// Fidelity proof for doc 31's read-time fold: the arena, read at a width, must emit the display
// rows a pane of that width really shows.
//
// **The oracle is the live grid**, and it has to be, now that retained history *is* this store:
// a comparison against `scrollbackRow(at:)` would ask the thing under test what the answer is.
// The live grid's wrapping is the printer's own -- `printNarrow`/`printWide` and the live
// refold -- and shares no code with the fold, so a terminal tall enough to hold its whole
// transcript in the viewport answers "what does a pane of this width display" independently.
//
// What belongs here: comparisons between the logical-line store's fold and those live rows, plus
// the spacer arithmetic (`research/31/F4` Observation 1) the fold re-derives rather than stores. What does
// not: the arena's mutating operations and its charge, which are `TerminalLogicalLineStoreTests`.
//
// The comparison is deliberately content-level -- scalars, kinds, style ids, hyperlink ids,
// content identity, soft-wrap and semantic prompt, read through `cell(at:)` over the pane's
// full width -- because `research/31/DD15` drops the one-cell canonical floor, so the two stores
// legitimately disagree about how many trailing default cells a blank row *stores* while
// agreeing about every column a reader can observe.
//
// **Which of the store's two walks is compared against what after the trailing-fill amendment.** The
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

    @Test("Folding the arena reproduces the display rows a pane of that width shows")
    func foldReproducesTodaysRetainedRows() throws {
        // Intent: feeding a pane's own display rows into the logical-line store and folding
        //   them back at the same width returns every column unchanged.
        // Why it exists: `31/I6` is the invariant the whole design rests on -- wrapping at
        //   read must emit the same cells, kinds, styles, spacer placement, continuation
        //   stamping and soft-wrap marking a displayed row carries -- and `research/31/F5`'s
        //   simplification argument is only collectable if it does.
        for content in RetainedContent.allCases {
            let retained = try liveDisplayRows(content.stimulus, columns: content.columns)
            let projected = projectedRows(retained, columns: content.columns)
            try #require(retained.count > 4, "\(content) displayed too little to compare")

            var store = Terminal.LogicalLineStore(
                budgetBytes: 1 << 20,
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
                    reference: projected[index],
                    width: content.columns,
                    label: "\(content) row \(index)"
                )
            }
            try assertOpenTailSeam(store, projected, width: content.columns, label: "\(content)")
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
                let source = try liveDisplayRows(content.stimulus, columns: content.columns)
                var store = Terminal.LogicalLineStore(
                    budgetBytes: 1 << 20,
                    width: content.columns
                )
                for row in source {
                    store.admit(row)
                }

                _ = store.setWidth(newWidth)

                // The same content displayed by a pane that was *never* at the old width. Its
                // transcript stays in the live grid, so neither retained storage nor a resize
                // fold is shared with the store under test.
                let referenceRows = try liveDisplayRows(content.stimulus, columns: newWidth)
                let projectedReference = projectedRows(referenceRows, columns: newWidth)
                #expect(
                    store.grandDisplayRowTotal == referenceRows.count,
                    "\(content) at width \(newWidth): folded \(store.grandDisplayRowTotal) rows against \(referenceRows.count)"
                )
                for offset in 0..<comparableRowCount(store, referenceRows.count) {
                    let painted = try #require(store.paintedDisplayRow(at: offset))
                    let contentOnly = try #require(store.displayRow(at: offset))
                    assertSameRow(
                        painted: painted,
                        content: contentOnly,
                        reference: projectedReference[offset],
                        width: newWidth,
                        label: "\(content) at width \(newWidth), row \(offset)"
                    )
                }
                try assertOpenTailSeam(
                    store,
                    projectedReference,
                    width: newWidth,
                    label: "\(content) at width \(newWidth)"
                )
            }
        }
    }

    @Test("A record straddling a chunk seam and the arena wrap folds like the live grid")
    func straddlingAndWrappingRecordFoldsLikeTheLiveGrid() throws {
        // Intent: `31/PO2`. One logical line whose bytes cross a backing-chunk seam and the
        //   arena's physical end folds, at three widths, into exactly the rows a pane of that
        //   width displays -- and the three readers agree on every one of those rows.
        // Why it exists: the chunk is copy granularity only, and the wrap is placement. Neither
        //   may reach the fold. Every other fixture in this suite sits in one chunk at an offset
        //   that never wraps, so a seam-relative or wrap-relative read would pass all of them.
        // Scenario: a long styled line of mixed narrow and wide clusters, ended by a background
        //   erase, then a blank line, then a short line -- printed into a pane whose history is
        //   already nearly full.
        let columns = 17
        let long = (0..<1_600).map { $0 % 3 == 0 ? "\u{754C}\u{4E16}" : "abcdefg" }.joined()
        // The mark rides on the one-row line at the end: the live grid stamps the row a mark was
        // issued on, while continuation stamping is the store's own derivation, so a mark on a
        // wrapped line would be comparing the two representations rather than the fold.
        let stimulus = "\u{1B}[41m" + long + "\u{1B}[K\u{1B}[0m\r\n"
            + "\r\n"
            + "\u{1B}]133;A\u{7}final\r\n"
        // The viewport has to hold the whole transcript at each width, or the oracle would be
        // reading its own scrollback.
        let viewport = [columns: 800, 13: 1_000, 7: 1_700]

        // Rows the store keeps before the line arrives. They are what puts the line near the
        // arena's end: budget 1 << 21 reserves 1,966,080 bytes in 64 KiB backing chunks, each
        // filler record costs exactly one header plus 17 cells (144 bytes), and 13,125 of them
        // leave the write cursor at 1,890,000. The line's own ~100,000 bytes then cross a chunk
        // seam and the arena's end, which the span assertions below check rather than assume.
        func fillerRow() -> Terminal.GridRow {
            Terminal.GridRow(cells: (0..<columns).map { _ in
                Terminal.GridCell(
                    scalars: TerminalScalars("z" as Unicode.Scalar),
                    kind: .narrow
                )
            })
        }

        let admitted = try liveDisplayRows(
            stimulus,
            columns: columns,
            viewportRows: try #require(viewport[columns])
        )
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 21, width: columns)
        for _ in 0..<13_125 { store.admit(fillerRow()) }
        for row in admitted { store.admit(row) }

        let summaries = (0..<store.recordCount).map { store.recordSummary(at: $0) }
        let lineCells = summaries.map { $0?.cellCount ?? 0 }.max() ?? 0
        let lineIndex = try #require(summaries.firstIndex { $0?.cellCount == lineCells })
        #expect(summaries[lineIndex]?.startsMidLine == false, "the line is whole")
        #expect(lineCells > 0)
        let span = try #require(store.recordArenaSpanForTesting(at: lineIndex))
        let chunk = store.chunkCapacityBytesForTesting
        #expect(
            span.start + span.length > store.capacityBytes,
            "the record has to cross the arena's end: \(span) of \(store.capacityBytes)"
        )
        #expect(
            (span.start + span.length - 1) / chunk > span.start / chunk + 1,
            "the record has to cross a chunk seam as well as the wrap: \(span), chunk \(chunk)"
        )
        #expect(store.evictedRowCount > 0, "the write cursor has to have passed the arena's end")
        #expect(store.chunkStorageIdentitiesForTesting().count > 1)
        #expect(summaries.contains { $0?.cellCount == 0 }, "the blank line is a zero-cell record")

        for width in [columns, 13, 7] {
            _ = store.setWidth(width)
            let reference = try liveDisplayRows(
                stimulus,
                columns: width,
                viewportRows: try #require(viewport[width])
            )
            let projected = projectedRows(reference, columns: width)
            // Only the transcript's own rows are compared: the filler ahead of it is this
            // store's, not the oracle's.
            let offset = store.grandDisplayRowTotal - reference.count
            #expect(offset > 0, "at width \(width) the filler must still be retained")
            for index in 0..<reference.count {
                let row = offset + index
                let painted = try #require(store.paintedDisplayRow(at: row))
                let contentOnly = try #require(store.displayRow(at: row))
                assertSameRow(
                    painted: painted,
                    content: contentOnly,
                    reference: projected[index],
                    width: width,
                    label: "straddling line at width \(width), row \(index)"
                )
                try assertBorrowingWalksAgree(
                    store,
                    displayRow: row,
                    painted: painted,
                    label: "straddling line at width \(width), row \(index)"
                )
            }
        }
    }

    /// Asserts the two borrowing reads emit exactly the painted row's columns.
    ///
    /// The frame path reads history through these and every fidelity proof here reads it
    /// through the materializing one, so nothing else would notice them disagreeing.
    private func assertBorrowingWalksAgree(
        _ store: Terminal.LogicalLineStore,
        displayRow: Int,
        painted: Terminal.GridRow,
        label: String
    ) throws {
        let cursor = try #require(store.locate(displayRow: displayRow))
        var borrowedKinds: [TerminalCellKind] = []
        var borrowedScalars: [TerminalScalars] = []
        var borrowedStyles: [Terminal.StyleId] = []
        store.forEachPaintedCell(at: cursor) { _, kind, scalars, styleId in
            borrowedKinds.append(kind)
            borrowedScalars.append(scalars)
            borrowedStyles.append(styleId)
        }
        var walkedKinds: [TerminalCellKind] = []
        store.forEachKind(at: cursor) { _, kind in walkedKinds.append(kind) }

        #expect(borrowedKinds == painted.cells.map(\.kind), "\(label): borrowed kinds")
        #expect(walkedKinds == painted.cells.map(\.kind), "\(label): walked kinds")
        #expect(borrowedStyles == painted.cells.map(\.styleId), "\(label): borrowed styles")
        #expect(
            borrowedScalars == painted.cells.indices.map { painted.scalars(at: $0) },
            "\(label): borrowed scalars"
        )
    }

    // MARK: - `research/31/F4` Observation 1: the spacer arithmetic

    @Test("A line of wide clusters folds to more rows than ceil(cells / width) predicts")
    func wideClustersFoldPastTheNaiveCeiling() throws {
        // Intent: three 2-cell clusters at width 3 occupy three display rows, not the two
        //   `ceil(6 / 3)` predicts.
        // Why it exists: `research/31/F4` Observation 1 is the one arithmetic correction the whole
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
                budgetBytes: 1 << 16,
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
        // Why it exists: `research/31/F4` case 1 refuses to *store* the spacer, so every attribute the
        //   renderer and `activationIdentity` read off it has to come back out of the wide
        //   head it precedes -- which is what `pack(line:columns:)` does today.
        // Admitted as one display row at width 4, then folded at 3, so the boundary the spacer
        // fills is one the fold discovers rather than one admission wrote.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
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
        // Intent: admitting a display row whose margin provenance names a wide-wrap gap stores
        //   the content cells only, and the spacer reappears at read.
        // Why it exists: `31/I1` -- a spacer's *position* is a function of the width, so
        //   storing one would be width-dependent data in history, which is `research/31/D1`'s no-go
        //   trigger.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 3)
        var wrapped = Terminal.GridRow(cells: [
            Terminal.GridCell(scalars: TerminalScalars("a" as Unicode.Scalar), kind: .narrow),
            Terminal.GridCell(scalars: TerminalScalars("b" as Unicode.Scalar), kind: .narrow),
            Terminal.GridCell(),
        ])
        wrapped.isSoftWrapped = true
        wrapped.marginProvenance = .wideWrap
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

    @Test("A deferred spacer is re-derived from the following wide head")
    func deferredSpacerIsRederivedFromFollowingWideHead() {
        // Intent: when a `.spacerHead` is dropped, the earlier row still reads with the spacer,
        //   and the spacer carries the wide head that follows it in the logical line.
        // Why it exists: `research/31/F8`'s re-run found this as a **gate 1 failure on `wide`** -- one
        //   retained display row in 14,486 read 178 cells where today's store holds 179 with a
        //   trailing spacer. `research/31/F4` case 1 refuses to store a spacer and the fold re-derives it
        //   from the wide head it defers; a split moves that head into the *next* record, so
        //   without this the column is simply lost, permanently, inside retained history. It is
        //   not the acknowledged open-tail divergence, which is transient and ends at the live
        //   seam; `research/31/DD6` says readers rejoin split records by adjacency, and this is a reader
        //   doing exactly that.
        // Scenario: the ring's write cursor reached the arena's physical end mid-line
        //   (`research/31/DD20`) on CJK content, which is how the probe produced it.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 3)
        var wrapped = Terminal.GridRow(cells: [
            Terminal.GridCell(scalars: TerminalScalars("a" as Unicode.Scalar), kind: .narrow),
            Terminal.GridCell(scalars: TerminalScalars("b" as Unicode.Scalar), kind: .narrow),
            Terminal.GridCell(),
        ])
        wrapped.isSoftWrapped = true
        wrapped.marginProvenance = .wideWrap
        store.admit(wrapped)
        #expect(store.recordSummary(at: 0)!.cellCount == 2)

        var head = Terminal.GridCell(
            scalars: TerminalScalars(Unicode.Scalar(0x754C)!),
            kind: .wideHead,
            styleId: 9
        )
        head.hyperlinkId = 4
        head.contentIdentity = 77
        var next = Terminal.GridRow(cells: [
            head,
            Terminal.GridCell(scalars: .empty, kind: .wideTail, styleId: 9),
            Terminal.GridCell(),
        ])
        next.isSoftWrapped = false
        store.admit(next)

        #expect(store.recordCount == 1)
        let seam = store.displayRow(at: 0)!
        #expect(seam.cells.count == 3)
        #expect(seam.cell(at: 2).kind == .spacerHead)
        #expect(seam.cell(at: 2).styleId == 9)
        #expect(seam.cell(at: 2).hyperlinkId == 4)
        #expect(seam.cell(at: 2).contentIdentity == 77)
        #expect(seam.isSoftWrapped)
        #expect(store.displayRow(at: 1)!.cell(at: 0).kind == .wideHead)
    }

    // MARK: - The trailing background-erase fill

    @Test("A hard-ended row's painted tail becomes a fill style, and repaints at every width")
    func hardEndedRowStoresItsBackgroundEraseTailAsAFillStyle() throws {
        // Intent: admitting a hard-ended row whose columns past its content carry a
        //   background-erase style stores the content cells plus one fill style, and the
        //   painted walk repaints from the content's end to the right margin at the admitting
        //   width, at a narrower one and at a wider one.
        // Why it exists: the original design measured such a row to its content end and
        //   dropped the paint, because storing it as *cells* would wrap a painted tail into
        //   whole blank display rows on a narrow. The amended design keeps both properties at
        //   once -- the paint is width-relative, so it is an attribute rather than cells -- and
        //   this is the test that says the row count stays put while the paint survives.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 20)
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
        //   zero-cell record, and `research/31/DD15`'s one-display-row floor is what keeps the row
        //   itself from folding away.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 12)
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
        // Why it exists: the amended design draws exactly one line -- a *trailing*
        //   to-edge paint is width-relative and becomes an attribute, while an interior erase
        //   is positionally real content. Without this test the fill rule could quietly swallow
        //   any styled blank and lose a column a program deliberately painted mid-line.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 10)
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
        #expect(second.scalars(at: 1).first == "b")
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
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 8)
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

    @Test("A width change repaints the background-erase tail in the store and the live refold alike")
    func widthChangeRepaintsTheTrailingFillInBothPaths() throws {
        // Intent: after a width change the store and the live refold both paint a hard-ended
        //   line's erase tail, at the new margin.
        // Why it exists: the two used to disagree -- the store kept the fill as one style and
        //   the live refold rebuilt its blanks at the default style -- and both now measure
        //   a row by `GridRow.visibleExtent`, so the divergence this test once pinned is gone.
        let source = try liveDisplayRows(RetainedContent.backgroundErased.stimulus, columns: 17)
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 20, width: 17)
        for row in source {
            store.admit(row)
        }
        _ = store.setWidth(9)

        let referenceRows = try resizedLiveDisplayRows(
            RetainedContent.backgroundErased.stimulus,
            columns: 17,
            resizedTo: 9
        )
        let referenceRow = try #require(referenceRows.first)
        let painted = try #require(store.paintedDisplayRow(at: 0))
        let end = contentEnd(of: referenceRow, width: 9)
        try #require(end < 9, "the sample row must leave a tail for the erase to paint")

        #expect(painted.cell(at: end).styleId != Terminal.defaultStyleId)
        #expect(painted.cell(at: 8).styleId == painted.cell(at: end).styleId)
        #expect(referenceRow.cell(at: end).styleId == painted.cell(at: end).styleId)
        #expect(referenceRow.cell(at: 8).styleId == painted.cell(at: 8).styleId)
    }

    // MARK: - A pending wrap margin belongs to the open tail

    @Test("The follower either discards or materializes a pending wrap margin")
    func followerResolvesThePendingWrapMargin() throws {
        // Intent: a leading wide head consumes the skipped margin, while every other follower
        //   makes the remembered wrap-time blank part of the logical line.
        // Why it exists: the open tail cannot decide whether the dropped spacer was structural
        //   until it sees the next row. Resolving from a later live write loses the column at the
        //   history seam.
        // Scenario: admit the same styled gap row before either a wide or narrow follower.
        let gap = Self.gapRow(width: 3, styleId: 5)

        var wide = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 3)
        wide.admit(gap)
        wide.admit(Terminal.GridRow(cells: [
            Terminal.GridCell(
                scalars: TerminalScalars(Unicode.Scalar(0x754C)!),
                kind: .wideHead,
                styleId: 7
            ),
            Terminal.GridCell(kind: .wideTail, styleId: 7),
        ]))
        #expect(wide.recordSummary(at: 0)?.cellCount == 4)
        #expect(wide.displayRow(at: 0)?.cell(at: 2).kind == .spacerHead)

        var narrow = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 3)
        narrow.admit(gap)
        narrow.admit(Terminal.GridRow(cells: [
            Terminal.GridCell(scalars: TerminalScalars("X" as Unicode.Scalar), kind: .narrow),
        ]))
        #expect(narrow.recordSummary(at: 0)?.cellCount == 4)
        let first = try #require(narrow.displayRow(at: 0))
        #expect(first.cell(at: 2).kind == .padding)
        #expect(first.cell(at: 2).styleId == 5)
        #expect(narrow.displayRow(at: 1)?.scalars(at: 0) == ["X"])
    }

    @Test("Closing a pending wrap margin keeps only non-default wrap-time paint")
    func closeResolvesThePendingWrapMargin() throws {
        for (styleId, expectedCells) in [(Terminal.StyleId(5), 3), (Terminal.defaultStyleId, 2)] {
            var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 3)
            store.admit(Self.gapRow(width: 3, styleId: styleId))

            store.closeOpenRecord()

            #expect(store.recordSummary(at: 0)?.cellCount == expectedCells)
            let row = try #require(store.displayRow(at: 0))
            #expect(row.cell(at: 2).kind == .padding)
            #expect(row.cell(at: 2).styleId == styleId)
        }
    }

    @Test("A pending margin survives rebase and front eviction but leaves with its record")
    func pendingMarginLifetimeFollowsItsOpenRecord() throws {
        let gap = Self.gapRow(width: 3, styleId: 5)
        let narrowFollower = Terminal.GridRow(cells: [
            Terminal.GridCell(scalars: TerminalScalars("X" as Unicode.Scalar), kind: .narrow),
        ])

        var source = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 3)
        source.admit(Terminal.GridRow(cells: [
            Terminal.GridCell(scalars: TerminalScalars("z" as Unicode.Scalar), kind: .narrow),
        ]))
        source.admit(gap)

        var rebased = source.rebased(toBudgetBytes: 1 << 15)
        _ = rebased.evictOneDisplayRow()
        rebased.admit(narrowFollower)
        let retainedGap = try #require(rebased.displayRow(at: 0))
        #expect(retainedGap.cell(at: 2).styleId == 5)

        var evicted = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 3)
        evicted.admit(gap)
        _ = evicted.evictOneDisplayRow()
        evicted.admit(narrowFollower)
        #expect(evicted.recordSummary(at: 0)?.cellCount == 1)
        #expect(evicted.displayRow(at: 0)?.scalars(at: 0) == ["X"])
    }

    @Test("Width and height hand-backs resolve the pending margin against the live follower")
    func handBacksResolveThePendingWrapMargin() throws {
        let gap = Self.gapRow(width: 3, styleId: 5)
        let head = Terminal.GridCell(
            scalars: TerminalScalars(Unicode.Scalar(0x754C)!),
            kind: .wideHead,
            styleId: 7
        )

        var widthChange = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 3)
        widthChange.admit(gap)
        let prefix = widthChange.setWidth(4, follower: Terminal.GridCell())
        #expect(prefix.cells.map(\.styleId) == [0, 0, 5])

        var heightGrow = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 3)
        heightGrow.admit(gap)
        let pulled = heightGrow.truncateTail(displayRows: 1, follower: head)
        let row = try #require(pulled.first)
        #expect(row.cell(at: 2).kind == .padding)
        #expect(row.cell(at: 2).styleId == 5)
        #expect(row.marginProvenance == .wideWrap)
    }

    @Test("The borrowing walks emit exactly the painted row's columns, on every content class")
    func borrowingWalksAgreeWithThePaintedRow() throws {
        // Intent: `forEachPaintedCell` and `forEachKind` visit the same columns, in the same
        //   order, carrying the same scalars, style ids and kinds as `paintedRow` builds --
        //   on every retained display row of every content class, and at a second width.
        // Why it exists: the frame path reads history through the two borrowing walks and every
        //   fidelity proof in this suite reads it through the materializing one, so nothing
        //   else in the tree would notice the two disagreeing. They are three walks over one
        //   `foldedRow` shape precisely so a spacer, a chunk seam or a trailing fill
        //   cannot land in one and not the others (`research/31/F13`: the borrowing walks stopped
        //   materializing a whole `GridCell` per column, which is what made them separate
        //   code).
        for content in RetainedContent.allCases {
            let retained = try liveDisplayRows(content.stimulus, columns: content.columns)
            var store = Terminal.LogicalLineStore(budgetBytes: 1 << 20, width: content.columns)
            for row in retained { store.admit(row) }

            for width in [content.columns, max(2, content.columns - 5)] {
                _ = store.setWidth(width)
                for index in 0..<store.grandDisplayRowTotal {
                    let cursor = try #require(store.locate(displayRow: index))
                    let expected = store.paintedRow(at: cursor)

                    var painted: [(Int, TerminalCellKind, TerminalScalars, Terminal.StyleId)] = []
                    store.forEachPaintedCell(at: cursor) { painted.append(($0, $1, $2, $3)) }
                    var kinds: [(Int, TerminalCellKind)] = []
                    store.forEachKind(at: cursor) { kinds.append(($0, $1)) }

                    let label = "\(content) width \(width) row \(index)"
                    #expect(painted.count == expected.cells.count, "\(label): painted column count")
                    #expect(kinds.count == expected.cells.count, "\(label): kind column count")
                    for (offset, visited) in painted.enumerated()
                    where offset < expected.cells.count {
                        #expect(visited.0 == offset, "\(label) column \(offset): order")
                        #expect(
                            visited.1 == expected.cells[offset].kind,
                            "\(label) column \(offset): painted kind"
                        )
                        #expect(
                            visited.2 == expected.scalars(at: offset),
                            "\(label) column \(offset): scalars"
                        )
                        #expect(
                            visited.3 == expected.cells[offset].styleId,
                            "\(label) column \(offset): style"
                        )
                    }
                    for (offset, visited) in kinds.enumerated() where offset < expected.cells.count {
                        #expect(visited.0 == offset, "\(label) column \(offset): kind order")
                        #expect(
                            visited.1 == expected.cells[offset].kind,
                            "\(label) column \(offset): kind"
                        )
                    }
                }
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

    /// The display rows a pane created at `columns` shows for `stimulus` in its live grid.
    ///
    /// `viewportRows` has to hold the whole transcript, or the oracle would be answering with
    /// the store under test's own scrollback.
    private func liveDisplayRows(
        _ stimulus: String,
        columns: Int,
        viewportRows: Int = 400
    ) throws -> [Terminal.GridRow] {
        var terminal = try #require(Terminal(columns: columns, rows: viewportRows))
        terminal.feed(Array(stimulus.utf8))
        try #require(terminal.scrollbackRowCount == 0, "the reference transcript entered scrollback")
        var rows: [Terminal.GridRow] = []
        for index in 0..<viewportRows {
            guard let row = terminal.liveRowForTesting(at: index) else { break }
            rows.append(row)
        }
        // The blank rows below the transcript are the viewport's, not the content's.
        while let last = rows.last,
              last.isSoftWrapped == false,
              last.semanticPrompt == .none,
              last.cells.allSatisfy({
                  $0.kind == .padding && $0.styleId == Terminal.defaultStyleId
              })
        {
            rows.removeLast()
        }
        return rows
    }

    /// Applies the public row stream's derived-spacer rule to the independent live-grid oracle.
    private func projectedRows(
        _ rows: [Terminal.GridRow],
        columns: Int
    ) -> [Terminal.GridRow] {
        rows.indices.map { index in
            rows[index].projected(
                columns: columns,
                follower: rows.indices.contains(index + 1) ? rows[index + 1].cells.first : nil
            )
        }
    }

    /// The one resize-driven reference, used only to show today's live-grid erase-tail loss.
    private func resizedLiveDisplayRows(
        _ stimulus: String,
        columns: Int,
        resizedTo newWidth: Int
    ) throws -> [Terminal.GridRow] {
        let feedRows = 400
        let resizedRows = 800
        var terminal = try #require(Terminal(columns: columns, rows: feedRows))
        terminal.feed(Array(stimulus.utf8))
        try #require(terminal.scrollbackRowCount == 0, "the reference transcript entered scrollback")
        terminal.resize(columns: newWidth, rows: resizedRows)
        try #require(terminal.scrollbackRowCount == 0, "the resized reference entered scrollback")

        var rows: [Terminal.GridRow] = []
        for index in 0..<resizedRows {
            guard let row = terminal.liveRowForTesting(at: index) else { break }
            rows.append(row)
        }
        while let last = rows.last,
              last.isSoftWrapped == false,
              last.semanticPrompt == .none,
              last.cells.allSatisfy({
                  $0.kind == .padding && $0.styleId == Terminal.defaultStyleId
              })
        {
            rows.removeLast()
        }
        return rows
    }

    /// Display rows the two stores must agree on cell for cell.
    ///
    /// Excludes the final display row of an **open** record, and only that row. `research/31/D3`
    /// Decision 3 states the reason in terms: admission drops the `.spacerHead` a wrap left in
    /// the last column (`research/31/F4` case 1, and storing it would be width-dependent data in
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

    /// Builds the live wide-wrap-gap form admitted by the store.
    private static func gapRow(width: Int, styleId: Terminal.StyleId) -> Terminal.GridRow {
        var cells = (0..<(width - 1)).map { offset in
            Terminal.GridCell(
                scalars: TerminalScalars(Unicode.Scalar(0x61 + offset)!),
                kind: .narrow
            )
        }
        cells.append(Terminal.GridCell(kind: .padding, styleId: styleId))
        var row = Terminal.GridRow(cells: cells)
        row.isSoftWrapped = true
        row.marginProvenance = .wideWrap
        return row
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
