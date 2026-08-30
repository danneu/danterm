// What the shaped-cluster cache owes the draw beyond pixel parity: one entry per
// (face, cluster) whatever colour it is drawn in, no entry that outlives the font set it
// was shaped under, a bound on how many entries it can hold, and no typesetting at all
// once a frame's clusters are cached.
//
// Parity itself lives in FallbackShapingParityTests; nothing here re-asserts a bitmap
// against the reference renderer. What these tests read is a rendered surface or a count
// the cache reports -- never the shape of a helper, and never the entries themselves.
import CoreGraphics
import Testing

import TerminalCore
@testable import TerminalRenderExecution
import TerminalRenderPlanning

/// Renders `plan` through a caller-owned cache, once per frame, and returns the surface.
///
/// The cache is the caller's so a test can read its counts afterwards and can hand the
/// same one to two draws that differ in metrics or content.
private func renderBitmap(
    plan: RenderFramePlan,
    metrics: TerminalRenderMetrics,
    shapedClusters: ShapedClusterCache,
    frames: Int = 1
) throws -> Bitmap {
    let size = try #require(renderFrameSize(for: plan, metrics: metrics))
    let surface = try BitmapSurface(size: size, metrics: metrics)
    let context = try #require(surface.context)
    for _ in 0..<frames {
        drawRenderFrame(plan, metrics: metrics, shapedClusters: shapedClusters, in: context)
    }
    return surface.bitmap()
}

/// Distinct CJK clusters, enough of them to overrun a deliberately small cap.
private func distinctClusterRow(count: Int) -> String {
    String(String.UnicodeScalarView((0..<count).compactMap {
        Unicode.Scalar(0x6F22 + $0)
    }))
}

struct ShapedClusterCacheTests {
    @Test("One cluster in two colours is shaped once and drawn in both")
    func twoColoursShareOneShaping() throws {
        // Intent: the same cluster in two foreground colours draws in each of them, and
        //   the cache holds one entry for the pair.
        // Why it exists: colour is deliberately not part of the key -- it is the batch's
        //   fill. If it leaked into the key, a themed or syntax-highlighted screen would
        //   shape the same character once per colour and the cache would grow with the
        //   palette instead of with the content.
        // Scenario: spec-first -- a diff view where the same CJK word appears in the
        //   added-line colour and the removed-line colour.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let plan = try makePlan(
            input: "\u{1B}[31m\u{6F22}\u{1B}[32m\u{6F22}",
            columns: 12,
            rows: 1
        )
        let foregrounds = plan.rows[0].textRuns.map(\.foreground)
        try #require(foregrounds.count == 2)
        try #require(foregrounds[0] != foregrounds[1])

        let cache = ShapedClusterCache(metrics: metrics)
        let bitmap = try renderBitmap(plan: plan, metrics: metrics, shapedClusters: cache)

        for (index, foreground) in foregrounds.enumerated() {
            let span = cellRect(row: 0, column: index * 2, columnCount: 2, metrics: metrics)
            #expect(
                bitmap.pixels(in: span).contains(Pixel(foreground)),
                "the cluster drawn in run \(index) has none of that run's colour"
            )
        }
        #expect(cache.entryCount == 1, "two colours of one cluster made \(cache.entryCount) entries")
    }

    @Test("A cached frame redrawn does no further typesetting")
    func asecondFrameOverCachedClustersMissesNothing() throws {
        // Intent: rendering a frame of fallback cells a second time through the same
        //   cache adds no misses, and its every distinct cluster cost exactly one.
        // Why it exists: this is the whole claim of the change -- steady state pays a
        //   lookup, not a typesetting. A cache that answered correctly but re-shaped
        //   anyway would pass every parity test and win nothing.
        // Scenario: spec-first -- a pane of CJK repainting while nothing in it changes.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let clusters = 6
        let plan = try makePlan(input: distinctClusterRow(count: clusters), columns: 40, rows: 1)
        let cache = ShapedClusterCache(metrics: metrics)

        _ = try renderBitmap(plan: plan, metrics: metrics, shapedClusters: cache)
        #expect(cache.missCount == clusters, "the first frame shaped \(cache.missCount) times")

        _ = try renderBitmap(plan: plan, metrics: metrics, shapedClusters: cache, frames: 4)
        #expect(cache.missCount == clusters, "later frames added \(cache.missCount - clusters) shapings")
    }

    @Test("A cache kept across a font-set change renders the new font set")
    func aCacheSurvivesAMetricsChangeWithoutServingOldGlyphs() throws {
        // Intent: a cache that has already served one font set, then draws under
        //   different metrics, produces the surface a cache that had never seen the old
        //   font set produces.
        // Why it exists: entries hold concrete faces and positions from the font set they
        //   were shaped under. An owner that keeps its cache across a font change would
        //   otherwise paint the previous font's glyphs, which no parity test would catch
        //   because each font set is self-consistent.
        // Scenario: spec-first -- the user changes the terminal font while CJK is on
        //   screen.
        let first = try #require(FallbackFaceSource.systemMonospace.metrics(displayScale: 2))
        let second = try #require(FallbackFaceSource.obliqueBaseFont.metrics(displayScale: 2))
        try #require(first != second)
        try #require(first.cellSize == second.cellSize)

        let plan = try makePlan(input: distinctClusterRow(count: 4), columns: 40, rows: 1)
        let carried = ShapedClusterCache(metrics: first)
        _ = try renderBitmap(plan: plan, metrics: first, shapedClusters: carried)

        let afterChange = try renderBitmap(plan: plan, metrics: second, shapedClusters: carried)
        let fresh = try renderBitmap(
            plan: plan,
            metrics: second,
            shapedClusters: ShapedClusterCache(metrics: second)
        )

        expectBitmap(afterChange, matches: fresh, "a carried cache after a font-set change")
    }

    @Test("More clusters than the cap stay bounded and still render")
    func drawingPastTheCapStaysBoundedAndCorrect() throws {
        // Intent: drawing many more distinct clusters than a cache's cap leaves its entry
        //   count at or below that cap, and the surface is what an unbounded-enough cache
        //   renders.
        // Why it exists: the cache is process memory that grows with the content on
        //   screen. Without a bound a long session of varied text would grow it without
        //   limit; with a bound that dropped correctness, a screen past the cap would
        //   render wrong instead of merely slower.
        // Scenario: spec-first -- a page of varied CJK longer than the cache can hold.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let capacity = 4
        let plan = try makePlan(input: distinctClusterRow(count: 12), columns: 40, rows: 1)
        let bounded = ShapedClusterCache(metrics: metrics, capacity: capacity)

        let rendered = try renderBitmap(
            plan: plan,
            metrics: metrics,
            shapedClusters: bounded,
            frames: 3
        )
        let unbounded = try renderBitmap(
            plan: plan,
            metrics: metrics,
            shapedClusters: ShapedClusterCache(metrics: metrics)
        )

        #expect(
            bounded.entryCount <= capacity,
            "a cap of \(capacity) held \(bounded.entryCount) entries"
        )
        expectBitmap(rendered, matches: unbounded, "a frame drawn past the cap")
    }
}
