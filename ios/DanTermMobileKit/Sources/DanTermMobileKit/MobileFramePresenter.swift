// The phone's whole presentation path: one frame planner and one surface
// swapchain per fitted surface, driven one step per display-link tick.
//
// It exists so the phone presents *through* the engine's presentation
// discipline rather than around it: the planner replans only damaged rows and
// the swapchain composes what each rotating buffer missed. What deliberately
// does not live here is a damage value of the phone's own -- the engine owns
// undrained damage and the swapchain owns per-buffer stale damage, so the only
// phone-side bit is "a drain is pending". Geometry does not live here either:
// the view fits the surface and reports records, scrolls, layout, and reset.
import IOSurface
import TerminalCore
import TerminalRenderExecution
import TerminalRenderPlanning

/// Turns one pane replica's damage into presented frames for one view.
///
/// Main-thread only, like the frame stores it hands back. It is a reference type
/// because the swapchain it drives is one: the view holds it for the life of the
/// view and refits it in place rather than replacing it, which is what lets the
/// pending-drain bit and the not-yet-fitted state outlive a surface rebuild.
public final class MobileFramePresenter {
    /// The store the view has attached, or nothing before this stream's first
    /// frame. The presenter tracks it so a reset can state that the layer must
    /// show nothing, while a same-stream refit keeps the frame already on screen.
    public private(set) var attachedStore: TerminalFrameBackingStore?

    private var swapchain: TerminalFrameSwapchain?
    private var planner = PaneFramePlanner()
    /// Set where terminal state may have moved, cleared by the tick that reads it.
    /// It is a bit rather than a damage set on purpose: the damage itself stays in
    /// the engine until a tick drains it.
    private var isDrainPending = false
    /// False until this fitted surface has published a plan, which forces the
    /// first frame after any fit to be a full render even when nothing is damaged.
    private var hasPublished = false
    private let isStoreInUse: (TerminalFrameBackingStore) -> Bool

    /// `isStoreInUse` exists for the headless kit tests; the view keeps the
    /// IOSurface default, exactly as the engine's swapchain does.
    public init(
        isStoreInUse: @escaping (TerminalFrameBackingStore) -> Bool = { $0.ioSurface.isInUse }
    ) {
        self.isStoreInUse = isStoreInUse
    }

    /// How the phone draws whatever the pane reports: its own fixed theme, and
    /// the terminal's own cursor. One definition, so a frame and any comparison
    /// against it cannot be planned under different presentation inputs.
    public static func presentation(for terminal: Terminal) -> RenderPresentation {
        let terminalPresentation = terminal.presentation
        return RenderPresentation(
            theme: .dark,
            isCursorVisible: terminalPresentation.isCursorVisible,
            cursorShape: terminalPresentation.cursorShape
        )
    }

    /// What the last presentation rendered: `.full` for a from-scratch render,
    /// otherwise the composed stale damage the buffer applied. Nil until the first
    /// presented frame.
    public var lastRenderedDamage: TerminalDamage? {
        swapchain?.lastRenderedDamage
    }

    /// Whether a display-link tick has anything to do. False without a fitted
    /// surface, so a pane with no extent yet parks the link instead of spinning;
    /// the pending drain is kept and the first fit picks it up.
    public var needsTick: Bool {
        guard let swapchain else { return false }
        return isDrainPending || swapchain.hasPendingPresentation
    }

    /// Records that terminal state may have moved. Called for every record, local
    /// scroll, and surface rebuild -- never for the damage itself, which stays in
    /// the engine until a tick drains it.
    public func noteDrainPending() {
        isDrainPending = true
    }

    /// Points this presenter at a grid and metrics, rebuilding the buffers and the
    /// planner when either moved. Returns false only when the buffers cannot be
    /// allocated, which leaves the previous surface presenting.
    ///
    /// A rebuild owes a frame even with nothing damaged: a rotation or a
    /// display-scale move changes no terminal row, and the fresh buffers hold no
    /// pixels, so the first tick after it must draw in full.
    @discardableResult
    public func fit(columns: Int, rows: Int, metrics: TerminalRenderMetrics) -> Bool {
        if let swapchain,
           swapchain.matches(columns: columns, rows: rows, metrics: metrics, colorSpace: nil) {
            return true
        }
        guard let rebuilt = TerminalFrameSwapchain(
            columns: columns,
            rows: rows,
            metrics: metrics,
            isStoreInUse: isStoreInUse
        ) else { return false }
        swapchain = rebuilt
        planner = PaneFramePlanner()
        hasPublished = false
        isDrainPending = true
        return true
    }

    /// Drops everything this stream owned, including the attached frame, because
    /// the next stream's pixels are not this one's. The caller detaches the layer
    /// contents to match, so no pane can ever show another pane's last frame.
    public func resetStream() {
        swapchain = nil
        planner = PaneFramePlanner()
        attachedStore = nil
        hasPublished = false
        isDrainPending = false
    }

    /// One display-link step: drain, plan, publish, or retry -- and return the
    /// store the caller must attach, or nothing when this tick presents no frame.
    ///
    /// A drain that yields nothing does not end the tick: a presentation coalesced
    /// on an earlier tick still owes the screen a frame, and the replica may have
    /// left `.exact` since it was planned.
    public func tick(_ replica: inout PaneReplica) -> TerminalFrameBackingStore? {
        guard let swapchain else { return nil }
        var presented: TerminalFrameBackingStore?
        if isDrainPending {
            isDrainPending = false
            if let frame = replica.drainPresentation() {
                // The first frame of a fitted surface is full whatever the engine
                // reports, which is what makes a rebuild draw at all: the drain after
                // a rotation carries no damage, and empty damage publishes nothing.
                let damage = hasPublished ? frame.damage : .full
                if damage.isEmpty == false {
                    let plan = planner.planFrame(
                        for: frame.terminal,
                        presentation: Self.presentation(for: frame.terminal),
                        damage: damage
                    )
                    hasPublished = true
                    presented = swapchain.publish(plan: plan, damage: damage)
                }
            }
        }
        if presented == nil {
            presented = swapchain.retryPendingPresentation()
        }
        if let presented {
            attachedStore = presented
        }
        return presented
    }
}
