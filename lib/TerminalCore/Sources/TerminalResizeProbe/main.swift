// Release-mode JSON entry point for the saturated-history resize probe.
//
// A probe, not a benchmark block: no collector schedules this and nothing pairs
// its output. It is run by hand, its JSON is pasted into a finding, and it stays
// committed so the next reader can re-run the same recipe -- which is exactly
// what `research/15/F18`'s deleted browsing probe could not offer.
//
// Kept to a thin argument parse so the recipe and the timing loop stay in the
// support target, where they are tested headlessly.
import Foundation
import TerminalResizeProbeSupport

var recipe = ResizeProbeRecipe.standard
var arguments = Array(CommandLine.arguments.dropFirst())
let usage = """
usage: TerminalResizeProbe [--recipe standard|saturating|sparse|wide] [--samples <count>] \
[--alternate-columns <count>]

"""

// `--recipe` is resolved first, so flag order cannot silently decide whether a
// later `--samples` is overwritten by the selected recipe's own count.
if let index = arguments.firstIndex(of: "--recipe") {
    guard index + 1 < arguments.count else {
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }
    switch arguments[index + 1] {
    case "standard": recipe = .standard
    case "saturating": recipe = .saturating
    case "sparse": recipe = .sparseSaturating
    case "wide": recipe = .wideSaturating
    default:
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }
    arguments.removeSubrange(index...(index + 1))
}

while arguments.isEmpty == false {
    guard arguments.count >= 2, let value = Int(arguments[1]), value >= 1 else {
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }
    switch arguments[0] {
    case "--samples":
        recipe = ResizeProbeRecipe(
            columns: recipe.columns, rows: recipe.rows, lineCount: recipe.lineCount,
            scrollbackBudgetBytes: recipe.scrollbackBudgetBytes,
            alternateColumns: recipe.alternateColumns,
            sampleCount: value, warmupCount: recipe.warmupCount,
            name: recipe.name, payload: recipe.payload
        )
    case "--alternate-columns":
        recipe = ResizeProbeRecipe(
            columns: recipe.columns, rows: recipe.rows, lineCount: recipe.lineCount,
            scrollbackBudgetBytes: recipe.scrollbackBudgetBytes,
            alternateColumns: value,
            sampleCount: recipe.sampleCount, warmupCount: recipe.warmupCount,
            name: recipe.name, payload: recipe.payload
        )
    default:
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }
    arguments.removeFirst(2)
}

// `Terminal.resize` ignores a width below 2 and a width equal to the current one,
// so `--alternate-columns 1` or `--alternate-columns <recipe columns>` would time
// `sampleCount` no-op resizes and print a full distribution of near-zero
// nanoseconds with nothing marking it unmeasured. Rejected here as the usage error
// every other bad flag produces, rather than left to the support target's
// precondition, which would trap the CLI with a SIGTRAP instead.
guard recipe.alternateColumns >= 2, recipe.alternateColumns != recipe.columns else {
    FileHandle.standardError.write(Data("""
        --alternate-columns must be at least 2 and differ from the recipe's \
        \(recipe.columns) columns; resizing to \(recipe.alternateColumns) is a no-op and \
        would measure nothing.

        """.utf8))
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}

let report = measureSaturatedResize(recipe: recipe)
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
do {
    FileHandle.standardOutput.write(try encoder.encode(report))
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("resize probe failed: \(error)\n".utf8))
    exit(1)
}
