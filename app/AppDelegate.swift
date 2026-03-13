// App delegate responsible for window setup, app lifecycle hooks, menus, and
// notification center delegation.
import Cocoa
import GhosttyKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, NSSplitViewDelegate, UNUserNotificationCenterDelegate {
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
        appMenu.addItem(withTitle: "Quit DanTerm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Shell menu
        let shellMenuItem = NSMenuItem()
        let shellMenu = NSMenu(title: "Shell")
        shellMenu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")

        shellMenu.addItem(withTitle: "New Group", action: #selector(newGroup(_:)), keyEquivalent: "n")

        let splitRightItem = NSMenuItem(title: "Split Right", action: #selector(splitRight(_:)), keyEquivalent: "d")
        shellMenu.addItem(splitRightItem)

        let splitDownItem = NSMenuItem(title: "Split Down", action: #selector(splitDown(_:)), keyEquivalent: "d")
        splitDownItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(splitDownItem)

        let nextTabItem = NSMenuItem(title: "Next Tab", action: #selector(nextTab(_:)), keyEquivalent: "N")
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(nextTabItem)

        let prevTabItem = NSMenuItem(title: "Previous Tab", action: #selector(prevTab(_:)), keyEquivalent: "P")
        prevTabItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(prevTabItem)

        let zoomItem = NSMenuItem(title: "Toggle Zoom", action: #selector(toggleZoom(_:)), keyEquivalent: "\r")
        zoomItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(zoomItem)

        let renameTabItem = NSMenuItem(title: "Rename Tab", action: #selector(renameTab(_:)), keyEquivalent: "R")
        renameTabItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(renameTabItem)

        shellMenu.addItem(NSMenuItem.separator())
        shellMenu.addItem(withTitle: "Close Pane", action: #selector(closePane(_:)), keyEquivalent: "w")
        shellMenuItem.submenu = shellMenu
        mainMenu.addItem(shellMenuItem)

        // Panes menu
        let panesMenuItem = NSMenuItem()
        let panesMenu = NSMenu(title: "Panes")

        let focusLeft = NSMenuItem(title: "Focus Left", action: #selector(focusLeft(_:)), keyEquivalent: "H")
        focusLeft.keyEquivalentModifierMask = [.command, .shift]
        panesMenu.addItem(focusLeft)

        let focusDown = NSMenuItem(title: "Focus Down", action: #selector(focusDown(_:)), keyEquivalent: "J")
        focusDown.keyEquivalentModifierMask = [.command, .shift]
        panesMenu.addItem(focusDown)

        let focusUp = NSMenuItem(title: "Focus Up", action: #selector(focusUp(_:)), keyEquivalent: "K")
        focusUp.keyEquivalentModifierMask = [.command, .shift]
        panesMenu.addItem(focusUp)

        let focusRight = NSMenuItem(title: "Focus Right", action: #selector(focusRight(_:)), keyEquivalent: "L")
        focusRight.keyEquivalentModifierMask = [.command, .shift]
        panesMenu.addItem(focusRight)

        panesMenu.addItem(NSMenuItem.separator())

        let goToAlert = NSMenuItem(title: "Go to Most Recent Unread Alert", action: #selector(goToMostRecentAlertPane(_:)), keyEquivalent: "a")
        goToAlert.keyEquivalentModifierMask = [.command, .shift]
        panesMenu.addItem(goToAlert)

        panesMenuItem.submenu = panesMenu
        mainMenu.addItem(panesMenuItem)

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

    @objc func toggleZoom(_ sender: Any?) {
        runtime.send(.toggleZoomPane)
    }

    @objc func renameTab(_ sender: Any?) {
        guard let tabId = runtime.model.selectedTabId else { return }
        sidebarView.beginRenamingTab(tabId)
    }

    @objc func exportState(_ sender: Any?) {
        runtime.send(.exportState)
    }

    @objc func importState(_ sender: Any?) {
        runtime.importStateFromPanel(restoreCommandBehavior: restoreCommandBehavior)
    }

    @objc func closePane(_ sender: Any?) {
        guard let tab = selectedTab(in: runtime.model),
              let surface = runtime.surfaces[tab.focusedPaneId]?.surface else { return }
        ghostty_surface_request_close(surface)
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

    // MARK: - App Lifecycle

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
