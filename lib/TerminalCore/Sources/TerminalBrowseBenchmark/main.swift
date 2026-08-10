// Release-mode JSON entry point for the retained-history browsing workload.
//
// One process, one block: the collector launches this per scheduled block and
// pairs the normalized per-frame number it prints. Kept to a thin argument
// parse so the stimulus and the timing loop stay in the support target, where
// they can be tested headlessly.
import Foundation
import TerminalBrowseBenchmarkSupport

var measuredCount = 2_000
var arguments = Array(CommandLine.arguments.dropFirst())
let usage = "usage: TerminalBrowseBenchmark [--measured <count>]\n"

while arguments.isEmpty == false {
    guard arguments.count >= 2, arguments[0] == "--measured",
          let value = Int(arguments[1]), value >= 1
    else {
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }
    measuredCount = value
    arguments.removeFirst(2)
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
