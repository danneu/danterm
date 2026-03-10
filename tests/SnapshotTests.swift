import Foundation

func snapshotTests() {
    print("Snapshot Tests...")

    // MARK: - Decode

    test("decode valid AppInitFile JSON") {
        let json = """
        {
          "version": 1,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "focusedPaneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                "rootNode": { "type": "leaf", "paneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5" }
              }]
            }],
            "panes": [{
              "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
              "title": "Terminal",
              "cwd": "~/world"
            }],
            "selectedTabId": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2"
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        try expectEqual(initFile.version, 1)
        try expectEqual(initFile.model.groups.count, 1)
        try expectEqual(initFile.model.panes.count, 1)
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

    test("decode split node") {
        let json = """
        {
          "version": 1,
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
                  "first": { "type": "leaf", "paneId": "AAAA0000-0000-0000-0000-000000000001" },
                  "second": { "type": "leaf", "paneId": "AAAA0000-0000-0000-0000-000000000002" },
                  "ratio": 0.6
                }
              }]
            }],
            "panes": [
              { "id": "AAAA0000-0000-0000-0000-000000000001", "title": "left" },
              { "id": "AAAA0000-0000-0000-0000-000000000002", "title": "right" }
            ],
            "selectedTabId": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2"
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model != nil, "should validate split tree")
        try expectEqual(model!.panes.count, 2)
        let tab = model!.groups[0].tabs[0]
        try expectEqual(allPaneIds(tab.rootNode).count, 2)
    }

    // MARK: - Validation

    test("validation rejects missing pane references") {
        let json = """
        {
          "version": 1,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "rootNode": { "type": "leaf", "paneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5" }
              }]
            }],
            "panes": [],
            "selectedTabId": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2"
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model == nil, "should reject missing pane reference")
    }

    test("validation rejects orphan panes") {
        let json = """
        {
          "version": 1,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "rootNode": { "type": "leaf", "paneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5" }
              }]
            }],
            "panes": [
              { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "used" },
              { "id": "BBBBBBBB-0000-0000-0000-000000000000", "title": "orphan" }
            ],
            "selectedTabId": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2"
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model == nil, "should reject orphan panes")
    }

    test("validation rejects pane in two tab trees") {
        let json = """
        {
          "version": 1,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [
                {
                  "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                  "rootNode": { "type": "leaf", "paneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5" }
                },
                {
                  "id": "DDDDDDDD-0000-0000-0000-000000000001",
                  "rootNode": { "type": "leaf", "paneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5" }
                }
              ]
            }],
            "panes": [
              { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "shared" }
            ]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model == nil, "should reject pane shared across tabs")
    }

    test("validation rejects duplicate pane ID within one tab tree") {
        let json = """
        {
          "version": 1,
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
                  "first": { "type": "leaf", "paneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5" },
                  "second": { "type": "leaf", "paneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5" }
                }
              }]
            }],
            "panes": [
              { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "shared" }
            ]
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
          "version": 1,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "rootNode": { "type": "leaf", "paneId": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A" }
              }]
            }],
            "panes": [
              { "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A", "title": "collision" }
            ]
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
          "version": 1,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "rootNode": { "type": "leaf", "paneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5" }
              }]
            }],
            "panes": [
              { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "T" }
            ]
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
          "version": 1,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "rootNode": { "type": "leaf", "paneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5" }
              }]
            }],
            "panes": [
              { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "T" }
            ],
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

    test("validation always makes first group default") {
        let json = """
        {
          "version": 1,
          "model": {
            "groups": [
              {
                "id": "AAAA0000-0000-0000-0000-000000000001",
                "name": "First",
                "isDefault": false,
                "tabs": [{
                  "id": "BBBB0000-0000-0000-0000-000000000001",
                  "rootNode": { "type": "leaf", "paneId": "CCCC0000-0000-0000-0000-000000000001" }
                }]
              },
              {
                "id": "AAAA0000-0000-0000-0000-000000000002",
                "name": "Second",
                "isDefault": true,
                "tabs": [{
                  "id": "BBBB0000-0000-0000-0000-000000000002",
                  "rootNode": { "type": "leaf", "paneId": "CCCC0000-0000-0000-0000-000000000002" }
                }]
              }
            ],
            "panes": [
              { "id": "CCCC0000-0000-0000-0000-000000000001", "title": "T" },
              { "id": "CCCC0000-0000-0000-0000-000000000002", "title": "T" }
            ]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model != nil, "should succeed")
        try expect(model!.groups[0].isDefault, "first group should be default")
        try expectEqual(model!.groups[0].name, "First")
        try expectEqual(model!.groups[1].isDefault, false, "all non-first groups should be non-default")
    }

    test("validation supports omitted IDs and focusedPaneId") {
        let json = """
        {
          "version": 1,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "rootNode": { "type": "leaf" }
              }]
            }],
            "panes": [
              { "title": "Terminal", "cwd": "~/world" }
            ]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model != nil, "should succeed")
        let built = model!
        try expect(built.groups[0].isDefault, "first group should be default")
        let firstTab = built.groups[0].tabs[0]
        try expectEqual(built.selectedTabId, firstTab.id, "selected tab should default to first group's first tab")
        let firstPane = firstLeafId(firstTab.rootNode)
        try expectEqual(firstTab.focusedPaneId, firstPane, "focused pane should default to first pane in first tab")
        try expect(built.panes[firstPane] != nil, "synthesized pane id should exist in pane dictionary")
    }

    // MARK: - Reconstruction invariants

    test("reconstructed model preserves all UUIDs") {
        let json = """
        {
          "version": 1,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "focusedPaneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                "rootNode": { "type": "leaf", "paneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5" }
              }]
            }],
            "panes": [{ "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "T" }],
            "selectedTabId": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2"
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)!

        try expectEqual(model.groups[0].id, GroupId(rawValue: UUID(uuidString: "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A")!))
        try expectEqual(model.groups[0].tabs[0].id, TabId(rawValue: UUID(uuidString: "89B4C232-C840-42A8-8CA6-C133C8EBBFF2")!))
        try expect(model.panes[PaneId(rawValue: UUID(uuidString: "A13076E4-A29C-4358-A771-B4B4DF84C6C5")!)] != nil)
        try expectEqual(model.selectedTabId, TabId(rawValue: UUID(uuidString: "89B4C232-C840-42A8-8CA6-C133C8EBBFF2")!))
    }

    test("launch.cwd wins over cwd for surface creation") {
        let ps = PaneSnapshot(id: "AAAA0000-0000-0000-0000-000000000001", title: "T", cwd: "~/fallback", launch: PaneLaunchSnapshot(command: nil, cwd: "~/override"))
        let (cwd, _) = resolveLaunch(ps)
        let home = NSHomeDirectory()
        try expectEqual(cwd, home + "/override")
    }

    test("pane without launch uses expanded cwd") {
        let ps = PaneSnapshot(id: "AAAA0000-0000-0000-0000-000000000001", title: "T", cwd: "~/mydir", launch: nil)
        let (cwd, command) = resolveLaunch(ps)
        let home = NSHomeDirectory()
        try expectEqual(cwd, home + "/mydir")
        try expect(command == nil)
    }

    test("pane with launch.command passes command") {
        let ps = PaneSnapshot(id: "AAAA0000-0000-0000-0000-000000000001", title: "T", cwd: nil, launch: PaneLaunchSnapshot(command: "lazygit", cwd: nil))
        let (_, command) = resolveLaunch(ps)
        try expectEqual(command, "lazygit")
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
        update(&model, .setTabColor(tabId: model.groups[0].tabs[0].id, color: .purple))

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

    test("validation rejects duplicate IDs across domains") {
        // Use same UUID for group and tab
        let json = """
        {
          "version": 1,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
                "rootNode": { "type": "leaf", "paneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5" }
              }]
            }],
            "panes": [
              { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "T" }
            ]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        try expect(model == nil, "should reject duplicate IDs across domains")
    }
}
