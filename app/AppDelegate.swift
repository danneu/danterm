// App delegate responsible for window setup, app lifecycle hooks, menus, and
// notification center delegation.
import Cocoa
import GhosttyKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSSplitViewDelegate, UNUserNotificationCenterDelegate {
    static let minWindowWidth: CGFloat = 600
    static let minWindowHeight: CGFloat = 300
    static let minSidebarWidth: CGFloat = 200

    var window: NSWindow!
    var ghosttyApp: GhosttyApp!
    var runtime: AppRuntime!
    var sidebarView: SidebarView!
    var contentArea: NSView!
    var splitView: NSSplitView!
    var chromeView: WindowChromeView!
    var initSnapshot: AppModelSnapshot?
    var restoreCommandBehavior: RestoreCommandBehavior = .prefill
    // Session recovery state set by main.swift before app launch.
    var lastSessionSnapshot: AppModelSnapshot?  // merged from Recovery/last-light.json + last-enriched.json
    var previousSessionCrashed: Bool = false     // true if session.json lock was still present
    /// Set by the .terminate effect before calling NSApp.terminate to bypass the
    /// applicationShouldTerminate safety net (user already confirmed).
    var quitConfirmed = false

    // NSApplicationDelegate: finish bootstrapping the Ghostty runtime, main
    // window, and launch-time services once AppKit has started the app.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create ghostty app (config + runtime callbacks)
        ghosttyApp = GhosttyApp()
        guard ghosttyApp.app != nil else {
            print("Failed to create GhosttyApp")
            NSApp.terminate(nil)
            return
        }

        // Create runtime
        runtime = AppRuntime(ghosttyApp: ghosttyApp)
        ghosttyApp.runtime = runtime

        // Build menu bar
        buildMenu()

        // Create window with transparent titlebar
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "DanTerm"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: Self.minWindowWidth, height: Self.minWindowHeight)
        window.center()
        window.delegate = self
        window.setFrameAutosaveName("MainWindow")

        // Custom chrome view (replaces NSToolbar)
        chromeView = WindowChromeView()
        chromeView.toggleButton.target = self
        chromeView.toggleButton.action = #selector(toggleSidebar(_:))
        chromeView.bellButton.target = self
        chromeView.bellButton.action = #selector(toggleAlerts(_:))
        chromeView.addTabButton.target = self
        chromeView.addTabButton.action = #selector(newTab(_:))
        chromeView.addGroupButton.target = self
        chromeView.addGroupButton.action = #selector(newGroup(_:))

        // Create split view (sidebar | content)
        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false

        // Sidebar
        sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: Self.minSidebarWidth, height: 600))
        sidebarView.runtime = runtime

        // Content area
        contentArea = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        splitView.addArrangedSubview(sidebarView)
        splitView.addArrangedSubview(contentArea)

        // Sidebar holds its width; content area stretches
        sidebarView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        contentArea.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Root container: chrome view on top, split view below
        let rootView = NSView()
        rootView.addSubview(chromeView)
        rootView.addSubview(splitView)

        NSLayoutConstraint.activate([
            chromeView.topAnchor.constraint(equalTo: rootView.topAnchor),
            chromeView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            chromeView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),

            splitView.topAnchor.constraint(equalTo: chromeView.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])

        window.contentView = rootView
        window.makeKeyAndOrderFront(nil)

        // Set divider position after window is visible
        splitView.setPosition(Self.minSidebarWidth, ofDividerAt: 0)
        chromeView.syncWithSidebarState(collapsed: false, sidebarWidth: Self.minSidebarWidth)

        // Wire runtime to views
        runtime.window = window
        runtime.sidebarView = sidebarView
        runtime.contentArea = contentArea
        runtime.chromeView = chromeView

        // Write session lock (crash detection for next launch). Atomically
        // overwrites any stale lock from a previous crash, so there's no window
        // where a startup crash would lose the lock.
        writeSessionLockFile()

        // Start periodic enriched checkpoints (scrollback capture)
        runtime.startEnrichedCheckpointTimer()

        // Clean up stale replay files from prior sessions
        runtime.cleanupStaleReplayDirectory()

        // Bootstrap startup: --init CLI > crash/clean restore prompt > fresh
        if let snapshot = initSnapshot {
            runtime.bootstrapFromSnapshot(snapshot, restoreCommandBehavior: restoreCommandBehavior)
            initSnapshot = nil
        } else if let lastSession = lastSessionSnapshot {
            // Prompt the user before restoring so they know what's coming.
            // Crash path gets a warning tone; clean exit is a neutral prompt.
            let summary = sessionSummary(lastSession)
            let alert = NSAlert()
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "Start Fresh")
            if previousSessionCrashed {
                alert.messageText = "Restore Previous Session?"
                alert.informativeText = "DanTerm did not exit cleanly last time.\n\(summary)"
                alert.alertStyle = .warning
            } else {
                alert.messageText = "Restore Previous Session?"
                alert.informativeText = summary
            }
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                runtime.bootstrapFromSnapshot(lastSession, restoreCommandBehavior: .prefill)
            } else {
                runtime.send(.createTab(inGroupId: nil))
            }
            lastSessionSnapshot = nil
        } else {
            runtime.send(.createTab(inGroupId: nil))
        }

        // Set up notification center
        let notifCenter = UNUserNotificationCenter.current()
        notifCenter.delegate = self

        NSApp.activate(ignoringOtherApps: true)

        // Request notification authorization after the app is active so the
        // system prompt is not racing the initial launch and window setup.
        DispatchQueue.main.async { [weak self] in
            self?.requestNotificationAuthorizationIfNeeded()
        }

    }

    /// Build a human-readable summary like "12 tabs in 3 groups" for the restore prompt.
    private func sessionSummary(_ snapshot: AppModelSnapshot) -> String {
        let tabCount = snapshot.groups.flatMap(\.tabs).count
        let groupCount = snapshot.groups.count
        let tabs = tabCount == 1 ? "1 tab" : "\(tabCount) tabs"
        let groups = groupCount == 1 ? "1 group" : "\(groupCount) groups"
        return "\(tabs) in \(groups)"
    }

    private func requestNotificationAuthorizationIfNeeded() {
        let notifCenter = UNUserNotificationCenter.current()
        notifCenter.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            notifCenter.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error {
                    print("Notification authorization request failed: \(error)")
                    return
                }
                print("Notification authorization granted: \(granted)")
            }
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About DanTerm", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Import State...", action: #selector(importState(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Export State...", action: #selector(exportState(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Preferences...", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Open DanTerm Config", action: #selector(openDanTermConfig(_:)), keyEquivalent: "")
        let openGhosttyItem = NSMenuItem(title: "Open Ghostty Config", action: #selector(openGhosttyConfig(_:)), keyEquivalent: ",")
        openGhosttyItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(openGhosttyItem)
        let reloadConfigItem = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig(_:)), keyEquivalent: ",")
        reloadConfigItem.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(reloadConfigItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit DanTerm", action: #selector(quitApp(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Find", action: #selector(findInTerminal(_:)), keyEquivalent: "f")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let toggleThemeItem = NSMenuItem(title: "Toggle Theme Panel", action: #selector(toggleThemePanel(_:)), keyEquivalent: "T")
        toggleThemeItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(toggleThemeItem)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Tab menu
        let tabMenuItem = NSMenuItem()
        let tabMenu = NSMenu(title: "Tab")
        tabMenu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        tabMenu.addItem(withTitle: "New Group", action: #selector(newGroup(_:)), keyEquivalent: "n")

        let renameTabItem = NSMenuItem(title: "Rename Tab", action: #selector(renameTab(_:)), keyEquivalent: "R")
        renameTabItem.keyEquivalentModifierMask = [.command, .shift]
        tabMenu.addItem(renameTabItem)

        let nextTabItem = NSMenuItem(title: "Next Tab", action: #selector(nextTab(_:)), keyEquivalent: "N")
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        tabMenu.addItem(nextTabItem)

        let prevTabItem = NSMenuItem(title: "Previous Tab", action: #selector(prevTab(_:)), keyEquivalent: "P")
        prevTabItem.keyEquivalentModifierMask = [.command, .shift]
        tabMenu.addItem(prevTabItem)

        // MRU switcher: cmd-shift-o (older, primary like cmd-tab) and
        // cmd-shift-i (newer, reverse). The local NSEvent monitor in
        // AppRuntime swallows these chords for the held-modifier path;
        // these menu items provide discoverability and a one-shot fallback.
        let recentOlderItem = NSMenuItem(title: "Recent Tab (Older)", action: #selector(mruRecentOlder(_:)), keyEquivalent: "o")
        recentOlderItem.keyEquivalentModifierMask = [.command, .shift]
        tabMenu.addItem(recentOlderItem)

        let recentNewerItem = NSMenuItem(title: "Recent Tab (Newer)", action: #selector(mruRecentNewer(_:)), keyEquivalent: "i")
        recentNewerItem.keyEquivalentModifierMask = [.command, .shift]
        tabMenu.addItem(recentNewerItem)

        let zoomItem = NSMenuItem(title: "Toggle Zoom", action: #selector(toggleZoom(_:)), keyEquivalent: "\r")
        zoomItem.keyEquivalentModifierMask = [.command]
        tabMenu.addItem(zoomItem)

        // Color submenu
        tabMenu.addItem(NSMenuItem.separator())
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorSubmenu = NSMenu()
        let colors = TabColor.allCases
        for (i, color) in colors.enumerated() {
            let item = NSMenuItem(title: color.rawValue.capitalized, action: #selector(setTabColorFromMenu(_:)), keyEquivalent: i < 3 ? "\(i + 1)" : "")
            item.tag = i
            item.image = color.swatchImage
            colorSubmenu.addItem(item)
        }
        colorSubmenu.addItem(NSMenuItem.separator())
        colorSubmenu.addItem(withTitle: "Clear Color", action: #selector(clearTabColor(_:)), keyEquivalent: "0")
        colorItem.submenu = colorSubmenu
        tabMenu.addItem(colorItem)

        tabMenu.addItem(NSMenuItem.separator())
        let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "W")
        closeTabItem.keyEquivalentModifierMask = [.command, .shift]
        tabMenu.addItem(closeTabItem)

        tabMenuItem.submenu = tabMenu
        mainMenu.addItem(tabMenuItem)

        // Pane menu
        let paneMenuItem = NSMenuItem()
        let paneMenu = NSMenu(title: "Pane")

        let splitRightItem = NSMenuItem(title: "Split Right", action: #selector(splitRight(_:)), keyEquivalent: "d")
        paneMenu.addItem(splitRightItem)

        let splitDownItem = NSMenuItem(title: "Split Down", action: #selector(splitDown(_:)), keyEquivalent: "d")
        splitDownItem.keyEquivalentModifierMask = [.command, .shift]
        paneMenu.addItem(splitDownItem)

        paneMenu.addItem(NSMenuItem.separator())

        let focusLeft = NSMenuItem(title: "Focus Left", action: #selector(focusLeft(_:)), keyEquivalent: "H")
        focusLeft.keyEquivalentModifierMask = [.command, .shift]
        paneMenu.addItem(focusLeft)

        let focusDown = NSMenuItem(title: "Focus Down", action: #selector(focusDown(_:)), keyEquivalent: "J")
        focusDown.keyEquivalentModifierMask = [.command, .shift]
        paneMenu.addItem(focusDown)

        let focusUp = NSMenuItem(title: "Focus Up", action: #selector(focusUp(_:)), keyEquivalent: "K")
        focusUp.keyEquivalentModifierMask = [.command, .shift]
        paneMenu.addItem(focusUp)

        let focusRight = NSMenuItem(title: "Focus Right", action: #selector(focusRight(_:)), keyEquivalent: "L")
        focusRight.keyEquivalentModifierMask = [.command, .shift]
        paneMenu.addItem(focusRight)

        paneMenu.addItem(NSMenuItem.separator())

        let goToAlert = NSMenuItem(title: "Go to Most Recent Unread Alert", action: #selector(goToMostRecentAlertPane(_:)), keyEquivalent: "a")
        goToAlert.keyEquivalentModifierMask = [.command, .shift]
        paneMenu.addItem(goToAlert)

        let ackTabAlertsItem = NSMenuItem(title: "Clear Tab Alerts", action: #selector(ackTabAlerts(_:)), keyEquivalent: ".")
        paneMenu.addItem(ackTabAlertsItem)

        let ackAlertItem = NSMenuItem(title: "Clear Pane Alerts", action: #selector(ackPaneAlerts(_:)), keyEquivalent: ".")
        ackAlertItem.keyEquivalentModifierMask = [.command, .shift]
        paneMenu.addItem(ackAlertItem)

        let todoItem = NSMenuItem(title: "Open TODOs", action: #selector(openTodo(_:)), keyEquivalent: "t")
        todoItem.keyEquivalentModifierMask = [.command, .option]
        paneMenu.addItem(todoItem)

        paneMenu.addItem(NSMenuItem.separator())
        paneMenu.addItem(withTitle: "Close Pane", action: #selector(closePane(_:)), keyEquivalent: "w")

        paneMenuItem.submenu = paneMenu
        mainMenu.addItem(paneMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu Actions

    @objc func newTab(_ sender: Any?) {
        runtime.send(.createTab(inGroupId: nil))
    }

    @objc func newGroup(_ sender: Any?) {
        let existingIds = Set(runtime.model.groups.map(\.id))
        runtime.send(.createGroup(name: "New group"))
        if let newGroup = runtime.model.groups.first(where: { !existingIds.contains($0.id) }) {
            let groupId = newGroup.id
            DispatchQueue.main.async { [weak self] in
                self?.sidebarView.beginRenamingGroup(groupId)
            }
        }
    }

    @objc func splitRight(_ sender: Any?) {
        runtime.send(.splitPane(direction: .horizontal))
    }

    @objc func splitDown(_ sender: Any?) {
        runtime.send(.splitPane(direction: .vertical))
    }

    @objc func nextTab(_ sender: Any?) {
        runtime.send(.selectAdjacentTab(direction: .next))
    }

    @objc func prevTab(_ sender: Any?) {
        runtime.send(.selectAdjacentTab(direction: .prev))
    }

    // Menu fallback for the MRU switcher: jumps once to the next/previous
    // tab in MRU history. Atomic step+commit; doesn't leave the overlay open.
    // The local NSEvent monitor consumes cmd-shift-i/o under normal operation,
    // so these run only if the monitor is absent.
    @objc func mruRecentOlder(_ sender: Any?) {
        runtime.send(.mruCycleOneShot(direction: .older))
    }

    @objc func mruRecentNewer(_ sender: Any?) {
        runtime.send(.mruCycleOneShot(direction: .newer))
    }

    @objc func toggleZoom(_ sender: Any?) {
        runtime.send(.toggleZoomPane)
    }

    @objc func renameTab(_ sender: Any?) {
        guard let tabId = runtime.model.selectedTabId else { return }
        sidebarView.beginRenamingTab(tabId)
    }

    @objc func closeTab(_ sender: Any?) {
        guard let tabId = runtime.model.selectedTabId else { return }
        runtime.send(.requestCloseTab(id: tabId))
    }

    // Tab > Color submenu actions. The action target is the sidebar's full
    // multi-selection (mirrors right-click context menu); the toggle-off
    // policy ("re-apply clears when every targeted tab already shares the
    // requested color") is delegated to resolveColorForBatch in
    // ModelOperations.swift, which is shared with SidebarView's context menu.
    @objc func setTabColorFromMenu(_ sender: NSMenuItem) {
        let colors = TabColor.allCases
        guard sender.tag >= 0, sender.tag < colors.count else { return }
        let tabIds = currentColorTargetTabIds()
        guard !tabIds.isEmpty else { return }
        let resolved = resolveColorForBatch(
            tabIds: tabIds, requested: colors[sender.tag], in: runtime.model)
        runtime.send(.setTabColors(tabIds: tabIds, color: resolved))
    }

    @objc func clearTabColor(_ sender: Any?) {
        let tabIds = currentColorTargetTabIds()
        guard !tabIds.isEmpty else { return }
        runtime.send(.setTabColors(tabIds: tabIds, color: nil))
    }

    // Action target for tab-color shortcuts. Prefers the sidebar's actual
    // multi-selection; falls back to the focused tab if the sidebar isn't
    // reachable (transient teardown only -- IUOs are set in
    // applicationDidFinishLaunching before any menu can dispatch).
    private func currentColorTargetTabIds() -> [TabId] {
        if let sidebar = sidebarView {
            let ids = sidebar.selectedTabIds()
            if !ids.isEmpty { return ids }
        }
        return runtime.model.selectedTabId.map { [$0] } ?? []
    }

    @objc func exportState(_ sender: Any?) {
        runtime.send(.exportState)
    }

    @objc func importState(_ sender: Any?) {
        runtime.importStateFromPanel(restoreCommandBehavior: restoreCommandBehavior)
    }

    @objc func showPreferences(_ sender: Any?) {
        runtime.showPreferencesPanel()
    }

    @objc func openDanTermConfig(_ sender: Any?) {
        let path = DanTermConfigParser.configFilePath()
        let url = URL(fileURLWithPath: path)
        // Create file + parent dirs if needed so the editor opens something
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent().path
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: path) {
            // Seed with a comment so macOS recognizes it as a text file
            let seed = "# DanTerm config — Ghostty keys + DanTerm-specific keys\n# https://github.com/danneu/danterm\n"
            fm.createFile(atPath: path, contents: seed.data(using: .utf8))
        }
        NSWorkspace.shared.open(url)
    }

    @objc func openGhosttyConfig(_ sender: Any?) {
        guard let path = GhosttyApp.configFilePath() else { return }
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent().path
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        NSWorkspace.shared.open(url)
    }

    @objc func reloadConfig(_ sender: Any?) {
        runtime.reloadAllConfig()
    }

    @objc func findInTerminal(_ sender: Any?) {
        runtime.send(.startSearch)
    }

    @objc func toggleThemePanel(_ sender: Any?) {
        runtime.toggleThemeBrowser()
    }

    @objc func closePane(_ sender: Any?) {
        guard let tab = selectedTab(in: runtime.model) else { return }
        runtime.send(.requestClosePane(paneId: tab.focusedPaneId))
    }

    @objc func openTodo(_ sender: Any?) {
        guard let tab = selectedTab(in: runtime.model) else { return }
        runtime.send(.toggleTodoPopover(paneId: tab.focusedPaneId))
    }

    @objc func focusLeft(_ sender: Any?) {
        runtime.send(.focusDirection(direction: .horizontal, side: .first))
    }

    @objc func focusDown(_ sender: Any?) {
        runtime.send(.focusDirection(direction: .vertical, side: .second))
    }

    @objc func focusUp(_ sender: Any?) {
        runtime.send(.focusDirection(direction: .vertical, side: .first))
    }

    @objc func focusRight(_ sender: Any?) {
        runtime.send(.focusDirection(direction: .horizontal, side: .second))
    }

    @objc func goToMostRecentAlertPane(_ sender: Any?) {
        runtime.send(.goToMostRecentAlertPane)
    }

    @objc func ackPaneAlerts(_ sender: Any?) {
        guard let tab = selectedTab(in: runtime.model) else { return }
        runtime.send(.clearAlertsForPane(paneId: tab.focusedPaneId))
    }

    @objc func ackTabAlerts(_ sender: Any?) {
        runtime.send(.ackTabAlerts)
    }

    @objc func quitApp(_ sender: Any?) {
        runtime?.send(.requestQuit)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let alertIdStr = userInfo["alertId"] as? String,
           let rawAlertId = UUID(uuidString: alertIdStr) {
            runtime.send(.activateAlert(alertId: AlertId(rawValue: rawAlertId)))
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    @objc func toggleAlerts(_ sender: Any?) {
        runtime.toggleAlertsPopover()
    }

    // Collapse/uncollapse the sidebar in the NSSplitView and sync the chrome.
    @objc func toggleSidebar(_ sender: Any?) {
        if splitView.isSubviewCollapsed(sidebarView) {
            sidebarView.isHidden = false
            splitView.setPosition(Self.minSidebarWidth, ofDividerAt: 0)
            chromeView.syncWithSidebarState(collapsed: false, sidebarWidth: Self.minSidebarWidth)
        } else {
            splitView.setPosition(0, ofDividerAt: 0)
            chromeView.syncWithSidebarState(collapsed: true, sidebarWidth: 0)
        }
    }

    // MARK: - NSSplitViewDelegate (sidebar)

    // Sidebar drag bounds: min 150px, max 300px
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return Self.minSidebarWidth
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 300
    }

    // Allow collapsing sidebar (but not content area)
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        return subview === sidebarView
    }

    // On window resize, only the content area resizes; sidebar keeps its width
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        return view !== sidebarView
    }

    // NSSplitViewDelegate: keep the chrome separator aligned with the divider during drag.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        let sidebarWidth = sidebarView.frame.width
        if splitView.isSubviewCollapsed(sidebarView) {
            chromeView.syncWithSidebarState(collapsed: true, sidebarWidth: 0)
        } else {
            chromeView.syncWithSidebarState(collapsed: false, sidebarWidth: sidebarWidth)
        }
    }

    // MARK: - NSWindowDelegate

    // NSWindowDelegate: intercept the window close (X) button so we can route
    // through the quit confirmation flow instead of closing immediately.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        runtime?.send(.requestQuit)
        return false
    }

    // MARK: - App Lifecycle

    // NSApplicationDelegate: catch-all safety net for any NSApp.terminate call.
    // Routes through the Elm quit confirmation unless the .terminate effect already
    // set quitConfirmed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime = runtime else { return .terminateNow }
        if quitConfirmed { return .terminateNow }
        runtime.send(.requestQuit)
        return .terminateCancel
    }

    // NSApplicationDelegate: write final enriched checkpoint (with scrollback) and
    // delete the session lock so the next launch knows this was a clean exit.
    func applicationWillTerminate(_ notification: Notification) {
        runtime?.performEnrichedCheckpoint()
        deleteSessionLockFile()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        runtime?.send(.appBecameActive)
    }

    func applicationDidResignActive(_ notification: Notification) {
        runtime?.send(.appResignedActive)
    }
}
