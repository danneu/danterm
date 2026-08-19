// Behavioral coverage for the unified close-confirmation transaction.
import Testing

@testable import DanTermCore

struct CloseConfirmationTests {
    @Test("confirmation projection follows every pending subject")
    func confirmationProjectionFollowsPendingSubject() throws {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        setRunning("npm run dev", in: paneId, model: &model)

        #expect(desiredConfirmation(in: model) == nil)

        _ = update(&model, .requestCloseTab(id: tabId))
        let close = try #require(desiredConfirmation(in: model))
        #expect(close.id == model.pendingConfirmation?.id)
        #expect(close.title == "Close tab \"Terminal\"?")
        #expect(close.informativeText == "This tab has a running command.")
        #expect(close.commands == ["npm run dev"])
        #expect(close.confirm.title == "Close Tab")
        #expect(close.confirm.isDestructive)
        #expect(close.cancel.answer == .cancel)
        #expect(close.confirm.answer == .confirm)
        #expect(close.alternatives.isEmpty)

        _ = update(&model, .requestQuit)
        let quit = try #require(desiredConfirmation(in: model))
        #expect(quit.id == model.pendingConfirmation?.id)
        #expect(quit.title == "Quit DanTerm?")
        #expect(quit.informativeText == "This will close 2 terminal sessions.")
        #expect(quit.commands == ["npm run dev"])
        #expect(quit.confirm.title == "Quit")
        #expect(quit.confirm.isDestructive)
        #expect(quit.cancel.answer == .cancel)
        #expect(quit.confirm.answer == .confirm)
    }

