// The display boundary as a whole: nothing multi-line reaches a view, and
// nothing that is not display text gets rewritten on its way to IPC, a
// checkpoint, or the model.
//
// The sweep here is the test that catches a render-ready field added as a bare
// `String`. It drives hostile text through real `.sessionReport` messages --
// the same path a program takes when it emits OSC 0/2 -- and then reads every
// surface the plan types.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

/// Text a program can put in a title with one escape sequence.
private let hostileInputs = [
    "a\nb",
    "a\r\nb",
    "\u{001B}]0;half a sequence",
    "left \u{202E}right",
    "  spread \t out \n across lines  ",
    "\n\n\n",
]

/// A string is flat when a fixed-height label can draw it: one line, and no
/// control scalar that a text system would have to interpret.
private func isFlat(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy {
        $0.properties.generalCategory != .control && $0 != "\u{202E}"
    }
}

private func expectFlat(_ line: DisplayLine, _ surface: String, input: String) {
    #expect(isFlat(line.text), "\(surface) was not flat for \(String(reflecting: input)): \(String(reflecting: line.text))")
}

private func expectFlat(_ line: DisplayLine?, _ surface: String, input: String) {
    guard let line else { return }
    expectFlat(line, surface, input: input)
}

/// A tab with two panes, so the pane strip, the tab-todo pane sections, and the
/// close-tab confirmation all have something to say.
private func makeHostileModel(_ hostile: String, runningCommand: Bool) throws -> (model: AppModel, tabId: TabId, panes: [PaneId]) {
    var model = makeModel()
    model.isAppActive = false
    createTab(&model)
    let firstPaneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
    update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
    let tab = try #require(selectedTab(in: model))
    let panes = allPaneIds(tab.paneTree.root)

    for paneId in panes {
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        update(&model, .sessionReport(sessionId: sessionId, report: .title(hostile)))
        update(&model, .sessionReport(sessionId: sessionId, report: .cwd("/tmp/\(hostile)")))
        if runningCommand, paneId == panes[0] {
            update(&model, .sessionReport(sessionId: sessionId, report: .commandStarted(hostile)))
        }
    }

    // A remote identity's user and host arrive base64-encoded from the shell
    // integration, so they are exactly as untrusted as a title. The decode
    // itself lives in TerminalCore; this is the value it produces.
    let firstSessionId = try #require(model.pane(panes[0])?.session?.id)
    update(&model, .sessionReport(sessionId: firstSessionId, report: .connectionDeclared(
        .remote(identity: RemoteSession(user: hostile, host: hostile)))))
    let agent = try #require(AgentSession(kind: "aider", sessionId: "abc123"))
    update(&model, .sessionReport(sessionId: firstSessionId, report: .agentAttached(agent)))

    update(&model, .addTodo(owner: .tab(tab.id), text: "a todo"))

    return (model, tab.id, panes)
}

