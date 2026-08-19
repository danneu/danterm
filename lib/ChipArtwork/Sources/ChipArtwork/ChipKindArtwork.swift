// The one place a `ChipKind` is turned into artwork, and the one way a client
// gets a chip it can hand to its own image type.
//
// Split out from ChipArtwork.swift and ChipRenderer.swift on purpose: those two
// must stay compilable against CoreGraphics alone, and naming `ChipKind` there
// would pull DanTermProtocol into a file the render check builds loose.
//
// Nothing here knows about AppKit or UIKit. A client wraps the CGImage in
// NSImage or UIImage itself; the drawing behind it is the same on both.

import CoreGraphics
import DanTermProtocol

extension ChipKind {
    /// The artwork this kind is drawn with. The collapse from an agent to a
    /// kind already happened on the server, so this is the whole mapping.
    public var artwork: ChipDefinition {
        switch self {
        case .terminal: return ChipArtwork.terminal
        case .claude: return ChipArtwork.claude
        case .codex: return ChipArtwork.codex
        case .agent: return ChipArtwork.agent
        }
    }

    /// The chip rasterized in its own brand colors, for a client that wants an
    /// image rather than a draw call -- a table cell, a menu item, a row.
    ///
    /// `edge` is the chip's edge length in points and `scale` the display's
    /// point-to-pixel ratio, so a caller passes what its screen reports and
    /// gets a bitmap that is sharp there. Returns nil only when the bitmap
    /// context cannot be created, which a zero or negative size guarantees.
    public func drawnImage(edge: CGFloat, scale: CGFloat, appearance: ChipAppearance) -> CGImage? {
        let pixels = Int((edge * scale).rounded())
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ChipRenderer.draw(
            artwork,
            in: context,
            rect: CGRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)),
            appearance: appearance,
            flipped: false
        )
        return context.makeImage()
    }
}
