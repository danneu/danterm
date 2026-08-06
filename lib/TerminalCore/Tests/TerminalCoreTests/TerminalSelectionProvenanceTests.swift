// Selection provenance equivalence and retained-history cost proofs.
import Testing

@testable import TerminalCore

/// Proves selection provenance without coupling pointer-move cost to retained history depth.
struct TerminalSelectionProvenanceTests {
    @Test("selection provenance matches selected text across projection shapes")
    func provenanceMatchesSelectionSerialization() throws {
        // Intent: both selection entry points retain exactly the content provenance that
        //   selection serialization would compute across every projection-emission branch.
        // Why it exists: reflow depends on this bit after the originally selected cells may
        //   have been erased, so a faster probe must preserve the old result exactly.
        // Scenario: selections sweep blank, erased, wrapped, wide, padded, seam, hard-boundary,
        //   alternate-screen, and out-of-range endpoints.
        for (label, fixture) in try fixtures() {
            let rows = fixture.scrollbackRowCount + fixture.geometry.rows.count
            let rowValues = Array(-1...(rows + 1))
            let columnValues = Array(-1...(fixture.geometry.columns + 1))
            let points = rowValues.flatMap { row in
                columnValues.map { TerminalTextPosition(row: row, column: $0) }
            }

            for first in points {
                for second in points {
                    var cellSelection = fixture
                    cellSelection.setSelection(from: first, to: second)
                    #expect(
                        cellSelection.selectionRequiresNonemptyReflowResultForTesting
                            == (cellSelection.selectedText?.isEmpty == false),
                        "cell selection in \(label): \(first) through \(second)"
                    )

                    var rangeSelection = fixture
                    rangeSelection.setSelection(.init(start: first, end: second))
                    #expect(
                        rangeSelection.selectionRequiresNonemptyReflowResultForTesting
                            == (rangeSelection.selectedText?.isEmpty == false),
                        "range selection in \(label): \(first) through \(second)"
                    )
                }
            }

            var all = fixture
            all.selectAll()
            #expect(
                all.selectionRequiresNonemptyReflowResultForTesting
                    == (all.selectedText?.isEmpty == false),
                "Select All in \(label)"
            )
        }
    }

    @Test("selection creation never materializes the complete projection")
    func selectionCreationAvoidsWholeProjection() throws {
        var terminal = try historyFixture(lines: 80)
        let point = TerminalTextPosition(row: 5, column: 0)
        let range = TerminalTextRange(
            start: point,
            end: TerminalTextPosition(row: 5, column: 1)
        )

        terminal.setSelection(range)
        let calibration = WholeProjectionCounter.measure {
            _ = terminal.selectedText
        }
        #expect(calibration >= 1)

        let cellMaterializations = WholeProjectionCounter.measure {
            terminal.setSelection(from: point, to: point)
        }
        let rangeMaterializations = WholeProjectionCounter.measure {
            terminal.setSelection(range)
        }

        #expect(cellMaterializations == 0)
        #expect(rangeMaterializations == 0)
    }

    @Test("history selection locate cost is independent of retained depth")
    func historySelectionLocateCostIsDepthIndependent() throws {
        func costs(lines: Int) throws -> (cell: Int, range: Int) {
            var terminal = try historyFixture(lines: lines)
            let point = TerminalTextPosition(row: 5, column: 0)
            let range = TerminalTextRange(
                start: point,
                end: TerminalTextPosition(row: 5, column: 1)
            )
            let cell = LocateCounter.measure {
                terminal.setSelection(from: point, to: point)
            }
            let rangeCost = LocateCounter.measure {
                terminal.setSelection(range)
            }
            return (cell, rangeCost)
        }

        let shallow = try costs(lines: 80)
        let deep = try costs(lines: 8_000)

        #expect(shallow.cell >= 1)
        #expect(shallow.range >= 1)
        #expect(deep.cell == shallow.cell)
        #expect(deep.range == shallow.range)
    }

    @Test("Select All materializes its projection exactly once")
    func selectAllDoesNotWalkProjectionAgainForProvenance() throws {
        var terminal = try historyFixture(lines: 80)

        let materializations = WholeProjectionCounter.measure {
            terminal.selectAll()
        }

        #expect(materializations == 1)
    }

    private func fixtures() throws -> [(String, Terminal)] {
        let blank = try #require(Terminal(columns: 4, rows: 3))

        var erased = blank
        erased.feed(Array("AB\r\u{1B}[2K".utf8))

        var softWrap = blank
        softWrap.feed(Array("ABCDE".utf8))

        var wide = blank
        wide.feed(Array("A\u{754C}B".utf8))

        var padding = blank
        padding.moveCursor(row: 0, column: 2)
        padding.feed(Array("X".utf8))

        var hardBoundary = blank
        hardBoundary.feed(Array("A\r\nB".utf8))

        var seam = try #require(Terminal(columns: 3, rows: 2))
        seam.feed(Array("ab\u{754C}\r\nx\r\ny".utf8))
        #expect((0..<seam.scrollbackRowCount).contains { row in
            seam.retainedRowForTesting(at: row)?.cells.contains {
                $0.kind == .spacerHead
            } == true
        })

        var alternate = blank
        alternate.feed(Array("primary".utf8))
        alternate.feed(Array("\u{1B}[?1049halt".utf8))

        return [
            ("blank", blank),
            ("erased", erased),
            ("soft wrap", softWrap),
            ("wide", wide),
            ("padding", padding),
            ("hard boundary", hardBoundary),
            ("seam spacer", seam),
            ("alternate screen", alternate),
        ]
    }

    private func historyFixture(lines: Int) throws -> Terminal {
        var terminal = try #require(Terminal(columns: 40, rows: 8))
        for index in 0..<lines {
            terminal.feed(Array("history line \(index)\r\n".utf8))
        }
        return terminal
    }
}
