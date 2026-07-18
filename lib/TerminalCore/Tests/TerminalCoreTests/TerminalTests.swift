// Proves the public headless terminal state and its private wide-cell mutation invariants.
import Testing

@testable import TerminalCore

/// Locks grid reduction to deterministic text, geometry, wrapping, and control behavior.
struct TerminalTests {
    @Test("construction rejects grids that cannot represent a wide cell")
    func constructionDomain() {
        #expect(Terminal(columns: 1, rows: 1) == nil)
        #expect(Terminal(columns: 2, rows: 0) == nil)
        #expect(Terminal(columns: 2, rows: 1) != nil)
    }

    @Test("Spanish canonical forms share geometry but retain exact scalars")
    func spanishCanonicalGeometry() throws {
        var precomposed = try #require(Terminal(columns: 8, rows: 1))
        var decomposed = try #require(Terminal(columns: 8, rows: 1))

        precomposed.feed(Array("ma\u{00F1}ana".utf8))
        decomposed.feed(Array("man\u{0303}ana".utf8))

        #expect(precomposed.geometry == decomposed.geometry)
        #expect(precomposed.screenText == decomposed.screenText)
        #expect(precomposed.cell(row: 0, column: 2)?.scalars == ["\u{00F1}"])
        #expect(decomposed.cell(row: 0, column: 2)?.scalars == ["n", "\u{0303}"])
    }

