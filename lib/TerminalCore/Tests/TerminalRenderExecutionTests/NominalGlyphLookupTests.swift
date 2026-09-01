// Proofs for `TerminalFace.nominalGlyph`, the live cmap lookup the run loop uses to route a
// private-use cell to the packaged symbols face. The lookup is a thin wrapper over
// `CTFontGetGlyphsForCharacters`, so its whole correctness claim is that it agrees with that
// function for every scalar, including the astral ones it must encode as a surrogate pair --
// these tests state that against a fresh call rather than a recorded golden. Bitmap proofs
// that a resolved glyph is drawn correctly live in `NerdFontSymbolsExecutionTests`.
import CoreGraphics
import CoreText
import Testing

@testable import TerminalRenderExecution

struct NominalGlyphLookupTests {
    /// The three private-use ranges `isPrivateUse` routes on, each paired with the stride the
    /// test walks it at: the BMP range is small enough to cover exhaustively, the two
    /// supplementary ones are sampled because each holds 65534 scalars.
    private static let privateUseRanges: [(range: ClosedRange<UInt32>, stride: UInt32)] = [
        (0xE000...0xF8FF, 1),
        (0xF0000...0xFFFFD, 977),
        (0x100000...0x10FFFD, 977),
    ]

    private static func sampledScalars() -> [UInt32] {
        var values: [UInt32] = []
        for (range, stride) in privateUseRanges {
            values.append(contentsOf: Swift.stride(
                from: range.lowerBound,
                through: range.upperBound,
                by: Int(stride)
            ))
            values.append(range.upperBound)
        }
        return values
    }

    /// The reference encoding: the UTF-16 units CoreText must see for a scalar, built through
    /// `String` so the expectation does not repeat the implementation's surrogate arithmetic.
    private static func liveGlyph(_ scalarValue: UInt32, in font: CTFont) -> CGGlyph? {
        guard let scalar = Unicode.Scalar(scalarValue) else { return nil }
        var characters = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        _ = CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
        return glyphs[0] == 0 ? nil : glyphs[0]
    }

    @Test("Every private-use scalar resolves to the face's own cmap glyph")
    func nominalGlyphAgreesWithCoreText() throws {
        // Intent: for both the packaged symbols face and an ordinary base face, `nominalGlyph`
        //   answers with the glyph CoreText maps that scalar to right now, across all three
        //   private-use ranges and both planes above the BMP.
        // Why it exists: the run loop routes a cell to the packaged face on this answer alone,
        //   and a wrong answer is invisible -- the cell just draws the wrong icon or silently
        //   falls back to shaping. The astral half is the real risk: a scalar above 0xFFFF has
        //   to reach CoreText as a surrogate pair, so a lookup that encodes it wrong finds
        //   nothing and every plane-15 icon disappears.
        let resource = try #require(NerdFontSymbolsResource.packaged)
        let faces = [
            TerminalFace(font: resource.face(pointSize: 13)),
            TerminalFontSet(baseName: "Menlo", baseSize: 13).face(bold: false, italic: false),
        ]
        for face in faces {
            for value in Self.sampledScalars() {
                #expect(
                    face.nominalGlyph(value) == Self.liveGlyph(value, in: face.font),
                    "scalar \(String(value, radix: 16))"
                )
            }
        }
    }

    @Test("The sampled scalars include mapped glyphs below and above the BMP")
    func sampledScalarsAreNotAllUnmapped() throws {
        // Intent: the agreement test walks scalars the packaged face really maps, on both sides
        //   of the surrogate boundary.
        // Why it exists: two `nil`s compare equal, so a sample that mapped nothing would let the
        //   agreement test pass without ever exercising a resolved glyph -- and the astral half
        //   is exactly the part the encoding can get wrong.
        let resource = try #require(NerdFontSymbolsResource.packaged)
        let face = TerminalFace(font: resource.face(pointSize: 13))
        let mapped = Self.sampledScalars().filter { face.nominalGlyph($0) != nil }
        #expect(mapped.contains { $0 <= 0xFFFF })
        #expect(mapped.contains { $0 > 0xFFFF })
    }

    @Test("A value that is not a scalar resolves to nil")
    func nonScalarValuesResolveToNil() {
        // Intent: a lone surrogate or an out-of-range value returns nil instead of being
        //   encoded into CoreText's buffer.
        // Why it exists: the caller passes a raw `UInt32`, and the fixed-size encoding path has
        //   no way to represent either value -- the guard is what keeps them out of it.
        let face = TerminalFontSet(baseName: "Menlo", baseSize: 13).face(bold: false, italic: false)
        #expect(face.nominalGlyph(0xD800) == nil)
        #expect(face.nominalGlyph(0xDFFF) == nil)
        #expect(face.nominalGlyph(0x11_0000) == nil)
    }
}
