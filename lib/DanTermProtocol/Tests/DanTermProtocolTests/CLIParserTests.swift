// Tests for the public `danterm` command-line parser.
import Foundation
import XCTest
@testable import DanTermProtocol

final class CLIParserTests: XCTestCase {
    func testTabNewParsesLaunchFlags() throws {
        let command = try parseCLI(["tab", "new", "--cmd", "foo", "--cwd", "/x", "--title", "t"])
        XCTAssertEqual(command.method, Methods.tabNew)
        XCTAssertEqual(command.outputMode, .json)
        XCTAssertEqual(command.params["launch"], .object([
            "cmd": .string("foo"),
            "cwd": .string("/x"),
            "title": .string("t"),
        ]))
    }

    func testTabNewParsesBackgroundFlag() throws {
        let command = try parseCLI(["tab", "new", "--background"])
        XCTAssertEqual(command.method, Methods.tabNew)
        XCTAssertEqual(command.outputMode, .json)
        XCTAssertEqual(command.params["background"], .bool(true))
    }

    func testTabNewParsesPositionFlags() throws {
        let afterSelected = try parseCLI(["tab", "new", "--after-selected"])
        XCTAssertEqual(afterSelected.params["position"], .string("afterSelected"))
        XCTAssertEqual(afterSelected.params["afterTabId"], nil)

        let atGroupEnd = try parseCLI(["tab", "new", "--at-group-end"])
        XCTAssertEqual(atGroupEnd.params["position"], .string("atGroupEnd"))
        XCTAssertEqual(atGroupEnd.params["afterTabId"], nil)

        let tabId = "85AA4B6B-41B2-4D67-A9C8-F0C25B2E2BEA"
        let afterTab = try parseCLI(["tab", "new", "--after-tab", tabId])
        XCTAssertEqual(afterTab.params["position"], .string("afterTab"))
        XCTAssertEqual(afterTab.params["afterTabId"], .string(tabId))
    }

    func testTabNewWithoutPositionFlagDefaultsToGroupEndInBackground() throws {
        // Intent: bare `tab new` emits deterministic, background CLI policy.
        // Why it exists: agents should not insert relative to live focus or steal
        //   focus when they forget optional flags.
        // Scenario: an agent opens a tab with no position or focus flags.
        let command = try parseCLI(["tab", "new"])
        XCTAssertEqual(command.params["position"], .string("atGroupEnd"))
        XCTAssertEqual(command.params["afterTabId"], nil)
        XCTAssertEqual(command.params["background"], .bool(true))
    }

    func testTabNewConflictingPositionFlagsThrowUsageError() {
        XCTAssertThrowsError(try parseCLI(["tab", "new", "--after-selected", "--at-group-end"])) { err in
            let message = (err as? CLIParseError)?.message
            XCTAssertTrue(message?.contains("mutually exclusive") == true)
            XCTAssertTrue(message?.contains(tabNewUsageWithPositionFlags) == true)
        }
    }

    func testTabNewMissingAfterTabValueThrowsUpdatedUsageError() {
        XCTAssertThrowsError(try parseCLI(["tab", "new", "--after-tab"])) { err in
            let message = (err as? CLIParseError)?.message
            XCTAssertTrue(message?.hasPrefix("usage: danterm tab new") == true)
            XCTAssertTrue(message?.contains("--after-tab") == true)
        }
    }

    func testPaneInfoParsesExplicitAndImplicitForms() throws {
        let explicit = try parseCLI(["pane", "info", "--pane", "P1"])
        XCTAssertEqual(explicit.method, Methods.paneInfo)
        XCTAssertEqual(explicit.outputMode, .json)
        XCTAssertEqual(explicit.params["pane"], .string("P1"))

        let implicit = try parseCLI(["pane", "info"])
        XCTAssertEqual(implicit.method, Methods.paneInfo)
        XCTAssertEqual(implicit.outputMode, .json)
        XCTAssertEqual(implicit.params["pane"], nil)
    }

    func testAgentAttachParsesToSilentMutation() throws {
        let command = try parseCLI(["agent", "attach", "--kind", "claude", "--id", "4f3a2b1c"])

        XCTAssertEqual(command.method, Methods.agentAttach)
        XCTAssertEqual(command.outputMode, .none)
        XCTAssertEqual(command.params["kind"], .string("claude"))
        XCTAssertEqual(command.params["id"], .string("4f3a2b1c"))
    }

