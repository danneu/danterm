// What the resize probe's own argument list resolves to. The shared walk is covered in
// TerminalProbeArgumentsTests; these cases pin the recipe selection, the two overrides, and the
// no-op-width refusal that only the resolved recipe can make.
import Testing
import TerminalProbeArguments

@testable import TerminalResizeProbeSupport

private func resolve(_ arguments: [String]) -> Result<ResizeProbeRecipe, ProbeArgumentError> {
    ResizeProbeCommandLine.command.parse(arguments).flatMap(resolveResizeProbeRecipe)
}

private func refusal(_ arguments: [String]) -> ProbeArgumentError? {
    guard case .failure(let error) = resolve(arguments) else { return nil }
    return error
}

@Test("Each recipe name selects its recipe, and no name selects the standard one")
func selectsRecipeByName() throws {
    #expect(try resolve([]).get().name == ResizeProbeRecipe.standard.name)
    #expect(try resolve(["--recipe", "saturating"]).get().name == ResizeProbeRecipe.saturating.name)
    #expect(
        try resolve(["--recipe", "sparse"]).get().name == ResizeProbeRecipe.sparseSaturating.name
    )
}

@Test("An unknown recipe name is refused and the known names are listed")
func refusesUnknownRecipe() {
    #expect(
        refusal(["--recipe", "enormous"])?.reason
            == .notAllowed(value: "enormous", allowed: ResizeProbeCommandLine.recipeNames)
    )
}

// Intent: an unwritten `--samples` leaves the selected recipe's own count alone.
// Why it exists: the flag declares a placeholder default so the parse has a type, and applying
// that placeholder unconditionally would silently retime every recipe at the standard count.
// Scenario: spec-first.
@Test("An unwritten sample count does not overwrite the recipe, in either flag order")
func unwrittenSampleCountKeepsTheRecipe() throws {
    #expect(
        try resolve(["--recipe", "saturating"]).get().sampleCount
            == ResizeProbeRecipe.saturating.sampleCount
    )
    #expect(try resolve(["--samples", "7", "--recipe", "saturating"]).get().sampleCount == PositiveCount.declared(7))
    #expect(try resolve(["--recipe", "saturating", "--samples", "7"]).get().sampleCount == PositiveCount.declared(7))
}

// Intent: an alternate width that cannot resize ends the run.
// Why it exists: `Terminal.resize` ignores a width equal to the current one, so the probe would
// time a run of no-op resizes and print a full distribution of near-zero nanoseconds with
// nothing marking it unmeasured.
// Scenario: spec-first.
@Test("An alternate width that would be a no-op is refused")
func refusesNoOpAlternateWidth() throws {
    let standard = ResizeProbeRecipe.standard
    let error = try #require(refusal(["--alternate-columns", String(standard.columns)]))
    guard case .rejected(let explanation) = error.reason else {
        Issue.record("expected a probe-specific refusal, got \(error.reason)")
        return
    }
    #expect(explanation.contains("no-op"))
}

@Test("An alternate width below what a terminal can represent is refused")
func refusesUnrepresentableAlternateWidth() {
    #expect(refusal(["--alternate-columns", "1"])?.reason == .belowMinimum(value: 1, minimum: 2))
}

@Test("A zero sample count is refused")
func refusesZeroSamples() {
    #expect(refusal(["--samples", "0"])?.reason == .belowMinimum(value: 0, minimum: 1))
}
