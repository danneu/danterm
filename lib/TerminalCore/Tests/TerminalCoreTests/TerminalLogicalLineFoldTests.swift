// Fidelity proof for doc 31's read-time fold: the arena, read at a width, must emit the same
// display rows today's per-display-row store holds.
//
// What belongs here: comparisons between the logical-line store's fold and
// `PackedRetainedRow`'s own walks over the rows a real `Terminal` retained, plus the spacer
// arithmetic (`31/F4` Observation 1) the fold re-derives rather than stores. What does not:
// the arena's mutating operations and its charge, which are `TerminalLogicalLineStoreTests`.
//
// The comparison is deliberately content-level -- scalars, kinds, style ids, hyperlink ids,
// content identity, soft-wrap and semantic prompt, read through `cell(at:)` over the pane's
// full width -- because `31/DD15` drops the one-cell canonical floor, so the two stores
// legitimately disagree about how many trailing default cells a blank row *stores* while
// agreeing about every column a reader can observe.
//
// **Which of the store's two walks is compared against what, since `31/DD25`'s amendment.** The
// **painted** walk is the one held to today's stored row column for column at the admitting
// width -- including the background-erase paint past the content end, which today's store holds
// as cells and this store holds as a per-record fill style. The **content** walk is held to
// today's row up to the content end only, and past it the two intentionally differ: the content
// walk emits nothing there, because a fill is paint rather than text and copy must not pick it
// up. That divergence is this suite's subject rather than its blind spot -- `assertSameRow`
// asserts both halves on every row, so neither can drift unnoticed.

import Testing

@testable import TerminalCore

@Suite("Logical-line read-time fold")
struct TerminalLogicalLineFoldTests {
    // MARK: - Cross-store fidelity

