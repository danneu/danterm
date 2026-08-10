// Tests for the CLI argument parser shared with `danterm pane split`.
import Foundation
import Testing
@testable import DanTermProtocol

struct PaneSplitArgsTests {
    @Test("horizontal direction parses")
    func horizontalDirectionParses() throws {
        let parsed = try parsePaneSplitArgs(["-h"])
        #expect(parsed == ParsedPaneSplit(pane: nil, direction: .horizontal))
    }

    @Test("vertical direction parses")
    func verticalDirectionParses() throws {
        let parsed = try parsePaneSplitArgs(["-v"])
        #expect(parsed == ParsedPaneSplit(pane: nil, direction: .vertical))
    }

    @Test("explicit pane parses")
    func explicitPaneParses() throws {
        let parsed = try parsePaneSplitArgs(["--pane", "P1", "-h"])
        #expect(parsed == ParsedPaneSplit(pane: "P1", direction: .horizontal))
    }

    @Test("background flag parses")
    func backgroundFlagParses() throws {
        // Intent: `--background` records only the background flag.
        // Why it exists: preserves back-compat for existing split recipes while
        //   the CLI layer flips the default to background.
        // Scenario: an existing agent recipe still includes `--background`.
        let parsed = try parsePaneSplitArgs(["-h", "--background"])
        #expect(parsed == ParsedPaneSplit(pane: nil, direction: .horizontal, background: true, foreground: false))
    }

    @Test("foreground flag parses")
    func foregroundFlagParses() throws {
        // Intent: `--foreground` records a request to focus the new split pane
        //   within its tab.
        // Why it exists: keeps focus policy explicit without making the arg
        //   parser infer command defaults.
        // Scenario: the user asks an agent to split and focus the new pane.
        let parsed = try parsePaneSplitArgs(["-h", "--foreground"])
        #expect(parsed == ParsedPaneSplit(pane: nil, direction: .horizontal, background: false, foreground: true))
    }

    @Test("launch flags parse")
    func launchFlagsParse() throws {
        let parsed = try parsePaneSplitArgs(["-h", "--cmd", "vim foo", "--cwd", "/tmp", "--title", "edit"])
        #expect(parsed == ParsedPaneSplit(
                pane: nil,
                direction: .horizontal,
                launch: LaunchSpec(cmd: "vim foo", cwd: "/tmp", title: "edit")
            ))
    }

    @Test("background combines with other flags")
    func backgroundCombinesWithOtherFlags() throws {
        let parsed = try parsePaneSplitArgs([
            "--pane", "P1", "-h", "--background",
            "--cmd", "just test", "--cwd", "/tmp", "--title", "tests",
        ])
        #expect(parsed == ParsedPaneSplit(
                pane: "P1",
                direction: .horizontal,
                launch: LaunchSpec(cmd: "just test", cwd: "/tmp", title: "tests"),
                background: true,
                foreground: false
            ))
    }

    @Test("conflicting focus flags throw")
    func conflictingFocusFlagsThrow() {
        // Intent: `--background --foreground` is rejected for pane splits.
        // Why it exists: prevents ambiguous focus policy before the command is
        //   serialized for IPC.
        // Scenario: a composed split command accidentally includes both flags.
        #expect(throws: PaneSplitParseError.conflictingFocusFlags) {
            try parsePaneSplitArgs(["-h", "--background", "--foreground"])
        }
    }

    @Test("empty command is omitted from launch")
    func emptyCommandIsOmittedFromLaunch() throws {
        let parsed = try parsePaneSplitArgs(["-v", "--cmd", "", "--cwd", "/tmp"])
        #expect(parsed == ParsedPaneSplit(
                pane: nil,
                direction: .vertical,
                launch: LaunchSpec(cmd: nil, cwd: "/tmp", title: nil)
            ))
    }

    @Test("missing pane arg throws")
    func missingPaneArgThrows() {
        #expect(throws: PaneSplitParseError.missingPaneArg) {
            try parsePaneSplitArgs(["--pane"])
        }
    }

    @Test("missing launch flag value throws")
    func missingLaunchFlagValueThrows() {
        #expect(throws: PaneSplitParseError.missingValue("--cmd")) {
            try parsePaneSplitArgs(["-h", "--cmd"])
        }
    }

    @Test("no direction throws")
    func noDirectionThrows() {
        #expect(throws: PaneSplitParseError.missingDirection) {
            try parsePaneSplitArgs([])
        }
    }

    @Test("unknown flag throws")
    func unknownFlagThrows() {
        #expect(throws: PaneSplitParseError.unknownFlag("--bogus")) {
            try parsePaneSplitArgs(["--bogus"])
        }
    }

    @Test("trailing argument throws")
    func trailingArgumentThrows() {
        #expect(throws: PaneSplitParseError.unexpectedArgument("extra")) {
            try parsePaneSplitArgs(["-h", "extra"])
        }
    }
}
