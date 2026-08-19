// Pure drop-target resolution tests. These pin which pane a layout-space point
// drops onto, and that the in-pane zone answer stays `resolveDropZone`'s.
// In-pane zone semantics themselves belong to DropZoneTests, not here.
import Foundation
import Testing

@testable import DanTermCore

struct PaneDropResolutionTests {
    private static let bounds = PaneLayoutRect(x: 0, y: 0, width: 800, height: 600)

    /// Samples the whole container so a test states a fact about every point, not
    /// about the handful a reader happened to pick.
    private static func gridPoints(in rect: PaneLayoutRect, steps: Int = 40) -> [DropZonePoint] {
        var points: [DropZonePoint] = []
        for i in 0...steps {
            for j in 0...steps {
                points.append(
                    DropZonePoint(
                        x: rect.minX + rect.width * CGFloat(i) / CGFloat(steps),
                        y: rect.minY + rect.height * CGFloat(j) / CGFloat(steps)
                    )
                )
            }
        }
        return points
    }

    @Test("a zoomed layout offers no drop on the hidden sibling")
    func zoomedLayoutHidesSiblingFromDrops() {
        // Intent: while one pane is zoomed, no point in the container resolves to
        //   the hidden sibling, and a drag started from the zoomed pane itself
        //   finds no in-tab target anywhere.
        // Why it exists: the flat container hides a zoomed pane's siblings but
        //   leaves their stale view frames tiling the container, so a resolver
        //   reading view frames highlighted and dropped onto invisible panes.
        //   Resolving from the pure layout makes that unrepresentable.
        // Scenario: spec-first -- a two-pane horizontal split with the left pane
        //   zoomed, sampled across the whole container.
        let zoomed = PaneId(), hidden = PaneId()
        let tree = SplitNodeModel.split(
            id: SplitId(),
            direction: .horizontal,
            first: .leaf(PaneModel(id: zoomed)),
            second: .leaf(PaneModel(id: hidden)),
            ratio: 0.5
        )
        let layout = paneLayout(in: Self.bounds, tree: tree, zoomedPaneId: zoomed)

        for point in Self.gridPoints(in: Self.bounds) {
            #expect(
                resolvePaneDrop(at: point, in: layout, source: hidden)?.target != hidden,
                "point (\(point.x), \(point.y)) resolved to the hidden sibling"
            )
            #expect(
                resolvePaneDrop(at: point, in: layout, source: zoomed) == nil,
                "point (\(point.x), \(point.y)) offered a drop to the zoomed source pane"
            )
        }
    }

    @Test("the in-pane zone answer is resolveDropZone's own")
    func inPaneZoneMatchesDropZoneResolver() throws {
        // Intent: for a point inside a target pane, the resolved intent equals what
        //   `resolveDropZone` returns for that point in the pane's local coordinates.
        // Why it exists: edge bands, the corner tie-break, and the center swap must
        //   keep exactly one decider; a second copy of the thresholds would drift.
        // Scenario: spec-first -- a two-pane vertical split, sampled across the
        //   target pane's own box.
        let source = PaneId(), target = PaneId()
        let tree = SplitNodeModel.split(
            id: SplitId(),
            direction: .vertical,
            first: .leaf(PaneModel(id: source)),
            second: .leaf(PaneModel(id: target)),
            ratio: 0.6
        )
        let layout = paneLayout(in: Self.bounds, tree: tree, zoomedPaneId: nil)
        let frame = try #require(layout.paneFrames[target])

        var sawSwap = false
        var sawSplits: Set<PaneDropIntent> = []
        for point in Self.gridPoints(in: frame) {
            let expected = resolveDropZone(
                cursorInPane: DropZonePoint(x: point.x - frame.minX, y: point.y - frame.minY),
                paneSize: DropZoneSize(width: frame.width, height: frame.height)
            )
            let drop = resolvePaneDrop(at: point, in: layout, source: source)
            // The pane's own maxX/maxY belong to the next box, not to this one, so
            // the sampled far edge legitimately resolves to nothing.
            if point.x == frame.maxX || point.y == frame.maxY { continue }
            #expect(drop?.target == target, "point (\(point.x), \(point.y)) left the target pane")
            #expect(drop?.intent == expected, "point (\(point.x), \(point.y)) disagreed with resolveDropZone")
            if expected == .swap { sawSwap = true } else if let expected { sawSplits.insert(expected) }
        }
        #expect(sawSwap, "the sample never covered the center swap zone")
        #expect(sawSplits == [.splitLeft, .splitRight, .splitTop, .splitBottom],
            "the sample never covered all four edge bands")
    }

    @Test("the source pane, the dividers, and the outside offer no drop")
    func sourceDividerAndOutsideOfferNoDrop() throws {
        // Intent: a point in the drag source's own frame, on a divider, or outside
        //   the container resolves to no drop at all.
        // Why it exists: dropping a pane onto itself is meaningless, and gaps
        //   between pane boxes must not fall through to a neighbor.
        // Scenario: spec-first -- a two-pane horizontal split dragged from the left
        //   pane, probing its own box, the divider strip, and points beyond bounds.
        let source = PaneId(), target = PaneId()
        let tree = SplitNodeModel.split(
            id: SplitId(),
            direction: .horizontal,
            first: .leaf(PaneModel(id: source)),
            second: .leaf(PaneModel(id: target)),
            ratio: 0.5
        )
        let layout = paneLayout(in: Self.bounds, tree: tree, zoomedPaneId: nil)
        let sourceFrame = try #require(layout.paneFrames[source])
        let divider = try #require(layout.dividers.values.first).frame

        for point in Self.gridPoints(in: sourceFrame, steps: 8) where point.x < sourceFrame.maxX {
            #expect(resolvePaneDrop(at: point, in: layout, source: source) == nil,
                "point (\(point.x), \(point.y)) in the source's own frame offered a drop")
        }

        let onDivider = DropZonePoint(x: divider.minX + divider.width / 2, y: divider.minY + divider.height / 2)
        #expect(resolvePaneDrop(at: onDivider, in: layout, source: source) == nil)

        let outside = [
            DropZonePoint(x: -1, y: 300),
            DropZonePoint(x: 801, y: 300),
            DropZonePoint(x: 400, y: -1),
            DropZonePoint(x: 400, y: 601),
        ]
        for point in outside {
            #expect(resolvePaneDrop(at: point, in: layout, source: source) == nil,
                "point (\(point.x), \(point.y)) outside the container offered a drop")
        }
    }

    @Test("a lone pane in its tab is never its own drop target")
    func lonePaneOffersNoDrop() {
        // Intent: with a single pane in the tab, no point yields an in-tab drop.
        // Why it exists: the drag still starts for a lone pane when other tabs
        //   exist, so the sidebar can accept it; the pane area must stay inert.
        // Scenario: spec-first -- one leaf filling the container, dragged from itself.
        let only = PaneId()
        let layout = paneLayout(in: Self.bounds, tree: .leaf(PaneModel(id: only)), zoomedPaneId: nil)

        for point in Self.gridPoints(in: Self.bounds, steps: 12) {
            #expect(resolvePaneDrop(at: point, in: layout, source: only) == nil,
                "point (\(point.x), \(point.y)) offered a drop in a single-pane tab")
        }
    }
}
