// Pure viewport traversal, cursor policy, and canonical run construction for
// complete terminal frames. Platform drawing and cross-frame state stay outside.
import TerminalCore
import TerminalSpriteGeometry

/// Produces all grid-space drawing work from the terminal's public viewport
/// inspection surface and explicit presentation inputs alone.
public func planFrame(
    for terminal: borrowing Terminal,
    presentation: RenderPresentation
) -> RenderFramePlan {
    let searchReadout = terminal.searchReadout
    return FramePlanner(presentation: presentation)
        .plan(for: terminal, searchReadout: searchReadout, reusing: nil, damage: .full)
        .plan
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

/// One row's search-match spans, read left to right by one advancing cursor.
///
/// The spans are ascending by start column, so a span whose end the cursor has passed
/// can cover no later column and is dropped for good. Spans may overlap; the earliest
/// span that covers a column supplies its state, which is the order a full scan of the
/// list would have found it in.
private struct RowMatchCursor {
    private let matches: [(columns: Range<Int>, isActive: Bool)]
    private var index = 0

    init(matches: [(columns: Range<Int>, isActive: Bool)]) {
        self.matches = matches
    }

    var isEmpty: Bool { matches.isEmpty }

    /// Resolves the overlay state at `column`, which must not precede the last column asked.
    mutating func overlayState(at column: Int, selected: Range<Int>?) -> RenderOverlayState? {
        let isSelected = selected?.contains(column) == true
        while index < matches.count, matches[index].columns.upperBound <= column {
            index += 1
        }
        guard index < matches.count, matches[index].columns.contains(column) else {
            return isSelected ? .selection : nil
        }
        return switch (isSelected, matches[index].isActive) {
        case (true, true): .selectionAndActiveSearchMatch
        case (true, false): .selectionAndSearchMatch
        case (false, true): .activeSearchMatch
        case (false, false): .searchMatch
        }
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

    func finished() -> RenderBackgroundRun {
        RenderBackgroundRun(
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

    func finished() -> RenderOverlayRun {
        RenderOverlayRun(
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

    func finished() -> RenderTextRun {
        RenderTextRun(
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

    func finished() -> RenderDecorationRun {
        RenderDecorationRun(
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
        searchReadout: TerminalSearchReadout?,
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
        let activeSearchMatchRange = searchReadout?.activeMatch
        let viewportTop = scrollProjection.topRow
        let searchMatchRanges = searchReadout?.viewportMatches ?? []
        var cursorStyle = reusable?.cursorStyle
        var nextMatch = 0

        // Copy reusable rows before the traversal so the traversal can write each replanned row
        // directly into its retained destination. The destination array index owns the row, so
        // shifted reuse is the same array-element copy as identity reuse.
        for row in 0..<rowCount {
            guard let reusable, let source = reuseSource(row) else { continue }
            rows[row] = reusable.rows[source]
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
            let hovered = columns(
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
            let streamRow = viewportTop + row
            // Rows are visited in ascending order and `searchMatchRanges` is ascending by
            // start, so a match that ended above this row can touch no later row either.
            while nextMatch < searchMatchRanges.count,
                  searchMatchRanges[nextMatch].end.row < streamRow
            {
                nextMatch += 1
            }
            var rowMatches: [(columns: Range<Int>, isActive: Bool)] = []
            var candidate = nextMatch
            while candidate < searchMatchRanges.count,
                  searchMatchRanges[candidate].start.row <= streamRow
            {
                let match = searchMatchRanges[candidate]
                if let columns = columns(
                    for: match,
                    row: row,
                    columns: columnCount,
                    viewportTop: viewportTop
                ) {
                    rowMatches.append((columns, match == activeSearchMatchRange))
                }
                candidate += 1
            }
            var matches = RowMatchCursor(matches: rowMatches)
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
                        ? matches.overlayState(at: column, selected: selected)
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
                                    overlayRuns.append(openOverlay.finished())
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
                        overlayRuns.append(run.finished())
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
                            backgroundRuns.append(run.finished())
                            openBackground = nil
                        }
                    } else if let run = openBackground,
                              run.startColumn + run.columnCount == column,
                              run.color == style.background
                    {
                        openBackground?.extend()
                    } else {
                        if let openBackground {
                            backgroundRuns.append(openBackground.finished())
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
                            } else if let reach = spriteDecode(for: scalar)?.inkReach {
                                // The executor routes this scalar away from the
                                // font, so its family's declared reach -- not the
                                // unmeasured cmap -- prices the row.
                                switch reach {
                                case .band: inkClass.insert(.band)
                                case .beyondBand: inkClass.insert(.generalText)
                                }
                            } else {
                                inkClass.insert(.generalText)
                            }
                        } else {
                            inkClass.insert(.band)
                        }
                        if let run = openText, run.continues(at: column, style: style) {
                            openText?.extend(with: cell)
                        } else {
                            if let openText { textRuns.append(openText.finished()) }
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
                            decorationRuns.append(run.finished())
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
                                decorationRuns.append(openDecoration.finished())
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

            if let openBackground { backgroundRuns.append(openBackground.finished()) }
            if let openOverlay { overlayRuns.append(openOverlay.finished()) }
            if let openText { textRuns.append(openText.finished()) }
            if let openDecoration { decorationRuns.append(openDecoration.finished()) }
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

    /// Projects one half-open stream range into a clipped viewport-row span. The one clip
    /// rule for selection, hover, and search matches alike.
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
