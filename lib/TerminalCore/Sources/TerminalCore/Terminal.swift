// `Terminal`, the pure headless terminal reduction: bytes in, grid and metadata state out,
// with no IO, no AppKit, and no clock. Everything that reads or writes the live screen state
// lives here, which is why the file is large and why it is one file.
//
// What it owns:
//   - Ingestion and dispatch: `feed`, the print path, C0/C1 controls, execution of the CSI,
//     OSC, and DCS actions the parser hands back, mode state, and queries with their replies.
//   - The grid itself: cursor, margins, tab stops, scroll regions, erase and edit operations,
//     the alternate screen, resize and reflow (`reconstructLogicalLines`, `pack`).
//   - State layered over the grid that only makes sense against a live coordinate space:
//     selection, hyperlink hover/arm interaction, OSC 133 semantic prompt anchoring
//     (vacate on resize, reclaim of stale heads), and damage/inspection invalidation.
//   - The boundary to retained history: admitting scrolled-off rows into `LogicalLineStore`
//     with its canonical trimming, and the `memoryCensus` walk that prices the whole engine.
//
// What deliberately lives elsewhere: pure OSC payload decoding (`OSCPayload`), search state,
// matching, retained-index maintenance (`Terminal.Search`), state-synchronization encoding
// (`TerminalStateSynchronizationEncoder`), retained-history storage and its
// arena/eviction policy (`LogicalLineStore`),
// the retained record, its cell word and its row folding (`LogicalLineRecord`, `CellWord`,
// `LogicalLineFold`), escape-sequence recognition into actions (`TerminalInputStream`,
// `EscapeAbsorber`), Unicode width and
// grapheme tables (generated), key/mouse encoding (`TerminalInputEncoding`), and the
// pointer-gesture policy (`TerminalInteractionPolicy`). The rule for what belongs here: if it
// mutates or interprets the live screen, or anchors something to a live coordinate, it is in
// this file; if it is a representation, a table, or a decision that can be made without the
// screen, it is not.
//
// Keep it pure. `Terminal` is value-semantic and fully testable by feeding bytes and reading
// back state, which is the property the whole engine's test suite rests on.

import BitCollections
import DequeModule

/// Addresses a projection boundary in the current scrollback-plus-viewport stream.
public struct TerminalTextPosition: Equatable, Sendable {
    /// Counts from the oldest retained scrollback row through the viewport.
    public var row: Int

    /// Addresses a boundary before, between, or after cells in the row.
    public var column: Int

    /// Creates a current-stream coordinate for selection or range inspection.
    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// Mirrors private prompt-row identity for invariant checks in the TerminalCore test target.
enum TerminalSemanticPromptStamp: Equatable, Sendable {
    case none
    case prompt
    case continuation
    case output
    case vacated
}

/// Names the snapshot-provable prompt-anchor contracts so corpus failures identify the broken
/// guarantee. The transition invariants for output floor, geometry coherence, and redraw-mode
/// scope are deliberately absent: they are proven by targeted behavioral tests that bracket the
/// blanking or reclaim operation, not by this oracle.
enum TerminalSemanticPromptInvariantViolation: String, Equatable, Hashable, Sendable {
    case ownership = "I1 ownership"
    case logicalLineIntegrity = "I2 logical-line integrity"
    case totalVacating = "I4 total vacating"
}

/// Carries the stamp and wrap facts the snapshot oracle quantifies over -- nothing heavier, so
/// building one allocates no cell copies.
struct TerminalSemanticPromptRowSnapshot: Equatable, Sendable {
    var stamp: TerminalSemanticPromptStamp
    var isSoftWrapped: Bool
    var isEmpty: Bool
}

/// Exposes a half-open logical-text range without tying callers to grid storage.
public struct TerminalTextRange: Equatable, Sendable {
    /// Marks the included projection boundary.
    public var start: TerminalTextPosition

    /// Marks the excluded projection boundary.
    public var end: TerminalTextPosition

    /// Creates a half-open range from two current-stream boundaries.
    public init(start: TerminalTextPosition, end: TerminalTextPosition) {
        self.start = start
        self.end = end
    }
}

/// Carries reset-to-current terminal bytes together with the geometry they require.
public struct TerminalStateSynchronization: Equatable, Sendable {
    /// Grid width at the state fence.
    public let columns: Int

    /// Grid height at the state fence.
    public let rows: Int

    /// Ordinary terminal-protocol bytes that rebuild the fenced state on a fresh terminal.
    public let bytes: [UInt8]

    /// How many of the source's retained history rows these bytes leave out, oldest first;
    /// `0` when the whole retained history is carried. A replica cannot derive this from the
    /// bytes -- they look the same whether the source had more history or not -- so the
    /// encoder is the only place that can state it.
    public let droppedHistoryRows: Int

    /// Keeps geometry inseparable from bytes whose cursor and wrapping operations depend on it.
    public init(columns: Int, rows: Int, bytes: [UInt8], droppedHistoryRows: Int) {
        self.columns = columns
        self.rows = rows
        self.bytes = bytes
        self.droppedHistoryRows = droppedHistoryRows
    }
}

/// Reduces terminal bytes into deterministic value-semantic screen state without IO.
public struct Terminal: Equatable, Sendable {
    /// Carries owner-observed generations without making observation history part of value equality.
    private struct ObservationGeneration: Equatable, Sendable {
        var value: UInt64 = 0

        static func == (_ lhs: Self, _ rhs: Self) -> Bool { true }
    }

    /// Owns every accumulator whose mutation requires a frame-consumer wakeup so the
    /// generation cannot drift from the pending work it describes.
    private struct PendingConsumerWork: Equatable, Sendable {
        private(set) var clipboardWrite: String?
        private(set) var semanticEvents = TerminalSemanticEventRetention()
        private(set) var generation = ObservationGeneration()

        var hasWork: Bool {
            clipboardWrite != nil || semanticEvents.isEmpty == false
        }

        var retainedSemanticEventBytes: Int {
            semanticEvents.retainedBytes
        }

        mutating func noteDamageChanged() {
            generation.value &+= 1
        }

        mutating func setClipboardWrite(_ value: String?) {
            guard clipboardWrite != value else { return }
            clipboardWrite = value
            generation.value &+= 1
        }

        mutating func admit(
            _ event: TerminalSemanticEvent,
            order: UInt64,
            externalRetainedBytes: Int
        ) -> TerminalSemanticEventAdmission {
            let admission = semanticEvents.admit(
                event,
                order: order,
                externalRetainedBytes: externalRetainedBytes
            )
            if admission == .admitted { generation.value &+= 1 }
            return admission
        }

        mutating func drainClipboardWrite() -> String? {
            defer { clipboardWrite = nil }
            return clipboardWrite
        }

        mutating func drainSemanticEvents() -> [TerminalSemanticEvent] {
            semanticEvents.takeAll()
        }
    }

    /// Indexes `hyperlinkTargets` from inside a cell. Narrow on purpose: an `Int?` here needs
    /// 8-byte alignment, which padded `GridCell` from 56 bytes to 72 -- so the field cost 16 bytes
    /// in every cell for a feature `research/15/F2` measured as unused in 100% of them. Two bytes fit in
    /// padding `TerminalStyle` already leaves behind, and the whole 16 bytes come back
    /// (`research/15/D3`). The price is a finite id space, which is why `allocateHyperlinkId` recycles rather
    /// than counting up; see the invariant stated there. Id 0 is reserved for an absent link so
    /// the live-cell word can store this field without an optional representation.
    typealias HyperlinkId = UInt16

    /// Distinguishes one printed occurrence of a cell from a later reprint of the same text, so a
    /// link armed at pointer-down can reject a run recreated before release.
    ///
    /// 32-bit for the same reason `HyperlinkId` is 16-bit: an `Int?` cost 8 bytes and forced
    /// `GridCell` to 8-byte alignment, so narrowing it takes the cell from 56 bytes to 48
    /// (`research/15/H4`). The price is a counter that can exhaust in minutes of maximal output --
    /// `allocateContentIdentity` owns what happens then, and `research/15/F12` explains why the naive
    /// wrap is not safe.
    typealias ContentIdentity = UInt32

    /// Indexes `styleTable` from inside a cell, replacing the 19-byte `TerminalStyle` that used to
    /// sit inline in every one (`research/15/H3`). `research/15/F11` measured 9-23 million style *writes* per
    /// corpus against 1-5 distinct *values*, which is what rules out a refcount and leaves a swept
    /// table -- see `reclaimDeadStyleEntries`.
    ///
    /// 32-bit, not the 16-bit doc 12 proposed, and the eight bytes are bought deliberately. A
    /// 16-bit id takes `GridCell` to a 24-byte stride instead of 32, but caps the terminal at
    /// 65,536 simultaneously-live styles -- and a truecolor image renderer assigns a distinct RGB
    /// per cell, so one screenful is ~12,000 and a few screens of history exhaust it. There is no
    /// honest fallback at that point: the cell holds nothing but an id, so exceeding the space
    /// means showing the user approximated colors. 32 bits makes the ceiling unreachable instead.
    typealias StyleId = UInt32

    /// Holds the arena cell word and sentinel-0 ids so every live-cell copy is a memory copy.
    struct GridCell: Equatable, Sendable {
        var word: CellWord
        private var storedContentIdentity: ContentIdentity
        private var storedHyperlinkId: HyperlinkId

        init(
            scalars: TerminalScalars = .empty,
            kind: TerminalCellKind = .padding,
            styleId: StyleId = Terminal.defaultStyleId,
            hyperlinkId: HyperlinkId? = nil,
            contentIdentity: ContentIdentity? = nil
        ) {
            precondition(scalars.count <= 1, "multi-scalar cells must be interned by their row")
            precondition(hyperlinkId != 0, "hyperlink id 0 is reserved for absence")
            precondition(contentIdentity != 0, "content identity 0 is reserved for absence")
            word = scalars.first.map {
                CellWord(kind: kind, styleId: styleId, scalar: $0)
            } ?? CellWord(kind: kind, styleId: styleId)
            storedContentIdentity = contentIdentity ?? 0
            storedHyperlinkId = hyperlinkId ?? 0
        }

        init(
            word: CellWord,
            hyperlinkId: HyperlinkId? = nil,
            contentIdentity: ContentIdentity? = nil
        ) {
            precondition(hyperlinkId != 0, "hyperlink id 0 is reserved for absence")
            precondition(contentIdentity != 0, "content identity 0 is reserved for absence")
            self.word = word
            storedContentIdentity = contentIdentity ?? 0
            storedHyperlinkId = hyperlinkId ?? 0
        }

        var kind: TerminalCellKind {
            get { word.kind }
            set { word = word.replacing(kind: newValue) }
        }

        var styleId: StyleId {
            get { word.styleId }
            set { word = word.replacing(styleId: newValue) }
        }

        var hyperlinkId: HyperlinkId? {
            get { storedHyperlinkId == 0 ? nil : storedHyperlinkId }
            set {
                precondition(newValue != 0, "hyperlink id 0 is reserved for absence")
                storedHyperlinkId = newValue ?? 0
            }
        }

        var contentIdentity: ContentIdentity? {
            get { storedContentIdentity == 0 ? nil : storedContentIdentity }
            set {
                precondition(newValue != 0, "content identity 0 is reserved for absence")
                storedContentIdentity = newValue ?? 0
            }
        }

        /// A blank a background erase painted: nothing but a non-default style. The only cell
        /// `GridRow.visibleExtent` may fold into a fill, so a hyperlink or an identity on a
        /// blank keeps it a cell.
        var isFillBlank: Bool {
            word.isSpilled == false
                && word.inlineScalar == nil
                && kind == .padding
                && styleId != Terminal.defaultStyleId
                && hyperlinkId == nil
                && contentIdentity == nil
        }

        /// Whether a reader could tell this cell from a default blank: text, a wide pair,
        /// paint, a hyperlink, or an identity. A derived `.spacerHead` has none of its own.
        var hasVisibleEffect: Bool {
            switch kind {
            case .narrow, .wideHead, .wideTail:
                return true
            case .spacerHead:
                return false
            case .padding:
                return word.isSpilled
                    || word.inlineScalar != nil
                    || styleId != Terminal.defaultStyleId
                    || hyperlinkId != nil
                    || contentIdentity != nil
            }
        }

        func matchesIgnoringPayload(_ other: GridCell) -> Bool {
            kind == other.kind
                && styleId == other.styleId
                && storedHyperlinkId == other.storedHyperlinkId
                && storedContentIdentity == other.storedContentIdentity
        }
    }

    /// One blank cell laid out as a whole `GridCell` stride, so a recycled row is filled a
    /// stride at a time instead of field by field (`research/39/H6`).
    ///
    /// A cell is smaller than its stride, so it is not layout compatible with any word type;
    /// the pattern is therefore written and read as untyped bytes only. `copyMemory` keeps the
    /// destination bound to `GridCell` and is legal because the cell is trivially copyable, so
    /// alignment is not a safety condition here -- no access goes through a word.
    ///
    /// The layout facts this depends on both fail loudly rather than silently: `storeBytes`
    /// traps if a cell ever outgrows the pattern, and `blankCellPatternByteCount` is asserted
    /// equal to `gridCellStrideBytes`.
    private struct BlankCellPattern {
        /// Exactly one cell stride. The padding the cell does not write stays zero, so the
        /// pattern never carries bytes no one initialized.
        private var bytes: (UInt64, UInt64) = (0, 0)

        init(_ cell: GridCell) {
            withUnsafeMutableBytes(of: &bytes) { $0.storeBytes(of: cell, as: GridCell.self) }
        }

        /// Overwrites every whole stride of `destination`, which must be cell storage.
        func fill(_ destination: UnsafeMutableRawBufferPointer) {
            guard let base = destination.baseAddress else { return }
            withUnsafeBytes(of: bytes) { pattern in
                guard let source = pattern.baseAddress else { return }
                var offset = 0
                while offset + pattern.count <= destination.count {
                    base.advanced(by: offset).copyMemory(from: source, byteCount: pattern.count)
                    offset += pattern.count
                }
            }
        }
    }

    /// Records which operation last wrote a row's final column when cell shape alone cannot
    /// decide whether a surviving wrap claim still has line-structure meaning.
    enum MarginProvenance: Equatable, Sendable {
        case content
        case erase
        case wideWrap
    }

    /// Moves row-level state with cells and owns the scalar arena its multi-scalar cells
    /// index into.
    ///
    /// A cell that changes row owner must carry its resolved scalars through `place`; a bare
    /// spilled cell resolves its offset against the wrong row. Each cluster is stored as its
    /// own scalar count followed by its scalars, and a spilled cell's word holds the offset of
    /// that count -- so a row owns exactly one buffer for every cluster it holds, and copying a
    /// row retains that one buffer. The open cluster is the one that ends at the arena's tail,
    /// so joining a scalar to it is one store and one count increment: no allocation while the
    /// row's storage is uniquely owned and the arena has capacity (`research/39/H2`). Scalars
    /// an overwrite or a re-open left behind stay until the amortized compaction threshold, so
    /// repeated rewrites stay bounded without scanning the whole grid. Rows with no
    /// multi-scalar cell keep the empty array singleton.
    struct GridRow: Equatable, Sendable {
        var cells: [GridCell]
        var isSoftWrapped = false
        private var arena: [Unicode.Scalar] = []
        private var arenaCompactionThreshold = 64

        init(cells: [GridCell]) {
            self.cells = cells
        }

        var spillStorageBytes: Int {
            guard arena.capacity > 0 else { return 0 }
            return Terminal.arrayStorageHeaderBytes
                + arena.capacity * MemoryLayout<Unicode.Scalar>.stride
        }

        /// Whether this row has ever grown a cluster. A row's arena is one multi-scalar
        /// allocation to the census however many clusters it holds.
        var hasSpillAllocation: Bool { arena.capacity > 0 }

        /// The arena exactly as it is laid out, dead scalars included.
        ///
        /// Every other reader asks about one cell, so none of them can see a cluster the arena
        /// still holds that no cell points at. A census that must say "and nothing else" needs the
        /// whole buffer, and that claim is what says a join wrote the open cluster in place instead
        /// of re-interning it (`research/39/I6`).
        var arenaCensusForTesting: [Unicode.Scalar] { arena }

        /// How many scalars the cluster whose count sits at `offset` runs for.
        ///
        /// The count is stored as a scalar because the arena holds scalars: it is never read as
        /// text, and every count a cluster can reach is a valid scalar value.
        private func clusterCount(at offset: Int) -> Int { Int(arena[offset].value) }

        private mutating func setClusterCount(_ count: Int, at offset: Int) {
            guard count >= 0, let encoded = Unicode.Scalar(UInt32(exactly: count) ?? .max) else {
                preconditionFailure("a cluster of \(count) scalars has no count the arena can hold")
            }
            arena[offset] = encoded
        }

        /// Reads a cell's scalars as a value that owns them.
        ///
        /// A multi-scalar cell copies its cluster out of the arena here, and that is deliberate:
        /// `TerminalScalars` is carried by value through the whole render plan, and giving it a
        /// case wide enough to name a range in the arena cost `retained-browse` 5% and
        /// `style-churn` 2% for a sharing nobody on that path needed (`research/39/H2` AR1). The
        /// arena is the row's own representation; the readers that walk a cluster per printed
        /// scalar use the accessors below instead of this one.
        func scalars(of cell: GridCell) -> TerminalScalars {
            if cell.word.isSpilled {
                return TerminalScalars(sharingClusterAt: cell.word.spillIndex, in: arena)
            }
            return cell.word.inlineScalar.map(TerminalScalars.init) ?? .empty
        }

        /// The first scalar of a cell's content, without materializing the rest.
        ///
        /// The printer asks this of the open cluster's cell for every scalar that might join it,
        /// which is why it may not build a payload value to answer.
        func firstScalar(of cell: GridCell) -> Unicode.Scalar? {
            cell.word.isSpilled ? arena[cell.word.spillIndex + 1] : cell.word.inlineScalar
        }

        /// Whether two cells in two rows hold the same scalars, without either row building a
        /// payload value to be compared. Row equality asks this of every column.
        static func scalarsEqual(
            _ lhs: GridCell,
            in lhsRow: GridRow,
            _ rhs: GridCell,
            in rhsRow: GridRow
        ) -> Bool {
            guard lhs.word.isSpilled else {
                return rhs.word.isSpilled == false && lhs.word.inlineScalar == rhs.word.inlineScalar
            }
            guard rhs.word.isSpilled else { return false }
            let lhsOffset = lhs.word.spillIndex
            let rhsOffset = rhs.word.spillIndex
            let count = lhsRow.clusterCount(at: lhsOffset)
            guard count == rhsRow.clusterCount(at: rhsOffset) else { return false }
            for position in 0..<count
            where lhsRow.arena[lhsOffset + 1 + position] != rhsRow.arena[rhsOffset + 1 + position] {
                return false
            }
            return true
        }

        func scalars(at column: Int) -> TerminalScalars {
            scalars(of: cell(at: column))
        }

        /// Copies a cell's scalars into `buffer`, replacing what it held and keeping its
        /// capacity.
        ///
        /// The one payload read that must not hand out a reference. REP's memory outlives the
        /// print that fills it, and a retained reference to the row's payload is what made the
        /// printer's next append to the open cluster copy the payload instead of growing it in
        /// place (`research/39/D6`).
        func copyScalars(of cell: GridCell, into buffer: inout [Unicode.Scalar]) {
            buffer.removeAll(keepingCapacity: true)
            if cell.word.isSpilled {
                let offset = cell.word.spillIndex
                buffer.append(
                    contentsOf: arena[(offset + 1)..<(offset + 1 + clusterCount(at: offset))]
                )
            } else if let scalar = cell.word.inlineScalar {
                buffer.append(scalar)
            }
        }

        /// Copies a cell's scalars into REP's memory, which must not reference this row.
        ///
        /// The one payload read that must not hand out a reference. REP's memory outlives the
        /// print that fills it, and a retained reference to the row's payload is what made the
        /// printer's next append to the open cluster copy the payload instead of growing it in
        /// place (`research/39/D6`).
        func copyScalars(of cell: GridCell, into memory: inout LastPrintedCluster) {
            guard cell.word.isSpilled else {
                memory.set(cell.word.inlineScalar)
                return
            }
            let offset = cell.word.spillIndex
            let count = clusterCount(at: offset)
            memory.set(arena[offset + 1])
            for position in 1..<count { memory.extend(arena[offset + 1 + position]) }
        }

        /// Reads a cell's scalars into a value that shares nothing with this row.
        ///
        /// For the one caller that has to carry a cluster across a write to the row it came
        /// from: a width change moves the cluster to another cell, and a shared read would make
        /// that write copy the row's whole arena.
        func copiedScalars(of cell: GridCell) -> TerminalScalars {
            var buffer: [Unicode.Scalar] = []
            copyScalars(of: cell, into: &buffer)
            return TerminalScalars(buffer)
        }

        func scalarCount(of cell: GridCell) -> Int {
            cell.word.isSpilled
                ? clusterCount(at: cell.word.spillIndex)
                : (cell.word.inlineScalar == nil ? 0 : 1)
        }

        mutating func place(_ cell: GridCell, scalars: TerminalScalars, at column: Int) {
            var placed = cell
            switch scalars.count {
            case 0:
                placed.word = CellWord(kind: cell.kind, styleId: cell.styleId)
            case 1:
                placed.word = CellWord(kind: cell.kind, styleId: cell.styleId, scalar: scalars[0])
            default:
                // Vacated before interning, so a compaction inside it reclaims the cluster this
                // cell is losing rather than carrying it into the rebuilt arena.
                cells[column].word = CellWord(kind: cell.kind, styleId: cell.styleId)
                let offset = intern(scalars)
                placed.word = CellWord(kind: cell.kind, styleId: cell.styleId, spillIndex: offset)
            }
            cells[column] = placed
        }

        /// Grows the row by one column and places `cell` there. The one way a row is built
        /// column by column: `place` needs the slot to exist first (a spilled cell writes its
        /// word before interning), so callers do not pre-size a placeholder array.
        mutating func append(_ cell: GridCell, scalars: TerminalScalars) {
            cells.append(GridCell())
            place(cell, scalars: scalars, at: cells.count - 1)
        }

        /// Joins one scalar to the cluster a cell already holds -- the printer's hot path.
        ///
        /// The join costs one store and one count increment whenever the cell's cluster ends at
        /// the arena's tail, which is the case for every cluster grown by uninterrupted
        /// printing. It is not the case when cursor movement re-opens an earlier cell's cluster
        /// after a later cell in this row spilled; that cluster moves to the tail first, and the
        /// scalars it vacates stay dead until compaction reclaims them.
        mutating func appendScalar(_ scalar: Unicode.Scalar, at column: Int) {
            guard cells[column].word.isSpilled else {
                // A cell with no scalar takes this one inline; a cell with one opens a cluster.
                guard let base = cells[column].word.inlineScalar else {
                    cells[column].word = CellWord(
                        kind: cells[column].kind,
                        styleId: cells[column].styleId,
                        scalar: scalar
                    )
                    return
                }
                let offset = beginCluster(scalarCapacity: 2)
                arena.append(base)
                arena.append(scalar)
                setClusterCount(2, at: offset)
                cells[column].word = CellWord(
                    kind: cells[column].kind,
                    styleId: cells[column].styleId,
                    spillIndex: offset
                )
                return
            }

            var offset = cells[column].word.spillIndex
            var count = clusterCount(at: offset)
            if offset + 1 + count != arena.count {
                if arena.count + count + 1 >= arenaCompactionThreshold {
                    compactClusters()
                    offset = cells[column].word.spillIndex
                    count = clusterCount(at: offset)
                }
                if offset + 1 + count != arena.count {
                    let source = offset
                    offset = arena.count
                    for position in 0...count {
                        let carried = arena[source + position]
                        arena.append(carried)
                    }
                    cells[column].word = CellWord(
                        kind: cells[column].kind,
                        styleId: cells[column].styleId,
                        spillIndex: offset
                    )
                }
            }
            arena.append(scalar)
            setClusterCount(count + 1, at: offset)
        }

        /// Rebuilds the arena from the clusters cells still point at, which is the only thing
        /// that reclaims a cluster an overwrite or a re-open left dead.
        ///
        /// A row filled by ordinary printing has nothing dead: each cluster is opened at the
        /// arena's tail and grown there, so the live clusters tile the arena exactly. Measuring
        /// that first is what keeps the amortized threshold from charging a row for a rebuild
        /// that would hand back what is already there (`research/39/H2`). Measured rather than
        /// counted, because `cells` is writable from outside this type and a cell overwritten
        /// there drops a cluster without telling the row.
        mutating func compactClusters() {
            var live = 0
            for column in cells.indices where cells[column].word.isSpilled {
                live += clusterCount(at: cells[column].word.spillIndex) + 1
            }
            if live == arena.count {
                arenaCompactionThreshold = max(64, 2 * arena.count)
                return
            }

            var compacted: [Unicode.Scalar] = []
            compacted.reserveCapacity(live)
            for column in cells.indices where cells[column].word.isSpilled {
                let source = cells[column].word.spillIndex
                let count = clusterCount(at: source)
                let offset = compacted.count
                compacted.append(contentsOf: arena[source..<(source + count + 1)])
                cells[column].word = CellWord(
                    kind: cells[column].kind,
                    styleId: cells[column].styleId,
                    spillIndex: offset
                )
            }
            arena = compacted
            arenaCompactionThreshold = max(64, 2 * compacted.count)
        }

        /// Copies a cluster to the arena's tail and returns the offset of its count.
        private mutating func intern(_ scalars: TerminalScalars) -> Int {
            let offset = beginCluster(scalarCapacity: scalars.count)
            for scalar in scalars { arena.append(scalar) }
            setClusterCount(scalars.count, at: offset)
            return offset
        }

        /// Opens a cluster at the arena's tail, compacting first when the arena has outgrown its
        /// threshold, and returns the offset its count occupies. The threshold doubles against
        /// what compaction finds live, so the reclaim cost stays amortized over the scalars that
        /// caused it.
        private mutating func beginCluster(scalarCapacity: Int) -> Int {
            if arena.count + scalarCapacity + 1 > arenaCompactionThreshold {
                compactClusters()
            }
            // The bound is the cell word's payload width: a cell holds this offset, not a
            // pointer, so an arena that outgrew the field would silently mis-address a cluster.
            precondition(arena.count < 0x1F_FFFF, "row cluster arena exhausted")
            // A placeholder count, which the caller replaces once it knows how many scalars it
            // appended. Nothing may read the cluster in between.
            arena.append(" ")
            return arena.count - 1
        }

        /// The last writer of this row's final column. `isSoftWrapped` is the printer's
        /// *claim* that the row continues, and EL 1/2 deliberately leave it standing over
        /// blanked cells (xterm parity, `eraseLine`); erase provenance records that the claim's
        /// evidence was erased, so `logicallyContinues` can decline it until a print reaches
        /// the margin again. Cell provenance, not cell shape: a reflow-folded row whose
        /// interior blank lands on the margin holds identical cells but genuinely continues,
        /// which is why the readers cannot re-derive this from the grid.
        var marginProvenance = MarginProvenance.content

        /// The wrap claim gated by its evidence: what every line-structure reader --
        /// admission, reflow, the text projections -- consumes in place of `isSoftWrapped`.
        /// The raw claim stays untouched for xterm parity and stays visible through
        /// `geometry`; this is the only meaning it has anywhere else.
        var logicallyContinues: Bool { isSoftWrapped && marginProvenance != .erase }

        /// The row as the projection stream carries it: the claim collapsed to its gated
        /// value, so every walk over a stream reads line structure without knowing about
        /// the transient.
        var withGatedContinuation: GridRow {
            guard isSoftWrapped, marginProvenance == .erase else { return self }
            var row = self
            row.isSoftWrapped = false
            row.marginProvenance = .content
            return row
        }

        var semanticPrompt = SemanticPromptRow.none

        static func == (lhs: GridRow, rhs: GridRow) -> Bool {
            guard lhs.isSoftWrapped == rhs.isSoftWrapped,
                  lhs.marginProvenance == rhs.marginProvenance,
                  lhs.semanticPrompt == rhs.semanticPrompt,
                  lhs.cells.count == rhs.cells.count
            else { return false }
            return lhs.cells.indices.allSatisfy { column in
                lhs.cells[column].matchesIgnoringPayload(rhs.cells[column])
                    && scalarsEqual(lhs.cells[column], in: lhs, rhs.cells[column], in: rhs)
            }
        }

        /// Reads the logical row rather than exposing its physical storage extent.
        func cell(at column: Int) -> GridCell {
            precondition(column >= 0)
            return cells.indices.contains(column) ? cells[column] : GridCell()
        }

        /// Turns this row back into a blank row of `columns` cells painted at `styleId`, reusing
        /// its own cell buffer when the width already matches.
        ///
        /// The one way a scroll recycles a row it is about to hand back to the viewport, so it
        /// must leave nothing of the row's former life behind: the result has to equal
        /// `GridRow(cells:)` on a fresh buffer, every cluster included. That is why it assigns a
        /// whole new value rather than clearing field by field -- a stored property added later
        /// gets its declared default here exactly as it does in a freshly made row.
        ///
        /// Dropping `cells` before writing through `buffer` is what keeps the reuse allocation
        /// free: it releases this row's own reference, so the buffer is uniquely owned unless a
        /// retained copy of the terminal shares it, in which case the write copies as it must.
        /// The cluster arena is emptied and handed back the same way, so a screen of clusters
        /// costs its arenas once per recycled row slot rather than once per line printed. Only
        /// the census's capacity measure can tell that apart from a fresh row.
        ///
        /// The reused buffer is filled a whole cell stride at a time from `BlankCellPattern`
        /// rather than cell by cell: a cell assignment lowers to a bounds check plus three
        /// stores, because the cell's two padding bytes split it (`research/39/H6`).
        mutating func resetAsBlank(columns: Int, styleId: StyleId) {
            var buffer = cells
            cells = []
            var arenaBuffer = arena
            arena = []
            let blank = GridCell(styleId: styleId)
            if buffer.count == columns {
                let pattern = BlankCellPattern(blank)
                buffer.withUnsafeMutableBytes { pattern.fill($0) }
            } else {
                buffer = Array(repeating: blank, count: columns)
            }
            arenaBuffer.removeAll(keepingCapacity: true)
            self = GridRow(cells: buffer)
            arena = arenaBuffer
        }

        /// Materializes the logical row for a consumer that requires full-width storage.
        func materialized(to columns: Int) -> GridRow {
            precondition(columns >= cells.count)
            guard cells.count < columns else { return self }
            var row = self
            row.cells.append(contentsOf: repeatElement(GridCell(), count: columns - cells.count))
            return row
        }

        /// What a hard-ended row contributes to its logical line: `contentEnd` cells, then one
        /// `fillStyle` painted from there to the margin (nil when the margin is default).
        ///
        /// Lossless: `contentEnd` is one past the last cell with a visible effect -- text, or
        /// a blank with a style, a hyperlink or an identity -- except that the maximal uniform
        /// run of styled blanks reaching the right margin collapses into `fillStyle`. Blanks
        /// between the content and that run stay cells: they are positionally real and re-wrap
        /// with the rest of the line. The store's admission and the live refold both measure by
        /// this one rule, so a row folds to the same line whichever path carries it.
        /// `retainedContentEnd` is the *text* extent and stays separate on purpose: Copy and
        /// the text projections must not see a colored-but-empty row as content.
        struct VisibleExtent {
            var contentEnd: Int
            var fillStyle: StyleId?
        }

        /// The visible extent of this row measured as a hard-ended row of `columns` cells.
        func visibleExtent(columns: Int) -> VisibleExtent {
            guard columns > 0 else { return VisibleExtent(contentEnd: 0, fillStyle: nil) }
            let margin = cell(at: columns - 1)
            var end = min(columns, cells.count)
            if margin.isFillBlank {
                while end > 0, cells[end - 1].isFillBlank, cells[end - 1].styleId == margin.styleId {
                    end -= 1
                }
                return VisibleExtent(contentEnd: end, fillStyle: margin.styleId)
            }
            while end > 0, cells[end - 1].hasVisibleEffect == false {
                end -= 1
            }
            return VisibleExtent(contentEnd: end, fillStyle: nil)
        }
    }

    /// The mark a non-head display row of a logical line carries: `.continuation` when the
    /// line's head is marked, nothing when it is not. The one definition the printer's soft
    /// wrap, the packer and the store's materializer and head trim all call, so a wrapped line
    /// reads the same live, after a refold and after it rematerializes from history.
    static func continuationMark(forLineHead head: SemanticPromptRow) -> SemanticPromptRow {
        head == .none ? .none : .continuation
    }

    /// Tracks a shell-redraw prompt row through prompt -> vacated -> repainted or
    /// reclaimed. Ownership is explicit because empty cells alone cannot distinguish
    /// a repaint grant from user content; see
    /// `docs/design/2026-08-01-osc-133-prompt-anchoring.md`.
    enum SemanticPromptRow: Equatable, Sendable {
        case none
        case prompt
        case continuation
        /// The hard upper bound for a search for the prompt below this output.
        case output
        /// A blanked prompt row still awaiting repaint or empty-row reclaim.
        case vacated
    }

    /// Tracks whether subsequent output belongs to command output, a prompt, or input.
    enum SemanticContent: Equatable, Sendable {
        case output
        case prompt
        case input
    }

    /// Selects the OSC 133 prompt range a capable shell promises to redraw.
    enum PromptRedrawMode: Equatable, Sendable {
        case disabled
        case full
        case last
    }

    /// Captures non-grid presentation state around one parser action in constant time.
    ///
    /// Every field is trivially copyable, and that is load-bearing rather than incidental:
    /// two of these exist per parser action, so a single refcounted member turns each
    /// construction, copy and destruction into a value-witness call. Holding the hovered
    /// `TerminalResolvedLink` did exactly that -- its `TerminalHyperlink` carries `uri`
    /// and `explicitId` Strings -- and cost 8.3% of the throughput workload's on-CPU time
    /// (`research/17/F7`). The hovered link is therefore represented by a revision counter plus its
    /// projected range, which is all `recordDamage(from:to:)` ever needed. Keep it POD:
    /// adding a String, array, or class reference here reintroduces that cost.
    private struct DamageActionSnapshot {
        var cursor: TerminalCursor?
        var selection: TerminalTextRange?
        var hoveredLinkRange: TerminalTextRange?
        var hoveredLinkRevision: UInt64
        /// Eviction-corrected top row, not `scrollProjection.topRow`: at the
        /// history budget an append and the arena eviction cancel in the
        /// retained-relative value while the content still translates
        /// (`research/33/F19`), and the guard below must see the same advance in
        /// both regimes to match it against `scrollShiftAccountedAdvance`.
        var absoluteTopRow: Int
        /// `Terminal.scrollShiftAccountedAdvance` at capture time, so the diff
        /// can subtract the viewport advance a recorded shift already describes.
        var scrollShiftAdvance: UInt64
        var isFollowing: Bool
        var isAlternateScreenActive: Bool
        var cursorPresentation: TerminalPresentation
    }

    /// Indexed view of the active text projection -- retained scrollback followed by the live
    /// rows -- so a point-local query reads only the rows it touches instead of materializing a
    /// copy of the whole retained stream on every pointer event.
    ///
    /// The seam and alternate-screen rules come from the active `DisplayRowProjector`, which is
    /// what lets an indexed reader match the materialized projection row for row. A live row sits
    /// at `historyRows + r` here whichever screen is active; the projector takes grid indices, so
    /// the mapping happens at each subscript.
    ///
    /// Constructing one is O(1): both row collections are copy-on-write and nothing here mutates
    /// them, so the whole type is a store, a row deque and a projector.
    ///
    /// Materializes a `GridRow` per history subscript, which is `research/31/D3` Decision 5's deliberate
    /// scope line for milestone 1: today's subscript already unpacks one row per access, so the
    /// facade is a wash against it, and the per-frame path never comes through here at all.
    /// Replacing it with a borrowing cursor is the follow-up plan's.
    struct ProjectionRows: RandomAccessCollection {
        private let history: LogicalLineStore
        private let historyRows: Int
        private let live: Deque<GridRow>
        private let projector: DisplayRowProjector

        init(
            history: LogicalLineStore,
            live: Deque<GridRow>,
            projector: DisplayRowProjector
        ) {
            self.history = history
            historyRows = projector.historyRowCount
            self.live = live
            self.projector = projector
        }

        var startIndex: Int { 0 }
        var endIndex: Int { historyRows + live.count }

        subscript(position: Int) -> GridRow {
            guard position < historyRows else {
                let liveIndex = position - historyRows
                return projector.project(live[liveIndex], projector.facts(forGridRow: liveIndex))
            }
            guard let row = history.paintedDisplayRow(at: position) else {
                preconditionFailure("the projection addressed a display row history does not hold")
            }
            return projector.project(row, projector.facts(forHistoryRow: position))
        }

        /// Walks a contiguous projection range with one history locate, preserving the seam
        /// and alternate-screen rules that make this collection the search projection.
        func forEachRow(
            in range: Range<Int>,
            _ body: (Int, GridRow) -> Void
        ) {
            precondition(range.lowerBound >= startIndex && range.upperBound <= endIndex)

            let historyEnd = Swift.min(range.upperBound, historyRows)
            if range.lowerBound < historyEnd {
                guard var cursor = history.locate(displayRow: range.lowerBound) else {
                    preconditionFailure("the projection addressed a display row history does not hold")
                }
                for position in range.lowerBound..<historyEnd {
                    body(position, projector.project(
                        history.paintedRow(at: cursor),
                        projector.facts(forHistoryRow: position)
                    ))
                    if position + 1 < historyEnd {
                        guard let next = history.advance(cursor) else {
                            preconditionFailure("the projection ended before its indexed row count")
                        }
                        cursor = next
                    }
                }
            }

            let liveStart = Swift.max(range.lowerBound, historyRows)
            guard liveStart < range.upperBound else { return }
            for position in liveStart..<range.upperBound {
                let liveIndex = position - historyRows
                body(position, projector.project(live[liveIndex], projector.facts(forGridRow: liveIndex)))
            }
        }
    }

    /// Holds the two value-backed stores a viewport visitor must carry through nested callbacks.
    ///
    /// The callbacks are synchronous, but Swift still copies a captured value into each closure
    /// context. One reference context keeps that ownership work per traversal instead of per row
    /// while leaving the terminal itself borrowed.
    private final class ViewportRowReadStorage {
        private let store: LogicalLineStore
        private let styles: [StyleId: TerminalStyle]?

        init(store: LogicalLineStore, styles: [StyleId: TerminalStyle]?) {
            self.store = store
            self.styles = styles
        }

        @inline(__always)
        func advance(_ cursor: LogicalLineStore.DisplayRowCursor) -> LogicalLineStore.DisplayRowCursor? {
            store.advance(cursor)
        }

        @inline(__always)
        func style(for id: StyleId) -> TerminalStyle {
            id == Terminal.defaultStyleId ? TerminalStyle() : styles?[id] ?? TerminalStyle()
        }

        func withPaintedCells(
            at cursor: LogicalLineStore.DisplayRowCursor,
            _ body: (
                _ count: Int,
                _ styleIdAt: (_ column: Int) -> StyleId,
                _ cellAt: (_ column: Int) -> (
                    kind: TerminalCellKind,
                    scalars: TerminalScalars
                )
            ) -> Void
        ) {
            store.withPaintedCells(at: cursor, body)
        }
    }

    /// Tracks cursor coordinates without exposing storage indices.
    struct CellPosition: Equatable, Sendable {
        var row: Int
        var column: Int
    }

    /// Keeps inspection state stable while rows migrate between viewport and scrollback.
    struct TextAnchor: Equatable, Comparable, Sendable {
        var row: Int
        var column: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.row < rhs.row || (lhs.row == rhs.row && lhs.column < rhs.column)
        }
    }

    /// Represents a half-open selection or match in absolute retained-row coordinates.
    struct TextAnchorRange: Equatable, Sendable {
        var start: TextAnchor
        var end: TextAnchor
    }

    /// Keeps selection extent, the pivot it turns on, and extension behavior on one
    /// replacement and drop lifetime.
    ///
    /// The pivot is the whole *unit* the gesture began at rather than one boundary: a token or
    /// line gesture that reverses across its origin has to keep that origin unit selected, and
    /// only the unit knows which of its two edges the reversal needs. At character granularity
    /// the unit is a single boundary, so the two spellings coincide.
    private struct SettledSelection: Equatable, Sendable {
        var anchorUnit: TextAnchorRange
        var focus: TextAnchor
        var granularity: TerminalSelectionGranularity
        /// Marks the empty selection a plain click leaves behind, which every public
        /// projection hides. Other empty selections -- a multi-click press over blank cells,
        /// `selectAll()` on a blank pane -- stay visible to them, so the kind of empty has to
        /// be carried rather than derived from the extent.
        var isCaret: Bool

        /// The highlighted extent: the ordered pair of the anchor unit and the focus.
        var range: TextAnchorRange {
            TextAnchorRange(
                start: min(anchorUnit.start, focus),
                end: max(anchorUnit.end, focus)
            )
        }

        /// Applies one restatement to every boundary the selection owns, so no path can move
        /// an endpoint without deciding what happens to the other two.
        mutating func mapBoundaries(_ transform: (TextAnchor) -> TextAnchor) {
            anchorUnit.start = transform(anchorUnit.start)
            anchorUnit.end = transform(anchorUnit.end)
            focus = transform(focus)
        }
    }

    /// Keeps bottom-follow policy explicit when a browsing anchor becomes bottom-aligned.
    private enum ViewportState: Equatable, Sendable {
        case following
        case browsing(top: TextAnchor)
    }

    /// Retains hover presentation against reflowable text anchors without storing platform state.
    private struct InteractionLinkState: Equatable, Sendable {
        var hyperlink: TerminalHyperlink
        var range: TextAnchorRange
        var activationIdentity: Int
    }

    /// Couples one atomic projected unit to the boundaries that can select it.
    private struct ProjectionUnit {
        var scalars: [Unicode.Scalar]
        var start: TextAnchor
        var end: TextAnchor
        var isHardBoundary: Bool
    }

    /// Locates one projected unit by the row it came from, so an expansion walk can step
    /// outward from a click without an index into a units array for the whole stream.
    /// Carrying the row's units keeps a step within the row allocation-free; crossing a row
    /// projects exactly one more row.
    private struct ProjectionCursor {
        var row: Int
        var indexInRow: Int
        var rowUnits: [ProjectionUnit]

        var unit: ProjectionUnit { rowUnits[indexInRow] }
    }

    /// Keeps the one DECSC slot independent from live cursor and mode mutation.
    struct SavedCursorState: Equatable, Sendable {
        var position = CellPosition(row: 0, column: 0)
        var style = TerminalStyle()
        var isPendingWrap = false
        var isOriginMode = false
        var isCursorVisible = true
        var cursorShape = TerminalCursorShape.block
        var isCursorBlinking = false
        // The VT420 manual puts the designations, the GL invocation, and any pending single
        // shift in DECSC's list, so the slot carries the whole charset value.
        var charsets = TerminalCharsetState()
    }

    /// Groups the control state that reset policy owns at screen scope.
    struct ScreenControlState: Equatable, Sendable {
        var savedCursor = SavedCursorState()
        var kittyKeyboardStack: [TerminalKittyKeyboardFlags] = []
    }

    /// Owns terminal-scoped mode state so reset has one complete default value.
    struct TerminalModes: Equatable, Sendable {
        var isInsertMode = false
        var isLineFeedNewLineMode = false
        var isApplicationCursorKeysMode = false
        var isApplicationKeypadMode = false
        var isFocusReportingMode = false
        var isBracketedPasteMode = false
        var mouseTrackingMode = TerminalMouseTrackingMode.off
        var isSGRMouseEncodingMode = false
        var isAlternateScrollMode = true
        var isOriginMode = false
        var isAutoWrapMode = true
        var isCursorVisible = true
        var cursorShape = TerminalCursorShape.block
        var isCursorBlinking = false
        var isSynchronizedOutputActive = false
    }

    /// Catalogs every ANSI mode accepted by set/reset, query, and synchronization.
    enum ANSIMode: UInt16, CaseIterable {
        case insert = 4
        case lineFeedNewLine = 20
    }

    /// Catalogs every DEC-private mode accepted by set/reset, query, and synchronization.
    enum DECPrivateMode: UInt16, CaseIterable {
        case applicationCursorKeys = 1
        case origin = 6
        case autoWrap = 7
        case cursorBlink = 12
        case cursorVisible = 25
        case legacyAlternateScreen = 47
        case mouseClick = 1000
        case mouseDrag = 1002
        case mouseAnyMotion = 1003
        case focusReporting = 1004
        case sgrMouseEncoding = 1006
        case alternateScroll = 1007
        case alternateScreen = 1047
        case savedCursor = 1048
        case alternateScreenAndSavedCursor = 1049
        case bracketedPaste = 2004
        case synchronizedOutput = 2026
        case graphemeClusters = 2027

        /// The one declaration of what this mode means. Set/reset, DECRQM, and
        /// synchronization all read it, so none of them can answer for a different mode.
        var policy: ModePolicy {
            switch self {
            case .applicationCursorKeys:
                ModePolicy(state: .stored(\.isApplicationCursorKeysMode))
            case .origin:
                ModePolicy(state: .stored(\.isOriginMode), setEffect: .homeCursor)
            case .autoWrap:
                ModePolicy(state: .stored(\.isAutoWrapMode))
            case .cursorBlink:
                ModePolicy(state: .stored(\.isCursorBlinking))
            case .cursorVisible:
                ModePolicy(state: .stored(\.isCursorVisible))
            case .legacyAlternateScreen:
                ModePolicy(state: .screenSwitch(ScreenSwitch(
                    savesCursor: false,
                    clearsOnEntry: false,
                    clearsOnExit: false
                )))
            case .mouseClick:
                ModePolicy(state: .mouseTracking(.click))
            case .mouseDrag:
                ModePolicy(state: .mouseTracking(.drag))
            case .mouseAnyMotion:
                ModePolicy(state: .mouseTracking(.anyMotion))
            case .focusReporting:
                ModePolicy(state: .stored(\.isFocusReportingMode), setEffect: .reportFocus)
            case .sgrMouseEncoding:
                ModePolicy(state: .stored(\.isSGRMouseEncodingMode))
            case .alternateScroll:
                ModePolicy(state: .stored(\.isAlternateScrollMode))
            case .alternateScreen:
                ModePolicy(state: .screenSwitch(ScreenSwitch(
                    savesCursor: false,
                    clearsOnEntry: false,
                    clearsOnExit: true
                )))
            case .savedCursor:
                ModePolicy(state: .cursorSlot)
            case .alternateScreenAndSavedCursor:
                ModePolicy(state: .screenSwitch(ScreenSwitch(
                    savesCursor: true,
                    clearsOnEntry: true,
                    clearsOnExit: false
                )))
            case .bracketedPaste:
                ModePolicy(state: .stored(\.isBracketedPasteMode))
            case .synchronizedOutput:
                ModePolicy(state: .stored(\.isSynchronizedOutputActive))
            case .graphemeClusters:
                ModePolicy(state: .fixedStatus(3))
            }
        }
    }

    /// Says where one DEC-private mode's state lives.
    ///
    /// A consumer switches over this instead of over the mode, so a mode whose state is a kind
    /// that already exists costs no consumer edit, and a genuinely new kind of state fails to
    /// compile in every consumer that has to interpret it.
    enum ModeState {
        /// A plain `Bool` on `TerminalModes`: the setter writes it, DECRQM reads it, and
        /// synchronization re-emits it. Most declared modes are this, which is the arm that
        /// makes a new one cost a single row here and no consumer edit.
        case stored(WritableKeyPath<TerminalModes, Bool>)
        /// One member of the mutually exclusive mouse-tracking trio.
        case mouseTracking(TerminalMouseTrackingMode)
        /// Switches the live grid between the primary and the alternate screen.
        case screenSwitch(ScreenSwitch)
        /// The screen's DECSC slot: setting saves the cursor into it, resetting restores from it.
        case cursorSlot
        /// No state of its own; the mode is recognized only to answer DECRQM with this status.
        case fixedStatus(Int)
    }

    /// The three answers that are the whole difference between the alternate-screen modes.
    ///
    /// 47 neither saves nor clears, 1047 clears the alternate as it leaves, and 1049 saves the
    /// cursor and clears the alternate as it arrives. These are xterm's edges, which ghostty
    /// matches. The set/reset path and the query path read the same answers, so neither can
    /// hold a different opinion about one mode.
    struct ScreenSwitch {
        var savesCursor: Bool
        var clearsOnEntry: Bool
        var clearsOnExit: Bool
    }

    /// Says what setting one DEC-private mode does beyond writing its state.
    ///
    /// Kept apart from `ModeState` because the modes that need one are otherwise plain stored
    /// `Bool`s -- folding the effect into the state kind would make every consumer name them
    /// again.
    enum ModeSetEffect {
        case none
        /// DECOM: the cursor re-homes to the origin the new mode selects.
        case homeCursor
        /// Answering the enable is the only way a child that starts in an unfocused pane can
        /// learn it is unfocused, as foot does.
        case reportFocus

        /// Whether setting the mode puts a reply on the wire.
        ///
        /// Synchronization omits exactly these modes when its caller has already accounted for
        /// the reply, so no consumer has to name a specific mode to get that behavior.
        var emitsReply: Bool {
            switch self {
            case .none, .homeCursor: false
            case .reportFocus: true
            }
        }
    }

    /// One mode's complete meaning: where its state lives, and what setting it also does.
    struct ModePolicy {
        var state: ModeState
        var setEffect: ModeSetEffect = .none
    }

    /// Keeps REP independent from later cursor movement and grid replacement.
    ///
    /// Owns its scalars rather than referencing the row's: while the memory held the row's own
    /// payload, the next append to the open cluster had to copy that payload instead of growing
    /// it in place (`research/39/D6`). It holds the cluster's first scalar inline and only the
    /// rest in a buffer, because the printer refreshes this memory after every scalar it prints
    /// and almost every cluster is one scalar -- reaching a heap buffer on that path cost
    /// `kitten-feed-unicode` 18%. The buffer is emptied rather than discarded, so a cluster that
    /// does need one costs no allocation to remember again. No first scalar is the absence of a
    /// memory, which is a state REP and the synchronization encoder both read.
    struct LastPrintedCluster: Equatable, Sendable, RandomAccessCollection {
        private var head: Unicode.Scalar?
        private var tail: [Unicode.Scalar] = []
        var cellWidth = 1

        /// Whether REP has a cluster to repeat.
        var isPresent: Bool { head != nil }

        /// Forgets the cluster while keeping the buffer the next multi-scalar cluster refills.
        mutating func clear() {
            set(nil)
            cellWidth = 1
        }

        /// Replaces the memory with one scalar, or with no memory at all.
        mutating func set(_ scalar: Unicode.Scalar?) {
            head = scalar
            // Guarded: `removeAll` reaches the buffer to check that it is uniquely referenced,
            // and this runs after every printed scalar.
            if tail.isEmpty == false { tail.removeAll(keepingCapacity: true) }
        }

        /// Extends the memory with a scalar the caller has already decided belongs to it.
        mutating func extend(_ scalar: Unicode.Scalar) {
            if head == nil { head = scalar } else { tail.append(scalar) }
        }

        /// Extends the memory only while the result still fits the retained-cluster bound, which
        /// is how the synchronization stream rebuilds a memory it received in chunks.
        @discardableResult
        mutating func append(_ scalar: Unicode.Scalar, upToUTF8ByteCount limit: Int) -> Bool {
            let scalarByteCount = TerminalScalars.utf8ByteCount(of: scalar)
            let retained = reduce(0) { $0 + TerminalScalars.utf8ByteCount(of: $1) }
            guard scalarByteCount <= limit, retained <= limit - scalarByteCount else {
                return false
            }
            extend(scalar)
            return true
        }

        // Reads as the cluster it remembers, so REP and the synchronization encoder walk it
        // without asking which half of the storage a scalar came from -- or building an array to
        // avoid asking.
        var startIndex: Int { 0 }

        var endIndex: Int { head == nil ? 0 : tail.count + 1 }

        subscript(position: Int) -> Unicode.Scalar {
            precondition(
                position >= 0 && position < endIndex,
                "cluster memory index out of bounds"
            )
            guard let head else { preconditionFailure("an absent cluster memory has no scalars") }
            return position == 0 ? head : tail[position - 1]
        }
    }

    /// Retains exactly the target and pairwise look-behind for one open grapheme cluster.
    struct ClusterContext: Equatable, Sendable {
        var target: CellPosition
        var previousClass: GraphemeBreakClass
        var breakState = GraphemeBreakState()
        var retainedUTF8ByteCount: Int

        /// Whether `lastPrintedCluster` already holds exactly what `target` holds, so a scalar
        /// joining this cluster can extend the memory instead of copying the cell out of the row
        /// (`research/39/D8`).
        ///
        /// A context the printer opened and remembered says true. A context adopted from
        /// anywhere else -- recovered from the grid, or restored by the synchronization stream,
        /// which can restore a memory and a context naming different cells -- says false, and so
        /// does a context whose memory the synchronization stream rewrote afterwards. It is a
        /// claim about the memory, not a record of provenance: an adopted context says true again
        /// once a join has rebuilt the memory from its cell, so two terminals holding the same
        /// cluster and the same memory compare equal whichever path opened the context.
        /// Everything that invalidates the look-behind clears the whole context, so the claim
        /// expires with it.
        var memoryMirrorsTarget = false
    }

    /// Owns every piece of terminal state whose meaning is scoped to one screen buffer.
    struct ScreenState: Equatable, Sendable {
        var rows: Deque<GridRow>
        var cursor = CellPosition(row: 0, column: 0)
        var isPendingWrap = false
        var control = ScreenControlState()
        var semanticContent = SemanticContent.output
        var semanticContentClearsAtEndOfLine = false

        /// Resolves the content cell before the cursor without treating layout as text.
        ///
        /// Lives on the screen and not on the terminal because cluster recovery calls it from a
        /// `mutating` method once per printed character: on the terminal, that borrow made the
        /// compiler copy the whole terminal per print (`research/39/F2`, `D5`). Everything it
        /// reads is screen state except the column count, which is terminal-stored and so
        /// arrives as an argument.
        func clusterPredecessor(columnCount: Int) -> CellPosition? {
            guard rows.indices.contains(cursor.row),
                  rows[cursor.row].cells.indices.contains(cursor.column)
            else { return nil }

            let candidate: CellPosition
            if isPendingWrap {
                candidate = cursor
            } else {
                if rows[cursor.row].cells[cursor.column].kind == .wideTail {
                    return nil
                }
                if cursor.column > 0 {
                    candidate = CellPosition(row: cursor.row, column: cursor.column - 1)
                } else {
                    guard cursor.row > 0,
                          rows[cursor.row - 1].logicallyContinues
                    else { return nil }
                    candidate = CellPosition(row: cursor.row - 1, column: columnCount - 1)
                }
            }

            let kind = rows[candidate.row].cells[candidate.column].kind
            let target = kind == .wideTail
                ? CellPosition(row: candidate.row, column: candidate.column - 1)
                : candidate
            guard target.column >= 0 else { return nil }
            let targetKind = rows[target.row].cells[target.column].kind
            guard targetKind == .narrow || targetKind == .wideHead else { return nil }
            return target
        }
    }

    /// Makes the offscreen payload carry the screen that must exist for each live-screen state.
    private enum ScreenOwnership: Equatable, Sendable {
        case primaryLive(alternate: ScreenState?)
        case alternateLive(primary: ScreenState)
    }

    /// Carries one atomic cell unit: the head cell and how many columns it occupies.
    ///
    /// A head plus a width rather than the cells themselves, because the only two-column unit is
    /// a wide pair whose tail is a pure function of its head. `pack` synthesizes that tail where
    /// it places the pair, so a refold allocates no per-cell array.
    private struct ReflowUnit {
        var head: GridCell
        var width: Int
        var headScalars: TerminalScalars
        /// A blank past its row's visible extent that the fold carries only to keep the live
        /// cursor's distance from the content. A packed row holding nothing else exists for
        /// the cursor alone, and `resizeWidth` takes it out of the trailing-blank budget.
        var isCursorPadding = false
    }

    /// Reconstructs one hard-delimited logical line, its prompt marker and its fill during reflow.
    private struct ReflowLine {
        var units: [ReflowUnit] = []
        var semanticPrompt = SemanticPromptRow.none
        /// The style painted past the content on the line's last packed row, and on every blank
        /// the pack synthesizes for the line. Line metadata rather than cells, so a filled row
        /// folds to its content and never grows rows on a narrow (`GridRow.visibleExtent`).
        var fillStyle: StyleId?
    }

    /// Relates an old visual row to its transient logical line and the offset after it.
    private struct ReflowRowMetadata {
        var line: Int
        var boundaryOffset: Int
    }

    /// Where in its line a tracked cursor sits, as a logical cell offset within that line.
    ///
    /// Two shapes and no third: a cursor on a cell the fold carries follows that cell; every
    /// other cursor follows the boundary after its row's units -- a pending wrap, the live cursor
    /// just past the blanks folded for it, or a saved slot past the fold bound, which is then its
    /// line's end. A distance past the content is not representable.
    ///
    /// Both cases are offsets, but they differ at the new margin, which is why they stay two
    /// cases: a cell offset resolves to wherever the cell covering it was placed, so a cell the
    /// pack pushed past the margin takes its cursor to the next row; a boundary offset folds onto
    /// the margin as last-column-plus-pending-wrap.
    private enum ReflowCursorAnchor {
        case cell(offset: Int)
        case boundary(offset: Int)
    }

    /// One position a width change carries through the refold: the live cursor, and the DECSC
    /// slot that has to come back onto the same text it was saved on.
    private struct TrackedCursor {
        var row: Int
        var column: Int
        var isPendingWrap: Bool
    }

    /// What one tracked cursor attaches to in the reconstructed lines.
    ///
    /// The second case exists because the refold only rebuilds rows down to the last row with a
    /// visible effect: a saved position on a default-blank row below that has no line to follow,
    /// so it is mapped by how far under the content it sat.
    private enum ReflowCursorAttachment {
        case inLine(line: Int, anchor: ReflowCursorAnchor)
        case belowContent(rowsBelow: Int, column: Int)
    }

    /// Records a cursor destination before the rebuilt stream is split into regions.
    private struct ReflowDestination {
        var row: Int
        var column: Int
        var isPendingWrap: Bool
    }

    /// Holds one packed logical line and the destinations its own walk resolved.
    ///
    /// The two destination arrays are positional answers to the offsets `pack` was asked about,
    /// not lookup tables: element *i* is where target *i* landed, and nil where the walk never
    /// reached that offset. Nothing here scales with the line's cells, which is the point --
    /// a refold resolves at most eleven targets and used to build a map of every cell to do it.
    private struct PackedReflowLine {
        var rows: [GridRow]
        var cellDestinations: [ReflowDestination?]
        var boundaryDestinations: [ReflowDestination?]
        var contentEnd: ReflowDestination
        /// Rows past the first that hold only blanks folded for the live cursor.
        var cursorOnlyRowCount: Int
    }

    private var columnCount: Int
    private var rowCount: Int

    /// Retained history, as one record per logical line printed (doc 31).
    ///
    /// Assigned in `init` rather than defaulted: the store owns the width its derived index is
    /// meaningful at, and there is no width until the terminal has one.
    ///
    /// Wrapped rather than stored bare so a mutation cannot leave the retained search index
    /// behind; `mutateHistory` is this terminal's only route to a door. See RetainedHistory.swift.
    private var history: RetainedHistory

    /// The store's monotone eviction counter as this terminal last saw it.
    ///
    /// Separate from `evictedRowCount`, which a hard reset restarts while history survives it, and
    /// which therefore cannot double as a high-water mark. The difference between the two counters
    /// is what `syncHistoryEvictions` hands `handleEviction`, so admission's own eviction and an
    /// explicit budget pass are reported through exactly one path.
    private var historyEvictionsObserved = 0
    private var screen: ScreenState
    private var screenOwnership = ScreenOwnership.primaryLive(alternate: nil)
    private var scrollRegion: Range<Int>?
    private var promptRedrawMode = PromptRedrawMode.full
    private var modes = TerminalModes()
    // Terminal-scoped, not per-screen: a raw 1047 switch changes no charset state in any
    // reference implementation, and storing it here is what makes that true for free.
    private var charsets = TerminalCharsetState()
    private var tabStops: BitSet
    private var lastPrintedCluster = LastPrintedCluster()
    private var clusterContext: ClusterContext?
    private var inputStream = TerminalInputStream()
    /// The host's effective focus for this pane, retained outside `modes` on purpose: the
    /// child owns mode 1004 and resets it, while focus is the host's fact and outlives every
    /// mode reset and screen switch. Holding it here is what lets a child that enables
    /// reporting late learn the state it missed. A terminal starts unfocused, so a pane that
    /// never received a focus callback reports the truth rather than a hopeful default.
    public private(set) var isFocused = false
    private var replyBytes: [UInt8] = []
    private var productIdentity: TerminalProductIdentity?
    private var defaultColors: TerminalDefaultColors
    private var evictedRowCount = 0
    // The three content-derived inspection fields below are read together, per printed
    // character, by `invalidateInspection`, whose guard rejects whenever all three are nil.
    // Each observer keeps `hasContentInspectionState` exact so that guard is one Bool load
    // instead of three optional loads. Selection is deliberately outside this cache because
    // overwrites preserve it and therefore have no selection work to gate.
    private var selection: SettledSelection? {
        didSet {
            if selection == nil { selectionRequiresNonemptyReflowResult = false }
        }
    }
    // Coordinate distance alone cannot distinguish a deliberate empty selection over blank
    // cells from a selection that originally covered content later erased by the child.
    // Reflow needs that provenance to drop only the latter when both anchors collapse.
    private var selectionRequiresNonemptyReflowResult = false
    private var search: Search? { didSet { refreshHasContentInspectionState() } }
    private var hoveredLinkState: InteractionLinkState? {
        didSet {
            refreshHasContentInspectionState()
            hoveredLinkRevisionCounter.value &+= 1
        }
    }
    private var armedLinkState: InteractionLinkState? {
        didSet { refreshHasContentInspectionState() }
    }

    /// Counts writes to `hoveredLinkState` so `DamageActionSnapshot` can notice a hover
    /// change without copying the link's refcounted target -- the whole point of `research/17/F7`.
    ///
    /// Reuses `ObservationGeneration` for its equality-neutral `==`: this is repaint
    /// bookkeeping, and two terminals with identical visible state must not compare
    /// unequal because one was hovered and unhovered along the way.
    ///
    /// The counter advances on every write, including one that stores an equal value, so
    /// the snapshot diff over-reports rather than under-reports. That direction is the safe
    /// one -- a redundant repaint of the hovered rows, never a missed one -- and it is why
    /// this replaces a value comparison instead of reimplementing one on a cheaper token:
    /// no token available here is a function of the link's URI (`activationIdentity` is
    /// `max(contentIdentity)` over the range's cells, and the public `TerminalResolvedLink`
    /// initializer assigns 0), so comparing tokens would miss a target change at an
    /// unchanged range. `TerminalHyperlinkInteractionTests` pins that case.
    private var hoveredLinkRevisionCounter = ObservationGeneration()

    /// Caches `search`/`hoveredLinkState`/`armedLinkState` being non-nil.
    ///
    /// Derived state, never assigned directly: the three observers above are its only writer.
    /// `false` is correct at initialization because all three fields start nil and property
    /// observers do not fire during initialization.
    private var hasContentInspectionState = false
    private var viewportState = ViewportState.following
    private var damage: TerminalDamage

    /// Total following-viewport rows advanced by scrolls recorded as damage
    /// shifts, in the same eviction-corrected units as `absoluteViewportTopRow`.
    /// Monotone forever; only ever read as a within-action delta by
    /// `recordDamage(from:to:)`, where it cancels exactly the topRow motion the
    /// recorded shift describes so the guard escalates only unaccounted moves.
    /// Wrapped in `ObservationGeneration` so path-dependent bookkeeping stays
    /// out of value equality, like every other observation counter here.
    private var scrollShiftAccountedAdvance = ObservationGeneration()
    private var hyperlinkTargets: [HyperlinkId: TerminalHyperlink] = [:]
    private var hyperlinkPen: HyperlinkId?
    private var nextHyperlinkId: HyperlinkId = 1
    private var nextContentIdentity: ContentIdentity = 1

    /// Resolves the id every cell carries. Seeded with the default style at `defaultStyleId` so a
    /// freshly-constructed `GridCell` needs no table access and the default entry is never swept.
    private var styleTable: [StyleId: TerminalStyle] = [defaultStyleId: TerminalStyle()]

    /// The reverse direction, which is what makes interning O(1) and keeps ids canonical: equal
    /// styles always intern to the same id, so `GridCell`'s synthesized `==` stays correct while
    /// comparing four bytes instead of nineteen.
    private var styleIds: [TerminalStyle: StyleId] = [TerminalStyle(): defaultStyleId]
    private var nextStyleId: StyleId = defaultStyleId + 1

    /// Table size that triggers a sweep. Raised past the surviving population after each one --
    /// sweeping is O(every cell), so a threshold that stayed put would re-sweep on nearly every
    /// intern once the live set legitimately sat above it.
    private var styleSweepThreshold = Terminal.baseStyleSweepThreshold
    private var machineHostname: String?
    private var pendingConsumerWork = PendingConsumerWork()
    private var nextSemanticEventOrder: UInt64 = 0
    private var primaryHistoryObservation = ObservationGeneration()

    /// The retained-history byte bound: the valve for rows whose bytes the cell cap cannot see.
    ///
    /// Raised from 10 MiB to 16 MiB by `research/28/D11`, because the two caps below no longer fit
    /// under the old budget. `research/28/F23` measured a full-width retained row at 179 columns costing
    /// **1,552 charged B/row**, so `research/28/D11`'s target depth needs `89,500 x 1,552` ~ 14.8 MiB and at
    /// 10 MiB the *byte* bound bound first, stopping a full-width fill at 6,756 rows. 16 MiB is
    /// that measured requirement plus headroom, not a round number chosen first.
    ///
    /// This is a per-pane figure, and `research/28/D11` is a trial: it gives back most of the 3.72 MB
    /// retained footprint `research/28/D10` banked. Read `research/28/D11` before treating it as settled.
    ///
    /// Public so measurement tools can report the budget they ran against. Deliberately just the
    /// constant: the budget-taking initializer stays internal, because the public initializer
    /// enforcing this fixed value is an invariant with its own test.
    public static let scrollbackByteLimit = 16_777_216

    /// Maximum UTF-8 payload retained for one live grapheme and its REP memory.
    ///
    /// Real terminals disagree: Alacritty grows zero-width storage without a cap
    /// (`references/alacritty/alacritty_terminal/src/term/cell.rs#Cell::push_zerowidth`),
    /// libvterm exposes six code points
    /// (`references/libvterm/include/vterm.h#VTERM_MAX_CHARS_PER_CELL`), and kitty stops at
    /// 24 to prevent denial of service (`references/kitty/kitty/screen.c#add_combining_char`).
    /// A byte limit also bounds synchronization payloads across scalar widths. It preserves
    /// at least 64 maximum-width scalars or 127 common two-byte combining marks in one cluster.
    public static let graphemeClusterByteLimit = 256

    /// The smallest budget the arena can be built at, which is the store's own precondition.
    ///
    /// Named so a test that wants the byte bound to bind early can size against it rather than
    /// discovering the floor as a failed initializer. Low enough that a fixture can ask for a
    /// two-line history: the arena's fixed costs -- the metadata reserve and the index rings'
    /// allocation -- are what a floor really buys, and both are small.
    static let minimumScrollbackBudgetBytes = 128

    static let kittyKeyboardStackDepth = 8
    static let maximumHyperlinkTargetBytes = 65_536

    /// Reserved for `TerminalStyle()`. Fixed so an unwritten cell costs no intern and no lookup.
    static let defaultStyleId: StyleId = 0

    /// Smallest table size worth a sweep. Well above the 1-5 distinct styles `research/15/F11` measured in
    /// ordinary output, so a normal session never sweeps at all.
    static let baseStyleSweepThreshold = 512
    /// The one ceiling retained hyperlink targets and retained semantic events are held
    /// against together. It is the retention surface's own limit, named here for the
    /// hyperlink side of the arithmetic so the two halves cannot diverge.
    static let maximumTerminalMetadataBytes = TerminalSemanticEventRetention.maximumRetainedBytes
    static let maximumSemanticValueBytes = 64 * 1_024
    static let maximumShellOSCBytes = 88 * 1_024
    static let maximumReplyBytes = 64 * 1_024

    /// Exposes aggregate retained link cost to structural bound tests.
    var retainedHyperlinkMetadataBytes: Int {
        hyperlinkTargets.values.reduce(0) { $0 + hyperlinkByteCost($1) }
            + InteractionLinkSlot.allCases.reduce(0) { cost, slot in
                cost + (self[slot].map { hyperlinkByteCost($0.hyperlink) } ?? 0)
            }
    }

    /// Exposes the shared hyperlink, interaction, and semantic retention cost to bound tests.
    var retainedTerminalMetadataBytes: Int {
        retainedHyperlinkMetadataBytes + retainedSemanticEventBytes
    }

    /// Exposes retained table cardinality for deduplication and sweep proofs.
    var retainedHyperlinkCount: Int { hyperlinkTargets.count }

    /// Exposes style-table cardinality to the sweep proofs in `TerminalStyleTableTests`.
    var retainedStyleCount: Int { styleTable.count }

    /// Makes the active bound visible to shared structural test assertions.
    ///
    /// The one bound history has since doc 31: the cell and row caps priced a width reflow of
    /// retained rows, and history is no longer reflowed (`research/31/D2` Decision 4).
    var scrollbackBudgetBytes: Int { history.store.budgetBytes }

    /// The store's own accounting, with budget, capacity and bytes-in-use reported separately so
    /// a proof can hold each against the others (`31/PO3`, `research/31/DD11`).
    var scrollbackCensus: LogicalLineStore.Census { history.store.census }

    /// Display rows retained history currently folds to at this width.
    ///
    /// Derived rather than counted since doc 31 -- it is the index's maintained grand total, not
    /// an array length -- which is why `research/31/D3` Decision 1 insists it stay O(1): the tree reads it
    /// around every `feed` and roughly 200 times per planned frame.
    private var historyRowCount: Int { history.store.grandDisplayRowTotal }

    /// Exposes the semantic SGR pen without allowing callers to mutate terminal state.
    ///
    /// The `didSet` is what keeps `H3` cheap. Every cell write sources its style from this pen or
    /// from `backgroundEraseStyle`, so interning can happen once per *pen change* -- thousands of
    /// times per corpus -- rather than once per *cell write*, which `research/15/F11` counted in the tens of
    /// millions. Invalidating here instead of interning eagerly also keeps a run of SGR parameters
    /// (each one a separate assignment) to a single intern at the first cell that uses the result.
    public private(set) var currentStyle = TerminalStyle() {
        didSet {
            guard currentStyle != oldValue else { return }
            currentStyleIdCache = nil
            backgroundEraseStyleIdCache = nil
        }
    }

    private var currentStyleIdCache: StyleId?
    private var backgroundEraseStyleIdCache: StyleId?

    /// Projects application-controlled presentation state for render scheduling and drawing.
    public var presentation: TerminalPresentation {
        TerminalPresentation(
            isCursorVisible: modes.isCursorVisible,
            cursorShape: modes.cursorShape,
            isCursorBlinking: modes.isCursorBlinking,
            isSynchronizedOutputActive: modes.isSynchronizedOutputActive
        )
    }

    /// Serializes observable engine state into bytes accepted by an ordinary reset terminal.
    public var stateSynchronization: TerminalStateSynchronization {
        stateSynchronization(historyBudgetBytes: nil)
    }

    /// Serializes observable engine state while spending at most `historyBudgetBytes` on
    /// retained history; `nil` carries all of it.
    ///
    /// The budget belongs to the caller, not to this encoder: an exact consumer -- a pane
    /// snapshot, a replica checkpoint -- passes `nil` and keeps the whole retained state,
    /// while a bounded replication stream passes its own budget. The grid, the alternate
    /// screen, and control state are always carried whole, so the returned payload exceeds
    /// the budget by that screen-proportional cost.
    public func stateSynchronization(
        historyBudgetBytes: Int?
    ) -> TerminalStateSynchronization {
        TerminalStateSynchronizationEncoder(input: stateSynchronizationInput)
            .encode(historyBudgetBytes: historyBudgetBytes)
    }

    /// Supplies the encoder with one read-only value snapshot of every serialization dependency.
    private var stateSynchronizationInput: TerminalStateSynchronizationEncoder.Input {
        TerminalStateSynchronizationEncoder.Input(
            columnCount: columnCount,
            rowCount: rowCount,
            history: history.store,
            primaryScreenRows: primaryScreenRows,
            primaryScreenState: primaryScreenState,
            retainedAlternateScreen: retainedAlternateScreenWorthSending,
            screen: screen,
            isAlternateScreenActive: isAlternateScreenActive,
            scrollRegion: scrollRegion,
            activeScrollRegion: activeScrollRegion,
            tabStops: tabStops,
            modes: modes,
            currentStyle: currentStyle,
            hyperlinkTargets: hyperlinkTargets,
            hyperlinkPen: hyperlinkPen,
            styleTable: styleTable,
            promptRedrawMode: promptRedrawMode,
            lastPrintedCluster: lastPrintedCluster,
            clusterContext: clusterContext,
            charsets: charsets,
            inputSynchronizationPrefix: inputStream.synchronizationPrefix
        )
    }

    private func charsetSynchronizationState(_ value: String) -> TerminalCharsetState? {
        let fields = value.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        let finals = Array(fields[0].utf8)
        guard finals.count == 4 else { return nil }
        var state = TerminalCharsetState()
        for (index, final) in finals.enumerated() {
            guard let charset = TerminalCharset(designationFinal: final),
                  let slot = TerminalCharsetSlot(rawValue: UInt8(index))
            else { return nil }
            state[slot] = charset
        }
        guard let invokedRaw = UInt8(fields[1]),
              let invoked = TerminalCharsetSlot(rawValue: invokedRaw)
        else { return nil }
        state.invokedSlot = invoked
        if fields[2] != "none" {
            guard let shiftRaw = UInt8(fields[2]),
                  let shift = TerminalCharsetSlot(rawValue: shiftRaw)
            else { return nil }
            state.pendingSingleShift = shift
        }
        return state
    }

    /// Lets the serialized PTY owner route semantic wheel intent without a lagging snapshot.
    public var isAlternateScreenActive: Bool {
        if case .alternateLive = screenOwnership { return true }
        return false
    }

    /// Selects the offscreen grid when one exists, independent of which screen is live.
    private var offscreenScreen: ScreenState? {
        switch screenOwnership {
        case .primaryLive(let alternate): alternate
        case .alternateLive(let primary): primary
        }
    }

    /// Yields the retained alternate screen only when re-entering it would show or restore
    /// something a screen the replica has never entered would not.
    ///
    /// Mode 47 makes an offscreen grid re-enterable without a clear, so everything the
    /// inactive alternate holds is state a program can bring straight back. What does not
    /// survive re-entry is excluded from the comparison: the switch carries the live cursor
    /// across and drops pending wrap, so neither can differ observably.
    private var retainedAlternateScreenWorthSending: ScreenState? {
        guard case .primaryLive(let alternate) = screenOwnership, var retained = alternate else {
            return nil
        }
        let pristine = ScreenState(
            rows: Deque((0..<rowCount).map { _ in makeBlankRow(columns: columnCount) })
        )
        retained.cursor = pristine.cursor
        retained.isPendingWrap = pristine.isPendingWrap
        return retained == pristine ? nil : alternate
    }

    /// Selects the complete primary state regardless of which screen is currently live.
    private var primaryScreenState: ScreenState {
        switch screenOwnership {
        case .primaryLive: screen
        case .alternateLive(let primary): primary
        }
    }

    /// Selects the primary grid regardless of which screen is currently live.
    private var primaryScreenRows: Deque<GridRow> {
        switch screenOwnership {
        case .primaryLive: screen.rows
        case .alternateLive(let primary): primary.rows
        }
    }

    /// Projects all child-controlled modes that affect deterministic user-input bytes.
    public var inputModes: TerminalInputModes {
        TerminalInputModes(
            applicationCursorKeys: modes.isApplicationCursorKeysMode,
            applicationKeypad: modes.isApplicationKeypadMode,
            lineFeedNewLine: modes.isLineFeedNewLineMode,
            focusReporting: modes.isFocusReportingMode,
            bracketedPaste: modes.isBracketedPasteMode,
            mouseTracking: modes.mouseTrackingMode,
            sgrMouseEncoding: modes.isSGRMouseEncodingMode,
            alternateScroll: modes.isAlternateScrollMode,
            kittyKeyboardFlags: screen.control.kittyKeyboardStack.last ?? []
        )
    }

    /// Retains the host's effective focus and returns the report the child has earned.
    ///
    /// The host states focus; the terminal decides the bytes, because only it knows whether
    /// the child asked for reports. The returned bytes are transmitted at the moment of the
    /// change so an otherwise silent child hears about it without waiting for output of its
    /// own; the enable-time report goes through the ordered reply queue instead, where it
    /// stays behind the bytes that enabled it.
    public mutating func setFocused(_ focused: Bool) -> [UInt8] {
        guard focused != isFocused else { return [] }
        isFocused = focused
        guard modes.isFocusReportingMode else { return [] }
        return Array(Self.focusReport(focused).utf8)
    }

    private static func focusReport(_ focused: Bool) -> String {
        focused ? "\u{1B}[I" : "\u{1B}[O"
    }

    /// Exposes terminal-generated bytes until the serialized host routes them to the child.
    public var pendingReplyBytes: [UInt8] {
        replyBytes
    }

    /// Reports whether a frame consumer has redraw work or a completed semantic write to drain.
    public var hasPendingConsumerWork: Bool {
        damage.isEmpty == false || pendingConsumerWork.hasWork
    }

    /// Lets the serialized host detect accumulator changes without copying terminal storage.
    public var pendingConsumerWorkGeneration: UInt64 {
        pendingConsumerWork.generation.value
    }

    /// Lets recovery consumers classify primary-text frames before materializing their projection.
    public var primaryHistoryGeneration: UInt64 {
        primaryHistoryObservation.value
    }

    /// Transfers all ordered terminal replies to one consumer without a parallel output path.
    public mutating func drainReplyBytes() -> [UInt8] {
        let drained = replyBytes
        replyBytes.removeAll(keepingCapacity: true)
        return drained
    }

    /// Transfers the newest completed clipboard write while preserving empty-string clears.
    public mutating func drainPendingClipboardWrite() -> String? {
        pendingConsumerWork.drainClipboardWrite()
    }

    /// Transfers the retained semantic batch in terminal-stream order and clears its budget share.
    public mutating func drainSemanticEvents() -> [TerminalSemanticEvent] {
        pendingConsumerWork.drainSemanticEvents()
    }

    /// Transfers all accumulated logical redraw work to one frame consumer.
    public mutating func drainDamage() -> TerminalDamage {
        damage.drain()
    }

    @inline(__always)
    private var damageActionSnapshot: DamageActionSnapshot {
        // Derived, not read through `scrollProjection`: this runs once per parser action from
        // inside a `mutating` method, where a member read copies the whole terminal
        // (`research/39/F2`, `D5`).
        let projection = Terminal.deriveScrollProjection(
            isAlternateScreenActive: isAlternateScreenActive,
            rowCount: rowCount,
            historyRowCount: historyRowCount,
            viewportState: viewportState,
            evictedRowCount: evictedRowCount
        )
        let cursorStreamRow = isAlternateScreenActive
            ? screen.cursor.row
            : historyRowCount + screen.cursor.row
        let cursorWindowRow = cursorStreamRow - projection.topRow
        return DamageActionSnapshot(
            cursor: (0..<rowCount).contains(cursorWindowRow)
                ? TerminalCursor(
                    row: cursorWindowRow,
                    column: screen.cursor.column,
                    isPendingWrap: screen.isPendingWrap
                )
                : nil,
            selection: selectionRange,
            hoveredLinkRange: hoveredLinkState.flatMap { publicRange($0.range) },
            hoveredLinkRevision: hoveredLinkRevisionCounter.value,
            absoluteTopRow: evictedRowCount + projection.topRow,
            scrollShiftAdvance: scrollShiftAccountedAdvance.value,
            isFollowing: projection.isFollowing,
            isAlternateScreenActive: isAlternateScreenActive,
            cursorPresentation: presentation
        )
    }

    /// Diffs the state now against a snapshot taken before one action. See
    /// `recordDamage(from:to:)`, which does the work.
    private mutating func recordDamage(since before: DamageActionSnapshot) {
        recordDamage(from: before, to: damageActionSnapshot)
    }

    /// Records only the render deltas implied by a cursor/selection/search/hover snapshot diff.
    ///
    /// Every statement here is presentation-only, so none advances the history generation:
    /// callers do mutate cells around this call, but that content reaches the generation
    /// through its own funnels (`invalidateInspection`, scrollback append, budget eviction).
    /// This is a global maintenance obligation: any new content mutation reachable
    /// from a caller must use an independently bumping path and extend
    /// `contentFunnelsAdvanceGenerationWhileScrolledBack`.
    /// Bumping here as well would make "generation advanced" unreadable as "history changed",
    /// since a bare cursor move or selection drag would trip it.
    ///
    /// Taking `after` as a parameter rather than reading it is what lets `feed` carry each
    /// action's "after" forward as the next action's "before". That is sound because nothing
    /// runs between the two points and every statement below writes only `damage` and
    /// `pendingConsumerWork`, neither of which `damageActionSnapshot` reads -- so the carried
    /// value is bit-for-bit what a fresh capture would produce. Anything added here that mutates
    /// snapshot-visible state breaks that, and no test would catch it (see `research/10/F8`);
    /// it belongs at the call site instead.
    private mutating func recordDamage(
        from before: DamageActionSnapshot,
        to after: DamageActionSnapshot
    ) {
        if before.isFollowing == false {
            recordPresentationFullDamage()
            return
        }
        // A viewport advance is escalated only when nothing describes it: the
        // scroll site records each following-viewport push as a shift and bumps
        // the accounted advance by the same amount, so a scroll's topRow motion
        // cancels out here in both history regimes, while every unaccounted
        // move -- resize reflow, scrollback clears, anything new -- still
        // escalates exactly as before (research/33 T9, D7's guard narrowing).
        let accountedAdvance = Int(after.scrollShiftAdvance &- before.scrollShiftAdvance)
        guard before.absoluteTopRow + accountedAdvance == after.absoluteTopRow,
              before.isAlternateScreenActive == after.isAlternateScreenActive
        else {
            recordPresentationFullDamage()
            return
        }
        if after.isFollowing == false {
            recordPresentationFullDamage()
            return
        }
        if before.cursor != after.cursor
            || before.cursorPresentation != after.cursorPresentation
        {
            if let row = before.cursor?.row { recordPresentationDamage(row: row) }
            if let row = after.cursor?.row { recordPresentationDamage(row: row) }
        }
        if before.selection != after.selection {
            recordPresentationDamage(rows: damagedViewportRows(for: before.selection))
            recordPresentationDamage(rows: damagedViewportRows(for: after.selection))
        }
        // Two independent reasons the hovered run can need repainting, and neither implies
        // the other: the stored link changed (`hoveredLinkRevision`), or it did not change
        // while the projection moved under it, so the same anchors now name different
        // viewport rows (`hoveredLinkRange`). Eviction reindexes rows without touching
        // `hoveredLinkState`, which is exactly the second case.
        if before.hoveredLinkRevision != after.hoveredLinkRevision
            || before.hoveredLinkRange != after.hoveredLinkRange
        {
            recordPresentationDamage(rows: damagedViewportRows(for: before.hoveredLinkRange))
            recordPresentationDamage(rows: damagedViewportRows(for: after.hoveredLinkRange))
        }
    }

    private mutating func recordFullDamage() {
        recordPresentationFullDamage()
        notePrimaryHistoryDamage()
    }

    private mutating func recordDamage(row: Int) {
        recordPresentationDamage(rows: widenedSearchDamageRows(for: row..<(row + 1)))
        notePrimaryHistoryDamage()
    }

    private mutating func recordDamage(rows: Range<Int>) {
        recordPresentationDamage(rows: widenedSearchDamageRows(for: rows))
        notePrimaryHistoryDamage()
    }

    private func widenedSearchDamageRows(for source: Range<Int>) -> Range<Int> {
        guard source.isEmpty == false, let search else { return source }
        let radius = search.damageRowRadius
        let lower = max(0, source.lowerBound - radius)
        let upper = min(rowCount, source.upperBound + radius)
        return lower..<upper
    }

    // The non-bumping variants below are the exception, not the rule: bumping stays the default
    // so the failure mode of a future miscategorized call site is a redundant recovery write,
    // never a lost one. A direct damage call outside `recordDamage(since:)` may use them only
    // when the mutation it follows touches `viewportState`/`search` alone -- never cell storage
    // -- and cannot run behind an active alternate screen. `invalidateInspection(inViewportRows:)`
    // reads presentational but fails that test: its full-damage branch follows a cell write and
    // is the content funnel for scrolled-back output.

    private mutating func recordPresentationFullDamage() {
        if damage.recordFull() { pendingConsumerWork.noteDamageChanged() }
    }

    private mutating func recordPresentationDamage(row: Int) {
        if damage.record(row: row) { pendingConsumerWork.noteDamageChanged() }
    }

    private mutating func recordPresentationDamage(rows: some Sequence<Int>) {
        if damage.record(rows: rows) { pendingConsumerWork.noteDamageChanged() }
    }

    private mutating func notePrimaryHistoryDamage() {
        if isAlternateScreenActive == false { primaryHistoryObservation.value &+= 1 }
    }

    private func damagedViewportRows(for range: TerminalTextRange?) -> Range<Int> {
        guard let range, range.start != range.end else { return 0..<0 }
        let top = scrollProjection.topRow
        let lower = max(range.start.row, top)
        let upper = min(range.end.row, top + rowCount - 1)
        guard lower <= upper else { return 0..<0 }
        return (lower - top)..<(upper - top + 1)
    }

    private var backgroundEraseStyle: TerminalStyle {
        TerminalStyle(
            foreground: currentStyle.foreground,
            background: currentStyle.background
        )
    }

    /// Interned id of the SGR pen, for the print path.
    private mutating func currentStyleId() -> StyleId {
        if let currentStyleIdCache { return currentStyleIdCache }
        let id = internStyle(currentStyle)
        currentStyleIdCache = id
        return id
    }

    /// Interned id of the erase pen, for every path that blanks cells.
    private mutating func backgroundEraseStyleId() -> StyleId {
        if let backgroundEraseStyleIdCache { return backgroundEraseStyleIdCache }
        let id = internStyle(backgroundEraseStyle)
        backgroundEraseStyleIdCache = id
        return id
    }

    /// Resolves a cell's stored id. Total by construction: `styleId` is only ever set from an id
    /// this type issued, and the sweep only drops ids no cell holds, so a miss would mean the
    /// invariant on `reclaimDeadStyleEntries` had already been violated.
    private func style(for id: StyleId) -> TerminalStyle {
        styleTable[id] ?? TerminalStyle()
    }

    /// Maps a style to the id cells store, minting one only for a value the table has not seen.
    ///
    /// Sweeps before minting when the table has grown past its threshold, which is the only thing
    /// bounding it: entries die when their last cell does, and nothing else notices that happening.
    private mutating func internStyle(_ style: TerminalStyle) -> StyleId {
        if let existing = styleIds[style] { return existing }
        if styleTable.count >= styleSweepThreshold { reclaimDeadStyleEntries() }
        if let existing = styleIds[style] { return existing }

        guard let id = allocateStyleId() else { return Self.defaultStyleId }
        styleTable[id] = style
        styleIds[style] = id
        return id
    }

    /// Issues an id no cell can already be pointing at, on the same invariant and by the same
    /// method as `allocateHyperlinkId`: entries only ever leave `styleTable` through the live-set
    /// filter in `reclaimDeadStyleEntries`, so an id absent from the table is absent from the grid.
    ///
    /// Recycling rather than counting up is what keeps the space unreachable rather than merely
    /// large. A monotonic counter exhausts after 2^32 *distinct styles ever interned*, which a few
    /// hours of full-screen truecolor video reaches -- and past that every new color would render
    /// as the default, permanently. Recycling changes the bound to 2^32 styles live *at once*,
    /// which the cells holding them would exhaust memory long before reaching. Scanning from a
    /// rotating cursor keeps that amortized O(1); `defaultStyleId` is skipped for free because its
    /// entry is always present.
    private mutating func allocateStyleId() -> StyleId? {
        guard styleTable.count <= Int(StyleId.max) else { return nil }
        var candidate = nextStyleId
        while styleTable[candidate] != nil { candidate &+= 1 }
        nextStyleId = candidate &+ 1
        return candidate
    }

    private func liveStyleIds() -> Set<StyleId> {
        var live: Set<StyleId> = [Self.defaultStyleId]
        func collect(_ rows: Deque<GridRow>, into live: inout Set<StyleId>) {
            for row in rows {
                for cell in row.cells { live.insert(cell.styleId) }
            }
        }
        history.store.forEachStyleId { live.insert($0) }
        collect(screen.rows, into: &live)
        if let offscreenScreen { collect(offscreenScreen.rows, into: &live) }
        return live
    }

    /// Drops table entries no cell points at, on the same invariant `allocateHyperlinkId` states:
    /// **every id held by a cell is a key of `styleTable`**. `liveStyleIds` walks history, the
    /// active grid, and the inactive screen, which is every place a cell lives; the pens
    /// are covered by dropping their caches rather than by walking them, since a pen's id is
    /// re-interned on demand.
    private mutating func reclaimDeadStyleEntries() {
        let live = liveStyleIds()
        styleTable = styleTable.filter { live.contains($0.key) }
        styleIds = styleIds.filter { live.contains($0.value) }
        currentStyleIdCache = nil
        backgroundEraseStyleIdCache = nil
        styleSweepThreshold = max(Self.baseStyleSweepThreshold, styleTable.count * 2)
    }

    /// The narrowest grid that can represent every supported cell: a double-width cell needs a
    /// column to occupy and a column to spill its spacer into.
    public static let minimumColumns = 2

    /// One row, because a terminal with no rows has nowhere to put the cursor.
    public static let minimumRows = 1

    /// Whether `init` will build this geometry, asked without building it.
    ///
    /// Exists so a caller can refuse a geometry before it does work the answer invalidates. The
    /// memory probe is the case that needs it: constructing a terminal to find out would allocate
    /// an arena inside the very window whose footprint delta the first payload reports, and the
    /// probes' `--columns` and `--rows` minimums would otherwise each restate this bound in their
    /// own file. `init` answers through this, so there is one statement of what is representable.
    public static func acceptsGeometry(columns: Int, rows: Int) -> Bool {
        columns >= minimumColumns && rows >= minimumRows
    }

    /// Rejects dimensions that cannot represent all supported terminal cells, and a
    /// scrollback budget the store cannot use. Production keeps the 16 MiB default; a
    /// deterministic test passes a small budget to make eviction reachable.
    ///
    /// The lower bound is the arena's: the store fixes its whole address-space capacity at
    /// construction and holds it below the budget by a metadata reserve (`research/31/DD36`),
    /// even though physical backing materializes lazily. A budget too small to hold a record
    /// plus its index is not a shallower history but an unusable one.
    public init?(
        columns: Int,
        rows: Int,
        scrollbackBudgetBytes: Int = Terminal.scrollbackByteLimit,
        machineHostname: String? = nil,
        productIdentity: TerminalProductIdentity? = nil,
        defaultColors: TerminalDefaultColors = .baked
    ) {
        guard Self.acceptsGeometry(columns: columns, rows: rows),
            scrollbackBudgetBytes >= Self.minimumScrollbackBudgetBytes
        else {
            return nil
        }
        columnCount = columns
        rowCount = rows
        history = RetainedHistory(store: LogicalLineStore(
            budgetBytes: scrollbackBudgetBytes & ~7,
            width: columns
        ))
        self.machineHostname = machineHostname
        self.productIdentity = productIdentity
        self.defaultColors = defaultColors
        tabStops = Self.defaultTabStops(columns: columns)
        damage = TerminalDamage(rowCount: rows, isFull: true)
        screen = ScreenState(
            rows: Deque((0..<rows).map { _ in
                GridRow(cells: (0..<columns).map { _ in GridCell() })
            })
        )
    }

    /// Updates protocol-visible defaults without treating configuration as grid damage.
    public mutating func setDefaultColors(_ colors: TerminalDefaultColors) {
        defaultColors = colors
    }

    /// Reduces a byte chunk synchronously while retaining unfinished stream state.
    public mutating func feed(_ bytes: [UInt8]) {
        // The buffer is what print-run ranges index, and what the parser recognizes from;
        // it is obtained once per feed rather than per token.
        bytes.withUnsafeBufferPointer { buffer in
            feedBuffer(buffer)
        }
    }

    /// Reduces bytes the caller already holds contiguously, so a reader that fills its own
    /// buffer does not have to copy each chunk into an `Array` first.
    ///
    /// The buffer is borrowed for the duration of the call only: every piece of unfinished
    /// stream state -- the UTF-8 decoder, the escape absorber, the synchronization prefix --
    /// accumulates by value, so the caller may overwrite these bytes as soon as this returns.
    public mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
        feedBuffer(bytes)
    }

    /// Pulls one action at a time and applies it before the next is recognized, so the token
    /// stream is never materialized as an array (`research/33/F9` sized the one this replaced at
    /// 60-80x the corpus's own byte count in allocator traffic). The first action is pulled before
    /// the first snapshot because a chunk that ends mid-sequence produces none, and that feed
    /// should cost nothing.
    private mutating func feedBuffer(_ bytes: UnsafeBufferPointer<UInt8>) {
        // One scratch for the whole feed, sized once by the stretch cap. It is where the stream
        // leaves the scalars it decoded and the writer it classified each into, so this feed turns
        // each of the chunk's bytes into a scalar exactly once (`research/39/D9`): every stretch is
        // applied before the next action is recognized, so one stretch's entries may be
        // overwritten by the next.
        TerminalStretchScratch.withScratch { scratch in
            var index = 0
            guard var action = inputStream.nextAction(in: bytes, from: &index, into: scratch)
            else { return }
            // One snapshot per action, not two. Action N's "after" is bit-for-bit what action
            // N+1 would capture as its "before": the only things that run between them are
            // `recordDamage`, which writes damage bookkeeping the snapshot does not read, and
            // the parse step, which touches only the decoder and absorber inside `inputStream`
            // -- and the snapshot reads neither. So carrying it forward is the same diff
            // sequence at half the construction cost.
            var before = damageActionSnapshot
            while true {
                apply(action, in: bytes, from: scratch, before: &before)
                guard let next = inputStream.nextAction(in: bytes, from: &index, into: scratch)
                else { return }
                action = next
            }
        }
    }

    /// `@inline(never)` from measurement, not taste: letting the optimizer inline this dispatch
    /// into the pull loop cost a further 1.5 points on the drain (`research/33/F15`).
    @inline(never)
    private mutating func apply(
        _ action: TerminalStreamAction,
        in bytes: UnsafeBufferPointer<UInt8>,
        from scratch: TerminalStretchScratch,
        before: inout DamageActionSnapshot
    ) {
        switch action {
        case let .printASCIIRun(range):
            printASCIIRun(bytes, range)
        case let .printTextStretch(_, scalarCount):
            printTextStretch(scratch, scalarCount: scalarCount)
        case let .print(printed):
            print(printed.scalar, classification: printed.classification)
        case let .execute(control):
            if control == 0x07 {
                admitSemanticEvent(.bell)
            } else {
                execute(control)
            }
        case let .escape(final):
            dispatchEscape(final)
        case let .escapeSequence(sequence):
            dispatchEscape(sequence)
        case let .csi(sequence):
            dispatchCSI(sequence)
        case let .osc(payload):
            dispatchOSC(payload)
        case let .dcs(sequence):
            dispatchDCS(sequence)
        }
        let after = damageActionSnapshot
        recordDamage(from: before, to: after)
        before = after
    }

    /// Answers the DCS routes the parser hands over; every other DCS family never reaches here.
    private mutating func dispatchDCS(_ sequence: DCSSequence) {
        switch sequence.route {
        case .decrqss:
            dispatchDECRQSS(sequence)
        case .xtgettcap:
            dispatchXTGETTCAP(sequence)
        }
    }

    /// XTGETTCAP: answers capability values from the generated projection of the contract.
    ///
    /// The projection is the whole roster, so this reads no grid state and adds no second
    /// list: a name DanTerm does not publish in `docs/terminal-capabilities.md` misses here.
    /// A parameterized header is rejected the same way DECRQSS rejects one.
    private mutating func dispatchXTGETTCAP(_ sequence: DCSSequence) {
        guard sequence.parameters.isNone else {
            appendReply("\u{1B}P0+r\u{1B}\\")
            return
        }
        appendReply(TerminalCapabilityQuery.reply(for: sequence.body))
    }

    /// DECRQSS: reports the current value of one setting, or reports the request invalid.
    ///
    /// The reply never echoes the request. Reflecting an attacker-supplied query back into the
    /// stream is CVE-2008-2383, and a request that misses carries no information the sender needs
    /// back (`docs/design/2026-08-06-swift-terminal-engine.md` I5).
    private mutating func dispatchDECRQSS(_ sequence: DCSSequence) {
        guard sequence.parameters.isNone, let status = decrqssStatus(for: sequence.body) else {
            appendReply("\u{1B}P0$r\u{1B}\\")
            return
        }
        appendReply("\u{1B}P1$r\(status)\u{1B}\\")
    }

    /// Maps a DECRQSS request body to its status string, or nil when DanTerm does not report it.
    ///
    /// The roster is stated rather than derived from "settings DanTerm models": whether a request
    /// draws a valid reply is observable, so it is contract. DECSLRM and DECSACE are absent
    /// because DanTerm models neither.
    private func decrqssStatus(for body: [UInt8]) -> String? {
        switch body {
        case Array("m".utf8):
            TerminalSettingReport.selectGraphicRendition(currentStyle)
        case Array("r".utf8):
            TerminalSettingReport.setTopAndBottomMargins(activeScrollRegion)
        case Array(" q".utf8):
            TerminalSettingReport.setCursorStyle(
                shape: modes.cursorShape,
                blinking: modes.isCursorBlinking
            )
        case Array("\"q".utf8):
            TerminalSettingReport.selectCharacterProtection(currentStyle.protected)
        default:
            nil
        }
    }

    private mutating func dispatchOSC(_ payload: [UInt8]) {
        guard let selectorEnd = payload.firstIndex(of: 0x3B), selectorEnd > payload.startIndex,
              let selector = OSCPayload.parseOSCSelector(payload[..<selectorEnd])
        else { return }
        switch selector {
        case 0, 2:
            dispatchTitle(payload, selectorEnd: selectorEnd)
        case 7:
            dispatchOSC7(payload, selectorEnd: selectorEnd)
        case 8:
            dispatchOSC8(payload, selectorEnd: selectorEnd)
        case 9:
            dispatchOSC9(payload, selectorEnd: selectorEnd)
        case 10:
            dispatchDefaultColorQuery(
                payload,
                selectorEnd: selectorEnd,
                selector: selector,
                color: defaultColors.foreground
            )
        case 11:
            dispatchDefaultColorQuery(
                payload,
                selectorEnd: selectorEnd,
                selector: selector,
                color: defaultColors.background
            )
        case 52:
            dispatchOSC52(payload, selectorEnd: selectorEnd)
        case 133:
            dispatchOSC133(payload, selectorEnd: selectorEnd)
        case 1337:
            dispatchDanTermShell(payload, selectorEnd: selectorEnd)
        case 777:
            dispatchOSC777(payload, selectorEnd: selectorEnd)
        default:
            break
        }
    }

    private mutating func dispatchDefaultColorQuery(
        _ payload: [UInt8],
        selectorEnd: Int,
        selector: Int,
        color: TerminalRGBColor
    ) {
        guard payload[(selectorEnd + 1)...].elementsEqual([0x3F]) else { return }
        appendReply("\u{1B}]\(selector);rgb:\(OSCPayload.oscColorComponent(color.red))/"
            + "\(OSCPayload.oscColorComponent(color.green))/"
            + "\(OSCPayload.oscColorComponent(color.blue))\u{1B}\\")
    }

    private mutating func dispatchOSC133(_ payload: [UInt8], selectorEnd: Int) {
        let command = Array(payload[payload.index(after: selectorEnd)...])
        guard let action = command.first else { return }
        if action == 0x4C { // L takes no options.
            guard command.count == 1 else { return }
        } else {
            guard [0x41, 0x42, 0x49, 0x43, 0x44, 0x4E, 0x50, 0x53].contains(action),
                  command.count == 1 || command[1] == 0x3B
            else { return }
        }

        let options = command.count > 2 ? Array(command.dropFirst(2)) : []
        switch action {
        case 0x41, 0x4E: // A, N
            semanticPromptFreshLine()
            setSemanticPrompt(kind: semanticPromptKind(in: options))
            if let redraw = semanticPromptOption("redraw", in: options) {
                switch redraw {
                case "0": promptRedrawMode = .disabled
                case "1": promptRedrawMode = .full
                case "last": promptRedrawMode = .last
                default: break
                }
            }
        case 0x50: // P
            setSemanticPrompt(kind: semanticPromptKind(in: options))
        case 0x42: // B
            screen.semanticContent = .input
            screen.semanticContentClearsAtEndOfLine = false
        case 0x49: // I
            screen.semanticContent = .input
            screen.semanticContentClearsAtEndOfLine = true
        case 0x43: // C
            screen.semanticContent = .output
            screen.semanticContentClearsAtEndOfLine = false
            // Stamp even when output starts partway through the prompt row: the row now
            // holds output and must stop every later prompt-block search.
            // Kitty marks it the same way (`references/kitty/kitty/screen.c#shell_prompt_marking`).
            screen.rows[screen.cursor.row].semanticPrompt = .output
        case 0x44: // D
            screen.semanticContent = .output
            screen.semanticContentClearsAtEndOfLine = false
        case 0x4C: // L
            semanticPromptFreshLine()
        case 0x53: // S is DanTerm's state-only synchronization form.
            applySemanticSynchronizationState(options)
        default:
            break
        }
    }

    private mutating func applySemanticSynchronizationState(_ options: [UInt8]) {
        if let redraw = semanticPromptOption("redraw", in: options) {
            switch redraw {
            case "0": promptRedrawMode = .disabled
            case "1": promptRedrawMode = .full
            case "last": promptRedrawMode = .last
            default: break
            }
        }
        if let mark = semanticPromptOption("mark", in: options) {
            screen.rows[screen.cursor.row].semanticPrompt = switch mark {
            case "none": .none
            case "prompt": .prompt
            case "continuation": .continuation
            case "output": .output
            case "vacated": .vacated
            default: screen.rows[screen.cursor.row].semanticPrompt
            }
        }
        if let wrap = semanticPromptOption("wrap", in: options) {
            switch wrap {
            case "hard":
                screen.rows[screen.cursor.row].isSoftWrapped = false
                screen.rows[screen.cursor.row].marginProvenance = .content
            case "soft":
                screen.rows[screen.cursor.row].isSoftWrapped = true
                screen.rows[screen.cursor.row].marginProvenance = .content
            case "stale":
                screen.rows[screen.cursor.row].isSoftWrapped = true
                screen.rows[screen.cursor.row].marginProvenance = .erase
            default:
                break
            }
        }
        if let repeatValue = semanticPromptOption("repeat", in: options) {
            applyRepeatSynchronizationState(repeatValue)
        }
        if let repeatValue = semanticPromptOption("repeat-add", in: options) {
            appendRepeatSynchronizationState(repeatValue)
        }
        if let clusterValue = semanticPromptOption("cluster", in: options) {
            applyClusterSynchronizationState(clusterValue)
        }
        if let charsetValue = semanticPromptOption("charset-saved", in: options),
           let state = charsetSynchronizationState(charsetValue) {
            screen.control.savedCursor.charsets = state
        }
        if let charsetValue = semanticPromptOption("charset", in: options),
           let state = charsetSynchronizationState(charsetValue) {
            charsets = state
        }
    }

    private mutating func applyRepeatSynchronizationState(_ value: String) {
        guard value == "none" else { return }
        lastPrintedCluster.clear()
        // The memory no longer says what any open cluster holds, so the printer must read that
        // cell back rather than extend this one (`ClusterContext.memoryMirrorsTarget`).
        clusterContext?.memoryMirrorsTarget = false
    }

    private mutating func appendRepeatSynchronizationState(_ value: String) {
        let fields = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2,
              let width = Int(fields[0]),
              width == 1 || width == 2,
              let appended = synchronizationScalars(fields[1])
        else { return }
        let wasPresent = lastPrintedCluster.isPresent
        if wasPresent {
            guard lastPrintedCluster.cellWidth == width else { return }
        }
        // Same reason as `applyRepeatSynchronizationState`: a memory this stream wrote names
        // whatever the stream says, not the cell an open cluster context targets.
        clusterContext?.memoryMirrorsTarget = false
        for scalar in appended {
            guard lastPrintedCluster.append(
                scalar,
                upToUTF8ByteCount: Self.graphemeClusterByteLimit
            ) else { break }
        }
        // The width belongs to a memory that exists. A chunk that opened no memory at all must
        // leave this terminal equal to one that never received it, width included.
        if wasPresent == false, lastPrintedCluster.isPresent {
            lastPrintedCluster.cellWidth = width
        }
    }

    private func synchronizationScalars(_ value: Substring) -> [Unicode.Scalar]? {
        let scalarValues = value.split(separator: ",", omittingEmptySubsequences: false)
        guard scalarValues.isEmpty == false else { return nil }
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(scalarValues.count)
        for value in scalarValues {
            guard let codePoint = UInt32(value, radix: 16),
                  let scalar = Unicode.Scalar(codePoint)
            else { return nil }
            scalars.append(scalar)
        }
        return scalars
    }

    private mutating func applyClusterSynchronizationState(_ value: String) {
        if value == "none" {
            clusterContext = nil
            return
        }
        let fields = value.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 4,
              let row = Int(fields[0]),
              let column = Int(fields[1]),
              screen.rows.indices.contains(row),
              screen.rows[row].cells.indices.contains(column),
              let previousRaw = UInt8(fields[2]),
              let previousClass = GraphemeBreakClass(rawValue: previousRaw),
              let stateRaw = UInt8(fields[3]),
              let breakState = graphemeBreakState(code: stateRaw)
        else { return }
        clusterContext = ClusterContext(
            target: CellPosition(row: row, column: column),
            previousClass: previousClass,
            breakState: breakState,
            retainedUTF8ByteCount: screen.rows[row]
                .scalars(of: screen.rows[row].cells[column]).reduce(0) {
                $0 + TerminalScalars.utf8ByteCount(of: $1)
            }
        )
    }

    private func graphemeBreakState(code: UInt8) -> GraphemeBreakState? {
        switch code {
        case 0: .initial
        case 1: .regionalIndicator
        case 2: .extendedPictographic
        case 3: .indicConjunctBreakConsonant
        case 4: .indicConjunctBreakLinker
        default: nil
        }
    }

    private mutating func semanticPromptFreshLine() {
        guard screen.cursor.column != 0 else { return }
        screen.cursor.column = 0
        clearPendingMotionState()
        lineFeed()
    }

    private mutating func setSemanticPrompt(kind: SemanticPromptRow) {
        screen.semanticContent = .prompt
        screen.semanticContentClearsAtEndOfLine = false
        screen.rows[screen.cursor.row].semanticPrompt = kind
        reclaimStalePromptHeads(for: kind)
        // A column-zero head starts a logical line. Clear the claim only after reclaim,
        // which needs that claim to recognize a stranded soft-wrapped head.
        if kind == .prompt, screen.cursor.column == 0, screen.cursor.row > 0 {
            screen.rows[screen.cursor.row - 1].isSoftWrapped = false
        }
    }

    /// Reclaims removable prompt rows as soon as a newer head makes them identifiable.
    private mutating func reclaimStalePromptHeads(for kind: SemanticPromptRow) {
        // `.full` only. Under `.last` the shell has declared it repaints just the final
        // prompt row, so rows above it remain shell-owned content.
        guard kind == .prompt, promptRedrawMode == .full else { return }
        // Row deletion and cursor movement are coherent only in one primary-screen
        // scroll region.
        guard isAlternateScreenActive == false,
              activeScrollRegion.contains(screen.cursor.row)
        else { return }
        var top = topOfStalePromptHeads(above: screen.cursor.row)
        // `.vacated` establishes ownership; emptiness establishes that deletion is free.
        // Reflow can preserve the stamp on a packed row with content, which must remain.
        while top > 0,
              screen.rows[top - 1].semanticPrompt == .vacated,
              Self.retainedContentEnd(in: screen.rows[top - 1]) == 0
        {
            top -= 1
        }
        guard top < screen.cursor.row, activeScrollRegion.contains(top) else { return }
        // Delete instead of re-blanking so the vacated rows do not become a permanent gap.
        // Move the cursor by the same count to preserve relative cursor arithmetic.
        let removed = screen.cursor.row - top
        moveAndFillRows(in: top..<activeScrollRegion.upperBound, by: -removed, pushesToScrollback: false)
        screen.cursor.row -= removed
    }

    private func semanticPromptKind(in options: [UInt8]) -> SemanticPromptRow {
        switch semanticPromptOption("k", in: options) {
        case "c", "s": .continuation
        default: .prompt
        }
    }

    private func semanticPromptOption(_ key: String, in options: [UInt8]) -> String? {
        let keyBytes = Array(key.utf8)
        for field in options.split(separator: 0x3B, omittingEmptySubsequences: false) {
            guard let equals = field.firstIndex(of: 0x3D),
                  Array(field[..<equals]) == keyBytes
            else { continue }
            return String(decoding: field[field.index(after: equals)...], as: UTF8.self)
        }
        return nil
    }

    private var retainedSemanticEventBytes: Int {
        pendingConsumerWork.retainedSemanticEventBytes
    }

    private mutating func dispatchTitle(_ payload: [UInt8], selectorEnd: Int) {
        let valueBytes = payload[payload.index(after: selectorEnd)...]
        guard valueBytes.count <= Self.maximumSemanticValueBytes,
              let value = String(validating: valueBytes, as: UTF8.self)
        else { return }
        // Reported verbatim, empty payload included: the empty string is the
        // clear, and what an untitled pane displays instead is the consumer's
        // decision. The engine manufactures no title of its own.
        admitSemanticEvent(.title(value))
    }

    private mutating func dispatchDanTermShell(_ payload: [UInt8], selectorEnd: Int) {
        guard payload.count <= Self.maximumShellOSCBytes else { return }
        let fields = payload[payload.index(after: selectorEnd)...].split(
            separator: 0x3B,
            omittingEmptySubsequences: false
        )
        guard fields.count >= 2,
              fields[0].elementsEqual("DanTermShell=3".utf8),
              let eventName = String(validating: fields[1], as: UTF8.self)
        else { return }

        switch eventName {
        case "integration-ready":
            guard fields.count == 2 else { return }
            admitSemanticEvent(.integrationReady)
        case "command-start":
            guard fields.count == 3,
                  let command = OSCPayload.decodedCanonicalBase64(
                      fields[2],
                      maximumByteCount: Self.maximumSemanticValueBytes
                  ),
                  !command.contains("\0"),
                  command.utf8.count <= Self.maximumSemanticValueBytes
            else { return }
            admitSemanticEvent(.commandStarted(command))
        case "command-end":
            guard fields.count == 3,
                  let exitStatus = OSCPayload.canonicalExitStatus(fields[2])
            else { return }
            admitSemanticEvent(.commandEnded(exitStatus: exitStatus))
        case "connection":
            guard fields.count >= 3,
                  let state = String(validating: fields[2], as: UTF8.self)
            else { return }
            switch state {
            case "local":
                guard fields.count == 3 else { return }
                admitSemanticEvent(.connectionDeclared(.local))
            case "remote":
                if fields.count == 3 {
                    admitSemanticEvent(.connectionDeclared(.remote(identity: nil)))
                    return
                }
                guard fields.count == 5,
                      let user = OSCPayload.decodedCanonicalBase64(
                          fields[3],
                          maximumByteCount: Self.maximumSemanticValueBytes
                      ),
                      let host = OSCPayload.decodedCanonicalBase64(
                          fields[4],
                          maximumByteCount: Self.maximumSemanticValueBytes
                      ),
                      user.utf8.count + host.utf8.count <= Self.maximumSemanticValueBytes
                else { return }
                admitSemanticEvent(.connectionDeclared(.remote(
                    identity: TerminalRemoteIdentity(user: user, host: host)
                )))
            default:
                return
            }
        default:
            return
        }
    }

    private mutating func dispatchOSC9(_ payload: [UInt8], selectorEnd: Int) {
        let value = payload[payload.index(after: selectorEnd)...]
        let firstEnd = value.firstIndex(of: 0x3B) ?? value.endIndex
        let first = value[..<firstEnd]
        if let selector = OSCPayload.canonicalConEmuSelector(first) {
            if selector == 4 { dispatchProgress(value) }
            return
        }
        admitNotification(titleBytes: [], bodyBytes: value)
    }

    private mutating func dispatchOSC777(_ payload: [UInt8], selectorEnd: Int) {
        let fields = payload[payload.index(after: selectorEnd)...].split(
            separator: 0x3B,
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard fields.count == 3, fields[0].elementsEqual("notify".utf8) else { return }
        admitNotification(titleBytes: fields[1], bodyBytes: fields[2])
    }

    private mutating func admitNotification(
        titleBytes: ArraySlice<UInt8>,
        bodyBytes: ArraySlice<UInt8>
    ) {
        guard titleBytes.count + bodyBytes.count <= Self.maximumSemanticValueBytes,
              let title = String(validating: titleBytes, as: UTF8.self),
              let body = String(validating: bodyBytes, as: UTF8.self)
        else { return }
        admitSemanticEvent(.desktopNotification(title: title, body: body))
    }

    private mutating func dispatchProgress(_ payload: ArraySlice<UInt8>) {
        let fields = payload.split(separator: 0x3B, omittingEmptySubsequences: false)
        guard fields.count >= 2, fields[0].elementsEqual("4".utf8),
              let state = String(validating: fields[1], as: UTF8.self)
        else { return }
        let event: TerminalProgress?
        switch (state, fields.count) {
        case ("0", 2): event = nil
        case ("1", 3):
            guard let percent = OSCPayload.progressPercent(fields[2]) else { return }
            event = .set(percent: percent)
        case ("2", 2): event = .error(percent: nil)
        case ("2", 3):
            guard let percent = OSCPayload.progressPercent(fields[2]) else { return }
            event = .error(percent: percent)
        case ("3", 2): event = .indeterminate
        case ("4", 2): event = .pause(percent: nil)
        case ("4", 3):
            guard let percent = OSCPayload.progressPercent(fields[2]) else { return }
            event = .pause(percent: percent)
        default: return
        }
        admitSemanticEvent(.progress(event))
    }

    private mutating func dispatchOSC7(_ payload: [UInt8], selectorEnd: Int) {
        let valueBytes = payload[payload.index(after: selectorEnd)...]
        guard valueBytes.count <= Self.maximumSemanticValueBytes else { return }
        let cwd: String?
        if valueBytes.isEmpty {
            cwd = nil
        } else {
            guard let parsed = OSCPayload.localFilePath(
                from: valueBytes,
                machineHostname: machineHostname
            ) else { return }
            cwd = parsed
        }
        admitSemanticEvent(.workingDirectory(cwd))
    }

    /// Offers one parsed event to the shared J6 accumulator, paying for it out of the
    /// metadata budget the retained hyperlink targets share.
    ///
    /// The retry is the whole reason the accumulator reports *why* it refused: only the
    /// engine can free bytes in this budget, and only a byte refusal is worth a sweep.
    private mutating func admitSemanticEvent(_ event: TerminalSemanticEvent) {
        var admission = pendingConsumerWork.admit(
            event,
            order: nextSemanticEventOrder,
            externalRetainedBytes: retainedHyperlinkMetadataBytes
        )
        if admission == .droppedForBytes {
            reclaimDeadHyperlinkTargets()
            admission = pendingConsumerWork.admit(
                event,
                order: nextSemanticEventOrder,
                externalRetainedBytes: retainedHyperlinkMetadataBytes
            )
        }
        guard admission == .admitted else { return }
        nextSemanticEventOrder &+= 1
    }

    private mutating func dispatchOSC8(_ payload: [UInt8], selectorEnd: Int) {
        let paramsStart = payload.index(after: selectorEnd)
        guard let paramsEnd = payload[paramsStart...].firstIndex(of: 0x3B) else { return }
        let uriStart = payload.index(after: paramsEnd)
        guard let uri = String(validating: payload[uriStart...], as: UTF8.self) else { return }
        if uri.isEmpty {
            hyperlinkPen = nil
            return
        }

        let params = String(validating: payload[paramsStart..<paramsEnd], as: UTF8.self)
        let explicitId = params.flatMap { OSCPayload.osc8ExplicitId(in: $0) }
        let target = TerminalHyperlink(uri: uri, explicitId: explicitId)
        guard hyperlinkByteCost(target) <= Self.maximumHyperlinkTargetBytes else { return }

        if let hyperlinkPen, hyperlinkTargets[hyperlinkPen] == target { return }
        if let explicitId,
           let existing = hyperlinkTargets.first(where: {
               $0.value.explicitId == explicitId && $0.value.uri == uri
           })?.key
        {
            self.hyperlinkPen = existing
            return
        }

        guard var candidateTargets = admittedHyperlinkTargets(adding: target, replacing: nil),
              let id = allocateHyperlinkId(avoiding: candidateTargets)
        else { return }
        candidateTargets[id] = target
        hyperlinkTargets = candidateTargets
        hyperlinkPen = id
    }

    /// Issues an id no cell can already be pointing at, so a finite id space can be recycled.
    ///
    /// Rests on one invariant: **every id held by a cell is a key of `hyperlinkTargets`**. Targets
    /// are only ever dropped by `filter { live.contains($0.key) }`, and `liveHyperlinkIds` walks
    /// scrollback, the active grid, the inactive primary screen, and the pen -- which is every
    /// place a cell lives. So an id absent from the table is absent from the grid, and reusing it
    /// cannot resurrect a stale link on a cell that outlived its target.
    ///
    /// Scanning from a rotating cursor rather than from zero keeps this amortized O(1) against a
    /// table that admission already walks linearly. Returning nil when the space is full is the
    /// same refusal the byte cap above performs, and reaches the same caller path.
    private mutating func allocateHyperlinkId(
        avoiding targets: [HyperlinkId: TerminalHyperlink]
    ) -> HyperlinkId? {
        guard targets.count < Int(HyperlinkId.max) else { return nil }
        // The scan is bounded by the id space itself rather than trusting the count guard above
        // to keep it terminating. A table that is full *in fact* -- however a count came to
        // disagree -- must refuse the open like any other exhaustion, not spin forever inside
        // `feed`. The bound also makes this function safe to probe: removing the guard is the
        // natural way to check that `fullIdSpaceRefusesFurtherOpens` still discriminates, and an
        // unbounded scan turns that into a hang nothing in the test framework can interrupt --
        // `.timeLimit` cancels a task, and Swift cancellation is cooperative, so it cannot stop
        // a synchronous loop (measured: a 60s limit did not fire in 130s).
        var candidate = nextHyperlinkId
        for _ in 0..<Int(HyperlinkId.max) {
            if targets[candidate] == nil {
                nextHyperlinkId = candidate == HyperlinkId.max ? 1 : candidate + 1
                return candidate
            }
            candidate = candidate == HyperlinkId.max ? 1 : candidate + 1
        }
        return nil
    }

    private func hyperlinkByteCost(_ target: TerminalHyperlink) -> Int {
        target.uri.utf8.count + (target.explicitId?.utf8.count ?? 0)
    }

    /// Names the interaction slot a caller is about to overwrite, whose current occupant
    /// therefore does not count against the admission sum.
    private enum InteractionLinkSlot: CaseIterable {
        case hover
        case arm
    }

    private subscript(slot: InteractionLinkSlot) -> InteractionLinkState? {
        get {
            switch slot {
            case .hover: hoveredLinkState
            case .arm: armedLinkState
            }
        }
        set {
            switch slot {
            case .hover: hoveredLinkState = newValue
            case .arm: armedLinkState = newValue
            }
        }
    }

    /// Prices one more hyperlink against the pane-wide metadata cap, reclaiming dead targets
    /// once if the table does not fit otherwise, and returns the table to store on success.
    ///
    /// The single spelling of an arithmetic that OSC 8 admission, hover, and arm all have to
    /// agree on: the retained targets, both interaction slots (minus the one being replaced),
    /// and the retained semantic events share one budget. Returning the reclaimed table rather
    /// than a `Bool` is what lets a caller commit the sweep it just paid for -- `liveHyperlinkIds`
    /// walks all of retained history, so a caller that discarded it would walk history twice.
    /// Non-mutating so callers keep control of their own damage bracketing.
    private func admittedHyperlinkTargets(
        adding target: TerminalHyperlink,
        replacing slot: InteractionLinkSlot?
    ) -> [HyperlinkId: TerminalHyperlink]? {
        let interactionCost = InteractionLinkSlot.allCases.reduce(0) { cost, candidateSlot in
            guard candidateSlot != slot else { return cost }
            return cost + (self[candidateSlot].map { hyperlinkByteCost($0.hyperlink) } ?? 0)
        }
        let fixedCost = interactionCost + retainedSemanticEventBytes + hyperlinkByteCost(target)

        var candidateTargets = hyperlinkTargets
        if candidateTargets.values.reduce(0, { $0 + hyperlinkByteCost($1) }) + fixedCost
            > Self.maximumTerminalMetadataBytes
        {
            let live = liveHyperlinkIds()
            candidateTargets = candidateTargets.filter { live.contains($0.key) }
        }
        guard candidateTargets.values.reduce(0, { $0 + hyperlinkByteCost($1) }) + fixedCost
            <= Self.maximumTerminalMetadataBytes
        else { return nil }
        return candidateTargets
    }

    private func admittedInteractionLink(
        _ link: TerminalResolvedLink,
        for slot: InteractionLinkSlot
    ) -> (targets: [HyperlinkId: TerminalHyperlink], state: InteractionLinkState)? {
        guard isActivatableWebURI(link.hyperlink.uri),
              hyperlinkByteCost(link.hyperlink) <= Self.maximumHyperlinkTargetBytes,
              let targets = admittedHyperlinkTargets(adding: link.hyperlink, replacing: slot)
        else { return nil }
        let ordered = textPositionPrecedes(link.range.start, link.range.end)
            ? (link.range.start, link.range.end)
            : (link.range.end, link.range.start)
        return (
            targets,
            InteractionLinkState(
                hyperlink: link.hyperlink,
                range: TextAnchorRange(
                    start: normalizedSelectionBoundary(ordered.0, isEnd: false),
                    end: normalizedSelectionBoundary(ordered.1, isEnd: true)
                ),
                activationIdentity: link.activationIdentity
            )
        )
    }

    @discardableResult
    private mutating func setInteractionLink(
        _ link: TerminalResolvedLink,
        for slot: InteractionLinkSlot
    ) -> Bool {
        guard let admitted = admittedInteractionLink(link, for: slot) else { return false }
        hyperlinkTargets = admitted.targets
        self[slot] = admitted.state
        return true
    }

    private func resolvedInteractionLink(for slot: InteractionLinkSlot) -> TerminalResolvedLink? {
        guard let state = self[slot], let range = publicRange(state.range) else { return nil }
        return TerminalResolvedLink(
            hyperlink: state.hyperlink,
            range: range,
            activationIdentity: state.activationIdentity
        )
    }

    private func liveHyperlinkIds() -> Set<HyperlinkId> {
        var live = Set<HyperlinkId>()
        func collect(_ rows: Deque<GridRow>, into live: inout Set<HyperlinkId>) {
            for row in rows {
                for cell in row.cells {
                    if let id = cell.hyperlinkId { live.insert(id) }
                }
            }
        }
        history.store.forEachHyperlinkId { live.insert($0) }
        collect(screen.rows, into: &live)
        if let offscreenScreen { collect(offscreenScreen.rows, into: &live) }
        if let hyperlinkPen { live.insert(hyperlinkPen) }
        return live
    }

    private mutating func reclaimDeadHyperlinkTargets() {
        let live = liveHyperlinkIds()
        hyperlinkTargets = hyperlinkTargets.filter { live.contains($0.key) }
    }

    private mutating func dispatchOSC52(_ payload: [UInt8], selectorEnd: Int) {
        let fields = payload.index(after: selectorEnd)..<payload.endIndex
        guard let targetEnd = payload[fields].firstIndex(of: 0x3B) else { return }
        let target = payload[fields.lowerBound..<targetEnd]
        guard target.allSatisfy({ byte in
            byte == 0x63 || byte == 0x70 || byte == 0x71 || byte == 0x73
                || (0x30...0x37).contains(byte)
        }) else { return }
        let dataStart = payload.index(after: targetEnd)
        let encoded = payload[dataStart...]
        guard encoded.elementsEqual([0x3F]) == false,
              let decoded = OSCPayload.decodeBase64(encoded, maximumByteCount: 1_048_576),
              let value = String(validating: decoded, as: UTF8.self)
        else { return }
        pendingConsumerWork.setClipboardWrite(value)
    }

    /// Resizes each screen by its contract while keeping the active cursor valid.
    public mutating func resize(columns: Int, rows: Int) {
        guard columns >= 2, rows >= 1 else { return }
        guard columns != columnCount || rows != rowCount else { return }

        // Resize can evict or rewrite retained primary text, including behind the alternate screen.
        primaryHistoryObservation.value &+= 1
        damage.reset(rowCount: rows, isFull: true)

        if isAlternateScreenActive {
            clearInspection()
        }

        let oldColumnCount = columnCount
        scrollRegion = nil
        if columns != oldColumnCount {
            resizeTabStops(from: oldColumnCount, to: columns)
        }

        withPrimaryScreenInstalled { terminal in
            if columns != oldColumnCount {
                terminal.clearPromptForResizeIfNeeded()
            }
            terminal.resizePrimaryScreen(columns: columns, rows: rows)
            terminal.clampScreenCursorState(&terminal.screen)
        }
        resizeAlternateScreen(columns: columns, rows: rows, oldColumnCount: oldColumnCount)

        clampSelectionToRetainedStream()
        clusterContext = nil
    }

    /// Vacates shell-owned prompt cells before reflow can reinterpret their old-width rows.
    ///
    /// The caller limits this to width changes and runs it before either resize leg. A combined
    /// shrink can move the prompt head into history, after which this upward walk could no longer
    /// find the ownership boundary needed to vacate the whole block.
    private mutating func clearPromptForResizeIfNeeded() {
        guard promptRedrawMode != .disabled, screen.semanticContent != .output else { return }
        if promptRedrawMode == .last {
            clearPromptCells(in: screen.cursor.row)
            return
        }

        var start = screen.cursor.row
        while start >= 0 {
            switch screen.rows[start].semanticPrompt {
            case .prompt, .vacated:
                // A vacated head is still the current block's ownership boundary.
                start = topOfStalePromptHeads(above: start)
                for row in start..<rowCount { clearPromptCells(in: row) }
                return
            case .output:
                // The shell erased the current head but has not re-marked it; an older
                // prompt above completed output is outside this repaint grant.
                return
            case .continuation, .none:
                start -= 1
            }
        }
    }

    /// Finds the topmost dangling soft-wrapped head directly above a newer prompt head.
    /// Adjacency alone is insufficient because legitimate one-row prompts can stack.
    private func topOfStalePromptHeads(above row: Int) -> Int {
        var top = row
        while top > 0,
              screen.rows[top - 1].semanticPrompt == .prompt,
              screen.rows[top - 1].isSoftWrapped
        {
            top -= 1
        }
        return top
    }

    /// Vacates one row on the shell's repaint promise, including its obsolete wrap claim.
    private mutating func clearPromptCells(in row: Int) {
        invalidateInspection(
            inViewportRows: row..<(row + 1),
            affectsPreviousProjection: true
        )
        let blank = GridCell(styleId: backgroundEraseStyleId())
        let columns = columnCount
        withRowCells(row) { cells in
            for column in 0..<columns {
                cells[column] = blank
            }
        }
        screen.rows[row].semanticPrompt = .vacated
        screen.rows[row].isSoftWrapped = false
        clusterContext = nil
    }

    /// Renders the selected local window as unstyled text, representing padding as spaces.
    public var screenText: String {
        presentedRows.map { row in
            var result = ""
            for column in 0..<columnCount {
                let cell = row.cell(at: column)
                switch cell.kind {
                case .narrow, .wideHead:
                    for scalar in row.scalars(of: cell) {
                        result.unicodeScalars.append(scalar)
                    }
                case .padding, .spacerHead:
                    result.append(" ")
                case .wideTail:
                    break
                }
            }
            return result
        }.joined(separator: "\n")
    }

    /// Projects the local window as logical text without soft-wrap separators or padding.
    public var viewportText: String {
        projectedHistoryText(from: presentedRows)
    }

    /// Derives the window from the five values it depends on, so no caller reads it as a member.
    ///
    /// A static function and not a computed property because the per-action damage snapshot needs
    /// this from inside a `mutating` method: reading it there through `self` made the compiler
    /// copy the whole terminal for the borrow, once per parser action (`research/39/F2`, `D5`).
    /// Every argument is a cheap scalar or the viewport enum, so the call carries no grid.
    private static func deriveScrollProjection(
        isAlternateScreenActive: Bool,
        rowCount: Int,
        historyRowCount: Int,
        viewportState: ViewportState,
        evictedRowCount: Int
    ) -> TerminalScrollProjection {
        if isAlternateScreenActive {
            return TerminalScrollProjection(
                totalRows: rowCount,
                topRow: 0,
                windowRows: rowCount,
                isFollowing: true
            )
        }
        let totalRows = historyRowCount + rowCount
        let maximumTop = max(0, totalRows - rowCount)
        let topRow: Int
        let isFollowing: Bool
        switch viewportState {
        case .following:
            topRow = maximumTop
            isFollowing = true
        case let .browsing(anchor):
            topRow = min(max(anchor.row - evictedRowCount, 0), maximumTop)
            isFollowing = false
        }
        return TerminalScrollProjection(
            totalRows: totalRows,
            topRow: topRow,
            windowRows: rowCount,
            isFollowing: isFollowing
        )
    }

    /// Exposes the current visual-row extent and window for scrollbar and inspection consumers.
    public var scrollProjection: TerminalScrollProjection {
        Terminal.deriveScrollProjection(
            isAlternateScreenActive: isAlternateScreenActive,
            rowCount: rowCount,
            historyRowCount: historyRowCount,
            viewportState: viewportState,
            evictedRowCount: evictedRowCount
        )
    }

    /// The stream row at the top of the local window in absolute, eviction-corrected
    /// coordinates -- the space text anchors pin. Unlike `scrollProjection.topRow`, which is
    /// retained-relative and plateaus once history eviction begins, this stays monotone while
    /// the viewport follows live output, so a delivery-rate sampler can read scrolled lines
    /// as a plain delta. A hard reset restarts it, like the eviction counter it builds on.
    public var absoluteViewportTopRow: Int {
        evictedRowCount + scrollProjection.topRow
    }

    /// Moves the local window by signed visual rows; positive values move toward live output.
    public mutating func scroll(byRows rowDelta: Int) {
        guard isAlternateScreenActive == false else { return }
        let current = scrollProjection.topRow
        let addition = current.addingReportingOverflow(rowDelta)
        let target = addition.overflow
            ? (rowDelta < 0 ? Int.min : Int.max)
            : addition.partialValue
        scroll(toTopRow: target)
    }

    /// Selects a top visual row in current-stream coordinates, clamping to a complete window.
    public mutating func scroll(toTopRow requestedRow: Int) {
        guard isAlternateScreenActive == false else { return }
        let previous = viewportState
        let maximumTop = max(0, historyRowCount + screen.rows.count - rowCount)
        let topRow = min(max(requestedRow, 0), maximumTop)
        if topRow == maximumTop {
            viewportState = .following
        } else {
            viewportState = .browsing(
                top: TextAnchor(row: evictedRowCount + topRow, column: 0)
            )
        }
        if viewportState != previous {
            recordPresentationFullDamage()
        }
    }

    /// Returns local presentation to live-bottom follow without changing terminal content.
    public mutating func scrollToBottom() {
        guard isAlternateScreenActive == false else { return }
        guard viewportState != .following else { return }
        viewportState = .following
        recordPresentationFullDamage()
    }

    /// Returns retained primary rows in oldest-first order.
    public var scrollbackRowCount: Int {
        historyRowCount
    }

    /// Exposes one retained row without allowing callers to mutate terminal storage.
    public func scrollbackRow(at index: Int) -> TerminalScrollbackRow? {
        guard let stored = history.store.paintedDisplayRow(at: index) else { return nil }
        let projector = activeDisplayRows
        let folded = projector.project(stored, projector.facts(forHistoryRow: index))
        let row = folded.materialized(to: columnCount)
        return TerminalScrollbackRow(
            cells: row.cells.map {
                TerminalCell(
                    kind: $0.kind,
                    scalars: row.scalars(of: $0),
                    style: style(for: $0.styleId),
                    hyperlink: $0.hyperlinkId.flatMap { hyperlinkTargets[$0] }
                )
            },
            isSoftWrapped: row.isSoftWrapped
        )
    }

    /// Logical lines retained in history.store. The denominator of the record-scoped readers below.
    public var scrollbackRecordCount: Int { history.store.recordCount }

    /// Reports one retained **logical line**'s content-identity run shape.
    ///
    /// Record-scoped since doc 31 (`research/31/D3` Decision 6, `research/31/DD17`), where the old row-scoped
    /// reader's contract stops being expressible: a display row is a slice the current width
    /// chooses, so "the row's own content, not the pane's width" has no meaning at a fold
    /// boundary. A record's stored cells are width-free by construction, so the contract is
    /// now literally true and the "reads the unmaterialized prefix" caveat is gone with the
    /// materialization. Doc 28's `PR1` consumes the quantity in aggregate, so what changed for
    /// it is the sample unit: one sample per logical line rather than per display row.
    ///
    /// `contentIdentity` stays deliberately absent from `TerminalCell`, so this returns counts
    /// from one call per record instead of widening the per-cell inspection value -- the shape
    /// `docs/design/2026-07-29-cross-module-value-dispatch.md` recommends at design time.
    /// O(stored cells), for measurement only.
    public func scrollbackRecordContentIdentityShape(
        at index: Int
    ) -> TerminalContentIdentityShape? {
        guard let cells = history.store.recordCells(at: index) else { return nil }
        var runCount = 0
        var strictRunCount = 0
        var identified = 0
        var unidentified = 0
        var previous: ContentIdentity?
        for cell in cells {
            guard let identity = cell.contentIdentity else {
                unidentified += 1
                previous = nil
                continue
            }
            identified += 1
            // A run continues on the counter's own step of one, or on a repeat -- `printWide`
            // stamps a head and its tail with a single identity, so demanding a strict step
            // would fragment every wide glyph's row.
            if let last = previous, identity == last &+ 1 {
                previous = identity
                continue
            }
            strictRunCount += 1
            if let last = previous, identity == last {
                previous = identity
                continue
            }
            runCount += 1
            previous = identity
        }
        return TerminalContentIdentityShape(
            runCount: runCount,
            strictRunCount: strictRunCount,
            identifiedCellCount: identified,
            unidentifiedCellCount: unidentified
        )
    }

    /// Walks live rows and retained records and reports exactly what their cell storage costs.
    ///
    /// Lives here rather than beside `TerminalMemoryCensus` because it needs `GridCell` and
    /// `GridRow`, which stay `private`. That split is the point: the census ships as reusable
    /// public evidence without widening the grid types, which is what forced doc 12's censuses to
    /// be throwaway probes. O(stored cells plus retained side-table entries) -- for measurement,
    /// not for a hot path.
    ///
    /// History is arena-denominated since doc 31 (`research/31/F6` `R16`, `research/31/DD11`): there is one region
    /// rather than a heap allocation per retained row, so the per-row leak proof `research/15/F4`
    /// motivated is restated as bytes-in-use against a capacity that never grows.
    public var memoryCensus: TerminalMemoryCensus {
        // Distinct styles are counted by id rather than by value: ids are canonical (equal styles
        // always intern to the same one), so this is the same number `research/12/F3` reported, reached
        // without re-deriving a hash for a type the table already hashes.
        let stride = MemoryLayout<GridCell>.stride
        let arena = history.store.census
        var census = TerminalMemoryCensus(
            screenRowCount: 0,
            scrollbackRowCount: historyRowCount,
            scrollbackRecordCount: history.store.recordCount,
            cellCount: 0,
            cellStrideBytes: stride,
            cellStorageBytes: 0,
            liveClusterStorageBytes: 0,
            retainedStoredCellCount: 0,
            retainedArenaBytesInUse: arena.arenaBytesInUse,
            retainedArenaCapacityBytes: arena.capacityBytes,
            retainedIndexBytes: arena.indexBytes,
            retainedSideTableBytes: arena.sideTableBytes,
            rowStorageAllocationCount: 0,
            styledCellCount: 0,
            distinctStyleCount: 0,
            multiScalarCellCount: 0,
            multiScalarAllocationCount: 0,
            hyperlinkCellCount: 0,
            contentIdentityCellCount: 0,
            distinctContentIdentityCount: 0
        )
        var styles: Set<StyleId> = []
        var identities: Set<ContentIdentity> = []

        // The inactive screen counts as resident: after the first alternate-screen entry the
        // process holds both grids, and a census that reported only the visible one would
        // understate a full-screen TUI by an entire screen.
        let screens = [screen.rows, offscreenScreen?.rows].compactMap { $0 }
        census.screenRowCount = screens.reduce(0) { $0 + $1.count }

        // Only live rows have a per-row allocation left to count: history's cells all live in the
        // one arena, which is exactly why it can no longer leak a row's storage.
        for row in screens.flatMap({ $0 }) where row.cells.isEmpty == false {
            census.rowStorageAllocationCount += 1
        }
        census.liveClusterStorageBytes = screens.flatMap({ $0 }).reduce(0) {
            $0 + $1.spillStorageBytes
        }
        census.cellStorageBytes = arena.arenaBytesInUse
            + census.liveClusterStorageBytes
            + screens.flatMap({ $0 }).reduce(0) { $0 + $1.cells.count * stride }

        history.store.forEachStoredCell { styleId, isSpilled in
            census.retainedStoredCellCount += 1
            census.cellCount += 1
            if styleId != Self.defaultStyleId { census.styledCellCount += 1 }
            if isSpilled { census.multiScalarCellCount += 1 }
        }
        census.multiScalarAllocationCount += history.store.spillTableCount
        history.store.forEachStyleId { styles.insert($0) }
        history.store.forEachHyperlinkId { _ in census.hyperlinkCellCount += 1 }
        history.store.forEachContentIdentity { identity in
            census.contentIdentityCellCount += 1
            identities.insert(identity)
        }

        for row in screens.flatMap({ $0 }) {
            census.cellCount += row.cells.count
            if row.hasSpillAllocation { census.multiScalarAllocationCount += 1 }
            for cell in row.cells {
                if cell.styleId != Self.defaultStyleId { census.styledCellCount += 1 }
                styles.insert(cell.styleId)
                if row.scalarCount(of: cell) > 1 {
                    census.multiScalarCellCount += 1
                }
                if cell.hyperlinkId != nil { census.hyperlinkCellCount += 1 }
                if let identity = cell.contentIdentity {
                    census.contentIdentityCellCount += 1
                    identities.insert(identity)
                }
            }
        }

        census.distinctStyleCount = styles.count
        census.distinctContentIdentityCount = identities.count
        return census
    }

    /// Recounts history's display rows straight off the arena, ignoring every cached total.
    ///
    /// The independent oracle `31/I9` is stated against: the maintained grand total must equal
    /// this after each of the six trigger points, and nothing else catches a missed invalidation
    /// (`31/AR4`).
    var independentScrollbackRowRecount: Int { history.store.independentDisplayRowRecount() }

    /// Hands a test the folded display row as the *renderer* sees it, fill included.
    func retainedRowForTesting(at index: Int) -> GridRow? {
        history.store.paintedDisplayRow(at: index)
    }

    /// Hands a test one live-grid row without exposing mutable storage.
    func liveRowForTesting(at index: Int) -> GridRow? {
        screen.rows.indices.contains(index) ? screen.rows[index] : nil
    }

    /// Exposes one retained line's record-level shape -- open, split, trimmed, filled -- so the
    /// store's contracts are assertable through the terminal that drives it.
    func retainedRecordSummaryForTesting(at index: Int) -> LogicalLineStore.RecordSummary? {
        history.store.recordSummary(at: index)
    }

    mutating func restoreWrapClaimBeforeCursorForTesting() {
        restoreWrapClaimBeforeCursor()
    }

    /// Forces retained-row eviction so resize-anchor clamping can be proved without output.
    mutating func evictScrollbackRowsForTesting(_ count: Int) {
        mutateHistory { store in
            for _ in 0..<max(0, count) {
                if store.evictOneDisplayRow() == false { break }
            }
        }
        syncHistoryEvictions()
    }

    /// Runs both metadata reclamation passes so their retained-row cost can be measured directly.
    mutating func reclaimMetadataForTesting() {
        reclaimDeadStyleEntries()
        reclaimDeadHyperlinkTargets()
    }

    /// Drives the content-identity counter to the last value before it wraps, so a test can reach
    /// the wrap without printing 2^32 cells. The wrap is otherwise unreachable in a test and its
    /// consequences are not local -- see `allocateContentIdentity`.
    mutating func primeContentIdentityWrapForTesting() {
        nextContentIdentity = ContentIdentity.max
    }

    /// Drives the style-id cursor to the end of its range, so a test can reach the recycle without
    /// interning 2^32 styles. Same rationale as the content-identity seam above: the wrap is
    /// unreachable in a test, and getting it wrong repaints live cells -- see `allocateStyleId`.
    mutating func primeStyleIdRecycleForTesting() {
        nextStyleId = StyleId.max
    }

    /// Drives the hyperlink id cursor to the last value before it wraps, so a test can reach the
    /// wrap without emitting 2^16 distinct OSC 8 targets. Same rationale as the two seams above,
    /// with a sharper cost: admission is linear in the live target table, so walking the cursor
    /// there for real is quadratic, and the failure it guards is a recycled id repainting a live
    /// cell with another target's URI -- see `allocateHyperlinkId`.
    mutating func primeHyperlinkIdWrapForTesting() {
        nextHyperlinkId = HyperlinkId.max
    }

    /// Fills the live target table to one id short of the usable space, so a test can reach the
    /// id-exhaustion refusal in `allocateHyperlinkId` without emitting 65,534 admissible OSC 8
    /// opens. The placeholder URI is one byte on purpose: the byte cap must not be what refuses,
    /// or the refusal under test is never reached. Duplicate URIs are the faithful shape -- a real
    /// session reaches this by alternating two short targets, which dedupes only against the
    /// current pen and so mints a fresh id every open.
    mutating func primeHyperlinkIdSpaceForTesting() {
        for id in 1..<HyperlinkId.max {
            hyperlinkTargets[id] = TerminalHyperlink(uri: "x")
        }
    }

    /// Creates the one-operation no-eviction oracle used to isolate eviction side effects.
    ///
    /// Rebases history onto an arena at the production budget rather than raising a bound in
    /// place: the arena fixes its whole address-space capacity at construction and never grows
    /// that capacity (`31/I2`), so "this terminal with an unlimited budget" is not a value that
    /// exists. Its backing still materializes lazily while the records are copied.
    ///
    /// `budgetBytes` lets a caller that builds one twin per action avoid materializing more
    /// backing than its fixture can reach while the existing records are replayed. "Unlimited"
    /// only ever means "cannot evict for what this oracle feeds it", so such a caller may name a
    /// smaller budget -- and owes a fixture-specific argument that eviction is unreachable,
    /// since a twin that evicts is a silently wrong oracle.
    func withUnlimitedScrollbackForTesting(
        budgetBytes: Int = Terminal.scrollbackByteLimit
    ) -> Self {
        var copy = self
        copy.replaceHistory(with: history.store.rebased(toBudgetBytes: budgetBytes))
        copy.historyEvictionsObserved = copy.history.store.evictedRowCount
        return copy
    }

    /// Exposes private row stamps to the shared snapshot oracle without changing public geometry.
    /// Computed only when a test asks; production never calls it.
    var semanticPromptRowsForTesting: [TerminalSemanticPromptRowSnapshot] {
        screen.rows.map { row in
            let stamp: TerminalSemanticPromptStamp = switch row.semanticPrompt {
            case .none: .none
            case .prompt: .prompt
            case .continuation: .continuation
            case .output: .output
            case .vacated: .vacated
            }
            return TerminalSemanticPromptRowSnapshot(
                stamp: stamp,
                isSoftWrapped: row.isSoftWrapped,
                isEmpty: Self.retainedContentEnd(in: row) == 0
            )
        }
    }

    /// Exposes selection provenance so equivalence tests read the engine's real decision.
    var selectionRequiresNonemptyReflowResultForTesting: Bool {
        selectionRequiresNonemptyReflowResult
    }

    /// Projects retained history and the viewport as logical text without a final newline.
    public var fullHistoryText: String {
        guard isAlternateScreenActive else { return primaryHistoryText }
        let projector = activeDisplayRows
        var stream = history.store.allPaintedDisplayRows()
        if let last = stream.indices.last {
            stream[last] = projector.project(stream[last], projector.facts(forHistoryRow: last))
        }
        stream.append(contentsOf: projector.projectedGridRows())
        return projectedHistoryText(from: stream)
    }

    /// Projects every retained and live row's line structure for wrap and reflow diagnosis.
    ///
    /// Reports the whole stream rather than the local window because the defect it exists to
    /// expose (`TerminalRowStructure`) is introduced when a row is admitted or reflowed, which
    /// is exactly when the row is leaving the window a viewport projection would show.
    public var rowStructure: [TerminalRowStructure] {
        let projector = activeDisplayRows
        let storedRetained = history.store.allPaintedDisplayRows()
        var retained = storedRetained
        let storedLiveRows = screen.rows
        let liveRows = projector.projectedGridRows()
        // Projected through the active stream's seam, so the dump reports what a reader would
        // see: the open tail's final display row gets back the `.spacerHead` admission dropped,
        // and an active alternate screen severs the wrap into the rows appended after history.
        if let last = retained.indices.last {
            retained[last] = projector.project(retained[last], projector.facts(forHistoryRow: last))
        }
        let storedRows = storedRetained + Array(storedLiveRows)
        var result: [TerminalRowStructure] = []
        result.reserveCapacity(retained.count + liveRows.count)
        for (offset, row) in (retained + liveRows).enumerated() {
            let stored = storedRows[offset]
            let visible = row.visibleExtent(columns: columnCount)
            result.append(TerminalRowStructure(
                index: offset,
                isRetained: offset < retained.count,
                isSoftWrapped: row.logicallyContinues,
                contentEnd: Self.retainedContentEnd(in: row),
                visibleEnd: visible.contentEnd,
                fillStyle: visible.fillStyle.map(style(for:)),
                width: columnCount,
                marginCellKind: row.cell(at: columnCount - 1).kind,
                staleWrapClaim: stored.isSoftWrapped && stored.marginProvenance == .erase
            ))
        }
        return result
    }

    /// Projects visible grid content into coordinate-preserving spans for external inspection.
    public var viewportCells: TerminalViewportCells {
        let rows = presentedRows.enumerated().map { index, row in
            TerminalViewportCellRow(index: index, spans: Self.viewportCellSpans(in: row))
        }
        return TerminalViewportCells(
            columns: columnCount,
            rowCount: rowCount,
            paneRowsOrigin: isAlternateScreenActive ? historyRowCount : scrollProjection.topRow,
            rows: rows
        )
    }

    /// Omits edge padding while translating interior padding into visible-distance spaces.
    private static func viewportCellSpans(in row: GridRow) -> [TerminalViewportCellSpan] {
        guard let lower = row.cells.firstIndex(where: { $0.kind != .padding }),
              let upper = row.cells.lastIndex(where: { $0.kind != .padding })
        else { return [] }

        struct Builder {
            let kind: TerminalViewportCellSpanKind
            let column: Int
            let cellWidth: Int
            var text = ""
            var utf8Offsets: [Int] = []

            mutating func append(_ scalars: TerminalScalars) {
                utf8Offsets.append(text.utf8.count)
                for scalar in scalars { text.unicodeScalars.append(scalar) }
            }

            mutating func appendSpace() {
                utf8Offsets.append(text.utf8.count)
                text.append(" ")
            }

            func value() -> TerminalViewportCellSpan {
                TerminalViewportCellSpan(
                    kind: kind,
                    column: column,
                    cellWidth: cellWidth,
                    text: kind == .spacer ? nil : text,
                    utf8Offsets: kind == .spacer ? nil : utf8Offsets
                )
            }
        }

        var result: [TerminalViewportCellSpan] = []
        var builder: Builder?
        func flush() {
            if let builder { result.append(builder.value()) }
            builder = nil
        }

        for column in lower...upper {
            let cell = row.cells[column]
            let kind: TerminalViewportCellSpanKind
            let width: Int
            switch cell.kind {
            case .padding, .narrow:
                kind = .narrow
                width = 1
            case .wideHead:
                kind = .wide
                width = 2
            case .wideTail:
                continue
            case .spacerHead:
                kind = .spacer
                width = 1
            }
            if builder?.kind != kind {
                flush()
                builder = Builder(kind: kind, column: column, cellWidth: width)
            }
            switch cell.kind {
            case .padding:
                builder?.appendSpace()
            case .narrow, .wideHead:
                builder?.append(row.scalars(of: cell))
            case .spacerHead:
                flush()
            case .wideTail:
                break
            }
        }
        flush()
        return result
    }

    /// Projects retained primary-screen history for recovery and export consumers.
    public var primaryHistoryText: String {
        return projectedHistoryText(from: primaryProjectionRows(from: 0))
    }

    /// Projects a positional tail of primary history under plain line and grapheme limits.
    ///
    /// Hard boundaries select the oldest complete logical line. The engine neither trims
    /// whitespace nor adds a final newline; persistence policy belongs to the caller.
    public func primaryHistoryTailText(maxLines: Int, maxChars: Int) -> String {
        guard maxLines > 0, maxChars > 0 else { return "" }
        let primaryRows = primaryScreenRows
        let totalRows = historyRowCount + primaryRows.count
        // A display row carries at most one hard break, so the budget's line count is the floor
        // on rows worth reading. Past it: one row for the last content row, which projects no
        // trailing newline of its own, and the live screen's height, because the rows below the
        // cursor are usually blank and a projection stops at the last one with content. Together
        // those are the systematic shortfall, and covering them here is what keeps the ordinary
        // case to a single pass. Clamped to the stream so an unbounded budget cannot overflow.
        var rowBudget = min(max(maxLines, 0), totalRows) + primaryRows.count + 1
        while true {
            let start = max(0, totalRows - rowBudget)
            let text = projectedHistoryText(
                from: primaryProjectionRows(from: start)
            )
            if start == 0 || positionalTailInputIsComplete(
                text,
                maxLines: maxLines,
                maxChars: maxChars
            ) {
                return positionalHistoryTail(text, maxLines: maxLines, maxChars: maxChars)
            }
            // Doubling rather than a computed start row: soft wrap and blank rows past the last
            // content shrink what a row contributes, and neither is known before projecting.
            // Retrying costs at most twice the text finally read.
            rowBudget *= 2
        }
    }

    /// Reports whether either positional bound can decide the final start without older text.
    private func positionalTailInputIsComplete(
        _ text: String,
        maxLines: Int,
        maxChars: Int
    ) -> Bool {
        var lineBreaks = 0
        var characters = 0
        for character in text {
            characters += 1
            if character == "\n" { lineBreaks += 1 }
        }
        return lineBreaks >= maxLines || characters > maxChars
    }

    /// Applies both positional bounds to a suffix known to contain the resulting start.
    private func positionalHistoryTail(_ text: String, maxLines: Int, maxChars: Int) -> String {
        var lineStart = text.startIndex
        var lineBreaks = 0
        for index in text.indices.reversed() where text[index] == "\n" {
            lineBreaks += 1
            if lineBreaks == maxLines {
                lineStart = text.index(after: index)
                break
            }
        }

        var characterStart = text.startIndex
        if text.count > maxChars {
            let positionalStart = text.index(text.endIndex, offsetBy: -maxChars)
            if positionalStart == text.startIndex
                || text[text.index(before: positionalStart)] == "\n" {
                characterStart = positionalStart
            } else if let boundary = text[positionalStart...].firstIndex(of: "\n") {
                characterStart = text.index(after: boundary)
            } else {
                characterStart = text.endIndex
            }
        }

        return String(text[max(lineStart, characterStart)...])
    }

    /// The primary-screen projection stream from display row `start` to its end, without
    /// materializing the rows before it. `primaryHistoryText` is this with `start` at zero.
    private func primaryProjectionRows(from start: Int) -> [GridRow] {
        let projector = primaryDisplayRows
        let primaryRows = projector.projectedGridRows()
        guard start < historyRowCount else {
            return Array(primaryRows[min(start - historyRowCount, primaryRows.count)...])
        }
        var stream = start == 0
            ? history.store.allPaintedDisplayRows()
            : history.store.paintedDisplayRows(in: start..<historyRowCount)
        stream.reserveCapacity(stream.count + primaryRows.count)
        if let last = stream.indices.last {
            stream[last] = projector.project(
                stream[last],
                projector.facts(forHistoryRow: historyRowCount - 1)
            )
        }
        stream.append(contentsOf: primaryRows)
        return stream
    }

    /// Returns the current half-open selection endpoints in stream coordinates.
    public var selectionRange: TerminalTextRange? {
        presentSelection.flatMap { publicRange($0.range) }
    }

    /// Returns the unit future Shift gestures inherit from the current selection.
    ///
    /// A caret answers `.character`: it is a settled selection like any other, and the whole
    /// point of it is that a following Shift press has a pivot and a unit to extend with.
    public var selectionGranularity: TerminalSelectionGranularity? {
        selection?.granularity
    }

    /// Returns the unit a following Shift gesture pivots on, in stream coordinates.
    ///
    /// Empty for a caret, which is what makes a click-then-Shift-click select exactly the
    /// text between the two points.
    public var selectionAnchorUnit: TerminalTextRange? {
        selection.flatMap { publicRange($0.anchorUnit) }
    }

    /// True while the only settled selection is the invisible one a click leaves behind.
    ///
    /// The one question that separates "nothing is selected" from "a pivot is waiting here":
    /// both answer `nil` for the range and the text, so pointer policy cannot decide a caret's
    /// fate any other way. Internal because a caret is engine-side state no host acts on.
    var holdsCaret: Bool {
        selection?.isCaret == true
    }

    /// The selection every public projection may show, which is every settled selection but
    /// the caret.
    private var presentSelection: SettledSelection? {
        guard let selection, selection.isCaret == false else { return nil }
        return selection
    }

    /// Returns the currently indicated HTTP(S) run in current retained-stream coordinates.
    public var hoveredLink: TerminalResolvedLink? {
        resolvedInteractionLink(for: .hover)
    }

    /// Admits and anchors one resolved link for hover presentation within the shared metadata cap.
    @discardableResult
    public mutating func setHoveredLink(_ link: TerminalResolvedLink) -> Bool {
        let before = damageActionSnapshot
        guard setInteractionLink(link, for: .hover) else { return false }
        recordDamage(since: before)
        return true
    }

    /// Reports whether the current table can atomically reserve one click target.
    func canAdmitArmedLink(_ link: TerminalResolvedLink) -> Bool {
        admittedInteractionLink(link, for: .arm) != nil
    }

    /// Atomically reserves a validated originating run for click-time revalidation.
    @discardableResult
    public mutating func setArmedLink(_ link: TerminalResolvedLink) -> Bool {
        setInteractionLink(link, for: .arm)
    }

    /// Clears the retained click reservation without affecting hover presentation.
    public mutating func clearArmedLink() {
        self[.arm] = nil
    }

    /// Reconstructs the current click reservation for release-time identity comparison.
    var armedLink: TerminalResolvedLink? {
        resolvedInteractionLink(for: .arm)
    }

    /// Clears hyperlink presentation without changing terminal text or selection.
    public mutating func clearHoveredLink() {
        guard self[.hover] != nil else { return }
        let before = damageActionSnapshot
        self[.hover] = nil
        recordDamage(since: before)
    }

    /// Serializes the selected projection units, preserving an intentionally empty selection.
    public var selectedText: String? {
        guard let selection = presentSelection else { return nil }
        return text(in: selection.range)
    }

    /// Returns one coherent counter and highlight value for the current viewport.
    public var searchReadout: TerminalSearchReadout? {
        guard isAlternateScreenActive == false, let search else { return nil }
        let projection = scrollProjection
        let rows = (evictedRowCount + projection.topRow)..<(
            evictedRowCount + projection.topRow + projection.windowRows
        )
        // A selected occurrence that does not project to a public range has no
        // highlight to point at, so the whole readout reads as unmatched rather than
        // a counter without its occurrence.
        guard let readout = search.readout(intersecting: rows, context: searchContext),
              let activeMatch = publicRange(readout.activeMatch)
        else { return .empty }
        return .matched(TerminalSearchMatches(
            selected: readout.selected,
            total: readout.total,
            activeMatch: activeMatch,
            viewportMatches: readout.viewportMatches.compactMap(publicRange)
        ))
    }

    /// Test oracle companion that reads the retained index for an explicit row window.
    func indexedSearchMatchRangesForTesting(in rows: Range<Int>) -> [TerminalTextRange] {
        guard isAlternateScreenActive == false, let search, rows.isEmpty == false else { return [] }
        let absoluteRows = (evictedRowCount + rows.lowerBound)..<(evictedRowCount + rows.upperBound)
        return search.readout(
            intersecting: absoluteRows,
            context: searchContext
        )?.viewportMatches.compactMap(publicRange) ?? []
    }

    /// Test oracle that bypasses the retained index and scans the requested row window directly.
    func scannedSearchMatchRanges(in rows: Range<Int>) -> [TerminalTextRange] {
        guard isAlternateScreenActive == false, let search, rows.isEmpty == false else { return [] }
        let absoluteRows = (evictedRowCount + rows.lowerBound)..<(evictedRowCount + rows.upperBound)
        return search.scannedMatchRanges(
            intersecting: absoluteRows,
            context: searchContext
        ).compactMap(publicRange)
    }

    /// Selects both endpoint cells after clamping them into the active stream.
    public mutating func setSelection(
        from: TerminalTextPosition,
        to: TerminalTextPosition
    ) {
        let before = damageActionSnapshot
        let first = normalizedCellPosition(from)
        let second = normalizedCellPosition(to)
        let ordered = positionPrecedes(first, second) ? (first, second) : (second, first)
        selection = SettledSelection(
            anchorUnit: emptyUnit(at: anchor(before: ordered.0)),
            focus: anchor(after: ordered.1),
            granularity: .character,
            isCaret: false
        )
        selectionRequiresNonemptyReflowResult = selectionContainsProjectedText()
        recordDamage(since: before)
    }

    /// Applies an already-computed half-open selection unit without losing wrap boundaries.
    public mutating func setSelection(_ range: TerminalTextRange) {
        setSelection(range, granularity: .character)
    }

    /// Applies an already-computed range and keeps its unit for later Shift extension.
    ///
    /// Anchors at the range's start, so a following Shift press moves its end. That is what
    /// AppKit does with a programmatic selection, and it is the only choice available: a
    /// caller that names an extent names no gesture origin.
    public mutating func setSelection(
        _ range: TerminalTextRange,
        granularity: TerminalSelectionGranularity
    ) {
        let before = damageActionSnapshot
        let ordered = textPositionPrecedes(range.start, range.end)
            ? (range.start, range.end)
            : (range.end, range.start)
        selection = SettledSelection(
            anchorUnit: emptyUnit(at: normalizedSelectionBoundary(ordered.0, isEnd: false)),
            focus: normalizedSelectionBoundary(ordered.1, isEnd: true),
            granularity: granularity,
            isCaret: false
        )
        selectionRequiresNonemptyReflowResult = selectionContainsProjectedText()
        recordDamage(since: before)
    }

    /// Settles what one pointer sample named: the unit the gesture pivots on, the boundary the
    /// pointer has reached, and the unit both are measured in.
    ///
    /// This is the only door a caret comes through. An empty character-granularity result is
    /// the pivot a plain click leaves behind, so it is stored but hidden from every public
    /// projection; every other empty result is a deliberate selection of blank cells and stays
    /// visible, copyable, and Copy-enabling.
    public mutating func setSelection(
        anchorUnit: TerminalTextRange,
        focus: TerminalTextPosition,
        granularity: TerminalSelectionGranularity
    ) {
        let before = damageActionSnapshot
        let ordered = textPositionPrecedes(anchorUnit.start, anchorUnit.end)
            ? (anchorUnit.start, anchorUnit.end)
            : (anchorUnit.end, anchorUnit.start)
        let unit = TextAnchorRange(
            start: normalizedSelectionBoundary(ordered.0, isEnd: false),
            end: normalizedSelectionBoundary(ordered.1, isEnd: true)
        )
        // The focus is whichever end of the selection it falls on, so which normalization it
        // takes is decided against the anchor rather than fixed by a parameter.
        let focusAnchor = normalizedSelectionBoundary(
            focus,
            isEnd: normalizedBoundaryPosition(focus) >= unit.start
        )
        selection = SettledSelection(
            anchorUnit: unit,
            focus: focusAnchor,
            granularity: granularity,
            isCaret: granularity == .character
                && unit.start == unit.end
                && focusAnchor == unit.start
        )
        selectionRequiresNonemptyReflowResult = selectionContainsProjectedText()
        recordDamage(since: before)
    }

    /// Selects the entire retained stream -- scrollback through viewport -- so callers copy full
    /// history without deriving stream bounds themselves. The extent is computed here from the same
    /// projection `fullHistoryText` uses, so the selected text equals it; an empty or blank buffer
    /// yields a present but empty selection, which keeps `selectedText` non-nil (and therefore
    /// `hasSelection` true) for Copy enablement rather than leaving the terminal unselected.
    public mutating func selectAll() {
        let before = damageActionSnapshot
        let units = projectionUnits()
        if let first = units.first, let last = units.last {
            selection = SettledSelection(
                anchorUnit: emptyUnit(at: first.start),
                focus: last.end,
                granularity: .character,
                isCaret: false
            )
        } else {
            let anchor = TextAnchor(row: evictedRowCount, column: 0)
            selection = SettledSelection(
                anchorUnit: emptyUnit(at: anchor),
                focus: anchor,
                granularity: .character,
                isCaret: false
            )
        }
        selectionRequiresNonemptyReflowResult = units.contains { $0.scalars.isEmpty == false }
        recordDamage(since: before)
    }

    /// Returns the maximal separator or non-separator run used by DanTerm's
    /// terminal-oriented double-click selection. Classification uses the leading
    /// scalar so a combining mark cannot move its base cell across the boundary.
    public func terminalTokenRange(at position: TerminalTextPosition) -> TerminalTextRange {
        let stream = activeProjection()
        guard let lastContentRow = stream.lastIndex(where: Self.rowContainsContent),
              let origin = nearestTextUnit(
                  to: position,
                  in: stream,
                  lastContentRow: lastContentRow
              )
        else { return emptyRange(at: position) }

        let targetIsBoundary = isTerminalTokenSeparator(origin.unit)
        var lower = origin
        while let candidate = textUnit(before: lower, in: stream, lastContentRow: lastContentRow),
              isTerminalTokenSeparator(candidate.unit) == targetIsBoundary {
            lower = candidate
        }
        var upper = origin
        while let candidate = textUnit(after: upper, in: stream, lastContentRow: lastContentRow),
              isTerminalTokenSeparator(candidate.unit) == targetIsBoundary {
            upper = candidate
        }
        return publicRange(TextAnchorRange(
            start: lower.unit.start,
            end: upper.unit.end
        )) ?? emptyRange(at: position)
    }

    /// Returns one logical line across all soft-wrapped visual rows for multi-click selection.
    public func logicalLineRange(at position: TerminalTextPosition) -> TerminalTextRange {
        logicalLineRange(at: position, in: activeProjection())
    }

    /// Walks the soft-wrap chain outward from the clicked row, so the rows it reads are the
    /// logical line's own. Takes the projection so a caller that already has one --
    /// `trimmedLogicalLineRange`, `detectedLink` -- shares it.
    private func logicalLineRange(
        at position: TerminalTextPosition,
        in stream: ProjectionRows
    ) -> TerminalTextRange {
        let target = min(max(position.row, 0), stream.count - 1)
        var first = target
        var last = target
        while first > stream.startIndex, stream[first - 1].isSoftWrapped {
            first -= 1
        }
        while last < stream.index(before: stream.endIndex), stream[last].isSoftWrapped {
            last += 1
        }
        return TerminalTextRange(
            start: TerminalTextPosition(row: first, column: 0),
            end: TerminalTextPosition(
                row: last,
                column: Self.projectedCellEnd(in: stream[last], columns: columnCount)
            )
        )
    }

    /// Returns the logical line with whitespace units removed from both outer edges, which is the
    /// unit a line-granularity pointer gesture selects. Deliberately separate from
    /// `logicalLineRange`: link detection windows its scan on that untrimmed extent, so trimming in
    /// place would move the rows it searches. A line that projects only whitespace -- or no units at
    /// all -- collapses to an empty range at the logical line's start, matching a blank line.
    public func trimmedLogicalLineRange(at position: TerminalTextPosition) -> TerminalTextRange {
        let stream = activeProjection()
        let line = logicalLineRange(at: position, in: stream)
        let lineStart = TerminalTextPosition(row: line.start.row, column: 0)
        let empty = TerminalTextRange(start: lineStart, end: lineStart)
        // Trimming whole projected units is what keeps a wide cell atomic and stops a combining
        // mark from re-classifying its whitespace base.
        let content = projectionUnits(
            from: Array(stream[line.start.row...line.end.row]),
            absoluteBase: evictedRowCount + line.start.row
        ).filter { $0.isHardBoundary == false && isWhitespaceUnit($0) == false }
        guard let first = content.first, let last = content.last else { return empty }
        return publicRange(TextAnchorRange(start: first.start, end: last.end)) ?? empty
    }

    /// Gives character-granular pointer policy the same grapheme and wide-cell atomicity as selection.
    func characterRange(at position: TerminalTextPosition) -> TerminalTextRange {
        let cell = normalizedCellPosition(position)
        return publicRange(TextAnchorRange(
            start: anchor(before: cell),
            end: anchor(after: cell)
        )) ?? emptyRange(at: position)
    }

    /// Resolves a pointed position to the nearer of the two boundaries surrounding the character
    /// under it. `offsetX` is the pointer's `0...1` position inside its own cell; the comparison
    /// spans the whole character, so a double-width cell snaps at its visual center rather than
    /// at either half's, and the midpoint itself belongs to the following boundary.
    func characterBoundary(
        at position: TerminalTextPosition,
        offsetX: Double
    ) -> TerminalTextPosition {
        let cell = normalizedCellPosition(position)
        let leading = anchor(before: cell)
        let trailing = anchor(after: cell)
        let width = max(1, trailing.column - leading.column)
        let clampedColumn = min(max(position.column, 0), columnCount - 1)
        let offsetInCharacter =
            Double(clampedColumn - cell.column) + min(max(offsetX, 0), 1)
        let column = offsetInCharacter >= Double(width) / 2 ? trailing.column : leading.column
        return canonicalBoundary(TerminalTextPosition(row: cell.row, column: column))
    }

    /// Collapses the two spellings of a soft-wrap seam -- past a wrapped row's last column, and
    /// before its continuation's first -- onto the second. They name one visual position, so
    /// without this a drag across the seam could compare two ends as distinct while selecting
    /// nothing between them.
    func canonicalBoundary(_ position: TerminalTextPosition) -> TerminalTextPosition {
        let stream = activeProjection()
        guard position.column >= columnCount,
              position.row >= 0,
              position.row + 1 < stream.count,
              stream[position.row].isSoftWrapped
        else { return position }
        return TerminalTextPosition(row: position.row + 1, column: 0)
    }

    /// Resolves explicit OSC 8 metadata or a detected URL through the HTTP(S) activation gate.
    public func activatableLink(at position: TerminalTextPosition) -> TerminalResolvedLink? {
        if let explicit = explicitLink(at: position) {
            guard isActivatableWebURI(explicit.hyperlink.uri) else { return nil }
            return explicit
        }
        return detectedLink(at: position)
    }

    /// Steps outward from the clicked cell over the run that shares its hyperlink id, holding
    /// one row at a time and fetching the next only when the run reaches a soft-wrap seam. Each
    /// stream subscript on a retained row is a history locate plus a row paint, so the cost of
    /// resolving a link is the rows it spans, not the cells it covers.
    private func explicitLink(at position: TerminalTextPosition) -> TerminalResolvedLink? {
        let stream = activeProjection()
        guard stream.isEmpty == false else { return nil }
        let row = min(max(position.row, 0), stream.count - 1)
        let column = min(max(position.column, 0), columnCount - 1)
        let clicked = stream[row]
        guard column < Self.projectedCellEnd(in: clicked, columns: columnCount),
              let id = clicked.cell(at: column).hyperlinkId,
              let target = hyperlinkTargets[id]
        else { return nil }

        var start = TerminalTextPosition(row: row, column: column)
        var window = clicked
        while start.column > 0, window.cell(at: start.column - 1).hyperlinkId == id {
            start.column -= 1
        }
        var windowRow = row
        while start.column == 0, windowRow > 0 {
            let previous = stream[windowRow - 1]
            guard previous.isSoftWrapped else { break }
            windowRow -= 1
            window = previous
            let previousEnd = Self.projectedCellEnd(in: previous, columns: columnCount)
            guard previousEnd > 0 else { continue }
            guard previous.cell(at: previousEnd - 1).hyperlinkId == id else { break }
            start = TerminalTextPosition(row: windowRow, column: previousEnd - 1)
            while start.column > 0, previous.cell(at: start.column - 1).hyperlinkId == id {
                start.column -= 1
            }
        }

        var last = TerminalTextPosition(row: row, column: column)
        window = clicked
        windowRow = row
        var windowEnd = Self.projectedCellEnd(in: clicked, columns: columnCount)
        while last.column + 1 < windowEnd, window.cell(at: last.column + 1).hyperlinkId == id {
            last.column += 1
        }
        while last.column + 1 >= windowEnd, window.isSoftWrapped, windowRow + 1 < stream.count {
            let next = stream[windowRow + 1]
            windowRow += 1
            window = next
            windowEnd = Self.projectedCellEnd(in: next, columns: columnCount)
            guard windowEnd > 0 else { continue }
            guard next.cell(at: 0).hyperlinkId == id else { break }
            last = TerminalTextPosition(row: windowRow, column: 0)
            while last.column + 1 < windowEnd, next.cell(at: last.column + 1).hyperlinkId == id {
                last.column += 1
            }
        }

        let range = TerminalTextRange(
            start: start,
            end: .init(row: last.row, column: last.column + 1)
        )
        return TerminalResolvedLink(
            hyperlink: target,
            range: range,
            activationIdentity: activationIdentity(in: range, stream: stream)
        )
    }

    private func detectedLink(at position: TerminalTextPosition) -> TerminalResolvedLink? {
        let stream = activeProjection()
        let lineRange = logicalLineRange(at: position, in: stream)
        let absoluteBase = evictedRowCount
        let rowRadius = Self.maximumHyperlinkTargetBytes / columnCount + 2
        let targetRow = min(max(position.row, lineRange.start.row), lineRange.end.row)
        let firstRow = max(lineRange.start.row, targetRow - rowRadius)
        let lastRow = min(lineRange.end.row, targetRow + rowRadius)
        let units = projectionUnits(
            from: Array(stream[firstRow...lastRow]),
            absoluteBase: absoluteBase + firstRow
        ).filter { $0.isHardBoundary == false }
        guard units.isEmpty == false else { return nil }
        let absolutePosition = TextAnchor(
            row: absoluteBase + min(max(position.row, lineRange.start.row), lineRange.end.row),
            column: min(max(position.column, 0), columnCount - 1)
        )
        guard let targetUnit = units.firstIndex(where: {
            $0.start <= absolutePosition && absolutePosition < $0.end
        }) else { return nil }

        var scalars: [Unicode.Scalar] = []
        var scalarUnits: [Int] = []
        for (unitIndex, unit) in units.enumerated() {
            for scalar in unit.scalars {
                scalars.append(scalar)
                scalarUnits.append(unitIndex)
            }
        }
        let targetScalars = scalarUnits.indices.filter { scalarUnits[$0] == targetUnit }
        guard let targetScalar = targetScalars.first else { return nil }
        let lowerWindow = max(0, targetScalar - Self.maximumHyperlinkTargetBytes)
        let upperWindow = min(scalars.count, targetScalar + Self.maximumHyperlinkTargetBytes + 1)

        for start in lowerWindow..<upperWindow where hasHTTPSPrefix(scalars, at: start) {
            if start > lowerWindow, isURLBodyScalar(scalars[start - 1]) { continue }
            var end = start
            while end < upperWindow, isURLBodyScalar(scalars[end]) { end += 1 }
            while end > start, isTrailingURLPunctuation(scalars[end - 1]) { end -= 1 }
            guard end > start,
                  scalarUnits[start...end - 1].contains(targetUnit)
            else { continue }
            var uri = String()
            // One append into a fresh string, over a slice already bounded by
            // `maximumHyperlinkTargetBytes` -- so the copy the generic overload makes is a
            // single copy of a URL, not one per scalar of a walk. The marker is what
            // `scripts/terminal-scalar-append-lint.sh` allows this site by.
            uri.unicodeScalars.append(contentsOf: scalars[start..<end])  // scalar-append: bounded-single-append
            guard uri.utf8.count <= Self.maximumHyperlinkTargetBytes,
                  isActivatableWebURI(uri)
            else { continue }
            let firstUnit = units[scalarUnits[start]]
            let lastUnit = units[scalarUnits[end - 1]]
            return TerminalResolvedLink(
                hyperlink: TerminalHyperlink(uri: uri),
                range: TerminalTextRange(
                    start: .init(
                        row: firstUnit.start.row - absoluteBase,
                        column: firstUnit.start.column
                    ),
                    end: .init(
                        row: lastUnit.end.row - absoluteBase,
                        column: lastUnit.end.column
                    )
                ),
                activationIdentity: activationIdentity(
                    in: TerminalTextRange(
                        start: .init(
                            row: firstUnit.start.row - absoluteBase,
                            column: firstUnit.start.column
                        ),
                        end: .init(
                            row: lastUnit.end.row - absoluteBase,
                            column: lastUnit.end.column
                        )
                    ),
                    stream: stream
                )
            )
        }
        return nil
    }

    private func hasHTTPSPrefix(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        let http: [UInt32] = [0x68, 0x74, 0x74, 0x70]
        guard index + 8 <= scalars.count else { return false }
        for offset in http.indices {
            let value = scalars[index + offset].value | 0x20
            guard value == http[offset] else { return false }
        }
        var colon = index + 4
        if scalars[colon].value | 0x20 == 0x73 { colon += 1 }
        guard colon + 2 < scalars.count else { return false }
        return scalars[colon].value == 0x3A
            && scalars[colon + 1].value == 0x2F
            && scalars[colon + 2].value == 0x2F
    }

    private func isURLBodyScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return value > 0x20 && value != 0x7F
            && value != 0x22 && value != 0x27
            && value != 0x28 && value != 0x3C && value != 0x3E
            && value != 0x5B && value != 0x7B
    }

    private func activationIdentity(
        in range: TerminalTextRange,
        stream: ProjectionRows
    ) -> Int {
        guard range.start.row <= range.end.row else { return 0 }
        var identity = 0
        for row in range.start.row...range.end.row where stream.indices.contains(row) {
            let start = row == range.start.row ? range.start.column : 0
            let end = row == range.end.row ? range.end.column : columnCount
            let cells = stream[row]
            for column in max(0, start)..<min(columnCount, end) {
                identity = max(identity, Int(cells.cell(at: column).contentIdentity ?? 0))
            }
        }
        return identity
    }

    private func isTrailingURLPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        [0x2C, 0x2E, 0x3B, 0x3A, 0x21, 0x3F, 0x29, 0x5C, 0x5D, 0x7D]
            .contains(scalar.value)
    }

    /// Clears only the local selection, leaving an active search untouched.
    public mutating func clearSelection() {
        let before = damageActionSnapshot
        selection = nil
        recordDamage(since: before)
    }

    /// Selects the newest literal match, keeping a non-matching needle as an empty search.
    ///
    /// An empty needle is not a search at all and drops the state entirely; a non-empty
    /// needle that matches nothing stays active with no occurrence so the caller can
    /// distinguish "found nothing" from "not searching".
    @discardableResult
    public mutating func beginSearch(_ query: String) -> Bool {
        guard isAlternateScreenActive == false else { return false }
        guard query.isEmpty == false else {
            guard search != nil else { return false }
            search = nil
            recordPresentationFullDamage()
            return false
        }
        let streamRows = evictedRowCount..<(evictedRowCount + projectionRowCount)
        let position = TextAnchor(row: streamRows.upperBound, column: 0)
        var newSearch = search?.refined(
            query: query,
            position: position,
            history: history.store
        ) ?? Search(query: query, position: position, history: history.store)
        let newestMatch = newSearch.selectNewest(in: searchContext)
        search = newSearch
        if let newestMatch { revealSearchMatchIfNeeded(newestMatch) }
        recordPresentationFullDamage()
        return newestMatch != nil
    }

    /// Moves to the next older match, wrapping past the oldest back to the newest.
    @discardableResult
    public mutating func searchNext() -> Bool {
        guard search != nil else { return false }
        let context = searchContext
        guard let target = search?.moveOlder(in: context) else { return false }
        revealSearchMatchIfNeeded(target)
        recordPresentationFullDamage()
        return true
    }

    /// Moves to the previous newer match, wrapping past the newest back to the oldest.
    @discardableResult
    public mutating func searchPrevious() -> Bool {
        guard search != nil else { return false }
        let context = searchContext
        guard let target = search?.moveNewer(in: context) else { return false }
        revealSearchMatchIfNeeded(target)
        recordPresentationFullDamage()
        return true
    }

    /// Clears the needle, position, and retained match index together.
    public mutating func clearSearch() {
        guard search != nil else { return }
        search = nil
        recordPresentationFullDamage()
    }

    /// Gives tests the coordinates the retained search index actually stores.
    var indexedSearchRecordRangesForTesting: [IndexedSearchRecordRange] {
        search?.indexedRecordRanges ?? []
    }

    /// Places the durable search anchor at a projected boundary for resolution tests.
    mutating func setSearchPositionForTesting(_ position: TerminalTextPosition) {
        let absoluteRow = evictedRowCount + position.row
        search?.position = TextAnchor(
            row: absoluteRow,
            column: position.column
        )
    }

    private func projectedHistoryText(from stream: [GridRow]) -> String {
        // The single funnel every history-text projection passes through, so counting the stream
        // here measures what a bounded read actually walks -- including the `rowBudget *= 2`
        // retries in `primaryHistoryTailText`, which are real cost and are summed in.
        Instrument.projectionRow.record(count: stream.count)
        var result = ""
        forEachProjectionUnit(from: stream, absoluteBase: 0) { unit in
            // Scalar at a time, not `append(contentsOf:)`. The generic-sequence overload
            // routes through `String.+` -- visible in the hang's stack as
            // `append(contentsOf:) -> String.+ -> prepareForAppendInPlace -> memmove` -- which
            // leaves the accumulator non-uniquely referenced, so it copies the whole string
            // instead of appending in place. This body runs once per projected *cell*, so that
            // copy made a full-budget history quadratic: 38s to project a 16 MB scrollback,
            // versus 0.15s here. Appending a single scalar has no such overload and stays
            // in place.
            for scalar in unit.scalars { result.unicodeScalars.append(scalar) }
        }
        return result
    }

    private var presentedRows: [GridRow] {
        let topRow = scrollProjection.topRow
        let bottomRow = topRow + rowCount
        var rows: [GridRow]
        if isAlternateScreenActive {
            rows = Array(screen.rows[topRow..<bottomRow])
        } else {
            let retainedStart = min(topRow, historyRowCount)
            let retainedEnd = min(bottomRow, historyRowCount)
            rows = history.store.paintedDisplayRows(in: retainedStart..<retainedEnd)
            if bottomRow > historyRowCount {
                let liveStart = max(0, topRow - historyRowCount)
                let liveEnd = bottomRow - historyRowCount
                rows.append(contentsOf: screen.rows[liveStart..<liveEnd])
            }
        }
        precondition(rows.count == rowCount, "viewport projection exceeded the active stream")
        let projector = activeDisplayRows
        return rows.enumerated().map { offset, row in
            projector.project(row, viewportRowFacts(projector, at: topRow + offset))
        }
    }

    /// The viewport projected to cell *kinds* only, which is all `geometry` carries.
    ///
    /// Separate from `presentedRows` because that materializes whole rows, and for a
    /// retained row materializing means decoding a style, a hyperlink, and a content
    /// identity per cell plus retaining a `TerminalScalars` -- every one of which
    /// `TerminalGeometry` then drops. `research/28/F17` measured this as roughly half the browsing
    /// regression, and it was pure waste: geometry has never read a scalar.
    ///
    /// Padding past a content-sized row's stored extent is synthesized here rather than
    /// stored, which is the same contract `forEachViewportCell(row:_:)` honors.
    private var presentedRowGeometry: [TerminalRowGeometry] {
        let topRow = scrollProjection.topRow
        let blankKind = GridCell().kind
        let projector = activeDisplayRows
        var cursor = historyCursor(atStreamRow: topRow)
        return (topRow..<(topRow + rowCount)).map { index in
            var kinds = [TerminalCellGeometry](
                repeating: TerminalCellGeometry(kind: blankKind),
                count: columnCount
            )
            if let at = cursor {
                var stored = 0
                history.store.forEachKind(at: at) { column, kind in
                    guard column < columnCount else { return }
                    kinds[column] = TerminalCellGeometry(kind: kind)
                    stored = column + 1
                }
                let wrapped = history.store.isSoftWrapped(at: at)
                cursor = history.store.advance(at)
                if cursor == nil, stored >= columnCount - 1 {
                    let storedMargin = stored == columnCount
                        ? GridCell(kind: kinds[columnCount - 1].kind)
                        : nil
                    let margin = projector.margin(
                        stored: storedMargin,
                        projector.facts(forHistoryRow: historyRowCount - 1)
                    )
                    kinds[columnCount - 1] = TerminalCellGeometry(kind: margin.kind)
                }
                return TerminalRowGeometry(cells: kinds, isSoftWrapped: wrapped)
            }
            guard let row = viewportStreamRow(at: index) else {
                preconditionFailure("viewport projection exceeded the active stream")
            }
            let facts = viewportRowFacts(projector, at: index)
            for column in 0..<(columnCount - 1) {
                kinds[column] = TerminalCellGeometry(kind: row.cell(at: column).kind)
            }
            kinds[columnCount - 1] = TerminalCellGeometry(kind: projector.margin(of: row, facts).kind)
            return TerminalRowGeometry(cells: kinds, isSoftWrapped: row.isSoftWrapped)
        }
    }

    /// Addresses a stream row inside retained history, or nil when it names a live row.
    ///
    /// The one `locate` a viewport traversal is allowed (`31/I7`, `research/31/D3` Decision 1 rule 2):
    /// callers take one of these for the top row and carry it forward with
    /// `LogicalLineStore.advance(_:)`, so the number of locates a frame spends is a small
    /// constant rather than one per visible row.
    private func historyCursor(atStreamRow index: Int) -> LogicalLineStore.DisplayRowCursor? {
        guard isAlternateScreenActive == false, index >= 0, index < historyRowCount else {
            return nil
        }
        return history.store.locate(displayRow: index)
    }

    private func viewportStreamRow(at index: Int) -> GridRow? {
        guard index >= 0 else { return nil }
        if isAlternateScreenActive {
            return screen.rows.indices.contains(index) ? screen.rows[index] : nil
        }
        if let row = history.store.paintedDisplayRow(at: index) {
            return row
        }
        let liveIndex = index - historyRowCount
        return screen.rows.indices.contains(liveIndex) ? screen.rows[liveIndex] : nil
    }

    /// The active stream: history followed by the live screen, severed while the alternate
    /// screen is active. The one place the active-screen flag reaches the seam rule.
    var activeDisplayRows: DisplayRowProjector {
        DisplayRowProjector(
            history: history.store,
            grid: screen.rows,
            columns: columnCount,
            seam: isAlternateScreenActive ? .severed : .preserved
        )
    }

    /// The primary stream: history followed by the primary screen, seam always preserved
    /// whichever screen is showing.
    var primaryDisplayRows: DisplayRowProjector {
        DisplayRowProjector(
            history: history.store,
            grid: primaryScreenRows,
            columns: columnCount,
            seam: .preserved
        )
    }

    /// Projects one viewport cell without copying its row.
    private func projectedViewportCell(
        in row: GridRow,
        at streamRow: Int,
        column: Int
    ) -> GridCell {
        guard column == columnCount - 1 else { return row.cell(at: column) }
        let projector = activeDisplayRows
        return projector.margin(of: row, viewportRowFacts(projector, at: streamRow))
    }

    /// Maps the viewport's stream-row convention onto the projector's: with the alternate
    /// screen active every viewport row is a grid row at its own index, otherwise the rows
    /// below `historyRowCount` are history and the rest are grid rows offset by it.
    private func viewportRowFacts(
        _ projector: DisplayRowProjector,
        at streamRow: Int
    ) -> DisplayRowProjector.RowFacts {
        if isAlternateScreenActive { return projector.facts(forGridRow: streamRow) }
        if streamRow < historyRowCount { return projector.facts(forHistoryRow: streamRow) }
        return projector.facts(forGridRow: streamRow - historyRowCount)
    }

    private mutating func revealSearchMatchIfNeeded(_ match: TextAnchorRange) {
        guard isAlternateScreenActive == false else { return }
        let projection = scrollProjection
        let top = evictedRowCount + projection.topRow
        let target: Int
        if match.start.row < top {
            target = match.start.row
        } else if match.start.row >= top + projection.windowRows {
            target = match.start.row - projection.windowRows + 1
        } else {
            return
        }
        let maximumTop = evictedRowCount + max(0, projection.totalRows - projection.windowRows)
        viewportState = .browsing(top: TextAnchor(
            row: min(max(target, evictedRowCount), maximumTop),
            column: 0
        ))
    }

    /// Rows the active text projection spans, for the clamps that need only its extent.
    private var projectionRowCount: Int { historyRowCount + screen.rows.count }

    /// Builds the non-retained grid view one search operation reads.
    private var searchContext: Search.Context {
        Search.Context(
            history: history.store,
            projection: activeProjection(),
            evictedRowCount: evictedRowCount,
            columnCount: columnCount
        )
    }

    /// The active text projection as an indexed sequence. Every point-local query reads through
    /// this rather than `activeProjectionRows()`, which is what keeps a pointer gesture's cost
    /// independent of how much history is retained.
    private func activeProjection() -> ProjectionRows {
        ProjectionRows(history: history.store, live: screen.rows, projector: activeDisplayRows)
    }

    /// Materializes the whole projection. Reserved for consumers that inherently read all of
    /// history -- search, Select All, history export, selected-text serialization. A query that
    /// only touches the clicked point must use `activeProjection()` instead.
    ///
    /// Walks history's records once rather than subscripting the facade per row: the facade
    /// locates a display row per access, which is right for a point query and quadratic-ish for
    /// all of history.store.
    private func activeProjectionRows() -> [GridRow] {
        Instrument.wholeProjection.record()
        let projector = activeDisplayRows
        var stream = history.store.allPaintedDisplayRows()
        if let last = stream.indices.last {
            stream[last] = projector.project(stream[last], projector.facts(forHistoryRow: last))
        }
        stream.append(contentsOf: projector.projectedGridRows())
        return stream
    }

    private func projectionUnits() -> [ProjectionUnit] {
        projectionUnits(from: activeProjectionRows(), absoluteBase: evictedRowCount)
    }

    private func projectionUnits(
        from stream: [GridRow],
        absoluteBase: Int
    ) -> [ProjectionUnit] {
        var units: [ProjectionUnit] = []
        forEachProjectionUnit(from: stream, absoluteBase: absoluteBase) {
            units.append($0)
        }
        return units
    }

    private func forEachProjectionUnit(
        from stream: [GridRow],
        absoluteBase: Int,
        _ body: (ProjectionUnit) -> Void
    ) {
        guard let lastContentRow = stream.lastIndex(where: Self.rowContainsContent) else {
            return
        }

        for rowIndex in 0...lastContentRow {
            let row = stream[rowIndex]
            let end = Self.projectedCellEnd(
                in: row,
                columns: columnCount,
                textFollowsInLine: Self.textFollowsInLine(after: rowIndex, in: stream)
            )
            forEachRowTextUnit(in: row, rowIndex: rowIndex, absoluteBase: absoluteBase, end: end, body)
            if rowIndex < lastContentRow, row.isSoftWrapped == false {
                body(ProjectionUnit(
                    scalars: ["\n"],
                    start: TextAnchor(row: absoluteBase + rowIndex, column: end),
                    end: TextAnchor(row: absoluteBase + rowIndex + 1, column: 0),
                    isHardBoundary: true
                ))
            }
        }
    }

    /// Emits one row's text units, the single definition of what a projected cell becomes.
    /// The whole-stream walk and the point-local expansion walk both go through here, so
    /// they cannot drift apart on wide cells, padding, or trailing-cell truncation; the
    /// hard boundary *between* rows is not a row-local fact and stays with each caller.
    private func forEachRowTextUnit(
        in row: GridRow,
        rowIndex: Int,
        absoluteBase: Int,
        end: Int,
        _ body: (ProjectionUnit) -> Void
    ) {
        var column = 0
        while column < end {
            let cell = row.cell(at: column)
            let width = cell.kind == .wideHead ? 2 : 1
            let scalars: [Unicode.Scalar]?
            switch cell.kind {
            case .narrow, .wideHead:
                scalars = Array(row.scalars(of: cell))
            case .padding:
                scalars = [" "]
            case .wideTail, .spacerHead:
                scalars = nil
            }
            if let scalars {
                body(ProjectionUnit(
                    scalars: scalars,
                    start: TextAnchor(row: absoluteBase + rowIndex, column: column),
                    end: TextAnchor(row: absoluteBase + rowIndex, column: column + width),
                    isHardBoundary: false
                ))
            }
            column += width
        }
    }

    /// One past the last column a row projects text for.
    ///
    /// A soft-wrapped row projects its blanks as spaces only while text follows them in the
    /// same logical line; the padding after a line's last text -- an erase, or the blanks a
    /// width change folds to keep a parked cursor's distance -- is not text, whichever display
    /// row it lands on. A wrapped row is measured to its own extent rather than to the pane
    /// width, which is the same number for every live row and for every folded row except at a
    /// seam: the open tail's final display row is short by the `.spacerHead` admission dropped,
    /// and a forced split's last row is short whenever the split offset is not a multiple of
    /// the current width. Measuring those to `columnCount` would project the padding past them
    /// as spaces the program never printed.
    static func projectedCellEnd(in row: GridRow, columns: Int, textFollowsInLine: Bool) -> Int {
        row.isSoftWrapped && textFollowsInLine
            ? min(columns, row.cells.count)
            : retainedContentEnd(in: row)
    }

    /// The row-local bound, for the readers that place a coordinate at a row's end (search,
    /// click expansion, the end-of-stream anchor) rather than emit its text: a wrapped row
    /// counts to its own extent whether or not text follows it.
    static func projectedCellEnd(in row: GridRow, columns: Int) -> Int {
        projectedCellEnd(in: row, columns: columns, textFollowsInLine: true)
    }

    /// Whether any later display row of the logical line that row `index` belongs to holds
    /// text. Walks forward only while rows continue, so it stops at the line's end.
    static func textFollowsInLine<Rows: RandomAccessCollection>(
        after index: Int,
        in rows: Rows
    ) -> Bool where Rows.Element == GridRow, Rows.Index == Int {
        guard rows[index].isSoftWrapped else { return false }
        var next = index + 1
        while next < rows.endIndex {
            let row = rows[next]
            if rowContainsContent(row) { return true }
            if row.isSoftWrapped == false { return false }
            next += 1
        }
        return false
    }

    private func text(in range: TextAnchorRange) -> String {
        var result = ""
        forEachProjectionUnit(
            from: activeProjectionRows(),
            absoluteBase: evictedRowCount
        ) { unit in
            if unit.start >= range.start && unit.end <= range.end {
                // Scalar at a time -- see `projectedHistoryText(from:)`; the same quadratic
                // `append(contentsOf:)` path would make copying a large selection hang.
                for scalar in unit.scalars { result.unicodeScalars.append(scalar) }
            }
        }
        return result
    }

    /// Reports whether the current selection contains any unit the full projection emits.
    ///
    /// Selection creation is a pointer-move path, so this reads only the selected rows through
    /// `ProjectionRows`. Locating the final emitted row may scan the trailing blank tail; that
    /// is the same degenerate accepted by the other point-local projection queries.
    private func selectionContainsProjectedText() -> Bool {
        guard let selection else { return false }
        let range = selection.range
        let stream = activeProjection()
        guard let lastContentRow = stream.lastIndex(where: Self.rowContainsContent) else {
            return false
        }
        let firstRow = max(0, range.start.row - evictedRowCount)
        let lastRow = min(lastContentRow, range.end.row - evictedRowCount)
        guard firstRow <= lastRow else { return false }

        for rowIndex in firstRow...lastRow {
            let row = stream[rowIndex]
            var containsText = false
            forEachRowTextUnit(
                in: row,
                rowIndex: rowIndex,
                absoluteBase: evictedRowCount,
                end: Self.projectedCellEnd(
                    in: row,
                    columns: columnCount,
                    textFollowsInLine: Self.textFollowsInLine(after: rowIndex, in: stream)
                )
            ) { unit in
                if unit.scalars.isEmpty == false,
                   unit.start >= range.start,
                   unit.end <= range.end {
                    containsText = true
                }
            }
            if containsText { return true }

            guard row.isSoftWrapped == false, rowIndex < lastContentRow else { continue }
            let boundary = ProjectionUnit(
                scalars: ["\n"],
                start: TextAnchor(
                    row: evictedRowCount + rowIndex,
                    column: Self.projectedCellEnd(in: row, columns: columnCount)
                ),
                end: TextAnchor(row: evictedRowCount + rowIndex + 1, column: 0),
                isHardBoundary: true
            )
            if boundary.start >= range.start,
               boundary.end <= range.end {
                return true
            }
        }
        return false
    }

    private func publicRange(_ range: TextAnchorRange) -> TerminalTextRange? {
        let base = evictedRowCount
        let streamCount = historyRowCount + screen.rows.count
        guard range.start.row >= base,
              range.end.row >= base,
              range.start.row < base + streamCount,
              range.end.row < base + streamCount
        else { return nil }
        return TerminalTextRange(
            start: TerminalTextPosition(row: range.start.row - base, column: range.start.column),
            end: TerminalTextPosition(row: range.end.row - base, column: range.end.column)
        )
    }

    private func normalizedCellPosition(_ position: TerminalTextPosition) -> CellPosition {
        let stream = activeProjection()
        let row = min(max(position.row, 0), stream.count - 1)
        var column = min(max(position.column, 0), columnCount - 1)
        if stream[row].cell(at: column).kind == .wideTail {
            column = max(0, column - 1)
        }
        return CellPosition(row: row, column: column)
    }

    private func normalizedBoundaryPosition(_ position: TerminalTextPosition) -> TextAnchor {
        let row = min(max(position.row, 0), projectionRowCount - 1)
        let column = min(max(position.column, 0), columnCount)
        return TextAnchor(row: evictedRowCount + row, column: column)
    }

    /// Spells the degenerate anchor unit -- one boundary -- that a character gesture and every
    /// programmatic selection pivot on.
    private func emptyUnit(at anchor: TextAnchor) -> TextAnchorRange {
        TextAnchorRange(start: anchor, end: anchor)
    }

    private func normalizedSelectionBoundary(
        _ position: TerminalTextPosition,
        isEnd: Bool
    ) -> TextAnchor {
        let row = min(max(position.row, 0), projectionRowCount - 1)
        if isEnd {
            guard position.column > 0 else {
                return TextAnchor(row: evictedRowCount + row, column: 0)
            }
            let cell = normalizedCellPosition(TerminalTextPosition(
                row: row,
                column: position.column - 1
            ))
            return anchor(after: cell)
        }
        guard position.column < columnCount else {
            return TextAnchor(row: evictedRowCount + row, column: columnCount)
        }
        let cell = normalizedCellPosition(TerminalTextPosition(
            row: row,
            column: position.column
        ))
        return anchor(before: cell)
    }

    /// Projects one stream row's text units, applying the whole-stream truncation rule: a
    /// row past the stream's last content row projects nothing. Hard boundaries are absent
    /// by construction -- a row-local list has nowhere to put the newline that belongs
    /// *between* rows -- so the expansion walk applies that rule structurally instead
    /// (`textUnit(before:)` / `textUnit(after:)`).
    private func rowTextUnits(
        in stream: ProjectionRows,
        row rowIndex: Int,
        lastContentRow: Int
    ) -> [ProjectionUnit] {
        guard rowIndex <= lastContentRow else { return [] }
        var units: [ProjectionUnit] = []
        let row = stream[rowIndex]
        forEachRowTextUnit(
            in: row,
            rowIndex: rowIndex,
            absoluteBase: evictedRowCount,
            end: Self.projectedCellEnd(
                in: row,
                columns: columnCount,
                textFollowsInLine: Self.textFollowsInLine(after: rowIndex, in: stream)
            )
        ) { units.append($0) }
        return units
    }

    /// Resolves the unit a click expands from without projecting the stream: the containing
    /// unit when one exists, else the nearest preceding one, else -- when nothing precedes
    /// the click -- the stream's first unit. Units are ordered and non-overlapping, so the
    /// last unit with `start <= target` is the containing unit whenever there is one, which
    /// collapses both cases into one backward walk. Rows that project nothing cost one
    /// row-level content scan each and no unit construction.
    private func nearestTextUnit(
        to position: TerminalTextPosition,
        in stream: ProjectionRows,
        lastContentRow: Int
    ) -> ProjectionCursor? {
        let target = normalizedBoundaryPosition(position)
        var backward = min(max(target.row - evictedRowCount, 0), lastContentRow)
        while backward >= 0 {
            let units = rowTextUnits(in: stream, row: backward, lastContentRow: lastContentRow)
            if let index = units.lastIndex(where: { $0.start <= target }) {
                return ProjectionCursor(row: backward, indexInRow: index, rowUnits: units)
            }
            backward -= 1
        }
        var forward = 0
        while forward <= lastContentRow {
            let units = rowTextUnits(in: stream, row: forward, lastContentRow: lastContentRow)
            if units.isEmpty == false {
                return ProjectionCursor(row: forward, indexInRow: 0, rowUnits: units)
            }
            forward += 1
        }
        return nil
    }

    /// Steps to the preceding text unit, or `nil` where the whole-stream projection would
    /// have emitted a hard boundary: a non-soft-wrapped predecessor row ends the line, and
    /// so does the top of the stream.
    private func textUnit(
        before cursor: ProjectionCursor,
        in stream: ProjectionRows,
        lastContentRow: Int
    ) -> ProjectionCursor? {
        if cursor.indexInRow > cursor.rowUnits.startIndex {
            return ProjectionCursor(
                row: cursor.row,
                indexInRow: cursor.rowUnits.index(before: cursor.indexInRow),
                rowUnits: cursor.rowUnits
            )
        }
        // A soft-wrapped row that projects no unit is not a boundary; keep walking past it,
        // exactly as a scan of the whole unit array would.
        var row = cursor.row
        while row > 0, stream[row - 1].isSoftWrapped {
            row -= 1
            let units = rowTextUnits(in: stream, row: row, lastContentRow: lastContentRow)
            if units.isEmpty == false {
                return ProjectionCursor(
                    row: row,
                    indexInRow: units.index(before: units.endIndex),
                    rowUnits: units
                )
            }
        }
        return nil
    }

    /// Steps to the following text unit, stopping at a hard line ending and at the stream's
    /// last content row, past which the projection emits nothing.
    private func textUnit(
        after cursor: ProjectionCursor,
        in stream: ProjectionRows,
        lastContentRow: Int
    ) -> ProjectionCursor? {
        if cursor.indexInRow < cursor.rowUnits.index(before: cursor.rowUnits.endIndex) {
            return ProjectionCursor(
                row: cursor.row,
                indexInRow: cursor.rowUnits.index(after: cursor.indexInRow),
                rowUnits: cursor.rowUnits
            )
        }
        var row = cursor.row
        while row < lastContentRow, stream[row].isSoftWrapped {
            row += 1
            let units = rowTextUnits(in: stream, row: row, lastContentRow: lastContentRow)
            if units.isEmpty == false {
                return ProjectionCursor(row: row, indexInRow: units.startIndex, rowUnits: units)
            }
        }
        return nil
    }

    private func emptyRange(at position: TerminalTextPosition) -> TerminalTextRange {
        let boundary = normalizedBoundaryPosition(position)
        let publicPosition = TerminalTextPosition(
            row: boundary.row - evictedRowCount,
            column: boundary.column
        )
        return TerminalTextRange(start: publicPosition, end: publicPosition)
    }

    /// Classifies by the leading scalar, like `isTerminalTokenSeparator`, so a combining mark
    /// cannot pull its base cell across the trimming decision.
    private func isWhitespaceUnit(_ unit: ProjectionUnit) -> Bool {
        unit.scalars.first?.properties.isWhitespace ?? false
    }

    private func isTerminalTokenSeparator(_ unit: ProjectionUnit) -> Bool {
        guard let leadingScalar = unit.scalars.first else { return false }
        if leadingScalar.properties.isWhitespace {
            return true
        }
        switch leadingScalar.value {
        case 0x22, 0x24, 0x27, 0x28, 0x29, 0x2C, 0x3A, 0x3B,
             0x3C, 0x3E, 0x5B, 0x5D, 0x60, 0x7B, 0x7C, 0x7D, 0x2502:
            return true
        default:
            return false
        }
    }

    private func textPositionPrecedes(
        _ lhs: TerminalTextPosition,
        _ rhs: TerminalTextPosition
    ) -> Bool {
        lhs.row < rhs.row || (lhs.row == rhs.row && lhs.column <= rhs.column)
    }

    private func positionPrecedes(_ lhs: CellPosition, _ rhs: CellPosition) -> Bool {
        lhs.row < rhs.row || (lhs.row == rhs.row && lhs.column <= rhs.column)
    }

    private func anchor(before position: CellPosition) -> TextAnchor {
        TextAnchor(row: evictedRowCount + position.row, column: position.column)
    }

    private func anchor(after position: CellPosition) -> TextAnchor {
        let row = activeProjection()[position.row]
        let width = row.cell(at: position.column).kind == .wideHead ? 2 : 1
        return TextAnchor(
            row: evictedRowCount + position.row,
            column: min(columnCount, position.column + width)
        )
    }

    /// Runs one history mutation through the door with this terminal's search slot.
    ///
    /// Every history mutation goes through here, so this is the single place a later change to
    /// how the slot is held -- or to who owns search state -- has to edit.
    private mutating func mutateHistory<Result>(
        _ body: (inout LogicalLineStore) -> Result
    ) -> Result {
        withHistoryDoor { history, slot in history.mutate(search: &slot, body) }
    }

    /// Replaces retained history wholesale, which rebuilds the retained index rather than
    /// advancing it. See `RetainedHistory.replace(with:search:)` for why the two differ.
    private mutating func replaceHistory(with replacement: LogicalLineStore) {
        withHistoryDoor { history, slot in history.replace(with: replacement, search: &slot) }
    }

    /// Supplies this terminal's search slot to one door call.
    ///
    /// The slot is moved into a local rather than passed as `&search` for two reasons. `search`
    /// is an observed property, so an `inout` on it is a formal access to the whole terminal and
    /// would overlap the door's access to `history`. And when no search exists the door gets a
    /// slot minted inactive on purpose, which keeps `search`'s inspection-cache `didSet` off the
    /// hottest path in the engine: that path reads the slot and writes nothing.
    private mutating func withHistoryDoor<Result>(
        _ body: (inout RetainedHistory, inout Search?) -> Result
    ) -> Result {
        guard search != nil else {
            var inactive: Search?
            return body(&history, &inactive)
        }
        var slot: Search?
        swap(&slot, &search)
        let result = body(&history, &slot)
        search = slot
        return result
    }

    private mutating func refreshHasContentInspectionState() {
        hasContentInspectionState = search != nil
            || InteractionLinkSlot.allCases.contains { self[$0] != nil }
    }

    private mutating func clearInspection() {
        selection = nil
        search = nil
        for slot in InteractionLinkSlot.allCases { self[slot] = nil }
        viewportState = .following
    }

    private mutating func invalidateInspection(
        inViewportRows range: Range<Int>,
        affectsPreviousProjection: Bool = false
    ) {
        guard range.isEmpty == false else { return }
        var affected = range
        if affectsPreviousProjection {
            if affected.lowerBound > 0,
               screen.rows[affected.lowerBound - 1].marginProvenance == .wideWrap
            {
                affected = (affected.lowerBound - 1)..<affected.upperBound
            } else if affected.lowerBound == 0,
                      historyRowCount > 0,
                      activeDisplayRows.facts(forHistoryRow: historyRowCount - 1).fillsMissingWrapSpacer
            {
                invalidateInspection(inScrollbackRow: historyRowCount - 1)
            }
        }
        if viewportState == .following {
            recordDamage(rows: affected)
        } else {
            recordFullDamage()
        }
        invalidateInspectionState(inViewportRows: affected)
    }

    /// The state half of `invalidateInspection(inViewportRows:)` alone, for the
    /// row-scroll path whose damage is the shift `recordScrollDamage` records:
    /// content still leaves the range in absolute coordinates, so link state
    /// anchored there must drop, but the whole-range row damage the
    /// combined form records is exactly what the shift representation deletes.
    private mutating func invalidateInspectionState(inViewportRows range: Range<Int>) {
        guard range.isEmpty == false, hasContentInspectionState else { return }
        let lower = evictedRowCount + historyRowCount + range.lowerBound
        let upper = evictedRowCount + historyRowCount + range.upperBound - 1
        invalidateInspection(inAbsoluteRows: lower...upper)
    }

    private mutating func invalidateInspection(inScrollbackRow row: Int) {
        if viewportState != .following {
            recordFullDamage()
        }
        guard hasContentInspectionState else { return }
        let absoluteRow = evictedRowCount + row
        invalidateInspection(inAbsoluteRows: absoluteRow...absoluteRow)
    }

    private mutating func invalidateInspection(inAbsoluteRows rows: ClosedRange<Int>) {
        // Link state asserts facts about cell content, so an overwrite retires it. Search
        // keeps a position rather than a content assertion and resolves against live matches.
        for slot in InteractionLinkSlot.allCases {
            if let state = self[slot], range(state.range, intersects: rows) {
                self[slot] = nil
            }
        }
    }

    private func range(
        _ range: TextAnchorRange,
        intersects rows: ClosedRange<Int>
    ) -> Bool {
        let lastIncludedRow = range.end.column == 0 && range.end.row > range.start.row
            ? range.end.row - 1
            : range.end.row
        return range.start.row <= rows.upperBound && lastIncludedRow >= rows.lowerBound
    }

    private func range(_ range: TextAnchorRange, intersects rows: Range<Int>) -> Bool {
        guard rows.isEmpty == false else { return false }
        return self.range(range, intersects: rows.lowerBound...(rows.upperBound - 1))
    }

    private mutating func clampSelectionToRetainedStream() {
        guard var selection else { return }
        let lastRow = evictedRowCount + historyRowCount + screen.rows.count - 1
        let lastAnchor = TextAnchor(
            row: lastRow,
            column: Self.projectedCellEnd(in: screen.rows.last!, columns: columnCount)
        )
        selection.mapBoundaries { boundary in
            min(
                TextAnchor(
                    row: boundary.row,
                    column: min(max(boundary.column, 0), columnCount)
                ),
                lastAnchor
            )
        }
        self.selection = selection
    }

    private mutating func handleEviction(of rowCount: Int) {
        guard rowCount > 0 else { return }
        evictedRowCount += rowCount
        let firstRetained = TextAnchor(row: evictedRowCount, column: 0)
        if var selection {
            // Only a wholly evicted selection is gone. A partly evicted one clamps whichever
            // of its boundaries fell off -- anchor or focus -- forward to the oldest retained
            // row, and each keeps the role it had.
            if selection.range.end <= firstRetained {
                self.selection = nil
            } else {
                selection.mapBoundaries { max($0, firstRetained) }
                self.selection = selection
            }
        }
        for slot in InteractionLinkSlot.allCases {
            if let state = self[slot], state.range.start < firstRetained {
                self[slot] = nil
            }
        }
        clampViewportAnchorToRetainedStream()
    }

    /// Keeps a browsing anchor addressable, resuming follow only when displaced to live bottom.
    private mutating func clampViewportAnchorToRetainedStream(
        previousTopBeforeReflow: TextAnchor? = nil
    ) {
        guard case let .browsing(anchor) = viewportState else { return }
        let maximumTop = evictedRowCount + max(0, historyRowCount + screen.rows.count - rowCount)
        let clamped = TextAnchor(
            row: min(max(anchor.row, evictedRowCount), maximumTop),
            column: 0
        )
        let reflowDisplaced = previousTopBeforeReflow.map {
            $0.row < evictedRowCount || $0.row > maximumTop
        } ?? false
        guard clamped != anchor || reflowDisplaced else { return }
        viewportState = clamped.row == maximumTop
            ? .following
            : .browsing(top: clamped)
        recordPresentationFullDamage()
    }

    /// Bytes a `[GridCell]` array header costs on top of its elements. Not derived from
    /// `MemoryLayout`, which describes the elements rather than the buffer holding them.
    static let arrayStorageHeaderBytes = 32

    /// Admits scrolled-off display rows into the open tail of retained history.store.
    ///
    /// One `admit` per display row, which appends its content to the logical line still being
    /// printed and closes that line when the row ends it (`research/31/D2` operation 1). Admission enforces
    /// the byte budget itself, so the eviction it causes is reported through
    /// `syncHistoryEvictions` rather than counted here.
    private mutating func appendToScrollback<S: Sequence>(_ newRows: S)
    where S.Element == GridRow {
        mutateHistory { store in
            for sourceRow in newRows {
                store.admit(sourceRow)
            }
        }
    }

    /// Brings retained history back inside its one charged-byte bound (`31/I2`).
    ///
    /// One bound, not three: the cell and row caps existed to bound the two terms of a width
    /// reflow's cost, and there is no reflow of history left to bound (`research/31/D2` Decision 4).
    private mutating func enforceScrollbackBudget() {
        _ = mutateHistory { $0.evictToBudget() }
        syncHistoryEvictions()
    }

    /// Reports whatever history has evicted since this terminal last looked, exactly once.
    ///
    /// Admission evicts on its own, so a caller that only ever counted an explicit budget pass
    /// would miss the rows a `feed` dropped. Reading the store's monotone counter instead of a
    /// per-call return is what makes the accounting independent of where the eviction happened.
    private mutating func syncHistoryEvictions() {
        let evictedCount = history.store.evictedRowCount - historyEvictionsObserved
        guard evictedCount > 0 else { return }
        historyEvictionsObserved = history.store.evictedRowCount
        primaryHistoryObservation.value &+= 1
        handleEviction(of: evictedCount)
    }

    /// Projects cell roles, row wraps, and cursor state without exposing mutable storage.
    public var geometry: TerminalGeometry {
        let projection = scrollProjection
        let windowRows = presentedRowGeometry
        let cursorStreamRow = isAlternateScreenActive
            ? screen.cursor.row
            : historyRowCount + screen.cursor.row
        let cursorWindowRow = cursorStreamRow - projection.topRow
        return TerminalGeometry(
            columns: columnCount,
            rows: windowRows,
            cursor: windowRows.indices.contains(cursorWindowRow)
                ? TerminalCursor(
                    row: cursorWindowRow,
                    column: screen.cursor.column,
                    isPendingWrap: screen.isPendingWrap
                )
                : nil
        )
    }

    /// Exposes the viewport width without constructing the test and interaction projection.
    public var viewportColumnCount: Int {
        columnCount
    }

    /// Places the visible cursor on the complete narrow or wide span a frame must render.
    public var cursorPlacement: TerminalCursorPlacement? {
        let projection = scrollProjection
        let cursorStreamRow = isAlternateScreenActive
            ? screen.cursor.row
            : historyRowCount + screen.cursor.row
        let cursorWindowRow = cursorStreamRow - projection.topRow
        guard (0..<rowCount).contains(cursorWindowRow),
              let row = viewportStreamRow(at: cursorStreamRow)
        else { return nil }

        let kind = projectedViewportCell(
            in: row,
            at: cursorStreamRow,
            column: screen.cursor.column
        ).kind
        if kind == .wideTail, screen.cursor.column > 0,
           projectedViewportCell(
               in: row,
               at: cursorStreamRow,
               column: screen.cursor.column - 1
           ).kind == .wideHead
        {
            return TerminalCursorPlacement(
                row: cursorWindowRow,
                column: screen.cursor.column - 1,
                columnWidth: 2
            )
        }
        return TerminalCursorPlacement(
            row: cursorWindowRow,
            column: screen.cursor.column,
            columnWidth: kind == .wideHead && screen.cursor.column + 1 < columnCount ? 2 : 1
        )
    }

    /// Returns scalar-exact content for a valid viewport coordinate.
    public func cell(row: Int, column: Int) -> TerminalCell? {
        let streamRow = scrollProjection.topRow + row
        guard row >= 0,
              row < rowCount,
              let windowRow = viewportStreamRow(at: streamRow),
              column >= 0,
              column < columnCount
        else {
            return nil
        }
        let cell = projectedViewportCell(in: windowRow, at: streamRow, column: column)
        return TerminalCell(
            kind: cell.kind,
            scalars: windowRow.scalars(of: cell),
            style: style(for: cell.styleId),
            hyperlink: cell.hyperlinkId.flatMap { hyperlinkTargets[$0] }
        )
    }

    static var isGridCellTriviallyCopyable: Bool { _isPOD(GridCell.self) }

    static var gridCellStrideBytes: Int { MemoryLayout<GridCell>.stride }

    static var blankCellPatternByteCount: Int { MemoryLayout<BlankCellPattern>.size }

    static func gridCellForTesting(word: CellWord) -> GridCell { GridCell(word: word) }

    mutating func replaceFirstCellForSpillBoundTesting(
        with text: String,
        count: Int
    ) {
        let payload = TerminalScalars(text.unicodeScalars)
        let cell = GridCell(kind: .wideHead)
        for _ in 0..<count {
            screen.rows[0].place(cell, scalars: payload, at: 0)
        }
    }

    mutating func rewriteFirstRowSpillLayoutForTesting() {
        for column in screen.rows[0].cells.indices {
            let cell = screen.rows[0].cells[column]
            let payload = screen.rows[0].scalars(of: cell)
            if payload.count > 1 {
                screen.rows[0].place(cell, scalars: payload, at: column)
            }
        }
    }

    /// Visits one viewport row's content in a single row resolution, passing each
    /// column the three fields a renderer actually consumes.
    ///
    /// `cell(row:column:)` answers the same question per coordinate, but it re-resolves
    /// the row on every call and materializes a whole `TerminalCell` -- and the render
    /// planner, which reads a full row per frame, uses three of that value's four fields
    /// and never reads `hyperlink` at all. Resolving once per row drops the per-column
    /// `GridRow` copy, the unread hyperlink lookup, and the `TerminalCell?`
    /// construct/destroy pair out of the planner's inner loop.
    ///
    /// Deliberately closure-based rather than returning a row view: the hot consumer is
    /// a different SwiftPM target, so per-cell accessors on a returned view would be
    /// opaque cross-module calls unless `GridCell` itself became `@usableFromInline`
    /// (see docs/design/2026-07-29-cross-module-value-dispatch.md). This shape costs one
    /// cross-module call per row and keeps the per-cell work inside this module, where
    /// it is already inline.
    ///
    /// Columns are visited in ascending order starting at zero. A row outside the
    /// viewport visits nothing, which is the same information `cell(row:column:)`
    /// conveys by returning nil.
    ///
    /// A caller that reads several rows of one frame must use `forEachViewportCell(rows:_:)`
    /// instead: this spelling costs one history locate per call, and that is exactly the per-row
    /// index walk `31/I7` forbids on the frame path.
    public func forEachViewportCell(
        row: Int,
        _ body: (_ column: Int, _ scalars: TerminalScalars, _ style: TerminalStyle) -> Void
    ) {
        forEachViewportCell(rows: row..<(row + 1)) { _, column, scalars, style in
            body(column, scalars, style)
        }
    }

    /// Visits the content of every viewport row `rows` names, in ascending order.
    ///
    /// The frame path's entry point, and the shape `31/I7` needs: retained history is addressed
    /// once, at the first row the traversal touches, and carried forward record by record for the
    /// rest. Rows outside `rows` are skipped without being folded, so a damage-clipped frame pays
    /// only for what it redraws. Out-of-viewport indices visit nothing.
    public func forEachViewportCell(
        rows requested: Range<Int>,
        where includesRow: (_ row: Int) -> Bool = { _ in true },
        _ body: (
            _ row: Int,
            _ column: Int,
            _ scalars: TerminalScalars,
            _ style: TerminalStyle
        ) -> Void
    ) {
        // `withoutActuallyEscaping` because the row visitor hands `body` down one more
        // non-escaping level; nothing here outlives the call.
        withoutActuallyEscaping(body) { forward in
            forEachViewportRow(rows: requested, where: includesRow) { row, visit in
                visit { _, style, visitCells in
                    visitCells { column, _, scalars in
                        forward(row, column, scalars, style)
                    }
                }
            }
        }
    }

    /// Visits every viewport row `rows` names in ascending order, handing each one a visitor for
    /// its style segments and the cells inside each segment.
    ///
    /// The frame path's entry point, and the shape `31/I7` needs: retained history is addressed
    /// once, at the first row the traversal touches, and carried forward record by record for the
    /// rest. Rows outside `rows` are skipped without being folded, so a damage-clipped frame pays
    /// only for what it redraws. Out-of-viewport indices visit nothing.
    ///
    /// **Row-scoped rather than cell-scoped on purpose.** A caller that plans a row needs three
    /// things resolved per row and read per column -- its hovered span, selected span, and cells.
    /// Under a single per-cell closure the row-scoped values become captured mutable variables
    /// that the closure re-reads on every column, and `research/31/F13` measured the result at 60% of the
    /// browsing regression; handing the row out first lets the caller hold them as ordinary
    /// locals, which is what the pre-plural spelling did. Calling `visit` is the caller's choice:
    /// a row it declines to visit still steps the traversal forward correctly.
    public func forEachViewportRow(
        rows requested: Range<Int>,
        where includesRow: (_ row: Int) -> Bool = { _ in true },
        _ body: (
            _ row: Int,
            _ visit: (
                (
                    _ columns: Range<Int>,
                    _ style: TerminalStyle,
                    _ visitCells: (
                        (
                            _ column: Int,
                            _ kind: TerminalCellKind,
                            _ scalars: TerminalScalars
                        ) -> Void
                    ) -> Void
                ) -> Void
            ) -> Void
        ) -> Void
    ) {
        let wanted = requested.clamped(to: 0..<rowCount)
        guard wanted.isEmpty == false else { return }

        // Bound the reference context to this traversal. It carries the two value-backed stores
        // through nested row callbacks without making those callbacks copy the whole terminal.
        do {
            let topRow = scrollProjection.topRow
            let viewportColumns = columnCount
            let projector = activeDisplayRows
            var cursor = historyCursor(atStreamRow: topRow + wanted.lowerBound)
            let resolvedStyles = styleTable.count == 1 ? nil : styleTable
            let readStorage: ViewportRowReadStorage?
            if cursor == nil {
                readStorage = nil
            } else {
                readStorage = ViewportRowReadStorage(
                    store: history.store,
                    styles: resolvedStyles
                )
            }
            // Every visitor below is synchronous and non-escaping. Carry a trivial reference
            // through them, then keep its owner alive explicitly through the last callback.
            let readStorageReference = readStorage.map(Unmanaged.passUnretained)

            // Memoized across segments because adjacent rows often repeat the same handful of style
            // ids. Correct for any content -- a miss just re-resolves.
            var lastId: StyleId?
            var lastStyle = TerminalStyle()

            for row in wanted {
                let streamRow = topRow + row
                // A row the caller does not want still has to be stepped over, or the cursor stops
                // naming the row it is asked for next. Stepping is O(1); folding is not.
                guard includesRow(row) else {
                    if let current = cursor {
                        cursor = readStorage?.advance(current)
                    }
                    continue
                }
                let at = cursor
                if let at {
                    cursor = readStorage?.advance(at)
                }
                if at == nil,
                   viewportStreamRow(at: streamRow) == nil
                {
                    continue
                }

                // Retained rows stream out of the arena rather than being materialized first.
                // A frame reads every visible row once and discards it, so folding a `GridRow`
                // here would buy an allocation and a full `GridCell` write per cell that nothing
                // outlives -- `research/28/F17` measured that as the dominant term in the browsing
                // regression. The style memoization is written out at each site rather than
                // funnelled through a nested function: a local function called from inside the
                // fold's own closure is one more indirect call per cell, on the frame path.
                if let at {
                    let projectedMargin = cursor == nil
                        ? projector.missingMargin(projector.facts(forHistoryRow: historyRowCount - 1))
                        : nil
                    body(row) { styleRunBody in
                        guard let readStorageReference else {
                            preconditionFailure("a retained cursor requires retained read storage")
                        }
                        readStorageReference.takeUnretainedValue().withPaintedCells(at: at) {
                            storedCount, storedStyleId, storedCell in
                            // The segment visitor hands the borrowed packed-cell accessor down one
                            // more non-escaping level; nothing here outlives this row traversal.
                            withoutActuallyEscaping(storedCell) { forwardStoredCell in
                                let margin = viewportColumns - 1
                                if projectedMargin != nil {
                                    precondition(
                                        storedCount == margin,
                                        "a pending margin must complete the retained seam row"
                                    )
                                }
                                let padding = GridCell()
                                let directEnd = projectedMargin == nil
                                    ? min(storedCount, viewportColumns)
                                    : margin
                                var emittedTail = false
                                var start = 0
                                while start < directEnd {
                                    let styleId = storedStyleId(start)
                                    var end = start + 1
                                    while end < directEnd, storedStyleId(end) == styleId {
                                        end += 1
                                    }
                                    let joinsProjectedMargin = end == directEnd
                                        && directEnd == margin
                                        && projectedMargin?.styleId == styleId
                                    let joinsPadding = end == directEnd
                                        && projectedMargin == nil
                                        && directEnd < viewportColumns
                                        && padding.styleId == styleId
                                    let runEnd = joinsProjectedMargin || joinsPadding
                                        ? viewportColumns
                                        : end
                                    if styleId != lastId {
                                        lastStyle = readStorageReference.takeUnretainedValue()
                                            .style(for: styleId)
                                        lastId = styleId
                                    }
                                    styleRunBody(start..<runEnd, lastStyle) { cellBody in
                                        for column in start..<end {
                                            let cell = forwardStoredCell(column)
                                            cellBody(column, cell.kind, cell.scalars)
                                        }
                                        if joinsProjectedMargin, let projectedMargin {
                                            cellBody(margin, projectedMargin.kind, .empty)
                                        } else if joinsPadding {
                                            for column in directEnd..<viewportColumns {
                                                cellBody(column, padding.kind, .empty)
                                            }
                                        }
                                    }
                                    emittedTail = joinsProjectedMargin || joinsPadding
                                    start = end
                                }
                                if emittedTail == false, let projectedMargin {
                                    if projectedMargin.styleId != lastId {
                                        lastStyle = readStorageReference.takeUnretainedValue()
                                            .style(for: projectedMargin.styleId)
                                        lastId = projectedMargin.styleId
                                    }
                                    styleRunBody(margin..<viewportColumns, lastStyle) { cellBody in
                                        cellBody(margin, projectedMargin.kind, .empty)
                                    }
                                } else if emittedTail == false, directEnd < viewportColumns {
                                    if padding.styleId != lastId {
                                        lastStyle = readStorageReference.takeUnretainedValue()
                                            .style(for: padding.styleId)
                                        lastId = padding.styleId
                                    }
                                    styleRunBody(directEnd..<viewportColumns, lastStyle) { cellBody in
                                        for column in directEnd..<viewportColumns {
                                            cellBody(column, padding.kind, .empty)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if let windowRow = viewportStreamRow(at: streamRow) {
                    let margin = viewportColumns - 1
                    let projectedMargin: GridCell?
                    if DisplayRowProjector.derivesOwnSpacer(windowRow) {
                        projectedMargin = projector.margin(
                            of: windowRow,
                            viewportRowFacts(projector, at: streamRow)
                        )
                    } else {
                        projectedMargin = nil
                    }
                    if projectedMargin == nil, windowRow.cells.count >= viewportColumns {
                        body(row) { styleRunBody in
                            windowRow.cells.withUnsafeBufferPointer { cells in
                                if resolvedStyles == nil {
                                    if lastId != Self.defaultStyleId {
                                        lastId = Self.defaultStyleId
                                        lastStyle = TerminalStyle()
                                    }
                                    styleRunBody(0..<viewportColumns, lastStyle) { cellBody in
                                        for column in 0..<viewportColumns {
                                            let cell = cells[column]
                                            cellBody(column, cell.kind, windowRow.scalars(of: cell))
                                        }
                                    }
                                    return
                                }
                                var start = 0
                                while start < viewportColumns {
                                    let styleId = cells[start].styleId
                                    var end = start + 1
                                    while end < viewportColumns, cells[end].styleId == styleId {
                                        end += 1
                                    }
                                    if styleId != lastId {
                                        lastStyle = styleId == Self.defaultStyleId
                                            ? TerminalStyle()
                                            : resolvedStyles?[styleId] ?? TerminalStyle()
                                        lastId = styleId
                                    }
                                    styleRunBody(start..<end, lastStyle) { cellBody in
                                        for column in start..<end {
                                            let cell = cells[column]
                                            cellBody(column, cell.kind, windowRow.scalars(of: cell))
                                        }
                                    }
                                    start = end
                                }
                            }
                        }
                        continue
                    }
                    body(row) { styleRunBody in
                        let padding = GridCell()
                        let directEnd = projectedMargin == nil
                            ? min(windowRow.cells.count, viewportColumns)
                            : margin
                        var emittedTail = false
                        var start = 0
                        while start < directEnd {
                            let styleId = windowRow.cells[start].styleId
                            var end = start + 1
                            while end < directEnd, windowRow.cells[end].styleId == styleId {
                                end += 1
                            }
                            let joinsProjectedMargin = end == directEnd
                                && directEnd == margin
                                && projectedMargin?.styleId == styleId
                            let joinsPadding = end == directEnd
                                && projectedMargin == nil
                                && directEnd < viewportColumns
                                && padding.styleId == styleId
                            let runEnd = joinsProjectedMargin || joinsPadding
                                ? viewportColumns
                                : end
                            if styleId != lastId {
                                lastStyle = styleId == Self.defaultStyleId
                                    ? TerminalStyle()
                                    : resolvedStyles?[styleId] ?? TerminalStyle()
                                lastId = styleId
                            }
                            styleRunBody(start..<runEnd, lastStyle) { cellBody in
                                for column in start..<end {
                                    let cell = windowRow.cells[column]
                                    cellBody(column, cell.kind, windowRow.scalars(of: cell))
                                }
                                if joinsProjectedMargin, let projectedMargin {
                                    cellBody(margin, projectedMargin.kind, windowRow.scalars(of: projectedMargin))
                                } else if joinsPadding {
                                    for column in directEnd..<viewportColumns {
                                        cellBody(column, padding.kind, .empty)
                                    }
                                }
                            }
                            emittedTail = joinsProjectedMargin || joinsPadding
                            start = end
                        }
                        if emittedTail == false, let projectedMargin {
                            if projectedMargin.styleId != lastId {
                                lastStyle = projectedMargin.styleId == Self.defaultStyleId
                                    ? TerminalStyle()
                                    : resolvedStyles?[projectedMargin.styleId] ?? TerminalStyle()
                                lastId = projectedMargin.styleId
                            }
                            styleRunBody(margin..<viewportColumns, lastStyle) { cellBody in
                                cellBody(margin, projectedMargin.kind, windowRow.scalars(of: projectedMargin))
                            }
                        } else if emittedTail == false, directEnd < viewportColumns {
                            if padding.styleId != lastId {
                                lastStyle = padding.styleId == Self.defaultStyleId
                                    ? TerminalStyle()
                                    : resolvedStyles?[padding.styleId] ?? TerminalStyle()
                                lastId = padding.styleId
                            }
                            styleRunBody(directEnd..<viewportColumns, lastStyle) { cellBody in
                                for column in directEnd..<viewportColumns {
                                    cellBody(column, padding.kind, .empty)
                                }
                            }
                        }
                    }
                }
            }
            withExtendedLifetime(readStorage) {}
        }
    }

    /// Positions future parser actions while preserving the same cursor validity rules.
    mutating func moveCursor(row: Int, column: Int) {
        screen.cursor.row = min(max(row, 0), rowCount - 1)
        screen.cursor.column = min(max(column, 0), columnCount - 1)
        screen.isPendingWrap = false
        clusterContext = nil
    }

    /// Describes what an erase actually reached and blanked after wide-pair expansion.
    struct EraseResult {
        var coveredWholeRow: Bool
        var blankedAllCells: Bool
    }

    /// Erases a row range with pen colors after expanding across intersected wide pairs.
    ///
    /// `selective` is the `?` on DECSED/DECSEL: the region, the wide-pair expansion and the
    /// row-level repairs below are the same, and the only difference is that a protected cell
    /// keeps its content. The result separates effective row coverage from protected survivors
    /// so display erase can decide whether it actually blanked row 0 in full.
    @discardableResult
    mutating func eraseCells(row: Int, columns: Range<Int>, selective: Bool = false) -> EraseResult {
        guard screen.rows.indices.contains(row), columns.isEmpty == false else {
            return EraseResult(coveredWholeRow: false, blankedAllCells: true)
        }
        var lower = max(0, columns.lowerBound)
        var upper = min(columnCount, columns.upperBound)
        guard lower < upper else {
            return EraseResult(coveredWholeRow: false, blankedAllCells: true)
        }
        if self.screen.rows[row].cells[lower].kind == .wideTail {
            lower -= 1
        }
        if self.screen.rows[row].cells[upper - 1].kind == .wideHead {
            upper += 1
        }
        lower = max(0, lower)
        upper = min(upper, columnCount)

        invalidateInspection(
            inViewportRows: row..<(row + 1),
            affectsPreviousProjection: lower == 0
        )

        let survivors = selective ? protectedMask(row: row, columns: lower..<upper) : nil

        let styleId = backgroundEraseStyleId()
        // The expansion above pulls every intersected wide pair wholly inside the
        // range, so no cell in it has a partner outside it. That is what lets the
        // interior be filled directly instead of through a per-cell
        // `clearCellAndPair`.
        let blank = GridCell(styleId: styleId)
        withRowCells(row) { cells in
            guard let survivors else {
                for column in lower..<upper {
                    cells[column] = blank
                }
                return
            }
            for column in lower..<upper where survivors[column - lower] == false {
                cells[column] = blank
            }
        }
        // The margin cell's last writer is now an erase, so a surviving wrap claim on this
        // row is unwitnessed until a print reaches the margin again
        // (`GridRow.marginProvenance`).
        // A protected margin cell was not erased, so it does not withdraw the claim.
        if upper == columnCount, survivors?[columnCount - 1 - lower] != true {
            screen.rows[row].marginProvenance = .erase
        }
        clusterContext = nil
        return EraseResult(
            coveredWholeRow: lower == 0 && upper == columnCount,
            blankedAllCells: survivors?.contains(true) != true
        )
    }

    /// Which columns a selective erase must leave standing, decided per wide pair.
    ///
    /// A pair is kept or blanked whole, so DECSEL can never leave a head without its tail. A
    /// spacer head is a wrap artifact rather than a character, so it is always blanked and every
    /// post-erase grid shape stays one ED/EL already produce.
    private func protectedMask(row: Int, columns: Range<Int>) -> [Bool] {
        var mask = [Bool](repeating: false, count: columns.count)
        readingRowCells(row) { cells in
            for column in columns {
                let cell = cells[column]
                guard style(for: cell.styleId).protected else { continue }
                mask[column - columns.lowerBound] = true
                let partner = cell.kind == .wideHead
                    ? column + 1
                    : (cell.kind == .wideTail ? column - 1 : column)
                if columns.contains(partner) {
                    mask[partner - columns.lowerBound] = true
                }
            }
        }
        return mask
    }

    private mutating func resizePrimaryScreen(columns: Int, rows: Int) {
        if rows != rowCount {
            resizeHeight(to: rows)
        }
        if columns != columnCount {
            resizeWidth(to: columns)
        }
    }

    private mutating func resizedRectangle(
        _ sourceRows: Deque<GridRow>,
        columns: Int,
        rows: Int,
        clearsSoftWrap: Bool
    ) -> Deque<GridRow> {
        Deque((0..<rows).map { rowIndex in
            guard sourceRows.indices.contains(rowIndex) else {
                return makeBlankRow(columns: columns)
            }

            let source = sourceRows[rowIndex]
            var cells = Array(source.cells.prefix(columns))
            if cells.count < columns {
                cells.append(contentsOf: (cells.count..<columns).map { _ in GridCell() })
            }
            let keepsContinuation = sourceRows.indices.contains(rowIndex + 1)
                && rowIndex + 1 < rows
            let clearsRowWrap = clearsSoftWrap
                || (source.isSoftWrapped && keepsContinuation == false)
            repairClippedCells(&cells)
            var resized = source
            resized.cells = cells
            resized.compactClusters()
            resized.isSoftWrapped = clearsRowWrap ? false : source.isSoftWrapped
            if columns != source.cells.count {
                resized.marginProvenance = .content
            }
            return resized
        })
    }

    private mutating func repairClippedCells(_ cells: inout [GridCell]) {
        var invalidColumns: [Int] = []
        for column in cells.indices {
            switch cells[column].kind {
            case .wideHead:
                if column + 1 >= cells.count || cells[column + 1].kind != .wideTail {
                    invalidColumns.append(column)
                }
            case .wideTail:
                if column == 0 || cells[column - 1].kind != .wideHead {
                    invalidColumns.append(column)
                }
            case .padding, .narrow, .spacerHead:
                break
            }
        }

        for column in invalidColumns {
            cells[column] = clippedBlank(replacing: cells[column])
        }
    }

    private mutating func clippedBlank(replacing cell: GridCell) -> GridCell {
        GridCell(styleId: internStyle(TerminalStyle(background: style(for: cell.styleId).background)))
    }

    private mutating func resizeHeight(to newRowCount: Int) {
        if newRowCount < rowCount {
            // Text-blank rows go first, whatever their paint, and the trim stops at the cursor
            // row so a row that exists only to hold the cursor is never dropped. Line structure
            // is read through `logicallyContinues`, like every other reader: a stale wrap claim
            // on a blanked last row must not displace a content row instead.
            while screen.rows.count > newRowCount,
                  screen.rows.indices.last.map({ $0 > screen.cursor.row }) == true,
                  let last = screen.rows.last,
                  last.logicallyContinues == false,
                  Self.rowContainsContent(last) == false
            {
                screen.rows.removeLast()
            }

            let displacedCount = screen.rows.count - newRowCount
            if displacedCount > 0 {
                appendToScrollback(screen.rows.prefix(displacedCount))
                screen.rows.removeFirst(displacedCount)
                // The saved slot is a passenger: it takes the displacement the live cursor takes,
                // and the same off-screen policy (row 0, column kept) when its row left the
                // active area, so DECRC still lands on the text DECSC saved.
                func displaced(_ row: Int) -> Int {
                    row < displacedCount ? 0 : row - displacedCount
                }
                screen.cursor.row = displaced(screen.cursor.row)
                screen.control.savedCursor.position.row = displaced(screen.control.savedCursor.position.row)
                enforceScrollbackBudget()
            }
        } else {
            let addedCount = newRowCount - rowCount
            var pulledCount = 0
            if screen.cursor.row == rowCount - 1 {
                pulledCount = min(addedCount, historyRowCount)
                if pulledCount > 0 {
                    // `research/31/D2` operation 4: the only write that shrinks the arena from the back.
                    // The rows keep their absolute stream positions and merely change which side
                    // of the history/live seam they sit on, so no anchor moves and
                    // `evictedRowCount` does not advance.
                    let follower = screen.rows.first?.cells.first
                    let pulled = mutateHistory {
                        $0.truncateTail(displayRows: pulledCount, follower: follower)
                    }
                    pulledCount = pulled.count
                    screen.rows.insert(
                        contentsOf: pulled.map { $0.materialized(to: columnCount) },
                        at: 0
                    )
                    screen.cursor.row += pulledCount
                    screen.control.savedCursor.position.row += pulledCount
                }
            }
            screen.rows.append(contentsOf: (pulledCount..<addedCount).map { _ in
                makeBlankRow(columns: columnCount)
            })
        }
        rowCount = newRowCount
        clampViewportAnchorToRetainedStream()
    }

    /// Adopts a new width: history keeps its bytes, and only the live screen refolds.
    ///
    /// This is doc 31's headline. History stores logical lines rather than display rows, so a
    /// width change writes no retained byte outside the open tail's seam repair (`31/I1`,
    /// `31/I11`) and evicts nothing at any width down to the engine minimum (`31/I3`). What is
    /// left is the live screen's refold -- which doc 28 already paid for and which survives
    /// unchanged -- one pass to recount display rows, and one restatement of the held anchors.
    private mutating func resizeWidth(to newColumnCount: Int) {
        let oldColumnCount = columnCount
        let historyRowsBefore = historyRowCount
        let viewportTopBeforeReflow: TextAnchor?
        if case let .browsing(top) = viewportState {
            viewportTopBeforeReflow = top
        } else {
            viewportTopBeforeReflow = nil
        }

        // Captured against the *old* fold, which exists only until the index is recomputed.
        // `research/31/D3` Decision 2's one new ordering invariant, stated rather than discovered later.
        let capturedBeforeSeam = capturedAnchorAddresses(historyRows: historyRowsBefore)

        // A line still being printed keeps its prompt mark on its record -- unless the pull-back
        // consumes the whole record, in which case the live refold inherits it.
        let seamPrompt = history.store.hasOpenTailRecord
            ? history.store.recordSummary(at: history.store.recordCount - 1)?.semanticPrompt ?? SemanticPromptRow.none
            : SemanticPromptRow.none
        let seamFollower = screen.rows.first?.cells.first
        let seamPrefix = mutateHistory {
            $0.setWidth(newColumnCount, follower: seamFollower)
        }
        let historyRowsAfter = historyRowCount
        let captured = rebasedAcrossSeam(
            capturedBeforeSeam,
            seamPrefixLength: seamPrefix.cells.count
        )

        // The cutoff counts paint as well as text: a painted blank row is in the fold and keeps
        // its fill, and only default-blank rows past the last visible effect are rebuilt.
        let lastLiveVisibleRow = screen.rows.lastIndex { row in
            let extent = row.visibleExtent(columns: oldColumnCount)
            return extent.contentEnd > 0 || extent.fillStyle != nil
        } ?? 0
        let lastSourceRow = max(screen.cursor.row, lastLiveVisibleRow)
        // The never-written rows are layout data (`D7`): their count is conserved across the
        // fold. A row that holds nothing but the cursor's distance from its line's text is one
        // of them in disguise -- the fold opens such a row when the blanks before the cursor
        // no longer fit, and absorbs it when they fit again -- so the budget counts it on the
        // way in and `pack` reports it on the way out, and a width round trip keeps its rows.
        var trailingBlankRowCount = screen.rows.count - lastSourceRow - 1
        var cursorLineRow = screen.cursor.row
        while cursorLineRow > 0, screen.rows[cursorLineRow - 1].logicallyContinues {
            let extent = screen.rows[cursorLineRow].visibleExtent(columns: oldColumnCount)
            if extent.contentEnd == 0, extent.fillStyle == nil {
                trailingBlankRowCount += 1
            }
            cursorLineRow -= 1
        }
        // Projected as a stream of their own: the rows past `lastSourceRow` are default blanks
        // and stay out of the reflow, so the last source row has no follower.
        let sourceRows = DisplayRowProjector(
            history: history.store,
            grid: Deque(screen.rows[...lastSourceRow]),
            columns: columnCount,
            seam: .preserved
        ).projectedGridRows()
        // Order is the contract with `placed` below: the live cursor first, because it alone
        // decides the resulting layout, then the saved slot as its passenger.
        let liveCursorIndex = 0
        let savedCursorIndex = 1
        let trackedCursors = [
            TrackedCursor(
                row: screen.cursor.row,
                column: screen.cursor.column,
                isPendingWrap: screen.isPendingWrap
            ),
            TrackedCursor(
                row: screen.control.savedCursor.position.row,
                column: screen.control.savedCursor.position.column,
                isPendingWrap: screen.control.savedCursor.isPendingWrap
            ),
        ]
        let reconstruction = reconstructLogicalLines(
            from: sourceRows,
            leadingRow: seamPrefix,
            leadingSemanticPrompt: seamPrompt,
            trackedCursors: trackedCursors,
            liveCursor: trackedCursors[liveCursorIndex],
            oldColumnCount: oldColumnCount
        )

        var rebuiltRows: [GridRow] = []
        var trackedDestinations = [ReflowDestination?](repeating: nil, count: trackedCursors.count)
        var liveDestinations = [WidthChangeAnchor: TextAnchor]()
        // The offsets one line's pack walk must answer, and who asked. Declared out here and
        // emptied per line so the whole refold pays for these buffers once. The boundary
        // requests are the cursors' first and the anchor slots' after, which is what lets one
        // offset array carry both and each requester find its own answer by position.
        var cellRequestCursors: [Int] = []
        var cellRequestOffsets: [Int] = []
        var boundaryRequestCursors: [Int] = []
        var boundaryRequestSlots: [WidthChangeAnchor] = []
        var boundaryRequestOffsets: [Int] = []
        for (lineIndex, line) in reconstruction.lines.enumerated() {
            cellRequestCursors.removeAll(keepingCapacity: true)
            cellRequestOffsets.removeAll(keepingCapacity: true)
            boundaryRequestCursors.removeAll(keepingCapacity: true)
            boundaryRequestSlots.removeAll(keepingCapacity: true)
            boundaryRequestOffsets.removeAll(keepingCapacity: true)
            for index in trackedCursors.indices {
                guard case let .inLine(line, anchor) = reconstruction.attachments[index],
                      line == lineIndex else { continue }
                switch anchor {
                case let .cell(offset):
                    cellRequestCursors.append(index)
                    cellRequestOffsets.append(offset)
                case let .boundary(offset):
                    boundaryRequestCursors.append(index)
                    boundaryRequestOffsets.append(offset)
                }
            }
            for (slot, address) in captured {
                guard case let .live(line, offset) = address, line == lineIndex else { continue }
                boundaryRequestSlots.append(slot)
                boundaryRequestOffsets.append(offset)
            }

            let packed = pack(
                line: line,
                columns: newColumnCount,
                cellTargets: cellRequestOffsets,
                boundaryTargets: boundaryRequestOffsets
            )
            let baseRow = rebuiltRows.count

            // A cursor the pack walk never reached keeps no destination, and `placed` homes it.
            for (request, index) in cellRequestCursors.enumerated() {
                guard let local = packed.cellDestinations[request] else { continue }
                trackedDestinations[index] = ReflowDestination(
                    row: baseRow + local.row,
                    column: local.column,
                    isPendingWrap: local.isPendingWrap
                )
            }
            for (request, index) in boundaryRequestCursors.enumerated() {
                guard let local = packed.boundaryDestinations[request] else { continue }
                trackedDestinations[index] = ReflowDestination(
                    row: baseRow + local.row,
                    column: local.column,
                    isPendingWrap: local.isPendingWrap
                )
            }
            // An anchor offset that is no unit boundary -- one landing inside a wide pair --
            // falls back to the line's content end.
            for (request, slot) in boundaryRequestSlots.enumerated() {
                let local = packed.boundaryDestinations[boundaryRequestCursors.count + request]
                    ?? packed.contentEnd
                liveDestinations[slot] = TextAnchor(
                    row: evictedRowCount + historyRowsAfter + baseRow + local.row,
                    column: local.isPendingWrap ? newColumnCount : local.column
                )
            }
            rebuiltRows.append(contentsOf: packed.rows)
            trailingBlankRowCount = max(0, trailingBlankRowCount - packed.cursorOnlyRowCount)
        }
        let reflowedContentEndRow = max(0, rebuiltRows.count - 1)

        /// Turns one tracked cursor's resolution into a position in the rebuilt stream. A cursor
        /// the refold could not place keeps its column and homes to the top, which is the same
        /// off-screen policy a height shrink applies.
        func placed(_ index: Int) -> ReflowDestination {
            if case let .belowContent(rowsBelow, column) = reconstruction.attachments[index] {
                return ReflowDestination(
                    row: reflowedContentEndRow + rowsBelow,
                    column: min(column, newColumnCount - 1),
                    isPendingWrap: false
                )
            }
            return trackedDestinations[index] ?? ReflowDestination(
                row: 0,
                column: min(trackedCursors[index].column, newColumnCount - 1),
                isPendingWrap: false
            )
        }

        var destination = placed(liveCursorIndex)
        var savedDestination = placed(savedCursorIndex)

        // Restated against the fold as it stands now, before the viewport fill below moves rows
        // across the seam: that move keeps every row's absolute stream position, so an anchor
        // restated here stays right whichever side of the seam its row ends up on.
        restateAnchors(
            captured,
            liveDestinations: liveDestinations,
            historyRowsAfter: historyRowsAfter
        )

        for _ in 0..<trailingBlankRowCount {
            rebuiltRows.append(makeBlankRow(columns: newColumnCount))
        }

        // A widening hands history back only after the old trailing blanks are present. This
        // ordering makes the deficit equal the rows that a prior narrowing displaced.
        let deficit = rowCount - rebuiltRows.count
        if deficit > 0, historyRowCount > 0 {
            let pullCount = min(deficit, historyRowCount)
            let follower = rebuiltRows.first?.cells.first
            let pulled = mutateHistory {
                $0.truncateTail(displayRows: pullCount, follower: follower)
            }
            rebuiltRows.insert(
                contentsOf: pulled.map { $0.materialized(to: newColumnCount) },
                at: 0
            )
            destination.row += pulled.count
            savedDestination.row += pulled.count
        }
        while rebuiltRows.count < rowCount {
            rebuiltRows.append(makeBlankRow(columns: newColumnCount))
        }

        var viewportStart = max(0, rebuiltRows.count - rowCount)
        if destination.row < viewportStart {
            // Only the appended tail can be removed here. If content below the cursor still
            // exceeds the viewport after those blanks are gone, the existing top clamp applies.
            let blankShortfall = min(viewportStart - destination.row, trailingBlankRowCount)
            rebuiltRows.removeLast(blankShortfall)
            viewportStart -= blankShortfall
        }

        columnCount = newColumnCount
        screen.rows = Deque(rebuiltRows[viewportStart..<(viewportStart + rowCount)])
        screen.cursor = CellPosition(
            row: max(0, destination.row - viewportStart),
            column: destination.column
        )
        screen.isPendingWrap = destination.isPendingWrap
        // Stage two: the layout above was decided by the live cursor alone, and the saved slot is
        // mapped through it. A saved row the refold pushed above the viewport is gone from the
        // active area, so it takes the live cursor's off-screen policy: row 0, column kept.
        screen.control.savedCursor.position = CellPosition(
            row: max(0, savedDestination.row - viewportStart),
            column: savedDestination.column
        )
        screen.control.savedCursor.isPendingWrap = savedDestination.isPendingWrap

        // Whatever the refold pushed above the viewport scrolled off, so it is admitted exactly
        // as it would have been had it scrolled off one row at a time.
        if viewportStart > 0 {
            appendToScrollback(Array(rebuiltRows[..<viewportStart]))
        }
        enforceScrollbackBudget()
        clampViewportAnchorToRetainedStream(previousTopBeforeReflow: viewportTopBeforeReflow)
    }

    /// Names one of the anchors a width change has to restate, so capture and restatement cannot
    /// drift apart on which is which.
    private enum WidthChangeAnchor: Hashable {
        case selectionAnchorStart
        case selectionAnchorEnd
        case selectionFocus
        case searchPosition
        case hoverStart
        case hoverEnd
        case armStart
        case armEnd
        case browsingTop
    }

    /// What a width change did to one held range: it had none to restate, it restated one, or
    /// an endpoint did not survive the rebuild and the range goes with it.
    private enum RestatedRange {
        case untouched
        case restated(TextAnchorRange)
        case dropped
    }

    /// An anchor's content address, which is what survives a width change.
    ///
    /// Two cases rather than one because the two halves of the stream change for different
    /// reasons: history keeps its bytes and refolds, so a record address is enough; the live
    /// screen is genuinely rebuilt, so its address is the reflow line and offset the rebuild is
    /// keyed by. `research/31/D3` Decision 2 rejected making the *stored* anchor either of these -- these
    /// are transients that live for the duration of one resize.
    private enum WidthChangeAddress {
        case history(recordIndex: Int, cellOffset: Int)
        case live(line: Int, offset: Int)
    }

    /// Moves the addresses the seam pull-back invalidated onto the live side of it.
    ///
    /// `research/31/D3` Decision 4 hands the open tail's partial final display row to the live refold, so a
    /// history address that pointed into those cells no longer resolves -- and the cells did not
    /// vanish, they changed which side of the seam they sit on. The prefix seeds the refold's
    /// first logical line at offset zero, which is what makes the conversion arithmetic; the same
    /// prefix also shifts every live address on that line, which is the second half of this.
    private func rebasedAcrossSeam(
        _ captured: [(WidthChangeAnchor, WidthChangeAddress)],
        seamPrefixLength: Int
    ) -> [(WidthChangeAnchor, WidthChangeAddress)] {
        captured.map { slot, address in
            switch address {
            case let .history(recordIndex, cellOffset):
                guard history.store.position(ofRecord: recordIndex, cellOffset: cellOffset) == nil else {
                    return (slot, address)
                }
                let kept = history.store.recordSummary(at: recordIndex)?.cellCount ?? 0
                return (slot, .live(line: 0, offset: max(0, cellOffset - kept)))
            case let .live(line, offset):
                guard line == 0 else { return (slot, address) }
                return (slot, .live(line: 0, offset: offset + seamPrefixLength))
            }
        }
    }

    private func capturedAnchorAddresses(
        historyRows: Int
    ) -> [(WidthChangeAnchor, WidthChangeAddress)] {
        var captured: [(WidthChangeAnchor, WidthChangeAddress)] = []
        func capture(_ slot: WidthChangeAnchor, _ anchor: TextAnchor?) {
            guard let anchor, let address = widthChangeAddress(of: anchor, historyRows: historyRows)
            else { return }
            captured.append((slot, address))
        }
        capture(.selectionAnchorStart, selection?.anchorUnit.start)
        capture(.selectionAnchorEnd, selection?.anchorUnit.end)
        capture(.selectionFocus, selection?.focus)
        capture(.searchPosition, search?.position)
        capture(.hoverStart, hoveredLinkState?.range.start)
        capture(.hoverEnd, hoveredLinkState?.range.end)
        capture(.armStart, armedLinkState?.range.start)
        capture(.armEnd, armedLinkState?.range.end)
        if case let .browsing(top) = viewportState { capture(.browsingTop, top) }
        return captured
    }

    private func widthChangeAddress(
        of anchor: TextAnchor,
        historyRows: Int
    ) -> WidthChangeAddress? {
        let streamRow = anchor.row - evictedRowCount
        guard streamRow >= 0 else { return nil }
        if streamRow < historyRows {
            guard let address = history.store.address(
                ofDisplayRow: streamRow,
                column: anchor.column
            ) else { return nil }
            return .history(recordIndex: address.recordIndex, cellOffset: address.cellOffset)
        }
        let liveRow = min(streamRow - historyRows, screen.rows.count - 1)
        guard liveRow >= 0 else { return nil }
        return .live(
            line: liveReflowLine(ofRow: liveRow),
            offset: liveReflowOffset(inRow: liveRow, upTo: anchor.column)
        )
    }

    /// Writes the restated anchors back, dropping a range whose two ends did not both survive.
    ///
    /// The counterpart of `capturedAnchorAddresses`, and the only place a width change edits an
    /// anchor: `research/31/D3` Decision 2 keeps the stored coordinate an absolute display row, so
    /// eviction still needs no anchor edit at all and this loop is the whole restatement.
    private mutating func restateAnchors(
        _ captured: [(WidthChangeAnchor, WidthChangeAddress)],
        liveDestinations: [WidthChangeAnchor: TextAnchor],
        historyRowsAfter: Int
    ) {
        var restated: [WidthChangeAnchor: TextAnchor] = [:]
        for (slot, address) in captured {
            switch address {
            case let .history(recordIndex, cellOffset):
                if let position = history.store.position(
                    ofRecord: recordIndex,
                    cellOffset: cellOffset
                ) {
                    restated[slot] = TextAnchor(
                        row: evictedRowCount + position.displayRow,
                        column: position.column
                    )
                } else {
                    // The only unresolvable case is a cell the seam pull-back handed to the live
                    // grid (`research/31/D3` Decision 4); it is now the first live row's head.
                    restated[slot] = TextAnchor(
                        row: evictedRowCount + historyRowsAfter,
                        column: 0
                    )
                }
            case .live:
                restated[slot] = liveDestinations[slot]
            }
        }

        func restate(_ start: WidthChangeAnchor, _ end: WidthChangeAnchor) -> RestatedRange {
            guard restated.keys.contains(start) || restated.keys.contains(end) else {
                return .untouched
            }
            guard let first = restated[start], let last = restated[end] else { return .dropped }
            return .restated(TextAnchorRange(start: min(first, last), end: max(first, last)))
        }

        // Restated slot by slot rather than through `restate`, which orders the pair it
        // returns: the anchor and the focus are roles, and a gesture that ran backwards has
        // its origin at the newer end. Ordering them here would silently swap the pivot.
        let selectionSlots: [WidthChangeAnchor] = [
            .selectionAnchorStart, .selectionAnchorEnd, .selectionFocus,
        ]
        if selectionSlots.contains(where: restated.keys.contains) {
            if var current = selection,
               let anchorStart = restated[.selectionAnchorStart],
               let anchorEnd = restated[.selectionAnchorEnd],
               let focus = restated[.selectionFocus]
            {
                current.anchorUnit = TextAnchorRange(
                    start: min(anchorStart, anchorEnd),
                    end: max(anchorStart, anchorEnd)
                )
                current.focus = focus
                let collapsed = current.range.start == current.range.end
                selection = selectionRequiresNonemptyReflowResult && collapsed ? nil : current
            } else {
                selection = nil
            }
        }
        if let position = restated[.searchPosition] { search?.position = position }
        switch restate(.hoverStart, .hoverEnd) {
        case .untouched: break
        case let .restated(range): hoveredLinkState?.range = range
        case .dropped: hoveredLinkState = nil
        }
        switch restate(.armStart, .armEnd) {
        case .untouched: break
        case let .restated(range): armedLinkState?.range = range
        case .dropped: armedLinkState = nil
        }
        if let top = restated[.browsingTop] {
            viewportState = .browsing(top: TextAnchor(row: top.row, column: 0))
        }
    }

    /// Which logical line of the live refold a live row belongs to: the count of hard endings
    /// above it, which is the same walk `reconstructLogicalLines` performs.
    private func liveReflowLine(ofRow row: Int) -> Int {
        var line = 0
        for index in 0..<row where screen.rows[index].logicallyContinues == false {
            line += 1
        }
        return line
    }

    /// A live row's column expressed as a cell offset within its logical line, which is the key
    /// `pack`'s boundary destinations are built on.
    private func liveReflowOffset(inRow row: Int, upTo column: Int) -> Int {
        var offset = 0
        var start = row
        while start > 0, screen.rows[start - 1].logicallyContinues { start -= 1 }
        let projector = activeDisplayRows
        for index in start..<row {
            offset += logicalCellCount(
                in: projector.project(screen.rows[index], projector.facts(forGridRow: index)),
                upTo: columnCount
            )
        }
        return offset + logicalCellCount(
            in: projector.project(screen.rows[row], projector.facts(forGridRow: row)),
            upTo: column
        )
    }

    /// Counts the cells `reconstructLogicalLines` would emit for one row's leading columns.
    private func logicalCellCount(in row: GridRow, upTo column: Int) -> Int {
        let end = min(column, Self.foldBound(of: row, columns: columnCount))
        var count = 0
        var index = 0
        while index < end {
            switch row.cell(at: index).kind {
            case .wideHead:
                count += 2
                index += 2
            case .narrow, .padding:
                count += 1
                index += 1
            case .spacerHead, .wideTail:
                index += 1
            }
        }
        return count
    }

    /// Rebuilds the **live screen**'s logical lines from its rows, so `pack` can lay them out at
    /// the new width.
    ///
    /// History is no longer a source: it stores logical lines already, so there is nothing there
    /// to reconstruct and nothing to rebuild (`research/31/F6` `X1`). What history does contribute is
    /// `leadingRow` -- the sub-row remainder `setWidth` cut off its open tail so no short
    /// display row is left in the middle of a line that continues here (`research/31/D3` Decision 4).
    private func reconstructLogicalLines(
        from sourceRows: [GridRow],
        leadingRow: GridRow,
        leadingSemanticPrompt: SemanticPromptRow,
        trackedCursors: [TrackedCursor],
        liveCursor: TrackedCursor,
        oldColumnCount: Int
    ) -> (
        lines: [ReflowLine],
        attachments: [ReflowCursorAttachment]
    ) {
        var lines: [ReflowLine] = []
        var currentLine = ReflowLine()
        var metadata: [ReflowRowMetadata] = []
        var logicalOffset = 0
        // Tracked cursors parked on a spacer column whose wide head has not been reached yet. The
        // head can be on the next source row, so this outlives a row and is cleared with the line.
        var pendingSpacerCursors: [Int] = []
        // Where each tracked cursor's own cell landed in its line, as a logical offset. Nil for a
        // cursor the fold carries no cell for, which is then a boundary.
        var cursorCellOffsets = [Int?](repeating: nil, count: trackedCursors.count)

        // The seam remainder enters the first line as content with no source row of its own: it
        // came out of history, so no live cell maps to it and it anchors nothing.
        if leadingRow.cells.isEmpty == false {
            currentLine.semanticPrompt = leadingSemanticPrompt
            var index = 0
            while index < leadingRow.cells.count {
                let cell = leadingRow.cells[index]
                switch cell.kind {
                case .wideHead:
                    currentLine.units.append(ReflowUnit(
                        head: cell,
                        width: 2,
                        headScalars: leadingRow.scalars(of: cell)
                    ))
                    logicalOffset += 2
                    index += 2
                case .narrow, .padding:
                    currentLine.units.append(ReflowUnit(
                        head: cell,
                        width: 1,
                        headScalars: leadingRow.scalars(of: cell)
                    ))
                    logicalOffset += 1
                    index += 1
                case .wideTail, .spacerHead:
                    index += 1
                }
            }
        }

        for (rowIndex, row) in sourceRows.enumerated() {
            if currentLine.semanticPrompt == .none || row.semanticPrompt == .prompt {
                currentLine.semanticPrompt = row.semanticPrompt
            }
            // The live cursor keeps its distance from the content as cells: a hard-ended row
            // folds to its visible extent, extended by the blanks between that extent and the
            // cursor when the cursor sits past it (ghostty's `cols_len = max(cols_len, p.x + 1)`,
            // less the cursor's own cell). Those blanks carry the row's fill by the extent rule,
            // and the cursor is then the boundary after them -- the same anchor a pending wrap
            // uses, and DanTerm's one spelling of "after the last cell of a full row". Only the
            // live cursor extends a row: the saved slot is a passenger and never creates one.
            let visibleEnd = Self.foldBound(of: row, columns: oldColumnCount)
            var iterationEnd = visibleEnd
            if row.logicallyContinues == false, liveCursor.row == rowIndex {
                iterationEnd = max(iterationEnd, min(oldColumnCount, liveCursor.column))
            }
            // Almost every row carries no tracked cursor, and the two that do are known before
            // the walk. Reading that once per row keeps the per-cell cost of resolving them out
            // of every other row.
            let rowCarriesTrackedCursor = trackedCursors.contains { tracked in
                tracked.row == rowIndex && tracked.isPendingWrap == false
            }
            /// Whether tracked cursor `index` sits on this source row's `column`. A pending wrap
            /// is never on a cell: it is the boundary after one.
            func isTracked(_ index: Int, at column: Int) -> Bool {
                let tracked = trackedCursors[index]
                return tracked.row == rowIndex
                    && tracked.column == column
                    && tracked.isPendingWrap == false
            }
            var column = 0
            while column < iterationEnd {
                let cell = row.cell(at: column)
                switch cell.kind {
                case .spacerHead:
                    if rowCarriesTrackedCursor {
                        for index in trackedCursors.indices where isTracked(index, at: column) {
                            pendingSpacerCursors.append(index)
                        }
                    }
                    column += 1
                case .wideHead:
                    // A spacer belongs to the wide pair it made room for, so a cursor on one
                    // follows the head. So does a cursor on the pair's tail, one column further.
                    for index in pendingSpacerCursors {
                        cursorCellOffsets[index] = logicalOffset
                    }
                    pendingSpacerCursors.removeAll(keepingCapacity: true)
                    if rowCarriesTrackedCursor {
                        for index in trackedCursors.indices {
                            if isTracked(index, at: column) {
                                cursorCellOffsets[index] = logicalOffset
                            } else if column + 1 < oldColumnCount, isTracked(index, at: column + 1) {
                                cursorCellOffsets[index] = logicalOffset + 1
                            }
                        }
                    }
                    currentLine.units.append(ReflowUnit(
                        head: cell,
                        width: 2,
                        headScalars: row.scalars(of: cell)
                    ))
                    logicalOffset += 2
                    column += 2
                case .narrow, .padding:
                    if rowCarriesTrackedCursor {
                        for index in trackedCursors.indices where isTracked(index, at: column) {
                            cursorCellOffsets[index] = logicalOffset
                        }
                    }
                    currentLine.units.append(ReflowUnit(
                        head: cell,
                        width: 1,
                        headScalars: row.scalars(of: cell),
                        isCursorPadding: column >= visibleEnd
                    ))
                    logicalOffset += 1
                    column += 1
                case .wideTail:
                    column += 1
                }
            }

            metadata.append(ReflowRowMetadata(
                line: lines.count,
                boundaryOffset: logicalOffset
            ))
            if row.logicallyContinues == false {
                currentLine.fillStyle = row.visibleExtent(columns: oldColumnCount).fillStyle
                lines.append(currentLine)
                currentLine = ReflowLine()
                logicalOffset = 0
                pendingSpacerCursors.removeAll(keepingCapacity: true)
            }
        }
        if sourceRows.last?.logicallyContinues == true || sourceRows.isEmpty {
            lines.append(currentLine)
        }

        let attachments = trackedCursors.indices.map { index -> ReflowCursorAttachment in
            let tracked = trackedCursors[index]
            guard tracked.row < metadata.count else {
                return .belowContent(
                    rowsBelow: tracked.row - (metadata.count - 1),
                    column: tracked.column
                )
            }
            let rowMetadata = metadata[tracked.row]
            // A cursor on a cell the fold carries follows that cell. Any other cursor is at a
            // boundary after its row's units: a pending wrap, the live cursor just past the
            // blanks folded for it, or a saved slot past the fold bound, which lands at its
            // line's end because a hard-ended row's units are the last of its line.
            let anchor: ReflowCursorAnchor = cursorCellOffsets[index].map { .cell(offset: $0) }
                ?? .boundary(offset: rowMetadata.boundaryOffset)
            return .inLine(line: rowMetadata.line, anchor: anchor)
        }

        return (lines, attachments)
    }

    /// One past the last column the fold carries from a row: full width for a row that
    /// continues, its visible extent for one that ends. The live cursor may extend this for its
    /// own row (`reconstructLogicalLines`); anchors count by the bare rule.
    static func foldBound(of row: GridRow, columns: Int) -> Int {
        row.logicallyContinues ? columns : row.visibleExtent(columns: columns).contentEnd
    }

    /// Lays one logical line out at the new width, and answers the offsets the refold wants.
    ///
    /// `cellTargets` and `boundaryTargets` are logical offsets within the line; the returned
    /// destination arrays are positional answers to them. The walk is the authority on where a
    /// cell landed, so it records a destination as it passes a wanted offset rather than leaving
    /// a per-cell map behind for a caller to look up in.
    private func pack(
        line: ReflowLine,
        columns: Int,
        cellTargets: [Int],
        boundaryTargets: [Int]
    ) -> PackedReflowLine {
        // Every blank the pack synthesizes for the line is painted in its fill, so the last
        // row's tail and any row a widening leaves short show the paint the erase left.
        let blankRow = makeBlankRow(
            columns: columns,
            styleId: line.fillStyle ?? Terminal.defaultStyleId
        )
        var packedRows = [blankRow]
        packedRows[0].semanticPrompt = line.semanticPrompt
        var cellDestinations = [ReflowDestination?](repeating: nil, count: cellTargets.count)
        var boundaryDestinations = [ReflowDestination?](
            repeating: nil,
            count: boundaryTargets.count
        )
        for index in boundaryTargets.indices where boundaryTargets[index] == 0 {
            boundaryDestinations[index] = ReflowDestination(row: 0, column: 0, isPendingWrap: false)
        }
        var row = 0
        var column = 0
        var logicalOffset = 0

        // Rows past the first that hold nothing but the blanks folded for the cursor: they
        // exist for the cursor alone, and `resizeWidth` takes them out of its trailing-blank
        // budget so a parked cursor does not displace content into history.
        var cursorOnlyRowCount = 0
        var rowHoldsOnlyCursorPadding = false

        func openRow() {
            if row > 0, rowHoldsOnlyCursorPadding { cursorOnlyRowCount += 1 }
            packedRows[row].isSoftWrapped = true
            packedRows.append(blankRow)
            row += 1
            column = 0
            packedRows[row].semanticPrompt = Self.continuationMark(forLineHead: line.semanticPrompt)
            rowHoldsOnlyCursorPadding = true
        }

        for unit in line.units {
            if column == columns {
                openRow()
            }
            if unit.width == 2, columns - column == 1 {
                packedRows[row].cells[column] = GridCell(styleId: unit.head.styleId)
                openRow()
                packedRows[row - 1].marginProvenance = .wideWrap
            }
            if unit.isCursorPadding == false {
                rowHoldsOnlyCursorPadding = false
            }

            packedRows[row].place(unit.head, scalars: unit.headScalars, at: column)
            if unit.width == 2 {
                // The tail is a pure function of its head, so the fold never carried one.
                packedRows[row].place(
                    GridCell(
                        kind: .wideTail,
                        styleId: unit.head.styleId,
                        hyperlinkId: unit.head.hyperlinkId,
                        contentIdentity: unit.head.contentIdentity
                    ),
                    scalars: .empty,
                    at: column + 1
                )
            }
            for index in cellTargets.indices {
                let offset = cellTargets[index] - logicalOffset
                guard offset >= 0, offset < unit.width else { continue }
                cellDestinations[index] = ReflowDestination(
                    row: row,
                    column: column + offset,
                    isPendingWrap: false
                )
            }
            column += unit.width
            logicalOffset += unit.width
            for index in boundaryTargets.indices where boundaryTargets[index] == logicalOffset {
                boundaryDestinations[index] = column == columns
                    ? ReflowDestination(row: row, column: columns - 1, isPendingWrap: true)
                    : ReflowDestination(row: row, column: column, isPendingWrap: false)
            }
        }
        if row > 0, rowHoldsOnlyCursorPadding { cursorOnlyRowCount += 1 }

        return PackedReflowLine(
            rows: packedRows,
            cellDestinations: cellDestinations,
            boundaryDestinations: boundaryDestinations,
            contentEnd: ReflowDestination(
                row: row,
                column: column,
                isPendingWrap: false
            ),
            cursorOnlyRowCount: cursorOnlyRowCount
        )
    }

    static func retainedContentEnd(in row: GridRow) -> Int {
        guard let lastContent = row.cells.lastIndex(where: { cell in
            cell.kind == .narrow || cell.kind == .wideHead
        }) else {
            return 0
        }
        return min(
            row.cells.count,
            lastContent + (row.cells[lastContent].kind == .wideHead ? 2 : 1)
        )
    }

    private func makeBlankRow(
        columns: Int,
        styleId: StyleId = Terminal.defaultStyleId
    ) -> GridRow {
        GridRow(cells: (0..<columns).map { _ in GridCell(styleId: styleId) })
    }

    private mutating func dispatchCSI(_ sequence: CSISequence) {
        switch sequence.intermediates.key {
        case 0x21:
            guard sequence.final == 0x70, sequence.parameters.isNone else { return }
            softReset()
            return
        case 0x3F:
            switch sequence.final {
            case 0x68:
                applyDECPrivateModes(sequence.parameters, enabled: true)
            case 0x6C:
                applyDECPrivateModes(sequence.parameters, enabled: false)
            case 0x6E:
                guard let request = sequence.parameters.exactlyOne() else { return }
                replyToStatusQuery(request, isDECPrivate: true)
            case 0x75:
                guard sequence.parameters.isNone else { return }
                let reported = (screen.control.kittyKeyboardStack.last ?? []).rawValue
                appendReply("\u{1B}[?\(reported)u")
            case 0x4A:
                // DECSED. Same arity and mode guards as ED so the two forms coincide
                // wherever nothing is protected, including on a malformed parameter.
                guard let mode = sequence.parameters.single(default: 0) else { return }
                eraseDisplay(mode: mode, selective: true)
            case 0x4B:
                // DECSEL, guarded like EL for the same reason.
                guard let mode = sequence.parameters.single(default: 0), mode <= 2 else { return }
                _ = eraseLine(mode: mode, selective: true)
            default:
                break
            }
            return
        case 0x3E:
            if sequence.final == 0x71, sequence.parameters.isNoneOrZero {
                // No identity means no product to name, so the terminal declines to
                // answer rather than inventing one.
                if let productIdentity {
                    appendReply(
                        "\u{1B}P>|\(productIdentity.name) \(productIdentity.version)\u{1B}\\"
                    )
                }
                return
            }
            guard sequence.final == 0x75, let flags = sequence.parameters.single(default: 0)
            else { return }
            pushKittyKeyboardFlags(.init(reported: flags))
            return
        case 0x3C:
            guard sequence.final == 0x75, let depth = sequence.parameters.single(default: 1)
            else { return }
            popKittyKeyboardFlags(depth)
            return
        case 0x3D:
            guard sequence.final == 0x75, let (flags, mode) = sequence.parameters.pair(defaults: (0, 1))
            else { return }
            setKittyKeyboardFlags(.init(reported: flags), mode: mode)
            return
        case 0x243F:
            guard sequence.final == 0x70, let rawMode = sequence.parameters.exactlyOne() else { return }
            replyToModeQuery(rawMode, isDECPrivate: true)
            return
        case 0x24:
            guard sequence.final == 0x70, let rawMode = sequence.parameters.exactlyOne() else { return }
            replyToModeQuery(rawMode, isDECPrivate: false)
            return
        case 0x20:
            guard sequence.final == 0x71, let style = sequence.parameters.single(default: 0)
            else { return }
            applyCursorStyle(style)
            return
        case 0x22:
            guard sequence.final == 0x71, let protection = sequence.parameters.single(default: 0)
            else { return }
            applyCharacterProtection(protection)
            return
        case 0:
            break
        default:
            return
        }

        switch sequence.final {
        case 0x63:
            guard sequence.parameters.isNoneOrZero else { return }
            replyToPrimaryDeviceAttributesQuery()
        case 0x6E:
            guard let request = sequence.parameters.exactlyOne() else { return }
            replyToStatusQuery(request, isDECPrivate: false)
        case 0x41, 0x6B:
            guard let amount = movementAmount(sequence.parameters) else { return }
            moveRelativeVerticalCursor(by: -amount, column: screen.cursor.column)
        case 0x42, 0x65:
            guard let amount = movementAmount(sequence.parameters) else { return }
            moveRelativeVerticalCursor(by: amount, column: screen.cursor.column)
        case 0x43, 0x61:
            guard let amount = movementAmount(sequence.parameters) else { return }
            movePositionedCursor(row: screen.cursor.row, column: screen.cursor.column + amount)
        case 0x44, 0x6A:
            guard let amount = movementAmount(sequence.parameters) else { return }
            movePositionedCursor(row: screen.cursor.row, column: screen.cursor.column - amount)
        case 0x45:
            guard let amount = movementAmount(sequence.parameters) else { return }
            moveRelativeVerticalCursor(by: amount, column: 0)
        case 0x46:
            guard let amount = movementAmount(sequence.parameters) else { return }
            moveRelativeVerticalCursor(by: -amount, column: 0)
        case 0x47, 0x60:
            guard let column = sequence.parameters.single(default: 1) else { return }
            movePositionedCursor(row: screen.cursor.row, column: absolutePosition(column))
        case 0x64:
            guard let row = sequence.parameters.single(default: 1) else { return }
            movePositionedCursor(
                row: positioningOriginRow + absolutePosition(row),
                column: screen.cursor.column
            )
        case 0x48, 0x66:
            guard let (row, column) = sequence.parameters.pair(defaults: (1, 1)) else { return }
            movePositionedCursor(
                row: positioningOriginRow + absolutePosition(row),
                column: absolutePosition(column)
            )
        case 0x49:
            guard let amount = movementAmount(sequence.parameters) else { return }
            moveCursorAcrossTabStops(amount: amount, forward: true)
        case 0x5A:
            guard let amount = movementAmount(sequence.parameters) else { return }
            moveCursorAcrossTabStops(amount: amount, forward: false)
        case 0x4A:
            guard let mode = sequence.parameters.single(default: 0) else { return }
            eraseDisplay(mode: mode)
        case 0x4B:
            guard let mode = sequence.parameters.single(default: 0), mode <= 2 else { return }
            _ = eraseLine(mode: mode)
        case 0x58:
            guard let amount = movementAmount(sequence.parameters) else { return }
            eraseCharacters(amount: amount)
        case 0x40:
            guard let amount = movementAmount(sequence.parameters) else { return }
            insertCharacters(amount: amount)
        case 0x50:
            guard let amount = movementAmount(sequence.parameters) else { return }
            deleteCharacters(amount: amount)
        case 0x4C:
            guard let amount = movementAmount(sequence.parameters) else { return }
            insertLines(amount: amount)
        case 0x4D:
            guard let amount = movementAmount(sequence.parameters) else { return }
            deleteLines(amount: amount)
        case 0x53:
            guard let amount = movementAmount(sequence.parameters) else { return }
            scrollUp(amount: amount)
        case 0x54:
            guard let amount = movementAmount(sequence.parameters) else { return }
            scrollDown(amount: amount)
        case 0x6D:
            applySGR(sequence)
        case 0x72:
            guard let (top, bottom) = sequence.parameters.pair(defaults: (1, 0)) else { return }
            setScrollRegion(top: top, bottom: bottom)
        case 0x67:
            guard let selector = sequence.parameters.single(default: 0) else { return }
            clearTabStop(selector)
        case 0x73:
            guard sequence.parameters.isNone else { return }
            saveCursor()
        case 0x75:
            guard sequence.parameters.isNone else { return }
            restoreCursor()
        case 0x62:
            guard let amount = movementAmount(sequence.parameters) else { return }
            repeatLastPrintedCluster(count: amount)
        case 0x68:
            applyANSIModes(sequence.parameters, enabled: true)
        case 0x6C:
            applyANSIModes(sequence.parameters, enabled: false)
        default:
            break
        }
    }

    private mutating func replyToStatusQuery(_ request: UInt16, isDECPrivate: Bool) {
        switch request {
        case 5:
            appendReply(isDECPrivate ? "\u{1B}[?0n" : "\u{1B}[0n")
        case 6:
            let row = modes.isOriginMode ? screen.cursor.row - positioningOriginRow + 1 : screen.cursor.row + 1
            let prefix = isDECPrivate ? "?" : ""
            appendReply("\u{1B}[\(prefix)\(row);\(screen.cursor.column + 1)R")
        default:
            break
        }
    }

    private mutating func replyToPrimaryDeviceAttributesQuery() {
        appendReply("\u{1B}[?1;2c")
    }

    private mutating func replyToModeQuery(_ rawMode: UInt16, isDECPrivate: Bool) {
        let status = isDECPrivate ? decPrivateModeStatus(rawMode) : ansiModeStatus(rawMode)
        let prefix = isDECPrivate ? "?" : ""
        appendReply("\u{1B}[\(prefix)\(rawMode);\(status)$y")
    }

    private func decPrivateModeStatus(_ rawMode: UInt16) -> Int {
        guard let mode = DECPrivateMode(rawValue: rawMode) else { return 0 }
        return switch mode.policy.state {
        case .stored(let keyPath): modes[keyPath: keyPath] ? 1 : 2
        case .mouseTracking(let tracking): modes.mouseTrackingMode == tracking ? 1 : 2
        case .screenSwitch: isAlternateScreenActive ? 1 : 2
        case .cursorSlot: 0
        case .fixedStatus(let status): status
        }
    }

    private func ansiModeStatus(_ rawMode: UInt16) -> Int {
        guard let mode = ANSIMode(rawValue: rawMode) else { return 0 }
        return switch mode {
        case .insert: modes.isInsertMode ? 1 : 2
        case .lineFeedNewLine: modes.isLineFeedNewLineMode ? 1 : 2
        }
    }

    private mutating func appendReply(_ reply: String) {
        let bytes = Array(reply.utf8)
        guard replyBytes.count + bytes.count <= Self.maximumReplyBytes else { return }
        replyBytes.append(contentsOf: bytes)
    }

    private mutating func applyANSIModes(_ parameters: CSIParameters, enabled: Bool) {
        for rawMode in parameters {
            guard let mode = ANSIMode(rawValue: rawMode) else { continue }
            switch mode {
            case .insert: modes.isInsertMode = enabled
            case .lineFeedNewLine: modes.isLineFeedNewLineMode = enabled
            }
        }
    }

    private mutating func applyDECPrivateModes(_ parameters: CSIParameters, enabled: Bool) {
        var shouldClearPendingMotion = false
        for rawMode in parameters {
            guard let mode = DECPrivateMode(rawValue: rawMode) else { continue }
            let policy = mode.policy
            switch policy.state {
            case .stored(let keyPath):
                modes[keyPath: keyPath] = enabled
            case .mouseTracking(let tracking):
                modes.mouseTrackingMode = enabled ? tracking : .off
            case .cursorSlot:
                if shouldClearPendingMotion {
                    clearPendingMotionState()
                    shouldClearPendingMotion = false
                }
                if enabled {
                    saveCursor()
                } else {
                    restoreCursor()
                }
            case .screenSwitch(let answers):
                if shouldClearPendingMotion {
                    clearPendingMotionState()
                    shouldClearPendingMotion = false
                }
                if enabled {
                    if answers.savesCursor { saveCursor() }
                    switchAlternateScreen(answers, enabled: true)
                } else {
                    switchAlternateScreen(answers, enabled: false)
                    if answers.savesCursor { restoreCursor() }
                }
            case .fixedStatus:
                break
            }
            switch policy.setEffect {
            case .none:
                break
            case .homeCursor:
                screen.cursor = CellPosition(row: positioningOriginRow, column: 0)
                shouldClearPendingMotion = true
            case .reportFocus:
                if enabled { appendReply(Self.focusReport(isFocused)) }
            }
        }
        if shouldClearPendingMotion {
            clearPendingMotionState()
        }
    }

    private mutating func applyCursorStyle(_ parameter: UInt16) {
        switch parameter {
        case 0, 1:
            modes.cursorShape = .block
            modes.isCursorBlinking = true
        case 2:
            modes.cursorShape = .block
            modes.isCursorBlinking = false
        case 3:
            modes.cursorShape = .underline
            modes.isCursorBlinking = true
        case 4:
            modes.cursorShape = .underline
            modes.isCursorBlinking = false
        case 5:
            modes.cursorShape = .bar
            modes.isCursorBlinking = true
        case 6:
            modes.cursorShape = .bar
            modes.isCursorBlinking = false
        default:
            break
        }
    }

    /// DECSCA: arms or disarms the pen's protection for the selective erases.
    ///
    /// `Ps` 0 and 2 both disarm, which is what the VT420 manual and xterm do; anything else
    /// outside 0...2 leaves the pen alone rather than guessing.
    private mutating func applyCharacterProtection(_ parameter: UInt16) {
        switch parameter {
        case 0, 2:
            currentStyle.protected = false
        case 1:
            currentStyle.protected = true
        default:
            break
        }
    }

    /// SGR 0: clears every rendition attribute while leaving DECSCA protection armed.
    ///
    /// Protection lives on the pen for storage reasons only. It is not a rendition, and DEC gives
    /// SGR no way to clear it, so `CSI 0 m` must not act as a hidden `CSI 0 " q`.
    private mutating func resetRendition() {
        currentStyle = TerminalStyle(protected: currentStyle.protected)
    }

    /// Identifies the style field selected by an SGR extended-color parameter.
    private enum SGRExtendedColorTarget {
        case foreground
        case background
        case underline

        init?(_ parameter: UInt16) {
            switch parameter {
            case 38:
                self = .foreground
            case 48:
                self = .background
            case 58:
                self = .underline
            default:
                return nil
            }
        }
    }

    /// Keeps the two supported extended-color grammars explicit in the shared decoder.
    private enum SGRExtendedColorSyntax {
        case colon
        case semicolon
    }

    private mutating func applySGR(_ sequence: CSISequence) {
        guard sequence.parameters.isEmpty == false else {
            resetRendition()
            return
        }

        var index = 0
        while index < sequence.parameters.count {
            var groupEnd = index + 1
            while groupEnd < sequence.parameters.count,
                  sequence.colonSeparators[groupEnd - 1]
            {
                groupEnd += 1
            }

            if groupEnd > index + 1 {
                applyColonSGR(sequence.parameters, range: index..<groupEnd)
                index = groupEnd
                continue
            }

            let parameter = sequence.parameters[index]
            if let target = SGRExtendedColorTarget(parameter) {
                let result = extendedColor(
                    in: sequence.parameters,
                    selectorIndex: index + 1,
                    endIndex: sequence.parameters.endIndex,
                    syntax: .semicolon
                )
                if let color = result.color {
                    apply(color, to: target)
                }
                index = result.nextIndex
            } else {
                applySimpleSGR(parameter)
                index += 1
            }
        }
    }

    private mutating func applyColonSGR(
        _ parameters: CSIParameters,
        range: Range<CSIParameters.Index>
    ) {
        guard let leadingIndex = range.first else { return }
        let leading = parameters[leadingIndex]

        if let target = SGRExtendedColorTarget(leading) {
            let result = extendedColor(
                in: parameters,
                selectorIndex: leadingIndex + 1,
                endIndex: range.upperBound,
                syntax: .colon
            )
            if let color = result.color {
                apply(color, to: target)
            }
            return
        }

        switch leading {
        case 4:
            switch range.count > 1 ? parameters[leadingIndex + 1] : nil {
            case 0:
                currentStyle.underline = .none
            case 2:
                currentStyle.underline = .double
            case 3:
                currentStyle.underline = .curly
            case 4:
                currentStyle.underline = .dotted
            case 5:
                currentStyle.underline = .dashed
            default:
                currentStyle.underline = .single
            }
        default:
            applySimpleSGR(leading)
        }
    }

    private mutating func applySimpleSGR(_ parameter: UInt16) {
        switch parameter {
        case 0:
            resetRendition()
        case 1:
            currentStyle.bold = true
        case 2:
            currentStyle.dim = true
        case 3:
            currentStyle.italic = true
        case 4:
            currentStyle.underline = .single
        case 7:
            currentStyle.reverse = true
        case 8:
            currentStyle.hidden = true
        case 9:
            currentStyle.strikethrough = true
        case 21:
            currentStyle.underline = .double
        case 22:
            currentStyle.bold = false
            currentStyle.dim = false
        case 23:
            currentStyle.italic = false
        case 24:
            currentStyle.underline = .none
        case 27:
            currentStyle.reverse = false
        case 28:
            currentStyle.hidden = false
        case 29:
            currentStyle.strikethrough = false
        case 30...37:
            currentStyle.foreground = .indexed(UInt8(parameter - 30))
        case 39:
            currentStyle.foreground = .default
        case 40...47:
            currentStyle.background = .indexed(UInt8(parameter - 40))
        case 49:
            currentStyle.background = .default
        case 59:
            currentStyle.underlineColor = .default
        case 90...97:
            currentStyle.foreground = .indexed(UInt8(parameter - 90 + 8))
        case 100...107:
            currentStyle.background = .indexed(UInt8(parameter - 100 + 8))
        default:
            break
        }
    }

    private func extendedColor(
        in parameters: CSIParameters,
        selectorIndex: Int,
        endIndex: Int,
        syntax: SGRExtendedColorSyntax
    ) -> (color: TerminalColor?, nextIndex: Int) {
        guard selectorIndex < endIndex else {
            return (nil, endIndex)
        }

        switch parameters[selectorIndex] {
        case 5:
            let nextIndex = syntax == .colon
                ? endIndex
                : min(endIndex, selectorIndex + 2)
            guard selectorIndex + 1 < endIndex else {
                return (nil, nextIndex)
            }
            return (
                .indexed(UInt8(truncatingIfNeeded: parameters[selectorIndex + 1])),
                nextIndex
            )
        case 2:
            let nextIndex = syntax == .colon
                ? endIndex
                : min(endIndex, selectorIndex + 4)
            let componentIndex = syntax == .colon && endIndex - selectorIndex >= 5
                ? selectorIndex + 2
                : selectorIndex + 1
            guard componentIndex + 2 < endIndex else {
                return (nil, nextIndex)
            }
            return (
                .rgb(
                    red: UInt8(truncatingIfNeeded: parameters[componentIndex]),
                    green: UInt8(truncatingIfNeeded: parameters[componentIndex + 1]),
                    blue: UInt8(truncatingIfNeeded: parameters[componentIndex + 2])
                ),
                nextIndex
            )
        default:
            return (nil, syntax == .colon ? endIndex : selectorIndex + 1)
        }
    }

    private mutating func apply(_ color: TerminalColor, to target: SGRExtendedColorTarget) {
        switch target {
        case .foreground:
            currentStyle.foreground = color
        case .background:
            currentStyle.background = color
        case .underline:
            currentStyle.underlineColor = color
        }
    }

    /// CSI K. Every EL mode is a rewrite-in-place operation and keeps any incoming history
    /// claim. Only EL 0 resets the row's own outgoing soft wrap: erasing the right end destroys
    /// the wrap point itself, while EL 1/2 blank cells without restructuring the line.
    /// Matches xterm (`util.c#ClearRight` is the only clear that drops the flag),
    /// Ghostty, kitty, and foot; tmux severs on EL 2 and is the lone outlier.
    /// Pinned by CSIEraseTests#eraseLineWrapAsymmetry. What keeps the surviving
    /// claim harmless is `eraseCells` recording the blanked margin
    /// (`GridRow.marginProvenance`): the line-structure readers decline the claim
    /// until a print reaches the margin again, so the parity state cannot fuse
    /// separately printed lines (TerminalStaleWrapClaimTests).
    ///
    /// `selective` is the `?` on DECSEL. EL 0's soft-wrap reset is unconditional either way:
    /// the wrap point is the margin column itself, and a protected cell standing there is text
    /// the program means to keep, not a claim that the line continues.
    private mutating func eraseLine(mode: UInt16, selective: Bool = false) -> Bool {
        let eraseResult: EraseResult
        switch mode {
        case 0:
            eraseResult = eraseCells(
                row: screen.cursor.row,
                columns: screen.cursor.column..<columnCount,
                selective: selective
            )
            screen.rows[screen.cursor.row].isSoftWrapped = false
        case 1:
            eraseResult = eraseCells(
                row: screen.cursor.row,
                columns: 0..<(screen.cursor.column + 1),
                selective: selective
            )
        case 2:
            eraseResult = eraseCells(
                row: screen.cursor.row,
                columns: 0..<columnCount,
                selective: selective
            )
        default:
            return false
        }
        clearPendingMotionState()
        return eraseResult.coveredWholeRow && eraseResult.blankedAllCells
    }

    /// `selective` is the `?` on DECSED. Mode 3 clears history whether or not it is selective:
    /// protection is a property of live cells, and xterm names the sequence "Selective Erase
    /// Saved Lines" for the same region ED 3 clears.
    private mutating func eraseDisplay(mode: UInt16, selective: Bool = false) {
        var blankedRowZero = false
        switch mode {
        case 0:
            let blankedCursorRow = eraseLine(mode: 0, selective: selective)
            blankedRowZero = screen.cursor.row == 0 && blankedCursorRow
            if screen.cursor.row + 1 < rowCount {
                for row in (screen.cursor.row + 1)..<rowCount {
                    _ = eraseEntireRow(row, selective: selective)
                }
            }
        case 1:
            if screen.cursor.row > 0 {
                for row in 0..<screen.cursor.row {
                    let blankedRow = eraseEntireRow(row, selective: selective)
                    if row == 0 {
                        blankedRowZero = blankedRow
                    }
                }
            }
            let blankedCursorRow = eraseLine(mode: 1, selective: selective)
            if screen.cursor.row == 0 {
                blankedRowZero = blankedCursorRow
            }
        case 2:
            for row in screen.rows.indices {
                let blankedRow = eraseEntireRow(row, selective: selective)
                if row == 0 {
                    blankedRowZero = blankedRow
                }
            }
            clearPendingMotionState()
        case 3:
            mutateHistory { $0.removeAll() }
            syncHistoryEvictions()
        default:
            return
        }
        if blankedRowZero {
            severHistoryWrapClaimForRowZeroErase()
        }
    }

    private mutating func eraseCharacters(amount: Int) {
        let upper = min(screen.cursor.column + amount, columnCount)
        eraseCells(row: screen.cursor.row, columns: screen.cursor.column..<upper)
        screen.rows[screen.cursor.row].isSoftWrapped = false
        clearPendingMotionState()
    }

    /// Ends history's open logical line after a display erase blanks all of live row 0.
    ///
    /// The open tail record's bit is history's claim that its last retained row continues into
    /// live row 0; the erase clears only live rows' own outgoing flags, so nothing else can
    /// close it. Left open across such an erase it asserts a continuation whose cells are gone,
    /// and both readers act on it: `admit` appends the next scrolled-off row into the pre-clear
    /// record, and a later width change pulls the record's partial row back onto the cleared
    /// screen (`research/31/D2` operation 2, amended 2026-08-05). Display erase owns this
    /// history-seam rule because it changes display structure; EL, DECSEL, and ECH are
    /// rewrite-in-place operations and keep the predecessor's claim even when they blank the
    /// row. A display erase with a surviving cell also keeps the claim. The funnel is a no-op
    /// on the alternate screen.
    private mutating func severHistoryWrapClaimForRowZeroErase() {
        severWrapClaim(before: 0)
    }

    /// A row that keeps a protected cell was not cleared, so its line structure still stands.
    private mutating func eraseEntireRow(_ row: Int, selective: Bool = false) -> Bool {
        let result = eraseCells(row: row, columns: 0..<columnCount, selective: selective)
        guard result.blankedAllCells else { return false }
        screen.rows[row].isSoftWrapped = false
        screen.rows[row].semanticPrompt = .none
        return result.coveredWholeRow
    }

    /// A count parameter: at most one, absent and zero both meaning one.
    private func movementAmount(_ parameters: CSIParameters) -> Int? {
        parameters.single(default: 1).map { max(Int($0), 1) }
    }

    /// A one-based position parameter as a zero-based index, zero meaning the first.
    private func absolutePosition(_ parameter: UInt16) -> Int {
        max(Int(parameter), 1) - 1
    }

    private var positioningRowRange: Range<Int> {
        modes.isOriginMode ? activeScrollRegion : 0..<rowCount
    }

    private var positioningOriginRow: Int {
        positioningRowRange.lowerBound
    }

    private mutating func movePositionedCursor(row: Int, column: Int) {
        let rowRange = positioningRowRange
        screen.cursor.row = min(max(row, rowRange.lowerBound), rowRange.upperBound - 1)
        screen.cursor.column = min(max(column, 0), columnCount - 1)
        clearPendingMotionState()
    }

    private mutating func moveRelativeVerticalCursor(by delta: Int, column: Int) {
        let row = screen.cursor.row
        let region = activeScrollRegion
        let lowerBound = delta < 0 && row >= region.lowerBound ? region.lowerBound : 0
        let upperBound = delta > 0 && row < region.upperBound ? region.upperBound : rowCount
        screen.cursor.row = min(max(row + delta, lowerBound), upperBound - 1)
        screen.cursor.column = min(max(column, 0), columnCount - 1)
        clearPendingMotionState()
    }

    private mutating func moveCursorAcrossTabStops(amount: Int, forward: Bool) {
        let column: Int?
        if forward {
            column = tabStops[members: (screen.cursor.column + 1)...]
                .dropFirst(amount - 1)
                .first
        } else {
            column = tabStops[members: ..<screen.cursor.column]
                .dropLast(amount - 1)
                .last
        }
        moveToTabStop(column: column ?? (forward ? columnCount - 1 : 0))
    }

    /// Sets the column for HT, CHT and CBT, which spend pending motion state only by moving.
    ///
    /// Tab-stop motion is the one cursor mover that does not clear the deferred-wrap latch
    /// outright. The latch is armed only while the cursor sits at the right margin, so a tab
    /// that cannot leave that column has changed nothing and must leave the latch to the next
    /// glyph -- xterm (`tabs.c#TabToNextStop` -> the bare `set_cur_col`), ghostty
    /// (`Terminal.zig#horizontalTab` -> `Screen.zig#cursorRight`), foot (`vt.c`, which saves and
    /// restores `lcf` by hand) and libvterm (`state.c#updatecursor`, which returns before
    /// cancelling the phantom when the position is unchanged) all agree. A tab that does move
    /// leaves the column the latch described, and `printCluster` consumes the latch without
    /// re-checking the column, so carrying it would wrap a glyph typed mid-row.
    private mutating func moveToTabStop(column: Int) {
        let previousColumn = screen.cursor.column
        screen.cursor.column = min(max(column, 0), columnCount - 1)
        if screen.cursor.column != previousColumn {
            clearPendingMotionState()
        }
    }

    private mutating func dispatchEscape(_ final: UInt8) {
        switch final {
        case 0x3D:
            modes.isApplicationKeypadMode = true
        case 0x3E:
            modes.isApplicationKeypadMode = false
        case 0x37:
            saveCursor()
        case 0x38:
            restoreCursor()
        case 0x44:
            clearPendingMotionState()
            lineFeed()
        case 0x45:
            clearPendingMotionState()
            lineFeed()
            screen.cursor.column = 0
        case 0x4D:
            clearPendingMotionState()
            reverseIndex()
        case 0x48:
            tabStops.insert(screen.cursor.column)
        case 0x63:
            hardReset()
        case 0x6E:
            charsets.invokedSlot = .g2
        case 0x6F:
            charsets.invokedSlot = .g3
        case 0x4E:
            charsets.pendingSingleShift = .g2
        case 0x4F:
            charsets.pendingSingleShift = .g3
        case 0x5A:
            replyToPrimaryDeviceAttributesQuery()
        default:
            break
        }
    }

    private mutating func dispatchEscape(_ sequence: EscapeSequence) {
        if let first = sequence.intermediates.first,
           let slot = TerminalCharsetSlot(designationIntermediate: first) {
            designateCharset(into: slot, sequence)
            return
        }
        guard sequence.intermediates.key == 0x23, sequence.final == 0x38 else { return }
        invalidateInspection(inViewportRows: screen.rows.indices)
        // DECALN replaces every row, row 0 included, so history's claim on it must end first.
        severHistoryWrapClaimForRowZeroErase()
        // DEC STD 070 makes DECALN a known-state reset and then a fill, which is what a program
        // uses it for: origin mode off, no scroll region, and the pen reduced to its colours, so
        // the absolute CUP that follows lands on its literal row and later output is not still
        // bold or reversed. The reset stays narrower than RIS -- the saved cursor, the tab stops,
        // the charsets, and the hyperlink pen all survive.
        modes.isOriginMode = false
        scrollRegion = nil
        // The fill and the pen carry protection differently, so they are derived apart: the `E`s
        // are ordinary unprotected characters, while DECSCA survives the pen reduction the same
        // way it survives SGR 0.
        let styleId = backgroundEraseStyleId()
        let wasProtected = currentStyle.protected
        currentStyle = backgroundEraseStyle
        currentStyle.protected = wasProtected
        for row in screen.rows.indices {
            screen.rows[row] = GridRow(cells: (0..<columnCount).map { _ in
                GridCell(scalars: .single("E"), kind: .narrow, styleId: styleId)
            })
        }
        moveCursor(row: 0, column: 0)
    }

    /// Designates one character set into a slot, degrading anything unsupported to ASCII.
    ///
    /// A slot left holding its previous set after an unrecognized designation would translate
    /// later output the program never asked to translate, and no report exists for a program
    /// to notice. So an unknown final -- and any longer form such as `ESC ( % 5` -- designates
    /// ASCII, which is deterministic plain text rather than history-dependent line drawing.
    /// Designation consumes no cell, so it must not touch pending wrap or the open cluster:
    /// `sgr0=\E(B\E[m` puts one in every attribute reset.
    private mutating func designateCharset(
        into slot: TerminalCharsetSlot,
        _ sequence: EscapeSequence
    ) {
        guard sequence.intermediates.count == 1,
              let charset = TerminalCharset(designationFinal: sequence.final)
        else {
            charsets[slot] = .ascii
            return
        }
        charsets[slot] = charset
    }

    private mutating func execute(_ control: UInt8) {
        switch control {
        case 0x08:
            screen.cursor.column = max(0, screen.cursor.column - 1)
            clearPendingMotionState()
        case 0x09:
            moveToTabStop(
                column: tabStops[members: (screen.cursor.column + 1)...].first ?? columnCount - 1
            )
        case 0x0A, 0x0B, 0x0C:
            clearPendingMotionState()
            lineFeed()
            if modes.isLineFeedNewLineMode {
                screen.cursor.column = 0
            }
        case 0x0D:
            screen.cursor.column = 0
            clearPendingMotionState()
        case 0x0E:
            charsets.invokedSlot = .g1
        case 0x0F:
            charsets.invokedSlot = .g0
        default:
            break
        }
    }

    private mutating func clearPendingMotionState() {
        screen.isPendingWrap = false
        clusterContext = nil
    }

    private static func defaultTabStops(columns: Int) -> BitSet {
        BitSet(stride(from: 0, to: columns, by: 8))
    }

    private mutating func resizeTabStops(from oldColumnCount: Int, to newColumnCount: Int) {
        tabStops.formIntersection(0..<newColumnCount)
        guard newColumnCount > oldColumnCount else { return }
        for column in oldColumnCount..<newColumnCount where column.isMultiple(of: 8) {
            tabStops.insert(column)
        }
    }

    private mutating func clearTabStop(_ selector: UInt16) {
        switch selector {
        case 0:
            tabStops.remove(screen.cursor.column)
        case 3:
            tabStops = []
        default:
            return
        }
    }

    private mutating func saveCursor() {
        screen.control.savedCursor = SavedCursorState(
            position: screen.cursor,
            style: currentStyle,
            isPendingWrap: screen.isPendingWrap,
            isOriginMode: modes.isOriginMode,
            isCursorVisible: modes.isCursorVisible,
            cursorShape: modes.cursorShape,
            isCursorBlinking: modes.isCursorBlinking,
            charsets: charsets
        )
    }

    private mutating func restoreCursor() {
        modes.isOriginMode = screen.control.savedCursor.isOriginMode
        let rowRange = positioningRowRange
        screen.cursor = CellPosition(
            row: min(max(screen.control.savedCursor.position.row, rowRange.lowerBound), rowRange.upperBound - 1),
            column: min(max(screen.control.savedCursor.position.column, 0), columnCount - 1)
        )
        if screen.control.savedCursor.isPendingWrap == false || screen.cursor.column != columnCount - 1 {
            movePositionOffWideTail(&screen.cursor, in: screen.rows)
        }
        currentStyle = screen.control.savedCursor.style
        modes.isCursorVisible = screen.control.savedCursor.isCursorVisible
        modes.cursorShape = screen.control.savedCursor.cursorShape
        modes.isCursorBlinking = screen.control.savedCursor.isCursorBlinking
        charsets = screen.control.savedCursor.charsets
        clusterContext = nil
        screen.isPendingWrap = screen.control.savedCursor.isPendingWrap
            && screen.cursor.column == columnCount - 1
    }

    private mutating func switchAlternateScreen(
        _ answers: ScreenSwitch,
        enabled: Bool
    ) {
        recordFullDamage()
        if enabled {
            clearInspection()
            if isAlternateScreenActive == false {
                swapActiveScreen()
            }
            if answers.clearsOnEntry { clearLiveScreen() }
        } else if isAlternateScreenActive {
            clearInspection()
            // Strictly before the swap: the mode's exit clear blanks the alternate it is
            // leaving, not the primary it is going back to.
            if answers.clearsOnExit { clearLiveScreen() }
            swapActiveScreen()
        }
        clearPendingMotionState()
    }

    /// Blanks the live grid for a screen switch that says it clears.
    ///
    /// The semantic-content reset belongs to the clear rather than to the switch: a mode that
    /// clears nothing leaves the grid it arrives on exactly as its last occupant left it.
    private mutating func clearLiveScreen() {
        screen.rows = Deque((0..<rowCount).map { _ in
            makeBlankRow(columns: columnCount, styleId: backgroundEraseStyleId())
        })
        screen.semanticContent = .output
        screen.semanticContentClearsAtEndOfLine = false
    }

    private mutating func selectPrimaryScreen() {
        guard isAlternateScreenActive else { return }
        recordFullDamage()
        clearInspection()
        swapActiveScreen()
    }

    /// Symmetrically exchanges the live and inactive screen while carrying the live cursor.
    private mutating func swapActiveScreen() {
        let carriedCursor = screen.cursor
        var ownership = ScreenOwnership.primaryLive(alternate: nil)
        swap(&ownership, &screenOwnership)
        switch ownership {
        case .primaryLive(let alternate):
            var incoming = alternate ?? ScreenState(
                rows: Deque((0..<rowCount).map { _ in makeBlankRow(columns: columnCount) })
            )
            incoming.cursor = carriedCursor
            incoming.isPendingWrap = false
            swap(&screen, &incoming)
            screenOwnership = .alternateLive(primary: incoming)
        case .alternateLive(var primary):
            primary.cursor = carriedCursor
            primary.isPendingWrap = false
            swap(&screen, &primary)
            screenOwnership = .primaryLive(alternate: primary)
        }
    }

    /// Installs the primary for one operation and restores an active alternate on return.
    private mutating func withPrimaryScreenInstalled<Result>(
        _ body: (inout Terminal) -> Result
    ) -> Result {
        var ownership = ScreenOwnership.primaryLive(alternate: nil)
        swap(&ownership, &screenOwnership)
        switch ownership {
        case .primaryLive:
            screenOwnership = ownership
            return body(&self)
        case .alternateLive(var primary):
            ownership = .primaryLive(alternate: nil)
            swap(&screen, &primary)
            let result = body(&self)
            swap(&screen, &primary)
            screenOwnership = .alternateLive(primary: primary)
            return result
        }
    }

    /// Applies rectangle resize to an existing alternate without duplicating its row storage.
    private mutating func resizeAlternateScreen(
        columns: Int,
        rows: Int,
        oldColumnCount: Int
    ) {
        var ownership = ScreenOwnership.primaryLive(alternate: nil)
        swap(&ownership, &screenOwnership)
        switch ownership {
        case .primaryLive(var alternate):
            if var alternateState = alternate {
                resizeAlternateState(
                    &alternateState,
                    columns: columns,
                    rows: rows,
                    oldColumnCount: oldColumnCount
                )
                alternate = alternateState
            }
            screenOwnership = .primaryLive(alternate: alternate)
        case .alternateLive(let primary):
            var alternate = ScreenState(rows: [])
            swap(&alternate, &screen)
            resizeAlternateState(
                &alternate,
                columns: columns,
                rows: rows,
                oldColumnCount: oldColumnCount
            )
            swap(&alternate, &screen)
            screenOwnership = .alternateLive(primary: primary)
        }
    }

    private mutating func resizeAlternateState(
        _ alternate: inout ScreenState,
        columns: Int,
        rows: Int,
        oldColumnCount: Int
    ) {
        alternate.rows = resizedRectangle(
            alternate.rows,
            columns: columns,
            rows: rows,
            clearsSoftWrap: columns != oldColumnCount
        )
        if columns != oldColumnCount {
            alternate.isPendingWrap = false
            alternate.control.savedCursor.isPendingWrap = false
        }
        clampScreenCursorState(&alternate)
    }

    private func clampScreenCursorState(_ screen: inout ScreenState) {
        clampPosition(&screen.cursor, isPendingWrap: screen.isPendingWrap, in: screen.rows)
        clampPosition(
            &screen.control.savedCursor.position,
            isPendingWrap: screen.control.savedCursor.isPendingWrap,
            in: screen.rows
        )
        screen.isPendingWrap = screen.isPendingWrap
            && screen.cursor.column == columnCount - 1
        screen.control.savedCursor.isPendingWrap = screen.control.savedCursor.isPendingWrap
            && screen.control.savedCursor.position.column == columnCount - 1
    }

    private func clampPosition(
        _ position: inout CellPosition,
        isPendingWrap: Bool,
        in grid: Deque<GridRow>
    ) {
        position.row = min(max(position.row, 0), rowCount - 1)
        position.column = min(max(position.column, 0), columnCount - 1)
        if isPendingWrap, position.column == columnCount - 1 {
            return
        }
        movePositionOffWideTail(&position, in: grid)
    }

    private func movePositionOffWideTail(_ position: inout CellPosition, in grid: Deque<GridRow>) {
        guard grid.indices.contains(position.row),
              grid[position.row].cells.indices.contains(position.column),
              grid[position.row].cells[position.column].kind == .wideTail
        else { return }
        position.column = max(0, position.column - 1)
    }

    private mutating func repeatLastPrintedCluster(count: Int) {
        guard lastPrintedCluster.isPresent else { return }

        // A one-scalar bulk-printable memory is a run of identical narrow cells, so it is filled
        // as one, row segment by row segment, instead of one print call per repeated cell
        // (`research/39/D7`). It keeps its own path because it is the only shape whose cells the
        // stream's own bulk writer can stamp, and it is the whole of the `csi` arm's cost.
        if lastPrintedCluster.count == 1 {
            let scalar = lastPrintedCluster[0]
            let classification = terminalUnicodeClassification(for: scalar)
            // The width is asked for separately because `isBulkPrintable` no longer implies it:
            // a wide memory is a run of identical wide cells, which is `repeatCluster`'s job.
            if classification.properties.cellWidth == .narrow, classification.isBulkPrintable {
                repeatNarrowScalar(scalar, count: count)
                return
            }
        }
        repeatCluster(count: count)
    }

    /// Repeats every memory the narrow scalar run cannot take -- wide, multi-scalar, or a narrow
    /// scalar that could join or be joined -- as runs of identical cells.
    ///
    /// One copy of the memory serves the whole REP. Both the run and the repeats it declines read
    /// the cluster while the terminal is being mutated, and `rememberOpenCluster` rewrites
    /// `lastPrintedCluster` from every cell either of them stamps, so the memory cannot be read
    /// in place. A one-scalar memory takes the inline case, so the copy reaches the heap only for
    /// a cluster that is already spilled in the row it came from.
    private mutating func repeatCluster(count: Int) {
        let cluster = lastPrintedCluster.count == 1
            ? TerminalScalars(lastPrintedCluster[0])
            : TerminalScalars(Array(lastPrintedCluster))
        let cellWidth = lastPrintedCluster.cellWidth
        // The look-behind one repeat leaves open is the same wherever the repeat lands, so it is
        // walked once here rather than per segment.
        var openClass = terminalUnicodeClassification(for: cluster[0]).graphemeBreakClass
        var openBreakState = GraphemeBreakState()
        var retainedUTF8ByteCount = TerminalScalars.utf8ByteCount(of: cluster[0])
        for position in 1..<cluster.count {
            let scalar = cluster[position]
            let nextClass = terminalUnicodeClassification(for: scalar).graphemeBreakClass
            _ = graphemeBreak(between: openClass, and: nextClass, state: &openBreakState)
            openClass = nextClass
            retainedUTF8ByteCount += TerminalScalars.utf8ByteCount(of: scalar)
        }

        var remaining = count
        while remaining > 0 {
            let taken = printBulkCluster(
                runCount: remaining,
                cluster: cluster,
                cellWidth: cellWidth,
                openClass: openClass,
                openBreakState: openBreakState,
                retainedUTF8ByteCount: retainedUTF8ByteCount
            )
            if taken > 0 {
                remaining -= taken
                continue
            }
            // The count goes through `print` untouched: wrapping, scrolling, DECAWM and insert
            // mode are `print`'s rules, and REP restating any of them is what made it diverge
            // from xterm (`references/xterm/charproc.c:6152`), which loops the raw count through
            // `dotext`. `CSIParameters.Element` is `UInt16`, so the loop is already bounded at
            // 65535 -- the same ceiling kitty and iTerm2 impose by hand.
            clusterContext = nil
            for position in 0..<cluster.count {
                print(cluster[position], recoversGridContext: false)
            }
            remaining -= 1
        }
    }

    /// Repeats one bulk-printable narrow scalar as runs of identical cells.
    ///
    /// Same loop shape as `printASCIIRun`: `printBulkNarrow` takes a prefix of what is left or
    /// declines, and whatever it declines -- the cell at a latched wrap, a cell in insert mode, a
    /// cell that must clear a wide partner -- costs one repeat through `print` before the run
    /// re-enters. So the wrap, scroll, DECAWM and insert-mode rules stay `print`'s, exactly as
    /// they were when every repeat went through it.
    ///
    /// The context is cleared before that one print because a repeat never joins what precedes
    /// it: `printBulkNarrow` may have recovered look-behind from the grid before declining, and
    /// leaving it would let a REP after a Prepend cell extend that cluster.
    private mutating func repeatNarrowScalar(_ scalar: Unicode.Scalar, count: Int) {
        var remaining = count
        while remaining > 0 {
            let taken = printBulkNarrow(runCount: remaining) { _ in scalar }
            if taken == 0 {
                clusterContext = nil
                print(scalar, recoversGridContext: false)
                remaining -= 1
            } else {
                remaining -= taken
            }
        }
    }

    private mutating func softReset() {
        recordFullDamage()
        resetTerminalControlState()
        resetSoftScreenControlState()
        hyperlinkPen = nil
        for slot in InteractionLinkSlot.allCases { self[slot] = nil }
        clearPendingMotionState()
    }

    private mutating func hardReset() {
        recordFullDamage()
        clearInspection()
        evictedRowCount = 0
        resetTerminalControlState()
        resetHardScreenControlState()
        selectPrimaryScreen()
        // A retained alternate outlives its program, so leaving it here would let a later
        // `?47h` bring a pre-reset frame back onto a terminal that is meant to be as good as
        // new -- and no synchronization stream could ever encode that difference away.
        screenOwnership = .primaryLive(alternate: nil)
        tabStops = Self.defaultTabStops(columns: columnCount)
        hyperlinkPen = nil
        hyperlinkTargets.removeAll(keepingCapacity: true)
        nextHyperlinkId = 1
        nextContentIdentity = 1
        screen.cursor = CellPosition(row: 0, column: 0)
        clearPendingMotionState()
        lastPrintedCluster.clear()
        screen.semanticContent = .output
        screen.semanticContentClearsAtEndOfLine = false
        promptRedrawMode = .full

        severWrapClaim(before: 0)
        for row in screen.rows.indices {
            _ = eraseEntireRow(row)
        }
    }

    private mutating func resetTerminalControlState() {
        scrollRegion = nil
        modes = TerminalModes()
        charsets = TerminalCharsetState()
        currentStyle = TerminalStyle()
    }

    private mutating func resetSoftScreenControlState() {
        screen.control = ScreenControlState()
        var ownership = ScreenOwnership.primaryLive(alternate: nil)
        swap(&ownership, &screenOwnership)
        switch ownership {
        case .primaryLive(var alternate):
            alternate?.control.kittyKeyboardStack.removeAll(keepingCapacity: true)
            screenOwnership = .primaryLive(alternate: alternate)
        case .alternateLive(var primary):
            primary.control.kittyKeyboardStack.removeAll(keepingCapacity: true)
            screenOwnership = .alternateLive(primary: primary)
        }
    }

    private mutating func resetHardScreenControlState() {
        screen.control = ScreenControlState()
        var ownership = ScreenOwnership.primaryLive(alternate: nil)
        swap(&ownership, &screenOwnership)
        switch ownership {
        case .primaryLive(var alternate):
            alternate?.control = ScreenControlState()
            screenOwnership = .primaryLive(alternate: alternate)
        case .alternateLive(var primary):
            primary.control = ScreenControlState()
            screenOwnership = .alternateLive(primary: primary)
        }
    }

    private mutating func pushKittyKeyboardFlags(_ flags: TerminalKittyKeyboardFlags) {
        var stack = screen.control.kittyKeyboardStack
        if stack.count == Self.kittyKeyboardStackDepth {
            stack.removeFirst()
        }
        stack.append(flags)
        screen.control.kittyKeyboardStack = stack
    }

    private mutating func popKittyKeyboardFlags(_ count: UInt16) {
        var stack = screen.control.kittyKeyboardStack
        stack.removeLast(min(Int(count), stack.count))
        screen.control.kittyKeyboardStack = stack
    }

    private mutating func setKittyKeyboardFlags(_ flags: TerminalKittyKeyboardFlags, mode: UInt16) {
        var stack = screen.control.kittyKeyboardStack
        let previous = stack.last ?? []
        let updated: TerminalKittyKeyboardFlags
        switch mode {
        case 1: updated = flags
        case 2: updated = previous.union(flags)
        case 3: updated = previous.subtracting(flags)
        default: return
        }
        if stack.isEmpty {
            stack.append(updated)
        } else {
            stack[stack.count - 1] = updated
        }
        screen.control.kittyKeyboardStack = stack
    }

    /// Prints a run of GL bytes, taking as much of it in bulk as the grid state allows.
    ///
    /// The loop is the whole contract: `printBulkNarrow` takes a prefix or declines, and whatever
    /// it declines goes through `printGLByte` one character at a time. So the cut rules live in
    /// one place, every one of them costs a character rather than the run, and a rule this
    /// reducer does not know about cannot produce a wrong grid -- only a slower one.
    ///
    /// This is the only place raw GL stream bytes become scalars, which is why it is the only
    /// place charset translation happens. `print(_:)` is reached with already-decoded scalars
    /// and with already-translated cell scalars re-fed by REP, and must not translate either.
    private mutating func printASCIIRun(
        _ bytes: UnsafeBufferPointer<UInt8>,
        _ range: Range<Int>
    ) {
        var index = range.lowerBound
        while index < range.upperBound {
            let charset = charsets[charsets.invokedSlot]
            let taken: Int
            if charset == .ascii {
                taken = printBulkNarrow(runCount: range.upperBound - index) { offset in
                    Unicode.Scalar(bytes[index + offset])
                }
            } else {
                taken = printBulkNarrow(runCount: range.upperBound - index) { offset in
                    charset.translate(bytes[index + offset])
                }
            }
            if taken == 0 {
                printGLByte(bytes[index])
                index += 1
            } else {
                index += taken
            }
        }
    }

    /// Spends one text stretch, walking it once and handing each maximal segment of one kind to
    /// the writer for that kind.
    ///
    /// This reads no bytes of the chunk and no classification table to pick a writer: the stream
    /// decoded and classified each of the stretch's scalars once, and this is where they are spent
    /// (`research/39/D9`, `research/39/D10`). Segmenting here rather than in the stream is what
    /// lets one action carry text of every classification -- a base and its marks reach the grid
    /// as one action instead of four -- while the writers keep the boundaries they need.
    ///
    /// The break decision stays with `print`: a scalar no bulk writer can stamp costs one
    /// single-scalar print, which is the only thing that owns the grid state a join depends on.
    private mutating func printTextStretch(
        _ scratch: TerminalStretchScratch,
        scalarCount: Int
    ) {
        var index = 0
        while index < scalarCount {
            switch scratch.kinds[index] {
            case .glByte:
                index = printGLSegment(scratch, from: index, upTo: scalarCount)
            case .bulkNarrow:
                index = printBulkSegment(scratch, from: index, upTo: scalarCount, isWide: false)
            case .bulkWide:
                index = printBulkSegment(scratch, from: index, upTo: scalarCount, isWide: true)
            case .zeroWidthJoin:
                index = printJoinSegment(scratch, from: index, upTo: scalarCount)
            case .single:
                print(scratch.scalars[index])
                index += 1
            }
        }
    }

    /// Prints the maximal run of GL bytes at `start`, and returns where it ended.
    ///
    /// The GL half of `printASCIIRun`, reading the stretch's scratch rather than the chunk: the
    /// same loop contract -- `printBulkNarrow` takes a prefix or declines, and whatever it
    /// declines goes through `printGLByte` one character at a time -- and the same reason for it,
    /// so every cut rule lives in one place and costs a character rather than the segment.
    ///
    /// A GL entry holds a printable ASCII byte, so its scalar value is the byte the invoked
    /// character set translates. This and `printASCIIRun` are the only places raw GL stream bytes
    /// become cell scalars, which is why they are the only places charset translation happens.
    private mutating func printGLSegment(
        _ scratch: TerminalStretchScratch,
        from start: Int,
        upTo end: Int
    ) -> Int {
        var segmentEnd = start
        while segmentEnd < end, scratch.kinds[segmentEnd] == .glByte { segmentEnd += 1 }

        var index = start
        while index < segmentEnd {
            let charset = charsets[charsets.invokedSlot]
            // The supplier reads a `let` rather than `index` itself: capturing the loop's own
            // counter would make the closure mutate the value it is indexing with.
            let requestStart = index
            let taken: Int
            if charset == .ascii {
                taken = printBulkNarrow(runCount: segmentEnd - index) { offset in
                    scratch.scalars[requestStart + offset]
                }
            } else {
                taken = printBulkNarrow(runCount: segmentEnd - index) { offset in
                    charset.translate(Self.glByte(of: scratch.scalars[requestStart + offset]))
                }
            }
            if taken == 0 {
                printGLByte(Self.glByte(of: scratch.scalars[index]))
                index += 1
            } else {
                index += taken
            }
        }
        return segmentEnd
    }

    /// Prints the maximal run of bulk-printable scalars of one width at `start`, and returns where
    /// it ended.
    ///
    /// The stream cut a run where the width changed; the stretch carries every width, so the cut
    /// is made here instead -- one segment is one width, and the width picks the writer once for
    /// the whole segment rather than per scalar. The loop contract is `printASCIIRun`'s: take a
    /// prefix or decline, and whatever is declined costs one scalar through `print`.
    private mutating func printBulkSegment(
        _ scratch: TerminalStretchScratch,
        from start: Int,
        upTo end: Int,
        isWide: Bool
    ) -> Int {
        let kind: TerminalStretchSegmentKind = isWide ? .bulkWide : .bulkNarrow
        var segmentEnd = start
        while segmentEnd < end, scratch.kinds[segmentEnd] == kind { segmentEnd += 1 }

        // A writer stamps into one row, so each request stops at the most cells a row can hold for
        // this width. `Terminal.minimumColumns` is 2, so a wide cap is never zero.
        let requestScalarCap = isWide ? columnCount / 2 : columnCount
        var index = start
        while index < segmentEnd {
            let requestCount = min(segmentEnd - index, requestScalarCap)
            // The supplier reads a `let` rather than `index` itself: capturing the loop's own
            // counter would make the closure mutate the value it is indexing with.
            let requestStart = index
            let taken: Int
            if isWide {
                taken = printBulkWide(runCount: requestCount) { scratch.scalars[requestStart + $0] }
            } else {
                taken = printBulkNarrow(runCount: requestCount) { scratch.scalars[requestStart + $0] }
            }
            if taken == 0 {
                print(scratch.scalars[index])
                index += 1
            } else {
                index += taken
            }
        }
        return segmentEnd
    }

    /// Joins the maximal run of zero-width scalars at `start` to the open cluster in one pass, and
    /// returns where it ended.
    ///
    /// Everything `print`/`appendToOpenClusterIfJoined` pay per scalar that does not change between
    /// the joiners of one segment is paid once here: the grid-context recovery, the three checks
    /// that the open cluster still names a joinable cell, the base-scalar read, the inspection
    /// invalidation and the context write-back. What is genuinely per-scalar stays per-scalar -- the
    /// grapheme break, the retained-byte budget, the arena append and the REP memory's extension
    /// (`research/39/D10`).
    ///
    /// The hoist is sound because the stream admits only zero-width non-variation-selector scalars
    /// to this segment, and `desiredClusterWidth` answers nil for every one of them without reading
    /// the base: no scalar here can move the target cell or change its width, so the cell the first
    /// joiner validated is the cell every later joiner writes. A scalar the segment refuses is
    /// dropped exactly as `print` drops it -- it places no cell either way.
    private mutating func printJoinSegment(
        _ scratch: TerminalStretchScratch,
        from start: Int,
        upTo end: Int
    ) -> Int {
        var segmentEnd = start
        while segmentEnd < end, scratch.kinds[segmentEnd] == .zeroWidthJoin { segmentEnd += 1 }

        let contextWasRecovered = recoverClusterContextFromGridIfNeeded()
        guard var context = clusterContext else {
            // Nothing to join. Each scalar still goes through `print`, which retries the recovery
            // for itself, so a segment with no open cluster costs exactly what it costs today.
            for index in start..<segmentEnd { print(scratch.scalars[index]) }
            return segmentEnd
        }
        let target = context.target
        guard screen.rows.indices.contains(target.row),
              screen.rows[target.row].cells.indices.contains(target.column),
              screen.rows[target.row].cells[target.column].kind == .narrow
                || screen.rows[target.row].cells[target.column].kind == .wideHead
        else {
            // The context names a cell that is gone or is no longer a cluster head, which drops it.
            // The scalar that found it is dropped with it; the rest re-enter through `print`, which
            // recovers a context from the grid for them.
            clusterContext = nil
            for index in (start + 1)..<segmentEnd { print(scratch.scalars[index]) }
            return segmentEnd
        }

        // Both are checked once for the whole segment: the base scalar cannot disappear from a cell
        // this loop only appends to, and the inspection range cannot move while the target does not.
        var baseWasRead = false
        var inspectionWasInvalidated = false
        var index = start
        while index < segmentEnd {
            let scalar = scratch.scalars[index]
            let classification = terminalUnicodeClassification(for: scalar)
            var nextBreakState = context.breakState
            guard graphemeBreak(
                between: context.previousClass,
                and: classification.graphemeBreakClass,
                state: &nextBreakState
            ) == false else {
                // A break leaves the cluster untouched and drops the scalar, so a later joiner in
                // the same segment is still offered the same context. A context recovered by this
                // call does not survive the refusal, and the scalars after it recover their own.
                if contextWasRecovered, index == start {
                    clusterContext = nil
                    for rest in (index + 1)..<segmentEnd { print(scratch.scalars[rest]) }
                    return segmentEnd
                }
                index += 1
                continue
            }
            if baseWasRead == false {
                guard screen.rows[target.row]
                    .firstScalar(of: screen.rows[target.row].cells[target.column]) != nil
                else {
                    clusterContext = nil
                    for rest in (index + 1)..<segmentEnd { print(scratch.scalars[rest]) }
                    return segmentEnd
                }
                baseWasRead = true
            }
            let scalarByteCount = TerminalScalars.utf8ByteCount(of: scalar)
            guard context.retainedUTF8ByteCount <= Self.graphemeClusterByteLimit - scalarByteCount
            else {
                // Refused for length: the cluster takes the scalar's break position so segmentation
                // continues past it, and the cell keeps the scalars it already holds.
                context.previousClass = classification.graphemeBreakClass
                context.breakState = nextBreakState
                refreshAdoptedClusterMemory(&context)
                index += 1
                continue
            }
            if inspectionWasInvalidated == false {
                invalidateInspection(
                    inViewportRows: target.row..<(target.row + 1),
                    affectsPreviousProjection: target.column == 0
                )
                inspectionWasInvalidated = true
            }
            context.previousClass = classification.graphemeBreakClass
            context.breakState = nextBreakState
            context.retainedUTF8ByteCount += scalarByteCount
            screen.rows[target.row].appendScalar(scalar, at: target.column)
            if context.memoryMirrorsTarget {
                lastPrintedCluster.extend(scalar)
            } else {
                refreshAdoptedClusterMemory(&context)
            }
            index += 1
        }
        clusterContext = context
        return segmentEnd
    }

    /// `rememberAdoptedCluster` for the segment join, which holds its context in a local.
    ///
    /// The memory has to be rebuilt from the cell, and `rememberOpenCluster` reads the stored
    /// context to find it -- so the local is published first and the mirroring flag it sets is
    /// carried back, which is what makes the rebuild happen once per segment rather than once per
    /// joiner.
    private mutating func refreshAdoptedClusterMemory(_ context: inout ClusterContext) {
        guard context.memoryMirrorsTarget == false else { return }
        clusterContext = context
        rememberOpenCluster()
        context.memoryMirrorsTarget = true
    }

    /// Recovers the stream byte a GL entry stands for.
    ///
    /// The stream admits a GL entry only for a printable ASCII byte, so the scalar it stored is
    /// that byte's value and the conversion cannot lose anything.
    private static func glByte(of scalar: Unicode.Scalar) -> UInt8 {
        UInt8(truncatingIfNeeded: scalar.value)
    }

    /// Prints one GL byte through the active character set.
    ///
    /// The set is read before the print because printing is what spends a pending single shift.
    private mutating func printGLByte(_ byte: UInt8) {
        print(charsets.activeCharset.translate(byte))
    }

    /// Resolves one row's cell storage once and lends it to `body` for writing.
    ///
    /// Every loop that writes a row's cells goes through here. A two-level
    /// `screen.rows[row].cells[column]` store costs a copy-on-write uniqueness check on the row
    /// array and another on the cell array for every single cell touched; resolving the row once
    /// pays both checks once for the whole loop.
    ///
    /// It sits on `Terminal` rather than on `ScreenState` on purpose: `self` is exclusively
    /// borrowed for the duration, so the compiler rejects a `body` that reads or writes any part
    /// of the terminal while the buffer is alive. The caller owns the row bound; `row` must be a
    /// valid row index.
    private mutating func withRowCells<R>(
        _ row: Int,
        _ body: (UnsafeMutableBufferPointer<GridCell>) -> R
    ) -> R {
        screen.rows[row].cells.withUnsafeMutableBufferPointer { body($0) }
    }

    /// The reading counterpart of `withRowCells`, for loops that only scan a row.
    ///
    /// A scan must not go through the mutating form: that would prove the row storage unique and
    /// so copy it whenever it is shared -- a cost a scan that writes nothing should never pay.
    /// Being non-mutating is what makes that a compile error rather than a review miss.
    private func readingRowCells<R>(
        _ row: Int,
        _ body: (UnsafeBufferPointer<GridCell>) -> R
    ) -> R {
        screen.rows[row].cells.withUnsafeBufferPointer { body($0) }
    }

    /// Writes a prefix of the run into one row in a single pass, or returns 0 to decline it.
    ///
    /// Everything `print`/`printNarrow` pay per character -- the Unicode classification, the
    /// cluster-join attempt, `invalidateInspection`, the style-id reads, and
    /// `rememberOpenCluster` -- is paid once here for the whole prefix. Two facts make that
    /// sound, and both are pinned by `TerminalBulkRunTests`: each supplier yields a scalar whose
    /// classification is grapheme-break-`.other` and free of emoji flags, and narrow -- the caller
    /// owns that last part, either because its source is printable ASCII or because the stream cut
    /// its run where the width changed -- so no character of a run can be wide or be joined by the
    /// next one; and Prepend is the only class an `.other` scalar does not break from, so one
    /// comparison decides whether the run's head could join an open cluster.
    ///
    /// It declines, rather than handling, every state in which a character is not a plain
    /// same-row cell replacement: a latched pending wrap, insert mode, an open prepend cluster, a
    /// cell whose overwrite would have to clear a partner, and a content-identity range that
    /// would straddle the counter's wrap. Declining costs one character and then re-enters, so
    /// each of those is a cut in the run, not a fallback for the rest of it.
    private mutating func printBulkNarrow(
        runCount: Int,
        scalar: (Int) -> Unicode.Scalar
    ) -> Int {
        // A pending single shift applies to exactly one character, so the run cannot carry it:
        // declining costs that one character and the rest of the run re-enters unshifted.
        guard screen.isPendingWrap == false,
              modes.isInsertMode == false,
              charsets.pendingSingleShift == nil
        else { return 0 }
        let row = screen.cursor.row
        let column = screen.cursor.column
        guard screen.rows.indices.contains(row), screen.rows[row].cells.count == columnCount,
              column >= 0, column < columnCount
        else { return 0 }
        _ = recoverClusterContextFromGridIfNeeded()
        if let context = clusterContext, context.previousClass == .prepend { return 0 }

        // Cut at the right margin, then before the first cell an overwrite cannot simply replace:
        // a wide pair blanks its other half, which is `prepareDestination`'s job and not this
        // one's.
        let available = min(runCount, columnCount - column)
        let count = readingRowCells(row) { cells -> Int in
            var count = 0
            while count < available {
                let kind = cells[column + count].kind
                guard kind == .narrow || kind == .padding else { break }
                count += 1
            }
            return count
        }
        guard count > 0 else { return 0 }

        // The scalar path asks for this style before it prepares each destination. Keep the lazy
        // cache state equal when the bulk path proves that no destination needs preparation.
        _ = backgroundEraseStyleId()

        guard let baseIdentity = reserveContentIdentities(count: count) else { return 0 }

        invalidateInspection(
            inViewportRows: row..<(row + 1),
            affectsPreviousProjection: column == 0
        )
        writeNarrowCells(
            row: row,
            column: column,
            count: count,
            baseIdentity: baseIdentity,
            breakClass: .other,
            scalar: scalar
        )
        rememberOpenCluster()
        return count
    }

    /// Writes a prefix of a wide run into one row in a single pass, or returns 0 to decline it.
    ///
    /// The wide sibling of `printBulkNarrow`, and it rests on the same premise: every scalar of
    /// the run is grapheme-break-`.other` and free of the emoji flags, so none joins the one
    /// before it and only the run's last cell stays open for what follows. Width does not enter
    /// that argument (`research/39/D8`), so the run pays per segment what `printWide` pays per
    /// character -- one destination prepare over the whole range, one inspection invalidation, one
    /// identity range, one cluster context, one cursor advance.
    ///
    /// What the segment owes the grid is what one wide print owes it, over the whole range rather
    /// than per pair: only the two boundary columns can sever a partner, which is
    /// `prepareDestination`'s rule, so a pair the segment overwrites mid-range is one it is about
    /// to store over anyway. That is why the segment does not need a plain destination and can
    /// repaint a row of wide pairs in one pass.
    ///
    /// It declines, rather than handles, every state in which a wide print is not a plain same-row
    /// pair store: a latched pending wrap, insert mode, an armed single shift, an open prepend
    /// cluster the head would join, a pair that does not fit before the right margin, and a
    /// content-identity range that would straddle the counter's wrap. Declining costs one scalar
    /// through `print` -- which owns the DECAWM wrap, the wrap spacer and the DECAWM-off backup --
    /// and then the run re-enters.
    private mutating func printBulkWide(
        runCount: Int,
        scalar: (Int) -> Unicode.Scalar
    ) -> Int {
        // A pending single shift applies to exactly one character, so the run cannot carry it:
        // declining costs that one character and the rest of the run re-enters unshifted.
        guard screen.isPendingWrap == false,
              modes.isInsertMode == false,
              charsets.pendingSingleShift == nil
        else { return 0 }
        let row = screen.cursor.row
        let column = screen.cursor.column
        guard screen.rows.indices.contains(row), screen.rows[row].cells.count == columnCount,
              column >= 0, column < columnCount
        else { return 0 }
        _ = recoverClusterContextFromGridIfNeeded()
        if let context = clusterContext, context.previousClass == .prepend { return 0 }

        // The right margin is the only cut: whole pairs that fit before it, and a pair the margin
        // leaves no room for declines the segment outright.
        let count = min(runCount, (columnCount - column) / 2)
        guard count > 0 else { return 0 }
        guard let baseIdentity = reserveContentIdentities(count: count) else { return 0 }

        // `printWide` widens at column 1 as well as at column 0, so a segment covering either
        // column widens too.
        invalidateInspection(
            inViewportRows: row..<(row + 1),
            affectsPreviousProjection: column <= 1
        )
        prepareDestination(
            row: row,
            columns: column..<(column + count * 2),
            replacementStyleId: backgroundEraseStyleId()
        )
        writeWideCells(
            row: row,
            column: column,
            count: count,
            baseIdentity: baseIdentity,
            breakClass: .other,
            scalar: scalar
        )
        rememberOpenCluster()
        return count
    }

    /// Reserves `count` consecutive content identities for one bulk-stamped run, or nothing when
    /// the range would straddle the counter's reset.
    ///
    /// The per-character path issues one identity per cell and resets the counter when it hands
    /// out `ContentIdentity.max`. A run that would straddle that reset is declined so the reset
    /// keeps happening on exactly the character it happens on today, which is the rule
    /// `allocateContentIdentity` states for one cell; every bulk writer asks it here so the two
    /// spellings cannot drift apart.
    private mutating func reserveContentIdentities(count: Int) -> ContentIdentity? {
        guard ContentIdentity(count - 1) <= ContentIdentity.max - nextContentIdentity else {
            return nil
        }
        let baseIdentity = nextContentIdentity
        if baseIdentity + ContentIdentity(count - 1) == ContentIdentity.max {
            nextContentIdentity = 1
            armedLinkState = nil
        } else {
            nextContentIdentity = baseIdentity + ContentIdentity(count)
        }
        return baseIdentity
    }

    /// Writes a prefix of a repeat run into one row in a single pass, or returns 0 to decline it.
    ///
    /// The wide and multi-scalar counterpart of `printBulkNarrow`, and the reason REP has one:
    /// the repeated cluster is stamped into whole cells instead of being replayed scalar by
    /// scalar through the segmenter. That is sound because the memory always mirrors a cell the
    /// printer produced -- a scalar the segmenter refused to join, or a width change it refused
    /// to make, never reaches the memory -- so the cluster and `cellWidth` together are what
    /// re-feeding the memory into a plain, same-row destination produces again. It is also what
    /// keeps the repeats independent of each other and of the cell before them, which replaying
    /// the scalars only achieved by clearing the cluster context before every repeat.
    ///
    /// It declines, rather than handles, every state in which a repeat is not a same-row cell
    /// replacement: a latched pending wrap, insert mode, an armed single shift, a repeat the
    /// cluster does not fit before the right margin, and a content-identity range that would
    /// straddle the counter's wrap. Declining costs one repeat through `print` and the run
    /// re-enters, so each of those is a cut in the run rather than a fallback for the rest of it.
    private mutating func printBulkCluster(
        runCount: Int,
        cluster: TerminalScalars,
        cellWidth: Int,
        openClass: GraphemeBreakClass,
        openBreakState: GraphemeBreakState,
        retainedUTF8ByteCount: Int
    ) -> Int {
        // A pending single shift applies to exactly one character, so the run cannot carry it:
        // declining costs that one repeat and the rest of the run re-enters unshifted.
        guard screen.isPendingWrap == false,
              modes.isInsertMode == false,
              charsets.pendingSingleShift == nil
        else { return 0 }
        let row = screen.cursor.row
        let column = screen.cursor.column
        guard screen.rows.indices.contains(row), screen.rows[row].cells.count == columnCount,
              column >= 0, column < columnCount
        else { return 0 }

        // The right margin is the only cut: whole repeats that fit before it, and a repeat the
        // cluster's width leaves no room for declines the segment outright.
        let count = min(runCount, (columnCount - column) / cellWidth)
        guard count > 0 else { return 0 }
        guard let baseIdentity = reserveContentIdentities(count: count) else { return 0 }

        // `printNarrow` and `printWide` both widen at column 1, so a run that covers column 1
        // widens too -- which a run starting at column 0 or 1 always does.
        invalidateInspection(
            inViewportRows: row..<(row + 1),
            affectsPreviousProjection: column <= 1
        )

        // What the run owes the grid is what one print owes it, over the whole range rather than
        // per cell: a wide pair that straddles either end stops claiming the half the range
        // takes. Only the two boundaries can straddle, so a partner a repeat severs mid-run is
        // one this run is about to store over anyway -- which is why the run does not need the
        // destination to be plain, and can repaint a row of wide cells in one pass.
        prepareDestination(
            row: row,
            columns: column..<(column + count * cellWidth),
            replacementStyleId: backgroundEraseStyleId()
        )

        let styleId = currentStyleId()
        let hyperlinkId = hyperlinkPen
        let kind: TerminalCellKind = cellWidth == 2 ? .wideHead : .narrow
        for index in 0..<count {
            let head = column + index * cellWidth
            let identity = baseIdentity + ContentIdentity(index)
            screen.rows[row].place(
                GridCell(
                    kind: kind,
                    styleId: styleId,
                    hyperlinkId: hyperlinkId,
                    contentIdentity: identity
                ),
                scalars: cluster,
                at: head
            )
            if cellWidth == 2 {
                screen.rows[row].cells[head + 1] = GridCell(
                    kind: .wideTail,
                    styleId: styleId,
                    hyperlinkId: hyperlinkId,
                    contentIdentity: identity
                )
            }
        }

        let lastHead = CellPosition(row: row, column: column + (count - 1) * cellWidth)
        if column + count * cellWidth == columnCount {
            screen.rows[row].marginProvenance = .content
        }
        clusterContext = ClusterContext(
            target: lastHead,
            previousClass: openClass,
            breakState: openBreakState,
            retainedUTF8ByteCount: retainedUTF8ByteCount,
            memoryMirrorsTarget: true
        )
        if cellWidth == 2 {
            advanceCursorPastWideCell(at: lastHead)
        } else if column + count == columnCount {
            screen.cursor.column = columnCount - 1
            screen.isPendingWrap = true
        } else {
            screen.cursor.column = column + count
        }
        rememberOpenCluster()
        return count
    }

    /// The one writer of plain narrow cells: stamps `count` consecutive cells in a row, opens the
    /// cluster context on the last of them, and advances the cursor with the pending-wrap latch.
    ///
    /// Both `printNarrow` (count 1) and `printBulkNarrow` (a whole run) end here, and that is the
    /// point: cell shape, cluster context, cursor advance and the wrap latch are the state machine
    /// the two paths must agree on, so they share it instead of each restating it. The caller owns
    /// everything that legitimately differs -- clearing the target cells, insert mode, identity
    /// allocation -- and must guarantee the target range is in-bounds and needs no clearing.
    ///
    /// `scalar` is a non-escaping per-offset supplier called exactly once for each offset in
    /// ascending order. That contract lets the scalar-run path decode sequentially from the fed
    /// chunk without materializing scalars; same-module specialization keeps it out of the hot
    /// loop's way.
    private mutating func writeNarrowCells(
        row: Int,
        column: Int,
        count: Int,
        baseIdentity: ContentIdentity,
        breakClass: GraphemeBreakClass,
        scalar: (Int) -> Unicode.Scalar
    ) {
        let styleId = currentStyleId()
        let hyperlinkId = hyperlinkPen
        // The supplier runs inside the borrow, which is what lets it read scalars straight from
        // the fed chunk instead of materializing them into an array first.
        var lastScalar: Unicode.Scalar?
        withRowCells(row) { cells in
            for offset in 0..<count {
                let suppliedScalar = scalar(offset)
                cells[column + offset] = GridCell(
                    scalars: .single(suppliedScalar),
                    kind: .narrow,
                    styleId: styleId,
                    hyperlinkId: hyperlinkId,
                    contentIdentity: baseIdentity + ContentIdentity(offset)
                )
                lastScalar = suppliedScalar
            }
        }

        clusterContext = ClusterContext(
            target: CellPosition(row: row, column: column + count - 1),
            previousClass: breakClass,
            retainedUTF8ByteCount: TerminalScalars.utf8ByteCount(of: lastScalar!),
            memoryMirrorsTarget: true
        )
        if column + count == columnCount {
            screen.rows[row].marginProvenance = .content
            screen.cursor.column = columnCount - 1
            screen.isPendingWrap = true
        } else {
            screen.cursor.column = column + count
        }
    }

    /// The one writer of plain wide cells: stamps `count` consecutive head/tail pairs in a row,
    /// opens the cluster context on the last head, and advances the cursor past it.
    ///
    /// The wide counterpart of `writeNarrowCells`, and it exists for the same reason: cell shape,
    /// cluster context, margin provenance and the cursor advance are the state machine
    /// `printWide` (count 1) and `printBulkWide` (a whole segment) must agree on, so they share it
    /// instead of each restating it. The caller owns everything that legitimately differs --
    /// wrapping at the margin, insert mode, clearing the target range, identity allocation -- and
    /// must guarantee `count` pairs fit in the row and need no further clearing.
    ///
    /// `scalar` is a non-escaping per-offset supplier called exactly once for each offset in
    /// ascending order, which is what lets the run path decode straight from the fed chunk.
    private mutating func writeWideCells(
        row: Int,
        column: Int,
        count: Int,
        baseIdentity: ContentIdentity,
        breakClass: GraphemeBreakClass,
        scalar: (Int) -> Unicode.Scalar
    ) {
        let styleId = currentStyleId()
        let hyperlinkId = hyperlinkPen
        // The supplier runs inside the borrow, which is what lets it read scalars straight from
        // the fed chunk instead of materializing them into an array first.
        var lastScalar: Unicode.Scalar?
        withRowCells(row) { cells in
            for offset in 0..<count {
                let suppliedScalar = scalar(offset)
                let head = column + offset * 2
                let contentIdentity = baseIdentity + ContentIdentity(offset)
                cells[head] = GridCell(
                    scalars: .single(suppliedScalar),
                    kind: .wideHead,
                    styleId: styleId,
                    hyperlinkId: hyperlinkId,
                    contentIdentity: contentIdentity
                )
                cells[head + 1] = GridCell(
                    kind: .wideTail,
                    styleId: styleId,
                    hyperlinkId: hyperlinkId,
                    contentIdentity: contentIdentity
                )
                lastScalar = suppliedScalar
            }
        }

        let lastHead = CellPosition(row: row, column: column + (count - 1) * 2)
        if lastHead.column + 2 == columnCount {
            screen.rows[row].marginProvenance = .content
        }
        clusterContext = ClusterContext(
            target: lastHead,
            previousClass: breakClass,
            retainedUTF8ByteCount: TerminalScalars.utf8ByteCount(of: lastScalar!),
            memoryMirrorsTarget: true
        )
        advanceCursorPastWideCell(at: lastHead)
    }

    /// Prints one scalar, reading its classification only when the caller did not already have it.
    ///
    /// The stream classifies every scalar it decodes, so the print it hands over arrives with the
    /// record and this reads no table (`research/39/D9`). REP, the synchronization stream and the
    /// cluster paths print scalars the stream never classified and pass nil.
    private mutating func print(
        _ scalar: Unicode.Scalar,
        classification carriedClassification: TerminalUnicodeClassification? = nil,
        recoversGridContext: Bool = true
    ) {
        let classification = carriedClassification
            ?? terminalUnicodeClassification(for: scalar)
        let contextWasRecovered = recoversGridContext
            && recoverClusterContextFromGridIfNeeded()
        if appendToOpenClusterIfJoined(
            scalar,
            classification: classification,
            contextWasRecovered: contextWasRecovered
        ) {
            // The join owns the memory: it extends the one it mirrors and rebuilds the one it
            // does not, so there is nothing left to refresh here.
            return
        }

        let properties = classification.properties
        guard properties.cellWidth != .zero else { return }

        // Past this point a cell is written, which is what spends a single shift -- whatever
        // the character is, and whether or not it came from a GL byte the shift could map.
        // A mark that joined the open cluster returned above and leaves the shift armed.
        charsets.pendingSingleShift = nil

        if screen.isPendingWrap, modes.isAutoWrapMode {
            invalidateInspection(inViewportRows: screen.cursor.row..<(screen.cursor.row + 1))
            softWrap()
        }

        switch properties.cellWidth {
        case .zero:
            // Unreachable: the guard above returns on .zero. The arm stays because
            // TerminalCellWidth has three cases and the exhaustiveness check is what
            // would fail the build if the generated table ever grew a fourth.
            break
        case .narrow:
            printNarrow(scalar, breakClass: classification.graphemeBreakClass)
        case .wide:
            printWide(scalar, breakClass: classification.graphemeBreakClass)
        }
        rememberOpenCluster()
    }

    /// Rebuilds segmentation look-behind from the content the cursor immediately follows.
    private mutating func recoverClusterContextFromGridIfNeeded() -> Bool {
        guard clusterContext == nil,
              let target = screen.clusterPredecessor(columnCount: columnCount)
        else { return false }
        let scalars = screen.rows[target.row]
            .scalars(of: screen.rows[target.row].cells[target.column])
        guard let first = scalars.first else { return false }

        var previousClass = terminalUnicodeClassification(for: first).graphemeBreakClass
        var breakState = GraphemeBreakState()
        for scalar in scalars.dropFirst() {
            let nextClass = terminalUnicodeClassification(for: scalar).graphemeBreakClass
            _ = graphemeBreak(between: previousClass, and: nextClass, state: &breakState)
            previousClass = nextClass
        }
        clusterContext = ClusterContext(
            target: target,
            previousClass: previousClass,
            breakState: breakState,
            retainedUTF8ByteCount: scalars.reduce(0) {
                $0 + TerminalScalars.utf8ByteCount(of: $1)
            }
        )
        return true
    }

    /// Rebuilds the REP memory from the cell the open cluster context targets.
    ///
    /// The bulk writers call it because they stamp many cells and remember only the last, and the
    /// join path calls it only for a context the printer did not open -- the one case where the
    /// memory does not already say what the target holds. A cluster the printer opened is
    /// extended in place instead, which is what keeps a `k`-scalar cluster from being copied `k`
    /// times with growing length (`research/39/D8`).
    private mutating func rememberOpenCluster() {
        guard let context = clusterContext else { return }
        let cell = screen.rows[context.target.row].cells[context.target.column]
        lastPrintedCluster.cellWidth = cell.kind == .wideHead ? 2 : 1
        guard cell.word.isSpilled else {
            lastPrintedCluster.set(cell.word.inlineScalar)
            return
        }
        // The memory is moved out of `self` for the copy. Reading the row while
        // `lastPrintedCluster` is inout makes the compiler copy the whole row to keep the two
        // accesses apart, and that copy retains the row's cells and its arena for every scalar
        // printed -- 8% of `kitten-feed-unicode` before the two swaps.
        var memory = LastPrintedCluster()
        swap(&memory, &lastPrintedCluster)
        screen.rows[context.target.row].copyScalars(of: cell, into: &memory)
        swap(&memory, &lastPrintedCluster)
    }

    private mutating func appendToOpenClusterIfJoined(
        _ scalar: Unicode.Scalar,
        classification: TerminalUnicodeClassification,
        contextWasRecovered: Bool = false
    ) -> Bool {
        guard var context = clusterContext else { return false }
        var target = context.target
        guard screen.rows.indices.contains(target.row), screen.rows[target.row].cells.indices.contains(target.column) else {
            clusterContext = nil
            return false
        }
        guard screen.rows[target.row].cells[target.column].kind == .narrow
            || screen.rows[target.row].cells[target.column].kind == .wideHead
        else {
            clusterContext = nil
            return false
        }

        var nextBreakState = context.breakState
        guard graphemeBreak(
            between: context.previousClass,
            and: classification.graphemeBreakClass,
            state: &nextBreakState
        ) == false else {
            if contextWasRecovered {
                clusterContext = nil
            }
            return false
        }

        guard let baseScalar = screen.rows[target.row]
            .firstScalar(of: screen.rows[target.row].cells[target.column])
        else {
            clusterContext = nil
            return false
        }
        let scalarByteCount = TerminalScalars.utf8ByteCount(of: scalar)
        guard context.retainedUTF8ByteCount <= Self.graphemeClusterByteLimit - scalarByteCount else {
            context.previousClass = classification.graphemeBreakClass
            context.breakState = nextBreakState
            clusterContext = context
            rememberAdoptedCluster(context)
            return true
        }
        let desiredWidth = desiredClusterWidth(
            for: scalar,
            classification: classification,
            baseScalar: baseScalar
        )
        if desiredWidth != nil,
           desiredWidth != (screen.rows[target.row].cells[target.column].kind == .wideHead ? .wide : .narrow),
           clusterTargetCanChangeWidth(target) == false {
            context.previousClass = classification.graphemeBreakClass
            context.breakState = nextBreakState
            clusterContext = context
            rememberAdoptedCluster(context)
            return true
        }
        invalidateInspection(
            inViewportRows: target.row..<(target.row + 1),
            affectsPreviousProjection: target.column == 0
        )
        // The width the cell ends up with, when the join changes it. Taken from the branch that
        // changes it rather than read back off the cell, so a mirrored join reads no cell at all.
        var changedCellWidth: Int?
        switch desiredWidth {
        case .wide where screen.rows[target.row].cells[target.column].kind == .narrow:
            target = upgradeClusterToWide(at: target)
            changedCellWidth = 2
        case .narrow where screen.rows[target.row].cells[target.column].kind == .wideHead:
            downgradeClusterToNarrow(at: target)
            changedCellWidth = 1
        case .zero, .narrow, .wide, nil:
            break
        }

        context.target = target
        context.previousClass = classification.graphemeBreakClass
        context.breakState = nextBreakState
        context.retainedUTF8ByteCount += scalarByteCount
        clusterContext = context
        screen.rows[target.row].appendScalar(scalar, at: target.column)
        if context.memoryMirrorsTarget {
            lastPrintedCluster.extend(scalar)
            if let changedCellWidth { lastPrintedCluster.cellWidth = changedCellWidth }
        } else {
            rememberAdoptedCluster(context)
        }
        return true
    }

    /// Refreshes the REP memory after a join onto a cluster the memory does not already mirror.
    ///
    /// A mirroring memory needs nothing here: the two refusals -- the byte limit and a width
    /// change the cursor relationship forbids -- accept the scalar without changing the cell, and
    /// an accepted scalar extends the memory in place. An adopted context has no such guarantee,
    /// and REP after it must still repeat what the cell holds.
    private mutating func rememberAdoptedCluster(_ context: ClusterContext) {
        guard context.memoryMirrorsTarget == false else { return }
        rememberOpenCluster()
        clusterContext?.memoryMirrorsTarget = true
    }

    /// Restricts width changes to the cursor relationship created by uninterrupted printing.
    private func clusterTargetCanChangeWidth(_ target: CellPosition) -> Bool {
        guard target.row == screen.cursor.row else { return false }
        if screen.isPendingWrap {
            if screen.cursor == target { return true }
            return screen.rows[target.row].cells[target.column].kind == .wideHead
                && screen.cursor.column == target.column + 1
        }
        let width = screen.rows[target.row].cells[target.column].kind == .wideHead ? 2 : 1
        return screen.cursor.column == target.column + width
    }

    private func desiredClusterWidth(
        for scalar: Unicode.Scalar,
        classification: TerminalUnicodeClassification,
        baseScalar: Unicode.Scalar
    ) -> TerminalCellWidth? {
        // The one branch that can answer non-nil for a zero-width scalar, which is why
        // `stretchSegmentKind` keeps a variation selector out of a join segment.
        if TerminalUnicodeClassification.isVariationSelector(scalar) {
            guard terminalUnicodeProperties(for: baseScalar).isEmojiVariationBase else {
                return nil
            }
            return scalar.value == 0xFE0F ? .wide : .narrow
        }

        let properties = classification.properties
        guard properties.cellWidth != .zero, properties.isEmojiModifier == false else {
            return nil
        }
        switch classification.graphemeBreakClass {
        case .v, .t, .prepend:
            return nil
        default:
            return .wide
        }
    }

    private mutating func upgradeClusterToWide(at target: CellPosition) -> CellPosition {
        // Copied, not shared: the cluster outlives the cell it is read from, and the `place`
        // below grows the same row's arena.
        let scalars = screen.rows[target.row]
            .copiedScalars(of: screen.rows[target.row].cells[target.column])
        let styleId = screen.rows[target.row].cells[target.column].styleId
        let hyperlinkId = screen.rows[target.row].cells[target.column].hyperlinkId
        let contentIdentity = screen.rows[target.row].cells[target.column].contentIdentity
        let replacementStyleId = backgroundEraseStyleId()
        var destination = target

        if target.column == columnCount - 1 {
            if modes.isAutoWrapMode {
                clearCellAndPair(
                    row: target.row,
                    column: target.column,
                    replacementStyleId: replacementStyleId
                )
                screen.rows[target.row].cells[target.column] = GridCell(
                    styleId: styleId
                )
                screen.rows[target.row].isSoftWrapped = true
                screen.rows[target.row].marginProvenance = .wideWrap
                screen.cursor = target
                let advanced = advanceToNextRow(preservingWrapClaim: true)
                if advanced == false {
                    screen.rows[target.row].cells[target.column] = GridCell(
                        styleId: replacementStyleId
                    )
                    screen.rows[target.row].isSoftWrapped = false
                    screen.rows[target.row].marginProvenance = .content
                }
                screen.cursor.column = 0
                destination = screen.cursor
                invalidateInspection(
                    inViewportRows: destination.row..<(destination.row + 1),
                    affectsPreviousProjection: true
                )
                clearCellAndPair(
                    row: destination.row,
                    column: 0,
                    replacementStyleId: replacementStyleId
                )
                clearCellAndPair(
                    row: destination.row,
                    column: 1,
                    replacementStyleId: replacementStyleId
                )
            } else {
                destination.column = columnCount - 2
                clearCellAndPair(
                    row: target.row,
                    column: target.column,
                    replacementStyleId: replacementStyleId
                )
                clearCellAndPair(
                    row: destination.row,
                    column: destination.column,
                    replacementStyleId: replacementStyleId
                )
                clearCellAndPair(
                    row: destination.row,
                    column: destination.column + 1,
                    replacementStyleId: replacementStyleId
                )
            }
        } else {
            clearCellAndPair(
                row: target.row,
                column: target.column + 1,
                replacementStyleId: replacementStyleId
            )
        }

        screen.rows[destination.row].place(
            GridCell(
                kind: .wideHead,
                styleId: styleId,
                hyperlinkId: hyperlinkId,
                contentIdentity: contentIdentity
            ),
            scalars: scalars,
            at: destination.column
        )
        screen.rows[destination.row].cells[destination.column + 1] = GridCell(
            kind: .wideTail,
            styleId: styleId,
            hyperlinkId: hyperlinkId,
            contentIdentity: contentIdentity
        )
        if destination.column + 2 == columnCount {
            screen.rows[destination.row].marginProvenance = .content
        }
        advanceCursorPastWideCell(at: destination)
        return destination
    }

    private mutating func downgradeClusterToNarrow(at target: CellPosition) {
        let replacementStyleId = backgroundEraseStyleId()
        screen.rows[target.row].cells[target.column].kind = .narrow
        screen.rows[target.row].cells[target.column + 1] = GridCell(styleId: replacementStyleId)

        if screen.cursor.column == columnCount - 1 {
            screen.isPendingWrap = false
        } else {
            screen.cursor.column -= 1
        }
    }

    /// Issues the identity stamped on one printed cell, and owns what happens when the counter
    /// runs out.
    ///
    /// One identity per printed cell means 32 bits is a few minutes of maximal output, not a bound
    /// nobody reaches. Two things follow, and neither is free. Incrementing past the end traps.
    /// Wrapping past it reissues identities an arm taken before the wrap would accept as its own,
    /// which is the check `linkArmTracksRunIdentity` exists to enforce -- so the arm is dropped at
    /// the wrap rather than left holding an identity that no longer means what it did. Zero is
    /// skipped because `activationIdentity` reads it as "this run has no identity".
    private mutating func allocateContentIdentity() -> ContentIdentity {
        let identity = nextContentIdentity
        if nextContentIdentity == ContentIdentity.max {
            nextContentIdentity = 1
            armedLinkState = nil
        } else {
            nextContentIdentity += 1
        }
        return identity
    }

    private mutating func printNarrow(
        _ scalar: Unicode.Scalar,
        breakClass: GraphemeBreakClass
    ) {
        let contentIdentity = allocateContentIdentity()
        let replacementStyleId = backgroundEraseStyleId()
        invalidateInspection(
            inViewportRows: screen.cursor.row..<(screen.cursor.row + 1),
            affectsPreviousProjection: screen.cursor.column <= 1
        )
        if modes.isInsertMode {
            moveAndFillCells(
                in: screen.cursor.column..<columnCount,
                row: screen.cursor.row,
                by: 1
            )
        }
        prepareDestination(
            row: screen.cursor.row,
            columns: screen.cursor.column..<(screen.cursor.column + 1),
            replacementStyleId: replacementStyleId
        )
        writeNarrowCells(
            row: screen.cursor.row,
            column: screen.cursor.column,
            count: 1,
            baseIdentity: contentIdentity,
            breakClass: breakClass
        ) { _ in scalar }
    }

    private mutating func printWide(
        _ scalar: Unicode.Scalar,
        breakClass: GraphemeBreakClass
    ) {
        let contentIdentity = allocateContentIdentity()
        let replacementStyleId = backgroundEraseStyleId()
        invalidateInspection(
            inViewportRows: screen.cursor.row..<(screen.cursor.row + 1),
            affectsPreviousProjection: screen.cursor.column <= 1
        )
        if screen.cursor.column == columnCount - 1 {
            if modes.isAutoWrapMode {
                prepareDestination(
                    row: screen.cursor.row,
                    columns: screen.cursor.column..<(screen.cursor.column + 1),
                    replacementStyleId: replacementStyleId
                )
                screen.rows[screen.cursor.row].cells[screen.cursor.column] = GridCell(
                    styleId: currentStyleId()
                )
                screen.rows[screen.cursor.row].isSoftWrapped = true
                screen.rows[screen.cursor.row].marginProvenance = .wideWrap
                let gap = screen.cursor
                let advanced = advanceToNextRow(preservingWrapClaim: true)
                if advanced == false {
                    screen.rows[gap.row].cells[gap.column] = GridCell(
                        styleId: replacementStyleId
                    )
                    screen.rows[gap.row].isSoftWrapped = false
                    screen.rows[gap.row].marginProvenance = .content
                }
                screen.cursor.column = 0
            } else {
                screen.cursor.column = columnCount - 2
            }
        }

        invalidateInspection(
            inViewportRows: screen.cursor.row..<(screen.cursor.row + 1),
            affectsPreviousProjection: screen.cursor.column == 0
        )

        if modes.isInsertMode {
            moveAndFillCells(
                in: screen.cursor.column..<columnCount,
                row: screen.cursor.row,
                by: 2
            )
        }

        prepareDestination(
            row: screen.cursor.row,
            columns: screen.cursor.column..<(screen.cursor.column + 2),
            replacementStyleId: replacementStyleId
        )
        writeWideCells(
            row: screen.cursor.row,
            column: screen.cursor.column,
            count: 1,
            baseIdentity: contentIdentity,
            breakClass: breakClass
        ) { _ in scalar }
    }

    private mutating func advanceCursorPastWideCell(at head: CellPosition) {
        screen.cursor = CellPosition(row: head.row, column: head.column + 1)
        if screen.cursor.column == columnCount - 1 {
            screen.isPendingWrap = true
        } else {
            screen.cursor.column += 1
            screen.isPendingWrap = false
        }
    }

    private mutating func softWrap() {
        screen.rows[screen.cursor.row].isSoftWrapped = true
        let wrappedMark = screen.rows[screen.cursor.row].semanticPrompt
        let advanced = advanceToNextRow(preservingWrapClaim: true)
        screen.cursor.column = 0
        endSemanticContentAtEndOfLineIfArmed()
        // The new row is a non-head row of the wrapped line, so it takes the structural mark
        // the packer and the store give such a row -- not a mark derived from shell context,
        // which is what made a soft-wrapped `.output` line read differently once it
        // rematerialized. A declined advance stamps nothing: the cursor did not move.
        if advanced {
            screen.rows[screen.cursor.row].semanticPrompt = Self.continuationMark(forLineHead: wrappedMark)
        }
        screen.isPendingWrap = false
        clusterContext = nil
    }

    private mutating func lineFeed() {
        advanceToNextRow()
        stampSemanticContinuationAfterLineAdvance()
    }

    /// The hard-newline stamp: inside a prompt/input region a new line's head is marked
    /// `.continuation`, which is a fact about the shell's region, not about line structure
    /// (`continuationMark(forLineHead:)` is the structural rule a soft wrap uses).
    private mutating func stampSemanticContinuationAfterLineAdvance() {
        if endSemanticContentAtEndOfLineIfArmed() { return }
        if screen.semanticContent == .prompt || screen.semanticContent == .input {
            screen.rows[screen.cursor.row].semanticPrompt = .continuation
        }
    }

    /// OSC 133;I's "input ends at end of line": the first line advance after it returns the
    /// region to output. Returns whether it fired.
    @discardableResult
    private mutating func endSemanticContentAtEndOfLineIfArmed() -> Bool {
        guard screen.semanticContentClearsAtEndOfLine else { return false }
        screen.semanticContent = .output
        screen.semanticContentClearsAtEndOfLine = false
        return true
    }

    @discardableResult
    private mutating func advanceToNextRow(preservingWrapClaim: Bool = false) -> Bool {
        let region = activeScrollRegion
        // The advance can be declined outright: a cursor on the last screen row *below* the
        // region's bottom matches neither branch. Restoring a wrap claim then would stamp
        // `rows[cursor.row - 1]` -- a region-interior row the wrap never touched -- so the
        // restore runs only when the advance actually scrolled or moved. Reachable by
        // inline-viewport TUIs that pin a footer with `CSI 1;N r` and print below it.
        let advanced: Bool
        if screen.cursor.row == region.upperBound - 1 {
            moveAndFillRows(
                in: region,
                by: -1,
                pushesToScrollback: retainsRowsScrolledOffTop,
                preservesTrailingWrap: preservingWrapClaim,
                invalidatesInspection: false
            )
            advanced = true
        } else if screen.cursor.row < rowCount - 1 {
            screen.cursor.row += 1
            advanced = true
        } else {
            advanced = false
        }
        if preservingWrapClaim, advanced {
            restoreWrapClaimBeforeCursor()
        }
        return advanced
    }

    private var activeScrollRegion: Range<Int> {
        scrollRegion ?? 0..<rowCount
    }

    // xterm/kitty/Ghostty retain a row scrolled off the top whenever the region is
    // anchored at row 0 and spans the full width, even with a bottom margin set
    // (references/ghostty/src/terminal/Terminal.zig#index). Inline-viewport TUIs (codex's
    // ratatui composer) depend on it: they pin a footer with `CSI 1;N r` and scroll
    // their transcript out the top expecting it to land in scrollback. We implement
    // no DECSLRM left/right margins, so full width is trivially true. Applies only
    // to the two upward-scroll paths; mid-screen shuffles still discard.
    private var retainsRowsScrolledOffTop: Bool {
        activeScrollRegion.lowerBound == 0 && isAlternateScreenActive == false
    }

    private mutating func setScrollRegion(top topParameter: UInt16, bottom bottomParameter: UInt16) {
        let top = max(Int(topParameter), 1)
        let bottom = bottomParameter == 0
            ? rowCount
            : min(Int(bottomParameter), rowCount)
        // An invalid region is a complete no-op: neither the margins nor the cursor move.
        // xterm, kitty, ghostty, alacritty, and tmux all guard the whole body on
        // `bottom > top`; only libvterm resets to full screen and homes, and its own
        // suite asserts nothing for this case. See the finding-7 entry in
        // plans/impl/2026-08-05-0954-terminal-engine-improvement-findings.md.
        guard bottom > top else { return }

        let candidate = (top - 1)..<bottom
        scrollRegion = candidate == 0..<rowCount ? nil : candidate
        moveCursor(row: positioningOriginRow, column: 0)
    }

    private mutating func scrollUp(amount: Int) {
        clearPendingMotionState()
        moveAndFillRows(
            in: activeScrollRegion,
            by: -amount,
            pushesToScrollback: retainsRowsScrolledOffTop
        )
    }

    private mutating func scrollDown(amount: Int) {
        clearPendingMotionState()
        moveAndFillRows(in: activeScrollRegion, by: amount, pushesToScrollback: false)
    }

    private mutating func insertCharacters(amount: Int) {
        clearPendingMotionState()
        guard activeScrollRegion.contains(screen.cursor.row) else { return }
        moveAndFillCells(
            in: screen.cursor.column..<columnCount,
            row: screen.cursor.row,
            by: amount
        )
    }

    private mutating func deleteCharacters(amount: Int) {
        clearPendingMotionState()
        guard activeScrollRegion.contains(screen.cursor.row) else { return }
        moveAndFillCells(
            in: screen.cursor.column..<columnCount,
            row: screen.cursor.row,
            by: -amount
        )
    }

    private mutating func insertLines(amount: Int) {
        clearPendingMotionState()
        let region = activeScrollRegion
        guard region.contains(screen.cursor.row) else { return }
        moveAndFillRows(
            in: screen.cursor.row..<region.upperBound,
            by: amount,
            pushesToScrollback: false
        )
    }

    private mutating func deleteLines(amount: Int) {
        clearPendingMotionState()
        let region = activeScrollRegion
        guard region.contains(screen.cursor.row) else { return }
        moveAndFillRows(
            in: screen.cursor.row..<region.upperBound,
            by: -amount,
            pushesToScrollback: false
        )
    }

    private mutating func reverseIndex() {
        let region = activeScrollRegion
        if screen.cursor.row == region.lowerBound {
            moveAndFillRows(in: region, by: 1, pushesToScrollback: false)
        } else {
            screen.cursor.row = max(0, screen.cursor.row - 1)
        }
    }

    /// Visits `range` in the order that makes an overlapping in-place shift safe.
    ///
    /// This is memmove's direction rule, and it is the whole reason the two shift primitives
    /// below need no copy of the strip they are moving. Shifting right (`delta > 0`) reads
    /// behind the write head, so descending order guarantees a source is read before anything
    /// overwrites it; shifting left reads ahead of it, so ascending order does. Getting the
    /// direction wrong does not crash -- it silently duplicates one element across the strip,
    /// which is why `TerminalEditingTests` pins ICH, DCH, IL, and DL against overlapping
    /// moves with distinct per-position content.
    ///
    /// `body` receives the destination and the source to move from, or `nil` where the source
    /// falls outside `range` and the caller must fill instead.
    ///
    /// Static on purpose: `body` mutates the grid, so a method borrowing `self` here would be
    /// an exclusivity violation at every call site.
    private static func moveInPlace(
        _ range: Range<Int>,
        by delta: Int,
        amount: Int,
        _ body: (_ destination: Int, _ source: Int?) -> Void
    ) {
        func source(for destination: Int) -> Int? {
            let source = delta < 0 ? destination + amount : destination - amount
            return range.contains(source) ? source : nil
        }
        if delta > 0 {
            for destination in range.reversed() { body(destination, source(for: destination)) }
        } else {
            for destination in range { body(destination, source(for: destination)) }
        }
    }

    /// Records the damage one row scroll implies, at the site that knows the
    /// exact permutation (research/33 T9, direction D7): a `(region, delta)`
    /// shift plus O(1) rows -- the vacated strip, and the two rows the baked
    /// cursor touches -- instead of the whole moved range.
    ///
    /// The fallbacks are the contract's worst cases, never worse than the
    /// pre-shift representation. A non-following viewport escalates to `.full`
    /// as before. A move that vacates its whole range is plain range damage. An
    /// active overlay refuses translation: retained planner rows bake
    /// selection, search and hover into their runs, and only a whole-viewport
    /// scrollback push moves those anchors together with the content -- for it
    /// the shift stands; a non-pushing scroll falls back to range rows (the
    /// highlight must stay while content moves), and a partial-region push
    /// escalates to `.full` (stream anchors move against rows the shift does
    /// not translate).
    private mutating func recordScrollDamage(
        range: Range<Int>,
        delta signedAmount: Int,
        pushesToScrollback: Bool
    ) {
        notePrimaryHistoryDamage()
        guard viewportState == .following else {
            recordPresentationFullDamage()
            return
        }
        // The flood fast path: once pending damage already covers the whole
        // viewport, a further shift carries no information any consumer can
        // act on, and `.full` is the same value spelled in one bit -- which
        // restores the pre-shift zero-cost tail for the rest of a 16 KiB
        // delivery (the un-bumped advance makes the snapshot diff escalate and
        // early-return per action, exactly as it did before `T9`). The paced
        // regime never accumulates whole-viewport rows, so it never gets here.
        if damage.coversViewportIgnoringShift(rowCount: rowCount) {
            recordPresentationFullDamage()
            return
        }
        let amount = abs(signedAmount)
        if amount >= range.count {
            recordPresentationDamage(rows: range)
            return
        }
        if search != nil {
            recordPresentationFullDamage()
            return
        }
        let overlayActive = presentSelection != nil
            || InteractionLinkSlot.allCases.contains { self[$0] != nil }
        let wholeViewport = range == 0..<rowCount
        if overlayActive, pushesToScrollback == false {
            recordPresentationDamage(rows: range)
            return
        }
        if overlayActive, pushesToScrollback, wholeViewport == false {
            recordPresentationFullDamage()
            return
        }
        if damage.recordShift(region: range, delta: signedAmount) {
            pendingConsumerWork.noteDamageChanged()
        }
        if pushesToScrollback {
            scrollShiftAccountedAdvance.value &+= UInt64(amount)
        }
        let vacated = signedAmount < 0
            ? (range.upperBound - amount)..<range.upperBound
            : range.lowerBound..<(range.lowerBound + amount)
        recordPresentationDamage(rows: vacated)
        // The retained planner bakes the block cursor into its row's runs, so
        // the previous frame's cursor image rides the translation to
        // `cursor.row + delta` and the cursor's own row needs a fresh bake.
        // These two rows are D7's "at most two cursor rows above the ideal".
        if range.contains(screen.cursor.row) {
            recordPresentationDamage(row: screen.cursor.row)
            let translated = screen.cursor.row + signedAmount
            if range.contains(translated) {
                recordPresentationDamage(row: translated)
            }
        }
    }

    private mutating func moveAndFillRows(
        in range: Range<Int>,
        by delta: Int,
        pushesToScrollback: Bool,
        preservesTrailingWrap: Bool = false,
        invalidatesInspection: Bool = true
    ) {
        guard range.isEmpty == false, delta != 0 else { return }
        let amount = min(abs(delta), range.count)
        recordScrollDamage(
            range: range,
            delta: delta < 0 ? -amount : amount,
            pushesToScrollback: pushesToScrollback
        )
        if invalidatesInspection {
            invalidateInspectionState(inViewportRows: range)
        }
        let styleId = backgroundEraseStyleId()
        // The rotation is selected by the *shape* of the move -- the range covers the viewport --
        // and never by where the rows that leave end up. Disposal stays the separate decision it
        // has always been: a whole-viewport scroll that retains nothing (the alternate screen,
        // `SD`, a whole-viewport `IL`/`DL`) rotates just the same and discards just the same.
        let rotatesWholeViewport = range == 0..<rowCount
        let retainsEvictedRows = delta < 0 && pushesToScrollback

        if retainsEvictedRows {
            appendToScrollback(screen.rows[range.lowerBound..<(range.lowerBound + amount)])
        } else {
            severWrapClaim(before: range.lowerBound)
        }

        if rotatesWholeViewport {
            rotateViewportRows(by: delta, amount: amount, styleId: styleId)
        } else {
            Self.moveInPlace(range, by: delta, amount: amount) { destination, source in
                if let source {
                    let moved = screen.rows[source]
                    screen.rows[destination] = moved
                } else {
                    screen.rows[destination] = makeBlankRow(columns: columnCount, styleId: styleId)
                }
            }
        }

        let survivingCount = range.count - amount
        if survivingCount > 0, preservesTrailingWrap == false {
            let lastSurvivor = delta < 0
                ? range.lowerBound + survivingCount - 1
                : range.upperBound - 1
            severWrapClaim(at: lastSurvivor)
        }
        if delta < 0, pushesToScrollback {
            enforceScrollbackBudget()
        }
    }

    /// Moves `amount` rows from one end of the viewport to the other, resetting each one to a
    /// blank on the way (`research/39/H1`).
    ///
    /// The whole point of the deque: a whole-viewport scroll permutes the rows without touching
    /// any of them, so it copies no row value and -- because the row that leaves is the row that
    /// comes back as the blank -- allocates no row either. The general shift this replaces cost
    /// one row copy per surviving row plus one full-width allocation per vacated row, which is
    /// what `F1` measured under `advanceToNextRow`.
    ///
    /// Recycling is safe for the rows history just took: `LogicalLineStore.admit` copies the
    /// cells it wants into its arena and keeps no reference to the row it was given, so nothing
    /// but a retained copy of the terminal can still see this storage -- and that copy is what
    /// makes the reset copy on write.
    ///
    /// Only whole-viewport callers may use this. A partial region needs the neighbours outside
    /// it to stay where they are, which no rotation of the whole storage can do.
    private mutating func rotateViewportRows(by delta: Int, amount: Int, styleId: StyleId) {
        for _ in 0..<amount {
            var recycled = delta < 0 ? screen.rows.removeFirst() : screen.rows.removeLast()
            recycled.resetAsBlank(columns: columnCount, styleId: styleId)
            if delta < 0 {
                screen.rows.append(recycled)
            } else {
                screen.rows.prepend(recycled)
            }
        }
    }

    // Horizontal counterpart to moveAndFillRows: both primitives clip, shift intact storage
    // in place via `moveInPlace`, BCE-fill the vacated strip, and repair seams.
    private mutating func moveAndFillCells(
        in range: Range<Int>,
        row: Int,
        by delta: Int
    ) {
        guard range.isEmpty == false, delta != 0 else { return }
        invalidateInspection(
            inViewportRows: row..<(row + 1),
            affectsPreviousProjection: range.lowerBound <= 1
        )
        let amount = min(abs(delta), range.count)
        let styleId = backgroundEraseStyleId()

        let blank = GridCell(styleId: styleId)
        withRowCells(row) { cells in
            Self.moveInPlace(range, by: delta, amount: amount) { destination, source in
                if let source {
                    cells[destination] = cells[source]
                } else {
                    cells[destination] = blank
                }
            }
        }

        severWrapClaim(at: row)
        repairHorizontalMove(in: row, replacementStyleId: styleId)
    }

    private mutating func repairHorizontalMove(
        in row: Int,
        replacementStyleId: StyleId
    ) {
        let columns = columnCount
        // The scan borrows rather than binding the row's cells to a `let`: a binding would still
        // be alive at the repair loop below, so the first repair write would copy the whole row.
        var invalidColumns: [Int] = []
        readingRowCells(row) { cells in
            for column in cells.indices {
                switch cells[column].kind {
                case .wideHead:
                    if column + 1 >= columns || cells[column + 1].kind != .wideTail {
                        invalidColumns.append(column)
                    }
                case .wideTail:
                    if column == 0 || cells[column - 1].kind != .wideHead {
                        invalidColumns.append(column)
                    }
                case .padding, .narrow, .spacerHead:
                    break
                }
            }
        }

        guard invalidColumns.isEmpty == false else { return }
        let blank = GridCell(styleId: replacementStyleId)
        withRowCells(row) { cells in
            for column in invalidColumns {
                cells[column] = blank
            }
        }
    }

    private mutating func severWrapClaim(before row: Int) {
        if row > 0 {
            severWrapClaim(at: row - 1)
        } else if isAlternateScreenActive == false {
            severScrollbackWrapClaim()
        }
    }

    private mutating func severWrapClaim(at row: Int) {
        guard screen.rows.indices.contains(row) else { return }
        guard screen.rows[row].isSoftWrapped else { return }
        invalidateInspection(inViewportRows: row..<(row + 1))
        screen.rows[row].isSoftWrapped = false
        screen.rows[row].marginProvenance = .content
    }

    /// Ends the logical line history is still printing, which is `research/31/D2` operation 2.
    ///
    /// The store resolves any skipped margin from its wrap-time paint before closing the line.
    private mutating func severScrollbackWrapClaim() {
        guard history.store.hasOpenTailRecord else { return }
        invalidateInspection(inScrollbackRow: historyRowCount - 1)
        mutateHistory { $0.closeOpenRecord() }
    }

    private mutating func restoreWrapClaimBeforeCursor() {
        if screen.cursor.row > 0 {
            guard screen.rows[screen.cursor.row - 1].isSoftWrapped == false else { return }
            invalidateInspection(inViewportRows: (screen.cursor.row - 1)..<screen.cursor.row)
            screen.rows[screen.cursor.row - 1].isSoftWrapped = true
        } else if isAlternateScreenActive == false, historyRowCount > 0 {
            guard history.store.hasOpenTailRecord == false else { return }
            invalidateInspection(inScrollbackRow: historyRowCount - 1)
            mutateHistory { $0.reopenTailRecord() }
        }
    }

    static func rowContainsContent(_ row: GridRow) -> Bool {
        row.cells.contains { cell in
            cell.kind == .narrow || cell.kind == .wideHead
        }
    }

    /// Makes a range of one row's columns safe to overwrite wholesale, writing only *outside* it.
    ///
    /// What a print owes the grid before it stores belongs to the whole destination range, not to
    /// each column on its own: a wide pair straddling a boundary must stop claiming the partner
    /// the range is about to take, and the previous row's wrap spacer retires once. Columns inside
    /// the range are left untouched because the caller is about to store every one of them, so
    /// each printed cell is written exactly once.
    ///
    private mutating func prepareDestination(
        row: Int,
        columns: Range<Int>,
        replacementStyleId: StyleId
    ) {
        // Checking the two boundary columns is enough only because wide pairs are consistent -- a
        // `.wideHead` is always followed by its `.wideTail` -- so a partner the range severs can
        // only sit immediately outside it.
        let before = columns.lowerBound - 1
        if before >= 0, screen.rows[row].cells[before].kind == .wideHead {
            screen.rows[row].cells[before] = GridCell(styleId: replacementStyleId)
        }
        let after = columns.upperBound
        if after < columnCount, screen.rows[row].cells[after].kind == .wideTail {
            screen.rows[row].cells[after] = GridCell(styleId: replacementStyleId)
        }
    }

    /// Blanks one cell whose blank is load-bearing, severing the partner it may claim.
    ///
    /// This is `prepareDestination` over a one-column range plus the blank itself, so the partner
    /// rule has one spelling. The print path does not come here -- it prepares its range and then
    /// stores over it -- and what is left are the callers that need the cleared cell to stay
    /// cleared.
    private mutating func clearCellAndPair(
        row: Int,
        column: Int,
        replacementStyleId: StyleId
    ) {
        guard screen.rows.indices.contains(row), screen.rows[row].cells.indices.contains(column) else { return }
        prepareDestination(
            row: row,
            columns: column..<(column + 1),
            replacementStyleId: replacementStyleId
        )
        screen.rows[row].cells[column] = GridCell(styleId: replacementStyleId)
    }

}
