// The single owner of how a display row is projected against the cell that follows it.
//
// A display row stream is retained history followed by a grid. It is a plain concatenation
// everywhere but one place: the last retained row. History stores that row without the
// `.spacerHead` a wide glyph at the fold would put at its margin -- where the spacer sits is a
// function of the width, which `31/I1` forbids storing -- so the reader re-derives the margin
// from the grid's first cell, and when that cell is not a wide head it shows the blank the
// store remembered instead (`openTailPendingMarginCell`). While the alternate screen is active
// the *active* stream severs that seam: the last retained row cannot soft-wrap into rows that
// belong to another screen. The *primary* stream (history followed by the primary screen)
// keeps the seam whichever screen is showing.
//
// Everything that reads a row across that seam -- row copies, single margin cells, and the
// kinds-only geometry read -- asks this file. Nothing outside it names
// `openTailPendingMarginCell` or `projectedMarginCell`; `scripts/display-row-projection-lint.sh`
// enforces that. The projector never reads the terminal's active-screen flag: a factory on
// `Terminal` (`activeDisplayRows`, `primaryDisplayRows`) picks the stream, and the projector
// only knows which grid follows history and whether the seam is preserved or severed.
//
// Two stream-row conventions coexist above this file (`ProjectionRows` indexes an alternate
// row at `historyRows + r`, the viewport path at `r`). Both agree on the history index, and
// only history rows have a seam, so callers map their own convention and hand this file a
// history index or a grid index -- never a stream row.

import DequeModule

extension Terminal {
    /// Projects any display row of one stream against its follower. A value, and a cheap one:
    /// it keeps the two seam facts it reads from the store, the grid deque (copy-on-write,
    /// never mutated), a width and a flag -- so a reader may build one per query.
    struct DisplayRowProjector {
        /// Whether the history/grid seam carries a wrap across it.
        enum Seam {
            /// The last retained row may soft-wrap into the grid's first row.
            case preserved
            /// The last retained row ends hard and shows no derived spacer.
            case severed
        }

        /// What one row needs from the rest of its stream to project itself.
        ///
        /// Wave 7 (reflow) extends this with fill style, content end and continuation facts,
        /// which is why it is a per-row value rather than a set of arguments.
        struct RowFacts {
            /// The first stored cell of the row that follows, when one does.
            let follower: GridCell?
            /// Whether the row was stored one column short of a spacer the seam supplies.
            let fillsMissingWrapSpacer: Bool
            /// The remembered blank shown at the seam when the follower is not a wide head.
            let missingWrapMargin: GridCell?
            /// Whether the row's soft wrap is cut by the alternate screen.
            let isSevered: Bool

            /// A row with nothing special about its margin: interior history rows.
            static let plain = RowFacts(
                follower: nil,
                fillsMissingWrapSpacer: false,
                missingWrapMargin: nil,
                isSevered: false
            )
        }

        private let grid: Deque<GridRow>
        private let columns: Int
        private let seam: Seam
        /// Read once at construction: the store hands the pending margin across a type
        /// boundary, and every row of one projection must see the same one.
        private let pendingMargin: GridCell?

        /// The number of retained display rows the history index runs over.
        let historyRowCount: Int

        init(history: LogicalLineStore, grid: Deque<GridRow>, columns: Int, seam: Seam) {
            self.grid = grid
            self.columns = columns
            self.seam = seam
            historyRowCount = history.grandDisplayRowTotal
            pendingMargin = history.openTailPendingMarginCell
        }

        /// Projects a bare grid whose rows have followers but no retained-history seam.
        init(grid: Deque<GridRow>, columns: Int) {
            self.grid = grid
            self.columns = columns
            seam = .severed
            historyRowCount = 0
            pendingMargin = nil
        }

        /// The facts for retained display row `index`. Only the last one has a seam.
        func facts(forHistoryRow index: Int) -> RowFacts {
            guard index == historyRowCount - 1 else { return .plain }
            switch seam {
            case .severed:
                return RowFacts(
                    follower: nil,
                    fillsMissingWrapSpacer: false,
                    missingWrapMargin: nil,
                    isSevered: true
                )
            case .preserved:
                return RowFacts(
                    follower: grid.first?.cells.first,
                    fillsMissingWrapSpacer: pendingMargin != nil,
                    missingWrapMargin: pendingMargin,
                    isSevered: false
                )
            }
        }

        /// The facts for grid row `index`: its follower is the next grid row, and nothing else.
        func facts(forGridRow index: Int) -> RowFacts {
            RowFacts(
                follower: grid.indices.contains(index + 1) ? grid[index + 1].cells.first : nil,
                fillsMissingWrapSpacer: false,
                missingWrapMargin: nil,
                isSevered: false
            )
        }

