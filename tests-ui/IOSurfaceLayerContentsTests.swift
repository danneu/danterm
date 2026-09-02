// Real-AppKit pins for the owned-pane-surface route (research/33/T25): the
// IOSurface layer-contents premises the headless harness cannot model. Pin
// one: with implicit actions disabled, a contents swap attaches no animation,
// so no presentation layer keeps a released surface alive. Whether the surface
// then goes free, and how fast, is deliberately not pin one's business. Pin two is the
// route's viability gate: the render server takes a use count on an attached
// surface, drops it after the detaching transaction commits, and once the
// surface reports free it stays free -- the premise that makes
// IOSurfaceIsInUse a safe write-eligibility check for a contents swapchain.
// If pin two goes red, the owned-surface route stops: a depth or age
// heuristic is not a substitute, because neither bounds when a stalled render
// server stops reading a surface.
//
// Pin four is the volatility gate research/41 D2 rests on: a surface detached
// from a layer that then presents nothing still frees while a sibling presents,
// and once free it may be made purgeable-volatile without ever being re-acquired.
//
// Pin three is the presentation contract (I5): the pane view's layer
// configuration puts the surface's first memory row at the visual top, at one
// surface pixel per backing pixel, with the theme background showing in the
// letterbox strip and the surface's bytes reaching the output unconverted.
import Cocoa
import IOSurface
import QuartzCore
import ChipArtwork
import PaneProcessLifecycle
import TerminalCore
import TerminalPaneSession
import TerminalPTYHost
import TerminalRenderExecution
import TerminalRenderPlanning
@testable import DanTerm

