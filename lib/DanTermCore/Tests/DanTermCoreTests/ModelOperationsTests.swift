// Swift Testing migration of the legacy `tests/ModelOperationsTests.swift`
// harness suite. Pins the pure model-operations layer: split-tree queries
// (allPaneIds, firstLeafId/lastLeafId, nearestLeaf), structural rewrites
// (removeLeaf, swapLeaves, moveLeaf, setRatio), focus/visibility helpers,
// MRU reconciliation + live-cycle remapping, and every "desired*" projection
// (alerts, switcher, quit confirmation, focus borders, pane toolbar, search
// overlays, pane config, sidebar, window chrome) plus the tab-todo popover
// drop-target / bucket-step / reorder-step rules. The compound `guard case`
// destructuring patterns the harness used with `throw TestFailure` convert to
// `Issue.record + return` (one-for-one failure sites) so the per-file count
// stays exact. Cross-suite MRU fixture lives in TestSupport.swift.
import Foundation
import Testing

@testable import DanTermCore

private func makeVisibilityModel(tabs: [TabModel], selectedTabId: TabId?) -> AppModel {
    AppModel(
        groups: [GroupModel(id: GroupId(), name: "General", tabs: tabs)],
        selectedTabId: selectedTabId
    )
}

private func makeTwoPaneTabTodoRowsModel() -> (model: AppModel, tabId: TabId, paneA: PaneId, paneB: PaneId) {
    var model = makeModel()
    createTab(&model)
    let tabId = selectedTab(in: model)!.id
    let paneA = selectedTab(in: model)!.focusedPaneId
    update(&model, .splitPane(paneId: paneA, direction: .horizontal))
    let paneOrder = allPaneIds(selectedTab(in: model)!.rootNode)
    return (model, tabId, paneOrder[0], paneOrder[1])
}

@Suite struct ModelOperationsTests {

    // MARK: - allPaneIds

    @Test("testAllPaneIdsFlatLeaf")
    func testAllPaneIdsFlatLeaf() {
        // Intent: allPaneIds on a single leaf returns exactly that leaf's pane id.
        // Why it exists: pins the recursion base case so a refactor of the tree
        //   walker cannot drop the single-leaf input.
        // Scenario: spec-first base-case check -- a tab with one pane.
        let id = PaneId()
        let node = SplitNodeModel.leaf(PaneModel(id: id))
        let ids = allPaneIds(node)
        #expect(ids.count == 1)
        #expect(ids[0] == id)
    }

