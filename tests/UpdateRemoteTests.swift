import Foundation

func remoteTests() {
    print("Remote Tests...")

    test("remoteSessionStarted sets isRemote") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let effects = update(&model, .remoteSessionStarted(paneId: paneId))
        try expectEqual(model.panes[paneId]?.isRemote, true, "pane should be remote")
        try expectEqual(effects.count, 0, "no effects expected")
    }

    test("commandEnded clears isRemote") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.panes[paneId]?.isRemote = true

        let effects = update(&model, .commandEnded(paneId: paneId))
        try expectEqual(model.panes[paneId]?.isRemote, false, "pane should not be remote")
        try expectEqual(effects.count, 0, "no effects expected")
    }

    test("commandEnded on non-remote pane is no-op") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let effects = update(&model, .commandEnded(paneId: paneId))
        try expectEqual(model.panes[paneId]?.isRemote, false, "pane should remain non-remote")
        try expectEqual(effects.count, 0, "no effects expected")
    }

    test("remoteSessionStarted on missing pane returns empty effects") {
        var model = makeModel()
        let fakePaneId = PaneId()
        let effects = update(&model, .remoteSessionStarted(paneId: fakePaneId))
        try expectEqual(effects.count, 0, "no effects for missing pane")
    }

    test("commandEnded on missing pane returns empty effects") {
        var model = makeModel()
        let fakePaneId = PaneId()
        let effects = update(&model, .commandEnded(paneId: fakePaneId))
        try expectEqual(effects.count, 0, "no effects for missing pane")
    }

    test("remote lifecycle: start then end") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        _ = update(&model, .remoteSessionStarted(paneId: paneId))
        try expectEqual(model.panes[paneId]?.isRemote, true)

        _ = update(&model, .commandEnded(paneId: paneId))
        try expectEqual(model.panes[paneId]?.isRemote, false)
    }
}
