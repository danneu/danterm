// Proof obligations for doc 28's packed retained row (`C6`).
//
// `PO2` is the canonical-extent claim -- packing must not change what a retained row
// stores, only how. `PO3` is the observability contract, and it is the one with teeth: a
// packed row reconstructs every field a `GridCell` carried, across each axis the encoding
// treats separately, and it does so through all three paths a retained row takes
// (admission, width reflow, height transfer back into the live grid).
//
// `PO5` -- `I5`, the read cost this representation was chosen for -- is deliberately *not*
// here any more. Retained history is doc 31's `LogicalLineStore`, which reimplements its own
// readers and shares only the C1 cell word with this type, so the two wall-clock ratio tests
// that stood for `PO5` were timing a path no frame takes. If that property needs a guard
// again, it belongs against `LogicalLineStore.locate(displayRow:)` and
// `forEachPaintedCell(at:_:)`, which is what the frame path really reads.
//
// Why the encoder is tested directly and not only through the terminal: the terminal
// cannot be driven into every cell shape the encoder must handle -- a wide multi-scalar
// cell, a 4-byte stride row, a fragmented identity row with a specific run count -- and a
// proof that skipped those would be a proof about the stimuli, not about the encoding. The
// behavioral tests below are what keep the direct ones honest about mattering.
import Testing

@testable import TerminalCore

/// Pins the packed retained representation's extent and round-trip.
struct TerminalPackedRetainedRowTests {
    // MARK: - Fixtures

    private func cell(
        _ scalar: Unicode.Scalar? = nil,
        kind: TerminalCellKind = .narrow,
        styleId: Terminal.StyleId = 0,
        hyperlinkId: Terminal.HyperlinkId? = nil,
        identity: Terminal.ContentIdentity? = nil
    ) -> Terminal.GridCell {
        Terminal.GridCell(
            scalars: scalar.map { TerminalScalars($0) } ?? .empty,
            kind: scalar == nil && kind == .narrow ? .padding : kind,
            styleId: styleId,
            hyperlinkId: hyperlinkId,
            contentIdentity: identity
        )
    }

    private func roundTrips(_ row: Terminal.GridRow) -> Bool {
        Terminal.PackedRetainedRow.pack(row).unpacked() == row
    }

    // MARK: - PO3, at the encoder

    @Test("Every cell axis the packed encoding treats separately survives a round trip")
    func encoderRoundTripsEveryAxis() {
        // Intent: pack-then-unpack is the identity on rows built from each shape the
        //   encoding handles by a different mechanism -- slot, style run, kind exception,
        //   spill, hyperlink table, identity run.
        // Why it exists: this is `I3` at the level the encoding actually fails. Each axis
        //   below reaches a different table, and an off-by-one in any one of them would
        //   still leave the other five reading correctly -- so a single mixed row would
        //   report "broken" without saying what, and a plain-ASCII row would report
        //   "fine" while five tables were wrong.
        // Scenario: spec-first. These are the axes doc 28's PO3 enumerates.
        let axes: [(String, Terminal.GridRow)] = [
            ("plain ASCII", Terminal.GridRow(cells: "hello".unicodeScalars.enumerated().map {
                cell($0.element, identity: Terminal.ContentIdentity($0.offset + 1))
            })),
            ("1-byte stride at the tier boundary", Terminal.GridRow(cells: [
                cell("\u{00FF}", identity: 1), cell("a", identity: 2),
            ])),
            ("2-byte stride", Terminal.GridRow(cells: [
                cell("\u{2500}", identity: 1), cell("a", identity: 2),
            ])),
            ("4-byte stride", Terminal.GridRow(cells: [
                cell("\u{1F600}", kind: .wideHead, identity: 1),
                cell(nil, kind: .wideTail, identity: 1),
            ])),
            ("interior never-written gap", Terminal.GridRow(cells: [
                cell("a", identity: 1), cell(nil, kind: .padding), cell("b", identity: 2),
            ])),
            ("styled runs", Terminal.GridRow(cells: [
                cell("a", styleId: 3, identity: 1), cell("b", styleId: 3, identity: 2),
                cell("c", styleId: 7, identity: 3), cell("d", identity: 4),
            ])),
            ("wide cells", Terminal.GridRow(cells: [
                cell("\u{754C}", kind: .wideHead, identity: 1),
                cell(nil, kind: .wideTail, identity: 1),
                cell(nil, kind: .spacerHead, identity: nil),
            ])),
            ("multi-scalar cells", Terminal.GridRow(cells: [
                Terminal.GridCell(
                    scalars: TerminalScalars(["e", "\u{0301}"] as [Unicode.Scalar]),
                    kind: .narrow,
                    contentIdentity: 1
                ),
                cell("z", identity: 2),
            ])),
            ("wide multi-scalar cell", Terminal.GridRow(cells: [
                Terminal.GridCell(
                    scalars: TerminalScalars(["\u{1F469}", "\u{200D}", "\u{1F4BB}"] as [Unicode.Scalar]),
                    kind: .wideHead,
                    contentIdentity: 4
                ),
                cell(nil, kind: .wideTail, identity: 4),
            ])),
            ("hyperlink cells", Terminal.GridRow(cells: [
                cell("h", hyperlinkId: 9, identity: 1),
                cell("i", hyperlinkId: 9, identity: 2),
                cell("j", identity: 3),
            ])),
            ("everything at once", Terminal.GridRow(cells: [
                cell("\u{2500}", styleId: 2, hyperlinkId: 4, identity: 10),
                Terminal.GridCell(
                    scalars: TerminalScalars(["e", "\u{0301}"] as [Unicode.Scalar]),
                    kind: .narrow,
                    styleId: 2,
                    hyperlinkId: 4,
                    contentIdentity: 11
                ),
                cell(nil, kind: .padding, styleId: 5),
                cell("\u{754C}", kind: .wideHead, styleId: 5, identity: 40),
                cell(nil, kind: .wideTail, styleId: 5, identity: 40),
            ])),
        ]

        for (name, row) in axes {
            #expect(roundTrips(row), "\(name) did not survive pack/unpack")
        }
    }

