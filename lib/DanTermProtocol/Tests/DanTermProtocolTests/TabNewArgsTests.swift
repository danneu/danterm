// Tests for what is unique to the `danterm tab new` argument parser: `--group`,
// the position flags, the flags it does not own, and the background it reports.
// The flag grammar it shares with `pane split` and `group new` is asserted once,
// in `NewCommandFlagsTests`.
import Foundation
import Testing
@testable import DanTermProtocol

struct TabNewArgsTests {
    @Test("group parses")
    func groupParses() throws {
        #expect(try parseTabNewArgs(["--group", "G1"]) == ParsedTabNew(group: "G1", launch: nil))
    }

    @Test("a repeated group overwrites silently")
    func aRepeatedGroupOverwritesSilently() throws {
        #expect(try parseTabNewArgs(["--group", "G1", "--group", "G2"]) == ParsedTabNew(group: "G2", launch: nil))
    }

    @Test("a missing group value reports the usage line")
    func aMissingGroupValueReportsTheUsageLine() {
        let error = #expect(throws: CLIParseError.self) {
            try parseTabNewArgs(["--group"])
        }
        #expect(error?.message == tabNewUsage)
    }

    @Test("both focus flags are reported")
    func bothFocusFlagsAreReported() throws {
        // Intent: `tab new` reports the background as well as the foreground.
        // Why it exists: `group new` reports only the foreground, so which flags
        //   reach a result is a per-command fact and belongs in this file.
        // Scenario: an agent recipe still passes the now-redundant `--background`.
        #expect(try parseTabNewArgs(["--background"]) == ParsedTabNew(group: nil, launch: nil, background: true, foreground: false))
        #expect(try parseTabNewArgs(["--foreground"]) == ParsedTabNew(group: nil, launch: nil, background: false, foreground: true))
    }

    @Test("split direction flags are unknown to tab new")
    func splitDirectionFlagsAreUnknownToTabNew() {
        // Intent: `-h` and `-v` belong to `pane split` only.
        // Why it exists: the three creation commands share a flag grammar, and
        //   this pins which flags stay outside it.
        // Scenario: a caller copies a `pane split` invocation into `tab new`.
        for flag in ["-h", "-v"] {
            let error = #expect(throws: CLIParseError.self) {
                try parseTabNewArgs([flag])
            }
            #expect(error?.message == "unknown flag: \(flag)")
        }
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
        let message = "--after-selected, --at-group-end, and --after-tab are mutually exclusive\n\(tabNewUsage)"
        for args in [
            ["--after-selected", "--at-group-end"],
            ["--at-group-end", "--at-group-end"],
            ["--after-tab", "T1", "--after-tab", "T2"],
        ] {
            let error = #expect(throws: CLIParseError.self) {
                try parseTabNewArgs(args)
            }
            #expect(error?.message == message)
        }
    }

    @Test("after-tab reads its value before the position conflict")
    func afterTabReadsItsValueBeforeThePositionConflict() {
        // Intent: a trailing `--after-tab` with no value reports the bare usage
        //   line, not the position conflict it would also cause.
        // Why it exists: the value is read first on purpose, so the message does
        //   not accuse the user of a conflict they can only fix by supplying a value.
        // Scenario: a command sets a position and then appends a bare
        //   `--after-tab` whose id was dropped.
        let error = #expect(throws: CLIParseError.self) {
            try parseTabNewArgs(["--after-selected", "--after-tab"])
        }
        #expect(error?.message == tabNewUsage)
    }
}
