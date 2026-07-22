// Cross-layer retention proof for terminal semantic metadata. This test-only
// integration imports DanTermCore without adding a product dependency from the
// terminal engine to the app model.
import Foundation
import Testing

@testable import DanTermCore
@testable import TerminalCore

struct TerminalMetadataIntegrationTests {
    @Test("core, handoff, and model shares total exactly 1 MiB and recover")
    func combinedMetadataAllowanceAndRecovery() throws {
        // Intent: hold a full handoff while TerminalCore refills and the model
        //   reaches its full share, then prove later valid input still applies.
        // Why it exists: pins the end-to-end allowance with all three layers
        //   live at once rather than relying only on isolated cap tests.
        // Scenario: a consumer stalls after draining one batch while child
        //   output refills the core and existing pane history fills the model.
        let token = "token"
        var terminal = try #require(Terminal(
            columns: 2,
            rows: 1,
            shellIntegrationToken: token
        ))
        let value = String(repeating: "x", count: 64 * 1024)
        let encoded = Data(value.utf8).base64EncodedString()
        let sequence = Array(
            "\u{1B}]1337;DanTermShell=1;\(token);command-start;\(encoded)\u{07}".utf8
        )

        for _ in 0..<4 { terminal.feed(sequence) }
        let heldHandoff = terminal.drainSemanticEvents()
        for _ in 0..<4 { terminal.feed(sequence) }

        var model = AppModel(groups: [GroupModel(id: GroupId(rawValue: UUID()), name: "General")])
        update(&model, .createTab(inGroupId: nil))
        model.isAppActive = false
        let paneId = try #require(model.groups.first?.tabs.first?.focusedPaneId)
        let field = String(repeating: "m", count: 64 * 1024)
        update(&model, .surfaceTitle(paneId: paneId, title: field))
        update(&model, .surfaceCwd(paneId: paneId, cwd: field))
        update(&model, .commandStarted(paneId: paneId, command: field))
        update(&model, .remoteSessionReported(
            paneId: paneId,
            session: RemoteSession(user: field, host: field)
        ))
        update(&model, .desktopNotification(paneId: paneId, title: field, body: field))
        update(&model, .desktopNotification(paneId: paneId, title: field, body: ""))

        #expect(semanticStringBytes(heldHandoff) == 256 * 1024)
        #expect(terminal.retainedTerminalMetadataBytes == 256 * 1024)
        #expect(terminalMetadataBytes(for: paneId, in: model) == 512 * 1024)
        #expect(
            semanticStringBytes(heldHandoff)
                + terminal.retainedTerminalMetadataBytes
                + terminalMetadataBytes(for: paneId, in: model)
                == 1024 * 1024
        )

        _ = terminal.drainSemanticEvents()
        terminal.feed(Array("\u{1B}]2;recovered\u{07}".utf8))
        #expect(terminal.drainSemanticEvents() == [.title("recovered")])
    }
}

private func semanticStringBytes(_ events: [TerminalSemanticEvent]) -> Int {
    events.reduce(0) { total, event in
        switch event {
        case .title(let value), .commandStarted(let value):
            return total + value.utf8.count
        case let .remoteHost(user, host):
            return total + user.utf8.count + host.utf8.count
        case .workingDirectory(let value):
            return total + (value?.utf8.count ?? 0)
        case .bell, .commandEnded, .remoteStarted:
            return total
        }
    }
}
