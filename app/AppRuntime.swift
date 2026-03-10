import Cocoa
import GhosttyKit
import UniformTypeIdentifiers
import UserNotifications

// App runtime owns the mutable app model, performs side effects emitted by the
// pure update function, and bridges model changes into AppKit/Ghostty objects.
class AppRuntime {
    var model: AppModel
    let ghosttyApp: GhosttyApp
    var surfaces: [PaneId: TerminalView] = [:]
    var tokenStore = PaneTokenStore()
    weak var window: NSWindow?
    weak var sidebarView: SidebarView?
    weak var contentArea: NSView?
    var alertsPopover: NSPopover?
    weak var alertsBellItem: NSToolbarItem?
    /// The custom bell button set as the toolbar item's view. Owns the badge directly.
    weak var alertsBellButton: BellToolbarButton?
    private var dragCoordinator: PaneDragCoordinator?

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
        }

        // Refresh toolbar text after title/cwd changes
        switch translatedMsg {
        case .surfaceTitle(let paneId, _), .surfaceCwd(let paneId, _):
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
            let view = TerminalView(ghosttyApp: ghosttyApp, workingDirectory: cwd, command: command, envVars: [("DANTERM_TOKEN", token)])
            view.bridge.paneId = paneId
            view.runtime = self
            surfaces[paneId] = view
            if view.surface == nil {
                send(.surfaceCreationFailed(paneId: paneId))
            }

        case .destroySurface(let paneId):
            tokenStore.remove(paneId)
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

        case .exportState(let initFile):
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

        case .terminate:
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
            alertsBellButton?.updateBadge(count: count)

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

        // Build sidebar tab IDs: all tabs except the source pane's tab
        let sourceTabId = tab.id
        let sidebarTabIds = model.groups.flatMap(\.tabs).map(\.id).filter { $0 != sourceTabId }

        // Sidebar frame provider
        let sidebarProvider: ((TabId) -> NSRect?)? = { [weak self] tabId in
            self?.sidebarView?.tabRowFrame(for: tabId)
        }

        let coordinator = PaneDragCoordinator(
            sourcePaneId: paneId,
            contentView: contentArea,
            paneFrameProvider: provider,
            targetPaneIds: targetIds,
            sidebarTabFrameProvider: sidebarProvider,
            sidebarTabIds: sidebarTabIds
        )
        coordinator.onCancel = { [weak self] in self?.cancelPaneDrag() }
        coordinator.onSidebarHighlight = { [weak self] tabId in
            self?.sidebarView?.highlightTabForDrop(tabId)
        }
        dragCoordinator = coordinator
    }

    func updatePaneDrag(event: NSEvent) {
        dragCoordinator?.updateDrag(locationInWindow: event.locationInWindow)
    }

    func completePaneDrag() {
        // Check sidebar drop first (pane → different tab)
        if let sidebarResult = dragCoordinator?.currentSidebarDrop() {
            cancelPaneDrag()
            send(.movePaneToTab(paneId: sidebarResult.paneId, targetTabId: sidebarResult.tabId))
            return
        }
        // Then check intra-tab pane drop
        guard let result = dragCoordinator?.currentDrop() else {
            cancelPaneDrag()
            return
        }
        cancelPaneDrag()
        send(.movePane(source: result.source, target: result.target, intent: result.intent))
    }

    func cancelPaneDrag() {
        guard dragCoordinator != nil else { return }
        // Reset to arrow; cursor rects will correct on next mouse move.
        NSCursor.arrow.set()
        dragCoordinator?.teardown()
        dragCoordinator = nil
    }

    // MARK: - Snapshot Bootstrap

    func bootstrapFromSnapshot(_ snapshot: AppModelSnapshot) {
        guard let built = validateAndBuildDetailed(snapshot) else {
            print("[init] Snapshot validation failed, falling back to default startup")
            send(.createTab(inGroupId: nil))
            return
        }
        self.model = built.model

        // Create surfaces for all panes
        for group in model.groups {
            for tab in group.tabs {
                for paneId in allPaneIds(tab.rootNode) {
                    let ps = built.paneSnapshots[paneId]
                    let resolved = ps.map { resolveLaunch($0) }
                    let token = tokenStore.generate(for: paneId)
                    let view = TerminalView(ghosttyApp: ghosttyApp, workingDirectory: resolved?.cwd, command: resolved?.command, envVars: [("DANTERM_TOKEN", token)])
                    view.bridge.paneId = paneId
                    view.runtime = self
                    surfaces[paneId] = view
                    if view.surface == nil {
                        send(.surfaceCreationFailed(paneId: paneId))
                        return
                    }
                }
            }
        }

        // Rebuild views
        rebuildContentView()
        sidebarView?.reload(model: model)
    }

    // MARK: - Pane Toolbars

    func refreshPaneToolbars() {
        guard let contentArea = contentArea else { return }
        forEachPaneWrapper(in: contentArea) { wrapper in
            let (title, cwd) = paneToolbarText(for: wrapper.paneId, in: model)
            wrapper.updateToolbar(title: title, cwd: cwd)
        }
    }

    private func refreshPaneToolbar(for paneId: PaneId) {
        guard let contentArea = contentArea else { return }
        let (title, cwd) = paneToolbarText(for: paneId, in: model)
        findPaneWrapper(for: paneId, in: contentArea)?.updateToolbar(title: title, cwd: cwd)
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
    }

    // MARK: - Alerts Popover

    func toggleAlertsPopover() {
        if let popover = alertsPopover, popover.isShown {
            popover.performClose(nil)
            alertsPopover = nil
            return
        }
        guard let anchor = alertsBellButton else { return }
        let vc = AlertsPopoverViewController()
        vc.runtime = self
        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        alertsPopover = popover
    }
}

/// Custom toolbar button that displays a bell icon with an overlaid badge count.
/// Set as the NSToolbarItem's `view` directly, so no view hierarchy discovery is needed.
class BellToolbarButton: NSButton {
    private let badgeLabel: NSTextField

    init() {
        badgeLabel = NSTextField(labelWithString: "0")
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        bezelStyle = .texturedRounded
        isBordered = true
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        image = NSImage(systemSymbolName: "bell", accessibilityDescription: "Alerts")?.withSymbolConfiguration(config)
        imagePosition = .imageOnly
        imageScaling = .scaleNone

        // Badge: red circle with white count text, ignores mouse events
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .monospacedSystemFont(ofSize: 8, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.backgroundColor = NSColor.systemRed.cgColor
        badgeLabel.layer?.cornerRadius = 7
        badgeLabel.layer?.masksToBounds = true
        badgeLabel.isHidden = true
        addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            // Size to match standard toolbar buttons
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 28),
            // Badge at top-right of button
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 14),
            badgeLabel.heightAnchor.constraint(equalToConstant: 14),
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 2),
            badgeLabel.topAnchor.constraint(equalTo: topAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func updateBadge(count: Int) {
        badgeLabel.stringValue = "\(count)"
        badgeLabel.isHidden = count == 0
    }

    // Route all hits within our bounds to self, so the badge doesn't intercept clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }
}
