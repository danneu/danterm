// Tests for what is unique to the `danterm pane split` argument parser: the
// pane-or-tab target, pane direction, and background it reports. The flag
// grammar it shares with `tab new` and `group new` is asserted once, in
// `NewCommandFlagsTests`.
import Foundation
import Testing
@testable import DanTermProtocol

struct PaneSplitArgsTests {
    @Test("direction flags parse")
    func directionFlagsParse() throws {
        #expect(throws: CLIParseError.self) { try parsePaneSplitArgs(["-h"]) }
        #expect(throws: CLIParseError.self) { try parsePaneSplitArgs(["-v"]) }
    }

    @Test("explicit pane parses")
    func explicitPaneParses() throws {
        #expect(try parsePaneSplitArgs(["--pane", "P1", "-h"]) == ParsedPaneSplit(target: .pane("P1", direction: .horizontal)))
    }

    @Test("explicit tab parses without a direction")
    func explicitTabParses() throws {
        #expect(try parsePaneSplitArgs(["--tab", "T1"]) == ParsedPaneSplit(target: .tab("T1")))
    }

    @Test("a repeated pane overwrites silently")
    func aRepeatedPaneOverwritesSilently() throws {
        #expect(try parsePaneSplitArgs(["--pane", "P1", "--pane", "P2", "-h"]) == ParsedPaneSplit(target: .pane("P2", direction: .horizontal)))
    }

    @Test("a missing pane value reports the usage line")
    func aMissingPaneValueReportsTheUsageLine() {
        let error = #expect(throws: CLIParseError.self) {
            try parsePaneSplitArgs(["--pane"])
        }
        #expect(error?.message == paneSplitUsage)
    }

    @Test("both focus flags are reported")
    func bothFocusFlagsAreReported() throws {
        // Intent: `pane split` reports the background as well as the foreground.
        // Why it exists: `group new` reports only the foreground, so which flags
        //   reach a result is a per-command fact and belongs in this file.
        // Scenario: an agent recipe still passes the now-redundant `--background`.
        #expect(try parsePaneSplitArgs(["--tab", "T1", "--background"]) == ParsedPaneSplit(target: .tab("T1"), background: true, foreground: false))
        #expect(try parsePaneSplitArgs(["--tab", "T1", "--foreground"]) == ParsedPaneSplit(target: .tab("T1"), background: false, foreground: true))
    }

    @Test("target and direction combinations are enforced")
    func targetAndDirectionCombinationsAreEnforced() {
        for args in [
            ["--pane", "P1"],
            ["--tab", "T1", "-h"],
            ["--pane", "P1", "--tab", "T1", "-h"],
        ] {
            #expect(throws: CLIParseError.self) { try parsePaneSplitArgs(args) }
        }
    }

    @Test("no direction reports the usage line")
    func noDirectionReportsTheUsageLine() {
        let error = #expect(throws: CLIParseError.self) {
            try parsePaneSplitArgs([])
        }
        #expect(error?.message == paneSplitUsage)
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

    @Test("a bad token outranks the missing direction checked after the scan")
    func aBadTokenOutranksTheMissingDirectionCheckedAfterTheScan() {
        // Intent: an error raised while scanning tokens beats the direction check
        //   that runs once the scan is over.
        // Why it exists: the direction check is the one guard placed after the
        //   loop, so it is the one that could wrongly pre-empt a real token error.
        // Scenario: a malformed split carries a typo and never names a direction.
        let error = #expect(throws: CLIParseError.self) {
            try parsePaneSplitArgs(["--bogus"])
        }
        #expect(error?.message == "unknown flag: --bogus")
    }
}
