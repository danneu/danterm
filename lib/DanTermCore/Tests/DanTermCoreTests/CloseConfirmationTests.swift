// Behavioral coverage for the unified close-confirmation transaction.
import Testing

@testable import DanTermCore

struct CloseConfirmationTests {
    @Test("impact records running commands by pane and rolls up tab tasks")
    func impactRecordsCommandsAndTasks() throws {
        var model = makeModel()
        createTab(&model)
        let tabId = try #require(selectedTab(in: model)?.id)
        let firstPaneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        setRunning("make test", in: firstPaneId, model: &model)
        update(&model, .addTodo(owner: .tab(tabId), text: "ship it"))
        update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let paneIds = allPaneIds(try #require(selectedTab(in: model)).paneTree.root)

        let impact = try #require(closeImpact(for: .tab(tabId), in: model))

        #expect(impact.panes.map(\.paneId) == paneIds)
        #expect(impact.panes.map(\.runningCommand) == ["make test", nil])
        #expect(impact.uncompletedTodoCount == 1)
        #expect(closeImpact(for: .pane(paneIds[1]), in: model)?.panes[0].runningCommand == nil)
        model.updatePane(paneIds[1]) { $0.session = nil }
        #expect(closeImpact(for: .pane(paneIds[1]), in: model)?.panes[0].runningCommand == nil)
        #expect(closeImpact(for: .pane(PaneId()), in: model) == nil)

        createTab(&model)
        let secondTabId = try #require(selectedTab(in: model)?.id)
        let secondTabPaneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        setRunning("rsync source dest", in: secondTabPaneId, model: &model)
        let batchImpact = try #require(closeImpact(for: .tabs([tabId, secondTabId]), in: model))
        #expect(batchImpact.panes.map(\.runningCommand) == ["make test", nil, "rsync source dest"])
        #expect(batchImpact.uncompletedTodoCount == 1)
    }

    @Test("running command gates pane and single-pane tab closes")
    func runningCommandGatesInteractiveCloses() throws {
        var paneModel = makeModel()
        createTab(&paneModel)
        createTab(&paneModel)
        let tabId = paneModel.groups[0].tabs[0].id
        update(&paneModel, .selectTab(id: tabId))
        let firstPaneId = try #require(selectedTab(in: paneModel)?.paneTree.focusedPaneId)
        update(&paneModel, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let subjectPaneId = try #require(selectedTab(in: paneModel)?.paneTree.focusedPaneId)
        setRunning("sleep 300", in: subjectPaneId, model: &paneModel)

        let paneCommands = update(&paneModel, .requestClosePane(paneId: subjectPaneId))

        #expect(closeConfirmation(in: paneCommands)?.subject == .pane(subjectPaneId))
        #expect(paneModel.pane(subjectPaneId) != nil)

        var tabModel = makeModel()
        createTab(&tabModel)
        createTab(&tabModel)
        let runningTabId = tabModel.groups[0].tabs[0].id
        let runningPaneId = tabModel.groups[0].tabs[0].paneTree.focusedPaneId
        setRunning("npm run dev", in: runningPaneId, model: &tabModel)

        let tabCommands = update(&tabModel, .requestCloseTab(id: runningTabId))

        #expect(closeConfirmation(in: tabCommands)?.subject == .tab(runningTabId))
        #expect(tabById(runningTabId, in: tabModel) != nil)
    }

    @Test("idle interactive closes stay direct")
    func idleInteractiveClosesStayDirect() throws {
        var paneModel = makeModel()
        createTab(&paneModel)
        createTab(&paneModel)
        let tabId = paneModel.groups[0].tabs[0].id
        update(&paneModel, .selectTab(id: tabId))
        let firstPaneId = try #require(selectedTab(in: paneModel)?.paneTree.focusedPaneId)
        update(&paneModel, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let idlePaneId = try #require(selectedTab(in: paneModel)?.paneTree.focusedPaneId)

        let paneCommands = update(&paneModel, .requestClosePane(paneId: idlePaneId))

        #expect(closeConfirmation(in: paneCommands) == nil)
        #expect(paneModel.pane(idlePaneId) == nil)

        var tabModel = makeModel()
        createTab(&tabModel)
        createTab(&tabModel)
        let idleTabId = tabModel.groups[0].tabs[0].id

        let tabCommands = update(&tabModel, .requestCloseTab(id: idleTabId))

        #expect(closeConfirmation(in: tabCommands) == nil)
        #expect(tabById(idleTabId, in: tabModel) == nil)
    }

    @Test("confirming an authorized last-tab close terminates once")
    func authorizedLastTabCloseTerminatesOnce() throws {
        var model = makeModel()
        createTab(&model)
        let tabId = try #require(selectedTab(in: model)?.id)
        let paneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        update(&model, .splitPane(paneId: paneId, direction: .horizontal))
        _ = update(&model, .requestCloseTab(id: tabId))

        let commands = update(&model, .confirmConfirmation)

        #expect(commands.count(where: { if case .terminate = $0 { true } else { false } }) == 1)
        #expect(model.hasAnyTab == false)
        #expect(model.pendingConfirmation == nil)
    }

    @Test("authorization follows the subject rather than a stale quit outcome")
    func authorizationFollowsSubject() throws {
        var model = makeModel()
        createTab(&model)
        let subjectTabId = try #require(selectedTab(in: model)?.id)
        let paneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        update(&model, .splitPane(paneId: paneId, direction: .horizontal))
        _ = update(&model, .requestCloseTab(id: subjectTabId))
        createTab(&model)
        let survivorTabId = try #require(selectedTab(in: model)?.id)
        let survivorPaneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        setRunning("rsync source dest", in: survivorPaneId, model: &model)

        let commands = update(&model, .confirmConfirmation)

        #expect(commands.contains { if case .terminate = $0 { true } else { false } } == false)
        #expect(tabById(subjectTabId, in: model) == nil)
        #expect(tabById(survivorTabId, in: model) != nil)
        #expect(model.pane(survivorPaneId)?.session?.command == .running("rsync source dest"))
    }

    @Test("an unauthorized close that becomes app-emptying asks before quitting")
    func unauthorizedCloseThatBecomesAppEmptyingAsks() throws {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let subjectTabId = model.groups[0].tabs[0].id
        let otherTabId = model.groups[0].tabs[1].id
        update(&model, .selectTab(id: subjectTabId))
        let paneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        update(&model, .splitPane(paneId: paneId, direction: .horizontal))
        _ = update(&model, .requestCloseTab(id: subjectTabId))
        _ = update(&model, .closeTab(id: otherTabId))

        let commands = update(&model, .confirmConfirmation)

        #expect(commands.contains { if case .terminate = $0 { true } else { false } } == false)
        #expect(tabById(subjectTabId, in: model) != nil)
        #expect(model.pendingConfirmation?.subject == .app)
    }

    @Test("an app confirmation always terminates after new work starts")
    func appConfirmationAlwaysTerminates() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        _ = update(&model, .requestQuit)
        setRunning("while true; do work; done", in: paneId, model: &model)

        let commands = update(&model, .confirmConfirmation)

        #expect(commands.contains { if case .terminate = $0 { true } else { false } })
        #expect(model.pendingConfirmation == nil)
    }

    @Test("new or changed pane work refreshes a frozen close alert")
    func growthRefreshesFrozenAlert() throws {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: tabId))
        let firstPaneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        setRunning("sleep 300", in: firstPaneId, model: &model)
        _ = update(&model, .requestCloseTab(id: tabId))
        update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let newPaneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        setRunning("sleep 300", in: newPaneId, model: &model)

        let commands = update(&model, .confirmConfirmation)

        #expect(tabById(tabId, in: model) != nil)
        let refreshed = try #require(closeConfirmation(in: commands))
        #expect(refreshed.subject == .tab(tabId))
        #expect(refreshed.copy.informativeText == "This tab has 2 terminal panes and 2 running commands.")
    }

