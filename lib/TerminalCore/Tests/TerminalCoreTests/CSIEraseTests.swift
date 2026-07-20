// Proves CSI line, display, and character erasure through public byte ingestion.
import Testing

@testable import TerminalCore

/// Locks erase dispatch to padding-producing, wide-safe default-mode semantics.
struct CSIEraseTests {
    @Test(
        "EL modes erase their inclusive regions and widen across wide cells",
        arguments: [
            EraseLineFixture(
                sequence: "\u{1B}[K",
                cursorColumn: 2,
                expectedKinds: [.narrow, .padding, .padding, .padding, .padding, .padding]
            ),
            EraseLineFixture(
                sequence: "\u{1B}[1K",
                cursorColumn: 1,
                expectedKinds: [.padding, .padding, .padding, .narrow, .narrow, .padding]
            ),
            EraseLineFixture(
                sequence: "\u{1B}[2K",
                cursorColumn: 3,
                expectedKinds: [.padding, .padding, .padding, .padding, .padding, .padding]
            ),
        ]
    )
    func eraseLineRegions(fixture: EraseLineFixture) throws {
        // Intent: prove each EL mode erases its inclusive region without
        //   leaving either half of an intersected wide cell behind.
        // Why it exists: both the cursor boundary and the erase endpoint can
        //   bisect the storage pair used for a double-width character.
        // Scenario: terminal output erases right, left, or the whole line
        //   while the cursor sits on one half of a Chinese glyph.
        var terminal = try #require(Terminal(columns: 6, rows: 2))
        terminal.feed(Array("A\u{754C}BC".utf8))
        terminal.moveCursor(row: 0, column: fixture.cursorColumn)
        let expectedCursor = terminal.geometry.cursor

        terminal.feed(Array(fixture.sequence.utf8))

        #expect(terminal.geometry.rows[0].cells.map(\.kind) == fixture.expectedKinds)
        #expect(terminal.geometry.cursor == expectedCursor)
        expectValidGrid(terminal)
    }

    @Test("EL right resets soft wrap while left and complete preserve it")
    func eraseLineWrapAsymmetry() throws {
        // Intent: pin the reference-compatible difference between EL 0 and
        //   the other line-erasure modes.
        // Why it exists: clearing the same row does not imply clearing its
        //   logical continuation flag for EL 1 or EL 2.
        // Scenario: a soft-wrapped shell line is partially or fully erased.
        for (sequence, expectedWrap) in [
            ("\u{1B}[0K", false),
            ("\u{1B}[1K", true),
            ("\u{1B}[2K", true),
        ] {
            var terminal = try #require(Terminal(columns: 4, rows: 2))
            terminal.feed(Array("ABCDE".utf8))
            terminal.moveCursor(row: 0, column: 2)

            terminal.feed(Array(sequence.utf8))

            #expect(terminal.geometry.rows[0].isSoftWrapped == expectedWrap)
            #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 2, isPendingWrap: false))
            expectValidGrid(terminal)
        }
    }

    @Test(
        "ED modes erase the display regions and reset only fully cleared row wraps",
        arguments: [0, 1, 2]
    )
    func eraseDisplayRegions(mode: Int) throws {
        // Intent: prove ED composes its cursor-row EL behavior with complete
        //   row clearing above or below, preserving the cursor.
        // Why it exists: partial display erasure has asymmetric row-wrap
        //   effects and can otherwise clear one row too many or too few.
        // Scenario: a three-row wrapped viewport receives ED below, above,
        //   or complete while the cursor is in the middle row.
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("ABCDEFGHIJKL".utf8))
        terminal.moveCursor(row: 1, column: 2)
        let expectedCursor = terminal.geometry.cursor

        terminal.feed(Array("\u{1B}[\(mode)J".utf8))

