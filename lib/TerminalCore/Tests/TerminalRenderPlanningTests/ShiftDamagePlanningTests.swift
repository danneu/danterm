// The planner half of research/33 T9's equivalence gate: across every scenario
// D7 names -- below-budget and at-budget streaming, DECSTBM sub-region scrolls,
// the alternate screen, and active overlays -- a planner reusing rows across a
// shift must produce byte-identical plans to a from-scratch traversal on every
// frame. The corpus suite proves the same equality over recorded fixtures; this
// file drives the scenarios fixtures do not reach, the at-budget regime above
// all.

import Testing

@testable import TerminalCore
@testable import TerminalRenderPlanning

struct ShiftDamagePlanningTests {
    private let line = "shifted content 0123456789 abcdefghijklmnopqrstuvwxyz"

    private var blockCursor: RenderPresentation {
        RenderPresentation(theme: .dark, isCursorVisible: true, cursorShape: .block)
    }

    /// Fills every viewport row, leaving the cursor at column 0 of the bottom row.
    private func prefill(_ terminal: inout Terminal, rows: Int) {
        var bytes: [UInt8] = []
        for _ in 0..<(rows - 1) { bytes += Array((line + "\r\n").utf8) }
        bytes += Array((line + "\r").utf8)
        terminal.feed(bytes)
    }

    /// Feeds each step, drains its damage into the reusing planner, and asserts
    /// the reused plan equals a fresh full traversal of the same terminal.
    /// Returns how many drained frames carried a shift, so a scenario can prove
    /// it exercised the translated path rather than passing vacuously.
    private func assertReuseEqualsScratch(
        terminal: inout Terminal,
        steps: [[UInt8]],
        context: Comment
    ) -> Int {
        _ = terminal.drainDamage()
        var planner = PaneFramePlanner()
        _ = planner.planFrame(for: terminal, presentation: blockCursor, damage: .full)

        var shiftedFrames = 0
        for (index, bytes) in steps.enumerated() {
            terminal.feed(bytes)
            let damage = terminal.drainDamage()
            if damage.shift != nil { shiftedFrames += 1 }
            let reused = planner.planFrame(for: terminal, presentation: blockCursor, damage: damage)
            let scratch = planFrame(for: terminal, presentation: blockCursor)
            if reused != scratch {
                Issue.record("\(context) diverged at step \(index), damage: \(damage)")
                return shiftedFrames
            }
        }
        return shiftedFrames
    }

    @Test("below-budget streaming plans identically through translated reuse")
    func belowBudgetStreaming() throws {
        var terminal = try #require(Terminal(columns: 60, rows: 20))
        prefill(&terminal, rows: 20)
        let steps = (0..<30).map { _ in Array((line + "\r\n").utf8) }
        let shifted = assertReuseEqualsScratch(
            terminal: &terminal,
            steps: steps,
            context: "below-budget streaming"
        )
        #expect(shifted == 30)
    }

