// Pure pane-layout tests. These pin model-derived pane and divider geometry,
// minimum-size behavior, drag inversion, and zoom without AppKit.
import Foundation
import Testing

@testable import DanTermCore

struct PaneLayoutTests {
    @Test("normal, zoomed, and unknown-zoom layouts place every pane exactly once")
    func layoutRosterIsExhaustive() {
        let paneA = PaneId(), paneB = PaneId(), paneC = PaneId()
        let tree = SplitNodeModel.split(
            id: SplitId(),
            direction: .horizontal,
            first: .leaf(PaneModel(id: paneA)),
            second: .split(
                id: SplitId(),
                direction: .vertical,
                first: .leaf(PaneModel(id: paneB)),
                second: .leaf(PaneModel(id: paneC)),
                ratio: 0.5
            ),
            ratio: 0.5
        )
        let bounds = PaneLayoutRect(x: 0, y: 0, width: 801, height: 601)

        let normal = paneLayout(in: bounds, tree: tree, zoomedPaneId: nil)
        let zoomed = paneLayout(in: bounds, tree: tree, zoomedPaneId: paneB)
        let unknownZoom = paneLayout(in: bounds, tree: tree, zoomedPaneId: PaneId())

        #expect(Set(normal.placements.keys) == [paneA, paneB, paneC])
        #expect(normal.placements.values.allSatisfy { $0.visibleFrame != nil })
        #expect(zoomed.placements == [paneA: .hidden, paneB: .visible(bounds), paneC: .hidden])
        #expect(unknownZoom == normal)
    }

