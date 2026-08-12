// Swift Testing migration of the legacy `tests/CustomTitleTests.swift`
// harness suite. Pins the tab custom title behavior end to end:
// displayTitle precedence (custom > session), renameTab (set / clear /
// trim / empty-clear / non-selected scope), session title reports + pane-focus
// non-override, windowChrome + close-confirm using displayTitle,
// snapshot round-trip (preserve customTitle, derive title/subtitle
// from the focused session on import including legacy fields), the
// renameCompletionMessages dispatcher (Enter vs Esc, group skip),
// sidebarRenameEnded restoring focus, and the clearCustomTitles batch
// (dedup, stale-filter, no-op on all-stale, reverts displayTitle).
// The seven `return try expect(false, "msg")` patterns inside
// completion-message destructures convert to `Issue.record + return`
// to preserve the failure-site count.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct CustomTitleTests {
    // MARK: - Model

    @Test("testDisplayTitlePrefersCustom")
    func testDisplayTitlePrefersCustom() {
        // Intent: displayTitle prefers customTitle over the focused session title.
        // Why it exists: pins the precedence rule.
        // Scenario: spec-first custom-wins.
        var model = makeModel()
        createTab(&model)
        model.groups[0].tabs[0].customTitle = "My App"
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.updatePane(paneId) { $0.session?.title = "vim" }
        #expect(tabDisplayTitle(model.groups[0].tabs[0]) == "My App")
    }

    @Test("testDisplayTitleFallback")
    func testDisplayTitleFallback() {
        // Intent: displayTitle falls back to the focused session title when there's
        //   no customTitle.
        // Why it exists: pins the fallback rule.
        // Scenario: spec-first fallback.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.updatePane(paneId) { $0.session?.title = "vim" }
        #expect(model.groups[0].tabs[0].customTitle == nil)
        #expect(tabDisplayTitle(model.groups[0].tabs[0]) == "vim")
    }

    // MARK: - renameTab

    @Test("testRenameTab")
    func testRenameTab() {
        // Intent: renameTab writes customTitle.
        // Why it exists: pins the bare rename path.
        // Scenario: spec-first rename.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        update(&model, .renameTab(id: tabId, name: "My App"))
        #expect(model.groups[0].tabs[0].customTitle == "My App")
    }

    @Test("testRenameTabClear")
    func testRenameTabClear() {
        // Intent: renameTab with nil clears customTitle.
        // Why it exists: pins the explicit clear branch.
        // Scenario: spec-first clear rename.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .renameTab(id: tabId, name: "Custom"))
        #expect(model.groups[0].tabs[0].customTitle == "Custom")

        update(&model, .renameTab(id: tabId, name: nil))
        #expect(model.groups[0].tabs[0].customTitle == nil, "customTitle should be nil")
    }

    @Test("testRenameTabEmptyStringClearsTitle")
    func testRenameTabEmptyStringClearsTitle() {
        // Intent: a whitespace-only name clears customTitle (treated as
        //   empty).
        // Why it exists: pins the trim-then-empty rule.
        // Scenario: spec-first whitespace clear.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .renameTab(id: tabId, name: "Custom"))

        update(&model, .renameTab(id: tabId, name: "   "))
        #expect(model.groups[0].tabs[0].customTitle == nil, "whitespace-only name should clear customTitle")
    }

    @Test("testRenameTabTrimsWhitespace")
    func testRenameTabTrimsWhitespace() {
        // Intent: leading/trailing whitespace is trimmed.
        // Why it exists: pins the trim rule.
        // Scenario: spec-first trim.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        update(&model, .renameTab(id: tabId, name: "  My App  "))
        #expect(model.groups[0].tabs[0].customTitle == "My App")
    }

    @Test("testRenameTabNonSelectedUpdatesOnlyThatTabsCustomTitle")
    func testRenameTabNonSelectedUpdatesOnlyThatTabsCustomTitle() {
        // Intent: renaming a non-selected tab updates only that tab; the
        //   selected tab's displayTitle is untouched.
        // Why it exists: pins the per-tab scope.
        // Scenario: spec-first background rename.
        var model = makeModel()
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        createTab(&model)

        update(&model, .renameTab(id: tabAId, name: "Custom"))
        #expect(model.groups[0].tabs[0].customTitle == "Custom")
        #expect(tabDisplayTitle(model.groups[0].tabs[1]) == "Terminal",
            "selected tab B's display title is unchanged by renaming background tab A")
    }

    // MARK: - Session title reports do not override custom title

    @Test("testSessionTitleDoesNotOverrideCustom")
    func testSessionTitleDoesNotOverrideCustom() {
        // Intent: a title report updates the underlying session title but
        //   customTitle (and displayTitle) survives.
        // Why it exists: pins the survive-on-session-title rule.
        // Scenario: spec-first survive.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .renameTab(id: tabId, name: "My App"))

        update(&model, .sessionReport(sessionId: sessionId(for: paneId, in: model), report: .title("vim")))
        #expect(model.groups[0].tabs[0].customTitle == "My App", "customTitle should persist")
        #expect(tabDisplayTitle(model.groups[0].tabs[0]) == "My App", "displayTitle should use customTitle")
    }

    @Test("testPaneFocusDoesNotOverrideCustom")
    func testPaneFocusDoesNotOverrideCustom() {
        // Intent: focus changes update tab.title but customTitle wins
        //   displayTitle.
        // Why it exists: pins the focus-change carveout for custom
        //   titles.
        // Scenario: spec-first focus-change carveout.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .renameTab(id: tabId, name: "My App"))

        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneA = allPaneIds(model.groups[0].tabs[0].rootNode).first!
        model.updatePane(paneA) { $0.session?.title = "zsh" }
        update(&model, .paneBecameFirstResponder(paneId: paneA))
        #expect(model.groups[0].tabs[0].customTitle == "My App")
        #expect(tabDisplayTitle(model.groups[0].tabs[0]) == "My App")
    }

    // MARK: - windowTitle uses displayTitle

    @Test("testWindowChromeUsesDisplayTitle")
    func testWindowChromeUsesDisplayTitle() {
        // Intent: window chrome contentTitle/windowTitle use the
        //   custom-title displayTitle, not the session title.
        // Why it exists: pins the chrome-from-displayTitle rule.
        // Scenario: spec-first chrome display.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .renameTab(id: tabId, name: "Custom"))

        update(&model, .sessionReport(sessionId: sessionId(for: paneId, in: model), report: .title("vim")))
        let chrome = desiredWindowChrome(in: model)
        #expect(chrome.contentTitle == "Custom", "content title uses the custom display title")
        #expect(chrome.windowTitle.contains("Custom"),
            "window title contains the custom display title, got: \(chrome.windowTitle)")
    }

    @Test("testCloseConfirmUsesDisplayTitle")
    func testCloseConfirmUsesDisplayTitle() {
        // Intent: showCloseTabConfirmation carries the displayTitle of
        //   the closing tab (custom-title wins).
        // Why it exists: pins the per-tab display in close
        //   confirmations.
        // Scenario: spec-first close confirm.
        var model = makeModel()
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        update(&model, .renameTab(id: tabAId, name: "My Server"))

        createTab(&model)

        update(&model, .selectTab(id: tabAId))
        update(&model, .splitFocusedPane(direction: .horizontal))

        let commands = update(&model, .requestCloseTab(id: tabAId))
        let confirmEffect = commands.first(where: {
            if case .showCloseTabConfirmation = $0 { return true }
            return false
        })
        #expect(confirmEffect != nil, "should show confirmation")
        if case .showCloseTabConfirmation(_, let tabTitle, _, _, _) = confirmEffect! {
            #expect(tabTitle == "My Server", "confirmation should use displayTitle")
        }
    }

    // MARK: - Snapshot

    @Test("testToSnapshotPreservesCustomTitle")
    func testToSnapshotPreservesCustomTitle() {
        // Intent: toSnapshot records the tab's customTitle.
        // Why it exists: pins the snapshot write.
        // Scenario: spec-first snapshot write.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .renameTab(id: tabId, name: "My Server"))

        let snapshot = toSnapshot(model)
        #expect(snapshot.groups[0].tabs[0].customTitle == "My Server")
    }

    @Test("testToSnapshotCustomTitleRoundTrip")
    func testToSnapshotCustomTitleRoundTrip() throws {
        // Intent: encode -> decode -> validateAndBuild preserves
        //   customTitle and the derived displayTitle.
        // Why it exists: pins the full snapshot round-trip.
        // Scenario: spec-first round-trip.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .renameTab(id: tabId, name: "My Server"))

        let snapshot = toSnapshot(model)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(AppInitFile(version: 1, model: snapshot))
        let decoded = try JSONDecoder().decode(AppInitFile.self, from: data)
        let rebuilt = validateAndBuild(decoded.model)

        #expect(rebuilt != nil, "round-trip should produce valid model")
        #expect(rebuilt!.groups[0].tabs[0].customTitle == "My Server")
        #expect(tabDisplayTitle(rebuilt!.groups[0].tabs[0]) == "My Server")
    }

    // MARK: - Tab chrome derivation from snapshot

    @Test("testImportDerivesTitleFromFocusedPane")
    func testImportDerivesTitleFromFocusedPane() throws {
        // Intent: on import, the tab title derives from the focused
        //   pane's title (with $HOME abbreviation).
        // Why it exists: pins the import title derivation.
        // Scenario: spec-first import title.
        let home = NSHomeDirectory()
        let json = """
        {
          "version": 3,
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
        #expect(model != nil, "should build model")
        #expect(tabTitle(model!.groups[0].tabs[0]) == "~/world")
    }

    @Test("testImportDerivesSubtitleFromLaunchCwd")
    func testImportDerivesSubtitleFromLaunchCwd() throws {
        // Intent: on import, the tab subtitle derives from the focused session cwd.
        // Why it exists: pins the session cwd source for subtitle.
        // Scenario: spec-first session cwd subtitle.
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "focusedPaneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                "rootNode": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "T", "cwd": "~/projects" } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        #expect(model != nil, "should build model")
        #expect(tabSubtitle(model!.groups[0].tabs[0]) == "~/projects")
    }

    @Test("testImportNilCwdDerivesNilSubtitle")
    func testImportNilCwdDerivesNilSubtitle() throws {
        // Intent: a pane without cwd produces nil subtitle.
        // Why it exists: pins the nil-cwd branch.
        // Scenario: spec-first nil subtitle.
        let json = """
        {
          "version": 3,
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
        #expect(model != nil, "should build model")
        #expect(tabSubtitle(model!.groups[0].tabs[0]) == nil, "subtitle should be nil when pane has no cwd")
    }

    @Test("testLegacySnapshotWithTitleSubtitleDecodesSuccessfully")
    func testLegacySnapshotWithTitleSubtitleDecodesSuccessfully() throws {
        // Intent: v3 snapshots that include tab-level title +
        //   subtitle decode (the fields are ignored; title/subtitle
        //   derive from pane).
        // Why it exists: pins backward compat for old snapshots.
        // Scenario: spec-first legacy snapshot.
        let json = """
        {
          "version": 3,
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
        #expect(model != nil, "legacy snapshot with title/subtitle should still decode")
        #expect(tabTitle(model!.groups[0].tabs[0]) == "Terminal")
        #expect(tabSubtitle(model!.groups[0].tabs[0]) == "~/world")
    }

    @Test("testDeriveTabChromeMatchesRuntimeBehavior")
    func testDeriveTabChromeMatchesRuntimeBehavior() {
        // Intent: deriveTabChrome on the focused pane produces values
        //   that match the runtime-derived tab.title/subtitle.
        // Why it exists: pins the deriveTabChrome helper against the
        //   runtime path.
        // Scenario: spec-first chrome derivation match.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let home = NSHomeDirectory()

        model.updatePane(paneId) { $0.session?.title = "\(home)/world" }
        model.updatePane(paneId) { $0.session?.cwd = "\(home)/projects" }
        update(&model, .splitFocusedPane(direction: .horizontal))
        update(&model, .paneBecameFirstResponder(paneId: paneId))

        let tab = model.groups[0].tabs[0]
        let chrome = tabChrome(tab)

        #expect(tabTitle(tab) == chrome.title)
        #expect(tabSubtitle(tab) == chrome.subtitle)
        #expect(tabTitle(tab) == "~/world")
        #expect(tabSubtitle(tab) == "~/projects")
    }

    @Test("a tab's chrome comes from its own tree, never from another tab's pane")
    func testTabChromeIsTabLocal() {
        // Intent: a tab whose focus names a pane it does not own reports the
        //   neutral fallback, not the chrome of whichever tab holds that pane.
        // Why it exists: the chrome helpers used to resolve the focused pane by
        //   scanning every group and tab in the model, so a tab left pointing at
        //   a pane that had moved away silently titled itself from a stranger.
        //   Scanning the window was also quadratic in the sidebar projection.
        // Scenario: spec-first. Two tabs; the first is left naming the second's
        //   pane, which is the shape a moved pane leaves behind mid-update.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let strangerPaneId = model.groups[0].tabs[1].focusedPaneId
        model.updatePane(strangerPaneId) { $0.session?.title = "stranger" }
        model.groups[0].tabs[0].focusedPaneId = strangerPaneId

        let tab = model.groups[0].tabs[0]

        #expect(tabTitle(tab) == "Terminal", "chrome must not resolve outside the tab's own tree")
        #expect(tabSubtitle(tab) == nil)
        #expect(tabChipKind(tab) == .terminal)
    }

    // MARK: - renameCompletionMessages

    @Test("renameCompletion: Enter with change dispatches rename then focus")
    func renameCompletionEnterWithChangeDispatchesRenameThenFocus() {
        // Intent: Enter on a changed value dispatches renameTab + then
        //   sidebarRenameEnded.
        // Why it exists: pins the dispatch sequence on commit.
        // Scenario: spec-first enter commit.
        let tabId = TabId()
        let msgs = renameCompletionMessages(
            isConfirm: true, target: .tab(tabId), newName: "New Name")
        #expect(msgs.count == 2)
        guard case .renameTab(let id, let name) = msgs[0] else {
            Issue.record("expected renameTab")
            return
        }
        #expect(id == tabId)
        #expect(name == "New Name")
        guard case .sidebarRenameEnded = msgs[1] else {
            Issue.record("expected sidebarRenameEnded")
            return
        }
    }

    @Test("renameCompletion: Enter with unchanged text still dispatches rename")
    func renameCompletionEnterUnchangedStillDispatchesRename() {
        // Intent: Enter on an unchanged value still dispatches both
        //   messages.
        // Why it exists: pins the no-diff-skip rule.
        // Scenario: spec-first unchanged-still-fires.
        let tabId = TabId()
        let msgs = renameCompletionMessages(
            isConfirm: true, target: .tab(tabId), newName: "zsh")
        #expect(msgs.count == 2)
        guard case .renameTab = msgs[0] else {
            Issue.record("expected renameTab")
            return
        }
        guard case .sidebarRenameEnded = msgs[1] else {
            Issue.record("expected sidebarRenameEnded")
            return
        }
    }

    @Test("renameCompletion: Enter with empty tab name clears title")
    func renameCompletionEnterEmptyTabNameClearsTitle() {
        // Intent: Enter on an empty name clears the custom title (nil
        //   newName).
        // Why it exists: pins the empty-name-clears rule.
        // Scenario: spec-first empty-clear.
        let tabId = TabId()
        let msgs = renameCompletionMessages(
            isConfirm: true, target: .tab(tabId), newName: "")
        #expect(msgs.count == 2)
        guard case .renameTab(_, let name) = msgs[0] else {
            Issue.record("expected renameTab")
            return
        }
        #expect(name == nil, "empty name should clear custom title")
    }

    @Test("renameCompletion: Enter with empty group name skips rename")
    func renameCompletionEnterEmptyGroupNameSkipsRename() {
        // Intent: Enter on an empty group name skips renameGroup and
        //   just emits sidebarRenameEnded.
        // Why it exists: pins the group-specific rule.
        // Scenario: spec-first empty group.
        let groupId = GroupId()
        let msgs = renameCompletionMessages(
            isConfirm: true, target: .group(groupId), newName: "")
        #expect(msgs.count == 1)
        guard case .sidebarRenameEnded = msgs[0] else {
            Issue.record("expected sidebarRenameEnded")
            return
        }
    }

    @Test("renameCompletion: Esc dispatches only focus restore")
    func renameCompletionEscDispatchesOnlyFocusRestore() {
        // Intent: Esc on a tab dispatches only sidebarRenameEnded.
        // Why it exists: pins the cancel path.
        // Scenario: spec-first esc tab.
        let tabId = TabId()
        let msgs = renameCompletionMessages(
            isConfirm: false, target: .tab(tabId), newName: "Changed Text")
        #expect(msgs.count == 1)
        guard case .sidebarRenameEnded = msgs[0] else {
            Issue.record("expected sidebarRenameEnded")
            return
        }
    }

    @Test("renameCompletion: Esc group dispatches only focus restore")
    func renameCompletionEscGroupDispatchesOnlyFocusRestore() {
        // Intent: Esc on a group dispatches only sidebarRenameEnded.
        // Why it exists: pins the cancel path for groups.
        // Scenario: spec-first esc group.
        let groupId = GroupId()
        let msgs = renameCompletionMessages(
            isConfirm: false, target: .group(groupId), newName: "New Name")
        #expect(msgs.count == 1)
        guard case .sidebarRenameEnded = msgs[0] else {
            Issue.record("expected sidebarRenameEnded")
            return
        }
    }

    @Test("renameCompletion: nil target dispatches only focus restore")
    func renameCompletionNilTargetDispatchesOnlyFocusRestore() {
        // Intent: nil action dispatches only sidebarRenameEnded.
        // Why it exists: pins the no-target branch.
        // Scenario: spec-first no target.
        let msgs = renameCompletionMessages(
            isConfirm: true, target: nil, newName: "text")
        #expect(msgs.count == 1)
        guard case .sidebarRenameEnded = msgs[0] else {
            Issue.record("expected sidebarRenameEnded")
            return
        }
    }

    // MARK: - sidebarRenameEnded update handler

    @Test("sidebarRenameEnded leaves active pane as desired focus")
    func sidebarRenameEndedLeavesActivePaneDesired() {
        // Intent: sidebarRenameEnded leaves the active pane as the model target.
        // Why it exists: the reconciler restores focus after AppKit ends editing.
        // Scenario: spec-first focus-restore.
        var model = makeModel()
        createTab(&model)
        let focusedPaneId = model.groups[0].tabs[0].focusedPaneId

        let commands = update(&model, .sidebarRenameEnded)
        #expect(commands.isEmpty)
        #expect(desiredPaneFocus(in: model) == .terminal(focusedPaneId))
    }

    @Test("renameTab emits no commands")
    func renameTabEmitsNoCommands() {
        // Intent: renameTab changes only model state.
        // Why it exists: pins the declarative view-sync boundary.
        // Scenario: spec-first no-steal.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        let commands = update(&model, .renameTab(id: tabId, name: "New"))
        #expect(commands.isEmpty)
    }

    @Test("renameGroup emits no commands")
    func renameGroupEmitsNoCommands() {
        // Intent: renameGroup changes only model state.
        // Why it exists: pins the symmetric declarative boundary.
        // Scenario: spec-first no-steal group.
        var model = makeModel()
        createTab(&model)
        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id

        let commands = update(&model, .renameGroup(id: workId, name: "Projects"))
        #expect(commands.isEmpty)
    }

    // MARK: - Snapshot

    @Test("testSnapshotCustomTitleOmitted")
    func testSnapshotCustomTitleOmitted() throws {
        // Intent: JSON without customTitle decodes with nil
        //   customTitle (backward compat).
        // Why it exists: pins the optional decode.
        // Scenario: spec-first omitted customTitle.
        let json = """
        {
          "version": 3,
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
        #expect(model != nil, "should decode without customTitle")
        #expect(model!.groups[0].tabs[0].customTitle == nil, "customTitle should be nil when omitted")
        #expect(tabDisplayTitle(model!.groups[0].tabs[0]) == "Terminal")
    }

    // MARK: - clearCustomTitles (batch from multi-select context menu)

    @Test("testClearCustomTitlesClearsAllSelected")
    func testClearCustomTitlesClearsAllSelected() {
        // Intent: clearCustomTitles(ids) nils every selected tab's
        //   customTitle; non-selected stay intact.
        // Why it exists: pins the per-id batch scope.
        // Scenario: spec-first batch clear.
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

        #expect(model.groups[0].tabs[0].customTitle == nil)
        #expect(model.groups[0].tabs[1].customTitle == nil)
        #expect(model.groups[0].tabs[2].customTitle == "gamma",
            "tabs not in the batch are unaffected")
    }

    @Test("testClearCustomTitlesDedupesAndIgnoresStale")
    func testClearCustomTitlesDedupesAndIgnoresStale() {
        // Intent: batch clearCustomTitles dedupes and ignores stale ids.
        // Why it exists: pins dedup + stale rules for the batch.
        // Scenario: spec-first batch dedup.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let id1 = model.groups[0].tabs[0].id
        let id2 = model.groups[0].tabs[1].id
        let stale = TabId()
        update(&model, .renameTab(id: id1, name: "alpha"))
        update(&model, .renameTab(id: id2, name: "beta"))

        update(&model, .clearCustomTitles(tabIds: [id1, id1, stale, id2]))

        #expect(model.groups[0].tabs[0].customTitle == nil)
        #expect(model.groups[0].tabs[1].customTitle == nil)
    }

    @Test("testClearCustomTitlesAllStaleIsNoop")
    func testClearCustomTitlesAllStaleIsNoop() {
        // Intent: an all-stale batch is a no-op.
        // Why it exists: pins the empty-after-filter guard.
        // Scenario: spec-first all-stale.
        var model = makeModel()
        createTab(&model)
        let snapshot = model.groups

        let commands = update(&model, .clearCustomTitles(
            tabIds: [TabId(), TabId()]))

        #expect(model.groups == snapshot)
        #expect(commands.count == 0)
    }

    @Test("testClearCustomTitlesRevertsSelectedTabDisplayTitle")
    func testClearCustomTitlesRevertsSelectedTabDisplayTitle() {
        // Intent: clearing the selected tab's customTitle reverts
        //   displayTitle to the underlying session title.
        // Why it exists: pins the displayTitle revert side effect.
        // Scenario: spec-first revert display.
        var model = makeModel()
        createTab(&model)
        let id = model.groups[0].tabs[0].id
        update(&model, .renameTab(id: id, name: "alpha"))
        #expect(model.selectedTabId == id)

        update(&model, .clearCustomTitles(tabIds: [id]))

        #expect(model.groups[0].tabs[0].customTitle == nil)
        #expect(tabDisplayTitle(model.groups[0].tabs[0]) == tabTitle(model.groups[0].tabs[0]),
            "cleared custom title -> display title reverts to the underlying tab title")
    }
}
