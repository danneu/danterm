// Tests for per-pane theme switching: setPaneTheme message, split inheritance,
// snapshot round-tripping, and resilient decoding of unknown theme names.
import Foundation

func themeTests() {
    print("Theme Tests...")

    test("setPaneTheme updates model") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .setPaneTheme(paneId: paneId, themeName: "Dracula"))
        try expectEqual(model.pane(paneId)?.theme, "Dracula")
    }

    test("setPaneTheme produces applyPaneTheme and scheduleCheckpoint effects") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let effects = update(&model, .setPaneTheme(paneId: paneId, themeName: "Nord"))
        try expect(hasEffect(effects) {
            if case .applyPaneTheme(let id) = $0 {
                return id == paneId
            }; return false
        }, "should emit applyPaneTheme")
        try expect(hasEffect(effects) {
            if case .scheduleCheckpoint = $0 { return true }; return false
        }, "should emit scheduleCheckpoint")
    }

    test("clearPaneTheme sets theme to nil") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .setPaneTheme(paneId: paneId, themeName: "Dracula"))
        try expectEqual(model.pane(paneId)?.theme, "Dracula")
        update(&model, .setPaneTheme(paneId: paneId, themeName: nil))
        try expect(model.pane(paneId)?.theme == nil, "theme should be nil after clearing")
    }

    test("splitPane inherits theme from parent") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .setPaneTheme(paneId: paneId, themeName: "Catppuccin Mocha"))
        update(&model, .splitPane(paneId: paneId, direction: .horizontal))
        let tab = selectedTab(in: model)!
        let newPaneId = tab.focusedPaneId
        try expect(newPaneId != paneId, "new pane should be different from parent")
        try expectEqual(model.pane(newPaneId)?.theme, "Catppuccin Mocha")
    }

    test("splitPane with theme emits applyPaneTheme for new pane") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .setPaneTheme(paneId: paneId, themeName: "Rose Pine"))
        let effects = update(&model, .splitPane(paneId: paneId, direction: .vertical))
        let tab = selectedTab(in: model)!
        let newPaneId = tab.focusedPaneId
        try expect(hasEffect(effects) {
            if case .applyPaneTheme(let id) = $0 {
                return id == newPaneId
            }; return false
        }, "should emit applyPaneTheme for new pane")
    }

    test("splitPane without theme does not emit applyPaneTheme") {
        var model = makeModel()
        createTab(&model)
        let effects = update(&model, .splitPane(direction: .horizontal))
        try expect(!hasEffect(effects) {
            if case .applyPaneTheme = $0 { return true }; return false
        }, "should not emit applyPaneTheme when no theme")
    }

    test("toSnapshot preserves theme") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .setPaneTheme(paneId: paneId, themeName: "Gruvbox Dark"))
        let snapshot = toSnapshot(model)
        let ps = snapshot.panes.first { $0.id == paneId.rawValue.uuidString }
        try expectEqual(ps?.theme, "Gruvbox Dark")
    }

    test("snapshot round-trip preserves theme") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .setPaneTheme(paneId: paneId, themeName: "TokyoNight Night"))
        let snapshot = toSnapshot(model)
        guard let restored = validateAndBuild(snapshot) else {
            throw TestFailure(message: "snapshot round-trip failed")
        }
        let restoredPane = restored.pane(paneId)
        try expect(restoredPane != nil, "pane should exist in restored model")
        try expectEqual(restoredPane?.theme, "TokyoNight Night")
    }

    test("snapshot with unknown theme name decodes and preserves in model") {
        let json = """
        {
          "version": 1,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "rootNode": { "type": "leaf", "paneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5" }
              }]
            }],
            "panes": [{
              "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
              "title": "Terminal",
              "theme": "NonExistent Theme"
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        try expectEqual(initFile.model.panes[0].theme, "NonExistent Theme")
        // validateAndBuild should succeed — unknown themes are preserved as-is
        let built = validateAndBuild(initFile.model)
        try expect(built != nil, "should rebuild despite unknown theme")
        let paneId = PaneId(rawValue: UUID(uuidString: "A13076E4-A29C-4358-A771-B4B4DF84C6C5")!)
        try expectEqual(built!.pane(paneId)?.theme, "NonExistent Theme")
    }

    test("export preserves theme in snapshot") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .setPaneTheme(paneId: paneId, themeName: "Catppuccin Latte"))
        let effects = update(&model, .exportState)
        guard case .exportState(let snapshot) = effects.first else {
            throw TestFailure(message: "expected exportState effect")
        }
        let ps = snapshot.panes.first { $0.id == paneId.rawValue.uuidString }
        try expectEqual(ps?.theme, "Catppuccin Latte")
    }

    test("mergeCheckpoints preserves theme") {
        let light = AppModelSnapshot(
            groups: [GroupSnapshot(id: "g1", name: "Default", isCollapsed: nil, tabs: [
                TabSnapshot(id: "t1", customTitle: nil, focusedPaneId: "p1", rootNode:
                    SplitNodeSnapshot.leaf(paneId: "p1"), color: nil)
            ])],
            panes: [PaneSnapshot(id: "p1", title: "t", cwd: "/c", launch: nil, scrollback: nil, theme: "Dracula")],
            selectedTabId: "t1"
        )
        let enriched = AppModelSnapshot(
            groups: [GroupSnapshot(id: "g1", name: "Default", isCollapsed: nil, tabs: [
                TabSnapshot(id: "t1", customTitle: nil, focusedPaneId: "p1", rootNode:
                    SplitNodeSnapshot.leaf(paneId: "p1"), color: nil)
            ])],
            panes: [PaneSnapshot(id: "p1", title: "t", cwd: "/c", launch: nil, scrollback: "text", theme: "Dracula")],
            selectedTabId: "t1"
        )
        let merged = mergeCheckpoints(light: light, enriched: enriched)
        try expectEqual(merged.panes[0].theme, "Dracula")
        try expectEqual(merged.panes[0].scrollback, "text")
    }

    test("theme name round-trips as arbitrary string") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .setPaneTheme(paneId: paneId, themeName: "My Custom Theme"))
        let snapshot = toSnapshot(model)
        guard let restored = validateAndBuild(snapshot) else {
            throw TestFailure(message: "snapshot round-trip failed")
        }
        try expectEqual(restored.pane(paneId)?.theme, "My Custom Theme")
    }

    test("unknown theme name preserved in snapshot round-trip") {
        let json = """
        {
          "version": 1,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "rootNode": { "type": "leaf", "paneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5" }
              }]
            }],
            "panes": [{
              "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
              "title": "Terminal",
              "theme": "NonExistent Theme"
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let built = validateAndBuild(initFile.model)
        try expect(built != nil, "should rebuild")
        // Round-trip the built model back to snapshot
        let snapshot = toSnapshot(built!)
        try expectEqual(snapshot.panes[0].theme, "NonExistent Theme")
    }

    test("nil theme round-trips through snapshot") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        // Don't set any theme — it's nil by default
        let snapshot = toSnapshot(model)
        guard let restored = validateAndBuild(snapshot) else {
            throw TestFailure(message: "snapshot round-trip failed")
        }
        try expect(restored.pane(paneId)?.theme == nil, "nil theme should survive round-trip")
    }
}