@Suite struct DisplayBoundarySweepTests {
    @Test("no projection hands a view a multi-line or control-bearing string", arguments: hostileInputs)
    func projectionsAreFlat(hostile: String) throws {
        for runningCommand in [false, true] {
            let (model, tabId, panes) = try makeHostileModel(hostile, runningCommand: runningCommand)

            let chrome = desiredWindowChrome(in: model)
            expectFlat(chrome.windowTitle, "windowChrome.windowTitle", input: hostile)
            expectFlat(chrome.contentTitle, "windowChrome.contentTitle", input: hostile)

            for group in desiredSidebar(in: model).groups {
                expectFlat(group.rendered.name, "sidebar group name", input: hostile)
                for tab in group.tabs {
                    expectFlat(tab.displayTitle, "sidebar tab title", input: hostile)
                }
            }

            for render in desiredPaneToolbar(in: model).values {
                expectFlat(render.label, "pane toolbar label", input: hostile)
                expectFlat(render.remoteLabel, "pane toolbar remote pill", input: hostile)
                expectFlat(render.agentLabel, "pane toolbar agent pill", input: hostile)
                expectFlat(render.chipTooltip, "pane chip tooltip", input: hostile)
            }

            for row in buildTabTodoRows(model: model, tabId: tabId) {
                if case .paneSectionHeader(_, let title) = row {
                    expectFlat(title, "tab-todo pane section header", input: hostile)
                }
            }

            var switcherModel = model
            update(&switcherModel, .mruCycleStepped(direction: .older))
            for row in desiredSwitcher(in: switcherModel)?.rows ?? [] {
                expectFlat(row.name, "switcher row name", input: hostile)
            }

            var alertModel = model
            alertModel.alertsPopoverOpen = true
            let notifiedSessionId = try #require(alertModel.pane(panes[1])?.session?.id)
            let commands = update(&alertModel, .sessionNotification(
                sessionId: notifiedSessionId, title: hostile, body: hostile))
            for command in commands {
                if case .sendNotification(_, _, let title, let subtitle, _) = command {
                    expectFlat(title, "sendNotification title", input: hostile)
                    expectFlat(subtitle, "sendNotification subtitle", input: hostile)
                }
            }
            for row in desiredAlertsPopover(in: alertModel, now: Date())!.rows {
                expectFlat(row.title, "alerts popover row title", input: hostile)
            }

            var closeModel = model
            _ = update(&closeModel, .requestCloseTab(id: tabId))
            if let projection = desiredConfirmation(in: closeModel) {
                expectFlat(projection.title, "close-tab confirmation title", input: hostile)
                for command in projection.commands {
                    expectFlat(command, "close confirmation command", input: hostile)
                }
            }

            var quitModel = model
            _ = update(&quitModel, .requestQuit)
            if let projection = desiredConfirmation(in: quitModel) {
                for command in projection.commands {
                    expectFlat(command, "quit confirmation command", input: hostile)
                }
            }
        }
    }
}

@Suite struct DisplayBoundaryRawStateTests {
    // Why it exists: flattening in the reducer would fix the visible symptom
    // and quietly corrupt the values IPC targets panes by. This fails loudly if
    // someone moves normalization there.
    @Test("the model keeps terminal-reported text byte for byte")
    func modelKeepsRawText() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)

        update(&model, .sessionReport(sessionId: sessionId, report: .title("a\nb")))
        update(&model, .sessionReport(sessionId: sessionId, report: .cwd("/tmp/a\nb")))
        update(&model, .sessionReport(sessionId: sessionId, report: .commandStarted("make\nall")))

        let session = try #require(model.pane(paneId)?.session)
        #expect(session.title == "a\nb")
        #expect(session.cwd == "/tmp/a\nb")
        #expect(session.command == .running("make\nall"))
    }

    @Test("pane.info reports the raw title while the sidebar shows a flat one")
    func paneInfoKeepsRawTitle() throws {
        var model = makeModel()
        createTab(&model)
        let tab = try #require(selectedTab(in: model))
        let paneId = tab.paneTree.focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        update(&model, .sessionReport(sessionId: sessionId, report: .title("a\nb")))

        let reply = try requireReply(sendRequest(
            &model,
            method: IpcRequestMethod.paneInfo.rawValue,
            params: .object(["pane": .string(paneId.rawValue.uuidString)])))

        #expect(reply["pane"]?["title"]?.asString == "a\nb")
        #expect(reply["tab"]?["title"]?.asString == "a\nb")
        #expect(desiredSidebar(in: model).groups[0].tabs[0].displayTitle.text == "a b")
    }

    @Test("ls reports the raw pane title")
    func lsKeepsRawTitle() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        update(&model, .sessionReport(sessionId: sessionId, report: .title("a\nb")))

        let reply = try requireReply(sendRequest(&model, method: IpcRequestMethod.ls.rawValue))
        let titles = collectStrings(reply, key: "title")

        #expect(titles.contains("a\nb"))
    }

    @Test("a checkpoint round-trip keeps the raw title and still projects a flat one")
    func checkpointKeepsRawTitle() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        update(&model, .sessionReport(sessionId: sessionId, report: .title("a\nb")))

        let rebuilt = try #require(validateAndBuild(toSnapshot(model)))
        let restoredPane = try #require(paneInNode(rebuilt.groups[0].tabs[0].paneTree.root, id: paneId))

        #expect(restoredPane.session?.recoveredLabel == "a\nb")
        #expect(desiredSidebar(in: rebuilt).groups[0].tabs[0].displayTitle.text == "a b")
    }

    // I1's exception: the sender's body may legitimately wrap, and
    // AlertPresentation.swift already promises never to rewrite it.
    @Test("the notification body is byte-identical to the sender's")
    func notificationBodyStaysRaw() throws {
        var model = makeModel()
        model.isAppActive = false
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)

        let commands = update(&model, .sessionNotification(
            sessionId: sessionId, title: "build", body: "line one\nline two"))

        let bodies = commands.compactMap { command -> String? in
            if case .sendNotification(_, _, _, _, let body) = command { return body }
            return nil
        }
        #expect(bodies == ["line one\nline two"])
    }
}

