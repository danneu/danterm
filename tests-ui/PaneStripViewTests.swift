// UI-harness tests for the tab row's pane strip: that it fits whatever pane
// count it is given into whatever width it is given, and that the focused pane
// is the one chip it never elides.
//
// The fitting assertions go through `plan(width:)` rather than through drawn
// pixels, because the claim being made is about fitting -- how many chips,
// starting where -- and pixels would only restate it less precisely. The state
// dots are the exception: whether a dot is ringed is a fact about paint, so
// that one test reads the paint. The `+N` label's width comes from real font
// metrics, which is why these live here and not in the pure core suite.
import Cocoa

@MainActor
func paneStripViewTests() {
    print("PaneStripView")

    // A strip of `count` panes with the one at `focused` marked.
    func makeStrip(count: Int, focused: Int, state: PaneChipState = .quiet) -> PaneStripView {
        let strip = PaneStripView()
        strip.chips = (0..<count).map { i in
            TabPaneChip(
                paneId: PaneId(rawValue: UUID()),
                kind: .terminal,
                isFocused: i == focused,
                state: state)
        }
        return strip
    }

    // The width the strip's own chips occupy, ignoring the overflow label.
    func chipsWidth(_ n: Int) -> CGFloat {
        CGFloat(n) * ChipArtwork.paneRowSize + CGFloat(max(0, n - 1)) * 3
    }

    // Paints a one-chip strip and reads back the middle of the band that should
    // ring its dot, at the four points where the ring is easiest to name.
    //
    // Rendered at 3x onto a ground the strip never paints in, so a band pixel
    // is either the ring or the miss it is meant to catch, and never an
    // antialiased blend of the two. The strip is drawn directly rather than
    // through the view hierarchy because its dot deliberately overhangs its own
    // bounds, which `cacheDisplay` would clip away.
    func ringSamples(
        state: PaneChipState, rowBackground: NSColor, ringWidth: CGFloat
    ) throws -> [(NSPoint, NSColor)] {
        let scale = 3
        let edge = ChipArtwork.paneRowSize
        let size = NSSize(width: edge + 6, height: edge + 6)

        let strip = makeStrip(count: 1, focused: 0, state: state)
        strip.rowBackground = rowBackground
        strip.frame = NSRect(origin: .zero, size: size)

        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width) * scale,
                pixelsHigh: Int(size.height) * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { throw UITestFailure(message: "could not make a \(scale)x bitmap to draw into") }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        // Magenta appears in no chip, no dot, and no ring, so it stands for
        // "nothing was painted here" without being mistaken for something.
        context.cgContext.setFillColor(NSColor.magenta.cgColor)
        context.cgContext.fill(NSRect(origin: .zero, size: size))
        strip.draw(strip.bounds)
        NSGraphicsContext.restoreGraphicsState()

        let chip = NSRect(x: 0, y: (size.height - edge) / 2, width: edge, height: edge)
        guard let dot = strip.stateDotRect(state, on: chip) else {
            throw UITestFailure(message: "\(state) draws no dot to ring")
        }
        let center = NSPoint(x: dot.midX, y: dot.midY)
        let radius = dot.width / 2 + ringWidth / 2

        return try [(-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (0.0, 1.0)].map { dx, dy in
            let point = NSPoint(x: center.x + dx * radius, y: center.y + dy * radius)
            // The rep's rows run top-down; the strip drew bottom-up.
            let px = Int(point.x * CGFloat(scale))
            let py = rep.pixelsHigh - 1 - Int(point.y * CGFloat(scale))
            guard let color = rep.colorAt(x: px, y: py) else {
                throw UITestFailure(message: "no pixel at \(point)")
            }
            return (point, color)
        }
    }

    uiTest("a strip that fits shows every pane and no overflow count") {
        // Intent: given room for all of them, nothing is elided.
        // Why it exists: the count is the whole answer for the common case of
        //   two or three panes, and a spurious "+0" would be noise. Spec-first.
        let strip = makeStrip(count: 3, focused: 0)

        let plan = strip.plan(width: 200)

        try uiExpect(plan.visible == 0..<3, "expected all three, got \(plan.visible)")
        try uiExpect(plan.hidden == 0, "expected nothing hidden, got \(plan.hidden)")
    }

    uiTest("a strip too long for its row elides the excess") {
        // Intent: at a width that holds about four chips, a fourteen-pane tab
        //   shows a short run and counts the rest.
        // Why it exists: the incident this replaces -- a stack of fixed-width
        //   chips could not shrink, so Auto Layout broke a width constraint and
        //   stretched one chip across the row instead of eliding anything.
        let strip = makeStrip(count: 14, focused: 0)

        let plan = strip.plan(width: chipsWidth(4))

        try uiExpect(plan.visible.count < 14, "expected elision, got \(plan.visible.count)")
        try uiExpect(
            plan.visible.count + plan.hidden == 14,
            "every pane is either shown or counted, got \(plan.visible.count) + \(plan.hidden)")
    }

    uiTest("the run never overflows the width it is given") {
        // Intent: across a sweep of widths and pane counts, the chips plus the
        //   overflow label always fit.
        // Why it exists: this is the property the view exists for, and the
        //   sidebar is user-resizable, so no single width can stand in for it.
        for count in [1, 2, 5, 14, 40] {
            for width in stride(from: CGFloat(8), through: 260, by: 6) {
                let strip = makeStrip(count: count, focused: 0)
                let plan = strip.plan(width: width)
                guard !plan.visible.isEmpty else { continue }

                var used = chipsWidth(plan.visible.count)
                if plan.hidden > 0 { used += 3 + strip.overflowLabelWidth(count: plan.hidden) }
                // One chip is always drawn even where nothing fits, so the floor
                // is exempt: a strip that showed nothing would be a worse answer
                // than one that overhangs a uselessly narrow row.
                try uiExpect(
                    used <= width || plan.visible.count == 1,
                    "count \(count) at width \(width): used \(used)")
            }
        }
    }

    uiTest("the focused pane is never the one elided") {
        // Intent: whichever pane is focused, it is inside the visible run.
        // Why it exists: the strip's whole job is to say which pane you are in.
        //   A strip that hides exactly that chip is worse than no strip, and the
        //   failure only appears once a tab has more panes than fit.
        for focused in 0..<14 {
            let strip = makeStrip(count: 14, focused: focused)

            let plan = strip.plan(width: chipsWidth(4))

            try uiExpect(
                plan.visible.contains(focused),
                "focus \(focused) fell outside \(plan.visible)")
        }
    }

    uiTest("a state dot stays inside the bleed the strip budgets for") {
        // Intent: every dot sits on its chip's top-right corner and overhangs by
        //   exactly the declared bleed, on both axes and in both flippednesses.
        // Why it exists: the strip sets `clipsToBounds = false` so the dot on the
        //   last chip is not cut off. That makes the overhang unbounded unless
        //   something holds it, and the margins it lands in -- 2pt above the
        //   strip, 4pt of trailing gap -- are only a few points wide.
        let bleed = ChipArtwork.stateDotBleed
        let chip = NSRect(x: 40, y: 0, width: ChipArtwork.paneRowSize, height: ChipArtwork.paneRowSize)

        for state: PaneChipState in [.attention, .busy] {
            let strip = makeStrip(count: 1, focused: 0, state: state)
            try uiExpect(strip.stateDotRect(state, on: chip) != nil, "\(state) should draw a dot")
            guard let dot = strip.stateDotRect(state, on: chip) else { continue }

            try uiExpect(
                abs(dot.maxX - (chip.maxX + bleed)) < 0.001,
                "\(state) overhangs \(dot.maxX - chip.maxX) horizontally, budget \(bleed)")
            // The strip is unflipped, so the chip's visual top is its maxY.
            try uiExpect(
                abs(dot.maxY - (chip.maxY + bleed)) < 0.001,
                "\(state) overhangs \(dot.maxY - chip.maxY) vertically, budget \(bleed)")
            try uiExpect(
                dot.width <= ChipArtwork.paneRowSize,
                "a dot wider than its chip would mark the neighbor too")
        }

        try uiExpect(
            makeStrip(count: 1, focused: 0).stateDotRect(.quiet, on: chip) == nil,
            "a quiet pane draws no dot at all")
    }

    uiTest("both states draw the same dot, so neither is the quieter one") {
        // Intent: attention and busy differ in hue and in nothing else -- same
        //   diameter, same corner, same ring.
        // Why it exists: busy used to be a smaller unringed dot. Ranking the two
        //   by weight cost the busy dot its outline, and an unringed dot on the
        //   accent-colored selected row sits directly on the blue with nothing
        //   to separate it.
        let chip = NSRect(x: 40, y: 0, width: ChipArtwork.paneRowSize, height: ChipArtwork.paneRowSize)
        let strip = makeStrip(count: 1, focused: 0, state: .busy)

        try uiExpect(
            strip.stateDotRect(.busy, on: chip) == strip.stateDotRect(.attention, on: chip),
            "busy \(String(describing: strip.stateDotRect(.busy, on: chip))) "
                + "!= attention \(String(describing: strip.stateDotRect(.attention, on: chip)))")
    }

    uiTest("a busy dot is ringed in the color of the row behind it") {
        // Intent: painting a busy pane's dot leaves a band of the row's own
        //   color between the dot and everything it lands on.
        // Why it exists: the incident this fixes -- on a selected tab the amber
        //   dots sat straight on the accent blue, with no outline at all,
        //   because busy was declared with a zero ring width.
        let row = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let ring = ChipArtwork.stateDotGeometry.ringWidth

        let sampled = try ringSamples(state: .busy, rowBackground: row, ringWidth: ring)

        for (point, color) in sampled {
            try uiExpect(
                color.isClose(to: row),
                "the ring at \(point) is \(color.debugDescription), expected the row's blue")
        }
    }

    uiTest("the run stays anchored at the start until the focus forces it") {
        // Intent: focusing an early pane leaves the strip reading from pane one;
        //   only a focus past the end of the run slides it.
        // Why it exists: a strip that recentered on every focus change would
        //   reshuffle under the pointer while the panes themselves had not
        //   moved. Spec-first.
        let width = chipsWidth(4)

        try uiExpect(
            makeStrip(count: 14, focused: 0).plan(width: width).visible.lowerBound == 0,
            "focusing the first pane should not slide the run")
        let slid = makeStrip(count: 14, focused: 13).plan(width: width)
        try uiExpect(slid.visible.upperBound == 14, "the run should end at the focused pane")
    }
}

/// Compares two painted colors loosely enough to survive antialiasing and a
/// trip through the bitmap's color space, and no looser: the colors a pane
/// strip can put in one pixel are far apart on purpose.
extension NSColor {
    fileprivate func isClose(to other: NSColor, tolerance: CGFloat = 0.15) -> Bool {
        guard
            let a = usingColorSpace(.sRGB),
            let b = other.usingColorSpace(.sRGB)
        else { return false }
        return abs(a.redComponent - b.redComponent) < tolerance
            && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
    }
}
