// Pure cell-local physical-pixel rasterization for Ghostty's legacy-computing symbols.

/// The finite Unicode scalar vocabulary implemented by Ghostty's legacy-computing drawer.
public struct LegacyComputingPattern: Equatable, Sendable {
    public let scalar: UInt32
    public let topology: LegacyComputingTopology

    public init(scalar: UInt32) {
        self.scalar = scalar
        self.topology = LegacyComputingTopology.decode(scalar)
    }
}

/// Canonical structural class decoded before rasterization so scalar identity is testable.
public enum LegacyComputingTopology: Equatable, Hashable, Sendable {
    case sextant(mask: Int)
    case smoothMosaic(grid: String)
    case edgeTriangle(edge: Int, inverted: Bool)
    case verticalEighth(index: Int)
    case horizontalEighth(index: Int)
    case legacyBlock(policy: String)
    case diagonalFill(ascending: Bool)
    case pairedEdgeTriangles(horizontal: Bool)
    case shadedCorner(index: Int)
    case cornerDiagonals(mask: Int)
    case mixedCross
    case negativeDiagonal(index: Int)
    case fractionalLeft(thirds: Int)
    case cellDiagonals(segments: String)
    case legacyCircle(shape: String)

    // Compile-time-constant decode tables. Hoisted to `static let` so classifying a
    // scalar reuses one shared instance instead of rebuilding an array literal per call.
    private static let blockPolicies = [
        "left-eighth+lower-eighth", "left-eighth+upper-eighth",
        "right-eighth+upper-eighth", "right-eighth+lower-eighth",
        "upper-eighth+lower-eighth", "horizontal-eighths-1-3-5-8",
        "upper-quarter", "upper-three-eighths", "upper-five-eighths",
        "upper-three-quarters", "upper-seven-eighths", "right-quarter",
        "right-three-eighths", "right-five-eighths", "right-three-quarters",
        "right-seven-eighths", "medium-left-half", "medium-right-half",
        "medium-upper-half", "medium-lower-half", "medium-full",
        "medium-full+solid-upper", "medium-full+solid-lower", "empty",
        "medium-full+solid-right", "checker-even", "checker-odd",
        "horizontal-bands-second-fourth",
    ]
    private static let cornerDiagonalMasks = [1, 2, 4, 8, 5, 10, 12, 3, 9, 6, 14, 13, 11, 7, 15]
    private static let cellDiagonalSegments = [
        "MR-LL", "UR-ML", "UL-MR", "ML-LR",
        "UL-LC", "UC-LR", "UR-LC", "UC-LL",
        "UL-MC+MC-UR", "UR-MC+MC-LR", "LL-MC+MC-LR", "UL-MC+MC-LL",
        "UL-LC+LC-UR", "UR-ML+ML-LR", "LL-UC+UC-LR", "UL-MR+MR-LL",
    ]
    private static let legacyCircleShapes = [
        "outline-top", "outline-right", "outline-bottom", "outline-left",
        "upper-centered-half-block", "lower-centered-half-block",
        "middle-left-half-block", "middle-right-half-block",
        "filled-top", "filled-right", "filled-bottom", "filled-left",
        "filled-top-right", "filled-bottom-left", "filled-bottom-right", "filled-top-left",
    ]

    static func decode(_ value: UInt32) -> Self {
        switch value {
        case 0x1FB00...0x1FB3B:
            let index = Int(value - 0x1FB00)
            return .sextant(mask: index + index / 0x14 + 1)
        case 0x1FB3C...0x1FB67:
            return .smoothMosaic(grid: LegacyComputingSpriteGeometry.smoothMosaicGrids[Int(value - 0x1FB3C)])
        case 0x1FB68...0x1FB6F:
            return .edgeTriangle(edge: Int(value - 0x1FB68) % 4, inverted: value < 0x1FB6C)
        case 0x1FB70...0x1FB75:
            return .verticalEighth(index: Int(value - 0x1FB70) + 1)
        case 0x1FB76...0x1FB7B:
            return .horizontalEighth(index: Int(value - 0x1FB76) + 1)
        case 0x1FB7C...0x1FB97:
            return .legacyBlock(policy: blockPolicies[Int(value - 0x1FB7C)])
        case 0x1FB98...0x1FB99:
            return .diagonalFill(ascending: value == 0x1FB98)
        case 0x1FB9A...0x1FB9B:
            return .pairedEdgeTriangles(horizontal: value == 0x1FB9A)
        case 0x1FB9C...0x1FB9F:
            return .shadedCorner(index: Int(value - 0x1FB9C))
        case 0x1FBA0...0x1FBAE:
            return .cornerDiagonals(mask: cornerDiagonalMasks[Int(value - 0x1FBA0)])
        case 0x1FBAF:
            return .mixedCross
        case 0x1FBBD...0x1FBBF:
            return .negativeDiagonal(index: Int(value - 0x1FBBD))
        case 0x1FBCE...0x1FBCF:
            return .fractionalLeft(thirds: value == 0x1FBCE ? 2 : 1)
        case 0x1FBD0...0x1FBDF:
            return .cellDiagonals(segments: cellDiagonalSegments[Int(value - 0x1FBD0)])
        default:
            return .legacyCircle(shape: legacyCircleShapes[Int(value - 0x1FBE0)])
        }
    }
}

