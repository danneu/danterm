// Pure Unicode classification and pixel-quantized geometry for braille sprites.
import CoreGraphics

/// Identifies one position in the Unicode braille 2x4 dot grid.
struct BrailleDot: Equatable, Sendable {
    let column: Int
    let row: Int
}

/// Keeps exact braille membership and geometry independent from font fallback.
enum BrailleSprite {
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
        let scale = metrics.displayScale
        let cellWidth = metrics.cellWidthPixels
        let cellHeight = metrics.cellHeightPixels
        let dotWidth = max(1, cellWidth / 4)
        let dotHeight = max(1, min(dotWidth, cellHeight / 8))
        let cellX = column * cellWidth
        let cellY = row * cellHeight

        for bit in 0..<8 where pattern & (1 << bit) != 0 {
            let dot = dot(forBit: bit)
            let slotMinX = dot.column * cellWidth / 2
            let slotMaxX = (dot.column + 1) * cellWidth / 2
            let slotMinY = dot.row * cellHeight / 4
            let slotMaxY = (dot.row + 1) * cellHeight / 4
            let x = cellX + slotMinX + (slotMaxX - slotMinX - dotWidth) / 2
            let y = cellY + slotMinY + (slotMaxY - slotMinY - dotHeight) / 2
            rects.append(CGRect(
                x: CGFloat(x) / scale,
                y: CGFloat(y) / scale,
                width: CGFloat(dotWidth) / scale,
                height: CGFloat(dotHeight) / scale
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
