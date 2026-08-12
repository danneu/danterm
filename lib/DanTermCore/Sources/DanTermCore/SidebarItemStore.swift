// Pure backing store for sidebar outline row identity and cache invariants.
import Foundation

// MARK: - SidebarItem

/// Reference-type wrapper for NSOutlineView row identity stability.
///
/// The payload is the row's *last applied* projection, not a model: the render
/// path draws a cell straight from it, so a suppressed or dropped row op leaves
/// the row showing what it last painted instead of silently picking up a newer
/// model at draw time. The interaction path (context menus, drag and drop,
/// selection) reads ids off the payload and looks the model up itself.
class SidebarItem {
    let id: UUID
    var kind: Kind

    enum Kind {
        case group(SidebarGroupProjection)
        case tab(SidebarTabProjection)
    }

    init(id: UUID, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

// MARK: - SidebarItemStore

/// Owns the sidebar's backing rows and id caches without depending on AppKit.
struct SidebarItemStore {
    var tabItemCache: [TabId: SidebarItem] = [:]
    var groupItemCache: [GroupId: SidebarItem] = [:]
    var rootItems: [SidebarItem] = []
    var childItems: [GroupId: [SidebarItem]] = [:]

    /// Test convenience: apply a whole ordered row-op script to the store.
    mutating func apply(_ ops: [SidebarRowOp], projection: SidebarProjection) {
        for op in ops {
            _ = apply(op, projection: projection)
        }
    }

    /// Apply one row op to the backing store. The Bool tells the AppKit bridge
    /// whether the matching structural NSOutlineView mutation should run.
    @discardableResult
    mutating func apply(_ op: SidebarRowOp, projection: SidebarProjection) -> Bool {
        switch op {
        case .reloadAll:
            rebuildAllRows(projection: projection)
            return true

        case .insertGroup(let id, let index):
            guard !projection.isSingleGroupMode,
                  let group = projection.group(id),
                  rootItems.indices.contains(index) || index == rootItems.count
            else { return false }

            let item = groupItemCache[id] ?? SidebarItem(id: id.rawValue, kind: .group(group))
            item.kind = .group(group)
            groupItemCache[id] = item
            childItems[id] = group.tabs.map { makeFreshTabItem(for: $0) }
            rootItems.insert(item, at: index)
            return true

        case .removeGroup(let index):
            guard !projection.isSingleGroupMode,
                  rootItems.indices.contains(index),
                  case .group(let group) = rootItems[index].kind
            else { return false }

            let item = rootItems[index]
            for child in childItems[group.id] ?? [] {
                removeCachedTabItemIfCurrent(child)
            }
            childItems.removeValue(forKey: group.id)
            if groupItemCache[group.id] === item {
                groupItemCache.removeValue(forKey: group.id)
            }
            rootItems.remove(at: index)
            return true

        case .reloadGroup(let id):
            _ = updateGroupItem(groupId: id, projection: projection)
            return true

        case .setGroupCollapsed(let id, _):
            _ = updateGroupItem(groupId: id, projection: projection)
            return true

        case .insertTab(let id, let groupId, let index):
            guard let tab = projection.tab(id) else { return false }

            if projection.isSingleGroupMode {
                guard rootItems.indices.contains(index) || index == rootItems.count else {
                    return false
                }
                let item = makeFreshTabItem(for: tab)
                rootItems.insert(item, at: index)
                return true
            } else {
                guard groupItemCache[groupId] != nil,
                      var children = childItems[groupId],
                      children.indices.contains(index) || index == children.count
                else { return false }
                let item = makeFreshTabItem(for: tab)
                children.insert(item, at: index)
                childItems[groupId] = children
                return true
            }

        case .removeTab(let groupId, let index):
            if projection.isSingleGroupMode {
                guard rootItems.indices.contains(index),
                      case .tab = rootItems[index].kind
                else { return false }
                let item = rootItems.remove(at: index)
                removeCachedTabItemIfCurrent(item)
                return true
            } else {
                guard groupItemCache[groupId] != nil,
                      var children = childItems[groupId],
                      children.indices.contains(index),
                      case .tab = children[index].kind
                else { return false }
                let item = children.remove(at: index)
                childItems[groupId] = children
                removeCachedTabItemIfCurrent(item)
                return true
            }

        case .reloadTab(let id):
            _ = updateTabItem(tabId: id, projection: projection)
            return true
        }
    }

    /// Return the backing row object currently displayed for a live tab id.
    func displayedTabItem(_ tabId: TabId) -> SidebarItem? {
        for item in rootItems {
            if case .tab(let tab) = item.kind, tab.id == tabId {
                return item
            }
            if case .group(let group) = item.kind {
                for child in childItems[group.id] ?? [] {
                    if case .tab(let tab) = child.kind, tab.id == tabId {
                        return child
                    }
                }
            }
        }
        return nil
    }

    /// Refresh one cached tab's projection payload if it still exists.
    @discardableResult
    mutating func updateTabItem(tabId: TabId, projection: SidebarProjection) -> SidebarItem? {
        guard let tab = projection.tab(tabId),
              let item = tabItemCache[tabId]
        else { return nil }
        item.kind = .tab(tab)
        return item
    }

    /// Refresh one cached group's projection payload if it still exists.
    @discardableResult
    mutating func updateGroupItem(groupId: GroupId, projection: SidebarProjection) -> SidebarItem? {
        guard let group = projection.group(groupId),
              let item = groupItemCache[groupId]
        else { return nil }
        item.kind = .group(group)
        return item
    }

    /// Incremental insert helper: always mount a fresh row item and cache it.
    @discardableResult
    mutating func makeFreshTabItem(for tab: SidebarTabProjection) -> SidebarItem {
        let item = SidebarItem(id: tab.id.rawValue, kind: .tab(tab))
        tabItemCache[tab.id] = item
        return item
    }

    /// Incremental remove helper: clear the cache only if it still points to
    /// the exact row object being unmounted.
    mutating func removeCachedTabItemIfCurrent(_ item: SidebarItem) {
        guard case .tab(let tab) = item.kind,
              tabItemCache[tab.id] === item
        else { return }
        tabItemCache.removeValue(forKey: tab.id)
    }

    /// Full rebuild path: reuse cached row objects for live rows, then prune
    /// entries whose ids are no longer represented by the displayed backing rows.
    private mutating func rebuildAllRows(projection: SidebarProjection) {
        var newRootItems: [SidebarItem] = []
        var newChildItems: [GroupId: [SidebarItem]] = [:]
        var liveTabIds = Set<TabId>()
        var displayedGroupIds = Set<GroupId>()

        if projection.isSingleGroupMode {
            for tab in projection.groups.first?.tabs ?? [] {
                let item = tabItemCache[tab.id] ?? SidebarItem(id: tab.id.rawValue, kind: .tab(tab))
                item.kind = .tab(tab)
                tabItemCache[tab.id] = item
                newRootItems.append(item)
                liveTabIds.insert(tab.id)
            }
        } else {
            for group in projection.groups {
                let groupItem = groupItemCache[group.id] ?? SidebarItem(id: group.id.rawValue, kind: .group(group))
                groupItem.kind = .group(group)
                groupItemCache[group.id] = groupItem
                newRootItems.append(groupItem)
                displayedGroupIds.insert(group.id)

                var tabItems: [SidebarItem] = []
                for tab in group.tabs {
                    let tabItem = tabItemCache[tab.id] ?? SidebarItem(id: tab.id.rawValue, kind: .tab(tab))
                    tabItem.kind = .tab(tab)
                    tabItemCache[tab.id] = tabItem
                    tabItems.append(tabItem)
                    liveTabIds.insert(tab.id)
                }
                newChildItems[group.id] = tabItems
            }
        }

        rootItems = newRootItems
        childItems = newChildItems
        tabItemCache = tabItemCache.filter { liveTabIds.contains($0.key) }
        groupItemCache = groupItemCache.filter { displayedGroupIds.contains($0.key) }
    }
}
