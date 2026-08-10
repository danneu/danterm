// Pure physical-pixel geometry proofs for Unicode Box Drawing sprites.
import Testing

@testable import TerminalSpriteGeometry

struct BoxDrawingSpriteGeometryTests {
    @Test("Light, heavy, mixed, and double lines share exact center axes")
    func representativeGoldenLines() {
        let light = geometry(.lines(.init(right: .light, left: .light)), 9, 17)
        #expect(light.rects == [
            .init(x: 4, y: 8, width: 5, height: 1),
            .init(x: 0, y: 8, width: 5, height: 1),
        ])
        let mixed = geometry(.lines(.init(right: .heavy, left: .light)), 9, 17)
        #expect(mixed.rects[0].y == 7)
        #expect(mixed.rects[0].height == 2)
        #expect(mixed.rects[1].y == 8)
        let double = geometry(.lines(.init(up: .double, down: .double)), 9, 17)
        #expect(Set(double.rects.map(\.x)) == [3, 5])
    }

    @Test("Double corners turn both tracks without filling their center")
    func doubleCornerGoldens() {
        let topLeft = geometry(.lines(.init(right: .double, down: .double)), 9, 17)
        #expect(topLeft.rects == [
            .init(x: 3, y: 7, width: 6, height: 1),
            .init(x: 5, y: 9, width: 4, height: 1),
            .init(x: 3, y: 7, width: 1, height: 10),
            .init(x: 5, y: 9, width: 1, height: 8),
        ])
        #expect(
            canonical(geometry(.lines(.init(down: .double, left: .double)), 9, 17).rects)
                == canonical(mirrorHorizontally(topLeft.rects, width: 9))
        )
        #expect(
            canonical(geometry(.lines(.init(up: .double, right: .double)), 9, 17).rects)
                == canonical(mirrorVertically(topLeft.rects, height: 17))
        )
        #expect(
            canonical(geometry(.lines(.init(up: .double, left: .double)), 9, 17).rects)
                == canonical(mirrorVertically(mirrorHorizontally(topLeft.rects, width: 9), height: 17))
        )
    }

    @Test("Double tees, crossings, and mixed single-double junctions use neighbor-aware endpoints")
    func doubleJunctionGoldens() {
        #expect(geometry(
            .lines(.init(up: .double, right: .double, down: .double)),
            9, 17
        ).rects == [
            .init(x: 3, y: 0, width: 1, height: 10),
            .init(x: 5, y: 0, width: 1, height: 8),
            .init(x: 5, y: 7, width: 4, height: 1),
            .init(x: 5, y: 9, width: 4, height: 1),
            .init(x: 3, y: 7, width: 1, height: 10),
            .init(x: 5, y: 9, width: 1, height: 8),
        ])
        #expect(geometry(
            .lines(.init(up: .double, right: .double, down: .double, left: .double)),
            9, 17
        ).rects == [
            .init(x: 3, y: 0, width: 1, height: 8),
            .init(x: 5, y: 0, width: 1, height: 8),
            .init(x: 5, y: 7, width: 4, height: 1),
            .init(x: 5, y: 9, width: 4, height: 1),
            .init(x: 3, y: 9, width: 1, height: 8),
            .init(x: 5, y: 9, width: 1, height: 8),
            .init(x: 0, y: 7, width: 4, height: 1),
            .init(x: 0, y: 9, width: 4, height: 1),
        ])
        #expect(geometry(
            .lines(.init(up: .light, right: .double, down: .light)),
            9, 17
        ).rects == [
            .init(x: 4, y: 0, width: 1, height: 10),
            .init(x: 5, y: 7, width: 4, height: 1),
            .init(x: 5, y: 9, width: 4, height: 1),
            .init(x: 4, y: 7, width: 1, height: 10),
        ])
    }

    @Test("Mixed light-heavy junctions and opposing half-lines have complete rectangle goldens")
    func mixedWeightGoldens() {
        #expect(geometry(.lines(.init(right: .heavy, down: .light)), 9, 17).rects == [
            .init(x: 4, y: 7, width: 5, height: 2),
            .init(x: 4, y: 7, width: 1, height: 10),
        ])
        #expect(geometry(
            .lines(.init(up: .heavy, right: .light, down: .light)),
            9, 17
        ).rects == [
            .init(x: 3, y: 0, width: 2, height: 9),
            .init(x: 3, y: 8, width: 6, height: 1),
            .init(x: 4, y: 8, width: 1, height: 9),
        ])
        #expect(geometry(
            .lines(.init(up: .heavy, right: .heavy, down: .light, left: .light)),
            9, 17
        ).rects == [
            .init(x: 3, y: 0, width: 2, height: 9),
            .init(x: 3, y: 7, width: 6, height: 2),
            .init(x: 4, y: 7, width: 1, height: 10),
            .init(x: 0, y: 8, width: 5, height: 1),
        ])
        #expect(geometry(.lines(.init(right: .heavy, left: .light)), 9, 17).rects == [
            .init(x: 4, y: 7, width: 5, height: 2),
            .init(x: 0, y: 8, width: 5, height: 1),
        ])
        #expect(geometry(.lines(.init(up: .light, down: .heavy)), 9, 17).rects == [
            .init(x: 4, y: 0, width: 1, height: 9),
            .init(x: 3, y: 8, width: 2, height: 9),
        ])
    }

    @Test("Dashed, rounded, and diagonal categories have deterministic geometry")
    func nonJunctionGoldenGeometry() {
        #expect(geometry(.dashed(axis: .horizontal, weight: .light, count: 3), 9, 17).rects.count == 3)
        let arc = geometry(.arc(.topLeft), 9, 17)
        #expect(arc.strokes == [.init(
            points: [.init(x: 4, y: 17), .init(x: 4, y: 8), .init(x: 9, y: 8)],
            width: 1,
            isCurved: true
        )])
        #expect(geometry(.diagonal(.cross), 9, 17).strokes.count == 2)
        #expect(geometry(.arc(.topRight), 9, 17).strokes == [.init(
            points: [.init(x: 4, y: 17), .init(x: 4, y: 8), .init(x: 0, y: 8)],
            width: 1,
            isCurved: true
        )])
        #expect(geometry(.arc(.bottomLeft), 9, 17).strokes == [.init(
            points: [.init(x: 4, y: 0), .init(x: 4, y: 8), .init(x: 9, y: 8)],
            width: 1,
            isCurved: true
        )])
        #expect(geometry(.arc(.bottomRight), 9, 17).strokes == [.init(
            points: [.init(x: 4, y: 0), .init(x: 4, y: 8), .init(x: 0, y: 8)],
            width: 1,
            isCurved: true
        )])
    }

    @Test("Centered dash allocation has exact gaps, lengths, and complete budgets")
    func dashAllocationGoldens() {
        let samples: [(BoxDrawingPattern, Int, Int, [SpritePixelRect])] = [
            (
                .dashed(axis: .horizontal, weight: .light, count: 2), 9, 17,
                [.init(x: 0, y: 8, width: 4, height: 1),
                 .init(x: 5, y: 8, width: 3, height: 1)]
            ),
            (
                .dashed(axis: .horizontal, weight: .heavy, count: 3), 10, 18,
                [.init(x: 0, y: 8, width: 3, height: 2),
                 .init(x: 4, y: 8, width: 2, height: 2),
                 .init(x: 7, y: 8, width: 2, height: 2)]
            ),
            (
                .dashed(axis: .vertical, weight: .light, count: 4), 9, 17,
                [.init(x: 4, y: 0, width: 1, height: 4),
                 .init(x: 4, y: 5, width: 1, height: 3),
                 .init(x: 4, y: 9, width: 1, height: 3),
                 .init(x: 4, y: 13, width: 1, height: 3)]
            ),
            (
                .dashed(axis: .vertical, weight: .heavy, count: 2), 10, 18,
                [.init(x: 4, y: 1, width: 2, height: 7),
                 .init(x: 4, y: 10, width: 2, height: 7)]
            ),
        ]
        for (pattern, width, height, expected) in samples {
            #expect(geometry(pattern, width, height).rects == expected)
        }
        for axis in [BoxDrawingAxis.horizontal, .vertical] {
            for weight in [BoxDrawingWeight.light, .heavy] {
                for count in 2...4 {
                    let width = axis == .horizontal ? 13 : 10
                    let height = axis == .vertical ? 19 : 18
                    let rects = geometry(
                        .dashed(axis: axis, weight: weight, count: count),
                        width, height
                    ).rects
                    #expect(rects.count == count)
                    let extents = rects.map {
                        axis == .horizontal ? $0.width : $0.height
                    }
                    let starts = rects.map {
                        axis == .horizontal ? $0.x : $0.y
                    }
                    let ends = zip(starts, extents).map(+)
                    let gaps = zip(ends.dropLast(), starts.dropFirst()).map { $1 - $0 }
                    let leading = starts[0]
                    let trailing = (axis == .horizontal ? width : height) - ends.last!
                    #expect(abs(leading - trailing) <= 1)
                    #expect(gaps.allSatisfy { $0 > 0 })
                    #expect(extents.reduce(0, +) + gaps.reduce(0, +) + leading + trailing
                        == (axis == .horizontal ? width : height))
                }
            }
        }
        #expect(
            geometry(.dashed(axis: .horizontal, weight: .light, count: 4), 7, 9).rects
                == geometry(.lines(.init(right: .light, left: .light)), 7, 9).rects
        )
        #expect(
            geometry(.dashed(axis: .vertical, weight: .heavy, count: 3), 9, 5).rects
                == geometry(.lines(.init(up: .heavy, down: .heavy)), 9, 5).rects
        )
    }

    @Test("All structural forms obey containment, edge, separation, and stroke budgets")
    func boundedDimensionMatrix() {
        for width in 1...17 {
            for height in 1...33 {
                for pattern in representativePatterns {
                    let result = geometry(pattern, width, height)
                    for rect in result.rects {
                        #expect(rect.x >= 0 && rect.y >= 0)
                        #expect(rect.width > 0 && rect.height > 0)
                        #expect(rect.x + rect.width <= width)
                        #expect(rect.y + rect.height <= height)
                    }
                    for stroke in result.strokes {
                        #expect((1...max(width, height)).contains(stroke.width))
                        #expect(stroke.points.allSatisfy {
                            (0...width).contains($0.x) && (0...height).contains($0.y)
                        })
                    }
                }
            }
        }
    }

    private func geometry(
        _ pattern: BoxDrawingPattern, _ width: Int, _ height: Int
    ) -> BoxDrawingPixelGeometry {
        BoxDrawingSpriteGeometry.geometry(
            pattern: pattern,
            cellWidthPixels: width,
            cellHeightPixels: height,
            lightStrokePixels: 1
        )
    }

    private var representativePatterns: [BoxDrawingPattern] {
        [
            .lines(.init(up: .light, right: .heavy, down: .double, left: .light)),
            .lines(.init(up: .heavy, right: .heavy, down: .heavy, left: .heavy)),
            .lines(.init(up: .double, right: .double, down: .double, left: .double)),
            .dashed(axis: .horizontal, weight: .light, count: 2),
            .dashed(axis: .vertical, weight: .heavy, count: 4),
            .arc(.topLeft), .arc(.bottomRight),
            .diagonal(.rising), .diagonal(.falling), .diagonal(.cross),
        ]
    }

    private func mirrorHorizontally(_ rects: [SpritePixelRect], width: Int) -> [SpritePixelRect] {
        rects.map { .init(x: width - $0.x - $0.width, y: $0.y, width: $0.width, height: $0.height) }
    }

    private func mirrorVertically(_ rects: [SpritePixelRect], height: Int) -> [SpritePixelRect] {
        rects.map { .init(x: $0.x, y: height - $0.y - $0.height, width: $0.width, height: $0.height) }
    }

    private func canonical(_ rects: [SpritePixelRect]) -> [SpritePixelRect] {
        rects.sorted {
            ($0.y, $0.x, $0.height, $0.width) < ($1.y, $1.x, $1.height, $1.width)
        }
    }
}
