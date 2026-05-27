// Pure update function for DanTerm's Elm-style state machine.
import Foundation
import DanTermProtocol

@discardableResult
func update(_ model: inout AppModel, _ msg: Msg) -> [Command] {
    // Single chokepoint: every code path that mutates tab membership or
    // selectedTabId reaches this point. `defer` fires after the matched case
    // returns, and `inout model` makes the reconciled state visible to
    // callers. Without this, MRU updates would have to be sprinkled into
    // every handler that touches tabs (movePaneToTab, surfaceCreationFailed,
    // deleteGroup, restore/import paths, etc.).
    let strandedPopoverPrev = todoPopoverStrandKey(model)
    defer {
        reconcileMru(&model)
        reconcileTodoPopover(&model, previous: strandedPopoverPrev)
    }

    switch msg {

    // MARK: - IPC

    case .ipcRequest(let reqId, let method, let params, let context):
        return handleIpcRequest(
            &model,
            reqId: reqId,
            method: method,
            params: params,
            context: context
        )

    // MARK: - Tab Management

    case .createTab(let inGroupId, let position, let launch, let background):
        let paneId = PaneId()
        let tabId = TabId()
        let cwd = launch?.cwd ?? currentCwd(in: model)

        var pane = PaneModel(id: paneId)
        if let title = launch?.title {
            pane.title = title
        }

        // The leaf owns the pane content directly -- no separate dict write.
        var tab = TabModel(id: tabId, focusedPaneId: paneId, rootNode: .leaf(pane))
        if let title = launch?.title {
            tab.customTitle = title
        }

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
        // .atGroupEnd always appends. .afterSelected and .afterTab insert
        // after their reference tab when it lives in the target group,
        // otherwise they append.
        switch position {
        case .atGroupEnd:
            model.groups[targetGroupIndex].tabs.append(tab)
        case .afterSelected:
            if let selId = model.selectedTabId,
               let selIdx = model.groups[targetGroupIndex].tabs.firstIndex(where: { $0.id == selId }) {
                model.groups[targetGroupIndex].tabs.insert(tab, at: selIdx + 1)
            } else {
                model.groups[targetGroupIndex].tabs.append(tab)
            }
        case .afterTab(let refTabId):
            if let refIdx = model.groups[targetGroupIndex].tabs.firstIndex(where: { $0.id == refTabId }) {
                model.groups[targetGroupIndex].tabs.insert(tab, at: refIdx + 1)
            } else {
                model.groups[targetGroupIndex].tabs.append(tab)
            }
        }

        // Defocus old tab's panes
        var commands: [Command] = []
        if !background, let oldTabId = model.selectedTabId {
            for oldPaneId in paneIdsForTab(oldTabId, in: model) {
                commands.append(.focusSurface(paneId: oldPaneId, focused: false))
            }
        }

        if !background {
            model.selectedTabId = tabId
        }

        commands.append(.createSurface(
            paneId: paneId,
            cwd: cwd,
            command: launch?.cmd,
            launchCommand: nil,
            waitAfterCommand: true
        ))
        // Persist new tab + pane + selection so a crash doesn't lose the tab.
        commands.append(.scheduleCheckpoint)
        return commands

    case .selectAdjacentTab(let direction):
        guard let targetId = adjacentTabId(direction: direction, in: model) else { return [] }
        return update(&model, .selectTab(id: targetId))

    case .selectTab(let id):
        return applySelectTab(&model, id: id)

    case .requestCloseTab(let id):
        guard let tab = tabById(id, in: model) else { return [] }
        let paneCount = allPaneIds(tab.rootNode).count
        let uncompletedTodos = tabTodoRollup(id, in: model).uncompleted

        if paneCount > 1 || uncompletedTodos > 0 {
            let isLastTab = totalTabCount(model) == 1
            return emitCloseTabConfirmation(
                &model, tabId: id, tabTitle: tab.displayTitle,
                paneCount: paneCount, isLastTab: isLastTab,
                uncompletedTodoCount: uncompletedTodos
            )
        }

        return update(&model, .closeTab(id: id))

    case .requestCloseTabs(let ids):
        let normalized = normalizedLiveTabIds(ids, in: model)
        guard !normalized.isEmpty else { return [] }
        guard normalized.count > 1 else {
            return update(&model, .requestCloseTab(id: normalized[0]))
        }
        return emitCloseTabsConfirmation(&model, ids: normalized)

    case .closeTab(let id):
        guard tabLocation(id, in: model) != nil else { return [] }

        if wouldQuitFromClose(model) {
            return emitTerminateConfirmation(&model)
        }

        var commands = closeTabBody(&model, id: id)

        // Check if all tabs gone
        let allTabs = model.groups.flatMap(\.tabs)
        if allTabs.isEmpty {
            return commands + [.terminate]
        }
        // Persist tab removal + new selection so closed tabs don't reappear on restore.
        commands.append(.scheduleCheckpoint)
        return commands

    // MARK: - Pane Management

    case .splitPane(let paneId, let direction, let launch, let background):
        let tab: TabModel
        if let paneId {
            guard let found = tabForPane(paneId, in: model) else { return [] }
            tab = found
        } else {
            guard let found = selectedTab(in: model) else { return [] }
            tab = found
        }
        let targetPaneId = paneId ?? tab.focusedPaneId
        let newPaneId = PaneId()
        let cwd = launch?.cwd ?? model.pane(targetPaneId)?.cwd
        let theme = model.pane(targetPaneId)?.theme

        var newPane = PaneModel(id: newPaneId)
        if let title = launch?.title {
            newPane.title = title
        }
        newPane.theme = theme

        // splitLeaf embeds the new pane's payload directly into the leaf.
        guard let newRoot = splitLeaf(tab.rootNode, paneId: targetPaneId, direction: direction, newPane: newPane) else { return [] }

        // Update the tab in place
        updateTab(tab.id, in: &model) { tab in
            tab.rootNode = newRoot
            if !background {
                tab.focusedPaneId = newPaneId
            }
            tab.isZoomed = false
        }

        var commands: [Command] = [
            .createSurface(
                paneId: newPaneId,
                cwd: cwd,
                command: launch?.cmd,
                launchCommand: nil,
                waitAfterCommand: true
            ),
        ]
        // Persist new split tree so the pane layout survives a crash.
        commands.append(.scheduleCheckpoint)
        return commands

    case .closePane(let paneId):
        guard let tabId = model.selectedTabId,
              let tab = selectedTab(in: model) else { return [] }

        // removeLeaf drops the leaf (and its pane payload) atomically; the close
        // path discards the removed pane. Side-table cleanup stays here.
        let (newTree, nextFocus, _) = removeLeaf(tab.rootNode, paneId: paneId)

        if newTree == nil && wouldQuitFromClose(model) {
            return emitTerminateConfirmation(&model)
        }

        // Surface teardown is reconcileSurfaceExistence's now (paneId leaves the tree
        // below, so the next reconcile tears its surface down); keep side-table cleanup.
        var commands: [Command] = []
        removeAlertsForPane(paneId, in: &model)
        removePaneSearchState(paneId, from: &model)
        model.lastNotificationTime.removeValue(forKey: paneId)
        if model.todoPopover == .pane(paneId) {
            model.todoPopover = nil
            commands.append(.dismissTodoPopover)
        }

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

        // Persist pane removal + updated tree so closed panes stay closed on restore.
        commands.append(.scheduleCheckpoint)
        return commands

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
        return [.scheduleCheckpoint]

    case .movePaneToTab(let paneId, let targetTabId):
        // Find source tab containing this pane
        guard let sourceTab = tabForPane(paneId, in: model) else { return [] }
        guard sourceTab.id != targetTabId else { return [] }

        guard tabById(targetTabId, in: model) != nil else { return [] }
        let sourceGroupId = groupForTab(sourceTab.id, in: model)?.id

        // Remove pane from source tab's tree, capturing its full payload so cwd/
        // theme/todos physically travel to the target tab (no global-dict ref).
        let (newSourceTree, nextFocus, removed) = removeLeaf(sourceTab.rootNode, paneId: paneId)
        guard let movedPane = removed else { return [] }

        // Update target tab: wrap its root with the moved pane.
        updateTab(targetTabId, in: &model) { tab in
            tab.rootNode = .split(
                id: SplitId(), direction: .horizontal,
                first: tab.rootNode, second: .leaf(movedPane), ratio: 0.5
            )
            tab.focusedPaneId = paneId
            tab.isZoomed = false
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

        // Build commands: defocus old tab's panes, then select + focus the target tab.
        var commands: [Command] = []
        if let oldTabId = model.selectedTabId {
            for oldPaneId in paneIdsForTab(oldTabId, in: model) {
                commands.append(.focusSurface(paneId: oldPaneId, focused: false))
            }
        }
        model.selectedTabId = targetTabId
        commands.append(.makeFirstResponder(paneId: paneId))
        // Persist cross-tab pane move so the new tree layout survives a crash.
        commands.append(.scheduleCheckpoint)
        return commands

    case .movePaneToNewTab(let paneId, let inGroupId, let atIndex):
        // Find source tab containing this pane
        guard let sourceTab = tabForPane(paneId, in: model) else { return [] }
        guard let dstGroupIdx = model.groups.firstIndex(where: { $0.id == inGroupId }) else { return [] }

        let sourceHasOnlyThisPane: Bool = {
            if case .leaf(let p) = sourceTab.rootNode { return p.id == paneId } else { return false }
        }()

        // Guard: don't allow if this would leave zero tabs
        if sourceHasOnlyThisPane && totalTabCount(model) == 1 { return [] }

        var commands: [Command] = []

        // Defocus old tab's panes
        if let oldTabId = model.selectedTabId {
            for oldPaneId in paneIdsForTab(oldTabId, in: model) {
                commands.append(.focusSurface(paneId: oldPaneId, focused: false))
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
            let (newSourceTree, nextFocus, removed) = removeLeaf(sourceTab.rootNode, paneId: paneId)
            guard let newRoot = newSourceTree, let movedPane = removed else { return [] }

            // Update source tab
            updateTab(sourceTab.id, in: &model) { tab in
                tab.rootNode = newRoot
                tab.isZoomed = false
                if tab.focusedPaneId == paneId, let next = nextFocus {
                    tab.focusedPaneId = next
                }
            }

            // Create new tab for the moved pane, carrying its full payload.
            let newTab = TabModel(id: TabId(), focusedPaneId: paneId, rootNode: .leaf(movedPane))
            let clamped = max(0, min(atIndex, model.groups[dstGroupIdx].tabs.count))
            model.groups[dstGroupIdx].tabs.insert(newTab, at: clamped)
            model.selectedTabId = newTab.id
        }

        if model.config.alertClearMode == .focus {
            markAlertsReadForPane(paneId, in: &model)
        }

        commands.append(.makeFirstResponder(paneId: paneId))
        // Persist pane-to-new-tab extraction so the tab structure survives a crash.
        commands.append(.scheduleCheckpoint)
        return commands

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
        var commands: [Command] = []
        for id in validIds {
            updateTab(id, in: &model) { t in t.color = color }
        }
        // The color stripe updates via reconcileSidebar (color is in the projection).
        commands.append(.scheduleCheckpoint)
        return commands

    case .clearCustomTitles(let tabIds):
        var seen = Set<TabId>()
        let validIds = tabIds.filter { id in
            guard !seen.contains(id), tabLocation(id, in: model) != nil
            else { return false }
            seen.insert(id); return true
        }
        guard !validIds.isEmpty else { return [] }
        for id in validIds {
            updateTab(id, in: &model) { t in t.customTitle = nil }
        }
        // The cleared rows reconcile via reconcileSidebar and the selected tab's window
        // chrome via reconcileWindowChrome. Persist so the batch clear survives a crash.
        return [.scheduleCheckpoint]

    case .clearAlertsForTabs(let tabIds):
        var seen = Set<TabId>()
        let validIds = tabIds.filter { id in
            guard !seen.contains(id), tabLocation(id, in: model) != nil
            else { return false }
            seen.insert(id); return true
        }
        guard !validIds.isEmpty else { return [] }
        var affectedPaneIds: [PaneId] = []
        for id in validIds {
            let paneIds = paneIdsForTab(id, in: model)
            let unreadPaneIds = unreadAlertPaneIds(for: paneIds, in: model)
            if !unreadPaneIds.isEmpty {
                affectedPaneIds.append(contentsOf: unreadPaneIds)
                for pid in unreadPaneIds { markAlertsReadForPane(pid, in: &model) }
            }
        }
        guard !affectedPaneIds.isEmpty else { return [] }
        // Tab/group bell badges reconcile via reconcileSidebar after the alerts read above.
        return []

    case .setPaneTheme(let paneId, let themeName):
        model.updatePane(paneId) { $0.theme = themeName }
        return [.scheduleCheckpoint]

    case .renameTab(let id, let name):
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        let customTitle: String? = (trimmed?.isEmpty ?? true) ? nil : trimmed
        updateTab(id, in: &model) { t in t.customTitle = customTitle }
        // The renamed row updates via reconcileSidebar (displayTitle is in the projection)
        // and the selected tab's window chrome via reconcileWindowChrome. Persist so the
        // rename survives a crash.
        return [.scheduleCheckpoint]

    case .sidebarRenameEnded:
        guard let tab = selectedTab(in: model) else { return [] }
        return [.makeFirstResponder(paneId: tab.focusedPaneId)]

    case .focusDirection(let direction, let side):
        guard let tab = selectedTab(in: model) else { return [] }
        if tab.isZoomed {
            updateSelectedTab(&model) { t in t.isZoomed = false }
            return []
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

        // Persist focused pane so restore opens the right pane within each tab.
        return [.scheduleCheckpoint]

    // MARK: - Command Tracking

    case .commandStarted(let paneId, let command):
        model.updatePane(paneId) { $0.lastCommand = command }
        // Persist last command so restore can prefill it in the shell.
        return [.scheduleCheckpoint]

    case .commandEnded(let paneId):
        guard let pane = model.pane(paneId) else { return [] }
        model.updatePane(paneId) { p in
            p.isRemote = false
            p.remoteSession = nil
        }
        guard pane.remoteThemeOverride != nil else { return [] }
        model.updatePane(paneId) { $0.remoteThemeOverride = nil }
        return []

    // MARK: - Remote Detection

    case .remoteSessionStarted(let paneId):
        guard model.pane(paneId) != nil else { return [] }
        let remoteTheme = model.config.remoteTheme
        model.updatePane(paneId) { p in
            p.isRemote = true
            p.remoteSession = nil
            p.remoteThemeOverride = remoteTheme
        }
        return []

    case .remoteSessionReported(let paneId, let session):
        guard let existing = model.pane(paneId) else { return [] }
        let wasRemote = existing.isRemote
        let oldSession = existing.remoteSession
        let remoteTheme = model.config.remoteTheme
        model.updatePane(paneId) { p in
            p.isRemote = true
            p.remoteSession = session
            if !wasRemote {
                p.remoteThemeOverride = remoteTheme
            }
        }

        guard !wasRemote || oldSession != session else { return [] }
        return []

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
        if newConfig.remoteTheme != oldConfig.remoteTheme {
            // Two passes: collect remote pane ids, then updatePane
            // (can't mutate via updatePane while iterating model.allPanes).
            for paneId in model.allPanes.filter(\.isRemote).map(\.id) {
                model.updatePane(paneId) { $0.remoteThemeOverride = newConfig.remoteTheme }
            }
        }
        return []

    case .ghosttyConfigReloaded:
        model.ghosttyConfigGeneration += 1
        return []

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
        return []

    case .preferencesClosed:
        model.preferencesDraft = nil
        model.committedGhosttyPrefs = nil
        return []

    case .prefSetAlertClearMode(let mode):
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.alertClearMode = mode
        return []

    case .prefSetRemoteTheme(let rawText):
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.remoteTheme = rawText
        return []

    case .prefResetAlertClearMode:
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.alertClearMode = model.config.alertClearMode
        return []

    case .prefResetRemoteTheme:
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.remoteTheme = model.config.remoteTheme
        return []

    case .prefSetTheme(let text):
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.theme = text
        return []

    case .prefSetFontSize(let text):
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.fontSize = text
        return []

    case .prefResetTheme:
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.theme = model.committedGhosttyPrefs?.theme
        return []

    case .prefResetFontSize:
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.fontSize = model.committedGhosttyPrefs?.fontSize
        return []

    case .ghosttyPrefsRefreshed(let ghostty):
        model.committedGhosttyPrefs = ghostty
        if model.preferencesDraft != nil {
            model.preferencesDraft!.theme = ghostty.theme
            model.preferencesDraft!.fontSize = ghostty.fontSize
        }
        return []

    case .prefSave:
        guard let draft = model.preferencesDraft else { return [] }
        let resolvedTheme = resolveRemoteTheme(draft.remoteTheme)
        let oldConfig = model.config
        var commands: [Command] = []
        // Save changed keys to disk.
        if draft.alertClearMode != oldConfig.alertClearMode {
            commands.append(.saveDanTermConfigKey(key: "alert-clear-mode", value: draft.alertClearMode.rawValue))
        }
        if resolvedTheme != oldConfig.remoteTheme {
            commands.append(.saveDanTermConfigKey(key: "remote-theme", value: resolvedTheme))
        }
        // Apply to model.
        model.config.alertClearMode = draft.alertClearMode
        model.config.remoteTheme = resolvedTheme
        // Normalize draft to resolved values post-save.
        model.preferencesDraft!.remoteTheme = resolvedTheme
        // Update remote panes if theme changed.
        if resolvedTheme != oldConfig.remoteTheme {
            for paneId in model.allPanes.filter(\.isRemote).map(\.id) {
                model.updatePane(paneId) { $0.remoteThemeOverride = resolvedTheme }
            }
        }
        // Save changed Ghostty keys and trigger reload if any changed.
        let committedGhostty = model.committedGhosttyPrefs ?? GhosttyPrefs()
        var ghosttyChanged = false
        if draft.theme != committedGhostty.theme {
            if let theme = draft.theme {
                commands.append(.saveDanTermConfigKey(key: "theme", value: theme))
            } else {
                commands.append(.removeDanTermConfigKey(key: "theme"))
            }
            ghosttyChanged = true
        }
        if draft.fontSize != committedGhostty.fontSize {
            if let fs = draft.fontSize, let val = Double(fs), val > 0 {
                commands.append(.saveDanTermConfigKey(key: "font-size", value: fs))
                ghosttyChanged = true
            } else if draft.fontSize == nil {
                commands.append(.removeDanTermConfigKey(key: "font-size"))
                ghosttyChanged = true
            }
            // else: invalid font-size — skip, leave dirty
        }
        if ghosttyChanged {
            commands.append(.reloadGhosttyConfig)
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
        return commands

    // MARK: - Export

    case .exportState:
        return [.exportState(toSnapshot(model))]

    // MARK: - Ghostty Callbacks

    case .surfaceTitle(let paneId, let title):
        model.updatePane(paneId) { $0.title = title }
        // Tab/window chrome derives from the focused pane title just set above.
        // Persist so restored tabs show the correct name.
        return [.scheduleCheckpoint]

    case .surfaceCwd(let paneId, let cwd):
        model.updatePane(paneId) { $0.cwd = cwd }
        // Tab/window chrome derives from the focused pane cwd just set above.
        // Persist so restored panes open in the right dir.
        return [.scheduleCheckpoint]

    case .surfaceProgress(let paneId, let state):
        model.updatePane(paneId) { $0.progress = state }
        return []

    case .surfaceBell(let paneId):
        // No alert for bell on the focused pane of the selected tab
        if let tab = selectedTab(in: model), tab.focusedPaneId == paneId {
            return []
        }

        guard tabForPane(paneId, in: model) != nil else { return [] }
        let paneTitle = model.pane(paneId)?.title ?? "Terminal"

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

        // The tab/group bell badges now ride reconcileSidebar (the projection counts
        // unread alerts per tab and per collapsed group); only the notification remains.
        var commands: [Command] = []

        commands.append(contentsOf: throttledNotification(
            alertId: alert.id, kind: .bell, paneId: paneId,
            title: "DanTerm", body: paneTitle, model: &model
        ))
        return commands

    case .desktopNotification(let paneId, let title, let body):
        // Same as bell: no alert for the focused pane of the selected tab
        if let tab = selectedTab(in: model), tab.focusedPaneId == paneId {
            return []
        }

        guard tabForPane(paneId, in: model) != nil else { return [] }

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

        // Tab/group bell badges ride reconcileSidebar (see surfaceBell).
        var commands: [Command] = []

        commands.append(contentsOf: throttledNotification(
            alertId: alert.id, kind: .desktopNotification, paneId: paneId,
            title: title, body: body, model: &model
        ))
        return commands

    case .surfaceClosed(let paneId):
        return update(&model, .closePane(paneId: paneId))

    case .surfaceCreationFailed(let paneId):
        // Surface creation failure removes the whole containing tab, so every
        // sibling pane must be cleaned up as if the tab had been closed.
        for gi in model.groups.indices {
            if let ti = model.groups[gi].tabs.firstIndex(where: { allPaneIds($0.rootNode).contains(paneId) }) {
                let tab = model.groups[gi].tabs[ti]
                let tabId = tab.id
                let groupId = model.groups[gi].id
                var commands: [Command] = []
                for pid in allPaneIds(tab.rootNode) {
                    // Surface teardown is reconcileSurfaceExistence's (these panes leave the
                    // tree below); keep the id-keyed side-table cleanup here.
                    removeAlertsForPane(pid, in: &model)
                    removePaneSearchState(pid, from: &model)
                    model.lastNotificationTime.removeValue(forKey: pid)
                }

                model.groups[gi].tabs.remove(at: ti)
                removeGroupIfEmpty(groupId, from: &model)

                if model.selectedTabId == tabId {
                    model.selectedTabId = model.groups.flatMap(\.tabs).first?.id
                }
                if model.groups.flatMap(\.tabs).isEmpty {
                    return commands + [.terminate]
                }
                // Persist tab removal after a failed surface so it doesn't reappear.
                commands.append(.scheduleCheckpoint)
                return commands
            }
        }
        // A pane in no tree cannot exist now, so this fallback is just defensive
        // side-table cleanup -- no tree/pane removal needed.
        removeAlertsForPane(paneId, in: &model)
        removePaneSearchState(paneId, from: &model)
        model.lastNotificationTime.removeValue(forKey: paneId)
        return []

    // MARK: - Lifecycle

    case .appBecameActive:
        return [.setAppFocus(true)]

    case .appResignedActive:
        if model.jumpMode != nil {
            model.jumpMode = nil   // jump badges clear via reconcileSidebar
        }
        return [.setAppFocus(false)]

    case .requestQuit:
        return emitTerminateConfirmation(&model)

    // MARK: - Alerts

    case .markAlertRead(let alertId):
        // Marking the alert read updates the tab/group bell badges via reconcileSidebar.
        if let idx = model.alerts.firstIndex(where: { $0.id == alertId }) {
            model.alerts[idx].isUnread = false
        }
        return []

    case .markAllAlertsRead:
        for i in model.alerts.indices { model.alerts[i].isUnread = false }
        return []   // bell badges reconcile via reconcileSidebar

    case .activateAlert(let alertId):
        guard let alert = model.alerts.first(where: { $0.id == alertId }) else { return [] }
        // Stale alert: pane no longer exists — just mark read, no navigation
        guard model.pane(alert.paneId) != nil else {
            if let idx = model.alerts.firstIndex(where: { $0.id == alertId }) {
                model.alerts[idx].isUnread = false
            }
            return [.dismissAlertsPopover]
        }
        // Mark read (unless manual mode — user must ack explicitly)
        if model.config.alertClearMode != .manual,
           let idx = model.alerts.firstIndex(where: { $0.id == alertId }) {
            model.alerts[idx].isUnread = false
        }
        var commands = navigateToPane(alert.paneId, in: &model)
        commands.append(.activateApp)
        commands.append(.dismissAlertsPopover)
        return commands

    case .goToMostRecentAlertPane:
        // Ack only the focused pane before searching so repeated presses walk every
        // unread pane, including sibling panes in the current split.
        if let tab = selectedTab(in: model),
           paneHasUnreadAlert(tab.focusedPaneId, alerts: model.alerts) {
            markAlertsReadForPane(tab.focusedPaneId, in: &model)
        }
        // Acked-pane bell badges reconcile via reconcileSidebar.
        guard let alert = model.alerts.first(where: { $0.isUnread && model.pane($0.paneId) != nil }) else {
            return []
        }
        return navigateToPane(alert.paneId, in: &model)

    case .setShowAllAlerts(let showAll):
        model.showAllAlerts = showAll
        return []

    case .clearAlertsForPane(let paneId):
        let hadUnread = model.alerts.contains { $0.paneId == paneId && $0.isUnread }
        guard hadUnread else { return [] }
        markAlertsReadForPane(paneId, in: &model)
        return []   // bell badge reconciles via reconcileSidebar

    case .ackTabAlerts:
        guard let tabId = model.selectedTabId else { return [] }
        let paneIds = paneIdsForTab(tabId, in: model)
        let affectedPaneIds = unreadAlertPaneIds(for: paneIds, in: model)
        guard !affectedPaneIds.isEmpty else { return [] }
        for paneId in affectedPaneIds { markAlertsReadForPane(paneId, in: &model) }
        return []   // bell badges reconcile via reconcileSidebar

    case .confirmTerminate:
        model.pendingConfirmation = nil
        return [.terminate]

    case .cancelTerminate:
        model.pendingConfirmation = nil
        return []

    case .confirmCloseTab(let id):
        model.pendingConfirmation = nil
        return update(&model, .closeTab(id: id))

    case .cancelCloseTab:
        model.pendingConfirmation = nil
        return []

    case .confirmCloseTabs(let ids):
        model.pendingConfirmation = nil
        let normalized = normalizedLiveTabIds(ids, in: model)
        guard !normalized.isEmpty else { return [] }

        var commands: [Command] = []
        for id in normalized {
            commands.append(contentsOf: closeTabBody(&model, id: id))
        }

        let allTabs = model.groups.flatMap(\.tabs)
        if allTabs.isEmpty {
            return commands + [.terminate]
        }
        commands.append(.scheduleCheckpoint)
        return commands

    case .cancelCloseTabs:
        model.pendingConfirmation = nil
        return []

    case .terminate:
        return [.terminate]

    // MARK: - Group Management

    case .createGroup(let name, let launch):
        let groupId = GroupId()
        let group = GroupModel(id: groupId, name: name)
        model.groups.append(group)
        return update(&model, .createTab(inGroupId: groupId, launch: launch))

    case .deleteGroup(let id, let moveTabs):
        guard let idx = model.groups.firstIndex(where: { $0.id == id }),
              model.groups.count > 1 else { return [] }

        let group = model.groups[idx]
        if !moveTabs && !group.tabs.isEmpty && totalTabCount(model) == group.tabs.count {
            return emitTerminateConfirmation(&model)
        }
        if moveTabs {
            guard let adjIdx = adjacentGroupIndex(deletingAt: idx, count: model.groups.count) else { return [] }
            model.groups[adjIdx].tabs.append(contentsOf: group.tabs)
        } else {
            // Close all tabs' surfaces
            var commands: [Command] = []
            for tab in group.tabs {
                for pid in allPaneIds(tab.rootNode) {
                    // Surface teardown is reconcileSurfaceExistence's (these panes leave the
                    // tree below); keep the id-keyed side-table cleanup here.
                    removeAlertsForPane(pid, in: &model)
                    removePaneSearchState(pid, from: &model)
                    model.lastNotificationTime.removeValue(forKey: pid)
                }
            }
            model.groups.remove(at: idx)
            if model.groups.flatMap(\.tabs).isEmpty {
                return commands + [.terminate]
            }
            // Fix selection if needed
            if let selId = model.selectedTabId,
               !model.groups.flatMap(\.tabs).contains(where: { $0.id == selId }) {
                model.selectedTabId = model.groups.flatMap(\.tabs).first?.id
            }
            // Persist group deletion + tab removal so they don't reappear.
            commands.append(.scheduleCheckpoint)
            return commands
        }

        model.groups.remove(at: idx)
        // Persist group deletion (tabs moved to default group).
        return [.scheduleCheckpoint]

    case .renameGroup(let id, let name):
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let idx = model.groups.firstIndex(where: { $0.id == id }) else { return [] }
        model.groups[idx].name = trimmed
        // Persist group name so it appears correctly on restore (the row updates via
        // reconcileSidebar).
        return [.scheduleCheckpoint]

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

        return [.scheduleCheckpoint]

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
        // in the order given. Discard nested commands -- we emit one
        // scheduleCheckpoint at the end (the sidebar updates via reconcileSidebar).
        _ = update(&model, .moveTabs(
            tabIds: validIds, toGroupId: newGroupId, atIndex: 0))
        return [.scheduleCheckpoint]

    case .reorderGroup(let groupId, let toIndex):
        guard let currentIdx = model.groups.firstIndex(where: { $0.id == groupId }) else { return [] }
        let clamped = max(0, min(toIndex, model.groups.count - 1))
        let group = model.groups.remove(at: currentIdx)
        model.groups.insert(group, at: clamped)
        // Persist group ordering so sidebar layout survives a restart (the rows reorder
        // via reconcileSidebar).
        return [.scheduleCheckpoint]

    case .toggleGroupCollapse(let groupId):
        guard let idx = model.groups.firstIndex(where: { $0.id == groupId }) else { return [] }
        model.groups[idx].isCollapsed.toggle()
        // Persist collapse state so sidebar groups restore expanded/collapsed.
        return [.scheduleCheckpoint]

    case .toggleZoomPane:
        guard let tab = selectedTab(in: model) else { return [] }
        if tab.isZoomed {
            updateSelectedTab(&model) { t in t.isZoomed = false }
            return []
        }
        if case .split = tab.rootNode {
            updateSelectedTab(&model) { t in t.isZoomed = true }
            return []
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
        // reconcilePaneChrome renders the overlay from the searchState change above;
        // only the post-reconcile focus into the (now-built) field stays a command.
        return [.focusSearchField(paneId: paneId)]

    case .searchNeedleChanged(let paneId, let needle):
        guard model.searchState[paneId] != nil else { return [] }
        model.searchState[paneId]?.needle = needle
        model.searchState[paneId]?.total = nil
        model.searchState[paneId]?.selected = nil
        // The overlay re-renders from the searchState change via reconcilePaneChrome.
        return [.sendSearchNeedle(paneId: paneId, needle: needle)]

    case .searchNavigate(let paneId, let direction):
        guard model.searchState[paneId] != nil else { return [] }
        return [.sendSearchNavigate(paneId: paneId, direction: direction)]

    case .endSearch(let paneId):
        guard model.searchState[paneId] != nil else { return [] }
        model.searchState.removeValue(forKey: paneId)
        // Clearing searchState drops the pane's key from the overlay projection, so
        // reconcilePaneChrome's `remove` tears the overlay down (no .hideSearchOverlay).
        return [.sendEndSearch(paneId: paneId), .makeFirstResponder(paneId: paneId)]

    case .ghosttySearchTotal(let paneId, let total):
        guard model.searchState[paneId] != nil else { return [] }
        model.searchState[paneId]?.total = total
        // reconcilePaneChrome re-renders the overlay's match count from this change.
        return []

    case .ghosttySearchSelected(let paneId, let selected):
        guard model.searchState[paneId] != nil else { return [] }
        model.searchState[paneId]?.selected = selected
        // reconcilePaneChrome re-renders the overlay's match count from this change.
        return []

    // MARK: - TODO

    case .toggleTodoPopover(let paneId):
        guard model.pane(paneId) != nil else { return [] }
        if model.todoPopover == .pane(paneId) {
            model.todoPopover = nil
            return [.dismissTodoPopover]
        }
        // Close any other open popover (pane or tab) before showing the new one.
        var commands: [Command] = []
        if case .tab = model.todoPopover {
            commands.append(.dismissTodoPopoverForTab)
        }
        model.todoPopover = .pane(paneId)
        commands.append(.showTodoPopover(paneId: paneId))
        return commands

    case .todoPopoverClosed(let paneId):
        if model.todoPopover == .pane(paneId) {
            model.todoPopover = nil
        }
        return []

    case .toggleTodoPopoverForTab(let tabId):
        guard tabById(tabId, in: model) != nil else { return [] }
        if model.todoPopover == .tab(tabId) {
            model.todoPopover = nil
            return [.dismissTodoPopoverForTab]
        }
        var commands: [Command] = []
        if case .pane = model.todoPopover {
            commands.append(.dismissTodoPopover)
        }
        model.todoPopover = .tab(tabId)
        commands.append(.showTodoPopoverForTab(tabId: tabId))
        return commands

    case .todoPopoverForTabClosed(let tabId):
        if model.todoPopover == .tab(tabId) {
            model.todoPopover = nil
        }
        return []

    case .addTabTodo(let tabId, let text):
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, tabById(tabId, in: model) != nil else { return [] }
        updateTab(tabId, in: &model) { t in
            t.todos.append(TodoItem(id: UUID(), text: trimmed, isDone: false))
        }
        return [.scheduleCheckpoint]

    case .toggleTabTodoDone(let tabId, let todoId):
        guard let tab = tabById(tabId, in: model),
              let idx = tab.todos.firstIndex(where: { $0.id == todoId }) else { return [] }
        updateTab(tabId, in: &model) { t in
            t.todos[idx].isDone.toggle()
        }
        return [.scheduleCheckpoint]

    case .setTabTodoDone(let tabId, let todoId, let isDone):
        guard let tab = tabById(tabId, in: model),
              let idx = tab.todos.firstIndex(where: { $0.id == todoId }),
              tab.todos[idx].isDone != isDone else { return [] }
        updateTab(tabId, in: &model) { t in
            t.todos[idx].isDone = isDone
        }
        return [.scheduleCheckpoint]

    case .editTabTodoText(let tabId, let todoId, let text):
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let tab = tabById(tabId, in: model),
              let idx = tab.todos.firstIndex(where: { $0.id == todoId }) else { return [] }
        updateTab(tabId, in: &model) { t in
            t.todos[idx].text = trimmed
        }
        return [.scheduleCheckpoint]

    case .deleteTabTodo(let tabId, let todoId):
        guard tabById(tabId, in: model) != nil else { return [] }
        updateTab(tabId, in: &model) { t in
            t.todos.removeAll { $0.id == todoId }
        }
        return [.scheduleCheckpoint]

    case .reorderTabTodo(let tabId, let todoId, let toIndex):
        guard let tab = tabById(tabId, in: model) else { return [] }
        var todos = tab.todos
        guard let fromIndex = todos.firstIndex(where: { $0.id == todoId }),
              toIndex >= 0, toIndex <= todos.count else { return [] }
        let clampedTo = min(toIndex, todos.count - 1)
        guard fromIndex != clampedTo else { return [] }
        let item = todos.remove(at: fromIndex)
        todos.insert(item, at: min(clampedTo, todos.count))
        updateTab(tabId, in: &model) { t in t.todos = todos }
        return [.scheduleCheckpoint]

    case .moveTodo(let source, let todoId, let destination, let atIndex):
        let sameBucket: Bool = {
            switch (source, destination) {
            case (.tab(let sourceId), .tab(let destinationId)):
                return sourceId == destinationId
            case (.pane(let sourceId), .pane(let destinationId)):
                return sourceId == destinationId
            case (.tab, .pane), (.pane, .tab):
                return false
            }
        }()
        guard !sameBucket else { return [] }

        let sourceTabId: TabId
        let sourceItem: TodoItem
        let sourceIndex: Int
        switch source {
        case .tab(let tabId):
            guard let tab = tabById(tabId, in: model),
                  let idx = tab.todos.firstIndex(where: { $0.id == todoId }) else { return [] }
            sourceTabId = tabId
            sourceItem = tab.todos[idx]
            sourceIndex = idx
        case .pane(let paneId):
            guard let pane = model.pane(paneId),
                  let idx = pane.todos.firstIndex(where: { $0.id == todoId }),
                  let tab = tabForPane(paneId, in: model) else { return [] }
            sourceTabId = tab.id
            sourceItem = pane.todos[idx]
            sourceIndex = idx
        }

        let destinationTabId: TabId
        let destinationCount: Int
        switch destination {
        case .tab(let tabId):
            guard let tab = tabById(tabId, in: model) else { return [] }
            destinationTabId = tabId
            destinationCount = tab.todos.count
        case .pane(let paneId):
            guard let pane = model.pane(paneId),
                  let tab = tabForPane(paneId, in: model) else { return [] }
            destinationTabId = tab.id
            destinationCount = pane.todos.count
        }

        guard sourceTabId == destinationTabId else { return [] }
        let insertAt = max(0, min(atIndex, destinationCount))

        switch source {
        case .tab(let tabId):
            updateTab(tabId, in: &model) { t in
                t.todos.remove(at: sourceIndex)
            }
        case .pane(let paneId):
            model.updatePane(paneId) { $0.todos.remove(at: sourceIndex) }
        }

        switch destination {
        case .tab(let tabId):
            updateTab(tabId, in: &model) { t in
                t.todos.insert(sourceItem, at: insertAt)
            }
        case .pane(let paneId):
            model.updatePane(paneId) { $0.todos.insert(sourceItem, at: insertAt) }
        }
        return [.scheduleCheckpoint]

    case .clearCompletedTabTodos(let tabId):
        guard tabById(tabId, in: model) != nil else { return [] }
        updateTab(tabId, in: &model) { t in
            t.todos.removeAll { $0.isDone }
        }
        return [.scheduleCheckpoint]

    case .addTodo(let paneId, let text):
        guard appendTodo(&model, paneId: paneId, text: text, id: UUID()) != nil else { return [] }
        return [.scheduleCheckpoint]

    case .toggleTodoDone(let paneId, let todoId):
        guard let idx = model.pane(paneId)?.todos.firstIndex(where: { $0.id == todoId }) else { return [] }
        model.updatePane(paneId) { $0.todos[idx].isDone.toggle() }
        return [.scheduleCheckpoint]

    case .setTodoDone(let paneId, let todoId, let isDone):
        guard let idx = model.pane(paneId)?.todos.firstIndex(where: { $0.id == todoId }) else { return [] }
        guard model.pane(paneId)!.todos[idx].isDone != isDone else { return [] }
        model.updatePane(paneId) { $0.todos[idx].isDone = isDone }
        return [.scheduleCheckpoint]

    case .editTodoText(let paneId, let todoId, let text):
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        guard let idx = model.pane(paneId)?.todos.firstIndex(where: { $0.id == todoId }) else { return [] }
        model.updatePane(paneId) { $0.todos[idx].text = trimmed }
        return [.scheduleCheckpoint]

    case .deleteTodo(let paneId, let todoId):
        model.updatePane(paneId) { $0.todos.removeAll { $0.id == todoId } }
        return [.scheduleCheckpoint]

    case .reorderTodo(let paneId, let todoId, let toIndex):
        guard var todos = model.pane(paneId)?.todos,
              let fromIndex = todos.firstIndex(where: { $0.id == todoId }),
              toIndex >= 0, toIndex <= todos.count else { return [] }
        let clampedTo = min(toIndex, todos.count - 1)
        guard fromIndex != clampedTo else { return [] }
        let item = todos.remove(at: fromIndex)
        let insertAt = clampedTo > fromIndex ? clampedTo : clampedTo
        todos.insert(item, at: min(insertAt, todos.count))
        model.updatePane(paneId) { $0.todos = todos }
        return [.scheduleCheckpoint]

    case .clearCompletedTodos(let paneId):
        model.updatePane(paneId) { $0.todos.removeAll { $0.isDone } }
        return [.scheduleCheckpoint]

    case .requestClosePane(let paneId):
        guard let pane = model.pane(paneId) else { return [] }
        // If this is the only pane in its tab, the close cascades into closeTab
        // (destroying tab todos + every pane's todos). Route through the
        // close-tab confirmation when the full rollup has any uncompleted item;
        // the rollup subsumes per-pane todos at the last-pane boundary, so
        // there's no double-prompt with the per-pane sheet.
        if let tab = tabForPane(paneId, in: model),
           allPaneIds(tab.rootNode).count == 1 {
            let rollup = tabTodoRollup(tab.id, in: model)
            if rollup.uncompleted > 0 {
                let isLastTab = totalTabCount(model) == 1
                return emitCloseTabConfirmation(
                    &model, tabId: tab.id, tabTitle: tab.displayTitle,
                    paneCount: 1, isLastTab: isLastTab,
                    uncompletedTodoCount: rollup.uncompleted
                )
            }
            return update(&model, .closePane(paneId: paneId))
        }
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
        var commands = mruCycleStep(&model, direction: direction)
        commands.append(contentsOf: mruCycleCommit(&model))
        return commands

    // Tab jump mode
    case .jumpModeActivated(let visibleTabs):
        return jumpModeActivate(&model, visibleTabs: visibleTabs)

    case .jumpModeKeyPressed(let char):
        return jumpModeCommit(&model, char: char)

    case .jumpModeCanceled:
        return jumpModeCancel(&model)
    }
}

// MARK: - IPC Handlers

private func handleIpcRequest(
    _ model: inout AppModel,
    reqId: UUID,
    method: String,
    params: JSONValue,
    context: IpcRequestContext
) -> [Command] {
    switch method {
    case Methods.ls:
        do {
            let snapshot = toSnapshot(model)
            let data = try JSONEncoder().encode(snapshot)
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            return [.ipcReply(reqId: reqId, result: value)]
        } catch {
            return [.ipcError(reqId: reqId, code: -32603, message: "internal error")]
        }

    case Methods.paneInfo:
        do {
            let paneId = try resolveTargetPane(params: params, context: context, in: model)
            guard let result = paneInfoResult(paneId, in: model) else {
                return ipcInvalidParams(reqId, "pane not found")
            }
            return [.ipcReply(reqId: reqId, result: result)]
        } catch let error as IpcParamsError {
            return ipcInvalidParams(reqId, error.message)
        } catch {
            return ipcInvalidParams(reqId, "invalid pane info params")
        }

    case Methods.tabRename:
        guard case .object(let object) = params else {
            return ipcInvalidParams(reqId, "invalid params")
        }
        let tabId: TabId
        do {
            tabId = try resolveIpcTabId(params: params, context: context, in: model)
        } catch let error as IpcParamsError {
            return ipcInvalidParams(reqId, error.message)
        } catch {
            return ipcInvalidParams(reqId, "invalid tab")
        }
        guard let titleValue = object["title"] else {
            return ipcInvalidParams(reqId, "invalid title")
        }
        let title: String?
        switch titleValue {
        case .string(let value):
            title = value
        case .null:
            title = nil
        default:
            return ipcInvalidParams(reqId, "invalid title")
        }
        let commands = update(&model, .renameTab(id: tabId, name: title))
        return commands + [.ipcReply(reqId: reqId, result: tabRenameResult(tabById(tabId, in: model)))]

    case Methods.paneSplit:
        do {
            guard case .object(let object) = params,
                  case .string(let rawDirection)? = object["direction"],
                  let direction = ipcSplitDirection(rawDirection)
            else {
                throw IpcParamsError("invalid pane split params")
            }
            let launch = try parseLaunchSpec(object["launch"])
            let background = try parseOptionalBool(object["background"], name: "background")
            let paneId = try resolvePaneSplitTarget(params: params, context: context, in: model)
            let before = Set(model.allPaneIds)
            let commands = update(&model, .splitPane(paneId: paneId, direction: direction, launch: launch, background: background))
            let newPaneId = model.allPaneIds.first(where: { !before.contains($0) })
            return commands + [.ipcReply(reqId: reqId, result: paneResult(newPaneId))]
        } catch let error as LaunchSpecParseError {
            return ipcInvalidParams(reqId, launchSpecErrorMessage(error))
        } catch let error as IpcParamsError {
            return ipcInvalidParams(reqId, error.message)
        } catch {
            return ipcInvalidParams(reqId, "invalid pane split params")
        }

    case Methods.tabNew:
        guard case .object(let object) = params else {
            return ipcInvalidParams(reqId, "invalid params")
        }
        let launch: LaunchSpec?
        do {
            launch = try parseLaunchSpec(object["launch"])
        } catch let error as LaunchSpecParseError {
            return ipcInvalidParams(reqId, launchSpecErrorMessage(error))
        } catch {
            return ipcInvalidParams(reqId, "invalid launch")
        }
        let background: Bool
        let groupId: GroupId
        let position: TabInsertPosition?
        do {
            background = try parseOptionalBool(object["background"], name: "background")
            position = try parseTabInsertPosition(object)
            groupId = try resolveTabNewTargetGroup(position: position, params: params, context: context, in: model)
        } catch let error as IpcParamsError {
            return ipcInvalidParams(reqId, error.message)
        } catch {
            return ipcInvalidParams(reqId, "invalid group")
        }
        var effectiveLaunch = launch
        if effectiveLaunch?.cwd == nil,
           let callerPaneId = resolveIpcPaneId(context, in: model),
           let cwd = model.pane(callerPaneId)?.cwd {
            effectiveLaunch = LaunchSpec(
                cmd: effectiveLaunch?.cmd,
                cwd: cwd,
                title: effectiveLaunch?.title
            )
        }
        let before = Set(model.groups.flatMap(\.tabs).map(\.id))
        let createTabMsg: Msg
        if let position {
            createTabMsg = .createTab(inGroupId: groupId, position: position, launch: effectiveLaunch, background: background)
        } else {
            createTabMsg = .createTab(inGroupId: groupId, launch: effectiveLaunch, background: background)
        }
        let commands = update(&model, createTabMsg)
        let tabId = newestTabId(excluding: before, in: model)
        return commands + [.ipcReply(reqId: reqId, result: tabNewResult(tabId: tabId, groupId: groupId, in: model))]

    case Methods.paneFocus:
        guard case .object(let object) = params,
              case .string(let rawPaneId)? = object["paneId"],
              let paneId = parsePaneId(rawPaneId),
              model.pane(paneId) != nil
        else {
            return ipcInvalidParams(reqId, "invalid pane id")
        }
        let commands = navigateToPane(paneId, in: &model)
        return commands + [.ipcReply(reqId: reqId, result: tabFocusResult(tabForPane(paneId, in: model)))]

    case Methods.themeSet:
        guard case .object(let object) = params,
              let themeValue = object["themeName"]
        else {
            return ipcInvalidParams(reqId, "invalid theme params")
        }
        let paneId: PaneId
        do {
            paneId = try resolveTargetPane(params: params, context: context, in: model)
        } catch let error as IpcParamsError {
            return ipcInvalidParams(reqId, error.message)
        } catch {
            return ipcInvalidParams(reqId, "invalid theme params")
        }
        let themeName: String?
        switch themeValue {
        case .null:
            themeName = nil
        case .string(let name):
            themeName = name
        default:
            return ipcInvalidParams(reqId, "invalid theme name")
        }
        let commands = update(&model, .setPaneTheme(paneId: paneId, themeName: themeName))
        return commands + [.ipcReply(reqId: reqId, result: paneThemeResult(paneId, in: model))]

    case Methods.paneInput:
        do {
            let paneId = try resolveSendKeysPane(params: params, context: context, in: model)
            guard case .object(let object) = params else {
                throw IpcParamsError("text or input required")
            }
            let textValue = object["text"]
            let inputValue = object["input"]
            switch (textValue, inputValue) {
            case (.some, .some):
                throw IpcParamsError("text or input required, not both")
            case (.none, .none):
                throw IpcParamsError("text or input required")
            case (.some(let t), .none):
                // Top-level IPC text keeps paste-path semantics.
                guard case .string(let text) = t, !text.isEmpty else {
                    throw IpcParamsError("invalid text")
                }
                return [
                    .sendText(paneId: paneId, text: text),
                    .ipcReply(reqId: reqId, result: okResult()),
                ]
            case (.none, .some(let i)):
                guard case .array(let arr) = i else {
                    throw IpcParamsError("input must be an array")
                }
                var commands: [Command] = []
                commands.reserveCapacity(arr.count + 1)
                for value in arr {
                    let event = try parseInputEvent(value)
                    switch event {
                    case .text(let text):
                        commands.append(.sendInputText(paneId: paneId, text: text))
                    case .key(let key, let mods):
                        commands.append(.sendInputKey(paneId: paneId, key: key, mods: mods))
                    }
                }
                commands.append(.ipcReply(reqId: reqId, result: okResult()))
                return commands
            }
        } catch let error as IpcParamsError {
            return ipcInvalidParams(reqId, error.message)
        } catch {
            return ipcInvalidParams(reqId, "invalid params")
        }

    case Methods.paneRead:
        do {
            guard case .object(let object) = params else {
                throw IpcParamsError("invalid params")
            }
            guard case .string(let rawPane)? = object["pane"] else {
                throw IpcParamsError("pane required")
            }
            guard let paneId = parsePaneId(rawPane), model.pane(paneId) != nil else {
                throw IpcParamsError("pane not found")
            }

            let lineLimit: Int?
            switch object["lines"] {
            case .none, .some(.null):
                lineLimit = nil
            case .some(.number(let n)):
                guard let i = Int(exactly: n), i > 0 else {
                    throw IpcParamsError("lines must be a positive integer")
                }
                lineLimit = i
            default:
                throw IpcParamsError("lines must be a positive integer")
            }
            return [.readPaneText(reqId: reqId, paneId: paneId, lineLimit: lineLimit)]
        } catch let error as IpcParamsError {
            return ipcInvalidParams(reqId, error.message)
        } catch {
            return ipcInvalidParams(reqId, "invalid params")
        }

    case Methods.todoList:
        do {
            let paneId = try resolveTargetPane(params: params, context: context, in: model)
            guard let todos = model.pane(paneId)?.todos else {
                return ipcInvalidParams(reqId, "no pane in context")
            }
            return [.ipcReply(reqId: reqId, result: todoListResult(todos))]
        } catch let error as IpcParamsError {
            return ipcInvalidParams(reqId, error.message)
        } catch {
            return ipcInvalidParams(reqId, "invalid todo params")
        }

    case Methods.todoAdd:
        guard case .object(let object) = params,
              case .string(let text)? = object["text"]
        else {
            return ipcInvalidParams(reqId, "invalid todo text")
        }
        let paneId: PaneId
        do {
            paneId = try resolveTargetPane(params: params, context: context, in: model)
        } catch let error as IpcParamsError {
            return ipcInvalidParams(reqId, error.message)
        } catch {
            return ipcInvalidParams(reqId, "invalid todo text")
        }
        guard let item = appendTodo(&model, paneId: paneId, text: text, id: UUID()) else {
            return ipcInvalidParams(reqId, "invalid todo text")
        }
        // Pane toolbar (incl. todo counts) reconciles from the model change above.
        return [
            .scheduleCheckpoint,
            .ipcReply(reqId: reqId, result: todoResult(item)),
        ]

    case Methods.todoEdit:
        guard case .object(let object) = params,
              case .string(let rawTodoId)? = object["todoId"],
              case .string(let text)? = object["text"],
              let todoId = parseTodoId(rawTodoId),
              !text.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            return ipcInvalidParams(reqId, "invalid todo")
        }
        let paneId: PaneId
        do {
            paneId = try resolveTargetPane(params: params, context: context, in: model)
        } catch let error as IpcParamsError {
            return ipcInvalidParams(reqId, error.message)
        } catch {
            return ipcInvalidParams(reqId, "invalid todo")
        }
        guard todoExists(todoId, paneId: paneId, in: model) else {
            return ipcInvalidParams(reqId, "invalid todo")
        }
        let commands = update(&model, .editTodoText(paneId: paneId, todoId: todoId, text: text))
        let updated = model.pane(paneId)?.todos.first(where: { $0.id == todoId })
        return commands + [
            .ipcReply(reqId: reqId, result: todoResult(updated)),
        ]

    case Methods.todoDone, Methods.todoOpen:
        guard case .object(let object) = params,
              case .string(let rawTodoId)? = object["todoId"],
              let todoId = parseTodoId(rawTodoId)
        else {
            return ipcInvalidParams(reqId, "invalid todo")
        }
        let paneId: PaneId
        do {
            paneId = try resolveTargetPane(params: params, context: context, in: model)
        } catch let error as IpcParamsError {
            return ipcInvalidParams(reqId, error.message)
        } catch {
            return ipcInvalidParams(reqId, "invalid todo")
        }
        guard todoExists(todoId, paneId: paneId, in: model) else {
            return ipcInvalidParams(reqId, "invalid todo")
        }
        let shouldBeDone = method == Methods.todoDone
        let commands = update(&model, .setTodoDone(paneId: paneId, todoId: todoId, isDone: shouldBeDone))
        let updated = model.pane(paneId)?.todos.first(where: { $0.id == todoId })
        return commands + [
            .ipcReply(reqId: reqId, result: todoResult(updated)),
        ]

    case Methods.todoDelete:
        guard case .object(let object) = params,
              case .string(let rawTodoId)? = object["todoId"],
              let todoId = parseTodoId(rawTodoId)
        else {
            return ipcInvalidParams(reqId, "invalid todo")
        }
        let paneId: PaneId
        do {
            paneId = try resolveTargetPane(params: params, context: context, in: model)
        } catch let error as IpcParamsError {
            return ipcInvalidParams(reqId, error.message)
        } catch {
            return ipcInvalidParams(reqId, "invalid todo")
        }
        guard todoExists(todoId, paneId: paneId, in: model) else {
            return ipcInvalidParams(reqId, "invalid todo")
        }
        let commands = update(&model, .deleteTodo(paneId: paneId, todoId: todoId))
        return commands + [
            .ipcReply(reqId: reqId, result: okResult()),
        ]

    case Methods.todoClearCompleted:
        let paneId: PaneId
        do {
            paneId = try resolveTargetPane(params: params, context: context, in: model)
        } catch let error as IpcParamsError {
            return ipcInvalidParams(reqId, error.message)
        } catch {
            return ipcInvalidParams(reqId, "no pane in context")
        }
        let commands = update(&model, .clearCompletedTodos(paneId: paneId))
        return commands + [
            .ipcReply(reqId: reqId, result: okResult()),
        ]

    default:
        return [.ipcError(reqId: reqId, code: -32601, message: "method not found")]
    }
}

private func ipcInvalidParams(_ reqId: UUID, _ message: String) -> [Command] {
    [.ipcError(reqId: reqId, code: -32602, message: message)]
}

private func parsePaneId(_ raw: String?) -> PaneId? {
    guard let raw, let uuid = UUID(uuidString: raw) else { return nil }
    return PaneId(rawValue: uuid)
}

private func parseTabId(_ raw: String?) -> TabId? {
    guard let raw, let uuid = UUID(uuidString: raw) else { return nil }
    return TabId(rawValue: uuid)
}

private func parseGroupId(_ raw: String?) -> GroupId? {
    guard let raw, let uuid = UUID(uuidString: raw) else { return nil }
    return GroupId(rawValue: uuid)
}

private func parseTodoId(_ raw: String?) -> UUID? {
    guard let raw else { return nil }
    return UUID(uuidString: raw)
}

private func resolveIpcPaneId(_ context: IpcRequestContext, in model: AppModel) -> PaneId? {
    guard let paneId = parsePaneId(context.paneId), model.pane(paneId) != nil else {
        return nil
    }
    return paneId
}

private struct IpcParamsError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

private func parseOptionalBool(_ value: JSONValue?, name: String) throws -> Bool {
    switch value {
    case .none, .some(.null):
        return false
    case .some(.bool(let value)):
        return value
    default:
        throw IpcParamsError("\(name) must be a boolean")
    }
}

private func parseTabInsertPosition(_ object: [String: JSONValue]) throws -> TabInsertPosition? {
    let positionValue = object["position"]
    let afterTabIdValue = object["afterTabId"]

    if positionValue == nil && afterTabIdValue == nil {
        return nil
    }
    if afterTabIdValue != nil {
        switch positionValue {
        case .none:
            throw IpcParamsError("afterTabId is only valid when position == \"afterTab\"")
        case .some(.string(let rawPosition)) where rawPosition != "afterTab":
            throw IpcParamsError("afterTabId is only valid when position == \"afterTab\"")
        default:
            break
        }
    }

    guard let positionValue else { return nil }
    guard case .string(let rawPosition) = positionValue else {
        throw IpcParamsError("position must be a string")
    }

    switch rawPosition {
    case "afterSelected":
        return .afterSelected
    case "atGroupEnd":
        return .atGroupEnd
    case "afterTab":
        guard let afterTabIdValue else {
            throw IpcParamsError("position=afterTab requires afterTabId")
        }
        guard case .string(let rawTabId) = afterTabIdValue else {
            throw IpcParamsError("afterTabId must be a string")
        }
        guard let tabId = parseTabId(rawTabId) else {
            throw IpcParamsError("afterTabId is not a valid tab id")
        }
        return .afterTab(tabId)
    default:
        throw IpcParamsError("position must be one of: afterSelected, atGroupEnd, afterTab")
    }
}

// Resolve a pane-targeting IPC command. A supplied params.pane is authoritative:
// malformed or stale explicit ids fail instead of falling back to pane context.
private func resolveTargetPane(
    params: JSONValue,
    context: IpcRequestContext,
    in model: AppModel
) throws -> PaneId {
    if case .object(let object) = params, let raw = object["pane"] {
        return try resolveExplicitPane(raw, in: model)
    }
    if let id = resolveIpcPaneId(context, in: model) {
        return id
    }
    throw IpcParamsError("no pane in context")
}

private func resolveExplicitPane(_ raw: JSONValue, in model: AppModel) throws -> PaneId {
    guard case .string(let str) = raw else {
        throw IpcParamsError("pane must be a string")
    }
    guard let id = parsePaneId(str), model.pane(id) != nil else {
        throw IpcParamsError("pane not found")
    }
    return id
}

// `pane split`-specific pane resolver. An explicit pane targets a sibling and
// must be valid; only an absent pane falls back to the request context.
private func resolvePaneSplitTarget(
    params: JSONValue,
    context: IpcRequestContext,
    in model: AppModel
) throws -> PaneId {
    try resolveTargetPane(params: params, context: context, in: model)
}

// `pane.input`-specific pane resolver. Honours an explicit `pane` field in
// params (cross-pane targeting) and never silently falls back to the request
// context when the explicit pane is malformed or unknown — the caller asked
// for a specific pane and got something wrong, so they should hear about it.
private func resolveSendKeysPane(
    params: JSONValue,
    context: IpcRequestContext,
    in model: AppModel
) throws -> PaneId {
    try resolveTargetPane(params: params, context: context, in: model)
}

// Parses a single `input[i]` JSON object into an InputEvent. All structural
// validation happens here so by the time the runtime handles
// `.sendInputKey(...)`, the KeyName has already been confirmed against the
// closed enum.
private func parseInputEvent(_ value: JSONValue) throws -> InputEvent {
    guard case .object(let object) = value else {
        throw IpcParamsError("input event must be an object")
    }
    let textPresent = object["text"] != nil
    let keyPresent = object["key"] != nil
    if textPresent == keyPresent {
        throw IpcParamsError("input event must have text xor key")
    }
    if textPresent {
        guard case .string(let text)? = object["text"] else {
            throw IpcParamsError("input event text must be a string")
        }
        return .text(text)
    }
    guard case .string(let keyName)? = object["key"] else {
        throw IpcParamsError("input event key must be a string")
    }
    guard let key = KeyName(wireName: keyName) else {
        throw IpcParamsError("unknown key \(keyName)")
    }
    var mods: KeyMods = []
    if let modsValue = object["mods"] {
        guard case .array(let arr) = modsValue else {
            throw IpcParamsError("mods must be an array")
        }
        var modNames: [String] = []
        modNames.reserveCapacity(arr.count)
        for entry in arr {
            guard case .string(let name) = entry else {
                throw IpcParamsError("mods entries must be strings")
            }
            modNames.append(name)
        }
        do {
            mods = try KeyMods.decode(wire: modNames)
        } catch KeyModsDecodeError.unknown(let name) {
            throw IpcParamsError("unknown mod \(name)")
        }
    }
    return .key(key, mods)
}

private func resolveIpcTabId(
    params: JSONValue,
    context: IpcRequestContext,
    in model: AppModel
) throws -> TabId {
    if case .object(let object) = params, let raw = object["tab"] {
        guard case .string(let str) = raw else {
            throw IpcParamsError("tab must be a string")
        }
        guard let id = parseTabId(str), tabById(id, in: model) != nil else {
            throw IpcParamsError("tab not found")
        }
        return id
    }
    if let paneId = parsePaneId(context.paneId),
       let tabId = tabForPane(paneId, in: model)?.id {
        return tabId
    }
    throw IpcParamsError("no tab in context")
}

private func resolveTabNewGroup(
    params: JSONValue,
    context: IpcRequestContext,
    in model: AppModel
) throws -> GroupId {
    if case .object(let object) = params, let raw = object["group"] {
        return try resolveExplicitGroup(raw, in: model)
    }
    if let paneId = parsePaneId(context.paneId),
       let tab = tabForPane(paneId, in: model),
       let group = groupForTab(tab.id, in: model) {
        return group.id
    }
    throw IpcParamsError("no group in context")
}

private func resolveTabNewTargetGroup(
    position: TabInsertPosition?,
    params: JSONValue,
    context: IpcRequestContext,
    in model: AppModel
) throws -> GroupId {
    guard case .afterTab(let refTabId) = position else {
        return try resolveTabNewGroup(params: params, context: context, in: model)
    }
    guard tabById(refTabId, in: model) != nil else {
        throw IpcParamsError("position.afterTabId not found")
    }
    guard let refGroup = groupForTab(refTabId, in: model) else {
        throw IpcParamsError("position.afterTabId not found")
    }
    if case .object(let object) = params, let rawGroup = object["group"] {
        let requestedGroupId = try resolveExplicitGroup(rawGroup, in: model)
        guard requestedGroupId == refGroup.id else {
            throw IpcParamsError("position.afterTabId is not in the requested group")
        }
        return requestedGroupId
    }
    return refGroup.id
}

private func resolveExplicitGroup(_ raw: JSONValue, in model: AppModel) throws -> GroupId {
    guard case .string(let str) = raw else {
        throw IpcParamsError("group must be a string")
    }
    guard let id = parseGroupId(str),
          model.groups.contains(where: { $0.id == id })
    else {
        throw IpcParamsError("group not found")
    }
    return id
}

private func ipcSplitDirection(_ raw: String) -> SplitNodeModel.Direction? {
    switch raw {
    case "horizontal": return .horizontal
    case "vertical": return .vertical
    default: return nil
    }
}

private func newestTabId(excluding before: Set<TabId>, in model: AppModel) -> TabId? {
    model.groups.flatMap(\.tabs).first(where: { !before.contains($0.id) })?.id
}

private func tabNewResult(tabId: TabId?, groupId: GroupId?, in model: AppModel) -> JSONValue {
    var object: [String: JSONValue] = [
        "tab": .null,
        "panes": .array([]),
    ]
    if let tabId {
        object["tab"] = tabSnapshotJSON(tabId, in: model) ?? .object(["id": .string(tabId.rawValue.uuidString)])
        object["panes"] = .array(paneIdsForTab(tabId, in: model).map { paneId in
            .object(["id": .string(paneId.rawValue.uuidString)])
        })
    }
    if let groupId,
       let group = model.groups.first(where: { $0.id == groupId }) {
        object["group"] = .object([
            "id": .string(group.id.rawValue.uuidString),
            "name": .string(group.name),
        ])
    }
    return .object(object)
}

private func tabRenameResult(_ tab: TabModel?) -> JSONValue {
    guard let tab else {
        return .object(["tab": .null])
    }
    return .object([
        "tab": .object([
            "id": .string(tab.id.rawValue.uuidString),
            "customTitle": tab.customTitle.map(JSONValue.string) ?? .null,
        ])
    ])
}

private func tabFocusResult(_ tab: TabModel?) -> JSONValue {
    guard let tab else {
        return .object(["tab": .null])
    }
    return .object([
        "tab": .object([
            "id": .string(tab.id.rawValue.uuidString),
            "focusedPaneId": .string(tab.focusedPaneId.rawValue.uuidString),
        ])
    ])
}

private func paneResult(_ paneId: PaneId?) -> JSONValue {
    guard let paneId else {
        return .object(["pane": .null])
    }
    return .object(["pane": .object(["id": .string(paneId.rawValue.uuidString)])])
}

private func paneInfoResult(_ paneId: PaneId, in model: AppModel) -> JSONValue? {
    guard let pane = model.pane(paneId),
          let tab = tabForPane(paneId, in: model),
          let group = groupForTab(tab.id, in: model)
    else {
        return nil
    }
    return .object([
        "pane": .object([
            "id": .string(pane.id.rawValue.uuidString),
            "title": .string(pane.title),
            "cwd": pane.cwd.map(JSONValue.string) ?? .null,
        ]),
        "tab": .object([
            "id": .string(tab.id.rawValue.uuidString),
            "title": .string(tab.displayTitle),
            "groupId": .string(group.id.rawValue.uuidString),
        ]),
        "group": .object([
            "id": .string(group.id.rawValue.uuidString),
            "name": .string(group.name),
        ]),
    ])
}

private func paneThemeResult(_ paneId: PaneId, in model: AppModel) -> JSONValue {
    .object([
        "pane": .object([
            "id": .string(paneId.rawValue.uuidString),
            "theme": model.pane(paneId)?.theme.map(JSONValue.string) ?? .null,
        ])
    ])
}

private func todoResult(_ item: TodoItem?) -> JSONValue {
    .object(["todo": item.map(todoJSON) ?? .null])
}

private func todoListResult(_ todos: [TodoItem]) -> JSONValue {
    .object(["todos": .array(todos.map(todoJSON))])
}

private func okResult() -> JSONValue {
    .object(["ok": .bool(true)])
}

private func tabSnapshotJSON(_ tabId: TabId, in model: AppModel) -> JSONValue? {
    let snapshot = toSnapshot(model)
    guard let tab = snapshot.groups.flatMap(\.tabs).first(where: { $0.id == tabId.rawValue.uuidString }) else {
        return nil
    }
    return encodeJSONValue(tab)
}

private func encodeJSONValue<T: Encodable>(_ value: T) -> JSONValue? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
}

private func launchSpecErrorMessage(_ error: LaunchSpecParseError) -> String {
    switch error {
    case .notObject:
        return "launch must be an object"
    case .fieldNotString(let field):
        return "launch.\(field) must be a string"
    }
}

private func appendTodo(_ model: inout AppModel, paneId: PaneId, text: String, id: UUID) -> TodoItem? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, model.pane(paneId) != nil else { return nil }
    let item = TodoItem(id: id, text: trimmed, isDone: false)
    model.updatePane(paneId) { $0.todos.append(item) }
    return item
}

private func todoExists(_ todoId: UUID, paneId: PaneId, in model: AppModel) -> Bool {
    model.pane(paneId)?.todos.contains(where: { $0.id == todoId }) == true
}

private func todoJSON(_ item: TodoItem) -> JSONValue {
    .object([
        "id": .string(item.id.uuidString),
        "text": .string(item.text),
        "isDone": .bool(item.isDone),
    ])
}

// MARK: - Tab Selection Helper

/// Body of `.selectTab` extracted into a helper so `mruCycleCommitted` can
/// reuse the focus / rebuild / checkpoint commands without duplicating logic.
private func applySelectTab(_ model: inout AppModel, id: TabId) -> [Command] {
    guard id != model.selectedTabId else { return [] }

    var commands: [Command] = []
    if let oldTabId = model.selectedTabId {
        for oldPaneId in paneIdsForTab(oldTabId, in: model) {
            commands.append(.focusSurface(paneId: oldPaneId, focused: false))
        }
    }
    model.selectedTabId = id
    if model.config.alertClearMode == .focus, let tab = selectedTab(in: model) {
        markAlertsReadForPane(tab.focusedPaneId, in: &model)
    }
    // Selection is view-owned: reconcileSidebar reapplies it (replacing the deleted
    // .setSidebarSelection), and any cleared-alert bell badges update from the projection.
    // The selected tab's window chrome reconciles via reconcileWindowChrome.
    commands.append(.scheduleCheckpoint)
    return commands
}

// MARK: - MRU Cycle Handlers

private func mruCycleStep(_ model: inout AppModel, direction: MruDirection) -> [Command] {
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
    // The switcher panel reconciles from model.mruCycle (reconcileSwitcher).
    return []
}

private func mruCycleCommit(_ model: inout AppModel) -> [Command] {
    guard let cycle = model.mruCycle else { return [] }

    // Tabs may have been removed mid-cycle (closeTab, surfaceCreationFailed,
    // last-pane closePane, automation). Filter frozenOrder against live tabs
    // and remap the cursor before reading the chosen id.
    guard let resolved = resolveLiveCycle(cycle, in: model) else {
        // Every frozen tab is gone; treat as cancel. mruCycle == nil ->
        // reconcileSwitcher orders the panel out.
        model.mruCycle = nil
        return []
    }

    let chosenId = resolved.liveOrder[resolved.cursorIndex]
    model.mruCycle = nil

    // mruCycle == nil now -> reconcileSwitcher hides the panel; the only surviving
    // commands are the selectTab commands when the chosen tab differs.
    var commands: [Command] = []
    if chosenId != model.selectedTabId {
        commands.append(contentsOf: applySelectTab(&model, id: chosenId))
    }
    return commands
}

private func mruCycleCancel(_ model: inout AppModel) -> [Command] {
    guard model.mruCycle != nil else { return [] }
    model.mruCycle = nil
    // mruCycle == nil -> reconcileSwitcher orders the panel out.
    return []
}

// MARK: - Tab Jump Mode Handlers

private func jumpModeActivate(_ model: inout AppModel, visibleTabs: [TabId]) -> [Command] {
    // End any in-flight MRU cycle; reconcileSwitcher hides the panel once mruCycle is nil
    // (a no-op assignment when no cycle is active).
    model.mruCycle = nil
    model.jumpMode = JumpModeState(keyMap: assignJumpKeys(visibleTabs: visibleTabs))
    return []   // jump badges (reconcileSidebar) + switcher hide (reconcileSwitcher) both reconcile
}

private func jumpModeCommit(_ model: inout AppModel, char: Character) -> [Command] {
    guard let jumpMode = model.jumpMode else { return [] }
    model.jumpMode = nil   // jump badges clear via reconcileSidebar

    guard let targetId = jumpMode.keyMap.first(where: { $0.value == char })?.key,
          tabLocation(targetId, in: model) != nil else {
        return []
    }

    return applySelectTab(&model, id: targetId)
}

private func jumpModeCancel(_ model: inout AppModel) -> [Command] {
    guard model.jumpMode != nil else { return [] }
    model.jumpMode = nil   // jump badges clear via reconcileSidebar
    return []
}

// MARK: - Helpers

/// Navigate to a pane: select its current tab, clear zoom if needed, focus the pane.
private func navigateToPane(_ paneId: PaneId, in model: inout AppModel) -> [Command] {
    guard let currentTab = tabForPane(paneId, in: model) else { return [] }
    let wasZoomed = currentTab.isZoomed
    let oldFocusedPaneId = currentTab.focusedPaneId
    let focusChanged = paneId != oldFocusedPaneId
    var commands = update(&model, .selectTab(id: currentTab.id))
    updateTab(currentTab.id, in: &model) { tab in
        tab.focusedPaneId = paneId
    }
    if focusChanged && model.config.alertClearMode == .focus {
        markAlertsReadForPane(paneId, in: &model)
    }
    if wasZoomed, paneId != oldFocusedPaneId {
        updateSelectedTab(&model) { t in t.isZoomed = false }
    }
    // No popover clear on same-tab navigation: the anchor button and the visible
    // container stay intact, so nothing is stranded (consistent with
    // paneBecameFirstResponder). A cross-tab navigate clears via the nested selectTab;
    // an unzoom drifts the shape and clears via update()'s reconcileTodoPopover.
    commands.append(.makeFirstResponder(paneId: paneId))
    if focusChanged {
        commands.append(.scheduleCheckpoint)
    }
    return commands
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

@discardableResult
private func markAlertsReadForPane(_ paneId: PaneId, in model: inout AppModel) -> Bool {
    var changed = false
    for i in model.alerts.indices where model.alerts[i].paneId == paneId && model.alerts[i].isUnread {
        model.alerts[i].isUnread = false
        changed = true
    }
    return changed
}

private func unreadAlertPaneIds(for paneIds: [PaneId], in model: AppModel) -> [PaneId] {
    let paneIdSet = Set(paneIds)
    var seen = Set<PaneId>()
    var result: [PaneId] = []
    for alert in model.alerts where alert.isUnread && paneIdSet.contains(alert.paneId) {
        if seen.insert(alert.paneId).inserted {
            result.append(alert.paneId)
        }
    }
    return result
}

// tabIdsForPanes / paneToTabIdMap / unreadAlertPaneIds(in:) were deleted in Stage 5:
// they existed only to compute which sidebar rows to refresh for an alert change, which
// reconcileSidebar now derives from the projection (the bell-badge counts).


/// Remove all alerts for a pane that is being destroyed.
private func removeAlertsForPane(_ paneId: PaneId, in model: inout AppModel) {
    model.alerts.removeAll { $0.paneId == paneId }
}

private func normalizedLiveTabIds(_ ids: [TabId], in model: AppModel) -> [TabId] {
    var seen = Set<TabId>()
    return ids.filter { id in
        guard !seen.contains(id), tabLocation(id, in: model) != nil
        else { return false }
        seen.insert(id)
        return true
    }
}

// Core tab removal shared by single and batch close. The caller owns the final
// tail: terminate-if-empty vs. reload-sidebar-and-checkpoint.
private func closeTabBody(_ model: inout AppModel, id: TabId) -> [Command] {
    guard let (groupIdx, tabIdx) = tabLocation(id, in: model) else { return [] }
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

    var commands: [Command] = []
    for pid in paneIds {
        // Surface teardown is reconcileSurfaceExistence's (these panes leave the tree
        // below); keep the id-keyed side-table cleanup + per-pane popover dismiss here.
        removeAlertsForPane(pid, in: &model)
        removePaneSearchState(pid, from: &model)
        model.lastNotificationTime.removeValue(forKey: pid)
        if model.todoPopover == .pane(pid) {
            model.todoPopover = nil
            commands.append(.dismissTodoPopover)
        }
    }
    // Tab popover open against this tab dies with the tab. Emit the dismiss
    // command even though no `todoPopoverForTabClosed` will fire, so AppRuntime
    // closes the floating NSPopover.
    if model.todoPopover == .tab(id) {
        model.todoPopover = nil
        commands.append(.dismissTodoPopoverForTab)
    }

    model.groups[groupIdx].tabs.remove(at: tabIdx)
    removeGroupIfEmpty(groupId, from: &model)
    // The closed tab's container is removed by reconcileContainers (it left the model).

    // Select fallback tab if we closed the selected one.
    if id == model.selectedTabId, let newId = fallbackTabId {
        model.selectedTabId = newId
    }
    return commands
}

/// Throttle macOS notification delivery: one per pane per kind every 1 second.
private let notificationThrottleInterval: TimeInterval = 1

/// Throttle macOS notification delivery: one per pane per kind every throttle interval.
private func throttledNotification(
    alertId: AlertId, kind: AlertKind, paneId: PaneId,
    title: String, body: String, model: inout AppModel
) -> [Command] {
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
