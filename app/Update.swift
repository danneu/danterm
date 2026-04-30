import Foundation

/// Normalize a raw remote theme string: trim whitespace, default empty to the config default.
func resolveRemoteTheme(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? DanTermConfig.default.remoteTheme : trimmed
}

/// Whether the preferences draft has any changes compared to the committed config.
func isDraftDirty(_ draft: PreferencesDraft, vs config: DanTermConfig, ghostty: GhosttyPrefs?) -> Bool {
    draft.alertClearMode != config.alertClearMode
        || resolveRemoteTheme(draft.remoteTheme) != config.remoteTheme
        || draft.theme != ghostty?.theme
        || draft.fontSize != ghostty?.fontSize
}

@discardableResult
func update(_ model: inout AppModel, _ msg: Msg) -> [Effect] {
    // Single chokepoint: every code path that mutates tab membership or
    // selectedTabId reaches this point. `defer` fires after the matched case
    // returns, and `inout model` makes the reconciled state visible to
    // callers. Without this, MRU updates would have to be sprinkled into
    // every handler that touches tabs (movePaneToTab, surfaceCreationFailed,
    // deleteGroup, restore/import paths, etc.).
    defer { reconcileMru(&model) }

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
        // Persist new tab + pane + selection so a crash doesn't lose the tab.
        effects.append(.scheduleCheckpoint)
        return effects

    case .selectAdjacentTab(let direction):
        guard let targetId = adjacentTabId(direction: direction, in: model) else { return [] }
        return update(&model, .selectTab(id: targetId))

    case .selectTab(let id):
        return applySelectTab(&model, id: id)

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
            return [.showTerminateConfirmation(paneCount: model.panes.count)]
        }

        let tab = model.groups[groupIdx].tabs[tabIdx]
        let groupId = model.groups[groupIdx].id
        let paneIds = allPaneIds(tab.rootNode)

        // Compute fallback selection: prefer predecessor, then successor in flattened order.
        let fallbackTabId: TabId? = {
            guard id == model.selectedTabId else { return nil }
            let allTabs = model.groups.flatMap(\.tabs)
            guard let idx = allTabs.firstIndex(where: { $0.id == id }) else { return nil }
            if idx > 0 { return allTabs[idx - 1].id }
            if idx + 1 < allTabs.count { return allTabs[idx + 1].id }
            return nil
        }()

        var effects: [Effect] = []
        for pid in paneIds {
            effects.append(.destroySurface(paneId: pid))
            removeAlertsForPane(pid, in: &model)
            removePaneSearchState(pid, from: &model)
            model.lastNotificationTime.removeValue(forKey: pid)
            model.panes.removeValue(forKey: pid)
        }

        model.groups[groupIdx].tabs.remove(at: tabIdx)
        removeGroupIfEmpty(groupId, from: &model)

        // Check if all tabs gone
        let allTabs = model.groups.flatMap(\.tabs)
        if allTabs.isEmpty {
            return effects + [.terminate]
        }

        // Select fallback tab if we closed the selected one
        if id == model.selectedTabId, let newId = fallbackTabId {
            model.selectedTabId = newId
            effects.append(.rebuildContentView)
            effects.append(contentsOf: selectionSyncEffects(for: model))
        }
        effects.append(.reloadSidebar)
        // Persist tab removal + new selection so closed tabs don't reappear on restore.
        effects.append(.scheduleCheckpoint)
        return effects

    // MARK: - Pane Management

    case .splitPane(let paneId, let direction):
        guard let tab = selectedTab(in: model) else { return [] }
        let targetPaneId = paneId ?? tab.focusedPaneId
        let newPaneId = PaneId()
        let cwd = model.panes[targetPaneId]?.cwd
        let theme = model.panes[targetPaneId]?.theme

        guard let newRoot = splitLeaf(tab.rootNode, paneId: targetPaneId, direction: direction, newPaneId: newPaneId) else { return [] }

        var newPane = PaneModel(id: newPaneId)
        newPane.theme = theme
        model.panes[newPaneId] = newPane

        // Update the tab in place
        updateSelectedTab(&model) { tab in
            tab.rootNode = newRoot
            tab.focusedPaneId = newPaneId
            tab.isZoomed = false
        }

        var effects: [Effect] = [
            .createSurface(paneId: newPaneId, cwd: cwd, command: nil),
            .rebuildContentView,
            // Persist new split tree so the pane layout survives a crash.
            .scheduleCheckpoint,
        ]
        if theme != nil {
            effects.append(.applyPaneTheme(paneId: newPaneId))
        }
        return effects

    case .closePane(let paneId):
        guard let tabId = model.selectedTabId,
              let tab = selectedTab(in: model) else { return [] }

        let (newTree, nextFocus) = removeLeaf(tab.rootNode, paneId: paneId)

        if newTree == nil && wouldQuitFromClose(model) {
            return [.showTerminateConfirmation(paneCount: model.panes.count)]
        }

        var effects: [Effect] = [.destroySurface(paneId: paneId)]
        removeAlertsForPane(paneId, in: &model)
        removePaneSearchState(paneId, from: &model)
        model.lastNotificationTime.removeValue(forKey: paneId)
        if model.todoPopoverPaneId == paneId {
            model.todoPopoverPaneId = nil
            effects.append(.dismissTodoPopover)
        }
        model.panes.removeValue(forKey: paneId)

        guard let newRoot = newTree else {
            // Last pane — close tab
            return update(&model, .closeTab(id: tabId))
        }

        if model.config.alertClearMode == .focus, let next = nextFocus {
            markAlertsReadForPane(next, in: &model)
        }
        updateSelectedTab(&model) { tab in
            tab.rootNode = newRoot
            tab.isZoomed = false
            if let next = nextFocus {
                tab.focusedPaneId = next
            }
        }

        if let next = nextFocus {
            effects.append(contentsOf: syncFocusedPaneChrome(next, in: &model))
        }

        effects.append(.rebuildContentView)
        // Persist pane removal + updated tree so closed panes stay closed on restore.
        effects.append(.scheduleCheckpoint)
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
        // Persist rearranged split tree so pane positions survive a crash.
        return [.rebuildContentView, .scheduleCheckpoint]

    case .movePaneToTab(let paneId, let targetTabId):
        // Find source tab containing this pane
        guard let sourceTab = tabForPane(paneId, in: model) else { return [] }
        guard sourceTab.id != targetTabId else { return [] }

        guard tabById(targetTabId, in: model) != nil else { return [] }
        let sourceGroupId = groupForTab(sourceTab.id, in: model)?.id

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
        if let sgid = sourceGroupId { removeGroupIfEmpty(sgid, from: &model) }

        // Mark alerts read for the moved pane (focus mode only)
        if model.config.alertClearMode == .focus {
            markAlertsReadForPane(paneId, in: &model)
        }

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
        // Persist cross-tab pane move so the new tree layout survives a crash.
        effects.append(.scheduleCheckpoint)
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
            let srcGroupId = model.groups[srcGroupIdx].id
            let tab = model.groups[srcGroupIdx].tabs.remove(at: srcTabIdx)
            var adjustedIndex = atIndex
            if srcGroupIdx == dstGroupIdx && srcTabIdx < atIndex {
                adjustedIndex -= 1
            }
            let clamped = max(0, min(adjustedIndex, model.groups[dstGroupIdx].tabs.count))
            model.groups[dstGroupIdx].tabs.insert(tab, at: clamped)
            removeGroupIfEmpty(srcGroupId, from: &model)
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

        if model.config.alertClearMode == .focus {
            markAlertsReadForPane(paneId, in: &model)
        }

        effects.append(.rebuildContentView)
        effects.append(.reloadSidebar)
        effects.append(contentsOf: selectionSyncEffects(for: model))
        effects.append(.makeFirstResponder(paneId: paneId))
        // Persist pane-to-new-tab extraction so the tab structure survives a crash.
        effects.append(.scheduleCheckpoint)
        return effects

    case .setTabColors(let tabIds, let color):
        // Apply the chosen color to every requested tab. No toggle-off
        // semantics here -- the cmd-1-on-red-clears UX is resolved at the
        // dispatcher via resolveColorForBatch before this Msg is sent.
        var seen = Set<TabId>()
        let validIds = tabIds.filter { id in
            guard !seen.contains(id), tabLocation(id, in: model) != nil
            else { return false }
            seen.insert(id); return true
        }
        guard !validIds.isEmpty else { return [] }
        var effects: [Effect] = []
        for id in validIds {
            updateTab(id, in: &model) { t in t.color = color }
            effects.append(.updateSidebarTabRow(tabId: id))
        }
        effects.append(.scheduleCheckpoint)
        return effects

    case .clearCustomTitles(let tabIds):
        var seen = Set<TabId>()
        let validIds = tabIds.filter { id in
            guard !seen.contains(id), tabLocation(id, in: model) != nil
            else { return false }
            seen.insert(id); return true
        }
        guard !validIds.isEmpty else { return [] }
        var effects: [Effect] = []
        var selectedTabAffected = false
        for id in validIds {
            updateTab(id, in: &model) { t in t.customTitle = nil }
            effects.append(.updateSidebarTabRow(tabId: id))
            if id == model.selectedTabId { selectedTabAffected = true }
        }
        if selectedTabAffected {
            effects.append(contentsOf: selectionSyncEffects(for: model))
        }
        effects.append(.scheduleCheckpoint)
        return effects

    case .clearAlertsForTabs(let tabIds):
        var seen = Set<TabId>()
        let validIds = tabIds.filter { id in
            guard !seen.contains(id), tabLocation(id, in: model) != nil
            else { return false }
            seen.insert(id); return true
        }
        guard !validIds.isEmpty else { return [] }
        var anyHadUnread = false
        for id in validIds {
            let paneIds = paneIdsForTab(id, in: model)
            let hadUnread = model.alerts.contains {
                $0.isUnread && paneIds.contains($0.paneId) }
            if hadUnread {
                anyHadUnread = true
                for pid in paneIds {
                    markAlertsReadForPane(pid, in: &model)
                }
            }
        }
        guard anyHadUnread else { return [] }
        return [.rebuildContentView, .reloadSidebar]

    case .setPaneTheme(let paneId, let themeName):
        model.panes[paneId]?.theme = themeName
        return [.applyPaneTheme(paneId: paneId), .scheduleCheckpoint]

    case .renameTab(let id, let name):
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        let customTitle: String? = (trimmed?.isEmpty ?? true) ? nil : trimmed
        updateTab(id, in: &model) { t in t.customTitle = customTitle }
        var effects: [Effect] = [.updateSidebarTabRow(tabId: id)]
        if id == model.selectedTabId {
            effects.append(contentsOf: selectionSyncEffects(for: model))
        }
        // Persist custom title so user's rename survives a crash.
        effects.append(.scheduleCheckpoint)
        return effects

    case .sidebarRenameEnded:
        guard let tab = selectedTab(in: model) else { return [] }
        return [.makeFirstResponder(paneId: tab.focusedPaneId)]

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

        if model.config.alertClearMode == .focus {
            markAlertsReadForPane(paneId, in: &model)
        }
        updateSelectedTab(&model) { t in t.focusedPaneId = paneId }

        var effects: [Effect] = [.rebuildContentView]
        effects.append(contentsOf: syncFocusedPaneChrome(paneId, in: &model))
        // Persist focused pane so restore opens the right pane within each tab.
        effects.append(.scheduleCheckpoint)
        return effects

    // MARK: - Command Tracking

    case .commandStarted(let paneId, let command):
        model.panes[paneId]?.lastCommand = command
        // Persist last command so restore can prefill it in the shell.
        return [.scheduleCheckpoint]

    case .commandEnded(let paneId):
        model.panes[paneId]?.isRemote = false
        guard model.panes[paneId]?.remoteThemeOverride != nil else { return [] }
        model.panes[paneId]?.remoteThemeOverride = nil
        return [.applyPaneTheme(paneId: paneId)]

    // MARK: - Remote Detection

    case .remoteSessionStarted(let paneId):
        guard model.panes[paneId] != nil else { return [] }
        model.panes[paneId]?.isRemote = true
        model.panes[paneId]?.remoteThemeOverride = model.config.remoteTheme
        return [.applyPaneTheme(paneId: paneId)]

    // MARK: - Config (external reload)

    case .configLoaded(let newConfig):
        let oldConfig = model.config
        model.config = newConfig
        // Reset draft to match new config if panel is open.
        // Reset DanTerm draft fields to match new config; preserve Ghostty fields
        // (ghosttyPrefsRefreshed handles those separately after CONFIG_CHANGE).
        if model.preferencesDraft != nil {
            model.preferencesDraft!.alertClearMode = newConfig.alertClearMode
            model.preferencesDraft!.remoteTheme = newConfig.remoteTheme
        }
        var effects: [Effect] = [.syncPreferencesPanel]
        if newConfig.remoteTheme != oldConfig.remoteTheme {
            for (paneId, pane) in model.panes where pane.isRemote {
                model.panes[paneId]?.remoteThemeOverride = newConfig.remoteTheme
                effects.append(.applyPaneTheme(paneId: paneId))
            }
        }
        return effects

    // MARK: - Preferences Panel

    case .preferencesOpened(let ghostty):
        // Only create draft on closed → open transition; re-focus is a no-op.
        if model.preferencesDraft == nil {
            model.preferencesDraft = PreferencesDraft(
                alertClearMode: model.config.alertClearMode,
                remoteTheme: model.config.remoteTheme,
                theme: ghostty.theme,
                fontSize: ghostty.fontSize
            )
            model.committedGhosttyPrefs = ghostty
        }
        return [.syncPreferencesPanel]

    case .preferencesClosed:
        model.preferencesDraft = nil
        model.committedGhosttyPrefs = nil
        return []

    case .prefSetAlertClearMode(let mode):
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.alertClearMode = mode
        return [.syncPreferencesPanel]

    case .prefSetRemoteTheme(let rawText):
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.remoteTheme = rawText
        return [.syncPreferencesPanel]

    case .prefResetAlertClearMode:
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.alertClearMode = model.config.alertClearMode
        return [.syncPreferencesPanel]

    case .prefResetRemoteTheme:
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.remoteTheme = model.config.remoteTheme
        return [.syncPreferencesPanel]

    case .prefSetTheme(let text):
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.theme = text
        return [.syncPreferencesPanel]

    case .prefSetFontSize(let text):
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.fontSize = text
        return [.syncPreferencesPanel]

    case .prefResetTheme:
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.theme = model.committedGhosttyPrefs?.theme
        return [.syncPreferencesPanel]

    case .prefResetFontSize:
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.fontSize = model.committedGhosttyPrefs?.fontSize
        return [.syncPreferencesPanel]

    case .ghosttyPrefsRefreshed(let ghostty):
        model.committedGhosttyPrefs = ghostty
        if model.preferencesDraft != nil {
            model.preferencesDraft!.theme = ghostty.theme
            model.preferencesDraft!.fontSize = ghostty.fontSize
        }
        return model.preferencesDraft != nil ? [.syncPreferencesPanel] : []

    case .prefSave:
        guard let draft = model.preferencesDraft else { return [] }
        let resolvedTheme = resolveRemoteTheme(draft.remoteTheme)
        let oldConfig = model.config
        var effects: [Effect] = []
        // Save changed keys to disk.
        if draft.alertClearMode != oldConfig.alertClearMode {
            effects.append(.saveDanTermConfigKey(key: "alert-clear-mode", value: draft.alertClearMode.rawValue))
        }
        if resolvedTheme != oldConfig.remoteTheme {
            effects.append(.saveDanTermConfigKey(key: "remote-theme", value: resolvedTheme))
        }
        // Apply to model.
        model.config.alertClearMode = draft.alertClearMode
        model.config.remoteTheme = resolvedTheme
        // Normalize draft to resolved values post-save.
        model.preferencesDraft!.remoteTheme = resolvedTheme
        // Update remote panes if theme changed.
        if resolvedTheme != oldConfig.remoteTheme {
            for (paneId, pane) in model.panes where pane.isRemote {
                model.panes[paneId]?.remoteThemeOverride = resolvedTheme
                effects.append(.applyPaneTheme(paneId: paneId))
            }
        }
        // Save changed Ghostty keys and trigger reload if any changed.
        let committedGhostty = model.committedGhosttyPrefs ?? GhosttyPrefs()
        var ghosttyChanged = false
        if draft.theme != committedGhostty.theme {
            if let theme = draft.theme {
                effects.append(.saveDanTermConfigKey(key: "theme", value: theme))
            } else {
                effects.append(.removeDanTermConfigKey(key: "theme"))
            }
            ghosttyChanged = true
        }
        if draft.fontSize != committedGhostty.fontSize {
            if let fs = draft.fontSize, let val = Double(fs), val > 0 {
                effects.append(.saveDanTermConfigKey(key: "font-size", value: fs))
                ghosttyChanged = true
            } else if draft.fontSize == nil {
                effects.append(.removeDanTermConfigKey(key: "font-size"))
                ghosttyChanged = true
            }
            // else: invalid font-size — skip, leave dirty
        }
        if ghosttyChanged {
            effects.append(.reloadGhosttyConfig)
            // Optimistically update committed baselines for saved fields.
            // The CONFIG_CHANGE callback will confirm with ghosttyPrefsRefreshed.
            if draft.theme != committedGhostty.theme {
                model.committedGhosttyPrefs?.theme = draft.theme
            }
            // Only update font-size baseline if it was actually saved (valid value or nil).
            let fontSizeSaved = draft.fontSize == nil
                || (draft.fontSize != nil && Double(draft.fontSize!) != nil && Double(draft.fontSize!)! > 0)
            if fontSizeSaved && draft.fontSize != committedGhostty.fontSize {
                model.committedGhosttyPrefs?.fontSize = draft.fontSize
            }
        }
        effects.append(.syncPreferencesPanel)
        return effects

    // MARK: - Export

    case .exportState:
        return [.exportState(toSnapshot(model))]

    // MARK: - Ghostty Callbacks

    case .surfaceTitle(let paneId, let title):
        model.panes[paneId]?.title = title
        guard let tab = tabForPane(paneId, in: model), tab.focusedPaneId == paneId else {
            // Persist pane title even for unfocused panes — it appears in restore.
            return [.scheduleCheckpoint]
        }
        let abbrev = abbreviateHome(title)
        updateTab(tab.id, in: &model) { t in t.title = abbrev }
        var effects: [Effect] = [.updateSidebarTabRow(tabId: tab.id)]
        if tab.id == model.selectedTabId {
            let updatedTab = selectedTab(in: model)!
            effects.append(.setWindowTitle(windowTitle(for: updatedTab)))
        }
        // Persist pane title so restored tabs show the correct name.
        effects.append(.scheduleCheckpoint)
        return effects

    case .surfaceCwd(let paneId, let cwd):
        model.panes[paneId]?.cwd = cwd
        guard let tab = tabForPane(paneId, in: model), tab.focusedPaneId == paneId else {
            // Persist cwd even for unfocused panes — it determines the shell's starting
            // directory on restore.
            return [.scheduleCheckpoint]
        }
        let abbrev = abbreviateHome(cwd)
        updateTab(tab.id, in: &model) { t in t.subtitle = abbrev }
        var effects: [Effect] = [.updateSidebarTabRow(tabId: tab.id)]
        if tab.id == model.selectedTabId {
            let updatedTab = selectedTab(in: model)!
            effects.append(.setWindowTitle(windowTitle(for: updatedTab)))
        }
        // Persist cwd so restored panes open in the correct directory.
        effects.append(.scheduleCheckpoint)
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

        // Hack: ack previous alerts so each pane has at most 1 unread alert.
        // This keeps pane badges boolean and tab badges count panes-with-alerts
        // rather than total alert volume. May replace with a better system later.
        markAlertsReadForPane(paneId, in: &model)

        let alert = AlertModel(
            id: AlertId(), kind: .bell, paneId: paneId,
            title: "DanTerm", body: paneTitle, createdAt: Date(), isUnread: true
        )
        model.alerts.insert(alert, at: 0)
        if model.alerts.count > 100 { model.alerts.removeLast() }

        var effects: [Effect] = [.updatePaneAlertBorder(paneId: paneId), .updateSidebarTabRow(tabId: tab.id)]
        if let group = groupForTab(tab.id, in: model), group.isCollapsed {
            effects.append(.updateSidebarGroupRow(groupId: group.id))
        }

        effects.append(contentsOf: throttledNotification(
            alertId: alert.id, kind: .bell, paneId: paneId,
            title: "DanTerm", body: paneTitle, model: &model
        ))
        return effects

    case .desktopNotification(let paneId, let title, let body):
        // Same as bell: no alert for the focused pane of the selected tab
        if let tab = selectedTab(in: model), tab.focusedPaneId == paneId {
            return []
        }

        guard let tab = tabForPane(paneId, in: model) else { return [] }

        // Hack: ack previous alerts so each pane has at most 1 unread alert.
        // This keeps pane badges boolean and tab badges count panes-with-alerts
        // rather than total alert volume. May replace with a better system later.
        markAlertsReadForPane(paneId, in: &model)

        let alert = AlertModel(
            id: AlertId(), kind: .desktopNotification, paneId: paneId,
            title: title, body: body, createdAt: Date(), isUnread: true
        )
        model.alerts.insert(alert, at: 0)
        if model.alerts.count > 100 { model.alerts.removeLast() }

        var effects: [Effect] = [.updatePaneAlertBorder(paneId: paneId), .updateSidebarTabRow(tabId: tab.id)]
        if let group = groupForTab(tab.id, in: model), group.isCollapsed {
            effects.append(.updateSidebarGroupRow(groupId: group.id))
        }

        effects.append(contentsOf: throttledNotification(
            alertId: alert.id, kind: .desktopNotification, paneId: paneId,
            title: title, body: body, model: &model
        ))
        return effects

    case .surfaceClosed(let paneId):
        return update(&model, .closePane(paneId: paneId))

    case .surfaceCreationFailed(let paneId):
        model.panes.removeValue(forKey: paneId)
        removeAlertsForPane(paneId, in: &model)
        removePaneSearchState(paneId, from: &model)
        model.lastNotificationTime.removeValue(forKey: paneId)
        // Find and remove the tab containing this pane
        for gi in model.groups.indices {
            if let ti = model.groups[gi].tabs.firstIndex(where: { allPaneIds($0.rootNode).contains(paneId) }) {
                let tabId = model.groups[gi].tabs[ti].id
                let groupId = model.groups[gi].id
                model.groups[gi].tabs.remove(at: ti)
                removeGroupIfEmpty(groupId, from: &model)
                if model.selectedTabId == tabId {
                    model.selectedTabId = model.groups.flatMap(\.tabs).first?.id
                }
                if model.groups.flatMap(\.tabs).isEmpty {
                    return [.terminate]
                }
                var effects: [Effect] = [.rebuildContentView, .reloadSidebar]
                effects.append(contentsOf: selectionSyncEffects(for: model))
                // Persist tab removal after a failed surface so it doesn't reappear.
                effects.append(.scheduleCheckpoint)
                return effects
            }
        }
        return []

    // MARK: - Lifecycle

    case .appBecameActive:
        return [.setAppFocus(true)]

    case .appResignedActive:
        return [.setAppFocus(false)]

    case .requestQuit:
        return [.showTerminateConfirmation(paneCount: model.panes.count)]

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
        // Stale alert: pane no longer exists — just mark read, no navigation
        guard model.panes[alert.paneId] != nil else {
            if let idx = model.alerts.firstIndex(where: { $0.id == alertId }) {
                model.alerts[idx].isUnread = false
            }
            return [.rebuildContentView, .reloadSidebar, .dismissAlertsPopover]
        }
        // Mark read (unless manual mode — user must ack explicitly)
        if model.config.alertClearMode != .manual,
           let idx = model.alerts.firstIndex(where: { $0.id == alertId }) {
            model.alerts[idx].isUnread = false
        }
        var effects = navigateToPane(alert.paneId, in: &model)
        effects.append(.activateApp)
        effects.append(.dismissAlertsPopover)
        return effects

    case .goToMostRecentAlertPane:
        // Ack all alerts on the current tab so repeated presses walk through tabs
        var ackedCurrentTab = false
        if let tabId = model.selectedTabId {
            let paneIds = paneIdsForTab(tabId, in: model)
            if model.alerts.contains(where: { $0.isUnread && paneIds.contains($0.paneId) }) {
                for paneId in paneIds {
                    markAlertsReadForPane(paneId, in: &model)
                }
                ackedCurrentTab = true
            }
        }
        guard let alert = model.alerts.first(where: { $0.isUnread && model.panes[$0.paneId] != nil }) else {
            return ackedCurrentTab ? [.rebuildContentView, .reloadSidebar] : []
        }
        return navigateToPane(alert.paneId, in: &model)

    case .setShowAllAlerts(let showAll):
        model.showAllAlerts = showAll
        return []

    case .clearAlertsForPane(let paneId):
        let hadUnread = model.alerts.contains { $0.paneId == paneId && $0.isUnread }
        guard hadUnread else { return [] }
        markAlertsReadForPane(paneId, in: &model)
        return [.rebuildContentView, .reloadSidebar]

    case .ackTabAlerts:
        guard let tabId = model.selectedTabId else { return [] }
        let paneIds = paneIdsForTab(tabId, in: model)
        let hadUnread = model.alerts.contains { $0.isUnread && paneIds.contains($0.paneId) }
        guard hadUnread else { return [] }
        for paneId in paneIds {
            markAlertsReadForPane(paneId, in: &model)
        }
        return [.rebuildContentView, .reloadSidebar]

    case .confirmTerminate:
        return [.terminate]

    case .cancelTerminate:
        return []

    case .terminate:
        return [.terminate]

    // MARK: - Group Management

    case .createGroup(let name):
        let groupId = GroupId()
        let group = GroupModel(id: groupId, name: name)
        model.groups.append(group)
        return update(&model, .createTab(inGroupId: groupId))

    case .deleteGroup(let id, let moveTabs):
        guard let idx = model.groups.firstIndex(where: { $0.id == id }),
              model.groups.count > 1 else { return [] }

        let group = model.groups[idx]
        if !moveTabs && !group.tabs.isEmpty && totalTabCount(model) == group.tabs.count {
            return [.showTerminateConfirmation(paneCount: model.panes.count)]
        }
        if moveTabs {
            guard let adjIdx = adjacentGroupIndex(deletingAt: idx, count: model.groups.count) else { return [] }
            model.groups[adjIdx].tabs.append(contentsOf: group.tabs)
        } else {
            // Close all tabs' surfaces
            var effects: [Effect] = []
            for tab in group.tabs {
                for pid in allPaneIds(tab.rootNode) {
                    effects.append(.destroySurface(paneId: pid))
                    removeAlertsForPane(pid, in: &model)
                    removePaneSearchState(pid, from: &model)
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
            // Persist group deletion + tab removal so they don't reappear.
            effects.append(.scheduleCheckpoint)
            return effects
        }

        model.groups.remove(at: idx)
        // Persist group deletion (tabs moved to default group).
        return [.reloadSidebar, .scheduleCheckpoint]

    case .renameGroup(let id, let name):
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let idx = model.groups.firstIndex(where: { $0.id == id }) else { return [] }
        model.groups[idx].name = trimmed
        // Persist group name so it appears correctly on restore.
        return [.reloadSidebar, .scheduleCheckpoint]

    case .moveTabs(let tabIds, let toGroupId, let atIndex):
        var seen = Set<TabId>()
        let validIds = tabIds.filter { id in
            guard !seen.contains(id), tabLocation(id, in: model) != nil
            else { return false }
            seen.insert(id); return true
        }
        guard !validIds.isEmpty,
              let dstGroupIdx = model.groups.firstIndex(where: { $0.id == toGroupId })
        else { return [] }

        // Pre-removal: how many of the moved tabs sit above atIndex in
        // dst? Their removal will shift the anchor left.
        let validIdSet = Set(validIds)
        let dstTabsPre = model.groups[dstGroupIdx].tabs
        let prefixCount = max(0, min(atIndex, dstTabsPre.count))
        let removedBeforeAnchor = dstTabsPre.prefix(prefixCount)
            .filter { validIdSet.contains($0.id) }.count

        // Remove tabs from sources in input order; collect TabModels for
        // re-insertion. Track source group ids for later pruning
        // (excluding dst — we re-insert into it).
        var movedTabs: [TabModel] = []
        var sourceGroupIdsToPrune: [GroupId] = []
        for id in validIds {
            guard let (gIdx, tIdx) = tabLocation(id, in: model) else { continue }
            let srcGroupId = model.groups[gIdx].id
            let tab = model.groups[gIdx].tabs.remove(at: tIdx)
            movedTabs.append(tab)
            if srcGroupId != toGroupId
               && !sourceGroupIdsToPrune.contains(srcGroupId) {
                sourceGroupIdsToPrune.append(srcGroupId)
            }
        }

        // Tab-only removals don't change group ordering, but re-resolve
        // dst defensively.
        guard let newDstGroupIdx = model.groups.firstIndex(where: { $0.id == toGroupId })
        else { return [] }

        let dstCount = model.groups[newDstGroupIdx].tabs.count
        let adjustedIndex = max(0, min(atIndex - removedBeforeAnchor, dstCount))

        for (offset, tab) in movedTabs.enumerated() {
            model.groups[newDstGroupIdx].tabs.insert(
                tab, at: adjustedIndex + offset)
        }

        for sgid in sourceGroupIdsToPrune {
            removeGroupIfEmpty(sgid, from: &model)
        }

        return [.reloadSidebar, .scheduleCheckpoint]

    case .extractTabsToNewGroup(let tabIds, let groupName):
        // Dedupe and drop ids that no longer exist.
        var seen = Set<TabId>()
        let validIds = tabIds.filter { id in
            guard !seen.contains(id), tabLocation(id, in: model) != nil
            else { return false }
            seen.insert(id); return true
        }
        guard !validIds.isEmpty else { return [] }

        // No-op: extracting every live tab (whether from one group or
        // across many) would prune every source group and leave the new
        // group as the sole group, collapsing existing structure and
        // triggering single-group mode where the promised inline rename
        // has no row to edit.
        let totalTabs = model.groups.reduce(0) { $0 + $1.tabs.count }
        if validIds.count == totalTabs { return [] }

        let newGroupId = GroupId()
        model.groups.append(GroupModel(id: newGroupId, name: groupName))

        // Reuse .moveTabs for tabLocation lookup, clamping, and
        // removeGroupIfEmpty pruning of vacated source groups. The new
        // group is empty, so atIndex: 0 is unambiguous; ids are inserted
        // in the order given. Discard nested effects -- we emit one
        // reloadSidebar + scheduleCheckpoint at the end.
        _ = update(&model, .moveTabs(
            tabIds: validIds, toGroupId: newGroupId, atIndex: 0))
        return [.reloadSidebar, .scheduleCheckpoint]

    case .reorderGroup(let groupId, let toIndex):
        guard let currentIdx = model.groups.firstIndex(where: { $0.id == groupId }) else { return [] }
        let clamped = max(0, min(toIndex, model.groups.count - 1))
        let group = model.groups.remove(at: currentIdx)
        model.groups.insert(group, at: clamped)
        // Persist group ordering so sidebar layout survives a restart.
        return [.reloadSidebar, .scheduleCheckpoint]

    case .toggleGroupCollapse(let groupId):
        guard let idx = model.groups.firstIndex(where: { $0.id == groupId }) else { return [] }
        model.groups[idx].isCollapsed.toggle()
        // Persist collapse state so sidebar groups restore expanded/collapsed.
        return [.scheduleCheckpoint]

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
        // Persist split ratio so pane proportions are restored accurately.
        return [.scheduleCheckpoint]

    // MARK: - Search

    case .startSearch:
        guard let tab = selectedTab(in: model) else { return [] }
        return [.sendStartSearch(paneId: tab.focusedPaneId)]

    case .ghosttyStartSearch(let paneId, let needle):
        if model.searchState[paneId] == nil {
            model.searchState[paneId] = SearchModel()
        }
        if !needle.isEmpty {
            model.searchState[paneId]?.needle = needle
        }
        return [.showSearchOverlay(paneId: paneId), .focusSearchField(paneId: paneId)]

    case .searchNeedleChanged(let paneId, let needle):
        guard model.searchState[paneId] != nil else { return [] }
        model.searchState[paneId]?.needle = needle
        model.searchState[paneId]?.total = nil
        model.searchState[paneId]?.selected = nil
        return [.sendSearchNeedle(paneId: paneId, needle: needle), .showSearchOverlay(paneId: paneId)]

    case .searchNavigate(let paneId, let direction):
        guard model.searchState[paneId] != nil else { return [] }
        return [.sendSearchNavigate(paneId: paneId, direction: direction)]

    case .endSearch(let paneId):
        guard model.searchState[paneId] != nil else { return [] }
        model.searchState.removeValue(forKey: paneId)
        return [.hideSearchOverlay(paneId: paneId), .sendEndSearch(paneId: paneId), .makeFirstResponder(paneId: paneId)]

    case .ghosttySearchTotal(let paneId, let total):
        guard model.searchState[paneId] != nil else { return [] }
        model.searchState[paneId]?.total = total
        return [.showSearchOverlay(paneId: paneId)]

    case .ghosttySearchSelected(let paneId, let selected):
        guard model.searchState[paneId] != nil else { return [] }
        model.searchState[paneId]?.selected = selected
        return [.showSearchOverlay(paneId: paneId)]

    // MARK: - TODO

    case .toggleTodoPopover(let paneId):
        guard model.panes[paneId] != nil else { return [] }
        if model.todoPopoverPaneId == paneId {
            model.todoPopoverPaneId = nil
            return [.dismissTodoPopover]
        }
        model.todoPopoverPaneId = paneId
        return [.showTodoPopover(paneId: paneId)]

    case .todoPopoverClosed(let paneId):
        if model.todoPopoverPaneId == paneId {
            model.todoPopoverPaneId = nil
        }
        return []

    case .addTodo(let paneId, let text):
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, model.panes[paneId] != nil else { return [] }
        let item = TodoItem(id: UUID(), text: trimmed, isDone: false)
        model.panes[paneId]!.todos.append(item)
        return [.scheduleCheckpoint]

    case .toggleTodoDone(let paneId, let todoId):
        guard let idx = model.panes[paneId]?.todos.firstIndex(where: { $0.id == todoId }) else { return [] }
        model.panes[paneId]!.todos[idx].isDone.toggle()
        return [.scheduleCheckpoint]

    case .editTodoText(let paneId, let todoId, let text):
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        guard let idx = model.panes[paneId]?.todos.firstIndex(where: { $0.id == todoId }) else { return [] }
        model.panes[paneId]!.todos[idx].text = trimmed
        return [.scheduleCheckpoint]

    case .deleteTodo(let paneId, let todoId):
        model.panes[paneId]?.todos.removeAll { $0.id == todoId }
        return [.scheduleCheckpoint]

    case .reorderTodo(let paneId, let todoId, let toIndex):
        guard var todos = model.panes[paneId]?.todos,
              let fromIndex = todos.firstIndex(where: { $0.id == todoId }),
              toIndex >= 0, toIndex <= todos.count else { return [] }
        let clampedTo = min(toIndex, todos.count - 1)
        guard fromIndex != clampedTo else { return [] }
        let item = todos.remove(at: fromIndex)
        let insertAt = clampedTo > fromIndex ? clampedTo : clampedTo
        todos.insert(item, at: min(insertAt, todos.count))
        model.panes[paneId]!.todos = todos
        return [.scheduleCheckpoint]

    case .clearCompletedTodos(let paneId):
        model.panes[paneId]?.todos.removeAll { $0.isDone }
        return [.scheduleCheckpoint]

    case .requestClosePane(let paneId):
        guard let pane = model.panes[paneId] else { return [] }
        let uncompletedCount = pane.todos.count { !$0.isDone }
        if uncompletedCount > 0 {
            return [.showClosePaneConfirmation(paneId: paneId, uncompletedCount: uncompletedCount)]
        }
        return update(&model, .closePane(paneId: paneId))

    // MRU tab switcher (real implementations follow in MRU section below)
    case .mruCycleStepped(let direction):
        return mruCycleStep(&model, direction: direction)

    case .mruCycleCommitted:
        return mruCycleCommit(&model)

    case .mruCycleCanceled:
        return mruCycleCancel(&model)

    case .mruCycleOneShot(let direction):
        var effects = mruCycleStep(&model, direction: direction)
        effects.append(contentsOf: mruCycleCommit(&model))
        return effects
    }
}

