// Behavioral proofs that topology-gated draws are accepted and recorded from engine damage.
import TerminalCore
import Testing

@testable import TerminalBenchmarkTopology

struct TerminalBenchmarkDamageTopologyRecorderTests {
    private static let rowCount = 66
    private static let fewSpanRows: Set<Int> = [5, 60]
    private static let maxSpanRows = Set(stride(from: 0, to: 66, by: 4))
    private static let incrementalMixedRows: Set<Int> = [31, 32, 33, 34]

    /// The clip a settled sparse draw resolves to: the halo expansion of the
    /// engine rows, which is what the view submits when no fallback occurred.
    private static func clip(for engineRows: Set<Int>) -> TerminalDamage {
        TerminalDamage(rows: haloRows(engineRows))
    }

    private static func haloRows(_ engineRows: Set<Int>) -> Set<Int> {
        var expanded: Set<Int> = []
        for row in engineRows {
            expanded.insert(max(0, row - 1))
            expanded.insert(row)
            expanded.insert(min(rowCount - 1, row + 1))
        }
        return expanded
    }

    @Test("sparse-spans-few accepts two distant rows and records their 6-row, 2-span drawing")
    func fewSpanStimulusIsAcceptedAndDerivesItsDrawingTopology() {
        // Intent: a draw whose engine damage is exactly the workload's two distant source
        //   rows is accepted, and the block series records both the engine topology and
        //   the drawing topology the shared halo derives from it.
        // Why it exists: the workload's verdict is only meaningful if every measured draw
        //   really carried the ideal sparse shape; recording the derived 6-row, 2-span
        //   drawing topology is what lets a reader confirm the clip that shape produced.
        var recorder = TerminalBenchmarkDamageTopologyRecorder(workload: "sparse-spans-few")
        #expect(recorder != nil)
        let accepted = recorder!.recordDrawIfTopologyMatches(
            engineDamage: TerminalDamage(rows: Self.fewSpanRows),
            clipDamage: Self.clip(for: Self.fewSpanRows),
            rowCount: Self.rowCount,
            usedDirtyRectFallback: false
        )
        #expect(accepted)
        #expect(recorder!.acceptedDrawCount == 1)
        #expect(recorder!.engineDamagedRowCounts == [2])
        #expect(recorder!.engineSpanCounts == [2])
        #expect(recorder!.haloDamagedRowCounts == [6])
        #expect(recorder!.haloSpanCounts == [2])
        #expect(recorder!.clipDamagedRowCounts == [6])
        #expect(recorder!.clipSpanCounts == [2])
    }

    @Test("sparse-spans-max accepts stride-four rows and records their 50-row, 17-span drawing")
    func maximumSpanStimulusIsAcceptedAndDerivesItsDrawingTopology() {
        // Intent: engine damage on every fourth row of the canonical grid is accepted and
        //   recorded as 17 rows in 17 engine spans, drawn as 50 rows in 17 spans.
        // Why it exists: this is the maximum disjoint topology the workload exists to
        //   bound, so a block that silently measured a smaller shape would report a cost
        //   bound it never actually exercised.
        var recorder = TerminalBenchmarkDamageTopologyRecorder(workload: "sparse-spans-max")
        #expect(recorder != nil)
        let accepted = recorder!.recordDrawIfTopologyMatches(
            engineDamage: TerminalDamage(rows: Self.maxSpanRows),
            clipDamage: Self.clip(for: Self.maxSpanRows),
            rowCount: Self.rowCount,
            usedDirtyRectFallback: false
        )
        #expect(accepted)
        #expect(recorder!.engineDamagedRowCounts == [17])
        #expect(recorder!.engineSpanCounts == [17])
        #expect(recorder!.haloDamagedRowCounts == [50])
        #expect(recorder!.haloSpanCounts == [17])
        #expect(recorder!.clipSpanCounts == [17])
    }

