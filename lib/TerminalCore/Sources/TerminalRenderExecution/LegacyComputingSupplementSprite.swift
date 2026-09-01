// Render-boundary conversion for supplement sprites: cell translation and Core Graphics types.
// Scalar decoding lives in `LegacyComputingSupplementSpriteGeometry`.
import CoreGraphics
import TerminalSpriteGeometry

/// Places one decoded supplement pattern at its terminal cell in display points.
enum LegacyComputingSupplementSprite {
    static func appendRects(
        pattern: LegacySupplementPattern,
        row: Int,
        column: Int,
        metrics: TerminalRenderMetrics,
        to rects: inout [CGRect]
    ) {
        let scale = metrics.displayScale
        let originX = column * metrics.cellWidthPixels
        let originY = row * metrics.cellHeightPixels
        let thickness = metrics.lightStrokePixels
        for rect in LegacyComputingSupplementSpriteGeometry.rects(
            pattern: pattern,
            cellWidthPixels: metrics.cellWidthPixels,
            cellHeightPixels: metrics.cellHeightPixels,
            thicknessPixels: thickness
        ) {
            rects.append(CGRect(
                x: CGFloat(originX + rect.x) / scale,
                y: CGFloat(originY + rect.y) / scale,
                width: CGFloat(rect.width) / scale,
                height: CGFloat(rect.height) / scale
            ))
        }
    }
}