    @Test("Folding the arena reproduces the display rows today's store holds")
    func foldReproducesTodaysRetainedRows() throws {
        // Intent: feeding a real terminal's retained display rows into the logical-line store
        //   and folding them back at the same width returns every column unchanged.
        // Why it exists: `31/I6` is the invariant the whole design rests on -- wrapping at
        //   read must emit the same cells, kinds, styles, spacer placement, continuation
        //   stamping and soft-wrap marking today's stored rows do -- and `31/F5`'s
        //   simplification argument is only collectable if it does.
        for content in RetainedContent.allCases {
            var terminal = try #require(Terminal(columns: content.columns, rows: 6))
            terminal.feed(Array(content.stimulus.utf8))

            let retained = (0..<terminal.scrollbackRowCount).map {
                terminal.retainedRowForTesting(at: $0)!
            }
            try #require(retained.count > 4, "\(content) retained too little to compare")

            var store = Terminal.LogicalLineStore(
                capacityBytes: 1 << 20,
                width: content.columns
            )
            for row in retained {
                store.admit(row)
            }

            #expect(
                store.grandDisplayRowTotal == retained.count,
                "\(content): folded \(store.grandDisplayRowTotal) rows against \(retained.count)"
            )
            for index in 0..<comparableRowCount(store, retained.count) {
                let painted = try #require(store.paintedDisplayRow(at: index))
                let contentOnly = try #require(store.displayRow(at: index))
                assertSameRow(
                    painted: painted,
                    content: contentOnly,
                    reference: retained[index],
                    width: content.columns,
                    label: "\(content) row \(index)"
                )
            }
            try assertOpenTailSeam(store, retained, width: content.columns, label: "\(content)")
        }
    }

    @Test("The fold reproduces the retained rows at the widths the pane was never at")
    func foldTracksAWidthChangeWithoutStoredWidth() throws {
        // Intent: after a width change the store's fold matches what today's engine holds for
        //   the same content at that width, having rewritten nothing in the arena.
        // Why it exists: this is `31/I1` and `31/I6` together -- a record's bytes are a
        //   function of content alone, so the *only* thing a width change may change is what
        //   the fold derives. A terminal reflowed to the new width is the independent oracle.
        for content in RetainedContent.allCases {
            for newWidth in [7, 13, 40] {
                var reference = try #require(Terminal(columns: content.columns, rows: 6))
                reference.feed(Array(content.stimulus.utf8))

                var store = Terminal.LogicalLineStore(
                    capacityBytes: 1 << 20,
                    width: content.columns
                )
                for index in 0..<reference.scrollbackRowCount {
                    store.admit(reference.retainedRowForTesting(at: index)!)
                }

                reference.resize(columns: newWidth, rows: 6)
                _ = store.setWidth(newWidth)

                // The live screen holds the tail of the stream on both sides, so compare the
                // history the reference kept, oldest first, against the store's own head.
                let referenceRows = (0..<reference.scrollbackRowCount).map {
                    reference.retainedRowForTesting(at: $0)!
                }
                let shared = min(
                    referenceRows.count,
                    comparableRowCount(store, store.grandDisplayRowTotal)
                )
                try #require(shared > 0)
                for offset in 0..<shared {
                    let folded = try #require(store.displayRow(at: offset))
                    // The **content** walk, and only it: today's reflow measures a hard-ended
                    // row to its content end, so a reflowed reference row has already lost any
                    // background-erase tail it was displaying. The store's painted walk keeps
                    // that paint, which is a divergence in the store's favour and is pinned by
                    // `widthChangeRepaintsTheTrailingFillTodaysReflowDrops` rather than hidden
                    // by comparing the weaker walk here.
                    assertSameContentRow(
                        folded,
                        referenceRows[offset],
                        width: newWidth,
                        label: "\(content) at width \(newWidth), row \(offset)"
                    )
                }
            }
        }
    }

    // MARK: - `31/F4` Observation 1: the spacer arithmetic

    @Test("A line of wide clusters folds to more rows than ceil(cells / width) predicts")
    func wideClustersFoldPastTheNaiveCeiling() throws {
        // Intent: three 2-cell clusters at width 3 occupy three display rows, not the two
        //   `ceil(6 / 3)` predicts.
        // Why it exists: `31/F4` Observation 1 is the one arithmetic correction the whole
        //   design took -- `ceil((cells + spacers) / width)`, with `spacers` a function of
        //   *where* the wide cells sit -- and the real engine is the oracle it was measured
        //   against, so this test re-derives it rather than restating a table.
        for (clusters, narrowWidth) in [(3, 3), (5, 3), (2, 4), (4, 5)] {
            var terminal = try #require(Terminal(columns: narrowWidth, rows: 40))
            terminal.feed(Array(String(repeating: "\u{754C}", count: clusters).utf8))
            let engineRows = try #require(terminal.geometry.cursor).row + 1

            // Admit the whole line as one display row at a width that holds it, then fold it at
            // the narrow width: the record's bytes never change, only the derivation.
            var store = Terminal.LogicalLineStore(
                capacityBytes: 1 << 16,
                width: clusters * 2
            )
            var cells: [Terminal.GridCell] = []
            for _ in 0..<clusters {
                cells.append(
                    Terminal.GridCell(
                        scalars: TerminalScalars(Unicode.Scalar(0x754C)!),
                        kind: .wideHead
                    )
                )
                cells.append(Terminal.GridCell(scalars: .empty, kind: .wideTail))
            }
            store.admit(Terminal.GridRow(cells: cells))
            #expect(store.grandDisplayRowTotal == 1)

            _ = store.setWidth(narrowWidth)

            #expect(
                store.grandDisplayRowTotal == engineRows,
                "\(clusters) clusters at width \(narrowWidth)"
            )
            #expect(store.independentDisplayRowRecount() == engineRows)
            #expect((cells.count + narrowWidth - 1) / narrowWidth <= engineRows)
        }
    }

    @Test("The re-derived spacer carries the wide head's style, hyperlink and identity")
    func rederivedSpacerInheritsTheWideHeadsAttributes() {
        // Intent: the `.spacerHead` the fold synthesizes at a wrap boundary carries the same
        //   style id, hyperlink id and content identity `Terminal.pack` gives it.
        // Why it exists: `31/F4` case 1 refuses to *store* the spacer, so every attribute the
        //   renderer and `activationIdentity` read off it has to come back out of the wide
        //   head it precedes -- which is what `pack(line:columns:)` does today.
        // Admitted as one display row at width 4, then folded at 3, so the boundary the spacer
        // fills is one the fold discovers rather than one admission wrote.
        var store = Terminal.LogicalLineStore(capacityBytes: 1 << 16, width: 4)
        var wide = Terminal.GridCell(
            scalars: TerminalScalars(Unicode.Scalar(0x754C)!),
            kind: .wideHead,
            styleId: 9
        )
        wide.hyperlinkId = 4
        wide.contentIdentity = 77
        let tail = Terminal.GridCell(scalars: .empty, kind: .wideTail, styleId: 9)
        store.admit(
            Terminal.GridRow(cells: [
                Terminal.GridCell(scalars: TerminalScalars("a" as Unicode.Scalar), kind: .narrow),
                Terminal.GridCell(scalars: TerminalScalars("b" as Unicode.Scalar), kind: .narrow),
                wide,
                tail,
            ])
        )
        _ = store.setWidth(3)

        #expect(store.grandDisplayRowTotal == 2)
        let first = store.displayRow(at: 0)!
        #expect(first.cell(at: 2).kind == .spacerHead)
        #expect(first.cell(at: 2).styleId == 9)
        #expect(first.cell(at: 2).hyperlinkId == 4)
        #expect(first.cell(at: 2).contentIdentity == 77)
        #expect(first.isSoftWrapped)
        #expect(store.displayRow(at: 1)!.cell(at: 0).kind == .wideHead)
    }

    @Test("A dropped spacer is re-derived rather than stored")
    func spacerIsNeverStored() {
        // Intent: admitting a display row whose last column is a `.spacerHead` stores the
        //   content cells only, and the spacer reappears at read.
        // Why it exists: `31/I1` -- a spacer's *position* is a function of the width, so
        //   storing one would be width-dependent data in history, which is `31/D1`'s no-go
        //   trigger.
        var store = Terminal.LogicalLineStore(capacityBytes: 1 << 16, width: 3)
        var wrapped = Terminal.GridRow(cells: [
            Terminal.GridCell(scalars: TerminalScalars("a" as Unicode.Scalar), kind: .narrow),
            Terminal.GridCell(scalars: TerminalScalars("b" as Unicode.Scalar), kind: .narrow),
            Terminal.GridCell(scalars: .empty, kind: .spacerHead),
        ])
        wrapped.isSoftWrapped = true
        store.admit(wrapped)
        #expect(store.recordSummary(at: 0)!.cellCount == 2)

        var next = Terminal.GridRow(cells: [
            Terminal.GridCell(scalars: TerminalScalars(Unicode.Scalar(0x754C)!), kind: .wideHead),
            Terminal.GridCell(scalars: .empty, kind: .wideTail),
            Terminal.GridCell(),
        ])
        next.isSoftWrapped = false
        store.admit(next)

        #expect(store.recordSummary(at: 0)!.cellCount == 4)
        #expect(store.grandDisplayRowTotal == 2)
        #expect(store.displayRow(at: 0)!.cell(at: 2).kind == .spacerHead)
    }

    // MARK: - `31/DD25` as amended: the trailing background-erase fill

    @Test("A hard-ended row's painted tail becomes a fill style, and repaints at every width")
    func hardEndedRowStoresItsBackgroundEraseTailAsAFillStyle() throws {
        // Intent: admitting a hard-ended row whose columns past its content carry a
        //   background-erase style stores the content cells plus one fill style, and the
        //   painted walk repaints from the content's end to the right margin at the admitting
        //   width, at a narrower one and at a wider one.
        // Why it exists: `31/DD25` originally measured such a row to its content end and
        //   dropped the paint, because storing it as *cells* would wrap a painted tail into
        //   whole blank display rows on a narrow. The amended design keeps both properties at
        //   once -- the paint is width-relative, so it is an attribute rather than cells -- and
        //   this is the test that says the row count stays put while the paint survives.
        var store = Terminal.LogicalLineStore(capacityBytes: 1 << 16, width: 20)
        var cells = (0..<3).map { column in
            Terminal.GridCell(
                scalars: TerminalScalars(Unicode.Scalar(UInt32(97 + column))!),
                kind: .narrow,
                styleId: 5
            )
        }
        cells.append(
            contentsOf: (0..<17).map { _ in
                Terminal.GridCell(scalars: .empty, kind: .padding, styleId: 5)
            }
        )
        store.admit(Terminal.GridRow(cells: cells))

        let summary = try #require(store.recordSummary(at: 0))
        #expect(summary.cellCount == 3)
        #expect(summary.trailingFillStyle == 5)
        #expect(store.grandDisplayRowTotal == 1)

        // At the admitting width the painted row is today's stored row, cell for cell.
        let painted = try #require(store.paintedDisplayRow(at: 0))
        for column in 0..<20 {
            #expect(painted.cell(at: column) == cells[column], "admitting width, column \(column)")
        }

        // Narrower: the content still folds to one row -- the fill added no cells -- and the
        // paint follows the content's end rather than wrapping into rows of its own.
        _ = store.setWidth(4)
        #expect(store.grandDisplayRowTotal == 1)
        #expect(store.independentDisplayRowRecount() == 1)
        let narrow = try #require(store.paintedDisplayRow(at: 0))
        #expect(narrow.cells.count == 4)
        #expect(narrow.cell(at: 3).styleId == 5)
        #expect(narrow.cell(at: 3).kind == .padding)

        // Wider: the paint extends to the new margin, which is what the same bytes would have
        // painted on a pane this wide.
        _ = store.setWidth(30)
        let wide = try #require(store.paintedDisplayRow(at: 0))
        #expect(wide.cells.count == 30)
        #expect(wide.cell(at: 29).styleId == 5)
    }

    @Test("A line with a fill and no content paints its whole row at every width")
    func zeroContentFillPaintsAFullRow() throws {
        // Intent: a hard-ended row erased end to end under a non-default background -- no
        //   content at all -- reads back as a full styled display row however wide the pane is.
        // Why it exists: this is the ED-with-background case, the one a per-cell encoding gets
        //   right only by storing a whole row of blanks. As a fill it is one style id on a
        //   zero-cell record, and `31/DD15`'s one-display-row floor is what keeps the row
        //   itself from folding away.
        var store = Terminal.LogicalLineStore(capacityBytes: 1 << 16, width: 12)
        store.admit(
            Terminal.GridRow(
                cells: (0..<12).map { _ in
                    Terminal.GridCell(scalars: .empty, kind: .padding, styleId: 3)
                }
            )
        )

        let summary = try #require(store.recordSummary(at: 0))
        #expect(summary.cellCount == 0)
        #expect(summary.trailingFillStyle == 3)

        for width in [12, 5, 40] {
            _ = store.setWidth(width)
            #expect(store.grandDisplayRowTotal == 1, "width \(width)")
            let painted = try #require(store.paintedDisplayRow(at: 0))
            #expect(painted.cells.count == width, "width \(width)")
            for column in 0..<width {
                #expect(painted.cell(at: column).styleId == 3, "width \(width), column \(column)")
            }
        }
    }

    @Test("Styled blanks between content stay cells and re-wrap with the line")
    func interiorStyledBlanksStayCellsRatherThanBecomingAFill() throws {
        // Intent: a styled blank with content on both sides is stored as a cell, keeps its
        //   column relative to the content when the line re-wraps, and is not folded into the
        //   record's trailing fill.
        // Why it exists: the amended `31/DD25` draws exactly one line -- a *trailing*
        //   to-edge paint is width-relative and becomes an attribute, while an interior erase
        //   is positionally real content. Without this test the fill rule could quietly swallow
        //   any styled blank and lose a column a program deliberately painted mid-line.
        var store = Terminal.LogicalLineStore(capacityBytes: 1 << 16, width: 10)
        var cells: [Terminal.GridCell] = [
            Terminal.GridCell(scalars: TerminalScalars("a" as Unicode.Scalar), kind: .narrow),
            Terminal.GridCell(scalars: .empty, kind: .padding, styleId: 6),
            Terminal.GridCell(scalars: .empty, kind: .padding, styleId: 6),
            Terminal.GridCell(scalars: TerminalScalars("b" as Unicode.Scalar), kind: .narrow),
        ]
        cells.append(
            contentsOf: (0..<6).map { _ in
                Terminal.GridCell(scalars: .empty, kind: .padding, styleId: 7)
            }
        )
        store.admit(Terminal.GridRow(cells: cells))

        let summary = try #require(store.recordSummary(at: 0))
        #expect(summary.cellCount == 4)
        #expect(summary.trailingFillStyle == 7)

        // Re-wrapped to two columns: the interior blanks travel with the content, so they land
        // in the rows their offsets put them in, and only the trailing paint tracks the margin.
        _ = store.setWidth(2)
        #expect(store.grandDisplayRowTotal == 2)
        let first = try #require(store.paintedDisplayRow(at: 0))
        let second = try #require(store.paintedDisplayRow(at: 1))
        #expect(first.cell(at: 1).styleId == 6)
        #expect(second.cell(at: 0).styleId == 6)
        #expect(second.cell(at: 1).scalars.first == "b")
        // The content filled the last row exactly, so there is no tail gap left to paint.
        #expect(second.cells.count == 2)
    }

    @Test("The content walk excludes the trailing fill that the painted walk emits")
    func copyWalkNeverSeesTheTrailingFill() throws {
        // Intent: the cells a copy reads -- the content walk and the record's cells -- stop at
        //   the line's content, while the painted walk carries the erase paint to the margin.
        // Why it exists: the fill is paint, not text. If it reached `recordCells` or
        //   `displayRow`, selecting a background-erased line would copy trailing blanks the
        //   program never printed, which is a user-visible regression no width would undo.
        var store = Terminal.LogicalLineStore(capacityBytes: 1 << 16, width: 8)
        var cells = [
            Terminal.GridCell(scalars: TerminalScalars("h" as Unicode.Scalar), kind: .narrow),
            Terminal.GridCell(scalars: TerminalScalars("i" as Unicode.Scalar), kind: .narrow),
        ]
        cells.append(
            contentsOf: (0..<6).map { _ in
                Terminal.GridCell(scalars: .empty, kind: .padding, styleId: 4)
            }
        )
        store.admit(Terminal.GridRow(cells: cells))

        #expect(try #require(store.recordCells(at: 0)).count == 2)
        let contentRow = try #require(store.displayRow(at: 0))
        #expect(contentRow.cells.count == 2)
        #expect(contentRow.cell(at: 2) == Terminal.GridCell())
        let painted = try #require(store.paintedDisplayRow(at: 0))
        #expect(painted.cells.count == 8)
        #expect(painted.cell(at: 2).styleId == 4)
    }

    @Test("A width change repaints the background-erase tail today's reflow drops")
    func widthChangeRepaintsTheTrailingFillTodaysReflowDrops() throws {
        // Intent: after a width change the store still paints a hard-ended line's erase tail,
        //   at the new margin, where today's engine has already lost it.
        // Why it exists: this is the amendment's deliberate divergence from today's output,
        //   recorded as a test rather than as a footnote. Today's `reconstructLogicalLines`
        //   measures a hard-ended row to its content end, so a resize discards the paint the
        //   user was looking at; the fill is width-free, so it survives and re-derives.
        var reference = try #require(Terminal(columns: 17, rows: 6))
        reference.feed(Array(RetainedContent.backgroundErased.stimulus.utf8))

        var store = Terminal.LogicalLineStore(capacityBytes: 1 << 20, width: 17)
        for index in 0..<reference.scrollbackRowCount {
            store.admit(reference.retainedRowForTesting(at: index)!)
        }

        reference.resize(columns: 9, rows: 6)
        _ = store.setWidth(9)

        let referenceRow = try #require(reference.retainedRowForTesting(at: 0))
        let painted = try #require(store.paintedDisplayRow(at: 0))
        let end = contentEnd(of: referenceRow, width: 9)
        try #require(end < 9, "the sample row must leave a tail for the erase to paint")

        #expect(referenceRow.cell(at: end).styleId == Terminal.defaultStyleId)
        #expect(painted.cell(at: end).styleId != Terminal.defaultStyleId)
        #expect(painted.cell(at: 8).styleId == painted.cell(at: end).styleId)
    }

    // MARK: - `31/D3` Decision 3: the background-erase blank

    @Test("A cleared spacer under a non-default erase style is materialized as one styled cell")
    func clearedSpacerMaterializesTheBackgroundEraseBlank() {
        // Intent: repairing a cleared spacer under a non-default erase style appends one
        //   styled blank to the open record, and under the default style appends nothing.
        // Why it exists: `31/D3` Decision 3 measured today's engine storing exactly one styled
        //   cell at that column, and nothing at all when the style is default -- so the fold
        //   reproduces today's output only if the repair is asymmetric in the same way.
        for (styleId, expectedCells) in [(Terminal.StyleId(5), 3), (Terminal.defaultStyleId, 2)] {
            var store = Terminal.LogicalLineStore(capacityBytes: 1 << 16, width: 3)
            var wrapped = Terminal.GridRow(cells: [
                Terminal.GridCell(scalars: TerminalScalars("a" as Unicode.Scalar), kind: .narrow),
                Terminal.GridCell(scalars: TerminalScalars("b" as Unicode.Scalar), kind: .narrow),
                Terminal.GridCell(scalars: .empty, kind: .spacerHead),
            ])
            wrapped.isSoftWrapped = true
            store.admit(wrapped)

            store.repairClearedSpacer(styleId: styleId)

            #expect(store.recordSummary(at: 0)!.cellCount == expectedCells)
            #expect(store.grandDisplayRowTotal == 1)
            if expectedCells == 3 {
                let row = store.displayRow(at: 0)!
                #expect(row.cell(at: 2).kind == .padding)
                #expect(row.cell(at: 2).styleId == styleId)
            }
        }
    }

    // MARK: - Helpers

    /// Content classes whose retained rows exercise different corners of the fold.
    private enum RetainedContent: CaseIterable, CustomStringConvertible {
        /// Short hard-ended lines: the `scrollback-stream` row shape.
        case shortLines
        /// Lines longer than the pane, so most retained rows are soft-wrapped continuations.
        case wrappedLines
        /// CJK, so `hasWideCells` fires and the spacer arithmetic runs.
        case wideClusters
        /// Styled and hyperlinked runs, so the side tables carry content.
        case decorated
        /// Hard-ended lines whose tail past the content is painted by a non-default
        /// background erase, which is the only class where today's stored row holds a cell the
        /// content walk does not.
        case backgroundErased

        var columns: Int { self == .wideClusters ? 11 : 17 }

        var description: String {
            switch self {
            case .shortLines: "shortLines"
            case .wrappedLines: "wrappedLines"
            case .wideClusters: "wideClusters"
            case .decorated: "decorated"
            case .backgroundErased: "backgroundErased"
            }
        }

        var stimulus: String {
            switch self {
            case .shortLines:
                (0..<40).map { "line \($0)\r\n" }.joined()
            case .wrappedLines:
                (0..<20).map { index in
                    String(repeating: "abcdefghij", count: 4) + "\(index)\r\n"
                }.joined()
            case .wideClusters:
                (0..<30).map { index in
                    String(repeating: "\u{754C}\u{4E16}", count: 3) + "x\(index)\r\n"
                }.joined()
            case .decorated:
                (0..<30).map { index in
                    "\u{1B}[3\(index % 8)m"
                        + "\u{1B}]8;;https://example.com/\(index)\u{1B}\\"
                        + "link \(index) text"
                        + "\u{1B}]8;;\u{1B}\\"
                        + " tail\u{1B}[0m\r\n"
                }.joined()
            case .backgroundErased:
                // Red background, a few printed cells, then EL -- so the columns past the
                // content end are blank cells carrying the erase style, to the right margin.
                (0..<30).map { index in
                    "\u{1B}[41mbce \(index)\u{1B}[K\u{1B}[0m\r\n"
                }.joined()
            }
        }
    }

    /// Display rows the two stores must agree on cell for cell.
    ///
    /// Excludes the final display row of an **open** record, and only that row. `31/D3`
    /// Decision 3 states the reason in terms: admission drops the `.spacerHead` a wrap left in
    /// the last column (`31/F4` case 1, and storing it would be width-dependent data in
    /// history), and the fold re-derives it from the wide head that follows -- which has not
    /// been admitted yet while the line is still being printed into the live grid. So for an
    /// open record "the only way a final display row can be short" is exactly that one column,
    /// and it fills in as soon as the next row scrolls off. `assertOpenTailSeam` pins the
    /// shortfall to that one column rather than letting the exclusion hide anything else.
    private func comparableRowCount(_ store: Terminal.LogicalLineStore, _ total: Int) -> Int {
        guard store.recordCount > 0,
              store.recordSummary(at: store.recordCount - 1)?.isOpen == true
        else { return total }
        return max(0, total - 1)
    }

    /// Asserts the open tail's final display row differs from today's stored row in at most the
    /// one column a dropped spacer occupied, and matches everywhere else.
    private func assertOpenTailSeam(
        _ store: Terminal.LogicalLineStore,
        _ retained: [Terminal.GridRow],
        width: Int,
        label: String
    ) throws {
        guard comparableRowCount(store, retained.count) < retained.count else { return }
        let index = retained.count - 1
        let folded = try #require(store.displayRow(at: index))
        let reference = retained[index]
        for column in 0..<width {
            let lhs = folded.cell(at: column)
            let rhs = reference.cell(at: column)
            if lhs == rhs { continue }
            #expect(rhs.kind == .spacerHead, "\(label) seam row, column \(column)")
            #expect(lhs == Terminal.GridCell(), "\(label) seam row, column \(column)")
            #expect(column == width - 1, "\(label) seam row, column \(column)")
        }
        #expect(folded.isSoftWrapped == reference.isSoftWrapped, "\(label) seam row: soft wrap")
    }

    /// Holds both of the store's walks to today's stored row, each over the extent it owns.
    ///
    /// The painted walk over the pane's full width, because that is the row the user saw. The
    /// content walk only up to the row's content end, because past it a background-erase tail
    /// lives in the record's fill style rather than in its cells -- the one place the two walks
    /// legitimately differ, and the reason this helper takes both rather than one.
    private func assertSameRow(
        painted: Terminal.GridRow,
        content: Terminal.GridRow,
        reference: Terminal.GridRow,
        width: Int,
        label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            painted.isSoftWrapped == reference.isSoftWrapped,
            "\(label): soft wrap",
            sourceLocation: sourceLocation
        )
        #expect(
            painted.semanticPrompt == reference.semanticPrompt,
            "\(label): semantic prompt",
            sourceLocation: sourceLocation
        )
        for column in 0..<width {
            let lhs = painted.cell(at: column)
            let rhs = reference.cell(at: column)
            #expect(
                lhs == rhs,
                "\(label): painted column \(column)",
                sourceLocation: sourceLocation
            )
        }
        for column in 0..<contentEnd(of: reference, width: width) {
            let lhs = content.cell(at: column)
            let rhs = reference.cell(at: column)
            #expect(
                lhs == rhs,
                "\(label): content column \(column)",
                sourceLocation: sourceLocation
            )
        }
    }

    /// Compares the store's content walk against a reference row column by column.
    private func assertSameContentRow(
        _ folded: Terminal.GridRow,
        _ reference: Terminal.GridRow,
        width: Int,
        label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            folded.isSoftWrapped == reference.isSoftWrapped,
            "\(label): soft wrap",
            sourceLocation: sourceLocation
        )
        #expect(
            folded.semanticPrompt == reference.semanticPrompt,
            "\(label): semantic prompt",
            sourceLocation: sourceLocation
        )
        for column in 0..<width {
            let lhs = folded.cell(at: column)
            let rhs = reference.cell(at: column)
            #expect(lhs == rhs, "\(label): column \(column)", sourceLocation: sourceLocation)
        }
    }

    /// One past the row's last content cell -- `Terminal.retainedContentEnd`'s rule, restated
    /// here because it is private to the engine. A soft-wrapped row occupies every column.
    private func contentEnd(of row: Terminal.GridRow, width: Int) -> Int {
        guard row.isSoftWrapped == false else { return width }
        for column in stride(from: min(width, row.cells.count) - 1, through: 0, by: -1) {
            let kind = row.cells[column].kind
            guard kind == .narrow || kind == .wideHead else { continue }
            return min(width, column + (kind == .wideHead ? 2 : 1))
        }
        return 0
    }
}
