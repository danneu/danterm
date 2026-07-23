// Pure Unicode classification and pixel-quantized geometry for braille sprites.
import CoreGraphics

/// Identifies one position in the Unicode braille 2x4 dot grid.
struct BrailleDot: Equatable, Sendable {
    let column: Int
    let row: Int
}

/// Describes one half-open dot rectangle in cell-local physical pixels.
struct BraillePixelRect: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

/// Separates braille's local integer-pixel allocation from cell placement and point conversion.
struct BraillePixelLayout: Equatable, Sendable {
    let dotSize: Int
    let xPositions: [Int]
    let yPositions: [Int]

    /// Selects a dot rectangle from the shared 2-column by 4-row grid.
    func rect(for dot: BrailleDot) -> BraillePixelRect {
        BraillePixelRect(
            x: xPositions[dot.column],
            y: yPositions[dot.row],
            width: dotSize,
            height: dotSize
        )
    }
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

    /// Allocates the shared dot grid before pattern selection or terminal-cell translation.
    static func layout(
        cellWidthPixels: Int,
        cellHeightPixels: Int
    ) -> BraillePixelLayout {
        var dotSize = min(cellWidthPixels / 4, cellHeightPixels / 8)
        var xSpacing = cellWidthPixels / 4
        var ySpacing = cellHeightPixels / 8
        var xMargin = xSpacing / 2
        var yMargin = ySpacing / 2
        var horizontalRemainder =
            cellWidthPixels - 2 * xMargin - xSpacing - 2 * dotSize
        var verticalRemainder =
            cellHeightPixels - 2 * yMargin - 3 * ySpacing - 4 * dotSize

        if dotSize == 0, horizontalRemainder >= 2, verticalRemainder >= 4 {
            dotSize += 1
            horizontalRemainder -= 2
            verticalRemainder -= 4
        }

        if xMargin == 0, horizontalRemainder >= 2 {
            xMargin += 1
            horizontalRemainder -= 2
        }
        if yMargin == 0, verticalRemainder >= 2 {
            yMargin += 1
            verticalRemainder -= 2
        }

        if horizontalRemainder >= 1 {
            xSpacing += 1
            horizontalRemainder -= 1
        }
        if verticalRemainder >= 3 {
            ySpacing += 1
            verticalRemainder -= 3
        }

        if horizontalRemainder >= 2 {
            xMargin += 1
            horizontalRemainder -= 2
        }
        if verticalRemainder >= 2 {
            yMargin += 1
            verticalRemainder -= 2
        }

        if horizontalRemainder >= 2, verticalRemainder >= 4 {
            dotSize += 1
            horizontalRemainder -= 2
            verticalRemainder -= 4
        }

        assert(horizontalRemainder >= 0)
        assert(verticalRemainder >= 0)
        assert(horizontalRemainder < 2 || verticalRemainder < 4)
        assert(2 * xMargin + xSpacing + 2 * dotSize <= cellWidthPixels)
        assert(2 * yMargin + 3 * ySpacing + 4 * dotSize <= cellHeightPixels)

        let xPositions = [
            xMargin,
            xMargin + dotSize + xSpacing,
        ]
        let yPositions = (0..<4).map { row in
            yMargin + row * (dotSize + ySpacing)
        }
        return BraillePixelLayout(
            dotSize: dotSize,
            xPositions: xPositions,
            yPositions: yPositions
        )
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
        let layout = layout(
            cellWidthPixels: cellWidth,
            cellHeightPixels: cellHeight
        )
        let cellX = column * cellWidth
        let cellY = row * cellHeight

        for bit in 0..<8 where pattern & (1 << bit) != 0 {
            let dot = dot(forBit: bit)
            let pixelRect = layout.rect(for: dot)
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
