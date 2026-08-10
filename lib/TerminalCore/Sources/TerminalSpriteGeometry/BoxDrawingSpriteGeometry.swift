// Pure cell-local physical-pixel geometry for the complete Unicode Box Drawing family.

/// Stroke weights used independently on each arm of a Box Drawing junction.
public enum BoxDrawingWeight: UInt8, Equatable, Sendable {
    case none
    case light
    case heavy
    case double
}

/// Cardinal arms in top, right, bottom, left order.
public struct BoxDrawingLines: Equatable, Sendable {
    public let up: BoxDrawingWeight
    public let right: BoxDrawingWeight
    public let down: BoxDrawingWeight
    public let left: BoxDrawingWeight

    public init(
        up: BoxDrawingWeight = .none,
        right: BoxDrawingWeight = .none,
        down: BoxDrawingWeight = .none,
        left: BoxDrawingWeight = .none
    ) {
        self.up = up
        self.right = right
        self.down = down
        self.left = left
    }
}

/// Selects the edge-to-edge direction of a dashed line.
public enum BoxDrawingAxis: Equatable, Sendable { case horizontal, vertical }

/// Identifies rounded corners by the two arms they connect.
public enum BoxDrawingCorner: Equatable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }

/// Selects one or both corner-to-corner diagonals.
public enum BoxDrawingDiagonal: Equatable, Sendable { case rising, falling, cross }

/// Finite structural vocabulary to which all 128 codepoints decode.
public enum BoxDrawingPattern: Equatable, Sendable {
    case lines(BoxDrawingLines)
    case dashed(axis: BoxDrawingAxis, weight: BoxDrawingWeight, count: Int)
    case arc(BoxDrawingCorner)
    case diagonal(BoxDrawingDiagonal)
}

/// One antialiased physical-pixel stroke; endpoints may deliberately touch cell edges.
public struct BoxDrawingPixelStroke: Equatable, Sendable {
    public let points: [SpritePixelPoint]
    public let width: Int
    public let isCurved: Bool

    public init(points: [SpritePixelPoint], width: Int, isCurved: Bool = false) {
        self.points = points
        self.width = width
        self.isCurved = isCurved
    }
}

/// Separates hard-edged fills from the few shapes that require stroked paths.
public struct BoxDrawingPixelGeometry: Equatable, Sendable {
    public let rects: [SpritePixelRect]
    public let strokes: [BoxDrawingPixelStroke]

    public init(rects: [SpritePixelRect], strokes: [BoxDrawingPixelStroke]) {
        self.rects = rects
        self.strokes = strokes
    }
}

/// Resolves stroke scarcity and junction joins in integer physical pixels.
public enum BoxDrawingSpriteGeometry {
    public static func geometry(
        pattern: BoxDrawingPattern,
        cellWidthPixels width: Int,
        cellHeightPixels height: Int,
        lightStrokePixels requestedLight: Int
    ) -> BoxDrawingPixelGeometry {
        precondition(width >= 0 && height >= 0 && requestedLight > 0)
        guard width > 0 && height > 0 else {
            return BoxDrawingPixelGeometry(rects: [], strokes: [])
        }
        let light = min(requestedLight, width, height)
        let heavy = min(max(light + 1, light * 2), width, height)

        switch pattern {
        case let .lines(lines):
            return BoxDrawingPixelGeometry(
                rects: lineRects(lines, width: width, height: height, light: light, heavy: heavy),
                strokes: []
            )
        case let .dashed(axis, weight, count):
            return BoxDrawingPixelGeometry(
                rects: dashedRects(
                    axis: axis, thickness: weight == .heavy ? heavy : light,
                    count: count, width: width, height: height
                ),
                strokes: []
            )
        case let .diagonal(diagonal):
            let rising = BoxDrawingPixelStroke(
                points: [SpritePixelPoint(x: 0, y: height), SpritePixelPoint(x: width, y: 0)],
                width: light
            )
            let falling = BoxDrawingPixelStroke(
                points: [SpritePixelPoint(x: 0, y: 0), SpritePixelPoint(x: width, y: height)],
                width: light
            )
            let strokes: [BoxDrawingPixelStroke] = switch diagonal {
                case .rising: [rising]
                case .falling: [falling]
                case .cross: [rising, falling]
            }
            return BoxDrawingPixelGeometry(rects: [], strokes: strokes)
        case let .arc(corner):
            let cx = (width - light) / 2 + light / 2
            let cy = (height - light) / 2 + light / 2
            let points: [SpritePixelPoint] = switch corner {
            case .topLeft: [.init(x: cx, y: height), .init(x: cx, y: cy), .init(x: width, y: cy)]
            case .topRight: [.init(x: cx, y: height), .init(x: cx, y: cy), .init(x: 0, y: cy)]
            case .bottomLeft: [.init(x: cx, y: 0), .init(x: cx, y: cy), .init(x: width, y: cy)]
            case .bottomRight: [.init(x: cx, y: 0), .init(x: cx, y: cy), .init(x: 0, y: cy)]
            }
            return BoxDrawingPixelGeometry(
                rects: [], strokes: [.init(points: points, width: light, isCurved: true)]
            )
        }
    }

