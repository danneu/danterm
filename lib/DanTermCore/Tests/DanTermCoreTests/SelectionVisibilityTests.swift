// Pins the rule that the selected tab always has a visible sidebar row: when the
// selection comes to sit in a collapsed group, that group expands. Every path
// that can put the selection inside a collapsed group is covered here -- close
// fallback, explicit selection, a tab moved under a stationary selection,
// reconcile's MRU repair, and restore -- plus the negative case that an
// unrelated collapsed group is left alone.
//
// The opposite boundary ("an explicit collapse of the group holding the
// selection still collapses it") belongs to testToggleGroupCollapse in
// UpdateGroupTests, not here.
import Foundation
import Testing

@testable import DanTermCore

@Suite("Selection visibility")
struct SelectionVisibilityTests {

    @Test("closing the selected tab expands the group its fallback lands in")
    func closeFallbackIntoCollapsedGroupExpands() throws {
        // Intent: when the close fallback selects a tab inside a collapsed
        //   group, that group ends up expanded with the fallback selected.
        // Why it exists: the reported symptom -- the sidebar showed no
        //   selected row at all, because the selected tab had no row.
        // Scenario: General holds the selected tab; Work is collapsed with
        //   two tabs; closing the General tab falls through to Work.
        var model = makeModel()
        createTab(&model)
        let generalTabId = model.groups[0].tabs[0].id
        update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id
        let firstWorkTabId = model.groups[1].tabs[0].id
        createTab(&model)
        update(&model, .selectTab(id: generalTabId))
        update(&model, .toggleGroupCollapse(groupId: workGroupId))

        update(&model, .closeTab(id: generalTabId))

        #expect(model.selectedTabId == firstWorkTabId)
        let work = try #require(model.groups.first { $0.id == workGroupId })
        #expect(work.isCollapsed == false, "the fallback's group should expand")
    }

    @Test("selecting a tab in a collapsed group expands it")
    func selectTabIntoCollapsedGroupExpands() {
        // Intent: .selectTab into a collapsed group expands that group.
        // Why it exists: `danterm focus` / `danterm pane focus` and the MRU
        //   cycle commit all reduce to .selectTab, so this covers them.
        // Scenario: collapse Work, select General, then select Work's tab.
        var model = makeModel()
        createTab(&model)
        let generalTabId = model.groups[0].tabs[0].id
        update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id
        let workTabId = model.groups[1].tabs[0].id
        update(&model, .selectTab(id: generalTabId))
        update(&model, .toggleGroupCollapse(groupId: workGroupId))

        update(&model, .selectTab(id: workTabId))

        #expect(model.selectedTabId == workTabId)
        #expect(model.groups[1].isCollapsed == false)
    }

    @Test("moving the selected tab into a collapsed group expands it")
    func moveSelectedTabIntoCollapsedGroupExpands() throws {
        // Intent: relocating the selected tab into a collapsed group expands
        //   the destination, even though selectedTabId never changes.
        // Why it exists: this is the sidebar drag of the selected tab. It
        //   fails if the transition is keyed on the tab id alone rather than
        //   on the (tab, group) pair.
        // Scenario: select a General tab, then .moveTabs it into collapsed
        //   Work.
        var model = makeModel()
        createTab(&model)
        let generalTabId = model.groups[0].tabs[0].id
        createTab(&model)
        update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id
        update(&model, .selectTab(id: generalTabId))
        update(&model, .toggleGroupCollapse(groupId: workGroupId))

        update(&model, .moveTabs(tabIds: [generalTabId], toGroupId: workGroupId, atIndex: 0))

        #expect(model.selectedTabId == generalTabId, "the selection did not change tabs")
        let work = try #require(model.groups.first { $0.id == workGroupId })
        #expect(work.isCollapsed == false, "the destination group should expand")
    }

    @Test("reconcile's MRU repair into a collapsed group expands it")
    func reconcileRepairIntoCollapsedGroupExpands() throws {
        // Intent: when reconcileTabState repairs a dead selection to an MRU
        //   survivor inside a collapsed group, that group expands.
        // Why it exists: this is the path that fails if expansion runs before
        //   tab reconciliation instead of after it.
        // Scenario: sessionCreationFailed removes the selected tab's whole
        //   tab without naming a replacement, so reconcile picks one.
        var model = makeModel()
        createTab(&model)
        let generalTabId = model.groups[0].tabs[0].id
        update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id
        let workTabId = model.groups[1].tabs[0].id
        update(&model, .selectTab(id: generalTabId))
        update(&model, .toggleGroupCollapse(groupId: workGroupId))

        let generalPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        let sessionId = model.pane(generalPaneId)!.session!.id
        update(&model, .sessionCreationFailed(sessionId: sessionId))

        #expect(model.selectedTabId == workTabId)
        let work = try #require(model.groups.first { $0.id == workGroupId })
        #expect(work.isCollapsed == false, "the repaired selection's group should expand")
    }

    @Test("an unrelated collapsed group stays collapsed")
    func unrelatedCollapsedGroupIsUntouched() {
        // Intent: the rule expands only the group that holds the selection.
        // Why it exists: guards against a blanket "expand everything on a
        //   selection change", which would throw away the user's collapses.
        // Scenario: Archive is collapsed while the selection moves between
        //   General and Work.
        var model = makeModel()
        createTab(&model)
        let generalTabId = model.groups[0].tabs[0].id
        update(&model, .createGroup(name: "Work"))
        let workTabId = model.groups[1].tabs[0].id
        update(&model, .createGroup(name: "Archive"))
        let archiveGroupId = model.groups[2].id
        update(&model, .selectTab(id: generalTabId))
        update(&model, .toggleGroupCollapse(groupId: archiveGroupId))

        update(&model, .selectTab(id: workTabId))

        #expect(model.selectedTabId == workTabId)
        #expect(model.groups[2].isCollapsed == true, "Archive holds no selection")
    }

    @Test("restore expands the group holding the restored selection")
    func restoreExpandsTheSelectionsGroup() {
        // Intent: a snapshot whose selectedTabId names a tab in a group saved
        //   collapsed restores with that group expanded, other collapsed
        //   groups untouched.
        // Why it exists: restore does not pass through update(), so it has to
        //   normalize on its own; otherwise the app opens with no visible
        //   selected row.
        // Scenario: hand-collapse Work and Archive on the model, point the
        //   selection at Work's tab, round-trip through the snapshot.
        var model = makeModel()
        createTab(&model)
        update(&model, .createGroup(name: "Work"))
        let workTabId = model.groups[1].tabs[0].id
        update(&model, .createGroup(name: "Archive"))
        model.groups[1].isCollapsed = true
        model.groups[2].isCollapsed = true
        model.selectedTabId = workTabId

        let rebuilt = validateAndBuild(toSnapshot(model))!

        #expect(rebuilt.selectedTabId == workTabId)
        #expect(rebuilt.groups[1].isCollapsed == false, "Work holds the selection")
        #expect(rebuilt.groups[2].isCollapsed == true, "Archive holds no selection")
    }
}
