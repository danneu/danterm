// Tests DanTerm export helpers and title-channel event translation.
import Foundation

func exportTests() {
    print("Export Tests...")

    // MARK: - parseDantermEvent

    test("parseDantermEvent: valid CMD_START") {
        let cmd = "vim"
        let b64 = Data(cmd.utf8).base64EncodedString()
        let raw = "__DANTERM_EVT__:tok123:CMD_START:\(b64)"
        let result = parseDantermEvent(raw, expectedToken: "tok123")
        try expectEqual(result, .commandStarted(command: "vim"))
    }

    test("parseDantermEvent: valid CMD_END") {
        let raw = "__DANTERM_EVT__:tok123:CMD_END"
        let result = parseDantermEvent(raw, expectedToken: "tok123")
        try expectEqual(result, .commandEnded)
    }

    test("parseDantermEvent: wrong token rejected") {
        let cmd = "vim"
        let b64 = Data(cmd.utf8).base64EncodedString()
        let raw = "__DANTERM_EVT__:wrong:CMD_START:\(b64)"
        let result = parseDantermEvent(raw, expectedToken: "tok123")
        try expect(result == nil, "wrong token should be rejected")
    }

    test("parseDantermEvent: missing token segment rejected") {
        let raw = "__DANTERM_EVT__:"
        let result = parseDantermEvent(raw, expectedToken: "tok123")
        try expect(result == nil, "missing token should be rejected")
    }

    test("parseDantermEvent: malformed base64 rejected") {
        let raw = "__DANTERM_EVT__:tok123:CMD_START:!!!invalid!!!"
        let result = parseDantermEvent(raw, expectedToken: "tok123")
        try expect(result == nil, "malformed base64 should be rejected")
    }

    test("parseDantermEvent: empty command after decode rejected") {
        let b64 = Data("".utf8).base64EncodedString()
        let raw = "__DANTERM_EVT__:tok123:CMD_START:\(b64)"
        let result = parseDantermEvent(raw, expectedToken: "tok123")
        try expect(result == nil, "empty command should be rejected")
    }

    test("parseDantermEvent: no prefix returns nil") {
        let result = parseDantermEvent("just a normal title", expectedToken: "tok123")
        try expect(result == nil, "non-event title should return nil")
    }

    test("parseDantermEvent: valid REMOTE_START") {
        let raw = "__DANTERM_EVT__:tok123:REMOTE_START"
        let result = parseDantermEvent(raw, expectedToken: "tok123")
        try expectEqual(result, .remoteStart)
    }

    test("parseDantermEvent: valid REMOTE_HOST") {
        let userB64 = Data("dan".utf8).base64EncodedString()
        let hostB64 = Data("caja".utf8).base64EncodedString()
        let raw = "__DANTERM_EVT__:tok123:REMOTE_HOST:\(userB64):\(hostB64)"
        let result = parseDantermEvent(raw, expectedToken: "tok123")
        try expectEqual(result, .remoteSession(value: RemoteSession(user: "dan", host: "caja")))
    }

    test("parseDantermEvent: REMOTE_HOST with missing user field rejected") {
        let hostB64 = Data("caja".utf8).base64EncodedString()
        let raw = "__DANTERM_EVT__:tok123:REMOTE_HOST::\(hostB64)"
        let result = parseDantermEvent(raw, expectedToken: "tok123")
        try expect(result == nil, "missing user field should be rejected")
    }

    test("parseDantermEvent: REMOTE_HOST with missing host field rejected") {
        let userB64 = Data("dan".utf8).base64EncodedString()
        let raw = "__DANTERM_EVT__:tok123:REMOTE_HOST:\(userB64):"
        let result = parseDantermEvent(raw, expectedToken: "tok123")
        try expect(result == nil, "missing host field should be rejected")
    }

    test("parseDantermEvent: REMOTE_HOST with no separator rejected") {
        let userB64 = Data("dan".utf8).base64EncodedString()
        let raw = "__DANTERM_EVT__:tok123:REMOTE_HOST:\(userB64)"
        let result = parseDantermEvent(raw, expectedToken: "tok123")
        try expect(result == nil, "missing separator should be rejected")
    }

    test("parseDantermEvent: REMOTE_HOST with invalid base64 user rejected") {
        let hostB64 = Data("caja".utf8).base64EncodedString()
        let raw = "__DANTERM_EVT__:tok123:REMOTE_HOST:!!!invalid!!!:\(hostB64)"
        let result = parseDantermEvent(raw, expectedToken: "tok123")
        try expect(result == nil, "invalid user base64 should be rejected")
    }

    test("parseDantermEvent: REMOTE_HOST with invalid base64 host rejected") {
        let userB64 = Data("dan".utf8).base64EncodedString()
        let raw = "__DANTERM_EVT__:tok123:REMOTE_HOST:\(userB64):!!!invalid!!!"
        let result = parseDantermEvent(raw, expectedToken: "tok123")
        try expect(result == nil, "invalid host base64 should be rejected")
    }

    test("parseDantermEvent: REMOTE_HOST with empty decoded user rejected") {
        let userB64 = Data("".utf8).base64EncodedString()
        let hostB64 = Data("caja".utf8).base64EncodedString()
        let raw = "__DANTERM_EVT__:tok123:REMOTE_HOST:\(userB64):\(hostB64)"
        let result = parseDantermEvent(raw, expectedToken: "tok123")
        try expect(result == nil, "empty decoded user should be rejected")
    }

    test("parseDantermEvent: REMOTE_HOST with empty decoded host rejected") {
        let userB64 = Data("dan".utf8).base64EncodedString()
        let hostB64 = Data("".utf8).base64EncodedString()
        let raw = "__DANTERM_EVT__:tok123:REMOTE_HOST:\(userB64):\(hostB64)"
        let result = parseDantermEvent(raw, expectedToken: "tok123")
        try expect(result == nil, "empty decoded host should be rejected")
    }

    test("parseDantermEvent: REMOTE_HOST wrong token rejected") {
        let userB64 = Data("dan".utf8).base64EncodedString()
        let hostB64 = Data("caja".utf8).base64EncodedString()
        let raw = "__DANTERM_EVT__:wrong-token:REMOTE_HOST:\(userB64):\(hostB64)"
        let result = parseDantermEvent(raw, expectedToken: "tok123")
        try expect(result == nil, "wrong token should be rejected")
    }

    test("parseDantermEvent: unknown event type returns nil") {
        let raw = "__DANTERM_EVT__:tok123:CMD_UNKNOWN"
        let result = parseDantermEvent(raw, expectedToken: "tok123")
        try expect(result == nil, "unknown event type should return nil")
    }

    test("parseDantermEvent: command with special characters") {
        let cmd = "ssh user@host -p 2222"
        let b64 = Data(cmd.utf8).base64EncodedString()
        let raw = "__DANTERM_EVT__:tok123:CMD_START:\(b64)"
        let result = parseDantermEvent(raw, expectedToken: "tok123")
        try expectEqual(result, .commandStarted(command: cmd))
    }

    // MARK: - translateMsg (runtime interception path)

    test("translateMsg: valid CMD_START translates to commandStarted") {
        let paneId = PaneId()
        let token = "my-token"
        let b64 = Data("vim".utf8).base64EncodedString()
        let title = "__DANTERM_EVT__:\(token):CMD_START:\(b64)"
        let result = translateMsg(.surfaceTitle(paneId: paneId, title: title)) { id in
            id == paneId ? token : nil
        }
        guard case .commandStarted(let pid, let cmd) = result else {
            throw TestFailure(message: "expected .commandStarted, got \(String(describing: result))")
        }
        try expectEqual(pid, paneId)
        try expectEqual(cmd, "vim")
    }

    test("translateMsg: CMD_END translates to commandEnded") {
        let paneId = PaneId()
        let token = "my-token"
        let title = "__DANTERM_EVT__:\(token):CMD_END"
        let result = translateMsg(.surfaceTitle(paneId: paneId, title: title)) { id in
            id == paneId ? token : nil
        }
        guard case .commandEnded(let pid) = result else {
            throw TestFailure(message: "expected .commandEnded, got \(String(describing: result))")
        }
        try expectEqual(pid, paneId)
    }

    test("translateMsg: REMOTE_START translates to remoteSessionStarted") {
        let paneId = PaneId()
        let token = "my-token"
        let title = "__DANTERM_EVT__:\(token):REMOTE_START"
        let result = translateMsg(.surfaceTitle(paneId: paneId, title: title)) { id in
            id == paneId ? token : nil
        }
        guard case .remoteSessionStarted(let pid) = result else {
            throw TestFailure(message: "expected .remoteSessionStarted, got \(String(describing: result))")
        }
        try expectEqual(pid, paneId)
    }

    test("translateMsg: REMOTE_HOST translates to remoteSessionReported") {
        let paneId = PaneId()
        let token = "my-token"
        let userB64 = Data("dan".utf8).base64EncodedString()
        let hostB64 = Data("caja".utf8).base64EncodedString()
        let title = "__DANTERM_EVT__:\(token):REMOTE_HOST:\(userB64):\(hostB64)"
        let result = translateMsg(.surfaceTitle(paneId: paneId, title: title)) { id in
            id == paneId ? token : nil
        }
        guard case .remoteSessionReported(let pid, let session) = result else {
            throw TestFailure(message: "expected .remoteSessionReported, got \(String(describing: result))")
        }
        try expectEqual(pid, paneId)
        try expectEqual(session, RemoteSession(user: "dan", host: "caja"))
    }

    test("translateMsg: wrong token drops message") {
        let paneId = PaneId()
        let b64 = Data("vim".utf8).base64EncodedString()
        let title = "__DANTERM_EVT__:wrong-token:CMD_START:\(b64)"
        let result = translateMsg(.surfaceTitle(paneId: paneId, title: title)) { id in
            id == paneId ? "correct-token" : nil
        }
        try expect(result == nil, "wrong token should drop message")
    }

    test("translateMsg: no token for pane drops message") {
        let paneId = PaneId()
        let b64 = Data("vim".utf8).base64EncodedString()
        let title = "__DANTERM_EVT__:any-token:CMD_START:\(b64)"
        let result = translateMsg(.surfaceTitle(paneId: paneId, title: title)) { _ in nil }
        try expect(result == nil, "no token for pane should drop message")
    }

    test("translateMsg: normal title passes through") {
        let paneId = PaneId()
        let msg = Msg.surfaceTitle(paneId: paneId, title: "vim - file.txt")
        let result = translateMsg(msg) { _ in "some-token" }
        guard case .surfaceTitle(let pid, let t) = result else {
            throw TestFailure(message: "expected .surfaceTitle, got \(String(describing: result))")
        }
        try expectEqual(pid, paneId)
        try expectEqual(t, "vim - file.txt")
    }

    test("translateMsg: non-surfaceTitle msg passes through") {
        let paneId = PaneId()
        let msg = Msg.surfaceCwd(paneId: paneId, cwd: "/home")
        let result = translateMsg(msg) { _ in nil }
        guard case .surfaceCwd(let pid, let cwd) = result else {
            throw TestFailure(message: "expected .surfaceCwd, got \(String(describing: result))")
        }
        try expectEqual(pid, paneId)
        try expectEqual(cwd, "/home")
    }

    // MARK: - PaneTokenStore (token lifecycle)

    test("PaneTokenStore: generate creates token") {
        var store = PaneTokenStore()
        let paneId = PaneId()
        let token = store.generate(for: paneId)
        try expect(!token.isEmpty, "token should not be empty")
        try expectEqual(store.token(for: paneId), token)
    }

    test("PaneTokenStore: remove cleans up token") {
        var store = PaneTokenStore()
        let paneId = PaneId()
        _ = store.generate(for: paneId)
        store.remove(paneId)
        try expect(store.token(for: paneId) == nil, "token should be removed")
    }

    test("PaneTokenStore: each pane gets unique token") {
        var store = PaneTokenStore()
        let p1 = PaneId()
        let p2 = PaneId()
        let t1 = store.generate(for: p1)
        let t2 = store.generate(for: p2)
        try expect(t1 != t2, "tokens should be unique")
    }

    test("PaneTokenStore: generate replaces existing token") {
        var store = PaneTokenStore()
        let paneId = PaneId()
        let t1 = store.generate(for: paneId)
        let t2 = store.generate(for: paneId)
        try expect(t1 != t2, "regenerated token should differ")
        try expectEqual(store.token(for: paneId), t2)
    }

    test("PaneTokenStore: unknown pane returns nil") {
        let store = PaneTokenStore()
        try expect(store.token(for: PaneId()) == nil, "unknown pane should return nil")
    }

    // MARK: - restore command behavior

    test("restoreCommandBehavior defaults to prefill") {
        let behavior = restoreCommandBehavior(from: ["DanTerm", "--init", "/tmp/state.json"])
        try expectEqual(behavior, .prefill)
    }

    test("restoreCommandBehavior parses execute flag") {
        let behavior = restoreCommandBehavior(from: ["DanTerm", "--init", "/tmp/state.json", "--restore-commands", "execute"])
        try expectEqual(behavior, .execute)
    }

    test("restoreCommandBehavior falls back to prefill for unknown value") {
        let behavior = restoreCommandBehavior(from: ["DanTerm", "--restore-commands", "bogus"])
        try expectEqual(behavior, .prefill)
    }

    test("restoreInitialInput prefills without newline by default") {
        let input = restoreInitialInput(for: "node server.js", behavior: .prefill)
        try expectEqual(input, "node server.js")
    }

    test("restoreInitialInput execute appends trailing newline") {
        let input = restoreInitialInput(for: "node server.js", behavior: .execute)
        try expectEqual(input, "node server.js\n")
    }

    test("restoreInitialInput execute preserves existing trailing newline") {
        let input = restoreInitialInput(for: "node server.js\n", behavior: .execute)
        try expectEqual(input, "node server.js\n")
    }

    test("restoreInitialInput returns nil for empty command") {
        let input = restoreInitialInput(for: "", behavior: .prefill)
        try expect(input == nil, "empty command should not produce input")
    }

    // MARK: - commandStarted Msg

    test("commandStarted sets lastCommand") {
        var model = makeModel()
        createTab(&model)
        let tab = model.groups[0].tabs[0]
        let paneId = tab.focusedPaneId
        update(&model, .commandStarted(paneId: paneId, command: "vim"))
        try expectEqual(model.panes[paneId]?.lastCommand, "vim")
    }

    test("commandStarted overwrites previous command") {
        var model = makeModel()
        createTab(&model)
        let tab = model.groups[0].tabs[0]
        let paneId = tab.focusedPaneId
        update(&model, .commandStarted(paneId: paneId, command: "vim"))
        update(&model, .commandStarted(paneId: paneId, command: "ssh"))
        try expectEqual(model.panes[paneId]?.lastCommand, "ssh")
    }

    test("commandStarted does not affect title") {
        var model = makeModel()
        createTab(&model)
        let tab = model.groups[0].tabs[0]
        let paneId = tab.focusedPaneId
        let titleBefore = model.panes[paneId]?.title
        update(&model, .commandStarted(paneId: paneId, command: "vim"))
        try expectEqual(model.panes[paneId]?.title, titleBefore)
    }

    test("surfaceTitle does not affect lastCommand") {
        var model = makeModel()
        createTab(&model)
        let tab = model.groups[0].tabs[0]
        let paneId = tab.focusedPaneId
        update(&model, .commandStarted(paneId: paneId, command: "vim"))
        update(&model, .surfaceTitle(paneId: paneId, title: "new title"))
        try expectEqual(model.panes[paneId]?.lastCommand, "vim")
    }

    // MARK: - truncateScrollback

    test("truncateScrollback: empty string returns nil") {
        try expect(truncateScrollback("") == nil, "empty should be nil")
    }

    test("truncateScrollback: whitespace-only returns nil") {
        try expect(truncateScrollback("  \n  \n  ") == nil, "whitespace should be nil")
    }

    test("truncateScrollback: text under limits gets trailing newline") {
        try expectEqual(truncateScrollback("line1\nline2\nline3"), "line1\nline2\nline3\n")
    }

    test("truncateScrollback: text already ending in newline preserved") {
        try expectEqual(truncateScrollback("line1\nline2\n"), "line1\nline2\n")
    }

    test("truncateScrollback: keeps last maxLines lines") {
        let lines = (1...5000).map { "line \($0)" }
        let text = lines.joined(separator: "\n")
        let result = truncateScrollback(text, maxLines: 4000)!
        let resultLines = result.split(separator: "\n")
        try expectEqual(resultLines.count, 4000)
        try expectEqual(String(resultLines.first!), "line 1001")
        try expectEqual(String(resultLines.last!), "line 5000")
    }

    test("truncateScrollback: over maxChars truncates at newline") {
        // Build text that's under line limit but over char limit
        let longLine = String(repeating: "x", count: 100)
        let lines = (1...100).map { _ in longLine }
        let text = lines.joined(separator: "\n")
        // maxChars=500 with 100-char lines + newlines
        let result = truncateScrollback(text, maxLines: 10000, maxChars: 500)!
        try expect(result.count <= 500, "result should be at most maxChars")
        // Should break at a newline boundary
        try expect(!result.hasPrefix("\n"), "should not start with newline")
    }

    test("truncateScrollback: exactly at limit") {
        let result = truncateScrollback("a\nb", maxLines: 2)!
        try expectEqual(result, "a\nb\n")
    }

    test("truncateScrollback: one over limit") {
        let result = truncateScrollback("a\nb\nc", maxLines: 2)!
        try expectEqual(result, "b\nc\n")
    }

    test("truncateScrollback: consecutive newlines count as empty lines") {
        let result = truncateScrollback("a\n\n\nb", maxLines: 2)!
        try expectEqual(result, "\nb\n")
    }

    test("truncateScrollback: trailing whitespace-only lines are stripped") {
        let result = truncateScrollback("hello\nworld\n   \n   \n   \n")!
        try expectEqual(result, "hello\nworld\n")
    }

    test("truncateScrollback: trailing empty lines are stripped") {
        let result = truncateScrollback("hello\nworld\n\n\n\n")!
        try expectEqual(result, "hello\nworld\n")
    }

    test("truncateScrollback: trailing whitespace-only lines without final newline") {
        let result = truncateScrollback("hello\nworld\n   \n   ")!
        try expectEqual(result, "hello\nworld\n")
    }

    test("truncateScrollback: trailing empty lines without final newline") {
        let result = truncateScrollback("hello\nworld\n\n")!
        try expectEqual(result, "hello\nworld\n")
    }

    test("truncateScrollback: all-whitespace without final newline returns nil") {
        try expect(truncateScrollback("   \n   ") == nil, "only whitespace lines should be nil")
    }

    test("truncateScrollback: all-whitespace trailing lines returns nil") {
        try expect(truncateScrollback("   \n   \n") == nil, "only whitespace lines should be nil")
    }

    test("truncateScrollback: real scrollback without final newline (ghostty format)") {
        let input = "╭ repo:danterm                                                                         k8s:orbstack\n╰ $                                                                                                \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   "
        let result = truncateScrollback(input)!
        try expectEqual(result, "╭ repo:danterm                                                                         k8s:orbstack\n╰ $\n")
    }

    test("truncateScrollback: real scrollback with padded trailing blank lines") {
        let input = "╭ repo:danterm                                                                         k8s:orbstack\n╰ $                                                                                                \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n"
        let result = truncateScrollback(input)!
        try expectEqual(result, "╭ repo:danterm                                                                         k8s:orbstack\n╰ $\n")
    }

    // MARK: - exportState Msg/Effect

    test("exportState effect contains AppModelSnapshot") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.panes[paneId]?.lastCommand = "vim"
        model.panes[paneId]?.cwd = NSHomeDirectory() + "/projects"

        let expected = toSnapshot(model)
        let effects = update(&model, .exportState)
        try expectEqual(effects.count, 1)
        guard case .exportState(let snapshot) = effects[0] else {
            throw TestFailure(message: "expected .exportState effect")
        }
        try expectEqual(snapshot.groups.count, expected.groups.count)
        try expectEqual(snapshot.panes.count, expected.panes.count)
        try expectEqual(snapshot.selectedTabId, expected.selectedTabId)
        // Verify IDs match
        try expectEqual(snapshot.groups[0].id, expected.groups[0].id)
        try expectEqual(snapshot.groups[0].tabs[0].id, expected.groups[0].tabs[0].id)
        try expectEqual(snapshot.groups[0].tabs[0].focusedPaneId, expected.groups[0].tabs[0].focusedPaneId)
        // Verify launch fields
        try expectEqual(snapshot.panes[0].id, expected.panes[0].id)
        try expectEqual(snapshot.panes[0].launch?.command, "vim")
        try expectEqual(snapshot.panes[0].launch?.cwd, "~/projects")
        // Pure snapshot has nil scrollback (enrichment happens in runtime)
        try expect(snapshot.panes[0].scrollback == nil, "pure snapshot should have nil scrollback")
        // Verify rootNode type
        if case .leaf(let snapPaneId) = snapshot.groups[0].tabs[0].rootNode {
            try expectEqual(snapPaneId, paneId.rawValue.uuidString)
        } else {
            throw TestFailure(message: "expected leaf rootNode")
        }
    }

    // MARK: - toSnapshot round-trip

    test("toSnapshot round-trips through validateAndBuild") {
        var model = makeModel()
        createTab(&model)
        let snapshot = toSnapshot(model)
        let rebuilt = validateAndBuild(snapshot)
        try expect(rebuilt != nil, "round-trip should produce valid model")
        try expectEqual(rebuilt!.groups.count, model.groups.count)
        try expectEqual(rebuilt!.panes.count, model.panes.count)
    }

    test("toSnapshot preserves UUIDs through round-trip") {
        var model = makeModel()
        createTab(&model)
        let snapshot = toSnapshot(model)
        let rebuilt = validateAndBuild(snapshot)!
        try expectEqual(rebuilt.groups[0].id, model.groups[0].id)
        try expectEqual(rebuilt.groups[0].tabs[0].id, model.groups[0].tabs[0].id)
        try expectEqual(rebuilt.selectedTabId, model.selectedTabId)
        let origPaneId = model.groups[0].tabs[0].focusedPaneId
        try expect(rebuilt.panes[origPaneId] != nil, "pane ID should survive round-trip")
    }

    test("toSnapshot preserves selectedTabId") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: firstTabId))
        let snapshot = toSnapshot(model)
        try expectEqual(snapshot.selectedTabId, firstTabId.rawValue.uuidString)
    }

    test("toSnapshot preserves split tree structure") {
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        let snapshot = toSnapshot(model)
        let rebuilt = validateAndBuild(snapshot)!
        let tab = rebuilt.groups[0].tabs[0]
        if case .split(_, let dir, _, _, let ratio) = tab.rootNode {
            try expectEqual(dir, .horizontal)
            try expectEqual(ratio, 0.5)
        } else {
            throw TestFailure(message: "expected split node")
        }
        try expectEqual(allPaneIds(tab.rootNode).count, 2)
    }

    test("toSnapshot preserves multiple groups") {
        var model = makeModel()
        createTab(&model)
        update(&model, .createGroup(name: "Work"))
        let snapshot = toSnapshot(model)
        let rebuilt = validateAndBuild(snapshot)!
        try expectEqual(rebuilt.groups.count, 2)
        try expectEqual(rebuilt.groups[0].name, "General")
        try expectEqual(rebuilt.groups[1].name, "Work")
    }

    test("toSnapshot preserves group collapsed state") {
        var model = makeModel()
        createTab(&model)
        update(&model, .createGroup(name: "Work"))
        update(&model, .toggleGroupCollapse(groupId: model.groups[1].id))
        let snapshot = toSnapshot(model)
        try expectEqual(snapshot.groups[1].isCollapsed, true)
    }

    // MARK: - Launch field

    test("lastCommand maps to launch.command in snapshot") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.panes[paneId]?.lastCommand = "vim"
        let snapshot = toSnapshot(model)
        try expectEqual(snapshot.panes[0].launch?.command, "vim")
    }

    test("launch omitted when no command and no cwd") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.panes[paneId]?.cwd = nil
        model.panes[paneId]?.lastCommand = nil
        let snapshot = toSnapshot(model)
        try expect(snapshot.panes[0].launch == nil, "launch should be nil when no command and no cwd")
    }

    test("cwd abbreviated with ~ in export") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let home = NSHomeDirectory()
        model.panes[paneId]?.cwd = home + "/projects"
        let snapshot = toSnapshot(model)
        try expectEqual(snapshot.panes[0].cwd, "~/projects")
    }

    test("launch.cwd present when cwd is set") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let home = NSHomeDirectory()
        model.panes[paneId]?.cwd = home + "/work"
        let snapshot = toSnapshot(model)
        try expectEqual(snapshot.panes[0].launch?.cwd, "~/work")
    }

    test("launch has both command and cwd when both set") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let home = NSHomeDirectory()
        model.panes[paneId]?.cwd = home + "/code"
        model.panes[paneId]?.lastCommand = "claude"
        let snapshot = toSnapshot(model)
        let launch = snapshot.panes[0].launch
        try expect(launch != nil, "launch should be present")
        try expectEqual(launch?.command, "claude")
        try expectEqual(launch?.cwd, "~/code")
    }

    // MARK: - JSON round-trip

    test("JSON round-trip preserves command metadata") {
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.panes[paneId]?.lastCommand = "claude"
        model.panes[paneId]?.cwd = NSHomeDirectory() + "/work"

        let initFile = toInitFile(model)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(initFile)
        let decoded = try JSONDecoder().decode(AppInitFile.self, from: data)

        // Verify snapshot-level launch fields survive encoding
        let exportedPane = decoded.model.panes.first(where: { $0.id == paneId.rawValue.uuidString })
        try expect(exportedPane != nil, "pane should exist in decoded snapshot")
        try expectEqual(exportedPane?.launch?.command, "claude")
        try expectEqual(exportedPane?.launch?.cwd, "~/work")

        // Verify full rebuild succeeds
        let rebuilt = validateAndBuild(decoded.model)
        try expect(rebuilt != nil, "JSON round-trip should produce valid model")
        try expectEqual(rebuilt!.panes.count, 2)
    }
}
