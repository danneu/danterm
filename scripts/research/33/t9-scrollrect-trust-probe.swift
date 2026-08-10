// research/33 T9 view half: is `scrollRect(_:by:)` bit-preserving on a
// layer-backed view on this macOS? D7 refuses to trust it until proven live.
//
// The probe draws eight distinct color bands into a layer-backed, flipped view
// (matching SwiftTerminalSessionView's configuration: wantsLayer, flipped,
// layer background color), lets AppKit commit the backing store, then calls
// `scroll(_:by:)` (scrollRect:by:'s Swift name) WITHOUT allowing any redraw
// and reads the layer back via CALayer.render(in:) -- the layer's contents is
// the same backing store the WindowServer composites, and CGWindowListCreateImage
// is obsoleted in macOS 15, so this is the readback channel available to an
// unattended probe. The verdict: TRANSLATED (bits moved by exactly one band),
// UNCHANGED (the scroll was a no-op), or OTHER (anything else -- the tearing
// case). It also reports whether the scroll dirtied the view and whether
// draw(_:) ran, because a silent invalidation is exactly the failure mode that
// would turn a trusted translation into stale rows.
//
// Run from a logged-in GUI session: xcrun swift t9-scrollrect-trust-probe.swift
import AppKit

let bandCount = 8
let bandHeight: CGFloat = 40
let viewSide: CGFloat = 320

let baseBandColors: [NSColor] = [
    NSColor.red, NSColor.green, NSColor.blue, NSColor.yellow,
    NSColor.cyan, NSColor.magenta, NSColor.orange, NSColor.purple,
]
let bandColors: [NSColor] = baseBandColors.map { $0.usingColorSpace(.sRGB)! }

final class BandView: NSView {
    var drawCount = 0
    var drawnRects: [NSRect] = []
    /// Once set, any further draw paints solid black instead of the bands, so
    /// a post-scroll redraw cannot silently repaint the pre-scroll pattern and
    /// masquerade as "the scroll was a no-op".
    var paintSentinel = false
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        drawnRects.append(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if paintSentinel {
            context.setFillColor(NSColor.black.cgColor)
            context.fill(dirtyRect)
            return
        }
        for band in 0..<bandCount {
            context.setFillColor(bandColors[band].cgColor)
            context.fill(CGRect(
                x: 0,
                y: CGFloat(band) * bandHeight,
                width: bounds.width,
                height: bandHeight
            ))
        }
    }
}

func pump(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
}

/// Samples the center pixel of each band row and maps it to a band index,
/// nil for anything that is not close to one of the eight colors.
func classifyBands(in image: CGImage, viewFrameInImage: CGRect) -> [Int?] {
    let width = image.width
    let height = image.height
    guard let data = image.dataProvider?.data as Data? else {
        return Array(repeating: nil, count: bandCount)
    }
    let bytesPerRow = image.bytesPerRow
    let bytesPerPixel = image.bitsPerPixel / 8
    let scaleX = viewFrameInImage.width / viewSide
    let scaleY = viewFrameInImage.height / viewSide
    var result: [Int?] = []
    for band in 0..<bandCount {
        // Center of the band in view points, then into image pixels. The image
        // is top-left origin, matching the flipped view.
        let px = Int(viewFrameInImage.origin.x + viewSide / 2 * scaleX)
        let py = Int(
            viewFrameInImage.origin.y + (CGFloat(band) * bandHeight + bandHeight / 2) * scaleY
        )
        guard px >= 0, px < width, py >= 0, py < height else {
            result.append(nil)
            continue
        }
        let offset = py * bytesPerRow + px * bytesPerPixel
        // Assume 8-bit channels; alpha position varies, so match on the best
        // candidate over both BGRA and RGBA readings.
        let b0 = CGFloat(data[offset]) / 255
        let b1 = CGFloat(data[offset + 1]) / 255
        let b2 = CGFloat(data[offset + 2]) / 255
        func nearestBand(r: CGFloat, g: CGFloat, b: CGFloat) -> (Int, CGFloat) {
            var best = (index: -1, distance: CGFloat.infinity)
            for (index, color) in bandColors.enumerated() {
                let dr = color.redComponent - r
                let dg = color.greenComponent - g
                let db = color.blueComponent - b
                let distance = dr * dr + dg * dg + db * db
                if distance < best.distance { best = (index, distance) }
            }
            return best
        }
        let bgra = nearestBand(r: b2, g: b1, b: b0)
        let rgba = nearestBand(r: b0, g: b1, b: b2)
        let best = bgra.1 <= rgba.1 ? bgra : rgba
        result.append(best.1 < 0.05 ? best.0 : nil)
    }
    return result
}