// MARK: - Tab Selection Helper

/// Body of `.selectTab` extracted into a helper so `mruCycleCommitted` can
/// reuse the focus / rebuild / checkpoint effects without duplicating logic.
private func applySelectTab(_ model: inout AppModel, id: TabId) -> [Effect] {
    guard id != model.selectedTabId else { return [] }

    var effects: [Effect] = []
    if let oldTabId = model.selectedTabId {
        for oldPaneId in paneIdsForTab(oldTabId, in: model) {
            effects.append(.focusSurface(paneId: oldPaneId, focused: false))
        }
    }
    model.selectedTabId = id
    if model.config.alertClearMode == .focus, let tab = selectedTab(in: model) {
        markAlertsReadForPane(tab.focusedPaneId, in: &model)
    }
    effects.append(.rebuildContentView)
    effects.append(.reloadSidebar)
    effects.append(contentsOf: selectionSyncEffects(for: model))
    effects.append(.scheduleCheckpoint)
    return effects
}

// MARK: - MRU Cycle Handlers

private func mruCycleStep(_ model: inout AppModel, direction: MruDirection) -> [Effect] {
    // Empty MRU: nothing to cycle through. Avoids modulo-by-zero below.
    guard !model.mruOrder.isEmpty else { return [] }

    if model.mruCycle == nil {
        // Freeze current order. cursorIndex starts at 0 (current tab); the
        // step below moves it to the first cycle target.
        model.mruCycle = MruCycleState(frozenOrder: model.mruOrder, cursorIndex: 0)
    }

    guard var cycle = model.mruCycle else { return [] }
    let count = cycle.frozenOrder.count
    // Full macOS Cmd-Tab parity: wrap in both directions, including on summon.
    // First .older from idle: 0 -> 1 (next-most-recent).
    // First .newer from idle: 0 -> count-1 (least-recently-used; like cmd-shift-tab).
    // Mid-cycle past either end: wraps around.
    switch direction {
    case .older: cycle.cursorIndex = (cycle.cursorIndex + 1) % count
    case .newer: cycle.cursorIndex = (cycle.cursorIndex - 1 + count) % count
    }
    model.mruCycle = cycle
    return [.showSwitcherOverlay]
}

