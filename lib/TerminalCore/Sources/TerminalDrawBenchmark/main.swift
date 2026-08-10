// Release-mode JSON entry point for the offscreen CoreText draw micro benchmark.
import Foundation
import TerminalDrawBenchmarkSupport

guard CommandLine.arguments.count == 2,
      let iterations = Int(CommandLine.arguments[1]),
      iterations >= 2 else {
    FileHandle.standardError.write(Data("usage: TerminalDrawBenchmark <iterations>=2\n".utf8))
    exit(2)
}

do {
    let report = try measureDrawBenchmarks(iterations: iterations)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(report))
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("draw benchmark failed: \(error)\n".utf8))
    exit(1)
}
