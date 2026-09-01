// The teardown ritual every pane-removal path owes a pane that leaves the tree:
// its pending IPC work is rejected with the cause's exact wording, its alerts
// leave the global feed, and a popover anchored to it is retracted.
//
// The wordings and the group path's alert pruning are pinned only here; the
// per-path suites (UpdateTabTests, UpdateGroupTests, CloseOtherPanesTests)
// cover selection, tree shape, and confirmation instead.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

/// The IPC work seeded against one pane, so a test can name the two requests it
/// expects back as errors.
private struct SeededPaneWork {
    var creationRequest: UUID
    var inputRequest: UUID
    var creationSession: SessionId
}

/// Seeds both halves of a pane's pending IPC work plus one alert, so every path
/// in the matrix is measured against the same starting state.
private func seedTeardownWork(
    _ model: inout AppModel,
    pane paneId: PaneId
) throws -> SeededPaneWork {
    let creationSession = try #require(model.pane(paneId)?.session?.id)
    let creationRequest = UUID()
    model.pendingSessionCreations[creationSession] = PendingSessionCreation(
        requestId: creationRequest,
        result: .null
    )
    let inputRequest = UUID()
    model.pendingInputSubmissions[InputSubmissionId()] = PendingInputSubmission(
        requestId: inputRequest,
        paneId: paneId
    )
    model.alerts.append(AlertModel(
        id: AlertId(), kind: .bell, paneId: paneId,
        title: "DanTerm", body: "done", createdAt: Date(), isUnread: true
    ))
    return SeededPaneWork(
        creationRequest: creationRequest,
        inputRequest: inputRequest,
        creationSession: creationSession
    )
}

private func ipcErrors(_ commands: [Command]) -> [(reqId: UUID, code: Int, message: String)] {
    commands.compactMap { command in
        if case .ipcError(let reqId, let code, let message) = command {
            (reqId: reqId, code: code, message: message)
        } else {
            nil
        }
    }
}

/// Asserts the pane is gone, keeps no alerts, and got both rejections worded by
/// the cause the path names.
private func expectTornDown(
    _ model: AppModel,
    _ commands: [Command],
    pane paneId: PaneId,
    work: SeededPaneWork,
    creationMessage: String,
    inputMessage: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(model.pane(paneId) == nil, sourceLocation: sourceLocation)
    #expect(
        model.alerts.contains { $0.paneId == paneId } == false,
        sourceLocation: sourceLocation
    )
    #expect(
        model.pendingSessionCreations[work.creationSession] == nil,
        sourceLocation: sourceLocation
    )
    #expect(
        model.pendingInputSubmissions.values.contains { $0.paneId == paneId } == false,
        sourceLocation: sourceLocation
    )

    let errors = ipcErrors(commands)
    let creation = errors.first { $0.reqId == work.creationRequest }
    let input = errors.first { $0.reqId == work.inputRequest }
    #expect(creation?.code == -32603, sourceLocation: sourceLocation)
    #expect(creation?.message == creationMessage, sourceLocation: sourceLocation)
    #expect(input?.code == -32603, sourceLocation: sourceLocation)
    #expect(input?.message == inputMessage, sourceLocation: sourceLocation)
}

private let paneClosedCreationMessage = "pane closed before its process started"
private let paneClosedInputMessage = "pane closed before its input was delivered"
private let failedStartCreationMessage = "pane process failed to start"
private let failedStartInputMessage = "pane process failed to start before its input was delivered"

/// Pins the pane-teardown ritual across every path that removes a pane.
struct PaneTeardownTests {
    @Test("closing one pane of a split rejects its pending work and prunes its alerts")
    func closePaneTearsDownTheRemovedPane() throws {
        var model = makeModel()
        createTab(&model)
        let retained = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        update(&model, .splitPane(paneId: retained, direction: .horizontal))
        let removed = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        let work = try seedTeardownWork(&model, pane: removed)

        let commands = update(&model, .closePane(paneId: removed))

        #expect(model.pane(retained) != nil)
        expectTornDown(
            model, commands, pane: removed, work: work,
            creationMessage: paneClosedCreationMessage,
            inputMessage: paneClosedInputMessage
        )
    }

    @Test("close others rejects every removed sibling's pending work and prunes its alerts")
    func closeOtherPanesTearsDownEverySibling() throws {
        var model = makeModel()
        createTab(&model)
        let retained = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        update(&model, .splitPane(paneId: retained, direction: .horizontal))
        let removed = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        let work = try seedTeardownWork(&model, pane: removed)

        let commands = update(&model, .requestCloseOtherPanes(paneId: retained))
        #expect(model.pendingConfirmation == nil)

        #expect(model.pane(retained) != nil)
        expectTornDown(
            model, commands, pane: removed, work: work,
            creationMessage: paneClosedCreationMessage,
            inputMessage: paneClosedInputMessage
        )
    }

    @Test("closing a tab rejects its panes' pending work and prunes their alerts")
    func closeTabTearsDownEveryPane() throws {
        var model = makeModel()
        createTab(&model)
        let keeper = try #require(selectedTab(in: model)?.id)
        createTab(&model)
        let closing = try #require(selectedTab(in: model))
        let removed = closing.paneTree.focusedPaneId
        let work = try seedTeardownWork(&model, pane: removed)

        let commands = update(&model, .closeTab(id: closing.id))

        #expect(tabById(keeper, in: model) != nil)
        #expect(tabById(closing.id, in: model) == nil)
        expectTornDown(
            model, commands, pane: removed, work: work,
            creationMessage: paneClosedCreationMessage,
            inputMessage: paneClosedInputMessage
        )
    }

