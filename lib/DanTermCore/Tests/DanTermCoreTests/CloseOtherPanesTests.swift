// Behavioral coverage for retaining one pane while atomically closing its siblings.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

/// Pins Close Others policy, teardown, background-tab targeting, and confirmation races.
struct CloseOtherPanesTests {
    @Test("one idle sibling closes immediately and a lone or stale target is inert")
    func immediateAndNoOpBoundaries() throws {
        var model = makeModel()
        createTab(&model)
        let retained = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)

        let loneBefore = model
        #expect(update(&model, .requestCloseOtherPanes(paneId: retained)).isEmpty)
        #expect(model == loneBefore)

        update(&model, .splitPane(paneId: retained, direction: .horizontal))
        let splitTab = try #require(selectedTab(in: model))
        let removed = try #require(
            allPaneIds(splitTab.paneTree.root).first { $0 != retained }
        )

        #expect(update(&model, .requestCloseOtherPanes(paneId: retained)).isEmpty)
        #expect(model.pane(retained) != nil)
        #expect(model.pane(removed) == nil)
        #expect(model.pendingConfirmation == nil)

        let staleBefore = model
        #expect(update(&model, .requestCloseOtherPanes(paneId: PaneId())).isEmpty)
        #expect(model == staleBefore)
    }

    @Test("nested close keeps the full target, focuses it, clears zoom, and leaves another tab")
    func nestedCloseRetainsTargetStateAndOtherTab() throws {
        var model = makeModel()
        createTab(&model)
        let subjectTabId = try #require(selectedTab(in: model)?.id)
        let retained = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        model.updatePane(retained) {
            $0.theme = "Solarized Dark"
            $0.fontSizeSteps = 3
            $0.todos = [TodoItem(id: TodoId(), text: TodoText("keep")!, isDone: false)]
        }
        update(&model, .splitPane(paneId: retained, direction: .horizontal))
        let second = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        update(&model, .splitPane(paneId: second, direction: .vertical))
        update(&model, .toggleZoomPane(paneId: second))
        let retainedBefore = try #require(model.pane(retained))

        createTab(&model)
        let otherTab = try #require(selectedTab(in: model))
        let otherPaneIds = allPaneIds(otherTab.paneTree.root)

        _ = update(&model, .requestCloseOtherPanes(paneId: retained))
        _ = confirmPending(&model)

        let subjectTab = try #require(tabById(subjectTabId, in: model))
        #expect(allPaneIds(subjectTab.paneTree.root) == [retained])
        #expect(subjectTab.paneTree.focusedPaneId == retained)
        #expect(subjectTab.paneTree.isZoomed == false)
        #expect(model.pane(retained) == retainedBefore)
        #expect(allPaneIds(otherTab.paneTree.root) == otherPaneIds)
        #expect(model.selectedTabId == otherTab.id)
    }

    @Test("confirmed close applies ordinary teardown to every removed pane")
    func confirmedCloseCleansEveryRemovedPane() throws {
        var model = makeModel()
        createTab(&model)
        let retained = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        update(&model, .splitPane(paneId: retained, direction: .horizontal))
        let second = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        update(&model, .splitPane(paneId: second, direction: .vertical))
        let splitTab = try #require(selectedTab(in: model))
        let removed = allPaneIds(splitTab.paneTree.root)
            .filter { $0 != retained }

        for paneId in removed {
            model.alerts.append(AlertModel(
                id: AlertId(), kind: .bell, paneId: paneId,
                title: "DanTerm", body: "done", createdAt: Date(), isUnread: true
            ))
        }
        model.todoPopover = .pane(removed[0])
        let creationRequest = UUID()
        let creationSession = try #require(model.pane(removed[0])?.session?.id)
        model.pendingSessionCreations[creationSession] = PendingSessionCreation(
            requestId: creationRequest,
            result: .null
        )
        let inputRequest = UUID()
        model.pendingInputSubmissions[InputSubmissionId()] = PendingInputSubmission(
            requestId: inputRequest,
            paneId: removed[1]
        )

        _ = update(&model, .requestCloseOtherPanes(paneId: retained))
        let commands = confirmPending(&model)

        #expect(removed.allSatisfy { model.pane($0) == nil })
        #expect(model.alerts.allSatisfy { removed.contains($0.paneId) == false })
        #expect(model.todoPopover == nil)
        #expect(model.pendingSessionCreations[creationSession] == nil)
        #expect(model.pendingInputSubmissions.isEmpty)
        let rejected = commands.compactMap { command -> UUID? in
            if case .ipcError(let requestId, _, _) = command { requestId } else { nil }
        }
        #expect(Set(rejected) == [creationRequest, inputRequest])
    }

    @Test("confirmation counts and impact include only panes that will close")
    func confirmationPolicyAndCopyAreAffectedOnly() throws {
        var model = makeModel()
        createTab(&model)
        let tabId = try #require(selectedTab(in: model)?.id)
        let retained = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        model.updatePane(retained) {
            $0.session?.command = .running("keep-running")
            $0.todos = [TodoItem(id: TodoId(), text: TodoText("keep task")!, isDone: false)]
        }
        update(&model, .addTodo(owner: .tab(tabId), text: TodoText("tab task")!))
        update(&model, .splitPane(paneId: retained, direction: .horizontal))
        let affected = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)

        _ = update(&model, .requestCloseOtherPanes(paneId: retained))
        #expect(model.pendingConfirmation == nil)
        #expect(model.pane(affected) == nil)

        update(&model, .splitPane(paneId: retained, direction: .horizontal))
        let warned = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        model.updatePane(warned) {
            $0.session?.command = .running("close-running")
            $0.todos = [TodoItem(id: TodoId(), text: TodoText("close task")!, isDone: false)]
        }
        _ = update(&model, .requestCloseOtherPanes(paneId: retained))

        let impact = try #require(pendingCloseImpact(model.pendingConfirmation))
        let projection = try #require(desiredConfirmation(in: model))
        #expect(impact.panes.map(\.paneId) == [warned])
        #expect(impact.uncompletedTodoCount == 1)
        #expect(projection.title == "Close other pane?")
        #expect(projection.informativeText == "1 other pane has a running command and 1 unfinished task. It will be closed.")
        #expect(projection.commands == ["close-running"])

        _ = cancelPending(&model)
        model.updatePane(warned) { $0.session?.command = .idle }
        _ = update(&model, .requestCloseOtherPanes(paneId: retained))
        #expect(model.pendingConfirmation != nil, "an unfinished affected-pane task should ask")

        _ = cancelPending(&model)
        model.updatePane(warned) {
            $0.todos = []
            $0.session?.command = .running("close-running")
        }
        _ = update(&model, .requestCloseOtherPanes(paneId: retained))
        #expect(model.pendingConfirmation != nil, "an affected running command should ask")

        _ = cancelPending(&model)
        model.updatePane(warned) {
            $0.todos = [TodoItem(id: TodoId(), text: TodoText("close task")!, isDone: false)]
        }
        update(&model, .splitPane(paneId: warned, direction: .vertical))
        _ = update(&model, .requestCloseOtherPanes(paneId: retained))
        #expect(pendingCloseImpact(model.pendingConfirmation)?.panes.count == 2)
        #expect(desiredConfirmation(in: model)?.title == "Close other panes?")
        #expect(
            desiredConfirmation(in: model)?.informativeText
                == "2 other panes have a running command and 1 unfinished task. They will be closed."
        )
    }

    @Test("cancel preserves every pane")
    func cancelPreservesEveryPane() throws {
        var model = makeModel()
        createTab(&model)
        let retained = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        update(&model, .splitPane(paneId: retained, direction: .horizontal))
        update(&model, .splitPane(
            paneId: try #require(selectedTab(in: model)?.paneTree.focusedPaneId),
            direction: .vertical
        ))
        let before = model

        _ = update(&model, .requestCloseOtherPanes(paneId: retained))
        _ = cancelPending(&model)

        var expected = before
        expected.pendingConfirmation = nil
        #expect(model == expected)
    }

    @Test("removing the retained pane retracts confirmation and a late answer is inert")
    func removedTargetRetractsAndRejectsLateAnswer() throws {
        var model = makeModel()
        createTab(&model)
        let retained = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        update(&model, .splitPane(paneId: retained, direction: .horizontal))
        update(&model, .splitPane(
            paneId: try #require(selectedTab(in: model)?.paneTree.focusedPaneId),
            direction: .vertical
        ))
        _ = update(&model, .requestCloseOtherPanes(paneId: retained))
        let staleId = try #require(model.pendingConfirmation?.id)

        _ = update(&model, .closePane(paneId: retained))
        #expect(model.pendingConfirmation == nil)
        let afterRemoval = model

        #expect(update(&model, .answerConfirmation(id: staleId, answer: .confirm)).isEmpty)
        #expect(model == afterRemoval)
    }

    @Test("a new sibling refreshes confirmation before any pane closes")
    func addedSiblingRefreshesConfirmation() throws {
        var model = makeModel()
        createTab(&model)
        let retained = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        update(&model, .splitPane(paneId: retained, direction: .horizontal))
        let firstAffected = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        model.updatePane(firstAffected) {
            $0.todos = [TodoItem(id: TodoId(), text: TodoText("warn")!, isDone: false)]
        }
        _ = update(&model, .requestCloseOtherPanes(paneId: retained))
        let firstId = try #require(model.pendingConfirmation?.id)
        update(&model, .splitPane(paneId: firstAffected, direction: .vertical))
        let beforeAnswer = Set(model.allPaneIds)

        _ = update(&model, .answerConfirmation(id: firstId, answer: .confirm))

        #expect(Set(model.allPaneIds) == beforeAnswer)
        #expect(model.pendingConfirmation?.id != firstId)
        #expect(pendingCloseImpact(model.pendingConfirmation)?.panes.count == 2)
    }

    @Test("new work in an affected pane refreshes confirmation before closing")
    func newWorkRefreshesConfirmation() throws {
        var model = makeModel()
        createTab(&model)
        let retained = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        update(&model, .splitPane(paneId: retained, direction: .horizontal))
        let affected = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        model.updatePane(affected) {
            $0.todos = [TodoItem(id: TodoId(), text: TodoText("warn")!, isDone: false)]
        }
        _ = update(&model, .requestCloseOtherPanes(paneId: retained))
        let firstId = try #require(model.pendingConfirmation?.id)
        model.updatePane(affected) { $0.session?.command = .running("make test") }

        _ = update(&model, .answerConfirmation(id: firstId, answer: .confirm))

        #expect(model.pane(affected) != nil)
        #expect(model.pendingConfirmation?.id != firstId)
        #expect(desiredConfirmation(in: model)?.commands == ["make test"])
    }
}
