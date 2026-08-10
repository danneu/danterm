// Proofs for the gate that decides whether a styled face may draw its mapped glyphs with
// `setFont` + `showGlyphs` instead of `CTFontDrawGlyphs`. The wrapper is documented to apply
// the CTFont's size and matrix to the context and not restore them (`CTFont.h`,
// `CTFontDrawGlyphs`), so bypassing it is only sound for a face that has no matrix to
// apply. That condition is the whole safety argument for the fast path, and it is
// invisible in a bitmap for the fonts
// DanTerm actually ships -- every face of the monospaced system font is a real designed face
// with an identity matrix -- which is exactly why it needs stating here rather than being
// left to the rendering suites. The pixel-level guarantees stay where they already are:
// `TextExecutionTests.fontTraitsPreserveGridGeometry` pins that each face renders distinctly,
// and `MultiStyleFrameTests` pins whole-frame parity across faces and colours.
import CoreGraphics
import CoreText
import Testing

@testable import TerminalRenderExecution

struct DirectGlyphDrawTests {
    private static let styles: [(bold: Bool, italic: Bool)] = [
        (false, false),
        (true, false),
        (false, true),
        (true, true),
    ]

    @Test("Every face of the shipped font takes the direct path, with its own graphics font")
    func shippedFacesQualify() throws {
        // Intent: all four styled faces expose a direct-draw `CGFont`, that font is the one
        //   CoreText derives from the face, and the four are distinct from each other.
        // Why it exists: the fast path's whole benefit depends on the common case taking it,
        //   so a gate that silently rejects every face would leave the code dead and the
        //   rendering suites green. Distinctness is the other half: one shared `CGFont` would
        //   render bold and italic text in the regular face, which no unit test of the table
        //   would notice.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        var names: Set<String> = []
        for style in Self.styles {
            let face = metrics.fonts.face(bold: style.bold, italic: style.italic)
            let direct = try #require(
                face.directDrawFont,
                "bold=\(style.bold) italic=\(style.italic) was refused the direct path"
            )
            let expected = CTFontCopyGraphicsFont(face.font, nil)
            #expect(direct.postScriptName == expected.postScriptName)
            #expect(face.pointSize == CTFontGetSize(face.font))
            names.insert((direct.postScriptName as String?) ?? "")
        }
        #expect(names.count == Self.styles.count, "faces shared a graphics font: \(names)")
    }

    @Test("A face whose CTFont carries a matrix is refused the direct path")
    func matrixBearingFaceIsRefused() throws {
        // Intent: a face built from a CTFont with a non-identity matrix reports no
        //   direct-draw font, so the run loop keeps sending it through `CTFontDrawGlyphs`.
        // Why it exists: `CTFontDrawGlyphs` applies that matrix to the context's text matrix
        //   and the bypass does not, so taking the fast path for such a face would drop the
        //   transform -- for a synthetic oblique, that means italic text rendering upright.
        //   No font DanTerm ships hits this (every face of the monospaced system font is a
        //   real designed face with an identity matrix), so the bitmap suites cannot cover
        //   it and the gate would look untested while being the reason the bypass is legal.
        // Scenario: spec-first -- a user font family with no true italic, where CoreText
        //   synthesizes the slant with a matrix instead of substituting a face.
        var skew = CGAffineTransform(a: 1, b: 0, c: 0.25, d: 1, tx: 0, ty: 0)
        let oblique = CTFontCreateWithName("Menlo" as CFString, 13, &skew)
        #expect(CTFontGetMatrix(oblique) != .identity, "the probe font carries no matrix")
        #expect(TerminalFace(font: oblique).directDrawFont == nil)

        // The control: the same family and size without a matrix does take the path, so the
        // refusal above is attributable to the matrix and not to the family.
        let upright = CTFontCreateWithName("Menlo" as CFString, 13, nil)
        #expect(TerminalFace(font: upright).directDrawFont != nil)
    }
}