    func testAgentAttachMissingFlagsThrowUsage() {
        for args in [
            ["agent", "attach", "--kind", "claude"],
            ["agent", "attach", "--id", "4f3a2b1c"],
            ["agent", "attach", "--kind"],
            ["agent", "attach", "--id"],
        ] {
            XCTAssertThrowsError(try parseCLI(args)) { err in
                XCTAssertEqual((err as? CLIParseError)?.message, "usage: danterm agent attach --kind <kind> --id <session-id>")
            }
        }
    }

    func testExplicitTargetFlagsParse() throws {
        let newTab = try parseCLI(["tab", "new", "--group", "G1"])
        XCTAssertEqual(newTab.method, Methods.tabNew)
        XCTAssertEqual(newTab.params["group"], .string("G1"))

        let rename = try parseCLI(["tab", "rename", "--tab", "T1", "work"])
        XCTAssertEqual(rename.method, Methods.tabRename)
        XCTAssertEqual(rename.params["tab"], .string("T1"))
        XCTAssertEqual(rename.params["title"], .string("work"))

        let clear = try parseCLI(["tab", "rename", "--tab", "T1", "--clear"])
        XCTAssertEqual(clear.method, Methods.tabRename)
        XCTAssertEqual(clear.params["tab"], .string("T1"))
        XCTAssertEqual(clear.params["title"], .null)

        let theme = try parseCLI(["theme", "set", "--pane", "P1", "TokyoNight"])
        XCTAssertEqual(theme.method, Methods.themeSet)
        XCTAssertEqual(theme.params["pane"], .string("P1"))
        XCTAssertEqual(theme.params["themeName"], .string("TokyoNight"))

        let themeClear = try parseCLI(["theme", "set", "--pane", "P1", "--clear"])
        XCTAssertEqual(themeClear.method, Methods.themeSet)
        XCTAssertEqual(themeClear.params["pane"], .string("P1"))
        XCTAssertEqual(themeClear.params["themeName"], .null)
    }

    func testTabRenameParsesStringAndClear() throws {
        let rename = try parseCLI(["tab", "rename", "work", "logs"])
        XCTAssertEqual(rename.method, Methods.tabRename)
        XCTAssertEqual(rename.params["title"], .string("work logs"))
        XCTAssertEqual(rename.outputMode, .none)

        let clear = try parseCLI(["tab", "rename", "--clear"])
        XCTAssertEqual(clear.method, Methods.tabRename)
        XCTAssertEqual(clear.params["title"], .null)
    }

    func testTabCloseParsesExplicitTab() throws {
        let command = try parseCLI(["tab", "close", "--tab", "T1"])
        XCTAssertEqual(command.method, Methods.tabClose)
        XCTAssertEqual(command.params["tab"], .string("T1"))
        XCTAssertEqual(command.outputMode, .none)
    }

    func testTabCloseWithoutTabHasNoTabParam() throws {
        let command = try parseCLI(["tab", "close"])
        XCTAssertEqual(command.method, Methods.tabClose)
        XCTAssertEqual(command.params["tab"], nil)
        XCTAssertEqual(command.outputMode, .none)
    }

    func testImplicitHumanMutationFormsStillParseWithoutExplicitTargets() throws {
        // Intent: implicit target commands still parse while tab/split defaults
        //   are made agent-safe.
        // Why it exists: the CLI contract still allows context-derived targets,
        //   but no longer leaves tab creation or pane splitting foregrounded.
        // Scenario: command parsing before IPC context is attached.
        XCTAssertEqual(try parseCLI(["tab", "new"]).params["group"], nil)
        XCTAssertEqual(try parseCLI(["tab", "new"]).params["background"], .bool(true))
        XCTAssertEqual(try parseCLI(["tab", "rename", "work"]).params["tab"], nil)
        XCTAssertEqual(try parseCLI(["tab", "rename", "--clear"]).params["tab"], nil)
        XCTAssertEqual(try parseCLI(["pane", "split", "-h"]).params["pane"], nil)
        XCTAssertEqual(try parseCLI(["pane", "split", "-h"]).params["background"], .bool(true))
        XCTAssertEqual(try parseCLI(["pane", "input", "--", "ls"]).params["pane"], nil)
        XCTAssertEqual(try parseCLI(["theme", "set", "TokyoNight"]).params["pane"], nil)
        XCTAssertEqual(try parseCLI(["theme", "set", "--clear"]).params["pane"], nil)
        XCTAssertEqual(try parseCLI(["todo", "list"]).params["pane"], nil)
    }

