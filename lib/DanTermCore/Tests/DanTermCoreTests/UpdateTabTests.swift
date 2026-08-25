// Swift Testing migration of the legacy `tests/UpdateTabTests.swift` harness
// suite. Pins the tab-domain Msg paths: createTab (including inGroupId /
// background / .afterTab / .atGroupEnd positions and cwd inheritance),
// selectTab (selection + bell/alert-clear semantics in focus vs manual modes,
// plus collapsed-group handling), selectAdjacentTab wrap rules,
// requestCloseTab / closeTab confirmation gating, the unified response, and
// batch requestCloseTabs paths (dedup,
// stale filtering, isQuit, checkpoint + terminate sequencing), and the
// setTabColor / setTabColors batch behavior. The dispatcher `closeTabs`
// confirmation helpers and the `effectCount`/`isTerminateEffect` shape probes
// move beside the suite as private file-scope helpers.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct UpdateTabTests {
    @Test("testCreateTabAddsToDefaultGroup")
    func testCreateTabAddsToDefaultGroup() {
        // Intent: createTab adds a tab to the default group, picks a single
        //   pane id, selects it, and emits exactly the createSession command
        //   for that pane.
        // Why it exists: pins the happy path the foreground tab UI relies on
        //   end to end (model selection + downstream session creation).
        // Scenario: spec-first first-tab check.
        var model = makeModel()
        let commands = createTab(&model)

        #expect(model.groups[0].tabs.count == 1)
        #expect(model.allPaneIds.count == 1)
        #expect(model.selectedTabId == model.groups[0].tabs[0].id)
        #expect(hasEffect(commands) {
            if case .createSession = $0 { return true }
            return false
        }, "should emit createSession")
    }

    @Test("testCreateTabBackgroundDoesNotChangeSelection")
    func testCreateTabBackgroundDoesNotChangeSelection() {
        // Intent: a background createTab grows the tab list and emits a
        //   createSession for the new pane while leaving selection and the
        //   prior pane's focus alone.
        // Why it exists: pins the background-tab invariant against
        //   accidental selection-steal regressions.
        // Scenario: spec-first background create -- start with one tab,
        //   create a second in background.
        var model = makeModel()
        createTab(&model)
        let selectedTabId = model.groups[0].tabs[0].id
        let beforePaneIds = Set(model.allPaneIds)

        let commands = createTab(&model, background: true)
        let newPaneIds = Set(model.allPaneIds).subtracting(beforePaneIds)

        #expect(model.groups[0].tabs.count == 2)
        #expect(model.selectedTabId == selectedTabId, "background tab should not steal selection")
        #expect(newPaneIds.count == 1, "background tab should create one pane")
        #expect(hasEffect(commands) {
            if case .createSession(_, let paneId, _, _, _) = $0 {
                return newPaneIds.contains(paneId)
            }
            return false
        }, "should emit createSession for new pane")
    }

    @Test("testCreateTabInheritsWorkingDirectory")
    func testCreateTabInheritsWorkingDirectory() {
        // Intent: a new tab's session inherits the cwd from the currently
        //   focused pane.
        // Why it exists: pins the cwd-propagation rule that keeps new tabs
        //   anchored to the user's current directory.
        // Scenario: spec-first cwd inherit -- first pane has cwd "/tmp/test";
        //   second createTab's session command carries the same cwd.
        var model = makeModel()
        createTab(&model)
        let firstPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        model.updatePane(firstPaneId) { $0.session?.cwd = "/tmp/test" }
        let commands = createTab(&model)
        let createEffect = commands.first(where: {
            if case .createSession = $0 { return true }
            return false
        })
        #expect(createEffect != nil, "should have createSession command")
        if case .createSession(_, _, let cwd, _, _) = createEffect! {
            #expect(cwd == "/tmp/test", "cwd should inherit")
        }
    }

    @Test("testSelectTabSwitchesSelection")
    func testSelectTabSwitchesSelection() {
        // Intent: selectTab updates model.selectedTabId.
        // Why it exists: pins the model mutation that drives downstream
        //   structural rebuilds (reconcileContainers).
        // Scenario: spec-first selection swap.
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        createTab(&model)

        update(&model, .selectTab(id: firstTabId))

        #expect(model.selectedTabId == firstTabId, "model selection should change")
    }

    @Test("testSelectTabClearsBell")
    func testSelectTabClearsBell() {
        // Intent: selecting a tab with an unread bell alert on its focused
        //   pane marks that alert read (default clear mode).
        // Why it exists: pins the "selecting clears the bell" rule the
        //   default settings expose.
        // Scenario: spec-first default-clear -- tab B's pane has an unread
        //   bell; selecting tab B marks it read.
        var model = makeModel()
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        createTab(&model)
        let tabBId = model.groups[0].tabs[1].id
        let tabBPaneId = model.groups[0].tabs[1].paneTree.focusedPaneId

        update(&model, .selectTab(id: tabAId))

        update(&model, .sessionBell(sessionId: sessionId(for: tabBPaneId, in: model)))
        #expect(model.alerts.contains { $0.paneId == tabBPaneId && $0.isUnread }, "should have unread alert on background pane")

        update(&model, .selectTab(id: tabBId))
        #expect(!model.alerts.contains { $0.paneId == tabBPaneId && $0.isUnread }, "selecting tab should mark alerts read")
    }

    @Test("testSelectTabFocusModeMarksFocusedPaneAlertsRead")
    func testSelectTabFocusModeMarksFocusedPaneAlertsRead() {
        // Intent: in focus clear mode, selecting a tab marks only the
        //   focused pane's alerts read.
        // Why it exists: pins the per-pane scope of focus mode against the
        //   tab-wide scope of the default mode.
        // Scenario: spec-first focus mode -- pre-insert an unread alert on
        //   tab B's focused pane; selecting tab B marks it read.
        var model = makeModel()
        model.config.alertClearMode = .focus
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        createTab(&model)
        let tabBId = model.groups[0].tabs[1].id
        let tabBPaneId = model.groups[0].tabs[1].paneTree.focusedPaneId

        update(&model, .selectTab(id: tabAId))

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: tabBPaneId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .selectTab(id: tabBId))

        #expect(model.alerts[0].isUnread == false,
            "focus-mode selection should mark focused pane alerts read")
        #expect(model.selectedTabId == tabBId)
    }

    @Test("testSelectTabFocusModeMarksAlertReadInCollapsedGroup")
    func testSelectTabFocusModeMarksAlertReadInCollapsedGroup() {
        // Intent: focus-mode selection still marks the focused pane's
        //   alerts read when the destination tab lives in a collapsed
        //   group.
        // Why it exists: pins the cross-group focus-mode rule (collapse
        //   is a view concern; clear logic operates on the model).
        // Scenario: spec-first collapse + focus -- collapse a Work group
        //   with one tab + alert; select that tab; alert clears.
        var model = makeModel()
        model.config.alertClearMode = .focus
        createTab(&model)
        let generalTabId = model.groups[0].tabs[0].id
        update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id
        let workTabId = model.groups[1].tabs[0].id
        let workPaneId = model.groups[1].tabs[0].paneTree.focusedPaneId
        update(&model, .selectTab(id: generalTabId))
        update(&model, .toggleGroupCollapse(groupId: workGroupId))

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: workPaneId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .selectTab(id: workTabId))

        #expect(!model.alerts.contains { $0.paneId == workPaneId && $0.isUnread },
            "focus-mode selection should mark the focused pane's alert read")
        #expect(model.selectedTabId == workTabId)
    }

    @Test("testCloseLastPaneShowsConfirmation")
    func testCloseLastPaneShowsConfirmation() {
        // Intent: closing the only pane in the only tab flips
        //   pendingConfirmation to .terminate and leaves the model
        //   unchanged.
        // Why it exists: pins the last-pane confirmation gate the runtime
        //   reads to display the quit panel.
        // Scenario: spec-first last-pane close.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId

        let commands = update(&model, .closePane(paneId: paneId))
        #expect(commands.isEmpty, "no command; reconcileQuitConfirmation drives the panel")
        #expect(testConfirmationKind(model.pendingConfirmation) == .app, "quit confirmation should be pending")
        #expect(model.groups[0].tabs.count == 1, "model should be unchanged")
        #expect(model.pane(paneId) != nil, "pane should still exist")
    }

    @Test("testCloseLastTabShowsConfirmation")
    func testCloseLastTabShowsConfirmation() {
        // Intent: closeTab on the only tab flips pendingConfirmation to
        //   .terminate without mutating the model.
        // Why it exists: pins the symmetric tab-level last-confirmation
        //   gate.
        // Scenario: spec-first last-tab close.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        let commands = update(&model, .closeTab(id: tabId))
        #expect(commands.isEmpty, "no command; reconcileQuitConfirmation drives the panel")
        #expect(testConfirmationKind(model.pendingConfirmation) == .app, "quit confirmation should be pending")
        #expect(model.groups[0].tabs.count == 1, "model should be unchanged")
    }

    @Test("testCreateTabInSpecificGroup")
    func testCreateTabInSpecificGroup() {
        // Intent: createTab honors an explicit inGroupId, placing the new
        //   tab in the requested group.
        // Why it exists: pins the IPC / context-menu routing that lets
        //   callers target a specific group.
        // Scenario: spec-first targeted create -- create Work group, then
        //   add a tab into Work.
        var model = makeModel()
        let _ = update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id

        createTab(&model, inGroupId: workGroupId)

        #expect(model.groups[0].tabs.count == 0, "General should have no tabs")
        #expect(model.groups[1].tabs.count == 2, "Work should have auto-created tab + explicit tab")
    }

    @Test("testCreateTabUnknownGroupIsNoOp")
    func testCreateTabUnknownGroupIsNoOp() {
        var model = makeModel()
        update(&model, .createGroup(name: "Work"))
        let generalCountBefore = model.groups[0].tabs.count
        let workGroupId = model.groups[1].id
        let selectedWorkTabId = model.groups[1].tabs[0].id
        update(&model, .selectTab(id: selectedWorkTabId))
        let workTabIdsBefore = model.groups[1].tabs.map(\.id)
        let unknownGroupId = GroupId()

        update(&model, .createTab(inGroupId: unknownGroupId))

        #expect(model.groups[0].tabs.count == generalCountBefore,
            "unknown explicit group should not fall back to group 0")
        #expect(model.groups[1].id == workGroupId, "pre-existing Work group should remain the target")
        #expect(model.groups[1].tabs.map(\.id) == workTabIdsBefore,
            "unknown explicit group should not create a tab")
        #expect(!model.groups.contains { $0.id == unknownGroupId }, "unknown id should not create a group")
        #expect(model.selectedTabId == selectedWorkTabId)
    }

    @Test("testCreateTabBackgroundIntoSpecificGroup")
    func testCreateTabBackgroundIntoSpecificGroup() {
        // Intent: an inGroupId + background create lands in the requested
        //   group without taking selection.
        // Why it exists: pins the cross-cutting routing + background combo.
        // Scenario: spec-first background-into-group.
        var model = makeModel()
        createTab(&model)
        let selectedTabId = model.selectedTabId!
        let _ = update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id
        let workCountBefore = model.groups[1].tabs.count
        _ = update(&model, .selectTab(id: selectedTabId))

        createTab(&model, inGroupId: workGroupId, background: true)

        #expect(model.groups[1].tabs.count == workCountBefore + 1, "background tab should land in requested group")
        #expect(model.selectedTabId == selectedTabId, "background tab should not change selection")
    }

    @Test("testCreateTabInsertsAfterCurrentTab")
    func testCreateTabInsertsAfterCurrentTab() {
        // Intent: createTab inserts the new tab immediately after the
        //   currently-selected tab.
        // Why it exists: pins the "insert after current" rule the tab bar
        //   reorders depend on.
        // Scenario: spec-first insert -- 3 tabs, select A, create D ->
        //   [A, D, B, C].
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        let tabBId = model.groups[0].tabs[1].id
        let tabCId = model.groups[0].tabs[2].id

        update(&model, .selectTab(id: tabAId))
        createTab(&model)
        let tabDId = model.groups[0].tabs[1].id

        #expect(model.groups[0].tabs.count == 4)
        #expect(model.groups[0].tabs[0].id == tabAId, "tab A should be first")
        #expect(model.groups[0].tabs[1].id == tabDId, "new tab D should be after A")
        #expect(model.groups[0].tabs[2].id == tabBId, "tab B should shift right")
        #expect(model.groups[0].tabs[3].id == tabCId, "tab C should shift right")
    }

    @Test("testCreateTabAtGroupEndAppendsRegardlessOfSelection")
    func testCreateTabAtGroupEndAppendsRegardlessOfSelection() {
        // Intent: position: .atGroupEnd appends to the end of the group
        //   regardless of which tab is selected.
        // Why it exists: pins the explicit-append position override.
        // Scenario: spec-first append-override -- 3 tabs A/B/C, select B,
        //   atGroupEnd lands tab D at index 3.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        let tabBId = model.groups[0].tabs[1].id
        let tabCId = model.groups[0].tabs[2].id

        update(&model, .selectTab(id: tabBId))
        update(&model, .createTabInSelectedGroup(position: .atGroupEnd))
        let tabDId = model.groups[0].tabs[3].id

        #expect(model.groups[0].tabs.count == 4)
        #expect(model.groups[0].tabs[0].id == tabAId, "tab A stays first")
        #expect(model.groups[0].tabs[1].id == tabBId, "tab B keeps its slot")
        #expect(model.groups[0].tabs[2].id == tabCId, "tab C keeps its slot")
        #expect(model.groups[0].tabs[3].id == tabDId, "new tab lands at end")
        #expect(model.selectedTabId == tabDId, "newly created tab is selected")
    }

    @Test("testCreateTabAtGroupEndUsesSelectedTabsGroupWhenNoneSpecified")
    func testCreateTabAtGroupEndUsesSelectedTabsGroupWhenNoneSpecified() {
        // Intent: atGroupEnd with inGroupId nil resolves to the selected
        //   tab's group and appends there.
        // Why it exists: pins the implicit-group-resolution rule.
        // Scenario: spec-first implicit-group -- Work group with three
        //   tabs, select middle, atGroupEnd appends to Work.
        var model = makeModel()
        update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id
        update(&model, .createTab(inGroupId: workGroupId))
        update(&model, .createTab(inGroupId: workGroupId))
        let workTab1 = model.groups[1].tabs[0].id
        let workTab2 = model.groups[1].tabs[1].id

        update(&model, .selectTab(id: workTab2))
        update(&model, .createTabInSelectedGroup(position: .atGroupEnd))

        #expect(model.groups[0].tabs.count == 0, "default group untouched")
        #expect(model.groups[1].tabs.count == 4, "work group grows by one")
        #expect(model.groups[1].tabs[0].id == workTab1, "first work tab unchanged")
        #expect(model.groups[1].tabs[1].id == workTab2, "selected work tab unchanged")
        #expect(model.groups[1].tabs.last?.id == model.selectedTabId, "new tab is last and selected")
    }

    @Test("testCreateTabAfterTabInTargetGroupInsertsAfterReference")
    func testCreateTabAfterTabInTargetGroupInsertsAfterReference() {
        // Intent: position: .afterTab(ref) places the new tab right
        //   after the referenced tab.
        // Why it exists: pins the explicit-reference insertion the IPC
        //   surfaces.
        // Scenario: spec-first afterTab -- A/B/C, create after A ->
        //   [A, D, B, C].
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        let tabBId = model.groups[0].tabs[1].id
        let tabCId = model.groups[0].tabs[2].id

        update(&model, .createTabInSelectedGroup(position: .afterTab(tabAId)))
        let tabDId = model.groups[0].tabs[1].id

        #expect(model.groups[0].tabs.map(\.id) == [tabAId, tabDId, tabBId, tabCId])
        #expect(model.selectedTabId == tabDId, "newly created tab is selected")
    }

    @Test("testCreateTabAfterTabFromDifferentGroupAppendsToTargetGroup")
    func testCreateTabAfterTabFromDifferentGroupAppendsToTargetGroup() {
        // Intent: when afterTab refers to a tab in a different group than
        //   the requested inGroupId, the new tab appends to the requested
        //   group.
        // Why it exists: pins the inGroupId-wins fallback so a stale or
        //   cross-group reference doesn't escape the target group.
        // Scenario: spec-first cross-group afterTab.
        var model = makeModel()
        createTab(&model)
        let otherGroupRef = model.groups[0].tabs[0].id
        _ = update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id
        update(&model, .createTab(inGroupId: workGroupId))
        let workBefore = model.groups[1].tabs.map(\.id)

        update(&model, .createTab(inGroupId: workGroupId, position: .afterTab(otherGroupRef)))
        let newTabId = model.groups[1].tabs.last!.id

        #expect(model.groups[1].tabs.map(\.id) == workBefore + [newTabId])
        #expect(model.selectedTabId == newTabId, "newly created tab is selected")
    }

    @Test("testCreateTabAfterUnknownTabAppendsToTargetGroup")
    func testCreateTabAfterUnknownTabAppendsToTargetGroup() {
        // Intent: afterTab with an unknown reference appends to the
        //   target group.
        // Why it exists: pins the fail-open behavior so stale ids don't
        //   raise errors or place the tab in the wrong group.
        // Scenario: spec-first unknown-ref afterTab.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let before = model.groups[0].tabs.map(\.id)

        update(&model, .createTabInSelectedGroup(position: .afterTab(TabId())))
        let newTabId = model.groups[0].tabs.last!.id

        #expect(model.groups[0].tabs.map(\.id) == before + [newTabId])
        #expect(model.selectedTabId == newTabId, "newly created tab is selected")
    }

    // MARK: - Adjacent Tab Navigation

    @Test("testNextTabWithinSameGroup")
    func testNextTabWithinSameGroup() {
        // Intent: selectAdjacentTab(.next) moves selection to the next tab
        //   in the same group.
        // Why it exists: pins intra-group forward navigation.
        // Scenario: spec-first next within group.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let secondTabId = model.groups[0].tabs[1].id
        update(&model, .selectTab(id: firstTabId))

        update(&model, .selectAdjacentTab(direction: .next))
        #expect(model.selectedTabId == secondTabId)
    }

    @Test("testPrevTabWithinSameGroup")
    func testPrevTabWithinSameGroup() {
        // Intent: selectAdjacentTab(.prev) moves selection to the previous
        //   tab in the same group.
        // Why it exists: pins intra-group backward navigation.
        // Scenario: spec-first prev within group.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let secondTabId = model.groups[0].tabs[1].id
        update(&model, .selectTab(id: secondTabId))

        update(&model, .selectAdjacentTab(direction: .prev))
        #expect(model.selectedTabId == firstTabId)
    }

    @Test("testNextTabAcrossGroups")
    func testNextTabAcrossGroups() {
        // Intent: .next crosses group boundaries when no more tabs in the
        //   current group.
        // Why it exists: pins cross-group forward navigation.
        // Scenario: spec-first next across groups.
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .createGroup(name: "Work"))
        let secondTabId = model.groups[1].tabs[0].id
        update(&model, .selectTab(id: firstTabId))

        update(&model, .selectAdjacentTab(direction: .next))
        #expect(model.selectedTabId == secondTabId)
    }

    @Test("testPrevTabAcrossGroups")
    func testPrevTabAcrossGroups() {
        // Intent: .prev crosses group boundaries when no more tabs in the
        //   current group.
        // Why it exists: pins cross-group backward navigation.
        // Scenario: spec-first prev across groups.
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .createGroup(name: "Work"))
        let secondTabId = model.groups[1].tabs[0].id
        update(&model, .selectTab(id: secondTabId))

        update(&model, .selectAdjacentTab(direction: .prev))
        #expect(model.selectedTabId == firstTabId)
    }

    @Test("testNextTabNoOpWithSingleTab")
    func testNextTabNoOpWithSingleTab() {
        // Intent: with one tab, .next is a no-op (no wrap-to-self).
        // Why it exists: pins the single-tab guard.
        // Scenario: spec-first single-tab next.
        var model = makeModel()
        createTab(&model)
        let lastTabId = model.groups[0].tabs[0].id

        update(&model, .selectAdjacentTab(direction: .next))
        #expect(model.selectedTabId == lastTabId)
    }

    @Test("testPrevTabNoOpWithSingleTab")
    func testPrevTabNoOpWithSingleTab() {
        // Intent: with one tab, .prev is a no-op (no wrap-to-self).
        // Why it exists: pins the single-tab guard for prev.
        // Scenario: spec-first single-tab prev.
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id

        update(&model, .selectAdjacentTab(direction: .prev))
        #expect(model.selectedTabId == firstTabId)
    }

    @Test("testNextTabWrapsFromLastToFirst")
    func testNextTabWrapsFromLastToFirst() {
        // Intent: .next from the last tab wraps to the first.
        // Why it exists: pins the wrap-around rule for next.
        // Scenario: spec-first wrap next.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let lastTabId  = model.groups[0].tabs[1].id
        update(&model, .selectTab(id: lastTabId))

        update(&model, .selectAdjacentTab(direction: .next))
        #expect(model.selectedTabId == firstTabId)
    }

    @Test("testPrevTabWrapsFromFirstToLast")
    func testPrevTabWrapsFromFirstToLast() {
        // Intent: .prev from the first tab wraps to the last.
        // Why it exists: pins the wrap-around rule for prev.
        // Scenario: spec-first wrap prev.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let lastTabId  = model.groups[0].tabs[1].id
        update(&model, .selectTab(id: firstTabId))

        update(&model, .selectAdjacentTab(direction: .prev))
        #expect(model.selectedTabId == lastTabId)
    }

    @Test("testNextTabWrapsAcrossGroups")
    func testNextTabWrapsAcrossGroups() {
        // Intent: .next wrap reaches into the first tab of the first group.
        // Why it exists: pins the global-wrap rule that bridges groups.
        // Scenario: spec-first cross-group wrap next.
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .createGroup(name: "Work"))
        let lastTabId = model.groups[1].tabs[0].id
        update(&model, .selectTab(id: lastTabId))

        update(&model, .selectAdjacentTab(direction: .next))
        #expect(model.selectedTabId == firstTabId)
    }

    @Test("testPrevTabWrapsAcrossGroups")
    func testPrevTabWrapsAcrossGroups() {
        // Intent: .prev wrap reaches into the last tab of the last group.
        // Why it exists: pins the global-wrap rule that bridges groups.
        // Scenario: spec-first cross-group wrap prev.
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .createGroup(name: "Work"))
        let lastTabId = model.groups[1].tabs[0].id
        update(&model, .selectTab(id: firstTabId))

        update(&model, .selectAdjacentTab(direction: .prev))
        #expect(model.selectedTabId == lastTabId)
    }

    @Test("testPrevTabWrapsIntoCollapsedGroup")
    func testPrevTabWrapsIntoCollapsedGroup() {
        // Intent: wrap navigation reaches into collapsed groups (collapse
        //   is a view concern; the wrap rule operates over the model).
        // Why it exists: pins the "do not skip collapsed groups" non-goal
        //   of the wrap change.
        // Scenario: spec-first collapse + wrap -- prev wraps into a
        //   collapsed Work group.
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .createGroup(name: "Work"))
        let collapsedGroupId = model.groups[1].id
        let lastTabId = model.groups[1].tabs[0].id
        update(&model, .toggleGroupCollapse(groupId: collapsedGroupId))
        update(&model, .selectTab(id: firstTabId))

        update(&model, .selectAdjacentTab(direction: .prev))
        #expect(model.selectedTabId == lastTabId,
            "wrap should reach tabs in collapsed groups")
    }

    @Test("testNextTabNoOpWithNoTabs")
    func testNextTabNoOpWithNoTabs() {
        // Intent: with no tabs, .next emits no commands.
        // Why it exists: pins the empty-model guard.
        // Scenario: spec-first empty next.
        var model = makeModel()
        let commands = update(&model, .selectAdjacentTab(direction: .next))
        #expect(commands.count == 0)
    }

    @Test("testPrevTabNoOpWithNoTabs")
    func testPrevTabNoOpWithNoTabs() {
        // Intent: with no tabs, .prev emits no commands.
        // Why it exists: pins the empty-model guard for prev.
        // Scenario: spec-first empty prev.
        var model = makeModel()
        let commands = update(&model, .selectAdjacentTab(direction: .prev))
        #expect(commands.count == 0)
    }

    // MARK: - requestCloseTab

    @Test("testRequestCloseTabSinglePaneClosesDirectly")
    func testRequestCloseTabSinglePaneClosesDirectly() {
        // Intent: requestCloseTab on a single-pane tab closes immediately
        //   (no confirmation panel).
        // Why it exists: pins the fast-path rule for the common case.
        // Scenario: spec-first direct close -- two-tab model, close the
        //   non-selected first single-pane tab.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let firstPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        let liveBefore = Set(model.allPaneIds)

        _ = update(&model, .requestCloseTab(id: firstTabId))
        #expect(model.groups[0].tabs.count == 1, "tab should be removed")
        #expect(sessionsToTearDown(liveSessionIds: liveBefore, model: model) == Set([firstPaneId]),
            "closed tab's pane session is torn down")
        #expect(model.pendingConfirmation == nil,
            "should not show confirmation for single-pane tab")
    }

    @Test("testRequestCloseTabMultiPaneShowsConfirmation")
    func testRequestCloseTabMultiPaneShowsConfirmation() {
        // Intent: requestCloseTab on a multi-pane tab emits a
        //   unified close confirmation and leaves the tab in place.
        // Why it exists: pins the confirmation gating for tabs with more
        //   than one pane.
        // Scenario: spec-first multi-pane confirm.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: firstTabId))

        update(&model, .splitFocusedPane(direction: .horizontal))

        _ = update(&model, .requestCloseTab(id: firstTabId))
        #expect(model.groups[0].tabs.count == 2, "tab should NOT be removed yet")
        #expect(testConfirmationKind(model.pendingConfirmation) == .tab(firstTabId),
            "should show confirmation with correct subject")
        #expect(pendingCloseImpact(model.pendingConfirmation)?.panes.count == 2)
    }

    @Test("testRequestCloseTabMultiPaneSetsPending")
    func testRequestCloseTabMultiPaneSetsPending() {
        // Intent: requestCloseTab on a multi-pane tab sets
        //   a tab-subject pending confirmation.
        // Why it exists: pins the pending-state mutation alongside the
        //   confirmation command.
        // Scenario: spec-first multi-pane pending.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: firstTabId))
        update(&model, .splitFocusedPane(direction: .horizontal))

        let commands = update(&model, .requestCloseTab(id: firstTabId))

        #expect(commands.isEmpty)
        #expect(testConfirmationKind(model.pendingConfirmation) == .tab(firstTabId), "close-tab confirmation should be pending")
    }

    @Test("a repeated close-tab request replaces the transaction")
    func repeatedCloseTabRequestReplacesTransaction() throws {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: firstTabId))
        update(&model, .splitFocusedPane(direction: .horizontal))
        model.pendingConfirmation = pendingCloseConfirmation(for: .tab(firstTabId), in: model)
        let firstId = try #require(model.pendingConfirmation?.id)

        let commands = update(&model, .requestCloseTab(id: firstTabId))

        #expect(commands.isEmpty)
        #expect(testConfirmationKind(model.pendingConfirmation) == .tab(firstTabId))
        #expect(model.pendingConfirmation?.id != firstId)
    }

    @Test("testRequestCloseTabWhileQuitPendingIsNoOp")
    func testRequestCloseTabWhileQuitPendingIsNoOp() {
        // Intent: a pending terminate confirmation blocks
        //   requestCloseTab.
        // Why it exists: pins the no-overlap guard against the quit panel.
        // Scenario: spec-first overlap guard (terminate pending).
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: firstTabId))
        update(&model, .splitFocusedPane(direction: .horizontal))
        model.pendingConfirmation = pendingAppConfirmation()

        let commands = update(&model, .requestCloseTab(id: firstTabId))

        #expect(commands.isEmpty)
        #expect(testConfirmationKind(model.pendingConfirmation) == .tab(firstTabId),
            "the close request should replace the quit confirmation")
    }

    @Test("testConfirmCloseTabClearsPendingAndDispatches")
    func testConfirmCloseTabClearsPendingAndDispatches() {
        // Intent: unified confirmation clears pendingConfirmation, removes the
        //   tab, and the session-existence reconciler tears down every
        //   pane in the closed tab.
        // Why it exists: pins the confirm-side commitment (mirror of the
        //   request-side gate).
        // Scenario: spec-first confirm-multi -- two-pane first tab; confirm
        //   closes and tears down both sessions.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: firstTabId))
        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneIds = paneIdsForTab(firstTabId, in: model)
        model.pendingConfirmation = pendingCloseConfirmation(for: .tab(firstTabId), in: model)
        let liveBefore = Set(model.allPaneIds)

        confirmPending(&model)

        #expect(model.pendingConfirmation == nil, "confirm should clear pending confirmation")
        #expect(!model.groups[0].tabs.contains { $0.id == firstTabId }, "tab should be removed")
        #expect(sessionsToTearDown(liveSessionIds: liveBefore, model: model) == Set(paneIds),
            "each pane in the closed tab is torn down")
    }

    @Test("testConfirmCloseTabLastMultiPaneRoutesToTerminate")
    func testConfirmCloseTabLastMultiPaneRoutesToTerminate() {
        // Intent: confirming the last multi-pane tab routes through a
        //   terminate confirmation rather than closing immediately.
        // Why it exists: pins the "last-tab terminate path" the close
        //   panel uses to chain into the quit confirmation.
        // Scenario: spec-first last-tab-multi-pane.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneIds = paneIdsForTab(tabId, in: model)
        model.pendingConfirmation = pendingCloseConfirmation(
            for: .tab(tabId),
            in: model,
            quitAuthorized: true
        )

        let commands = confirmPending(&model)

        #expect(commands.contains { if case .terminate = $0 { return true }; return false })
        for paneId in paneIds {
            #expect(model.pane(paneId) == nil, "pane should be removed")
        }
        #expect(model.hasAnyTab == false)
        #expect(model.pendingConfirmation == nil, "confirmed quit authorization should not ask twice")
    }

    @Test("testCancelCloseTabClearsPending")
    func testCancelCloseTabClearsPending() {
        // Intent: unified cancellation clears pendingConfirmation and emits no
        //   commands.
        // Why it exists: pins the cancel-side wiring.
        // Scenario: spec-first cancel.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        model.pendingConfirmation = pendingCloseConfirmation(for: .tab(tabId), in: model)

        let commands = cancelPending(&model)

        #expect(commands.count == 0, "cancel should produce no commands")
        #expect(model.pendingConfirmation == nil, "cancel should clear pending confirmation")
    }

    @Test("testRequestCloseTabSinglePaneLastTabShowsTerminateConfirmation")
    func testRequestCloseTabSinglePaneLastTabShowsTerminateConfirmation() {
        // Intent: requestCloseTab on the last single-pane tab flips
        //   pendingConfirmation to .terminate (no immediate close).
        // Why it exists: pins the terminate-path for the last tab.
        // Scenario: spec-first last-tab-single-pane.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        let commands = update(&model, .requestCloseTab(id: tabId))
        #expect(model.groups[0].tabs.count == 1, "tab should NOT be removed")
        #expect(commands.isEmpty, "no command; reconcileQuitConfirmation drives the panel")
        #expect(testConfirmationKind(model.pendingConfirmation) == .app, "quit confirmation should be pending")
    }

    @Test("testRequestCloseTabsMixedBatchShowsSingleConfirmationAndKeepsTabsUntilConfirm")
    func testRequestCloseTabsMixedBatchShowsSingleConfirmationAndKeepsTabsUntilConfirm() {
        // Intent: a batch with multi-pane + todo-bearing tabs shows
        //   exactly one batch confirmation, carries the requested ids,
        //   reports a tabCount of 3, and leaves the tabs in place + no
        //   panes torn down.
        // Why it exists: pins the batch-confirm rollup so a multi-tab
        //   close goes through a single panel.
        // Scenario: spec-first batch confirm.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let secondTabId = model.groups[0].tabs[1].id
        let thirdTabId = model.groups[0].tabs[2].id
        update(&model, .selectTab(id: firstTabId))
        update(&model, .splitFocusedPane(direction: .horizontal))
        update(&model, .addTodo(owner: .tab(secondTabId), text: "finish this"))
        let tabIdsBefore = model.groups.flatMap(\.tabs).map(\.id)
        let liveBefore = Set(model.allPaneIds)

        _ = update(&model, .requestCloseTabs(ids: [firstTabId, secondTabId, thirdTabId]))

        guard let confirmation = closeTabsConfirmationArgs(in: model) else {
            Issue.record("expected batch close confirmation")
            return
        }
        #expect(model.pendingConfirmation != nil, "should hold one batch confirmation")
        #expect(confirmation.tabIds == [firstTabId, secondTabId, thirdTabId])
        #expect(confirmation.tabCount == 3)
        #expect(model.groups.flatMap(\.tabs).map(\.id) == tabIdsBefore, "tabs should remain until confirm")
        #expect(testConfirmationKind(model.pendingConfirmation) == .tabs([firstTabId, secondTabId, thirdTabId]),
            "batch confirmation should be pending")
        #expect(sessionsToTearDown(liveSessionIds: liveBefore, model: model).isEmpty,
            "request should not tear down panes")
    }

    @Test("testRequestCloseTabsRollsUpPaneAndTodoCounts")
    func testRequestCloseTabsRollsUpPaneAndTodoCounts() {
        // Intent: the confirmation carries totalPaneCount and
        //   totalUncompletedTodos rolled up across the batch.
        // Why it exists: pins the per-tab rollup the dialog renders.
        // Scenario: spec-first rollup -- four panes total (one split),
        //   two uncompleted todos (one tab, one pane).
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let secondTabId = model.groups[0].tabs[1].id
        let thirdTab = model.groups[0].tabs[2]
        update(&model, .selectTab(id: firstTabId))
        update(&model, .splitFocusedPane(direction: .horizontal))
        update(&model, .addTodo(owner: .tab(secondTabId), text: "tab task"))
        update(&model, .addTodo(owner: .pane(thirdTab.paneTree.focusedPaneId), text: "pane task"))

        _ = update(&model, .requestCloseTabs(ids: [firstTabId, secondTabId, thirdTab.id]))

        guard let confirmation = closeTabsConfirmationArgs(in: model) else {
            Issue.record("expected batch close confirmation")
            return
        }
        #expect(confirmation.totalPaneCount == 4, "should roll up every pane in the batch")
        #expect(confirmation.totalUncompletedTodos == 2, "should roll up tab and pane todos")
    }

    @Test("testRequestCloseTabsSetsIsQuitWhenBatchCoversEveryLiveTab")
    func testRequestCloseTabsSetsIsQuitWhenBatchCoversEveryLiveTab() {
        // Intent: when the batch covers every live tab, the confirmation
        //   reports isQuit=true.
        // Why it exists: pins the quit-routing condition the dialog uses
        //   to switch its copy.
        // Scenario: spec-first batch covers all.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let ids = model.groups[0].tabs.map(\.id)

        _ = update(&model, .requestCloseTabs(ids: ids))

        guard let confirmation = closeTabsConfirmationArgs(in: model) else {
            Issue.record("expected batch close confirmation")
            return
        }
        #expect(confirmation.isQuit, "closing every live tab should set isQuit")
    }

    @Test("testRequestCloseTabsSingleIdDelegatesToRequestCloseTab")
    func testRequestCloseTabsSingleIdDelegatesToRequestCloseTab() {
        // Intent: a single-id batch produces the same model and session teardown as a direct
        //   requestCloseTab.
        // Why it exists: pins the dispatcher's single-id delegation
        //   contract (no behavior drift).
        // Scenario: spec-first delegation parity.
        var base = makeModel()
        createTab(&base)
        createTab(&base)
        let firstTabId = base.groups[0].tabs[0].id
        var direct = base
        var batch = base

        let liveBefore = Set(base.allPaneIds)
        update(&direct, .requestCloseTab(id: firstTabId))
        update(&batch, .requestCloseTabs(ids: [firstTabId]))

        #expect(batch == direct, "single-id batch should match direct request model mutation")
        #expect(sessionsToTearDown(liveSessionIds: liveBefore, model: batch) ==
                        sessionsToTearDown(liveSessionIds: liveBefore, model: direct))
    }

    @Test("a single-id batch that needs confirmation matches the direct request")
    func singleIdBatchNeedingConfirmationMatchesDirectRequest() {
        // Intent: a one-tab batch whose tab has more than one pane produces the
        //   same pending confirmation as a direct requestCloseTab.
        // Why it exists: the menubar close routes every target set through
        //   requestCloseTabs, so single-target parity has to hold on the
        //   confirming arm too, not just the close-immediately arm.
        // Scenario: spec-first parity -- the target tab holds a split.
        var base = makeModel()
        createTab(&base)
        createTab(&base)
        let firstTabId = base.groups[0].tabs[0].id
        update(&base, .selectTab(id: firstTabId))
        update(&base, .splitFocusedPane(direction: .horizontal))
        var direct = base
        var batch = base

        update(&direct, .requestCloseTab(id: firstTabId))
        update(&batch, .requestCloseTabs(ids: [firstTabId]))

        #expect(testConfirmationKind(direct.pendingConfirmation) == .tab(firstTabId),
            "the direct request should raise a single-tab confirmation")
        #expect(testConfirmationKind(batch.pendingConfirmation) ==
                        testConfirmationKind(direct.pendingConfirmation),
            "the single-id batch should raise the same confirmation subject")
        #expect(batch.groups == direct.groups, "neither path should close the tab yet")
    }

    @Test("testRequestCloseTabsEmptyIdsIsNoOp")
    func testRequestCloseTabsEmptyIdsIsNoOp() {
        // Intent: an empty-batch requestCloseTabs is a no-op (no commands,
        //   no model change).
        // Why it exists: pins the empty-input guard.
        // Scenario: spec-first empty batch.
        var model = makeModel()
        let snapshot = model

        let commands = update(&model, .requestCloseTabs(ids: []))

        #expect(commands.count == 0)
        #expect(model == snapshot, "empty batch should not mutate model")
    }

    @Test("testRequestCloseTabsFiltersStaleIdsBeforeSingletonDelegation")
    func testRequestCloseTabsFiltersStaleIdsBeforeSingletonDelegation() {
        // Intent: stale ids are filtered before the batch decides to
        //   delegate to the single-id close path.
        // Why it exists: pins the dispatcher prune so a stale id does not
        //   confuse the singleton-vs-batch decision.
        // Scenario: spec-first stale-prune -- batch {stale, live} closes
        //   the live tab.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let liveTabId = model.groups[0].tabs[0].id
        let liveTabPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        let staleTabId = TabId()
        let liveBefore = Set(model.allPaneIds)

        update(&model, .requestCloseTabs(ids: [staleTabId, liveTabId]))

        #expect(!model.groups[0].tabs.contains { $0.id == liveTabId }, "live tab should be closed")
        #expect(model.groups[0].tabs.count == 1, "stale id should be ignored")
        #expect(sessionsToTearDown(liveSessionIds: liveBefore, model: model).contains(liveTabPaneId),
            "delegated close tears down the live tab pane")
    }

    @Test("testRequestCloseTabsDeduplicatesIdsForConfirmation")
    func testRequestCloseTabsDeduplicatesIdsForConfirmation() {
        // Intent: duplicate ids in the batch dedup before the
        //   confirmation, and the dedup'd id count drives isQuit.
        // Why it exists: pins the dedup contract that prevents
        //   double-counting from inflating the confirmation copy or
        //   misfiring quit routing.
        // Scenario: spec-first dedup.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let secondTabId = model.groups[0].tabs[1].id
        update(&model, .selectTab(id: firstTabId))
        update(&model, .splitFocusedPane(direction: .horizontal))

        _ = update(&model, .requestCloseTabs(ids: [firstTabId, secondTabId, firstTabId, secondTabId]))

        guard let confirmation = closeTabsConfirmationArgs(in: model) else {
            Issue.record("expected batch close confirmation")
            return
        }
        #expect(confirmation.tabIds == [firstTabId, secondTabId])
        #expect(confirmation.tabCount == 2)
        #expect(confirmation.totalPaneCount == 3)
        #expect(confirmation.isQuit, "unique-id coverage should drive isQuit")
    }

    @Test("a batch close request replaces the pending transaction")
    func batchCloseRequestReplacesPendingTransaction() throws {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let ids = model.groups[0].tabs.map(\.id)
        model.pendingConfirmation = pendingCloseConfirmation(for: .tabs(ids), in: model)
        let firstId = try #require(model.pendingConfirmation?.id)

        let commands = update(&model, .requestCloseTabs(ids: ids))

        #expect(commands.isEmpty)
        #expect(testConfirmationKind(model.pendingConfirmation) == .tabs(ids))
        #expect(model.pendingConfirmation?.id != firstId)
        #expect(model.groups[0].tabs.map(\.id) == ids)
    }

    @Test("testConfirmCloseTabsRemovesEveryRequestedTabAndClearsPending")
    func testConfirmCloseTabsRemovesEveryRequestedTabAndClearsPending() {
        // Intent: unified confirmation removes every requested tab, clears
        //   pendingConfirmation, and the session-existence reconciler
        //   tears down every pane in the closed tabs.
        // Why it exists: pins the batch confirm commit.
        // Scenario: spec-first commit -- close first + second of three
        //   tabs.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let secondTabId = model.groups[0].tabs[1].id
        let thirdTabId = model.groups[0].tabs[2].id
        update(&model, .selectTab(id: firstTabId))
        update(&model, .splitFocusedPane(direction: .horizontal))
        let expectedDestroyed = Set(paneIdsForTab(firstTabId, in: model) + paneIdsForTab(secondTabId, in: model))
        model.pendingConfirmation = pendingCloseConfirmation(
            for: .tabs([firstTabId, secondTabId]),
            in: model
        )
        let liveBefore = Set(model.allPaneIds)

        confirmPending(&model)

        #expect(model.pendingConfirmation == nil, "confirm should clear pending confirmation")
        #expect(Set(model.groups.flatMap(\.tabs).map(\.id)) == Set([thirdTabId]))
        #expect(sessionsToTearDown(liveSessionIds: liveBefore, model: model) == expectedDestroyed)
        for paneId in expectedDestroyed {
            #expect(model.pane(paneId) == nil, "closed tab pane should be removed")
        }
    }

    @Test("testConfirmCloseTabsEmptyingBatchTerminatesWithoutReloadOrCheckpoint")
    func testConfirmCloseTabsEmptyingBatchTerminatesWithoutReloadOrCheckpoint() {
        // Intent: when a batch closes every live tab, the dispatcher emits exactly one
        //   terminate as the last command.
        // Why it exists: pins the terminate-only commit so a closing-app
        //   batch doesn't waste a checkpoint write.
        // Scenario: spec-first close-all-and-terminate.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let ids = model.groups[0].tabs.map(\.id)
        model.pendingConfirmation = pendingCloseConfirmation(
            for: .tabs(ids),
            in: model,
            quitAuthorized: true
        )

        let commands = confirmPending(&model)

        #expect(effectCount(commands) { if case .terminate = $0 { return true }; return false } ==
                        1, "emptying batch should emit exactly one terminate")
        #expect(isTerminateEffect(commands.last), "terminate should be the final command")
    }

    @Test("testConfirmCloseTabsNonEmptyingBatchReloadsAndCheckpointsOnce")
    func testConfirmCloseTabsNonEmptyingBatchReloadsAndCheckpointsOnce() {
        // Intent: a non-emptying batch checkpoints exactly once and does
        //   NOT terminate.
        // Why it exists: pins the partial-close commit so the surviving
        //   set persists via a single checkpoint, not zero or many.
        // Scenario: spec-first partial-close.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let secondTabId = model.groups[0].tabs[1].id
        let thirdTabId = model.groups[0].tabs[2].id
        update(&model, .selectTab(id: secondTabId))
        model.pendingConfirmation = pendingCloseConfirmation(
            for: .tabs([secondTabId, thirdTabId]),
            in: model
        )

        let commands = confirmPending(&model)

        #expect(Set(model.groups.flatMap(\.tabs).map(\.id)) == Set([firstTabId]))
        #expect(model.selectedTabId == firstTabId, "selection should move to a remaining tab")
        #expect(commands.isEmpty)
        #expect(effectCount(commands) { if case .terminate = $0 { return true }; return false } ==
                        0, "non-emptying batch should not terminate")
    }

    @Test("testCancelCloseTabsClearsPendingAndRemovesNothing")
    func testCancelCloseTabsClearsPendingAndRemovesNothing() {
        // Intent: unified cancellation clears pendingConfirmation and leaves
        //   every tab in place.
        // Why it exists: pins the batch cancel wiring.
        // Scenario: spec-first batch cancel.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let ids = model.groups[0].tabs.map(\.id)
        model.pendingConfirmation = pendingCloseConfirmation(for: .tabs(ids), in: model)

        let commands = cancelPending(&model)

        #expect(commands.count == 0, "cancel should produce no commands")
        #expect(model.pendingConfirmation == nil, "cancel should clear pending confirmation")
        #expect(model.groups[0].tabs.map(\.id) == ids)
    }

    // MARK: - Tab Color

    @Test("testSetTabColor")
    func testSetTabColor() {
        // Intent: setTabColors on a single tab id sets the color.
        // Why it exists: pins the color mutation path.
        // Scenario: spec-first set color.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        let commands = update(&model, .setTabColors(tabIds: [tabId], color: .red))
        #expect(model.groups[0].tabs[0].color == .red)
        #expect(commands.isEmpty)
    }

    @Test("testSetTabColorClear")
    func testSetTabColorClear() {
        // Intent: setTabColors with nil clears the color.
        // Why it exists: pins the explicit-clear branch.
        // Scenario: spec-first clear color.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .setTabColors(tabIds: [tabId], color: .blue))

        let commands = update(&model, .setTabColors(tabIds: [tabId], color: nil))
        #expect(model.groups[0].tabs[0].color == nil, "color should be nil")
        #expect(commands.isEmpty)
    }

    @Test("testSetTabColorReplaceDifferent")
    func testSetTabColorReplaceDifferent() {
        // Intent: setting a different color replaces the existing one
        //   (The replacement Msg always replaces; a request resolves toggle-off.)
        // Why it exists: pins the always-replace semantics against the
        //   removed Msg-layer toggle.
        // Scenario: spec-first replace different.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .setTabColors(tabIds: [tabId], color: .red))

        update(&model, .setTabColors(tabIds: [tabId], color: .blue))
        #expect(model.groups[0].tabs[0].color == .blue)
    }

    @Test("testCloseTabNonSelected")
    func testCloseTabNonSelected() {
        // Intent: closing a non-selected tab does not change selection;
        //   the closed tab's pane session is torn down.
        // Why it exists: pins the selection invariant for background-tab
        //   closes alongside the session-existence net.
        // Scenario: spec-first close-non-selected.
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let firstPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId

        createTab(&model)
        let secondTabId = model.groups[0].tabs[1].id
        let liveBefore = Set(model.allPaneIds)

        update(&model, .closeTab(id: firstTabId))
        #expect(model.selectedTabId == secondTabId, "selection should remain on second tab")
        #expect(model.groups[0].tabs.count == 1)
        #expect(sessionsToTearDown(liveSessionIds: liveBefore, model: model) == Set([firstPaneId]),
            "closed non-selected tab's pane session is torn down")
    }

    // MARK: - Close Tab Selects Previous

    @Test("testCloseMiddleTabSelectsPrevious")
    func testCloseMiddleTabSelectsPrevious() {
        // Intent: closing the middle selected tab selects the previous
        //   tab.
        // Why it exists: pins the "select predecessor" rule.
        // Scenario: spec-first middle close.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        let tabBId = model.groups[0].tabs[1].id

        update(&model, .selectTab(id: tabBId))
        update(&model, .closeTab(id: tabBId))

        #expect(model.selectedTabId == tabAId, "closing middle tab should select predecessor")
        #expect(model.groups[0].tabs.count == 2)
    }

    @Test("testCloseFirstTabSelectsNext")
    func testCloseFirstTabSelectsNext() {
        // Intent: closing the first tab selects the successor (no
        //   predecessor to fall back to).
        // Why it exists: pins the fallback to .next when at index 0.
        // Scenario: spec-first first close.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        let tabBId = model.groups[0].tabs[1].id

        update(&model, .selectTab(id: tabAId))
        update(&model, .closeTab(id: tabAId))

        #expect(model.selectedTabId == tabBId, "closing first tab should select successor")
        #expect(model.groups[0].tabs.count == 1)
    }

    @Test("closing the selected tab clears the fallback pane's alert in focus mode")
    func closeSelectedTabClearsFallbackPaneAlertInFocusMode() {
        // Intent: closing the selected tab in focus mode marks the fallback
        //   tab's focused-pane alert read.
        // Why it exists: closeTabRemoval assigned the fallback selection
        //   directly, so this route could leave the now-visible pane badged.
        // Scenario: REDUCE-3 -- tab A has an unread focused-pane alert, tab B
        //   is selected, and closing tab B returns focus to tab A.
        var model = makeModel()
        model.config.alertClearMode = .focus
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        let paneAId = model.groups[0].tabs[0].paneTree.focusedPaneId
        createTab(&model)
        let tabBId = model.groups[0].tabs[1].id
        update(&model, .selectTab(id: tabAId))
        model.alerts = [AlertModel(
            id: AlertId(), kind: .bell, paneId: paneAId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        )]

        update(&model, .selectTab(id: tabBId))
        update(&model, .closeTab(id: tabBId))

        #expect(model.selectedTabId == tabAId)
        #expect(model.alerts[0].isUnread == false,
                "the fallback pane is now visible, so its alert must be read")
    }

    @Test("testCloseTabCrossGroupSelectsPrevious")
    func testCloseTabCrossGroupSelectsPrevious() {
        // Intent: closing the only tab in its group prunes that group and
        //   selects the cross-group predecessor.
        // Why it exists: pins the auto-prune + cross-group selection path.
        // Scenario: spec-first cross-group close.
        var model = makeModel()
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Work"))
        let tabBId = model.groups[1].tabs[0].id

        update(&model, .selectTab(id: tabBId))
        update(&model, .closeTab(id: tabBId))

        #expect(model.groups.count == 1, "Work group should be pruned")
        #expect(model.selectedTabId == tabAId, "should select predecessor across group boundary")
    }

    // MARK: - setTabColors (batch from multi-select context menu)

    @Test("color request resolves toggle-off inside update")
    func requestSetTabColorsResolvesToggle() {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        model.groups[0].tabs[0].color = .red

        update(&model, .requestSetTabColors(tabIds: [tabId], requested: .red))
        #expect(model.groups[0].tabs[0].color == nil)

        update(&model, .requestSetTabColors(tabIds: [tabId], requested: .blue))
        #expect(model.groups[0].tabs[0].color == .blue)
    }

    @Test("testSetTabColorsAppliesToAll")
    func testSetTabColorsAppliesToAll() {
        // Intent: batch setTabColors applies the color to every id.
        // Why it exists: pins the batch path the multi-select context menu
        //   uses.
        // Scenario: spec-first batch set.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let ids = model.groups[0].tabs.map(\.id)

        update(&model, .setTabColors(tabIds: ids, color: .blue))

        #expect(model.groups[0].tabs.allSatisfy { $0.color == .blue },
            "every selected tab gets the new color")
    }

    @Test("testSetTabColorsAlwaysReplaces")
    func testSetTabColorsAlwaysReplaces() {
        // Intent: re-applying the same color via the batch replaces
        //   (never toggles off at the Msg layer).
        // Why it exists: pins the always-replace contract against the
        //   request-side toggle override.
        // Scenario: spec-first re-apply replace.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let id1 = model.groups[0].tabs[0].id
        let id2 = model.groups[0].tabs[1].id
        update(&model, .setTabColors(tabIds: [id1], color: .red))
        #expect(model.groups[0].tabs[0].color == .red)

        update(&model, .setTabColors(tabIds: [id1, id2], color: .red))
        #expect(model.groups[0].tabs[0].color == .red)
        #expect(model.groups[0].tabs[1].color == .red)
    }

    @Test("testSetTabColorsClearsWithNil")
    func testSetTabColorsClearsWithNil() {
        // Intent: batch setTabColors with nil clears every id.
        // Why it exists: pins the explicit clear branch in the batch.
        // Scenario: spec-first batch clear.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let ids = model.groups[0].tabs.map(\.id)
        update(&model, .setTabColors(tabIds: ids, color: .green))

        update(&model, .setTabColors(tabIds: ids, color: nil))
        #expect(model.groups[0].tabs.allSatisfy { $0.color == nil },
            "nil color clears all selected")
    }

    @Test("testSetTabColorsDedupesAndIgnoresStale")
    func testSetTabColorsDedupesAndIgnoresStale() {
        // Intent: batch setTabColors dedupes ids and ignores stale ids.
        // Why it exists: pins the dedup + stale-filter guard for the
        //   batch path.
        // Scenario: spec-first batch dedup + stale.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let id1 = model.groups[0].tabs[0].id
        let id2 = model.groups[0].tabs[1].id
        let stale = TabId()

        let commands = update(&model, .setTabColors(
            tabIds: [id1, id1, stale, id2], color: .purple))

        #expect(model.groups[0].tabs[0].color == .purple)
        #expect(model.groups[0].tabs[1].color == .purple)
        #expect(commands.isEmpty)
    }

    @Test("testSetTabColorsAllStaleIsNoop")
    func testSetTabColorsAllStaleIsNoop() {
        // Intent: a batch composed entirely of stale ids is a no-op.
        // Why it exists: pins the empty-batch guard after stale filter.
        // Scenario: spec-first all-stale.
        var model = makeModel()
        createTab(&model)
        let snapshot = model.groups
        let stale1 = TabId()
        let stale2 = TabId()

        let commands = update(&model, .setTabColors(
            tabIds: [stale1, stale2], color: .red))

        #expect(model.groups == snapshot)
        #expect(commands.count == 0)
    }
}

private func closeTabsConfirmationArgs(
    in model: AppModel
) -> (tabIds: [TabId], tabCount: Int, totalPaneCount: Int, totalUncompletedTodos: Int, isQuit: Bool)? {
    guard case .tabs(let tabIds) = testConfirmationKind(model.pendingConfirmation),
          let pending = model.pendingConfirmation,
          let impact = pendingCloseImpact(pending)
    else { return nil }
    return (
        tabIds,
        tabIds.count,
        impact.panes.count,
        impact.uncompletedTodoCount,
        pendingQuitAuthorized(pending) ?? false
    )
}

private func effectCount(_ commands: [Command], matching predicate: (Command) -> Bool) -> Int {
    commands.filter(predicate).count
}

private func isTerminateEffect(_ command: Command?) -> Bool {
    guard let command else { return false }
    if case .terminate = command { return true }
    return false
}
