// Testable timing policy for the headless Terminal.feed benchmark executable.
import Dispatch
import Foundation
import TerminalCore

/// Captures fixed-batch samples while retaining totals needed to prove the duration floor.
public struct CoreBenchmarkMeasurements: Codable, Equatable, Sendable {
    /// The fixed number of fresh terminal executions represented by every sample.
    public let batchCount: Int
    /// Per-execution feed durations normalized from each fixed-batch total.
    public let feedDurationNanoseconds: [UInt64]
    /// Raw fixed-batch totals retained so the caller can verify the duration floor.
    public let sampleDurationNanoseconds: [UInt64]

    /// Keeps normalized values and their proof totals together across the executable boundary.
    public init(
        batchCount: Int,
        feedDurationNanoseconds: [UInt64],
        sampleDurationNanoseconds: [UInt64]
    ) {
        self.batchCount = batchCount
        self.feedDurationNanoseconds = feedDurationNanoseconds
        self.sampleDurationNanoseconds = sampleDurationNanoseconds
    }
}

/// Reports malformed length framing without coupling the harness to the suite process.
public enum CoreBenchmarkError: Error {
    case truncatedLength
    case truncatedChunk
}

/// Decodes unsigned 64-bit big-endian lengths followed by their exact fixture bytes.
public func decodeBenchmarkChunks(_ data: Data) throws -> [[UInt8]] {
    var offset = 0
    var chunks: [[UInt8]] = []
    while offset < data.count {
        guard data.count - offset >= 8 else {
            throw CoreBenchmarkError.truncatedLength
        }
        var length: UInt64 = 0
        for byte in data[offset..<(offset + 8)] {
            length = (length << 8) | UInt64(byte)
        }
        offset += 8
        guard length <= UInt64(data.count - offset) else {
            throw CoreBenchmarkError.truncatedChunk
        }
        let end = offset + Int(length)
        chunks.append(Array(data[offset..<end]))
        offset = end
    }
    return chunks
}

/// Measures only feed calls while recreating the fixed-geometry terminal for every execution.
public func measureFeedBatch(
    chunks: [[UInt8]],
    executionCount: Int,
    makeTerminal: () -> Terminal? = { Terminal(columns: 80, rows: 24) },
    now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
) -> UInt64 {
    var total: UInt64 = 0
    for _ in 0..<executionCount {
        guard var terminal = makeTerminal() else {
            fatalError("fixed benchmark geometry must be valid")
        }
        let start = now()
        for chunk in chunks {
            terminal.feed(chunk)
        }
        total += now() - start
    }
    return total
}

/// Repeats the same fresh-terminal feed boundary for profiler attachment.
@discardableResult
public func runSustainedFeed(
    maximumCycles: Int? = nil,
    feedCycle: () -> Void
) -> Int {
    var completed = 0
    while maximumCycles.map({ completed < $0 }) ?? true {
        feedCycle()
        completed += 1
    }
    return completed
}

/// Calibrates outside the reported samples, then retries with one fixed batch until every sample meets the floor.
public func measureDurationStableFeed(
    iterations: Int,
    targetNanoseconds: UInt64,
    measureBatch: (Int) -> UInt64
) -> CoreBenchmarkMeasurements {
    precondition(iterations >= 2)
    precondition(targetNanoseconds > 0)

    var batchCount = 1
    var calibration = measureBatch(batchCount)
    while calibration < targetNanoseconds {
        batchCount = scaledBatchCount(
            current: batchCount,
            observedNanoseconds: calibration,
            targetNanoseconds: targetNanoseconds
        )
        calibration = measureBatch(batchCount)
    }

    while true {
        let totals = (0..<iterations).map { _ in measureBatch(batchCount) }
        guard let shortest = totals.min(), shortest < targetNanoseconds else {
            return CoreBenchmarkMeasurements(
                batchCount: batchCount,
                feedDurationNanoseconds: totals.map { $0 / UInt64(batchCount) },
                sampleDurationNanoseconds: totals
            )
        }
        batchCount = scaledBatchCount(
            current: batchCount,
            observedNanoseconds: shortest,
            targetNanoseconds: targetNanoseconds
        )
    }
}

private func scaledBatchCount(
    current: Int,
    observedNanoseconds: UInt64,
    targetNanoseconds: UInt64
) -> Int {
    guard observedNanoseconds > 0 else { return current + 1 }
    let numerator = UInt64(current) * targetNanoseconds
    let scaled = (numerator + observedNanoseconds - 1) / observedNanoseconds
    return max(current + 1, Int(scaled))
}
