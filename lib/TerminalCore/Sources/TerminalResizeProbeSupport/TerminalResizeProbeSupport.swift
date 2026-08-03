// The saturated-history resize probe: how long a width change costs on a full scrollback.
//
// `28/H1` asks an *absolute* question -- does a width change on a saturated
// history fit in a frame budget, and where does its time go -- and `28/D1`
// pitch 2 answered it with a deliberate refusal: this is a committed probe
// recipe, not a candidate workload. A paired workload would need two arms, and
// there is no pre-trim arm to compare against (the doc's evidence floor forbids
// wanting one). So this reports a distribution and no verdict; nothing here
// selects a threshold and nothing here decides anything.
//
// It exists as committed code because `15/F18`'s browsing probe was deleted
// after it was read, which cost this doc a whole re-implementation task
// (`28/F5`). A probe whose recipe is frozen in prose but whose code is gone is
// a recipe nobody can re-run.
//
// Belongs here: the saturation stimulus, the resize loop, and the distribution
// reduction. Does not belong here: a frame-budget comparison, a pass/fail, or
// anything paired -- upgrading this to a candidate workload is `D1`'s stated
// gate (a change *expected* to move resize cost, which gives the comparison a
// second arm), and a separate decision.
//
// Depends on `TerminalCore` alone. No planning, no rendering, no AppKit: a
// resize is an engine operation, and keeping the probe pure is what lets it run
// headless and under a profiler.
import Foundation
import TerminalCore

/// The probe's recipe, frozen as data so every number it prints names its shape.
///
/// `D1` pitch 2 required the recipe to state its geometry, budget, row count,
/// and repeat count. This type is that requirement made mechanical: the values
/// are carried into the emitted report, so a distribution can never be read
/// without the conditions that produced it.
public struct ResizeProbeRecipe: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let lineCount: Int
    /// Reported, not configurable. The budget-taking initializer is internal to
    /// `TerminalCore` (it exists to give deterministic tests a small budget), so
    /// this probe runs at the production budget and says so -- which is the
    /// budget H1's question is about anyway.
    public let scrollbackBudgetBytes: Int
    /// The width the probe alternates to and back from. Chosen wide-to-narrow
    /// rather than narrow-to-wide because narrowing is the direction that
    /// *reflows* content -- widening a canonical row mostly re-pads it.
    public let alternateColumns: Int
    /// Resize operations timed, counting both directions. Each is one sample.
    public let sampleCount: Int
    /// Untimed resizes run first, so the first sample is not charged for the
    /// scratch every later one reuses.
    public let warmupCount: Int

    /// The standard recipe: `15/F18`'s saturation geometry and payload at the
    /// production budget, alternating 179 <-> 100 columns.
    ///
    /// The stimulus is deliberately the browsing workload's, so a reader
    /// comparing this probe against `28/F5`'s numbers is looking at the same
    /// history rather than two differently-shaped ones.
    public static let standard = ResizeProbeRecipe(
        columns: 179, rows: 66, lineCount: 10_000,
        scrollbackBudgetBytes: Terminal.productionScrollbackBudgetBytes,
        alternateColumns: 100, sampleCount: 40, warmupCount: 4
    )

    public init(
        columns: Int, rows: Int, lineCount: Int, scrollbackBudgetBytes: Int,
        alternateColumns: Int, sampleCount: Int, warmupCount: Int
    ) {
        self.columns = columns
        self.rows = rows
        self.lineCount = lineCount
        self.scrollbackBudgetBytes = scrollbackBudgetBytes
        self.alternateColumns = alternateColumns
        self.sampleCount = sampleCount
        self.warmupCount = warmupCount
    }

    /// The identity a report claims, so a changed shape is a changed identity.
    public var identity: String {
        "saturated-resize-v1-\(lineCount)-lines-\(columns)x\(rows)-to-\(alternateColumns)"
    }
}

/// A resize-cost distribution, reported instead of a single number.
///
/// `D1` pitch 2 required a distribution rather than a point estimate, and the
/// reason is the question: "does this fit in a frame budget" is answered by the
/// tail, not the median. Every raw sample is retained so a later reader can
/// re-reduce them under different quantiles without re-running the probe --
/// `20/F12` is the standing example of an artifact that had to be recovered by
/// hand because only a summary was kept.
public struct ResizeProbeDistribution: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let minimumNanoseconds: UInt64
    public let medianNanoseconds: UInt64
    public let p90Nanoseconds: UInt64
    public let p99Nanoseconds: UInt64
    public let maximumNanoseconds: UInt64
    public let meanNanoseconds: UInt64
    /// Every timed resize, in collection order, alternating narrow and wide.
    public let samplesNanoseconds: [UInt64]

    /// Reduces raw samples, or reports an empty distribution rather than a zero.
    ///
    /// Zeros would read as "instant" to anyone scanning the report; the empty
    /// count is what says "not measured", which is the distinction the
    /// measurement-discipline rule this doc binds itself to insists on.
    public init(samplesNanoseconds: [UInt64]) {
        self.samplesNanoseconds = samplesNanoseconds
        let ordered = samplesNanoseconds.sorted()
        sampleCount = ordered.count
        guard ordered.isEmpty == false else {
            minimumNanoseconds = 0
            medianNanoseconds = 0
            p90Nanoseconds = 0
            p99Nanoseconds = 0
            maximumNanoseconds = 0
            meanNanoseconds = 0
            return
        }
        minimumNanoseconds = ordered[0]
        maximumNanoseconds = ordered[ordered.count - 1]
        medianNanoseconds = Self.quantile(ordered, 0.50)
        p90Nanoseconds = Self.quantile(ordered, 0.90)
        p99Nanoseconds = Self.quantile(ordered, 0.99)
        meanNanoseconds = ordered.reduce(UInt64(0), &+) / UInt64(ordered.count)
    }

    /// Nearest-rank quantile: an order statistic, never an interpolated value.
    ///
    /// A real observed sample is the honest answer for a tail question -- an
    /// interpolated p99 over 40 samples reports a duration that never occurred.
    static func quantile(_ ordered: [UInt64], _ fraction: Double) -> UInt64 {
        let rank = Int((fraction * Double(ordered.count)).rounded(.up))
        return ordered[min(max(rank, 1), ordered.count) - 1]
    }
}

