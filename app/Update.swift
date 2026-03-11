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
                  let (gi, _) = tabLocation(selId, in: model) {
            targetGroupIndex = gi
        } else {
            targetGroupIndex = 0
        }
        // Insert after current tab if it's in the same group, otherwise append
        if let selId = model.selectedTabId,
           let selIdx = model.groups[targetGroupIndex].tabs.firstIndex(where: { $0.id == selId }) {
            model.groups[targetGroupIndex].tabs.insert(tab, at: selIdx + 1)
        } else {
            model.groups[targetGroupIndex].tabs.append(tab)
        }

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
        effects.append(contentsOf: selectionSyncEffects(for: model))
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
        // Mark alerts read on the newly focused pane
        if let tab = selectedTab(in: model) {
            markAlertsReadForPane(tab.focusedPaneId, in: &model)
        }
        effects.append(.rebuildContentView)
        effects.append(.reloadSidebar)
        effects.append(contentsOf: selectionSyncEffects(for: model))
        return effects

    case .requestCloseTab(let id):
        guard let tab = tabById(id, in: model) else { return [] }
        let paneCount = allPaneIds(tab.rootNode).count

        if paneCount > 1 {
            let isLastTab = totalTabCount(model) == 1
            return [.showCloseTabConfirmation(tabId: id, tabTitle: tab.displayTitle, paneCount: paneCount, isLastTab: isLastTab)]
        }

        return update(&model, .closeTab(id: id))

    case .closeTab(let id):
        guard let (groupIdx, tabIdx) = tabLocation(id, in: model) else { return [] }

        if wouldQuitFromClose(model) {
            return [.showTerminateConfirmation]
        }

        let tab = model.groups[groupIdx].tabs[tabIdx]
        let paneIds = allPaneIds(tab.rootNode)

        var effects: [Effect] = []
        for pid in paneIds {
            effects.append(.destroySurface(paneId: pid))
            markAlertsReadForPane(pid, in: &model)
            model.lastNotificationTime.removeValue(forKey: pid)
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
            effects.append(contentsOf: selectionSyncEffects(for: model))
        }
        effects.append(.reloadSidebar)
        return effects

    // MARK: - Pane Management

    case .splitPane(let paneId, let direction):
        guard let tab = selectedTab(in: model) else { return [] }
        let targetPaneId = paneId ?? tab.focusedPaneId
        let newPaneId = PaneId()
        let cwd = model.panes[targetPaneId]?.cwd

        guard let newRoot = splitLeaf(tab.rootNode, paneId: targetPaneId, direction: direction, newPaneId: newPaneId) else { return [] }

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
              let tab = selectedTab(in: model) else { return [] }

        let (newTree, nextFocus) = removeLeaf(tab.rootNode, paneId: paneId)

        if newTree == nil && wouldQuitFromClose(model) {
            return [.showTerminateConfirmation]
        }

        var effects: [Effect] = [.destroySurface(paneId: paneId)]
        markAlertsReadForPane(paneId, in: &model)
        model.lastNotificationTime.removeValue(forKey: paneId)
        model.panes.removeValue(forKey: paneId)

        guard let newRoot = newTree else {
            // Last pane — close tab
            return update(&model, .closeTab(id: tabId))
        }

        updateSelectedTab(&model) { tab in
            tab.rootNode = newRoot
            tab.isZoomed = false
            if let next = nextFocus {
                tab.focusedPaneId = next
            }
        }

        effects.append(.rebuildContentView)
        return effects

    case .movePane(let source, let target, let intent):
        guard source != target else { return [] }
        guard let tab = selectedTab(in: model) else { return [] }
        guard !tab.isZoomed else { return [] }

        let newRoot: SplitNodeModel?
        if intent == .swap {
            newRoot = swapLeaves(tab.rootNode, source, target)
        } else {
            let (direction, insertFirst): (SplitNodeModel.Direction, Bool) = {
                switch intent {
                case .splitTop: return (.vertical, true)
                case .splitBottom: return (.vertical, false)
                case .splitLeft: return (.horizontal, true)
                case .splitRight: return (.horizontal, false)
                case .swap: fatalError("handled above")
                }
            }()
            newRoot = moveLeaf(tab.rootNode, source: source, target: target, direction: direction, insertFirst: insertFirst)
        }

        guard let newRoot = newRoot else { return [] }
        updateSelectedTab(&model) { tab in
            tab.rootNode = newRoot
            tab.focusedPaneId = source
            tab.isZoomed = false
        }
        return [.rebuildContentView]

    case .movePaneToTab(let paneId, let targetTabId):
        // Find source tab containing this pane
        guard let sourceTab = tabForPane(paneId, in: model) else { return [] }
        guard sourceTab.id != targetTabId else { return [] }

        guard tabById(targetTabId, in: model) != nil else { return [] }

        // Remove pane from source tab's tree
        let (newSourceTree, nextFocus) = removeLeaf(sourceTab.rootNode, paneId: paneId)

        // Update target tab: wrap its root with the moved pane
        let chrome = model.panes[paneId].map { deriveTabChrome(from: $0) }
        updateTab(targetTabId, in: &model) { tab in
            tab.rootNode = .split(
                id: SplitId(), direction: .horizontal,
                first: tab.rootNode, second: .leaf(paneId), ratio: 0.5
            )
            tab.focusedPaneId = paneId
            tab.isZoomed = false
            if let chrome {
                tab.title = chrome.title
                tab.subtitle = chrome.subtitle
            }
        }

        // Handle source tab
        if let newRoot = newSourceTree {
            // Source tab still has panes — update it
            updateTab(sourceTab.id, in: &model) { tab in
                tab.rootNode = newRoot
                tab.isZoomed = false
                if tab.focusedPaneId == paneId, let next = nextFocus {
                    tab.focusedPaneId = next
                }
            }
        } else {
            // Source tab is empty — remove it from its group
            removeTab(sourceTab.id, from: &model)
        }

        // Mark alerts read for the moved pane (cross-tab move is a navigation action)
        markAlertsReadForPane(paneId, in: &model)

        // Build effects: defocus old tab's panes, select target tab, rebuild
        var effects: [Effect] = []
        if let oldTabId = model.selectedTabId {
            for oldPaneId in paneIdsForTab(oldTabId, in: model) {
                effects.append(.focusSurface(paneId: oldPaneId, focused: false))
            }
        }
        model.selectedTabId = targetTabId
        effects.append(.rebuildContentView)
        effects.append(.reloadSidebar)
        effects.append(contentsOf: selectionSyncEffects(for: model))
        effects.append(.makeFirstResponder(paneId: paneId))
        return effects

    case .movePaneToNewTab(let paneId, let inGroupId, let atIndex):
        // Find source tab containing this pane
        guard let sourceTab = tabForPane(paneId, in: model) else { return [] }
        guard let dstGroupIdx = model.groups.firstIndex(where: { $0.id == inGroupId }) else { return [] }

        let sourceHasOnlyThisPane: Bool = {
            if case .leaf(let id) = sourceTab.rootNode { return id == paneId } else { return false }
        }()

        // Guard: don't allow if this would leave zero tabs
        if sourceHasOnlyThisPane && totalTabCount(model) == 1 { return [] }

        var effects: [Effect] = []

        // Defocus old tab's panes
        if let oldTabId = model.selectedTabId {
            for oldPaneId in paneIdsForTab(oldTabId, in: model) {
                effects.append(.focusSurface(paneId: oldPaneId, focused: false))
            }
        }

        if sourceHasOnlyThisPane {
            // Path A: Source tab has only this pane — move the tab entity
            guard let (srcGroupIdx, srcTabIdx) = tabLocation(sourceTab.id, in: model) else { return [] }
            let tab = model.groups[srcGroupIdx].tabs.remove(at: srcTabIdx)
            var adjustedIndex = atIndex
            if srcGroupIdx == dstGroupIdx && srcTabIdx < atIndex {
                adjustedIndex -= 1
            }
            let clamped = max(0, min(adjustedIndex, model.groups[dstGroupIdx].tabs.count))
            model.groups[dstGroupIdx].tabs.insert(tab, at: clamped)
            model.selectedTabId = tab.id
        } else {
            // Path B: Source tab has other panes — create new tab
            let (newSourceTree, nextFocus) = removeLeaf(sourceTab.rootNode, paneId: paneId)
            guard let newRoot = newSourceTree else { return [] }

            // Update source tab
            updateTab(sourceTab.id, in: &model) { tab in
                tab.rootNode = newRoot
                tab.isZoomed = false
                if tab.focusedPaneId == paneId, let next = nextFocus {
                    tab.focusedPaneId = next
                }
            }

            // Create new tab for the moved pane
            var newTab = TabModel(id: TabId(), focusedPaneId: paneId, rootNode: .leaf(paneId))
            if let pane = model.panes[paneId] {
                let chrome = deriveTabChrome(from: pane)
                newTab.title = chrome.title
                newTab.subtitle = chrome.subtitle
            }
            let clamped = max(0, min(atIndex, model.groups[dstGroupIdx].tabs.count))
            model.groups[dstGroupIdx].tabs.insert(newTab, at: clamped)
            model.selectedTabId = newTab.id
        }

        markAlertsReadForPane(paneId, in: &model)

        effects.append(.rebuildContentView)
        effects.append(.reloadSidebar)
        effects.append(contentsOf: selectionSyncEffects(for: model))
        effects.append(.makeFirstResponder(paneId: paneId))
        return effects

    case .setTabColor(let tabId, let color):
        updateTab(tabId, in: &model) { t in t.color = color }
        return [.reloadSidebarRow(tabId: tabId)]

    case .renameTab(let id, let name):
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        let customTitle: String? = (trimmed?.isEmpty ?? true) ? nil : trimmed
        updateTab(id, in: &model) { t in t.customTitle = customTitle }
        var effects: [Effect] = [.reloadSidebarRow(tabId: id)]
        if id == model.selectedTabId {
            effects.append(contentsOf: selectionSyncEffects(for: model))
        }
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

        markAlertsReadForPane(paneId, in: &model)
        updateSelectedTab(&model) { t in t.focusedPaneId = paneId }

        // Update tab title/subtitle from newly focused pane
        if let pane = model.panes[paneId] {
            let chrome = deriveTabChrome(from: pane)
            updateSelectedTab(&model) { t in
                t.title = chrome.title
                t.subtitle = chrome.subtitle
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

    // MARK: - Command Tracking

    case .commandStarted(let paneId, let command):
        model.panes[paneId]?.lastCommand = command
        return []

    // MARK: - Export

    case .exportState:
        return [.exportState(toSnapshot(model))]

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

    case .surfaceProgress(let paneId, let state):
        model.panes[paneId]?.progress = state
        return []

    case .surfaceBell(let paneId):
        // No alert for bell on the focused pane of the selected tab
        if let tab = selectedTab(in: model), tab.focusedPaneId == paneId {
            return []
        }

        guard let tab = tabForPane(paneId, in: model) else { return [] }
        let paneTitle = model.panes[paneId]?.title ?? "Terminal"

        let alert = AlertModel(
            id: AlertId(), kind: .bell, paneId: paneId, tabId: tab.id,
            title: "DanTerm", body: paneTitle, createdAt: Date(), isUnread: true
        )
        model.alerts.insert(alert, at: 0)
        if model.alerts.count > 100 { model.alerts.removeLast() }

        var effects: [Effect] = [.rebuildContentView, .reloadSidebarRow(tabId: tab.id)]
        if let group = groupForTab(tab.id, in: model), group.isCollapsed {
            effects.append(.reloadSidebarGroupRow(groupId: group.id))
        }

        effects.append(contentsOf: throttledNotification(
            alertId: alert.id, kind: .bell, paneId: paneId,
            title: "DanTerm", body: paneTitle, tabId: tab.id, model: &model
        ))
        return effects

    case .desktopNotification(let paneId, let title, let body):
        let isFocused = selectedTab(in: model).map { $0.focusedPaneId == paneId } ?? false
        guard let tab = tabForPane(paneId, in: model) else { return [] }

        let alert = AlertModel(
            id: AlertId(), kind: .desktopNotification, paneId: paneId, tabId: tab.id,
            title: title, body: body, createdAt: Date(), isUnread: !isFocused
        )
        model.alerts.insert(alert, at: 0)
        if model.alerts.count > 100 { model.alerts.removeLast() }

        var effects: [Effect] = []
        if !isFocused {
            effects.append(.rebuildContentView)
            effects.append(.reloadSidebarRow(tabId: tab.id))
            if let group = groupForTab(tab.id, in: model), group.isCollapsed {
                effects.append(.reloadSidebarGroupRow(groupId: group.id))
            }
        }

        effects.append(contentsOf: throttledNotification(
            alertId: alert.id, kind: .desktopNotification, paneId: paneId,
            title: title, body: body, tabId: tab.id, model: &model
        ))
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
                var effects: [Effect] = [.rebuildContentView, .reloadSidebar]
                effects.append(contentsOf: selectionSyncEffects(for: model))
                return effects
            }
        }
        return []

    // MARK: - Lifecycle

    case .appBecameActive:
        return [.setAppFocus(true)]

    case .appResignedActive:
        return [.setAppFocus(false)]

    // MARK: - Alerts

    case .markAlertRead(let alertId):
        if let idx = model.alerts.firstIndex(where: { $0.id == alertId }) {
            model.alerts[idx].isUnread = false
        }
        return [.rebuildContentView, .reloadSidebar]

    case .markAllAlertsRead:
        for i in model.alerts.indices { model.alerts[i].isUnread = false }
        return [.rebuildContentView, .reloadSidebar]

    case .activateAlert(let alertId):
        guard let alert = model.alerts.first(where: { $0.id == alertId }) else { return [] }
        // Stale alert: pane or tab no longer exists — just mark read, no navigation
        guard model.panes[alert.paneId] != nil,
              tabForPane(alert.paneId, in: model) != nil else {
            if let idx = model.alerts.firstIndex(where: { $0.id == alertId }) {
                model.alerts[idx].isUnread = false
            }
            return [.rebuildContentView, .reloadSidebar, .dismissAlertsPopover]
        }
        // Mark read
        if let idx = model.alerts.firstIndex(where: { $0.id == alertId }) {
            model.alerts[idx].isUnread = false
        }
        // Navigate: select tab, focus pane, clear zoom if needed, activate app
        var effects = update(&model, .selectTab(id: alert.tabId))
        if let tab = selectedTab(in: model), tab.isZoomed, alert.paneId != tab.focusedPaneId {
            updateSelectedTab(&model) { t in t.isZoomed = false }
        }
        // Always emit refresh effects — selectTab is a no-op when already on
        // the alert's tab, but we still need to clear the red border/badges
        // after marking the alert read.
        effects.append(.rebuildContentView)
        effects.append(.reloadSidebar)
        effects.append(.makeFirstResponder(paneId: alert.paneId))
        effects.append(.activateApp)
        effects.append(.dismissAlertsPopover)
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
                    markAlertsReadForPane(pid, in: &model)
                    model.lastNotificationTime.removeValue(forKey: pid)
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
                effects.append(contentsOf: selectionSyncEffects(for: model))
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
        guard let (srcGroupIdx, tabIdx) = tabLocation(tabId, in: model),
              let dstGroupIdx = model.groups.firstIndex(where: { $0.id == toGroupId }) else { return [] }

        let tab = model.groups[srcGroupIdx].tabs.remove(at: tabIdx)
        var adjustedIndex = atIndex
        if srcGroupIdx == dstGroupIdx && tabIdx < atIndex {
            adjustedIndex -= 1
        }
        let clampedIndex = max(0, min(adjustedIndex, model.groups[dstGroupIdx].tabs.count))
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
    guard let (gi, ti) = tabLocation(tabId, in: model) else { return }
    body(&model.groups[gi].tabs[ti])
}

