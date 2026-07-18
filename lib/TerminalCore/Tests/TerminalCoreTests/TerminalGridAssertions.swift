// Shared structural assertions for viewport and retained terminal rows.
import Testing

@testable import TerminalCore

func expectValidGrid(
    _ geometry: TerminalGeometry,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for row in geometry.rows {
        expectValidRow(
            kinds: row.cells.map(\.kind),
            isSoftWrapped: row.isSoftWrapped,
            sourceLocation: sourceLocation
        )
    }
}

func expectValidGrid(
    _ terminal: Terminal,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    var inspectedRows: [(cells: [TerminalCell], isSoftWrapped: Bool)] = []
    for index in 0..<terminal.scrollbackRowCount {
        guard let row = terminal.scrollbackRow(at: index) else {
            Issue.record("missing scrollback row \(index)", sourceLocation: sourceLocation)
            continue
        }
        #expect(row.cells.count == terminal.geometry.columns, sourceLocation: sourceLocation)
        inspectedRows.append((row.cells, row.isSoftWrapped))
        expectValidRow(
            kinds: row.cells.map(\.kind),
            isSoftWrapped: row.isSoftWrapped,
            sourceLocation: sourceLocation
        )
    }

    for (rowIndex, row) in terminal.geometry.rows.enumerated() {
        let cells = row.cells.indices.compactMap {
            terminal.cell(row: rowIndex, column: $0)
        }
        #expect(cells.count == terminal.geometry.columns, sourceLocation: sourceLocation)
        inspectedRows.append((cells, row.isSoftWrapped))
        expectValidRow(
            kinds: cells.map(\.kind),
            isSoftWrapped: row.isSoftWrapped,
            sourceLocation: sourceLocation
        )
    }

    for rowIndex in inspectedRows.indices {
        let cells = inspectedRows[rowIndex].cells
        for column in cells.indices {
            switch cells[column].kind {
            case .wideHead:
                if column + 1 < cells.count {
                    #expect(
                        cells[column + 1].style == cells[column].style,
                        sourceLocation: sourceLocation
                    )
                }
            case .wideTail:
                if column > 0 {
                    #expect(
                        cells[column - 1].style == cells[column].style,
                        sourceLocation: sourceLocation
                    )
                }
            case .spacerHead:
                #expect(rowIndex + 1 < inspectedRows.count, sourceLocation: sourceLocation)
                if rowIndex + 1 < inspectedRows.count,
                   let deferredHead = inspectedRows[rowIndex + 1].cells.first
                {
                    #expect(deferredHead.kind == .wideHead, sourceLocation: sourceLocation)
                    #expect(
                        deferredHead.style == cells[column].style,
                        sourceLocation: sourceLocation
                    )
                }
            case .padding, .narrow:
                break
            }
        }
    }
}

private func expectValidRow(
    kinds: [TerminalCellKind],
    isSoftWrapped: Bool,
    sourceLocation: SourceLocation
) {
    for column in kinds.indices {
        switch kinds[column] {
        case .wideHead:
            #expect(column + 1 < kinds.count, sourceLocation: sourceLocation)
            if column + 1 < kinds.count {
                #expect(kinds[column + 1] == .wideTail, sourceLocation: sourceLocation)
            }
        case .wideTail:
            #expect(column > 0, sourceLocation: sourceLocation)
            if column > 0 {
                #expect(kinds[column - 1] == .wideHead, sourceLocation: sourceLocation)
            }
        case .spacerHead:
            #expect(column == kinds.count - 1, sourceLocation: sourceLocation)
            #expect(isSoftWrapped, sourceLocation: sourceLocation)
        case .padding, .narrow:
            break
        }
    }
}
