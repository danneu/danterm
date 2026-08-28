// Pure external IPC method dispatch for DanTerm's Elm core. This file owns request
// validation, model mutations, and reply construction; transport lifecycle stays outside
// DanTermCore. Changes to this API surface must update integrations/danterm/SKILL.md.
import Foundation
import DanTermProtocol

// MARK: - IPC Handlers

/// Non-throwing IPC error boundary: callers get `Command` replies while the
/// method dispatcher can use thrown validation errors internally.
func handleIpcRequest(
    _ model: inout AppModel,
    reqId: UUID,
    caller: IpcCallerIdentity,
    request: IpcRequest,
    env: CoreEnv
) -> [Command] {
    do {
        return try dispatchIpc(
            &model,
            reqId: reqId,
            caller: caller,
            request: request,
            env: env
        )
    } catch let error as IpcParamsError {
        return ipcInvalidParams(reqId, error.message)
    } catch {
        return [.ipcError(reqId: reqId, code: -32603, message: "internal error")]
    }
}

/// Carries per-method IPC dispatch behind `handleIpcRequest`, so each case can
/// validate with `throw` before mutating the model and leave reply translation central.
private func dispatchIpc(
    _ model: inout AppModel,
    reqId: UUID,
    caller: IpcCallerIdentity,
    request: IpcRequest,
    env: CoreEnv
) throws -> [Command] {
    if request.method.requiresLocalCaller, case .remote = caller {
        throw IpcParamsError("\(request.method.rawValue) is unavailable to remote callers")
    }

    switch request {
    case .ping:
        // Deliberately here and nowhere else. The reply's only content is the fact
        // that this function ran, so an instance too starved to service requests
        // fails liveness instead of answering from a cheaper layer.
        return [.ipcReply(reqId: reqId, result: okResult())]

    case .doctorAppFacts:
        return [.readDoctorAppFacts(reqId: reqId)]

    case .focusInfo:
        return [.readFocusInfo(reqId: reqId)]

    case .quit:
        // Allowlist, not denylist: only an instance the launcher pool handed out
        // may be ended over IPC, so an identity the scheme does not recognize is
        // refused without anyone having to name it here. Passing that instance's
        // socket is the authorization, the same way an explicit pane id
        // authorizes pane.close -- there is no confirmation and no todo check.
        guard env.instanceIdentity().isLauncherPoolSlot else {
            throw IpcParamsError("quit is limited to launcher slot instances")
        }
        // Reply before the terminate effect so the client can see an honored
        // quit; the CLI also reads the closed socket as success, because
        // NSApp.terminate tears the IPC server down behind this.
        return [.ipcReply(reqId: reqId, result: okResult())]
            + update(&model, .terminate, env: env)

    case .ls:
        let encoder = IpcEntityEncoder(home: env.homeDirectory())
        return [.ipcReply(reqId: reqId, result: encoder.list(model))]

    case .roster:
        // Subscribing is idempotent, so this arm says nothing about whether the
        // connection is already a subscriber: the runtime keys subscribers by
        // connection and a repeat request only re-answers with the same roster.
        return [.subscribeRoster(reqId: reqId, roster: paneRoster(in: model))]

    case .tailnetStatus:
        // Copied out, never derived. A remote caller is answered like a local one:
        // the reply names the endpoint that peer already reached and the state it is
        // in, which is nothing it could not observe by connecting.
        return [.ipcReply(reqId: reqId, result: model.tailnetStatus.json)]

    case .paneInfo(let paneId):
        try requirePane(paneId, in: model)
        guard let pane = model.pane(paneId),
              let tab = tabForPane(paneId, in: model),
              let group = groupForTab(tab.id, in: model)
        else {
            throw IpcParamsError("pane not found")
        }
        let encoder = IpcEntityEncoder(home: env.homeDirectory())
        return [.ipcReply(
            reqId: reqId,
            result: encoder.paneInfo(pane: pane, tab: tab, group: group, in: model)
        )]

    case .agentAttach(let paneId, let requestSession):
        let session = try agentSession(from: requestSession)
        try requirePane(paneId, in: model)
        guard let sessionId = model.pane(paneId)?.session?.id else {
            throw IpcParamsError("pane not found")
        }
        let commands = update(
            &model,
            .sessionReport(sessionId: sessionId, report: .agentAttached(session)),
            env: env
        )
        return commands + [.ipcReply(reqId: reqId, result: .object(["ok": .bool(true)]))]

    case .agentActivity(let paneId, let requestSession, let requestActivity):
        let session = try agentSession(from: requestSession)
        let activity = agentActivity(from: requestActivity)
        try requirePane(paneId, in: model)
        guard let sessionId = model.pane(paneId)?.session?.id else {
            throw IpcParamsError("pane not found")
        }
        let commands = update(
            &model,
            .sessionReport(
                sessionId: sessionId,
                report: .agentActivityChanged(session: session, activity: activity)
            ),
            env: env
        )
        return commands + [.ipcReply(reqId: reqId, result: .object(["ok": .bool(true)]))]

    case .agentDetach(let paneId, let requestSession):
        let session = try agentSession(from: requestSession)
        try requirePane(paneId, in: model)
        guard let sessionId = model.pane(paneId)?.session?.id else {
            throw IpcParamsError("pane not found")
        }
        let commands = update(
            &model,
            .sessionReport(sessionId: sessionId, report: .agentDetached(session)),
            env: env
        )
        return commands + [.ipcReply(reqId: reqId, result: .object(["ok": .bool(true)]))]

    case .groupNew(let requestedName, let launch, let background):
        let name = try groupName(requestedName)
        let effectiveLaunch = LaunchSpec(
            cmd: launch?.cmd,
            cwd: launch?.cwd ?? env.homeDirectory(),
            title: launch?.title
        )
        let groupsBefore = Set(model.groups.map(\.id))
        let tabsBefore = liveTabIds(in: model)
        let commands = update(
            &model,
            .createGroup(name: name, launch: effectiveLaunch, background: background),
            env: env
        )
        let group = model.groups.first(where: { groupsBefore.contains($0.id) == false })
        let tab = newestTabId(excluding: tabsBefore, in: model).flatMap { tabById($0, in: model) }
        let encoder = IpcEntityEncoder(home: env.homeDirectory())
        return deferCreationReply(
            commands,
            requestId: reqId,
            result: encoder.tabNew(tab: tab, group: group, in: model),
            paneId: tab?.paneTree.focusedPaneId,
            model: &model
        )

    case .groupClose(let groupId, let moveTabs):
        // Both refusals mirror how tab.close refuses the last tab. `.deleteGroup`
        // returns [] for the last group, and drives the app confirmation for a
        // destructive close of the group holding every tab -- which would leave the
        // group open and strand a pending confirmation. Quitting is `quit`'s job,
        // never a side effect of closing a group.
        guard let group = model.groups.first(where: { $0.id == groupId }) else {
            throw IpcParamsError("group not found")
        }
        guard model.groups.count > 1 else {
            throw IpcParamsError("cannot close the last group")
        }
        if moveTabs == false, group.tabs.isEmpty == false, totalTabCount(model) == group.tabs.count {
            throw IpcParamsError("cannot close the last group with tabs")
        }
        let commands = update(&model, .deleteGroup(id: groupId, moveTabs: moveTabs), env: env)
        return commands + [.ipcReply(reqId: reqId, result: .object([
            "group": .object(["id": .string(groupId.rawValue.uuidString)])
        ]))]

    case .groupRename(let groupId, let requestedName):
        try requireGroup(groupId, in: model)
        let name = try groupName(requestedName)
        let commands = update(&model, .renameGroup(id: groupId, name: name), env: env)
        let group = model.groups.first(where: { $0.id == groupId })
        let encoder = IpcEntityEncoder(home: env.homeDirectory())
        return commands + [.ipcReply(
            reqId: reqId,
            result: .object(["group": group.map(encoder.groupReference) ?? .null])
        )]

    case .tabRename(let tabId, let title):
        try requireTab(tabId, in: model)
        let commands = update(&model, .renameTab(id: tabId, name: title), env: env)
        return commands + [.ipcReply(reqId: reqId, result: tabRenameResult(tabById(tabId, in: model)))]

    case .tabClose(let tabId):
        try requireTab(tabId, in: model)
        // Refuse the last tab: routing it through .closeTab would set a terminate
        // confirmation, leave the tab open, and strand pendingConfirmation.
        // Quitting is `quit`'s job, never a side effect of closing a tab.
        if wouldQuitFromClose(model) {
            throw IpcParamsError("cannot close the last tab")
        }
        let commands = update(&model, .closeTab(id: tabId), env: env)
        return commands + [.ipcReply(reqId: reqId, result: .object([
            "tab": .object(["id": .string(tabId.rawValue.uuidString)])
        ]))]

    case .paneSplit(let target, let launch, let background):
        switch target {
        case .tab(let tabId):
            try requireTab(tabId, in: model)
            return [.resolveAutosplit(
                reqId: reqId,
                caller: caller,
                tabId: tabId,
                launch: launch,
                background: background
            )]
        case .pane(let paneId, let requestDirection):
            try requirePane(paneId, in: model)
            let before = Set(model.allPaneIds)
            let commands = update(
                &model,
                .splitPane(
                    paneId: paneId,
                    direction: requestDirection,
                    launch: launch,
                    background: background
                ),
                env: env
            )
            let newPaneId = model.allPaneIds.first(where: { !before.contains($0) })
            let encoder = IpcEntityEncoder(home: env.homeDirectory())
            return deferCreationReply(
                commands,
                requestId: reqId,
                result: encoder.paneReference(newPaneId.flatMap(model.pane)),
                paneId: newPaneId,
                model: &model
            )
        }

    case .paneClose(let paneId):
        try requirePane(paneId, in: model)
        guard let tab = tabForPane(paneId, in: model) else {
            throw IpcParamsError("pane not found")
        }
        if isSinglePane(tab.paneTree.root), wouldQuitFromClose(model) {
            throw IpcParamsError("cannot close the last pane")
        }
        let commands = update(&model, .closePane(paneId: paneId), env: env)
        return commands + [.ipcReply(reqId: reqId, result: .object([
            "pane": .object(["id": .string(paneId.rawValue.uuidString)])
        ]))]

    case .tabNew(let target, let launch, let background):
        let groupId: GroupId
        let position: TabInsertPosition
        switch target {
        case .group(let requestedGroupId, let requestedPosition):
            try requireGroup(requestedGroupId, in: model)
            groupId = requestedGroupId
            position = requestedPosition == .afterSelected ? .afterSelected : .atGroupEnd
        case .afterTab(let referenceTabId):
            guard let group = groupForTab(referenceTabId, in: model) else {
                throw IpcParamsError("position.afterTabId not found")
            }
            groupId = group.id
            position = .afterTab(referenceTabId)
        }
        let effectiveLaunch = LaunchSpec(
            cmd: launch?.cmd,
            cwd: launch?.cwd ?? env.homeDirectory(),
            title: launch?.title
        )
        let before = liveTabIds(in: model)
        let commands = update(
            &model,
            .createTab(
                inGroupId: groupId,
                position: position,
                launch: effectiveLaunch,
                background: background
            ),
            env: env
        )
        let tabId = newestTabId(excluding: before, in: model)
        let tab = tabId.flatMap { tabById($0, in: model) }
        let group = model.groups.first(where: { $0.id == groupId })
        let encoder = IpcEntityEncoder(home: env.homeDirectory())
        return deferCreationReply(
            commands,
            requestId: reqId,
            result: encoder.tabNew(tab: tab, group: group, in: model),
            paneId: tab?.paneTree.focusedPaneId,
            model: &model
        )

    case .paneFocus(let paneId):
        try requirePane(paneId, in: model)
        let commands = navigateToPane(paneId, in: &model, env: env)
        return commands + [.ipcReply(reqId: reqId, result: tabFocusResult(tabForPane(paneId, in: model)))]

    case .themeSet(let paneId, let themeName):
        try requirePane(paneId, in: model)
        let commands = update(&model, .setPaneTheme(paneId: paneId, themeName: themeName), env: env)
        let encoder = IpcEntityEncoder(home: env.homeDirectory())
        return commands + [.ipcReply(reqId: reqId, result: encoder.paneTheme(model.pane(paneId)))]

    case .paneInput(let paneId, let input):
        try requirePane(paneId, in: model)
        var commands: [Command] = []
        var submissionIds: [InputSubmissionId] = []
        // One read of the wait this pane's agent holds now, shared by every submission
        // in the request: they are all the same input act, and a wait raised while they
        // are in flight belongs to the next act, not this one.
        let waitGeneration = model.pane(paneId)?.session?.agent.currentWaitGeneration
        switch input {
        case .text(let text):
            let submissionId = InputSubmissionId(rawValue: env.newId())
            submissionIds.append(submissionId)
            commands.append(.submitPaneInput(
                paneId: paneId,
                input: .paste(text),
                submissionId: submissionId,
                waitGeneration: waitGeneration
            ))
        case .events(let events):
            commands.reserveCapacity(events.count)
            for event in events {
                let submissionId = InputSubmissionId(rawValue: env.newId())
                submissionIds.append(submissionId)
                switch event {
                case .text(let text):
                    commands.append(.submitPaneInput(
                        paneId: paneId,
                        input: .text(text),
                        submissionId: submissionId,
                        waitGeneration: waitGeneration
                    ))
                case .key(let key, let mods):
                    commands.append(.submitPaneInput(
                        paneId: paneId,
                        input: .key(key, modifiers: mods),
                        submissionId: submissionId,
                        waitGeneration: waitGeneration
                    ))
                case .wheel(let direction, let column, let row):
                    commands.append(.submitPaneInput(
                        paneId: paneId,
                        input: .wheel(direction, column: column, row: row),
                        submissionId: submissionId,
                        waitGeneration: waitGeneration
                    ))
                }
            }
        }
        guard submissionIds.isEmpty == false else {
            return [.ipcReply(reqId: reqId, result: okResult())]
        }
        for submissionId in submissionIds {
            model.pendingInputSubmissions[submissionId] = PendingInputSubmission(
                requestId: reqId,
                paneId: paneId
            )
        }
        return commands

    case .paneRead(let paneId, let lineLimit):
        try requirePane(paneId, in: model)
        return [.readPaneText(reqId: reqId, paneId: paneId, lineLimit: lineLimit)]

    case .paneCells(let paneId):
        try requirePane(paneId, in: model)
        return [.readPaneCells(reqId: reqId, paneId: paneId)]

    case .paneResize(let paneId, let requested):
        try requirePane(paneId, in: model)
        let commands: [Command]
        switch requested {
        case .grid(let columns, let rows):
            // The failable init is the whole range check: a grid the model
            // cannot hold is a grid the PTY, the engine, and a replica would
            // not all reproduce, so the caller is told rather than clamped.
            guard let grid = PaneGridOverride(columns: columns, rows: rows) else {
                throw IpcParamsError(
                    "columns must be \(paneGridOverrideColumnRange.lowerBound)-"
                        + "\(paneGridOverrideColumnRange.upperBound) and rows must be "
                        + "\(paneGridOverrideRowRange.lowerBound)-\(paneGridOverrideRowRange.upperBound)"
                )
            }
            commands = update(&model, .setPaneGridOverride(paneId: paneId, grid: grid), env: env)
        case .fit:
            commands = update(&model, .clearPaneGridOverride(paneId: paneId), env: env)
        }
        guard let pane = model.pane(paneId),
              let tab = tabForPane(paneId, in: model),
              let group = groupForTab(tab.id, in: model)
        else {
            throw IpcParamsError("pane not found")
        }
        let encoder = IpcEntityEncoder(home: env.homeDirectory())
        return commands + [.ipcReply(
            reqId: reqId,
            result: encoder.paneInfo(pane: pane, tab: tab, group: group, in: model)
        )]

    case .paneZoom(let paneId, let requested):
        try requirePane(paneId, in: model)
        guard let tab = tabForPane(paneId, in: model) else {
            throw IpcParamsError("pane not found")
        }
        // Resolve against the named pane rather than the tab flag, so `on` for a
        // pane whose tab is already zoomed on a sibling still moves the zoom.
        let isPaneZoomed = tab.paneTree.zoomedPaneId == paneId
        let target: Bool
        switch requested {
        case .on: target = true
        case .off: target = false
        case .toggle: target = isPaneZoomed == false
        }
        // Route through `.toggleZoomPane` rather than writing zoom here, so the
        // scripted path and the menubar/context-menu paths cannot drift: the guard that
        // only a split tab may zoom lives there and is the reason a request can be
        // honoured and still report `isZoomed: false`.
        var commands: [Command] = []
        if isPaneZoomed != target {
            commands = update(&model, .toggleZoomPane(paneId: paneId), env: env)
        }
        guard let pane = model.pane(paneId),
              let currentTab = tabForPane(paneId, in: model),
              let group = groupForTab(currentTab.id, in: model)
        else {
            throw IpcParamsError("pane not found")
        }
        let encoder = IpcEntityEncoder(home: env.homeDirectory())
        return commands + [.ipcReply(
            reqId: reqId,
            result: encoder.paneInfo(pane: pane, tab: currentTab, group: group, in: model)
        )]

    case .paneRows(let paneId):
        try requirePane(paneId, in: model)
        return [.readPaneRowStructure(reqId: reqId, paneId: paneId)]

    case .paneTape(let paneId, let follow, let start, let policy):
        try requirePane(paneId, in: model)
        return [.streamPaneTape(
            reqId: reqId,
            paneId: paneId,
            capture: follow ? .follow : .dump,
            start: start,
            policy: policy
        )]

    case .paneSnapshot(let paneId):
        try requirePane(paneId, in: model)
        return [.streamPaneTape(
            reqId: reqId,
            paneId: paneId,
            capture: .snapshot,
            start: .now,
            // A snapshot is the exact-state consumer, so it takes no history budget: the
            // whole retained state is the product it promises.
            policy: .reconstructible(historyBudgetBytes: nil)
        )]

    case .todoList(let owner):
        try requireTodoOwner(owner, in: model)
        let todos = model.todos(for: owner) ?? []
        return [.ipcReply(reqId: reqId, result: todoListResult(todos))]

    case .todoAdd(let owner, let text):
        try requireTodoOwner(owner, in: model)
        guard let item = appendTodo(
            &model, owner: owner, text: text, id: TodoId(rawValue: env.newId())
        ) else {
            throw IpcParamsError("invalid todo text")
        }
        return [.ipcReply(reqId: reqId, result: todoResult(item))]

    case .todoEdit(let owner, let todoId, let text):
        try requireTodoOwner(owner, in: model)
        guard todoExists(todoId, owner: owner, in: model) else {
            throw IpcParamsError("invalid todo")
        }
        let commands = update(&model, .editTodoText(owner: owner, todoId: todoId, text: text), env: env)
        let updated = model.todos(for: owner)?.first(where: { $0.id == todoId })
        return commands + [
            .ipcReply(reqId: reqId, result: todoResult(updated)),
        ]

    case .todoSetDone(let owner, let todoId, let isDone):
        try requireTodoOwner(owner, in: model)
        guard todoExists(todoId, owner: owner, in: model) else {
            throw IpcParamsError("invalid todo")
        }
        let commands = update(&model, .setTodoDone(owner: owner, todoId: todoId, isDone: isDone), env: env)
        let updated = model.todos(for: owner)?.first(where: { $0.id == todoId })
        return commands + [
            .ipcReply(reqId: reqId, result: todoResult(updated)),
        ]

    case .todoDelete(let owner, let todoId):
        try requireTodoOwner(owner, in: model)
        guard todoExists(todoId, owner: owner, in: model) else {
            throw IpcParamsError("invalid todo")
        }
        let commands = update(&model, .deleteTodo(owner: owner, todoId: todoId), env: env)
        return commands + [
            .ipcReply(reqId: reqId, result: okResult()),
        ]

    case .todoClearCompleted(let owner):
        try requireTodoOwner(owner, in: model)
        let commands = update(&model, .clearCompletedTodos(owner: owner), env: env)
        return commands + [
            .ipcReply(reqId: reqId, result: okResult()),
        ]

    }
}

