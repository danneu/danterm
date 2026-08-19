// Tests for the public `danterm` command-line parser.
import Foundation
import Testing
@testable import DanTermProtocol

struct CLIParserTests {
    // Each command arrives complete except for its target, so the parser must
    // refuse it and say which flag is missing. Checking the message is what
    // makes the case honest: a bare "it threw" passes just as well when the
    // parser rejected the command for some unrelated reason.
    @Test("every targeting command requires an explicit target", arguments: targetingCommands)
    func everyTargetingCommandRequiresAnExplicitTarget(_ command: TargetingCommand) {
        let args = command.args(nil)
        let error = #expect(throws: CLIParseError.self) {
            _ = try parseCLI(args)
        }
        #expect(
            error?.message.contains(command.usageToken) == true,
            "\(command.label) should name \(command.usageToken), got: \(error?.message ?? "no error")"
        )
    }

    // The id never reaches the app: three shared helpers in CLIParser turn a
    // raw string into a PaneId, TabId, or GroupId, and each refuses anything
    // that is not a UUID. This drives all three from the same list as the
    // sweep above, so a command cannot be checked on one axis and not the other.
    @Test("every targeting command refuses a target that is not an id", arguments: targetingCommands)
    func everyTargetingCommandRefusesAMalformedId(_ command: TargetingCommand) {
        let args = command.args("not-an-id")
        let error = #expect(throws: CLIParseError.self) {
            _ = try parseCLI(args)
        }
        #expect(
            error?.message == "invalid \(command.entity) id: not-an-id",
            "\(command.label) got: \(error?.message ?? "no error")"
        )
    }

    @Test("global socket target parses before the command")
    func globalSocketTargetParsesBeforeCommand() throws {
        let invocation = try parseCLIInvocation(["--socket", "/tmp/slot.sock", "ls"])

        #expect(invocation.target == .unixSocket(path: "/tmp/slot.sock"))
        #expect(invocation.command == CLICommand(request: .ls, outputMode: .json))
    }

    @Test("global TCP target parses before the command")
    func globalTCPTargetParsesBeforeCommand() throws {
        let invocation = try parseCLIInvocation(["--tcp", "localhost:24863", "ls"])

        #expect(invocation.target == .tcp(host: "localhost", port: 24863))
        #expect(invocation.command == CLICommand(request: .ls, outputMode: .json))
    }

    @Test("invocation without a socket target preserves command parsing")
    func invocationWithoutSocketPreservesCommandParsing() throws {
        let invocation = try parseCLIInvocation(["ls"])
        let command = try parseCLI(["ls"])

        #expect(invocation.target == nil)
        #expect(invocation.command == command)
    }

    @Test("focus parses as a target-free JSON query")
    func focusParsesAsTargetFreeJSONQuery() throws {
        let command = try parseCLI(["focus"])

        #expect(command.request == .focusInfo)
        #expect(command.method == IpcRequestMethod.focusInfo.rawValue)
        #expect(command.params.isEmpty)
        #expect(command.outputMode == .json)
    }

    @Test("quit parses as a target-free command with no output")
    func quitParsesAsTargetFreeCommand() throws {
        let command = try parseCLI(["quit"])

        #expect(command.request == .quit)
        #expect(command.method == IpcRequestMethod.quit.rawValue)
        #expect(command.params.isEmpty)
        #expect(command.outputMode == .none)
    }

    @Test("quit takes no arguments")
    func quitTakesNoArguments() {
        let error = #expect(throws: CLIParseError.self) {
            try parseCLI(["quit", "--force"])
        }

        #expect(error?.message == "usage: danterm quit")
    }

    @Test("tailnet status parses as a target-free JSON command")
    func tailnetStatusParsesAsTargetFreeCommand() throws {
        let command = try parseCLI(["tailnet", "status"])

        #expect(command.request == .tailnetStatus)
        #expect(command.method == IpcRequestMethod.tailnetStatus.rawValue)
        #expect(command.params.isEmpty)
        #expect(command.outputMode == .json)
    }

    @Test("tailnet rejects an unknown or missing subcommand", arguments: [
        ["tailnet"],
        ["tailnet", "listen"],
        ["tailnet", "status", "--json"],
    ])
    func tailnetRejectsUnknownSubcommand(_ args: [String]) {
        let error = #expect(throws: CLIParseError.self) {
            try parseCLI(args)
        }

        #expect(error?.message == "usage: danterm tailnet status")
    }

    @Test("global socket target rejects unusable forms", arguments: [
        (["--socket"], "usage: danterm --socket <path> <command> [args]"),
        (["--socket", "", "ls"], "--socket requires a non-empty path"),
        (["--socket", "/tmp/one.sock", "--socket", "/tmp/two.sock", "ls"], "--socket may be specified only once"),
    ] as [([String], String)])
    func globalSocketTargetRejectsUnusableForms(_ testCase: ([String], String)) {
        let error = #expect(throws: CLIParseError.self) {
            try parseCLIInvocation(testCase.0)
        }

        #expect(error?.message == testCase.1)
    }

    @Test("global TCP target rejects unusable forms", arguments: [
        (["--tcp"], "usage: danterm --tcp <host:port> <command> [args]"),
        (["--tcp", "", "ls"], "--tcp requires a non-empty host:port"),
        (["--tcp", "localhost:", "ls"], "--tcp requires host:port"),
        (["--tcp", ":24863", "ls"], "--tcp requires host:port"),
        (["--tcp", "localhost:0", "ls"], "--tcp port must be between 1 and 65535"),
        (["--tcp", "localhost:24863", "--tcp", "localhost:24864", "ls"], "--tcp may be specified only once"),
        (["--socket", "/tmp/control.sock", "--tcp", "localhost:24863", "ls"], "--socket and --tcp are mutually exclusive"),
        (["--tcp", "localhost:24863", "--socket", "/tmp/control.sock", "ls"], "--socket and --tcp are mutually exclusive"),
    ] as [([String], String)])
    func globalTCPTargetRejectsUnusableForms(_ testCase: ([String], String)) {
        let error = #expect(throws: CLIParseError.self) {
            try parseCLIInvocation(testCase.0)
        }

        #expect(error?.message == testCase.1)
    }

    @Test("tab new parses launch flags")
    func tabNewParsesLaunchFlags() throws {
        let command = try parseCLI(["tab", "new", "--group", groupId, "--cmd", "foo", "--cwd", "/x", "--title", "t"])
        #expect(command.method == IpcRequestMethod.tabNew.rawValue)
        #expect(command.outputMode == .json)
        #expect(command.params["launch"] == .object([
            "cmd": .string("foo"),
            "cwd": .string("/x"),
            "title": .string("t"),
        ]))
    }

    @Test("tab new supplies the caller process working directory")
    func tabNewSuppliesCallerWorkingDirectory() throws {
        let command = try parseCLI(
            ["tab", "new", "--group", groupId],
            currentDirectory: "/caller"
        )

        #expect(command.params["launch"]?["cwd"] == .string("/caller"))
    }

    @Test("tab new parses background flag")
    func tabNewParsesBackgroundFlag() throws {
        let command = try parseCLI(["tab", "new", "--group", groupId, "--background"])
        #expect(command.method == IpcRequestMethod.tabNew.rawValue)
        #expect(command.outputMode == .json)
        #expect(command.params["background"] == .bool(true))
    }

    @Test("tab new parses position flags")
    func tabNewParsesPositionFlags() throws {
        let afterSelected = try parseCLI(["tab", "new", "--group", groupId, "--after-selected"])
        #expect(afterSelected.params["position"] == .string("afterSelected"))
        #expect(afterSelected.params["afterTabId"] == nil)

        let atGroupEnd = try parseCLI(["tab", "new", "--group", groupId, "--at-group-end"])
        #expect(atGroupEnd.params["position"] == .string("atGroupEnd"))
        #expect(atGroupEnd.params["afterTabId"] == nil)

        let afterTab = try parseCLI(["tab", "new", "--after-tab", tabId])
        #expect(afterTab.params["position"] == .string("afterTab"))
        #expect(afterTab.params["afterTabId"] == .string(tabId))
    }

    @Test("tab new with a group defaults to group end in background")
    func tabNewWithoutPositionFlagDefaultsToGroupEndInBackground() throws {
        // Intent: bare `tab new` emits deterministic, background CLI policy.
        // Why it exists: agents should not insert relative to live focus or steal
        //   focus when they forget optional flags.
        // Scenario: an agent opens a tab with no position or focus flags.
        let command = try parseCLI(["tab", "new", "--group", groupId])
        #expect(command.params["position"] == .string("atGroupEnd"))
        #expect(command.params["afterTabId"] == nil)
        #expect(command.params["background"] == .bool(true))
    }

    @Test("tab new conflicting position flags throw usage error")
    func tabNewConflictingPositionFlagsThrowUsageError() {
        let error = #expect(throws: CLIParseError.self) {
            try parseCLI(["tab", "new", "--group", groupId, "--after-selected", "--at-group-end"])
        }
        #expect(error?.message.contains("mutually exclusive") == true)
        #expect(error?.message.contains(tabNewUsageWithPositionFlags) == true)
    }

    @Test("tab new missing after tab value throws updated usage error")
    func tabNewMissingAfterTabValueThrowsUpdatedUsageError() {
        let error = #expect(throws: CLIParseError.self) {
            try parseCLI(["tab", "new", "--after-tab"])
        }
        #expect(error?.message.hasPrefix("usage: danterm tab new") == true)
        #expect(error?.message.contains("--after-tab") == true)
    }

    @Test("pane info parses an explicit pane")
    func paneInfoParsesExplicitPane() throws {
        let explicit = try parseCLI(["pane", "info", "--pane", paneId])
        #expect(explicit.method == IpcRequestMethod.paneInfo.rawValue)
        #expect(explicit.outputMode == .json)
        #expect(explicit.params["pane"] == .string(paneId))

    }

    @Test("pane focus parses pane param")
    func paneFocusParsesPaneParam() throws {
        let command = try parseCLI(["pane", "focus", paneId])

        #expect(command.method == IpcRequestMethod.paneFocus.rawValue)
        #expect(command.outputMode == .none)
        #expect(command.params["pane"] == .string(paneId))
        #expect(command.params["paneId"] == nil)
    }

    @Test("agent attach parses to silent mutation")
    func agentAttachParsesToSilentMutation() throws {
        let command = try parseCLI(["agent", "attach", "--pane", paneId, "--kind", "claude", "--id", "4f3a2b1c"])

        #expect(command.method == IpcRequestMethod.agentAttach.rawValue)
        #expect(command.outputMode == .none)
        #expect(command.params["pane"] == .string(paneId))
        #expect(command.params["kind"] == .string("claude"))
        #expect(command.params["id"] == .string("4f3a2b1c"))
    }

    @Test("agent attach missing flags throw usage", arguments: [
        ["agent", "attach", "--kind", "claude"],
        ["agent", "attach", "--id", "4f3a2b1c"],
        ["agent", "attach", "--kind"],
        ["agent", "attach", "--id"],
    ])
    func agentAttachMissingFlagsThrowUsage(_ args: [String]) {
        let error = #expect(throws: CLIParseError.self) {
            try parseCLI(args)
        }
        #expect(error?.message == "usage: danterm agent attach --pane <pane-id> --kind <kind> --id <session-id>")
    }

    @Test("agent activity and detach parse to silent mutations")
    func agentLifecycleParsesToSilentMutations() throws {
        let activity = try parseCLI([
            "agent", "activity", "--pane", paneId, "--kind", "codex", "--id", "thread-1", "--state", "waiting",
        ])
        #expect(activity.method == IpcRequestMethod.agentActivity.rawValue)
        #expect(activity.outputMode == .none)
        #expect(activity.params["kind"] == .string("codex"))
        #expect(activity.params["id"] == .string("thread-1"))
        #expect(activity.params["state"] == .string("waiting"))

        let detach = try parseCLI(["agent", "detach", "--pane", paneId, "--kind", "claude", "--id", "session-1"])
        #expect(detach.method == IpcRequestMethod.agentDetach.rawValue)
        #expect(detach.outputMode == .none)
        #expect(detach.params["kind"] == .string("claude"))
        #expect(detach.params["id"] == .string("session-1"))
    }

    @Test("agent activity accepts only declared states", arguments: ["busy", "question", "done"])
    func agentActivityRejectsUnsupportedStates(_ state: String) {
        let error = #expect(throws: CLIParseError.self) {
            try parseCLI([
                "agent", "activity", "--pane", paneId, "--kind", "codex", "--id", "thread-1", "--state", state,
            ])
        }
        #expect(error?.message == "agent activity state must be working, waiting, or idle")
    }

    @Test("explicit target flags parse")
    func explicitTargetFlagsParse() throws {
        let newTab = try parseCLI(["tab", "new", "--group", groupId])
        #expect(newTab.method == IpcRequestMethod.tabNew.rawValue)
        #expect(newTab.params["group"] == .string(groupId))

        let rename = try parseCLI(["tab", "rename", "--tab", tabId, "work"])
        #expect(rename.method == IpcRequestMethod.tabRename.rawValue)
        #expect(rename.params["tab"] == .string(tabId))
        #expect(rename.params["title"] == .string("work"))

        let clear = try parseCLI(["tab", "rename", "--tab", tabId, "--clear"])
        #expect(clear.method == IpcRequestMethod.tabRename.rawValue)
        #expect(clear.params["tab"] == .string(tabId))
        #expect(clear.params["title"] == .null)

        let theme = try parseCLI(["theme", "set", "--pane", paneId, "TokyoNight"])
        #expect(theme.method == IpcRequestMethod.themeSet.rawValue)
        #expect(theme.params["pane"] == .string(paneId))
        #expect(theme.params["themeName"] == .string("TokyoNight"))

        let themeClear = try parseCLI(["theme", "set", "--pane", paneId, "--clear"])
        #expect(themeClear.method == IpcRequestMethod.themeSet.rawValue)
        #expect(themeClear.params["pane"] == .string(paneId))
        #expect(themeClear.params["themeName"] == .null)
    }

    @Test("tab rename parses string and clear")
    func tabRenameParsesStringAndClear() throws {
        let rename = try parseCLI(["tab", "rename", "--tab", tabId, "work", "logs"])
        #expect(rename.method == IpcRequestMethod.tabRename.rawValue)
        #expect(rename.params["title"] == .string("work logs"))
        #expect(rename.outputMode == .none)

        let clear = try parseCLI(["tab", "rename", "--tab", tabId, "--clear"])
        #expect(clear.method == IpcRequestMethod.tabRename.rawValue)
        #expect(clear.params["title"] == .null)
    }

    // A group always has a name, so `group rename` has no `--clear` counterpart to
    // the `tab rename` form this pairs with.
    @Test("group rename joins a multi-word name")
    func groupRenameJoinsMultiWordName() throws {
        let command = try parseCLI(["group", "rename", "--group", groupId, "work", "logs"])
        #expect(command.method == IpcRequestMethod.groupRename.rawValue)
        #expect(command.params["group"] == .string(groupId))
        #expect(command.params["name"] == .string("work logs"))
        #expect(command.outputMode == .none)
    }

    // The background default is CLI policy, not the reducer's: `Msg.createGroup`
    // selects the new tab, and an agent creating a group must not steal the user's
    // focus. `--foreground` is the only way to ask for it.
    @Test("group new defaults to background and inverts only with --foreground")
    func groupNewDefaultsToBackground() throws {
        let background = try parseCLI(["group", "new", "--name", "Notes"], currentDirectory: "/caller")
        #expect(background.method == IpcRequestMethod.groupNew.rawValue)
        #expect(background.params["name"] == .string("Notes"))
        #expect(background.params["background"] == .bool(true))
        #expect(background.outputMode == .json)

        let foreground = try parseCLI(
            ["group", "new", "--name", "Notes", "--foreground"], currentDirectory: "/caller")
        #expect(foreground.params["background"] == .bool(false))
    }

    @Test("group new carries the launch spec and defaults cwd to the caller")
    func groupNewCarriesLaunchSpec() throws {
        let command = try parseCLI(
            ["group", "new", "--name", "Builds", "--cmd", "just test", "--title", "tests"],
            currentDirectory: "/caller")

        #expect(command.params["launch"]?["cmd"]?.asString == "just test")
        #expect(command.params["launch"]?["cwd"]?.asString == "/caller")
        #expect(command.params["launch"]?["title"]?.asString == "tests")

        let explicitCwd = try parseCLI(
            ["group", "new", "--name", "Builds", "--cwd", "/proj"], currentDirectory: "/caller")
        #expect(explicitCwd.params["launch"]?["cwd"]?.asString == "/proj")
    }

    @Test("group close parses the move-tabs flag")
    func groupCloseParsesMoveTabsFlag() throws {
        let plain = try parseCLI(["group", "close", "--group", groupId])
        #expect(plain.method == IpcRequestMethod.groupClose.rawValue)
        #expect(plain.params["group"] == .string(groupId))
        #expect(plain.params["moveTabs"] == .bool(false))
        #expect(plain.outputMode == .none)

        let moved = try parseCLI(["group", "close", "--group", groupId, "--move-tabs"])
        #expect(moved.params["moveTabs"] == .bool(true))
    }

    @Test("tab close parses explicit tab")
    func tabCloseParsesExplicitTab() throws {
        let command = try parseCLI(["tab", "close", "--tab", tabId])
        #expect(command.method == IpcRequestMethod.tabClose.rawValue)
        #expect(command.params["tab"] == .string(tabId))
        #expect(command.outputMode == .none)
    }

    @Test("pane close parses an explicit pane as a silent mutation")
    func paneCloseParsesExplicitPane() throws {
        let command = try parseCLI(["pane", "close", "--pane", paneId])

        #expect(command.method == IpcRequestMethod.paneClose.rawValue)
        #expect(command.params == ["pane": .string(paneId)])
        #expect(command.outputMode == .none)
    }

    @Test("pane close requires a non-empty explicit pane", arguments: [
        ["pane", "close"],
        ["pane", "close", "--pane"],
        ["pane", "close", "--pane", ""],
    ])
    func paneCloseRequiresNonEmptyExplicitPane(_ args: [String]) {
        let error = #expect(throws: CLIParseError.self) {
            try parseCLI(args)
        }

        #expect(error?.message == "usage: danterm pane close --pane <pane-id>")
    }

    @Test("pane command usage lists every supported subcommand")
    func paneCommandUsageListsEverySubcommand() {
        let error = #expect(throws: CLIParseError.self) {
            try parseCLI(["pane"])
        }

        #expect(
            error?.message
                == "usage: danterm pane <focus|info|split|close|input|read|rows|zoom|resize|tape|snapshot>"
        )
    }

    @Test("group command usage lists every supported subcommand")
    func groupCommandUsageListsEverySubcommand() {
        let error = #expect(throws: CLIParseError.self) {
            try parseCLI(["group"])
        }

        #expect(error?.message == "usage: danterm group <new|rename|close>")
    }

    @Test("todo explicit pane forms parse")
    func todoExplicitPaneFormsParse() throws {
        let list = try parseCLI(["todo", "list", "--pane", paneId])
        #expect(list.method == IpcRequestMethod.todoList.rawValue)
        #expect(list.outputMode == .json)
        #expect(list.params["pane"] == .string(paneId))

        let add = try parseCLI(["todo", "add", "--pane", paneId, "write", "test"])
        #expect(add.method == IpcRequestMethod.todoAdd.rawValue)
        #expect(add.outputMode == .json)
        #expect(add.params["pane"] == .string(paneId))
        #expect(add.params["text"] == .string("write test"))

        let todoId = "44444444-4444-4444-8444-444444444444"
        let edit = try parseCLI(["todo", "edit", "--pane", paneId, todoId, "write", "test"])
        #expect(edit.method == IpcRequestMethod.todoEdit.rawValue)
        #expect(edit.params["pane"] == .string(paneId))
        #expect(edit.params["todoId"] == .string(todoId))
        #expect(edit.params["text"] == .string("write test"))

        let clear = try parseCLI(["todo", "clear-completed", "--pane", paneId])
        #expect(clear.method == IpcRequestMethod.todoClearCompleted.rawValue)
        #expect(clear.params["pane"] == .string(paneId))
    }

    @Test("todo state mutations parse explicit panes", arguments: [
        ("done", IpcRequestMethod.todoDone.rawValue),
        ("open", IpcRequestMethod.todoOpen.rawValue),
        ("delete", IpcRequestMethod.todoDelete.rawValue),
    ])
    func todoStateMutationsParseExplicitPanes(_ testCase: (subcommand: String, method: String)) throws {
        let todoId = "44444444-4444-4444-8444-444444444444"
        let command = try parseCLI(["todo", testCase.subcommand, "--pane", paneId, todoId])
        #expect(command.method == testCase.method)
        #expect(command.params["pane"] == .string(paneId))
        #expect(command.params["todoId"] == .string(todoId))
    }

    @Test("todo verbs accept tab owners and typed todo ids", arguments: [
        "done", "open", "delete",
    ])
    func todoStateMutationsParseTabs(_ subcommand: String) throws {
        let todoId = "44444444-4444-4444-8444-444444444444"
        let command = try parseCLI(["todo", subcommand, "--tab", tabId, todoId])
        #expect(command.params["tab"] == .string(tabId))
        #expect(command.params["todoId"] == .string(todoId))
    }

    @Test("todo owners are mutually exclusive and todo ids are validated locally")
    func todoTargetValidation() {
        let usage = "usage: danterm todo done (--pane <pane-id> | --tab <tab-id>) <todo-id>"
        for args in [
            ["todo", "done", "44444444-4444-4444-8444-444444444444"],
            ["todo", "done", "--pane", paneId, "--tab", tabId, "44444444-4444-4444-8444-444444444444"],
            ["todo", "done", "--pane", paneId, "not-a-uuid"],
        ] {
            let error = #expect(throws: CLIParseError.self) { try parseCLI(args) }
            #expect(error?.message == usage)
        }
    }

    @Test("pane input read and split parse")
    func paneInputReadAndSplitParse() throws {
        let input = try parseCLI(["pane", "input", "--pane", paneId, "--", "ls", "Enter"])
        #expect(input.method == IpcRequestMethod.paneInput.rawValue)
        #expect(input.params["pane"] == .string(paneId))
        #expect(input.outputMode == .none)

        let read = try parseCLI(["pane", "read", "--pane", paneId, "--lines", "20"])
        #expect(read.method == IpcRequestMethod.paneRead.rawValue)
        #expect(read.params["lines"] == .number(20))
        #expect(read.outputMode == .text)

        let split = try parseCLI(["pane", "split", "--pane", paneId, "-v", "--cmd", "top", "--title", "monitor"])
        #expect(split.method == IpcRequestMethod.paneSplit.rawValue)
        #expect(split.outputMode == .json)
        #expect(split.params["pane"] == .string(paneId))
        #expect(split.params["direction"] == .string("vertical"))
        #expect(split.params["launch"] == .object([
            "cmd": .string("top"),
            "title": .string("monitor"),
        ]))
    }

    @Test("pane rows requires an explicit pane and takes no other argument")
    func paneRowsRequiresExplicitPane() throws {
        let command = try parseCLI(["pane", "rows", "--pane", paneId])
        #expect(command.method == IpcRequestMethod.paneRows.rawValue)
        #expect(command.params == ["pane": .string(paneId)])
        #expect(command.outputMode == .json)

        #expect(throws: CLIParseError.self) { _ = try parseCLI(["pane", "rows"]) }
        #expect(throws: CLIParseError.self) {
            _ = try parseCLI(["pane", "rows", "--pane", paneId, "--lines", "20"])
        }
    }

    @Test("pane zoom takes a positional state and an explicit pane")
    func paneZoomTakesPositionalState() throws {
        let explicit = try parseCLI(["pane", "zoom", "--pane", paneId, "on"])
        #expect(explicit.method == IpcRequestMethod.paneZoom.rawValue)
        #expect(explicit.params == ["pane": .string(paneId), "state": .string("on")])
        #expect(explicit.outputMode == .json)

        #expect(throws: CLIParseError.self) { _ = try parseCLI(["pane", "zoom"]) }
        #expect(throws: CLIParseError.self) { _ = try parseCLI(["pane", "zoom", "sideways"]) }
        #expect(throws: CLIParseError.self) { _ = try parseCLI(["pane", "zoom", "on", "off"]) }
    }

    @Test("pane resize parses the grid form and the fit form")
    func paneResizeParsesBothForms() throws {
        let grid = try parseCLI(["pane", "resize", "--pane", paneId, "80x24"])
        #expect(grid.method == IpcRequestMethod.paneResize.rawValue)
        #expect(grid.params == [
            "pane": .string(paneId),
            "columns": .number(80),
            "rows": .number(24),
        ])
        #expect(grid.outputMode == .json)

        let fit = try parseCLI(["pane", "resize", "--pane", paneId, "--fit"])
        #expect(fit.method == IpcRequestMethod.paneResize.rawValue)
        #expect(fit.params == ["pane": .string(paneId), "fit": .bool(true)])
        #expect(fit.outputMode == .json)
    }

    // The grammar, not a check, is what keeps a caller from asking for a grid
    // and a fit at once, so every mixed or malformed spelling has to land on the
    // same usage error rather than on a silently preferred half.
    @Test("pane resize refuses every shape that is not exactly one form", arguments: [
        ["pane", "resize", "--pane", paneId],
        ["pane", "resize", "--pane", paneId, "80x24", "--fit"],
        ["pane", "resize", "--pane", paneId, "80x24", "60x20"],
        ["pane", "resize", "--pane", paneId, "80"],
        ["pane", "resize", "--pane", paneId, "80x"],
        ["pane", "resize", "--pane", paneId, "80x24x2"],
        ["pane", "resize", "--pane", paneId, "-4x24"],
        ["pane", "resize", "--pane", paneId, "0x24"],
        ["pane", "resize", "--pane", paneId, "80x0"],
        ["pane", "resize", "--pane", paneId, "eightyx24"],
    ])
    func paneResizeRefusesEveryOtherShape(_ args: [String]) {
        let error = #expect(throws: CLIParseError.self) { try parseCLI(args) }
        #expect(error?.message == "usage: danterm pane resize --pane <pane-id> <columns>x<rows>|--fit")
    }

    @Test("pane tape defaults a finite beginning dump to raw replay")
    func paneTapeDefaultsToRawReplay() throws {
        // Intent: with no --format flag, the command renders the exact-bytes stream.
        // Why it exists: the default output is what fixture conversion and replay consume, so
        // a default that derived a readable view would silently make every capture
        // unreplayable.
        let command = try parseCLI(["pane", "tape", "--pane", paneId])

        #expect(command.method == IpcRequestMethod.paneTape.rawValue)
        #expect(command.params == [
            "pane": .string(paneId),
            "start": .string("beginning"),
            "mode": .string("raw"),
        ])
        #expect(command.outputMode == .tapeStream(.replay))
    }

    @Test("pane tape takes the format each stream is rendered in", arguments: [
        ("replay", PaneTapeFormat.replay),
        ("inspect", PaneTapeFormat.inspect),
    ])
    func paneTapeTakesTheStreamFormat(_ testCase: (String, PaneTapeFormat)) throws {
        let command = try parseCLI([
            "pane", "tape", "--pane", paneId, "--format", testCase.0,
        ])

        #expect(command.outputMode == .tapeStream(testCase.1))
        // The format never reaches DanTerm: the app always sends exact bytes.
        #expect(command.params == [
            "pane": .string(paneId),
            "start": .string("beginning"),
            "mode": .string("raw"),
        ])
    }

    @Test("pane tape defaults follows and cursor resumes to reconstructible")
    func paneTapeParsesFollowAndCursorResume() throws {
        let follow = try parseCLI(["pane", "tape", "--pane", paneId, "--follow"])
        #expect(follow.params == [
            "pane": .string(paneId),
            "follow": .bool(true),
            "start": .string("beginning"),
            "mode": .string("reconstructible"),
            "syncHistoryBytes": .number(Double(PaneTapeSyncPolicy.defaultHistoryBudgetBytes)),
        ])

        let fromNow = try parseCLI([
            "pane", "tape", "--follow", "--from-now", "--pane", paneId,
        ])
        #expect(fromNow.params == [
            "pane": .string(paneId),
            "follow": .bool(true),
            "start": .string("now"),
            "mode": .string("reconstructible"),
            "syncHistoryBytes": .number(Double(PaneTapeSyncPolicy.defaultHistoryBudgetBytes)),
        ])

        let cursor = """
            {"recorderLifetimeId":"11111111-1111-4111-8111-111111111111",\
            "sequence":7,"feedByteOffset":20,"writeByteOffset":3}
            """
        let resumed = try parseCLI([
            "pane", "tape", "--pane", paneId, "--from-cursor", cursor,
        ])
        #expect(resumed.params["start"] == .object([
            "cursor": .object([
                "recorderLifetimeId": .string("11111111-1111-4111-8111-111111111111"),
                "sequence": .number(7),
                "feedByteOffset": .number(20),
                "writeByteOffset": .number(3),
            ]),
        ]))
        #expect(resumed.params["mode"] == .string("reconstructible"))
    }

    @Test("pane tape accepts an explicit stream mode and pane snapshot is a stream")
    func paneTapeModeAndPaneSnapshot() throws {
        let reconstructed = try parseCLI([
            "pane", "tape", "--pane", paneId, "--reconstructible",
        ])
        #expect(reconstructed.params["mode"] == .string("reconstructible"))

        let rawFollow = try parseCLI([
            "pane", "tape", "--pane", paneId, "--follow", "--raw",
        ])
        #expect(rawFollow.params["mode"] == .string("raw"))

        let snapshot = try parseCLI(["pane", "snapshot", "--pane", paneId])
        #expect(snapshot.method == IpcRequestMethod.paneSnapshot.rawValue)
        #expect(snapshot.params == ["pane": .string(paneId)])
        #expect(snapshot.outputMode == .tapeStream(.replay))
    }

    // Intent: `--sync-history-bytes` reaches the request as the stream's history budget, and
    //   a reconstructible stream that names none carries the server default instead.
    // Why it exists: the budget is the whole point of the flag -- a stream that silently
    //   dropped it would sync the entire retained history and no test would notice, because
    //   the payload is correct either way and only its size differs.
    // Scenario: spec-first contract for the bounded pane.tape request.
    @Test("pane tape carries an explicit sync history budget, or the default")
    func paneTapeCarriesSyncHistoryBudget() throws {
        let explicit = try parseCLI([
            "pane", "tape", "--pane", paneId, "--reconstructible", "--sync-history-bytes", "4096",
        ])
        #expect(explicit.params["syncHistoryBytes"] == .number(4096))

        let gridOnly = try parseCLI([
            "pane", "tape", "--pane", paneId, "--follow", "--sync-history-bytes", "0",
        ])
        #expect(gridOnly.params["syncHistoryBytes"] == .number(0))

        let defaulted = try parseCLI(["pane", "tape", "--pane", paneId, "--reconstructible"])
        #expect(
            defaulted.params["syncHistoryBytes"]
                == .number(Double(PaneTapeSyncPolicy.defaultHistoryBudgetBytes))
        )

        // A raw stream emits no synchronization, so it states no budget at all.
        let raw = try parseCLI(["pane", "tape", "--pane", paneId, "--raw"])
        #expect(raw.params["syncHistoryBytes"] == nil)
    }

    @Test("pane tape rejects missing and unexpected arguments", arguments: [
        (["pane", "tape"], paneTapeUsage),
        (["pane", "tape", "--follow"], paneTapeUsage),
        (["pane", "tape", "--pane"], paneTapeUsage),
        (["pane", "tape", "--pane", paneId, "--format"], "--format requires replay or inspect\n\(paneTapeUsage)"),
        (["pane", "tape", "--pane", paneId, "--format", "bogus"], "unknown format: bogus\n\(paneTapeUsage)"),
        (["pane", "tape", "--pane", paneId, "extra"], "unexpected argument: extra"),
        (["pane", "tape", "--bogus"], "unknown flag: --bogus"),
        (
            ["pane", "tape", "--pane", paneId, "--reconstructible", "--sync-history-bytes"],
            "--sync-history-bytes requires a byte count\n\(paneTapeUsage)"
        ),
        (
            ["pane", "tape", "--pane", paneId, "--reconstructible", "--sync-history-bytes", "-1"],
            "invalid sync history bytes: -1\n\(paneTapeUsage)"
        ),
        (
            ["pane", "tape", "--pane", paneId, "--reconstructible", "--sync-history-bytes", "1.5"],
            "invalid sync history bytes: 1.5\n\(paneTapeUsage)"
        ),
        (
            ["pane", "tape", "--pane", paneId, "--raw", "--sync-history-bytes", "1024"],
            "--sync-history-bytes needs --reconstructible: a raw stream sends no sync\n\(paneTapeUsage)"
        ),
        (
            ["pane", "tape", "--pane", paneId, "--sync-history-bytes", "1024"],
            "--sync-history-bytes needs --reconstructible: a raw stream sends no sync\n\(paneTapeUsage)"
        ),
    ] as [([String], String)])
    func paneTapeRejectsMissingAndUnexpectedArguments(_ testCase: ([String], String)) {
        let error = #expect(throws: CLIParseError.self) {
            try parseCLI(testCase.0)
        }
        #expect(error?.message == testCase.1)
    }

    @Test("pane input serializes key event JSON")
    func paneInputSerializesKeyEventJSON() throws {
        // Intent: `pane input` serializes each token to the exact wire JSON the IPC
        //   decoder consumes -- the encode path end-to-end (argv -> params["input"]).
        // Why it exists: this plan moves key encoding into KeyName.wireName and rewires
        //   inputEventToJSON; without asserting the payload, a bad `.character` arm or a
        //   mis-wired call ships silently (the round-trip and classifier tests miss it).
        // Scenario: spec-first contract for the pane.input params["input"] array.
        let cmd = try parseCLI([
            "pane", "input", "--pane", paneId, "--",
            "BSpace", "Insert", "F12", "C-c", "C-\\", "C-Space", "S-Tab",
        ])
        #expect(cmd.params["input"] == .array([
            .object(["key": .string("BSpace")]),
            .object(["key": .string("Insert")]),
            .object(["key": .string("F12")]),
            .object(["key": .string("c"), "mods": .array([.string("ctrl")])]),
            .object(["key": .string("\\"), "mods": .array([.string("ctrl")])]),
            .object(["key": .string(" "), "mods": .array([.string("ctrl")])]),
            .object(["key": .string("Tab"), "mods": .array([.string("shift")])]),
        ]))
    }

    @Test("pane split parses background flag")
    func paneSplitParsesBackgroundFlag() throws {
        let command = try parseCLI(["pane", "split", "--pane", paneId, "-h", "--background"])
        #expect(command.method == IpcRequestMethod.paneSplit.rawValue)
        #expect(command.outputMode == .json)
        #expect(command.params["direction"] == .string("horizontal"))
        #expect(command.params["background"] == .bool(true))
    }

    @Test("tab new after selected defaults to background")
    func tabNewAfterSelectedDefaultsToBackground() throws {
        // Intent: explicit position choices do not opt into foreground focus.
        // Why it exists: focus policy is independent from tab-placement policy.
        // Scenario: an agent intentionally anchors after the selected tab but
        //   still expects the new tab to open in the background.
        let command = try parseCLI(["tab", "new", "--group", groupId, "--after-selected"])
        #expect(command.params["position"] == .string("afterSelected"))
        #expect(command.params["background"] == .bool(true))
    }

    @Test("tab new foreground disables background at group end")
    func tabNewForegroundDisablesBackgroundAtGroupEnd() throws {
        // Intent: `--foreground` is the explicit inverse of the new background
        //   default for tab creation.
        // Why it exists: switching to a new tab remains possible when the user
        //   asks for it, while placement stays deterministic by default.
        // Scenario: the user asks the agent to open a tab and switch to it.
        let command = try parseCLI(["tab", "new", "--group", groupId, "--foreground"])
        #expect(command.params["position"] == .string("atGroupEnd"))
        #expect(command.params["background"] == .bool(false))
    }

    @Test("tab new at group end explicit form matches default")
    func tabNewAtGroupEndExplicitFormMatchesDefault() throws {
        // Intent: the explicit at-group-end flag still serializes the same
        //   placement as the new default.
        // Why it exists: existing commands that already chose deterministic
        //   placement should keep their wire shape.
        // Scenario: an agent keeps passing `--at-group-end` after the default
        //   changes to that same policy.
        let command = try parseCLI(["tab", "new", "--group", groupId, "--at-group-end"])
        #expect(command.params["position"] == .string("atGroupEnd"))
        #expect(command.params["background"] == .bool(true))
    }

    @Test("tab new conflicting focus flags throw usage error")
    func tabNewConflictingFocusFlagsThrowUsageError() {
        // Intent: ambiguous tab focus flags produce a usage error.
        // Why it exists: command composition should fail loudly instead of
        //   silently choosing background or foreground.
        // Scenario: a recipe leaves legacy `--background` while adding
        //   `--foreground` for a user-requested switch.
        let error = #expect(throws: CLIParseError.self) {
            try parseCLI(["tab", "new", "--group", groupId, "--background", "--foreground"])
        }
        #expect(error?.message.contains("--background and --foreground are mutually exclusive") == true)
        #expect(error?.message.contains(tabNewUsageWithPositionFlags) == true)
    }

    @Test("pane split defaults to background")
    func paneSplitDefaultsToBackground() throws {
        // Intent: pane split defaults to leaving the caller's pane focused.
        // Why it exists: autonomous splits should not steal focus when the
        //   agent omits optional focus flags.
        // Scenario: an agent splits a known pane horizontally.
        let command = try parseCLI(["pane", "split", "--pane", paneId, "-h"])
        #expect(command.params["direction"] == .string("horizontal"))
        #expect(command.params["background"] == .bool(true))
    }

    @Test("pane split foreground disables background")
    func paneSplitForegroundDisablesBackground() throws {
        // Intent: `pane split --foreground` asks the app to focus the new pane
        //   within the target tab.
        // Why it exists: foreground split remains available without changing
        //   selected-tab navigation semantics.
        // Scenario: the user asks the agent to split and focus the new pane.
        let command = try parseCLI(["pane", "split", "--pane", paneId, "-h", "--foreground"])
        #expect(command.params["direction"] == .string("horizontal"))
        #expect(command.params["background"] == .bool(false))
    }

    @Test("pane split conflicting focus flags throw usage error")
    func paneSplitConflictingFocusFlagsThrowUsageError() {
        // Intent: ambiguous pane-split focus flags produce a usage error.
        // Why it exists: focus policy should be explicit when both inverse flags
        //   appear in one command.
        // Scenario: a composed split command accidentally includes both flags.
        let error = #expect(throws: CLIParseError.self) {
            try parseCLI(["pane", "split", "--pane", paneId, "-h", "--background", "--foreground"])
        }
        #expect(error?.message.contains("--background and --foreground are mutually exclusive") == true)
        #expect(error?.message.contains(paneSplitUsageWithFocusFlags) == true)
    }

    @Test("malformed explicit target syntax throws usage errors", arguments: [
        (["pane", "info", "--pane"], "usage: danterm pane info --pane <pane-id>"),
        (["tab", "new", "--group"], tabNewUsageWithPositionFlags),
        (["tab", "rename", "--tab"], "usage: danterm tab rename --tab <tab-id> <name>|--clear"),
        (["tab", "rename", "--tab", tabId, "--clear", "extra"], "usage: danterm tab rename --tab <tab-id> <name>|--clear"),
        (["tab", "close", "--tab"], "usage: danterm tab close --tab <tab-id>"),
        (["tab", "close", "bogus"], "usage: danterm tab close --tab <tab-id>"),
        (["tab", "close", "--nope"], "usage: danterm tab close --tab <tab-id>"),
        (["group", "rename", "--group"], groupRenameUsage),
        (["group", "rename", "--group", groupId], groupRenameUsage),
        (["group", "rename", groupId, "notes"], groupRenameUsage),
        (["group", "rename", "--group", groupId, "--clear"], "unknown flag: --clear"),
        (["group", "new"], groupNewUsage),
        (["group", "new", "--name"], groupNewUsage),
        (["group", "new", "--name", "Notes", "--group", groupId], "unknown flag: --group"),
        (["group", "new", "--name", "Notes", "--background", "--foreground"],
         "--background and --foreground are mutually exclusive\n\(groupNewUsage)"),
        (["group", "new", "Notes"], "unexpected argument: Notes"),
        (["group", "close"], groupCloseUsage),
        (["group", "close", "--group"], groupCloseUsage),
        (["group", "close", groupId], groupCloseUsage),
        (["group", "close", "--group", groupId, "extra"], "unexpected argument: extra"),
        (["group", "close", "--group", groupId, "--nope"], "unknown flag: --nope"),
        (["pane", "close", "--pane", paneId, "extra"], "unexpected argument: extra"),
        (["pane", "close", "--nope"], "unknown flag: --nope"),
        (["pane", "split", "--pane"], paneSplitUsageWithFocusFlags),
        (["pane", "input", "--pane"], "usage: danterm pane input --pane <pane-id> ..."),
        (["theme", "set", "--pane"], "usage: danterm theme set --pane <pane-id> <name>|--clear"),
        (["theme", "set", "--pane", paneId, "--clear", "extra"], "usage: danterm theme set --pane <pane-id> <name>|--clear"),
        (["todo", "list", "--pane"], "usage: danterm todo list (--pane <pane-id> | --tab <tab-id>)"),
        (["todo", "add", "--pane"], "usage: danterm todo add (--pane <pane-id> | --tab <tab-id>) <text>"),
    ] as [([String], String)])
    func malformedExplicitTargetSyntaxThrowsUsageErrors(_ testCase: ([String], String)) {
        let error = #expect(throws: CLIParseError.self) {
            try parseCLI(testCase.0)
        }
        #expect(error?.message == testCase.1)
    }
}

