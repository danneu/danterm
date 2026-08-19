// Tests for what is unique to the `danterm tab new` argument parser: the
// position flags, the flags it does not own, and the background it reports. The
// flag grammar it shares with `pane split` and `group new` is asserted once, in
// `NewCommandFlagsTests`; the anchor -- `--group` or `--after-tab` -- is read by
// the shared target step before this parser sees anything.
import Foundation
import Testing
@testable import DanTermProtocol

struct TabNewArgsTests {
    @Test("an empty tail parses")
    func anEmptyTailParses() throws {
        #expect(try parseTabNewArgs([]) == ParsedTabNew(launch: nil))
    }

    @Test("the anchor flags are not this parser's to read", arguments: [
        ["--group", "G1"],
        ["--after-tab", "T1"],
    ])
    func theAnchorFlagsAreNotThisParsersToRead(_ args: [String]) {
        // Intent: the tail parser treats an anchor flag as any other unknown flag.
        // Why it exists: the anchor belongs to the shared target step that runs
        //   before this parser, so an anchor reaching it would mean two owners.
        let error = #expect(throws: CLIParseError.self) {
            try parseTabNewArgs(args)
        }
        #expect(error?.message == "unknown flag: \(args[0])")
    }

    @Test("both focus flags are reported")
    func bothFocusFlagsAreReported() throws {
        // Intent: `tab new` reports the background as well as the foreground.
        // Why it exists: `group new` reports only the foreground, so which flags
        //   reach a result is a per-command fact and belongs in this file.
        // Scenario: an agent recipe still passes the now-redundant `--background`.
        #expect(try parseTabNewArgs(["--background"]) == ParsedTabNew(launch: nil, background: true, foreground: false))
        #expect(try parseTabNewArgs(["--foreground"]) == ParsedTabNew(launch: nil, background: false, foreground: true))
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
        #expect(try parseTabNewArgs(["--after-selected"]) == ParsedTabNew(launch: nil, position: .afterSelected))
        #expect(try parseTabNewArgs(["--at-group-end"]) == ParsedTabNew(launch: nil, position: .atGroupEnd))
    }

    @Test("position flags conflict, including with themselves")
    func positionFlagsConflictIncludingWithThemselves() {
        // Intent: a second position flag always conflicts, even when it repeats
        //   the first one.
        // Why it exists: position is a single slot filled once, unlike the focus
        //   flags, which tolerate repetition. The asymmetry is intentional.
        // Scenario: a command asks for two placements for one new tab.
        for args in [
            ["--after-selected", "--at-group-end"],
            ["--at-group-end", "--at-group-end"],
        ] {
            let error = #expect(throws: CLIParseError.self) {
                try parseTabNewArgs(args)
            }
            #expect(error?.message == tabNewPositionConflict)
        }
    }
}
