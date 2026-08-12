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
        #expect(throws: NewCommandParseError.conflictingFocusFlags) {
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

    @Test("missing pane value throws")
    func missingPaneValueThrows() {
        #expect(throws: NewCommandParseError.missingValue("--pane")) {
            try parsePaneSplitArgs(["--pane"])
        }
    }

    @Test("missing launch flag value throws")
    func missingLaunchFlagValueThrows() {
        #expect(throws: NewCommandParseError.missingValue("--cmd")) {
            try parsePaneSplitArgs(["-h", "--cmd"])
        }
    }

    @Test("no direction throws")
    func noDirectionThrows() {
        #expect(throws: NewCommandParseError.missingDirection) {
            try parsePaneSplitArgs([])
        }
    }

    @Test("unknown flag throws")
    func unknownFlagThrows() {
        #expect(throws: NewCommandParseError.unknownFlag("--bogus")) {
            try parsePaneSplitArgs(["--bogus"])
        }
    }

    @Test("trailing argument throws")
    func trailingArgumentThrows() {
        #expect(throws: NewCommandParseError.unexpectedArgument("extra")) {
            try parsePaneSplitArgs(["-h", "extra"])
        }
    }

    @Test("first bad token wins over a later conflict")
    func firstBadTokenWinsOverALaterConflict() {
        // Intent: parsing stops at the first token it cannot accept, and every
        //   in-loop error outranks the missing direction checked after the loop.
        // Why it exists: the focus conflict needs both flags and the direction
        //   check runs last, so a left-to-right parser must report the typo.
        // Scenario: a malformed split carries a typo and both focus flags, and
        //   never names a direction.
        #expect(throws: NewCommandParseError.unknownFlag("--bogus")) {
            try parsePaneSplitArgs(["--bogus", "--background", "--foreground"])
        }
    }

    @Test("conflicting focus flags throw in either order")
    func conflictingFocusFlagsThrowInEitherOrder() {
        #expect(throws: NewCommandParseError.conflictingFocusFlags) {
            try parsePaneSplitArgs(["-h", "--foreground", "--background"])
        }
    }

    @Test("repeating the same focus flag is accepted")
    func repeatingTheSameFocusFlagIsAccepted() throws {
        let parsed = try parsePaneSplitArgs(["-h", "--background", "--background"])
        #expect(parsed == ParsedPaneSplit(pane: nil, direction: .horizontal, background: true))
    }

    @Test("repeated value flags overwrite silently")
    func repeatedValueFlagsOverwriteSilently() throws {
        let parsed = try parsePaneSplitArgs(["--pane", "P1", "--pane", "P2", "-h", "--cmd", "one", "--cmd", "two"])
        #expect(parsed == ParsedPaneSplit(
            pane: "P2",
            direction: .horizontal,
            launch: LaunchSpec(cmd: "two", cwd: nil, title: nil)
        ))
    }

    @Test("empty cwd still produces a launch")
    func emptyCwdStillProducesALaunch() throws {
        // Intent: `--cwd ""` yields a launch holding an empty cwd.
        // Why it exists: `LaunchSpec.init` normalizes an empty cmd to nil but
        //   leaves cwd alone, which `emptyCommandIsOmittedFromLaunch` pins from
        //   the other side.
        // Scenario: a caller interpolates an empty variable into `--cwd`.
        let parsed = try parsePaneSplitArgs(["-v", "--cwd", ""])
        #expect(parsed == ParsedPaneSplit(
            pane: nil,
            direction: .vertical,
            launch: LaunchSpec(cmd: nil, cwd: "", title: nil)
        ))
    }

    @Test("repeated direction flag throws")
    func repeatedDirectionFlagThrows() {
        // Intent: a second direction flag is rejected, even when it repeats the
        //   first one.
        // Why it exists: direction is a single slot filled once. The error is
        //   `unexpectedArgument`, so the CLI names the offending token.
        // Scenario: a generated split appends `-h` to a command that has it.
        #expect(throws: NewCommandParseError.unexpectedArgument("-h")) {
            try parsePaneSplitArgs(["-h", "-h"])
        }
        #expect(throws: NewCommandParseError.unexpectedArgument("-v")) {
            try parsePaneSplitArgs(["-h", "-v"])
        }
    }
}
