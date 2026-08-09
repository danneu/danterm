// Research doc 33, task T14: measure the printable-ASCII ink envelope per styled face.
//
// F6 measured the regular face only. T14's derivation unions the four styled faces the
// glyph batch actually submits from (regular, bold, italic, bold-italic -- the only
// unclipped draw path; symbols and CTLine fallback cells clip to their cell in
// `drawTextCell`, and every sprite family clips or is geometry-contained). This probe
// reports, per face and scale:
//   - whether every glyph of 0x20...0x7E maps (a zero glyph would reroute a cell to the
//     clipped fallback, which the envelope's completeness guard must know about),
//   - the union ink bounding box over those glyphs relative to the baseline,
//   - the box converted to cell-relative pixel offsets using the same quantization as
//     `TerminalRenderMetrics` (ceil of scaled advance/line height/ascent),
// and then the unioned envelope T14 stores: the ink-top margin below the cell top
// (floored, conservative) and the ink-bottom overshoot past the cell bottom (ceiled,
// conservative). Run with `swift scripts/research/33/t14-ink-envelope-probe.swift
// [fontName] [pointSize]`; defaults are the shipped system monospace at 13 pt.

import AppKit
import CoreText

let arguments = CommandLine.arguments
let fontSize: CGFloat = arguments.count > 2 ? CGFloat(Double(arguments[2]) ?? 13) : 13
let baseName: String = arguments.count > 1
    ? arguments[1]
    : NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular).fontName

/// Mirrors `TerminalRenderMetrics`'s quantization: scaled point value, rounded up.
func quantizedPixelCount(_ pointValue: CGFloat, scale: CGFloat) -> Int? {
    guard pointValue.isFinite, pointValue > 0 else { return nil }
    let scaled = pointValue * scale
    let rounded = scaled.rounded(.up)
    guard rounded.isFinite, rounded > 0 else { return nil }
    return Int(rounded)
}

func styled(_ font: CTFont, _ traits: CTFontSymbolicTraits) -> CTFont {
    CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traits, [.boldTrait, .italicTrait]) ?? font
}

let regular = CTFontCreateWithName(baseName as CFString, fontSize, nil)
let faces: [(String, CTFont)] = [
    ("regular", regular),
    ("bold", styled(regular, .boldTrait)),
    ("italic", styled(regular, .italicTrait)),
    ("boldItalic", styled(regular, [.boldTrait, .italicTrait])),
]

var character = UniChar(0x004D)
var mGlyph = CGGlyph()
guard CTFontGetGlyphsForCharacters(regular, &character, &mGlyph, 1) else {
    fatalError("\(baseName) has no M glyph; TerminalRenderMetrics would refuse it")
}
let ascent = CTFontGetAscent(regular)
let descent = CTFontGetDescent(regular)
let leading = CTFontGetLeading(regular)
let lineHeight = ascent + descent + leading

print("face set: \(baseName) @ \(fontSize) pt")
print("ascent \(ascent), descent \(descent), leading \(leading), line height \(lineHeight)")
print("")

struct FaceInk {
    let name: String
    let complete: Bool
    /// Ink box in font space (y up, origin at baseline), union over 0x20...0x7E.
    let maxAboveBaseline: CGFloat
    let maxBelowBaseline: CGFloat
}

var faceInks: [FaceInk] = []
for (name, font) in faces {
    let characters = (0x20...0x7E).map { UniChar($0) }
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    var mutableCharacters = characters
    _ = CTFontGetGlyphsForCharacters(font, &mutableCharacters, &glyphs, characters.count)
    let complete = glyphs.allSatisfy { $0 != 0 }
    var rects = [CGRect](repeating: .zero, count: glyphs.count)
    var mutableGlyphs = glyphs
    let union = CTFontGetBoundingRectsForGlyphs(
        font, .horizontal, &mutableGlyphs, &rects, glyphs.count
    )
    // Union manually as well, ignoring zero glyphs, so an unmapped scalar cannot
    // smuggle a .notdef box into the envelope.
    var above = -CGFloat.infinity
    var below = -CGFloat.infinity
    for (glyph, rect) in zip(glyphs, rects) where glyph != 0 && rect.isEmpty == false {
        above = max(above, rect.maxY)
        below = max(below, -rect.minY)
    }
    faceInks.append(FaceInk(
        name: name, complete: complete, maxAboveBaseline: above, maxBelowBaseline: below
    ))
    print("\(name): complete=\(complete), ink above baseline \(above), below baseline \(below)")
    print("    (CTFont union box for reference: \(union))")
}
print("")

for scale: CGFloat in [1, 2] {
    guard let cellHeightPixels = quantizedPixelCount(lineHeight, scale: scale),
          let baselinePixels = quantizedPixelCount(ascent, scale: scale)
    else { continue }
    print("scale \(scale)x: cell height \(cellHeightPixels) px, baseline \(baselinePixels) px")
    var topMarginPixels = Int.max
    var bottomOvershootPixels = Int.min
    for ink in faceInks {
        // Highest ink sits `baseline - above` below the cell top; lowest ink sits
        // `baseline + below - cellHeight` below the cell bottom (positive = overshoot).
        let topMargin = CGFloat(baselinePixels) - ink.maxAboveBaseline * scale
        let bottomOvershoot = ink.maxBelowBaseline * scale
            - CGFloat(cellHeightPixels - baselinePixels)
        print(String(format: "  %-11@ top margin %+.2f px, bottom overshoot %+.2f px",
                     ink.name as NSString, topMargin, bottomOvershoot))
        topMarginPixels = min(topMarginPixels, Int(topMargin.rounded(.down)))
        bottomOvershootPixels = max(bottomOvershootPixels, Int(bottomOvershoot.rounded(.up)))
    }
    let allComplete = faceInks.allSatisfy(\.complete)
    print("  union envelope: top margin \(topMarginPixels) px (floored), "
        + "bottom overshoot \(bottomOvershootPixels) px (ceiled), "
        + "ascii tables complete: \(allComplete)")
    print("")
}
