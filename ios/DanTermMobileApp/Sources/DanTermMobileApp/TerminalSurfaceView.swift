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
    var didUpdateArchive: ((PaneReplicaArchive) -> Void)?
    var didChangeReplicaState: ((PaneReplicaState) -> Void)?

    private var replica = PaneReplica()
    private var metrics: TerminalRenderMetrics?
    private var stores: [TerminalFrameBackingStore] = []
    private var policy: MobilePresentationPolicy<Int>?
    private let surfaceView = UIView()
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?
    private var geometry: (columns: Int, rows: Int)?

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
    func reset(archive: PaneReplicaArchive?) -> PaneTapeCursor? {
        if let archive, let restored = try? PaneReplica(archive: archive) {
            replica = restored
        } else {
            replica = PaneReplica()
        }
        stores = []
        policy = nil
        geometry = nil
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
        try replica.apply(record)
        didChangeReplicaState?(replica.state)
        if let archive = replica.archive { didUpdateArchive?(archive) }
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

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let metrics, let geometry else { return }
        let width = CGFloat(metrics.cellWidthPixels * geometry.columns) / metrics.displayScale
        let height = CGFloat(metrics.cellHeightPixels * geometry.rows) / metrics.displayScale
        surfaceView.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let fit = min(bounds.width / max(width, 1), bounds.height / max(height, 1))
        surfaceView.transform = CGAffineTransform(scaleX: fit, y: fit)
        surfaceView.layer.position = CGPoint(
            x: (bounds.width - width * fit) / 2,
            y: (bounds.height - height * fit) / 2
        )
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

    private func ensureSurfaces(columns: Int, rows: Int) {
        if geometry?.columns == columns, geometry?.rows == rows { return }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        guard let metrics = TerminalRenderMetrics(displayScale: scale, fontSize: 11) else { return }
        let newStores = (0..<3).compactMap { _ in
            TerminalFrameBackingStore(columns: columns, rows: rows, metrics: metrics)
        }
        guard newStores.count == 3 else { return }
        self.metrics = metrics
        stores = newStores
        policy = MobilePresentationPolicy(surfaceIds: Array(stores.indices))
        geometry = (columns, rows)
        surfaceView.layer.contentsScale = scale
        setNeedsLayout()
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
