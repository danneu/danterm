// Exact scalar membership and pattern decoding for the eight sprite families.
//
// One file because the eight decodes are one vocabulary behind one entry point
// (`spriteDecode(for:)`). These suites own the per-family answers; `SpriteVocabularyTests`
// owns the properties that hold across all eight. Rendered output stays in
// `TerminalRenderExecutionTests`.
import Testing

@testable import TerminalSpriteGeometry

struct BoxDrawingSpriteDecodeTests {
    @Test("Sprite membership is exactly one scalar in the Box Drawing range")
    func exactSupportedSet() {
        for value in UInt32(0x2500)...UInt32(0x257F) {
            #expect(BoxDrawingSpriteGeometry.pattern(for: Unicode.Scalar(value)!) != nil)
        }
        #expect(BoxDrawingSpriteGeometry.pattern(for: "\u{24FF}") == nil)
        #expect(BoxDrawingSpriteGeometry.pattern(for: "\u{2580}") == nil)
    }

    @Test("Every Box Drawing scalar has its exact canonical structural pattern")
    func exhaustivePatternMapping() {
        let actual = (UInt32(0x2500)...UInt32(0x257F)).map {
            patternSignature(BoxDrawingSpriteGeometry.pattern(for: Unicode.Scalar($0)!)!)
        }.joined(separator: "/")
        #expect(actual == "nlnl/nhnh/lnln/hnhn/Hl3/Hh3/Vl3/Vh3/Hl4/Hh4/Vl4/Vh4/nlln/nhln/nlhn/nhhn/nnll/nnlh/nnhl/nnhh/llnn/lhnn/hlnn/hhnn/lnnl/lnnh/hnnl/hnnh/llln/lhln/hlln/llhn/hlhn/hhln/lhhn/hhhn/lnll/lnlh/hnll/lnhl/hnhl/hnlh/lnhh/hnhh/nlll/nllh/nhll/nhlh/nlhl/nlhh/nhhl/nhhh/llnl/llnh/lhnl/lhnh/hlnl/hlnh/hhnl/hhnh/llll/lllh/lhll/lhlh/hlll/llhl/hlhl/hllh/hhll/llhh/lhhl/hhlh/lhhh/hlhh/hhhl/hhhh/Hl2/Hh2/Vl2/Vh2/ndnd/dndn/ndln/nldn/nddn/nnld/nndl/nndd/ldnn/dlnn/ddnn/lnnd/dnnl/dnnd/ldln/dldn/dddn/lnld/dndl/dndd/ndld/nldl/nddd/ldnd/dlnl/ddnd/ldld/dldl/dddd/ATL/ATR/ABR/ABL/DR/DF/DX/nnnl/lnnn/nlnn/nnln/nnnh/hnnn/nhnn/nnhn/nhnl/lnhn/nlnh/hnln")
    }
}

struct BlockElementSpriteDecodeTests {
    @Test("Sprite membership is exactly one scalar in the Block Elements range")
    func exactSupportedSet() {
        for value in UInt32(0x2580)...UInt32(0x259F) {
            #expect(BlockElementSpriteGeometry.pattern(for: Unicode.Scalar(value)!) != nil)
        }
        #expect(BlockElementSpriteGeometry.pattern(for: "\u{257F}") == nil)
        #expect(BlockElementSpriteGeometry.pattern(for: "\u{25A0}") == nil)
    }

