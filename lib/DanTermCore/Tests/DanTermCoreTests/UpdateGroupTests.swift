// Swift Testing migration of the legacy `tests/UpdateGroupTests.swift` harness
// suite. Pins the group-domain Msg paths: createGroup (auto-tab + focus),
// renameGroup (trim/empty rejection), reorderGroup, toggleGroupCollapse,
// deleteGroup (moveTabs vs close branches, last-group no-op), moveTabs (batch
// reorder rules, dedup + stale filter, intra-group offset math, auto-prune
// of empty source groups), extractTabsToNewGroup (selection preservation,
// dedup + stale, all-tab no-ops), and the auto-prune interactions with
// closeTab / movePaneToNewTab / sessionCreationFailed. The legacy harness
// had no compound `guard case` patterns in this file -- every assertion
// converts 1:1 with no Issue.record needed.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct UpdateGroupTests {
    @Test("interactive group creation requests one inline rename")
    func interactiveCreateRequestsRename() throws {
        var model = makeModel()
        createTab(&model)

        _ = update(&model, .createGroupInteractively(name: "New group"))

        let created = try #require(model.groups.last)
        #expect(model.sidebarRenameTarget == .group(created.id))
        _ = update(&model, .sidebarRenameEnded(session: try #require(model.sidebarRename).id))
        #expect(model.sidebarRenameTarget == nil)
    }

    @Test("domain group creation does not request inline rename")
    func domainCreateDoesNotRequestRename() {
        var model = makeModel()
        createTab(&model)

        _ = update(&model, .createGroup(name: "Domain group"))

        #expect(model.sidebarRenameTarget == nil)
    }

    @Test("interactive extraction requests rename only after creating a group")
    func interactiveExtractRequestsRename() throws {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let extractedId = model.groups[0].tabs[0].id

        _ = update(&model, .extractTabsToNewGroupInteractively(
            tabIds: [extractedId], groupName: "New group"))

        let created = try #require(model.groups.last)
        #expect(model.sidebarRenameTarget == .group(created.id))

        model.sidebarRename = nil
        let remainingIds = model.groups[0].tabs.map(\.id)
        _ = update(&model, .extractTabsToNewGroup(
            tabIds: [remainingIds[0]], groupName: "Domain group"))
        #expect(model.sidebarRenameTarget == nil)
    }

    @Test("requestDeleteGroup applies immediate, confirmation, and refusal policy")
    func requestDeleteGroupPolicy() throws {
        var emptyModel = makeModel()
        createTab(&emptyModel)
        let emptyId = GroupId()
        emptyModel.groups.append(GroupModel(id: emptyId, name: "Empty"))
        _ = update(&emptyModel, .requestDeleteGroup(id: emptyId))
        #expect(emptyModel.groups.contains { $0.id == emptyId } == false)
        #expect(emptyModel.pendingConfirmation == nil)

        var populatedModel = makeModel()
        createTab(&populatedModel)
        _ = update(&populatedModel, .createGroup(name: "Work"))
        let work = try #require(populatedModel.groups.first { $0.name == "Work" })
        let destination = populatedModel.groups[0]
        _ = update(&populatedModel, .requestDeleteGroup(id: work.id))
        let pending = try #require(populatedModel.pendingConfirmation)
        #expect(testConfirmationKind(pending) == .deleteGroup(work.id))
        #expect(pendingDeleteGroup(pending)?.tabIds == work.tabs.map(\.id))
        #expect(pendingDeleteGroup(pending)?.destinationGroupId == destination.id)
        #expect(desiredConfirmation(in: populatedModel)?.title == "Delete group \"Work\"?")
        let deleteGroup = try #require(desiredConfirmation(in: populatedModel))
        #expect(deleteGroup.confirm.title == "Close Tabs")
        #expect(deleteGroup.confirm.answer == .deleteGroup(moveTabs: false))
        #expect(deleteGroup.confirm.isDestructive == true)
        #expect(deleteGroup.cancel.answer == .cancel)
        #expect(deleteGroup.alternatives.count == 1)
        #expect(deleteGroup.alternatives.first?.title == "Move to group \"General\"")
        #expect(deleteGroup.alternatives.first?.answer == .deleteGroup(moveTabs: true))
        #expect(deleteGroup.alternatives.first?.isDestructive == false)

        var lastModel = makeModel()
        createTab(&lastModel)
        let lastId = lastModel.groups[0].id
        _ = update(&lastModel, .requestDeleteGroup(id: lastId))
        #expect(lastModel.groups.count == 1)
        #expect(lastModel.pendingConfirmation == nil)
    }

    @Test("stale delete-group choices cannot affect a replacement")
    func staleDeleteGroupChoicesCannotAffectReplacement() throws {
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .createGroup(name: "Work"))
        let workId = try #require(model.groups.first { $0.name == "Work" }?.id)
        _ = update(&model, .requestDeleteGroup(id: workId))
        let staleId = try #require(model.pendingConfirmation?.id)
        _ = update(&model, .requestQuit)
        let replacement = try #require(model.pendingConfirmation)

        #expect(update(&model, .answerConfirmation(id: staleId, answer: .deleteGroup(moveTabs: true))).isEmpty)
        #expect(model.pendingConfirmation == replacement)
        #expect(model.groups.contains { $0.id == workId })
        #expect(update(&model, .answerConfirmation(id: staleId, answer: .deleteGroup(moveTabs: false))).isEmpty)
        #expect(model.pendingConfirmation == replacement)
    }

    @Test("delete-group choice refreshes when the affected tab set grows")
    func deleteGroupChoiceRefreshesForGrowth() throws {
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .createGroup(name: "Work"))
        let workId = try #require(model.groups.first { $0.name == "Work" }?.id)
        _ = update(&model, .requestDeleteGroup(id: workId))
        let firstId = try #require(model.pendingConfirmation?.id)
        _ = update(&model, .createTab(inGroupId: workId))
        let currentIds = try #require(model.groups.first { $0.id == workId }?.tabs.map(\.id))

        _ = update(&model, .answerConfirmation(id: firstId, answer: .deleteGroup(moveTabs: false)))

        #expect(model.groups.contains { $0.id == workId })
        #expect(model.pendingConfirmation?.id != firstId)
        #expect(pendingDeleteGroup(model.pendingConfirmation)?.tabIds == currentIds)
    }

    @Test("delete-group destination refreshes if the frozen group disappears")
    func deleteGroupDestinationRefreshes() throws {
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .createGroup(name: "Work"))
        _ = update(&model, .createGroup(name: "Archive"))
        let generalId = model.groups[0].id
        let workId = model.groups[1].id
        let archiveId = model.groups[2].id
        _ = update(&model, .requestDeleteGroup(id: workId))
        let firstId = try #require(model.pendingConfirmation?.id)
        #expect(pendingDeleteGroup(model.pendingConfirmation)?.destinationGroupId == generalId)

        _ = update(&model, .deleteGroup(id: generalId, moveTabs: true))

        #expect(model.pendingConfirmation?.id != firstId)
        #expect(pendingDeleteGroup(model.pendingConfirmation)?.destinationGroupId == archiveId)
        #expect(
            desiredConfirmation(in: model)?.alternatives.first?.title
                == "Move to group \"Archive\"")
    }

    @Test("move choice uses the frozen destination after group reordering")
    func deleteGroupMoveUsesFrozenDestination() throws {
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .createGroup(name: "Work"))
        _ = update(&model, .createGroup(name: "Archive"))
        let generalId = model.groups[0].id
        let workId = model.groups[1].id
        let archiveId = model.groups[2].id
        let workTabIds = model.groups[1].tabs.map(\.id)
        _ = update(&model, .requestDeleteGroup(id: workId))
        let confirmationId = try #require(model.pendingConfirmation?.id)
        _ = update(&model, .reorderGroup(groupId: generalId, toIndex: 2))

        _ = update(&model, .answerConfirmation(id: confirmationId, answer: .deleteGroup(moveTabs: true)))

        #expect(model.groups.contains { $0.id == workId } == false)
        #expect(workTabIds.allSatisfy { tabId in
            model.groups.first { $0.id == generalId }?.tabs.contains { $0.id == tabId } == true
        })
        #expect(workTabIds.allSatisfy { tabId in
            model.groups.first { $0.id == archiveId }?.tabs.contains { $0.id == tabId } == false
        })
    }

    @Test("close choice deletes the requested group and its tabs")
    func deleteGroupCloseChoiceDeletesGroup() throws {
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .createGroup(name: "Work"))
        let work = try #require(model.groups.first { $0.name == "Work" })
        _ = update(&model, .requestDeleteGroup(id: work.id))
        let confirmationId = try #require(model.pendingConfirmation?.id)

        let commands = update(
            &model,
            .answerConfirmation(id: confirmationId, answer: .deleteGroup(moveTabs: false))
        )

        #expect(model.groups.contains { $0.id == work.id } == false)
        #expect(model.pendingConfirmation == nil)
        #expect(commands.isEmpty)
    }

    @Test("testCreateGroupAndMoveTab")
    func testCreateGroupAndMoveTab() {
        // Intent: createGroup adds a group with an auto-created tab; a
        //   subsequent moveTabs into it prunes the now-empty source.
        // Why it exists: pins the end-to-end "extract via moveTabs" flow.
        // Scenario: spec-first move + prune -- General with one tab,
        //   create Work, move the tab; General is pruned.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Work"))
        #expect(model.groups.count == 2)
        #expect(model.groups[1].name == "Work")
        #expect(model.groups[1].tabs.count == 1, "new group should have auto-created tab")

        let workGroupId = model.groups[1].id
        update(&model, .moveTabs(tabIds: [tabId], toGroupId: workGroupId, atIndex: 0))

        #expect(model.groups.count == 1, "empty General should be pruned")
        #expect(model.groups[0].id == workGroupId)
        #expect(model.groups[0].tabs.count == 2, "Work should have auto-created tab + moved tab")
        #expect(model.groups[0].tabs[0].id == tabId)
    }

    @Test("testDeleteGroupMovesTabs")
    func testDeleteGroupMovesTabs() {
        // Intent: deleteGroup(moveTabs: true) reparents tabs to the
        //   adjacent group rather than destroying them.
        // Why it exists: pins the moveTabs branch of deleteGroup.
        // Scenario: spec-first move-on-delete -- Temp with two tabs;
        //   delete with moveTabs=true reparents both to General.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tab1Id = model.groups[0].tabs[0].id
        let tab2Id = model.groups[0].tabs[1].id

        update(&model, .createGroup(name: "Temp"))
        let tempGroupId = model.groups[1].id
        let autoTabId = model.groups[1].tabs[0].id
        update(&model, .moveTabs(tabIds: [tab1Id], toGroupId: tempGroupId, atIndex: 0))

        #expect(model.groups[0].tabs.count == 1, "General should have 1 tab remaining")
        #expect(model.groups[1].tabs.count == 2, "Temp should have moved tab + auto tab")

        update(&model, .deleteGroup(id: tempGroupId, moveTabs: true))
        #expect(model.groups.count == 1, "only General should remain")
        #expect(model.groups[0].tabs.count == 3, "all tabs should be in General")
        #expect(model.groups[0].tabs.contains(where: { $0.id == tab1Id }), "moved tab should be in General")
        #expect(model.groups[0].tabs.contains(where: { $0.id == autoTabId }), "auto-created tab should be in General")
        #expect(model.groups[0].tabs.contains(where: { $0.id == tab2Id }), "original tab should be in General")
    }

    @Test("testDeleteFirstGroupMovesTabsToNext")
    func testDeleteFirstGroupMovesTabsToNext() {
        // Intent: deleting the first group moves its tabs to the next
        //   group (no wrap-around).
        // Why it exists: pins the direction the adjacent-group fallback
        //   resolves.
        // Scenario: spec-first first-group delete.
        var model = makeModel()
        createTab(&model)
        let generalId = model.groups[0].id
        let generalTabId = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Second"))

        update(&model, .deleteGroup(id: generalId, moveTabs: true))
        #expect(model.groups.count == 1, "only Second should remain")
        #expect(model.groups[0].name == "Second")
        #expect(model.groups[0].tabs.contains(where: { $0.id == generalTabId }), "tab should be moved to Second")
    }

    @Test("testDeleteGroupClosesTabs")
    func testDeleteGroupClosesTabs() {
        // Intent: deleteGroup(moveTabs: false) closes every tab in the
        //   deleted group; the session-existence net tears down every
        //   destroyed pane.
        // Why it exists: pins the destructive branch of deleteGroup.
        // Scenario: spec-first close-on-delete.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabId1 = model.groups[0].tabs[0].id
        let tabId2 = model.groups[0].tabs[1].id

        update(&model, .createGroup(name: "Temp"))
        let tempGroupId = model.groups[1].id

        update(&model, .moveTabs(tabIds: [tabId1], toGroupId: tempGroupId, atIndex: 0))

        let deletedPanes = Set(model.groups[1].tabs.flatMap { allPaneIds($0.paneTree.root) })
        let liveBefore = Set(model.allPaneIds)

        update(&model, .deleteGroup(id: tempGroupId, moveTabs: false))
        #expect(model.groups.count == 1, "only General should remain")
        #expect(sessionsToTearDown(liveSessionIds: liveBefore, model: model) == deletedPanes,
            "both deleted tabs' pane sessions are torn down")
        #expect(model.groups[0].tabs.count == 1)
        #expect(model.groups[0].tabs[0].id == tabId2)
    }

    @Test("deleting the selected tab's group selects the MRU-previous tab")
    func deleteGroupSelectsMruPreviousTab() throws {
        // Intent: when deleteGroup(moveTabs: false) destroys the selected tab,
        //   selection lands on the most recently used surviving tab, and
        //   mruOrder[0] agrees with it.
        // Why it exists: this branch used to jump to the first tab in
        //   flattened order, disagreeing with every other removal path.
        // Scenario: spec-first; General holds A and B, "Other" holds C, and C
        //   is selected last, so the MRU answer (B) and the flattened-first
        //   answer (A) differ.
        var model = makeModel()
        let generalId = model.groups[0].id
        createTab(&model, inGroupId: generalId)
        let tabA = try #require(model.selectedTabId)
        createTab(&model, inGroupId: generalId)
        let tabB = try #require(model.selectedTabId)
        update(&model, .createGroup(name: "Other"))
        let otherId = model.groups[1].id
        let tabC = try #require(model.selectedTabId)

        update(&model, .deleteGroup(id: otherId, moveTabs: false))

        #expect(tabById(tabC, in: model) == nil, "the deleted group's tab is gone")
        #expect(model.selectedTabId == tabB, "MRU-previous tab, not the first tab \(tabA)")
        #expect(model.mruOrder.first == tabB, "the repaired selection heads mruOrder")
    }

    @Test("testDeleteGroupShowsConfirmationIfLast")
    func testDeleteGroupShowsConfirmationIfLast() {
        // Intent: with auto-pruning of empty groups, deleting the sole
        //   remaining group is a no-op (the model invariant requires at
        //   least one group).
        // Why it exists: pins the auto-prune + last-group interaction.
        // Scenario: spec-first auto-prune + delete-last -- moveTabs empties
        //   General (pruned), then delete the only group remaining.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Only"))
        let onlyGroupId = model.groups[1].id
        update(&model, .moveTabs(tabIds: [tabId], toGroupId: onlyGroupId, atIndex: 0))

        #expect(model.groups.count == 1, "empty General should be pruned")
        #expect(model.groups[0].id == onlyGroupId)

        let commands = update(&model, .deleteGroup(id: onlyGroupId, moveTabs: false))
        #expect(commands.count == 0, "deleting sole group should be no-op")
        #expect(model.groups.count == 1, "model should be unchanged")
    }

    @Test("testDeleteLastGroupNoOp")
    func testDeleteLastGroupNoOp() {
        // Intent: deleting the only remaining group is a no-op even with
        //   moveTabs=true.
        // Why it exists: pins the same last-group invariant for the move
        //   branch.
        // Scenario: spec-first last-group move-delete.
        var model = makeModel()
        createTab(&model)
        let onlyGroupId = model.groups[0].id

        let commands = update(&model, .deleteGroup(id: onlyGroupId, moveTabs: true))
        #expect(commands.count == 0, "deleting last remaining group should be no-op")
        #expect(model.groups.count == 1)
    }

    @Test("testRenameGroup")
    func testRenameGroup() {
        // Intent: renameGroup updates the name without a side-effect command.
        // Why it exists: pins the model mutation.
        // Scenario: spec-first rename.
        var model = makeModel()
        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id

        let commands = update(&model, .renameGroup(id: workId, name: "Projects"))
        #expect(model.groups[1].name == "Projects")
        #expect(commands.isEmpty)
    }

    @Test("renameGroup rejects empty name")
    func renameGroupRejectsEmptyName() {
        // Intent: an empty name leaves the group untouched and emits no
        //   commands.
        // Why it exists: pins the validation guard.
        // Scenario: spec-first empty-name reject.
        var model = makeModel()
        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id

        let commands = update(&model, .renameGroup(id: workId, name: ""))
        #expect(model.groups[1].name == "Work", "name should be unchanged")
        #expect(commands.count == 0, "should emit no commands")
    }

    @Test("renameGroup rejects whitespace-only name")
    func renameGroupRejectsWhitespaceOnlyName() {
        // Intent: a whitespace-only name is treated as empty.
        // Why it exists: pins the trim-then-check rule.
        // Scenario: spec-first whitespace-only reject.
        var model = makeModel()
        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id

        let commands = update(&model, .renameGroup(id: workId, name: "   "))
        #expect(model.groups[1].name == "Work", "name should be unchanged")
        #expect(commands.count == 0, "should emit no commands")
    }

    @Test("renameGroup trims whitespace")
    func renameGroupTrimsWhitespace() {
        // Intent: leading/trailing whitespace is trimmed before assignment.
        // Why it exists: pins the trim rule.
        // Scenario: spec-first whitespace trim.
        var model = makeModel()
        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id

        update(&model, .renameGroup(id: workId, name: "  Projects  "))
        #expect(model.groups[1].name == "Projects")
    }

    @Test("testReorderGroup")
    func testReorderGroup() {
        // Intent: reorderGroup repositions a group without a side-effect command.
        // Why it exists: pins the reorder path.
        // Scenario: spec-first reorder -- [General, A, B] -> [General, B, A].
        var model = makeModel()
        update(&model, .createGroup(name: "A"))
        update(&model, .createGroup(name: "B"))
        let bGroupId = model.groups[2].id

        let commands = update(&model, .reorderGroup(groupId: bGroupId, toIndex: 1))
        #expect(model.groups[0].name == "General")
        #expect(model.groups[1].name == "B")
        #expect(model.groups[2].name == "A")
        #expect(commands.isEmpty)
    }

    @Test("testReorderGroupToIndex0")
    func testReorderGroupToIndex0() {
        // Intent: reorderGroup to index 0 promotes the group to the top.
        // Why it exists: pins the head-position reorder.
        // Scenario: spec-first reorder to top.
        var model = makeModel()
        update(&model, .createGroup(name: "A"))
        let aGroupId = model.groups[1].id

        let commands = update(&model, .reorderGroup(groupId: aGroupId, toIndex: 0))
        #expect(model.groups[0].name == "A", "A should be at index 0")
        #expect(model.groups[1].name == "General")
        #expect(commands.isEmpty)
    }

    @Test("testToggleGroupCollapse")
    func testToggleGroupCollapse() {
        // Intent: toggleGroupCollapse flips isCollapsed without a side-effect command.
        // Why it exists: pins the toggle pattern.
        // Scenario: spec-first toggle on then off.
        var model = makeModel()
        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id

        #expect(model.groups[1].isCollapsed == false)
        let effects1 = update(&model, .toggleGroupCollapse(groupId: workId))
        #expect(model.groups[1].isCollapsed == true)
        #expect(effects1.isEmpty)

        let effects2 = update(&model, .toggleGroupCollapse(groupId: workId))
        #expect(model.groups[1].isCollapsed == false)
        #expect(effects2.isEmpty)
    }

    @Test("testCreateGroupCreatesTabAndFocuses")
    func testCreateGroupCreatesTabAndFocuses() {
        // Intent: createGroup creates a tab in the new group and selects that tab; the
        //   tab's pane gets a createSession.
        // Why it exists: pins the auto-tab and selection contract.
        // Scenario: spec-first auto-tab + focus.
        var model = makeModel()
        createTab(&model)
        let oldSelectedTabId = model.selectedTabId

        let commands = update(&model, .createGroup(name: "Work"))
        let workGroup = model.groups[1]

        #expect(workGroup.tabs.count == 1, "new group should have one tab")
        let newTab = workGroup.tabs[0]
        #expect(model.selectedTabId == newTab.id, "new tab should be selected")
        #expect(model.selectedTabId != oldSelectedTabId, "selection should have changed")
        #expect(model.pane(newTab.paneTree.focusedPaneId) != nil, "pane should exist in model")

        #expect(hasEffect(commands) {
            if case .createSession = $0 { return true }
            return false
        }, "should emit createSession for the new tab's pane")
    }

    @Test("testMoveTabClampsIndex")
    func testMoveTabClampsIndex() {
        // Intent: moveTabs atIndex past the destination length clamps to
        //   append.
        // Why it exists: pins the clamp-to-end rule.
        // Scenario: spec-first end clamp.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Target"))
        let targetId = model.groups[1].id

        update(&model, .moveTabs(tabIds: [tabId], toGroupId: targetId, atIndex: 999))
        let targetGroup = model.groups.first(where: { $0.id == targetId })!
        #expect(targetGroup.tabs.count == 2, "should have auto-created tab + moved tab")
        #expect(targetGroup.tabs[1].id == tabId, "tab should land at clamped end index")
    }

    @Test("moveTab within same group adjusts for removal offset")
    func moveTabWithinSameGroupAdjustsForRemovalOffset() {
        // Intent: an intra-group move adjusts the atIndex for the removed
        //   source slot.
        // Why it exists: pins the off-by-one fix the outline-view dispatch
        //   relies on (drag from index 0 to "after B" lands at index 1).
        // Scenario: spec-first removal-offset.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let groupId = model.groups[0].id
        let a = model.groups[0].tabs[0].id
        let b = model.groups[0].tabs[1].id
        let c = model.groups[0].tabs[2].id

        update(&model, .moveTabs(tabIds: [a], toGroupId: groupId, atIndex: 2))
        #expect(model.groups[0].tabs[0].id == b, "B should be first")
        #expect(model.groups[0].tabs[1].id == a, "A should be second")
        #expect(model.groups[0].tabs[2].id == c, "C should be third")
    }

    @Test("moveTab with negative atIndex clamps to 0")
    func moveTabWithNegativeAtIndexClampsToZero() {
        // Intent: moveTabs atIndex < 0 clamps to 0 (prepend).
        // Why it exists: pins the clamp-to-start rule.
        // Scenario: spec-first negative clamp.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Target"))
        let targetId = model.groups[1].id

        update(&model, .moveTabs(tabIds: [tabId], toGroupId: targetId, atIndex: -1))
        let targetGroup = model.groups.first(where: { $0.id == targetId })!
        #expect(targetGroup.tabs[0].id == tabId, "tab should land at clamped index 0")
    }

    // MARK: - Auto-prune empty groups

    @Test("testCloseLastTabInGroupRemovesGroup")
    func testCloseLastTabInGroupRemovesGroup() {
        // Intent: closing the last tab in a group prunes that group.
        // Why it exists: pins the auto-prune-on-close rule.
        // Scenario: spec-first close-last-prune.
        var model = makeModel()
        createTab(&model)

        update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id

        let generalTabId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: generalTabId))
        update(&model, .closeTab(id: generalTabId))

        #expect(model.groups.count == 1, "empty General should be pruned")
        #expect(model.groups[0].id == workGroupId, "Work should remain")
        #expect(model.selectedTabId != nil, "some tab should be selected")
    }

    @Test("testMoveTabLeavingEmptyGroupRemovesIt")
    func testMoveTabLeavingEmptyGroupRemovesIt() {
        // Intent: moveTabs that empties the source group prunes it.
        // Why it exists: pins the auto-prune-on-move rule.
        // Scenario: spec-first move-prune.
        var model = makeModel()
        createTab(&model)

        update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id
        let generalTabId = model.groups[0].tabs[0].id

        update(&model, .moveTabs(tabIds: [generalTabId], toGroupId: workGroupId, atIndex: 0))

        #expect(model.groups.count == 1, "empty General should be pruned")
        #expect(model.groups[0].id == workGroupId)
        #expect(model.groups[0].tabs.count == 2, "Work should have both tabs")
    }

    @Test("testCloseTabInMultiTabGroupKeepsGroup")
    func testCloseTabInMultiTabGroupKeepsGroup() {
        // Intent: closing a tab in a multi-tab group does not prune the
        //   group.
        // Why it exists: pins the negative of the auto-prune rule.
        // Scenario: spec-first survives-with-others.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tab1Id = model.groups[0].tabs[0].id

        update(&model, .closeTab(id: tab1Id))

        #expect(model.groups.count == 1, "group should still exist")
        #expect(model.groups[0].tabs.count == 1, "one tab should remain")
    }

    @Test("testMovePaneToNewTabCrossGroupPrunesEmptyGroup")
    func testMovePaneToNewTabCrossGroupPrunesEmptyGroup() {
        // Intent: movePaneToNewTab into a different group can empty and
        //   prune the source group.
        // Why it exists: pins the auto-prune interaction with
        //   movePaneToNewTab.
        // Scenario: spec-first extract-prune.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id

        update(&model, .movePaneToNewTab(paneId: paneA, inGroupId: workGroupId, atIndex: 0))

        #expect(model.groups.count == 1, "empty General should be pruned")
        #expect(model.groups[0].id == workGroupId)
        #expect(model.groups[0].tabs.count == 2, "Work should have auto tab + moved tab")
        #expect(model.selectedTabId == model.groups[0].tabs[0].id, "moved tab should be selected")
    }

    @Test("testSessionCreationFailedPrunesEmptyGroup")
    func testSessionCreationFailedPrunesEmptyGroup() {
        // Intent: sessionCreationFailed on the only pane in the only tab
        //   of a group prunes that group; the model does NOT terminate
        //   because another group exists.
        // Why it exists: pins the auto-prune + survival path under
        //   session-creation failure.
        // Scenario: spec-first failure-prune.
        var model = makeModel()
        createTab(&model)

        update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id

        let generalTabId = model.groups[0].tabs[0].id
        let generalPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .selectTab(id: generalTabId))

        let sessionId = model.pane(generalPaneId)!.session!.id
        let commands = update(&model, .sessionCreationFailed(sessionId: sessionId))

        #expect(model.groups.count == 1, "empty General should be pruned")
        #expect(model.groups[0].id == workGroupId, "Work should remain")
        #expect(!hasEffect(commands) {
            if case .terminate = $0 { return true }
            return false
        }, "should not terminate -- Work group has tabs")
    }

    @Test("testExtractSingleTabToNewGroup")
    func testExtractSingleTabToNewGroup() {
        // Intent: extractTabsToNewGroup with one id creates the new group
        //   carrying that tab; the source group survives if it still has
        //   tabs.
        // Why it exists: pins the single-tab extract path.
        // Scenario: spec-first single extract.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tab1Id = model.groups[0].tabs[0].id

        let commands = update(&model, .extractTabsToNewGroup(
            tabIds: [tab1Id], groupName: "Extracted"))

        #expect(model.groups.count == 2, "source group should survive (still has tab2)")
        #expect(model.groups[1].name == "Extracted")
        #expect(model.groups[1].tabs.count == 1)
        #expect(model.groups[1].tabs[0].id == tab1Id)
        #expect(model.groups[0].tabs.count == 1, "source has tab2 left")

        #expect(commands.isEmpty)
    }

    @Test("testExtractMultipleTabsSameGroup")
    func testExtractMultipleTabsSameGroup() {
        // Intent: extracting two tabs from one group preserves input
        //   order in the new group.
        // Why it exists: pins the order-preservation rule of the extract
        //   path.
        // Scenario: spec-first multi extract.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let tab1Id = model.groups[0].tabs[0].id
        let tab2Id = model.groups[0].tabs[1].id

        let commands = update(&model, .extractTabsToNewGroup(
            tabIds: [tab1Id, tab2Id], groupName: "Extracted"))

        #expect(model.groups.count == 2)
        #expect(model.groups[1].tabs.count == 2)
        #expect(model.groups[1].tabs[0].id == tab1Id, "order preserved")
        #expect(model.groups[1].tabs[1].id == tab2Id, "order preserved")
        #expect(model.groups[0].tabs.count == 1, "tab3 left in source")
        #expect(commands.isEmpty)
    }

    @Test("testExtractMultipleTabsAcrossGroups")
    func testExtractMultipleTabsAcrossGroups() {
        // Intent: extracting tabs from two different groups can prune one
        //   of them; the new group still gets both tabs in input order.
        // Why it exists: pins the cross-group extract + prune contract.
        // Scenario: spec-first cross-group extract.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let general1 = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Work"))
        let workAuto = model.groups[1].tabs[0].id

        let commands = update(&model, .extractTabsToNewGroup(
            tabIds: [general1, workAuto], groupName: "Extracted"))

        #expect(model.groups.count == 2, "Work pruned, General + Extracted remain")
        #expect(model.groups[0].name == "General")
        #expect(model.groups[1].name == "Extracted")
        #expect(model.groups[1].tabs.count == 2)
        #expect(model.groups[1].tabs[0].id == general1, "input order preserved")
        #expect(model.groups[1].tabs[1].id == workAuto, "input order preserved")
        #expect(commands.isEmpty)
    }

    @Test("testExtractAllTabsFromOnlyGroupIsNoop")
    func testExtractAllTabsFromOnlyGroupIsNoop() {
        // Intent: extracting every tab from the only group is a no-op
        //   (would require destroying the source).
        // Why it exists: pins the destroy-source guard.
        // Scenario: spec-first all-from-only.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tab1Id = model.groups[0].tabs[0].id
        let tab2Id = model.groups[0].tabs[1].id
        let snapshot = model.groups

        let commands = update(&model, .extractTabsToNewGroup(
            tabIds: [tab1Id, tab2Id], groupName: "Extracted"))

        #expect(model.groups.count == 1, "no new group created")
        #expect(model.groups == snapshot, "model.groups unchanged")
        #expect(commands.count == 0, "no-op should emit no commands")
    }

    @Test("testExtractAllTabsAcrossMultipleGroupsIsNoop")
    func testExtractAllTabsAcrossMultipleGroupsIsNoop() {
        // Intent: extracting every live tab across multiple groups is a
        //   no-op (no group survives).
        // Why it exists: pins the symmetric guard for the cross-group
        //   case.
        // Scenario: spec-first all-across.
        var model = makeModel()
        createTab(&model)
        let generalTabId = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Work"))
        let workTabId = model.groups[1].tabs[0].id

        let snapshotCount = model.groups.count
        let commands = update(&model, .extractTabsToNewGroup(
            tabIds: [generalTabId, workTabId], groupName: "Extracted"))

        #expect(model.groups.count == snapshotCount,
            "no group destruction; structure preserved")
        #expect(commands.count == 0, "no-op should emit no commands")
    }

    @Test("testExtractDedupesAndIgnoresStaleIds")
    func testExtractDedupesAndIgnoresStaleIds() {
        // Intent: extractTabsToNewGroup dedupes ids and ignores stale
        //   ids; only valid ids are extracted in input order.
        // Why it exists: pins the dedup + stale-filter rule.
        // Scenario: spec-first extract dedup.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let tab1Id = model.groups[0].tabs[0].id
        let tab2Id = model.groups[0].tabs[1].id
        let stale = TabId()

        let commands = update(&model, .extractTabsToNewGroup(
            tabIds: [tab1Id, tab1Id, stale, tab2Id], groupName: "Extracted"))

        #expect(model.groups.count == 2)
        #expect(model.groups[1].tabs.count == 2, "duplicate dropped, stale dropped")
        #expect(model.groups[1].tabs[0].id == tab1Id)
        #expect(model.groups[1].tabs[1].id == tab2Id)
        #expect(commands.isEmpty)
    }

    @Test("testExtractAllStaleIdsIsNoop")
    func testExtractAllStaleIdsIsNoop() {
        // Intent: a batch of only stale ids is a no-op.
        // Why it exists: pins the empty-after-filter guard.
        // Scenario: spec-first all-stale extract.
        var model = makeModel()
        createTab(&model)
        let snapshot = model.groups
        let stale1 = TabId()
        let stale2 = TabId()

        let commands = update(&model, .extractTabsToNewGroup(
            tabIds: [stale1, stale2], groupName: "Extracted"))

        #expect(model.groups == snapshot, "no group created when all ids stale")
        #expect(commands.count == 0)
    }

    @Test("testExtractPreservesSelectedTabIdWhenFocusedTabIsExtracted")
    func testExtractPreservesSelectedTabIdWhenFocusedTabIsExtracted() {
        // Intent: extracting the focused tab keeps selection on that tab
        //   (it still exists, just under a new group).
        // Why it exists: pins the "selection survives extraction" rule
        //   for the focused-tab branch.
        // Scenario: spec-first focused extract.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let focusedId = model.selectedTabId
        #expect(focusedId != nil)

        update(&model, .extractTabsToNewGroup(
            tabIds: [focusedId!], groupName: "Extracted"))

        #expect(model.selectedTabId == focusedId,
            "selection must not move when the focused tab is extracted")
    }

    @Test("testExtractPreservesSelectedTabIdWhenOtherTabIsExtracted")
    func testExtractPreservesSelectedTabIdWhenOtherTabIsExtracted() {
        // Intent: extracting a non-focused tab leaves selection alone.
        // Why it exists: pins the symmetric rule for the other-tab
        //   branch.
        // Scenario: spec-first non-focused extract.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let focusedId = model.selectedTabId
        let otherId = model.groups[0].tabs[0].id

        update(&model, .extractTabsToNewGroup(
            tabIds: [otherId], groupName: "Extracted"))

        #expect(model.selectedTabId == focusedId,
            "selection must not move when an unrelated tab is extracted")
    }

    // MARK: - moveTabs (batch drag)

    @Test("testMoveTabsCrossGroup")
    func testMoveTabsCrossGroup() {
        // Intent: moveTabs across groups inserts the batch at atIndex in the destination,
        //   preserving input order without a side-effect command.
        // Why it exists: pins the cross-group batch contract.
        // Scenario: spec-first cross-group batch.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let a0 = model.groups[0].tabs[0].id
        let a1 = model.groups[0].tabs[1].id

        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id
        let b0 = model.groups[1].tabs[0].id

        let commands = update(&model, .moveTabs(
            tabIds: [a0, a1], toGroupId: workId, atIndex: 1))

        #expect(model.groups.count == 2)
        #expect(model.groups[0].name == "General")
        #expect(model.groups[0].tabs.count == 1, "a2 left in General")
        #expect(model.groups[1].tabs.count == 3, "Work has b0 + moved a0,a1")
        #expect(model.groups[1].tabs[0].id == b0)
        #expect(model.groups[1].tabs[1].id == a0, "input order preserved")
        #expect(model.groups[1].tabs[2].id == a1, "input order preserved")

        #expect(commands.isEmpty)
    }

    @Test("testMoveTabsIntraGroupShiftDown")
    func testMoveTabsIntraGroupShiftDown() {
        // Intent: moveTabs intra-group, where the batch moves down past
        //   intervening tabs, produces the documented order.
        // Why it exists: pins the down-shift case of intra-group moveTabs.
        // Scenario: spec-first down-shift -- [a0,a1,a2,a3] move {a1,a2}
        //   to index 4 -> [a0,a3,a1,a2].
        var model = makeModel()
        for _ in 0..<4 { createTab(&model) }
        let groupId = model.groups[0].id
        let ids = model.groups[0].tabs.map(\.id)
        let a0 = ids[0]; let a1 = ids[1]; let a2 = ids[2]; let a3 = ids[3]

        update(&model, .moveTabs(tabIds: [a1, a2], toGroupId: groupId, atIndex: 4))

        let final = model.groups[0].tabs.map(\.id)
        #expect(final == [a0, a3, a1, a2])
    }

    @Test("testMoveTabsIntraGroupShiftUp")
    func testMoveTabsIntraGroupShiftUp() {
        // Intent: moveTabs intra-group, moving up to index 0 (prepend).
        // Why it exists: pins the up-shift case.
        // Scenario: spec-first up-shift -- [a0,a1,a2,a3] move {a2,a3} to
        //   index 0 -> [a2,a3,a0,a1].
        var model = makeModel()
        for _ in 0..<4 { createTab(&model) }
        let groupId = model.groups[0].id
        let ids = model.groups[0].tabs.map(\.id)
        let a0 = ids[0]; let a1 = ids[1]; let a2 = ids[2]; let a3 = ids[3]

        update(&model, .moveTabs(tabIds: [a2, a3], toGroupId: groupId, atIndex: 0))

        let final = model.groups[0].tabs.map(\.id)
        #expect(final == [a2, a3, a0, a1])
    }

    @Test("testMoveTabsIntraGroupAnchorBetweenSelected")
    func testMoveTabsIntraGroupAnchorBetweenSelected() {
        // Intent: moveTabs intra-group with an anchor index between
        //   selected items adjusts atIndex for elements removed before it.
        // Why it exists: pins the offset-correction math.
        // Scenario: spec-first anchor-between -- [a,b,c,d] move {a,c} to
        //   index 3 -> [b,a,c,d].
        var model = makeModel()
        for _ in 0..<4 { createTab(&model) }
        let groupId = model.groups[0].id
        let ids = model.groups[0].tabs.map(\.id)
        let a = ids[0]; let b = ids[1]; let c = ids[2]; let d = ids[3]

        update(&model, .moveTabs(tabIds: [a, c], toGroupId: groupId, atIndex: 3))

        let final = model.groups[0].tabs.map(\.id)
        #expect(final == [b, a, c, d])
    }

    @Test("testMoveTabsCrossGroupEmptiesSourceAndPrunes")
    func testMoveTabsCrossGroupEmptiesSourceAndPrunes() {
        // Intent: a cross-group moveTabs that empties the source prunes
        //   the source group.
        // Why it exists: pins the auto-prune-on-batch-move interaction.
        // Scenario: spec-first batch-move + prune.
        var model = makeModel()
        createTab(&model)
        let generalTab = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id
        let workTab = model.groups[1].tabs[0].id

        update(&model, .moveTabs(tabIds: [generalTab], toGroupId: workId, atIndex: 1))

        #expect(model.groups.count == 1, "empty General pruned")
        #expect(model.groups[0].id == workId)
        #expect(model.groups[0].tabs.map(\.id) == [workTab, generalTab])
    }

    @Test("testMoveTabsDedupesAndIgnoresStaleIds")
    func testMoveTabsDedupesAndIgnoresStaleIds() {
        // Intent: moveTabs dedupes ids and ignores stale ids; live ids
        //   move in input order.
        // Why it exists: pins the dedup + stale-filter rule for the
        //   batch move.
        // Scenario: spec-first move dedup.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let a0 = model.groups[0].tabs[0].id
        let a1 = model.groups[0].tabs[1].id

        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id
        let workAuto = model.groups[1].tabs[0].id
        let stale = TabId()

        update(&model, .moveTabs(
            tabIds: [a0, a0, stale, a1], toGroupId: workId, atIndex: 1))

        #expect(model.groups[0].tabs.count == 1, "a2 left in General")
        #expect(model.groups[1].tabs.map(\.id) == [workAuto, a0, a1],
            "duplicate + stale dropped; rest moved in order")
    }

    @Test("testMoveTabsAllStaleIdsIsNoop")
    func testMoveTabsAllStaleIdsIsNoop() {
        // Intent: an all-stale batch is a no-op.
        // Why it exists: pins the empty-after-filter guard for moveTabs.
        // Scenario: spec-first all-stale move.
        var model = makeModel()
        createTab(&model)
        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id
        let snapshot = model.groups
        let stale1 = TabId()
        let stale2 = TabId()

        let commands = update(&model, .moveTabs(
            tabIds: [stale1, stale2], toGroupId: workId, atIndex: 0))

        #expect(model.groups == snapshot, "groups unchanged")
        #expect(commands.count == 0)
    }

    @Test("testMoveTabsClampedAtIndex")
    func testMoveTabsClampedAtIndex() {
        // Intent: moveTabs clamps both past-end and negative atIndex
        //   values.
        // Why it exists: pins the bidirectional clamp.
        // Scenario: spec-first clamp both directions -- past-end appends,
        //   then negative prepends.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let a0 = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id
        let workAuto = model.groups[1].tabs[0].id

        update(&model, .moveTabs(
            tabIds: [a0], toGroupId: workId, atIndex: 999))
        #expect(model.groups[1].tabs.map(\.id) == [workAuto, a0],
            "past-end atIndex clamps to append")

        update(&model, .moveTabs(
            tabIds: [a0], toGroupId: workId, atIndex: -5))
        #expect(model.groups[1].tabs.map(\.id) == [a0, workAuto],
            "negative atIndex clamps to 0")
    }
}
