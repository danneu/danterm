// AppKit presentation lifecycle adapters: system sleep and window occlusion
// become independent inputs at the stable terminal-session boundary.
import Cocoa

/// Owns the workspace notification tokens that suspend and resume terminal rendering.
@MainActor
final class WorkspaceLifecycleObserver {
    private weak var runtime: AppRuntime?
    private var notificationTokens: [NSObjectProtocol] = []
    private let notificationCenter: NotificationCenter

    init(
        runtime: AppRuntime,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.runtime = runtime
        self.notificationCenter = notificationCenter

        notificationTokens = [
            observeOnMain(
                NSWorkspace.willSleepNotification,
                center: notificationCenter
            ) { [weak self] in
                self?.runtime?.setRenderingAvailable(false)
            },
            observeOnMain(
                NSWorkspace.didWakeNotification,
                center: notificationCenter
            ) { [weak self] in
                self?.runtime?.setRenderingAvailable(true)
            },
        ]
    }

    /// Permanently disconnects workspace lifecycle callbacks from their runtime owner.
    func tearDown() {
        removeObservers()
    }

    // `isolated deinit` so the token list stays ordinary main-actor state. The list is
    // written from `init` and `tearDown()`, both main-actor, and a nonisolated deinit
    // could only reach it by declaring the race away.
    isolated deinit {
        removeObservers()
    }

    private func removeObservers() {
        for token in notificationTokens {
            notificationCenter.removeObserver(token)
        }
        notificationTokens.removeAll()
    }
}

@MainActor
extension AppRuntime {
    /// Pushes system rendering availability to every live terminal session.
    func setRenderingAvailable(_ available: Bool) {
        guard schedulingLifecycle.isActive else { return }
        guard renderingAvailable != available else { return }
        renderingAvailable = available
        for host in paneHosts.values {
            host.session.setRenderingAvailable(available)
        }
    }

    /// Pushes effective model and window visibility to live terminal sessions.
    func syncPaneVisibility() {
        guard schedulingLifecycle.isActive else { return }
        let windowVisible = window?.occlusionState.contains(.visible) ?? true
        let desired = effectivePaneVisibility(in: model, windowVisible: windowVisible)

        for (paneId, host) in paneHosts {
            let visible = desired[paneId] ?? true
            if paneVisibility[paneId] != visible {
                #if DANTERM_TERMINAL_CHARACTERIZATION
                recordTerminalCharacterizationVisibilityChange(paneId: paneId, visible: visible)
                #endif
                host.session.setVisible(visible)
                paneVisibility[paneId] = visible
            }
        }

        paneVisibility = paneVisibility.filter { paneId, _ in
            paneHosts[paneId] != nil
        }
    }
}

@MainActor
extension AppDelegate {
    /// Starts the app-lifetime workspace adapter after the runtime is available.
    func installWorkspaceLifecycleObserver(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        workspaceLifecycleObserver?.tearDown()
        workspaceLifecycleObserver = WorkspaceLifecycleObserver(
            runtime: runtime,
            notificationCenter: notificationCenter
        )
    }

    /// Disconnects workspace notifications before the application owner is torn down.
    func tearDownWorkspaceLifecycleObserver() {
        workspaceLifecycleObserver?.tearDown()
        workspaceLifecycleObserver = nil
    }

    // NSWindowDelegate: window occlusion changes alter every pane's effective
    // renderer visibility.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard notification.object is NSWindow else { return }
        #if DANTERM_TERMINAL_BENCHMARK
        benchmarkStateRecorder?.windowDidChangeOcclusionState()
        #endif
        runtime?.syncPaneVisibility()
    }
}
