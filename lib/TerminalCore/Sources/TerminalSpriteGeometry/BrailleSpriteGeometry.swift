// Cell-local physical-pixel allocation for the Unicode braille dot grid.

/// Holds the shared 2-column by 4-row braille grid independently from pattern
/// selection, terminal-cell placement, and any drawing framework. The grid is
/// permanently 2x4, so the dot positions are fixed inline scalars rather than
/// heap-allocated arrays: that encodes the shape invariant and keeps this tiny
/// immutable value allocation-free.
public struct BraillePixelLayout: Equatable, Sendable {
    public let dotSize: Int

    private let x0: Int
    private let x1: Int
    private let y0: Int
    private let y1: Int
    private let y2: Int
    private let y3: Int

    init(dotSize: Int, x0: Int, x1: Int, y0: Int, y1: Int, y2: Int, y3: Int) {
        self.dotSize = dotSize
        self.x0 = x0
        self.x1 = x1
        self.y0 = y0
        self.y1 = y1
        self.y2 = y2
        self.y3 = y3
    }

    /// Selects a dot rectangle from the allocated braille grid.
    public func rect(column: Int, row: Int) -> SpritePixelRect {
        SpritePixelRect(
            x: xPosition(column),
            y: yPosition(row),
            width: dotSize,
            height: dotSize
        )
    }

    private func xPosition(_ column: Int) -> Int {
        switch column {
        case 0: x0
        case 1: x1
        default: preconditionFailure("Invalid braille column")
        }
    }

    private func yPosition(_ row: Int) -> Int {
        switch row {
        case 0: y0
        case 1: y1
        case 2: y2
        case 3: y3
        default: preconditionFailure("Invalid braille row")
        }
    }
}

/// Allocates braille's complete dot grid as pure integer-pixel geometry so
/// renderers and future sprite infrastructure share one deterministic seam.
public enum BrailleSpriteGeometry {
    /// Coarse routing span for the shared vocabulary. Braille is dense: every scalar in the
    /// range is a member, so `pattern(for:)` is the dot bitmask itself.
    public static let coarseRange: ClosedRange<UInt32> = 0x2800...0x28FF

    /// Dots are allocated inside the cell's own pixel grid, so a row of braille cells keeps
    /// its ink inside its own band.
    public static let inkReach: SpriteInkReach = .band

    public static func pattern(for scalar: Unicode.Scalar) -> UInt8? {
        guard coarseRange.contains(scalar.value) else {
            return nil
        }
        return UInt8(scalar.value - coarseRange.lowerBound)
    }

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

        let yStep = dotSize + ySpacing
        return BraillePixelLayout(
            dotSize: dotSize,
            x0: xMargin,
            x1: xMargin + dotSize + xSpacing,
            y0: yMargin,
            y1: yMargin + yStep,
            y2: yMargin + 2 * yStep,
            y3: yMargin + 3 * yStep
        )
    }
}
