// Pins the sidebar store's outline-mutation contract and row identity invariants.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct SidebarItemStoreTests {
    @Test("valid row ops return complete outline mutations")
    func validRowOpsReturnCompleteOutlineMutations() throws {
        let groupA = GroupId()
        let groupB = GroupId()
        let tabA = TabId()
        let tabB = TabId()
        var model = sidebarStoreModel([
            (groupA, "A", [tabA]),
            (groupB, "B", [tabB]),
        ], selected: tabA)
        model.groups[1].isCollapsed = true
        let projection = desiredSidebar(in: model)
        var store = SidebarItemStore()

        let reloadAll = store.apply(.reloadAll, projection: projection)
        guard case .reloadAll(let collapseStates) = reloadAll else {
            Issue.record("reloadAll should return a full outline reload")
            return
        }
        #expect(collapseStates.count == 2)
        #expect(collapseStates[0].item === store.groupItemCache[groupA])
        #expect(!collapseStates[0].collapsed)
        #expect(collapseStates[1].item === store.groupItemCache[groupB])
        #expect(collapseStates[1].collapsed)

        model.groups[0].name = "Renamed"
        model.groups[0].isCollapsed = true
        model.groups[0].tabs[0].customTitle = "Custom"
        let updatedProjection = desiredSidebar(in: model)

        let reloadGroup = store.apply(.reloadGroup(id: groupA), projection: updatedProjection)
        let repaintedGroup = try requireRepaint(reloadGroup)
        #expect(repaintedGroup === store.groupItemCache[groupA])
        guard case .group(let updatedGroup) = repaintedGroup.kind else {
            Issue.record("reloadGroup should return a group item")
            return
        }
        #expect(updatedGroup.rendered.name == DisplayLine("Renamed"))

        let setCollapsed = store.apply(
            .setGroupCollapsed(id: groupA, collapsed: true),
            projection: updatedProjection)
        guard case .setGroupCollapsed(let collapsedItem, let collapsed) = setCollapsed else {
            Issue.record("setGroupCollapsed should return a collapse mutation")
            return
        }
        #expect(collapsedItem === store.groupItemCache[groupA])
        #expect(collapsed)

        let reloadTab = store.apply(.reloadTab(id: tabA), projection: updatedProjection)
        let repaintedTab = try requireRepaint(reloadTab)
        #expect(repaintedTab === store.tabItemCache[tabA])
        guard case .tab(let updatedTab) = repaintedTab.kind else {
            Issue.record("reloadTab should return a tab item")
            return
        }
        #expect(updatedTab.hasCustomTitle)
    }

    @Test("structural row ops return their item parent and running index")
    func structuralRowOpsReturnItemParentAndIndex() throws {
        let groupA = GroupId()
        let groupB = GroupId()
        let tabA = TabId()
        let tabB = TabId()
        let tabC = TabId()
        let oldModel = sidebarStoreModel([
            (groupA, "A", [tabA]),
            (groupB, "B", [tabB]),
        ], selected: tabA)
        var store = seedSidebarStore(oldModel)

        var insertedModel = sidebarStoreModel([
            (groupA, "A", [tabA, tabC]),
            (groupB, "B", [tabB]),
        ], selected: tabA)
        var projection = desiredSidebar(in: insertedModel)
        let insertTab = store.apply(
            .insertTab(id: tabC, groupId: groupA, index: 1),
            projection: projection)
        let insertedTab = try requireInsert(insertTab, at: 1, parent: store.groupItemCache[groupA])
        #expect(insertedTab === store.tabItemCache[tabC])

        let removeTab = store.apply(
            .removeTab(groupId: groupA, index: 0),
            projection: projection)
        let removedTab = try requireRemove(removeTab, at: 0, parent: store.groupItemCache[groupA])
        guard case .tab(let removedTabProjection) = removedTab.kind else {
            Issue.record("removeTab should return a tab item")
            return
        }
        #expect(removedTabProjection.id == tabA)

        let groupC = GroupId()
        insertedModel.groups.append(GroupModel(
            id: groupC,
            name: "C",
            isCollapsed: true,
            tabs: [sidebarStoreTab(TabId())]))
        projection = desiredSidebar(in: insertedModel)
        let insertGroup = store.apply(
            .insertGroup(id: groupC, index: 2),
            projection: projection)
        let insertedGroup = try requireInsert(insertGroup, at: 2, parent: nil)
        #expect(insertedGroup === store.groupItemCache[groupC])
        guard case .insert(_, _, _, let collapseState) = insertGroup else {
            Issue.record("insertGroup should return an insert mutation")
            return
        }
        #expect(collapseState?.item === insertedGroup)
        #expect(collapseState?.collapsed == true)

        let removeGroup = store.apply(.removeGroup(index: 1), projection: projection)
        let removedGroup = try requireRemove(removeGroup, at: 1, parent: nil)
        guard case .group(let removedGroupProjection) = removedGroup.kind else {
            Issue.record("removeGroup should return a group item")
            return
        }
        #expect(removedGroupProjection.id == groupB)

        let singleGroup = GroupId()
        let singleTabA = TabId()
        let singleTabB = TabId()
        let singleOldModel = sidebarStoreModel([
            (singleGroup, "Single", [singleTabA]),
        ], selected: singleTabA)
        var singleStore = seedSidebarStore(singleOldModel)
        let singleNewModel = sidebarStoreModel([
            (singleGroup, "Single", [singleTabA, singleTabB]),
        ], selected: singleTabA)
        let singleProjection = desiredSidebar(in: singleNewModel)

        let insertRootTab = singleStore.apply(
            .insertTab(id: singleTabB, groupId: singleGroup, index: 1),
            projection: singleProjection)
        _ = try requireInsert(insertRootTab, at: 1, parent: nil)
        let removeRootTab = singleStore.apply(
            .removeTab(groupId: singleGroup, index: 0),
            projection: singleProjection)
        _ = try requireRemove(removeRootTab, at: 0, parent: nil)
    }

    @Test("unappliable row ops rebuild the store from the handed projection")
    func unappliableRowOpsRebuildStoreFromProjection() throws {
        let groupA = GroupId()
        let groupB = GroupId()
        let tabA = TabId()
        let tabB = TabId()
        let oldModel = sidebarStoreModel([
            (groupA, "A", [tabA]),
            (groupB, "B", [tabB]),
        ], selected: tabA)
        let replacement = TabId()
        let newModel = sidebarStoreModel([
            (groupA, "Renamed", [tabA, replacement]),
            (groupB, "B", [tabB]),
        ], selected: replacement)
        let projection = desiredSidebar(in: newModel)

        let rejectedOps: [SidebarRowOp] = [
            .insertGroup(id: GroupId(), index: 0),
            .insertGroup(id: groupA, index: 99),
            .insertTab(id: TabId(), groupId: groupA, index: 0),
            .insertTab(id: tabA, groupId: GroupId(), index: 0),
            .insertTab(id: tabA, groupId: groupA, index: 99),
            .removeGroup(index: 99),
            .removeTab(groupId: GroupId(), index: 0),
            .removeTab(groupId: groupA, index: 99),
            .reloadGroup(id: GroupId()),
            .setGroupCollapsed(id: GroupId(), collapsed: true),
            .setGroupCollapsed(id: groupA, collapsed: true),
            .reloadTab(id: TabId()),
        ]
        for op in rejectedOps {
            var store = seedSidebarStore(oldModel)
            _ = try requireReloadAll(store.apply(op, projection: projection))
            try assertSidebarStoreMatchesProjection(store, projection: projection)
        }

        let singleOldModel = sidebarStoreModel([
            (groupA, "A", [tabA]),
        ], selected: tabA)
        let singleReplacement = TabId()
        let singleNewModel = sidebarStoreModel([
            (groupA, "Renamed", [singleReplacement]),
        ], selected: singleReplacement)
        let singleProjection = desiredSidebar(in: singleNewModel)
        let wrongModeOps: [SidebarRowOp] = [
            .insertGroup(id: groupA, index: 0),
            .removeGroup(index: 0),
        ]
        for op in wrongModeOps {
            var singleStore = seedSidebarStore(singleOldModel)
            _ = try requireReloadAll(singleStore.apply(op, projection: singleProjection))
            try assertSidebarStoreMatchesProjection(singleStore, projection: singleProjection)
        }
    }

    @Test("single-group identity replacement updates the mounted tabs")
    func singleGroupIdentityReplacementUpdatesMountedTabs() {
        // Intent: applying the computed diff for a lone-group replacement mounts
        //   the replacement group's tabs and removes the old group's tabs.
        // Why it exists: MODEL-2 found that the diff emitted hidden group-row ops,
        //   which the store refused and left the outline permanently stale.
        // Scenario: single-group G1 with t1 is replaced by G2 with t2.
        let oldGroup = GroupId()
        let oldTab = TabId()
        let oldModel = sidebarStoreModel([
            (oldGroup, "Old", [oldTab]),
        ], selected: oldTab)
        let oldProjection = desiredSidebar(in: oldModel)
        var store = seedSidebarStore(oldModel)

        let newGroup = GroupId()
        let newTab = TabId()
        let newModel = sidebarStoreModel([
            (newGroup, "New", [newTab]),
        ], selected: newTab)
        let newProjection = desiredSidebar(in: newModel)

        store.apply(
            computeSidebarRowOps(old: oldProjection, new: newProjection),
            projection: newProjection)

        #expect(store.displayedTabItem(newTab) != nil)
        #expect(store.displayedTabItem(oldTab) == nil)
    }

    @Test("later group to earlier group move keeps moved tab cache pointed at displayed item")
    func laterToEarlierGroupMoveKeepsCacheCurrent() throws {
        // Intent: moving a tab from a later group to an earlier group
        //   keeps the moved tab's cache pointed at its displayed row.
        // Why it exists: pins the cross-group cache-identity invariant.
        // Scenario: spec-first cross-group move.
        let groupA = GroupId()
        let groupB = GroupId()
        let groupC = GroupId()
        let first = TabId()
        let middle = TabId()
        let moved = TabId()
        let oldModel = sidebarStoreModel([
            (groupA, "A", [first]),
            (groupB, "B", [middle]),
            (groupC, "C", [moved]),
        ], selected: first)
        var store = seedSidebarStore(oldModel)
        let oldProjection = desiredSidebar(in: oldModel)

        let newModel = sidebarStoreModel([
            (groupA, "A", [moved, first]),
            (groupB, "B", [middle]),
            (groupC, "C", []),
        ], selected: moved)
        applySidebarStoreTransition(&store, old: oldProjection, newModel: newModel)

        try assertSidebarStoreCacheInvariant(store, model: newModel)
        #expect(store.tabItemCache[moved] === store.displayedTabItem(moved),
            "moved tab cache should point at the displayed destination row")
    }

    @Test("cross-group move into topmost visible position keeps selected tab cached")
    func crossGroupMoveIntoTopmostKeepsSelectedCached() throws {
        // Intent: moving the selected tab into the topmost position of
        //   another group keeps it cached.
        // Why it exists: pins the topmost-target cache invariant.
        // Scenario: spec-first cross-group move to topmost.
        let groupA = GroupId()
        let groupB = GroupId()
        let first = TabId()
        let moved = TabId()
        let trailing = TabId()
        let oldModel = sidebarStoreModel([
            (groupA, "A", [first]),
            (groupB, "B", [moved, trailing]),
        ], selected: first)
        var store = seedSidebarStore(oldModel)
        let oldProjection = desiredSidebar(in: oldModel)

        let newModel = sidebarStoreModel([
            (groupA, "A", [moved, first]),
            (groupB, "B", [trailing]),
        ], selected: moved)
        applySidebarStoreTransition(&store, old: oldProjection, newModel: newModel)

        #expect(sidebarDisplayedTabIds(in: newModel).first == moved, "moved tab should be topmost")
        try assertSidebarStoreCacheInvariant(store, model: newModel)
    }

    @Test("inserted group child construction keeps moved tab cache current")
    func insertedGroupChildConstructionKeepsCacheCurrent() throws {
        // Intent: inserting a new group mounts a moved tab as its
        //   cached displayed row.
        // Why it exists: pins the new-group cache invariant.
        // Scenario: spec-first new-group with moved tab.
        let groupA = GroupId()
        let groupB = GroupId()
        let newGroup = GroupId()
        let first = TabId()
        let moved = TabId()
        let trailing = TabId()
        let oldModel = sidebarStoreModel([
            (groupA, "A", [first]),
            (groupB, "B", [moved, trailing]),
        ], selected: first)
        var store = seedSidebarStore(oldModel)
        let oldProjection = desiredSidebar(in: oldModel)

        let newModel = sidebarStoreModel([
            (groupA, "A", [first]),
            (newGroup, "New", [moved]),
            (groupB, "B", [trailing]),
        ], selected: moved)
        applySidebarStoreTransition(&store, old: oldProjection, newModel: newModel)

        try assertSidebarStoreCacheInvariant(store, model: newModel)
        #expect(store.tabItemCache[moved] === store.displayedTabItem(moved),
            "inserted group should mount the moved tab as the cached displayed row")
    }

    @Test("group removal clears closed child without clearing moved-out survivor")
    func groupRemovalClearsClosedChildKeepsSurvivor() throws {
        // Intent: removing a group evicts its destroyed tabs from the
        //   cache; a tab moved out before removal stays cached.
        // Why it exists: pins the group-remove cleanup contract.
        // Scenario: spec-first group remove with survivor.
        let groupA = GroupId()
        let groupB = GroupId()
        let removeMe = GroupId()
        let first = TabId()
        let survivor = TabId()
        let closed = TabId()
        let other = TabId()
        let oldModel = sidebarStoreModel([
            (groupA, "A", [first]),
            (removeMe, "RemoveMe", [survivor, closed]),
            (groupB, "B", [other]),
        ], selected: survivor)
        var store = seedSidebarStore(oldModel)
        let oldProjection = desiredSidebar(in: oldModel)

        let newModel = sidebarStoreModel([
            (groupA, "A", [survivor, first]),
            (groupB, "B", [other]),
        ], selected: survivor)
        applySidebarStoreTransition(&store, old: oldProjection, newModel: newModel)

        try assertSidebarStoreCacheInvariant(store, model: newModel, removed: [closed])
        #expect(store.tabItemCache[survivor] === store.displayedTabItem(survivor),
            "survivor cache should point at its displayed row")
    }

    @Test("same-group reorder keeps every live tab cache current")
    func sameGroupReorderKeepsCacheCurrent() throws {
        // Intent: a same-group reorder keeps every live tab cached.
        // Why it exists: pins the intra-group reorder cache invariant.
        // Scenario: spec-first reorder.
        let group = GroupId()
        let first = TabId()
        let moved = TabId()
        let trailing = TabId()
        let oldModel = sidebarStoreModel([
            (group, "A", [first, moved, trailing]),
        ], selected: first)
        var store = seedSidebarStore(oldModel)
        let oldProjection = desiredSidebar(in: oldModel)

        let newModel = sidebarStoreModel([
            (group, "A", [moved, first, trailing]),
        ], selected: moved)
        applySidebarStoreTransition(&store, old: oldProjection, newModel: newModel)

        try assertSidebarStoreCacheInvariant(store, model: newModel)
    }

    @Test("plain close evicts closed tab and keeps selected survivor cached")
    func plainCloseEvictsClosedKeepsSurvivor() throws {
        // Intent: closing a tab evicts it from the cache; the new
        //   selected survivor stays cached.
        // Why it exists: pins the per-tab close cleanup.
        // Scenario: spec-first plain close.
        let group = GroupId()
        let first = TabId()
        let closed = TabId()
        let survivor = TabId()
        let oldModel = sidebarStoreModel([
            (group, "A", [first, closed, survivor]),
        ], selected: closed)
        var store = seedSidebarStore(oldModel)
        let oldProjection = desiredSidebar(in: oldModel)

        let newModel = sidebarStoreModel([
            (group, "A", [first, survivor]),
        ], selected: survivor)
        applySidebarStoreTransition(&store, old: oldProjection, newModel: newModel)

        try assertSidebarStoreCacheInvariant(store, model: newModel, removed: [closed])
    }

    @Test("topmost tab close evicts closed tab and keeps next tab cached")
    func topmostTabCloseEvictsClosedKeepsNextCached() throws {
        // Intent: closing the topmost tab evicts it and the next tab
        //   takes the cached displayed row.
        // Why it exists: pins the topmost-close cleanup.
        // Scenario: spec-first topmost close.
        let group = GroupId()
        let closed = TabId()
        let next = TabId()
        let oldModel = sidebarStoreModel([
            (group, "A", [closed, next]),
        ], selected: closed)
        var store = seedSidebarStore(oldModel)
        let oldProjection = desiredSidebar(in: oldModel)

        let newModel = sidebarStoreModel([
            (group, "A", [next]),
        ], selected: next)
        applySidebarStoreTransition(&store, old: oldProjection, newModel: newModel)

        try assertSidebarStoreCacheInvariant(store, model: newModel, removed: [closed])
        #expect(store.tabItemCache[next] === store.displayedTabItem(next),
            "next tab cache should point at its displayed row")
    }

    @Test("multi-group to single-group reloadAll prunes closed topmost tab")
    func multiToSingleReloadAllPrunesClosedTopmost() throws {
        // Intent: the multi-group to single-group flip (reloadAll path)
        //   evicts closed tabs and keeps the survivor cache identity.
        // Why it exists: pins the reloadAll cleanup contract.
        // Scenario: spec-first reloadAll prune.
        let groupA = GroupId()
        let groupB = GroupId()
        let closed = TabId()
        let next = TabId()
        let oldModel = sidebarStoreModel([
            (groupA, "A", [closed]),
            (groupB, "B", [next]),
        ], selected: closed)
        var store = seedSidebarStore(oldModel)
        let oldProjection = desiredSidebar(in: oldModel)

        let newModel = sidebarStoreModel([
            (groupB, "B", [next]),
        ], selected: next)
        applySidebarStoreTransition(&store, old: oldProjection, newModel: newModel)

        try assertSidebarStoreCacheInvariant(store, model: newModel, removed: [closed])
        #expect(store.tabItemCache[next] === store.displayedTabItem(next),
            "reloadAll survivor cache should point at its displayed root row")
    }
}

