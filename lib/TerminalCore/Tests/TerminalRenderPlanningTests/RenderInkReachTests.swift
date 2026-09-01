// Behavioral proofs for the derived glyph halo's two pure halves (research/33
// T14, D9): per-row ink reach classified from a plan's runs, and the
// erase-span/plan-row shape an incremental render derives from damage plus
// old and new reaches. Byte-level correctness lives in FrameBackingStoreTests;
// these pin the countable shape the task claims.
import Testing

import TerminalCore
@testable import TerminalRenderPlanning

struct RenderInkReachTests {
    /// The canonical 2x geometry: 31 px cell, measured ASCII envelope of a
    /// 4 px top margin and 2 px descender overshoot (t14-ink-envelope-probe).
    private let cellHeight = 31
    private let envelope = RenderInkEnvelope(inkTopOffsetPixels: 4, inkBottomOffsetPixels: 2)

    private var hiddenCursor: RenderPresentation {
        RenderPresentation(theme: .dark, isCursorVisible: false, cursorShape: .block)
    }

    private func plan(
        rows: Int = 6,
        columns: Int = 20,
        feeding bytes: [UInt8],
        cursorVisible: Bool = false
    ) throws -> RenderFramePlan {
        var terminal = try #require(Terminal(columns: columns, rows: rows))
        terminal.feed(bytes)
        return planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: cursorVisible,
                cursorShape: .block
            )
        )
    }

    @Test("an all-ASCII row reaches exactly the measured envelope")
    func asciiRowReach() throws {
        let plan = try plan(feeding: Array("ascii gjpqy\r\n".utf8))
        let reaches = renderRowReaches(of: plan, envelope: envelope, cellHeightPixels: cellHeight)
        #expect(reaches[0] == RenderRowReach(lowerOffsetPixels: 4, upperOffsetPixels: 33))
    }

    @Test("a single-scalar non-ASCII cell widens its row to the full-cell reach")
    func generalRowReach() throws {
        // U+00E9 is mapped by the styled face's wider cmap and submitted
        // unclipped, so its extents are not vouched for by the ASCII envelope.
        let plan = try plan(feeding: Array("caf\u{E9}\r\n".utf8))
        let reaches = renderRowReaches(of: plan, envelope: envelope, cellHeightPixels: cellHeight)
        #expect(reaches[0] == RenderRowReach(lowerOffsetPixels: -31, upperOffsetPixels: 62))
    }

    @Test("a multi-scalar cluster contributes only its clipped cell band")
    func clusterRowReach() throws {
        // e + combining acute draws through drawTextCell, which clips to the
        // cell; beside ASCII the row's reach is the union of band and envelope.
        let plan = try plan(feeding: Array("e\u{0301}x\r\n".utf8))
        let reaches = renderRowReaches(of: plan, envelope: envelope, cellHeightPixels: cellHeight)
        #expect(reaches[0] == RenderRowReach(lowerOffsetPixels: 0, upperOffsetPixels: 33))
    }

    @Test("a sprite-only row contributes only its cell band")
    func spriteRowReach() throws {
        // Intent: cells the executor draws as sprites are priced at the band
        //   their family declares, not at the font's unmeasured full-cell halo.
        // Why it exists: a TUI made of borders, blocks, and braille is the
        //   content the terminal renders fastest, and mispricing it erased and
        //   replanned three rows of pixels for every damaged row.
        // Scenario: one row of box drawing, block elements, and braille -- no
        //   ASCII and no accents, so the row's reach is the sprite class alone.
        let plan = try plan(feeding: Array("\u{250C}\u{2500}\u{2510}\u{2588}\u{28FF}\r\n".utf8))
        let reaches = renderRowReaches(of: plan, envelope: envelope, cellHeightPixels: cellHeight)
        #expect(reaches[0] == RenderRowReach(lowerOffsetPixels: 0, upperOffsetPixels: 31))
    }

    @Test("scalars no family decodes keep the full-cell reach")
    func spriteNonMembersKeepGeneralReach() throws {
        // Intent: only an exact sprite member is priced as a band. An interior
        //   gap of a family's coarse range and an above-floor scalar in no
        //   family both fall to the font, whose extents are unmeasured.
        // Why it exists: pricing a font-bound scalar as band would leave stale
        //   ink above and below its row -- a correctness regression, not a
        //   missed optimization.
        // Scenario: U+1FBB0 sits in a gap between legacy-computing's
        //   implemented spans; U+2605 is above the sprite floor and in no
        //   family's range at all.
        for scalar in ["\u{1FBB0}", "\u{2605}"] {
            let plan = try plan(feeding: Array((scalar + "\r\n").utf8))
            let reaches = renderRowReaches(
                of: plan,
                envelope: envelope,
                cellHeightPixels: cellHeight
            )
            #expect(reaches[0] == RenderRowReach(lowerOffsetPixels: -31, upperOffsetPixels: 62))
        }
    }

    @Test("rows with no drawing have no reach, and band layers contribute the band")
    func emptyAndBandRows() throws {
        // Row 0 text, row 2 colored background via SGR, rows 1 and 3+ empty.
        let bytes = Array("text\r\n\r\n\u{1B}[44m    \u{1B}[0m\r\n".utf8)
        let plan = try plan(feeding: bytes)
        let reaches = renderRowReaches(of: plan, envelope: envelope, cellHeightPixels: cellHeight)
        #expect(reaches[0] != nil)
        #expect(reaches[1] == nil)
        // The background run pins the row's reach to start at its band top,
        // whether or not the planner also emits text runs for the spaces.
        #expect(reaches[2]?.lowerOffsetPixels == 0)
        #expect((reaches[2]?.upperOffsetPixels ?? 0) >= 31)
        #expect(reaches[4] == nil)
    }

    @Test("the cursor row carries at least its band even with no text")
    func cursorRowReach() throws {
        let plan = try plan(feeding: [], cursorVisible: true)
        let reaches = renderRowReaches(of: plan, envelope: envelope, cellHeightPixels: cellHeight)
        #expect(reaches[0] == RenderRowReach(lowerOffsetPixels: 0, upperOffsetPixels: 31))
    }

    @Test("a nil envelope degrades ASCII rows to the full-cell reach")
    func nilEnvelopeDegrades() throws {
        let plan = try plan(feeding: Array("ascii\r\n".utf8))
        let reaches = renderRowReaches(of: plan, envelope: nil, cellHeightPixels: cellHeight)
        #expect(reaches[0] == RenderRowReach(lowerOffsetPixels: -31, upperOffsetPixels: 62))
    }

    @Test("partial reuse preserves copied, transitioned, and band-only row reaches")
    func partialReusePreservesRowReaches() throws {
        // Intent: row reach remains identical to fresh planning when retained
        //   rows copy forward and damaged rows change their ink facts.
        // Why it exists: the plan now carries the classifier result with each
        //   row, so reuse must replace it exactly when that row's runs change.
        // Scenario: one update leaves an ASCII row untouched, another row
        //   transitions ASCII -> accented -> ASCII, and a third gains then
        //   loses a background band while otherwise empty.
        var terminal = try #require(Terminal(columns: 20, rows: 6))
        terminal.feed(Array("copied ascii\r\ntransition ascii\r\n\r\ntail".utf8))
        _ = terminal.drainDamage()

        var planner = PaneFramePlanner()
        _ = planner.planFrame(for: terminal, searchReadout: terminal.searchReadout, presentation: hiddenCursor, damage: .full)

        let updates: [(bytes: String, row: Int, expected: RenderRowReach?)] = [
            (
                "\u{1B}[2;1Hcaf\u{E9}\u{1B}[K",
                1,
                RenderRowReach(lowerOffsetPixels: -31, upperOffsetPixels: 62)
            ),
            (
                "\u{1B}[2;1Hplain ascii\u{1B}[K",
                1,
                RenderRowReach(lowerOffsetPixels: 4, upperOffsetPixels: 33)
            ),
            (
                "\u{1B}[3;1H\u{1B}[44m\u{1B}[2K\u{1B}[0m",
                2,
                RenderRowReach(lowerOffsetPixels: 0, upperOffsetPixels: 31)
            ),
            ("\u{1B}[3;1H\u{1B}[2K", 2, nil),
        ]
        for update in updates {
            terminal.feed(Array(update.bytes.utf8))
            let damage = terminal.drainDamage()
            try #require(damage.isFull == false)
            try #require(damage.shift == nil)
            try #require(damage.contains(row: 0) == false)

            let reused = planner.planFrame(
                for: terminal,
                searchReadout: terminal.searchReadout,
                presentation: hiddenCursor,
                damage: damage
            )
            let fresh = planFrame(for: terminal, presentation: hiddenCursor)
            let reusedReaches = renderRowReaches(
                of: reused,
                envelope: envelope,
                cellHeightPixels: cellHeight
            )
            let freshReaches = renderRowReaches(
                of: fresh,
                envelope: envelope,
                cellHeightPixels: cellHeight
            )
            #expect(reusedReaches == freshReaches)
            #expect(reusedReaches[0] == RenderRowReach(lowerOffsetPixels: 4, upperOffsetPixels: 33))
            #expect(reusedReaches[update.row] == update.expected)
        }

        let final = planner.planFrame(for: terminal, searchReadout: terminal.searchReadout, presentation: hiddenCursor, damage: .none)
        let reaches = renderRowReaches(of: final, envelope: envelope, cellHeightPixels: cellHeight)
        #expect(reaches[0] == RenderRowReach(lowerOffsetPixels: 4, upperOffsetPixels: 33))
        #expect(reaches[1] == RenderRowReach(lowerOffsetPixels: 4, upperOffsetPixels: 33))
        #expect(reaches[2] == nil)
    }

    @Test("translated reuse preserves reaches for viewport and DECSTBM scrolls")
    func translatedReusePreservesRowReaches() throws {
        // Intent: translated rows carry the same reach as a fresh traversal.
        // Why it exists: relocation rewrites each run's row coordinate but
        //   must not reclassify or drop the content facts stored beside it.
        // Scenario: a mixed-content viewport scrolls once, then a bounded
        //   region containing mixed rows scrolls while its footer stays put.
        for setupAndStep in [
            (
                "ascii\r\ncaf\u{E9}\r\nplain\r\nmore\r\ntail\r\nbottom\r",
                "new line\r\n"
            ),
            (
                "ascii\r\ncaf\u{E9}\r\nplain\r\nmore\r\nfooter\r\nbottom\r"
                    + "\u{1B}[2;5r\u{1B}[5;1H",
                "region line\r\n"
            ),
        ] {
            var terminal = try #require(Terminal(columns: 20, rows: 6))
            terminal.feed(Array(setupAndStep.0.utf8))
            _ = terminal.drainDamage()

            var planner = PaneFramePlanner()
            _ = planner.planFrame(for: terminal, searchReadout: terminal.searchReadout, presentation: hiddenCursor, damage: .full)
            terminal.feed(Array(setupAndStep.1.utf8))
            let damage = terminal.drainDamage()
            try #require(damage.isFull == false)
            try #require((damage.shift?.delta ?? 0) != 0)

            let reused = planner.planFrame(
                for: terminal,
                searchReadout: terminal.searchReadout,
                presentation: hiddenCursor,
                damage: damage
            )
            let fresh = planFrame(for: terminal, presentation: hiddenCursor)
            #expect(
                renderRowReaches(of: reused, envelope: envelope, cellHeightPixels: cellHeight)
                    == renderRowReaches(of: fresh, envelope: envelope, cellHeightPixels: cellHeight)
            )
        }
    }

    private func asciiReaches(rows: Int) -> [RenderRowReach?] {
        Array(
            repeating: RenderRowReach(lowerOffsetPixels: 4, upperOffsetPixels: 33),
            count: rows
        )
    }

    @Test("an ASCII damaged row erases its band plus the overshoot and plans itself and the neighbor above")
    func asciiSteadyStateShape() {
        // Intent: the countable claim -- 2 planned rows and a sub-cell erase
        //   band where the pre-T14 shape erased 3 full rows and planned 5.
        // Why it exists: this is the shape the t5 gate's glyph fall rests on.
        // Scenario: one damaged row mid-grid, every row all-ASCII.
        let reaches = asciiReaches(rows: 20)
        let shape = renderApplyShape(
            damage: TerminalDamage(rows: [10], rowCount: 20),
            rowCount: 20,
            cellHeightPixels: cellHeight,
            oldReaches: reaches,
            newReaches: reaches
        )
        #expect(shape.erasePixelSpans == [310..<343])
        #expect(shape.planDamage.rowIndices == [9, 10])
    }

    @Test("a general damaged row reproduces the pre-T14 reach as its worst case")
    func generalDamagedRowShape() {
        var reaches = asciiReaches(rows: 20)
        reaches[10] = RenderRowReach(lowerOffsetPixels: -31, upperOffsetPixels: 62)
        let shape = renderApplyShape(
            damage: TerminalDamage(rows: [10], rowCount: 20),
            rowCount: 20,
            cellHeightPixels: cellHeight,
            oldReaches: reaches,
            newReaches: reaches
        )
        // Erase covers rows 9 through 11 whole; every row whose ink reaches
        // that region is planned. Row 12's ink starts 4 px below the erase
        // edge, so the halo-of-halo's fifth row is gone even in the worst case.
        #expect(shape.erasePixelSpans == [279..<372])
        #expect(shape.planDamage.rowIndices == [8, 9, 10, 11])
    }

    @Test("a damaged sprite row erases one band and plans only itself")
    func spriteDamagedRowShape() throws {
        // Intent: the countable win -- one band erased and one row planned,
        //   against `generalDamagedRowShape`'s three rows of pixels and four
        //   planned rows for the same single-row damage.
        // Why it exists: this is the whole point of pricing sprite cells as
        //   the band; no benchmark currently resolves the wall-clock effect,
        //   so the shape is the verification.
        // Scenario: a grid of box-drawing rows with one row damaged mid-grid.
        let rows = 20
        let line = "\u{250C}\u{2500}\u{2510}"
        let plan = try plan(
            rows: rows,
            feeding: Array(Array(repeating: line, count: rows).joined(separator: "\r\n").utf8)
        )
        let reaches = renderRowReaches(of: plan, envelope: envelope, cellHeightPixels: cellHeight)
        let shape = renderApplyShape(
            damage: TerminalDamage(rows: [10], rowCount: rows),
            rowCount: rows,
            cellHeightPixels: cellHeight,
            oldReaches: reaches,
            newReaches: reaches
        )
        #expect(shape.erasePixelSpans == [310..<341])
        #expect(shape.planDamage.rowIndices == [10])
    }

    @Test("stale general ink forces the wide erase through the old reach alone")
    func classTransitionUsesOldReach() {
        // Intent: a row rewritten from non-ASCII to ASCII still erases the
        //   full-cell band its stale ink may occupy.
        // Why it exists: the ledger is what makes the derived halo sound
        //   across content transitions; using only the new reach would leave
        //   the old accent's ink above the row.
        var old = asciiReaches(rows: 20)
        old[10] = RenderRowReach(lowerOffsetPixels: -31, upperOffsetPixels: 62)
        let new = asciiReaches(rows: 20)
        let shape = renderApplyShape(
            damage: TerminalDamage(rows: [10], rowCount: 20),
            rowCount: 20,
            cellHeightPixels: cellHeight,
            oldReaches: old,
            newReaches: new
        )
        #expect(shape.erasePixelSpans == [279..<372])
        #expect(shape.planDamage.rowIndices == [8, 9, 10, 11])
    }

    @Test("an empty damaged row still erases its band and replans the descenders above")
    func emptyDamagedRow() {
        var reaches = asciiReaches(rows: 20)
        reaches[10] = nil
        let shape = renderApplyShape(
            damage: TerminalDamage(rows: [10], rowCount: 20),
            rowCount: 20,
            cellHeightPixels: cellHeight,
            oldReaches: reaches,
            newReaches: reaches
        )
        #expect(shape.erasePixelSpans == [310..<341])
        #expect(shape.planDamage.rowIndices == [9])
    }

    @Test("adjacent damaged rows merge into one erase span")
    func adjacentSpansMerge() {
        let reaches = asciiReaches(rows: 20)
        let shape = renderApplyShape(
            damage: TerminalDamage(rows: [4, 3], rowCount: 20),
            rowCount: 20,
            cellHeightPixels: cellHeight,
            oldReaches: reaches,
            newReaches: reaches
        )
        #expect(shape.erasePixelSpans == [93..<157])
        #expect(shape.planDamage.rowIndices == [2, 3, 4])
    }

    @Test("erase spans clamp to the frame at both edges")
    func edgeRowsClamp() {
        let reaches = asciiReaches(rows: 4)
        let top = renderApplyShape(
            damage: TerminalDamage(rows: [0], rowCount: 4),
            rowCount: 4,
            cellHeightPixels: cellHeight,
            oldReaches: reaches,
            newReaches: reaches
        )
        #expect(top.erasePixelSpans == [0..<33])
        #expect(top.planDamage.rowIndices == [0])
        let bottom = renderApplyShape(
            damage: TerminalDamage(rows: [3], rowCount: 4),
            rowCount: 4,
            cellHeightPixels: cellHeight,
            oldReaches: reaches,
            newReaches: reaches
        )
        #expect(bottom.erasePixelSpans == [93..<124])
        #expect(bottom.planDamage.rowIndices == [2, 3])
    }

    @Test("a colored-background neighbor below is replanned when the overshoot band bites it")
    func backgroundNeighborIsPlanned() {
        // Intent: a sub-pixel erase intrusion into a row with band content
        //   replans that row instead of refilling it with default background.
        var reaches = asciiReaches(rows: 20)
        reaches[11] = RenderRowReach(lowerOffsetPixels: 0, upperOffsetPixels: 31)
        let shape = renderApplyShape(
            damage: TerminalDamage(rows: [10], rowCount: 20),
            rowCount: 20,
            cellHeightPixels: cellHeight,
            oldReaches: reaches,
            newReaches: reaches
        )
        #expect(shape.erasePixelSpans == [310..<343])
        #expect(shape.planDamage.rowIndices == [9, 10, 11])
    }
}
