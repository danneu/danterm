// The damage-aware planning entry point for one pane's ordered frame stream.
// Separate from `RenderFramePlanner.swift` because that file owns the stateless
// planning boundary -- everything here exists to hold state *between* frames, and
// keeping the two apart is what stops cross-frame reuse from leaking into the
// stateless `planFrame(for:presentation:)` contract every other caller uses.
import TerminalCore

/// Plans successive frames for a single pane, copying the runs of rows the
/// terminal did not damage instead of re-inspecting their cells.
///
/// Reuse state, accumulated damage, and terminal snapshots are only jointly
/// meaningful within one pane's ordered frame stream -- nothing binds them to
/// each other at the type level, so pairing a retained frame with another pane's
/// terminal would silently reuse the wrong rows. That is why the retained state
/// is owned here and never handed out: the only way to reach reuse is through an
/// instance the pane keeps for its own stream, so the lineage invariant reduces
/// to "one planner per pane" rather than a per-call obligation.
///
/// Reuse is refused -- and the full viewport replanned -- whenever presentation
/// differs from the retained frame's, the grid dimensions differ, damage is full,
/// or no retained frame exists. Presentation is carried rather than assumed
/// stable because it is the one planning input the damage model does not cover:
/// a future per-pane theme switch changes every row's colors while recording no
/// damage at all.
public struct PaneFramePlanner: Sendable {
    private var retained: RetainedFrame?

    /// Starts a stream with no retained frame, so the first call plans in full.
    public init() {}

    /// Plans the complete viewport, replanning only the rows `damage` marks when
    /// the previous frame of this stream is still reusable.
    ///
    /// The result is always a complete plan, never a clipped one: callers that
    /// draw incrementally pass the resulting row restriction to the executor.
    public mutating func planFrame(
        for terminal: borrowing Terminal,
        searchReadout: TerminalSearchReadout?,
        presentation: RenderPresentation,
        damage: TerminalDamage
    ) -> RenderFramePlan {
        let reusable = retained?.presentation == presentation ? retained?.rows : nil
        let planned = FramePlanner(presentation: presentation)
            .plan(
                for: terminal,
                searchReadout: searchReadout,
                reusing: reusable,
                damage: damage
            )
        retained = RetainedFrame(presentation: presentation, rows: planned.retained)
        return planned.plan
    }

    /// Binds retained rows to the presentation they were planned under, so the
    /// two can never be compared or reused independently.
    private struct RetainedFrame: Sendable {
        let presentation: RenderPresentation
        let rows: RetainedFrameRows
    }
}
