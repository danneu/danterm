// What the browse benchmark's own argument list maps to. The shared walk is covered in
// TerminalProbeArgumentsTests; these cases pin the one flag the collector passes.
import Testing
import TerminalProbeArguments

@testable import TerminalBrowseBenchmarkSupport

private func refusal(_ arguments: [String]) -> ProbeArgumentError? {
    guard case .failure(let error) = BrowseBenchmarkCommandLine.command.parse(arguments)
    else { return nil }
    return error
}

@Test("A written frame count is what the block measures")
func readsWrittenFrameCount() throws {
    let arguments = try BrowseBenchmarkCommandLine.command.parse(["--measured", "500"]).get()
    #expect(arguments[BrowseBenchmarkCommandLine.measured] == 500)
}

@Test("A zero frame count is refused")
func refusesZeroFrames() {
    #expect(refusal(["--measured", "0"])?.reason == .belowMinimum(value: 0, minimum: 1))
}

@Test("An unparsable frame count is refused rather than defaulted")
func refusesUnparsableFrameCount() {
    #expect(refusal(["--measured", "lots"])?.reason == .notAWholeNumber("lots"))
}

@Test("An unwritten flag falls back to the shipped default")
func fallsBackToShippedDefault() throws {
    let arguments = try BrowseBenchmarkCommandLine.command.parse([]).get()
    #expect(arguments[BrowseBenchmarkCommandLine.measured] == 2_000)
}

@Test("A written workload selects its stimulus and the default stays retained-browse")
func readsWrittenWorkload() throws {
    let dense = try BrowseBenchmarkCommandLine.command.parse(["--workload", "search-dense"]).get()
    #expect(
        BrowseBenchmarkCommandLine.stimulus(named: dense[BrowseBenchmarkCommandLine.workload])
            == .searchDense
    )
    let unwritten = try BrowseBenchmarkCommandLine.command.parse([]).get()
    #expect(
        BrowseBenchmarkCommandLine.stimulus(named: unwritten[BrowseBenchmarkCommandLine.workload])
            == .standard
    )
}

@Test("An unknown workload is refused rather than defaulted")
func refusesUnknownWorkload() {
    #expect(
        refusal(["--workload", "draw"])?.reason
            == .notAllowed(value: "draw", allowed: ["retained-browse", "search-dense"])
    )
}
