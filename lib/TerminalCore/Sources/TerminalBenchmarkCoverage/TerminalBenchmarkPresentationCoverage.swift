// Continuous foreground/presentation coverage accounting for profiling runs.
//
// A profile of a live, input-driven workload is only attributable if the app
// really was the frontmost application, with its canonical window on screen and
// unoccluded, for the whole recorded interval. Anything else -- a notification
// panel taking focus, a covering window, a space switch -- changes what the app
// draws and therefore what the profiler attributes, without changing any counter
// the harness already publishes. This file counts that condition instead of
// asserting it: the app-side publisher takes one sample per published activity
// snapshot, and a reader that differences two snapshots learns both how many
// samples the interval contains and how many of them lapsed.
//
// Counting rather than latching is what lets missing measurement stay
// distinguishable from measured zero: an interval with no samples proves
// nothing, which is not the same claim as an interval that was sampled and
// never lapsed.
//
// It lives in the library, beside the other benchmark accounting, because the
// counting rules are the part worth pinning under a headless test; the app-side
// observer keeps only the AppKit probes that produce the two booleans.
//
// Belongs here: how samples and lapses are counted and what the activity
// snapshot publishes. Does not belong here: how the booleans are obtained (that
// is AppKit), the publish cadence, or the validity verdict a bounded capture
// derives from two snapshots.

/// Counts continuous foreground/presentation samples so a profiling window can
/// prove -- not assume -- that the measured app stayed presented and frontmost.
///
/// The counters are cumulative for the app's lifetime and never reset, matching
/// the lifetime draw counters they are published beside: a reader brackets a
/// profiling window with two snapshots and subtracts, so a mid-run reset would
/// make an interval's sample count meaningless.
public struct TerminalBenchmarkPresentationCoverageRecorder {
    public private(set) var sampleCount = 0
    public private(set) var foregroundSampleCount = 0
    public private(set) var presentedSampleCount = 0

    public init() {}

    /// Records one sample of the two conditions a valid capture requires.
    ///
    /// A lapsed sample still advances `sampleCount`, which is what keeps "the app
    /// lost foreground" distinguishable from "nobody sampled this interval".
    public mutating func record(isForeground: Bool, isPresented: Bool) {
        sampleCount += 1
        if isForeground { foregroundSampleCount += 1 }
        if isPresented { presentedSampleCount += 1 }
    }

    /// Publishes the cumulative counters in the activity snapshot's own shape, so
    /// the JSON keys a bounded capture differences are fixed here rather than at
    /// the app-side write.
    public func artifact() -> [String: Any] {
        [
            "sampleCount": sampleCount,
            "foregroundSampleCount": foregroundSampleCount,
            "presentedSampleCount": presentedSampleCount,
        ]
    }
}
