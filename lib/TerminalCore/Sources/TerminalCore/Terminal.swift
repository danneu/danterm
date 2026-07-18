// Pure headless terminal reduction: byte ingestion, grid mutation, controls, and inspection.

/// Reduces terminal bytes into a deterministic value-semantic viewport without IO or callbacks.
public struct Terminal: Equatable, Sendable {
    /// Keeps scalar storage and wide-cell roles together for invariant-preserving mutation.
    private struct GridCell: Equatable, Sendable {
        var kind: TerminalCellKind = .padding
        var scalars: [Unicode.Scalar] = []
    }

    /// Moves soft-wrap identity with its cells during viewport scrolling.
    private struct GridRow: Equatable, Sendable {
        var cells: [GridCell]
        var isSoftWrapped = false
    }

    /// Tracks cursor and combining-mark attachment coordinates without exposing storage indices.
    private struct CellPosition: Equatable, Sendable {
        var row: Int
        var column: Int
    }

    private let columnCount: Int
    private let rowCount: Int
    private var rows: [GridRow]
    private var cursor = CellPosition(row: 0, column: 0)
    private var isPendingWrap = false
    private var attachTarget: CellPosition?
    private var inputStream = TerminalInputStream()

    /// Rejects dimensions that cannot represent all supported terminal cells.
    public init?(columns: Int, rows: Int) {
        guard columns >= 2, rows >= 1 else { return nil }
        columnCount = columns
        rowCount = rows
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
            case let .csi(sequence):
                dispatchCSI(sequence)
            }
        }
    }

    /// Renders the fixed viewport as unstyled text, representing padding as spaces.
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
        return TerminalCell(kind: cell.kind, scalars: cell.scalars)
    }

    /// Positions future parser actions while preserving the same cursor validity rules.
    mutating func moveCursor(row: Int, column: Int) {
        cursor.row = min(max(row, 0), rowCount - 1)
        cursor.column = min(max(column, 0), columnCount - 1)
        isPendingWrap = false
        attachTarget = nil
    }

    /// Clears a row range after expanding its boundaries across intersected wide pairs.
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

        for column in lower..<upper {
            clearCellAndPair(row: row, column: column)
        }
        attachTarget = nil
    }

    private mutating func dispatchCSI(_ sequence: CSISequence) {
        guard sequence.intermediates.isEmpty else { return }

        switch sequence.final {
        case 0x41, 0x6B:
            guard let amount = movementAmount(sequence.parameters) else { return }
            moveCursor(row: cursor.row - amount, column: cursor.column)
        case 0x42:
            guard let amount = movementAmount(sequence.parameters) else { return }
            moveCursor(row: cursor.row + amount, column: cursor.column)
        case 0x43:
            guard let amount = movementAmount(sequence.parameters) else { return }
            moveCursor(row: cursor.row, column: cursor.column + amount)
        case 0x44, 0x6A:
            guard let amount = movementAmount(sequence.parameters) else { return }
            moveCursor(row: cursor.row, column: cursor.column - amount)
        case 0x45:
            guard let amount = movementAmount(sequence.parameters) else { return }
            moveCursor(row: cursor.row + amount, column: 0)
        case 0x46:
            guard let amount = movementAmount(sequence.parameters) else { return }
            moveCursor(row: cursor.row - amount, column: 0)
        case 0x47, 0x60:
            guard sequence.parameters.count <= 1 else { return }
            moveCursor(row: cursor.row, column: absolutePosition(sequence.parameters.first))
        case 0x64:
            guard sequence.parameters.count <= 1 else { return }
            moveCursor(row: absolutePosition(sequence.parameters.first), column: cursor.column)
        case 0x48, 0x66:
            guard sequence.parameters.count <= 2 else { return }
            moveCursor(
                row: absolutePosition(sequence.parameters.first),
                column: absolutePosition(sequence.parameters.dropFirst().first)
            )
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
        default:
            break
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
            break
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

    private mutating func execute(_ control: UInt8) {
        switch control {
        case 0x08:
            cursor.column = max(0, cursor.column - 1)
            clearPendingMotionState()
        case 0x09:
            let previousColumn = cursor.column
            let nextStop = ((cursor.column / 8) + 1) * 8
            cursor.column = min(nextStop, columnCount - 1)
            if cursor.column != previousColumn {
                attachTarget = nil
            }
        case 0x0A, 0x0B, 0x0C:
            clearPendingMotionState()
            lineFeed()
        case 0x0D:
            cursor.column = 0
            clearPendingMotionState()
        default:
            break
        }
    }

    private mutating func clearPendingMotionState() {
        isPendingWrap = false
        attachTarget = nil
    }

    private mutating func print(_ scalar: Unicode.Scalar) {
        let properties = terminalUnicodeProperties(for: scalar)
        if properties.cellWidth == .zero {
            appendZeroWidth(scalar)
            return
        }

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
    }

    private mutating func appendZeroWidth(_ scalar: Unicode.Scalar) {
        guard let target = attachTarget else { return }
        guard rows.indices.contains(target.row), rows[target.row].cells.indices.contains(target.column) else {
            attachTarget = nil
            return
        }
        guard rows[target.row].cells[target.column].kind == .narrow
            || rows[target.row].cells[target.column].kind == .wideHead
        else {
            attachTarget = nil
            return
        }

        if scalar.value == 0xFE0E || scalar.value == 0xFE0F {
            guard let base = rows[target.row].cells[target.column].scalars.first,
                  terminalUnicodeProperties(for: base).isExtendedPictographic
            else { return }
        }
        rows[target.row].cells[target.column].scalars.append(scalar)
    }

    private mutating func printNarrow(_ scalar: Unicode.Scalar) {
        clearCellAndPair(row: cursor.row, column: cursor.column)
        rows[cursor.row].cells[cursor.column] = GridCell(kind: .narrow, scalars: [scalar])
        attachTarget = cursor

        if cursor.column == columnCount - 1 {
            isPendingWrap = true
        } else {
            cursor.column += 1
        }
    }

    private mutating func printWide(_ scalar: Unicode.Scalar) {
        var preservesWrappedSpacer = false
        if cursor.column == columnCount - 1 {
            clearCellAndPair(row: cursor.row, column: cursor.column)
            rows[cursor.row].cells[cursor.column] = GridCell(kind: .spacerHead, scalars: [])
            rows[cursor.row].isSoftWrapped = true
            advanceToNextRow()
            cursor.column = 0
            preservesWrappedSpacer = true
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
        rows[cursor.row].cells[cursor.column] = GridCell(kind: .wideHead, scalars: [scalar])
        rows[cursor.row].cells[cursor.column + 1] = GridCell(kind: .wideTail, scalars: [])
        attachTarget = cursor

        cursor.column += 1
        if cursor.column == columnCount - 1 {
            isPendingWrap = true
        } else {
            cursor.column += 1
            isPendingWrap = false
        }
    }

    private mutating func softWrap() {
        rows[cursor.row].isSoftWrapped = true
        advanceToNextRow()
        cursor.column = 0
        isPendingWrap = false
        attachTarget = nil
    }

    private mutating func lineFeed() {
        advanceToNextRow()
    }

    private mutating func advanceToNextRow() {
        if cursor.row == rowCount - 1 {
            rows.removeFirst()
            rows.append(GridRow(cells: (0..<columnCount).map { _ in GridCell() }))
        } else {
            cursor.row += 1
        }
    }

    private mutating func clearCellAndPair(
        row: Int,
        column: Int,
        clearsPreviousSpacer: Bool = true
    ) {
        guard rows.indices.contains(row), rows[row].cells.indices.contains(column) else { return }
        switch rows[row].cells[column].kind {
        case .wideHead:
            rows[row].cells[column] = GridCell()
            if column + 1 < columnCount {
                rows[row].cells[column + 1] = GridCell()
            }
        case .wideTail:
            rows[row].cells[column] = GridCell()
            if column > 0 {
                rows[row].cells[column - 1] = GridCell()
            }
        case .padding, .narrow, .spacerHead:
            rows[row].cells[column] = GridCell()
        }

        if clearsPreviousSpacer,
           row > 0,
           column <= 1,
           rows[row - 1].cells[columnCount - 1].kind == .spacerHead
        {
            rows[row - 1].cells[columnCount - 1] = GridCell()
        }
    }
}