    func testTodoExplicitPaneFormsParse() throws {
        let list = try parseCLI(["todo", "list", "--pane", "P1"])
        XCTAssertEqual(list.method, Methods.todoList)
        XCTAssertEqual(list.outputMode, .json)
        XCTAssertEqual(list.params["pane"], .string("P1"))

        let add = try parseCLI(["todo", "add", "--pane", "P1", "write", "test"])
        XCTAssertEqual(add.method, Methods.todoAdd)
        XCTAssertEqual(add.outputMode, .json)
        XCTAssertEqual(add.params["pane"], .string("P1"))
        XCTAssertEqual(add.params["text"], .string("write test"))

        let edit = try parseCLI(["todo", "edit", "--pane", "P1", "TODO1", "write", "test"])
        XCTAssertEqual(edit.method, Methods.todoEdit)
        XCTAssertEqual(edit.params["pane"], .string("P1"))
        XCTAssertEqual(edit.params["todoId"], .string("TODO1"))
        XCTAssertEqual(edit.params["text"], .string("write test"))

        for (subcommand, method) in [
            ("done", Methods.todoDone),
            ("open", Methods.todoOpen),
            ("delete", Methods.todoDelete),
        ] {
            let command = try parseCLI(["todo", subcommand, "--pane", "P1", "TODO1"])
            XCTAssertEqual(command.method, method)
            XCTAssertEqual(command.params["pane"], .string("P1"))
            XCTAssertEqual(command.params["todoId"], .string("TODO1"))
        }

        let clear = try parseCLI(["todo", "clear-completed", "--pane", "P1"])
        XCTAssertEqual(clear.method, Methods.todoClearCompleted)
        XCTAssertEqual(clear.params["pane"], .string("P1"))
    }

    func testPaneInputReadAndSplitParse() throws {
        let input = try parseCLI(["pane", "input", "--pane", "P1", "--", "ls", "Enter"])
        XCTAssertEqual(input.method, Methods.paneInput)
        XCTAssertEqual(input.params["pane"], .string("P1"))
        XCTAssertEqual(input.outputMode, .none)

        let read = try parseCLI(["pane", "read", "--pane", "P1", "--lines", "20"])
        XCTAssertEqual(read.method, Methods.paneRead)
        XCTAssertEqual(read.params["lines"], .number(20))
        XCTAssertEqual(read.outputMode, .text)

        let split = try parseCLI(["pane", "split", "--pane", "P1", "-v", "--cmd", "top", "--title", "monitor"])
        XCTAssertEqual(split.method, Methods.paneSplit)
        XCTAssertEqual(split.outputMode, .json)
        XCTAssertEqual(split.params["pane"], .string("P1"))
        XCTAssertEqual(split.params["direction"], .string("vertical"))
        XCTAssertEqual(split.params["launch"], .object([
            "cmd": .string("top"),
            "title": .string("monitor"),
        ]))
    }

    func testPaneSplitParsesBackgroundFlag() throws {
        let command = try parseCLI(["pane", "split", "-h", "--background"])
        XCTAssertEqual(command.method, Methods.paneSplit)
        XCTAssertEqual(command.outputMode, .json)
        XCTAssertEqual(command.params["direction"], .string("horizontal"))
        XCTAssertEqual(command.params["background"], .bool(true))
    }

    func testTabNewAfterSelectedDefaultsToBackground() throws {
        // Intent: explicit position choices do not opt into foreground focus.
        // Why it exists: focus policy is independent from tab-placement policy.
        // Scenario: an agent intentionally anchors after the selected tab but
        //   still expects the new tab to open in the background.
        let command = try parseCLI(["tab", "new", "--after-selected"])
        XCTAssertEqual(command.params["position"], .string("afterSelected"))
        XCTAssertEqual(command.params["background"], .bool(true))
    }

    func testTabNewForegroundDisablesBackgroundAtGroupEnd() throws {
        // Intent: `--foreground` is the explicit inverse of the new background
        //   default for tab creation.
        // Why it exists: switching to a new tab remains possible when the user
        //   asks for it, while placement stays deterministic by default.
        // Scenario: the user asks the agent to open a tab and switch to it.
        let command = try parseCLI(["tab", "new", "--foreground"])
        XCTAssertEqual(command.params["position"], .string("atGroupEnd"))
        XCTAssertEqual(command.params["background"], .bool(false))
    }

    func testTabNewAtGroupEndExplicitFormMatchesDefault() throws {
        // Intent: the explicit at-group-end flag still serializes the same
        //   placement as the new default.
        // Why it exists: existing commands that already chose deterministic
        //   placement should keep their wire shape.
        // Scenario: an agent keeps passing `--at-group-end` after the default
        //   changes to that same policy.
        let command = try parseCLI(["tab", "new", "--at-group-end"])
        XCTAssertEqual(command.params["position"], .string("atGroupEnd"))
        XCTAssertEqual(command.params["background"], .bool(true))
    }