@MainActor
func ioSurfaceLayerContentsTests() async {
    print("IOSurfaceLayerContents")

    // Intent: with a "contents" entry of NSNull in the layer's actions
    // dictionary, repeated contents swaps attach no implicit animation.
    // Why it exists: an implicit crossfade would hold the released surface in
    // a presentation layer past the swap, so the swapchain's "detached means
    // releasable" reasoning would be wrong by one animation duration.
    // Scenario: two filled surfaces alternate as the contents of a composited
    // layer; after every swap the layer carries no "contents" animation.
    //
    // This pin does not assert that the swapped-out surface goes free, and must
    // not: freeing is presentation-driven, so a wait that presents no new frame
    // cannot make it happen, and a cold pipeline has been measured holding a
    // detached surface across four later presentations. Promptness is not part
    // of the contract -- pin two owns freeing, demands only monotonicity, and
    // waits by presenting frames the way a live swapchain does.
    await uiTest("disabled actions: a contents swap attaches no implicit animation") {
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
            await flushAndPump(deadline: 5.0) { front.isInUse },
            "render server never acquired the attached surface; is the probe window composited?")

        var attached = front
        var idle = back
        for _ in 0 ..< 4 {
            swap(&attached, &idle)
            layer.contents = attached
            try uiExpect(
                layer.animation(forKey: "contents") == nil,
                "implicit contents animation attached despite the disabling actions dictionary")
            CATransaction.flush()
            try uiExpect(
                layer.animation(forKey: "contents") == nil,
                "contents animation appeared at commit despite the disabling actions dictionary")
        }
    }

    // Intent: a surface detached by a committed transaction and never
    // reattached goes free once later frames present, and from the moment
    // IOSurfaceIsInUse reports it free it stays free -- through many further
    // swaps and across a rewrite of its pixels.
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
    await uiTest("viability gate: a detached surface reported free stays free") {
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
            await flushAndPump(deadline: 5.0) { candidate.isInUse },
            "render server never acquired the attached surface; is the probe window composited?")

        // Both waits below count presented frames rather than elapsed seconds.
        // The gate is about ordering, and a busy machine spends longer on a
        // frame without needing more of them, so a frame count keeps the bound
        // independent of load. On this machine the detached surface frees after
        // 3 frames; 60 is headroom over that measurement, not a threshold tuned
        // to sit just above it.
        let frameBudget = 60

        // Detach; candidate is never reattached below. Freeing is driven by
        // later presentations, so keep swapping the other two surfaces while
        // waiting for it.
        var attached = second
        var idle = third
        var frames = 0
        while candidate.isInUse && frames < frameBudget {
            swap(&attached, &idle)
            layer.contents = attached
            CATransaction.flush()
            await pumpMainQueueOnce()
            frames += 1
        }
        try uiExpect(
            !candidate.isInUse,
            "detached surface never reported free while later frames kept presenting")

        for _ in 0 ..< frameBudget {
            swap(&attached, &idle)
            layer.contents = attached
            CATransaction.flush()
            try uiExpect(
                !candidate.isInUse,
                "VIABILITY GATE FAILED: a surface reported free was re-acquired by the render server")
            await pumpMainQueueOnce()
            try uiExpect(
                !candidate.isInUse,
                "VIABILITY GATE FAILED: a surface reported free was re-acquired by the render server")
        }

        fill(candidate, byte: 0x33)
        try uiExpect(
            !candidate.isInUse,
            "writing a free detached surface flipped its in-use report")
    }

    // Intent: a surface detached from a layer that then presents nothing -- a
    // hidden pane's layer -- still frees while a sibling layer in the same
    // window keeps presenting; once free it may be made purgeable-volatile, is
    // never re-acquired, and comes back with its pages intact.
    // Why it exists: this is research/41 D2's viability gate for the volatile
    // fast path, and the only place the two facts it rests on can be observed.
    // F8 measured the ex-attached buffer still in use after a committed and
    // flushed detach in 44 hides of 44, which is why the app re-asks on a
    // bounded retry; nothing in IOSurface or QuartzCore will tell it when the
    // answer changes. If the second assertion never holds -- the surface does
    // not free while its own layer presents nothing -- that is D2's uncertainty
    // 1 answered "never", and the retry is deleted rather than tuned.
    // Scenario: two sibling layers in one composited window; one shows the
    // candidate and then shows nothing, while the other keeps swapping frames.
    await uiTest("volatility gate: a hidden layer's detached surface frees, goes volatile, stays free") {
        let hidden = CALayer()
        hidden.actions = ["contents": NSNull()]
        let sibling = CALayer()
        sibling.actions = ["contents": NSNull()]
        let candidate = try makeProbeSurface()
        let siblingFront = try makeProbeSurface()
        let siblingBack = try makeProbeSurface()
        fill(candidate, byte: 0x5A)
        fill(siblingFront, byte: 0x80)
        fill(siblingBack, byte: 0x20)
        let window = makeProbeWindow(hosting: hidden, beside: sibling)
        defer { window.orderOut(nil) }

        hidden.contents = candidate
        sibling.contents = siblingFront
        try uiExpect(
            await flushAndPump(deadline: 5.0) { candidate.isInUse },
            "render server never acquired the attached surface; is the probe window composited?")

        // The hide, exactly as `SwiftTerminalSessionView` performs it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hidden.contents = nil
        CATransaction.commit()
        CATransaction.flush()
        try uiExpect(
            candidate.isInUse,
            "the render server released the detached surface within the hide's own flush; "
                + "F8 measured it held in 44 of 44 hides, and the app's retry assumes that")

        // Frames, not seconds: freeing is presentation-driven, and a busy
        // machine spends longer on a frame without needing more of them. 60 is
        // headroom over the 3 frames pin two measured, not a tuned threshold.
        let frameBudget = 60
        var attached = siblingFront
        var idle = siblingBack
        var frames = 0
        while candidate.isInUse && frames < frameBudget {
            swap(&attached, &idle)
            sibling.contents = attached
            CATransaction.flush()
            await pumpMainQueueOnce()
            frames += 1
        }
        try uiExpect(
            !candidate.isInUse,
            "a hidden layer's detached surface never freed while a sibling presented "
                + "\(frameBudget) frames: research/41 D2 uncertainty 1 is answered 'never', "
                + "and the bounded pixel-release retry must be deleted rather than tuned")

        var oldState = IOSurfacePurgeabilityState.purgeableKeepCurrent
        try uiExpect(
            candidate.setPurgeable(.purgeableVolatile, oldState: &oldState) == KERN_SUCCESS,
            "the kernel refused to make a free detached surface volatile")

        for _ in 0 ..< frameBudget {
            swap(&attached, &idle)
            sibling.contents = attached
            CATransaction.flush()
            try uiExpect(
                !candidate.isInUse,
                "VOLATILITY GATE FAILED: a volatile detached surface was re-acquired")
            await pumpMainQueueOnce()
            try uiExpect(
                !candidate.isInUse,
                "VOLATILITY GATE FAILED: a volatile detached surface was re-acquired")
        }

        var restoredFrom = IOSurfacePurgeabilityState.purgeableKeepCurrent
        try uiExpect(
            candidate.setPurgeable(
                IOSurfacePurgeabilityState([]), oldState: &restoredFrom
            ) == KERN_SUCCESS,
            "the kernel refused to restore a volatile surface")
        try uiExpect(
            restoredFrom == .purgeableVolatile,
            "the surface did not come back volatile-with-pages: \(restoredFrom)")
        try uiExpect(
            firstByte(of: candidate) == 0x5A,
            "the restored surface lost the byte written before it was attached: "
                + "\(String(describing: firstByte(of: candidate)))")
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
    await uiTest("presentation: row 0 on top, unscaled, letterbox background, colors unconverted") {
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
private func makeProbeWindow(hosting layer: CALayer, beside sibling: CALayer? = nil) -> NSWindow {
    let side = CGFloat(probeSide)
    let width = sibling == nil ? side : side * 2
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: width, height: side),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.level = .floating
    let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: side))
    host.layer = CALayer()
    host.wantsLayer = true
    layer.frame = NSRect(x: 0, y: 0, width: side, height: side)
    host.layer?.addSublayer(layer)
    if let sibling {
        // Beside, not over: an occluded layer never acquires its contents
        // surface, and the whole point of the sibling is that it keeps
        // presenting while the first layer does not.
        sibling.frame = NSRect(x: side, y: 0, width: side, height: side)
        host.layer?.addSublayer(sibling)
    }
    window.contentView = host
    window.orderFrontRegardless()
    return window
}

/// The first byte of a surface's pixels, for the pin that asks whether restored
/// pages still hold what was written into them.
private func firstByte(of surface: IOSurface) -> UInt8? {
    surface.lock(options: [], seed: nil)
    defer { surface.unlock(options: [], seed: nil) }
    return surface.baseAddress.assumingMemoryBound(to: UInt8.self).pointee
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
///
/// It re-flushes an unchanged layer tree, so it presents no new frame. That
/// makes it right for waiting on an effect an already-committed attach will
/// produce -- the render server taking its use count -- and wrong for waiting
/// on one that only later presentations produce. Waiting here for a detached
/// surface to go free never terminates on a cold pipeline, however long the
/// deadline: see pin two, which waits by presenting frames instead.
@MainActor
private func flushAndPump(deadline: TimeInterval, until condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(deadline)
    repeat {
        CATransaction.flush()
        if condition() { return true }
        await pumpMainQueueOnce()
    } while Date() < end
    return condition()
}
