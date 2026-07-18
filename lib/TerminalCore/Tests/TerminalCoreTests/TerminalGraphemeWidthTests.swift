// Proves grapheme width accumulation and every narrow/wide geometry transition.
import Testing

@testable import TerminalCore

/// Locks cluster width changes to atomic cell-pair, cursor, wrap, and spacer behavior.
struct TerminalGraphemeWidthTests {
    @Test("VS16 upgrades over empty, narrow, and wide neighbors")
    func variationSelectorUpgradeClearsNeighborAtomically() throws {
        let neighbors: [String?] = [nil, "X", "\u{754C}"]

        for neighbor in neighbors {
            var terminal = try #require(Terminal(columns: 5, rows: 1))
            if let neighbor {
                terminal.moveCursor(row: 0, column: 2)
                terminal.feed(Array(neighbor.utf8))
            }
            terminal.moveCursor(row: 0, column: 1)

            terminal.feed(Array("#\u{FE0F}".utf8))

            #expect(terminal.cell(row: 0, column: 1)?.scalars == ["#", "\u{FE0F}"])
            #expect(terminal.geometry.rows[0].cells.map(\.kind) == [
                .padding, .wideHead, .wideTail, .padding, .padding,
            ])
            #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 3, isPendingWrap: false))
            expectValidGrid(terminal.geometry)
        }
    }

    @Test("VS16 relocates a last-column cluster and preserves wrap geometry")
    func variationSelectorUpgradeRelocatesAtLastColumn() throws {
        var midScreen = try #require(Terminal(columns: 4, rows: 2))
        midScreen.moveCursor(row: 0, column: 3)
        midScreen.feed(Array("#\u{FE0F}".utf8))

        #expect(midScreen.geometry.rows[0].cells[3].kind == .spacerHead)
        #expect(midScreen.geometry.rows[0].isSoftWrapped)
        #expect(midScreen.cell(row: 1, column: 0)?.scalars == ["#", "\u{FE0F}"])
        #expect(midScreen.geometry.rows[1].cells.map(\.kind) == [
            .wideHead, .wideTail, .padding, .padding,
        ])
        #expect(midScreen.geometry.cursor == TerminalCursor(row: 1, column: 2, isPendingWrap: false))
        expectValidGrid(midScreen.geometry)

        var bottom = try #require(Terminal(columns: 4, rows: 2))
        bottom.feed(Array("A".utf8))
        bottom.moveCursor(row: 1, column: 3)
        bottom.feed(Array("#\u{FE0F}".utf8))

        #expect(bottom.screenText.contains("A") == false)
        #expect(bottom.geometry.rows[0].cells[3].kind == .spacerHead)
        #expect(bottom.geometry.rows[0].isSoftWrapped)
        #expect(bottom.cell(row: 1, column: 0)?.scalars == ["#", "\u{FE0F}"])
        #expect(bottom.geometry.cursor == TerminalCursor(row: 1, column: 2, isPendingWrap: false))
        expectValidGrid(bottom.geometry)

        var minimum = try #require(Terminal(columns: 2, rows: 2))
        minimum.moveCursor(row: 0, column: 1)
        minimum.feed(Array("#\u{FE0F}".utf8))

        #expect(minimum.geometry.rows[0].cells[1].kind == .spacerHead)
        #expect(minimum.cell(row: 1, column: 0)?.scalars == ["#", "\u{FE0F}"])
        #expect(minimum.geometry.rows[1].cells.map(\.kind) == [.wideHead, .wideTail])
        #expect(minimum.geometry.cursor == TerminalCursor(row: 1, column: 1, isPendingWrap: true))
        expectValidGrid(minimum.geometry)
    }

    @Test("VS15 downgrades in place and clears stale relocation spacers")
    func variationSelectorDowngrade() throws {
        var midRow = try #require(Terminal(columns: 5, rows: 1))
        midRow.feed(Array("\u{00A9}\u{FE0F}\u{FE0E}".utf8))

        #expect(midRow.cell(row: 0, column: 0)?.scalars == ["\u{00A9}", "\u{FE0F}", "\u{FE0E}"])
        #expect(midRow.geometry.rows[0].cells.map(\.kind) == [
            .narrow, .padding, .padding, .padding, .padding,
        ])
        #expect(midRow.geometry.cursor == TerminalCursor(row: 0, column: 1, isPendingWrap: false))
        expectValidGrid(midRow.geometry)

        var rightEdge = try #require(Terminal(columns: 2, rows: 1))
        rightEdge.feed(Array("\u{00A9}\u{FE0F}\u{FE0E}".utf8))

        #expect(rightEdge.geometry.rows[0].cells.map(\.kind) == [.narrow, .padding])
        #expect(rightEdge.geometry.cursor == TerminalCursor(row: 0, column: 1, isPendingWrap: false))
        expectValidGrid(rightEdge.geometry)

        var relocated = try #require(Terminal(columns: 4, rows: 2))
        relocated.moveCursor(row: 0, column: 3)
        relocated.feed(Array("#\u{FE0F}\u{FE0E}".utf8))

        #expect(relocated.geometry.rows[0].cells[3].kind == .padding)
        #expect(relocated.geometry.rows[0].isSoftWrapped)
        #expect(relocated.cell(row: 1, column: 0)?.scalars == ["#", "\u{FE0F}", "\u{FE0E}"])
        #expect(relocated.geometry.rows[1].cells.map(\.kind) == [
            .narrow, .padding, .padding, .padding,
        ])
        #expect(relocated.geometry.cursor == TerminalCursor(row: 1, column: 1, isPendingWrap: false))
        expectValidGrid(relocated.geometry)
    }

    @Test("valid selectors force width while invalid selectors only remain stored")
    func variationSelectorBaseGatingAndRepeatedUpgrade() throws {
        var valid = try #require(Terminal(columns: 4, rows: 1))
        valid.feed(Array("\u{00A9}\u{FE0F}\u{FE0F}".utf8))

        #expect(valid.cell(row: 0, column: 0)?.scalars == ["\u{00A9}", "\u{FE0F}", "\u{FE0F}"])
        #expect(valid.geometry.rows[0].cells.map(\.kind) == [
            .wideHead, .wideTail, .padding, .padding,
        ])
        #expect(valid.geometry.cursor == TerminalCursor(row: 0, column: 2, isPendingWrap: false))
        expectValidGrid(valid.geometry)

        var invalid = try #require(Terminal(columns: 4, rows: 1))
        invalid.feed(Array("A\u{FE0E}\u{FE0F}".utf8))

        #expect(invalid.cell(row: 0, column: 0)?.scalars == ["A", "\u{FE0E}", "\u{FE0F}"])
        #expect(invalid.geometry.rows[0].cells.map(\.kind) == [
            .narrow, .padding, .padding, .padding,
        ])
        expectValidGrid(invalid.geometry)
    }

    @Test("Regional Indicators are wide alone and in paired clusters")
    func regionalIndicatorGeometry() throws {
        var terminal = try #require(Terminal(columns: 7, rows: 1))

        terminal.feed(Array("\u{1F1E6}\u{1F1E7}\u{1F1E8}".utf8))

        #expect(terminal.cell(row: 0, column: 0)?.scalars == ["\u{1F1E6}", "\u{1F1E7}"])
        #expect(terminal.cell(row: 0, column: 2)?.scalars == ["\u{1F1E8}"])
        #expect(terminal.geometry.rows[0].cells.map(\.kind) == [
            .wideHead, .wideTail, .wideHead, .wideTail, .padding, .padding, .padding,
        ])
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 4, isPendingWrap: false))
        expectValidGrid(terminal.geometry)
    }

    @Test("upgraded clusters remain atomic under overwrite and erase")
    func upgradedClusterAtomicity() throws {
        for targetColumn in [0, 1] {
            var overwritten = try #require(Terminal(columns: 4, rows: 1))
            overwritten.feed(Array("#\u{FE0F}".utf8))
            overwritten.moveCursor(row: 0, column: targetColumn)
            overwritten.feed(Array("X".utf8))

            #expect(overwritten.geometry.rows[0].cells[0].kind == (
                targetColumn == 0 ? .narrow : .padding
            ))
            #expect(overwritten.geometry.rows[0].cells[1].kind == (
                targetColumn == 1 ? .narrow : .padding
            ))
            expectValidGrid(overwritten.geometry)
        }

        var erased = try #require(Terminal(columns: 4, rows: 1))
        erased.feed(Array("#\u{FE0F}".utf8))
        erased.eraseCells(row: 0, columns: 1..<2)

        #expect(erased.geometry.rows[0].cells.prefix(2).allSatisfy { $0.kind == .padding })
        expectValidGrid(erased.geometry)
    }

    @Test("joining positive-width scalars upgrade a narrow cluster")
    func widthContributingJoinersUpgrade() throws {
        let fixtures = [
            "\u{00A9}\u{200D}\u{1F469}",
            "\u{0915}\u{0903}",
        ]

        for fixture in fixtures {
            var terminal = try #require(Terminal(columns: 4, rows: 1))
            terminal.feed(Array(fixture.utf8))

            #expect(terminal.cell(row: 0, column: 0)?.scalars == Array(fixture.unicodeScalars))
            #expect(terminal.geometry.rows[0].cells.map(\.kind) == [
                .wideHead, .wideTail, .padding, .padding,
            ])
            expectValidGrid(terminal.geometry)
        }
    }

    @Test("excluded joining scalars leave a narrow cluster narrow")
    func excludedJoinersStayNarrow() throws {
        let fixtures = [
            "A\u{1F3FD}",
            "\u{1160}\u{1161}",
            "\u{0D4E}\u{0D4E}",
        ]

        for fixture in fixtures {
            var terminal = try #require(Terminal(columns: 4, rows: 1))
            terminal.feed(Array(fixture.utf8))

            #expect(terminal.cell(row: 0, column: 0)?.scalars == Array(fixture.unicodeScalars))
            #expect(terminal.geometry.rows[0].cells.map(\.kind) == [
                .narrow, .padding, .padding, .padding,
            ])
            expectValidGrid(terminal.geometry)
        }
    }

    private func expectValidGrid(
        _ geometry: TerminalGeometry,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for row in geometry.rows {
            for column in row.cells.indices {
                switch row.cells[column].kind {
                case .wideHead:
                    #expect(column + 1 < row.cells.count, sourceLocation: sourceLocation)
                    if column + 1 < row.cells.count {
                        #expect(row.cells[column + 1].kind == .wideTail, sourceLocation: sourceLocation)
                    }
                case .wideTail:
                    #expect(column > 0, sourceLocation: sourceLocation)
                    if column > 0 {
                        #expect(row.cells[column - 1].kind == .wideHead, sourceLocation: sourceLocation)
                    }
                case .spacerHead:
                    #expect(column == row.cells.count - 1, sourceLocation: sourceLocation)
                    #expect(row.isSoftWrapped, sourceLocation: sourceLocation)
                case .padding, .narrow:
                    break
                }
            }
        }
    }
}