    @Test("nested splits tile their parent boxes exactly")
    func nestedSplitsTileParentBoxes() throws {
        // Intent: every split partitions its own box into two pane regions and
        //   one divider without overlap or escape across varied trees and sizes.
        // Why it exists: pane sizes must derive from their immediate parent,
        //   not from a stale container-wide frame.
        // Scenario: horizontal-first, vertical-first, and undersized nested trees.
        let paneA = PaneId(), paneB = PaneId(), paneC = PaneId(), paneD = PaneId()
        let horizontalFirst = SplitNodeModel.split(
            id: SplitId(),
            direction: .horizontal,
            first: .leaf(PaneModel(id: paneA)),
            second: .split(
                id: SplitId(),
                direction: .vertical,
                first: .leaf(PaneModel(id: paneB)),
                second: .leaf(PaneModel(id: paneC)),
                ratio: 0.25
            ),
            ratio: 0.4
        )
        let verticalFirst = SplitNodeModel.split(
            id: SplitId(),
            direction: .vertical,
            first: .split(
                id: SplitId(),
                direction: .horizontal,
                first: .leaf(PaneModel(id: paneA)),
                second: .leaf(PaneModel(id: paneB)),
                ratio: 0.7
            ),
            second: .split(
                id: SplitId(),
                direction: .horizontal,
                first: .leaf(PaneModel(id: paneC)),
                second: .leaf(PaneModel(id: paneD)),
                ratio: 0.2
            ),
            ratio: 0.6
        )
        let cases: [(String, SplitNodeModel, PaneLayoutRect)] = [
            ("horizontal first", horizontalFirst, PaneLayoutRect(x: 11, y: 17, width: 803, height: 607)),
            ("vertical first", verticalFirst, PaneLayoutRect(x: 3, y: 5, width: 517, height: 409)),
            ("undersized", verticalFirst, PaneLayoutRect(x: 0, y: 0, width: 151, height: 151)),
        ]

        for (name, tree, bounds) in cases {
            let layout = paneLayout(in: bounds, tree: tree, zoomedPaneId: nil)
            try verifyLayout(layout, realizes: tree, in: bounds, caseName: name)
            #expect(paneLayout(in: bounds, tree: tree, zoomedPaneId: nil) == layout,
                "\(name) layout is idempotent")
        }
    }

    @Test("Claude Code split incident derives the nested pane from its column")
    func claudeCodeSplitIncidentUsesColumnWidth() throws {
        // Intent: splitting the right column of a 179-wide two-column layout
        //   keeps both new panes inside that column.
        // Why it exists: the 2026-08-16 Claude Code incident briefly gave the
        //   nested pane 119 columns by redistributing against the full container.
        // Scenario: a 179x66 root split evenly, then its right child splits down.
        let paneA = PaneId(), paneB = PaneId(), paneC = PaneId()
        let nestedSplit = SplitId()
        let tree = SplitNodeModel.split(
            id: SplitId(),
            direction: .horizontal,
            first: .leaf(PaneModel(id: paneA)),
            second: .split(
                id: nestedSplit,
                direction: .vertical,
                first: .leaf(PaneModel(id: paneB)),
                second: .leaf(PaneModel(id: paneC)),
                ratio: 0.5
            ),
            ratio: 0.5
        )

        let layout = paneLayout(
            in: PaneLayoutRect(x: 0, y: 0, width: 179, height: 66),
            tree: tree,
            zoomedPaneId: nil,
            metrics: PaneLayoutMetrics(minimumPaneExtent: 1, dividerThickness: 1)
        )
        let nestedDivider = try #require(layout.dividers[nestedSplit])
        let paneBFrame = try #require(layout.placements[paneB]?.visibleFrame)
        let paneCFrame = try #require(layout.placements[paneC]?.visibleFrame)

        #expect(nestedDivider.splitBounds.width == 89)
        #expect(paneBFrame.width == 89)
        #expect(paneCFrame.width == 89)
    }

    @Test("a clamped divider position round-trips through its ratio")
    func clampedDividerPositionRoundTrips() throws {
        // Intent: converting a dragged divider position to a ratio and laying
        //   out that ratio reproduces the same divider on both axes, including a clamp.
        // Why it exists: drag and layout must share one clamp or the divider
        //   jumps when the model round trip completes.
        // Scenario: a drag asks for 20pt in a 500pt split with a 100pt minimum.
        let paneA = PaneId(), paneB = PaneId(), splitId = SplitId()
        let bounds = PaneLayoutRect(x: 40, y: 10, width: 500, height: 300)
        let tree = SplitNodeModel.split(
            id: splitId,
            direction: .horizontal,
            first: .leaf(PaneModel(id: paneA)),
            second: .leaf(PaneModel(id: paneB)),
            ratio: 0.5
        )
        let ratio = paneSplitRatio(
            forDividerPosition: bounds.minX + 20,
            in: bounds,
            direction: .horizontal
        )
        let layout = paneLayout(
            in: bounds,
            tree: replacingRatio(in: tree, with: ratio),
            zoomedPaneId: nil
        )
        let divider = try #require(layout.dividers[splitId])

        #expect(divider.frame.minX == bounds.minX + 100)
        #expect(divider.ratio == ratio)

        let verticalSplitId = SplitId()
        let verticalTree = SplitNodeModel.split(
            id: verticalSplitId,
            direction: .vertical,
            first: .leaf(PaneModel(id: paneA)),
            second: .leaf(PaneModel(id: paneB)),
            ratio: 0.4
        )
        let desired = paneLayout(in: bounds, tree: verticalTree, zoomedPaneId: nil)
        let desiredDivider = try #require(desired.dividers[verticalSplitId])
        let verticalRatio = paneSplitRatio(
            forDividerPosition: desiredDivider.frame.maxY,
            in: bounds,
            direction: .vertical
        )
        let roundTripped = paneLayout(
            in: bounds,
            tree: replacingRatio(in: verticalTree, with: verticalRatio),
            zoomedPaneId: nil
        )
        #expect(roundTripped == desired)
    }

    @Test("minimum extent yields symmetrically when the split is too small")
    func minimumExtentYieldsSymmetrically() throws {
        // Intent: an undersized box gives both children equal non-zero extents
        //   while the children and divider still tile it exactly.
        // Why it exists: enforcing one pane's minimum at the other's expense
        //   can squeeze the other pane to zero and submit a false grid.
        // Scenario: an extreme restored ratio in a 151pt box with 100pt minima.
        let paneA = PaneId(), paneB = PaneId(), splitId = SplitId()
        let tree = SplitNodeModel.split(
            id: splitId,
            direction: .horizontal,
            first: .leaf(PaneModel(id: paneA)),
            second: .leaf(PaneModel(id: paneB)),
            ratio: 0.99
        )
        let bounds = PaneLayoutRect(x: 0, y: 0, width: 151, height: 80)

        let layout = paneLayout(in: bounds, tree: tree, zoomedPaneId: nil)
        let first = try #require(layout.placements[paneA]?.visibleFrame)
        let second = try #require(layout.placements[paneB]?.visibleFrame)
        let divider = try #require(layout.dividers[splitId])

        #expect(first.width == 75)
        #expect(second.width == 75)
        #expect(first.width > 0 && second.width > 0)
        #expect(first.union(divider.frame).union(second) == bounds)

        let tiny = paneLayout(
            in: PaneLayoutRect(x: 0, y: 0, width: 1, height: 80),
            tree: tree,
            zoomedPaneId: nil
        )
        let tinyFirst = try #require(tiny.placements[paneA]?.visibleFrame)
        let tinySecond = try #require(tiny.placements[paneB]?.visibleFrame)
        let tinyDivider = try #require(tiny.dividers[splitId])
        #expect(tinyFirst.width > 0 && tinySecond.width > 0)
        #expect(tinyFirst.union(tinyDivider.frame).union(tinySecond)
            == PaneLayoutRect(x: 0, y: 0, width: 1, height: 80))
    }

    @Test("restored extreme ratio clamps only while the box is small")
    func restoredExtremeRatioRecoversWhenBoundsGrow() throws {
        // Intent: layout clamps an extreme stored ratio without changing it,
        //   then returns to that proportion when larger bounds permit it.
        // Why it exists: AppKit's old ratio feedback permanently replaced the
        //   stored ratio with the clamped presentation.
        // Scenario: ratio 0.9 lays out in 301pt and then 1001pt boxes.
        let paneA = PaneId(), paneB = PaneId(), splitId = SplitId()
        let storedRatio: CGFloat = 0.9
        let tree = SplitNodeModel.split(
            id: splitId,
            direction: .horizontal,
            first: .leaf(PaneModel(id: paneA)),
            second: .leaf(PaneModel(id: paneB)),
            ratio: storedRatio
        )

        let small = paneLayout(
            in: PaneLayoutRect(x: 0, y: 0, width: 301, height: 80),
            tree: tree,
            zoomedPaneId: nil
        )
        let large = paneLayout(
            in: PaneLayoutRect(x: 0, y: 0, width: 1001, height: 80),
            tree: tree,
            zoomedPaneId: nil
        )

        #expect(try #require(small.placements[paneB]?.visibleFrame).width == 100)
        #expect(try #require(large.dividers[splitId]).ratio == storedRatio)
        #expect(try #require(large.placements[paneA]?.visibleFrame).width == 900)
    }

    @Test("zoom reports one full-size pane and hides the rest")
    func zoomIsTotalAndReversible() throws {
        // Intent: zoom fills the bounds with the selected pane, suppresses all
        //   dividers, and reports every other pane hidden without changing the tree.
        // Why it exists: zoom must be another pure layout case, not a second
        //   frame producer that detaches and pins a wrapper.
        // Scenario: zoom and unzoom the middle pane of a three-pane tree.
        let paneA = PaneId(), paneB = PaneId(), paneC = PaneId()
        let tree = SplitNodeModel.split(
            id: SplitId(),
            direction: .horizontal,
            first: .leaf(PaneModel(id: paneA)),
            second: .split(
                id: SplitId(),
                direction: .vertical,
                first: .leaf(PaneModel(id: paneB)),
                second: .leaf(PaneModel(id: paneC)),
                ratio: 0.5
            ),
            ratio: 0.5
        )
        let bounds = PaneLayoutRect(x: 0, y: 0, width: 801, height: 601)
        let before = paneLayout(in: bounds, tree: tree, zoomedPaneId: nil)
        let zoomed = paneLayout(in: bounds, tree: tree, zoomedPaneId: paneB)
        let after = paneLayout(in: bounds, tree: tree, zoomedPaneId: nil)

        #expect(zoomed.placements == [paneA: .hidden, paneB: .visible(bounds), paneC: .hidden])
        #expect(zoomed.dividers.isEmpty)
        #expect(after == before)
    }
}