        let kinds = terminal.geometry.rows.map { $0.cells.map(\.kind) }
        switch mode {
        case 0:
            #expect(kinds[0] == Array(repeating: .narrow, count: 4))
            #expect(kinds[1] == [.narrow, .narrow, .padding, .padding])
            #expect(kinds[2] == Array(repeating: .padding, count: 4))
            #expect(terminal.geometry.rows.map(\.isSoftWrapped) == [true, false, false])
        case 1:
            #expect(kinds[0] == Array(repeating: .padding, count: 4))
            #expect(kinds[1] == [.padding, .padding, .padding, .narrow])
            #expect(kinds[2] == Array(repeating: .narrow, count: 4))
            #expect(terminal.geometry.rows.map(\.isSoftWrapped) == [false, true, false])
        default:
            #expect(kinds.allSatisfy { $0 == Array(repeating: .padding, count: 4) })
            #expect(terminal.geometry.rows.allSatisfy { $0.isSoftWrapped == false })
        }
        #expect(terminal.geometry.cursor == expectedCursor)
        expectValidGrid(terminal)
    }

    @Test("home then ED complete clears the viewport without moving the home cursor")
    func canonicalClearScreenPair() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("ABCDEFGHI".utf8))

        terminal.feed(Array("\u{1B}[H\u{1B}[2J".utf8))

        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))
        #expect(terminal.geometry.rows.allSatisfy { row in
            row.cells.allSatisfy { $0.kind == .padding } && row.isSoftWrapped == false
        })
        expectValidGrid(terminal)
    }

    @Test("ED 3 clears only scrollback and pending motion state")
    func eraseDisplayScrollback() throws {
        // Intent: clear retained history without changing viewport, cursor,
        //   pen, or active region, while ending deferred wrap and attachment.
        // Why it exists: ED 3 shares dispatch with active-grid erase modes but
        //   has a distinct target and the slice-wide side-state policy.
        // Scenario: a shell clears its transcript while a bounded TUI remains
        //   displayed and continues scrolling inside the same margins.
        var terminal = try #require(Terminal(columns: 3, rows: 3))
        terminal.feed(Array("ABCDEFGHIJ".utf8))
        terminal.feed(Array("\u{1B}[2;3r\u{1B}[3;2H\u{1B}[1;31;44m".utf8))
        let expectedGeometry = terminal.geometry
        let expectedStyle = terminal.currentStyle
        #expect(terminal.scrollbackRowCount == 1)

        terminal.feed(Array("\u{1B}[3J".utf8))

        #expect(terminal.scrollbackRowCount == 0)
        #expect(terminal.geometry == expectedGeometry)
        #expect(terminal.currentStyle == expectedStyle)
        #expect(terminal.geometry.cursor?.isPendingWrap == false)
        terminal.feed(Array("\u{1B}[S".utf8))
        #expect(terminal.scrollbackRowCount == 0)
        expectValidGrid(terminal)

        let once = terminal
        terminal.feed(Array("\u{1B}[3J".utf8))
        #expect(terminal == once)

        terminal.moveCursor(row: 0, column: 0)
        terminal.feed(Array("Z".utf8))
        #expect(terminal.cell(row: 0, column: 0)?.scalars == ["Z"])
        expectValidGrid(terminal)

        var combining = try #require(Terminal(columns: 3, rows: 1))
        combining.feed(Array("A\u{1B}[3J\u{0301}".utf8))
        #expect(combining.cell(row: 0, column: 0)?.scalars == ["A"])
    }

    @Test("ECH defaults and zero to one, clamps, widens, and supports two columns")
    func eraseCharactersMatrix() throws {
        // Intent: cover ECH count defaulting, clamping, and wide-pair boundary
        //   expansion on normal and minimal grid widths.
        // Why it exists: a one-cell erase can start on a wide tail, while a
        //   large count must clamp without overrunning the row.
        // Scenario: an application blanks characters under the cursor in a
        //   line containing Chinese text.
        for sequence in ["\u{1B}[X", "\u{1B}[0X"] {
            var terminal = try #require(Terminal(columns: 6, rows: 1))
            terminal.feed(Array("A\u{754C}BC".utf8))
            terminal.moveCursor(row: 0, column: 2)
            let expectedCursor = terminal.geometry.cursor

            terminal.feed(Array(sequence.utf8))

            #expect(terminal.geometry.rows[0].cells.map(\.kind) == [
                .narrow, .padding, .padding, .narrow, .narrow, .padding,
            ])
            #expect(terminal.geometry.cursor == expectedCursor)
            expectValidGrid(terminal)
        }

        var clamped = try #require(Terminal(columns: 6, rows: 1))
        clamped.feed(Array("ABCDEF".utf8))
        clamped.moveCursor(row: 0, column: 3)
        clamped.feed(Array("\u{1B}[99X".utf8))
        #expect(clamped.geometry.rows[0].cells.map(\.kind) == [
            .narrow, .narrow, .narrow, .padding, .padding, .padding,
        ])
        expectValidGrid(clamped)

        var minimal = try #require(Terminal(columns: 2, rows: 1))
        minimal.feed(Array("\u{754C}".utf8))
        minimal.moveCursor(row: 0, column: 0)
        minimal.feed(Array("\u{1B}[X".utf8))
        #expect(minimal.geometry.rows[0].cells.map(\.kind) == [.padding, .padding])
        expectValidGrid(minimal)
    }

    @Test("ECH resets a mid-row wrap and clears the preceding spacer head")
    func eraseCharactersWrapAndSpacerCleanup() throws {
        // Intent: prove ECH resets logical wrap even for a short mid-row
        //   range and repairs the spacer linking a wrapped wide character.
        // Why it exists: range erasure alone does not describe either row
        //   metadata or the previous row's trailing spacer representation.
        // Scenario: a wrapped line is blanked in place, including a wide
        //   glyph that wrapped from a spacer at the prior right margin.
        var midRow = try #require(Terminal(columns: 4, rows: 2))
        midRow.feed(Array("ABCDE".utf8))
        midRow.moveCursor(row: 0, column: 1)
        midRow.feed(Array("\u{1B}[X".utf8))
        #expect(midRow.geometry.rows[0].isSoftWrapped == false)
        expectValidGrid(midRow)

        var spacer = try #require(Terminal(columns: 4, rows: 2))
        spacer.moveCursor(row: 0, column: 3)
        spacer.feed(Array("\u{754C}".utf8))
        #expect(spacer.geometry.rows[0].cells[3].kind == .spacerHead)
        spacer.moveCursor(row: 1, column: 0)
        spacer.feed(Array("\u{1B}[X".utf8))
        #expect(spacer.geometry.rows[0].cells[3].kind == .padding)
        expectValidGrid(spacer)
    }

    @Test("active-grid erases clear pending wrap and combining attachment")
    func activeEraseClearsPendingState() throws {
        // Intent: prove interpreted EL, ED, and ECH dispatches clear deferred
        //   wrap, and a mutating erase blocks later combining attachment.
        // Why it exists: visible cell assertions cannot observe stale parser-
        //   adjacent state that changes the next scalar's behavior.
        // Scenario: terminal output erases while a last-column wrap or a
        //   previous printable attachment target is pending.
        for sequence in ["\u{1B}[K", "\u{1B}[J", "\u{1B}[X"] {
            var terminal = try #require(Terminal(columns: 2, rows: 2))
            terminal.feed(Array("AB".utf8))
            terminal.feed(Array(sequence.utf8))
            #expect(terminal.geometry.cursor?.isPendingWrap == false)
            expectValidGrid(terminal)
        }

        var combining = try #require(Terminal(columns: 4, rows: 1))
        combining.feed(Array("A\u{1B}[X\u{0301}".utf8))
        #expect(combining.cell(row: 0, column: 0)?.scalars == ["A"])
        expectValidGrid(combining)
    }

    @Test("erasure produces padding rather than written spaces")
    func eraseProducesPadding() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 1))
        terminal.feed(Array("A B".utf8))
        terminal.moveCursor(row: 0, column: 1)
        let expectedCursor = terminal.geometry.cursor

        terminal.feed(Array("\u{1B}[X".utf8))

        #expect(terminal.screenText == "A B ")
        #expect(terminal.geometry.rows[0].cells[1].kind == .padding)
        #expect(terminal.geometry.cursor == expectedCursor)
        expectValidGrid(terminal)
    }

    @Test(
        "invalid erase dispatches leave terminal state bit-identical",
        arguments: [
            "\u{1B}[1;2K",
            "\u{1B}[3K",
            "\u{1B}[1;2J",
            "\u{1B}[4J",
            "\u{1B}[22J",
            "\u{1B}[1;2X",
            "\u{1B}[?K",
            "\u{1B}[1:2K",
        ]
    )
    func invalidEraseIsNoOp(sequence: String) throws {
        // Intent: enforce erase arity, mode, intermediate, and colon gates
        //   before any grid or pending-state mutation occurs.
        // Why it exists: malformed terminal output must not partially clear
        //   a line or consume deferred wrap state.
        // Scenario: a full last column has pending wrap when an unsupported
        //   erase-shaped CSI dispatch arrives.
        var terminal = try #require(Terminal(columns: 2, rows: 2))
        terminal.feed(Array("AB".utf8))
        let expected = terminal

        terminal.feed(Array(sequence.utf8))

        #expect(terminal == expected)
    }

    struct EraseLineFixture: Sendable {
        let sequence: String
        let cursorColumn: Int
        let expectedKinds: [TerminalCellKind]
    }

}
