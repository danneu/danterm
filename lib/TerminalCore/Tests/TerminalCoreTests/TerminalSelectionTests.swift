// Selection serialization, attachment, invalidation, eviction, and screen-lifetime proofs.
import Testing

@testable import TerminalCore

/// Pins linear selection to projection-unit boundaries owned by the terminal value.
struct TerminalSelectionTests {
    @Test("a single cell selects one complete projection unit")
    func singleCellSelection() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("AB".utf8))

        terminal.setSelection(
            from: TerminalTextPosition(row: 0, column: 0),
            to: TerminalTextPosition(row: 0, column: 0)
        )

        #expect(terminal.selectionRange == TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 0),
            end: TerminalTextPosition(row: 0, column: 1)
        ))
        #expect(terminal.selectedText == "A")

        let found = terminal.beginSearch("A")
        #expect(found)
        terminal.clearSelection()
        #expect(terminal.selectionRange == nil)
        #expect(terminal.activeSearchMatchRange != nil)
        terminal.clearSearch()
        #expect(terminal.activeSearchMatchRange == nil)
    }

    @Test("selection uses the logical projection for wraps boundaries spaces and empty lines")
    func projectionSerialization() throws {
        // Intent: make selection a substring operation over the same full-history projection.
        // Why it exists: independent row serialization loses soft-wrap padding and empty lines.
        // Scenario: a user drags across wrapped output, hard returns, and an empty output line.
        var soft = try #require(Terminal(columns: 4, rows: 3))
        soft.feed(Array("ABCDE".utf8))
        soft.setSelection(
            from: TerminalTextPosition(row: 1, column: 0),
            to: TerminalTextPosition(row: 0, column: 2)
        )
        #expect(soft.selectedText == "CDE")

        var hard = try #require(Terminal(columns: 4, rows: 4))
        hard.feed(Array("A B\r\n\r\nC".utf8))
        hard.setSelection(
            from: TerminalTextPosition(row: 0, column: 0),
            to: TerminalTextPosition(row: 2, column: 0)
        )
        #expect(hard.selectedText == "A B\n\nC")

        var padding = try #require(Terminal(columns: 4, rows: 2))
        padding.feed(Array("A".utf8))
        padding.setSelection(
            from: TerminalTextPosition(row: 0, column: 0),
            to: TerminalTextPosition(row: 0, column: 3)
        )
        #expect(padding.selectedText == "A")

        var wrappedPadding = try #require(Terminal(columns: 4, rows: 2))
        wrappedPadding.moveCursor(row: 0, column: 3)
        wrappedPadding.feed(Array("XY".utf8))
        wrappedPadding.setSelection(
            from: TerminalTextPosition(row: 0, column: 0),
            to: TerminalTextPosition(row: 1, column: 0)
        )
        #expect(wrappedPadding.selectedText == "   XY")
    }

    @Test("selection endpoints never split grapheme clusters or wide cells")
    func clusterAtomicity() throws {
        let decomposed = "n\u{0303}"
        var spanish = try #require(Terminal(columns: 6, rows: 1))
        spanish.feed(Array(decomposed.utf8))
        spanish.setSelection(
            from: TerminalTextPosition(row: 0, column: 0),
            to: TerminalTextPosition(row: 0, column: 0)
        )
        #expect(spanish.selectedText == decomposed)

        var wide = try #require(Terminal(columns: 6, rows: 1))
        wide.feed(Array("A\u{754C}".utf8))
        wide.setSelection(
            from: TerminalTextPosition(row: 0, column: 2),
            to: TerminalTextPosition(row: 0, column: 2)
        )
        #expect(wide.selectionRange == TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 1),
            end: TerminalTextPosition(row: 0, column: 3)
        ))
        #expect(wide.selectedText == "\u{754C}")

        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        var emoji = try #require(Terminal(columns: 4, rows: 1))
        emoji.feed(Array(family.utf8))
        emoji.setSelection(
            from: TerminalTextPosition(row: 0, column: 0),
            to: TerminalTextPosition(row: 0, column: 1)
        )
        #expect(emoji.selectedText == family)
    }

    @Test("selection and search stay attached through width reflow and height migration")
    func resizeAttachment() throws {
        // Intent: retain the exact occurrence and endpoint images across reversible reflow.
        // Why it exists: recomputing from equal text can silently jump among duplicate matches.
        // Scenario: a pane narrows, grows, shrinks vertically, and grows back around repeated text.
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("xx target xx target".utf8))
        terminal.setSelection(
            from: TerminalTextPosition(row: 1, column: 3),
            to: TerminalTextPosition(row: 2, column: 0)
        )
        let foundTarget = terminal.beginSearch("target")
        #expect(foundTarget)
        let selection = terminal.selectionRange
        let match = terminal.activeSearchMatchRange
        let text = terminal.selectedText

        terminal.resize(columns: 5, rows: 3)
        terminal.resize(columns: 8, rows: 3)

        #expect(terminal.selectionRange == selection)
        #expect(terminal.activeSearchMatchRange == match)
        #expect(terminal.selectedText == text)

        terminal.resize(columns: 8, rows: 1)
        #expect(terminal.selectedText == text)
        terminal.resize(columns: 8, rows: 3)
        #expect(terminal.selectedText == text)

        var hardBoundary = try #require(Terminal(columns: 6, rows: 3))
        hardBoundary.feed(Array("AB\r\nCD".utf8))
        hardBoundary.setSelection(
            from: TerminalTextPosition(row: 0, column: 1),
            to: TerminalTextPosition(row: 1, column: 0)
        )
        let foundBoundary = hardBoundary.beginSearch("\n")
        #expect(foundBoundary)
        let boundarySelection = hardBoundary.selectionRange
        let boundaryMatch = hardBoundary.activeSearchMatchRange
        hardBoundary.resize(columns: 4, rows: 3)
        hardBoundary.resize(columns: 6, rows: 3)
        #expect(hardBoundary.selectionRange == boundarySelection)
        #expect(hardBoundary.activeSearchMatchRange == boundaryMatch)

        var interiorPadding = try #require(Terminal(columns: 6, rows: 3))
        interiorPadding.moveCursor(row: 0, column: 5)
        interiorPadding.feed(Array("XY".utf8))
        interiorPadding.setSelection(
            from: TerminalTextPosition(row: 0, column: 2),
            to: TerminalTextPosition(row: 0, column: 4)
        )
        let paddingRange = interiorPadding.selectionRange
        interiorPadding.resize(columns: 4, rows: 3)
        interiorPadding.resize(columns: 6, rows: 3)
        #expect(interiorPadding.selectionRange == paddingRange)
        #expect(interiorPadding.selectedText == "   ")
    }

    @Test("ordinary output migration preserves selection while overwrite clears only intersections")
    func mutationAttachmentAndInvalidation() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("AAAA\r\nBBBB".utf8))
        terminal.setSelection(
            from: TerminalTextPosition(row: 0, column: 0),
            to: TerminalTextPosition(row: 0, column: 3)
        )
        terminal.feed(Array("\r\nCCCC".utf8))
        #expect(terminal.selectedText == "AAAA")
        #expect(terminal.selectionRange?.start.row == 0)

        terminal.feed(Array("\u{1B}[2;1HZ".utf8))
        #expect(terminal.selectedText == "AAAA")

        var overwritten = try #require(Terminal(columns: 4, rows: 2))
        overwritten.feed(Array("AAAA\r\nBBBB".utf8))
        overwritten.setSelection(
            from: TerminalTextPosition(row: 0, column: 0),
            to: TerminalTextPosition(row: 0, column: 3)
        )
        overwritten.feed(Array("\u{1B}[1;1HZ".utf8))
        #expect(overwritten.selectionRange == nil)
    }

    @Test("eviction clamps selection and clears a truncated active match")
    func evictionMaintenance() throws {
        var terminal = try #require(Terminal(
            columns: 2,
            rows: 1,
            scrollbackBudgetBytes: historyBudget(lines: 2, cells: 1, paneColumns: 2)
        ))
        terminal.feed(Array("A\r\nB\r\nC".utf8))
        terminal.setSelection(
            from: TerminalTextPosition(row: 0, column: 0),
            to: TerminalTextPosition(row: 2, column: 0)
        )
        let foundA = terminal.beginSearch("A")
        #expect(foundA)

        terminal.feed(Array("\r\nD".utf8))

        #expect(terminal.selectedText == "B\nC")
        #expect(terminal.activeSearchMatchRange == nil)

        terminal.setSelection(
            from: TerminalTextPosition(row: 0, column: 0),
            to: TerminalTextPosition(row: 2, column: 0)
        )
        terminal.feed(Array("\u{1B}[3J".utf8))
        #expect(terminal.selectionRange != nil)
        #expect(terminal.selectedText == "D")
    }

    @Test("whole eviction clears while reflow eviction clamps after attachment")
    func wholeAndReflowEviction() throws {
        var whole = try #require(Terminal(
            columns: 2,
            rows: 1,
            scrollbackBudgetBytes: historyBudget(lines: 1, cells: 1, paneColumns: 2)
        ))
        whole.feed(Array("A\r\nB".utf8))
        whole.setSelection(
            from: TerminalTextPosition(row: 0, column: 0),
            to: TerminalTextPosition(row: 0, column: 0)
        )
        whole.feed(Array("\r\nC".utf8))
        #expect(whole.selectionRange == nil)

        var reflow = try #require(Terminal(
            columns: 4,
            rows: 1,
            scrollbackBudgetBytes: historyBudget(lineCells: [24], paneColumns: 4)
        ))
        reflow.feed(Array("ABCDEFGHI".utf8))
        reflow.setSelection(
            from: TerminalTextPosition(row: 0, column: 0),
            to: TerminalTextPosition(row: 2, column: 0)
        )
        let found = reflow.beginSearch("AB")
        #expect(found)

        reflow.resize(columns: 2, rows: 1)

        // The width change evicts nothing (`31/I3`), so the occurrence it used to lose to a
        // reflow-triggered eviction survives -- restated, not dropped (`research/31/D3` Decision 2).
        #expect(reflow.selectedText == reflow.fullHistoryText)
        #expect(reflow.activeSearchMatchRange != nil)
    }

    @Test("a stripped trailing blank endpoint clamps to retained content")
    func strippedBlankEndpointClamps() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("A".utf8))
        terminal.setSelection(
            from: TerminalTextPosition(row: 2, column: 3),
            to: TerminalTextPosition(row: 2, column: 3)
        )

        terminal.resize(columns: 4, rows: 1)

        #expect(terminal.selectionRange == TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 1),
            end: TerminalTextPosition(row: 0, column: 1)
        ))
        #expect(terminal.selectedText == "")

        var empty = try #require(Terminal(columns: 6, rows: 2))
        empty.setSelection(
            from: TerminalTextPosition(row: 0, column: 4),
            to: TerminalTextPosition(row: 0, column: 5)
        )
        empty.resize(columns: 3, rows: 2)
        #expect(empty.selectionRange != nil)
        #expect(empty.selectedText == "")
    }

    @Test("select-all covers the whole retained stream including scrollback")
    func selectAllCoversWholeStream() throws {
        // Intent: select-all selects the entire retained stream, so its text equals the
        //   full-history projection and its start anchors the first retained row.
        // Why it exists: pins whole-stream extent (not the viewport), computed inside the
        //   terminal value, the contract the Cmd-A plumbing relies on to copy scrollback.
        // Scenario: output has scrolled past one screen, evicting early rows into scrollback.
        var terminal = try #require(Terminal(
            columns: 2,
            rows: 1,
            scrollbackBudgetBytes: historyBudget(lines: 2, cells: 1, paneColumns: 2)
        ))
        terminal.feed(Array("A\r\nB\r\nC\r\nD".utf8))

        terminal.selectAll()

        #expect(terminal.fullHistoryText == "B\nC\nD")
        #expect(terminal.selectedText == terminal.fullHistoryText)
        #expect(terminal.selectionRange?.start == TerminalTextPosition(row: 0, column: 0))
    }

    @Test("select-all on an empty buffer yields a present empty selection")
    func selectAllEmptyBuffer() throws {
        // Intent: select-all on a fresh terminal produces a present selection whose text is the
        //   (empty) full-history projection, not an unselected terminal.
        // Why it exists: selection presence drives `hasSelection` and therefore Copy enablement,
        //   so an empty buffer must still register a selection rather than no-op.
        // Scenario: a user presses Cmd-A immediately after opening a pane with no output.
        var terminal = try #require(Terminal(columns: 4, rows: 3))

        terminal.selectAll()

        #expect(terminal.selectionRange != nil)
        #expect(terminal.selectedText == terminal.fullHistoryText)
        #expect(terminal.selectedText == "")
    }

    @Test("screen replacement clears inspection while inert controls preserve it")
    func screenLifetime() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("AB".utf8))
        selectAndSearch(&terminal)
        terminal.feed(Array("\u{1B}[?47h\u{1B}[?47l".utf8))
        #expect(terminal.selectionRange != nil)
        #expect(terminal.activeSearchMatchRange != nil)

        terminal.feed(Array("\u{1B}[?1047l".utf8))
        #expect(terminal.selectionRange != nil)
        terminal.feed(Array("\u{1B}[?1047h".utf8))
        #expect(terminal.selectionRange == nil)
        #expect(terminal.activeSearchMatchRange == nil)

        terminal.feed(Array("ALT".utf8))
        selectAndSearch(&terminal, query: "ALT")
        terminal.resize(columns: 5, rows: 2)
        #expect(terminal.selectionRange == nil)
        #expect(terminal.activeSearchMatchRange == nil)

        terminal.feed(Array("\u{1B}[?1047l".utf8))
        selectAndSearch(&terminal)
        terminal.feed(Array("\u{1B}[!p".utf8))
        #expect(terminal.selectionRange != nil)
        terminal.feed(Array("\u{1B}c".utf8))
        #expect(terminal.selectionRange == nil)
    }

    @Test("every alternate transition arm follows whether it replaces the projection")
    func alternateTransitionMatrix() throws {
        var redundantSet = try #require(Terminal(columns: 4, rows: 2))
        redundantSet.feed(Array("AB\u{1B}[?1049hALT".utf8))
        selectAndSearch(&redundantSet, query: "ALT")
        redundantSet.feed(Array("\u{1B}[?1049h".utf8))
        #expect(redundantSet.selectionRange == nil)

        var redundantReset = try #require(Terminal(columns: 4, rows: 2))
        redundantReset.feed(Array("AB".utf8))
        selectAndSearch(&redundantReset)
        redundantReset.feed(Array("\u{1B}[?1049l".utf8))
        #expect(redundantReset.selectionRange != nil)
        #expect(redundantReset.activeSearchMatchRange != nil)

        var softAlternate = try #require(Terminal(columns: 4, rows: 2))
        softAlternate.feed(Array("AB\u{1B}[?1047hALT".utf8))
        selectAndSearch(&softAlternate, query: "ALT")
        softAlternate.feed(Array("\u{1B}[!p".utf8))
        #expect(softAlternate.selectionRange == nil)

        var primarySoft = try #require(Terminal(columns: 4, rows: 2))
        primarySoft.feed(Array("AB".utf8))
        selectAndSearch(&primarySoft)
        primarySoft.feed(Array("\u{1B}[!p".utf8))
        #expect(primarySoft.selectionRange != nil)
    }

    @Test("cursor style modes and tab stops preserve inspection state")
    func projectionNeutralControlsPreserve() throws {
        var terminal = try #require(Terminal(columns: 10, rows: 2))
        terminal.feed(Array("AB".utf8))
        selectAndSearch(&terminal)

        terminal.feed(Array("\u{1B}[31m\u{1B}[?7l\u{1B}[?25l\u{1B}[3g\u{1B}[2;2H".utf8))

        #expect(terminal.selectionRange != nil)
        #expect(terminal.activeSearchMatchRange != nil)
    }

    @Test("inspection state is semantic across feed chunking")
    func chunkingEquality() throws {
        let bytes = Array("alpha beta alpha".utf8)
        var whole = try #require(Terminal(columns: 7, rows: 3))
        whole.feed(bytes)
        var bytewise = try #require(Terminal(columns: 7, rows: 3))
        for byte in bytes {
            bytewise.feed([byte])
        }

        whole.setSelection(
            from: TerminalTextPosition(row: 0, column: 1),
            to: TerminalTextPosition(row: 1, column: 2)
        )
        bytewise.setSelection(
            from: TerminalTextPosition(row: 0, column: 1),
            to: TerminalTextPosition(row: 1, column: 2)
        )
        for result in [whole.beginSearch("alpha"), bytewise.beginSearch("alpha")] {
            #expect(result)
        }

        #expect(whole == bytewise)
        #expect(whole.selectedText == bytewise.selectedText)
        #expect(whole.activeSearchMatchRange == bytewise.activeSearchMatchRange)
    }

    @Test("seeded output resize selection and search keep valid projection boundaries")
    func seededInspectionSweep() throws {
        // Intent: check the cross-product invariants after every operation, not just endpoints.
        // Why it exists: reflow, eviction, and mutation hooks compose in orders examples miss.
        // Scenario: deterministic shell-like output alternates with resize and inspection actions.
        var generator = SeededByteGenerator(state: 0xDAD0_6EED)
        var terminal = try #require(Terminal(columns: 6, rows: 3))
        let bytes = Array("abxy \r\n".utf8)

        for _ in 0..<128 {
            switch generator.nextByte() % 4 {
            case 0:
                terminal.feed([bytes[Int(generator.nextByte()) % bytes.count]])
            case 1:
                terminal.resize(
                    columns: 3 + Int(generator.nextByte() % 6),
                    rows: 1 + Int(generator.nextByte() % 4)
                )
            case 2:
                let streamRows = terminal.scrollbackRowCount + terminal.geometry.rows.count
                terminal.setSelection(
                    from: TerminalTextPosition(
                        row: Int(generator.nextByte()) % streamRows,
                        column: Int(generator.nextByte()) % terminal.geometry.columns
                    ),
                    to: TerminalTextPosition(
                        row: Int(generator.nextByte()) % streamRows,
                        column: Int(generator.nextByte()) % terminal.geometry.columns
                    )
                )
            default:
                _ = terminal.beginSearch("ab")
            }

            if let selected = terminal.selectedText {
                #expect(selected.isEmpty || terminal.fullHistoryText.contains(selected))
            }
            if let range = terminal.selectionRange {
                #expect(cellKind(at: range.start, in: terminal) != .wideTail)
                #expect(cellKind(at: range.end, in: terminal) != .wideTail)
            }
            if let match = terminal.activeSearchMatchRange, match.end.column > 0 {
                var selectedMatch = terminal
                selectedMatch.setSelection(
                    from: match.start,
                    to: TerminalTextPosition(row: match.end.row, column: match.end.column - 1)
                )
                #expect(selectedMatch.selectedText?.lowercased() == "ab")
            }
        }
    }

    private func selectAndSearch(_ terminal: inout Terminal, query: String = "AB") {
        terminal.setSelection(
            from: TerminalTextPosition(row: terminal.scrollbackRowCount, column: 0),
            to: TerminalTextPosition(row: terminal.scrollbackRowCount, column: 0)
        )
        let found = terminal.beginSearch(query)
        #expect(found)
    }

    private func cellKind(
        at position: TerminalTextPosition,
        in terminal: Terminal
    ) -> TerminalCellKind? {
        guard position.column < terminal.geometry.columns else { return nil }
        if position.row < terminal.scrollbackRowCount {
            return terminal.scrollbackRow(at: position.row)?.cells[position.column].kind
        }
        let viewportRow = position.row - terminal.scrollbackRowCount
        guard terminal.geometry.rows.indices.contains(viewportRow) else { return nil }
        return terminal.geometry.rows[viewportRow].cells[position.column].kind
    }
}
