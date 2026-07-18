// Proves that semantic pen state is stamped onto cells and survives structural movement.
import Testing

@testable import TerminalCore

/// Locks cell presentation across writing, erasure, scrolling, and grid transformations.
struct TerminalCellStyleTests {
    @Test(
        "EL, ED, and ECH stamp only the current colors onto erased cells",
        arguments: [
            EraseStyleFixture(sequence: "\u{1B}[K", erasedIndices: [1, 2, 3]),
            EraseStyleFixture(sequence: "\u{1B}[2J", erasedIndices: Array(0..<8)),
            EraseStyleFixture(sequence: "\u{1B}[2X", erasedIndices: [1, 2]),
        ]
    )
    func erasesStampColorsWithoutAttributes(fixture: EraseStyleFixture) throws {
        // Intent: EL, ED, and ECH fill their regions with the pen's foreground
        //   and background while clearing every presentation attribute.
        // Why it exists: reusing the current pen wholesale would make blank
        //   cells bold, underlined, reversed, hidden, or struck through.
        // Scenario: a decorated application clears part or all of its viewport.
        let eraseStyle = TerminalStyle(foreground: .indexed(1), background: .indexed(4))
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("ABCDEFGH".utf8))
        terminal.moveCursor(row: 0, column: 1)

        terminal.feed(Array(
            "\u{1B}[1;2;3;4:3;7;8;9;31;44m\(fixture.sequence)".utf8
        ))

