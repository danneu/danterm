// Headless release-mode timing harness for duration-stable Terminal.feed samples.
import Foundation
import TerminalCoreBenchmarkSupport

let targetNanoseconds: UInt64 = 1_000_000_000

let usage = "usage: TerminalCoreBenchmark <iterations>=2|--fixed <execution-count> <iterations>=1|--profile>\n"

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}

do {
    let chunks = try decodeBenchmarkChunks(FileHandle.standardInput.readDataToEndOfFile())
    if CommandLine.arguments[1] == "--profile" {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data(usage.utf8))
            exit(2)
        }
        runSustainedFeed {
            _ = measureFeedBatch(chunks: chunks, executionCount: 1)
        }
        exit(0)
    }
    let measurements: CoreBenchmarkMeasurements
    if CommandLine.arguments[1] == "--fixed" {
        guard
            CommandLine.arguments.count == 4,
            let executionCount = Int(CommandLine.arguments[2]),
            executionCount >= 1,
            let iterations = Int(CommandLine.arguments[3]),
            iterations >= 1
        else {
            FileHandle.standardError.write(Data(usage.utf8))
            exit(2)
        }
        let totals = (0..<iterations).map { _ in
            measureFeedBatch(chunks: chunks, executionCount: executionCount)
        }
        measurements = CoreBenchmarkMeasurements(
            batchCount: executionCount,
            feedDurationNanoseconds: totals.map { $0 / UInt64(executionCount) },
            sampleDurationNanoseconds: totals
        )
    } else {
        guard
            CommandLine.arguments.count == 2,
            let iterations = Int(CommandLine.arguments[1]),
            iterations >= 2
        else {
            FileHandle.standardError.write(Data(usage.utf8))
            exit(2)
        }
        measurements = measureDurationStableFeed(
            iterations: iterations,
            targetNanoseconds: targetNanoseconds,
            measureBatch: { measureFeedBatch(chunks: chunks, executionCount: $0) }
        )
    }
    let output = try JSONEncoder().encode(measurements)
    FileHandle.standardOutput.write(output)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("invalid benchmark input: \(error)\n".utf8))
    exit(2)
}
