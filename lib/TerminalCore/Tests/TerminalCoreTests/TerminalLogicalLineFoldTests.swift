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
                let folded = try #require(store.displayRow(at: index))
                assertSameRow(
                    folded,
                    retained[index],
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
                    assertSameRow(
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

    @Test("A hard-ended row's painted tail is a display-row artefact, not line content")
    func hardEndedRowDropsItsBackgroundErasePaddingPastTheContentEnd() throws {
        // Intent: admitting a hard-ended row whose columns past its content carry a
        //   background-erase style stores the content only, so a narrower width does not wrap
        //   that painted tail into extra display rows.
        // Why it exists: this is the one place `31/F4` case 17's admission rule
        //   (`reconstructLogicalLines`' `retainedContentEnd`) visibly disagrees with
        //   `PackedRetainedRow.pack`'s canonical extent, which keeps the styled blank. As a
        //   display row the difference is one painted column; as *line content* it is a cell the
        //   fold re-wraps, so keeping it would turn a painted tail into whole blank display rows
        //   on a narrow. Today's reflow drops it for the same reason.
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

        #expect(try #require(store.recordSummary(at: 0)).cellCount == 3)
        #expect(store.grandDisplayRowTotal == 1)

        _ = store.setWidth(4)
        #expect(store.grandDisplayRowTotal == 1)
        #expect(store.independentDisplayRowRecount() == 1)
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

        var columns: Int { self == .wideClusters ? 11 : 17 }

        var description: String {
            switch self {
            case .shortLines: "shortLines"
            case .wrappedLines: "wrappedLines"
            case .wideClusters: "wideClusters"
            case .decorated: "decorated"
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

    /// Compares two display rows column by column over the pane's full width.
    private func assertSameRow(
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
}
