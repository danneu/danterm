// Pure cell-local physical-pixel geometry for Unicode Block Elements.

/// Selects an edge or the full axis for an aligned Block Elements fill.
public enum BlockElementAlignment: Equatable, Sendable {
    case start
    case end
    case full
}

/// Identifies quadrants using the Unicode Block Elements top-to-bottom layout.
public struct BlockElementQuadrants: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let topLeft = Self(rawValue: 1 << 0)
    public static let topRight = Self(rawValue: 1 << 1)
    public static let bottomLeft = Self(rawValue: 1 << 2)
    public static let bottomRight = Self(rawValue: 1 << 3)
}

/// Carries the intensity of the three shade glyphs without coupling geometry
/// to a drawing framework or a concrete foreground color.
public enum BlockElementShade: UInt8, Equatable, Hashable, Sendable {
    case light = 64
    case medium = 128
    case dark = 192
    case solid = 255
}

/// Describes the finite geometry vocabulary used by U+2580...U+259F.
public enum BlockElementPattern: Equatable, Sendable {
    case aligned(
        horizontal: BlockElementAlignment,
        vertical: BlockElementAlignment,
        widthEighths: Int,
        heightEighths: Int
    )
    case full(shade: BlockElementShade)
    case quadrants(BlockElementQuadrants)
}

/// Allocates Block Elements as contained half-open rectangles in physical
/// pixels, including controlled one-pixel overlap at odd quadrant boundaries.
public enum BlockElementSpriteGeometry {
    /// Coarse routing span for the shared vocabulary; exact membership stays in `pattern(for:)`.
    public static let coarseRange: ClosedRange<UInt32> = 0x2580...0x259F

    /// Every pattern is a contained rectangle set, so a row of these cells keeps its ink
    /// inside its own band.
    public static let inkReach: SpriteInkReach = .band

    public static func pattern(for scalar: Unicode.Scalar) -> BlockElementPattern? {
        let value = scalar.value
        guard coarseRange.contains(value) else {
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
                heightEighths: Int(value - coarseRange.lowerBound)
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

    public static func rects(
        pattern: BlockElementPattern,
        cellWidthPixels: Int,
        cellHeightPixels: Int
    ) -> [SpritePixelRect] {
        precondition(cellWidthPixels >= 0 && cellHeightPixels >= 0)

        switch pattern {
        case let .aligned(horizontal, vertical, widthEighths, heightEighths):
            precondition((1...8).contains(widthEighths))
            precondition((1...8).contains(heightEighths))
            let width = roundedPart(widthEighths, of: 8, size: cellWidthPixels)
            let height = roundedPart(heightEighths, of: 8, size: cellHeightPixels)
            guard width > 0 && height > 0 else { return [] }
            return [SpritePixelRect(
                x: origin(for: horizontal, size: cellWidthPixels, extent: width),
                y: origin(for: vertical, size: cellHeightPixels, extent: height),
                width: width,
                height: height
            )]

        case .full:
            guard cellWidthPixels > 0 && cellHeightPixels > 0 else { return [] }
            return [SpritePixelRect(
                x: 0,
                y: 0,
                width: cellWidthPixels,
                height: cellHeightPixels
            )]

        case let .quadrants(quadrants):
            let leftMax = roundedPart(1, of: 2, size: cellWidthPixels)
            let rightMin = cellWidthPixels - leftMax
            let topMax = roundedPart(1, of: 2, size: cellHeightPixels)
            let bottomMin = cellHeightPixels - topMax
            let candidates: [(BlockElementQuadrants, SpritePixelRect)] = [
                (.topLeft, SpritePixelRect(x: 0, y: 0, width: leftMax, height: topMax)),
                (
                    .topRight,
                    SpritePixelRect(
                        x: rightMin,
                        y: 0,
                        width: cellWidthPixels - rightMin,
                        height: topMax
                    )
                ),
                (
                    .bottomLeft,
                    SpritePixelRect(
                        x: 0,
                        y: bottomMin,
                        width: leftMax,
                        height: cellHeightPixels - bottomMin
                    )
                ),
                (
                    .bottomRight,
                    SpritePixelRect(
                        x: rightMin,
                        y: bottomMin,
                        width: cellWidthPixels - rightMin,
                        height: cellHeightPixels - bottomMin
                    )
                ),
            ]
            return candidates.compactMap { quadrant, rect in
                quadrants.contains(quadrant) && rect.width > 0 && rect.height > 0
                    ? rect
                    : nil
            }
        }
    }

    private static func roundedPart(_ numerator: Int, of denominator: Int, size: Int) -> Int {
        (size * numerator + denominator / 2) / denominator
    }

    private static func origin(
        for alignment: BlockElementAlignment,
        size: Int,
        extent: Int
    ) -> Int {
        switch alignment {
        case .start, .full: 0
        case .end: size - extent
        }
    }
}
