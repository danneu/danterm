// Tests for pure update() handling of DanTerm IPC requests.
import Foundation
import DanTermProtocol

func ipcUpdateTests() {
    print("IPC update tests:")

    test("unknown method returns method-not-found error") {
        var model = makeModel()
        createTab(&model)
        let effects = sendIpc(&model, method: "missing")
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32601)
    }

    test("malformed context returns invalid params") {
        var model = makeModel()
        createTab(&model)
        let effects = sendIpc(&model, method: Methods.tabTitle, context: IpcRequestContext(paneId: "not-a-uuid"))
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
    }

    test("ls returns full snapshot") {
        var model = makeModel()
        createTab(&model)
        let effects = sendIpc(&model, method: Methods.ls)
        let reply = try requireIpcReply(effects)
        guard case .object(let object) = reply else {
            throw TestFailure(message: "expected object snapshot")
        }
        try expect(object["groups"] != nil, "snapshot should include groups")
        try expect(object["panes"] != nil, "snapshot should include panes")
    }

    test("tab.title set and get use pane current tab") {
        var model = makeModel()
        createTab(&model)
        let ctx = contextForSelectedPane(in: model)

        _ = sendIpc(&model, method: Methods.tabTitle, params: .object(["title": .string("hello")]), context: ctx)
        let effects = sendIpc(&model, method: Methods.tabTitle, context: ctx)
        let reply = try requireIpcReply(effects)
        try expectEqual(reply["title"]?.asString, "hello")
    }

    test("tab.title ignores stale tab id when pane moved") {
        var model = makeModel()
        createTab(&model)
        let sourceTabId = selectedTab(in: model)!.id
        let paneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .splitPane(direction: .horizontal))
        createTab(&model)
        let targetTabId = selectedTab(in: model)!.id
        _ = update(&model, .movePaneToTab(paneId: paneId, targetTabId: targetTabId))

        let stale = IpcRequestContext(
            paneId: paneId.rawValue.uuidString,
            tabId: sourceTabId.rawValue.uuidString
        )
        _ = sendIpc(&model, method: Methods.tabTitle, params: .object(["title": .string("current")]), context: stale)

        let currentTab = tabForPane(paneId, in: model)
        try expectEqual(currentTab?.id, targetTabId)
        try expectEqual(currentTab?.customTitle, "current")
    }

    test("pane.split targets context pane even when another tab is selected") {
        var model = makeModel()
        createTab(&model)
        let backgroundTabId = selectedTab(in: model)!.id
        let backgroundPaneId = selectedTab(in: model)!.focusedPaneId
        createTab(&model)
        let foregroundTabId = selectedTab(in: model)!.id

        let effects = sendIpc(
            &model,
            method: Methods.paneSplit,
            params: .object(["direction": .string("horizontal")]),
            context: IpcRequestContext(paneId: backgroundPaneId.rawValue.uuidString)
        )

        try expectEqual(model.selectedTabId, foregroundTabId)
        try expectEqual(allPaneIds(tabById(backgroundTabId, in: model)!.rootNode).count, 2)
        try expect(hasEffect(effects) { if case .ipcReply = $0 { return true }; return false })
    }

    test("pane.focus selects target tab and requests first responder") {
        var model = makeModel()
        createTab(&model)
        let targetTabId = selectedTab(in: model)!.id
        let targetPaneId = selectedTab(in: model)!.focusedPaneId
        createTab(&model)

        let effects = sendIpc(
            &model,
            method: Methods.paneFocus,
            params: .object(["paneId": .string(targetPaneId.rawValue.uuidString)])
        )

        try expectEqual(model.selectedTabId, targetTabId)
        try expect(hasEffect(effects) {
            if case .makeFirstResponder(let paneId) = $0 { return paneId == targetPaneId }
            return false
        }, "expected focus effect")
    }

    test("new-tab with group creates tab in named group") {
        var model = makeModel()
        createTab(&model)
        let effects = sendIpc(&model, method: Methods.newTab, params: .object(["group": .string("Builds")]))
        let group = model.groups.first(where: { $0.name == "Builds" })
        try expectEqual(group?.tabs.count, 1)
        try expect(try requireIpcReply(effects)["tabId"]?.asString != nil, "reply should include tab id")
    }

    test("new-tab with duplicate group names targets first matching group") {
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .createGroup(name: "Builds"))
        _ = update(&model, .createGroup(name: "Builds"))

        let buildGroups = model.groups.filter { $0.name == "Builds" }
        try expectEqual(buildGroups.count, 2)
        let firstGroupId = buildGroups[0].id
        let secondGroupId = buildGroups[1].id
        let firstCountBefore = buildGroups[0].tabs.count
        let secondCountBefore = buildGroups[1].tabs.count

        let effects = sendIpc(&model, method: Methods.newTab, params: .object(["group": .string("Builds")]))

        let firstGroup = model.groups.first(where: { $0.id == firstGroupId })
        let secondGroup = model.groups.first(where: { $0.id == secondGroupId })
        try expectEqual(firstGroup?.tabs.count, firstCountBefore + 1)
        try expectEqual(secondGroup?.tabs.count, secondCountBefore)
        try expect(try requireIpcReply(effects)["tabId"]?.asString != nil, "reply should include tab id")
    }

    test("theme.set updates pane override and clears with null") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let ctx = IpcRequestContext(paneId: paneId.rawValue.uuidString)

        _ = sendIpc(&model, method: Methods.themeSet, params: .object(["themeName": .string("Tokyo Night")]), context: ctx)
        try expectEqual(model.panes[paneId]?.theme, "Tokyo Night")

        _ = sendIpc(&model, method: Methods.themeSet, params: .object(["themeName": .null]), context: ctx)
        try expectEqual(model.panes[paneId]?.theme, nil)
    }

    test("todo list add edit done open delete clear-completed use context pane") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let ctx = IpcRequestContext(paneId: paneId.rawValue.uuidString)

        let addEffects = sendIpc(
            &model,
            method: Methods.todoAdd,
            params: .object(["text": .string(" ship cli ")]),
            context: ctx
        )
        let added = try requireIpcReply(addEffects)
        let todoId = try requireString(added["id"], "todo add should return id")
        try expectEqual(model.panes[paneId]?.todos.first?.text, "ship cli")
        try expect(hasEffect(addEffects) { if case .refreshPaneToolbar(let pid) = $0 { return pid == paneId }; return false })

        _ = sendIpc(&model, method: Methods.todoEdit, params: .object(["todoId": .string(todoId), "text": .string("ship cli v2")]), context: ctx)
        try expectEqual(model.panes[paneId]?.todos.first?.text, "ship cli v2")

        _ = sendIpc(&model, method: Methods.todoDone, params: .object(["todoId": .string(todoId)]), context: ctx)
        try expectEqual(model.panes[paneId]?.todos.first?.isDone, true)

        _ = sendIpc(&model, method: Methods.todoOpen, params: .object(["todoId": .string(todoId)]), context: ctx)
        try expectEqual(model.panes[paneId]?.todos.first?.isDone, false)

        let list = try requireIpcReply(sendIpc(&model, method: Methods.todoList, context: ctx))
        try expectEqual(list.asArray?.count, 1)

        _ = sendIpc(&model, method: Methods.todoDelete, params: .object(["todoId": .string(todoId)]), context: ctx)
        try expectEqual(model.panes[paneId]?.todos.count, 0)

        let secondAdd = try requireIpcReply(sendIpc(
            &model,
            method: Methods.todoAdd,
            params: .object(["text": .string("done later")]),
            context: ctx
        ))
        let secondTodoId = try requireString(secondAdd["id"], "todo add should return second id")
        _ = sendIpc(&model, method: Methods.todoDone, params: .object(["todoId": .string(secondTodoId)]), context: ctx)
        _ = sendIpc(&model, method: Methods.todoDone, params: .object(["todoId": .string(todoId)]), context: ctx)
        _ = sendIpc(&model, method: Methods.todoClearCompleted, context: ctx)
        try expectEqual(model.panes[paneId]?.todos.count, 0)
    }

    test("todo delete rejects unknown id") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.todoDelete,
            params: .object(["todoId": .string(UUID().uuidString)]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
    }

    test("send-keys emits text effect for context pane") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.sendKeys,
            params: .object(["text": .string("echo hi")]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )
        try expect(hasEffect(effects) {
            if case .sendText(let pid, let text) = $0 { return pid == paneId && text == "echo hi" }
            return false
        }, "expected sendText effect")
    }
}