    private static func lineRects(
        _ lines: BoxDrawingLines, width: Int, height: Int, light: Int, heavy: Int
    ) -> [SpritePixelRect] {
        let horizontalDoubleFits = height >= light * 3
        let verticalDoubleFits = width >= light * 3
        func resolved(_ weight: BoxDrawingWeight, horizontal: Bool) -> BoxDrawingWeight {
            if weight == .double && (horizontal ? horizontalDoubleFits : verticalDoubleFits) == false {
                return .heavy
            }
            return weight
        }
        let up = resolved(lines.up, horizontal: false)
        let right = resolved(lines.right, horizontal: true)
        let down = resolved(lines.down, horizontal: false)
        let left = resolved(lines.left, horizontal: true)

        let hLightTop = (height - light) / 2
        let hLightBottom = hLightTop + light
        let hHeavyTop = (height - heavy) / 2
        let hHeavyBottom = hHeavyTop + heavy
        let hDoubleTop = max(0, hLightTop - light)
        let hDoubleBottom = min(height, hLightBottom + light)
        let vLightLeft = (width - light) / 2
        let vLightRight = vLightLeft + light
        let vHeavyLeft = (width - heavy) / 2
        let vHeavyRight = vHeavyLeft + heavy
        let vDoubleLeft = max(0, vLightLeft - light)
        let vDoubleRight = min(width, vLightRight + light)

        let upBottom: Int
        if left == .heavy || right == .heavy {
            upBottom = hHeavyBottom
        } else if left != right || down == up {
            upBottom = left == .double || right == .double ? hDoubleBottom : hLightBottom
        } else if left == .none && right == .none {
            upBottom = hLightBottom
        } else {
            upBottom = hLightTop
        }

        let downTop: Int
        if left == .heavy || right == .heavy {
            downTop = hHeavyTop
        } else if left != right || up == down {
            downTop = left == .double || right == .double ? hDoubleTop : hLightTop
        } else if left == .none && right == .none {
            downTop = hLightTop
        } else {
            downTop = hLightBottom
        }

        let leftRight: Int
        if up == .heavy || down == .heavy {
            leftRight = vHeavyRight
        } else if up != down || left == right {
            leftRight = up == .double || down == .double ? vDoubleRight : vLightRight
        } else if up == .none && down == .none {
            leftRight = vLightRight
        } else {
            leftRight = vLightLeft
        }

        let rightLeft: Int
        if up == .heavy || down == .heavy {
            rightLeft = vHeavyLeft
        } else if up != down || right == left {
            rightLeft = up == .double || down == .double ? vDoubleLeft : vLightLeft
        } else if up == .none && down == .none {
            rightLeft = vLightLeft
        } else {
            rightLeft = vLightRight
        }

        var result: [SpritePixelRect] = []
        func append(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
            let minX = min(max(0, x0), width)
            let minY = min(max(0, y0), height)
            let maxX = min(max(0, x1), width)
            let maxY = min(max(0, y1), height)
            if minX < maxX && minY < maxY {
                result.append(.init(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
            }
        }

        switch up {
        case .none: break
        case .light: append(vLightLeft, 0, vLightRight, upBottom)
        case .heavy: append(vHeavyLeft, 0, vHeavyRight, upBottom)
        case .double:
            let leftBottom = left == .double ? hLightTop : upBottom
            let rightBottom = right == .double ? hLightTop : upBottom
            append(vDoubleLeft, 0, vLightLeft, leftBottom)
            append(vLightRight, 0, vDoubleRight, rightBottom)
        }
        switch right {
        case .none: break
        case .light: append(rightLeft, hLightTop, width, hLightBottom)
        case .heavy: append(rightLeft, hHeavyTop, width, hHeavyBottom)
        case .double:
            let topLeft = up == .double ? vLightRight : rightLeft
            let bottomLeft = down == .double ? vLightRight : rightLeft
            append(topLeft, hDoubleTop, width, hLightTop)
            append(bottomLeft, hLightBottom, width, hDoubleBottom)
        }
        switch down {
        case .none: break
        case .light: append(vLightLeft, downTop, vLightRight, height)
        case .heavy: append(vHeavyLeft, downTop, vHeavyRight, height)
        case .double:
            let leftTop = left == .double ? hLightBottom : downTop
            let rightTop = right == .double ? hLightBottom : downTop
            append(vDoubleLeft, leftTop, vLightLeft, height)
            append(vLightRight, rightTop, vDoubleRight, height)
        }
        switch left {
        case .none: break
        case .light: append(0, hLightTop, leftRight, hLightBottom)
        case .heavy: append(0, hHeavyTop, leftRight, hHeavyBottom)
        case .double:
            let topRight = up == .double ? vLightLeft : leftRight
            let bottomRight = down == .double ? vLightLeft : leftRight
            append(0, hDoubleTop, topRight, hLightTop)
            append(0, hLightBottom, bottomRight, hDoubleBottom)
        }
        return result
    }

    private static func dashedRects(
        axis: BoxDrawingAxis, thickness: Int, count: Int, width: Int, height: Int
    ) -> [SpritePixelRect] {
        let extent = axis == .horizontal ? width : height
        guard extent >= count * 2 else {
            let lines = axis == .horizontal
                ? BoxDrawingLines(right: thickness > 1 ? .heavy : .light, left: thickness > 1 ? .heavy : .light)
                : BoxDrawingLines(up: thickness > 1 ? .heavy : .light, down: thickness > 1 ? .heavy : .light)
            return lineRects(lines, width: width, height: height, light: 1, heavy: thickness)
        }
        let gap = max(1, min(thickness, extent / (count * 2)))
        let ink = extent - count * gap
        let base = ink / count
        var remainder = ink % count
        var cursor = gap / 2
        var rects: [SpritePixelRect] = []
        for _ in 0..<count {
            let length = base + (remainder > 0 ? 1 : 0)
            remainder = max(0, remainder - 1)
            rects.append(axis == .horizontal
                ? .init(x: cursor, y: (height - thickness) / 2, width: length, height: thickness)
                : .init(x: (width - thickness) / 2, y: cursor, width: thickness, height: length))
            cursor += length + gap
        }
        return rects
    }
}
