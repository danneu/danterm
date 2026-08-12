// Swift Testing migration of the legacy `tests/UpdateIpcTests.swift` harness
// suite. Pins the pure `update()` handling of DanTerm IPC requests across
// the protocol surface: ls (full snapshot), focus.info (live runtime read),
// pane.info (explicit + implicit
// pane targeting and missing/invalid targets), tab.rename (set/clear,
// explicit targeting, malformed
// inputs), pane.close (required explicit targeting, sibling promotion, tab
// cascade, last-pane refusal, and confirmation bypass), pane.split
// (explicit-pane targeting, malformed/unknown/non-
// string/orphan failures, background and launch flows), pane.focus
// (selection + first responder + popover preservation +
// alert clear), tab.new (explicit group, group context, background, launch,
// afterTab matching, malformed groups, cwd sourcing), theme.set,
// the todo command family (list/add/edit/done/open/delete/clear-completed), and
// pane.input (text/input array/empty mods/non-array mods/ctrl mod/both-or-
// neither/unknown key/non-string key/unknown mod/shift mod/missing pane/
// non-string pane), plus pane.read (viewport + scrollback line limit).
// The 16 legacy `throw TestFailure` sites split: 9 convert to `try #require`
// (single-value unwraps + helper fall-throughs), 7 to `Issue.record + return`
// (compound case-pattern destructures); the failure-site total stays exact.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

@Suite struct UpdateIpcTests {
    @Test("every targeting IPC method rejects an absent target without mutation")
    func everyTargetingMethodRejectsAbsentTarget() throws {
        let todoId = UUID().uuidString
        let cases: [(method: String, params: [String: JSONValue], entity: String)] = [
            (IpcRequestMethod.tabNew.rawValue, [:], "group"),
            (IpcRequestMethod.tabRename.rawValue, ["title": .string("work")], "tab"),
            (IpcRequestMethod.tabClose.rawValue, [:], "tab"),
            (IpcRequestMethod.groupRename.rawValue, ["name": .string("Notes")], "group"),
            (IpcRequestMethod.groupClose.rawValue, [:], "group"),
            (IpcRequestMethod.paneFocus.rawValue, [:], "pane"),
            (IpcRequestMethod.paneInfo.rawValue, [:], "pane"),
            (IpcRequestMethod.paneSplit.rawValue, ["direction": .string("horizontal")], "pane"),
            (IpcRequestMethod.paneClose.rawValue, [:], "pane"),
            (IpcRequestMethod.paneInput.rawValue, ["input": .array([.object(["text": .string("x")])])], "pane"),
            (IpcRequestMethod.paneRead.rawValue, [:], "pane"),
            (IpcRequestMethod.paneRows.rawValue, [:], "pane"),
            (IpcRequestMethod.paneZoom.rawValue, ["state": .string("on")], "pane"),
            (IpcRequestMethod.paneTape.rawValue, [:], "pane"),
            (IpcRequestMethod.themeSet.rawValue, ["themeName": .null], "pane"),
            (IpcRequestMethod.agentAttach.rawValue, ["kind": .string("codex"), "id": .string("thread")], "pane"),
            (IpcRequestMethod.agentActivity.rawValue, [
                "kind": .string("codex"),
                "id": .string("thread"),
                "state": .string("working"),
            ], "pane"),
            (IpcRequestMethod.agentDetach.rawValue, ["kind": .string("codex"), "id": .string("thread")], "pane"),
            (IpcRequestMethod.todoList.rawValue, [:], "pane"),
            (IpcRequestMethod.todoAdd.rawValue, ["text": .string("work")], "pane"),
            (IpcRequestMethod.todoEdit.rawValue, ["todoId": .string(todoId), "text": .string("work")], "pane"),
            (IpcRequestMethod.todoDone.rawValue, ["todoId": .string(todoId)], "pane"),
            (IpcRequestMethod.todoOpen.rawValue, ["todoId": .string(todoId)], "pane"),
            (IpcRequestMethod.todoDelete.rawValue, ["todoId": .string(todoId)], "pane"),
            (IpcRequestMethod.todoClearCompleted.rawValue, [:], "pane"),
        ]

        for testCase in cases {
            var model = makeModel()
            createTab(&model)
            let before = model
            let commands = sendIpc(
                &model,
                method: testCase.method,
                params: .object(testCase.params)
            )

            let expected = testCase.method.hasPrefix("todo.")
                ? "pane or tab required"
                : "\(testCase.entity) required"
            #expect(try requireIpcError(commands).message == expected)
            #expect(model == before)
        }
    }

    @Test("doctor permissions delegates probing to the runtime")
    func doctorPermissionsDelegatesProbingToRuntime() throws {
        var model = makeModel()
        let commands = sendIpc(&model, method: IpcRequestMethod.doctorPermissions.rawValue)
        let command = try #require(commands.first)
        guard case .readDoctorPermissions = command else {
            Issue.record("expected readDoctorPermissions")
            return
        }
        #expect(commands.count == 1)
    }

    @Test("focus.info delegates live claimant inspection to the runtime")
    func focusInfoDelegatesInspectionToRuntime() throws {
        var model = makeModel()
        let commands = sendIpc(&model, method: IpcRequestMethod.focusInfo.rawValue)
        let command = try #require(commands.first)
        guard case .readFocusInfo = command else {
            Issue.record("expected readFocusInfo")
            return
        }
        #expect(commands.count == 1)
    }

    @Test("unknown method returns method-not-found error")
    func unknownMethodReturnsMethodNotFoundError() throws {
        // Intent: an unknown method returns the standard JSON-RPC
        //   "method not found" code (-32601).
        // Why it exists: pins the unknown-method error path.
        // Scenario: spec-first unknown method.
        var model = makeModel()
        createTab(&model)
        let commands = sendIpc(&model, method: "missing")
        let error = try requireIpcError(commands)
        #expect(error.code == -32601)
    }

