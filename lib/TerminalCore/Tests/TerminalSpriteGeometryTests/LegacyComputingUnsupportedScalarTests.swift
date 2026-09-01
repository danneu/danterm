// What the legacy-computing family does with a scalar outside its vocabulary.
//
// Separate from LegacyComputingSpriteGeometryTests, which proves the supported
// vocabulary decodes and rasterizes correctly, because this file pins the opposite
// contract: `LegacyComputingPattern(scalar:)` is public and unguarded -- membership is
// answered by `LegacyComputingSpriteGeometry.pattern(for:)`, which a direct caller of the
// initializer never has to ask -- so both halves of the family, decoding and rasterizing,
// have to answer an out-of-vocabulary scalar with a defined value instead of trapping or
// disagreeing.
import Testing

@testable import TerminalSpriteGeometry

struct LegacyComputingUnsupportedScalarTests {
    @Test("Out-of-vocabulary scalars decode as unsupported and draw nothing")
    func unsupportedScalarsDecodeAndDrawConsistently() {
        // Intent: a scalar the family does not implement decodes to `.unsupported` and
        //   produces no pixel runs, at every cell size.
        // Why it exists: `decode`'s catch-all used to index the legacy-circle table at
        //   `value - 0x1FBE0` for every unmatched scalar, so a gap scalar (0x1FBB0)
        //   trapped on unsigned subtraction and anything at or above 0x1FBF0 trapped on
        //   array bounds -- while `runs` answered those same scalars with no ink. The
        //   two halves of the file have to agree.
        // Scenario: spec-first; no incident. `pattern(for:)` guards membership at the
        //   render path's construction site today, so this is the contract for any future
        //   direct caller of the public initializer.
        let outOfVocabulary: [UInt32] = [
            0x0041,   // Latin capital A, far below the family
            0x1FBB0,  // an interior gap between the implemented spans
            0x1FBCD,  // the gap immediately before the fractional-left pair
            0x1FBF0,  // one past the last legacy-circle scalar
            0x1FFFF,  // above the family entirely
        ]
        for value in outOfVocabulary {
            let pattern = LegacyComputingPattern(scalar: value)
            let context = Comment(rawValue: "U+\(String(value, radix: 16, uppercase: true))")
            #expect(pattern.topology == .unsupported, context)
            #expect(
                LegacyComputingSpriteGeometry.runs(
                    pattern: pattern, cellWidthPixels: 8, cellHeightPixels: 16
                ).isEmpty,
                context
            )
        }
    }
}