    // Regression pin for research/33 F25: `incremental-mixed` produced no valid block
    // once the pane owned its display surface, because acceptance compared the rendered
    // rectangle against a frozen 6 rows and a render brings a stale swapchain buffer
    // current over composed damage. Acceptance reads the stimulus, so buffer depth
    // cannot decide whether a draw is measured.
    @Test("incremental-mixed accepts both shapes its producer emits and no other")
    func incrementalMixedAcceptsItsSettledAndFirstUpdateShapes() {
        // Intent: the workload's steady-state stimulus (four rows in one span) and its
        //   first update after settling (those rows plus the row the cursor vacates, five
        //   rows in two spans) are both accepted; a wider stimulus is not.
        // Why it exists: this is the only ladder workload that can catch a damage-scoping
        //   regression, and it can only do that if a localized update is measured and a
        //   whole-screen one is refused.
        var recorder = TerminalBenchmarkDamageTopologyRecorder(
            workload: "full-screen-incremental-mixed-churn"
        )
        #expect(recorder != nil)
        let firstUpdateRows = Self.incrementalMixedRows.union([65])
        let acceptedFirstUpdate = recorder!.recordDrawIfTopologyMatches(
            engineDamage: TerminalDamage(rows: firstUpdateRows),
            clipDamage: Self.clip(for: firstUpdateRows),
            rowCount: Self.rowCount,
            usedDirtyRectFallback: false
        )
        #expect(acceptedFirstUpdate)
        let acceptedSettled = recorder!.recordDrawIfTopologyMatches(
            engineDamage: TerminalDamage(rows: Self.incrementalMixedRows),
            clipDamage: Self.clip(for: Self.incrementalMixedRows),
            rowCount: Self.rowCount,
            usedDirtyRectFallback: false
        )
        #expect(acceptedSettled)
        #expect(recorder!.engineDamagedRowCounts == [5, 4])
        #expect(recorder!.engineSpanCounts == [2, 1])
        let acceptedWider = recorder!.recordDrawIfTopologyMatches(
            engineDamage: TerminalDamage(rows: Self.incrementalMixedRows.union([10, 20])),
            clipDamage: .full,
            rowCount: Self.rowCount,
            usedDirtyRectFallback: false
        )
        #expect(acceptedWider == false)
        #expect(recorder!.acceptedDrawCount == 2)
    }

    // Regression pin for research/33 F25: the render's own row span is a property of how
    // stale the acquired swapchain buffer was, so it must not gate acceptance.
    @Test("A render that touches far more rows than the stimulus is still accepted")
    func aStaleBufferBringCurrentDoesNotRejectTheDraw() {
        // Intent: a draw whose engine damage carries the contract shape is accepted even
        //   when the clip it rendered under covers the whole grid.
        // Why it exists: a buffer reacquired from a 3-deep swapchain renders the damage
        //   composed since it was last displayed, which is routinely much wider than one
        //   publication's -- and rejecting it stalls the serialized producer forever,
        //   which is exactly how the whole workload went dark.
        var recorder = TerminalBenchmarkDamageTopologyRecorder(
            workload: "full-screen-incremental-mixed-churn"
        )!
        let accepted = recorder.recordDrawIfTopologyMatches(
            engineDamage: TerminalDamage(rows: Self.incrementalMixedRows),
            clipDamage: .full,
            rowCount: Self.rowCount,
            usedDirtyRectFallback: false
        )
        #expect(accepted)
        #expect(recorder.engineDamagedRowCounts == [4])
        #expect(recorder.clipDamagedRowCounts == [66])
        #expect(recorder.clipFullDamageCount == 1)
    }

