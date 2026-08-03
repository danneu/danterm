// Shared structural assertions for viewport and retained terminal rows.
import Darwin
import Testing

@testable import TerminalCore

func expectValidGrid(
    _ geometry: TerminalGeometry,
    context: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for row in geometry.rows {
        expectValidRow(
            kinds: row.cells.map(\.kind),
            isSoftWrapped: row.isSoftWrapped,
            context: context,
            sourceLocation: sourceLocation
        )
    }
}

func expectValidGrid(
    _ terminal: Terminal,
    context: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        terminal.scrollbackByteCount <= terminal.scrollbackBudgetBytes,
        context,
        sourceLocation: sourceLocation
    )
    #expect(
        terminal.scrollbackByteCount == terminal.recomputedScrollbackByteCount,
        context,
        sourceLocation: sourceLocation
    )

    var liveTerminal = terminal
    liveTerminal.scrollToBottom()
    let activeRows = inspectedViewportRows(
        of: liveTerminal,
        context: context,
        sourceLocation: sourceLocation
    )
    expectValidStream(activeRows, context: context, sourceLocation: sourceLocation)

    var primary = terminal
    primary.feed(Array("\u{1B}[?1047l".utf8))
    primary.scrollToBottom()
    var primaryRows: [(cells: [TerminalCell], isSoftWrapped: Bool)] =
        (0..<primary.scrollbackRowCount).compactMap { index in
        guard let row = primary.scrollbackRow(at: index) else {
            if let context {
                Issue.record(context, sourceLocation: sourceLocation)
            } else {
                Issue.record("missing scrollback row \(index)", sourceLocation: sourceLocation)
            }
            return nil
        }
        #expect(
            row.cells.count == primary.geometry.columns,
            context,
            sourceLocation: sourceLocation
        )
        return (row.cells, row.isSoftWrapped)
    }
    primaryRows.append(contentsOf: inspectedViewportRows(
        of: primary,
        context: context,
        sourceLocation: sourceLocation
    ))
    expectValidStream(primaryRows, context: context, sourceLocation: sourceLocation)
}

/// Checks the snapshot-provable OSC 133 prompt-anchor invariants (I1 ownership, I2 logical-line
/// integrity, I4 total vacating). The transition invariants (I3, I5, I6) quantify over what a
/// single blanking or reclaim mutation changed, which no post-event snapshot can prove; they are
/// covered by targeted behavioral tests in `TerminalSemanticPromptInvariantTests` that bracket
/// the relevant operation precisely.
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
    context: Comment?,
    sourceLocation: SourceLocation
) -> [(cells: [TerminalCell], isSoftWrapped: Bool)] {
    terminal.geometry.rows.enumerated().map { rowIndex, row in
        let cells = row.cells.indices.compactMap {
            terminal.cell(row: rowIndex, column: $0)
        }
        #expect(
            cells.count == terminal.geometry.columns,
            context,
            sourceLocation: sourceLocation
        )
        return (cells, row.isSoftWrapped)
    }
}

