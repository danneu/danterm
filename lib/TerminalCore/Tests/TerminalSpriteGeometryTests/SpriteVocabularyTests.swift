// The properties that must hold across all eight sprite families at once.
//
// Per-family decoding is proved in SpriteDecodeTests; this file pins what the shared entry
// point promises whoever reads it: it decodes exactly what the families decode, it reports
// the reach each family declares, and no family hides below the classification floor. A
// family that breaks one of the three fails here -- nothing else sees it.
import Testing

@testable import TerminalSpriteGeometry

struct SpriteVocabularyTests {
    /// Every family, paired with the range it claims and the decode it answers with. Named so
    /// a failure says which family broke the property rather than only which scalar did.
    private struct Family: Sendable {
        let name: String
        let range: ClosedRange<UInt32>
        let inkReach: SpriteInkReach
        let decodes: @Sendable (Unicode.Scalar) -> Bool
    }

    private static let families: [Family] = [
        Family(
            name: "Box Drawing", range: BoxDrawingSpriteGeometry.coarseRange,
            inkReach: BoxDrawingSpriteGeometry.inkReach,
            decodes: { BoxDrawingSpriteGeometry.pattern(for: $0) != nil }
        ),
        Family(
            name: "Block Elements", range: BlockElementSpriteGeometry.coarseRange,
            inkReach: BlockElementSpriteGeometry.inkReach,
            decodes: { BlockElementSpriteGeometry.pattern(for: $0) != nil }
        ),
        Family(
            name: "Geometric Shapes", range: GeometricShapeSpriteGeometry.coarseRange,
            inkReach: GeometricShapeSpriteGeometry.inkReach,
            decodes: { GeometricShapeSpriteGeometry.pattern(for: $0) != nil }
        ),
        Family(
            name: "Braille", range: BrailleSpriteGeometry.coarseRange,
            inkReach: BrailleSpriteGeometry.inkReach,
            decodes: { BrailleSpriteGeometry.pattern(for: $0) != nil }
        ),
        Family(
            name: "Powerline", range: PowerlineSpriteGeometry.coarseRange,
            inkReach: PowerlineSpriteGeometry.inkReach,
            decodes: { PowerlineSpriteGeometry.pattern(for: $0) != nil }
        ),
        Family(
            name: "Branch Drawing", range: BranchDrawingSpriteGeometry.coarseRange,
            inkReach: BranchDrawingSpriteGeometry.inkReach,
            decodes: { BranchDrawingSpriteGeometry.pattern(for: $0) != nil }
        ),
        Family(
            name: "Legacy Computing Supplement",
            range: LegacyComputingSupplementSpriteGeometry.coarseRange,
            inkReach: LegacyComputingSupplementSpriteGeometry.inkReach,
            decodes: { LegacyComputingSupplementSpriteGeometry.pattern(for: $0) != nil }
        ),
        Family(
            name: "Legacy Computing", range: LegacyComputingSpriteGeometry.coarseRange,
            inkReach: LegacyComputingSpriteGeometry.inkReach,
            decodes: { LegacyComputingSpriteGeometry.pattern(for: $0) != nil }
        ),
    ]

    @Test("The shared entry decodes a scalar exactly when its family does")
    func entryAgreesWithEveryFamily() {
        // Intent: over every family's coarse range plus one scalar on each side,
        //   `spriteDecode(for:)` answers non-nil exactly where that family's `pattern(for:)`
        //   does -- interior gaps of a sparse range included.
        // Why it exists: this entry point is the renderer's single membership answer. A
        //   family the entry forgets to route, or routes with the wrong range, would be
        //   drawn from the font while its own decode tests keep passing.
        for family in Self.families {
            for value in (family.range.lowerBound - 1)...(family.range.upperBound + 1) {
                guard let scalar = Unicode.Scalar(value) else { continue }
                // Any family, not only this one: the ranges abut, so a scalar one past this
                // family's end can legitimately be the next family's first member.
                let expected = Self.families.contains {
                    $0.range.contains(value) && $0.decodes(scalar)
                }
                #expect(
                    (spriteDecode(for: scalar) != nil) == expected,
                    Comment(rawValue: "\(family.name) U+\(String(value, radix: 16, uppercase: true))")
                )
            }
        }
    }

    @Test("A decoded cell reports its own family's declared ink reach")
    func decodeCarriesTheFamilyReach() {
        // Intent: the reach `SpriteDecode.inkReach` reports for a scalar is the reach the
        //   family that claimed it declares, and every family declares the band today.
        // Why it exists: a consumer pricing a row's ink repaints exactly the declared reach.
        //   A family whose geometry leaves its cell must say so here, or an incremental
        //   redraw would leave its overspill on screen.
        for family in Self.families {
            #expect(
                family.inkReach == .band,
                Comment(rawValue: "\(family.name) no longer declares the band")
            )
            for value in family.range where Unicode.Scalar(value) != nil {
                let scalar = Unicode.Scalar(value)!
                guard let decode = spriteDecode(for: scalar) else { continue }
                #expect(
                    decode.inkReach == family.inkReach,
                    Comment(rawValue: "\(family.name) U+\(String(value, radix: 16, uppercase: true))")
                )
            }
        }
    }

    @Test("The classification floor is exactly the lowest sprite family's range start")
    func floorMatchesLowestFamilyRangeStart() {
        // Intent: `spriteClassificationMinimumScalar` equals the minimum `coarseRange`
        //   lower bound across every family -- no family below it, and no slack above the
        //   lowest one.
        // Why it exists: the floor exists only to skip work, so a correct render never
        //   depends on its value. A new family claiming scalars below it would be dropped to
        //   the font path silently, and a floor left below the lowest family would quietly
        //   stop paying for itself. This is the only test that sees either.
        let declaredFloor = Self.families.map { $0.range.lowerBound }.min()
        #expect(declaredFloor == spriteClassificationMinimumScalar)
        for family in Self.families {
            #expect(
                family.range.lowerBound >= spriteClassificationMinimumScalar,
                Comment(rawValue: "\(family.name) claims scalars below the classification floor")
            )
        }
    }
}