        let erased = Set(fixture.erasedIndices)
        for index in 0..<8 {
            let cell = try #require(terminal.cell(row: index / 4, column: index % 4))
            if erased.contains(index) {
                #expect(cell.kind == .padding)
                #expect(cell.style == eraseStyle)
            } else {
                #expect(cell.style == TerminalStyle())
            }
        }
        expectValidGrid(terminal)
    }

    @Test("erasing either half of a wide cell applies BCE style to both halves")
    func wideEraseStylesBothCells() throws {
        let eraseStyle = TerminalStyle(foreground: .indexed(1), background: .indexed(4))
        var terminal = try #require(Terminal(columns: 5, rows: 1))
        terminal.feed(Array("A\u{754C}B".utf8))
        terminal.moveCursor(row: 0, column: 2)

        terminal.feed(Array("\u{1B}[1;4;31;44m\u{1B}[X".utf8))

        #expect(terminal.cell(row: 0, column: 1)?.kind == .padding)
        #expect(terminal.cell(row: 0, column: 2)?.kind == .padding)
        #expect(terminal.cell(row: 0, column: 1)?.style == eraseStyle)
        #expect(terminal.cell(row: 0, column: 2)?.style == eraseStyle)
        expectValidGrid(terminal)
    }

    @Test("LF, soft wrap, and wide wrap reveal rows filled with BCE style")
    func scrollOffFillsRevealedRowWithColors() throws {
        // Intent: every route that scrolls the viewport reveals padding with
        //   the active pen colors and no other attributes.
        // Why it exists: LF, deferred soft wrap, and margin-wide wrap share a
        //   scroll primitive but reach it through independent control paths.
        // Scenario: a one-row terminal scrolls while a decorated color pen is active.
        let penSequence = "\u{1B}[1;2;3;4:3;7;8;9;31;44m"
        let penStyle = TerminalStyle(
            foreground: .indexed(1),
            background: .indexed(4),
            bold: true,
            dim: true,
            italic: true,
            underline: .curly,
            reverse: true,
            hidden: true,
            strikethrough: true
        )
        let eraseStyle = TerminalStyle(foreground: .indexed(1), background: .indexed(4))

        var lineFeed = try #require(Terminal(columns: 3, rows: 1))
        lineFeed.feed(Array("\(penSequence)\n".utf8))
        for column in 0..<3 {
            #expect(lineFeed.cell(row: 0, column: column)?.style == eraseStyle)
        }

        var softWrap = try #require(Terminal(columns: 2, rows: 1))
        softWrap.feed(Array("\(penSequence)ABC".utf8))
        #expect(softWrap.cell(row: 0, column: 0)?.style == penStyle)
        #expect(softWrap.cell(row: 0, column: 1)?.style == eraseStyle)

        var wideWrap = try #require(Terminal(columns: 3, rows: 1))
        wideWrap.feed(Array(penSequence.utf8))
        wideWrap.moveCursor(row: 0, column: 2)
        wideWrap.feed(Array("\u{754C}".utf8))
        #expect(wideWrap.cell(row: 0, column: 0)?.style == penStyle)
        #expect(wideWrap.cell(row: 0, column: 1)?.style == penStyle)
        #expect(wideWrap.cell(row: 0, column: 2)?.style == eraseStyle)

        expectValidGrid(lineFeed)
        expectValidGrid(softWrap)
        expectValidGrid(wideWrap)
    }

    @Test("default-pen erase remains bit-identical to default structural clearing")
    func defaultEraseRemainsBitIdentical() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 1))
        terminal.feed(Array("A\u{754C}".utf8))
        terminal.moveCursor(row: 0, column: 2)
        var expected = terminal
        expected.eraseCells(row: 0, columns: 2..<3)

        terminal.feed(Array("\u{1B}[X".utf8))

        #expect(terminal == expected)
    }

    @Test("overwriting half a styled wide pair leaves the vacated cell default styled")
    func structuralWideClearRemainsDefaultStyled() throws {
        // Intent: distinguish ordinary overwrite cleanup from BCE erasure.
        // Why it exists: structural clearing must not inherit either the old
        //   wide cell's style or the current pen used for the replacement.
        // Scenario: colored narrow output overwrites the tail of a differently
        //   colored wide glyph.
        let green = TerminalStyle(foreground: .indexed(2))
        var terminal = try #require(Terminal(columns: 4, rows: 1))
        terminal.feed(Array("\u{1B}[31m\u{754C}\u{1B}[32m".utf8))
        terminal.moveCursor(row: 0, column: 1)

        terminal.feed(Array("X".utf8))

        #expect(terminal.cell(row: 0, column: 0)?.kind == .padding)
        #expect(terminal.cell(row: 0, column: 0)?.style == TerminalStyle())
        #expect(terminal.cell(row: 0, column: 1)?.style == green)
        expectValidGrid(terminal)
    }

    @Test("BCE-only padding remains style-blind during width and height resize")
    func bcePaddingDoesNotBecomeResizeContent() throws {
        // Intent: background-colored padding remains absent from resize's
        //   content model even though public cell inspection exposes its style.
        // Why it exists: treating BCE style as content would retain blank rows
        //   or carry erase colors into resize-synthesized filler.
        // Scenario: an application colors and clears an otherwise empty viewport,
        //   then the user narrows it or shrinks away its trailing blank rows.
        let eraseStyle = TerminalStyle(foreground: .indexed(1), background: .indexed(4))
        let eraseSequence = "\u{1B}[1;4;31;44m\u{1B}[2J"

        var width = try #require(Terminal(columns: 4, rows: 2))
        width.feed(Array(eraseSequence.utf8))
        #expect(width.cell(row: 0, column: 0)?.style == eraseStyle)

        width.resize(columns: 2, rows: 2)

        for row in 0..<2 {
            for column in 0..<2 {
                #expect(width.cell(row: row, column: column)?.style == TerminalStyle())
            }
        }
        #expect(width.fullHistoryText == "")

        var height = try #require(Terminal(columns: 4, rows: 3))
        height.feed(Array(eraseSequence.utf8))

        height.resize(columns: 4, rows: 1)

        #expect(height.scrollbackRowCount == 0)
        for column in 0..<4 {
            #expect(height.cell(row: 0, column: column)?.style == eraseStyle)
        }
        #expect(height.fullHistoryText == "")
    }

    @Test("prints stamp the current style without restyling earlier cells")
    func stampAtPrintTime() throws {
        let decorated = TerminalStyle(
            foreground: .indexed(1),
            background: .indexed(4),
            bold: true,
            dim: true,
            italic: true,
            underline: .curly,
            reverse: true,
            hidden: true,
            strikethrough: true
        )
        let green = TerminalStyle(foreground: .indexed(2))
        let blue = TerminalStyle(foreground: .indexed(4))
        var terminal = try #require(Terminal(columns: 2, rows: 2))

        terminal.feed(Array(
            "\u{1B}[1;2;3;4:3;7;8;9;31;44mA\u{1B}[0;32mB\u{1B}[34mC".utf8
        ))

        #expect(terminal.cell(row: 0, column: 0)?.style == decorated)
        #expect(terminal.cell(row: 0, column: 1)?.style == green)
        #expect(terminal.cell(row: 1, column: 0)?.style == blue)
        #expect(terminal.currentStyle == blue)
    }

    @Test("a wide print at the margin gives its spacer, head, and tail one style")
    func widePrintAtMarginKeepsStyleCoherent() throws {
        let red = TerminalStyle(foreground: .indexed(1))
        var terminal = try #require(Terminal(columns: 3, rows: 2))
        terminal.feed(Array("ab\u{1B}[31m\u{754C}".utf8))

        #expect(terminal.cell(row: 0, column: 2)?.style == red)
        #expect(terminal.cell(row: 1, column: 0)?.style == red)
        #expect(terminal.cell(row: 1, column: 1)?.style == red)
        expectValidGrid(terminal)
    }

    @Test("a grapheme cluster keeps its first scalar style across SGR changes")
    func clusterStyleSurvivesContinuationAndWidthChanges() throws {
        let red = TerminalStyle(foreground: .indexed(1))

        var continuation = try #require(Terminal(columns: 4, rows: 1))
        continuation.feed(Array("\u{1B}[31me\u{1B}[32m\u{301}".utf8))
        #expect(continuation.cell(row: 0, column: 0)?.style == red)

        var upgrade = try #require(Terminal(columns: 4, rows: 2))
        upgrade.feed(Array("\u{1B}[31m".utf8))
        upgrade.moveCursor(row: 0, column: 3)
        upgrade.feed(Array("#\u{1B}[32m\u{FE0F}".utf8))
        #expect(upgrade.cell(row: 0, column: 3)?.style == red)
        #expect(upgrade.cell(row: 1, column: 0)?.style == red)
        #expect(upgrade.cell(row: 1, column: 1)?.style == red)

        var downgrade = try #require(Terminal(columns: 4, rows: 1))
        downgrade.feed(Array("\u{1B}[31m\u{00A9}\u{FE0F}\u{1B}[32m\u{FE0E}".utf8))
        #expect(downgrade.cell(row: 0, column: 0)?.style == red)
        #expect(downgrade.cell(row: 0, column: 1)?.style == TerminalStyle())
    }

    @Test("reflow synthesizes coherent styled wide tails and spacer heads")
    func reflowSynthesizedWideCellsKeepStyle() throws {
        // Intent: keep one wide cell's style coherent when reflow rebuilds both
        //   its tail and an odd-width spacer rather than copying either cell.
        // Why it exists: synthesized structural cells otherwise fall back to
        //   default style while their associated wide head remains styled.
        // Scenario: a red wide glyph moves across a four-to-three-column resize.
        let red = TerminalStyle(foreground: .indexed(1))
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("\u{1B}[31mab\u{754C}".utf8))

        terminal.resize(columns: 3, rows: 3)

        #expect(terminal.cell(row: 0, column: 2)?.kind == .spacerHead)
        #expect(terminal.cell(row: 0, column: 2)?.style == red)
        #expect(terminal.cell(row: 1, column: 0)?.style == red)
        #expect(terminal.cell(row: 1, column: 1)?.style == red)
        expectValidGrid(terminal)
    }

    @Test("scrollback and height-width resize preserve mixed cell styles")
    func scrollbackAndResizePreserveStyles() throws {
        let red = TerminalStyle(foreground: .indexed(1))
        let green = TerminalStyle(foreground: .indexed(2))
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("\u{1B}[31mABCD\r\n\u{1B}[32mEFGH\r\n".utf8))

        #expect(terminal.scrollbackRow(at: 0)?.cells.allSatisfy { $0.style == red } == true)
        #expect(terminal.geometry.rows[0].cells.indices.allSatisfy {
            terminal.cell(row: 0, column: $0)?.style == green
        })

        terminal.resize(columns: 4, rows: 1)
        terminal.resize(columns: 4, rows: 3)
        terminal.resize(columns: 2, rows: 3)

        #expect(terminal.scrollbackRow(at: 0)?.cells.allSatisfy { $0.style == red } == true)
        #expect(terminal.scrollbackRow(at: 1)?.cells.allSatisfy { $0.style == red } == true)
        #expect(terminal.geometry.rows[0].cells.indices.allSatisfy {
            terminal.cell(row: 0, column: $0)?.style == green
        })
        #expect(terminal.geometry.rows[1].cells.indices.allSatisfy {
            terminal.cell(row: 1, column: $0)?.style == green
        })
        expectValidGrid(terminal)
    }

    @Test("resize filler remains default styled under a nondefault pen")
    func resizeFillerUsesDefaultStyle() throws {
        let red = TerminalStyle(foreground: .indexed(1))
        var terminal = try #require(Terminal(columns: 4, rows: 1))
        terminal.feed(Array("\u{1B}[31mA".utf8))

        terminal.resize(columns: 6, rows: 3)

        #expect(terminal.cell(row: 0, column: 0)?.style == red)
        for row in 0..<3 {
            for column in 0..<6 where row != 0 || column != 0 {
                #expect(terminal.cell(row: row, column: column)?.style == TerminalStyle())
            }
        }
    }

    struct EraseStyleFixture: Sendable {
        let sequence: String
        let erasedIndices: [Int]
    }
}
