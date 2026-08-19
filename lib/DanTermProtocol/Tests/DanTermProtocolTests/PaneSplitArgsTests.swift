// Tests the direction and focus flags in the `danterm pane split` tail. The
// shared target parser and CLIParser own the pane-or-tab grammar and its
// target-dependent direction rule.
import Foundation
import Testing
@testable import DanTermProtocol

struct PaneSplitArgsTests {
    @Test("direction flags parse")
    func directionFlagsParse() throws {
        #expect(try parsePaneSplitArgs(["-h"]) == ParsedPaneSplit(direction: .horizontal))
        #expect(try parsePaneSplitArgs(["-v"]) == ParsedPaneSplit(direction: .vertical))
    }

    @Test("target flags are not this parser's to read", arguments: ["--pane", "--tab"])
    func targetFlagsAreNotThisParsersToRead(_ flag: String) {
        let error = #expect(throws: CLIParseError.self) {
            try parsePaneSplitArgs([flag, "target", "-h"])
        }
        #expect(error?.message == "unknown flag: \(flag)")
    }

    @Test("both focus flags are reported")
    func bothFocusFlagsAreReported() throws {
        // Intent: `pane split` reports the background as well as the foreground.
        // Why it exists: `group new` reports only the foreground, so which flags
        //   reach a result is a per-command fact and belongs in this file.
        // Scenario: an agent recipe still passes the now-redundant `--background`.
        #expect(try parsePaneSplitArgs(["--background"]) == ParsedPaneSplit(background: true, foreground: false))
        #expect(try parsePaneSplitArgs(["--foreground"]) == ParsedPaneSplit(background: false, foreground: true))
    }

    @Test("no direction remains available to a tab target")
    func noDirectionRemainsAvailableToATabTarget() throws {
        #expect(try parsePaneSplitArgs([]) == ParsedPaneSplit())
    }

    @Test("a repeated direction flag is rejected")
    func aRepeatedDirectionFlagIsRejected() {
        // Intent: a second direction flag is rejected, even when it repeats the
        //   first one.
        // Why it exists: direction is a single slot filled once, unlike the focus
        //   flags. The message names the offending token so the user can drop it.
        // Scenario: a generated split appends `-h` to a command that has it.
        for flag in ["-h", "-v"] {
            let error = #expect(throws: CLIParseError.self) {
                try parsePaneSplitArgs(["-h", flag])
            }
            #expect(error?.message == "unexpected argument: \(flag)")
        }
    }

    @Test("an unknown flag is reported without a direction")
    func anUnknownFlagIsReportedWithoutADirection() {
        let error = #expect(throws: CLIParseError.self) {
            try parsePaneSplitArgs(["--bogus"])
        }
        #expect(error?.message == "unknown flag: --bogus")
    }
}
