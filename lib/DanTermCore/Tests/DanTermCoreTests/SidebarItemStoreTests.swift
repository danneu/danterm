// Swift Testing migration of the legacy `tests/SidebarItemStoreTests.swift`
// harness suite. Pins SidebarItemStore.apply structural-op preconditions
// (missing/out-of-range ops return false and do NOT mutate the backing
// store) and the cache-identity invariants the reconciler relies on: under
// granular row-op transitions (cross-group move, inserted-group child
// construction, group removal, intra-group reorder, plain close, topmost
// close, multi->single mode flip), every displayed tab's cache item
// remains pointer-identical to its displayed row, removed tabs are evicted
// from the cache, and the selected survivor stays cached. The
// assertSidebarStoreCacheInvariant helper's two `guard let ... else { throw }`
// patterns convert to `try #require` (single-value optionals).
import Foundation
import Testing

@testable import DanTermCore

@Suite struct SidebarItemStoreTests {
    @Test("apply contract: missing structural ops skip backing mutations")
    func applyContractMissingStructuralOpsSkipMutations() {
        // Intent: structural ops referencing missing groups/tabs return
        //   false and DO NOT mutate the backing store; non-structural
        //   ops (reload* / setGroupCollapsed) return true even when the
        //   id is unknown and still leave the backing structure
        //   unchanged.
        // Why it exists: pins the apply contract's precondition checks.
        // Scenario: spec-first apply contract.
        let groupA = GroupId()
        let groupB = GroupId()
        let tabA = TabId()
        let tabB = TabId()
        let model = sidebarStoreModel([
            (groupA, "A", [tabA]),
            (groupB, "B", [tabB]),
        ], selected: tabA)
        var store = seedSidebarStore(model)
        let before = sidebarStoreSnapshot(store)

        let insertGroupResult = store.apply(.insertGroup(id: GroupId(), index: 0), model: model, isSingleGroupMode: false)
        #expect(!insertGroupResult, "missing group insert should return false")
        #expect(sidebarStoreSnapshot(store) == before, "missing group insert should not mutate")

        let insertTabResult = store.apply(.insertTab(id: TabId(), groupId: groupA, index: 0), model: model, isSingleGroupMode: false)
        #expect(!insertTabResult, "missing tab insert should return false")
        #expect(sidebarStoreSnapshot(store) == before, "missing tab insert should not mutate")

        let insertTabMissingParent = store.apply(.insertTab(id: tabA, groupId: GroupId(), index: 0), model: model, isSingleGroupMode: false)
        #expect(!insertTabMissingParent, "missing parent tab insert should return false")
        #expect(sidebarStoreSnapshot(store) == before, "missing parent insert should not mutate")

        let removeGroupOOR = store.apply(.removeGroup(index: 99), model: model, isSingleGroupMode: false)
        #expect(!removeGroupOOR, "out-of-range group remove should return false")
        #expect(sidebarStoreSnapshot(store) == before, "out-of-range group remove should not mutate")

        let removeTabMissingParent = store.apply(.removeTab(groupId: GroupId(), index: 0), model: model, isSingleGroupMode: false)
        #expect(!removeTabMissingParent, "missing parent tab remove should return false")
        #expect(sidebarStoreSnapshot(store) == before, "missing parent remove should not mutate")

        let removeTabOOR = store.apply(.removeTab(groupId: groupA, index: 99), model: model, isSingleGroupMode: false)
        #expect(!removeTabOOR, "out-of-range tab remove should return false")
        #expect(sidebarStoreSnapshot(store) == before, "out-of-range tab remove should not mutate")

        let reloadGroup = store.apply(.reloadGroup(id: GroupId()), model: model, isSingleGroupMode: false)
        #expect(reloadGroup, "reloadGroup should return true")
        let setCollapsed = store.apply(.setGroupCollapsed(id: GroupId(), collapsed: true), model: model, isSingleGroupMode: false)
        #expect(setCollapsed, "setGroupCollapsed should return true")
        let reloadTab = store.apply(.reloadTab(id: TabId()), model: model, isSingleGroupMode: false)
        #expect(reloadTab, "reloadTab should return true")
        #expect(sidebarStoreSnapshot(store) == before, "non-structural ops should not mutate backing structure")
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

private func sidebarStoreSnapshot(_ store: SidebarItemStore) -> SidebarStoreSnapshot {
    SidebarStoreSnapshot(
        rootItems: store.rootItems.map(ObjectIdentifier.init),
        childItems: store.childItems.mapValues { $0.map(ObjectIdentifier.init) },
        tabItemCache: store.tabItemCache.mapValues(ObjectIdentifier.init),
        groupItemCache: store.groupItemCache.mapValues(ObjectIdentifier.init)
    )
}

private func seedSidebarStore(_ model: AppModel) -> SidebarItemStore {
    var store = SidebarItemStore()
    let projection = desiredSidebar(in: model)
    store.apply(
        computeSidebarRowOps(old: nil, new: projection),
        model: model,
        isSingleGroupMode: projection.isSingleGroupMode)
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
        model: newModel,
        isSingleGroupMode: newProjection.isSingleGroupMode)
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
    pane.title = String(id.rawValue.uuidString.prefix(8))
    return TabModel(
        id: id,
        focusedPaneId: paneId,
        rootNode: .leaf(pane)
    )
}
