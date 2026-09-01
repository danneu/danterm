// Render-boundary conversion for Powerline sprites: cell translation and Core Graphics types.
// Scalar decoding lives in `PowerlineSpriteGeometry`.
import CoreGraphics
import TerminalSpriteGeometry

/// Holds one translated Powerline path while its geometry remains cell-local.
struct PowerlineRenderPath {
    let geometry: PowerlinePixelPath
    let cellOrigin: CGPoint
}

/// Places one decoded Powerline pattern at its terminal cell in display points.
enum PowerlineSprite {
    static func paths(
        pattern: PowerlinePattern,
        row: Int,
        column: Int,
        metrics: TerminalRenderMetrics
    ) -> [PowerlineRenderPath] {
        let light = metrics.lightStrokePixels
        let geometry = PowerlineSpriteGeometry.geometry(
            pattern: pattern,
            cellWidthPixels: metrics.cellWidthPixels,
            cellHeightPixels: metrics.cellHeightPixels,
            lightStrokePixels: light
        )
        let origin = CGPoint(
            x: CGFloat(column * metrics.cellWidthPixels) / metrics.displayScale,
            y: CGFloat(row * metrics.cellHeightPixels) / metrics.displayScale
        )
        return geometry.paths.map { PowerlineRenderPath(geometry: $0, cellOrigin: origin) }
    }
}
