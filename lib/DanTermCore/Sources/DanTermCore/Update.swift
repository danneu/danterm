// Pure reducer for DanTerm's Elm-style state machine. External IPC method dispatch
// lives in IpcDispatch.swift so this file stays focused on message-driven state changes.
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
    defer {
        reconcileMru(&model)
        reconcileTodoPopover(&model)
        reconcilePendingConfirmation(&model, env: env)
    }

    switch msg {

    // MARK: - IPC

    case .ipcRequest(let reqId, let request):
        return handleIpcRequest(
            &model,
            reqId: reqId,
            request: request,
            env: env
        )

    case .ipcRequestDecodeFailed(let reqId, let error):
        return [.ipcError(reqId: reqId, code: error.code, message: error.message)]

    // MARK: - Tab Management

    case .createTabInSelectedGroup(let position, let launch, let background):
        let groupId = model.selectedTabId
            .flatMap { groupForTab($0, in: model)?.id }
            ?? model.groups.first?.id
        guard let groupId else { return [] }
        return update(
            &model,
            .createTab(
                inGroupId: groupId,
                position: position,
                launch: launch,
                background: background
            ),
            env: env
        )

    case .createTab(let inGroupId, let position, let launch, let background):
        guard let targetGroupIndex = model.groups.firstIndex(where: { $0.id == inGroupId }) else {
            return []
        }
        let paneId = PaneId(rawValue: env.newId())
        let sessionId = SessionId(rawValue: env.newId())
        let tabId = TabId(rawValue: env.newId())
        let cwd = launch?.cwd ?? currentCwd(in: model)

        let launchTitle = launch?.title?.singleLineName
        let pane = PaneModel(
            id: paneId,
            session: SessionModel(id: sessionId, title: launchTitle ?? "Terminal")
        )

        // The leaf owns the pane content directly -- no separate dict write.
        var tab = TabModel(id: tabId, paneTree: PaneTree(root: .leaf(pane)))
        tab.customTitle = launchTitle

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
        guard tabById(id, in: model) != nil else { return [] }
        let subject = ConfirmationSubject.tab(id)
        guard let impact = closeImpact(for: subject, in: model) else { return [] }

        if impact.panes.count > 1 || impact.hasWarning {
            return emitConfirmation(
                &model,
                subject: subject,
                quitAuthorized: totalTabCount(model) == 1,
                env: env
            )
        }

        return update(&model, .closeTab(id: id), env: env)

    case .requestCloseTabs(let ids):
        let normalized = normalizedLiveTabIds(ids, in: model)
        guard !normalized.isEmpty else { return [] }
        guard normalized.count > 1 else {
            return update(&model, .requestCloseTab(id: normalized[0]), env: env)
        }
        return emitConfirmation(
            &model,
            subject: .tabs(normalized),
            quitAuthorized: normalized.count == totalTabCount(model),
            env: env
        )

    case .closeTab(let id):
        return closeTabBody(&model, id: id, quitAuthorized: false, env: env)

    // MARK: - Pane Management

    case .splitFocusedPane(let direction, let launch, let background):
        guard let paneId = selectedTab(in: model)?.paneTree.focusedPaneId else { return [] }
        return update(
            &model,
            .splitPane(
                paneId: paneId,
                direction: direction,
                launch: launch,
                background: background
            ),
            env: env
        )

    case .splitPane(let targetPaneId, let direction, let launch, let background):
        guard let tab = tabForPane(targetPaneId, in: model) else { return [] }
        let newPaneId = PaneId(rawValue: env.newId())
        let newSessionId = SessionId(rawValue: env.newId())
        let newSplitId = SplitId(rawValue: env.newId())
        let cwd = launch?.cwd ?? model.pane(targetPaneId)?.session?.cwd
        let theme = model.pane(targetPaneId)?.theme
        let fontSizeSteps = model.pane(targetPaneId)?.fontSizeSteps ?? 0

        var newPane = PaneModel(
            id: newPaneId,
            session: SessionModel(
                id: newSessionId, title: launch?.title?.singleLineName ?? "Terminal")
        )
        newPane.theme = theme
        newPane.fontSizeSteps = fontSizeSteps

        var paneTree = tab.paneTree
        guard paneTree.split(
            paneId: targetPaneId, direction: direction, newPane: newPane,
            newSplitId: newSplitId, focusNewPane: !background
        ) else { return [] }

        updateTab(tab.id, in: &model) { tab in
            tab.paneTree = paneTree
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
        return closePaneBody(&model, paneId: paneId, quitAuthorized: false, env: env)

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
        guard !tab.paneTree.isZoomed else { return [] }

        var paneTree = tab.paneTree
        let didMove: Bool
        if intent == .swap {
            didMove = paneTree.swap(source: source, target: target)
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
            didMove = paneTree.move(
                source: source, target: target, direction: direction,
                insertFirst: insertFirst, newSplitId: newSplitId
            )
        }

        guard didMove else { return [] }
        updateSelectedTab(&model) { tab in
            tab.paneTree = paneTree
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
        var sourcePaneTree = sourceTab.paneTree
        guard let removal = sourcePaneTree.remove(paneId) else { return [] }

        // Update target tab: wrap its root with the moved pane.
        updateTab(targetTabId, in: &model) { tab in
            tab.paneTree.adopt(removal.pane, splitId: SplitId(rawValue: env.newId()))
        }

        // Handle source tab
        if !removal.emptiedTree {
            // Source tab still has panes — update it
            updateTab(sourceTab.id, in: &model) { tab in
                tab.paneTree = sourcePaneTree
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
        return commands

    case .movePaneToNewTab(let paneId, let inGroupId, let atIndex):
        // Find source tab containing this pane
        guard let sourceTab = tabForPane(paneId, in: model) else { return [] }
        guard let dstGroupIdx = model.groups.firstIndex(where: { $0.id == inGroupId }) else { return [] }

        let sourceHasOnlyThisPane: Bool = {
            if case .leaf(let p) = sourceTab.paneTree.root { return p.id == paneId } else { return false }
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
            var sourcePaneTree = sourceTab.paneTree
            guard let removal = sourcePaneTree.remove(paneId), !removal.emptiedTree else { return [] }

            // Update source tab
            updateTab(sourceTab.id, in: &model) { tab in
                tab.paneTree = sourcePaneTree
            }

            // Create new tab for the moved pane, carrying its full payload.
            let newTab = TabModel(
                id: TabId(rawValue: env.newId()),
                paneTree: PaneTree(root: .leaf(removal.pane))
            )
            let clamped = max(0, min(atIndex, model.groups[dstGroupIdx].tabs.count))
            model.groups[dstGroupIdx].tabs.insert(newTab, at: clamped)
            model.selectedTabId = newTab.id
        }

        if model.config.alertClearMode == .focus {
            markAlertsReadForPane(paneId, in: &model)
        }

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
        guard let targetId = paneId ?? selectedTab(in: model)?.paneTree.focusedPaneId,
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
        guard let targetId = paneId ?? selectedTab(in: model)?.paneTree.focusedPaneId,
              let pane = model.pane(targetId), pane.fontSizeSteps != 0 else { return [] }
        model.updatePane(targetId) { $0.fontSizeSteps = 0 }
        return []

    case .renameTab(let id, let name):
        let customTitle = name?.singleLineName
        updateTab(id, in: &model) { t in t.customTitle = customTitle }
        // The renamed row updates via reconcileSidebar (displayTitle is in the projection)
        // and the selected tab's window chrome via reconcileWindowChrome.
        return []

    case .sidebarRenameEnded:
        return []

    case .focusDirection(let direction, let side):
        guard let tab = selectedTab(in: model) else { return [] }
        if tab.paneTree.isZoomed {
            updateSelectedTab(&model) { $0.paneTree.unzoom() }
            return []
        }
        guard let target = nearestLeaf(
            tab.paneTree.root,
            from: tab.paneTree.focusedPaneId,
            direction: direction,
            side: side
        ) else { return [] }

        if model.config.alertClearMode == .focus {
            markAlertsReadForPane(target, in: &model)
        }
        updateSelectedTab(&model) { $0.paneTree.focus(target) }
        return []

    case .paneBecameFirstResponder(let paneId):
        guard let tab = selectedTab(in: model) else { return [] }
        // Only adopt a pane that actually lives in the selected tab. A stray
        // becomeFirstResponder from a hidden/background session must not
        // corrupt this tab's focusedPaneId or clear the foreign pane's alerts.
        guard allPaneIds(tab.paneTree.root).contains(paneId) else { return [] }
        if paneId != tab.paneTree.focusedPaneId {
            if model.config.alertClearMode == .focus {
                markAlertsReadForPane(paneId, in: &model)
            }
            updateSelectedTab(&model) { $0.paneTree.focus(paneId) }
        }
        model.searchState[paneId]?.focusOwner = .terminal

        return []

    case .searchFieldBecameFirstResponder(let paneId):
        guard let tab = selectedTab(in: model),
              tab.paneTree.focusedPaneId == paneId,
              model.searchState[paneId] != nil else { return [] }
        model.searchState[paneId]?.focusOwner = .field

        return []

    // MARK: - Session Lifecycles

    case .sessionReport(let sessionId, let report):
        guard report.isAdmitted,
              let mutation = model.updateSession(
                sessionId,
                { reduceSession(&$0, report: report) }
              )
        else { return [] }
        switch report {
        case .title, .cwd, .progress, .commandStarted, .agentAttached, .agentDetached:
            return []
        case .commandEnded:
            return []
        case .agentActivityChanged(_, .waiting):
            guard mutation.didChange else { return [] }
            guard selectedTab(in: model)?.paneTree.focusedPaneId != mutation.paneId else { return [] }
            return desktopAlertCommands(
                model: &model,
                paneId: mutation.paneId,
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
        if model.isAppActive, let tab = selectedTab(in: model), tab.paneTree.focusedPaneId == paneId {
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

    case .sessionProcessStarted(let sessionId):
        guard let paneId = model.pane(owning: sessionId)?.id else { return [] }
        model.updatePane(paneId) { pane in
            pane.session?.processPhase = .running
        }
        guard let pending = model.pendingSessionCreations.removeValue(forKey: sessionId) else {
            return []
        }
        return [.ipcReply(reqId: pending.requestId, result: pending.result)]

    case .sessionProcessExited(let sessionId), .sessionEnded(let sessionId):
        guard let paneId = model.pane(owning: sessionId)?.id else { return [] }
        return update(&model, .closePane(paneId: paneId), env: env)

    case .sessionCreationFailed(let sessionId):
        guard let paneId = model.pane(owning: sessionId)?.id else { return [] }
        // Session creation failure removes the whole containing tab, so every
        // sibling pane must be cleaned up as if the tab had been closed.
        for gi in model.groups.indices {
            if let ti = model.groups[gi].tabs.firstIndex(where: {
                allPaneIds($0.paneTree.root).contains(paneId)
            }) {
                let tab = model.groups[gi].tabs[ti]
                let tabId = tab.id
                let groupId = model.groups[gi].id
                var commands: [Command] = []
                for pid in allPaneIds(tab.paneTree.root) {
                    commands.append(contentsOf: rejectPendingCreation(
                        for: pid,
                        in: &model,
                        message: "pane process failed to start"
                    ))
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
                    return commands + [.terminate]
                }
                return commands
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
           let focusedPaneId = selectedTab(in: model)?.paneTree.focusedPaneId {
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
        return emitConfirmation(&model, subject: .app, env: env)

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

    case .toggleAlertsPopover:
        model.alertsPopoverOpen.toggle()
        return []

    case .alertsPopoverClosed:
        model.alertsPopoverOpen = false
        return []

    case .activateAlert(let alertId):
        model.alertsPopoverOpen = false
        guard let alert = model.alerts.first(where: { $0.id == alertId }) else { return [] }
        // Stale alert: pane no longer exists — just mark read, no navigation
        guard model.pane(alert.paneId) != nil else {
            if let idx = model.alerts.firstIndex(where: { $0.id == alertId }) {
                model.alerts[idx].isUnread = false
            }
            return []
        }
        // Mark read (unless manual mode — user must ack explicitly)
        if model.config.alertClearMode != .manual,
           let idx = model.alerts.firstIndex(where: { $0.id == alertId }) {
            model.alerts[idx].isUnread = false
        }
        var commands = navigateToPane(alert.paneId, in: &model, env: env)
        commands.append(.activateApp)
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
        let currentFocusedPaneId = currentTab.paneTree.focusedPaneId
        let currentPaneIds = Set(allPaneIds(currentTab.paneTree.root))
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

    case .confirmConfirmation(let id):
        return confirmPendingConfirmation(&model, id: id, env: env)

    case .cancelConfirmation(let id):
        guard model.pendingConfirmation?.id == id else { return [] }
        model.pendingConfirmation = nil
        return []

    case .chooseDeleteGroupConfirmation(let id, let moveTabs):
        return chooseDeleteGroupConfirmation(&model, id: id, moveTabs: moveTabs, env: env)

    case .terminate:
        return [.terminate]

    case .runtimeWillShutdown:
        let creationErrors = model.pendingSessionCreations.values.map {
            Command.ipcError(
                reqId: $0.requestId,
                code: -32603,
                message: "application shut down before the pane process started"
            )
        }
        let inputErrors = model.pendingInputRequests.keys.map {
            Command.ipcError(
                reqId: $0,
                code: -32603,
                message: "application shut down before pane input was delivered"
            )
        }
        model.pendingSessionCreations.removeAll()
        model.pendingInputRequests.removeAll()
        model.pendingInputSubmissions.removeAll()
        return creationErrors + inputErrors

    case .inputSubmissionCompleted(let submissionId, let result):
        guard let requestId = model.pendingInputSubmissions.removeValue(forKey: submissionId),
              var request = model.pendingInputRequests[requestId]
        else { return [] }
        request.remaining.remove(submissionId)
        switch result {
        case .delivered where request.remaining.isEmpty == false:
            model.pendingInputRequests[requestId] = request
            return []
        case .delivered:
            model.pendingInputRequests.removeValue(forKey: requestId)
            return [.ipcReply(reqId: requestId, result: .object(["ok": .bool(true)]))]
        case .rejected:
            model.pendingInputRequests.removeValue(forKey: requestId)
            for pendingId in request.remaining {
                model.pendingInputSubmissions.removeValue(forKey: pendingId)
            }
            return [.ipcError(
                reqId: requestId,
                code: -32603,
                message: "pane input was not delivered"
            )]
        }

    // MARK: - Group Management

    case .createGroup(let name, let launch, let background):
        let groupId = GroupId(rawValue: env.newId())
        let group = GroupModel(id: groupId, name: name)
        model.groups.append(group)
        return update(
            &model,
            .createTab(inGroupId: groupId, launch: launch, background: background),
            env: env
        )

    case .requestDeleteGroup(let id):
        return requestDeleteGroup(&model, id: id, env: env)

    case .deleteGroup(let id, let moveTabs):
        return deleteGroupBody(&model, id: id, moveTabs: moveTabs, env: env)

    case .renameGroup(let id, let name):
        guard let newName = name.singleLineName,
              let idx = model.groups.firstIndex(where: { $0.id == id }) else { return [] }
        model.groups[idx].name = newName
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
        if tab.paneTree.isZoomed {
            updateTab(tab.id, in: &model) { $0.paneTree.unzoom() }
            return []
        }
        if case .split = tab.paneTree.root {
            updateTab(tab.id, in: &model) { $0.paneTree.toggleZoom() }
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
            tab.paneTree.updateRatio(splitId: splitId, ratio: ratio)
        }
        return []

    // MARK: - Search

    case .startSearch:
        guard let tab = selectedTab(in: model) else { return [] }
        return [.sendStartSearch(paneId: tab.paneTree.focusedPaneId)]

    case .searchStarted(let paneId, let needle):
        if model.searchState[paneId] == nil {
            model.searchState[paneId] = SearchModel()
        }
        model.searchState[paneId]?.focusOwner = .field
        if !needle.isEmpty {
            model.searchState[paneId]?.needle = needle
        }
        return []

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
        return update(&model, .searchNavigate(paneId: tab.paneTree.focusedPaneId, direction: direction), env: env)

    case .endSearch(let paneId):
        guard model.searchState[paneId] != nil else { return [] }
        model.searchState.removeValue(forKey: paneId)
        // Clearing searchState drops the pane's key from the overlay projection, so
        // reconcilePaneChrome's `remove` tears the overlay down (no .hideSearchOverlay).
        return [.sendEndSearch(paneId: paneId)]

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

    case .toggleTodoPopover(let owner):
        guard model.todos(for: owner) != nil,
              todoPopoverAnchorIsEligible(owner, in: model)
        else { return [] }
        if model.todoPopover == owner {
            model.todoPopover = nil
            return []
        }
        model.todoPopover = owner
        return []

    case .todoPopoverClosed(let owner):
        if model.todoPopover == owner {
            model.todoPopover = nil
        }
        return []

    case .addTodo(let owner, let text):
        guard appendTodo(&model, owner: owner, text: text, id: TodoId(rawValue: env.newId())) != nil else { return [] }
        return []

    case .toggleTodoDone(let owner, let todoId):
        guard let todos = model.todos(for: owner),
              let idx = todos.firstIndex(where: { $0.id == todoId }) else { return [] }
        model.updateTodos(for: owner) { $0[idx].isDone.toggle() }
        return []

    case .setTodoDone(let owner, let todoId, let isDone):
        guard let todos = model.todos(for: owner),
              let idx = todos.firstIndex(where: { $0.id == todoId }),
              todos[idx].isDone != isDone else { return [] }
        model.updateTodos(for: owner) { $0[idx].isDone = isDone }
        return []

    case .editTodoText(let owner, let todoId, let text):
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let todos = model.todos(for: owner),
              let idx = todos.firstIndex(where: { $0.id == todoId }) else { return [] }
        model.updateTodos(for: owner) { $0[idx].text = trimmed }
        return []

    case .deleteTodo(let owner, let todoId):
        guard model.todos(for: owner) != nil else { return [] }
        model.updateTodos(for: owner) { $0.removeAll { $0.id == todoId } }
        return []

    case .reorderTodo(let owner, let todoId, let toIndex):
        guard let current = model.todos(for: owner),
              let todos = reorderedTodos(current, moving: todoId, to: toIndex) else { return [] }
        model.updateTodos(for: owner) { $0 = todos }
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
            model.updateTodos(for: .tab(tabId)) { $0.remove(at: sourceIndex) }
        case .pane(let paneId):
            model.updateTodos(for: .pane(paneId)) { $0.remove(at: sourceIndex) }
        }

        switch destination {
        case .tab(let tabId):
            model.updateTodos(for: .tab(tabId)) { $0.insert(sourceItem, at: insertAt) }
        case .pane(let paneId):
            model.updateTodos(for: .pane(paneId)) { $0.insert(sourceItem, at: insertAt) }
        }
        return []

    case .clearCompletedTodos(let owner):
        guard model.todos(for: owner) != nil else { return [] }
        model.updateTodos(for: owner) { $0.removeAll { $0.isDone } }
        return []

    case .requestClosePane(let paneId):
        guard model.pane(paneId) != nil else { return [] }
        // If this is the only pane in its tab, the close cascades into closeTab
        // (destroying tab todos + every pane's todos). Route through the
        // close-tab confirmation when the full rollup has any uncompleted item;
        // the rollup subsumes per-pane todos at the last-pane boundary, so
        // there's no double-prompt with the per-pane sheet.
        if let tab = tabForPane(paneId, in: model),
           allPaneIds(tab.paneTree.root).count == 1 {
            let subject = ConfirmationSubject.tab(tab.id)
            if closeImpact(for: subject, in: model)?.hasWarning == true {
                return emitConfirmation(
                    &model,
                    subject: subject,
                    quitAuthorized: totalTabCount(model) == 1,
                    env: env
                )
            }
            return update(&model, .closePane(paneId: paneId), env: env)
        }
        let subject = ConfirmationSubject.pane(paneId)
        if closeImpact(for: subject, in: model)?.hasWarning == true {
            return emitConfirmation(&model, subject: subject, env: env)
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

/// Commits or refreshes the one pending transaction against the live model.
private func confirmPendingConfirmation(
    _ model: inout AppModel,
    id: ConfirmationId,
    env: CoreEnv
) -> [Command] {
    guard let pending = model.pendingConfirmation, pending.id == id else { return [] }
    if case .deleteGroup = pending.subject { return [] }
    if pending.subject == .app {
        model.pendingConfirmation = nil
        return [.terminate]
    }

    if closeSubjectHasGrown(pending, in: model) {
        model.pendingConfirmation = nil
        switch pending.subject {
        case .pane(let paneId):
            return update(&model, .requestClosePane(paneId: paneId), env: env)
        case .tab(let tabId):
            return update(&model, .requestCloseTab(id: tabId), env: env)
        case .tabs(let tabIds):
            return update(&model, .requestCloseTabs(ids: tabIds), env: env)
        case .deleteGroup:
            return []
        case .app:
            return []
        }
    }

    model.pendingConfirmation = nil
    switch pending.subject {
    case .pane(let paneId):
        return closePaneBody(
            &model,
            paneId: paneId,
            quitAuthorized: pending.quitAuthorized,
            env: env
        )
    case .tab(let tabId):
        return closeTabBody(
            &model,
            id: tabId,
            quitAuthorized: pending.quitAuthorized,
            env: env
        )
    case .tabs(let tabIds):
        let normalized = normalizedLiveTabIds(tabIds, in: model)
        var commands: [Command] = []
        for tabId in normalized {
            commands.append(contentsOf: closeTabRemoval(&model, id: tabId))
        }
        guard model.hasAnyTab == false else { return commands }
        if pending.quitAuthorized {
            return commands + [.terminate]
        }
        return commands + emitConfirmation(&model, subject: .app, env: env)
    case .deleteGroup:
        return []
    case .app:
        return [.terminate]
    }
}

/// Applies one delete-group choice only while its frozen transaction is current.
private func chooseDeleteGroupConfirmation(
    _ model: inout AppModel,
    id: ConfirmationId,
    moveTabs: Bool,
    env: CoreEnv
) -> [Command] {
    guard let pending = model.pendingConfirmation,
          pending.id == id,
          case .deleteGroup(let groupId) = pending.subject,
          let frozen = pending.deleteGroup,
          let group = model.groups.first(where: { $0.id == groupId })
    else { return [] }

    let currentTabIds = group.tabs.map(\.id)
    let currentTabSet = Set(currentTabIds)
    let frozenTabSet = Set(frozen.tabIds)
    guard currentTabSet.isSubset(of: frozenTabSet),
          model.groups.contains(where: { $0.id == frozen.destinationGroupId })
    else {
        emitDeleteGroupConfirmation(&model, groupId: groupId, env: env)
        return []
    }

    model.pendingConfirmation = nil
    if moveTabs {
        guard let sourceIndex = model.groups.firstIndex(where: { $0.id == groupId }),
              let destinationIndex = model.groups.firstIndex(where: {
                $0.id == frozen.destinationGroupId
              })
        else { return [] }
        let tabs = model.groups[sourceIndex].tabs
        model.groups[destinationIndex].tabs.append(contentsOf: tabs)
        model.groups.remove(at: sourceIndex)
        return []
    }
    return deleteGroupBody(&model, id: groupId, moveTabs: false, env: env)
}

/// Applies delete-group request policy before any panel exists.
private func requestDeleteGroup(
    _ model: inout AppModel,
    id: GroupId,
    env: CoreEnv
) -> [Command] {
    guard let group = model.groups.first(where: { $0.id == id }),
          model.groups.count > 1
    else { return [] }
    if group.tabs.isEmpty {
        return deleteGroupBody(&model, id: id, moveTabs: false, env: env)
    }
    emitDeleteGroupConfirmation(&model, groupId: id, env: env)
    return []
}

/// Freezes the current delete-group choices into the shared transaction slot.
private func emitDeleteGroupConfirmation(
    _ model: inout AppModel,
    groupId: GroupId,
    env: CoreEnv
) {
    guard let groupIndex = model.groups.firstIndex(where: { $0.id == groupId }),
          model.groups.count > 1,
          model.groups[groupIndex].tabs.isEmpty == false,
          let destinationIndex = adjacentGroupIndex(
            deletingAt: groupIndex,
            count: model.groups.count
          )
    else {
        model.pendingConfirmation = nil
        return
    }
    model.pendingConfirmation = PendingConfirmation(
        id: ConfirmationId(rawValue: env.newId()),
        subject: .deleteGroup(groupId),
        tabTitle: nil,
        impact: nil,
        deleteGroup: DeleteGroupConfirmation(
            tabIds: model.groups[groupIndex].tabs.map(\.id),
            destinationGroupId: model.groups[destinationIndex].id
        ),
        quitAuthorized: false
    )
}

/// Executes the already-decided group deletion path used by IPC and confirmations.
private func deleteGroupBody(
    _ model: inout AppModel,
    id: GroupId,
    moveTabs: Bool,
    env: CoreEnv
) -> [Command] {
    guard let idx = model.groups.firstIndex(where: { $0.id == id }),
          model.groups.count > 1 else { return [] }

    let group = model.groups[idx]
    if moveTabs == false,
       group.tabs.isEmpty == false,
       totalTabCount(model) == group.tabs.count {
        return emitConfirmation(&model, subject: .app, env: env)
    }
    if moveTabs {
        guard let adjacentIndex = adjacentGroupIndex(
            deletingAt: idx,
            count: model.groups.count
        ) else { return [] }
        model.groups[adjacentIndex].tabs.append(contentsOf: group.tabs)
    } else {
        var commands: [Command] = []
        for tab in group.tabs {
            for paneId in allPaneIds(tab.paneTree.root) {
                commands.append(contentsOf: rejectPendingCreation(
                    for: paneId,
                    in: &model,
                    message: "pane closed before its process started"
                ))
                clearPaneSideTables(paneId, in: &model)
            }
        }
        model.groups.remove(at: idx)
        if model.hasAnyTab == false {
            return commands + [.terminate]
        }
        if let selectedTabId = model.selectedTabId,
           model.groups.flatMap(\.tabs).contains(where: { $0.id == selectedTabId }) == false {
            model.selectedTabId = model.groups.flatMap(\.tabs).first?.id
        }
        return commands
    }

    model.groups.remove(at: idx)
    return []
}

private func closeSubjectHasGrown(_ pending: PendingConfirmation, in model: AppModel) -> Bool {
    guard let snapshot = pending.impact,
          let current = closeImpact(for: pending.subject, in: model)
    else { return false }

    for pane in current.panes {
        guard let prior = snapshot.panes.first(where: { $0.paneId == pane.paneId }) else {
            return true
        }
        if let runningCommand = pane.runningCommand,
           prior.runningCommand != runningCommand {
            return true
        }
    }
    return false
}

/// Retracts or refreshes a transaction when its subject or frozen choices change.
private func reconcilePendingConfirmation(_ model: inout AppModel, env: CoreEnv) {
    guard let pending = model.pendingConfirmation else { return }
    switch pending.subject {
    case .pane(let paneId):
        if model.pane(paneId) == nil {
            model.pendingConfirmation = nil
        }
    case .tab(let tabId):
        if tabById(tabId, in: model) == nil {
            model.pendingConfirmation = nil
        }
    case .tabs(let tabIds):
        if tabIds.isEmpty || tabIds.contains(where: { tabById($0, in: model) == nil }) {
            model.pendingConfirmation = nil
        }
    case .deleteGroup(let groupId):
        guard let group = model.groups.first(where: { $0.id == groupId }),
              model.groups.count > 1
        else {
            model.pendingConfirmation = nil
            return
        }
        if group.tabs.isEmpty {
            model.groups.removeAll(where: { $0.id == groupId })
            model.pendingConfirmation = nil
        } else if let frozen = pending.deleteGroup,
                  model.groups.contains(where: { $0.id == frozen.destinationGroupId }) == false {
            emitDeleteGroupConfirmation(&model, groupId: groupId, env: env)
        }
    case .app:
        break
    }
}

private func closeTabBody(
    _ model: inout AppModel,
    id: TabId,
    quitAuthorized: Bool,
    env: CoreEnv
) -> [Command] {
    guard tabLocation(id, in: model) != nil else { return [] }
    if wouldQuitFromClose(model) {
        guard quitAuthorized else {
            return emitConfirmation(&model, subject: .app, env: env)
        }
        return closeTabRemoval(&model, id: id) + [.terminate]
    }
    let commands = closeTabRemoval(&model, id: id)
    if model.hasAnyTab == false {
        return commands + [.terminate]
    }
    return commands
}

private func closePaneBody(
    _ model: inout AppModel,
    paneId: PaneId,
    quitAuthorized: Bool,
    env: CoreEnv
) -> [Command] {
    // Resolve the pane's own tab because shell exits and stale menus can target
    // a background pane after selection has changed.
    guard let tab = tabForPane(paneId, in: model) else { return [] }
    var paneTree = tab.paneTree
    guard let removal = paneTree.remove(paneId) else { return [] }

    if removal.emptiedTree {
        if wouldQuitFromClose(model) {
            guard quitAuthorized else {
                return emitConfirmation(&model, subject: .app, env: env)
            }
            return closeTabRemoval(&model, id: tab.id) + [.terminate]
        }
        return closeTabRemoval(&model, id: tab.id)
    }

    let commands = rejectPendingCreation(
        for: paneId,
        in: &model,
        message: "pane closed before its process started"
    )
    clearPaneSideTables(paneId, in: &model)
    if model.todoPopover == .pane(paneId) {
        model.todoPopover = nil
    }

    if removal.focusMoved, model.config.alertClearMode == .focus,
       tab.id == model.selectedTabId {
        markAlertsReadForPane(paneTree.focusedPaneId, in: &model)
    }
    updateTab(tab.id, in: &model) { tab in
        tab.paneTree = paneTree
    }
    return commands
}

/// Pure todo reorder shared by the pane and tab handlers: removes `todoId` and
/// reinserts it at the clamped destination. Returns nil when the id is absent,
/// the index is out of range, or the item would not move -- so both callers can
/// `guard let` it and skip the checkpoint on a no-op.
func reorderedTodos(_ todos: [TodoItem], moving todoId: TodoId, to toIndex: Int) -> [TodoItem]? {
    guard let fromIndex = todos.firstIndex(where: { $0.id == todoId }),
          toIndex >= 0, toIndex <= todos.count else { return nil }
    let clampedTo = min(toIndex, todos.count - 1)
    guard fromIndex != clampedTo else { return nil }
    var result = todos
    let item = result.remove(at: fromIndex)
    result.insert(item, at: min(clampedTo, result.count))
    return result
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
        markAlertsReadForPane(tab.paneTree.focusedPaneId, in: &model)
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
func navigateToPane(
    _ paneId: PaneId,
    in model: inout AppModel,
    env: CoreEnv
) -> [Command] {
    guard let currentTab = tabForPane(paneId, in: model) else { return [] }
    let wasZoomed = currentTab.paneTree.isZoomed
    let oldFocusedPaneId = currentTab.paneTree.focusedPaneId
    let focusChanged = paneId != oldFocusedPaneId
    let commands = update(&model, .selectTab(id: currentTab.id), env: env)
    updateTab(currentTab.id, in: &model) { tab in
        tab.paneTree.focus(paneId)
    }
    if focusChanged && model.config.alertClearMode == .focus {
        markAlertsReadForPane(paneId, in: &model)
    }
    if wasZoomed, paneId != oldFocusedPaneId {
        updateSelectedTab(&model) { $0.paneTree.unzoom() }
    }
    // No popover clear on same-tab navigation: the anchor button and the visible
    // container stay intact, so nothing is stranded (consistent with
    // paneBecameFirstResponder). A cross-tab navigate clears via the nested selectTab;
    // an unzoom drifts the shape and clears via update()'s reconcileTodoPopover.
    return commands
}

private func updateSelectedTab(_ model: inout AppModel, _ body: (inout TabModel) -> Void) {
    guard let selId = model.selectedTabId else { return }
    updateTab(selId, in: &model, body)
}

private func updateTab(_ tabId: TabId, in model: inout AppModel, _ body: (inout TabModel) -> Void) {
    model.updateTab(tabId, body)
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
private func closeTabRemoval(_ model: inout AppModel, id: TabId) -> [Command] {
    guard let (groupIdx, tabIdx) = tabLocation(id, in: model) else { return [] }
    let tab = model.groups[groupIdx].tabs[tabIdx]
    let groupId = model.groups[groupIdx].id
    let paneIds = allPaneIds(tab.paneTree.root)

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
        commands.append(contentsOf: rejectPendingCreation(
            for: pid,
            in: &model,
            message: "pane closed before its process started"
        ))
        // Session teardown is reconcileSessionExistence's (these panes leave the tree
        // below); keep side-table cleanup + per-pane popover dismiss here.
        clearPaneSideTables(pid, in: &model)
        if model.todoPopover == .pane(pid) {
            model.todoPopover = nil
        }
    }
    // A tab-scoped popover dies with its owner; the existence pass closes it.
    if model.todoPopover == .tab(id) {
        model.todoPopover = nil
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

/// Removes and rejects the creation request owned by one pane, if it still waits on spawn.
private func rejectPendingCreation(
    for paneId: PaneId,
    in model: inout AppModel,
    message: String
) -> [Command] {
    guard let sessionId = model.pane(paneId)?.session?.id,
          let pending = model.pendingSessionCreations.removeValue(forKey: sessionId)
    else { return [] }
    return [.ipcError(reqId: pending.requestId, code: -32603, message: message)]
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
    if model.isAppActive, let tab = selectedTab(in: model), tab.paneTree.focusedPaneId == paneId {
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
    title: DisplayLine, subtitle: DisplayLine?, body: String, model: inout AppModel, now: Date
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
