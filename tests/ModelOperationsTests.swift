import Foundation

func modelOperationsTests() {
    print("ModelOperations Tests...")

    // MARK: - allPaneIds

    test("testAllPaneIdsFlatLeaf") {
        let id = PaneId()
        let node = SplitNodeModel.leaf(id)
        let ids = allPaneIds(node)
        try expectEqual(ids.count, 1)
        try expectEqual(ids[0], id)
    }

    test("testAllPaneIdsNestedTree") {
        let a = PaneId(), b = PaneId(), c = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(a),
            second: .split(
                id: SplitId(), direction: .vertical,
                first: .leaf(b),
                second: .leaf(c),
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

    // MARK: - firstLeafId / lastLeafId

    test("testFirstLeafId") {
        let a = PaneId(), b = PaneId(), c = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .split(
                id: SplitId(), direction: .vertical,
                first: .leaf(a),
                second: .leaf(b),
                ratio: 0.5
            ),
            second: .leaf(c),
            ratio: 0.5
        )
        try expectEqual(firstLeafId(node), a)
    }

    test("testLastLeafId") {
        let a = PaneId(), b = PaneId(), c = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(a),
            second: .split(
                id: SplitId(), direction: .vertical,
                first: .leaf(b),
                second: .leaf(c),
                ratio: 0.5
            ),
            ratio: 0.5
        )
        try expectEqual(lastLeafId(node), c)
    }

    // MARK: - splitLeaf

    test("testSplitLeafNotFound") {
        let a = PaneId()
        let node = SplitNodeModel.leaf(a)
        let result = splitLeaf(node, paneId: PaneId(), direction: .horizontal, newPaneId: PaneId())
        try expect(result == nil, "should return nil for unknown paneId")
    }

    // MARK: - removeLeaf

    test("testRemoveLeafRootLeaf") {
        let a = PaneId()
        let node = SplitNodeModel.leaf(a)
        let (newTree, nextFocus) = removeLeaf(node, paneId: a)
        try expect(newTree == nil, "removing root leaf should return nil tree")
        try expect(nextFocus == nil, "removing root leaf should return nil focus")
    }

    test("testRemoveLeafDeepTree") {
        let a = PaneId(), b = PaneId(), c = PaneId()
        // Tree: [A, [B, C]]
        let inner = SplitNodeModel.split(
            id: SplitId(), direction: .vertical,
            first: .leaf(b),
            second: .leaf(c),
            ratio: 0.5
        )
        let root = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(a),
            second: inner,
            ratio: 0.5
        )

        // Remove B — inner split should collapse to just C, result: [A, C]
        let (newTree, nextFocus) = removeLeaf(root, paneId: b)
        try expect(newTree != nil, "tree should not be nil")
        guard case .split(_, .horizontal, let first, let second, _) = newTree! else {
            throw TestFailure(message: "should be a horizontal split")
        }
        if case .leaf(let fid) = first {
            try expectEqual(fid, a)
        } else {
            throw TestFailure(message: "first should be leaf A")
        }
        if case .leaf(let sid) = second {
            try expectEqual(sid, c)
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
            first: .leaf(a),
            second: .leaf(b),
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
            first: .leaf(a),
            second: .leaf(b),
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
            first: .leaf(a),
            second: .split(
                id: SplitId(), direction: .vertical,
                first: .leaf(b),
                second: .leaf(c),
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
            first: .leaf(a),
            second: .leaf(b),
            ratio: 0.5
        )
        // From A, go left — no neighbor
        try expect(nearestLeaf(node, from: a, direction: .horizontal, side: .first) == nil, "should return nil at edge")
        // From A, go vertical — wrong direction
        try expect(nearestLeaf(node, from: a, direction: .vertical, side: .second) == nil, "should return nil for wrong direction")
    }

    // MARK: - setRatio

    test("testSetRatio") {
        let splitId = SplitId()
        let a = PaneId(), b = PaneId()
        let node = SplitNodeModel.split(
            id: splitId, direction: .horizontal,
            first: .leaf(a),
            second: .leaf(b),
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
            first: .leaf(a),
            second: .split(
                id: splitId2, direction: .vertical,
                first: .leaf(b),
                second: .leaf(c),
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

    // MARK: - abbreviateHome

    test("testAbbreviateHome") {
        let home = NSHomeDirectory()
        try expectEqual(abbreviateHome(home + "/projects"), "~/projects")
        try expectEqual(abbreviateHome("/tmp/foo"), "/tmp/foo")
        try expectEqual(abbreviateHome(home), "~")
    }

    // MARK: - bellCount / groupBellCount

    test("testBellCount") {
        let a = PaneId(), b = PaneId()
        let tab = TabModel(
            id: TabId(),
            focusedPaneId: a,
            rootNode: .split(
                id: SplitId(), direction: .horizontal,
                first: .leaf(a),
                second: .leaf(b),
                ratio: 0.5
            )
        )
        var panes: [PaneId: PaneModel] = [
            a: PaneModel(id: a),
            b: PaneModel(id: b),
        ]
        try expectEqual(bellCount(for: tab, panes: panes), 0)

        panes[a]?.hasBell = true
        try expectEqual(bellCount(for: tab, panes: panes), 1)

        panes[b]?.hasBell = true
        try expectEqual(bellCount(for: tab, panes: panes), 2)
    }

    test("testGroupBellCount") {
        let a = PaneId(), b = PaneId()
        let tab1 = TabModel(id: TabId(), focusedPaneId: a, rootNode: .leaf(a))
        let tab2 = TabModel(id: TabId(), focusedPaneId: b, rootNode: .leaf(b))
        let group = GroupModel(id: GroupId(), name: "Test", isDefault: false, tabs: [tab1, tab2])
        var panes: [PaneId: PaneModel] = [
            a: PaneModel(id: a),
            b: PaneModel(id: b),
        ]

        try expectEqual(groupBellCount(for: group, panes: panes), 0)
        panes[b]?.hasBell = true
        try expectEqual(groupBellCount(for: group, panes: panes), 1)
    }
}