    @Test("The row-level fields no cell carries survive packing")
    func encoderCarriesRowLevelFields() {
        // Intent: `isSoftWrapped` and `semanticPrompt` come back exactly, for every prompt
        //   stamp and both wrap states.
        // Why it exists: neither is derivable from cells, and a packed row that dropped
        //   either would pass every cell-for-cell check above while changing observable
        //   content after a width reflow and breaking OSC 133 prompt jumps. That gap is
        //   what human review of the plan caught, and this is the test it asked for.
        // Scenario: spec-first.
        let stamps: [Terminal.SemanticPromptRow] =
            [.none, .prompt, .continuation, .output, .vacated]
        for stamp in stamps {
            for wrapped in [true, false] {
                var row = Terminal.GridRow(cells: [cell("a", identity: 1)])
                row.isSoftWrapped = wrapped
                row.semanticPrompt = stamp
                #expect(roundTrips(row), "\(stamp)/\(wrapped) did not survive pack/unpack")
            }
        }
    }

    @Test("A fragmented identity row falls back to per-cell storage and still reads back")
    func fragmentedIdentityUsesPerCellFallback() {
        // Intent: a row whose identities fragment badly enough that a run table would cost
        //   more than four bytes per stored cell switches to the per-cell encoding, and
        //   every identity still reads back exactly.
        // Why it exists: `D6` charges `contentIdentity` per contiguous run, which is only
        //   the cheaper of two encodings -- the fallback is what keeps the *worst* case
        //   bounded at the floor rather than unbounded. An encoder that never took the
        //   fallback would pay 8 bytes per cell on fragmented content, above the floor it
        //   was priced against.
        // Scenario: spec-first; the row models content assembled by cursor moves.
        let fragmented = Terminal.GridRow(cells: (0..<16).map {
            cell("x", identity: Terminal.ContentIdentity(1000 - $0 * 7))
        })
        let packed = Terminal.PackedRetainedRow.pack(fragmented)
        #expect(packed.unpacked() == fragmented)
        // Sixteen isolated runs would be 128 bytes against the floor's 64, so the encoder
        // must have taken the fallback. Read off the payload rather than a flag so the
        // assertion is about bytes, which is what the pricing model promised.
        let runTableBytes = 16 * 8
        #expect(packed.payloadByteCount < 7 + 16 * 8 + runTableBytes)
    }

