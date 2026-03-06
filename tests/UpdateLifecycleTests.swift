import Foundation

func lifecycleTests() {
    print("Lifecycle Tests...")

    test("testAppBecameActive") {
        var model = makeModel()
        let effects = update(&model, .appBecameActive)
        try expectEqual(effects.count, 1)
        if case .setAppFocus(let focused) = effects[0] {
            try expectEqual(focused, true)
        } else {
            throw TestFailure(message: "expected setAppFocus(true)")
        }
    }

    test("testAppResignedActive") {
        var model = makeModel()
        let effects = update(&model, .appResignedActive)
        try expectEqual(effects.count, 1)
        if case .setAppFocus(let focused) = effects[0] {
            try expectEqual(focused, false)
        } else {
            throw TestFailure(message: "expected setAppFocus(false)")
        }
    }

    test("testNotificationClicked") {
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let firstPaneId = model.groups[0].tabs[0].focusedPaneId

        // Create second tab so selecting first is meaningful
        createTab(&model)

        let effects = update(&model, .notificationClicked(tabId: firstTabId, paneId: firstPaneId))
        try expectEqual(model.selectedTabId, firstTabId, "should select the clicked tab")
        try expect(hasEffect(effects) {
            if case .makeFirstResponder(let pid) = $0, pid == firstPaneId { return true }
            return false
        }, "should make pane first responder")
        try expect(hasEffect(effects) {
            if case .activateApp = $0 { return true }
            return false
        }, "should activate app")
    }

    test("testNotificationClickedNilPane") {
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id

        createTab(&model)

        let effects = update(&model, .notificationClicked(tabId: firstTabId, paneId: nil))
        try expectEqual(model.selectedTabId, firstTabId)
        try expect(!hasEffect(effects) {
            if case .makeFirstResponder = $0 { return true }
            return false
        }, "should not have makeFirstResponder when paneId is nil")
        try expect(hasEffect(effects) {
            if case .activateApp = $0 { return true }
            return false
        }, "should still activate app")
    }

    test("testTerminate") {
        var model = makeModel()
        let effects = update(&model, .terminate)
        try expectEqual(effects.count, 1)
        if case .terminate = effects[0] {
            // good
        } else {
            throw TestFailure(message: "expected terminate effect")
        }
    }

    test("testConfirmTerminateWithOneTab") {
        var model = makeModel()
        createTab(&model)
        let effects = update(&model, .confirmTerminate)
        try expectEqual(effects.count, 1)
        try expect(hasEffect(effects) {
            if case .terminate = $0 { return true }
            return false
        }, "should terminate when only one tab remains")
    }

    test("testConfirmTerminateWithMultipleTabs") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let effects = update(&model, .confirmTerminate)
        try expectEqual(effects.count, 0, "should not terminate when multiple tabs exist")
    }

    test("testCancelTerminate") {
        var model = makeModel()
        createTab(&model)
        let effects = update(&model, .cancelTerminate)
        try expectEqual(effects.count, 0, "cancel should produce no effects")
    }
}
