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
    @Test("ping is answered by the same dispatch that services every other request")
    func pingIsAnsweredThroughDispatch() throws {
        // Intent: a pong is an ordinary reply produced by `update`, for a local and
        //   a remote caller alike, and it changes nothing in the model.
        // Why it exists: the pong is the client's proof that the Mac is servicing
        //   requests. If anything below dispatch could answer it, a Mac too starved
        //   to run a request would still report itself alive.
        let callers: [IpcCallerIdentity] = [
            .local,
            .remote(nodeId: "node-phone", user: "dan@example.com", machineName: "iphone"),
        ]

        for caller in callers {
            var model = makeModel()
            createTab(&model)
            let before = model
            let commands = sendIpc(
                &model,
                method: IpcRequestMethod.ping.rawValue,
                caller: caller
            )

            #expect(commands.count == 1)
            guard case .ipcReply(_, let result)? = commands.first else {
                Issue.record("ping produced \(commands) instead of a reply")
                return
            }
            #expect(result == .object(["ok": .bool(true)]))
            #expect(model == before)
        }
    }

    @Test("tailnet.status replies with the listener status the model holds")
    func tailnetStatusRepliesWithTheModelStatus() throws {
        // Intent: the reply is the status the app authored, copied out of the model
        //   verbatim, for a local and an admitted remote caller alike.
        // Why it exists: the preferences pane, this reply, and a slot launch handle
        //   must never disagree. They can only stay equal if none of them derives an
        //   endpoint or invents a state of its own.
        let endpoint = DanTermTailnetEndpoint(
            base: "100.99.4.1:24863",
            offset: 4,
            address: "100.99.4.1",
            port: 24867
        )
        let statuses: [DanTermTailnetStatus] = [
            .disabled(reason: "no tailnet endpoint is configured"),
            .waiting(endpoint: endpoint, reason: "the interface is not up"),
            .listening(endpoint: endpoint),
        ]
        let callers: [IpcCallerIdentity] = [
            .local,
            .remote(nodeId: "node-phone", user: "dan@example.com", machineName: "iphone"),
        ]

        for status in statuses {
            for caller in callers {
                var model = makeModel()
                model.tailnetStatus = status
                let before = model
                let commands = sendIpc(
                    &model,
                    method: IpcRequestMethod.tailnetStatus.rawValue,
                    caller: caller
                )

                #expect(commands.count == 1)
                guard case .ipcReply(_, let result)? = commands.first else {
                    Issue.record("tailnet.status produced \(commands) instead of a reply")
                    return
                }
                #expect(result == status.json)
                #expect(model == before)
            }
        }
    }

    @Test("a published listener status replaces the one the model reports")
    func publishedTailnetStatusReplacesTheReportedOne() {
        // Intent: the server's status transition is the only thing that moves the
        //   model's tailnet status.
        // Why it exists: the listener binds on a later retry, so a model that kept
        //   its launch value would report `waiting` at a listening instance forever.
        var model = makeModel()
        let endpoint = DanTermTailnetEndpoint(
            base: "100.99.4.1:24863",
            offset: 0,
            address: "100.99.4.1",
            port: 24863
        )
        model.tailnetStatus = .waiting(endpoint: endpoint, reason: "the listener is not open yet")

        let commands = update(&model, .tailnetStatusChanged(.listening(endpoint: endpoint)))

        #expect(commands.isEmpty)
        #expect(model.tailnetStatus == .listening(endpoint: endpoint))
    }

    @Test("every targeting IPC method refuses an absent, non-string, or unresolvable target")
    func everyTargetingMethodRefusesBadTarget() throws {
        // Intent: for every method that names an entity, all four bad-target
        //   shapes return -32602 with the shared vocabulary, and none of them
        //   changes the model.
        // Why it exists: production resolves every target through one decoder
        //   (`target(_:object:)` in DanTermProtocol), so the test for it is one
        //   table, not one test per method. The table also owns its own
        //   coverage: a new targeting method that nobody lists here is a method
        //   nobody checks, which is how pane.rows and the three agent methods
        //   went unchecked on every axis but "absent".
        // Scenario: spec-first sweep of every targeting method.
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
            (IpcRequestMethod.paneResize.rawValue, ["fit": .bool(true)], "pane"),
            // start/mode are required, and pane.tape validates them once the
            // pane resolves -- without them the unresolvable probes would fail
            // on the wrong param.
            (IpcRequestMethod.paneTape.rawValue, [
                "start": .string("beginning"),
                "mode": .string("raw"),
            ], "pane"),
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
            let absentMessage = testCase.method.hasPrefix("todo.")
                || testCase.method == IpcRequestMethod.paneSplit.rawValue
                ? "pane or tab required"
                : "\(testCase.entity) required"
            let probes: [(label: String, value: JSONValue?, message: String)] = [
                ("absent", nil, absentMessage),
                ("number", .number(7), "\(testCase.entity) must be a string"),
                ("array", .array([]), "\(testCase.entity) must be a string"),
                ("object", .object([:]), "\(testCase.entity) must be a string"),
                ("malformed", .string("not-a-uuid"), "\(testCase.entity) not found"),
                ("unknown", .string(UUID().uuidString), "\(testCase.entity) not found"),
            ]

            for probe in probes {
                var model = makeModel()
                createTab(&model)
                var params = testCase.params
                if let value = probe.value {
                    params[testCase.entity] = value
                    // A tab or group target could still be inferred from the
                    // caller's pane, so supply one: a resolver that fell back
                    // would answer instead of failing. A pane target has no
                    // second source, since the target key is the context key.
                    if testCase.entity != "pane" {
                        params["pane"] = .string(selectedPaneId(in: model).rawValue.uuidString)
                    }
                }
                let before = model

                let commands = sendIpc(&model, method: testCase.method, params: .object(params))

                let error = try requireIpcError(commands)
                let where_ = "\(testCase.method) with a \(probe.label) target"
                #expect(error.code == -32602, "\(where_) should be invalid params")
                #expect(error.message == probe.message, "\(where_) got: \(error.message)")
                #expect(model == before, "\(where_) changed the model")
                // The reply is the whole answer: a refused target must not also
                // emit a side effect, which model equality alone cannot show
                // for the methods whose work is a Command rather than a change.
                #expect(commands.count == 1, "\(where_) emitted \(commands.count) commands")
            }
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
        let tabA = TabModel(id: tabAId, customTitle: "work", paneTree: PaneTree(root: nestedRoot, focusedPaneId: paneBId), color: .purple, todos: [TodoItem(id: tabTodoId, text: "review", isDone: true)])
        let tabB = TabModel(id: tabBId, paneTree: PaneTree(root: .leaf(paneD), focusedPaneId: paneDId))
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
            "processPhase": .string("spawning"),
            "integration": .object(["state": .string("neverReported")]),
            "command": .object(["state": .string("idle")]),
            "connection": .object(["state": .string("local")]),
            "agent": .object(["state": .string("none")]),
        ]
        let runningLifecycles: [String: JSONValue] = [
            "processPhase": .string("spawning"),
            "integration": .object(["state": .string("neverReported")]),
            "command": .object(["state": .string("running"), "text": .string("swift test")]),
            "connection": .object(["state": .string("local")]),
            "agent": .object(["state": .string("none")]),
        ]
        // No tab in this fixture is zoomed, so every encoded pane carries the
        // same `isZoomed: false`.
        func pane(_ fields: [String: JSONValue], lifecycles: [String: JSONValue]) -> JSONValue {
            .object(fields
                .merging(["isZoomed": .bool(false)]) { field, _ in field }
                .merging(lifecycles) { _, lifecycle in lifecycle })
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
        let tab = TabModel(id: tabId, paneTree: PaneTree(root: .leaf(pane), focusedPaneId: paneId))
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

    @Test("ls names the row whose inline rename editor is open")
    func lsNamesOpenInlineRenameTarget() throws {
        // Intent: the state listing reports the tab or group whose sidebar
        //   editor is open, and reports nothing while no session exists.
        // Why it exists: an agent reproducing a rename issue has to be able to
        //   read whether an editor is open and on which row. Every writer --
        //   the menu and the double-click alike -- now begins the session
        //   through the model, so the listing can answer honestly.
        // Scenario: spec-first -- the user starts renaming a tab, then starts
        //   renaming a group instead.
        var model = makeModel()
        createTab(&model)
        let tabId = try #require(selectedTab(in: model)).id
        let groupId = try #require(model.groups.first).id

        #expect(try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.ls.rawValue))["inlineRename"] == nil,
            "no session is open before any begin")

        _ = update(&model, .beginSidebarRename(target: .tab(tabId)))
        #expect(try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.ls.rawValue))["inlineRename"]
            == .object(["type": .string("tab"), "tabId": .string(tabId.rawValue.uuidString)]))

        _ = update(&model, .beginSidebarRename(target: .group(groupId)))
        #expect(try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.ls.rawValue))["inlineRename"]
            == .object(["type": .string("group"), "groupId": .string(groupId.rawValue.uuidString)]),
            "a second begin moves the reported session to its target")
    }

    @Test("ls reports no open inline rename once the session ends")
    func lsReportsNoInlineRenameAfterSessionEnds() throws {
        // Intent: every rename-ending cause the model can reach leaves the
        //   listing reporting no open session.
        // Why it exists: a listing that keeps naming a closed editor is worse
        //   than no listing, because an agent would wait on a session that
        //   ended.
        // Scenario: spec-first -- the editor closes on its own, and the row it
        //   was editing goes away underneath it.
        func openTabRename(_ model: inout AppModel) throws -> TabId {
            let tabId = try #require(selectedTab(in: model)).id
            _ = update(&model, .beginSidebarRename(target: .tab(tabId)))
            #expect(try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.ls.rawValue))["inlineRename"] != nil)
            return tabId
        }
        func reportedRename(_ model: inout AppModel) throws -> JSONValue? {
            try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.ls.rawValue))["inlineRename"]
        }

        // The editor closes and reports the session it ended.
        var ended = makeModel()
        createTab(&ended)
        _ = try openTabRename(&ended)
        _ = update(&ended, .sidebarRenameEnded(session: try #require(ended.sidebarRename).id))
        #expect(try reportedRename(&ended) == nil)

        // The edited tab is closed while its editor is open.
        var closedTab = makeModel()
        createTab(&closedTab)
        createTab(&closedTab)
        let closedTabId = try openTabRename(&closedTab)
        _ = sendIpc(
            &closedTab,
            method: IpcRequestMethod.tabClose.rawValue,
            params: .object(["tab": .string(closedTabId.rawValue.uuidString)])
        )
        #expect(try reportedRename(&closedTab) == nil)

        // The edited group is closed while its editor is open.
        var closedGroup = makeModel()
        createTab(&closedGroup)
        _ = update(&closedGroup, .createGroup(name: "Builds"))
        let closedGroupId = closedGroup.groups[1].id
        _ = update(&closedGroup, .beginSidebarRename(target: .group(closedGroupId)))
        #expect(try reportedRename(&closedGroup) != nil)
        _ = sendIpc(&closedGroup, method: IpcRequestMethod.groupClose.rawValue, params: .object([
            "group": .string(closedGroupId.rawValue.uuidString),
        ]))
        #expect(try reportedRename(&closedGroup) == nil)
    }

    @Test("agent.attach routes through the pane owner before its reply")
    func agentAttachRoutesThroughPaneOwnerBeforeReply() throws {
        // Intent: agent.attach reduces the model before returning its reply.
        // Why it exists: reply ordering is guaranteed by one pure update pass.
        // Scenario: a Claude SessionStart hook reports its session id from
        //   inside a DanTerm pane.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId

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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId

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
                "isZoomed": .bool(false),
                "cwd": .null,
                "integration": .object(["state": .string("neverReported")]),
                "command": .object(["state": .string("idle")]),
                "connection": .object(["state": .string("local")]),
                "agent": .object(["state": .string("none")]),
                "processPhase": .string("spawning"),
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId

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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId

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
        let backgroundPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
        _ = update(&model, .createGroup(name: "Other"))
        let otherGroupId = model.groups.last!.id
        createTab(&model, inGroupId: otherGroupId)
        let contextPaneId = selectedTab(in: model)!.paneTree.focusedPaneId

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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        let tabId = selectedTab(in: model)!.id

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInfo.rawValue,
            params: .object([
                "pane": .string(paneId.rawValue.uuidString),
                "start": .string("beginning"),
                "mode": .string("raw"),
            ])
        )

        let reply = try requireIpcReply(commands)
        #expect(reply["pane"]?["id"]?.asString == paneId.rawValue.uuidString)
        #expect(reply["tab"]?["id"]?.asString == tabId.rawValue.uuidString)
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        let backgroundPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
        createTab(&model)
        let foregroundTabId = selectedTab(in: model)!.id
        let foregroundPaneId = selectedTab(in: model)!.paneTree.focusedPaneId

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
        #expect(model.sidebarRenameTarget == nil,
            "remote creation must not request AppKit focus")
        #expect(reply["group"]?["id"]?.asString == created.id.rawValue.uuidString)
        #expect(reply["group"]?["name"]?.asString == "Builds")
        #expect(reply["tab"]?["id"]?.asString == created.tabs[0].id.rawValue.uuidString)
        let paneId = try requirePaneId(
            reply["panes"]?.asArray?.first?["id"], "group.new should return pane id")
        #expect(created.tabs[0].paneTree.focusedPaneId == paneId)
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

    // This input drives `.deleteGroup` into the app confirmation, which leaves
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        #expect(model.pendingConfirmation == nil,
            "CLI tab.close should not show a close-tab confirmation")
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
        model.pendingConfirmation = pendingAppConfirmation()
        let env = makeTestEnv(
            instanceIdentity: try #require(DanTermInstanceIdentity(developmentSlot: 3))
        )

        let commands = sendIpc(&model, method: IpcRequestMethod.quit.rawValue, env: env)

        _ = try requireIpcReply(commands)
        #expect(hasEffect(commands, isTerminate))
        #expect(model.pendingConfirmation?.subject == .app)
    }

    @Test("remote quit is refused before instance authorization")
    func remoteQuitIsRefused() throws {
        // Intent: a remote caller cannot end the Mac instance it depends on.
        // Why it exists: remote authority is per request and must take precedence
        //   over the launcher's instance authorization.
        // Scenario: an admitted remote caller reaches a launcher pool slot.
        var model = makeModel()
        let env = makeTestEnv(
            instanceIdentity: try #require(DanTermInstanceIdentity(developmentSlot: 1))
        )
        let caller = IpcCallerIdentity.remote(
            nodeId: "node-remote",
            user: "dan@example.com",
            machineName: "phone"
        )

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.quit.rawValue,
            caller: caller,
            env: env
        )

        let error = try requireIpcError(commands)
        #expect(error.message == "quit is unavailable to remote callers")
        #expect(hasEffect(commands, isTerminate) == false)
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

    @Test("pane.close removes an explicit pane and reports its id")
    func paneCloseRemovesExplicitPaneAndReportsId() throws {
        // Intent: pane.close routes through the existing pane-close mutation,
        //   promotes the sibling, and replies with the closed pane id.
        // Why it exists: pins the IPC surface to the GUI's model operation
        //   instead of growing a second pane-removal implementation.
        // Scenario: spec-first close of the focused pane in a two-pane tab.
        var model = makeModel()
        createTab(&model)
        let survivorPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
        _ = update(&model, .splitPane(paneId: survivorPaneId, direction: .horizontal))
        let closedPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        #expect(tab.paneTree.focusedPaneId == survivorPaneId)
        if case .leaf(let survivor) = tab.paneTree.root {
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
        let closedPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId

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
        let survivorPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
        _ = update(&model, .splitPane(paneId: survivorPaneId, direction: .horizontal))
        let closedPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
        _ = update(&model, .addTodo(owner: .pane(closedPaneId), text: "pane task"))
        _ = update(&model, .addTodo(owner: .tab(tabId), text: "tab task"))

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneClose.rawValue,
            params: .object(["pane": .string(closedPaneId.rawValue.uuidString)])
        )

        _ = try requireIpcReply(commands)
        #expect(model.pane(closedPaneId) == nil)
        #expect(model.pendingConfirmation == nil)

        var tabModel = makeModel()
        createTab(&tabModel)
        let closedTabId = selectedTab(in: tabModel)!.id
        let solePaneId = selectedTab(in: tabModel)!.paneTree.focusedPaneId
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
        #expect(tabModel.pendingConfirmation == nil)
    }

    @Test("pane.split targets the named pane even when another tab is selected")
    func paneSplitTargetsNamedPaneEvenWhenAnotherTabSelected() throws {
        var model = makeModel()
        createTab(&model)
        let backgroundTabId = selectedTab(in: model)!.id
        let backgroundPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        #expect(allPaneIds(tabById(backgroundTabId, in: model)!.paneTree.root).count == 2)
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
        let callerPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
        _ = update(&model, .splitPane(paneId: callerPaneId, direction: .horizontal))
        let siblingPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
            tabById(tabId, in: model)!.paneTree.root
        else {
            Issue.record("expected explicit sibling pane to be split")
            return
        }
        #expect(first.id == callerPaneId)
        #expect(second.id == siblingPaneId)
        #expect(third.id == returnedPaneId)
    }

    @Test("pane.focus selects target tab and projects its responder")
    func paneFocusSelectsTabAndProjectsResponder() throws {
        // Intent: pane.focus selects the target's tab and records the pane target.
        // Why it exists: pins the focus-cross-tab path.
        // Scenario: spec-first cross-tab focus.
        var model = makeModel()
        createTab(&model)
        let targetTabId = selectedTab(in: model)!.id
        let targetPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        let firstPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
        _ = update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let secondPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
        updateTabForTest(tabId, in: &model) { $0.paneTree.focus(firstPaneId) }

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneFocus.rawValue,
            params: .object(["pane": .string(secondPaneId.rawValue.uuidString)])
        )

        let reply = try requireIpcReply(commands)
        #expect(reply["tab"]?["focusedPaneId"]?.asString == secondPaneId.rawValue.uuidString)
        #expect(tabById(tabId, in: model)?.paneTree.focusedPaneId == secondPaneId)
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
        let firstPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
        _ = update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let secondPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
        updateTabForTest(tabId, in: &model) { $0.paneTree.focus(firstPaneId) }
        model.todoPopover = .pane(firstPaneId)

        _ = sendIpc(
            &model,
            method: IpcRequestMethod.paneFocus.rawValue,
            params: .object(["pane": .string(secondPaneId.rawValue.uuidString)]),
            pane: selectedPaneId(in: model)
        )

        #expect(model.todoPopover == .pane(firstPaneId))
        #expect(tabById(tabId, in: model)?.paneTree.focusedPaneId == secondPaneId)
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
        let firstPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
        _ = update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let secondPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
        updateTabForTest(tabId, in: &model) { $0.paneTree.focus(firstPaneId) }
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
                        "isZoomed": .bool(false),
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
        let callerPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
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

    @Test("tab.new does not infer a group from a supplied pane")
    func tabNewDoesNotInferGroupFromPane() throws {
        var model = makeModel()
        createTab(&model)
        let callerPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
            let selectedPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
            model.updatePane(selectedPaneId) { $0.session?.cwd = "/selected" }
            createTab(&model)
            let callerPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        let paneIdInContext = selectedTab(in: model)!.paneTree.focusedPaneId
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
        let paneId = group?.tabs.last?.paneTree.focusedPaneId
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId

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
        let focusedPaneId = selectedTab(in: model)!.paneTree.focusedPaneId

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
        #expect(allPaneIds(tab.paneTree.root).contains(newPaneId), "target tab should contain new pane")
        #expect(tab.paneTree.focusedPaneId == focusedPaneId, "background split should preserve focused pane")
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
        let backgroundPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        #expect(allPaneIds(backgroundTab.paneTree.root).contains(newPaneId), "background tab should contain new pane")
        #expect(backgroundTab.paneTree.focusedPaneId == backgroundPaneId, "background split should preserve target focus")
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
            let contextPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        let targetPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
        createTab(&model)
        let contextPaneId = selectedTab(in: model)!.paneTree.focusedPaneId

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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        let targetPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
        createTab(&model)
        let contextPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
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

    @Test("todo delete rejects unknown id")
    func todoDeleteRejectsUnknownId() throws {
        // Intent: todoDelete with an unknown id returns -32602.
        // Why it exists: pins fail-closed for stale todo ids.
        // Scenario: spec-first stale todo delete.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object(["text": .string("echo hi")]),
            pane: paneId
        )
        #expect(hasEffect(commands) {
            if case .sendText(let pid, let text, _, _) = $0 { return pid == paneId && text == "echo hi" }
            return false
        }, "expected sendText command")
    }

    @Test("pane.input defers success until every submission is delivered")
    func paneInputDefersSuccessUntilEverySubmissionIsDelivered() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        let requestId = UUID()
        let request = try IpcRequest.decode(
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object([
                "pane": .string(paneId.rawValue.uuidString),
                "input": .array([
                    .object(["text": .string("ls")]),
                    .object(["key": .string("Enter")]),
                ]),
            ])
        )

        let commands = update(&model, .ipcRequest(reqId: requestId, caller: .local, request: request))
        let submissions = commands.compactMap { command -> InputSubmissionId? in
            switch command {
            case .sendInputText(_, _, let id, _), .sendInputKey(_, _, _, let id, _): id
            default: nil
            }
        }
        #expect(submissions.count == 2)
        #expect(commands.contains { if case .ipcReply = $0 { true } else { false } } == false)

        let first = update(
            &model,
            .inputSubmissionCompleted(id: submissions[0], result: .delivered)
        )
        #expect(first.isEmpty)
        let second = update(
            &model,
            .inputSubmissionCompleted(id: submissions[1], result: .delivered)
        )
        #expect(try requireIpcReply(second)["ok"]?.asBool == true)
    }

    @Test("pane.input preserves each host rejection reason in its IPC error")
    func paneInputRejectsOnceWhenAnySubmissionFails() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        let requestId = UUID()
        let request = try IpcRequest.decode(
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object([
                "pane": .string(paneId.rawValue.uuidString),
                "input": .array([
                    .object(["text": .string("a")]),
                    .object(["text": .string("b")]),
                ]),
            ])
        )
        let commands = update(&model, .ipcRequest(reqId: requestId, caller: .local, request: request))
        let submissions = commands.compactMap { command -> InputSubmissionId? in
            if case .sendInputText(_, _, let id, _) = command { return id }
            return nil
        }

        let failed = update(
            &model,
            .inputSubmissionCompleted(
                id: submissions[0],
                result: .rejected(.canonicalModeTimeout)
            )
        )
        let late = update(
            &model,
            .inputSubmissionCompleted(id: submissions[1], result: .delivered)
        )

        #expect(try requireIpcError(failed) == .init(
            code: -32603,
            message: "pane input timed out waiting for the tty to leave canonical mode"
        ))
        #expect(late.isEmpty)
    }

    @Test("pane.input keeps canonical timeout, process exit, and write failure distinct")
    func paneInputKeepsHostFailuresDistinct() throws {
        let cases: [(InputSubmissionFailure, String)] = [
            (
                .canonicalModeTimeout,
                "pane input timed out waiting for the tty to leave canonical mode"
            ),
            (
                .processEnded,
                "pane input was not delivered because the pane process ended"
            ),
            (
                .writeFailed(EIO),
                "pane input failed to write to the PTY (errno \(EIO))"
            ),
        ]

        for (failure, message) in cases {
            var model = makeModel()
            createTab(&model)
            let paneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
            let requestId = UUID()
            let request = try IpcRequest.decode(
                method: IpcRequestMethod.paneInput.rawValue,
                params: .object([
                    "pane": .string(paneId.rawValue.uuidString),
                    "text": .string("probe"),
                ])
            )
            let commands = update(
                &model,
                .ipcRequest(reqId: requestId, caller: .local, request: request)
            )
            let submissionId = try #require(commands.compactMap { command -> InputSubmissionId? in
                guard case .sendText(_, _, let id, _) = command else { return nil }
                return id
            }.first)

            let rejected = update(
                &model,
                .inputSubmissionCompleted(id: submissionId, result: .rejected(failure))
            )

            #expect(try requireIpcError(rejected) == .init(code: -32603, message: message))
        }
    }

    @Test("pane.info exposes a rejected launch input with its typed reason")
    func paneInfoExposesRejectedLaunchInput() throws {
        var model = makeModel()
        let commands = update(
            &model,
            .createTabInSelectedGroup(
                position: .afterSelected,
                launch: LaunchSpec(cmd: "printf ready", cwd: nil, title: nil),
                background: false
            )
        )
        let sessionId = try #require(commands.compactMap { command -> SessionId? in
            guard case .createSession(let id, _, _, _, _) = command else { return nil }
            return id
        }.first)
        let paneId = try #require(model.pane(owning: sessionId)?.id)

        let pending = try requireIpcReply(sendIpc(
            &model,
            method: IpcRequestMethod.paneInfo.rawValue,
            params: .object(["pane": .string(paneId.rawValue.uuidString)])
        ))
        #expect(pending["pane"]?["launchInput"] == .object([
            "state": .string("pending"),
        ]))

        _ = update(
            &model,
            .launchInputCompleted(
                sessionId: sessionId,
                result: .rejected(.writeFailed(EIO))
            )
        )
        let rejected = try requireIpcReply(sendIpc(
            &model,
            method: IpcRequestMethod.paneInfo.rawValue,
            params: .object(["pane": .string(paneId.rawValue.uuidString)])
        ))
        #expect(rejected["pane"]?["launchInput"] == .object([
            "state": .string("rejected"),
            "reason": .string("writeFailed"),
            "errno": .number(Double(EIO)),
        ]))
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        #expect(commands.count == 2)
        guard case .sendInputText(let p0, let t0, _, _) = commands[0] else {
            Issue.record("expected first command = sendInputText")
            return
        }
        #expect(p0 == paneId)
        #expect(t0 == "ls")
        guard case .sendInputKey(let p1, let key1, let mods1, _, _) = commands[1] else {
            Issue.record("expected second command = sendInputKey")
            return
        }
        #expect(p1 == paneId)
        #expect(key1 == KeyName.named(.enter))
        #expect(mods1 == KeyMods())
        #expect(commands.contains { if case .ipcReply = $0 { true } else { false } } == false)
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
            if case .sendInputKey(let p, let k, let m, _, _) = $0 {
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        // Intent: ctrl-c emits sendInputKey(.character("c"), .ctrl).
        // Why it exists: pins the ctrl modifier mapping.
        // Scenario: spec-first ctrl-c.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
            if case .sendInputKey(let p, let k, let m, _, _) = $0 {
                return p == paneId && k == .character("c") && m == [.ctrl]
            }
            return false
        }, "expected sendInputKey for C-c")
    }

    @Test("pane.input wheel event emits owner-side wheel command")
    func paneInputWheelEventEmitsWheelCommand() {
        // Intent: a wire wheel event retains direction and cell through pure dispatch.
        // Why it exists: lowering wheel input anywhere else could bypass the pane owner's
        //   authoritative mouse-tracking and screen-mode decision.
        // Scenario: a remote caller wheels up over column 4, row 2.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object([
                "input": .array([.object([
                    "wheel": .string("up"),
                    "column": .number(4),
                    "row": .number(2),
                ])])
            ]),
            pane: paneId
        )

        #expect(commands.contains { command in
            if case .sendInputWheel(
                let target,
                direction: .up,
                column: 4,
                row: 2,
                submissionId: _,
                waitGeneration: _
            ) = command {
                return target == paneId
            }
            return false
        })
    }

    @Test("pane.input with both text and input is invalid params")
    func paneInputBothTextAndInputIsInvalidParams() throws {
        // Intent: both `text` and `input` fail (one or the other,
        //   never both).
        // Why it exists: pins the mutual-exclusion rule.
        // Scenario: spec-first both-fields.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
            if case .sendInputKey(let target, .named(.tab), let modifiers, _, _) = command {
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
        let backgroundPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
        createTab(&model)
        let foregroundPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
            if case .sendInputText(let p, let t, _, _) = $0 {
                return p == backgroundPaneId && t == "hi"
            }
            return false
        }, "expected command targeting explicit pane")
    }

    @Test("pane.read emits viewport read command without immediate reply")
    func paneReadEmitsViewportReadNoImmediateReply() {
        // Intent: pane.read emits a single readPaneText command and no
        //   immediate ipcReply (the async response carries the data).
        // Why it exists: pins the async-read shape.
        // Scenario: spec-first viewport read.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
            let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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

    @Test("roster answers with the current roster and asks for a subscription")
    func rosterRepliesWithCurrentRosterAndSubscribes() {
        // Intent: one roster request produces one command that carries the roster the
        //   model projects right now, and nothing else.
        // Why it exists: the reply and the subscription share the request's socket, so
        //   a client that got a roster it cannot keep receiving would look identical to
        //   a working subscribe until the first change never arrived.
        // Scenario: the phone client subscribes over its tailnet connection.
        var model = makeModel()
        createTab(&model)
        createTab(&model)

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.roster.rawValue,
            caller: .remote(nodeId: "n1", user: "dan", machineName: "phone")
        )

        #expect(commands.count == 1)
        guard case .subscribeRoster(_, let roster) = commands[0] else {
            Issue.record("expected subscribeRoster command")
            return
        }
        #expect(roster == paneRoster(in: model))
        #expect(roster.panes.count == 2)
    }

    @Test("a repeat roster request answers again without a second subscription")
    func repeatRosterRequestAnswersAgain() {
        // Intent: subscribing twice on one connection is the same request twice, not
        //   two subscriptions -- dispatch says nothing about who already subscribed.
        // Why it exists: the wire carries no subscription id, so idempotence is the
        //   only thing that keeps a reconnecting client from doubling its own pushes.
        // Scenario: a phone re-sends its subscribe after a stalled bootstrap.
        var model = makeModel()
        createTab(&model)

        let first = sendIpc(&model, method: IpcRequestMethod.roster.rawValue)
        let second = sendIpc(&model, method: IpcRequestMethod.roster.rawValue)

        guard case .subscribeRoster(_, let firstRoster) = first.first,
              case .subscribeRoster(_, let secondRoster) = second.first
        else {
            Issue.record("expected subscribeRoster commands")
            return
        }
        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(firstRoster == secondRoster)
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneTape.rawValue,
            params: .object([
                "pane": .string(paneId.rawValue.uuidString),
                "start": .string("beginning"),
                "mode": .string("raw"),
            ])
        )

        #expect(commands.count == 1)
        guard case .streamPaneTape(
            _, let commandPaneId, let capture, let start, let policy
        ) = commands[0] else {
            Issue.record("expected streamPaneTape command")
            return
        }
        #expect(commandPaneId == paneId)
        #expect(capture == .dump)
        #expect(start == .beginning)
        #expect(policy == .raw)
    }

    @Test("pane.tape follow resolves the addressed pane and preserves tail mode")
    func paneTapeFollowResolvesAddressedPane() {
        // Intent: follow requests emit a long-lived stream command for the explicit pane.
        // Why it exists: the one-reply dump command cannot represent later notifications.
        // Scenario: an agent asks to tail a known background pane without its backlog.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneTape.rawValue,
            params: .object([
                "pane": .string(paneId.rawValue.uuidString),
                "follow": .bool(true),
                "start": .string("now"),
                "mode": .string("reconstructible"),
            ])
        )

        #expect(commands.count == 1)
        guard case .streamPaneTape(
            _, let commandPaneId, let capture, let start, let policy
        ) = commands[0] else {
            Issue.record("expected streamPaneTape command")
            return
        }
        #expect(commandPaneId == paneId)
        #expect(capture == .follow)
        #expect(start == .now)
        // The request named no budget, so the stream runs under the server default.
        #expect(
            policy
                == .reconstructible(
                    historyBudgetBytes: PaneTapeSyncPolicy.defaultHistoryBudgetBytes
                )
        )
    }

    // The pane target itself is swept with every other targeting method; this
    // covers the one param that is pane.tape's own.
    @Test("pane.tape rejects a start it cannot interpret")
    func paneTapeRejectsInvalidStart() throws {
        var invalidModel = makeModel()
        createTab(&invalidModel)
        let paneId = selectedTab(in: invalidModel)!.paneTree.focusedPaneId
        let invalid = sendIpc(
            &invalidModel,
            method: IpcRequestMethod.paneTape.rawValue,
            params: .object([
                "pane": .string(paneId.rawValue.uuidString),
                "start": .string("bogus"),
                "mode": .string("raw"),
            ])
        )
        #expect(try requireIpcError(invalid) == .init(
            code: -32602,
            message: "invalid tape start"
        ))
    }

    @Test("pane.snapshot requests exact current state from the addressed pane")
    func paneSnapshotRequestsExactCurrentState() {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneSnapshot.rawValue,
            pane: paneId
        )

        #expect(commands.count == 1)
        guard case .streamPaneTape(
            _, let commandPaneId, let capture, let start, let policy
        ) = commands[0] else {
            Issue.record("expected streamPaneTape command")
            return
        }
        #expect(commandPaneId == paneId)
        #expect(capture == .snapshot)
        #expect(start == .now)
        // A snapshot is the exact-state consumer: it takes no history budget, so a pane with
        // history deeper than any default still snapshots whole.
        #expect(policy == .reconstructible(historyBudgetBytes: nil))
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
    caller: IpcCallerIdentity = .local,
    env: CoreEnv = .live
) -> [Command] {
    var effectiveParams = params
    if let pane, case .object(var object) = effectiveParams, object["pane"] == nil {
        object["pane"] = .string(pane.rawValue.uuidString)
        effectiveParams = .object(object)
    }
    let reqId = UUID()
    do {
        let commands = update(
            &model,
            .ipcRequest(
                reqId: reqId,
                caller: caller,
                request: try IpcRequest.decode(method: method, params: effectiveParams)
            ),
            env: env
        )
        let completionCommands = commands.flatMap { command -> [Command] in
            guard case .createSession(let sessionId, _, _, _, _) = command else { return [] }
            return update(&model, .sessionProcessStarted(sessionId: sessionId), env: env)
        }
        return commands + completionCommands
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
    selectedTab(in: model)!.paneTree.focusedPaneId
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
    #expect(tab.paneTree.focusedPaneId == paneId)
    if case .leaf(let rootPane) = tab.paneTree.root {
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

// MARK: - pane.resize

@Suite struct UpdateIpcResizeTests {
    @Test("pane.resize sets, replaces, and clears the pane's grid override")
    func paneResizeSetsReplacesAndClears() throws {
        // Intent: a resize stores exactly the grid asked for, a second resize
        //   replaces the first outright, and the fit form removes the override.
        // Why it exists: the model records no owner and no tenure, so a claim can
        //   only be correct if the last request wins and a fit is a plain clear.
        // Scenario: spec-first; a phone claims a pane at 60x20, claims it again at
        //   40x16, and the Mac hands it back with a fit.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedPaneId(in: model)

        let claimed = try requireIpcReply(sendIpc(
            &model,
            method: IpcRequestMethod.paneResize.rawValue,
            params: .object(["columns": .number(60), "rows": .number(20)]),
            pane: paneId
        ))
        #expect(model.pane(paneId)?.gridOverride == PaneGridOverride(columns: 60, rows: 20))
        #expect(claimed["pane"]?["gridOverride"] == .object([
            "columns": .number(60),
            "rows": .number(20),
        ]))

        _ = sendIpc(
            &model,
            method: IpcRequestMethod.paneResize.rawValue,
            params: .object(["columns": .number(40), "rows": .number(16)]),
            pane: paneId
        )
        #expect(model.pane(paneId)?.gridOverride == PaneGridOverride(columns: 40, rows: 16))

        let fitted = try requireIpcReply(sendIpc(
            &model,
            method: IpcRequestMethod.paneResize.rawValue,
            params: .object(["fit": .bool(true)]),
            pane: paneId
        ))
        #expect(model.pane(paneId)?.gridOverride == nil)
        #expect(fitted["pane"]?["gridOverride"] == nil)
    }

    // The engine floor and the storage ceiling are the accepted range, and a
    // request outside it is refused rather than clamped: a clamped grid is a size
    // nobody asked for, which the caller would then have to discover by reading
    // the reply back.
    @Test("pane.resize accepts the range ends and refuses everything past them", arguments: [
        (columns: 2, rows: 1, accepted: true),
        (columns: 1024, rows: 1024, accepted: true),
        (columns: 1, rows: 24, accepted: false),
        (columns: 80, rows: 0, accepted: false),
        (columns: 1025, rows: 24, accepted: false),
        (columns: 80, rows: 1025, accepted: false),
        (columns: -80, rows: -24, accepted: false),
    ])
    func paneResizeBoundsTheAcceptedGrid(columns: Int, rows: Int, accepted: Bool) throws {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedPaneId(in: model)

        let commands = sendIpc(
            &model,
            method: IpcRequestMethod.paneResize.rawValue,
            params: .object(["columns": .number(Double(columns)), "rows": .number(Double(rows))]),
            pane: paneId
        )

        if accepted {
            _ = try requireIpcReply(commands)
            #expect(model.pane(paneId)?.gridOverride == PaneGridOverride(columns: columns, rows: rows))
        } else {
            let error = try requireIpcError(commands)
            #expect(error.code == -32602)
            #expect(error.message == "columns must be 2-1024 and rows must be 1-1024")
            #expect(model.pane(paneId)?.gridOverride == nil)
        }
    }

    @Test("ls reports a claimed grid on the pane it belongs to")
    func lsReportsClaimedGrid() throws {
        // Intent: `ls` carries the override, so a client can see which panes are
        //   running at a claimed size without asking about each one.
        // Why it exists: the override is durable until an explicit take-back, so a
        //   client that cannot see it cannot tell a small pane from a claimed one.
        // Scenario: spec-first; one pane of a split tab is claimed at 60x20.
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .splitFocusedPane(direction: .horizontal))
        let claimedId = selectedPaneId(in: model)
        let otherId = try #require(model.allPaneIds.first { $0 != claimedId })

        _ = sendIpc(
            &model,
            method: IpcRequestMethod.paneResize.rawValue,
            params: .object(["columns": .number(60), "rows": .number(20)]),
            pane: claimedId
        )
        let listing = try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.ls.rawValue))

        #expect(paneObject(claimedId, in: listing)?["gridOverride"] == .object([
            "columns": .number(60),
            "rows": .number(20),
        ]))
        #expect(paneObject(otherId, in: listing)?["gridOverride"] == nil)
    }
}

