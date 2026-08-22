// The engine's cost instruments: one enumeration of what can be counted, and one dynamically
// scoped tally that counts it.
//
// Several contracts in this package are claims about *work* -- a frame addresses retained
// history once, a bounded tail read walks the budget it was given, index maintenance visits a
// bounded number of matches -- and `agent-docs/measurement-discipline.md` rules out settling
// them with a wall clock. Each one is pinned by counting the operation itself, so the tests read
// an exact number instead of a duration a loaded machine can perturb.
//
// A free global rather than a member of the type being measured: these claims are about a
// *frame* or a *read*, which spans several reads of `Sendable` value types, so a counter inside
// one of them would have to be either a refcounted box on a hot type -- what
// `docs/design/2026-07-29-cross-module-value-dispatch.md` warns off -- or a mutation on a read
// path that has none. `31/AR5` records the consequence: `31/I7` stays a discipline the counters
// guard rather than a mechanism that enforces it.
//
// The scope is task-local rather than process-wide because the test suite runs in parallel, and
// a global counter would tally every terminal every other test is driving at the same time.
//
// What belongs here: the instrument list and the tally. What does not: any assertion about what
// a given instrument should read, which belongs to the test making the claim, and any recording
// site, which belongs at the operation it prices.

/// Names one countable engine operation, and is the entry point for both recording and measuring
/// it.
///
/// One enumeration rather than one counter type per instrument: the nine hand-rolled counters
/// this replaces were identical but for a field name, so each new claim meant pasting the
/// pattern again, and their separate task-locals gave nesting an accidental answer instead of a
/// stated one.
enum Instrument: Int, CaseIterable, Sendable {
    /// Display-row-to-record locates, so `31/PO7` can assert what one planned frame spends.
    case displayRowLocate

    /// Cells traversed by a row-boundary walk that starts at a record's first cell. Recorded
    /// once per walk so the instrument itself adds no work inside the fold loop.
    case rowBoundaryCellWalk

    /// Whole retained-store equality checks at architecture boundaries, so owner-queue tests can
    /// prove that mutation publication never falls back to an O(history) value comparison.
    case wholeStoreEquality

    /// Display rows a history-text projection materializes and walks, so
    /// `primaryHistoryTailText`'s reason for existing -- that a bounded read costs the budget it
    /// is given and not the scrollback behind it -- is assertable as an exact number rather than
    /// a wall clock. Recorded once per projection with the whole stream length, so the read path
    /// pays one task-local lookup per call and nothing per cell.
    case projectionRow

    /// Complete active-projection materializations, so point-local selection reads can prove they
    /// do not scale with retained history depth.
    case wholeProjection

    /// Record coordinates resolved into current display geometry, so `31/PO7` can assert that a
    /// highlighted frame resolves the matches it draws rather than the matches history holds.
    /// The instrument `31/AR3` names: translating a record coordinate is the new
    /// per-visible-match work on the frame path, and nothing in the type system keeps a reader
    /// from resolving a coordinate inside a binary search over every stored match instead.
    case recordPositionResolution

    /// Content units inspected while resolving nearest-search distances, which lets tests
    /// distinguish endpoint-local rank work from a walk through the gap between matches.
    case searchDistanceWork

    /// Cells decoded through a whole-record materialization, so an index build over closed
    /// history can assert it streams the arena instead of rebuilding cells it does not keep. A
    /// materialized cell carries a style id, a hyperlink probe and a content-identity probe that
    /// a content key never reads, so the count is the difference between the streaming reader and
    /// the materializing one rather than a proxy for it. Recorded once per whole-record read with
    /// that record's cell count, so no per-cell task-local lookup lands on any path.
    case recordCellMaterialization

    /// Retained display rows constructed by whole-history materializations. Reclamation only
    /// needs packed metadata ids, so this makes its zero-row structural contract testable
    /// independently of wall-clock noise.
    case retainedRowMaterialization

    /// Indexed-match visits during closed-history search maintenance, so its cost remains
    /// bounded.
    case searchIndexMaintenance

    /// Closed records visited while scanning search units, so incremental needle entry can prove
    /// that retained history with no old match adds no work.
    case closedRecordSearchScan

    /// Spill payloads walked while maintaining the open tail's byte charge, so admission can
    /// prove its work does not grow with the number of spills already held by the logical line.
    case openSpillChargeWork

    /// Records `count` of this instrument's operation against whatever measurements are in scope,
    /// and nothing when there are none.
    @inline(__always)
    func record(count: Int = 1) {
        Tally.active?.add(self, count)
    }

    /// Runs `body` and reports what it spent on this instrument.
    ///
    /// A measurement observes its own body in full, including the parts of it that run inside a
    /// nested measurement, and each scope counts an operation exactly once.
    func measure(_ body: () -> Void) -> Int {
        let tally = Tally(enclosing: Tally.active)
        return Tally.$active.withValue(tally) {
            body()
            return tally.count(of: self)
        }
    }

    /// The counts one `measure` scope is collecting.
    ///
    /// A class so the dynamic scope below can hand the same box to every synchronous callee
    /// without copying it back out. Each scope links to the one it nests inside and forwards
    /// every recording outward, so an enclosing measurement never loses the work its own body did
    /// inside a nested scope.
    private final class Tally: @unchecked Sendable {
        private let enclosing: Tally?
        private var counts: [Int]

        @TaskLocal static var active: Tally?

        init(enclosing: Tally?) {
            self.enclosing = enclosing
            counts = [Int](repeating: 0, count: Instrument.allCases.count)
        }

        func add(_ instrument: Instrument, _ count: Int) {
            var scope: Tally? = self
            while let current = scope {
                current.counts[instrument.rawValue] += count
                scope = current.enclosing
            }
        }

        func count(of instrument: Instrument) -> Int {
            counts[instrument.rawValue]
        }
    }
}
