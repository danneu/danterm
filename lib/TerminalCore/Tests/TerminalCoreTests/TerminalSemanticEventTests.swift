// Semantic event protocol, recovery, ordering, and retention-bound contracts.
import Testing
@testable import TerminalCore

@Suite("Terminal semantic events")
struct TerminalSemanticEventTests {
    @Test("OSC title and cwd events are decoded and drained in stream order")
    func titleAndCwd() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2, machineHostname: "mac"))
        terminal.feed(Array("\u{1B}]2;editor\u{7}\u{1B}]7;file://mac/tmp/a%20b\u{1B}\\".utf8))
        #expect(terminal.drainSemanticEvents() == [.title("editor"), .workingDirectory("/tmp/a b")])
        #expect(terminal.drainSemanticEvents().isEmpty)
    }

    @Test("empty title follows cwd until another explicit title arrives")
    func cwdTitleFallback() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2, machineHostname: "mac"))
        terminal.feed(Array("\u{1B}]7;file://localhost/a\u{7}\u{1B}]0;\u{7}".utf8))
        #expect(terminal.drainSemanticEvents() == [.workingDirectory("/a"), .title("/a")])
        terminal.feed(Array("\u{1B}]7;file://mac/b\u{7}".utf8))
        #expect(terminal.drainSemanticEvents() == [.workingDirectory("/b"), .title("/b")])
        terminal.feed(Array("\u{1B}]2;fixed\u{7}\u{1B}]7;\u{7}".utf8))
        #expect(terminal.drainSemanticEvents() == [.title("fixed"), .workingDirectory(nil)])
    }

    @Test("OSC 7 rejects non-local and malformed file URIs")
    func cwdPolicy() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2, machineHostname: "mac"))
        terminal.feed(Array("\u{1B}]7;file://remote/tmp\u{7}\u{1B}]7;https://mac/tmp\u{7}\u{1B}]7;file://mac/%ZZ\u{7}".utf8))
        #expect(terminal.drainSemanticEvents().isEmpty)
    }

    @Test("standalone BEL is a bell while OSC BEL only terminates the OSC")
    func bellMeaning() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        terminal.feed(Array("\u{7}\u{1B}]0;title\u{7}".utf8))
        #expect(terminal.drainSemanticEvents() == [.bell, .title("title")])
    }

    @Test("retired private title prefixes follow ordinary title behavior")
    func retiredPrivateTitleIsOrdinary() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        terminal.feed(Array("\u{1B}]0;__DANTERM_EVT__:ordinary\u{7}".utf8))
        #expect(terminal.drainSemanticEvents() == [.title("__DANTERM_EVT__:ordinary")])
    }

    @Test("valid multibyte title bytes survive chunking across C1-range continuations")
    func utf8Chunking() throws {
        let bytes = Array("\u{1B}]0;Aé\u{1B}\\Z".utf8)
        for split in 0...bytes.count {
            var terminal = try #require(Terminal(columns: 20, rows: 2))
            terminal.feed(Array(bytes[..<split]))
            terminal.feed(Array(bytes[split...]))
            #expect(terminal.drainSemanticEvents() == [.title("Aé")])
            #expect(terminal.cell(row: 0, column: 0)?.scalars == Array("Z".unicodeScalars))
        }
    }

    @Test("semantic values accept exactly 64 KiB and recover after oversized input")
    func valueLimitAndRecovery() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        let exact = String(repeating: "a", count: 65_536)
        let oversized = String(repeating: "b", count: 65_537)
        terminal.feed(Array("\u{1B}]0;\(exact)\u{7}".utf8))
        #expect(terminal.drainSemanticEvents() == [.title(exact)])
        terminal.feed(Array("\u{1B}]0;\(oversized)\u{7}\u{1B}]0;ok\u{7}".utf8))
        #expect(terminal.drainSemanticEvents() == [.title("ok")])
    }

    @Test("malformed UTF-8 semantic values recover to a later valid OSC")
    func malformedUTF8Recovery() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        terminal.feed([0x1B, 0x5D, 0x30, 0x3B, 0xC3, 0x07])
        terminal.feed(Array("\u{1B}]0;recovered\u{7}".utf8))
        #expect(terminal.drainSemanticEvents() == [.title("recovered")])
    }

    @Test("coalesced events move to their newest ordering positions")
    func coalescingOrder() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2, machineHostname: "mac"))
        terminal.feed(Array("\u{1B}]0;old\u{7}\u{7}\u{1B}]7;file://mac/a\u{7}\u{1B}]0;new\u{7}".utf8))
        #expect(terminal.drainSemanticEvents() == [.bell, .workingDirectory("/a"), .title("new")])
    }

    @Test("bells and native shell events share a 100-event FIFO bound")
    func discreteBound() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2, shellIntegrationToken: "token"))
        terminal.feed(Array(String(repeating: "\u{7}", count: 100).utf8))
        terminal.feed(Array("\u{1B}]1337;DanTermShell=1;token;command-end\u{7}".utf8))
        #expect(terminal.drainSemanticEvents() == Array(repeating: .bell, count: 100))
    }

    @Test("semantic events participate in the shared 256 KiB metadata cap")
    func sharedMetadataBound() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        let target = String(repeating: "h", count: 65_527)
        for index in 0..<4 {
            terminal.feed(Array("\u{1B}]8;id=\(index);https://\(target)\u{7}x".utf8))
        }
        terminal.feed(Array("\u{1B}]0;title\u{7}".utf8))
        #expect(terminal.retainedTerminalMetadataBytes <= 256 * 1_024)
        #expect(terminal.drainSemanticEvents().isEmpty)
    }
}