    @Test("A draw whose engine damage misses the required topology is neither accepted nor recorded")
    func partialAndFullEngineDamageAreRejected() {
        // Intent: engine damage with too few rows, with the right row count in the wrong
        //   number of spans, or reported as full is rejected and appends nothing.
        // Why it exists: AppKit can draw before the whole stimulus has been parsed, and a
        //   theme or geometry invalidation publishes full damage; accepting either would
        //   put a draw in the series that never carried the protected topology.
        var recorder = TerminalBenchmarkDamageTopologyRecorder(workload: "sparse-spans-few")!
        #expect(recorder.recordDrawIfTopologyMatches(
            engineDamage: TerminalDamage(rows: [5]),
            clipDamage: Self.clip(for: [5]),
            rowCount: Self.rowCount,
            usedDirtyRectFallback: false
        ) == false)
        #expect(recorder.recordDrawIfTopologyMatches(
            engineDamage: TerminalDamage(rows: [5, 6]),
            clipDamage: Self.clip(for: [5, 6]),
            rowCount: Self.rowCount,
            usedDirtyRectFallback: false
        ) == false)
        #expect(recorder.recordDrawIfTopologyMatches(
            engineDamage: .full,
            clipDamage: .full,
            rowCount: Self.rowCount,
            usedDirtyRectFallback: false
        ) == false)
        #expect(recorder.acceptedDrawCount == 0)
        #expect(recorder.engineSpanCounts.isEmpty)
        #expect(recorder.haloSpanCounts.isEmpty)
        #expect(recorder.clipSpanCounts.isEmpty)
    }

    @Test("Renderer fallback is recorded as measured behavior rather than rejecting the draw")
    func rendererFallbackIsRecordedWithoutGatingAcceptance() {
        // Intent: a draw whose stimulus topology is correct but whose renderer resolved
        //   damage from the bounding dirty rectangle is still accepted, with the fallback
        //   and the resulting clip topology recorded.
        // Why it exists: a synthesized known-bad arm deviates exactly at renderer damage
        //   resolution, so gating acceptance there would turn the regression this
        //   workload is meant to measure into an unmeasured block instead.
        var recorder = TerminalBenchmarkDamageTopologyRecorder(workload: "sparse-spans-few")!
        let accepted = recorder.recordDrawIfTopologyMatches(
            engineDamage: TerminalDamage(rows: Self.fewSpanRows),
            clipDamage: .full,
            rowCount: Self.rowCount,
            usedDirtyRectFallback: true
        )
        #expect(accepted)
        #expect(recorder.engineSpanCounts == [2])
        #expect(recorder.clipDamagedRowCounts == [66])
        #expect(recorder.clipSpanCounts == [1])
        #expect(recorder.clipFullDamageCount == 1)
        #expect(recorder.dirtyRectFallbackCount == 1)
    }

    @Test("Every published series covers exactly the accepted draws")
    func seriesCoverTheSameAcceptedDrawSet() {
        // Intent: after a mix of accepted and rejected draws, every series has one entry
        //   per accepted draw and the artifact's sample count agrees with them.
        // Why it exists: the comparison contract treats an aggregate without complete
        //   sample coverage as "not measured", so a series that could drift out of step
        //   with the draw set would let a partially covered block read as a valid one.
        var recorder = TerminalBenchmarkDamageTopologyRecorder(workload: "sparse-spans-max")!
        for attempt in 0..<4 {
            let engineRows = attempt == 2 ? Set([0, 4]) : Self.maxSpanRows
            _ = recorder.recordDrawIfTopologyMatches(
                engineDamage: TerminalDamage(rows: engineRows),
                clipDamage: Self.clip(for: engineRows),
                rowCount: Self.rowCount,
                usedDirtyRectFallback: false
            )
        }
        #expect(recorder.acceptedDrawCount == 3)
        let artifact = recorder.artifact()
        #expect(artifact["sampleCount"] as? Int == 3)
        #expect(artifact["workload"] as? String == "sparse-spans-max")
        #expect(
            artifact["allowedEngineDamageShapes"] as? [[String: Int]]
                == [["damagedRowCount": 17, "spanCount": 17]]
        )
        for key in [
            "engineDamagedRowCounts", "engineSpanCounts",
            "haloDamagedRowCounts", "haloSpanCounts",
            "clipDamagedRowCounts", "clipSpanCounts",
        ] {
            #expect((artifact[key] as? [Int])?.count == 3, "\(key) lost accepted-draw coverage")
        }
    }

    @Test(
        "Only the topology-gated workloads construct a recorder",
        arguments: [
            "full-screen-content-churn",
            "full-screen-style-churn",
            "localized-draw",
            "scrollback-stream",
        ]
    )
    func ungatedWorkloadsHaveNoRecorder(workload: String) {
        // Intent: no workload outside the three gated ones can build a recorder.
        // Why it exists: the ungated workloads must keep the block artifact and measured
        //   path their frozen rules were calibrated against, and a nil recorder is what
        //   makes that isolation structural rather than conventional.
        #expect(TerminalBenchmarkDamageTopologyRecorder(workload: workload) == nil)
    }
}