    @Test("malformed explicit target returns invalid params")
    func malformedExplicitTargetReturnsInvalidParams() throws {
        var model = makeModel()
        createTab(&model)
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.tabRename.rawValue,
            params: .object(["tab": .string("not-a-uuid"), "title": .string("work")])
        )
        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
    }

    @Test("ls encodes the documented rich model with current pane lifecycles")
    func lsEncodesRichModelDirectly() throws {
        let paneAId = PaneId(rawValue: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!)
        let paneBId = PaneId(rawValue: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!)
        let paneCId = PaneId(rawValue: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!)
        let paneDId = PaneId(rawValue: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!)
        let splitAId = SplitId(rawValue: UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!)
        let splitBId = SplitId(rawValue: UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!)
        let tabAId = TabId(rawValue: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        let tabBId = TabId(rawValue: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)
        let groupAId = GroupId(rawValue: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!)
        let groupBId = GroupId(rawValue: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!)
        let paneTodoId = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let tabTodoId = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        let paneA = PaneModel(
            id: paneAId,
            session: SessionModel(
                id: SessionId(),
                title: "shell",
                cwd: "/Users/testhome/work",
                command: .running("swift test"),
                lastCommand: "swift test"
            ),
            theme: "Tokyo Night",
            fontSizeSteps: 2,
            todos: [TodoItem(id: paneTodoId, text: "ship", isDone: false)]
        )
        let paneB = PaneModel(
            id: paneBId,
            session: SessionModel(id: SessionId(), title: "tests", cwd: "/tmp")
        )
        let paneC = PaneModel(id: paneCId, session: SessionModel(id: SessionId(), title: "logs"))
        let paneD = PaneModel(id: paneDId, session: SessionModel(id: SessionId(), title: "archive"))
        let nestedRoot: SplitNodeModel = .split(
            id: splitAId,
            direction: .horizontal,
            first: .leaf(paneA),
            second: .split(
                id: splitBId,
                direction: .vertical,
                first: .leaf(paneB),
                second: .leaf(paneC),
                ratio: 0.4
            ),
            ratio: 0.6
        )
        let tabA = TabModel(
            id: tabAId,
            customTitle: "work",
            focusedPaneId: paneBId,
            rootNode: nestedRoot,
            color: .purple,
            todos: [TodoItem(id: tabTodoId, text: "review", isDone: true)]
        )
        let tabB = TabModel(id: tabBId, focusedPaneId: paneDId, rootNode: .leaf(paneD))
        var model = AppModel(
            groups: [
                GroupModel(id: groupAId, name: "General", tabs: [tabA]),
                GroupModel(id: groupBId, name: "Archive", isCollapsed: true, tabs: [tabB]),
            ],
            selectedTabId: tabAId
        )
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.ls.rawValue,
            env: makeTestEnv(homeDirectory: "/Users/testhome")
        )

        let result = try requireIpcReply(commands)
        let neutralLifecycles: [String: JSONValue] = [
            "integration": .object(["state": .string("neverReported")]),
            "command": .object(["state": .string("idle")]),
            "connection": .object(["state": .string("local")]),
            "agent": .object(["state": .string("none")]),
        ]
        let runningLifecycles: [String: JSONValue] = [
            "integration": .object(["state": .string("neverReported")]),
            "command": .object(["state": .string("running"), "text": .string("swift test")]),
            "connection": .object(["state": .string("local")]),
            "agent": .object(["state": .string("none")]),
        ]
        func pane(_ fields: [String: JSONValue], lifecycles: [String: JSONValue]) -> JSONValue {
            .object(fields.merging(lifecycles) { _, lifecycle in lifecycle })
        }
        let expected: JSONValue = .object([
            "groups": .array([
                .object([
                    "id": .string(groupAId.rawValue.uuidString),
                    "name": .string("General"),
                    "isCollapsed": .bool(false),
                    "tabs": .array([.object([
                        "id": .string(tabAId.rawValue.uuidString),
                        "customTitle": .string("work"),
                        "focusedPaneId": .string(paneBId.rawValue.uuidString),
                        "color": .string("purple"),
                        "todos": .array([.object([
                            "id": .string(tabTodoId.uuidString),
                            "text": .string("review"),
                            "isDone": .bool(true),
                        ])]),
                        "rootNode": .object([
                            "type": .string("split"),
                            "id": .string(splitAId.rawValue.uuidString),
                            "direction": .string("horizontal"),
                            "ratio": .number(0.6),
                            "first": .object([
                                "type": .string("leaf"),
                                "pane": pane([
                                    "id": .string(paneAId.rawValue.uuidString),
                                    "title": .string("shell"),
                                    "cwd": .string("~/work"),
                                    "theme": .string("Tokyo Night"),
                                    "fontSizeSteps": .number(2),
                                    "todos": .array([.object([
                                        "id": .string(paneTodoId.uuidString),
                                        "text": .string("ship"),
                                        "isDone": .bool(false),
                                    ])]),
                                ], lifecycles: runningLifecycles),
                            ]),
                            "second": .object([
                                "type": .string("split"),
                                "id": .string(splitBId.rawValue.uuidString),
                                "direction": .string("vertical"),
                                "ratio": .number(0.4),
                                "first": .object([
                                    "type": .string("leaf"),
                                    "pane": pane([
                                        "id": .string(paneBId.rawValue.uuidString),
                                        "title": .string("tests"),
                                        "cwd": .string("/tmp"),
                                    ], lifecycles: neutralLifecycles),
                                ]),
                                "second": .object([
                                    "type": .string("leaf"),
                                    "pane": pane([
                                        "id": .string(paneCId.rawValue.uuidString),
                                        "title": .string("logs"),
                                    ], lifecycles: neutralLifecycles),
                                ]),
                            ]),
                        ]),
                    ])]),
                ]),
                .object([
                    "id": .string(groupBId.rawValue.uuidString),
                    "name": .string("Archive"),
                    "isCollapsed": .bool(true),
                    "tabs": .array([.object([
                        "id": .string(tabBId.rawValue.uuidString),
                        "focusedPaneId": .string(paneDId.rawValue.uuidString),
                        "rootNode": .object([
                            "type": .string("leaf"),
                            "pane": pane([
                                "id": .string(paneDId.rawValue.uuidString),
                                "title": .string("archive"),
                            ], lifecycles: neutralLifecycles),
                        ]),
                    ])]),
                ]),
            ]),
            "selectedTabId": .string(tabAId.rawValue.uuidString),
        ])
        #expect(result == expected)
    }

    @Test("ls attaches lifecycle fields only to panes when entity ids collide")
    func lsScopesLifecycleFieldsToPaneEntities() throws {
        let rawId = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let paneId = PaneId(rawValue: rawId)
        let tabId = TabId(rawValue: rawId)
        let groupId = GroupId(rawValue: rawId)
        let state = SessionModel(id: SessionId(), command: .running("make test"), lastCommand: "make test")
        let pane = PaneModel(id: paneId, session: state)
        let tab = TabModel(id: tabId, focusedPaneId: paneId, rootNode: .leaf(pane))
        var model = AppModel(
            groups: [GroupModel(id: groupId, name: "collision", tabs: [tab])],
            selectedTabId: tabId
        )
        let result = try requireIpcReply(sendIpc(
            &model,
            method: IpcRequestMethod.ls.rawValue
        ))
        let group = try #require(result["groups"]?.asArray?.first)
        let encodedTab = try #require(group["tabs"]?.asArray?.first)
        let encodedPane = encodedTab["rootNode"]?["pane"]

        let expectedFields = paneLifecycleInspectionFields(state)
        for key in ["integration", "command", "connection", "agent"] {
            #expect(group[key] == nil)
            #expect(encodedTab[key] == nil)
            #expect(encodedPane?[key] == expectedFields[key])
        }
        #expect(encodedPane?["live"] == nil)
    }

    @Test("agent.attach routes through the pane owner before its reply")
    func agentAttachRoutesThroughPaneOwnerBeforeReply() throws {
        // Intent: agent.attach reduces the model before returning its reply.
        // Why it exists: reply ordering is guaranteed by one pure update pass.
        // Scenario: a Claude SessionStart hook reports its session id from
        //   inside a DanTerm pane.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.agentAttach.rawValue,
            params: .object([
                "kind": .string("Claude"),
                "id": .string("4f3a2b1c-0000-4000-9000-abcdef123456"),
            ]),
            pane: paneId
        )

        #expect(commands.count == 1)
        let session = try #require(AgentSession(
            kind: "claude",
            sessionId: "4f3a2b1c-0000-4000-9000-abcdef123456"
        ))
        #expect(model.pane(paneId)?.session?.agent == .attached(session: session, activity: nil))
        _ = try requireIpcReply(commands)
    }

    @Test("pane.info replies directly with complete default lifecycles")
    func paneInfoRepliesDirectlyWithDefaultLifecycles() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInfo.rawValue,
            pane: paneId
        )

        let result = try requireIpcReply(commands)
        let tab = try #require(selectedTab(in: model))
        let group = try #require(model.groups.first)
        let expected: JSONValue = .object([
            "pane": .object([
                "id": .string(paneId.rawValue.uuidString),
                "title": .string("Terminal"),
                "cwd": .null,
                "integration": .object(["state": .string("neverReported")]),
                "command": .object(["state": .string("idle")]),
                "connection": .object(["state": .string("local")]),
                "agent": .object(["state": .string("none")]),
            ]),
            "tab": .object([
                "id": .string(tab.id.rawValue.uuidString),
                "title": .string("Terminal"),
                "groupId": .string(group.id.rawValue.uuidString),
                "isZoomed": .bool(false),
            ]),
            "group": .object([
                "id": .string(group.id.rawValue.uuidString),
                "name": .string("General"),
            ]),
        ])
        #expect(result == expected)
    }

    @Test("agent activity and detach route session-qualified events")
    func agentActivityAndDetachRouteSessionQualifiedEvents() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let context = paneId
        let session = try #require(AgentSession(kind: "codex", sessionId: "thread-1"))
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(session)))

        let activity = sendIpc(
            &model,
            method: IpcRequestMethod.agentActivity.rawValue,
            params: .object([
                "kind": .string("codex"),
                "id": .string("thread-1"),
                "state": .string("waiting"),
            ]),
            pane: context
        )
        let detach = sendIpc(
            &model,
            method: IpcRequestMethod.agentDetach.rawValue,
            params: .object(["kind": .string("codex"), "id": .string("thread-1")]),
            pane: context
        )

        #expect(activity.count == 1)
        _ = try requireIpcReply(activity)
        #expect(detach.count == 1)
        _ = try requireIpcReply(detach)
        #expect(model.pane(paneId)?.session?.agent == AgentLifecycle.none)
    }

    @Test("agent activity rejects unsupported states before pane mutation")
    func agentActivityRejectsUnsupportedStates() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.agentActivity.rawValue,
            params: .object([
                "kind": .string("codex"),
                "id": .string("thread-1"),
                "state": .string("busy"),
            ]),
            pane: paneId
        )

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
    }

    @Test("agent.attach rejects invalid params without changing pane")
    func agentAttachRejectsInvalidParams() throws {
        // Intent: unsafe kind/session id input returns invalid-params and
        //   leaves the pane's live agent session nil.
        // Why it exists: guards the toolbar and recovery-line paths against
        //   terminal escape, shell metacharacter, and CLI flag injection.
        // Scenario: a malicious pane process tries to report a flag-shaped id.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.agentAttach.rawValue,
            params: .object([
                "kind": .string("claude"),
                "id": .string("--dangerously-skip-permissions"),
            ]),
            pane: paneId
        )

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
    }

    @Test("pane.info explicit pane returns containing pane tab and group")
    func paneInfoExplicitPaneReturnsContainingTabAndGroup() throws {
        // Intent: pane.info with an explicit pane returns the pane's
        //   containing tab and group (ignoring the IPC context pane).
        // Why it exists: pins the explicit-target wins rule.
        // Scenario: spec-first explicit pane.
        var model = makeModel()
        createTab(&model)
        let backgroundGroupId = model.groups[0].id
        let backgroundTabId = selectedTab(in: model)!.id
        let backgroundPaneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .createGroup(name: "Other"))
        let otherGroupId = model.groups.last!.id
        createTab(&model, inGroupId: otherGroupId)
        let contextPaneId = selectedTab(in: model)!.focusedPaneId

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInfo.rawValue,
            params: .object(["pane": .string(backgroundPaneId.rawValue.uuidString)]),
            pane: contextPaneId
        )

        let reply = try requireIpcReply(commands)
        #expect(reply["pane"]?["id"]?.asString == backgroundPaneId.rawValue.uuidString)
        #expect(reply["tab"]?["id"]?.asString == backgroundTabId.rawValue.uuidString)
        #expect(reply["tab"]?["groupId"]?.asString == backgroundGroupId.rawValue.uuidString)
        #expect(reply["group"]?["id"]?.asString == backgroundGroupId.rawValue.uuidString)
        #expect(reply["group"]?["name"]?.asString == "General")
    }

    @Test("pane.info uses the explicitly named pane")
    func paneInfoUsesExplicitPane() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let tabId = selectedTab(in: model)!.id

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInfo.rawValue,
            params: .object(["pane": .string(paneId.rawValue.uuidString)])
        )

        let reply = try requireIpcReply(commands)
        #expect(reply["pane"]?["id"]?.asString == paneId.rawValue.uuidString)
        #expect(reply["tab"]?["id"]?.asString == tabId.rawValue.uuidString)
    }

    @Test("pane.info missing or invalid target fails without falling back")
    func paneInfoMissingOrInvalidTargetFails() throws {
        // Intent: pane.info with missing / non-UUID / unknown pane
        //   returns -32602 (no fallback to context).
        // Why it exists: pins the no-fallback rule.
        // Scenario: spec-first missing/invalid/unknown.
        var model = makeModel()
        createTab(&model)
        let contextPaneId = selectedTab(in: model)!.focusedPaneId

        let missing = sendIpc(&model, method: IpcRequestMethod.paneInfo.rawValue, pane: nil)
        #expect(try requireIpcError(missing).code == -32602)

        let invalid = sendIpc(
            &model,
            method: IpcRequestMethod.paneInfo.rawValue,
            params: .object(["pane": .string("not-a-uuid")]),
            pane: contextPaneId
        )
        #expect(try requireIpcError(invalid).code == -32602)

        let unknown = sendIpc(
            &model,
            method: IpcRequestMethod.paneInfo.rawValue,
            params: .object(["pane": .string(UUID().uuidString)]),
            pane: contextPaneId
        )
        #expect(try requireIpcError(unknown).code == -32602)
    }

    @Test("tab.rename sets and clears custom title")
    func tabRenameSetsAndClearsCustomTitle() throws {
        // Intent: tab.rename sets customTitle (and returns it in reply)
        //   then clears it via null.
        // Why it exists: pins the set/clear round-trip.
        // Scenario: spec-first set + clear.
        var model = makeModel()
        createTab(&model)
        let ctx = selectedPaneId(in: model)
        let tabId = selectedTab(in: model)!.id

        let setEffects = sendIpc(&model, method: IpcRequestMethod.tabRename.rawValue, params: .object([
            "tab": .string(tabId.rawValue.uuidString),
            "title": .string("hello"),
        ]), pane: ctx)
        let setReply = try requireIpcReply(setEffects)
        #expect(setReply["tab"]?["id"]?.asString == tabId.rawValue.uuidString)
        #expect(setReply["tab"]?["customTitle"]?.asString == "hello")
        #expect(tabById(tabId, in: model)?.customTitle == "hello")

        let clearEffects = sendIpc(&model, method: IpcRequestMethod.tabRename.rawValue, params: .object([
            "tab": .string(tabId.rawValue.uuidString),
            "title": .null,
        ]), pane: ctx)
        let clearReply = try requireIpcReply(clearEffects)
        #expect(clearReply["tab"]?["customTitle"] == .null)
        #expect(tabById(tabId, in: model)?.customTitle == nil)
    }

    @Test("tab.rename targets the named live tab when a pane moved")
    func tabRenameDerivesLiveTabFromPaneContext() {
        // Intent: tab.rename uses the live tab of the pane in context;
        //   after movePaneToTab, the new live tab is targeted.
        // Why it exists: pins the live-derivation rule.
        // Scenario: spec-first live tab via pane.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .splitFocusedPane(direction: .horizontal))
        createTab(&model)
        let targetTabId = selectedTab(in: model)!.id
        _ = update(&model, .movePaneToTab(paneId: paneId, targetTabId: targetTabId))

        _ = sendIpc(
            &model,
            method: IpcRequestMethod.tabRename.rawValue,
            params: .object([
                "tab": .string(targetTabId.rawValue.uuidString),
                "title": .string("current"),
            ]),
            pane: paneId
        )

        let currentTab = tabForPane(paneId, in: model)
        #expect(currentTab?.id == targetTabId)
        #expect(currentTab?.customTitle == "current")
    }

    @Test("tab.rename explicit tab targets that tab regardless of selection and context")
    func tabRenameExplicitTabTargetsRegardlessOfContext() throws {
        // Intent: an explicit tab param targets that tab regardless of
        //   selection + pane context.
        // Why it exists: pins the explicit-wins rule.
        // Scenario: spec-first explicit tab.
        var model = makeModel()
        createTab(&model)
        let backgroundTabId = selectedTab(in: model)!.id
        let backgroundPaneId = selectedTab(in: model)!.focusedPaneId
        createTab(&model)
        let foregroundTabId = selectedTab(in: model)!.id
        let foregroundPaneId = selectedTab(in: model)!.focusedPaneId

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.tabRename.rawValue,
            params: .object([
                "tab": .string(backgroundTabId.rawValue.uuidString),
                "title": .string("build"),
            ]),
            pane: foregroundPaneId
        )

        let reply = try requireIpcReply(commands)
        #expect(reply["tab"]?["id"]?.asString == backgroundTabId.rawValue.uuidString)
        #expect(tabById(backgroundTabId, in: model)?.customTitle == "build")
        #expect(tabById(foregroundTabId, in: model)?.customTitle == nil)
        #expect(tabForPane(backgroundPaneId, in: model)?.id == backgroundTabId)
    }

    @Test("tab.rename malformed or unknown explicit tab does not fall back to context")
    func tabRenameMalformedOrUnknownExplicitTabNoFallback() throws {
        // Intent: explicit tab values that are malformed/unknown/non-
        //   string return -32602; the context tab is not affected.
        // Why it exists: pins the no-fallback guard for explicit tab.
        // Scenario: spec-first malformed/unknown/non-string explicit.
        for tabValue in [JSONValue.string("not-a-uuid"), .string(UUID().uuidString), .number(7)] {
            var model = makeModel()
            createTab(&model)
            let contextTabId = selectedTab(in: model)!.id
            let contextPaneId = selectedTab(in: model)!.focusedPaneId

            let commands = sendIpc(
                &model,
                method: IpcRequestMethod.tabRename.rawValue,
                params: .object([
                    "tab": tabValue,
                    "title": .string("should-not-apply"),
                ]),
                pane: contextPaneId
            )

            let error = try requireIpcError(commands)
            #expect(error.code == -32602)
            #expect(tabById(contextTabId, in: model)?.customTitle == nil)
        }
    }

    @Test("tab.rename without explicit tab and without pane context fails before mutation")
    func tabRenameWithoutTabAndWithoutContextFails() throws {
        // Intent: with neither an explicit tab nor a pane context,
        //   tab.rename errors out before any mutation.
        // Why it exists: pins the "need a target" rule.
        // Scenario: spec-first no-target.
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.tabRename.rawValue,
            params: .object(["title": .string("missing-context")]),
            pane: nil
        )

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(tabById(tabId, in: model)?.customTitle == nil)
    }

    @Test("group.new creates a group holding one tab and replies with both ids")
    func groupNewCreatesGroupWithOneTab() throws {
        // Intent: group.new adds a group with exactly one tab, and the reply
        //   names the new group and that tab.
        // Why it exists: `.createGroup` creates the first tab too, so a caller
        //   needs both ids back to keep driving.
        // Scenario: spec-first creation beside an existing group.
        var model = makeModel()
        createTab(&model)
        let existingGroupId = model.groups[0].id

        let commands = sendIpc(&model, method: IpcRequestMethod.groupNew.rawValue, params: .object([
            "name": .string("Builds"),
        ]))

        let reply = try requireIpcReply(commands)
        #expect(model.groups.count == 2)
        let created = try #require(model.groups.first(where: { $0.id != existingGroupId }))
        #expect(created.name == "Builds")
        #expect(created.tabs.count == 1)
        #expect(reply["group"]?["id"]?.asString == created.id.rawValue.uuidString)
        #expect(reply["group"]?["name"]?.asString == "Builds")
        #expect(reply["tab"]?["id"]?.asString == created.tabs[0].id.rawValue.uuidString)
        let paneId = try requirePaneId(
            reply["panes"]?.asArray?.first?["id"], "group.new should return pane id")
        #expect(created.tabs[0].focusedPaneId == paneId)
    }

    // `Msg.createGroup` forwards to `.createTab` with background: false, so before
    // the creation background parameter existed every scripted group creation stole
    // the user's selection.
    @Test("group.new leaves selection alone by default and takes it with background false")
    func groupNewBackgroundPolicy() throws {
        // Intent: the created tab is not selected unless the request asks for
        //   the foreground.
        // Why it exists: an agent creating a group must not move the user's focus.
        // Scenario: spec-first background default, then an explicit foreground.
        var model = makeModel()
        createTab(&model)
        let selectedBefore = model.selectedTabId

        _ = sendIpc(&model, method: IpcRequestMethod.groupNew.rawValue, params: .object([
            "name": .string("Builds"),
            "background": .bool(true),
        ]))
        #expect(model.selectedTabId == selectedBefore)

        let commands = sendIpc(&model, method: IpcRequestMethod.groupNew.rawValue, params: .object([
            "name": .string("Notes"),
            "background": .bool(false),
        ]))
        let reply = try requireIpcReply(commands)
        let newTabId = try requireTabId(reply["tab"]?["id"], "group.new should return tab id")
        #expect(model.selectedTabId == newTabId)
    }

    @Test("group.new forwards the launch spec to the created tab")
    func groupNewForwardsLaunchSpec() throws {
        // Intent: the launch payload reaches the group's first tab.
        // Why it exists: `.createGroup` creates that tab, so the spec has only
        //   one place to land and a caller must be able to seed it.
        // Scenario: spec-first creation with a command, cwd, and title.
        var model = makeModel()
        createTab(&model)

        let commands = sendIpc(&model, method: IpcRequestMethod.groupNew.rawValue, params: .object([
            "name": .string("Builds"),
            "launch": .object([
                "cmd": .string("just test"),
                "cwd": .string("/tmp"),
                "title": .string("tests"),
            ]),
        ]))

        let reply = try requireIpcReply(commands)
        let paneId = try requirePaneId(
            reply["panes"]?.asArray?.first?["id"], "group.new should return pane id")
        #expect(hasEffect(commands) {
            if case .createSession(_, let effectPaneId, let cwd, let command, _) = $0 {
                return effectPaneId == paneId && cwd == "/tmp" && command == "just test"
            }
            return false
        }, "expected createSession seeded from the launch spec")
    }

    // `.createGroup` normalizes nothing, so without the dispatch guard this would
    // create a group whose name is blank or spans several lines.
    @Test("group.new rejects a whitespace-only name and creates nothing")
    func groupNewRejectsWhitespaceOnlyName() throws {
        // Intent: a name that normalizes to nothing is refused with
        //   `invalid name` and no group is created.
        // Why it exists: a blank group name would be unreachable in the sidebar.
        // Scenario: spec-first blank creation.
        var model = makeModel()
        createTab(&model)
        let before = model

        let commands = sendIpc(&model, method: IpcRequestMethod.groupNew.rawValue, params: .object([
            "name": .string("   "),
        ]))

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(error.message == "invalid name")
        #expect(model == before)
    }

    @Test("group.new collapses a multiline name to one line")
    func groupNewCollapsesMultilineName() throws {
        // Intent: a name carrying newlines is stored as one line, matching what
        //   rename already enforces.
        // Why it exists: `.createGroup` applies no normalization of its own.
        // Scenario: spec-first pasted two-line name.
        var model = makeModel()
        createTab(&model)
        let existingGroupId = model.groups[0].id

        let commands = sendIpc(&model, method: IpcRequestMethod.groupNew.rawValue, params: .object([
            "name": .string("work\n  logs"),
        ]))

        let reply = try requireIpcReply(commands)
        #expect(reply["group"]?["name"]?.asString == "work logs")
        let created = try #require(model.groups.first(where: { $0.id != existingGroupId }))
        #expect(created.name == "work logs")
    }

    @Test("group.close removes the group and its tabs")
    func groupCloseRemovesGroupAndTabs() throws {
        // Intent: group.close deletes the group with its tabs and replies with
        //   the closed group id.
        // Why it exists: pins the default (destructive) branch to the existing
        //   delete mutation instead of a second removal path.
        // Scenario: spec-first close of a second group.
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .createGroup(name: "Builds"))
        let closedGroupId = model.groups[1].id
        let closedTabIds = model.groups[1].tabs.map(\.id)

        let commands = sendIpc(&model, method: IpcRequestMethod.groupClose.rawValue, params: .object([
            "group": .string(closedGroupId.rawValue.uuidString),
        ]))

        let reply = try requireIpcReply(commands)
        #expect(reply["group"]?["id"]?.asString == closedGroupId.rawValue.uuidString)
        #expect(model.groups.contains(where: { $0.id == closedGroupId }) == false)
        for tabId in closedTabIds {
            #expect(tabById(tabId, in: model) == nil)
        }
    }

    @Test("group.close with moveTabs reparents the tabs into the adjacent group")
    func groupCloseWithMoveTabsReparentsTabs() throws {
        // Intent: moveTabs deletes the group but keeps its tabs, in the
        //   adjacent group.
        // Why it exists: pins the non-destructive branch of the same mutation.
        // Scenario: spec-first close that preserves work.
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .createGroup(name: "Builds"))
        let closedGroupId = model.groups[1].id
        let movedTabIds = model.groups[1].tabs.map(\.id)
        let survivingGroupId = model.groups[0].id

        _ = sendIpc(&model, method: IpcRequestMethod.groupClose.rawValue, params: .object([
            "group": .string(closedGroupId.rawValue.uuidString),
            "moveTabs": .bool(true),
        ]))

        #expect(model.groups.contains(where: { $0.id == closedGroupId }) == false)
        let surviving = try #require(model.groups.first(where: { $0.id == survivingGroupId }))
        for tabId in movedTabIds {
            #expect(surviving.tabs.contains(where: { $0.id == tabId }))
        }
    }

    @Test("group.close refuses the last group")
    func groupCloseRefusesLastGroup() throws {
        // Intent: closing the only group is refused with
        //   `cannot close the last group`, either way the tabs are handled.
        // Why it exists: `.deleteGroup` silently returns [] for the last group,
        //   so the CLI would otherwise exit 0 for a close that never happened.
        // Scenario: spec-first single-group model.
        var model = makeModel()
        createTab(&model)
        let onlyGroupId = model.groups[0].id

        for moveTabs in [false, true] {
            var attempt = model
            let before = attempt
            let commands = sendIpc(&attempt, method: IpcRequestMethod.groupClose.rawValue, params: .object([
                "group": .string(onlyGroupId.rawValue.uuidString),
                "moveTabs": .bool(moveTabs),
            ]))

            let error = try requireIpcError(commands)
            #expect(error.code == -32602)
            #expect(error.message == "cannot close the last group")
            #expect(attempt == before)
        }
    }

    // This input drives `.deleteGroup` into emitTerminateConfirmation, which leaves
    // the group open and strands a pending confirmation. The CLI never quits the app
    // as a side effect.
    @Test("group.close refuses a group holding every tab and strands no confirmation")
    func groupCloseRefusesGroupHoldingEveryTab() throws {
        // Intent: without moveTabs, closing the group that holds every tab is
        //   refused, and no pending confirmation is left behind.
        // Why it exists: the alternative is a quit prompt the caller never asked
        //   for, on a command that reports success.
        // Scenario: an empty second group makes this group not the last group
        //   while it still holds every tab.
        var model = makeModel()
        createTab(&model)
        model.groups.append(GroupModel(id: GroupId(), name: "Empty"))
        let tabsGroupId = model.groups[0].id
        let before = model

        let commands = sendIpc(&model, method: IpcRequestMethod.groupClose.rawValue, params: .object([
            "group": .string(tabsGroupId.rawValue.uuidString),
        ]))

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(error.message == "cannot close the last group with tabs")
        #expect(model == before)
        #expect(model.pendingConfirmation == nil)
    }

    @Test("group.close with moveTabs accepts a group holding every tab")
    func groupCloseWithMoveTabsAcceptsGroupHoldingEveryTab() throws {
        // Intent: the every-tab refusal is about destroying every tab, so
        //   moveTabs makes the same request legal.
        // Why it exists: proves the refusal guards the terminate path, not the
        //   group shape.
        // Scenario: the same model as the refusal above, plus --move-tabs.
        var model = makeModel()
        createTab(&model)
        model.groups.append(GroupModel(id: GroupId(), name: "Empty"))
        let tabsGroupId = model.groups[0].id
        let movedTabIds = model.groups[0].tabs.map(\.id)

        let commands = sendIpc(&model, method: IpcRequestMethod.groupClose.rawValue, params: .object([
            "group": .string(tabsGroupId.rawValue.uuidString),
            "moveTabs": .bool(true),
        ]))

        _ = try requireIpcReply(commands)
        #expect(model.groups.contains(where: { $0.id == tabsGroupId }) == false)
        for tabId in movedTabIds {
            #expect(tabById(tabId, in: model) != nil)
        }
        #expect(model.pendingConfirmation == nil)
    }

    @Test("group.close of an absent group is refused")
    func groupCloseAbsentGroupIsRefused() throws {
        // Intent: an unknown group id fails with `group not found`.
        // Why it exists: pins the existence check ahead of both refusals.
        // Scenario: spec-first unknown id.
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .createGroup(name: "Builds"))
        let before = model

        let commands = sendIpc(&model, method: IpcRequestMethod.groupClose.rawValue, params: .object([
            "group": .string(UUID().uuidString),
        ]))

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(error.message == "group not found")
        #expect(model == before)
    }

    @Test("group.rename sets the group name and replies with it")
    func groupRenameSetsGroupName() throws {
        // Intent: group.rename renames the named group and returns the
        //   resulting name.
        // Why it exists: pins the reply shape a caller asserts against.
        // Scenario: spec-first rename of a second group.
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .createGroup(name: "Builds"))
        let groupId = model.groups[1].id

        let commands = sendIpc(&model, method: IpcRequestMethod.groupRename.rawValue, params: .object([
            "group": .string(groupId.rawValue.uuidString),
            "name": .string("Notes"),
        ]))

        let reply = try requireIpcReply(commands)
        #expect(reply["group"]?["id"]?.asString == groupId.rawValue.uuidString)
        #expect(reply["group"]?["name"]?.asString == "Notes")
        #expect(model.groups[1].name == "Notes")
    }

    @Test("group.rename of an absent group is refused")
    func groupRenameAbsentGroupIsRefused() throws {
        // Intent: an unknown group id fails with `group not found`.
        // Why it exists: pins the existence check to the same error
        //   vocabulary `tab new --group` already uses.
        // Scenario: spec-first unknown id.
        var model = makeModel()
        createTab(&model)
        let before = model

        let commands = sendIpc(&model, method: IpcRequestMethod.groupRename.rawValue, params: .object([
            "group": .string(UUID().uuidString),
            "name": .string("Notes"),
        ]))

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(error.message == "group not found")
        #expect(model == before)
    }

    // Without the dispatch guard this would exit 0 for a rename that never
    // happened: `.renameGroup` silently returns [] when the name normalizes away.
    @Test("group.rename rejects a whitespace-only name and leaves the name intact")
    func groupRenameRejectsWhitespaceOnlyName() throws {
        // Intent: a name that normalizes to nothing is refused with
        //   `invalid name` and the group keeps its old name.
        // Why it exists: a silent no-op would report success to a script.
        // Scenario: spec-first blank rename.
        var model = makeModel()
        createTab(&model)
        let groupId = model.groups[0].id
        let nameBefore = model.groups[0].name

        let commands = sendIpc(&model, method: IpcRequestMethod.groupRename.rawValue, params: .object([
            "group": .string(groupId.rawValue.uuidString),
            "name": .string("   "),
        ]))

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(error.message == "invalid name")
        #expect(model.groups[0].name == nameBefore)
    }

    @Test("group.rename collapses a multiline name to one line")
    func groupRenameCollapsesMultilineName() throws {
        // Intent: a name carrying newlines is accepted and stored as one line.
        // Why it exists: every surface showing a group name lays it out as a
        //   single line, so the CLI must not admit a multiline one.
        // Scenario: spec-first pasted two-line name.
        var model = makeModel()
        createTab(&model)
        let groupId = model.groups[0].id

        let commands = sendIpc(&model, method: IpcRequestMethod.groupRename.rawValue, params: .object([
            "group": .string(groupId.rawValue.uuidString),
            "name": .string("work\n  logs"),
        ]))

        let reply = try requireIpcReply(commands)
        #expect(reply["group"]?["name"]?.asString == "work logs")
        #expect(model.groups[0].name == "work logs")
    }

    @Test("tab.close removes explicit tab")
    func tabCloseRemovesExplicitTab() throws {
        // Intent: tab.close closes the explicit tab and replies with the
        //   closed tab id.
        // Why it exists: pins the CLI close path to the existing tab-close
        //   mutation instead of adding another removal branch.
        // Scenario: spec-first explicit close of a background tab.
        var model = makeModel()
        createTab(&model)
        let closedTabId = selectedTab(in: model)!.id
        createTab(&model)
        let countBefore = totalTabCount(model)

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.tabClose.rawValue,
            params: .object(["tab": .string(closedTabId.rawValue.uuidString)])
        )

        let reply = try requireIpcReply(commands)
        #expect(reply["tab"]?["id"]?.asString == closedTabId.rawValue.uuidString)
        #expect(tabById(closedTabId, in: model) == nil)
        #expect(totalTabCount(model) == countBefore - 1)
    }

    @Test("tab.close closes the named tab after a pane moved")
    func tabCloseDerivesTabFromPaneContext() {
        // Intent: tab.close without an explicit tab closes the tab that
        //   currently owns the IPC context pane.
        // Why it exists: pins the same live pane-to-tab targeting rule as
        //   tab.rename.
        // Scenario: spec-first implicit close from a DanTerm pane context.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .splitFocusedPane(direction: .horizontal))
        createTab(&model)
        let targetTabId = selectedTab(in: model)!.id
        _ = update(&model, .movePaneToTab(paneId: paneId, targetTabId: targetTabId))

        _ = sendIpc(
            &model,
            method: IpcRequestMethod.tabClose.rawValue,
            params: .object(["tab": .string(targetTabId.rawValue.uuidString)]),
            pane: paneId
        )

        #expect(tabForPane(paneId, in: model) == nil)
        #expect(tabById(targetTabId, in: model) == nil)
    }

    @Test("tab.close selects fallback when closing selected tab")
    func tabCloseSelectsFallbackWhenClosingSelected() throws {
        // Intent: closing the selected tab through IPC moves selection to
        //   the same fallback sibling as the UI close path.
        // Why it exists: pins reuse of closeTabBody's fallback-selection
        //   behavior.
        // Scenario: spec-first CLI close of the foreground tab.
        var model = makeModel()
        createTab(&model)
        let fallbackTabId = selectedTab(in: model)!.id
        createTab(&model)
        let closedTabId = selectedTab(in: model)!.id

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.tabClose.rawValue,
            params: .object(["tab": .string(closedTabId.rawValue.uuidString)])
        )

        _ = try requireIpcReply(commands)
        #expect(tabById(closedTabId, in: model) == nil)
        #expect(model.selectedTabId == fallbackTabId)
    }

    @Test("tab.close bypasses confirmation for multi-pane tab")
    func tabCloseBypassesConfirmationForMultiPaneTab() throws {
        // Intent: tab.close closes a non-last multi-pane tab immediately
        //   without a GUI confirmation command.
        // Why it exists: pins routing through .closeTab instead of
        //   .requestCloseTab, whose confirmation sheet cannot be driven by
        //   CLI callers.
        // Scenario: spec-first CLI close of a build tab with two panes.
        var model = makeModel()
        createTab(&model)
        let closedTabId = selectedTab(in: model)!.id
        let paneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .splitPane(paneId: paneId, direction: .horizontal))
        createTab(&model)

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.tabClose.rawValue,
            params: .object(["tab": .string(closedTabId.rawValue.uuidString)])
        )

        _ = try requireIpcReply(commands)
        #expect(tabById(closedTabId, in: model) == nil)
        #expect(model.pendingConfirmation == nil)
        #expect(!hasEffect(commands) {
            if case .showCloseTabConfirmation = $0 { return true }
            return false
        }, "CLI tab.close should not show a close-tab confirmation")
    }

    @Test("quit terminates a launcher pool slot whatever the model is holding")
    func quitTerminatesLauncherPoolSlot() throws {
        // Intent: a slot instance answers quit with the same terminate effect
        //   Cmd-Q produces, and answers it while a confirmation is pending.
        // Why it exists: quit is the agent's only graceful exit, so it must not
        //   inherit the GUI's confirmation gate or leave one stranded behind it.
        // Scenario: a slot-3 instance whose model already has a terminate
        //   confirmation open from an earlier Cmd-Q.
        var model = makeModel()
        createTab(&model)
        model.pendingConfirmation = .terminate
        let env = makeTestEnv(
            instanceIdentity: try #require(DanTermInstanceIdentity(developmentSlot: 3))
        )

        let commands = sendIpc(&model, method: IpcRequestMethod.quit.rawValue, env: env)

        _ = try requireIpcReply(commands)
        #expect(hasEffect(commands, isTerminate))
        #expect(model.pendingConfirmation == .terminate)
    }

    @Test(
        "quit is refused by every instance outside the launcher pool",
        arguments: [
            DanTermInstanceIdentity(bundleIdentifier: "com.danneu.danterm"),
            DanTermInstanceIdentity(bundleIdentifier: "com.danneu.danterm-dev"),
            DanTermInstanceIdentity(bundleIdentifier: "com.example.harness"),
        ]
    )
    func quitRefusedOutsideLauncherPool(_ identity: DanTermInstanceIdentity) throws {
        // Intent: production, the canonical dev app, and any identifier outside
        //   the scheme all refuse quit and emit no terminate effect.
        // Why it exists: this is the guard that keeps the CLI from ending the
        //   user's real sessions, and it is never exercised against production
        //   live -- the run that would find a defect is the run that destroys
        //   the sessions the guard protects.
        // Scenario: one dispatch per identity the pool does not admit.
        var model = makeModel()
        createTab(&model)
        let env = makeTestEnv(instanceIdentity: identity)

        let commands = sendIpc(&model, method: IpcRequestMethod.quit.rawValue, env: env)

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(error.message == "quit is limited to launcher slot instances")
        #expect(!hasEffect(commands, isTerminate))
    }

    @Test("tab.close refuses last tab without pending confirmation")
    func tabCloseRefusesLastTab() throws {
        // Intent: tab.close refuses to close the only remaining tab.
        // Why it exists: routing the last tab through .closeTab would set a
        //   terminate confirmation, leave the tab open, and strand
        //   pendingConfirmation for future close/quit dialogs.
        // Scenario: regression-style CLI close of the last app tab.
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.tabClose.rawValue,
            params: .object(["tab": .string(tabId.rawValue.uuidString)])
        )

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(error.message == "cannot close the last tab")
        #expect(tabById(tabId, in: model) != nil)
        #expect(model.pendingConfirmation == nil)
    }

    @Test("tab.close malformed or unknown explicit tab does not fall back to context")
    func tabCloseMalformedOrUnknownExplicitTab() throws {
        // Intent: explicit tab values that are malformed/unknown/non-
        //   string return -32602; the context tab is not closed.
        // Why it exists: pins the no-fallback guard for explicit tab.
        // Scenario: spec-first malformed/unknown/non-string explicit.
        for tabValue in [JSONValue.string("not-a-uuid"), .string(UUID().uuidString), .number(7)] {
            var model = makeModel()
            createTab(&model)
            let contextTabId = selectedTab(in: model)!.id
            let contextPaneId = selectedTab(in: model)!.focusedPaneId
            let countBefore = totalTabCount(model)

            let commands = sendIpc(
                &model,
                method: IpcRequestMethod.tabClose.rawValue,
                params: .object(["tab": tabValue]),
                pane: contextPaneId
            )

            let error = try requireIpcError(commands)
            #expect(error.code == -32602)
            #expect(tabById(contextTabId, in: model) != nil)
            #expect(totalTabCount(model) == countBefore)
        }
    }

    @Test("tab.close without explicit tab and without pane context fails before mutation")
    func tabCloseWithoutTabAndWithoutContextFails() throws {
        // Intent: with neither an explicit tab nor a pane context,
        //   tab.close errors out before any mutation.
        // Why it exists: pins the "need a target" rule.
        // Scenario: spec-first no-target.
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id

        let commands = sendIpc(&model, method: IpcRequestMethod.tabClose.rawValue, pane: nil)

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(tabById(tabId, in: model) != nil)
    }

    @Test("pane.close removes an explicit pane and reports its id")
    func paneCloseRemovesExplicitPaneAndReportsId() throws {
        // Intent: pane.close routes through the existing pane-close mutation,
        //   promotes the sibling, and replies with the closed pane id.
        // Why it exists: pins the IPC surface to the GUI's model operation
        //   instead of growing a second pane-removal implementation.
        // Scenario: spec-first close of the focused pane in a two-pane tab.
        var model = makeModel()
        createTab(&model)
        let survivorPaneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .splitPane(paneId: survivorPaneId, direction: .horizontal))
        let closedPaneId = selectedTab(in: model)!.focusedPaneId
        let tabId = selectedTab(in: model)!.id

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneClose.rawValue,
            params: .object(["pane": .string(closedPaneId.rawValue.uuidString)])
        )

        let reply = try requireIpcReply(commands)
        #expect(reply["pane"]?["id"]?.asString == closedPaneId.rawValue.uuidString)
        #expect(model.pane(closedPaneId) == nil)
        let tab = try #require(tabById(tabId, in: model))
        #expect(tab.focusedPaneId == survivorPaneId)
        if case .leaf(let survivor) = tab.rootNode {
            #expect(survivor.id == survivorPaneId)
        } else {
            Issue.record("pane.close should promote the surviving sibling")
        }
    }

    @Test("pane.close closes the tab that held its sole pane")
    func paneCloseClosesSolePaneTab() throws {
        // Intent: closing a tab's sole pane cascades through closeTab.
        // Why it exists: pins parity with the existing GUI close semantics.
        // Scenario: spec-first close of a background single-pane tab while a
        //   second tab keeps the app alive.
        var model = makeModel()
        createTab(&model)
        let closedTabId = selectedTab(in: model)!.id
        let closedPaneId = selectedTab(in: model)!.focusedPaneId
        createTab(&model)
        let countBefore = totalTabCount(model)

        _ = try requireIpcReply(sendIpc(
            &model,
            method: IpcRequestMethod.paneClose.rawValue,
            params: .object(["pane": .string(closedPaneId.rawValue.uuidString)])
        ))

        #expect(model.pane(closedPaneId) == nil)
        #expect(tabById(closedTabId, in: model) == nil)
        #expect(totalTabCount(model) == countBefore - 1)
    }

    @Test("pane.close refuses the only pane of the only tab")
    func paneCloseRefusesOnlyPaneOfOnlyTab() throws {
        // Intent: pane.close fails before the last-pane close can enter the
        //   app-termination confirmation path.
        // Why it exists: an IPC success with a surviving pane and stranded
        //   pending confirmation would lie to the caller and block later UI.
        // Scenario: spec-first attempt to close the app's sole pane.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneClose.rawValue,
            params: .object(["pane": .string(paneId.rawValue.uuidString)])
        )

        let error = try requireIpcError(commands)
        #expect(error == .init(code: -32602, message: "cannot close the last pane"))
        #expect(model.pane(paneId) != nil)
        #expect(model.pendingConfirmation == nil)
        #expect(hasEffect(commands) { if case .terminate = $0 { return true }; return false } == false)
    }

    @Test("pane.close bypasses pane and tab todo confirmations")
    func paneCloseBypassesTodoConfirmations() throws {
        // Intent: pane.close dispatches .closePane directly when an affected
        //   pane or its tab carries uncompleted todos.
        // Why it exists: CLI callers cannot drive AppKit confirmation sheets,
        //   and tab.close already establishes the direct-mutation policy.
        // Scenario: spec-first close of one pane in a split task tab, then the
        //   sole pane of a task tab while another tab keeps the app alive.
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let survivorPaneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .splitPane(paneId: survivorPaneId, direction: .horizontal))
        let closedPaneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .addTodo(owner: .pane(closedPaneId), text: "pane task"))
        _ = update(&model, .addTodo(owner: .tab(tabId), text: "tab task"))

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneClose.rawValue,
            params: .object(["pane": .string(closedPaneId.rawValue.uuidString)])
        )

        _ = try requireIpcReply(commands)
        #expect(model.pane(closedPaneId) == nil)
        #expect(hasEffect(commands) {
            if case .showClosePaneConfirmation = $0 { return true }
            if case .showCloseTabConfirmation = $0 { return true }
            return false
        } == false)

        var tabModel = makeModel()
        createTab(&tabModel)
        let closedTabId = selectedTab(in: tabModel)!.id
        let solePaneId = selectedTab(in: tabModel)!.focusedPaneId
        _ = update(&tabModel, .addTodo(owner: .pane(solePaneId), text: "pane task"))
        _ = update(&tabModel, .addTodo(owner: .tab(closedTabId), text: "tab task"))
        createTab(&tabModel)

        let tabCommands = sendIpc(
            &tabModel,
            method: IpcRequestMethod.paneClose.rawValue,
            params: .object(["pane": .string(solePaneId.rawValue.uuidString)])
        )

        _ = try requireIpcReply(tabCommands)
        #expect(tabById(closedTabId, in: tabModel) == nil)
        #expect(hasEffect(tabCommands) {
            if case .showClosePaneConfirmation = $0 { return true }
            if case .showCloseTabConfirmation = $0 { return true }
            return false
        } == false)
    }

    @Test("pane.close requires a valid explicit pane and never falls back to context")
    func paneCloseRejectsMissingMalformedUnknownAndNonStringPane() throws {
        // Intent: every absent or invalid explicit pane is rejected without
        //   using the caller pane context or mutating the model.
        // Why it exists: closing is destructive, so its target must always be
        //   the pane id the caller named.
        // Scenario: spec-first missing, malformed, unknown, and wrong-type ids.
        var model = makeModel()
        createTab(&model)
        let contextPaneId = selectedTab(in: model)!.focusedPaneId
        let context = contextPaneId
        let before = model
        let cases: [JSONValue] = [
            .object([:]),
            .object(["pane": .string("not-a-uuid")]),
            .object(["pane": .string(UUID().uuidString)]),
            .object(["pane": .number(7)]),
        ]

        for params in cases {
            let commands = sendIpc(
                &model,
                method: IpcRequestMethod.paneClose.rawValue,
                params: params,
                pane: context
            )

            #expect(try requireIpcError(commands).code == -32602)
            #expect(model == before)
        }
    }

    @Test("pane.split targets the named pane even when another tab is selected")
    func paneSplitTargetsNamedPaneEvenWhenAnotherTabSelected() throws {
        var model = makeModel()
        createTab(&model)
        let backgroundTabId = selectedTab(in: model)!.id
        let backgroundPaneId = selectedTab(in: model)!.focusedPaneId
        createTab(&model)
        let foregroundTabId = selectedTab(in: model)!.id
        let beforePaneIds = Set(model.allPaneIds)

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneSplit.rawValue,
            params: .object([
                "pane": .string(backgroundPaneId.rawValue.uuidString),
                "direction": .string("horizontal"),
            ])
        )

        #expect(model.selectedTabId == foregroundTabId)
        #expect(allPaneIds(tabById(backgroundTabId, in: model)!.rootNode).count == 2)
        let reply = try requireIpcReply(commands)
        let returnedPaneId = try requirePaneId(reply["pane"]?["id"], "pane.split should return the new pane id")
        #expect(!beforePaneIds.contains(returnedPaneId), "returned pane id should be new")
        #expect(Set(model.allPaneIds).subtracting(beforePaneIds) == Set([returnedPaneId]))
    }

    @Test("pane.split explicit pane targets sibling instead of caller context")
    func paneSplitExplicitPaneTargetsSibling() throws {
        // Intent: an explicit pane param wins over the caller context.
        // Why it exists: pins the explicit-wins for pane.split.
        // Scenario: spec-first explicit pane.
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let callerPaneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .splitPane(paneId: callerPaneId, direction: .horizontal))
        let siblingPaneId = selectedTab(in: model)!.focusedPaneId
        let beforePaneIds = Set(model.allPaneIds)

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneSplit.rawValue,
            params: .object([
                "pane": .string(siblingPaneId.rawValue.uuidString),
                "direction": .string("vertical"),
            ]),
            pane: callerPaneId
        )

        let reply = try requireIpcReply(commands)
        let returnedPaneId = try requirePaneId(reply["pane"]?["id"], "pane.split should return the sibling split pane id")
        #expect(!beforePaneIds.contains(returnedPaneId), "returned pane id should be new")
        #expect(Set(model.allPaneIds).subtracting(beforePaneIds) == Set([returnedPaneId]))
        guard case .split(_, .horizontal, .leaf(let first), .split(_, .vertical, .leaf(let second), .leaf(let third), _), _) =
            tabById(tabId, in: model)!.rootNode
        else {
            Issue.record("expected explicit sibling pane to be split")
            return
        }
        #expect(first.id == callerPaneId)
        #expect(second.id == siblingPaneId)
        #expect(third.id == returnedPaneId)
    }

    @Test("pane.split malformed explicit pane does not fall back to context")
    func paneSplitMalformedExplicitPaneNoFallback() throws {
        // Intent: a malformed explicit pane returns -32602; the model
        //   is unchanged.
        // Why it exists: pins the no-fallback rule.
        // Scenario: spec-first malformed explicit.
        var model = makeModel()
        createTab(&model)
        let callerPaneId = selectedTab(in: model)!.focusedPaneId
        let beforePaneIds = Set(model.allPaneIds)

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneSplit.rawValue,
            params: .object([
                "pane": .string("not-a-uuid"),
                "direction": .string("horizontal"),
            ]),
            pane: callerPaneId
        )

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(Set(model.allPaneIds) == beforePaneIds)
    }

    @Test("pane.split non-string explicit pane does not fall back to context")
    func paneSplitNonStringExplicitPaneNoFallback() throws {
        // Intent: a non-string explicit pane returns -32602 with a
        //   "pane must be a string" message.
        // Why it exists: pins the type-check message.
        // Scenario: spec-first non-string explicit.
        var model = makeModel()
        createTab(&model)
        let callerPaneId = selectedTab(in: model)!.focusedPaneId
        let beforePaneIds = Set(model.allPaneIds)

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneSplit.rawValue,
            params: .object([
                "pane": .number(42),
                "direction": .string("horizontal"),
            ]),
            pane: callerPaneId
        )

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(error.message.contains("pane must be a string"),
            "message should describe non-string pane, got: \(error.message)")
        #expect(Set(model.allPaneIds) == beforePaneIds)
    }

    @Test("pane.split unknown explicit pane does not fall back to context")
    func paneSplitUnknownExplicitPaneNoFallback() throws {
        // Intent: an unknown UUID explicit pane returns -32602; the
        //   model is unchanged.
        // Why it exists: pins the unknown-id no-fallback rule.
        // Scenario: spec-first unknown explicit.
        var model = makeModel()
        createTab(&model)
        let callerPaneId = selectedTab(in: model)!.focusedPaneId
        let beforePaneIds = Set(model.allPaneIds)

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneSplit.rawValue,
            params: .object([
                "pane": .string(UUID().uuidString),
                "direction": .string("horizontal"),
            ]),
            pane: callerPaneId
        )

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(Set(model.allPaneIds) == beforePaneIds)
    }

    @Test("pane.split without explicit pane and without pane context fails before mutation")
    func paneSplitNoExplicitAndNoContextFails() throws {
        // Intent: with no explicit pane and no pane context,
        //   pane.split errors out.
        // Why it exists: pins the "need a target" rule.
        // Scenario: spec-first no-target.
        var model = makeModel()
        createTab(&model)
        let beforePaneIds = Set(model.allPaneIds)

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneSplit.rawValue,
            params: .object(["direction": .string("horizontal")]),
            pane: nil
        )

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(Set(model.allPaneIds) == beforePaneIds)
    }

    @Test("pane.split on a pane id absent from every tree is rejected without mutation")
    func paneSplitOnPaneAbsentFromAllTreesRejected() throws {
        // Intent: a context pane id absent from every tree is rejected;
        //   no mutation.
        // Why it exists: pins the orphan-pane fail-closed (with tree-
        //   owns-panes, the drift hole is structurally closed).
        // Scenario: spec-first orphan pane.
        var model = makeModel()
        createTab(&model)
        let unknownPaneId = PaneId()
        let beforePaneIds = Set(model.allPaneIds)

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneSplit.rawValue,
            params: .object(["direction": .string("horizontal")]),
            pane: unknownPaneId
        )

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(Set(model.allPaneIds) == beforePaneIds)
    }

    @Test("pane.focus selects target tab and projects its responder")
    func paneFocusSelectsTabAndProjectsResponder() throws {
        // Intent: pane.focus selects the target's tab and records the pane target.
        // Why it exists: pins the focus-cross-tab path.
        // Scenario: spec-first cross-tab focus.
        var model = makeModel()
        createTab(&model)
        let targetTabId = selectedTab(in: model)!.id
        let targetPaneId = selectedTab(in: model)!.focusedPaneId
        createTab(&model)

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneFocus.rawValue,
            params: .object(["pane": .string(targetPaneId.rawValue.uuidString)])
        )

        #expect(model.selectedTabId == targetTabId)
        let reply = try requireIpcReply(commands)
        #expect(reply["tab"]?["id"]?.asString == targetTabId.rawValue.uuidString)
        #expect(reply["tab"]?["focusedPaneId"]?.asString == targetPaneId.rawValue.uuidString)
        #expect(desiredPaneFocus(in: model) == .terminal(targetPaneId))
    }

    @Test("pane.focus replies with same-tab focusedPaneId synchronously")
    func paneFocusRepliesWithSameTabFocusedSync() throws {
        // Intent: a same-tab focus change reflects in the reply's
        //   focusedPaneId and the live tab's focusedPaneId.
        // Why it exists: pins the synchronous-update rule.
        // Scenario: spec-first same-tab focus.
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let firstPaneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let secondPaneId = selectedTab(in: model)!.focusedPaneId
        updateTabForTest(tabId, in: &model) { $0.focusedPaneId = firstPaneId }

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneFocus.rawValue,
            params: .object(["pane": .string(secondPaneId.rawValue.uuidString)])
        )

        let reply = try requireIpcReply(commands)
        #expect(reply["tab"]?["focusedPaneId"]?.asString == secondPaneId.rawValue.uuidString)
        #expect(tabById(tabId, in: model)?.focusedPaneId == secondPaneId)
    }

    @Test("pane.focus preserves popover on same-tab focus in unzoomed tab")
    func paneFocusPreservesPopoverOnSameTabFocus() {
        // Intent: same-tab focus change does NOT clear an open todo
        //   popover.
        // Why it exists: pins the popover-preserve rule for same-tab
        //   focus.
        // Scenario: spec-first popover preserve.
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let firstPaneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let secondPaneId = selectedTab(in: model)!.focusedPaneId
        updateTabForTest(tabId, in: &model) { $0.focusedPaneId = firstPaneId }
        model.todoPopover = .pane(firstPaneId)

        _ = sendIpc(
            &model,
            method: IpcRequestMethod.paneFocus.rawValue,
            params: .object(["pane": .string(secondPaneId.rawValue.uuidString)]),
            pane: selectedPaneId(in: model)
        )

        #expect(model.todoPopover == .pane(firstPaneId))
        #expect(tabById(tabId, in: model)?.focusedPaneId == secondPaneId)
    }

    @Test("pane.focus clears target pane alerts in focus mode")
    func paneFocusClearsTargetPaneAlertsInFocusMode() {
        // Intent: pane.focus in focus alert-clear mode marks the
        //   target's alerts read.
        // Why it exists: pins the alert-clear semantics for IPC focus.
        // Scenario: spec-first IPC focus mode clear.
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
            method: IpcRequestMethod.paneFocus.rawValue,
            params: .object(["pane": .string(secondPaneId.rawValue.uuidString)])
        )

        #expect(model.alerts[0].isUnread == false, "focusing pane should mark its alerts read")
    }

    @Test("pane.focus requires an explicit pane")
    func paneFocusRequiresExplicitPane() throws {
        // Intent: pane.focus does not fall back to IPC pane context.
        // Why it exists: pins the explicit-required policy while the
        //   implementation moves through the generic resolver.
        // Scenario: spec-first no explicit focus target.
        var model = makeModel()
        createTab(&model)
        let commands = sendIpc(&model, method: IpcRequestMethod.paneFocus.rawValue)

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(error.message == "pane required")
    }

    @Test("pane.focus rejects non-string pane")
    func paneFocusRejectsNonStringPane() throws {
        // Intent: pane.focus rejects non-string explicit panes with the
        //   shared pane-target vocabulary.
        // Why it exists: pins the generic resolver's type error for an
        //   explicit-required command.
        // Scenario: spec-first malformed explicit focus target.
        for paneValue in [JSONValue.number(5), .array([]), .object([:])] {
            var model = makeModel()
            createTab(&model)

            let commands = sendIpc(
                &model,
                method: IpcRequestMethod.paneFocus.rawValue,
                params: .object(["pane": paneValue])
            )

            let error = try requireIpcError(commands)
            #expect(error.code == -32602)
            #expect(error.message == "pane must be a string")
        }
    }

    @Test("pane.focus rejects unknown pane")
    func paneFocusRejectsUnknownPane() throws {
        // Intent: pane.focus rejects malformed or stale explicit pane
        //   strings with "pane not found".
        // Why it exists: replaces the older catch-all "invalid pane id"
        //   branch with the shared resolver vocabulary.
        // Scenario: spec-first unknown explicit focus target.
        for rawPane in ["bogus", UUID().uuidString] {
            var model = makeModel()
            createTab(&model)

            let commands = sendIpc(
                &model,
                method: IpcRequestMethod.paneFocus.rawValue,
                params: .object(["pane": .string(rawPane)])
            )

            let error = try requireIpcError(commands)
            #expect(error.code == -32602)
            #expect(error.message == "pane not found")
        }
    }

    @Test("tab.new explicit group id creates tab in that group")
    func tabNewExplicitGroupIdCreatesTab() throws {
        // Intent: tab.new with an explicit group id creates a tab
        //   there; the reply includes tab + group + panes.
        // Why it exists: pins the explicit-group path.
        // Scenario: spec-first explicit group.
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .createGroup(name: "Builds"))
        let groupId = model.groups.last!.id
        let countBefore = model.groups.last!.tabs.count
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.tabNew.rawValue,
            params: .object(["group": .string(groupId.rawValue.uuidString)])
        )
        let group = model.groups.first(where: { $0.id == groupId })
        #expect(group?.tabs.count == countBefore + 1)
        let reply = try requireIpcReply(commands)
        #expect(reply["tab"]?["id"]?.asString != nil, "reply should include tab id")
        #expect(reply["group"]?["id"]?.asString == groupId.rawValue.uuidString)
        #expect(reply["group"]?["name"]?.asString == "Builds")
        #expect(reply["panes"]?.asArray?.count == 1)
    }

    @Test("tab.new returns the explicit entity document from the core encoder")
    func tabNewReturnsExplicitEntityDocument() throws {
        let groupId = GroupId(rawValue: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        let paneId = PaneId(rawValue: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)
        let sessionId = SessionId(rawValue: UUID(uuidString: "22222222-2222-4222-8222-222222222223")!)
        let tabId = TabId(rawValue: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!)
        var model = AppModel(groups: [GroupModel(id: groupId, name: "Builds")])
        let env = makeTestEnv(idSequence: [paneId.rawValue, sessionId.rawValue, tabId.rawValue])

        let result = try requireIpcReply(sendIpc(
            &model,
            method: IpcRequestMethod.tabNew.rawValue,
            params: .object([
                "group": .string(groupId.rawValue.uuidString),
                "launch": .object([
                    "cwd": .string("/Users/testhome/project"),
                    "title": .string("tests"),
                ]),
            ]),
            env: env
        ))
        let expected: JSONValue = .object([
            "tab": .object([
                "id": .string(tabId.rawValue.uuidString),
                "customTitle": .string("tests"),
                "focusedPaneId": .string(paneId.rawValue.uuidString),
                "rootNode": .object([
                    "type": .string("leaf"),
                    "pane": .object([
                        "id": .string(paneId.rawValue.uuidString),
                        "title": .string("tests"),
                    ]),
                ]),
            ]),
            "panes": .array([.object(["id": .string(paneId.rawValue.uuidString)])]),
            "group": .object([
                "id": .string(groupId.rawValue.uuidString),
                "name": .string("Builds"),
            ]),
        ])
        #expect(result == expected)
    }

    @Test("tab.new uses its named group despite an unrelated pane param")
    func tabNewUsesNamedGroupDespiteUnrelatedPaneParam() throws {
        var model = makeModel()
        createTab(&model)
        let callerGroupId = model.groups[0].id
        let callerPaneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .createGroup(name: "Builds"))
        let explicitGroupId = model.groups.last!.id
        let callerCountBefore = model.groups.first(where: { $0.id == callerGroupId })!.tabs.count
        let explicitCountBefore = model.groups.first(where: { $0.id == explicitGroupId })!.tabs.count

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.tabNew.rawValue,
            params: .object(["group": .string(explicitGroupId.rawValue.uuidString)]),
            pane: callerPaneId
        )

        #expect(model.groups.first(where: { $0.id == callerGroupId })?.tabs.count == callerCountBefore)
        #expect(model.groups.first(where: { $0.id == explicitGroupId })?.tabs.count == explicitCountBefore + 1)
        #expect(try requireIpcReply(commands)["group"]?["id"]?.asString == explicitGroupId.rawValue.uuidString)
    }

    @Test("tab.new malformed or unknown explicit group does not fall back or create")
    func tabNewMalformedOrUnknownExplicitGroupNoFallback() throws {
        // Intent: malformed/unknown/non-string explicit group returns
        //   -32602; no group or tab is created.
        // Why it exists: pins the no-fallback rule for explicit group.
        // Scenario: spec-first malformed/unknown/non-string explicit.
        for groupValue in [JSONValue.string("not-a-uuid"), .string(UUID().uuidString), .number(7)] {
            var model = makeModel()
            createTab(&model)
            let contextPaneId = selectedTab(in: model)!.focusedPaneId
            let groupsBefore = model.groups.count
            let tabsBefore = model.groups.flatMap(\.tabs).count

            let commands = sendIpc(
                &model,
                method: IpcRequestMethod.tabNew.rawValue,
                params: .object(["group": groupValue]),
                pane: contextPaneId
            )

            let error = try requireIpcError(commands)
            #expect(error.code == -32602)
            #expect(model.groups.count == groupsBefore)
            #expect(model.groups.flatMap(\.tabs).count == tabsBefore)
        }
    }

    @Test("tab.new does not infer a group from a supplied pane")
    func tabNewDoesNotInferGroupFromPane() throws {
        var model = makeModel()
        createTab(&model)
        let callerPaneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .createGroup(name: "Other"))
        let tabsBefore = model.groups.flatMap(\.tabs).count

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.tabNew.rawValue,
            params: .object([:]),
            pane: callerPaneId
        )

        #expect(try requireIpcError(commands).message == "group required")
        #expect(model.groups.flatMap(\.tabs).count == tabsBefore)
    }

    @Test("tab.new without explicit group and without pane context fails before mutation")
    func tabNewWithoutGroupAndContextFails() throws {
        // Intent: tab.new with neither explicit group nor pane context
        //   errors out.
        // Why it exists: pins the "need a group" rule.
        // Scenario: spec-first no group.
        var model = makeModel()
        createTab(&model)
        let tabsBefore = model.groups.flatMap(\.tabs).count
        let commands = sendIpc(&model, method: IpcRequestMethod.tabNew.rawValue, params: .object([:]), pane: nil)
        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(model.groups.flatMap(\.tabs).count == tabsBefore)
    }

    @Test("tab and group explicit target errors use uniform vocabulary")
    func tabAndGroupExplicitTargetErrorsUseUniformVocabulary() throws {
        // Intent: tab and group resolvers use the same explicit-target
        //   vocabulary as panes.
        // Why it exists: locks the message contract before the call
        //   sites move behind a generic resolver.
        // Scenario: spec-first explicit target errors for tab.rename
        //   and tab.new group routing.
        struct TargetCase {
            let entity: String
            let method: String
            let explicitParams: (JSONValue) -> JSONValue
            let absentParams: JSONValue
        }

        let targetCases = [
            TargetCase(
                entity: "tab",
                method: IpcRequestMethod.tabRename.rawValue,
                explicitParams: { .object(["tab": $0, "title": .string("build")]) },
                absentParams: .object(["title": .string("build")])
            ),
            TargetCase(
                entity: "group",
                method: IpcRequestMethod.tabNew.rawValue,
                explicitParams: { .object(["group": $0]) },
                absentParams: .object([:])
            ),
        ]

        for targetCase in targetCases {
            var nonStringModel = makeModel()
            createTab(&nonStringModel)
            let nonStringCommands = sendIpc(
                &nonStringModel,
                method: targetCase.method,
                params: targetCase.explicitParams(.number(7)),
                pane: selectedPaneId(in: nonStringModel)
            )
            let nonStringError = try requireIpcError(nonStringCommands)
            #expect(nonStringError.code == -32602)
            #expect(nonStringError.message == "\(targetCase.entity) must be a string")

            var unknownModel = makeModel()
            createTab(&unknownModel)
            let unknownCommands = sendIpc(
                &unknownModel,
                method: targetCase.method,
                params: targetCase.explicitParams(.string(UUID().uuidString)),
                pane: selectedPaneId(in: unknownModel)
            )
            let unknownError = try requireIpcError(unknownCommands)
            #expect(unknownError.code == -32602)
            #expect(unknownError.message == "\(targetCase.entity) not found")

            var absentModel = makeModel()
            createTab(&absentModel)
            let absentCommands = sendIpc(
                &absentModel,
                method: targetCase.method,
                params: targetCase.absentParams,
                pane: nil
            )
            let absentError = try requireIpcError(absentCommands)
            #expect(absentError.code == -32602)
            #expect(absentError.message == "\(targetCase.entity) required")
        }
    }

    @Test("tab.new background does not steal selection")
    func tabNewBackgroundDoesNotStealSelection() throws {
        // Intent: a background tab.new returns the new tab id but does
        //   NOT change selection.
        // Why it exists: pins the background invariant.
        // Scenario: spec-first background tab.new.
        var model = makeModel()
        createTab(&model)
        let selectedTabId = selectedTab(in: model)!.id
        let groupId = model.groups[0].id

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.tabNew.rawValue,
            params: .object([
                "group": .string(groupId.rawValue.uuidString),
                "background": .bool(true),
            ])
        )

        #expect(model.selectedTabId == selectedTabId, "background tab.new should not change selected tab")
        let reply = try requireIpcReply(commands)
        #expect(reply["tab"]?["id"]?.asString != nil, "reply should include new tab id")
        #expect(reply["group"]?["id"]?.asString == groupId.rawValue.uuidString)
    }

    @Test("tab.new with malformed background fails before mutation")
    func tabNewWithMalformedBackgroundFails() throws {
        // Intent: a non-bool background parameter returns -32602; no
        //   mutation.
        // Why it exists: pins the type check.
        // Scenario: spec-first malformed background.
        var model = makeModel()
        createTab(&model)
        let groupId = model.groups[0].id
        let paneIdsBefore = Set(model.allPaneIds)
        let tabsBefore = model.groups.flatMap(\.tabs).map(\.id)

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.tabNew.rawValue,
            params: .object([
                "group": .string(groupId.rawValue.uuidString),
                "background": .string("true"),
            ])
        )

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(Set(model.allPaneIds) == paneIdsBefore)
        #expect(model.groups.flatMap(\.tabs).map(\.id) == tabsBefore)
    }

    @Test("tab.new without cwd uses home rather than any pane cwd")
    func tabNewWithoutCwdUsesHome() throws {
        for background in [true, false] {
            var model = makeModel()
            createTab(&model)
            let selectedTabId = selectedTab(in: model)!.id
            let selectedPaneId = selectedTab(in: model)!.focusedPaneId
            model.updatePane(selectedPaneId) { $0.session?.cwd = "/selected" }
            createTab(&model)
            let callerPaneId = selectedTab(in: model)!.focusedPaneId
            model.updatePane(callerPaneId) { $0.session?.cwd = "/caller" }
            _ = update(&model, .selectTab(id: selectedTabId))
            let groupId = model.groups[0].id
            let env = CoreEnv(
                newId: { UUID() },
                now: { Date(timeIntervalSince1970: 1_700_000_000) },
                homeDirectory: { "/home" },
                instanceIdentity: { DanTermInstanceIdentity(bundleIdentifier: "com.danneu.danterm") }
            )

            let commands = sendIpc(
                &model,
                method: IpcRequestMethod.tabNew.rawValue,
                params: .object([
                    "group": .string(groupId.rawValue.uuidString),
                    "background": .bool(background),
                ]),
                pane: callerPaneId,
                env: env
            )

            let reply = try requireIpcReply(commands)
            let paneId = try requirePaneId(reply["panes"]?.asArray?.first?["id"], "tab.new should return pane id")
            #expect(hasEffect(commands) {
                if case .createSession(_, let effectPaneId, let cwd, _, _) = $0 {
                    return effectPaneId == paneId && cwd == "/home"
                }
                return false
            }, "tab.new should use home without an explicit cwd")
        }
    }

    @Test("tab.new with launch seeds shell input and custom tab title")
    func tabNewWithLaunchSeedsShellInputAndCustomTitle() throws {
        // Intent: tab.new with a launch object seeds shell input, sets
        //   custom title, and emits createSession with the documented
        //   shape (command + waitAfterCommand=true).
        // Why it exists: pins the launch wiring.
        // Scenario: spec-first launch shell input.
        var model = makeModel()
        createTab(&model)
        let paneIdInContext = selectedTab(in: model)!.focusedPaneId
        let groupId = model.groups[0].id
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.tabNew.rawValue,
            params: .object([
                "group": .string(groupId.rawValue.uuidString),
                "launch": .object([
                    "cmd": .string("date"),
                    "cwd": .string("/tmp"),
                    "title": .string("clock"),
                ])
            ]),
            pane: paneIdInContext
        )

        let reply = try requireIpcReply(commands)
        let tabId = try requireTabId(reply["tab"]?["id"], "tab.new should return tab id")
        let paneId = try requirePaneId(reply["panes"]?.asArray?.first?["id"], "tab.new should return pane id")
        #expect(reply["tab"]?["focusedPaneId"]?.asString == paneId.rawValue.uuidString)
        #expect(reply["tab"]?["rootNode"]?["pane"]?["id"]?.asString == paneId.rawValue.uuidString)
        #expect(reply["panes"]?.asArray?.first?.asObject?.keys.count == 1)
        #expect(tabById(tabId, in: model)?.customTitle == "clock")
        #expect(tabById(tabId, in: model).map { tabDisplayTitle($0) } == "clock")
        #expect(model.pane(paneId)?.session?.title == "clock")
        #expect(hasEffect(commands) {
            if case .createSession(_, let effectPaneId, let cwd, let command, let launchCommand) = $0 {
                return effectPaneId == paneId
                    && cwd == "/tmp"
                    && command == "date"
                    && launchCommand == nil
            }
            return false
        }, "expected createSession with shell input command")
    }

    @Test("tab.new with explicit group id forwards launch to created tab")
    func tabNewWithExplicitGroupForwardsLaunch() {
        // Intent: launch payload reaches the created tab even when an
        //   explicit group is supplied.
        // Why it exists: pins the explicit-group + launch combo.
        // Scenario: spec-first launch with group.
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .createGroup(name: "Builds"))
        let groupId = model.groups.last!.id

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.tabNew.rawValue,
            params: .object([
                "group": .string(groupId.rawValue.uuidString),
                "launch": .object(["cmd": .string("make test")]),
            ])
        )

        let group = model.groups.first(where: { $0.id == groupId })
        let paneId = group?.tabs.last?.focusedPaneId
        #expect(paneId != nil, "target group should have a new tab")
        #expect(hasEffect(commands) {
            if case .createSession(_, let effectPaneId, _, let command, let launchCommand) = $0 {
                return effectPaneId == paneId && command == "make test" && launchCommand == nil
            }
            return false
        }, "expected shell input command to reach group-created tab")
    }

    @Test("tab.new afterTab without group uses referenced tab group without pane context")
    func tabNewAfterTabWithoutGroupUsesReferencedTabGroup() throws {
        // Intent: tab.new with afterTab and no group uses the
        //   referenced tab's group (no pane context needed).
        // Why it exists: pins the afterTab-implies-group rule.
        // Scenario: spec-first afterTab no group.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let refTabId = model.groups[0].tabs[0].id
        let targetGroupId = model.groups[0].id
        _ = update(&model, .createGroup(name: "Other"))
        let beforeGroupTabs = groupTabIds(in: model)
        let panesBefore = Set(model.allPaneIds)

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.tabNew.rawValue,
            params: .object([
                "position": .string("afterTab"),
                "afterTabId": .string(refTabId.rawValue.uuidString),
            ])
        )

        let reply = try requireIpcReply(commands)
        try expectAfterTabInserted(
            reply: reply,
            in: model,
            targetGroupId: targetGroupId,
            refTabId: refTabId,
            beforeGroupTabs: beforeGroupTabs,
            panesBefore: panesBefore
        )
    }

    @Test("tab.new rejects both group and afterTab anchors")
    func tabNewRejectsBothGroupAndAfterTabAnchors() throws {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let refTabId = model.groups[0].tabs[0].id
        let targetGroupId = model.groups[0].id
        let tabsBefore = groupTabIds(in: model)

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.tabNew.rawValue,
            params: .object([
                "group": .string(targetGroupId.rawValue.uuidString),
                "position": .string("afterTab"),
                "afterTabId": .string(refTabId.rawValue.uuidString),
            ])
        )

        #expect(try requireIpcError(commands).message == "tab.new requires exactly one of group or afterTabId")
        #expect(groupTabIds(in: model) == tabsBefore)
    }

    @Test("tab.new afterTab with different explicit group fails before mutation")
    func tabNewAfterTabWithDifferentExplicitGroupFails() throws {
        // Intent: afterTab + a different explicit group fails before
        //   mutation.
        // Why it exists: pins the conflict-rejected rule.
        // Scenario: spec-first afterTab vs explicit group conflict.
        var model = makeModel()
        createTab(&model)
        let refTabId = model.groups[0].tabs[0].id
        _ = update(&model, .createGroup(name: "Other"))
        let otherGroupId = model.groups[1].id
        let before = model

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.tabNew.rawValue,
            params: .object([
                "group": .string(otherGroupId.rawValue.uuidString),
                "position": .string("afterTab"),
                "afterTabId": .string(refTabId.rawValue.uuidString),
            ])
        )

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(model == before)
    }

    @Test("tab.new afterTab invalid params fail before mutation")
    func tabNewAfterTabInvalidParamsFail() throws {
        // Intent: a variety of invalid afterTab parameter shapes all
        //   fail before mutation.
        // Why it exists: pins the comprehensive invalid-input fail-
        //   closed rules.
        // Scenario: spec-first afterTab invalid params (8 cases).
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

            let commands = sendIpc(&model, method: IpcRequestMethod.tabNew.rawValue, params: .object(params))

            let error = try requireIpcError(commands)
            #expect(error.code == -32602)
            #expect(model == before)
        }
    }

    @Test("pane.split with launch title sets pane title without tab custom title")
    func paneSplitWithLaunchTitleSetsPaneTitleNoTabCustom() throws {
        // Intent: pane.split with a launch.title sets the new pane's
        //   title; tab.customTitle stays nil.
        // Why it exists: pins launch.title as the new session's initial title.
        // Scenario: spec-first split launch title.
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let paneId = selectedTab(in: model)!.focusedPaneId

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneSplit.rawValue,
            params: .object([
                "direction": .string("horizontal"),
                "launch": .object([
                    "cmd": .string("cargo --version"),
                    "cwd": .string("/tmp"),
                    "title": .string("cargo"),
                ]),
            ]),
            pane: paneId
        )

        let newPaneId = try requirePaneId(try requireIpcReply(commands)["pane"]?["id"], "pane.split should return pane id")
        #expect(model.pane(newPaneId)?.session?.title == "cargo")
        #expect(tabById(tabId, in: model)?.customTitle == nil)
        #expect(hasEffect(commands) {
            if case .createSession(_, let effectPaneId, let cwd, let command, let launchCommand) = $0 {
                return effectPaneId == newPaneId
                    && cwd == "/tmp"
                    && command == "cargo --version"
                    && launchCommand == nil
            }
            return false
        }, "expected split createSession to seed shell input")
    }

    @Test("pane.split background on selected tab preserves focused pane")
    func paneSplitBackgroundOnSelectedTabPreservesFocus() throws {
        // Intent: a background pane.split on the selected tab adds a
        //   pane but does NOT change focus.
        // Why it exists: pins the background-focus invariant for
        //   pane.split on the selected tab.
        // Scenario: spec-first background split selected.
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let focusedPaneId = selectedTab(in: model)!.focusedPaneId

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneSplit.rawValue,
            params: .object([
                "direction": .string("horizontal"),
                "background": .bool(true),
            ]),
            pane: focusedPaneId
        )

        let reply = try requireIpcReply(commands)
        let newPaneId = try requirePaneId(reply["pane"]?["id"], "pane.split should return pane id")
        let tab = tabById(tabId, in: model)!
        #expect(allPaneIds(tab.rootNode).contains(newPaneId), "target tab should contain new pane")
        #expect(tab.focusedPaneId == focusedPaneId, "background split should preserve focused pane")
        #expect(model.selectedTabId == tabId, "background split should not change selected tab")
    }

    @Test("pane.split background on unselected tab emits scoped rebuild")
    func paneSplitBackgroundOnUnselectedTabEmitsScopedRebuild() throws {
        // Intent: background split on a non-selected tab adds a pane
        //   there; selection and target focus stay intact.
        // Why it exists: pins the per-tab scoped rebuild contract.
        // Scenario: spec-first background split unselected.
        var model = makeModel()
        createTab(&model)
        let selectedTabId = selectedTab(in: model)!.id
        createTab(&model)
        let backgroundTabId = selectedTab(in: model)!.id
        let backgroundPaneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .selectTab(id: selectedTabId))

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneSplit.rawValue,
            params: .object([
                "direction": .string("horizontal"),
                "background": .bool(true),
            ]),
            pane: backgroundPaneId
        )

        let reply = try requireIpcReply(commands)
        let newPaneId = try requirePaneId(reply["pane"]?["id"], "pane.split should return pane id")
        let backgroundTab = tabById(backgroundTabId, in: model)!
        #expect(allPaneIds(backgroundTab.rootNode).contains(newPaneId), "background tab should contain new pane")
        #expect(backgroundTab.focusedPaneId == backgroundPaneId, "background split should preserve target focus")
        #expect(model.selectedTabId == selectedTabId, "background split should not change selected tab")
    }

    @Test("pane.split with malformed background fails before mutation")
    func paneSplitWithMalformedBackgroundFails() throws {
        // Intent: a non-bool background parameter returns -32602; no
        //   mutation.
        // Why it exists: pins the type check.
        // Scenario: spec-first malformed background.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let paneIdsBefore = Set(model.allPaneIds)

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneSplit.rawValue,
            params: .object([
                "direction": .string("horizontal"),
                "background": .string("true"),
            ]),
            pane: paneId
        )

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(Set(model.allPaneIds) == paneIdsBefore)
    }

    @Test("malformed launch returns invalid params without mutation commands")
    func malformedLaunchReturnsInvalidParamsWithoutMutation() throws {
        // Intent: a malformed launch param fails both tab.new and
        //   pane.split paths before any mutation; no createSession
        //   command leaks.
        // Why it exists: pins fail-closed for malformed launch.
        // Scenario: spec-first malformed launch.
        let launchValues: [JSONValue] = [
            .string("bad"),
            .object(["cmd": .number(42)]),
        ]
        for launchValue in launchValues {
            var model = makeModel()
            createTab(&model)
            let contextPaneId = selectedTab(in: model)!.focusedPaneId
            let paneIdsBefore = Set(model.allPaneIds)
            let tabEffects = sendIpc(
                &model,
                method: IpcRequestMethod.tabNew.rawValue,
                params: .object(["launch": launchValue])
            )
            #expect(try requireIpcError(tabEffects).code == -32602)
            #expect(Set(model.allPaneIds) == paneIdsBefore)
            #expect(!hasEffect(tabEffects) {
                if case .createSession = $0 { return true }
                return false
            }, "malformed tab.new launch should not create a session")

            let splitEffects = sendIpc(
                &model,
                method: IpcRequestMethod.paneSplit.rawValue,
                params: .object([
                    "direction": .string("horizontal"),
                    "launch": launchValue,
                ]),
                pane: contextPaneId
            )
            #expect(try requireIpcError(splitEffects).code == -32602)
            #expect(Set(model.allPaneIds) == paneIdsBefore)
            #expect(!hasEffect(splitEffects) {
                if case .createSession = $0 { return true }
                return false
            }, "malformed pane.split launch should not create a session")
        }
    }

    @Test("theme.set updates pane override and clears with null")
    func themeSetUpdatesPaneOverrideClearsWithNull() throws {
        // Intent: theme.set sets pane.theme; null clears it.
        // Why it exists: pins the theme.set round-trip.
        // Scenario: spec-first theme set + clear.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let ctx = paneId

        let setEffects = sendIpc(&model, method: IpcRequestMethod.themeSet.rawValue, params: .object(["themeName": .string("Tokyo Night")]), pane: ctx)
        #expect(model.pane(paneId)?.theme == "Tokyo Night")
        #expect(try requireIpcReply(setEffects)["pane"]?["theme"]?.asString == "Tokyo Night")

        let clearEffects = sendIpc(&model, method: IpcRequestMethod.themeSet.rawValue, params: .object(["themeName": .null]), pane: ctx)
        #expect(model.pane(paneId)?.theme == nil)
        #expect(try requireIpcReply(clearEffects)["pane"]?["theme"] == .null)
    }

    @Test("theme.set explicit pane targets that pane regardless of context")
    func themeSetExplicitPaneTargetsRegardlessOfContext() throws {
        // Intent: an explicit pane param overrides the IPC context.
        // Why it exists: pins explicit-wins for theme.set.
        // Scenario: spec-first theme explicit pane.
        var model = makeModel()
        createTab(&model)
        let targetPaneId = selectedTab(in: model)!.focusedPaneId
        createTab(&model)
        let contextPaneId = selectedTab(in: model)!.focusedPaneId

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.themeSet.rawValue,
            params: .object([
                "pane": .string(targetPaneId.rawValue.uuidString),
                "themeName": .string("Tokyo Night"),
            ]),
            pane: contextPaneId
        )

        #expect(model.pane(targetPaneId)?.theme == "Tokyo Night")
        #expect(model.pane(contextPaneId)?.theme == nil)
        #expect(try requireIpcReply(commands)["pane"]?["id"]?.asString == targetPaneId.rawValue.uuidString)
    }

    @Test("theme.set malformed or unknown explicit pane does not fall back to context")
    func themeSetMalformedOrUnknownExplicitPaneNoFallback() throws {
        // Intent: malformed/unknown/non-string explicit pane returns
        //   -32602; context pane is not affected.
        // Why it exists: pins no-fallback for theme.set.
        // Scenario: spec-first malformed/unknown explicit.
        for paneValue in [JSONValue.string("not-a-uuid"), .string(UUID().uuidString), .number(7)] {
            var model = makeModel()
            createTab(&model)
            let contextPaneId = selectedTab(in: model)!.focusedPaneId

            let commands = sendIpc(
                &model,
                method: IpcRequestMethod.themeSet.rawValue,
                params: .object([
                    "pane": paneValue,
                    "themeName": .string("Tokyo Night"),
                ]),
                pane: contextPaneId
            )

            let error = try requireIpcError(commands)
            #expect(error.code == -32602)
            #expect(model.pane(contextPaneId)?.theme == nil)
        }
    }

    @Test("theme.set without explicit pane and without pane context fails before mutation")
    func themeSetWithoutPaneAndContextFails() throws {
        // Intent: theme.set without an explicit pane and no context
        //   errors before mutation.
        // Why it exists: pins the "need a pane" rule.
        // Scenario: spec-first no-pane.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.themeSet.rawValue,
            params: .object(["themeName": .string("Tokyo Night")]),
            pane: nil
        )

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(model.pane(paneId)?.theme == nil)
    }

    @Test("todo list add edit done open delete clear-completed use context pane")
    func todoCommandFamilyUsesContextPane() throws {
        // Intent: the full todo command surface (list/add/edit/done/
        //   open/delete/clear-completed) operates on the context pane
        //   when no explicit pane is supplied.
        // Why it exists: pins the implicit-context branch for all todo
        //   methods.
        // Scenario: spec-first todo lifecycle on context pane.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let ctx = paneId

        let addEffects = sendIpc(
            &model,
            method: IpcRequestMethod.todoAdd.rawValue,
            params: .object(["text": .string(" ship cli ")]),
            pane: ctx
        )
        let added = try requireIpcReply(addEffects)
        let todoId = try requireString(added["todo"]?["id"], "todo add should return id")
        #expect(model.pane(paneId)?.todos.first?.text == "ship cli")

        let editReply = try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.todoEdit.rawValue, params: .object(["todoId": .string(todoId), "text": .string("ship cli v2")]), pane: ctx))
        #expect(model.pane(paneId)?.todos.first?.text == "ship cli v2")
        #expect(editReply["todo"]?["text"]?.asString == "ship cli v2")

        let doneReply = try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.todoDone.rawValue, params: .object(["todoId": .string(todoId)]), pane: ctx))
        #expect(model.pane(paneId)?.todos.first?.isDone == true)
        #expect(doneReply["todo"]?["isDone"]?.asBool == true)

        let openReply = try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.todoOpen.rawValue, params: .object(["todoId": .string(todoId)]), pane: ctx))
        #expect(model.pane(paneId)?.todos.first?.isDone == false)
        #expect(openReply["todo"]?["isDone"]?.asBool == false)

        let list = try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.todoList.rawValue, pane: ctx))
        #expect(list["todos"]?.asArray?.count == 1)

        _ = sendIpc(&model, method: IpcRequestMethod.todoDelete.rawValue, params: .object(["todoId": .string(todoId)]), pane: ctx)
        #expect(model.pane(paneId)?.todos.count == 0)

        let secondAdd = try requireIpcReply(sendIpc(
            &model,
            method: IpcRequestMethod.todoAdd.rawValue,
            params: .object(["text": .string("done later")]),
            pane: ctx
        ))
        let secondTodoId = try requireString(secondAdd["todo"]?["id"], "todo add should return second id")
        _ = sendIpc(&model, method: IpcRequestMethod.todoDone.rawValue, params: .object(["todoId": .string(secondTodoId)]), pane: ctx)
        _ = sendIpc(&model, method: IpcRequestMethod.todoDone.rawValue, params: .object(["todoId": .string(todoId)]), pane: ctx)
        _ = sendIpc(&model, method: IpcRequestMethod.todoClearCompleted.rawValue, pane: ctx)
        #expect(model.pane(paneId)?.todos.count == 0)
    }

    @Test("todo commands with explicit pane target that pane regardless of context")
    func todoCommandsWithExplicitPaneTargetThatPaneRegardless() throws {
        // Intent: explicit pane param wins over the context pane on
        //   every todo command.
        // Why it exists: pins the explicit-wins rule for todos.
        // Scenario: spec-first explicit pane routing.
        var model = makeModel()
        createTab(&model)
        let targetPaneId = selectedTab(in: model)!.focusedPaneId
        createTab(&model)
        let contextPaneId = selectedTab(in: model)!.focusedPaneId
        let ctx = contextPaneId

        let addReply = try requireIpcReply(sendIpc(
            &model,
            method: IpcRequestMethod.todoAdd.rawValue,
            params: .object([
                "pane": .string(targetPaneId.rawValue.uuidString),
                "text": .string("ship cli"),
            ]),
            pane: ctx
        ))
        let todoId = try requireString(addReply["todo"]?["id"], "todo add should return id")
        #expect(model.pane(targetPaneId)?.todos.first?.text == "ship cli")
        #expect(model.pane(contextPaneId)?.todos.count == 0)

        let listReply = try requireIpcReply(sendIpc(
            &model,
            method: IpcRequestMethod.todoList.rawValue,
            params: .object(["pane": .string(targetPaneId.rawValue.uuidString)]),
            pane: ctx
        ))
        #expect(listReply["todos"]?.asArray?.count == 1)

        _ = sendIpc(
            &model,
            method: IpcRequestMethod.todoEdit.rawValue,
            params: .object([
                "pane": .string(targetPaneId.rawValue.uuidString),
                "todoId": .string(todoId),
                "text": .string("ship cli v2"),
            ]),
            pane: ctx
        )
        #expect(model.pane(targetPaneId)?.todos.first?.text == "ship cli v2")

        _ = sendIpc(
            &model,
            method: IpcRequestMethod.todoDone.rawValue,
            params: .object([
                "pane": .string(targetPaneId.rawValue.uuidString),
                "todoId": .string(todoId),
            ]),
            pane: ctx
        )
        #expect(model.pane(targetPaneId)?.todos.first?.isDone == true)

        _ = sendIpc(
            &model,
            method: IpcRequestMethod.todoOpen.rawValue,
            params: .object([
                "pane": .string(targetPaneId.rawValue.uuidString),
                "todoId": .string(todoId),
            ]),
            pane: ctx
        )
        #expect(model.pane(targetPaneId)?.todos.first?.isDone == false)

        _ = sendIpc(
            &model,
            method: IpcRequestMethod.todoDone.rawValue,
            params: .object([
                "pane": .string(targetPaneId.rawValue.uuidString),
                "todoId": .string(todoId),
            ]),
            pane: ctx
        )
        _ = sendIpc(
            &model,
            method: IpcRequestMethod.todoClearCompleted.rawValue,
            params: .object(["pane": .string(targetPaneId.rawValue.uuidString)]),
            pane: ctx
        )
        #expect(model.pane(targetPaneId)?.todos.count == 0)

        let deleteReply = try requireIpcReply(sendIpc(
            &model,
            method: IpcRequestMethod.todoAdd.rawValue,
            params: .object([
                "pane": .string(targetPaneId.rawValue.uuidString),
                "text": .string("delete me"),
            ]),
            pane: ctx
        ))
        let deleteId = try requireString(deleteReply["todo"]?["id"], "todo add should return delete id")
        _ = sendIpc(
            &model,
            method: IpcRequestMethod.todoDelete.rawValue,
            params: .object([
                "pane": .string(targetPaneId.rawValue.uuidString),
                "todoId": .string(deleteId),
            ]),
            pane: ctx
        )
        #expect(model.pane(targetPaneId)?.todos.count == 0)
    }

    @Test("todo command family edits a tab owner")
    func todoCommandFamilyEditsTabOwner() throws {
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let tab = JSONValue.string(tabId.rawValue.uuidString)

        let add = try requireIpcReply(sendIpc(
            &model,
            method: IpcRequestMethod.todoAdd.rawValue,
            params: .object(["tab": tab, "text": .string("ship tab")])
        ))
        let todoId = try requireString(add["todo"]?["id"], "tab todo add should return id")
        #expect(tabById(tabId, in: model)?.todos.first?.text == "ship tab")

        let list = try requireIpcReply(sendIpc(
            &model, method: IpcRequestMethod.todoList.rawValue, params: .object(["tab": tab])
        ))
        #expect(list["todos"]?.asArray?.count == 1)

        _ = sendIpc(&model, method: IpcRequestMethod.todoEdit.rawValue, params: .object([
            "tab": tab, "todoId": .string(todoId), "text": .string("ship tab v2"),
        ]))
        #expect(tabById(tabId, in: model)?.todos.first?.text == "ship tab v2")

        _ = sendIpc(&model, method: IpcRequestMethod.todoDone.rawValue, params: .object([
            "tab": tab, "todoId": .string(todoId),
        ]))
        #expect(tabById(tabId, in: model)?.todos.first?.isDone == true)

        _ = sendIpc(&model, method: IpcRequestMethod.todoOpen.rawValue, params: .object([
            "tab": tab, "todoId": .string(todoId),
        ]))
        #expect(tabById(tabId, in: model)?.todos.first?.isDone == false)

        _ = sendIpc(&model, method: IpcRequestMethod.todoDone.rawValue, params: .object([
            "tab": tab, "todoId": .string(todoId),
        ]))
        _ = sendIpc(
            &model, method: IpcRequestMethod.todoClearCompleted.rawValue,
            params: .object(["tab": tab])
        )
        #expect(tabById(tabId, in: model)?.todos.isEmpty == true)

        let deleteAdd = try requireIpcReply(sendIpc(
            &model, method: IpcRequestMethod.todoAdd.rawValue,
            params: .object(["tab": tab, "text": .string("delete")])
        ))
        let deleteId = try requireString(deleteAdd["todo"]?["id"], "tab todo add should return id")
        _ = sendIpc(&model, method: IpcRequestMethod.todoDelete.rawValue, params: .object([
            "tab": tab, "todoId": .string(deleteId),
        ]))
        #expect(tabById(tabId, in: model)?.todos.isEmpty == true)
    }

    @Test("todo command rejects an unknown tab owner")
    func todoCommandRejectsUnknownTabOwner() throws {
        var model = makeModel()
        createTab(&model)
        let before = model

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.todoList.rawValue,
            params: .object(["tab": .string(TabId().rawValue.uuidString)])
        )

        #expect(try requireIpcError(commands) == .init(code: -32602, message: "tab not found"))
        #expect(model == before)
    }

    @Test("todo commands malformed or unknown explicit pane do not fall back to context")
    func todoCommandsMalformedOrUnknownExplicitPaneNoFallback() throws {
        // Intent: malformed / unknown / non-string explicit pane on
        //   every todo method returns -32602; context pane stays
        //   untouched.
        // Why it exists: pins no-fallback for every todo command.
        // Scenario: spec-first todo no-fallback sweep.
        for paneValue in [JSONValue.string("not-a-uuid"), .string(UUID().uuidString), .number(7)] {
            let commands: [(String, [String: JSONValue])] = [
                (IpcRequestMethod.todoList.rawValue, [:]),
                (IpcRequestMethod.todoAdd.rawValue, ["text": .string("should-not-apply")]),
                (IpcRequestMethod.todoEdit.rawValue, ["todoId": .string("TODO_ID"), "text": .string("changed")]),
                (IpcRequestMethod.todoDone.rawValue, ["todoId": .string("TODO_ID")]),
                (IpcRequestMethod.todoOpen.rawValue, ["todoId": .string("TODO_ID")]),
                (IpcRequestMethod.todoDelete.rawValue, ["todoId": .string("TODO_ID")]),
                (IpcRequestMethod.todoClearCompleted.rawValue, [:]),
            ]

            for (method, baseParams) in commands {
                var model = makeModel()
                createTab(&model)
                let contextPaneId = selectedTab(in: model)!.focusedPaneId
                let item = appendTodoForTest(&model, paneId: contextPaneId, text: "context")
                if method == IpcRequestMethod.todoClearCompleted.rawValue || method == IpcRequestMethod.todoOpen.rawValue {
                    model.updatePane(contextPaneId) { $0.todos[0].isDone = true }
                }

                var params = baseParams
                params["pane"] = paneValue
                if params["todoId"] != nil {
                    params["todoId"] = .string(item.id.rawValue.uuidString)
                }

                let sent = sendIpc(
                    &model,
                    method: method,
                    params: .object(params),
                    pane: contextPaneId
                )

                let error = try requireIpcError(sent)
                #expect(error.code == -32602)
                #expect(model.pane(contextPaneId)?.todos.count == 1)
                #expect(model.pane(contextPaneId)?.todos[0].text == "context")
            }
        }
    }

    @Test("todo commands without explicit pane and without pane context fail before mutation")
    func todoCommandsWithoutPaneAndContextFail() throws {
        // Intent: every todo command requires a pane (explicit or
        //   context); without either it returns -32602.
        // Why it exists: pins the "need a pane" rule for the full
        //   command surface.
        // Scenario: spec-first todo no-pane sweep.
        let commands: [(String, [String: JSONValue])] = [
            (IpcRequestMethod.todoList.rawValue, [:]),
            (IpcRequestMethod.todoAdd.rawValue, ["text": .string("should-not-apply")]),
            (IpcRequestMethod.todoEdit.rawValue, ["todoId": .string(UUID().uuidString), "text": .string("changed")]),
            (IpcRequestMethod.todoDone.rawValue, ["todoId": .string(UUID().uuidString)]),
            (IpcRequestMethod.todoOpen.rawValue, ["todoId": .string(UUID().uuidString)]),
            (IpcRequestMethod.todoDelete.rawValue, ["todoId": .string(UUID().uuidString)]),
            (IpcRequestMethod.todoClearCompleted.rawValue, [:]),
        ]

        for (method, params) in commands {
            var model = makeModel()
            createTab(&model)
            let paneId = selectedTab(in: model)!.focusedPaneId
            _ = appendTodoForTest(&model, paneId: paneId, text: "context")

            let sent = sendIpc(
                &model,
                method: method,
                params: .object(params),
                pane: nil
            )

            let error = try requireIpcError(sent)
            #expect(error.code == -32602)
            #expect(model.pane(paneId)?.todos.count == 1)
        }
    }

    @Test("todo delete rejects unknown id")
    func todoDeleteRejectsUnknownId() throws {
        // Intent: todoDelete with an unknown id returns -32602.
        // Why it exists: pins fail-closed for stale todo ids.
        // Scenario: spec-first stale todo delete.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.todoDelete.rawValue,
            params: .object(["todoId": .string(UUID().uuidString)]),
            pane: paneId
        )
        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
    }

    @Test("pane.input emits text command for context pane")
    func paneInputEmitsTextCommandForContextPane() {
        // Intent: pane.input { text } emits sendText addressed to the
        //   context pane.
        // Why it exists: pins the text branch of pane.input.
        // Scenario: spec-first text input.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object(["text": .string("echo hi")]),
            pane: paneId
        )
        #expect(hasEffect(commands) {
            if case .sendText(let pid, let text) = $0 { return pid == paneId && text == "echo hi" }
            return false
        }, "expected sendText command")
    }

    @Test("pane.input input array emits ordered Effects via the key path")
    func paneInputInputArrayEmitsOrderedEffects() {
        // Intent: pane.input { input: [...] } emits sendInputText +
        //   sendInputKey in order, then ipcReply; no sendText leaks.
        // Why it exists: pins the input-array path against text-path
        //   fallback.
        // Scenario: spec-first input array.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object([
                "input": .array([
                    .object(["text": .string("ls")]),
                    .object(["key": .string("Enter")]),
                ])
            ]),
            pane: paneId
        )
        #expect(commands.count == 3)
        guard case .sendInputText(let p0, let t0) = commands[0] else {
            Issue.record("expected first command = sendInputText")
            return
        }
        #expect(p0 == paneId)
        #expect(t0 == "ls")
        guard case .sendInputKey(let p1, let key1, let mods1) = commands[1] else {
            Issue.record("expected second command = sendInputKey")
            return
        }
        #expect(p1 == paneId)
        #expect(key1 == KeyName.named(.enter))
        #expect(mods1 == KeyMods())
        guard case .ipcReply = commands[2] else {
            Issue.record("expected third command = ipcReply")
            return
        }
        #expect(!hasEffect(commands) {
            if case .sendText = $0 { return true }
            return false
        }, "input path must not emit .sendText")
    }

    @Test("pane.input explicit empty mods equals omitted mods")
    func paneInputExplicitEmptyModsEqualsOmittedMods() {
        // Intent: an explicit empty mods array equals omitted mods.
        // Why it exists: pins the equality of two representations.
        // Scenario: spec-first empty mods.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object([
                "input": .array([
                    .object([
                        "key": .string("Enter"),
                        "mods": .array([]),
                    ])
                ])
            ]),
            pane: paneId
        )
        #expect(hasEffect(commands) {
            if case .sendInputKey(let p, let k, let m) = $0 {
                return p == paneId && k == .named(.enter) && m == KeyMods()
            }
            return false
        }, "expected sendInputKey with empty mods")
    }

    @Test("pane.input non-array mods is invalid params")
    func paneInputNonArrayModsIsInvalidParams() throws {
        // Intent: a non-array mods value returns -32602 with the
        //   documented message.
        // Why it exists: pins the type-check message.
        // Scenario: spec-first non-array mods.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object([
                "input": .array([
                    .object([
                        "key": .string("Enter"),
                        "mods": .string("ctrl"),
                    ])
                ])
            ]),
            pane: paneId
        )
        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(error.message.contains("mods must be an array"),
            "message should describe non-array mods, got: \(error.message)")
    }

    @Test("pane.input key with ctrl mod emits sendInputKey")
    func paneInputKeyWithCtrlModEmitsSendInputKey() {
        // Intent: ctrl-c emits sendInputKey(.letter("c"), .ctrl).
        // Why it exists: pins the ctrl modifier mapping.
        // Scenario: spec-first ctrl-c.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object([
                "input": .array([
                    .object([
                        "key": .string("c"),
                        "mods": .array([.string("ctrl")]),
                    ])
                ])
            ]),
            pane: paneId
        )
        #expect(hasEffect(commands) {
            if case .sendInputKey(let p, let k, let m) = $0 {
                return p == paneId && k == .letter("c") && m == [.ctrl]
            }
            return false
        }, "expected sendInputKey for C-c")
    }

    @Test("pane.input with both text and input is invalid params")
    func paneInputBothTextAndInputIsInvalidParams() throws {
        // Intent: both `text` and `input` fail (one or the other,
        //   never both).
        // Why it exists: pins the mutual-exclusion rule.
        // Scenario: spec-first both-fields.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object([
                "text": .string("hi"),
                "input": .array([.object(["text": .string("hi")])]),
            ]),
            pane: paneId
        )
        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
    }

    @Test("pane.input with neither text nor input is invalid params")
    func paneInputNeitherTextNorInputIsInvalidParams() throws {
        // Intent: neither `text` nor `input` fails.
        // Why it exists: pins the one-required rule.
        // Scenario: spec-first no-field.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object([:]),
            pane: paneId
        )
        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
    }

    @Test("pane.input input event missing both text and key is invalid params")
    func paneInputInputEventMissingBothFails() throws {
        // Intent: an input event with neither text nor key fails.
        // Why it exists: pins the inner one-required rule.
        // Scenario: spec-first inner no-field.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object([
                "input": .array([.object([:])])
            ]),
            pane: paneId
        )
        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
    }

    @Test("pane.input input event with both text and key is invalid params")
    func paneInputInputEventBothTextAndKeyFails() throws {
        // Intent: an input event with both text and key fails.
        // Why it exists: pins the inner mutual-exclusion.
        // Scenario: spec-first inner both-fields.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object([
                "input": .array([
                    .object([
                        "text": .string("x"),
                        "key": .string("Enter"),
                    ])
                ])
            ]),
            pane: paneId
        )
        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
    }

    @Test("pane.input unknown key name is rejected before any Command")
    func paneInputUnknownKeyRejectedBeforeAnyCommand() throws {
        // Intent: a wire-level unknown key name returns -32602 BEFORE
        //   any sendInputKey is emitted.
        // Why it exists: pins the load-bearing assertion that unknown
        //   keys never make it past the IPC handler.
        // Scenario: spec-first unknown key.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object([
                "input": .array([
                    .object(["key": .string("Bogus")])
                ])
            ]),
            pane: paneId
        )
        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(error.message.contains("unknown key Bogus"),
            "message should mention unknown key Bogus, got: \(error.message)")
        #expect(!hasEffect(commands) {
            if case .sendInputKey = $0 { return true }
            return false
        }, "no .sendInputKey should be emitted")
    }

    @Test("pane.input non-string key value is invalid params")
    func paneInputNonStringKeyIsInvalidParams() throws {
        // Intent: a non-string key value returns -32602.
        // Why it exists: pins the type check on key.
        // Scenario: spec-first non-string key.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object([
                "input": .array([
                    .object(["key": .number(5)])
                ])
            ]),
            pane: paneId
        )
        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
    }

    @Test("pane.input unknown mod name is invalid params")
    func paneInputUnknownModNameIsInvalidParams() throws {
        // Intent: an unknown mod name returns -32602 with a "unknown
        //   mod" message.
        // Why it exists: pins the named-mod validation.
        // Scenario: spec-first unknown mod.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object([
                "input": .array([
                    .object([
                        "key": .string("Enter"),
                        "mods": .array([.string("bogus")]),
                    ])
                ])
            ]),
            pane: paneId
        )
        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(error.message.contains("unknown mod bogus"),
            "message should mention unknown mod bogus, got: \(error.message)")
    }

    @Test("pane.input shift mod reaches the named-key command")
    func paneInputShiftModReachesNamedKeyCommand() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object([
                "input": .array([
                    .object([
                        "key": .string("Tab"),
                        "mods": .array([.string("shift")]),
                    ])
                ])
            ]),
            pane: paneId
        )
        #expect(commands.contains { command in
            if case .sendInputKey(let target, .named(.tab), let modifiers) = command {
                return target == paneId && modifiers == [.shift]
            }
            return false
        })
    }

    @Test("pane.input explicit pane targets that pane regardless of context")
    func paneInputExplicitPaneTargetsRegardlessOfContext() {
        // Intent: explicit pane param wins over the IPC context.
        // Why it exists: pins the explicit-wins rule for pane.input.
        // Scenario: spec-first explicit pane.
        var model = makeModel()
        createTab(&model)
        let backgroundPaneId = selectedTab(in: model)!.focusedPaneId
        createTab(&model)
        let foregroundPaneId = selectedTab(in: model)!.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object([
                "pane": .string(backgroundPaneId.rawValue.uuidString),
                "input": .array([.object(["text": .string("hi")])]),
            ]),
            pane: foregroundPaneId
        )
        #expect(hasEffect(commands) {
            if case .sendInputText(let p, let t) = $0 {
                return p == backgroundPaneId && t == "hi"
            }
            return false
        }, "expected command targeting explicit pane")
    }

    @Test("pane.input explicit pane that doesn't exist returns pane not found")
    func paneInputExplicitPaneNotFoundError() throws {
        // Intent: an unknown explicit pane returns "pane not found"
        //   (no fallback to context).
        // Why it exists: pins the no-fallback rule and the message.
        // Scenario: spec-first unknown explicit pane.
        var model = makeModel()
        createTab(&model)
        let realPaneId = selectedTab(in: model)!.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object([
                "pane": .string(UUID().uuidString),
                "input": .array([.object(["text": .string("hi")])]),
            ]),
            pane: realPaneId
        )
        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(error.message.contains("pane not found"),
            "expected 'pane not found', got: \(error.message)")
        #expect(!hasEffect(commands) {
            if case .sendInputText = $0 { return true }
            return false
        }, "no input command should be emitted")
    }

    @Test("pane.input non-string pane is invalid params and does not fall back")
    func paneInputNonStringPaneIsInvalidParams() throws {
        // Intent: non-string pane returns -32602 with a "pane must be
        //   a string" message.
        // Why it exists: pins the type-check message.
        // Scenario: spec-first non-string pane.
        var model = makeModel()
        createTab(&model)
        let realPaneId = selectedTab(in: model)!.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object([
                "pane": .number(5),
                "input": .array([.object(["text": .string("hi")])]),
            ]),
            pane: realPaneId
        )
        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(error.message.contains("pane must be a string"),
            "expected 'pane must be a string', got: \(error.message)")
    }

    @Test("pane.input without an explicit pane errors")
    func paneInputNoPaneInContextOrExplicitErrors() throws {
        // Intent: an absent explicit pane returns -32602 with the shared
        //   required-target message.
        // Why it exists: pins the missing-pane error message.
        // Scenario: spec-first no pane.
        var model = makeModel()
        createTab(&model)
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object(["input": .array([.object(["text": .string("hi")])])]),
            pane: nil
        )
        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(error.message == "pane required")
    }

    @Test("pane.read emits viewport read command without immediate reply")
    func paneReadEmitsViewportReadNoImmediateReply() {
        // Intent: pane.read emits a single readPaneText command and no
        //   immediate ipcReply (the async response carries the data).
        // Why it exists: pins the async-read shape.
        // Scenario: spec-first viewport read.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneRead.rawValue,
            params: .object(["pane": .string(paneId.rawValue.uuidString)])
        )

        #expect(commands.count == 1)
        guard case .readPaneText(_, let effectPaneId, let lineLimit) = commands[0] else {
            Issue.record("expected readPaneText command")
            return
        }
        #expect(effectPaneId == paneId)
        #expect(lineLimit == nil)
        #expect(!hasEffect(commands) {
            if case .ipcReply = $0 { return true }
            return false
        }, "pane.read success should not emit an immediate ipcReply")
    }

    @Test("pane.read emits scrollback tail read command with line limit")
    func paneReadEmitsScrollbackTailReadWithLineLimit() {
        // Intent: pane.read with `lines` emits readPaneText carrying
        //   that line limit.
        // Why it exists: pins the lines-param wiring.
        // Scenario: spec-first lines limit.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneRead.rawValue,
            params: .object([
                "pane": .string(paneId.rawValue.uuidString),
                "lines": .number(200),
            ])
        )

        #expect(commands.count == 1)
        guard case .readPaneText(_, let effectPaneId, let lineLimit) = commands[0] else {
            Issue.record("expected readPaneText command")
            return
        }
        #expect(effectPaneId == paneId)
        #expect(lineLimit == 200)
    }

    @Test("pane.read missing pane param errors")
    func paneReadMissingPaneParamErrors() throws {
        // Intent: missing pane param returns -32602 with "pane
        //   required".
        // Why it exists: pins the missing-pane error message.
        // Scenario: spec-first missing pane.
        var model = makeModel()
        createTab(&model)
        let commands = sendIpc(&model, method: IpcRequestMethod.paneRead.rawValue, params: .object([:]))
        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(error.message == "pane required")
    }

    @Test("pane.read non-string pane param errors")
    func paneReadNonStringPaneParamErrors() throws {
        // Intent: non-string pane param returns -32602 with "pane
        //   must be a string".
        // Why it exists: pins the type check.
        // Scenario: spec-first non-string pane.
        for paneValue in [JSONValue.number(5), .array([]), .object([:])] {
            var model = makeModel()
            createTab(&model)
            let commands = sendIpc(
                &model,
                method: IpcRequestMethod.paneRead.rawValue,
                params: .object(["pane": paneValue])
            )
            let error = try requireIpcError(commands)
            #expect(error.code == -32602)
            #expect(error.message == "pane must be a string")
        }
    }

    @Test("pane.read unknown pane errors")
    func paneReadUnknownPaneErrors() throws {
        // Intent: unknown pane id returns -32602 with "pane not found".
        // Why it exists: pins the unknown-pane error message.
        // Scenario: spec-first unknown pane.
        for rawPane in ["bogus", UUID().uuidString] {
            var model = makeModel()
            createTab(&model)
            let commands = sendIpc(
                &model,
                method: IpcRequestMethod.paneRead.rawValue,
                params: .object(["pane": .string(rawPane)])
            )
            let error = try requireIpcError(commands)
            #expect(error.code == -32602)
            #expect(error.message == "pane not found")
        }
    }

    @Test("pane.read invalid line limits error")
    func paneReadInvalidLineLimitsError() throws {
        // Intent: invalid `lines` values (zero, negative, string,
        //   fractional) return -32602 with "lines must be a positive
        //   integer".
        // Why it exists: pins the lines validation.
        // Scenario: spec-first invalid lines.
        let invalidValues: [JSONValue] = [.number(0), .number(-5), .string("5"), .number(1.5)]
        for linesValue in invalidValues {
            var model = makeModel()
            createTab(&model)
            let paneId = selectedTab(in: model)!.focusedPaneId
            let commands = sendIpc(
                &model,
                method: IpcRequestMethod.paneRead.rawValue,
                params: .object([
                    "pane": .string(paneId.rawValue.uuidString),
                    "lines": linesValue,
                ])
            )
            let error = try requireIpcError(commands)
            #expect(error.code == -32602)
            #expect(error.message == "lines must be a positive integer")
        }
    }

    @Test("pane.tape resolves the addressed pane and defers its reply")
    func paneTapeResolvesAddressedPane() {
        // Intent: pane.tape emits one dump command for the explicit pane and no
        //   immediate reply, leaving serialization to the runtime boundary.
        // Why it exists: the pure update layer must not read a session or encode
        //   a recording while still owning pane-addressing semantics.
        // Scenario: a CLI client requests a tape from a known background pane.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneTape.rawValue,
            params: .object(["pane": .string(paneId.rawValue.uuidString)])
        )

        #expect(commands.count == 1)
        guard case .dumpPaneTape(_, let commandPaneId) = commands[0] else {
            Issue.record("expected dumpPaneTape command")
            return
        }
        #expect(commandPaneId == paneId)
    }

    @Test("pane.tape follow resolves the addressed pane and preserves tail mode")
    func paneTapeFollowResolvesAddressedPane() {
        // Intent: follow requests emit a long-lived stream command for the explicit pane.
        // Why it exists: the one-reply dump command cannot represent later notifications.
        // Scenario: an agent asks to tail a known background pane without its backlog.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneTape.rawValue,
            params: .object([
                "pane": .string(paneId.rawValue.uuidString),
                "follow": .bool(true),
                "fromNow": .bool(true),
            ])
        )

        #expect(commands.count == 1)
        guard case .followPaneTape(_, let commandPaneId, let fromNow) = commands[0] else {
            Issue.record("expected followPaneTape command")
            return
        }
        #expect(commandPaneId == paneId)
        #expect(fromNow)
    }

    @Test("pane.tape rejects missing and unknown panes")
    func paneTapeRejectsMissingAndUnknownPanes() throws {
        var missingModel = makeModel()
        createTab(&missingModel)
        let missing = sendIpc(
            &missingModel,
            method: IpcRequestMethod.paneTape.rawValue,
            params: .object([:]),
            pane: nil
        )
        #expect(try requireIpcError(missing) == .init(code: -32602, message: "pane required"))

        var unknownModel = makeModel()
        createTab(&unknownModel)
        let unknown = sendIpc(
            &unknownModel,
            method: IpcRequestMethod.paneTape.rawValue,
            params: .object(["pane": .string(UUID().uuidString)])
        )
        #expect(try requireIpcError(unknown) == .init(code: -32602, message: "pane not found"))

        var invalidModel = makeModel()
        createTab(&invalidModel)
        let paneId = selectedTab(in: invalidModel)!.focusedPaneId
        let invalid = sendIpc(
            &invalidModel,
            method: IpcRequestMethod.paneTape.rawValue,
            params: .object([
                "pane": .string(paneId.rawValue.uuidString),
                "fromNow": .bool(true),
            ])
        )
        #expect(try requireIpcError(invalid) == .init(
            code: -32602,
            message: "fromNow requires follow"
        ))
    }
}

