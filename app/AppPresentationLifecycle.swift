// AppKit presentation lifecycle adapters: system sleep and window occlusion
// become independent inputs at the stable terminal-session boundary. Both feed
// the rendering gate only; pane visibility, which decides pixel ownership, is
// derived from the model alone.
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
                self?.runtime?.setSystemRenderingAvailable(false)
            },
            observeOnMain(
                NSWorkspace.didWakeNotification,
                center: notificationCenter
            ) { [weak self] in
                self?.runtime?.setSystemRenderingAvailable(true)
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
    /// Records whether the system is awake, then republishes the rendering gate.
    func setSystemRenderingAvailable(_ available: Bool) {
        guard schedulingLifecycle.isActive else { return }
        guard systemRenderingAvailable != available else { return }
        systemRenderingAvailable = available
        syncRenderingAvailable()
    }

    /// Pushes the rendering gate -- the system is awake and the window is not
    /// occluded -- to every live terminal session.
    ///
    /// Both inputs only suspend rendering. Neither one may reach `setVisible`,
    /// because a hidden pane gives up its layer contents and its buffers, and the
    /// window of an occluded app is still composited live by Mission Control and
    /// App Expose (research/41 T8 review).
    func syncRenderingAvailable() {
        guard schedulingLifecycle.isActive else { return }
        let windowVisible = window?.occlusionState.contains(.visible) ?? true
        let available = systemRenderingAvailable && windowVisible
        guard renderingAvailable != available else { return }
        renderingAvailable = available
        for host in paneHosts.values {
            host.session.setRenderingAvailable(available)
        }
    }

    /// Pushes model-derived pane visibility -- which decides pixel ownership -- to
    /// live terminal sessions.
    func syncPaneVisibility() {
        guard schedulingLifecycle.isActive else { return }
        let desired = effectivePaneVisibility(in: model)

        // Each record remembers what its own session was last told, so a pane installed
        // under a reused pane id starts from "nothing pushed yet" and there is no stale
        // entry left behind to prune.
        for (paneId, host) in paneHosts {
            let visible = desired[paneId] ?? true
            guard host.pushedVisibility != visible else { continue }
            #if DANTERM_TERMINAL_CHARACTERIZATION
            recordTerminalCharacterizationVisibilityChange(paneId: paneId, visible: visible)
            #endif
            host.session.setVisible(visible)
            host.pushedVisibility = visible
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

    // NSWindowDelegate: window occlusion suspends and resumes rendering. It never
    // touches pane visibility, so no pane releases its pixels behind a cover.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard notification.object is NSWindow else { return }
        #if DANTERM_TERMINAL_BENCHMARK
        benchmarkStateRecorder?.windowDidChangeOcclusionState()
        #endif
        runtime?.syncRenderingAvailable()
    }
}