private let paneId = "11111111-1111-4111-8111-111111111111"
private let tabId = "22222222-2222-4222-8222-222222222222"
private let groupId = "33333333-3333-4333-8333-333333333333"
private let groupRenameUsage = "usage: danterm group rename --group <group-id> <name>"
private let groupNewUsage = "usage: danterm group new --name <name> [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground]"
private let groupCloseUsage = "usage: danterm group close --group <group-id> [--move-tabs]"
private let tabNewUsageWithPositionFlags = "usage: danterm tab new (--group <group-id> | --after-tab <tab-id>) [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground] [--after-selected | --at-group-end]"
private let paneSplitUsageWithFocusFlags = "usage: danterm pane split --pane <pane-id> -h|-v [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground]"
private let paneTapeUsage = "usage: danterm pane tape --pane <pane-id> [--follow] [--from-now | --from-cursor <cursor-json>] [--raw | --reconstructible] [--sync-history-bytes <n>] [--format replay|inspect]"

private let todoId = "44444444-4444-4444-8444-444444444444"

/// One row per command that names an entity, shared by the two target sweeps.
/// Both axes -- no target at all, and a target that is not an id -- read this
/// list, so a command can only be unchecked by being missing from it, which is
/// one visible line rather than a silence.
struct TargetingCommand: Sendable {
    let label: String
    /// pane, tab, or group -- the id helper that must refuse a malformed value.
    let entity: String
    /// What the usage line names when the target is absent. Defaults to the
    /// flag, which every targeting command but `pane focus` uses.
    let usageToken: String
    /// The full invocation. `nil` supplies no target at all.
    let args: @Sendable (String?) -> [String]

