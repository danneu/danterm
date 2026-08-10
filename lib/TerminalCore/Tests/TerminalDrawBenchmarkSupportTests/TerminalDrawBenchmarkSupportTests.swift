// Behavioral contracts for the deterministic CoreText draw micro benchmark.
import TerminalCore
import TerminalRenderPlanning
import Testing
@testable import TerminalDrawBenchmarkSupport

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

    @Test("Every workload fills its grid completely")
    func workloadsFillTheGrid() throws {
        // Intent: both workloads put a cell in every column of every row.
        // Why it exists: per-draw cost scales with occupied cells, so a workload
        //   that leaves a ragged right margin is not comparable to one that does
        //   not, and the difference would read as a property of the content.
        // Scenario: spec-first -- the text workload lays down whole tokens and
        //   has to truncate the last one on each row to reach the margin.
        for grid in DrawBenchmarkGrid.standard {
            for workload in DrawBenchmarkWorkload.allCases {
                let plan = try #require(makeWorkloadPlan(for: grid, workload: workload))
                let cellCount = plan.textRuns.reduce(0) { $0 + $1.cells.count }

                #expect(cellCount == grid.columns * grid.rows)
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
        let report = try measureDrawBenchmarks(iterations: 2, targetNanoseconds: 1_000_000)

        for measurement in report.measurements {
            let surface = measurement.surface
            let cells = measurement.grid.columns * measurement.grid.rows

            #expect(surface.bitmapPixelWidth
                == surface.cellPixelWidth * measurement.grid.columns)
            #expect(surface.bitmapPixelHeight
                == surface.cellPixelHeight * measurement.grid.rows)
            #expect(surface.drawnCellCount > 0)
            #expect(surface.drawnRunCount > 0)
            switch measurement.scenario {
            case .fullFrame:
                #expect(surface.drawnCellCount == cells)
            case .damageClipped:
                #expect(surface.drawnCellCount < cells)
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
