// Exact Unicode decoding and render-boundary conversion for Box Drawing sprites.
import CoreGraphics
import TerminalSpriteGeometry

/// Maps every U+2500...U+257F scalar to Box Drawing-specific physical geometry.
enum BoxDrawingSprite {
    /// Coarse routing span for the classifier switch; exact membership stays in `pattern(for:)`.
    static let coarseRange: ClosedRange<UInt32> = 0x2500...0x257F

    static func pattern(for scalar: Unicode.Scalar) -> BoxDrawingPattern? {
        let value = scalar.value
        guard coarseRange.contains(value) else { return nil }
        return patterns[Int(value - coarseRange.lowerBound)]
    }

    static func append(
        pattern: BoxDrawingPattern,
        row: Int,
        column: Int,
        metrics: TerminalRenderMetrics,
        rects: inout [CGRect],
        strokes: inout [BoxDrawingRenderStroke]
    ) {
        let light = metrics.lightStrokePixels
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
    ) -> BoxDrawingPattern { .lines(.init(up: up, right: right, down: down, left: left)) }
    private static func dh(_ weight: BoxDrawingWeight, _ count: Int) -> BoxDrawingPattern {
        .dashed(axis: .horizontal, weight: weight, count: count)
    }
    private static func dv(_ weight: BoxDrawingWeight, _ count: Int) -> BoxDrawingPattern {
        .dashed(axis: .vertical, weight: weight, count: count)
    }

    // One entry per scalar of `coarseRange`, indexed by codepoint offset. The size is part of
    // the type, so a lost or added slot is a compile error rather than a shifted glyph.
    private static let patterns: InlineArray<128, BoxDrawingPattern> = [
        e(n,l,n,l), e(n,h,n,h), e(l,n,l,n), e(h,n,h,n),
        dh(l,3), dh(h,3), dv(l,3), dv(h,3),
        dh(l,4), dh(h,4), dv(l,4), dv(h,4),
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
        e(l,h,h,h), e(h,l,h,h), e(h,h,h,l), e(h,h,h,h),
        dh(l,2), dh(h,2), dv(l,2), dv(h,2),
        e(n,d,n,d), e(d,n,d,n), e(n,d,l,n), e(n,l,d,n),
        e(n,d,d,n), e(n,n,l,d), e(n,n,d,l), e(n,n,d,d),
        e(l,d,n,n), e(d,l,n,n), e(d,d,n,n), e(l,n,n,d),
        e(d,n,n,l), e(d,n,n,d), e(l,d,l,n), e(d,l,d,n),
        e(d,d,d,n), e(l,n,l,d), e(d,n,d,l), e(d,n,d,d),
        e(n,d,l,d), e(n,l,d,l), e(n,d,d,d), e(l,d,n,d),
        e(d,l,n,l), e(d,d,n,d), e(l,d,l,d), e(d,l,d,l),
        e(d,d,d,d), .arc(.topLeft), .arc(.topRight), .arc(.bottomRight),
        .arc(.bottomLeft), .diagonal(.rising), .diagonal(.falling), .diagonal(.cross),
        e(n,n,n,l), e(l,n,n,n), e(n,l,n,n), e(n,n,l,n),
        e(n,n,n,h), e(h,n,n,n), e(n,h,n,n), e(n,n,h,n),
        e(n,h,n,l), e(l,n,h,n), e(n,l,n,h), e(h,n,l,n),
    ]
}

struct BoxDrawingRenderStroke {
    let geometry: BoxDrawingPixelStroke
    let cellOrigin: CGPoint
}
