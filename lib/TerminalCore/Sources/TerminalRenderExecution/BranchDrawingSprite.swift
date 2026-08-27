// Exact Unicode classification and render-boundary translation for Branch Drawing sprites.
import CoreGraphics
import TerminalSpriteGeometry

/// Holds one translated Branch Drawing glyph while its geometry stays cell-local.
struct BranchDrawingRenderGeometry {
    let geometry: BranchPixelGeometry
    let cellOrigin: CGPoint
}

/// Maps the contiguous 62-glyph Branch Drawing range without accepting scalar sequences.
enum BranchDrawingSprite {
    /// Coarse routing span for the classifier switch; exact membership stays in `pattern(for:)`.
    static let coarseRange: ClosedRange<UInt32> = 0xF5D0...0xF60D

    /// Per-node-pair connector masks in `BranchDirections` bit order
    /// (up=1/right=2/down=4/left=8), indexed by `nodeIndex / 2`.
    private static let nodeMasks: [UInt8] = [
        0, 2, 8, 10, 4, 1, 5, 6, 12, 3, 9, 7, 13, 14, 11, 15,
    ]

    static func pattern(for scalar: Unicode.Scalar) -> BranchDrawingPattern? {
        let value = scalar.value
        guard coarseRange.contains(value) else { return nil }
        let offset = Int(value - coarseRange.lowerBound)
        if offset < 30 {
            return BranchLinePattern(rawValue: offset).map(BranchDrawingPattern.line)
        }
        let nodeIndex = offset - 30
        let pair = nodeIndex / 2
        let filled = nodeIndex.isMultiple(of: 2)
        let directions = BranchDirections(rawValue: nodeMasks[pair])
        return .node(.init(directions: directions, filled: filled))
    }

    static func geometry(
        pattern: BranchDrawingPattern,
        row: Int,
        column: Int,
        metrics: TerminalRenderMetrics
    ) -> BranchDrawingRenderGeometry {
        let light = metrics.lightStrokePixels
        return BranchDrawingRenderGeometry(
            geometry: BranchDrawingSpriteGeometry.geometry(
                pattern: pattern,
                cellWidthPixels: metrics.cellWidthPixels,
                cellHeightPixels: metrics.cellHeightPixels,
                lightStrokePixels: light
            ),
            cellOrigin: CGPoint(
                x: CGFloat(column * metrics.cellWidthPixels) / metrics.displayScale,
                y: CGFloat(row * metrics.cellHeightPixels) / metrics.displayScale
            )
        )
    }
}
