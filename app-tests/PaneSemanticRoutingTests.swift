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
}