private func mruCycleCommit(_ model: inout AppModel) -> [Effect] {
    guard let cycle = model.mruCycle else { return [] }

    // Tabs may have been removed mid-cycle (closeTab, surfaceCreationFailed,
    // last-pane closePane, automation). Filter frozenOrder against live tabs
    // and remap the cursor before reading the chosen id.
    guard let resolved = resolveLiveCycle(cycle, in: model) else {
        // Every frozen tab is gone; treat as cancel.
        model.mruCycle = nil
        return [.hideSwitcherOverlay]
    }

    let chosenId = resolved.liveOrder[resolved.cursorIndex]
    model.mruCycle = nil

    var effects: [Effect] = []
    if chosenId != model.selectedTabId {
        effects.append(contentsOf: applySelectTab(&model, id: chosenId))
    }
    effects.append(.hideSwitcherOverlay)
    return effects
}

private func mruCycleCancel(_ model: inout AppModel) -> [Effect] {
    guard model.mruCycle != nil else { return [] }
    model.mruCycle = nil
    return [.hideSwitcherOverlay]
}

// MARK: - Helpers

/// Navigate to a pane: select its current tab, clear zoom if needed, focus the pane.
private func navigateToPane(_ paneId: PaneId, in model: inout AppModel) -> [Effect] {
    guard let currentTab = tabForPane(paneId, in: model) else { return [] }
    var effects = update(&model, .selectTab(id: currentTab.id))
    if let tab = selectedTab(in: model), tab.isZoomed, paneId != tab.focusedPaneId {
        updateSelectedTab(&model) { t in t.isZoomed = false }
    }
    // Always emit refresh effects — selectTab is a no-op when already on
    // the pane's tab, but we still need to update borders/badges.
    effects.append(.rebuildContentView)
    effects.append(.reloadSidebar)
    effects.append(.makeFirstResponder(paneId: paneId))
    return effects
}

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