private func expectValidStream(
    _ inspectedRows: [(cells: [TerminalCell], isSoftWrapped: Bool)],
    context: Comment?,
    sourceLocation: SourceLocation
) {
    for row in inspectedRows {
        expectValidRow(
            kinds: row.cells.map(\.kind),
            isSoftWrapped: row.isSoftWrapped,
            context: context,
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
                        context,
                        sourceLocation: sourceLocation
                    )
                    #expect(
                        cells[column + 1].hyperlink == cells[column].hyperlink,
                        context,
                        sourceLocation: sourceLocation
                    )
                }
            case .wideTail:
                if column > 0 {
                    #expect(
                        cells[column - 1].style == cells[column].style,
                        context,
                        sourceLocation: sourceLocation
                    )
                    #expect(
                        cells[column - 1].hyperlink == cells[column].hyperlink,
                        context,
                        sourceLocation: sourceLocation
                    )
                }
            case .spacerHead:
                #expect(
                    rowIndex + 1 < inspectedRows.count,
                    context,
                    sourceLocation: sourceLocation
                )
                if rowIndex + 1 < inspectedRows.count,
                   let deferredHead = inspectedRows[rowIndex + 1].cells.first
                {
                    #expect(
                        deferredHead.kind == .wideHead,
                        context,
                        sourceLocation: sourceLocation
                    )
                    #expect(
                        deferredHead.style == cells[column].style,
                        context,
                        sourceLocation: sourceLocation
                    )
                    #expect(
                        deferredHead.hyperlink == cells[column].hyperlink,
                        context,
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
    context: Comment?,
    sourceLocation: SourceLocation
) {
    for column in kinds.indices {
        switch kinds[column] {
        case .wideHead:
            #expect(column + 1 < kinds.count, context, sourceLocation: sourceLocation)
            if column + 1 < kinds.count {
                #expect(
                    kinds[column + 1] == .wideTail,
                    context,
                    sourceLocation: sourceLocation
                )
            }
        case .wideTail:
            #expect(column > 0, context, sourceLocation: sourceLocation)
            if column > 0 {
                #expect(
                    kinds[column - 1] == .wideHead,
                    context,
                    sourceLocation: sourceLocation
                )
            }
        case .spacerHead:
            #expect(column == kinds.count - 1, context, sourceLocation: sourceLocation)
            #expect(isSoftWrapped, context, sourceLocation: sourceLocation)
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
/// Sized on a row of *printed* cells since doc 28's packing. The packed retained row charges
/// by content -- a scalar column, a style run, an identity run -- so a full-width row of
/// never-written cells is both cheaper and a shape history does not hold at full width
/// (canonical trimming collapses it to one cell). A budget written in blank rows would admit
/// a different number of real rows than the test that wrote it intends.
///
/// Only a multi-scalar cluster adds a spill allocation, so `spilledClusterScalars` lists the
/// scalar count of each such cluster.
func historyRowCost(columns: Int, spilledClusterScalars: [Int] = []) -> Int {
    Terminal.compactScrollbackRowByteCost(storedCells: columns)
        + spilledClusterScalars.reduce(0) { $0 + 32 + $1 * 4 }
}

/// Bytes an ordinary compact history row costs for an exact stored-cell extent.
func compactHistoryRowCost(storedCells: Int) -> Int {
    Terminal.compactScrollbackRowByteCost(storedCells: storedCells)
}

/// Bytes history charges for a packed retained row whose blob holds `payloadBytes`.
///
/// Restates doc 28's `C6` charge -- row slot, array header, the allocator's answer for the
/// blob, and one allocation per multi-scalar spill -- so a budget fixture can be written as
/// the arithmetic it means instead of a number recovered from a failing assertion. Asks
/// libmalloc for the rounding for the same reason `historyRowCost` asks the engine: no
/// expression in a payload size reproduces a size class.
func packedHistoryRowCost(payloadBytes: Int, spilledClusterScalars: [Int] = []) -> Int {
    let arrayHeader = 32
    var total = MemoryLayout<Terminal.PackedRetainedRow>.stride
        + arrayHeader
        + (malloc_good_size(arrayHeader + payloadBytes) - arrayHeader)
    if spilledClusterScalars.isEmpty == false {
        // The spill directory, then one allocation per cluster.
        total += arrayHeader
            + (malloc_good_size(arrayHeader + spilledClusterScalars.count * 8) - arrayHeader)
        for scalars in spilledClusterScalars {
            total += arrayHeader + (malloc_good_size(arrayHeader + scalars * 4) - arrayHeader)
        }
    }
    return total
}

/// The packed blob's own fixed costs, so a fixture can spell out what a row's payload is
/// made of. Mirrors `Terminal.PackedRetainedRow.Header` deliberately rather than reading it:
/// a fixture that asked the encoder what it charges could not pin the encoding.
enum PackedRowCharge {
    static let header = 13
    static let styleRun = 6
    static let kindException = 3
    static let spillException = 7
    static let hyperlinkException = 4
    static let identityRun = 8
    static let identityCell = 4
}