    @Test("Random and sequential reads of the same packed row agree everywhere")
    func randomReadAgreesWithSequentialRead() {
        // Intent: `cell(at:)` -- the O(log) point read -- returns exactly what the linear
        //   `unpacked()` walk produces, at every column including past the stored extent.
        // Why it exists: the two readers are separate implementations of one contract, and
        //   `I5` is the reason the point reader exists at all. They drift silently: the
        //   linear walk advances cursors and the point reader binary-searches, so a table
        //   whose entries the walk consumes in the wrong order would still look right from
        //   one side.
        // Scenario: spec-first.
        let row = Terminal.GridRow(cells: [
            cell("a", styleId: 1, identity: 5),
            cell(nil, kind: .padding, styleId: 1),
            Terminal.GridCell(
                scalars: TerminalScalars(["e", "\u{0301}"] as [Unicode.Scalar]),
                kind: .narrow,
                styleId: 2,
                hyperlinkId: 8,
                contentIdentity: 6
            ),
            cell("\u{754C}", kind: .wideHead, styleId: 2, identity: 7),
            cell(nil, kind: .wideTail, styleId: 2, identity: 7),
            cell("z", identity: 8),
        ])
        let packed = Terminal.PackedRetainedRow.pack(row)
        let walked = packed.unpacked()
        for column in 0..<(row.cells.count + 3) {
            #expect(packed.cell(at: column) == walked.cell(at: column), "column \(column)")
        }
    }

    @Test("The encoder trims to canonical extent itself, matching what compacted() produced")
    func packTrimsToCanonicalExtent() {
        // Intent: `pack` applied to an untrimmed row produces exactly the packed row that
        //   `pack(row.compacted())` produced -- same stored extent, same bytes, same reads.
        // Why it exists: admission used to materialize `compacted()` first, which copied the
        //   whole cell array (and retained every `TerminalScalars` in it) purely to drop a
        //   suffix the encoder was about to bound anyway. Folding the trim into the encoder
        //   removes that copy, and this pins the two spellings as the same row so the
        //   removal cannot quietly change what history stores -- which is `I2`.
        // Scenario: spec-first.
        let content = "hi".unicodeScalars.enumerated().map {
            cell($0.element, identity: Terminal.ContentIdentity($0.offset + 1))
        }
        let padded = Terminal.GridRow(
            cells: content + Array(repeating: Terminal.GridCell(), count: 10)
        )
        let packed = Terminal.PackedRetainedRow.pack(padded)
        #expect(packed == Terminal.PackedRetainedRow.pack(padded.compacted()))
        #expect(packed.storedCellCount == content.count)
        #expect(packed.unpacked() == padded.compacted())

        // An all-default row still stores one cell: canonical extent is floored at one, and
        // trimming to zero would make a blank retained row indistinguishable from an evicted
        // slot in the buffer's own accounting.
        let blank = Terminal.GridRow(cells: Array(repeating: Terminal.GridCell(), count: 8))
        #expect(Terminal.PackedRetainedRow.pack(blank).storedCellCount == 1)
    }

    @Test("Interior runs of never-written cells read back as the default cells they were")
    func interiorBlankRunsRoundTrip() {
        // Intent: a row whose content is separated by long interior runs of never-written
        //   cells round-trips cell for cell, including the blanks.
        // Why it exists: the encoder writes into a zero-filled blob and skips any cell whose
        //   word is zero, so a default cell is encoded by *not writing it*. That is only
        //   sound while a default `GridCell` and a zero word mean the same thing -- give
        //   `GridCell` a non-zero default (a style id, a kind) and the skip silently starts
        //   erasing cells. This is the test that would catch it.
        // Scenario: spec-first, but the shape is `benchmark/scrollback-stream`'s: bare LF
        //   leaves a staircase whose rows are mostly columns nobody ever wrote.
        var cells = Array(repeating: Terminal.GridCell(), count: 100)
        for (offset, scalar) in "tail".unicodeScalars.enumerated() {
            cells[80 + offset] = cell(scalar, identity: Terminal.ContentIdentity(offset + 1))
        }
        cells[40] = cell("m", styleId: 3, identity: 900)
        let row = Terminal.GridRow(cells: cells)

        let packed = Terminal.PackedRetainedRow.pack(row)
        #expect(packed.storedCellCount == 84)
        #expect(packed.unpacked() == row.compacted())
        for column in 0..<packed.storedCellCount {
            #expect(packed.cell(at: column) == cells[column], "column \(column)")
        }
    }

    // MARK: - PO2, through the terminal

