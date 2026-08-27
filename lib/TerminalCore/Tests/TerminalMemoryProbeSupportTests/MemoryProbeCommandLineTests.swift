// What the memory probe's own argument list resolves to. The shared walk is covered in
// TerminalProbeArgumentsTests; these cases pin this probe's declared names and ranges plus the
// payload-name check, which is the one refusal only the matrix can make.
import Testing
import TerminalProbeArguments

@testable import TerminalMemoryProbeSupport

private func resolve(_ arguments: [String]) -> Result<MemoryProbeInputs, ProbeArgumentError> {
    MemoryProbeCommandLine.command.parse(arguments).flatMap(resolveMemoryProbeInputs)
}

private func refusal(_ arguments: [String]) -> ProbeArgumentError? {
    guard case .failure(let error) = resolve(arguments) else { return nil }
    return error
}

@Test("A written geometry is what the probe measures")
func readsWrittenGeometry() throws {
    let inputs = try resolve(["--columns", "80", "--rows", "24"]).get()
    #expect(inputs.columns == 80)
    #expect(inputs.rows == 24)
}

// Intent: an unparsable geometry ends the run instead of becoming the default.
// Why it exists: the helper this spec replaced returned the default, so `--columns eighty`
// printed a header naming 179 columns as though 179 had been asked for.
// Scenario: spec-first -- the audited behavior of `flagValue`.
@Test("An unparsable geometry is refused rather than defaulted")
func refusesUnparsableGeometry() {
    #expect(refusal(["--columns", "eighty"])?.reason == .notAWholeNumber("eighty"))
}

// Intent: a flag written without its value ends the run.
// Why it exists: a trailing `--rows` read as absent, which is the one case where the operator
// plainly meant to set something.
// Scenario: spec-first.
@Test("A flag written without its value is refused")
func refusesMissingValue() {
    #expect(refusal(["--rows"])?.reason == .missingValue)
}

// Intent: a negative chunk cannot silently select single-shot feeding.
// Why it exists: `--chunk -5` fell through the old parse into the mode that measures one huge
// parse instead of a resident terminal, and the header said only "single-shot" -- the same
// wording a deliberate `--chunk 0` produces.
// Scenario: spec-first.
@Test("A negative feed chunk is refused, while zero still selects single-shot")
func refusesNegativeChunkButAdmitsZero() throws {
    #expect(refusal(["--chunk", "-5"])?.reason == .belowMinimum(value: -5, minimum: 0))
    #expect(try resolve(["--chunk", "0"]).get().chunkBytes == nil)
    #expect(try resolve(["--chunk", "8192"]).get().chunkBytes == 8192)
}

@Test("An unknown payload name is refused and the known names are listed")
func refusesUnknownPayload() throws {
    let error = try #require(refusal(["--payload", "no-such-payload"]))
    guard case .notAllowed(let value, let allowed) = error.reason else {
        Issue.record("expected a closed-set refusal, got \(error.reason)")
        return
    }
    #expect(value == "no-such-payload")
    #expect(allowed.isEmpty == false)
}

@Test("A known payload name resolves and an unwritten one runs the whole matrix")
func resolvesKnownPayload() throws {
    let known = try #require(MemoryProbeMatrix.payloads(columns: 179, lineCount: 1).first?.name)
    #expect(try resolve(["--payload", known]).get().payloadName == known)
    #expect(try resolve([]).get().payloadName == nil)
}

@Test("An unwritten flag falls back to the shipped default")
func fallsBackToShippedDefaults() throws {
    let inputs = try resolve([]).get()
    #expect(inputs.columns == 179)
    #expect(inputs.lineCount == MemoryProbeMatrix.scrollbackLineCount)
    #expect(inputs.chunkBytes == defaultFeedChunkBytes)
    #expect(inputs.wantsJSON == false)
    #expect(inputs.wantsVmmap == false)
}
