// Covers the headless draw arm's C entry points, which the paired comparison in
// `scripts/terminal-headless-draw-compare.py` calls through `dlsym`.
//
// The value here is mostly that this target exists at all: it is what makes `swift test`
// compile `HeadlessDrawArm`, and a compile is what the arm went without from `13db5f73`
// until the source moved into this package. The assertions below add the next question a
// compile cannot answer -- whether a prepared arm reports a batch it actually ran.
//
// Timing comparisons between scenarios do not belong here. This suite states that a batch
// happened; how long it took is the measurement's business, and the measurement runs on an
// idle machine by hand, not in the gate.
import Testing

import TerminalDrawBenchmarkSupport
@testable import HeadlessDrawArm

// Serialized because both entry points read and write one process-wide prepared surface,
// which is the C ABI the driver needs. Parallel cases would race that global.
@Suite(.serialized)
struct HeadlessDrawArmTests {
    // Intent: every scenario the compare driver can ask for prepares, and a prepared arm
    // reports a nonzero duration for a nonzero batch.
    // Why it exists: `arm_batch` returns 0 for an arm that never prepared, so a driver that
    // silently failed to prepare would publish a paired difference between two zeros.
    // Scenario: the eight (workload, clip) combinations `terminal-headless-draw-compare.py`
    // exposes as `--workload` and `--clip-rows`.
    @Test(
        "Every driver-reachable scenario prepares and times a batch",
        arguments: [0 as Int32, 4], [0 as Int32, 1, 2, 3]
    )
    func preparesAndTimesEveryScenario(clipRows: Int32, workload: Int32) {
        #expect(arm_prepare(80, 24, clipRows, workload) == 0)
        #expect(arm_batch(1) > 0)
    }

    // Intent: a workload index the driver does not know refuses to prepare.
    // Why it exists: the arm holds one process-wide surface, so a silently ignored index
    // would leave the previous workload's surface in place -- or, on a first call, draw the
    // sprite workload -- and the driver would publish a paired difference for a path the
    // caller never selected. A refusal is the only reading that cannot be mistaken for a
    // measurement.
    // Scenario: spec-first -- a driver and an arm that disagree on how many workloads exist,
    // which is the state a new workload passes through.
    @Test("An unknown workload index refuses to prepare")
    func unknownWorkloadRefuses() {
        #expect(arm_prepare(80, 24, 0, 4) == 1)
    }

    // Intent: the symbols workload refuses to prepare when this process has no packaged
    // symbols face.
    // Why it exists: without that face every icon cell falls through to `drawTextCell`, so
    // the arm would still prepare, still time a batch, and publish the `CTLine` fallback
    // path under the symbols workload's name. The arm loads as a dylib into the compare
    // driver's process, where the font comes from the SwiftPM resource bundle rather than
    // `Bundle.main`, so an absent face is a real state and not a hypothetical one.
    // Scenario: spec-first -- an arm built or copied without its resource bundle beside it.
    @Test("The symbols workload refuses to prepare without the packaged face")
    func symbolsWorkloadRefusesWithoutThePackagedFace() {
        let restore = armPackagedSymbolsFaceIsAvailable
        defer { armPackagedSymbolsFaceIsAvailable = restore }
        armPackagedSymbolsFaceIsAvailable = { false }

        #expect(arm_prepare(80, 24, 0, 3) == 1)
        #expect(arm_prepare(80, 24, 0, 2) == 0)
    }

    // Intent: a prepared symbols surface reports icon cells, and the workloads that cannot
    // reach the symbols path report none.
    // Why it exists: the driver divides its absolute paired difference by this count, so a
    // count that silently included ordinary cells would deflate every per-icon number it
    // publishes.
    @Test("Only the symbols workload reports icon cells")
    func onlyTheSymbolsWorkloadReportsIconCells() {
        #expect(arm_prepare(80, 24, 0, 3) == 0)
        #expect(arm_icon_cell_count() == 80 * 24)
        for workload in [0 as Int32, 1, 2] {
            #expect(arm_prepare(80, 24, 0, workload) == 0)
            #expect(arm_icon_cell_count() == 0)
        }
    }

    // Intent: every generator this arm carries produces the same bytes as the
    // TerminalDrawBenchmarkSupport generator it was copied from.
    // Why it exists: the copy is deliberate -- the arm's own setup has to be the constant
    // that makes TerminalCore the only variable -- but until now only a comment said the two
    // copies agree. Two benchmarks that quietly draw different corpora produce numbers that
    // cannot be read against each other, and nothing would have failed.
    // Scenario: spec-first -- an edit to one copy of a generator and not the other.
    @Test(
        "The arm's copied generators match the benchmark support originals",
        arguments: DrawBenchmarkWorkload.allCases
    )
    func copiedGeneratorsMatchTheOriginals(workload: DrawBenchmarkWorkload) throws {
        let index = try #require(DrawBenchmarkWorkload.allCases.firstIndex(of: workload))
        for grid in DrawBenchmarkGrid.standard {
            #expect(
                PreparedDraw.workloadANSI(
                    columns: grid.columns, rows: grid.rows, workload: index
                ) == workloadANSI(for: grid, workload: workload)
            )
        }
    }
}
