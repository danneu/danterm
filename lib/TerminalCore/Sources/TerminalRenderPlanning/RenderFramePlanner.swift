// Pure viewport traversal, cursor policy, and canonical run construction for
// complete terminal frames. Platform drawing and cross-frame state stay outside.
import TerminalCore

/// Produces all grid-space drawing work from the terminal's public viewport
/// inspection surface and explicit presentation inputs alone.
public func planFrame(
    for terminal: Terminal,
    presentation: RenderPresentation
) -> RenderFramePlan {
    FramePlanner(terminal: terminal, presentation: presentation)
        .plan(reusing: nil, damage: .full)
        .plan
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

/// Retains the three cell-derived layers split per viewport row so a later frame
/// can copy an undamaged row's runs instead of re-inspecting its cells.
///
/// Row-major arrays rather than one flat plan: reuse is decided per row, and
/// keeping the rows separate is what makes copying a row an array append instead
/// of a filter over the whole frame. Only the cell-derived layers appear here --
/// selection, search-match, and cursor are recomputed every frame.
struct RetainedFrameRows: Sendable {
    let columns: Int
    let background: [[RenderBackgroundRun]]
    let text: [[RenderTextRun]]
    let decorations: [[RenderDecorationRun]]

    var rowCount: Int { background.count }
}

/// Pairs a finished plan with the state a following frame needs to reuse its rows.
struct PlannedFrame {
    let plan: RenderFramePlan
    let retained: RetainedFrameRows
}

/// Keeps one inspected cell's role, content, and resolved presentation together
/// while independent frame layers are derived from the same viewport pass.
private struct PlannedCell {
    let kind: TerminalCellKind
    let scalars: TerminalScalars
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
struct FramePlanner {
    let terminal: Terminal
    let presentation: RenderPresentation

    /// Plans a complete viewport, replanning only rows `damage` marks when
    /// `retained` describes the immediately preceding frame of the same stream.
    ///
    /// Callers own the lineage and presentation checks; this only refuses reuse
    /// on the shape mismatches it can see for itself (full damage, changed grid).
    func plan(reusing retained: RetainedFrameRows?, damage: TerminalDamage) -> PlannedFrame {
        let geometry = terminal.geometry
        let cursorSpan = normalizedCursor(in: geometry)
        let rowCount = geometry.rows.count

        let reusable: RetainedFrameRows? =
            if let retained,
               damage.isFull == false,
               retained.columns == geometry.columns,
               retained.rowCount == rowCount
            {
                retained
            } else {
                nil
            }

        var background: [[RenderBackgroundRun]] = []
        var text: [[RenderTextRun]] = []
        var decorations: [[RenderDecorationRun]] = []
        background.reserveCapacity(rowCount)
        text.reserveCapacity(rowCount)
        decorations.reserveCapacity(rowCount)

        // One traversal for every replanned row rather than one per row: retained history is
        // addressed once and carried forward, which is the contract `31/I7` states and the
        // mechanism `31/D3` Decision 1 rule 2 requires of a frame.
        let cells = inspectedCells(
            rows: 0..<rowCount,
            replanning: { reusable == nil || damage.rows.contains($0) },
            geometry: geometry,
            cursorSpan: cursorSpan
        )
        for row in 0..<rowCount {
            if let reusable, damage.rows.contains(row) == false {
                background.append(reusable.background[row])
                text.append(reusable.text[row])
                decorations.append(reusable.decorations[row])
                continue
            }
            background.append(backgroundRuns(row: row, cells: cells[row]))
            text.append(textRuns(row: row, cells: cells[row]))
            decorations.append(decorationRuns(row: row, cells: cells[row]))
        }

        let plan = RenderFramePlan(
            columns: geometry.columns,
            rows: rowCount,
            defaultBackground: presentation.theme.defaultBackground,
            selectionBackground: presentation.theme.selectionBackground,
            searchMatchBackground: presentation.theme.searchMatchBackground,
            backgroundRuns: Array(background.joined()),
            selectionRuns: highlightRuns(
                for: terminal.selectionRange,
                columns: geometry.columns,
                rows: rowCount
            ),
            searchMatchRuns: highlightRuns(
                for: terminal.activeSearchMatchRange,
                columns: geometry.columns,
                rows: rowCount
            ),
            textRuns: Array(text.joined()),
            decorationRuns: Array(decorations.joined()),
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
        return PlannedFrame(
            plan: plan,
            retained: RetainedFrameRows(
                columns: geometry.columns,
                background: background,
                text: text,
                decorations: decorations
            )
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

    /// Inspects every row `replanning` selects, in one traversal of the terminal's viewport.
    ///
    /// One traversal rather than one per row because addressing retained history costs a
    /// display-row-to-record locate, and paying one per visible row is exactly the per-frame cost
    /// `31/I7` exists to forbid. Rows the caller reuses are stepped over rather than inspected,
    /// so a damage-clipped frame still pays only for what it redraws; they come back empty.
    private func inspectedCells(
        rows: Range<Int>,
        replanning: (Int) -> Bool,
        geometry: TerminalGeometry,
        cursorSpan: CursorSpan?
    ) -> [[PlannedCell]] {
        // Both row-scoped lookups are hoisted deliberately. `terminal.cell(row:column:)`
        // re-resolved the viewport row on every column, and `isHovered` re-read
        // `hoveredLink` and `scrollProjection` on every column; a profile put the
        // resulting per-cell traffic at ~20% of `planFrame` (see
        // docs/research/14-live-scroll-workload-profile.md, F10). Resolve each once per
        // row, then walk the columns.
        var result = [[PlannedCell]](repeating: [], count: rows.count)
        var hovered: Range<Int>?
        var selected: Range<Int>?
        var lastResolvedRow = -1

        terminal.forEachViewportCell(rows: rows, where: replanning) {
            row, column, scalars, semanticStyle in
            let kinds = geometry.rows[row].cells
            guard column < kinds.count else { return }
            if row != lastResolvedRow {
                hovered = hoveredColumns(row: row, columns: geometry.columns)
                selected = selectedColumns(row: row, columns: geometry.columns)
                lastResolvedRow = row
                result[row].reserveCapacity(kinds.count)
            }
            result[row].append(plannedCell(
                row: row,
                column: column,
                kind: kinds[column].kind,
                scalars: scalars,
                semanticStyle: semanticStyle,
                hovered: hovered,
                selected: selected,
                cursorSpan: cursorSpan
            ))
        }

        // Columns the terminal row does not cover keep the empty/default content the
        // previous `terminal.cell(...) -> nil` path produced for them.
        for row in rows where replanning(row) {
            let kinds = geometry.rows[row].cells
            guard result[row].count < kinds.count else { continue }
            let hovered = hoveredColumns(row: row, columns: geometry.columns)
            let selected = selectedColumns(row: row, columns: geometry.columns)
            while result[row].count < kinds.count {
                result[row].append(plannedCell(
                    row: row,
                    column: result[row].count,
                    kind: kinds[result[row].count].kind,
                    scalars: .empty,
                    semanticStyle: TerminalStyle(),
                    hovered: hovered,
                    selected: selected,
                    cursorSpan: cursorSpan
                ))
            }
        }
        return result
    }

    private func plannedCell(
        row: Int,
        column: Int,
        kind: TerminalCellKind,
        scalars: TerminalScalars,
        semanticStyle: TerminalStyle,
        hovered: Range<Int>?,
        selected: Range<Int>?,
        cursorSpan: CursorSpan?
    ) -> PlannedCell {
        var style = resolveCellStyle(semanticStyle, theme: presentation.theme)
        if style.underline == .none, hovered?.contains(column) == true {
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
        if selected?.contains(column) == true {
            style = ResolvedCellStyle(
                foreground: presentation.theme.selectionForeground,
                background: style.background,
                bold: style.bold,
                italic: style.italic,
                underline: style.underline,
                underlineColor: style.underlineColor,
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
        return PlannedCell(kind: kind, scalars: scalars, style: style)
    }

    /// The hovered-link span for one row, resolved once instead of per column.
    private func hoveredColumns(row: Int, columns: Int) -> Range<Int>? {
        guard let range = terminal.hoveredLink?.range else { return nil }
        let streamRow = terminal.scrollProjection.topRow + row
        guard range.start.row...range.end.row ~= streamRow else { return nil }
        let start = streamRow == range.start.row ? range.start.column : 0
        let end = streamRow == range.end.row ? range.end.column : columns
        guard start <= end else { return nil }
        return start..<end
    }

    /// The local-selection span for one viewport row, resolved once per traversal.
    private func selectedColumns(row: Int, columns: Int) -> Range<Int>? {
        guard let selection = terminal.selectionRange else { return nil }
        let streamRow = terminal.scrollProjection.topRow + row
        guard selection.start.row...selection.end.row ~= streamRow else { return nil }
        let start = streamRow == selection.start.row ? selection.start.column : 0
        let end = streamRow == selection.end.row ? selection.end.column : columns
        let clampedStart = min(max(start, 0), columns)
        let clampedEnd = min(max(end, 0), columns)
        guard clampedStart < clampedEnd else { return nil }
        return clampedStart..<clampedEnd
    }

    private func backgroundRuns(row: Int, cells: [PlannedCell]) -> [RenderBackgroundRun] {
        var result: [RenderBackgroundRun] = []
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

    private func textRuns(row: Int, cells: [PlannedCell]) -> [RenderTextRun] {
        var result: [RenderTextRun] = []
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
        return result
    }

    private func decorationRuns(row: Int, cells: [PlannedCell]) -> [RenderDecorationRun] {
        var result: [RenderDecorationRun] = []
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
