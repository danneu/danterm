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
///
/// A carried shift is folded into region-wide row damage first. This serves the
/// consumers that cannot realize a translation: the view's folded path (a stale
/// mirror, research/33 T9), the dirty-rect fallback, and the benchmark
/// topology's view-facing model. The mirror path never calls this with a
/// shift-carrying value -- `TerminalFrameBackingStore.apply` realizes the
/// translation and clips to shift-free row sets.
public func clipFramePlan(
    _ plan: RenderFramePlan,
    to damage: TerminalDamage
) -> RenderFramePlan {
    guard damage.isFull == false else { return plan }
    let rows = damage.expandingShift()
    // One span anchored at row 0 covering the plan's height is exactly the
    // whole viewport, so nothing below could be filtered out.
    if rows.damagedRowCount == plan.rows,
       rows.contains(row: 0),
       rows.maximalContiguousSpanCount == 1
    {
        return plan
    }
    return RenderFramePlan(
        columns: plan.columns,
        rows: plan.rows,
        defaultBackground: plan.defaultBackground,
        backgroundRuns: plan.backgroundRuns.filter { rows.contains(row: $0.row) },
        overlayRuns: plan.overlayRuns.filter { rows.contains(row: $0.row) },
        textRuns: plan.textRuns.filter { rows.contains(row: $0.row) },
        decorationRuns: plan.decorationRuns.filter { rows.contains(row: $0.row) },
        cursor: plan.cursor.flatMap { rows.contains(row: $0.row) ? $0 : nil }
    )
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
    let background: [[RenderBackgroundRun]]
    let overlays: [[RenderOverlayRun]]?
    let text: [[RenderTextRun]]
    let decorations: [[RenderDecorationRun]]
    let cursorStyle: ResolvedCursorStyle?

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
    var style: ResolvedCellStyle
}

/// One maximal span of a row sharing an overlay state and the fill resolved for it.
///
/// The colorize step's unit of work, and the reason overlay resolution costs what
/// the plan carries rather than what the row is wide: a fill is a function of
/// (state, background, theme) alone, so it is resolved once here and reused by
/// every layer the fragment covers.
private struct OverlayFragment {
    let columns: Range<Int>
    let state: RenderOverlayState
    let fill: RenderColor
}

/// One span of a row whose glyph colors must be pushed clear of an overlay fill.
///
/// The fragments minus the block cursor's span: the cursor bakes its own colors
/// into the cells it covers and outranks the push there, while the overlay run
/// still covers it unbroken.
private struct OverlayPush {
    let columns: Range<Int>
    let fill: RenderColor

    /// Removes the cursor's columns, keeping whatever push survives on each side.
    func excluding(_ span: Range<Int>) -> [OverlayPush] {
        guard columns.overlaps(span) else { return [self] }
        var result: [OverlayPush] = []
        if columns.lowerBound < span.lowerBound {
            result.append(OverlayPush(columns: columns.lowerBound..<span.lowerBound, fill: fill))
        }
        if span.upperBound < columns.upperBound {
            result.append(OverlayPush(columns: span.upperBound..<columns.upperBound, fill: fill))
        }
        return result
    }
}

/// Walks a row's push spans in step with an ascending column scan, so asking for
/// the fill over a column stays a bounded index bump rather than a search.
private struct OverlayPushCursor {
    private let pushes: [OverlayPush]
    private var index = 0

    init(_ pushes: [OverlayPush]) {
        self.pushes = pushes
    }

    mutating func fill(at column: Int) -> RenderColor? {
        while index < pushes.count, pushes[index].columns.upperBound <= column {
            index += 1
        }
        guard index < pushes.count, pushes[index].columns.contains(column) else { return nil }
        return pushes[index].fill
    }
}

