// Pure viewport traversal, cursor policy, and canonical run construction for
// complete terminal frames. Platform drawing and cross-frame state stay outside.
import TerminalCore

/// Produces all grid-space drawing work from the terminal's public viewport
/// inspection surface and explicit presentation inputs alone.
public func planFrame(
    for terminal: borrowing Terminal,
    presentation: RenderPresentation
) -> RenderFramePlan {
    FramePlanner(presentation: presentation)
        .plan(for: terminal, reusing: nil, damage: .full)
        .plan
}

// Row rewrites for translated reuse: a run copied across a shift is identical
// except for the row it names, and each run's payload arrays ride along by
// reference. Fileprivate because only `FramePlanner.plan`'s reuse loop may
// relocate a run -- everywhere else a run's row is an invariant.
extension RenderBackgroundRun {
    fileprivate func translated(to row: Int) -> RenderBackgroundRun {
        RenderBackgroundRun(
            row: row,
            startColumn: startColumn,
            columnCount: columnCount,
            color: color
        )
    }
}

extension RenderOverlayRun {
    fileprivate func translated(to row: Int) -> RenderOverlayRun {
        RenderOverlayRun(
            row: row,
            startColumn: startColumn,
            columnCount: columnCount,
            state: state,
            color: color
        )
    }
}

