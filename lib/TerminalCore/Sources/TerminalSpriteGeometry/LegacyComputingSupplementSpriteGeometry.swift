// Cell-local physical-pixel geometry for Symbols for Legacy Computing Supplement.
import Foundation

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
    /// The exact scalar sets this family implements, in Unicode order.
    public static let implementedRanges: [ClosedRange<UInt32>] = [
        0x1CC1B...0x1CC1E, 0x1CC21...0x1CC3F, 0x1CD00...0x1CDE5,
        0x1CE00...0x1CE01, 0x1CE0B...0x1CE0C, 0x1CE16...0x1CE19,
        0x1CE51...0x1CEAF,
    ]

    /// Coarse routing span (the `implementedRanges` envelope) for the shared vocabulary.
    /// Wider than the discontiguous membership decoded in `pattern(for:)`; interior gaps
    /// return nil there and fall to the font path.
    public static let coarseRange: ClosedRange<UInt32> = 0x1CC1B...0x1CEAF

    /// Every rect is clipped to the cell rectangle, so a row of these cells keeps its ink
    /// inside its own band.
    public static let inkReach: SpriteInkReach = .band

    public static func pattern(for scalar: Unicode.Scalar) -> LegacySupplementPattern? {
        let value = scalar.value
        switch value {
        case 0x1CC1B...0x1CC1E: return .box(UInt8(value - 0x1CC1B))
        case 0x1CC21...0x1CC2F: return .separatedQuadrants(UInt8(value - 0x1CC20))
        case 0x1CC30...0x1CC3F:
            return .circlePieces([circlePieces[Int(value - 0x1CC30)]])
        case 0x1CD00...0x1CDE5:
            return .octants(octantMasks[Int(value - 0x1CD00)])
        case 0x1CE00: return .splitCircle(vertical: true)
        case 0x1CE01: return .splitCircle(vertical: false)
        case 0x1CE0B:
            return .circlePieces([
                piece(0, 0, 1, 0.5, .topLeft),
                piece(0, 0, 1, 0.5, .bottomLeft),
            ])
        case 0x1CE0C:
            return .circlePieces([
                piece(1, 0, 1, 0.5, .topRight),
                piece(1, 0, 1, 0.5, .bottomRight),
            ])
        case 0x1CE16...0x1CE19: return .box(UInt8(value - 0x1CE12))
        case 0x1CE51...0x1CE8F: return .separatedSextants(UInt8(value - 0x1CE50))
        case 0x1CE90...0x1CEAF: return .sixteenth(index: Int(value - 0x1CE90))
        default: return nil
        }
    }

    private static let octantMasks: [UInt8] = [
        4,6,7,8,9,11,12,13,14,16,17,18,19,21,22,23,24,25,26,27,28,29,30,31,
        32,33,34,35,36,37,38,39,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,
        57,58,59,60,61,62,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,81,82,83,
        84,86,87,88,89,91,92,93,94,96,97,98,99,100,101,102,103,104,105,106,107,
        108,109,110,111,112,113,114,115,116,117,118,119,120,121,122,123,124,125,
        126,127,129,130,131,132,133,134,135,136,137,138,139,140,141,142,143,144,
        145,146,147,148,149,150,151,152,153,154,155,156,157,158,159,161,162,163,
        164,166,167,168,169,171,172,173,174,176,177,178,179,180,181,182,183,184,
        185,186,187,188,189,190,191,193,194,195,196,197,198,199,200,201,202,203,
        204,205,206,207,208,209,210,211,212,213,214,215,216,217,218,219,220,221,
        222,223,224,225,226,227,228,229,230,231,232,233,234,235,236,237,238,239,
        241,242,243,244,246,247,248,249,251,253,254,
    ]

    private static func piece(
        _ x: Double, _ y: Double, _ width: Double, _ height: Double,
        _ corner: LegacySupplementArcCorner
    ) -> LegacySupplementCirclePiece {
        LegacySupplementCirclePiece(
            xCells: x, yCells: y, widthCells: width, heightCells: height, corner: corner
        )
    }

    private static let circlePieces: [LegacySupplementCirclePiece] = [
        piece(0, 0, 2, 2, .topLeft),
        piece(1, 0, 2, 2, .topLeft),
        piece(2, 0, 2, 2, .topRight),
        piece(3, 0, 2, 2, .topRight),
        piece(0, 1, 2, 2, .topLeft),
        piece(0, 0, 1, 1, .topLeft),
        piece(1, 0, 1, 1, .topRight),
        piece(3, 1, 2, 2, .topRight),
        piece(0, 2, 2, 2, .bottomLeft),
        piece(0, 1, 1, 1, .bottomLeft),
        piece(1, 1, 1, 1, .bottomRight),
        piece(3, 2, 2, 2, .bottomRight),
        piece(0, 3, 2, 2, .bottomLeft),
        piece(1, 3, 2, 2, .bottomLeft),
        piece(2, 3, 2, 2, .bottomRight),
        piece(3, 3, 2, 2, .bottomRight),
    ]

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
            return splitCircle(vertical: vertical, width: width, height: height, thickness: thickness)
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

    // U+1CE00 "RIGHT HALF AND LEFT HALF WHITE CIRCLE" and U+1CE01 "LOWER HALF AND UPPER
    // HALF WHITE CIRCLE" are each two whole circles centered on opposite cell edges, so
    // only the inward half of each survives `ellipseOutline`'s cell-bounded scan -- the
    // same clipping trick `circlePiece` uses. Both circles get the isotropic radius
    // min(width, height) / 2 the character names imply, which is why an anisotropic cell
    // leaves a gap along its longer axis instead of stretching the halves to the corners.
    private static func splitCircle(
        vertical: Bool, width: Int, height: Int, thickness: Int
    ) -> [SpritePixelRect] {
        let radius = Double(min(width, height)) / 2
        let centers: [(x: Double, y: Double)] = vertical
            ? [(0, Double(height) / 2), (Double(width), Double(height) / 2)]
            : [(Double(width) / 2, 0), (Double(width) / 2, Double(height))]
        return centers.flatMap { center in
            ellipseOutline(
                centerX: center.x, centerY: center.y, radiusX: radius, radiusY: radius,
                width: width, height: height, thickness: thickness
            )
        }
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
        width: Int, height: Int, thickness: Int,
        corner: LegacySupplementArcCorner? = nil
    ) -> [SpritePixelRect] {
        guard radiusX > 0 && radiusY > 0 else { return [] }
        let tolerance = Double(thickness) / max(1, min(radiusX, radiusY))
        // Shared by the main scan and the empty-result fallback below: the fallback is
        // what keeps the degenerate-size nearest-pixel pick inside the requested
        // quadrant, so a second copy edited on one side only would silently move it.
        func inCorner(_ dx: Double, _ dy: Double) -> Bool {
            switch corner {
            case .topLeft: dx <= 0 && dy <= 0
            case .topRight: dx >= 0 && dy <= 0
            case .bottomLeft: dx <= 0 && dy >= 0
            case .bottomRight: dx >= 0 && dy >= 0
            case nil: true
            }
        }
        var result: [SpritePixelRect] = []
        for y in 0..<height {
            for x in 0..<width {
                let dx = (Double(x) + 0.5 - centerX) / radiusX
                let dy = (Double(y) + 0.5 - centerY) / radiusY
                let distance = sqrt(dx * dx + dy * dy)
                if inCorner(dx, dy) && abs(distance - 1) <= tolerance {
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
                    guard inCorner(dx, dy) else { continue }
                    let error = abs(sqrt(dx * dx + dy * dy) - 1)
                    if error < nearest.error {
                        nearest = (x, y, error)
                    }
                }
            }
            result = [SpritePixelRect(x: nearest.x, y: nearest.y, width: 1, height: 1)]
        }
        return result
    }
}
