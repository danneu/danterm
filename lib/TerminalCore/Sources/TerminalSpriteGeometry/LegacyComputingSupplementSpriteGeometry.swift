// Cell-local physical-pixel geometry for Symbols for Legacy Computing Supplement.
import Foundation

/// Identifies the elementary regions used by the supplement's block mosaics.
public enum LegacySupplementRegion: Int, Equatable, Sendable {
    case one, two, three, four, five, six, seven, eight
}

/// Selects one quarter of a translated ellipse outline.
public enum LegacySupplementArcCorner: Equatable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
}

/// Describes Ghostty's cell-relative ellipse construction without carrying a codepoint.
public struct LegacySupplementCirclePiece: Equatable, Sendable {
    public let xCells: Double
    public let yCells: Double
    public let widthCells: Double
    public let heightCells: Double
    public let corner: LegacySupplementArcCorner

    public init(
        xCells: Double,
        yCells: Double,
        widthCells: Double,
        heightCells: Double,
        corner: LegacySupplementArcCorner
    ) {
        self.xCells = xCells
        self.yCells = yCells
        self.widthCells = widthCells
        self.heightCells = heightCells
        self.corner = corner
    }
}

/// Keeps Unicode decoding outside pure geometry while describing every supported shape class.
public enum LegacySupplementPattern: Equatable, Sendable {
    case box(UInt8)
    case separatedQuadrants(UInt8)
    case circlePieces([LegacySupplementCirclePiece])
    case octants(UInt8)
    case splitCircle(vertical: Bool)
    case separatedSextants(UInt8)
    case sixteenth(index: Int)
}

/// Produces clipped, pixel-aligned coverage for every supplement sprite.
public enum LegacyComputingSupplementSpriteGeometry {
    public static func rects(
        pattern: LegacySupplementPattern,
        cellWidthPixels width: Int,
        cellHeightPixels height: Int,
        thicknessPixels thickness: Int
    ) -> [SpritePixelRect] {
        precondition(width >= 0 && height >= 0 && thickness > 0)
        guard width > 0 && height > 0 else { return [] }
        switch pattern {
        case let .box(bits):
            return boxRects(bits: bits, width: width, height: height, thickness: thickness)
        case let .separatedQuadrants(bits):
            return separated(bits: bits, columns: 2, rows: 2, width: width, height: height)
        case let .circlePieces(pieces):
            return pieces.flatMap {
                circlePiece($0, width: width, height: height, thickness: thickness)
            }
        case let .octants(bits):
            return tiled(bits: bits, columns: 2, rows: 4, width: width, height: height)
        case let .splitCircle(vertical):
            return ellipseOutline(
                centerX: Double(width) / 2, centerY: Double(height) / 2,
                radiusX: Double(width) / 2, radiusY: Double(height) / 2,
                width: width, height: height, thickness: thickness,
                splitVertical: vertical
            )
        case let .separatedSextants(bits):
            return separated(bits: bits, columns: 2, rows: 3, width: width, height: height)
        case let .sixteenth(index):
            return sixteenth(index: index, width: width, height: height)
        }
    }

    private static func boxRects(
        bits: UInt8, width: Int, height: Int, thickness: Int
    ) -> [SpritePixelRect] {
        let t = min(thickness, min(width, height))
        let midX = width / 2
        let midY = height / 2
        let centerX = max(0, min(width - t, midX - t / 2))
        let centerY = max(0, min(height - t, midY - t / 2))
        var result: [SpritePixelRect] = []
        switch bits {
        case 0:
            result = [
                SpritePixelRect(x: 0, y: centerY, width: width, height: t),
                SpritePixelRect(x: width - t, y: 0, width: t, height: midY),
            ]
        case 1:
            result = [
                SpritePixelRect(x: 0, y: centerY, width: width, height: t),
                SpritePixelRect(x: width - t, y: midY, width: t, height: height - midY),
            ]
        case 2:
            result = [
                SpritePixelRect(x: 0, y: 0, width: width, height: t),
                SpritePixelRect(x: 0, y: 0, width: t, height: midY),
            ]
        case 3:
            result = [
                SpritePixelRect(x: 0, y: height - t, width: width, height: t),
                SpritePixelRect(x: 0, y: midY, width: t, height: height - midY),
            ]
        case 4:
            result = [
                SpritePixelRect(x: centerX, y: 0, width: t, height: height),
                SpritePixelRect(x: midX, y: 0, width: width - midX, height: t),
            ]
        case 5:
            result = [
                SpritePixelRect(x: centerX, y: 0, width: t, height: height),
                SpritePixelRect(x: midX, y: height - t, width: width - midX, height: t),
            ]
        case 6:
            result = [
                SpritePixelRect(x: centerX, y: 0, width: t, height: height),
                SpritePixelRect(x: 0, y: 0, width: midX, height: t),
            ]
        default:
            result = [
                SpritePixelRect(x: centerX, y: 0, width: t, height: height),
                SpritePixelRect(x: 0, y: height - t, width: midX, height: t),
            ]
        }
        return result.filter { $0.width > 0 && $0.height > 0 }
    }

