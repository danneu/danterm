// Exact Unicode classification and render-boundary conversion for supplement sprites.
import CoreGraphics
import TerminalSpriteGeometry

/// Maps exactly the Symbols for Legacy Computing Supplement glyphs implemented by Ghostty.
enum LegacyComputingSupplementSprite {
    static let implementedRanges: [ClosedRange<UInt32>] = [
        0x1CC1B...0x1CC1E, 0x1CC21...0x1CC3F, 0x1CD00...0x1CDE5,
        0x1CE00...0x1CE01, 0x1CE0B...0x1CE0C, 0x1CE16...0x1CE19,
        0x1CE51...0x1CEAF,
    ]

    static func pattern(for scalars: [Unicode.Scalar]) -> LegacySupplementPattern? {
        guard scalars.count == 1, let value = scalars.first?.value else { return nil }
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

    static func appendRects(
        pattern: LegacySupplementPattern,
        row: Int,
        column: Int,
        metrics: TerminalRenderMetrics,
        to rects: inout [CGRect]
    ) {
        let scale = metrics.displayScale
        let originX = column * metrics.cellWidthPixels
        let originY = row * metrics.cellHeightPixels
        let thickness = max(1, Int((metrics.underlineThickness * scale).rounded()))
        for rect in LegacyComputingSupplementSpriteGeometry.rects(
            pattern: pattern,
            cellWidthPixels: metrics.cellWidthPixels,
            cellHeightPixels: metrics.cellHeightPixels,
            thicknessPixels: thickness
        ) {
            rects.append(CGRect(
                x: CGFloat(originX + rect.x) / scale,
                y: CGFloat(originY + rect.y) / scale,
                width: CGFloat(rect.width) / scale,
                height: CGFloat(rect.height) / scale
            ))
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
}
