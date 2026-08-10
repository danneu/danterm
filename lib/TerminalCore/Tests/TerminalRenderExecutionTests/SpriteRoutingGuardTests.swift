// Guard for `spriteClassificationMinimumScalar`, the scalar floor that lets an ordinary text
// cell skip sprite family routing entirely. The floor restates where the families actually
// start, so it can silently drift out from under them: a family added below it would stop
// being drawn as a sprite, and no other test would fail -- the family's own bitmap tests
// would keep passing on every scalar the font happens to have a glyph for. This ties the
// floor to the families' declared ranges. Behavior at and around the floor is owned by the
// per-family execution suites, which already render their full scalar sets.
import Testing

@testable import TerminalRenderExecution

struct SpriteRoutingGuardTests {
    /// Every family the executor routes to, paired with the range it claims. Named so a
    /// failure says which family broke the floor rather than only which number did.
    private static let familyRanges: [(name: String, range: ClosedRange<UInt32>)] = [
        ("Box Drawing", BoxDrawingSprite.coarseRange),
        ("Block Elements", BlockElementSprite.coarseRange),
        ("Geometric Shapes", GeometricShapeSprite.coarseRange),
        ("Braille", BrailleSprite.coarseRange),
        ("Powerline", PowerlineSprite.coarseRange),
        ("Branch Drawing", BranchDrawingSprite.coarseRange),
        ("Legacy Computing Supplement", LegacyComputingSupplementSprite.coarseRange),
        ("Legacy Computing", LegacyComputingSprite.coarseRange),
    ]

    @Test("The classification floor is exactly the lowest sprite family's range start")
    func floorMatchesLowestFamilyRangeStart() {
        // Intent: `spriteClassificationMinimumScalar` equals the minimum `coarseRange`
        //   lower bound across every routed family -- no family below it, and no slack
        //   above the lowest one.
        // Why it exists: the floor exists only to skip work, so a correct render never
        //   depends on its value. A new family claiming scalars below it would be dropped
        //   to the font path silently, and a floor left below the lowest family would
        //   quietly stop paying for itself. This is the only test that sees either.
        let declaredFloor = Self.familyRanges.map { $0.range.lowerBound }.min()
        #expect(declaredFloor == spriteClassificationMinimumScalar)
        for family in Self.familyRanges {
            #expect(
                family.range.lowerBound >= spriteClassificationMinimumScalar,
                "\(family.name) claims scalars below the classification floor"
            )
        }
    }
}
