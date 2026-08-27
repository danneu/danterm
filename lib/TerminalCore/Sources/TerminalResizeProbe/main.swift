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
import TerminalProbeArguments
import TerminalResizeProbeSupport

// The flag surface and its resolution are `ResizeProbeCommandLine` and
// `resolveResizeProbeRecipe`, in the support module, so the gate tests them. This file only
// turns a refusal into an exit status and a report into JSON.
let recipe: ResizeProbeRecipe
switch ResizeProbeCommandLine.command.parse(CommandLine.arguments.dropFirst())
    .flatMap(resolveResizeProbeRecipe)
{
case .success(let resolved):
    recipe = resolved
case .failure(let error):
    FileHandle.standardError.write(Data(error.report.utf8))
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