    @Test("at-budget streaming plans identically while eviction freezes topRow")
    func atBudgetStreaming() throws {
        // The regime research/33 F19 flagged: append and arena eviction cancel in
        // `scrollProjection.topRow` while content still translates, so the shift
        // must come from the scroll site and reuse must stay sound across
        // eviction's chunked reindexing.
        var terminal = try #require(Terminal(
            columns: 60,
            rows: 20,
            scrollbackBudgetBytes: 4096
        ))
        for _ in 0..<200 { terminal.feed(Array((line + "\r\n").utf8)) }
        var frozenTopRowSteps = 0
        var probe = terminal
        _ = probe.drainDamage()

        let steps = (0..<100).map { _ in Array((line + "\r\n").utf8) }
        for bytes in steps {
            let before = probe.scrollProjection.topRow
            probe.feed(bytes)
            if probe.scrollProjection.topRow == before { frozenTopRowSteps += 1 }
        }
        #expect(frozenTopRowSteps > 50, "budget too large to reach the frozen-topRow regime")

        let shifted = assertReuseEqualsScratch(
            terminal: &terminal,
            steps: steps,
            context: "at-budget streaming"
        )
        #expect(shifted == 100)
    }

    @Test("a DECSTBM footer stays reusable while the region above it scrolls")
    func regionScrollWithPinnedFooter() throws {
        // The inline-viewport TUI shape: a footer pinned with CSI r while the
        // transcript region scrolls. Footer rows reuse untranslated; region rows
        // reuse across the shift.
        var terminal = try #require(Terminal(columns: 60, rows: 12))
        prefill(&terminal, rows: 12)
        terminal.feed(Array("\u{1B}[1;9r\u{1B}[9;1H".utf8))
        let steps = (0..<20).map { _ in Array((line + "\r\n").utf8) }
        let shifted = assertReuseEqualsScratch(
            terminal: &terminal,
            steps: steps,
            context: "DECSTBM footer"
        )
        #expect(shifted == 20)
    }

    @Test("alternate-screen scrolls plan identically through translated reuse")
    func alternateScreenScrolling() throws {
        var terminal = try #require(Terminal(columns: 60, rows: 12))
        terminal.feed(Array("\u{1B}[?1049h".utf8))
        prefill(&terminal, rows: 12)
        let steps = (0..<20).map { _ in Array((line + "\r\n").utf8) }
        let shifted = assertReuseEqualsScratch(
            terminal: &terminal,
            steps: steps,
            context: "alternate screen"
        )
        #expect(shifted == 20)
    }

    @Test("a baked selection translates exactly with a whole-viewport push")
    func selectionRidesWholeViewportShift() throws {
        // The one overlay-active scroll the engine still records as a shift: the
        // retained rows carry the selection baked in, and the equality against a
        // fresh traversal is what proves the baked highlight lands where the
        // stream-anchored selection now projects.
        var terminal = try #require(Terminal(columns: 60, rows: 20))
        prefill(&terminal, rows: 20)
        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 5, column: 0),
            end: TerminalTextPosition(row: 6, column: 12)
        ))
        let steps = (0..<15).map { _ in Array((line + "\r\n").utf8) }
        let shifted = assertReuseEqualsScratch(
            terminal: &terminal,
            steps: steps,
            context: "selection over push scroll"
        )
        #expect(shifted == 15)
    }

    @Test("overlay fallbacks still plan identically where translation is refused")
    func overlayFallbacksPlanIdentically() throws {
        // Region scroll under a selection falls back to region-row damage, and a
        // scrolled-back mutation to `.full`; both must keep the reuse equality.
        var terminal = try #require(Terminal(columns: 60, rows: 12))
        prefill(&terminal, rows: 12)
        terminal.feed(Array("\u{1B}[3;10r\u{1B}[10;1H".utf8))
        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 3, column: 0),
            end: TerminalTextPosition(row: 3, column: 8)
        ))
        let steps = (0..<10).map { _ in Array((line + "\r\n").utf8) }
        let shifted = assertReuseEqualsScratch(
            terminal: &terminal,
            steps: steps,
            context: "selection over region scroll"
        )
        #expect(shifted == 0)
    }

    @Test("mid-screen line edits translate the cursor bake correctly")
    func insertAndDeleteLinesAroundTheCursor() throws {
        // IL/DL with the cursor inside the shifted range is where the previous
        // frame's baked block cursor rides the translation: both its destination
        // row and the cursor's own row must replan, or the equality breaks with
        // a ghost cursor.
        var terminal = try #require(Terminal(columns: 60, rows: 12))
        prefill(&terminal, rows: 12)
        terminal.feed(Array("\u{1B}[6;5H".utf8))
        var steps: [[UInt8]] = []
        for _ in 0..<6 {
            steps.append(Array("\u{1B}[2L".utf8))
            steps.append(Array("\u{1B}[1M".utf8))
            steps.append(Array("\u{1B}M".utf8))
        }
        let shifted = assertReuseEqualsScratch(
            terminal: &terminal,
            steps: steps,
            context: "IL/DL around cursor"
        )
        #expect(shifted > 0)
    }
}
