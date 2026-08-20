// Test-only flat projections for assertions written before plans became row-indexed.
import TerminalRenderPlanning

extension RenderFramePlan {
    var backgroundRuns: [RenderBackgroundRun] { rows.flatMap(\.backgroundRuns) }
    var overlayRuns: [RenderOverlayRun] { rows.flatMap(\.overlayRuns) }
    var textRuns: [RenderTextRun] { rows.flatMap(\.textRuns) }
    var decorationRuns: [RenderDecorationRun] { rows.flatMap(\.decorationRuns) }
}
