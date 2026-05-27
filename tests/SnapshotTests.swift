import Foundation

func snapshotTests() {
    print("Snapshot Tests...")

    // MARK: - Decode

    test("decode valid AppInitFile JSON") {
        let json = """
        {
          "version": 2,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "focusedPaneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                "rootNode": { "type": "leaf", "pane": {
                  "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                  "title": "Terminal",
                  "cwd": "~/world"
                } }
              }]
            }],
            "selectedTabId": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2"
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        try expectEqual(initFile.version, 2)
        try expectEqual(initFile.model.groups.count, 1)
        try expectEqual(allPaneSnapshots(initFile.model).count, 1)
        try expectEqual(initFile.model.selectedTabId, "89B4C232-C840-42A8-8CA6-C133C8EBBFF2")
    }

    test("decode failure on malformed JSON") {
        let json = "{ invalid json"
        let data = json.data(using: .utf8)!
        var decoded = false
        do {
            _ = try JSONDecoder().decode(AppInitFile.self, from: data)
            decoded = true
        } catch {}
        try expect(!decoded, "should fail to decode malformed JSON")
    }

    test("loadValidatedInitFile rejects malformed JSON") {
        let data = "{ invalid json".data(using: .utf8)!
        do {
            _ = try loadValidatedInitFile(from: data)
            throw TestFailure(message: "expected malformed JSON to fail")
        } catch let error as AppInitFileLoadError {
            try expectEqual(error, .decodeFailed)
        }
    }

    // The version guard flipped: v2 is the only accepted format; v1 (the old flat
    // panes array) and v3+ are rejected outright with no version-dispatch fork.
    test("loadValidatedInitFile accepts v2 and rejects v1 / v3") {
        // v2 round-trips through the loader.
        var model = makeModel()
        createTab(&model)
        let v2data = try JSONEncoder().encode(toInitFile(model))
        _ = try loadValidatedInitFile(from: v2data)

        // v1 (flat panes array) is rejected on version, not silently imported.
        let v1json = """
        {
          "version": 1,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "rootNode": { "type": "leaf", "paneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5" }
              }]
            }],
            "panes": [{ "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "Terminal" }]
          }
        }
        """
        do {
            _ = try loadValidatedInitFile(from: v1json.data(using: .utf8)!)
            throw TestFailure(message: "expected v1 to be rejected")
        } catch let error as AppInitFileLoadError {
            try expectEqual(error, .unsupportedVersion(1))
        }

        // v3 (a future format) is rejected too.
        let v3json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{ "rootNode": { "type": "leaf", "pane": { "title": "Terminal" } } }]
            }]
          }
        }
        """
        do {
            _ = try loadValidatedInitFile(from: v3json.data(using: .utf8)!)
            throw TestFailure(message: "expected v3 to be rejected")
        } catch let error as AppInitFileLoadError {
            try expectEqual(error, .unsupportedVersion(3))
        }
    }

    test("loadValidatedInitFile rejects invalid snapshot") {
        // A well-formed v2 file that still fails validation: no group/tab at all.
        let json = """
        {
          "version": 2,
          "model": { "groups": [] }
        }
        """
        let data = json.data(using: .utf8)!
        do {
            _ = try loadValidatedInitFile(from: data)
            throw TestFailure(message: "expected invalid snapshot to fail")
        } catch let error as AppInitFileLoadError {
            try expectEqual(error, .invalidSnapshot)
        }
    }

    test("loadValidatedInitFile returns validated restore") {
        var model = makeModel()
        createTab(&model)
        let data = try JSONEncoder().encode(toInitFile(model))
        let loaded = try loadValidatedInitFile(from: data)
        try expectEqual(loaded.snapshot.selectedTabId, model.selectedTabId?.rawValue.uuidString)
        try expectEqual(loaded.model.groups.count, model.groups.count)
        try expectEqual(loaded.model.allPaneIds.count, model.allPaneIds.count)
    }

    test("loadValidatedInitFile does not restore pending confirmation") {
        var model = makeModel()
        createTab(&model)
        model.pendingConfirmation = .terminate

        let data = try JSONEncoder().encode(toInitFile(model))
        let loaded = try loadValidatedInitFile(from: data)

        try expect(loaded.model.pendingConfirmation == nil,
            "pending confirmation is ephemeral and must not be serialized")
    }

    test("decode split node") {
        let json = """
        {
          "version": 2,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "focusedPaneId": "AAAA0000-0000-0000-0000-000000000001",
                "rootNode": {
                  "type": "split",
                  "id": "CCCC0000-0000-0000-0000-000000000001",
                  "direction": "horizontal",
                  "first": { "type": "leaf", "pane": { "id": "AAAA0000-0000-0000-0000-000000000001", "title": "left" } },
                  "second": { "type": "leaf", "pane": { "id": "AAAA0000-0000-0000-0000-000000000002", "title": "right" } },
                  "ratio": 0.6
                }
              }]
            }],
            "selectedTabId": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2"
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model != nil, "should validate split tree")
        try expectEqual(model!.allPaneIds.count, 2)
        let tab = model!.groups[0].tabs[0]
        try expectEqual(allPaneIds(tab.rootNode).count, 2)
    }

    // MARK: - Validation
    //
    // The orphan-pane and missing-pane-reference checks are gone: with the pane
    // embedded in its leaf, a pane exists iff a leaf owns it, so both are
    // structurally impossible. Leaf-id uniqueness (a pane id on two leaves) is
    // the lone surviving duplicate check; it subsumes the old within-tab and
    // cross-tree duplicate checks.

    test("validation rejects pane id shared across two tab leaves") {
        let json = """
        {
          "version": 2,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [
                {
                  "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                  "rootNode": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "shared" } }
                },
                {
                  "id": "DDDDDDDD-0000-0000-0000-000000000001",
                  "rootNode": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "shared" } }
                }
              ]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model == nil, "should reject the same pane id appearing on two leaves")
    }

    test("validation rejects duplicate pane ID within one tab tree") {
        let json = """
        {
          "version": 2,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "focusedPaneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                "rootNode": {
                  "type": "split",
                  "id": "CCCC0000-0000-0000-0000-000000000001",
                  "direction": "horizontal",
                  "first": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "a" } },
                  "second": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "b" } }
                }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model == nil, "should reject duplicate pane id within a tab tree")
    }

    test("validation rejects pane ID colliding with group ID") {
        let json = """
        {
          "version": 2,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "rootNode": { "type": "leaf", "pane": { "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A", "title": "collision" } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model == nil, "should reject pane id collisions with other id domains")
    }

    test("validation normalizes missing selectedTabId to first tab") {
        let json = """
        {
          "version": 2,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "rootNode": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "T" } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model != nil, "should succeed")
        try expectEqual(model!.selectedTabId, TabId(rawValue: UUID(uuidString: "89B4C232-C840-42A8-8CA6-C133C8EBBFF2")!))
    }

    test("validation normalizes invalid selectedTabId to first tab") {
        let json = """
        {
          "version": 2,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "rootNode": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "T" } }
              }]
            }],
            "selectedTabId": "00000000-0000-0000-0000-000000000000"
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model != nil, "should succeed")
        try expectEqual(model!.selectedTabId, TabId(rawValue: UUID(uuidString: "89B4C232-C840-42A8-8CA6-C133C8EBBFF2")!))
    }

    test("validation supports omitted IDs and focusedPaneId") {
        let json = """
        {
          "version": 2,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "rootNode": { "type": "leaf" }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model != nil, "should succeed")
        let built = model!
        let firstTab = built.groups[0].tabs[0]
        try expectEqual(built.selectedTabId, firstTab.id, "selected tab should default to first group's first tab")
        let firstPane = firstLeafId(firstTab.rootNode)
        try expectEqual(firstTab.focusedPaneId, firstPane, "focused pane should default to first pane in first tab")
        try expect(built.pane(firstPane) != nil, "synthesized pane id should exist as a tree leaf")
    }

    // MARK: - Reconstruction invariants

    test("reconstructed model preserves all UUIDs") {
        let json = """
        {
          "version": 2,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "focusedPaneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                "rootNode": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "T" } }
              }]
            }],
            "selectedTabId": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2"
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)!

        try expectEqual(model.groups[0].id, GroupId(rawValue: UUID(uuidString: "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A")!))
        try expectEqual(model.groups[0].tabs[0].id, TabId(rawValue: UUID(uuidString: "89B4C232-C840-42A8-8CA6-C133C8EBBFF2")!))
        try expect(model.pane(PaneId(rawValue: UUID(uuidString: "A13076E4-A29C-4358-A771-B4B4DF84C6C5")!)) != nil)
        try expectEqual(model.selectedTabId, TabId(rawValue: UUID(uuidString: "89B4C232-C840-42A8-8CA6-C133C8EBBFF2")!))
    }

    test("launch.cwd wins over cwd for surface creation") {
        let ps = PaneSnapshot(id: "AAAA0000-0000-0000-0000-000000000001", title: "T", cwd: "~/fallback", launch: PaneLaunchSnapshot(command: nil, cwd: "~/override"), scrollback: nil, theme: nil)
        let (cwd, _) = resolveLaunch(ps)
        let home = NSHomeDirectory()
        try expectEqual(cwd, home + "/override")
    }

    test("pane without launch uses expanded cwd") {
        let ps = PaneSnapshot(id: "AAAA0000-0000-0000-0000-000000000001", title: "T", cwd: "~/mydir", launch: nil, scrollback: nil, theme: nil)
        let (cwd, command) = resolveLaunch(ps)
        let home = NSHomeDirectory()
        try expectEqual(cwd, home + "/mydir")
        try expect(command == nil)
    }

    test("pane with launch.command passes command") {
        let ps = PaneSnapshot(id: "AAAA0000-0000-0000-0000-000000000001", title: "T", cwd: nil, launch: PaneLaunchSnapshot(command: "lazygit", cwd: nil), scrollback: nil, theme: nil)
        let (_, command) = resolveLaunch(ps)
        try expectEqual(command, "lazygit")
    }

    // MARK: - Scrollback Backward Compatibility

    test("decode JSON without scrollback field yields nil scrollback") {
        let json = """
        {
          "version": 2,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "rootNode": { "type": "leaf", "pane": {
                  "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                  "title": "Terminal"
                } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        try expect(allPaneSnapshots(initFile.model)[0].scrollback == nil, "scrollback should be nil when absent from JSON")
    }

    test("decode JSON with scrollback field preserves value") {
        let json = """
        {
          "version": 2,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "rootNode": { "type": "leaf", "pane": {
                  "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                  "title": "Terminal",
                  "scrollback": "$ echo hello\\nhello\\n$ "
                } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        try expectEqual(allPaneSnapshots(initFile.model)[0].scrollback, "$ echo hello\nhello\n$ ")
    }

    test("round-trip encode/decode preserves scrollback") {
        let ps = PaneSnapshot(id: "AAAA0000-0000-0000-0000-000000000001", title: "T", cwd: nil, launch: nil, scrollback: "line1\nline2\n", theme: nil)
        let data = try JSONEncoder().encode(ps)
        let decoded = try JSONDecoder().decode(PaneSnapshot.self, from: data)
        try expectEqual(decoded.scrollback, "line1\nline2\n")
    }

    test("round-trip encode/decode preserves nil scrollback") {
        let ps = PaneSnapshot(id: "AAAA0000-0000-0000-0000-000000000001", title: "T", cwd: nil, launch: nil, scrollback: nil, theme: nil)
        let data = try JSONEncoder().encode(ps)
        let decoded = try JSONDecoder().decode(PaneSnapshot.self, from: data)
        try expect(decoded.scrollback == nil, "nil scrollback should survive round-trip")
    }

    test("expandTilde expands home directory") {
        let home = NSHomeDirectory()
        try expectEqual(expandTilde("~/foo"), home + "/foo")
        try expectEqual(expandTilde("/absolute"), "/absolute")
        try expectEqual(expandTilde("~"), home)
    }

    // MARK: - Tab Color Snapshot

    test("testSnapshotPreservesTabColor") {
        var model = makeModel()
        createTab(&model)
        update(&model, .setTabColors(tabIds: [model.groups[0].tabs[0].id], color: .purple))

        let snapshot = toSnapshot(model)
        let rebuilt = validateAndBuild(snapshot)
        try expect(rebuilt != nil, "should rebuild from snapshot")
        try expectEqual(rebuilt!.groups[0].tabs[0].color, .purple)
    }

    test("testSnapshotNilColorPreserved") {
        var model = makeModel()
        createTab(&model)
        // No color set — should remain nil through round-trip

        let snapshot = toSnapshot(model)
        let rebuilt = validateAndBuild(snapshot)
        try expect(rebuilt != nil, "should rebuild from snapshot")
        try expect(rebuilt!.groups[0].tabs[0].color == nil, "color should remain nil")
    }

    test("snapshot round-trip drops open preferences draft") {
        var model = makeModel()
        createTab(&model)
        update(&model, .preferencesOpened(ghostty: GhosttyPrefs(theme: "Dracula", fontSize: "14")))
        update(&model, .prefSetTheme("Solarized"))
        try expect(model.preferencesDraft != nil, "draft should exist before snapshot")
        try expect(model.committedGhosttyPrefs != nil, "ghostty prefs should exist before snapshot")

        let snapshot = toSnapshot(model)
        let rebuilt = validateAndBuild(snapshot)

        try expect(rebuilt != nil, "should rebuild from snapshot")
        try expect(rebuilt!.preferencesDraft == nil, "draft should not be serialized")
        try expect(rebuilt!.committedGhosttyPrefs == nil, "ghostty prefs should not be serialized")
    }

    test("validation rejects duplicate IDs across domains") {
        // Use same UUID for group and tab
        let json = """
        {
          "version": 2,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
                "rootNode": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "T" } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model == nil, "should reject duplicate IDs across domains")
    }

    // MARK: - TODO Snapshot

    test("snapshot round-trip preserves todos") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "task one"))
        update(&model, .addTodo(paneId: paneId, text: "task two"))
        let todoId = model.pane(paneId)!.todos[0].id
        update(&model, .toggleTodoDone(paneId: paneId, todoId: todoId))

        let snapshot = toSnapshot(model)
        let rebuilt = validateAndBuild(snapshot)
        try expect(rebuilt != nil, "should rebuild from snapshot with todos")
        let todos = rebuilt!.pane(paneId)!.todos
        try expectEqual(todos.count, 2)
        try expectEqual(todos[0].text, "task one")
        try expectEqual(todos[0].isDone, true)
        try expectEqual(todos[1].text, "task two")
        try expectEqual(todos[1].isDone, false)
    }

    test("snapshot round-trip preserves tab todos") {
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        update(&model, .addTabTodo(tabId: tabId, text: "tab one"))
        update(&model, .addTabTodo(tabId: tabId, text: "tab two"))
        let id1 = tabById(tabId, in: model)!.todos[0].id
        update(&model, .toggleTabTodoDone(tabId: tabId, todoId: id1))

        let snapshot = toSnapshot(model)
        let rebuilt = validateAndBuild(snapshot)
        try expect(rebuilt != nil, "should rebuild from snapshot with tab todos")
        let todos = tabById(tabId, in: rebuilt!)!.todos
        try expectEqual(todos.count, 2)
        try expectEqual(todos[0].text, "tab one")
        try expectEqual(todos[0].isDone, true)
        try expectEqual(todos[1].text, "tab two")
        try expectEqual(todos[1].isDone, false)
    }

    test("toSnapshot emits nil for empty tab todos") {
        var model = makeModel()
        createTab(&model)
        let snapshot = toSnapshot(model)
        let tabSnap = snapshot.groups[0].tabs[0]
        try expect(tabSnap.todos == nil, "empty tab todos should encode as nil")
    }

    test("snapshot without tab todos field decodes with empty list") {
        let json = """
        {
          "version": 2,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "rootNode": { "type": "leaf", "pane": {
                  "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                  "title": "Terminal",
                  "cwd": "~/world"
                } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model != nil, "should rebuild snapshot without tab todos field")
        let tabs = model!.groups.flatMap(\.tabs)
        try expectEqual(tabs[0].todos.count, 0, "tab todos should default to empty")
    }

    test("snapshot without todos field decodes with empty array") {
        let json = """
        {
          "version": 2,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "rootNode": { "type": "leaf", "pane": {
                  "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                  "title": "Terminal",
                  "cwd": "~/world"
                } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model != nil, "should rebuild snapshot without todos field")
        let panes = Array(model!.allPanes)
        try expectEqual(panes[0].todos.count, 0, "todos should default to empty")
    }
}
