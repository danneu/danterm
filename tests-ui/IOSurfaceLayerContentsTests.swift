// Real-AppKit pins for the owned-pane-surface route (research/33/T25): the
// IOSurface layer-contents premises the headless harness cannot model. Pin
// one: with implicit actions disabled, a contents swap attaches no animation,
// so no presentation layer keeps a released surface alive. Pin two is the
// route's viability gate: the render server takes a use count on an attached
// surface, drops it after the detaching transaction commits, and once the
// surface reports free it stays free -- the premise that makes
// IOSurfaceIsInUse a safe write-eligibility check for a contents swapchain.
// If pin two goes red, the owned-surface route stops: a depth or age
// heuristic is not a substitute, because neither bounds when a stalled render
// server stops reading a surface.
//
// Pin three is the presentation contract (I5): the pane view's layer
// configuration puts the surface's first memory row at the visual top, at one
// surface pixel per backing pixel, with the theme background showing in the
// letterbox strip and the surface's bytes reaching the output unconverted.
import Cocoa
import IOSurface
import QuartzCore

@MainActor
func ioSurfaceLayerContentsTests() {
    print("IOSurfaceLayerContents")

    // Intent: with a "contents" entry of NSNull in the layer's actions
    // dictionary, repeated contents swaps attach no implicit animation, and
    // the swapped-out surface's use count drops.
    // Why it exists: an implicit crossfade would hold the released surface in
    // a presentation layer past the swap, so the swapchain's "detached means
    // releasable" reasoning would be wrong by one animation duration.
    // Scenario: two filled surfaces alternate as the contents of a composited
    // layer; after every swap the layer carries no "contents" animation and
    // the replaced surface goes free.
    uiTest("disabled actions: contents swaps attach no animation and release the old surface") {
        let layer = CALayer()
        layer.actions = ["contents": NSNull()]
        let front = try makeProbeSurface()
        let back = try makeProbeSurface()
        fill(front, byte: 0xFF)
        fill(back, byte: 0x40)
        let window = makeProbeWindow(hosting: layer)
        defer { window.orderOut(nil) }

        layer.contents = front
        try uiExpect(
            flushAndPump(deadline: 5.0) { front.isInUse },
            "render server never acquired the attached surface; is the probe window composited?")

        var attached = front
        var released = back
        for _ in 0 ..< 4 {
            swap(&attached, &released)
            layer.contents = attached
            try uiExpect(
                layer.animation(forKey: "contents") == nil,
                "implicit contents animation attached despite the disabling actions dictionary")
            CATransaction.flush()
            try uiExpect(
                layer.animation(forKey: "contents") == nil,
                "contents animation appeared at commit despite the disabling actions dictionary")
            try uiExpect(
                flushAndPump(deadline: 5.0) { !released.isInUse },
                "swapped-out surface still in use after the swap committed")
        }
    }

    // Intent: a surface detached by a committed transaction and never
    // reattached goes free once later frames present, and from the moment
    // IOSurfaceIsInUse reports it free it stays free -- through a second of
    // continued swaps and across a rewrite of its pixels.
    // Why it exists: this is the owned-surface route's viability gate. The
    // swapchain writes a buffer only when it is detached and reported free;
    // if the render server could re-acquire such a surface, that write could
    // tear the displayed frame, and no invariant of the route survives. The
    // gate demands monotonicity, not promptness: the render server holds a
    // detached surface until subsequent presentations flush it from the
    // pipeline, so the wait for freedom keeps presenting frames, exactly as
    // a live swapchain does.
    // Scenario: surface A displays, then B replaces it; B/C swaps keep
    // committing until A reports free, and from then on no swap and no
    // rewrite of A may ever see it in use again.
    uiTest("viability gate: a detached surface reported free stays free") {
        let layer = CALayer()
        layer.actions = ["contents": NSNull()]
        let candidate = try makeProbeSurface()
        let second = try makeProbeSurface()
        let third = try makeProbeSurface()
        fill(candidate, byte: 0xC0)
        fill(second, byte: 0x80)
        fill(third, byte: 0x20)
        let window = makeProbeWindow(hosting: layer)
        defer { window.orderOut(nil) }

        layer.contents = candidate
        try uiExpect(
            flushAndPump(deadline: 5.0) { candidate.isInUse },
            "render server never acquired the attached surface; is the probe window composited?")

        // Detach; candidate is never reattached below. Freeing is driven by
        // later presentations, so keep swapping the other two surfaces while
        // waiting for it.
        var attached = second
        var idle = third
        let freeDeadline = Date().addingTimeInterval(5.0)
        while candidate.isInUse && Date() < freeDeadline {
            swap(&attached, &idle)
            layer.contents = attached
            CATransaction.flush()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        try uiExpect(
            !candidate.isInUse,
            "detached surface never reported free while later frames kept presenting")

        let end = Date().addingTimeInterval(1.0)
        while Date() < end {
            swap(&attached, &idle)
            layer.contents = attached
            CATransaction.flush()
            try uiExpect(
                !candidate.isInUse,
                "VIABILITY GATE FAILED: a surface reported free was re-acquired by the render server")
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            try uiExpect(
                !candidate.isInUse,
                "VIABILITY GATE FAILED: a surface reported free was re-acquired by the render server")
        }

        fill(candidate, byte: 0x33)
        try uiExpect(
            !candidate.isInUse,
            "writing a free detached surface flipped its in-use report")
    }

    // Intent: a flipped, layer-backed view configured the way the pane view is
    // -- `layerContentsPlacement = .topLeft`, `contentsScale` set to the
    // surface's backing scale -- shows surface memory row 0 at the visual top,
    // unscaled, leaves the layer's own background in the letterbox strip, and
    // passes the surface's bytes through without a color conversion.
    // Why it exists: I5, and it is four independent ways to be silently wrong.
    // A vertical flip renders the terminal upside down; a wrong gravity
    // stretches the grid over the letterbox; a wrong contents scale halves or
    // doubles it; a color conversion shifts every pixel the store rendered
    // byte-exactly. None of them fails any other gate in this plan, because
    // every other gate stops at the store's memory.
    // Scenario: a surface twice the size of the grid's point extent, red in its
    // top half and blue in its bottom, shown by a view half again as wide and
    // tall as the surface covers.
    uiTest("presentation: row 0 on top, unscaled, letterbox background, colors unconverted") {
        let scale: CGFloat = 2
        let surfacePixels = NSSize(width: 32, height: 16)
        let viewPoints = NSSize(width: 40, height: 20)
        let surface = try makeSplitSurface(
            width: Int(surfacePixels.width),
            height: Int(surfacePixels.height))

        let view = FlippedProbeView(frame: NSRect(origin: .zero, size: viewPoints))
        view.wantsLayer = true
        view.layerContentsPlacement = .topLeft
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        let letterbox = CGColor(red: 0, green: 1, blue: 0, alpha: 1)
        view.layer?.backgroundColor = letterbox
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: viewPoints),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.contentsScale = scale
        view.layer?.contents = surface
        CATransaction.commit()
        CATransaction.flush()

        let shot = try renderLayer(try uiRequire(view.layer, "the probe view has no layer"),
                                   pointSize: viewPoints,
                                   scale: scale)
        // Surface row 0 is red and its bottom half blue, so the top sample
        // proves the orientation and the lower one proves the surface was not
        // squashed to fit the taller view.
        try uiExpect(shot.isRed(x: 2, y: 2),
                     "surface row 0 is not at the visual top: \(shot.describe(x: 2, y: 2))")
        try uiExpect(shot.isBlue(x: 2, y: 12),
                     "the surface was rescaled to the view: \(shot.describe(x: 2, y: 12))")
        try uiExpect(
            shot.isBackground(x: Int(surfacePixels.width) + 8, y: 2),
            "the strip right of the grid is not the layer background: "
                + shot.describe(x: Int(surfacePixels.width) + 8, y: 2))
        try uiExpect(
            shot.isBackground(x: 2, y: Int(surfacePixels.height) + 8),
            "the strip below the grid is not the layer background: "
                + shot.describe(x: 2, y: Int(surfacePixels.height) + 8))
    }
}

