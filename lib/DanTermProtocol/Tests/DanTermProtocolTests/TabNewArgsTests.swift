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
        #expect(throws: NewCommandParseError.conflictingFocusFlags) {
            try parseTabNewArgs(["--background", "--foreground"])
        }
    }

    @Test("missing value throws")
    func missingValueThrows() {
        #expect(throws: NewCommandParseError.missingValue("--title")) {
            try parseTabNewArgs(["--title"])
        }
    }

    @Test("unknown flag throws")
    func unknownFlagThrows() {
        #expect(throws: NewCommandParseError.unknownFlag("--bogus")) {
            try parseTabNewArgs(["--bogus"])
        }
    }

    @Test("split direction flags are unknown to tab new")
    func splitDirectionFlagsAreUnknownToTabNew() {
        // Intent: `-h` and `-v` belong to `pane split` only.
        // Why it exists: the three creation commands share a flag grammar, and
        //   this pins which flags stay outside it.
        // Scenario: a caller copies a `pane split` invocation into `tab new`.
        #expect(throws: NewCommandParseError.unknownFlag("-h")) {
            try parseTabNewArgs(["-h"])
        }
        #expect(throws: NewCommandParseError.unknownFlag("-v")) {
            try parseTabNewArgs(["-v"])
        }
    }

    @Test("bare argument throws")
    func bareArgumentThrows() {
        #expect(throws: NewCommandParseError.unexpectedArgument("Notes")) {
            try parseTabNewArgs(["Notes"])
        }
    }

    @Test("first bad token wins over a later conflict")
    func firstBadTokenWinsOverALaterConflict() {
        // Intent: parsing stops at the first token it cannot accept.
        // Why it exists: the focus conflict is only detected once both flags are
        //   read, so a left-to-right parser must report the earlier problem.
        // Scenario: a malformed command carries both a typo and both focus flags.
        #expect(throws: NewCommandParseError.unknownFlag("--bogus")) {
            try parseTabNewArgs(["--bogus", "--background", "--foreground"])
        }
    }

    @Test("conflicting focus flags throw in either order")
    func conflictingFocusFlagsThrowInEitherOrder() {
        #expect(throws: NewCommandParseError.conflictingFocusFlags) {
            try parseTabNewArgs(["--foreground", "--background"])
        }
    }

    @Test("repeating the same focus flag is accepted")
    func repeatingTheSameFocusFlagIsAccepted() throws {
        // Intent: `--background --background` parses, unlike the position flags,
        //   which conflict with themselves.
        // Why it exists: the two flag families guard differently on purpose, and
        //   a shared parser must not level them.
        // Scenario: a generated command appends a focus flag that is already there.
        #expect(try parseTabNewArgs(["--background", "--background"]) == ParsedTabNew(group: nil, launch: nil, background: true))
        #expect(try parseTabNewArgs(["--foreground", "--foreground"]) == ParsedTabNew(group: nil, launch: nil, foreground: true))
    }

    @Test("repeated value flags overwrite silently")
    func repeatedValueFlagsOverwriteSilently() throws {
        #expect(try parseTabNewArgs(["--group", "G1", "--group", "G2", "--cmd", "one", "--cmd", "two"]) == ParsedTabNew(
            group: "G2",
            launch: LaunchSpec(cmd: "two", cwd: nil, title: nil)
        ))
    }

    @Test("empty command alone leaves no launch")
    func emptyCommandAloneLeavesNoLaunch() throws {
        // Intent: `--cmd ""` yields no launch, while `--cwd ""` still yields one.
        // Why it exists: `LaunchSpec.init` normalizes an empty cmd to nil but
        //   leaves cwd and title alone, so `isEmpty` treats the two differently.
        // Scenario: a caller interpolates an empty variable into the flag value.
        #expect(try parseTabNewArgs(["--cmd", ""]) == ParsedTabNew(group: nil, launch: nil))
        #expect(try parseTabNewArgs(["--cwd", ""]) == ParsedTabNew(group: nil, launch: LaunchSpec(cmd: nil, cwd: "", title: nil)))
    }

    @Test("position flags parse")
    func positionFlagsParse() throws {
        #expect(try parseTabNewArgs(["--after-selected"]) == ParsedTabNew(group: nil, launch: nil, position: .afterSelected))
        #expect(try parseTabNewArgs(["--at-group-end"]) == ParsedTabNew(group: nil, launch: nil, position: .atGroupEnd))
        #expect(try parseTabNewArgs(["--after-tab", "T7"]) == ParsedTabNew(group: nil, launch: nil, position: .afterTab("T7")))
    }

    @Test("position flags conflict, including with themselves")
    func positionFlagsConflictIncludingWithThemselves() {
        // Intent: a second position flag always conflicts, even when it repeats
        //   the first one.
        // Why it exists: position is a single slot filled once, unlike the focus
        //   flags, which tolerate repetition. The asymmetry is intentional.
        // Scenario: a command asks for two placements for one new tab.
        #expect(throws: NewCommandParseError.conflictingPositionFlags) {
            try parseTabNewArgs(["--after-selected", "--at-group-end"])
        }
        #expect(throws: NewCommandParseError.conflictingPositionFlags) {
            try parseTabNewArgs(["--at-group-end", "--at-group-end"])
        }
        #expect(throws: NewCommandParseError.conflictingPositionFlags) {
            try parseTabNewArgs(["--after-tab", "T1", "--after-tab", "T2"])
        }
    }

    @Test("after-tab reads its value before the position conflict")
    func afterTabReadsItsValueBeforeThePositionConflict() {
        // Intent: a trailing `--after-tab` with no value reports the missing
        //   value, not the position conflict it would also cause.
        // Why it exists: the value is read first on purpose, so the message names
        //   the token the user must fix.
        // Scenario: a command sets a position and then appends a bare
        //   `--after-tab` whose id was dropped.
        #expect(throws: NewCommandParseError.missingValue("--after-tab")) {
            try parseTabNewArgs(["--after-selected", "--after-tab"])
        }
    }
}
