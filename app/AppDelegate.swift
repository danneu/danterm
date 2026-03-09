import Cocoa
import GhosttyKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, NSSplitViewDelegate, NSToolbarDelegate, UNUserNotificationCenterDelegate {
    var window: NSWindow!
    var ghosttyApp: GhosttyApp!
    var runtime: AppRuntime!
    var sidebarView: SidebarView!
    var contentArea: NSView!
    var splitView: NSSplitView!
    var initSnapshot: AppModelSnapshot?
    var alertsBellItem: NSToolbarItem?

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

        // Create window
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DanTerm"
        window.minSize = NSSize(width: 600, height: 300)
        window.center()

        // Toolbar with sidebar toggle
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // Create split view (sidebar | content)
        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self

        // Sidebar
        sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        sidebarView.runtime = runtime

        // Content area
        contentArea = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        splitView.addArrangedSubview(sidebarView)
        splitView.addArrangedSubview(contentArea)

        // Sidebar holds its width; content area stretches
        sidebarView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        contentArea.setContentHuggingPriority(.defaultLow, for: .horizontal)

        window.contentView = splitView
        window.makeKeyAndOrderFront(nil)

        // Set divider position after window is visible
        splitView.setPosition(200, ofDividerAt: 0)

        // Wire runtime to views
        runtime.window = window
        runtime.sidebarView = sidebarView
        runtime.contentArea = contentArea

        // Bootstrap from snapshot or create default tab
        if let snapshot = initSnapshot {
            runtime.bootstrapFromSnapshot(snapshot)
            initSnapshot = nil
        } else {
            runtime.send(.createTab(inGroupId: nil))
        }

        // Set up notification center
        UNUserNotificationCenter.current().delegate = self

        NSApp.activate(ignoringOtherApps: true)

    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About DanTerm", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Export State...", action: #selector(exportState(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit DanTerm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Shell menu
        let shellMenuItem = NSMenuItem()
        let shellMenu = NSMenu(title: "Shell")
        shellMenu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")

        let newGroupItem = NSMenuItem(title: "New Group", action: #selector(newGroup(_:)), keyEquivalent: "G")
        newGroupItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(newGroupItem)

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

        panesMenuItem.submenu = panesMenu
        mainMenu.addItem(panesMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu Actions

    @objc func newTab(_ sender: Any?) {
        runtime.send(.createTab(inGroupId: nil))
    }

    @objc func newGroup(_ sender: Any?) {
        runtime.send(.createGroup(name: "Untitled"))
        // Begin renaming the last group
        if let lastGroup = runtime.model.groups.last, !lastGroup.isDefault {
            sidebarView.beginRenamingGroup(lastGroup.id)
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

    @objc func exportState(_ sender: Any?) {
        runtime.send(.exportState)
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
        completionHandler([])
    }

    // MARK: - NSToolbarDelegate

    private static let sidebarToggleId = NSToolbarItem.Identifier("ToggleSidebar")
    private static let alertsBellId = NSToolbarItem.Identifier("AlertsBell")

    // System .toggleSidebar only works with NSSplitViewController, so we use a
    // custom item with the standard sidebar icon and explicit target/action.
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == Self.sidebarToggleId {
            let item = NSToolbarItem(itemIdentifier: Self.sidebarToggleId)
            item.label = "Toggle Sidebar"
            item.toolTip = "Toggle Sidebar"
            item.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Toggle Sidebar")
            item.target = self
            item.action = #selector(toggleSidebar(_:))
            return item
        }
        if itemIdentifier == Self.alertsBellId {
            let item = NSToolbarItem(itemIdentifier: Self.alertsBellId)
            item.label = "Alerts"
            item.toolTip = "Alerts"
            // Use a custom view so we own the badge directly — no view hierarchy walking needed.
            let bellButton = BellToolbarButton()
            bellButton.target = self
            bellButton.action = #selector(toggleAlerts(_:))
            item.view = bellButton
            alertsBellItem = item
            runtime.alertsBellButton = bellButton
            return item
        }
        return nil
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarToggleId, Self.alertsBellId]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarToggleId, Self.alertsBellId]
    }

    @objc func toggleAlerts(_ sender: Any?) {
        runtime.toggleAlertsPopover()
    }

    // Collapse/uncollapse the sidebar in the NSSplitView.
    // When collapsed, NSSplitView hides the subview so we unhide before restoring position.
    @objc func toggleSidebar(_ sender: Any?) {
        if splitView.isSubviewCollapsed(sidebarView) {
            sidebarView.isHidden = false
            splitView.setPosition(200, ofDividerAt: 0)
        } else {
            splitView.setPosition(0, ofDividerAt: 0)
        }
    }

    // MARK: - NSSplitViewDelegate (sidebar)

    // Sidebar drag bounds: min 150px, max 300px
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 150
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

    // MARK: - App Lifecycle

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