/// Finds one pane's encoded object anywhere in an `ls` listing, so a reporting
/// assertion does not have to restate the split tree's shape.
private func paneObject(_ paneId: PaneId, in listing: JSONValue) -> JSONValue? {
    func search(_ value: JSONValue) -> JSONValue? {
        switch value {
        case .object(let object):
            if object["id"] == .string(paneId.rawValue.uuidString), object["title"] != nil {
                return value
            }
            for nested in object.values {
                if let found = search(nested) { return found }
            }
            return nil
        case .array(let items):
            for item in items {
                if let found = search(item) { return found }
            }
            return nil
        default:
            return nil
        }
    }
    return search(listing)
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        let params = JSONValue.object([
            "pane": .string(paneId.rawValue.uuidString),
            "state": .string("on"),
        ])

        for _ in 0..<2 {
            let reply = try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.paneZoom.rawValue, params: params))
            #expect(reply["tab"]?["isZoomed"]?.asBool == true)
            #expect(selectedTab(in: model)!.paneTree.isZoomed)
        }

        let off = JSONValue.object([
            "pane": .string(paneId.rawValue.uuidString),
            "state": .string("off"),
        ])
        for _ in 0..<2 {
            let reply = try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.paneZoom.rawValue, params: off))
            #expect(reply["tab"]?["isZoomed"]?.asBool == false)
            #expect(selectedTab(in: model)!.paneTree.isZoomed == false)
        }
    }

    @Test("pane.zoom toggle flips the tab and reports the resulting state")
    func paneZoomToggleFlips() throws {
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .splitFocusedPane(direction: .horizontal))
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId

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

    @Test("pane.zoom resolves on/off/toggle against the pane it names")
    func paneZoomResolvesAgainstTheNamedPane() throws {
        // Intent: `on`, `off`, and `toggle` each read and write the named
        //   pane's own zoom state -- including `on` for a pane whose tab is
        //   already zoomed on a sibling -- and the reply's pane-level
        //   `isZoomed` says where the zoom landed.
        // Why it exists: the request used to compare against the tab flag, so
        //   `on` for an unzoomed pane in an already-zoomed tab was read as
        //   "nothing to do" and left the zoom on the wrong pane. A caller then
        //   had no field that could tell it so. Spec-first.
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .splitFocusedPane(direction: .horizontal))
        let tree = selectedTab(in: model)!.paneTree
        let focused = tree.focusedPaneId
        let sibling = allPaneIds(tree.root).first { $0 != focused }!

        func zoom(_ pane: PaneId, _ state: String) throws -> JSONValue {
            try requireIpcReply(sendIpc(
                &model,
                method: IpcRequestMethod.paneZoom.rawValue,
                params: .object([
                    "pane": .string(pane.rawValue.uuidString),
                    "state": .string(state),
                ])
            ))
        }

        let zoomedFocused = try zoom(focused, "on")
        #expect(zoomedFocused["pane"]?["isZoomed"]?.asBool == true)

        let movedToSibling = try zoom(sibling, "on")
        #expect(
            movedToSibling["pane"]?["isZoomed"]?.asBool == true,
            "`on` must move the zoom onto the named pane, not read the tab as already done")
        #expect(selectedTab(in: model)!.paneTree.zoomedPaneId == sibling)

        let toggledOff = try zoom(sibling, "toggle")
        #expect(toggledOff["pane"]?["isZoomed"]?.asBool == false)
        #expect(selectedTab(in: model)!.paneTree.zoomedPaneId == nil)

        let offOnUnzoomed = try zoom(focused, "off")
        #expect(offOnUnzoomed["pane"]?["isZoomed"]?.asBool == false, "`off` is idempotent")
    }

    @Test("ls and pane.info report zoom on the pane that holds it")
    func paneLevelZoomIsReportedByLsAndPaneInfo() throws {
        // Intent: with one pane of a split tab zoomed, that pane's encoded
        //   `isZoomed` is true and its sibling's is false -- in the `ls`
        //   listing and in each pane's own `pane.info` reply.
        // Why it exists: the tab-level flag alone cannot say which pane the
        //   zoom is on, so a caller that zoomed a pane had no field to read
        //   back to confirm where the zoom landed. Spec-first.
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .splitFocusedPane(direction: .horizontal))
        let tree = selectedTab(in: model)!.paneTree
        let zoomedPane = tree.focusedPaneId
        let sibling = allPaneIds(tree.root).first { $0 != zoomedPane }!
        _ = update(&model, .toggleZoomPane(paneId: zoomedPane))

        let listing = try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.ls.rawValue))
        #expect(paneObject(zoomedPane, in: listing)?["isZoomed"]?.asBool == true)
        #expect(paneObject(sibling, in: listing)?["isZoomed"]?.asBool == false)

        let zoomedInfo = try requireIpcReply(sendIpc(
            &model, method: IpcRequestMethod.paneInfo.rawValue, pane: zoomedPane))
        #expect(zoomedInfo["pane"]?["isZoomed"]?.asBool == true)

        let siblingInfo = try requireIpcReply(sendIpc(
            &model, method: IpcRequestMethod.paneInfo.rawValue, pane: sibling))
        #expect(siblingInfo["pane"]?["isZoomed"]?.asBool == false)
        #expect(
            siblingInfo["tab"]?["isZoomed"]?.asBool == true,
            "the tab-level fact stays what it was: this tab is zoomed on some pane")
    }

    @Test("pane.zoom rejects an unknown state and an unknown pane")
    func paneZoomRejectsBadInput() throws {
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .splitFocusedPane(direction: .horizontal))
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId

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
        #expect(selectedTab(in: model)!.paneTree.isZoomed == false)
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
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        let context = paneId

        let before = try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.paneInfo.rawValue, pane: context))
        #expect(before["tab"]?["isZoomed"]?.asBool == false)

        _ = update(&model, .toggleZoomPane(paneId: paneId))

        let after = try requireIpcReply(sendIpc(&model, method: IpcRequestMethod.paneInfo.rawValue, pane: context))
        #expect(after["tab"]?["isZoomed"]?.asBool == true)
    }

    @Test("pane.info reports spawning then running without shell integration")
    func paneInfoReportsProcessPhaseWithoutIntegration() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)

        let spawning = try requireIpcReply(sendIpc(
            &model,
            method: IpcRequestMethod.paneInfo.rawValue,
            pane: paneId
        ))
        _ = update(&model, .sessionProcessStarted(sessionId: sessionId))
        let running = try requireIpcReply(sendIpc(
            &model,
            method: IpcRequestMethod.paneInfo.rawValue,
            pane: paneId
        ))

        #expect(spawning["pane"]?["processPhase"]?.asString == "spawning")
        #expect(running["pane"]?["processPhase"]?.asString == "running")
        #expect(running["pane"]?["integration"]?["state"]?.asString == "neverReported")
    }

    @Test("every creation method defers its reply until process start")
    func everyCreationMethodDefersReplyUntilProcessStart() throws {
        for surface in ["group.new", "tab.new", "pane.split"] {
            var model = makeModel()
            createTab(&model)
            let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
            let groupId = model.groups[0].id
            let params: JSONValue
            switch surface {
            case "group.new":
                params = .object(["name": .string("Builds")])
            case "tab.new":
                params = .object(["group": .string(groupId.rawValue.uuidString)])
            default:
                params = .object([
                    "pane": .string(paneId.rawValue.uuidString),
                    "direction": .string("horizontal"),
                ])
            }
            let request = try IpcRequest.decode(method: surface, params: params)
            let requestId = UUID()

            let commands = update(
                &model,
                .ipcRequest(reqId: requestId, caller: .local, request: request)
            )
            let sessionId = try #require(commands.compactMap { command -> SessionId? in
                if case .createSession(let id, _, _, _, _) = command { return id }
                return nil
            }.first)

            #expect(commands.contains { if case .ipcReply = $0 { true } else { false } } == false)
            let completed = update(&model, .sessionProcessStarted(sessionId: sessionId))
            #expect(completed.contains {
                if case .ipcReply(let id, _) = $0 { return id == requestId }
                return false
            })
        }
    }
}