    // Intent: every subject offers exactly one cancel answer and one distinct
    // default answer, and the answers that destroy work say so.
    // Why it exists: the panel used to invent Cancel itself and to pick its
    // message from a hidden view, so no branch could state either fact.
    // Scenario: project each of the five subjects and read its choices.
    @Test("every confirmation subject offers a cancel and a distinct default")
    func everySubjectOffersCancelAndDefault() throws {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabIds = model.groups[0].tabs.map(\.id)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        setRunning("npm run dev", in: paneId, model: &model)
        _ = update(&model, .createGroup(name: "Work"))
        let workId = try #require(model.groups.first { $0.name == "Work" }?.id)

        var subjects: [AppModel] = []
        let closeSubjects: [ConfirmationSubject] = [.pane(paneId), .tab(tabIds[0]), .tabs(tabIds)]
        for subject in closeSubjects {
            var copy = model
            copy.pendingConfirmation = pendingCloseConfirmation(for: subject, in: copy)
            subjects.append(copy)
        }
        var quitModel = model
        quitModel.pendingConfirmation = pendingAppConfirmation()
        subjects.append(quitModel)
        var deleteModel = model
        _ = update(&deleteModel, .requestDeleteGroup(id: workId))
        subjects.append(deleteModel)

        for subjectModel in subjects {
            let projection = try #require(desiredConfirmation(in: subjectModel))
            #expect(projection.cancel.answer == .cancel)
            #expect(projection.cancel.title == "Cancel")
            #expect(projection.cancel.isDestructive == false)
            #expect(projection.confirm.answer != .cancel)
            for alternative in projection.alternatives {
                #expect(alternative.answer != .cancel)
            }
        }

        // Only the delete-group default keeps the tabs, so only it is safe.
        var destructive: [Bool] = []
        for subjectModel in subjects {
            destructive.append(try #require(desiredConfirmation(in: subjectModel)).confirm.isDestructive)
        }
        #expect(destructive == [true, true, true, true, false])

        let deleteGroup = try #require(desiredConfirmation(in: subjects[4]))
        #expect(deleteGroup.alternatives.map(\.isDestructive) == [true])
    }

    // Intent: an alternative is part of the projection's identity.
    // Why it exists: reconcileConfirmation reconfigures the panel only when the
    // diffed projection changes, so a choice it cannot see would never be drawn.
    // Scenario: two projections that agree on everything but one alternative.
    @Test("projections differing only in an alternative are not equal")
    func alternativeParticipatesInEquality() {
        let id = ConfirmationId()
        func projection(alternatives: [ConfirmationChoice]) -> ConfirmationProjection {
            ConfirmationProjection(
                id: id,
                title: "Delete group \"Work\"?",
                informativeText: "This group has 1 tab(s).",
                commands: [],
                confirm: ConfirmationChoice(
                    title: "Move to General", answer: .deleteGroup(moveTabs: true)),
                cancel: ConfirmationChoice(title: "Cancel", answer: .cancel),
                alternatives: alternatives
            )
        }
        let closeTabs = ConfirmationChoice(
            title: "Close Tabs", answer: .deleteGroup(moveTabs: false), isDestructive: true)

        #expect(projection(alternatives: []) != projection(alternatives: [closeTabs]))
        #expect(projection(alternatives: [closeTabs]) == projection(alternatives: [closeTabs]))
    }

    @Test("a newer request replaces the pending confirmation")
    func newerRequestReplacesPendingConfirmation() throws {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let secondTabId = model.groups[0].tabs[1].id
        setRunning("first", in: model.groups[0].tabs[0].paneTree.focusedPaneId, model: &model)
        setRunning("second", in: model.groups[0].tabs[1].paneTree.focusedPaneId, model: &model)
        _ = update(&model, .requestCloseTab(id: firstTabId))
        let firstId = try #require(model.pendingConfirmation?.id)

        let commands = update(&model, .requestCloseTab(id: secondTabId))

        #expect(commands.isEmpty)
        #expect(model.pendingConfirmation?.subject == .tab(secondTabId))
        #expect(model.pendingConfirmation?.id != firstId)
    }

    @Test("answers for a replaced transaction cannot affect its replacement")
    func staleAnswersCannotAffectReplacement() throws {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let secondTabId = model.groups[0].tabs[1].id
        setRunning("first", in: model.groups[0].tabs[0].paneTree.focusedPaneId, model: &model)
        setRunning("second", in: model.groups[0].tabs[1].paneTree.focusedPaneId, model: &model)
        _ = update(&model, .requestCloseTab(id: firstTabId))
        let staleId = try #require(model.pendingConfirmation?.id)
        _ = update(&model, .requestCloseTab(id: secondTabId))
        let replacement = try #require(model.pendingConfirmation)

        #expect(update(&model, .confirmConfirmation(id: staleId)).isEmpty)
        #expect(model.pendingConfirmation == replacement)
        #expect(tabById(firstTabId, in: model) != nil)
        #expect(tabById(secondTabId, in: model) != nil)

        #expect(update(&model, .cancelConfirmation(id: staleId)).isEmpty)
        #expect(model.pendingConfirmation == replacement)
    }

    @Test("confirmation retracts when its subject dies and survives unrelated changes")
    func confirmationValidityFollowsSubjectLifetime() throws {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let subjectTabId = model.groups[0].tabs[0].id
        let otherTabId = model.groups[0].tabs[1].id
        setRunning("sleep 300", in: model.groups[0].tabs[0].paneTree.focusedPaneId, model: &model)
        _ = update(&model, .requestCloseTab(id: subjectTabId))
        let pending = try #require(model.pendingConfirmation)

        _ = update(&model, .selectTab(id: otherTabId))
        #expect(model.pendingConfirmation == pending)

        _ = update(&model, .closeTab(id: subjectTabId))
        #expect(model.pendingConfirmation == nil)
        #expect(desiredConfirmation(in: model) == nil)
    }

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

        _ = update(&paneModel, .requestClosePane(paneId: subjectPaneId))

        #expect(closeConfirmation(in: paneModel)?.subject == .pane(subjectPaneId))
        #expect(paneModel.pane(subjectPaneId) != nil)

        var tabModel = makeModel()
        createTab(&tabModel)
        createTab(&tabModel)
        let runningTabId = tabModel.groups[0].tabs[0].id
        let runningPaneId = tabModel.groups[0].tabs[0].paneTree.focusedPaneId
        setRunning("npm run dev", in: runningPaneId, model: &tabModel)

        _ = update(&tabModel, .requestCloseTab(id: runningTabId))

        #expect(closeConfirmation(in: tabModel)?.subject == .tab(runningTabId))
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

        _ = update(&paneModel, .requestClosePane(paneId: idlePaneId))

        #expect(closeConfirmation(in: paneModel) == nil)
        #expect(paneModel.pane(idlePaneId) == nil)

        var tabModel = makeModel()
        createTab(&tabModel)
        createTab(&tabModel)
        let idleTabId = tabModel.groups[0].tabs[0].id

        _ = update(&tabModel, .requestCloseTab(id: idleTabId))

        #expect(closeConfirmation(in: tabModel) == nil)
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

        let commands = confirmPending(&model)

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

        let commands = confirmPending(&model)

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

        let commands = confirmPending(&model)

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

        let commands = confirmPending(&model)

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

        _ = confirmPending(&model)

        #expect(tabById(tabId, in: model) != nil)
        let refreshed = try #require(closeConfirmation(in: model))
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

        _ = confirmPending(&model)

        #expect(tabById(tabId, in: model) != nil)
        #expect(closeConfirmation(in: model) != nil)
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

        let commands = confirmPending(&model)

        #expect(commands.isEmpty)
        #expect(tabById(tabId, in: model) == nil)
    }