private func verifyLayout(
    _ layout: PaneLayout,
    realizes tree: SplitNodeModel,
    in bounds: PaneLayoutRect,
    caseName: String,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    func verifyNode(_ node: SplitNodeModel, in expectedBounds: PaneLayoutRect) throws {
        switch node {
        case .leaf(let pane):
            #expect(layout.placements[pane.id] == .visible(expectedBounds),
                "\(caseName): pane does not fill its assigned box", sourceLocation: sourceLocation)
        case .split(let splitId, let direction, let first, let second, _):
            let placement = try #require(layout.dividers[splitId], sourceLocation: sourceLocation)
            #expect(placement.splitBounds == expectedBounds,
                "\(caseName): split does not use its parent box", sourceLocation: sourceLocation)
            #expect(
                placement.firstChildBounds.union(placement.frame).union(placement.secondChildBounds)
                    == expectedBounds,
                "\(caseName): children and divider do not tile the split",
                sourceLocation: sourceLocation
            )
            #expect(placement.firstChildBounds.intersects(placement.frame) == false,
                sourceLocation: sourceLocation)
            #expect(placement.firstChildBounds.intersects(placement.secondChildBounds) == false,
                sourceLocation: sourceLocation)
            #expect(placement.frame.intersects(placement.secondChildBounds) == false,
                sourceLocation: sourceLocation)
            switch direction {
            case .horizontal:
                #expect(placement.firstChildBounds.minX == expectedBounds.minX,
                    "\(caseName): first child is not left", sourceLocation: sourceLocation)
                #expect(placement.secondChildBounds.maxX == expectedBounds.maxX,
                    "\(caseName): second child is not right", sourceLocation: sourceLocation)
            case .vertical:
                #expect(placement.firstChildBounds.maxY == expectedBounds.maxY,
                    "\(caseName): first child is not top", sourceLocation: sourceLocation)
                #expect(placement.secondChildBounds.minY == expectedBounds.minY,
                    "\(caseName): second child is not bottom", sourceLocation: sourceLocation)
            }
            try verifyNode(first, in: placement.firstChildBounds)
            try verifyNode(second, in: placement.secondChildBounds)
        }
    }

    try verifyNode(tree, in: bounds)
    #expect(Set(layout.placements.keys) == Set(allPaneIds(tree)),
        "\(caseName): layout pane set differs from the tree", sourceLocation: sourceLocation)
    let allRects = layout.placements.values.compactMap(\.visibleFrame)
        + layout.dividers.values.map(\.frame)
    for (index, rect) in allRects.enumerated() {
        #expect(bounds.contains(rect), "\(caseName): rect escaped bounds", sourceLocation: sourceLocation)
        for other in allRects.dropFirst(index + 1) {
            #expect(rect.intersects(other) == false,
                "\(caseName): pane or divider rectangles overlap", sourceLocation: sourceLocation)
        }
    }
}

private extension PaneLayoutRect {
    func contains(_ other: PaneLayoutRect) -> Bool {
        other.minX >= minX && other.maxX <= maxX
            && other.minY >= minY && other.maxY <= maxY
    }

    func intersects(_ other: PaneLayoutRect) -> Bool {
        width > 0 && height > 0 && other.width > 0 && other.height > 0
            && minX < other.maxX && other.minX < maxX
            && minY < other.maxY && other.minY < maxY
    }

    func union(_ other: PaneLayoutRect) -> PaneLayoutRect {
        let unionMinX = min(minX, other.minX)
        let unionMinY = min(minY, other.minY)
        let unionMaxX = max(maxX, other.maxX)
        let unionMaxY = max(maxY, other.maxY)
        return PaneLayoutRect(
            x: unionMinX,
            y: unionMinY,
            width: unionMaxX - unionMinX,
            height: unionMaxY - unionMinY
        )
    }
}

private func replacingRatio(in node: SplitNodeModel, with ratio: CGFloat) -> SplitNodeModel {
    guard case .split(let id, let direction, let first, let second, _) = node else {
        return node
    }
    return .split(id: id, direction: direction, first: first, second: second, ratio: ratio)
}
