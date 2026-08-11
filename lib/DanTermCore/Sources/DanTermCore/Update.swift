// Pure update function for DanTerm's Elm-style state machine.
import Foundation
import DanTermProtocol

@discardableResult
func update(
    _ model: inout AppModel,
    _ msg: Msg,
    env: CoreEnv = .live
) -> [Command] {
    // Single chokepoint: every code path that mutates tab membership or
    // selectedTabId reaches this point. `defer` fires after the matched case
    // returns, and `inout model` makes the reconciled state visible to
    // callers. Without this, MRU updates would have to be sprinkled into
    // every handler that touches tabs (movePaneToTab, sessionCreationFailed,
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
            context: context,
            env: env
        )

    // MARK: - Tab Management

    case .createTab(let inGroupId, let position, let launch, let background):
        let paneId = PaneId(rawValue: env.newId())
        let sessionId = SessionId(rawValue: env.newId())
        let tabId = TabId(rawValue: env.newId())
        let cwd = launch?.cwd ?? currentCwd(in: model)

        let pane = PaneModel(
            id: paneId,
            session: SessionModel(id: sessionId, title: launch?.title ?? "Terminal")
        )

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
                commands.append(.focusSession(paneId: oldPaneId, focused: false))
            }
        }

        if !background {
            model.selectedTabId = tabId
        }

        commands.append(.createSession(
            sessionId: sessionId,
            paneId: paneId,
            cwd: cwd,
            command: launch?.cmd,
            launchCommand: nil
        ))
        return commands

    case .selectAdjacentTab(let direction):
        guard let targetId = adjacentTabId(direction: direction, in: model) else { return [] }
        return update(&model, .selectTab(id: targetId), env: env)

    case .selectTab(let id):
        return applySelectTab(&model, id: id)

    case .requestCloseTab(let id):
        guard let tab = tabById(id, in: model) else { return [] }
        let paneCount = allPaneIds(tab.rootNode).count
        let uncompletedTodos = tabTodoRollup(id, in: model).uncompleted

        if paneCount > 1 || uncompletedTodos > 0 {
            let isLastTab = totalTabCount(model) == 1
            return emitCloseTabConfirmation(
                &model, tabId: id, tabTitle: tabDisplayTitle(tab, in: model),
                paneCount: paneCount, isLastTab: isLastTab,
                uncompletedTodoCount: uncompletedTodos
            )
        }

        return update(&model, .closeTab(id: id), env: env)

    case .requestCloseTabs(let ids):
        let normalized = normalizedLiveTabIds(ids, in: model)
        guard !normalized.isEmpty else { return [] }
        guard normalized.count > 1 else {
            return update(&model, .requestCloseTab(id: normalized[0]), env: env)
        }
        return emitCloseTabsConfirmation(&model, ids: normalized)

    case .closeTab(let id):
        guard tabLocation(id, in: model) != nil else { return [] }

        if wouldQuitFromClose(model) {
            return emitTerminateConfirmation(&model)
        }

        let commands = closeTabBody(&model, id: id)

        // Check if all tabs gone
        if !model.hasAnyTab {
            return commands + [.terminate]
        }
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
        let newPaneId = PaneId(rawValue: env.newId())
        let newSessionId = SessionId(rawValue: env.newId())
        let newSplitId = SplitId(rawValue: env.newId())
        let cwd = launch?.cwd ?? model.pane(targetPaneId)?.session?.cwd
        let theme = model.pane(targetPaneId)?.theme
        let fontSizeSteps = model.pane(targetPaneId)?.fontSizeSteps ?? 0

        var newPane = PaneModel(
            id: newPaneId,
            session: SessionModel(id: newSessionId, title: launch?.title ?? "Terminal")
        )
        newPane.theme = theme
        newPane.fontSizeSteps = fontSizeSteps

        // splitLeaf embeds the new pane's payload directly into the leaf.
        guard let newRoot = splitLeaf(
            tab.rootNode, paneId: targetPaneId, direction: direction, newPane: newPane,
            newSplitId: newSplitId
        ) else { return [] }

        // Update the tab in place
        updateTab(tab.id, in: &model) { tab in
            tab.rootNode = newRoot
            if !background {
                tab.focusedPaneId = newPaneId
            }
            tab.isZoomed = false
        }

        let commands: [Command] = [
            .createSession(
                sessionId: newSessionId,
                paneId: newPaneId,
                cwd: cwd,
                command: launch?.cmd,
                launchCommand: nil
            ),
        ]
        return commands

    case .closePane(let paneId):
        // Resolve the pane's own tab (mirrors .splitPane): .sessionEnded routes
        // background-tab shell exits here, and a stale context menu may fire after
        // the selection changed -- both must act on the tab that owns the pane.
        // A pane in no tab (already closed) is a pure no-op.
        guard let tab = tabForPane(paneId, in: model) else { return [] }

        // removeLeaf drops the leaf (and its pane payload) atomically; the close
        // path discards the removed pane. Side-table cleanup stays here.
        let (newTree, nextFocus, _) = removeLeaf(tab.rootNode, paneId: paneId)

        if newTree == nil && wouldQuitFromClose(model) {
            return emitTerminateConfirmation(&model)
        }

        // Session teardown is reconcileSessionExistence's now (paneId leaves the tree
        // below, so the next reconcile tears its session down); keep side-table cleanup.
        var commands: [Command] = []
        clearPaneSideTables(paneId, in: &model)
        if model.todoPopover == .pane(paneId) {
            model.todoPopover = nil
            commands.append(.dismissTodoPopover)
        }

        guard let newRoot = newTree else {
            // Last pane — close the pane's own tab
            return update(&model, .closeTab(id: tab.id), env: env)
        }

        // Focus-mode alert clearing only applies when the close happens in the
        // selected tab: a background tab's survivor never actually gains
        // user-visible focus, so its unread alerts must survive until the user
        // views the tab (they clear through the tab-selection path).
        if model.config.alertClearMode == .focus, let next = nextFocus,
           tab.id == model.selectedTabId {
            markAlertsReadForPane(next, in: &model)
        }
        updateTab(tab.id, in: &model) { tab in
            tab.rootNode = newRoot
            tab.isZoomed = false
            if let next = nextFocus {
                tab.focusedPaneId = next
            }
        }

        return commands

    case .movePane(let source, let target, let intent):
        // Selected-tab scoping is deliberate: unlike .closePane/.splitPane,
        // which resolve tabForPane because background-tab dispatches are real,
        // .movePane's only producer is the PaneWrapperView drag gesture, bound
        // to the selected tab by construction. A stale dispatch whose panes
        // live elsewhere no-ops below: swapLeaves/moveLeaf return nil unless
        // both ids are in this tree, before focusedPaneId is written. Resolving
        // the panes' real tab instead would silently rearrange a tab the user is
        // not looking at. Revisit if .movePane gains an IPC producer.
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
            let newSplitId = SplitId(rawValue: env.newId())
            newRoot = moveLeaf(
                tab.rootNode, source: source, target: target, direction: direction,
                insertFirst: insertFirst, newSplitId: newSplitId
            )
        }

        guard let newRoot = newRoot else { return [] }
        updateSelectedTab(&model) { tab in
            tab.rootNode = newRoot
            tab.focusedPaneId = source
            tab.isZoomed = false
        }
        return []

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
                id: SplitId(rawValue: env.newId()), direction: .horizontal,
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
                commands.append(.focusSession(paneId: oldPaneId, focused: false))
            }
        }
        model.selectedTabId = targetTabId
        commands.append(.makeFirstResponder(paneId: paneId))
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
                commands.append(.focusSession(paneId: oldPaneId, focused: false))
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
            let newTab = TabModel(id: TabId(rawValue: env.newId()), focusedPaneId: paneId, rootNode: .leaf(movedPane))
            let clamped = max(0, min(atIndex, model.groups[dstGroupIdx].tabs.count))
            model.groups[dstGroupIdx].tabs.insert(newTab, at: clamped)
            model.selectedTabId = newTab.id
        }

        if model.config.alertClearMode == .focus {
            markAlertsReadForPane(paneId, in: &model)
        }

        commands.append(.makeFirstResponder(paneId: paneId))
        return commands

    case .setTabColors(let tabIds, let color):
        // Apply the chosen color to every requested tab. No toggle-off
        // semantics here -- the cmd-1-on-red-clears UX is resolved at the
        // dispatcher via resolveColorForBatch before this Msg is sent.
        let validIds = normalizedLiveTabIds(tabIds, in: model)
        guard !validIds.isEmpty else { return [] }
        for id in validIds {
            updateTab(id, in: &model) { t in t.color = color }
        }
        // The color stripe updates via reconcileSidebar (color is in the projection).
        return []

    case .clearCustomTitles(let tabIds):
        let validIds = normalizedLiveTabIds(tabIds, in: model)
        guard !validIds.isEmpty else { return [] }
        for id in validIds {
            updateTab(id, in: &model) { t in t.customTitle = nil }
        }
        // The cleared rows reconcile via reconcileSidebar and the selected tab's window
        // chrome via reconcileWindowChrome.
        return []

    case .clearAlertsForTabs(let tabIds):
        let validIds = normalizedLiveTabIds(tabIds, in: model)
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
        return []

    case .adjustPaneFontSize(let paneId, let steps):
        guard let targetId = paneId ?? selectedTab(in: model)?.focusedPaneId,
              let pane = model.pane(targetId) else { return [] }
        // Bound the delta against the room this pane has left, not against the
        // step range: the latter saturates short (a pane at the floor jumped by
        // Int.max would stop below the ceiling), while this lands a huge jump
        // exactly on the bound and still keeps the addition from overflowing.
        let roomDown = paneFontSizeStepRange.lowerBound - pane.fontSizeSteps
        let roomUp = paneFontSizeStepRange.upperBound - pane.fontSizeSteps
        let next = pane.fontSizeSteps + min(max(steps, roomDown), roomUp)
        guard next != pane.fontSizeSteps else { return [] }
        model.updatePane(targetId) { $0.fontSizeSteps = next }
        // The pane re-grids via reconcilePaneConfig (font size is in the projection).
        return []

    case .resetPaneFontSize(let paneId):
        guard let targetId = paneId ?? selectedTab(in: model)?.focusedPaneId,
              let pane = model.pane(targetId), pane.fontSizeSteps != 0 else { return [] }
        model.updatePane(targetId) { $0.fontSizeSteps = 0 }
        return []

    case .renameTab(let id, let name):
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        let customTitle: String? = (trimmed?.isEmpty ?? true) ? nil : trimmed
        updateTab(id, in: &model) { t in t.customTitle = customTitle }
        // The renamed row updates via reconcileSidebar (displayTitle is in the projection)
        // and the selected tab's window chrome via reconcileWindowChrome.
        return []

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
        // Only adopt a pane that actually lives in the selected tab. A stray
        // becomeFirstResponder from a hidden/background session must not
        // corrupt this tab's focusedPaneId or clear the foreign pane's alerts.
        guard allPaneIds(tab.rootNode).contains(paneId) else { return [] }
        let oldFocusedId = tab.focusedPaneId
        guard paneId != oldFocusedId else { return [] }

        if model.config.alertClearMode == .focus {
            markAlertsReadForPane(paneId, in: &model)
        }
        updateSelectedTab(&model) { t in t.focusedPaneId = paneId }

        return []

    // MARK: - Session Lifecycles

    case .sessionReport(let sessionId, let report):
        guard report.isAdmitted,
              let paneId = model.pane(owning: sessionId)?.id,
              let previous = model.pane(paneId)?.session
        else { return [] }
        model.updateSession(sessionId) { reduceSession(&$0, report: report) }
        let didChange = model.pane(paneId)?.session != previous
        switch report {
        case .title, .cwd, .progress, .commandStarted, .agentAttached, .agentDetached:
            return []
        case .commandEnded:
            return []
        case .agentActivityChanged(_, .waiting):
            guard didChange else { return [] }
            guard selectedTab(in: model)?.focusedPaneId != paneId else { return [] }
            return desktopAlertCommands(
                model: &model,
                paneId: paneId,
                senderTitle: "",
                body: "Waiting for input",
                env: env
            )
        case .integrationReady, .connectionDeclared, .agentActivityChanged:
            return []
        }

    // MARK: - Config (external reload)

    case .configLoaded(let newConfig, let resolvedFontFamily):
        model.config = newConfig
        // Written as a pair with the config it was resolved from so config, resolution,
        // warning, and pane projection stay coherent and panes never render a stale family.
        model.resolvedFontFamily = resolvedFontFamily
        // Reset draft to match new config if panel is open.
        if model.preferencesDraft != nil {
            model.preferencesDraft!.alertClearMode = newConfig.alertClearMode
            model.preferencesDraft!.remoteTheme = newConfig.remoteTheme
            model.preferencesDraft!.theme = newConfig.defaultTheme
            model.preferencesDraft!.fontSize = newConfig.fontSize.map(configFontSizeText)
            model.preferencesDraft!.fontFamily = newConfig.fontFamily
            model.preferencesDraft!.copyOnSelect = newConfig.copyOnSelect
        }
        return []

    case .fontFamilyResolved(let resolvedFontFamily):
        model.resolvedFontFamily = resolvedFontFamily
        return []

    // MARK: - Preferences Panel

    case .preferencesOpened(let installedFontFamilies, let availableThemeNames):
        // Only create draft on closed → open transition; re-focus is a no-op.
        if model.preferencesDraft == nil {
            model.installedFontFamilies = installedFontFamilies
            model.availableThemeNames = availableThemeNames
            model.preferencesDraft = PreferencesDraft(
                alertClearMode: model.config.alertClearMode,
                remoteTheme: model.config.remoteTheme,
                theme: model.config.defaultTheme,
                fontSize: model.config.fontSize.map(configFontSizeText),
                fontFamily: model.config.fontFamily,
                copyOnSelect: model.config.copyOnSelect
            )
        }
        return []

    case .preferencesClosed:
        model.preferencesDraft = nil
        model.installedFontFamilies = []
        model.availableThemeNames = []
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

    case .prefSetFontFamily(let text):
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.fontFamily = text
        return []

    case .prefSetCopyOnSelect(let enabled):
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.copyOnSelect = enabled
        return []

    case .prefResetTheme:
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.theme = model.config.defaultTheme
        return []

    case .prefResetFontSize:
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.fontSize = model.config.fontSize.map(configFontSizeText)
        return []

    case .prefResetFontFamily:
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.fontFamily = model.config.fontFamily
        return []

    case .prefResetCopyOnSelect:
        guard model.preferencesDraft != nil else { return [] }
        model.preferencesDraft!.copyOnSelect = model.config.copyOnSelect
        return []

    case .prefSave:
        guard let draft = model.preferencesDraft else { return [] }
        let resolvedTheme = resolveRemoteTheme(draft.remoteTheme)
        let oldConfig = model.config
        var newConfig = oldConfig
        newConfig.alertClearMode = draft.alertClearMode
        newConfig.copyOnSelect = draft.copyOnSelect
        newConfig.remoteTheme = resolvedTheme
        newConfig.defaultTheme = draft.theme
        // A size outside the renderable range is bounded rather than rejected:
        // the number the user typed says which end they wanted, and storing it
        // raw would leave the panel showing a size no pane draws at.
        let parsedFontSize: Double? = draft.fontSize.flatMap { Double($0) }
        let validFontSize = draft.fontSize == nil
            || (parsedFontSize.map { $0.isFinite && $0 > 0 } ?? false)
        if validFontSize {
            newConfig.fontSize = parsedFontSize.map(DanTermConfig.boundedFontSize)
        }
        // Whether the family is installed is not knowable here and is not a
        // validation question anyway: an unavailable name is still written, since
        // it is the user's file and they may be about to install the font. The
        // runtime resolves what it writes and feeds the verdict back through
        // fontFamilyResolved, completing a coherent apply and repainting live panes
        // without a manual reload.
        newConfig.fontFamily = resolveFontFamilyDraft(draft.fontFamily)
        model.config = newConfig
        // Normalize draft to resolved values post-save. The size is echoed back
        // only when it was saved: text that failed to parse stays on screen for
        // the user to correct, and the field keeps reading dirty.
        model.preferencesDraft!.remoteTheme = resolvedTheme
        model.preferencesDraft!.fontFamily = newConfig.fontFamily
        if validFontSize {
            model.preferencesDraft!.fontSize = newConfig.fontSize.map(configFontSizeText)
        }
        return newConfig == oldConfig ? [] : [.saveDanTermConfig(newConfig)]

    // MARK: - Export

    case .exportState:
        return [.exportState(toSnapshot(model, home: env.homeDirectory()))]

    // MARK: - Terminal Session Callbacks

    case .sessionBell(let sessionId):
        guard let paneId = model.pane(owning: sessionId)?.id else { return [] }
        // No alert for the focused pane while the app is active; when inactive,
        // the focused pane is unseen and should follow the normal alert path.
        if model.isAppActive, let tab = selectedTab(in: model), tab.focusedPaneId == paneId {
            return []
        }

        guard tabForPane(paneId, in: model) != nil else { return [] }
        let paneTitle = model.pane(paneId)?.session?.title ?? "Terminal"

        // Hack: ack previous alerts so each pane has at most 1 unread alert.
        // This keeps pane badges boolean and tab badges count panes-with-alerts
        // rather than total alert volume. May replace with a better system later.
        markAlertsReadForPane(paneId, in: &model)

        let now = env.now()
        let alert = AlertModel(
            id: AlertId(rawValue: env.newId()), kind: .bell, paneId: paneId,
            title: "DanTerm", body: paneTitle, createdAt: now, isUnread: true
        )
        model.alerts.insert(alert, at: 0)
        if model.alerts.count > 100 { model.alerts.removeLast() }

        // The tab/group bell badges now ride reconcileSidebar (the projection counts
        // unread alerts per tab and per collapsed group); only the notification remains.
        var commands: [Command] = []

        commands.append(contentsOf: throttledNotification(
            alertId: alert.id, kind: .bell, paneId: paneId,
            title: "DanTerm", subtitle: nil, body: paneTitle, model: &model, now: now
        ))
        return commands

    case .sessionNotification(let sessionId, let title, let body):
        guard let paneId = model.pane(owning: sessionId)?.id else { return [] }
        return desktopAlertCommands(
            model: &model,
            paneId: paneId,
            senderTitle: title,
            body: body,
            env: env
        )

    case .sessionEnded(let sessionId):
        guard let paneId = model.pane(owning: sessionId)?.id else { return [] }
        return update(&model, .closePane(paneId: paneId), env: env)

    case .sessionCreationFailed(let sessionId):
        guard let paneId = model.pane(owning: sessionId)?.id else { return [] }
        // Session creation failure removes the whole containing tab, so every
        // sibling pane must be cleaned up as if the tab had been closed.
        for gi in model.groups.indices {
            if let ti = model.groups[gi].tabs.firstIndex(where: { allPaneIds($0.rootNode).contains(paneId) }) {
                let tab = model.groups[gi].tabs[ti]
                let tabId = tab.id
                let groupId = model.groups[gi].id
                for pid in allPaneIds(tab.rootNode) {
                    // Session teardown is reconcileSessionExistence's (these panes leave the
                    // tree below); keep side-table cleanup via clearPaneSideTables.
                    clearPaneSideTables(pid, in: &model)
                }

                model.groups[gi].tabs.remove(at: ti)
                removeGroupIfEmpty(groupId, from: &model)

                if model.selectedTabId == tabId {
                    model.selectedTabId = model.groups.flatMap(\.tabs).first?.id
                }
                if !model.hasAnyTab {
                    return [.terminate]
                }
                return []
            }
        }
        // A pane in no tree cannot exist now, so this fallback is just defensive
        // side-table cleanup -- no tree/pane removal needed.
        clearPaneSideTables(paneId, in: &model)
        return []

    // MARK: - Lifecycle

    case .appBecameActive:
        model.isAppActive = true
        if model.config.alertClearMode == .focus,
           let focusedPaneId = selectedTab(in: model)?.focusedPaneId {
            markAlertsReadForPane(focusedPaneId, in: &model)
        }
        return []

    case .appResignedActive:
        model.isAppActive = false
        if model.jumpMode != nil {
            model.jumpMode = nil   // jump badges clear via reconcileSidebar
        }
        return []

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
        var commands = navigateToPane(alert.paneId, in: &model, env: env)
        commands.append(.activateApp)
        commands.append(.dismissAlertsPopover)
        return commands

    case .goToMostRecentAlertPane:
        // Cmd-Shift-A finishes the current tab before moving to the next tab
        // that needs attention. Same-tab pane navigation is only the fallback
        // when no other tab has a live unread alert.
        guard let currentTab = selectedTab(in: model) else {
            guard let alert = model.alerts.first(where: { $0.isUnread && tabForPane($0.paneId, in: model) != nil }) else {
                return []
            }
            return navigateToPane(alert.paneId, in: &model, env: env)
        }

        let currentTabId = currentTab.id
        let currentFocusedPaneId = currentTab.focusedPaneId
        let currentPaneIds = Set(allPaneIds(currentTab.rootNode))
        let liveUnreadAlerts = model.alerts.compactMap { alert -> (alert: AlertModel, tab: TabModel)? in
            guard alert.isUnread, let tab = tabForPane(alert.paneId, in: model) else { return nil }
            return (alert, tab)
        }

        if let target = liveUnreadAlerts.first(where: { $0.tab.id != currentTabId }) {
            for paneId in currentPaneIds { markAlertsReadForPane(paneId, in: &model) }
            return navigateToPane(target.alert.paneId, in: &model, env: env)
        }

        if let target = liveUnreadAlerts.first(where: {
            currentPaneIds.contains($0.alert.paneId) && $0.alert.paneId != currentFocusedPaneId
        }) {
            let commands = navigateToPane(target.alert.paneId, in: &model, env: env)
            for paneId in currentPaneIds { markAlertsReadForPane(paneId, in: &model) }
            return commands
        }

        for paneId in currentPaneIds { markAlertsReadForPane(paneId, in: &model) }
        return []

    case .setShowAllAlerts(let showAll):
        model.showAllAlerts = showAll
        return []

    case .clearAlertsForPane(let paneId):
        let hadUnread = model.alerts.contains { $0.paneId == paneId && $0.isUnread }
        guard hadUnread else { return [] }
        markAlertsReadForPane(paneId, in: &model)
        return []   // bell badge reconciles via reconcileSidebar

    case .confirmTerminate:
        model.pendingConfirmation = nil
        return [.terminate]

    case .cancelTerminate:
        model.pendingConfirmation = nil
        return []

    case .confirmCloseTab(let id):
        model.pendingConfirmation = nil
        return update(&model, .closeTab(id: id), env: env)

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

        if !model.hasAnyTab {
            return commands + [.terminate]
        }
        return commands

    case .cancelCloseTabs:
        model.pendingConfirmation = nil
        return []

    case .terminate:
        return [.terminate]

    // MARK: - Group Management

    case .createGroup(let name, let launch):
        let groupId = GroupId(rawValue: env.newId())
        let group = GroupModel(id: groupId, name: name)
        model.groups.append(group)
        return update(&model, .createTab(inGroupId: groupId, launch: launch), env: env)

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
            // Close all tabs' sessions.
            for tab in group.tabs {
                for pid in allPaneIds(tab.rootNode) {
                    // Session teardown is reconcileSessionExistence's (these panes leave the
                    // tree below); keep side-table cleanup via clearPaneSideTables.
                    clearPaneSideTables(pid, in: &model)
                }
            }
            model.groups.remove(at: idx)
            if !model.hasAnyTab {
                return [.terminate]
            }
            // Fix selection if needed
            if let selId = model.selectedTabId,
               !model.groups.flatMap(\.tabs).contains(where: { $0.id == selId }) {
                model.selectedTabId = model.groups.flatMap(\.tabs).first?.id
            }
            return []
        }

        model.groups.remove(at: idx)
        return []

    case .renameGroup(let id, let name):
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let idx = model.groups.firstIndex(where: { $0.id == id }) else { return [] }
        model.groups[idx].name = trimmed
        return []

    case .moveTabs(let tabIds, let toGroupId, let atIndex):
        let validIds = normalizedLiveTabIds(tabIds, in: model)
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

        return []

    case .extractTabsToNewGroup(let tabIds, let groupName):
        let validIds = normalizedLiveTabIds(tabIds, in: model)
        guard !validIds.isEmpty else { return [] }

        // No-op: extracting every live tab (whether from one group or
        // across many) would prune every source group and leave the new
        // group as the sole group, collapsing existing structure and
        // triggering single-group mode where the promised inline rename
        // has no row to edit.
        let totalTabs = model.groups.reduce(0) { $0 + $1.tabs.count }
        if validIds.count == totalTabs { return [] }

        let newGroupId = GroupId(rawValue: env.newId())
        model.groups.append(GroupModel(id: newGroupId, name: groupName))

        // Reuse .moveTabs for tabLocation lookup, clamping, and
        // removeGroupIfEmpty pruning of vacated source groups. The new
        // group is empty, so atIndex: 0 is unambiguous; ids are inserted
        // in the order given. Discard nested commands; the sidebar updates via
        // reconcileSidebar.
        _ = update(&model, .moveTabs(tabIds: validIds, toGroupId: newGroupId, atIndex: 0), env: env)
        return []

    case .reorderGroup(let groupId, let toIndex):
        guard let currentIdx = model.groups.firstIndex(where: { $0.id == groupId }) else { return [] }
        let clamped = max(0, min(toIndex, model.groups.count - 1))
        let group = model.groups.remove(at: currentIdx)
        model.groups.insert(group, at: clamped)
        return []

    case .toggleGroupCollapse(let groupId):
        guard let idx = model.groups.firstIndex(where: { $0.id == groupId }) else { return [] }
        model.groups[idx].isCollapsed.toggle()
        return []

    case .toggleZoomPane(let paneId):
        // nil = selected tab (menubar path); non-nil = the pane's own tab
        // (mirrors .splitPane), so a stale context menu still zooms the tab
        // it was built for after a selection change.
        let tab: TabModel
        if let paneId {
            guard let found = tabForPane(paneId, in: model) else { return [] }
            tab = found
        } else {
            guard let found = selectedTab(in: model) else { return [] }
            tab = found
        }
        if tab.isZoomed {
            updateTab(tab.id, in: &model) { t in t.isZoomed = false }
            return []
        }
        if case .split = tab.rootNode {
            updateTab(tab.id, in: &model) { t in t.isZoomed = true }
            return []
        }
        return []

    // MARK: - View

    case .splitRatioChanged(let splitId, let ratio):
        // Hidden background containers stay mounted and can fire
        // splitViewDidResizeSubviews during window resize, so resolve the
        // split's own tab instead of assuming the selected tab owns it.
        guard let tab = tabForSplit(splitId, in: model) else { return [] }
        updateTab(tab.id, in: &model) { tab in
            tab.rootNode = setRatio(tab.rootNode, splitId: splitId, ratio: ratio)
        }
        return []

    // MARK: - Search

    case .startSearch:
        guard let tab = selectedTab(in: model) else { return [] }
        return [.sendStartSearch(paneId: tab.focusedPaneId)]

    case .searchStarted(let paneId, let needle):
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
        model.searchState[paneId]?.status = nil
        // The overlay re-renders from the searchState change via reconcilePaneChrome.
        return [.sendSearchNeedle(paneId: paneId, needle: needle)]

    case .searchNavigate(let paneId, let direction):
        guard model.searchState[paneId] != nil else { return [] }
        return [.sendSearchNavigate(paneId: paneId, direction: direction)]

    case .navigateFocusedSearch(let direction):
        // The menu items stay enabled, so Cmd-G with no open overlay lands here and
        // must do nothing rather than drive engine search state invisibly.
        guard let tab = selectedTab(in: model) else { return [] }
        return update(&model, .searchNavigate(paneId: tab.focusedPaneId, direction: direction), env: env)

    case .endSearch(let paneId):
        guard model.searchState[paneId] != nil else { return [] }
        model.searchState.removeValue(forKey: paneId)
        // Clearing searchState drops the pane's key from the overlay projection, so
        // reconcilePaneChrome's `remove` tears the overlay down (no .hideSearchOverlay).
        return [.sendEndSearch(paneId: paneId), .makeFirstResponder(paneId: paneId)]

    case .searchTotalReported(let paneId, let total):
        guard model.searchState[paneId] != nil else { return [] }
        // Backends report the total first and the selection that goes with it second,
        // so a fresh total supersedes any standing selection rather than keeping an
        // index the new count may no longer contain.
        model.searchState[paneId]?.status = total.map { .counted(total: $0) }
        // reconcilePaneChrome re-renders the overlay's match count from this change.
        return []

    case .searchSelectionReported(let paneId, let selected):
        // A selection is only meaningful against a standing total; one arriving
        // before any total is dropped, which is what keeps the impossible
        // "selected without total" pair out of the model.
        guard let status = model.searchState[paneId]?.status else { return [] }
        model.searchState[paneId]?.status = selected.map {
            .matched(selected: $0, total: status.total)
        } ?? .counted(total: status.total)
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
            t.todos.append(TodoItem(id: env.newId(), text: trimmed, isDone: false))
        }
        return []

    case .toggleTabTodoDone(let tabId, let todoId):
        guard let tab = tabById(tabId, in: model),
              let idx = tab.todos.firstIndex(where: { $0.id == todoId }) else { return [] }
        updateTab(tabId, in: &model) { t in
            t.todos[idx].isDone.toggle()
        }
        return []

    case .setTabTodoDone(let tabId, let todoId, let isDone):
        guard let tab = tabById(tabId, in: model),
              let idx = tab.todos.firstIndex(where: { $0.id == todoId }),
              tab.todos[idx].isDone != isDone else { return [] }
        updateTab(tabId, in: &model) { t in
            t.todos[idx].isDone = isDone
        }
        return []

    case .editTabTodoText(let tabId, let todoId, let text):
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let tab = tabById(tabId, in: model),
              let idx = tab.todos.firstIndex(where: { $0.id == todoId }) else { return [] }
        updateTab(tabId, in: &model) { t in
            t.todos[idx].text = trimmed
        }
        return []

    case .deleteTabTodo(let tabId, let todoId):
        guard tabById(tabId, in: model) != nil else { return [] }
        updateTab(tabId, in: &model) { t in
            t.todos.removeAll { $0.id == todoId }
        }
        return []

    case .reorderTabTodo(let tabId, let todoId, let toIndex):
        guard let tab = tabById(tabId, in: model),
              let todos = reorderedTodos(tab.todos, moving: todoId, to: toIndex) else { return [] }
        updateTab(tabId, in: &model) { t in t.todos = todos }
        return []

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
        return []

    case .clearCompletedTabTodos(let tabId):
        guard tabById(tabId, in: model) != nil else { return [] }
        updateTab(tabId, in: &model) { t in
            t.todos.removeAll { $0.isDone }
        }
        return []

    case .addTodo(let paneId, let text):
        guard appendTodo(&model, paneId: paneId, text: text, id: env.newId()) != nil else { return [] }
        return []

    case .toggleTodoDone(let paneId, let todoId):
        guard let idx = model.pane(paneId)?.todos.firstIndex(where: { $0.id == todoId }) else { return [] }
        model.updatePane(paneId) { $0.todos[idx].isDone.toggle() }
        return []

    case .setTodoDone(let paneId, let todoId, let isDone):
        guard let pane = model.pane(paneId),
              let idx = pane.todos.firstIndex(where: { $0.id == todoId }),
              pane.todos[idx].isDone != isDone else { return [] }
        model.updatePane(paneId) { $0.todos[idx].isDone = isDone }
        return []

    case .editTodoText(let paneId, let todoId, let text):
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        guard let idx = model.pane(paneId)?.todos.firstIndex(where: { $0.id == todoId }) else { return [] }
        model.updatePane(paneId) { $0.todos[idx].text = trimmed }
        return []

    case .deleteTodo(let paneId, let todoId):
        model.updatePane(paneId) { $0.todos.removeAll { $0.id == todoId } }
        return []

    case .reorderTodo(let paneId, let todoId, let toIndex):
        guard let current = model.pane(paneId)?.todos,
              let todos = reorderedTodos(current, moving: todoId, to: toIndex) else { return [] }
        model.updatePane(paneId) { $0.todos = todos }
        return []

    case .clearCompletedTodos(let paneId):
        model.updatePane(paneId) { $0.todos.removeAll { $0.isDone } }
        return []

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
                    &model, tabId: tab.id, tabTitle: tabDisplayTitle(tab, in: model),
                    paneCount: 1, isLastTab: isLastTab,
                    uncompletedTodoCount: rollup.uncompleted
                )
            }
            return update(&model, .closePane(paneId: paneId), env: env)
        }
        let uncompletedCount = pane.todos.count { !$0.isDone }
        if uncompletedCount > 0 {
            return [.showClosePaneConfirmation(paneId: paneId, uncompletedCount: uncompletedCount)]
        }
        return update(&model, .closePane(paneId: paneId), env: env)

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

