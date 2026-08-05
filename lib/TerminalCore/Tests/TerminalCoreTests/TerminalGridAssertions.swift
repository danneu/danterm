// Shared structural assertions for viewport and retained terminal rows.
import Testing

@testable import TerminalCore

func expectValidGrid(
    _ terminal: Terminal,
    context: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    // The one bound history has, and the independent recount that catches a stale index --
    // `31/I2` and `31/I9`, asserted on every grid a suite validates rather than only where a
    // test remembered to look.
    #expect(
        terminal.scrollbackCensus.chargedBytes <= terminal.scrollbackCensus.capacityBytes,
        context,
        sourceLocation: sourceLocation
    )
    #expect(
        terminal.scrollbackRowCount == terminal.independentScrollbackRowRecount,
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

/// The arena bytes one retained logical line of `cells` printed cells charges.
///
/// Record-denominated since doc 31: history holds one record per logical line -- an 8-byte
/// header, one 8-byte cell per stored cell, and the identity run a line printed straight
/// through needs -- rather than one packed blob per display row. A fixture that wants a
/// *budget* asks `historyBudget(lines:cells:)`, which searches the store; this is for a
/// fixture that wants to state what one line costs.
func historyLineCost(cells: Int) -> Int {
    var total = RecordCharge.header + max(0, cells) * RecordCharge.cell
    if cells > 0 { total += RecordCharge.identityRun }
    return (total + 7) & ~7
}

/// The smallest byte budget that retains every logical line `lineCells` describes.
///
/// Searched against a real store rather than derived, for the reason doc 15's `D4` made the old
/// helper ask the engine too: what history charges is what the *allocator* gave, and under doc 31
/// that spans the records, the index rings, the side tables and the room the write path reserves
/// for a record's tables before it appends. No expression in a cell count reproduces that, and
/// one written from a model would silently size every fixture wrong.
func historyBudget(lineCells: [Int], paneColumns: Int = 0) -> Int {
    let width = max(2, lineCells.max() ?? 2)
    func retainsAll(_ budget: Int) -> Bool {
        var probe = Terminal.LogicalLineStore(budgetBytes: budget, width: width)
        for cells in lineCells {
            probe.admit(Terminal.GridRow(cells: (0..<cells).map {
                Terminal.GridCell(
                    scalars: TerminalScalars("a" as Unicode.Scalar),
                    kind: .narrow,
                    contentIdentity: Terminal.ContentIdentity($0 + 1)
                )
            }))
        }
        return probe.recordCount >= lineCells.count
    }

    var low = Terminal.minimumScrollbackBudgetBytes
    if retainsAll(low) { return low }
    var high = low
    while retainsAll(high) == false { high *= 2 }
    while high - low > 8 {
        let mid = (low + high) / 2 & ~7
        if retainsAll(mid) { high = mid } else { low = mid }
    }
    return max(high, fullWidthRowFloor(columns: paneColumns))
}

/// The smallest byte budget that retains `lines` logical lines of `cells` printed cells.
func historyBudget(lines: Int, cells: Int, paneColumns: Int = 0) -> Int {
    historyBudget(lineCells: Array(repeating: cells, count: lines), paneColumns: paneColumns)
}

/// A budget floor sized so one full-width soft-wrapped display row fits the arena.
///
/// A pane whose history cannot hold a single display row of its own width retains nothing at
/// all -- legal, and never what a fixture means. Named as a floor rather than folded into the
/// search because the search models the fixture's *lines*, and a wrapping line admits rows of
/// the pane's width whatever its own length.
private func fullWidthRowFloor(columns: Int) -> Int {
    guard columns > 0 else { return 0 }
    let arena = 112 + columns * 16
    var budget = (arena + 7) & ~7
    while budget - (((budget / 16) + 7) & ~7) < arena { budget += 8 }
    return budget
}

/// The record arena's fixed charges, so a fixture can spell out what a logical line is made of.
///
/// Restates `Terminal.LogicalLineRecord`'s charges deliberately rather than reading them: a
/// fixture that asked the store what it charges could not pin the encoding. Only the charges a
/// fixture actually spells out live here -- an unread constant pins nothing.
enum RecordCharge {
    static let header = 8
    static let cell = 8
    static let identityRun = 8
    static let identityCell = 4
}
