// The one answer to "is this scalar a sprite, and what does it decode to".
//
// Holds the entry point over the eight families, the scalar floor below which no family
// claims anything, and the ink-reach vocabulary each family declares beside its decode.
// Per-family decode tables stay in that family's own `*SpriteGeometry.swift`, and nothing
// that needs cell metrics belongs here: this file answers membership only, so a consumer
// that has no metrics -- the frame planner -- can ask the same question the executor asks.

/// How far a sprite family's ink can travel out of the cell band its row occupies.
///
/// Membership does not imply containment, so every family states this beside its decode
/// rather than letting a consumer assume it. A family that deliberately overscans its cell
/// (the geometry contract permits one) declares `.beyondBand` and must be priced as if it
/// drew through the font, so the claim lives in the family's own diff.
public enum SpriteInkReach: Equatable, Sendable {
    /// Ink stays within the cell rectangle: cell-local rects, or a path clipped to the cell.
    case band
    /// Ink may leave the cell rectangle, so no consumer may assume a band-sized footprint.
    case beyondBand
}

/// One decoded sprite cell: which family claimed the scalar, and the pattern it decoded to.
///
/// The executor switches on this to draw; a consumer that needs only the cell's ink
/// footprint reads `inkReach`. Carrying the pattern is what keeps the executor from decoding
/// a second time after asking membership.
public enum SpriteDecode: Equatable, Sendable {
    case boxDrawing(BoxDrawingPattern)
    case blockElement(BlockElementPattern)
    case geometricShape(GeometricShapePattern)
    case braille(UInt8)
    case powerline(PowerlinePattern)
    case branchDrawing(BranchDrawingPattern)
    case legacyComputingSupplement(LegacySupplementPattern)
    case legacyComputing(LegacyComputingPattern)

    /// The declared ink reach of the family that claimed the scalar.
    public var inkReach: SpriteInkReach {
        switch self {
        case .boxDrawing: BoxDrawingSpriteGeometry.inkReach
        case .blockElement: BlockElementSpriteGeometry.inkReach
        case .geometricShape: GeometricShapeSpriteGeometry.inkReach
        case .braille: BrailleSpriteGeometry.inkReach
        case .powerline: PowerlineSpriteGeometry.inkReach
        case .branchDrawing: BranchDrawingSpriteGeometry.inkReach
        case .legacyComputingSupplement: LegacyComputingSupplementSpriteGeometry.inkReach
        case .legacyComputing: LegacyComputingSpriteGeometry.inkReach
        }
    }
}

/// Lowest scalar any sprite family claims, so a caller can reject an ordinary text cell
/// before entering the family switch at all. Almost every cell a terminal draws is ASCII or
/// Latin text, and for those the switch's eight `ClosedRange.contains` calls are pure
/// overhead -- they are also generic range-membership witnesses rather than inlined
/// comparisons, which made them measurable (~5% of the draw bracket; `research/18/F4`).
///
/// This duplicates where the families actually start, so it can drift out from under them:
/// a family claiming scalars below this floor would fall to the font path with no other
/// test failing. `SpriteVocabularyTests` ties the two together.
///
/// Computed rather than stored so the comparison inlines into callers in other targets
/// (docs/design/2026-07-29-cross-module-value-dispatch.md).
@inlinable
public var spriteClassificationMinimumScalar: UInt32 { 0x2500 }

/// Decodes `scalar` as a sprite cell, or answers nil when it must be drawn from the font.
///
/// The vocabulary's single membership answer: the executor draws what comes back, and a
/// consumer pricing a row's ink reads the same decode's `inkReach`, so two stages of the
/// renderer cannot disagree about what a cell is. Exact membership, not coarse range: a
/// scalar inside a family's span but outside its decode (an interior gap) answers nil,
/// exactly as the font path requires.
///
/// `@inlinable` for the floor rejection only -- the per-family decode stays out of line, so
/// an ordinary text cell pays one comparison at the call site.
@inlinable
public func spriteDecode(for scalar: Unicode.Scalar) -> SpriteDecode? {
    guard scalar.value >= spriteClassificationMinimumScalar else { return nil }
    return spriteDecodeAboveFloor(for: scalar)
}

/// The family switch behind `spriteDecode(for:)`, kept out of line so the inlined floor
/// rejection stays one comparison.
///
/// Every supported family occupies a scalar range disjoint from the others, so this routes
/// to the single family whose range can contain the scalar instead of testing all eight in
/// order.
@usableFromInline
func spriteDecodeAboveFloor(for scalar: Unicode.Scalar) -> SpriteDecode? {
    switch scalar.value {
    case BoxDrawingSpriteGeometry.coarseRange:
        BoxDrawingSpriteGeometry.pattern(for: scalar).map(SpriteDecode.boxDrawing)
    case BlockElementSpriteGeometry.coarseRange:
        BlockElementSpriteGeometry.pattern(for: scalar).map(SpriteDecode.blockElement)
    case GeometricShapeSpriteGeometry.coarseRange:
        GeometricShapeSpriteGeometry.pattern(for: scalar).map(SpriteDecode.geometricShape)
    case BrailleSpriteGeometry.coarseRange:
        BrailleSpriteGeometry.pattern(for: scalar).map(SpriteDecode.braille)
    case PowerlineSpriteGeometry.coarseRange:
        PowerlineSpriteGeometry.pattern(for: scalar).map(SpriteDecode.powerline)
    case BranchDrawingSpriteGeometry.coarseRange:
        BranchDrawingSpriteGeometry.pattern(for: scalar).map(SpriteDecode.branchDrawing)
    // Coarse ranges spanning each multi-range family; the family answers nil for the
    // interior gaps, which then fall through to the font path.
    case LegacyComputingSupplementSpriteGeometry.coarseRange:
        LegacyComputingSupplementSpriteGeometry.pattern(for: scalar)
            .map(SpriteDecode.legacyComputingSupplement)
    case LegacyComputingSpriteGeometry.coarseRange:
        LegacyComputingSpriteGeometry.pattern(for: scalar).map(SpriteDecode.legacyComputing)
    default:
        nil
    }
}
