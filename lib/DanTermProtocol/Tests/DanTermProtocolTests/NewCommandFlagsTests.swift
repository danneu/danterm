// Tests for the flag grammar `tab new`, `pane split`, and `group new` share.
// The behavior lives in one place, so it is asserted in one place: a command's
// own test file covers only what is unique to that command.
import Foundation
import Testing
@testable import DanTermProtocol

/// The usage line the driver renders errors with. Deliberately not any real
/// command's, so nothing here can pass by matching a command-specific line.
private let driverUsage = "usage: danterm <creation> \(newCommandFlagsUsage)"

/// Runs the shared grammar with nothing else in the loop, so these tests bind to
/// the grammar itself rather than to whichever command happens to compose it.
private func parseSharedFlags(_ args: [String]) throws -> NewCommandFlags {
    var flags = NewCommandFlags(usage: driverUsage)
    var index = 0
    while index < args.count {
        index = try flags.consume(args, at: index)
    }
    return flags
}

/// Asserts the rendered message, which is the whole observable output of a parse
/// failure now that the parsers render their own errors.
private func expectMessage(
    _ expected: String,
    _ args: [String],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let error = #expect(throws: CLIParseError.self, sourceLocation: sourceLocation) {
        _ = try parseSharedFlags(args)
    }
    #expect(error?.message == expected, sourceLocation: sourceLocation)
}

struct NewCommandFlagsTests {
    @Test("launch flags parse individually")
    func launchFlagsParseIndividually() throws {
        #expect(try parseSharedFlags(["--cmd", "date"]).launch == LaunchSpec(cmd: "date", cwd: nil, title: nil))
        #expect(try parseSharedFlags(["--cwd", "/tmp"]).launch == LaunchSpec(cmd: nil, cwd: "/tmp", title: nil))
        #expect(try parseSharedFlags(["--title", "logs"]).launch == LaunchSpec(cmd: nil, cwd: nil, title: "logs"))
    }

    @Test("launch flags combine")
    func launchFlagsCombine() throws {
        let flags = try parseSharedFlags(["--cmd", "make test", "--cwd", "/repo", "--title", "tests"])
        #expect(flags.launch == LaunchSpec(cmd: "make test", cwd: "/repo", title: "tests"))
    }

    @Test("no launch flags leave no launch")
    func noLaunchFlagsLeaveNoLaunch() throws {
        #expect(try parseSharedFlags([]).launch == nil)
    }

    @Test("repeated value flags overwrite silently")
    func repeatedValueFlagsOverwriteSilently() throws {
        #expect(try parseSharedFlags(["--cmd", "one", "--cmd", "two"]).launch == LaunchSpec(cmd: "two", cwd: nil, title: nil))
    }

    @Test("empty command alone leaves no launch")
    func emptyCommandAloneLeavesNoLaunch() throws {
        // Intent: `--cmd ""` yields no launch, while `--cwd ""` still yields one.
        // Why it exists: `LaunchSpec.init` normalizes an empty cmd to nil but
        //   leaves cwd and title alone, so `isEmpty` treats the two differently.
        // Scenario: a caller interpolates an empty variable into the flag value.
        #expect(try parseSharedFlags(["--cmd", ""]).launch == nil)
        #expect(try parseSharedFlags(["--cwd", ""]).launch == LaunchSpec(cmd: nil, cwd: "", title: nil))
    }

    @Test("focus flags parse")
    func focusFlagsParse() throws {
        let background = try parseSharedFlags(["--background"])
        #expect(background.background)
        #expect(background.foreground == false)
        let foreground = try parseSharedFlags(["--foreground"])
        #expect(foreground.foreground)
        #expect(foreground.background == false)
    }

    @Test("repeating the same focus flag is accepted")
    func repeatingTheSameFocusFlagIsAccepted() throws {
        // Intent: `--background --background` parses, unlike a repeated position
        //   or direction flag, which its command rejects.
        // Why it exists: the three flag families guard differently on purpose,
        //   and the shared grammar must not level them.
        // Scenario: a generated command appends a focus flag that is already there.
        #expect(try parseSharedFlags(["--background", "--background"]).background)
        #expect(try parseSharedFlags(["--foreground", "--foreground"]).foreground)
    }

    @Test("conflicting focus flags are rejected in either order")
    func conflictingFocusFlagsAreRejectedInEitherOrder() {
        // Intent: `--background --foreground` is rejected instead of letting the
        //   last flag win.
        // Why it exists: prevents ambiguous focus policy on the agent-facing CLI.
        // Scenario: a composed command accidentally includes both focus flags.
        let message = "--background and --foreground are mutually exclusive\n\(driverUsage)"
        expectMessage(message, ["--background", "--foreground"])
        expectMessage(message, ["--foreground", "--background"])
    }

    @Test("a missing flag value reports the usage line")
    func aMissingFlagValueReportsTheUsageLine() {
        expectMessage(driverUsage, ["--cmd"])
        expectMessage(driverUsage, ["--title"])
    }

    @Test("an unowned flag is rejected by name")
    func anUnownedFlagIsRejectedByName() {
        // Intent: a token the shared grammar does not own is rejected here, which
        //   is why each command need only own its own flags.
        // Why it exists: this is the one rule that decides whether an unrecognized
        //   token is a flag or a stray argument.
        // Scenario: a command carries a typo, and a command carries a bare word.
        expectMessage("unknown flag: --bogus", ["--bogus"])
        expectMessage("unexpected argument: Notes", ["Notes"])
    }

    @Test("the first bad token wins over a later conflict")
    func theFirstBadTokenWinsOverALaterConflict() {
        // Intent: parsing stops at the first token it cannot accept.
        // Why it exists: the focus conflict is only detected once both flags are
        //   read, so a left-to-right parser must report the earlier problem.
        // Scenario: a malformed command carries both a typo and both focus flags.
        expectMessage("unknown flag: --bogus", ["--bogus", "--background", "--foreground"])
    }
}
