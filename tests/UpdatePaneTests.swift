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
        try expectEqual(effects.count, 0, "splitRatioChanged should produce no effects")

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
        model.panes[paneA]?.hasBell = true
        model.panes[paneA]?.title = "my-title"
        model.panes[paneA]?.cwd = "/tmp/foo"

        // paneB is focused. Simulate paneA becoming first responder.
        let effects = update(&model, .paneBecameFirstResponder(paneId: paneA))

        let tab = model.groups[0].tabs[0]
        try expectEqual(tab.focusedPaneId, paneA, "focused pane should change")
        try expectEqual(model.panes[paneA]?.hasBell, false, "bell should be cleared")
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
}
