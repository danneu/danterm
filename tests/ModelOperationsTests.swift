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
                first: .leaf(tl),
                second: .leaf(bl),
                ratio: 0.5
            ),
            second: .split(
                id: SplitId(), direction: .vertical,
                first: .leaf(tr),
                second: .leaf(br),
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

    // MARK: - swapLeaves

    test("testSwapLeavesSimple") {
        let a = PaneId(), b = PaneId()
        let splitId = SplitId()
        let node = SplitNodeModel.split(
            id: splitId, direction: .horizontal,
            first: .leaf(a),
            second: .leaf(b),
            ratio: 0.6
        )
        let result = swapLeaves(node, a, b)
        try expect(result != nil, "should return non-nil")
        guard case .split(let rSplitId, .horizontal, let first, let second, let ratio) = result! else {
            throw TestFailure(message: "should be a horizontal split")
        }
        try expectEqual(rSplitId, splitId, "split id preserved")
        try expectEqual(ratio, 0.6, "ratio preserved")
        if case .leaf(let fid) = first { try expectEqual(fid, b) }
        else { throw TestFailure(message: "first should be leaf B") }
        if case .leaf(let sid) = second { try expectEqual(sid, a) }
        else { throw TestFailure(message: "second should be leaf A") }
    }

    test("testSwapLeavesNested") {
        let a = PaneId(), b = PaneId(), c = PaneId()
        let innerSplitId = SplitId()
        let outerSplitId = SplitId()
        let node = SplitNodeModel.split(
            id: outerSplitId, direction: .horizontal,
            first: .leaf(a),
            second: .split(
                id: innerSplitId, direction: .vertical,
                first: .leaf(b),
                second: .leaf(c),
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
        if case .leaf(let fid) = first { try expectEqual(fid, c, "first should now be C") }
        else { throw TestFailure(message: "first should be a leaf") }
        guard case .split(let rInnerId, .vertical, let innerFirst, let innerSecond, let innerRatio) = second else {
            throw TestFailure(message: "second should be inner split")
        }
        try expectEqual(rInnerId, innerSplitId, "inner split id preserved")
        try expectEqual(innerRatio, 0.3, "inner ratio preserved")
        if case .leaf(let fid) = innerFirst { try expectEqual(fid, b, "inner first still B") }
        else { throw TestFailure(message: "inner first should be leaf") }
        if case .leaf(let sid) = innerSecond { try expectEqual(sid, a, "inner second now A") }
        else { throw TestFailure(message: "inner second should be leaf") }
    }

    test("testSwapLeavesSamePane") {
        let a = PaneId()
        let node = SplitNodeModel.leaf(a)
        try expect(swapLeaves(node, a, a) == nil, "same pane returns nil")
    }

    test("testSwapLeavesMissingPane") {
        let a = PaneId(), b = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(a),
            second: .leaf(b),
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
            first: .leaf(a),
            second: .leaf(b),
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
            first: .leaf(a),
            second: .leaf(b),
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
            first: .leaf(a),
            second: .split(
                id: SplitId(), direction: .vertical,
                first: .leaf(b),
                second: .leaf(c),
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
            first: .leaf(a),
            second: .leaf(b),
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
        let node = SplitNodeModel.leaf(a)
        try expect(moveLeaf(node, source: a, target: a, direction: .horizontal, insertFirst: true) == nil, "same source/target returns nil")
    }

    test("testMoveLeafMissingSource") {
        let a = PaneId(), b = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(a),
            second: .leaf(b),
            ratio: 0.5
        )
        try expect(moveLeaf(node, source: PaneId(), target: b, direction: .horizontal, insertFirst: true) == nil, "missing source returns nil")
    }

    test("testMoveLeafMissingTarget") {
        let a = PaneId(), b = PaneId()
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(a),
            second: .leaf(b),
            ratio: 0.5
        )
        // removeLeaf(a) leaves .leaf(b), then insertAtLeaf for missing target returns nil
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
                first: .leaf(a),
                second: .leaf(b),
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
        let tab1 = TabModel(id: tabId1, focusedPaneId: a, rootNode: .leaf(a))
        let tab2 = TabModel(id: tabId2, focusedPaneId: b, rootNode: .leaf(b))
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
        model.panes[paneId] = PaneModel(id: paneId)
        model.groups[0].tabs.append(TabModel(id: tabId, focusedPaneId: paneId, rootNode: .leaf(paneId)))
    }
    return (model, ids)
}
