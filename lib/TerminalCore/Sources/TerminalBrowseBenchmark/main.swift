// Release-mode JSON entry point for the retained-history browsing workload.
//
// One process, one block: the collector launches this per scheduled block and
// pairs the normalized per-frame number it prints. Kept to a thin argument
// parse so the stimulus and the timing loop stay in the support target, where
// they can be tested headlessly.
import Foundation
import TerminalBrowseBenchmarkSupport
import TerminalProbeArguments

// The flag surface is `BrowseBenchmarkCommandLine`, in the support module, so the gate tests it.
let measuredCount: Int
switch BrowseBenchmarkCommandLine.command.parse(CommandLine.arguments.dropFirst()) {
case .success(let arguments):
    measuredCount = arguments[BrowseBenchmarkCommandLine.measured]
case .failure(let error):
    FileHandle.standardError.write(Data(error.report.utf8))
    exit(2)
}

let measurements = measureBrowsingPlan(measuredCount: measuredCount)
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
do {
    FileHandle.standardOutput.write(try encoder.encode(measurements))
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("browse benchmark failed: \(error)\n".utf8))
    exit(1)
}
