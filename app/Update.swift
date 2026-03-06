import Foundation

@discardableResult
func update(_ model: inout AppModel, _ msg: Msg) -> [Effect] {
    switch msg {

    // MARK: - Tab Management

    case .createTab(let inGroupId):
        let paneId = PaneId()
        let tabId = TabId()
        let cwd = currentCwd(in: model)

        let pane = PaneModel(id: paneId)
        model.panes[paneId] = pane

        let tab = TabModel(id: tabId, focusedPaneId: paneId, rootNode: .leaf(paneId))

        // Find target group
        let targetGroupIndex: Int
        if let gid = inGroupId, let idx = model.groups.firstIndex(where: { $0.id == gid }) {
            targetGroupIndex = idx
        } else if let selId = model.selectedTabId,
                  let idx = model.groups.firstIndex(where: { $0.tabs.contains(where: { $0.id == selId }) }) {
            targetGroupIndex = idx
        } else {
            targetGroupIndex = 0
        }
        model.groups[targetGroupIndex].tabs.append(tab)

        // Defocus old tab's panes
        var effects: [Effect] = []
        if let oldTabId = model.selectedTabId {
            for oldPaneId in paneIdsForTab(oldTabId, in: model) {
                effects.append(.focusSurface(paneId: oldPaneId, focused: false))
            }
        }

        model.selectedTabId = tabId

        effects.append(.createSurface(paneId: paneId, cwd: cwd, command: nil))
        effects.append(.rebuildContentView)
        effects.append(.reloadSidebar)
        return effects

    case .selectAdjacentTab(let direction):
        guard let targetId = adjacentTabId(direction: direction, in: model) else { return [] }
        return update(&model, .selectTab(id: targetId))

    case .selectTab(let id):
        guard id != model.selectedTabId else { return [] }

        var effects: [Effect] = []

        // Defocus old tab's panes
        if let oldTabId = model.selectedTabId {
            for oldPaneId in paneIdsForTab(oldTabId, in: model) {
                effects.append(.focusSurface(paneId: oldPaneId, focused: false))
            }
        }

        model.selectedTabId = id
        // Clear bell on the newly focused pane
        if let tab = selectedTab(in: model) {
            model.panes[tab.focusedPaneId]?.hasBell = false
        }
        effects.append(.rebuildContentView)
        effects.append(.reloadSidebar)
        return effects

    case .requestCloseTab(let id):
        guard let groupIdx = model.groups.firstIndex(where: { $0.tabs.contains(where: { $0.id == id }) }),
              let tabIdx = model.groups[groupIdx].tabs.firstIndex(where: { $0.id == id }) else { return [] }

        let tab = model.groups[groupIdx].tabs[tabIdx]
        let paneCount = allPaneIds(tab.rootNode).count

        if paneCount > 1 {
            let isLastTab = totalTabCount(model) == 1
            return [.showCloseTabConfirmation(tabId: id, tabTitle: tab.title, paneCount: paneCount, isLastTab: isLastTab)]
        }

        return update(&model, .closeTab(id: id))

    case .closeTab(let id):
        guard let groupIdx = model.groups.firstIndex(where: { $0.tabs.contains(where: { $0.id == id }) }),
              let tabIdx = model.groups[groupIdx].tabs.firstIndex(where: { $0.id == id }) else { return [] }

        if wouldQuitFromClose(model) {
            return [.showTerminateConfirmation]
        }

        let tab = model.groups[groupIdx].tabs[tabIdx]
        let paneIds = allPaneIds(tab.rootNode)

        var effects: [Effect] = []
        for pid in paneIds {
            effects.append(.destroySurface(paneId: pid))
            model.panes.removeValue(forKey: pid)
        }

        model.groups[groupIdx].tabs.remove(at: tabIdx)

        // Check if all tabs gone
        let allTabs = model.groups.flatMap(\.tabs)
        if allTabs.isEmpty {
            return effects + [.terminate]
        }

        // Select adjacent tab if we closed the selected one
        if id == model.selectedTabId {
            if !model.groups[groupIdx].tabs.isEmpty {
                let newIdx = min(tabIdx, model.groups[groupIdx].tabs.count - 1)
                model.selectedTabId = model.groups[groupIdx].tabs[newIdx].id
            } else {
                model.selectedTabId = allTabs.first?.id
            }
            effects.append(.rebuildContentView)
        }
        effects.append(.reloadSidebar)
        return effects

    // MARK: - Pane Management

    case .splitPane(let direction):
        guard let tab = selectedTab(in: model) else { return [] }
        let focusedId = tab.focusedPaneId
        let newPaneId = PaneId()
        let cwd = model.panes[focusedId]?.cwd

        guard let newRoot = splitLeaf(tab.rootNode, paneId: focusedId, direction: direction, newPaneId: newPaneId) else { return [] }

        let newPane = PaneModel(id: newPaneId)
        model.panes[newPaneId] = newPane

        // Update the tab in place
        updateSelectedTab(&model) { tab in
            tab.rootNode = newRoot
            tab.focusedPaneId = newPaneId
            tab.isZoomed = false
        }

        return [
            .createSurface(paneId: newPaneId, cwd: cwd, command: nil),
            .rebuildContentView,
        ]

    case .closePane(let paneId):
        guard let tabId = model.selectedTabId,
              let groupIdx = model.groups.firstIndex(where: { $0.tabs.contains(where: { $0.id == tabId }) }),
              let tabIdx = model.groups[groupIdx].tabs.firstIndex(where: { $0.id == tabId }) else { return [] }

        let tab = model.groups[groupIdx].tabs[tabIdx]
        let (newTree, nextFocus) = removeLeaf(tab.rootNode, paneId: paneId)

        if newTree == nil && wouldQuitFromClose(model) {
            return [.showTerminateConfirmation]
        }

        var effects: [Effect] = [.destroySurface(paneId: paneId)]
        model.panes.removeValue(forKey: paneId)

        guard let newRoot = newTree else {
            // Last pane — close tab
            return update(&model, .closeTab(id: tabId))
        }

        model.groups[groupIdx].tabs[tabIdx].rootNode = newRoot
        if let next = nextFocus {
            model.groups[groupIdx].tabs[tabIdx].focusedPaneId = next
        }
        normalizeZoom(&model.groups[groupIdx].tabs[tabIdx])

        effects.append(.rebuildContentView)
        return effects

    case .focusDirection(let direction, let side):
        guard let tab = selectedTab(in: model) else { return [] }
        if tab.isZoomed {
            updateSelectedTab(&model) { t in t.isZoomed = false }
            return [.rebuildContentView]
        }
        guard let target = nearestLeaf(tab.rootNode, from: tab.focusedPaneId, direction: direction, side: side) else { return [] }

        // Keep focused-pane state changes in paneBecameFirstResponder so
        // keyboard focus changes and border rendering stay in sync.
        return [.makeFirstResponder(paneId: target)]

    case .paneBecameFirstResponder(let paneId):
        guard let tab = selectedTab(in: model) else { return [] }
        let oldFocusedId = tab.focusedPaneId
        guard paneId != oldFocusedId else { return [] }

        model.panes[paneId]?.hasBell = false
        updateSelectedTab(&model) { t in t.focusedPaneId = paneId }

        // Update tab title/subtitle from newly focused pane
        if let pane = model.panes[paneId] {
            updateSelectedTab(&model) { t in
                t.title = abbreviateHome(pane.title)
                if let cwd = pane.cwd {
                    t.subtitle = abbreviateHome(cwd)
                }
            }
        }

        var effects: [Effect] = [.rebuildContentView]
        if let tab = selectedTab(in: model) {
            effects.append(.setWindowTitle(windowTitle(for: tab)))
            effects.append(.reloadSidebarRow(tabId: tab.id))
            if let group = groupForTab(tab.id, in: model), group.isCollapsed {
                effects.append(.reloadSidebarGroupRow(groupId: group.id))
            }
        }
        return effects

    // MARK: - Ghostty Callbacks

    case .surfaceTitle(let paneId, let title):
        model.panes[paneId]?.title = title
        guard let tab = tabForPane(paneId, in: model), tab.focusedPaneId == paneId else {
            return []
        }
        let abbrev = abbreviateHome(title)
        updateTab(tab.id, in: &model) { t in t.title = abbrev }
        var effects: [Effect] = [.reloadSidebarRow(tabId: tab.id)]
        if tab.id == model.selectedTabId {
            let updatedTab = selectedTab(in: model)!
            effects.append(.setWindowTitle(windowTitle(for: updatedTab)))
        }
        return effects

    case .surfaceCwd(let paneId, let cwd):
        model.panes[paneId]?.cwd = cwd
        guard let tab = tabForPane(paneId, in: model), tab.focusedPaneId == paneId else {
            return []
        }
        let abbrev = abbreviateHome(cwd)
        updateTab(tab.id, in: &model) { t in t.subtitle = abbrev }
        var effects: [Effect] = [.reloadSidebarRow(tabId: tab.id)]
        if tab.id == model.selectedTabId {
            let updatedTab = selectedTab(in: model)!
            effects.append(.setWindowTitle(windowTitle(for: updatedTab)))
        }
        return effects

    case .surfaceBell(let paneId):
        model.panes[paneId]?.hasBell = true

        // If focused in selected tab, immediately clear
        if let tab = selectedTab(in: model), tab.focusedPaneId == paneId {
            model.panes[paneId]?.hasBell = false
            return []
        }

        // Find which tab this pane belongs to
        var effects: [Effect] = [.rebuildContentView]
        for group in model.groups {
            for tab in group.tabs {
                if allPaneIds(tab.rootNode).contains(paneId) {
                    effects.append(.reloadSidebarRow(tabId: tab.id))
                    if group.isCollapsed {
                        effects.append(.reloadSidebarGroupRow(groupId: group.id))
                    }

                    // System notification only when app is not active
                    // Throttle: skip if last notification was within 5 seconds
                    if let pane = model.panes[paneId] {
                        let shouldNotify: Bool
                        if let last = pane.lastBellNotification {
                            shouldNotify = Date().timeIntervalSince(last) >= 5
                        } else {
                            shouldNotify = true
                        }

                        if shouldNotify {
                            model.panes[paneId]?.lastBellNotification = Date()
                            if !model.notificationPermissionRequested {
                                model.notificationPermissionRequested = true
                                effects.append(.requestNotificationPermission)
                            }
                            effects.append(.sendNotification(
                                title: "DanTerm",
                                body: pane.title,
                                tabId: tab.id,
                                paneId: paneId
                            ))
                        }
                    }
                    break
                }
            }
        }
        return effects

    case .surfaceClosed(let paneId):
        return update(&model, .closePane(paneId: paneId))

    case .surfaceCreationFailed(let paneId):
        model.panes.removeValue(forKey: paneId)
        // Find and remove the tab containing this pane
        for gi in model.groups.indices {
            if let ti = model.groups[gi].tabs.firstIndex(where: { allPaneIds($0.rootNode).contains(paneId) }) {
                let tabId = model.groups[gi].tabs[ti].id
                model.groups[gi].tabs.remove(at: ti)
                if model.selectedTabId == tabId {
                    model.selectedTabId = model.groups.flatMap(\.tabs).first?.id
                }
                if model.groups.flatMap(\.tabs).isEmpty {
                    return [.terminate]
                }
                return [.rebuildContentView, .reloadSidebar]
            }
        }
        return []

    // MARK: - Lifecycle

    case .appBecameActive:
        return [.setAppFocus(true)]

    case .appResignedActive:
        return [.setAppFocus(false)]

    case .notificationClicked(let tabId, let paneId):
        var effects = update(&model, .selectTab(id: tabId))
        // Clear zoom if notification targets a different pane than focused
        if let pid = paneId, let tab = selectedTab(in: model), tab.isZoomed, pid != tab.focusedPaneId {
            updateSelectedTab(&model) { t in t.isZoomed = false }
            effects.append(.rebuildContentView)
        }
        if let pid = paneId {
            effects.append(.makeFirstResponder(paneId: pid))
        }
        effects.append(.activateApp)
        return effects

    case .confirmTerminate:
        if wouldQuitFromClose(model) {
            return [.terminate]
        }
        return []

    case .cancelTerminate:
        return []

    case .terminate:
        return [.terminate]

    // MARK: - Group Management

    case .createGroup(let name):
        let groupId = GroupId()
        let group = GroupModel(id: groupId, name: name, isDefault: false)
        model.groups.append(group)
        return update(&model, .createTab(inGroupId: groupId))

    case .deleteGroup(let id, let moveTabs):
        guard let idx = model.groups.firstIndex(where: { $0.id == id }),
              !model.groups[idx].isDefault else { return [] }

        let group = model.groups[idx]
        if !moveTabs && !group.tabs.isEmpty && totalTabCount(model) == group.tabs.count {
            return [.showTerminateConfirmation]
        }
        if moveTabs {
            model.groups[0].tabs.append(contentsOf: group.tabs)
        } else {
            // Close all tabs' surfaces
            var effects: [Effect] = []
            for tab in group.tabs {
                for pid in allPaneIds(tab.rootNode) {
                    effects.append(.destroySurface(paneId: pid))
                    model.panes.removeValue(forKey: pid)
                }
            }
            model.groups.remove(at: idx)
            if model.groups.flatMap(\.tabs).isEmpty {
                return effects + [.terminate]
            }
            // Fix selection if needed
            if let selId = model.selectedTabId,
               !model.groups.flatMap(\.tabs).contains(where: { $0.id == selId }) {
                model.selectedTabId = model.groups.flatMap(\.tabs).first?.id
                effects.append(.rebuildContentView)
            }
            effects.append(.reloadSidebar)
            return effects
        }

        model.groups.remove(at: idx)
        return [.reloadSidebar]

    case .renameGroup(let id, let name):
        guard let idx = model.groups.firstIndex(where: { $0.id == id }) else { return [] }
        model.groups[idx].name = name
        return [.reloadSidebar]

    case .moveTab(let tabId, let toGroupId, let atIndex):
        guard let srcGroupIdx = model.groups.firstIndex(where: { $0.tabs.contains(where: { $0.id == tabId }) }),
              let tabIdx = model.groups[srcGroupIdx].tabs.firstIndex(where: { $0.id == tabId }),
              let dstGroupIdx = model.groups.firstIndex(where: { $0.id == toGroupId }) else { return [] }

        let tab = model.groups[srcGroupIdx].tabs.remove(at: tabIdx)
        let clampedIndex = min(atIndex, model.groups[dstGroupIdx].tabs.count)
        model.groups[dstGroupIdx].tabs.insert(tab, at: clampedIndex)
        return [.reloadSidebar]

    case .reorderGroup(let groupId, let toIndex):
        guard let currentIdx = model.groups.firstIndex(where: { $0.id == groupId }),
              !model.groups[currentIdx].isDefault else { return [] }
        let clamped = max(1, min(toIndex, model.groups.count - 1))
        let group = model.groups.remove(at: currentIdx)
        model.groups.insert(group, at: clamped)
        return [.reloadSidebar]

    case .toggleGroupCollapse(let groupId):
        guard let idx = model.groups.firstIndex(where: { $0.id == groupId }) else { return [] }
        model.groups[idx].isCollapsed.toggle()
        return []

    case .toggleZoomPane:
        guard let tab = selectedTab(in: model) else { return [] }
        if tab.isZoomed {
            updateSelectedTab(&model) { t in t.isZoomed = false }
            return [.rebuildContentView]
        }
        if case .split = tab.rootNode {
            updateSelectedTab(&model) { t in t.isZoomed = true }
            return [.rebuildContentView]
        }
        return []

    // MARK: - View

    case .splitRatioChanged(let splitId, let ratio):
        updateSelectedTab(&model) { tab in
            tab.rootNode = setRatio(tab.rootNode, splitId: splitId, ratio: ratio)
        }
        return []
    }
}

// MARK: - Helpers

private func updateSelectedTab(_ model: inout AppModel, _ body: (inout TabModel) -> Void) {
    guard let selId = model.selectedTabId else { return }
    updateTab(selId, in: &model, body)
}

private func updateTab(_ tabId: TabId, in model: inout AppModel, _ body: (inout TabModel) -> Void) {
    for gi in model.groups.indices {
        if let ti = model.groups[gi].tabs.firstIndex(where: { $0.id == tabId }) {
            body(&model.groups[gi].tabs[ti])
            return
        }
    }
}

private func normalizeZoom(_ tab: inout TabModel) {
    if case .leaf = tab.rootNode { tab.isZoomed = false }
}

private func windowTitle(for tab: TabModel) -> String {
    if let subtitle = tab.subtitle, subtitle != tab.title {
        return "\(tab.title) — \(subtitle)"
    }
    return tab.title
}