private struct SidebarStoreSnapshot: Equatable {
    var rootItems: [ObjectIdentifier]
    var childItems: [GroupId: [ObjectIdentifier]]
    var tabItemCache: [TabId: ObjectIdentifier]
    var groupItemCache: [GroupId: ObjectIdentifier]
}

private func requireReloadAll(
    _ mutation: SidebarOutlineMutation
) throws -> [SidebarGroupCollapseState] {
    guard case .reloadAll(let collapseStates) = mutation else {
        Issue.record("expected a full outline reload")
        throw SidebarStoreTestError.unexpectedMutation
    }
    return collapseStates
}

private func requireRepaint(_ mutation: SidebarOutlineMutation) throws -> SidebarItem {
    guard case .repaint(let item) = mutation else {
        Issue.record("expected a repaint mutation")
        throw SidebarStoreTestError.unexpectedMutation
    }
    return item
}

private func requireInsert(
    _ mutation: SidebarOutlineMutation,
    at expectedIndex: Int,
    parent expectedParent: SidebarItem?
) throws -> SidebarItem {
    guard case .insert(let item, let index, let parent, _) = mutation else {
        Issue.record("expected an insert mutation")
        throw SidebarStoreTestError.unexpectedMutation
    }
    #expect(index == expectedIndex)
    #expect(parent === expectedParent)
    return item
}

