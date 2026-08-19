// Presents one exact pane replica through detached IOSurfaces and damage-gated ticks.
import DanTermClient
import DanTermMobileKit
import DanTermProtocol
import Foundation
import TerminalCore
import TerminalRenderExecution
import TerminalRenderPlanning
import UIKit

/// Everything the scroll chrome needs to describe this surface, read in one pass.
///
/// One value rather than four properties, because the viewport the chrome sizes and the
/// projection it mirrors have to describe the same drawn grid: read separately, a layout
/// pass between two reads would let the chrome give UIKit a viewport the projection does
/// not fit, and its maximum offset would then stop short of the engine's maximum top row.
struct TerminalScrollFacts {
    /// Nothing while the replica holds no terminal, which is a surface with no stream yet
    /// rather than one with nothing to scroll.
    let projection: TerminalScrollProjection?
    /// One drawn row's height in this view's points, which is the whole conversion between
    /// the engine's rows and a scroll view's offsets.
    let rowHeight: CGFloat
    /// The bottom-pinned rectangle the cells occupy, which the chrome overlays exactly.
    let drawnFrame: CGRect
    let isAlternateScreenActive: Bool
}

/// Owns the replica and reusable surfaces so attached pixels are never mutated.
@MainActor
final class TerminalSurfaceView: UIView {
    /// Signals that a new exact cursor can replace the saved continuation checkpoint.
    var didAdvanceReplica: (() -> Void)?
    var didChangeReplicaState: ((PaneReplicaState) -> Void)?
    /// Signals that the extent or the safe area this view claims and draws inside settled
    /// at new values, so the session can be told the grid it now offers.
    var didLayout: (() -> Void)?

    private var replica = PaneReplica()
    private var replicaPaneId: PaneId?
    private var surface: MobileObserveSurface?
    private var stores: [TerminalFrameBackingStore] = []
    private var policy: MobilePresentationPolicy<Int>?
    private let surfaceView = UIView()
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?
    private var geometry: (columns: Int, rows: Int)?

    /// How far the keyboard-riding bar has risen above this view's bottom, in points,
    /// measured by the placing controller. It is a presentation offset only: the grid,
    /// the claim, and the frame stores read the content box, which never sees it.
    var obscuredBottomHeight: CGFloat = 0 {
        didSet {
            guard obscuredBottomHeight != oldValue else { return }
            setNeedsLayout()
        }
    }

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
        let previousSlack = anchorSlackPixels
        defer { invalidateLayoutOnAnchorMove(from: previousSlack) }
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
    func scrollViewport(_ scroll: MobileViewportScroll) {
        let previousSlack = anchorSlackPixels
        defer { invalidateLayoutOnAnchorMove(from: previousSlack) }
        switch scroll {
        case .byRows(let rows): replica.scrollViewport(byRows: rows)
        case .toTopRow(let row): replica.scrollViewport(toTopRow: row)
        }
        guard replica.state == .exact else { return }
        policy?.noteDamage()
        displayLink?.isPaused = false
    }

    /// Prevents local viewport scrolling while the remote pane uses its alternate screen.
    var isAlternateScreenActive: Bool {
        replica.terminal?.isAlternateScreenActive == true
    }

    /// The engine's scroll truth and the geometry it is drawn with. Nothing until this view
    /// has fitted a surface, because until then there is no drawn row to measure.
    var scrollFacts: TerminalScrollFacts? {
        guard let surface, let placement else { return nil }
        return TerminalScrollFacts(
            projection: replica.terminal?.scrollProjection,
            rowHeight: surface.cellSize(in: placement.contentBox).height,
            drawnFrame: surface.drawnFrame(in: placement),
            isAlternateScreenActive: isAlternateScreenActive
        )
    }

    /// The grid cell one point in this view's coordinates falls on, so a gesture the owner
    /// turns into a mouse report names a real position instead of the origin.
    func gridCell(at point: CGPoint) -> (column: Int, row: Int)? {
        guard let surface, let placement else { return nil }
        return surface.cell(at: point, in: placement)
    }

    /// Whether the replicated pane's grid is an override, or nothing while the replica
    /// is not exact. It is the replica's own bit rather than a comparison of grids: a
    /// coincidental match between the pane's grid and this phone's is not a claim.
    var pinned: Bool? { replica.pinned }

