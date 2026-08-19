// Field-independence proof for the 8-byte cell word the logical-line arena stores.
//
// `CellWord` is the one type that knows the word's bit layout, so an encoder and a decoder that
// share a mis-transcribed shift agree with each other and hide the mistake. These tests break
// that tie by driving every field to the top of its range at once: if two fields overlap, one
// of them comes back wrong.
//
// What belongs here: encode-then-decode round trips over the word's own fields. What does not:
// the record header's layout, the arena's operations, or any assertion about which raw bit a
// field occupies -- the store never serializes a word, so a bit position is private structure.

import Testing

@testable import TerminalCore

@Suite("Cell word encoding")
struct TerminalCellWordTests {
    private static let allKinds: [TerminalCellKind] = [
        .padding, .narrow, .wideHead, .wideTail, .spacerHead,
    ]

    /// The widest scalar Unicode defines, which the layout claims fits inline with no spill.
    private static let topScalar = Unicode.Scalar(0x10_FFFF)!

    /// The largest spill index the payload field can express: all 21 of its bits set.
    private static let topSpillIndex = 0x1F_FFFF

    @Test("A cell word carrying an inline scalar decodes every field back unchanged")
    func inlineScalarRoundTrips() {
        for kind in Self.allKinds {
            let word = Terminal.CellWord(
                kind: kind,
                styleId: Terminal.StyleId.max,
                scalar: Self.topScalar
            )
            #expect(word.kind == kind)
            #expect(word.styleId == Terminal.StyleId.max)
            #expect(word.isSpilled == false)
            #expect(word.inlineScalar == Self.topScalar)
        }
    }

    @Test("A cell word carrying a spill index decodes every field back unchanged")
    func spillIndexRoundTrips() {
        for kind in Self.allKinds {
            let word = Terminal.CellWord(
                kind: kind,
                styleId: Terminal.StyleId.max,
                spillIndex: Self.topSpillIndex
            )
            #expect(word.kind == kind)
            #expect(word.styleId == Terminal.StyleId.max)
            #expect(word.isSpilled)
            #expect(word.spillIndex == Self.topSpillIndex)
            #expect(word.inlineScalar == nil)
        }
    }

    @Test("A cell word with no payload decodes as empty without disturbing its other fields")
    func emptyPayloadRoundTrips() {
        for kind in Self.allKinds {
            let word = Terminal.CellWord(kind: kind, styleId: Terminal.StyleId.max)
            #expect(word.kind == kind)
            #expect(word.styleId == Terminal.StyleId.max)
            #expect(word.isSpilled == false)
            #expect(word.inlineScalar == nil)
        }
    }

    // A word is stored and re-read as a bare `UInt64`, so the raw form has to be lossless in
    // both directions or a read walk decodes a different cell than the write path encoded.
    @Test("Wrapping a stored raw word reproduces the word that was written")
    func rawWordRoundTrips() {
        let word = Terminal.CellWord(
            kind: .wideHead,
            styleId: Terminal.StyleId.max,
            scalar: Self.topScalar
        )
        let reread = Terminal.CellWord(raw: word.raw)
        #expect(reread.kind == word.kind)
        #expect(reread.styleId == word.styleId)
        #expect(reread.isSpilled == word.isSpilled)
        #expect(reread.inlineScalar == word.inlineScalar)
    }
}
