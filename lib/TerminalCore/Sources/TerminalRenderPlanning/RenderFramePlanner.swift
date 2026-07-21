// Pure viewport traversal, cursor policy, and canonical run construction for
// complete terminal frames. Platform drawing and cross-frame state stay outside.
import TerminalCore

/// Produces all grid-space drawing work from the terminal's public viewport
/// inspection surface and explicit presentation inputs alone.
public func planFrame(
    for terminal: Terminal,
    presentation: RenderPresentation
) -> RenderFramePlan {
    FramePlanner(terminal: terminal, presentation: presentation).plan()
}

/// Narrows a complete retained frame to the visible rows a damage pass must draw.
public func clipFramePlan(
    _ plan: RenderFramePlan,
    to damage: TerminalDamage
) -> RenderFramePlan {
    guard damage.isFull == false else { return plan }
    let rows = damage.rows.filter { plan.rows > $0 }
    return RenderFramePlan(
        columns: plan.columns,
        rows: plan.rows,
        defaultBackground: plan.defaultBackground,
        selectionBackground: plan.selectionBackground,
        backgroundRuns: plan.backgroundRuns.filter { rows.contains($0.row) },
        selectionRuns: plan.selectionRuns.filter { rows.contains($0.row) },
        textRuns: plan.textRuns.filter { rows.contains($0.row) },
        decorationRuns: plan.decorationRuns.filter { rows.contains($0.row) },
        cursor: plan.cursor.flatMap { rows.contains($0.row) ? $0 : nil }
    )
}

/// Keeps one inspected cell's role, content, and resolved presentation together
/// while independent frame layers are derived from the same viewport pass.
private struct PlannedCell {
    let kind: TerminalCellKind
    let scalars: [Unicode.Scalar]
    let style: ResolvedCellStyle
}

/// Records the cursor's normalized grid span once so both layer overrides and
/// the executor-facing cursor record use identical wide-cell policy.
private struct CursorSpan {
    let row: Int
    let column: Int
    let columnWidth: Int

    func contains(row: Int, column: Int) -> Bool {
        self.row == row && self.column..<self.column + columnWidth ~= column
    }
}

/// Represents a glyph cell before adjacent cells with identical shaping inputs
/// are folded into an executor-facing text run.
private struct TextCandidate {
    let column: Int
    let cell: RenderTextCell
    let foreground: RenderColor
    let bold: Bool
    let italic: Bool
}

/// Represents one decorated grid column before identical adjacent columns are
/// folded into a non-overlapping executor-facing decoration run.
private struct DecorationCandidate {
    let column: Int
    let kinds: [RenderDecorationKind]
    let color: RenderColor
}

/// Owns only one call's transient traversal state, preserving a stateless public
/// planning boundary while keeping layer algorithms in one focused type.
private struct FramePlanner {
    let terminal: Terminal
    let presentation: RenderPresentation

    func plan() -> RenderFramePlan {
        let geometry = terminal.geometry
        let cursorSpan = normalizedCursor(in: geometry)
        let cells = inspectedCells(geometry: geometry, cursorSpan: cursorSpan)

        return RenderFramePlan(
            columns: geometry.columns,
            rows: geometry.rows.count,
            defaultBackground: presentation.theme.defaultBackground,
            selectionBackground: presentation.theme.selectionBackground,
            backgroundRuns: backgroundRuns(cells),
            selectionRuns: selectionRuns(
                columns: geometry.columns,
                rows: geometry.rows.count
            ),
            textRuns: textRuns(cells),
            decorationRuns: decorationRuns(cells),
            cursor: cursorSpan.map {
                RenderCursor(row: $0.row, column: $0.column, columnWidth: $0.columnWidth)
            }
        )
    }

