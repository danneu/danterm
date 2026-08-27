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
    // Scenario: the four (workload, clip) combinations `terminal-headless-draw-compare.py`
    // exposes as `--workload` and `--clip-rows`.
    @Test(
        "Every driver-reachable scenario prepares and times a batch",
        arguments: [0 as Int32, 4], [0 as Int32, 1]
    )
    func preparesAndTimesEveryScenario(clipRows: Int32, textShaped: Int32) {
        #expect(arm_prepare(80, 24, clipRows, textShaped) == 0)
        #expect(arm_batch(1) > 0)
    }
}
