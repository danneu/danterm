// What the retained-row probe's own argument list maps to. The shared walk is covered in
// TerminalProbeArgumentsTests; these cases pin this probe's declared names and ranges.
import Testing
import TerminalProbeArguments

@testable import TerminalRetainedRowProbeSupport

private func refusal(_ arguments: [String]) -> ProbeArgumentError? {
    guard case .failure(let error) = RetainedRowProbeCommandLine.command.parse(arguments)
    else { return nil }
    return error
}

@Test("A written geometry and stimulus name are what the probe reports")
func readsWrittenArguments() throws {
    let arguments = try RetainedRowProbeCommandLine.command
        .parse(["--columns", "80", "--rows", "24", "--stimulus", "vim-session"]).get()
    #expect(arguments[RetainedRowProbeCommandLine.columns] == 80)
    #expect(arguments[RetainedRowProbeCommandLine.rows] == 24)
    #expect(arguments[RetainedRowProbeCommandLine.stimulus] == "vim-session")
}

// Intent: a geometry the engine cannot represent is a usage error, not a measurement failure.
// Why it exists: `--columns 1` used to pass the parse and come back as a nil report two steps
// later, reported as "rejected geometry" with exit 1 -- the wrong status for a typo.
// Scenario: spec-first.
@Test("A width below what a terminal can represent is refused")
func refusesUnrepresentableWidth() {
    #expect(refusal(["--columns", "1"])?.reason == .belowMinimum(value: 1, minimum: 2))
}

@Test("An unparsable geometry is refused rather than defaulted")
func refusesUnparsableGeometry() {
    #expect(refusal(["--rows", "twenty"])?.reason == .notAWholeNumber("twenty"))
}

@Test("An unwritten stimulus name reports stdin")
func defaultsToStdin() throws {
    let arguments = try RetainedRowProbeCommandLine.command.parse([]).get()
    #expect(arguments[RetainedRowProbeCommandLine.stimulus] == "stdin")
}
