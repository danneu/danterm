// Verifies cursor appearance and synchronized-update state through public terminal controls.
import Testing

@testable import TerminalCore

/// Pins presentation-only terminal state without coupling it to renderer policy.
struct TerminalPresentationModeTests {
    @Test("presentation modes start at DanTerm defaults and map every supported control")
    func defaultsAndControlMapping() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        #expect(terminal.presentation == TerminalPresentation(
            isCursorVisible: true,
            cursorShape: .block,
            isCursorBlinking: false,
            isSynchronizedOutputActive: false
        ))

        terminal.feed(Array("\u{1B}[?25l\u{1B}[?2026h".utf8))
        #expect(terminal.presentation.isCursorVisible == false)
        #expect(terminal.presentation.isSynchronizedOutputActive)

        let mappings: [(String, TerminalCursorShape, Bool)] = [
            ("\u{1B}[ q", .block, true),
            ("\u{1B}[0 q", .block, true),
            ("\u{1B}[1 q", .block, true),
            ("\u{1B}[2 q", .block, false),
            ("\u{1B}[3 q", .underline, true),
            ("\u{1B}[4 q", .underline, false),
            ("\u{1B}[5 q", .bar, true),
            ("\u{1B}[6 q", .bar, false),
        ]
        for (sequence, shape, isBlinking) in mappings {
            terminal.feed(Array(sequence.utf8))
            #expect(terminal.presentation.cursorShape == shape)
            #expect(terminal.presentation.isCursorBlinking == isBlinking)
        }

        terminal.feed(Array("\u{1B}[?25h\u{1B}[?2026l".utf8))
        #expect(terminal.presentation.isCursorVisible)
        #expect(terminal.presentation.isSynchronizedOutputActive == false)
    }

    @Test("invalid cursor styles are inert and presentation controls preserve print-side state")
    func invalidStylesAndPrintSideState() throws {
        for sequence in ["\u{1B}[7 q", "\u{1B}[99 q", "\u{1B}[1;2 q"] {
            var terminal = try #require(Terminal(columns: 3, rows: 2))
            let expected = terminal
            terminal.feed(Array(sequence.utf8))
            #expect(terminal == expected)
        }

        var pending = try #require(Terminal(columns: 2, rows: 2))
        pending.feed(Array("AB\u{1B}[?25l\u{1B}[6 q\u{1B}[?2026hX".utf8))
        #expect(pending.screenText == "AB\nX ")

        var cluster = try #require(Terminal(columns: 4, rows: 1))
        cluster.feed(Array("A\u{200D}\u{1B}[?25l\u{1B}[6 q\u{1B}[?2026h\u{0301}".utf8))
        #expect(cluster.cell(row: 0, column: 0)?.scalars == ["A", "\u{200D}", "\u{0301}"])
        #expect(cluster.geometry.cursor == TerminalCursor(row: 0, column: 1, isPendingWrap: false))
    }

    @Test("presentation state is shared across alternate-screen switches")
    func alternateScreenPreservesPresentationState() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("\u{1B}[?25l\u{1B}[5 q\u{1B}[?2026h\u{1B}[?1047h".utf8))
        #expect(terminal.presentation == TerminalPresentation(
            isCursorVisible: false,
            cursorShape: .bar,
            isCursorBlinking: true,
            isSynchronizedOutputActive: true
        ))

        terminal.feed(Array("\u{1B}[?1047l".utf8))
        #expect(terminal.presentation == TerminalPresentation(
            isCursorVisible: false,
            cursorShape: .bar,
            isCursorBlinking: true,
            isSynchronizedOutputActive: true
        ))
    }

    @Test(
        "every saved-cursor path round-trips cursor appearance",
        arguments: [
            ("\u{1B}7", "\u{1B}8"),
            ("\u{1B}[s", "\u{1B}[u"),
            ("\u{1B}[?1048h", "\u{1B}[?1048l"),
            ("\u{1B}[?1049h", "\u{1B}[?1049l"),
        ]
    )
    func savedCursorAppearance(save: String, restore: String) throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("\u{1B}[?25l\u{1B}[6 q\(save)".utf8))
        terminal.feed(Array("\u{1B}[?25h\u{1B}[3 q\(restore)".utf8))

        #expect(terminal.presentation.isCursorVisible == false)
        #expect(terminal.presentation.cursorShape == .bar)
        #expect(terminal.presentation.isCursorBlinking == false)
    }

    @Test("saved cursor appearance is independent on the primary and alternate screens")
    func savedAppearanceIsScreenScoped() throws {
        // Intent: cursor visibility, shape, and blink restore from the active screen's save.
        // Why it exists: position isolation alone would leave half of DECSC shared by accident.
        // Scenario: the primary and alternate screens save visibly different cursor appearances.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("\u{1B}[?25h\u{1B}[3 q\u{1B}7\u{1B}[?1047h".utf8))
        terminal.feed(Array("\u{1B}[?25l\u{1B}[6 q\u{1B}7\u{1B}[?1047l\u{1B}8".utf8))

        #expect(terminal.presentation.isCursorVisible)
        #expect(terminal.presentation.cursorShape == .underline)
        #expect(terminal.presentation.isCursorBlinking)

        terminal.feed(Array("\u{1B}[?1047h\u{1B}8".utf8))
        #expect(terminal.presentation.isCursorVisible == false)
        #expect(terminal.presentation.cursorShape == .bar)
        #expect(terminal.presentation.isCursorBlinking == false)
    }

    @Test("soft and hard reset restore defaults but preserve saved appearance")
    func resetMatrix() throws {
        for reset in ["\u{1B}[!p", "\u{1B}c"] {
            var terminal = try #require(Terminal(columns: 4, rows: 2))
            terminal.feed(Array("\u{1B}[?25l\u{1B}[6 q\u{1B}7".utf8))
            terminal.feed(Array("\u{1B}[?25h\u{1B}[3 q\u{1B}[?2026h\(reset)".utf8))
            #expect(terminal.presentation == TerminalPresentation(
                isCursorVisible: true,
                cursorShape: .block,
                isCursorBlinking: false,
                isSynchronizedOutputActive: false
            ))

            terminal.feed(Array("\u{1B}8".utf8))
            #expect(terminal.presentation.isCursorVisible == false)
            #expect(terminal.presentation.cursorShape == .bar)
            #expect(terminal.presentation.isCursorBlinking == false)
            #expect(terminal.presentation.isSynchronizedOutputActive == false)
        }
    }

    @Test("presentation controls are invariant across every byte boundary")
    func chunkInvariance() throws {
        let bytes = Array("A\u{200D}\u{1B}[?25l\u{1B}[5 q\u{1B}[?2026h\u{1B}7\u{1B}[?1047h\u{1B}[?1047l\u{1B}8".utf8)
        var oneChunk = try #require(Terminal(columns: 5, rows: 2))
        oneChunk.feed(bytes)
        var bytewise = try #require(Terminal(columns: 5, rows: 2))
        for byte in bytes {
            bytewise.feed([byte])
        }

        #expect(oneChunk == bytewise)
    }
}