/// Splits one row's selection and match spans into non-overlapping segments, one
/// per distinct overlay state, in ascending column order.
///
/// Replaces the per-column state classification the traversal used to do: the two
/// inputs are contiguous ranges, so their partition has at most three pieces
/// however wide the row is.
private func overlayStateSegments(
    selected: Range<Int>?,
    matched: Range<Int>?
) -> [(columns: Range<Int>, state: RenderOverlayState)] {
    switch (selected, matched) {
    case (nil, nil):
        return []
    case let (selection?, nil):
        return [(selection, .selection)]
    case let (nil, match?):
        return [(match, .activeSearchMatch)]
    case let (selection?, match?):
        let lower = max(selection.lowerBound, match.lowerBound)
        let upper = min(selection.upperBound, match.upperBound)
        guard lower < upper else {
            return selection.lowerBound < match.lowerBound
                ? [(selection, .selection), (match, .activeSearchMatch)]
                : [(match, .activeSearchMatch), (selection, .selection)]
        }
        var result: [(columns: Range<Int>, state: RenderOverlayState)] = []
        if selection.lowerBound != match.lowerBound {
            result.append((
                min(selection.lowerBound, match.lowerBound)..<lower,
                selection.lowerBound < match.lowerBound ? .selection : .activeSearchMatch
            ))
        }
        result.append((lower..<upper, .selectionAndActiveSearchMatch))
        if selection.upperBound != match.upperBound {
            result.append((
                upper..<max(selection.upperBound, match.upperBound),
                selection.upperBound > match.upperBound ? .selection : .activeSearchMatch
            ))
        }
        return result
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
        self.init(
            startColumn: startColumn,
            cells: [cell],
            foreground: style.foreground,
            bold: style.bold,
            italic: style.italic
        )
    }

    init(
        startColumn: Int,
        cells: [RenderTextCell],
        foreground: RenderColor,
        bold: Bool,
        italic: Bool
    ) {
        self.startColumn = startColumn
        self.foreground = foreground
        self.bold = bold
        self.italic = italic
        self.cells = cells
        width = cells.reduce(0) { $0 + $1.columnWidth }
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

    mutating func extend(with appended: [RenderTextCell]) {
        cells.append(contentsOf: appended)
        width += appended.reduce(0) { $0 + $1.columnWidth }
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
        let columnCount = terminal.viewportColumnCount
        let rowCount = terminal.scrollProjection.windowRows
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

        var background: [[RenderBackgroundRun]] = []
        var text: [[RenderTextRun]] = []
        var decorations: [[RenderDecorationRun]] = []
        background.reserveCapacity(rowCount)
        text.reserveCapacity(rowCount)
        decorations.reserveCapacity(rowCount)

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

        // One traversal for every replanned row rather than one per row: retained history is
        // addressed once and carried forward, which is the contract `31/I7` states and the
        // mechanism `research/31/D3` Decision 1 rule 2 requires of a frame.
        let selectionRange = terminal.selectionRange
        let searchMatchRange = terminal.activeSearchMatchRange
        var cells = inspectedCells(
            rowCount: rowCount,
            replanning: { reuseSource($0) == nil },
            columnCount: columnCount,
            selectionRange: selectionRange
        )
        let overlaysActive = selectionRange != nil || searchMatchRange != nil
        var overlays: [[RenderOverlayRun]]? =
            if overlaysActive || reusable?.overlays != nil { [] } else { nil }
        overlays?.reserveCapacity(rowCount)
        var cursorStyle: ResolvedCursorStyle?
        for row in 0..<rowCount {
            if let reusable, let source = reuseSource(row) {
                if source == row {
                    background.append(reusable.background[row])
                    overlays?.append(reusable.overlays?[row] ?? [])
                    text.append(reusable.text[row])
                    decorations.append(reusable.decorations[row])
                } else {
                    background.append(reusable.background[source].map { $0.translated(to: row) })
                    overlays?.append((reusable.overlays?[source] ?? []).map { $0.translated(to: row) })
                    text.append(reusable.text[source].map { $0.translated(to: row) })
                    decorations.append(reusable.decorations[source].map { $0.translated(to: row) })
                }
                continue
            }
            // Colorize before the cursor rewrite, so every fill resolves against the cell's own
            // background rather than the one the cursor is about to bake into its span.
            let fragments = overlayFragments(
                cells: cells[row],
                selected: columns(for: selectionRange, row: row, columns: columnCount),
                matched: columns(for: searchMatchRange, row: row, columns: columnCount)
            )
            var pushes = fragments.map { OverlayPush(columns: $0.columns, fill: $0.fill) }
            if let cursorSpan, cursorSpan.row == row,
               cells[row].indices.contains(cursorSpan.column)
            {
                let beneath = fragments.first { $0.columns.contains(cursorSpan.column) }?.fill
                    ?? cells[row][cursorSpan.column].style.background
                let resolved = resolveCursorStyle(background: beneath, theme: presentation.theme)
                cursorStyle = resolved
                if presentation.cursorShape == .block {
                    let span = cursorSpan.column
                        ..< min(cursorSpan.column + cursorSpan.columnWidth, cells[row].count)
                    for column in span {
                        cells[row][column].style.foreground = resolved.foreground
                        cells[row][column].style.background = resolved.fill
                        cells[row][column].style.underlineColor = resolved.foreground
                    }
                    pushes = pushes.flatMap { $0.excluding(span) }
                }
            }
            background.append(backgroundRuns(row: row, cells: cells[row]))
            overlays?.append(fragments.map {
                RenderOverlayRun(
                    row: row,
                    startColumn: $0.columns.lowerBound,
                    columnCount: $0.columns.count,
                    state: $0.state,
                    color: $0.fill
                )
            })
            text.append(colorized(textRuns(row: row, cells: cells[row]), row: row, pushes: pushes))
            decorations.append(colorized(
                decorationRuns(row: row, cells: cells[row]),
                row: row,
                pushes: pushes
            ))
        }

        let resolvedCursorStyle = cursorStyle ?? reusable?.cursorStyle
        let plan = RenderFramePlan(
            columns: columnCount,
            rows: rowCount,
            defaultBackground: presentation.theme.defaultBackground,
            backgroundRuns: Array(background.joined()),
            overlayRuns: overlays.map { Array($0.joined()) } ?? [],
            textRuns: Array(text.joined()),
            decorationRuns: Array(decorations.joined()),
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
                background: background,
                overlays: overlays,
                text: text,
                decorations: decorations,
                cursorStyle: resolvedCursorStyle
            )
        )
    }

    /// Inspects every row `replanning` selects, in one traversal of the terminal's viewport.
    ///
    /// One traversal rather than one per row because addressing retained history costs a
    /// display-row-to-record locate, and paying one per visible row is exactly the per-frame cost
    /// `31/I7` exists to forbid. Rows the caller reuses are stepped over rather than inspected,
    /// so a damage-clipped frame still pays only for what it redraws; they come back empty.
    /// `rowCount` rather than a row range: `result` is indexed by absolute viewport row, so
    /// only a range based at 0 was ever correct, and which rows are inspected is decided by
    /// `replanning`, not by the range.
    private func inspectedCells(
        rowCount: Int,
        replanning: (Int) -> Bool,
        columnCount: Int,
        selectionRange: TerminalTextRange?
    ) -> [[PlannedCell]] {
        // Every row-scoped lookup is hoisted deliberately, and staying hoisted is what the
        // row-scoped traversal is for. `terminal.cell(row:column:)` re-resolved the viewport row
        // on every column and `isHovered` re-read `hoveredLink` and `scrollProjection` on every
        // column; a profile put that per-cell traffic at ~20% of `planFrame` (see
        // `research/14/F10`). Making the traversal plural put three of them back inside a
        // single per-cell closure -- the kind array and the two overlay spans -- and
        // `research/31/F13` measured the result at 60% of the browsing regression.
        // `forEachViewportRow` now supplies kind with the other cell fields and hands the row out
        // first so the two remaining spans can be `let`s of this closure's own frame. Colorize
        // resolves overlay fills per row, so this pass carries only the selection foreground
        // override, which is not an overlay color.
        var result = [[PlannedCell]](repeating: [], count: rowCount)
        terminal.forEachViewportRow(rows: 0..<rowCount, where: replanning) { row, visit in
            let hovered = hoveredColumns(row: row, columns: columnCount)
            let selected = columns(for: selectionRange, row: row, columns: columnCount)
            var cells: [PlannedCell] = []
            cells.reserveCapacity(columnCount)
            visit { column, kind, scalars, semanticStyle in
                guard column < columnCount else { return }
                let cell = plannedCell(
                    row: row,
                    column: column,
                    kind: kind,
                    scalars: scalars,
                    semanticStyle: semanticStyle,
                    hovered: hovered,
                    selected: selected
                )
                cells.append(cell)
            }
            result[row] = cells
        }

        // The single padding site for columns the terminal row does not cover: they keep the
        // empty/default content the previous `terminal.cell(...) -> nil` path produced. Today
        // it is reached only by a row the traversal never handed out (one whose stream row does
        // not resolve), because `forEachViewportRow` pads every row it does visit out to the
        // column count -- but it deliberately covers a short visited row too, so the padding
        // rule stays in one place instead of being duplicated inside the traversal closure.
        for row in 0..<rowCount where replanning(row)
            && result[row].count < columnCount
        {
            let hovered = hoveredColumns(row: row, columns: columnCount)
            let selected = columns(for: selectionRange, row: row, columns: columnCount)
            while result[row].count < columnCount {
                let column = result[row].count
                let cell = plannedCell(
                    row: row,
                    column: column,
                    kind: .padding,
                    scalars: .empty,
                    semanticStyle: TerminalStyle(),
                    hovered: hovered,
                    selected: selected
                )
                result[row].append(cell)
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
        selected: Range<Int>?
    ) -> PlannedCell {
        var style = resolveCellStyle(semanticStyle, theme: presentation.theme)
        // Order is the policy: hover's underline color is the pre-selection foreground.
        if style.underline == .none, hovered?.contains(column) == true {
            style.underline = .single
            style.underlineColor = style.foreground
        }
        if selected?.contains(column) == true {
            style.foreground = presentation.theme.selectionForeground
        }
        return PlannedCell(kind: kind, scalars: scalars, style: style)
    }

    /// Partitions one row into overlay state segments, intersects them with the
    /// row's background partition, and resolves each resulting fragment's fill once.
    ///
    /// This is the whole colorize step's reason for existing. Both inputs vary at
    /// run granularity -- state comes from two contiguous column ranges, fill from
    /// the background beneath -- so the resolver runs once per distinct
    /// (state, background) span and never once per column.
    private func overlayFragments(
        cells: [PlannedCell],
        selected: Range<Int>?,
        matched: Range<Int>?
    ) -> [OverlayFragment] {
        var result: [OverlayFragment] = []

        // Coalescing here rather than in a later pass: two fragments split by a
        // background transition can still resolve to one fill, and `I4` requires
        // the overlay layer to be maximal over the colors it actually carries.
        func append(_ columns: Range<Int>, _ state: RenderOverlayState, _ background: RenderColor) {
            let fill = resolveOverlayFill(
                state: state,
                background: background,
                theme: presentation.theme
            )
            if let last = result.last,
               last.state == state,
               last.fill == fill,
               last.columns.upperBound == columns.lowerBound
            {
                result[result.count - 1] = OverlayFragment(
                    columns: last.columns.lowerBound..<columns.upperBound,
                    state: state,
                    fill: fill
                )
                return
            }
            result.append(OverlayFragment(columns: columns, state: state, fill: fill))
        }

        for segment in overlayStateSegments(selected: selected, matched: matched) {
            let lower = max(segment.columns.lowerBound, 0)
            let upper = min(segment.columns.upperBound, cells.count)
            guard lower < upper else { continue }
            var start = lower
            var background = cells[lower].style.background
            for column in (lower + 1)..<upper {
                let color = cells[column].style.background
                guard color != background else { continue }
                append(start..<column, segment.state, background)
                start = column
                background = color
            }
            append(start..<upper, segment.state, background)
        }
        return result
    }

    /// Rewrites the text runs the pushes cover, splitting a run only where the
    /// fill beneath its cells changes and re-coalescing every piece.
    ///
    /// Splitting first is what keeps the push proportional to the plan: a piece
    /// has one base foreground and one fill, so it costs one resolution however
    /// many columns it spans. Re-coalescing then restores `I4` across both kinds
    /// of seam a split leaves -- fragment boundaries, and neighbors whose distinct
    /// base foregrounds were pushed onto the same color.
    private func colorized(
        _ runs: [RenderTextRun],
        row: Int,
        pushes: [OverlayPush]
    ) -> [RenderTextRun] {
        guard pushes.isEmpty == false else { return runs }
        var result: [RenderTextRun] = []
        var open: OpenTextRun?
        var cursor = OverlayPushCursor(pushes)

        for run in runs {
            var pieceStart = run.startColumn
            var pieceCells: [RenderTextCell] = []
            var pieceFill: RenderColor?
            var column = run.startColumn

            func flushPiece() {
                guard pieceCells.isEmpty == false else { return }
                let foreground = pieceFill.map { overlayForeground(run.foreground, over: $0) }
                    ?? run.foreground
                if open?.continues(
                    at: pieceStart,
                    foreground: foreground,
                    bold: run.bold,
                    italic: run.italic
                ) == true {
                    open?.extend(with: pieceCells)
                } else {
                    if let open { result.append(open.finished(row: row)) }
                    open = OpenTextRun(
                        startColumn: pieceStart,
                        cells: pieceCells,
                        foreground: foreground,
                        bold: run.bold,
                        italic: run.italic
                    )
                }
                pieceCells.removeAll(keepingCapacity: true)
            }

            // Attribution follows the cell's start column, so a wide glyph takes
            // the fill over its head and never splits between head and tail.
            for cell in run.cells {
                let fill = cursor.fill(at: column)
                if pieceCells.isEmpty == false, fill != pieceFill {
                    flushPiece()
                    pieceStart = column
                }
                pieceFill = fill
                pieceCells.append(cell)
                column += cell.columnWidth
            }
            flushPiece()
        }
        if let open { result.append(open.finished(row: row)) }
        return result
    }

    /// Rewrites the decoration runs the pushes cover, per column and per piece.
    private func colorized(
        _ runs: [RenderDecorationRun],
        row: Int,
        pushes: [OverlayPush]
    ) -> [RenderDecorationRun] {
        guard pushes.isEmpty == false else { return runs }
        var result: [RenderDecorationRun] = []
        var current: RenderDecorationRun?
        var cursor = OverlayPushCursor(pushes)

        func append(_ piece: RenderDecorationRun) {
            if let run = current,
               piece.startColumn == run.startColumn + run.columnCount,
               piece.kinds == run.kinds,
               piece.color == run.color,
               piece.strikethroughColor == run.strikethroughColor
            {
                current = RenderDecorationRun(
                    row: row,
                    startColumn: run.startColumn,
                    columnCount: run.columnCount + piece.columnCount,
                    kinds: run.kinds,
                    color: run.color,
                    strikethroughColor: run.strikethroughColor
                )
                return
            }
            if let current { result.append(current) }
            current = piece
        }

        for run in runs {
            let end = run.startColumn + run.columnCount
            var pieceStart = run.startColumn
            var pieceFill = cursor.fill(at: run.startColumn)
            for column in (run.startColumn + 1)..<end {
                let fill = cursor.fill(at: column)
                guard fill != pieceFill else { continue }
                append(pushed(run, columns: pieceStart..<column, over: pieceFill))
                pieceStart = column
                pieceFill = fill
            }
            append(pushed(run, columns: pieceStart..<end, over: pieceFill))
        }
        if let current { result.append(current) }
        return result
    }

    /// Recolors one slice of a decoration run for the fill beneath it.
    ///
    /// Only the strikethrough color always moves: `color` is the underline's own
    /// color whenever an underline is drawn, and that never came from the pushed
    /// foreground. The two agree exactly when there is no underline, so a piece
    /// costs one resolution either way.
    private func pushed(
        _ run: RenderDecorationRun,
        columns: Range<Int>,
        over fill: RenderColor?
    ) -> RenderDecorationRun {
        guard let fill else {
            return RenderDecorationRun(
                row: run.row,
                startColumn: columns.lowerBound,
                columnCount: columns.count,
                kinds: run.kinds,
                color: run.color,
                strikethroughColor: run.strikethroughColor
            )
        }
        let strikethroughColor = overlayForeground(run.strikethroughColor, over: fill)
        let underlined = run.kinds.contains { $0 != .strikethrough }
        return RenderDecorationRun(
            row: run.row,
            startColumn: columns.lowerBound,
            columnCount: columns.count,
            kinds: run.kinds,
            color: underlined ? run.color : strikethroughColor,
            strikethroughColor: strikethroughColor
        )
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

    /// Projects one half-open stream range into a clipped viewport-row span.
    private func columns(
        for range: TerminalTextRange?,
        row: Int,
        columns: Int
    ) -> Range<Int>? {
        guard let selection = range, selection.start != selection.end else { return nil }
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