/// One probe run: the recipe, what it actually saturated, and the distribution.
public struct ResizeProbeReport: Codable, Equatable, Sendable {
    public let recipeIdentity: String
    public let columns: Int
    public let rows: Int
    public let lineCount: Int
    public let scrollbackBudgetBytes: Int
    public let alternateColumns: Int
    public let warmupCount: Int
    /// Retained rows present when timing began. Reported because the budget, not
    /// `lineCount`, decides it -- a recipe that stopped saturating would show up
    /// here rather than silently measuring a shallow history.
    public let retainedRowCountAtStart: Int
    public let distribution: ResizeProbeDistribution

    public init(
        recipeIdentity: String, columns: Int, rows: Int, lineCount: Int,
        scrollbackBudgetBytes: Int, alternateColumns: Int, warmupCount: Int,
        retainedRowCountAtStart: Int, distribution: ResizeProbeDistribution
    ) {
        self.recipeIdentity = recipeIdentity
        self.columns = columns
        self.rows = rows
        self.lineCount = lineCount
        self.scrollbackBudgetBytes = scrollbackBudgetBytes
        self.alternateColumns = alternateColumns
        self.warmupCount = warmupCount
        self.retainedRowCountAtStart = retainedRowCountAtStart
        self.distribution = distribution
    }
}

/// Builds a terminal whose scrollback is saturated against the recipe's budget.
///
/// Separate from the timing loop so a test can assert the precondition the whole
/// probe rests on -- that history is budget-saturated rather than merely deep --
/// which is the one way this probe could silently degrade into a measurement of
/// resizing a small history.
public func makeSaturatedTerminal(recipe: ResizeProbeRecipe = .standard) -> Terminal {
    // Force-unwrapped deliberately: the only failure is a geometry or budget no
    // terminal accepts, and both are frozen constants of the recipe. A nil here
    // is a bug in the constant, not a runtime condition.
    var terminal = Terminal(columns: recipe.columns, rows: recipe.rows)!
    for line in 0..<recipe.lineCount {
        terminal.feed(
            Array(
                "DANTERM-RESIZE-\(String(format: "%05d", line)) plain ascii retained row\r\n".utf8
            )
        )
    }
    return terminal
}

/// Times `sampleCount` width changes on a saturated history and reports the spread.
///
/// Alternates between the two widths rather than resizing to the same width
/// repeatedly: a no-op resize is free and would measure nothing. Each direction
/// is timed separately and both land in one distribution, because H1's question
/// is about the cost a user's window drag pays, and a drag pays both.
public func measureSaturatedResize(
    recipe: ResizeProbeRecipe = .standard,
    now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
) -> ResizeProbeReport {
    var terminal = makeSaturatedTerminal(recipe: recipe)
    let widths = [recipe.alternateColumns, recipe.columns]

    for index in 0..<recipe.warmupCount {
        terminal.resize(columns: widths[index % 2], rows: recipe.rows)
    }
    // Read after warming: the warm resizes reflow, and reflow changes how many
    // rows the same bytes buy. This is the depth the timed samples actually run
    // against, which is the number worth reporting.
    let retainedAtStart = terminal.scrollbackRowCount

    var samples: [UInt64] = []
    samples.reserveCapacity(recipe.sampleCount)
    for index in 0..<recipe.sampleCount {
        let width = widths[(recipe.warmupCount + index) % 2]
        let started = now()
        terminal.resize(columns: width, rows: recipe.rows)
        samples.append(now() &- started)
    }

    return ResizeProbeReport(
        recipeIdentity: recipe.identity,
        columns: recipe.columns, rows: recipe.rows, lineCount: recipe.lineCount,
        scrollbackBudgetBytes: recipe.scrollbackBudgetBytes,
        alternateColumns: recipe.alternateColumns, warmupCount: recipe.warmupCount,
        retainedRowCountAtStart: retainedAtStart,
        distribution: ResizeProbeDistribution(samplesNanoseconds: samples)
    )
}