    init(
        _ label: String,
        entity: String,
        usageToken: String? = nil,
        args: @escaping @Sendable (String?) -> [String]
    ) {
        self.label = label
        self.entity = entity
        self.usageToken = usageToken ?? "--\(entity)"
        self.args = args
    }
}

private func paneFlag(_ target: String?) -> [String] {
    target.map { ["--pane", $0] } ?? []
}

private func tabFlag(_ target: String?) -> [String] {
    target.map { ["--tab", $0] } ?? []
}

private func groupFlag(_ target: String?) -> [String] {
    target.map { ["--group", $0] } ?? []
}

let targetingCommands: [TargetingCommand] = [
    .init("tab new", entity: "group", args: { ["tab", "new"] + groupFlag($0) }),
    .init("tab rename", entity: "tab", args: { ["tab", "rename"] + tabFlag($0) + ["work"] }),
    .init("tab close", entity: "tab", args: { ["tab", "close"] + tabFlag($0) }),
    .init("group rename", entity: "group", args: { ["group", "rename"] + groupFlag($0) + ["notes"] }),
    .init("group close", entity: "group", args: { ["group", "close"] + groupFlag($0) }),
    // `pane focus` is the one targeting command that takes its pane
    // positionally rather than behind --pane, so its usage line names the
    // placeholder instead. SKILL.md documents that form.
    .init("pane focus", entity: "pane", usageToken: "<pane-id>", args: { ["pane", "focus"] + ($0.map { [$0] } ?? []) }),
    .init("pane info", entity: "pane", args: { ["pane", "info"] + paneFlag($0) }),
    .init("pane split", entity: "pane", args: { ["pane", "split"] + paneFlag($0) + ["-h"] }),
    .init("pane close", entity: "pane", args: { ["pane", "close"] + paneFlag($0) }),
    .init("pane input", entity: "pane", args: { ["pane", "input"] + paneFlag($0) + ["--", "C-c"] }),
    .init("pane read", entity: "pane", args: { ["pane", "read"] + paneFlag($0) }),
    .init("pane rows", entity: "pane", args: { ["pane", "rows"] + paneFlag($0) }),
    .init("pane zoom", entity: "pane", args: { ["pane", "zoom"] + paneFlag($0) + ["on"] }),
    .init("pane resize", entity: "pane", args: { ["pane", "resize"] + paneFlag($0) + ["80x24"] }),
    .init("pane tape", entity: "pane", args: { ["pane", "tape"] + paneFlag($0) }),
    .init("pane snapshot", entity: "pane", args: { ["pane", "snapshot"] + paneFlag($0) }),
    .init("theme set", entity: "pane", args: { ["theme", "set"] + paneFlag($0) + ["TokyoNight"] }),
    .init("agent attach", entity: "pane", args: {
        ["agent", "attach"] + paneFlag($0) + ["--kind", "codex", "--id", "thread-1"]
    }),
    .init("agent activity", entity: "pane", args: {
        ["agent", "activity"] + paneFlag($0) + ["--kind", "codex", "--id", "thread-1", "--state", "working"]
    }),
    .init("agent detach", entity: "pane", args: {
        ["agent", "detach"] + paneFlag($0) + ["--kind", "codex", "--id", "thread-1"]
    }),
    .init("todo list", entity: "pane", args: { ["todo", "list"] + paneFlag($0) }),
    .init("todo add", entity: "pane", args: { ["todo", "add"] + paneFlag($0) + ["write", "test"] }),
    .init("todo edit", entity: "pane", args: { ["todo", "edit"] + paneFlag($0) + [todoId, "write", "test"] }),
    .init("todo done", entity: "pane", args: { ["todo", "done"] + paneFlag($0) + [todoId] }),
    .init("todo open", entity: "pane", args: { ["todo", "open"] + paneFlag($0) + [todoId] }),
    .init("todo delete", entity: "pane", args: { ["todo", "delete"] + paneFlag($0) + [todoId] }),
    .init("todo clear-completed", entity: "pane", args: { ["todo", "clear-completed"] + paneFlag($0) }),
]
