// Proves semantic SGR pen interpretation independently of cell storage and rendering.
import Testing

@testable import TerminalCore

/// Locks presentation-state parsing to semantic colors and independent attributes.
struct TerminalStyleTests {
    @Test("viewport traversal exposes maximally coalesced live style segments")
    func viewportStyleSegments() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 1))
        terminal.feed(Array("\u{1B}[31mab\u{1B}[0mcd".utf8))

        var segments: [(columns: Range<Int>, style: TerminalStyle)] = []
        terminal.forEachViewportRow(rows: 0..<1) { _, visit in
            visit { columns, style, visitCells in
                segments.append((columns, style))
                visitCells { _, _, _ in }
            }
        }

        #expect(segments.map(\.columns) == [0..<2, 2..<6])
        #expect(segments[0].style == TerminalStyle(foreground: .indexed(1)))
        #expect(segments[1].style == TerminalStyle())
    }

    @Test("SGR empty and zero parameters reset the current style")
    func reset() throws {
        var terminal = try #require(Terminal(columns: 2, rows: 1))

        terminal.feed(Array("\u{1B}[1;2;3;4;7;8;9;31;42m".utf8))
        #expect(terminal.currentStyle != TerminalStyle())

        terminal.feed(Array("\u{1B}[m".utf8))
        #expect(terminal.currentStyle == TerminalStyle())

        terminal.feed(Array("\u{1B}[1;31m\u{1B}[0m".utf8))
        #expect(terminal.currentStyle == TerminalStyle())
    }

    @Test("SGR attributes set and clear independently")
    func attributes() throws {
        var terminal = try #require(Terminal(columns: 2, rows: 1))

        terminal.feed(Array("\u{1B}[1;2;3;4;7;8;9m".utf8))
        #expect(terminal.currentStyle.bold)
        #expect(terminal.currentStyle.dim)
        #expect(terminal.currentStyle.italic)
        #expect(terminal.currentStyle.underline == .single)
        #expect(terminal.currentStyle.reverse)
        #expect(terminal.currentStyle.hidden)
        #expect(terminal.currentStyle.strikethrough)

        terminal.feed(Array("\u{1B}[22;23;24;27;28;29m".utf8))
        #expect(terminal.currentStyle == TerminalStyle())
    }

    @Test("an over-long SGR applies its first 24 parameters")
    func overLongSequenceTruncates() throws {
        // Intent: an SGR past the parser's parameter cap still applies everything that fits,
        //   and applies nothing past the cap.
        // Why it exists: the parser used to drop such a sequence whole, so one extra
        //   parameter left the previous pen in force with no sign anything was lost.
        // Scenario: a generator emits bold, an RGB foreground, a long run of italic, and a
        //   final reverse that sits one parameter past the cap.
        var terminal = try #require(Terminal(columns: 2, rows: 1))

        let fitting = ["1", "38", "2", "10", "20", "30"] + Array(repeating: "3", count: 18)
        terminal.feed(Array("\u{1B}[\((fitting + ["7"]).joined(separator: ";"))m".utf8))

        #expect(terminal.currentStyle.bold)
        #expect(terminal.currentStyle.italic)
        #expect(terminal.currentStyle.foreground == .rgb(red: 10, green: 20, blue: 30))
        #expect(terminal.currentStyle.reverse == false)
    }

    @Test("SGR underline variants honor colon groups and legacy double underline")
    func underlineVariants() throws {
        var terminal = try #require(Terminal(columns: 2, rows: 1))

        for (sequence, expected) in [
            ("\u{1B}[4m", TerminalUnderlineStyle.single),
            ("\u{1B}[4:0m", .none),
            ("\u{1B}[4:1m", .single),
            ("\u{1B}[4:2m", .double),
            ("\u{1B}[4:3m", .curly),
            ("\u{1B}[4:4m", .dotted),
            ("\u{1B}[4:5m", .dashed),
            ("\u{1B}[4:99m", .single),
            ("\u{1B}[21m", .double),
        ] {
            terminal.feed(Array(sequence.utf8))
            #expect(terminal.currentStyle.underline == expected)
        }
    }

    @Test("SGR base and bright colors stay semantic")
    func semanticPaletteColors() throws {
        var terminal = try #require(Terminal(columns: 2, rows: 1))

        for index in 0..<8 {
            terminal.feed(Array("\u{1B}[\(30 + index);\(40 + index)m".utf8))
            #expect(terminal.currentStyle.foreground == .indexed(UInt8(index)))
            #expect(terminal.currentStyle.background == .indexed(UInt8(index)))

            terminal.feed(Array("\u{1B}[\(90 + index);\(100 + index)m".utf8))
            #expect(terminal.currentStyle.foreground == .indexed(UInt8(index + 8)))
            #expect(terminal.currentStyle.background == .indexed(UInt8(index + 8)))
        }

        terminal.feed(Array("\u{1B}[39;49m".utf8))
        #expect(terminal.currentStyle.foreground == .default)
        #expect(terminal.currentStyle.background == .default)
    }

    @Test("SGR extended colors accept semicolon and both colon RGB forms")
    func extendedColors() throws {
        var terminal = try #require(Terminal(columns: 2, rows: 1))

        terminal.feed(Array("\u{1B}[38;5;200;48;2;1;2;3m".utf8))
        #expect(terminal.currentStyle.foreground == .indexed(200))
        #expect(terminal.currentStyle.background == .rgb(red: 1, green: 2, blue: 3))

        terminal.feed(Array("\u{1B}[38:2:4:5:6;48:2::7:8:9m".utf8))
        #expect(terminal.currentStyle.foreground == .rgb(red: 4, green: 5, blue: 6))
        #expect(terminal.currentStyle.background == .rgb(red: 7, green: 8, blue: 9))

        terminal.feed(Array("\u{1B}[38:5:201;48:5:202m".utf8))
        #expect(terminal.currentStyle.foreground == .indexed(201))
        #expect(terminal.currentStyle.background == .indexed(202))
    }

    @Test("SGR color components truncate modulo 256")
    func componentTruncation() throws {
        var terminal = try #require(Terminal(columns: 2, rows: 1))

        terminal.feed(Array("\u{1B}[38;2;256;257;65535;48:5:511m".utf8))

        #expect(terminal.currentStyle.foreground == .rgb(red: 0, green: 1, blue: 255))
        #expect(terminal.currentStyle.background == .indexed(255))
    }

    @Test("SGR underline colors stay independent through shape resets and full reset")
    func underlineColors() throws {
        var terminal = try #require(Terminal(columns: 2, rows: 1))
        terminal.feed(Array("\u{1B}[31;4;58;2;1;2;3;1m".utf8))
        #expect(terminal.currentStyle.underlineColor == .rgb(red: 1, green: 2, blue: 3))
        #expect(terminal.currentStyle.bold)

        terminal.feed(Array("\u{1B}[24;58:5:100m".utf8))
        #expect(terminal.currentStyle.underline == .none)
        #expect(terminal.currentStyle.underlineColor == .indexed(100))

        terminal.feed(Array("\u{1B}[4:5;59m".utf8))
        #expect(terminal.currentStyle.underline == .dashed)
        #expect(terminal.currentStyle.underlineColor == .default)

        terminal.feed(Array("\u{1B}[58:2::4:5:6m".utf8))
        #expect(terminal.currentStyle.underlineColor == .rgb(red: 4, green: 5, blue: 6))
        terminal.feed(Array("\u{1B}[0m".utf8))
        #expect(terminal.currentStyle == TerminalStyle())
    }

    @Test("Underline color survives cells saved cursor reflow and malformed recovery")
    func underlineColorRetention() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("\u{1B}[4:4;58:5:42mA\u{1B}7\u{1B}[59mB".utf8))

        let styled = TerminalStyle(
            underline: .dotted,
            underlineColor: .indexed(42)
        )
        #expect(terminal.cell(row: 0, column: 0)?.style == styled)
        #expect(terminal.cell(row: 0, column: 1)?.style.underlineColor == .default)
        terminal.feed(Array("\u{1B}8C".utf8))
        #expect(terminal.cell(row: 0, column: 1)?.style == styled)

        terminal.resize(columns: 2, rows: 2)
        // Row 0 holds "AC": column 0 is the pre-DECSC cell and column 1 is the one the restored
        // pen wrote, which is the cell this test is about. Assert both concretely -- an existential
        // over the grid was satisfied by column 0 alone, so dropping the underline color from the
        // reflowed DECRC cell still passed.
        #expect(terminal.cell(row: 0, column: 0)?.style == styled)
        #expect(terminal.cell(row: 0, column: 1)?.style == styled)

        terminal.feed(Array("\u{1B}[58:2:1:2;4:5m".utf8))
        #expect(terminal.currentStyle.underline == .dashed)
        #expect(terminal.currentStyle.underlineColor == .indexed(42))
    }

    @Test("malformed and unknown SGR groups recover for later live parameters")
    func malformedRecovery() throws {
        let sequences: [(String, TerminalColor)] = [
            ("\u{1B}[38;2;1;31m", .default),
            ("\u{1B}[38;7;31m", .indexed(1)),
            ("\u{1B}[38:2:1:2;31m", .indexed(1)),
            ("\u{1B}[999:1:2;31m", .indexed(1)),
        ]

        for (sequence, expected) in sequences {
            var terminal = try #require(Terminal(columns: 2, rows: 1))
            terminal.feed(Array(sequence.utf8))
            #expect(terminal.currentStyle.foreground == expected)
        }
    }

    @Test("unknown SGR color selector is consumed atomically and recovery continues")
    func unknownColorSelectorIsInert() throws {
        // Intent: an unknown selector in a colon color group leaves the pen unchanged and
        //   does not prevent a later valid SGR parameter in the same sequence from applying.
        // Why it exists: pins maximal colon-group consumption so selector members cannot
        //   escape malformed SGR 58 groups and become standalone presentation attributes.
        // Scenario: an application emits `CSI 58:4:` while a styled pen is active, then
        //   follows it with a valid foreground color in the same CSI sequence.
        var terminal = try #require(Terminal(columns: 2, rows: 1))
        terminal.feed(Array("\u{1B}[1;3;4:5;31;42;58:5:7m".utf8))
        let styled = terminal.currentStyle

        terminal.feed(Array("\u{1B}[58:4:m".utf8))
        #expect(terminal.currentStyle == styled)

        terminal.feed(Array("\u{1B}[58:4:;32m".utf8))
        #expect(terminal.currentStyle == TerminalStyle(
            foreground: .indexed(2),
            background: .indexed(2),
            bold: true,
            italic: true,
            underline: .dashed,
            underlineColor: .indexed(7)
        ))
    }

    @Test("empty SGR parameters reset wherever they appear")
    func emptyParameters() throws {
        var terminal = try #require(Terminal(columns: 2, rows: 1))

        terminal.feed(Array("\u{1B}[1;44m\u{1B}[;31m".utf8))
        #expect(terminal.currentStyle == TerminalStyle(foreground: .indexed(1)))

        terminal.feed(Array("\u{1B}[1;32;44m\u{1B}[31;;41m".utf8))
        #expect(terminal.currentStyle == TerminalStyle(background: .indexed(1)))

        terminal.feed(Array("\u{1B}[31;m".utf8))
        #expect(terminal.currentStyle == TerminalStyle())
    }

    @Test("ignored SGR parameters do not mutate presentation state")
    func consumedIgnoredParameters() throws {
        var terminal = try #require(Terminal(columns: 2, rows: 1))
        terminal.feed(Array("\u{1B}[31m".utf8))
        let expected = terminal.currentStyle

        terminal.feed(Array("\u{1B}[5;25;10;19;73;74;75;1234m".utf8))

        #expect(terminal.currentStyle == expected)
    }

    @Test("SGR with intermediate bytes is dropped")
    func intermediateBytesAreDropped() throws {
        var terminal = try #require(Terminal(columns: 2, rows: 1))
        terminal.feed(Array("\u{1B}[31m".utf8))
        let expected = terminal

        terminal.feed(Array("\u{1B}[32$m".utf8))

        #expect(terminal == expected)
    }

    @Test("SGR preserves pending wrap and open grapheme assembly")
    func nonPenStateSurvives() throws {
        var pending = try #require(Terminal(columns: 2, rows: 2))
        pending.feed(Array("AB".utf8))
        let geometry = pending.geometry
        pending.feed(Array("\u{1B}[31m".utf8))
        #expect(pending.geometry == geometry)

        var cluster = try #require(Terminal(columns: 2, rows: 1))
        cluster.feed(Array("e\u{1B}[31m\u{301}".utf8))
        #expect(cluster.cell(row: 0, column: 0)?.scalars == ["e", "\u{301}"])
    }

    @Test("SGR terminal state is invariant across every chunk split")
    func chunkBoundaryInvariance() throws {
        let bytes = Array("A\u{1B}[1;4:3;38;2;257;2;3;48:2::4:5:6mB\u{1B}[31;mC".utf8)
        var expected = try #require(Terminal(columns: 4, rows: 2))
        expected.feed(bytes)

        for split in 0...bytes.count {
            var terminal = try #require(Terminal(columns: 4, rows: 2))
            terminal.feed(Array(bytes[..<split]))
            terminal.feed(Array(bytes[split...]))
            #expect(terminal == expected)
        }

        var bytewise = try #require(Terminal(columns: 4, rows: 2))
        for byte in bytes {
            bytewise.feed([byte])
        }
        #expect(bytewise == expected)
    }

    @Test("DECSCA parameters arm, disarm, or leave the pen alone", arguments: [
        ("\u{1B}[1\"q", true),
        ("\u{1B}[\"q", false),
        ("\u{1B}[0\"q", false),
        ("\u{1B}[2\"q", false),
    ])
    func characterProtectionParameters(sequence: String, expected: Bool) throws {
        var terminal = try #require(Terminal(columns: 2, rows: 1))

        terminal.feed(Array(sequence.utf8))
        #expect(terminal.currentStyle.protected == expected)
    }

    @Test("an unrecognized DECSCA parameter leaves protection as it was")
    func characterProtectionIgnoresUnknownParameters() throws {
        var terminal = try #require(Terminal(columns: 2, rows: 1))

        terminal.feed(Array("\u{1B}[1\"q\u{1B}[3\"q".utf8))
        #expect(terminal.currentStyle.protected)

        terminal.feed(Array("\u{1B}[0\"q\u{1B}[99\"q".utf8))
        #expect(terminal.currentStyle.protected == false)
    }

    @Test("every character cell printed under an armed pen is protected")
    func characterProtectionRidesEveryPrintedCell() throws {
        // Intent: narrow cells and both halves of a wide pair carry the pen's protection.
        // Why it exists: a protected wide head with an unprotected tail would let a later
        //   selective erase split the pair and leave a tail with no head.
        // Scenario: a program arms DECSCA and draws a field holding a wide character.
        var terminal = try #require(Terminal(columns: 4, rows: 1))

        terminal.feed(Array("\u{1B}[1\"qa\u{754C}".utf8))

        #expect(terminal.cell(row: 0, column: 0)?.style.protected == true)
        #expect(terminal.cell(row: 0, column: 1)?.kind == .wideHead)
        #expect(terminal.cell(row: 0, column: 1)?.style.protected == true)
        #expect(terminal.cell(row: 0, column: 2)?.kind == .wideTail)
        #expect(terminal.cell(row: 0, column: 2)?.style.protected == true)

        terminal.feed(Array("\u{1B}[0\"qb".utf8))
        #expect(terminal.cell(row: 0, column: 3)?.style.protected == false)

        // A wide character that does not fit the margin lands on the next row, and both of its
        // cells must still carry the pen the print started with.
        var wrapping = try #require(Terminal(columns: 3, rows: 2))
        wrapping.feed(Array("\u{1B}[1\"qab\u{754C}".utf8))
        #expect(wrapping.cell(row: 0, column: 2)?.kind == .spacerHead)
        #expect(wrapping.cell(row: 1, column: 0)?.kind == .wideHead)
        #expect(wrapping.cell(row: 1, column: 0)?.style.protected == true)
        #expect(wrapping.cell(row: 1, column: 1)?.style.protected == true)
    }

    @Test("SGR and DECSCA leave each other alone")
    func characterProtectionIsIndependentOfRendition() throws {
        // Intent: SGR 0 keeps protection armed, and DECSCA keeps the rendition attributes.
        // Why it exists: protection is stored on the pen only because every cell writer
        //   already carries the pen; DEC gives SGR no way to clear it, so the `sgr0` in a
        //   prompt must not silently disarm a field the program protected.
        // Scenario: a program arms protection, then resets its colors between fields.
        var terminal = try #require(Terminal(columns: 4, rows: 1))

        terminal.feed(Array("\u{1B}[1\"q\u{1B}[1;31m".utf8))
        #expect(terminal.currentStyle.protected)
        #expect(terminal.currentStyle.bold)

        terminal.feed(Array("\u{1B}[0m".utf8))
        #expect(terminal.currentStyle == TerminalStyle(protected: true))

        terminal.feed(Array("\u{1B}[m".utf8))
        #expect(terminal.currentStyle == TerminalStyle(protected: true))

        terminal.feed(Array("\u{1B}[31m\u{1B}[0\"q".utf8))
        #expect(terminal.currentStyle == TerminalStyle(foreground: .indexed(1)))
    }

    @Test("a combining mark keeps its base cell's protection")
    func characterProtectionSurvivesClusterGrowth() throws {
        var terminal = try #require(Terminal(columns: 2, rows: 1))

        terminal.feed(Array("\u{1B}[1\"qe\u{1B}[0\"q\u{301}".utf8))

        #expect(terminal.cell(row: 0, column: 0)?.scalars == ["e", "\u{301}"])
        #expect(terminal.cell(row: 0, column: 0)?.style.protected == true)
    }

    @Test("DECALN fills unprotected cells and keeps the pen armed")
    func alignmentFillIgnoresProtection() throws {
        // Intent: `ESC # 8` writes ordinary `E`s over protected content and leaves DECSCA set.
        // Why it exists: DECALN reduces the pen to its colors, and protection is not a
        //   rendition, so that reduction must not reach it -- while the fill is plain text.
        // Scenario: a program protects a field, then runs the alignment pattern.
        var terminal = try #require(Terminal(columns: 3, rows: 2))
        terminal.feed(Array("\u{1B}[1\"q\u{1B}[31mAB".utf8))

        terminal.feed(Array("\u{1B}#8".utf8))

        #expect(terminal.cell(row: 0, column: 0)?.scalars == ["E"])
        #expect(terminal.cell(row: 0, column: 0)?.style.protected == false)
        #expect(terminal.currentStyle == TerminalStyle(
            foreground: .indexed(1),
            protected: true
        ))

        terminal.feed(Array("Z".utf8))
        #expect(terminal.cell(row: 0, column: 0)?.style.protected == true)
    }

    @Test("cell-moving operations carry protection with the cells they move")
    func characterProtectionMovesWithCells() throws {
        // Intent: ICH, DCH, IL, DL, a scroll into history, and a width reflow all keep a
        //   protected run protected, and leave the cells they create unprotected.
        // Why it exists: protection rides the interned style id, so every one of these paths
        //   should be free -- this is the proof that none of them rebuilds a cell by hand.
        // Scenario: a protected field is pushed around by editing, scrolling, and a resize.
        var editing = try #require(Terminal(columns: 6, rows: 2))
        editing.feed(Array("\u{1B}[1\"qAB\u{1B}[0\"q".utf8))
        editing.feed(Array("\u{1B}[1;1H\u{1B}[2@".utf8))
        #expect(editing.cell(row: 0, column: 0)?.style.protected == false)
        #expect(editing.cell(row: 0, column: 2)?.scalars == ["A"])
        #expect(editing.cell(row: 0, column: 2)?.style.protected == true)

        editing.feed(Array("\u{1B}[1;1H\u{1B}[1P".utf8))
        #expect(editing.cell(row: 0, column: 1)?.scalars == ["A"])
        #expect(editing.cell(row: 0, column: 1)?.style.protected == true)

        editing.feed(Array("\u{1B}[1;1H\u{1B}[1L".utf8))
        #expect(editing.cell(row: 0, column: 1)?.style.protected == false)
        #expect(editing.cell(row: 1, column: 1)?.style.protected == true)

        editing.feed(Array("\u{1B}[1;1H\u{1B}[1M".utf8))
        #expect(editing.cell(row: 0, column: 1)?.style.protected == true)

        var scrolling = try #require(Terminal(columns: 4, rows: 1))
        scrolling.feed(Array("\u{1B}[1\"qP\u{1B}[0\"q\r\nQ".utf8))
        let retained = try #require(scrolling.scrollbackRow(at: 0))
        #expect(retained.cells[0].scalars == ["P"])
        #expect(retained.cells[0].style.protected)

        var reflow = try #require(Terminal(columns: 4, rows: 2))
        reflow.feed(Array("\u{1B}[1\"qab\u{754C}\u{1B}[0\"q".utf8))
        reflow.resize(columns: 3, rows: 2)
        let folded = try #require(reflow.scrollbackRow(at: 0))
        #expect(folded.cells[0].scalars == ["a"])
        #expect(folded.cells[0].style.protected)
        #expect(reflow.cell(row: 0, column: 0)?.kind == .wideHead)
        #expect(reflow.cell(row: 0, column: 0)?.style.protected == true)
        #expect(reflow.cell(row: 0, column: 1)?.style.protected == true)
    }
}