// MARK: - Private helpers

private struct IpcErrorResult: Equatable {
    let code: Int
    let message: String
}

private func sendIpc(
    _ model: inout AppModel,
    method: String,
    params: JSONValue = .object([:]),
    pane: PaneId? = nil,
    env: CoreEnv = .live
) -> [Command] {
    var effectiveParams = params
    if let pane, case .object(var object) = effectiveParams, object["pane"] == nil {
        object["pane"] = .string(pane.rawValue.uuidString)
        effectiveParams = .object(object)
    }
    let reqId = UUID()
    do {
        return update(
            &model,
            .ipcRequest(
                reqId: reqId,
                request: try IpcRequest.decode(method: method, params: effectiveParams)
            ),
            env: env
        )
    } catch let error as IpcRequestDecodeError {
        return update(&model, .ipcRequestDecodeFailed(reqId: reqId, error: error), env: env)
    } catch {
        return update(
            &model,
            .ipcRequestDecodeFailed(reqId: reqId, error: .internalError),
            env: env
        )
    }
}

private func selectedPaneId(in model: AppModel) -> PaneId {
    selectedTab(in: model)!.focusedPaneId
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
    let targetGroupIndex = try #require(
        model.groups.firstIndex(where: { $0.id == targetGroupId }),
        "target group should exist"
    )
    let refIndex = try #require(
        beforeGroupTabs[targetGroupIndex].firstIndex(of: refTabId),
        "reference tab should be in target group snapshot"
    )
    let tabId = try requireTabId(reply["tab"]?["id"], "tab.new should return tab id")
    let paneId = try requirePaneId(reply["panes"]?.asArray?.first?["id"], "tab.new should return pane id")
    var expectedTarget = beforeGroupTabs[targetGroupIndex]
    expectedTarget.insert(tabId, at: refIndex + 1)

    for groupIndex in model.groups.indices {
        if groupIndex == targetGroupIndex {
            #expect(model.groups[groupIndex].tabs.map(\.id) == expectedTarget)
        } else {
            #expect(model.groups[groupIndex].tabs.map(\.id) == beforeGroupTabs[groupIndex])
        }
    }

    let newPaneIds = Set(model.allPaneIds).subtracting(panesBefore)
    #expect(newPaneIds == [paneId])
    let tab = try #require(tabById(tabId, in: model), "new tab should exist")
    #expect(tab.focusedPaneId == paneId)
    if case .leaf(let rootPane) = tab.rootNode {
        #expect(rootPane.id == paneId)
    } else {
        Issue.record("new tab should have a root leaf")
        return
    }
    #expect(model.selectedTabId == tabId)
}