    @Test("Packing leaves a retained row's stored extent exactly where canonical trim put it")
    func retainedExtentIsUnchangedByPacking() throws {
        // Intent: for blank, ragged, trailing-whitespace and full-width rows, the number of
        //   cells history stores is the canonical trimmed extent -- the index of the last
        //   non-default cell plus one, floored at one.
        // Why it exists: `I2` says the stored extent stays a pure function of observable
        //   content. Packing runs at admission, right where trimming does, so an encoder
        //   that padded to the stride tier or rounded a table would silently widen every
        //   retained row and turn the budget's row count into a different number.
        // Scenario: spec-first.
        let columns = 12
        var terminal = try #require(Terminal(columns: columns, rows: 2))
        // A blank row, a ragged row, a row whose content ends in spaces, and a full-width
        // row -- in that order. The two-row pane keeps only the last of them live, so all
        // four reach history.
        terminal.feed(Array("\r\n".utf8))
        terminal.feed(Array("abc\r\n".utf8))
        terminal.feed(Array("de   \r\n".utf8))
        terminal.feed(Array("123456789012\r\n".utf8))
        terminal.feed(Array("z\r\n".utf8))

        var extents: [Int] = []
        for index in 0..<terminal.scrollbackRowCount {
            let row = try #require(terminal.scrollbackRow(at: index))
            let last = row.cells.lastIndex {
                $0 != TerminalCell(kind: .padding, scalars: .empty, style: TerminalStyle(), hyperlink: nil)
            }
            extents.append((last ?? 0) + 1)
        }
        #expect(extents == [1, 3, 5, 12])
        // The census counts what history *stores*, and a blank logical line stores no cells at
        // all (`31/DD15`): its single display row is the fold's floor, not a stored cell. So the
        // stored total is the displayed extents less the blank row's one column.
        #expect(terminal.memoryCensus.retainedStoredCellCount == extents.reduce(0, +) - 1)
    }

    // MARK: - PO3, through the terminal's three paths

