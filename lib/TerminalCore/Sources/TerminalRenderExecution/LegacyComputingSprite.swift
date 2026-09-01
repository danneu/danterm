// Render-boundary conversion for legacy-computing sprites: cell translation and Core Graphics
// types. Scalar decoding lives in `LegacyComputingSpriteGeometry`.
import CoreGraphics
import TerminalSpriteGeometry

/// Places one decoded legacy-computing pattern at its terminal cell in display points.
enum LegacyComputingSprite {
    static func appendRects(
        pattern: LegacyComputingPattern,
        row: Int,
        column: Int,
        metrics: TerminalRenderMetrics,
        to rects: inout [UInt8: [CGRect]]
    ) {
        let scale = metrics.displayScale
        let originX = column * metrics.cellWidthPixels
        let originY = row * metrics.cellHeightPixels
        let light = metrics.lightStrokePixels
        for run in LegacyComputingSpriteGeometry.runs(
            pattern: pattern,
            cellWidthPixels: metrics.cellWidthPixels,
            cellHeightPixels: metrics.cellHeightPixels,
            lightStrokePixels: light
        ) {
            rects[run.alpha, default: []].append(CGRect(
                x: CGFloat(originX + run.rect.x) / scale,
                y: CGFloat(originY + run.rect.y) / scale,
                width: CGFloat(run.rect.width) / scale,
                height: CGFloat(run.rect.height) / scale
            ))
        }
    }
}
