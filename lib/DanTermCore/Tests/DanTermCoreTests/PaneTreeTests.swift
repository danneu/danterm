// Direct behavioral coverage for PaneTree's focus, zoom, and shape invariants.
import Testing

@testable import DanTermCore

@Suite struct PaneTreeTests {
    @Test("construction repairs invalid focus and single-pane zoom")
    func constructionNormalizesInvalidState() {
        let pane = PaneModel(id: PaneId())

        let tree = PaneTree(
            root: .leaf(pane), focusedPaneId: PaneId(), isZoomed: true)

        #expect(tree.focusedPaneId == pane.id)
        #expect(tree.focusedPane.id == pane.id)
        #expect(tree.isZoomed == false)
    }

    @Test("payload updates and ratio changes preserve focus and zoom")
    func shapeNeutralMutationsPreserveFocusAndZoom() throws {
        let (first, second, splitId) = paneIdsAndSplit()
        var tree = splitTree(first: first, second: second, splitId: splitId, focused: second)
        _ = tree.zoom(second)

        let updated = tree.updatePane(first) { $0.theme = "Dracula" }
        tree.updateRatio(splitId: splitId, ratio: 0.25)

        #expect(updated)
        #expect(tree.focusedPaneId == second)
        #expect(tree.focusedPane.id == second)
        #expect(tree.isZoomed)
        #expect(try #require(paneInNode(tree.root, id: first)).theme == "Dracula")
        guard case .split(_, _, _, _, let ratio) = tree.root else {
            Issue.record("tree should remain split")
            return
        }
        #expect(ratio == 0.25)
    }

    @Test("foreground and background splits keep valid focus and clear zoom")
    func splitAppliesFocusPolicyAndClearsZoom() {
        let first = PaneId(), second = PaneId(), third = PaneId()
        var tree = splitTree(
            first: first, second: second, splitId: SplitId(), focused: first)
        _ = tree.zoom(first)

        let backgroundSplit = tree.split(
            paneId: second, direction: .vertical, newPane: PaneModel(id: third),
            newSplitId: SplitId(), focusNewPane: false)
        #expect(backgroundSplit)
        #expect(tree.focusedPaneId == first)
        #expect(tree.focusedPane.id == first)
        #expect(tree.isZoomed == false)

        let fourth = PaneId()
        let foregroundSplit = tree.split(
            paneId: third, direction: .horizontal, newPane: PaneModel(id: fourth),
            newSplitId: SplitId(), focusNewPane: true)
        #expect(foregroundSplit)
        #expect(tree.focusedPaneId == fourth)
        #expect(tree.focusedPane.id == fourth)
    }

    @Test("remove changes focus only for the focused pane and clears zoom")
    func removeAppliesFocusRule() throws {
        let first = PaneId(), second = PaneId(), third = PaneId()
        let nested: SplitNodeModel = .split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: first)),
            second: .split(
                id: SplitId(), direction: .vertical,
                first: .leaf(PaneModel(id: second)),
                second: .leaf(PaneModel(id: third)), ratio: 0.5),
            ratio: 0.5)
        var tree = PaneTree(root: nested, focusedPaneId: first, isZoomed: true)

        let backgroundResult = tree.remove(second)
        let backgroundRemoval = try #require(backgroundResult)
        #expect(backgroundRemoval.focusMoved == false)
        #expect(tree.focusedPaneId == first)
        #expect(tree.focusedPane.id == first)
        #expect(tree.isZoomed == false)

        let focusedResult = tree.remove(first)
        let focusedRemoval = try #require(focusedResult)
        #expect(focusedRemoval.focusMoved)
        #expect(tree.focusedPaneId == third)
        #expect(tree.focusedPane.id == third)

        let lastResult = tree.remove(third)
        let lastRemoval = try #require(lastResult)
        #expect(lastRemoval.emptiedTree)
        #expect(tree.focusedPane.id == third)
    }

    @Test("swap, move, and adopt focus the moved pane and clear zoom")
    func rearrangementsPreserveInvariant() {
        let first = PaneId(), second = PaneId()
        var swapped = splitTree(
            first: first, second: second, splitId: SplitId(), focused: second)
        _ = swapped.zoom(second)

        let didSwap = swapped.swap(source: first, target: second)
        #expect(didSwap)
        #expect(swapped.focusedPaneId == first)
        #expect(swapped.focusedPane.id == first)
        #expect(swapped.isZoomed == false)

        let third = PaneId()
        swapped.adopt(PaneModel(id: third), splitId: SplitId())
        #expect(swapped.focusedPaneId == third)
        #expect(swapped.focusedPane.id == third)

        let didMove = swapped.move(
            source: first, target: second, direction: .vertical,
            insertFirst: true, newSplitId: SplitId())
        #expect(didMove)
        #expect(swapped.focusedPaneId == first)
        #expect(swapped.focusedPane.id == first)
    }

    @Test("focus is zoom-neutral and rejects panes outside the tree")
    func focusPreservesZoom() {
        let first = PaneId(), second = PaneId()
        var tree = splitTree(
            first: first, second: second, splitId: SplitId(), focused: first)
        _ = tree.zoom(first)

        let didFocus = tree.focus(second)
        #expect(didFocus)
        #expect(tree.focusedPaneId == second)
        #expect(tree.focusedPane.id == second)
        #expect(tree.isZoomed)
        let didFocusForeign = tree.focus(PaneId())
        #expect(didFocusForeign == false)
        #expect(tree.focusedPaneId == second)
    }

    @Test("zoom needs a split tree, focuses the pane it names, and unzoom keeps that focus")
    func zoomRequiresSplitAndFocusesItsTarget() {
        // Intent: `zoom` refuses a lone leaf and a pane outside the tree, and
        //   on a split tree it makes the named pane both the zoomed and the
        //   focused pane; `unzoom` then leaves focus where the zoom put it.
        // Why it exists: zoom hides every sibling, so a zoomed pane that did
        //   not hold focus would send keystrokes to a hidden pane. Binding the
        //   focus move into the mutator is what keeps the two facts together.
        let pane = PaneId()
        var single = PaneTree(root: .leaf(PaneModel(id: pane)))
        let zoomedLoneLeaf = single.zoom(pane)
        #expect(zoomedLoneLeaf == false)
        #expect(single.isZoomed == false)
        #expect(single.zoomedPaneId == nil)

        let second = PaneId()
        var split = splitTree(
            first: pane, second: second, splitId: SplitId(), focused: second)
        let zoomedForeignPane = split.zoom(PaneId())
        #expect(zoomedForeignPane == false, "a pane outside the tree cannot be zoomed")
        #expect(split.isZoomed == false)

        let zoomedTarget = split.zoom(pane)
        #expect(zoomedTarget)
        #expect(split.zoomedPaneId == pane)
        #expect(split.focusedPane.id == pane, "the zoomed pane must hold focus")

        split.unzoom()
        #expect(split.zoomedPaneId == nil)
        #expect(split.focusedPane.id == pane)
    }
}

private func paneIdsAndSplit() -> (PaneId, PaneId, SplitId) {
    (PaneId(), PaneId(), SplitId())
}

private func splitTree(
    first: PaneId, second: PaneId, splitId: SplitId, focused: PaneId
) -> PaneTree {
    PaneTree(
        root: .split(
            id: splitId, direction: .horizontal,
            first: .leaf(PaneModel(id: first)),
            second: .leaf(PaneModel(id: second)), ratio: 0.5),
        focusedPaneId: focused)
}
