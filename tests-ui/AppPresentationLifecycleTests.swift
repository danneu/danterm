// Integration tests for AppKit lifecycle and occlusion forwarding into terminal sessions.
import Cocoa

@MainActor
func appPresentationLifecycleTests() {
    print("AppPresentationLifecycle")

    uiTest("workspace sleep and wake reach sessions until observer teardown") {
        let runtime = AppRuntime()
        let paneId = PaneId()
        let session = TerminalView()
        runtime.sessions[paneId] = session
        let delegate = AppDelegate()
        delegate.runtime = runtime
        let center = NSWorkspace.shared.notificationCenter

        delegate.installWorkspaceLifecycleObserver(notificationCenter: center)
        center.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        center.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)

        try uiExpect(
            session.renderingAvailability == [false, true],
            "workspace lifecycle should reach the terminal-session availability seam"
        )

        delegate.tearDownWorkspaceLifecycleObserver()
        center.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        try uiExpect(
            session.renderingAvailability == [false, true],
            "workspace callbacks should be inert after observer teardown"
        )
    }

    uiTest("window occlusion reaches session visibility and reveals once") {
        let runtime = AppRuntime()
        let paneId = PaneId()
        let tabId = TabId()
        let groupId = GroupId()
        let session = TerminalView()
        let pane = PaneModel(id: paneId)
        let tab = TabModel(id: tabId, customTitle: nil, paneTree: PaneTree(root: .leaf(pane), focusedPaneId: paneId))
        runtime.model = AppModel(
            groups: [GroupModel(id: groupId, name: "General", tabs: [tab])]
        )
        runtime.model.selectedTabId = tabId
        runtime.sessions[paneId] = session
        let window = PresentationLifecycleTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        runtime.window = window
        let delegate = AppDelegate()
        delegate.runtime = runtime

        window.reportedOcclusionState = []
        delegate.windowDidChangeOcclusionState(
            Notification(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        )
        window.reportedOcclusionState = [.visible]
        delegate.windowDidChangeOcclusionState(
            Notification(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        )

        try uiExpect(session.visibility == [false, true], "occlusion should reach setVisible")
        try uiExpect(session.revealCount == 1, "restoring visibility should request one reveal")
    }
}

private final class PresentationLifecycleTestWindow: NSWindow {
    var reportedOcclusionState: NSWindow.OcclusionState = []

    override var occlusionState: NSWindow.OcclusionState {
        reportedOcclusionState
    }
}
