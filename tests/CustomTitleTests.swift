import Foundation

func customTitleTests() {
    print("Custom Title Tests...")

    // MARK: - Model

    test("testDisplayTitlePrefersCustom") {
        var model = makeModel()
        createTab(&model)
        model.groups[0].tabs[0].customTitle = "My App"
        model.groups[0].tabs[0].title = "vim"
        try expectEqual(model.groups[0].tabs[0].displayTitle, "My App")
    }

    test("testDisplayTitleFallback") {
        var model = makeModel()
        createTab(&model)
        model.groups[0].tabs[0].title = "vim"
        try expect(model.groups[0].tabs[0].customTitle == nil)
        try expectEqual(model.groups[0].tabs[0].displayTitle, "vim")
    }

    // MARK: - renameTab

    test("testRenameTab") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        let effects = update(&model, .renameTab(id: tabId, name: "My App"))
        try expectEqual(model.groups[0].tabs[0].customTitle, "My App")
        // The renamed row updates via reconcileSidebar (displayTitle is in the projection).
        // Tab is selected, so it should also emit setWindowTitle.
        try expect(hasEffect(effects) {
            if case .setWindowTitle = $0 { return true }
            return false
        }, "should emit setWindowTitle for selected tab")
    }

    test("testRenameTabClear") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .renameTab(id: tabId, name: "Custom"))
        try expectEqual(model.groups[0].tabs[0].customTitle, "Custom")

        let effects = update(&model, .renameTab(id: tabId, name: nil))
        try expect(model.groups[0].tabs[0].customTitle == nil, "customTitle should be nil")
        // The renamed row updates via reconcileSidebar (displayTitle is in the projection).
        try expect(hasEffect(effects) {
            if case .setWindowTitle = $0 { return true }
            return false
        }, "should emit setWindowTitle")
    }

    test("testRenameTabEmptyStringClearsTitle") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .renameTab(id: tabId, name: "Custom"))

        update(&model, .renameTab(id: tabId, name: "   "))
        try expect(model.groups[0].tabs[0].customTitle == nil, "whitespace-only name should clear customTitle")
    }

    test("testRenameTabTrimsWhitespace") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        update(&model, .renameTab(id: tabId, name: "  My App  "))
        try expectEqual(model.groups[0].tabs[0].customTitle, "My App")
    }

    test("testRenameTabNonSelectedDoesNotEmitSetWindowTitle") {
        var model = makeModel()
        createTab(&model) // tab A
        let tabAId = model.groups[0].tabs[0].id
        createTab(&model) // tab B (now selected)

        let effects = update(&model, .renameTab(id: tabAId, name: "Custom"))
        try expectEqual(model.groups[0].tabs[0].customTitle, "Custom")
        try expect(!hasEffect(effects) {
            if case .setWindowTitle = $0 { return true }
            return false
        }, "should not emit setWindowTitle for non-selected tab")
    }

    // MARK: - surfaceTitle does not override custom title

    test("testSurfaceTitleDoesNotOverrideCustom") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .renameTab(id: tabId, name: "My App"))

        // surfaceTitle updates tab.title but customTitle should stay
        update(&model, .surfaceTitle(paneId: paneId, title: "vim"))
        try expectEqual(model.groups[0].tabs[0].customTitle, "My App", "customTitle should persist")
        try expectEqual(model.groups[0].tabs[0].displayTitle, "My App", "displayTitle should use customTitle")
    }

    test("testPaneFocusDoesNotOverrideCustom") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .renameTab(id: tabId, name: "My App"))

        // Split to create a second pane
        update(&model, .splitPane(direction: .horizontal))
        let paneA = allPaneIds(model.groups[0].tabs[0].rootNode).first!
        model.updatePane(paneA) { $0.title = "zsh" }
        // Focus change should update tab.title but not customTitle
        update(&model, .paneBecameFirstResponder(paneId: paneA))
        try expectEqual(model.groups[0].tabs[0].customTitle, "My App")
        try expectEqual(model.groups[0].tabs[0].displayTitle, "My App")
    }

    // MARK: - windowTitle uses displayTitle

    test("testSetWindowTitleUsesDisplayTitle") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .renameTab(id: tabId, name: "Custom"))

        // surfaceTitle triggers setWindowTitle — it should contain custom title
        let effects = update(&model, .surfaceTitle(paneId: paneId, title: "vim"))
        let windowTitleEffect = effects.first(where: {
            if case .setWindowTitle = $0 { return true }
            return false
        })
        try expect(windowTitleEffect != nil, "should emit setWindowTitle")
        if case .setWindowTitle(let title) = windowTitleEffect! {
            try expect(title.contains("Custom"), "window title should contain custom title, got: \(title)")
        }
    }

    test("testCloseConfirmUsesDisplayTitle") {
        var model = makeModel()
        createTab(&model) // tab A
        let tabAId = model.groups[0].tabs[0].id
        update(&model, .renameTab(id: tabAId, name: "My Server"))

        createTab(&model) // tab B (so closing A doesn't trigger terminate confirmation)

        // Split tab A to get multi-pane
        update(&model, .selectTab(id: tabAId))
        update(&model, .splitPane(direction: .horizontal))

        let effects = update(&model, .requestCloseTab(id: tabAId))
        let confirmEffect = effects.first(where: {
            if case .showCloseTabConfirmation = $0 { return true }
            return false
        })
        try expect(confirmEffect != nil, "should show confirmation")
        if case .showCloseTabConfirmation(_, let tabTitle, _, _, _) = confirmEffect! {
            try expectEqual(tabTitle, "My Server", "confirmation should use displayTitle")
        }
    }

    // MARK: - Selection-changing paths emit setWindowTitle

    test("testSelectTabEmitsSetWindowTitle") {
        var model = makeModel()
        createTab(&model) // tab A
        let tabAId = model.groups[0].tabs[0].id
        createTab(&model) // tab B (now selected)

        let effects = update(&model, .selectTab(id: tabAId))
        try expect(hasEffect(effects) {
            if case .setWindowTitle = $0 { return true }
            return false
        }, "selectTab should emit setWindowTitle")
    }

    test("testCloseSelectedTabEmitsSetWindowTitle") {
        var model = makeModel()
        createTab(&model) // tab A
        createTab(&model) // tab B (now selected)
        let tabBId = model.groups[0].tabs[1].id

        let effects = update(&model, .closeTab(id: tabBId))
        try expect(hasEffect(effects) {
            if case .setWindowTitle = $0 { return true }
            return false
        }, "closing selected tab should emit setWindowTitle for fallback tab")
    }

    test("testCreateTabEmitsSetWindowTitle") {
        var model = makeModel()
        let effects = createTab(&model)
        try expect(hasEffect(effects) {
            if case .setWindowTitle = $0 { return true }
            return false
        }, "createTab should emit setWindowTitle")
    }

    test("testDeleteGroupEmitsSetWindowTitle") {
        var model = makeModel()
        createTab(&model) // tab1 in General
        createTab(&model) // tab2 keeps General alive after moveTab
        let tabA = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Temp"))
        let tempGroupId = model.groups[1].id
        // Move tabA to Temp — General keeps tab2
        update(&model, .moveTabs(tabIds: [tabA], toGroupId: tempGroupId, atIndex: 0))

        // Select tabA (in Temp) so the deletion triggers a selection change.
        update(&model, .selectTab(id: tabA))

        let effects = update(&model, .deleteGroup(id: tempGroupId, moveTabs: false))
        try expect(hasEffect(effects) {
            if case .setWindowTitle = $0 { return true }
            return false
        }, "deleteGroup should emit setWindowTitle when selection changes")
    }

    test("testMovePaneToTabEmitsSetWindowTitle") {
        var model = makeModel()
        createTab(&model) // tab1
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model) // tab2
        let tab2Id = model.groups[0].tabs[1].id

        let effects = update(&model, .movePaneToTab(paneId: paneA, targetTabId: tab2Id))
        try expect(hasEffect(effects) {
            if case .setWindowTitle = $0 { return true }
            return false
        }, "movePaneToTab should emit setWindowTitle")
    }

    // MARK: - Snapshot

    test("testToSnapshotPreservesCustomTitle") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .renameTab(id: tabId, name: "My Server"))

        let snapshot = toSnapshot(model)
        try expectEqual(snapshot.groups[0].tabs[0].customTitle, "My Server")
    }

    test("testToSnapshotCustomTitleRoundTrip") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .renameTab(id: tabId, name: "My Server"))

        // Export → encode → decode → rebuild
        let snapshot = toSnapshot(model)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(AppInitFile(version: 1, model: snapshot))
        let decoded = try JSONDecoder().decode(AppInitFile.self, from: data)
        let rebuilt = validateAndBuild(decoded.model)

        try expect(rebuilt != nil, "round-trip should produce valid model")
        try expectEqual(rebuilt!.groups[0].tabs[0].customTitle, "My Server")
        try expectEqual(rebuilt!.groups[0].tabs[0].displayTitle, "My Server")
    }

    // MARK: - Tab chrome derivation from snapshot

    test("testImportDerivesTitleFromFocusedPane") {
        let home = NSHomeDirectory()
        let json = """
        {
          "version": 2,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "focusedPaneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                "rootNode": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "\(home)/world", "cwd": "~/world" } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model != nil, "should build model")
        try expectEqual(model!.groups[0].tabs[0].title, "~/world")
    }

    test("testImportDerivesSubtitleFromLaunchCwd") {
        let json = """
        {
          "version": 2,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "focusedPaneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                "rootNode": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "T", "launch": { "cwd": "~/projects" } } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model != nil, "should build model")
        try expectEqual(model!.groups[0].tabs[0].subtitle, "~/projects")
    }

    test("testImportNilCwdDerivesNilSubtitle") {
        let json = """
        {
          "version": 2,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "focusedPaneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                "rootNode": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "Terminal" } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model != nil, "should build model")
        try expect(model!.groups[0].tabs[0].subtitle == nil, "subtitle should be nil when pane has no cwd")
    }

    test("testLegacySnapshotWithTitleSubtitleDecodesSuccessfully") {
        // Old JSON that still includes tab-level "title" and "subtitle" should decode fine
        let json = """
        {
          "version": 2,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "title": "vim",
                "subtitle": "~/world",
                "focusedPaneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                "rootNode": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "Terminal", "cwd": "~/world" } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model != nil, "legacy snapshot with title/subtitle should still decode")
        // Title is derived from pane, not from the (now-ignored) tab-level title
        try expectEqual(model!.groups[0].tabs[0].title, "Terminal")
        try expectEqual(model!.groups[0].tabs[0].subtitle, "~/world")
    }

    test("testDeriveTabChromeMatchesRuntimeBehavior") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let home = NSHomeDirectory()

        // Set pane title and cwd to absolute paths
        model.updatePane(paneId) { $0.title = "\(home)/world" }
        model.updatePane(paneId) { $0.cwd = "\(home)/projects" }
        // Trigger paneBecameFirstResponder via split + refocus
        update(&model, .splitPane(direction: .horizontal))
        update(&model, .paneBecameFirstResponder(paneId: paneId))

        let tab = model.groups[0].tabs[0]
        let pane = model.pane(paneId)!
        let chrome = deriveTabChrome(from: pane)

        try expectEqual(tab.title, chrome.title)
        try expectEqual(tab.subtitle, chrome.subtitle)
        try expectEqual(tab.title, "~/world")
        try expectEqual(tab.subtitle, "~/projects")
    }

    // MARK: - renameCompletionMessages

    test("renameCompletion: Enter with change dispatches rename then focus") {
        let tabId = TabId()
        let msgs = renameCompletionMessages(
            isConfirm: true, action: .tab(tabId), newName: "New Name")
        try expectEqual(msgs.count, 2)
        guard case .renameTab(let id, let name) = msgs[0] else {
            return try expect(false, "expected renameTab")
        }
        try expectEqual(id, tabId)
        try expectEqual(name, "New Name")
        guard case .sidebarRenameEnded = msgs[1] else {
            return try expect(false, "expected sidebarRenameEnded")
        }
    }

    test("renameCompletion: Enter with unchanged text still dispatches rename") {
        let tabId = TabId()
        let msgs = renameCompletionMessages(
            isConfirm: true, action: .tab(tabId), newName: "zsh")
        try expectEqual(msgs.count, 2)
        guard case .renameTab = msgs[0] else {
            return try expect(false, "expected renameTab")
        }
        guard case .sidebarRenameEnded = msgs[1] else {
            return try expect(false, "expected sidebarRenameEnded")
        }
    }

    test("renameCompletion: Enter with empty tab name clears title") {
        let tabId = TabId()
        let msgs = renameCompletionMessages(
            isConfirm: true, action: .tab(tabId), newName: "")
        try expectEqual(msgs.count, 2)
        guard case .renameTab(_, let name) = msgs[0] else {
            return try expect(false, "expected renameTab")
        }
        try expect(name == nil, "empty name should clear custom title")
    }

    test("renameCompletion: Enter with empty group name skips rename") {
        let groupId = GroupId()
        let msgs = renameCompletionMessages(
            isConfirm: true, action: .group(groupId), newName: "")
        try expectEqual(msgs.count, 1)
        guard case .sidebarRenameEnded = msgs[0] else {
            return try expect(false, "expected sidebarRenameEnded")
        }
    }

    test("renameCompletion: Esc dispatches only focus restore") {
        let tabId = TabId()
        let msgs = renameCompletionMessages(
            isConfirm: false, action: .tab(tabId), newName: "Changed Text")
        try expectEqual(msgs.count, 1)
        guard case .sidebarRenameEnded = msgs[0] else {
            return try expect(false, "expected sidebarRenameEnded")
        }
    }

    test("renameCompletion: Esc group dispatches only focus restore") {
        let groupId = GroupId()
        let msgs = renameCompletionMessages(
            isConfirm: false, action: .group(groupId), newName: "New Name")
        try expectEqual(msgs.count, 1)
        guard case .sidebarRenameEnded = msgs[0] else {
            return try expect(false, "expected sidebarRenameEnded")
        }
    }

    test("renameCompletion: nil target dispatches only focus restore") {
        let msgs = renameCompletionMessages(
            isConfirm: true, action: nil, newName: "text")
        try expectEqual(msgs.count, 1)
        guard case .sidebarRenameEnded = msgs[0] else {
            return try expect(false, "expected sidebarRenameEnded")
        }
    }

    // MARK: - sidebarRenameEnded update handler

    test("sidebarRenameEnded restores focus to active pane") {
        var model = makeModel()
        createTab(&model)
        let focusedPaneId = model.groups[0].tabs[0].focusedPaneId

        let effects = update(&model, .sidebarRenameEnded)
        try expect(hasEffect(effects) {
            if case .makeFirstResponder(let pid) = $0, pid == focusedPaneId {
                return true
            }
            return false
        }, "should emit makeFirstResponder for focused pane")
    }

    test("renameTab does not emit makeFirstResponder") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        let effects = update(&model, .renameTab(id: tabId, name: "New"))
        try expect(!hasEffect(effects) {
            if case .makeFirstResponder = $0 { return true }
            return false
        }, "renameTab should not restore focus (would steal from click-away)")
    }

    test("renameGroup does not emit makeFirstResponder") {
        var model = makeModel()
        createTab(&model)
        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id

        let effects = update(&model, .renameGroup(id: workId, name: "Projects"))
        try expect(!hasEffect(effects) {
            if case .makeFirstResponder = $0 { return true }
            return false
        }, "renameGroup should not restore focus (would steal from click-away)")
    }

    // MARK: - Snapshot

    test("testSnapshotCustomTitleOmitted") {
        // JSON without customTitle should decode to nil (backward compat)
        let json = """
        {
          "version": 2,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "rootNode": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "Terminal" } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model != nil, "should decode without customTitle")
        try expect(model!.groups[0].tabs[0].customTitle == nil, "customTitle should be nil when omitted")
        try expectEqual(model!.groups[0].tabs[0].displayTitle, "Terminal")
    }

    // MARK: - clearCustomTitles (batch from multi-select context menu)

    test("testClearCustomTitlesClearsAllSelected") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let id1 = model.groups[0].tabs[0].id
        let id2 = model.groups[0].tabs[1].id
        let id3 = model.groups[0].tabs[2].id
        update(&model, .renameTab(id: id1, name: "alpha"))
        update(&model, .renameTab(id: id2, name: "beta"))
        update(&model, .renameTab(id: id3, name: "gamma"))

        update(&model, .clearCustomTitles(tabIds: [id1, id2]))

        try expect(model.groups[0].tabs[0].customTitle == nil)
        try expect(model.groups[0].tabs[1].customTitle == nil)
        try expectEqual(model.groups[0].tabs[2].customTitle, "gamma",
            "tabs not in the batch are unaffected")
    }

    test("testClearCustomTitlesDedupesAndIgnoresStale") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let id1 = model.groups[0].tabs[0].id
        let id2 = model.groups[0].tabs[1].id
        let stale = TabId()
        update(&model, .renameTab(id: id1, name: "alpha"))
        update(&model, .renameTab(id: id2, name: "beta"))

        let effects = update(&model, .clearCustomTitles(
            tabIds: [id1, id1, stale, id2]))

        try expect(model.groups[0].tabs[0].customTitle == nil)
        try expect(model.groups[0].tabs[1].customTitle == nil)
        // Per-row sidebar updates now reconcile; the batch clear still persists.
        try expect(hasEffect(effects) {
            if case .scheduleCheckpoint = $0 { return true }
            return false
        }, "should persist the batch clear via scheduleCheckpoint")
    }

    test("testClearCustomTitlesAllStaleIsNoop") {
        var model = makeModel()
        createTab(&model)
        let snapshot = model.groups

        let effects = update(&model, .clearCustomTitles(
            tabIds: [TabId(), TabId()]))

        try expectEqual(model.groups, snapshot)
        try expectEqual(effects.count, 0)
    }

    test("testClearCustomTitlesEmitsSelectionSyncForSelectedTab") {
        // Spec parity with single-tab .renameTab: when the focused tab's
        // custom title is cleared, the toolbar/window-title needs to
        // resync via selectionSyncEffects.
        var model = makeModel()
        createTab(&model)
        let id = model.groups[0].tabs[0].id
        update(&model, .renameTab(id: id, name: "alpha"))
        try expectEqual(model.selectedTabId, id)

        let effects = update(&model, .clearCustomTitles(tabIds: [id]))

        try expect(model.groups[0].tabs[0].customTitle == nil)
        // Clearing the focused tab's title resyncs the window title via selectionSyncEffects
        // (the row itself reconciles via reconcileSidebar).
        try expect(hasEffect(effects) {
            if case .setWindowTitle = $0 { return true }
            return false
        }, "should emit setWindowTitle (selectionSync) for the selected tab")
    }
}