/// Pure todo reorder shared by the pane and tab handlers: removes `todoId` and
/// reinserts it at the clamped destination. Returns nil when the id is absent,
/// the index is out of range, or the item would not move -- so both callers can
/// `guard let` it and skip the checkpoint on a no-op.
func reorderedTodos(_ todos: [TodoItem], moving todoId: UUID, to toIndex: Int) -> [TodoItem]? {
    guard let fromIndex = todos.firstIndex(where: { $0.id == todoId }),
          toIndex >= 0, toIndex <= todos.count else { return nil }
    let clampedTo = min(toIndex, todos.count - 1)
    guard fromIndex != clampedTo else { return nil }
    var result = todos
    let item = result.remove(at: fromIndex)
    result.insert(item, at: min(clampedTo, result.count))
    return result
}

// MARK: - IPC Handlers

/// Non-throwing IPC error boundary: callers get `Command` replies while the
/// method dispatcher can use thrown validation errors internally.
private func handleIpcRequest(
    _ model: inout AppModel,
    reqId: UUID,
    method: String,
    params: JSONValue,
    context: IpcRequestContext,
    env: CoreEnv
) -> [Command] {
    do {
        return try dispatchIpc(
            &model,
            reqId: reqId,
            method: method,
            params: params,
            context: context,
            env: env
        )
    } catch let error as IpcParamsError {
        return ipcInvalidParams(reqId, error.message)
    } catch let error as LaunchSpecParseError {
        return ipcInvalidParams(reqId, launchSpecErrorMessage(error))
    } catch {
        return [.ipcError(reqId: reqId, code: -32603, message: "internal error")]
    }
}

