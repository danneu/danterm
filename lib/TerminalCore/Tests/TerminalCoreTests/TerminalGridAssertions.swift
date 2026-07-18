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
    expectValidGrid(terminal.geometry, sourceLocation: sourceLocation)
    for index in 0..<terminal.scrollbackRowCount {
        guard let row = terminal.scrollbackRow(at: index) else {
            Issue.record("missing scrollback row \(index)", sourceLocation: sourceLocation)
            continue
        }
        #expect(row.cells.count == terminal.geometry.columns, sourceLocation: sourceLocation)
        expectValidRow(
            kinds: row.cells.map(\.kind),
            isSoftWrapped: row.isSoftWrapped,
            sourceLocation: sourceLocation
        )
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