private func requireIpcReply(_ commands: [Command]) throws -> JSONValue {
    let reply = commands.compactMap { command -> JSONValue? in
        if case .ipcReply(_, let result) = command { return result }
        return nil
    }.first
    return try #require(reply, "expected ipcReply")
}

private func isTerminate(_ command: Command) -> Bool {
    if case .terminate = command { return true }
    return false
}

private func requireIpcError(_ commands: [Command]) throws -> IpcErrorResult {
    let result = commands.compactMap { command -> IpcErrorResult? in
        if case .ipcError(_, let code, let message) = command {
            return IpcErrorResult(code: code, message: message)
        }
        return nil
    }.first
    return try #require(result, "expected ipcError")
}

private func requireString(_ value: JSONValue?, _ message: String) throws -> String {
    try #require(value?.asString, Comment(rawValue: message))
}

private func requirePaneId(_ value: JSONValue?, _ message: String) throws -> PaneId {
    let raw = try requireString(value, message)
    let uuid = try #require(UUID(uuidString: raw), Comment(rawValue: message))
    return PaneId(rawValue: uuid)
}

private func requireTabId(_ value: JSONValue?, _ message: String) throws -> TabId {
    let raw = try requireString(value, message)
    let uuid = try #require(UUID(uuidString: raw), Comment(rawValue: message))
    return TabId(rawValue: uuid)
}

