import Cocoa
import GhosttyKit
import UniformTypeIdentifiers
import UserNotifications

// App runtime owns the mutable app model, performs side effects emitted by the
// pure update function, and bridges model changes into AppKit/Ghostty objects.
class AppRuntime {
    private struct StagedRestoreSession {
        let model: AppModel
        let surfaces: [PaneId: TerminalView]
        let tokenStore: PaneTokenStore
        let replayFiles: [PaneId: URL]
    }

    var model: AppModel
    let ghosttyApp: GhosttyApp
    var surfaces: [PaneId: TerminalView] = [:]
    var tokenStore = PaneTokenStore()
    weak var window: NSWindow?
    weak var sidebarView: SidebarView?
    weak var contentArea: NSView?
    weak var chromeView: WindowChromeView?
    var alertsPopover: NSPopover?
    private var dragCoordinator: PaneDragCoordinator?
    private var replayFiles: [PaneId: URL] = [:]
    private static let replayDirectoryName = "danterm-scrollback"
    // Session persistence uses two tiers of checkpoints:
    //   Light  — pure model serialization (no scrollback), written after a 2s debounce
    //            following any state-mutating Msg. Cheap and frequent.
    //   Enriched — model + scrollback text read from live Ghostty surfaces, written on
    //              a 60s repeating timer and once at clean termination. Expensive but
    //              gives full restore fidelity including terminal history.
    private var checkpointTimer: DispatchSourceTimer?          // debounce timer for light checkpoints
    private var enrichedCheckpointTimer: DispatchSourceTimer?  // repeating timer for enriched checkpoints
    private var checkpointPending = false                      // true while a debounced write is scheduled
    private static let checkpointDebounceInterval: TimeInterval = 2.0
    private static let enrichedCheckpointInterval: TimeInterval = 60.0

    init(ghosttyApp: GhosttyApp) {
        self.ghosttyApp = ghosttyApp
        self.model = AppModel(
            groups: [GroupModel(id: GroupId(), name: "General", isDefault: true)],
            panes: [:]
        )
    }

    func send(_ msg: Msg) {
        guard let translatedMsg = translateMsg(msg, tokenForPane: { self.tokenStore.token(for: $0) }) else { return }

        let oldUnreadCount = totalUnreadAlertCount(model: model)
        let effects = update(&model, translatedMsg)
        for effect in effects {
            perform(effect)
        }
        let newUnreadCount = totalUnreadAlertCount(model: model)
        if newUnreadCount != oldUnreadCount {
            perform(.updateDockBadge(newUnreadCount))
            perform(.updateToolbarBellBadge(newUnreadCount))
        }

        // Defensive backstop: cancel drag on app resign, in case the coordinator's
        // notification observer fires out of order.
        if case .appResignedActive = translatedMsg {
            cancelPaneDrag()
            // Flush pending light checkpoint so we don't lose state if the app
            // is killed while backgrounded (e.g. memory pressure, force quit).
            flushPendingCheckpoint()
        }

        // Refresh toolbar text after title/cwd/progress changes
        switch translatedMsg {
        case .surfaceTitle(let paneId, _), .surfaceCwd(let paneId, _), .surfaceProgress(let paneId, _):
            refreshPaneToolbar(for: paneId)
        default:
            break
        }
    }

    func terminalView(for paneId: PaneId) -> TerminalView? {
        return surfaces[paneId]
    }

    // MARK: - Effect Performer

