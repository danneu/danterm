// Proves UAX #29 boundaries drive terminal cell assembly, reset behavior, and recovery.
import Testing

@testable import TerminalCore

/// Locks retained grapheme clusters to one cell unit without coupling tests to segmenter internals.
struct TerminalGraphemeTests {
    @Test("representative grapheme sequences assemble into one cell unit")
    func representativeAssembly() throws {
        let fixtures: [(text: String, kind: TerminalCellKind)] = [
            ("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", .wideHead),
            ("\u{1F44D}\u{1F3FD}", .wideHead),
            ("\u{1F1FA}\u{1F1F8}", .wideHead),
            ("#\u{FE0F}\u{20E3}", .wideHead),
            ("\u{0915}\u{094D}\u{200D}\u{0915}", .wideHead),
        ]

        for fixture in fixtures {
            var terminal = try #require(Terminal(columns: 12, rows: 2))
            terminal.feed(Array(fixture.text.utf8))

            #expect(terminal.cell(row: 0, column: 0)?.kind == fixture.kind)
            #expect(terminal.cell(row: 0, column: 0)?.scalars == Array(fixture.text.unicodeScalars))
            #expect(terminal.screenText.contains(fixture.text))
        }
    }

    @Test("a third Regional Indicator starts a new cluster")
    func regionalIndicatorParity() throws {
        var terminal = try #require(Terminal(columns: 7, rows: 1))

        terminal.feed(Array("\u{1F1E6}\u{1F1E7}\u{1F1E8}".utf8))

        #expect(terminal.cell(row: 0, column: 0)?.scalars == ["\u{1F1E6}", "\u{1F1E7}"])
        #expect(terminal.cell(row: 0, column: 2)?.scalars == ["\u{1F1E8}"])
    }

    @Test("soft wrap starts the next grapheme with fresh break state")
    func softWrapResetsLookBehind() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.moveCursor(row: 0, column: 2)

        terminal.feed(Array("\u{1F1E6}\u{1F1E7}\u{1F1E8}\u{1F1E9}".utf8))

