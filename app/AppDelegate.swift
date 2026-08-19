// App delegate responsible for window setup, app lifecycle hooks, menus, and
// notification center delegation.
import Cocoa
@preconcurrency import UserNotifications

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSSplitViewDelegate, @preconcurrency UNUserNotificationCenterDelegate, WindowIndependentMenuActions {
    nonisolated static let minWindowWidth: CGFloat = 600
    nonisolated static let minWindowHeight: CGFloat = 300
    nonisolated static let minSidebarWidth: CGFloat = 200

    var window: NSWindow!
    var terminalBackend: SwiftTerminalBackend!
    var runtime: AppRuntime!
    var sidebarView: SidebarView!
    var contentArea: NSView!
    var splitView: NSSplitView!
    var chromeView: WindowChromeView!
    // Owned for the application lifetime; its teardown disconnects NSWorkspace callbacks.
    var workspaceLifecycleObserver: WorkspaceLifecycleObserver?
    var initSnapshot: AppModelSnapshot?
    var launchPolicy = AppLaunchPolicy(arguments: [])
    // Session recovery state set by main.swift before app launch.
    var lastSessionSnapshot: ValidatedAppRestore?  // merged + validated from Recovery/last-light.json + last-enriched.json
    var previousSessionCrashed: Bool = false     // true if session.json lock was still present
    #if DANTERM_TERMINAL_BENCHMARK
    private var benchmarkGeometryController: TerminalBenchmarkGeometryController?
    // AppPresentationLifecycle forwards occlusion into benchmark validity recording.
    var benchmarkStateRecorder: TerminalBenchmarkStateRecorder?
    #endif
    /// Set by the .terminate effect before calling NSApp.terminate to bypass the
    /// applicationShouldTerminate safety net (user already confirmed).
    var quitConfirmed = false

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
            tailnetOptIn: launchPolicy.tailnetOptIn
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

        // Write session lock (crash detection for next launch). Atomically
        // overwrites any stale lock from a previous crash, so there's no window
        // where a startup crash would lose the lock.
        writeSessionLockFile()

        // Clean up stale replay files from prior sessions
        runtime.cleanupStaleReplayDirectory()

        // Bootstrap startup: --init CLI > crash/clean restore prompt > fresh
        if let snapshot = initSnapshot {
            runtime.bootstrapFromSnapshot(snapshot)
            initSnapshot = nil
        } else if launchPolicy.startup == .promptForRecovery,
                  let lastSession = lastSessionSnapshot {
            // Prompt the user before restoring so they know what's coming.
            // Crash path gets a warning tone; clean exit is a neutral prompt.
            let summary = sessionSummary(lastSession)
            let alert = NSAlert()
            alert.addButton(withTitle: "Restore")
            let startFreshButton = alert.addButton(withTitle: "Start Fresh")
            // Enter activates "Restore" (first button = default). Bind Escape to
            // "Start Fresh" so dismissing the modal matches clicking it.
            startFreshButton.keyEquivalent = "\u{1b}"
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
                runtime.bootstrapFromValidatedRestore(lastSession)
            } else {
                runtime.send(.createTabInSelectedGroup())
            }
            lastSessionSnapshot = nil
        } else {
            runtime.send(.createTabInSelectedGroup())
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
        appMenu.addItem(withTitle: "Settings...", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        let openConfigItem = NSMenuItem(title: "Open DanTerm Config", action: #selector(openDanTermConfig(_:)), keyEquivalent: ",")
        openConfigItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(openConfigItem)
        let reloadConfigItem = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig(_:)), keyEquivalent: ",")
        reloadConfigItem.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(reloadConfigItem)
        appMenu.addItem(withTitle: "Install danterm Command in PATH", action: #selector(installDantermInPath(_:)), keyEquivalent: "")
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
        editMenu.addItem(withTitle: "Find Next", action: #selector(findNextInTerminal(_:)), keyEquivalent: "g")
        let findPreviousItem = NSMenuItem(title: "Find Previous", action: #selector(findPreviousInTerminal(_:)), keyEquivalent: "G")
        findPreviousItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(findPreviousItem)
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        // Theme browser sits on Cmd-Shift-B so the shortcut matches the menu noun.
        // Cmd-Shift-T is reserved for "New Tab at End of Group".
        let toggleThemeItem = NSMenuItem(title: "Toggle Theme Browser", action: #selector(toggleThemeBrowser(_:)), keyEquivalent: "B")
        toggleThemeItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(toggleThemeItem)

        // Font size zooms the focused pane only. AppKit matches key equivalents
        // against charactersIgnoringModifiers, so Cmd-Shift-= arrives as "+" and
        // plain Cmd-= as "="; one item cannot match both. The visible row binds
        // "+", and a hidden twin keeps "=" live without showing a second row.
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Increase Font Size", action: #selector(increasePaneFontSize(_:)), keyEquivalent: "+")
        let increaseEqualsItem = NSMenuItem(title: "Increase Font Size", action: #selector(increasePaneFontSize(_:)), keyEquivalent: "=")
        increaseEqualsItem.isHidden = true
        increaseEqualsItem.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(increaseEqualsItem)
        viewMenu.addItem(withTitle: "Decrease Font Size", action: #selector(decreasePaneFontSize(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(resetPaneFontSize(_:)), keyEquivalent: "0")

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Tab menu
        let tabMenuItem = NSMenuItem()
        let tabMenu = NSMenu(title: "Tab")
        tabMenu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        // Cmd-Shift-T appends to the current group, ignoring which tab is selected.
        let newTabAtEndItem = NSMenuItem(title: "New Tab at End of Group", action: #selector(newTabAtGroupEnd(_:)), keyEquivalent: "T")
        newTabAtEndItem.keyEquivalentModifierMask = [.command, .shift]
        tabMenu.addItem(newTabAtEndItem)
        tabMenu.addItem(withTitle: "New Group", action: #selector(newGroup(_:)), keyEquivalent: "n")

        let renameTabItem = NSMenuItem(title: "Rename Tab", action: #selector(renameTab(_:)), keyEquivalent: "R")
        renameTabItem.keyEquivalentModifierMask = [.command, .shift]
        tabMenu.addItem(renameTabItem)
        tabMenu.addItem(withTitle: "Clear Custom Title", action: #selector(clearCustomTitle(_:)), keyEquivalent: "")

        let nextTabItem = NSMenuItem(title: "Next Tab", action: #selector(nextTab(_:)), keyEquivalent: "N")
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        tabMenu.addItem(nextTabItem)

        let prevTabItem = NSMenuItem(title: "Previous Tab", action: #selector(prevTab(_:)), keyEquivalent: "P")
        prevTabItem.keyEquivalentModifierMask = [.command, .shift]
        tabMenu.addItem(prevTabItem)

        let jumpItem = NSMenuItem(title: "Jump to Tab...", action: #selector(jumpToTab(_:)), keyEquivalent: "f")
        jumpItem.keyEquivalentModifierMask = [.command, .shift]
        tabMenu.addItem(jumpItem)

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
        // Cmd-9, not Cmd-0: "Actual Size" in the View menu owns Cmd-0.
        colorSubmenu.addItem(withTitle: "Clear Color", action: #selector(clearTabColor(_:)), keyEquivalent: "9")
        colorItem.submenu = colorSubmenu
        tabMenu.addItem(colorItem)

        let clearTabAlertsItem = NSMenuItem(title: "Clear Tab Alerts", action: #selector(clearTabAlerts(_:)), keyEquivalent: ".")
        tabMenu.addItem(clearTabAlertsItem)

        let tabTodoItem = NSMenuItem(title: "Toggle To-do List", action: #selector(toggleTabTodoPopover(_:)), keyEquivalent: "'")
        tabTodoItem.keyEquivalentModifierMask = [.command]
        tabMenu.addItem(tabTodoItem)

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

        let zoomItem = NSMenuItem(title: "Toggle Zoom", action: #selector(toggleZoom(_:)), keyEquivalent: "\r")
        zoomItem.keyEquivalentModifierMask = [.command]
        paneMenu.addItem(zoomItem)

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

        let goToAlert = NSMenuItem(title: "Next Unread Alert", action: #selector(goToMostRecentAlertPane(_:)), keyEquivalent: "a")
        goToAlert.keyEquivalentModifierMask = [.command, .shift]
        paneMenu.addItem(goToAlert)

        let ackAlertItem = NSMenuItem(title: "Clear Pane Alerts", action: #selector(ackPaneAlerts(_:)), keyEquivalent: ".")
        ackAlertItem.keyEquivalentModifierMask = [.command, .shift]
        paneMenu.addItem(ackAlertItem)

        let todoItem = NSMenuItem(title: "Toggle To-do List", action: #selector(openTodo(_:)), keyEquivalent: "'")
        todoItem.keyEquivalentModifierMask = [.command, .shift]
        paneMenu.addItem(todoItem)

        paneMenu.addItem(NSMenuItem.separator())
        paneMenu.addItem(withTitle: "Close Pane", action: #selector(closePane(_:)), keyEquivalent: "w")

        paneMenuItem.submenu = paneMenu
        mainMenu.addItem(paneMenuItem)

        // Window menu. Per Apple HIG, app-specific menus (Tab/Pane) precede Window.
        // All three actions are AppKit built-ins dispatched through the responder
        // chain (target nil) to the key window / NSApp.
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        // Registering windowsMenu makes AppKit auto-append the live window list
        // (below a separator it inserts) and enables cmd-` window cycling. Only
        // windows with isExcludedFromWindowsMenu == false are listed, so auxiliary
        // panels opt out at their construction sites to keep the list to one entry.
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu Actions

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

    @objc func closeTab(_ sender: Any?) {
        guard let tabId = runtime.model.selectedTabId else { return }
        runtime.send(.requestCloseTab(id: tabId))
    }

    // Tab > Color submenu actions share the menubar batch router with
    // clear-custom-title and clear-tab-alert actions.
    @objc func setTabColorFromMenu(_ sender: NSMenuItem) {
        let colors = TabColor.allCases
        guard sender.tag >= 0, sender.tag < colors.count else { return }
        if let msg = menubarTabActionMsg(
            .setColor(colors[sender.tag]),
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
            let alert = NSAlert()
            alert.messageText = "danterm Installed"
            if outcome.usedAdministratorPrivileges {
                alert.informativeText = "Installed \(outcome.destinationURL.path) with administrator privileges."
            } else {
                alert.informativeText = "Installed \(outcome.destinationURL.path)."
            }
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Install Failed"
            alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
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
        runtime.toggleThemeBrowser()
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

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        MenuCommandPolicy.isEnabled(action: item.action, windowIsLive: window != nil && window.isVisible)
    }
}
