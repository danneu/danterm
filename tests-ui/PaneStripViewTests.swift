// UI-harness tests for the tab row's pane strip: that it fits whatever pane
// count it is given into whatever width it is given, and that the focused pane
// is the one chip it never elides.
//
// The assertions go through `plan(width:)` rather than through drawn pixels,
// because the claim being made is about fitting -- how many chips, starting
// where -- and pixels would only restate it less precisely. The `+N` label's
// width comes from real font metrics, which is why these live here and not in
// the pure core suite.
import Cocoa

@MainActor
func paneStripViewTests() {
    print("PaneStripView")

    // A strip of `count` panes with the one at `focused` marked.
    func makeStrip(count: Int, focused: Int) -> PaneStripView {
        let strip = PaneStripView()
        strip.chips = (0..<count).map { i in
            TabPaneChip(
                paneId: PaneId(rawValue: UUID()),
                kind: .terminal,
                isFocused: i == focused)
        }
        return strip
    }

    // The width the strip's own chips occupy, ignoring the overflow label.
    func chipsWidth(_ n: Int) -> CGFloat {
        CGFloat(n) * ChipArtwork.paneRowSize + CGFloat(max(0, n - 1)) * 3
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
