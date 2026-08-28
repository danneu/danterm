// Testable timing policy for the headless benchmark executables: the duration-floor
// calibration both the Terminal.feed and draw benchmarks measure against, plus the
// feed benchmark's own sampling and reporting shape.
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

/// Reports malformed framing without coupling the harness to the suite process.
public enum CoreBenchmarkError: Error, Equatable {
    case truncatedLength
    case truncatedChunk
    case unknownPhase(UInt8)
}

/// Which side of the clock a framed chunk falls on. A fixture that wraps its stimulus in
/// terminal setup and teardown -- the kitten arms do -- must not charge those bytes to the
/// measurement, because the run being reproduced does not charge them either.
public enum CoreBenchmarkPhase: UInt8, Sendable {
    case setup = 0
    case timed = 1
    case teardown = 2
}

/// A framed fixture grouped by phase. Grouping happens once at decode so the measurement
/// loop reads the clock exactly twice per execution: a per-chunk clock read would add
/// overhead that scales with chunk count and would change what the already-calibrated
/// workloads report.
public struct CoreBenchmarkFixture: Equatable, Sendable {
    public let setup: [[UInt8]]
    public let timed: [[UInt8]]
    public let teardown: [[UInt8]]

    public init(setup: [[UInt8]] = [], timed: [[UInt8]] = [], teardown: [[UInt8]] = []) {
        self.setup = setup
        self.timed = timed
        self.teardown = teardown
    }
}

/// Decodes frames of one phase byte, an unsigned 64-bit big-endian length, and that many
/// fixture bytes.
public func decodeBenchmarkFixture(_ data: Data) throws -> CoreBenchmarkFixture {
    var offset = 0
    var setup: [[UInt8]] = []
    var timed: [[UInt8]] = []
    var teardown: [[UInt8]] = []
    while offset < data.count {
        guard data.count - offset >= 9 else {
            throw CoreBenchmarkError.truncatedLength
        }
        let phaseByte = data[data.startIndex + offset]
        guard let phase = CoreBenchmarkPhase(rawValue: phaseByte) else {
            throw CoreBenchmarkError.unknownPhase(phaseByte)
        }
        offset += 1
        var length: UInt64 = 0
        for byte in data[(data.startIndex + offset)..<(data.startIndex + offset + 8)] {
            length = (length << 8) | UInt64(byte)
        }
        offset += 8
        guard length <= UInt64(data.count - offset) else {
            throw CoreBenchmarkError.truncatedChunk
        }
        let end = offset + Int(length)
        let chunk = Array(data[(data.startIndex + offset)..<(data.startIndex + end)])
        switch phase {
        case .setup: setup.append(chunk)
        case .timed: timed.append(chunk)
        case .teardown: teardown.append(chunk)
        }
        offset = end
    }
    return CoreBenchmarkFixture(setup: setup, timed: timed, teardown: teardown)
}

/// Measures only the timed phase's feed calls while recreating the fixed-geometry terminal
/// for every execution. Setup and teardown are fed into the same terminal, so the timed
/// phase parses against the state they establish, but they are outside the clock.
public func measureFeedBatch(
    fixture: CoreBenchmarkFixture,
    executionCount: Int,
    makeTerminal: () -> Terminal? = { Terminal(columns: 179, rows: 66) },
    now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
) -> UInt64 {
    var total: UInt64 = 0
    for _ in 0..<executionCount {
        guard var terminal = makeTerminal() else {
            fatalError("fixed benchmark geometry must be valid")
        }
        for chunk in fixture.setup {
            terminal.feed(chunk)
        }
        let start = now()
        for chunk in fixture.timed {
            terminal.feed(chunk)
        }
        total += now() - start
        for chunk in fixture.teardown {
            terminal.feed(chunk)
        }
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

/// How far above the floor calibration aims, as a fraction of the floor.
///
/// The collector validates every block against the same floor this policy calibrates to, so
/// aiming *at* the floor picks the first batch count that clears it and leaves the achieved
/// margin to whatever batch-count discreteness happens to give. `kitten-feed-unicode` costs
/// ~167 ms per execution, so six executions landed at 1.003 s against a 1.000 s floor and
/// roughly half its blocks were discarded as `block-below-duration-floor`. Aiming higher makes
/// a below-floor block mean an actual machine disturbance, which is the only thing that
/// discard is meant to detect. One fifth is far beyond the block-to-block spread measured on
/// every feed arm (0.4% to 2%) and costs proportionally more machine time per block.
private let calibrationMarginFraction: UInt64 = 5

/// The duration-floor policy every reported sample in both benchmark executables rests on:
/// calibrate outside the reported samples, then retry with one fixed batch until every sample
/// clears the floor by `calibrationMarginFraction`. Public because the draw benchmark runs the
/// same policy over a different batch body -- keeping one copy is the point, since a drift here
/// silently changes what both benchmarks report.
///
/// `floorNanoseconds` is the value a sample is later judged against, not the value calibration
/// aims for; passing the judged floor is what keeps the margin from being lost at a call site.
public func measureDurationStable(
    iterations: Int,
    floorNanoseconds: UInt64,
    measureBatch: (Int) -> UInt64
) -> (batchCount: Int, totals: [UInt64]) {
    precondition(iterations >= 2)
    precondition(floorNanoseconds > 0)
    let targetNanoseconds = floorNanoseconds + floorNanoseconds / calibrationMarginFraction

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
            return (batchCount, totals)
        }
        batchCount = scaledBatchCount(
            current: batchCount,
            observedNanoseconds: shortest,
            targetNanoseconds: targetNanoseconds
        )
    }
}

/// Wraps the shared floor policy in the feed benchmark's reporting shape.
public func measureDurationStableFeed(
    iterations: Int,
    floorNanoseconds: UInt64,
    measureBatch: (Int) -> UInt64
) -> CoreBenchmarkMeasurements {
    let stable = measureDurationStable(
        iterations: iterations,
        floorNanoseconds: floorNanoseconds,
        measureBatch: measureBatch
    )
    return CoreBenchmarkMeasurements(
        batchCount: stable.batchCount,
        feedDurationNanoseconds: stable.totals.map { $0 / UInt64(stable.batchCount) },
        sampleDurationNanoseconds: stable.totals
    )
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
