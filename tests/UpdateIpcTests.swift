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
        let effects = sendIpc(&model, method: Methods.tabRename, context: IpcRequestContext(paneId: "not-a-uuid"))
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

    test("pane.info explicit pane returns containing pane tab and group") {
        var model = makeModel()
        createTab(&model)
        let backgroundGroupId = model.groups[0].id
        let backgroundTabId = selectedTab(in: model)!.id
        let backgroundPaneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .createGroup(name: "Other"))
        let otherGroupId = model.groups.last!.id
        createTab(&model, inGroupId: otherGroupId)
        let contextPaneId = selectedTab(in: model)!.focusedPaneId

        let effects = sendIpc(
            &model,
            method: Methods.paneInfo,
            params: .object(["pane": .string(backgroundPaneId.rawValue.uuidString)]),
            context: IpcRequestContext(paneId: contextPaneId.rawValue.uuidString)
        )

        let reply = try requireIpcReply(effects)
        try expectEqual(reply["pane"]?["id"]?.asString, backgroundPaneId.rawValue.uuidString)
        try expectEqual(reply["tab"]?["id"]?.asString, backgroundTabId.rawValue.uuidString)
        try expectEqual(reply["tab"]?["groupId"]?.asString, backgroundGroupId.rawValue.uuidString)
        try expectEqual(reply["group"]?["id"]?.asString, backgroundGroupId.rawValue.uuidString)
        try expectEqual(reply["group"]?["name"]?.asString, "General")
    }

    test("pane.info implicit pane uses pane context") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let tabId = selectedTab(in: model)!.id

        let effects = sendIpc(
            &model,
            method: Methods.paneInfo,
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )

        let reply = try requireIpcReply(effects)
        try expectEqual(reply["pane"]?["id"]?.asString, paneId.rawValue.uuidString)
        try expectEqual(reply["tab"]?["id"]?.asString, tabId.rawValue.uuidString)
    }

    test("pane.info missing or invalid target fails without falling back") {
        var model = makeModel()
        createTab(&model)
        let contextPaneId = selectedTab(in: model)!.focusedPaneId

        let missing = sendIpc(&model, method: Methods.paneInfo, context: IpcRequestContext())
        try expectEqual(try requireIpcError(missing).code, -32602)

        let invalid = sendIpc(
            &model,
            method: Methods.paneInfo,
            params: .object(["pane": .string("not-a-uuid")]),
            context: IpcRequestContext(paneId: contextPaneId.rawValue.uuidString)
        )
        try expectEqual(try requireIpcError(invalid).code, -32602)

        let unknown = sendIpc(
            &model,
            method: Methods.paneInfo,
            params: .object(["pane": .string(UUID().uuidString)]),
            context: IpcRequestContext(paneId: contextPaneId.rawValue.uuidString)
        )
        try expectEqual(try requireIpcError(unknown).code, -32602)
    }

    test("tab.rename sets and clears custom title") {
        var model = makeModel()
        createTab(&model)
        let ctx = contextForSelectedPane(in: model)
        let tabId = selectedTab(in: model)!.id

        let setEffects = sendIpc(&model, method: Methods.tabRename, params: .object(["title": .string("hello")]), context: ctx)
        let setReply = try requireIpcReply(setEffects)
        try expectEqual(setReply["tab"]?["id"]?.asString, tabId.rawValue.uuidString)
        try expectEqual(setReply["tab"]?["customTitle"]?.asString, "hello")
        try expectEqual(tabById(tabId, in: model)?.customTitle, "hello")

        let clearEffects = sendIpc(&model, method: Methods.tabRename, params: .object(["title": .null]), context: ctx)
        let clearReply = try requireIpcReply(clearEffects)
        try expectEqual(clearReply["tab"]?["customTitle"], .null)
        try expectEqual(tabById(tabId, in: model)?.customTitle, nil)
    }

    test("tab.rename derives live tab from pane context when pane moved") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .splitPane(direction: .horizontal))
        createTab(&model)
        let targetTabId = selectedTab(in: model)!.id
        _ = update(&model, .movePaneToTab(paneId: paneId, targetTabId: targetTabId))

        _ = sendIpc(
            &model,
            method: Methods.tabRename,
            params: .object(["title": .string("current")]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )

        let currentTab = tabForPane(paneId, in: model)
        try expectEqual(currentTab?.id, targetTabId)
        try expectEqual(currentTab?.customTitle, "current")
    }

    test("tab.rename explicit tab targets that tab regardless of selection and context") {
        var model = makeModel()
        createTab(&model)
        let backgroundTabId = selectedTab(in: model)!.id
        let backgroundPaneId = selectedTab(in: model)!.focusedPaneId
        createTab(&model)
        let foregroundTabId = selectedTab(in: model)!.id
        let foregroundPaneId = selectedTab(in: model)!.focusedPaneId

        let effects = sendIpc(
            &model,
            method: Methods.tabRename,
            params: .object([
                "tab": .string(backgroundTabId.rawValue.uuidString),
                "title": .string("build"),
            ]),
            context: IpcRequestContext(paneId: foregroundPaneId.rawValue.uuidString)
        )

        let reply = try requireIpcReply(effects)
        try expectEqual(reply["tab"]?["id"]?.asString, backgroundTabId.rawValue.uuidString)
        try expectEqual(tabById(backgroundTabId, in: model)?.customTitle, "build")
        try expectEqual(tabById(foregroundTabId, in: model)?.customTitle, nil)
        try expectEqual(tabForPane(backgroundPaneId, in: model)?.id, backgroundTabId)
    }

    test("tab.rename malformed or unknown explicit tab does not fall back to context") {
        for tabValue in [JSONValue.string("not-a-uuid"), .string(UUID().uuidString), .number(7)] {
            var model = makeModel()
            createTab(&model)
            let contextTabId = selectedTab(in: model)!.id
            let contextPaneId = selectedTab(in: model)!.focusedPaneId

            let effects = sendIpc(
                &model,
                method: Methods.tabRename,
                params: .object([
                    "tab": tabValue,
                    "title": .string("should-not-apply"),
                ]),
                context: IpcRequestContext(paneId: contextPaneId.rawValue.uuidString)
            )

            let error = try requireIpcError(effects)
            try expectEqual(error.code, -32602)
            try expectEqual(tabById(contextTabId, in: model)?.customTitle, nil)
        }
    }

    test("tab.rename without explicit tab and without pane context fails before mutation") {
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let effects = sendIpc(
            &model,
            method: Methods.tabRename,
            params: .object(["title": .string("missing-context")]),
            context: IpcRequestContext()
        )

        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
        try expectEqual(tabById(tabId, in: model)?.customTitle, nil)
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
        let returnedPaneId = try requirePaneId(reply["pane"]?["id"], "pane.split should return the new pane id")
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
        let returnedPaneId = try requirePaneId(reply["pane"]?["id"], "pane.split should return the sibling split pane id")
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

    test("pane.split without explicit pane and without pane context fails before mutation") {
        var model = makeModel()
        createTab(&model)
        let beforePaneIds = Set(model.panes.keys)

        let effects = sendIpc(
            &model,
            method: Methods.paneSplit,
            params: .object(["direction": .string("horizontal")]),
            context: IpcRequestContext()
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
        try expectEqual(reply["pane"], .null)
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
        let reply = try requireIpcReply(effects)
        try expectEqual(reply["tab"]?["id"]?.asString, targetTabId.rawValue.uuidString)
        try expectEqual(reply["tab"]?["focusedPaneId"]?.asString, targetPaneId.rawValue.uuidString)
        try expect(hasEffect(effects) {
            if case .makeFirstResponder(let paneId) = $0 { return paneId == targetPaneId }
            return false
        }, "expected focus effect")
    }

    test("pane.focus replies with same-tab focusedPaneId synchronously") {
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let firstPaneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let secondPaneId = selectedTab(in: model)!.focusedPaneId
        updateTabForTest(tabId, in: &model) { $0.focusedPaneId = firstPaneId }

        let effects = sendIpc(
            &model,
            method: Methods.paneFocus,
            params: .object(["paneId": .string(secondPaneId.rawValue.uuidString)])
        )

        let reply = try requireIpcReply(effects)
        try expectEqual(reply["tab"]?["focusedPaneId"]?.asString, secondPaneId.rawValue.uuidString)
        try expectEqual(tabById(tabId, in: model)?.focusedPaneId, secondPaneId)
    }

    test("pane.focus clears target pane alerts in focus mode") {
        var model = makeModel()
        model.config.alertClearMode = .focus
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let firstPaneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let secondPaneId = selectedTab(in: model)!.focusedPaneId
        updateTabForTest(tabId, in: &model) { $0.focusedPaneId = firstPaneId }
        model.alerts.insert(AlertModel(
            id: AlertId(),
            kind: .bell,
            paneId: secondPaneId,
            title: "DanTerm",
            body: "test",
            createdAt: Date(),
            isUnread: true
        ), at: 0)

        _ = sendIpc(
            &model,
            method: Methods.paneFocus,
            params: .object(["paneId": .string(secondPaneId.rawValue.uuidString)])
        )

        try expectEqual(model.alerts[0].isUnread, false, "focusing pane should mark its alerts read")
    }

    test("tab.new explicit group id creates tab in that group") {
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .createGroup(name: "Builds"))
        let groupId = model.groups.last!.id
        let countBefore = model.groups.last!.tabs.count
        let effects = sendIpc(
            &model,
            method: Methods.tabNew,
            params: .object(["group": .string(groupId.rawValue.uuidString)])
        )
        let group = model.groups.first(where: { $0.id == groupId })
        try expectEqual(group?.tabs.count, countBefore + 1)
        let reply = try requireIpcReply(effects)
        try expect(reply["tab"]?["id"]?.asString != nil, "reply should include tab id")
        try expectEqual(reply["group"]?["id"]?.asString, groupId.rawValue.uuidString)
        try expectEqual(reply["group"]?["name"]?.asString, "Builds")
        try expectEqual(reply["panes"]?.asArray?.count, 1)
    }

    test("tab.new explicit group id wins over pane context group") {
        var model = makeModel()
        createTab(&model)
        let callerGroupId = model.groups[0].id
        let callerPaneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .createGroup(name: "Builds"))
        let explicitGroupId = model.groups.last!.id
        let callerCountBefore = model.groups.first(where: { $0.id == callerGroupId })!.tabs.count
        let explicitCountBefore = model.groups.first(where: { $0.id == explicitGroupId })!.tabs.count

        let effects = sendIpc(
            &model,
            method: Methods.tabNew,
            params: .object(["group": .string(explicitGroupId.rawValue.uuidString)]),
            context: IpcRequestContext(paneId: callerPaneId.rawValue.uuidString)
        )

        try expectEqual(model.groups.first(where: { $0.id == callerGroupId })?.tabs.count, callerCountBefore)
        try expectEqual(model.groups.first(where: { $0.id == explicitGroupId })?.tabs.count, explicitCountBefore + 1)
        try expectEqual(try requireIpcReply(effects)["group"]?["id"]?.asString, explicitGroupId.rawValue.uuidString)
    }

    test("tab.new malformed or unknown explicit group does not fall back or create") {
        for groupValue in [JSONValue.string("not-a-uuid"), .string(UUID().uuidString), .number(7)] {
            var model = makeModel()
            createTab(&model)
            let contextPaneId = selectedTab(in: model)!.focusedPaneId
            let groupsBefore = model.groups.count
            let tabsBefore = model.groups.flatMap(\.tabs).count

            let effects = sendIpc(
                &model,
                method: Methods.tabNew,
                params: .object(["group": groupValue]),
                context: IpcRequestContext(paneId: contextPaneId.rawValue.uuidString)
            )

            let error = try requireIpcError(effects)
            try expectEqual(error.code, -32602)
            try expectEqual(model.groups.count, groupsBefore)
            try expectEqual(model.groups.flatMap(\.tabs).count, tabsBefore)
        }
    }

    test("tab.new without explicit group uses pane context group") {
        var model = makeModel()
        createTab(&model)
        let callerGroupId = model.groups[0].id
        let callerPaneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .createGroup(name: "Other"))

        let effects = sendIpc(
            &model,
            method: Methods.tabNew,
            params: .object([:]),
            context: IpcRequestContext(paneId: callerPaneId.rawValue.uuidString)
        )

        try expectEqual(model.groups.first(where: { $0.id == callerGroupId })?.tabs.count, 2)
        try expectEqual(try requireIpcReply(effects)["group"]?["id"]?.asString, callerGroupId.rawValue.uuidString)
    }

    test("tab.new without explicit group and without pane context fails before mutation") {
        var model = makeModel()
        createTab(&model)
        let tabsBefore = model.groups.flatMap(\.tabs).count
        let effects = sendIpc(&model, method: Methods.tabNew, params: .object([:]), context: IpcRequestContext())
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
        try expectEqual(model.groups.flatMap(\.tabs).count, tabsBefore)
    }

    test("tab.new background does not steal selection") {
        var model = makeModel()
        createTab(&model)
        let selectedTabId = selectedTab(in: model)!.id
        let groupId = model.groups[0].id

        let effects = sendIpc(
            &model,
            method: Methods.tabNew,
            params: .object([
                "group": .string(groupId.rawValue.uuidString),
                "background": .bool(true),
            ])
        )

        try expectEqual(model.selectedTabId, selectedTabId, "background tab.new should not change selected tab")
        let reply = try requireIpcReply(effects)
        try expect(reply["tab"]?["id"]?.asString != nil, "reply should include new tab id")
        try expectEqual(reply["group"]?["id"]?.asString, groupId.rawValue.uuidString)
    }

    test("tab.new with malformed background fails before mutation") {
        var model = makeModel()
        createTab(&model)
        let groupId = model.groups[0].id
        let paneIdsBefore = Set(model.panes.keys)
        let tabsBefore = model.groups.flatMap(\.tabs).map(\.id)

        let effects = sendIpc(
            &model,
            method: Methods.tabNew,
            params: .object([
                "group": .string(groupId.rawValue.uuidString),
                "background": .string("true"),
            ])
        )

        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
        try expectEqual(Set(model.panes.keys), paneIdsBefore)
        try expectEqual(model.groups.flatMap(\.tabs).map(\.id), tabsBefore)
    }

    test("tab.new inherits cwd from caller pane, not selected tab") {
        for background in [true, false] {
            var model = makeModel()
            createTab(&model)
            let selectedTabId = selectedTab(in: model)!.id
            let selectedPaneId = selectedTab(in: model)!.focusedPaneId
            model.panes[selectedPaneId]?.cwd = "/selected"
            createTab(&model)
            let callerPaneId = selectedTab(in: model)!.focusedPaneId
            model.panes[callerPaneId]?.cwd = "/caller"
            _ = update(&model, .selectTab(id: selectedTabId))

            let effects = sendIpc(
                &model,
                method: Methods.tabNew,
                params: .object(["background": .bool(background)]),
                context: IpcRequestContext(paneId: callerPaneId.rawValue.uuidString)
            )

            let reply = try requireIpcReply(effects)
            let paneId = try requirePaneId(reply["panes"]?.asArray?.first?["id"], "tab.new should return pane id")
            try expect(hasEffect(effects) {
                if case .createSurface(let effectPaneId, let cwd, _, _, _) = $0 {
                    return effectPaneId == paneId && cwd == "/caller"
                }
                return false
            }, "tab.new should inherit cwd from caller pane")
        }
    }

    test("tab.new with launch creates direct-launch surface and custom tab title") {
        var model = makeModel()
        createTab(&model)
        let paneIdInContext = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.tabNew,
            params: .object([
                "launch": .object([
                    "cmd": .string("date"),
                    "cwd": .string("/tmp"),
                    "title": .string("clock"),
                ])
            ]),
            context: IpcRequestContext(paneId: paneIdInContext.rawValue.uuidString)
        )

        let reply = try requireIpcReply(effects)
        let tabId = try requireTabId(reply["tab"]?["id"], "tab.new should return tab id")
        let paneId = try requirePaneId(reply["panes"]?.asArray?.first?["id"], "tab.new should return pane id")
        try expectEqual(reply["tab"]?["focusedPaneId"]?.asString, paneId.rawValue.uuidString)
        try expectEqual(reply["tab"]?["rootNode"]?["paneId"]?.asString, paneId.rawValue.uuidString)
        try expectEqual(reply["panes"]?.asArray?.first?.asObject?.keys.count, 1)
        try expectEqual(tabById(tabId, in: model)?.customTitle, "clock")
        try expectEqual(tabById(tabId, in: model)?.displayTitle, "clock")
        try expectEqual(model.panes[paneId]?.title, "clock")
        try expect(hasEffect(effects) {
            if case .createSurface(let effectPaneId, let cwd, let command, let launchCommand, let waitAfterCommand) = $0 {
                return effectPaneId == paneId
                    && cwd == "/tmp"
                    && command == nil
                    && launchCommand == "date"
                    && waitAfterCommand
            }
            return false
        }, "expected createSurface with direct launch command")
    }

    test("tab.new with explicit group id forwards launch to created tab") {
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .createGroup(name: "Builds"))
        let groupId = model.groups.last!.id

        let effects = sendIpc(
            &model,
            method: Methods.tabNew,
            params: .object([
                "group": .string(groupId.rawValue.uuidString),
                "launch": .object(["cmd": .string("make test")]),
            ])
        )

        let group = model.groups.first(where: { $0.id == groupId })
        let paneId = group?.tabs.last?.focusedPaneId
        try expect(paneId != nil, "target group should have a new tab")
        try expect(hasEffect(effects) {
            if case .createSurface(let effectPaneId, _, let command, let launchCommand, _) = $0 {
                return effectPaneId == paneId && command == nil && launchCommand == "make test"
            }
            return false
        }, "expected launch command to reach group-created tab")
    }

    test("tab.new afterTab without group uses referenced tab group without pane context") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let refTabId = model.groups[0].tabs[0].id
        let targetGroupId = model.groups[0].id
        _ = update(&model, .createGroup(name: "Other"))
        let beforeGroupTabs = groupTabIds(in: model)
        let panesBefore = Set(model.panes.keys)

        let effects = sendIpc(
            &model,
            method: Methods.tabNew,
            params: .object([
                "position": .string("afterTab"),
                "afterTabId": .string(refTabId.rawValue.uuidString),
            ])
        )

        let reply = try requireIpcReply(effects)
        try expectAfterTabInserted(
            reply: reply,
            in: model,
            targetGroupId: targetGroupId,
            refTabId: refTabId,
            beforeGroupTabs: beforeGroupTabs,
            panesBefore: panesBefore
        )
    }

    test("tab.new afterTab with matching group succeeds") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let refTabId = model.groups[0].tabs[0].id
        let targetGroupId = model.groups[0].id
        let beforeGroupTabs = groupTabIds(in: model)
        let panesBefore = Set(model.panes.keys)

        let effects = sendIpc(
            &model,
            method: Methods.tabNew,
            params: .object([
                "group": .string(targetGroupId.rawValue.uuidString),
                "position": .string("afterTab"),
                "afterTabId": .string(refTabId.rawValue.uuidString),
            ])
        )

        let reply = try requireIpcReply(effects)
        try expectAfterTabInserted(
            reply: reply,
            in: model,
            targetGroupId: targetGroupId,
            refTabId: refTabId,
            beforeGroupTabs: beforeGroupTabs,
            panesBefore: panesBefore
        )
    }

    test("tab.new afterTab with different explicit group fails before mutation") {
        var model = makeModel()
        createTab(&model)
        let refTabId = model.groups[0].tabs[0].id
        _ = update(&model, .createGroup(name: "Other"))
        let otherGroupId = model.groups[1].id
        let before = model

        let effects = sendIpc(
            &model,
            method: Methods.tabNew,
            params: .object([
                "group": .string(otherGroupId.rawValue.uuidString),
                "position": .string("afterTab"),
                "afterTabId": .string(refTabId.rawValue.uuidString),
            ])
        )

        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
        try expectEqual(model, before)
    }

    test("tab.new afterTab invalid params fail before mutation") {
        let invalidCases: [[String: JSONValue]] = [
            [
                "position": .string("afterTab"),
                "afterTabId": .string(UUID().uuidString),
            ],
            [
                "position": .string("afterTab"),
            ],
            [
                "position": .string("afterTab"),
                "afterTabId": .number(7),
            ],
            [
                "position": .string("afterTab"),
                "afterTabId": .string("not-a-uuid"),
            ],
            [
                "afterTabId": .string(UUID().uuidString),
            ],
            [
                "position": .number(7),
            ],
            [
                "position": .string("middle"),
            ],
            [
                "position": .string("afterSelected"),
                "afterTabId": .string(UUID().uuidString),
            ],
        ]

        for params in invalidCases {
            var model = makeModel()
            createTab(&model)
            let before = model

            let effects = sendIpc(&model, method: Methods.tabNew, params: .object(params))

            let error = try requireIpcError(effects)
            try expectEqual(error.code, -32602)
            try expectEqual(model, before)
        }
    }

    test("pane.split with launch title sets pane title without tab custom title") {
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let paneId = selectedTab(in: model)!.focusedPaneId

        let effects = sendIpc(
            &model,
            method: Methods.paneSplit,
            params: .object([
                "direction": .string("horizontal"),
                "launch": .object([
                    "cmd": .string("cargo --version"),
                    "cwd": .string("/tmp"),
                    "title": .string("cargo"),
                ]),
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )

        let newPaneId = try requirePaneId(try requireIpcReply(effects)["pane"]?["id"], "pane.split should return pane id")
        try expectEqual(model.panes[newPaneId]?.title, "cargo")
        try expectEqual(tabById(tabId, in: model)?.customTitle, nil)
        try expect(hasEffect(effects) {
            if case .createSurface(let effectPaneId, let cwd, let command, let launchCommand, _) = $0 {
                return effectPaneId == newPaneId
                    && cwd == "/tmp"
                    && command == nil
                    && launchCommand == "cargo --version"
            }
            return false
        }, "expected split createSurface to use direct launch")
    }

    test("pane.split background on selected tab preserves focused pane") {
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let focusedPaneId = selectedTab(in: model)!.focusedPaneId

        let effects = sendIpc(
            &model,
            method: Methods.paneSplit,
            params: .object([
                "direction": .string("horizontal"),
                "background": .bool(true),
            ]),
            context: IpcRequestContext(paneId: focusedPaneId.rawValue.uuidString)
        )

        let reply = try requireIpcReply(effects)
        let newPaneId = try requirePaneId(reply["pane"]?["id"], "pane.split should return pane id")
        let tab = tabById(tabId, in: model)!
        try expect(allPaneIds(tab.rootNode).contains(newPaneId), "target tab should contain new pane")
        try expectEqual(tab.focusedPaneId, focusedPaneId, "background split should preserve focused pane")
        try expectEqual(model.selectedTabId, tabId, "background split should not change selected tab")
        try expect(hasEffect(effects) {
            if case .rebuildTabContainer(let effectTabId) = $0, effectTabId == tabId { return true }
            return false
        }, "selected-tab background split should rebuild tab container")
    }

    test("pane.split background on unselected tab emits scoped rebuild") {
        var model = makeModel()
        createTab(&model)
        let selectedTabId = selectedTab(in: model)!.id
        createTab(&model)
        let backgroundTabId = selectedTab(in: model)!.id
        let backgroundPaneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .selectTab(id: selectedTabId))

        let effects = sendIpc(
            &model,
            method: Methods.paneSplit,
            params: .object([
                "direction": .string("horizontal"),
                "background": .bool(true),
            ]),
            context: IpcRequestContext(paneId: backgroundPaneId.rawValue.uuidString)
        )

        let reply = try requireIpcReply(effects)
        let newPaneId = try requirePaneId(reply["pane"]?["id"], "pane.split should return pane id")
        let backgroundTab = tabById(backgroundTabId, in: model)!
        try expect(allPaneIds(backgroundTab.rootNode).contains(newPaneId), "background tab should contain new pane")
        try expectEqual(backgroundTab.focusedPaneId, backgroundPaneId, "background split should preserve target focus")
        try expectEqual(model.selectedTabId, selectedTabId, "background split should not change selected tab")
        try expect(hasEffect(effects) {
            if case .rebuildTabContainer(let effectTabId) = $0, effectTabId == backgroundTabId { return true }
            return false
        }, "unselected-tab background split should emit scoped rebuild")
    }

    test("pane.split with malformed background fails before mutation") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let paneIdsBefore = Set(model.panes.keys)

        let effects = sendIpc(
            &model,
            method: Methods.paneSplit,
            params: .object([
                "direction": .string("horizontal"),
                "background": .string("true"),
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )

        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
        try expectEqual(Set(model.panes.keys), paneIdsBefore)
    }

    test("malformed launch returns invalid params without mutation effects") {
        let launchValues: [JSONValue] = [
            .string("bad"),
            .object(["cmd": .number(42)]),
        ]
        for launchValue in launchValues {
            var model = makeModel()
            createTab(&model)
            let contextPaneId = selectedTab(in: model)!.focusedPaneId
            let paneIdsBefore = Set(model.panes.keys)
            let tabEffects = sendIpc(
                &model,
                method: Methods.tabNew,
                params: .object(["launch": launchValue])
            )
            try expectEqual(try requireIpcError(tabEffects).code, -32602)
            try expectEqual(Set(model.panes.keys), paneIdsBefore)
            try expect(!hasEffect(tabEffects) {
                if case .createSurface = $0 { return true }
                return false
            }, "malformed tab.new launch should not create a surface")

            let splitEffects = sendIpc(
                &model,
                method: Methods.paneSplit,
                params: .object([
                    "direction": .string("horizontal"),
                    "launch": launchValue,
                ]),
                context: IpcRequestContext(paneId: contextPaneId.rawValue.uuidString)
            )
            try expectEqual(try requireIpcError(splitEffects).code, -32602)
            try expectEqual(Set(model.panes.keys), paneIdsBefore)
            try expect(!hasEffect(splitEffects) {
                if case .createSurface = $0 { return true }
                return false
            }, "malformed pane.split launch should not create a surface")
        }
    }

    test("theme.set updates pane override and clears with null") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let ctx = IpcRequestContext(paneId: paneId.rawValue.uuidString)

        let setEffects = sendIpc(&model, method: Methods.themeSet, params: .object(["themeName": .string("Tokyo Night")]), context: ctx)
        try expectEqual(model.panes[paneId]?.theme, "Tokyo Night")
        try expectEqual(try requireIpcReply(setEffects)["pane"]?["theme"]?.asString, "Tokyo Night")

        let clearEffects = sendIpc(&model, method: Methods.themeSet, params: .object(["themeName": .null]), context: ctx)
        try expectEqual(model.panes[paneId]?.theme, nil)
        try expectEqual(try requireIpcReply(clearEffects)["pane"]?["theme"], .null)
    }

    test("theme.set explicit pane targets that pane regardless of context") {
        var model = makeModel()
        createTab(&model)
        let targetPaneId = selectedTab(in: model)!.focusedPaneId
        createTab(&model)
        let contextPaneId = selectedTab(in: model)!.focusedPaneId

        let effects = sendIpc(
            &model,
            method: Methods.themeSet,
            params: .object([
                "pane": .string(targetPaneId.rawValue.uuidString),
                "themeName": .string("Tokyo Night"),
            ]),
            context: IpcRequestContext(paneId: contextPaneId.rawValue.uuidString)
        )

        try expectEqual(model.panes[targetPaneId]?.theme, "Tokyo Night")
        try expectEqual(model.panes[contextPaneId]?.theme, nil)
        try expectEqual(try requireIpcReply(effects)["pane"]?["id"]?.asString, targetPaneId.rawValue.uuidString)
    }

    test("theme.set malformed or unknown explicit pane does not fall back to context") {
        for paneValue in [JSONValue.string("not-a-uuid"), .string(UUID().uuidString), .number(7)] {
            var model = makeModel()
            createTab(&model)
            let contextPaneId = selectedTab(in: model)!.focusedPaneId

            let effects = sendIpc(
                &model,
                method: Methods.themeSet,
                params: .object([
                    "pane": paneValue,
                    "themeName": .string("Tokyo Night"),
                ]),
                context: IpcRequestContext(paneId: contextPaneId.rawValue.uuidString)
            )

            let error = try requireIpcError(effects)
            try expectEqual(error.code, -32602)
            try expectEqual(model.panes[contextPaneId]?.theme, nil)
        }
    }

    test("theme.set without explicit pane and without pane context fails before mutation") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.themeSet,
            params: .object(["themeName": .string("Tokyo Night")]),
            context: IpcRequestContext()
        )

        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
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
        let todoId = try requireString(added["todo"]?["id"], "todo add should return id")
        try expectEqual(model.panes[paneId]?.todos.first?.text, "ship cli")
        try expect(hasEffect(addEffects) { if case .refreshPaneToolbar(let pid) = $0 { return pid == paneId }; return false })

        let editReply = try requireIpcReply(sendIpc(&model, method: Methods.todoEdit, params: .object(["todoId": .string(todoId), "text": .string("ship cli v2")]), context: ctx))
        try expectEqual(model.panes[paneId]?.todos.first?.text, "ship cli v2")
        try expectEqual(editReply["todo"]?["text"]?.asString, "ship cli v2")

        let doneReply = try requireIpcReply(sendIpc(&model, method: Methods.todoDone, params: .object(["todoId": .string(todoId)]), context: ctx))
        try expectEqual(model.panes[paneId]?.todos.first?.isDone, true)
        try expectEqual(doneReply["todo"]?["isDone"]?.asBool, true)

        let openReply = try requireIpcReply(sendIpc(&model, method: Methods.todoOpen, params: .object(["todoId": .string(todoId)]), context: ctx))
        try expectEqual(model.panes[paneId]?.todos.first?.isDone, false)
        try expectEqual(openReply["todo"]?["isDone"]?.asBool, false)

        let list = try requireIpcReply(sendIpc(&model, method: Methods.todoList, context: ctx))
        try expectEqual(list["todos"]?.asArray?.count, 1)

        _ = sendIpc(&model, method: Methods.todoDelete, params: .object(["todoId": .string(todoId)]), context: ctx)
        try expectEqual(model.panes[paneId]?.todos.count, 0)

        let secondAdd = try requireIpcReply(sendIpc(
            &model,
            method: Methods.todoAdd,
            params: .object(["text": .string("done later")]),
            context: ctx
        ))
        let secondTodoId = try requireString(secondAdd["todo"]?["id"], "todo add should return second id")
        _ = sendIpc(&model, method: Methods.todoDone, params: .object(["todoId": .string(secondTodoId)]), context: ctx)
        _ = sendIpc(&model, method: Methods.todoDone, params: .object(["todoId": .string(todoId)]), context: ctx)
        _ = sendIpc(&model, method: Methods.todoClearCompleted, context: ctx)
        try expectEqual(model.panes[paneId]?.todos.count, 0)
    }

    test("todo commands with explicit pane target that pane regardless of context") {
        var model = makeModel()
        createTab(&model)
        let targetPaneId = selectedTab(in: model)!.focusedPaneId
        createTab(&model)
        let contextPaneId = selectedTab(in: model)!.focusedPaneId
        let ctx = IpcRequestContext(paneId: contextPaneId.rawValue.uuidString)

        let addReply = try requireIpcReply(sendIpc(
            &model,
            method: Methods.todoAdd,
            params: .object([
                "pane": .string(targetPaneId.rawValue.uuidString),
                "text": .string("ship cli"),
            ]),
            context: ctx
        ))
        let todoId = try requireString(addReply["todo"]?["id"], "todo add should return id")
        try expectEqual(model.panes[targetPaneId]?.todos.first?.text, "ship cli")
        try expectEqual(model.panes[contextPaneId]?.todos.count, 0)

        let listReply = try requireIpcReply(sendIpc(
            &model,
            method: Methods.todoList,
            params: .object(["pane": .string(targetPaneId.rawValue.uuidString)]),
            context: ctx
        ))
        try expectEqual(listReply["todos"]?.asArray?.count, 1)

        _ = sendIpc(
            &model,
            method: Methods.todoEdit,
            params: .object([
                "pane": .string(targetPaneId.rawValue.uuidString),
                "todoId": .string(todoId),
                "text": .string("ship cli v2"),
            ]),
            context: ctx
        )
        try expectEqual(model.panes[targetPaneId]?.todos.first?.text, "ship cli v2")

        _ = sendIpc(
            &model,
            method: Methods.todoDone,
            params: .object([
                "pane": .string(targetPaneId.rawValue.uuidString),
                "todoId": .string(todoId),
            ]),
            context: ctx
        )
        try expectEqual(model.panes[targetPaneId]?.todos.first?.isDone, true)

        _ = sendIpc(
            &model,
            method: Methods.todoOpen,
            params: .object([
                "pane": .string(targetPaneId.rawValue.uuidString),
                "todoId": .string(todoId),
            ]),
            context: ctx
        )
        try expectEqual(model.panes[targetPaneId]?.todos.first?.isDone, false)

        _ = sendIpc(
            &model,
            method: Methods.todoDone,
            params: .object([
                "pane": .string(targetPaneId.rawValue.uuidString),
                "todoId": .string(todoId),
            ]),
            context: ctx
        )
        _ = sendIpc(
            &model,
            method: Methods.todoClearCompleted,
            params: .object(["pane": .string(targetPaneId.rawValue.uuidString)]),
            context: ctx
        )
        try expectEqual(model.panes[targetPaneId]?.todos.count, 0)

        let deleteReply = try requireIpcReply(sendIpc(
            &model,
            method: Methods.todoAdd,
            params: .object([
                "pane": .string(targetPaneId.rawValue.uuidString),
                "text": .string("delete me"),
            ]),
            context: ctx
        ))
        let deleteId = try requireString(deleteReply["todo"]?["id"], "todo add should return delete id")
        _ = sendIpc(
            &model,
            method: Methods.todoDelete,
            params: .object([
                "pane": .string(targetPaneId.rawValue.uuidString),
                "todoId": .string(deleteId),
            ]),
            context: ctx
        )
        try expectEqual(model.panes[targetPaneId]?.todos.count, 0)
    }

    test("todo commands malformed or unknown explicit pane do not fall back to context") {
        for paneValue in [JSONValue.string("not-a-uuid"), .string(UUID().uuidString), .number(7)] {
            let commands: [(String, [String: JSONValue])] = [
                (Methods.todoList, [:]),
                (Methods.todoAdd, ["text": .string("should-not-apply")]),
                (Methods.todoEdit, ["todoId": .string("TODO_ID"), "text": .string("changed")]),
                (Methods.todoDone, ["todoId": .string("TODO_ID")]),
                (Methods.todoOpen, ["todoId": .string("TODO_ID")]),
                (Methods.todoDelete, ["todoId": .string("TODO_ID")]),
                (Methods.todoClearCompleted, [:]),
            ]

            for (method, baseParams) in commands {
                var model = makeModel()
                createTab(&model)
                let contextPaneId = selectedTab(in: model)!.focusedPaneId
                let item = appendTodoForTest(&model, paneId: contextPaneId, text: "context")
                if method == Methods.todoClearCompleted || method == Methods.todoOpen {
                    model.panes[contextPaneId]!.todos[0].isDone = true
                }

                var params = baseParams
                params["pane"] = paneValue
                if params["todoId"] != nil {
                    params["todoId"] = .string(item.id.uuidString)
                }

                let effects = sendIpc(
                    &model,
                    method: method,
                    params: .object(params),
                    context: IpcRequestContext(paneId: contextPaneId.rawValue.uuidString)
                )

                let error = try requireIpcError(effects)
                try expectEqual(error.code, -32602)
                try expectEqual(model.panes[contextPaneId]?.todos.count, 1)
                try expectEqual(model.panes[contextPaneId]?.todos[0].text, "context")
            }
        }
    }

    test("todo commands without explicit pane and without pane context fail before mutation") {
        let commands: [(String, [String: JSONValue])] = [
            (Methods.todoList, [:]),
            (Methods.todoAdd, ["text": .string("should-not-apply")]),
            (Methods.todoEdit, ["todoId": .string(UUID().uuidString), "text": .string("changed")]),
            (Methods.todoDone, ["todoId": .string(UUID().uuidString)]),
            (Methods.todoOpen, ["todoId": .string(UUID().uuidString)]),
            (Methods.todoDelete, ["todoId": .string(UUID().uuidString)]),
            (Methods.todoClearCompleted, [:]),
        ]

        for (method, params) in commands {
            var model = makeModel()
            createTab(&model)
            let paneId = selectedTab(in: model)!.focusedPaneId
            _ = appendTodoForTest(&model, paneId: paneId, text: "context")

            let effects = sendIpc(
                &model,
                method: method,
                params: .object(params),
                context: IpcRequestContext()
            )

            let error = try requireIpcError(effects)
            try expectEqual(error.code, -32602)
            try expectEqual(model.panes[paneId]?.todos.count, 1)
        }
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

    test("pane.input emits text effect for context pane") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.paneInput,
            params: .object(["text": .string("echo hi")]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )
        try expect(hasEffect(effects) {
            if case .sendText(let pid, let text) = $0 { return pid == paneId && text == "echo hi" }
            return false
        }, "expected sendText effect")
    }

    test("pane.input input array emits ordered Effects via the key path") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.paneInput,
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

    test("pane.input explicit empty mods equals omitted mods") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.paneInput,
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

    test("pane.input non-array mods is invalid params") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.paneInput,
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

    test("pane.input key with ctrl mod emits sendInputKey") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.paneInput,
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

    test("pane.input with both text and input is invalid params") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.paneInput,
            params: .object([
                "text": .string("hi"),
                "input": .array([.object(["text": .string("hi")])]),
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
    }

    test("pane.input with neither text nor input is invalid params") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.paneInput,
            params: .object([:]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
    }

    test("pane.input input event missing both text and key is invalid params") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.paneInput,
            params: .object([
                "input": .array([.object([:])])
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
    }

    test("pane.input input event with both text and key is invalid params") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.paneInput,
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
    test("pane.input unknown key name is rejected before any Effect") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.paneInput,
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

    test("pane.input non-string key value is invalid params") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.paneInput,
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

    test("pane.input unknown mod name is invalid params") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.paneInput,
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

    test("pane.input shift mod is rejected") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.paneInput,
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

    test("pane.input explicit pane targets that pane regardless of context") {
        var model = makeModel()
        createTab(&model)
        let backgroundPaneId = selectedTab(in: model)!.focusedPaneId
        createTab(&model)
        let foregroundPaneId = selectedTab(in: model)!.focusedPaneId
        // Context says foreground; explicit pane param overrides to background.
        let effects = sendIpc(
            &model,
            method: Methods.paneInput,
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

    test("pane.input explicit pane that doesn't exist returns pane not found") {
        var model = makeModel()
        createTab(&model)
        let realPaneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.paneInput,
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

    test("pane.input non-string pane is invalid params and does not fall back") {
        var model = makeModel()
        createTab(&model)
        let realPaneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.paneInput,
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

    test("pane.input with no pane in context and no explicit pane errors") {
        var model = makeModel()
        createTab(&model)
        let effects = sendIpc(
            &model,
            method: Methods.paneInput,
            params: .object(["input": .array([.object(["text": .string("hi")])])]),
            context: IpcRequestContext()
        )
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
        try expect(error.message.contains("no pane in context"),
                   "expected 'no pane in context', got: \(error.message)")
    }

    test("pane.read emits viewport read effect without immediate reply") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.paneRead,
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
        }, "pane.read success should not emit an immediate ipcReply")
    }

    test("pane.read emits scrollback tail read effect with line limit") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = sendIpc(
            &model,
            method: Methods.paneRead,
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

    test("pane.read missing pane param errors") {
        var model = makeModel()
        createTab(&model)
        let effects = sendIpc(&model, method: Methods.paneRead, params: .object([:]))
        let error = try requireIpcError(effects)
        try expectEqual(error.code, -32602)
        try expectEqual(error.message, "pane required")
    }

    test("pane.read non-string pane param errors") {
        for paneValue in [JSONValue.number(5), .array([]), .object([:])] {
            var model = makeModel()
            createTab(&model)
            let effects = sendIpc(
                &model,
                method: Methods.paneRead,
                params: .object(["pane": paneValue])
            )
            let error = try requireIpcError(effects)
            try expectEqual(error.code, -32602)
            try expectEqual(error.message, "pane required")
        }
    }

    test("pane.read unknown pane errors") {
        for rawPane in ["bogus", UUID().uuidString] {
            var model = makeModel()
            createTab(&model)
            let effects = sendIpc(
                &model,
                method: Methods.paneRead,
                params: .object(["pane": .string(rawPane)])
            )
            let error = try requireIpcError(effects)
            try expectEqual(error.code, -32602)
            try expectEqual(error.message, "pane not found")
        }
    }

    test("pane.read invalid line limits error") {
        let invalidValues: [JSONValue] = [.number(0), .number(-5), .string("5"), .number(1.5)]
        for linesValue in invalidValues {
            var model = makeModel()
            createTab(&model)
            let paneId = selectedTab(in: model)!.focusedPaneId
            let effects = sendIpc(
                &model,
                method: Methods.paneRead,
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
    return IpcRequestContext(paneId: tab.focusedPaneId.rawValue.uuidString)
}

private func groupTabIds(in model: AppModel) -> [[TabId]] {
    model.groups.map { $0.tabs.map(\.id) }
}

private func expectAfterTabInserted(
    reply: JSONValue,
    in model: AppModel,
    targetGroupId: GroupId,
    refTabId: TabId,
    beforeGroupTabs: [[TabId]],
    panesBefore: Set<PaneId>
) throws {
    guard let targetGroupIndex = model.groups.firstIndex(where: { $0.id == targetGroupId }) else {
        throw TestFailure(message: "target group should exist")
    }
    guard let refIndex = beforeGroupTabs[targetGroupIndex].firstIndex(of: refTabId) else {
        throw TestFailure(message: "reference tab should be in target group snapshot")
    }
    let tabId = try requireTabId(reply["tab"]?["id"], "tab.new should return tab id")
    let paneId = try requirePaneId(reply["panes"]?.asArray?.first?["id"], "tab.new should return pane id")
    var expectedTarget = beforeGroupTabs[targetGroupIndex]
    expectedTarget.insert(tabId, at: refIndex + 1)

    for groupIndex in model.groups.indices {
        if groupIndex == targetGroupIndex {
            try expectEqual(model.groups[groupIndex].tabs.map(\.id), expectedTarget)
        } else {
            try expectEqual(model.groups[groupIndex].tabs.map(\.id), beforeGroupTabs[groupIndex])
        }
    }

    let newPaneIds = Set(model.panes.keys).subtracting(panesBefore)
    try expectEqual(newPaneIds, [paneId])
    guard let tab = tabById(tabId, in: model) else {
        throw TestFailure(message: "new tab should exist")
    }
    try expectEqual(tab.focusedPaneId, paneId)
    if case .leaf(let rootPaneId) = tab.rootNode {
        try expectEqual(rootPaneId, paneId)
    } else {
        throw TestFailure(message: "new tab should have a root leaf")
    }
    try expectEqual(model.selectedTabId, tabId)
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

private func requireTabId(_ value: JSONValue?, _ message: String) throws -> TabId {
    let raw = try requireString(value, message)
    guard let uuid = UUID(uuidString: raw) else {
        throw TestFailure(message: message)
    }
    return TabId(rawValue: uuid)
}

private func appendTodoForTest(_ model: inout AppModel, paneId: PaneId, text: String) -> TodoItem {
    let item = TodoItem(id: UUID(), text: text, isDone: false)
    model.panes[paneId]!.todos.append(item)
    return item
}

private func updateTabForTest(_ tabId: TabId, in model: inout AppModel, _ body: (inout TabModel) -> Void) {
    for groupIndex in model.groups.indices {
        if let tabIndex = model.groups[groupIndex].tabs.firstIndex(where: { $0.id == tabId }) {
            body(&model.groups[groupIndex].tabs[tabIndex])
            return
        }
    }
}