    @Test("Every Block Elements scalar decodes to its Unicode shape")
    func exhaustivePatternDecoding() {
        let expected: [BlockElementPattern] = [
            .aligned(horizontal: .full, vertical: .start, widthEighths: 8, heightEighths: 4),
            .aligned(horizontal: .full, vertical: .end, widthEighths: 8, heightEighths: 1),
            .aligned(horizontal: .full, vertical: .end, widthEighths: 8, heightEighths: 2),
            .aligned(horizontal: .full, vertical: .end, widthEighths: 8, heightEighths: 3),
            .aligned(horizontal: .full, vertical: .end, widthEighths: 8, heightEighths: 4),
            .aligned(horizontal: .full, vertical: .end, widthEighths: 8, heightEighths: 5),
            .aligned(horizontal: .full, vertical: .end, widthEighths: 8, heightEighths: 6),
            .aligned(horizontal: .full, vertical: .end, widthEighths: 8, heightEighths: 7),
            .full(shade: .solid),
            .aligned(horizontal: .start, vertical: .full, widthEighths: 7, heightEighths: 8),
            .aligned(horizontal: .start, vertical: .full, widthEighths: 6, heightEighths: 8),
            .aligned(horizontal: .start, vertical: .full, widthEighths: 5, heightEighths: 8),
            .aligned(horizontal: .start, vertical: .full, widthEighths: 4, heightEighths: 8),
            .aligned(horizontal: .start, vertical: .full, widthEighths: 3, heightEighths: 8),
            .aligned(horizontal: .start, vertical: .full, widthEighths: 2, heightEighths: 8),
            .aligned(horizontal: .start, vertical: .full, widthEighths: 1, heightEighths: 8),
            .aligned(horizontal: .end, vertical: .full, widthEighths: 4, heightEighths: 8),
            .full(shade: .light),
            .full(shade: .medium),
            .full(shade: .dark),
            .aligned(horizontal: .full, vertical: .start, widthEighths: 8, heightEighths: 1),
            .aligned(horizontal: .end, vertical: .full, widthEighths: 1, heightEighths: 8),
            .quadrants([.bottomLeft]),
            .quadrants([.bottomRight]),
            .quadrants([.topLeft]),
            .quadrants([.topLeft, .bottomLeft, .bottomRight]),
            .quadrants([.topLeft, .bottomRight]),
            .quadrants([.topLeft, .topRight, .bottomLeft]),
            .quadrants([.topLeft, .topRight, .bottomRight]),
            .quadrants([.topRight]),
            .quadrants([.topRight, .bottomLeft]),
            .quadrants([.topRight, .bottomLeft, .bottomRight]),
        ]

        for (offset, pattern) in expected.enumerated() {
            let scalar = Unicode.Scalar(0x2580 + UInt32(offset))!
            #expect(BlockElementSpriteGeometry.pattern(for: scalar) == pattern)
        }
    }
}

struct BrailleSpriteDecodeTests {
    @Test("Membership is exactly the braille block and the pattern is the dot bitmask")
    func exactSupportedSet() {
        #expect(BrailleSpriteGeometry.pattern(for: "\u{2800}") == 0)
        #expect(BrailleSpriteGeometry.pattern(for: "\u{28FF}") == 0xFF)
        #expect(BrailleSpriteGeometry.pattern(for: "\u{27FF}") == nil)
        #expect(BrailleSpriteGeometry.pattern(for: "\u{2900}") == nil)
        #expect(BrailleSpriteGeometry.pattern(for: "\u{1F600}") == nil)
    }
}

struct GeometricShapeSpriteDecodeTests {
    @Test("Sprite membership is exactly the eight supported single scalars")
    func exactSupportedSet() {
        let supported = Set([0x25E2, 0x25E3, 0x25E4, 0x25E5, 0x25F8, 0x25F9, 0x25FA, 0x25FF])
        for value in UInt32(0x25E1)...UInt32(0x2600) {
            #expect(
                (GeometricShapeSpriteGeometry.pattern(for: Unicode.Scalar(value)!) != nil)
                    == supported.contains(Int(value)),
                Comment(rawValue: "U+\(String(value, radix: 16, uppercase: true))")
            )
        }
    }

    @Test("Every supported scalar maps exhaustively to its corner and style")
    func exhaustiveMapping() {
        let expected: [(Unicode.Scalar, GeometricShapePattern)] = [
            ("\u{25E2}", .init(corner: .bottomRight, style: .filled)),
            ("\u{25E3}", .init(corner: .bottomLeft, style: .filled)),
            ("\u{25E4}", .init(corner: .topLeft, style: .filled)),
            ("\u{25E5}", .init(corner: .topRight, style: .filled)),
            ("\u{25F8}", .init(corner: .topLeft, style: .outlined)),
            ("\u{25F9}", .init(corner: .topRight, style: .outlined)),
            ("\u{25FA}", .init(corner: .bottomLeft, style: .outlined)),
            ("\u{25FF}", .init(corner: .bottomRight, style: .outlined)),
        ]
        for (scalar, pattern) in expected {
            #expect(GeometricShapeSpriteGeometry.pattern(for: scalar) == pattern)
        }
    }
}

