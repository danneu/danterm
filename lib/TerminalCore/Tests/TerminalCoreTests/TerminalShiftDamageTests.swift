// Value-level proofs for the shift-carrying, word-backed damage representation
// (research/33 T9 with the T20 rider): composition rules, canonical spans, halo,
// and the fold every consumer that cannot translate applies at its seam.

import Testing
@testable import TerminalCore

struct TerminalShiftDamageTests {
    @Test("row damage is canonical, bounded, and ascending without a sort")
    func rowsAreCanonicalAndAscending() {
        let damage = TerminalDamage(rows: [7, 2, 3, 64, 65, 130])
        #expect(damage.damagedRowCount == 6)
        #expect(damage.rowIndices == [2, 3, 7, 64, 65, 130])
        #expect(damage.maximalContiguousSpans() == [2..<4, 7..<8, 64..<66, 130..<131])
        #expect(damage.maximalContiguousSpanCount == 4)
        #expect(damage.contains(row: 64))
        #expect(damage.contains(row: 63) == false)
    }

    @Test("equality is semantic across storage widths")
    func equalityIgnoresCapacity() {
        #expect(TerminalDamage(rows: [1, 2], rowCount: 4) == TerminalDamage(rows: [1, 2], rowCount: 200))
        #expect(TerminalDamage(rows: [], rowCount: 66) == .none)
        #expect(TerminalDamage(rows: [0], rowCount: 66) != .none)
        #expect(TerminalDamage.full != .none)
    }

    @Test("the glyph halo is a word expansion clamped to the viewport")
    func glyphHalo() {
        let haloed = TerminalDamage(rows: [0, 5, 63, 64], rowCount: 66).withGlyphHalo(rowCount: 66)
        #expect(haloed.rowIndices == [0, 1, 4, 5, 6, 62, 63, 64, 65])
        let clamped = TerminalDamage(rows: [65], rowCount: 66).withGlyphHalo(rowCount: 66)
        #expect(clamped.rowIndices == [64, 65])
    }

    @Test("a later shift translates pending rows and drops rows leaving the region")
    func shiftTranslatesPendingRows() {
        // Rows 3 and 10 are pending; a one-line upward scroll of rows 2..<12 arrives.
        // Row 3's stale content now sits at row 2; row 10's at row 9. A pending row at
        // the region top (2) would leave the region and must drop.
        var pending = TerminalDamage(rows: [1, 2, 3, 10, 20], rowCount: 24)
        var later = TerminalDamage(rows: [], rowCount: 24)
        later.recordShift(region: 2..<12, delta: -1)
        later.formUnion(TerminalDamage(rows: [11], rowCount: 24))
        pending.formUnion(later)

        #expect(pending.shift == TerminalDamageShift(region: 2..<12, delta: -1))
        // 1 and 20 are outside the region and stay; 2 drops out; 3 -> 2, 10 -> 9; 11 is
        // the newly damaged row the later value carried.
        #expect(pending.rowIndices == [1, 2, 9, 11, 20])
    }

    @Test("same-region shifts sum and collapse to region rows at the region height")
    func sameRegionShiftsSumAndCollapse() {
        var pending = TerminalDamage(rows: [], rowCount: 10)
        pending.recordShift(region: 0..<4, delta: -2)
        var later = TerminalDamage(rows: [], rowCount: 10)
        later.recordShift(region: 0..<4, delta: -1)
        pending.formUnion(later)
        #expect(pending.shift == TerminalDamageShift(region: 0..<4, delta: -3))

        var final = TerminalDamage(rows: [], rowCount: 10)
        final.recordShift(region: 0..<4, delta: -1)
        pending.formUnion(final)
        // |delta| reached the region height: nothing survives translation, so the
        // shift collapses to region-wide row damage and rows outside stay untouched.
        #expect(pending.shift == nil)
        #expect(pending.rowIndices == [0, 1, 2, 3])
    }

    @Test("a shift with a different region escalates to full")
    func regionMismatchEscalates() {
        var pending = TerminalDamage(rows: [], rowCount: 10)
        pending.recordShift(region: 0..<4, delta: -1)
        var later = TerminalDamage(rows: [], rowCount: 10)
        later.recordShift(region: 2..<8, delta: -1)
        pending.formUnion(later)
        #expect(pending == .full)
    }

    @Test("full damage absorbs everything and empty damage is the identity")
    func fullAndEmptyUnionLaws() {
        var full = TerminalDamage.full
        var later = TerminalDamage(rows: [1], rowCount: 4)
        later.recordShift(region: 0..<4, delta: -1)
        full.formUnion(later)
        #expect(full == .full)

        var pending = TerminalDamage.none
        pending.formUnion(later)
        #expect(pending == later)
        pending.formUnion(.none)
        #expect(pending == later)

        pending.formUnion(.full)
        #expect(pending == .full)
    }

