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

    func testImplicitHumanMutationFormsStillParseWithoutExplicitTargets() throws {
        XCTAssertEqual(try parseCLI(["tab", "new"]).params["group"], nil)
        XCTAssertEqual(try parseCLI(["tab", "new"]).params["background"], nil)
        XCTAssertEqual(try parseCLI(["tab", "rename", "work"]).params["tab"], nil)
        XCTAssertEqual(try parseCLI(["tab", "rename", "--clear"]).params["tab"], nil)
        XCTAssertEqual(try parseCLI(["pane", "split", "-h"]).params["pane"], nil)
        XCTAssertEqual(try parseCLI(["pane", "split", "-h"]).params["background"], nil)
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
            (["tab", "new", "--group"], "usage: danterm tab new [--group <group-id>] [--cmd <s>] [--cwd <p>] [--title <s>] [--background]"),
            (["tab", "rename", "--tab"], "usage: danterm tab rename [--tab <tab-id>] <name>|--clear"),
            (["tab", "rename", "--tab", "T1", "--clear", "extra"], "usage: danterm tab rename [--tab <tab-id>] --clear"),
            (["pane", "split", "--pane"], "usage: danterm pane split [--pane <pane-id>] -h|-v [--cmd <s>] [--cwd <p>] [--title <s>] [--background]"),
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