/// Remove a specific group if it has zero tabs, unless it's the sole group.
private func removeGroupIfEmpty(_ groupId: GroupId, from model: inout AppModel) {
    guard model.groups.count > 1,
          let idx = model.groups.firstIndex(where: { $0.id == groupId }),
          model.groups[idx].tabs.isEmpty else { return }
    model.groups.remove(at: idx)
}

private func windowTitle(for tab: TabModel) -> String {
    if let subtitle = tab.subtitle, subtitle != tab.displayTitle {
        return "\(tab.displayTitle) — \(subtitle)"
    }
    return tab.displayTitle
}

/// Sync the selected tab's title/subtitle from the given pane and return
/// sidebar + window-title effects.
private func syncFocusedPaneChrome(_ paneId: PaneId, in model: inout AppModel) -> [Effect] {
    if let pane = model.panes[paneId] {
        let chrome = deriveTabChrome(from: pane)
        updateSelectedTab(&model) { t in
            t.title = chrome.title
            t.subtitle = chrome.subtitle
        }
    }
    var effects: [Effect] = []
    if let tab = selectedTab(in: model) {
        effects.append(.setWindowTitle(windowTitle(for: tab)))
        effects.append(.updateSidebarTabRow(tabId: tab.id))
        if let group = groupForTab(tab.id, in: model), group.isCollapsed {
            effects.append(.updateSidebarGroupRow(groupId: group.id))
        }
    }
    return effects
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

/// Remove all alerts for a pane that is being destroyed.
private func removeAlertsForPane(_ paneId: PaneId, in model: inout AppModel) {
    model.alerts.removeAll { $0.paneId == paneId }
}

/// Throttle macOS notification delivery: one per pane per kind every 5 seconds.
private let notificationThrottleInterval: TimeInterval = 1

/// Throttle macOS notification delivery: one per pane per kind every throttle interval.
private func throttledNotification(
    alertId: AlertId, kind: AlertKind, paneId: PaneId,
    title: String, body: String, model: inout AppModel
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

    return [.sendNotification(alertId: alertId, title: title, body: body)]
}
