// Behavioral tests for the retained-history browsing candidate workload.
//
// These pin the two properties that make the workload worth having: the
// viewport really sits over retained history (otherwise it duplicates workloads
// already on the ladder), and both arms plan the same cells (otherwise a paired
// difference is comparing two different frames). Timing is not asserted -- this
// is a candidate workload with no frozen rule, and asserting a duration in a
// unit test would invent the threshold `research/28/D1` deliberately withheld.
import Testing
import TerminalCore
import TerminalRenderPlanning
@testable import TerminalBrowseBenchmarkSupport

@Suite("Retained-history browsing benchmark stimulus")
struct TerminalBrowseBenchmarkSupportTests {
    @Test("The browsing terminal parks its whole viewport over retained history")
    func browsingTerminalIsOffTheLiveGrid() {
        // Intent: after setup, every visible row comes from scrollback storage
        //   rather than the live grid.
        // Why it exists: this is the entire reason the workload was admitted --
        //   `research/28/D1` pitch 1 records that no calibrated workload displays retained
        //   history. If setup silently left the viewport following the bottom,
        //   the workload would still collect and still pair, and would quietly be
        //   a slower duplicate of the live-grid planning already measured.
        let stimulus = BrowseBenchmarkStimulus.standard
        let terminal = makeBrowsingTerminal(stimulus: stimulus)

        #expect(terminal.scrollbackRowCount > 0)
        let projection = terminal.scrollProjection
        #expect(projection.isFollowing == false)
        #expect(projection.topRow == 0)
        // The viewport is a full window of retained rows, not a partial overlap
        // with the live grid.
        #expect(terminal.scrollbackRowCount >= stimulus.rows)
    }

    @Test("A browsing frame plan covers cells, so the checksum can separate two arms")
    func browsingPlanCoversCells() {
        // Intent: the plan produced over retained history is non-empty, and the
        //   coverage reduction returns a positive, repeatable number.
        // Why it exists: the checksum is the workload's only proof that two arms
        //   planned the same frame -- `research/15/F18` carried that obligation and this
        //   workload inherits it. A checksum that were always zero would compare
        //   equal across any change and silently validate nothing.
        let terminal = makeBrowsingTerminal()
        let presentation = RenderPresentation(
            theme: .dark, isCursorVisible: false, cursorShape: .block
        )

        let first = planCellCoverage(planFrame(for: terminal, presentation: presentation))
        let second = planCellCoverage(planFrame(for: terminal, presentation: presentation))

        #expect(first > 0)
        #expect(first == second)
    }

    @Test("A measured series reports the same checksum for every frame it timed")
    func measuredSeriesChecksumScalesWithFrameCount() {
        // Intent: the reported checksum is the per-frame coverage summed over
        //   exactly the measured frames, and excludes the warmup ones.
        // Why it exists: warmup frames are deliberately excluded from timing, so
        //   a checksum that included them would disagree between two arms that
        //   warmed differently and would flag a false content divergence.
        let stimulus = BrowseBenchmarkStimulus.standard
        let terminal = makeBrowsingTerminal(stimulus: stimulus)
        let presentation = RenderPresentation(
            theme: .dark, isCursorVisible: false, cursorShape: .block
        )
        let perFrame = planCellCoverage(
            planFrame(for: terminal, presentation: presentation)
        )

        let measured = measureBrowsingPlan(
            stimulus: stimulus, warmupCount: 2, measuredCount: 3
        )

        #expect(measured.planCellChecksum == perFrame &* 3)
        #expect(measured.measuredCount == 3)
        #expect(measured.warmupCount == 2)
    }

    @Test("The stimulus identity names the shape a block claims to have measured")
    func stimulusIdentityNamesItsShape() {
        // Intent: the identity string carries the geometry and the line count.
        // Why it exists: the collector validates the identity a block claims, so
        //   the string is what stops a block collected under an older stimulus
        //   from passing as one collected under the current shape. A constant
        //   identity would defeat that check entirely.
        #expect(
            BrowseBenchmarkStimulus.standard.identity
                == "retained-browse-v1-10000-lines-oldest-row-179x66"
        )
        let narrower = BrowseBenchmarkStimulus(columns: 80, rows: 24, lineCount: 500)
        #expect(narrower.identity != BrowseBenchmarkStimulus.standard.identity)
    }

    @Test("A measured series normalizes its duration to one frame")
    func measuredSeriesNormalizesPerFrame() {
        // Intent: the paired metric is nanoseconds per frame, derived from the
        //   total and the frame count.
        // Why it exists: the comparison pairs on a normalized quantity, so a
        //   block reporting a cumulative total would make two blocks with
        //   different frame counts look like a performance difference.
        var tick: UInt64 = 0
        let measured = measureBrowsingPlan(
            warmupCount: 1,
            measuredCount: 4,
            now: {
                tick &+= 1_000
                return tick
            }
        )

        #expect(
            measured.planNanosecondsPerFrame
                == measured.planDurationNanoseconds / 4
        )
    }

    @Test("A measured series scales one frame's coverage by the frames it timed")
    func measuredSeriesScalesCoverageByFrameCount() {
        // Intent: the reported per-frame coverage is the coverage of a single
        //   plan, and the checksum is that value times `measuredCount`, for any
        //   frame count including zero.
        // Why it exists: the coverage walk is the instrument, and it is computed
        //   once outside the timed bracket. An accumulator summed inside the loop
        //   would agree with this at the three-frame case the suite already pins
        //   and could still drift at another count -- by including a warmup frame,
        //   or by counting nothing at all when no frame is measured.
        let stimulus = BrowseBenchmarkStimulus.standard
        let terminal = makeBrowsingTerminal(stimulus: stimulus)
        let presentation = RenderPresentation(
            theme: .dark, isCursorVisible: false, cursorShape: .block
        )
        let perFrame = planCellCoverage(
            planFrame(for: terminal, presentation: presentation)
        )

        for count in [0, 1, 7] {
            let measured = measureBrowsingPlan(
                stimulus: stimulus, warmupCount: 2, measuredCount: count
            )

            #expect(measured.planCellsPerFrame == perFrame)
            #expect(measured.planCellChecksum == perFrame &* UInt64(count))
        }
    }
}
