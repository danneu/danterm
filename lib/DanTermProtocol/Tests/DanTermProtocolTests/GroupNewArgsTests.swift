// Tests for the CLI argument parser behind `danterm group new`.
import Foundation
import Testing
@testable import DanTermProtocol

struct GroupNewArgsTests {
    @Test("empty args parses empty group")
    func emptyArgsParsesEmptyGroup() throws {
        #expect(try parseGroupNewArgs([]) == ParsedGroupNew(name: nil, launch: nil))
    }

    @Test("name parses")
    func nameParses() throws {
        #expect(try parseGroupNewArgs(["--name", "Notes"]) == ParsedGroupNew(name: "Notes", launch: nil))
    }

    @Test("launch flags parse individually")
    func launchFlagsParseIndividually() throws {
        #expect(try parseGroupNewArgs(["--cmd", "date"]) == ParsedGroupNew(name: nil, launch: LaunchSpec(cmd: "date", cwd: nil, title: nil)))
        #expect(try parseGroupNewArgs(["--cwd", "/tmp"]) == ParsedGroupNew(name: nil, launch: LaunchSpec(cmd: nil, cwd: "/tmp", title: nil)))
        #expect(try parseGroupNewArgs(["--title", "logs"]) == ParsedGroupNew(name: nil, launch: LaunchSpec(cmd: nil, cwd: nil, title: "logs")))
    }

    @Test("combination parses")
    func combinationParses() throws {
        #expect(try parseGroupNewArgs(["--name", "Work", "--cmd", "make test", "--cwd", "/repo", "--title", "tests"]) == ParsedGroupNew(
            name: "Work",
            launch: LaunchSpec(cmd: "make test", cwd: "/repo", title: "tests")
        ))
    }

    @Test("background flag is accepted and not reported")
    func backgroundFlagIsAcceptedAndNotReported() throws {
        // Intent: `--background` parses but leaves no trace in the result.
        // Why it exists: `ParsedGroupNew` deliberately has no `background` field
        //   because the CLI derives it from `foreground == false`; the flag
        //   exists here only so the focus conflict guard can see it.
        // Scenario: a recipe passes the redundant explicit `--background`.
        #expect(try parseGroupNewArgs(["--background"]) == ParsedGroupNew(name: nil, launch: nil, foreground: false))
    }

    @Test("foreground flag parses")
    func foregroundFlagParses() throws {
        #expect(try parseGroupNewArgs(["--foreground"]) == ParsedGroupNew(name: nil, launch: nil, foreground: true))
    }

    @Test("conflicting focus flags throw in either order")
    func conflictingFocusFlagsThrowInEitherOrder() {
        #expect(throws: NewCommandParseError.conflictingFocusFlags) {
            try parseGroupNewArgs(["--background", "--foreground"])
        }
        #expect(throws: NewCommandParseError.conflictingFocusFlags) {
            try parseGroupNewArgs(["--foreground", "--background"])
        }
    }

    @Test("repeating the same focus flag is accepted")
    func repeatingTheSameFocusFlagIsAccepted() throws {
        #expect(try parseGroupNewArgs(["--foreground", "--foreground"]) == ParsedGroupNew(name: nil, launch: nil, foreground: true))
        #expect(try parseGroupNewArgs(["--background", "--background"]) == ParsedGroupNew(name: nil, launch: nil, foreground: false))
    }

    @Test("repeated value flags overwrite silently")
    func repeatedValueFlagsOverwriteSilently() throws {
        #expect(try parseGroupNewArgs(["--name", "a", "--name", "b", "--cmd", "one", "--cmd", "two"]) == ParsedGroupNew(
            name: "b",
            launch: LaunchSpec(cmd: "two", cwd: nil, title: nil)
        ))
    }

    @Test("empty command alone leaves no launch")
    func emptyCommandAloneLeavesNoLaunch() throws {
        // Intent: `--cmd ""` yields no launch, while `--cwd ""` still yields one.
        // Why it exists: `LaunchSpec.init` normalizes an empty cmd to nil but
        //   leaves cwd and title alone, so `isEmpty` treats the two differently.
        // Scenario: a caller interpolates an empty variable into the flag value.
        #expect(try parseGroupNewArgs(["--cmd", ""]) == ParsedGroupNew(name: nil, launch: nil))
        #expect(try parseGroupNewArgs(["--cwd", ""]) == ParsedGroupNew(name: nil, launch: LaunchSpec(cmd: nil, cwd: "", title: nil)))
    }

    @Test("missing value throws")
    func missingValueThrows() {
        #expect(throws: NewCommandParseError.missingValue("--name")) {
            try parseGroupNewArgs(["--name"])
        }
        #expect(throws: NewCommandParseError.missingValue("--title")) {
            try parseGroupNewArgs(["--title"])
        }
    }

    @Test("unknown flag throws")
    func unknownFlagThrows() {
        #expect(throws: NewCommandParseError.unknownFlag("--bogus")) {
            try parseGroupNewArgs(["--bogus"])
        }
    }

    @Test("split direction flags are unknown to group new")
    func splitDirectionFlagsAreUnknownToGroupNew() {
        // Intent: `-h` and `-v` belong to `pane split` only.
        // Why it exists: the three commands share a flag grammar, and this pins
        //   which flags stay outside it.
        // Scenario: a caller copies a `pane split` invocation into `group new`.
        #expect(throws: NewCommandParseError.unknownFlag("-h")) {
            try parseGroupNewArgs(["-h"])
        }
        #expect(throws: NewCommandParseError.unknownFlag("-v")) {
            try parseGroupNewArgs(["-v"])
        }
    }

    @Test("bare argument throws")
    func bareArgumentThrows() {
        #expect(throws: NewCommandParseError.unexpectedArgument("Notes")) {
            try parseGroupNewArgs(["Notes"])
        }
    }

    @Test("first bad token wins over a later conflict")
    func firstBadTokenWinsOverALaterConflict() {
        // Intent: parsing stops at the first token it cannot accept.
        // Why it exists: the focus conflict is only detected once both flags are
        //   read, so a left-to-right parser must report the earlier problem.
        // Scenario: a malformed command carries both a typo and both focus flags.
        #expect(throws: NewCommandParseError.unknownFlag("--bogus")) {
            try parseGroupNewArgs(["--bogus", "--background", "--foreground"])
        }
    }
}
