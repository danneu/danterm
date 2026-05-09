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
        let beforePaneIds = Set(model.panes.keys)

        let effects = sendIpc(
            &model,
            method: Methods.paneSplit,
            params: .object(["direction": .string("horizontal")]),
            context: IpcRequestContext(paneId: backgroundPaneId.rawValue.uuidString)
        )

        try expectEqual(model.selectedTabId, foregroundTabId)
        try expectEqual(allPaneIds(tabById(backgroundTabId, in: model)!.rootNode).count, 2)
        let reply = try requireIpcReply(effects)
        let returnedPaneId = try requirePaneId(reply["paneId"], "pane.split should return the new pane id")
        try expect(!beforePaneIds.contains(returnedPaneId), "returned pane id should be new")
        try expectEqual(Set(model.panes.keys).subtracting(beforePaneIds), Set([returnedPaneId]))
    }

    test("pane.split explicit pane targets sibling instead of caller context") {
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let callerPaneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .splitPane(paneId: callerPaneId, direction: .horizontal))
        let siblingPaneId = selectedTab(in: model)!.focusedPaneId
        let beforePaneIds = Set(model.panes.keys)

        let effects = sendIpc(
            &model,
            method: Methods.paneSplit,
            params: .object([
                "pane": .string(siblingPaneId.rawValue.uuidString),
                "direction": .string("vertical"),
            ]),
            context: IpcRequestContext(paneId: callerPaneId.rawValue.uuidString)
        )

        let reply = try requireIpcReply(effects)
        let returnedPaneId = try requirePaneId(reply["paneId"], "pane.split should return the sibling split pane id")
        try expect(!beforePaneIds.contains(returnedPaneId), "returned pane id should be new")
        try expectEqual(Set(model.panes.keys).subtracting(beforePaneIds), Set([returnedPaneId]))
        guard case .split(_, .horizontal, .leaf(let first), .split(_, .vertical, .leaf(let second), .leaf(let third), _), _) =
            tabById(tabId, in: model)!.rootNode
        else {
            throw TestFailure(message: "expected explicit sibling pane to be split")
        }
        try expectEqual(first, callerPaneId)
        try expectEqual(second, siblingPaneId)
        try expectEqual(third, returnedPaneId)
    }

    test("pane.split malformed explicit pane does not fall back to context") {
        var model = makeModel()
        createTab(&model)
        let callerPaneId = selectedTab(in: model)!.focusedPaneId
        let beforePaneIds = Set(model.panes.keys)

        let effects = sendIpc(
            &model,
            method: Methods.paneSplit,
            params: .object([
                "pane": .string("not-a-uuid"),
                "direction": .string("horizontal"),
            ]),
            context: IpcRequestContext(paneId: callerPaneId.rawValue.uuidString)
        )

        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
        try expectEqual(Set(model.panes.keys), beforePaneIds)
    }

    test("pane.split non-string explicit pane does not fall back to context") {
        var model = makeModel()
        createTab(&model)
        let callerPaneId = selectedTab(in: model)!.focusedPaneId
        let beforePaneIds = Set(model.panes.keys)

        let effects = sendIpc(
            &model,
            method: Methods.paneSplit,
            params: .object([
                "pane": .number(42),
                "direction": .string("horizontal"),
            ]),
            context: IpcRequestContext(paneId: callerPaneId.rawValue.uuidString)
        )

        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
        try expect(error.message.contains("pane must be a string"),
                   "message should describe non-string pane, got: \(error.message)")
        try expectEqual(Set(model.panes.keys), beforePaneIds)
    }

    test("pane.split unknown explicit pane does not fall back to context") {
        var model = makeModel()
        createTab(&model)
        let callerPaneId = selectedTab(in: model)!.focusedPaneId
        let beforePaneIds = Set(model.panes.keys)

        let effects = sendIpc(
            &model,
            method: Methods.paneSplit,
            params: .object([
                "pane": .string(UUID().uuidString),
                "direction": .string("horizontal"),
            ]),
            context: IpcRequestContext(paneId: callerPaneId.rawValue.uuidString)
        )

        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
        try expectEqual(Set(model.panes.keys), beforePaneIds)
    }

    test("pane.split no-op target returns null pane id") {
        var model = makeModel()
        createTab(&model)
        let orphanPaneId = PaneId()
        model.panes[orphanPaneId] = PaneModel(id: orphanPaneId)
        let beforePaneIds = Set(model.panes.keys)

        let effects = sendIpc(
            &model,
            method: Methods.paneSplit,
            params: .object(["direction": .string("horizontal")]),
            context: IpcRequestContext(paneId: orphanPaneId.rawValue.uuidString)
        )

        let reply = try requireIpcReply(effects)
        try expectEqual(reply["paneId"], .null)
        try expectEqual(Set(model.panes.keys), beforePaneIds)
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

    test("send-keys input array emits ordered Effects via the key path") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.sendKeys,
            params: .object([
                "input": .array([
                    .object(["text": .string("ls")]),
                    .object(["key": .string("Enter")]),
                ])
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )
        // Three effects in order: sendInputText, sendInputKey, ipcReply.
        try expectEqual(effects.count, 3)
        guard case .sendInputText(let p0, let t0) = effects[0] else {
            throw TestFailure(message: "expected first effect = sendInputText")
        }
        try expectEqual(p0, paneId)
        try expectEqual(t0, "ls")
        guard case .sendInputKey(let p1, let key1, let mods1) = effects[1] else {
            throw TestFailure(message: "expected second effect = sendInputKey")
        }
        try expectEqual(p1, paneId)
        try expectEqual(key1, KeyName.named(.enter))
        try expectEqual(mods1, KeyMods())
        guard case .ipcReply = effects[2] else {
            throw TestFailure(message: "expected third effect = ipcReply")
        }
        try expect(!hasEffect(effects) {
            if case .sendText = $0 { return true }
            return false
        }, "input path must not emit .sendText")
    }

    test("send-keys explicit empty mods equals omitted mods") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.sendKeys,
            params: .object([
                "input": .array([
                    .object([
                        "key": .string("Enter"),
                        "mods": .array([]),
                    ])
                ])
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )
        try expect(hasEffect(effects) {
            if case .sendInputKey(let p, let k, let m) = $0 {
                return p == paneId && k == .named(.enter) && m == KeyMods()
            }
            return false
        }, "expected sendInputKey with empty mods")
    }

    test("send-keys non-array mods is invalid params") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.sendKeys,
            params: .object([
                "input": .array([
                    .object([
                        "key": .string("Enter"),
                        "mods": .string("ctrl"),
                    ])
                ])
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
        try expect(error.message.contains("mods must be an array"),
                   "message should describe non-array mods, got: \(error.message)")
    }

    test("send-keys key with ctrl mod emits sendInputKey") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.sendKeys,
            params: .object([
                "input": .array([
                    .object([
                        "key": .string("c"),
                        "mods": .array([.string("ctrl")]),
                    ])
                ])
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )
        try expect(hasEffect(effects) {
            if case .sendInputKey(let p, let k, let m) = $0 {
                return p == paneId && k == .letter("c") && m == [.ctrl]
            }
            return false
        }, "expected sendInputKey for C-c")
    }

    test("send-keys with both text and input is invalid params") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.sendKeys,
            params: .object([
                "text": .string("hi"),
                "input": .array([.object(["text": .string("hi")])]),
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
    }

    test("send-keys with neither text nor input is invalid params") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.sendKeys,
            params: .object([:]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
    }

    test("send-keys input event missing both text and key is invalid params") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.sendKeys,
            params: .object([
                "input": .array([.object([:])])
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
    }

    test("send-keys input event with both text and key is invalid params") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.sendKeys,
            params: .object([
                "input": .array([
                    .object([
                        "text": .string("x"),
                        "key": .string("Enter"),
                    ])
                ])
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
    }

    // Load-bearing assertion: a wire-level "Bogus" key never makes it past the
    // IPC handler. No .sendInputKey is emitted; the response is an error.
    test("send-keys unknown key name is rejected before any Effect") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.sendKeys,
            params: .object([
                "input": .array([
                    .object(["key": .string("Bogus")])
                ])
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
        try expect(error.message.contains("unknown key Bogus"),
                   "message should mention unknown key Bogus, got: \(error.message)")
        try expect(!hasEffect(effects) {
            if case .sendInputKey = $0 { return true }
            return false
        }, "no .sendInputKey should be emitted")
    }

    test("send-keys non-string key value is invalid params") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.sendKeys,
            params: .object([
                "input": .array([
                    .object(["key": .number(5)])
                ])
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
    }

    test("send-keys unknown mod name is invalid params") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.sendKeys,
            params: .object([
                "input": .array([
                    .object([
                        "key": .string("Enter"),
                        "mods": .array([.string("bogus")]),
                    ])
                ])
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
        try expect(error.message.contains("unknown mod bogus"),
                   "message should mention unknown mod bogus, got: \(error.message)")
    }

    test("send-keys shift mod is rejected") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.sendKeys,
            params: .object([
                "input": .array([
                    .object([
                        "key": .string("Tab"),
                        "mods": .array([.string("shift")]),
                    ])
                ])
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
        try expect(error.message.contains("shift"),
                   "message should mention shift, got: \(error.message)")
    }

    test("send-keys explicit pane targets that pane regardless of context") {
        var model = makeModel()
        createTab(&model)
        let backgroundPaneId = selectedTab(in: model)!.focusedPaneId
        createTab(&model)
        let foregroundPaneId = selectedTab(in: model)!.focusedPaneId
        // Context says foreground; explicit pane param overrides to background.
        let effects = sendIpc(
            &model,
            method: Methods.sendKeys,
            params: .object([
                "pane": .string(backgroundPaneId.rawValue.uuidString),
                "input": .array([.object(["text": .string("hi")])]),
            ]),
            context: IpcRequestContext(paneId: foregroundPaneId.rawValue.uuidString)
        )
        try expect(hasEffect(effects) {
            if case .sendInputText(let p, let t) = $0 {
                return p == backgroundPaneId && t == "hi"
            }
            return false
        }, "expected effect targeting explicit pane")
    }

    test("send-keys explicit pane that doesn't exist returns pane not found") {
        var model = makeModel()
        createTab(&model)
        let realPaneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.sendKeys,
            params: .object([
                "pane": .string(UUID().uuidString),
                "input": .array([.object(["text": .string("hi")])]),
            ]),
            // Context pane exists, but explicit pane shouldn't fall back.
            context: IpcRequestContext(paneId: realPaneId.rawValue.uuidString)
        )
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
        try expect(error.message.contains("pane not found"),
                   "expected 'pane not found', got: \(error.message)")
        try expect(!hasEffect(effects) {
            if case .sendInputText = $0 { return true }
            return false
        }, "no input effect should be emitted")
    }

    test("send-keys non-string pane is invalid params and does not fall back") {
        var model = makeModel()
        createTab(&model)
        let realPaneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.sendKeys,
            params: .object([
                "pane": .number(5),
                "input": .array([.object(["text": .string("hi")])]),
            ]),
            context: IpcRequestContext(paneId: realPaneId.rawValue.uuidString)
        )
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
        try expect(error.message.contains("pane must be a string"),
                   "expected 'pane must be a string', got: \(error.message)")
    }

    test("send-keys with no pane in context and no explicit pane errors") {
        var model = makeModel()
        createTab(&model)
        let effects = sendIpc(
            &model,
            method: Methods.sendKeys,
            params: .object(["input": .array([.object(["text": .string("hi")])])]),
            context: IpcRequestContext()
        )
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
        try expect(error.message.contains("no pane in context"),
                   "expected 'no pane in context', got: \(error.message)")
    }

    test("read-pane emits viewport read effect without immediate reply") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.readPane,
            params: .object(["pane": .string(paneId.rawValue.uuidString)])
        )

        try expectEqual(effects.count, 1)
        guard case .readPaneText(_, let effectPaneId, let lineLimit) = effects[0] else {
            throw TestFailure(message: "expected readPaneText effect")
        }
        try expectEqual(effectPaneId, paneId)
        try expectEqual(lineLimit, nil)
        try expect(!hasEffect(effects) {
            if case .ipcReply = $0 { return true }
            return false
        }, "read-pane success should not emit an immediate ipcReply")
    }

    test("read-pane emits scrollback tail read effect with line limit") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.readPane,
            params: .object([
                "pane": .string(paneId.rawValue.uuidString),
                "lines": .number(200),
            ])
        )

        try expectEqual(effects.count, 1)
        guard case .readPaneText(_, let effectPaneId, let lineLimit) = effects[0] else {
            throw TestFailure(message: "expected readPaneText effect")
        }
        try expectEqual(effectPaneId, paneId)
        try expectEqual(lineLimit, 200)
    }

    test("read-pane missing pane param errors") {
        var model = makeModel()
        createTab(&model)
        let effects = sendIpc(&model, method: Methods.readPane, params: .object([:]))
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
        try expectEqual(error.message, "pane required")
    }

    test("read-pane non-string pane param errors") {
        for paneValue in [JSONValue.number(5), .array([]), .object([:])] {
            var model = makeModel()
            createTab(&model)
            let effects = sendIpc(
                &model,
                method: Methods.readPane,
                params: .object(["pane": paneValue])
            )
            let error = try requireIpcError(effects)
            try expectEqual(error.code, -32602)
            try expectEqual(error.message, "pane required")
        }
    }

    test("read-pane unknown pane errors") {
        for rawPane in ["bogus", UUID().uuidString] {
            var model = makeModel()
            createTab(&model)
            let effects = sendIpc(
                &model,
                method: Methods.readPane,
                params: .object(["pane": .string(rawPane)])
            )
            let error = try requireIpcError(effects)
            try expectEqual(error.code, -32602)
            try expectEqual(error.message, "pane not found")
        }
    }

    test("read-pane invalid line limits error") {
        let invalidValues: [JSONValue] = [.number(0), .number(-5), .string("5"), .number(1.5)]
        for linesValue in invalidValues {
            var model = makeModel()
            createTab(&model)
            let paneId = selectedTab(in: model)!.focusedPaneId
            let effects = sendIpc(
                &model,
                method: Methods.readPane,
                params: .object([
                    "pane": .string(paneId.rawValue.uuidString),
                    "lines": linesValue,
                ])
            )
            let error = try requireIpcError(effects)
            try expectEqual(error.code, -32602)
            try expectEqual(error.message, "lines must be a positive integer")
        }
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

private func requirePaneId(_ value: JSONValue?, _ message: String) throws -> PaneId {
    let raw = try requireString(value, message)
    guard let uuid = UUID(uuidString: raw) else {
        throw TestFailure(message: message)
    }
    return PaneId(rawValue: uuid)
}