private func removeTab(_ tabId: TabId, from model: inout AppModel) {
    guard let (gi, ti) = tabLocation(tabId, in: model) else { return }
    model.groups[gi].tabs.remove(at: ti)
}

private func windowTitle(for tab: TabModel) -> String {
    if let subtitle = tab.subtitle, subtitle != tab.displayTitle {
        return "\(tab.displayTitle) — \(subtitle)"
    }
    return tab.displayTitle
}

private func selectionSyncEffects(for model: AppModel) -> [Effect] {
    guard let tab = selectedTab(in: model) else { return [] }
    return [.setWindowTitle(windowTitle(for: tab))]
}

private func markAlertsReadForPane(_ paneId: PaneId, in model: inout AppModel) {
    for i in model.alerts.indices where model.alerts[i].paneId == paneId && model.alerts[i].isUnread {
        model.alerts[i].isUnread = false
    }
}

/// Throttle macOS notification delivery: one per pane per kind every 5 seconds.
private let notificationThrottleInterval: TimeInterval = 1

/// Throttle macOS notification delivery: one per pane per kind every throttle interval.
private func throttledNotification(
    alertId: AlertId, kind: AlertKind, paneId: PaneId,
    title: String, body: String, tabId: TabId, model: inout AppModel
) -> [Effect] {
    let now = Date()
    let shouldNotify: Bool
    if let last = model.lastNotificationTime[paneId]?[kind] {
        shouldNotify = now.timeIntervalSince(last) >= notificationThrottleInterval
    } else {
        shouldNotify = true
    }

    guard shouldNotify else { return [] }

    model.lastNotificationTime[paneId, default: [:]][kind] = now

    return [.sendNotification(
        alertId: alertId, title: title, body: body, tabId: tabId, paneId: paneId
    )]
}
