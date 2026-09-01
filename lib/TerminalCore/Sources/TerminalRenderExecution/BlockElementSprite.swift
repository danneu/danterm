// Render-boundary conversion for Block Elements: cell translation and Core Graphics types.
// Scalar decoding lives in `BlockElementSpriteGeometry`.
import CoreGraphics
import TerminalSpriteGeometry

/// Places one decoded Block Elements pattern at its terminal cell in display points.
enum BlockElementSprite {
    static func shade(for pattern: BlockElementPattern) -> BlockElementShade {
        if case let .full(shade) = pattern {
            return shade
        }
        return .solid
    }

    static func appendRects(
        pattern: BlockElementPattern,
        row: Int,
        column: Int,
        metrics: TerminalRenderMetrics,
        to rects: inout [CGRect]
    ) {
        let scale = metrics.displayScale
        let cellWidth = metrics.cellWidthPixels
        let cellHeight = metrics.cellHeightPixels
        let cellX = column * cellWidth
        let cellY = row * cellHeight

        for pixelRect in BlockElementSpriteGeometry.rects(
            pattern: pattern,
            cellWidthPixels: cellWidth,
            cellHeightPixels: cellHeight
        ) {
            rects.append(CGRect(
                x: CGFloat(cellX + pixelRect.x) / scale,
                y: CGFloat(cellY + pixelRect.y) / scale,
                width: CGFloat(pixelRect.width) / scale,
                height: CGFloat(pixelRect.height) / scale
            ))
        }
    }
}