/// The pane view's flipped, contents-only shape, with nothing else on it: the
/// point is that no `draw(_:)` exists to produce these pixels.
private final class FlippedProbeView: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
}

/// A surface whose top half is opaque red and bottom half opaque blue, written
/// as raw BGRA so a color conversion anywhere in the display path shows up as a
/// changed component rather than as a plausible-looking image.
private func makeSplitSurface(width: Int, height: Int) throws -> IOSurface {
    guard let surface = IOSurface(properties: [
        .width: width,
        .height: height,
        .bytesPerElement: 4,
        .pixelFormat: UInt32(0x4247_5241), // 'BGRA'
    ]) else {
        throw UITestFailure(message: "IOSurface allocation failed")
    }
    surface.lock(options: [], seed: nil)
    let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let pixel = base + y * surface.bytesPerRow + x * 4
            pixel[0] = y < height / 2 ? 0 : 255 // blue
            pixel[1] = 0
            pixel[2] = y < height / 2 ? 255 : 0 // red
            pixel[3] = 255
        }
    }
    surface.unlock(options: [], seed: nil)
    return surface
}

/// Backing pixels sampled by top-left coordinates, so a test reads them the way
/// a person looking at the pane would.
private struct LayerShot {
    let pixelWidth: Int
    let pixelHeight: Int
    let bytes: [UInt8]