struct PowerlineSpriteDecodeTests {
    @Test("Sprite membership is exactly the 18 supported single scalars")
    func exactSupportedSet() {
        let supported = Set(UInt32(0xE0B0)...UInt32(0xE0BF))
            .union([0xE0D2, 0xE0D4])
        for value in UInt32(0xE0AF)...UInt32(0xE0D5) {
            #expect(
                (PowerlineSpriteGeometry.pattern(for: Unicode.Scalar(value)!) != nil)
                    == supported.contains(value),
                Comment(rawValue: "U+\(String(value, radix: 16, uppercase: true))")
            )
        }
    }

    @Test("Every supported scalar maps exhaustively in Ghostty order")
    func exhaustiveMapping() {
        let patterns: [PowerlinePattern] = [
            .rightHard, .rightThin, .leftHard, .leftThin,
            .rightHardRounded, .rightThinRounded, .leftHardRounded, .leftThinRounded,
            .upperRightHardDiagonal, .upperRightThinDiagonal,
            .lowerRightHardDiagonal, .lowerRightThinDiagonal,
            .lowerLeftHardDiagonal, .lowerLeftThinDiagonal,
            .upperLeftHardDiagonal, .upperLeftThinDiagonal,
        ]
        for (offset, pattern) in patterns.enumerated() {
            #expect(PowerlineSpriteGeometry.pattern(
                for: Unicode.Scalar(0xE0B0 + offset)!
            ) == pattern)
        }
        #expect(PowerlineSpriteGeometry.pattern(for: "\u{E0D2}") == .leftCap)
        #expect(PowerlineSpriteGeometry.pattern(for: "\u{E0D4}") == .rightCap)
    }
}

struct BranchDrawingSpriteDecodeTests {
    @Test("Sprite membership is exactly U+F5D0 through U+F60D as single scalars")
    func exactMembership() {
        for value in UInt32(0xF5CF)...UInt32(0xF60E) {
            #expect(
                (BranchDrawingSpriteGeometry.pattern(for: Unicode.Scalar(value)!) != nil)
                    == (0xF5D0...0xF60D).contains(value)
            )
        }
    }

    @Test("All 62 scalars map exhaustively in Ghostty order")
    func exhaustiveMapping() {
        for offset in 0..<30 {
            #expect(BranchDrawingSpriteGeometry.pattern(
                for: Unicode.Scalar(0xF5D0 + offset)!
            ) == .line(BranchLinePattern(rawValue: offset)!))
        }
        let masks: [BranchDirections] = [
            [], [.right], [.left], [.left, .right],
            [.down], [.up], [.up, .down], [.right, .down],
            [.left, .down], [.up, .right], [.up, .left],
            [.up, .right, .down], [.up, .down, .left],
            [.right, .down, .left], [.up, .right, .left],
            [.up, .right, .down, .left],
        ]
        for (pair, directions) in masks.enumerated() {
            for pairOffset in 0...1 {
                let offset = 30 + pair * 2 + pairOffset
                #expect(BranchDrawingSpriteGeometry.pattern(
                    for: Unicode.Scalar(0xF5D0 + offset)!
                ) == .node(.init(
                    directions: directions,
                    filled: pairOffset == 0
                )))
            }
        }
    }
}

struct LegacyComputingSpriteDecodeTests {
    @Test("Sprite membership is exactly Ghostty's 213 single-scalar set")
    func exactSupportedSet() {
        let supported = Set(UInt32(0x1FB00)...UInt32(0x1FBAF))
            .union(UInt32(0x1FBBD)...UInt32(0x1FBBF))
            .union(UInt32(0x1FBCE)...UInt32(0x1FBEF))
        for value in UInt32(0x1FAFF)...UInt32(0x1FBF0) {
            #expect(
                (LegacyComputingSpriteGeometry.pattern(for: Unicode.Scalar(value)!) != nil)
                    == supported.contains(value),
                Comment(rawValue: "U+\(String(value, radix: 16, uppercase: true))")
            )
        }
    }
}

