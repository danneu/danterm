// Accepted-draw topology accounting for every benchmark workload whose stimulus
// is partial damage.
//
// Three workloads exist to protect an exact damage shape -- `sparse-spans-few`
// (2 rows in 2 spans), `sparse-spans-max` (17 rows in 17 spans), and
// `incremental-mixed` (4 rows in 1 span) at 179x66 -- so a draw only counts as
// measured when the engine damage behind it really carried that shape.
//
// Deciding that from the rendered rectangle is impossible, for two independent
// reasons. A compound clip is drawn under the union of its spans, so one span
// and seventeen read the same bounding row count. And since the pane owns its
// display surface (research/33 `T25`), a render brings a stale swapchain buffer
// current by applying the damage composed since that buffer was last displayed
// -- so the rows a render touches are a property of buffer depth, not of the
// stimulus. A rule written against the rendered rectangle therefore measures the
// swapchain rather than the change under test; `incremental-mixed` stopped
// producing a valid block at all when that rule met the swapchain. The decision
// reads the published frame's own `TerminalDamage` instead, upstream of renderer
// damage resolution, and that is what this file implements.
//
// It lives in the library rather than beside the app-side observer for the same
// reason `TerminalBenchmarkMarkerScanner` does: it is the part with rules worth
// pinning under a headless test, and keeping it here leaves the observer holding
// only AppKit plumbing.
//
// Belongs here: what topology each gated workload requires, whether a draw
// satisfies it, and the per-accepted-draw series a block artifact publishes.
// Does not belong here: files, acknowledgments, timing, or any workload that is
// not topology-gated -- every full-screen, headless, and replay workload must
// not reach this code at all.
import TerminalCore
import TerminalRenderPlanning

/// One damage set reduced to the two numbers a clip's cost depends on.
///
/// Row count and span count are tracked together because neither alone
/// identifies a topology: 50 rows can arrive as 1 span or as 17, and those are
/// the two cases the sparse-span workloads exist to tell apart.
public struct TerminalDamageTopology: Equatable, Sendable {
    public let damagedRowCount: Int
    public let spanCount: Int
    public let isFull: Bool

    /// Reduces damage against the frame's row count, which is what makes full
    /// damage comparable to an enumerated row set. A carried shift is folded to
    /// region rows first: topology is a drawing-cost measure, and the drawer
    /// repaints every row a translation touched until the view half of
    /// research/33 T9 lands.
    public init(_ damage: TerminalDamage, rowCount: Int) {
        if damage.isFull {
            damagedRowCount = rowCount
            spanCount = rowCount > 0 ? 1 : 0
            isFull = true
        } else {
            let folded = damage.expandingShift()
            damagedRowCount = folded.damagedRowCount
            spanCount = folded.maximalContiguousSpanCount
            isFull = false
        }
    }
}

/// One engine damage shape a workload's stimulus is allowed to produce.
///
/// A workload may list more than one, and that is not slack in the gate: it
/// enumerates the shapes its own producer emits. `incremental-mixed` writes four
/// rows every update, but its first update after the settling frame also damages
/// the row the cursor vacates, so the block's series is one 5-row draw in two
/// spans followed by 4-row draws in one. Anything outside the enumerated set is
/// a stimulus that did not happen, and its draw is not measured.
public struct TerminalBenchmarkDamageShape: Equatable, Sendable {
    public let damagedRowCount: Int
    public let spanCount: Int

    public init(damagedRowCount: Int, spanCount: Int) {
        self.damagedRowCount = damagedRowCount
        self.spanCount = spanCount
    }

    /// The artifact form, so the JSON keys a validator reads are fixed here
    /// rather than at the app-side write.
    public var artifact: [String: Int] {
        ["damagedRowCount": damagedRowCount, "spanCount": spanCount]
    }
}

/// Selects accepted draws for one topology-gated workload and accumulates the
/// topology evidence its block artifact publishes.
///
/// `init?` returning nil for every other workload is the isolation guarantee:
/// the ungated workloads construct no recorder, so nothing here runs on their
/// measured path and their block artifact keeps exactly the shape their frozen
/// rules were calibrated against.
///
/// Every series appends in the same call, so their counts stay equal to
/// `acceptedDrawCount` and each index refers to one accepted draw -- the
/// coverage the comparison contract requires before it will read any of them.
public struct TerminalBenchmarkDamageTopologyRecorder {
    /// The engine topology a draw must carry, per workload, at the canonical
    /// 179x66 geometry. Stated as engine rows and spans rather than drawn ones
    /// because the halo transform derives the drawn shape from it, and because
    /// the drawn shape is no longer the stimulus's own property at all.
    ///
    /// `incremental-mixed`'s shapes are measured from its producer
    /// (`incremental_mixed_screen` in `scripts/terminal-benchmark-producer.py`)
    /// against a settled dense screen, not asserted from the source.
    private static let contracts: [String: [TerminalBenchmarkDamageShape]] = [
        "sparse-spans-few": [
            TerminalBenchmarkDamageShape(damagedRowCount: 2, spanCount: 2),
        ],
        "sparse-spans-max": [
            TerminalBenchmarkDamageShape(damagedRowCount: 17, spanCount: 17),
        ],
        "full-screen-incremental-mixed-churn": [
            TerminalBenchmarkDamageShape(damagedRowCount: 4, spanCount: 1),
            TerminalBenchmarkDamageShape(damagedRowCount: 5, spanCount: 2),
        ],
    ]

