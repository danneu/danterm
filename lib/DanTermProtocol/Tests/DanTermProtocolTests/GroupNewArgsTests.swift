// Tests for what is unique to the `danterm group new` argument parser: `--name`,
// the flags it does not own, and the background it deliberately does not report.
// The flag grammar it shares with `tab new` and `pane split` is asserted once, in
// `NewCommandFlagsTests`.
import Foundation
import Testing
@testable import DanTermProtocol

struct GroupNewArgsTests {
    @Test("name parses")
    func nameParses() throws {
        #expect(try parseGroupNewArgs(["--name", "Notes"]) == ParsedGroupNew(name: "Notes", launch: nil))
    }

    @Test("a repeated name overwrites silently")
    func aRepeatedNameOverwritesSilently() throws {
        #expect(try parseGroupNewArgs(["--name", "a", "--name", "b"]) == ParsedGroupNew(name: "b", launch: nil))
    }

    @Test("a missing name value reports the usage line")
    func aMissingNameValueReportsTheUsageLine() {
        let error = #expect(throws: CLIParseError.self) {
            try parseGroupNewArgs(["--name"])
        }
        #expect(error?.message == groupNewUsage)
    }

    @Test("background is accepted and not reported")
    func backgroundIsAcceptedAndNotReported() throws {
        // Intent: `--background` parses but leaves no trace in the result, while
        //   `--foreground` is reported.
        // Why it exists: `ParsedGroupNew` deliberately has no `background` field
        //   because the CLI derives it from `foreground == false`; the flag
        //   exists in the shared grammar only so the focus conflict can be seen.
        // Scenario: a recipe passes the redundant explicit `--background`.
        #expect(try parseGroupNewArgs(["--background"]) == ParsedGroupNew(name: nil, launch: nil, foreground: false))
        #expect(try parseGroupNewArgs(["--foreground"]) == ParsedGroupNew(name: nil, launch: nil, foreground: true))
    }

    @Test("split direction flags are unknown to group new")
    func splitDirectionFlagsAreUnknownToGroupNew() {
        // Intent: `-h` and `-v` belong to `pane split` only.
        // Why it exists: the three commands share a flag grammar, and this pins
        //   which flags stay outside it.
        // Scenario: a caller copies a `pane split` invocation into `group new`.
        for flag in ["-h", "-v"] {
            let error = #expect(throws: CLIParseError.self) {
                try parseGroupNewArgs([flag])
            }
            #expect(error?.message == "unknown flag: \(flag)")
        }
    }
}
