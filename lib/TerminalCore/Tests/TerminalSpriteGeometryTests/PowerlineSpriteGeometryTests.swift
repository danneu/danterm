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
        // Intent: each left-hand Powerline form is the right-hand form reflected about
        //   the cell's vertical centerline, with y and style untouched.
        // Why it exists: `PowerlineSpriteGeometry.geometry` derives seven of these nine
        //   right-hand patterns by calling the production
        //   `PowerlinePixelGeometry.mirroredHorizontally` itself, so asserting against
        //   that same function restated the implementation -- a bug inside it (mirroring
        //   y, dropping a cubic control point) changed both sides and stayed green. The
        //   independent `testMirror` oracle below is what makes the pairs falsifiable.
        // Scenario: spec-first; no incident.
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
            let context = Comment(rawValue: "\(left) -> \(right)")
            #expect(rhs.paths.map(\.style) == lhs.paths.map(\.style), context)
            #expect(
                rhs.paths.map(\.commands)
                    == lhs.paths.map { testMirror($0.commands, cellWidthPixels: 7) },
                context
            )
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

/// Reflects path commands about the cell's vertical centerline independently of the
/// production mirror, so `horizontalMirrors` has an oracle the implementation cannot
/// satisfy by construction. Deliberately spelled out the naive way: `x -> width - x`,
/// `y` and command kind unchanged.
private func testMirror(
    _ commands: [PowerlinePixelPathCommand],
    cellWidthPixels width: Int
) -> [PowerlinePixelPathCommand] {
    func flip(_ point: PowerlinePixelPoint) -> PowerlinePixelPoint {
        PowerlinePixelPoint(x: Double(width) - point.x, y: point.y)
    }
    return commands.map { command in
        switch command {
        case let .move(point): .move(flip(point))
        case let .line(point): .line(flip(point))
        case let .cubic(control1, control2, end):
            .cubic(control1: flip(control1), control2: flip(control2), end: flip(end))
        case .close: .close
        }
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