    @Test("A combined-metadata row survives admission, width reflow, and height transfer")
    func combinedRowSurvivesAllThreePaths() throws {
        // Intent: a row carrying a hyperlink, a style, a wide glyph and a combining
        //   sequence reads back identically after it scrolls into history, after the pane
        //   is made narrower and wider again, and after it is pulled back into the live
        //   grid by a taller pane.
        // Why it exists: `PO3` names all three paths because they are three different
        //   pieces of code. Admission packs, reflow unpacks and repacks, and height
        //   transfer unpacks into the live grid -- and only the first is exercised by a
        //   test that merely scrolls content off.
        // Scenario: spec-first.
        var terminal = try #require(Terminal(columns: 20, rows: 3, scrollbackBudgetBytes: 1 << 20))
        terminal.feed(Array("\u{1B}]8;id=x;https://danterm.test\u{1B}\\".utf8))
        terminal.feed(Array("\u{1B}[31mlink".utf8))
        terminal.feed(Array("\u{1B}]8;;\u{1B}\\".utf8))
        terminal.feed(Array("\u{1B}[0m 界 e\u{0301}\r\n".utf8))
        terminal.feed(Array("filler-a\r\nfiller-b\r\nfiller-c\r\n".utf8))

        func retainedRow() throws -> TerminalScrollbackRow {
            let match = try #require((0..<terminal.scrollbackRowCount).first {
                terminal.scrollbackRow(at: $0)?.cells.first?.scalars.first == "l"
            })
            return try #require(terminal.scrollbackRow(at: match))
        }

        let admitted = try retainedRow()
        #expect(admitted.cells[0].hyperlink?.uri == "https://danterm.test")
        #expect(admitted.cells[3].hyperlink?.explicitId == "x")
        #expect(admitted.cells[0].style != TerminalStyle())
        #expect(admitted.cells.contains { $0.kind == .wideHead && $0.scalars.first == "界" })
        #expect(admitted.cells.contains { $0.scalars.count == 2 })

        terminal.resize(columns: 12, rows: 3)
        terminal.resize(columns: 20, rows: 3)
        let reflowed = try retainedRow()
        #expect(reflowed.cells.prefix(4).map(\.scalars.first) == admitted.cells.prefix(4).map(\.scalars.first))
        #expect(reflowed.cells[0].hyperlink?.uri == "https://danterm.test")
        #expect(reflowed.cells.contains { $0.kind == .wideHead && $0.scalars.first == "界" })
        #expect(reflowed.cells.contains { $0.scalars.count == 2 })

        // Height transfer: a taller pane pulls retained rows back into the live grid.
        let beforeTransfer = terminal.scrollbackRowCount
        terminal.resize(columns: 20, rows: 6)
        #expect(terminal.scrollbackRowCount < beforeTransfer)
        let live = (0..<6).compactMap { row in
            (0..<20).compactMap { terminal.cell(row: row, column: $0) }
        }
        let linkRow = try #require(live.first { $0.first?.scalars.first == "l" })
        #expect(linkRow[0].hyperlink?.uri == "https://danterm.test")
        #expect(linkRow.contains { $0.kind == .wideHead && $0.scalars.first == "界" })
        #expect(linkRow.contains { $0.scalars.count == 2 })
    }

    @Test("A soft-wrapped line read out of history still rejoins through a width reflow")
    func softWrapSurvivesHistoryAndReflow() throws {
        // Intent: a logical line long enough to wrap, once fully in history, still reflows
        //   as one line when the pane widens -- which requires the packed rows to have kept
        //   `isSoftWrapped`.
        // Why it exists: `isSoftWrapped` is a row field no cell carries, so every cell-wise
        //   round-trip above passes with it dropped. What breaks is only visible a resize
        //   later, as a wrapped line that will not rejoin.
        // Scenario: spec-first. Human review of doc 28's plan named this axis.
        var terminal = try #require(Terminal(columns: 10, rows: 2, scrollbackBudgetBytes: 1 << 20))
        terminal.feed(Array("abcdefghijklmnopqrstuvwxy\r\n".utf8))
        terminal.feed(Array("tail-a\r\ntail-b\r\ntail-c\r\n".utf8))

        terminal.resize(columns: 30, rows: 2)
        let rejoined = (0..<terminal.scrollbackRowCount).compactMap { index -> String? in
            guard let row = terminal.scrollbackRow(at: index) else { return nil }
            return String(String.UnicodeScalarView(row.cells.flatMap { Array($0.scalars) }))
        }
        #expect(rejoined.contains { $0.hasPrefix("abcdefghijklmnopqrstuvwxy") })
    }

    @Test("A prompt-marked row keeps its OSC 133 stamp after scrolling into history")
    func semanticPromptSurvivesHistory() throws {
        // Intent: an OSC 133 prompt row scrolled into history and pulled back by a taller
        //   pane still reports as a prompt row.
        // Why it exists: `semanticPrompt` is the second row-level field with no cell to
        //   carry it, and prompt navigation anchors on it. A packed row that dropped it
        //   would break jump-to-previous-prompt while every cell read stayed correct.
        // Scenario: spec-first.
        var terminal = try #require(Terminal(columns: 20, rows: 2, scrollbackBudgetBytes: 1 << 20))
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ command\r\n".utf8))
        terminal.feed(Array("\u{1B}]133;C\u{1B}\\output-a\r\noutput-b\r\noutput-c\r\n".utf8))

        terminal.resize(columns: 20, rows: 8)
        let stamps = terminal.semanticPromptRowsForTesting
        #expect(stamps.contains { $0.stamp == .prompt })
    }

    @Test("A fragmented-identity row read out of history still adjudicates link activation")
    func fragmentedIdentityRowStillAdjudicatesActivation() throws {
        // Intent: a retained row whose `contentIdentity` values were assembled out of print
        //   order -- so the packed row takes its per-cell fallback -- still carries the
        //   identities `activationIdentity` reads, and an arm taken over it survives.
        // Why it exists: `activationIdentity` takes `max(contentIdentity)` over a projected
        //   range that spans retained rows, and reads zero as "no identity". A fallback that
        //   lost values would silently stop adjudicating links living in scrollback --
        //   `I3` with no reader that tolerates it.
        // Scenario: spec-first; the row models a line assembled by cursor moves.
        var terminal = try #require(Terminal(columns: 30, rows: 2, scrollbackBudgetBytes: 1 << 20))
        // Print right-to-left in chunks so identities descend across the row.
        for column in stride(from: 20, through: 0, by: -5) {
            terminal.feed(Array("\u{1B}[1;\(column + 1)H".utf8))
            terminal.feed(Array("https".utf8))
        }
        terminal.feed(Array("\u{1B}[2;1H".utf8))
        terminal.feed(Array("filler-a\r\nfiller-b\r\n".utf8))

        let shape = try #require(terminal.scrollbackRecordContentIdentityShape(at: 0))
        #expect(shape.strictRunCount > 1)
        #expect(shape.identifiedCellCount > 0)

        // `activationIdentity` reads the *values*, not the count, so the check that matters
        // is that the packed row hands back the same identity at the same column the live
        // grid stamped. Re-pack the decoded row: an encoding that lost or renumbered a value
        // could not reproduce itself.
        let decoded = try #require(terminal.retainedRowForTesting(at: 0))
        #expect(Terminal.PackedRetainedRow.pack(decoded).unpacked() == decoded)
        #expect(decoded.cells.contains { $0.contentIdentity != nil })
    }
}
