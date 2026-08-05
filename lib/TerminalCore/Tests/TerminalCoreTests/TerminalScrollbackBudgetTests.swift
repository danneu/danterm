// Behavioral proofs for deterministic scrollback accounting, eviction, and head-trim state.
//
// Restated against doc 31's record store: history has **one** bound -- charged bytes against the
// arena's capacity (`31/I2`) -- where it had three. The cell and row caps priced the two terms of
// a width reflow of retained rows, and there is no reflow of retained rows left to price
// (`31/D2` Decision 4), so this file's cap tests are gone rather than adapted. What replaces the
// public `isHistoryHeadTruncated` flag is the invariant `31/D2` Decision 2 states in its place:
// the oldest retained record is a *suffix* of the logical line that produced it whenever its head
// has been trimmed, and it reads as a mid-line continuation for as long as it survives (`31/DD10`).
import Testing

@testable import TerminalCore

/// Locks the one charged-byte bound to every history mutation path without coupling tests to
/// storage.
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
            scrollbackBudgetBytes: historyBudget(lines: 4, cells: 8)
        ))
        terminal.feed(Array("A\r\nB\r\nC\r\nD\r\n".utf8))
        let before = terminal.primaryHistoryText
        let rowCount = terminal.scrollbackRowCount

        terminal.resize(columns: 16, rows: 1)

        #expect(terminal.primaryHistoryText == before)
        #expect(terminal.scrollbackRowCount == rowCount)
        expectValidGrid(terminal)
    }

    @Test("short compact lines retain deeper history than full-width lines at one budget")
    func compactLineLengthControlsRetentionDepth() throws {
        // Intent: a fixed byte budget retains more short lines than full-width lines.
        // Why it exists: content-denominated storage is useful only if its smaller charge turns
        //   into user-visible history depth rather than merely changing a diagnostic counter.
        // Scenario: equal-width panes stream one-cell and full-width hard lines.
        let columns = 80
        let budget = historyBudget(lines: 2, cells: columns)
        var short = try #require(Terminal(columns: columns, rows: 1, scrollbackBudgetBytes: budget))
        var full = try #require(Terminal(columns: columns, rows: 1, scrollbackBudgetBytes: budget))
        for _ in 0..<10 {
            short.feed(Array("x\r\n".utf8))
            full.feed(Array(String(repeating: "1234567890", count: 8).utf8))
            full.feed(Array("\r\n".utf8))
        }

        #expect(short.scrollbackRowCount > full.scrollbackRowCount)
        #expect(short.scrollbackCensus.chargedBytes <= short.scrollbackCensus.capacityBytes)
        #expect(full.scrollbackCensus.chargedBytes <= full.scrollbackCensus.capacityBytes)
    }

    @Test("equivalent resize routes converge to one canonical retained representation")
    func compactHistoryIsCanonicalAcrossResizeRoutes() throws {
        // Intent: equal terminal content reached through different retained widths compares equal.
        // Why it exists: synthesized equality includes private history state, so a store that
        //   remembered the width it was fed at would make observably identical terminals unequal
        //   and break no-op detection. Under doc 31 it is also the sharpest statement of `31/I1`:
        //   nothing width-dependent is stored, so the route cannot be recovered from the bytes.
        // Scenario: one pane retains a line narrowly then widens; its twin starts wide.
        var resized = try #require(Terminal(columns: 4, rows: 1))
        resized.feed(Array("abc\r\n".utf8))
        resized.resize(columns: 8, rows: 1)

        var direct = try #require(Terminal(columns: 8, rows: 1))
        direct.feed(Array("abc\r\n".utf8))

        #expect(resized == direct)
    }

    @Test("the arena is reserved once, and the charge never passes its capacity")
    func budgetChargesReservedStorageNotJustCells() throws {
        // Intent: what history charges stays inside the capacity it was built at, and that
        //   capacity does not move however much is fed through it.
        // Why it exists: doc 15's `F7`/`F12` incident restated for the arena (`31/DD11`). The old
        //   charge modelled per-row allocations and drifted from what malloc really reserved; the
        //   arena is allocated once, below the budget by a fixed metadata reserve (`31/DD36`), so
        //   the bound holds by construction and the proof is that capacity never grows.
        // Scenario: a pane at ordinary widths streams enough history to force steady eviction.
        for columns in [80, 200] {
            var terminal = try #require(Terminal(
                columns: columns,
                rows: 4,
                scrollbackBudgetBytes: historyBudget(lines: 400, cells: columns)
            ))
            let capacity = terminal.scrollbackCensus.capacityBytes
            for line in 0..<2_000 {
                terminal.feed(Array("row \(line) ".utf8))
                terminal.feed([0x0D, 0x0A])
            }

            #expect(terminal.scrollbackRowCount > 0)
            let census = terminal.scrollbackCensus
            #expect(census.capacityBytes == capacity)
            #expect(census.capacityBytes < census.budgetBytes)
            #expect(census.chargedBytes <= census.capacityBytes)
        }
    }

    @Test("a pane whose budget cannot hold one full-width row retains nothing and keeps running")
    func aBudgetBelowOneFullWidthRowRetainsNothing() throws {
        // Intent: a pane configured with a scrollback budget too small for a single display row
        //   of its own width retains no history, stays inside its charge, and keeps displaying
        //   correctly instead of trapping.
        // Why it exists: `LogicalLineStore.admit`'s opening guard states the contract in words
        //   -- "such a pane has no history, and the degenerate configuration stays reachable
        //   instead of being a crash" -- and nothing exercised it. Every other budget in the
        //   suite comes from `historyBudget`, whose binary search calls the store itself and so
        //   can only ever return a budget where the guard cannot fire.
        var terminal = try #require(Terminal(columns: 80, rows: 2, scrollbackBudgetBytes: 1024))
        // Full-width rows only: an 80-cell row's worst case exceeds the arena this budget
        // reserves, while a shorter one would still be admitted and break the retains-nothing
        // claim. Soft wrapping at 80 columns is what makes every scrolled-off row full width.
        for line in 0..<40 {
            terminal.feed(Array(String(repeating: "\(line % 10)", count: 240).utf8))
        }

        #expect(terminal.scrollbackRowCount == 0)
        let census = terminal.scrollbackCensus
        #expect(census.chargedBytes <= census.capacityBytes)
        #expect(terminal.screenText == String(repeating: "9", count: 80) + "\n"
            + String(repeating: "9", count: 80))
        expectValidGrid(terminal)
    }

    @Test("a logical line's arena charge uses pinned header, cell, and table literals")
    func costModelUsesPinnedLiterals() throws {
        // Intent: freeze what a retained logical line costs across every structural cell shape.
        // Why it exists: eviction points are value semantics and cannot drift with a toolchain.
        //   Restated per *record* by doc 31: the header is charged once per logical line rather
        //   than once per display row, which is the change that buys the depth `31/PO11` gates on.
        // Scenario: canonical blank, ASCII, wide, spacer, and emoji lines enter history.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let charge = RecordCharge.self
        let fixtures: [(columns: Int, text: String, cells: Int, identityRuns: Int)] = [
            // A blank hard-ended line stores no cells at all: a record's cell count is a content
            // property, and zero is representable (`31/DD15`).
            (4, "", 0, 0),
            // Four ASCII cells printed straight through: one identity run covers the line.
            (4, "ABCD", 4, 1),
            // A wide glyph is two cells and costs no more than two of anything else: its kind
            // rides in the cell. Head and tail share one identity, which a
            // `(start, extent, base)` run cannot express, so the encoder takes the per-cell floor.
            (2, "\u{754C}", 2, 0),
            // The only shape that reaches outside the arena: a five-scalar cluster spills to the
            // side table, reached by an index the cell's scalar field holds in place of a scalar.
            (2, family, 2, 0),
        ]

        for fixture in fixtures {
            var terminal = try #require(Terminal(columns: fixture.columns, rows: 1))
            terminal.feed(Array(fixture.text.utf8))
            terminal.feed([0x0D, 0x0A])

            let summary = try #require(terminal.retainedRecordSummaryForTesting(at: 0))
            #expect(summary.cellCount == fixture.cells)
            var expected = charge.header + fixture.cells * charge.cell
            expected += fixture.identityRuns > 0
                ? fixture.identityRuns * charge.identityRun
                : fixture.cells * charge.identityCell
            #expect(terminal.scrollbackCensus.arenaBytesInUse == (expected + 7) & ~7)
        }

        var spacer = try #require(Terminal(columns: 3, rows: 1))
        spacer.moveCursor(row: 0, column: 2)
        spacer.feed(Array("\u{754C}".utf8))
        // The spacer itself is never stored -- where one sits is a function of the width, which
        // `31/I1` forbids storing -- and the fold re-derives it at read.
        #expect(spacer.scrollbackRow(at: 0)?.cells.last?.kind == .spacerHead)
        #expect(spacer.retainedRecordSummaryForTesting(at: 0)?.cellCount == 2)

        let production = try #require(Terminal(columns: 4, rows: 2))
        let overridden = try #require(Terminal(
            columns: 4,
            rows: 2,
            scrollbackBudgetBytes: Terminal.productionScrollbackBudgetBytes - 8
        ))
        #expect(production != overridden)
    }

    @Test("exact budget retains and overshoot evicts the minimal oldest prefix")
    func exactBoundaryAndMinimalEviction() throws {
        // Intent: prove the strict-over trigger and minimal oldest-first display-row removal.
        // Why it exists: an off-by-one would discard history at the documented boundary, and
        //   eviction that dropped more than one display row per step would move four anchors and
        //   the scrollbar further per admitted row than today's engine does (`31/I4`).
        // Scenario: two lines fill a tiny budget before one push and one shrink overshoot it.
        var terminal = try #require(Terminal(
            columns: 2,
            rows: 1,
            scrollbackBudgetBytes: historyBudget(lines: 2, cells: 1, paneColumns: 2)
        ))

        terminal.feed(Array("A\r\nB\r\n".utf8))
        #expect(terminal.scrollbackRowCount == 2)
        #expect(terminal.scrollbackRow(at: 0)?.cells[0].scalars == ["A"])

        terminal.feed(Array("C\r\n".utf8))
        #expect(terminal.scrollbackRowCount == 2)
        #expect(terminal.scrollbackRow(at: 0)?.cells[0].scalars == ["B"])
        #expect(terminal.scrollbackRow(at: 1)?.cells[0].scalars == ["C"])

        var batch = try #require(Terminal(
            columns: 2,
            rows: 4,
            scrollbackBudgetBytes: historyBudget(lines: 2, cells: 1)
        ))
        batch.feed(Array("A\r\nB\r\nC\r\nD".utf8))
        batch.resize(columns: 2, rows: 1)
        #expect(batch.scrollbackRowCount == 2)
        #expect(batch.scrollbackRow(at: 0)?.cells[0].scalars == ["B"])
        #expect(batch.scrollbackRow(at: 1)?.cells[0].scalars == ["C"])
        expectValidGrid(batch)
    }

    @Test("a width change evicts nothing, at any width down to the engine minimum")
    func widthChangeEvictsNothing() throws {
        // Intent: narrowing a history that is already sitting on its budget ceiling, and widening
        //   it back, retains every logical line and every scalar, at every width between the
        //   engine minimum and the original.
        // Why it exists: this is `31/I3`, and it is the invariant that replaces the deleted row
        //   cap. `narrowThenWidenPreservesCappedHistory` pinned the *mitigation* for a lossiness
        //   the row cap could not avoid -- narrowing multiplies display rows while leaving
        //   content alone, so a display-row bound evicts what widening cannot restore. Storing
        //   logical lines makes that lossiness unrepresentable rather than mitigated, so the
        //   property is now stated directly on the store instead of on a cap ratio. Saturation is
        //   the regime that matters here: with headroom, a width change that did charge for the
        //   refold would evict nothing anyway and the test would pass on a broken engine. An
        //   earlier form fed 4,000 lines at the production budget and called the result
        //   saturated; at ~1,461 charged bytes a line that is ~5.8 MB against a 15,728,640-byte
        //   arena, so nothing was ever evicted and the premise was simply false.
        //   `TerminalLogicalLineStoreTests.widthChangeIsANoOpOnRetainedStorage` states the
        //   arena-byte and cell-for-cell half of `31/I1` at the store; what is unique here is
        //   `Terminal.resize` driving it on a history deep enough to span many arena chunks.
        // Scenario: a user drags a pane narrow and back with a full history of full-width output.
        let wide = 179
        // Small enough to reach the ceiling in ~340 lines, large enough that the arena is still
        // many chunks (records may not straddle one, `31/DD54`, so the seams force-split records
        // exactly as they do at the production budget) -- asserted below rather than assumed.
        let budgetBytes = 1 << 19
        var terminal = try #require(Terminal(
            columns: wide,
            rows: 1,
            scrollbackBudgetBytes: budgetBytes
        ))
        let lineCount = 1_024
        for index in 0..<lineCount {
            let body = String(repeating: "abcdefgh\(index % 10)", count: 20)
            let line = String(("L\(index)-" + body).prefix(wide))
            terminal.feed(Array((line + "\r\n").utf8))
        }

        // The premise, observed rather than claimed. The oldest line being unfindable is
        // eviction; a record or row count is not, since the viewport accounts for a shortfall
        // whether or not anything was ever evicted.
        #expect(terminal.primaryHistoryText.contains("L0-") == false)
        let census = terminal.scrollbackCensus
        #expect(census.chargedBytes <= census.capacityBytes)
        // On the ceiling, not merely past the first eviction: within a sixteenth of capacity.
        #expect(census.chargedBytes * 16 >= census.capacityBytes * 15)
        let chunkShift = Terminal.LogicalLineStore.chunkByteShift(forCapacity: census.capacityBytes)
        let chunkBytes = 1 << chunkShift
        #expect(census.capacityBytes >= chunkBytes * 4)

        let records = terminal.scrollbackRecordCount
        let textAtWide = terminal.primaryHistoryText
        let rowsAtWide = terminal.scrollbackRowCount

        for narrow in [100, 40, 2] {
            terminal.resize(columns: narrow, rows: 1)
            // Not one logical line lost, at any width -- and the display-row count grows, which
            // is what made a display-row bound lossy in the first place.
            #expect(terminal.scrollbackRecordCount == records)
            #expect(terminal.scrollbackRowCount > rowsAtWide)
            // Every scalar too, not just every record: history text is a function of the retained
            // logical lines, so a width that dropped or clipped one shows up here even when the
            // record count survives it.
            #expect(terminal.primaryHistoryText == textAtWide)
        }

        terminal.resize(columns: wide, rows: 1)
        #expect(terminal.scrollbackRecordCount == records)
        #expect(terminal.scrollbackRowCount == rowsAtWide)
        #expect(terminal.primaryHistoryText == textAtWide)
        // Once, on the width the cycle returns to. Each call folds the whole history a second
        // time and copies the terminal twice, and `resizePathsEnforceBudget` already runs it on
        // a two-column refold; the depth here is what this test contributes, not the width.
        expectValidGrid(terminal)
    }

    @Test("a trimmed head reads as a mid-line continuation and carries no mark")
    func truncationTracksLastEvictedBoundary() throws {
        // Intent: when eviction cuts inside a logical line, what survives is a suffix that reads
        //   as a continuation; when it cuts at a line boundary, the new head is a line start.
        // Why it exists: `31/DD10` deletes the public `isHistoryHeadTruncated` -- it had no
        //   production consumer and `31/DD2` made it constant -- and `31/D2` Decision 2 states
        //   the fact it asserted as a property of what the fold emits at the top of history.
        //   This is that property, asserted where the flag used to be.
        // Scenario: soft, hard, and over-budget cluster cuts cross the seam.
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        var soft = try #require(Terminal(
            columns: 2,
            rows: 1,
            scrollbackBudgetBytes: historyBudget(lines: 1, cells: 6, paneColumns: 2)
        ))
        // One logical line long enough that the budget has to cut *inside* it.
        soft.feed(Array(alphabet.utf8))

        #expect(soft.scrollbackRowCount >= 1)
        #expect(soft.retainedRecordSummaryForTesting(at: 0)?.startsMidLine == true)
        // What survives is a suffix of the line, and the head that survives reads as one.
        #expect(alphabet.hasSuffix(soft.primaryHistoryText))
        #expect(soft.primaryHistoryText.count < alphabet.count)

        // A hard newline gives history a line boundary to cut at instead, and the record that
        // starts there is a line start rather than a continuation.
        soft.feed(Array("\r\n".utf8))
        for index in 0..<8 { soft.feed(Array("\(index)\r\n".utf8)) }
        #expect(soft.retainedRecordSummaryForTesting(at: 0)?.startsMidLine == false)
        expectValidGrid(soft)

        var spacer = try #require(Terminal(
            columns: 3,
            rows: 1,
            scrollbackBudgetBytes: historyBudget(lines: 1, cells: 3)
        ))
        spacer.moveCursor(row: 0, column: 2)
        spacer.feed(Array("\u{754C}ABCD".utf8))
        expectValidGrid(spacer)

        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        var giant = try #require(Terminal(
            columns: 2,
            rows: 1,
            scrollbackBudgetBytes: historyBudget(lines: 1, cells: 2)
        ))
        giant.feed(Array((family + "Z").utf8))
        #expect(giant.screenText == "Z ")
        expectValidGrid(giant)
    }

    @Test("ED 3 clears accounting before history restarts")
    func eraseDisplayThreeResetsBudgetState() throws {
        // Intent: reset both derived byte state and eviction metadata with explicit erasure.
        // Why it exists: stale accounting would corrupt every later enforcement decision.
        // Scenario: an application clears truncated history, then starts a new transcript.
        var terminal = try #require(Terminal(
            columns: 2,
            rows: 1,
            scrollbackBudgetBytes: historyBudget(lines: 1, cells: 2)
        ))
        terminal.feed(Array("ABCDE".utf8))
        #expect(terminal.scrollbackCensus.arenaBytesInUse > 0)

        terminal.feed(Array("\u{1B}[3J".utf8))
        #expect(terminal.scrollbackRowCount == 0)
        #expect(terminal.scrollbackRecordCount == 0)
        #expect(terminal.scrollbackCensus.arenaBytesInUse == 0)

        terminal.feed(Array("\r\nX\r\n".utf8))
        #expect(terminal.scrollbackRowCount == 1)
        expectValidGrid(terminal)
    }

    @Test("height and width resize enforce the budget after preserving retained suffixes")
    func resizePathsEnforceBudget() throws {
        // Intent: enforce after height displacement and width refold at the new charge.
        // Why it exists: both paths can exceed the budget without a parser-driven scroll.
        // Scenario: a pane shrinks, narrows, regrows, and refolds an already-trimmed head.
        let twoLines = historyBudget(lines: 2, cells: 1, paneColumns: 2)
        var height = try #require(Terminal(columns: 2, rows: 4, scrollbackBudgetBytes: twoLines))
        height.feed(Array("A\r\nB\r\nC\r\nD".utf8))
        height.resize(columns: 2, rows: 1)
        #expect(height.primaryHistoryText == "B\nC\nD")
        expectValidGrid(height)

        var width = try #require(Terminal(
            columns: 4,
            rows: 1,
            scrollbackBudgetBytes: historyBudget(lines: 3, cells: 4)
        ))
        width.feed(Array("ABCDEFGHI".utf8))
        let before = width.primaryHistoryText

        width.resize(columns: 2, rows: 1)
        // A width change evicts nothing (`31/I3`), so the retained text is unchanged rather than
        // a suffix of what it was -- which is what the caps could not promise.
        #expect(width.primaryHistoryText == before)
        expectValidGrid(width)

        width.resize(columns: 2, rows: 4)
        expectValidGrid(width)

        var trimmed = try #require(Terminal(
            columns: 2,
            rows: 1,
            scrollbackBudgetBytes: twoLines
        ))
        trimmed.feed(Array("ABCDEFG".utf8))
        let trimmedText = trimmed.primaryHistoryText
        trimmed.resize(columns: 3, rows: 1)
        #expect(trimmed.primaryHistoryText == trimmedText)
        expectValidGrid(trimmed)
    }

    @Test("truncating resize advances primary history generation on either screen")
    func truncatingResizeAdvancesPrimaryHistoryGeneration() throws {
        // Intent: signal recovery whenever a resize changes retained primary history.
        // Why it exists: generation-based recovery observation can otherwise keep stale text
        //   after a resize moved the history/live seam.
        // Scenario: a budget-filled shell narrows either directly or behind a full-screen app.
        for entersAlternateScreen in [false, true] {
            var terminal = try #require(Terminal(
                columns: 4,
                rows: 1,
                scrollbackBudgetBytes: historyBudget(lines: 2, cells: 4)
            ))
            terminal.feed(Array("ABCDEFGHI".utf8))
            if entersAlternateScreen {
                terminal.feed(Array("\u{1B}[?1047h".utf8))
            }
            let generationBeforeResize = terminal.primaryHistoryGeneration

            terminal.resize(columns: 2, rows: 1)

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
            scrollbackBudgetBytes: historyBudget(lines: 2, cells: 4)
        ))
        active.feed(Array("ABCDEFGHI".utf8))
        var alternate = active

        alternate.feed(Array("\u{1B}[?1047h123456789012".utf8))
        #expect(alternate.scrollbackRowCount == active.scrollbackRowCount)
        #expect(alternate.scrollbackCensus == active.scrollbackCensus)

        active.resize(columns: 2, rows: 1)
        alternate.resize(columns: 2, rows: 1)
        #expect(alternate.primaryHistoryText == active.primaryHistoryText)
        #expect(alternate.scrollbackRowCount == active.scrollbackRowCount)
        alternate.feed(Array("\u{1B}[?1047l".utf8))
        #expect(alternate.primaryHistoryText == active.primaryHistoryText)
        expectValidGrid(alternate)
    }

    @Test("eviction leaves viewport cursor and parser control behavior unchanged")
    func cursorAndControlStateAreImmune() throws {
        // Intent: isolate eviction from cursor, saved state, modes, wrap, and cluster behavior.
        // Why it exists: later input must observe only the enclosing operation's state changes.
        // Scenario: three evicting panes -- a feed, a height shrink and a width narrow -- each
        //   compared immediately with its no-eviction twin.
        //
        // The twin is a separately constructed terminal at the production budget rather than a
        // copy with its bound raised: the arena reserves its capacity once, at construction, so
        // "the same terminal with an unlimited budget" is not a value that exists (`31/I2`).
        // Two distinct operations across three cases: the resize one drives both the height
        // shrink (2x4) and the width narrow (4x1), which is the axis the `setup` entry carries.
        // Paired with its setup in one array so the two can never fall out of step.
        let feedC: (Terminal, Terminal) -> (Terminal, Terminal) = { bounded, unbounded in
            var bounded = bounded
            var unbounded = unbounded
            bounded.feed(Array("C\r\n".utf8))
            unbounded.feed(Array("C\r\n".utf8))
            return (bounded, unbounded)
        }
        let resizeToOneRow: (Terminal, Terminal) -> (Terminal, Terminal) = { bounded, unbounded in
            var bounded = bounded
            var unbounded = unbounded
            bounded.resize(columns: 2, rows: 1)
            unbounded.resize(columns: 2, rows: 1)
            return (bounded, unbounded)
        }

        let cases: [(
            columns: Int,
            rows: Int,
            bytes: String,
            budget: Int,
            operation: (Terminal, Terminal) -> (Terminal, Terminal)
        )] = [
            (2, 1, "A\r\n", historyBudget(lines: 1, cells: 2), feedC),
            (2, 4, "A\r\nB\r\nC\r\nDE", historyBudget(lines: 2, cells: 2), resizeToOneRow),
            (4, 1, "ABCDEFGHI", historyBudget(lines: 2, cells: 4), resizeToOneRow),
        ]

        for testCase in cases {
            var bounded = try #require(Terminal(
                columns: testCase.columns,
                rows: testCase.rows,
                scrollbackBudgetBytes: testCase.budget
            ))
            let prefix = "\u{1B}[4h\u{1B}7"
            bounded.feed(Array((prefix + testCase.bytes).utf8))
            let unbounded = bounded.withUnlimitedScrollbackForTesting()

            var pair = testCase.operation(bounded, unbounded)
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
            scrollbackBudgetBytes: historyBudget(lines: 1, cells: 2)
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
        // Intent: sweep all mutation families against a fresh operation-local unbounded twin.
        // Why it exists: the maintained totals, the derived index and the charge must remain
        //   coherent in composition -- `31/AR4`'s stale index is the failure mode with no
        //   analogue in the old store, and only a recount against the arena catches it.
        // Scenario: random input, single-axis resizes, and ED 3 replay whole and bytewise.
        let tokens = ["a", "b", " ", "\u{754C}", "\u{1F642}", "\r\n", "\n", "\u{1B}[3J"]
        let budget = historyBudget(lines: 2, cells: 5)
        // The twin is rebuilt per action, and an arena zero-fills its whole capacity at
        // construction, so the twin's budget is paid ~3,000 times as a memset. It only has to be
        // unbounded relative to one action: it starts from a history the bounded terminal already
        // held (<= `budget`, a few hundred bytes) and takes on at most one action's spill --
        // fewer than 8 rows of at most 7 columns at this grid. The measured peak across all
        // 3,072 twins is 200 arena bytes against the 61,440 this budget reserves, and the
        // headroom assertion below fails the run long before a twin could evict and turn the
        // oracle silently wrong.
        let twinBudget = 1 << 16
        for seed in UInt64(1)...32 {
            var generator = SeededByteGenerator(state: seed)
            var bounded = try #require(Terminal(
                columns: 5,
                rows: 2,
                scrollbackBudgetBytes: budget
            ))
            var actions: [Action] = []

            for _ in 0..<96 {
                let action: Action
                if generator.nextWord().isMultiple(of: 5) {
                    if generator.nextWord().isMultiple(of: 2) {
                        action = .resize(
                            columns: 2 + Int(generator.nextWord() % 6),
                            rows: bounded.geometry.rows.count
                        )
                    } else {
                        action = .resize(
                            columns: bounded.geometry.columns,
                            rows: 1 + Int(generator.nextWord() % 4)
                        )
                    }
                } else {
                    action = .feed(Array(tokens[Int(generator.nextWord() % UInt64(tokens.count))].utf8))
                }
                actions.append(action)
                var unbounded = bounded.withUnlimitedScrollbackForTesting(budgetBytes: twinBudget)
                apply(action, to: &bounded, bytewise: false)
                apply(action, to: &unbounded, bytewise: false)

                // The suffix oracle below is only a suffix if the twin never evicted. Assert the
                // twin stayed a sixteenth clear of its arena rather than that it happened not to
                // evict: usage is what a too-small `twinBudget` erodes first, so this fails while
                // the margin is still 16x instead of at the moment the oracle breaks.
                let twinCensus = unbounded.memoryCensus
                #expect(
                    twinCensus.retainedArenaBytesInUse * 16 <= twinCensus.retainedArenaCapacityBytes
                )

                let retained = Array(bounded.primaryHistoryText.unicodeScalars)
                let whole = Array(unbounded.primaryHistoryText.unicodeScalars)
                #expect(
                    whole.suffix(retained.count).elementsEqual(retained),
                    "seed \(seed), action \(actions.count), script \(actions)"
                )
                #expect(bounded.geometry == unbounded.geometry)
                #expect(bounded.screenText == unbounded.screenText)
                #expect(bounded.scrollbackRowCount <= unbounded.scrollbackRowCount)
                expectValidGrid(bounded)
            }

            var bytewise = try #require(Terminal(
                columns: 5,
                rows: 2,
                scrollbackBudgetBytes: budget
            ))
            for action in actions {
                apply(action, to: &bytewise, bytewise: true)
            }
            #expect(bytewise == bounded)
        }
    }

    @Test("public initializer wires the one production bound")
    func publicProductionBoundsCrossing() throws {
        // Intent: prove the public initializer alone wires the literal production budget, and
        //   that the arena's capacity is held below it by the metadata reserve.
        // Why it exists: a tiny injected budget cannot catch an omitted or incorrect public
        //   default, and this literal is a deliberate ruling rather than a detail -- `28/D11`
        //   raised it to cover two caps that doc 31 deletes, and `31/D2` Decision 1 re-derived
        //   the same number on new grounds. The two caps it used to be pinned beside are gone
        //   with the reflow of history they priced (`31/D2` Decision 4).
        // Scenario: sustained ordinary output at a narrow width.
        var terminal = try #require(Terminal(columns: 8, rows: 1))

        for line in 0..<20_000 {
            terminal.feed(Array("c\(line % 10)\r\n".utf8))
        }

        let census = terminal.scrollbackCensus
        #expect(census.budgetBytes == 16_777_216)
        #expect(census.capacityBytes == 16_777_216 - 16_777_216 / 16)
        #expect(census.chargedBytes <= census.capacityBytes)
        #expect(terminal.scrollbackRowCount == 20_000)
    }

    private enum Action {
        case feed([UInt8])
        case resize(columns: Int, rows: Int)
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
        // Intent: after sustained output, what history actually holds fits inside the byte
        //   budget the terminal was configured with.
        // Why it exists: the pre-doc-15 cost model charged 40 bytes for a cell whose real cost
        //   was a 72-byte stride, so a 10 MB budget admitted ~22 MB of scrollback. Every other
        //   test here checks the model against itself and so could not see it; this one checks
        //   the model against what the store is really holding.
        // Scenario: any long-running session that has filled its history.
        let columns = 179
        var terminal = try #require(Terminal(columns: columns, rows: 66))
        for line in 0..<20_000 {
            terminal.feed(Array("DANTERM-BUDGET-\(line) sustained plain-text output payload\r\n".utf8))
        }

        let census = terminal.memoryCensus
        #expect(census.scrollbackRowCount > 0)
        #expect(census.retainedChargedBytes <= census.retainedArenaCapacityBytes)
        #expect(census.retainedArenaCapacityBytes < Terminal.productionScrollbackBudgetBytes)
        #expect(census.hasRetainedStorageOverdraft == false)
        // The depth the smaller charge bought, stated rather than implied.
        #expect(census.retainedStoredCellCount > 0)
        // Bounded on both sides: a record's cell is 8 bytes, so the floor says a retained cell
        // really is packed, and the ceiling says the header and side tables have not grown into
        // a second cell's worth.
        #expect(census.retainedBytesPerStoredCell > 8)
        #expect(census.retainedBytesPerStoredCell < Double(census.cellStrideBytes) / 3)
    }
}