        /// Every grid row projected against its neighbour, in order.
        func projectedGridRows() -> [GridRow] {
            grid.indices.map { index in project(grid[index], facts(forGridRow: index)) }
        }

        /// The row-scoped read: a copy of `row` as the stream carries it.
        func project(_ row: GridRow, _ facts: RowFacts) -> GridRow {
            if facts.isSevered {
                var projected = row.withGatedContinuation
                projected.isSoftWrapped = false
                return projected
            }
            return row.projected(
                columns: columns,
                follower: facts.follower,
                fillsMissingWrapSpacer: facts.fillsMissingWrapSpacer,
                missingWrapMargin: facts.missingWrapMargin
            )
        }

        /// The cell-scoped read: `row`'s margin cell as the stream carries it, without copying
        /// the row. Columns before the margin are the row's own.
        func margin(of row: GridRow, _ facts: RowFacts) -> GridCell {
            let marginColumn = columns - 1
            return margin(
                stored: row.cells.indices.contains(marginColumn) ? row.cells[marginColumn] : nil,
                derivesOwnSpacer: Self.derivesOwnSpacer(row),
                facts
            )
        }

        /// The kinds-only read: the projected margin given only what was stored there, for a
        /// reader that streams a row's cells and never builds a `GridRow`. `stored` is nil when
        /// the row stops short of the margin.
        func margin(stored: GridCell?, derivesOwnSpacer: Bool = false, _ facts: RowFacts) -> GridCell {
            guard facts.isSevered == false else { return stored ?? GridCell() }
            return Self.projectedMarginCell(
                stored: stored,
                follower: facts.follower,
                fillsMissingWrapSpacer: facts.fillsMissingWrapSpacer || derivesOwnSpacer,
                missingWrapMargin: facts.missingWrapMargin
            )
        }

        /// The cell the seam adds to a row stored one column short, or nil when the row is
        /// whole as stored. The frame walk reads this once per traversal and splices it in.
        func missingMargin(_ facts: RowFacts) -> GridCell? {
            guard facts.fillsMissingWrapSpacer else { return nil }
            return margin(stored: nil, facts)
        }

        /// A live row that wrapped on a wide glyph re-derives its spacer from its follower on
        /// every read, so no consumer can cache the stored spacer's fields. The frame walk asks
        /// this to know whether a live row's margin needs the projector at all.
        static func derivesOwnSpacer(_ row: GridRow) -> Bool {
            row.logicallyContinues && row.marginProvenance == .wideWrap
        }

        /// The `.spacerHead` a row's margin shows when a wide head follows it.
        ///
        /// A stored spacer is re-derived so its style, hyperlink and identity follow the head's
        /// current values; a missing one (the open tail's final display row) is derived from
        /// scratch, and falls back to the remembered blank when the follower is not a wide head.
        static func projectedMarginCell(
            stored: GridCell?,
            follower: GridCell?,
            fillsMissingWrapSpacer: Bool,
            missingWrapMargin: GridCell?
        ) -> GridCell {
            if let stored, stored.kind != .spacerHead, fillsMissingWrapSpacer == false {
                return stored
            }
            guard stored?.kind == .spacerHead || fillsMissingWrapSpacer else {
                return GridCell()
            }
            guard let follower, follower.kind == .wideHead else {
                return stored ?? missingWrapMargin ?? GridCell()
            }
            return GridCell(
                kind: .spacerHead,
                styleId: follower.styleId,
                hyperlinkId: follower.hyperlinkId,
                contentIdentity: follower.contentIdentity
            )
        }
    }
}

extension Terminal.GridRow {
    /// Projects this row against the cell that follows it in a stream. Lives with the
    /// projector because it is the projector's row-scoped read spelled as a method, for the
    /// callers that already hold their facts in hand.
    func projected(
        columns: Int,
        follower: Terminal.GridCell?,
        fillsMissingWrapSpacer: Bool = false,
        missingWrapMargin: Terminal.GridCell? = nil
    ) -> Terminal.GridRow {
        var row = withGatedContinuation
        guard columns > 0 else { return row }
        let margin = columns - 1
        let storedMargin = row.cells.indices.contains(margin) ? row.cells[margin] : nil
        let projectedMargin = Terminal.DisplayRowProjector.projectedMarginCell(
            stored: storedMargin,
            follower: follower,
            fillsMissingWrapSpacer: fillsMissingWrapSpacer
                || Terminal.DisplayRowProjector.derivesOwnSpacer(row),
            missingWrapMargin: missingWrapMargin
        )
        if row.cells.indices.contains(margin), projectedMargin != storedMargin {
            row.cells[margin] = projectedMargin
        } else if fillsMissingWrapSpacer, row.cells.count == margin {
            row.cells.append(projectedMargin)
        }
        return row
    }
}
