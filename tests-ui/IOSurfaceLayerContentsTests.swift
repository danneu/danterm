// Real-AppKit pins for the owned-pane-surface route (research/33/T25): the two
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
