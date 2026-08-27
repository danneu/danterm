// What the occupancy probe's own argument list maps to. The shared walk is covered in
// TerminalProbeArgumentsTests; these cases pin this probe's declared names and ranges, which are
// what decide whether a mistyped flag reaches `makeOccupancyTerminal`.
import Testing
import TerminalProbeArguments

@testable import TerminalOccupancyProbeSupport

private func refusal(_ arguments: [String]) -> ProbeArgumentError? {
    guard case .failure(let error) = OccupancyProbeCommandLine.command.parse(arguments)
    else { return nil }
    return error
}

@Test("A written geometry is what the probe measures")
func readsWrittenGeometry() throws {
    let arguments = try #require(
        try? OccupancyProbeCommandLine.command.parse(["--columns", "80", "--rows", "24"]).get()
    )
    #expect(arguments[OccupancyProbeCommandLine.columns] == 80)
    #expect(arguments[OccupancyProbeCommandLine.rows] == 24)
}

// Intent: an unparsable geometry ends the run instead of becoming the default.
// Why it exists: the helper this spec replaced returned the default, so `--columns eighty`
// measured 179 columns and printed a header naming 179 as though it had been asked for.
// Scenario: spec-first -- the audited behavior of `flagValue`.
@Test("An unparsable geometry is refused rather than defaulted")
func refusesUnparsableGeometry() {
    #expect(refusal(["--columns", "eighty"])?.reason == .notAWholeNumber("eighty"))
}

// Intent: a zero-iteration run cannot start.
// Why it exists: `--iterations 0` exited 0 over a full table of 0.00 ms readings, which is
// indistinguishable from a terminal that answered instantly.
// Scenario: spec-first.
@Test("A zero-iteration run is refused")
func refusesZeroIterations() {
    #expect(refusal(["--iterations", "0"])?.reason == .belowMinimum(value: 0, minimum: 1))
}

// Intent: a geometry the engine cannot represent is a usage error, not a crash.
// Why it exists: `--columns 1` reached `makeOccupancyTerminal` and trapped there, printing
// nothing at all -- the operator saw a signal, not a mistake.
// Scenario: spec-first.
@Test("A width below what a terminal can represent is refused")
func refusesUnrepresentableWidth() {
    #expect(refusal(["--columns", "1"])?.reason == .belowMinimum(value: 1, minimum: 2))
}

@Test("A misspelled flag is refused rather than ignored")
func refusesMisspelledFlag() {
    #expect(refusal(["--iteration", "5"])?.reason == .unknownFlag)
}

@Test("An unwritten flag falls back to the shipped default")
func fallsBackToShippedDefaults() throws {
    let arguments = try #require(try? OccupancyProbeCommandLine.command.parse([]).get())
    #expect(arguments[OccupancyProbeCommandLine.columns] == OccupancyProbeDefaults.columns)
    #expect(arguments[OccupancyProbeCommandLine.iterations] == OccupancyProbeDefaults.iterations)
    #expect(arguments[OccupancyProbeCommandLine.json] == false)
}
