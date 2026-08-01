// Pure physical-pixel geometry proofs for the complete Branch Drawing sprite family.
import Testing
import TerminalSpriteGeometry

struct BranchDrawingSpriteGeometryTests {
    @Test("All 30 line patterns have their canonical ordinary-size topology")
    func canonicalLineTopologies() {
        let h = "R(0,8,9,1,255)"
        let v = "R(4,0,1,17,255)"
        let br = "A(5,0;5,9;0,9;1)"
        let bl = "A(5,0;5,9;9,9;1)"
        let tr = "A(5,17;5,9;0,9;1)"
        let tl = "A(5,17;5,9;9,9;1)"
        let fadeUp: String = (0..<17).map { (row: Int) -> String in
            let coverage = Double(17 - row) * 255 / 17
            let alpha = Int(coverage.rounded())
            return "R(4,\(row),1,1,\(alpha))"
        }.joined(separator: " ")
        let fadeDown: String = (0..<17).map { (row: Int) -> String in
            let coverage = Double(row) * 255 / 17
            let alpha = Int(coverage.rounded())
            return "R(4,\(row),1,1,\(alpha))"
        }.joined(separator: " ")
        let expected: [String] = [
            h,
            v,
            "R(0,8,1,1,255) R(1,8,1,1,227) R(2,8,1,1,198) R(3,8,1,1,170) R(4,8,1,1,142) R(5,8,1,1,113) R(6,8,1,1,85) R(7,8,1,1,57) R(8,8,1,1,28)",
            "R(0,8,1,1,0) R(1,8,1,1,28) R(2,8,1,1,57) R(3,8,1,1,85) R(4,8,1,1,113) R(5,8,1,1,142) R(6,8,1,1,170) R(7,8,1,1,198) R(8,8,1,1,227)",
            fadeUp,
            fadeDown,
            br, bl, tr, tl,
            "\(v) \(tr)", "\(v) \(br)", "\(tr) \(br)",
            "\(v) \(tl)", "\(v) \(bl)", "\(tl) \(bl)",
            "\(h) \(bl)", "\(h) \(br)", "\(br) \(bl)",
            "\(h) \(tl)", "\(h) \(tr)", "\(tr) \(tl)",
            "\(v) \(tl) \(tr)", "\(v) \(bl) \(br)",
            "\(h) \(bl) \(tl)", "\(h) \(tr) \(br)",
            "\(v) \(tl) \(br)", "\(v) \(tr) \(bl)",
            "\(h) \(tl) \(br)", "\(h) \(tr) \(bl)",
        ]

        #expect(expected.count == BranchLinePattern.allCases.count)
        for (pattern, expectedSignature) in zip(BranchLinePattern.allCases, expected) {
            let geometry = BranchDrawingSpriteGeometry.geometry(
                pattern: .line(pattern), cellWidthPixels: 9,
                cellHeightPixels: 17, lightStrokePixels: 1
            )
            #expect(
                signature(geometry) == expectedSignature,
                Comment(rawValue: "\(pattern)")
            )
        }
    }

    @Test("Every pattern is deterministic and contained across constrained cell sizes")
    func boundedMatrix() {
        let patterns = BranchLinePattern.allCases.map(BranchDrawingPattern.line)
            + nodePatterns()
        for width in 0...12 {
            for height in 0...18 {
                for pattern in patterns {
                    let first = BranchDrawingSpriteGeometry.geometry(
                        pattern: pattern, cellWidthPixels: width,
                        cellHeightPixels: height, lightStrokePixels: 1
                    )
                    let second = BranchDrawingSpriteGeometry.geometry(
                        pattern: pattern, cellWidthPixels: width,
                        cellHeightPixels: height, lightStrokePixels: 1
                    )
                    #expect(first == second)
                    #expect(first.rects.allSatisfy {
                        $0.rect.x >= 0 && $0.rect.y >= 0
                            && $0.rect.x + $0.rect.width <= width
                            && $0.rect.y + $0.rect.height <= height
                    })
                }
            }
        }
    }

    @Test("Fades allocate one strip per pixel and reverse coverage exactly")
    func fadeAllocation() {
        let right = BranchDrawingSpriteGeometry.geometry(
            pattern: .line(.fadeRight), cellWidthPixels: 7,
            cellHeightPixels: 11, lightStrokePixels: 1
        )
        let left = BranchDrawingSpriteGeometry.geometry(
            pattern: .line(.fadeLeft), cellWidthPixels: 7,
            cellHeightPixels: 11, lightStrokePixels: 1
        )
        #expect(right.rects.count == 7)
        #expect(left.rects.count == 7)
        #expect(right.rects.map(\.alpha) == [255, 219, 182, 146, 109, 73, 36])
        #expect(left.rects.map(\.alpha) == [0, 36, 73, 109, 146, 182, 219])
        #expect(right.rects.allSatisfy { $0.rect.height == 1 && $0.rect.width == 1 })
    }

    @Test("Node connectors touch requested edges and share the circle axes")
    func nodeConnectivity() throws {
        let geometry = BranchDrawingSpriteGeometry.geometry(
            pattern: .node(.init(directions: [.up, .right, .down, .left], filled: false)),
            cellWidthPixels: 9, cellHeightPixels: 17, lightStrokePixels: 1
        )
        let node = try #require(geometry.node)
        #expect(node.centerX == 4.5)
        #expect(node.centerY == 8.5)
        #expect(node.radius == 4.5)
        #expect(geometry.rects.contains { $0.rect.y == 0 })
        #expect(geometry.rects.contains { $0.rect.x == 0 })
        #expect(geometry.rects.contains { $0.rect.x + $0.rect.width == 9 })
        #expect(geometry.rects.contains { $0.rect.y + $0.rect.height == 17 })
    }

    @Test("Zero-sized cells degrade to empty geometry")
    func zeroSized() {
        #expect(BranchDrawingSpriteGeometry.geometry(
            pattern: .line(.horizontal), cellWidthPixels: 0,
            cellHeightPixels: 4, lightStrokePixels: 1
        ) == BranchPixelGeometry(rects: [], arcs: [], node: nil))
    }
}

private func signature(_ geometry: BranchPixelGeometry) -> String {
    let rects = geometry.rects.map {
        "R(\($0.rect.x),\($0.rect.y),\($0.rect.width),\($0.rect.height),\($0.alpha))"
    }
    let arcs = geometry.arcs.map {
        "A(\($0.start.x),\($0.start.y);\($0.control.x),\($0.control.y);"
            + "\($0.end.x),\($0.end.y);\($0.width))"
    }
    return (rects + arcs).joined(separator: " ")
}

private func nodePatterns() -> [BranchDrawingPattern] {
    (0..<16).flatMap { mask in
        [true, false].map { filled in
            .node(.init(
                directions: BranchDirections(rawValue: UInt8(mask)),
                filled: filled
            ))
        }
    }
}
