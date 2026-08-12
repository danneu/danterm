// Tests for the public `danterm` command-line parser.
import Foundation
import Testing
@testable import DanTermProtocol

struct CLIParserTests {
    @Test("every targeting command requires an explicit target", arguments: [
        ["tab", "new"],
        ["tab", "rename", "work"],
        ["tab", "close"],
        ["group", "rename", "notes"],
        ["pane", "info"],
        ["pane", "split", "-h"],
        ["pane", "input", "--", "C-c"],
        ["pane", "zoom", "on"],
        ["theme", "set", "TokyoNight"],
        ["agent", "attach", "--kind", "codex", "--id", "thread-1"],
        ["agent", "activity", "--kind", "codex", "--id", "thread-1", "--state", "working"],
        ["agent", "detach", "--kind", "codex", "--id", "thread-1"],
        ["todo", "list"],
        ["todo", "add", "write", "test"],
        ["todo", "edit", "11111111-1111-4111-8111-111111111111", "write", "test"],
        ["todo", "done", "11111111-1111-4111-8111-111111111111"],
        ["todo", "open", "11111111-1111-4111-8111-111111111111"],
        ["todo", "delete", "11111111-1111-4111-8111-111111111111"],
        ["todo", "clear-completed"],
    ])
    func everyTargetingCommandRequiresAnExplicitTarget(_ args: [String]) {
        #expect(throws: CLIParseError.self) {
            _ = try parseCLI(args)
        }
    }

    @Test("malformed ids fail at parse time for every target kind", arguments: [
        ["pane", "focus", "not-a-pane"],
        ["tab", "close", "--tab", "not-a-tab"],
        ["tab", "new", "--group", "not-a-group"],
        ["group", "rename", "--group", "not-a-group", "notes"],
    ])
    func malformedTargetIdsFailAtParseTime(_ args: [String]) {
        #expect(throws: CLIParseError.self) {
            _ = try parseCLI(args)
        }
    }

    @Test("global socket target parses before the command")
    func globalSocketTargetParsesBeforeCommand() throws {
        let invocation = try parseCLIInvocation(["--socket", "/tmp/slot.sock", "ls"])

        #expect(invocation.socketPath == "/tmp/slot.sock")
        #expect(invocation.command == CLICommand(request: .ls, outputMode: .json))
    }

    @Test("invocation without a socket target preserves command parsing")
    func invocationWithoutSocketPreservesCommandParsing() throws {
        let invocation = try parseCLIInvocation(["ls"])
        let command = try parseCLI(["ls"])

        #expect(invocation.socketPath == nil)
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

        #expect(error?.message == "usage: danterm pane <focus|info|split|close|input|read|rows|zoom|tape>")
    }

    @Test("group command usage lists every supported subcommand")
    func groupCommandUsageListsEverySubcommand() {
        let error = #expect(throws: CLIParseError.self) {
            try parseCLI(["group"])
        }

        #expect(error?.message == "usage: danterm group <rename>")
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

    @Test("pane tape parses explicit pane as JSON output")
    func paneTapeParsesExplicitPaneAsJSONOutput() throws {
        let command = try parseCLI(["pane", "tape", "--pane", paneId])

        #expect(command.method == IpcRequestMethod.paneTape.rawValue)
        #expect(command.params == ["pane": .string(paneId)])
        #expect(command.outputMode == .json)
    }

    @Test("pane tape parses follow and from now")
    func paneTapeParsesFollowAndFromNow() throws {
        let follow = try parseCLI(["pane", "tape", "--pane", paneId, "--follow"])
        #expect(follow.params == [
            "pane": .string(paneId),
            "follow": .bool(true),
        ])

        let fromNow = try parseCLI([
            "pane", "tape", "--follow", "--from-now", "--pane", paneId,
        ])
        #expect(fromNow.params == [
            "pane": .string(paneId),
            "follow": .bool(true),
            "fromNow": .bool(true),
        ])
    }

    @Test("pane tape rejects missing and unexpected arguments", arguments: [
        (["pane", "tape"], "usage: danterm pane tape --pane <pane-id> [--follow] [--from-now]"),
        (["pane", "tape", "--follow"], "usage: danterm pane tape --pane <pane-id> [--follow] [--from-now]"),
        (["pane", "tape", "--pane"], "usage: danterm pane tape --pane <pane-id> [--follow] [--from-now]"),
        (["pane", "tape", "--pane", paneId, "--from-now"], "--from-now requires --follow\nusage: danterm pane tape --pane <pane-id> [--follow] [--from-now]"),
        (["pane", "tape", "--pane", paneId, "extra"], "unexpected argument: extra"),
        (["pane", "tape", "--bogus"], "unknown flag: --bogus"),
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
        //   inputEventToJSON; without asserting the payload, a bad `.letter` arm or a
        //   mis-wired call ships silently (the round-trip and classifier tests miss it).
        // Scenario: spec-first contract for the pane.input params["input"] array.
        let cmd = try parseCLI(["pane", "input", "--pane", paneId, "--", "BSpace", "F12", "C-c", "S-Tab"])
        #expect(cmd.params["input"] == .array([
            .object(["key": .string("BSpace")]),
            .object(["key": .string("F12")]),
            .object(["key": .string("c"), "mods": .array([.string("ctrl")])]),
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

    @Test("removed legacy commands are unknown", arguments: ["new-tab", "send-keys", "read-pane"])
    func removedLegacyCommandsAreUnknown(_ command: String) {
        let error = #expect(throws: CLIParseError.self) {
            try parseCLI([command])
        }
        #expect(error?.message == "unknown command: \(command)")
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
private let tabNewUsageWithPositionFlags = "usage: danterm tab new (--group <group-id> | --after-tab <tab-id>) [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground] [--after-selected | --at-group-end]"
private let paneSplitUsageWithFocusFlags = "usage: danterm pane split --pane <pane-id> -h|-v [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground]"