    @Test("quit replaces a pending close confirmation")
    func quitReplacesPendingCloseConfirmation() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        setRunning("sleep 300", in: paneId, model: &model)
        _ = update(&model, .requestCloseTab(id: try #require(selectedTab(in: model)?.id)))

        let commands = update(&model, .requestQuit)

        #expect(commands.isEmpty)
        #expect(model.pendingConfirmation?.subject == .app)
        #expect(desiredConfirmation(in: model)?.id == model.pendingConfirmation?.id)
    }

    @Test("a running last pane routes through a quit-authorized tab subject")
    func runningLastPaneRoutesThroughTabSubject() throws {
        var model = makeModel()
        createTab(&model)
        let tabId = try #require(selectedTab(in: model)?.id)
        let paneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        setRunning("sleep 300", in: paneId, model: &model)

        _ = update(&model, .requestClosePane(paneId: paneId))

        #expect(closeConfirmation(in: model)?.subject == .tab(tabId))
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

        let paneCommands = confirmPending(&paneModel)

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

        let batchCommands = confirmPending(&batchModel)

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

        _ = confirmPending(&tabModel)

        #expect(tabById(tabId, in: tabModel) != nil)
        #expect(closeConfirmation(in: tabModel)?.copy.commands == ["make test"])

        var batchModel = makeModel()
        createTab(&batchModel)
        createTab(&batchModel)
        createTab(&batchModel)
        let subjectIds = Array(batchModel.groups[0].tabs.prefix(2).map(\.id))
        let paneId = batchModel.groups[0].tabs[1].paneTree.focusedPaneId
        _ = update(&batchModel, .requestCloseTabs(ids: subjectIds))
        setRunning("rsync source dest", in: paneId, model: &batchModel)

        _ = confirmPending(&batchModel)

        #expect(subjectIds.allSatisfy { tabById($0, in: batchModel) != nil })
        #expect(closeConfirmation(in: batchModel)?.subject == .tabs(subjectIds))
        #expect(closeConfirmation(in: batchModel)?.copy.commands == ["rsync source dest"])
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

        _ = confirmPending(&confirmModel)

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

        _ = cancelPending(&cancelModel)

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
        #expect(tabCopy.commands == ["npm run dev"])
        #expect(paneCopy.informativeText == "This pane has a running command.")
        #expect(paneCopy.commands == tabCopy.commands)
    }

    @Test("a command is flattened but never shortened")
    func commandIsFlattenedButNeverShortened() {
        // Intent: the display boundary strips controls and bidi overrides, and
        //   that is the only thing standing between the raw command and the
        //   projection -- no length rule survives it.
        // Why it exists: the copy affordance can only hand over the whole command
        //   if the model kept the whole command. A length bound here is what made
        //   copying an ellipsis possible.
        // Scenario: a hostile command far past the old 60-character bound.
        let paneId = PaneId()
        let tail = String(repeating: "a", count: 300)
        let hostile = "\u{1B}[31m\u{202E}" + tail
        let impact = CloseImpact(
            panes: [.init(paneId: paneId, runningCommand: hostile)],
            uncompletedTodoCount: 0
        )

        let copy = closeConfirmationCopy(subject: .pane(paneId), impact: impact, quitAuthorized: false)

        #expect(copy.commands.map(\.text) == ["[31m" + tail])
        #expect(copy.commands[0].text.contains("\u{2026}") == false)
        #expect(copy.commands[0].text.contains("\u{1B}") == false)
        #expect(copy.commands[0].text.contains("\u{202E}") == false)
    }

    @Test("batch fallback, plural commands, and verbatim command text are exact")
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
        // Plural is the case that used to name no command at all.
        #expect(plural.commands.map(\.text) == ["one", "two"])

        for command in [
            String(repeating: "a", count: 60),
            String(repeating: "b", count: 61),
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
            #expect(copy.commands.map(\.text) == [command])
        }
    }
}

private func setRunning(_ command: String, in paneId: PaneId, model: inout AppModel) {
    model.updatePane(paneId) { $0.session?.command = .running(command) }
}

private func closeConfirmation(
    in model: AppModel
) -> (subject: ConfirmationSubject, copy: CloseConfirmationCopy)? {
    guard let pending = model.pendingConfirmation, let impact = pending.impact else { return nil }
    return (
        pending.subject,
        closeConfirmationCopy(
            subject: pending.subject,
            impact: impact,
            quitAuthorized: pending.quitAuthorized
        )
    )
}
