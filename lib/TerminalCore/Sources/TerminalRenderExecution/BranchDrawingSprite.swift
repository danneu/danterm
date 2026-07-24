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

    static func pattern(for scalars: [Unicode.Scalar]) -> BranchDrawingPattern? {
        guard scalars.count == 1, let value = scalars.first?.value,
              (0xF5D0...0xF60D).contains(value)
        else { return nil }
        let offset = Int(value - 0xF5D0)
        if offset < 30 {
            return BranchLinePattern(rawValue: offset).map(BranchDrawingPattern.line)
        }
        let nodeIndex = offset - 30
        let masks: [UInt8] = [
            0, 2, 8, 10, 4, 1, 5, 6, 12, 3, 9, 7, 13, 14, 11, 15,
        ]
        let pair = nodeIndex / 2
        let filled = nodeIndex.isMultiple(of: 2)
        let mask = masks[pair]
        let directions = Set(BranchDirection.allCases.filter { direction in
            let bit: UInt8 = switch direction {
            case .up: 1
            case .right: 2
            case .down: 4
            case .left: 8
            }
            return mask & bit != 0
        })
        return .node(.init(directions: directions, filled: filled))
    }

    static func geometry(
        pattern: BranchDrawingPattern,
        row: Int,
        column: Int,
        metrics: TerminalRenderMetrics
    ) -> BranchDrawingRenderGeometry {
        let light = max(1, Int((metrics.underlineThickness * metrics.displayScale).rounded()))
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
