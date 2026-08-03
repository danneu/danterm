// Headless frame planning over *retained* history, which no calibrated workload reaches.
//
// The five routine workloads all plan from a live grid: `scrollback-stream`
// follows the bottom, and the three serialized-draw workloads start from the
// current screen. Nothing on the ladder scrolls back and plans a frame whose
// rows come out of scrollback storage -- so the one measurement that most
// motivated compact retained rows (`15/F18`, -5.79% on browsing frame planning)
// rested on a temporary probe that was deleted right after it was read, and
// cannot be re-run. `28/D1` pitch 1 admitted this workload to end that.
//
// Belongs here: the browsing stimulus (geometry, payload, where the viewport is
// parked), the warm/measure loop, and the checksum that proves both arms planned
// the same cells. Does not belong here: any decision rule -- this is a
// *candidate* workload, so it collects descriptively and a human moves a
// screened threshold into the frozen table, per `20`'s precedent and `23/D4`'s
// worked example.
//
// Deliberately depends on `TerminalCore` and `TerminalRenderPlanning` only. No
// AppKit, no CoreGraphics, no window: planning is pure, and keeping the harness
// pure is what lets it run headless in CI and under a profiler without a
// WindowServer connection.
import Foundation
import TerminalCore
import TerminalRenderPlanning

/// The browsing stimulus, frozen as data so a changed shape is a changed identity.
///
/// Stated as one value rather than scattered literals because the collector
/// validates the identity string the runner claims: an arm that quietly changed
/// the geometry or the payload would have to change this too, so a block
/// collected under an older shape cannot pass as one collected under this one.
public struct BrowseBenchmarkStimulus: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let lineCount: Int

    /// `15/F18`'s recipe exactly: identical 179x66 terminals, 10,000 short
    /// hard-terminated lines, browsed from the oldest retained row. Reproduced
    /// rather than re-derived so this workload's numbers are comparable in kind
    /// with the descriptive result it replaces.
    public static let standard = BrowseBenchmarkStimulus(
        columns: 179, rows: 66, lineCount: 10_000
    )

    public init(columns: Int, rows: Int, lineCount: Int) {
        self.columns = columns
        self.rows = rows
        self.lineCount = lineCount
    }

    /// The identity a block claims and the collector checks.
    public var identity: String {
        "retained-browse-v1-\(lineCount)-lines-oldest-row-\(columns)x\(rows)"
    }
}

/// One measured browsing series, plus the evidence that it measured what it says.
public struct BrowseBenchmarkMeasurements: Codable, Equatable, Sendable {
    public let stimulusIdentity: String
    public let retainedRowCount: Int
    /// Cells the plan actually covered, summed across the measured calls. Both
    /// arms must report the same value or they did not plan the same frame --
    /// this is `15/F18`'s checksum obligation, kept.
    public let planCellChecksum: UInt64
    public let warmupCount: Int
    public let measuredCount: Int
    /// Total nanoseconds for `measuredCount` full `planFrame` calls.
    public let planDurationNanoseconds: UInt64
    /// The normalized per-frame quantity the comparison pairs on.
    public let planNanosecondsPerFrame: UInt64

    public init(
        stimulusIdentity: String,
        retainedRowCount: Int,
        planCellChecksum: UInt64,
        warmupCount: Int,
        measuredCount: Int,
        planDurationNanoseconds: UInt64,
        planNanosecondsPerFrame: UInt64
    ) {
        self.stimulusIdentity = stimulusIdentity
        self.retainedRowCount = retainedRowCount
        self.planCellChecksum = planCellChecksum
        self.warmupCount = warmupCount
        self.measuredCount = measuredCount
        self.planDurationNanoseconds = planDurationNanoseconds
        self.planNanosecondsPerFrame = planNanosecondsPerFrame
    }
}

/// Builds a terminal holding `lineCount` retained lines, parked at the oldest one.
///
/// Separate from the measurement so a test can assert the browsing precondition
/// -- that the viewport really is off the live grid and over scrollback -- which
/// is the one way this workload could silently degrade into a duplicate of the
/// live-grid workloads already on the ladder.
public func makeBrowsingTerminal(
    stimulus: BrowseBenchmarkStimulus = .standard
) -> Terminal {
    // Force-unwrapped deliberately: the only failure is a geometry no terminal
    // cell can be represented at, and this workload's geometry is a frozen
    // constant. A nil here is a bug in the constant, not a runtime condition.
    var terminal = Terminal(columns: stimulus.columns, rows: stimulus.rows)!
    for line in 0..<stimulus.lineCount {
        terminal.feed(
            Array(
                "DANTERM-BROWSE-\(String(format: "%05d", line)) plain ascii retained row\r\n".utf8
            )
        )
    }
    // Row 0 in current-stream coordinates is the oldest row still retained after
    // the budget evicted, so this parks the whole viewport in scrollback storage
    // rather than merely near it.
    terminal.scroll(toTopRow: 0)
    return terminal
}

/// Reduces one plan to a number both arms must agree on.
///
/// Counts covered cells rather than hashing colors: the point is to prove the
/// two arms traversed the same viewport, and a representation change is allowed
/// to alter run boundaries without altering the cells those runs cover.
public func planCellCoverage(_ plan: RenderFramePlan) -> UInt64 {
    var total: UInt64 = 0
    for run in plan.textRuns {
        total &+= UInt64(run.cells.count)
    }
    for run in plan.backgroundRuns {
        total &+= UInt64(run.columnCount)
    }
    return total
}

/// Times `measuredCount` full frame plans over retained history, after warming.
///
/// Warms first because the first plans allocate the retained-row scratch the
/// later ones reuse; measuring those would charge one arm for an allocation the
/// other already paid. `15/F18` used 20 warm and 2,000 measured calls, and those
/// counts are kept so the two results are comparable.
public func measureBrowsingPlan(
    stimulus: BrowseBenchmarkStimulus = .standard,
    warmupCount: Int = 20,
    measuredCount: Int = 2_000,
    now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
) -> BrowseBenchmarkMeasurements {
    let terminal = makeBrowsingTerminal(stimulus: stimulus)
    let presentation = RenderPresentation(
        theme: .dark, isCursorVisible: false, cursorShape: .block
    )

    var checksum: UInt64 = 0
    for _ in 0..<warmupCount {
        checksum &+= planCellCoverage(planFrame(for: terminal, presentation: presentation))
    }
    checksum = 0

    let started = now()
    for _ in 0..<measuredCount {
        checksum &+= planCellCoverage(planFrame(for: terminal, presentation: presentation))
    }
    let elapsed = now() &- started

    return BrowseBenchmarkMeasurements(
        stimulusIdentity: stimulus.identity,
        retainedRowCount: terminal.scrollbackRowCount,
        planCellChecksum: checksum,
        warmupCount: warmupCount,
        measuredCount: measuredCount,
        planDurationNanoseconds: elapsed,
        planNanosecondsPerFrame: measuredCount > 0
            ? elapsed / UInt64(measuredCount)
            : 0
    )
}
