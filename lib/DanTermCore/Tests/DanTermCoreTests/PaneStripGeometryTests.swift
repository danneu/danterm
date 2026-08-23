// Pure coverage for the pane strip's fitting contract. Synthetic overflow
// label widths keep the layout sweep deterministic and headless.

import Foundation
import Testing

@testable import DanTermCore

struct PaneStripGeometryTests {
    private let chipWidth: CGFloat = 12
    private let spacing: CGFloat = 3

    @Test("room for every chip shows the full run")
    func fullRunFits() {
        let plan = paneStripPlan(
            chips: makeChips(count: 3, focused: 0), width: 200,
            chipWidth: chipWidth, spacing: spacing,
            overflowLabelWidth: { _ in 18 })

        #expect(plan.visible == 0..<3)
        #expect(plan.hidden == 0)
    }

    @Test("the run is maximal and never overflows", arguments: [1, 2, 5, 14, 40])
    func runIsMaximalAndFits(total: Int) {
        // Intent: every supported width gets the largest run that fits, except
        //   for the one-chip floor where showing the pane beats clipping it.
        // Why it exists: the pane strip replaced a stack that broke its width
        //   constraint and stretched one chip across a narrow sidebar.
        // Scenario: the sidebar sweeps through narrow and wide layouts for
        //   representative pane counts and synthetic overflow-label widths.
        for width in stride(from: CGFloat(8), through: 260, by: 6) {
            let plan = paneStripPlan(
                chips: makeChips(count: total, focused: 0), width: width,
                chipWidth: chipWidth, spacing: spacing,
                overflowLabelWidth: overflowWidth)

            let used = usedWidth(for: plan, total: total)
            #expect(
                used <= width || plan.visible.count == 1,
                "count \(total) at width \(width): used \(used)")
            #expect(
                plan.visible.count + plan.hidden == total,
                "count \(total) at width \(width) lost or duplicated a pane")

            if plan.hidden > 0, plan.visible.count < total {
                let widerPlanUsed = usedWidth(visibleCount: plan.visible.count + 1, total: total)
                #expect(
                    widerPlanUsed > width,
                    "count \(total) at width \(width) elided a chip that used \(widerPlanUsed)")
            }
        }
    }

    @Test("the focused chip stays visible with the smallest possible slide", arguments: [1, 2, 5, 14])
    func focusedRunSlidesMinimally(total: Int) {
        // Intent: focus is always visible and moves the run from index zero
        //   only by the distance needed to include it.
        // Why it exists: a run that recenters on every focus change reshuffles
        //   under the pointer even though the panes themselves did not move.
        // Scenario: every focus position is checked across the sidebar's width
        //   range for representative pane counts.
        for width in stride(from: CGFloat(8), through: 260, by: 6) {
            for focused in 0..<total {
                let plan = paneStripPlan(
                    chips: makeChips(count: total, focused: focused), width: width,
                    chipWidth: chipWidth, spacing: spacing,
                    overflowLabelWidth: overflowWidth)
                let expectedStart = max(0, focused - plan.visible.count + 1)

                #expect(plan.visible.contains(focused))
                #expect(
                    plan.visible.lowerBound == expectedStart,
                    "count \(total), width \(width), focus \(focused) started at \(plan.visible.lowerBound), expected \(expectedStart)")
            }
        }
    }

    @Test("empty and non-positive inputs show no chips")
    func domainEdgesShowNothing() {
        let noChips = paneStripPlan(
            chips: [], width: 100, chipWidth: chipWidth, spacing: spacing,
            overflowLabelWidth: overflowWidth)
        let zeroWidth = paneStripPlan(
            chips: makeChips(count: 3, focused: 0), width: 0,
            chipWidth: chipWidth, spacing: spacing,
            overflowLabelWidth: overflowWidth)
        let negativeWidth = paneStripPlan(
            chips: makeChips(count: 3, focused: 0), width: -1,
            chipWidth: chipWidth, spacing: spacing,
            overflowLabelWidth: overflowWidth)

        #expect(noChips == PaneStripPlan(visible: 0..<0, hidden: 0))
        #expect(zeroWidth == PaneStripPlan(visible: 0..<0, hidden: 3))
        #expect(negativeWidth == PaneStripPlan(visible: 0..<0, hidden: 3))
    }

    private func makeChips(count: Int, focused: Int) -> [TabPaneChip] {
        (0..<count).map { index in
            TabPaneChip(
                paneId: PaneId(), kind: .terminal, isFocused: index == focused,
                hasAlert: false, agent: .quiet)
        }
    }

    private func chipsWidth(_ count: Int) -> CGFloat {
        CGFloat(count) * chipWidth + CGFloat(max(0, count - 1)) * spacing
    }

    private func overflowWidth(_ hidden: Int) -> CGFloat {
        CGFloat(12 + String(hidden).count * 6)
    }

    private func usedWidth(for plan: PaneStripPlan, total: Int) -> CGFloat {
        usedWidth(visibleCount: plan.visible.count, total: total)
    }

    private func usedWidth(visibleCount: Int, total: Int) -> CGFloat {
        let hidden = total - visibleCount
        return chipsWidth(visibleCount) + (hidden > 0 ? spacing + overflowWidth(hidden) : 0)
    }
}