    @Test("deleting a group without moving its tabs tears down every pane it held")
    func deleteGroupTearsDownEveryPane() throws {
        var model = makeModel()
        createTab(&model)
        update(&model, .createGroup(name: "Other"))
        let doomedGroup = try #require(model.groups.last?.id)
        let doomedTab = try #require(model.groups.last?.tabs.first)
        let removed = doomedTab.paneTree.focusedPaneId
        let work = try seedTeardownWork(&model, pane: removed)

        let commands = update(&model, .deleteGroup(id: doomedGroup, moveTabs: false))

        #expect(model.groups.contains { $0.id == doomedGroup } == false)
        expectTornDown(
            model, commands, pane: removed, work: work,
            creationMessage: paneClosedCreationMessage,
            inputMessage: paneClosedInputMessage
        )
    }

    @Test("a failed session start tears down every pane of the tab it removes")
    func sessionCreationFailureTearsDownTheWholeTab() throws {
        var model = makeModel()
        createTab(&model)
        let keeper = try #require(selectedTab(in: model)?.id)
        createTab(&model)
        let failing = try #require(selectedTab(in: model))
        let removed = failing.paneTree.focusedPaneId
        let work = try seedTeardownWork(&model, pane: removed)

        let commands = update(&model, .sessionCreationFailed(sessionId: work.creationSession))

        #expect(tabById(keeper, in: model) != nil)
        #expect(tabById(failing.id, in: model) == nil)
        expectTornDown(
            model, commands, pane: removed, work: work,
            creationMessage: failedStartCreationMessage,
            inputMessage: failedStartInputMessage
        )
    }

    // The runtime quits on `.terminate`, so a rejection queued after it would
    // never reach the caller waiting on the reply.
    @Test("rejections precede the terminate when the removal empties the app")
    func rejectionsPrecedeTerminate() throws {
        var model = makeModel()
        createTab(&model)
        let firstPane = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        update(&model, .splitPane(paneId: firstPane, direction: .horizontal))
        let lastTab = try #require(selectedTab(in: model))
        var work = try seedTeardownWork(&model, pane: lastTab.paneTree.focusedPaneId)

        update(&model, .requestCloseTab(id: lastTab.id))
        let closeCommands = confirmPending(&model)
        try expectRejectionsBeforeTerminate(closeCommands, work: work)

        var failing = makeModel()
        createTab(&failing)
        let failingTab = try #require(selectedTab(in: failing))
        work = try seedTeardownWork(&failing, pane: failingTab.paneTree.focusedPaneId)

        let failureCommands = update(&failing, .sessionCreationFailed(sessionId: work.creationSession))
        try expectRejectionsBeforeTerminate(failureCommands, work: work)
    }

    private func expectRejectionsBeforeTerminate(
        _ commands: [Command],
        work: SeededPaneWork,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let terminateIndex = try #require(
            commands.firstIndex { if case .terminate = $0 { true } else { false } },
            sourceLocation: sourceLocation
        )
        let rejectionIndices = commands.indices.filter { index in
            if case .ipcError(let reqId, _, _) = commands[index] {
                return reqId == work.creationRequest || reqId == work.inputRequest
            }
            return false
        }
        #expect(rejectionIndices.count == 2, sourceLocation: sourceLocation)
        #expect(
            rejectionIndices.allSatisfy { $0 < terminateIndex },
            sourceLocation: sourceLocation
        )
    }

    // The teardown sites carry no popover clear of their own: `update()`'s
    // reconcile tail retracts a popover whose anchor left the model.
    @Test("a popover anchored to a removed pane or a closed tab is retracted")
    func popoverRetractsWithItsAnchor() throws {
        var model = makeModel()
        createTab(&model)
        let retained = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        update(&model, .splitPane(paneId: retained, direction: .horizontal))
        let removed = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        model.todoPopover = .pane(removed)
        #expect(todoPopoverAnchorIsEligible(.pane(removed), in: model))
        update(&model, .closePane(paneId: removed))
        #expect(model.todoPopover == nil)

        createTab(&model)
        let closing = try #require(selectedTab(in: model))
        let closingPane = closing.paneTree.focusedPaneId
        model.todoPopover = .pane(closingPane)
        #expect(todoPopoverAnchorIsEligible(.pane(closingPane), in: model))
        update(&model, .closeTab(id: closing.id))
        #expect(model.todoPopover == nil)

        createTab(&model)
        let tabAnchored = try #require(selectedTab(in: model)?.id)
        model.todoPopover = .tab(tabAnchored)
        #expect(todoPopoverAnchorIsEligible(.tab(tabAnchored), in: model))
        update(&model, .closeTab(id: tabAnchored))
        #expect(model.todoPopover == nil)

        update(&model, .createGroup(name: "Other"))
        let doomedGroup = try #require(model.groups.last?.id)
        let doomedPane = try #require(model.groups.last?.tabs.first?.paneTree.focusedPaneId)
        model.todoPopover = .pane(doomedPane)
        #expect(todoPopoverAnchorIsEligible(.pane(doomedPane), in: model))
        update(&model, .deleteGroup(id: doomedGroup, moveTabs: false))
        #expect(model.todoPopover == nil)
    }
}
