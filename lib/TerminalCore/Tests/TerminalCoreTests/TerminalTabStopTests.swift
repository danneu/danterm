// Verifies mutable terminal tab stops, their dispatch rules, and resize behavior.
import Testing

@testable import TerminalCore

/// Pins tab navigation to stored stops rather than a hardcoded every-eight calculation.
struct TerminalTabStopTests {
    @Test("HTS and TBC control the stops visited by horizontal tab")
    func tabStopDispatch() throws {
        var terminal = try #require(Terminal(columns: 12, rows: 1))
        terminal.moveCursor(row: 0, column: 3)
        terminal.feed(Array("\u{1B}H".utf8))
        terminal.moveCursor(row: 0, column: 5)
        terminal.feed(Array("\u{1B}H".utf8))

        terminal.moveCursor(row: 0, column: 0)
        terminal.feed([0x09])
        #expect(terminal.geometry.cursor.column == 3)
        terminal.feed([0x09])
        #expect(terminal.geometry.cursor.column == 5)
        terminal.feed(Array("\u{1B}[g".utf8))
        terminal.moveCursor(row: 0, column: 3)
        terminal.feed([0x09])
        #expect(terminal.geometry.cursor.column == 8)

        terminal.feed(Array("\u{1B}[3g".utf8))
        terminal.moveCursor(row: 0, column: 0)
        terminal.feed([0x09])
        #expect(terminal.geometry.cursor.column == 11)
        #expect(terminal.geometry.rows[0].cells.allSatisfy { $0.kind == .padding })
    }

    @Test("invalid TBC forms are bit-identical while valid forms clear pending state")
    func tabClearNormalizationAndSideState() throws {
        for sequence in ["\u{1B}[1g", "\u{1B}[5g", "\u{1B}[0;3g"] {
            var terminal = try #require(Terminal(columns: 2, rows: 2))
            terminal.feed(Array("AB".utf8))
            let expected = terminal
            terminal.feed(Array(sequence.utf8))
            #expect(terminal == expected)
        }

        for sequence in ["\u{1B}H", "\u{1B}[g", "\u{1B}[0g", "\u{1B}[3g"] {
            var terminal = try #require(Terminal(columns: 2, rows: 2))
            terminal.feed(Array("AB".utf8))
            terminal.feed(Array(sequence.utf8))
            #expect(terminal.geometry.cursor.isPendingWrap == false)
        }
    }

    @Test("HT at the last column preserves pending wrap and the open cluster")
    func tabAtLastColumnIsBitIdentical() throws {
        var terminal = try #require(Terminal(columns: 2, rows: 2))
        terminal.feed(Array("AB\u{200D}".utf8))
        let expected = terminal

        terminal.feed([0x09])

        #expect(terminal == expected)
    }

    @Test("resize preserves retained stops and defaults newly introduced columns")
    func tabStopsAcrossResize() throws {
        // Intent: distinguish retained custom stop state from defaults synthesized
        //   only for columns that a width growth newly introduces.
        // Why it exists: recomputing all stops on resize would resurrect cleared
        //   retained stops, while preserving all stops would retain shrunken ones.
        // Scenario: a shell customizes the first screen, grows it, shrinks it, and
        //   later grows it again after the old right-hand columns were discarded.
        var terminal = try #require(Terminal(columns: 12, rows: 2))
        terminal.moveCursor(row: 0, column: 3)
        terminal.feed(Array("\u{1B}H".utf8))
        terminal.moveCursor(row: 0, column: 8)
        terminal.feed(Array("\u{1B}[g".utf8))

        terminal.resize(columns: 20, rows: 2)
        terminal.moveCursor(row: 0, column: 0)
        terminal.feed([0x09])
        #expect(terminal.geometry.cursor.column == 3)
        terminal.feed(Array("\u{1B}[g".utf8))
        terminal.moveCursor(row: 0, column: 0)
        terminal.feed([0x09])
        #expect(terminal.geometry.cursor.column == 16)
        terminal.moveCursor(row: 0, column: 17)
        terminal.feed(Array("\u{1B}H".utf8))

        terminal.resize(columns: 10, rows: 2)
        terminal.resize(columns: 20, rows: 2)
        terminal.moveCursor(row: 0, column: 0)
        terminal.feed([0x09])
        #expect(terminal.geometry.cursor.column == 16)
        terminal.feed([0x09])
        #expect(terminal.geometry.cursor.column == 19)
    }

    @Test("tab stops participate in terminal equality")
    func tabStopsAffectEquality() throws {
        var customized = try #require(Terminal(columns: 10, rows: 1))
        customized.moveCursor(row: 0, column: 3)
        var baseline = customized

        customized.feed(Array("\u{1B}H".utf8))

        #expect(customized != baseline)
        baseline.feed(Array("\u{1B}H".utf8))
        #expect(customized == baseline)
    }
}
