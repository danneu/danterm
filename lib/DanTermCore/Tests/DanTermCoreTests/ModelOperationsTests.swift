// Behavioral coverage for ModelOperations.swift: the pure split-tree queries
// and rewrites (allPaneIds, firstLeafId/lastLeafId, nearestLeaf, splitLeaf,
// removeLeaf, swapLeaves, moveLeaf, setRatio), pane visibility and pane
// side-table cleanup, MRU reconciliation and live-cycle remapping, the sidebar
// context / reload-selection / row-emphasis resolvers, batch color resolution,
// tab-todo rollup, and jump-key assignment.
//
// Not here: the `desired*` projections defined in Projections.swift
// (ProjectionsTests.swift), the tab-todo row model and its resolvers from
// TabTodo.swift (TabTodoTests.swift), and the ModelOperations.swift subjects
// that already have files of their own (SwitcherEventTests.swift,
// UnreadAlertTallyTests.swift). The cross-suite MRU and two-pane tab-todo
// fixtures live in TestSupport.swift.
import Foundation
import Testing

@testable import DanTermCore

private func makeVisibilityModel(tabs: [TabModel], selectedTabId: TabId?) -> AppModel {
    AppModel(
        groups: [GroupModel(id: GroupId(), name: "General", tabs: tabs)],
        selectedTabId: selectedTabId
    )
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

    // MARK: - effectivePaneVisibility

    @Test("effectivePaneVisibility marks every reachable pane hidden when window is hidden")
    func effectivePaneVisibilityHidesAllWhenWindowHidden() {
        // Intent: with windowVisible: false, every pane in every tab is hidden.
        // Why it exists: pins the window-hidden short-circuit so a refactor
        //   cannot accidentally leak per-tab visibility decisions when the
        //   window itself is occluded.
        // Scenario: spec-first window-hidden check -- two tabs, one split,
        //   window not visible; all three panes report hidden.
        let a = PaneId(), b = PaneId(), c = PaneId()
        let tabAId = TabId(), tabBId = TabId()
        let tabA = TabModel(id: tabAId, paneTree: PaneTree(root: .split(
                id: SplitId(), direction: .horizontal,
                first: .leaf(PaneModel(id: a)),
                second: .leaf(PaneModel(id: b)),
                ratio: 0.5
            ), focusedPaneId: a))
        let tabB = TabModel(id: tabBId, paneTree: PaneTree(root: .leaf(PaneModel(id: c)), focusedPaneId: c))
        let model = makeVisibilityModel(tabs: [tabA, tabB], selectedTabId: tabAId)

        let visibility = effectivePaneVisibility(in: model, windowVisible: false)

        #expect(visibility == [a: false, b: false, c: false])
    }

    @Test("effectivePaneVisibility marks a selected single-pane tab visible")
    func effectivePaneVisibilityVisibleSinglePane() {
        // Intent: a selected single-pane tab reports its pane visible.
        // Why it exists: pins the happy path of the visibility projection.
        // Scenario: spec-first single-pane check -- one tab, one pane, window
        //   visible.
        let paneId = PaneId()
        let tabId = TabId()
        let tab = TabModel(id: tabId, paneTree: PaneTree(root: .leaf(PaneModel(id: paneId)), focusedPaneId: paneId))
        let model = makeVisibilityModel(tabs: [tab], selectedTabId: tabId)

        let visibility = effectivePaneVisibility(in: model, windowVisible: true)

        #expect(visibility == [paneId: true])
    }

    @Test("effectivePaneVisibility hides panes in non-selected tabs")
    func effectivePaneVisibilityHidesNonSelectedTabs() {
        // Intent: panes in a non-selected tab are hidden even when the window
        //   is visible.
        // Why it exists: pins per-tab scoping so background-tab sessions stay
        //   hidden until selected.
        // Scenario: spec-first scoping check -- two tabs (selected split,
        //   background single-pane); the background pane reports hidden.
        let selectedA = PaneId(), selectedB = PaneId(), background = PaneId()
        let selectedTabId = TabId(), backgroundTabId = TabId()
        let selectedTab = TabModel(id: selectedTabId, paneTree: PaneTree(root: .split(
                id: SplitId(), direction: .horizontal,
                first: .leaf(PaneModel(id: selectedA)),
                second: .leaf(PaneModel(id: selectedB)),
                ratio: 0.5
            ), focusedPaneId: selectedA))
        let backgroundTab = TabModel(id: backgroundTabId, paneTree: PaneTree(root: .leaf(PaneModel(id: background)), focusedPaneId: background))
        let model = makeVisibilityModel(tabs: [selectedTab, backgroundTab], selectedTabId: selectedTabId)

        let visibility = effectivePaneVisibility(in: model, windowVisible: true)

        #expect(visibility == [selectedA: true, selectedB: true, background: false])
    }

    @Test("effectivePaneVisibility hides zoomed sibling panes")
    func effectivePaneVisibilityHidesZoomedSiblings() {
        // Intent: when a tab is zoomed, only the focused pane is visible; its
        //   siblings hide.
        // Why it exists: pins the zoom contract that drives session rendering
        //   suspension on hidden siblings.
        // Scenario: spec-first zoom check -- a split tab with isZoomed=true
        //   reports the focused pane visible and the sibling hidden.
        let focused = PaneId(), sibling = PaneId()
        let tabId = TabId()
        let tab = TabModel(id: tabId, paneTree: PaneTree(root: .split(
                id: SplitId(), direction: .horizontal,
                first: .leaf(PaneModel(id: focused)),
                second: .leaf(PaneModel(id: sibling)),
                ratio: 0.5
            ), focusedPaneId: focused, isZoomed: true))
        let model = makeVisibilityModel(tabs: [tab], selectedTabId: tabId)

        let visibility = effectivePaneVisibility(in: model, windowVisible: true)

        #expect(visibility == [focused: true, sibling: false])
    }

    @Test("effectivePaneVisibility keeps a zoomed single-pane tab visible")
    func effectivePaneVisibilityZoomedSinglePaneVisible() {
        // Intent: zoom on a single-pane tab keeps the pane visible (no
        //   siblings to hide).
        // Why it exists: pins the zoom corner case that hits the same code
        //   path as a split-tab zoom but with one leaf.
        // Scenario: spec-first zoom corner case -- a zoomed single-pane tab
        //   reports the pane visible.
        let paneId = PaneId()
        let tabId = TabId()
        let tab = TabModel(id: tabId, paneTree: PaneTree(root: .leaf(PaneModel(id: paneId)), focusedPaneId: paneId, isZoomed: true))
        let model = makeVisibilityModel(tabs: [tab], selectedTabId: tabId)

        let visibility = effectivePaneVisibility(in: model, windowVisible: true)

        #expect(visibility == [paneId: true])
    }

    @Test("effectivePaneVisibility hides every pane when there is no selected tab")
    func effectivePaneVisibilityNoSelectedHidesAll() {
        // Intent: with selectedTabId nil, every pane is hidden even on a
        //   visible window.
        // Why it exists: pins the "no selection" guard against accidental
        //   visibility leaks during transient empty-selection states.
        // Scenario: spec-first empty-selection check -- a single split tab,
        //   selectedTabId nil; both panes report hidden.
        let a = PaneId(), b = PaneId()
        let tabId = TabId()
        let tab = TabModel(id: tabId, paneTree: PaneTree(root: .split(
                id: SplitId(), direction: .horizontal,
                first: .leaf(PaneModel(id: a)),
                second: .leaf(PaneModel(id: b)),
                ratio: 0.5
            ), focusedPaneId: a))
        let model = makeVisibilityModel(tabs: [tab], selectedTabId: nil)

        let visibility = effectivePaneVisibility(in: model, windowVisible: true)

        #expect(visibility == [a: false, b: false])
    }

    @Test("effectivePaneVisibility marks every selected nested split leaf visible")
    func effectivePaneVisibilityNestedSplitAllVisible() {
        // Intent: every leaf in the selected tab's nested split tree is
        //   visible (when not zoomed).
        // Why it exists: pins the visibility walker's coverage of nested
        //   splits so an off-by-one in recursion is caught.
        // Scenario: spec-first deep-tree check -- three leaves under a nested
        //   horizontal/vertical split all report visible.
        let a = PaneId(), b = PaneId(), c = PaneId()
        let tabId = TabId()
        let tab = TabModel(id: tabId, paneTree: PaneTree(root: .split(
                id: SplitId(), direction: .horizontal,
                first: .leaf(PaneModel(id: a)),
                second: .split(
                    id: SplitId(), direction: .vertical,
                    first: .leaf(PaneModel(id: b)),
                    second: .leaf(PaneModel(id: c)),
                    ratio: 0.5
                ),
                ratio: 0.5
            ), focusedPaneId: a))
        let model = makeVisibilityModel(tabs: [tab], selectedTabId: tabId)

        let visibility = effectivePaneVisibility(in: model, windowVisible: true)

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

    // MARK: - reconcileTabState

    @Test("reconcileTabState on full live order is a no-op except possible hoist")
    func reconcileTabStateNoOpExceptHoist() {
        // Intent: with mruOrder == live order and a non-cycling selected
        //   head, reconcileTabState leaves mruOrder unchanged.
        // Why it exists: pins the fast path so a stable selection doesn't
        //   ripple through the order on every update().
        // Scenario: spec-first steady-state -- mruOrder == ids,
        //   selectedTabId == ids[0].
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.mruOrder = ids
        model.selectedTabId = ids[0]
        reconcileTabState(&model)
        #expect(model.mruOrder == ids)
    }

    @Test("reconcileTabState hoists selectedTabId to index 0 when not cycling")
    func reconcileTabStateHoistsSelectedWhenNotCycling() {
        // Intent: when not cycling, reconcileTabState moves selectedTabId to
        //   index 0.
        // Why it exists: pins the "selection drives MRU" rule outside of
        //   cmd-tab cycling.
        // Scenario: spec-first hoist -- mruOrder [A,B,C], selectedTabId C
        //   reconciles to [C,A,B].
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.mruOrder = ids
        model.selectedTabId = ids[2]
        reconcileTabState(&model)
        #expect(model.mruOrder == [ids[2], ids[0], ids[1]])
    }

    @Test("reconcileTabState does NOT hoist when cycling")
    func reconcileTabStateDoesNotHoistWhenCycling() {
        // Intent: during a cycle (mruCycle != nil), reconcileTabState leaves
        //   mruOrder frozen even if selection drifts.
        // Why it exists: pins the freeze the cmd-tab UX depends on so the
        //   row order stays stable across cursor moves.
        // Scenario: spec-first cycle freeze.
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.mruOrder = ids
        model.selectedTabId = ids[2]
        model.mruCycle = MruCycleState(frozenOrder: ids, cursorIndex: 1)
        reconcileTabState(&model)
        #expect(model.mruOrder == ids)
    }

    @Test("reconcileTabState prunes stale ids")
    func reconcileTabStatePrunesStaleIds() {
        // Intent: reconcileTabState drops mruOrder entries that no longer map
        //   to a live tab.
        // Why it exists: pins the cleanup that prevents the switcher panel
        //   from showing ghost tabs.
        // Scenario: spec-first ghost prune -- mruOrder = [ghost, live1,
        //   live2] -> [live1, live2].
        let (m0, ids) = makeMruModel(tabCount: 2)
        var model = m0
        let ghost = TabId()
        model.mruOrder = [ghost, ids[0], ids[1]]
        reconcileTabState(&model)
        #expect(!model.mruOrder.contains(ghost), "ghost id must be pruned")
        #expect(Set(model.mruOrder) == Set(ids))
    }

    @Test("reconcileTabState appends missing live tabs at the back")
    func reconcileTabStateAppendsMissingLiveTabs() {
        // Intent: reconcileTabState appends live tabs missing from mruOrder at
        //   the end (in display order).
        // Why it exists: pins the recovery path that lets the switcher show
        //   newly created or restored tabs.
        // Scenario: spec-first append -- mruOrder = [ids[0]] with three
        //   live tabs grows to [ids[0], ids[1], ids[2]].
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.mruOrder = [ids[0]]
        reconcileTabState(&model)
        #expect(model.mruOrder == [ids[0], ids[1], ids[2]])
    }

    @Test("reconcileTabState deduplicates: first occurrence wins")
    func reconcileTabStateDeduplicatesFirstOccurrenceWins() {
        // Intent: duplicate entries in mruOrder collapse to a single first
        //   occurrence.
        // Why it exists: pins the dedup contract that defends against
        //   corrupt persisted state and double-hoist bugs.
        // Scenario: spec-first dedup -- [B,A,B,C] reconciles to [B,A,C].
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.mruOrder = [ids[1], ids[0], ids[1], ids[2]]
        reconcileTabState(&model)
        #expect(model.mruOrder == [ids[1], ids[0], ids[2]])
    }

    @Test("reconcileTabState on empty mruOrder builds full list (restore-time)")
    func reconcileTabStateEmptyBuildsFullList() {
        // Intent: from an empty mruOrder, reconcileTabState builds the full list
        //   with the selected tab hoisted to index 0.
        // Why it exists: pins the restore-time recovery so a freshly
        //   restored model gets a usable MRU on the first update().
        // Scenario: spec-first restore-time -- mruOrder = [], selectedTabId
        //   = ids[1]; reconciles to [B, A, C] (B hoisted).
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.mruOrder = []
        model.selectedTabId = ids[1]
        reconcileTabState(&model)
        #expect(model.mruOrder.count == 3)
        #expect(model.mruOrder[0] == ids[1], "selected tab hoisted to front")
        #expect(Set(model.mruOrder) == Set(ids), "all live tabs present")
    }

    @Test("reconcileTabState does not early-out when count matches but a live tab is missing")
    func reconcileTabStateDoesNotEarlyOutCountMatchMissingLive() {
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
        reconcileTabState(&model)
        #expect(!model.mruOrder.contains(ghost), "stale id must be pruned")
        #expect(Set(model.mruOrder) == Set(ids), "missing live tab must be appended")
    }

    @Test("reconcileTabState does not early-out on a duplicate live id")
    func reconcileTabStateDoesNotEarlyOutDuplicateLive() {
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
        reconcileTabState(&model)
        #expect(model.mruOrder == [ids[0], ids[1]], "dedup to [A], then append B")
    }

    @Test("reconcileTabState repairs a dead selection from the surviving MRU order")
    func reconcileTabStateRepairsDeadSelectionFromMru() {
        // Intent: a selectedTabId that names no live tab is repaired to the
        //   most recently used surviving tab, and that tab becomes mruOrder[0].
        // Why it exists: selection validity and MRU order are one
        //   reconciliation result, so a removal path that forgets to repair
        //   selection still lands the user on the MRU answer rather than an
        //   arbitrary tab.
        // Scenario: spec-first; mruOrder puts C ahead of A while A is the
        //   first tab in flattened order, so the MRU answer and the
        //   flattened-first answer differ.
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        let dead = TabId()
        model.mruOrder = [dead, ids[2], ids[0], ids[1]]
        model.selectedTabId = dead
        reconcileTabState(&model)
        #expect(model.selectedTabId == ids[2], "selection lands on the MRU-first survivor")
        #expect(model.mruOrder == [ids[2], ids[0], ids[1]])
    }

    @Test("reconcileTabState leaves a live selection untouched")
    func reconcileTabStateLeavesLiveSelectionUntouched() {
        // Intent: reconciliation never moves a selection that already names a
        //   live tab.
        // Why it exists: the repair must be a repair, not a policy that
        //   overrides the deliberate selection moves other handlers make.
        // Scenario: spec-first; B is selected while C heads mruOrder.
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.mruOrder = [ids[2], ids[0], ids[1]]
        model.selectedTabId = ids[1]
        reconcileTabState(&model)
        #expect(model.selectedTabId == ids[1])
        #expect(model.mruOrder.first == ids[1], "the live selection is hoisted, not replaced")
    }

    @Test("reconcileTabState clears the selection when no tab survives")
    func reconcileTabStateClearsSelectionWithNoSurvivors() {
        // Intent: with no live tabs, selectedTabId becomes nil instead of
        //   dangling on a dead id.
        // Why it exists: pins the "nil iff no tabs" half of the selection
        //   invariant, so no consumer reads a selection that names nothing.
        // Scenario: spec-first; the last tab was removed.
        var model = makeModel()
        let dead = TabId()
        model.selectedTabId = dead
        model.mruOrder = [dead]
        reconcileTabState(&model)
        #expect(model.selectedTabId == nil)
        #expect(model.mruOrder.isEmpty)
    }

    @Test("reconcileTabState is idempotent for selection and order alike")
    func reconcileTabStateIdempotentForSelectionAndOrder() {
        // Intent: a second reconciliation changes nothing after the first.
        // Why it exists: the pass runs on every update(), so a non-idempotent
        //   repair would drift the selection tick by tick.
        // Scenario: spec-first; repair a dead selection, then reconcile again.
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.mruOrder = [TabId(), ids[2], ids[0], ids[1]]
        model.selectedTabId = model.mruOrder[0]
        reconcileTabState(&model)
        let afterFirst = model
        reconcileTabState(&model)
        #expect(model.selectedTabId == afterFirst.selectedTabId)
        #expect(model.mruOrder == afterFirst.mruOrder)
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
        let paneA = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .splitPane(paneId: paneA, direction: .horizontal))
        let paneA2 = selectedTab(in: model)!.paneTree.focusedPaneId

        update(&model, .addTodo(owner: .tab(tabA.id), text: "tab task"))
        update(&model, .addTodo(owner: .pane(paneA), text: "p1 a"))
        update(&model, .addTodo(owner: .pane(paneA), text: "p1 b done"))
        let pAdone = model.pane(paneA)!.todos[1].id
        update(&model, .toggleTodoDone(owner: .pane(paneA), todoId: pAdone))
        update(&model, .addTodo(owner: .pane(paneA2), text: "p2 a"))

        update(&model, .addTodo(owner: .pane(tabB.paneTree.focusedPaneId), text: "tab B pane task"))

        let rollup = tabTodoRollup(tabA.id, in: model)
        #expect(rollup.total == 4, "1 tab + 2 paneA + 1 paneA2")
        #expect(rollup.uncompleted == 3, "one pane todo is done")

        let rollupB = tabTodoRollup(tabB.id, in: model)
        #expect(rollupB.total == 1)
        #expect(rollupB.uncompleted == 1)
    }
}