func renderLayer(_ view: NSView) -> CGImage? {
    guard let layer = view.layer else { return nil }
    let scale = view.window?.backingScaleFactor ?? 2
    let pixelWidth = Int(viewSide * scale)
    let pixelHeight = Int(viewSide * scale)
    guard let context = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }
    context.scaleBy(x: scale, y: scale)
    // CALayer.render(in:) draws with the layer's own geometry (top-left origin
    // for a flipped AppKit view's layer); flip the CG context to match.
    context.translateBy(x: 0, y: viewSide)
    context.scaleBy(x: 1, y: -1)
    layer.render(in: context)
    return context.makeImage()
}

func describe(_ bands: [Int?]) -> String {
    bands.map { $0.map(String.init) ?? "." }.joined(separator: ",")
}

/// Compares an after-classification against the before, for a scroll of
/// `deltaBands` (positive = content moved toward higher band rows).
func verdict(before: [Int?], after: [Int?], deltaBands: Int) -> String {
    guard before.compactMap({ $0 }).count == bandCount else { return "CHANNEL-UNUSABLE" }
    var translated = true
    var unchanged = true
    for row in 0..<bandCount {
        let source = row - deltaBands
        let expectedTranslated = source >= 0 && source < bandCount ? before[source] : nil
        if after[row] != expectedTranslated && expectedTranslated != nil { translated = false }
        if after[row] != before[row] { unchanged = false }
    }
    if translated && !unchanged { return "TRANSLATED" }
    if unchanged { return "UNCHANGED" }
    return "OTHER"
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let window = NSWindow(
    contentRect: NSRect(x: 80, y: 120, width: viewSide, height: viewSide),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
window.isReleasedWhenClosed = false
let view = BandView(frame: NSRect(x: 0, y: 0, width: viewSide, height: viewSide))
view.wantsLayer = true
view.layer?.backgroundColor = NSColor.black.cgColor
window.contentView = view
window.orderFrontRegardless()

view.needsDisplay = true
window.displayIfNeeded()
pump(0.3)

print("backingScaleFactor: \(window.backingScaleFactor)")
print("layerContentsRedrawPolicy: \(view.layerContentsRedrawPolicy.rawValue)")
print("layer.contents type: \(view.layer?.contents.map { String(describing: type(of: $0)) } ?? "nil")")

let beforeRender = renderLayer(view).map {
    classifyBands(in: $0, viewFrameInImage: CGRect(
        x: 0, y: 0, width: CGFloat($0.width), height: CGFloat($0.height)
    ))
}
print("before  render:  \(beforeRender.map(describe) ?? "render-failed")")

// The scroll under test: content moves up one band (delta = -1 band), the way
// a terminal scroll vacates the bottom row. In this flipped view that is a
// negative y offset in points.
view.paintSentinel = true
let drawsBefore = view.drawCount
view.scroll(view.bounds, by: NSSize(width: 0, height: -bandHeight))
let dirtyAfterScroll = view.needsDisplay
// Pump without displayIfNeeded so an AppKit-side invalidation would surface as
// a draw here rather than being hidden by our own display pass.
pump(0.3)
let drawsAfter = view.drawCount

print("scrollRect dirtied view: \(dirtyAfterScroll)")
print("draws during scroll+pump: \(drawsAfter - drawsBefore)")
print("sentinel draw rects: \(view.drawnRects.suffix(drawsAfter - drawsBefore))")

let afterRender = renderLayer(view).map {
    classifyBands(in: $0, viewFrameInImage: CGRect(
        x: 0, y: 0, width: CGFloat($0.width), height: CGFloat($0.height)
    ))
}
print("after   render:  \(afterRender.map(describe) ?? "render-failed")")

if let before = beforeRender, let after = afterRender {
    print("VERDICT render:  \(verdict(before: before, after: after, deltaBands: -1))")
} else {
    print("VERDICT render:  CHANNEL-UNUSABLE")
}

window.orderOut(nil)
exit(0)
