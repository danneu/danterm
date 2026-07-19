// Pure headless terminal reduction: byte ingestion, grid mutation, controls, and inspection.

/// Reduces terminal bytes into deterministic value-semantic primary-screen state without IO.
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

    /// Tracks cursor coordinates without exposing storage indices.
    private struct CellPosition: Equatable, Sendable {
        var row: Int
        var column: Int
    }

    /// Keeps the one DECSC slot independent from live cursor and mode mutation.
    private struct SavedCursorState: Equatable, Sendable {
        var position = CellPosition(row: 0, column: 0)
        var style = TerminalStyle()
        var isPendingWrap = false
        var isOriginMode = false
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
    private var scrollbackRows: [GridRow] = []
    private var rows: [GridRow]
    private var scrollRegion: Range<Int>?
    private var cursor = CellPosition(row: 0, column: 0)
    private var isPendingWrap = false
    private var isInsertMode = false
    private var isLineFeedNewLineMode = false
    private var isOriginMode = false
    private var isAutoWrapMode = true
    private var tabStops: Set<Int>
    private var savedCursor = SavedCursorState()
    private var lastPrintedCluster: LastPrintedCluster?
    private var clusterContext: ClusterContext?
    private var inputStream = TerminalInputStream()

    /// Exposes the semantic SGR pen without allowing callers to mutate terminal state.
    public private(set) var currentStyle = TerminalStyle()

    private var backgroundEraseStyle: TerminalStyle {
        TerminalStyle(
            foreground: currentStyle.foreground,
            background: currentStyle.background
        )
    }

    /// Rejects dimensions that cannot represent all supported terminal cells.
    public init?(columns: Int, rows: Int) {
        guard columns >= 2, rows >= 1 else { return nil }
        columnCount = columns
        rowCount = rows
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
            case let .csi(sequence):
                dispatchCSI(sequence)
            }
        }
    }

    /// Resizes the primary screen while preserving its logical history and cursor attachment.
    public mutating func resize(columns: Int, rows: Int) {
        guard columns >= 2, rows >= 1 else { return }
        guard columns != columnCount || rows != rowCount else { return }

        scrollRegion = nil
        if rows != rowCount {
            resizeHeight(to: rows)
        }
        if columns != columnCount {
            resizeTabStops(from: columnCount, to: columns)
            resizeWidth(to: columns)
        }
        clusterContext = nil
    }

    /// Renders the current viewport as unstyled text, representing padding as spaces.
    public var screenText: String {
        rows.map { row in
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

    /// Projects retained history and the viewport as logical text without a final newline.
    public var fullHistoryText: String {
        let stream = scrollbackRows + rows
        guard let lastContentRow = stream.lastIndex(where: rowContainsContent) else {
            return ""
        }

        var result = ""
        for index in 0...lastContentRow {
            appendProjectedText(from: stream[index], to: &result)
            if index < lastContentRow, stream[index].isSoftWrapped == false {
                result.append("\n")
            }
        }
        return result
    }

    /// Projects cell roles, row wraps, and cursor state without exposing mutable storage.
    public var geometry: TerminalGeometry {
        TerminalGeometry(
            columns: columnCount,
            rows: rows.map { row in
                TerminalRowGeometry(
                    cells: row.cells.map { TerminalCellGeometry(kind: $0.kind) },
                    isSoftWrapped: row.isSoftWrapped
                )
            },
            cursor: TerminalCursor(
                row: cursor.row,
                column: cursor.column,
                isPendingWrap: isPendingWrap
            )
        )
    }

    /// Returns scalar-exact content for a valid viewport coordinate.
    public func cell(row: Int, column: Int) -> TerminalCell? {
        guard rows.indices.contains(row), self.rows[row].cells.indices.contains(column) else {
            return nil
        }
        let cell = rows[row].cells[column]
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

        let style = backgroundEraseStyle
        for column in lower..<upper {
            clearCellAndPair(row: row, column: column, replacementStyle: style)
        }
        clusterContext = nil
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
                scrollbackRows.append(contentsOf: rows.prefix(displacedCount))
                rows.removeFirst(displacedCount)
                if cursor.row < displacedCount {
                    cursor.row = 0
                } else {
                    cursor.row -= displacedCount
                }
            }
        } else {
            let addedCount = newRowCount - rowCount
            var pulledCount = 0
            if cursor.row == rowCount - 1 {
                pulledCount = min(addedCount, scrollbackRows.count)
                if pulledCount > 0 {
                    let split = scrollbackRows.count - pulledCount
                    let pulled = Array(scrollbackRows[split...])
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
    }

    private mutating func resizeWidth(to newColumnCount: Int) {
        let oldColumnCount = columnCount
        let oldBottomDistance = rowCount - 1 - cursor.row
        let oldCursorGlobalRow = scrollbackRows.count + cursor.row
        let fullStream = scrollbackRows + rows
        let lastContentRow = fullStream.lastIndex(where: rowContainsContent) ?? 0
        let retainedLastRow = max(oldCursorGlobalRow, lastContentRow)
        let sourceRows = Array(fullStream[...retainedLastRow])
        let reconstruction = reconstructLogicalLines(
            from: sourceRows,
            cursorGlobalRow: oldCursorGlobalRow,
            viewportTopGlobalRow: scrollbackRows.count,
            oldColumnCount: oldColumnCount
        )

        var rebuiltRows: [GridRow] = []
        var cursorDestination: ReflowDestination?
        var viewportTopDestinationRow = 0
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
        scrollbackRows = Array(rebuiltRows[..<viewportStart])
        rows = Array(rebuiltRows[viewportStart...])
        columnCount = newColumnCount
        cursor = CellPosition(
            row: max(0, destination.row - viewportStart),
            column: destination.column
        )
        isPendingWrap = destination.isPendingWrap
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
        viewportTopKey: Int?
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
            viewportTopMetadata.firstSourceKey
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
            default:
                break
            }
            return
        }
        guard sequence.intermediates.isEmpty else { return }

        switch sequence.final {
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
            case 6:
                isOriginMode = enabled
                cursor = CellPosition(row: positioningOriginRow, column: 0)
                shouldClearPendingMotion = true
            case 7:
                isAutoWrapMode = enabled
                shouldClearPendingMotion = true
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
            default:
                continue
            }
        }
        if shouldClearPendingMotion {
            clearPendingMotionState()
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
            scrollbackRows.removeAll(keepingCapacity: true)
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
            isOriginMode: isOriginMode
        )
    }

    private mutating func restoreCursor() {
        isOriginMode = savedCursor.isOriginMode
        let rowRange = positioningRowRange
        cursor = CellPosition(
            row: min(max(savedCursor.position.row, rowRange.lowerBound), rowRange.upperBound - 1),
            column: min(max(savedCursor.position.column, 0), columnCount - 1)
        )
        currentStyle = savedCursor.style
        clusterContext = nil
        isPendingWrap = savedCursor.isPendingWrap
            && isAutoWrapMode
            && cursor.column == columnCount - 1
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
        resetControlState()
        clearPendingMotionState()
    }

    private mutating func hardReset() {
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
        isOriginMode = false
        isAutoWrapMode = true
        tabStops = Self.defaultTabStops(columns: columnCount)
        currentStyle = TerminalStyle()
    }

    private mutating func print(_ scalar: Unicode.Scalar) {
        if appendToOpenClusterIfJoined(scalar) {
            rememberOpenCluster()
            return
        }

        let properties = terminalUnicodeProperties(for: scalar)
        guard properties.cellWidth != .zero else { return }

        if isPendingWrap {
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
                pushesToScrollback: scrollRegion == nil,
                preservesTrailingWrap: preservingWrapClaim
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
            pushesToScrollback: scrollRegion == nil
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
        preservesTrailingWrap: Bool = false
    ) {
        guard range.isEmpty == false, delta != 0 else { return }
        let amount = min(abs(delta), range.count)
        let sourceRows = Array(rows[range])
        let style = backgroundEraseStyle

        if delta < 0, pushesToScrollback {
            scrollbackRows.append(contentsOf: sourceRows.prefix(amount))
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
    }

    // Horizontal counterpart to moveAndFillRows: both primitives snapshot,
    // clip, move intact storage, BCE-fill the vacated strip, and repair seams.
    private mutating func moveAndFillCells(
        in range: Range<Int>,
        row: Int,
        by delta: Int
    ) {
        guard range.isEmpty == false, delta != 0 else { return }
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
        } else if let last = scrollbackRows.indices.last {
            severScrollbackWrapClaim(at: last, replacementStyle: replacementStyle)
        }
    }

    private mutating func severWrapClaim(
        at row: Int,
        replacementStyle: TerminalStyle
    ) {
        guard rows.indices.contains(row) else { return }
        rows[row].isSoftWrapped = false
        if rows[row].cells[columnCount - 1].kind == .spacerHead {
            rows[row].cells[columnCount - 1] = GridCell(style: replacementStyle)
        }
    }

    private mutating func severScrollbackWrapClaim(
        at row: Int,
        replacementStyle: TerminalStyle
    ) {
        scrollbackRows[row].isSoftWrapped = false
        if scrollbackRows[row].cells[columnCount - 1].kind == .spacerHead {
            scrollbackRows[row].cells[columnCount - 1] = GridCell(style: replacementStyle)
        }
    }

    private mutating func restoreWrapClaimBeforeCursor() {
        if cursor.row > 0 {
            rows[cursor.row - 1].isSoftWrapped = true
        } else if let last = scrollbackRows.indices.last {
            scrollbackRows[last].isSoftWrapped = true
        }
    }

    private func rowContainsContent(_ row: GridRow) -> Bool {
        row.cells.contains { cell in
            cell.kind == .narrow || cell.kind == .wideHead
        }
    }

    private func appendProjectedText(from row: GridRow, to result: inout String) {
        let end = row.isSoftWrapped
            ? row.cells.endIndex
            : (row.cells.lastIndex { cell in
                cell.kind == .narrow || cell.kind == .wideHead
            }.map { $0 + 1 } ?? row.cells.startIndex)

        for cell in row.cells[..<end] {
            switch cell.kind {
            case .narrow, .wideHead:
                result.unicodeScalars.append(contentsOf: cell.scalars)
            case .padding:
                result.append(" ")
            case .wideTail, .spacerHead:
                break
            }
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
            rows[row - 1].cells[columnCount - 1] = GridCell(style: replacementStyle)
        } else if row == 0,
                  let last = scrollbackRows.indices.last,
                  scrollbackRows[last].cells[columnCount - 1].kind == .spacerHead
        {
            scrollbackRows[last].cells[columnCount - 1] = GridCell(style: replacementStyle)
        }
    }
}
