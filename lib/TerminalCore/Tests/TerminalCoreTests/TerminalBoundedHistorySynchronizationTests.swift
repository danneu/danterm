// Proofs for the history budget on a state synchronization: what the bound costs, where the
// cut may land, and what the encoder reports about the rows it left out. The unbounded
// round-trip proofs stay in TerminalStateSynchronizationTests.swift; this file only covers
// what a budget changes.

import Testing
@testable import TerminalCore

/// Proves a budgeted synchronization stays within its bound without losing grid exactness.
struct TerminalBoundedHistorySynchronizationTests {
    @Test(
        "a history budget bounds what a synchronization spends on history",
        arguments: [0, 512, 4_096, 32_768]
    )
    func boundsHistoryToItsBudget(budget: Int) throws {
        // Intent: the history a bounded sync carries never costs more than the budget.
        // Why it exists: the budget exists to make a join or a repair affordable on a remote
        // link, so a deep pane exceeding it would defeat the whole feature.
        // Scenario: a pane with a long transcript syncs under each of several budgets.
        var source = try #require(Terminal(columns: 40, rows: 6))
        for index in 0..<2_000 {
            source.feed(Array("line \(index) of a deep transcript\r\n".utf8))
        }

        // A grid-only sync is the screen-proportional cost every sync pays, so anything the
        // bounded sync spends above it is history, and I1 bounds exactly that difference.
        let gridOnly = source.stateSynchronization(historyBudgetBytes: 0)
        let bounded = source.stateSynchronization(historyBudgetBytes: budget)
        #expect(bounded.bytes.count <= gridOnly.bytes.count + budget)
        #expect(bounded.droppedHistoryRows > 0)
        #expect(bounded.bytes.count < source.stateSynchronization.bytes.count)
    }

    @Test("a bounded synchronization replays the grid exactly and a verbatim history suffix")
    func replaysBoundedHistorySuffix() throws {
        // Intent: bounding loses only the oldest history, never grid fidelity.
        // Why it exists: a replica whose grid drifted would show the wrong screen, which is
        // worse than showing a short scrollback.
        // Scenario: a styled transcript deeper than the budget syncs onto a fresh terminal.
        var source = try #require(Terminal(columns: 20, rows: 4))
        source.feed(Array("\u{1B}[33mancient\u{1B}[m\r\n".utf8))
        for index in 0..<300 {
            source.feed(Array("row \(index)\r\n".utf8))
        }
        source.feed(Array("\u{1B}[1mtail".utf8))

        let bounded = source.stateSynchronization(historyBudgetBytes: 2_048)
        #expect(bounded.droppedHistoryRows > 0)
        var replica = try #require(Terminal(columns: bounded.columns, rows: bounded.rows))
        replica.feed(bounded.bytes)

        for row in 0..<bounded.rows {
            for column in 0..<bounded.columns {
                #expect(
                    replica.cell(row: row, column: column)
                        == source.cell(row: row, column: column),
                    "cell \(row),\(column)"
                )
            }
        }
        #expect(
            replica.scrollbackRowCount
                == source.scrollbackRowCount - bounded.droppedHistoryRows
        )
        for index in 0..<replica.scrollbackRowCount {
            #expect(
                replica.scrollbackRow(at: index)
                    == source.scrollbackRow(at: index + bounded.droppedHistoryRows)
            )
        }
    }

    @Test("a bounded cut never leaves a leading wrap-continuation fragment")
    func cutsAtALogicalLineBoundary() throws {
        // Intent: the oldest line a replica holds is a whole logical line.
        // Why it exists: a replica that starts mid-wrap shows a headless fragment, and a later
        // reflow would rewrap that fragment as if it were a line of its own.
        // Scenario: one wrapped line fills 41 display rows and the budget fits only a few, so
        // the natural byte cut would land inside it.
        var source = try #require(Terminal(columns: 8, rows: 2))
        source.feed(Array(String(repeating: "a", count: 8 * 40 + 3).utf8))
        source.feed(Array("\r\nbee\r\ncee\r\ndee".utf8))

        let bounded = source.stateSynchronization(historyBudgetBytes: 120)
        let dropped = bounded.droppedHistoryRows
        #expect(dropped > 0)
        // Every row of the wrapped line except its last continues, so a cut that landed inside
        // it would leave a continuing row immediately before the replica's oldest row.
        #expect(source.scrollbackRow(at: dropped - 1)?.isSoftWrapped == false)

        var replica = try #require(Terminal(columns: bounded.columns, rows: bounded.rows))
        replica.feed(bounded.bytes)
        let retained = (0..<replica.scrollbackRowCount).compactMap { replica.scrollbackRow(at: $0) }
        #expect(retained.isEmpty == false)
        #expect(
            retained.contains { row in
                row.cells.contains { String(describing: $0.scalars) == "a" }
            } == false
        )
    }

    @Test("a synchronization whose history fits reports no drop and carries today's bytes")
    func reportsNoDropWhenHistoryFits() throws {
        // Intent: a budget wide enough to hold everything changes nothing.
        // Why it exists: a client that always sets the parameter must not pay a different
        // payload, or a different report, for a pane that was never going to overflow.
        // Scenario: a five-line transcript syncs unbounded and under a generous budget.
        var source = try #require(Terminal(columns: 20, rows: 4))
        source.feed(Array("one\r\ntwo\r\nthree\r\nfour\r\nfive".utf8))

        let unbounded = source.stateSynchronization
        let bounded = source.stateSynchronization(historyBudgetBytes: 262_144)
        #expect(unbounded.droppedHistoryRows == 0)
        #expect(bounded.droppedHistoryRows == 0)
        #expect(bounded.bytes == unbounded.bytes)
    }
}