    @Test("expanding the shift folds it into region-wide row damage")
    func expandingShiftFoldsToRegionRows() {
        var damage = TerminalDamage(rows: [15], rowCount: 16)
        damage.recordShift(region: 2..<12, delta: -1)
        damage.formUnion(TerminalDamage(rows: [11], rowCount: 16))
        let expanded = damage.expandingShift()
        #expect(expanded.shift == nil)
        #expect(expanded.rowIndices == Array(2..<12) + [15])
        #expect(TerminalDamage.full.expandingShift() == .full)
        #expect(TerminalDamage.none.expandingShift() == .none)
    }

    @Test("an out-of-range row cannot be constructed into bounded damage")
    func outOfRangeRowsAreUnrepresentable() async {
        await #expect(processExitsWith: .failure) {
            _ = TerminalDamage(rows: [7], rowCount: 4)
        }
        await #expect(processExitsWith: .failure) {
            _ = TerminalDamage(rows: [-1])
        }
    }
}

/// Engine-side proofs that a scroll records a translation at the scroll site
/// (research/33 T9 against D7): the drained value carries `(region, delta)`
/// plus O(1) rows -- the vacated strip and the two cursor rows -- in both
/// history regimes, and every viewport change the shift does not describe
/// still escalates exactly as before.
struct TerminalScrollShiftDamageTests {
    private let line = "paced line 0123456789 abcdefghijklmnopqrstuvwxyz 0123456789"

    /// Fills every viewport row, leaving the cursor at column 0 of the bottom row.
    private func prefill(_ terminal: inout Terminal, rows: Int) {
        var bytes: [UInt8] = []
        for _ in 0..<(rows - 1) { bytes += Array((line + "\r\n").utf8) }
        bytes += Array((line + "\r").utf8)
        terminal.feed(bytes)
        _ = terminal.drainDamage()
    }

    @Test("a one-line scroll below the history budget drains a shift plus O(1) rows")
    func belowBudgetScrollDrainsShift() throws {
        // Intent: the paced-regime steady state -- one line per drain -- publishes a
        //   whole-viewport translation and damages only the vacated row and the two
        //   cursor rows, instead of escalating to `.full` on the topRow guard.
        // Why it exists: research/33 F11/F13 measured 100% of streaming escalation
        //   coming from that guard, 66 rows damaged to express 1.
        var terminal = try #require(Terminal(columns: 80, rows: 40))
        prefill(&terminal, rows: 40)

        for _ in 0..<20 {
            let topBefore = terminal.absoluteViewportTopRow
            terminal.feed(Array((line + "\r\n").utf8))
            let damage = terminal.drainDamage()
            #expect(terminal.absoluteViewportTopRow - topBefore == 1)
            #expect(damage.isFull == false)
            #expect(damage.shift == TerminalDamageShift(region: 0..<40, delta: -1))
            #expect(damage.rowIndices == [38, 39])
        }
    }