    private func selectionRuns(columns: Int, rows: Int) -> [RenderSelectionRun] {
        guard let selection = terminal.selectionRange,
              selection.start != selection.end,
              columns > 0,
              rows > 0
        else {
            return []
        }

        let topRow = terminal.scrollProjection.topRow
        let viewportRows = topRow..<(topRow + rows)
        let firstRow = max(selection.start.row, viewportRows.lowerBound)
        let lastRow = min(selection.end.row, viewportRows.upperBound - 1)
        guard firstRow <= lastRow else { return [] }

        var result: [RenderSelectionRun] = []
        for streamRow in firstRow...lastRow {
            let start = streamRow == selection.start.row ? selection.start.column : 0
            let end = streamRow == selection.end.row ? selection.end.column : columns
            let clampedStart = min(max(start, 0), columns)
            let clampedEnd = min(max(end, 0), columns)
            guard clampedStart < clampedEnd else { continue }
            result.append(RenderSelectionRun(
                row: streamRow - topRow,
                startColumn: clampedStart,
                columnCount: clampedEnd - clampedStart
            ))
        }
        return result
    }

    private func normalizedCursor(in geometry: TerminalGeometry) -> CursorSpan? {
        guard presentation.isCursorVisible, let cursor = geometry.cursor else { return nil }
        guard geometry.rows.indices.contains(cursor.row),
              geometry.rows[cursor.row].cells.indices.contains(cursor.column)
        else {
            return nil
        }

        let kind = geometry.rows[cursor.row].cells[cursor.column].kind
        switch kind {
        case .wideHead where cursor.column + 1 < geometry.columns:
            return CursorSpan(row: cursor.row, column: cursor.column, columnWidth: 2)
        case .wideTail where cursor.column > 0
            && geometry.rows[cursor.row].cells[cursor.column - 1].kind == .wideHead:
            return CursorSpan(row: cursor.row, column: cursor.column - 1, columnWidth: 2)
        default:
            return CursorSpan(row: cursor.row, column: cursor.column, columnWidth: 1)
        }
    }

    private func inspectedCells(
        geometry: TerminalGeometry,
        cursorSpan: CursorSpan?
    ) -> [[PlannedCell]] {
        geometry.rows.indices.map { row in
            geometry.rows[row].cells.indices.map { column in
                let inspected = terminal.cell(row: row, column: column)
                let semanticStyle = inspected?.style ?? TerminalStyle()
                var style = resolveCellStyle(semanticStyle, theme: presentation.theme)
                if style.underline == .none, isHovered(row: row, column: column) {
                    style = ResolvedCellStyle(
                        foreground: style.foreground,
                        background: style.background,
                        bold: style.bold,
                        italic: style.italic,
                        underline: .single,
                        hidden: style.hidden,
                        strikethrough: style.strikethrough
                    )
                }
                if cursorSpan?.contains(row: row, column: column) == true {
                    style = ResolvedCellStyle(
                        foreground: presentation.theme.cursorText,
                        background: presentation.theme.cursor,
                        bold: style.bold,
                        italic: style.italic,
                        underline: style.underline,
                        hidden: style.hidden,
                        strikethrough: style.strikethrough
                    )
                }
                return PlannedCell(
                    kind: geometry.rows[row].cells[column].kind,
                    scalars: inspected?.scalars ?? [],
                    style: style
                )
            }
        }
    }

    private func isHovered(row: Int, column: Int) -> Bool {
        guard let range = terminal.hoveredLink?.range else { return false }
        let streamRow = terminal.scrollProjection.topRow + row
        guard range.start.row...range.end.row ~= streamRow else { return false }
        let start = streamRow == range.start.row ? range.start.column : 0
        let end = streamRow == range.end.row ? range.end.column : terminal.geometry.columns
        return start..<end ~= column
    }

    private func backgroundRuns(_ rows: [[PlannedCell]]) -> [RenderBackgroundRun] {
        var result: [RenderBackgroundRun] = []
        for (row, cells) in rows.enumerated() {
            var startColumn: Int?
            var color: RenderColor?

            for (column, cell) in cells.enumerated() {
                let cellColor = cell.style.background
                guard cellColor != presentation.theme.defaultBackground else {
                    appendBackgroundRun(
                        row: row,
                        endColumn: column,
                        startColumn: &startColumn,
                        color: &color,
                        to: &result
                    )
                    continue
                }
                if color != cellColor {
                    appendBackgroundRun(
                        row: row,
                        endColumn: column,
                        startColumn: &startColumn,
                        color: &color,
                        to: &result
                    )
                    startColumn = column
                    color = cellColor
                }
            }
            appendBackgroundRun(
                row: row,
                endColumn: cells.count,
                startColumn: &startColumn,
                color: &color,
                to: &result
            )
        }
        return result
    }