    @Test("an idle pane added under an alert refreshes it")
    func idlePaneGrowthRefreshesAlert() throws {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: tabId))
        let paneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        setRunning("sleep 300", in: paneId, model: &model)
        _ = update(&model, .requestCloseTab(id: tabId))
        update(&model, .splitPane(paneId: paneId, direction: .horizontal))

        let commands = update(&model, .confirmConfirmation)

        #expect(tabById(tabId, in: model) != nil)
        #expect(closeConfirmation(in: commands) != nil)
    }

    @Test("a covered command finishing does not refresh the alert")
    func commandFinishingAllowsClose() throws {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        setRunning("sleep 300", in: paneId, model: &model)
        _ = update(&model, .requestCloseTab(id: tabId))
        model.updatePane(paneId) { $0.session?.command = .idle }

        let commands = update(&model, .confirmConfirmation)

        #expect(commands.isEmpty)
        #expect(tabById(tabId, in: model) == nil)
    }

    @Test("one pending transaction blocks another confirmation surface")
    func pendingTransactionBlocksStacking() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        setRunning("sleep 300", in: paneId, model: &model)
        _ = update(&model, .requestCloseTab(id: try #require(selectedTab(in: model)?.id)))

        let commands = update(&model, .requestQuit)

        #expect(commands.isEmpty)
        #expect(model.pendingConfirmation?.subject != .app)
        #expect(desiredQuitConfirmation(in: model) == nil)
    }

    @Test("a running last pane routes through a quit-authorized tab subject")
    func runningLastPaneRoutesThroughTabSubject() throws {
        var model = makeModel()
        createTab(&model)
        let tabId = try #require(selectedTab(in: model)?.id)
        let paneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        setRunning("sleep 300", in: paneId, model: &model)

        let commands = update(&model, .requestClosePane(paneId: paneId))

        #expect(closeConfirmation(in: commands)?.subject == .tab(tabId))
        #expect(model.pendingConfirmation?.quitAuthorized == true)
    }

    @Test("pane and batch closes ask if they become app-emptying while open")
    func paneAndBatchThatBecomeAppEmptyingAsk() throws {
        var paneModel = makeModel()
        createTab(&paneModel)
        let firstPaneId = try #require(selectedTab(in: paneModel)?.paneTree.focusedPaneId)
        update(&paneModel, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let subjectPaneId = try #require(selectedTab(in: paneModel)?.paneTree.focusedPaneId)
        setRunning("sleep 300", in: subjectPaneId, model: &paneModel)
        _ = update(&paneModel, .requestClosePane(paneId: subjectPaneId))
        _ = update(&paneModel, .closePane(paneId: firstPaneId))

        let paneCommands = update(&paneModel, .confirmConfirmation)

        #expect(paneCommands.contains { if case .terminate = $0 { true } else { false } } == false)
        #expect(paneModel.pane(subjectPaneId) != nil)
        #expect(paneModel.pendingConfirmation?.subject == .app)

        var batchModel = makeModel()
        createTab(&batchModel)
        createTab(&batchModel)
        createTab(&batchModel)
        let subjectIds = Array(batchModel.groups[0].tabs.prefix(2).map(\.id))
        let outsideId = batchModel.groups[0].tabs[2].id
        _ = update(&batchModel, .requestCloseTabs(ids: subjectIds))
        _ = update(&batchModel, .closeTab(id: outsideId))

        let batchCommands = update(&batchModel, .confirmConfirmation)

        #expect(batchCommands.contains { if case .terminate = $0 { true } else { false } } == false)
        #expect(batchModel.hasAnyTab == false)
        #expect(batchModel.pendingConfirmation?.subject == .app)
    }

    @Test("starting work in a covered pane refreshes tab and batch subjects")
    func coveredPaneWorkRefreshesTabAndBatch() throws {
        var tabModel = makeModel()
        createTab(&tabModel)
        createTab(&tabModel)
        let tabId = tabModel.groups[0].tabs[0].id
        update(&tabModel, .selectTab(id: tabId))
        let firstPaneId = try #require(selectedTab(in: tabModel)?.paneTree.focusedPaneId)
        update(&tabModel, .splitPane(paneId: firstPaneId, direction: .horizontal))
        _ = update(&tabModel, .requestCloseTab(id: tabId))
        setRunning("make test", in: firstPaneId, model: &tabModel)

        let tabCommands = update(&tabModel, .confirmConfirmation)

        #expect(tabById(tabId, in: tabModel) != nil)
        #expect(closeConfirmation(in: tabCommands)?.copy.commandDetail == "make test")

        var batchModel = makeModel()
        createTab(&batchModel)
        createTab(&batchModel)
        createTab(&batchModel)
        let subjectIds = Array(batchModel.groups[0].tabs.prefix(2).map(\.id))
        let paneId = batchModel.groups[0].tabs[1].paneTree.focusedPaneId
        _ = update(&batchModel, .requestCloseTabs(ids: subjectIds))
        setRunning("rsync source dest", in: paneId, model: &batchModel)

        let batchCommands = update(&batchModel, .confirmConfirmation)

        #expect(subjectIds.allSatisfy { tabById($0, in: batchModel) != nil })
        #expect(closeConfirmation(in: batchCommands)?.subject == .tabs(subjectIds))
        #expect(closeConfirmation(in: batchCommands)?.copy.commandDetail == "rsync source dest")
    }

    @Test("pane confirm closes and pane cancel leaves it intact")
    func paneConfirmAndCancel() throws {
        var confirmModel = makeModel()
        createTab(&confirmModel)
        createTab(&confirmModel)
        let tabId = confirmModel.groups[0].tabs[0].id
        update(&confirmModel, .selectTab(id: tabId))
        let firstPaneId = try #require(selectedTab(in: confirmModel)?.paneTree.focusedPaneId)
        update(&confirmModel, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let paneId = try #require(selectedTab(in: confirmModel)?.paneTree.focusedPaneId)
        setRunning("sleep 300", in: paneId, model: &confirmModel)
        _ = update(&confirmModel, .requestClosePane(paneId: paneId))

        _ = update(&confirmModel, .confirmConfirmation)

        #expect(confirmModel.pane(paneId) == nil)
        #expect(confirmModel.pendingConfirmation == nil)

        var cancelModel = makeModel()
        createTab(&cancelModel)
        createTab(&cancelModel)
        let cancelTabId = cancelModel.groups[0].tabs[0].id
        update(&cancelModel, .selectTab(id: cancelTabId))
        let cancelFirstPaneId = try #require(selectedTab(in: cancelModel)?.paneTree.focusedPaneId)
        update(&cancelModel, .splitPane(paneId: cancelFirstPaneId, direction: .horizontal))
        let cancelPaneId = try #require(selectedTab(in: cancelModel)?.paneTree.focusedPaneId)
        setRunning("sleep 300", in: cancelPaneId, model: &cancelModel)
        _ = update(&cancelModel, .requestClosePane(paneId: cancelPaneId))

        _ = update(&cancelModel, .cancelConfirmation)

        #expect(cancelModel.pane(cancelPaneId) != nil)
        #expect(cancelModel.pendingConfirmation == nil)
    }

    @Test("copy joins panes, commands, tasks, and quit text in order")
    func copyJoinsClausesInOrder() {
        let paneA = PaneId()
        let paneB = PaneId()
        let impact = CloseImpact(
            panes: [
                .init(paneId: paneA, runningCommand: "npm run dev"),
                .init(paneId: paneB, runningCommand: nil),
            ],
            uncompletedTodoCount: 1
        )

        let tabCopy = closeConfirmationCopy(subject: .tab(TabId()), impact: impact, quitAuthorized: true)
        let paneCopy = closeConfirmationCopy(
            subject: .pane(paneA),
            impact: CloseImpact(panes: [.init(paneId: paneA, runningCommand: "npm run dev")], uncompletedTodoCount: 0),
            quitAuthorized: false
        )

        #expect(tabCopy.informativeText == "This tab has 2 terminal panes, a running command and 1 unfinished task. Closing it will quit DanTerm.")
        #expect(tabCopy.commandDetail == "npm run dev")
        #expect(paneCopy.informativeText == "This pane has a running command.")
        #expect(paneCopy.commandDetail == tabCopy.commandDetail)
    }

    @Test("command detail is normalized and bounded after normalization")
    func commandDetailIsNormalizedAndBounded() {
        let paneId = PaneId()
        let hostile = "\u{1B}[31m\u{202E}" + String(repeating: "a", count: 61)
        let impact = CloseImpact(
            panes: [.init(paneId: paneId, runningCommand: hostile)],
            uncompletedTodoCount: 0
        )

        let copy = closeConfirmationCopy(subject: .pane(paneId), impact: impact, quitAuthorized: false)

        #expect(copy.commandDetail?.text == "[31m" + String(repeating: "a", count: 55) + "\u{2026}")
        #expect(copy.commandDetail?.text.count == 60)
        #expect(copy.commandDetail?.text.contains("\u{1B}") == false)
        #expect(copy.commandDetail?.text.contains("\u{202E}") == false)
    }

    @Test("batch fallback, plural commands, and command detail boundaries are exact")
    func remainingCopyFormsAreExact() {
        let paneA = PaneId()
        let paneB = PaneId()
        let idleImpact = CloseImpact(
            panes: [
                .init(paneId: paneA, runningCommand: nil),
                .init(paneId: paneB, runningCommand: nil),
            ],
            uncompletedTodoCount: 0
        )
        let runningImpact = CloseImpact(
            panes: [
                .init(paneId: paneA, runningCommand: "one"),
                .init(paneId: paneB, runningCommand: "two"),
            ],
            uncompletedTodoCount: 0
        )

        #expect(closeConfirmationCopy(
            subject: .tabs([TabId(), TabId()]),
            impact: idleImpact,
            quitAuthorized: false
        ).informativeText == "These tabs will be closed.")
        #expect(closeConfirmationCopy(
            subject: .tabs([TabId(), TabId()]),
            impact: idleImpact,
            quitAuthorized: true
        ).informativeText == "These tabs will be closed. Closing them will quit DanTerm.")
        let plural = closeConfirmationCopy(
            subject: .tabs([TabId(), TabId()]),
            impact: runningImpact,
            quitAuthorized: false
        )
        #expect(plural.informativeText == "These tabs have 2 running commands.")
        #expect(plural.commandDetail == nil)

        for command in [
            String(repeating: "a", count: 60),
            "say \"double\" and 'single'",
        ] {
            let copy = closeConfirmationCopy(
                subject: .pane(paneA),
                impact: CloseImpact(
                    panes: [.init(paneId: paneA, runningCommand: command)],
                    uncompletedTodoCount: 0
                ),
                quitAuthorized: false
            )
            #expect(copy.commandDetail?.text == command)
        }
        let long = String(repeating: "b", count: 61)
        let bounded = closeConfirmationCopy(
            subject: .pane(paneA),
            impact: CloseImpact(
                panes: [.init(paneId: paneA, runningCommand: long)],
                uncompletedTodoCount: 0
            ),
            quitAuthorized: false
        )
        #expect(bounded.commandDetail?.text == String(repeating: "b", count: 59) + "\u{2026}")
    }
}

private func setRunning(_ command: String, in paneId: PaneId, model: inout AppModel) {
    model.updatePane(paneId) { $0.session?.command = .running(command) }
}

private func closeConfirmation(
    in commands: [Command]
) -> (subject: ConfirmationSubject, copy: CloseConfirmationCopy)? {
    for command in commands {
        if case .showCloseConfirmation(let subject, _, _, let copy) = command {
            return (subject, copy)
        }
    }
    return nil
}
