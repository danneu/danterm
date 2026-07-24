// Exact Unicode classification and render-boundary conversion for Powerline sprites.
import CoreGraphics
import TerminalSpriteGeometry

/// Holds one translated Powerline path while its geometry remains cell-local.
struct PowerlineRenderPath {
    let geometry: PowerlinePixelPath
    let cellOrigin: CGPoint
}

/// Maps Ghostty's finite Powerline set and translates its pure physical geometry.
enum PowerlineSprite {
    /// Coarse routing span for the classifier switch. Wider than the sparse membership decoded
    /// in `pattern(for:)`; interior gaps return nil there and fall through to the font path.
    static let coarseRange: ClosedRange<UInt32> = 0xE0B0...0xE0D4

    static func pattern(for scalars: [Unicode.Scalar]) -> PowerlinePattern? {
        guard scalars.count == 1, let value = scalars.first?.value else { return nil }
        return switch value {
        case 0xE0B0: .rightHard
        case 0xE0B1: .rightThin
        case 0xE0B2: .leftHard
        case 0xE0B3: .leftThin
        case 0xE0B4: .rightHardRounded
        case 0xE0B5: .rightThinRounded
        case 0xE0B6: .leftHardRounded
        case 0xE0B7: .leftThinRounded
        case 0xE0B8: .upperRightHardDiagonal
        case 0xE0B9: .upperRightThinDiagonal
        case 0xE0BA: .lowerRightHardDiagonal
        case 0xE0BB: .lowerRightThinDiagonal
        case 0xE0BC: .lowerLeftHardDiagonal
        case 0xE0BD: .lowerLeftThinDiagonal
        case 0xE0BE: .upperLeftHardDiagonal
        case 0xE0BF: .upperLeftThinDiagonal
        case 0xE0D2: .leftCap
        case 0xE0D4: .rightCap
        default: nil
        }
    }

    static func paths(
        pattern: PowerlinePattern,
        row: Int,
        column: Int,
        metrics: TerminalRenderMetrics
    ) -> [PowerlineRenderPath] {
        let light = max(1, Int((metrics.underlineThickness * metrics.displayScale).rounded()))
        let geometry = PowerlineSpriteGeometry.geometry(
            pattern: pattern,
            cellWidthPixels: metrics.cellWidthPixels,
            cellHeightPixels: metrics.cellHeightPixels,
            lightStrokePixels: light
        )
        let origin = CGPoint(
            x: CGFloat(column * metrics.cellWidthPixels) / metrics.displayScale,
            y: CGFloat(row * metrics.cellHeightPixels) / metrics.displayScale
        )
        return geometry.paths.map { PowerlineRenderPath(geometry: $0, cellOrigin: origin) }
    }
}
