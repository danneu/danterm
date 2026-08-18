// Presents one exact pane replica through detached IOSurfaces and damage-gated ticks.
import DanTermClient
import DanTermMobileKit
import DanTermProtocol
import Foundation
import TerminalCore
import TerminalRenderExecution
import TerminalRenderPlanning
import UIKit

/// Owns the replica and reusable surfaces so attached pixels are never mutated.
@MainActor
final class TerminalSurfaceView: UIView {
    /// Signals that a new exact cursor can replace the saved continuation checkpoint.
    var didAdvanceReplica: (() -> Void)?
    var didChangeReplicaState: ((PaneReplicaState) -> Void)?

    private var replica = PaneReplica()
    private var replicaPaneId: PaneId?
    private var surface: MobileObserveSurface?
    private var stores: [TerminalFrameBackingStore] = []
    private var policy: MobilePresentationPolicy<Int>?
    private let surfaceView = UIView()
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?
    private var geometry: (columns: Int, rows: Int)?

    /// The one font size this surface renders and claims at; both readings of the cell
    /// box must agree or a claim would name a grid the surface does not draw.
    private static let fontSize: CGFloat = 11

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        surfaceView.layer.anchorPoint = .zero
        surfaceView.layer.magnificationFilter = .nearest
        addSubview(surfaceView)
        let target = DisplayLinkTarget(owner: self)
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick))
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        displayLinkTarget = target
        displayLink = link
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        displayLink?.invalidate()
    }

    /// Replaces the current stream replica when the user selects another pane.
    @discardableResult
    func reset(checkpoint: PaneReplicaCheckpoint?, for paneId: PaneId) -> PaneTapeCursor? {
        replicaPaneId = paneId
        if let checkpoint, let restored = try? PaneReplica(checkpoint: checkpoint, for: paneId) {
            replica = restored
        } else {
            replica = PaneReplica()
        }
        stores = []
        policy = nil
        geometry = nil
        surface = nil
        surfaceView.layer.contents = nil
        displayLink?.isPaused = true
        if let terminal = replica.terminal {
            ensureSurfaces(columns: terminal.geometry.columns, rows: terminal.geometry.rows.count)
            policy?.noteDamage()
            displayLink?.isPaused = false
        }
        return replica.cursor
    }

    /// Applies one exact stream record and schedules only the presentation work it creates.
    func apply(_ record: PaneTapeRecord) throws {
        let previousCursor = replica.cursor
        try replica.apply(record)
        didChangeReplicaState?(replica.state)
        if replica.state == .exact, replica.cursor != previousCursor {
            didAdvanceReplica?()
        }
        guard replica.state == .exact, let terminal = replica.terminal else { return }
        ensureSurfaces(columns: terminal.geometry.columns, rows: terminal.geometry.rows.count)
        policy?.noteDamage()
        displayLink?.isPaused = policy?.needsTick == false
    }

    /// Applies local primary-screen scroll without sending authoritative terminal bytes.
    func scrollViewport(byRows rows: Int) {
        replica.scrollViewport(byRows: rows)
        guard replica.state == .exact else { return }
        policy?.noteDamage()
        displayLink?.isPaused = false
    }

    /// Prevents local viewport scrolling while the remote pane uses its alternate screen.
    var isAlternateScreenActive: Bool {
        replica.terminal?.isAlternateScreenActive == true
    }

    /// The grid this surface shows at native cell metrics, which is the grid the claim
    /// gesture asks the pane to run at. It is derived from the current extent rather
    /// than from the replica, so it answers for the phone even before a stream arrives.
    var nativeGrid: MobileSurfaceGrid? {
        let scale = displayScale
        guard let metrics = TerminalRenderMetrics(displayScale: scale, fontSize: Self.fontSize)
        else { return nil }
        return MobileSurfaceGrid(
            widthPixels: Int(bounds.width * scale),
            heightPixels: Int(bounds.height * scale),
            cellWidthPixels: metrics.cellWidthPixels,
            cellHeightPixels: metrics.cellHeightPixels
        )
    }

    /// Copies one exact value snapshot so checkpoint synthesis can run off the main actor.
    func checkpointSource() -> (replica: PaneReplica, paneId: PaneId)? {
        guard replica.state == .exact, let replicaPaneId else { return nil }
        return (replica, replicaPaneId)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The extent decides the metrics, so a rotation or a keyboard has to be able to
        // change them. Re-running the fit here is what makes the surfaces follow the view.
        if let geometry { ensureSurfaces(columns: geometry.columns, rows: geometry.rows) }
        guard let surface else { return }
        let scale = displayScale
        // The pixels are already drawn small enough for this view, so they are shown one
        // for one rather than scaled by a transform.
        let width = CGFloat(surface.pixelWidth) / scale
        let height = CGFloat(surface.pixelHeight) / scale
        surfaceView.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        surfaceView.layer.contentsScale = scale
        // The replica draws from the bottom of the view, so newly typed output stays put
        // while the keyboard changes how much of the view is left.
        surfaceView.layer.position = CGPoint(x: 0, y: bounds.height - height)
    }

    fileprivate func displayTick() {
        guard var policy, let action = policy.nextAction else {
            displayLink?.isPaused = true
            return
        }
        switch action {
        case .render(let surfaceId):
            guard stores[surfaceId].ioSurface.isInUse == false else {
                self.policy = policy
                return
            }
            guard let frame = replica.drainPresentation() else {
                displayLink?.isPaused = true
                return
            }
            let presentation = frame.terminal.presentation
            let plan = planFrame(
                for: frame.terminal,
                presentation: RenderPresentation(
                    theme: .dark,
                    isCursorVisible: presentation.isCursorVisible,
                    cursorShape: presentation.cursorShape
                )
            )
            stores[surfaceId].renderFull(plan)
            policy.didRender(surfaceId: surfaceId)
        case .publish(let surfaceId), .retryPublish(let surfaceId):
            let store = stores[surfaceId]
            if store.ioSurface.isInUse {
                policy.didCoalescePublish(surfaceId: surfaceId)
            } else {
                surfaceView.layer.contents = store.ioSurface
                policy.didPublish(surfaceId: surfaceId)
            }
        }
        self.policy = policy
        displayLink?.isPaused = policy.needsTick == false
    }

    /// Allocates the frame stores one grid needs in this view, at the metrics the view
    /// can actually draw it with. Idempotent: it returns without touching anything when
    /// neither the grid nor the resolved metrics moved, so the layout pass may call it.
    private func ensureSurfaces(columns: Int, rows: Int) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = displayScale
        guard let fitted = MobileObserveSurface(
            columns: columns,
            rows: rows,
            widthPixels: Int(bounds.width * scale),
            heightPixels: Int(bounds.height * scale),
            displayScale: scale,
            fontSize: Self.fontSize
        ) else { return }
        if geometry?.columns == columns, geometry?.rows == rows, surface == fitted { return }
        let newStores = (0..<3).compactMap { _ in
            TerminalFrameBackingStore(columns: columns, rows: rows, metrics: fitted.metrics)
        }
        guard newStores.count == 3 else { return }
        surface = fitted
        stores = newStores
        policy = MobilePresentationPolicy(surfaceIds: Array(stores.indices))
        geometry = (columns, rows)
        // The stores are new and hold no pixels, so the replica has to redraw into them
        // before anything can be published from them again.
        policy?.noteDamage()
        displayLink?.isPaused = false
        setNeedsLayout()
    }

    /// The one reading of this view's point-to-pixel scale, used for the metrics it
    /// renders with and for the size it shows those pixels at. The two must agree or the
    /// grid would be drawn at one size and presented at another.
    private var displayScale: CGFloat {
        window?.screen.scale ?? traitCollection.displayScale
    }
}

/// Breaks the display link's retain cycle while preserving its Objective-C selector target.
@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var owner: TerminalSurfaceView?

    init(owner: TerminalSurfaceView) {
        self.owner = owner
    }

    @objc func tick() {
        owner?.displayTick()
    }
}
