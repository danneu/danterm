import Foundation

func modelOperationsTests() {
    print("ModelOperations Tests...")

    func makeTwoPaneTabTodoRowsModel() -> (model: AppModel, tabId: TabId, paneA: PaneId, paneB: PaneId) {
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let paneA = selectedTab(in: model)!.focusedPaneId
        update(&model, .splitPane(paneId: paneA, direction: .horizontal))
        let paneOrder = allPaneIds(selectedTab(in: model)!.rootNode)
        return (model, tabId, paneOrder[0], paneOrder[1])
    }

    // MARK: - allPaneIds

    test("testAllPaneIdsFlatLeaf") {
        let id = PaneId()
        let node = SplitNodeModel.leaf(PaneModel(id: id))
        let ids = allPaneIds(node)
        try expectEqual(ids.count, 1)
        try expectEqual(ids[0], id)
    }

    test("testAllPaneIdsNestedTree") {
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
        try expectEqual(ids.count, 3)
        try expect(ids.contains(a))
        try expect(ids.contains(b))
        try expect(ids.contains(c))
    }

    // MARK: - effectiveSurfaceVisibility

    func makeVisibilityModel(tabs: [TabModel], selectedTabId: TabId?) -> AppModel {
        // Panes already live in the leaves of the passed-in tabs.
        return AppModel(
            groups: [GroupModel(id: GroupId(), name: "General", tabs: tabs)],
            selectedTabId: selectedTabId
        )
    }

    test("effectiveSurfaceVisibility marks every reachable pane hidden when window is hidden") {
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

        try expectEqual(visibility, [a: false, b: false, c: false])
    }

    test("effectiveSurfaceVisibility marks a selected single-pane tab visible") {
        let paneId = PaneId()
        let tabId = TabId()
        let tab = TabModel(id: tabId, focusedPaneId: paneId, rootNode: .leaf(PaneModel(id: paneId)))
        let model = makeVisibilityModel(tabs: [tab], selectedTabId: tabId)

        let visibility = effectiveSurfaceVisibility(in: model, windowVisible: true)

        try expectEqual(visibility, [paneId: true])
    }

    test("effectiveSurfaceVisibility hides panes in non-selected tabs") {
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

        try expectEqual(visibility, [selectedA: true, selectedB: true, background: false])
    }

    test("effectiveSurfaceVisibility hides zoomed sibling panes") {
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

        try expectEqual(visibility, [focused: true, sibling: false])
    }

    test("effectiveSurfaceVisibility keeps a zoomed single-pane tab visible") {
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

        try expectEqual(visibility, [paneId: true])
    }

    test("effectiveSurfaceVisibility hides every pane when there is no selected tab") {
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

        try expectEqual(visibility, [a: false, b: false])
    }

    test("effectiveSurfaceVisibility marks every selected nested split leaf visible") {
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

        try expectEqual(visibility, [a: true, b: true, c: true])
    }

    // MARK: - firstLeafId / lastLeafId

    test("testFirstLeafId") {
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
        try expectEqual(firstLeafId(node), a)
    }

    test("testLastLeafId") {
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
        try expectEqual(lastLeafId(node), c)
    }

    // MARK: - splitLeaf

    test("testSplitLeafNotFound") {
        let a = PaneId()
        let node = SplitNodeModel.leaf(PaneModel(id: a))
        let result = splitLeaf(node, paneId: PaneId(), direction: .horizontal, newPane: PaneModel(id: PaneId()))
        try expect(result == nil, "should return nil for unknown paneId")
    }

    // MARK: - removeLeaf

    test("testRemoveLeafRootLeaf") {
        let a = PaneId()
        let node = SplitNodeModel.leaf(PaneModel(id: a))
        let (newTree, nextFocus, _) = removeLeaf(node, paneId: a)
        try expect(newTree == nil, "removing root leaf should return nil tree")
        try expect(nextFocus == nil, "removing root leaf should return nil focus")
    }

    test("testRemoveLeafDeepTree") {
        let a = PaneId(), b = PaneId(), c = PaneId()
        // Tree: [A, [B, C]]
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

        // Remove B — inner split should collapse to just C, result: [A, C]
        let (newTree, nextFocus, _) = removeLeaf(root, paneId: b)
        try expect(newTree != nil, "tree should not be nil")
        guard case .split(_, .horizontal, let first, let second, _) = newTree! else {
            throw TestFailure(message: "should be a horizontal split")
        }
        if case .leaf(let fpane) = first {
            try expectEqual(fpane.id, a)
        } else {
            throw TestFailure(message: "first should be leaf A")
        }
        if case .leaf(let spane) = second {
            try expectEqual(spane.id, c)
        } else {
            throw TestFailure(message: "second should be leaf C (promoted)")
        }
        try expectEqual(nextFocus, c, "next focus should be C (first leaf of sibling)")
    }

    // MARK: - nearestLeaf

    test("testNearestLeafSimple") {
        let a = PaneId(), b = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.5
        )
        // From A, go right (second)
        try expectEqual(nearestLeaf(node, from: a, direction: .horizontal, side: .second), b)
        // From B, go left (first)
        try expectEqual(nearestLeaf(node, from: b, direction: .horizontal, side: .first), a)
    }

    test("testNearestLeafVertical") {
        let a = PaneId(), b = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .vertical,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.5
        )
        // From A, go down (second)
        try expectEqual(nearestLeaf(node, from: a, direction: .vertical, side: .second), b)
        // From B, go up (first)
        try expectEqual(nearestLeaf(node, from: b, direction: .vertical, side: .first), a)
    }

    test("testNearestLeafNestedLShape") {
        let a = PaneId(), b = PaneId(), c = PaneId()
        // [A, [B, C]] where outer=horizontal, inner=vertical
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
        // From B, go left → A
        try expectEqual(nearestLeaf(node, from: b, direction: .horizontal, side: .first), a)
        // From C, go left → A
        try expectEqual(nearestLeaf(node, from: c, direction: .horizontal, side: .first), a)
        // From A, go right → B (first leaf of second child)
        try expectEqual(nearestLeaf(node, from: a, direction: .horizontal, side: .second), b)
        // From B, go down → C
        try expectEqual(nearestLeaf(node, from: b, direction: .vertical, side: .second), c)
    }

    test("testNearestLeafNoNeighbor") {
        let a = PaneId(), b = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.5
        )
        // From A, go left — no neighbor
        try expect(nearestLeaf(node, from: a, direction: .horizontal, side: .first) == nil, "should return nil at edge")
        // From A, go vertical — wrong direction
        try expect(nearestLeaf(node, from: a, direction: .vertical, side: .second) == nil, "should return nil for wrong direction")
    }

    test("testNearestLeaf2x2GridPreservesPerpendicularPosition") {
        let tl = PaneId(), tr = PaneId(), bl = PaneId(), br = PaneId()
        // 2x2 grid: horizontal split of two vertical columns
        //   H
        //   ├── V1: TL (first), BL (second)
        //   └── V2: TR (first), BR (second)
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
        // From TR, go left → should be TL (same row), not BL
        try expectEqual(nearestLeaf(node, from: tr, direction: .horizontal, side: .first), tl)
        // From BR, go left → should be BL (same row)
        try expectEqual(nearestLeaf(node, from: br, direction: .horizontal, side: .first), bl)
        // From TL, go right → should be TR (same row)
        try expectEqual(nearestLeaf(node, from: tl, direction: .horizontal, side: .second), tr)
        // From BL, go right → should be BR (same row)
        try expectEqual(nearestLeaf(node, from: bl, direction: .horizontal, side: .second), br)
    }

    // MARK: - setRatio

    test("testSetRatio") {
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
            throw TestFailure(message: "should be a split")
        }
        try expectEqual(ratio, 0.7)
    }

    test("testSetRatioLeavesOthersUnchanged") {
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
            throw TestFailure(message: "should be a split")
        }
        try expectEqual(outerRatio, 0.5, "outer ratio unchanged")
        guard case .split(_, _, _, _, let innerRatio) = second else {
            throw TestFailure(message: "inner should be a split")
        }
        try expectEqual(innerRatio, 0.3, "inner ratio updated")
    }

    // MARK: - totalTabCount

    test("testTotalTabCountEmpty") {
        let model = makeModel()
        try expectEqual(totalTabCount(model), 0)
    }

    test("testTotalTabCountSingleTab") {
        var model = makeModel()
        createTab(&model)
        try expectEqual(totalTabCount(model), 1)
    }

    test("testTotalTabCountMultipleGroups") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        update(&model, .createGroup(name: "Work"))
        // createGroup auto-creates a tab
        try expectEqual(totalTabCount(model), 3)
    }

    // MARK: - isFocusedAndVisible

    test("testIsFocusedAndVisible") {
        var model = makeModel()
        createTab(&model)
        let firstPaneId = selectedTab(in: model)!.focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let focusedSplitPaneId = selectedTab(in: model)!.focusedPaneId

        try expect(isFocusedAndVisible(focusedSplitPaneId, in: model), "focused pane in selected split tab should be visible")
        try expect(!isFocusedAndVisible(firstPaneId, in: model), "non-focused pane should not be focused and visible")

        createTab(&model)
        let singlePaneId = selectedTab(in: model)!.focusedPaneId

        try expect(!isFocusedAndVisible(singlePaneId, in: model), "focused pane in single-pane tab should not show a focus border")
        try expect(!isFocusedAndVisible(focusedSplitPaneId, in: model), "pane in non-selected tab should not be focused and visible")
    }

    // MARK: - swapLeaves

    test("testSwapLeavesSimple") {
        let a = PaneId(), b = PaneId()
        let splitId = SplitId()
        let node = SplitNodeModel.split(
            id: splitId, direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.6
        )
        let result = swapLeaves(node, a, b)
        try expect(result != nil, "should return non-nil")
        guard case .split(let rSplitId, .horizontal, let first, let second, let ratio) = result! else {
            throw TestFailure(message: "should be a horizontal split")
        }
        try expectEqual(rSplitId, splitId, "split id preserved")
        try expectEqual(ratio, 0.6, "ratio preserved")
        if case .leaf(let fpane) = first { try expectEqual(fpane.id, b) }
        else { throw TestFailure(message: "first should be leaf B") }
        if case .leaf(let spane) = second { try expectEqual(spane.id, a) }
        else { throw TestFailure(message: "second should be leaf A") }
    }

    test("testSwapLeavesNested") {
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
            throw TestFailure(message: "should be outer split")
        }
        try expectEqual(rOuterId, outerSplitId, "outer split id preserved")
        try expectEqual(outerRatio, 0.7, "outer ratio preserved")
        if case .leaf(let fpane) = first { try expectEqual(fpane.id, c, "first should now be C") }
        else { throw TestFailure(message: "first should be a leaf") }
        guard case .split(let rInnerId, .vertical, let innerFirst, let innerSecond, let innerRatio) = second else {
            throw TestFailure(message: "second should be inner split")
        }
        try expectEqual(rInnerId, innerSplitId, "inner split id preserved")
        try expectEqual(innerRatio, 0.3, "inner ratio preserved")
        if case .leaf(let fpane) = innerFirst { try expectEqual(fpane.id, b, "inner first still B") }
        else { throw TestFailure(message: "inner first should be leaf") }
        if case .leaf(let spane) = innerSecond { try expectEqual(spane.id, a, "inner second now A") }
        else { throw TestFailure(message: "inner second should be leaf") }
    }

    test("testSwapLeavesSamePane") {
        let a = PaneId()
        let node = SplitNodeModel.leaf(PaneModel(id: a))
        try expect(swapLeaves(node, a, a) == nil, "same pane returns nil")
    }

    test("testSwapLeavesMissingPane") {
        let a = PaneId(), b = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.5
        )
        try expect(swapLeaves(node, a, PaneId()) == nil, "missing pane returns nil")
    }

    // MARK: - moveLeaf

    test("testMoveLeafLeftInsert") {
        let a = PaneId(), b = PaneId()
        // [A, B] → move A to left of B → [A, B] (same shape but fresh split)
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.5
        )
        let result = moveLeaf(node, source: a, target: b, direction: .horizontal, insertFirst: true)
        try expect(result != nil, "should succeed")
        let ids = allPaneIds(result!)
        try expectEqual(ids.count, 2)
        try expect(ids.contains(a))
        try expect(ids.contains(b))
        // Source should be first (left)
        try expectEqual(firstLeafId(result!), a, "A should be first")
    }

    test("testMoveLeafRightInsert") {
        let a = PaneId(), b = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.5
        )
        let result = moveLeaf(node, source: a, target: b, direction: .horizontal, insertFirst: false)
        try expect(result != nil, "should succeed")
        // Source should be second (right)
        try expectEqual(lastLeafId(result!), a, "A should be last")
    }

    test("testMoveLeafFromNestedTree") {
        let a = PaneId(), b = PaneId(), c = PaneId()
        // Tree: [A, [B, C]] — move B to top of A
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
        let result = moveLeaf(node, source: b, target: a, direction: .vertical, insertFirst: true)!
        let ids = allPaneIds(result)
        try expectEqual(ids.count, 3, "all three panes preserved")
        // After removing B from [B,C], inner collapses to C.
        // Then insert B above A → [[B,A], C]
        try expectEqual(firstLeafId(result), b, "B should be first (top-left)")
    }

    test("testMoveLeafCreatesNewSplitId") {
        let a = PaneId(), b = PaneId()
        let origSplitId = SplitId()
        let node = SplitNodeModel.split(
            id: origSplitId, direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.5
        )
        let result = moveLeaf(node, source: a, target: b, direction: .vertical, insertFirst: true)!
        // The result should have a split with ratio 0.5 wrapping A and B
        guard case .split(let newSplitId, .vertical, _, _, let ratio) = result else {
            throw TestFailure(message: "should be a vertical split")
        }
        try expectEqual(ratio, 0.5, "new split has ratio 0.5")
        try expect(newSplitId != origSplitId, "new split should have fresh ID")
    }

    test("testMoveLeafSameSourceTarget") {
        let a = PaneId()
        let node = SplitNodeModel.leaf(PaneModel(id: a))
        try expect(moveLeaf(node, source: a, target: a, direction: .horizontal, insertFirst: true) == nil, "same source/target returns nil")
    }

    test("testMoveLeafMissingSource") {
        let a = PaneId(), b = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.5
        )
        try expect(moveLeaf(node, source: PaneId(), target: b, direction: .horizontal, insertFirst: true) == nil, "missing source returns nil")
    }

    test("testMoveLeafMissingTarget") {
        let a = PaneId(), b = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: a)),
            second: .leaf(PaneModel(id: b)),
            ratio: 0.5
        )
        // removeLeaf(a) leaves .leaf(PaneModel(id: b)), then insertAtLeaf for missing target returns nil
        try expect(moveLeaf(node, source: a, target: PaneId(), direction: .horizontal, insertFirst: true) == nil, "missing target returns nil")
    }

    // MARK: - abbreviateHome

    test("testAbbreviateHome") {
        let home = NSHomeDirectory()
        try expectEqual(abbreviateHome(home + "/projects"), "~/projects")
        try expectEqual(abbreviateHome("/tmp/foo"), "/tmp/foo")
        try expectEqual(abbreviateHome(home), "~")
    }

    // MARK: - deleteGroupAction

    test("testDeleteGroupActionEmptyGroup") {
        var model = makeModel()
        createTab(&model)
        // Construct an empty group directly (auto-pruning prevents this via update())
        let workGroupId = GroupId()
        model.groups.append(GroupModel(id: workGroupId, name: "Work"))
        let action = deleteGroupAction(for: workGroupId, in: model)
        guard case .deleteImmediately(let gid) = action else {
            throw TestFailure(message: "expected .deleteImmediately, got \(String(describing: action))")
        }
        try expectEqual(gid, workGroupId)
    }

    test("testDeleteGroupActionGroupWithTabs") {
        var model = makeModel()
        update(&model, .createGroup(name: "Work"))
        let workGroup = model.groups.first(where: { $0.name == "Work" })!
        // createGroup auto-creates one tab
        let action = deleteGroupAction(for: workGroup.id, in: model)
        guard case .confirm(let gid, let name, let tabCount) = action else {
            throw TestFailure(message: "expected .confirm, got \(String(describing: action))")
        }
        try expectEqual(gid, workGroup.id)
        try expectEqual(name, "Work")
        try expectEqual(tabCount, 1)
    }

    test("testDeleteGroupActionLastGroup") {
        let model = makeModel()
        let onlyGroup = model.groups[0]
        let action = deleteGroupAction(for: onlyGroup.id, in: model)
        try expect(action == nil, "last remaining group should return nil")
    }

    // MARK: - bellCount / groupBellCount

    test("testUnreadAlertCount") {
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
        try expectEqual(unreadAlertCount(for: tab, alerts: alerts), 0)

        alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: a,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)
        try expectEqual(unreadAlertCount(for: tab, alerts: alerts), 1)

        alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: b,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)
        try expectEqual(unreadAlertCount(for: tab, alerts: alerts), 2)
    }

    test("testGroupUnreadAlertCount") {
        let a = PaneId(), b = PaneId()
        let tabId1 = TabId(), tabId2 = TabId()
        let tab1 = TabModel(id: tabId1, focusedPaneId: a, rootNode: .leaf(PaneModel(id: a)))
        let tab2 = TabModel(id: tabId2, focusedPaneId: b, rootNode: .leaf(PaneModel(id: b)))
        let group = GroupModel(id: GroupId(), name: "Test", tabs: [tab1, tab2])
        var alerts: [AlertModel] = []

        try expectEqual(groupUnreadAlertCount(for: group, alerts: alerts), 0)
        alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: b,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)
        try expectEqual(groupUnreadAlertCount(for: group, alerts: alerts), 1)
    }

    // MARK: - moveToFront

    test("moveToFront empty array is no-op") {
        var arr: [Int] = []
        moveToFront(&arr, 1)
        try expectEqual(arr, [])
    }

    test("moveToFront missing element is no-op") {
        var arr = [1, 2, 3]
        moveToFront(&arr, 99)
        try expectEqual(arr, [1, 2, 3])
    }

    test("moveToFront existing element moves to index 0") {
        var arr = [1, 2, 3, 4]
        moveToFront(&arr, 3)
        try expectEqual(arr, [3, 1, 2, 4])
    }

    test("moveToFront idempotent when already at index 0") {
        var arr = [1, 2, 3]
        moveToFront(&arr, 1)
        try expectEqual(arr, [1, 2, 3])
    }

    test("moveToFront removes prior occurrence (no duplicates)") {
        var arr = [1, 2, 1, 3]
        moveToFront(&arr, 1)
        try expectEqual(arr, [1, 2, 3])
    }

    // MARK: - reconcileMru

    test("reconcileMru on full live order is a no-op except possible hoist") {
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.mruOrder = ids
        model.selectedTabId = ids[0]
        reconcileMru(&model)
        try expectEqual(model.mruOrder, ids)
    }

    test("reconcileMru hoists selectedTabId to index 0 when not cycling") {
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.mruOrder = ids               // [A, B, C]
        model.selectedTabId = ids[2]       // C selected
        reconcileMru(&model)
        try expectEqual(model.mruOrder, [ids[2], ids[0], ids[1]])
    }

    test("reconcileMru does NOT hoist when cycling") {
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.mruOrder = ids               // [A, B, C]
        model.selectedTabId = ids[2]       // C selected
        model.mruCycle = MruCycleState(frozenOrder: ids, cursorIndex: 1)
        reconcileMru(&model)
        try expectEqual(model.mruOrder, ids)  // unchanged
    }

    test("reconcileMru prunes stale ids") {
        let (m0, ids) = makeMruModel(tabCount: 2)
        var model = m0
        let ghost = TabId()
        model.mruOrder = [ghost, ids[0], ids[1]]
        reconcileMru(&model)
        try expect(!model.mruOrder.contains(ghost), "ghost id must be pruned")
        try expectEqual(Set(model.mruOrder), Set(ids))
    }

    test("reconcileMru appends missing live tabs at the back") {
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.mruOrder = [ids[0]]  // only one entry; B, C missing
        reconcileMru(&model)
        // Existing entry preserved at front; missing tabs appended in display order.
        try expectEqual(model.mruOrder, [ids[0], ids[1], ids[2]])
    }

    test("reconcileMru deduplicates: first occurrence wins") {
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        // Buggy state: same id appears twice. Reconcile must clean up.
        model.mruOrder = [ids[1], ids[0], ids[1], ids[2]]
        reconcileMru(&model)
        try expectEqual(model.mruOrder, [ids[1], ids[0], ids[2]])
    }

    test("reconcileMru on empty mruOrder builds full list (restore-time)") {
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.mruOrder = []
        model.selectedTabId = ids[1]
        reconcileMru(&model)
        try expectEqual(model.mruOrder.count, 3)
        try expectEqual(model.mruOrder[0], ids[1], "selected tab hoisted to front")
        try expect(Set(model.mruOrder) == Set(ids), "all live tabs present")
    }

    // MARK: - resolveLiveCycle

    test("resolveLiveCycle all live → identity") {
        let (m0, ids) = makeMruModel(tabCount: 4)
        let model = m0
        let cycle = MruCycleState(frozenOrder: ids, cursorIndex: 2)
        let resolved = resolveLiveCycle(cycle, in: model)
        try expect(resolved != nil)
        try expectEqual(resolved!.liveOrder, ids)
        try expectEqual(resolved!.cursorIndex, 2)
    }

    test("resolveLiveCycle dead id before cursor → cursor remaps to same target") {
        let (m0, ids) = makeMruModel(tabCount: 4)
        var model = m0
        let frozen = ids  // [A, B, C, D], cursor=2 → target C
        // Remove B from the live model.
        model.groups[0].tabs.removeAll { $0.id == ids[1] }
        let cycle = MruCycleState(frozenOrder: frozen, cursorIndex: 2)
        let resolved = resolveLiveCycle(cycle, in: model)
        try expect(resolved != nil)
        try expectEqual(resolved!.liveOrder, [ids[0], ids[2], ids[3]])
        try expectEqual(resolved!.cursorIndex, 1, "C still pinned at its new live index")
    }

    test("resolveLiveCycle dead id at cursor → snap back to nearest preceding live") {
        let (m0, ids) = makeMruModel(tabCount: 4)
        var model = m0
        let frozen = ids  // [A, B, C, D], cursor=2 → target C
        // Remove C from the live model.
        model.groups[0].tabs.removeAll { $0.id == ids[2] }
        let cycle = MruCycleState(frozenOrder: frozen, cursorIndex: 2)
        let resolved = resolveLiveCycle(cycle, in: model)
        try expect(resolved != nil)
        try expectEqual(resolved!.liveOrder, [ids[0], ids[1], ids[3]])
        try expectEqual(resolved!.cursorIndex, 1, "snapped back to B")
    }

    test("resolveLiveCycle dead id at cursor with no preceding live → fallback to 0") {
        let (m0, ids) = makeMruModel(tabCount: 4)
        var model = m0
        let frozen = ids
        // Remove A (the only candidate before cursor=0).
        model.groups[0].tabs.removeAll { $0.id == ids[0] }
        let cycle = MruCycleState(frozenOrder: frozen, cursorIndex: 0)
        let resolved = resolveLiveCycle(cycle, in: model)
        try expect(resolved != nil)
        try expectEqual(resolved!.liveOrder, [ids[1], ids[2], ids[3]])
        try expectEqual(resolved!.cursorIndex, 0, "fell back to live index 0")
    }

    test("resolveLiveCycle all frozen ids dead → nil") {
        let (m0, ids) = makeMruModel(tabCount: 1)
        var model = m0
        let frozen = ids
        model.groups[0].tabs.removeAll()
        let cycle = MruCycleState(frozenOrder: frozen, cursorIndex: 0)
        let resolved = resolveLiveCycle(cycle, in: model)
        try expect(resolved == nil, "no live tabs → nil")
    }

    // MARK: - desiredSwitcher (MRU switcher overlay projection, Stage 7)

    // The disappearance net: a non-nil projection while cycling (rows in the live
    // frozen order + the carried cursor index, name/alertCount reflecting the model),
    // then nil once the cycle ends -- the nil is what reconcileSwitcher turns into an
    // orderOut. resolveLiveCycle's own remapping is covered by the tests above.
    test("desiredSwitcher: non-nil while cycling, nil once the cycle ends") {
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        // No cycle -> nothing to show (the panel stays ordered out).
        try expect(model.mruCycle == nil, "precondition: not cycling")
        try expect(desiredSwitcher(in: model) == nil, "no MRU cycle -> nil projection")

        // Distinctive name on the first tab and an unread alert on the second, so the
        // projected rows demonstrably reflect the model.
        model.groups[0].tabs[0].customTitle = "Alpha"
        let alertPane = model.groups[0].tabs[1].focusedPaneId
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: alertPane,
            title: "DanTerm", body: "x", createdAt: Date(), isUnread: true), at: 0)

        model.mruCycle = MruCycleState(frozenOrder: ids, cursorIndex: 1)
        guard let proj = desiredSwitcher(in: model) else {
            throw TestFailure(message: "expected a non-nil projection while cycling")
        }
        try expectEqual(proj.rows.map(\.tabId), ids, "rows follow the live (frozen) order")
        try expectEqual(proj.cursorIndex, 1, "cursor index carried from the cycle")
        try expectEqual(proj.rows[0].name, "Alpha", "row name is the tab's displayTitle")
        try expectEqual(proj.rows[1].alertCount, 1, "row alertCount reflects the model's unread alerts")
        try expectEqual(proj.rows[0].alertCount, 0, "a tab with no unread alerts has zero count")

        // Cycle ends -> projection disappears, so the diff issues orderOut.
        model.mruCycle = nil
        try expect(desiredSwitcher(in: model) == nil, "cycle ended -> nil projection (orderOut)")
    }

    test("desiredQuitConfirmation projects terminate pane count only") {
        var model = makeModel()
        createTab(&model)

        try expect(desiredQuitConfirmation(in: model) == nil, "no pending confirmation -> nil projection")

        model.pendingConfirmation = .closeTab
        try expect(desiredQuitConfirmation(in: model) == nil, "close-tab confirmation uses NSAlert, not the quit panel")

        model.pendingConfirmation = .terminate
        try expectEqual(desiredQuitConfirmation(in: model), QuitConfirmationProjection(paneCount: 1),
            "single-pane terminate confirmation projects pane count 1")

        var multi = makeMruModel(tabCount: 3).model
        multi.pendingConfirmation = .terminate
        try expectEqual(desiredQuitConfirmation(in: multi), QuitConfirmationProjection(paneCount: 3),
            "multi-pane terminate confirmation projects the live pane count")

        multi.pendingConfirmation = nil
        try expect(desiredQuitConfirmation(in: multi) == nil, "cleared confirmation -> nil projection")
    }

    test("desiredQuitConfirmation decrements as panes close while pending") {
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .splitPane(direction: .horizontal))
        try expectEqual(model.allPaneIds.count, 2, "precondition: split created two panes")
        model.pendingConfirmation = .terminate
        try expectEqual(desiredQuitConfirmation(in: model)?.paneCount, 2,
            "open quit panel starts with both panes")

        let paneId = model.groups[0].tabs[0].focusedPaneId
        _ = update(&model, .closePane(paneId: paneId))

        try expectEqual(model.allPaneIds.count, 1, "non-last pane close removes one pane")
        try expect(model.pendingConfirmation == .terminate, "non-last pane close keeps quit confirmation pending")
        try expectEqual(desiredQuitConfirmation(in: model)?.paneCount, 1,
            "projection reflects the decremented live pane count")
    }

    // MARK: - resolveContextTargets (sidebar Finder/Mail rule)

    test("resolveContextTargets clicked row in selection returns selection in row order") {
        let id0 = TabId(); let id1 = TabId(); let id2 = TabId()
        let map: [Int: TabId] = [0: id0, 1: id1, 2: id2]
        let result = resolveContextTargets(
            clickedRow: 1,
            selectedRows: IndexSet([2, 0, 1]),
            tabIdAtRow: { map[$0] })
        try expectEqual(result, [id0, id1, id2])
    }

    test("resolveContextTargets clicked row outside selection returns clicked row only") {
        let id0 = TabId(); let id3 = TabId()
        let map: [Int: TabId] = [0: id0, 3: id3]
        let result = resolveContextTargets(
            clickedRow: 3,
            selectedRows: IndexSet([0]),
            tabIdAtRow: { map[$0] })
        try expectEqual(result, [id3])
    }

    test("resolveContextTargets group row (nil mapping) returns empty") {
        // clicked row 1 maps to nil (group row); selection covers only it.
        let result = resolveContextTargets(
            clickedRow: 1,
            selectedRows: IndexSet([1]),
            tabIdAtRow: { _ in nil })
        try expectEqual(result, [])
    }

    test("resolveContextTargets selection mixes tab and group rows — group filtered") {
        let id0 = TabId(); let id2 = TabId()
        // Row 1 is a group row (returns nil). Selection {0,1,2}, click row 0.
        let map: [Int: TabId?] = [0: id0, 1: nil, 2: id2]
        let result = resolveContextTargets(
            clickedRow: 0,
            selectedRows: IndexSet([0, 1, 2]),
            tabIdAtRow: { map[$0] ?? nil })
        try expectEqual(result, [id0, id2])
    }

    test("resolveContextTargets negative clicked row returns empty") {
        let result = resolveContextTargets(
            clickedRow: -1,
            selectedRows: IndexSet(),
            tabIdAtRow: { _ in TabId() })
        try expectEqual(result, [])
    }

    // MARK: - resolveReloadSelection (sidebar selection restore rule)

    test("resolveReloadSelection preserves multi-selection when focus is in it") {
        let a = TabId(); let b = TabId(); let c = TabId(); let d = TabId()
        let result = resolveReloadSelection(
            priorSelectedTabIds: [a, b, c],
            liveTabIds: [a, b, c, d],
            selectedTabId: a)
        try expectEqual(result, [a, b, c])
    }

    test("resolveReloadSelection drops stale ids while preserving") {
        let a = TabId(); let b = TabId(); let stale = TabId()
        // prior {a, b, stale}; stale closed → dropped. Focus a is in live prior.
        let result = resolveReloadSelection(
            priorSelectedTabIds: [a, b, stale],
            liveTabIds: [a, b],
            selectedTabId: a)
        try expectEqual(result, [a, b])
    }

    test("resolveReloadSelection collapses to focus when external focus change") {
        let a = TabId(); let b = TabId(); let c = TabId()
        // Prior {a, b}; model focus moves to c (outside prior selection).
        let result = resolveReloadSelection(
            priorSelectedTabIds: [a, b],
            liveTabIds: [a, b, c],
            selectedTabId: c)
        try expectEqual(result, [c])
    }

    test("resolveReloadSelection collapses to focus when all prior ids stale") {
        let a = TabId(); let b = TabId(); let c = TabId()
        // prior {a, b} both closed; focus c is live.
        let result = resolveReloadSelection(
            priorSelectedTabIds: [a, b],
            liveTabIds: [c],
            selectedTabId: c)
        try expectEqual(result, [c])
    }

    test("resolveReloadSelection returns empty when selectedTabId is itself stale") {
        let a = TabId(); let b = TabId(); let stale = TabId()
        let result = resolveReloadSelection(
            priorSelectedTabIds: [a, b],
            liveTabIds: [a, b],
            selectedTabId: stale)
        try expectEqual(result, [])
    }

    test("resolveReloadSelection returns empty when no selectedTabId") {
        let a = TabId(); let b = TabId()
        let result = resolveReloadSelection(
            priorSelectedTabIds: [a, b],
            liveTabIds: [a, b],
            selectedTabId: nil)
        try expectEqual(result, [])
    }

    // MARK: - shouldForceSidebarRowEmphasis

    test("shouldForceSidebarRowEmphasis true when ids match") {
        let id = TabId()
        try expect(shouldForceSidebarRowEmphasis(rowTabId: id, focusedTabId: id))
    }

    test("shouldForceSidebarRowEmphasis false when ids differ") {
        let row = TabId(); let focused = TabId()
        try expect(!shouldForceSidebarRowEmphasis(rowTabId: row, focusedTabId: focused))
    }

    test("shouldForceSidebarRowEmphasis false for group rows (rowTabId nil)") {
        let focused = TabId()
        try expect(!shouldForceSidebarRowEmphasis(rowTabId: nil, focusedTabId: focused))
    }

    test("shouldForceSidebarRowEmphasis false when focusedTabId nil") {
        let row = TabId()
        try expect(!shouldForceSidebarRowEmphasis(rowTabId: row, focusedTabId: nil))
    }

    test("shouldForceSidebarRowEmphasis false when both nil") {
        try expect(!shouldForceSidebarRowEmphasis(rowTabId: nil, focusedTabId: nil))
    }

    // MARK: - resolveColorForBatch

    test("testResolveColorForBatchEmptyReturnsNil") {
        // Empty batch has no policy meaning; helper fails closed.
        let model = makeModel()
        try expect(resolveColorForBatch(tabIds: [], requested: .red, in: model) == nil)
    }

    test("testResolveColorForBatchSingleSameColorClears") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        model.groups[0].tabs[0].color = .red
        try expect(resolveColorForBatch(tabIds: [tabId], requested: .red, in: model) == nil)
    }

    test("testResolveColorForBatchSingleDifferentColorSets") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        model.groups[0].tabs[0].color = .red
        try expectEqual(resolveColorForBatch(tabIds: [tabId], requested: .orange, in: model), .orange)
    }

    test("testResolveColorForBatchSingleUncoloredSets") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        // tab.color defaults to nil
        try expectEqual(resolveColorForBatch(tabIds: [tabId], requested: .red, in: model), .red)
    }

    test("testResolveColorForBatchMultiAllShareRequestedClears") {
        // cmd-1 on N already-red tabs clears them all (toggle-off extends
        // to multi when every targeted tab already shares the requested color).
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let id1 = model.groups[0].tabs[0].id
        let id2 = model.groups[0].tabs[1].id
        model.groups[0].tabs[0].color = .red
        model.groups[0].tabs[1].color = .red
        try expect(resolveColorForBatch(tabIds: [id1, id2], requested: .red, in: model) == nil)
    }

    test("testResolveColorForBatchMultiAllUncoloredSetsRequested") {
        // All tabs uncolored (color == nil) is NOT "all share .red", so cmd-1
        // sets them all rather than clearing. Covers the nil-color branch of
        // the all-share check.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let id1 = model.groups[0].tabs[0].id
        let id2 = model.groups[0].tabs[1].id
        // both tabs default to color == nil
        try expectEqual(resolveColorForBatch(tabIds: [id1, id2], requested: .red, in: model), .red)
    }

    test("testResolveColorForBatchMultiMixedColorsSetRequested") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let id1 = model.groups[0].tabs[0].id
        let id2 = model.groups[0].tabs[1].id
        model.groups[0].tabs[0].color = .red
        model.groups[0].tabs[1].color = .orange
        try expectEqual(resolveColorForBatch(tabIds: [id1, id2], requested: .red, in: model), .red)
    }

    test("testResolveColorForBatchExplicitNilOnSingleColored") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        model.groups[0].tabs[0].color = .red
        try expect(resolveColorForBatch(tabIds: [tabId], requested: nil, in: model) == nil)
    }

    test("testResolveColorForBatchExplicitNilOnMulti") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let id1 = model.groups[0].tabs[0].id
        let id2 = model.groups[0].tabs[1].id
        model.groups[0].tabs[0].color = .red
        model.groups[0].tabs[1].color = .red
        try expect(resolveColorForBatch(tabIds: [id1, id2], requested: nil, in: model) == nil)
    }

    // MARK: - Tab Jump Mode

    test("assignJumpKeys empty visible tab list returns empty map") {
        let keyMap: [TabId: Character] = assignJumpKeys(visibleTabs: [])
        try expectEqual(keyMap, [:])
    }

    test("assignJumpKeys assigns documented sequence in visible order") {
        let ids = (0..<10).map { _ in TabId() }
        let keyMap = assignJumpKeys(visibleTabs: ids)
        let expected = Array("asdfghjkl;")
        try expectEqual(keyMap.count, ids.count)
        for (index, id) in ids.enumerated() {
            try expectEqual(keyMap[id], expected[index])
        }
    }

    // MARK: - tabTodoRollup

    test("tabTodoRollup empty tab returns zero") {
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let rollup = tabTodoRollup(tabId, in: model)
        try expectEqual(rollup.total, 0)
        try expectEqual(rollup.uncompleted, 0)
    }

    test("tabTodoRollup sums tab + all panes; ignores other tabs' panes") {
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

        // Tab B has its own pane todo that should not bleed in
        update(&model, .addTodo(paneId: tabB.focusedPaneId, text: "tab B pane task"))

        let rollup = tabTodoRollup(tabA.id, in: model)
        try expectEqual(rollup.total, 4, "1 tab + 2 paneA + 1 paneA2")
        try expectEqual(rollup.uncompleted, 3, "one pane todo is done")

        let rollupB = tabTodoRollup(tabB.id, in: model)
        try expectEqual(rollupB.total, 1)
        try expectEqual(rollupB.uncompleted, 1)
    }

    // MARK: - Tab Todo Popover Rows

    test("buildTabTodoRows emits a header for every pane regardless of empty todos") {
        var (model, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTodo(paneId: paneA, text: "pane A task"))

        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let paneHeaders = rows.compactMap { row -> PaneId? in
            if case .paneSectionHeader(let paneId, _) = row { return paneId }
            return nil
        }

        try expectEqual(paneHeaders, [paneA, paneB])
    }

    test("buildTabTodoRows emits placeholders for an empty tab and empty panes") {
        let (model, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()

        let rows = buildTabTodoRows(model: model, tabId: tabId)

        try expectEqual(rows, [
            .tabSectionHeader,
            .tabEmptyPlaceholder,
            .paneSectionHeader(paneId: paneA, title: model.pane(paneA)!.title),
            .paneEmptyPlaceholder(paneId: paneA),
            .paneSectionHeader(paneId: paneB, title: model.pane(paneB)!.title),
            .paneEmptyPlaceholder(paneId: paneB),
        ])
    }

    test("buildTabTodoRows emits placeholders only for empty sections") {
        var (model, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTabTodo(tabId: tabId, text: "tab task"))
        update(&model, .addTodo(paneId: paneA, text: "pane A task"))

        let rows = buildTabTodoRows(model: model, tabId: tabId)

        try expect(rows.contains(.tabEmptyPlaceholder) == false, "populated tab should not have a placeholder")
        try expect(rows.contains(.paneEmptyPlaceholder(paneId: paneA)) == false, "populated pane should not have a placeholder")
        try expect(rows.contains(.paneEmptyPlaceholder(paneId: paneB)), "empty pane should have a placeholder")
    }

    test("buildTabTodoRows places each placeholder immediately after its header") {
        let (model, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()

        let rows = buildTabTodoRows(model: model, tabId: tabId)

        try expectEqual(rows[0], .tabSectionHeader)
        try expectEqual(rows[1], .tabEmptyPlaceholder)
        let paneAHeader = rows.firstIndex { row in
            if case .paneSectionHeader(let paneId, _) = row { return paneId == paneA }
            return false
        }!
        try expectEqual(rows[paneAHeader + 1], .paneEmptyPlaceholder(paneId: paneA))
        let paneBHeader = rows.firstIndex { row in
            if case .paneSectionHeader(let paneId, _) = row { return paneId == paneB }
            return false
        }!
        try expectEqual(rows[paneBHeader + 1], .paneEmptyPlaceholder(paneId: paneB))
    }

    test("tab todo placeholder rows are non-selectable section members") {
        let paneId = PaneId()

        let tabPlaceholder = TabTodoRow.tabEmptyPlaceholder
        try expectEqual(tabPlaceholder.isHeader, false)
        try expectEqual(tabPlaceholder.isSelectable, false)
        try expect(tabPlaceholder.editTarget == nil)
        try expect(tabPlaceholder.itemText == nil)
        try expectEqual(tabPlaceholder.sectionIdentifier, Optional(AnyHashable("tab")))

        let panePlaceholder = TabTodoRow.paneEmptyPlaceholder(paneId: paneId)
        try expectEqual(panePlaceholder.isHeader, false)
        try expectEqual(panePlaceholder.isSelectable, false)
        try expect(panePlaceholder.editTarget == nil)
        try expect(panePlaceholder.itemText == nil)
        try expectEqual(panePlaceholder.sectionIdentifier, Optional(AnyHashable(paneId)))
    }

    test("resolveTabTodoDropTarget .on tabSectionHeader appends to tab") {
        var (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTabTodo(tabId: tabId, text: "tab A"))
        update(&model, .addTabTodo(tabId: tabId, text: "tab B"))
        let rows = buildTabTodoRows(model: model, tabId: tabId)

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: 0, dropOperation: .on)

        try expectEqual(target?.destination, .tab(tabId))
        try expectEqual(target?.atIndex, 2)
    }

    test("resolveTabTodoDropTarget .on paneSectionHeader appends to pane") {
        var (model, tabId, paneA, _) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTodo(paneId: paneA, text: "pane A"))
        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let headerRow = rows.firstIndex {
            if case .paneSectionHeader(let paneId, _) = $0 { return paneId == paneA }
            return false
        }!

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: headerRow, dropOperation: .on)

        try expectEqual(target?.destination, .pane(paneA))
        try expectEqual(target?.atIndex, 1)
    }

    test("resolveTabTodoDropTarget .on tabEmptyPlaceholder inserts at tab index 0") {
        let (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let placeholderRow = rows.firstIndex(of: .tabEmptyPlaceholder)!

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: placeholderRow, dropOperation: .on)

        try expectEqual(target?.destination, .tab(tabId))
        try expectEqual(target?.atIndex, 0)
    }

    test("resolveTabTodoDropTarget .on paneEmptyPlaceholder inserts at pane index 0") {
        let (model, tabId, paneA, _) = makeTwoPaneTabTodoRowsModel()
        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let placeholderRow = rows.firstIndex(of: .paneEmptyPlaceholder(paneId: paneA))!

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: placeholderRow, dropOperation: .on)

        try expectEqual(target?.destination, .pane(paneA))
        try expectEqual(target?.atIndex, 0)
    }

    test("resolveTabTodoDropTarget .above first tabItem inserts at tab index 0") {
        var (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTabTodo(tabId: tabId, text: "tab A"))
        let rows = buildTabTodoRows(model: model, tabId: tabId)

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: 1, dropOperation: .above)

        try expectEqual(target?.destination, .tab(tabId))
        try expectEqual(target?.atIndex, 0)
    }

    test("resolveTabTodoDropTarget .above between two tabItems uses local index") {
        var (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTabTodo(tabId: tabId, text: "tab A"))
        update(&model, .addTabTodo(tabId: tabId, text: "tab B"))
        let rows = buildTabTodoRows(model: model, tabId: tabId)

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: 2, dropOperation: .above)

        try expectEqual(target?.destination, .tab(tabId))
        try expectEqual(target?.atIndex, 1)
    }

    test("resolveTabTodoDropTarget .above paneSectionHeader appends to previous section") {
        var (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTabTodo(tabId: tabId, text: "tab A"))
        update(&model, .addTabTodo(tabId: tabId, text: "tab B"))
        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let firstPaneHeader = rows.firstIndex {
            if case .paneSectionHeader = $0 { return true }
            return false
        }!

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: firstPaneHeader, dropOperation: .above)

        try expectEqual(target?.destination, .tab(tabId))
        try expectEqual(target?.atIndex, 2)
    }

    test("resolveTabTodoDropTarget .above one-past-end appends to last section") {
        var (model, tabId, _, paneB) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTodo(paneId: paneB, text: "pane B"))
        let rows = buildTabTodoRows(model: model, tabId: tabId)

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: rows.count, dropOperation: .above)

        try expectEqual(target?.destination, .pane(paneB))
        try expectEqual(target?.atIndex, 1)
    }

    test("resolveTabTodoDropTarget .above tabEmptyPlaceholder inserts at tab index 0") {
        let (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let placeholderRow = rows.firstIndex(of: .tabEmptyPlaceholder)!

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: placeholderRow, dropOperation: .above)

        try expectEqual(target?.destination, .tab(tabId))
        try expectEqual(target?.atIndex, 0)
    }

    test("resolveTabTodoDropTarget .above paneEmptyPlaceholder inserts at pane index 0") {
        let (model, tabId, paneA, _) = makeTwoPaneTabTodoRowsModel()
        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let placeholderRow = rows.firstIndex(of: .paneEmptyPlaceholder(paneId: paneA))!

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: placeholderRow, dropOperation: .above)

        try expectEqual(target?.destination, .pane(paneA))
        try expectEqual(target?.atIndex, 0)
    }

    test("resolveTabTodoDropTarget .above one-past-end appends to final placeholder section") {
        let (model, tabId, _, paneB) = makeTwoPaneTabTodoRowsModel()
        let rows = buildTabTodoRows(model: model, tabId: tabId)

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: rows.count, dropOperation: .above)

        try expectEqual(target?.destination, .pane(paneB))
        try expectEqual(target?.atIndex, 0)
    }

    test("resolveTabTodoDropTarget .above tabSectionHeader row 0 returns nil") {
        let (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        let rows = buildTabTodoRows(model: model, tabId: tabId)

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: 0, dropOperation: .above)

        try expect(target == nil)
    }

    test("resolveTabTodoBucketStep tab + delta=+1 returns pane0") {
        let (_, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()

        let destination = resolveTabTodoBucketStep(
            current: .tab(todoId: UUID()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            delta: 1
        )

        try expectEqual(destination, .pane(paneA))
    }

    test("resolveTabTodoBucketStep pane0 + delta=-1 returns tab") {
        let (_, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()

        let destination = resolveTabTodoBucketStep(
            current: .pane(paneId: paneA, todoId: UUID()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            delta: -1
        )

        try expectEqual(destination, .tab(tabId))
    }

    test("resolveTabTodoBucketStep tab + delta=-1 stops at start") {
        let (_, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()

        let destination = resolveTabTodoBucketStep(
            current: .tab(todoId: UUID()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            delta: -1
        )

        try expect(destination == nil)
    }

    test("resolveTabTodoBucketStep lastPane + delta=+1 stops at end") {
        let (_, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()

        let destination = resolveTabTodoBucketStep(
            current: .pane(paneId: paneB, todoId: UUID()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            delta: 1
        )

        try expect(destination == nil)
    }

    // MARK: - resolveTabTodoReorderStep

    test("resolveTabTodoReorderStep middle of tab section with delta=+1 reorders down") {
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

        try expectEqual(step, .reorderInSection(toIndex: 2))
    }

    test("resolveTabTodoReorderStep middle of tab section with delta=-1 reorders up") {
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

        try expectEqual(step, .reorderInSection(toIndex: 0))
    }

    test("resolveTabTodoReorderStep last tab item with delta=+1 moves to first pane at start") {
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

        try expectEqual(step, .moveToBucket(destination: .pane(paneA), atIndex: 0))
    }

    test("resolveTabTodoReorderStep last tab item with delta=+1 moves to empty first pane at start") {
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

        try expectEqual(step, .moveToBucket(destination: .pane(paneA), atIndex: 0))
    }

    test("resolveTabTodoReorderStep first pane0 item with delta=-1 moves to tab end") {
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

        try expectEqual(step, .moveToBucket(destination: .tab(tabId), atIndex: 3))
    }

    test("resolveTabTodoReorderStep first pane0 item with delta=-1 moves to empty tab at start") {
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

        try expectEqual(step, .moveToBucket(destination: .tab(tabId), atIndex: 0))
    }

    test("resolveTabTodoReorderStep last pane0 item with delta=+1 moves to pane1 start") {
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

        try expectEqual(step, .moveToBucket(destination: .pane(paneB), atIndex: 0))
    }

    test("resolveTabTodoReorderStep first pane1 item with delta=-1 moves to pane0 end") {
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

        try expectEqual(step, .moveToBucket(destination: .pane(paneA), atIndex: 4))
    }

    test("resolveTabTodoReorderStep first tab item with delta=-1 stops at top") {
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

        try expect(step == nil)
    }

    test("resolveTabTodoReorderStep last last-pane item with delta=+1 stops at bottom") {
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

        try expect(step == nil)
    }

    test("assignJumpKeys caps mapping at jump key sequence count") {
        let ids = (0..<(jumpModeKeySequence.count + 3)).map { _ in TabId() }
        let keyMap = assignJumpKeys(visibleTabs: ids)
        try expectEqual(keyMap.count, jumpModeKeySequence.count)
        try expect(keyMap[ids[jumpModeKeySequence.count - 1]] != nil)
        try expect(keyMap[ids[jumpModeKeySequence.count]] == nil)
        try expect(keyMap[ids[jumpModeKeySequence.count + 2]] == nil)
    }

    // MARK: - desiredFocusBorders (focus-border projection, Stage 3)

    test("desiredFocusBorders: single-pane selected tab draws no focus border (bell still shows)") {
        var model = makeModel()
        createTab(&model)
        let pane = selectedTab(in: model)!.focusedPaneId
        // Single-pane tab: no green focus border even though it is the focused pane.
        try expectEqual(
            desiredFocusBorders(in: model)[pane],
            BorderState(focused: false, bell: false),
            "single-pane focused tab draws no border")
        // An unread alert still lights the (red) bell border; the single-pane rule
        // suppresses only the green focus border, not the bell.
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: pane,
            title: "DanTerm", body: "x", createdAt: Date(), isUnread: true), at: 0)
        try expectEqual(
            desiredFocusBorders(in: model)[pane],
            BorderState(focused: false, bell: true),
            "single-pane tab still shows the bell border")
    }

    test("desiredFocusBorders: split tab marks the focused pane, bell follows unread alert") {
        var model = makeModel()
        createTab(&model)
        let paneA = selectedTab(in: model)!.focusedPaneId
        update(&model, .splitPane(paneId: paneA, direction: .horizontal))
        let focusedId = selectedTab(in: model)!.focusedPaneId
        let otherId = allPaneIds(selectedTab(in: model)!.rootNode).first { $0 != focusedId }!

        var borders = desiredFocusBorders(in: model)
        try expectEqual(borders[focusedId], BorderState(focused: true, bell: false),
            "focused pane in a split tab draws the focus border")
        try expectEqual(borders[otherId], BorderState(focused: false, bell: false),
            "unfocused sibling draws no border")

        // Unread alert on the unfocused sibling lights only its bell.
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: otherId,
            title: "DanTerm", body: "x", createdAt: Date(), isUnread: true), at: 0)
        borders = desiredFocusBorders(in: model)
        try expectEqual(borders[otherId], BorderState(focused: false, bell: true),
            "unfocused pane with an unread alert shows the bell border")
        try expectEqual(borders[focusedId], BorderState(focused: true, bell: false),
            "focused pane is unaffected by a sibling's alert")
    }

    test("desiredFocusBorders: keyed over all live panes; non-selected tabs draw no border") {
        var model = makeModel()
        createTab(&model)
        let tab0Pane = selectedTab(in: model)!.focusedPaneId
        update(&model, .splitPane(paneId: tab0Pane, direction: .horizontal))
        createTab(&model)  // tab1 becomes selected; tab0's split panes are now hidden

        let borders = desiredFocusBorders(in: model)
        try expectEqual(Set(borders.keys), Set(model.allPaneIds),
            "projection is keyed over every live pane")
        for paneId in allPaneIds(model.groups[0].tabs[0].rootNode) {
            try expectEqual(borders[paneId], BorderState(focused: false, bell: false),
                "panes in a non-selected tab draw no border")
        }
    }

    // MARK: - desiredPaneToolbar (pane-toolbar projection, Stage 4)

    test("desiredPaneToolbar: derives all eight toolbar fields from the model + pane") {
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
        // Two unread alerts (counted) plus one read alert (excluded) for this pane.
        for unread in [true, true, false] {
            model.alerts.insert(AlertModel(
                id: AlertId(), kind: .bell, paneId: paneId,
                title: "DanTerm", body: "x", createdAt: Date(), isUnread: unread), at: 0)
        }
        try expectEqual(
            desiredPaneToolbar(in: model)[paneId],
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

    test("desiredPaneToolbar: keyed over every live pane") {
        var model = makeModel()
        createTab(&model)
        let tab0Pane = selectedTab(in: model)!.focusedPaneId
        update(&model, .splitPane(paneId: tab0Pane, direction: .horizontal))
        createTab(&model)  // second tab, hidden, still projected
        try expectEqual(Set(desiredPaneToolbar(in: model).keys), Set(model.allPaneIds),
            "toolbar projection covers all live panes (host destroyed elsewhere -> default no-op remove)")
    }

    // MARK: - desiredSearchOverlays (search-overlay projection, Stage 4)

    test("desiredSearchOverlays: keyed only while search is active; drops the key on endSearch") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        // No search yet: the pane has no overlay key.
        try expect(desiredSearchOverlays(in: model)[paneId] == nil,
            "no active search -> no key")

        update(&model, .ghosttyStartSearch(paneId: paneId, needle: "foo"))
        model.searchState[paneId]?.total = 7
        model.searchState[paneId]?.selected = 2
        try expectEqual(
            desiredSearchOverlays(in: model)[paneId],
            SearchOverlayRender(needle: "foo", total: 7, selected: 2),
            "active search keys the pane with needle + match counts")

        // Ending search clears searchState; the pane's key disappears. In the live
        // pass that fires applyDiff's `remove` -> hideSearchOverlay while the pane
        // (and its wrapper) survive.
        update(&model, .endSearch(paneId: paneId))
        try expect(desiredSearchOverlays(in: model)[paneId] == nil,
            "ended search drops the pane's key (disappear-but-host-survives)")
    }

    // MARK: - desiredPaneConfig (pane-config projection)

    test("desiredPaneConfig: keyed only for themed panes; drops the key on clear") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId

        try expect(desiredPaneConfig(in: model)[paneId] == nil,
            "nil theme -> no config key")

        update(&model, .setPaneTheme(paneId: paneId, themeName: "Dracula"))
        try expectEqual(
            desiredPaneConfig(in: model)[paneId],
            PaneConfigKey(theme: "Dracula", generation: 0),
            "set theme keys the pane")

        update(&model, .setPaneTheme(paneId: paneId, themeName: nil))
        try expect(desiredPaneConfig(in: model)[paneId] == nil,
            "cleared theme drops the pane's key")
    }

    test("desiredPaneConfig: remote override takes priority over user theme") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        model.updatePane(paneId) { pane in
            pane.theme = "Dracula"
            pane.remoteThemeOverride = "Purplepeter"
        }

        try expectEqual(
            desiredPaneConfig(in: model)[paneId],
            PaneConfigKey(theme: "Purplepeter", generation: 0),
            "effective theme prefers remote override")
    }

    test("desiredPaneConfig: ghosttyConfigReloaded changes every themed pane generation") {
        var model = makeModel()
        createTab(&model)
        let firstPaneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .setPaneTheme(paneId: firstPaneId, themeName: "Dracula"))
        update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let themedPaneIds = Set(desiredPaneConfig(in: model).keys)
        createTab(&model)
        let unthemedPaneId = selectedTab(in: model)!.focusedPaneId

        let before = desiredPaneConfig(in: model)
        try expectEqual(Set(before.keys), themedPaneIds)
        try expect(before[unthemedPaneId] == nil, "unthemed pane is absent before reload")

        update(&model, .ghosttyConfigReloaded)
        let after = desiredPaneConfig(in: model)
        try expectEqual(Set(after.keys), themedPaneIds)
        try expect(after[unthemedPaneId] == nil, "unthemed pane stays absent after reload")
        for paneId in themedPaneIds {
            try expectEqual(after[paneId]?.generation, (before[paneId]?.generation ?? -1) + 1)
            try expectEqual(after[paneId]?.theme, before[paneId]?.theme)
        }
    }

    test("ghosttyConfigReloaded increments generation and returns no commands") {
        var model = makeModel()
        let commands = update(&model, .ghosttyConfigReloaded)

        try expectEqual(model.ghosttyConfigGeneration, 1)
        try expectEqual(commands.count, 0)
    }

    // MARK: - desiredSidebar (sidebar projection, Stage 5)

    test("desiredSidebar: ordered groups -> tabs with rendered attrs, collapse, jump badge") {
        let g1 = GroupId(); let g2 = GroupId()
        let tA = TabId(); let tB = TabId(); let tC = TabId()
        let pA = PaneId(); let pB = PaneId(); let pC = PaneId()
        var tabA = TabModel(id: tA, focusedPaneId: pA, rootNode: .leaf(PaneModel(id: pA)))
        tabA.title = "shell"; tabA.customTitle = "Edited"; tabA.subtitle = "~/src"; tabA.color = .blue
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
        try expect(!proj.isSingleGroupMode, "two groups -> not single-group mode")
        try expectEqual(proj.groups.map(\.id), [g1, g2], "groups in model order")

        let work = proj.groups[0]
        try expectEqual(work.name, "Work")
        try expect(work.isCollapsed, "collapse projected from the model")
        try expect(work.isFirst, "first group flagged")
        try expectEqual(work.tabCount, 2)
        try expectEqual(work.unreadAlertCount, 1, "group bell rolls up its tabs' unread alerts")
        try expectEqual(work.tabs.map(\.id), [tA, tB], "tabs in group order")
        // Tab A: displayTitle resolves customTitle; subtitle, color, bell carried.
        try expectEqual(work.tabs[0].displayTitle, "Edited")
        try expectEqual(work.tabs[0].subtitle, "~/src")
        try expectEqual(work.tabs[0].color, .blue)
        try expectEqual(work.tabs[0].unreadAlertCount, 1)
        try expect(work.tabs[0].jumpKey == nil, "tab A has no jump key")
        // Tab B: jump badge from model.jumpMode.keyMap.
        try expectEqual(work.tabs[1].jumpKey, "j", "jump badge from model.jumpMode.keyMap")
        try expect(!proj.groups[1].isFirst, "second group not first")
    }

    test("desiredSidebar: projection excludes selection (independent of selectedTabId)") {
        let (model, ids) = makeMruModel(tabCount: 3)
        var other = model
        other.selectedTabId = ids[2]
        try expect(model.selectedTabId != other.selectedTabId, "precondition: selection differs")
        try expectEqual(desiredSidebar(in: model), desiredSidebar(in: other),
            "selection is view-owned -> not in the projection")
    }

    test("desiredSidebar: one group is single-group mode") {
        let (model, _) = makeMruModel(tabCount: 2)
        try expect(desiredSidebar(in: model).isSingleGroupMode,
            "a single group promotes tabs to roots (no group row)")
    }

    // MARK: - desiredWindowChrome (window title / badges / tab-todo projection, Stage 6)

    test("desiredWindowChrome: window/content titles, unread count, and tab-todo rollup from the selected tab") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        // Distinct custom title + subtitle so the window title carries the " — sub"
        // suffix while the content title stays the bare display title.
        model.groups[0].tabs[0].customTitle = "Custom"
        model.groups[0].tabs[0].subtitle = "~/src"
        // Tab-level + pane-level to-dos roll up together (tabTodoRollup).
        model.groups[0].tabs[0].todos = [TodoItem(id: UUID(), text: "t1", isDone: false)]
        model.updatePane(paneId) {
            $0.todos = [
                TodoItem(id: UUID(), text: "p1", isDone: true),
                TodoItem(id: UUID(), text: "p2", isDone: false),
            ]
        }
        // Two unread alerts (counted) plus one read alert (excluded) -> totalUnreadAlertCount 2.
        for unread in [true, true, false] {
            model.alerts.insert(AlertModel(
                id: AlertId(), kind: .bell, paneId: paneId,
                title: "DanTerm", body: "x", createdAt: Date(), isUnread: unread), at: 0)
        }
        try expectEqual(
            desiredWindowChrome(in: model),
            WindowChromeProjection(
                windowTitle: "Custom — ~/src",
                contentTitle: "Custom",
                unreadCount: 2,
                tabTodoTotal: 3,
                tabTodoUncompleted: 2),
            "window chrome derives both titles, the unread badge count, and the tab-todo rollup")
    }

    test("desiredWindowChrome: no selected tab -> empty titles, zero badge, zero rollup") {
        let model = makeModel()  // no tabs -> selectedTabId == nil
        try expect(selectedTab(in: model) == nil, "precondition: no selected tab")
        try expectEqual(
            desiredWindowChrome(in: model),
            WindowChromeProjection(
                windowTitle: "", contentTitle: "",
                unreadCount: 0, tabTodoTotal: 0, tabTodoUncompleted: 0),
            "no selected tab -> empty titles, zero badge, (0,0) rollup")
    }

    test("desiredWindowChrome: window title omits the subtitle when absent or equal to the display title") {
        var model = makeModel()
        createTab(&model)
        model.groups[0].tabs[0].title = "vim"  // no customTitle, no subtitle
        var proj = desiredWindowChrome(in: model)
        try expectEqual(proj.windowTitle, "vim", "no subtitle -> window title is the bare display title")
        try expectEqual(proj.contentTitle, "vim")
        // A subtitle equal to the display title is treated as absent (no " — vim" dup).
        model.groups[0].tabs[0].subtitle = "vim"
        proj = desiredWindowChrome(in: model)
        try expectEqual(proj.windowTitle, "vim", "subtitle == display title is suppressed")
    }

    test("desiredWindowChrome: reflects the selected tab, not background tabs") {
        var model = makeModel()
        createTab(&model)  // tab A
        let tabAId = model.groups[0].tabs[0].id
        model.groups[0].tabs[0].customTitle = "Alpha"
        createTab(&model)  // tab B (now selected)
        model.groups[0].tabs[1].customTitle = "Beta"

        try expectEqual(desiredWindowChrome(in: model).contentTitle, "Beta",
            "chrome reflects the selected tab B")
        // Selection drives the projection (the property the deleted .setWindowTitle
        // selection-change emission tests asserted, now structural via reconcile()).
        model.selectedTabId = tabAId
        try expectEqual(desiredWindowChrome(in: model).contentTitle, "Alpha",
            "selecting tab A makes the chrome reflect A")
    }
}

/// Build a model with N tabs in one group; returns the tab ids in display order.
/// Used by MRU/cycle tests in this file and tests/UpdateMruTests.swift.
func makeMruModel(tabCount: Int) -> (model: AppModel, tabIds: [TabId]) {
    var model = makeModel()
    var ids: [TabId] = []
    for _ in 0..<tabCount {
        let paneId = PaneId()
        let tabId = TabId()
        ids.append(tabId)
        model.groups[0].tabs.append(TabModel(id: tabId, focusedPaneId: paneId, rootNode: .leaf(PaneModel(id: paneId))))
    }
    return (model, ids)
}
