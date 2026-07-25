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
        searchMatchBackground: plan.searchMatchBackground,
        backgroundRuns: plan.backgroundRuns.filter { rows.contains($0.row) },
        selectionRuns: plan.selectionRuns.filter { rows.contains($0.row) },
        searchMatchRuns: plan.searchMatchRuns.filter { rows.contains($0.row) },
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

/// Accumulates the text run currently being coalesced so extending it appends a
/// cell in place instead of rebuilding the whole run per cell, which made
/// both the copying and the width measurement quadratic in row length.
///
/// Being the payload of an `Optional` is the open/closed gate: there is no
/// closed state to mistake for an open one, so continuation can only be
/// considered while a run is genuinely open.
private struct OpenTextRun {
    let startColumn: Int
    let foreground: RenderColor
    let bold: Bool
    let italic: Bool
    private(set) var cells: [RenderTextCell]
    /// Sum of `cells`' column widths, advanced with every append so continuity
    /// never has to re-measure the run.
    private(set) var width: Int

    init(startColumn: Int, cell: RenderTextCell, style: ResolvedCellStyle) {
        self.startColumn = startColumn
        foreground = style.foreground
        bold = style.bold
        italic = style.italic
        cells = [cell]
        width = cell.columnWidth
    }

    func continues(at column: Int, style: ResolvedCellStyle) -> Bool {
        column == startColumn + width
            && style.foreground == foreground
            && style.bold == bold
            && style.italic == italic
    }

    mutating func extend(with cell: RenderTextCell) {
        cells.append(cell)
        width += cell.columnWidth
    }

    func finished(row: Int) -> RenderTextRun {
        RenderTextRun(
            row: row,
            startColumn: startColumn,
            cells: cells,
            foreground: foreground,
            bold: bold,
            italic: italic
        )
    }
}

/// Represents one decorated grid column before identical adjacent columns are
/// folded into a non-overlapping executor-facing decoration run.
private struct DecorationCandidate {
    let column: Int
    let kinds: [RenderDecorationKind]
    let color: RenderColor
    let strikethroughColor: RenderColor
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
            searchMatchBackground: presentation.theme.searchMatchBackground,
            backgroundRuns: backgroundRuns(cells),
            selectionRuns: highlightRuns(
                for: terminal.selectionRange,
                columns: geometry.columns,
                rows: geometry.rows.count
            ),
            searchMatchRuns: highlightRuns(
                for: terminal.activeSearchMatchRange,
                columns: geometry.columns,
                rows: geometry.rows.count
            ),
            textRuns: textRuns(cells),
            decorationRuns: decorationRuns(cells),
            cursor: cursorSpan.map {
                RenderCursor(
                    row: $0.row,
                    column: $0.column,
                    columnWidth: $0.columnWidth,
                    shape: presentation.cursorShape,
                    color: presentation.theme.cursor
                )
            }
        )
    }

    /// Clips one half-open stream range to the viewport as row-major overlay runs.
    ///
    /// Shared by the selection and search-match channels: both are stream-coordinate
    /// bands over the same projection, and drawing them from one clip is what keeps a
    /// match from landing a row off the selection covering the same text.
    private func highlightRuns(
        for range: TerminalTextRange?,
        columns: Int,
        rows: Int
    ) -> [RenderSelectionRun] {
        guard let selection = range,
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
                        underlineColor: style.foreground,
                        hidden: style.hidden,
                        strikethrough: style.strikethrough
                    )
                }
                if presentation.cursorShape == .block,
                   cursorSpan?.contains(row: row, column: column) == true {
                    style = ResolvedCellStyle(
                        foreground: presentation.theme.cursorText,
                        background: presentation.theme.cursor,
                        bold: style.bold,
                        italic: style.italic,
                        underline: style.underline,
                        underlineColor: presentation.theme.cursorText,
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
            // Cells that draw no glyph `continue` without reading or writing the
            // accumulator, so a filtered cell can never flush or extend an open
            // run -- a run spanning one splits only if the column arithmetic says
            // so. The column comes from the enumeration rather than a counter of
            // admitted cells, which is what keeps that arithmetic honest.
            var open: OpenTextRun?
            for (column, cell) in cells.enumerated() {
                guard cell.style.hidden == false else { continue }
                let width: Int
                switch cell.kind {
                case .narrow:
                    width = 1
                case .wideHead:
                    width = 2
                case .padding, .wideTail, .spacerHead:
                    continue
                }
                guard cell.scalars.isEmpty == false else { continue }

                let textCell = RenderTextCell(scalars: cell.scalars, columnWidth: width)
                if let run = open, run.continues(at: column, style: cell.style) {
                    open?.extend(with: textCell)
                } else {
                    if let run = open { result.append(run.finished(row: row)) }
                    open = OpenTextRun(startColumn: column, cell: textCell, style: cell.style)
                }
            }
            if let run = open { result.append(run.finished(row: row)) }
        }
        return result
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
                    color: cell.style.underline == .none
                        ? cell.style.foreground
                        : cell.style.underlineColor,
                    strikethroughColor: cell.style.foreground
                )
            }

            var current: RenderDecorationRun?
            for candidate in candidates {
                if let run = current,
                   candidate.column == run.startColumn + run.columnCount,
                   candidate.kinds == run.kinds,
                   candidate.color == run.color,
                   candidate.strikethroughColor == run.strikethroughColor
                {
                    current = RenderDecorationRun(
                        row: row,
                        startColumn: run.startColumn,
                        columnCount: run.columnCount + 1,
                        kinds: run.kinds,
                        color: run.color,
                        strikethroughColor: run.strikethroughColor
                    )
                } else {
                    if let current { result.append(current) }
                    current = RenderDecorationRun(
                        row: row,
                        startColumn: candidate.column,
                        columnCount: 1,
                        kinds: candidate.kinds,
                        color: candidate.color,
                        strikethroughColor: candidate.strikethroughColor
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
        case .dotted:
            result.append(.underlineDotted)
        case .dashed:
            result.append(.underlineDashed)
        }
        if style.strikethrough {
            result.append(.strikethrough)
        }
        return result
    }
}