private func requireRemove(
    _ mutation: SidebarOutlineMutation,
    at expectedIndex: Int,
    parent expectedParent: SidebarItem?
) throws -> SidebarItem {
    guard case .remove(let item, let index, let parent) = mutation else {
        Issue.record("expected a remove mutation")
        throw SidebarStoreTestError.unexpectedMutation
    }
    #expect(index == expectedIndex)
    #expect(parent === expectedParent)
    return item
}

private enum SidebarStoreTestError: Error {
    case unexpectedMutation
}

private func sidebarStoreSnapshot(_ store: SidebarItemStore) -> SidebarStoreSnapshot {
    SidebarStoreSnapshot(
        rootItems: store.rootItems.map(ObjectIdentifier.init),
        childItems: store.childItems.mapValues { $0.map(ObjectIdentifier.init) },
        tabItemCache: store.tabItemCache.mapValues(ObjectIdentifier.init),
        groupItemCache: store.groupItemCache.mapValues(ObjectIdentifier.init)
    )
}

/// Verifies that every mounted row and cache entry represents the handed projection.
private func assertSidebarStoreMatchesProjection(
    _ store: SidebarItemStore,
    projection: SidebarProjection
) throws {
    let expectedTabs = Set(projection.groups.flatMap(\.tabs).map(\.id))
    #expect(Set(store.tabItemCache.keys) == expectedTabs)

    if projection.isSingleGroupMode {
        #expect(store.groupItemCache.isEmpty)
        #expect(store.childItems.isEmpty)
        let tabs = projection.groups.first?.tabs ?? []
        #expect(store.rootItems.count == tabs.count)
        for (item, tab) in zip(store.rootItems, tabs) {
            guard case .tab(let mounted) = item.kind else {
                Issue.record("single-group root should be a tab")
                throw SidebarStoreTestError.unexpectedMutation
            }
            #expect(mounted == tab)
            #expect(store.tabItemCache[tab.id] === item)
        }
        return
    }

    #expect(Set(store.groupItemCache.keys) == Set(projection.groups.map(\.id)))
    #expect(store.rootItems.count == projection.groups.count)
    for (item, group) in zip(store.rootItems, projection.groups) {
        guard case .group(let mounted) = item.kind else {
            Issue.record("multi-group root should be a group")
            throw SidebarStoreTestError.unexpectedMutation
        }
        #expect(mounted == group)
        #expect(store.groupItemCache[group.id] === item)
        let children = store.childItems[group.id] ?? []
        #expect(children.count == group.tabs.count)
        for (child, tab) in zip(children, group.tabs) {
            guard case .tab(let mountedTab) = child.kind else {
                Issue.record("group child should be a tab")
                throw SidebarStoreTestError.unexpectedMutation
            }
            #expect(mountedTab == tab)
            #expect(store.tabItemCache[tab.id] === child)
        }
    }
}