/// One run of equally shaded physical pixels.
public struct LegacyComputingPixelRun: Equatable, Sendable {
    public let rect: SpritePixelRect
    public let alpha: UInt8

    public init(rect: SpritePixelRect, alpha: UInt8 = 255) {
        self.rect = rect
        self.alpha = alpha
    }
}

/// Rasterizes the diverse legacy family through one clipped, deterministic pixel seam.
public enum LegacyComputingSpriteGeometry {
    fileprivate static let smoothMosaicGrids = [
        "......#..##.", "......#..###", "...#..#..##.", "...#..##.###",
        "#..#..##.##.", ".###########", "..##########", ".##.########",
        "..#.########", ".##.##.#####", ".....#######", "........#.##",
        "........####", ".....#..#.##", ".....#.#####", "..#..#.##.##",
        "##.#########", "#..#########", "##.##.######", "#..##.######",
        "##.##.##.###", "...#..######", "#########.##", "#########..#",
        "######.##.##", "######.##..#", "###.##.##.##", "##.#........",
        "####........", "##.#..#.....", "#####.#.....", "##.##.#..#..",
        "#######.....", "###########.", "##########..", "########.##.",
        "########.#..", "#####.##.##.", ".##..#......", "###..#......",
        ".##..#..#...", "###.##..#...", ".##.##..#..#", "######..#...",
    ]

    // Compile-time-constant run tables. Hoisted to `static let` so each per-cell draw
    // reuses one shared instance instead of rebuilding an array literal.
    private static let boxEdgePairs = [(0, 3), (0, 1), (2, 1), (2, 3), (1, 3)]
    private static let horizontalEighthBands = [0, 2, 4, 7]
    private static let partialEighthCounts = [2, 3, 5, 6, 7]
    private static let cornerDiagonalMasks = [1, 2, 4, 8, 5, 10, 12, 3, 9, 6, 14, 13, 11, 7, 15]

