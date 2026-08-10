// Pins the value-only adapter from engine semantic events into the pane-owned
// live stream without constructing AppKit views or a PTY.
import Testing
import TerminalCore

@testable import DanTerm

struct PaneSemanticRoutingTests {
    @Test("terminal semantic events lower only declared live pane inputs")
    func terminalEventsLowerToPaneInputs() {
        let remote = RemoteSession(user: "dan", host: "caja")
        let cases: [(TerminalSemanticEvent, PaneSemanticEvent?)] = [
            (.integrationReady, .integrationReady),
            (.commandStarted("echo ok"), .commandStarted("echo ok")),
            (.commandEnded(exitStatus: 7), .commandEnded(exitStatus: 7)),
            (.remoteStarted, .remoteDetected),
            (.remoteHost(user: "dan", host: "caja"), .remoteIdentityReported(remote)),
            (.connectionEnded, .connectionEnded),
            (.title("vim"), nil),
            (.workingDirectory("/tmp"), nil),
            (.bell, nil),
            (.desktopNotification(title: "Build", body: "Done"), nil),
            (.progress(.indeterminate), nil),
        ]

        for (event, expected) in cases {
            #expect(paneSemanticEvent(for: event) == expected)
        }
    }

    @Test("semantic admission bounds command and combined remote identity bytes")
    func semanticAdmissionBoundsCommandAndRemoteIdentity() {
        let limit = TerminalMetadataBounds.maximumValueBytes
        let atLimit = String(repeating: "a", count: limit)
        let overLimit = atLimit + "b"
        let half = String(repeating: "u", count: limit / 2)
        let otherHalf = String(repeating: "h", count: limit - half.utf8.count)

        #expect(paneSemanticEvent(for: .commandStarted(atLimit)) == .commandStarted(atLimit))
        #expect(paneSemanticEvent(for: .commandStarted(overLimit)) == nil)
        #expect(paneSemanticEvent(for: .remoteHost(user: half, host: otherHalf)) ==
            .remoteIdentityReported(RemoteSession(user: half, host: otherHalf)))
        #expect(paneSemanticEvent(for: .remoteHost(user: half + "x", host: otherHalf)) == nil)
    }
}
