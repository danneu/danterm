// Covers `Terminal.rowStructure`, the read-only line-structure projection that lets a caller
// outside the engine check wrap and reflow invariants without reading cells or text.
//
// Not a place for cell-content or styling assertions: this projection deliberately reports only
// where a logical line ends and how far its content reaches.
import Testing
@testable import TerminalCore

@Suite("Terminal row structure")
struct TerminalRowStructureTests {
    @Test("A hard-ended line reports no wrap and its own content end")
    func hardEndedLine() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("ab\r\ncd\r\n".utf8))

        let structure = terminal.rowStructure
        #expect(structure.count == 3)
        #expect(structure[0].isSoftWrapped == false)
        #expect(structure[0].contentEnd == 2)
        #expect(structure[1].isSoftWrapped == false)
        #expect(structure[1].contentEnd == 2)
        #expect(structure.allSatisfy { $0.isRetained == false })
    }

    @Test("An autowrapped line reports a wrap whose content fills the row")
    func autowrappedLine() throws {
        // Intent: pin that the projection reports the invariant a real autowrap satisfies --
        //   the wrapping row's content reaches the last column.
        // Why it exists: the projection's whole purpose is to make `isSoftWrapped == true`
        //   with `contentEnd < width` recognizable as impossible from outside the engine, so
        //   the honest case has to be pinned alongside it.
        // Scenario: a program prints past the right margin and the terminal wraps.
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("abcdef".utf8))

        let structure = terminal.rowStructure
        #expect(structure[0].isSoftWrapped)
        #expect(structure[0].contentEnd == structure[0].width)
        #expect(structure[1].isSoftWrapped == false)
        #expect(structure[1].contentEnd == 2)
    }

    @Test("A wide glyph that wraps early reports the spacer it left at the margin")
    func wideGlyphWrapReportsSpacerMargin() throws {
        // Intent: a CJK wrap is distinguishable from a stale wrap claim without reading cells.
        // Why it exists: a wide glyph meeting the last column leaves a `.spacerHead` there and
        //   wraps, so `isSoftWrapped` with `contentEnd == width - 1` is a legitimate print
        //   outcome. An oracle checking only `contentEnd < width` misreads it as spurious;
        //   `marginCellKind` is what lets the check exclude it.
        // Scenario: four narrow cells then U+754C at width 5.
        var terminal = try #require(Terminal(columns: 5, rows: 3))
        terminal.feed(Array("abcd\u{754C}".utf8))

        let structure = terminal.rowStructure
        #expect(structure[0].isSoftWrapped)
        #expect(structure[0].contentEnd == 4)
        #expect(structure[0].marginCellKind == .spacerHead)
        #expect(structure[1].contentEnd == 2)
        #expect(structure[1].marginCellKind == .padding)
    }

    @Test("Rows scrolled off the top are reported as retained, ahead of the live grid")
    func retainedRowsPrecedeLiveRows() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("one\r\ntwo\r\nthree\r\n".utf8))

        let structure = terminal.rowStructure
        let retained = structure.prefix { $0.isRetained }
        #expect(retained.isEmpty == false)
        #expect(structure.dropFirst(retained.count).allSatisfy { $0.isRetained == false })
        #expect(structure.map(\.index) == Array(0..<structure.count))
    }

    @Test("Every row satisfies the wrap invariant across a resize round trip")
    func wrapInvariantSurvivesResize() throws {
        // Intent: assert the property the projection exists to police -- a row that claims to
        //   soft-wrap must have content in its last column.
        // Why it exists: a logical line whose stored cells exceed its content produces correct
        //   output at the width it was built for and garbled output at any other, so the defect
        //   is invisible until a resize. This is the structure-level oracle for that class.
        // Scenario: wrapped and unwrapped output is reflowed narrower and back.
        var terminal = try #require(Terminal(columns: 20, rows: 6))
        terminal.feed(Array("short\r\n".utf8))
        terminal.feed(Array(String(repeating: "x", count: 45).utf8))
        terminal.feed(Array("\r\nshort again\r\n".utf8))

        for width in [9, 20, 37, 20] {
            terminal.resize(columns: width, rows: 6)
            for row in terminal.rowStructure where row.isSoftWrapped {
                #expect(
                    row.contentEnd == row.width,
                    "row \(row.index) claims a wrap with content ending at \(row.contentEnd) of \(row.width)"
                )
            }
        }
    }
}
