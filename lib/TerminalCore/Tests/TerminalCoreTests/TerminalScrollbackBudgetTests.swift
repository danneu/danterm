// Behavioral proofs for deterministic scrollback accounting, eviction, and truncation state.
import Testing

@testable import TerminalCore

/// Locks the fixed byte budget to every history mutation path without coupling tests to storage.
struct TerminalScrollbackBudgetTests {
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
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let fixtures: [(columns: Int, text: String, expected: Int)] = [
            (4, "", 48 + 4 * 48),
            // Identical to the blank row above, and correctly so: an ASCII cell stores its one
            // scalar inline, so it costs exactly what an empty cell costs.
            (4, "ABCD", 48 + 4 * 48),
            (2, "\u{754C}", 48 + 2 * 48),
            // The only shape that costs more: a five-scalar cluster spills to its own allocation.
            (2, family, 48 + 2 * 48 + 32 + 5 * 4),
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
        #expect(spacer.scrollbackRowByteCost(at: 0) == 48 + 3 * 48)

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
        let rowCost = historyRowCost(columns: 2)
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
            scrollbackBudgetBytes: historyRowCost(columns: 4) * 2
        ))
        width.feed(Array("ABCDEFGHI".utf8))
        #expect(width.scrollbackByteCount == historyRowCost(columns: 4) * 2)
        let before = width.primaryHistoryText

        width.resize(columns: 2, rows: 1)
        #expect(width.scrollbackByteCount <= historyRowCost(columns: 4) * 2)
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

    @Test("public initializer enforces the fixed 10 MiB production budget", .timeLimit(.minutes(1)))
    func publicProductionBudgetCrossing() throws {
        // Intent: prove the public initializer alone wires the literal production budget.
        // Why it exists: tiny test budgets cannot catch an omitted or incorrect public default.
        // Scenario: sustained two-column output crosses 10 MiB and retains the newest row.
        let budget = 10_485_760
        let rowCost = historyRowCost(columns: 2)
        let rowCount = budget / rowCost + 2
        var bytes: [UInt8] = []
        bytes.reserveCapacity(rowCount * 4)
        for index in 0..<rowCount {
            if index == 0 {
                bytes.append(0x58)
            } else if index == rowCount - 1 {
                bytes.append(0x5A)
            } else {
                bytes.append(0x41)
            }
            bytes.append(0x41)
            bytes.append(0x0D)
            bytes.append(0x0A)
        }
        var terminal = try #require(Terminal(columns: 2, rows: 1))

        terminal.feed(bytes)

        #expect(terminal.scrollbackBudgetBytes == budget)
        #expect(terminal.scrollbackByteCount <= budget)
        #expect(budget - terminal.scrollbackByteCount < rowCost)
        #expect(terminal.scrollbackRowCount < rowCount)
        #expect(terminal.scrollbackRow(at: 0)?.cells[0].scalars == ["A"])
        #expect(terminal.scrollbackRow(at: terminal.scrollbackRowCount - 1)?.cells[0].scalars == ["Z"])
        #expect(terminal.scrollbackByteCount == terminal.recomputedScrollbackByteCount)
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
        // Rows are full width regardless of the text on them, so history's true cell cost is
        // rows x columns x stride. Deliberately measured from the census rather than from
        // `scrollbackByteCount`, which is the very thing under test.
        let historyBytes = census.scrollbackRowCount * columns * census.cellStrideBytes
        #expect(census.scrollbackRowCount > 0)
        #expect(historyBytes <= Terminal.productionScrollbackBudgetBytes)
    }
}