struct LegacyComputingSupplementSpriteDecodeTests {
    @Test("Sprite membership exactly matches Ghostty's supplement ranges")
    func exactMembership() {
        let expected = Set(LegacyComputingSupplementSpriteGeometry.implementedRanges.flatMap { Array($0) })
        for value in UInt32(0x1CC00)...UInt32(0x1CEBF) {
            let actual = LegacyComputingSupplementSpriteGeometry.pattern(for: Unicode.Scalar(value)!) != nil
            #expect(actual == expected.contains(value))
        }
    }

    @Test("Every subgroup scalar decodes in exact Unicode order")
    func exhaustivePatternDecoding() {
        for offset in 0..<4 {
            #expect(pattern(0x1CC1B + UInt32(offset)) == .box(UInt8(offset)))
            #expect(pattern(0x1CE16 + UInt32(offset)) == .box(UInt8(offset + 4)))
        }
        for value in UInt32(1)...15 {
            #expect(pattern(0x1CC20 + value) == .separatedQuadrants(UInt8(value)))
        }
        for value in UInt32(1)...63 {
            #expect(pattern(0x1CE50 + value) == .separatedSextants(UInt8(value)))
        }
        for index in 0..<32 {
            #expect(pattern(0x1CE90 + UInt32(index)) == .sixteenth(index: index))
        }
        let circles: [LegacySupplementCirclePiece] = [
            piece(0,0,2,2,.topLeft), piece(1,0,2,2,.topLeft),
            piece(2,0,2,2,.topRight), piece(3,0,2,2,.topRight),
            piece(0,1,2,2,.topLeft), piece(0,0,1,1,.topLeft),
            piece(1,0,1,1,.topRight), piece(3,1,2,2,.topRight),
            piece(0,2,2,2,.bottomLeft), piece(0,1,1,1,.bottomLeft),
            piece(1,1,1,1,.bottomRight), piece(3,2,2,2,.bottomRight),
            piece(0,3,2,2,.bottomLeft), piece(1,3,2,2,.bottomLeft),
            piece(2,3,2,2,.bottomRight), piece(3,3,2,2,.bottomRight),
        ]
        for (index, circle) in circles.enumerated() {
            #expect(pattern(0x1CC30 + UInt32(index)) == .circlePieces([circle]))
        }
        #expect(pattern(0x1CE00) == .splitCircle(vertical: true))
        #expect(pattern(0x1CE01) == .splitCircle(vertical: false))
        #expect(pattern(0x1CE0B) == .circlePieces([
            piece(0,0,1,0.5,.topLeft), piece(0,0,1,0.5,.bottomLeft),
        ]))
        #expect(pattern(0x1CE0C) == .circlePieces([
            piece(1,0,1,0.5,.topRight), piece(1,0,1,0.5,.bottomRight),
        ]))
    }

    private func pattern(_ value: UInt32) -> LegacySupplementPattern? {
        LegacyComputingSupplementSpriteGeometry.pattern(for: Unicode.Scalar(value)!)
    }

    private func piece(
        _ x: Double, _ y: Double, _ width: Double, _ height: Double,
        _ corner: LegacySupplementArcCorner
    ) -> LegacySupplementCirclePiece {
        LegacySupplementCirclePiece(
            xCells: x, yCells: y, widthCells: width, heightCells: height, corner: corner
        )
    }
}

private func patternSignature(_ pattern: BoxDrawingPattern) -> String {
    switch pattern {
    case let .lines(lines):
        return [lines.up, lines.right, lines.down, lines.left].map {
            switch $0 {
            case .none: "n"
            case .light: "l"
            case .heavy: "h"
            case .double: "d"
            }
        }.joined()
    case let .dashed(axis, weight, count):
        return "\(axis == .horizontal ? "H" : "V")\(weight == .heavy ? "h" : "l")\(count)"
    case let .arc(corner):
        return switch corner {
        case .topLeft: "ATL"
        case .topRight: "ATR"
        case .bottomLeft: "ABL"
        case .bottomRight: "ABR"
        }
    case let .diagonal(diagonal):
        return switch diagonal {
        case .rising: "DR"
        case .falling: "DF"
        case .cross: "DX"
        }
    }
}