/// Stores one creation reply beside the session whose process decides its result.
private func deferCreationReply(
    _ commands: [Command],
    requestId: UUID,
    result: JSONValue,
    paneId: PaneId?,
    model: inout AppModel
) -> [Command] {
    guard let paneId, let sessionId = model.pane(paneId)?.session?.id else {
        return commands + [.ipcError(
            reqId: requestId,
            code: -32603,
            message: "session creation did not produce a pane"
        )]
    }
    model.pendingSessionCreations[sessionId] = PendingSessionCreation(
        requestId: requestId,
        result: result
    )
    return commands
}

private func ipcInvalidParams(_ reqId: UUID, _ message: String) -> [Command] {
    [.ipcError(reqId: reqId, code: -32602, message: message)]
}

private struct IpcParamsError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Validates the session identity shared by every pane-scoped agent mutation.
private func agentSession(from request: IpcAgentSession) throws -> AgentSession {
    guard let session = AgentSession(kind: request.kind, sessionId: request.id) else {
        throw IpcParamsError("invalid agent session")
    }
    return session
}

private func agentActivity(from request: IpcAgentActivity) -> AgentActivity {
    switch request {
    case .working: return .working
    case .waiting: return .waiting
    case .idle: return .idle
    }
}

private func requirePane(_ paneId: PaneId, in model: AppModel) throws {
    guard model.pane(paneId) != nil else { throw IpcParamsError("pane not found") }
}

