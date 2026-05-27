// Tests for sidebar backing-store cache identity across granular row ops.
import Foundation

func sidebarItemStoreTests() {
    print("SidebarItemStore Tests...")

    test("apply contract: missing structural ops skip backing mutations") {
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

        try expect(!store.apply(.insertGroup(id: GroupId(), index: 0), model: model, isSingleGroupMode: false),
            "missing group insert should return false")
        try expectEqual(sidebarStoreSnapshot(store), before, "missing group insert should not mutate")

        try expect(!store.apply(.insertTab(id: TabId(), groupId: groupA, index: 0), model: model, isSingleGroupMode: false),
            "missing tab insert should return false")
        try expectEqual(sidebarStoreSnapshot(store), before, "missing tab insert should not mutate")

        try expect(!store.apply(.insertTab(id: tabA, groupId: GroupId(), index: 0), model: model, isSingleGroupMode: false),
            "missing parent tab insert should return false")
        try expectEqual(sidebarStoreSnapshot(store), before, "missing parent insert should not mutate")

        try expect(!store.apply(.removeGroup(index: 99), model: model, isSingleGroupMode: false),
            "out-of-range group remove should return false")
        try expectEqual(sidebarStoreSnapshot(store), before, "out-of-range group remove should not mutate")

        try expect(!store.apply(.removeTab(groupId: GroupId(), index: 0), model: model, isSingleGroupMode: false),
            "missing parent tab remove should return false")
        try expectEqual(sidebarStoreSnapshot(store), before, "missing parent remove should not mutate")

        try expect(!store.apply(.removeTab(groupId: groupA, index: 99), model: model, isSingleGroupMode: false),
            "out-of-range tab remove should return false")
        try expectEqual(sidebarStoreSnapshot(store), before, "out-of-range tab remove should not mutate")

        try expect(store.apply(.reloadGroup(id: GroupId()), model: model, isSingleGroupMode: false),
            "reloadGroup should return true")
        try expect(store.apply(.setGroupCollapsed(id: GroupId(), collapsed: true), model: model, isSingleGroupMode: false),
            "setGroupCollapsed should return true")
        try expect(store.apply(.reloadTab(id: TabId()), model: model, isSingleGroupMode: false),
            "reloadTab should return true")
        try expectEqual(sidebarStoreSnapshot(store), before, "non-structural ops should not mutate backing structure")
    }

    test("later group to earlier group move keeps moved tab cache pointed at displayed item") {
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
        try expect(store.tabItemCache[moved] === store.displayedTabItem(moved),
            "moved tab cache should point at the displayed destination row")
    }

    test("cross-group move into topmost visible position keeps selected tab cached") {
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

        try expect(sidebarDisplayedTabIds(in: newModel).first == moved, "moved tab should be topmost")
        try assertSidebarStoreCacheInvariant(store, model: newModel)
    }

    test("inserted group child construction keeps moved tab cache current") {
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
        try expect(store.tabItemCache[moved] === store.displayedTabItem(moved),
            "inserted group should mount the moved tab as the cached displayed row")
    }

    test("group removal clears closed child without clearing moved-out survivor") {
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
        try expect(store.tabItemCache[survivor] === store.displayedTabItem(survivor),
            "survivor cache should point at its displayed row")
    }

    test("same-group reorder keeps every live tab cache current") {
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

    test("plain close evicts closed tab and keeps selected survivor cached") {
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

    test("topmost tab close evicts closed tab and keeps next tab cached") {
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
        try expect(store.tabItemCache[next] === store.displayedTabItem(next),
            "next tab cache should point at its displayed row")
    }

    test("multi-group to single-group reloadAll prunes closed topmost tab") {
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
        try expect(store.tabItemCache[next] === store.displayedTabItem(next),
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
    removed: Set<TabId> = [],
    file: String = #file,
    line: Int = #line
) throws {
    for tabId in sidebarDisplayedTabIds(in: model) {
        guard let displayed = store.displayedTabItem(tabId) else {
            throw TestFailure(message: "missing displayed item for \(tabId) (\(file):\(line))")
        }
        guard let cached = store.tabItemCache[tabId] else {
            throw TestFailure(message: "missing cache item for \(tabId) (\(file):\(line))")
        }
        try expect(cached === displayed, "cache item should be the displayed row for \(tabId)", file: file, line: line)
    }

    for tabId in removed {
        try expect(store.tabItemCache[tabId] == nil, "removed tab should be absent from cache", file: file, line: line)
    }

    if let selectedTabId = model.selectedTabId, tabById(selectedTabId, in: model) != nil {
        guard let displayed = store.displayedTabItem(selectedTabId),
              let cached = store.tabItemCache[selectedTabId]
        else {
            throw TestFailure(message: "selected tab missing displayed/cache item (\(file):\(line))")
        }
        try expect(cached === displayed, "selected tab cache should be the displayed row", file: file, line: line)
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
