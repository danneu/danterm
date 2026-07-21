// Proves semantic SGR pen interpretation independently of cell storage and rendering.
import Testing

@testable import TerminalCore

/// Locks presentation-state parsing to semantic colors and independent attributes.
struct TerminalStyleTests {
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
        #expect(terminal.geometry.rows.indices.contains { row in
            terminal.geometry.rows[row].cells.indices.contains { column in
                terminal.cell(row: row, column: column)?.style == styled
            }
        })

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
}
