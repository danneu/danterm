// Reducer coverage for installing a validated restore as one normal message.
import Foundation
import Testing
import DanTermProtocol

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
        clearFocusHistory(&restored)

        var live = makeModel()
        update(&live, .noticeReported(.message(title: "Queued", message: "Keep me")))
        let queuedNotices = live.noticeQueue

        let commands = update(&live, .restoreSession(restored))

        #expect(live.selectedTabId == selectedTabId)
        #expect(switcherOrder(of: live).first == selectedTabId)
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

    // Intent: restore keeps the live tailnet listener status instead of the
    //   staged model's default.
    // Why it exists: `tailnetStatus` is authored by the IPC server, never
    //   snapshotted, and republished only on transitions -- so a restore that
    //   installed the staged default would report no listener for the rest of
    //   the process. Incident: after File > Import State, `danterm tailnet
    //   status` and the preferences Listener row reported no listener at a
    //   listening instance.
    @Test("restore preserves the live tailnet listener status")
    func restorePreservesTailnetStatus() {
        var restored = makeModel()
        createTab(&restored)

        var live = makeModel()
        let endpoint = DanTermTailnetEndpoint(
            base: "100.99.4.1:24863",
            offset: 0,
            address: "100.99.4.1",
            port: 24863
        )
        _ = update(&live, .tailnetStatusChanged(.listening(endpoint: endpoint)))

        _ = update(&live, .restoreSession(restored))

        #expect(
            live.tailnetStatus == .listening(endpoint: endpoint),
            "restore installed the staged tailnet status"
        )
    }

    // Intent: a restore answers every pending IPC request in the live model --
    //   including one attached to no live pane -- with exactly one error per
    //   request, then clears both maps.
    // Why it exists: the restore destroys the sessions those requests wait on,
    //   so a carried or dropped entry can never complete. Incident: a `danterm
    //   tab new` or `danterm pane input` in flight when a restore committed hung
    //   forever.
    @Test("restore rejects every pending IPC request exactly once")
    func restoreRejectsEveryPendingIpcRequest() throws {
        var live = makeModel()
        createTab(&live)
        let paneId = live.groups[0].tabs[0].paneTree.focusedPaneId
        let sessionId = try #require(live.pane(paneId)?.session?.id)
        let creationRequestId = UUID()
        live.pendingSessionCreations[sessionId] = PendingSessionCreation(
            requestId: creationRequestId,
            result: .null
        )
        // A multi-item input request in flight for a live pane, so this also
        // pins that a restore answers a request once, not once per submission.
        let inputRequestId = UUID()
        let request = try IpcRequest.decode(
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object([
                "pane": .string(paneId.rawValue.uuidString),
                "input": .array([
                    .object(["text": .string("a")]),
                    .object(["text": .string("b")]),
                ]),
            ])
        )
        _ = update(&live, .ipcRequest(reqId: inputRequestId, caller: .local, request: request))
        // A multi-submission entry whose pane is absent from the live tree: the
        // map sweep, not a pane walk, is what must answer it.
        let orphanRequestId = UUID()
        let orphanPaneId = PaneId()
        live.pendingInputSubmissions[InputSubmissionId()] = PendingInputSubmission(
            requestId: orphanRequestId,
            paneId: orphanPaneId
        )
        live.pendingInputSubmissions[InputSubmissionId()] = PendingInputSubmission(
            requestId: orphanRequestId,
            paneId: orphanPaneId
        )
        #expect(live.pendingInputSubmissions.count == 4)

        var restored = makeModel()
        createTab(&restored)
        let commands = update(&live, .restoreSession(restored))

        let rejections = commands.compactMap { command -> (reqId: UUID, code: Int, message: String)? in
            if case .ipcError(let id, let code, let message) = command {
                return (id, code, message)
            }
            return nil
        }
        #expect(rejections.count == 3)
        #expect(Set(rejections.map(\.reqId)) == [creationRequestId, inputRequestId, orphanRequestId])
        #expect(rejections.allSatisfy { $0.code == -32603 })
        #expect(
            rejections.first { $0.reqId == creationRequestId }?.message
                == "session restored before the pane process started"
        )
        for requestId in [inputRequestId, orphanRequestId] {
            #expect(
                rejections.first { $0.reqId == requestId }?.message
                    == "session restored before pane input was delivered"
            )
        }
        #expect(commands.contains {
            if case .installStagedRestoreSession = $0 { return true }
            return false
        })
        #expect(live.pendingSessionCreations.isEmpty)
        #expect(live.pendingInputSubmissions.isEmpty)
    }
}
