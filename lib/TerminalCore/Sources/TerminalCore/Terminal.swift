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

    /// Keeps scalar storage and wide-cell roles together for invariant-preserving mutation.
    private struct GridCell: Equatable, Sendable {
        var kind: TerminalCellKind = .padding
        var scalars = TerminalScalars.empty
        var style = TerminalStyle()
        var hyperlinkId: Int?
        var contentIdentity: Int?
    }

    /// Moves row-level wrap and semantic-prompt identity with cells during scrolling.
    private struct GridRow: Equatable, Sendable {
        var cells: [GridCell]
        var isSoftWrapped = false
        var semanticPrompt = SemanticPromptRow.none
    }

    /// Marks only the rows needed to find and preserve a shell-redraw prompt block.
    private enum SemanticPromptRow: Equatable, Sendable {
        case none
        case prompt
        case continuation
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
    private struct DamageActionSnapshot {
        var cursor: TerminalCursor?
        var selection: TerminalTextRange?
        var searchMatch: TerminalTextRange?
        var hoveredLink: TerminalResolvedLink?
        var topRow: Int
        var isFollowing: Bool
        var isAlternateScreenActive: Bool
        var cursorPresentation: TerminalPresentation
    }

    /// Gives retained rows logical zero-based indices while front eviction stays amortized O(1).
    private struct ScrollbackBuffer: Equatable, Sendable {
        private var storage: [GridRow] = []
        private var storageStart = 0

        var count: Int { storage.count - storageStart }
        var isEmpty: Bool { count == 0 }
        var indices: Range<Int> { 0..<count }

        init() {}

        init<S: Sequence>(_ rows: S) where S.Element == GridRow {
            storage = Array(rows)
        }

        subscript(position: Int) -> GridRow {
            get {
                precondition(indices.contains(position))
                return storage[storageStart + position]
            }
            set {
                precondition(indices.contains(position))
                storage[storageStart + position] = newValue
            }
        }

        mutating func append(_ row: GridRow) {
            storage.append(row)
        }

        func asArray() -> [GridRow] {
            Array(storage[storageStart...])
        }

        func suffix(from index: Int) -> [GridRow] {
            precondition(indices.contains(index) || index == count)
            return Array(storage[(storageStart + index)...])
        }

        mutating func removeFirst() -> GridRow {
            precondition(isEmpty == false)
            let row = storage[storageStart]
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

    /// Tracks cursor coordinates without exposing storage indices.
    private struct CellPosition: Equatable, Sendable {
        var row: Int
        var column: Int
    }

    /// Keeps inspection state stable while rows migrate between viewport and scrollback.
    private struct TextAnchor: Equatable, Comparable, Sendable {
        var row: Int
        var column: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.row < rhs.row || (lhs.row == rhs.row && lhs.column < rhs.column)
        }
    }

    /// Represents a half-open selection or match in absolute retained-row coordinates.
    private struct TextAnchorRange: Equatable, Sendable {
        var start: TextAnchor
        var end: TextAnchor
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
    private var primaryKittyKeyboardStack: [UInt16] = []
    private var alternateKittyKeyboardStack: [UInt16] = []
    private var evictedRowCount = 0
    // The four inspection fields below are read together, per printed character, by
    // `invalidateInspection`, whose guard rejects whenever all four are nil -- the state of
    // every run with no selection, search, hover, or armed link. Each observer keeps
    // `hasInteractionState` exact so that guard is one Bool load instead of four optional
    // loads. Maintaining it here rather than at the call sites is what makes it undriftable:
    // `didSet` fires for in-place mutation (`selection.start.column = ...`) as well as for
    // whole-value assignment, so no future write can bypass it.
    private var selection: TextAnchorRange? { didSet { refreshHasInteractionState() } }
    private var search: SearchState? { didSet { refreshHasInteractionState() } }
    private var hoveredLinkState: InteractionLinkState? { didSet { refreshHasInteractionState() } }
    private var armedLinkState: InteractionLinkState? { didSet { refreshHasInteractionState() } }

    /// Caches `selection`/`search`/`hoveredLinkState`/`armedLinkState` being non-nil.
    ///
    /// Derived state, never assigned directly: the four observers above are its only writer.
    /// `false` is correct at initialization because all four fields start nil and property
    /// observers do not fire during initialization.
    private var hasInteractionState = false
    private var viewportState = ViewportState.following
    private var damage: TerminalDamageAccumulator
    private var hyperlinkTargets: [Int: TerminalHyperlink] = [:]
    private var hyperlinkPen: Int?
    private var nextHyperlinkId = 1
    private var nextContentIdentity = 1
    private var machineHostname: String?
    private var currentWorkingDirectory: String?
    private var titleUsesWorkingDirectory = false
    private var pendingConsumerWork = PendingConsumerWork()
    private var nextSemanticEventOrder: UInt64 = 0
    private var primaryHistoryObservation = ObservationGeneration()

    static let productionScrollbackBudgetBytes = 10_485_760
    static let kittyKeyboardStackDepth = 8
    static let maximumHyperlinkTargetBytes = 65_536
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

    /// Makes the active bound visible to shared structural test assertions.
    private(set) var scrollbackBudgetBytes: Int

    /// Caches retained-row cost so the line-feed path never scans full history.
    private(set) var scrollbackByteCount = 0

    /// Records whether eviction severed the retained stream inside a logical line.
    public private(set) var isHistoryHeadTruncated = false

    /// Exposes the semantic SGR pen without allowing callers to mutate terminal state.
    public private(set) var currentStyle = TerminalStyle()

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
            hoveredLink: hoveredLink,
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
        if before.hoveredLink != after.hoveredLink {
            recordPresentationDamage(rows: damagedViewportRows(for: before.hoveredLink?.range))
            recordPresentationDamage(rows: damagedViewportRows(for: after.hoveredLink?.range))
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

    /// Rejects dimensions that cannot represent all supported terminal cells.
    public init?(
        columns: Int,
        rows: Int,
        machineHostname: String? = nil,
        programVersion: String = "dev"
    ) {
        self.init(
            columns: columns,
            rows: rows,
            scrollbackBudgetBytes: Self.productionScrollbackBudgetBytes,
            machineHostname: machineHostname,
            programVersion: programVersion
        )
    }

    /// Gives deterministic tests a small budget while production remains fixed at 10 MiB.
    init?(
        columns: Int,
        rows: Int,
        scrollbackBudgetBytes: Int,
        machineHostname: String? = nil,
        programVersion: String = "dev"
    ) {
        guard columns >= 2, rows >= 1, scrollbackBudgetBytes >= 0 else { return nil }
        columnCount = columns
        rowCount = rows
        self.scrollbackBudgetBytes = scrollbackBudgetBytes
        self.machineHostname = machineHostname
        self.programVersion = programVersion
        tabStops = Self.defaultTabStops(columns: columns)
        damage = TerminalDamageAccumulator(rowCount: rows, isFull: true)
        self.rows = (0..<rows).map { _ in
            GridRow(cells: (0..<columns).map { _ in GridCell() })
        }
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
            if cursor.column == 0, rows[cursor.row].semanticPrompt != .none {
                rows[cursor.row].semanticPrompt = .none
            }
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

        let id = nextHyperlinkId
        candidateTargets[id] = target
        hyperlinkTargets = candidateTargets
        hyperlinkPen = id
        nextHyperlinkId += 1
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

    private func liveHyperlinkIds() -> Set<Int> {
        var live = Set<Int>()
        func collect(_ rows: [GridRow], into live: inout Set<Int>) {
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
            case .prompt:
                for row in start..<rowCount { clearPromptCells(in: row) }
                return
            case .continuation, .none:
                start -= 1
            }
        }
    }

    private mutating func clearPromptCells(in row: Int) {
        invalidateInspection(inViewportRows: row..<(row + 1))
        let style = backgroundEraseStyle
        for column in 0..<columnCount {
            rows[row].cells[column] = GridCell(style: style)
        }
        clusterContext = nil
    }

    /// Renders the selected local window as unstyled text, representing padding as spaces.
    public var screenText: String {
        presentedRows.map { row in
            var result = ""
            for cell in row.cells {
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
        let row = scrollbackRows[index]
        return TerminalScrollbackRow(
            cells: row.cells.map {
                TerminalCell(
                    kind: $0.kind,
                    scalars: $0.scalars,
                    style: $0.style,
                    hyperlink: $0.hyperlinkId.flatMap { hyperlinkTargets[$0] }
                )
            },
            isSoftWrapped: row.isSoftWrapped
        )
    }

    /// Recomputes retained-row cost for coherence proofs without affecting enforcement.
    var recomputedScrollbackByteCount: Int {
        scrollbackRows.indices.reduce(0) {
            $0 + Self.scrollbackByteCost(of: scrollbackRows[$1])
        }
    }

    /// Exposes one canonical row cost so tests can pin the representation-neutral literals.
    func scrollbackRowByteCost(at index: Int) -> Int? {
        guard scrollbackRows.indices.contains(index) else { return nil }
        return Self.scrollbackByteCost(of: scrollbackRows[index])
    }

    /// Creates the one-operation no-eviction oracle used to isolate eviction side effects.
    func withUnlimitedScrollbackForTesting() -> Self {
        var copy = self
        copy.scrollbackBudgetBytes = .max
        return copy
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
        let matches = searchMatches(for: search.query)
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

    /// Returns the maximal same-class word unit used by native double-click selection.
    public func wordRange(at position: TerminalTextPosition) -> TerminalTextRange {
        let units = projectionUnits()
        guard let target = nearestTextUnitIndex(to: position, in: units) else {
            return emptyRange(at: position)
        }
        let targetClass = wordClass(of: units[target])
        var lower = target
        var upper = target
        while lower > units.startIndex {
            let candidate = units.index(before: lower)
            guard units[candidate].isHardBoundary == false,
                  wordClass(of: units[candidate]) == targetClass
            else { break }
            lower = candidate
        }
        while upper < units.index(before: units.endIndex) {
            let candidate = units.index(after: upper)
            guard units[candidate].isHardBoundary == false,
                  wordClass(of: units[candidate]) == targetClass
            else { break }
            upper = candidate
        }
        return publicRange(TextAnchorRange(
            start: units[lower].start,
            end: units[upper].end
        )) ?? emptyRange(at: position)
    }

    /// Returns the maximal whitespace-delimited run used by native triple-click selection.
    ///
    /// Sits between word and line granularity so a path, URL, hash, or flag is one gesture:
    /// the split is purely whitespace-vs-not over the same projection `wordRange` walks, with
    /// no path or URL recognition and no trailing-punctuation trimming. Like `wordRange` it
    /// stops at a hard line ending, so a cluster spans a soft wrap but never absorbs the next
    /// command's first token.
    public func clusterRange(at position: TerminalTextPosition) -> TerminalTextRange {
        let units = projectionUnits()
        guard let target = nearestTextUnitIndex(to: position, in: units) else {
            return emptyRange(at: position)
        }
        let targetIsWhitespace = isWhitespaceUnit(units[target])
        var lower = target
        var upper = target
        while lower > units.startIndex {
            let candidate = units.index(before: lower)
            guard units[candidate].isHardBoundary == false,
                  isWhitespaceUnit(units[candidate]) == targetIsWhitespace
            else { break }
            lower = candidate
        }
        while upper < units.index(before: units.endIndex) {
            let candidate = units.index(after: upper)
            guard units[candidate].isHardBoundary == false,
                  isWhitespaceUnit(units[candidate]) == targetIsWhitespace
            else { break }
            upper = candidate
        }
        return publicRange(TextAnchorRange(
            start: units[lower].start,
            end: units[upper].end
        )) ?? emptyRange(at: position)
    }

    /// Returns one logical line across all soft-wrapped visual rows for quadruple-click selection.
    public func logicalLineRange(at position: TerminalTextPosition) -> TerminalTextRange {
        let stream = activeProjectionRows()
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
        let stream = activeProjectionRows()
        guard stream.isEmpty == false else { return nil }
        let row = min(max(position.row, 0), stream.count - 1)
        let column = min(max(position.column, 0), columnCount - 1)
        guard let id = stream[row].cells[column].hyperlinkId,
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
            guard stream[candidate.row].cells[candidate.column].hyperlinkId == id else { break }
            lower -= 1
        }
        while upper + 1 < coordinates.count {
            let candidate = coordinates[upper + 1]
            guard stream[candidate.row].cells[candidate.column].hyperlinkId == id else { break }
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
        let lineRange = logicalLineRange(at: position)
        let absoluteBase = evictedRowCount
        let stream = activeProjectionRows()
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
        stream: [GridRow]
    ) -> Int {
        guard range.start.row <= range.end.row else { return 0 }
        var identity = 0
        for row in range.start.row...range.end.row where stream.indices.contains(row) {
            let start = row == range.start.row ? range.start.column : 0
            let end = row == range.end.row ? range.end.column : columnCount
            for column in max(0, start)..<min(columnCount, end) {
                identity = max(identity, stream[row].cells[column].contentIdentity ?? 0)
            }
        }
        return identity
    }

    private func isTrailingURLPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        [0x2C, 0x2E, 0x3B, 0x3A, 0x21, 0x3F, 0x29, 0x5D, 0x7D].contains(scalar.value)
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
        let match = searchMatches(for: query).last
        search = SearchState(query: query, range: match)
        revealSearchMatchIfNeeded()
        recordDamage(since: before)
        return match != nil
    }

    /// Moves to the next older match, wrapping past the oldest back to the newest.
    @discardableResult
    public mutating func searchNext() -> Bool {
        guard let search else { return false }
        let matches = searchMatches(for: search.query)
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
        let matches = searchMatches(for: search.query)
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

    private func viewportStreamRow(at index: Int) -> GridRow? {
        guard index >= 0 else { return nil }
        if isAlternateScreenActive {
            return rows.indices.contains(index) ? rows[index] : nil
        }
        if scrollbackRows.indices.contains(index) {
            return scrollbackRows[index]
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

    private func activeProjectionRows() -> [GridRow] {
        var stream = scrollbackRows.asArray()
        if isAlternateScreenActive, let last = stream.indices.last {
            stream[last].isSoftWrapped = false
        }
        stream.append(contentsOf: rows)
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
        guard let lastContentRow = stream.lastIndex(where: rowContainsContent) else {
            return
        }

        for rowIndex in 0...lastContentRow {
            let row = stream[rowIndex]
            let end = projectedCellEnd(in: row)
            var column = 0
            while column < end {
                let cell = row.cells[column]
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

    private func projectedCellEnd(in row: GridRow) -> Int {
        row.isSoftWrapped ? row.cells.endIndex : retainedContentEnd(in: row)
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
        let stream = activeProjectionRows()
        let row = min(max(position.row, 0), stream.count - 1)
        var column = min(max(position.column, 0), columnCount - 1)
        if stream[row].cells[column].kind == .wideTail {
            column = max(0, column - 1)
        }
        return CellPosition(row: row, column: column)
    }

    private func normalizedBoundaryPosition(_ position: TerminalTextPosition) -> TextAnchor {
        let stream = activeProjectionRows()
        let row = min(max(position.row, 0), stream.count - 1)
        let column = min(max(position.column, 0), columnCount)
        return TextAnchor(row: evictedRowCount + row, column: column)
    }

    private func normalizedSelectionBoundary(
        _ position: TerminalTextPosition,
        isEnd: Bool
    ) -> TextAnchor {
        let stream = activeProjectionRows()
        let row = min(max(position.row, 0), stream.count - 1)
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

    private func nearestTextUnitIndex(
        to position: TerminalTextPosition,
        in units: [ProjectionUnit]
    ) -> Int? {
        let textIndices = units.indices.filter { units[$0].isHardBoundary == false }
        guard let first = textIndices.first else { return nil }
        let target = normalizedBoundaryPosition(position)
        if let containing = textIndices.first(where: {
            units[$0].start <= target && target < units[$0].end
        }) {
            return containing
        }
        return textIndices.last(where: { units[$0].start <= target }) ?? first
    }

    private func emptyRange(at position: TerminalTextPosition) -> TerminalTextRange {
        let boundary = normalizedBoundaryPosition(position)
        let publicPosition = TerminalTextPosition(
            row: boundary.row - evictedRowCount,
            column: boundary.column
        )
        return TerminalTextRange(start: publicPosition, end: publicPosition)
    }

    private func isWhitespaceUnit(_ unit: ProjectionUnit) -> Bool {
        unit.scalars.allSatisfy { $0.properties.isWhitespace }
    }

    private func wordClass(of unit: ProjectionUnit) -> Int {
        if isWhitespaceUnit(unit) { return 0 }
        if unit.scalars.allSatisfy({ scalar in
            let value = scalar.value
            return value >= 0x80
                || value == 0x5F
                || (0x30...0x39).contains(value)
                || (0x41...0x5A).contains(value)
                || (0x61...0x7A).contains(value)
        }) {
            return 1
        }
        return 2
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
        let stream = activeProjectionRows()
        let width = stream[position.row].cells[position.column].kind == .wideHead ? 2 : 1
        return TextAnchor(
            row: evictedRowCount + position.row,
            column: min(columnCount, position.column + width)
        )
    }

    private func searchMatches(for query: String) -> [TextAnchorRange] {
        let queryScalars = Array(query.unicodeScalars)
        guard queryScalars.isEmpty == false else { return [] }
        let units = projectionUnits()
        var matches: [TextAnchorRange] = []

        for startIndex in units.indices {
            var candidate: [Unicode.Scalar] = []
            var endIndex = startIndex
            while endIndex < units.endIndex, candidate.count < queryScalars.count {
                candidate.append(contentsOf: units[endIndex].scalars)
                endIndex += 1
            }
            guard candidate.count == queryScalars.count,
                  asciiFoldedEqual(candidate, queryScalars)
            else { continue }
            matches.append(TextAnchorRange(
                start: units[startIndex].start,
                end: units[endIndex - 1].end
            ))
        }
        return matches
    }

    private func asciiFoldedEqual(
        _ lhs: [Unicode.Scalar],
        _ rhs: [Unicode.Scalar]
    ) -> Bool {
        zip(lhs, rhs).allSatisfy { asciiFold($0) == asciiFold($1) }
    }

    private func asciiFold(_ scalar: Unicode.Scalar) -> UInt32 {
        let value = scalar.value
        return value >= 0x41 && value <= 0x5A ? value + 0x20 : value
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
        if let match = search?.range, range(match, intersects: rows) {
            self.search = nil
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
        if let match = search?.range, match.start < firstRetained {
            self.search = nil
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

    private static func scrollbackByteCost(of row: GridRow) -> Int {
        16 + row.cells.reduce(0) { total, cell in
            total + 32 + 8 * cell.scalars.count
        }
    }

    private mutating func appendToScrollback<S: Sequence>(_ newRows: S)
    where S.Element == GridRow {
        for row in newRows {
            scrollbackRows.append(row)
            scrollbackByteCount += Self.scrollbackByteCost(of: row)
        }
    }

    private mutating func enforceScrollbackBudget() {
        var lastEvicted: GridRow?
        var evictedCount = 0
        while scrollbackByteCount > scrollbackBudgetBytes {
            let evicted = scrollbackRows.removeFirst()
            scrollbackByteCount -= Self.scrollbackByteCost(of: evicted)
            lastEvicted = evicted
            evictedCount += 1
        }
        if let lastEvicted {
            isHistoryHeadTruncated = lastEvicted.isSoftWrapped
        }
        if evictedCount > 0 { primaryHistoryObservation.value &+= 1 }
        handleEviction(of: evictedCount)
    }

    /// Projects cell roles, row wraps, and cursor state without exposing mutable storage.
    public var geometry: TerminalGeometry {
        let projection = scrollProjection
        let windowRows = presentedRows
        let cursorStreamRow = isAlternateScreenActive
            ? cursor.row
            : scrollbackRows.count + cursor.row
        let cursorWindowRow = cursorStreamRow - projection.topRow
        return TerminalGeometry(
            columns: columnCount,
            rows: windowRows.map { row in
                TerminalRowGeometry(
                    cells: row.cells.map { TerminalCellGeometry(kind: $0.kind) },
                    isSoftWrapped: row.isSoftWrapped
                )
            },
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
              windowRow.cells.indices.contains(column)
        else {
            return nil
        }
        let cell = windowRow.cells[column]
        return TerminalCell(
            kind: cell.kind,
            scalars: cell.scalars,
            style: cell.style,
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
        guard let windowRow = viewportStreamRow(at: streamRow) else { return }
        for column in windowRow.cells.indices {
            body(column, windowRow.cells[column].scalars, windowRow.cells[column].style)
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

        let style = backgroundEraseStyle
        // The expansion above pulls every intersected wide pair wholly inside the
        // range, so no cell in it has a partner outside it. That is what lets the
        // interior be filled directly instead of through a per-cell
        // `clearCellAndPair`, whose two nested array subscripts cost a COW
        // uniqueness check on the row array and another on the cell array for
        // every single cell erased.
        let blank = GridCell(style: style)
        rows[row].cells.withUnsafeMutableBufferPointer { cells in
            for column in lower..<upper {
                cells[column] = blank
            }
        }
        // Loop-invariant: the repair is a no-op above column 1, so it runs once
        // for the range rather than once per erased cell. It is idempotent, so
        // the old per-cell calls at columns 0 and 1 did the work of this one.
        if lower <= 1 {
            clearPreviousSpacer(beforeRow: row, column: lower, replacementStyle: style)
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

    private func resizedRectangle(
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

    private func repairClippedCells(_ cells: inout [GridCell], clearsSpacers: Bool) {
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

    private func clippedBlank(replacing cell: GridCell) -> GridCell {
        GridCell(style: TerminalStyle(background: cell.style.background))
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
                    scrollbackRows.removeLast(pulledCount)
                    rows.insert(contentsOf: pulled, at: 0)
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
                    cursorDestination = ReflowDestination(
                        row: baseRow + packed.contentEnd.row,
                        column: min(packed.contentEnd.column + distance, newColumnCount - 1),
                        isPendingWrap: false
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
                let cell = row.cells[column]
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
                    if column + 1 < row.cells.count {
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
                                style: cell.style,
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
                    style: unit.cells[0].style,
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
        style: TerminalStyle = TerminalStyle()
    ) -> GridRow {
        GridRow(cells: (0..<columns).map { _ in GridCell(style: style) })
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
        for row in rows.indices {
            rows[row] = GridRow(cells: (0..<columnCount).map { _ in
                GridCell(kind: .narrow, scalars: .single("E"), style: currentStyle)
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
                makeBlankRow(columns: columnCount, style: backgroundEraseStyle)
            }
            semanticContent = .output
            semanticContentClearsAtEndOfLine = false
        } else if let primary = inactivePrimaryScreen {
            clearInspection()
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

        let style = backgroundEraseStyle
        severWrapClaim(before: 0, replacementStyle: style)
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
        let style = rows[target.row].cells[target.column].style
        let hyperlinkId = rows[target.row].cells[target.column].hyperlinkId
        let contentIdentity = rows[target.row].cells[target.column].contentIdentity
        var destination = target

        if target.column == columnCount - 1 {
            if isAutoWrapMode {
                clearCellAndPair(row: target.row, column: target.column)
                rows[target.row].cells[target.column] = GridCell(
                    kind: .spacerHead,
                    style: style,
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
            kind: .wideHead,
            scalars: scalars,
            style: style,
            hyperlinkId: hyperlinkId,
            contentIdentity: contentIdentity
        )
        rows[destination.row].cells[destination.column + 1] = GridCell(
            kind: .wideTail,
            style: style,
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

    private mutating func printNarrow(
        _ scalar: Unicode.Scalar,
        breakClass: GraphemeBreakClass
    ) {
        let contentIdentity = nextContentIdentity
        nextContentIdentity += 1
        invalidateInspection(inViewportRows: cursor.row..<(cursor.row + 1))
        if isInsertMode {
            moveAndFillCells(
                in: cursor.column..<columnCount,
                row: cursor.row,
                by: 1
            )
        }
        clearCellAndPair(row: cursor.row, column: cursor.column)
        rows[cursor.row].cells[cursor.column] = GridCell(
            kind: .narrow,
            scalars: .single(scalar),
            style: currentStyle,
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
        let contentIdentity = nextContentIdentity
        nextContentIdentity += 1
        invalidateInspection(inViewportRows: cursor.row..<(cursor.row + 1))
        var preservesWrappedSpacer = false
        if cursor.column == columnCount - 1 {
            if isAutoWrapMode {
                clearCellAndPair(row: cursor.row, column: cursor.column)
                rows[cursor.row].cells[cursor.column] = GridCell(
                    kind: .spacerHead,
                    style: currentStyle,
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
        rows[cursor.row].cells[cursor.column] = GridCell(
            kind: .wideHead,
            scalars: .single(scalar),
            style: currentStyle,
            hyperlinkId: hyperlinkPen,
            contentIdentity: contentIdentity
        )
        rows[cursor.row].cells[cursor.column + 1] = GridCell(
            kind: .wideTail,
            style: currentStyle,
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
        let style = backgroundEraseStyle

        if delta < 0, pushesToScrollback {
            // Only the evicted prefix has to outlive the move, so this copies `amount` rows
            // rather than the whole region. It must be materialized rather than passed as a
            // slice of `rows`: `appendToScrollback` is mutating, and handing it a slice of
            // `self.rows` would be an overlapping access to `self`.
            appendToScrollback(Array(rows[range.lowerBound..<(range.lowerBound + amount)]))
        } else {
            severWrapClaim(before: range.lowerBound, replacementStyle: style)
        }

        Self.moveInPlace(range, by: delta, amount: amount) { destination, source in
            if let source {
                let moved = rows[source]
                rows[destination] = moved
            } else {
                rows[destination] = makeBlankRow(columns: columnCount, style: style)
            }
        }

        let survivingCount = range.count - amount
        if survivingCount > 0, preservesTrailingWrap == false {
            let lastSurvivor = delta < 0
                ? range.lowerBound + survivingCount - 1
                : range.upperBound - 1
            severWrapClaim(at: lastSurvivor, replacementStyle: style)
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
        let style = backgroundEraseStyle

        Self.moveInPlace(range, by: delta, amount: amount) { destination, source in
            if let source {
                let moved = rows[row].cells[source]
                rows[row].cells[destination] = moved
            } else {
                rows[row].cells[destination] = GridCell(style: style)
            }
        }

        severWrapClaim(at: row, replacementStyle: style)
        clearPreviousSpacer(
            beforeRow: row,
            column: range.lowerBound,
            replacementStyle: style
        )
        repairHorizontalMove(in: row, replacementStyle: style)
    }

    private mutating func repairHorizontalMove(
        in row: Int,
        replacementStyle: TerminalStyle
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
            rows[row].cells[column] = GridCell(style: replacementStyle)
        }
    }

    private mutating func severWrapClaim(
        before row: Int,
        replacementStyle: TerminalStyle
    ) {
        if row > 0 {
            severWrapClaim(at: row - 1, replacementStyle: replacementStyle)
        } else if isAlternateScreenActive == false, let last = scrollbackRows.indices.last {
            severScrollbackWrapClaim(at: last, replacementStyle: replacementStyle)
        }
    }

    private mutating func severWrapClaim(
        at row: Int,
        replacementStyle: TerminalStyle
    ) {
        guard rows.indices.contains(row) else { return }
        guard rows[row].isSoftWrapped
            || rows[row].cells[columnCount - 1].kind == .spacerHead
        else { return }
        invalidateInspection(inViewportRows: row..<(row + 1))
        rows[row].isSoftWrapped = false
        if rows[row].cells[columnCount - 1].kind == .spacerHead {
            rows[row].cells[columnCount - 1] = GridCell(style: replacementStyle)
        }
    }

    private mutating func severScrollbackWrapClaim(
        at row: Int,
        replacementStyle: TerminalStyle
    ) {
        guard scrollbackRows[row].isSoftWrapped
            || scrollbackRows[row].cells[columnCount - 1].kind == .spacerHead
        else { return }
        invalidateInspection(inScrollbackRow: row)
        scrollbackRows[row].isSoftWrapped = false
        if scrollbackRows[row].cells[columnCount - 1].kind == .spacerHead {
            scrollbackRows[row].cells[columnCount - 1] = GridCell(style: replacementStyle)
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
        replacementStyle: TerminalStyle = TerminalStyle()
    ) {
        guard rows.indices.contains(row), rows[row].cells.indices.contains(column) else { return }
        switch rows[row].cells[column].kind {
        case .wideHead:
            rows[row].cells[column] = GridCell(style: replacementStyle)
            if column + 1 < columnCount {
                rows[row].cells[column + 1] = GridCell(style: replacementStyle)
            }
        case .wideTail:
            rows[row].cells[column] = GridCell(style: replacementStyle)
            if column > 0 {
                rows[row].cells[column - 1] = GridCell(style: replacementStyle)
            }
        case .padding, .narrow, .spacerHead:
            rows[row].cells[column] = GridCell(style: replacementStyle)
        }

        if clearsPreviousSpacer {
            clearPreviousSpacer(
                beforeRow: row,
                column: column,
                replacementStyle: replacementStyle
            )
        }
    }

    private mutating func clearPreviousSpacer(
        beforeRow row: Int,
        column: Int,
        replacementStyle: TerminalStyle = TerminalStyle()
    ) {
        guard column <= 1 else { return }
        if row > 0, rows[row - 1].cells[columnCount - 1].kind == .spacerHead {
            invalidateInspection(inViewportRows: (row - 1)..<row)
            rows[row - 1].cells[columnCount - 1] = GridCell(style: replacementStyle)
        } else if row == 0,
                  isAlternateScreenActive == false,
                  let last = scrollbackRows.indices.last,
                  scrollbackRows[last].cells[columnCount - 1].kind == .spacerHead
        {
            invalidateInspection(inScrollbackRow: last)
            scrollbackRows[last].cells[columnCount - 1] = GridCell(style: replacementStyle)
        }
    }
}