    private func appendBackgroundRun(
        row: Int,
        endColumn: Int,
        startColumn: inout Int?,
        color: inout RenderColor?,
        to result: inout [RenderBackgroundRun]
    ) {
        if let startColumn, let color {
            result.append(RenderBackgroundRun(
                row: row,
                startColumn: startColumn,
                columnCount: endColumn - startColumn,
                color: color
            ))
        }
        startColumn = nil
        color = nil
    }

    private func textRuns(_ rows: [[PlannedCell]]) -> [RenderTextRun] {
        var result: [RenderTextRun] = []
        for (row, cells) in rows.enumerated() {
            let candidates = cells.enumerated().compactMap { column, cell -> TextCandidate? in
                guard cell.style.hidden == false else { return nil }
                let width: Int
                switch cell.kind {
                case .narrow:
                    width = 1
                case .wideHead:
                    width = 2
                case .padding, .wideTail, .spacerHead:
                    return nil
                }
                guard cell.scalars.isEmpty == false else { return nil }
                return TextCandidate(
                    column: column,
                    cell: RenderTextCell(scalars: cell.scalars, columnWidth: width),
                    foreground: cell.style.foreground,
                    bold: cell.style.bold,
                    italic: cell.style.italic
                )
            }

            var current: RenderTextRun?
            for candidate in candidates {
                if let run = current,
                   candidate.column == run.startColumn + textWidth(run),
                   candidate.foreground == run.foreground,
                   candidate.bold == run.bold,
                   candidate.italic == run.italic
                {
                    current = RenderTextRun(
                        row: row,
                        startColumn: run.startColumn,
                        cells: run.cells + [candidate.cell],
                        foreground: run.foreground,
                        bold: run.bold,
                        italic: run.italic
                    )
                } else {
                    if let current { result.append(current) }
                    current = RenderTextRun(
                        row: row,
                        startColumn: candidate.column,
                        cells: [candidate.cell],
                        foreground: candidate.foreground,
                        bold: candidate.bold,
                        italic: candidate.italic
                    )
                }
            }
            if let current { result.append(current) }
        }
        return result
    }

    private func textWidth(_ run: RenderTextRun) -> Int {
        run.cells.reduce(0) { $0 + $1.columnWidth }
    }

    private func decorationRuns(_ rows: [[PlannedCell]]) -> [RenderDecorationRun] {
        var result: [RenderDecorationRun] = []
        for (row, cells) in rows.enumerated() {
            let candidates = cells.enumerated().compactMap {
                column, cell -> DecorationCandidate? in
                guard cell.style.hidden == false else { return nil }
                switch cell.kind {
                case .narrow, .wideHead, .wideTail:
                    break
                case .padding, .spacerHead:
                    return nil
                }
                let kinds = decorationKinds(for: cell.style)
                guard kinds.isEmpty == false else { return nil }
                return DecorationCandidate(
                    column: column,
                    kinds: kinds,
                    color: cell.style.foreground
                )
            }

            var current: RenderDecorationRun?
            for candidate in candidates {
                if let run = current,
                   candidate.column == run.startColumn + run.columnCount,
                   candidate.kinds == run.kinds,
                   candidate.color == run.color
                {
                    current = RenderDecorationRun(
                        row: row,
                        startColumn: run.startColumn,
                        columnCount: run.columnCount + 1,
                        kinds: run.kinds,
                        color: run.color
                    )
                } else {
                    if let current { result.append(current) }
                    current = RenderDecorationRun(
                        row: row,
                        startColumn: candidate.column,
                        columnCount: 1,
                        kinds: candidate.kinds,
                        color: candidate.color
                    )
                }
            }
            if let current { result.append(current) }
        }
        return result
    }

    private func decorationKinds(for style: ResolvedCellStyle) -> [RenderDecorationKind] {
        var result: [RenderDecorationKind] = []
        switch style.underline {
        case .none:
            break
        case .single:
            result.append(.underlineSingle)
        case .double:
            result.append(.underlineDouble)
        case .curly:
            result.append(.underlineCurly)
        }
        if style.strikethrough {
            result.append(.strikethrough)
        }
        return result
    }
}
