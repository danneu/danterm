import Cocoa
import GhosttyKit
import UserNotifications

class AppRuntime {
    var model: AppModel
    let ghosttyApp: GhosttyApp
    var surfaces: [PaneId: TerminalView] = [:]
    weak var window: NSWindow?
    weak var sidebarView: SidebarView?
    weak var contentArea: NSView?

    init(ghosttyApp: GhosttyApp) {
        self.ghosttyApp = ghosttyApp
        self.model = AppModel(
            groups: [GroupModel(id: GroupId(), name: "General", isDefault: true)],
            panes: [:]
        )
    }

    func send(_ msg: Msg) {
        let oldBellCount = totalBellCount(model: model)
        let effects = update(&model, msg)
        for effect in effects {
            perform(effect)
        }
        let newBellCount = totalBellCount(model: model)
        if newBellCount != oldBellCount {
            perform(.updateDockBadge(newBellCount))
        }
    }

    func terminalView(for paneId: PaneId) -> TerminalView? {
        return surfaces[paneId]
    }

    // MARK: - Effect Performer

    private func perform(_ effect: Effect) {
        switch effect {
        case .createSurface(let paneId, let cwd, let command):
            let view = TerminalView(ghosttyApp: ghosttyApp, workingDirectory: cwd, command: command)
            view.bridge.paneId = paneId
            view.runtime = self
            surfaces[paneId] = view
            if view.surface == nil {
                send(.surfaceCreationFailed(paneId: paneId))
            }

        case .destroySurface(let paneId):
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

        case .sendNotification(let title, let body, let tabId, let paneId):
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = [
                "tabId": tabId.rawValue.uuidString,
                "paneId": paneId.rawValue.uuidString,
            ]
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)

        case .requestNotificationPermission:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

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

        case .updateDockBadge(let count):
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
            NSApp.dockTile.display()
        }
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
                    let view = TerminalView(ghosttyApp: ghosttyApp, workingDirectory: resolved?.cwd, command: resolved?.command)
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

    // MARK: - View Building

    private func rebuildContentView() {
        guard let contentArea = contentArea else { return }

        // Remove old content
        for subview in contentArea.subviews {
            subview.removeFromSuperview()
        }

        guard let tab = selectedTab(in: model) else { return }

        // Defocus all surfaces before rebuilding
        for paneId in allPaneIds(tab.rootNode) {
            if let view = surfaces[paneId], let surface = view.surface {
                ghostty_surface_set_focus(surface, false)
            }
        }

        let container = SplitContainerView(
            rootNode: tab.rootNode,
            surfaceLookup: { [weak self] paneId in self?.surfaces[paneId] },
            runtime: self,
            frame: contentArea.bounds
        )
        container.autoresizingMask = [.width, .height]
        contentArea.addSubview(container)
        container.rebuild()

        // Set focus borders based on model state
        let focusedId = tab.focusedPaneId
        for paneId in allPaneIds(tab.rootNode) {
            let isFocused = paneId == focusedId
            let hasBell = model.panes[paneId]?.hasBell ?? false
            surfaces[paneId]?.setFocusBorder(isFocused, hasBell: hasBell)
        }

        // Focus the right pane
        if let focusedView = surfaces[focusedId] {
            window?.makeFirstResponder(focusedView)
        }
    }
}
