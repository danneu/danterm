// Exact Unicode classification and render-boundary conversion for legacy-computing sprites.
import CoreGraphics
import TerminalSpriteGeometry

/// Maps Ghostty's discontiguous legacy-computing scalar set to pure pixel geometry.
enum LegacyComputingSprite {
    /// Coarse routing span for the classifier switch. Wider than the discontiguous membership
    /// decoded in `pattern(for:)`; interior gaps return nil there and fall through to the font path.
    static let coarseRange: ClosedRange<UInt32> = 0x1FB00...0x1FBEF

    static func pattern(for scalar: Unicode.Scalar) -> LegacyComputingPattern? {
        let value = scalar.value
        let supported = (0x1FB00...0x1FBAF).contains(value)
            || (0x1FBBD...0x1FBBF).contains(value)
            || (0x1FBCE...0x1FBEF).contains(value)
        guard supported else { return nil }
        return LegacyComputingPattern(scalar: value)
    }

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
