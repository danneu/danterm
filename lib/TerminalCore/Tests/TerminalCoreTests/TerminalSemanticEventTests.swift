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

    @Test("OSC 9 and OSC 777 emit complete desktop notifications")
    func notifications() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        terminal.feed(Array("\u{1B}]9;build done\u{7}\u{1B}]777;notify;Deploy;host;ready\u{1B}\\".utf8))
        #expect(terminal.drainSemanticEvents() == [
            .desktopNotification(title: "", body: "build done"),
            .desktopNotification(title: "Deploy", body: "host;ready"),
        ])
    }

    @Test("OSC 9 reserves canonical ConEmu selectors before notification fallback")
    func notificationSelectorPrecedence() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        for selector in 1...12 {
            terminal.feed(Array("\u{1B}]9;\(selector);ignored\u{7}".utf8))
        }
        terminal.feed(Array("\u{1B}]9;13;ordinary\u{7}\u{1B}]9;123\u{7}\u{1B}]9;04;leading\u{7}".utf8))
        #expect(terminal.drainSemanticEvents() == [
            .desktopNotification(title: "", body: "13;ordinary"),
            .desktopNotification(title: "", body: "123"),
            .desktopNotification(title: "", body: "04;leading"),
        ])
    }

    @Test("OSC 9 selector 4 accepts only the canonical progress grammar")
    func progressGrammar() throws {
        let cases: [(String, TerminalSemanticEvent)] = [
            ("1;42", .progress(.set(percent: 42))),
            ("2", .progress(.error(percent: nil))),
            ("2;7", .progress(.error(percent: 7))),
            ("3", .progress(.indeterminate)),
            ("4", .progress(.pause(percent: nil))),
            ("4;99", .progress(.pause(percent: 99))),
            ("0", .progress(nil)),
        ]
        for (payload, expected) in cases {
            var terminal = try #require(Terminal(columns: 20, rows: 2))
            terminal.feed(Array("\u{1B}]9;4;\(payload)\u{7}".utf8))
            #expect(terminal.drainSemanticEvents() == [expected])
        }

        var terminal = try #require(Terminal(columns: 20, rows: 2))
        terminal.feed(Array("\u{1B}]9;4;1;101\u{7}\u{1B}]9;4;3;1\u{7}".utf8))
        #expect(terminal.drainSemanticEvents().isEmpty)
    }

    @Test("progress coalesces while notifications share the discrete event bound")
    func progressCoalescingAndNotificationBound() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        terminal.feed(Array("\u{1B}]9;4;1;1\u{7}\u{1B}]9;notice\u{7}\u{1B}]9;4;4;50\u{7}".utf8))
        #expect(terminal.drainSemanticEvents() == [
            .desktopNotification(title: "", body: "notice"),
            .progress(.pause(percent: 50)),
        ])

        for index in 0..<101 {
            terminal.feed(Array("\u{1B}]9;event-\(index)\u{7}".utf8))
        }
        #expect(terminal.drainSemanticEvents().count == 100)
    }

    @Test("notification title and body share one 64 KiB limit and recover")
    func notificationLimitAndRecovery() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        let exactBody = String(repeating: "a", count: 65_535)
        terminal.feed(Array("\u{1B}]777;notify;t;\(exactBody)\u{7}".utf8))
        #expect(terminal.drainSemanticEvents() == [.desktopNotification(title: "t", body: exactBody)])
        terminal.feed(Array("\u{1B}]777;notify;tt;\(exactBody)\u{7}\u{1B}]9;ok\u{7}".utf8))
        #expect(terminal.drainSemanticEvents() == [.desktopNotification(title: "", body: "ok")])
    }

    @Test("notifications accept every OSC terminator and remain chunk invariant")
    func notificationTerminatorsAndChunking() throws {
        let sequences = [
            Array("\u{1B}]9;bel\u{7}".utf8),
            Array("\u{1B}]9;st\u{1B}\\".utf8),
            [0x1B, 0x5D] + Array("9;c1".utf8) + [0x9C],
        ]
        let expected: [TerminalSemanticEvent] = [
            .desktopNotification(title: "", body: "bel"),
            .desktopNotification(title: "", body: "st"),
            .desktopNotification(title: "", body: "c1"),
        ]
        let bytes = sequences.flatMap { $0 }
        for split in 0...bytes.count {
            var terminal = try #require(Terminal(columns: 20, rows: 2))
            terminal.feed(Array(bytes[..<split]))
            terminal.feed(Array(bytes[split...]))
            #expect(terminal.drainSemanticEvents() == expected, "split at \(split)")
        }
    }

    @Test("malformed UTF-8 notifications are ignored before a later valid notification")
    func malformedNotificationUTF8Recovery() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        terminal.feed([0x1B, 0x5D, 0x39, 0x3B, 0xC3, 0x07])
        terminal.feed(Array("\u{1B}]9;recovered\u{7}".utf8))
        #expect(terminal.drainSemanticEvents() == [
            .desktopNotification(title: "", body: "recovered"),
        ])
    }
}
