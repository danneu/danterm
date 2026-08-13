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
    request: IpcRequest,
    env: CoreEnv
) -> [Command] {
    do {
        return try dispatchIpc(
            &model,
            reqId: reqId,
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
    request: IpcRequest,
    env: CoreEnv
) throws -> [Command] {
    switch request {
    case .doctorPermissions:
        return [.readDoctorPermissions(reqId: reqId)]

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
        return commands + [.ipcReply(
            reqId: reqId,
            result: encoder.tabNew(tab: tab, group: group, in: model)
        )]

    case .groupClose(let groupId, let moveTabs):
        // Both refusals mirror how tab.close refuses the last tab. `.deleteGroup`
        // returns [] for the last group, and drives emitTerminateConfirmation for a
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

    case .paneSplit(let paneId, let requestDirection, let launch, let background):
        try requirePane(paneId, in: model)
        let direction: SplitNodeModel.Direction = requestDirection == .horizontal
            ? .horizontal
            : .vertical
        let before = Set(model.allPaneIds)
        let commands = update(
            &model,
            .splitPane(paneId: paneId, direction: direction, launch: launch, background: background),
            env: env
        )
        let newPaneId = model.allPaneIds.first(where: { !before.contains($0) })
        let encoder = IpcEntityEncoder(home: env.homeDirectory())
        return commands + [.ipcReply(reqId: reqId, result: encoder.paneReference(newPaneId.flatMap(model.pane)))]

    case .paneClose(let paneId):
        try requirePane(paneId, in: model)
        guard let tab = tabForPane(paneId, in: model) else {
            throw IpcParamsError("pane not found")
        }
        if allPaneIds(tab.paneTree.root).count == 1, wouldQuitFromClose(model) {
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
        return commands + [.ipcReply(
            reqId: reqId,
            result: encoder.tabNew(tab: tab, group: group, in: model)
        )]

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
        switch input {
        case .text(let text):
            return [
                .sendText(paneId: paneId, text: text),
                .ipcReply(reqId: reqId, result: okResult()),
            ]
        case .events(let events):
            var commands: [Command] = []
            commands.reserveCapacity(events.count + 1)
            for event in events {
                switch event {
                case .text(let text):
                    commands.append(.sendInputText(paneId: paneId, text: text))
                case .key(let key, let mods):
                    commands.append(.sendInputKey(paneId: paneId, key: key, mods: mods))
                }
            }
            commands.append(.ipcReply(reqId: reqId, result: okResult()))
            return commands
        }

    case .paneRead(let paneId, let lineLimit):
        try requirePane(paneId, in: model)
        return [.readPaneText(reqId: reqId, paneId: paneId, lineLimit: lineLimit)]

    case .paneZoom(let paneId, let requested):
        try requirePane(paneId, in: model)
        guard let tab = tabForPane(paneId, in: model) else {
            throw IpcParamsError("pane not found")
        }
        let target: Bool
        switch requested {
        case .on: target = true
        case .off: target = false
        case .toggle: target = tab.paneTree.isZoomed == false
        }
        // Route through `.toggleZoomPane` rather than writing `isZoomed` here, so the
        // scripted path and the menubar/context-menu paths cannot drift: the guard that
        // only a split tab may zoom lives there and is the reason a request can be
        // honoured and still report `isZoomed: false`.
        if tab.paneTree.isZoomed != target {
            _ = update(&model, .toggleZoomPane(paneId: paneId), env: env)
        }
        guard let pane = model.pane(paneId),
              let currentTab = tabForPane(paneId, in: model),
              let group = groupForTab(currentTab.id, in: model)
        else {
            throw IpcParamsError("pane not found")
        }
        let encoder = IpcEntityEncoder(home: env.homeDirectory())
        return [.ipcReply(
            reqId: reqId,
            result: encoder.paneInfo(pane: pane, tab: currentTab, group: group, in: model)
        )]

    case .paneRows(let paneId):
        try requirePane(paneId, in: model)
        return [.readPaneRowStructure(reqId: reqId, paneId: paneId)]

    case .paneTape(let paneId, let follow, let fromNow):
        try requirePane(paneId, in: model)
        return follow
            ? [.followPaneTape(reqId: reqId, paneId: paneId, fromNow: fromNow)]
            : [.dumpPaneTape(reqId: reqId, paneId: paneId)]

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

    case .todoDone(let owner, let todoId), .todoOpen(let owner, let todoId):
        try requireTodoOwner(owner, in: model)
        guard todoExists(todoId, owner: owner, in: model) else {
            throw IpcParamsError("invalid todo")
        }
        let shouldBeDone: Bool
        switch request {
        case .todoDone: shouldBeDone = true
        case .todoOpen: shouldBeDone = false
        default: preconditionFailure("exhaustive todo state request")
        }
        let commands = update(&model, .setTodoDone(owner: owner, todoId: todoId, isDone: shouldBeDone), env: env)
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
        "text": .string(item.text),
        "isDone": .bool(item.isDone),
    ])
}
