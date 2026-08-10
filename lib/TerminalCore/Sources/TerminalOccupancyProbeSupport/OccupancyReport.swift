// The result types the occupancy probe produces, and the arithmetic that summarizes a run.
//
// Split from the measurement so the summary can be unit-tested without a clock. Everything
// here is pure: samples in, statistics out.
import Foundation

/// One measured case: every wall-clock bracket taken for it, plus the statistics printed.
///
/// Keeps the raw millisecond list rather than only its summary, because the JSON mode exists
/// so a reader who did not run the probe can recompute the summary and disagree with it.
public struct OccupancySample: Sendable, Equatable {
    public let name: String
    public let milliseconds: [Double]

    public init(name: String, milliseconds: [Double]) {
        self.name = name
        self.milliseconds = milliseconds
    }

    public var iterations: Int { milliseconds.count }
    public var meanMilliseconds: Double {
        milliseconds.isEmpty ? 0 : milliseconds.reduce(0, +) / Double(milliseconds.count)
    }
    public var minMilliseconds: Double { milliseconds.min() ?? 0 }
    public var maxMilliseconds: Double { milliseconds.max() ?? 0 }

    /// The smallest mean this probe will turn into a rate.
    ///
    /// A bracket around a cache hit reads a few hundred nanoseconds, which is the timer's
    /// noise floor rather than a duration. Dividing it into 1000 yields a confident-looking
    /// throughput in the millions, printed beside a real key-repeat rate as though the two
    /// were comparable. Ten microseconds is well below anything on the owner queue worth
    /// naming and well above the floor.
    public static let rateResolutionMilliseconds = 0.01

    /// How many of this operation the owner queue can serve per second, or nil when it is
    /// too fast to have been meaningfully timed.
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
