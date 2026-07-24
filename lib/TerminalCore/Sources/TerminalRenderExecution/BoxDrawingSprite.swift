// Exact Unicode decoding and render-boundary conversion for Box Drawing sprites.
import CoreGraphics
import TerminalSpriteGeometry

/// Maps every U+2500...U+257F scalar to Box Drawing-specific physical geometry.
enum BoxDrawingSprite {
    /// Coarse routing span for the classifier switch; exact membership stays in `pattern(for:)`.
    static let coarseRange: ClosedRange<UInt32> = 0x2500...0x257F

    static func pattern(for scalars: [Unicode.Scalar]) -> BoxDrawingPattern? {
        guard scalars.count == 1, let value = scalars.first?.value,
              (0x2500...0x257F).contains(value)
        else { return nil }
        if let lines = lineMappings[Int(value - 0x2500)] { return .lines(lines) }
        return switch value {
        case 0x2504: .dashed(axis: .horizontal, weight: .light, count: 3)
        case 0x2505: .dashed(axis: .horizontal, weight: .heavy, count: 3)
        case 0x2506: .dashed(axis: .vertical, weight: .light, count: 3)
        case 0x2507: .dashed(axis: .vertical, weight: .heavy, count: 3)
        case 0x2508: .dashed(axis: .horizontal, weight: .light, count: 4)
        case 0x2509: .dashed(axis: .horizontal, weight: .heavy, count: 4)
        case 0x250A: .dashed(axis: .vertical, weight: .light, count: 4)
        case 0x250B: .dashed(axis: .vertical, weight: .heavy, count: 4)
        case 0x254C: .dashed(axis: .horizontal, weight: .light, count: 2)
        case 0x254D: .dashed(axis: .horizontal, weight: .heavy, count: 2)
        case 0x254E: .dashed(axis: .vertical, weight: .light, count: 2)
        case 0x254F: .dashed(axis: .vertical, weight: .heavy, count: 2)
        case 0x256D: .arc(.topLeft)
        case 0x256E: .arc(.topRight)
        case 0x256F: .arc(.bottomRight)
        case 0x2570: .arc(.bottomLeft)
        case 0x2571: .diagonal(.rising)
        case 0x2572: .diagonal(.falling)
        case 0x2573: .diagonal(.cross)
        default: preconditionFailure("complete Box Drawing mapping for \(String(value, radix: 16))")
        }
    }

    static func append(
        pattern: BoxDrawingPattern,
        row: Int,
        column: Int,
        metrics: TerminalRenderMetrics,
        rects: inout [CGRect],
        strokes: inout [BoxDrawingRenderStroke]
    ) {
        let light = max(1, Int((metrics.underlineThickness * metrics.displayScale).rounded()))
        let geometry = BoxDrawingSpriteGeometry.geometry(
            pattern: pattern,
            cellWidthPixels: metrics.cellWidthPixels,
            cellHeightPixels: metrics.cellHeightPixels,
            lightStrokePixels: light
        )
        let origin = CGPoint(
            x: CGFloat(column * metrics.cellWidthPixels) / metrics.displayScale,
            y: CGFloat(row * metrics.cellHeightPixels) / metrics.displayScale
        )
        for rect in geometry.rects {
            rects.append(CGRect(
                x: origin.x + CGFloat(rect.x) / metrics.displayScale,
                y: origin.y + CGFloat(rect.y) / metrics.displayScale,
                width: CGFloat(rect.width) / metrics.displayScale,
                height: CGFloat(rect.height) / metrics.displayScale
            ))
        }
        strokes += geometry.strokes.map {
            BoxDrawingRenderStroke(geometry: $0, cellOrigin: origin)
        }
    }

    private static let n = BoxDrawingWeight.none
    private static let l = BoxDrawingWeight.light
    private static let h = BoxDrawingWeight.heavy
    private static let d = BoxDrawingWeight.double
    private static func e(
        _ up: BoxDrawingWeight = n, _ right: BoxDrawingWeight = n,
        _ down: BoxDrawingWeight = n, _ left: BoxDrawingWeight = n
    ) -> BoxDrawingLines { .init(up: up, right: right, down: down, left: left) }

    // Indexed by codepoint offset. Nil slots are dashed, arc, or diagonal forms.
    private static let lineMappings: [BoxDrawingLines?] = [
        e(n,l,n,l), e(n,h,n,h), e(l,n,l,n), e(h,n,h,n), nil,nil,nil,nil,nil,nil,nil,nil,
        e(n,l,l,n), e(n,h,l,n), e(n,l,h,n), e(n,h,h,n),
        e(n,n,l,l), e(n,n,l,h), e(n,n,h,l), e(n,n,h,h),
        e(l,l,n,n), e(l,h,n,n), e(h,l,n,n), e(h,h,n,n),
        e(l,n,n,l), e(l,n,n,h), e(h,n,n,l), e(h,n,n,h),
        e(l,l,l,n), e(l,h,l,n), e(h,l,l,n), e(l,l,h,n),
        e(h,l,h,n), e(h,h,l,n), e(l,h,h,n), e(h,h,h,n),
        e(l,n,l,l), e(l,n,l,h), e(h,n,l,l), e(l,n,h,l),
        e(h,n,h,l), e(h,n,l,h), e(l,n,h,h), e(h,n,h,h),
        e(n,l,l,l), e(n,l,l,h), e(n,h,l,l), e(n,h,l,h),
        e(n,l,h,l), e(n,l,h,h), e(n,h,h,l), e(n,h,h,h),
        e(l,l,n,l), e(l,l,n,h), e(l,h,n,l), e(l,h,n,h),
        e(h,l,n,l), e(h,l,n,h), e(h,h,n,l), e(h,h,n,h),
        e(l,l,l,l), e(l,l,l,h), e(l,h,l,l), e(l,h,l,h),
        e(h,l,l,l), e(l,l,h,l), e(h,l,h,l), e(h,l,l,h),
        e(h,h,l,l), e(l,l,h,h), e(l,h,h,l), e(h,h,l,h),
        e(l,h,h,h), e(h,l,h,h), e(h,h,h,l), e(h,h,h,h), nil,nil,nil,nil,
        e(n,d,n,d), e(d,n,d,n), e(n,d,l,n), e(n,l,d,n),
        e(n,d,d,n), e(n,n,l,d), e(n,n,d,l), e(n,n,d,d),
        e(l,d,n,n), e(d,l,n,n), e(d,d,n,n), e(l,n,n,d),
        e(d,n,n,l), e(d,n,n,d), e(l,d,l,n), e(d,l,d,n),
        e(d,d,d,n), e(l,n,l,d), e(d,n,d,l), e(d,n,d,d),
        e(n,d,l,d), e(n,l,d,l), e(n,d,d,d), e(l,d,n,d),
        e(d,l,n,l), e(d,d,n,d), e(l,d,l,d), e(d,l,d,l),
        e(d,d,d,d), nil,nil,nil,nil,nil,nil,nil,
        e(n,n,n,l), e(l,n,n,n), e(n,l,n,n), e(n,n,l,n),
        e(n,n,n,h), e(h,n,n,n), e(n,h,n,n), e(n,n,h,n),
        e(n,h,n,l), e(l,n,h,n), e(n,l,n,h), e(h,n,l,n),
    ]
}

struct BoxDrawingRenderStroke {
    let geometry: BoxDrawingPixelStroke
    let cellOrigin: CGPoint
}