private struct IpcErrorResult: Equatable {
    let code: Int
    let message: String
}

private func sendIpc(
    _ model: inout AppModel,
    method: String,
    params: JSONValue = .object([:]),
    context: IpcRequestContext = IpcRequestContext()
) -> [Effect] {
    update(&model, .ipcRequest(reqId: UUID(), method: method, params: params, context: context))
}

private func contextForSelectedPane(in model: AppModel) -> IpcRequestContext {
    let tab = selectedTab(in: model)!
    return IpcRequestContext(
        paneId: tab.focusedPaneId.rawValue.uuidString,
        tabId: tab.id.rawValue.uuidString
    )
}

private func requireIpcReply(_ effects: [Effect]) throws -> JSONValue {
    for effect in effects {
        if case .ipcReply(_, let result) = effect {
            return result
        }
    }
    throw TestFailure(message: "expected ipcReply")
}

private func requireIpcError(_ effects: [Effect]) throws -> IpcErrorResult {
    for effect in effects {
        if case .ipcError(_, let code, let message) = effect {
            return IpcErrorResult(code: code, message: message)
        }
    }
    throw TestFailure(message: "expected ipcError")
}

private func requireString(_ value: JSONValue?, _ message: String) throws -> String {
    guard let string = value?.asString else {
        throw TestFailure(message: message)
    }
    return string
}