private func requireTab(_ tabId: TabId, in model: AppModel) throws {
    guard tabById(tabId, in: model) != nil else { throw IpcParamsError("tab not found") }
}

private func requireGroup(_ groupId: GroupId, in model: AppModel) throws {
    guard model.groups.contains(where: { $0.id == groupId }) else {
        throw IpcParamsError("group not found")
    }
}

/// Rejects a group name the reducer would silently drop, so a caller never sees
/// exit 0 for a rename that did not happen. `.renameGroup` returns [] when the
/// name normalizes away, and `.createGroup` normalizes nothing at all.
private func groupName(_ requested: String) throws -> String {
    guard let name = requested.singleLineName else { throw IpcParamsError("invalid name") }
    return name
}

private func newestTabId(excluding before: Set<TabId>, in model: AppModel) -> TabId? {
    model.groups.flatMap(\.tabs).first(where: { !before.contains($0.id) })?.id
}

private func tabRenameResult(_ tab: TabModel?) -> JSONValue {
    guard let tab else {
        return .object(["tab": .null])
    }
    return .object([
        "tab": .object([
            "id": .string(tab.id.rawValue.uuidString),
            "customTitle": tab.customTitle.map(JSONValue.string) ?? .null,
        ])
    ])
}

private func tabFocusResult(_ tab: TabModel?) -> JSONValue {
    guard let tab else {
        return .object(["tab": .null])
    }
    return .object([
        "tab": .object([
            "id": .string(tab.id.rawValue.uuidString),
            "focusedPaneId": .string(tab.paneTree.focusedPaneId.rawValue.uuidString),
        ])
    ])
}

private func todoResult(_ item: TodoItem?) -> JSONValue {
    .object(["todo": item.map(todoJSON) ?? .null])
}

private func todoListResult(_ todos: [TodoItem]) -> JSONValue {
    .object(["todos": .array(todos.map(todoJSON))])
}

private func okResult() -> JSONValue {
    .object(["ok": .bool(true)])
}

private func requireTodoOwner(_ owner: TodoOwner, in model: AppModel) throws {
    guard model.todos(for: owner) != nil else {
        switch owner {
        case .pane: throw IpcParamsError("pane not found")
        case .tab: throw IpcParamsError("tab not found")
        }
    }
}

private func todoExists(_ todoId: TodoId, owner: TodoOwner, in model: AppModel) -> Bool {
    model.todos(for: owner)?.contains(where: { $0.id == todoId }) == true
}

private func todoJSON(_ item: TodoItem) -> JSONValue {
    .object([
        "id": .string(item.id.rawValue.uuidString),
            "text": .string(item.text.value),
        "isDone": .bool(item.isDone),
    ])
}
