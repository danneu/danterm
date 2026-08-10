// Cell-local physical-pixel geometry for Ghostty's Branch Drawing private-use family.

/// Cardinal directions used by branch lines and node connectors.
public enum BranchDirection: UInt8, CaseIterable, Equatable, Sendable {
    case up, right, down, left

    /// This direction's single bit in a `BranchDirections` mask.
    public var mask: BranchDirections {
        switch self {
        case .up: .up
        case .right: .right
        case .down: .down
        case .left: .left
        }
    }
}

/// The cardinal edges carrying a connector on a Branch Drawing node, as a fixed
/// value-type bitmask over a four-element universe. Bit convention matches the
/// classifier's mask table (up=1/right=2/down=4/left=8); mirrors
/// `BlockElementQuadrants` and drops the per-value `Set` allocation.
public struct BranchDirections: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let up = Self(rawValue: 1 << 0)
    public static let right = Self(rawValue: 1 << 1)
    public static let down = Self(rawValue: 1 << 2)
    public static let left = Self(rawValue: 1 << 3)
}

/// The 30 non-node branch glyphs, ordered exactly as U+F5D0...U+F5ED.
public enum BranchLinePattern: Int, CaseIterable, Equatable, Sendable {
    case horizontal, vertical, fadeRight, fadeLeft, fadeDown, fadeUp
    case bottomRight, bottomLeft, topRight, topLeft
    case verticalTopRight, verticalBottomRight, rightPair
    case verticalTopLeft, verticalBottomLeft, leftPair
    case horizontalBottomLeft, horizontalBottomRight, bottomPair
    case horizontalTopLeft, horizontalTopRight, topPair
    case verticalTopPair, verticalBottomPair, horizontalLeftPair, horizontalRightPair
    case verticalTopLeftBottomRight, verticalTopRightBottomLeft
    case horizontalTopLeftBottomRight, horizontalTopRightBottomLeft
}

/// One of the 32 circle-node variants, with an optional connector at each edge.
public struct BranchNodePattern: Equatable, Sendable {
    public let directions: BranchDirections
    public let filled: Bool

    public init(directions: BranchDirections, filled: Bool) {
        self.directions = directions
        self.filled = filled
    }
}

/// Complete structural vocabulary for all 62 Branch Drawing glyphs.
public enum BranchDrawingPattern: Equatable, Sendable {
    case line(BranchLinePattern)
    case node(BranchNodePattern)
}

/// A hard-edged bar with a constant 8-bit foreground coverage.
public struct BranchPixelRect: Equatable, Sendable {
    public let rect: SpritePixelRect
    public let alpha: UInt8

    public init(rect: SpritePixelRect, alpha: UInt8 = 255) {
        self.rect = rect
        self.alpha = alpha
    }
}

/// A cell-local quadratic stroke used for the rounded branch corners.
public struct BranchPixelArc: Equatable, Sendable {
    public let start: SpritePixelPoint
    public let control: SpritePixelPoint
    public let end: SpritePixelPoint
    public let width: Int

    public init(start: SpritePixelPoint, control: SpritePixelPoint, end: SpritePixelPoint, width: Int) {
        self.start = start
        self.control = control
        self.end = end
        self.width = width
    }
}

/// A filled disk or an outlined ring centered on the shared box-drawing axes.
public struct BranchPixelNode: Equatable, Sendable {
    public let centerX: Double
    public let centerY: Double
    public let radius: Double
    public let strokeWidth: Int
    public let filled: Bool

    public init(centerX: Double, centerY: Double, radius: Double, strokeWidth: Int, filled: Bool) {
        self.centerX = centerX
        self.centerY = centerY
        self.radius = radius
        self.strokeWidth = strokeWidth
        self.filled = filled
    }
}

/// Collects the raster primitives needed to paint one Branch Drawing cell.
public struct BranchPixelGeometry: Equatable, Sendable {
    public let rects: [BranchPixelRect]
    public let arcs: [BranchPixelArc]
    public let node: BranchPixelNode?

    public init(rects: [BranchPixelRect], arcs: [BranchPixelArc], node: BranchPixelNode?) {
        self.rects = rects
        self.arcs = arcs
        self.node = node
    }
}

/// Resolves Branch Drawing into deterministic physical-pixel geometry.
public enum BranchDrawingSpriteGeometry {
    public static func geometry(
        pattern: BranchDrawingPattern,
        cellWidthPixels width: Int,
        cellHeightPixels height: Int,
        lightStrokePixels requestedLight: Int
    ) -> BranchPixelGeometry {
        precondition(width >= 0 && height >= 0 && requestedLight > 0)
        guard width > 0, height > 0 else {
            return BranchPixelGeometry(rects: [], arcs: [], node: nil)
        }
        let light = min(requestedLight, width, height)
        let left = (width - light) / 2
        let top = (height - light) / 2
        let cx = Double(left) + Double(light) / 2
        let cy = Double(top) + Double(light) / 2

        switch pattern {
        case let .line(line):
            return lineGeometry(line, width: width, height: height, light: light, cx: cx, cy: cy)
        case let .node(pattern):
            let radius = max(0, min(cx, cy, Double(width) - cx, Double(height) - cy))
            var rects: [BranchPixelRect] = []
            func append(_ direction: BranchDirection) {
                let x0: Int
                let y0: Int
                let x1: Int
                let y1: Int
                switch direction {
                case .up:
                    (x0, y0, x1, y1) = (left, 0, left + light, Int((cy - radius + Double(light) / 2).rounded(.up)))
                case .right:
                    (x0, y0, x1, y1) = (Int((cx + radius - Double(light) / 2).rounded(.down)), top, width, top + light)
                case .down:
                    (x0, y0, x1, y1) = (left, Int((cy + radius - Double(light) / 2).rounded(.down)), left + light, height)
                case .left:
                    (x0, y0, x1, y1) = (0, top, Int((cx - radius + Double(light) / 2).rounded(.up)), top + light)
                }
                if x0 < x1, y0 < y1 {
                    rects.append(.init(rect: .init(x: x0, y: y0, width: x1 - x0, height: y1 - y0)))
                }
            }
            for direction in BranchDirection.allCases where pattern.directions.contains(direction.mask) {
                append(direction)
            }
            return BranchPixelGeometry(
                rects: rects,
                arcs: [],
                node: BranchPixelNode(
                    centerX: cx,
                    centerY: cy,
                    radius: radius,
                    strokeWidth: light,
                    filled: pattern.filled
                )
            )
        }
    }

