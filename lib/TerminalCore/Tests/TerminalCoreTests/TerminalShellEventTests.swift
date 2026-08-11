// DanTerm-private tokenless OSC coverage, including strict framing and recovery.
import Foundation
import Testing
@testable import TerminalCore

@Suite("Terminal shell events")
struct TerminalShellEventTests {
    @Test("v3 connection declarations replace every v2 connection event")
    func connectionDeclarationVersionBoundary() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))

        terminal.feed(Array("\u{1B}]1337;DanTermShell=3;connection;local\u{7}".utf8))
        terminal.feed(Array("\u{1B}]1337;DanTermShell=2;remote-start\u{7}".utf8))
        terminal.feed(Array("\u{1B}]1337;DanTermShell=2;remote-host;ZGFu;Y2FqYQ==\u{7}".utf8))
        terminal.feed(Array("\u{1B}]1337;DanTermShell=2;connection-end\u{7}".utf8))

        #expect(terminal.drainSemanticEvents().count == 1)
    }

    @Test("all native shell events decode without changing the title")
    func typedEventsAndTitleIsolation() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        let command = Data("printf 'hola'".utf8).base64EncodedString()
        let user = Data("dan".utf8).base64EncodedString()
        let host = Data("caja".utf8).base64EncodedString()
        terminal.feed(Array((
            "\u{1B}]2;editor\u{7}"
                + "\u{1B}]1337;DanTermShell=3;integration-ready\u{1B}\\"
                + "\u{1B}]1337;DanTermShell=3;command-start;\(command)\u{1B}\\"
                + "\u{1B}]1337;DanTermShell=3;command-end;17\u{7}"
                + "\u{1B}]1337;DanTermShell=3;connection;remote\u{7}"
                + "\u{1B}]1337;DanTermShell=3;connection;remote;\(user);\(host)\u{1B}\\"
                + "\u{1B}]1337;DanTermShell=3;connection;local\u{1B}\\"
        ).utf8))

        #expect(terminal.drainSemanticEvents() == [
            .title("editor"),
            .integrationReady,
            .commandStarted("printf 'hola'"),
            .commandEnded(exitStatus: 17),
            .connectionDeclared(.remote(identity: nil)),
            .connectionDeclared(.remote(identity: TerminalRemoteIdentity(user: "dan", host: "caja"))),
            .connectionDeclared(.local),
        ])
    }

    @Test("command-start rejects NUL before persistence")
    func rejectsNULCommand() throws {
        let command = Data("printf before\0after".utf8).base64EncodedString()
        var terminal = try #require(Terminal(columns: 20, rows: 2))

        terminal.feed(Array("\u{1B}]1337;DanTermShell=3;command-start;\(command)\u{1B}\\".utf8))

        #expect(terminal.drainSemanticEvents().isEmpty)
    }

    @Test("wrong protocol identities and malformed payloads recover to later valid input")
    func framingAndRecovery() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        let valid = Data("echo ok".utf8).base64EncodedString()
        terminal.feed(Array((
            "\u{1B}]1337;Wrong=2;command-end;0\u{7}"
                + "\u{1B}]1337;DanTermShell=1;command-end;0\u{7}"
                + "\u{1B}]1337;DanTermShell=2;connection;local\u{7}"
                + "\u{1B}]1337;DanTermShell=3;command-start;abcd===\u{7}"
                + "\u{1B}]1337;DanTermShell=3;command-start;\(valid)\u{7}"
        ).utf8))

        #expect(terminal.drainSemanticEvents() == [.commandStarted("echo ok")])
    }

    @Test("a native event survives every two- and three-chunk byte split")
    func everyByteSplit() throws {
        let encoded = Data("echo español".utf8).base64EncodedString()
        let bytes = Array(
            "\u{1B}]1337;DanTermShell=3;command-start;\(encoded)\u{1B}\\".utf8
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
        terminal.feed(shellEvent("connection", fields: ["remote", encode(exactUser), encode(exactHost)]))
        terminal.feed(shellEvent("connection", fields: ["remote", encode(exactUser), encode(oversizedHost)]))

        #expect(terminal.drainSemanticEvents() == [
            .commandStarted(exactCommand),
            .connectionDeclared(.remote(identity: TerminalRemoteIdentity(
                user: exactUser,
                host: exactHost
            ))),
        ])
    }

    @Test("encoded OSC content accepts the 88 KiB boundary and recovers after overflow")
    func encodedLimitAndRecovery() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        let prefix = "1337;DanTermShell=3;unknown;"
        let exactPayload = prefix + String(
            repeating: "x",
            count: Terminal.maximumShellOSCBytes - prefix.utf8.count
        )
        let oversizedPayload = exactPayload + "x"

        terminal.feed(Array("\u{1B}]\(exactPayload)\u{7}".utf8))
        terminal.feed(Array("\u{1B}]\(oversizedPayload)\u{7}".utf8))
        terminal.feed(shellEvent("command-end", fields: ["0"]))

        #expect(terminal.drainSemanticEvents() == [.commandEnded(exitStatus: 0)])
    }

    @Test("every malformed envelope class is inert and later input recovers")
    func malformedEnvelopeClasses() throws {
        let invalidUTF8 = Data([0xFF]).base64EncodedString()
        let empty = Data().base64EncodedString()
        let malformedEvents = [
            "\u{1B}]1337;DanTermShell=3\u{7}",
            "\u{1B}]1337;DanTermShell=3;unknown\u{7}",
            "\u{1B}]1337;DanTermShell=3;integration-ready;extra\u{7}",
            "\u{1B}]1337;DanTermShell=3;command-start\u{7}",
            "\u{1B}]1337;DanTermShell=3;command-start;\(empty);extra\u{7}",
            "\u{1B}]1337;DanTermShell=3;command-end\u{7}",
            "\u{1B}]1337;DanTermShell=3;command-end;00\u{7}",
            "\u{1B}]1337;DanTermShell=3;command-end;256\u{7}",
            "\u{1B}]1337;DanTermShell=3;command-end;-1\u{7}",
            "\u{1B}]1337;DanTermShell=3;connection\u{7}",
            "\u{1B}]1337;DanTermShell=3;connection;unknown\u{7}",
            "\u{1B}]1337;DanTermShell=3;connection;local;extra\u{7}",
            "\u{1B}]1337;DanTermShell=3;connection;remote;ZGFu\u{7}",
            "\u{1B}]1337;DanTermShell=3;connection;remote;ZGFu;Y2FqYQ==;extra\u{7}",
            "\u{1B}]1337;DanTermShell=3;connection;remote;ZGE;Y2FqYQ==\u{7}",
            "\u{1B}]1337;DanTermShell=3;command-start;\(invalidUTF8)\u{7}",
            "\u{1B}]1337;DanTermShell=3;command-start;\(empty)\u{7}",
            "\u{1B}]1337;DanTermShell=3;command-start;ZGE\u{7}",
            "\u{1B}]1337;DanTermShell=3;command-start; ZGFu\u{7}",
        ]
        var terminal = try #require(Terminal(columns: 20, rows: 2))

        for event in malformedEvents { terminal.feed(Array(event.utf8)) }
        terminal.feed(shellEvent("command-end", fields: ["255"]))

        #expect(terminal.drainSemanticEvents() == [.commandEnded(exitStatus: 255)])
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
        terminal.feed(shellEvent("command-end", fields: ["9"]))
        terminal.feed(Array("\u{1B}]7;file://mac/two\u{7}".utf8))

        #expect(terminal.drainSemanticEvents() == [
            .commandEnded(exitStatus: 9),
            .workingDirectory("/two"),
            .title("/two"),
        ])
    }
}

private func shellEvent(_ event: String, fields: [String] = []) -> [UInt8] {
    let suffix = fields.isEmpty ? "" : ";" + fields.joined(separator: ";")
    return Array("\u{1B}]1337;DanTermShell=3;\(event)\(suffix)\u{1B}\\".utf8)
}

private func encode(_ value: String) -> String {
    Data(value.utf8).base64EncodedString()
}