    @Test("testAllPaneIdsNestedTree")
    func testAllPaneIdsNestedTree() {
        // Intent: allPaneIds on a nested split returns every leaf's pane id.
        // Why it exists: pins the recursion's coverage so a tree-walk refactor
        //   that fails to descend a branch is caught.
        // Scenario: spec-first coverage check -- a horizontal split where the
        //   right child is itself a vertical split (three leaves total).
        let a = PaneId(), b = PaneId(), c = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .split(
                id: SplitId(), direction: .vertical,
                first: .leaf(PaneModel(id: b)),
                second: .leaf(PaneModel(id: c)),
                ratio: 0.5
            ),
            ratio: 0.5
        )
        let ids = allPaneIds(node)
        #expect(ids.count == 3)
        #expect(ids.contains(a))
        #expect(ids.contains(b))
        #expect(ids.contains(c))
    }

    // MARK: - effectiveSurfaceVisibility

    @Test("effectiveSurfaceVisibility marks every reachable pane hidden when window is hidden")
    func effectiveSurfaceVisibilityHidesAllWhenWindowHidden() {
        // Intent: with windowVisible: false, every pane in every tab is hidden.
        // Why it exists: pins the window-hidden short-circuit so a refactor
        //   cannot accidentally leak per-tab visibility decisions when the
        //   window itself is occluded.
        // Scenario: spec-first window-hidden check -- two tabs, one split,
        //   window not visible; all three panes report hidden.
        let a = PaneId(), b = PaneId(), c = PaneId()
        let tabAId = TabId(), tabBId = TabId()
        let tabA = TabModel(
            id: tabAId,
            focusedPaneId: a,
            rootNode: .split(
                id: SplitId(), direction: .horizontal,
                first: .leaf(PaneModel(id: a)),
                second: .leaf(PaneModel(id: b)),
                ratio: 0.5
            )
        )
        let tabB = TabModel(id: tabBId, focusedPaneId: c, rootNode: .leaf(PaneModel(id: c)))
        let model = makeVisibilityModel(tabs: [tabA, tabB], selectedTabId: tabAId)

        let visibility = effectiveSurfaceVisibility(in: model, windowVisible: false)

        #expect(visibility == [a: false, b: false, c: false])
    }

    @Test("effectiveSurfaceVisibility marks a selected single-pane tab visible")
    func effectiveSurfaceVisibilityVisibleSinglePane() {
        // Intent: a selected single-pane tab reports its pane visible.
        // Why it exists: pins the happy path of the visibility projection.
        // Scenario: spec-first single-pane check -- one tab, one pane, window
        //   visible.
        let paneId = PaneId()
        let tabId = TabId()
        let tab = TabModel(id: tabId, focusedPaneId: paneId, rootNode: .leaf(PaneModel(id: paneId)))
        let model = makeVisibilityModel(tabs: [tab], selectedTabId: tabId)

        let visibility = effectiveSurfaceVisibility(in: model, windowVisible: true)

        #expect(visibility == [paneId: true])
    }

    @Test("effectiveSurfaceVisibility hides panes in non-selected tabs")
    func effectiveSurfaceVisibilityHidesNonSelectedTabs() {
        // Intent: panes in a non-selected tab are hidden even when the window
        //   is visible.
        // Why it exists: pins per-tab scoping so background-tab surfaces stay
        //   hidden until selected.
        // Scenario: spec-first scoping check -- two tabs (selected split,
        //   background single-pane); the background pane reports hidden.
        let selectedA = PaneId(), selectedB = PaneId(), background = PaneId()
        let selectedTabId = TabId(), backgroundTabId = TabId()
        let selectedTab = TabModel(
            id: selectedTabId,
            focusedPaneId: selectedA,
            rootNode: .split(
                id: SplitId(), direction: .horizontal,
                first: .leaf(PaneModel(id: selectedA)),
                second: .leaf(PaneModel(id: selectedB)),
                ratio: 0.5
            )
        )
        let backgroundTab = TabModel(
            id: backgroundTabId,
            focusedPaneId: background,
            rootNode: .leaf(PaneModel(id: background))
        )
        let model = makeVisibilityModel(tabs: [selectedTab, backgroundTab], selectedTabId: selectedTabId)

        let visibility = effectiveSurfaceVisibility(in: model, windowVisible: true)

        #expect(visibility == [selectedA: true, selectedB: true, background: false])
    }

    @Test("effectiveSurfaceVisibility hides zoomed sibling panes")
    func effectiveSurfaceVisibilityHidesZoomedSiblings() {
        // Intent: when a tab is zoomed, only the focused pane is visible; its
        //   siblings hide.
        // Why it exists: pins the zoom contract that drives surface render
        //   suspension on hidden siblings.
        // Scenario: spec-first zoom check -- a split tab with isZoomed=true
        //   reports the focused pane visible and the sibling hidden.
        let focused = PaneId(), sibling = PaneId()
        let tabId = TabId()
        let tab = TabModel(
            id: tabId,
            focusedPaneId: focused,
            rootNode: .split(
                id: SplitId(), direction: .horizontal,
                first: .leaf(PaneModel(id: focused)),
                second: .leaf(PaneModel(id: sibling)),
                ratio: 0.5
            ),
            isZoomed: true
        )
        let model = makeVisibilityModel(tabs: [tab], selectedTabId: tabId)

        let visibility = effectiveSurfaceVisibility(in: model, windowVisible: true)

        #expect(visibility == [focused: true, sibling: false])
    }

    @Test("effectiveSurfaceVisibility keeps a zoomed single-pane tab visible")
    func effectiveSurfaceVisibilityZoomedSinglePaneVisible() {
        // Intent: zoom on a single-pane tab keeps the pane visible (no
        //   siblings to hide).
        // Why it exists: pins the zoom corner case that hits the same code
        //   path as a split-tab zoom but with one leaf.
        // Scenario: spec-first zoom corner case -- a zoomed single-pane tab
        //   reports the pane visible.
        let paneId = PaneId()
        let tabId = TabId()
        let tab = TabModel(
            id: tabId,
            focusedPaneId: paneId,
            rootNode: .leaf(PaneModel(id: paneId)),
            isZoomed: true
        )
        let model = makeVisibilityModel(tabs: [tab], selectedTabId: tabId)

        let visibility = effectiveSurfaceVisibility(in: model, windowVisible: true)

        #expect(visibility == [paneId: true])
    }

    @Test("effectiveSurfaceVisibility hides every pane when there is no selected tab")
    func effectiveSurfaceVisibilityNoSelectedHidesAll() {
        // Intent: with selectedTabId nil, every pane is hidden even on a
        //   visible window.
        // Why it exists: pins the "no selection" guard against accidental
        //   visibility leaks during transient empty-selection states.
        // Scenario: spec-first empty-selection check -- a single split tab,
        //   selectedTabId nil; both panes report hidden.
        let a = PaneId(), b = PaneId()
        let tabId = TabId()
        let tab = TabModel(
            id: tabId,
            focusedPaneId: a,
            rootNode: .split(
                id: SplitId(), direction: .horizontal,
                first: .leaf(PaneModel(id: a)),
                second: .leaf(PaneModel(id: b)),
                ratio: 0.5
            )
        )
        let model = makeVisibilityModel(tabs: [tab], selectedTabId: nil)

        let visibility = effectiveSurfaceVisibility(in: model, windowVisible: true)

        #expect(visibility == [a: false, b: false])
    }

    @Test("effectiveSurfaceVisibility marks every selected nested split leaf visible")
    func effectiveSurfaceVisibilityNestedSplitAllVisible() {
        // Intent: every leaf in the selected tab's nested split tree is
        //   visible (when not zoomed).
        // Why it exists: pins the visibility walker's coverage of nested
        //   splits so an off-by-one in recursion is caught.
        // Scenario: spec-first deep-tree check -- three leaves under a nested
        //   horizontal/vertical split all report visible.
        let a = PaneId(), b = PaneId(), c = PaneId()
        let tabId = TabId()
        let tab = TabModel(
            id: tabId,
            focusedPaneId: a,
            rootNode: .split(
                id: SplitId(), direction: .horizontal,
                first: .leaf(PaneModel(id: a)),
                second: .split(
                    id: SplitId(), direction: .vertical,
                    first: .leaf(PaneModel(id: b)),
                    second: .leaf(PaneModel(id: c)),
                    ratio: 0.5
                ),
                ratio: 0.5
            )
        )
        let model = makeVisibilityModel(tabs: [tab], selectedTabId: tabId)

        let visibility = effectiveSurfaceVisibility(in: model, windowVisible: true)

        #expect(visibility == [a: true, b: true, c: true])
    }

    // MARK: - firstLeafId / lastLeafId

    @Test("testFirstLeafId")
    func testFirstLeafId() {
        // Intent: firstLeafId returns the deepest first-child leaf id in a
        //   nested tree.
        // Why it exists: pins the leftmost-traversal contract focus helpers
        //   rely on after structural rewrites.
        // Scenario: spec-first traversal check -- in [[A, B], C], firstLeafId
        //   is A.
        let a = PaneId(), b = PaneId(), c = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .split(
                id: SplitId(), direction: .vertical,
                first: .leaf(PaneModel(id: a)),
                second: .leaf(PaneModel(id: b)),
                ratio: 0.5
            ),
            second: .leaf(PaneModel(id: c)),
            ratio: 0.5
        )
        #expect(firstLeafId(node) == a)
    }

    @Test("testLastLeafId")
    func testLastLeafId() {
        // Intent: lastLeafId returns the deepest second-child leaf id in a
        //   nested tree.
        // Why it exists: pins the rightmost-traversal contract focus helpers
        //   use for tail navigation.
        // Scenario: spec-first traversal check -- in [A, [B, C]], lastLeafId
        //   is C.
        let a = PaneId(), b = PaneId(), c = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .split(
                id: SplitId(), direction: .vertical,
                first: .leaf(PaneModel(id: b)),
                second: .leaf(PaneModel(id: c)),
                ratio: 0.5
            ),
            ratio: 0.5
        )
        #expect(lastLeafId(node) == c)
    }

    // MARK: - splitLeaf

    @Test("testSplitLeafNotFound")
    func testSplitLeafNotFound() {
        // Intent: splitLeaf with an unknown paneId returns nil (no panic, no
        //   accidental insertion).
        // Why it exists: pins fail-closed behavior so a stale split request
        //   becomes a no-op rather than a corrupted tree.
        // Scenario: spec-first error check -- caller asks to split a pane id
        //   that isn't in the tree.
        let a = PaneId()
        let node = SplitNodeModel.leaf(PaneModel(id: a))
        let result = splitLeaf(
            node,
            paneId: PaneId(),
            direction: .horizontal,
            newPane: PaneModel(id: PaneId()),
            newSplitId: SplitId()
        )
        #expect(result == nil, "should return nil for unknown paneId")
    }

    // MARK: - removeLeaf

    @Test("testRemoveLeafRootLeaf")
    func testRemoveLeafRootLeaf() {
        // Intent: removing the root leaf returns nil tree and nil focus.
        // Why it exists: pins the empty-tab termination contract closePane
        //   relies on to know the tab itself should be removed.
        // Scenario: spec-first close-last-pane check -- removing the only
        //   pane returns (nil, nil, _).
        let a = PaneId()
        let node = SplitNodeModel.leaf(PaneModel(id: a))
        let (newTree, nextFocus, _) = removeLeaf(node, paneId: a)
        #expect(newTree == nil, "removing root leaf should return nil tree")
        #expect(nextFocus == nil, "removing root leaf should return nil focus")
    }

    @Test("testRemoveLeafDeepTree")
    func testRemoveLeafDeepTree() {
        // Intent: removing a leaf inside a nested split collapses its parent
        //   split to the surviving sibling and reports the next focus.
        // Why it exists: pins the collapse-on-removal invariant: after
        //   closing one of two siblings, the remaining sibling promotes in
        //   place of the now-empty split.
        // Scenario: spec-first sibling-collapse check -- in [A, [B, C]],
        //   removing B yields [A, C] and nextFocus = C.
        let a = PaneId(), b = PaneId(), c = PaneId()
        let inner = SplitNodeModel.split(
            id: SplitId(), direction: .vertical,
            first: .leaf(PaneModel(id: b)),
            second: .leaf(PaneModel(id: c)),
            ratio: 0.5
        )
        let root = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: inner,
            ratio: 0.5
        )

        let (newTree, nextFocus, _) = removeLeaf(root, paneId: b)
        #expect(newTree != nil, "tree should not be nil")
        guard case .split(_, .horizontal, let first, let second, _) = newTree! else {
            Issue.record("should be a horizontal split")
            return
        }
        if case .leaf(let fpane) = first {
            #expect(fpane.id == a)
        } else {
            Issue.record("first should be leaf A")
            return
        }
        if case .leaf(let spane) = second {
            #expect(spane.id == c)
        } else {
            Issue.record("second should be leaf C (promoted)")
            return
        }
        #expect(nextFocus == c, "next focus should be C (first leaf of sibling)")
    }

    // MARK: - nearestLeaf

    @Test("testNearestLeafSimple")
    func testNearestLeafSimple() {
        // Intent: in a horizontal split [A, B], nearestLeaf finds B from A
        //   going right and A from B going left.
        // Why it exists: pins the direction-aware neighbor lookup focus
        //   navigation uses.
        // Scenario: spec-first directional-focus check.
        let a = PaneId(), b = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.5
        )
        #expect(nearestLeaf(node, from: a, direction: .horizontal, side: .second) == b)
        #expect(nearestLeaf(node, from: b, direction: .horizontal, side: .first) == a)
    }

    @Test("testNearestLeafVertical")
    func testNearestLeafVertical() {
        // Intent: in a vertical split [A, B], nearestLeaf finds B going down
        //   and A going up.
        // Why it exists: pins the same direction-aware lookup as the
        //   horizontal case but along the orthogonal axis.
        // Scenario: spec-first directional-focus check (vertical).
        let a = PaneId(), b = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .vertical,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.5
        )
        #expect(nearestLeaf(node, from: a, direction: .vertical, side: .second) == b)
        #expect(nearestLeaf(node, from: b, direction: .vertical, side: .first) == a)
    }

    @Test("testNearestLeafNestedLShape")
    func testNearestLeafNestedLShape() {
        // Intent: directional lookup descends into nested splits to find
        //   the closest leaf in the requested direction.
        // Why it exists: pins the multi-level descent the L-shape ([A, [B,
        //   C]]) hits so focus navigation jumps across nesting boundaries.
        // Scenario: spec-first nested-tree check -- four direction queries
        //   on an L-shape resolve to neighbors across the split boundary.
        let a = PaneId(), b = PaneId(), c = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .split(
                id: SplitId(), direction: .vertical,
                first: .leaf(PaneModel(id: b)),
                second: .leaf(PaneModel(id: c)),
                ratio: 0.5
            ),
            ratio: 0.5
        )
        #expect(nearestLeaf(node, from: b, direction: .horizontal, side: .first) == a)
        #expect(nearestLeaf(node, from: c, direction: .horizontal, side: .first) == a)
        #expect(nearestLeaf(node, from: a, direction: .horizontal, side: .second) == b)
        #expect(nearestLeaf(node, from: b, direction: .vertical, side: .second) == c)
    }

    @Test("testNearestLeafNoNeighbor")
    func testNearestLeafNoNeighbor() {
        // Intent: nearestLeaf returns nil at the edge of the tree or for the
        //   wrong axis.
        // Why it exists: pins the "no neighbor" guard so focus navigation at
        //   the edge stays a no-op rather than wrapping or panicking.
        // Scenario: spec-first edge check -- in [A, B], A has no leftward
        //   neighbor; a vertical query on a horizontal split also has none.
        let a = PaneId(), b = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.5
        )
        #expect(nearestLeaf(node, from: a, direction: .horizontal, side: .first) == nil, "should return nil at edge")
        #expect(nearestLeaf(node, from: a, direction: .vertical, side: .second) == nil, "should return nil for wrong direction")
    }

    @Test("testNearestLeaf2x2GridPreservesPerpendicularPosition")
    func testNearestLeaf2x2GridPreservesPerpendicularPosition() {
        // Intent: in a 2x2 grid, directional movement preserves the
        //   perpendicular position (move right from TR -> TL, not BL).
        // Why it exists: pins the "same row" invariant for grid navigation
        //   that earlier versions broke by descending into the first leaf of
        //   the sibling regardless of position.
        // Scenario: spec-first grid-navigation check -- four directional
        //   queries on a horizontal split of two vertical columns.
        let tl = PaneId(), tr = PaneId(), bl = PaneId(), br = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .split(
                id: SplitId(), direction: .vertical,
                first: .leaf(PaneModel(id: tl)),
                second: .leaf(PaneModel(id: bl)),
                ratio: 0.5
            ),
            second: .split(
                id: SplitId(), direction: .vertical,
                first: .leaf(PaneModel(id: tr)),
                second: .leaf(PaneModel(id: br)),
                ratio: 0.5
            ),
            ratio: 0.5
        )
        #expect(nearestLeaf(node, from: tr, direction: .horizontal, side: .first) == tl)
        #expect(nearestLeaf(node, from: br, direction: .horizontal, side: .first) == bl)
        #expect(nearestLeaf(node, from: tl, direction: .horizontal, side: .second) == tr)
        #expect(nearestLeaf(node, from: bl, direction: .horizontal, side: .second) == br)
    }

    // MARK: - setRatio

    @Test("testSetRatio")
    func testSetRatio() {
        // Intent: setRatio updates only the targeted split's ratio.
        // Why it exists: pins the immutable rebuild path that divider drags
        //   exercise on a single split.
        // Scenario: spec-first divider-drag check -- a single split's ratio
        //   updates from 0.5 to 0.7.
        let splitId = SplitId()
        let a = PaneId(), b = PaneId()
        let node = SplitNodeModel.split(
            id: splitId, direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.5
        )
        let updated = setRatio(node, splitId: splitId, ratio: 0.7)
        guard case .split(_, _, _, _, let ratio) = updated else {
            Issue.record("should be a split")
            return
        }
        #expect(ratio == 0.7)
    }

    @Test("testSetRatioLeavesOthersUnchanged")
    func testSetRatioLeavesOthersUnchanged() {
        // Intent: setRatio on a nested split leaves the outer split's ratio
        //   untouched.
        // Why it exists: pins the targeted-split invariant so a divider drag
        //   on one split cannot accidentally rebalance siblings.
        // Scenario: spec-first scoped-mutation check -- updating the inner
        //   split's ratio does not touch the outer split's.
        let splitId1 = SplitId(), splitId2 = SplitId()
        let a = PaneId(), b = PaneId(), c = PaneId()
        let node = SplitNodeModel.split(
            id: splitId1, direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .split(
                id: splitId2, direction: .vertical,
                first: .leaf(PaneModel(id: b)),
                second: .leaf(PaneModel(id: c)),
                ratio: 0.5
            ),
            ratio: 0.5
        )
        let updated = setRatio(node, splitId: splitId2, ratio: 0.3)
        guard case .split(_, _, _, let second, let outerRatio) = updated else {
            Issue.record("should be a split")
            return
        }
        #expect(outerRatio == 0.5, "outer ratio unchanged")
        guard case .split(_, _, _, _, let innerRatio) = second else {
            Issue.record("inner should be a split")
            return
        }
        #expect(innerRatio == 0.3, "inner ratio updated")
    }

    // MARK: - totalTabCount

    @Test("testTotalTabCountEmpty")
    func testTotalTabCountEmpty() {
        // Intent: totalTabCount on an empty model is 0.
        // Why it exists: pins the empty base case for window-chrome badges.
        // Scenario: spec-first empty-model check -- fresh model with no
        //   tabs.
        let model = makeModel()
        #expect(totalTabCount(model) == 0)
    }

    @Test("testTotalTabCountSingleTab")
    func testTotalTabCountSingleTab() {
        // Intent: totalTabCount reports 1 after a single createTab.
        // Why it exists: pins the simplest non-zero count.
        // Scenario: spec-first single-tab check.
        var model = makeModel()
        createTab(&model)
        #expect(totalTabCount(model) == 1)
    }

    @Test("testTotalTabCountMultipleGroups")
    func testTotalTabCountMultipleGroups() {
        // Intent: totalTabCount sums tabs across groups (createGroup
        //   auto-creates a tab).
        // Why it exists: pins the cross-group rollup window-chrome and the
        //   sidebar badge depend on.
        // Scenario: spec-first multi-group rollup -- two manual creates plus
        //   the createGroup auto-tab = 3 total.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        update(&model, .createGroup(name: "Work"))
        #expect(totalTabCount(model) == 3)
    }

    // MARK: - isFocusedAndVisible

    @Test("testIsFocusedAndVisible")
    func testIsFocusedAndVisible() {
        // Intent: isFocusedAndVisible returns true only for the focused pane
        //   of the selected split tab (not single-pane, not background).
        // Why it exists: pins the green focus-border rule applied to the
        //   pane (single-pane tabs draw no border; background panes don't
        //   either).
        // Scenario: spec-first focus-border check -- split selected tab has
        //   one true, sibling false; new single-pane tab is also false.
        var model = makeModel()
        createTab(&model)
        let firstPaneId = selectedTab(in: model)!.focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let focusedSplitPaneId = selectedTab(in: model)!.focusedPaneId

        #expect(isFocusedAndVisible(focusedSplitPaneId, in: model), "focused pane in selected split tab should be visible")
        #expect(!isFocusedAndVisible(firstPaneId, in: model), "non-focused pane should not be focused and visible")

        createTab(&model)
        let singlePaneId = selectedTab(in: model)!.focusedPaneId

        #expect(!isFocusedAndVisible(singlePaneId, in: model), "focused pane in single-pane tab should not show a focus border")
        #expect(!isFocusedAndVisible(focusedSplitPaneId, in: model), "pane in non-selected tab should not be focused and visible")
    }

    // MARK: - swapLeaves

    @Test("testSwapLeavesSimple")
    func testSwapLeavesSimple() {
        // Intent: swapLeaves swaps two leaves in a single split, preserving
        //   the split's id and ratio.
        // Why it exists: pins that drag-to-swap keeps the surrounding split
        //   structure intact; only the leaves trade positions.
        // Scenario: spec-first swap check -- in [A, B] with ratio 0.6,
        //   swapping yields [B, A] with the same id and ratio.
        let a = PaneId(), b = PaneId()
        let splitId = SplitId()
        let node = SplitNodeModel.split(
            id: splitId, direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.6
        )
        let result = swapLeaves(node, a, b)
        #expect(result != nil, "should return non-nil")
        guard case .split(let rSplitId, .horizontal, let first, let second, let ratio) = result! else {
            Issue.record("should be a horizontal split")
            return
        }
        #expect(rSplitId == splitId, "split id preserved")
        #expect(ratio == 0.6, "ratio preserved")
        if case .leaf(let fpane) = first { #expect(fpane.id == b) }
        else { Issue.record("first should be leaf B"); return }
        if case .leaf(let spane) = second { #expect(spane.id == a) }
        else { Issue.record("second should be leaf A"); return }
    }

    @Test("testSwapLeavesNested")
    func testSwapLeavesNested() {
        // Intent: swapLeaves across nested splits preserves both splits'
        //   ids and ratios.
        // Why it exists: pins the multi-level rewrite where the source and
        //   target are not siblings; ids/ratios must stay frozen at both
        //   levels.
        // Scenario: spec-first cross-level swap -- in [A, [B, C]] swapping
        //   A with C yields [C, [B, A]] with all ids/ratios preserved.
        let a = PaneId(), b = PaneId(), c = PaneId()
        let innerSplitId = SplitId()
        let outerSplitId = SplitId()
        let node = SplitNodeModel.split(
            id: outerSplitId, direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .split(
                id: innerSplitId, direction: .vertical,
                first: .leaf(PaneModel(id: b)),
                second: .leaf(PaneModel(id: c)),
                ratio: 0.3
            ),
            ratio: 0.7
        )
        let result = swapLeaves(node, a, c)!
        guard case .split(let rOuterId, .horizontal, let first, let second, let outerRatio) = result else {
            Issue.record("should be outer split")
            return
        }
        #expect(rOuterId == outerSplitId, "outer split id preserved")
        #expect(outerRatio == 0.7, "outer ratio preserved")
        if case .leaf(let fpane) = first { #expect(fpane.id == c, "first should now be C") }
        else { Issue.record("first should be a leaf"); return }
        guard case .split(let rInnerId, .vertical, let innerFirst, let innerSecond, let innerRatio) = second else {
            Issue.record("second should be inner split")
            return
        }
        #expect(rInnerId == innerSplitId, "inner split id preserved")
        #expect(innerRatio == 0.3, "inner ratio preserved")
        if case .leaf(let fpane) = innerFirst { #expect(fpane.id == b, "inner first still B") }
        else { Issue.record("inner first should be leaf"); return }
        if case .leaf(let spane) = innerSecond { #expect(spane.id == a, "inner second now A") }
        else { Issue.record("inner second should be leaf"); return }
    }

    @Test("testSwapLeavesSamePane")
    func testSwapLeavesSamePane() {
        // Intent: swapping a pane with itself returns nil.
        // Why it exists: pins the identity guard so a no-op drag onto the
        //   source becomes a model-untouched nil.
        // Scenario: spec-first no-op guard -- swap(A, A) on a single-leaf
        //   tree.
        let a = PaneId()
        let node = SplitNodeModel.leaf(PaneModel(id: a))
        #expect(swapLeaves(node, a, a) == nil, "same pane returns nil")
    }

    @Test("testSwapLeavesMissingPane")
    func testSwapLeavesMissingPane() {
        // Intent: swap returns nil when one of the panes is absent.
        // Why it exists: pins fail-closed for stale drag targets.
        // Scenario: spec-first stale-target check -- swap with an unknown
        //   id returns nil.
        let a = PaneId(), b = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.5
        )
        #expect(swapLeaves(node, a, PaneId()) == nil, "missing pane returns nil")
    }

    // MARK: - moveLeaf

    @Test("testMoveLeafLeftInsert")
    func testMoveLeafLeftInsert() {
        // Intent: moveLeaf with insertFirst=true positions the source as
        //   the new first child relative to the target.
        // Why it exists: pins the drop-on-left-edge semantics drag/drop
        //   relies on.
        // Scenario: spec-first left-insert -- moving A "left of" B in
        //   [A, B] yields a tree whose first leaf is A.
        let a = PaneId(), b = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.5
        )
        let result = moveLeaf(
            node, source: a, target: b, direction: .horizontal, insertFirst: true, newSplitId: SplitId())
        #expect(result != nil, "should succeed")
        let ids = allPaneIds(result!)
        #expect(ids.count == 2)
        #expect(ids.contains(a))
        #expect(ids.contains(b))
        #expect(firstLeafId(result!) == a, "A should be first")
    }

    @Test("testMoveLeafRightInsert")
    func testMoveLeafRightInsert() {
        // Intent: moveLeaf with insertFirst=false positions the source as
        //   the second child relative to the target.
        // Why it exists: pins the drop-on-right-edge semantics drag/drop
        //   relies on.
        // Scenario: spec-first right-insert -- moving A "right of" B in
        //   [A, B] yields a tree whose last leaf is A.
        let a = PaneId(), b = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.5
        )
        let result = moveLeaf(
            node, source: a, target: b, direction: .horizontal, insertFirst: false, newSplitId: SplitId())
        #expect(result != nil, "should succeed")
        #expect(lastLeafId(result!) == a, "A should be last")
    }

    @Test("testMoveLeafFromNestedTree")
    func testMoveLeafFromNestedTree() {
        // Intent: moveLeaf removes the source from a nested subtree
        //   (collapsing it as needed) and inserts it at the target.
        // Why it exists: pins the remove+insert composition the
        //   higher-level move helpers thread through.
        // Scenario: spec-first nested-move -- in [A, [B, C]], moving B to
        //   top of A yields a tree whose first leaf is B.
        let a = PaneId(), b = PaneId(), c = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .split(
                id: SplitId(), direction: .vertical,
                first: .leaf(PaneModel(id: b)),
                second: .leaf(PaneModel(id: c)),
                ratio: 0.5
            ),
            ratio: 0.5
        )
        let result = moveLeaf(
            node, source: b, target: a, direction: .vertical, insertFirst: true, newSplitId: SplitId())!
        let ids = allPaneIds(result)
        #expect(ids.count == 3, "all three panes preserved")
        #expect(firstLeafId(result) == b, "B should be first (top-left)")
    }

    @Test("testMoveLeafUsesSuppliedSplitId")
    func testMoveLeafUsesSuppliedSplitId() {
        // Intent: moveLeaf forms a split around the inserted leaf using the
        //   caller-supplied split id with the default 0.5 ratio.
        // Why it exists: pins split-id ownership at the update() caller so the
        //   pure tree helper stays deterministic and env-free.
        // Scenario: spec-first split-id check -- moving A across direction
        //   yields a split with the supplied id and ratio 0.5.
        let a = PaneId(), b = PaneId()
        let origSplitId = SplitId()
        let insertedSplitId = SplitId()
        let node = SplitNodeModel.split(
            id: origSplitId, direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.5
        )
        let result = moveLeaf(
            node,
            source: a,
            target: b,
            direction: .vertical,
            insertFirst: true,
            newSplitId: insertedSplitId
        )!
        guard case .split(let newSplitId, .vertical, _, _, let ratio) = result else {
            Issue.record("should be a vertical split")
            return
        }
        #expect(ratio == 0.5, "new split has ratio 0.5")
        #expect(newSplitId == insertedSplitId, "new split should use the supplied ID")
        #expect(newSplitId != origSplitId, "new split should not reuse the stale outer ID")
    }

    @Test("testMoveLeafSameSourceTarget")
    func testMoveLeafSameSourceTarget() {
        // Intent: moveLeaf with source == target returns nil (no-op).
        // Why it exists: pins the identity guard against drag-onto-self.
        // Scenario: spec-first no-op guard.
        let a = PaneId()
        let node = SplitNodeModel.leaf(PaneModel(id: a))
        #expect(
            moveLeaf(
                node, source: a, target: a, direction: .horizontal, insertFirst: true, newSplitId: SplitId()
            ) == nil,
            "same source/target returns nil"
        )
    }

    @Test("testMoveLeafMissingSource")
    func testMoveLeafMissingSource() {
        // Intent: moveLeaf with an unknown source returns nil.
        // Why it exists: pins fail-closed for stale source ids.
        // Scenario: spec-first stale-source check.
        let a = PaneId(), b = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.5
        )
        #expect(
            moveLeaf(
                node, source: PaneId(), target: b, direction: .horizontal, insertFirst: true,
                newSplitId: SplitId()
            ) == nil,
            "missing source returns nil"
        )
    }

    @Test("testMoveLeafMissingTarget")
    func testMoveLeafMissingTarget() {
        // Intent: moveLeaf with an unknown target returns nil after the
        //   source has been removed in the trial walk.
        // Why it exists: pins the symmetric stale-target guard.
        // Scenario: spec-first stale-target check.
        let a = PaneId(), b = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.5
        )
        #expect(
            moveLeaf(
                node, source: a, target: PaneId(), direction: .horizontal, insertFirst: true,
                newSplitId: SplitId()
            ) == nil,
            "missing target returns nil"
        )
    }

    // MARK: - abbreviateHome

    @Test("testAbbreviateHome")
    func testAbbreviateHome() {
        // Intent: abbreviateHome substitutes ~ for $HOME and leaves
        //   non-home paths untouched.
        // Why it exists: pins the title/subtitle abbreviation used in tab
        //   chrome and pane toolbars.
        // Scenario: spec-first abbreviation check -- $HOME/projects, an
        //   unrelated /tmp path, and bare $HOME.
        let home = NSHomeDirectory()
        #expect(abbreviateHome(home + "/projects") == "~/projects")
        #expect(abbreviateHome("/tmp/foo") == "/tmp/foo")
        #expect(abbreviateHome(home) == "~")
    }

    // MARK: - deleteGroupAction

    @Test("testDeleteGroupActionEmptyGroup")
    func testDeleteGroupActionEmptyGroup() {
        // Intent: deleting an empty group skips confirmation
        //   (.deleteImmediately).
        // Why it exists: pins the no-tabs branch that bypasses the user
        //   prompt.
        // Scenario: spec-first no-tabs check -- a directly constructed empty
        //   group resolves to .deleteImmediately.
        var model = makeModel()
        createTab(&model)
        let workGroupId = GroupId()
        model.groups.append(GroupModel(id: workGroupId, name: "Work"))
        let action = deleteGroupAction(for: workGroupId, in: model)
        guard case .deleteImmediately(let gid) = action else {
            Issue.record("expected .deleteImmediately, got \(String(describing: action))")
            return
        }
        #expect(gid == workGroupId)
    }

    @Test("testDeleteGroupActionGroupWithTabs")
    func testDeleteGroupActionGroupWithTabs() {
        // Intent: deleting a group with tabs surfaces a confirm action
        //   carrying the group id, name, and tab count.
        // Why it exists: pins the data the confirm panel renders.
        // Scenario: spec-first confirmation payload -- a group with one
        //   auto-created tab resolves to .confirm(name="Work", count=1).
        var model = makeModel()
        update(&model, .createGroup(name: "Work"))
        let workGroup = model.groups.first(where: { $0.name == "Work" })!
        let action = deleteGroupAction(for: workGroup.id, in: model)
        guard case .confirm(let gid, let name, let tabCount) = action else {
            Issue.record("expected .confirm, got \(String(describing: action))")
            return
        }
        #expect(gid == workGroup.id)
        #expect(name == "Work")
        #expect(tabCount == 1)
    }

    @Test("testDeleteGroupActionLastGroup")
    func testDeleteGroupActionLastGroup() {
        // Intent: deleting the last remaining group returns nil (no-op).
        // Why it exists: pins the invariant that the model always has at
        //   least one group.
        // Scenario: spec-first last-group guard.
        let model = makeModel()
        let onlyGroup = model.groups[0]
        let action = deleteGroupAction(for: onlyGroup.id, in: model)
        #expect(action == nil, "last remaining group should return nil")
    }

    // MARK: - bellCount / groupBellCount

    @Test("testUnreadAlertCount")
    func testUnreadAlertCount() {
        // Intent: unreadAlertCount sums unread alerts whose paneId is in
        //   the tab's tree.
        // Why it exists: pins the tab-level rollup the sidebar bell badge
        //   reads.
        // Scenario: spec-first rollup -- a two-pane tab with one alert per
        //   pane reports 2 unread.
        let a = PaneId(), b = PaneId()
        let tabId = TabId()
        let tab = TabModel(
            id: tabId,
            focusedPaneId: a,
            rootNode: .split(
                id: SplitId(), direction: .horizontal,
                first: .leaf(PaneModel(id: a)),
                second: .leaf(PaneModel(id: b)),
                ratio: 0.5
            )
        )
        var alerts: [AlertModel] = []
        #expect(unreadAlertCount(for: tab, alerts: alerts) == 0)

        alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: a,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)
        #expect(unreadAlertCount(for: tab, alerts: alerts) == 1)

        alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: b,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)
        #expect(unreadAlertCount(for: tab, alerts: alerts) == 2)
    }

    @Test("testGroupUnreadAlertCount")
    func testGroupUnreadAlertCount() {
        // Intent: groupUnreadAlertCount sums unread alerts across every
        //   tab in the group.
        // Why it exists: pins the group-level rollup the sidebar group
        //   header bell reads.
        // Scenario: spec-first rollup -- two tabs in one group, one alert
        //   in the second tab, returns 1.
        let a = PaneId(), b = PaneId()
        let tabId1 = TabId(), tabId2 = TabId()
        let tab1 = TabModel(id: tabId1, focusedPaneId: a, rootNode: .leaf(PaneModel(id: a)))
        let tab2 = TabModel(id: tabId2, focusedPaneId: b, rootNode: .leaf(PaneModel(id: b)))
        let group = GroupModel(id: GroupId(), name: "Test", tabs: [tab1, tab2])
        var alerts: [AlertModel] = []

        #expect(groupUnreadAlertCount(for: group, alerts: alerts) == 0)
        alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: b,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)
        #expect(groupUnreadAlertCount(for: group, alerts: alerts) == 1)
    }

    // MARK: - moveToFront

    @Test("moveToFront empty array is no-op")
    func moveToFrontEmptyArrayNoOp() {
        // Intent: moveToFront on an empty array leaves it empty.
        // Why it exists: pins the trivial base case to ward off out-of-
        //   bounds regressions.
        // Scenario: spec-first base case.
        var arr: [Int] = []
        moveToFront(&arr, 1)
        #expect(arr == [])
    }

    @Test("moveToFront missing element is no-op")
    func moveToFrontMissingElementNoOp() {
        // Intent: moveToFront with an absent element leaves the array
        //   unchanged.
        // Why it exists: pins the no-op-on-absence guard the MRU reconciler
        //   relies on for stale ids.
        // Scenario: spec-first stale-id check.
        var arr = [1, 2, 3]
        moveToFront(&arr, 99)
        #expect(arr == [1, 2, 3])
    }

    @Test("moveToFront existing element moves to index 0")
    func moveToFrontExistingElementMovesToZero() {
        // Intent: moveToFront removes the element from its current index
        //   and re-inserts it at the front.
        // Why it exists: pins the happy path of selecting an MRU tab and
        //   hoisting it.
        // Scenario: spec-first hoist check -- moving 3 to front of
        //   [1,2,3,4] yields [3,1,2,4].
        var arr = [1, 2, 3, 4]
        moveToFront(&arr, 3)
        #expect(arr == [3, 1, 2, 4])
    }

    @Test("moveToFront idempotent when already at index 0")
    func moveToFrontIdempotentAtIndexZero() {
        // Intent: moveToFront on the head element leaves the array
        //   unchanged.
        // Why it exists: pins the idempotence the MRU reconciler reads as
        //   "no churn needed."
        // Scenario: spec-first head-idempotence check.
        var arr = [1, 2, 3]
        moveToFront(&arr, 1)
        #expect(arr == [1, 2, 3])
    }

    @Test("moveToFront removes prior occurrence (no duplicates)")
    func moveToFrontRemovesPriorOccurrenceNoDup() {
        // Intent: moveToFront removes every prior occurrence before
        //   inserting at index 0.
        // Why it exists: pins the dedup invariant the MRU reconciler
        //   ultimately writes back.
        // Scenario: spec-first dedup check -- [1,2,1,3] with target 1
        //   becomes [1,2,3].
        var arr = [1, 2, 1, 3]
        moveToFront(&arr, 1)
        #expect(arr == [1, 2, 3])
    }

    // MARK: - reconcileMru

    @Test("reconcileMru on full live order is a no-op except possible hoist")
    func reconcileMruNoOpExceptHoist() {
        // Intent: with mruOrder == live order and a non-cycling selected
        //   head, reconcileMru leaves mruOrder unchanged.
        // Why it exists: pins the fast path so a stable selection doesn't
        //   ripple through the order on every update().
        // Scenario: spec-first steady-state -- mruOrder == ids,
        //   selectedTabId == ids[0].
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.mruOrder = ids
        model.selectedTabId = ids[0]
        reconcileMru(&model)
        #expect(model.mruOrder == ids)
    }

    @Test("reconcileMru hoists selectedTabId to index 0 when not cycling")
    func reconcileMruHoistsSelectedWhenNotCycling() {
        // Intent: when not cycling, reconcileMru moves selectedTabId to
        //   index 0.
        // Why it exists: pins the "selection drives MRU" rule outside of
        //   cmd-tab cycling.
        // Scenario: spec-first hoist -- mruOrder [A,B,C], selectedTabId C
        //   reconciles to [C,A,B].
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.mruOrder = ids
        model.selectedTabId = ids[2]
        reconcileMru(&model)
        #expect(model.mruOrder == [ids[2], ids[0], ids[1]])
    }

    @Test("reconcileMru does NOT hoist when cycling")
    func reconcileMruDoesNotHoistWhenCycling() {
        // Intent: during a cycle (mruCycle != nil), reconcileMru leaves
        //   mruOrder frozen even if selection drifts.
        // Why it exists: pins the freeze the cmd-tab UX depends on so the
        //   row order stays stable across cursor moves.
        // Scenario: spec-first cycle freeze.
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.mruOrder = ids
        model.selectedTabId = ids[2]
        model.mruCycle = MruCycleState(frozenOrder: ids, cursorIndex: 1)
        reconcileMru(&model)
        #expect(model.mruOrder == ids)
    }

    @Test("reconcileMru prunes stale ids")
    func reconcileMruPrunesStaleIds() {
        // Intent: reconcileMru drops mruOrder entries that no longer map
        //   to a live tab.
        // Why it exists: pins the cleanup that prevents the switcher panel
        //   from showing ghost tabs.
        // Scenario: spec-first ghost prune -- mruOrder = [ghost, live1,
        //   live2] -> [live1, live2].
        let (m0, ids) = makeMruModel(tabCount: 2)
        var model = m0
        let ghost = TabId()
        model.mruOrder = [ghost, ids[0], ids[1]]
        reconcileMru(&model)
        #expect(!model.mruOrder.contains(ghost), "ghost id must be pruned")
        #expect(Set(model.mruOrder) == Set(ids))
    }

    @Test("reconcileMru appends missing live tabs at the back")
    func reconcileMruAppendsMissingLiveTabs() {
        // Intent: reconcileMru appends live tabs missing from mruOrder at
        //   the end (in display order).
        // Why it exists: pins the recovery path that lets the switcher show
        //   newly created or restored tabs.
        // Scenario: spec-first append -- mruOrder = [ids[0]] with three
        //   live tabs grows to [ids[0], ids[1], ids[2]].
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.mruOrder = [ids[0]]
        reconcileMru(&model)
        #expect(model.mruOrder == [ids[0], ids[1], ids[2]])
    }

    @Test("reconcileMru deduplicates: first occurrence wins")
    func reconcileMruDeduplicatesFirstOccurrenceWins() {
        // Intent: duplicate entries in mruOrder collapse to a single first
        //   occurrence.
        // Why it exists: pins the dedup contract that defends against
        //   corrupt persisted state and double-hoist bugs.
        // Scenario: spec-first dedup -- [B,A,B,C] reconciles to [B,A,C].
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.mruOrder = [ids[1], ids[0], ids[1], ids[2]]
        reconcileMru(&model)
        #expect(model.mruOrder == [ids[1], ids[0], ids[2]])
    }

    @Test("reconcileMru on empty mruOrder builds full list (restore-time)")
    func reconcileMruEmptyBuildsFullList() {
        // Intent: from an empty mruOrder, reconcileMru builds the full list
        //   with the selected tab hoisted to index 0.
        // Why it exists: pins the restore-time recovery so a freshly
        //   restored model gets a usable MRU on the first update().
        // Scenario: spec-first restore-time -- mruOrder = [], selectedTabId
        //   = ids[1]; reconciles to [B, A, C] (B hoisted).
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.mruOrder = []
        model.selectedTabId = ids[1]
        reconcileMru(&model)
        #expect(model.mruOrder.count == 3)
        #expect(model.mruOrder[0] == ids[1], "selected tab hoisted to front")
        #expect(Set(model.mruOrder) == Set(ids), "all live tabs present")
    }

    @Test("reconcileMru does not early-out when count matches but a live tab is missing")
    func reconcileMruDoesNotEarlyOutCountMatchMissingLive() {
        // Intent: mruOrder with a matching count but stale id is rebuilt, not
        //   treated as canonical.
        // Why it exists: pins the fast path against a count-only check that
        //   would drop the missing live tab from the switcher.
        // Scenario: spec-first; a restore/import-like swap leaves a stale MRU
        //   entry while live tab count stays unchanged.
        let (m0, ids) = makeMruModel(tabCount: 2)
        var model = m0
        let ghost = TabId()
        model.mruOrder = [ids[0], ghost]
        model.selectedTabId = ids[0]
        reconcileMru(&model)
        #expect(!model.mruOrder.contains(ghost), "stale id must be pruned")
        #expect(Set(model.mruOrder) == Set(ids), "missing live tab must be appended")
    }

    @Test("reconcileMru does not early-out on a duplicate live id")
    func reconcileMruDoesNotEarlyOutDuplicateLive() {
        // Intent: mruOrder with a repeated live id is rebuilt, not treated as
        //   canonical.
        // Why it exists: pins the fast path against accepting [A, A] for live
        //   {A, B}, which has the right count and a valid head but lacks coverage.
        // Scenario: spec-first; a corrupt/transient MRU order repeats one live
        //   id and omits another.
        let (m0, ids) = makeMruModel(tabCount: 2)
        var model = m0
        model.mruOrder = [ids[0], ids[0]]
        model.selectedTabId = ids[0]
        reconcileMru(&model)
        #expect(model.mruOrder == [ids[0], ids[1]], "dedup to [A], then append B")
    }

    // MARK: - resolveLiveCycle

    @Test("resolveLiveCycle all live → identity")
    func resolveLiveCycleAllLiveIdentity() {
        // Intent: when every frozen id is still live, resolveLiveCycle
        //   returns the frozen order and cursor unchanged.
        // Why it exists: pins the no-op fast path so steady-state cycling
        //   stays stable.
        // Scenario: spec-first steady state -- all four ids live, cursor
        //   index 2.
        let (m0, ids) = makeMruModel(tabCount: 4)
        let model = m0
        let cycle = MruCycleState(frozenOrder: ids, cursorIndex: 2)
        let resolved = resolveLiveCycle(cycle, in: model)
        #expect(resolved != nil)
        #expect(resolved!.liveOrder == ids)
        #expect(resolved!.cursorIndex == 2)
    }

    @Test("resolveLiveCycle dead id before cursor → cursor remaps to same target")
    func resolveLiveCycleDeadBeforeCursorRemaps() {
        // Intent: when a dead id sits before the cursor, the cursor
        //   re-indexes to the same target id in the live order.
        // Why it exists: pins the cursor-stability invariant after a
        //   non-target tab closes.
        // Scenario: spec-first cursor-shift -- [A,B,C,D] cursor=2 (target
        //   C); remove B; cursor=1 still points at C.
        let (m0, ids) = makeMruModel(tabCount: 4)
        var model = m0
        let frozen = ids
        model.groups[0].tabs.removeAll { $0.id == ids[1] }
        let cycle = MruCycleState(frozenOrder: frozen, cursorIndex: 2)
        let resolved = resolveLiveCycle(cycle, in: model)
        #expect(resolved != nil)
        #expect(resolved!.liveOrder == [ids[0], ids[2], ids[3]])
        #expect(resolved!.cursorIndex == 1, "C still pinned at its new live index")
    }

    @Test("resolveLiveCycle dead id at cursor → snap back to nearest preceding live")
    func resolveLiveCycleDeadAtCursorSnapsBack() {
        // Intent: when the cursor's frozen id is itself dead, snap back to
        //   the nearest preceding live id.
        // Why it exists: pins the recovery that prevents cycling onto a
        //   ghost tab.
        // Scenario: spec-first snap-back -- cursor C, C closes, snap to B.
        let (m0, ids) = makeMruModel(tabCount: 4)
        var model = m0
        let frozen = ids
        model.groups[0].tabs.removeAll { $0.id == ids[2] }
        let cycle = MruCycleState(frozenOrder: frozen, cursorIndex: 2)
        let resolved = resolveLiveCycle(cycle, in: model)
        #expect(resolved != nil)
        #expect(resolved!.liveOrder == [ids[0], ids[1], ids[3]])
        #expect(resolved!.cursorIndex == 1, "snapped back to B")
    }

    @Test("resolveLiveCycle dead id at cursor with no preceding live → fallback to 0")
    func resolveLiveCycleDeadAtCursorNoPrecedingLiveFallback() {
        // Intent: when the cursor is dead and nothing precedes it, fall
        //   back to live index 0.
        // Why it exists: pins the head fallback so cycling can never land
        //   on -1.
        // Scenario: spec-first head fallback -- cursor at A, A closes,
        //   fall back to ids[1] (now live index 0).
        let (m0, ids) = makeMruModel(tabCount: 4)
        var model = m0
        let frozen = ids
        model.groups[0].tabs.removeAll { $0.id == ids[0] }
        let cycle = MruCycleState(frozenOrder: frozen, cursorIndex: 0)
        let resolved = resolveLiveCycle(cycle, in: model)
        #expect(resolved != nil)
        #expect(resolved!.liveOrder == [ids[1], ids[2], ids[3]])
        #expect(resolved!.cursorIndex == 0, "fell back to live index 0")
    }

    @Test("resolveLiveCycle all frozen ids dead → nil")
    func resolveLiveCycleAllDeadNil() {
        // Intent: when no frozen id is live, resolveLiveCycle returns nil.
        // Why it exists: pins the cycle-cancel signal the runtime uses to
        //   order the switcher panel out.
        // Scenario: spec-first all-dead -- one frozen id, that tab closes.
        let (m0, ids) = makeMruModel(tabCount: 1)
        var model = m0
        let frozen = ids
        model.groups[0].tabs.removeAll()
        let cycle = MruCycleState(frozenOrder: frozen, cursorIndex: 0)
        let resolved = resolveLiveCycle(cycle, in: model)
        #expect(resolved == nil, "no live tabs → nil")
    }

    // MARK: - desiredAlertsPopover

    @Test("desiredAlertsPopover filters unread vs show-all rows")
    func desiredAlertsPopoverFiltersUnreadVsShowAll() {
        // Intent: desiredAlertsPopover.rows reflects the show-all flag
        //   (only unread when false, all alerts when true).
        // Why it exists: pins the tab toggle wiring the alerts popover
        //   panel renders.
        // Scenario: spec-first tab-toggle -- one unread + one read; rows
        //   shrink to {unread} then expand to both.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let unread = AlertModel(
            id: AlertId(), kind: .bell, paneId: paneId,
            title: "Unread", body: "bell", createdAt: Date(timeIntervalSince1970: 10), isUnread: true)
        let read = AlertModel(
            id: AlertId(), kind: .desktopNotification, paneId: paneId,
            title: "Read", body: "osc", createdAt: Date(timeIntervalSince1970: 20), isUnread: false)
        model.alerts = [unread, read]

        var proj = desiredAlertsPopover(in: model)
        #expect(proj.rows.map(\.id) == [unread.id], "unread tab shows only unread alerts")
        #expect(proj.showAll == false, "projection carries the show-all flag")

        model.showAllAlerts = true
        proj = desiredAlertsPopover(in: model)
        #expect(proj.rows.map(\.id) == [unread.id, read.id], "show-all tab shows all alerts")
        #expect(proj.showAll == true, "projection carries the show-all flag")
    }

    @Test("desiredAlertsPopover mark-all visibility reads the full alert list")
    func desiredAlertsPopoverMarkAllVisibility() {
        // Intent: markAllVisible is true if any alert is unread,
        //   independent of the show-all flag.
        // Why it exists: pins the "no unread anywhere" condition for
        //   hiding the mark-all button.
        // Scenario: spec-first mark-all -- in show-all mode, mark-all is
        //   visible until the last unread alert is marked read.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let read = AlertModel(
            id: AlertId(), kind: .bell, paneId: paneId,
            title: "Read", body: "x", createdAt: Date(timeIntervalSince1970: 10), isUnread: false)
        var unread = AlertModel(
            id: AlertId(), kind: .bell, paneId: paneId,
            title: "Unread", body: "x", createdAt: Date(timeIntervalSince1970: 20), isUnread: true)
        model.showAllAlerts = true
        model.alerts = [read, unread]

        var proj = desiredAlertsPopover(in: model)
        #expect(proj.rows.map(\.id) == [read.id, unread.id], "show-all keeps read rows visible")
        #expect(proj.markAllVisible == true, "any unread alert shows the mark-all button")

        unread.isUnread = false
        model.alerts = [read, unread]
        proj = desiredAlertsPopover(in: model)
        #expect(proj.rows.map(\.id) == [read.id, unread.id], "show-all rows remain after all alerts are read")
        #expect(proj.markAllVisible == false, "no unread alerts hides the mark-all button")
    }

    @Test("desiredAlertsPopover empty text follows the selected alert tab")
    func desiredAlertsPopoverEmptyTextFollowsTab() {
        // Intent: emptyText carries "No unread alerts" on the unread tab
        //   and "No alerts" on the show-all tab; non-empty rows -> nil.
        // Why it exists: pins the per-tab empty-state copy the popover
        //   shows.
        // Scenario: spec-first empty-state -- inspect emptyText across
        //   tab toggles and after inserting an alert.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId

        var proj = desiredAlertsPopover(in: model)
        #expect(proj.emptyText == "No unread alerts", "empty unread tab uses unread copy")

        model.showAllAlerts = true
        proj = desiredAlertsPopover(in: model)
        #expect(proj.emptyText == "No alerts", "empty history tab uses history copy")

        model.alerts = [AlertModel(
            id: AlertId(), kind: .bell, paneId: paneId,
            title: "DanTerm", body: "x", createdAt: Date(timeIntervalSince1970: 10), isUnread: true)]
        proj = desiredAlertsPopover(in: model)
        #expect(proj.emptyText == nil, "rows present means no empty text")
    }

    @Test("desiredAlertsPopover changes when a background alert is inserted")
    func desiredAlertsPopoverChangesOnBackgroundAlert() {
        // Intent: inserting an alert into model.alerts changes the
        //   projection identity (rows + markAllVisible reflect the new
        //   state).
        // Why it exists: pins the input-equality contract the reconcile
        //   loop reads to decide whether to refresh the popover.
        // Scenario: spec-first insertion-detected -- proj0 != proj1 after
        //   an unread alert is prepended.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId

        let proj0 = desiredAlertsPopover(in: model)
        let alert = AlertModel(
            id: AlertId(), kind: .bell, paneId: paneId,
            title: "DanTerm", body: "build", createdAt: Date(timeIntervalSince1970: 10), isUnread: true)
        model.alerts.insert(alert, at: 0)
        let proj1 = desiredAlertsPopover(in: model)

        #expect(proj0 != proj1, "inserted alert changes the projection")
        #expect(proj1.rows.first?.id == alert.id, "new alert is the first rendered row")
        #expect(proj1.markAllVisible == true, "unread background alert shows the mark-all button")
    }

    // MARK: - desiredSwitcher (MRU switcher overlay projection, Stage 7)

    @Test("desiredSwitcher: non-nil while cycling, nil once the cycle ends")
    func desiredSwitcherNonNilWhileCyclingNilAfter() {
        // Intent: desiredSwitcher returns a populated projection while
        //   cycling and nil otherwise.
        // Why it exists: pins the appearance/disappearance net the
        //   reconciler uses to issue orderFront/orderOut on the panel.
        // Scenario: spec-first cycle lifecycle -- absence pre-cycle, rows
        //   while cycling reflect live order + carried cursor + per-row
        //   name/alertCount, then absence after the cycle ends.
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        #expect(model.mruCycle == nil, "precondition: not cycling")
        #expect(desiredSwitcher(in: model) == nil, "no MRU cycle -> nil projection")

        model.groups[0].tabs[0].customTitle = "Alpha"
        let alertPane = model.groups[0].tabs[1].focusedPaneId
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: alertPane,
            title: "DanTerm", body: "x", createdAt: Date(), isUnread: true), at: 0)

        model.mruCycle = MruCycleState(frozenOrder: ids, cursorIndex: 1)
        guard let proj = desiredSwitcher(in: model) else {
            Issue.record("expected a non-nil projection while cycling")
            return
        }
        #expect(proj.rows.map(\.tabId) == ids, "rows follow the live (frozen) order")
        #expect(proj.cursorIndex == 1, "cursor index carried from the cycle")
        #expect(proj.rows[0].name == "Alpha", "row name is the tab's displayTitle")
        #expect(proj.rows[1].alertCount == 1, "row alertCount reflects the model's unread alerts")
        #expect(proj.rows[0].alertCount == 0, "a tab with no unread alerts has zero count")

        model.mruCycle = nil
        #expect(desiredSwitcher(in: model) == nil, "cycle ended -> nil projection (orderOut)")
    }

    @Test("desiredQuitConfirmation projects terminate pane count only")
    func desiredQuitConfirmationProjectsTerminateOnly() {
        // Intent: desiredQuitConfirmation returns nil unless
        //   pendingConfirmation == .terminate, then carries pane count.
        // Why it exists: pins the per-confirmation gating that keeps
        //   the close-tab NSAlert path off the quit panel.
        // Scenario: spec-first projection -- nil with no confirmation,
        //   nil for close-tab, non-nil for terminate with paneCount.
        var model = makeModel()
        createTab(&model)

        #expect(desiredQuitConfirmation(in: model) == nil, "no pending confirmation -> nil projection")

        model.pendingConfirmation = .closeTab
        #expect(desiredQuitConfirmation(in: model) == nil, "close-tab confirmation uses NSAlert, not the quit panel")

        model.pendingConfirmation = .terminate
        #expect(desiredQuitConfirmation(in: model) == QuitConfirmationProjection(paneCount: 1),
            "single-pane terminate confirmation projects pane count 1")

        var multi = makeMruModel(tabCount: 3).model
        multi.pendingConfirmation = .terminate
        #expect(desiredQuitConfirmation(in: multi) == QuitConfirmationProjection(paneCount: 3),
            "multi-pane terminate confirmation projects the live pane count")

        multi.pendingConfirmation = nil
        #expect(desiredQuitConfirmation(in: multi) == nil, "cleared confirmation -> nil projection")
    }

    @Test("desiredQuitConfirmation decrements as panes close while pending")
    func desiredQuitConfirmationDecrementsWithPanes() {
        // Intent: the paneCount field reflects live panes while a quit
        //   confirmation is pending.
        // Why it exists: pins the live-rollup so the user sees the
        //   accurate pane count even after closing some panes.
        // Scenario: spec-first live-update -- start with two panes,
        //   close one non-last pane; the projection reports 1.
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .splitPane(direction: .horizontal))
        #expect(model.allPaneIds.count == 2, "precondition: split created two panes")
        model.pendingConfirmation = .terminate
        #expect(desiredQuitConfirmation(in: model)?.paneCount == 2,
            "open quit panel starts with both panes")

        let paneId = model.groups[0].tabs[0].focusedPaneId
        _ = update(&model, .closePane(paneId: paneId))

        #expect(model.allPaneIds.count == 1, "non-last pane close removes one pane")
        #expect(model.pendingConfirmation == .terminate, "non-last pane close keeps quit confirmation pending")
        #expect(desiredQuitConfirmation(in: model)?.paneCount == 1,
            "projection reflects the decremented live pane count")
    }

    // MARK: - resolveContextTargets (sidebar Finder/Mail rule)

    @Test("resolveContextTargets clicked row in selection returns selection in row order")
    func resolveContextTargetsClickedInSelection() {
        // Intent: when the clicked row is part of the multi-selection,
        //   return every selected tab id in row order.
        // Why it exists: pins the Finder/Mail right-click rule so context
        //   menu actions operate on the visible selection, not just the
        //   click target.
        // Scenario: spec-first selection-in -- click row 1; selection
        //   {0,1,2} returns ids in row order.
        let id0 = TabId(); let id1 = TabId(); let id2 = TabId()
        let map: [Int: TabId] = [0: id0, 1: id1, 2: id2]
        let result = resolveContextTargets(
            clickedRow: 1,
            selectedRows: IndexSet([2, 0, 1]),
            tabIdAtRow: { map[$0] })
        #expect(result == [id0, id1, id2])
    }

    @Test("resolveContextTargets clicked row outside selection returns clicked row only")
    func resolveContextTargetsClickedOutsideSelection() {
        // Intent: when the click lands outside the current selection,
        //   target only the clicked row.
        // Why it exists: pins the "Finder rule" override that re-anchors
        //   the action to the click.
        // Scenario: spec-first selection-out -- click row 3 with
        //   selection {0}; returns [id3].
        let id0 = TabId(); let id3 = TabId()
        let map: [Int: TabId] = [0: id0, 3: id3]
        let result = resolveContextTargets(
            clickedRow: 3,
            selectedRows: IndexSet([0]),
            tabIdAtRow: { map[$0] })
        #expect(result == [id3])
    }

    @Test("resolveContextTargets group row (nil mapping) returns empty")
    func resolveContextTargetsGroupRowEmpty() {
        // Intent: clicking a group row (tabIdAtRow returns nil) yields no
        //   targets.
        // Why it exists: pins the group-row guard so context-menu tab
        //   actions never fire against a group header.
        // Scenario: spec-first group-row check.
        let result = resolveContextTargets(
            clickedRow: 1,
            selectedRows: IndexSet([1]),
            tabIdAtRow: { _ in nil })
        #expect(result == [])
    }

    @Test("resolveContextTargets selection mixes tab and group rows — group filtered")
    func resolveContextTargetsMixedSelectionFiltersGroup() {
        // Intent: a selection that spans tab rows and a group row drops
        //   the group row from the returned targets.
        // Why it exists: pins the filter that keeps group headers from
        //   sneaking into tab-only context actions.
        // Scenario: spec-first mixed selection -- {0,1,2} with row 1 a
        //   group row returns [id0, id2].
        let id0 = TabId(); let id2 = TabId()
        let map: [Int: TabId?] = [0: id0, 1: nil, 2: id2]
        let result = resolveContextTargets(
            clickedRow: 0,
            selectedRows: IndexSet([0, 1, 2]),
            tabIdAtRow: { map[$0] ?? nil })
        #expect(result == [id0, id2])
    }

    @Test("resolveContextTargets negative clicked row returns empty")
    func resolveContextTargetsNegativeRowEmpty() {
        // Intent: a negative clickedRow (no row clicked) returns no
        //   targets.
        // Why it exists: pins the empty-area guard so right-click on
        //   blank space does nothing.
        // Scenario: spec-first empty-area check.
        let result = resolveContextTargets(
            clickedRow: -1,
            selectedRows: IndexSet(),
            tabIdAtRow: { _ in TabId() })
        #expect(result == [])
    }

    // MARK: - resolveReloadSelection (sidebar selection restore rule)

    @Test("resolveReloadSelection preserves multi-selection when focus is in it")
    func resolveReloadSelectionPreservesMultiWhenFocusInIt() {
        // Intent: when the focused tab is part of the prior selection,
        //   preserve the whole multi-selection.
        // Why it exists: pins the multi-select reload contract so
        //   structural updates don't collapse the user's selection.
        // Scenario: spec-first preserve -- selection {a,b,c}, focus a;
        //   reload keeps {a,b,c}.
        let a = TabId(); let b = TabId(); let c = TabId(); let d = TabId()
        let result = resolveReloadSelection(
            priorSelectedTabIds: [a, b, c],
            liveTabIds: [a, b, c, d],
            selectedTabId: a)
        #expect(result == [a, b, c])
    }

    @Test("resolveReloadSelection drops stale ids while preserving")
    func resolveReloadSelectionDropsStale() {
        // Intent: stale ids are dropped from the preserved selection.
        // Why it exists: pins the per-tick prune of closed tabs from the
        //   user's selection.
        // Scenario: spec-first prune -- selection {a, b, stale}, live
        //   {a, b}; reload returns {a, b}.
        let a = TabId(); let b = TabId(); let stale = TabId()
        let result = resolveReloadSelection(
            priorSelectedTabIds: [a, b, stale],
            liveTabIds: [a, b],
            selectedTabId: a)
        #expect(result == [a, b])
    }

    @Test("resolveReloadSelection collapses to focus when external focus change")
    func resolveReloadSelectionCollapsesOnExternalFocusChange() {
        // Intent: an external selection change collapses the prior
        //   multi-selection down to the new focus.
        // Why it exists: pins the "external change wins" rule that
        //   prevents stale selections after a non-sidebar selection
        //   change.
        // Scenario: spec-first collapse -- selection {a, b}, focus
        //   becomes c (not in selection); reload returns {c}.
        let a = TabId(); let b = TabId(); let c = TabId()
        let result = resolveReloadSelection(
            priorSelectedTabIds: [a, b],
            liveTabIds: [a, b, c],
            selectedTabId: c)
        #expect(result == [c])
    }

    @Test("resolveReloadSelection collapses to focus when all prior ids stale")
    func resolveReloadSelectionCollapsesWhenAllStale() {
        // Intent: with every prior id closed, collapse to the live focus.
        // Why it exists: pins the recovery path so a fully-stale prior
        //   selection cannot strand the sidebar.
        // Scenario: spec-first all-stale -- selection {a, b} both closed;
        //   reload returns {c}.
        let a = TabId(); let b = TabId(); let c = TabId()
        let result = resolveReloadSelection(
            priorSelectedTabIds: [a, b],
            liveTabIds: [c],
            selectedTabId: c)
        #expect(result == [c])
    }

    @Test("resolveReloadSelection returns empty when selectedTabId is itself stale")
    func resolveReloadSelectionEmptyWhenSelectedTabStale() {
        // Intent: a stale selectedTabId yields an empty selection.
        // Why it exists: pins fail-closed on stale focus -- the reload
        //   shows no selection rather than guessing.
        // Scenario: spec-first stale-focus check.
        let a = TabId(); let b = TabId(); let stale = TabId()
        let result = resolveReloadSelection(
            priorSelectedTabIds: [a, b],
            liveTabIds: [a, b],
            selectedTabId: stale)
        #expect(result == [])
    }

    @Test("resolveReloadSelection returns empty when no selectedTabId")
    func resolveReloadSelectionEmptyWhenNoSelectedTab() {
        // Intent: no selectedTabId means no reload selection.
        // Why it exists: pins the empty-focus branch (analogous to the
        //   stale case but distinct in the contract).
        // Scenario: spec-first no-focus check.
        let a = TabId(); let b = TabId()
        let result = resolveReloadSelection(
            priorSelectedTabIds: [a, b],
            liveTabIds: [a, b],
            selectedTabId: nil)
        #expect(result == [])
    }

    // MARK: - shouldForceSidebarRowEmphasis

    @Test("shouldForceSidebarRowEmphasis true when ids match")
    func shouldForceSidebarRowEmphasisTrueWhenIdsMatch() {
        // Intent: a tab row whose id equals focusedTabId is emphasized.
        // Why it exists: pins the focus-emphasis rule the sidebar paints.
        // Scenario: spec-first match check.
        let id = TabId()
        #expect(shouldForceSidebarRowEmphasis(rowTabId: id, focusedTabId: id))
    }

    @Test("shouldForceSidebarRowEmphasis false when ids differ")
    func shouldForceSidebarRowEmphasisFalseWhenIdsDiffer() {
        // Intent: a non-matching row is not emphasized.
        // Why it exists: pins the negative case.
        // Scenario: spec-first non-match check.
        let row = TabId(); let focused = TabId()
        #expect(!shouldForceSidebarRowEmphasis(rowTabId: row, focusedTabId: focused))
    }

    @Test("shouldForceSidebarRowEmphasis false for group rows (rowTabId nil)")
    func shouldForceSidebarRowEmphasisFalseForGroupRows() {
        // Intent: group rows never receive emphasis (rowTabId nil).
        // Why it exists: pins the group-row guard.
        // Scenario: spec-first group-row check.
        let focused = TabId()
        #expect(!shouldForceSidebarRowEmphasis(rowTabId: nil, focusedTabId: focused))
    }

    @Test("shouldForceSidebarRowEmphasis false when focusedTabId nil")
    func shouldForceSidebarRowEmphasisFalseWhenFocusedNil() {
        // Intent: no focused tab means no row emphasis.
        // Why it exists: pins the empty-focus branch.
        // Scenario: spec-first empty-focus check.
        let row = TabId()
        #expect(!shouldForceSidebarRowEmphasis(rowTabId: row, focusedTabId: nil))
    }

    @Test("shouldForceSidebarRowEmphasis false when both nil")
    func shouldForceSidebarRowEmphasisFalseWhenBothNil() {
        // Intent: nil row id and nil focused id never match.
        // Why it exists: pins the degenerate-case guard.
        // Scenario: spec-first both-nil check.
        #expect(!shouldForceSidebarRowEmphasis(rowTabId: nil, focusedTabId: nil))
    }

    // MARK: - resolveColorForBatch

    @Test("testResolveColorForBatchEmptyReturnsNil")
    func testResolveColorForBatchEmptyReturnsNil() {
        // Intent: an empty batch resolves to nil (no policy meaning).
        // Why it exists: pins the empty-input fail-closed guard.
        // Scenario: spec-first empty-batch check.
        let model = makeModel()
        #expect(resolveColorForBatch(tabIds: [], requested: .red, in: model) == nil)
    }

    @Test("testResolveColorForBatchSingleSameColorClears")
    func testResolveColorForBatchSingleSameColorClears() {
        // Intent: requesting the color the single target already has
        //   toggles it off (clear).
        // Why it exists: pins the single-target toggle the colour
        //   shortcut depends on.
        // Scenario: spec-first toggle -- red tab + cmd-1 (red) -> nil.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        model.groups[0].tabs[0].color = .red
        #expect(resolveColorForBatch(tabIds: [tabId], requested: .red, in: model) == nil)
    }

    @Test("testResolveColorForBatchSingleDifferentColorSets")
    func testResolveColorForBatchSingleDifferentColorSets() {
        // Intent: requesting a new color on a colored tab updates it.
        // Why it exists: pins the change branch of the single-target
        //   path.
        // Scenario: spec-first set -- red tab + cmd-2 (orange) -> orange.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        model.groups[0].tabs[0].color = .red
        #expect(resolveColorForBatch(tabIds: [tabId], requested: .orange, in: model) == .orange)
    }

    @Test("testResolveColorForBatchSingleUncoloredSets")
    func testResolveColorForBatchSingleUncoloredSets() {
        // Intent: requesting a color on an uncolored tab sets it.
        // Why it exists: pins the nil-color branch.
        // Scenario: spec-first first-color -- nil tab + cmd-1 -> red.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        #expect(resolveColorForBatch(tabIds: [tabId], requested: .red, in: model) == .red)
    }

    @Test("testResolveColorForBatchMultiAllShareRequestedClears")
    func testResolveColorForBatchMultiAllShareRequestedClears() {
        // Intent: a batch where every tab shares the requested color
        //   toggles them all off.
        // Why it exists: pins the multi-target toggle-off extension.
        // Scenario: spec-first multi toggle -- {red, red} + cmd-1 -> nil.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let id1 = model.groups[0].tabs[0].id
        let id2 = model.groups[0].tabs[1].id
        model.groups[0].tabs[0].color = .red
        model.groups[0].tabs[1].color = .red
        #expect(resolveColorForBatch(tabIds: [id1, id2], requested: .red, in: model) == nil)
    }

    @Test("testResolveColorForBatchMultiAllUncoloredSetsRequested")
    func testResolveColorForBatchMultiAllUncoloredSetsRequested() {
        // Intent: an all-uncolored batch sets the requested color (not
        //   clear).
        // Why it exists: pins the nil-color branch of the all-share check.
        // Scenario: spec-first multi first-color -- {nil, nil} + cmd-1
        //   -> red.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let id1 = model.groups[0].tabs[0].id
        let id2 = model.groups[0].tabs[1].id
        #expect(resolveColorForBatch(tabIds: [id1, id2], requested: .red, in: model) == .red)
    }

    @Test("testResolveColorForBatchMultiMixedColorsSetRequested")
    func testResolveColorForBatchMultiMixedColorsSetRequested() {
        // Intent: a mixed-color batch normalizes to the requested color.
        // Why it exists: pins the multi-target normalization branch.
        // Scenario: spec-first mixed -> normalized -- {red, orange} +
        //   cmd-1 -> red.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let id1 = model.groups[0].tabs[0].id
        let id2 = model.groups[0].tabs[1].id
        model.groups[0].tabs[0].color = .red
        model.groups[0].tabs[1].color = .orange
        #expect(resolveColorForBatch(tabIds: [id1, id2], requested: .red, in: model) == .red)
    }

    @Test("testResolveColorForBatchExplicitNilOnSingleColored")
    func testResolveColorForBatchExplicitNilOnSingleColored() {
        // Intent: explicit-nil request clears a single colored tab.
        // Why it exists: pins the explicit-clear path (caller asks for
        //   nil).
        // Scenario: spec-first explicit clear single.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        model.groups[0].tabs[0].color = .red
        #expect(resolveColorForBatch(tabIds: [tabId], requested: nil, in: model) == nil)
    }

    @Test("testResolveColorForBatchExplicitNilOnMulti")
    func testResolveColorForBatchExplicitNilOnMulti() {
        // Intent: explicit-nil request clears a multi-target batch.
        // Why it exists: pins the explicit-clear path applied to a batch.
        // Scenario: spec-first explicit clear multi.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let id1 = model.groups[0].tabs[0].id
        let id2 = model.groups[0].tabs[1].id
        model.groups[0].tabs[0].color = .red
        model.groups[0].tabs[1].color = .red
        #expect(resolveColorForBatch(tabIds: [id1, id2], requested: nil, in: model) == nil)
    }

    // MARK: - Tab Jump Mode

    @Test("assignJumpKeys empty visible tab list returns empty map")
    func assignJumpKeysEmptyReturnsEmpty() {
        // Intent: assignJumpKeys with no visible tabs returns the empty
        //   map.
        // Why it exists: pins the empty-input guard the jump overlay
        //   reads.
        // Scenario: spec-first empty-list check.
        let keyMap: [TabId: Character] = assignJumpKeys(visibleTabs: [])
        #expect(keyMap == [:])
    }

    @Test("assignJumpKeys assigns documented sequence in visible order")
    func assignJumpKeysAssignsDocumentedSequence() {
        // Intent: assignJumpKeys maps tabs to "asdfghjkl;" in visible
        //   order.
        // Why it exists: pins the documented key sequence the jump
        //   overlay paints.
        // Scenario: spec-first sequence -- 10 tabs -> 10 home-row keys.
        let ids = (0..<10).map { _ in TabId() }
        let keyMap = assignJumpKeys(visibleTabs: ids)
        let expected = Array("asdfghjkl;")
        #expect(keyMap.count == ids.count)
        for (index, id) in ids.enumerated() {
            #expect(keyMap[id] == expected[index])
        }
    }

    // MARK: - tabTodoRollup

    @Test("tabTodoRollup empty tab returns zero")
    func tabTodoRollupEmptyTabReturnsZero() {
        // Intent: an empty tab rolls up to (total=0, uncompleted=0).
        // Why it exists: pins the empty base case the window-chrome
        //   reads.
        // Scenario: spec-first empty rollup.
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let rollup = tabTodoRollup(tabId, in: model)
        #expect(rollup.total == 0)
        #expect(rollup.uncompleted == 0)
    }

    @Test("tabTodoRollup sums tab + all panes; ignores other tabs' panes")
    func tabTodoRollupSumsTabAndPanesIgnoresOtherTabs() {
        // Intent: rollup includes the tab's todos and every pane's todos
        //   in the tab, ignoring panes that belong to other tabs.
        // Why it exists: pins the cross-tab isolation so a sibling tab
        //   cannot bleed counts into the open tab's rollup.
        // Scenario: spec-first scoped rollup -- a two-pane tab with one
        //   tab todo + two paneA todos (one done) + one paneA2 todo
        //   rolls up to (4, 3); a separate tab's pane todo stays apart.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabA = model.groups[0].tabs[0]
        let tabB = model.groups[0].tabs[1]
        update(&model, .selectTab(id: tabA.id))
        let paneA = selectedTab(in: model)!.focusedPaneId
        update(&model, .splitPane(paneId: paneA, direction: .horizontal))
        let paneA2 = selectedTab(in: model)!.focusedPaneId

        update(&model, .addTabTodo(tabId: tabA.id, text: "tab task"))
        update(&model, .addTodo(paneId: paneA, text: "p1 a"))
        update(&model, .addTodo(paneId: paneA, text: "p1 b done"))
        let pAdone = model.pane(paneA)!.todos[1].id
        update(&model, .toggleTodoDone(paneId: paneA, todoId: pAdone))
        update(&model, .addTodo(paneId: paneA2, text: "p2 a"))

        update(&model, .addTodo(paneId: tabB.focusedPaneId, text: "tab B pane task"))

        let rollup = tabTodoRollup(tabA.id, in: model)
        #expect(rollup.total == 4, "1 tab + 2 paneA + 1 paneA2")
        #expect(rollup.uncompleted == 3, "one pane todo is done")

        let rollupB = tabTodoRollup(tabB.id, in: model)
        #expect(rollupB.total == 1)
        #expect(rollupB.uncompleted == 1)
    }

    // MARK: - Tab Todo Popover Rows

    @Test("buildTabTodoRows emits a header for every pane regardless of empty todos")
    func buildTabTodoRowsEmitsHeaderForEveryPane() {
        // Intent: every live pane in the tab gets a paneSectionHeader row.
        // Why it exists: pins the header-coverage invariant the popover
        //   reads to render section labels.
        // Scenario: spec-first header coverage -- two-pane tab, only
        //   paneA has todos; both panes still get headers.
        var (model, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTodo(paneId: paneA, text: "pane A task"))

        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let paneHeaders = rows.compactMap { row -> PaneId? in
            if case .paneSectionHeader(let paneId, _) = row { return paneId }
            return nil
        }

        #expect(paneHeaders == [paneA, paneB])
    }

    @Test("buildTabTodoRows emits placeholders for an empty tab and empty panes")
    func buildTabTodoRowsEmitsPlaceholdersForEmptySections() {
        // Intent: empty tab and empty panes each receive their respective
        //   placeholder row.
        // Why it exists: pins the placeholder shape the popover renders
        //   for the empty state.
        // Scenario: spec-first empty -- the two-pane model with no todos
        //   has the documented header + placeholder sequence.
        let (model, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()

        let rows = buildTabTodoRows(model: model, tabId: tabId)

        #expect(rows == [
            .tabSectionHeader,
            .tabEmptyPlaceholder,
            .paneSectionHeader(paneId: paneA, title: model.pane(paneA)!.title),
            .paneEmptyPlaceholder(paneId: paneA),
            .paneSectionHeader(paneId: paneB, title: model.pane(paneB)!.title),
            .paneEmptyPlaceholder(paneId: paneB),
        ])
    }

    @Test("buildTabTodoRows emits placeholders only for empty sections")
    func buildTabTodoRowsEmitsPlaceholdersOnlyForEmpty() {
        // Intent: populated sections get no placeholder; empty sections
        //   keep theirs.
        // Why it exists: pins the placeholder-only-when-empty rule.
        // Scenario: spec-first mixed -- tab + paneA populated, paneB
        //   empty; only paneB's placeholder remains.
        var (model, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTabTodo(tabId: tabId, text: "tab task"))
        update(&model, .addTodo(paneId: paneA, text: "pane A task"))

        let rows = buildTabTodoRows(model: model, tabId: tabId)

        #expect(rows.contains(.tabEmptyPlaceholder) == false, "populated tab should not have a placeholder")
        #expect(rows.contains(.paneEmptyPlaceholder(paneId: paneA)) == false, "populated pane should not have a placeholder")
        #expect(rows.contains(.paneEmptyPlaceholder(paneId: paneB)), "empty pane should have a placeholder")
    }

    @Test("buildTabTodoRows places each placeholder immediately after its header")
    func buildTabTodoRowsPlacesPlaceholdersImmediatelyAfterHeader() {
        // Intent: each empty section's placeholder appears at header+1.
        // Why it exists: pins the row-ordering invariant the popover
        //   selection model uses to keep the visible placeholder pinned.
        // Scenario: spec-first ordering -- in the empty model, every
        //   placeholder sits at section header + 1.
        let (model, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()

        let rows = buildTabTodoRows(model: model, tabId: tabId)

        #expect(rows[0] == .tabSectionHeader)
        #expect(rows[1] == .tabEmptyPlaceholder)
        let paneAHeader = rows.firstIndex { row in
            if case .paneSectionHeader(let paneId, _) = row { return paneId == paneA }
            return false
        }!
        #expect(rows[paneAHeader + 1] == .paneEmptyPlaceholder(paneId: paneA))
        let paneBHeader = rows.firstIndex { row in
            if case .paneSectionHeader(let paneId, _) = row { return paneId == paneB }
            return false
        }!
        #expect(rows[paneBHeader + 1] == .paneEmptyPlaceholder(paneId: paneB))
    }

    @Test("tab todo placeholder rows are non-selectable section members")
    func tabTodoPlaceholdersAreNonSelectableSectionMembers() {
        // Intent: placeholder rows report isHeader=false, isSelectable=
        //   false, no editTarget/itemText, but a valid sectionIdentifier.
        // Why it exists: pins the row metadata the keyboard navigator and
        //   diff stay consistent with.
        // Scenario: spec-first row-metadata sweep -- assert every
        //   placeholder field for the tab and pane variants.
        let paneId = PaneId()

        let tabPlaceholder = TabTodoRow.tabEmptyPlaceholder
        #expect(tabPlaceholder.isHeader == false)
        #expect(tabPlaceholder.isSelectable == false)
        #expect(tabPlaceholder.editTarget == nil)
        #expect(tabPlaceholder.itemText == nil)
        #expect(tabPlaceholder.sectionIdentifier == Optional(AnyHashable("tab")))

        let panePlaceholder = TabTodoRow.paneEmptyPlaceholder(paneId: paneId)
        #expect(panePlaceholder.isHeader == false)
        #expect(panePlaceholder.isSelectable == false)
        #expect(panePlaceholder.editTarget == nil)
        #expect(panePlaceholder.itemText == nil)
        #expect(panePlaceholder.sectionIdentifier == Optional(AnyHashable(paneId)))
    }

    // MARK: - TODO Popover Projections

    @Test("desiredPaneTodoPopover returns rows, pane id, and completed visibility")
    func desiredPaneTodoPopoverReturnsRowsAndCompleted() {
        // Intent: desiredPaneTodoPopover carries rows from the pane's
        //   todos, the pane id, and hasCompleted=true when any item is
        //   done.
        // Why it exists: pins the per-pane projection the popover panel
        //   reads.
        // Scenario: spec-first projection -- a pane with two todos, one
        //   marked done, hasCompleted is true.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "done"))
        update(&model, .addTodo(paneId: paneId, text: "pending"))
        let doneId = model.pane(paneId)!.todos[0].id
        update(&model, .toggleTodoDone(paneId: paneId, todoId: doneId))

        let projection = desiredPaneTodoPopover(paneId: paneId, in: model)

        #expect(projection?.paneId == paneId)
        #expect(projection?.rows == model.pane(paneId)!.todos)
        #expect(projection?.hasCompleted == true)
    }

    @Test("desiredPaneTodoPopover returns nil for a missing pane")
    func desiredPaneTodoPopoverNilForMissingPane() {
        // Intent: missing pane id yields nil projection.
        // Why it exists: pins fail-closed for stale pane ids.
        // Scenario: spec-first stale-pane.
        let model = makeModel()

        let projection = desiredPaneTodoPopover(paneId: PaneId(), in: model)

        #expect(projection == nil)
    }

    @Test("desiredTabTodoPopover includes rows, pane order, and tab-only completed visibility")
    func desiredTabTodoPopoverRowsPaneOrderTabOnlyCompleted() {
        // Intent: desiredTabTodoPopover.rows == buildTabTodoRows; .paneOrder
        //   matches the tab's pane order; tabHasCompleted reflects ONLY tab
        //   todos (pane completion does not flip it).
        // Why it exists: pins the projection contract the tab popover reads
        //   plus the subtle "tab-only completed" semantics.
        // Scenario: spec-first projection -- tab todo + paneA todo, then
        //   complete the pane todo (tabHasCompleted stays false), then
        //   complete the tab todo (tabHasCompleted flips true).
        var (model, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTabTodo(tabId: tabId, text: "tab pending"))
        update(&model, .addTodo(paneId: paneA, text: "pane done"))
        let paneDoneId = model.pane(paneA)!.todos[0].id
        update(&model, .toggleTodoDone(paneId: paneA, todoId: paneDoneId))

        var projection = desiredTabTodoPopover(tabId: tabId, in: model)

        #expect(projection?.tabId == tabId)
        #expect(projection?.rows == buildTabTodoRows(model: model, tabId: tabId))
        #expect(projection?.paneOrder == [paneA, paneB])
        #expect(projection?.tabHasCompleted == false, "pane completion should not show tab clear button")

        let tabTodoId = tabById(tabId, in: model)!.todos[0].id
        update(&model, .toggleTabTodoDone(tabId: tabId, todoId: tabTodoId))
        projection = desiredTabTodoPopover(tabId: tabId, in: model)

        #expect(projection?.tabHasCompleted == true)
    }

    @Test("desiredTabTodoPopover changes for pane todo, tab todo, and pane title changes")
    func desiredTabTodoPopoverChangesOnTodoOrTitleChange() {
        // Intent: the projection identity changes when pane todos, tab
        //   todos, or pane titles change.
        // Why it exists: pins the input-equality contract the reconcile
        //   loop reads.
        // Scenario: spec-first change-detection -- three mutations in
        //   sequence each flip the projection.
        var (model, tabId, paneA, _) = makeTwoPaneTabTodoRowsModel()
        var previous = desiredTabTodoPopover(tabId: tabId, in: model)

        update(&model, .addTodo(paneId: paneA, text: "pane task"))
        var next = desiredTabTodoPopover(tabId: tabId, in: model)
        #expect(previous != next, "pane todo changes should update the projection")

        previous = next
        update(&model, .addTabTodo(tabId: tabId, text: "tab task"))
        next = desiredTabTodoPopover(tabId: tabId, in: model)
        #expect(previous != next, "tab todo changes should update the projection")

        previous = next
        model.updatePane(paneA) { $0.title = "renamed pane" }
        next = desiredTabTodoPopover(tabId: tabId, in: model)
        #expect(previous != next, "pane title changes should update the projection")
    }

    @Test("resolveTabTodoEditTarget follows a todo across tab and pane buckets")
    func resolveTabTodoEditTargetFollowsAcrossBuckets() {
        // Intent: an edit target tracks a todo across moveTodo
        //   transitions between tab and pane buckets.
        // Why it exists: pins the cross-bucket follow that keeps the edit
        //   field anchored to the moved todo.
        // Scenario: spec-first follow -- add a tab todo, move it to a
        //   pane (edit target switches), move it back (switches back).
        var (model, tabId, paneA, _) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTabTodo(tabId: tabId, text: "movable"))
        let todoId = tabById(tabId, in: model)!.todos[0].id

        update(&model, .moveTodo(from: .tab(tabId), todoId: todoId, to: .pane(paneA), atIndex: 0))
        var projection = desiredTabTodoPopover(tabId: tabId, in: model)!
        #expect(
            resolveTabTodoEditTarget(.tab(todoId: todoId), in: projection) ==
            .pane(paneId: paneA, todoId: todoId)
        )

        update(&model, .moveTodo(from: .pane(paneA), todoId: todoId, to: .tab(tabId), atIndex: 0))
        projection = desiredTabTodoPopover(tabId: tabId, in: model)!
        #expect(
            resolveTabTodoEditTarget(.pane(paneId: paneA, todoId: todoId), in: projection) ==
            .tab(todoId: todoId)
        )
    }

    @Test("resolveTabTodoEditTarget is scoped to the open tab projection")
    func resolveTabTodoEditTargetScopedToOpenTab() {
        // Intent: an edit target from one tab is not resolved against a
        //   different tab's projection.
        // Why it exists: pins the per-tab scope so cross-tab id lookups
        //   never leak across the popover boundary.
        // Scenario: spec-first scope -- tab A's todo, tab B's projection,
        //   resolve returns nil.
        var model = makeModel()
        createTab(&model)
        let tabA = selectedTab(in: model)!.id
        update(&model, .addTabTodo(tabId: tabA, text: "outside"))
        let outsideTodoId = tabById(tabA, in: model)!.todos[0].id
        createTab(&model)
        let tabB = selectedTab(in: model)!.id

        let projection = desiredTabTodoPopover(tabId: tabB, in: model)!

        #expect(resolveTabTodoEditTarget(.tab(todoId: outsideTodoId), in: projection) == nil)
    }

    @Test("newlyAddedTabTodoTarget returns the first tab item missing from the captured id set")
    func newlyAddedTabTodoTargetReturnsFirstMissing() {
        // Intent: after adding a tab todo, the helper points at the new
        //   item's id (the first tab id not in the captured set).
        // Why it exists: pins the new-item focus rule the popover uses to
        //   jump edit mode to the just-added row.
        // Scenario: spec-first new-item focus -- capture ids before add,
        //   then assert the helper picks the new id.
        var (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTabTodo(tabId: tabId, text: "existing"))
        let previousProjection = desiredTabTodoPopover(tabId: tabId, in: model)!
        let previousIds = Set(previousProjection.rows.compactMap { row -> UUID? in
            if case .tabItem(let item) = row { return item.id }
            return nil
        })

        update(&model, .addTabTodo(tabId: tabId, text: "new"))
        let updatedProjection = desiredTabTodoPopover(tabId: tabId, in: model)!
        let newTodoId = tabById(tabId, in: model)!.todos[1].id

        #expect(
            newlyAddedTabTodoTarget(previousTabTodoIds: previousIds, in: updatedProjection) ==
            .tab(todoId: newTodoId)
        )
    }

    @Test("resolveTabTodoDropTarget .on tabSectionHeader appends to tab")
    func resolveTabTodoDropTargetOnTabHeaderAppends() {
        // Intent: drop .on tabSectionHeader resolves to tab destination,
        //   atIndex == current tab todo count (append).
        // Why it exists: pins the "drop on header -> append" rule.
        // Scenario: spec-first header drop -- two tab todos; drop on the
        //   tab header lands at index 2.
        var (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTabTodo(tabId: tabId, text: "tab A"))
        update(&model, .addTabTodo(tabId: tabId, text: "tab B"))
        let rows = buildTabTodoRows(model: model, tabId: tabId)

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: 0, dropOperation: .on)

        #expect(target?.destination == .tab(tabId))
        #expect(target?.atIndex == 2)
    }

    @Test("resolveTabTodoDropTarget .on paneSectionHeader appends to pane")
    func resolveTabTodoDropTargetOnPaneHeaderAppends() {
        // Intent: drop .on a pane section header lands at the end of
        //   that pane's todo list.
        // Why it exists: pins the same "drop on header -> append" rule
        //   for the pane variant.
        // Scenario: spec-first pane header drop -- one paneA todo; drop
        //   on the paneA header lands at index 1.
        var (model, tabId, paneA, _) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTodo(paneId: paneA, text: "pane A"))
        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let headerRow = rows.firstIndex {
            if case .paneSectionHeader(let paneId, _) = $0 { return paneId == paneA }
            return false
        }!

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: headerRow, dropOperation: .on)

        #expect(target?.destination == .pane(paneA))
        #expect(target?.atIndex == 1)
    }

    @Test("resolveTabTodoDropTarget .on tabEmptyPlaceholder inserts at tab index 0")
    func resolveTabTodoDropTargetOnTabPlaceholderInsertsAtZero() {
        // Intent: drop .on tabEmptyPlaceholder inserts at the tab's
        //   index 0.
        // Why it exists: pins the empty-section drop rule (placeholder is
        //   the only visible target).
        // Scenario: spec-first empty drop.
        let (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let placeholderRow = rows.firstIndex(of: .tabEmptyPlaceholder)!

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: placeholderRow, dropOperation: .on)

        #expect(target?.destination == .tab(tabId))
        #expect(target?.atIndex == 0)
    }

    @Test("resolveTabTodoDropTarget .on paneEmptyPlaceholder inserts at pane index 0")
    func resolveTabTodoDropTargetOnPanePlaceholderInsertsAtZero() {
        // Intent: drop .on paneEmptyPlaceholder inserts at the pane's
        //   index 0.
        // Why it exists: pins the pane variant of the empty-section drop
        //   rule.
        // Scenario: spec-first empty pane drop.
        let (model, tabId, paneA, _) = makeTwoPaneTabTodoRowsModel()
        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let placeholderRow = rows.firstIndex(of: .paneEmptyPlaceholder(paneId: paneA))!

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: placeholderRow, dropOperation: .on)

        #expect(target?.destination == .pane(paneA))
        #expect(target?.atIndex == 0)
    }

    @Test("resolveTabTodoDropTarget .above first tabItem inserts at tab index 0")
    func resolveTabTodoDropTargetAboveFirstTabItem() {
        // Intent: drop .above the first tab item inserts at tab index 0.
        // Why it exists: pins the "above first item" rule.
        // Scenario: spec-first above-first -- drop above row 1 (first
        //   tab item) lands at tab index 0.
        var (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTabTodo(tabId: tabId, text: "tab A"))
        let rows = buildTabTodoRows(model: model, tabId: tabId)

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: 1, dropOperation: .above)

        #expect(target?.destination == .tab(tabId))
        #expect(target?.atIndex == 0)
    }

    @Test("resolveTabTodoDropTarget .above between two tabItems uses local index")
    func resolveTabTodoDropTargetAboveBetweenTabItems() {
        // Intent: drop .above a tabItem N inserts at the destination's
        //   local index N within the tab section.
        // Why it exists: pins the local-index translation that maps row
        //   ordinals to bucket-local indices.
        // Scenario: spec-first local-index -- two tab todos; drop above
        //   row 2 (second tab item) lands at tab index 1.
        var (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTabTodo(tabId: tabId, text: "tab A"))
        update(&model, .addTabTodo(tabId: tabId, text: "tab B"))
        let rows = buildTabTodoRows(model: model, tabId: tabId)

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: 2, dropOperation: .above)

        #expect(target?.destination == .tab(tabId))
        #expect(target?.atIndex == 1)
    }

    @Test("resolveTabTodoDropTarget .above paneSectionHeader appends to previous section")
    func resolveTabTodoDropTargetAbovePaneHeaderAppendsToPrev() {
        // Intent: drop .above a paneSectionHeader appends to the previous
        //   section (tab section here).
        // Why it exists: pins the "above the boundary between sections"
        //   rule.
        // Scenario: spec-first append-to-prev -- two tab todos; drop
        //   above the first paneSectionHeader lands at tab index 2
        //   (append).
        var (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTabTodo(tabId: tabId, text: "tab A"))
        update(&model, .addTabTodo(tabId: tabId, text: "tab B"))
        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let firstPaneHeader = rows.firstIndex {
            if case .paneSectionHeader = $0 { return true }
            return false
        }!

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: firstPaneHeader, dropOperation: .above)

        #expect(target?.destination == .tab(tabId))
        #expect(target?.atIndex == 2)
    }

    @Test("resolveTabTodoDropTarget .above one-past-end appends to last section")
    func resolveTabTodoDropTargetAboveOnePastEndAppendsToLast() {
        // Intent: drop .above rows.count (one-past-end) appends to the
        //   last visible section.
        // Why it exists: pins the trailing-edge drop rule.
        // Scenario: spec-first one-past-end -- paneB has one todo; drop
        //   above rows.count lands at pane B index 1.
        var (model, tabId, _, paneB) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTodo(paneId: paneB, text: "pane B"))
        let rows = buildTabTodoRows(model: model, tabId: tabId)

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: rows.count, dropOperation: .above)

        #expect(target?.destination == .pane(paneB))
        #expect(target?.atIndex == 1)
    }

    @Test("resolveTabTodoDropTarget .above tabEmptyPlaceholder inserts at tab index 0")
    func resolveTabTodoDropTargetAboveTabPlaceholderInsertsAtZero() {
        // Intent: drop .above the tab's empty placeholder inserts at tab
        //   index 0.
        // Why it exists: pins the empty-section .above rule.
        // Scenario: spec-first above-empty-tab.
        let (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let placeholderRow = rows.firstIndex(of: .tabEmptyPlaceholder)!

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: placeholderRow, dropOperation: .above)

        #expect(target?.destination == .tab(tabId))
        #expect(target?.atIndex == 0)
    }

    @Test("resolveTabTodoDropTarget .above paneEmptyPlaceholder inserts at pane index 0")
    func resolveTabTodoDropTargetAbovePanePlaceholderInsertsAtZero() {
        // Intent: drop .above a pane's empty placeholder inserts at the
        //   pane's index 0.
        // Why it exists: pins the empty-pane .above rule.
        // Scenario: spec-first above-empty-pane.
        let (model, tabId, paneA, _) = makeTwoPaneTabTodoRowsModel()
        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let placeholderRow = rows.firstIndex(of: .paneEmptyPlaceholder(paneId: paneA))!

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: placeholderRow, dropOperation: .above)

        #expect(target?.destination == .pane(paneA))
        #expect(target?.atIndex == 0)
    }

    @Test("resolveTabTodoDropTarget .above one-past-end appends to final placeholder section")
    func resolveTabTodoDropTargetAboveOnePastEndAppendsToFinalPlaceholder() {
        // Intent: with the final section empty (placeholder only), .above
        //   one-past-end appends to that placeholder section.
        // Why it exists: pins the trailing-edge rule against the
        //   placeholder boundary, not the underlying todos.
        // Scenario: spec-first one-past-end empty -- both panes empty;
        //   .above rows.count lands at paneB index 0.
        let (model, tabId, _, paneB) = makeTwoPaneTabTodoRowsModel()
        let rows = buildTabTodoRows(model: model, tabId: tabId)

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: rows.count, dropOperation: .above)

        #expect(target?.destination == .pane(paneB))
        #expect(target?.atIndex == 0)
    }

    @Test("resolveTabTodoDropTarget .above tabSectionHeader row 0 returns nil")
    func resolveTabTodoDropTargetAboveTabSectionHeaderRow0Nil() {
        // Intent: drop .above the very first row (the tab section header)
        //   yields no valid destination.
        // Why it exists: pins the leading-edge guard.
        // Scenario: spec-first above-row-zero.
        let (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        let rows = buildTabTodoRows(model: model, tabId: tabId)

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: 0, dropOperation: .above)

        #expect(target == nil)
    }

    @Test("resolveTabTodoBucketStep tab + delta=+1 returns pane0")
    func resolveTabTodoBucketStepTabPlusOneReturnsPane0() {
        // Intent: stepping +1 from the tab bucket returns the first pane.
        // Why it exists: pins the bucket-traversal order the keyboard
        //   shortcuts use.
        // Scenario: spec-first tab -> paneA.
        let (_, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()

        let destination = resolveTabTodoBucketStep(
            current: .tab(todoId: UUID()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            delta: 1
        )

        #expect(destination == .pane(paneA))
    }

    @Test("resolveTabTodoBucketStep pane0 + delta=-1 returns tab")
    func resolveTabTodoBucketStepPane0MinusOneReturnsTab() {
        // Intent: stepping -1 from the first pane returns the tab bucket.
        // Why it exists: pins the reverse direction of the same
        //   traversal.
        // Scenario: spec-first paneA -> tab.
        let (_, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()

        let destination = resolveTabTodoBucketStep(
            current: .pane(paneId: paneA, todoId: UUID()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            delta: -1
        )

        #expect(destination == .tab(tabId))
    }

    @Test("resolveTabTodoBucketStep tab + delta=-1 stops at start")
    func resolveTabTodoBucketStepTabMinusOneStops() {
        // Intent: stepping -1 from tab returns nil (clamped at start).
        // Why it exists: pins the leading-edge clamp the keyboard
        //   navigator reads to halt.
        // Scenario: spec-first start clamp.
        let (_, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()

        let destination = resolveTabTodoBucketStep(
            current: .tab(todoId: UUID()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            delta: -1
        )

        #expect(destination == nil)
    }

    @Test("resolveTabTodoBucketStep lastPane + delta=+1 stops at end")
    func resolveTabTodoBucketStepLastPanePlusOneStops() {
        // Intent: stepping +1 from the last pane returns nil (clamped at
        //   end).
        // Why it exists: pins the trailing-edge clamp.
        // Scenario: spec-first end clamp.
        let (_, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()

        let destination = resolveTabTodoBucketStep(
            current: .pane(paneId: paneB, todoId: UUID()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            delta: 1
        )

        #expect(destination == nil)
    }

    // MARK: - resolveTabTodoReorderStep

    @Test("resolveTabTodoReorderStep middle of tab section with delta=+1 reorders down")
    func resolveTabTodoReorderStepTabMiddlePlus1ReordersDown() {
        // Intent: a middle item in the tab section reorders within
        //   section (toIndex = currentIndex + 1).
        // Why it exists: pins the intra-section reorder of cmd-shift-j /
        //   cmd-shift-k.
        // Scenario: spec-first within-section -- delta +1 at index 1
        //   yields .reorderInSection(toIndex: 2).
        let tabId = TabId()

        let step = resolveTabTodoReorderStep(
            current: .tab(todoId: UUID()),
            paneOrder: [PaneId(), PaneId()],
            tabId: tabId,
            currentIndex: 1,
            currentSectionCount: 3,
            destinationSectionCount: { _ in 0 },
            delta: 1
        )

        #expect(step == .reorderInSection(toIndex: 2))
    }

    @Test("resolveTabTodoReorderStep middle of tab section with delta=-1 reorders up")
    func resolveTabTodoReorderStepTabMiddleMinus1ReordersUp() {
        // Intent: delta=-1 in the middle of a section reorders up.
        // Why it exists: pins the symmetric within-section reorder.
        // Scenario: spec-first within-section -- delta -1 at index 1
        //   yields .reorderInSection(toIndex: 0).
        let tabId = TabId()

        let step = resolveTabTodoReorderStep(
            current: .tab(todoId: UUID()),
            paneOrder: [PaneId(), PaneId()],
            tabId: tabId,
            currentIndex: 1,
            currentSectionCount: 3,
            destinationSectionCount: { _ in 0 },
            delta: -1
        )

        #expect(step == .reorderInSection(toIndex: 0))
    }

    @Test("resolveTabTodoReorderStep last tab item with delta=+1 moves to first pane at start")
    func resolveTabTodoReorderStepLastTabPlus1MovesToFirstPane() {
        // Intent: stepping +1 off the end of the tab section crosses
        //   into pane0 at index 0.
        // Why it exists: pins the cross-section transition that
        //   keyboards rely on to escape the section.
        // Scenario: spec-first cross-into-paneA at start.
        let tabId = TabId()
        let paneA = PaneId()
        let paneB = PaneId()

        let step = resolveTabTodoReorderStep(
            current: .tab(todoId: UUID()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            currentIndex: 2,
            currentSectionCount: 3,
            destinationSectionCount: { destination in
                destination == .pane(paneA) ? 2 : 0
            },
            delta: 1
        )

        #expect(step == .moveToBucket(destination: .pane(paneA), atIndex: 0))
    }

    @Test("resolveTabTodoReorderStep last tab item with delta=+1 moves to empty first pane at start")
    func resolveTabTodoReorderStepLastTabPlus1MovesToEmptyFirstPane() {
        // Intent: the same cross-section step works against an empty
        //   destination (index 0 still valid).
        // Why it exists: pins the empty-destination branch.
        // Scenario: spec-first cross-into-empty-paneA.
        let tabId = TabId()
        let paneA = PaneId()
        let paneB = PaneId()

        let step = resolveTabTodoReorderStep(
            current: .tab(todoId: UUID()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            currentIndex: 2,
            currentSectionCount: 3,
            destinationSectionCount: { _ in 0 },
            delta: 1
        )

        #expect(step == .moveToBucket(destination: .pane(paneA), atIndex: 0))
    }

    @Test("resolveTabTodoReorderStep first pane0 item with delta=-1 moves to tab end")
    func resolveTabTodoReorderStepFirstPane0Minus1MovesToTabEnd() {
        // Intent: stepping -1 off the start of paneA crosses into the
        //   tab section at its end (atIndex = destination count).
        // Why it exists: pins the symmetric cross-section transition.
        // Scenario: spec-first cross-into-tab at end (count == 3).
        let tabId = TabId()
        let paneA = PaneId()
        let paneB = PaneId()

        let step = resolveTabTodoReorderStep(
            current: .pane(paneId: paneA, todoId: UUID()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            currentIndex: 0,
            currentSectionCount: 2,
            destinationSectionCount: { destination in
                destination == .tab(tabId) ? 3 : 0
            },
            delta: -1
        )

        #expect(step == .moveToBucket(destination: .tab(tabId), atIndex: 3))
    }

    @Test("resolveTabTodoReorderStep first pane0 item with delta=-1 moves to empty tab at start")
    func resolveTabTodoReorderStepFirstPane0Minus1MovesToEmptyTabAtStart() {
        // Intent: with the tab section empty, the same backward step
        //   lands at tab index 0.
        // Why it exists: pins the empty-destination branch on the
        //   reverse direction.
        // Scenario: spec-first cross-into-empty-tab.
        let tabId = TabId()
        let paneA = PaneId()
        let paneB = PaneId()

        let step = resolveTabTodoReorderStep(
            current: .pane(paneId: paneA, todoId: UUID()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            currentIndex: 0,
            currentSectionCount: 2,
            destinationSectionCount: { _ in 0 },
            delta: -1
        )

        #expect(step == .moveToBucket(destination: .tab(tabId), atIndex: 0))
    }

    @Test("resolveTabTodoReorderStep last pane0 item with delta=+1 moves to pane1 start")
    func resolveTabTodoReorderStepLastPane0Plus1MovesToPane1Start() {
        // Intent: stepping +1 off the end of paneA crosses to paneB at
        //   index 0.
        // Why it exists: pins the pane-to-pane transition.
        // Scenario: spec-first paneA -> paneB at start.
        let tabId = TabId()
        let paneA = PaneId()
        let paneB = PaneId()

        let step = resolveTabTodoReorderStep(
            current: .pane(paneId: paneA, todoId: UUID()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            currentIndex: 3,
            currentSectionCount: 4,
            destinationSectionCount: { destination in
                destination == .pane(paneB) ? 2 : 0
            },
            delta: 1
        )

        #expect(step == .moveToBucket(destination: .pane(paneB), atIndex: 0))
    }

    @Test("resolveTabTodoReorderStep first pane1 item with delta=-1 moves to pane0 end")
    func resolveTabTodoReorderStepFirstPane1Minus1MovesToPane0End() {
        // Intent: stepping -1 off the start of paneB crosses to paneA at
        //   the end (atIndex == paneA count).
        // Why it exists: pins the reverse pane-to-pane transition.
        // Scenario: spec-first paneB -> paneA at end (count == 4).
        let tabId = TabId()
        let paneA = PaneId()
        let paneB = PaneId()

        let step = resolveTabTodoReorderStep(
            current: .pane(paneId: paneB, todoId: UUID()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            currentIndex: 0,
            currentSectionCount: 2,
            destinationSectionCount: { destination in
                destination == .pane(paneA) ? 4 : 0
            },
            delta: -1
        )

        #expect(step == .moveToBucket(destination: .pane(paneA), atIndex: 4))
    }

    @Test("resolveTabTodoReorderStep first tab item with delta=-1 stops at top")
    func resolveTabTodoReorderStepFirstTabMinus1Stops() {
        // Intent: stepping -1 at the start of the tab section returns
        //   nil (clamped).
        // Why it exists: pins the top-of-list clamp.
        // Scenario: spec-first top clamp.
        let tabId = TabId()
        let paneA = PaneId()
        let paneB = PaneId()

        let step = resolveTabTodoReorderStep(
            current: .tab(todoId: UUID()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            currentIndex: 0,
            currentSectionCount: 3,
            destinationSectionCount: { _ in 0 },
            delta: -1
        )

        #expect(step == nil)
    }

    @Test("resolveTabTodoReorderStep last last-pane item with delta=+1 stops at bottom")
    func resolveTabTodoReorderStepLastLastPanePlus1Stops() {
        // Intent: stepping +1 at the end of the last pane returns nil
        //   (clamped).
        // Why it exists: pins the bottom-of-list clamp.
        // Scenario: spec-first bottom clamp.
        let tabId = TabId()
        let paneA = PaneId()
        let paneB = PaneId()

        let step = resolveTabTodoReorderStep(
            current: .pane(paneId: paneB, todoId: UUID()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            currentIndex: 1,
            currentSectionCount: 2,
            destinationSectionCount: { _ in 0 },
            delta: 1
        )

        #expect(step == nil)
    }

    @Test("assignJumpKeys caps mapping at jump key sequence count")
    func assignJumpKeysCapsAtSequenceCount() {
        // Intent: with more tabs than jump keys, only the first
        //   jumpModeKeySequence.count tabs are mapped.
        // Why it exists: pins the cap so the overlay never assigns
        //   beyond the documented sequence.
        // Scenario: spec-first cap -- count + 3 tabs; only count get
        //   keys.
        let ids = (0..<(jumpModeKeySequence.count + 3)).map { _ in TabId() }
        let keyMap = assignJumpKeys(visibleTabs: ids)
        #expect(keyMap.count == jumpModeKeySequence.count)
        #expect(keyMap[ids[jumpModeKeySequence.count - 1]] != nil)
        #expect(keyMap[ids[jumpModeKeySequence.count]] == nil)
        #expect(keyMap[ids[jumpModeKeySequence.count + 2]] == nil)
    }

    // MARK: - desiredThemeBrowser

    @Test("desiredThemeBrowser: tracks the focused pane's theme across same-tab focus")
    func desiredThemeBrowserTracksFocusedPaneTheme() {
        // Intent: desiredThemeBrowser.currentThemeName reads the
        //   currently focused pane's theme; same-tab focus changes flip
        //   it.
        // Why it exists: pins the live update the theme browser reads
        //   to reflect the active pane.
        // Scenario: spec-first focus follow -- split tab with two
        //   themed panes; switching focus across panes flips the
        //   projected theme.
        var model = makeModel()
        createTab(&model)
        let paneA = selectedTab(in: model)!.focusedPaneId
        update(&model, .splitPane(paneId: paneA, direction: .horizontal))
        let focused = selectedTab(in: model)!.focusedPaneId
        let other = allPaneIds(selectedTab(in: model)!.rootNode).first { $0 != focused }!
        update(&model, .setPaneTheme(paneId: focused, themeName: "Dracula"))
        update(&model, .setPaneTheme(paneId: other, themeName: "Nord"))

        #expect(desiredThemeBrowser(in: model).currentThemeName == "Dracula",
            "projection returns the focused pane's theme")

        update(&model, .paneBecameFirstResponder(paneId: other))
        #expect(desiredThemeBrowser(in: model).currentThemeName == "Nord",
            "projection updates on same-tab focus change -- the bug this fixes")
    }

    @Test("desiredThemeBrowser: nil theme when no selected tab or no override")
    func desiredThemeBrowserNilWhenNoSelectedTabOrTheme() {
        // Intent: currentThemeName is nil if there's no selected tab or
        //   no pane theme set.
        // Why it exists: pins the absence branch the browser uses to
        //   show the default placeholder.
        // Scenario: spec-first absence -- empty model, then a tab with
        //   no theme set.
        var model = makeModel()

        #expect(desiredThemeBrowser(in: model).currentThemeName == nil)

        createTab(&model)
        #expect(desiredThemeBrowser(in: model).currentThemeName == nil)
    }

    @Test("desiredThemeBrowser: reports the user theme, not the remote override")
    func desiredThemeBrowserReportsUserNotRemoteOverride() {
        // Intent: the browser shows the user-set pane.theme, not the
        //   transient remoteThemeOverride.
        // Why it exists: pins the "show the user's choice" rule so the
        //   browser doesn't drift to remote themes during SSH sessions.
        // Scenario: spec-first override-vs-user -- pane has theme
        //   "Dracula" and a remote override "Purplepeter"; the browser
        //   reports Dracula.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .setPaneTheme(paneId: paneId, themeName: "Dracula"))
        model.updatePane(paneId) { $0.remoteThemeOverride = "Purplepeter" }

        #expect(desiredThemeBrowser(in: model).currentThemeName == "Dracula",
            "projection reads pane.theme, never effectiveTheme")
    }

    // MARK: - desiredFocusBorders (focus-border projection, Stage 3)

    @Test("desiredFocusBorders: single-pane selected tab draws no focus border (bell still shows)")
    func desiredFocusBordersSinglePaneNoBorderBellOk() {
        // Intent: a single-pane selected tab reports focused=false; an
        //   unread alert still flips bell=true.
        // Why it exists: pins the single-pane suppression rule against
        //   the bell-border independence.
        // Scenario: spec-first dual-check -- no border initially; bell
        //   true after inserting an unread alert.
        var model = makeModel()
        createTab(&model)
        let pane = selectedTab(in: model)!.focusedPaneId
        #expect(
            desiredFocusBorders(in: model)[pane] ==
            BorderState(focused: false, bell: false),
            "single-pane focused tab draws no border")
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: pane,
            title: "DanTerm", body: "x", createdAt: Date(), isUnread: true), at: 0)
        #expect(
            desiredFocusBorders(in: model)[pane] ==
            BorderState(focused: false, bell: true),
            "single-pane tab still shows the bell border")
    }

    @Test("desiredFocusBorders: split tab marks the focused pane, bell follows unread alert")
    func desiredFocusBordersSplitTabFocusBellPerPane() {
        // Intent: in a split tab, the focused pane has focused=true and
        //   bell=false; an unread alert on the sibling flips its
        //   bell=true (without touching the focused pane).
        // Why it exists: pins the per-pane border decomposition in a
        //   multi-pane tab.
        // Scenario: spec-first split-tab check -- two panes, alert lands
        //   on the unfocused one; focused stays unaffected.
        var model = makeModel()
        createTab(&model)
        let paneA = selectedTab(in: model)!.focusedPaneId
        update(&model, .splitPane(paneId: paneA, direction: .horizontal))
        let focusedId = selectedTab(in: model)!.focusedPaneId
        let otherId = allPaneIds(selectedTab(in: model)!.rootNode).first { $0 != focusedId }!

        var borders = desiredFocusBorders(in: model)
        #expect(borders[focusedId] == BorderState(focused: true, bell: false),
            "focused pane in a split tab draws the focus border")
        #expect(borders[otherId] == BorderState(focused: false, bell: false),
            "unfocused sibling draws no border")

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: otherId,
            title: "DanTerm", body: "x", createdAt: Date(), isUnread: true), at: 0)
        borders = desiredFocusBorders(in: model)
        #expect(borders[otherId] == BorderState(focused: false, bell: true),
            "unfocused pane with an unread alert shows the bell border")
        #expect(borders[focusedId] == BorderState(focused: true, bell: false),
            "focused pane is unaffected by a sibling's alert")
    }

    @Test("desiredFocusBorders: keyed over all live panes; non-selected tabs draw no border")
    func desiredFocusBordersKeyedOverAllLivePanes() {
        // Intent: borders dict is keyed over every live pane; panes in
        //   non-selected tabs all report focused=false, bell=false.
        // Why it exists: pins the coverage invariant the diff reads to
        //   know which keys to remove.
        // Scenario: spec-first coverage -- two tabs (selected split,
        //   background single); background panes report no border.
        var model = makeModel()
        createTab(&model)
        let tab0Pane = selectedTab(in: model)!.focusedPaneId
        update(&model, .splitPane(paneId: tab0Pane, direction: .horizontal))
        createTab(&model)

        let borders = desiredFocusBorders(in: model)
        #expect(Set(borders.keys) == Set(model.allPaneIds),
            "projection is keyed over every live pane")
        for paneId in allPaneIds(model.groups[0].tabs[0].rootNode) {
            #expect(borders[paneId] == BorderState(focused: false, bell: false),
                "panes in a non-selected tab draw no border")
        }
    }

    // MARK: - desiredPaneToolbar (pane-toolbar projection, Stage 4)

    @Test("desiredPaneToolbar: derives all eight toolbar fields from the model + pane")
    func desiredPaneToolbarDerivesAllFields() {
        // Intent: the projection derives title, cwd, progress, isRemote,
        //   remoteSession, unreadAlertCount, totalTodoCount, and
        //   uncompletedTodoCount from the pane + model.alerts.
        // Why it exists: pins the eight-field render contract so a UI
        //   refactor cannot silently drop a field.
        // Scenario: spec-first full-field check -- a populated pane with
        //   two unread + one read alert renders the documented
        //   PaneToolbarRender.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        model.updatePane(paneId) {
            $0.title = "vim"
            $0.cwd = "/work/proj"
            $0.progress = .set(percent: 42)
            $0.isRemote = true
            $0.remoteSession = RemoteSession(user: "dan", host: "caja")
            $0.todos = [
                TodoItem(id: UUID(), text: "a", isDone: false),
                TodoItem(id: UUID(), text: "b", isDone: true),
                TodoItem(id: UUID(), text: "c", isDone: false),
            ]
        }
        for unread in [true, true, false] {
            model.alerts.insert(AlertModel(
                id: AlertId(), kind: .bell, paneId: paneId,
                title: "DanTerm", body: "x", createdAt: Date(), isUnread: unread), at: 0)
        }
        #expect(
            desiredPaneToolbar(in: model)[paneId] ==
            PaneToolbarRender(
                title: "vim",
                cwd: "/work/proj",
                progress: .set(percent: 42),
                isRemote: true,
                remoteSession: RemoteSession(user: "dan", host: "caja"),
                unreadAlertCount: 2,
                totalTodoCount: 3,
                uncompletedTodoCount: 2),
            "all eight toolbar fields derive from the pane + model.alerts")
    }

    @Test("desiredPaneToolbar: keyed over every live pane")
    func desiredPaneToolbarKeyedOverEveryLivePane() {
        // Intent: the projection is keyed over allPaneIds.
        // Why it exists: pins the coverage invariant the diff relies on
        //   so toolbars for background panes stay around for selection
        //   switches.
        // Scenario: spec-first coverage.
        var model = makeModel()
        createTab(&model)
        let tab0Pane = selectedTab(in: model)!.focusedPaneId
        update(&model, .splitPane(paneId: tab0Pane, direction: .horizontal))
        createTab(&model)
        #expect(Set(desiredPaneToolbar(in: model).keys) == Set(model.allPaneIds),
            "toolbar projection covers all live panes (host destroyed elsewhere -> default no-op remove)")
    }

    // MARK: - desiredSearchOverlays (search-overlay projection, Stage 4)

    @Test("desiredSearchOverlays: keyed only while search is active; drops the key on endSearch")
    func desiredSearchOverlaysKeyedWhileActiveDropsOnEnd() {
        // Intent: the overlay dict keys a pane only while its searchState
        //   exists; endSearch drops the key.
        // Why it exists: pins the appearance/disappearance contract the
        //   reconciler uses to show/hide the overlay.
        // Scenario: spec-first lifecycle -- no key pre-search, full
        //   render mid-search, no key post-search.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        #expect(desiredSearchOverlays(in: model)[paneId] == nil,
            "no active search -> no key")

        update(&model, .ghosttyStartSearch(paneId: paneId, needle: "foo"))
        model.searchState[paneId]?.total = 7
        model.searchState[paneId]?.selected = 2
        #expect(
            desiredSearchOverlays(in: model)[paneId] ==
            SearchOverlayRender(needle: "foo", total: 7, selected: 2),
            "active search keys the pane with needle + match counts")

        update(&model, .endSearch(paneId: paneId))
        #expect(desiredSearchOverlays(in: model)[paneId] == nil,
            "ended search drops the pane's key (disappear-but-host-survives)")
    }

    // MARK: - desiredPaneConfig (pane-config projection)

    @Test("desiredPaneConfig: keyed only for themed panes; drops the key on clear")
    func desiredPaneConfigKeyedForThemedDropsOnClear() {
        // Intent: a pane's config key exists only while it has a theme;
        //   clearing the theme drops the key.
        // Why it exists: pins the disappear-but-host-survives net for
        //   per-pane Ghostty config application.
        // Scenario: spec-first lifecycle -- no key pre-set, set "Dracula"
        //   (key appears), clear (key disappears).
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId

        #expect(desiredPaneConfig(in: model)[paneId] == nil,
            "nil theme -> no config key")

        update(&model, .setPaneTheme(paneId: paneId, themeName: "Dracula"))
        #expect(
            desiredPaneConfig(in: model)[paneId] ==
            PaneConfigKey(theme: "Dracula", generation: 0),
            "set theme keys the pane")

        update(&model, .setPaneTheme(paneId: paneId, themeName: nil))
        #expect(desiredPaneConfig(in: model)[paneId] == nil,
            "cleared theme drops the pane's key")
    }

    @Test("desiredPaneConfig: remote override takes priority over user theme")
    func desiredPaneConfigRemoteOverridePrioritized() {
        // Intent: when remoteThemeOverride is set, the projected theme
        //   matches the override.
        // Why it exists: pins effective-theme semantics in the pane-
        //   config projection.
        // Scenario: spec-first override -- theme "Dracula" + override
        //   "Purplepeter" -> Purplepeter.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        model.updatePane(paneId) { pane in
            pane.theme = "Dracula"
            pane.remoteThemeOverride = "Purplepeter"
        }

        #expect(
            desiredPaneConfig(in: model)[paneId] ==
            PaneConfigKey(theme: "Purplepeter", generation: 0),
            "effective theme prefers remote override")
    }

    @Test("desiredPaneConfig: ghosttyConfigReloaded changes every themed pane generation")
    func desiredPaneConfigReloadBumpsGeneration() {
        // Intent: ghosttyConfigReloaded bumps every themed pane's
        //   generation while leaving unthemed panes absent.
        // Why it exists: pins the reload-propagation rule that drives
        //   per-pane config refreshes after a global Ghostty reload.
        // Scenario: spec-first reload -- two themed panes + one
        //   unthemed; reload increments both themed generations and
        //   keeps the unthemed pane absent.
        var model = makeModel()
        createTab(&model)
        let firstPaneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .setPaneTheme(paneId: firstPaneId, themeName: "Dracula"))
        update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let themedPaneIds = Set(desiredPaneConfig(in: model).keys)
        createTab(&model)
        let unthemedPaneId = selectedTab(in: model)!.focusedPaneId

        let before = desiredPaneConfig(in: model)
        #expect(Set(before.keys) == themedPaneIds)
        #expect(before[unthemedPaneId] == nil, "unthemed pane is absent before reload")

        update(&model, .ghosttyConfigReloaded)
        let after = desiredPaneConfig(in: model)
        #expect(Set(after.keys) == themedPaneIds)
        #expect(after[unthemedPaneId] == nil, "unthemed pane stays absent after reload")
        for paneId in themedPaneIds {
            #expect(after[paneId]?.generation == (before[paneId]?.generation ?? -1) + 1)
            #expect(after[paneId]?.theme == before[paneId]?.theme)
        }
    }

    @Test("ghosttyConfigReloaded increments generation and returns no commands")
    func ghosttyConfigReloadedIncrementsGenerationNoCommands() {
        // Intent: ghosttyConfigReloaded bumps model.ghosttyConfigGeneration
        //   and emits no commands.
        // Why it exists: pins the bare state mutation against silent
        //   side-effect leakage.
        // Scenario: spec-first generation bump.
        var model = makeModel()
        let commands = update(&model, .ghosttyConfigReloaded)

        #expect(model.ghosttyConfigGeneration == 1)
        #expect(commands.count == 0)
    }

    // MARK: - desiredSidebar (sidebar projection, Stage 5)

    @Test("desiredSidebar: ordered groups -> tabs with rendered attrs, collapse, jump badge")
    func desiredSidebarOrderedGroupsTabsAttrsCollapseJump() {
        // Intent: the sidebar projection lists groups in model order, each
        //   with collapse + isFirst + tabCount + unreadAlertCount, and tabs
        //   with displayTitle/subtitle/color/unreadAlertCount + optional
        //   jumpKey from jumpMode.keyMap.
        // Why it exists: pins the sidebar render contract end to end across
        //   every projected field.
        // Scenario: spec-first full-projection -- two groups (Work collapsed
        //   with two tabs incl. customTitle/color/alert, Home with one
        //   tab); tab B has a jump key.
        let g1 = GroupId(); let g2 = GroupId()
        let tA = TabId(); let tB = TabId(); let tC = TabId()
        let pA = PaneId(); let pB = PaneId(); let pC = PaneId()
        var paneA = PaneModel(id: pA)
        paneA.title = "shell"
        paneA.cwd = "\(NSHomeDirectory())/src"
        var tabA = TabModel(id: tA, focusedPaneId: pA, rootNode: .leaf(paneA))
        tabA.customTitle = "Edited"; tabA.color = .blue
        let tabB = TabModel(id: tB, focusedPaneId: pB, rootNode: .leaf(PaneModel(id: pB)))
        let tabC = TabModel(id: tC, focusedPaneId: pC, rootNode: .leaf(PaneModel(id: pC)))
        var model = AppModel(groups: [
            GroupModel(id: g1, name: "Work", isCollapsed: true, tabs: [tabA, tabB]),
            GroupModel(id: g2, name: "Home", tabs: [tabC]),
        ], selectedTabId: tA)
        model.alerts = [AlertModel(id: AlertId(), kind: .bell, paneId: pA,
            title: "t", body: "b", createdAt: Date(), isUnread: true)]
        model.jumpMode = JumpModeState(keyMap: [tB: "j"])

        let proj = desiredSidebar(in: model)
        #expect(!proj.isSingleGroupMode, "two groups -> not single-group mode")
        #expect(proj.groups.map(\.id) == [g1, g2], "groups in model order")

        let work = proj.groups[0]
        #expect(work.name == "Work")
        #expect(work.isCollapsed, "collapse projected from the model")
        #expect(work.isFirst, "first group flagged")
        #expect(work.tabCount == 2)
        #expect(work.unreadAlertCount == 1, "group bell rolls up its tabs' unread alerts")
        #expect(work.tabs.map(\.id) == [tA, tB], "tabs in group order")
        #expect(work.tabs[0].displayTitle == "Edited")
        #expect(work.tabs[0].subtitle == "~/src")
        #expect(work.tabs[0].color == .blue)
        #expect(work.tabs[0].unreadAlertCount == 1)
        #expect(work.tabs[0].jumpKey == nil, "tab A has no jump key")
        #expect(work.tabs[1].jumpKey == "j", "jump badge from model.jumpMode.keyMap")
        #expect(!proj.groups[1].isFirst, "second group not first")
    }

    @Test("desiredSidebar: projection excludes selection (independent of selectedTabId)")
    func desiredSidebarExcludesSelection() {
        // Intent: the sidebar projection is independent of
        //   selectedTabId.
        // Why it exists: pins the view-owned selection rule so the
        //   projection doesn't churn on selection changes.
        // Scenario: spec-first selection-independence -- swap
        //   selectedTabId, projection unchanged.
        let (model, ids) = makeMruModel(tabCount: 3)
        var other = model
        other.selectedTabId = ids[2]
        #expect(model.selectedTabId != other.selectedTabId, "precondition: selection differs")
        #expect(desiredSidebar(in: model) == desiredSidebar(in: other),
            "selection is view-owned -> not in the projection")
    }

    @Test("desiredSidebar: one group is single-group mode")
    func desiredSidebarOneGroupIsSingleGroupMode() {
        // Intent: a one-group sidebar is single-group mode (tabs roll up
        //   without a group header).
        // Why it exists: pins the mode flag the sidebar layout reads.
        // Scenario: spec-first single-group.
        let (model, _) = makeMruModel(tabCount: 2)
        #expect(desiredSidebar(in: model).isSingleGroupMode,
            "a single group promotes tabs to roots (no group row)")
    }

    // MARK: - desiredWindowChrome (window title / badges / tab-todo projection, Stage 6)

    @Test("desiredWindowChrome: window/content titles, unread count, and tab-todo rollup from the selected tab")
    func desiredWindowChromeAllFields() {
        // Intent: desiredWindowChrome derives windowTitle ("Custom — sub"),
        //   contentTitle ("Custom"), unreadCount (only unread alerts), and
        //   tabTodoTotal/uncompleted (tab + pane todos in the selected tab).
        // Why it exists: pins the full window-chrome render contract,
        //   including the subtitle-join and todo rollup.
        // Scenario: spec-first projection -- custom-title tab with a cwd
        //   subtitle, mixed tab + pane todos, two unread + one read alert.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        model.groups[0].tabs[0].customTitle = "Custom"
        model.updatePane(paneId) { $0.cwd = "\(NSHomeDirectory())/src" }
        model.groups[0].tabs[0].todos = [TodoItem(id: UUID(), text: "t1", isDone: false)]
        model.updatePane(paneId) {
            $0.todos = [
                TodoItem(id: UUID(), text: "p1", isDone: true),
                TodoItem(id: UUID(), text: "p2", isDone: false),
            ]
        }
        for unread in [true, true, false] {
            model.alerts.insert(AlertModel(
                id: AlertId(), kind: .bell, paneId: paneId,
                title: "DanTerm", body: "x", createdAt: Date(), isUnread: unread), at: 0)
        }
        #expect(
            desiredWindowChrome(in: model) ==
            WindowChromeProjection(
                windowTitle: "Custom — ~/src",
                contentTitle: "Custom",
                unreadCount: 2,
                tabTodoTotal: 3,
                tabTodoUncompleted: 2),
            "window chrome derives both titles, the unread badge count, and the tab-todo rollup")
    }

    @Test("desiredWindowChrome: no selected tab -> empty titles, zero badge, zero rollup")
    func desiredWindowChromeNoSelectedTab() {
        // Intent: with no selected tab, windowTitle and contentTitle are
        //   empty and all counts are zero.
        // Why it exists: pins the empty-state branch.
        // Scenario: spec-first empty model.
        let model = makeModel()
        #expect(selectedTab(in: model) == nil, "precondition: no selected tab")
        #expect(
            desiredWindowChrome(in: model) ==
            WindowChromeProjection(
                windowTitle: "", contentTitle: "",
                unreadCount: 0, tabTodoTotal: 0, tabTodoUncompleted: 0),
            "no selected tab -> empty titles, zero badge, (0,0) rollup")
    }

    @Test("desiredWindowChrome: window title omits the subtitle when absent or equal to the display title")
    func desiredWindowChromeOmitsSubtitleWhenAbsentOrEqual() {
        // Intent: when no subtitle exists, or it equals the display title,
        //   windowTitle is just the display title.
        // Why it exists: pins the subtitle-suppression rule that keeps
        //   redundancy out of the window title.
        // Scenario: spec-first dual-check -- no subtitle case, then
        //   subtitle equal to display title.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.updatePane(paneId) { $0.title = "vim" }
        var proj = desiredWindowChrome(in: model)
        #expect(proj.windowTitle == "vim", "no subtitle -> window title is the bare display title")
        #expect(proj.contentTitle == "vim")
        model.groups[0].tabs[0].customTitle = "~/src"
        model.updatePane(paneId) { $0.cwd = "\(NSHomeDirectory())/src" }
        proj = desiredWindowChrome(in: model)
        #expect(proj.windowTitle == "~/src", "subtitle == display title is suppressed")
    }

    @Test("desiredWindowChrome: reflects the selected tab, not background tabs")
    func desiredWindowChromeReflectsSelectedTab() {
        // Intent: changing selectedTabId flips the projection's
        //   contentTitle to the new tab's display title.
        // Why it exists: pins the selection-drives-projection rule the
        //   reconciler relies on (replacing the deleted .setWindowTitle
        //   selection-change emission).
        // Scenario: spec-first selection-drive -- two tabs A/B with
        //   distinct customTitles; selecting A flips contentTitle to
        //   Alpha, then B flips it to Beta.
        var model = makeModel()
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        model.groups[0].tabs[0].customTitle = "Alpha"
        createTab(&model)
        model.groups[0].tabs[1].customTitle = "Beta"

        #expect(desiredWindowChrome(in: model).contentTitle == "Beta",
            "chrome reflects the selected tab B")
        model.selectedTabId = tabAId
        #expect(desiredWindowChrome(in: model).contentTitle == "Alpha",
            "selecting tab A makes the chrome reflect A")
    }
}
