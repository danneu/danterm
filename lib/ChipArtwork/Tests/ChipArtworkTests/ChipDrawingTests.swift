// Proves that a chip kind reaches pixels: that every kind paints something,
// that no two kinds paint alike, and that a kind with two palettes repaints
// when the appearance changes.
//
// This is the proof both clients rest on, which is why it lives in the artwork
// package rather than in either app's own suite: the gate runs it for the Mac
// and the iOS portability gate cross-compiles it for the phone.

import ChipArtwork
import CoreGraphics
import DanTermProtocol
import Foundation
import Testing

/// The pixels behind a drawn chip, so two renderings can be compared exactly.
private func pixels(of kind: ChipKind, appearance: ChipAppearance) throws -> Data {
    let image = try #require(kind.drawnImage(edge: 32, scale: 1, appearance: appearance))
    let data = try #require(image.dataProvider?.data)
    return Data(referencing: data)
}

@Test("each kind paints a distinct, non-empty chip")
func eachKindPaintsADistinctChip() throws {
    // Intent: every kind is told apart by its pixels, not only by the stored
    //   enum.
    // Why it exists: the chip's whole job is to be recognized at a glance, and
    //   every path from artwork to screen -- opcode decoding, the aspect fit,
    //   the palette -- sits between the kind and what is drawn. The generic
    //   agent chip raises the stakes: it has to differ from the terminal chip,
    //   or an unknown agent reads as a bare shell again.
    // Scenario: draw all four kinds at one size and appearance and compare the
    //   bitmaps. Spec-first.
    var renders: [ChipKind: Data] = [:]
    for kind in ChipKind.allCases {
        renders[kind] = try pixels(of: kind, appearance: .light)
    }

    #expect(Set(renders.values).count == ChipKind.allCases.count)
    #expect(renders.values.allSatisfy { $0.contains(where: { $0 != 0 }) })
}

@Test("codex is repainted for a dark appearance")
func codexIsRepaintedForADarkAppearance() throws {
    // Intent: a kind whose two palettes differ paints differently in each.
    // Why it exists: codex inverts (black on white, white on black) while
    //   claude keeps one orange in both, so codex is the kind that proves the
    //   appearance actually reaches the renderer.
    // Scenario: draw codex light and dark and compare the bitmaps. Spec-first.
    let light = try pixels(of: .codex, appearance: .light)
    let dark = try pixels(of: .codex, appearance: .dark)

    #expect(light != dark)
}
