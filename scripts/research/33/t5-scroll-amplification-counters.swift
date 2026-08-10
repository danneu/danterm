// Research doc 33, task T5: the counter shim the instrumented engine copy increments.
//
// `t5-scroll-amplification.py` copies `lib/TerminalCore/Sources/TerminalCore` and
// `lib/TerminalCore/Sources/TerminalRenderPlanning` into a scratch directory, injects one
// call to a member of this type at each site this task counts, and compiles the result as
// one module with `t5-scroll-amplification-probe.swift`. Nothing here is on a production
// path and the engine in the repo is never edited.
//
// It holds counting only. Any decision about what the numbers mean belongs in the finding.

/// Tallies what one scroll event costs the planner, and why the frame it produced carries
/// `.full` damage instead of rows.
///
/// The escalation attribution is kept separate from the planner traversal because they
/// answer two different halves of `T9`'s claim: the escalation is what refuses row-scoped
/// drawing, and the traversal is what refuses row reuse in the planner above it.
struct T5Counters {
    // Engine, `Terminal.recordPresentationFullDamage` and the three branches of
    // `recordDamage(from:to:)` that reach it. Anything else lands in the totals only, and
    // the difference is the "some other site" residue.
    var fullDamageCalls = 0
    var fullDamageEscalations = 0
    var fullFromNotFollowingBefore = 0
    var fullFromTopRowOrScreenChange = 0
    var fullFromNotFollowingAfter = 0

    // Rows carried by drained non-full damage values. Counted by the probe at its own
    // drain call rather than injected: the word-backed drain builds no per-row set, so
    // there is no engine site left to patch.
    var drainRowInserts = 0

    // Planner, `FramePlanner.inspectedCells`: rows the traversal re-inspected and cells it
    // built a `PlannedCell` for. This is the planning half of the amplification -- reuse
    // skips a row entirely, so a re-inspected row is a row the frame paid for again.
    var plannerRowsInspected = 0
    var plannerCellsInspected = 0
}

nonisolated(unsafe) var t5Counters = T5Counters()
