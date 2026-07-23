// Pure physical-pixel geometry proofs for the complete Powerline sprite family.
import Testing

@testable import TerminalSpriteGeometry

struct PowerlineSpriteGeometryTests {
    @Test("Every pattern has deterministic contained geometry at ordinary and constrained sizes")
    func exhaustiveGeometry() {
        for width in 1...17 {
            for height in 1...33 {
                for pattern in PowerlinePattern.allCases {
                    let first = PowerlineSpriteGeometry.geometry(
                        pattern: pattern,
                        cellWidthPixels: width,
                        cellHeightPixels: height,
                        lightStrokePixels: 1
                    )
                    let second = PowerlineSpriteGeometry.geometry(
                        pattern: pattern,
                        cellWidthPixels: width,
                        cellHeightPixels: height,
                        lightStrokePixels: 1
                    )
                    let context = Comment(rawValue: "\(pattern), \(width)x\(height)")
                    #expect(first == second, context)
                    #expect(first.paths.isEmpty == false, context)
                    #expect(first.paths.flatMap(\.commands).flatMap(\.points).allSatisfy {
                        $0.x >= 0 && $0.x <= Double(width)
                            && $0.y >= 0 && $0.y <= Double(height)
                    }, context)
                }
            }
        }
    }

    @Test("Canonical Powerline paths match Ghostty endpoints and cubic controls")
    func canonicalGeometry() {
        let hard = PowerlineSpriteGeometry.geometry(
            pattern: .rightHard,
            cellWidthPixels: 8,
            cellHeightPixels: 16,
            lightStrokePixels: 1
        )
        #expect(hard.paths == [.init(commands: [
            .move(.init(x: 0, y: 0)),
            .line(.init(x: 8, y: 8)),
            .line(.init(x: 0, y: 16)),
            .close,
        ], style: .fill)])

        let rounded = PowerlineSpriteGeometry.geometry(
            pattern: .rightHardRounded,
            cellWidthPixels: 8,
            cellHeightPixels: 16,
            lightStrokePixels: 1
        )
        let c = (2.squareRoot() - 1) * 4 / 3
        #expect(rounded.paths[0].commands == [
            .move(.init(x: 0, y: 0)),
            .cubic(
                control1: .init(x: 8 * c, y: 0),
                control2: .init(x: 8, y: 8 - 8 * c),
                end: .init(x: 8, y: 8)
            ),
            .line(.init(x: 8, y: 8)),
            .cubic(
                control1: .init(x: 8, y: 8 + 8 * c),
                control2: .init(x: 8 * c, y: 16),
                end: .init(x: 0, y: 16)
            ),
            .close,
        ])
    }

    @Test("Left and right forms are exact horizontal mirrors")
    func horizontalMirrors() {
        let pairs: [(PowerlinePattern, PowerlinePattern)] = [
            (.rightHard, .leftHard), (.rightThin, .leftThin),
            (.rightHardRounded, .leftHardRounded), (.rightThinRounded, .leftThinRounded),
            (.upperRightHardDiagonal, .lowerRightHardDiagonal),
            (.lowerLeftHardDiagonal, .upperLeftHardDiagonal),
            (.upperRightThinDiagonal, .lowerRightThinDiagonal),
            (.lowerLeftThinDiagonal, .upperLeftThinDiagonal),
            (.leftCap, .rightCap),
        ]
        for (left, right) in pairs {
            let lhs = PowerlineSpriteGeometry.geometry(
                pattern: left, cellWidthPixels: 7, cellHeightPixels: 15, lightStrokePixels: 1
            )
            let rhs = PowerlineSpriteGeometry.geometry(
                pattern: right, cellWidthPixels: 7, cellHeightPixels: 15, lightStrokePixels: 1
            )
            #expect(rhs == lhs.mirroredHorizontally(cellWidthPixels: 7))
        }
    }

    @Test("Zero dimensions degrade to no paths and thick strokes are bounded")
    func scarcity() {
        #expect(PowerlineSpriteGeometry.geometry(
            pattern: .rightThin, cellWidthPixels: 0, cellHeightPixels: 9, lightStrokePixels: 1
        ).paths.isEmpty)
        let tiny = PowerlineSpriteGeometry.geometry(
            pattern: .rightThinRounded,
            cellWidthPixels: 1,
            cellHeightPixels: 1,
            lightStrokePixels: 4
        )
        #expect(tiny.paths[0].style == .innerStroke(widthPixels: 1))
    }
}

private extension PowerlinePixelPathCommand {
    var points: [PowerlinePixelPoint] {
        switch self {
        case let .move(point), let .line(point): [point]
        case let .cubic(control1, control2, end): [control1, control2, end]
        case .close: []
        }
    }
}
