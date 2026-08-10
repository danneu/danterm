// Tests for the CLI argument parser shared with `danterm tab new`.
import Foundation
import Testing
@testable import DanTermProtocol

struct TabNewArgsTests {
    @Test("empty args parses default tab")
    func emptyArgsParsesDefaultTab() throws {
        #expect(try parseTabNewArgs([]) == ParsedTabNew(group: nil, launch: nil))
    }

    @Test("group parses")
    func groupParses() throws {
        #expect(try parseTabNewArgs(["--group", "G1"]) == ParsedTabNew(group: "G1", launch: nil))
    }

    @Test("background flag parses")
    func backgroundFlagParses() throws {
        // Intent: `--background` records only the background flag.
        // Why it exists: preserves back-compat for scripts that already pass the
        //   now-redundant explicit background request.
        // Scenario: an existing agent recipe still includes `--background`;
        //   parsing must keep accepting it without implying foreground.
        #expect(try parseTabNewArgs(["--background"]) == ParsedTabNew(group: nil, launch: nil, background: true, foreground: false))
    }

    @Test("foreground flag parses")
    func foregroundFlagParses() throws {
        // Intent: `--foreground` records a request to focus/select the new tab.
        // Why it exists: keeps the arg parser as a faithful flag-presence layer
        //   before CLI policy maps absent focus flags to background execution.
        // Scenario: the user explicitly asks an agent to switch to the new tab.
        #expect(try parseTabNewArgs(["--foreground"]) == ParsedTabNew(group: nil, launch: nil, background: false, foreground: true))
    }

    @Test("launch flags parse individually")
    func launchFlagsParseIndividually() throws {
        #expect(try parseTabNewArgs(["--cmd", "date"]) == ParsedTabNew(group: nil, launch: LaunchSpec(cmd: "date", cwd: nil, title: nil)))
        #expect(try parseTabNewArgs(["--cwd", "/tmp"]) == ParsedTabNew(group: nil, launch: LaunchSpec(cmd: nil, cwd: "/tmp", title: nil)))
        #expect(try parseTabNewArgs(["--title", "logs"]) == ParsedTabNew(group: nil, launch: LaunchSpec(cmd: nil, cwd: nil, title: "logs")))
    }

    @Test("combination parses")
    func combinationParses() throws {
        #expect(try parseTabNewArgs(["--group", "G1", "--cmd", "make test", "--cwd", "/repo", "--title", "tests"]) == ParsedTabNew(group: "G1", launch: LaunchSpec(cmd: "make test", cwd: "/repo", title: "tests")))
    }

    @Test("background combines with other flags")
    func backgroundCombinesWithOtherFlags() throws {
        #expect(try parseTabNewArgs(["--group", "G1", "--background", "--cmd", "date"]) == ParsedTabNew(
                group: "G1",
                launch: LaunchSpec(cmd: "date", cwd: nil, title: nil),
                background: true,
                foreground: false
            ))
    }

    @Test("conflicting focus flags throw")
    func conflictingFocusFlagsThrow() {
        // Intent: `--background --foreground` is rejected instead of letting the
        //   last parsed flag win.
        // Why it exists: prevents ambiguous focus policy on the agent-facing CLI.
        // Scenario: a composed command accidentally includes both focus flags.
        #expect(throws: TabNewParseError.conflictingFocusFlags) {
            try parseTabNewArgs(["--background", "--foreground"])
        }
    }

    @Test("missing value throws")
    func missingValueThrows() {
        #expect(throws: TabNewParseError.missingValue("--title")) {
            try parseTabNewArgs(["--title"])
        }
    }

    @Test("unknown flag throws")
    func unknownFlagThrows() {
        #expect(throws: TabNewParseError.unknownFlag("--bogus")) {
            try parseTabNewArgs(["--bogus"])
        }
    }
}
