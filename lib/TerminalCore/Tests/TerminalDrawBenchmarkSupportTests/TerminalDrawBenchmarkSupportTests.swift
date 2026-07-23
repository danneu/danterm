// Behavioral contracts for the deterministic CoreText draw micro benchmark.
import TerminalCore
import TerminalRenderPlanning
import Testing
@testable import TerminalDrawBenchmarkSupport

@Suite("Terminal draw benchmark support")
struct TerminalDrawBenchmarkSupportTests {
    @Test("btop-shaped input is deterministic at every benchmark grid")
    func workloadIsDeterministic() {
        for grid in DrawBenchmarkGrid.standard {
            #expect(btopShapedANSI(for: grid) == btopShapedANSI(for: grid))
        }
    }

    @Test("btop-shaped plans fragment text runs at cell granularity")
    func workloadFragmentsTextRuns() throws {
        for grid in DrawBenchmarkGrid.standard {
            let plan = try #require(makeBtopShapedPlan(for: grid))
            #expect(plan.textRuns.count > grid.columns * grid.rows * 3 / 4)
        }
    }

    @Test("full-frame and damage-clipped scenarios execute on real bitmap surfaces")
    func scenariosExecuteOffscreen() throws {
        for grid in DrawBenchmarkGrid.standard {
            let plan = try #require(makeBtopShapedPlan(for: grid))
            #expect(try executeDrawScenario(.fullFrame, plan: plan) > 0)
            #expect(try executeDrawScenario(.damageClipped, plan: plan) > 0)
        }
    }
}