    private static func tiled(
        bits: UInt8, columns: Int, rows: Int, width: Int, height: Int
    ) -> [SpritePixelRect] {
        (0..<(columns * rows)).compactMap { index in
            guard bits & (1 << index) != 0 else { return nil }
            let column = index % columns
            let row = index / columns
            let x0 = column * width / columns
            let x1 = (column + 1) * width / columns
            let y0 = row * height / rows
            let y1 = (row + 1) * height / rows
            guard x1 > x0 && y1 > y0 else { return nil }
            return SpritePixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
    }

    private static func separated(
        bits: UInt8, columns: Int, rows: Int, width: Int, height: Int
    ) -> [SpritePixelRect] {
        let gap = max(1, width / 12)
        return (0..<(columns * rows)).compactMap { index in
            guard bits & (1 << index) != 0 else { return nil }
            let column = index % columns
            let row = index / columns
            let x0 = column * width / columns + gap
            let x1 = (column + 1) * width / columns - gap
            let y0 = row * height / rows + gap
            let y1 = (row + 1) * height / rows - gap
            guard x1 > x0 && y1 > y0 else { return nil }
            return SpritePixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
    }

    // Compile-time-constant quarter-grid spans for the 32 sixteenth blocks. Hoisted to
    // `static let` so each per-cell draw reuses one shared instance rather than
    // rebuilding the array literal.
    private static let sixteenthRanges: [(Int, Int, Int, Int)] = [
        (0,1,0,1),(1,2,0,1),(2,3,0,1),(3,4,0,1),
        (0,1,1,2),(1,2,1,2),(2,3,1,2),(3,4,1,2),
        (0,1,2,3),(1,2,2,3),(2,3,2,3),(3,4,2,3),
        (0,1,3,4),(1,2,3,4),(2,3,3,4),(3,4,3,4),
        (2,4,3,4),(1,4,3,4),(0,3,3,4),(0,2,3,4),
        (0,1,2,4),(0,1,1,4),(0,1,0,3),(0,1,0,2),
        (0,2,0,1),(0,3,0,1),(1,4,0,1),(2,4,0,1),
        (3,4,0,2),(3,4,0,3),(3,4,1,4),(3,4,2,4),
    ]

    private static func sixteenth(index: Int, width: Int, height: Int) -> [SpritePixelRect] {
        let range = sixteenthRanges[index]
        let x0 = range.0 * width / 4, x1 = range.1 * width / 4
        let y0 = range.2 * height / 4, y1 = range.3 * height / 4
        return [SpritePixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)]
    }

    private static func circlePiece(
        _ piece: LegacySupplementCirclePiece,
        width: Int,
        height: Int,
        thickness: Int
    ) -> [SpritePixelRect] {
        let radiusX = Double(width) * piece.widthCells
        let radiusY = Double(height) * piece.heightCells
        let xOffset = Double(width) * piece.xCells
        let yOffset = Double(height) * piece.yCells
        let centerX: Double
        let centerY: Double
        let visibleCorner: LegacySupplementArcCorner
        switch piece.corner {
        case .topLeft:
            centerX = -xOffset
            centerY = -yOffset
            visibleCorner = .bottomRight
        case .topRight:
            centerX = 2 * radiusX - xOffset
            centerY = -yOffset
            visibleCorner = .bottomLeft
        case .bottomLeft:
            centerX = -xOffset
            centerY = 2 * radiusY - yOffset
            visibleCorner = .topRight
        case .bottomRight:
            centerX = 2 * radiusX - xOffset
            centerY = 2 * radiusY - yOffset
            visibleCorner = .topLeft
        }
        return ellipseOutline(
            centerX: centerX, centerY: centerY, radiusX: radiusX, radiusY: radiusY,
            width: width, height: height, thickness: thickness,
            corner: visibleCorner
        )
    }

    private static func ellipseOutline(
        centerX: Double, centerY: Double, radiusX: Double, radiusY: Double,
        width: Int, height: Int, thickness: Int, splitVertical: Bool = false,
        corner: LegacySupplementArcCorner? = nil
    ) -> [SpritePixelRect] {
        guard radiusX > 0 && radiusY > 0 else { return [] }
        let tolerance = Double(thickness) / max(1, min(radiusX, radiusY))
        var result: [SpritePixelRect] = []
        for y in 0..<height {
            for x in 0..<width {
                let dx = (Double(x) + 0.5 - centerX) / radiusX
                let dy = (Double(y) + 0.5 - centerY) / radiusY
                let distance = sqrt(dx * dx + dy * dy)
                let inCorner = switch corner {
                case .topLeft: dx <= 0 && dy <= 0
                case .topRight: dx >= 0 && dy <= 0
                case .bottomLeft: dx <= 0 && dy >= 0
                case .bottomRight: dx >= 0 && dy >= 0
                case nil: true
                }
                if inCorner && abs(distance - 1) <= tolerance {
                    result.append(SpritePixelRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        if result.isEmpty {
            var nearest = (x: 0, y: 0, error: Double.greatestFiniteMagnitude)
            for y in 0..<height {
                for x in 0..<width {
                    let dx = (Double(x) + 0.5 - centerX) / radiusX
                    let dy = (Double(y) + 0.5 - centerY) / radiusY
                    let inCorner = switch corner {
                    case .topLeft: dx <= 0 && dy <= 0
                    case .topRight: dx >= 0 && dy <= 0
                    case .bottomLeft: dx <= 0 && dy >= 0
                    case .bottomRight: dx >= 0 && dy >= 0
                    case nil: true
                    }
                    guard inCorner else { continue }
                    let error = abs(sqrt(dx * dx + dy * dy) - 1)
                    if error < nearest.error {
                        nearest = (x, y, error)
                    }
                }
            }
            result = [SpritePixelRect(x: nearest.x, y: nearest.y, width: 1, height: 1)]
        }
        if splitVertical {
            // Both half outlines deliberately meet at the cell center.
            return result
        }
        return result
    }
}