private func appendTodoForTest(_ model: inout AppModel, paneId: PaneId, text: String) -> TodoItem {
    let item = TodoItem(id: UUID(), text: text, isDone: false)
    model.updatePane(paneId) { $0.todos.append(item) }
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

// MARK: - pane.zoom

@Suite struct UpdateIpcZoomTests {
    @Test("pane.zoom sets an explicit state rather than toggling")
    func paneZoomSetsExplicitState() throws {
        // Intent: `state: "on"` and `state: "off"` drive the tab to that zoom state
        //   regardless of what it was, so repeating a request is a no-op.
        // Why it exists: a script that can only toggle cannot recover a known state
        //   after any concurrent change, which makes an agent-driven resize stimulus
        //   depend on history it cannot observe.
        // Scenario: spec-first; an agent zooms a split tab twice, then unzooms twice.
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .splitFocusedPane(direction: .horizontal))
        let paneId = selectedTab(in: model)!.focusedPaneId
        let params = JSONValue.object([
            "pane": .string(paneId.rawValue.uuidString),
            "state": .string("on"),
        ])

        for _ in 0..<2 {
            let reply = try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.paneZoom.rawValue, params: params))
            #expect(reply["tab"]?["isZoomed"]?.asBool == true)
            #expect(selectedTab(in: model)!.isZoomed)
        }

        let off = JSONValue.object([
            "pane": .string(paneId.rawValue.uuidString),
            "state": .string("off"),
        ])
        for _ in 0..<2 {
            let reply = try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.paneZoom.rawValue, params: off))
            #expect(reply["tab"]?["isZoomed"]?.asBool == false)
            #expect(selectedTab(in: model)!.isZoomed == false)
        }
    }

    @Test("pane.zoom toggle flips the tab and reports the resulting state")
    func paneZoomToggleFlips() throws {
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .splitFocusedPane(direction: .horizontal))
        let paneId = selectedTab(in: model)!.focusedPaneId
        let params = JSONValue.object([
            "pane": .string(paneId.rawValue.uuidString),
            "state": .string("toggle"),
        ])

        #expect(try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.paneZoom.rawValue, params: params))["tab"]?["isZoomed"]?.asBool == true)
        #expect(try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.paneZoom.rawValue, params: params))["tab"]?["isZoomed"]?.asBool == false)
    }

    @Test("pane.zoom on an unsplit tab reports not zoomed instead of failing")
    func paneZoomUnsplitTabReportsNotZoomed() throws {
        // Intent: a tab with no split cannot zoom, and the reply says so.
        // Why it exists: a caller scripting a resize stimulus needs to distinguish
        //   "zoom applied" from "nothing to zoom" without parsing an error string.
        // Scenario: spec-first; an agent zooms a tab holding a single pane.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId

        let reply = try requireIpcReply(sendIpc(
            &model,
            method: IpcRequestMethod.paneZoom.rawValue,
            params: .object([
                "pane": .string(paneId.rawValue.uuidString),
                "state": .string("on"),
            ])
        ))
        #expect(reply["tab"]?["isZoomed"]?.asBool == false)
    }

    @Test("pane.zoom rejects an unknown state and an unknown pane")
    func paneZoomRejectsBadInput() throws {
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .splitFocusedPane(direction: .horizontal))
        let paneId = selectedTab(in: model)!.focusedPaneId

        let badState = sendIpc(&model, method: IpcRequestMethod.paneZoom.rawValue, params: .object([
            "pane": .string(paneId.rawValue.uuidString),
            "state": .string("sideways"),
        ]))
        #expect(try requireIpcError(badState).code == -32602)

        let unknownPane = sendIpc(&model, method: IpcRequestMethod.paneZoom.rawValue, params: .object([
            "pane": .string(UUID().uuidString),
            "state": .string("on"),
        ]))
        #expect(try requireIpcError(unknownPane).code == -32602)
        #expect(selectedTab(in: model)!.isZoomed == false)
    }

    @Test("pane.info reports the tab's zoom state")
    func paneInfoReportsZoomState() throws {
        // Intent: the state `pane.zoom` sets is readable through `pane.info`.
        // Why it exists: zoom is deliberately transient and so is absent from the
        //   persisted snapshot `ls` returns, which would otherwise leave an agent
        //   able to set zoom but not observe it.
        // Scenario: spec-first; an agent zooms a tab and reads it back.
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .splitFocusedPane(direction: .horizontal))
        let paneId = selectedTab(in: model)!.focusedPaneId
        let context = paneId

        let before = try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.paneInfo.rawValue, pane: context))
        #expect(before["tab"]?["isZoomed"]?.asBool == false)

        _ = update(&model, .toggleZoomPane(paneId: paneId))

        let after = try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.paneInfo.rawValue, pane: context))
        #expect(after["tab"]?["isZoomed"]?.asBool == true)
    }
}