    func testTabNewConflictingFocusFlagsThrowUsageError() {
        // Intent: ambiguous tab focus flags produce a usage error.
        // Why it exists: command composition should fail loudly instead of
        //   silently choosing background or foreground.
        // Scenario: a recipe leaves legacy `--background` while adding
        //   `--foreground` for a user-requested switch.
        XCTAssertThrowsError(try parseCLI(["tab", "new", "--background", "--foreground"])) { err in
            let message = (err as? CLIParseError)?.message
            XCTAssertTrue(message?.contains("--background and --foreground are mutually exclusive") == true)
            XCTAssertTrue(message?.contains(tabNewUsageWithPositionFlags) == true)
        }
    }

    func testPaneSplitDefaultsToBackground() throws {
        // Intent: pane split defaults to leaving the caller's pane focused.
        // Why it exists: autonomous splits should not steal focus when the
        //   agent omits optional focus flags.
        // Scenario: an agent splits a known pane horizontally.
        let command = try parseCLI(["pane", "split", "-h"])
        XCTAssertEqual(command.params["direction"], .string("horizontal"))
        XCTAssertEqual(command.params["background"], .bool(true))
    }

    func testPaneSplitForegroundDisablesBackground() throws {
        // Intent: `pane split --foreground` asks the app to focus the new pane
        //   within the target tab.
        // Why it exists: foreground split remains available without changing
        //   selected-tab navigation semantics.
        // Scenario: the user asks the agent to split and focus the new pane.
        let command = try parseCLI(["pane", "split", "-h", "--foreground"])
        XCTAssertEqual(command.params["direction"], .string("horizontal"))
        XCTAssertEqual(command.params["background"], .bool(false))
    }

    func testPaneSplitConflictingFocusFlagsThrowUsageError() {
        // Intent: ambiguous pane-split focus flags produce a usage error.
        // Why it exists: focus policy should be explicit when both inverse flags
        //   appear in one command.
        // Scenario: a composed split command accidentally includes both flags.
        XCTAssertThrowsError(try parseCLI(["pane", "split", "-h", "--background", "--foreground"])) { err in
            let message = (err as? CLIParseError)?.message
            XCTAssertTrue(message?.contains("--background and --foreground are mutually exclusive") == true)
            XCTAssertTrue(message?.contains(paneSplitUsageWithFocusFlags) == true)
        }
    }

    func testRemovedLegacyCommandsAreUnknown() {
        for command in ["new-tab", "send-keys", "read-pane"] {
            XCTAssertThrowsError(try parseCLI([command])) { err in
                XCTAssertEqual((err as? CLIParseError)?.message, "unknown command: \(command)")
            }
        }
    }

    func testMalformedExplicitTargetSyntaxThrowsUsageErrors() {
        let cases: [([String], String)] = [
            (["pane", "info", "--pane"], "usage: danterm pane info [--pane <pane-id>]"),
            (["tab", "new", "--group"], tabNewUsageWithPositionFlags),
            (["tab", "rename", "--tab"], "usage: danterm tab rename [--tab <tab-id>] <name>|--clear"),
            (["tab", "rename", "--tab", "T1", "--clear", "extra"], "usage: danterm tab rename [--tab <tab-id>] --clear"),
            (["tab", "close", "--tab"], "usage: danterm tab close [--tab <tab-id>]"),
            (["tab", "close", "bogus"], "unexpected argument: bogus"),
            (["tab", "close", "--nope"], "unknown flag: --nope"),
            (["pane", "split", "--pane"], paneSplitUsageWithFocusFlags),
            (["pane", "input", "--pane"], "usage: danterm pane input --pane <pane-id> ..."),
            (["theme", "set", "--pane"], "usage: danterm theme set [--pane <pane-id>] <name>|--clear"),
            (["theme", "set", "--pane", "P1", "--clear", "extra"], "usage: danterm theme set [--pane <pane-id>] --clear"),
            (["todo", "list", "--pane"], "usage: danterm todo list [--pane <pane-id>]"),
            (["todo", "add", "--pane"], "usage: danterm todo add [--pane <pane-id>] <text>"),
        ]

        for (args, message) in cases {
            XCTAssertThrowsError(try parseCLI(args)) { err in
                XCTAssertEqual((err as? CLIParseError)?.message, message)
            }
        }
    }
}

private let tabNewUsageWithPositionFlags = "usage: danterm tab new [--group <group-id>] [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground] [--after-selected | --at-group-end | --after-tab <tab-id>]"
private let paneSplitUsageWithFocusFlags = "usage: danterm pane split [--pane <pane-id>] -h|-v [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground]"
