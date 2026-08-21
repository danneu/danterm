// Verifies that the terminal retains host focus and owns every DEC mode 1004 report.
import Testing

@testable import TerminalCore

/// Pins the one contract that keeps a child's idea of focus true: the terminal retains the
/// host's effective focus whether or not reporting is on, and answers each enable with the
/// state it holds right then.
struct TerminalFocusReportingTests {
    @Test("enabling reporting in a never-focused terminal reports unfocused")
    func enableReportsInitialUnfocusedState() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        #expect(terminal.isFocused == false)

        terminal.feed(Array("\u{1B}[?1004h".utf8))

        #expect(terminal.drainReplyBytes() == Array("\u{1B}[O".utf8))
    }

    // Intent: focus that arrives before the child enables reporting is retained, not dropped.
    // Why it exists: a pane created in a background tab receives its focus input long before
    //   the application starts, so a terminal that only encodes transitions leaves that
    //   application believing it is focused forever.
    // Scenario: the host sets focus while reporting is off, then the child enables mode 1004.
    @Test("focus set while reporting is disabled writes no bytes but survives to the next enable")
    func disabledModeRetainsFocus() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 3))

        #expect(terminal.setFocused(true).isEmpty)
        #expect(terminal.isFocused)
        #expect(terminal.drainReplyBytes().isEmpty)

        terminal.feed(Array("\u{1B}[?1004h".utf8))
        #expect(terminal.drainReplyBytes() == Array("\u{1B}[I".utf8))
    }

    @Test("focus changes while reporting is enabled report once per real transition")
    func enabledModeReportsOnlyTransitions() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("\u{1B}[?1004h".utf8))
        _ = terminal.drainReplyBytes()

        #expect(terminal.setFocused(true) == Array("\u{1B}[I".utf8))
        #expect(terminal.setFocused(true).isEmpty)
        #expect(terminal.setFocused(false) == Array("\u{1B}[O".utf8))
        #expect(terminal.setFocused(false).isEmpty)
        // A change reaches the child as its own transmission, never through the reply queue.
        #expect(terminal.drainReplyBytes().isEmpty)
    }

    @Test("every enable request answers with the state held at that moment")
    func repeatedEnableReportsCurrentState() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("\u{1B}[?1004h".utf8))
        #expect(terminal.drainReplyBytes() == Array("\u{1B}[O".utf8))

        _ = terminal.setFocused(true)
        terminal.feed(Array("\u{1B}[?1004h".utf8))
        #expect(terminal.drainReplyBytes() == Array("\u{1B}[I".utf8))
    }

    @Test("disabling reporting answers nothing and keeps retained focus")
    func disableIsSilentAndKeepsFocus() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("\u{1B}[?1004h".utf8))
        _ = terminal.setFocused(true)
        _ = terminal.drainReplyBytes()

        terminal.feed(Array("\u{1B}[?1004l".utf8))
        #expect(terminal.drainReplyBytes().isEmpty)
        #expect(terminal.setFocused(false).isEmpty)

        terminal.feed(Array("\u{1B}[?1004h".utf8))
        #expect(terminal.drainReplyBytes() == Array("\u{1B}[O".utf8))
    }

    @Test("a terminal reset clears the mode without discarding retained focus")
    func resetKeepsRetainedFocus() throws {
        for reset in ["\u{1B}c", "\u{1B}[!p"] {
            var terminal = try #require(Terminal(columns: 8, rows: 3))
            terminal.feed(Array("\u{1B}[?1004h".utf8))
            _ = terminal.setFocused(true)
            _ = terminal.drainReplyBytes()

            terminal.feed(Array(reset.utf8))
            #expect(terminal.isFocused)
            #expect(terminal.drainReplyBytes().isEmpty)

            terminal.feed(Array("\u{1B}[?1004h".utf8))
            #expect(terminal.drainReplyBytes() == Array("\u{1B}[I".utf8))
        }
    }

    @Test("switching screens changes neither retained focus nor the reported state")
    func screenSwitchKeepsRetainedFocus() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("\u{1B}[?1004h".utf8))
        _ = terminal.setFocused(true)
        _ = terminal.drainReplyBytes()

        terminal.feed(Array("\u{1B}[?1049h".utf8))
        #expect(terminal.isFocused)
        #expect(terminal.setFocused(false) == Array("\u{1B}[O".utf8))

        terminal.feed(Array("\u{1B}[?1049l".utf8))
        #expect(terminal.isFocused == false)
        terminal.feed(Array("\u{1B}[?1004h".utf8))
        #expect(terminal.drainReplyBytes() == Array("\u{1B}[O".utf8))
    }

    // Intent: the enable report depends on retained state alone, not on how the enabling
    //   bytes were delivered.
    // Why it exists: a PTY read boundary can split any sequence, and a report driven from a
    //   parser side effect would be sensitive to the split.
    @Test("the enable report is invariant to input chunking")
    func enableReportIsChunkInvariant() throws {
        let bytes = Array("\u{1B}[?1004h".utf8)

        var oneChunk = try #require(Terminal(columns: 8, rows: 3))
        _ = oneChunk.setFocused(true)
        oneChunk.feed(bytes)

        var bytewise = try #require(Terminal(columns: 8, rows: 3))
        _ = bytewise.setFocused(true)
        for byte in bytes { bytewise.feed([byte]) }

        #expect(oneChunk == bytewise)
        #expect(oneChunk.drainReplyBytes() == Array("\u{1B}[I".utf8))
        #expect(bytewise.drainReplyBytes() == Array("\u{1B}[I".utf8))
    }
}
