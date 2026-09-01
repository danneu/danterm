// Behavioral contracts for the deterministic CoreText draw micro benchmark.
import TerminalCore
import TerminalRenderPlanning
import Testing
@testable import TerminalDrawBenchmarkSupport
@testable import TerminalRenderExecution

@Suite("Terminal draw benchmark support")
struct TerminalDrawBenchmarkSupportTests {
    @Test("Every workload's input is deterministic at every benchmark grid")
    func workloadIsDeterministic() {
        for grid in DrawBenchmarkGrid.standard {
            for workload in DrawBenchmarkWorkload.allCases {
                #expect(workloadANSI(for: grid, workload: workload)
                    == workloadANSI(for: grid, workload: workload))
            }
        }
    }

    @Test("btop-shaped plans fragment text runs at cell granularity")
    func btopWorkloadFragmentsTextRuns() throws {
        for grid in DrawBenchmarkGrid.standard {
            let plan = try #require(makeWorkloadPlan(for: grid, workload: .btopShaped))
            #expect(plan.textRuns.count > grid.columns * grid.rows * 3 / 4)
        }
    }

    @Test("Text-shaped plans hold nothing but printable ASCII")
    func textWorkloadHoldsOnlyPrintableASCII() throws {
        // Intent: no cell of the text-shaped workload carries a scalar outside
        //   printable ASCII.
        // Why it exists: this is the whole reason the workload exists. Every
        //   sprite family the executor routes to begins at U+2500 or above, so
        //   an all-ASCII grid is one the executor cannot classify as a sprite
        //   and must hand to CTFontGetGlyphsForCharacters and CTFontDrawGlyphs.
        //   Assert the property that entails the glyph path rather than the
        //   glyph calls themselves, which no seam exposes.
        // Scenario: research/13/F5 found the btop-shaped fixture routes every single cell
        //   to a sprite family and reaches CTFontDrawGlyphs zero times, which
        //   left the benchmark blind to every glyph-path change.
        for grid in DrawBenchmarkGrid.standard {
            let plan = try #require(makeWorkloadPlan(for: grid, workload: .textShaped))
            let scalars = plan.textRuns.flatMap { $0.cells.flatMap { Array($0.scalars) } }

            #expect(scalars.isEmpty == false)
            #expect(scalars.allSatisfy { (0x20...0x7E).contains($0.value) })
        }
    }

    @Test("Text-shaped plans fold runs into token-sized spans covering every styled face")
    func textWorkloadFoldsRunsAcrossEveryFace() throws {
        // Intent: the text-shaped workload produces multi-cell runs, and its
        //   runs between them use all four bold/italic combinations.
        // Why it exists: two ways this fixture could quietly misrepresent the
        //   glyph path. Style churn at cell granularity -- which the btop-shaped
        //   workload deliberately has -- would make every CTFontDrawGlyphs call
        //   a one-glyph call and overstate any per-glyph work against real
        //   output. And a workload that never leaves the regular face would
        //   leave three of the metrics' four styled faces unmeasured.
        // Scenario: spec-first -- a screen of source code or log output, where
        //   color and emphasis change at token boundaries and words are several
        //   cells long.
        for grid in DrawBenchmarkGrid.standard {
            let plan = try #require(makeWorkloadPlan(for: grid, workload: .textShaped))
            let cellCount = plan.textRuns.reduce(0) { $0 + $1.cells.count }

            #expect(plan.textRuns.count < cellCount / 2)
            for bold in [false, true] {
                for italic in [false, true] {
                    #expect(plan.textRuns.contains { $0.bold == bold && $0.italic == italic })
                }
            }
        }
    }

    @Test("Fallback-shaped plans hold no cell the executor's fast path can claim")
    func fallbackWorkloadHoldsOnlyFallbackCells() throws {
        // Intent: every cell of the fallback-shaped workload is one the executor
        //   sends to `drawTextCell` -- a multi-scalar cluster, a scalar above
        //   `UInt16.max`, or a single BMP scalar the base face cannot map.
        // Why it exists: this is the whole reason the workload exists. The other
        //   two workloads reach the sprite path and the batched-glyph fast path,
        //   and neither typesets a `CTLine`. Assert the property that entails the
        //   fallback path -- the three conditions `drawTextRuns` routes on -- rather
        //   than the CoreText calls themselves, which no seam exposes.
        // Scenario: research/40/F1 read three quarters of a saturated main thread as
        //   per-cell `CTLineCreateWithAttributedString` on kitten's `unicode` arm,
        //   and found no frozen benchmark arm that reaches the path at all.
        let face = try #require(TerminalRenderMetrics(displayScale: 2)).fonts.regular
        for grid in DrawBenchmarkGrid.standard {
            let plan = try #require(makeWorkloadPlan(for: grid, workload: .fallbackShaped))
            let cells = plan.textRuns.flatMap { $0.cells }

            #expect(cells.isEmpty == false)
            #expect(cells.allSatisfy { cell in
                guard cell.scalars.count == 1, let scalar = cell.scalars.first else { return true }
                guard scalar.value <= UInt32(UInt16.max) else { return true }
                return face.nominalGlyph(scalar.value) == nil
            })
        }
    }

    @Test("Fallback-shaped plans hold wide cells and clusters at token-boundary styles")
    func fallbackWorkloadCoversEveryFallbackReason() throws {
        // Intent: the fallback workload carries all three reasons a cell falls
        //   back -- a multi-scalar cluster, a scalar above `UInt16.max`, and an
        //   unmapped wide BMP scalar -- and changes style at token boundaries so
        //   its runs are the several-cell spans real output produces.
        // Why it exists: a workload made of one reason would price one branch of
        //   the fallback and read as the whole path. The doc's candidate cache is
        //   keyed on the cluster, so a corpus without clusters or astral scalars
        //   could not tell a working key design from a broken one. Token-boundary
        //   styles keep run lengths off the per-cell floor the btop workload sits on.
        // Scenario: spec-first -- a screen of CJK prose with combining-mark text
        //   mixed in, which is the shape of kitten's two Unicode arms.
        for grid in DrawBenchmarkGrid.standard {
            let plan = try #require(makeWorkloadPlan(for: grid, workload: .fallbackShaped))
            let cells = plan.textRuns.flatMap { $0.cells }

            #expect(cells.contains { $0.scalars.count > 1 })
            #expect(cells.contains { $0.scalars.contains { $0.value > UInt32(UInt16.max) } })
            #expect(cells.contains { $0.columnWidth == 2 })
            #expect(plan.textRuns.count < cells.count / 2)
            for bold in [false, true] {
                for italic in [false, true] {
                    #expect(plan.textRuns.contains { $0.bold == bold && $0.italic == italic })
                }
            }
        }
    }

    @Test("Symbols-shaped plans hold nothing but packaged-symbol icon cells")
    func symbolsWorkloadHoldsOnlyPackagedSymbolCells() throws {
        // Intent: every cell of the symbols-shaped workload satisfies all four conditions
        //   the executor tests before it draws a packaged symbol -- one private-use scalar,
        //   claimed by no sprite family, unmapped by the styled base faces, and mapped by
        //   the packaged symbols face.
        // Why it exists: this is the whole reason the workload exists, and a cell that
        //   misses any one condition measures a different path while still looking like an
        //   icon. A sprite-claimed scalar is filled as rects, and one the base face maps
        //   goes out in the batch; either way the run would price a path nobody asked for.
        // Scenario: DRAW-9 -- the packaged-symbols path had no benchmark arm at all, so a
        //   change to its per-cell glyph lookup could not be measured.
        let fonts = try #require(TerminalRenderMetrics(displayScale: 2)).fonts
        let symbols = try #require(PackagedSymbolsFace.face(pointSize: 14))
        let spriteClaimed = [PowerlineSprite.coarseRange, BranchDrawingSprite.coarseRange]
        for grid in DrawBenchmarkGrid.standard {
            let plan = try #require(makeWorkloadPlan(for: grid, workload: .symbolsShaped))
            let cells = plan.textRuns.flatMap { $0.cells }

            #expect(cells.isEmpty == false)
            for cell in cells {
                #expect(cell.scalars.count == 1)
                let scalar = try #require(cell.scalars.first)
                #expect(isPrivateUse(scalar.value))
                #expect(spriteClaimed.allSatisfy { $0.contains(scalar.value) == false })
                for face in [fonts.regular, fonts.bold, fonts.italic, fonts.boldItalic] {
                    #expect(face.nominalGlyph(scalar.value) == nil)
                }
                #expect(TerminalFace(font: symbols).nominalGlyph(scalar.value) != nil)
            }
        }
    }

    @Test("Symbols-shaped plans carry both private-use shapes at token-boundary styles")
    func symbolsWorkloadCoversBothPrivateUseShapes() throws {
        // Intent: the workload holds BMP icons and plane-15 icons, and changes style at
        //   token boundaries so its runs are the several-cell spans real output produces.
        // Why it exists: the two shapes reach the batched glyph call differently -- one code
        //   unit against a surrogate pair -- and the glyph-index arithmetic that walks that
        //   batch is what decides which cell a symbol is attributed to. A corpus of one
        //   shape could not tell correct arithmetic from an off-by-one. Token-boundary
        //   styles keep run lengths off the per-cell floor the btop workload sits on.
        for grid in DrawBenchmarkGrid.standard {
            let plan = try #require(makeWorkloadPlan(for: grid, workload: .symbolsShaped))
            let cells = plan.textRuns.flatMap { $0.cells }

            #expect(cells.contains { $0.scalars.contains { $0.value <= UInt32(UInt16.max) } })
            #expect(cells.contains { $0.scalars.contains { $0.value > UInt32(UInt16.max) } })
            #expect(plan.textRuns.count < cells.count / 2)
            for bold in [false, true] {
                for italic in [false, true] {
                    #expect(plan.textRuns.contains { $0.bold == bold && $0.italic == italic })
                }
            }
        }
    }

    @Test("Every workload fills its grid completely")
    func workloadsFillTheGrid() throws {
        // Intent: every workload covers every column of every row.
        // Why it exists: per-draw cost scales with occupied columns, so a workload
        //   that leaves a ragged right margin is not comparable to one that does
        //   not, and the difference would read as a property of the content.
        // Scenario: spec-first -- the text workload lays down whole tokens and
        //   has to truncate the last one on each row to reach the margin, and the
        //   fallback workload's wide cells cannot land on an odd final column, so
        //   it pads with one-column clusters instead.
        for grid in DrawBenchmarkGrid.standard {
            for workload in DrawBenchmarkWorkload.allCases {
                let plan = try #require(makeWorkloadPlan(for: grid, workload: workload))
                let columnCount = plan.textRuns.reduce(0) { total, run in
                    total + run.cells.reduce(0) { $0 + $1.columnWidth }
                }

                #expect(columnCount == grid.columns * grid.rows)
            }
        }
    }

    @Test("Every measurement describes the surface and content it drew")
    func measurementsDescribeTheirSurface() throws {
        // Intent: a measurement carries the bitmap it drew into, the cell size
        //   it drew at, and how many runs and cells it drew -- enough for a
        //   reader to check its per-draw duration against a rect-fill floor.
        // Why it exists: research/11/F4. A research finding quoted per-draw durations
        //   from this benchmark that were 16x faster than a bare
        //   CGContextFillRects of the same cells -- physically impossible, and
        //   caused by a summarizing script dividing by the batch count twice.
        //   The report carried no denominator anyone could have divided to
        //   catch it. A number that cannot be checked for plausibility gets
        //   believed, so every run now carries its own.
        // Scenario: an agent reading a JSON report months from now, deciding
        //   whether 13.85us for a full 80x24 frame is a real measurement.
        let report = try measureDrawBenchmarks(iterations: 2, floorNanoseconds: 1_000_000)

        for measurement in report.measurements {
            let surface = measurement.surface
            let columns = measurement.grid.columns * measurement.grid.rows

            #expect(surface.bitmapPixelWidth
                == surface.cellPixelWidth * measurement.grid.columns)
            #expect(surface.bitmapPixelHeight
                == surface.cellPixelHeight * measurement.grid.rows)
            #expect(surface.drawnCellCount > 0)
            #expect(surface.drawnRunCount > 0)
            #expect(surface.drawnColumnCount >= surface.drawnCellCount)
            switch measurement.scenario {
            case .fullFrame:
                #expect(surface.drawnColumnCount == columns)
            case .damageClipped:
                #expect(surface.drawnColumnCount < columns)
            }
        }
    }

    @Test("Full-frame and damage-clipped scenarios execute on real bitmap surfaces")
    func scenariosExecuteOffscreen() throws {
        for grid in DrawBenchmarkGrid.standard {
            for workload in DrawBenchmarkWorkload.allCases {
                let plan = try #require(makeWorkloadPlan(for: grid, workload: workload))
                #expect(try executeDrawScenario(.fullFrame, plan: plan) > 0)
                #expect(try executeDrawScenario(.damageClipped, plan: plan) > 0)
            }
        }
    }
}
