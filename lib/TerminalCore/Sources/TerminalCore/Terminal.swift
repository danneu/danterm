// Pure headless terminal reduction: byte ingestion, grid mutation, controls, and inspection.

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
/// guarantee. The transition invariants (I3 output floor, I5 geometry coherence, I6 redraw-mode
/// scope) are deliberately absent: they are proven by targeted behavioral tests that bracket the
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
        private(set) var title: PendingTerminalSemanticEvent?
        private(set) var workingDirectory: PendingTerminalSemanticEvent?
        private(set) var progress: PendingTerminalSemanticEvent?
        private(set) var discrete: [PendingTerminalSemanticEvent] = []
        private(set) var generation = ObservationGeneration()

        var hasWork: Bool {
            clipboardWrite != nil || title != nil || workingDirectory != nil
                || progress != nil || discrete.isEmpty == false
        }

        var retainedSemanticEventBytes: Int {
            (title?.byteCost ?? 0)
                + (workingDirectory?.byteCost ?? 0)
                + (progress?.byteCost ?? 0)
                + discrete.reduce(0) { $0 + $1.byteCost }
        }

        mutating func noteDamageChanged() {
            generation.value &+= 1
        }

        mutating func setClipboardWrite(_ value: String?) {
            guard clipboardWrite != value else { return }
            clipboardWrite = value
            generation.value &+= 1
        }

        mutating func setTitle(_ value: PendingTerminalSemanticEvent?) {
            guard title != value else { return }
            title = value
            generation.value &+= 1
        }

        mutating func setWorkingDirectory(_ value: PendingTerminalSemanticEvent?) {
            guard workingDirectory != value else { return }
            workingDirectory = value
            generation.value &+= 1
        }

        mutating func setProgress(_ value: PendingTerminalSemanticEvent?) {
            guard progress != value else { return }
            progress = value
            generation.value &+= 1
        }

        mutating func appendDiscrete(_ value: PendingTerminalSemanticEvent) {
            discrete.append(value)
            generation.value &+= 1
        }

        mutating func drainClipboardWrite() -> String? {
            defer { clipboardWrite = nil }
            return clipboardWrite
        }

        mutating func drainSemanticEvents() -> [TerminalSemanticEvent] {
            var events = discrete
            if let title { events.append(title) }
            if let workingDirectory { events.append(workingDirectory) }
            if let progress { events.append(progress) }
            events.sort { $0.order < $1.order }
            title = nil
            workingDirectory = nil
            progress = nil
            discrete.removeAll(keepingCapacity: true)
            return events.map(\.event)
        }
    }

    /// Indexes `hyperlinkTargets` from inside a cell. Narrow on purpose: an `Int?` here needs
    /// 8-byte alignment, which padded `GridCell` from 56 bytes to 72 -- so the field cost 16 bytes
    /// in every cell for a feature `15/F2` measured as unused in 100% of them. Two bytes fit in
    /// padding `TerminalStyle` already leaves behind, and the whole 16 bytes come back (doc 15's
    /// `D3`). The price is a finite id space, which is why `allocateHyperlinkId` recycles rather
    /// than counting up; see the invariant stated there.
    typealias HyperlinkId = UInt16

    /// Distinguishes one printed occurrence of a cell from a later reprint of the same text, so a
    /// link armed at pointer-down can reject a run recreated before release.
    ///
    /// 32-bit for the same reason `HyperlinkId` is 16-bit: an `Int?` cost 8 bytes and forced
    /// `GridCell` to 8-byte alignment, so narrowing it takes the cell from 56 bytes to 48 (doc
    /// 15's `H4`). The price is a counter that can exhaust in minutes of maximal output --
    /// `allocateContentIdentity` owns what happens then, and `15/F12` explains why the naive
    /// wrap is not safe.
    typealias ContentIdentity = UInt32

    /// Indexes `styleTable` from inside a cell, replacing the 19-byte `TerminalStyle` that used to
    /// sit inline in every one (doc 15's `H3`). `15/F11` measured 9-23 million style *writes* per
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

    /// Keeps scalar storage and wide-cell roles together for invariant-preserving mutation.
    ///
    /// Field order is load-bearing, not stylistic. Swift lays stored properties out in declaration
    /// order, and `scalars` is the only 8-byte-aligned member; declared after `kind` it forced
    /// seven bytes of padding into every cell. Leading with it recovers them, which is what takes
    /// the stride to 32 rather than 40 -- a whole malloc bucket at every width `15/F12` checked.
    struct GridCell: Equatable, Sendable {
        var scalars = TerminalScalars.empty
        var kind: TerminalCellKind = .padding
        var styleId: StyleId = Terminal.defaultStyleId
        var hyperlinkId: HyperlinkId?
        var contentIdentity: ContentIdentity?
    }

    /// Moves row-level wrap and semantic-prompt identity with cells during scrolling.
    struct GridRow: Equatable, Sendable {
        var cells: [GridCell]
        var isSoftWrapped = false
        var semanticPrompt = SemanticPromptRow.none

        /// Reads the logical row rather than exposing its physical storage extent.
        func cell(at column: Int) -> GridCell {
            precondition(column >= 0)
            return cells.indices.contains(column) ? cells[column] : GridCell()
        }

        /// Materializes the logical row for a consumer that requires full-width storage.
        func materialized(to columns: Int) -> GridRow {
            precondition(columns >= cells.count)
            guard cells.count < columns else { return self }
            var row = self
            row.cells.append(contentsOf: repeatElement(GridCell(), count: columns - cells.count))
            return row
        }

        /// Returns the canonical retained representation without default trailing padding.
        ///
        /// The independent statement of `I2`. `PackedRetainedRow.pack` applies the same trim
        /// as it encodes -- so nothing on the admission path calls this -- and the tests hold
        /// the two spellings equal. Keeping it is what makes that a comparison against a
        /// definition rather than against the encoder's own arithmetic.
        func compacted() -> GridRow {
            let lastStoredColumn = cells.lastIndex(where: { $0 != GridCell() }) ?? 0
            let storedCount = lastStoredColumn + 1
            guard storedCount < cells.count else { return self }
            var row = self
            row.cells = Array(cells.prefix(storedCount))
            return row
        }

        /// Writes anywhere in the logical row, materializing omitted padding first when needed.
        mutating func setCell(_ cell: GridCell, at column: Int, columns: Int) {
            precondition(column >= 0 && column < columns)
            if cells.count < columns {
                cells.append(contentsOf: repeatElement(GridCell(), count: columns - cells.count))
            }
            cells[column] = cell
        }
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
    private enum SemanticContent: Equatable, Sendable {
        case output
        case prompt
        case input
    }

    /// Selects the OSC 133 prompt range a capable shell promises to redraw.
    private enum PromptRedrawMode: Equatable, Sendable {
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
    /// (`17/F7`). The hovered link is therefore represented by a revision counter plus its
    /// projected range, which is all `recordDamage(from:to:)` ever needed. Keep it POD:
    /// adding a String, array, or class reference here reintroduces that cost.
    private struct DamageActionSnapshot {
        var cursor: TerminalCursor?
        var selection: TerminalTextRange?
        var searchMatch: TerminalTextRange?
        var hoveredLinkRange: TerminalTextRange?
        var hoveredLinkRevision: UInt64
        var topRow: Int
        var isFollowing: Bool
        var isAlternateScreenActive: Bool
        var cursorPresentation: TerminalPresentation
    }

    /// Gives retained rows logical zero-based indices while front eviction stays amortized O(1).
    ///
    /// Holds `PackedRetainedRow`, not `GridRow`: history is the only place doc 28's `C6`
    /// representation lives, and the buffer is the seam. Callers that want cells reach them
    /// through the packed row's own readers, or pay one `unpacked()` when they inherently
    /// read the whole row.
    private struct ScrollbackBuffer: Equatable, Sendable {
        private var storage: [PackedRetainedRow] = []
        private var storageStart = 0

        var count: Int { storage.count - storageStart }
        var isEmpty: Bool { count == 0 }
        var indices: Range<Int> { 0..<count }

        init() {}

        init<S: Sequence>(_ rows: S) where S.Element == GridRow {
            storage = rows.map { PackedRetainedRow.pack($0) }
        }

        subscript(position: Int) -> PackedRetainedRow {
            get {
                precondition(indices.contains(position))
                return storage[storageStart + position]
            }
            set {
                precondition(indices.contains(position))
                storage[storageStart + position] = newValue
            }
        }

        /// Reports how many rows this buffer still holds cell storage for. Equals `count` only
        /// while front eviction actually releases what it drops, which is the invariant it exists
        /// to prove; see doc 15's `F4` for the regression that motivated it.
        var retainedCellStorageRowCount: Int {
            storage.reduce(0) { $0 + ($1.storedCellCount == 0 ? 0 : 1) }
        }

        mutating func append(_ row: PackedRetainedRow) {
            storage.append(row)
        }

        /// Unpacks the whole retained stream. Reserved for consumers that inherently read
        /// all of history -- search, Select All, export, width reflow -- and never reached
        /// from a point query, which is what `activeProjection()` exists for.
        func asArray() -> [GridRow] {
            storage[storageStart...].map { $0.unpacked() }
        }

        func suffix(from index: Int) -> [GridRow] {
            precondition(indices.contains(index) || index == count)
            return storage[(storageStart + index)...].map { $0.unpacked() }
        }

        mutating func removeFirst() -> PackedRetainedRow {
            precondition(isEmpty == false)
            let row = storage[storageStart]
            // Release the evicted row's storage now rather than at the next compaction. A slot
            // below `storageStart` owns nothing: it is unreachable through every accessor here,
            // but its blob is a separate heap allocation that stays live while the slot holds it.
            // Since compaction will not run until dead slots outnumber live ones, skipping this
            // let history retain up to twice the rows it admitted (doc 15's `F4`).
            storage[storageStart] = PackedRetainedRow()
            storageStart += 1
            compactIfNeeded()
            return row
        }

        mutating func removeLast(_ count: Int) {
            precondition(count >= 0 && count <= self.count)
            storage.removeLast(count)
            if isEmpty {
                storage.removeAll(keepingCapacity: true)
                storageStart = 0
            }
        }

        mutating func removeAll(keepingCapacity: Bool) {
            storage.removeAll(keepingCapacity: keepingCapacity)
            storageStart = 0
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.count == rhs.count else { return false }
            return lhs.indices.allSatisfy { lhs[$0] == rhs[$0] }
        }

        private mutating func compactIfNeeded() {
            if storageStart == storage.count {
                storage.removeAll(keepingCapacity: false)
                storageStart = 0
                return
            }
            guard storageStart >= 1_024, storageStart * 2 >= storage.count else { return }
            storage = Array(storage[storageStart...])
            storageStart = 0
        }
    }

    /// Indexed view of the active text projection -- retained scrollback followed by the live
    /// rows -- so a point-local query reads only the rows it touches instead of materializing a
    /// copy of the whole retained stream on every pointer event.
    ///
    /// Owns the alternate-screen seam rule, which is the one place the projection is not a plain
    /// concatenation: while the alternate grid is active, the last scrollback row cannot soft-wrap
    /// into the alternate rows appended after it. Keeping the rule here is what lets an indexed
    /// reader match the materialized projection row for row.
    ///
    /// Constructing one is O(1): both row collections are copy-on-write and nothing here mutates
    /// them, so the whole type is two retained buffers and a flag.
    private struct ProjectionRows: RandomAccessCollection {
        private let scrollback: ScrollbackBuffer
        private let live: [GridRow]
        private let isAlternateScreenActive: Bool

        init(scrollback: ScrollbackBuffer, live: [GridRow], isAlternateScreenActive: Bool) {
            self.scrollback = scrollback
            self.live = live
            self.isAlternateScreenActive = isAlternateScreenActive
        }

        var startIndex: Int { 0 }
        var endIndex: Int { scrollback.count + live.count }

        subscript(position: Int) -> GridRow {
            guard position < scrollback.count else {
                return live[position - scrollback.count]
            }
            var row = scrollback[position].unpacked()
            if isAlternateScreenActive, position == scrollback.count - 1 {
                row.isSoftWrapped = false
            }
            return row
        }
    }

    /// Tracks cursor coordinates without exposing storage indices.
    private struct CellPosition: Equatable, Sendable {
        var row: Int
        var column: Int
    }

    /// Keeps inspection state stable while rows migrate between viewport and scrollback.
    fileprivate struct TextAnchor: Equatable, Comparable, Sendable {
        var row: Int
        var column: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.row < rhs.row || (lhs.row == rhs.row && lhs.column < rhs.column)
        }
    }

    /// Represents a half-open selection or match in absolute retained-row coordinates.
    fileprivate struct TextAnchorRange: Equatable, Sendable {
        var start: TextAnchor
        var end: TextAnchor
    }

    /// Counts the events after which an absolute retained row no longer names the text it
    /// named -- a hard reset, a width reflow, a screen replacement.
    ///
    /// Kept out of value equality like `ObservationGeneration`, and for the same reason: two
    /// terminals holding identical screen state are the same value however each got there.
    /// What it identifies is outstanding `PinnedTextRange`s, not the state.
    private struct RowNumberingEpoch: Equatable, Sendable {
        var value: UInt64 = 0

        static func == (_ lhs: Self, _ rhs: Self) -> Bool { true }
    }

    /// A text range a caller can hold across terminal mutations, readable only through
    /// `resolvedRange(_:)`.
    ///
    /// Exists for the in-flight drag anchor, the one coordinate the pointer policy must keep
    /// from one event to the next. `TerminalTextPosition` counts rows from the oldest
    /// *retained* row, so eviction restates every such value the instant it happens and a
    /// stored one silently names lower and lower text. Opaque on purpose: a caller that could
    /// read the rows back could also restate the eviction clamp `Terminal` already applies,
    /// and drift from it.
    struct PinnedTextRange: Equatable, Sendable {
        fileprivate let range: TextAnchorRange
        // The raw counter, not a `RowNumberingEpoch`: that type's `==` answers true so the
        // epoch stays out of `Terminal`'s value equality, which would silently make every
        // stale pin compare and resolve as current.
        fileprivate let epoch: UInt64

        // Written out rather than synthesized: synthesis would inherit the stored properties'
        // fileprivate access, leaving the pointer policy's own `Equatable` unsatisfiable.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.range == rhs.range && lhs.epoch == rhs.epoch
        }
    }

    /// Keeps bottom-follow policy explicit when a browsing anchor becomes bottom-aligned.
    private enum ViewportState: Equatable, Sendable {
        case following
        case browsing(top: TextAnchor)
    }

    /// Stores only the active query and occurrence so navigation always rescans live text.
    ///
    /// `range` is nil while the query matches nothing. That state is deliberately distinct
    /// from `search == nil`: a needle the user typed that found nothing is still an active
    /// search reporting an empty status, whereas no search state at all reports none.
    private struct SearchState: Equatable, Sendable {
        var query: String
        var range: TextAnchorRange?
    }

    /// Memoizes the open needle's whole-history match list, keyed by the needle itself.
    ///
    /// Exists because every navigation step rescanned all of history twice -- once in
    /// `searchNext`/`searchPrevious` and again in `searchStatus` -- which at a saturated
    /// 10 MiB scrollback priced one keypress above the owner queue's whole budget for it.
    /// Selecting a different occurrence does not change which occurrences exist, so the
    /// list survives navigation and only content invalidates it.
    ///
    /// Never part of value equality: `TerminalPTYHost.applySearch` publishes a frame when
    /// `terminal != previousTerminal`, and filling a cache is not a change any consumer
    /// can observe. Sharing `ObservationGeneration`'s always-equal shape for that reason.
    private struct SearchMatchCache: Equatable, Sendable {
        private var query: String?
        private var stored: [TextAnchorRange] = []

        func matches(for query: String) -> [TextAnchorRange]? {
            self.query == query ? stored : nil
        }

        mutating func store(_ matches: [TextAnchorRange], for query: String) {
            self.query = query
            stored = matches
        }

        mutating func invalidate() {
            query = nil
            stored = []
        }

        static func == (_ lhs: Self, _ rhs: Self) -> Bool { true }
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

    /// Keeps search comparison allocation-free for the common one-scalar key while
    /// retaining full folded expansions for Unicode graphemes that need them.
    private enum SearchGraphemeKey: Equatable {
        case scalar(UInt32)
        case scalars([Unicode.Scalar])
    }

    /// Reuses cursor reflow keys and logical-line boundaries for inspection anchors.
    private enum ReflowTextAttachment {
        case cell(key: Int, width: Int, usesStart: Bool)
        case lineStart(Int)
        case lineEnd(Int)
    }

    /// Keeps the one DECSC slot independent from live cursor and mode mutation.
    private struct SavedCursorState: Equatable, Sendable {
        var position = CellPosition(row: 0, column: 0)
        var style = TerminalStyle()
        var isPendingWrap = false
        var isOriginMode = false
        var isCursorVisible = true
        var cursorShape = TerminalCursorShape.block
        var isCursorBlinking = false
    }

    /// Keeps REP independent from later cursor movement and grid replacement.
    private struct LastPrintedCluster: Equatable, Sendable {
        var scalars: TerminalScalars
        var cellWidth: Int
    }

    /// Retains exactly the target and pairwise look-behind for one open grapheme cluster.
    private struct ClusterContext: Equatable, Sendable {
        var target: CellPosition
        var previousClass: GraphemeBreakClass
        var breakState = GraphemeBreakState()
    }

    /// Retains primary cells and resize-only cursor semantics while the alternate grid is active.
    private struct InactivePrimaryScreen: Equatable, Sendable {
        var rows: [GridRow]
        var resizeCursor: CellPosition
        var isResizePendingWrap: Bool
        var semanticContent: SemanticContent
        var semanticContentClearsAtEndOfLine: Bool
    }

    /// Carries one atomic cell unit and the old coordinates that must follow it.
    private struct ReflowUnit {
        var cells: [GridCell]
        var sourceOffsets: [(key: Int, offset: Int)]
    }

    /// Reconstructs one hard-delimited logical line and its prompt marker during reflow.
    private struct ReflowLine {
        var units: [ReflowUnit] = []
        var semanticPrompt = SemanticPromptRow.none
    }

    /// Relates an old visual row to its transient logical line and boundary.
    private struct ReflowRowMetadata {
        var line: Int
        var boundaryOffset: Int
        var retainedEnd: Int
        var firstSourceKey: Int?
    }

    /// Distinguishes cursor meanings that require different resize attachment rules.
    private enum ReflowCursorAnchor {
        case cell(key: Int)
        case trailingPadding(line: Int, distance: Int, allPaddingColumn: Int?)
        case boundary(line: Int, offset: Int)
    }

    /// Records a cursor destination before the rebuilt stream is split into regions.
    private struct ReflowDestination {
        var row: Int
        var column: Int
        var isPendingWrap: Bool
    }

    /// Holds one packed logical line and the attachment lookup produced with it.
    private struct PackedReflowLine {
        var rows: [GridRow]
        var cellDestinations: [Int: ReflowDestination]
        var boundaryDestinations: [Int: ReflowDestination]
        var contentEnd: ReflowDestination
    }

    private var columnCount: Int
    private var rowCount: Int
    private var scrollbackRows = ScrollbackBuffer()
    private var rows: [GridRow]
    private var inactivePrimaryScreen: InactivePrimaryScreen?
    private var scrollRegion: Range<Int>?
    private var cursor = CellPosition(row: 0, column: 0)
    private var isPendingWrap = false
    private var semanticContent = SemanticContent.output
    private var semanticContentClearsAtEndOfLine = false
    private var promptRedrawMode = PromptRedrawMode.full
    private var isInsertMode = false
    private var isLineFeedNewLineMode = false
    private var isApplicationCursorKeysMode = false
    private var isApplicationKeypadMode = false
    private var isFocusReportingMode = false
    private var isBracketedPasteMode = false
    private var mouseTrackingMode = TerminalMouseTrackingMode.off
    private var isSGRMouseEncodingMode = false
    private var isOriginMode = false
    private var isAutoWrapMode = true
    private var isCursorVisible = true
    private var cursorShape = TerminalCursorShape.block
    private var isCursorBlinking = false
    private var isSynchronizedOutputActive = false
    private var tabStops: Set<Int>
    private var savedCursor = SavedCursorState()
    private var lastPrintedCluster: LastPrintedCluster?
    private var clusterContext: ClusterContext?
    private var inputStream = TerminalInputStream()
    private var replyBytes: [UInt8] = []
    private var programVersion: String
    private var defaultColors: TerminalDefaultColors
    private var primaryKittyKeyboardStack: [UInt16] = []
    private var alternateKittyKeyboardStack: [UInt16] = []
    private var evictedRowCount = 0
    private var rowNumberingEpoch = RowNumberingEpoch()
    // The four inspection fields below are read together, per printed character, by
    // `invalidateInspection`, whose guard rejects whenever all four are nil -- the state of
    // every run with no selection, search, hover, or armed link. Each observer keeps
    // `hasInteractionState` exact so that guard is one Bool load instead of four optional
    // loads. Maintaining it here rather than at the call sites is what makes it undriftable:
    // `didSet` fires for in-place mutation (`selection.start.column = ...`) as well as for
    // whole-value assignment, so no future write can bypass it.
    private var selection: TextAnchorRange? { didSet { refreshHasInteractionState() } }
    private var search: SearchState? { didSet { refreshHasInteractionState() } }
    private var searchMatchCache = SearchMatchCache()
    private var hoveredLinkState: InteractionLinkState? {
        didSet {
            refreshHasInteractionState()
            hoveredLinkRevisionCounter.value &+= 1
        }
    }
    private var armedLinkState: InteractionLinkState? { didSet { refreshHasInteractionState() } }

    /// Counts writes to `hoveredLinkState` so `DamageActionSnapshot` can notice a hover
    /// change without copying the link's refcounted target -- the whole point of `17/F7`.
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

    /// Caches `selection`/`search`/`hoveredLinkState`/`armedLinkState` being non-nil.
    ///
    /// Derived state, never assigned directly: the four observers above are its only writer.
    /// `false` is correct at initialization because all four fields start nil and property
    /// observers do not fire during initialization.
    private var hasInteractionState = false
    private var viewportState = ViewportState.following
    private var damage: TerminalDamageAccumulator
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
    private var currentWorkingDirectory: String?
    private var titleUsesWorkingDirectory = false
    private var pendingConsumerWork = PendingConsumerWork()
    private var nextSemanticEventOrder: UInt64 = 0
    private var primaryHistoryObservation = ObservationGeneration()

    /// The retained-history byte bound: the valve for rows whose bytes the cell cap cannot see.
    ///
    /// Raised from 10 MiB to 16 MiB by doc 28's `D11`, because the two caps below no longer fit
    /// under the old budget. `F23` measured a full-width retained row at 179 columns costing
    /// **1,552 charged B/row**, so `D11`'s target depth needs `89,500 x 1,552` ~ 14.8 MiB and at
    /// 10 MiB the *byte* bound bound first, stopping a full-width fill at 6,756 rows. 16 MiB is
    /// that measured requirement plus headroom, not a round number chosen first.
    ///
    /// This is a per-pane figure, and `D11` is a trial: it gives back most of the 3.72 MB
    /// retained footprint `D10` banked. Read `D11` before treating it as settled.
    ///
    /// Public so measurement tools can report the budget they ran against. Deliberately just the
    /// constant: the budget-taking initializer stays internal, because the public initializer
    /// enforcing this fixed value is an invariant with its own test.
    public static let productionScrollbackBudgetBytes = 16_777_216

    /// The retained-history cell bound, and the one that actually bounds a resize.
    ///
    /// Reflow cost is two-term. Doc 28's `D8` fits it at **1.85 us/row + 0.352 us/cell** on the
    /// packed representation, across three content regimes, and the cell term dominates at any
    /// real pane width. Being denominated in *content* is what makes this bound safe under
    /// reflow: rewrapping a row moves stored cells between rows but does not create or destroy
    /// them, so a narrow-then-widen cycle evicts nothing. A row cap alone does not have that
    /// property -- see `productionScrollbackRowCap`.
    ///
    /// **What sizes it now is a depth target, not the resize budget.** Through `D8` this value
    /// was 327,680, derived so that the simultaneous worst case fit `D8`'s ~150 ms budget (1.5x
    /// the 99.5 ms pre-packing baseline). `D11` reopens that budget by explicit human choice and
    /// sizes the cap from `F23`'s candidate (b) instead: **10,000 retained rows of full-width
    /// content at 179 columns**, i.e. `10,000 x 179 = 1,790,000` stored cells. The old
    /// derivation does not produce this number and is no longer what justifies it.
    ///
    /// The price is measured, not modelled away. `F23` timed a saturated resize at this cap and
    /// row cap at **600.5 ms** (min 594.1, max 632.9) -- 6.04x the 99.5 ms baseline and 4.00x
    /// `D8`'s budget. That cost is accepted *provisionally*, for a dogfood trial with an exit
    /// condition; `D11` states the trial and the three ways out of it. Nothing here supersedes
    /// `D8`'s cost model, which still predicts this correctly (it overreads by 7.7-12.0%).
    public static let productionScrollbackCellCap = 1_790_000

    /// The retained-history row bound: a backstop for content the cell cap cannot see.
    ///
    /// The cell cap bounds the dominant reflow term but is blind to the degenerate regime `F9`
    /// describes -- a retained row can hold ~zero stored cells (a blank line costs 80 B and
    /// stores nothing), so a history of blank rows would satisfy any cell cap while making row
    /// count, and with it the `1.85 us/row` term, unbounded.
    ///
    /// Sized to hold the losslessness property below against the cell cap, rather than chosen as
    /// a round number: `cellCap / 20` = `1,790,000 / 20` = **89,500**. Through `D8` the same
    /// ratio fell out of the resize budget (16,384 against a 327,680 cell cap); under `D11` the
    /// cell cap is sized from a depth target instead, and this cap follows it to keep the ratio
    /// at 20. It sits far above the 1,000-10,000 rows every mainstream terminal defaults to
    /// (`xterm` 1,024, `foot` 1,000, `kitty` 2,000, `tmux` 2,000, `alacritty` 10,000).
    ///
    /// **The one place this bound is lossy.** Narrowing a pane multiplies row count while
    /// leaving cells alone, so below `cellCap / rowCap` = 20 columns the row cap can bind on the
    /// way down and evict content that widening cannot restore. Above 20 columns the cell cap
    /// holds row count low enough that rewrapping never reaches this bound, which is what
    /// `narrowThenWidenPreservesCappedHistory` pins. Raising `rowCap` to make even a 10-column
    /// pane lossless would cost the cell cap most of its budget, and `D8` takes the trade
    /// deliberately rather than by omission.
    ///
    /// The ratio is not cosmetic, and `F23` measured what breaking it costs: the same cell cap
    /// with `rowCap` left at 10,000 (ratio 179) looks cheaper to resize -- 296.3 ms -- but the
    /// first narrowing to 100 columns **evicted 5,032 of its 10,000 rows**. A row cap set to the
    /// depth target rather than to `cellCap / 20` does not hold that depth.
    ///
    /// Public for the same reason the budget is: measurement tools report the bound they ran
    /// against, and the public initializer enforcing this value is an invariant with its own test.
    public static let productionScrollbackRowCap = 89_500
    static let kittyKeyboardStackDepth = 8
    static let maximumHyperlinkTargetBytes = 65_536

    /// Reserved for `TerminalStyle()`. Fixed so an unwritten cell costs no intern and no lookup.
    static let defaultStyleId: StyleId = 0

    /// Smallest table size worth a sweep. Well above the 1-5 distinct styles `15/F11` measured in
    /// ordinary output, so a normal session never sweeps at all.
    static let baseStyleSweepThreshold = 512
    static let maximumTerminalMetadataBytes = 256 * 1_024
    static let maximumSemanticValueBytes = 64 * 1_024
    static let maximumShellOSCBytes = 88 * 1_024
    static let maximumDiscreteSemanticEvents = 100
    static let maximumReplyBytes = 64 * 1_024

    /// Exposes aggregate retained link cost to structural bound tests.
    var retainedHyperlinkMetadataBytes: Int {
        hyperlinkTargets.values.reduce(0) { $0 + hyperlinkByteCost($1) }
            + (hoveredLinkState.map { hyperlinkByteCost($0.hyperlink) } ?? 0)
            + (armedLinkState.map { hyperlinkByteCost($0.hyperlink) } ?? 0)
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
    private(set) var scrollbackBudgetBytes: Int

    /// The active row cap. See `productionScrollbackRowCap` for why there are three bounds.
    private(set) var scrollbackRowCap: Int

    /// The active cell cap. See `productionScrollbackCellCap`.
    private(set) var scrollbackCellCap: Int

    /// Caches retained stored cells so the line-feed path never re-walks history to enforce the
    /// cell cap. Maintained exactly like `scrollbackByteCount`, at the same two sites.
    private(set) var scrollbackStoredCellCount = 0

    /// Caches retained-row cost so the line-feed path never scans full history.
    private(set) var scrollbackByteCount = 0

    /// Records whether eviction severed the retained stream inside a logical line.
    public private(set) var isHistoryHeadTruncated = false

    /// Exposes the semantic SGR pen without allowing callers to mutate terminal state.
    ///
    /// The `didSet` is what keeps `H3` cheap. Every cell write sources its style from this pen or
    /// from `backgroundEraseStyle`, so interning can happen once per *pen change* -- thousands of
    /// times per corpus -- rather than once per *cell write*, which `15/F11` counted in the tens of
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
            isCursorVisible: isCursorVisible,
            cursorShape: cursorShape,
            isCursorBlinking: isCursorBlinking,
            isSynchronizedOutputActive: isSynchronizedOutputActive
        )
    }

    /// Lets the serialized PTY owner route semantic wheel intent without a lagging snapshot,
    /// and is the one way this file asks which screen is active. Matches the optional's tag in
    /// place instead of comparing it against `nil`: `InactivePrimaryScreen` is `Equatable` and
    /// holds a row array, so `== nil` resolves to the generic two-operand `==`, which copies
    /// both operands -- retaining and releasing that array -- to answer a question about
    /// nothing but whether the optional is populated. The feed path asks it several times per
    /// action, and the resulting pair of comparison temporaries was 22.5% of the live app's
    /// PTY-host thread.
    public var isAlternateScreenActive: Bool {
        if case .some = inactivePrimaryScreen { return true }
        return false
    }

    /// Projects all child-controlled modes that affect deterministic user-input bytes.
    public var inputModes: TerminalInputModes {
        TerminalInputModes(
            applicationCursorKeys: isApplicationCursorKeysMode,
            applicationKeypad: isApplicationKeypadMode,
            lineFeedNewLine: isLineFeedNewLineMode,
            focusReporting: isFocusReportingMode,
            bracketedPaste: isBracketedPasteMode,
            mouseTracking: mouseTrackingMode,
            sgrMouseEncoding: isSGRMouseEncodingMode,
            kittyKeyboardFlags: activeKittyKeyboardStack.last ?? 0
        )
    }

    /// Exposes terminal-generated bytes until the serialized host routes them to the child.
    public var pendingReplyBytes: [UInt8] {
        replyBytes
    }

    /// Reports whether a frame consumer has redraw work or a completed semantic write to drain.
    public var hasPendingConsumerWork: Bool {
        damage.hasDamage || pendingConsumerWork.hasWork
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

    private var damageActionSnapshot: DamageActionSnapshot {
        let projection = scrollProjection
        let cursorStreamRow = isAlternateScreenActive
            ? cursor.row
            : scrollbackRows.count + cursor.row
        let cursorWindowRow = cursorStreamRow - projection.topRow
        return DamageActionSnapshot(
            cursor: (0..<rowCount).contains(cursorWindowRow)
                ? TerminalCursor(
                    row: cursorWindowRow,
                    column: cursor.column,
                    isPendingWrap: isPendingWrap
                )
                : nil,
            selection: selectionRange,
            searchMatch: activeSearchMatchRange,
            hoveredLinkRange: hoveredLinkState.flatMap { publicRange($0.range) },
            hoveredLinkRevision: hoveredLinkRevisionCounter.value,
            topRow: projection.topRow,
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
    /// snapshot-visible state breaks that, and no test would catch it (see F8 in
    /// `docs/research/10-terminal-feed-hotspots.md`); it belongs at the call site instead.
    private mutating func recordDamage(
        from before: DamageActionSnapshot,
        to after: DamageActionSnapshot
    ) {
        if before.isFollowing == false {
            recordPresentationFullDamage()
            return
        }
        guard before.topRow == after.topRow,
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
        if before.searchMatch != after.searchMatch {
            recordPresentationDamage(rows: damagedViewportRows(for: before.searchMatch))
            recordPresentationDamage(rows: damagedViewportRows(for: after.searchMatch))
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
        recordPresentationDamage(row: row)
        notePrimaryHistoryDamage()
    }

    private mutating func recordDamage(rows: some Sequence<Int>) {
        recordPresentationDamage(rows: rows)
        notePrimaryHistoryDamage()
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
        // Deliberately above the alternate-screen guard, and deliberately here rather than
        // at the invalidation sites: the comment above `recordPresentationFullDamage` makes
        // this the funnel every cell-storage write reaches and the non-bumping variants the
        // narrow exception, so hanging the match cache here inherits its fail-safe
        // direction -- a miscategorized call site costs a redundant rescan, never a stale
        // answer. The guard below is about primary-history recovery, which the alternate
        // screen genuinely does not affect; a search scanned under the alternate screen
        // reads that screen's rows, so its cache must drop on both.
        searchMatchCache.invalidate()
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
        func collect(_ rows: [GridRow], into live: inout Set<StyleId>) {
            for row in rows {
                for cell in row.cells { live.insert(cell.styleId) }
            }
        }
        collect(scrollbackRows.asArray(), into: &live)
        collect(rows, into: &live)
        if let inactivePrimaryScreen { collect(inactivePrimaryScreen.rows, into: &live) }
        return live
    }

    /// Drops table entries no cell points at, on the same invariant `allocateHyperlinkId` states:
    /// **every id held by a cell is a key of `styleTable`**. `liveStyleIds` walks history, the
    /// active grid, and the retained primary screen, which is every place a cell lives; the pens
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

    /// Rejects dimensions that cannot represent all supported terminal cells.
    public init?(
        columns: Int,
        rows: Int,
        machineHostname: String? = nil,
        programVersion: String = "dev",
        defaultColors: TerminalDefaultColors = .baked
    ) {
        self.init(
            columns: columns,
            rows: rows,
            scrollbackBudgetBytes: Self.productionScrollbackBudgetBytes,
            scrollbackRowCap: Self.productionScrollbackRowCap,
            scrollbackCellCap: Self.productionScrollbackCellCap,
            machineHostname: machineHostname,
            programVersion: programVersion,
            defaultColors: defaultColors
        )
    }

    /// Gives deterministic tests a small budget while production remains fixed at 10 MiB.
    ///
    /// `scrollbackRowCap` defaults to the production cap rather than to "unbounded": a test that
    /// asks for a small budget is asking to reach the *byte* bound sooner, not to opt out of the
    /// row bound, and defaulting it away would let a fixture retain a depth production never can.
    init?(
        columns: Int,
        rows: Int,
        scrollbackBudgetBytes: Int,
        scrollbackRowCap: Int = Terminal.productionScrollbackRowCap,
        scrollbackCellCap: Int = Terminal.productionScrollbackCellCap,
        machineHostname: String? = nil,
        programVersion: String = "dev",
        defaultColors: TerminalDefaultColors = .baked
    ) {
        guard columns >= 2, rows >= 1, scrollbackBudgetBytes >= 0, scrollbackRowCap >= 0,
            scrollbackCellCap >= 0
        else {
            return nil
        }
        columnCount = columns
        rowCount = rows
        self.scrollbackBudgetBytes = scrollbackBudgetBytes
        self.scrollbackRowCap = scrollbackRowCap
        self.scrollbackCellCap = scrollbackCellCap
        self.machineHostname = machineHostname
        self.programVersion = programVersion
        self.defaultColors = defaultColors
        tabStops = Self.defaultTabStops(columns: columns)
        damage = TerminalDamageAccumulator(rowCount: rows, isFull: true)
        self.rows = (0..<rows).map { _ in
            GridRow(cells: (0..<columns).map { _ in GridCell() })
        }
    }

    /// Updates protocol-visible defaults without treating configuration as grid damage.
    public mutating func setDefaultColors(_ colors: TerminalDefaultColors) {
        defaultColors = colors
    }

    /// Reduces a byte chunk synchronously while retaining unfinished stream state.
    public mutating func feed(_ bytes: [UInt8]) {
        let actions = inputStream.feed(bytes)
        guard actions.isEmpty == false else { return }
        // One snapshot per action, not two. Action N's "after" is bit-for-bit what action N+1
        // would capture as its "before" -- nothing runs between them, and `recordDamage` writes
        // only damage bookkeeping, which the snapshot does not read -- so carrying it forward is
        // the same diff sequence at half the construction cost.
        var before = damageActionSnapshot
        for action in actions {
            switch action {
            case let .print(scalar):
                print(scalar)
            case let .execute(control):
                if control == 0x07 {
                    admitDiscreteSemanticEvent(.bell)
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
            }
            let after = damageActionSnapshot
            recordDamage(from: before, to: after)
            before = after
        }
    }

    private mutating func dispatchOSC(_ payload: [UInt8]) {
        guard let selectorEnd = payload.firstIndex(of: 0x3B), selectorEnd > payload.startIndex,
              let selector = parseOSCSelector(payload[..<selectorEnd])
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
        appendReply("\u{1B}]\(selector);rgb:\(oscColorComponent(color.red))/"
            + "\(oscColorComponent(color.green))/\(oscColorComponent(color.blue))\u{1B}\\")
    }

    private func oscColorComponent(_ component: UInt8) -> String {
        let digits = Array("0123456789abcdef".utf8)
        let high = digits[Int(component >> 4)]
        let low = digits[Int(component & 0x0F)]
        return String(decoding: [high, low, high, low], as: UTF8.self)
    }

    private mutating func dispatchOSC133(_ payload: [UInt8], selectorEnd: Int) {
        let command = Array(payload[payload.index(after: selectorEnd)...])
        guard let action = command.first else { return }
        if action == 0x4C { // L takes no options.
            guard command.count == 1 else { return }
        } else {
            guard [0x41, 0x42, 0x49, 0x43, 0x44, 0x4E, 0x50].contains(action),
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
            semanticContent = .input
            semanticContentClearsAtEndOfLine = false
        case 0x49: // I
            semanticContent = .input
            semanticContentClearsAtEndOfLine = true
        case 0x43: // C
            semanticContent = .output
            semanticContentClearsAtEndOfLine = false
            // Stamp even when output starts partway through the prompt row: the row now
            // holds output and must stop every later prompt-block search.
            // Kitty marks it the same way (`references/kitty/kitty/screen.c#shell_prompt_marking`).
            rows[cursor.row].semanticPrompt = .output
        case 0x44: // D
            semanticContent = .output
            semanticContentClearsAtEndOfLine = false
        case 0x4C: // L
            semanticPromptFreshLine()
        default:
            break
        }
    }

    private mutating func semanticPromptFreshLine() {
        guard cursor.column != 0 else { return }
        cursor.column = 0
        clearPendingMotionState()
        lineFeed()
    }

    private mutating func setSemanticPrompt(kind: SemanticPromptRow) {
        semanticContent = .prompt
        semanticContentClearsAtEndOfLine = false
        rows[cursor.row].semanticPrompt = kind
        reclaimStalePromptHeads(for: kind)
        // A column-zero head starts a logical line. Clear the claim only after reclaim,
        // which needs that claim to recognize a stranded soft-wrapped head.
        if kind == .prompt, cursor.column == 0, cursor.row > 0 {
            rows[cursor.row - 1].isSoftWrapped = false
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
              activeScrollRegion.contains(cursor.row)
        else { return }
        var top = topOfStalePromptHeads(above: cursor.row)
        // `.vacated` establishes ownership; emptiness establishes that deletion is free.
        // Reflow can preserve the stamp on a packed row with content, which must remain.
        while top > 0,
              rows[top - 1].semanticPrompt == .vacated,
              retainedContentEnd(in: rows[top - 1]) == 0
        {
            top -= 1
        }
        guard top < cursor.row, activeScrollRegion.contains(top) else { return }
        // Delete instead of re-blanking so the vacated rows do not become a permanent gap.
        // Move the cursor by the same count to preserve relative cursor arithmetic.
        let removed = cursor.row - top
        moveAndFillRows(in: top..<activeScrollRegion.upperBound, by: -removed, pushesToScrollback: false)
        cursor.row -= removed
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
        let valueBytes = Array(payload[payload.index(after: selectorEnd)...])
        guard valueBytes.count <= Self.maximumSemanticValueBytes,
              let value = strictlyDecodedUTF8(valueBytes)
        else { return }
        titleUsesWorkingDirectory = value.isEmpty
        pendingConsumerWork.setTitle(admittedCoalescedSemanticEvent(
            .title(value.isEmpty ? currentWorkingDirectory ?? "" : value),
            replacing: pendingConsumerWork.title
        ))
    }

    private mutating func dispatchDanTermShell(_ payload: [UInt8], selectorEnd: Int) {
        guard payload.count <= Self.maximumShellOSCBytes else { return }
        let fields = payload[payload.index(after: selectorEnd)...].split(
            separator: 0x3B,
            omittingEmptySubsequences: false
        )
        guard fields.count >= 2,
              fields[0].elementsEqual("DanTermShell=1".utf8),
              let eventName = String(validating: fields[1], as: UTF8.self)
        else { return }

        switch eventName {
        case "command-start":
            guard fields.count == 3,
                  let command = decodedCanonicalBase64(fields[2]),
                  !command.contains("\0"),
                  command.utf8.count <= Self.maximumSemanticValueBytes
            else { return }
            admitDiscreteSemanticEvent(.commandStarted(command))
        case "command-end":
            guard fields.count == 2 else { return }
            admitDiscreteSemanticEvent(.commandEnded)
        case "remote-start":
            guard fields.count == 2 else { return }
            admitDiscreteSemanticEvent(.remoteStarted)
        case "remote-host":
            guard fields.count == 4,
                  let user = decodedCanonicalBase64(fields[2]),
                  let host = decodedCanonicalBase64(fields[3]),
                  user.utf8.count + host.utf8.count <= Self.maximumSemanticValueBytes
            else { return }
            admitDiscreteSemanticEvent(.remoteHost(user: user, host: host))
        default:
            return
        }
    }

    private mutating func dispatchOSC9(_ payload: [UInt8], selectorEnd: Int) {
        let value = payload[payload.index(after: selectorEnd)...]
        let firstEnd = value.firstIndex(of: 0x3B) ?? value.endIndex
        let first = value[..<firstEnd]
        if let selector = canonicalConEmuSelector(first) {
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

    private func canonicalConEmuSelector(_ bytes: ArraySlice<UInt8>) -> Int? {
        for value in 1...12 where bytes.elementsEqual(String(value).utf8) {
            return value
        }
        return nil
    }

    private mutating func admitNotification(
        titleBytes: ArraySlice<UInt8>,
        bodyBytes: ArraySlice<UInt8>
    ) {
        guard titleBytes.count + bodyBytes.count <= Self.maximumSemanticValueBytes,
              let title = strictlyDecodedUTF8(Array(titleBytes)),
              let body = strictlyDecodedUTF8(Array(bodyBytes))
        else { return }
        admitDiscreteSemanticEvent(.desktopNotification(title: title, body: body))
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
            guard let percent = progressPercent(fields[2]) else { return }
            event = .set(percent: percent)
        case ("2", 2): event = .error(percent: nil)
        case ("2", 3):
            guard let percent = progressPercent(fields[2]) else { return }
            event = .error(percent: percent)
        case ("3", 2): event = .indeterminate
        case ("4", 2): event = .pause(percent: nil)
        case ("4", 3):
            guard let percent = progressPercent(fields[2]) else { return }
            event = .pause(percent: percent)
        default: return
        }
        pendingConsumerWork.setProgress(admittedCoalescedSemanticEvent(
            .progress(event),
            replacing: pendingConsumerWork.progress
        ))
    }

    private func progressPercent(_ bytes: ArraySlice<UInt8>) -> UInt8? {
        guard bytes.isEmpty == false, bytes.allSatisfy({ (0x30...0x39).contains($0) }),
              let value = Int(String(decoding: bytes, as: UTF8.self)), value <= 100
        else { return nil }
        return UInt8(value)
    }

    private func decodedCanonicalBase64(_ bytes: ArraySlice<UInt8>) -> String? {
        guard bytes.isEmpty == false,
              let decoded = decodeBase64(bytes, maximumByteCount: Self.maximumSemanticValueBytes),
              let value = String(validating: decoded, as: UTF8.self),
              value.isEmpty == false
        else { return nil }
        return value
    }

    private mutating func dispatchOSC7(_ payload: [UInt8], selectorEnd: Int) {
        let valueBytes = Array(payload[payload.index(after: selectorEnd)...])
        guard valueBytes.count <= Self.maximumSemanticValueBytes else { return }
        let cwd: String?
        if valueBytes.isEmpty {
            cwd = nil
        } else {
            guard let parsed = localFilePath(from: valueBytes) else { return }
            cwd = parsed
        }
        currentWorkingDirectory = cwd
        pendingConsumerWork.setWorkingDirectory(admittedCoalescedSemanticEvent(
            .workingDirectory(cwd),
            replacing: pendingConsumerWork.workingDirectory
        ))
        if titleUsesWorkingDirectory {
            pendingConsumerWork.setTitle(admittedCoalescedSemanticEvent(
                .title(cwd ?? ""),
                replacing: pendingConsumerWork.title
            ))
        }
    }

    private mutating func admitDiscreteSemanticEvent(_ event: TerminalSemanticEvent) {
        guard pendingConsumerWork.discrete.count < Self.maximumDiscreteSemanticEvents else { return }
        let candidate = PendingTerminalSemanticEvent(order: nextSemanticEventOrder, event: event)
        guard canAdmitSemanticBytes(candidate.byteCost) else { return }
        nextSemanticEventOrder &+= 1
        pendingConsumerWork.appendDiscrete(candidate)
    }

    private mutating func admittedCoalescedSemanticEvent(
        _ event: TerminalSemanticEvent,
        replacing existing: PendingTerminalSemanticEvent?
    ) -> PendingTerminalSemanticEvent? {
        let candidate = PendingTerminalSemanticEvent(order: nextSemanticEventOrder, event: event)
        let releasedBytes = existing?.byteCost ?? 0
        if retainedTerminalMetadataBytes - releasedBytes + candidate.byteCost
            > Self.maximumTerminalMetadataBytes
        {
            reclaimDeadHyperlinkTargets()
        }
        guard retainedTerminalMetadataBytes - releasedBytes + candidate.byteCost
                <= Self.maximumTerminalMetadataBytes
        else { return existing }
        nextSemanticEventOrder &+= 1
        return candidate
    }

    private mutating func canAdmitSemanticBytes(_ byteCount: Int) -> Bool {
        if retainedTerminalMetadataBytes + byteCount > Self.maximumTerminalMetadataBytes {
            reclaimDeadHyperlinkTargets()
        }
        return retainedTerminalMetadataBytes + byteCount <= Self.maximumTerminalMetadataBytes
    }

    private func strictlyDecodedUTF8(_ bytes: [UInt8]) -> String? {
        let value = String(decoding: bytes, as: UTF8.self)
        return Array(value.utf8) == bytes ? value : nil
    }

    private func localFilePath(from bytes: [UInt8]) -> String? {
        let prefix = Array("file://".utf8)
        guard bytes.starts(with: prefix),
              let slash = bytes[prefix.count...].firstIndex(of: 0x2F)
        else { return nil }
        let hostBytes = Array(bytes[prefix.count..<slash])
        guard let host = strictlyDecodedUTF8(hostBytes),
              Self.namesThisMachine(host, machineHostname: machineHostname)
        else { return nil }
        guard let decodedPathBytes = percentDecoded(Array(bytes[slash...])),
              let path = strictlyDecodedUTF8(decodedPathBytes)
        else { return nil }
        return path
    }

    /// Decides whether an OSC 7 URI host names this machine. Tolerant of exactly the
    /// spellings macOS manufactures -- ASCII case, one trailing dot, and a trailing
    /// `.local` label -- because the shells report the POSIX hostname while several
    /// system APIs return the mDNS form, and byte equality silently drops every report
    /// when the two diverge. Deliberately not a "first label matches" rule, which would
    /// accept `mac.evil.com` from an ssh session. A nil `machineHostname` means the
    /// embedder supplied no machine identity, so only `localhost` is local.
    private static func namesThisMachine(_ host: String, machineHostname: String?) -> Bool {
        if host == "localhost" { return true }
        guard let machineHostname else { return false }
        let normalized = normalizedHost(host)
        return !normalized.isEmpty && normalized == normalizedHost(machineHostname)
    }

    private static func normalizedHost(_ host: String) -> [UInt8] {
        var bytes = Array(host.utf8)
        for index in bytes.indices where (0x41...0x5A).contains(bytes[index]) {
            bytes[index] += 0x20
        }
        if bytes.last == 0x2E { bytes.removeLast() }
        let localSuffix = Array(".local".utf8)
        if bytes.count > localSuffix.count, bytes.suffix(localSuffix.count).elementsEqual(localSuffix) {
            bytes.removeLast(localSuffix.count)
        }
        return bytes
    }

    private func percentDecoded(_ bytes: [UInt8]) -> [UInt8]? {
        var result: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] != 0x25 {
                result.append(bytes[index])
                index += 1
                continue
            }
            guard index + 2 < bytes.count,
                  let high = hexadecimalValue(bytes[index + 1]),
                  let low = hexadecimalValue(bytes[index + 2])
            else { return nil }
            result.append(high * 16 + low)
            index += 3
        }
        return result
    }

    private func hexadecimalValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    private mutating func dispatchOSC8(_ payload: [UInt8], selectorEnd: Int) {
        let paramsStart = payload.index(after: selectorEnd)
        guard let paramsEnd = payload[paramsStart...].firstIndex(of: 0x3B) else { return }
        let uriStart = payload.index(after: paramsEnd)
        let uriBytes = Array(payload[uriStart...])
        let uri = String(decoding: uriBytes, as: UTF8.self)
        guard Array(uri.utf8) == uriBytes else { return }
        if uri.isEmpty {
            hyperlinkPen = nil
            return
        }

        let paramsBytes = Array(payload[paramsStart..<paramsEnd])
        let params = String(decoding: paramsBytes, as: UTF8.self)
        let explicitId = Array(params.utf8) == paramsBytes ? osc8ExplicitId(in: params) : nil
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

        var candidateTargets = hyperlinkTargets
        let interactionCost = (hoveredLinkState.map { hyperlinkByteCost($0.hyperlink) } ?? 0)
            + (armedLinkState.map { hyperlinkByteCost($0.hyperlink) } ?? 0)
        if candidateTargets.values.reduce(0, { $0 + hyperlinkByteCost($1) })
            + interactionCost + retainedSemanticEventBytes + hyperlinkByteCost(target)
                > Self.maximumTerminalMetadataBytes
        {
            let live = liveHyperlinkIds()
            candidateTargets = candidateTargets.filter { live.contains($0.key) }
        }
        guard candidateTargets.values.reduce(0, { $0 + hyperlinkByteCost($1) })
            + interactionCost + retainedSemanticEventBytes + hyperlinkByteCost(target)
                <= Self.maximumTerminalMetadataBytes
        else { return }

        guard let id = allocateHyperlinkId(avoiding: candidateTargets) else { return }
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
        guard targets.count <= Int(HyperlinkId.max) else { return nil }
        var candidate = nextHyperlinkId
        while targets[candidate] != nil { candidate &+= 1 }
        nextHyperlinkId = candidate &+ 1
        return candidate
    }

    private func osc8ExplicitId(in params: String) -> String? {
        for field in params.split(separator: ":", omittingEmptySubsequences: false) {
            let pieces = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pieces.count == 2, pieces[0] == "id" {
                return String(pieces[1])
            }
        }
        return nil
    }

    private func hyperlinkByteCost(_ target: TerminalHyperlink) -> Int {
        target.uri.utf8.count + (target.explicitId?.utf8.count ?? 0)
    }

    private func liveHyperlinkIds() -> Set<HyperlinkId> {
        var live = Set<HyperlinkId>()
        func collect(_ rows: [GridRow], into live: inout Set<HyperlinkId>) {
            for row in rows {
                for cell in row.cells {
                    if let id = cell.hyperlinkId { live.insert(id) }
                }
            }
        }
        collect(scrollbackRows.asArray(), into: &live)
        collect(rows, into: &live)
        if let inactivePrimaryScreen { collect(inactivePrimaryScreen.rows, into: &live) }
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
              let decoded = decodeBase64(encoded, maximumByteCount: 1_048_576)
        else { return }
        let value = String(decoding: decoded, as: UTF8.self)
        guard Array(value.utf8) == decoded else { return }
        pendingConsumerWork.setClipboardWrite(value)
    }

    private func parseOSCSelector(_ bytes: ArraySlice<UInt8>) -> Int? {
        var value = 0
        for byte in bytes {
            guard (0x30...0x39).contains(byte) else { return nil }
            let multiplied = value.multipliedReportingOverflow(by: 10)
            guard multiplied.overflow == false else { return nil }
            let added = multiplied.partialValue.addingReportingOverflow(Int(byte - 0x30))
            guard added.overflow == false else { return nil }
            value = added.partialValue
        }
        return value
    }

    private func decodeBase64(
        _ encoded: ArraySlice<UInt8>,
        maximumByteCount: Int
    ) -> [UInt8]? {
        guard encoded.count.isMultiple(of: 4) else { return nil }
        var decoded: [UInt8] = []
        decoded.reserveCapacity(min(maximumByteCount, encoded.count / 4 * 3))
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let aIndex = index
            let bIndex = encoded.index(after: aIndex)
            let cIndex = encoded.index(after: bIndex)
            let dIndex = encoded.index(after: cIndex)
            let next = encoded.index(after: dIndex)
            guard let a = base64Value(encoded[aIndex]), let b = base64Value(encoded[bIndex]) else {
                return nil
            }
            let cByte = encoded[cIndex]
            let dByte = encoded[dIndex]
            guard appendDecodedBase64Quartet(
                a: a,
                b: b,
                cByte: cByte,
                dByte: dByte,
                isFinal: next == encoded.endIndex,
                maximumByteCount: maximumByteCount,
                to: &decoded
            ) else { return nil }
            index = next
        }
        return decoded
    }

    private func appendDecodedBase64Quartet(
        a: UInt8,
        b: UInt8,
        cByte: UInt8,
        dByte: UInt8,
        isFinal: Bool,
        maximumByteCount: Int,
        to decoded: inout [UInt8]
    ) -> Bool {
        decoded.append((a << 2) | (b >> 4))
        if cByte == 0x3D {
            guard isFinal, dByte == 0x3D, b & 0x0F == 0 else { return false }
        } else {
            guard let c = base64Value(cByte) else { return false }
            decoded.append((b << 4) | (c >> 2))
            if dByte == 0x3D {
                guard isFinal, c & 0x03 == 0 else { return false }
            } else {
                guard let d = base64Value(dByte) else { return false }
                decoded.append((c << 6) | d)
            }
        }
        return decoded.count <= maximumByteCount
    }

    private func base64Value(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x41...0x5A: byte - 0x41
        case 0x61...0x7A: byte - 0x61 + 26
        case 0x30...0x39: byte - 0x30 + 52
        case 0x2B: 62
        case 0x2F: 63
        default: nil
        }
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

        if var primary = inactivePrimaryScreen {
            let alternateRows = self.rows
            let liveCursor = cursor
            let livePendingWrap = isPendingWrap
            let liveSemanticContent = semanticContent
            let liveSemanticContentClearsAtEndOfLine = semanticContentClearsAtEndOfLine

            self.rows = primary.rows
            cursor = primary.resizeCursor
            isPendingWrap = primary.isResizePendingWrap
            semanticContent = primary.semanticContent
            semanticContentClearsAtEndOfLine = primary.semanticContentClearsAtEndOfLine
            clearPromptForResizeIfNeeded()
            resizePrimaryScreen(columns: columns, rows: rows)
            primary.rows = self.rows
            primary.resizeCursor = cursor
            primary.isResizePendingWrap = isPendingWrap
            primary.semanticContent = semanticContent
            primary.semanticContentClearsAtEndOfLine = semanticContentClearsAtEndOfLine

            self.rows = resizedRectangle(
                alternateRows,
                columns: columns,
                rows: rows,
                clearsSoftWrap: columns != oldColumnCount
            )
            cursor = liveCursor
            isPendingWrap = livePendingWrap
            semanticContent = liveSemanticContent
            semanticContentClearsAtEndOfLine = liveSemanticContentClearsAtEndOfLine
            inactivePrimaryScreen = primary
        } else {
            clearPromptForResizeIfNeeded()
            resizePrimaryScreen(columns: columns, rows: rows)
        }

        clampCursorStateToActiveGrid()
        clampSelectionToRetainedStream()
        clusterContext = nil
    }

    private mutating func clearPromptForResizeIfNeeded() {
        guard promptRedrawMode != .disabled, semanticContent != .output else { return }
        if promptRedrawMode == .last {
            clearPromptCells(in: cursor.row)
            return
        }

        var start = cursor.row
        while start >= 0 {
            switch rows[start].semanticPrompt {
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
              rows[top - 1].semanticPrompt == .prompt,
              rows[top - 1].isSoftWrapped
        {
            top -= 1
        }
        return top
    }

    /// Vacates one row on the shell's repaint promise, including its obsolete wrap claim.
    private mutating func clearPromptCells(in row: Int) {
        invalidateInspection(inViewportRows: row..<(row + 1))
        let styleId = backgroundEraseStyleId()
        for column in 0..<columnCount {
            rows[row].cells[column] = GridCell(styleId: styleId)
        }
        rows[row].semanticPrompt = .vacated
        rows[row].isSoftWrapped = false
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
                    for scalar in cell.scalars {
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

    /// Exposes the current visual-row extent and window for scrollbar and inspection consumers.
    public var scrollProjection: TerminalScrollProjection {
        if isAlternateScreenActive {
            return TerminalScrollProjection(
                totalRows: rowCount,
                topRow: 0,
                windowRows: rowCount,
                isFollowing: true
            )
        }
        let totalRows = scrollbackRows.count + rows.count
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
        let maximumTop = max(0, scrollbackRows.count + rows.count - rowCount)
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
        scrollbackRows.count
    }

    /// Exposes one retained row without allowing callers to mutate terminal storage.
    public func scrollbackRow(at index: Int) -> TerminalScrollbackRow? {
        guard scrollbackRows.indices.contains(index) else { return nil }
        let row = scrollbackRows[index].unpacked().materialized(to: columnCount)
        return TerminalScrollbackRow(
            cells: row.cells.map {
                TerminalCell(
                    kind: $0.kind,
                    scalars: $0.scalars,
                    style: style(for: $0.styleId),
                    hyperlink: $0.hyperlinkId.flatMap { hyperlinkTargets[$0] }
                )
            },
            isSoftWrapped: row.isSoftWrapped
        )
    }

    /// Reports one retained row's content-identity run shape, reading the stored prefix
    /// directly rather than the materialized row.
    ///
    /// Row-scoped on purpose. `contentIdentity` is deliberately absent from `TerminalCell`,
    /// and doc 28's `PR1` needs it only in aggregate, so this returns counts from one call
    /// per row instead of widening the per-cell inspection value -- which would add a stored
    /// property to a hot type crossing a target boundary and change its layout for every
    /// consumer. That is the shape
    /// `docs/design/2026-07-29-cross-module-value-dispatch.md` recommends reaching for at
    /// design time, and the same one `forEachViewportCell(row:_:)` took for the render
    /// planner. O(stored cells), for measurement only.
    ///
    /// Reads `scrollbackRows` unmaterialized because the trailing default cells
    /// `materialized(to:)` appends were never printed into: counting them would report the
    /// pane's width as unidentified rather than the row's own content.
    public func scrollbackRowContentIdentityShape(at index: Int) -> TerminalContentIdentityShape? {
        guard scrollbackRows.indices.contains(index) else { return nil }
        var runCount = 0
        var strictRunCount = 0
        var identified = 0
        var unidentified = 0
        var previous: ContentIdentity?
        for cell in scrollbackRows[index].unpacked().cells {
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

    /// Walks the whole grid and reports exactly what its cell storage costs.
    ///
    /// Lives here rather than beside `TerminalMemoryCensus` because it needs `GridCell` and
    /// `GridRow`, which stay `private`. That split is the point: the census ships as reusable
    /// public evidence without widening the grid types, which is what forced doc 12's censuses to
    /// be throwaway probes. O(cells) -- for measurement, not for a hot path.
    public var memoryCensus: TerminalMemoryCensus {
        // Distinct styles are counted by id rather than by value: ids are canonical (equal styles
        // always intern to the same one), so this is the same number doc `12/F3` reported, reached
        // without re-deriving a hash for a type the table already hashes.
        let stride = MemoryLayout<GridCell>.stride
        var census = TerminalMemoryCensus(
            screenRowCount: 0,
            scrollbackRowCount: scrollbackRows.count,
            cellCount: 0,
            cellStrideBytes: stride,
            cellStorageBytes: 0,
            retainedStoredCellCount: 0,
            retainedPackedPayloadBytes: 0,
            rowStorageAllocationCount: 0,
            retainedRowStorageRowCount: scrollbackRows.retainedCellStorageRowCount,
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

        // The retained primary screen counts as resident: under the alternate screen the process
        // holds both grids, and a census that reported only the visible one would understate a
        // full-screen TUI by an entire screen.
        let screens = [rows, inactivePrimaryScreen?.rows].compactMap { $0 }
        census.screenRowCount = screens.reduce(0) { $0 + $1.count }

        // Retained rows are priced by their blob, live rows by the cell stride. Content
        // counts below are read from the *decoded* row either way, because the census answers
        // "what is the grid holding" -- and packing changed what a cell costs, not what a row
        // contains. Unpacking here is affordable for the same reason the whole walk is: this
        // is a measurement accessor, never a hot path.
        for index in scrollbackRows.indices {
            let packed = scrollbackRows[index]
            if packed.storedCellCount > 0 { census.rowStorageAllocationCount += 1 }
            census.retainedStoredCellCount += packed.storedCellCount
            census.retainedPackedPayloadBytes += packed.payloadByteCount
        }
        for row in screens.flatMap({ $0 }) where row.cells.isEmpty == false {
            census.rowStorageAllocationCount += 1
        }
        census.cellStorageBytes = census.retainedPackedPayloadBytes
            + screens.flatMap({ $0 }).reduce(0) { $0 + $1.cells.count * stride }

        for row in scrollbackRows.asArray() + screens.flatMap({ $0 }) {
            census.cellCount += row.cells.count
            for cell in row.cells {
                if cell.styleId != Self.defaultStyleId { census.styledCellCount += 1 }
                styles.insert(cell.styleId)
                if cell.scalars.count > 1 {
                    census.multiScalarCellCount += 1
                    census.multiScalarAllocationCount += 1
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

    /// Counts rows whose cell storage history still owns, so leak proofs can assert it equals
    /// `scrollbackRowCount` without naming how the buffer evicts. Deliberately phrased as the
    /// invariant rather than as buffer internals: doc 15's `D1` defers a ring-buffer rewrite that
    /// would answer this trivially, and this accessor must survive it.
    var retainedCellStorageRowCount: Int {
        scrollbackRows.retainedCellStorageRowCount
    }

    /// Recomputes retained-row cost for coherence proofs without affecting enforcement.
    var recomputedScrollbackByteCount: Int {
        scrollbackRows.indices.reduce(0) {
            $0 + Self.scrollbackByteCost(of: scrollbackRows[$1])
        }
    }

    /// The cell-cap sibling of `recomputedScrollbackByteCount`, for the same coherence proofs.
    var recomputedScrollbackStoredCellCount: Int {
        scrollbackRows.indices.reduce(0) { $0 + scrollbackRows[$1].storedCellCount }
    }

    /// Charges one blank row of `columns` cells, so tests can size budgets in whole rows without
    /// restating the cost model. Since `D4` charges reserved rather than occupied storage, that
    /// model is no longer arithmetic a test can safely rewrite from a column count.
    static func blankScrollbackRowByteCost(columns: Int) -> Int {
        scrollbackByteCost(of: GridRow(cells: (0..<columns).map { _ in GridCell() }))
    }

    /// Sizes a compact ordinary row so retention tests can choose exact eviction boundaries.
    static func compactScrollbackRowByteCost(storedCells: Int) -> Int {
        precondition(storedCells >= 1)
        // Modelled as cells that were really *printed*: an ASCII scalar and a contiguous
        // identity each. Doc 28's packed row charges by content, so a fixture row of bare
        // `.narrow` cells carrying no scalar would owe a kind exception per cell and price a
        // shape the terminal never produces -- which is how a budget written in these units
        // would silently admit a different number of real rows than the test intends.
        return scrollbackByteCost(of: GridRow(cells: (0..<storedCells).map {
            GridCell(
                scalars: .single("a"),
                kind: .narrow,
                contentIdentity: ContentIdentity($0 + 1)
            )
        }))
    }

    /// Sums what history's cell storage *actually reserved*, derived independently of the charge
    /// model so a test can hold one against the other.
    ///
    /// `Array.capacity` is the allocator's own answer -- Swift sets it from the block malloc really
    /// returned -- so this counts bucket rounding without modelling a single size class. Kept
    /// separate from `recomputedScrollbackByteCount`, which recomputes the *charge*; this one
    /// recomputes the *cost*. The budget is honest exactly when the second does not exceed it.
    var retainedScrollbackAllocationBytes: Int {
        scrollbackRows.indices.reduce(0) {
            $0 + MemoryLayout<PackedRetainedRow>.stride
                + Self.arrayStorageHeaderBytes
                + scrollbackRows[$1].storage.capacity
        }
    }

    /// Hands a test the decoded retained row, so a packed-representation proof can compare
    /// fields the public reader deliberately omits -- `contentIdentity` above all. Computed
    /// only when a test asks; production reads packed rows through the buffer.
    func retainedRowForTesting(at index: Int) -> GridRow? {
        guard scrollbackRows.indices.contains(index) else { return nil }
        return scrollbackRows[index].unpacked()
    }

    /// Exposes one canonical row cost so tests can pin the representation-neutral literals.
    func scrollbackRowByteCost(at index: Int) -> Int? {
        guard scrollbackRows.indices.contains(index) else { return nil }
        return Self.scrollbackByteCost(of: scrollbackRows[index])
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

    /// Creates the one-operation no-eviction oracle used to isolate eviction side effects.
    func withUnlimitedScrollbackForTesting() -> Self {
        var copy = self
        copy.scrollbackBudgetBytes = .max
        copy.scrollbackRowCap = .max
        copy.scrollbackCellCap = .max
        return copy
    }

    /// Exposes private row stamps to the shared snapshot oracle without changing public geometry.
    /// Computed only when a test asks; production never calls it.
    var semanticPromptRowsForTesting: [TerminalSemanticPromptRowSnapshot] {
        rows.map { row in
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
                isEmpty: retainedContentEnd(in: row) == 0
            )
        }
    }

    /// Projects retained history and the viewport as logical text without a final newline.
    public var fullHistoryText: String {
        guard isAlternateScreenActive else { return primaryHistoryText }
        var stream = scrollbackRows.asArray()
        if let last = stream.indices.last {
            stream[last].isSoftWrapped = false
        }
        stream.append(contentsOf: rows)
        return projectedHistoryText(from: stream)
    }

    /// Projects retained primary-screen history for recovery and export consumers.
    public var primaryHistoryText: String {
        let primaryRows = inactivePrimaryScreen?.rows ?? rows
        return projectedHistoryText(from: scrollbackRows.asArray() + primaryRows)
    }

    /// Returns the current half-open selection endpoints in stream coordinates.
    public var selectionRange: TerminalTextRange? {
        selection.flatMap(publicRange)
    }

    /// Returns the currently indicated HTTP(S) run in current retained-stream coordinates.
    public var hoveredLink: TerminalResolvedLink? {
        guard let hoveredLinkState, let range = publicRange(hoveredLinkState.range) else {
            return nil
        }
        return TerminalResolvedLink(
            hyperlink: hoveredLinkState.hyperlink,
            range: range,
            activationIdentity: hoveredLinkState.activationIdentity
        )
    }

    /// Admits and anchors one resolved link for hover presentation within the shared metadata cap.
    @discardableResult
    public mutating func setHoveredLink(_ link: TerminalResolvedLink) -> Bool {
        guard isActivatableHTTPLink(link.hyperlink.uri),
              hyperlinkByteCost(link.hyperlink) <= Self.maximumHyperlinkTargetBytes
        else { return false }

        let before = damageActionSnapshot
        var candidateTargets = hyperlinkTargets
        let armCost = armedLinkState.map { hyperlinkByteCost($0.hyperlink) } ?? 0
        let retainedCost = candidateTargets.values.reduce(0) { $0 + hyperlinkByteCost($1) }
        if retainedCost + armCost + retainedSemanticEventBytes + hyperlinkByteCost(link.hyperlink)
            > Self.maximumTerminalMetadataBytes
        {
            let live = liveHyperlinkIds()
            candidateTargets = candidateTargets.filter { live.contains($0.key) }
        }
        let candidateCost = candidateTargets.values.reduce(0) { $0 + hyperlinkByteCost($1) }
        guard candidateCost + armCost + retainedSemanticEventBytes + hyperlinkByteCost(link.hyperlink)
            <= Self.maximumTerminalMetadataBytes
        else { return false }

        let ordered = textPositionPrecedes(link.range.start, link.range.end)
            ? (link.range.start, link.range.end)
            : (link.range.end, link.range.start)
        hyperlinkTargets = candidateTargets
        hoveredLinkState = InteractionLinkState(
            hyperlink: link.hyperlink,
            range: TextAnchorRange(
                start: normalizedSelectionBoundary(ordered.0, isEnd: false),
                end: normalizedSelectionBoundary(ordered.1, isEnd: true)
            ),
            activationIdentity: link.activationIdentity
        )
        recordDamage(since: before)
        return true
    }

    /// Reports whether the current table can atomically reserve one click target.
    func canAdmitArmedLink(_ link: TerminalResolvedLink) -> Bool {
        guard isActivatableHTTPLink(link.hyperlink.uri),
              hyperlinkByteCost(link.hyperlink) <= Self.maximumHyperlinkTargetBytes
        else { return false }
        var candidateTargets = hyperlinkTargets
        let hoverCost = hoveredLinkState.map { hyperlinkByteCost($0.hyperlink) } ?? 0
        if candidateTargets.values.reduce(0, { $0 + hyperlinkByteCost($1) })
            + hoverCost + retainedSemanticEventBytes + hyperlinkByteCost(link.hyperlink)
            > Self.maximumTerminalMetadataBytes
        {
            let live = liveHyperlinkIds()
            candidateTargets = candidateTargets.filter { live.contains($0.key) }
        }
        return candidateTargets.values.reduce(0, { $0 + hyperlinkByteCost($1) })
            + hoverCost + retainedSemanticEventBytes + hyperlinkByteCost(link.hyperlink)
            <= Self.maximumTerminalMetadataBytes
    }

    /// Atomically reserves a validated originating run for click-time revalidation.
    @discardableResult
    public mutating func setArmedLink(_ link: TerminalResolvedLink) -> Bool {
        guard canAdmitArmedLink(link) else { return false }
        var candidateTargets = hyperlinkTargets
        let hoverCost = hoveredLinkState.map { hyperlinkByteCost($0.hyperlink) } ?? 0
        if candidateTargets.values.reduce(0, { $0 + hyperlinkByteCost($1) })
            + hoverCost + retainedSemanticEventBytes + hyperlinkByteCost(link.hyperlink)
            > Self.maximumTerminalMetadataBytes
        {
            let live = liveHyperlinkIds()
            candidateTargets = candidateTargets.filter { live.contains($0.key) }
        }
        let ordered = textPositionPrecedes(link.range.start, link.range.end)
            ? (link.range.start, link.range.end)
            : (link.range.end, link.range.start)
        hyperlinkTargets = candidateTargets
        armedLinkState = InteractionLinkState(
            hyperlink: link.hyperlink,
            range: TextAnchorRange(
                start: normalizedSelectionBoundary(ordered.0, isEnd: false),
                end: normalizedSelectionBoundary(ordered.1, isEnd: true)
            ),
            activationIdentity: link.activationIdentity
        )
        return true
    }

    /// Clears the retained click reservation without affecting hover presentation.
    public mutating func clearArmedLink() {
        armedLinkState = nil
    }

    /// Reconstructs the current click reservation for release-time identity comparison.
    var armedLink: TerminalResolvedLink? {
        guard let armedLinkState, let range = publicRange(armedLinkState.range) else {
            return nil
        }
        return TerminalResolvedLink(
            hyperlink: armedLinkState.hyperlink,
            range: range,
            activationIdentity: armedLinkState.activationIdentity
        )
    }

    /// Clears hyperlink presentation without changing terminal text or selection.
    public mutating func clearHoveredLink() {
        guard hoveredLinkState != nil else { return }
        let before = damageActionSnapshot
        hoveredLinkState = nil
        recordDamage(since: before)
    }

    /// Serializes the selected projection units, preserving an intentionally empty selection.
    public var selectedText: String? {
        guard let selection else { return nil }
        return text(in: selection)
    }

    /// Returns the current half-open search occurrence in stream coordinates.
    ///
    /// Yields nil under the alternate screen: match anchors are absolute stream rows over
    /// scrollback, but the alt projection restarts at row 0, so a retained scrollback match
    /// would land on unrelated alt-screen content. Mirrors `revealSearchMatchIfNeeded`.
    public var activeSearchMatchRange: TerminalTextRange? {
        guard isAlternateScreenActive == false else { return nil }
        return search?.range.flatMap(publicRange)
    }

    /// Reports the active search's live match count and selected index, or nil when
    /// no search is active (never begun, cleared, or an empty needle).
    ///
    /// Recomputed from the same scan navigation uses, so it never disagrees with the
    /// selected match. Suppressed under the alternate screen for the reason on
    /// `activeSearchMatchRange`.
    ///
    /// When the retained occurrence is stale or absent -- output arrived while a failed
    /// search was open, or the selected match was overwritten -- this reports the newest
    /// match, which is exactly the one the next navigation re-attaches to.
    public var searchStatus: TerminalSearchStatus? {
        guard isAlternateScreenActive == false, let search else { return nil }
        // Read-only counterpart to `memoizedSearchMatches`: a get-only property on a value
        // type cannot fill the cache, so it answers from one and scans only on a miss.
        let matches = searchMatchCache.matches(for: search.query)
            ?? searchMatches(for: search.query)
        guard matches.isEmpty == false else { return .empty }
        let selected = search.range
            .flatMap(matches.firstIndex(of:))
            .map { matches.count - 1 - $0 }
        return .matched(selected: selected ?? 0, total: matches.count)
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
        selection = TextAnchorRange(
            start: anchor(before: ordered.0),
            end: anchor(after: ordered.1)
        )
        recordDamage(since: before)
    }

    /// Applies an already-computed half-open selection unit without losing wrap boundaries.
    public mutating func setSelection(_ range: TerminalTextRange) {
        let before = damageActionSnapshot
        let ordered = textPositionPrecedes(range.start, range.end)
            ? (range.start, range.end)
            : (range.end, range.start)
        selection = TextAnchorRange(
            start: normalizedSelectionBoundary(ordered.0, isEnd: false),
            end: normalizedSelectionBoundary(ordered.1, isEnd: true)
        )
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
            selection = TextAnchorRange(start: first.start, end: last.end)
        } else {
            let anchor = TextAnchor(row: evictedRowCount, column: 0)
            selection = TextAnchorRange(start: anchor, end: anchor)
        }
        recordDamage(since: before)
    }

    /// Returns the maximal separator or non-separator run used by DanTerm's
    /// terminal-oriented double-click selection. Classification uses the leading
    /// scalar so a combining mark cannot move its base cell across the boundary.
    public func terminalTokenRange(at position: TerminalTextPosition) -> TerminalTextRange {
        let stream = activeProjection()
        guard let lastContentRow = stream.lastIndex(where: rowContainsContent),
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
            end: TerminalTextPosition(row: last, column: projectedCellEnd(in: stream[last]))
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

    /// Resolves explicit OSC 8 metadata or a detected URL through the HTTP(S) activation gate.
    public func activatableLink(at position: TerminalTextPosition) -> TerminalResolvedLink? {
        if let explicit = explicitLink(at: position) {
            guard isActivatableHTTPLink(explicit.hyperlink.uri) else { return nil }
            return explicit
        }
        return detectedLink(at: position)
    }

    private func explicitLink(at position: TerminalTextPosition) -> TerminalResolvedLink? {
        let stream = activeProjection()
        guard stream.isEmpty == false else { return nil }
        let row = min(max(position.row, 0), stream.count - 1)
        let column = min(max(position.column, 0), columnCount - 1)
        guard let id = stream[row].cell(at: column).hyperlinkId,
              let target = hyperlinkTargets[id]
        else { return nil }

        var firstRow = row
        var lastRow = row
        while firstRow > 0, stream[firstRow - 1].isSoftWrapped { firstRow -= 1 }
        while lastRow + 1 < stream.count, stream[lastRow].isSoftWrapped { lastRow += 1 }
        var coordinates: [TerminalTextPosition] = []
        for rowIndex in firstRow...lastRow {
            for columnIndex in 0..<projectedCellEnd(in: stream[rowIndex]) {
                coordinates.append(.init(row: rowIndex, column: columnIndex))
            }
        }
        guard let targetIndex = coordinates.firstIndex(of: .init(row: row, column: column)) else {
            return nil
        }
        var lower = targetIndex
        var upper = targetIndex
        while lower > 0 {
            let candidate = coordinates[lower - 1]
            guard stream[candidate.row].cell(at: candidate.column).hyperlinkId == id else { break }
            lower -= 1
        }
        while upper + 1 < coordinates.count {
            let candidate = coordinates[upper + 1]
            guard stream[candidate.row].cell(at: candidate.column).hyperlinkId == id else { break }
            upper += 1
        }
        let start = coordinates[lower]
        let last = coordinates[upper]
        return TerminalResolvedLink(
            hyperlink: target,
            range: TerminalTextRange(
                start: start,
                end: .init(row: last.row, column: last.column + 1)
            ),
            activationIdentity: activationIdentity(
                in: TerminalTextRange(
                    start: start,
                    end: .init(row: last.row, column: last.column + 1)
                ),
                stream: stream
            )
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
            uri.unicodeScalars.append(contentsOf: scalars[start..<end])
            guard uri.utf8.count <= Self.maximumHyperlinkTargetBytes,
                  isActivatableHTTPLink(uri)
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
            for column in max(0, start)..<min(columnCount, end) {
                identity = max(identity, Int(stream[row].cell(at: column).contentIdentity ?? 0))
            }
        }
        return identity
    }

    private func isTrailingURLPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        [0x2C, 0x2E, 0x3B, 0x3A, 0x21, 0x3F, 0x29, 0x5C, 0x5D, 0x7D]
            .contains(scalar.value)
    }

    private func isActivatableHTTPLink(_ uri: String) -> Bool {
        let scalars = Array(uri.unicodeScalars)
        guard scalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F }),
              let colon = scalars.firstIndex(where: { $0.value == 0x3A })
        else { return false }
        let scheme = String(String.UnicodeScalarView(scalars[..<colon])).lowercased()
        guard scheme == "http" || scheme == "https",
              colon + 2 < scalars.count,
              scalars[colon + 1].value == 0x2F,
              scalars[colon + 2].value == 0x2F
        else { return false }
        let authorityStart = colon + 3
        let authorityEnd = scalars[authorityStart...].firstIndex(where: {
            $0.value == 0x2F || $0.value == 0x3F || $0.value == 0x23
        }) ?? scalars.endIndex
        guard authorityStart < authorityEnd else { return false }
        let authority = Array(scalars[authorityStart..<authorityEnd])
        let at = authority.lastIndex(where: { $0.value == 0x40 })
        if let at, isValidURIComponent(authority[..<at], allowsColon: true) == false {
            return false
        }
        let hostPortStart = at.map { $0 + 1 } ?? 0
        guard hostPortStart < authority.count else { return false }
        let hostPort = Array(authority[hostPortStart...])
        let port: ArraySlice<Unicode.Scalar>?
        let host: ArraySlice<Unicode.Scalar>
        let isBracketedHost: Bool
        if hostPort.first?.value == 0x5B {
            guard let close = hostPort.firstIndex(where: { $0.value == 0x5D }), close > 1 else {
                return false
            }
            host = hostPort[1..<close]
            isBracketedHost = true
            if close + 1 < hostPort.count {
                guard hostPort[close + 1].value == 0x3A else { return false }
                port = hostPort[(close + 2)...]
            } else {
                port = nil
            }
        } else if let separator = hostPort.lastIndex(where: { $0.value == 0x3A }) {
            guard hostPort[..<separator].allSatisfy({ $0.value != 0x3A }) else { return false }
            host = hostPort[..<separator]
            port = hostPort[(separator + 1)...]
            isBracketedHost = false
        } else {
            host = hostPort[...]
            port = nil
            isBracketedHost = false
        }
        guard host.isEmpty == false,
              isBracketedHost ? isValidIPLiteral(host) : isValidRegName(host)
        else { return false }
        if let port {
            guard port.isEmpty == false,
                  port.allSatisfy({ (0x30...0x39).contains($0.value) }),
                  let value = Int(String(String.UnicodeScalarView(port))),
                  (1...65_535).contains(value)
            else { return false }
        }
        return true
    }

    private func isValidRegName(_ host: ArraySlice<Unicode.Scalar>) -> Bool {
        isValidURIComponent(host, allowsColon: false)
    }

    private func isValidURIComponent(
        _ scalars: ArraySlice<Unicode.Scalar>,
        allowsColon: Bool
    ) -> Bool {
        let values = scalars.map(\.value)
        var index = 0
        while index < values.count {
            let value = values[index]
            if value == 0x25 {
                guard index + 2 < values.count,
                      isHexDigit(values[index + 1]),
                      isHexDigit(values[index + 2])
                else { return false }
                index += 3
                continue
            }
            guard isUnreservedOrSubDelimiter(value) || (allowsColon && value == 0x3A) else {
                return false
            }
            index += 1
        }
        return true
    }

    private func isValidIPLiteral(_ host: ArraySlice<Unicode.Scalar>) -> Bool {
        let value = String(String.UnicodeScalarView(host))
        if value.first == "v" || value.first == "V" {
            guard let dot = value.firstIndex(of: "."), dot > value.startIndex else { return false }
            let version = value[value.index(after: value.startIndex)..<dot]
            let address = value[value.index(after: dot)...]
            return version.isEmpty == false
                && version.unicodeScalars.allSatisfy { isHexDigit($0.value) }
                && address.isEmpty == false
                && address.unicodeScalars.allSatisfy {
                    isUnreservedOrSubDelimiter($0.value) || $0.value == 0x3A
                }
        }
        return isValidIPv6(value)
    }

    private func isValidIPv6(_ address: String) -> Bool {
        guard address.isEmpty == false else { return false }
        let characters = Array(address)
        var compressionCount = 0
        if characters.count >= 2 {
            for index in 0..<(characters.count - 1)
            where characters[index] == ":" && characters[index + 1] == ":"
            {
                compressionCount += 1
            }
        }
        guard compressionCount <= 1 else { return false }
        let isCompressed = compressionCount == 1
        if isCompressed == false,
           (characters.first == ":" || characters.last == ":")
        {
            return false
        }
        let pieces = address.split(separator: ":", omittingEmptySubsequences: true)
        var groupCount = 0
        for (index, piece) in pieces.enumerated() {
            if piece.contains(".") {
                guard index == pieces.count - 1, isValidIPv4(String(piece)) else { return false }
                groupCount += 2
            } else {
                guard (1...4).contains(piece.count),
                      piece.unicodeScalars.allSatisfy({ isHexDigit($0.value) })
                else { return false }
                groupCount += 1
            }
        }
        if isCompressed {
            return groupCount < 8
        }
        return groupCount == 8
    }

    private func isValidIPv4(_ address: String) -> Bool {
        let pieces = address.split(separator: ".", omittingEmptySubsequences: false)
        return pieces.count == 4 && pieces.allSatisfy { piece in
            piece.isEmpty == false
                && piece.unicodeScalars.allSatisfy { (0x30...0x39).contains($0.value) }
                && Int(piece).map { (0...255).contains($0) } == true
        }
    }

    private func isHexDigit(_ value: UInt32) -> Bool {
        (0x30...0x39).contains(value)
            || (0x41...0x46).contains(value)
            || (0x61...0x66).contains(value)
    }

    private func isUnreservedOrSubDelimiter(_ value: UInt32) -> Bool {
        return (0x30...0x39).contains(value)
            || (0x41...0x5A).contains(value)
            || (0x61...0x7A).contains(value)
            || value == 0x2D || value == 0x2E || value == 0x5F || value == 0x7E
            || [0x21, 0x24, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x3B, 0x3D]
                .contains(value)
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
        let before = damageActionSnapshot
        guard query.isEmpty == false else {
            search = nil
            recordDamage(since: before)
            return false
        }
        let match = memoizedSearchMatches(for: query).last
        search = SearchState(query: query, range: match)
        revealSearchMatchIfNeeded()
        recordDamage(since: before)
        return match != nil
    }

    /// Moves to the next older match, wrapping past the oldest back to the newest.
    @discardableResult
    public mutating func searchNext() -> Bool {
        guard let search else { return false }
        let matches = memoizedSearchMatches(for: search.query)
        guard let current = search.range.flatMap(matches.firstIndex(of:)) else {
            return reattachToNewestMatch(among: matches)
        }
        let before = damageActionSnapshot
        self.search?.range = current > 0 ? matches[current - 1] : matches[matches.count - 1]
        revealSearchMatchIfNeeded()
        recordDamage(since: before)
        return true
    }

    /// Moves to the previous newer match, wrapping past the newest back to the oldest.
    @discardableResult
    public mutating func searchPrevious() -> Bool {
        guard let search else { return false }
        let matches = memoizedSearchMatches(for: search.query)
        guard let current = search.range.flatMap(matches.firstIndex(of:)) else {
            return reattachToNewestMatch(among: matches)
        }
        let before = damageActionSnapshot
        self.search?.range = current + 1 < matches.count ? matches[current + 1] : matches[0]
        revealSearchMatchIfNeeded()
        recordDamage(since: before)
        return true
    }

    /// Selects the newest match for a search whose occurrence is missing or stale.
    ///
    /// Reached when output arrives under a failed needle, or overwrites the selected
    /// match: without it the engine would stay in "matches exist, none selected" and
    /// navigation would refuse to move until the user retyped the needle.
    private mutating func reattachToNewestMatch(among matches: [TextAnchorRange]) -> Bool {
        guard let newest = matches.last else { return false }
        let before = damageActionSnapshot
        search?.range = newest
        revealSearchMatchIfNeeded()
        recordDamage(since: before)
        return true
    }

    /// Clears the query and its active occurrence together.
    public mutating func clearSearch() {
        let before = damageActionSnapshot
        search = nil
        recordDamage(since: before)
    }

    private func projectedHistoryText(from stream: [GridRow]) -> String {
        var result = ""
        forEachProjectionUnit(from: stream, absoluteBase: 0) { unit in
            result.unicodeScalars.append(contentsOf: unit.scalars)
        }
        return result
    }

    private var presentedRows: [GridRow] {
        let topRow = scrollProjection.topRow
        return (topRow..<(topRow + rowCount)).map { index in
            guard let row = viewportStreamRow(at: index) else {
                preconditionFailure("viewport projection exceeded the active stream")
            }
            return row
        }
    }

    /// The viewport projected to cell *kinds* only, which is all `geometry` carries.
    ///
    /// Separate from `presentedRows` because that materializes whole rows, and for a
    /// retained row materializing means decoding a style, a hyperlink, and a content
    /// identity per cell plus retaining a `TerminalScalars` -- every one of which
    /// `TerminalGeometry` then drops. `28/F17` measured this as roughly half the browsing
    /// regression, and it was pure waste: geometry has never read a scalar.
    ///
    /// Padding past a content-sized row's stored extent is synthesized here rather than
    /// stored, which is the same contract `forEachViewportCell(row:_:)` honors.
    private var presentedRowGeometry: [TerminalRowGeometry] {
        let topRow = scrollProjection.topRow
        let blankKind = GridCell().kind
        return (topRow..<(topRow + rowCount)).map { index in
            var kinds = [TerminalCellGeometry](
                repeating: TerminalCellGeometry(kind: blankKind),
                count: columnCount
            )
            if isAlternateScreenActive == false, scrollbackRows.indices.contains(index) {
                let packed = scrollbackRows[index]
                packed.forEachKind { column, kind in
                    guard column < columnCount else { return }
                    kinds[column] = TerminalCellGeometry(kind: kind)
                }
                return TerminalRowGeometry(cells: kinds, isSoftWrapped: packed.isSoftWrapped)
            }
            guard let row = viewportStreamRow(at: index) else {
                preconditionFailure("viewport projection exceeded the active stream")
            }
            for column in 0..<min(row.cells.count, columnCount) {
                kinds[column] = TerminalCellGeometry(kind: row.cells[column].kind)
            }
            return TerminalRowGeometry(cells: kinds, isSoftWrapped: row.isSoftWrapped)
        }
    }

    private func viewportStreamRow(at index: Int) -> GridRow? {
        guard index >= 0 else { return nil }
        if isAlternateScreenActive {
            return rows.indices.contains(index) ? rows[index] : nil
        }
        if scrollbackRows.indices.contains(index) {
            return scrollbackRows[index].unpacked()
        }
        let liveIndex = index - scrollbackRows.count
        return rows.indices.contains(liveIndex) ? rows[liveIndex] : nil
    }

    private mutating func revealSearchMatchIfNeeded() {
        guard isAlternateScreenActive == false, let match = search.flatMap(\.range) else { return }
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
    private var projectionRowCount: Int { scrollbackRows.count + rows.count }

    /// The active text projection as an indexed sequence. Every point-local query reads through
    /// this rather than `activeProjectionRows()`, which is what keeps a pointer gesture's cost
    /// independent of how much history is retained.
    private func activeProjection() -> ProjectionRows {
        ProjectionRows(
            scrollback: scrollbackRows,
            live: rows,
            isAlternateScreenActive: isAlternateScreenActive
        )
    }

    /// Materializes the whole projection. Reserved for consumers that inherently read all of
    /// history -- search, Select All, history export, width reflow, selected-text serialization.
    /// A query that only touches the clicked point must use `activeProjection()` instead.
    private func activeProjectionRows() -> [GridRow] {
        Array(activeProjection())
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
        guard let lastContentRow = stream.lastIndex(where: rowContainsContent) else {
            return
        }

        for rowIndex in 0...lastContentRow {
            let row = stream[rowIndex]
            let end = projectedCellEnd(in: row)
            forEachRowTextUnit(in: row, rowIndex: rowIndex, absoluteBase: absoluteBase, body)
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
        _ body: (ProjectionUnit) -> Void
    ) {
        let end = projectedCellEnd(in: row)
        var column = 0
        while column < end {
            let cell = row.cell(at: column)
            let width = cell.kind == .wideHead ? 2 : 1
            let scalars: [Unicode.Scalar]?
            switch cell.kind {
            case .narrow, .wideHead:
                scalars = Array(cell.scalars)
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

    private func projectedCellEnd(in row: GridRow) -> Int {
        row.isSoftWrapped ? columnCount : retainedContentEnd(in: row)
    }

    private func text(in range: TextAnchorRange) -> String {
        var result = ""
        forEachProjectionUnit(
            from: activeProjectionRows(),
            absoluteBase: evictedRowCount
        ) { unit in
            if unit.start >= range.start && unit.end <= range.end {
                result.unicodeScalars.append(contentsOf: unit.scalars)
            }
        }
        return result
    }

    /// Pins a just-computed range so a caller can hold it across appends, scrolls, and
    /// evictions. Normalizes its endpoints exactly as `setSelection(_:)` does, so minting a
    /// selection unit and resolving it back is the identity on that unit.
    func pinnedRange(_ range: TerminalTextRange) -> PinnedTextRange {
        let ordered = textPositionPrecedes(range.start, range.end)
            ? (range.start, range.end)
            : (range.end, range.start)
        return PinnedTextRange(
            range: TextAnchorRange(
                start: normalizedSelectionBoundary(ordered.0, isEnd: false),
                end: normalizedSelectionBoundary(ordered.1, isEnd: true)
            ),
            epoch: rowNumberingEpoch.value
        )
    }

    /// Resolves a pinned range against the stream as it is now, or nil once it no longer
    /// names retained text.
    ///
    /// Applies the eviction rule `handleEviction` applies to a settled selection rather than
    /// a second one derived at the call site: a range whose end has been evicted is gone, and
    /// a partially evicted one clamps its start forward to the oldest retained row. A pin
    /// minted before the rows were renumbered is gone outright: it would otherwise resolve to
    /// a position that is in range and wrong, which is worse than nothing.
    func resolvedRange(_ pinned: PinnedTextRange) -> TerminalTextRange? {
        guard pinned.epoch == rowNumberingEpoch.value else { return nil }
        let firstRetained = TextAnchor(row: evictedRowCount, column: 0)
        guard pinned.range.end > firstRetained else { return nil }
        return publicRange(TextAnchorRange(
            start: max(pinned.range.start, firstRetained),
            end: pinned.range.end
        ))
    }

    /// Retires every outstanding pinned range. Call from any mutation after which an absolute
    /// retained row names different text than it did before -- the counter restarting, the
    /// stream re-flowing, one screen replacing another.
    private mutating func renumberRows() {
        rowNumberingEpoch.value &+= 1
    }

    private func publicRange(_ range: TextAnchorRange) -> TerminalTextRange? {
        let base = evictedRowCount
        let streamCount = scrollbackRows.count + rows.count
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
        forEachRowTextUnit(
            in: stream[rowIndex],
            rowIndex: rowIndex,
            absoluteBase: evictedRowCount
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

    /// Returns the needle's matches, scanning only when the cache cannot answer.
    ///
    /// The mutating counterpart of the read in `searchStatus`: navigation runs first and
    /// fills the cache, so the status read that follows it in the same owner-queue job is
    /// a hit rather than a second full scan.
    private mutating func memoizedSearchMatches(for query: String) -> [TextAnchorRange] {
        if let cached = searchMatchCache.matches(for: query) { return cached }
        let computed = searchMatches(for: query)
        searchMatchCache.store(computed, for: query)
        return computed
    }

    private func searchMatches(for query: String) -> [TextAnchorRange] {
        let needleKeys = searchGraphemeKeys(for: query)
        guard needleKeys.isEmpty == false else { return [] }
        let units = projectionUnits()
        guard needleKeys.count <= units.count else { return [] }
        var matches: [TextAnchorRange] = []
        var window = [SearchGraphemeKey?](repeating: nil, count: needleKeys.count)

        for endIndex in units.indices {
            window[endIndex % needleKeys.count] = searchGraphemeKey(for: units[endIndex].scalars)
            guard endIndex + 1 >= needleKeys.count else { continue }
            let startIndex = endIndex - needleKeys.count + 1
            var matchesNeedle = true
            for offset in needleKeys.indices {
                guard window[(startIndex + offset) % needleKeys.count] == needleKeys[offset] else {
                    matchesNeedle = false
                    break
                }
            }
            guard matchesNeedle else { continue }
            matches.append(TextAnchorRange(
                start: units[startIndex].start,
                end: units[endIndex].end
            ))
        }
        return matches
    }

    private func searchGraphemeKeys(for query: String) -> [SearchGraphemeKey] {
        let scalars = Array(query.unicodeScalars)
        guard let first = scalars.first else { return [] }
        var keys: [SearchGraphemeKey] = []
        var cluster = [first]
        var previous = first
        var breakState = GraphemeBreakState()

        for current in scalars.dropFirst() {
            if graphemeBreak(between: previous, and: current, state: &breakState) {
                keys.append(searchGraphemeKey(for: cluster))
                cluster = [current]
                breakState = GraphemeBreakState()
            } else {
                cluster.append(current)
            }
            previous = current
        }
        keys.append(searchGraphemeKey(for: cluster))
        return keys
    }

    private func searchGraphemeKey(for scalars: [Unicode.Scalar]) -> SearchGraphemeKey {
        if scalars.count == 1, let scalar = scalars.first, scalar.value < 0x80 {
            let value = scalar.value
            return .scalar(value >= 0x41 && value <= 0x5A ? value + 0x20 : value)
        }
        let key = canonicalCaselessKey(for: scalars)
        if key.count == 1, let scalar = key.first {
            return .scalar(scalar.value)
        }
        return .scalars(key)
    }

    private func attachments(
        for range: TextAnchorRange,
        in units: [ProjectionUnit],
        rowMetadata: [ReflowRowMetadata],
        oldColumnCount: Int
    ) -> (start: ReflowTextAttachment, end: ReflowTextAttachment) {
        (
            attachment(
                for: range.start,
                prefersStart: true,
                in: units,
                rowMetadata: rowMetadata,
                oldColumnCount: oldColumnCount
            ),
            attachment(
                for: range.end,
                prefersStart: false,
                in: units,
                rowMetadata: rowMetadata,
                oldColumnCount: oldColumnCount
            )
        )
    }

    private func attachment(
        for anchor: TextAnchor,
        prefersStart: Bool,
        in units: [ProjectionUnit],
        rowMetadata: [ReflowRowMetadata],
        oldColumnCount: Int
    ) -> ReflowTextAttachment {
        if prefersStart, let unit = units.first(where: { $0.start == anchor }) {
            return attachment(
                for: unit,
                usesStart: true,
                rowMetadata: rowMetadata,
                oldColumnCount: oldColumnCount
            )
        }
        if let unit = units.first(where: { $0.end == anchor }) {
            return attachment(
                for: unit,
                usesStart: false,
                rowMetadata: rowMetadata,
                oldColumnCount: oldColumnCount
            )
        }
        if let unit = units.first(where: { $0.start >= anchor }) {
            return attachment(
                for: unit,
                usesStart: true,
                rowMetadata: rowMetadata,
                oldColumnCount: oldColumnCount
            )
        }
        return .lineEnd(rowMetadata.last?.line ?? 0)
    }

    private func attachment(
        for unit: ProjectionUnit,
        usesStart: Bool,
        rowMetadata: [ReflowRowMetadata],
        oldColumnCount: Int
    ) -> ReflowTextAttachment {
        let sourceRow = unit.start.row - evictedRowCount
        if unit.isHardBoundary {
            return usesStart
                ? .lineEnd(rowMetadata[sourceRow].line)
                : .lineStart(rowMetadata[sourceRow + 1].line)
        }
        return .cell(
            key: sourceKey(
                row: sourceRow,
                column: unit.start.column,
                columns: oldColumnCount
            ),
            width: unit.end.column - unit.start.column,
            usesStart: usesStart
        )
    }

    private func textDestination(
        for attachment: ReflowTextAttachment,
        lineIndex: Int,
        packed: PackedReflowLine,
        baseRow: Int
    ) -> TextAnchor? {
        switch attachment {
        case let .cell(key, width, usesStart):
            guard let destination = packed.cellDestinations[key] else { return nil }
            return TextAnchor(
                row: evictedRowCount + baseRow + destination.row,
                column: destination.column + (usesStart ? 0 : width)
            )
        case let .lineStart(line) where line == lineIndex:
            return TextAnchor(row: evictedRowCount + baseRow, column: 0)
        case let .lineEnd(line) where line == lineIndex:
            return TextAnchor(
                row: evictedRowCount + baseRow + packed.contentEnd.row,
                column: packed.contentEnd.column
            )
        default:
            return nil
        }
    }

    private mutating func refreshHasInteractionState() {
        hasInteractionState = selection != nil
            || search != nil
            || hoveredLinkState != nil
            || armedLinkState != nil
    }

    private mutating func clearInspection() {
        selection = nil
        search = nil
        hoveredLinkState = nil
        armedLinkState = nil
        viewportState = .following
    }

    private mutating func invalidateInspection(inViewportRows range: Range<Int>) {
        guard range.isEmpty == false else { return }
        if viewportState == .following {
            recordDamage(rows: range)
        } else {
            recordFullDamage()
        }
        guard hasInteractionState else { return }
        let lower = evictedRowCount + scrollbackRows.count + range.lowerBound
        let upper = evictedRowCount + scrollbackRows.count + range.upperBound - 1
        invalidateInspection(inAbsoluteRows: lower...upper)
    }

    private mutating func invalidateInspection(inScrollbackRow row: Int) {
        if viewportState != .following {
            recordFullDamage()
        }
        guard hasInteractionState else { return }
        let absoluteRow = evictedRowCount + row
        invalidateInspection(inAbsoluteRows: absoluteRow...absoluteRow)
    }

    private mutating func invalidateInspection(inAbsoluteRows rows: ClosedRange<Int>) {
        if let selection, range(selection, intersects: rows) {
            self.selection = nil
        }
        // Only the occurrence, never the needle: a search whose match was overwritten is
        // still an open search, and `reattachToNewestMatch` is what re-selects for it.
        // Dropping the whole search here would strand the user in a state only retyping
        // the needle can leave, because navigation short-circuits on a nil query.
        if let match = search?.range, range(match, intersects: rows) {
            self.search?.range = nil
        }
        if let hoveredLinkState, range(hoveredLinkState.range, intersects: rows) {
            self.hoveredLinkState = nil
        }
        if let armedLinkState, range(armedLinkState.range, intersects: rows) {
            self.armedLinkState = nil
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

    private mutating func clampSelectionToRetainedStream() {
        guard var selection else { return }
        selection.start.column = min(max(selection.start.column, 0), columnCount)
        selection.end.column = min(max(selection.end.column, 0), columnCount)
        let lastRow = evictedRowCount + scrollbackRows.count + rows.count - 1
        let lastAnchor = TextAnchor(row: lastRow, column: projectedCellEnd(in: rows.last!))
        if selection.start > lastAnchor {
            selection.start = lastAnchor
        }
        if selection.end > lastAnchor {
            selection.end = lastAnchor
        }
        self.selection = selection
    }

    private mutating func handleEviction(of rowCount: Int) {
        guard rowCount > 0 else { return }
        evictedRowCount += rowCount
        let firstRetained = TextAnchor(row: evictedRowCount, column: 0)
        if var selection {
            if selection.end <= firstRetained {
                self.selection = nil
            } else {
                selection.start = max(selection.start, firstRetained)
                self.selection = selection
            }
        }
        // Occurrence only, for the reason on `invalidateInspection`. Note the contrast
        // with `selection` just above, which clamps its start forward and drops only
        // when it is entirely gone -- an evicted match has no equivalent clamp, so it
        // releases the occurrence and leaves the needle for navigation to re-attach.
        if let match = search?.range, match.start < firstRetained {
            self.search?.range = nil
        }
        if let hoveredLinkState, hoveredLinkState.range.start < firstRetained {
            self.hoveredLinkState = nil
        }
        if let armedLinkState, armedLinkState.range.start < firstRetained {
            self.armedLinkState = nil
        }
        if case let .browsing(anchor) = viewportState, anchor < firstRetained {
            viewportState = .browsing(top: firstRetained)
        }
        clampViewportAnchorToRetainedStream()
    }

    private mutating func clampViewportAnchorToRetainedStream() {
        guard case let .browsing(anchor) = viewportState else { return }
        let maximumTop = evictedRowCount + max(0, scrollbackRows.count + rows.count - rowCount)
        viewportState = .browsing(top: TextAnchor(
            row: min(max(anchor.row, evictedRowCount), maximumTop),
            column: 0
        ))
    }

    /// Bytes a `[GridCell]` array header costs on top of its elements. Not derived from
    /// `MemoryLayout`, which describes the elements rather than the buffer holding them.
    static let arrayStorageHeaderBytes = 32

    /// What history really costs, so the byte budget means what it says.
    ///
    /// Every term is the true size of something the row owns: its slot in the buffer, the header
    /// of its cell array, the cells themselves at their **stride** (what a cell costs *in an
    /// array*, the only way cells are stored), and one spill allocation per multi-scalar cell.
    ///
    /// The previous model charged `16 + cells * (32 + 8 * scalars)` -- 40 bytes for an ordinary
    /// single-scalar cell against a true stride of 72. It therefore admitted ~2.2x the history it
    /// promised: a 10 MB budget held ~22 MB (doc 15's `H1`, measured in `15/F2`).
    ///
    /// Cells are charged at `capacity`, not `count`, and that is the whole of doc 15's `D4`. A row's
    /// cell array is not allocated at its element count: malloc rounds the request up to a size
    /// class, and Swift then reports the block it really got as `capacity` -- 90 cells' worth at 80
    /// columns, 218 at 200. Charging `count` therefore under-charged every row by that rounding,
    /// which `15/F7` measured at ~11.5%.
    ///
    /// Reading `capacity` rather than modelling the size classes is what makes this affordable.
    /// `15/F7` declined to model bucket rounding because a table of allocator size classes is a
    /// platform detail this model cannot portably encode -- true, and still true. `capacity` is the
    /// allocator's own answer to the same question, so the rounding is charged without anyone
    /// predicting it. `retainedScrollbackAllocationBytes` re-derives the same total independently,
    /// and a test holds it against the budget.
    ///
    /// This also decouples the budget from the cell's width, which is why `15/F12` needed it: a
    /// narrower cell that leaves the row in the same malloc bucket now admits the same history it
    /// always did, instead of admitting more rows that each cost what they always cost.
    private static func scrollbackByteCost(of row: PackedRetainedRow) -> Int {
        var total = MemoryLayout<PackedRetainedRow>.stride
            + arrayStorageHeaderBytes
            + row.storage.capacity
        if row.spillCount > 0 {
            // The spill directory is a real allocation the packed row owns, charged even
            // though doc 28's model priced only the spills it points at -- `I4` is that the
            // charge describes what the row allocates, not what a candidate predicted.
            total += arrayStorageHeaderBytes + row.spills.capacity * MemoryLayout<[Unicode.Scalar]>.stride
            for spill in row.spills {
                total += arrayStorageHeaderBytes + spill.capacity * MemoryLayout<Unicode.Scalar>.stride
            }
        }
        return total
    }

    /// Prices a row the retained buffer has not admitted yet, by packing it. Used by the
    /// test-facing sizing helpers below, which choose eviction boundaries in whole rows.
    private static func scrollbackByteCost(of row: GridRow) -> Int {
        scrollbackByteCost(of: PackedRetainedRow.pack(row))
    }

    private mutating func appendToScrollback<S: Sequence>(_ newRows: S)
    where S.Element == GridRow {
        for sourceRow in newRows {
            // `pack` trims to canonical form (`I2`) as it encodes, so admission never
            // materializes the trimmed row -- see the note on `pack`. This is what makes
            // history's representation `C1` while the live grid stays untouched (`I1`).
            let row = PackedRetainedRow.pack(sourceRow)
            scrollbackRows.append(row)
            scrollbackByteCount += Self.scrollbackByteCost(of: row)
            scrollbackStoredCellCount += row.storedCellCount
        }
    }

    private mutating func enforceScrollbackBudget() {
        // Carry the one bit we need rather than the row that holds it: retaining the `GridRow`
        // across the loop and until scope exit pins its cells -- a whole row's allocation -- for
        // nothing. Same defect class as the one `removeFirst` just stopped committing.
        var lastEvictedIsSoftWrapped: Bool?
        var evictedCount = 0
        // Three bounds, whichever binds first. The byte budget bounds memory; the cell and row
        // caps bound the two terms of reflow cost, which is what a width change pays and what
        // bytes stopped bounding once packing cut a stored cell to ~1 B. See
        // `productionScrollbackCellCap`.
        while scrollbackByteCount > scrollbackBudgetBytes
            || scrollbackRows.count > scrollbackRowCap
            || scrollbackStoredCellCount > scrollbackCellCap
        {
            let evicted = scrollbackRows.removeFirst()
            scrollbackByteCount -= Self.scrollbackByteCost(of: evicted)
            scrollbackStoredCellCount -= evicted.storedCellCount
            lastEvictedIsSoftWrapped = evicted.isSoftWrapped
            evictedCount += 1
        }
        if let lastEvictedIsSoftWrapped {
            isHistoryHeadTruncated = lastEvictedIsSoftWrapped
        }
        if evictedCount > 0 { primaryHistoryObservation.value &+= 1 }
        handleEviction(of: evictedCount)
    }

    /// Projects cell roles, row wraps, and cursor state without exposing mutable storage.
    public var geometry: TerminalGeometry {
        let projection = scrollProjection
        let windowRows = presentedRowGeometry
        let cursorStreamRow = isAlternateScreenActive
            ? cursor.row
            : scrollbackRows.count + cursor.row
        let cursorWindowRow = cursorStreamRow - projection.topRow
        return TerminalGeometry(
            columns: columnCount,
            rows: windowRows,
            cursor: windowRows.indices.contains(cursorWindowRow)
                ? TerminalCursor(
                    row: cursorWindowRow,
                    column: cursor.column,
                    isPendingWrap: isPendingWrap
                )
                : nil
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
        let cell = windowRow.cell(at: column)
        return TerminalCell(
            kind: cell.kind,
            scalars: cell.scalars,
            style: style(for: cell.styleId),
            hyperlink: cell.hyperlinkId.flatMap { hyperlinkTargets[$0] }
        )
    }

    /// Visits one viewport row's content in a single row resolution, passing each
    /// column the two fields a renderer actually consumes.
    ///
    /// `cell(row:column:)` answers the same question per coordinate, but it re-resolves
    /// the row on every call and materializes a whole `TerminalCell` -- and the render
    /// planner, which reads a full row per frame, uses two of that value's four fields
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
    public func forEachViewportCell(
        row: Int,
        _ body: (_ column: Int, _ scalars: TerminalScalars, _ style: TerminalStyle) -> Void
    ) {
        guard row >= 0, row < rowCount else { return }
        let streamRow = scrollProjection.topRow + row
        // Memoized because a row is a handful of style runs, not `columnCount` distinct styles:
        // without it every column would pay a dictionary lookup that the previous column already
        // did. Correct for any content -- a miss just re-resolves.
        var lastId: StyleId?
        var lastStyle = TerminalStyle()
        var storedCount = 0
        func emit(_ column: Int, _ scalars: TerminalScalars, _ styleId: StyleId) {
            if styleId != lastId {
                lastStyle = self.style(for: styleId)
                lastId = styleId
            }
            body(column, scalars, lastStyle)
            storedCount = column + 1
        }

        // Retained rows stream out of packed storage rather than being materialized first.
        // A frame reads every visible row once and discards it, so `unpacked()` here bought
        // an allocation and a full `GridCell` write per cell that nothing outlived --
        // `28/F17` measured that as the dominant term in the browsing regression, and the
        // pre-packing representation never paid it because it could return its stored array
        // by reference.
        if isAlternateScreenActive == false, scrollbackRows.indices.contains(streamRow) {
            scrollbackRows[streamRow].forEachContentCell { emit($0, $1, $2) }
        } else {
            guard let windowRow = viewportStreamRow(at: streamRow) else { return }
            for column in windowRow.cells.indices {
                let cell = windowRow.cells[column]
                emit(column, cell.scalars, cell.styleId)
            }
        }

        guard storedCount < columnCount else { return }
        let padding = GridCell()
        if padding.styleId != lastId {
            lastStyle = self.style(for: padding.styleId)
        }
        for column in storedCount..<columnCount {
            body(column, padding.scalars, lastStyle)
        }
    }

    /// Positions future parser actions while preserving the same cursor validity rules.
    mutating func moveCursor(row: Int, column: Int) {
        cursor.row = min(max(row, 0), rowCount - 1)
        cursor.column = min(max(column, 0), columnCount - 1)
        isPendingWrap = false
        clusterContext = nil
    }

    /// Erases a row range with pen colors after expanding across intersected wide pairs.
    mutating func eraseCells(row: Int, columns: Range<Int>) {
        guard rows.indices.contains(row), columns.isEmpty == false else { return }
        var lower = max(0, columns.lowerBound)
        var upper = min(columnCount, columns.upperBound)
        guard lower < upper else { return }
        if self.rows[row].cells[lower].kind == .wideTail {
            lower -= 1
        }
        if self.rows[row].cells[upper - 1].kind == .wideHead {
            upper += 1
        }
        lower = max(0, lower)
        upper = min(upper, columnCount)

        invalidateInspection(inViewportRows: row..<(row + 1))

        let styleId = backgroundEraseStyleId()
        // The expansion above pulls every intersected wide pair wholly inside the
        // range, so no cell in it has a partner outside it. That is what lets the
        // interior be filled directly instead of through a per-cell
        // `clearCellAndPair`, whose two nested array subscripts cost a COW
        // uniqueness check on the row array and another on the cell array for
        // every single cell erased.
        let blank = GridCell(styleId: styleId)
        rows[row].cells.withUnsafeMutableBufferPointer { cells in
            for column in lower..<upper {
                cells[column] = blank
            }
        }
        // Loop-invariant: the repair is a no-op above column 1, so it runs once
        // for the range rather than once per erased cell. It is idempotent, so
        // the old per-cell calls at columns 0 and 1 did the work of this one.
        if lower <= 1 {
            clearPreviousSpacer(beforeRow: row, column: lower, replacementStyleId: styleId)
        }
        clusterContext = nil
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
        _ sourceRows: [GridRow],
        columns: Int,
        rows: Int,
        clearsSoftWrap: Bool
    ) -> [GridRow] {
        (0..<rows).map { rowIndex in
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
            let preservesSpacer = clearsRowWrap == false
                && keepsContinuation
                && sourceRows[rowIndex + 1].cells.first?.kind == .wideHead
            repairClippedCells(&cells, clearsSpacers: preservesSpacer == false)
            return GridRow(
                cells: cells,
                isSoftWrapped: clearsRowWrap ? false : source.isSoftWrapped,
                semanticPrompt: source.semanticPrompt
            )
        }
    }

    private mutating func repairClippedCells(_ cells: inout [GridCell], clearsSpacers: Bool) {
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
            case .spacerHead:
                if clearsSpacers {
                    invalidColumns.append(column)
                }
            case .padding, .narrow:
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
            while rows.count > newRowCount,
                  rows.indices.last.map({ $0 > cursor.row }) == true,
                  let last = rows.last,
                  last.isSoftWrapped == false,
                  last.cells.allSatisfy({ $0.kind == .padding })
            {
                rows.removeLast()
            }

            let displacedCount = rows.count - newRowCount
            if displacedCount > 0 {
                appendToScrollback(rows.prefix(displacedCount))
                rows.removeFirst(displacedCount)
                if cursor.row < displacedCount {
                    cursor.row = 0
                } else {
                    cursor.row -= displacedCount
                }
                enforceScrollbackBudget()
            }
        } else {
            let addedCount = newRowCount - rowCount
            var pulledCount = 0
            if cursor.row == rowCount - 1 {
                pulledCount = min(addedCount, scrollbackRows.count)
                if pulledCount > 0 {
                    let split = scrollbackRows.count - pulledCount
                    let pulled = scrollbackRows.suffix(from: split)
                    scrollbackByteCount -= pulled.reduce(0) {
                        $0 + Self.scrollbackByteCost(of: $1)
                    }
                    // Counted off the *packed* rows, not off `pulled`: `suffix(from:)`
                    // materializes to full width, so its rows no longer carry the stored
                    // extent the cell cap is denominated in.
                    var pulledCells = 0
                    for index in split..<scrollbackRows.count {
                        pulledCells += scrollbackRows[index].storedCellCount
                    }
                    scrollbackStoredCellCount -= pulledCells
                    scrollbackRows.removeLast(pulledCount)
                    rows.insert(
                        contentsOf: pulled.map { $0.materialized(to: columnCount) },
                        at: 0
                    )
                    cursor.row += pulledCount
                }
            }
            rows.append(contentsOf: (pulledCount..<addedCount).map { _ in
                makeBlankRow(columns: columnCount)
            })
        }
        rowCount = newRowCount
        clampViewportAnchorToRetainedStream()
    }

    private mutating func resizeWidth(to newColumnCount: Int) {
        // Reflow redistributes logical lines across rows, so a row keeps its number and loses
        // its text. Height-only resizes never reach here, and must not.
        renumberRows()
        let oldUnits = projectionUnits()
        let oldColumnCount = columnCount
        let oldBottomDistance = rowCount - 1 - cursor.row
        let oldCursorGlobalRow = scrollbackRows.count + cursor.row
        let fullStream = scrollbackRows.asArray() + rows
        let lastContentRow = fullStream.lastIndex(where: rowContainsContent) ?? 0
        let browsingSourceGlobalRow: Int?
        if case let .browsing(anchor) = viewportState {
            browsingSourceGlobalRow = min(
                max(anchor.row - evictedRowCount, 0),
                fullStream.count - 1
            )
        } else {
            browsingSourceGlobalRow = nil
        }
        let retainedLastRow = max(
            oldCursorGlobalRow,
            lastContentRow,
            browsingSourceGlobalRow ?? 0
        )
        let sourceRows = Array(fullStream[...retainedLastRow])
        let reconstruction = reconstructLogicalLines(
            from: sourceRows,
            cursorGlobalRow: oldCursorGlobalRow,
            viewportTopGlobalRow: scrollbackRows.count,
            oldColumnCount: oldColumnCount
        )
        let selectionAttachments: (
            start: ReflowTextAttachment,
            end: ReflowTextAttachment
        )? = selection.flatMap { selection in
            guard oldUnits.isEmpty == false else { return nil }
            return attachments(
                for: selection,
                in: oldUnits,
                rowMetadata: reconstruction.rowMetadata,
                oldColumnCount: oldColumnCount
            )
        }
        let searchAttachments = search?.range.map {
            attachments(
                for: $0,
                in: oldUnits,
                rowMetadata: reconstruction.rowMetadata,
                oldColumnCount: oldColumnCount
            )
        }
        let hoverAttachments = hoveredLinkState.map {
            attachments(
                for: $0.range,
                in: oldUnits,
                rowMetadata: reconstruction.rowMetadata,
                oldColumnCount: oldColumnCount
            )
        }
        let armAttachments = armedLinkState.map {
            attachments(
                for: $0.range,
                in: oldUnits,
                rowMetadata: reconstruction.rowMetadata,
                oldColumnCount: oldColumnCount
            )
        }

        var rebuiltRows: [GridRow] = []
        var cursorDestination: ReflowDestination?
        var selectionStartDestination: TextAnchor?
        var selectionEndDestination: TextAnchor?
        var searchStartDestination: TextAnchor?
        var searchEndDestination: TextAnchor?
        var hoverStartDestination: TextAnchor?
        var hoverEndDestination: TextAnchor?
        var armStartDestination: TextAnchor?
        var armEndDestination: TextAnchor?
        var viewportTopDestinationRow = 0
        var browsingTopDestinationRow: Int?
        for (lineIndex, line) in reconstruction.lines.enumerated() {
            let packed = pack(line: line, columns: newColumnCount)
            let baseRow = rebuiltRows.count

            if lineIndex == reconstruction.viewportTopLine {
                if let key = reconstruction.viewportTopKey,
                   let local = packed.cellDestinations[key]
                {
                    viewportTopDestinationRow = baseRow + local.row
                } else {
                    viewportTopDestinationRow = baseRow
                }
            }
            if let browsingSourceGlobalRow {
                let metadata = reconstruction.rowMetadata[browsingSourceGlobalRow]
                if lineIndex == metadata.line {
                    if let key = metadata.firstSourceKey,
                       let local = packed.cellDestinations[key]
                    {
                        browsingTopDestinationRow = baseRow + local.row
                    } else {
                        browsingTopDestinationRow = baseRow
                    }
                }
            }

            switch reconstruction.anchor {
            case let .cell(key) where lineIndex == reconstruction.cursorLine:
                if let local = packed.cellDestinations[key] {
                    cursorDestination = ReflowDestination(
                        row: baseRow + local.row,
                        column: local.column,
                        isPendingWrap: false
                    )
                }
            case let .trailingPadding(line, distance, allPaddingColumn) where line == lineIndex:
                if let allPaddingColumn {
                    cursorDestination = ReflowDestination(
                        row: baseRow,
                        column: min(allPaddingColumn, newColumnCount - 1),
                        isPendingWrap: false
                    )
                } else {
                    // `contentEnd.column` is one past the line's last committed cell, so the
                    // cursor wants to sit at `contentEnd.column + distance`. That can land
                    // past the right margin and has to clamp. Clamping onto a blank is
                    // harmless, but when the reflowed content fills the row exactly the
                    // clamp would park the cursor *on* the final character, and the next
                    // printed scalar would overwrite committed output rather than wrap --
                    // e.g. 19 columns of text narrowed to a 19-column grid turned the next
                    // keystroke into "some long long texX".
                    //
                    // DanTerm has no one-past-the-end cursor column: everywhere else, "past
                    // the last cell of a full row" is spelled as the last column plus a
                    // deferred wrap (`printNarrow` arms `isPendingWrap` instead of moving to
                    // a column that does not exist). Reflow has to use that same spelling,
                    // or the distinction is lost in the clamp.
                    let desired = packed.contentEnd.column + distance
                    cursorDestination = ReflowDestination(
                        row: baseRow + packed.contentEnd.row,
                        column: min(desired, newColumnCount - 1),
                        isPendingWrap: distance == 0 && packed.contentEnd.column == newColumnCount
                    )
                }
            case let .boundary(line, offset) where line == lineIndex:
                if let local = packed.boundaryDestinations[offset] {
                    cursorDestination = ReflowDestination(
                        row: baseRow + local.row,
                        column: local.column,
                        isPendingWrap: local.isPendingWrap
                    )
                }
            default:
                break
            }
            if let selectionAttachments {
                selectionStartDestination = selectionStartDestination ?? textDestination(
                    for: selectionAttachments.start,
                    lineIndex: lineIndex,
                    packed: packed,
                    baseRow: baseRow
                )
                selectionEndDestination = selectionEndDestination ?? textDestination(
                    for: selectionAttachments.end,
                    lineIndex: lineIndex,
                    packed: packed,
                    baseRow: baseRow
                )
            }
            if let searchAttachments {
                searchStartDestination = searchStartDestination ?? textDestination(
                    for: searchAttachments.start,
                    lineIndex: lineIndex,
                    packed: packed,
                    baseRow: baseRow
                )
                searchEndDestination = searchEndDestination ?? textDestination(
                    for: searchAttachments.end,
                    lineIndex: lineIndex,
                    packed: packed,
                    baseRow: baseRow
                )
            }
            if let hoverAttachments {
                hoverStartDestination = hoverStartDestination ?? textDestination(
                    for: hoverAttachments.start,
                    lineIndex: lineIndex,
                    packed: packed,
                    baseRow: baseRow
                )
                hoverEndDestination = hoverEndDestination ?? textDestination(
                    for: hoverAttachments.end,
                    lineIndex: lineIndex,
                    packed: packed,
                    baseRow: baseRow
                )
            }
            if let armAttachments {
                armStartDestination = armStartDestination ?? textDestination(
                    for: armAttachments.start,
                    lineIndex: lineIndex,
                    packed: packed,
                    baseRow: baseRow
                )
                armEndDestination = armEndDestination ?? textDestination(
                    for: armAttachments.end,
                    lineIndex: lineIndex,
                    packed: packed,
                    baseRow: baseRow
                )
            }
            rebuiltRows.append(contentsOf: packed.rows)
        }

        let destination = cursorDestination ?? ReflowDestination(
            row: 0,
            column: min(cursor.column, newColumnCount - 1),
            isPendingWrap: false
        )
        let continuationIncrease = max(
            0,
            destination.row - viewportTopDestinationRow - cursor.row
        )
        let desiredBottomDistance = max(0, oldBottomDistance - continuationIncrease)
        let requiredRowCount = max(
            rowCount,
            destination.row + desiredBottomDistance + 1
        )
        while rebuiltRows.count < requiredRowCount {
            rebuiltRows.append(makeBlankRow(columns: newColumnCount))
        }

        let viewportStart = rebuiltRows.count - rowCount
        scrollbackRows = ScrollbackBuffer(rebuiltRows[..<viewportStart])
        scrollbackByteCount = recomputedScrollbackByteCount
        scrollbackStoredCellCount = recomputedScrollbackStoredCellCount
        rows = Array(rebuiltRows[viewportStart...])
        columnCount = newColumnCount
        cursor = CellPosition(
            row: max(0, destination.row - viewportStart),
            column: destination.column
        )
        isPendingWrap = destination.isPendingWrap
        if selectionAttachments != nil {
            if let start = selectionStartDestination, let end = selectionEndDestination {
                selection = TextAnchorRange(start: min(start, end), end: max(start, end))
            } else {
                selection = nil
            }
        }
        if searchAttachments != nil {
            if let start = searchStartDestination, let end = searchEndDestination {
                search?.range = TextAnchorRange(start: min(start, end), end: max(start, end))
            } else {
                search = nil
            }
        }
        if hoverAttachments != nil {
            if let start = hoverStartDestination, let end = hoverEndDestination {
                hoveredLinkState?.range = TextAnchorRange(
                    start: min(start, end),
                    end: max(start, end)
                )
            } else {
                hoveredLinkState = nil
            }
        }
        if armAttachments != nil {
            if let start = armStartDestination, let end = armEndDestination {
                armedLinkState?.range = TextAnchorRange(
                    start: min(start, end),
                    end: max(start, end)
                )
            } else {
                armedLinkState = nil
            }
        }
        if let browsingTopDestinationRow {
            viewportState = .browsing(top: TextAnchor(
                row: evictedRowCount + browsingTopDestinationRow,
                column: 0
            ))
        }
        enforceScrollbackBudget()
        clampViewportAnchorToRetainedStream()
    }

    private func reconstructLogicalLines(
        from sourceRows: [GridRow],
        cursorGlobalRow: Int,
        viewportTopGlobalRow: Int,
        oldColumnCount: Int
    ) -> (
        lines: [ReflowLine],
        anchor: ReflowCursorAnchor,
        cursorLine: Int,
        viewportTopLine: Int,
        viewportTopKey: Int?,
        rowMetadata: [ReflowRowMetadata]
    ) {
        var lines: [ReflowLine] = []
        var currentLine = ReflowLine()
        var metadata: [ReflowRowMetadata] = []
        var logicalOffset = 0
        var pendingSpacerKeys: [Int] = []
        var retainedSourceKeys = Set<Int>()

        for (rowIndex, row) in sourceRows.enumerated() {
            if currentLine.semanticPrompt == .none || row.semanticPrompt == .prompt {
                currentLine.semanticPrompt = row.semanticPrompt
            }
            let retainedEnd = retainedContentEnd(in: row)
            let iterationEnd = row.isSoftWrapped ? oldColumnCount : retainedEnd
            var column = 0
            var firstSourceKey: Int?
            while column < iterationEnd {
                let cell = row.cell(at: column)
                let key = sourceKey(row: rowIndex, column: column, columns: oldColumnCount)
                switch cell.kind {
                case .spacerHead:
                    firstSourceKey = firstSourceKey ?? key
                    pendingSpacerKeys.append(key)
                    column += 1
                case .wideHead:
                    firstSourceKey = firstSourceKey ?? key
                    var sources = pendingSpacerKeys.map { (key: $0, offset: 0) }
                    pendingSpacerKeys.removeAll(keepingCapacity: true)
                    sources.append((key: key, offset: 0))
                    retainedSourceKeys.insert(key)
                    if column + 1 < oldColumnCount {
                        let tailKey = sourceKey(
                            row: rowIndex,
                            column: column + 1,
                            columns: oldColumnCount
                        )
                        sources.append((key: tailKey, offset: 1))
                        retainedSourceKeys.insert(tailKey)
                    }
                    for source in sources {
                        retainedSourceKeys.insert(source.key)
                    }
                    currentLine.units.append(ReflowUnit(
                        cells: [
                            cell,
                            GridCell(
                                kind: .wideTail,
                                styleId: cell.styleId,
                                hyperlinkId: cell.hyperlinkId,
                                contentIdentity: cell.contentIdentity
                            ),
                        ],
                        sourceOffsets: sources
                    ))
                    logicalOffset += 2
                    column += 2
                case .narrow, .padding:
                    firstSourceKey = firstSourceKey ?? key
                    currentLine.units.append(ReflowUnit(
                        cells: [cell],
                        sourceOffsets: [(key: key, offset: 0)]
                    ))
                    retainedSourceKeys.insert(key)
                    logicalOffset += 1
                    column += 1
                case .wideTail:
                    column += 1
                }
            }

            metadata.append(ReflowRowMetadata(
                line: lines.count,
                boundaryOffset: logicalOffset,
                retainedEnd: retainedEnd,
                firstSourceKey: firstSourceKey
            ))
            if row.isSoftWrapped == false {
                lines.append(currentLine)
                currentLine = ReflowLine()
                logicalOffset = 0
                pendingSpacerKeys.removeAll(keepingCapacity: true)
            }
        }
        if sourceRows.last?.isSoftWrapped == true {
            lines.append(currentLine)
        }

        let cursorMetadata = metadata[cursorGlobalRow]
        let viewportTopMetadata = metadata[viewportTopGlobalRow]
        let cursorKey = sourceKey(
            row: cursorGlobalRow,
            column: cursor.column,
            columns: oldColumnCount
        )
        let anchor: ReflowCursorAnchor
        if isPendingWrap {
            anchor = .boundary(
                line: cursorMetadata.line,
                offset: cursorMetadata.boundaryOffset
            )
        } else if retainedSourceKeys.contains(cursorKey) {
            anchor = .cell(key: cursorKey)
        } else if cursorMetadata.retainedEnd == 0 {
            anchor = .trailingPadding(
                line: cursorMetadata.line,
                distance: 0,
                allPaddingColumn: cursor.column
            )
        } else {
            anchor = .trailingPadding(
                line: cursorMetadata.line,
                distance: max(0, cursor.column - cursorMetadata.retainedEnd),
                allPaddingColumn: nil
            )
        }

        return (
            lines,
            anchor,
            cursorMetadata.line,
            viewportTopMetadata.line,
            viewportTopMetadata.firstSourceKey,
            metadata
        )
    }

    private func pack(line: ReflowLine, columns: Int) -> PackedReflowLine {
        var packedRows = [makeBlankRow(columns: columns)]
        packedRows[0].semanticPrompt = line.semanticPrompt
        var cellDestinations: [Int: ReflowDestination] = [:]
        var boundaryDestinations = [
            0: ReflowDestination(row: 0, column: 0, isPendingWrap: false),
        ]
        var row = 0
        var column = 0
        var logicalOffset = 0

        for unit in line.units {
            if column == columns {
                packedRows[row].isSoftWrapped = true
                packedRows.append(makeBlankRow(columns: columns))
                row += 1
                column = 0
                if line.semanticPrompt != .none {
                    packedRows[row].semanticPrompt = .continuation
                }
            }
            if unit.cells.count == 2, columns - column == 1 {
                packedRows[row].cells[column] = GridCell(
                    kind: .spacerHead,
                    styleId: unit.cells[0].styleId,
                    hyperlinkId: unit.cells[0].hyperlinkId,
                    contentIdentity: unit.cells[0].contentIdentity
                )
                packedRows[row].isSoftWrapped = true
                packedRows.append(makeBlankRow(columns: columns))
                row += 1
                column = 0
                if line.semanticPrompt != .none {
                    packedRows[row].semanticPrompt = .continuation
                }
            }

            for (offset, cell) in unit.cells.enumerated() {
                packedRows[row].cells[column + offset] = cell
            }
            for source in unit.sourceOffsets {
                cellDestinations[source.key] = ReflowDestination(
                    row: row,
                    column: column + source.offset,
                    isPendingWrap: false
                )
            }
            column += unit.cells.count
            logicalOffset += unit.cells.count
            boundaryDestinations[logicalOffset] = column == columns
                ? ReflowDestination(row: row, column: columns - 1, isPendingWrap: true)
                : ReflowDestination(row: row, column: column, isPendingWrap: false)
        }

        return PackedReflowLine(
            rows: packedRows,
            cellDestinations: cellDestinations,
            boundaryDestinations: boundaryDestinations,
            contentEnd: ReflowDestination(
                row: row,
                column: column,
                isPendingWrap: false
            )
        )
    }

    private func retainedContentEnd(in row: GridRow) -> Int {
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

    private func sourceKey(row: Int, column: Int, columns: Int) -> Int {
        row * columns + column
    }

    private func makeBlankRow(
        columns: Int,
        styleId: StyleId = Terminal.defaultStyleId
    ) -> GridRow {
        GridRow(cells: (0..<columns).map { _ in GridCell(styleId: styleId) })
    }

    private mutating func dispatchCSI(_ sequence: CSISequence) {
        if sequence.intermediates == [0x21] {
            guard sequence.final == 0x70, sequence.parameters.isEmpty else { return }
            softReset()
            return
        }
        if sequence.intermediates == [0x3F] {
            switch sequence.final {
            case 0x68:
                applyDECPrivateModes(sequence.parameters, enabled: true)
            case 0x6C:
                applyDECPrivateModes(sequence.parameters, enabled: false)
            case 0x6E:
                replyToStatusQuery(sequence.parameters, isDECPrivate: true)
            case 0x75:
                guard sequence.parameters.isEmpty else { return }
                appendReply("\u{1B}[?\(activeKittyKeyboardStack.last ?? 0)u")
            default:
                break
            }
            return
        }
        if sequence.intermediates == [0x3E] {
            if sequence.final == 0x71,
               sequence.parameters.isEmpty || sequence.parameters == [0]
            {
                appendReply("\u{1B}P>|DanTerm \(programVersion)\u{1B}\\")
                return
            }
            guard sequence.final == 0x75, sequence.parameters.count <= 1 else { return }
            pushKittyKeyboardFlags(sequence.parameters.first ?? 0)
            return
        }
        if sequence.intermediates == [0x3C] {
            guard sequence.final == 0x75, sequence.parameters.count <= 1 else { return }
            popKittyKeyboardFlags(sequence.parameters.first ?? 1)
            return
        }
        if sequence.intermediates == [0x3D] {
            guard sequence.final == 0x75, sequence.parameters.count <= 2 else { return }
            setKittyKeyboardFlags(
                sequence.parameters.first ?? 0,
                mode: sequence.parameters.dropFirst().first ?? 1
            )
            return
        }
        if sequence.intermediates == [0x3F, 0x24] {
            guard sequence.final == 0x70 else { return }
            replyToModeQuery(sequence.parameters, isDECPrivate: true)
            return
        }
        if sequence.intermediates == [0x24] {
            guard sequence.final == 0x70 else { return }
            replyToModeQuery(sequence.parameters, isDECPrivate: false)
            return
        }
        if sequence.intermediates == [0x20] {
            guard sequence.final == 0x71, sequence.parameters.count <= 1 else { return }
            applyCursorStyle(sequence.parameters.first ?? 0)
            return
        }
        guard sequence.intermediates.isEmpty else { return }

        switch sequence.final {
        case 0x63:
            guard sequence.parameters.isEmpty || sequence.parameters == [0] else { return }
            appendReply("\u{1B}[?1;2c")
        case 0x6E:
            replyToStatusQuery(sequence.parameters, isDECPrivate: false)
        case 0x41, 0x6B:
            guard let amount = movementAmount(sequence.parameters) else { return }
            movePositionedCursor(row: cursor.row - amount, column: cursor.column)
        case 0x42, 0x65:
            guard let amount = movementAmount(sequence.parameters) else { return }
            movePositionedCursor(row: cursor.row + amount, column: cursor.column)
        case 0x43, 0x61:
            guard let amount = movementAmount(sequence.parameters) else { return }
            movePositionedCursor(row: cursor.row, column: cursor.column + amount)
        case 0x44, 0x6A:
            guard let amount = movementAmount(sequence.parameters) else { return }
            movePositionedCursor(row: cursor.row, column: cursor.column - amount)
        case 0x45:
            guard let amount = movementAmount(sequence.parameters) else { return }
            movePositionedCursor(row: cursor.row + amount, column: 0)
        case 0x46:
            guard let amount = movementAmount(sequence.parameters) else { return }
            movePositionedCursor(row: cursor.row - amount, column: 0)
        case 0x47, 0x60:
            guard sequence.parameters.count <= 1 else { return }
            movePositionedCursor(
                row: cursor.row,
                column: absolutePosition(sequence.parameters.first)
            )
        case 0x64:
            guard sequence.parameters.count <= 1 else { return }
            movePositionedCursor(
                row: positioningOriginRow + absolutePosition(sequence.parameters.first),
                column: cursor.column
            )
        case 0x48, 0x66:
            guard sequence.parameters.count <= 2 else { return }
            movePositionedCursor(
                row: positioningOriginRow + absolutePosition(sequence.parameters.first),
                column: absolutePosition(sequence.parameters.dropFirst().first)
            )
        case 0x49:
            guard let amount = movementAmount(sequence.parameters) else { return }
            moveCursorAcrossTabStops(amount: amount, forward: true)
        case 0x5A:
            guard let amount = movementAmount(sequence.parameters) else { return }
            moveCursorAcrossTabStops(amount: amount, forward: false)
        case 0x4A:
            guard sequence.parameters.count <= 1 else { return }
            eraseDisplay(mode: sequence.parameters.first ?? 0)
        case 0x4B:
            guard sequence.parameters.count <= 1 else { return }
            let mode = sequence.parameters.first ?? 0
            guard mode <= 2 else { return }
            eraseLine(mode: mode)
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
            setScrollRegion(sequence.parameters)
        case 0x67:
            clearTabStop(sequence.parameters)
        case 0x73:
            guard sequence.parameters.isEmpty else { return }
            saveCursor()
        case 0x75:
            guard sequence.parameters.isEmpty else { return }
            restoreCursor()
        case 0x62:
            repeatLastPrintedCluster(sequence.parameters)
        case 0x68:
            applyANSIModes(sequence.parameters, enabled: true)
        case 0x6C:
            applyANSIModes(sequence.parameters, enabled: false)
        default:
            break
        }
    }

    private mutating func replyToStatusQuery(
        _ parameters: [UInt16],
        isDECPrivate: Bool
    ) {
        guard parameters.count == 1 else { return }
        switch parameters[0] {
        case 5:
            appendReply(isDECPrivate ? "\u{1B}[?0n" : "\u{1B}[0n")
        case 6:
            let row = isOriginMode ? cursor.row - positioningOriginRow + 1 : cursor.row + 1
            let prefix = isDECPrivate ? "?" : ""
            appendReply("\u{1B}[\(prefix)\(row);\(cursor.column + 1)R")
        default:
            break
        }
    }

    private mutating func replyToModeQuery(
        _ parameters: [UInt16],
        isDECPrivate: Bool
    ) {
        guard parameters.count == 1 else { return }
        let mode = parameters[0]
        let status = isDECPrivate ? decPrivateModeStatus(mode) : ansiModeStatus(mode)
        let prefix = isDECPrivate ? "?" : ""
        appendReply("\u{1B}[\(prefix)\(mode);\(status)$y")
    }

    private func decPrivateModeStatus(_ mode: UInt16) -> Int {
        switch mode {
        case 1:
            isApplicationCursorKeysMode ? 1 : 2
        case 6:
            isOriginMode ? 1 : 2
        case 7:
            isAutoWrapMode ? 1 : 2
        case 25:
            isCursorVisible ? 1 : 2
        case 1004:
            isFocusReportingMode ? 1 : 2
        case 1000:
            mouseTrackingMode == .click ? 1 : 2
        case 1002:
            mouseTrackingMode == .drag ? 1 : 2
        case 1003:
            mouseTrackingMode == .anyMotion ? 1 : 2
        case 1006:
            isSGRMouseEncodingMode ? 1 : 2
        case 1047, 1049:
            isAlternateScreenActive ? 1 : 2
        case 2026:
            isSynchronizedOutputActive ? 1 : 2
        case 2004:
            isBracketedPasteMode ? 1 : 2
        default:
            0
        }
    }

    private func ansiModeStatus(_ mode: UInt16) -> Int {
        switch mode {
        case 4:
            isInsertMode ? 1 : 2
        case 20:
            isLineFeedNewLineMode ? 1 : 2
        default:
            0
        }
    }

    private mutating func appendReply(_ reply: String) {
        let bytes = Array(reply.utf8)
        guard replyBytes.count + bytes.count <= Self.maximumReplyBytes else { return }
        replyBytes.append(contentsOf: bytes)
    }

    private mutating func applyANSIModes(_ parameters: [UInt16], enabled: Bool) {
        var recognized = false
        for parameter in parameters {
            switch parameter {
            case 4:
                isInsertMode = enabled
                recognized = true
            case 20:
                isLineFeedNewLineMode = enabled
                recognized = true
            default:
                continue
            }
        }
        if recognized {
            clearPendingMotionState()
        }
    }

    private mutating func applyDECPrivateModes(_ parameters: [UInt16], enabled: Bool) {
        var shouldClearPendingMotion = false
        for parameter in parameters {
            switch parameter {
            case 1:
                isApplicationCursorKeysMode = enabled
            case 6:
                isOriginMode = enabled
                cursor = CellPosition(row: positioningOriginRow, column: 0)
                shouldClearPendingMotion = true
            case 7:
                isAutoWrapMode = enabled
                shouldClearPendingMotion = true
            case 25:
                isCursorVisible = enabled
            case 1004:
                isFocusReportingMode = enabled
            case 1000:
                mouseTrackingMode = enabled ? .click : .off
            case 1002:
                mouseTrackingMode = enabled ? .drag : .off
            case 1003:
                mouseTrackingMode = enabled ? .anyMotion : .off
            case 1006:
                isSGRMouseEncodingMode = enabled
            case 2004:
                isBracketedPasteMode = enabled
            case 2026:
                isSynchronizedOutputActive = enabled
            case 1048:
                if shouldClearPendingMotion {
                    clearPendingMotionState()
                    shouldClearPendingMotion = false
                }
                if enabled {
                    saveCursor()
                } else {
                    restoreCursor()
                }
            case 1047:
                if shouldClearPendingMotion {
                    clearPendingMotionState()
                    shouldClearPendingMotion = false
                }
                switchAlternateScreen(enabled: enabled)
            case 1049:
                if shouldClearPendingMotion {
                    clearPendingMotionState()
                    shouldClearPendingMotion = false
                }
                if enabled {
                    saveCursor()
                    switchAlternateScreen(enabled: true)
                } else {
                    switchAlternateScreen(enabled: false)
                    restoreCursor()
                }
            default:
                continue
            }
        }
        if shouldClearPendingMotion {
            clearPendingMotionState()
        }
    }

    private mutating func applyCursorStyle(_ parameter: UInt16) {
        switch parameter {
        case 0, 1:
            cursorShape = .block
            isCursorBlinking = true
        case 2:
            cursorShape = .block
            isCursorBlinking = false
        case 3:
            cursorShape = .underline
            isCursorBlinking = true
        case 4:
            cursorShape = .underline
            isCursorBlinking = false
        case 5:
            cursorShape = .bar
            isCursorBlinking = true
        case 6:
            cursorShape = .bar
            isCursorBlinking = false
        default:
            break
        }
    }

    private mutating func applySGR(_ sequence: CSISequence) {
        guard sequence.parameters.isEmpty == false else {
            currentStyle = TerminalStyle()
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
                applyColonSGR(Array(sequence.parameters[index..<groupEnd]))
                index = groupEnd
                continue
            }

            let parameter = sequence.parameters[index]
            if parameter == 38 || parameter == 48 || parameter == 58 {
                let result = semicolonColor(
                    in: sequence.parameters,
                    selectorIndex: index + 1
                )
                if let color = result.color {
                    if parameter == 58 {
                        currentStyle.underlineColor = color
                    } else {
                        set(color: color, foreground: parameter == 38)
                    }
                }
                index = result.nextIndex
            } else {
                applySimpleSGR(parameter)
                index += 1
            }
        }
    }

    private mutating func applyColonSGR(_ group: [UInt16]) {
        guard let leading = group.first else { return }
        switch leading {
        case 4:
            switch group.dropFirst().first {
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
        case 38, 48, 58:
            if let color = colonColor(in: group) {
                if leading == 58 {
                    currentStyle.underlineColor = color
                } else {
                    set(color: color, foreground: leading == 38)
                }
            }
        default:
            applySimpleSGR(leading)
        }
    }

    private mutating func applySimpleSGR(_ parameter: UInt16) {
        switch parameter {
        case 0:
            currentStyle = TerminalStyle()
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

    private func colonColor(in group: [UInt16]) -> TerminalColor? {
        guard group.count >= 3 else { return nil }
        switch group[1] {
        case 5:
            return .indexed(UInt8(truncatingIfNeeded: group[2]))
        case 2:
            if group.count >= 6 {
                return .rgb(
                    red: UInt8(truncatingIfNeeded: group[3]),
                    green: UInt8(truncatingIfNeeded: group[4]),
                    blue: UInt8(truncatingIfNeeded: group[5])
                )
            }
            guard group.count >= 5 else { return nil }
            return .rgb(
                red: UInt8(truncatingIfNeeded: group[2]),
                green: UInt8(truncatingIfNeeded: group[3]),
                blue: UInt8(truncatingIfNeeded: group[4])
            )
        default:
            return nil
        }
    }

    private func semicolonColor(
        in parameters: [UInt16],
        selectorIndex: Int
    ) -> (color: TerminalColor?, nextIndex: Int) {
        guard parameters.indices.contains(selectorIndex) else {
            return (nil, parameters.endIndex)
        }

        switch parameters[selectorIndex] {
        case 5:
            let nextIndex = min(parameters.endIndex, selectorIndex + 2)
            guard parameters.indices.contains(selectorIndex + 1) else {
                return (nil, nextIndex)
            }
            return (
                .indexed(UInt8(truncatingIfNeeded: parameters[selectorIndex + 1])),
                nextIndex
            )
        case 2:
            let nextIndex = min(parameters.endIndex, selectorIndex + 4)
            guard selectorIndex + 3 < parameters.endIndex else {
                return (nil, nextIndex)
            }
            return (
                .rgb(
                    red: UInt8(truncatingIfNeeded: parameters[selectorIndex + 1]),
                    green: UInt8(truncatingIfNeeded: parameters[selectorIndex + 2]),
                    blue: UInt8(truncatingIfNeeded: parameters[selectorIndex + 3])
                ),
                nextIndex
            )
        default:
            return (nil, selectorIndex + 1)
        }
    }

    private mutating func set(color: TerminalColor, foreground: Bool) {
        if foreground {
            currentStyle.foreground = color
        } else {
            currentStyle.background = color
        }
    }

    private mutating func eraseLine(mode: UInt16) {
        switch mode {
        case 0:
            eraseCells(row: cursor.row, columns: cursor.column..<columnCount)
            rows[cursor.row].isSoftWrapped = false
        case 1:
            eraseCells(row: cursor.row, columns: 0..<(cursor.column + 1))
        case 2:
            eraseCells(row: cursor.row, columns: 0..<columnCount)
        default:
            return
        }
        clearPendingMotionState()
    }

    private mutating func eraseDisplay(mode: UInt16) {
        switch mode {
        case 0:
            eraseLine(mode: 0)
            if cursor.row + 1 < rowCount {
                for row in (cursor.row + 1)..<rowCount {
                    eraseEntireRow(row)
                }
            }
        case 1:
            if cursor.row > 0 {
                for row in 0..<cursor.row {
                    eraseEntireRow(row)
                }
            }
            eraseLine(mode: 1)
        case 2:
            for row in rows.indices {
                eraseEntireRow(row)
            }
            clearPendingMotionState()
        case 3:
            let evictedCount = scrollbackRows.count
            scrollbackRows.removeAll(keepingCapacity: true)
            scrollbackByteCount = 0
            scrollbackStoredCellCount = 0
            isHistoryHeadTruncated = false
            if evictedCount > 0 { primaryHistoryObservation.value &+= 1 }
            handleEviction(of: evictedCount)
            clearPendingMotionState()
        default:
            return
        }
    }

    private mutating func eraseCharacters(amount: Int) {
        let upper = min(cursor.column + amount, columnCount)
        eraseCells(row: cursor.row, columns: cursor.column..<upper)
        rows[cursor.row].isSoftWrapped = false
        clearPendingMotionState()
    }

    private mutating func eraseEntireRow(_ row: Int) {
        eraseCells(row: row, columns: 0..<columnCount)
        rows[row].isSoftWrapped = false
        rows[row].semanticPrompt = .none
    }

    private func movementAmount(_ parameters: [UInt16]) -> Int? {
        guard parameters.count <= 1 else { return nil }
        return max(Int(parameters.first ?? 1), 1)
    }

    private func absolutePosition(_ parameter: UInt16?) -> Int {
        max(Int(parameter ?? 1), 1) - 1
    }

    private var positioningRowRange: Range<Int> {
        isOriginMode ? activeScrollRegion : 0..<rowCount
    }

    private var positioningOriginRow: Int {
        positioningRowRange.lowerBound
    }

    private mutating func movePositionedCursor(row: Int, column: Int) {
        let rowRange = positioningRowRange
        cursor.row = min(max(row, rowRange.lowerBound), rowRange.upperBound - 1)
        cursor.column = min(max(column, 0), columnCount - 1)
        clearPendingMotionState()
    }

    private mutating func moveCursorAcrossTabStops(amount: Int, forward: Bool) {
        let candidates = tabStops
            .filter { forward ? $0 > cursor.column : $0 < cursor.column }
            .sorted(by: forward ? (<) : (>))
        let targetIndex = amount - 1
        let column = candidates.indices.contains(targetIndex)
            ? candidates[targetIndex]
            : (forward ? columnCount - 1 : 0)
        movePositionedCursor(row: cursor.row, column: column)
    }

    private mutating func dispatchEscape(_ final: UInt8) {
        switch final {
        case 0x3D:
            isApplicationKeypadMode = true
        case 0x3E:
            isApplicationKeypadMode = false
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
            cursor.column = 0
        case 0x4D:
            clearPendingMotionState()
            reverseIndex()
        case 0x48:
            tabStops.insert(cursor.column)
            clearPendingMotionState()
        case 0x63:
            hardReset()
        default:
            break
        }
    }

    private mutating func dispatchEscape(_ sequence: EscapeSequence) {
        guard sequence.intermediates == [0x23], sequence.final == 0x38 else { return }
        invalidateInspection(inViewportRows: rows.indices)
        let styleId = currentStyleId()
        for row in rows.indices {
            rows[row] = GridRow(cells: (0..<columnCount).map { _ in
                GridCell(scalars: .single("E"), kind: .narrow, styleId: styleId)
            })
        }
        clearPendingMotionState()
    }

    private mutating func execute(_ control: UInt8) {
        switch control {
        case 0x08:
            cursor.column = max(0, cursor.column - 1)
            clearPendingMotionState()
        case 0x09:
            let previousColumn = cursor.column
            cursor.column = tabStops.filter { $0 > cursor.column }.min()
                ?? columnCount - 1
            if cursor.column != previousColumn {
                clusterContext = nil
            }
        case 0x0A, 0x0B, 0x0C:
            clearPendingMotionState()
            lineFeed()
            if isLineFeedNewLineMode {
                cursor.column = 0
            }
        case 0x0D:
            cursor.column = 0
            clearPendingMotionState()
        default:
            break
        }
    }

    private mutating func clearPendingMotionState() {
        isPendingWrap = false
        clusterContext = nil
    }

    private static func defaultTabStops(columns: Int) -> Set<Int> {
        Set(stride(from: 0, to: columns, by: 8))
    }

    private mutating func resizeTabStops(from oldColumnCount: Int, to newColumnCount: Int) {
        tabStops = Set(tabStops.filter { $0 < newColumnCount })
        guard newColumnCount > oldColumnCount else { return }
        for column in oldColumnCount..<newColumnCount where column.isMultiple(of: 8) {
            tabStops.insert(column)
        }
    }

    private mutating func clearTabStop(_ parameters: [UInt16]) {
        guard parameters.count <= 1 else { return }
        switch parameters.first ?? 0 {
        case 0:
            tabStops.remove(cursor.column)
        case 3:
            tabStops.removeAll(keepingCapacity: true)
        default:
            return
        }
        clearPendingMotionState()
    }

    private mutating func saveCursor() {
        savedCursor = SavedCursorState(
            position: cursor,
            style: currentStyle,
            isPendingWrap: isPendingWrap,
            isOriginMode: isOriginMode,
            isCursorVisible: isCursorVisible,
            cursorShape: cursorShape,
            isCursorBlinking: isCursorBlinking
        )
    }

    private mutating func restoreCursor() {
        isOriginMode = savedCursor.isOriginMode
        let rowRange = positioningRowRange
        cursor = CellPosition(
            row: min(max(savedCursor.position.row, rowRange.lowerBound), rowRange.upperBound - 1),
            column: min(max(savedCursor.position.column, 0), columnCount - 1)
        )
        movePositionOffWideTail(&cursor, in: rows)
        currentStyle = savedCursor.style
        isCursorVisible = savedCursor.isCursorVisible
        cursorShape = savedCursor.cursorShape
        isCursorBlinking = savedCursor.isCursorBlinking
        clusterContext = nil
        isPendingWrap = savedCursor.isPendingWrap
            && isAutoWrapMode
            && cursor.column == columnCount - 1
    }

    private mutating func switchAlternateScreen(enabled: Bool) {
        recordFullDamage()
        if enabled {
            clearInspection()
            // The viewport rows keep their numbers and get a different grid underneath them,
            // in both directions -- including a redundant enable, which blanks them again.
            renumberRows()
            if isAlternateScreenActive == false {
                inactivePrimaryScreen = InactivePrimaryScreen(
                    rows: rows,
                    resizeCursor: cursor,
                    isResizePendingWrap: isPendingWrap,
                    semanticContent: semanticContent,
                    semanticContentClearsAtEndOfLine: semanticContentClearsAtEndOfLine
                )
            }
            rows = (0..<rowCount).map { _ in
                makeBlankRow(columns: columnCount, styleId: backgroundEraseStyleId())
            }
            semanticContent = .output
            semanticContentClearsAtEndOfLine = false
        } else if let primary = inactivePrimaryScreen {
            clearInspection()
            renumberRows()
            rows = primary.rows
            semanticContent = primary.semanticContent
            semanticContentClearsAtEndOfLine = primary.semanticContentClearsAtEndOfLine
            inactivePrimaryScreen = nil
        }
        clearPendingMotionState()
    }

    private mutating func selectPrimaryScreen() {
        guard let primary = inactivePrimaryScreen else { return }
        recordFullDamage()
        clearInspection()
        // Guarded above, so a reset that finds the primary screen already active renumbers
        // nothing -- which is why a soft reset stops a drag only when taken from the
        // alternate screen.
        renumberRows()
        rows = primary.rows
        semanticContent = primary.semanticContent
        semanticContentClearsAtEndOfLine = primary.semanticContentClearsAtEndOfLine
        inactivePrimaryScreen = nil
    }

    private mutating func clampCursorStateToActiveGrid() {
        clampPosition(&cursor, in: rows)
        clampPosition(&savedCursor.position, in: rows)
        isPendingWrap = isPendingWrap
            && isAutoWrapMode
            && cursor.column == columnCount - 1
    }

    private func clampPosition(_ position: inout CellPosition, in grid: [GridRow]) {
        position.row = min(max(position.row, 0), rowCount - 1)
        position.column = min(max(position.column, 0), columnCount - 1)
        movePositionOffWideTail(&position, in: grid)
    }

    private func movePositionOffWideTail(_ position: inout CellPosition, in grid: [GridRow]) {
        guard grid.indices.contains(position.row),
              grid[position.row].cells.indices.contains(position.column),
              grid[position.row].cells[position.column].kind == .wideTail
        else { return }
        position.column = max(0, position.column - 1)
    }

    private mutating func repeatLastPrintedCluster(_ parameters: [UInt16]) {
        guard parameters.count <= 1,
              let cluster = lastPrintedCluster,
              isPendingWrap == false
        else { return }

        let requestedCount = max(Int(parameters.first ?? 1), 1)
        let availableColumns = columnCount - cursor.column
        let repeatCount = min(requestedCount, availableColumns / cluster.cellWidth)
        guard repeatCount > 0 else { return }

        for _ in 0..<repeatCount {
            clusterContext = nil
            for scalar in cluster.scalars {
                print(scalar)
            }
        }
    }

    private mutating func softReset() {
        recordFullDamage()
        selectPrimaryScreen()
        resetControlState()
        hyperlinkPen = nil
        hoveredLinkState = nil
        armedLinkState = nil
        clearPendingMotionState()
    }

    private mutating func hardReset() {
        recordFullDamage()
        clearInspection()
        // Restarting the count is what a pinned range cannot survive: without this, a stale
        // anchor resolves against rows that are numbered from zero again.
        renumberRows()
        evictedRowCount = 0
        selectPrimaryScreen()
        resetControlState()
        hyperlinkPen = nil
        hyperlinkTargets.removeAll(keepingCapacity: true)
        nextHyperlinkId = 1
        nextContentIdentity = 1
        cursor = CellPosition(row: 0, column: 0)
        clearPendingMotionState()
        lastPrintedCluster = nil
        semanticContent = .output
        semanticContentClearsAtEndOfLine = false
        promptRedrawMode = .full

        let styleId = backgroundEraseStyleId()
        severWrapClaim(before: 0, replacementStyleId: styleId)
        for row in rows.indices {
            eraseEntireRow(row)
        }
    }

    private mutating func resetControlState() {
        scrollRegion = nil
        isInsertMode = false
        isLineFeedNewLineMode = false
        isApplicationCursorKeysMode = false
        isApplicationKeypadMode = false
        isFocusReportingMode = false
        isBracketedPasteMode = false
        mouseTrackingMode = .off
        isSGRMouseEncodingMode = false
        isOriginMode = false
        isAutoWrapMode = true
        isCursorVisible = true
        cursorShape = .block
        isCursorBlinking = false
        isSynchronizedOutputActive = false
        primaryKittyKeyboardStack.removeAll(keepingCapacity: true)
        alternateKittyKeyboardStack.removeAll(keepingCapacity: true)
        tabStops = Self.defaultTabStops(columns: columnCount)
        currentStyle = TerminalStyle()
    }

    private var activeKittyKeyboardStack: [UInt16] {
        get {
            isAlternateScreenActive ? alternateKittyKeyboardStack : primaryKittyKeyboardStack
        }
        set {
            if isAlternateScreenActive {
                alternateKittyKeyboardStack = newValue
            } else {
                primaryKittyKeyboardStack = newValue
            }
        }
    }

    private mutating func pushKittyKeyboardFlags(_ flags: UInt16) {
        var stack = activeKittyKeyboardStack
        if stack.count == Self.kittyKeyboardStackDepth {
            stack.removeFirst()
        }
        stack.append(flags & 1)
        activeKittyKeyboardStack = stack
    }

    private mutating func popKittyKeyboardFlags(_ count: UInt16) {
        var stack = activeKittyKeyboardStack
        stack.removeLast(min(Int(count), stack.count))
        activeKittyKeyboardStack = stack
    }

    private mutating func setKittyKeyboardFlags(_ flags: UInt16, mode: UInt16) {
        var stack = activeKittyKeyboardStack
        let previous = stack.last ?? 0
        let masked = flags & 1
        let updated: UInt16
        switch mode {
        case 1: updated = masked
        case 2: updated = previous | masked
        case 3: updated = previous & ~masked
        default: return
        }
        if stack.isEmpty {
            stack.append(updated)
        } else {
            stack[stack.count - 1] = updated
        }
        activeKittyKeyboardStack = stack
    }

    private mutating func print(_ scalar: Unicode.Scalar) {
        let classification = terminalUnicodeClassification(for: scalar)
        if appendToOpenClusterIfJoined(scalar, classification: classification) {
            rememberOpenCluster()
            return
        }

        let properties = classification.properties
        guard properties.cellWidth != .zero else { return }

        if isPendingWrap {
            invalidateInspection(inViewportRows: cursor.row..<(cursor.row + 1))
            softWrap()
        }

        switch properties.cellWidth {
        case .zero:
            break
        case .narrow:
            printNarrow(scalar, breakClass: classification.graphemeBreakClass)
        case .wide:
            printWide(scalar, breakClass: classification.graphemeBreakClass)
        }
        rememberOpenCluster()
    }

    private mutating func rememberOpenCluster() {
        guard let context = clusterContext else { return }
        let cell = rows[context.target.row].cells[context.target.column]
        lastPrintedCluster = LastPrintedCluster(
            scalars: cell.scalars,
            cellWidth: cell.kind == .wideHead ? 2 : 1
        )
    }

    private mutating func appendToOpenClusterIfJoined(
        _ scalar: Unicode.Scalar,
        classification: TerminalUnicodeClassification
    ) -> Bool {
        guard var context = clusterContext else { return false }
        var target = context.target
        guard rows.indices.contains(target.row), rows[target.row].cells.indices.contains(target.column) else {
            clusterContext = nil
            return false
        }
        guard rows[target.row].cells[target.column].kind == .narrow
            || rows[target.row].cells[target.column].kind == .wideHead
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
            return false
        }

        guard let baseScalar = rows[target.row].cells[target.column].scalars.first else {
            clusterContext = nil
            return false
        }
        invalidateInspection(inViewportRows: target.row..<(target.row + 1))
        switch desiredClusterWidth(
            for: scalar,
            classification: classification,
            baseScalar: baseScalar
        ) {
        case .wide where rows[target.row].cells[target.column].kind == .narrow:
            target = upgradeClusterToWide(at: target)
        case .narrow where rows[target.row].cells[target.column].kind == .wideHead:
            downgradeClusterToNarrow(at: target)
        case .zero, .narrow, .wide, nil:
            break
        }

        rows[target.row].cells[target.column].scalars.append(scalar)
        context.target = target
        context.previousClass = classification.graphemeBreakClass
        context.breakState = nextBreakState
        clusterContext = context
        return true
    }

    private func desiredClusterWidth(
        for scalar: Unicode.Scalar,
        classification: TerminalUnicodeClassification,
        baseScalar: Unicode.Scalar
    ) -> TerminalCellWidth? {
        if scalar.value == 0xFE0F || scalar.value == 0xFE0E {
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
        let scalars = rows[target.row].cells[target.column].scalars
        let styleId = rows[target.row].cells[target.column].styleId
        let hyperlinkId = rows[target.row].cells[target.column].hyperlinkId
        let contentIdentity = rows[target.row].cells[target.column].contentIdentity
        var destination = target

        if target.column == columnCount - 1 {
            if isAutoWrapMode {
                clearCellAndPair(row: target.row, column: target.column)
                rows[target.row].cells[target.column] = GridCell(
                    kind: .spacerHead,
                    styleId: styleId,
                    hyperlinkId: hyperlinkId,
                    contentIdentity: contentIdentity
                )
                rows[target.row].isSoftWrapped = true
                cursor = target
                advanceToNextRow(preservingWrapClaim: true)
                cursor.column = 0
                destination = cursor
                invalidateInspection(inViewportRows: destination.row..<(destination.row + 1))
                clearCellAndPair(row: destination.row, column: 0, clearsPreviousSpacer: false)
                clearCellAndPair(row: destination.row, column: 1, clearsPreviousSpacer: false)
            } else {
                destination.column = columnCount - 2
                clearCellAndPair(row: target.row, column: target.column)
                clearCellAndPair(row: destination.row, column: destination.column)
                clearCellAndPair(row: destination.row, column: destination.column + 1)
            }
        } else {
            clearCellAndPair(row: target.row, column: target.column + 1)
        }

        rows[destination.row].cells[destination.column] = GridCell(
            scalars: scalars,
            kind: .wideHead,
            styleId: styleId,
            hyperlinkId: hyperlinkId,
            contentIdentity: contentIdentity
        )
        rows[destination.row].cells[destination.column + 1] = GridCell(
            kind: .wideTail,
            styleId: styleId,
            hyperlinkId: hyperlinkId,
            contentIdentity: contentIdentity
        )
        advanceCursorPastWideCell(at: destination)
        return destination
    }

    private mutating func downgradeClusterToNarrow(at target: CellPosition) {
        rows[target.row].cells[target.column].kind = .narrow
        rows[target.row].cells[target.column + 1] = GridCell()

        if target.column == 0 {
            clearPreviousSpacer(beforeRow: target.row, column: target.column)
        }

        if cursor.column == columnCount - 1 {
            isPendingWrap = false
        } else {
            cursor.column -= 1
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
        invalidateInspection(inViewportRows: cursor.row..<(cursor.row + 1))
        if isInsertMode {
            moveAndFillCells(
                in: cursor.column..<columnCount,
                row: cursor.row,
                by: 1
            )
        }
        clearCellAndPair(row: cursor.row, column: cursor.column)
        let styleId = currentStyleId()
        rows[cursor.row].cells[cursor.column] = GridCell(
            scalars: .single(scalar),
            kind: .narrow,
            styleId: styleId,
            hyperlinkId: hyperlinkPen,
            contentIdentity: contentIdentity
        )
        clusterContext = ClusterContext(target: cursor, previousClass: breakClass)

        if cursor.column == columnCount - 1 {
            isPendingWrap = isAutoWrapMode
        } else {
            cursor.column += 1
        }
    }

    private mutating func printWide(
        _ scalar: Unicode.Scalar,
        breakClass: GraphemeBreakClass
    ) {
        let contentIdentity = allocateContentIdentity()
        invalidateInspection(inViewportRows: cursor.row..<(cursor.row + 1))
        var preservesWrappedSpacer = false
        if cursor.column == columnCount - 1 {
            if isAutoWrapMode {
                clearCellAndPair(row: cursor.row, column: cursor.column)
                rows[cursor.row].cells[cursor.column] = GridCell(
                    kind: .spacerHead,
                    styleId: currentStyleId(),
                    hyperlinkId: hyperlinkPen,
                    contentIdentity: contentIdentity
                )
                rows[cursor.row].isSoftWrapped = true
                advanceToNextRow(preservingWrapClaim: true)
                cursor.column = 0
                preservesWrappedSpacer = true
            } else {
                cursor.column = columnCount - 2
            }
        }

        invalidateInspection(inViewportRows: cursor.row..<(cursor.row + 1))

        if isInsertMode {
            moveAndFillCells(
                in: cursor.column..<columnCount,
                row: cursor.row,
                by: 2
            )
        }

        clearCellAndPair(
            row: cursor.row,
            column: cursor.column,
            clearsPreviousSpacer: preservesWrappedSpacer == false
        )
        clearCellAndPair(
            row: cursor.row,
            column: cursor.column + 1,
            clearsPreviousSpacer: preservesWrappedSpacer == false
        )
        let styleId = currentStyleId()
        rows[cursor.row].cells[cursor.column] = GridCell(
            scalars: .single(scalar),
            kind: .wideHead,
            styleId: styleId,
            hyperlinkId: hyperlinkPen,
            contentIdentity: contentIdentity
        )
        rows[cursor.row].cells[cursor.column + 1] = GridCell(
            kind: .wideTail,
            styleId: styleId,
            hyperlinkId: hyperlinkPen,
            contentIdentity: contentIdentity
        )
        clusterContext = ClusterContext(target: cursor, previousClass: breakClass)
        advanceCursorPastWideCell(at: cursor)
    }

    private mutating func advanceCursorPastWideCell(at head: CellPosition) {
        if isAutoWrapMode == false, head.column + 1 == columnCount - 1 {
            cursor = head
            isPendingWrap = false
            return
        }
        cursor = CellPosition(row: head.row, column: head.column + 1)
        if cursor.column == columnCount - 1 {
            isPendingWrap = true
        } else {
            cursor.column += 1
            isPendingWrap = false
        }
    }

    private mutating func softWrap() {
        rows[cursor.row].isSoftWrapped = true
        advanceToNextRow(preservingWrapClaim: true)
        cursor.column = 0
        stampSemanticContinuationAfterLineAdvance()
        isPendingWrap = false
        clusterContext = nil
    }

    private mutating func lineFeed() {
        advanceToNextRow()
        stampSemanticContinuationAfterLineAdvance()
    }

    private mutating func stampSemanticContinuationAfterLineAdvance() {
        if semanticContentClearsAtEndOfLine {
            semanticContent = .output
            semanticContentClearsAtEndOfLine = false
        } else if semanticContent == .prompt || semanticContent == .input {
            rows[cursor.row].semanticPrompt = .continuation
        }
    }

    private mutating func advanceToNextRow(preservingWrapClaim: Bool = false) {
        let region = activeScrollRegion
        if cursor.row == region.upperBound - 1 {
            recordDamage(rows: region)
            moveAndFillRows(
                in: region,
                by: -1,
                pushesToScrollback: retainsRowsScrolledOffTop,
                preservesTrailingWrap: preservingWrapClaim,
                invalidatesInspection: false
            )
        } else if cursor.row < rowCount - 1 {
            cursor.row += 1
        }
        if preservingWrapClaim {
            restoreWrapClaimBeforeCursor()
        }
    }

    private var activeScrollRegion: Range<Int> {
        scrollRegion ?? 0..<rowCount
    }

    // xterm/kitty/Ghostty retain a row scrolled off the top whenever the region is
    // anchored at row 0 and spans the full width, even with a bottom margin set
    // (.ghostty-src/src/terminal/Terminal.zig:1466). Inline-viewport TUIs (codex's
    // ratatui composer) depend on it: they pin a footer with `CSI 1;N r` and scroll
    // their transcript out the top expecting it to land in scrollback. We implement
    // no DECSLRM left/right margins, so full width is trivially true. Applies only
    // to the two upward-scroll paths; mid-screen shuffles still discard.
    private var retainsRowsScrolledOffTop: Bool {
        activeScrollRegion.lowerBound == 0 && isAlternateScreenActive == false
    }

    private mutating func setScrollRegion(_ parameters: [UInt16]) {
        guard parameters.count <= 2 else { return }

        let top = max(Int(parameters.first ?? 1), 1)
        let bottomParameter = parameters.dropFirst().first ?? 0
        let bottom = bottomParameter == 0
            ? rowCount
            : min(Int(bottomParameter), rowCount)
        if bottom <= top {
            scrollRegion = nil
        } else {
            let candidate = (top - 1)..<bottom
            scrollRegion = candidate == 0..<rowCount ? nil : candidate
        }
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
        guard activeScrollRegion.contains(cursor.row) else { return }
        moveAndFillCells(
            in: cursor.column..<columnCount,
            row: cursor.row,
            by: amount
        )
    }

    private mutating func deleteCharacters(amount: Int) {
        clearPendingMotionState()
        guard activeScrollRegion.contains(cursor.row) else { return }
        moveAndFillCells(
            in: cursor.column..<columnCount,
            row: cursor.row,
            by: -amount
        )
    }

    private mutating func insertLines(amount: Int) {
        clearPendingMotionState()
        let region = activeScrollRegion
        guard region.contains(cursor.row) else { return }
        moveAndFillRows(
            in: cursor.row..<region.upperBound,
            by: amount,
            pushesToScrollback: false
        )
    }

    private mutating func deleteLines(amount: Int) {
        clearPendingMotionState()
        let region = activeScrollRegion
        guard region.contains(cursor.row) else { return }
        moveAndFillRows(
            in: cursor.row..<region.upperBound,
            by: -amount,
            pushesToScrollback: false
        )
    }

    private mutating func reverseIndex() {
        let region = activeScrollRegion
        if cursor.row == region.lowerBound {
            moveAndFillRows(in: region, by: 1, pushesToScrollback: false)
        } else {
            cursor.row = max(0, cursor.row - 1)
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

    private mutating func moveAndFillRows(
        in range: Range<Int>,
        by delta: Int,
        pushesToScrollback: Bool,
        preservesTrailingWrap: Bool = false,
        invalidatesInspection: Bool = true
    ) {
        guard range.isEmpty == false, delta != 0 else { return }
        if invalidatesInspection {
            invalidateInspection(inViewportRows: range)
        }
        let amount = min(abs(delta), range.count)
        let styleId = backgroundEraseStyleId()

        if delta < 0, pushesToScrollback {
            // Only the evicted prefix has to outlive the move, so this copies `amount` rows
            // rather than the whole region. It must be materialized rather than passed as a
            // slice of `rows`: `appendToScrollback` is mutating, and handing it a slice of
            // `self.rows` would be an overlapping access to `self`.
            appendToScrollback(Array(rows[range.lowerBound..<(range.lowerBound + amount)]))
        } else {
            severWrapClaim(before: range.lowerBound, replacementStyleId: styleId)
        }

        Self.moveInPlace(range, by: delta, amount: amount) { destination, source in
            if let source {
                let moved = rows[source]
                rows[destination] = moved
            } else {
                rows[destination] = makeBlankRow(columns: columnCount, styleId: styleId)
            }
        }

        let survivingCount = range.count - amount
        if survivingCount > 0, preservesTrailingWrap == false {
            let lastSurvivor = delta < 0
                ? range.lowerBound + survivingCount - 1
                : range.upperBound - 1
            severWrapClaim(at: lastSurvivor, replacementStyleId: styleId)
        }
        if delta < 0, pushesToScrollback {
            enforceScrollbackBudget()
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
        invalidateInspection(inViewportRows: row..<(row + 1))
        let amount = min(abs(delta), range.count)
        let styleId = backgroundEraseStyleId()

        Self.moveInPlace(range, by: delta, amount: amount) { destination, source in
            if let source {
                let moved = rows[row].cells[source]
                rows[row].cells[destination] = moved
            } else {
                rows[row].cells[destination] = GridCell(styleId: styleId)
            }
        }

        severWrapClaim(at: row, replacementStyleId: styleId)
        clearPreviousSpacer(
            beforeRow: row,
            column: range.lowerBound,
            replacementStyleId: styleId
        )
        repairHorizontalMove(in: row, replacementStyleId: styleId)
    }

    private mutating func repairHorizontalMove(
        in row: Int,
        replacementStyleId: StyleId
    ) {
        let cells = rows[row].cells
        var invalidColumns: [Int] = []
        for column in cells.indices {
            switch cells[column].kind {
            case .wideHead:
                if column + 1 >= columnCount || cells[column + 1].kind != .wideTail {
                    invalidColumns.append(column)
                }
            case .wideTail:
                if column == 0 || cells[column - 1].kind != .wideHead {
                    invalidColumns.append(column)
                }
            case .spacerHead:
                invalidColumns.append(column)
            case .padding, .narrow:
                break
            }
        }

        for column in invalidColumns {
            rows[row].cells[column] = GridCell(styleId: replacementStyleId)
        }
    }

    private mutating func severWrapClaim(
        before row: Int,
        replacementStyleId: StyleId
    ) {
        if row > 0 {
            severWrapClaim(at: row - 1, replacementStyleId: replacementStyleId)
        } else if isAlternateScreenActive == false, let last = scrollbackRows.indices.last {
            severScrollbackWrapClaim(at: last, replacementStyleId: replacementStyleId)
        }
    }

    private mutating func severWrapClaim(
        at row: Int,
        replacementStyleId: StyleId
    ) {
        guard rows.indices.contains(row) else { return }
        guard rows[row].isSoftWrapped
            || rows[row].cells[columnCount - 1].kind == .spacerHead
        else { return }
        invalidateInspection(inViewportRows: row..<(row + 1))
        rows[row].isSoftWrapped = false
        if rows[row].cells[columnCount - 1].kind == .spacerHead {
            rows[row].cells[columnCount - 1] = GridCell(styleId: replacementStyleId)
        }
    }

    private mutating func severScrollbackWrapClaim(
        at row: Int,
        replacementStyleId: StyleId
    ) {
        guard scrollbackRows[row].isSoftWrapped
            || scrollbackRows[row].cell(at: columnCount - 1).kind == .spacerHead
        else { return }
        invalidateInspection(inScrollbackRow: row)
        scrollbackRows[row].isSoftWrapped = false
        if scrollbackRows[row].cell(at: columnCount - 1).kind == .spacerHead {
            setScrollbackCell(
                GridCell(styleId: replacementStyleId),
                row: row,
                column: columnCount - 1
            )
        }
    }

    private mutating func restoreWrapClaimBeforeCursor() {
        if cursor.row > 0 {
            guard rows[cursor.row - 1].isSoftWrapped == false else { return }
            invalidateInspection(inViewportRows: (cursor.row - 1)..<cursor.row)
            rows[cursor.row - 1].isSoftWrapped = true
        } else if isAlternateScreenActive == false, let last = scrollbackRows.indices.last {
            guard scrollbackRows[last].isSoftWrapped == false else { return }
            invalidateInspection(inScrollbackRow: last)
            scrollbackRows[last].isSoftWrapped = true
        }
    }

    private func rowContainsContent(_ row: GridRow) -> Bool {
        row.cells.contains { cell in
            cell.kind == .narrow || cell.kind == .wideHead
        }
    }

    private mutating func clearCellAndPair(
        row: Int,
        column: Int,
        clearsPreviousSpacer: Bool = true,
        replacementStyleId: StyleId = Terminal.defaultStyleId
    ) {
        guard rows.indices.contains(row), rows[row].cells.indices.contains(column) else { return }
        switch rows[row].cells[column].kind {
        case .wideHead:
            rows[row].cells[column] = GridCell(styleId: replacementStyleId)
            if column + 1 < columnCount {
                rows[row].cells[column + 1] = GridCell(styleId: replacementStyleId)
            }
        case .wideTail:
            rows[row].cells[column] = GridCell(styleId: replacementStyleId)
            if column > 0 {
                rows[row].cells[column - 1] = GridCell(styleId: replacementStyleId)
            }
        case .padding, .narrow, .spacerHead:
            rows[row].cells[column] = GridCell(styleId: replacementStyleId)
        }

        if clearsPreviousSpacer {
            clearPreviousSpacer(
                beforeRow: row,
                column: column,
                replacementStyleId: replacementStyleId
            )
        }
    }

    private mutating func clearPreviousSpacer(
        beforeRow row: Int,
        column: Int,
        replacementStyleId: StyleId = Terminal.defaultStyleId
    ) {
        guard column <= 1 else { return }
        if row > 0, rows[row - 1].cells[columnCount - 1].kind == .spacerHead {
            invalidateInspection(inViewportRows: (row - 1)..<row)
            rows[row - 1].cells[columnCount - 1] = GridCell(styleId: replacementStyleId)
        } else if row == 0,
                  isAlternateScreenActive == false,
                  let last = scrollbackRows.indices.last,
                  scrollbackRows[last].cell(at: columnCount - 1).kind == .spacerHead
        {
            invalidateInspection(inScrollbackRow: last)
            setScrollbackCell(
                GridCell(styleId: replacementStyleId),
                row: last,
                column: columnCount - 1
            )
        }
    }

    /// Mutates logical history while keeping its cached byte charge exact.
    private mutating func setScrollbackCell(_ cell: GridCell, row: Int, column: Int) {
        let oldCost = Self.scrollbackByteCost(of: scrollbackRows[row])
        let oldCells = scrollbackRows[row].storedCellCount
        var retained = scrollbackRows[row].unpacked()
        retained.setCell(cell, at: column, columns: columnCount)
        let packed = PackedRetainedRow.pack(retained)
        scrollbackRows[row] = packed
        scrollbackByteCount += Self.scrollbackByteCost(of: packed) - oldCost
        scrollbackStoredCellCount += packed.storedCellCount - oldCells
    }
}