@Suite struct DisplaySurfaceTests {
    @Test("a hostile title and working directory reach the window title flat")
    func windowTitleIsFlat() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        update(&model, .sessionReport(sessionId: sessionId, report: .title("a\nb")))
        update(&model, .sessionReport(sessionId: sessionId, report: .cwd("/tmp\nx")))

        #expect(desiredWindowChrome(in: model).windowTitle.text == "a b — /tmp x")
    }

    @Test("a hostile title reaches the close-tab confirmation flat")
    func closeConfirmationIsFlat() throws {
        var model = makeModel()
        createTab(&model)
        let firstPaneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        let tabId = try #require(selectedTab(in: model)).id
        update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        // The tab's display title comes from the focused pane, which the split moved.
        let focusedPaneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        let focusedSessionId = try #require(model.pane(focusedPaneId)?.session?.id)
        update(&model, .sessionReport(sessionId: focusedSessionId, report: .title("a\nb")))

        _ = update(&model, .requestCloseTab(id: tabId))
        #expect(desiredConfirmation(in: model)?.title == "Close tab \"a b\"?")
    }

    @Test("a hostile title reaches the alert presentation flat")
    func alertPresentationIsFlat() throws {
        var model = makeModel()
        model.isAppActive = false
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        update(&model, .sessionReport(sessionId: sessionId, report: .title("pane\ntitle")))

        update(&model, .sessionNotification(
            sessionId: sessionId, title: "sender\ntitle", body: "body"))
        model.alertsPopoverOpen = true

        #expect(model.alerts.first?.title.text == "sender title")
        #expect(desiredAlertsPopover(in: model, now: Date())!.rows.first?.title.text == "sender title")
    }
}

// MARK: - Local IPC helpers

private func sendRequest(
    _ model: inout AppModel,
    method: String,
    params: JSONValue = .object([:])
) -> [Command] {
    do {
        return update(&model, .ipcRequest(
            reqId: UUID(),
            caller: .local,
            request: try IpcRequest.decode(method: method, params: params)))
    } catch {
        Issue.record("could not decode \(method): \(error)")
        return []
    }
}

private func requireReply(_ commands: [Command]) throws -> JSONValue {
    let reply = commands.compactMap { command -> JSONValue? in
        if case .ipcReply(_, let result) = command { return result }
        return nil
    }.first
    return try #require(reply, "expected ipcReply")
}

/// Every string stored under `key` anywhere in a reply, so a test does not have
/// to spell out the shape of a nested listing.
private func collectStrings(_ value: JSONValue, key: String) -> [String] {
    switch value {
    case .object(let fields):
        return fields.flatMap { name, child -> [String] in
            if name == key, let text = child.asString { return [text] }
            return collectStrings(child, key: key)
        }
    case .array(let items):
        return items.flatMap { collectStrings($0, key: key) }
    default:
        return []
    }
}
