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

import HeadlessDrawArm

// Serialized because both entry points read and write one process-wide prepared surface,
// which is the C ABI the driver needs. Parallel cases would race that global.
@Suite(.serialized)
struct HeadlessDrawArmTests {
    // Intent: every scenario the compare driver can ask for prepares, and a prepared arm
    // reports a nonzero duration for a nonzero batch.
    // Why it exists: `arm_batch` returns 0 for an arm that never prepared, so a driver that
    // silently failed to prepare would publish a paired difference between two zeros.
    // Scenario: the six (workload, clip) combinations `terminal-headless-draw-compare.py`
    // exposes as `--workload` and `--clip-rows`.
    @Test(
        "Every driver-reachable scenario prepares and times a batch",
        arguments: [0 as Int32, 4], [0 as Int32, 1, 2]
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
        #expect(arm_prepare(80, 24, 0, 3) == 1)
    }
}