    public static func runs(
        pattern: LegacyComputingPattern,
        cellWidthPixels width: Int,
        cellHeightPixels height: Int,
        lightStrokePixels requestedLight: Int = 1
    ) -> [LegacyComputingPixelRun] {
        precondition(requestedLight > 0)
        guard width > 0, height > 0 else { return [] }
        let light = min(requestedLight, width, height)
        let heavy = min(max(light + 1, light * 2), width, height)
        let value = pattern.scalar
        var pixels = Array(repeating: UInt8(0), count: width * height)

        func set(_ x: Int, _ y: Int, _ alpha: UInt8 = 255) {
            guard (0..<width).contains(x), (0..<height).contains(y) else { return }
            pixels[y * width + x] = max(pixels[y * width + x], alpha)
        }
        func fill(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int, _ alpha: UInt8 = 255) {
            for y in max(0, y0)..<min(height, y1) {
                for x in max(0, x0)..<min(width, x1) { set(x, y, alpha) }
            }
        }
        func fraction(_ numerator: Int, _ denominator: Int, _ extent: Int) -> Int {
            (numerator * extent) / denominator
        }
        func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, thick: Int? = nil) {
            let radius = Double(max(1, thick ?? light)) / 2
            let dx = x1 - x0
            let dy = y1 - y0
            let lengthSquared = max(0.0001, dx * dx + dy * dy)
            for y in 0..<height {
                for x in 0..<width {
                    let px = Double(x) + 0.5
                    let py = Double(y) + 0.5
                    let t = max(0, min(1, ((px - x0) * dx + (py - y0) * dy) / lengthSquared))
                    let distanceX = px - (x0 + t * dx)
                    let distanceY = py - (y0 + t * dy)
                    if distanceX * distanceX + distanceY * distanceY <= radius * radius { set(x, y) }
                }
            }
        }
        func triangle(_ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double), invert: Bool = false, alpha: UInt8 = 255) {
            func edge(_ p: (Double, Double), _ q: (Double, Double), _ x: Double, _ y: Double) -> Double {
                (x - p.0) * (q.1 - p.1) - (y - p.1) * (q.0 - p.0)
            }
            for y in 0..<height {
                for x in 0..<width {
                    let px = Double(x) + 0.5, py = Double(y) + 0.5
                    let e0 = edge(a, b, px, py), e1 = edge(b, c, px, py), e2 = edge(c, a, px, py)
                    let inside = (e0 >= 0 && e1 >= 0 && e2 >= 0) || (e0 <= 0 && e1 <= 0 && e2 <= 0)
                    if inside != invert { set(x, y, alpha) }
                }
            }
        }
        func polygon(_ points: [(Double, Double)], alpha: UInt8 = 255) {
            guard points.count >= 3 else { return }
            for y in 0..<height {
                for x in 0..<width {
                    let px = Double(x) + 0.5, py = Double(y) + 0.5
                    var inside = false
                    var previous = points.count - 1
                    for current in points.indices {
                        let a = points[current], b = points[previous]
                        if (a.1 > py) != (b.1 > py),
                           px < (b.0 - a.0) * (py - a.1) / (b.1 - a.1) + a.0
                        {
                            inside.toggle()
                        }
                        previous = current
                    }
                    if inside { set(x, y, alpha) }
                }
            }
        }
        func checker(_ parity: Int) {
            let rows = max(1, Int((4 * Double(height) / Double(width)).rounded()))
            for y in 0..<rows where y < rows {
                for x in 0..<4 where (x + y) % 2 == parity {
                    fill(x * width / 4, (x + 1) * width / 4, y * height / rows, (y + 1) * height / rows)
                }
            }
        }
        func circle(_ cx: Double, _ cy: Double, filled: Bool) {
            let radius = Double(min(width, height)) / 2
            let stroke = Double(light)
            for y in 0..<height {
                for x in 0..<width {
                    let dx = Double(x) + 0.5 - cx
                    let dy = Double(y) + 0.5 - cy
                    let distanceSquared = dx * dx + dy * dy
                    let outer = radius
                    let inner = max(0, radius - stroke)
                    if filled ? distanceSquared <= outer * outer
                        : distanceSquared <= outer * outer && distanceSquared >= inner * inner
                    {
                        set(x, y)
                    }
                }
            }
        }

        switch value {
        case 0x1FB00...0x1FB3B:
            let index = Int(value - 0x1FB00)
            let mask = index + index / 0x14 + 1
            let xs = [0, width / 2, width]
            let ys = [0, height / 3, 2 * height / 3, height]
            for bit in 0..<6 where mask & (1 << bit) != 0 {
                fill(xs[bit % 2], xs[bit % 2 + 1], ys[bit / 2], ys[bit / 2 + 1])
            }
        case 0x1FB3C...0x1FB67:
            let grid = Array(smoothMosaicGrids[Int(value - 0x1FB3C)])
            func marked(_ row: Int, _ column: Int) -> Bool { grid[row * 3 + column] == "#" }
            let coordinates: [((Double, Double), Bool)] = [
                ((0, 0), marked(0, 0)),
                ((0, Double(height) / 3), marked(1, 0) && (!marked(0, 0) || !marked(2, 0))),
                ((0, 2 * Double(height) / 3), marked(2, 0) && (!marked(1, 0) || !marked(3, 0))),
                ((0, Double(height)), marked(3, 0)),
                ((Double(width) / 2, Double(height)), marked(3, 1) && (!marked(3, 0) || !marked(3, 2))),
                ((Double(width), Double(height)), marked(3, 2)),
                ((Double(width), 2 * Double(height) / 3), marked(2, 2) && (!marked(3, 2) || !marked(1, 2))),
                ((Double(width), Double(height) / 3), marked(1, 2) && (!marked(2, 2) || !marked(0, 2))),
                ((Double(width), 0), marked(0, 2)),
                ((Double(width) / 2, 0), marked(0, 1) && (!marked(0, 2) || !marked(0, 0))),
            ]
            polygon(coordinates.compactMap { $0.1 ? $0.0 : nil })
        case 0x1FB68...0x1FB6F:
            let edge = Int(value - 0x1FB68) % 4
            let invert = value < 0x1FB6C
            let center = (Double(width) / 2, Double(height) / 2)
            let corners: [((Double, Double), (Double, Double))] = [
                ((0, 0), (0, Double(height))), ((0, 0), (Double(width), 0)),
                ((Double(width), 0), (Double(width), Double(height))),
                ((0, Double(height)), (Double(width), Double(height))),
            ]
            triangle(center, corners[edge].0, corners[edge].1, invert: invert)
        case 0x1FB70...0x1FB75:
            let n = Int(value - 0x1FB70) + 1
            fill(n * width / 8, (n + 1) * width / 8, 0, height)
        case 0x1FB76...0x1FB7B:
            let n = Int(value - 0x1FB76) + 1
            fill(0, width, n * height / 8, (n + 1) * height / 8)
        case 0x1FB7C...0x1FB80:
            let edgePair = Self.boxEdgePairs[Int(value - 0x1FB7C)]
            for edge in [edgePair.0, edgePair.1] {
                if edge == 0 { fill(0, max(1, width / 8), 0, height) }
                if edge == 1 { fill(0, width, 0, max(1, height / 8)) }
                if edge == 2 { fill(width - max(1, width / 8), width, 0, height) }
                if edge == 3 { fill(0, width, height - max(1, height / 8), height) }
            }
        case 0x1FB81:
            for n in Self.horizontalEighthBands { fill(0, width, n * height / 8, (n + 1) * height / 8) }
        case 0x1FB82...0x1FB86:
            let eighths = Self.partialEighthCounts[Int(value - 0x1FB82)]
            fill(0, width, 0, eighths * height / 8)
        case 0x1FB87...0x1FB8B:
            let eighths = Self.partialEighthCounts[Int(value - 0x1FB87)]
            fill(width - eighths * width / 8, width, 0, height)
        case 0x1FB8C...0x1FB8F:
            let alpha: UInt8 = 128
            if value == 0x1FB8C { fill(0, width / 2, 0, height, alpha) }
            if value == 0x1FB8D { fill(width / 2, width, 0, height, alpha) }
            if value == 0x1FB8E { fill(0, width, 0, height / 2, alpha) }
            if value == 0x1FB8F { fill(0, width, height / 2, height, alpha) }
        case 0x1FB90...0x1FB94:
            if value == 0x1FB93 { break }
            fill(0, width, 0, height, 128)
            if value == 0x1FB91 { fill(0, width, 0, height / 2) }
            if value == 0x1FB92 { fill(0, width, height / 2, height) }
            if value == 0x1FB94 { fill(width / 2, width, 0, height) }
        case 0x1FB95...0x1FB96:
            checker(Int(value - 0x1FB95))
        case 0x1FB97:
            fill(0, width, height / 4, height / 2)
            fill(0, width, 3 * height / 4, height)
        case 0x1FB98...0x1FB99:
            let ascending = value == 0x1FB98
            let count = max(1, width / (2 * light))
            for i in -count...count {
                let offset = Double(i * max(2 * light, width / count))
                if ascending { line(offset, 0, Double(width) + offset, Double(height)) }
                else { line(Double(width) + offset, 0, offset, Double(height)) }
            }
        case 0x1FB9A...0x1FB9B:
            let center = (Double(width) / 2, Double(height) / 2)
            if value == 0x1FB9A {
                triangle(center, (0, 0), (Double(width), 0))
                triangle(center, (0, Double(height)), (Double(width), Double(height)))
            } else {
                triangle(center, (0, 0), (0, Double(height)))
                triangle(center, (Double(width), 0), (Double(width), Double(height)))
            }
        case 0x1FB9C...0x1FB9F:
            let w = Double(width), h = Double(height)
            let cornerTriangles: [[(Double, Double)]] = [
                [(0.0, 0.0), (w / 2, 0), (0, h / 2)],
                [(w, 0.0), (w, h / 2), (w / 2, 0)],
                [(w, h), (w / 2, h), (w, h / 2)],
                [(0.0, h), (0, h / 2), (w / 2, h)],
            ]
            let points = cornerTriangles[Int(value - 0x1FB9C)]
            triangle(points[0], points[1], points[2], alpha: 128)
        case 0x1FBA0...0x1FBAE:
            let mask = Self.cornerDiagonalMasks[Int(value - 0x1FBA0)]
            let cx = Double((width + 1) / 2), cy = Double((height + 1) / 2)
            if mask & 1 != 0 { line(cx, 0, 0, cy) }
            if mask & 2 != 0 { line(cx, 0, Double(width), cy) }
            if mask & 4 != 0 { line(cx, Double(height), 0, cy) }
            if mask & 8 != 0 { line(cx, Double(height), Double(width), cy) }
        case 0x1FBAF:
            let centerX = width / 2
            let centerY = height / 2
            fill(centerX - heavy / 2, centerX + (heavy + 1) / 2, 0, height)
            fill(0, width, centerY - light / 2, centerY + (light + 1) / 2)
        case 0x1FBBD...0x1FBBF:
            if value == 0x1FBBD {
                var cut = Array(repeating: false, count: width * height)
                line(0, 0, Double(width), Double(height))
                line(Double(width), 0, 0, Double(height))
                for i in pixels.indices { cut[i] = pixels[i] != 0 }
                pixels = Array(repeating: 255, count: width * height)
                for i in pixels.indices where cut[i] { pixels[i] = 0 }
            } else {
                fill(0, width, 0, height)
                let count = value == 0x1FBBE ? 8 : 15
                let masks = count
                let cx = Double((width + 1) / 2), cy = Double((height + 1) / 2)
                var cut = Array(repeating: false, count: width * height)
                let saved = pixels
                pixels = Array(repeating: 0, count: width * height)
                if masks & 1 != 0 { line(cx, 0, 0, cy) }
                if masks & 2 != 0 { line(cx, 0, Double(width), cy) }
                if masks & 4 != 0 { line(cx, Double(height), 0, cy) }
                if masks & 8 != 0 { line(cx, Double(height), Double(width), cy) }
                for i in pixels.indices { cut[i] = pixels[i] != 0 }
                pixels = saved
                for i in pixels.indices where cut[i] { pixels[i] = 0 }
            }
        case 0x1FBCE:
            fill(0, fraction(2, 3, width), 0, height)
        case 0x1FBCF:
            fill(0, fraction(1, 3, width), 0, height)
        case 0x1FBD0...0x1FBDF:
            let w = Double(width), h = Double(height)
            let ul = (0.0, 0.0), uc = (w / 2, 0.0), ur = (w, 0.0)
            let ml = (0.0, h / 2), mc = (w / 2, h / 2), mr = (w, h / 2)
            let ll = (0.0, h), lc = (w / 2, h), lr = (w, h)
            let segments: [[((Double, Double), (Double, Double))]] = [
                [(mr, ll)], [(ur, ml)], [(ul, mr)], [(ml, lr)],
                [(ul, lc)], [(uc, lr)], [(ur, lc)], [(uc, ll)],
                [(ul, mc), (mc, ur)], [(ur, mc), (mc, lr)],
                [(ll, mc), (mc, lr)], [(ul, mc), (mc, ll)],
                [(ul, lc), (lc, ur)], [(ur, ml), (ml, lr)],
                [(ll, uc), (uc, lr)], [(ul, mr), (mr, ll)],
            ]
            for segment in segments[Int(value - 0x1FBD0)] {
                line(segment.0.0, segment.0.1, segment.1.0, segment.1.1)
            }
        case 0x1FBE0...0x1FBE3, 0x1FBE8...0x1FBEF:
            let positions: [(Double, Double)] = [
                (Double(width) / 2, 0), (Double(width), Double(height) / 2),
                (Double(width) / 2, Double(height)), (0, Double(height) / 2),
                (Double(width), 0), (0, Double(height)), (Double(width), Double(height)), (0, 0),
            ]
            let index = value < 0x1FBE8 ? Int(value - 0x1FBE0) : Int(value - 0x1FBE8)
            circle(positions[index].0, positions[index].1, filled: value >= 0x1FBE8)
        case 0x1FBE4...0x1FBE7:
            if value == 0x1FBE4 { fill(width / 4, 3 * width / 4, 0, height / 2) }
            if value == 0x1FBE5 { fill(width / 4, 3 * width / 4, height / 2, height) }
            if value == 0x1FBE6 { fill(0, width / 2, height / 4, 3 * height / 4) }
            if value == 0x1FBE7 { fill(width / 2, width, height / 4, 3 * height / 4) }
        default:
            break
        }

        var runs: [LegacyComputingPixelRun] = []
        for y in 0..<height {
            var x = 0
            while x < width {
                let alpha = pixels[y * width + x]
                guard alpha != 0 else { x += 1; continue }
                let start = x
                while x < width, pixels[y * width + x] == alpha { x += 1 }
                runs.append(LegacyComputingPixelRun(
                    rect: SpritePixelRect(x: start, y: y, width: x - start, height: 1),
                    alpha: alpha
                ))
            }
        }
        return runs
    }
}
