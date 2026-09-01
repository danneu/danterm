// Render-boundary conversion for Box Drawing sprites: cell translation and Core Graphics
// types. Scalar decoding lives in `BoxDrawingSpriteGeometry`.
import CoreGraphics
import TerminalSpriteGeometry

/// Places one decoded Box Drawing pattern at its terminal cell in display points.
enum BoxDrawingSprite {
    static func append(
        pattern: BoxDrawingPattern,
        row: Int,
        column: Int,
        metrics: TerminalRenderMetrics,
        rects: inout [CGRect],
        strokes: inout [BoxDrawingRenderStroke]
    ) {
        let light = metrics.lightStrokePixels
        let geometry = BoxDrawingSpriteGeometry.geometry(
            pattern: pattern,
            cellWidthPixels: metrics.cellWidthPixels,
            cellHeightPixels: metrics.cellHeightPixels,
            lightStrokePixels: light
        )
        let origin = CGPoint(
            x: CGFloat(column * metrics.cellWidthPixels) / metrics.displayScale,
            y: CGFloat(row * metrics.cellHeightPixels) / metrics.displayScale
        )
        for rect in geometry.rects {
            rects.append(CGRect(
                x: origin.x + CGFloat(rect.x) / metrics.displayScale,
                y: origin.y + CGFloat(rect.y) / metrics.displayScale,
                width: CGFloat(rect.width) / metrics.displayScale,
                height: CGFloat(rect.height) / metrics.displayScale
            ))
        }
        strokes += geometry.strokes.map {
            BoxDrawingRenderStroke(geometry: $0, cellOrigin: origin)
        }
    }
}

struct BoxDrawingRenderStroke {
    let geometry: BoxDrawingPixelStroke
    let cellOrigin: CGPoint
}
