// Integration tests for AppKit lifecycle and occlusion forwarding into terminal sessions.
import Cocoa
import ChipArtwork
import PaneProcessLifecycle
import TerminalCore
import TerminalPaneSession
import TerminalPTYHost
import TerminalRenderExecution
import TerminalRenderPlanning
@testable import DanTerm

@MainActor
func appPresentationLifecycleTests() async {
    print("AppPresentationLifecycle")

    await uiTest("workspace sleep and wake reach sessions until observer teardown") {
        let runtime = makeUITestRuntime()
        let paneId = PaneId()
        let session = FakeTerminalSession()
        runtime.installTerminalSession(session, paneId: paneId)
        let delegate = AppDelegate(
            instancePaths: runtime.instancePaths, configURL: uiTestAbsentConfigURL())
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

    await uiTest("window occlusion gates rendering and never releases a pane's pixels") {
        // Intent: an occluded window stops every live pane from rendering and leaves
        //   pane visibility untouched, so no pane gives up its layer contents or its
        //   buffers; uncovering the window makes rendering available again.
        // Why it exists: research/41 T8 made a hidden pane release its pixels, and
        //   `setVisible` was fed by model visibility and occlusion together. A window
        //   the user covers would then blank every pane, which Mission Control and App
        //   Expose composite live -- the user would see bare background.
        // Scenario: a selected single-pane tab in a window that is covered and then
        //   uncovered.
        let paneId = PaneId()
        let tabId = TabId()
        let groupId = GroupId()
        let session = FakeTerminalSession()
        let pane = PaneModel(id: paneId)
        let tab = TabModel(id: tabId, customTitle: nil, paneTree: PaneTree(root: .leaf(pane), focusedPaneId: paneId))
        let runtime = makeUITestRuntime(model: AppModel(
            groups: [GroupModel(id: groupId, name: "General", tabs: [tab])],
            selectedTabId: tabId
        ))
        runtime.installTerminalSession(session, paneId: paneId)
        let window = PresentationLifecycleTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        runtime.window = window
        let delegate = AppDelegate(
            instancePaths: runtime.instancePaths, configURL: uiTestAbsentConfigURL())
        delegate.runtime = runtime

        window.reportedOcclusionState = []
        delegate.windowDidChangeOcclusionState(
            Notification(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        )
        window.reportedOcclusionState = [.visible]
        delegate.windowDidChangeOcclusionState(
            Notification(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        )

        try uiExpect(
            session.renderingAvailability == [false, true],
            "occlusion should reach the rendering seam: \(session.renderingAvailability)"
        )
        try uiExpect(
            session.visibility.isEmpty,
            "occlusion pushed pane visibility and released the pane's pixels: "
                + "\(session.visibility)"
        )
    }

    await uiTest("deselecting a tab hides its pane while the window stays visible") {
        // Intent: model visibility alone decides whether a pane owns pixels, so
        //   selecting the other tab hides the first pane and reveals the second.
        // Why it exists: the memory win of research/41 T8 is that unselected tabs
        //   release their surfaces. Moving occlusion off `setVisible` must not take
        //   that with it.
        // Scenario: two tabs in one visible window, with the selection moved to the
        //   second tab.
        let firstPaneId = PaneId()
        let secondPaneId = PaneId()
        let firstTabId = TabId()
        let secondTabId = TabId()
        let groupId = GroupId()
        let firstSession = FakeTerminalSession()
        let secondSession = FakeTerminalSession()
        let firstTab = TabModel(
            id: firstTabId, customTitle: nil,
            paneTree: PaneTree(root: .leaf(PaneModel(id: firstPaneId)), focusedPaneId: firstPaneId))
        let secondTab = TabModel(
            id: secondTabId, customTitle: nil,
            paneTree: PaneTree(root: .leaf(PaneModel(id: secondPaneId)), focusedPaneId: secondPaneId))
        let runtime = makeUITestRuntime(model: AppModel(
            groups: [GroupModel(id: groupId, name: "General", tabs: [firstTab, secondTab])],
            selectedTabId: firstTabId
        ))
        runtime.installTerminalSession(firstSession, paneId: firstPaneId)
        runtime.installTerminalSession(secondSession, paneId: secondPaneId)
        let window = PresentationLifecycleTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.reportedOcclusionState = [.visible]
        runtime.window = window

        runtime.syncPaneVisibility()
        try uiExpect(
            firstSession.visibility == [true] && secondSession.visibility == [false],
            "the initial push did not follow the selection: "
                + "\(firstSession.visibility) \(secondSession.visibility)"
        )

        runtime.model.selectedTabId = secondTabId
        runtime.syncPaneVisibility()

        try uiExpect(
            firstSession.visibility == [true, false],
            "the deselected tab's pane kept its pixels: \(firstSession.visibility)"
        )
        try uiExpect(
            secondSession.visibility == [false, true],
            "the selected tab's pane was not revealed: \(secondSession.visibility)"
        )
    }
}

private final class PresentationLifecycleTestWindow: NSWindow {
    var reportedOcclusionState: NSWindow.OcclusionState = []

    override var occlusionState: NSWindow.OcclusionState {
        reportedOcclusionState
    }
}