    private static func lineGeometry(
        _ pattern: BranchLinePattern,
        width: Int,
        height: Int,
        light: Int,
        cx: Double,
        cy: Double
    ) -> BranchPixelGeometry {
        let left = (width - light) / 2
        let top = (height - light) / 2
        let horizontal = BranchPixelRect(rect: .init(x: 0, y: top, width: width, height: light))
        let vertical = BranchPixelRect(rect: .init(x: left, y: 0, width: light, height: height))
        func fade(_ direction: BranchDirection) -> [BranchPixelRect] {
            let extent = direction == .left || direction == .right ? width : height
            return (0..<extent).map { index in
                let alpha = UInt8(clamping: Int((Double(
                    direction == .left || direction == .up ? index : extent - index
                ) * 255 / Double(extent)).rounded()))
                let rect = direction == .left || direction == .right
                    ? SpritePixelRect(x: index, y: top, width: 1, height: light)
                    : SpritePixelRect(x: left, y: index, width: light, height: 1)
                return BranchPixelRect(rect: rect, alpha: alpha)
            }
        }
        func arc(_ corner: BranchDirection) -> BranchPixelArc {
            switch corner {
            case .up: // top-left
                return .init(start: .init(x: Int(cx.rounded()), y: height), control: .init(x: Int(cx.rounded()), y: Int(cy.rounded())), end: .init(x: width, y: Int(cy.rounded())), width: light)
            case .right: // top-right
                return .init(start: .init(x: Int(cx.rounded()), y: height), control: .init(x: Int(cx.rounded()), y: Int(cy.rounded())), end: .init(x: 0, y: Int(cy.rounded())), width: light)
            case .down: // bottom-left
                return .init(start: .init(x: Int(cx.rounded()), y: 0), control: .init(x: Int(cx.rounded()), y: Int(cy.rounded())), end: .init(x: width, y: Int(cy.rounded())), width: light)
            case .left: // bottom-right
                return .init(start: .init(x: Int(cx.rounded()), y: 0), control: .init(x: Int(cx.rounded()), y: Int(cy.rounded())), end: .init(x: 0, y: Int(cy.rounded())), width: light)
            }
        }
        var rects: [BranchPixelRect] = []
        var arcs: [BranchPixelArc] = []
        switch pattern {
        case .horizontal: rects = [horizontal]
        case .vertical: rects = [vertical]
        case .fadeRight: rects = fade(.right)
        case .fadeLeft: rects = fade(.left)
        case .fadeDown: rects = fade(.down)
        case .fadeUp: rects = fade(.up)
        case .bottomRight: arcs = [arc(.left)]
        case .bottomLeft: arcs = [arc(.down)]
        case .topRight: arcs = [arc(.right)]
        case .topLeft: arcs = [arc(.up)]
        case .verticalTopRight: rects = [vertical]; arcs = [arc(.right)]
        case .verticalBottomRight: rects = [vertical]; arcs = [arc(.left)]
        case .rightPair: arcs = [arc(.right), arc(.left)]
        case .verticalTopLeft: rects = [vertical]; arcs = [arc(.up)]
        case .verticalBottomLeft: rects = [vertical]; arcs = [arc(.down)]
        case .leftPair: arcs = [arc(.up), arc(.down)]
        case .horizontalBottomLeft: rects = [horizontal]; arcs = [arc(.down)]
        case .horizontalBottomRight: rects = [horizontal]; arcs = [arc(.left)]
        case .bottomPair: arcs = [arc(.left), arc(.down)]
        case .horizontalTopLeft: rects = [horizontal]; arcs = [arc(.up)]
        case .horizontalTopRight: rects = [horizontal]; arcs = [arc(.right)]
        case .topPair: arcs = [arc(.right), arc(.up)]
        case .verticalTopPair: rects = [vertical]; arcs = [arc(.up), arc(.right)]
        case .verticalBottomPair: rects = [vertical]; arcs = [arc(.down), arc(.left)]
        case .horizontalLeftPair: rects = [horizontal]; arcs = [arc(.down), arc(.up)]
        case .horizontalRightPair: rects = [horizontal]; arcs = [arc(.right), arc(.left)]
        case .verticalTopLeftBottomRight: rects = [vertical]; arcs = [arc(.up), arc(.left)]
        case .verticalTopRightBottomLeft: rects = [vertical]; arcs = [arc(.right), arc(.down)]
        case .horizontalTopLeftBottomRight: rects = [horizontal]; arcs = [arc(.up), arc(.left)]
        case .horizontalTopRightBottomLeft: rects = [horizontal]; arcs = [arc(.right), arc(.down)]
        }
        return BranchPixelGeometry(rects: rects, arcs: arcs, node: nil)
    }
}
