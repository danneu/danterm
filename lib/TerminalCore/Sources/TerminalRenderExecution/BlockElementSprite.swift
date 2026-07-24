// Exact Unicode classification and render-boundary conversion for Block Elements.
import CoreGraphics
import TerminalSpriteGeometry

/// Maps the complete Block Elements range to its pure physical-pixel geometry.
enum BlockElementSprite {
    /// Coarse routing span for the classifier switch; exact membership stays in `pattern(for:)`.
    static let coarseRange: ClosedRange<UInt32> = 0x2580...0x259F

    static func pattern(for scalar: Unicode.Scalar) -> BlockElementPattern? {
        let value = scalar.value
        guard (0x2580...0x259F).contains(value) else {
            return nil
        }

        return switch value {
        case 0x2580:
            .aligned(horizontal: .full, vertical: .start, widthEighths: 8, heightEighths: 4)
        case 0x2581...0x2587:
            .aligned(
                horizontal: .full,
                vertical: .end,
                widthEighths: 8,
                heightEighths: Int(value - 0x2580)
            )
        case 0x2588:
            .full(shade: .solid)
        case 0x2589...0x258F:
            .aligned(
                horizontal: .start,
                vertical: .full,
                widthEighths: Int(0x2590 - value),
                heightEighths: 8
            )
        case 0x2590:
            .aligned(horizontal: .end, vertical: .full, widthEighths: 4, heightEighths: 8)
        case 0x2591:
            .full(shade: .light)
        case 0x2592:
            .full(shade: .medium)
        case 0x2593:
            .full(shade: .dark)
        case 0x2594:
            .aligned(horizontal: .full, vertical: .start, widthEighths: 8, heightEighths: 1)
        case 0x2595:
            .aligned(horizontal: .end, vertical: .full, widthEighths: 1, heightEighths: 8)
        case 0x2596:
            .quadrants([.bottomLeft])
        case 0x2597:
            .quadrants([.bottomRight])
        case 0x2598:
            .quadrants([.topLeft])
        case 0x2599:
            .quadrants([.topLeft, .bottomLeft, .bottomRight])
        case 0x259A:
            .quadrants([.topLeft, .bottomRight])
        case 0x259B:
            .quadrants([.topLeft, .topRight, .bottomLeft])
        case 0x259C:
            .quadrants([.topLeft, .topRight, .bottomRight])
        case 0x259D:
            .quadrants([.topRight])
        case 0x259E:
            .quadrants([.topRight, .bottomLeft])
        default:
            .quadrants([.topRight, .bottomLeft, .bottomRight])
        }
    }

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