    private func perform(_ effect: Effect) {
        switch effect {
        case .createSurface(let paneId, let cwd, let command):
            let token = tokenStore.generate(for: paneId)
            let view = makeTerminalView(
                paneId: paneId,
                workingDirectory: cwd,
                command: command,
                restoreCommandBehavior: .execute,
                envVars: [("DANTERM_TOKEN", token)]
            )
            surfaces[paneId] = view
            if view.surface == nil {
                send(.surfaceCreationFailed(paneId: paneId))
            }

        case .destroySurface(let paneId):
            tokenStore.remove(paneId)
            cleanupReplayFile(for: paneId)
            if let view = surfaces.removeValue(forKey: paneId) {
                view.closeSurface()
            }

        case .focusSurface(let paneId, let focused):
            if let view = surfaces[paneId], let surface = view.surface {
                ghostty_surface_set_focus(surface, focused)
            }

        case .makeFirstResponder(let paneId):
            if let view = surfaces[paneId] {
                window?.makeFirstResponder(view)
            }

        case .rebuildContentView:
            rebuildContentView()

        case .reloadSidebar:
            sidebarView?.reload(model: model)

        case .reloadSidebarRow(let tabId):
            sidebarView?.reloadRow(tabId: tabId, model: model)

        case .reloadSidebarGroupRow(let groupId):
            sidebarView?.reloadGroupRow(groupId: groupId, model: model)

        case .setWindowTitle(let title):
            window?.title = title
            refreshContentTitlebar()

        case .sendNotification(let alertId, let title, let body, let tabId, let paneId):
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = [
                "alertId": alertId.rawValue.uuidString,
                "tabId": tabId.rawValue.uuidString,
                "paneId": paneId.rawValue.uuidString,
            ]
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            enqueueNotificationRequest(request)

        case .exportState(let snapshot):
            // Enrich pane snapshots with scrollback from live surfaces
            let enrichedPanes: [PaneSnapshot] = snapshot.panes.map { ps in
                guard let idStr = ps.id,
                      let uuid = UUID(uuidString: idStr),
                      let view = surfaces[PaneId(rawValue: uuid)],
                      let surface = view.surface,
                      let rawText = readScrollbackText(surface: surface),
                      let scrollback = truncateScrollback(rawText) else {
                    return ps
                }
                return PaneSnapshot(
                    id: ps.id, title: ps.title, cwd: ps.cwd,
                    launch: ps.launch, scrollback: scrollback
                )
            }
            let enrichedSnapshot = AppModelSnapshot(
                groups: snapshot.groups,
                panes: enrichedPanes,
                selectedTabId: snapshot.selectedTabId
            )
            let initFile = AppInitFile(version: 1, model: enrichedSnapshot)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data: Data
            do {
                data = try encoder.encode(initFile)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Export Failed"
                alert.informativeText = "Failed to encode state: \(error.localizedDescription)"
                alert.runModal()
                return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "danterm-state.json"
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            guard let window = window else { return }
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url)
                } catch {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "Save Failed"
                        alert.informativeText = error.localizedDescription
                        alert.runModal()
                    }
                }
            }

        case .showCloseTabConfirmation(let tabId, let tabTitle, let paneCount, let isLastTab):
            let alert = NSAlert()
            alert.messageText = "Close tab \"\(tabTitle)\"?"
            if isLastTab {
                alert.informativeText = "This tab has \(paneCount) terminal panes. Closing it will quit DanTerm."
            } else {
                alert.informativeText = "This tab has \(paneCount) terminal panes."
            }
            alert.addButton(withTitle: "Close Tab")
            alert.addButton(withTitle: "Cancel")
            if let window = window {
                alert.beginSheetModal(for: window) { [weak self] response in
                    if response == .alertFirstButtonReturn {
                        self?.send(.closeTab(id: tabId))
                    }
                }
            } else {
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    self.send(.closeTab(id: tabId))
                }
            }

        case .showTerminateConfirmation:
            let alert = NSAlert()
            alert.messageText = "Quit DanTerm?"
            alert.informativeText = "Closing the last pane will quit the application."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                self.send(.confirmTerminate)
            } else {
                self.send(.cancelTerminate)
            }

        case .scheduleCheckpoint:
            scheduleDebouncedCheckpoint()

        case .terminate:
            checkpointTimer?.cancel()
            checkpointTimer = nil
            enrichedCheckpointTimer?.cancel()
            enrichedCheckpointTimer = nil
            for paneId in replayFiles.keys {
                cleanupReplayFile(for: paneId)
            }
            NSApp.terminate(nil)

        case .activateApp:
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)

        case .setAppFocus(let focused):
            if let app = ghosttyApp.app {
                ghostty_app_set_focus(app, focused)
            }

        case .dismissAlertsPopover:
            alertsPopover?.performClose(nil)
            alertsPopover = nil

        case .updateToolbarBellBadge(let count):
            chromeView?.updateBellBadge(count: count)

        case .updateDockBadge(let count):
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
            NSApp.dockTile.display()
        }
    }

    // Deliver notifications only after checking authorization state so the
    // first real alert can recover if the launch-time prompt was skipped.
    private func enqueueNotificationRequest(_ request: UNNotificationRequest) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                center.add(request) { error in
                    if let error {
                        print("Failed to enqueue notification: \(error)")
                    }
                }
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        print("Notification authorization request failed: \(error)")
                        return
                    }
                    guard granted else { return }
                    center.add(request) { error in
                        if let error {
                            print("Failed to enqueue notification: \(error)")
                        }
                    }
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    // MARK: - Scrollback Replay Files

    /// Read full scrollback text from a ghostty surface using line-based selection.
    private func readScrollbackText(surface: ghostty_surface_t) -> String? {
        let topLeft = ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        let bottomRight = ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        let selection = ghostty_selection_s(top_left: topLeft, bottom_right: bottomRight, rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return nil }
        let len = Int(text.text_len)
        return ptr.withMemoryRebound(to: UInt8.self, capacity: len) { reboundPtr in
            String(bytes: UnsafeBufferPointer(start: reboundPtr, count: len), encoding: .utf8)
        }
    }

    /// Write scrollback text to a temp file for shell replay. Returns the file URL.
    private func writeReplayFile(scrollback: String) -> URL? {
        guard let data = scrollback.data(using: .utf8) else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.replayDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("txt")
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return nil }
        return fileURL
    }

    /// Delete the replay file for a pane if one exists.
    private func cleanupReplayFile(for paneId: PaneId) {
        if let url = replayFiles.removeValue(forKey: paneId) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Delete all files in $TMPDIR/danterm-scrollback/ from prior sessions.
    func cleanupStaleReplayDirectory() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.replayDirectoryName, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Session Checkpointing

    /// Schedule a light checkpoint after a debounce delay. Each call resets the
    /// timer so rapid-fire model changes (e.g. dragging a split divider) coalesce
    /// into a single disk write.
    private func scheduleDebouncedCheckpoint() {
        checkpointTimer?.cancel()
        checkpointPending = true
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.checkpointDebounceInterval)
        timer.setEventHandler { [weak self] in
            self?.performLightCheckpoint()
        }
        timer.resume()
        checkpointTimer = timer
    }

    /// Flush a pending debounced checkpoint immediately. Called on appResignedActive
    /// so we don't lose the last 2s of state changes when the user switches away.
    func flushPendingCheckpoint() {
        guard checkpointPending else { return }
        checkpointTimer?.cancel()
        checkpointTimer = nil
        performLightCheckpoint()
    }

    /// Start a repeating 60s timer that writes enriched checkpoints (model +
    /// scrollback from live surfaces). Called once from applicationDidFinishLaunching.
    func startEnrichedCheckpointTimer() {
        enrichedCheckpointTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.enrichedCheckpointInterval, repeating: Self.enrichedCheckpointInterval)
        timer.setEventHandler { [weak self] in
            self?.performEnrichedCheckpoint()
        }
        timer.resume()
        enrichedCheckpointTimer = timer
    }

    /// Write a light checkpoint: pure model serialization with scrollback: nil.
    /// Cheap — no Ghostty surface interaction.
    private func performLightCheckpoint() {
        checkpointPending = false
        let initFile = toInitFile(model)
        writeCheckpoint(initFile)
    }

    /// Write an enriched checkpoint: model snapshot + scrollback text read from
    /// each live Ghostty surface. Expensive but gives full restore fidelity.
    /// Called by the 60s periodic timer and once at clean termination.
    func performEnrichedCheckpoint() {
        let snapshot = toSnapshot(model)
        let enrichedPanes: [PaneSnapshot] = snapshot.panes.map { ps in
            guard let idStr = ps.id,
                  let uuid = UUID(uuidString: idStr),
                  let view = surfaces[PaneId(rawValue: uuid)],
                  let surface = view.surface,
                  let rawText = readScrollbackText(surface: surface),
                  let scrollback = truncateScrollback(rawText) else {
                return ps
            }
            return PaneSnapshot(
                id: ps.id, title: ps.title, cwd: ps.cwd,
                launch: ps.launch, scrollback: scrollback
            )
        }
        let enrichedSnapshot = AppModelSnapshot(
            groups: snapshot.groups,
            panes: enrichedPanes,
            selectedTabId: snapshot.selectedTabId
        )
        writeCheckpoint(AppInitFile(version: 1, model: enrichedSnapshot))
    }

    /// Encode and atomically write a checkpoint to Recovery/last.json.
    /// Uses .sortedKeys for stable output (no .prettyPrinted — this is a machine file).
    private func writeCheckpoint(_ initFile: AppInitFile) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(initFile) else { return }
        let dir = recoveryDirectoryURL()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: recoveryCheckpointURL(), options: .atomic)
    }

    // MARK: - State Import

    /// Present a file picker, validate the chosen state file, and replace the current session.
    func importStateFromPanel(restoreCommandBehavior: RestoreCommandBehavior = .prefill) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.importState(from: url, restoreCommandBehavior: restoreCommandBehavior)
        }
    }

    /// Load a state file from disk, keeping the current session intact on any validation failure.
    func importState(from url: URL, restoreCommandBehavior: RestoreCommandBehavior = .prefill) {
        do {
            let data = try Data(contentsOf: url)
            let loaded = try loadValidatedInitFile(from: data)
            do {
                let staged = try stageValidatedRestore(loaded, restoreCommandBehavior: restoreCommandBehavior)
                commitRestoreSession(staged)
            } catch {
                showImportError(message: "Import failed while creating terminal surfaces.")
            }
        } catch let error as AppInitFileLoadError {
            showImportError(message: importErrorMessage(for: error))
        } catch {
            showImportError(message: error.localizedDescription)
        }
    }

    // MARK: - Pane Drag

    func startPaneDrag(paneId: PaneId) {
        cancelPaneDrag()
        guard let contentArea = contentArea else { return }
        guard let tab = selectedTab(in: model) else { return }

        let targetIds = allPaneIds(tab.rootNode).filter { $0 != paneId }

        // Build pane frame provider: converts PaneWrapperView frames to window coordinates
        let provider: (PaneId) -> NSRect? = { [weak self] targetPaneId in
            guard let self = self, let contentArea = self.contentArea else { return nil }
            guard let wrapper = self.findPaneWrapper(for: targetPaneId, in: contentArea) else { return nil }
            return wrapper.convert(wrapper.bounds, to: nil)
        }

        let coordinator = PaneDragCoordinator(
            sourcePaneId: paneId,
            contentView: contentArea,
            paneFrameProvider: provider,
            targetPaneIds: targetIds
        )
        dragCoordinator = coordinator
    }

    /// Convert a screen point to window coordinates and update the drag overlay.
    func updatePaneDrag(screenPoint: NSPoint) {
        guard let window = window else { return }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        dragCoordinator?.updateDrag(locationInWindow: windowPoint)
    }

    /// Return current pane-area drop if one is active (for use by NSDraggingSource endedAt).
    func currentPaneDrop() -> (source: PaneId, target: PaneId, intent: PaneDropIntent)? {
        return dragCoordinator?.currentDrop()
    }

    /// Tear down the drag coordinator overlay. Called after the NSDraggingSession ends.
    func endPaneDrag() {
        cancelPaneDrag()
    }

    func cancelPaneDrag() {
        guard dragCoordinator != nil else { return }
        dragCoordinator?.teardown()
        dragCoordinator = nil
    }

    // MARK: - Snapshot Bootstrap

    func bootstrapFromSnapshot(_ snapshot: AppModelSnapshot, restoreCommandBehavior: RestoreCommandBehavior = .prefill) {
        guard let built = validateAndBuildDetailed(snapshot) else {
            print("[init] Snapshot validation failed, falling back to default startup")
            send(.createTab(inGroupId: nil))
            return
        }
        let loaded = ValidatedAppRestore(snapshot: snapshot, model: built.model, paneSnapshots: built.paneSnapshots)
        do {
            let staged = try stageValidatedRestore(loaded, restoreCommandBehavior: restoreCommandBehavior)
            commitRestoreSession(staged)
        } catch {
            print("[init] Snapshot surface creation failed, falling back to default startup")
            send(.createTab(inGroupId: nil))
        }
    }

    /// Build all runtime objects for a validated restore without touching the live session.
    private func stageValidatedRestore(
        _ loaded: ValidatedAppRestore,
        restoreCommandBehavior: RestoreCommandBehavior
    ) throws -> StagedRestoreSession {
        var stagedSurfaces: [PaneId: TerminalView] = [:]
        var stagedTokenStore = PaneTokenStore()
        var stagedReplayFiles: [PaneId: URL] = [:]

        do {
            for group in loaded.model.groups {
                for tab in group.tabs {
                    for paneId in allPaneIds(tab.rootNode) {
                        let ps = loaded.paneSnapshots[paneId]
                        let resolved = ps.map { resolveLaunch($0) }
                        let token = stagedTokenStore.generate(for: paneId)
                        var envVars: [(String, String)] = [("DANTERM_TOKEN", token)]
                        if let scrollback = ps?.scrollback,
                           let replayURL = writeReplayFile(scrollback: scrollback) {
                            stagedReplayFiles[paneId] = replayURL
                            envVars.append(("DANTERM_RESTORE_SCROLLBACK_FILE", replayURL.path))
                        }
                        let view = makeTerminalView(
                            paneId: paneId,
                            workingDirectory: resolved?.cwd,
                            command: resolved?.command,
                            restoreCommandBehavior: restoreCommandBehavior,
                            envVars: envVars
                        )
                        stagedSurfaces[paneId] = view
                        if view.surface == nil {
                            throw RestoreBuildError.surfaceCreationFailed
                        }
                    }
                }
            }

            return StagedRestoreSession(
                model: loaded.model,
                surfaces: stagedSurfaces,
                tokenStore: stagedTokenStore,
                replayFiles: stagedReplayFiles
            )
        } catch {
            discardRestoreSession(StagedRestoreSession(
                model: loaded.model,
                surfaces: stagedSurfaces,
                tokenStore: stagedTokenStore,
                replayFiles: stagedReplayFiles
            ))
            throw error
        }
    }

    /// Tear down live runtime resources before swapping in a replacement session.
    private func tearDownCurrentSession() {
        cancelPaneDrag()
        alertsPopover?.performClose(nil)
        alertsPopover = nil

        for paneId in Array(surfaces.keys) {
            cleanupReplayFile(for: paneId)
            if let view = surfaces.removeValue(forKey: paneId) {
                view.closeSurface()
            }
        }
        for paneId in Array(replayFiles.keys) {
            cleanupReplayFile(for: paneId)
        }
        tokenStore = PaneTokenStore()
    }

    /// Swap a fully staged restore into the live runtime and refresh derived UI state.
    private func commitRestoreSession(_ staged: StagedRestoreSession) {
        tearDownCurrentSession()
        model = staged.model
        surfaces = staged.surfaces
        tokenStore = staged.tokenStore
        replayFiles = staged.replayFiles

        refreshContentTitlebar()
        rebuildContentView()
        sidebarView?.reload(model: model)
        let unreadCount = totalUnreadAlertCount(model: model)
        chromeView?.updateBellBadge(count: unreadCount)
        NSApp.dockTile.badgeLabel = unreadCount > 0 ? "\(unreadCount)" : nil
        NSApp.dockTile.display()
    }

    /// Dispose of a staged restore after a failed build so no temp state leaks into the live session.
    private func discardRestoreSession(_ staged: StagedRestoreSession) {
        for (_, view) in staged.surfaces {
            view.closeSurface()
        }
        for url in staged.replayFiles.values {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Construct a terminal view and attach DanTerm runtime metadata before first use.
    private func makeTerminalView(
        paneId: PaneId,
        workingDirectory: String?,
        command: String?,
        restoreCommandBehavior: RestoreCommandBehavior,
        envVars: [(String, String)]
    ) -> TerminalView {
        let view = TerminalView(
            ghosttyApp: ghosttyApp,
            workingDirectory: workingDirectory,
            command: command,
            restoreCommandBehavior: restoreCommandBehavior,
            envVars: envVars
        )
        view.bridge.paneId = paneId
        view.runtime = self
        return view
    }

    private func importErrorMessage(for error: AppInitFileLoadError) -> String {
        switch error {
        case .decodeFailed:
            return "The selected file is not valid DanTerm JSON."
        case .unsupportedVersion(let version):
            return "Unsupported state file version: \(version)."
        case .invalidSnapshot:
            return "The selected state file failed snapshot validation."
        }
    }

    private func showImportError(message: String) {
        let presentAlert = {
            let alert = NSAlert()
            alert.messageText = "Import Failed"
            alert.informativeText = message
            alert.runModal()
        }
        if Thread.isMainThread {
            presentAlert()
        } else {
            DispatchQueue.main.async(execute: presentAlert)
        }
    }

    // MARK: - Content Titlebar

    /// Update the window chrome title with the selected tab's display title.
    /// Called from .setWindowTitle effect (emitted on tab select, rename, title/cwd changes).
    func refreshContentTitlebar() {
        guard let tab = selectedTab(in: model) else {
            chromeView?.updateTitle("")
            return
        }
        chromeView?.updateTitle(tab.displayTitle)
    }

    // MARK: - Pane Toolbars

    func refreshPaneToolbars() {
        guard let contentArea = contentArea else { return }
        forEachPaneWrapper(in: contentArea) { wrapper in
            let (title, cwd) = paneToolbarText(for: wrapper.paneId, in: model)
            let progress = model.panes[wrapper.paneId]?.progress
            wrapper.updateToolbar(title: title, cwd: cwd, progress: progress)
        }
    }

    private func refreshPaneToolbar(for paneId: PaneId) {
        guard let contentArea = contentArea else { return }
        let (title, cwd) = paneToolbarText(for: paneId, in: model)
        let progress = model.panes[paneId]?.progress
        findPaneWrapper(for: paneId, in: contentArea)?.updateToolbar(title: title, cwd: cwd, progress: progress)
    }

    private func findPaneWrapper(for paneId: PaneId, in view: NSView) -> PaneWrapperView? {
        for sub in view.subviews {
            if let wrapper = sub as? PaneWrapperView {
                if wrapper.paneId == paneId { return wrapper }
            } else if let found = findPaneWrapper(for: paneId, in: sub) {
                return found
            }
        }
        return nil
    }

    private func forEachPaneWrapper(in view: NSView, _ body: (PaneWrapperView) -> Void) {
        for sub in view.subviews {
            if let wrapper = sub as? PaneWrapperView {
                body(wrapper)
            } else {
                forEachPaneWrapper(in: sub, body)
            }
        }
    }

    // MARK: - View Building

    private func rebuildContentView() {
        cancelPaneDrag()
        guard let contentArea = contentArea else { return }

        // Remove old content
        for subview in contentArea.subviews {
            subview.removeFromSuperview()
        }

        guard let tab = selectedTab(in: model) else { return }

        let displayNode: SplitNodeModel
        if tab.isZoomed {
            displayNode = .leaf(tab.focusedPaneId)
        } else {
            displayNode = tab.rootNode
        }

        // Defocus all surfaces before rebuilding
        for paneId in allPaneIds(tab.rootNode) {
            if let view = surfaces[paneId], let surface = view.surface {
                ghostty_surface_set_focus(surface, false)
            }
        }

        let container = SplitContainerView(
            rootNode: displayNode,
            surfaceLookup: { [weak self] paneId in self?.surfaces[paneId] },
            runtime: self,
            isZoomed: tab.isZoomed,
            hasSplits: { if case .leaf = tab.rootNode { return false } else { return true } }(),
            frame: contentArea.bounds
        )
        container.autoresizingMask = [.width, .height]
        contentArea.addSubview(container)
        container.rebuild()

        // Set focus borders based on model state (skip green border for single-pane tabs)
        let focusedId = tab.focusedPaneId
        let isSinglePane: Bool = { if case .leaf = tab.rootNode { return true } else { return false } }()
        for paneId in allPaneIds(displayNode) {
            let isFocused = !isSinglePane && paneId == focusedId
            let hasBell = paneHasUnreadAlert(paneId, alerts: model.alerts)
            surfaces[paneId]?.setFocusBorder(isFocused, hasBell: hasBell)
        }

        // Focus the right pane
        if let focusedView = surfaces[focusedId] {
            window?.makeFirstResponder(focusedView)
        }

        refreshPaneToolbars()
        refreshContentTitlebar()
    }

    // MARK: - Alerts Popover

    func toggleAlertsPopover() {
        if let popover = alertsPopover, popover.isShown {
            popover.performClose(nil)
            alertsPopover = nil
            return
        }
        guard let anchor = chromeView?.bellButton else { return }
        let vc = AlertsPopoverViewController()
        vc.runtime = self
        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        alertsPopover = popover
    }
}

private enum RestoreBuildError: Error {
    case surfaceCreationFailed
}
