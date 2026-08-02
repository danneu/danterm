// Accepted-draw topology accounting for the sparse-span benchmark workloads.
//
// The `sparse-spans-few` and `sparse-spans-max` workloads exist to protect two
// exact damage shapes -- 2 rows in 2 spans, and 17 rows in 17 spans at 179x66 --
// so a draw only counts as measured when the engine damage behind it really
// carried that shape. Deciding that from AppKit's bounding dirty rectangle is
// impossible: the rectangle a compound clip is drawn under is the union of every
// span, and it reads the same for one span or seventeen. The decision therefore
// reads the published frame's own `TerminalDamage`, upstream of renderer damage
// resolution, and that is what this file implements.
//
// It lives in the library rather than beside the app-side observer for the same
// reason `TerminalBenchmarkMarkerScanner` does: it is the part with rules worth
// pinning under a headless test, and keeping it here leaves the observer holding
// only AppKit plumbing.
//
// Belongs here: what topology each sparse-span workload requires, whether a draw
// satisfies it, and the per-accepted-draw series a block artifact publishes.
// Does not belong here: files, acknowledgments, timing, or any workload that is
// not topology-gated -- the other five workloads must not reach this code at
// all.
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
    /// damage comparable to an enumerated row set.
    public init(_ damage: TerminalDamage, rowCount: Int) {
        if damage.isFull {
            damagedRowCount = rowCount
            spanCount = rowCount > 0 ? 1 : 0
            isFull = true
        } else {
            damagedRowCount = damage.rows.count
            spanCount = terminalDamageMaximalContiguousSpanCount(damage.rows)
            isFull = false
        }
    }
}

/// Selects accepted draws for one sparse-span workload and accumulates the
/// topology evidence its block artifact publishes.
///
/// `init?` returning nil for every other workload is the isolation guarantee:
/// the five existing workloads construct no recorder, so nothing here runs on
/// their measured path and their block artifact keeps exactly the shape their
/// frozen rules were calibrated against.
///
/// Every series appends in the same call, so their counts stay equal to
/// `acceptedDrawCount` and each index refers to one accepted draw -- the
/// coverage the comparison contract requires before it will read any of them.
public struct TerminalBenchmarkSparseSpanRecorder {
    /// The engine topology a draw must carry, per workload, at the canonical
    /// 179x66 geometry. Stated as engine rows and spans rather than drawn ones
    /// because the halo transform derives the drawn shape from it.
    private static let contracts: [String: (damagedRowCount: Int, spanCount: Int)] = [
        "sparse-spans-few": (damagedRowCount: 2, spanCount: 2),
        "sparse-spans-max": (damagedRowCount: 17, spanCount: 17),
    ]

    public let workload: String
    public let expectedEngineDamagedRowCount: Int
    public let expectedEngineSpanCount: Int
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
        guard let contract = Self.contracts[workload] else { return nil }
        self.workload = workload
        self.expectedEngineDamagedRowCount = contract.damagedRowCount
        self.expectedEngineSpanCount = contract.spanCount
    }

    /// Records one completed draw when its engine damage carries the required
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
              engine.damagedRowCount == expectedEngineDamagedRowCount,
              engine.spanCount == expectedEngineSpanCount
        else { return false }
        let halo = TerminalDamageTopology(
            TerminalDamage(
                rows: terminalDamageRowsWithGlyphHalo(engineDamage.rows, rowCount: rowCount)
            ),
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
            "expectedEngineDamagedRowCount": expectedEngineDamagedRowCount,
            "expectedEngineSpanCount": expectedEngineSpanCount,
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
