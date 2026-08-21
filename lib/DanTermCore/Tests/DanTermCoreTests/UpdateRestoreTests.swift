// Reducer coverage for installing a validated restore as one normal message.
import Testing

@testable import DanTermCore

@Suite struct UpdateRestoreTests {
    // Intent: restore installation uses every reducer normalizer and preserves live notices.
    // Why it exists: the runtime used to replace AppModel directly and hand-replay only tab
    //   normalization, so new normalizers and queued notices were silently skipped.
    // Scenario: a staged model carries five stale ephemeral states while a live notice waits.
    @Test("restore installs through every reducer normalizer and preserves notices")
    func restoreNormalizesAndPreservesNotices() throws {
        var restored = makeModel()
        createTab(&restored)
        let staleTabId = try #require(restored.selectedTabId)
        let stalePaneId = try #require(selectedTab(in: restored)?.paneTree.focusedPaneId)
        restored.pendingConfirmation = pendingCloseConfirmation(for: .tab(staleTabId), in: restored)
        restored.sidebarRename = SidebarRenameSession(
            id: RenameSessionId(),
            target: .tab(staleTabId)
        )
        restored.todoPopover = .pane(stalePaneId)
        createTab(&restored)
        let selectedTabId = try #require(restored.selectedTabId)
        let selectedPaneId = try #require(selectedTab(in: restored)?.paneTree.focusedPaneId)
        restored.isAppActive = false
        update(&restored, .sessionBell(sessionId: sessionId(for: selectedPaneId, in: restored)))
        restored.isAppActive = true
        restored.groups[0].tabs.removeAll { $0.id == staleTabId }
        restored.mruOrder = []

        var live = makeModel()
        update(&live, .noticeReported(.message(title: "Queued", message: "Keep me")))
        let queuedNotices = live.noticeQueue

        let commands = update(&live, .restoreSession(restored))

        #expect(live.selectedTabId == selectedTabId)
        #expect(live.mruOrder.first == selectedTabId)
        #expect(live.alerts.first?.isUnread == false)
        #expect(live.todoPopover == nil)
        #expect(live.pendingConfirmation == nil)
        #expect(live.sidebarRename == nil)
        #expect(live.noticeQueue == queuedNotices)
        #expect(commands.count == 1)
        guard case .installStagedRestoreSession = commands[0] else {
            Issue.record("restore should return only the staged host-swap command")
            return
        }
    }
}
