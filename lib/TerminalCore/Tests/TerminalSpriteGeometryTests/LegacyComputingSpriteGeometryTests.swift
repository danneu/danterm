// Pure containment and representative shape proofs for legacy-computing sprites.
import Testing

@testable import TerminalSpriteGeometry

struct LegacyComputingSpriteGeometryTests {
    @Test("Every scalar decodes to its canonical structural subgroup and identity")
    func canonicalTopology() {
        #expect(LegacyComputingPattern(scalar: 0x1FB00).topology == .sextant(mask: 1))
        #expect(LegacyComputingPattern(scalar: 0x1FB14).topology == .sextant(mask: 22))
        #expect(LegacyComputingPattern(scalar: 0x1FB3B).topology == .sextant(mask: 62))

        let smooth = (UInt32(0x1FB3C)...UInt32(0x1FB67)).map {
            LegacyComputingPattern(scalar: $0).topology
        }
        let smoothGrids = [
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
        #expect(smooth == smoothGrids.map(LegacyComputingTopology.smoothMosaic(grid:)))

        for offset in 0..<8 {
            #expect(LegacyComputingPattern(scalar: 0x1FB68 + UInt32(offset)).topology
                == .edgeTriangle(edge: offset % 4, inverted: offset < 4))
        }
        for offset in 0..<6 {
            #expect(LegacyComputingPattern(scalar: 0x1FB70 + UInt32(offset)).topology
                == .verticalEighth(index: offset + 1))
            #expect(LegacyComputingPattern(scalar: 0x1FB76 + UInt32(offset)).topology
                == .horizontalEighth(index: offset + 1))
        }
        let blockPolicies = [
            "left-eighth+lower-eighth", "left-eighth+upper-eighth", "right-eighth+upper-eighth",
            "right-eighth+lower-eighth", "upper-eighth+lower-eighth", "horizontal-eighths-1-3-5-8",
            "upper-quarter", "upper-three-eighths", "upper-five-eighths", "upper-three-quarters",
            "upper-seven-eighths", "right-quarter", "right-three-eighths", "right-five-eighths",
            "right-three-quarters", "right-seven-eighths", "medium-left-half", "medium-right-half",
            "medium-upper-half", "medium-lower-half", "medium-full", "medium-full+solid-upper",
            "medium-full+solid-lower", "empty", "medium-full+solid-right", "checker-even",
            "checker-odd", "horizontal-bands-second-fourth",
        ]
        for (offset, policy) in blockPolicies.enumerated() {
            #expect(LegacyComputingPattern(scalar: 0x1FB7C + UInt32(offset)).topology
                == .legacyBlock(policy: policy))
        }
        #expect(LegacyComputingPattern(scalar: 0x1FB98).topology == .diagonalFill(ascending: true))
        #expect(LegacyComputingPattern(scalar: 0x1FB99).topology == .diagonalFill(ascending: false))
        #expect(LegacyComputingPattern(scalar: 0x1FB9A).topology == .pairedEdgeTriangles(horizontal: true))
        #expect(LegacyComputingPattern(scalar: 0x1FB9B).topology == .pairedEdgeTriangles(horizontal: false))
        for offset in 0..<4 {
            #expect(LegacyComputingPattern(scalar: 0x1FB9C + UInt32(offset)).topology
                == .shadedCorner(index: offset))
        }
        let cornerMasks = [1, 2, 4, 8, 5, 10, 12, 3, 9, 6, 14, 13, 11, 7, 15]
        for (offset, mask) in cornerMasks.enumerated() {
            #expect(LegacyComputingPattern(scalar: 0x1FBA0 + UInt32(offset)).topology
                == .cornerDiagonals(mask: mask))
        }
        #expect(LegacyComputingPattern(scalar: 0x1FBAF).topology == .mixedCross)
        for offset in 0..<3 {
            #expect(LegacyComputingPattern(scalar: 0x1FBBD + UInt32(offset)).topology
                == .negativeDiagonal(index: offset))
        }
        #expect(LegacyComputingPattern(scalar: 0x1FBCE).topology == .fractionalLeft(thirds: 2))
        #expect(LegacyComputingPattern(scalar: 0x1FBCF).topology == .fractionalLeft(thirds: 1))
        let diagonalSegments = [
            "MR-LL", "UR-ML", "UL-MR", "ML-LR", "UL-LC", "UC-LR", "UR-LC", "UC-LL",
            "UL-MC+MC-UR", "UR-MC+MC-LR", "LL-MC+MC-LR", "UL-MC+MC-LL",
            "UL-LC+LC-UR", "UR-ML+ML-LR", "LL-UC+UC-LR", "UL-MR+MR-LL",
        ]
        let circleShapes = [
            "outline-top", "outline-right", "outline-bottom", "outline-left",
            "upper-centered-half-block", "lower-centered-half-block",
            "middle-left-half-block", "middle-right-half-block",
            "filled-top", "filled-right", "filled-bottom", "filled-left",
            "filled-top-right", "filled-bottom-left", "filled-bottom-right", "filled-top-left",
        ]
        for offset in 0..<16 {
            #expect(LegacyComputingPattern(scalar: 0x1FBD0 + UInt32(offset)).topology
                == .cellDiagonals(segments: diagonalSegments[offset]))
            #expect(LegacyComputingPattern(scalar: 0x1FBE0 + UInt32(offset)).topology
                == .legacyCircle(shape: circleShapes[offset]))
        }
    }

    @Test("Every supported scalar has deterministic contained physical-pixel runs")
    func exhaustiveContainment() {
        let values = Array(UInt32(0x1FB00)...UInt32(0x1FBAF))
            + Array(UInt32(0x1FBBD)...UInt32(0x1FBBF))
            + Array(UInt32(0x1FBCE)...UInt32(0x1FBEF))
        for (width, height) in [(1, 1), (2, 3), (7, 15), (8, 16), (16, 32)] {
            for value in values {
                let pattern = LegacyComputingPattern(scalar: value)
                let first = LegacyComputingSpriteGeometry.runs(
                    pattern: pattern, cellWidthPixels: width, cellHeightPixels: height
                )
                let second = LegacyComputingSpriteGeometry.runs(
                    pattern: pattern, cellWidthPixels: width, cellHeightPixels: height
                )
                #expect(first == second)
                #expect(first.allSatisfy {
                    $0.rect.x >= 0 && $0.rect.y >= 0
                        && $0.rect.x + $0.rect.width <= width
                        && $0.rect.y + $0.rect.height <= height
                        && $0.rect.width > 0 && $0.rect.height > 0
                }, Comment(rawValue: "U+\(String(value, radix: 16, uppercase: true)) \(width)x\(height)"))
            }
        }
    }

    @Test("Sextants follow Ghostty's skipped empty and full bit masks")
    func sextantMasks() {
        let first = LegacyComputingSpriteGeometry.runs(
            pattern: LegacyComputingPattern(scalar: 0x1FB00),
            cellWidthPixels: 8,
            cellHeightPixels: 18
        )
        let last = LegacyComputingSpriteGeometry.runs(
            pattern: LegacyComputingPattern(scalar: 0x1FB3B),
            cellWidthPixels: 8,
            cellHeightPixels: 18
        )
        #expect(first.reduce(0) { $0 + $1.rect.width * $1.rect.height } == 24)
        #expect(last.reduce(0) { $0 + $1.rect.width * $1.rect.height } == 120)
    }

    @Test("Constrained dimensions degrade safely and zero dimensions are empty")
    func constrainedSizes() {
        let pattern = LegacyComputingPattern(scalar: 0x1FBE8)
        #expect(LegacyComputingSpriteGeometry.runs(
            pattern: pattern, cellWidthPixels: 0, cellHeightPixels: 10
        ).isEmpty)
        #expect(LegacyComputingSpriteGeometry.runs(
            pattern: pattern, cellWidthPixels: 10, cellHeightPixels: 0
        ).isEmpty)
        #expect(LegacyComputingSpriteGeometry.runs(
            pattern: pattern, cellWidthPixels: 1, cellHeightPixels: 1
        ).count <= 1)
    }

    @Test("Unallocated U+1FB93 is intentionally empty while neighboring shades are not")
    func unallocatedHole() {
        func runs(_ value: UInt32) -> [LegacyComputingPixelRun] {
            LegacyComputingSpriteGeometry.runs(
                pattern: LegacyComputingPattern(scalar: value),
                cellWidthPixels: 8,
                cellHeightPixels: 16
            )
        }
        #expect(runs(0x1FB92).isEmpty == false)
        #expect(runs(0x1FB93).isEmpty)
        #expect(runs(0x1FB94).isEmpty == false)
    }

    @Test("All sixteen cell-diagonal topologies remain pairwise distinct at canonical size")
    func cellDiagonalIdentity() {
        let geometries = (UInt32(0x1FBD0)...UInt32(0x1FBDF)).map {
            LegacyComputingSpriteGeometry.runs(
                pattern: LegacyComputingPattern(scalar: $0),
                cellWidthPixels: 16,
                cellHeightPixels: 24
            )
        }
        #expect(Set(geometries.map(String.init(describing:))).count == 16)
    }

    @Test("Stroke quantization scales light and heavy legacy lines in physical pixels")
    func strokeQuantization() {
        func ink(_ value: UInt32, width: Int, height: Int, stroke: Int) -> Int {
            LegacyComputingSpriteGeometry.runs(
                pattern: LegacyComputingPattern(scalar: value),
                cellWidthPixels: width,
                cellHeightPixels: height,
                lightStrokePixels: stroke
            ).reduce(0) { $0 + $1.rect.width * $1.rect.height }
        }
        let diagonal1 = ink(0x1FBD0, width: 8, height: 16, stroke: 1)
        let diagonal2 = ink(0x1FBD0, width: 16, height: 32, stroke: 2)
        #expect(diagonal2 >= diagonal1 * 3)
        #expect(diagonal2 <= diagonal1 * 7)

        let crossLight1 = ink(0x1FBAF, width: 8, height: 16, stroke: 1)
        let crossLight2 = ink(0x1FBAF, width: 16, height: 32, stroke: 2)
        #expect(crossLight2 >= crossLight1 * 3)
        #expect(crossLight2 <= crossLight1 * 5)

        let stripes1 = ink(0x1FB98, width: 8, height: 16, stroke: 1)
        let stripes2 = ink(0x1FB98, width: 16, height: 32, stroke: 2)
        #expect(stripes2 >= stripes1 * 3)
        #expect(stripes2 <= stripes1 * 5)
    }
}