    @Test("a scroll at the history budget drains the same shift-carrying value")
    func atBudgetScrollDrainsSameShift() throws {
        // Intent: where arena eviction freezes `scrollProjection.topRow`, the drained
        //   damage is byte-for-byte the below-budget shape.
        // Why it exists: research/33 F19's rider -- a shift derived from topRow deltas
        //   reads zero exactly here, so the shift must come from the scroll site, and
        //   this is the at-budget arm D7 requires the verification matrix to carry.
        var terminal = try #require(Terminal(
            columns: 80,
            rows: 40,
            scrollbackBudgetBytes: historyBudget(lines: 60, cells: 60, paneColumns: 80)
        ))
        for _ in 0..<300 { terminal.feed(Array((line + "\r\n").utf8)) }
        _ = terminal.drainDamage()

        var frozenTopRowScrolls = 0
        for _ in 0..<200 {
            let projectedBefore = terminal.scrollProjection.topRow
            let absoluteBefore = terminal.absoluteViewportTopRow
            terminal.feed(Array((line + "\r\n").utf8))
            let damage = terminal.drainDamage()
            #expect(terminal.absoluteViewportTopRow - absoluteBefore == 1)
            if terminal.scrollProjection.topRow == projectedBefore { frozenTopRowScrolls += 1 }
            #expect(damage.isFull == false)
            #expect(damage.shift == TerminalDamageShift(region: 0..<40, delta: -1))
            #expect(damage.rowIndices == [38, 39])
        }
        // The regime must actually be the frozen-topRow one, or this arm proves nothing.
        #expect(frozenTopRowScrolls > 100)
    }

    @Test("two scrolls in one drain compose into one summed shift")
    func scrollsComposeAcrossOneDrain() throws {
        var terminal = try #require(Terminal(columns: 80, rows: 40))
        prefill(&terminal, rows: 40)

        terminal.feed(Array((line + "\r\n" + line + "\r\n").utf8))
        let damage = terminal.drainDamage()
        #expect(damage.isFull == false)
        #expect(damage.shift == TerminalDamageShift(region: 0..<40, delta: -2))
        // The first line's damage translates up one row under the second scroll.
        #expect(damage.rowIndices == [37, 38, 39])
    }

    @Test("a scrolled-back viewport still escalates to full damage")
    func browsingScrollStaysFull() throws {
        var terminal = try #require(Terminal(columns: 80, rows: 10))
        for _ in 0..<30 { terminal.feed(Array((line + "\r\n").utf8)) }
        terminal.scroll(byRows: -5)
        _ = terminal.drainDamage()

        terminal.feed(Array((line + "\r\n").utf8))
        #expect(terminal.drainDamage() == .full)
    }

    @Test("a DECSTBM region scroll translates only the region")
    func regionScrollShiftsRegionOnly() throws {
        // CSI 3;10r pins rows 2..<10; the footer and header rows outside it are
        // untouched, so the shift names the region and the viewport top holds.
        var terminal = try #require(Terminal(columns: 80, rows: 12))
        prefill(&terminal, rows: 12)
        terminal.feed(Array("\u{1B}[3;10r\u{1B}[8;1H".utf8))
        _ = terminal.drainDamage()
        let topBefore = terminal.absoluteViewportTopRow

        terminal.feed(Array("\r\n\r\n".utf8))
        _ = terminal.drainDamage()
        terminal.feed(Array((line + "\r\n").utf8))
        let damage = terminal.drainDamage()
        #expect(terminal.absoluteViewportTopRow == topBefore)
        #expect(damage.isFull == false)
        #expect(damage.shift == TerminalDamageShift(region: 2..<10, delta: -1))
        #expect(damage.rowIndices == [8, 9])
    }

    @Test("reverse index at the top records a downward shift")
    func reverseIndexShiftsDown() throws {
        var terminal = try #require(Terminal(columns: 80, rows: 12))
        prefill(&terminal, rows: 12)
        terminal.feed(Array("\u{1B}[1;1H".utf8))
        _ = terminal.drainDamage()

        terminal.feed(Array("\u{1B}M".utf8))
        let damage = terminal.drainDamage()
        #expect(damage.isFull == false)
        #expect(damage.shift == TerminalDamageShift(region: 0..<12, delta: 1))
        #expect(damage.rowIndices == [0, 1])
    }

    @Test("an active selection forces a non-pushing scroll back to region rows")
    func selectionRefusesNonPushingShift() throws {
        // A retained frame bakes the selection into its rows, and a selection is
        // anchored to rows, not content: translating a baked row would move the
        // highlight with the content while the real selection stays put. The
        // fallback is the pre-shift representation -- region-wide row damage.
        var terminal = try #require(Terminal(columns: 80, rows: 12))
        prefill(&terminal, rows: 12)
        terminal.feed(Array("\u{1B}[3;10r\u{1B}[10;1H".utf8))
        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 3, column: 0),
            end: TerminalTextPosition(row: 3, column: 5)
        ))
        _ = terminal.drainDamage()

        terminal.feed(Array((line + "\r\n").utf8))
        let damage = terminal.drainDamage()
        #expect(damage.isFull == false)
        #expect(damage.shift == nil)
        #expect(Set(damage.rowIndices).isSuperset(of: Set(2..<10)))
    }

    @Test("an active selection rides a whole-viewport push scroll as a shift")
    func selectionSurvivesWholeViewportShift() throws {
        // A whole-viewport push is the one scroll whose overlays are content-anchored
        // in the direction the content moves: history absorbs the top row and every
        // stream anchor keeps naming the same content, so the baked highlight
        // translates exactly with its text and no fallback is needed.
        var terminal = try #require(Terminal(columns: 80, rows: 40))
        prefill(&terminal, rows: 40)
        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 2, column: 0),
            end: TerminalTextPosition(row: 2, column: 5)
        ))
        _ = terminal.drainDamage()

        terminal.feed(Array((line + "\r\n").utf8))
        let damage = terminal.drainDamage()
        #expect(damage.isFull == false)
        #expect(damage.shift == TerminalDamageShift(region: 0..<40, delta: -1))
    }

    @Test("an alternate-screen scroll shifts without escalating")
    func alternateScreenScrollShifts() throws {
        var terminal = try #require(Terminal(columns: 80, rows: 12))
        terminal.feed(Array("\u{1B}[?1049h".utf8))
        prefill(&terminal, rows: 12)

        terminal.feed(Array((line + "\r\n").utf8))
        let damage = terminal.drainDamage()
        #expect(damage.isFull == false)
        #expect(damage.shift == TerminalDamageShift(region: 0..<12, delta: -1))
        #expect(damage.rowIndices == [10, 11])
    }
}
