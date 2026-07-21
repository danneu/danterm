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
    /// Keeps scalar storage and wide-cell roles together for invariant-preserving mutation.
    private struct GridCell: Equatable, Sendable {
        var kind: TerminalCellKind = .padding
        var scalars: [Unicode.Scalar] = []
        var style = TerminalStyle()
    }

    /// Moves soft-wrap identity with its cells during viewport scrolling.
    private struct GridRow: Equatable, Sendable {
        var cells: [GridCell]
        var isSoftWrapped = false
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
    private struct SearchState: Equatable, Sendable {
        var query: String
        var range: TextAnchorRange
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
        var scalars: [Unicode.Scalar]
        var cellWidth: Int
    }

    /// Retains exactly the target and pairwise look-behind for one open grapheme cluster.
    private struct ClusterContext: Equatable, Sendable {
        var target: CellPosition
        var previousScalar: Unicode.Scalar
        var breakState = GraphemeBreakState()
    }

    /// Retains primary cells and their private reflow anchor while the alternate grid is active.
    private struct InactivePrimaryScreen: Equatable, Sendable {
        var rows: [GridRow]
        var resizeCursor: CellPosition
        var isResizePendingWrap: Bool
    }

    /// Carries one atomic cell unit and the old coordinates that must follow it.
    private struct ReflowUnit {
        var cells: [GridCell]
        var sourceOffsets: [(key: Int, offset: Int)]
    }

    /// Reconstructs one hard-delimited logical line only for the duration of reflow.
    private struct ReflowLine {
        var units: [ReflowUnit] = []
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
    private var primaryKittyKeyboardStack: [UInt16] = []
    private var alternateKittyKeyboardStack: [UInt16] = []
    private var evictedRowCount = 0
    private var selection: TextAnchorRange?
    private var search: SearchState?
    private var viewportState = ViewportState.following

    static let productionScrollbackBudgetBytes = 10_485_760
    static let kittyKeyboardStackDepth = 8

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

    /// Lets the serialized PTY owner route semantic wheel intent without a lagging snapshot.
    public var isAlternateScreenActive: Bool {
        inactivePrimaryScreen != nil
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

    /// Transfers all ordered terminal replies to one consumer without a parallel output path.
    public mutating func drainReplyBytes() -> [UInt8] {
        let drained = replyBytes
        replyBytes.removeAll(keepingCapacity: true)
        return drained
    }

    private var backgroundEraseStyle: TerminalStyle {
        TerminalStyle(
            foreground: currentStyle.foreground,
            background: currentStyle.background
        )
    }

    /// Rejects dimensions that cannot represent all supported terminal cells.
    public init?(columns: Int, rows: Int) {
        self.init(
            columns: columns,
            rows: rows,
            scrollbackBudgetBytes: Self.productionScrollbackBudgetBytes
        )
    }

    /// Gives deterministic tests a small budget while production remains fixed at 10 MiB.
    init?(columns: Int, rows: Int, scrollbackBudgetBytes: Int) {
        guard columns >= 2, rows >= 1, scrollbackBudgetBytes >= 0 else { return nil }
        columnCount = columns
        rowCount = rows
        self.scrollbackBudgetBytes = scrollbackBudgetBytes
        tabStops = Self.defaultTabStops(columns: columns)
        self.rows = (0..<rows).map { _ in
            GridRow(cells: (0..<columns).map { _ in GridCell() })
        }
    }

    /// Reduces a byte chunk synchronously while retaining unfinished stream state.
    public mutating func feed(_ bytes: [UInt8]) {
        for action in inputStream.feed(bytes) {
            switch action {
            case let .print(scalar):
                print(scalar)
            case let .execute(control):
                execute(control)
            case let .escape(final):
                dispatchEscape(final)
            case let .escapeSequence(sequence):
                dispatchEscape(sequence)
            case let .csi(sequence):
                dispatchCSI(sequence)
            }
        }
    }

    /// Resizes each screen by its contract while keeping the active cursor valid.
    public mutating func resize(columns: Int, rows: Int) {
        guard columns >= 2, rows >= 1 else { return }
        guard columns != columnCount || rows != rowCount else { return }

        if inactivePrimaryScreen != nil {
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

            self.rows = primary.rows
            cursor = primary.resizeCursor
            isPendingWrap = primary.isResizePendingWrap
            resizePrimaryScreen(columns: columns, rows: rows)
            primary.rows = self.rows
            primary.resizeCursor = cursor
            primary.isResizePendingWrap = isPendingWrap

            self.rows = resizedRectangle(
                alternateRows,
                columns: columns,
                rows: rows,
                clearsSoftWrap: columns != oldColumnCount
            )
            cursor = liveCursor
            isPendingWrap = livePendingWrap
            inactivePrimaryScreen = primary
        } else {
            resizePrimaryScreen(columns: columns, rows: rows)
        }

        clampCursorStateToActiveGrid()
        clampSelectionToRetainedStream()
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
        if inactivePrimaryScreen != nil {
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
        guard inactivePrimaryScreen == nil else { return }
        let current = scrollProjection.topRow
        let addition = current.addingReportingOverflow(rowDelta)
        let target = addition.overflow
            ? (rowDelta < 0 ? Int.min : Int.max)
            : addition.partialValue
        scroll(toTopRow: target)
    }

    /// Selects a top visual row in current-stream coordinates, clamping to a complete window.
    public mutating func scroll(toTopRow requestedRow: Int) {
        guard inactivePrimaryScreen == nil else { return }
        let maximumTop = max(0, scrollbackRows.count + rows.count - rowCount)
        let topRow = min(max(requestedRow, 0), maximumTop)
        if topRow == maximumTop {
            viewportState = .following
        } else {
            viewportState = .browsing(
                top: TextAnchor(row: evictedRowCount + topRow, column: 0)
            )
        }
    }

    /// Returns local presentation to live-bottom follow without changing terminal content.
    public mutating func scrollToBottom() {
        guard inactivePrimaryScreen == nil else { return }
        viewportState = .following
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
                TerminalCell(kind: $0.kind, scalars: $0.scalars, style: $0.style)
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
        guard inactivePrimaryScreen != nil else { return primaryHistoryText }
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

    /// Serializes the selected projection units, preserving an intentionally empty selection.
    public var selectedText: String? {
        guard let selection else { return nil }
        return text(in: selection)
    }

    /// Returns the current half-open search occurrence in stream coordinates.
    public var activeSearchMatchRange: TerminalTextRange? {
        search.flatMap { publicRange($0.range) }
    }

    /// Selects both endpoint cells after clamping them into the active stream.
    public mutating func setSelection(
        from: TerminalTextPosition,
        to: TerminalTextPosition
    ) {
        let first = normalizedCellPosition(from)
        let second = normalizedCellPosition(to)
        let ordered = positionPrecedes(first, second) ? (first, second) : (second, first)
        selection = TextAnchorRange(
            start: anchor(before: ordered.0),
            end: anchor(after: ordered.1)
        )
    }

    /// Clears only the local selection, leaving an active search untouched.
    public mutating func clearSelection() {
        selection = nil
    }

    /// Selects the newest literal match, or clears search state when none exists.
    @discardableResult
    public mutating func beginSearch(_ query: String) -> Bool {
        guard query.isEmpty == false, let match = searchMatches(for: query).last else {
            search = nil
            return false
        }
        search = SearchState(query: query, range: match)
        revealSearchMatchIfNeeded()
        return true
    }

    /// Moves to the next older match without wrapping or disturbing an end match.
    @discardableResult
    public mutating func searchNext() -> Bool {
        guard let search else { return false }
        let matches = searchMatches(for: search.query)
        guard let current = matches.firstIndex(of: search.range), current > 0 else {
            return false
        }
        self.search?.range = matches[current - 1]
        revealSearchMatchIfNeeded()
        return true
    }

    /// Moves to the previous newer match without wrapping or disturbing an end match.
    @discardableResult
    public mutating func searchPrevious() -> Bool {
        guard let search else { return false }
        let matches = searchMatches(for: search.query)
        guard let current = matches.firstIndex(of: search.range), current + 1 < matches.count else {
            return false
        }
        self.search?.range = matches[current + 1]
        revealSearchMatchIfNeeded()
        return true
    }

    /// Clears the query and its active occurrence together.
    public mutating func clearSearch() {
        search = nil
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
        if inactivePrimaryScreen != nil {
            return rows.indices.contains(index) ? rows[index] : nil
        }
        if scrollbackRows.indices.contains(index) {
            return scrollbackRows[index]
        }
        let liveIndex = index - scrollbackRows.count
        return rows.indices.contains(liveIndex) ? rows[liveIndex] : nil
    }

    private mutating func revealSearchMatchIfNeeded() {
        guard inactivePrimaryScreen == nil, let match = search?.range else { return }
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
        if inactivePrimaryScreen != nil, let last = stream.indices.last {
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
                    scalars = cell.scalars
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

    private mutating func clearInspection() {
        selection = nil
        search = nil
        viewportState = .following
    }

    private mutating func invalidateInspection(inViewportRows range: Range<Int>) {
        guard range.isEmpty == false, selection != nil || search != nil else { return }
        let lower = evictedRowCount + scrollbackRows.count + range.lowerBound
        let upper = evictedRowCount + scrollbackRows.count + range.upperBound - 1
        invalidateInspection(inAbsoluteRows: lower...upper)
    }

    private mutating func invalidateInspection(inScrollbackRow row: Int) {
        guard selection != nil || search != nil else { return }
        let absoluteRow = evictedRowCount + row
        invalidateInspection(inAbsoluteRows: absoluteRow...absoluteRow)
    }

    private mutating func invalidateInspection(inAbsoluteRows rows: ClosedRange<Int>) {
        if let selection, range(selection, intersects: rows) {
            self.selection = nil
        }
        if let search, range(search.range, intersects: rows) {
            self.search = nil
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
        if let search, search.range.start < firstRetained {
            self.search = nil
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
        handleEviction(of: evictedCount)
    }

    /// Projects cell roles, row wraps, and cursor state without exposing mutable storage.
    public var geometry: TerminalGeometry {
        let projection = scrollProjection
        let windowRows = presentedRows
        let cursorStreamRow = inactivePrimaryScreen == nil
            ? scrollbackRows.count + cursor.row
            : cursor.row
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
        return TerminalCell(kind: cell.kind, scalars: cell.scalars, style: cell.style)
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
        upper = min(upper, columnCount)

        invalidateInspection(inViewportRows: row..<(row + 1))

        let style = backgroundEraseStyle
        for column in lower..<upper {
            clearCellAndPair(row: row, column: column, replacementStyle: style)
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
                isSoftWrapped: clearsRowWrap ? false : source.isSoftWrapped
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
        let searchAttachments = search.map {
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
                            GridCell(kind: .wideTail, scalars: [], style: cell.style),
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
            }
            if unit.cells.count == 2, columns - column == 1 {
                packedRows[row].cells[column] = GridCell(
                    kind: .spacerHead,
                    scalars: [],
                    style: unit.cells[0].style
                )
                packedRows[row].isSoftWrapped = true
                packedRows.append(makeBlankRow(columns: columns))
                row += 1
                column = 0
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
            inactivePrimaryScreen == nil ? 2 : 1
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
        replyBytes.append(contentsOf: reply.utf8)
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
                if parameter != 58, let color = result.color {
                    set(color: color, foreground: parameter == 38)
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
            default:
                currentStyle.underline = .single
            }
        case 38, 48, 58:
            if leading != 58, let color = colonColor(in: group) {
                set(color: color, foreground: leading == 38)
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
                GridCell(kind: .narrow, scalars: ["E"], style: currentStyle)
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
        if enabled {
            clearInspection()
            if inactivePrimaryScreen == nil {
                inactivePrimaryScreen = InactivePrimaryScreen(
                    rows: rows,
                    resizeCursor: cursor,
                    isResizePendingWrap: isPendingWrap
                )
            }
            rows = (0..<rowCount).map { _ in
                makeBlankRow(columns: columnCount, style: backgroundEraseStyle)
            }
        } else if let primary = inactivePrimaryScreen {
            clearInspection()
            rows = primary.rows
            inactivePrimaryScreen = nil
        }
        clearPendingMotionState()
    }

    private mutating func selectPrimaryScreen() {
        guard let primary = inactivePrimaryScreen else { return }
        clearInspection()
        rows = primary.rows
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
        selectPrimaryScreen()
        resetControlState()
        clearPendingMotionState()
    }

    private mutating func hardReset() {
        clearInspection()
        evictedRowCount = 0
        selectPrimaryScreen()
        resetControlState()
        cursor = CellPosition(row: 0, column: 0)
        clearPendingMotionState()
        lastPrintedCluster = nil

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
            inactivePrimaryScreen == nil ? primaryKittyKeyboardStack : alternateKittyKeyboardStack
        }
        set {
            if inactivePrimaryScreen == nil {
                primaryKittyKeyboardStack = newValue
            } else {
                alternateKittyKeyboardStack = newValue
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
        if appendToOpenClusterIfJoined(scalar) {
            rememberOpenCluster()
            return
        }

        let properties = terminalUnicodeProperties(for: scalar)
        guard properties.cellWidth != .zero else { return }

        if isPendingWrap {
            invalidateInspection(inViewportRows: cursor.row..<(cursor.row + 1))
            softWrap()
        }

        switch properties.cellWidth {
        case .zero:
            break
        case .narrow:
            printNarrow(scalar)
        case .wide:
            printWide(scalar)
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

    private mutating func appendToOpenClusterIfJoined(_ scalar: Unicode.Scalar) -> Bool {
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
            between: context.previousScalar,
            and: scalar,
            state: &nextBreakState
        ) == false else {
            return false
        }

        guard let baseScalar = rows[target.row].cells[target.column].scalars.first else {
            clusterContext = nil
            return false
        }
        invalidateInspection(inViewportRows: target.row..<(target.row + 1))
        switch desiredClusterWidth(for: scalar, baseScalar: baseScalar) {
        case .wide where rows[target.row].cells[target.column].kind == .narrow:
            target = upgradeClusterToWide(at: target)
        case .narrow where rows[target.row].cells[target.column].kind == .wideHead:
            downgradeClusterToNarrow(at: target)
        case .zero, .narrow, .wide, nil:
            break
        }

        rows[target.row].cells[target.column].scalars.append(scalar)
        context.target = target
        context.previousScalar = scalar
        context.breakState = nextBreakState
        clusterContext = context
        return true
    }

    private func desiredClusterWidth(
        for scalar: Unicode.Scalar,
        baseScalar: Unicode.Scalar
    ) -> TerminalCellWidth? {
        if scalar.value == 0xFE0F || scalar.value == 0xFE0E {
            guard terminalUnicodeProperties(for: baseScalar).isEmojiVariationBase else {
                return nil
            }
            return scalar.value == 0xFE0F ? .wide : .narrow
        }

        let properties = terminalUnicodeProperties(for: scalar)
        guard properties.cellWidth != .zero, properties.isEmojiModifier == false else {
            return nil
        }
        switch graphemeBreakClass(for: scalar) {
        case .v, .t, .prepend:
            return nil
        default:
            return .wide
        }
    }

    private mutating func upgradeClusterToWide(at target: CellPosition) -> CellPosition {
        let scalars = rows[target.row].cells[target.column].scalars
        let style = rows[target.row].cells[target.column].style
        var destination = target

        if target.column == columnCount - 1 {
            if isAutoWrapMode {
                clearCellAndPair(row: target.row, column: target.column)
                rows[target.row].cells[target.column] = GridCell(
                    kind: .spacerHead,
                    scalars: [],
                    style: style
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
            style: style
        )
        rows[destination.row].cells[destination.column + 1] = GridCell(
            kind: .wideTail,
            scalars: [],
            style: style
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

    private mutating func printNarrow(_ scalar: Unicode.Scalar) {
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
            scalars: [scalar],
            style: currentStyle
        )
        clusterContext = ClusterContext(target: cursor, previousScalar: scalar)

        if cursor.column == columnCount - 1 {
            isPendingWrap = isAutoWrapMode
        } else {
            cursor.column += 1
        }
    }

    private mutating func printWide(_ scalar: Unicode.Scalar) {
        invalidateInspection(inViewportRows: cursor.row..<(cursor.row + 1))
        var preservesWrappedSpacer = false
        if cursor.column == columnCount - 1 {
            if isAutoWrapMode {
                clearCellAndPair(row: cursor.row, column: cursor.column)
                rows[cursor.row].cells[cursor.column] = GridCell(
                    kind: .spacerHead,
                    scalars: [],
                    style: currentStyle
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
            scalars: [scalar],
            style: currentStyle
        )
        rows[cursor.row].cells[cursor.column + 1] = GridCell(
            kind: .wideTail,
            scalars: [],
            style: currentStyle
        )
        clusterContext = ClusterContext(target: cursor, previousScalar: scalar)
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
        isPendingWrap = false
        clusterContext = nil
    }

    private mutating func lineFeed() {
        advanceToNextRow()
    }

    private mutating func advanceToNextRow(preservingWrapClaim: Bool = false) {
        let region = activeScrollRegion
        if cursor.row == region.upperBound - 1 {
            moveAndFillRows(
                in: region,
                by: -1,
                pushesToScrollback: scrollRegion == nil && inactivePrimaryScreen == nil,
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
            pushesToScrollback: scrollRegion == nil && inactivePrimaryScreen == nil
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
        let sourceRows = Array(rows[range])
        let style = backgroundEraseStyle

        if delta < 0, pushesToScrollback {
            appendToScrollback(sourceRows.prefix(amount))
        } else {
            severWrapClaim(before: range.lowerBound, replacementStyle: style)
        }

        for destination in range {
            let source = delta < 0 ? destination + amount : destination - amount
            if range.contains(source) {
                rows[destination] = sourceRows[source - range.lowerBound]
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

    // Horizontal counterpart to moveAndFillRows: both primitives snapshot,
    // clip, move intact storage, BCE-fill the vacated strip, and repair seams.
    private mutating func moveAndFillCells(
        in range: Range<Int>,
        row: Int,
        by delta: Int
    ) {
        guard range.isEmpty == false, delta != 0 else { return }
        invalidateInspection(inViewportRows: row..<(row + 1))
        let amount = min(abs(delta), range.count)
        let sourceCells = Array(rows[row].cells[range])
        let style = backgroundEraseStyle

        for destination in range {
            let source = delta < 0 ? destination + amount : destination - amount
            if range.contains(source) {
                rows[row].cells[destination] = sourceCells[source - range.lowerBound]
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
        } else if inactivePrimaryScreen == nil, let last = scrollbackRows.indices.last {
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
        } else if inactivePrimaryScreen == nil, let last = scrollbackRows.indices.last {
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
                  inactivePrimaryScreen == nil,
                  let last = scrollbackRows.indices.last,
                  scrollbackRows[last].cells[columnCount - 1].kind == .spacerHead
        {
            invalidateInspection(inScrollbackRow: last)
            scrollbackRows[last].cells[columnCount - 1] = GridCell(style: replacementStyle)
        }
    }
}