    @Test("wide text uses a head and tail without changing plain screen width")
    func wideCellGeometry() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 1))

        terminal.feed(Array("\u{754C}A".utf8))

        #expect(terminal.geometry.rows[0].cells.map(\.kind) == [
            .wideHead, .wideTail, .narrow, .padding,
        ])
        #expect(terminal.screenText == "\u{754C}A ")
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 3, isPendingWrap: false))
    }

    @Test("deferred wrapping waits for the next printable scalar")
    func deferredWrap() throws {
        var terminal = try #require(Terminal(columns: 3, rows: 2))

        terminal.feed(Array("ABC".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 2, isPendingWrap: true))
        #expect(terminal.geometry.rows[0].isSoftWrapped == false)

        terminal.feed(Array("D".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 1, column: 1, isPendingWrap: false))
        #expect(terminal.geometry.rows[0].isSoftWrapped)
        #expect(terminal.cell(row: 1, column: 0)?.scalars == ["D"])
    }

    @Test("a wide cell at the last column leaves a spacer head and wraps whole")
    func wideAtRightEdge() throws {
        var terminal = try #require(Terminal(columns: 3, rows: 2))
        terminal.feed([0x09])

        terminal.feed(Array("\u{1F618}".utf8))

        #expect(terminal.geometry.rows[0].cells.map(\.kind) == [.padding, .padding, .spacerHead])
        #expect(terminal.geometry.rows[0].isSoftWrapped)
        #expect(terminal.geometry.rows[1].cells.map(\.kind) == [.wideHead, .wideTail, .padding])
        #expect(terminal.geometry.cursor == TerminalCursor(row: 1, column: 2, isPendingWrap: false))
    }

    @Test("zero-width scalars attach only to the current printed target")
    func zeroWidthAttachMatrix() throws {
        var none = try #require(Terminal(columns: 4, rows: 2))
        none.feed(Array("\u{0301}".utf8))
        #expect(none.cell(row: 0, column: 0)?.scalars == [])

        var narrow = try #require(Terminal(columns: 4, rows: 2))
        narrow.feed(Array("A\u{0301}".utf8))
        #expect(narrow.cell(row: 0, column: 0)?.scalars == ["A", "\u{0301}"])

        var wide = try #require(Terminal(columns: 4, rows: 2))
        wide.feed(Array("\u{754C}\u{0301}".utf8))
        #expect(wide.cell(row: 0, column: 0)?.scalars == ["\u{754C}", "\u{0301}"])
        #expect(wide.cell(row: 0, column: 1)?.scalars == [])

        var pending = try #require(Terminal(columns: 2, rows: 2))
        pending.feed(Array("AB\u{0301}".utf8))
        #expect(pending.geometry.cursor.isPendingWrap)
        #expect(pending.cell(row: 0, column: 1)?.scalars == ["B", "\u{0301}"])
        #expect(pending.geometry.rows[0].isSoftWrapped == false)
    }

    @Test("variation selectors remain stored on any no-break base")
    func variationSelectorAttachPolicy() throws {
        var emoji = try #require(Terminal(columns: 4, rows: 1))
        emoji.feed(Array("\u{1F618}\u{FE0E}\u{FE0F}".utf8))
        #expect(emoji.cell(row: 0, column: 0)?.scalars == ["\u{1F618}", "\u{FE0E}", "\u{FE0F}"])
        #expect(emoji.geometry.rows[0].cells.map(\.kind) == [.wideHead, .wideTail, .padding, .padding])

        var text = try #require(Terminal(columns: 4, rows: 1))
        text.feed(Array("A\u{FE0E}\u{FE0F}".utf8))
        #expect(text.cell(row: 0, column: 0)?.scalars == ["A", "\u{FE0E}", "\u{FE0F}"])
    }

    @Test("ground controls move the cursor without writing cells")
    func groundControlMatrix() throws {
        var terminal = try #require(Terminal(columns: 10, rows: 3))
        terminal.feed(Array("ABC".utf8))

        terminal.feed([0x0D])
        #expect(terminal.geometry.cursor.column == 0)
        terminal.feed([0x09])
        #expect(terminal.geometry.cursor.column == 8)
        terminal.feed([0x08])
        #expect(terminal.geometry.cursor.column == 7)
        terminal.feed([0x0A])
        #expect(terminal.geometry.cursor == TerminalCursor(row: 1, column: 7, isPendingWrap: false))
        terminal.feed([0x0B, 0x0C])
        #expect(terminal.geometry.cursor == TerminalCursor(row: 2, column: 7, isPendingWrap: false))
        #expect(terminal.screenText == "          \n          \n          ")
    }

    @Test("LF, VT, and FF line-feed below and at the bottom", arguments: [0x0A, 0x0B, 0x0C] as [UInt8])
    func lineFeedControls(control: UInt8) throws {
        var terminal = try #require(Terminal(columns: 2, rows: 2))
        terminal.feed(Array("ABC".utf8))
        terminal.moveCursor(row: 0, column: 1)

        terminal.feed([control])
        #expect(terminal.geometry.cursor.row == 1)
        #expect(terminal.geometry.rows[0].isSoftWrapped)

        terminal.feed([control])
        #expect(terminal.geometry.cursor.row == 1)
        #expect(terminal.geometry.rows[0].isSoftWrapped == false)
        #expect(terminal.cell(row: 0, column: 0)?.scalars == ["C"])
    }

    @Test("controls clear pending wrap while ignored controls preserve it")
    func pendingWrapControlMatrix() throws {
        for control in [0x08, 0x0A, 0x0B, 0x0C, 0x0D] as [UInt8] {
            var terminal = try #require(Terminal(columns: 2, rows: 2))
            terminal.feed(Array("AB".utf8))
            terminal.feed([control])
            #expect(terminal.geometry.cursor.isPendingWrap == false)
        }

        var tab = try #require(Terminal(columns: 2, rows: 2))
        tab.feed(Array("AB".utf8))
        let expectedTab = tab
        tab.feed([0x09])
        #expect(tab == expectedTab)

        let ignored: [UInt8] = [
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
            0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
            0x18, 0x19, 0x1A, 0x1C, 0x1D, 0x1E, 0x1F, 0x7F,
        ]
        for control in ignored {
            var terminal = try #require(Terminal(columns: 2, rows: 2))
            terminal.feed(Array("AB".utf8))
            let expected = terminal
            terminal.feed([control])
            #expect(terminal == expected)
        }
    }

    @Test("backspace may land on a wide tail without erasing")
    func backspaceOntoWideTail() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 1))
        terminal.feed(Array("\u{754C}".utf8))

        terminal.feed([0x08])

        #expect(terminal.geometry.cursor.column == 1)
        #expect(terminal.geometry.rows[0].cells.map(\.kind) == [.wideHead, .wideTail, .padding, .padding])
    }

    @Test("backspace clamps at column zero")
    func backspaceClampsAtZero() throws {
        var terminal = try #require(Terminal(columns: 2, rows: 1))

        terminal.feed([0x08])

        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))
        #expect(terminal.geometry.rows[0].cells.allSatisfy { $0.kind == .padding })
    }

    @Test("tab clamps to the last column and preserves padding")
    func tabStopsAndPadding() throws {
        var terminal = try #require(Terminal(columns: 12, rows: 1))

        terminal.feed([0x09])
        #expect(terminal.geometry.cursor.column == 8)
        terminal.feed([0x09])
        #expect(terminal.geometry.cursor.column == 11)
        #expect(terminal.geometry.rows[0].cells.allSatisfy { $0.kind == .padding })
    }

    @Test("written space and cursor-only padding share screen text but not geometry")
    func writtenSpaceVersusPadding() throws {
        var written = try #require(Terminal(columns: 4, rows: 1))
        var skipped = try #require(Terminal(columns: 4, rows: 1))
        written.feed(Array(" ".utf8))
        skipped.feed([0x09, 0x0D])

        #expect(written.screenText == skipped.screenText)
        #expect(written.geometry != skipped.geometry)
        #expect(written.geometry.rows[0].cells[0].kind == .narrow)
        #expect(skipped.geometry.rows[0].cells[0].kind == .padding)
    }

    @Test("overwriting either half clears the full wide pair", arguments: [2, 6])
    func overwriteWideHalves(columns: Int) throws {
        for targetColumn in [0, 1] {
            var terminal = try #require(Terminal(columns: columns, rows: 2))
            terminal.feed(Array("\u{754C}".utf8))
            terminal.moveCursor(row: 0, column: targetColumn)
            terminal.feed(Array("X".utf8))

            #expect(terminal.geometry.rows[0].cells[0].kind == (targetColumn == 0 ? .narrow : .padding))
            #expect(terminal.geometry.rows[0].cells[1].kind == (targetColumn == 1 ? .narrow : .padding))
            expectValidGrid(terminal)
        }
    }

    @Test("wide overwrite clears every intersected pair", arguments: [2, 6])
    func wideOverAdjacentPairs(columns: Int) throws {
        var terminal = try #require(Terminal(columns: columns, rows: 1))
        terminal.feed(Array((columns == 2 ? "\u{754C}" : "\u{754C}\u{754C}").utf8))
        terminal.moveCursor(row: 0, column: columns == 2 ? 0 : 1)

        terminal.feed(Array("\u{1F618}".utf8))

        let expected: [TerminalCellKind] = columns == 2
            ? [.wideHead, .wideTail]
            : [.padding, .wideHead, .wideTail, .padding, .padding, .padding]
        #expect(terminal.geometry.rows[0].cells.map(\.kind) == expected)
        expectValidGrid(terminal)
    }

    @Test("erase widens a split range to full wide pairs", arguments: [2, 6])
    func eraseWidensWidePairs(columns: Int) throws {
        var terminal = try #require(Terminal(columns: columns, rows: 2))
        terminal.feed(Array("\u{754C}".utf8))

        terminal.eraseCells(row: 0, columns: 1..<2)

        #expect(terminal.geometry.rows[0].cells[0].kind == .padding)
        #expect(terminal.geometry.rows[0].cells[1].kind == .padding)
        expectValidGrid(terminal)
    }

    @Test("clearing a wrapped pair removes its previous-row spacer head", arguments: [2, 6])
    func clearingWrappedPairClearsSpacerHead(columns: Int) throws {
        var terminal = try #require(Terminal(columns: columns, rows: 2))
        terminal.moveCursor(row: 0, column: columns - 1)
        terminal.feed(Array("\u{754C}".utf8))
        terminal.moveCursor(row: 1, column: 0)

        terminal.feed(Array("X".utf8))

        #expect(terminal.geometry.rows[0].cells[columns - 1].kind == .padding)
        expectValidGrid(terminal)
    }

    @Test("bottom scrolling moves wrap flags and wide rows whole", arguments: [2, 6])
    func scrollingPreservesWideIntegrity(columns: Int) throws {
        var terminal = try #require(Terminal(columns: columns, rows: 2))
        terminal.moveCursor(row: 0, column: columns - 1)
        terminal.feed(Array("\u{754C}".utf8))
        terminal.feed([0x0A])

        #expect(terminal.geometry.rows[0].cells[0].kind == .wideHead)
        #expect(terminal.geometry.rows[0].isSoftWrapped == false)
        #expect(terminal.geometry.rows[1].cells.allSatisfy { $0.kind == .padding })
        expectValidGrid(terminal)

        terminal.feed([0x0A])
        #expect(terminal.geometry.rows.allSatisfy { row in
            row.cells.allSatisfy { $0.kind == .padding }
        })
        let retained = try #require(terminal.scrollbackRow(at: 1))
        #expect(retained.cells[0].kind == .wideHead)
        #expect(retained.cells[1].kind == .wideTail)
        #expect(retained.isSoftWrapped == false)
        expectValidGrid(terminal)
    }

    @Test("every representative chunk split produces identical terminal state")
    func chunkBoundaryInvariance() throws {
        // Intent: prove terminal state, including decoder, absorber, grid, and
        //   pending wrap, is independent of arbitrary PTY read boundaries.
        // Why it exists: stream-level equality alone cannot catch grid actions
        //   applied differently when a scalar or sequence spans a feed call.
        // Scenario: mixed Spanish, Chinese, emoji, malformed bytes, controls,
        //   escapes, and a wide-at-edge print arrive in every chunk partition.
        let fixtures: [[UInt8]] = [
            Array("ma\u{00F1}ana".utf8),
            Array("man\u{0303}ana".utf8),
            Array("\u{754C}\u{1F618}".utf8),
            Array("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}".utf8),
            Array("\u{1F44D}\u{1F3FD}".utf8),
            Array("\u{1F1FA}\u{1F1F8}\u{1F1E8}".utf8),
            Array("AB#\u{FE0F}".utf8),
            Array("#\u{FE0F}\u{20E3}".utf8),
            Array("\u{0915}\u{094D}\u{200D}\u{0915}".utf8),
            Array("\u{1F468}\u{200D}".utf8) + [0x80] + Array("\u{0301}\u{1F469}".utf8),
            [0x41, 0x0D, 0x09, 0x08, 0x0A, 0x42],
            [0xF0, 0x9F, 0x41, 0x80, 0x42],
            [0x41, 0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x42],
            [0x41, 0x1B, 0x5B, 0x32, 0x3B, 0x33, 0x48, 0x42],
            [0x41, 0x1B, 0x5B, 0x31, 0x32, 0x33, 0x43, 0x42],
            [0x41, 0x1B, 0x5B, 0x32, 0x4A, 0x42],
            Array("A\u{1B}[38:2::1:2:3mB".utf8),
            [0x41, 0x1B, 0x5B, 0x3F, 0x32, 0x41, 0x42],
            Array(("A\u{1B}[" + Array(repeating: "1", count: 25).joined(separator: ";") + "HB").utf8),
            [0x41, 0x1B, 0x5B, 0x31, 0x32, 0x18, 0x42],
            [0x41, 0x1B, 0x5B, 0x31, 0x32, 0x1B, 0x5B, 0x32, 0x4A, 0x42],
            [0x09] + Array("\u{754C}".utf8),
        ]

        for bytes in fixtures {
            let expected = try run(chunks: [bytes])
            for first in 0...bytes.count {
                #expect(try run(chunks: [Array(bytes[..<first]), Array(bytes[first...])]) == expected)
                for second in first...bytes.count {
                    #expect(try run(chunks: [
                        Array(bytes[..<first]),
                        Array(bytes[first..<second]),
                        Array(bytes[second...]),
                    ]) == expected)
                }
            }
            #expect(try run(chunks: bytes.map { [$0] }) == expected)
        }
    }

    @Test("terminal replay is deterministic and copies remain independent")
    func replayAndCopyIsolation() throws {
        let bytes = Array("A\u{754C}B".utf8) + [0x1B, 0x5B, 0x6D, 0x09]
        var first = try #require(Terminal(columns: 8, rows: 2))
        var second = try #require(Terminal(columns: 8, rows: 2))

        first.feed(bytes)
        second.feed(bytes)
        let copy = first
        first.feed(Array("Z".utf8))

        #expect(copy == second)
        #expect(first != copy)
    }

    @Test("arbitrary terminal bytes recover after CAN and print a sentinel")
    func deterministicTerminalFuzzRecovery() throws {
        // Intent: exercise the integrated decoder, absorber, controls, and grid
        //   with arbitrary bytes, then prove useful output resumes.
        // Why it exists: stream-only fuzz cannot detect a valid action that
        //   violates cursor or wide-cell mutation bounds in the terminal.
        // Scenario: deterministic untrusted PTY blobs are canceled before a
        //   final sentinel that must remain visible in the viewport.
        for seed in UInt64(1)...256 {
            var generator = Generator(state: seed)
            var terminal = try #require(Terminal(columns: 7, rows: 3))
            terminal.feed((0..<128).map { _ in generator.next() })
            terminal.feed([0x18, 0x7C])

            #expect(terminal.screenText.contains("|"))
            expectValidGrid(terminal)
        }
    }

    @Test("CSI-biased terminal bytes recover after CAN and preserve grid validity")
    func csiBiasedTerminalFuzzRecovery() throws {
        // Intent: stress CSI collection and interpreted mutation with an
        //   escape-, parameter-, separator-, and final-heavy byte alphabet.
        // Why it exists: uniformly arbitrary input rarely reaches the parser
        //   states and erase boundaries most likely to expose grid corruption.
        // Scenario: deterministic adversarial PTY traffic is canceled before
        //   a printable sentinel that must survive in a structurally valid grid.
        let byteAlphabet: [[UInt8]] = [
            0x1B, 0x5B, 0x30, 0x31, 0x32, 0x39, 0x3A, 0x3B, 0x3F,
            0x20, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x48, 0x4A,
            0x4B, 0x4C, 0x4D, 0x50, 0x53, 0x54, 0x58, 0x60, 0x64,
            0x66, 0x67, 0x68, 0x6A, 0x6B, 0x6C, 0x72, 0x73,
            0x75, 0x18, 0x1A, 0x7F,
        ].map { [$0] }
        let sgrFragments = [
            Array("\u{1B}[m".utf8),
            Array("\u{1B}[1;2;3;4:3;7;8;9m".utf8),
            Array("\u{1B}[38;5;200m".utf8),
            Array("\u{1B}[48:2::1:2:3m".utf8),
        ]
        let sliceSixFragments = [
            Array("\u{1B}[2;3r".utf8),
            Array("\u{1B}[S\u{1B}[T".utf8),
            Array("\u{1B}[@\u{1B}[P\u{1B}[L\u{1B}[M".utf8),
            Array("\u{1B}[3J\u{1B}D\u{1B}E\u{1B}M".utf8),
        ]
        let modeFragments = [
            Array("\u{1B}[4h\u{1B}[4l".utf8),
            Array("\u{1B}[20h\u{1B}[20l".utf8),
            Array("\u{1B}[?6h\u{1B}[?6l".utf8),
            Array("\u{1B}[?7l\u{1B}[?7h".utf8),
        ]
        let tabAndSaveFragments = [
            Array("\u{1B}H\u{1B}[3g".utf8),
            Array("\u{1B}7\u{1B}8".utf8),
            Array("\u{1B}[s\u{1B}[u".utf8),
            Array("\u{1B}[?1048h\u{1B}[?1048l".utf8),
        ]
        let alphabet = byteAlphabet + sgrFragments + sliceSixFragments + modeFragments
            + tabAndSaveFragments
        for seed in UInt64(1)...256 {
            var generator = Generator(state: seed)
            var terminal = try #require(Terminal(columns: 7, rows: 3))
            for fragment in sgrFragments + sliceSixFragments + modeFragments
                + tabAndSaveFragments + (0..<256).map({ _ in
                alphabet[Int(generator.next()) % alphabet.count]
            }) {
                terminal.feed(fragment)
            }
            terminal.feed([0x18, 0x7C])

            #expect(terminal.screenText.contains("|"))
            expectValidGrid(terminal)
        }
    }

    private func run(chunks: [[UInt8]]) throws -> Terminal {
        var terminal = try #require(Terminal(columns: 3, rows: 3))
        for chunk in chunks {
            terminal.feed(chunk)
        }
        return terminal
    }

    private struct Generator {
        var state: UInt64

        mutating func next() -> UInt8 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        }
    }
}
