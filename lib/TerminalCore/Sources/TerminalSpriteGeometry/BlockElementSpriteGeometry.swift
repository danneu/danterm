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
