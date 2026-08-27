// App delegate responsible for window setup, app lifecycle hooks, menus, and
// notification center delegation.
import Cocoa
import DanTermProtocol
@preconcurrency import UserNotifications

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSSplitViewDelegate, @preconcurrency UNUserNotificationCenterDelegate, WindowIndependentMenuActions, ConfigurableMenuCommandTarget {
    nonisolated static let minWindowWidth: CGFloat = 600
    nonisolated static let minWindowHeight: CGFloat = 300
    nonisolated static let minSidebarWidth: CGFloat = 200

    /// Every identity-keyed path this process owns, resolved once at launch and
    /// handed down from there, so nothing below re-derives a directory of its own.
    let instancePaths: DanTermInstancePaths
    /// The config file this launch owns, resolved once in main.swift. It sits beside
    /// the instance paths rather than inside them because it is not keyed by the
    /// instance identity: two identities can deliberately read one file.
    let configURL: URL
    var window: NSWindow!
    var terminalBackend: SwiftTerminalBackend!
    var runtime: AppRuntime!
    var sidebarView: SidebarView!
    var contentArea: NSView!
    var splitView: NSSplitView!
    var chromeView: WindowChromeView!
    private var configurableMenuBindingSurface: ConfigurableMenuBindingSurface?
    // Owned for the application lifetime; its teardown disconnects NSWorkspace callbacks.
    var workspaceLifecycleObserver: WorkspaceLifecycleObserver?
    var initSnapshot: AppModelSnapshot?
    var launchPolicy = AppLaunchPolicy(arguments: [])
    // Session recovery state set by main.swift before app launch.
    var lastSessionSnapshot: ValidatedAppRestore?  // merged + validated from Recovery/last-light.json + last-enriched.json
    var previousSessionCrashed: Bool = false     // true unless the session.json lock was confirmed absent
    // Set by main.swift when the launch-time lock claim failed. Held until the runtime
    // has a window to present through, then reported once as a notice.
    var sessionLockClaimFailure: Error?
    #if DANTERM_TERMINAL_BENCHMARK
    private var benchmarkGeometryController: TerminalBenchmarkGeometryController?
    // AppPresentationLifecycle forwards occlusion into benchmark validity recording.
    var benchmarkStateRecorder: TerminalBenchmarkStateRecorder?
    #endif
    /// Set by the .terminate effect before calling NSApp.terminate to bypass the
    /// applicationShouldTerminate safety net (user already confirmed).
    var quitConfirmed = false

    init(instancePaths: DanTermInstancePaths, configURL: URL) {
        self.instancePaths = instancePaths
        self.configURL = configURL
        super.init()
    }

    // NSApplicationDelegate: finish bootstrapping the terminal backend, main
    // window, and launch-time services once AppKit has started the app.
    func applicationDidFinishLaunching(_ notification: Notification) {
        terminalBackend = SwiftTerminalBackend()
        guard terminalBackend.isReady else {
            print("Failed to create terminal backend")
            NSApp.terminate(nil)
            return
        }

        // Create runtime
        runtime = AppRuntime(
            ports: .live(
                terminalBackend: terminalBackend,
                notificationAuthorizationPolicy: launchPolicy.notificationAuthorization
            ),
            dialogSurfaces: .live(),
            instancePaths: instancePaths,
            configStore: DanTermConfigStore(url: configURL),
            // The real launch state. A detached launch finishes launching without ever
            // activating, and `applicationDidBecomeActive` supplies every later change.
            applicationActive: NSApp.isActive
        )
        installWorkspaceLifecycleObserver()

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
        chromeView.tabTodoButton.target = self
        chromeView.tabTodoButton.action = #selector(toggleTabTodoPopover(_:))

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
        #if DANTERM_TERMINAL_BENCHMARK
        window.orderFront(nil)
        #else
        if launchPolicy.activation == .foreground {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
        #endif

        // Set divider position after window is visible
        splitView.setPosition(Self.minSidebarWidth, ofDividerAt: 0)
        chromeView.syncWithSidebarState(collapsed: false, sidebarWidth: Self.minSidebarWidth)

        // Wire runtime to views
        runtime.window = window
        runtime.sidebarView = sidebarView
        runtime.contentArea = contentArea
        runtime.chromeView = chromeView
        runtime.presentPendingConfigError()
        // The lock itself was claimed in main.swift before any of this existed; only
        // telling the user about a failed claim had to wait for the window.
        if let failure = sessionLockClaimFailure {
            sessionLockClaimFailure = nil
            runtime.reportSessionLockClaimFailure(failure)
        }

        // Clean up stale replay files from prior sessions
        runtime.cleanupStaleReplayDirectory()

        // Bootstrap startup: --init CLI > crash/clean restore prompt > fresh
        if let snapshot = initSnapshot {
            runtime.bootstrapFromSnapshot(snapshot)
            initSnapshot = nil
            runtime.startIpcServer()
        } else if launchPolicy.startup == .promptForRecovery,
                  let lastSession = lastSessionSnapshot {
            let summary = sessionSummary(lastSession)
            let message = previousSessionCrashed
                ? "DanTerm did not exit cleanly last time.\n\(summary)"
                : summary
            runtime.requestRestorePrompt(lastSession, message: message)
            lastSessionSnapshot = nil
        } else {
            runtime.send(.createTabInSelectedGroup())
            runtime.startIpcServer()
        }

        #if DANTERM_TERMINAL_BENCHMARK
        let benchmarkRuntime = runtime
        benchmarkGeometryController = TerminalBenchmarkGeometryController(
            window: window,
            environment: ProcessInfo.processInfo.environment,
            session: { [weak benchmarkRuntime] in benchmarkRuntime?.paneHosts.values.first?.session }
        )
        benchmarkGeometryController?.start()
        benchmarkStateRecorder = TerminalBenchmarkStateRecorder(
            window: window,
            environment: ProcessInfo.processInfo.environment
        )
        TerminalBenchmarkObserver.shared?.stateRecorder = benchmarkStateRecorder
        // After the recorder is attached, because the sampler reads through it.
        // Profiling runs only -- the observer refuses without an activity path.
        TerminalBenchmarkObserver.shared?.startPresentationSampling()
        #endif

        #if !DANTERM_TERMINAL_CHARACTERIZATION && !DANTERM_TERMINAL_BENCHMARK
        // Set up notification center
        let notifCenter = UNUserNotificationCenter.current()
        notifCenter.delegate = self
        #endif

        #if DANTERM_TERMINAL_BENCHMARK
        NSApp.activate()
        #else
        if launchPolicy.activation == .foreground {
            NSApp.activate(ignoringOtherApps: true)
        }
        #endif

        // Benchmark builds are excluded so notification authorization never interrupts a measurement.
        #if !DANTERM_TERMINAL_CHARACTERIZATION && !DANTERM_TERMINAL_BENCHMARK
        // Request notification authorization after the app is active so the
        // system prompt is not racing the initial launch and window setup.
        if launchPolicy.notificationAuthorization.permitsRequest {
            DispatchQueue.main.async { [weak self] in
                self?.requestNotificationAuthorizationIfNeeded()
            }
        }
        #endif

    }

    /// Build a human-readable summary like "12 tabs in 3 groups" for the restore prompt.
    private func sessionSummary(_ restore: ValidatedAppRestore) -> String {
        let tabCount = restore.model.groups.flatMap(\.tabs).count
        let groupCount = restore.model.groups.count
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

    /// Builds the App menu on its own so a test can read it without launching the app.
    /// Every item here is fixed: either an AppKit built-in or a one-shot maintenance
    /// action with its own selector, so none of them belongs in the keybinding catalog.
    /// The two config commands are the exception and stay configurable.
    static func makeAppMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About DanTerm", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Import State...", action: #selector(AppDelegate.importState(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Export State...", action: #selector(AppDelegate.exportState(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        // Cmd+, is the macOS convention for Settings, not a preference, so the item owns it
        // outright and `keybindingReservations` keeps configurable commands off it.
        appMenu.addItem(withTitle: "Settings...", action: #selector(AppDelegate.showPreferences(_:)), keyEquivalent: ",")
        appMenu.addCommand("app.open-config")
        appMenu.addCommand("app.reload-config")
        appMenu.addItem(
            withTitle: "Install danterm Command in PATH",
            action: #selector(AppDelegate.installDantermInPath(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(NSMenuItem.separator())
        // Standard App-menu Hide triad. Dispatched through the responder chain
        // (target nil) to AppKit built-ins, so no handler methods are needed.
        appMenu.addItem(withTitle: "Hide DanTerm", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        // Show All auto-disables until something is hidden.
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit DanTerm", action: #selector(AppDelegate.quitApp(_:)), keyEquivalent: "q")
        return appMenu
    }

    /// Builds the Edit menu without installing it into AppKit's global menu state.
    static func makeEditMenu() -> NSMenu {
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
        editMenu.addCommand("edit.find")
        editMenu.addCommand("edit.find-next")
        editMenu.addCommand("edit.find-previous")
        return editMenu
    }

    /// Builds the View menu without installing it into AppKit's global menu state.
    static func makeViewMenu() -> NSMenu {
        let viewMenu = NSMenu(title: "View")
        // Theme browser sits on Cmd-Shift-B so the shortcut matches the menu noun.
        // Cmd-Shift-T is reserved for "New Tab at End of Group".
        viewMenu.addCommand("view.toggle-theme-browser")

        // Font size zooms the focused pane only. AppKit matches key equivalents
        // against charactersIgnoringModifiers, so Cmd-Shift-= arrives as "+" and
        // plain Cmd-= as "="; one item cannot match both. The visible row binds
        // "+", and a hidden twin keeps "=" live without showing a second row.
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addCommand("view.font-increase")
        viewMenu.addCommand("view.font-decrease")
        viewMenu.addCommand("view.font-reset")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addCommand("view.toggle-sidebar")
        viewMenu.addCommand("view.toggle-alerts")
        return viewMenu
    }

    /// Builds the Tab menu without installing it into AppKit's global menu state.
    static func makeTabMenu() -> NSMenu {
        let tabMenu = NSMenu(title: "Tab")
        tabMenu.addCommand("tab.new")
        // Cmd-Shift-T appends to the current group, ignoring which tab is selected.
        tabMenu.addCommand("tab.new-at-end")
        tabMenu.addCommand("tab.new-group")
        tabMenu.addCommand("tab.rename")
        tabMenu.addCommand("tab.clear-title")
        tabMenu.addCommand("tab.next")
        tabMenu.addCommand("tab.previous")
        tabMenu.addCommand("tab.jump")

        // MRU switcher: cmd-shift-o (older, primary like cmd-tab) and
        // cmd-shift-i (newer, reverse). The local NSEvent monitor in
        // AppRuntime swallows these chords for the held-modifier path;
        // these menu items provide discoverability and a one-shot fallback.
        tabMenu.addCommand("tab.recent-older")
        tabMenu.addCommand("tab.recent-newer")

        // Color submenu
        tabMenu.addItem(NSMenuItem.separator())
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorSubmenu = NSMenu()
        for color in TabColor.allCases {
            let item = colorSubmenu.addCommand(
                KeybindingActionID(rawValue: color.configurableCommand.rawValue)
            )[0]
            item.image = color.swatchImage
        }
        colorSubmenu.addItem(NSMenuItem.separator())
        // Cmd-9, not Cmd-0: "Actual Size" in the View menu owns Cmd-0.
        colorSubmenu.addCommand("tab.color-none")
        colorItem.submenu = colorSubmenu
        tabMenu.addItem(colorItem)

        tabMenu.addCommand("tab.clear-alerts")
        tabMenu.addCommand("tab.toggle-todo")

        tabMenu.addItem(NSMenuItem.separator())
        tabMenu.addCommand("tab.close")
        return tabMenu
    }

    /// Builds the Pane menu without installing it into AppKit's global menu state.
    static func makePaneMenu() -> NSMenu {
        let paneMenu = NSMenu(title: "Pane")

        paneMenu.addCommand("pane.split-right")
        paneMenu.addCommand("pane.split-down")
        paneMenu.addCommand("pane.toggle-zoom")

        paneMenu.addItem(NSMenuItem.separator())

        paneMenu.addCommand("pane.focus-left")
        paneMenu.addCommand("pane.focus-down")
        paneMenu.addCommand("pane.focus-up")
        paneMenu.addCommand("pane.focus-right")

        paneMenu.addItem(NSMenuItem.separator())

        paneMenu.addCommand("pane.next-alert")
        paneMenu.addCommand("pane.clear-alerts")
        paneMenu.addCommand("pane.toggle-todo")

        paneMenu.addItem(NSMenuItem.separator())
        paneMenu.addCommand("pane.close")
        return paneMenu
    }

    /// Builds the Window menu without registering it as AppKit's live window menu.
    static func makeWindowMenu() -> NSMenu {
        // All three actions are AppKit built-ins dispatched through the responder
        // chain (target nil) to the key window / NSApp.
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        return windowMenu
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let windowMenu = Self.makeWindowMenu()
        for menu in [
            Self.makeAppMenu(), Self.makeEditMenu(), Self.makeViewMenu(),
            Self.makeTabMenu(), Self.makePaneMenu(), windowMenu,
        ] {
            let item = NSMenuItem()
            item.submenu = menu
            mainMenu.addItem(item)
        }

        // Per Apple HIG, app-specific menus (Tab/Pane) precede Window.
        // Registering windowsMenu makes AppKit auto-append the live window list
        // (below a separator it inserts) and enables cmd-` window cycling. Only
        // windows with isExcludedFromWindowsMenu == false are listed, so auxiliary
        // panels opt out at their construction sites to keep the list to one entry.
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
        let bindingSurface = ConfigurableMenuBindingSurface(menu: mainMenu)
        configurableMenuBindingSurface = bindingSurface
        runtime.configurableMenuBindingSurface = bindingSurface
    }

    // MARK: - Menu Actions

    /// Exhaustively routes catalog identities to the existing action behavior.
    @objc func performConfiguredCommand(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String,
              let command = ConfigurableCommand(rawValue: rawID)
        else { return }
        switch command {
        case .openConfig: openDanTermConfig(sender)
        case .reloadConfig: reloadConfig(sender)
        case .find: findInTerminal(sender)
        case .findNext: findNextInTerminal(sender)
        case .findPrevious: findPreviousInTerminal(sender)
        case .toggleThemeBrowser: toggleThemeBrowser(sender)
        case .fontIncrease: increasePaneFontSize(sender)
        case .fontDecrease: decreasePaneFontSize(sender)
        case .fontReset: resetPaneFontSize(sender)
        case .toggleSidebar: toggleSidebar(sender)
        case .toggleAlerts: toggleAlerts(sender)
        case .newTab: newTab(sender)
        case .newTabAtEnd: newTabAtGroupEnd(sender)
        case .newGroup: newGroup(sender)
        case .renameTab: renameTab(sender)
        case .clearTitle: clearCustomTitle(sender)
        case .nextTab: nextTab(sender)
        case .previousTab: prevTab(sender)
        case .jump: jumpToTab(sender)
        case .recentOlder: mruRecentOlder(sender)
        case .recentNewer: mruRecentNewer(sender)
        case .colorRed, .colorOrange, .colorYellow, .colorGreen,
             .colorBlue, .colorPurple, .colorGray:
            guard let color = command.tabColor else { return }
            setTabColorFromMenu(color)
        case .colorNone: clearTabColor(sender)
        case .clearTabAlerts: clearTabAlerts(sender)
        case .toggleTabTodo: toggleTabTodoPopover(sender)
        case .closeTab: closeTab(sender)
        case .splitRight: splitRight(sender)
        case .splitDown: splitDown(sender)
        case .toggleZoom: toggleZoom(sender)
        case .focusLeft: focusLeft(sender)
        case .focusDown: focusDown(sender)
        case .focusUp: focusUp(sender)
        case .focusRight: focusRight(sender)
        case .nextAlert: goToMostRecentAlertPane(sender)
        case .clearPaneAlerts: ackPaneAlerts(sender)
        case .togglePaneTodo: openTodo(sender)
        case .closePane: closePane(sender)
        }
    }

    @objc func newTab(_ sender: Any?) {
        runtime.send(.createTabInSelectedGroup())
    }

    @objc func newTabAtGroupEnd(_ sender: Any?) {
        runtime.send(.createTabInSelectedGroup(position: .atGroupEnd))
    }

    @objc func newGroup(_ sender: Any?) {
        runtime.send(.createGroupInteractively(name: "New group"))
    }

    @objc func splitRight(_ sender: Any?) {
        runtime.send(.splitFocusedPane(direction: .horizontal))
    }

    @objc func splitDown(_ sender: Any?) {
        runtime.send(.splitFocusedPane(direction: .vertical))
    }

    @objc func nextTab(_ sender: Any?) {
        runtime.send(.selectAdjacentTab(direction: .next))
    }

    @objc func prevTab(_ sender: Any?) {
        runtime.send(.selectAdjacentTab(direction: .prev))
    }

    @objc func jumpToTab(_ sender: Any?) {
        runtime.enterJumpMode()
    }

    @objc func mruRecentOlder(_ sender: Any?) {
        activateRecentTab(direction: .older)
    }

    @objc func mruRecentNewer(_ sender: Any?) {
        activateRecentTab(direction: .newer)
    }

    private func activateRecentTab(direction: MruDirection) {
        runtime.send(mruActivationMessage(
            direction: direction,
            initiatedByKeyEquivalent: NSApp.currentEvent?.type == .keyDown
        ))
    }

    @objc func toggleZoom(_ sender: Any?) {
        runtime.send(.toggleZoomPane(paneId: nil))
    }

    @objc func renameTab(_ sender: Any?) {
        guard let tabId = runtime.model.selectedTabId else { return }
        runtime.send(.beginSidebarRename(target: .tab(tabId)))
    }

    @objc func clearCustomTitle(_ sender: Any?) {
        if let msg = menubarTabActionMsg(
            .clearCustomTitles,
            sidebarSelection: sidebarView?.selectedTabIds() ?? [],
            in: runtime.model
        ) {
            runtime.send(msg)
        }
    }

    // Close Tab shares the menubar batch router, so cmd+shift+w and the
    // sidebar context menu agree about what "the tabs I picked" means.
    @objc func closeTab(_ sender: Any?) {
        if let msg = menubarTabActionMsg(
            .close,
            sidebarSelection: sidebarView?.selectedTabIds() ?? [],
            in: runtime.model
        ) {
            runtime.send(msg)
        }
    }

    // Tab > Color submenu actions share the menubar batch router with
    // clear-custom-title and clear-tab-alert actions.
    private func setTabColorFromMenu(_ color: TabColor) {
        if let msg = menubarTabActionMsg(
            .setColor(color),
            sidebarSelection: sidebarView?.selectedTabIds() ?? [],
            in: runtime.model
        ) {
            runtime.send(msg)
        }
    }

    @objc func clearTabColor(_ sender: Any?) {
        if let msg = menubarTabActionMsg(
            .clearColor,
            sidebarSelection: sidebarView?.selectedTabIds() ?? [],
            in: runtime.model
        ) {
            runtime.send(msg)
        }
    }

    @objc func exportState(_ sender: Any?) {
        runtime.send(.exportState)
    }

    @objc func importState(_ sender: Any?) {
        runtime.importStateFromPanel()
    }

    @objc func showPreferences(_ sender: Any?) {
        runtime.showPreferencesPanel()
    }

    @objc func openDanTermConfig(_ sender: Any?) {
        runtime.openDanTermConfig()
    }

    @objc func reloadConfig(_ sender: Any?) {
        runtime.reloadDanTermConfig()
    }

    @objc func installDantermInPath(_ sender: Any?) {
        do {
            let outcome = try CLIPathInstaller.default.install()
            let message: String
            if outcome.usedAdministratorPrivileges {
                message = "Installed \(outcome.destinationURL.path) with administrator privileges."
            } else {
                message = "Installed \(outcome.destinationURL.path)."
            }
            runtime.send(.noticeReported(.message(title: "danterm Installed", message: message)))
        } catch {
            runtime.send(.noticeReported(.message(
                title: "Install Failed",
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )))
        }
    }

    @objc func findInTerminal(_ sender: Any?) {
        runtime.send(.startSearch)
    }

    @objc func findNextInTerminal(_ sender: Any?) {
        runtime.send(.navigateFocusedSearch(direction: .next))
    }

    @objc func findPreviousInTerminal(_ sender: Any?) {
        runtime.send(.navigateFocusedSearch(direction: .previous))
    }

    @objc func toggleThemeBrowser(_ sender: Any?) {
        runtime.send(.toggleThemeBrowser)
    }

    // nil paneId means the focused pane of the selected tab, which is what a
    // menubar action targets.
    @objc func increasePaneFontSize(_ sender: Any?) {
        runtime.send(.adjustPaneFontSize(paneId: nil, steps: 1))
    }

    @objc func decreasePaneFontSize(_ sender: Any?) {
        runtime.send(.adjustPaneFontSize(paneId: nil, steps: -1))
    }

    @objc func resetPaneFontSize(_ sender: Any?) {
        runtime.send(.resetPaneFontSize(paneId: nil))
    }

    @objc func closePane(_ sender: Any?) {
        guard let tab = selectedTab(in: runtime.model) else { return }
        runtime.send(.requestClosePane(paneId: tab.paneTree.focusedPaneId))
    }

    @objc func openTodo(_ sender: Any?) {
        guard let tab = selectedTab(in: runtime.model) else { return }
        runtime.send(.toggleTodoPopover(owner: .pane(tab.paneTree.focusedPaneId)))
    }

    @objc func toggleTabTodoPopover(_ sender: Any?) {
        guard let tabId = runtime.model.selectedTabId else { return }
        runtime.send(.toggleTodoPopover(owner: .tab(tabId)))
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
        runtime.send(.clearAlertsForPane(paneId: tab.paneTree.focusedPaneId))
    }

    @objc func clearTabAlerts(_ sender: Any?) {
        if let msg = menubarTabActionMsg(
            .clearAlerts,
            sidebarSelection: sidebarView?.selectedTabIds() ?? [],
            in: runtime.model
        ) {
            runtime.send(msg)
        }
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
        runtime.send(.toggleAlertsPopover)
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

    // NSWindowDelegate: a window moved to another screen may have a different
    // backing scale, which every session's renderer has to pick up.
    func windowDidChangeScreen(_ notification: Notification) {
        guard notification.object is NSWindow else { return }
        runtime?.refreshSessionsForScreenChange()
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
        tearDownWorkspaceLifecycleObserver()
        runtime?.stopIpcServer()
        runtime?.prepareRecoveryForApplicationExit()
        runtime?.shutdown()
        terminalBackend?.terminateForApplicationExit()
        deleteSessionLockFile(paths: instancePaths)
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

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let rawID = item.representedObject as? String {
            return MenuCommandPolicy.isEnabled(
                commandID: KeybindingActionID(rawValue: rawID),
                windowIsLive: window != nil && window.isVisible
            )
        }
        return MenuCommandPolicy.isEnabled(action: item.action, windowIsLive: window != nil && window.isVisible)
    }
}
