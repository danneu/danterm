// The resize probe's flag surface and the resolution of those flags into a recipe, declared here
// rather than in `main.swift` so the gate can test them. Top-level code in an executable target
// cannot be imported, so a spec written there is a spec no suite can reach.
//
// The no-op-width refusal lives here rather than in TerminalProbeArguments because it compares
// two numbers only the resolved recipe holds.
import TerminalProbeArguments

/// The one declaration of what `TerminalResizeProbe` accepts.
public enum ResizeProbeCommandLine {
    public static let recipeNames = ["standard", "saturating", "sparse", "wide"]
    public static let recipe = TextFlag("--recipe", default: "standard", allowed: recipeNames)
    /// The declared defaults on these two are placeholders: the value that applies comes from the
    /// selected recipe, and both are read through `provided`, so an unwritten flag leaves the
    /// recipe's own number alone. That is why flag order cannot decide the outcome.
    public static let samples = IntegerFlag(
        "--samples", default: ResizeProbeRecipe.standard.sampleCount, minimum: 1
    )
    /// At least 2 because `Terminal.resize` ignores a narrower width, which would time a run of
    /// no-op resizes and print a full distribution of near-zero nanoseconds.
    public static let alternateColumns = IntegerFlag(
        "--alternate-columns", default: ResizeProbeRecipe.standard.alternateColumns, minimum: 2
    )

    public static let command = ProbeCommand(
        usage: """
            usage: TerminalResizeProbe [--recipe standard|saturating|sparse|wide] \
            [--samples <count>] [--alternate-columns <count>]

            """,
        flags: [.text(recipe), .integer(samples), .integer(alternateColumns)]
    )
}

/// Turns a parsed argument list into the recipe to measure, or into the refusal to print.
///
/// A recipe out of here is one whose alternate width really resizes: `Terminal.resize` ignores a
/// width equal to the current one, so an alternate width matching the recipe's would time
/// `sampleCount` no-op resizes and report near-zero nanoseconds with nothing marking it
/// unmeasured.
public func resolveResizeProbeRecipe(
    _ arguments: ProbeArguments
) -> Result<ResizeProbeRecipe, ProbeArgumentError> {
    var recipe: ResizeProbeRecipe = switch arguments[ResizeProbeCommandLine.recipe] {
    case "saturating": .saturating
    case "sparse": .sparseSaturating
    case "wide": .wideSaturating
    default: .standard
    }

    if let sampleCount = arguments.provided(ResizeProbeCommandLine.samples) {
        recipe = recipe.with(sampleCount: sampleCount)
    }
    if let alternateColumns = arguments.provided(ResizeProbeCommandLine.alternateColumns) {
        recipe = recipe.with(alternateColumns: alternateColumns)
    }

    guard recipe.alternateColumns != recipe.columns else {
        return .failure(ProbeArgumentError(
            flag: ResizeProbeCommandLine.alternateColumns.name,
            reason: .rejected("""
                --alternate-columns must differ from the \(recipe.name) recipe's \
                \(recipe.columns) columns; resizing to \(recipe.alternateColumns) is a no-op and \
                would measure nothing.
                """),
            usage: ResizeProbeCommandLine.command.usage
        ))
    }
    return .success(recipe)
}

extension ResizeProbeRecipe {
    /// A copy with one field replaced, so a flag override does not have to restate the other
    /// eight and cannot silently drop one when the type grows a field.
    func with(sampleCount: Int? = nil, alternateColumns: Int? = nil) -> ResizeProbeRecipe {
        ResizeProbeRecipe(
            columns: columns,
            rows: rows,
            lineCount: lineCount,
            scrollbackBudgetBytes: scrollbackBudgetBytes,
            alternateColumns: alternateColumns ?? self.alternateColumns,
            sampleCount: sampleCount ?? self.sampleCount,
            warmupCount: warmupCount,
            name: name,
            payload: payload
        )
    }
}
