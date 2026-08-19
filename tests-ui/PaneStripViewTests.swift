// UI-harness tests for the tab row's pane strip: that it fits whatever pane
// count it is given into whatever width it is given, and that the focused pane
// is the one chip it never elides.
//
// The fitting assertions go through `plan(width:)` rather than through drawn
// pixels, because the claim being made is about fitting -- how many chips,
// starting where -- and pixels would only restate it less precisely. The state
// dots are the exception: whether a dot is ringed, and whether both marks are
// painted at once, are facts about paint, so those tests read the paint. The
// `+N` label's width comes from real font metrics, which is why these live here
// and not in the pure core suite.
import ChipArtwork
import Cocoa

@MainActor
func paneStripViewTests() {
    print("PaneStripView")

    // A strip of `count` panes with the one at `focused` marked, every chip
    // carrying the same pair of state facts.
    func makeStrip(
        count: Int, focused: Int, hasAlert: Bool = false, agent: PaneAgentMark = .quiet
    ) -> PaneStripView {
        let strip = PaneStripView()
        strip.chips = (0..<count).map { i in
            TabPaneChip(
                paneId: PaneId(rawValue: UUID()),
                kind: .terminal,
                isFocused: i == focused,
                hasAlert: hasAlert,
                agent: agent)
        }
        return strip
    }

    // The width the strip's own chips occupy, ignoring the overflow label.
    func chipsWidth(_ n: Int) -> CGFloat {
        CGFloat(n) * ChipArtwork.paneRowSize + CGFloat(max(0, n - 1)) * 3
    }

    // Paints a one-chip strip carrying both facts and hands back the bitmap,
    // so a test can read the color at a point.
    //
    // Rendered at 3x onto a ground the strip never paints in, so a sampled
    // pixel is either paint or the miss it is meant to catch, and never an
    // antialiased blend of the two. The strip is drawn directly rather than
    // through the view hierarchy because its dots deliberately overhang its own
    // bounds, which `cacheDisplay` would clip away.
    let sampleScale = 3

    func paintOneChip(
        hasAlert: Bool, agent: PaneAgentMark, rowBackground: NSColor
    ) throws -> (rep: NSBitmapImageRep, strip: PaneStripView, chip: NSRect) {
        let edge = ChipArtwork.paneRowSize
        let size = NSSize(width: edge + 6, height: edge + 6)

        let strip = makeStrip(count: 1, focused: 0, hasAlert: hasAlert, agent: agent)
        strip.rowBackground = rowBackground
        strip.frame = NSRect(origin: .zero, size: size)

        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width) * sampleScale,
                pixelsHigh: Int(size.height) * sampleScale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { throw UITestFailure(message: "could not make a 3x bitmap to draw into") }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(sampleScale), y: CGFloat(sampleScale))
        // Magenta appears in no chip, no dot, and no ring, so it stands for
        // "nothing was painted here" without being mistaken for something.
        context.cgContext.setFillColor(NSColor.magenta.cgColor)
        context.cgContext.fill(NSRect(origin: .zero, size: size))
        strip.draw(strip.bounds)
        NSGraphicsContext.restoreGraphicsState()

        let chip = NSRect(x: 0, y: (size.height - edge) / 2, width: edge, height: edge)
        return (rep, strip, chip)
    }

    // The palette the strip will paint with, resolved the way it resolves it:
    // the harness runs under whichever appearance the machine is set to.
    func palette(of strip: PaneStripView) -> ChipPaneListPalette {
        strip.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? ChipArtwork.paneListDark : ChipArtwork.paneListLight
    }

    // The painted color at a point in the strip's own coordinates.
    func color(of rep: NSBitmapImageRep, at point: NSPoint) throws -> NSColor {
        // The rep's rows run top-down; the strip drew bottom-up.
        let px = Int(point.x * CGFloat(sampleScale))
        let py = rep.pixelsHigh - 1 - Int(point.y * CGFloat(sampleScale))
        guard let color = rep.colorAt(x: px, y: py) else {
            throw UITestFailure(message: "no pixel at \(point)")
        }
        return color
    }

    // The middle of the band that should ring one corner's mark, at the four
    // points where the ring is easiest to name.
    func ringSamples(
        hasAlert: Bool, agent: PaneAgentMark, corner: PaneStripView.MarkCorner,
        rowBackground: NSColor, ringWidth: CGFloat
    ) throws -> [(NSPoint, NSColor)] {
        let painted = try paintOneChip(
            hasAlert: hasAlert, agent: agent, rowBackground: rowBackground)
        let dot = painted.strip.markRect(corner, on: painted.chip)
        let center = NSPoint(x: dot.midX, y: dot.midY)
        let radius = dot.width / 2 + ringWidth / 2

        return try [(-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (0.0, 1.0)].map { dx, dy in
            let point = NSPoint(x: center.x + dx * radius, y: center.y + dy * radius)
            return (point, try color(of: painted.rep, at: point))
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

    uiTest("the two marks take opposite corners and stay inside the bleed") {
        // Intent: the alert mark sits on the chip's top-trailing corner and the
        //   agent mark on its bottom-trailing one, each overhanging by exactly
        //   the declared bleed, at the same size, and never touching each other.
        // Why it exists: the strip sets `clipsToBounds = false` so the dots on
        //   the last chip are not cut off. That makes the overhang unbounded
        //   unless something holds it, and the margins the dots land in -- 2pt
        //   above the strip, about 5pt below it, 4pt of trailing gap -- are only
        //   a few points wide. The two marks also have to stay apart: they
        //   report independent facts on a 12pt chip, and a strip that merged
        //   them would be back to reporting one.
        let bleed = ChipArtwork.stateDotBleed
        let ring = ChipArtwork.stateDotGeometry.ringWidth
        let chip = NSRect(
            x: 40, y: 0, width: ChipArtwork.paneRowSize, height: ChipArtwork.paneRowSize)
        let strip = makeStrip(count: 1, focused: 0, hasAlert: true, agent: .working)

        let alert = strip.markRect(.topTrailing, on: chip)
        let agent = strip.markRect(.bottomTrailing, on: chip)

        // The strip is unflipped, so the chip's visual top is its maxY.
        try uiExpect(
            abs(alert.maxY - (chip.maxY + bleed)) < 0.001,
            "the alert mark overhangs \(alert.maxY - chip.maxY) upward, budget \(bleed)")
        try uiExpect(
            abs(agent.minY - (chip.minY - bleed)) < 0.001,
            "the agent mark overhangs \(chip.minY - agent.minY) downward, budget \(bleed)")
        for (name, dot) in [("alert", alert), ("agent", agent)] {
            try uiExpect(
                abs(dot.maxX - (chip.maxX + bleed)) < 0.001,
                "the \(name) mark overhangs \(dot.maxX - chip.maxX) sideways, budget \(bleed)")
            try uiExpect(
                dot.width <= ChipArtwork.paneRowSize,
                "a mark wider than its chip would mark the neighbor too")
        }
        // Equal size, so neither mark is the quieter one: they are ranked by
        // hue and by corner alone. Busy was a smaller unringed dot once, and
        // ranking by weight is what cost it the outline it now keeps.
        try uiExpect(alert.size == agent.size, "alert \(alert.size) != agent \(agent.size)")
        // Rings included: a gap that only the fills clear would still read as
        // one smeared mark.
        try uiExpect(
            !alert.insetBy(dx: -ring, dy: -ring).intersects(agent.insetBy(dx: -ring, dy: -ring)),
            "the two ringed marks overlap: \(alert) and \(agent)")
    }

    uiTest("every mark the strip paints is ringed in the color of the row") {
        // Intent: painting any of the three marks leaves a band of the row's own
        //   color between the dot and everything it lands on.
        // Why it exists: the incident this fixes -- on a selected tab the amber
        //   dots sat straight on the accent blue, with no outline at all,
        //   because busy was declared with a zero ring width. Every mark added
        //   since has to be held to the same claim, and only sampled paint can
        //   say a ring exists: geometry that reserves room for one proves
        //   nothing about whether it was drawn.
        let row = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let ring = ChipArtwork.stateDotGeometry.ringWidth
        let marks: [(String, Bool, PaneAgentMark, PaneStripView.MarkCorner)] = [
            ("alert", true, .quiet, .topTrailing),
            ("waiting", false, .waiting, .bottomTrailing),
            ("busy", false, .working, .bottomTrailing),
        ]

        for (name, hasAlert, agent, corner) in marks {
            let sampled = try ringSamples(
                hasAlert: hasAlert, agent: agent, corner: corner,
                rowBackground: row, ringWidth: ring)

            for (point, color) in sampled {
                try uiExpect(
                    color.isClose(to: row),
                    "the \(name) ring at \(point) is \(color.debugDescription), "
                        + "expected the row's blue")
            }
        }
    }

    uiTest("an alerting pane with a working agent paints both marks") {
        // Intent: a chip that has rung a bell while its agent runs draws red at
        //   the top-trailing corner and amber at the bottom-trailing one.
        // Why it exists: this is the regression the split exists for. The chip
        //   used to carry one dot for both facts, so an alert on a working pane
        //   erased the fact that the agent was still running.
        let row = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

        let painted = try paintOneChip(hasAlert: true, agent: .working, rowBackground: row)
        let palette = palette(of: painted.strip)

        let alert = painted.strip.markRect(.topTrailing, on: painted.chip)
        let agent = painted.strip.markRect(.bottomTrailing, on: painted.chip)
        let alertColor = try color(of: painted.rep, at: NSPoint(x: alert.midX, y: alert.midY))
        let agentColor = try color(of: painted.rep, at: NSPoint(x: agent.midX, y: agent.midY))

        try uiExpect(
            alertColor.isClose(to: NSColor(cgColor: palette.alertDot) ?? .clear),
            "the top mark is \(alertColor.debugDescription), expected the alert red")
        try uiExpect(
            agentColor.isClose(to: NSColor(cgColor: palette.busyDot) ?? .clear),
            "the bottom mark is \(agentColor.debugDescription), expected the busy amber")
    }

    uiTest("a pane with nothing to report paints no mark at all") {
        // Intent: a quiet chip leaves both of its corners as they were.
        // Why it exists: the marks are the strip's only third channel, so ones
        //   that lit for every pane would report nothing. Spec-first.
        let row = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

        let painted = try paintOneChip(hasAlert: false, agent: .quiet, rowBackground: row)

        for corner: PaneStripView.MarkCorner in [.topTrailing, .bottomTrailing] {
            let dot = painted.strip.markRect(corner, on: painted.chip)
            // The corners bleed past the chip, so an unpainted one still shows
            // the magenta ground the harness laid down.
            let sampled = try color(
                of: painted.rep, at: NSPoint(x: dot.maxX - dot.width / 4, y: dot.midY))
            try uiExpect(
                sampled.isClose(to: .magenta),
                "\(corner) is \(sampled.debugDescription), expected nothing painted")
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