        #expect(terminal.cell(row: 0, column: 2)?.scalars == ["\u{1F1E6}", "\u{1F1E7}"])
        #expect(terminal.cell(row: 1, column: 0)?.scalars == ["\u{1F1E8}", "\u{1F1E9}"])
        #expect(terminal.geometry.rows[0].isSoftWrapped)
    }

    @Test("non-joining zero-width scalars are invisible to the open cluster")
    func droppedScalarLeavesContextUntouched() throws {
        // Intent: prove a discarded zero-width break neither enters storage nor
        //   replaces the preceding retained scalar for the next break decision.
        // Why it exists: committing segmenter state before the drop would make a
        //   following combining mark start defectively and disappear as well.
        // Scenario: a shell prints A, an isolated ZWSP, then an acute accent that
        //   must still attach to A exactly as if the ZWSP had never arrived.
        var dropped = try #require(Terminal(columns: 4, rows: 1))
        var direct = try #require(Terminal(columns: 4, rows: 1))

        dropped.feed(Array("A\u{200B}\u{0301}".utf8))
        direct.feed(Array("A\u{0301}".utf8))

        #expect(dropped == direct)
        #expect(dropped.cell(row: 0, column: 0)?.scalars == ["A", "\u{0301}"])
    }

    @Test("leading Extend and ZWJ scalars drop without moving terminal state")
    func leadingZeroWidthScalarsDrop() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 1))
        let initial = terminal

        terminal.feed(Array("\u{0301}\u{200D}".utf8))

        #expect(terminal == initial)
    }

    @Test("invalid variation selectors remain scalar-exact without changing width")
    func invalidVariationSelectorsAreStored() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 1))

        terminal.feed(Array("A\u{FE0E}\u{FE0F}".utf8))

        #expect(terminal.cell(row: 0, column: 0)?.scalars == ["A", "\u{FE0E}", "\u{FE0F}"])
        #expect(terminal.geometry.rows[0].cells.map(\.kind) == [.narrow, .padding, .padding, .padding])
    }

    @Test("motion and mutating erases break an open grapheme cluster")
    func resetEventsBreakCluster() throws {
        // Intent: verify every existing attachment-reset family also resets the
        //   UAX #29 look-behind before the next printable scalar.
        // Why it exists: retaining only the target reset while leaking segmenter
        //   state can make the next emoji join according to stale ZWJ or RI history.
        // Scenario: terminal motion or erase interrupts A + ZWJ before an emoji;
        //   the emoji must print as a new cluster at the post-action cursor.
        let fixtures: [(bytes: [UInt8], row: Int, column: Int)] = [
            ([0x08], 0, 0),
            ([0x0D], 0, 0),
            ([0x0A], 1, 1),
            ([0x0B], 1, 1),
            ([0x0C], 1, 1),
            ([0x09], 0, 8),
            ([0x1B, 0x5B, 0x43], 0, 2),
            ([0x1B, 0x5B, 0x58], 0, 1),
        ]

        for fixture in fixtures {
            var terminal = try #require(Terminal(columns: 12, rows: 2))
            terminal.feed(Array("A\u{200D}".utf8))
            terminal.feed(fixture.bytes)
            terminal.feed(Array("\u{1F469}".utf8))

            #expect(terminal.cell(row: fixture.row, column: fixture.column)?.scalars == ["\u{1F469}"])
        }
    }

    @Test("bit-identical no-op events preserve an open grapheme cluster")
    func noOpEventsPreserveCluster() throws {
        let noOps: [[UInt8]] = [
            [0x00],
            [0x1B, 0x5B, 0x33, 0x4A],
            [0x1B, 0x5B, 0x6D],
        ]

        for bytes in noOps {
            var terminal = try #require(Terminal(columns: 8, rows: 1))
            terminal.feed(Array("\u{1F468}\u{200D}".utf8))
            terminal.feed(bytes)
            terminal.feed(Array("\u{1F469}".utf8))

            #expect(terminal.cell(row: 0, column: 0)?.scalars == [
                "\u{1F468}", "\u{200D}", "\u{1F469}",
            ])
        }
    }

    @Test("cursor movement drops a later combining mark and resets RI parity")
    func cursorMovementResetsLookBehind() throws {
        var combining = try #require(Terminal(columns: 6, rows: 1))
        combining.feed(Array("A".utf8))
        combining.moveCursor(row: 0, column: 2)
        combining.feed(Array("\u{0301}".utf8))
        #expect(combining.cell(row: 0, column: 0)?.scalars == ["A"])
        #expect(combining.cell(row: 0, column: 2)?.scalars == [])

        var regionalIndicators = try #require(Terminal(columns: 6, rows: 1))
        regionalIndicators.feed(Array("\u{1F1E6}".utf8))
        regionalIndicators.moveCursor(row: 0, column: 1)
        regionalIndicators.feed(Array("\u{1F1E7}\u{1F1E8}".utf8))
        #expect(regionalIndicators.cell(row: 0, column: 1)?.scalars == [
            "\u{1F1E7}", "\u{1F1E8}",
        ])
    }

    @Test("malformed UTF-8 participates in grapheme breaking by replacement class")
    func malformedReplacementBreaksAndRecovers() throws {
        // Intent: prove U+FFFD follows ordinary grapheme rules while later emoji
        //   assembly remains usable after malformed input.
        // Why it exists: special reset handling for decoder replacements would
        //   disagree with both UAX #29 and the terminal's retained-scalar stream.
        // Scenario: malformed PTY bytes interrupt A + ZWJ, a mark decorates the
        //   replacement, then a valid family sequence arrives intact.
        var terminal = try #require(Terminal(columns: 12, rows: 1))
        terminal.feed(Array("A\u{200D}".utf8) + [0x80] + Array("\u{0301}\u{1F468}\u{200D}\u{1F469}".utf8))

        #expect(terminal.cell(row: 0, column: 0)?.scalars == ["A", "\u{200D}"])
        #expect(terminal.cell(row: 0, column: 1)?.scalars == ["\u{FFFD}", "\u{0301}"])
        #expect(terminal.cell(row: 0, column: 2)?.scalars == [
            "\u{1F468}", "\u{200D}", "\u{1F469}",
        ])

        var prepend = try #require(Terminal(columns: 4, rows: 1))
        prepend.feed(Array("\u{0D4E}".utf8) + [0x80])
        #expect(prepend.cell(row: 0, column: 0)?.scalars == ["\u{0D4E}", "\u{FFFD}"])
    }

    @Test("clustered wide cells overwrite, erase, and scroll atomically")
    func clusteredWideCellAtomicity() throws {
        let family = "\u{1F468}\u{200D}\u{1F469}"

        for targetColumn in [0, 1] {
            var terminal = try #require(Terminal(columns: 4, rows: 1))
            terminal.feed(Array(family.utf8))
            terminal.moveCursor(row: 0, column: targetColumn)
            terminal.feed(Array("X".utf8))

            #expect(terminal.geometry.rows[0].cells[0].kind == (targetColumn == 0 ? .narrow : .padding))
            #expect(terminal.geometry.rows[0].cells[1].kind == (targetColumn == 1 ? .narrow : .padding))
            expectValidGrid(terminal)
        }

        var erased = try #require(Terminal(columns: 4, rows: 1))
        erased.feed(Array(family.utf8))
        erased.eraseCells(row: 0, columns: 1..<2)
        #expect(erased.geometry.rows[0].cells.prefix(2).allSatisfy { $0.kind == .padding })
        expectValidGrid(erased)

        var scrolled = try #require(Terminal(columns: 4, rows: 2))
        scrolled.feed(Array(family.utf8))
        scrolled.feed([0x0A, 0x0A])
        #expect(scrolled.screenText.contains(family) == false)
        expectValidGrid(scrolled)
    }

    @Test("grapheme-biased terminal bytes recover and preserve grid validity")
    func graphemeBiasedFuzzRecovery() throws {
        // Intent: stress retained cluster state with emoji, RI, selectors,
        //   controls, malformed prefixes, and CSI introducers before a sentinel.
        // Why it exists: uniformly random bytes rarely sustain the pairwise
        //   histories that expose stale targets or invalid wide-cell mutations.
        // Scenario: deterministic adversarial PTY tokens end with CAN and a
        //   printable sentinel that must survive in a structurally valid grid.
        let alphabet: [[UInt8]] = [
            Array("\u{1F1E6}".utf8), Array("\u{1F1E7}".utf8),
            Array("\u{200D}".utf8), Array("\u{FE0E}".utf8), Array("\u{FE0F}".utf8),
            Array("\u{1F3FD}".utf8), Array("\u{1F468}".utf8), Array("\u{0301}".utf8),
            [0x80], [0x08], [0x0A], [0x0D], [0x1B], [0x5B], [0x58],
        ]

        for seed in UInt64(1)...128 {
            var generator = Generator(state: seed)
            var terminal = try #require(Terminal(columns: 7, rows: 3))
            var bytes: [UInt8] = []
            for _ in 0..<128 {
                bytes.append(contentsOf: alphabet[Int(generator.next()) % alphabet.count])
            }
            terminal.feed(bytes + [0x18, 0x7C])

            #expect(terminal.screenText.unicodeScalars.contains("|"))
            expectValidGrid(terminal)
        }
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
