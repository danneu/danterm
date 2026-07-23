// Pure physical-pixel allocation proofs for Unicode braille sprites.
import Testing

@testable import TerminalSpriteGeometry

struct BrailleSpriteGeometryTests {
    @Test(
        "Braille layout follows the declared square-dot allocation policy",
        arguments: [
            BrailleLayoutSample(
                width: 8, height: 16, dotSize: 2,
                xPositions: [1, 5], yPositions: [1, 5, 9, 13]
            ),
            BrailleLayoutSample(
                width: 9, height: 16, dotSize: 2,
                xPositions: [1, 6], yPositions: [1, 5, 9, 13]
            ),
            BrailleLayoutSample(
                width: 8, height: 17, dotSize: 2,
                xPositions: [1, 5], yPositions: [1, 5, 9, 13]
            ),
            BrailleLayoutSample(
                width: 9, height: 18, dotSize: 2,
                xPositions: [1, 6], yPositions: [2, 6, 10, 14]
            ),
            BrailleLayoutSample(
                width: 10, height: 20, dotSize: 2,
                xPositions: [1, 6], yPositions: [1, 6, 11, 16]
            ),
            BrailleLayoutSample(
                width: 12, height: 24, dotSize: 3,
                xPositions: [1, 8], yPositions: [1, 7, 13, 19]
            ),
            BrailleLayoutSample(
                width: 6, height: 16, dotSize: 1,
                xPositions: [1, 4], yPositions: [1, 5, 9, 13]
            ),
            BrailleLayoutSample(
                width: 12, height: 12, dotSize: 1,
                xPositions: [2, 7], yPositions: [1, 4, 7, 10]
            ),
            BrailleLayoutSample(
                width: 2, height: 4, dotSize: 1,
                xPositions: [0, 1], yPositions: [0, 1, 2, 3]
            ),
            BrailleLayoutSample(
                width: 2, height: 3, dotSize: 0,
                xPositions: nil, yPositions: nil
            ),
        ]
    )
    func representativePixelLayouts(sample: BrailleLayoutSample) {
        // Intent: pin the allocator's observable dot size and grid positions at
        //   even, odd, constrained, minimum viable, and degraded cell sizes.
        // Why it exists: the shared geometry layer must preserve braille's proven
        //   pixel allocation while remaining independent from render execution.
        // Scenario: a terminal font or display scale produces one of these physical
        //   cell sizes and every braille pattern must use the same stable grid.
        let layout = BrailleSpriteGeometry.layout(
            cellWidthPixels: sample.width,
            cellHeightPixels: sample.height
        )

        #expect(layout.dotSize == sample.dotSize)
        if let xPositions = sample.xPositions {
            #expect(layout.xPositions == xPositions)
        }
        if let yPositions = sample.yPositions {
            #expect(layout.yPositions == yPositions)
        }
    }

    @Test("Braille layout preserves its physical-pixel invariants across supported sizes")
    func physicalPixelInvariantMatrix() {
        // Intent: verify square uniform dots, containment, separation, shared axes,
        //   equal gaps, and deterministic allocation throughout a bounded size matrix.
        // Why it exists: the shared primitive must not weaken the allocator contract
        //   when geometry moves away from the Core Graphics execution boundary.
        // Scenario: users select fonts and display scales yielding physical cells
        //   from 1x1 through the larger ordinary terminal sizes in this matrix.
        for width in 1...32 {
            for height in 1...64 {
                let context = Comment(rawValue: "cell \(width)x\(height)")
                let layout = BrailleSpriteGeometry.layout(
                    cellWidthPixels: width,
                    cellHeightPixels: height
                )
                let repeated = BrailleSpriteGeometry.layout(
                    cellWidthPixels: width,
                    cellHeightPixels: height
                )

                #expect(layout == repeated, context)
                #expect(
                    (layout.dotSize > 0) == (width >= 2 && height >= 4),
                    context
                )
                #expect(layout.dotSize >= 0, context)

                let rects = (0..<2).flatMap { column in
                    (0..<4).map { row in
                        layout.rect(column: column, row: row)
                    }
                }
                for rect in rects {
                    #expect(rect.width == rect.height, context)
                    if layout.dotSize > 0 {
                        #expect(
                            rect.x >= 0
                            && rect.y >= 0
                            && rect.x + rect.width <= width
                            && rect.y + rect.height <= height,
                            context
                        )
                    }
                }

                guard layout.dotSize > 0 else { continue }
                #expect(
                    layout.xPositions[0] < layout.xPositions[1]
                    && zip(
                        layout.yPositions,
                        layout.yPositions.dropFirst()
                    ).allSatisfy(<)
                    && layout.xPositions[0] + layout.dotSize <= layout.xPositions[1]
                    && zip(
                        layout.yPositions,
                        layout.yPositions.dropFirst()
                    ).allSatisfy {
                        $0 + layout.dotSize <= $1
                    },
                    context
                )
                let verticalGaps = zip(
                    layout.yPositions,
                    layout.yPositions.dropFirst()
                ).map { $1 - ($0 + layout.dotSize) }
                #expect(Set(verticalGaps).count == 1, context)
            }
        }
    }
}

struct BrailleLayoutSample: Sendable, CustomTestStringConvertible {
    let width: Int
    let height: Int
    let dotSize: Int
    let xPositions: [Int]?
    let yPositions: [Int]?

    var testDescription: String {
        "\(width)x\(height)"
    }
}
