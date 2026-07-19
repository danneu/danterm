// Proves CSI cursor movement and positioning through the public byte-ingestion boundary.
import Testing

@testable import TerminalCore

/// Locks the first interpreted CSI family to bounded default-mode cursor semantics.
struct CSICursorMovementTests {
    @Test(
        "relative cursor movement defaults, aliases, and clamps",
        arguments: [
            MovementFixture(sequence: "\u{1B}[A", start: (2, 2), expected: (1, 2)),
            MovementFixture(sequence: "\u{1B}[0A", start: (2, 2), expected: (1, 2)),
            MovementFixture(sequence: "\u{1B}[2k", start: (2, 2), expected: (0, 2)),
            MovementFixture(sequence: "\u{1B}[B", start: (2, 2), expected: (3, 2)),
            MovementFixture(sequence: "\u{1B}[0B", start: (2, 2), expected: (3, 2)),
            MovementFixture(sequence: "\u{1B}[C", start: (2, 2), expected: (2, 3)),
            MovementFixture(sequence: "\u{1B}[0C", start: (2, 2), expected: (2, 3)),
            MovementFixture(sequence: "\u{1B}[a", start: (2, 2), expected: (2, 3)),
            MovementFixture(sequence: "\u{1B}[0a", start: (2, 2), expected: (2, 3)),
            MovementFixture(sequence: "\u{1B}[D", start: (2, 2), expected: (2, 1)),
            MovementFixture(sequence: "\u{1B}[0D", start: (2, 2), expected: (2, 1)),
            MovementFixture(sequence: "\u{1B}[2j", start: (2, 2), expected: (2, 0)),
            MovementFixture(sequence: "\u{1B}[e", start: (2, 2), expected: (3, 2)),
            MovementFixture(sequence: "\u{1B}[0e", start: (2, 2), expected: (3, 2)),
            MovementFixture(sequence: "\u{1B}[99A", start: (2, 2), expected: (0, 2)),
            MovementFixture(sequence: "\u{1B}[99B", start: (2, 2), expected: (4, 2)),
            MovementFixture(sequence: "\u{1B}[99C", start: (2, 2), expected: (2, 4)),
            MovementFixture(sequence: "\u{1B}[99a", start: (2, 2), expected: (2, 4)),
            MovementFixture(sequence: "\u{1B}[99D", start: (2, 2), expected: (2, 0)),
            MovementFixture(sequence: "\u{1B}[99e", start: (2, 2), expected: (4, 2)),
        ]
    )
    func relativeMovement(fixture: MovementFixture) throws {
        var terminal = try #require(Terminal(columns: 5, rows: 5))
        terminal.moveCursor(row: fixture.start.row, column: fixture.start.column)

        terminal.feed(Array(fixture.sequence.utf8))

        #expect(terminal.geometry.cursor == TerminalCursor(
            row: fixture.expected.row,
            column: fixture.expected.column,
            isPendingWrap: false
        ))
    }

    @Test(
        "next and previous line movement resets the column and clamps",
        arguments: [
            MovementFixture(sequence: "\u{1B}[E", start: (2, 3), expected: (3, 0)),
            MovementFixture(sequence: "\u{1B}[0E", start: (2, 3), expected: (3, 0)),
            MovementFixture(sequence: "\u{1B}[99E", start: (2, 3), expected: (4, 0)),
            MovementFixture(sequence: "\u{1B}[F", start: (2, 3), expected: (1, 0)),
            MovementFixture(sequence: "\u{1B}[0F", start: (2, 3), expected: (1, 0)),
            MovementFixture(sequence: "\u{1B}[99F", start: (2, 3), expected: (0, 0)),
        ]
    )
    func lineMovement(fixture: MovementFixture) throws {
        var terminal = try #require(Terminal(columns: 5, rows: 5))
        terminal.moveCursor(row: fixture.start.row, column: fixture.start.column)

        terminal.feed(Array(fixture.sequence.utf8))

        #expect(terminal.geometry.cursor == TerminalCursor(
            row: fixture.expected.row,
            column: fixture.expected.column,
            isPendingWrap: false
        ))
    }

    @Test(
        "absolute row and column positioning is one-based, defaulted, aliased, and clamped",
        arguments: [
            MovementFixture(sequence: "\u{1B}[G", start: (2, 3), expected: (2, 0)),
            MovementFixture(sequence: "\u{1B}[0G", start: (2, 3), expected: (2, 0)),
            MovementFixture(sequence: "\u{1B}[4G", start: (2, 0), expected: (2, 3)),
            MovementFixture(sequence: "\u{1B}[3`", start: (2, 0), expected: (2, 2)),
            MovementFixture(sequence: "\u{1B}[99G", start: (2, 0), expected: (2, 4)),
            MovementFixture(sequence: "\u{1B}[d", start: (3, 2), expected: (0, 2)),
            MovementFixture(sequence: "\u{1B}[0d", start: (3, 2), expected: (0, 2)),
            MovementFixture(sequence: "\u{1B}[4d", start: (0, 2), expected: (3, 2)),
            MovementFixture(sequence: "\u{1B}[99d", start: (0, 2), expected: (4, 2)),
        ]
    )
    func axisPositioning(fixture: MovementFixture) throws {
        var terminal = try #require(Terminal(columns: 5, rows: 5))
        terminal.moveCursor(row: fixture.start.row, column: fixture.start.column)

        terminal.feed(Array(fixture.sequence.utf8))

        #expect(terminal.geometry.cursor == TerminalCursor(
            row: fixture.expected.row,
            column: fixture.expected.column,
            isPendingWrap: false
        ))
    }

    @Test(
        "CUP and HVP default coordinates independently and clamp",
        arguments: [
            MovementFixture(sequence: "\u{1B}[H", start: (3, 3), expected: (0, 0)),
            MovementFixture(sequence: "\u{1B}[0;0H", start: (3, 3), expected: (0, 0)),
            MovementFixture(sequence: "\u{1B}[3H", start: (0, 4), expected: (2, 0)),
            MovementFixture(sequence: "\u{1B}[3;H", start: (0, 4), expected: (2, 0)),
            MovementFixture(sequence: "\u{1B}[;4H", start: (4, 0), expected: (0, 3)),
            MovementFixture(sequence: "\u{1B}[4;5H", start: (0, 0), expected: (3, 4)),
            MovementFixture(sequence: "\u{1B}[2;3f", start: (4, 4), expected: (1, 2)),
            MovementFixture(sequence: "\u{1B}[99;99H", start: (0, 0), expected: (4, 4)),
        ]
    )
    func twoAxisPositioning(fixture: MovementFixture) throws {
        var terminal = try #require(Terminal(columns: 5, rows: 5))
        terminal.moveCursor(row: fixture.start.row, column: fixture.start.column)

        terminal.feed(Array(fixture.sequence.utf8))

        #expect(terminal.geometry.cursor == TerminalCursor(
            row: fixture.expected.row,
            column: fixture.expected.column,
            isPendingWrap: false
        ))
    }

    @Test(
        "invalid or unsupported CSI leaves movement state bit-identical",
        arguments: [
            "\u{1B}[1;2A",
            "\u{1B}[1;2G",
            "\u{1B}[1;2d",
            "\u{1B}[1;2;3H",
            "\u{1B}[?2A",
            "\u{1B}[1:2A",
            "\u{1B}[9z",
        ]
    )
    func invalidMovementIsNoOp(sequence: String) throws {
        // Intent: require the CSI interpretation gate to reject bad arity,
        //   intermediates, colon-dropped input, and unsupported finals.
        // Why it exists: merely recognizing a movement-like final must not
        //   disturb cursor state that later printable input depends on.
        // Scenario: a full last column has pending wrap and an attachment
        //   target when malformed or unsupported terminal output arrives.
        var terminal = try #require(Terminal(columns: 2, rows: 2))
        terminal.feed(Array("AB".utf8))
        let expected = terminal

        terminal.feed(Array(sequence.utf8))

        #expect(terminal == expected)
    }

    @Test(
        "valid movement clears pending wrap and the combining attachment target",
        arguments: ["\u{1B}[C", "\u{1B}[a", "\u{1B}[B", "\u{1B}[e"]
    )
    func movementClearsPendingState(sequence: String) throws {
        // Intent: prove even a clamped movement dispatch clears both forms of
        //   pending state before the next printable or zero-width scalar.
        // Why it exists: coordinate equality alone cannot prove a valid CSI
        //   dispatch happened when the cursor is already at the target edge.
        // Scenario: output fills the last column, moves right at the boundary,
        //   then sends a combining mark that must not attach to the old cell.
        var terminal = try #require(Terminal(columns: 2, rows: 2))
        terminal.feed(Array("AB".utf8))
        terminal.feed(Array(sequence.utf8))
        terminal.feed(Array("\u{0301}".utf8))

        #expect(terminal.geometry.cursor.isPendingWrap == false)
        #expect(terminal.cell(row: 0, column: 1)?.scalars == ["B"])
        #expect(terminal.geometry.rows[0].isSoftWrapped == false)
    }

    @Test("cursor movement never scrolls or changes grid contents")
    func movementDoesNotScroll() throws {
        // Intent: pin relative movement at the bottom edge to cursor-only
        //   mutation, preserving cells and row soft-wrap identity.
        // Why it exists: line-feed already scrolls at the bottom, so cursor
        //   down must not accidentally share that mutation path.
        // Scenario: a wrapped two-row viewport receives a large CUD request
        //   while its cursor is already on the bottom row.
        var terminal = try #require(Terminal(columns: 3, rows: 2))
        terminal.feed(Array("ABCD".utf8))
        let expectedText = terminal.screenText
        let expectedRows = terminal.geometry.rows

        terminal.feed(Array("\u{1B}[99B".utf8))

        #expect(terminal.screenText == expectedText)
        #expect(terminal.geometry.rows == expectedRows)
        #expect(terminal.geometry.cursor == TerminalCursor(row: 1, column: 1, isPendingWrap: false))
    }

    struct MovementFixture: Sendable {
        let sequence: String
        let start: (row: Int, column: Int)
        let expected: (row: Int, column: Int)
    }
}
