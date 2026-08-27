// Test-only flat projections for assertions written before plans became row-indexed.
import TerminalRenderPlanning

extension RenderFramePlan {
    var backgroundRuns: [RenderBackgroundRun] { rows.flatMap(\.backgroundRuns) }
    var overlayRuns: [RenderOverlayRun] { rows.flatMap(\.overlayRuns) }
    var textRuns: [RenderTextRun] { rows.flatMap(\.textRuns) }
    var decorationRuns: [RenderDecorationRun] { rows.flatMap(\.decorationRuns) }

    var backgroundRunsWithRows: [(row: Int, run: RenderBackgroundRun)] {
        rows.enumerated().flatMap { row, planRow in
            planRow.backgroundRuns.map { (row, $0) }
        }
    }

    var overlayRunsWithRows: [(row: Int, run: RenderOverlayRun)] {
        rows.enumerated().flatMap { row, planRow in
            planRow.overlayRuns.map { (row, $0) }
        }
    }

    var textRunsWithRows: [(row: Int, run: RenderTextRun)] {
        rows.enumerated().flatMap { row, planRow in
            planRow.textRuns.map { (row, $0) }
        }
    }

    var decorationRunsWithRows: [(row: Int, run: RenderDecorationRun)] {
        rows.enumerated().flatMap { row, planRow in
            planRow.decorationRuns.map { (row, $0) }
        }
    }
}
