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
        #expect(terminal.geometry.cursor?.column == 3)
        terminal.feed([0x09])
        #expect(terminal.geometry.cursor?.column == 5)
        terminal.feed(Array("\u{1B}[g".utf8))
        terminal.moveCursor(row: 0, column: 3)
        terminal.feed([0x09])
        #expect(terminal.geometry.cursor?.column == 8)

        terminal.feed(Array("\u{1B}[3g".utf8))
        terminal.moveCursor(row: 0, column: 0)
        terminal.feed([0x09])
        #expect(terminal.geometry.cursor?.column == 11)
        #expect(terminal.geometry.rows[0].cells.allSatisfy { $0.kind == .padding })
    }

    @Test("HTS and valid TBC forms preserve pending wrap")
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
            #expect(terminal.geometry.cursor?.isPendingWrap == true)
            terminal.feed(Array("C".utf8))
            #expect(terminal.screenText == "AB\nC ")

            var cluster = try #require(Terminal(columns: 3, rows: 1))
            cluster.feed(Array("A\u{200D}\(sequence)\u{0301}".utf8))
            #expect(cluster.cell(row: 0, column: 0)?.scalars == ["A", "\u{200D}", "\u{0301}"])
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

    @Test(
        "CHT and CBT walk stored tab stops, default zero to one, and clamp",
        arguments: [
            CursorTabFixture(sequence: "\u{1B}[I", start: 0, expected: 8),
            CursorTabFixture(sequence: "\u{1B}[0I", start: 0, expected: 8),
            CursorTabFixture(sequence: "\u{1B}[2I", start: 0, expected: 16),
            CursorTabFixture(sequence: "\u{1B}[9I", start: 17, expected: 19),
            CursorTabFixture(sequence: "\u{1B}[Z", start: 19, expected: 16),
            CursorTabFixture(sequence: "\u{1B}[0Z", start: 9, expected: 8),
            CursorTabFixture(sequence: "\u{1B}[2Z", start: 19, expected: 8),
            CursorTabFixture(sequence: "\u{1B}[9Z", start: 0, expected: 0),
        ]
    )
    func cursorTabMovement(fixture: CursorTabFixture) throws {
        var terminal = try #require(Terminal(columns: 20, rows: 1))
        terminal.moveCursor(row: 0, column: fixture.start)

        terminal.feed(Array(fixture.sequence.utf8))

        #expect(terminal.geometry.cursor == TerminalCursor(
            row: 0,
            column: fixture.expected,
            isPendingWrap: false
        ))
    }

    @Test(
        "CHT and CBT clear pending wrap and the combining attachment target at the last column",
        arguments: ["\u{1B}[I", "\u{1B}[Z"]
    )
    func cursorTabClearsPendingState(sequence: String) throws {
        // Intent: prove both cursor-tab directions dispatch through positioned
        //   movement, even when CHT clamps at the right edge.
        // Why it exists: coordinate equality cannot distinguish a valid clamped
        //   CHT from an ignored sequence, and a stale cluster could absorb input.
        // Scenario: output fills the last column, uses a cursor-tab command,
        //   then sends a combining mark that must not attach to the old cell.
        var terminal = try #require(Terminal(columns: 20, rows: 1))
        terminal.feed(Array(String(repeating: "A", count: 20).utf8))

        terminal.feed(Array(sequence.utf8))
        terminal.feed(Array("\u{0301}".utf8))

        #expect(terminal.geometry.cursor?.isPendingWrap == false)
        #expect(terminal.cell(row: 0, column: 19)?.scalars == ["A"])
        #expect(terminal.geometry.rows[0].isSoftWrapped == false)
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
        #expect(terminal.geometry.cursor?.column == 3)
        terminal.feed(Array("\u{1B}[g".utf8))
        terminal.moveCursor(row: 0, column: 0)
        terminal.feed([0x09])
        #expect(terminal.geometry.cursor?.column == 16)
        terminal.moveCursor(row: 0, column: 17)
        terminal.feed(Array("\u{1B}H".utf8))

        terminal.resize(columns: 10, rows: 2)
        terminal.resize(columns: 20, rows: 2)
        terminal.moveCursor(row: 0, column: 0)
        terminal.feed([0x09])
        #expect(terminal.geometry.cursor?.column == 16)
        terminal.feed([0x09])
        #expect(terminal.geometry.cursor?.column == 19)
    }

    @Test("tab past the last default stop clamps to the last column")
    func tabClampsWithDefaultStopsPresent() throws {
        // Intent: with the default every-eight stops intact and the cursor already past the
        //   last one that fits, HT clamps to the final column instead of running off the row.
        // Why it exists: `tabStopDispatch` reaches the clamp only after `ESC[3g` has cleared
        //   every stop, so it exercises the empty-stop-set path. An implementation that kept
        //   the set for custom stops only and computed the defaults arithmetically -- a
        //   plausible optimization, since the stop filter runs per HT -- would answer 16 here
        //   and still pass that test. This is the defaults-present case.
        // Scenario: a 12-column pane where the shell tabs twice from the left margin.
        var terminal = try #require(Terminal(columns: 12, rows: 1))

        terminal.feed([0x09])
        #expect(terminal.geometry.cursor?.column == 8)
        terminal.feed([0x09])
        #expect(terminal.geometry.cursor?.column == 11)
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

    struct CursorTabFixture: Sendable {
        let sequence: String
        let start: Int
        let expected: Int
    }
}
