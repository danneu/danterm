// Headless release-mode timing harness for duration-stable Terminal.feed samples.
import Foundation
import TerminalCoreBenchmarkSupport

let targetNanoseconds: UInt64 = 1_000_000_000

guard CommandLine.arguments.count == 2,
      let iterations = Int(CommandLine.arguments[1]),
      iterations >= 2 else {
    FileHandle.standardError.write(Data("usage: TerminalCoreBenchmark <iterations>=2\n".utf8))
    exit(2)
}

do {
    let chunks = try decodeBenchmarkChunks(FileHandle.standardInput.readDataToEndOfFile())
    let measurements = measureDurationStableFeed(
        iterations: iterations,
        targetNanoseconds: targetNanoseconds,
        measureBatch: { measureFeedBatch(chunks: chunks, executionCount: $0) }
    )
    let output = try JSONEncoder().encode(measurements)
    FileHandle.standardOutput.write(output)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("invalid benchmark input: \(error)\n".utf8))
    exit(2)
}
