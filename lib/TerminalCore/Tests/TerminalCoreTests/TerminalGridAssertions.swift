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
    #expect(
        terminal.scrollbackByteCount <= terminal.scrollbackBudgetBytes,
        sourceLocation: sourceLocation
    )
    #expect(
        terminal.scrollbackByteCount == terminal.recomputedScrollbackByteCount,
        sourceLocation: sourceLocation
    )

    var liveTerminal = terminal
    liveTerminal.scrollToBottom()
    let activeRows = inspectedViewportRows(of: liveTerminal, sourceLocation: sourceLocation)
    expectValidStream(activeRows, sourceLocation: sourceLocation)

    var primary = terminal
    primary.feed(Array("\u{1B}[?1047l".utf8))
    primary.scrollToBottom()
    var primaryRows: [(cells: [TerminalCell], isSoftWrapped: Bool)] =
        (0..<primary.scrollbackRowCount).compactMap { index in
        guard let row = primary.scrollbackRow(at: index) else {
            Issue.record("missing scrollback row \(index)", sourceLocation: sourceLocation)
            return nil
        }
        #expect(row.cells.count == primary.geometry.columns, sourceLocation: sourceLocation)
        return (row.cells, row.isSoftWrapped)
    }
    primaryRows.append(contentsOf: inspectedViewportRows(
        of: primary,
        sourceLocation: sourceLocation
    ))
    expectValidStream(primaryRows, sourceLocation: sourceLocation)
}

/// Checks the OSC 133 prompt-anchor state and every mutation-level violation observed so far.
func expectSemanticPromptInvariants(
    _ terminal: Terminal,
    context: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let stateViolations = semanticPromptStateViolations(
        in: terminal.semanticPromptRowsForTesting
    )
    #expect(
        stateViolations.isEmpty,
        "\(context): \(stateViolations.map(\.rawValue).joined(separator: ", "))",
        sourceLocation: sourceLocation
    )
    let transitionViolations = terminal.semanticPromptTransitionViolationsForTesting
    #expect(
        transitionViolations.isEmpty,
        "\(context): \(transitionViolations.map(\.rawValue).joined(separator: ", "))",
        sourceLocation: sourceLocation
    )
}

/// Evaluates the stable snapshot proof for ownership and logical-line integrity.
func semanticPromptStateViolations(
    in rows: [TerminalSemanticPromptRowSnapshot]
) -> [TerminalSemanticPromptInvariantViolation] {
    var violations: [TerminalSemanticPromptInvariantViolation] = []
    for index in rows.indices {
        let row = rows[index]
        if row.stamp == .vacated,
           row.isEmpty,
           index + 1 < rows.count,
           rows[index + 1].stamp == .prompt
        {
            violations.append(.ownership)
        }
        if row.stamp == .prompt,
           index > 0,
           rows[index - 1].isSoftWrapped
        {
            violations.append(.logicalLineIntegrity)
        }
        if row.stamp == .vacated, row.isEmpty, row.isSoftWrapped {
            violations.append(.totalVacating)
        }
    }
    return Array(Set(violations)).sorted { $0.rawValue < $1.rawValue }
}

private func inspectedViewportRows(
    of terminal: Terminal,
    sourceLocation: SourceLocation
) -> [(cells: [TerminalCell], isSoftWrapped: Bool)] {
    terminal.geometry.rows.enumerated().map { rowIndex, row in
        let cells = row.cells.indices.compactMap {
            terminal.cell(row: rowIndex, column: $0)
        }
        #expect(cells.count == terminal.geometry.columns, sourceLocation: sourceLocation)
        return (cells, row.isSoftWrapped)
    }
}

private func expectValidStream(
    _ inspectedRows: [(cells: [TerminalCell], isSoftWrapped: Bool)],
    sourceLocation: SourceLocation
) {
    for row in inspectedRows {
        expectValidRow(
            kinds: row.cells.map(\.kind),
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
                    #expect(
                        cells[column + 1].hyperlink == cells[column].hyperlink,
                        sourceLocation: sourceLocation
                    )
                }
            case .wideTail:
                if column > 0 {
                    #expect(
                        cells[column - 1].style == cells[column].style,
                        sourceLocation: sourceLocation
                    )
                    #expect(
                        cells[column - 1].hyperlink == cells[column].hyperlink,
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
                    #expect(
                        deferredHead.hyperlink == cells[column].hyperlink,
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

/// Bytes one full-width history row costs in the terminal's own byte accounting.
///
/// Test budgets are written as multiples of this rather than as magic numbers, so the cost model
/// lives in one place. Correcting it (doc 15's `H1`, which moved an ordinary cell from a charged
/// 40 bytes to its true stride) otherwise means reverse-engineering the intended row count out of
/// a dozen unrelated literals scattered across suites.
///
/// It asks the engine rather than restating its arithmetic, which doc 15's `D4` made necessary: the
/// budget now charges the storage a row *reserves*, and a row's cell array is allocated in a malloc
/// bucket that holds more cells than the row has columns (90 at 80 columns, 218 at 200). No
/// expression in a column count can reproduce that, and one written from a stride would silently
/// under-size every budget at real pane widths.
///
/// Blank and single-scalar cells cost the same -- only a multi-scalar cluster adds a spill
/// allocation, so `spilledClusterScalars` lists the scalar count of each such cluster.
func historyRowCost(columns: Int, spilledClusterScalars: [Int] = []) -> Int {
    Terminal.blankScrollbackRowByteCost(columns: columns)
        + spilledClusterScalars.reduce(0) { $0 + 32 + $1 * 4 }
}