/// Carries per-method IPC dispatch behind `handleIpcRequest`, so each case can
/// validate with `throw` before mutating the model and leave reply translation central.
private func dispatchIpc(
    _ model: inout AppModel,
    reqId: UUID,
    method: String,
    params: JSONValue,
    context: IpcRequestContext,
    env: CoreEnv
) throws -> [Command] {
    switch method {
    case Methods.doctorPermissions:
        return [.readDoctorPermissions(reqId: reqId)]

    case Methods.ls:
        let encoder = IpcEntityEncoder(home: env.homeDirectory())
        return [.ipcReply(reqId: reqId, result: encoder.list(model))]

    case Methods.paneInfo:
        let paneId = try resolvePane(params: params, context: context, in: model)
        guard let pane = model.pane(paneId),
              let tab = tabForPane(paneId, in: model),
              let group = groupForTab(tab.id, in: model)
        else {
            throw IpcParamsError("pane not found")
        }
        let encoder = IpcEntityEncoder(home: env.homeDirectory())
        return [.ipcReply(
            reqId: reqId,
            result: encoder.paneInfo(pane: pane, tab: tab, group: group, in: model)
        )]

    case Methods.agentAttach:
        let session = try agentSession(from: params)
        let paneId = try resolvePane(params: params, context: context, in: model)
        guard let sessionId = model.pane(paneId)?.session?.id else {
            throw IpcParamsError("pane not found")
        }
        let commands = update(
            &model,
            .sessionReport(sessionId: sessionId, report: .agentAttached(session)),
            env: env
        )
        return commands + [.ipcReply(reqId: reqId, result: .object(["ok": .bool(true)]))]

    case Methods.agentActivity:
        let session = try agentSession(from: params)
        guard case .object(let object) = params,
              case .string(let rawActivity)? = object["state"],
              let activity = AgentActivity(rawIpcValue: rawActivity)
        else {
            throw IpcParamsError("invalid agent activity")
        }
        let paneId = try resolvePane(params: params, context: context, in: model)
        guard let sessionId = model.pane(paneId)?.session?.id else {
            throw IpcParamsError("pane not found")
        }
        let commands = update(
            &model,
            .sessionReport(
                sessionId: sessionId,
                report: .agentActivityChanged(session: session, activity: activity)
            ),
            env: env
        )
        return commands + [.ipcReply(reqId: reqId, result: .object(["ok": .bool(true)]))]

    case Methods.agentDetach:
        let session = try agentSession(from: params)
        let paneId = try resolvePane(params: params, context: context, in: model)
        guard let sessionId = model.pane(paneId)?.session?.id else {
            throw IpcParamsError("pane not found")
        }
        let commands = update(
            &model,
            .sessionReport(sessionId: sessionId, report: .agentDetached(session)),
            env: env
        )
        return commands + [.ipcReply(reqId: reqId, result: .object(["ok": .bool(true)]))]

    case Methods.tabRename:
        guard case .object(let object) = params else {
            throw IpcParamsError("invalid params")
        }
        let tabId = try resolveTab(params: params, context: context, in: model)
        guard let titleValue = object["title"] else {
            throw IpcParamsError("invalid title")
        }
        let title: String?
        switch titleValue {
        case .string(let value):
            title = value
        case .null:
            title = nil
        default:
            throw IpcParamsError("invalid title")
        }
        let commands = update(&model, .renameTab(id: tabId, name: title), env: env)
        return commands + [.ipcReply(reqId: reqId, result: tabRenameResult(tabById(tabId, in: model)))]

    case Methods.tabClose:
        let tabId = try resolveTab(params: params, context: context, in: model)
        // Refuse the last tab: routing it through .closeTab would set a terminate
        // confirmation, leave the tab open, and strand pendingConfirmation. The CLI
        // never quits the app as a side effect of closing a tab.
        if wouldQuitFromClose(model) {
            throw IpcParamsError("cannot close the last tab")
        }
        let commands = update(&model, .closeTab(id: tabId), env: env)
        return commands + [.ipcReply(reqId: reqId, result: .object([
            "tab": .object(["id": .string(tabId.rawValue.uuidString)])
        ]))]

    case Methods.paneSplit:
        guard case .object(let object) = params,
              case .string(let rawDirection)? = object["direction"],
              let direction = ipcSplitDirection(rawDirection)
        else {
            throw IpcParamsError("invalid pane split params")
        }
        let launch = try parseLaunchSpec(object["launch"])
        let background = try parseOptionalBool(object["background"], name: "background")
        let paneId = try resolvePane(params: params, context: context, in: model)
        let before = Set(model.allPaneIds)
        let commands = update(
            &model,
            .splitPane(paneId: paneId, direction: direction, launch: launch, background: background),
            env: env
        )
        let newPaneId = model.allPaneIds.first(where: { !before.contains($0) })
        let encoder = IpcEntityEncoder(home: env.homeDirectory())
        return commands + [.ipcReply(reqId: reqId, result: encoder.paneReference(newPaneId.flatMap(model.pane)))]

    case Methods.paneClose:
        let paneId = try resolvePane(
            params: params,
            context: context,
            in: model,
            requireExplicit: true
        )
        guard let tab = tabForPane(paneId, in: model) else {
            throw IpcParamsError("pane not found")
        }
        if allPaneIds(tab.rootNode).count == 1, wouldQuitFromClose(model) {
            throw IpcParamsError("cannot close the last pane")
        }
        let commands = update(&model, .closePane(paneId: paneId), env: env)
        return commands + [.ipcReply(reqId: reqId, result: .object([
            "pane": .object(["id": .string(paneId.rawValue.uuidString)])
        ]))]

    case Methods.tabNew:
        guard case .object(let object) = params else {
            throw IpcParamsError("invalid params")
        }
        let launch = try parseLaunchSpec(object["launch"])
        let background = try parseOptionalBool(object["background"], name: "background")
        let position = try parseTabInsertPosition(object)
        let groupId = try resolveTabNewTargetGroup(position: position, params: params, context: context, in: model)
        var effectiveLaunch = launch
        if effectiveLaunch?.cwd == nil,
           let callerPaneId = resolveIpcPaneId(context, in: model),
           let cwd = model.pane(callerPaneId)?.session?.cwd {
            effectiveLaunch = LaunchSpec(
                cmd: effectiveLaunch?.cmd,
                cwd: cwd,
                title: effectiveLaunch?.title
            )
        }
        let before = liveTabIds(in: model)
        let createTabMsg: Msg
        if let position {
            createTabMsg = .createTab(inGroupId: groupId, position: position, launch: effectiveLaunch, background: background)
        } else {
            createTabMsg = .createTab(inGroupId: groupId, launch: effectiveLaunch, background: background)
        }
        let commands = update(&model, createTabMsg, env: env)
        let tabId = newestTabId(excluding: before, in: model)
        let tab = tabId.flatMap { tabById($0, in: model) }
        let group = model.groups.first(where: { $0.id == groupId })
        let encoder = IpcEntityEncoder(home: env.homeDirectory())
        return commands + [.ipcReply(
            reqId: reqId,
            result: encoder.tabNew(tab: tab, group: group, in: model)
        )]

    case Methods.paneFocus:
        var focusParams = params
        // `paneId` is a deprecated direct-IPC alias; forward CLI traffic sends `pane`.
        if case .object(var object) = params,
           object["pane"] == nil,
           let legacyPaneId = object["paneId"] {
            object["pane"] = legacyPaneId
            focusParams = .object(object)
        }
        let paneId = try resolvePane(params: focusParams, context: context, in: model, requireExplicit: true)
        let commands = navigateToPane(paneId, in: &model, env: env)
        return commands + [.ipcReply(reqId: reqId, result: tabFocusResult(tabForPane(paneId, in: model)))]

    case Methods.themeSet:
        guard case .object(let object) = params,
              let themeValue = object["themeName"]
        else {
            throw IpcParamsError("invalid theme params")
        }
        let paneId = try resolvePane(params: params, context: context, in: model)
        let themeName: String?
        switch themeValue {
        case .null:
            themeName = nil
        case .string(let name):
            themeName = name
        default:
            throw IpcParamsError("invalid theme name")
        }
        let commands = update(&model, .setPaneTheme(paneId: paneId, themeName: themeName), env: env)
        let encoder = IpcEntityEncoder(home: env.homeDirectory())
        return commands + [.ipcReply(reqId: reqId, result: encoder.paneTheme(model.pane(paneId)))]

    case Methods.paneInput:
        let paneId = try resolvePane(params: params, context: context, in: model)
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

    case Methods.paneRead:
        guard case .object(let object) = params else {
            throw IpcParamsError("invalid params")
        }
        let paneId = try resolvePane(params: params, context: context, in: model, requireExplicit: true)

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

    case Methods.paneZoom:
        let paneId = try resolvePane(params: params, context: context, in: model)
        guard case .string(let requested)? = params["state"] else {
            throw IpcParamsError("state must be one of on, off, toggle")
        }
        guard let tab = tabForPane(paneId, in: model) else {
            throw IpcParamsError("pane not found")
        }
        let target: Bool
        switch requested {
        case "on": target = true
        case "off": target = false
        case "toggle": target = tab.isZoomed == false
        default:
            throw IpcParamsError("state must be one of on, off, toggle")
        }
        // Route through `.toggleZoomPane` rather than writing `isZoomed` here, so the
        // scripted path and the menubar/context-menu paths cannot drift: the guard that
        // only a split tab may zoom lives there and is the reason a request can be
        // honoured and still report `isZoomed: false`.
        if tab.isZoomed != target {
            _ = update(&model, .toggleZoomPane(paneId: paneId), env: env)
        }
        guard let pane = model.pane(paneId),
              let currentTab = tabForPane(paneId, in: model),
              let group = groupForTab(currentTab.id, in: model)
        else {
            throw IpcParamsError("pane not found")
        }
        let encoder = IpcEntityEncoder(home: env.homeDirectory())
        return [.ipcReply(
            reqId: reqId,
            result: encoder.paneInfo(pane: pane, tab: currentTab, group: group, in: model)
        )]

    case Methods.paneRows:
        let paneId = try resolvePane(params: params, context: context, in: model, requireExplicit: true)
        return [.readPaneRowStructure(reqId: reqId, paneId: paneId)]

    case Methods.paneTape:
        let paneId = try resolvePane(
            params: params,
            context: context,
            in: model,
            requireExplicit: true
        )
        let follow: Bool
        switch params["follow"] {
        case nil:
            follow = false
        case .some(.bool(let value)):
            follow = value
        default:
            throw IpcParamsError("follow must be boolean")
        }
        let fromNow: Bool
        switch params["fromNow"] {
        case nil:
            fromNow = false
        case .some(.bool(let value)):
            fromNow = value
        default:
            throw IpcParamsError("fromNow must be boolean")
        }
        guard fromNow == false || follow else {
            throw IpcParamsError("fromNow requires follow")
        }
        return follow
            ? [.followPaneTape(reqId: reqId, paneId: paneId, fromNow: fromNow)]
            : [.dumpPaneTape(reqId: reqId, paneId: paneId)]

    case Methods.todoList:
        let paneId = try resolvePane(params: params, context: context, in: model)
        let todos = model.pane(paneId)?.todos ?? []
        return [.ipcReply(reqId: reqId, result: todoListResult(todos))]

    case Methods.todoAdd:
        guard case .object(let object) = params,
              case .string(let text)? = object["text"]
        else {
            throw IpcParamsError("invalid todo text")
        }
        let paneId = try resolvePane(params: params, context: context, in: model)
        guard let item = appendTodo(&model, paneId: paneId, text: text, id: env.newId()) else {
            throw IpcParamsError("invalid todo text")
        }
        // Pane toolbar (incl. todo counts) reconciles from the model change above.
        return [.ipcReply(reqId: reqId, result: todoResult(item))]

    case Methods.todoEdit:
        guard case .object(let object) = params,
              case .string(let rawTodoId)? = object["todoId"],
              case .string(let text)? = object["text"],
              let todoId = parseTodoId(rawTodoId),
              !text.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw IpcParamsError("invalid todo")
        }
        let paneId = try resolvePane(params: params, context: context, in: model)
        guard todoExists(todoId, paneId: paneId, in: model) else {
            throw IpcParamsError("invalid todo")
        }
        let commands = update(&model, .editTodoText(paneId: paneId, todoId: todoId, text: text), env: env)
        let updated = model.pane(paneId)?.todos.first(where: { $0.id == todoId })
        return commands + [
            .ipcReply(reqId: reqId, result: todoResult(updated)),
        ]

    case Methods.todoDone, Methods.todoOpen:
        guard case .object(let object) = params,
              case .string(let rawTodoId)? = object["todoId"],
              let todoId = parseTodoId(rawTodoId)
        else {
            throw IpcParamsError("invalid todo")
        }
        let paneId = try resolvePane(params: params, context: context, in: model)
        guard todoExists(todoId, paneId: paneId, in: model) else {
            throw IpcParamsError("invalid todo")
        }
        let shouldBeDone = method == Methods.todoDone
        let commands = update(&model, .setTodoDone(paneId: paneId, todoId: todoId, isDone: shouldBeDone), env: env)
        let updated = model.pane(paneId)?.todos.first(where: { $0.id == todoId })
        return commands + [
            .ipcReply(reqId: reqId, result: todoResult(updated)),
        ]

    case Methods.todoDelete:
        guard case .object(let object) = params,
              case .string(let rawTodoId)? = object["todoId"],
              let todoId = parseTodoId(rawTodoId)
        else {
            throw IpcParamsError("invalid todo")
        }
        let paneId = try resolvePane(params: params, context: context, in: model)
        guard todoExists(todoId, paneId: paneId, in: model) else {
            throw IpcParamsError("invalid todo")
        }
        let commands = update(&model, .deleteTodo(paneId: paneId, todoId: todoId), env: env)
        return commands + [
            .ipcReply(reqId: reqId, result: okResult()),
        ]

    case Methods.todoClearCompleted:
        let paneId = try resolvePane(params: params, context: context, in: model)
        let commands = update(&model, .clearCompletedTodos(paneId: paneId), env: env)
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

/// Validates the session identity shared by every pane-scoped agent mutation.
private func agentSession(from params: JSONValue) throws -> AgentSession {
    guard case .object(let object) = params,
          case .string(let kind)? = object["kind"],
          case .string(let sessionId)? = object["id"],
          let session = AgentSession(kind: kind, sessionId: sessionId)
    else {
        throw IpcParamsError("invalid agent session")
    }
    return session
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

/// Centralizes IPC target lookup so explicit pane/tab/group params and context
/// fallback share one vocabulary and one no-silent-fallback rule.
private func resolveTarget<ID>(
    entity: String,
    params: JSONValue,
    parse: (String) -> ID?,
    exists: (ID) -> Bool,
    contextID: () -> ID?,
    requireExplicit: Bool
) throws -> ID {
    if case .object(let object) = params, let raw = object[entity] {
        guard case .string(let str) = raw else {
            throw IpcParamsError("\(entity) must be a string")
        }
        guard let id = parse(str), exists(id) else {
            throw IpcParamsError("\(entity) not found")
        }
        return id
    }
    if requireExplicit {
        throw IpcParamsError("\(entity) required")
    }
    if let id = contextID() {
        return id
    }
    throw IpcParamsError("no \(entity) in context")
}

/// Keeps pane-targeting IPC commands on the shared resolver while preserving
/// their live-pane context fallback policy.
private func resolvePane(
    params: JSONValue,
    context: IpcRequestContext,
    in model: AppModel,
    requireExplicit: Bool = false
) throws -> PaneId {
    try resolveTarget(
        entity: "pane",
        params: params,
        parse: { parsePaneId($0) },
        exists: { model.pane($0) != nil },
        contextID: { resolveIpcPaneId(context, in: model) },
        requireExplicit: requireExplicit
    )
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

/// Resolves tab-targeting IPC commands from an explicit tab field or the tab
/// containing the pane in request context.
private func resolveTab(
    params: JSONValue,
    context: IpcRequestContext,
    in model: AppModel,
    requireExplicit: Bool = false
) throws -> TabId {
    try resolveTarget(
        entity: "tab",
        params: params,
        parse: { parseTabId($0) },
        exists: { tabById($0, in: model) != nil },
        contextID: {
            guard let paneId = parsePaneId(context.paneId) else { return nil }
            return tabForPane(paneId, in: model)?.id
        },
        requireExplicit: requireExplicit
    )
}

/// Resolves group-targeting IPC commands from an explicit group field or the
/// group containing the pane in request context.
private func resolveGroup(
    params: JSONValue,
    context: IpcRequestContext,
    in model: AppModel,
    requireExplicit: Bool = false
) throws -> GroupId {
    try resolveTarget(
        entity: "group",
        params: params,
        parse: { parseGroupId($0) },
        exists: { id in model.groups.contains { $0.id == id } },
        contextID: {
            guard let paneId = parsePaneId(context.paneId),
                  let tab = tabForPane(paneId, in: model),
                  let group = groupForTab(tab.id, in: model)
            else { return nil }
            return group.id
        },
        requireExplicit: requireExplicit
    )
}

private func resolveTabNewTargetGroup(
    position: TabInsertPosition?,
    params: JSONValue,
    context: IpcRequestContext,
    in model: AppModel
) throws -> GroupId {
    guard case .afterTab(let refTabId) = position else {
        return try resolveGroup(params: params, context: context, in: model)
    }
    guard tabById(refTabId, in: model) != nil else {
        throw IpcParamsError("position.afterTabId not found")
    }
    guard let refGroup = groupForTab(refTabId, in: model) else {
        throw IpcParamsError("position.afterTabId not found")
    }
    if case .object(let object) = params, object["group"] != nil {
        let requestedGroupId = try resolveGroup(params: params, context: context, in: model)
        guard requestedGroupId == refGroup.id else {
            throw IpcParamsError("position.afterTabId is not in the requested group")
        }
        return requestedGroupId
    }
    return refGroup.id
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

private func todoResult(_ item: TodoItem?) -> JSONValue {
    .object(["todo": item.map(todoJSON) ?? .null])
}

private func todoListResult(_ todos: [TodoItem]) -> JSONValue {
    .object(["todos": .array(todos.map(todoJSON))])
}

private func okResult() -> JSONValue {
    .object(["ok": .bool(true)])
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
            commands.append(.focusSession(paneId: oldPaneId, focused: false))
        }
    }
    model.selectedTabId = id
    if model.config.alertClearMode == .focus, let tab = selectedTab(in: model) {
        markAlertsReadForPane(tab.focusedPaneId, in: &model)
    }
    // Selection is view-owned: reconcileSidebar reapplies it (replacing the deleted
    // .setSidebarSelection), and any cleared-alert bell badges update from the projection.
    // The selected tab's window chrome reconciles via reconcileWindowChrome.
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

    // Tabs may have been removed mid-cycle (closeTab, sessionCreationFailed,
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
private func navigateToPane(
    _ paneId: PaneId,
    in model: inout AppModel,
    env: CoreEnv
) -> [Command] {
    guard let currentTab = tabForPane(paneId, in: model) else { return [] }
    let wasZoomed = currentTab.isZoomed
    let oldFocusedPaneId = currentTab.focusedPaneId
    let focusChanged = paneId != oldFocusedPaneId
    var commands = update(&model, .selectTab(id: currentTab.id), env: env)
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
        // Session teardown is reconcileSessionExistence's (these panes leave the tree
        // below); keep side-table cleanup + per-pane popover dismiss here.
        clearPaneSideTables(pid, in: &model)
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

/// Raises one pane alert through the shared stored-alert and macOS notification
/// path after resolving its semantic title tiers.
private func desktopAlertCommands(
    model: inout AppModel,
    paneId: PaneId,
    senderTitle: String,
    body: String,
    env: CoreEnv
) -> [Command] {
    guard senderTitle.fitsTerminalMetadataValueLimit,
          body.fitsTerminalMetadataValueLimit
    else { return [] }
    if model.isAppActive, let tab = selectedTab(in: model), tab.focusedPaneId == paneId {
        return []
    }
    guard tabForPane(paneId, in: model) != nil else { return [] }

    markAlertsReadForPane(paneId, in: &model)
    let presentation = alertPresentation(
        senderTitle: senderTitle,
        paneId: paneId,
        in: model
    )
    let now = env.now()
    let alert = AlertModel(
        id: AlertId(rawValue: env.newId()),
        kind: .desktopNotification,
        paneId: paneId,
        title: presentation.title,
        body: body,
        createdAt: now,
        isUnread: true
    )
    model.alerts.insert(alert, at: 0)
    if model.alerts.count > 100 { model.alerts.removeLast() }

    return throttledNotification(
        alertId: alert.id,
        kind: .desktopNotification,
        paneId: paneId,
        title: presentation.title,
        subtitle: presentation.subtitle,
        body: body,
        model: &model,
        now: now
    )
}

/// Throttle macOS notification delivery: one per pane per kind every throttle interval.
private func throttledNotification(
    alertId: AlertId, kind: AlertKind, paneId: PaneId,
    title: String, subtitle: String?, body: String, model: inout AppModel, now: Date
) -> [Command] {
    let shouldNotify: Bool
    if let last = model.lastNotificationTime[paneId]?[kind] {
        shouldNotify = now.timeIntervalSince(last) >= notificationThrottleInterval
    } else {
        shouldNotify = true
    }

    guard shouldNotify else { return [] }

    model.lastNotificationTime[paneId, default: [:]][kind] = now

    return [.sendNotification(
        alertId: alertId, paneId: paneId, title: title, subtitle: subtitle, body: body
    )]
}
