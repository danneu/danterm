// Cell-local physical-pixel allocation for the Unicode braille dot grid.

/// Holds the shared 2-column by 4-row braille grid independently from pattern
/// selection, terminal-cell placement, and any drawing framework.
public struct BraillePixelLayout: Equatable, Sendable {
    public let dotSize: Int
    public let xPositions: [Int]
    public let yPositions: [Int]

    /// Selects a dot rectangle from the allocated braille grid.
    public func rect(column: Int, row: Int) -> SpritePixelRect {
        SpritePixelRect(
            x: xPositions[column],
            y: yPositions[row],
            width: dotSize,
            height: dotSize
        )
    }
}

/// Allocates braille's complete dot grid as pure integer-pixel geometry so
/// renderers and future sprite infrastructure share one deterministic seam.
public enum BrailleSpriteGeometry {
    public static func layout(
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
}
