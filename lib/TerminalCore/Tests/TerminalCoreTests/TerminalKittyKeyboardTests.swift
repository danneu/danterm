// Verifies terminal keyboard-mode state, negotiation replies, screen stacks, and reset behavior.
import Testing

@testable import TerminalCore

/// Locks keyboard protocol state to honest replies and per-screen stack semantics.
struct TerminalKittyKeyboardTests {
    @Test("Kitty push, set, query, and pop mask unsupported flags")
    func negotiationRoundTrip() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 3))

        terminal.feed(Array("\u{1B}[>31u\u{1B}[?u".utf8))
        #expect(terminal.inputModes.kittyKeyboardFlags == 1)
        #expect(terminal.drainReplyBytes() == Array("\u{1B}[?1u".utf8))

        terminal.feed(Array("\u{1B}[=0;1u\u{1B}[?u".utf8))
        #expect(terminal.drainReplyBytes() == Array("\u{1B}[?0u".utf8))
        terminal.feed(Array("\u{1B}[=1;2u\u{1B}[?u".utf8))
        #expect(terminal.drainReplyBytes() == Array("\u{1B}[?1u".utf8))
        terminal.feed(Array("\u{1B}[=1;3u\u{1B}[<u\u{1B}[?u".utf8))
        #expect(terminal.drainReplyBytes() == Array("\u{1B}[?0u".utf8))

        terminal.feed(Array("\u{1B}[>1u\u{1B}[<99u\u{1B}[?u".utf8))
        #expect(terminal.drainReplyBytes() == Array("\u{1B}[?0u".utf8))
    }

    @Test("Kitty stacks evict oldest entries and stay independent per screen")
    func stackDepthAndScreens() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        for index in 0..<(Terminal.kittyKeyboardStackDepth + 1) {
            terminal.feed(Array("\u{1B}[>\(index.isMultiple(of: 2) ? 1 : 0)u".utf8))
        }
        terminal.feed(Array("\u{1B}[<\(Terminal.kittyKeyboardStackDepth - 1)u\u{1B}[?u".utf8))
        #expect(terminal.drainReplyBytes() == Array("\u{1B}[?0u".utf8))

        for screenMode in [1047, 1049] {
            var screens = try #require(Terminal(columns: 8, rows: 3))
            screens.feed(Array("\u{1B}[>1u\u{1B}[?\(screenMode)h\u{1B}[?u".utf8))
            #expect(screens.drainReplyBytes() == Array("\u{1B}[?0u".utf8))
            screens.feed(Array("\u{1B}[>1u\u{1B}[?\(screenMode)l\u{1B}[?u".utf8))
            #expect(screens.drainReplyBytes() == Array("\u{1B}[?1u".utf8))
            screens.feed(Array("\u{1B}[?\(screenMode)h\u{1B}[?u".utf8))
            #expect(screens.drainReplyBytes() == Array("\u{1B}[?1u".utf8))
        }
    }

    @Test("DECSTR and RIS clear keyboard modes and both Kitty stacks")
    func resets() throws {
        for reset in ["\u{1B}[!p", "\u{1B}c"] {
            var terminal = try #require(Terminal(columns: 8, rows: 3))
            terminal.feed(Array("\u{1B}[?1h\u{1B}[?1004h\u{1B}[?2004h\u{1B}=\u{1B}[>1u\u{1B}[?1049h\u{1B}[>1u\(reset)".utf8))

            #expect(terminal.inputModes == .default)
            // The `?1004h` above answered with a focus report of its own; this case is about
            // what the resets do to keyboard state.
            _ = terminal.drainReplyBytes()
            terminal.feed(Array("\u{1B}[?u\u{1B}[?1049h\u{1B}[?u".utf8))
            #expect(terminal.drainReplyBytes() == Array("\u{1B}[?0u\u{1B}[?0u".utf8))
        }
    }

    @Test("bare CSI-u restores cursor while modifyOtherKeys stays inert")
    func dispatchIsolation() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("\u{1B}[2;2H\u{1B}[s\u{1B}[3;4H\u{1B}[u".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 1, column: 1, isPendingWrap: false))

        let before = terminal
        terminal.feed(Array("\u{1B}[>4;2m\u{1B}[?4m".utf8))
        #expect(terminal == before)
        #expect(terminal.pendingReplyBytes.isEmpty)
    }
}
