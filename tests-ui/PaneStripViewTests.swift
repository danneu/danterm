// UI-harness tests for the tab row's pane-strip painting. Pure fitting behavior
// lives in PaneStripGeometryTests; this suite reads pixels and AppKit geometry.
import ChipArtwork
import Cocoa
import PaneProcessLifecycle
import TerminalCore
import TerminalPaneSession
import TerminalPTYHost
import TerminalRenderExecution
import TerminalRenderPlanning
@testable import DanTerm

@MainActor
func paneStripViewTests() async {
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

    await uiTest("the two marks take opposite corners and stay inside the bleed") {
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

    await uiTest("every mark the strip paints is ringed in the color of the row") {
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

    await uiTest("an alerting pane with a working agent paints both marks") {
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

    await uiTest("a pane with nothing to report paints no mark at all") {
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

    await uiTest("overflow fitting uses the width of the label the strip paints") {
        // Intent: real font metrics reserve enough room for the overflow label
        //   while preserving the one-chip floor at widths where nothing fits.
        // Why it exists: the headless fitting sweep uses synthetic widths, so
        //   only the AppKit harness can tie that proof to the shipping font.
        // Scenario: representative pane counts sweep the sidebar's width range
        //   and compare the plan with a label built from the painted font.
        let chipWidth = ChipArtwork.paneRowSize
        let spacing: CGFloat = 3
        let font = NSFont.systemFont(ofSize: 9, weight: .medium)

        for count in [2, 5, 14, 40] {
            for width in stride(from: CGFloat(8), through: 260, by: 6) {
                let strip = makeStrip(count: count, focused: 0)
                strip.frame = NSRect(x: 0, y: 0, width: width, height: chipWidth)
                let plan = strip.plan(width: width)
                let chipsWidth = CGFloat(plan.visible.count) * chipWidth
                    + CGFloat(max(0, plan.visible.count - 1)) * spacing
                let labelWidth = plan.hidden > 0
                    ? NSAttributedString(
                        string: "+\(plan.hidden)", attributes: [.font: font]
                    ).size().width
                    : 0
                let used = chipsWidth + (labelWidth > 0 ? spacing + labelWidth : 0)

                try uiExpect(
                    used <= width || plan.visible.count == 1,
                    "count \(count) at width \(width): real label uses \(used)")
            }
        }
    }

    await uiTest("repainting reuses pane-strip overflow measurements") {
        // Intent: fitting measures each newly needed overflow count once and a
        //   repaint at unchanged inputs performs no measurement.
        // Why it exists: this strip repaints for every sidebar-width step, and
        //   measuring attributed text from draw made unchanged frames repeat
        //   the same CoreText work.
        // Scenario: four panes need a +1 label, repeated paints reuse it, then
        //   a fifth pane measures the newly needed +2 label exactly once.
        var measuredCounts: [Int] = []
        let strip = PaneStripView(
            frame: NSRect(x: 0, y: 0, width: 55, height: ChipArtwork.paneRowSize),
            measureOverflowLabelWidth: { count in
                measuredCounts.append(count)
                return 9
            })

        strip.chips = (0..<4).map { index in
            TabPaneChip(
                paneId: PaneId(rawValue: UUID()), kind: .terminal,
                isFocused: index == 0, hasAlert: false, agent: .quiet)
        }
        try uiExpect(measuredCounts == [1], "initial fit measured \(measuredCounts)")

        let rep = strip.bitmapImageRepForCachingDisplay(in: strip.bounds)!
        strip.cacheDisplay(in: strip.bounds, to: rep)
        strip.cacheDisplay(in: strip.bounds, to: rep)
        try uiExpect(measuredCounts == [1], "unchanged repaints measured \(measuredCounts)")

        strip.chips = (0..<5).map { index in
            TabPaneChip(
                paneId: PaneId(rawValue: UUID()), kind: .terminal,
                isFocused: index == 0, hasAlert: false, agent: .quiet)
        }
        try uiExpect(measuredCounts == [1, 2], "new overflow count measured \(measuredCounts)")

        strip.cacheDisplay(in: strip.bounds, to: rep)
        try uiExpect(measuredCounts == [1, 2], "repaint remeasured \(measuredCounts)")
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
