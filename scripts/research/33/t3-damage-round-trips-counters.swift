// Research doc 33, task T3: the counter shim the instrumented engine copy increments.
//
// `t3-damage-round-trips.py` copies `lib/TerminalCore/Sources/TerminalCore` and
// `lib/TerminalCore/Sources/TerminalRenderPlanning` into a scratch directory, injects one
// call to a member of this type at each site on the damage path, and compiles the result
// as one module with `t3-damage-round-trips-probe.swift`. Nothing here is on a production
// path and the engine in the repo is never edited.
//
// It holds counting only. Any decision about what the numbers mean belongs in the finding.

/// Tallies of every allocation and hash operation the damage representation costs between
/// the accumulator's words and the clip spans a draw finally uses.
///
/// Allocations and hash operations are counted separately per stage rather than summed
/// here, because the stages sit in three different owners -- engine, session, view -- and a
/// task that deletes one of them must be able to read its own line.
struct T3Counters {
    // Stage 1, engine: `TerminalDamageAccumulator.drain()` walks its words into a `Set<Int>`.
    var drainCalls = 0
    var drainFullCalls = 0
    var drainSetAllocations = 0
    var drainRowInserts = 0

    // Stage 1b, engine: why a frame carries `.full` instead of rows. The three named sites
    // are the branches of `recordDamage(from:to:)`; everything else lands in the totals
    // only, and the difference between them is the "some other site" residue.
    var fullDamageCalls = 0
    var fullDamageEscalations = 0
    var fullFromNotFollowingBefore = 0
    var fullFromTopRowOrScreenChange = 0
    var fullFromNotFollowingAfter = 0

    // Stage 2, engine: `TerminalDamage.init(rows:)` filters that set into an array and
    // rebuilds a second set from it.
    var damageInitCalls = 0
    var damageInitArrayAllocations = 0
    var damageInitSetAllocations = 0
    var damageInitRowHashes = 0

    // Stage 3, session and view: `TerminalDamage.formUnion` hashes every row of the other
    // side into the receiver.
    var formUnionCalls = 0
    var formUnionEmptyCalls = 0
    var formUnionRowHashes = 0

    // Stage 4, view: `terminalDamageRowsWithGlyphHalo` builds a third set at three inserts
    // per damaged row.
    var haloCalls = 0
    var haloSetAllocations = 0
    var haloRowInserts = 0

    // Stage 5, planner: `damage.rows.contains(row)` per viewport row, from three sites. The
    // `replanning` predicate is one closure reached twice -- once by the cell traversal and
    // once by the padding sweep below it -- and the row-copy loop asks a third time.
    var plannerPredicateCalls = 0
    var plannerRowCopyLookups = 0

    // Stage 6, draw: `terminalDamageMaximalContiguousSpans` sorts the set back into order.
    var spanCalls = 0
    var spanSortArrayAllocations = 0
    var spanSortRows = 0
    /// Calls whose input set already iterated in ascending order before `sorted()` ran.
    var spanSortAlreadyAscending = 0
    /// Adjacent pairs of the input set's native iteration order that ran downhill. Zero on
    /// an already-ascending call, so it separates "nearly ordered" from "scrambled".
    var spanSortInversions = 0

    mutating func noteDrainSet() {
        drainSetAllocations += 1
    }

    mutating func noteDamageInit(rowCount: Int) {
        damageInitCalls += 1
        damageInitArrayAllocations += 1
        damageInitSetAllocations += 1
        damageInitRowHashes += rowCount
    }

    mutating func noteFormUnion(rowCount: Int) {
        formUnionCalls += 1
        if rowCount == 0 { formUnionEmptyCalls += 1 }
        formUnionRowHashes += rowCount
    }

    mutating func noteHalo() {
        haloCalls += 1
        haloSetAllocations += 1
    }

    /// Records one span coalescing and whether the sort it is about to run was needed.
    ///
    /// The check walks the set in its own iteration order, which is the order `sorted()`
    /// would have had to fix. It is the whole point of the counter: `T20` claims a word
    /// scan emits spans already ordered, and this measures what the `Set` gives up.
    mutating func noteSpanSort(_ rows: Set<Int>) {
        spanCalls += 1
        spanSortArrayAllocations += 1
        spanSortRows += rows.count
        var previous: Int?
        var inversions = 0
        for row in rows {
            if let previous, row < previous { inversions += 1 }
            previous = row
        }
        spanSortInversions += inversions
        if inversions == 0 { spanSortAlreadyAscending += 1 }
    }

    var totalSetAllocations: Int {
        drainSetAllocations + damageInitSetAllocations + haloSetAllocations
    }

    var totalArrayAllocations: Int {
        damageInitArrayAllocations + spanSortArrayAllocations
    }

    var totalHashOperations: Int {
        drainRowInserts
            + damageInitRowHashes
            + formUnionRowHashes
            + haloRowInserts
            + plannerMembershipLookups
    }

    var plannerMembershipLookups: Int {
        plannerPredicateCalls + plannerRowCopyLookups
    }
}

nonisolated(unsafe) var t3Counters = T3Counters()
