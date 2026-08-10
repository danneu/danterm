// Swift Testing migration of the legacy `tests/UpdateThemeTests.swift`
// harness suite. Pins per-pane theme switching: setPaneTheme + clearing,
// split inheritance and projected config, on-disk round-trips (snapshot
// + export), resilient decoding of unknown theme names, and the
// scrollback-preserving theme propagation in mergeCheckpoints. The four
// `guard let restored = validateAndBuild(...) else { throw TestFailure }`
// unwraps convert to `try #require` (the snapshot-round-trip exists as a
// single nullable value); the one `guard case .exportState(...)` destructure
// uses `Issue.record + return` because the case has an associated value to
// bind.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct UpdateThemeTests {
    @Test("setPaneTheme updates model")
    func setPaneThemeUpdatesModel() throws {
        // Intent: setPaneTheme stores the theme on the pane.
        // Why it exists: pins the bare write.
        // Scenario: spec-first set.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .setPaneTheme(paneId: paneId, themeName: "Dracula"))
        #expect(model.pane(paneId)?.theme == "Dracula")
    }

    @Test("setPaneTheme projects theme")
    func setPaneThemeProjectsTheme() {
        // Intent: setPaneTheme drives the per-pane config projection.
        // Why it exists: pins the projection path.
        // Scenario: spec-first projection.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .setPaneTheme(paneId: paneId, themeName: "Nord"))
        #expect(desiredPaneConfig(in: model)[paneId]?.theme == "Nord")
    }

    @Test("clearPaneTheme sets theme to nil")
    func clearPaneThemeSetsThemeNil() {
        // Intent: setPaneTheme(nil) clears the pane's theme.
        // Why it exists: pins the explicit-clear branch.
        // Scenario: spec-first clear.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .setPaneTheme(paneId: paneId, themeName: "Dracula"))
        #expect(model.pane(paneId)?.theme == "Dracula")
        update(&model, .setPaneTheme(paneId: paneId, themeName: nil))
        #expect(model.pane(paneId)?.theme == nil, "theme should be nil after clearing")
    }

    @Test("splitPane inherits theme from parent")
    func splitPaneInheritsThemeFromParent() {
        // Intent: a splitPane creates a new pane that inherits the parent
        //   pane's theme.
        // Why it exists: pins theme propagation on split.
        // Scenario: spec-first split inherit.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .setPaneTheme(paneId: paneId, themeName: "Catppuccin Mocha"))
        update(&model, .splitPane(paneId: paneId, direction: .horizontal))
        let tab = selectedTab(in: model)!
        let newPaneId = tab.focusedPaneId
        #expect(newPaneId != paneId, "new pane should be different from parent")
        #expect(model.pane(newPaneId)?.theme == "Catppuccin Mocha")
    }

    @Test("splitPane with theme projects config for new pane")
    func splitPaneWithThemeProjectsConfigForNewPane() {
        // Intent: the new pane gets its own config projection key with
        //   the inherited theme.
        // Why it exists: pins the projection coverage after split.
        // Scenario: spec-first split projection.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .setPaneTheme(paneId: paneId, themeName: "Rose Pine"))
        update(&model, .splitPane(paneId: paneId, direction: .vertical))
        let tab = selectedTab(in: model)!
        let newPaneId = tab.focusedPaneId
        #expect(desiredPaneConfig(in: model)[newPaneId]?.theme == "Rose Pine")
    }

    @Test("splitPane without an override projects the configured defaults")
    func splitPaneWithoutThemeProjectsDefaults() {
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        let paneId = selectedTab(in: model)!.focusedPaneId
        #expect(desiredPaneConfig(in: model)[paneId] == PaneConfigKey(
            theme: "Monokai Remastered",
            fontSize: 13
        ))
    }

    @Test("toSnapshot preserves theme")
    func toSnapshotPreservesTheme() {
        // Intent: toSnapshot records the pane's theme.
        // Why it exists: pins the snapshot write.
        // Scenario: spec-first snapshot write.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .setPaneTheme(paneId: paneId, themeName: "Gruvbox Dark"))
        let snapshot = toSnapshot(model)
        let ps = paneSnapshot(paneId.rawValue.uuidString, in: snapshot)
        #expect(ps?.theme == "Gruvbox Dark")
    }

    @Test("snapshot round-trip preserves theme")
    func snapshotRoundTripPreservesTheme() throws {
        // Intent: validateAndBuild(toSnapshot(...)) preserves theme.
        // Why it exists: pins the full snapshot/restore round-trip.
        // Scenario: spec-first round-trip.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .setPaneTheme(paneId: paneId, themeName: "TokyoNight Night"))
        let snapshot = toSnapshot(model)
        let restored = try #require(validateAndBuild(snapshot), "snapshot round-trip failed")
        let restoredPane = restored.pane(paneId)
        #expect(restoredPane != nil, "pane should exist in restored model")
        #expect(restoredPane?.theme == "TokyoNight Night")
    }

    @Test("snapshot with unknown theme name decodes and preserves in model")
    func snapshotWithUnknownThemeNameDecodesAndPreserves() throws {
        // Intent: an unknown theme name decodes and survives
        //   validateAndBuild.
        // Why it exists: pins the resilient decode rule (forward-compat
        //   for future theme names the user might restore from).
        // Scenario: spec-first unknown-theme decode.
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "rootNode": { "type": "leaf", "pane": {
                  "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                  "title": "Terminal",
                  "theme": "NonExistent Theme"
                } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        #expect(allPaneSnapshots(initFile.model)[0].theme == "NonExistent Theme")
        let built = validateAndBuild(initFile.model)
        #expect(built != nil, "should rebuild despite unknown theme")
        let paneId = PaneId(rawValue: UUID(uuidString: "A13076E4-A29C-4358-A771-B4B4DF84C6C5")!)
        #expect(built!.pane(paneId)?.theme == "NonExistent Theme")
    }

    @Test("export preserves theme in snapshot")
    func exportPreservesThemeInSnapshot() {
        // Intent: .exportState emits an exportState command whose
        //   snapshot preserves the pane theme.
        // Why it exists: pins the export wire format.
        // Scenario: spec-first export theme.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .setPaneTheme(paneId: paneId, themeName: "Catppuccin Latte"))
        let commands = update(&model, .exportState)
        guard case .exportState(let snapshot) = commands.first else {
            Issue.record("expected exportState command")
            return
        }
        let ps = paneSnapshot(paneId.rawValue.uuidString, in: snapshot)
        #expect(ps?.theme == "Catppuccin Latte")
    }

    @Test("mergeCheckpoints preserves theme")
    func mergeCheckpointsPreservesTheme() {
        // Intent: mergeCheckpoints retains theme from light + scrollback
        //   from enriched.
        // Why it exists: pins the field-by-field merge contract.
        // Scenario: spec-first merge theme.
        let p1 = PaneId()
        let light = ValidatedAppRestore(
            snapshot: toSnapshot(makeModel()), model: makeModel(),
            paneSnapshots: [p1: PaneSnapshot(id: p1.rawValue.uuidString, title: "t", cwd: "/c", command: nil, scrollback: nil, theme: "Dracula")]
        )
        let enriched = ValidatedAppRestore(
            snapshot: toSnapshot(makeModel()), model: makeModel(),
            paneSnapshots: [p1: PaneSnapshot(id: p1.rawValue.uuidString, title: "t", cwd: "/c", command: nil, scrollback: "text", theme: "Dracula")]
        )
        let merged = mergeCheckpoints(light: light, enriched: enriched)
        #expect(merged.paneSnapshots[p1]?.theme == "Dracula")
        #expect(merged.paneSnapshots[p1]?.scrollback == "text")
    }

    @Test("theme name round-trips as arbitrary string")
    func themeNameRoundTripsAsArbitraryString() throws {
        // Intent: a custom theme name survives snapshot round-trip.
        // Why it exists: pins the no-enum-clamp rule on theme names.
        // Scenario: spec-first custom name round-trip.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .setPaneTheme(paneId: paneId, themeName: "My Custom Theme"))
        let snapshot = toSnapshot(model)
        let restored = try #require(validateAndBuild(snapshot), "snapshot round-trip failed")
        #expect(restored.pane(paneId)?.theme == "My Custom Theme")
    }

    @Test("unknown theme name preserved in snapshot round-trip")
    func unknownThemeNamePreservedInSnapshotRoundTrip() throws {
        // Intent: an unknown theme survives a full decode + rebuild +
        //   re-encode cycle.
        // Why it exists: pins forward-compatible theme persistence.
        // Scenario: spec-first unknown round-trip.
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "rootNode": { "type": "leaf", "pane": {
                  "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                  "title": "Terminal",
                  "theme": "NonExistent Theme"
                } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let built = validateAndBuild(initFile.model)
        #expect(built != nil, "should rebuild")
        let snapshot = toSnapshot(built!)
        #expect(allPaneSnapshots(snapshot)[0].theme == "NonExistent Theme")
    }

    @Test("nil theme round-trips through snapshot")
    func nilThemeRoundTripsThroughSnapshot() throws {
        // Intent: nil theme survives snapshot round-trip.
        // Why it exists: pins the explicit-nil round-trip.
        // Scenario: spec-first nil round-trip.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let snapshot = toSnapshot(model)
        let restored = try #require(validateAndBuild(snapshot), "snapshot round-trip failed")
        #expect(restored.pane(paneId)?.theme == nil, "nil theme should survive round-trip")
    }
}
