// Authenticated DanTerm-private OSC coverage, including isolation and recovery.
import Foundation
import Testing
@testable import TerminalCore

@Suite("Terminal shell events")
struct TerminalShellEventTests {
    @Test("all native shell events decode without changing the title")
    func typedEventsAndTitleIsolation() throws {
        let token = "12345678-1234-1234-1234-123456789abc"
        var terminal = try #require(Terminal(columns: 20, rows: 2, shellIntegrationToken: token))
        let command = Data("printf 'hola'".utf8).base64EncodedString()
        let user = Data("dan".utf8).base64EncodedString()
        let host = Data("caja".utf8).base64EncodedString()
        terminal.feed(Array((
            "\u{1B}]2;editor\u{7}"
                + "\u{1B}]1337;DanTermShell=1;\(token);command-start;\(command)\u{1B}\\"
                + "\u{1B}]1337;DanTermShell=1;\(token);command-end\u{7}"
                + "\u{1B}]1337;DanTermShell=1;\(token);remote-start\u{7}"
                + "\u{1B}]1337;DanTermShell=1;\(token);remote-host;\(user);\(host)\u{1B}\\"
        ).utf8))

        #expect(terminal.drainSemanticEvents() == [
            .title("editor"),
            .commandStarted("printf 'hola'"),
            .commandEnded,
            .remoteStarted,
            .remoteHost(user: "dan", host: "caja"),
        ])
    }

    @Test("wrong tokens and malformed payloads recover to later valid input")
    func authenticationAndRecovery() throws {
        let token = "right"
        var terminal = try #require(Terminal(columns: 20, rows: 2, shellIntegrationToken: token))
        let valid = Data("echo ok".utf8).base64EncodedString()
        terminal.feed(Array((
            "\u{1B}]1337;DanTermShell=1;wrong;command-end\u{7}"
                + "\u{1B}]1337;DanTermShell=2;\(token);command-end\u{7}"
                + "\u{1B}]1337;DanTermShell=1;\(token);command-start;abcd===\u{7}"
                + "\u{1B}]1337;DanTermShell=1;\(token);command-start;\(valid)\u{7}"
        ).utf8))

        #expect(terminal.drainSemanticEvents() == [.commandStarted("echo ok")])
    }

    @Test("a native event survives every two-chunk byte split")
    func everyByteSplit() throws {
        let token = "token"
        let encoded = Data("echo español".utf8).base64EncodedString()
        let bytes = Array(
            "\u{1B}]1337;DanTermShell=1;\(token);command-start;\(encoded)\u{1B}\\".utf8
        )

        for split in 0...bytes.count {
            var terminal = try #require(Terminal(
                columns: 20,
                rows: 2,
                shellIntegrationToken: token
            ))
            terminal.feed(Array(bytes[..<split]))
            terminal.feed(Array(bytes[split...]))
            #expect(terminal.drainSemanticEvents() == [.commandStarted("echo español")])
        }

        for first in 0...bytes.count {
            for second in first...bytes.count {
                var terminal = try #require(Terminal(
                    columns: 20,
                    rows: 2,
                    shellIntegrationToken: token
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
        let token = "token"
        var terminal = try #require(Terminal(columns: 20, rows: 2, shellIntegrationToken: token))
        let exactCommand = String(repeating: "c", count: 65_536)
        let oversizedCommand = exactCommand + "c"
        let exactUser = String(repeating: "u", count: 32_768)
        let exactHost = String(repeating: "h", count: 32_768)
        let oversizedHost = exactHost + "h"

        terminal.feed(shellEvent(token, "command-start", fields: [encode(exactCommand)]))
        terminal.feed(shellEvent(token, "command-start", fields: [encode(oversizedCommand)]))
        terminal.feed(shellEvent(token, "remote-host", fields: [encode(exactUser), encode(exactHost)]))
        terminal.feed(shellEvent(token, "remote-host", fields: [encode(exactUser), encode(oversizedHost)]))

        #expect(terminal.drainSemanticEvents() == [
            .commandStarted(exactCommand),
            .remoteHost(user: exactUser, host: exactHost),
        ])
    }

    @Test("one pane cannot authenticate another pane's event")
    func paneTokenIsolation() throws {
        var first = try #require(Terminal(columns: 20, rows: 2, shellIntegrationToken: "first"))
        var second = try #require(Terminal(columns: 20, rows: 2, shellIntegrationToken: "second"))
        let event = shellEvent("first", "command-end")

        first.feed(event)
        second.feed(event)

        #expect(first.drainSemanticEvents() == [.commandEnded])
        #expect(second.drainSemanticEvents().isEmpty)
    }

    @Test("encoded OSC content accepts the 88 KiB boundary and recovers after overflow")
    func encodedLimitAndRecovery() throws {
        let token = "token"
        var terminal = try #require(Terminal(columns: 20, rows: 2, shellIntegrationToken: token))
        let prefix = "1337;DanTermShell=1;\(token);unknown;"
        let exactPayload = prefix + String(
            repeating: "x",
            count: Terminal.maximumShellOSCBytes - prefix.utf8.count
        )
        let oversizedPayload = exactPayload + "x"

        terminal.feed(Array("\u{1B}]\(exactPayload)\u{7}".utf8))
        terminal.feed(Array("\u{1B}]\(oversizedPayload)\u{7}".utf8))
        terminal.feed(shellEvent(token, "command-end"))

        #expect(terminal.drainSemanticEvents() == [.commandEnded])
    }

    @Test("every malformed envelope class is inert and later input recovers")
    func malformedEnvelopeClasses() throws {
        let token = "token"
        let invalidUTF8 = Data([0xFF]).base64EncodedString()
        let empty = Data().base64EncodedString()
        let malformedEvents = [
            "\u{1B}]1337;DanTermShell=1;;command-end\u{7}",
            "\u{1B}]1337;DanTermShell=1;\(token);unknown\u{7}",
            "\u{1B}]1337;DanTermShell=1;\(token);command-end;extra\u{7}",
            "\u{1B}]1337;DanTermShell=1;\(token);remote-host;ZGFu\u{7}",
            "\u{1B}]1337;DanTermShell=1;\(token);command-start;\(invalidUTF8)\u{7}",
            "\u{1B}]1337;DanTermShell=1;\(token);command-start;\(empty)\u{7}",
            "\u{1B}]1337;DanTermShell=1;\(token);command-start;ZGE\u{7}",
            "\u{1B}]1337;DanTermShell=1;\(token);command-start; ZGFu\u{7}",
        ]
        var terminal = try #require(Terminal(columns: 20, rows: 2, shellIntegrationToken: token))

        for event in malformedEvents { terminal.feed(Array(event.utf8)) }
        terminal.feed(shellEvent(token, "command-end"))

        #expect(terminal.drainSemanticEvents() == [.commandEnded])
    }

    @Test("native events do not change ordinary title fallback state")
    func titleFallbackIsolation() throws {
        let token = "token"
        var terminal = try #require(Terminal(
            columns: 20,
            rows: 2,
            machineHostname: "mac",
            shellIntegrationToken: token
        ))
        terminal.feed(Array("\u{1B}]7;file://mac/one\u{7}\u{1B}]0;\u{7}".utf8))
        _ = terminal.drainSemanticEvents()
        terminal.feed(shellEvent(token, "command-end"))
        terminal.feed(Array("\u{1B}]7;file://mac/two\u{7}".utf8))

        #expect(terminal.drainSemanticEvents() == [
            .commandEnded,
            .workingDirectory("/two"),
            .title("/two"),
        ])
    }
}

private func shellEvent(_ token: String, _ event: String, fields: [String] = []) -> [UInt8] {
    let suffix = fields.isEmpty ? "" : ";" + fields.joined(separator: ";")
    return Array("\u{1B}]1337;DanTermShell=1;\(token);\(event)\(suffix)\u{1B}\\".utf8)
}

private func encode(_ value: String) -> String {
    Data(value.utf8).base64EncodedString()
}
