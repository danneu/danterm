// Pure Unicode classification and pixel-quantized geometry for braille sprites.
import CoreGraphics
import TerminalSpriteGeometry

/// Identifies one position in the Unicode braille 2x4 dot grid.
struct BrailleDot: Equatable, Sendable {
    let column: Int
    let row: Int
}

/// Keeps exact braille membership and geometry independent from font fallback.
enum BrailleSprite {
    /// Coarse routing span for the classifier switch; exact membership stays in `pattern(for:)`.
    static let coarseRange: ClosedRange<UInt32> = 0x2800...0x28FF

    static func pattern(for scalars: [Unicode.Scalar]) -> UInt8? {
        guard scalars.count == 1, let scalar = scalars.first,
              (0x2800...0x28FF).contains(scalar.value)
        else {
            return nil
        }
        return UInt8(scalar.value - 0x2800)
    }

    static func dots(for scalars: [Unicode.Scalar]) -> [BrailleDot]? {
        guard let pattern = pattern(for: scalars) else { return nil }
        return (0..<8).compactMap { bit in
            guard pattern & (1 << bit) != 0 else { return nil }
            return dot(forBit: bit)
        }
    }

    static func rects(
        for scalar: Unicode.Scalar,
        row: Int,
        column: Int,
        metrics: TerminalRenderMetrics
    ) -> [CGRect] {
        guard let pattern = pattern(for: [scalar]) else { return [] }
        var rects: [CGRect] = []
        rects.reserveCapacity(pattern.nonzeroBitCount)
        appendRects(
            pattern: pattern,
            row: row,
            column: column,
            metrics: metrics,
            to: &rects
        )
        return rects
    }

    static func appendRects(
        pattern: UInt8,
        row: Int,
        column: Int,
        metrics: TerminalRenderMetrics,
        to rects: inout [CGRect]
    ) {
        let layout = BrailleSpriteGeometry.layout(
            cellWidthPixels: metrics.cellWidthPixels,
            cellHeightPixels: metrics.cellHeightPixels
        )
        appendRects(
            pattern: pattern,
            row: row,
            column: column,
            metrics: metrics,
            layout: layout,
            to: &rects
        )
    }

    /// Emits braille dot rects against a caller-supplied layout. The draw loop
    /// builds the layout once per draw (it depends only on `metrics`, which is
    /// constant across a draw) and reuses it for every braille cell, so the hot
    /// path pays no per-cell `BraillePixelLayout` allocation. The convenience
    /// `appendRects(...)` overload above builds the layout itself for off-hot-path
    /// callers.
    static func appendRects(
        pattern: UInt8,
        row: Int,
        column: Int,
        metrics: TerminalRenderMetrics,
        layout: BraillePixelLayout,
        to rects: inout [CGRect]
    ) {
        let scale = metrics.displayScale
        let cellWidth = metrics.cellWidthPixels
        let cellX = column * cellWidth
        let cellY = row * metrics.cellHeightPixels

        for bit in 0..<8 where pattern & (1 << bit) != 0 {
            let dot = dot(forBit: bit)
            let pixelRect = layout.rect(column: dot.column, row: dot.row)
            rects.append(CGRect(
                x: CGFloat(cellX + pixelRect.x) / scale,
                y: CGFloat(cellY + pixelRect.y) / scale,
                width: CGFloat(pixelRect.width) / scale,
                height: CGFloat(pixelRect.height) / scale
            ))
        }
    }

    private static func dot(forBit bit: Int) -> BrailleDot {
        switch bit {
        case 0: BrailleDot(column: 0, row: 0)
        case 1: BrailleDot(column: 0, row: 1)
        case 2: BrailleDot(column: 0, row: 2)
        case 3: BrailleDot(column: 1, row: 0)
        case 4: BrailleDot(column: 1, row: 1)
        case 5: BrailleDot(column: 1, row: 2)
        case 6: BrailleDot(column: 0, row: 3)
        default: BrailleDot(column: 1, row: 3)
        }
    }
}