    public let workload: String
    public let allowedEngineDamageShapes: [TerminalBenchmarkDamageShape]
    public private(set) var acceptedDrawCount = 0
    public private(set) var engineDamagedRowCounts: [Int] = []
    public private(set) var engineSpanCounts: [Int] = []
    public private(set) var haloDamagedRowCounts: [Int] = []
    public private(set) var haloSpanCounts: [Int] = []
    public private(set) var clipDamagedRowCounts: [Int] = []
    public private(set) var clipSpanCounts: [Int] = []
    public private(set) var clipFullDamageCount = 0
    public private(set) var dirtyRectFallbackCount = 0

    public init?(workload: String) {
        guard let shapes = Self.contracts[workload] else { return nil }
        self.workload = workload
        self.allowedEngineDamageShapes = shapes
    }

    /// Records one completed draw when its engine damage carries a required
    /// topology, and reports whether it did.
    ///
    /// The renderer-side arguments are recorded, never gated on: a synthesized
    /// known-bad arm deviates exactly there, and rejecting its draws would
    /// silently turn a measurable regression into an unmeasured block. Only the
    /// engine damage -- the stimulus -- decides acceptance.
    public mutating func recordDrawIfTopologyMatches(
        engineDamage: TerminalDamage,
        clipDamage: TerminalDamage,
        rowCount: Int,
        usedDirtyRectFallback: Bool
    ) -> Bool {
        let engine = TerminalDamageTopology(engineDamage, rowCount: rowCount)
        guard engine.isFull == false,
              allowedEngineDamageShapes.contains(
                  TerminalBenchmarkDamageShape(
                      damagedRowCount: engine.damagedRowCount,
                      spanCount: engine.spanCount
                  )
              )
        else { return false }
        let halo = TerminalDamageTopology(
            engineDamage.expandingShift().withGlyphHalo(rowCount: rowCount),
            rowCount: rowCount
        )
        let clip = TerminalDamageTopology(clipDamage, rowCount: rowCount)
        acceptedDrawCount += 1
        engineDamagedRowCounts.append(engine.damagedRowCount)
        engineSpanCounts.append(engine.spanCount)
        haloDamagedRowCounts.append(halo.damagedRowCount)
        haloSpanCounts.append(halo.spanCount)
        clipDamagedRowCounts.append(clip.damagedRowCount)
        clipSpanCounts.append(clip.spanCount)
        if clip.isFull { clipFullDamageCount += 1 }
        if usedDirtyRectFallback { dirtyRectFallbackCount += 1 }
        return true
    }

    /// Discards every accepted-draw series while keeping the workload contract,
    /// so one app serving many blocks starts each block's evidence empty.
    public mutating func reset() {
        acceptedDrawCount = 0
        engineDamagedRowCounts = []
        engineSpanCounts = []
        haloDamagedRowCounts = []
        haloSpanCounts = []
        clipDamagedRowCounts = []
        clipSpanCounts = []
        clipFullDamageCount = 0
        dirtyRectFallbackCount = 0
    }

    /// Publishes the series in the block artifact's own shape, so the JSON keys
    /// a comparison reads are fixed here rather than at the app-side write.
    public func artifact() -> [String: Any] {
        [
            "workload": workload,
            "allowedEngineDamageShapes": allowedEngineDamageShapes.map(\.artifact),
            "sampleCount": acceptedDrawCount,
            "engineDamagedRowCounts": engineDamagedRowCounts,
            "engineSpanCounts": engineSpanCounts,
            "haloDamagedRowCounts": haloDamagedRowCounts,
            "haloSpanCounts": haloSpanCounts,
            "clipDamagedRowCounts": clipDamagedRowCounts,
            "clipSpanCounts": clipSpanCounts,
            "clipFullDamageCount": clipFullDamageCount,
            "dirtyRectFallbackCount": dirtyRectFallbackCount,
        ]
    }
}
