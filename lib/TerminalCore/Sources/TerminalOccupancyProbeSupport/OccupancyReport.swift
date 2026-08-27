// The result types the occupancy probe produces, and the arithmetic that summarizes a run.
//
// Split from the measurement so the summary can be unit-tested without a clock. Everything
// here is pure: samples in, statistics out.
import Foundation
import TerminalProbeArguments

/// One measured case: every wall-clock bracket taken for it, plus the statistics printed.
///
/// Keeps the raw millisecond list rather than only its summary, because the JSON mode exists
/// so a reader who did not run the probe can recompute the summary and disagree with it.
///
/// The first measurement is a stored field and the rest are a list, so a sample with nothing in
/// it cannot be built. That is not tidiness: with an empty list the mean was zero, a zero mean
/// is below `rateResolutionMilliseconds`, and the CLI prints that as "faster than this probe can
/// time" -- so a run that measured nothing and a run that was too fast to time said the same
/// words. Holding the first measurement apart is what deletes the fallbacks that made them
/// indistinguishable.
public struct OccupancySample: Sendable, Equatable {
    public let name: String
    public let firstMilliseconds: Double
    public let laterMilliseconds: [Double]

    public init(name: String, first: Double, rest: [Double] = []) {
        self.name = name
        self.firstMilliseconds = first
        self.laterMilliseconds = rest
    }

    /// Every bracket in collection order, which is the shape the JSON mode publishes.
    public var milliseconds: [Double] { [firstMilliseconds] + laterMilliseconds }

    public var iterations: Int { laterMilliseconds.count + 1 }
    public var meanMilliseconds: Double {
        laterMilliseconds.reduce(firstMilliseconds, +) / Double(iterations)
    }
    public var minMilliseconds: Double { laterMilliseconds.reduce(firstMilliseconds, Swift.min) }
    public var maxMilliseconds: Double { laterMilliseconds.reduce(firstMilliseconds, Swift.max) }

    /// The smallest mean this probe will turn into a rate.
    ///
    /// A bracket around a cache hit reads a few hundred nanoseconds, which is the timer's
    /// noise floor rather than a duration. Dividing it into 1000 yields a confident-looking
    /// throughput in the millions, printed beside a real key-repeat rate as though the two
    /// were comparable. Ten microseconds is well below anything on the owner queue worth
    /// naming and well above the floor.
    public static let rateResolutionMilliseconds = 0.01

    /// How many of this operation the owner queue can serve per second, or nil when it is
    /// too fast to have been meaningfully timed -- which is the only thing nil means, because
    /// a sample with no measurements is not constructible.
    ///
    /// Reported rather than left to the reader because doc 19's argument is a comparison
    /// against macOS key-repeat arrival (15/s default, 66/s fastest), and a reciprocal is
    /// easy to invert by accident in a way a table hides. Nil rather than a large number:
    /// a cached navigation step legitimately reads 0.00 ms, and that is the success case --
    /// the caller should say so in words instead of implying a measurement.
    public var operationsPerSecond: Double? {
        let mean = meanMilliseconds
        return mean >= Self.rateResolutionMilliseconds ? 1000 / mean : nil
    }
}

/// A whole probe run: the pane it measured, and every case it measured on that pane.
public struct OccupancyReport: Sendable {
    public let columns: Int
    public let rows: Int
    public let cellCount: Int
    public let historyRowCount: Int
    public let samples: [OccupancySample]

    public init(
        columns: Int,
        rows: Int,
        cellCount: Int,
        historyRowCount: Int,
        samples: [OccupancySample]
    ) {
        self.columns = columns
        self.rows = rows
        self.cellCount = cellCount
        self.historyRowCount = historyRowCount
        self.samples = samples
    }
}

/// Brackets one operation in wall-clock, per doc 19's inverted rule.
///
/// Wall-clock and not on-CPU deliberately: a job that blocks holds the owner queue exactly
/// as hard as one that burns CPU, and the main-thread fence pays for both identically, so an
/// on-CPU instrument would understate precisely the jobs this probe exists to find.
public func measureOccupancyMilliseconds(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}