    private func components(x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8) {
        // CGContext row 0 is the bottom row; these coordinates are top-down.
        let offset = ((pixelHeight - 1 - y) * pixelWidth + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    func isRed(x: Int, y: Int) -> Bool {
        let c = components(x: x, y: y)
        return c.r == 255 && c.g == 0 && c.b == 0
    }

    func isBlue(x: Int, y: Int) -> Bool {
        let c = components(x: x, y: y)
        return c.b == 255 && c.g == 0 && c.r == 0
    }

    /// Loose where the surface samples are exact, and deliberately so: the
    /// letterbox is a CGColor the compositor may quantize through a color
    /// space, while the grid is surface bytes that must arrive unconverted.
    /// What this asserts is background rather than grid, not an exact value.
    func isBackground(x: Int, y: Int) -> Bool {
        let c = components(x: x, y: y)
        return c.g > 200 && c.r < 32 && c.b < 32
    }

    func describe(x: Int, y: Int) -> String {
        let c = components(x: x, y: y)
        return "B\(c.b) G\(c.g) R\(c.r) at (\(x),\(y))"
    }
}

/// Rasterizes the layer tree at backing resolution. This is not the render
/// server's compositing path, but it applies the same layer geometry rules --
/// `isGeometryFlipped`, `contentsGravity`, `contentsScale` -- which is what
/// this pin is about, and it needs no screen-recording permission.
@MainActor
private func renderLayer(
    _ layer: CALayer,
    pointSize: NSSize,
    scale: CGFloat
) throws -> LayerShot {
    let pixelWidth = Int(pointSize.width * scale)
    let pixelHeight = Int(pointSize.height * scale)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: pixelWidth * 4,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
    ) else {
        throw UITestFailure(message: "could not create the layer readback context")
    }
    context.scaleBy(x: scale, y: scale)
    layer.render(in: context)
    guard let data = context.data else {
        throw UITestFailure(message: "the layer readback context has no pixels")
    }
    let raw = data.assumingMemoryBound(to: UInt8.self)
    return LayerShot(
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        bytes: Array(UnsafeBufferPointer(start: raw, count: pixelWidth * pixelHeight * 4)))
}

private func uiRequire<Value>(_ value: Value?, _ message: String) throws -> Value {
    guard let value else { throw UITestFailure(message: message) }
    return value
}

// MARK: - Probe fixtures

private let probeSide = 64

/// Borderless floating window hosting `layer`, ordered front so the render
/// server actually composites it -- an occluded or offscreen layer never
/// acquires its contents surface, and every assertion here rides on that
/// acquisition happening.
@MainActor
private func makeProbeWindow(hosting layer: CALayer) -> NSWindow {
    let side = CGFloat(probeSide)
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: side, height: side),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.level = .floating
    let host = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
    host.layer = CALayer()
    host.wantsLayer = true
    layer.frame = host.bounds
    host.layer?.addSublayer(layer)
    window.contentView = host
    window.orderFrontRegardless()
    return window
}

private func makeProbeSurface() throws -> IOSurface {
    guard let surface = IOSurface(properties: [
        .width: probeSide,
        .height: probeSide,
        .bytesPerElement: 4,
        .pixelFormat: UInt32(0x4247_5241), // 'BGRA'
    ]) else {
        throw UITestFailure(message: "IOSurface allocation failed")
    }
    return surface
}

private func fill(_ surface: IOSurface, byte: UInt8) {
    surface.lock(options: [], seed: nil)
    memset(surface.baseAddress, Int32(byte), surface.allocationSize)
    surface.unlock(options: [], seed: nil)
}

/// Commits the implicit transaction and pumps the run loop until `condition`
/// holds or `deadline` seconds pass. Render-server effects (surface use
/// counts) land asynchronously, so every expectation here needs this shape.
@MainActor
private func flushAndPump(deadline: TimeInterval, until condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(deadline)
    repeat {
        CATransaction.flush()
        if condition() { return true }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    } while Date() < end
    return condition()
}
