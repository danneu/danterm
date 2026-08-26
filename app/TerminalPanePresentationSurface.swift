// The pane view's seam onto the buffers it presents.
//
// `SwiftTerminalSessionView` owns a rotation of IOSurface-backed frame stores
// and decides which one each publish may render into. The production rotation is
// `TerminalFrameSwapchain`, a final engine type, so a test that wants to watch
// what a publish rendered -- or to hold every buffer busy and see the publish
// coalesce -- cannot wrap it. This protocol is the whole of what the view asks
// of that rotation, so a test supplies a recording stand-in for it while the view
// under test stays the production view.
import CoreGraphics
import TerminalCore
import TerminalRenderExecution
import TerminalRenderPlanning

/// Everything `SwiftTerminalSessionView` asks of the buffers it presents.
@MainActor
protocol TerminalPanePresentationSurface: AnyObject {
    /// True while a publish found no free buffer and is waiting for a retry.
    var hasPendingPresentation: Bool { get }
    /// What the last render covered, for the benchmark's render census.
    var lastRenderedDamage: TerminalDamage? { get }
    /// True once no buffer can still surface an older whole-frame setup.
    var allBuffersHaveRenderedLatestWholeFrameDamage: Bool { get }

    func matches(
        columns: Int,
        rows: Int,
        metrics: TerminalRenderMetrics,
        colorSpace: CGColorSpace?
    ) -> Bool
    func matches(metrics: TerminalRenderMetrics, colorSpace: CGColorSpace?) -> Bool
    func requireEveryBufferToRenderAgain()
    func publish(plan: RenderFramePlan, damage: TerminalDamage) -> TerminalFrameBackingStore?
    func retryPendingPresentation() -> TerminalFrameBackingStore?
}

/// Builds the rotation for one set of presentation inputs, or nothing when the
/// geometry has no allocatable buffers.
///
/// The view replaces the whole rotation whenever a presentation input moves, so
/// this is called again on every trust break rather than once per pane.
typealias TerminalPanePresentationSurfaceFactory = @MainActor (
    _ columns: Int,
    _ rows: Int,
    _ metrics: TerminalRenderMetrics,
    _ colorSpace: CGColorSpace?
) -> (any TerminalPanePresentationSurface)?

/// The production rotation already answers for every one of these, so the
/// conformance adds nothing; it only states that the real swapchain fits the seam.
extension TerminalFrameSwapchain: TerminalPanePresentationSurface {}

/// The rotation the app ships: real IOSurface buffers, freed on the render
/// server's own in-use report.
@MainActor
func liveTerminalPanePresentationSurface(
    columns: Int,
    rows: Int,
    metrics: TerminalRenderMetrics,
    colorSpace: CGColorSpace?
) -> (any TerminalPanePresentationSurface)? {
    TerminalFrameSwapchain(
        columns: columns,
        rows: rows,
        metrics: metrics,
        colorSpace: colorSpace
    )
}

/// Resolves the cell geometry one font choice and backing scale produce, or nothing
/// when that face has no usable cell box.
///
/// A seam because the real answer reads the machine's installed fonts, and the
/// pane's fallback behavior -- an unusable face must never leave a terminal blank
/// or frozen -- must be provable without depending on which faces are installed.
typealias TerminalPaneMetricsFactory = @MainActor (
    _ displayScale: CGFloat,
    _ fontChoice: TerminalFontChoice
) -> TerminalRenderMetrics?

/// The geometry the app ships: the engine's own font measurement.
@MainActor
func liveTerminalPaneMetrics(
    displayScale: CGFloat,
    fontChoice: TerminalFontChoice
) -> TerminalRenderMetrics? {
    TerminalRenderMetrics(displayScale: displayScale, fontChoice: fontChoice)
}