    /// The grid this surface shows at native cell metrics, which is the grid the claim
    /// gesture asks the pane to run at. It is derived from the current extent rather
    /// than from the replica, so it answers for the phone even before a stream arrives.
    var nativeGrid: MobileSurfaceGrid? {
        contentBox?.nativeGrid(fontSize: Self.fontSize)
    }

    /// Copies one exact value snapshot so checkpoint synthesis can run off the main actor.
    func checkpointSource() -> (replica: PaneReplica, paneId: PaneId)? {
        guard replica.state == .exact, let replicaPaneId else { return nil }
        return (replica, replicaPaneId)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The extent decides the metrics, so a rotation has to be able to change them.
        // Re-running the fit here is what makes the surfaces follow the view. The
        // keyboard is not such a change: this view's bounds are keyboard-absent, so a
        // show or hide reaches only the placement below, never the fit.
        if let geometry { ensureSurfaces(columns: geometry.columns, rows: geometry.rows) }
        if let surface, let placement {
            let scale = placement.contentBox.displayScale
            // The pixels are already drawn small enough for this view, so they are shown
            // one for one rather than scaled by a transform.
            let frame = surface.drawnFrame(in: placement)
            surfaceView.bounds = CGRect(origin: .zero, size: frame.size)
            surfaceView.layer.contentsScale = scale
            // The replica draws bottom-pinned at the placement's drawn bottom, which the
            // keyboard lifts only as far as the cursor anchor needs: a fresh prompt stays
            // put, and a full screen slides its top rows up out of the clip.
            surfaceView.layer.position = frame.origin
        }
        // Reported from here, last, because this is the moment the view's own extent and
        // safe area are both settled. An owner watching the controller's layout callback
        // would read them one pass early, since a subview's insets are resolved after its
        // superview lays out.
        didLayout?()
    }

    // The safe area is half of the content box, and iOS delivers inset changes without a
    // bounds change on some rotations, so the fit has to be re-run for one.
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
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
        guard let box = contentBox,
              let fitted = MobileObserveSurface(
                  columns: columns,
                  rows: rows,
                  contentBox: box,
                  fontSize: Self.fontSize
              )
        else { return }
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

    /// The one reading of the region this view may put cells in. Every extent question
    /// -- what grid a claim names, what pixels a frame store holds, where the layer
    /// showing them sits -- is answered from this single value, so none of them can
    /// describe a different region than the others. The insets are zero until the
    /// terminal runs full-bleed and has a safe area to stay clear of.
    private var contentBox: MobileContentBox? {
        MobileContentBox(
            width: bounds.width,
            height: bounds.height,
            insetTop: safeAreaInsets.top,
            // The box's near and far edges are the drawn pixels' own, so the physical
            // insets map onto them directly rather than by writing direction.
            insetLeading: safeAreaInsets.left,
            insetTrailing: safeAreaInsets.right,
            // The bottom edge of this view is the top of the bottom controls, which is
            // already clear of anything the system reserves.
            insetBottom: 0,
            displayScale: window?.screen.scale ?? traitCollection.displayScale
        )
    }

    /// The one reading of where the drawn rectangle sits right now. Every consumer that
    /// must line up with the cells -- the drawn layer, the scroll chrome's facts, the
    /// gesture-to-cell mapping -- reads this value, so a keyboard mid-slide cannot put
    /// them in different places.
    private var placement: MobileSurfacePlacement? {
        contentBox.map {
            MobileSurfacePlacement(
                contentBox: $0,
                obscuredHeight: obscuredBottomHeight,
                anchorSlackPixels: anchorSlackPixels
            )
        }
    }

    /// The drawn pixels below the replica's anchored cursor row, or nothing without an
    /// eligible anchor, which makes the placement fall back to the full lift.
    private var anchorSlackPixels: Int? {
        guard let surface, let row = replica.cursorAnchorRow else { return nil }
        return surface.slackPixels(belowRow: row)
    }

    /// Schedules a layout pass when a record or a local scroll moved the anchor while
    /// the keyboard is up; the drawn layer's position is only written in `layoutSubviews`,
    /// so a moved anchor that schedules nothing would leave the lift stale.
    private func invalidateLayoutOnAnchorMove(from previousSlack: Int?) {
        guard obscuredBottomHeight > 0, anchorSlackPixels != previousSlack else { return }
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
