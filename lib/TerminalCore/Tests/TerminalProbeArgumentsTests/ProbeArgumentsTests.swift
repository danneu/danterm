// Behavioral coverage for the shared probe flag parse: what one argument list maps to.
//
// Every case here is stated as argv in, value or refusal out, so a rewrite of the walk that
// keeps the mapping keeps these passing.
import Testing

@testable import TerminalProbeArguments

private let columns = IntegerFlag("--columns", default: 179, minimum: 2)
private let iterations = IntegerFlag("--iterations", default: 40, minimum: 1)
private let chunk = IntegerFlag("--chunk", default: 4096, minimum: 0)
private let samples = IntegerFlag("--samples", default: 40, minimum: 1, maximum: 1000)
private let payload = TextFlag("--payload")
private let recipe = TextFlag("--recipe", default: "standard", allowed: ["standard", "saturating"])
private let json = SwitchFlag("--json")

private let command = ProbeCommand(
    usage: "usage: Probe [--columns <n>]\n",
    flags: [
        .integer(columns), .integer(iterations), .integer(chunk), .integer(samples),
        .text(payload), .text(recipe), .toggle(json),
    ]
)

private func refusal(_ arguments: [String]) -> ProbeArgumentError? {
    guard case .failure(let error) = command.parse(arguments) else { return nil }
    return error
}

private func parsed(_ arguments: [String]) -> ProbeArguments? {
    try? command.parse(arguments).get()
}

@Test("A declared flag with a valid value is read back")
func readsDeclaredValues() throws {
    let arguments = try #require(parsed(["--columns", "80", "--iterations", "3", "--json"]))
    #expect(arguments[columns] == 80)
    #expect(arguments[iterations] == 3)
    #expect(arguments[json])
}

@Test("An absent flag falls back to its declared default")
func absentFlagUsesDefault() throws {
    let arguments = try #require(parsed([]))
    #expect(arguments[columns] == 179)
    #expect(arguments[json] == false)
    #expect(arguments[payload] == nil)
    #expect(arguments[recipe] == "standard")
}

// Intent: a value the parse cannot read is refused, never swapped for the default.
// Why it exists: the helper this parser replaced returned the default for an unparsable value,
// so `--columns eighty` measured 179 columns and printed a header that named 179 as if asked.
// Scenario: spec-first -- the audited behavior of `flagValue` in the memory and occupancy probes.
@Test("An unparsable value is refused rather than defaulted")
func refusesUnparsableValue() throws {
    let error = try #require(refusal(["--columns", "eighty"]))
    #expect(error.flag == "--columns")
    #expect(error.reason == .notAWholeNumber("eighty"))
}

// Intent: a flag written without its value ends the parse.
// Why it exists: the replaced helper treated a trailing flag as absent, which is the one case
// where the user plainly meant to set something.
// Scenario: spec-first.
@Test("A flag with no value is refused rather than defaulted")
func refusesMissingValue() throws {
    let error = try #require(refusal(["--iterations"]))
    #expect(error.flag == "--iterations")
    #expect(error.reason == .missingValue)
}

// Intent: a misspelled flag ends the parse.
// Why it exists: the replaced helper searched for its own name, so it could not see a word it
// did not recognize; a typo simply never took effect and nothing said so.
// Scenario: spec-first.
@Test("An unknown flag is refused")
func refusesUnknownFlag() throws {
    let error = try #require(refusal(["--colunms", "80"]))
    #expect(error.flag == "--colunms")
    #expect(error.reason == .unknownFlag)
}

// Intent: a value outside the range the measurement is defined for ends the parse.
// Why it exists: `--iterations 0` exited 0 over a full table of 0.00 ms readings, and
// `--columns 1` trapped inside the support module with no output at all.
// Scenario: spec-first.
@Test("A value below the declared minimum is refused")
func refusesValueBelowMinimum() {
    #expect(refusal(["--iterations", "0"])?.reason == .belowMinimum(value: 0, minimum: 1))
    #expect(refusal(["--columns", "1"])?.reason == .belowMinimum(value: 1, minimum: 2))
    #expect(refusal(["--chunk", "-5"])?.reason == .belowMinimum(value: -5, minimum: 0))
}

// Intent: a minimum of zero still admits zero.
// Why it exists: the memory probe's `--chunk 0` is a documented mode, not an error, so the
// range check must not collapse "zero" and "negative".
// Scenario: spec-first.
@Test("A zero minimum still admits zero")
func admitsZeroWhenMinimumIsZero() {
    #expect(parsed(["--chunk", "0"])?[chunk] == 0)
}

@Test("A value above the declared maximum is refused")
func refusesValueAboveMaximum() {
    #expect(refusal(["--samples", "1001"])?.reason == .aboveMaximum(value: 1001, maximum: 1000))
}

@Test("A text flag outside its closed set is refused")
func refusesUnknownTextValue() throws {
    let error = try #require(refusal(["--recipe", "sparse"]))
    #expect(error.reason == .notAllowed(value: "sparse", allowed: ["standard", "saturating"]))
}

@Test("A text flag with no closed set takes any value")
func acceptsFreeText() {
    #expect(parsed(["--payload", "scrollback-plain"])?[payload] == "scrollback-plain")
}

// Intent: giving one flag twice ends the parse.
// Why it exists: last-wins would silently discard the first value, which is the same
// "given but ignored" state the rest of this parser exists to make unrepresentable.
// Scenario: spec-first.
@Test("A repeated flag is refused rather than resolved last-wins")
func refusesRepeatedFlag() {
    #expect(refusal(["--columns", "80", "--columns", "90"])?.reason == .repeatedFlag)
}

// Intent: `provided` reports only what the command line carried.
// Why it exists: the resize probe's `--samples` default belongs to the selected recipe, so an
// unwritten flag must not overwrite it with the placeholder the spec declares.
// Scenario: spec-first.
@Test("provided distinguishes an unwritten flag from one written at the default")
func providedIgnoresTheDeclaredDefault() {
    #expect(parsed([])?.provided(samples) == nil)
    #expect(parsed(["--samples", "40"])?.provided(samples) == 40)
}

@Test("A refusal report names the flag and then the usage")
func reportCarriesUsage() throws {
    let error = try #require(refusal(["--columns", "eighty"]))
    #expect(error.report.contains("--columns"))
    #expect(error.report.contains("usage: Probe"))
}
