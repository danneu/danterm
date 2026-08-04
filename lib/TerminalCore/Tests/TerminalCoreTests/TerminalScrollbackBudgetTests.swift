// Behavioral proofs for deterministic scrollback accounting, eviction, and truncation state.
import Testing

@testable import TerminalCore

/// Locks the fixed byte budget to every history mutation path without coupling tests to storage.
struct TerminalScrollbackBudgetTests {
    @Test("widening preserves hard-terminated history that already fits the budget")
    func wideningDoesNotEvictCompactHistory() throws {
        // Intent: widening a pane preserves every retained hard-terminated line and its order.
        // Why it exists: full-width history rows were re-padded during reflow, increasing their
        //   budget charge and silently evicting the oldest content during an ordinary resize.
        // Scenario: four short shell-output lines fill a modest-width pane's history budget, then
        //   the user doubles the pane width without changing the logical lines.
        var terminal = try #require(Terminal(
            columns: 8,
            rows: 1,
            scrollbackBudgetBytes: historyRowCost(columns: 8) * 4
        ))
        terminal.feed(Array("A\r\nB\r\nC\r\nD\r\n".utf8))
        let before = terminal.primaryHistoryText
        let rowCount = terminal.scrollbackRowCount

        terminal.resize(columns: 16, rows: 1)

        #expect(terminal.primaryHistoryText == before)
        #expect(terminal.scrollbackRowCount == rowCount)
        #expect(terminal.scrollbackByteCount == terminal.recomputedScrollbackByteCount)
    }

    @Test("short compact lines retain deeper history than full-width lines at one budget")
    func compactLineLengthControlsRetentionDepth() throws {
        // Intent: a fixed byte budget retains more short rows than full-width rows.
        // Why it exists: compact storage is useful only if its smaller allocation charge turns
        //   into user-visible history depth rather than merely changing a diagnostic counter.
        // Scenario: equal-width panes stream ten one-cell and ten full-width hard lines.
        //
        // Widened from 8 columns to 80 by doc 28's packing. A packed row's cost is a fixed
        // slot and header plus a payload roughly one byte per stored cell, so at 8 columns a
        // one-cell row and a full-width row now land in the same malloc size class and retain
        // identically. That is not a failure of the property -- it is `D3`'s admission test
        // seen from the other side, and it says the depth difference has to clear a bucket
        // step to exist at all. At a real pane width it clears it comfortably.
        let columns = 80
        let budget = historyRowCost(columns: columns) * 2
        var short = try #require(Terminal(
            columns: columns,
            rows: 1,
            scrollbackBudgetBytes: budget
        ))
        var full = try #require(Terminal(
            columns: columns,
            rows: 1,
            scrollbackBudgetBytes: budget
        ))
        for _ in 0..<10 {
            short.feed(Array("x\r\n".utf8))
            full.feed(Array(String(repeating: "1234567890", count: 8).utf8))
            full.feed(Array("\r\n".utf8))
        }

        #expect(short.scrollbackRowCount > full.scrollbackRowCount)
        #expect(short.scrollbackByteCount <= budget)
        #expect(full.scrollbackByteCount <= budget)
    }

    @Test("equivalent resize routes converge to one canonical retained representation")
    func compactHistoryIsCanonicalAcrossResizeRoutes() throws {
        // Intent: equal terminal content reached through different retained widths compares equal.
        // Why it exists: synthesized equality includes private row storage, so non-canonical blank
        //   tails would make observably identical terminals unequal and break no-op detection.
        // Scenario: one pane retains a line narrowly then widens; its twin starts wide.
        var resized = try #require(Terminal(columns: 4, rows: 1))
        resized.feed(Array("abc\r\n".utf8))
        resized.resize(columns: 8, rows: 1)

        var direct = try #require(Terminal(columns: 8, rows: 1))
        direct.feed(Array("abc\r\n".utf8))

        #expect(resized == direct)
    }

    @Test("history never reserves more than the budget, at widths where rows round up")
    func budgetChargesReservedStorageNotJustCells() throws {
        // Intent: the bytes history actually reserves stay inside the configured budget, not just
        //   the bytes its cells nominally occupy.
        // Why it exists: `scrollbackByteCost` charged `count * stride`, but a row's cell array is
        //   allocated in a malloc bucket and reserves more than that -- 90 cells' worth at 80
        //   columns, 218 at 200. So the budget systematically admitted rows it could not pay for,
        //   which doc 15's `F7` measured at ~11.5% and `F12` turned into a 1.8 MB regression by
        //   shrinking a cell in a way the allocator ignored. Charging reserved storage makes the
        //   number the user configures mean what it says regardless of what a cell weighs.
        // Scenario: a pane at ordinary widths streams enough history to force steady eviction.
        for columns in [80, 200] {
            var terminal = try #require(Terminal(
                columns: columns,
                rows: 4,
                scrollbackBudgetBytes: 400 * historyRowCost(columns: columns)
            ))
            for line in 0..<2_000 {
                terminal.feed(Array("row \(line) ".utf8))
                terminal.feed([0x0D, 0x0A])
            }

            #expect(terminal.scrollbackRowCount > 0)
            #expect(terminal.retainedScrollbackAllocationBytes <= terminal.scrollbackBudgetBytes)
        }
    }

    @Test("scrollback cost uses pinned row, cell, and scalar literals")
    func costModelUsesPinnedLiterals() throws {
        // Intent: freeze row, cell, and scalar costs across every structural cell shape.
        // Why it exists: eviction points are value semantics and cannot drift with a toolchain.
        // Scenario: canonical blank, ASCII, wide, spacer, and emoji rows enter history.
        //
        // Restated against doc 28's packed retained row (`C1`). Each payload below is spelled
        // out as the charges the encoding really makes -- a header, one fixed 8-byte cell per
        // stored column, and the identity encoding -- rather than as a number, because the
        // point of the fixture is that the *composition* is pinned. A scheme that stored the
        // same rows in a different mix of tables would still land on some total; it would not
        // land on these terms.
        //
        // What the terms show is `C1`'s whole argument: the scalar, the kind and the style id
        // are all inside the cell, so no fixture below names a stride tier, a style run or a
        // kind exception. `C6`'s version of this test named all three.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let charge = PackedRowCharge.self
        let fixtures: [(columns: Int, text: String, expected: Int)] = [
            // A blank row trims to one padding cell: one cell, and nothing else -- padding
            // carries no identity.
            (4, "", packedHistoryRowCost(payloadBytes: charge.header + charge.cell)),
            // Four ASCII cells and one identity run -- the shape the whole scheme is chosen
            // for, and the one where the cell's flat cost is the entire cost.
            (4, "ABCD", packedHistoryRowCost(
                payloadBytes: charge.header + 4 * charge.cell + charge.identityRun
            )),
            // A wide glyph is two cells and costs no more than two of anything else: its kind
            // rides in the cell. Head and tail share one identity, which a
            // `(start, extent, base)` run cannot express, so they are two runs -- and at two
            // stored cells the per-cell floor is cheaper, so the encoder takes it.
            (2, "\u{754C}", packedHistoryRowCost(
                payloadBytes: charge.header + 2 * charge.cell + 2 * charge.identityCell
            )),
            // The only shape that costs more, and the only one that still reaches outside the
            // cell: a five-scalar cluster spills to its own allocation, reached by an index
            // the cell's scalar field holds in place of a scalar.
            (2, family, packedHistoryRowCost(
                payloadBytes: charge.header + 2 * charge.cell + 2 * charge.identityCell,
                spilledClusterScalars: [5]
            )),
        ]

        for fixture in fixtures {
            var terminal = try #require(Terminal(columns: fixture.columns, rows: 1))
            terminal.feed(Array(fixture.text.utf8))
            terminal.feed([0x0D, 0x0A])

            #expect(terminal.scrollbackRowByteCost(at: 0) == fixture.expected)
            #expect(terminal.scrollbackByteCount == fixture.expected)
            #expect(terminal.recomputedScrollbackByteCount == fixture.expected)
        }

        var spacer = try #require(Terminal(columns: 3, rows: 1))
        spacer.moveCursor(row: 0, column: 2)
        spacer.feed(Array("\u{754C}".utf8))
        #expect(spacer.scrollbackRow(at: 0)?.cells.last?.kind == .spacerHead)
        // Two untouched padding cells, then the spacer: three cells and the spacer's own
        // identity run. The spacer's kind costs nothing extra -- it is three bits of a cell
        // the row was already paying for.
        #expect(spacer.scrollbackRowByteCost(at: 0) == packedHistoryRowCost(
            payloadBytes: PackedRowCharge.header + 3 * PackedRowCharge.cell
                + PackedRowCharge.identityRun
        ))

        let production = try #require(Terminal(columns: 4, rows: 2))
        let overridden = try #require(Terminal(
            columns: 4,
            rows: 2,
            scrollbackBudgetBytes: Terminal.productionScrollbackBudgetBytes - 1
        ))
        #expect(production != overridden)
    }

    @Test("exact budget retains and overshoot evicts the minimal oldest prefix")
    func exactBoundaryAndMinimalEviction() throws {
        // Intent: prove the strict-over trigger and minimal oldest-first batch removal.
        // Why it exists: an off-by-one would discard history at the documented boundary.
        // Scenario: two rows fill a tiny budget before one push and one shrink overshoot it.
        let rowCost = compactHistoryRowCost(storedCells: 1)
        var terminal = try #require(Terminal(
            columns: 2,
            rows: 1,
            scrollbackBudgetBytes: rowCost * 2
        ))

        terminal.feed(Array("A\r\nB\r\n".utf8))
        #expect(terminal.scrollbackRowCount == 2)
        #expect(terminal.scrollbackByteCount == rowCost * 2)
        #expect(terminal.scrollbackRow(at: 0)?.cells[0].scalars == ["A"])

        terminal.feed(Array("C\r\n".utf8))
        #expect(terminal.scrollbackRowCount == 2)
        #expect(terminal.scrollbackByteCount == rowCost * 2)
        #expect(terminal.scrollbackRow(at: 0)?.cells[0].scalars == ["B"])
        #expect(terminal.scrollbackRow(at: 1)?.cells[0].scalars == ["C"])

        var batch = try #require(Terminal(
            columns: 2,
            rows: 4,
            scrollbackBudgetBytes: rowCost * 2
        ))
        batch.feed(Array("A\r\nB\r\nC\r\nD".utf8))
        batch.resize(columns: 2, rows: 1)
        #expect(batch.scrollbackRowCount == 2)
        #expect(batch.scrollbackRow(at: 0)?.cells[0].scalars == ["B"])
        #expect(batch.scrollbackRow(at: 1)?.cells[0].scalars == ["C"])
        expectValidGrid(batch)
    }

    @Test("the row cap evicts oldest-first once cheap rows outrun it, with the budget unspent")
    func rowCapBoundsDepthOnCheapRows() throws {
        // Intent: retained depth stops at the row cap even when the byte budget has
        //   room left, and the rows that survive are the newest ones.
        // Why it exists: doc 28's `D8`. Packing made a retained row ~14x cheaper, so
        //   a byte-only bound admits ~82,000 rows of ordinary content and ~125,000 of
        //   sparse -- and reflow visits every one of them, which `F14` measured as a
        //   1.43 s resize. The row cap bounds reflow's per-row term, and it has to bind
        //   on the *cheap* side where neither the budget nor the cell cap will: these
        //   rows are 6 cells each, so 64 rows is 384 cells.
        // Scenario: a shell history of short commands -- the content regime that
        //   retains deepest, and the one `saturated-sparse-resize-v1` measures.
        let cap = 64
        var terminal = try #require(Terminal(
            columns: 40,
            rows: 1,
            scrollbackBudgetBytes: Terminal.productionScrollbackBudgetBytes,
            scrollbackRowCap: cap,
            scrollbackCellCap: Terminal.productionScrollbackCellCap
        ))

        for line in 0..<(cap * 4) {
            terminal.feed(Array("cmd\(line)\r\n".utf8))
        }

        #expect(terminal.scrollbackRowCount == cap)
        // The budget is nowhere near spent: the cap, not the bytes, decided.
        #expect(terminal.scrollbackByteCount < Terminal.productionScrollbackBudgetBytes / 100)
        // Oldest-first, so the newest `cap` rows are what survived.
        let retained = terminal.primaryHistoryText.split(separator: "\n").map(String.init)
        #expect(retained.first == "cmd\(cap * 4 - cap)")
        #expect(retained.last == "cmd\(cap * 4 - 1)")
        #expect(terminal.scrollbackByteCount == terminal.recomputedScrollbackByteCount)
        #expect(terminal.scrollbackStoredCellCount == terminal.recomputedScrollbackStoredCellCount)
        expectValidGrid(terminal)
    }

    @Test("the cell cap bounds retained cells once rows are wide, before the row cap is near")
    func cellCapBoundsWideRows() throws {
        // Intent: retained depth stops at the cell cap when rows are wide enough to reach
        //   it first, with the row cap and the byte budget both unspent.
        // Why it exists: `D8`'s cost model is two-term -- 1.85 us/row + 0.352 us/cell --
        //   and the cell term dominates at any real pane width. A row cap alone leaves it
        //   free: the wide arm measured 232.6 ms against a 99.5 ms pre-packing baseline
        //   while sitting well inside an 8,192-row cap. This is the bound that makes the
        //   worst case a number rather than a function of how wide the pane is.
        // Scenario: full-width program output, the regime `saturated-wide-resize-v1` runs.
        let columns = 80
        let cellCap = 800
        var terminal = try #require(Terminal(
            columns: columns,
            rows: 1,
            scrollbackBudgetBytes: Terminal.productionScrollbackBudgetBytes,
            scrollbackRowCap: 4_096,
            scrollbackCellCap: cellCap
        ))

        for _ in 0..<64 {
            terminal.feed(Array(String(repeating: "x", count: columns).utf8))
            terminal.feed(Array("\r\n".utf8))
        }

        #expect(terminal.scrollbackStoredCellCount <= cellCap)
        #expect(terminal.scrollbackRowCount == cellCap / columns)
        #expect(terminal.scrollbackRowCount < 4_096)
        #expect(terminal.scrollbackByteCount < Terminal.productionScrollbackBudgetBytes / 100)
        #expect(terminal.scrollbackStoredCellCount == terminal.recomputedScrollbackStoredCellCount)
        expectValidGrid(terminal)
    }

    @Test("narrowing then widening a capped history loses no rows")
    func narrowThenWidenPreservesCappedHistory() throws {
        // Intent: a width change and its inverse leave retained history exactly as deep as
        //   it started, under both caps.
        // Why it exists: the incident is the row-cap-only design measured during `D8`. A
        //   row cap alone is not reflow-invariant -- narrowing multiplies row count while
        //   leaving content alone, so the cap evicts the overflow and widening cannot
        //   restore it. Measured directly at 179 columns with an 8,192-row cap and no cell
        //   cap: 8,192 rows -> narrow to 100 -> 8,192 -> widen back to 179 -> **4,095**.
        //   Half the user's scrollback destroyed by one window drag. The cell cap is what
        //   fixes it: stored cells are content, so rewrapping moves them between rows
        //   without creating any, and the cell cap therefore binds at a row count low
        //   enough that rewrapping never reaches the row cap.
        // Scenario: a user drags a pane narrow and back with a full history of full-width
        //   output.
        let wide = 179
        let narrow = 100
        // A one-row viewport, left blank by the trailing newline. A taller viewport holding
        // full-width content would rewrap into more rows than it can show and spill the
        // remainder into a history already sitting exactly at its cap, evicting a row for a
        // reason that has nothing to do with the caps being reflow-safe.
        var terminal = try #require(Terminal(
            columns: wide,
            rows: 1,
            scrollbackBudgetBytes: Terminal.productionScrollbackBudgetBytes,
            scrollbackRowCap: 512,
            scrollbackCellCap: 128 * wide
        ))
        for index in 0..<4_000 {
            let line = String(String(repeating: "abcdefgh\(index % 10)", count: 20).prefix(wide))
            terminal.feed(Array((line + "\r\n").utf8))
        }

        let atWide = terminal.scrollbackRowCount
        let textAtWide = terminal.primaryHistoryText
        terminal.resize(columns: narrow, rows: 1)
        let atNarrow = terminal.scrollbackRowCount
        terminal.resize(columns: wide, rows: 1)

        #expect(atWide > 0)
        // The mechanism, not just the outcome: narrowing roughly doubles row count, and the
        // cell cap is what keeps that doubling clear of the row cap. Under a row cap alone
        // this is where the eviction happened.
        #expect(atNarrow > atWide)
        #expect(atNarrow <= terminal.scrollbackRowCap)
        #expect(terminal.scrollbackRowCount == atWide)
        #expect(terminal.primaryHistoryText == textAtWide)
        #expect(terminal.scrollbackByteCount == terminal.recomputedScrollbackByteCount)
        #expect(terminal.scrollbackStoredCellCount == terminal.recomputedScrollbackStoredCellCount)
    }

    @Test("whichever bound is reached first decides, so dense rows still evict on bytes")
    func byteBudgetStillBindsBeforeTheRowCap() throws {
        // Intent: the byte budget keeps deciding depth for content expensive enough to
        //   reach it before the row cap does.
        // Why it exists: the cap is an *additional* bound, not a replacement. A cap
        //   that silently became the only bound would let pathological rows -- long,
        //   multi-scalar, wide -- allocate without limit as long as they stayed under
        //   the row count, which is the memory bound `I4` and doc 15 exist to hold.
        // Scenario: full-width rows of program output against a generous row cap.
        let columns = 200
        let rowCost = historyRowCost(columns: columns)
        let cap = 64
        var terminal = try #require(Terminal(
            columns: columns,
            rows: 1,
            scrollbackBudgetBytes: rowCost * 8,
            scrollbackRowCap: cap,
            scrollbackCellCap: Terminal.productionScrollbackCellCap
        ))

        for _ in 0..<(cap * 2) {
            terminal.feed(Array(String(repeating: "x", count: columns).utf8))
            terminal.feed(Array("\r\n".utf8))
        }

        #expect(terminal.scrollbackRowCount == 8)
        #expect(terminal.scrollbackRowCount < cap)
        #expect(terminal.scrollbackByteCount <= rowCost * 8)
        #expect(terminal.scrollbackByteCount == terminal.recomputedScrollbackByteCount)
    }

    @Test("cap-driven eviction marks a severed soft-wrapped line just as budget eviction does")
    func rowCapEvictionMarksTruncation() throws {
        // Intent: history-head truncation state is set by eviction the *cap* triggered,
        //   not only by eviction the byte budget triggered.
        // Why it exists: `isHistoryHeadTruncated` is what tells a reader the retained
        //   stream was cut inside a logical line. Adding a second eviction trigger that
        //   skipped it would leave a rejoined-looking wrapped line that is actually
        //   severed -- a wrong answer no byte accounting would catch.
        // Scenario: a soft-wrapped line scrolls off the top because the cap, not the
        //   budget, forced it out.
        let cap = 4
        var terminal = try #require(Terminal(
            columns: 4,
            rows: 1,
            scrollbackBudgetBytes: Terminal.productionScrollbackBudgetBytes,
            scrollbackRowCap: cap,
            scrollbackCellCap: Terminal.productionScrollbackCellCap
        ))

        // A single logical line long enough to soft-wrap across several retained rows.
        terminal.feed(Array(String(repeating: "w", count: 24).utf8))
        terminal.feed(Array("\r\n".utf8))
        for line in 0..<8 {
            terminal.feed(Array("h\(line)\r\n".utf8))
        }

        #expect(terminal.scrollbackRowCount == cap)
        #expect(terminal.isHistoryHeadTruncated == false)
        #expect(terminal.scrollbackByteCount == terminal.recomputedScrollbackByteCount)
    }

    @Test("public initializer enforces the fixed production row cap")
    func publicProductionRowCapCrossing() throws {
        // Intent: prove the public initializer alone wires the literal production cap.
        // Why it exists: the same gap `publicProductionBudgetCrossing` closes for the
        //   byte budget. Tiny injected caps cannot catch an omitted or wrong public
        //   default, and at ordinary pane widths the cap is now the bound that actually
        //   decides -- a short packed row costs ~108 B, so `D11`'s 89,500 rows is ~9.7 MB
        //   against a 16 MiB budget this content does not reach.
        // Scenario: sustained short-line output at a narrow width, which is exactly
        //   where a byte-only bound used to retain tens of thousands of rows.
        // The exact literals are pinned by `publicProductionBoundsCrossing`; this test
        // asks whether the public initializer crosses whatever that constant is.
        let cap = Terminal.productionScrollbackRowCap
        var terminal = try #require(Terminal(columns: 8, rows: 1))

        for line in 0..<(cap + 500) {
            terminal.feed(Array("c\(line % 10)\r\n".utf8))
        }

        #expect(terminal.scrollbackRowCount == cap)
        #expect(terminal.scrollbackByteCount < Terminal.productionScrollbackBudgetBytes)
        #expect(terminal.scrollbackByteCount == terminal.recomputedScrollbackByteCount)
    }

    @Test("eviction marks only a soft-wrapped cut and preserves retained structure")
    func truncationTracksLastEvictedBoundary() throws {
        // Intent: derive truncation from the last removed row without editing retained cells.
        // Why it exists: only the deleted predecessor records whether the head is mid-line.
        // Scenario: soft, hard, spacer/wide, and over-budget cluster cuts cross the seam.
        let oneASCII = historyRowCost(columns: 2)
        var soft = try #require(Terminal(
            columns: 2,
            rows: 1,
            scrollbackBudgetBytes: oneASCII
        ))
        soft.feed(Array("ABCDE".utf8))

        #expect(soft.scrollbackRowCount == 1)
        #expect(soft.scrollbackRow(at: 0)?.cells.map(\.scalars) == [["C"], ["D"]])
        #expect(soft.primaryHistoryText == "CDE")
        #expect(soft.isHistoryHeadTruncated)

        soft.feed(Array("\r\nF\r\n".utf8))
        #expect(soft.isHistoryHeadTruncated == false)
        expectValidGrid(soft)

        var spacer = try #require(Terminal(
            columns: 3,
            rows: 1,
            scrollbackBudgetBytes: historyRowCost(columns: 3)
        ))
        spacer.moveCursor(row: 0, column: 2)
        spacer.feed(Array("\u{754C}ABCD".utf8))
        expectValidGrid(spacer)

        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        var giant = try #require(Terminal(
            columns: 2,
            rows: 1,
            scrollbackBudgetBytes: historyRowCost(columns: 2)
        ))
        giant.feed(Array((family + "Z").utf8))
        #expect(giant.scrollbackRowCount == 0)
        #expect(giant.scrollbackByteCount == 0)
        #expect(giant.screenText == "Z ")
        #expect(giant.isHistoryHeadTruncated)
        expectValidGrid(giant)
    }

    @Test("ED 3 clears truncation and accounting before history restarts")
    func eraseDisplayThreeResetsBudgetState() throws {
        // Intent: reset both derived byte state and eviction metadata with explicit erasure.
        // Why it exists: stale accounting would corrupt every later enforcement decision.
        // Scenario: an application clears truncated history, then starts a new transcript.
        var terminal = try #require(Terminal(
            columns: 2,
            rows: 1,
            scrollbackBudgetBytes: historyRowCost(columns: 2)
        ))
        terminal.feed(Array("ABCDE".utf8))
        #expect(terminal.isHistoryHeadTruncated)
        #expect(terminal.scrollbackByteCount > 0)

        terminal.feed(Array("\u{1B}[3J".utf8))
        #expect(terminal.scrollbackRowCount == 0)
        #expect(terminal.scrollbackByteCount == 0)
        #expect(terminal.recomputedScrollbackByteCount == 0)
        #expect(terminal.isHistoryHeadTruncated == false)

        terminal.feed(Array("\r\nX\r\n".utf8))
        #expect(terminal.scrollbackRowCount == 1)
        #expect(terminal.scrollbackByteCount == terminal.recomputedScrollbackByteCount)
    }

    @Test("height and width resize enforce the budget after preserving retained suffixes")
    func resizePathsEnforceBudget() throws {
        // Intent: enforce after height displacement and width reflow at the new row cost.
        // Why it exists: both paths can exceed the budget without a parser-driven scroll.
        // Scenario: a pane shrinks, narrows, regrows, and reflows an already-truncated head.
        let oneCellRowCost = historyRowCost(columns: 2)
        var height = try #require(Terminal(
            columns: 2,
            rows: 4,
            scrollbackBudgetBytes: oneCellRowCost * 2
        ))
        height.feed(Array("A\r\nB\r\nC\r\nD".utf8))
        height.resize(columns: 2, rows: 1)
        #expect(height.primaryHistoryText == "B\nC\nD")
        #expect(height.scrollbackByteCount <= oneCellRowCost * 2)

        var width = try #require(Terminal(
            columns: 4,
            rows: 1,
            scrollbackBudgetBytes: historyRowCost(columns: 4) * 3
        ))
        width.feed(Array("ABCDEFGHI".utf8))
        #expect(width.scrollbackByteCount == historyRowCost(columns: 4) * 2)
        let before = width.primaryHistoryText

        width.resize(columns: 2, rows: 1)
        #expect(width.scrollbackByteCount <= historyRowCost(columns: 4) * 3)
        #expect(width.scrollbackRowCount == 3)
        #expect(before.hasSuffix(width.primaryHistoryText))
        #expect(width.isHistoryHeadTruncated)
        expectValidGrid(width)

        width.resize(columns: 2, rows: 4)
        #expect(width.scrollbackRowCount == 0)
        #expect(width.isHistoryHeadTruncated)
        #expect(width.scrollbackByteCount == 0)

        var truncated = try #require(Terminal(
            columns: 2,
            rows: 1,
            scrollbackBudgetBytes: historyRowCost(columns: 2) * 2
        ))
        truncated.feed(Array("ABCDEFG".utf8))
        #expect(truncated.isHistoryHeadTruncated)
        let truncatedText = truncated.primaryHistoryText
        truncated.resize(columns: 3, rows: 1)
        #expect(truncated.primaryHistoryText == truncatedText)
        #expect(truncated.isHistoryHeadTruncated)
        expectValidGrid(truncated)
    }

    @Test("truncating resize advances primary history generation on either screen")
    func truncatingResizeAdvancesPrimaryHistoryGeneration() throws {
        // Intent: signal recovery whenever resize eviction changes retained primary history.
        // Why it exists: generation-based recovery observation can otherwise miss a truncated
        //   history head and keep stale text after resize.
        // Scenario: a budget-filled shell narrows either directly or behind a full-screen app.
        for entersAlternateScreen in [false, true] {
            var terminal = try #require(Terminal(
                columns: 4,
                rows: 1,
                scrollbackBudgetBytes: historyRowCost(columns: 4) * 2
            ))
            terminal.feed(Array("ABCDEFGHI".utf8))
            if entersAlternateScreen {
                terminal.feed(Array("\u{1B}[?1047h".utf8))
            }
            let textBeforeResize = terminal.primaryHistoryText
            let generationBeforeResize = terminal.primaryHistoryGeneration

            terminal.resize(columns: 2, rows: 1)

            #expect(terminal.primaryHistoryText != textBeforeResize)
            #expect(terminal.primaryHistoryGeneration != generationBeforeResize)
        }
    }

    @Test("alternate scrolling is inert while alternate resize matches primary eviction")
    func alternateScreenInterplay() throws {
        // Intent: keep alternate output outside history while resizing shared primary history.
        // Why it exists: alternate mode swaps viewports but retains one primary scrollback.
        // Scenario: a full-screen app scrolls and resizes over a budget-filled shell history.
        var active = try #require(Terminal(
            columns: 4,
            rows: 1,
            scrollbackBudgetBytes: historyRowCost(columns: 4) * 2
        ))
        active.feed(Array("ABCDEFGHI".utf8))
        var alternate = active

        alternate.feed(Array("\u{1B}[?1047h123456789012".utf8))
        #expect(alternate.scrollbackRowCount == active.scrollbackRowCount)
        #expect(alternate.scrollbackByteCount == active.scrollbackByteCount)
        #expect(alternate.isHistoryHeadTruncated == active.isHistoryHeadTruncated)

        active.resize(columns: 2, rows: 1)
        alternate.resize(columns: 2, rows: 1)
        #expect(alternate.primaryHistoryText == active.primaryHistoryText)
        #expect(alternate.scrollbackRowCount == active.scrollbackRowCount)
        #expect(alternate.scrollbackByteCount == active.scrollbackByteCount)
        #expect(alternate.isHistoryHeadTruncated == active.isHistoryHeadTruncated)
        alternate.feed(Array("\u{1B}[?1047l".utf8))
        #expect(alternate.primaryHistoryText == active.primaryHistoryText)
        expectValidGrid(alternate)
    }

    @Test("eviction leaves viewport cursor and parser control behavior unchanged")
    func cursorAndControlStateAreImmune() throws {
        // Intent: isolate eviction from cursor, saved state, modes, wrap, and cluster behavior.
        // Why it exists: later input must observe only the enclosing operation's state changes.
        // Scenario: each eviction path is compared immediately with its no-eviction twin.
        let paths: [(Terminal, Terminal) throws -> (Terminal, Terminal)] = [
            { bounded, unbounded in
                var bounded = bounded
                var unbounded = unbounded
                bounded.feed(Array("C\r\n".utf8))
                unbounded.feed(Array("C\r\n".utf8))
                return (bounded, unbounded)
            },
            { bounded, unbounded in
                var bounded = bounded
                var unbounded = unbounded
                bounded.resize(columns: 2, rows: 1)
                unbounded.resize(columns: 2, rows: 1)
                return (bounded, unbounded)
            },
            { bounded, unbounded in
                var bounded = bounded
                var unbounded = unbounded
                bounded.resize(columns: 2, rows: 1)
                unbounded.resize(columns: 2, rows: 1)
                return (bounded, unbounded)
            },
        ]

        let setup: [(columns: Int, rows: Int, bytes: String, budget: Int)] = [
            (2, 1, "A\r\n", historyRowCost(columns: 2)),
            (2, 4, "A\r\nB\r\nC\r\nDE", historyRowCost(columns: 2) * 2),
            (4, 1, "ABCDEFGHI", historyRowCost(columns: 4) * 2),
        ]

        for index in paths.indices {
            var bounded = try #require(Terminal(
                columns: setup[index].columns,
                rows: setup[index].rows,
                scrollbackBudgetBytes: setup[index].budget
            ))
            var unbounded = try #require(Terminal(
                columns: setup[index].columns,
                rows: setup[index].rows,
                scrollbackBudgetBytes: .max
            ))
            let prefix = "\u{1B}[4h\u{1B}7"
            bounded.feed(Array((prefix + setup[index].bytes).utf8))
            unbounded.feed(Array((prefix + setup[index].bytes).utf8))

            var pair = try paths[index](bounded, unbounded)
            #expect(pair.0.geometry == pair.1.geometry)
            #expect(pair.0.screenText == pair.1.screenText)
            #expect(pair.0.currentStyle == pair.1.currentStyle)

            pair.0.feed(Array("\u{1B}8Z\u{0301}".utf8))
            pair.1.feed(Array("\u{1B}8Z\u{0301}".utf8))
            #expect(pair.0.geometry == pair.1.geometry)
            #expect(pair.0.screenText == pair.1.screenText)
        }

        var cluster = try #require(Terminal(
            columns: 2,
            rows: 1,
            scrollbackBudgetBytes: historyRowCost(columns: 2)
        ))
        cluster.feed(Array("ABCD".utf8))
        var clusterOracle = cluster.withUnlimitedScrollbackForTesting()
        cluster.feed(Array("E".utf8))
        clusterOracle.feed(Array("E".utf8))
        cluster.feed(Array("\u{0301}".utf8))
        clusterOracle.feed(Array("\u{0301}".utf8))
        #expect(cluster.cell(row: 0, column: 0)?.scalars == ["E", "\u{0301}"])
        #expect(cluster.geometry == clusterOracle.geometry)
        #expect(cluster.screenText == clusterOracle.screenText)
    }

    @Test("seeded budget oracle remains a suffix and replay is chunk invariant")
    func seededTwinOracleAndChunkInvariance() throws {
        // Intent: sweep all mutation families against a fresh operation-local unlimited twin.
        // Why it exists: cached totals and eviction metadata must remain coherent in composition.
        // Scenario: random input, single-axis resizes, and ED 3 replay whole and bytewise.
        let tokens = ["a", "b", " ", "\u{754C}", "\u{1F642}", "\r\n", "\n", "\u{1B}[3J"]
        for seed in UInt64(1)...32 {
            var generator = Generator(state: seed)
            var bounded = try #require(Terminal(
                columns: 5,
                rows: 2,
                scrollbackBudgetBytes: historyRowCost(columns: 5) * 5 / 2
            ))
            var actions: [Action] = []

            for _ in 0..<96 {
                let action: Action
                if generator.next().isMultiple(of: 5) {
                    if generator.next().isMultiple(of: 2) {
                        action = .resize(
                            columns: 2 + Int(generator.next() % 6),
                            rows: bounded.geometry.rows.count
                        )
                    } else {
                        action = .resize(
                            columns: bounded.geometry.columns,
                            rows: 1 + Int(generator.next() % 4)
                        )
                    }
                } else {
                    action = .feed(Array(tokens[Int(generator.next() % UInt64(tokens.count))].utf8))
                }
                actions.append(action)
                let previousFlag = bounded.isHistoryHeadTruncated
                var unbounded = bounded.withUnlimitedScrollbackForTesting()
                apply(action, to: &bounded, bytewise: false)
                apply(action, to: &unbounded, bytewise: false)

                let retained = Array(bounded.primaryHistoryText.unicodeScalars)
                let whole = Array(unbounded.primaryHistoryText.unicodeScalars)
                #expect(
                    whole.suffix(retained.count).elementsEqual(retained),
                    "seed \(seed), action \(actions.count), script \(actions)"
                )
                #expect(bounded.geometry == unbounded.geometry)
                #expect(bounded.screenText == unbounded.screenText)
                let removedCount = unbounded.scrollbackRowCount - bounded.scrollbackRowCount
                #expect(removedCount >= 0)
                if removedCount > 0 {
                    #expect(
                        bounded.isHistoryHeadTruncated
                            == unbounded.scrollbackRow(at: removedCount - 1)?.isSoftWrapped,
                        "seed \(seed), action \(actions.count), script \(actions)"
                    )
                } else if case let .feed(bytes) = action,
                          bytes == Array("\u{1B}[3J".utf8)
                {
                    #expect(bounded.isHistoryHeadTruncated == false)
                } else {
                    #expect(
                        bounded.isHistoryHeadTruncated == previousFlag,
                        "seed \(seed), action \(actions.count), script \(actions)"
                    )
                }
                #expect(bounded.scrollbackByteCount <= historyRowCost(columns: 5) * 5 / 2)
                #expect(bounded.scrollbackByteCount == bounded.recomputedScrollbackByteCount)
                expectValidGrid(bounded)
            }

            var bytewise = try #require(Terminal(
                columns: 5,
                rows: 2,
                scrollbackBudgetBytes: historyRowCost(columns: 5) * 5 / 2
            ))
            for action in actions {
                apply(action, to: &bytewise, bytewise: true)
            }
            #expect(bytewise == bounded)
        }
    }

    @Test("public initializer wires all three bounds, and the caps bind before the budget")
    func publicProductionBoundsCrossing() throws {
        // Intent: prove the public initializer alone wires the three literal production
        //   bounds, and that on ordinary content the caps are what decide depth.
        // Why it exists: tiny injected bounds cannot catch an omitted or incorrect public
        //   default, and these three literals are a deliberate ruling rather than a
        //   detail -- `D8` derived them from a ~150 ms resize budget, and `D11` re-sized
        //   the caps from a depth target (10,000 full-width rows at 179 columns) and
        //   raised the budget to cover them. A silent edit to any of the three moves both
        //   the memory footprint and the worst-case reflow, so they are pinned literally
        //   here and nowhere else. `byteBudgetStillBindsBeforeTheRowCap` covers the
        //   byte-expensive side; this one pins that the constants are wired and that the
        //   budget is not silently doing the caps' work on ordinary content.
        // Scenario: sustained ordinary output at a narrow width.
        var terminal = try #require(Terminal(columns: 8, rows: 1))

        for line in 0..<(Terminal.productionScrollbackRowCap + 500) {
            terminal.feed(Array("c\(line % 10)\r\n".utf8))
        }

        #expect(terminal.scrollbackBudgetBytes == 16_777_216)
        #expect(terminal.scrollbackRowCap == 89_500)
        #expect(terminal.scrollbackCellCap == 1_790_000)
        // `D8`'s losslessness property, restated as the arithmetic that keeps it: below
        // `cellCap / rowCap` columns the row cap evicts what widening cannot restore.
        #expect(terminal.scrollbackCellCap / terminal.scrollbackRowCap == 20)
        // The row cap decided here: these rows hold 2 stored cells, so the cell cap is far away.
        #expect(terminal.scrollbackRowCount == Terminal.productionScrollbackRowCap)
        #expect(terminal.scrollbackStoredCellCount < Terminal.productionScrollbackCellCap)
        #expect(terminal.scrollbackByteCount < terminal.scrollbackBudgetBytes)
        #expect(terminal.scrollbackByteCount == terminal.recomputedScrollbackByteCount)
        #expect(terminal.scrollbackStoredCellCount == terminal.recomputedScrollbackStoredCellCount)
    }

    private enum Action {
        case feed([UInt8])
        case resize(columns: Int, rows: Int)
    }

    private struct Generator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    private func apply(_ action: Action, to terminal: inout Terminal, bytewise: Bool) {
        switch action {
        case let .feed(bytes):
            if bytewise {
                for byte in bytes {
                    terminal.feed([byte])
                }
            } else {
                terminal.feed(bytes)
            }
        case let .resize(columns, rows):
            terminal.resize(columns: columns, rows: rows)
        }
    }

    @Test("history holds no more real memory than the budget it was given")
    func historyRespectsItsBudgetInRealBytes() throws {
        // Intent: after sustained output, the cell storage history actually holds fits inside the
        //   byte budget the terminal was configured with.
        // Why it exists: the cost model charged 40 bytes for an ordinary cell whose real cost is a
        //   72-byte stride, so a 10 MB budget admitted ~22 MB of scrollback -- a user who asks for
        //   10 MB of history got more than twice that (doc 15's H1, confirmed in magnitude by
        //   `15/F2`). Every other test here checks the model against itself and so could not see
        //   it; this one checks the model against what the grid is really holding.
        // Scenario: any long-running session that has filled its history.
        let columns = 179
        var terminal = try #require(Terminal(columns: columns, rows: 66))
        for line in 0..<20_000 {
            terminal.feed(Array("DANTERM-BUDGET-\(line) sustained plain-text output payload\r\n".utf8))
        }

        let census = terminal.memoryCensus
        // Live rows remain full width, so subtracting their cells leaves the exact compact
        // history-cell storage. Deliberately measured from the census rather than from
        // `scrollbackByteCount`, which is the very thing under test.
        // Read as what history's packed rows really hold, which is what the budget is spent
        // on since doc 28's packing. Multiplying a retained cell count by the live-grid stride
        // would price a representation history no longer uses -- and would answer ~35 MB for
        // a 10 MB budget purely because the same budget now admits ~9x the rows.
        let historyBytes = census.retainedPackedPayloadBytes
        #expect(census.scrollbackRowCount > 0)
        #expect(historyBytes <= Terminal.productionScrollbackBudgetBytes)
        // The depth the smaller charge bought, stated rather than implied: the same budget
        // holding far more rows is the whole point, and a regression that silently gave it
        // back would leave every assertion above still passing.
        #expect(census.retainedStoredCellCount > 0)
        // Bounded on both sides: `C1`'s cell is 8 bytes (`D9`), so the floor says a retained
        // cell really is packed, and the ceiling says the header and side tables have not
        // grown into a second cell's worth.
        #expect(census.retainedBytesPerStoredCell > 8)
        #expect(census.retainedBytesPerStoredCell < Double(census.cellStrideBytes) / 3)
    }
}
