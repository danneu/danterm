// The one search for metrics whose frame extent overflows, shared by the suites that
// need an overflow case.
//
// Its own file rather than a private helper beside either caller: two suites in this
// target -- frame sizing in RenderMetricsTests and the background pass in
// BackgroundExecutionTests -- had grown byte-identical copies of this binary search
// under different names, so a change to the overflow definition had to be made twice.
// Nothing else belongs here; general plan/bitmap fixtures live in BitmapTestSupport.
import CoreGraphics

@testable import TerminalRenderExecution

/// The largest accepted display scale whose two-column frame extent no longer fits in
/// `Int`, or nil when no such scale exists. Returns metrics rather than a scale because
/// the overflow the callers exercise is a property of the derived cell width, and the
/// scale that produces it is not otherwise interesting.
func largestMetricsWhoseTwoColumnFrameOverflows() -> TerminalRenderMetrics? {
    var accepted: CGFloat = 1
    var refused = CGFloat(Int.max)
    for _ in 0..<128 {
        let candidate = accepted + (refused - accepted) / 2
        if TerminalRenderMetrics(displayScale: candidate) == nil {
            refused = candidate
        } else {
            accepted = candidate
        }
    }
    let metrics = TerminalRenderMetrics(displayScale: accepted)
    return metrics.flatMap { $0.cellWidthPixels > Int.max / 2 ? $0 : nil }
}
