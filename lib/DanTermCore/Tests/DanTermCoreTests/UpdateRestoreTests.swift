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
        restored.pendingConfirmation = pendingCloseConfirmation(
            for: closeTabTarget(staleTabId, in: restored),
            in: restored
        )
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

    // Intent: restore keeps the live application-activation flag instead of the
    //   staged model's.
    // Why it exists: `isAppActive` is ephemeral and never snapshotted, so a model
    //   decoded from a checkpoint always claims the default "active". A restore that
    //   installed that value would tell every pane its terminal is focused right
    //   after a background launch, which is the state mode-1004 clients read.
    // Scenario: DanTerm launches without activating, then restores a checkpoint.
    //   Spec-first -- no incident to cite, and none should be invented.
    @Test("restore preserves the live application-activation flag")
    func restorePreservesApplicationActivation() {
        var restored = makeModel()
        createTab(&restored)
        restored.isAppActive = true

        var live = makeModel()
        live.isAppActive = false

        _ = update(&live, .restoreSession(restored))

        #expect(live.isAppActive == false, "restore installed the staged activation flag")
    }
}
