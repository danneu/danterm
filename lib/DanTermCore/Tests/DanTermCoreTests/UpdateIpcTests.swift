// Swift Testing migration of the legacy `tests/UpdateIpcTests.swift` harness
// suite. Pins the pure `update()` handling of DanTerm IPC requests across
// the protocol surface: ls (full snapshot), pane.info (explicit + implicit
// pane context, missing/invalid target), tab.rename (set/clear, live-tab
// derivation from pane context, explicit-vs-context precedence, malformed
// inputs), pane.split (context-pane targeting, explicit-pane overrides,
// malformed/unknown/non-string/orphan failures, background and launch
// flows), pane.focus (selection + first responder + popover preservation +
// alert clear), tab.new (explicit group, group context, background, launch,
// afterTab matching, malformed groups, cwd inheritance), theme.set
// (explicit-vs-context precedence), the todo command family (list/add/edit/
// done/open/delete/clear-completed across context + explicit-pane), and
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

    @Test("malformed context returns invalid params")
    func malformedContextReturnsInvalidParams() throws {
        // Intent: an IPC context with a malformed pane id returns
        //   invalid-params (-32602) before any mutation.
        // Why it exists: pins the context-validation guard.
        // Scenario: spec-first malformed context.
        var model = makeModel()
        createTab(&model)
        let commands = sendIpc(&model, method: Methods.tabRename, context: IpcRequestContext(paneId: "not-a-uuid"))
        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
    }

    @Test("ls encodes the documented rich model directly with live pane semantics")
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
            title: "shell",
            cwd: "/Users/testhome/work",
            theme: "Tokyo Night",
            fontSizeSteps: 2,
            todos: [TodoItem(id: paneTodoId, text: "ship", isDone: false)]
        )
        let paneB = PaneModel(id: paneBId, title: "tests", cwd: "/tmp")
        let paneC = PaneModel(id: paneCId, title: "logs")
        let paneD = PaneModel(id: paneDId, title: "archive")
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
        let semantics = PaneSemanticState(command: .running("swift test"))
        let commands = sendIpc(
            &model,
            method: Methods.ls,
            livePaneState: LivePaneStateView(semanticsByPaneId: [paneAId: semantics]),
            env: makeTestEnv(homeDirectory: "/Users/testhome")
        )

        let result = try requireIpcReply(commands)
        let neutralSemantics: JSONValue = .object([
            "integration": .object(["state": .string("neverReported")]),
            "command": .object(["state": .string("idle")]),
            "connection": .object(["state": .string("local")]),
            "agent": .object(["state": .string("none")]),
        ])
        let runningSemantics: JSONValue = .object([
            "integration": .object(["state": .string("neverReported")]),
            "command": .object(["state": .string("running"), "text": .string("swift test")]),
            "connection": .object(["state": .string("local")]),
            "agent": .object(["state": .string("none")]),
        ])
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
                                "pane": .object([
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
                                    "semantics": runningSemantics,
                                ]),
                            ]),
                            "second": .object([
                                "type": .string("split"),
                                "id": .string(splitBId.rawValue.uuidString),
                                "direction": .string("vertical"),
                                "ratio": .number(0.4),
                                "first": .object([
                                    "type": .string("leaf"),
                                    "pane": .object([
                                        "id": .string(paneBId.rawValue.uuidString),
                                        "title": .string("tests"),
                                        "cwd": .string("/tmp"),
                                        "semantics": neutralSemantics,
                                    ]),
                                ]),
                                "second": .object([
                                    "type": .string("leaf"),
                                    "pane": .object([
                                        "id": .string(paneCId.rawValue.uuidString),
                                        "title": .string("logs"),
                                        "semantics": neutralSemantics,
                                    ]),
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
                            "pane": .object([
                                "id": .string(paneDId.rawValue.uuidString),
                                "title": .string("archive"),
                                "semantics": neutralSemantics,
                            ]),
                        ]),
                    ])]),
                ]),
            ]),
            "selectedTabId": .string(tabAId.rawValue.uuidString),
        ])
        #expect(result == expected)
    }

    @Test("ls attaches semantics only to panes when entity ids collide")
    func lsScopesSemanticsToPaneEntities() throws {
        let rawId = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let paneId = PaneId(rawValue: rawId)
        let tabId = TabId(rawValue: rawId)
        let groupId = GroupId(rawValue: rawId)
        let pane = PaneModel(id: paneId)
        let tab = TabModel(id: tabId, focusedPaneId: paneId, rootNode: .leaf(pane))
        var model = AppModel(
            groups: [GroupModel(id: groupId, name: "collision", tabs: [tab])],
            selectedTabId: tabId
        )
        let state = PaneSemanticState(command: .running("make test"))

        let result = try requireIpcReply(sendIpc(
            &model,
            method: Methods.ls,
            livePaneState: LivePaneStateView(semanticsByPaneId: [paneId: state])
        ))
        let group = try #require(result["groups"]?.asArray?.first)
        let encodedTab = try #require(group["tabs"]?.asArray?.first)
        let encodedPane = encodedTab["rootNode"]?["pane"]

        #expect(group["semantics"] == nil)
        #expect(encodedTab["semantics"] == nil)
        #expect(encodedPane?["semantics"] == paneSemanticInspectionValue(state))
    }

    @Test("agent.attach routes through the pane owner before its reply")
    func agentAttachRoutesThroughPaneOwnerBeforeReply() throws {
        // Intent: agent.attach validates the session and returns one owner-routed
        //   command instead of mutating AppModel or replying from pure update.
        // Why it exists: success must be written only after the live session has
        //   applied and projected the attachment.
        // Scenario: a Claude SessionStart hook reports its session id from
        //   inside a DanTerm pane.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId

        let commands = sendIpc(
            &model,
            method: Methods.agentAttach,
            params: .object([
                "kind": .string("Claude"),
                "id": .string("4f3a2b1c-0000-4000-9000-abcdef123456"),
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )

        #expect(commands.count == 1)
        guard case .applyPaneSemanticIpc(_, let commandPaneId, let event) = commands[0] else {
            Issue.record("expected pane-owner semantic IPC command")
            return
        }
        #expect(commandPaneId == paneId)
        let session = try #require(AgentSession(
            kind: "claude",
            sessionId: "4f3a2b1c-0000-4000-9000-abcdef123456"
        ))
        #expect(event == .agentAttached(session))
    }

    @Test("pane.info replies directly with complete default semantics")
    func paneInfoRepliesDirectlyWithDefaultSemantics() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId

        let commands = sendIpc(
            &model,
            method: Methods.paneInfo,
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
        )

        let result = try requireIpcReply(commands)
        let tab = try #require(selectedTab(in: model))
        let group = try #require(model.groups.first)
        let expected: JSONValue = .object([
            "pane": .object([
                "id": .string(paneId.rawValue.uuidString),
                "title": .string("Terminal"),
                "cwd": .null,
                "semantics": .object([
                    "integration": .object(["state": .string("neverReported")]),
                    "command": .object(["state": .string("idle")]),
                    "connection": .object(["state": .string("local")]),
                    "agent": .object(["state": .string("none")]),
                ]),
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
        let context = IpcRequestContext(paneId: paneId.rawValue.uuidString)

        let activity = sendIpc(
            &model,
            method: Methods.agentActivity,
            params: .object([
                "kind": .string("codex"),
                "id": .string("thread-1"),
                "state": .string("waiting"),
            ]),
            context: context
        )
        let detach = sendIpc(
            &model,
            method: Methods.agentDetach,
            params: .object(["kind": .string("codex"), "id": .string("thread-1")]),
            context: context
        )

        guard case .applyPaneSemanticIpc(_, let activityPane, let activityEvent) = activity.first,
              case .applyPaneSemanticIpc(_, let detachPane, let detachEvent) = detach.first
        else {
            Issue.record("expected pane-owner semantic IPC commands")
            return
        }
        let session = try #require(AgentSession(kind: "codex", sessionId: "thread-1"))
        #expect(activity.count == 1)
        #expect(activityPane == paneId)
        #expect(activityEvent == .agentActivityChanged(session: session, activity: .waiting))
        #expect(detach.count == 1)
        #expect(detachPane == paneId)
        #expect(detachEvent == .agentDetached(session))
    }

    @Test("agent activity rejects unsupported states before pane mutation")
    func agentActivityRejectsUnsupportedStates() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId

        let commands = sendIpc(
            &model,
            method: Methods.agentActivity,
            params: .object([
                "kind": .string("codex"),
                "id": .string("thread-1"),
                "state": .string("busy"),
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
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
            method: Methods.agentAttach,
            params: .object([
                "kind": .string("claude"),
                "id": .string("--dangerously-skip-permissions"),
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
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
            method: Methods.paneInfo,
            params: .object(["pane": .string(backgroundPaneId.rawValue.uuidString)]),
            context: IpcRequestContext(paneId: contextPaneId.rawValue.uuidString)
        )

        let reply = try requireIpcReply(commands)
        #expect(reply["pane"]?["id"]?.asString == backgroundPaneId.rawValue.uuidString)
        #expect(reply["tab"]?["id"]?.asString == backgroundTabId.rawValue.uuidString)
        #expect(reply["tab"]?["groupId"]?.asString == backgroundGroupId.rawValue.uuidString)
        #expect(reply["group"]?["id"]?.asString == backgroundGroupId.rawValue.uuidString)
        #expect(reply["group"]?["name"]?.asString == "General")
    }

    @Test("pane.info implicit pane uses pane context")
    func paneInfoImplicitPaneUsesContext() throws {
        // Intent: pane.info without an explicit pane uses the IPC
        //   context pane.
        // Why it exists: pins the implicit-context branch.
        // Scenario: spec-first implicit pane.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let tabId = selectedTab(in: model)!.id

        let commands = sendIpc(
            &model,
            method: Methods.paneInfo,
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
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

        let missing = sendIpc(&model, method: Methods.paneInfo, context: IpcRequestContext())
        #expect(try requireIpcError(missing).code == -32602)

        let invalid = sendIpc(
            &model,
            method: Methods.paneInfo,
            params: .object(["pane": .string("not-a-uuid")]),
            context: IpcRequestContext(paneId: contextPaneId.rawValue.uuidString)
        )
        #expect(try requireIpcError(invalid).code == -32602)

        let unknown = sendIpc(
            &model,
            method: Methods.paneInfo,
            params: .object(["pane": .string(UUID().uuidString)]),
            context: IpcRequestContext(paneId: contextPaneId.rawValue.uuidString)
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
        let ctx = contextForSelectedPane(in: model)
        let tabId = selectedTab(in: model)!.id

        let setEffects = sendIpc(&model, method: Methods.tabRename, params: .object(["title": .string("hello")]), context: ctx)
        let setReply = try requireIpcReply(setEffects)
        #expect(setReply["tab"]?["id"]?.asString == tabId.rawValue.uuidString)
        #expect(setReply["tab"]?["customTitle"]?.asString == "hello")
        #expect(tabById(tabId, in: model)?.customTitle == "hello")

        let clearEffects = sendIpc(&model, method: Methods.tabRename, params: .object(["title": .null]), context: ctx)
        let clearReply = try requireIpcReply(clearEffects)
        #expect(clearReply["tab"]?["customTitle"] == .null)
        #expect(tabById(tabId, in: model)?.customTitle == nil)
    }

    @Test("tab.rename derives live tab from pane context when pane moved")
    func tabRenameDerivesLiveTabFromPaneContext() {
        // Intent: tab.rename uses the live tab of the pane in context;
        //   after movePaneToTab, the new live tab is targeted.
        // Why it exists: pins the live-derivation rule.
        // Scenario: spec-first live tab via pane.
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
            method: Methods.tabRename,
            params: .object([
                "tab": .string(backgroundTabId.rawValue.uuidString),
                "title": .string("build"),
            ]),
            context: IpcRequestContext(paneId: foregroundPaneId.rawValue.uuidString)
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
                method: Methods.tabRename,
                params: .object([
                    "tab": tabValue,
                    "title": .string("should-not-apply"),
                ]),
                context: IpcRequestContext(paneId: contextPaneId.rawValue.uuidString)
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
            method: Methods.tabRename,
            params: .object(["title": .string("missing-context")]),
            context: IpcRequestContext()
        )

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(tabById(tabId, in: model)?.customTitle == nil)
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
            method: Methods.tabClose,
            params: .object(["tab": .string(closedTabId.rawValue.uuidString)])
        )

        let reply = try requireIpcReply(commands)
        #expect(reply["tab"]?["id"]?.asString == closedTabId.rawValue.uuidString)
        #expect(tabById(closedTabId, in: model) == nil)
        #expect(totalTabCount(model) == countBefore - 1)
    }

    @Test("tab.close derives tab from pane context")
    func tabCloseDerivesTabFromPaneContext() {
        // Intent: tab.close without an explicit tab closes the tab that
        //   currently owns the IPC context pane.
        // Why it exists: pins the same live pane-to-tab targeting rule as
        //   tab.rename.
        // Scenario: spec-first implicit close from a DanTerm pane context.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .splitPane(direction: .horizontal))
        createTab(&model)
        let targetTabId = selectedTab(in: model)!.id
        _ = update(&model, .movePaneToTab(paneId: paneId, targetTabId: targetTabId))

        _ = sendIpc(
            &model,
            method: Methods.tabClose,
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
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
            method: Methods.tabClose,
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
            method: Methods.tabClose,
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
            method: Methods.tabClose,
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
                method: Methods.tabClose,
                params: .object(["tab": tabValue]),
                context: IpcRequestContext(paneId: contextPaneId.rawValue.uuidString)
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

        let commands = sendIpc(&model, method: Methods.tabClose, context: IpcRequestContext())

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(tabById(tabId, in: model) != nil)
    }

    @Test("pane.split targets context pane even when another tab is selected")
    func paneSplitTargetsContextPaneEvenWhenAnotherTabSelected() throws {
        // Intent: pane.split using the pane context targets that pane
        //   even when a different tab is selected.
        // Why it exists: pins the context-pane override.
        // Scenario: spec-first context-pane split.
        var model = makeModel()
        createTab(&model)
        let backgroundTabId = selectedTab(in: model)!.id
        let backgroundPaneId = selectedTab(in: model)!.focusedPaneId
        createTab(&model)
        let foregroundTabId = selectedTab(in: model)!.id
        let beforePaneIds = Set(model.allPaneIds)

        let commands = sendIpc(
            &model,
            method: Methods.paneSplit,
            params: .object(["direction": .string("horizontal")]),
            context: IpcRequestContext(paneId: backgroundPaneId.rawValue.uuidString)
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
            method: Methods.paneSplit,
            params: .object([
                "pane": .string(siblingPaneId.rawValue.uuidString),
                "direction": .string("vertical"),
            ]),
            context: IpcRequestContext(paneId: callerPaneId.rawValue.uuidString)
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
            method: Methods.paneSplit,
            params: .object([
                "pane": .string("not-a-uuid"),
                "direction": .string("horizontal"),
            ]),
            context: IpcRequestContext(paneId: callerPaneId.rawValue.uuidString)
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
            method: Methods.paneSplit,
            params: .object([
                "pane": .number(42),
                "direction": .string("horizontal"),
            ]),
            context: IpcRequestContext(paneId: callerPaneId.rawValue.uuidString)
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
            method: Methods.paneSplit,
            params: .object([
                "pane": .string(UUID().uuidString),
                "direction": .string("horizontal"),
            ]),
            context: IpcRequestContext(paneId: callerPaneId.rawValue.uuidString)
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
            method: Methods.paneSplit,
            params: .object(["direction": .string("horizontal")]),
            context: IpcRequestContext()
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
            method: Methods.paneSplit,
            params: .object(["direction": .string("horizontal")]),
            context: IpcRequestContext(paneId: unknownPaneId.rawValue.uuidString)
        )

        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(Set(model.allPaneIds) == beforePaneIds)
    }

    @Test("pane.focus selects target tab and requests first responder")
    func paneFocusSelectsTabAndRequestsFirstResponder() throws {
        // Intent: pane.focus selects the target's tab and emits
        //   makeFirstResponder for the pane.
        // Why it exists: pins the focus-cross-tab path.
        // Scenario: spec-first cross-tab focus.
        var model = makeModel()
        createTab(&model)
        let targetTabId = selectedTab(in: model)!.id
        let targetPaneId = selectedTab(in: model)!.focusedPaneId
        createTab(&model)

        let commands = sendIpc(
            &model,
            method: Methods.paneFocus,
            params: .object(["pane": .string(targetPaneId.rawValue.uuidString)])
        )

        #expect(model.selectedTabId == targetTabId)
        let reply = try requireIpcReply(commands)
        #expect(reply["tab"]?["id"]?.asString == targetTabId.rawValue.uuidString)
        #expect(reply["tab"]?["focusedPaneId"]?.asString == targetPaneId.rawValue.uuidString)
        #expect(hasEffect(commands) {
            if case .makeFirstResponder(let paneId) = $0 { return paneId == targetPaneId }
            return false
        }, "expected focus command")
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
            method: Methods.paneFocus,
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
            method: Methods.paneFocus,
            params: .object(["pane": .string(secondPaneId.rawValue.uuidString)]),
            context: contextForSelectedPane(in: model)
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
            method: Methods.paneFocus,
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
        let context = contextForSelectedPane(in: model)

        let commands = sendIpc(&model, method: Methods.paneFocus, context: context)

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
                method: Methods.paneFocus,
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
                method: Methods.paneFocus,
                params: .object(["pane": .string(rawPane)])
            )

            let error = try requireIpcError(commands)
            #expect(error.code == -32602)
            #expect(error.message == "pane not found")
        }
    }

    @Test("pane.focus accepts legacy paneId alias")
    func paneFocusAcceptsLegacyPaneIdAlias() throws {
        // Intent: raw IPC clients that still send paneId can focus a
        //   pane when the forward pane field is absent.
        // Why it exists: paneId is a deprecated wire alias, not a CLI-
        //   emitted field; direct IPC clients may still rely on it.
        // Scenario: back-compat direct IPC request with paneId only.
        var model = makeModel()
        createTab(&model)
        let targetTabId = selectedTab(in: model)!.id
        let targetPaneId = selectedTab(in: model)!.focusedPaneId
        createTab(&model)

        let commands = sendIpc(
            &model,
            method: Methods.paneFocus,
            params: .object(["paneId": .string(targetPaneId.rawValue.uuidString)])
        )

        let reply = try requireIpcReply(commands)
        #expect(model.selectedTabId == targetTabId)
        #expect(reply["tab"]?["focusedPaneId"]?.asString == targetPaneId.rawValue.uuidString)
    }

    @Test("pane.focus pane field wins over legacy paneId alias")
    func paneFocusPaneFieldWinsOverLegacyPaneIdAlias() throws {
        // Intent: the forward pane field is authoritative when both it
        //   and the deprecated paneId alias are present.
        // Why it exists: prevents legacy-alias normalization from
        //   overwriting the explicit forward target.
        // Scenario: direct IPC request sends both pane and paneId.
        var model = makeModel()
        createTab(&model)
        let firstTabId = selectedTab(in: model)!.id
        let firstPaneId = selectedTab(in: model)!.focusedPaneId
        createTab(&model)
        let secondPaneId = selectedTab(in: model)!.focusedPaneId

        let commands = sendIpc(
            &model,
            method: Methods.paneFocus,
            params: .object([
                "pane": .string(firstPaneId.rawValue.uuidString),
                "paneId": .string(secondPaneId.rawValue.uuidString),
            ])
        )

        let reply = try requireIpcReply(commands)
        #expect(model.selectedTabId == firstTabId)
        #expect(reply["tab"]?["focusedPaneId"]?.asString == firstPaneId.rawValue.uuidString)
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
            method: Methods.tabNew,
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
        let tabId = TabId(rawValue: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!)
        var model = AppModel(groups: [GroupModel(id: groupId, name: "Builds")])
        let env = makeTestEnv(idSequence: [paneId.rawValue, tabId.rawValue])

        let result = try requireIpcReply(sendIpc(
            &model,
            method: Methods.tabNew,
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

    @Test("tab.new explicit group id wins over pane context group")
    func tabNewExplicitGroupWinsOverPaneContextGroup() throws {
        // Intent: an explicit group id wins over the implicit pane-
        //   context group.
        // Why it exists: pins explicit-wins.
        // Scenario: spec-first explicit vs context group.
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
            method: Methods.tabNew,
            params: .object(["group": .string(explicitGroupId.rawValue.uuidString)]),
            context: IpcRequestContext(paneId: callerPaneId.rawValue.uuidString)
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
                method: Methods.tabNew,
                params: .object(["group": groupValue]),
                context: IpcRequestContext(paneId: contextPaneId.rawValue.uuidString)
            )

            let error = try requireIpcError(commands)
            #expect(error.code == -32602)
            #expect(model.groups.count == groupsBefore)
            #expect(model.groups.flatMap(\.tabs).count == tabsBefore)
        }
    }

    @Test("tab.new without explicit group uses pane context group")
    func tabNewWithoutExplicitGroupUsesContextGroup() throws {
        // Intent: without an explicit group, tab.new uses the pane
        //   context's group.
        // Why it exists: pins the implicit-group derivation.
        // Scenario: spec-first implicit group.
        var model = makeModel()
        createTab(&model)
        let callerGroupId = model.groups[0].id
        let callerPaneId = selectedTab(in: model)!.focusedPaneId
        _ = update(&model, .createGroup(name: "Other"))

        let commands = sendIpc(
            &model,
            method: Methods.tabNew,
            params: .object([:]),
            context: IpcRequestContext(paneId: callerPaneId.rawValue.uuidString)
        )

        #expect(model.groups.first(where: { $0.id == callerGroupId })?.tabs.count == 2)
        #expect(try requireIpcReply(commands)["group"]?["id"]?.asString == callerGroupId.rawValue.uuidString)
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
        let commands = sendIpc(&model, method: Methods.tabNew, params: .object([:]), context: IpcRequestContext())
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
                method: Methods.tabRename,
                explicitParams: { .object(["tab": $0, "title": .string("build")]) },
                absentParams: .object(["title": .string("build")])
            ),
            TargetCase(
                entity: "group",
                method: Methods.tabNew,
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
                context: contextForSelectedPane(in: nonStringModel)
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
                context: contextForSelectedPane(in: unknownModel)
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
                context: IpcRequestContext()
            )
            let absentError = try requireIpcError(absentCommands)
            #expect(absentError.code == -32602)
            #expect(absentError.message == "no \(targetCase.entity) in context")
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
            method: Methods.tabNew,
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
            method: Methods.tabNew,
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

    @Test("tab.new inherits cwd from caller pane, not selected tab")
    func tabNewInheritsCwdFromCallerPane() throws {
        // Intent: tab.new inherits cwd from the caller pane (per
        //   IPC context), not from the selected tab's pane.
        // Why it exists: pins the caller-pane scope of cwd.
        // Scenario: spec-first cwd inherit (both foreground +
        //   background).
        for background in [true, false] {
            var model = makeModel()
            createTab(&model)
            let selectedTabId = selectedTab(in: model)!.id
            let selectedPaneId = selectedTab(in: model)!.focusedPaneId
            model.updatePane(selectedPaneId) { $0.cwd = "/selected" }
            createTab(&model)
            let callerPaneId = selectedTab(in: model)!.focusedPaneId
            model.updatePane(callerPaneId) { $0.cwd = "/caller" }
            _ = update(&model, .selectTab(id: selectedTabId))

            let commands = sendIpc(
                &model,
                method: Methods.tabNew,
                params: .object(["background": .bool(background)]),
                context: IpcRequestContext(paneId: callerPaneId.rawValue.uuidString)
            )

            let reply = try requireIpcReply(commands)
            let paneId = try requirePaneId(reply["panes"]?.asArray?.first?["id"], "tab.new should return pane id")
            #expect(hasEffect(commands) {
                if case .createSession(let effectPaneId, let cwd, _, _, _) = $0 {
                    return effectPaneId == paneId && cwd == "/caller"
                }
                return false
            }, "tab.new should inherit cwd from caller pane")
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
        let commands = sendIpc(
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

        let reply = try requireIpcReply(commands)
        let tabId = try requireTabId(reply["tab"]?["id"], "tab.new should return tab id")
        let paneId = try requirePaneId(reply["panes"]?.asArray?.first?["id"], "tab.new should return pane id")
        #expect(reply["tab"]?["focusedPaneId"]?.asString == paneId.rawValue.uuidString)
        #expect(reply["tab"]?["rootNode"]?["pane"]?["id"]?.asString == paneId.rawValue.uuidString)
        #expect(reply["panes"]?.asArray?.first?.asObject?.keys.count == 1)
        #expect(tabById(tabId, in: model)?.customTitle == "clock")
        #expect(tabById(tabId, in: model)?.displayTitle == "clock")
        #expect(model.pane(paneId)?.title == "clock")
        #expect(hasEffect(commands) {
            if case .createSession(let effectPaneId, let cwd, let command, let launchCommand, let waitAfterCommand) = $0 {
                return effectPaneId == paneId
                    && cwd == "/tmp"
                    && command == "date"
                    && launchCommand == nil
                    && waitAfterCommand
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
            method: Methods.tabNew,
            params: .object([
                "group": .string(groupId.rawValue.uuidString),
                "launch": .object(["cmd": .string("make test")]),
            ])
        )

        let group = model.groups.first(where: { $0.id == groupId })
        let paneId = group?.tabs.last?.focusedPaneId
        #expect(paneId != nil, "target group should have a new tab")
        #expect(hasEffect(commands) {
            if case .createSession(let effectPaneId, _, let command, let launchCommand, _) = $0 {
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
            method: Methods.tabNew,
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

    @Test("tab.new afterTab with matching group succeeds")
    func tabNewAfterTabWithMatchingGroupSucceeds() throws {
        // Intent: afterTab with a group id that matches the reference
        //   tab's group succeeds.
        // Why it exists: pins the matching-group OK branch.
        // Scenario: spec-first afterTab matching group.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let refTabId = model.groups[0].tabs[0].id
        let targetGroupId = model.groups[0].id
        let beforeGroupTabs = groupTabIds(in: model)
        let panesBefore = Set(model.allPaneIds)

        let commands = sendIpc(
            &model,
            method: Methods.tabNew,
            params: .object([
                "group": .string(targetGroupId.rawValue.uuidString),
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
            method: Methods.tabNew,
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

            let commands = sendIpc(&model, method: Methods.tabNew, params: .object(params))

            let error = try requireIpcError(commands)
            #expect(error.code == -32602)
            #expect(model == before)
        }
    }

    @Test("pane.split with launch title sets pane title without tab custom title")
    func paneSplitWithLaunchTitleSetsPaneTitleNoTabCustom() throws {
        // Intent: pane.split with a launch.title sets the new pane's
        //   title; tab.customTitle stays nil.
        // Why it exists: pins the per-pane title scope of launch.title.
        // Scenario: spec-first split launch title.
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let paneId = selectedTab(in: model)!.focusedPaneId

        let commands = sendIpc(
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

        let newPaneId = try requirePaneId(try requireIpcReply(commands)["pane"]?["id"], "pane.split should return pane id")
        #expect(model.pane(newPaneId)?.title == "cargo")
        #expect(tabById(tabId, in: model)?.customTitle == nil)
        #expect(hasEffect(commands) {
            if case .createSession(let effectPaneId, let cwd, let command, let launchCommand, _) = $0 {
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
            method: Methods.paneSplit,
            params: .object([
                "direction": .string("horizontal"),
                "background": .bool(true),
            ]),
            context: IpcRequestContext(paneId: focusedPaneId.rawValue.uuidString)
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
            method: Methods.paneSplit,
            params: .object([
                "direction": .string("horizontal"),
                "background": .bool(true),
            ]),
            context: IpcRequestContext(paneId: backgroundPaneId.rawValue.uuidString)
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
            method: Methods.paneSplit,
            params: .object([
                "direction": .string("horizontal"),
                "background": .string("true"),
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
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
                method: Methods.tabNew,
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
                method: Methods.paneSplit,
                params: .object([
                    "direction": .string("horizontal"),
                    "launch": launchValue,
                ]),
                context: IpcRequestContext(paneId: contextPaneId.rawValue.uuidString)
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
        let ctx = IpcRequestContext(paneId: paneId.rawValue.uuidString)

        let setEffects = sendIpc(&model, method: Methods.themeSet, params: .object(["themeName": .string("Tokyo Night")]), context: ctx)
        #expect(model.pane(paneId)?.theme == "Tokyo Night")
        #expect(try requireIpcReply(setEffects)["pane"]?["theme"]?.asString == "Tokyo Night")

        let clearEffects = sendIpc(&model, method: Methods.themeSet, params: .object(["themeName": .null]), context: ctx)
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
            method: Methods.themeSet,
            params: .object([
                "pane": .string(targetPaneId.rawValue.uuidString),
                "themeName": .string("Tokyo Night"),
            ]),
            context: IpcRequestContext(paneId: contextPaneId.rawValue.uuidString)
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
                method: Methods.themeSet,
                params: .object([
                    "pane": paneValue,
                    "themeName": .string("Tokyo Night"),
                ]),
                context: IpcRequestContext(paneId: contextPaneId.rawValue.uuidString)
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
            method: Methods.themeSet,
            params: .object(["themeName": .string("Tokyo Night")]),
            context: IpcRequestContext()
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
        let ctx = IpcRequestContext(paneId: paneId.rawValue.uuidString)

        let addEffects = sendIpc(
            &model,
            method: Methods.todoAdd,
            params: .object(["text": .string(" ship cli ")]),
            context: ctx
        )
        let added = try requireIpcReply(addEffects)
        let todoId = try requireString(added["todo"]?["id"], "todo add should return id")
        #expect(model.pane(paneId)?.todos.first?.text == "ship cli")

        let editReply = try requireIpcReply(sendIpc(&model, method: Methods.todoEdit, params: .object(["todoId": .string(todoId), "text": .string("ship cli v2")]), context: ctx))
        #expect(model.pane(paneId)?.todos.first?.text == "ship cli v2")
        #expect(editReply["todo"]?["text"]?.asString == "ship cli v2")

        let doneReply = try requireIpcReply(sendIpc(&model, method: Methods.todoDone, params: .object(["todoId": .string(todoId)]), context: ctx))
        #expect(model.pane(paneId)?.todos.first?.isDone == true)
        #expect(doneReply["todo"]?["isDone"]?.asBool == true)

        let openReply = try requireIpcReply(sendIpc(&model, method: Methods.todoOpen, params: .object(["todoId": .string(todoId)]), context: ctx))
        #expect(model.pane(paneId)?.todos.first?.isDone == false)
        #expect(openReply["todo"]?["isDone"]?.asBool == false)

        let list = try requireIpcReply(sendIpc(&model, method: Methods.todoList, context: ctx))
        #expect(list["todos"]?.asArray?.count == 1)

        _ = sendIpc(&model, method: Methods.todoDelete, params: .object(["todoId": .string(todoId)]), context: ctx)
        #expect(model.pane(paneId)?.todos.count == 0)

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
        #expect(model.pane(paneId)?.todos.count == 0)
    }

    @Test("todo commands with explicit pane target that pane regardless of context")
    func todoCommandsWithExplicitPaneTargetThatPaneRegardless() throws {
        // Intent: explicit pane param wins over the context pane on
        //   every todo command.
        // Why it exists: pins the explicit-wins rule for todos.
        // Scenario: spec-first explicit pane lifecycle.
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
        #expect(model.pane(targetPaneId)?.todos.first?.text == "ship cli")
        #expect(model.pane(contextPaneId)?.todos.count == 0)

        let listReply = try requireIpcReply(sendIpc(
            &model,
            method: Methods.todoList,
            params: .object(["pane": .string(targetPaneId.rawValue.uuidString)]),
            context: ctx
        ))
        #expect(listReply["todos"]?.asArray?.count == 1)

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
        #expect(model.pane(targetPaneId)?.todos.first?.text == "ship cli v2")

        _ = sendIpc(
            &model,
            method: Methods.todoDone,
            params: .object([
                "pane": .string(targetPaneId.rawValue.uuidString),
                "todoId": .string(todoId),
            ]),
            context: ctx
        )
        #expect(model.pane(targetPaneId)?.todos.first?.isDone == true)

        _ = sendIpc(
            &model,
            method: Methods.todoOpen,
            params: .object([
                "pane": .string(targetPaneId.rawValue.uuidString),
                "todoId": .string(todoId),
            ]),
            context: ctx
        )
        #expect(model.pane(targetPaneId)?.todos.first?.isDone == false)

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
        #expect(model.pane(targetPaneId)?.todos.count == 0)

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
        #expect(model.pane(targetPaneId)?.todos.count == 0)
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
                    model.updatePane(contextPaneId) { $0.todos[0].isDone = true }
                }

                var params = baseParams
                params["pane"] = paneValue
                if params["todoId"] != nil {
                    params["todoId"] = .string(item.id.uuidString)
                }

                let sent = sendIpc(
                    &model,
                    method: method,
                    params: .object(params),
                    context: IpcRequestContext(paneId: contextPaneId.rawValue.uuidString)
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

            let sent = sendIpc(
                &model,
                method: method,
                params: .object(params),
                context: IpcRequestContext()
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
            method: Methods.todoDelete,
            params: .object(["todoId": .string(UUID().uuidString)]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
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
            method: Methods.paneInput,
            params: .object(["text": .string("echo hi")]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
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
            method: Methods.paneInput,
            params: .object([
                "input": .array([
                    .object(["text": .string("ls")]),
                    .object(["key": .string("Enter")]),
                ])
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
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
            method: Methods.paneInput,
            params: .object([
                "text": .string("hi"),
                "input": .array([.object(["text": .string("hi")])]),
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
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
            method: Methods.paneInput,
            params: .object([:]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
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
            method: Methods.paneInput,
            params: .object([
                "input": .array([.object([:])])
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
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
            method: Methods.paneInput,
            params: .object([
                "input": .array([
                    .object(["key": .string("Bogus")])
                ])
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
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
            method: Methods.paneInput,
            params: .object([
                "input": .array([
                    .object(["key": .number(5)])
                ])
            ]),
            context: IpcRequestContext(paneId: paneId.rawValue.uuidString)
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
            method: Methods.paneInput,
            params: .object([
                "pane": .string(backgroundPaneId.rawValue.uuidString),
                "input": .array([.object(["text": .string("hi")])]),
            ]),
            context: IpcRequestContext(paneId: foregroundPaneId.rawValue.uuidString)
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
            method: Methods.paneInput,
            params: .object([
                "pane": .string(UUID().uuidString),
                "input": .array([.object(["text": .string("hi")])]),
            ]),
            context: IpcRequestContext(paneId: realPaneId.rawValue.uuidString)
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
            method: Methods.paneInput,
            params: .object([
                "pane": .number(5),
                "input": .array([.object(["text": .string("hi")])]),
            ]),
            context: IpcRequestContext(paneId: realPaneId.rawValue.uuidString)
        )
        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(error.message.contains("pane must be a string"),
            "expected 'pane must be a string', got: \(error.message)")
    }

    @Test("pane.input with no pane in context and no explicit pane errors")
    func paneInputNoPaneInContextOrExplicitErrors() throws {
        // Intent: no pane context and no explicit pane returns -32602
        //   with a "no pane in context" message.
        // Why it exists: pins the no-pane error message.
        // Scenario: spec-first no pane.
        var model = makeModel()
        createTab(&model)
        let commands = sendIpc(
            &model,
            method: Methods.paneInput,
            params: .object(["input": .array([.object(["text": .string("hi")])])]),
            context: IpcRequestContext()
        )
        let error = try requireIpcError(commands)
        #expect(error.code == -32602)
        #expect(error.message.contains("no pane in context"),
            "expected 'no pane in context', got: \(error.message)")
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
            method: Methods.paneRead,
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
            method: Methods.paneRead,
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
        let commands = sendIpc(&model, method: Methods.paneRead, params: .object([:]))
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
                method: Methods.paneRead,
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
                method: Methods.paneRead,
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
                method: Methods.paneRead,
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
            method: Methods.paneTape,
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
            method: Methods.paneTape,
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
            method: Methods.paneTape,
            params: .object([:]),
            context: IpcRequestContext()
        )
        #expect(try requireIpcError(missing) == .init(code: -32602, message: "pane required"))

        var unknownModel = makeModel()
        createTab(&unknownModel)
        let unknown = sendIpc(
            &unknownModel,
            method: Methods.paneTape,
            params: .object(["pane": .string(UUID().uuidString)])
        )
        #expect(try requireIpcError(unknown) == .init(code: -32602, message: "pane not found"))

        var invalidModel = makeModel()
        createTab(&invalidModel)
        let paneId = selectedTab(in: invalidModel)!.focusedPaneId
        let invalid = sendIpc(
            &invalidModel,
            method: Methods.paneTape,
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
    context: IpcRequestContext = IpcRequestContext(),
    livePaneState: LivePaneStateView = LivePaneStateView(),
    env: CoreEnv = .live
) -> [Command] {
    update(
        &model,
        .ipcRequest(reqId: UUID(), method: method, params: params, context: context),
        livePaneState: livePaneState,
        env: env
    )
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
        _ = update(&model, .splitPane(direction: .horizontal))
        let paneId = selectedTab(in: model)!.focusedPaneId
        let params = JSONValue.object([
            "pane": .string(paneId.rawValue.uuidString),
            "state": .string("on"),
        ])

        for _ in 0..<2 {
            let reply = try requireIpcReply(sendIpc(&model, method: Methods.paneZoom, params: params))
            #expect(reply["tab"]?["isZoomed"]?.asBool == true)
            #expect(selectedTab(in: model)!.isZoomed)
        }

        let off = JSONValue.object([
            "pane": .string(paneId.rawValue.uuidString),
            "state": .string("off"),
        ])
        for _ in 0..<2 {
            let reply = try requireIpcReply(sendIpc(&model, method: Methods.paneZoom, params: off))
            #expect(reply["tab"]?["isZoomed"]?.asBool == false)
            #expect(selectedTab(in: model)!.isZoomed == false)
        }
    }

    @Test("pane.zoom toggle flips the tab and reports the resulting state")
    func paneZoomToggleFlips() throws {
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .splitPane(direction: .horizontal))
        let paneId = selectedTab(in: model)!.focusedPaneId
        let params = JSONValue.object([
            "pane": .string(paneId.rawValue.uuidString),
            "state": .string("toggle"),
        ])

        #expect(try requireIpcReply(sendIpc(&model, method: Methods.paneZoom, params: params))["tab"]?["isZoomed"]?.asBool == true)
        #expect(try requireIpcReply(sendIpc(&model, method: Methods.paneZoom, params: params))["tab"]?["isZoomed"]?.asBool == false)
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
            method: Methods.paneZoom,
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
        _ = update(&model, .splitPane(direction: .horizontal))
        let paneId = selectedTab(in: model)!.focusedPaneId

        let badState = sendIpc(&model, method: Methods.paneZoom, params: .object([
            "pane": .string(paneId.rawValue.uuidString),
            "state": .string("sideways"),
        ]))
        #expect(try requireIpcError(badState).code == -32602)

        let unknownPane = sendIpc(&model, method: Methods.paneZoom, params: .object([
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
        _ = update(&model, .splitPane(direction: .horizontal))
        let paneId = selectedTab(in: model)!.focusedPaneId
        let context = IpcRequestContext(paneId: paneId.rawValue.uuidString)

        let before = try requireIpcReply(sendIpc(&model, method: Methods.paneInfo, context: context))
        #expect(before["tab"]?["isZoomed"]?.asBool == false)

        _ = update(&model, .toggleZoomPane(paneId: paneId))

        let after = try requireIpcReply(sendIpc(&model, method: Methods.paneInfo, context: context))
        #expect(after["tab"]?["isZoomed"]?.asBool == true)
    }
}
