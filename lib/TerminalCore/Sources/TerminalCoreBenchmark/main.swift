// Headless release-mode timing harness for duration-stable Terminal.feed samples, plus the
// two commands that let the Python collector build a kitten arm's stimulus from this same
// binary: `generate` writes one arm's framed fixture, `describe` prints what the port encodes.
import Foundation
import KittenFeedFixture
import TerminalCoreBenchmarkSupport

// The floor a collected block is judged against (`minimumBlockNanoseconds` in
// `scripts/terminal-benchmark-validation.py`'s block contracts). Calibration aims above
// it, not at it -- see `measureDurationStable`.
let blockFloorNanoseconds: UInt64 = 1_000_000_000

let usage = """
    usage: TerminalCoreBenchmark <iterations>=2|--fixed <execution-count> <iterations>=1|--profile
           TerminalCoreBenchmark generate <arm>
           TerminalCoreBenchmark describe

    """

func fail() -> Never {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}

/// Frames one chunk the way `decodeBenchmarkFixture` reads it: phase byte, big-endian
/// length, bytes. Empty phases emit nothing, so an arm without teardown stays legal.
func frame(_ phase: CoreBenchmarkPhase, _ bytes: [UInt8]) -> Data {
    guard !bytes.isEmpty else { return Data() }
    var framed = Data([phase.rawValue])
    framed.append(contentsOf: withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { Array($0) })
    framed.append(contentsOf: bytes)
    return framed
}

guard CommandLine.arguments.count >= 2 else { fail() }

if CommandLine.arguments[1] == "generate" {
    guard
        CommandLine.arguments.count == 3,
        let arm = KittenFeedArm(rawValue: CommandLine.arguments[2])
    else { fail() }
    let stream = KittenFeedGenerator.stream(for: arm)
    FileHandle.standardOutput.write(frame(.setup, stream.setup))
    FileHandle.standardOutput.write(frame(.timed, stream.timed))
    FileHandle.standardOutput.write(frame(.teardown, stream.teardown))
    exit(0)
}

if CommandLine.arguments[1] == "describe" {
    guard CommandLine.arguments.count == 2 else { fail() }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
        FileHandle.standardOutput.write(try encoder.encode(KittenFeedGenerator.parameters()))
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("cannot describe kitten feed arms: \(error)\n".utf8))
        exit(2)
    }
    exit(0)
}

do {
    let fixture = try decodeBenchmarkFixture(FileHandle.standardInput.readDataToEndOfFile())
    if CommandLine.arguments[1] == "--profile" {
        guard CommandLine.arguments.count == 2 else { fail() }
        runSustainedFeed {
            _ = measureFeedBatch(fixture: fixture, executionCount: 1)
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
        else { fail() }
        let totals = (0..<iterations).map { _ in
            measureFeedBatch(fixture: fixture, executionCount: executionCount)
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
        else { fail() }
        measurements = measureDurationStableFeed(
            iterations: iterations,
            floorNanoseconds: blockFloorNanoseconds,
            measureBatch: { measureFeedBatch(fixture: fixture, executionCount: $0) }
        )
    }
    let output = try JSONEncoder().encode(measurements)
    FileHandle.standardOutput.write(output)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("invalid benchmark input: \(error)\n".utf8))
    exit(2)
}