extension RenderTextRun {
    fileprivate func translated(to row: Int) -> RenderTextRun {
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

extension RenderDecorationRun {
    fileprivate func translated(to row: Int) -> RenderDecorationRun {
        RenderDecorationRun(
            row: row,
            startColumn: startColumn,
            columnCount: columnCount,
            kinds: kinds,
            color: color,
            strikethroughColor: strikethroughColor
        )
    }
}

/// Retains the four cell-derived layers split per viewport row so a later frame
/// can copy an undamaged row's runs instead of re-inspecting its cells.
///
/// Row-major arrays rather than one flat plan: reuse is decided per row, and
/// keeping the rows separate is what makes copying a row an array append instead
/// of a filter over the whole frame. The cursor is recomputed every frame because
/// it remains a single frame-level record rather than a row-derived layer.
struct RetainedFrameRows: Sendable {
    let columns: Int
    let rows: [RenderPlanRow]
    let cursorStyle: ResolvedCursorStyle?

    var rowCount: Int { rows.count }
}

/// Pairs a finished plan with the state a following frame needs to reuse its rows.
struct PlannedFrame {
    let plan: RenderFramePlan
    let retained: RetainedFrameRows
}

/// Resolves the overlay state at one column from the row-local selection and match spans.
private func overlayState(
    at column: Int,
    selected: Range<Int>?,
    matches: [(columns: Range<Int>, isActive: Bool)]
) -> RenderOverlayState? {
    let isSelected = selected?.contains(column) == true
    guard let match = matches.first(where: { $0.columns.contains(column) }) else {
        return isSelected ? .selection : nil
    }
    return switch (isSelected, match.isActive) {
    case (true, true): .selectionAndActiveSearchMatch
    case (true, false): .selectionAndSearchMatch
    case (false, true): .activeSearchMatch
    case (false, false): .searchMatch
    }
}

/// Accumulates one maximal non-default background span without rebuilding its value per cell.
private struct OpenBackgroundRun {
    let startColumn: Int
    let color: RenderColor
    private(set) var columnCount = 1

    mutating func extend() {
        columnCount += 1
    }

    func finished(row: Int) -> RenderBackgroundRun {
        RenderBackgroundRun(
            row: row,
            startColumn: startColumn,
            columnCount: columnCount,
            color: color
        )
    }
}

/// Accumulates one maximal resolved overlay span and its latest source background.
private struct OpenOverlayRun {
    let startColumn: Int
    let state: RenderOverlayState
    let fill: RenderColor
    private(set) var sourceBackground: RenderColor
    private(set) var columnCount = 1

    mutating func extend(sourceBackground: RenderColor) {
        self.sourceBackground = sourceBackground
        columnCount += 1
    }

    func finished(row: Int) -> RenderOverlayRun {
        RenderOverlayRun(
            row: row,
            startColumn: startColumn,
            columnCount: columnCount,
            state: state,
            color: fill
        )
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
        continues(
            at: column,
            foreground: style.foreground,
            bold: style.bold,
            italic: style.italic
        )
    }

    func continues(
        at column: Int,
        foreground: RenderColor,
        bold: Bool,
        italic: Bool
    ) -> Bool {
        column == startColumn + width
            && foreground == self.foreground
            && bold == self.bold
            && italic == self.italic
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

/// Accumulates one maximal decoration span without rebuilding its value per cell.
private struct OpenDecorationRun {
    let startColumn: Int
    let kinds: [RenderDecorationKind]
    let color: RenderColor
    let strikethroughColor: RenderColor
    private(set) var columnCount = 1

    mutating func extend() {
        columnCount += 1
    }

    func finished(row: Int) -> RenderDecorationRun {
        RenderDecorationRun(
            row: row,
            startColumn: startColumn,
            columnCount: columnCount,
            kinds: kinds,
            color: color,
            strikethroughColor: strikethroughColor
        )
    }
}

/// Owns one call's small presentation input while borrowing the terminal state
/// it inspects, preserving a stateless public planning boundary.
struct FramePlanner {
    let presentation: RenderPresentation

    /// Plans a complete viewport, replanning only rows `damage` marks when
    /// `retained` describes the immediately preceding frame of the same stream.
    ///
    /// Callers own the lineage and presentation checks; this only refuses reuse
    /// on the shape mismatches it can see for itself (full damage, changed grid).
    func plan(
        for terminal: borrowing Terminal,
        reusing retained: RetainedFrameRows?,
        damage: TerminalDamage
    ) -> PlannedFrame {
        let columnCount = terminal.viewportColumnCount
        let scrollProjection = terminal.scrollProjection
        let rowCount = scrollProjection.windowRows
        let cursorSpan = presentation.isCursorVisible ? terminal.cursorPlacement : nil

        let reusable: RetainedFrameRows? =
            if let retained,
               damage.isFull == false,
               retained.columns == columnCount,
               retained.rowCount == rowCount
            {
                retained
            } else {
                nil
            }

        let emptyRow = RenderPlanRow(
            backgroundRuns: [],
            overlayRuns: [],
            textRuns: [],
            decorationRuns: [],
            inkClass: []
        )
        var rows = [RenderPlanRow](repeating: emptyRow, count: rowCount)

        // The retained row viewport row `row` may copy instead of re-inspecting,
        // or nil to replan it. Identity for undamaged rows the shift does not
        // cover; `row - delta` inside a shifted region, which is what keeps row
        // reuse alive across a scroll (research/33 T9): the recorded shift is
        // exactly the permutation the grid applied, so the translated copy is
        // the row a fresh inspection would produce, and every row that claim
        // does not hold for (the vacated strip, wrap seams, the cursor rows) is
        // in the damage set and replans.
        let shift = damage.shift
        func reuseSource(_ row: Int) -> Int? {
            guard reusable != nil else { return nil }
            if damage.contains(row: row) { return nil }
            guard let shift, shift.region.contains(row) else { return row }
            let source = row - shift.delta
            return shift.region.contains(source) ? source : nil
        }

        let selectionRange = terminal.selectionRange
        let hoveredLinkRange = terminal.hoveredLink?.range
        let activeSearchMatchRange = terminal.activeSearchMatchRange
        let viewportTop = scrollProjection.topRow
        let viewportRows = viewportTop..<(viewportTop + rowCount)
        let searchMatchRanges = terminal.searchMatchRanges(in: viewportRows)
        var cursorStyle = reusable?.cursorStyle

        // Copy reusable rows before the traversal so the traversal can write each replanned row
        // directly into its retained destination. A translated row changes only its row field;
        // payload arrays remain shared.
        for row in 0..<rowCount {
            guard let reusable, let source = reuseSource(row) else { continue }
            if source == row {
                rows[row] = reusable.rows[row]
            } else {
                let sourceRow = reusable.rows[source]
                rows[row] = RenderPlanRow(
                    backgroundRuns: sourceRow.backgroundRuns.map { $0.translated(to: row) },
                    overlayRuns: sourceRow.overlayRuns.map { $0.translated(to: row) },
                    textRuns: sourceRow.textRuns.map { $0.translated(to: row) },
                    decorationRuns: sourceRow.decorationRuns.map { $0.translated(to: row) },
                    inkClass: sourceRow.inkClass
                )
            }
        }

        // One traversal for every replanned row rather than one per row: retained history is
        // addressed once and carried forward, which is the contract `31/I7` states and the
        // mechanism `research/31/D3` Decision 1 rule 2 requires of a frame. The four open runs
        // are locals of the row body on purpose. Moving them outside this frame would make the
        // per-cell closure re-read captured row state, the regression measured by `31/F13`.
        terminal.forEachViewportRow(
            rows: 0..<rowCount,
            where: { reuseSource($0) == nil }
        ) { row, visit in
            let hovered = hoveredColumns(
                for: hoveredLinkRange,
                row: row,
                columns: columnCount,
                viewportTop: viewportTop
            )
            let selected = columns(
                for: selectionRange,
                row: row,
                columns: columnCount,
                viewportTop: viewportTop
            )
            let matches = searchMatchRanges.compactMap { match -> (Range<Int>, Bool)? in
                guard let columns = columns(
                    for: match,
                    row: row,
                    columns: columnCount,
                    viewportTop: viewportTop
                ) else {
                    return nil
                }
                return (columns, match == activeSearchMatchRange)
            }
            let rowHasOverlays = selected != nil || matches.isEmpty == false
            let rowCursor = cursorSpan.flatMap { $0.row == row ? $0 : nil }
            let blockCursorColumns = rowCursor.flatMap { cursor -> Range<Int>? in
                guard presentation.cursorShape == .block else { return nil }
                return cursor.column..<min(cursor.column + cursor.columnWidth, columnCount)
            }

            var backgroundRuns: [RenderBackgroundRun] = []
            var overlayRuns: [RenderOverlayRun] = []
            var textRuns: [RenderTextRun] = []
            var inkClass: RenderRowInkClass = []
            var decorationRuns: [RenderDecorationRun] = []
            var openBackground: OpenBackgroundRun?
            var openOverlay: OpenOverlayRun?
            var openText: OpenTextRun?
            var openDecoration: OpenDecorationRun?
            var rowCursorStyle: ResolvedCursorStyle?

            visit { columns, semanticStyle, visitCells in
                guard columns.lowerBound < columnCount else { return }
                let resolvedStyle = resolveCellStyle(
                    semanticStyle,
                    theme: presentation.theme
                )
                visitCells { column, kind, scalars in
                    var style = resolvedStyle
                    if style.underline == .none, hovered?.contains(column) == true {
                        style.underline = .single
                        style.underlineColor = style.foreground
                    }
                    if selected?.contains(column) == true {
                        style.foreground = presentation.theme.selectionForeground
                    }

                    // Resolve the overlay against the cell's own background before a block cursor
                    // bakes its colors into the same column.
                    let state = rowHasOverlays
                        ? overlayState(at: column, selected: selected, matches: matches)
                        : nil
                    let overlayFill: RenderColor?
                    if let state {
                        if let run = openOverlay,
                           run.startColumn + run.columnCount == column,
                           run.state == state,
                           run.sourceBackground == style.background
                        {
                            overlayFill = run.fill
                            openOverlay?.extend(sourceBackground: style.background)
                        } else {
                            let resolvedFill = resolveOverlayFill(
                                state: state,
                                background: style.background,
                                theme: presentation.theme
                            )
                            overlayFill = resolvedFill
                            if let run = openOverlay,
                               run.startColumn + run.columnCount == column,
                               run.state == state,
                               run.fill == resolvedFill
                            {
                                openOverlay?.extend(sourceBackground: style.background)
                            } else {
                                if let openOverlay {
                                    overlayRuns.append(openOverlay.finished(row: row))
                                }
                                openOverlay = OpenOverlayRun(
                                    startColumn: column,
                                    state: state,
                                    fill: resolvedFill,
                                    sourceBackground: style.background
                                )
                            }
                        }
                    } else if let run = openOverlay {
                        overlayFill = nil
                        overlayRuns.append(run.finished(row: row))
                        openOverlay = nil
                    } else {
                        overlayFill = nil
                    }

                    if rowCursor?.column == column {
                        rowCursorStyle = resolveCursorStyle(
                            background: overlayFill ?? style.background,
                            theme: presentation.theme
                        )
                        cursorStyle = rowCursorStyle
                    }
                    let cursorCoversColumn = blockCursorColumns?.contains(column) == true
                    if cursorCoversColumn, let rowCursorStyle {
                        style.foreground = rowCursorStyle.foreground
                        style.background = rowCursorStyle.fill
                        style.underlineColor = rowCursorStyle.foreground
                    } else if let overlayFill {
                        style.foreground = overlayForeground(style.foreground, over: overlayFill)
                    }

                    if style.background == presentation.theme.defaultBackground {
                        if let run = openBackground {
                            backgroundRuns.append(run.finished(row: row))
                            openBackground = nil
                        }
                    } else if let run = openBackground,
                              run.startColumn + run.columnCount == column,
                              run.color == style.background
                    {
                        openBackground?.extend()
                    } else {
                        if let openBackground {
                            backgroundRuns.append(openBackground.finished(row: row))
                        }
                        openBackground = OpenBackgroundRun(
                            startColumn: column,
                            color: style.background
                        )
                    }

                    let textWidth: Int? = switch kind {
                    case .narrow: 1
                    case .wideHead: 2
                    case .padding, .wideTail, .spacerHead: nil
                    }
                    if style.hidden == false, scalars.isEmpty == false, let textWidth {
                        let cell = RenderTextCell(scalars: scalars, columnWidth: textWidth)
                        if scalars.count == 1, let scalar = scalars.first {
                            if scalar.value >= 0x20, scalar.value <= 0x7E {
                                inkClass.insert(.asciiText)
                            } else {
                                inkClass.insert(.generalText)
                            }
                        } else {
                            inkClass.insert(.band)
                        }
                        if let run = openText, run.continues(at: column, style: style) {
                            openText?.extend(with: cell)
                        } else {
                            if let openText { textRuns.append(openText.finished(row: row)) }
                            openText = OpenTextRun(startColumn: column, cell: cell, style: style)
                        }
                    }

                    let decoratable = switch kind {
                    case .narrow, .wideHead, .wideTail: true
                    case .padding, .spacerHead: false
                    }
                    let kinds = style.hidden || decoratable == false ? [] : decorationKinds(for: style)
                    if kinds.isEmpty {
                        if let run = openDecoration {
                            decorationRuns.append(run.finished(row: row))
                            openDecoration = nil
                        }
                    } else {
                        let underlined = style.underline != .none
                        let strikethroughColor = style.foreground
                        let color = underlined ? style.underlineColor : strikethroughColor
                        if let run = openDecoration,
                           run.startColumn + run.columnCount == column,
                           run.kinds == kinds,
                           run.color == color,
                           run.strikethroughColor == strikethroughColor
                        {
                            openDecoration?.extend()
                        } else {
                            if let openDecoration {
                                decorationRuns.append(openDecoration.finished(row: row))
                            }
                            openDecoration = OpenDecorationRun(
                                startColumn: column,
                                kinds: kinds,
                                color: color,
                                strikethroughColor: strikethroughColor
                            )
                        }
                    }
                }
            }

            if let openBackground { backgroundRuns.append(openBackground.finished(row: row)) }
            if let openOverlay { overlayRuns.append(openOverlay.finished(row: row)) }
            if let openText { textRuns.append(openText.finished(row: row)) }
            if let openDecoration { decorationRuns.append(openDecoration.finished(row: row)) }
            if backgroundRuns.isEmpty == false
                || overlayRuns.isEmpty == false
                || decorationRuns.isEmpty == false
            {
                inkClass.insert(.band)
            }
            rows[row] = RenderPlanRow(
                backgroundRuns: backgroundRuns,
                overlayRuns: overlayRuns,
                textRuns: textRuns,
                decorationRuns: decorationRuns,
                inkClass: inkClass
            )
        }

        let resolvedCursorStyle = cursorStyle
        let plan = RenderFramePlan(
            columns: columnCount,
            defaultBackground: presentation.theme.defaultBackground,
            rows: rows,
            cursor: cursorSpan.map {
                RenderCursor(
                    row: $0.row,
                    column: $0.column,
                    columnWidth: $0.columnWidth,
                    shape: presentation.cursorShape,
                    color: resolvedCursorStyle?.fill ?? presentation.theme.cursor
                )
            }
        )
        return PlannedFrame(
            plan: plan,
            retained: RetainedFrameRows(
                columns: columnCount,
                rows: rows,
                cursorStyle: resolvedCursorStyle
            )
        )
    }

    /// The hovered-link span for one row, resolved once instead of per column.
    private func hoveredColumns(
        for range: TerminalTextRange?,
        row: Int,
        columns: Int,
        viewportTop: Int
    ) -> Range<Int>? {
        guard let range else { return nil }
        let streamRow = viewportTop + row
        guard range.start.row...range.end.row ~= streamRow else { return nil }
        let start = streamRow == range.start.row ? range.start.column : 0
        let end = streamRow == range.end.row ? range.end.column : columns
        guard start <= end else { return nil }
        return start..<end
    }

    /// Projects one half-open stream range into a clipped viewport-row span.
    private func columns(
        for range: TerminalTextRange?,
        row: Int,
        columns: Int,
        viewportTop: Int
    ) -> Range<Int>? {
        guard let selection = range, selection.start != selection.end else { return nil }
        let streamRow = viewportTop + row
        guard selection.start.row...selection.end.row ~= streamRow else { return nil }
        let start = streamRow == selection.start.row ? selection.start.column : 0
        let end = streamRow == selection.end.row ? selection.end.column : columns
        let clampedStart = min(max(start, 0), columns)
        let clampedEnd = min(max(end, 0), columns)
        guard clampedStart < clampedEnd else { return nil }
        return clampedStart..<clampedEnd
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
