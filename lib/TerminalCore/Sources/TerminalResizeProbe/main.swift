// Release-mode JSON entry point for the saturated-history resize probe.
//
// A probe, not a benchmark block: no collector schedules this and nothing pairs
// its output. It is run by hand, its JSON is pasted into a finding, and it stays
// committed so the next reader can re-run the same recipe -- which is exactly
// what `15/F18`'s deleted browsing probe could not offer.
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