private func seedSidebarStore(_ model: AppModel) -> SidebarItemStore {
    var store = SidebarItemStore()
    let projection = desiredSidebar(in: model)
    store.apply(computeSidebarRowOps(old: nil, new: projection), projection: projection)
    return store
}

@discardableResult
private func applySidebarStoreTransition(
    _ store: inout SidebarItemStore,
    old oldProjection: SidebarProjection,
    newModel: AppModel
) -> SidebarProjection {
    let newProjection = desiredSidebar(in: newModel)
    store.apply(
        computeSidebarRowOps(old: oldProjection, new: newProjection),
        projection: newProjection)
    return newProjection
}

private func assertSidebarStoreCacheInvariant(
    _ store: SidebarItemStore,
    model: AppModel,
    removed: Set<TabId> = []
) throws {
    for tabId in sidebarDisplayedTabIds(in: model) {
        let displayed = try #require(store.displayedTabItem(tabId), "missing displayed item for \(tabId)")
        let cached = try #require(store.tabItemCache[tabId], "missing cache item for \(tabId)")
        #expect(cached === displayed, "cache item should be the displayed row for \(tabId)")
    }

    for tabId in removed {
        #expect(store.tabItemCache[tabId] == nil, "removed tab should be absent from cache")
    }

    if let selectedTabId = model.selectedTabId, tabById(selectedTabId, in: model) != nil {
        guard let displayed = store.displayedTabItem(selectedTabId),
              let cached = store.tabItemCache[selectedTabId]
        else {
            Issue.record("selected tab missing displayed/cache item")
            return
        }
        #expect(cached === displayed, "selected tab cache should be the displayed row")
    }
}

private func sidebarDisplayedTabIds(in model: AppModel) -> [TabId] {
    model.groups.flatMap { $0.tabs.map(\.id) }
}

private func sidebarStoreModel(
    _ groups: [(GroupId, String, [TabId])],
    selected selectedTabId: TabId?
) -> AppModel {
    AppModel(
        groups: groups.map { groupId, name, tabIds in
            GroupModel(
                id: groupId,
                name: name,
                tabs: tabIds.map(sidebarStoreTab)
            )
        },
        selectedTabId: selectedTabId
    )
}

private func sidebarStoreTab(_ id: TabId) -> TabModel {
    let paneId = PaneId()
    var pane = PaneModel(id: paneId)
    pane.session = SessionModel(
        id: SessionId(),
        title: String(id.rawValue.uuidString.prefix(8))
    )
    return TabModel(id: id, paneTree: PaneTree(root: .leaf(pane), focusedPaneId: paneId))
}
