import Foundation

func paneTests() {
    print("Pane Tests...")

    test("testSplitPaneProducesCorrectTree") {
        var model = makeModel()
        createTab(&model)
        let originalPaneId = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let tab = model.groups[0].tabs[0]

        guard case .split(_, let direction, let first, let second, _) = tab.rootNode else {
            throw TestFailure(message: "root should be a split after splitting")
        }
        try expectEqual(direction, .horizontal)
        if case .leaf(let fid) = first {
            try expectEqual(fid, originalPaneId, "first child should be original pane")
        } else {
            throw TestFailure(message: "first child should be a leaf")
        }
        if case .leaf(let sid) = second {
            try expectEqual(sid, tab.focusedPaneId, "second child should be new focused pane")
        } else {
            throw TestFailure(message: "second child should be a leaf")
        }
        try expectEqual(model.panes.count, 2)
    }

    test("testClosePanePromotesSibling") {
        var model = makeModel()
        createTab(&model)
        let firstPaneId = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let newPaneId = model.groups[0].tabs[0].focusedPaneId
        try expect(newPaneId != firstPaneId, "split should create new pane")

        update(&model, .closePane(paneId: newPaneId))
        let updatedTab = model.groups[0].tabs[0]
        try expect(model.panes[newPaneId] == nil, "closed pane should be removed from panes dict")
        if case .leaf(let remainingId) = updatedTab.rootNode {
            try expectEqual(remainingId, firstPaneId)
        } else {
            throw TestFailure(message: "root should be a leaf after closing one of two panes")
        }
    }

    test("testFocusDirectionRequestsFirstResponder") {
        var model = makeModel()
        createTab(&model)
        let leftPaneId = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let rightPaneId = model.groups[0].tabs[0].focusedPaneId
        try expect(rightPaneId != leftPaneId)

        let effectsLeft = update(&model, .focusDirection(direction: .horizontal, side: .first))
        try expectEqual(model.groups[0].tabs[0].focusedPaneId, rightPaneId, "focusDirection should not change model focus directly")
        try expect(hasEffect(effectsLeft) {
            if case .makeFirstResponder(let paneId) = $0, paneId == leftPaneId { return true }
            return false
        }, "should request first responder for left pane")

        // Simulate AppKit callback to move model focus to the left pane.
        _ = update(&model, .paneBecameFirstResponder(paneId: leftPaneId))

        let effectsRight = update(&model, .focusDirection(direction: .horizontal, side: .second))
        try expectEqual(model.groups[0].tabs[0].focusedPaneId, leftPaneId, "focusDirection should still not mutate focus")
        try expect(hasEffect(effectsRight) {
            if case .makeFirstResponder(let paneId) = $0, paneId == rightPaneId { return true }
            return false
        }, "should request first responder for right pane")
    }

    test("testSplitRatioChangedNoEffects") {
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))

        guard case .split(let splitId, _, _, _, _) = model.groups[0].tabs[0].rootNode else {
            throw TestFailure(message: "should be a split")
        }

        let effects = update(&model, .splitRatioChanged(splitId: splitId, ratio: 0.3))
        try expectEqual(effects.count, 1, "splitRatioChanged should only produce scheduleCheckpoint")
        try expect(hasEffect(effects) { if case .scheduleCheckpoint = $0 { return true }; return false })

        guard case .split(_, _, _, _, let ratio) = model.groups[0].tabs[0].rootNode else {
            throw TestFailure(message: "should still be a split")
        }
        try expectEqual(ratio, 0.3, "ratio should be updated")
    }

    test("testClosePaneDeepTree") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        // Split A -> [A, B]
        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId

        // Split B -> [B, C] making tree: [A, [B, C]]
        update(&model, .splitPane(direction: .vertical))
        let paneC = model.groups[0].tabs[0].focusedPaneId

        try expectEqual(model.panes.count, 3)

        // Close B (inner leaf)
        update(&model, .closePane(paneId: paneB))
        try expect(model.panes[paneB] == nil, "paneB should be removed")
        try expectEqual(model.panes.count, 2)

        // Tree should now be [A, C]
        let tab = model.groups[0].tabs[0]
        guard case .split(_, .horizontal, let first, let second, _) = tab.rootNode else {
            throw TestFailure(message: "root should be a horizontal split")
        }
        if case .leaf(let fid) = first {
            try expectEqual(fid, paneA, "first should be paneA")
        } else {
            throw TestFailure(message: "first child should be a leaf")
        }
        if case .leaf(let sid) = second {
            try expectEqual(sid, paneC, "second should be paneC")
        } else {
            throw TestFailure(message: "second child should be a leaf")
        }
    }

    test("testFocusDirectionNoNeighbor") {
        var model = makeModel()
        createTab(&model)

        // Single pane, try to navigate
        let effects = update(&model, .focusDirection(direction: .horizontal, side: .first))
        try expectEqual(effects.count, 0, "no effects when no neighbor exists")
    }

    test("testPaneBecameFirstResponder") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        // Split to create paneB
        update(&model, .splitPane(direction: .horizontal))

        // Set some state on paneA
        model.panes[paneA]?.title = "my-title"
        model.panes[paneA]?.cwd = "/tmp/foo"

        // Add an unread alert for paneA
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        // paneB is focused. Simulate paneA becoming first responder.
        let effects = update(&model, .paneBecameFirstResponder(paneId: paneA))

        let tab = model.groups[0].tabs[0]
        try expectEqual(tab.focusedPaneId, paneA, "focused pane should change")
        try expectEqual(model.alerts[0].isUnread, false, "alert should be marked read")
        try expect(hasEffect(effects) {
            if case .rebuildContentView = $0 { return true }
            return false
        }, "should emit rebuildContentView")
        try expect(hasEffect(effects) {
            if case .reloadSidebarRow = $0 { return true }
            return false
        }, "should emit reloadSidebarRow")
        try expect(hasEffect(effects) {
            if case .setWindowTitle = $0 { return true }
            return false
        }, "should emit setWindowTitle")
    }

    test("testPaneBecameFirstResponderSamePane") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let effects = update(&model, .paneBecameFirstResponder(paneId: paneId))
        try expectEqual(effects.count, 0, "same pane should return no effects")
    }

    // MARK: - Zoom Tests

    test("testToggleZoomOnSplit") {
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))

        let effects = update(&model, .toggleZoomPane)
        try expectEqual(model.groups[0].tabs[0].isZoomed, true)
        try expect(hasEffect(effects) {
            if case .rebuildContentView = $0 { return true }
            return false
        }, "should rebuild content view")
    }

    test("testToggleZoomOff") {
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        update(&model, .toggleZoomPane)

        let effects = update(&model, .toggleZoomPane)
        try expectEqual(model.groups[0].tabs[0].isZoomed, false)
        try expect(hasEffect(effects) {
            if case .rebuildContentView = $0 { return true }
            return false
        }, "should rebuild content view")
    }

    test("testToggleZoomNoOpOnSinglePane") {
        var model = makeModel()
        createTab(&model)

        let effects = update(&model, .toggleZoomPane)
        try expectEqual(model.groups[0].tabs[0].isZoomed, false)
        try expectEqual(effects.count, 0, "no effects on single pane")
    }

    test("testCloseZoomedPaneNormalizesZoom") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId
        update(&model, .toggleZoomPane)
        try expectEqual(model.groups[0].tabs[0].isZoomed, true)

        // Close paneB, leaving only paneA (single leaf)
        update(&model, .closePane(paneId: paneB))
        try expectEqual(model.groups[0].tabs[0].isZoomed, false, "zoom should normalize when single pane remains")
        try expectEqual(model.groups[0].tabs[0].focusedPaneId, paneA)
    }

    test("testCloseZoomedPaneClearsZoomWithMultiplePanesRemaining") {
        var model = makeModel()
        createTab(&model)

        // Create 3 panes: [A, [B, C]]
        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId
        update(&model, .splitPane(direction: .vertical))
        let paneC = model.groups[0].tabs[0].focusedPaneId

        // Zoom paneC
        update(&model, .toggleZoomPane)
        try expectEqual(model.groups[0].tabs[0].isZoomed, true)

        // Close zoomed paneC — should unzoom even though splits remain
        update(&model, .closePane(paneId: paneC))
        try expectEqual(model.groups[0].tabs[0].isZoomed, false, "zoom should clear when zoomed pane is closed")
        try expectEqual(model.groups[0].tabs[0].focusedPaneId, paneB, "focus should move to sibling")
    }

    test("testSplitWhileZoomedClearsZoom") {
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        update(&model, .toggleZoomPane)
        try expectEqual(model.groups[0].tabs[0].isZoomed, true)

        update(&model, .splitPane(direction: .vertical))
        try expectEqual(model.groups[0].tabs[0].isZoomed, false, "split should clear zoom")
    }

    test("testFocusDirectionWhileZoomedClearsZoom") {
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        update(&model, .toggleZoomPane)
        try expectEqual(model.groups[0].tabs[0].isZoomed, true)

        let effects = update(&model, .focusDirection(direction: .horizontal, side: .first))
        try expectEqual(model.groups[0].tabs[0].isZoomed, false, "focus direction should clear zoom")
        try expect(hasEffect(effects) {
            if case .rebuildContentView = $0 { return true }
            return false
        }, "should rebuild content view")
    }

    // MARK: - movePane Tests

    test("testMovePaneSplitIntent") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId

        // Move A to bottom of B
        let effects = update(&model, .movePane(source: paneA, target: paneB, intent: .splitBottom))
        let tab = model.groups[0].tabs[0]
        try expectEqual(tab.focusedPaneId, paneA, "source should be focused after move")
        try expectEqual(tab.isZoomed, false, "zoom should be cleared")
        try expect(hasEffect(effects) {
            if case .rebuildContentView = $0 { return true }
            return false
        }, "should emit rebuildContentView")
        // Both panes should still exist
        let ids = allPaneIds(tab.rootNode)
        try expectEqual(ids.count, 2)
        try expect(ids.contains(paneA))
        try expect(ids.contains(paneB))
    }

    test("testMovePaneSwapIntent") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId

        let effects = update(&model, .movePane(source: paneA, target: paneB, intent: .swap))
        let tab = model.groups[0].tabs[0]
        try expectEqual(tab.focusedPaneId, paneA, "source should be focused after swap")
        try expect(hasEffect(effects) {
            if case .rebuildContentView = $0 { return true }
            return false
        }, "should emit rebuildContentView")
        // A should now be second (was first before swap)
        try expectEqual(lastLeafId(tab.rootNode), paneA, "A should now be last (swapped to right)")
    }

    test("testMovePaneSameSourceTarget") {
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        let pane = model.groups[0].tabs[0].focusedPaneId

        let effects = update(&model, .movePane(source: pane, target: pane, intent: .swap))
        try expectEqual(effects.count, 0, "same source/target is no-op")
    }

    test("testMovePaneNoSelectedTab") {
        var model = makeModel()
        model.selectedTabId = nil

        let effects = update(&model, .movePane(source: PaneId(), target: PaneId(), intent: .swap))
        try expectEqual(effects.count, 0, "no selected tab is no-op")
    }

    test("testMovePaneZoomedTab") {
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        let paneA = model.groups[0].tabs[0].focusedPaneId
        update(&model, .toggleZoomPane)
        try expectEqual(model.groups[0].tabs[0].isZoomed, true)

        let paneB = allPaneIds(model.groups[0].tabs[0].rootNode).first(where: { $0 != paneA })!
        let effects = update(&model, .movePane(source: paneA, target: paneB, intent: .swap))
        try expectEqual(effects.count, 0, "zoomed tab is no-op")
    }

    test("testSplitPaneTargetsByPaneId") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        // Split → [A, B], B is focused
        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId
        try expect(paneB != paneA)

        // Split pane A by paneId while B is focused → should split A, not B
        update(&model, .splitPane(paneId: paneA, direction: .vertical))
        let tab = model.groups[0].tabs[0]

        // Root should still be horizontal (the original split)
        guard case .split(_, .horizontal, let first, let second, _) = tab.rootNode else {
            throw TestFailure(message: "root should be horizontal split")
        }

        // First child should now be a vertical split (A was split)
        guard case .split(_, .vertical, let innerFirst, let innerSecond, _) = first else {
            throw TestFailure(message: "first child should be vertical split (pane A was split)")
        }
        if case .leaf(let fid) = innerFirst {
            try expectEqual(fid, paneA, "inner first should be pane A")
        } else {
            throw TestFailure(message: "inner first should be a leaf")
        }
        // The new pane should be the focused pane
        let paneC = tab.focusedPaneId
        if case .leaf(let sid) = innerSecond {
            try expectEqual(sid, paneC, "inner second should be new pane C")
        } else {
            throw TestFailure(message: "inner second should be a leaf")
        }

        // Second child should still be B (untouched)
        if case .leaf(let bid) = second {
            try expectEqual(bid, paneB, "second child should still be pane B")
        } else {
            throw TestFailure(message: "second child should be a leaf")
        }

        try expectEqual(model.panes.count, 3)
    }

    test("testFocusDirectionThenFirstResponderUpdatesFocusAndRebuilds") {
        var model = makeModel()
        createTab(&model)
        let leftPaneId = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let rightPaneId = model.groups[0].tabs[0].focusedPaneId
        try expect(rightPaneId != leftPaneId)

        let focusEffects = update(&model, .focusDirection(direction: .horizontal, side: .first))
        try expectEqual(model.groups[0].tabs[0].focusedPaneId, rightPaneId, "focus should remain on right pane until first responder callback")
        try expect(hasEffect(focusEffects) {
            if case .makeFirstResponder(let paneId) = $0, paneId == leftPaneId { return true }
            return false
        }, "should request first responder for left pane")

        let callbackEffects = update(&model, .paneBecameFirstResponder(paneId: leftPaneId))
        try expectEqual(model.groups[0].tabs[0].focusedPaneId, leftPaneId, "focus should update after first responder callback")
        try expect(hasEffect(callbackEffects) {
            if case .rebuildContentView = $0 { return true }
            return false
        }, "should rebuild content view after focus change callback")
    }

    // MARK: - movePaneToTab Tests

    test("testMovePaneToTabBasicCrossTab") {
        var model = makeModel()
        createTab(&model) // tab1 with paneA
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model) // tab2 with paneB
        let tab2Id = model.groups[0].tabs[1].id
        let paneB = model.groups[0].tabs[1].focusedPaneId

        let effects = update(&model, .movePaneToTab(paneId: paneA, targetTabId: tab2Id))

        // Source tab (single pane) should be removed
        try expectEqual(model.groups[0].tabs.count, 1, "source tab should be removed when empty")
        try expectEqual(model.groups[0].tabs[0].id, tab2Id, "remaining tab should be target")

        // Target tab should have both panes in a split
        let targetTab = model.groups[0].tabs[0]
        let targetPaneIds = allPaneIds(targetTab.rootNode)
        try expectEqual(targetPaneIds.count, 2, "target tab should have 2 panes")
        try expect(targetPaneIds.contains(paneA), "target should contain moved pane")
        try expect(targetPaneIds.contains(paneB), "target should contain original pane")

        // Selection and focus
        try expectEqual(model.selectedTabId, tab2Id, "should select target tab")
        try expectEqual(targetTab.focusedPaneId, paneA, "should focus moved pane")
        try expectEqual(targetTab.isZoomed, false, "target zoom should be cleared")

        // No destroySurface — surface is reused
        try expect(!hasEffect(effects) {
            if case .destroySurface = $0 { return true }
            return false
        }, "should not destroy any surfaces")

        try expect(hasEffect(effects) {
            if case .makeFirstResponder(let pid) = $0, pid == paneA { return true }
            return false
        }, "should emit makeFirstResponder for moved pane")
    }

    test("testMovePaneToTabSourceHasMultiplePanes") {
        var model = makeModel()
        createTab(&model) // tab1
        let tab1Id = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId
        update(&model, .splitPane(direction: .horizontal)) // tab1 = [A, B]
        let paneB = model.groups[0].tabs[0].focusedPaneId

        createTab(&model) // tab2 with paneC
        let tab2Id = model.groups[0].tabs[1].id
        let paneC = model.groups[0].tabs[1].focusedPaneId

        // Move paneA from tab1 to tab2
        update(&model, .movePaneToTab(paneId: paneA, targetTabId: tab2Id))

        // Tab1 should remain with just paneB
        try expectEqual(model.groups[0].tabs.count, 2, "source tab should remain")
        let srcTab = model.groups[0].tabs.first(where: { $0.id == tab1Id })!
        if case .leaf(let id) = srcTab.rootNode {
            try expectEqual(id, paneB, "source tab should have paneB as leaf")
        } else {
            throw TestFailure(message: "source tab should be a single leaf")
        }
        try expectEqual(srcTab.focusedPaneId, paneB, "source tab should focus paneB")

        // Tab2 should have [C, A] split
        let dstTab = model.groups[0].tabs.first(where: { $0.id == tab2Id })!
        let dstPaneIds = allPaneIds(dstTab.rootNode)
        try expectEqual(dstPaneIds.count, 2)
        try expect(dstPaneIds.contains(paneA))
        try expect(dstPaneIds.contains(paneC))
        try expectEqual(dstTab.focusedPaneId, paneA, "target tab should focus moved pane")
    }

    test("testMovePaneToTabSameTabIsNoOp") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let effects = update(&model, .movePaneToTab(paneId: paneId, targetTabId: tabId))
        try expectEqual(effects.count, 0, "same tab should be no-op")
    }

    test("testMovePaneToTabSourceTabClosedWhenEmpty") {
        var model = makeModel()
        createTab(&model) // tab1 with single pane
        let tab1Id = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model) // tab2
        let tab2Id = model.groups[0].tabs[1].id

        update(&model, .movePaneToTab(paneId: paneA, targetTabId: tab2Id))

        // Tab1 should be gone
        try expect(!model.groups[0].tabs.contains(where: { $0.id == tab1Id }), "empty source tab should be removed")
        try expectEqual(model.groups[0].tabs.count, 1)
    }

    test("testMovePaneToTabCrossGroup") {
        var model = makeModel()
        createTab(&model) // tab1 in group 0 (General)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        // Create a second group with a tab
        update(&model, .createGroup(name: "Work"))
        let group1Id = model.groups[1].id
        let tab2Id = model.groups[1].tabs[0].id
        let paneB = model.groups[1].tabs[0].focusedPaneId

        // Move paneA from group0 to group1's tab
        update(&model, .movePaneToTab(paneId: paneA, targetTabId: tab2Id))

        // Source group should be pruned (was single tab, now empty)
        try expectEqual(model.groups.count, 1, "empty source group should be pruned")
        try expectEqual(model.groups[0].id, group1Id, "only Work group should remain")

        // Target tab should have both panes
        let targetTab = model.groups[0].tabs.first(where: { $0.id == tab2Id })!
        let targetPanes = allPaneIds(targetTab.rootNode)
        try expectEqual(targetPanes.count, 2)
        try expect(targetPanes.contains(paneA))
        try expect(targetPanes.contains(paneB))
    }

    test("testMovePaneToTabDefocusesOldTabSurfaces") {
        var model = makeModel()
        createTab(&model) // tab1
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model) // tab2 (now selected)
        let tab2Id = model.groups[0].tabs[1].id
        let paneB = model.groups[0].tabs[1].focusedPaneId

        // Move paneA to tab2 (tab2 is currently selected)
        let effects = update(&model, .movePaneToTab(paneId: paneA, targetTabId: tab2Id))

        // Should defocus tab2's panes before switching (paneB was in the selected tab)
        try expect(hasEffect(effects) {
            if case .focusSurface(let pid, let focused) = $0, pid == paneB, !focused { return true }
            return false
        }, "should defocus old tab's panes")
    }

    test("testMovePaneToTabEmitsMakeFirstResponder") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)
        let tab2Id = model.groups[0].tabs[1].id

        let effects = update(&model, .movePaneToTab(paneId: paneA, targetTabId: tab2Id))

        try expect(hasEffect(effects) {
            if case .makeFirstResponder(let pid) = $0, pid == paneA { return true }
            return false
        }, "should emit makeFirstResponder for moved pane")
    }

    test("testMovePaneToTabTargetZoomCleared") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)
        let tab2Id = model.groups[0].tabs[1].id
        // Zoom tab2
        update(&model, .splitPane(direction: .horizontal))
        update(&model, .toggleZoomPane)
        try expectEqual(model.groups[0].tabs[1].isZoomed, true)

        update(&model, .movePaneToTab(paneId: paneA, targetTabId: tab2Id))

        let targetTab = model.groups[0].tabs.first(where: { $0.id == tab2Id })!
        try expectEqual(targetTab.isZoomed, false, "target zoom should be cleared after move")
    }

    // MARK: - movePaneToNewTab Tests

    test("testMovePaneToNewTabPathB_SplitTabCreatesNewTab") {
        var model = makeModel()
        createTab(&model) // tab1
        let tab1Id = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId
        update(&model, .splitPane(direction: .horizontal)) // tab1 = [A, B]
        let paneB = model.groups[0].tabs[0].focusedPaneId
        let groupId = model.groups[0].id

        // Drag paneA to new tab at index 1 (after tab1)
        let effects = update(&model, .movePaneToNewTab(paneId: paneA, inGroupId: groupId, atIndex: 1))

        try expectEqual(model.groups[0].tabs.count, 2, "should have 2 tabs")
        // Source tab should still exist with paneB only
        let srcTab = model.groups[0].tabs[0]
        try expectEqual(srcTab.id, tab1Id)
        if case .leaf(let id) = srcTab.rootNode {
            try expectEqual(id, paneB, "source tab should have paneB")
        } else {
            throw TestFailure(message: "source tab should be a single leaf")
        }
        try expectEqual(srcTab.focusedPaneId, paneB)

        // New tab should be at index 1 with paneA
        let newTab = model.groups[0].tabs[1]
        if case .leaf(let id) = newTab.rootNode {
            try expectEqual(id, paneA, "new tab should have paneA")
        } else {
            throw TestFailure(message: "new tab should be a single leaf")
        }
        try expectEqual(newTab.focusedPaneId, paneA)
        try expectEqual(model.selectedTabId, newTab.id, "new tab should be selected")

        // No destroySurface
        try expect(!hasEffect(effects) {
            if case .destroySurface = $0 { return true }
            return false
        }, "should not destroy any surfaces")

        try expect(hasEffect(effects) {
            if case .makeFirstResponder(let pid) = $0, pid == paneA { return true }
            return false
        }, "should emit makeFirstResponder for moved pane")
    }

    test("testMovePaneToNewTabPathA_SinglePaneMoveTab") {
        var model = makeModel()
        createTab(&model) // tab1 single pane
        let tab1Id = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId
        // Give tab1 custom metadata
        update(&model, .setTabColor(tabId: tab1Id, color: .red))
        update(&model, .renameTab(id: tab1Id, name: "MyTab"))

        createTab(&model) // tab2
        let groupId = model.groups[0].id

        // Drag paneA (only pane in tab1) to index 2 (after tab2)
        let effects = update(&model, .movePaneToNewTab(paneId: paneA, inGroupId: groupId, atIndex: 2))

        try expectEqual(model.groups[0].tabs.count, 2, "tab count should be same (tab was moved, not cloned)")
        // tab1 should now be at index 1 (it was moved from 0 to end)
        let movedTab = model.groups[0].tabs[1]
        try expectEqual(movedTab.id, tab1Id, "tab entity should be preserved (same ID)")
        try expectEqual(movedTab.color, .red, "color should be preserved")
        try expectEqual(movedTab.customTitle, "MyTab", "custom title should be preserved")
        try expectEqual(model.selectedTabId, tab1Id, "moved tab should be selected")

        try expect(!hasEffect(effects) {
            if case .destroySurface = $0 { return true }
            return false
        }, "should not destroy any surfaces")
    }

    test("testMovePaneToNewTabPathA_SameGroupIndexAdjust") {
        var model = makeModel()
        createTab(&model) // tab1 at index 0
        let tab1Id = model.groups[0].tabs[0].id
        let pane1 = model.groups[0].tabs[0].focusedPaneId

        createTab(&model) // tab2 at index 1
        createTab(&model) // tab3 at index 2
        let groupId = model.groups[0].id

        // Move tab1 (single pane) to index 2. Since removing tab1 from index 0 shifts
        // everything, the adjusted index should be 1.
        update(&model, .movePaneToNewTab(paneId: pane1, inGroupId: groupId, atIndex: 2))

        try expectEqual(model.groups[0].tabs.count, 3)
        // tab1 should be at index 1 after adjustment (was index 0, target 2, adjusted to 1)
        try expectEqual(model.groups[0].tabs[1].id, tab1Id)
        try expectEqual(model.selectedTabId, tab1Id)
    }

    test("testMovePaneToNewTabCrossGroup") {
        var model = makeModel()
        createTab(&model) // tab1 in General
        let tab1Id = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId
        update(&model, .splitPane(direction: .horizontal)) // tab1 = [A, B]

        // Create second group with a tab
        update(&model, .createGroup(name: "Work"))
        let group1Id = model.groups[1].id

        // Move paneA to a new tab in group1 at index 0
        update(&model, .movePaneToNewTab(paneId: paneA, inGroupId: group1Id, atIndex: 0))

        // Source tab should remain with paneB
        try expectEqual(model.groups[0].tabs.count, 1)
        try expectEqual(model.groups[0].tabs[0].id, tab1Id)

        // New tab in group1 at index 0
        try expectEqual(model.groups[1].tabs.count, 2, "group1 should have 2 tabs")
        let newTab = model.groups[1].tabs[0]
        if case .leaf(let id) = newTab.rootNode {
            try expectEqual(id, paneA)
        } else {
            throw TestFailure(message: "new tab should be a leaf")
        }
    }

    test("testMovePaneToNewTabSinglePaneSingleTabGuard") {
        var model = makeModel()
        createTab(&model) // only tab with single pane
        let paneA = model.groups[0].tabs[0].focusedPaneId
        let groupId = model.groups[0].id

        // Should be no-op: can't create a new tab from the only pane in the only tab
        let effects = update(&model, .movePaneToNewTab(paneId: paneA, inGroupId: groupId, atIndex: 0))
        try expectEqual(effects.count, 0, "should be no-op for single-pane single-tab")
        try expectEqual(model.groups[0].tabs.count, 1)
    }

    test("testMovePaneToNewTabPathB_SourceFocusUpdated") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId
        update(&model, .splitPane(direction: .horizontal)) // [A, B], B focused
        let paneB = model.groups[0].tabs[0].focusedPaneId

        // Move B (the focused pane) to a new tab
        let groupId = model.groups[0].id
        update(&model, .movePaneToNewTab(paneId: paneB, inGroupId: groupId, atIndex: 1))

        // Source tab should now focus paneA
        let srcTab = model.groups[0].tabs[0]
        try expectEqual(srcTab.focusedPaneId, paneA, "source tab should focus remaining pane")
    }

    test("testMovePaneToNewTabPathB_ChromeDerived") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId
        model.panes[paneA]?.title = "/Users/dan/projects"
        model.panes[paneA]?.cwd = "/Users/dan/projects"
        update(&model, .splitPane(direction: .horizontal))
        let groupId = model.groups[0].id

        // Move paneA to a new tab
        update(&model, .movePaneToNewTab(paneId: paneA, inGroupId: groupId, atIndex: 1))

        let newTab = model.groups[0].tabs[1]
        try expectEqual(newTab.title, abbreviateHome("/Users/dan/projects"), "title should be derived from pane")
        try expectEqual(newTab.subtitle, abbreviateHome("/Users/dan/projects"), "subtitle should be derived from pane cwd")
    }

    test("testMovePaneToNewTabAlertsClearedOnMove") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId
        update(&model, .splitPane(direction: .horizontal))
        let groupId = model.groups[0].id

        let alert = AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        )
        model.alerts.insert(alert, at: 0)

        update(&model, .movePaneToNewTab(paneId: paneA, inGroupId: groupId, atIndex: 1))

        let movedAlert = model.alerts.first(where: { $0.paneId == paneA })!
        try expectEqual(movedAlert.isUnread, false, "alert should be marked read")
    }

    test("testMovePaneToNewTabBeforeSourceIndex") {
        var model = makeModel()
        createTab(&model) // tab1 at 0
        update(&model, .splitPane(direction: .horizontal)) // tab1 = [A, B]
        let paneA = allPaneIds(model.groups[0].tabs[0].rootNode).first!
        let groupId = model.groups[0].id

        // Drag paneA to index 0 (before tab1)
        update(&model, .movePaneToNewTab(paneId: paneA, inGroupId: groupId, atIndex: 0))

        try expectEqual(model.groups[0].tabs.count, 2)
        // New tab should be at index 0
        let newTab = model.groups[0].tabs[0]
        if case .leaf(let id) = newTab.rootNode {
            try expectEqual(id, paneA)
        } else {
            throw TestFailure(message: "new tab should be a leaf with paneA")
        }
    }

    test("testMovePaneToTabAlertsClearedOnMove") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)
        let tab2Id = model.groups[0].tabs[1].id
        let paneB = model.groups[0].tabs[1].focusedPaneId

        // Create unread alert for paneA (the pane being moved)
        let alertA = AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "alert A", createdAt: Date(), isUnread: true
        )
        model.alerts.insert(alertA, at: 0)

        // Create unread alert for paneB (unrelated)
        let alertB = AlertModel(
            id: AlertId(), kind: .bell, paneId: paneB,
            title: "DanTerm", body: "alert B", createdAt: Date(), isUnread: true
        )
        model.alerts.insert(alertB, at: 0)

        update(&model, .movePaneToTab(paneId: paneA, targetTabId: tab2Id))

        // Moved pane's alert should be read
        let movedAlert = model.alerts.first(where: { $0.paneId == paneA })!
        try expectEqual(movedAlert.isUnread, false, "moved pane's alert should be marked read")

        // Unrelated alert should remain unread
        let otherAlert = model.alerts.first(where: { $0.paneId == paneB })!
        try expectEqual(otherAlert.isUnread, true, "unrelated alert should remain unread")
    }
}
