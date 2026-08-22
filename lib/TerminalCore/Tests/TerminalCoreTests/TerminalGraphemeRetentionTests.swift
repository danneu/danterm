// Proves that live grapheme storage, REP memory, and synchronization bytes stay bounded
// under an input stream that never closes one cluster.

import Testing

@testable import TerminalCore

/// Locks the terminal's grapheme retention limit to observable grid and continuation behavior.
struct TerminalGraphemeRetentionTests {
    @Test("grapheme retention stops at its byte limit without changing later output")
    func continuingCombiningStreamIsBounded() throws {
        // Intent: bound every retained copy of an open grapheme while preserving admitted content.
        // Why it exists: one continuing cluster otherwise grows the cell, REP memory, and state
        //   synchronization payload for the whole session lifetime.
        // Scenario: a base receives marks through the last fitting scalar and far past it, is
        //   synchronized and repeated after erasure, then ordinary output continues beside it.
        let byteLimit = Terminal.graphemeClusterByteLimit
        let mark = "\u{0301}"
        let retainedMarkCount = (byteLimit - 1) / mark.utf8.count
        let retainedCluster = "A" + String(repeating: mark, count: retainedMarkCount)
        let overflow = String(repeating: mark, count: 1_024)

        var exact = try #require(Terminal(columns: 4, rows: 1))
        exact.feed(Array(retainedCluster.utf8))
        let exactSynchronization = exact.stateSynchronization

        var flooded = try #require(Terminal(columns: 4, rows: 1))
        flooded.feed(Array((retainedCluster + overflow).utf8))

        var recovered = try #require(Terminal(columns: 4, rows: 1))
        recovered.feed(Array(retainedCluster.utf8))
        recovered.feed(Array(("\u{1B}[2G" + overflow).utf8))

        #expect(flooded.cell(row: 0, column: 0)?.scalars == TerminalScalars(retainedCluster.unicodeScalars))
        #expect(flooded.stateSynchronization == exactSynchronization)
        #expect(recovered == flooded)
        #expect(recovered.stateSynchronization == exactSynchronization)

        let synchronization = flooded.stateSynchronization
        var resumed = try #require(Terminal(
            columns: synchronization.columns,
            rows: synchronization.rows
        ))
        resumed.feed(synchronization.bytes)
        #expect(resumed.cell(row: 0, column: 0)?.scalars == TerminalScalars(retainedCluster.unicodeScalars))

        flooded.feed(Array(mark.utf8))
        resumed.feed(Array(mark.utf8))
        exact.feed(Array(mark.utf8))
        #expect(flooded.cell(row: 0, column: 0)?.scalars == TerminalScalars(retainedCluster.unicodeScalars))
        #expect(resumed.cell(row: 0, column: 0)?.scalars == TerminalScalars(retainedCluster.unicodeScalars))

        let repeatAfterErase = Array("\u{1B}[2J\u{1B}[H\u{1B}[b".utf8)
        flooded.feed(repeatAfterErase)
        resumed.feed(repeatAfterErase)
        exact.feed(repeatAfterErase)
        #expect(flooded.cell(row: 0, column: 0)?.scalars == TerminalScalars(retainedCluster.unicodeScalars))
        #expect(resumed.cell(row: 0, column: 0)?.scalars == TerminalScalars(retainedCluster.unicodeScalars))

        flooded.feed(Array("B".utf8))
        resumed.feed(Array("B".utf8))
        exact.feed(Array("B".utf8))
        #expect(flooded.screenText == exact.screenText)
        #expect(resumed.screenText == exact.screenText)
        #expect(renderedCells(flooded) == renderedCells(exact))
        #expect(renderedCells(resumed) == renderedCells(exact))

        var width = try #require(Terminal(columns: 4, rows: 1))
        let heart = "\u{2764}"
        let widthMarks = String(
            repeating: mark,
            count: (byteLimit - heart.utf8.count) / mark.utf8.count
        )
        width.feed(Array((heart + widthMarks + "\u{FE0F}").utf8))
        #expect(width.cell(row: 0, column: 0)?.scalars == TerminalScalars((heart + widthMarks).unicodeScalars))
        #expect(width.geometry.rows[0].cells[0].kind == .narrow)
    }

    private func renderedCells(_ terminal: Terminal) -> [TerminalScalars] {
        var result: [TerminalScalars] = []
        terminal.forEachViewportCell(row: 0) { _, scalars, _ in result.append(scalars) }
        return result
    }
}
