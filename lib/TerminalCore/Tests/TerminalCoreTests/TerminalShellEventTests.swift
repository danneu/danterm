// DanTerm-private tokenless OSC coverage, including strict framing and recovery.
import Foundation
import Testing
@testable import TerminalCore

@Suite("Terminal shell events")
struct TerminalShellEventTests {
    @Test("all native shell events decode without changing the title")
    func typedEventsAndTitleIsolation() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        let command = Data("printf 'hola'".utf8).base64EncodedString()
        let user = Data("dan".utf8).base64EncodedString()
        let host = Data("caja".utf8).base64EncodedString()
        terminal.feed(Array((
            "\u{1B}]2;editor\u{7}"
                + "\u{1B}]1337;DanTermShell=1;command-start;\(command)\u{1B}\\"
                + "\u{1B}]1337;DanTermShell=1;command-end\u{7}"
                + "\u{1B}]1337;DanTermShell=1;remote-start\u{7}"
                + "\u{1B}]1337;DanTermShell=1;remote-host;\(user);\(host)\u{1B}\\"
        ).utf8))

        #expect(terminal.drainSemanticEvents() == [
            .title("editor"),
            .commandStarted("printf 'hola'"),
            .commandEnded,
            .remoteStarted,
            .remoteHost(user: "dan", host: "caja"),
        ])
    }

    @Test("command-start rejects NUL before persistence")
    func rejectsNULCommand() throws {
        let command = Data("printf before\0after".utf8).base64EncodedString()
        var terminal = try #require(Terminal(columns: 20, rows: 2))

        terminal.feed(Array("\u{1B}]1337;DanTermShell=1;command-start;\(command)\u{1B}\\".utf8))

        #expect(terminal.drainSemanticEvents().isEmpty)
    }

    @Test("wrong protocol identities and malformed payloads recover to later valid input")
    func framingAndRecovery() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        let valid = Data("echo ok".utf8).base64EncodedString()
        terminal.feed(Array((
            "\u{1B}]1337;Wrong=1;command-end\u{7}"
                + "\u{1B}]1337;DanTermShell=2;command-end\u{7}"
                + "\u{1B}]1337;DanTermShell=1;command-start;abcd===\u{7}"
                + "\u{1B}]1337;DanTermShell=1;command-start;\(valid)\u{7}"
        ).utf8))

        #expect(terminal.drainSemanticEvents() == [.commandStarted("echo ok")])
    }

    @Test("a native event survives every two-chunk byte split")
    func everyByteSplit() throws {
        let encoded = Data("echo español".utf8).base64EncodedString()
        let bytes = Array(
            "\u{1B}]1337;DanTermShell=1;command-start;\(encoded)\u{1B}\\".utf8
        )

        for split in 0...bytes.count {
            var terminal = try #require(Terminal(
                columns: 20,
                rows: 2
            ))
            terminal.feed(Array(bytes[..<split]))
            terminal.feed(Array(bytes[split...]))
            #expect(terminal.drainSemanticEvents() == [.commandStarted("echo español")])
        }

        for first in 0...bytes.count {
            for second in first...bytes.count {
                var terminal = try #require(Terminal(
                    columns: 20,
                    rows: 2
                ))
                terminal.feed(Array(bytes[..<first]))
                terminal.feed(Array(bytes[first..<second]))
                terminal.feed(Array(bytes[second...]))
                #expect(terminal.drainSemanticEvents() == [.commandStarted("echo español")])
            }
        }
    }

    @Test("decoded payload limits are exact for command and combined remote identity")
    func decodedLimits() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        let exactCommand = String(repeating: "c", count: 65_536)
        let oversizedCommand = exactCommand + "c"
        let exactUser = String(repeating: "u", count: 32_768)
        let exactHost = String(repeating: "h", count: 32_768)
        let oversizedHost = exactHost + "h"

        terminal.feed(shellEvent("command-start", fields: [encode(exactCommand)]))
        terminal.feed(shellEvent("command-start", fields: [encode(oversizedCommand)]))
        terminal.feed(shellEvent("remote-host", fields: [encode(exactUser), encode(exactHost)]))
        terminal.feed(shellEvent("remote-host", fields: [encode(exactUser), encode(oversizedHost)]))

        #expect(terminal.drainSemanticEvents() == [
            .commandStarted(exactCommand),
            .remoteHost(user: exactUser, host: exactHost),
        ])
    }

    @Test("encoded OSC content accepts the 88 KiB boundary and recovers after overflow")
    func encodedLimitAndRecovery() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        let prefix = "1337;DanTermShell=1;unknown;"
        let exactPayload = prefix + String(
            repeating: "x",
            count: Terminal.maximumShellOSCBytes - prefix.utf8.count
        )
        let oversizedPayload = exactPayload + "x"

        terminal.feed(Array("\u{1B}]\(exactPayload)\u{7}".utf8))
        terminal.feed(Array("\u{1B}]\(oversizedPayload)\u{7}".utf8))
        terminal.feed(shellEvent("command-end"))

        #expect(terminal.drainSemanticEvents() == [.commandEnded])
    }

    @Test("every malformed envelope class is inert and later input recovers")
    func malformedEnvelopeClasses() throws {
        let invalidUTF8 = Data([0xFF]).base64EncodedString()
        let empty = Data().base64EncodedString()
        let malformedEvents = [
            "\u{1B}]1337;DanTermShell=1\u{7}",
            "\u{1B}]1337;DanTermShell=1;unknown\u{7}",
            "\u{1B}]1337;DanTermShell=1;command-start\u{7}",
            "\u{1B}]1337;DanTermShell=1;command-start;\(empty);extra\u{7}",
            "\u{1B}]1337;DanTermShell=1;command-end;extra\u{7}",
            "\u{1B}]1337;DanTermShell=1;remote-start;extra\u{7}",
            "\u{1B}]1337;DanTermShell=1;remote-host;ZGFu\u{7}",
            "\u{1B}]1337;DanTermShell=1;remote-host;ZGFu;Y2FqYQ==;extra\u{7}",
            "\u{1B}]1337;DanTermShell=1;command-start;\(invalidUTF8)\u{7}",
            "\u{1B}]1337;DanTermShell=1;command-start;\(empty)\u{7}",
            "\u{1B}]1337;DanTermShell=1;command-start;ZGE\u{7}",
            "\u{1B}]1337;DanTermShell=1;command-start; ZGFu\u{7}",
        ]
        var terminal = try #require(Terminal(columns: 20, rows: 2))

        for event in malformedEvents { terminal.feed(Array(event.utf8)) }
        terminal.feed(shellEvent("command-end"))

        #expect(terminal.drainSemanticEvents() == [.commandEnded])
    }

    @Test("native events do not change ordinary title fallback state")
    func titleFallbackIsolation() throws {
        var terminal = try #require(Terminal(
            columns: 20,
            rows: 2,
            machineHostname: "mac"
        ))
        terminal.feed(Array("\u{1B}]7;file://mac/one\u{7}\u{1B}]0;\u{7}".utf8))
        _ = terminal.drainSemanticEvents()
        terminal.feed(shellEvent("command-end"))
        terminal.feed(Array("\u{1B}]7;file://mac/two\u{7}".utf8))

        #expect(terminal.drainSemanticEvents() == [
            .commandEnded,
            .workingDirectory("/two"),
            .title("/two"),
        ])
    }
}

private func shellEvent(_ event: String, fields: [String] = []) -> [UInt8] {
    let suffix = fields.isEmpty ? "" : ";" + fields.joined(separator: ";")
    return Array("\u{1B}]1337;DanTermShell=1;\(event)\(suffix)\u{1B}\\".utf8)
}

private func encode(_ value: String) -> String {
    Data(value.utf8).base64EncodedString()
}
