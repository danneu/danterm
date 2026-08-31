// Behavioral UI tests for model-owned sidebar divider and chrome presentation.
import Cocoa
@testable import DanTerm

@MainActor
func sidebarPresentationTests() async {
    print("SidebarPresentation")

    await uiTest("catalog toggle round trips through the model and restores width") {
        let fixture = sidebarPresentationFixture()
        fixture.runtime.model.sidebar = SidebarPresentation(isCollapsed: false, width: 280)
        fixture.runtime.reconcileSidebarPresentation()
        fixture.runtime.sentMessages = []
        installSidebarReducer(on: fixture.runtime)
        let menuItem = NSMenuItem()
        menuItem.representedObject = ConfigurableCommand.toggleSidebar

        fixture.delegate.performConfiguredCommand(menuItem)
        fixture.delegate.performConfiguredCommand(menuItem)

        try uiExpect(fixture.runtime.sentMessages.count == 2,
            "two catalog toggles should send two messages")
        try uiExpect(fixture.runtime.sentMessages.allSatisfy {
            if case .toggleSidebar = $0 { return true }
            return false
        }, "catalog toggle sent a non-sidebar message")
        try uiExpect(fixture.runtime.model.sidebar ==
            SidebarPresentation(isCollapsed: false, width: 280),
            "two catalog toggles did not preserve the model width")
        try uiExpect(fixture.delegate.sidebarView.frame.width == 280,
            "two catalog toggles did not restore the divider width")
    }

    await uiTest("chrome sidebar gesture sends the model message") {
        let fixture = sidebarPresentationFixture()

        fixture.delegate.chromeView.toggleButton.performClick(nil)

        try expectOnlyToggleSidebar(fixture.runtime)
    }

    await uiTest("reconcile restores saved width and originates no report") {
        let fixture = sidebarPresentationFixture()
        fixture.runtime.model.sidebar = SidebarPresentation(isCollapsed: false, width: 280)
        fixture.runtime.reconcileSidebarPresentation()

        try uiExpect(fixture.runtime.sentMessages.isEmpty,
            "applying the projection reported a sidebar message")
        try uiExpect(fixture.delegate.sidebarView.frame.width == 280,
            "expanded projection did not apply the saved width")
        try uiExpect(fixture.delegate.chromeView.sidebarSeparatorLeading == 280,
            "chrome separator did not follow the divider")
        try uiExpect(fixture.delegate.chromeView.sidebarTitleLeading == 288,
            "chrome title did not follow the divider")

        fixture.runtime.model.sidebar = SidebarPresentation(isCollapsed: true, width: 280)
        fixture.runtime.reconcileSidebarPresentation()
        try uiExpect(fixture.delegate.splitView.isSubviewCollapsed(fixture.delegate.sidebarView),
            "collapsed projection left the sidebar expanded")
        try uiExpect(fixture.delegate.chromeView.sidebarSeparatorLeading == 0,
            "collapsed chrome separator did not reach the leading edge")
        try uiExpect(fixture.delegate.chromeView.isSidebarTitleLeadingFromBell,
            "collapsed chrome title did not follow the bell")

        fixture.runtime.model.sidebar = SidebarPresentation(isCollapsed: false, width: 280)
        fixture.runtime.reconcileSidebarPresentation()
        try uiExpect(fixture.delegate.sidebarView.frame.width == 280,
            "reopening did not restore the saved expanded width")
        try uiExpect(fixture.runtime.sentMessages.isEmpty,
            "collapse or reopen reconciliation reported a sidebar message")
    }

    await uiTest("native resize reports complete sidebar presentation") {
        let fixture = sidebarPresentationFixture()
        fixture.runtime.model.sidebar = SidebarPresentation(isCollapsed: false, width: 280)
        fixture.runtime.reconcileSidebarPresentation()
        fixture.runtime.sentMessages = []

        fixture.delegate.splitViewDidResizeSubviews(
            Notification(name: NSSplitView.didResizeSubviewsNotification,
                         object: fixture.delegate.splitView)
        )

        try uiExpect(fixture.runtime.sentMessages.count == 1,
            "native resize should report one message")
        guard case .sidebarPresentationReported(let isCollapsed, let width) =
                fixture.runtime.sentMessages[0] else {
            throw UITestFailure(message: "native resize sent the wrong message")
        }
        try uiExpect(!isCollapsed && width == 280,
            "native resize did not report the observed presentation")

        fixture.delegate.splitView.setPosition(0, ofDividerAt: 0)
        fixture.runtime.sentMessages = []
        installSidebarReducer(on: fixture.runtime)
        fixture.delegate.splitViewDidResizeSubviews(
            Notification(name: NSSplitView.didResizeSubviewsNotification,
                         object: fixture.delegate.splitView)
        )
        try uiExpect(fixture.runtime.sentMessages.count == 1,
            "native collapse should report one message")
        guard case .sidebarPresentationReported(let collapsed, _) =
                fixture.runtime.sentMessages[0] else {
            throw UITestFailure(message: "native collapse sent the wrong message")
        }
        try uiExpect(collapsed, "native collapse did not report collapsed state")
        try uiExpect(fixture.runtime.model.sidebar ==
            SidebarPresentation(isCollapsed: true, width: 280),
            "native collapse did not preserve the saved model width")

        fixture.runtime.send(.toggleSidebar)
        try uiExpect(fixture.delegate.sidebarView.frame.width == 280,
            "pointer collapse round trip did not restore the saved width")
    }
}

@MainActor
private func sidebarPresentationFixture() -> (
    delegate: AppDelegate,
    runtime: RecordingAppRuntime
) {
    let runtime = makeUITestRuntime()
    let delegate = AppDelegate(
        instancePaths: runtime.instancePaths,
        configURL: uiTestAbsentConfigURL()
    )
    delegate.runtime = runtime
    delegate.chromeView = WindowChromeView()
    delegate.chromeView.toggleButton.target = delegate
    delegate.chromeView.toggleButton.action = #selector(AppDelegate.toggleSidebar(_:))
    delegate.splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    delegate.splitView.isVertical = true
    delegate.sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 200, height: 500))
    delegate.contentArea = NSView(frame: NSRect(x: 200, y: 0, width: 600, height: 500))
    delegate.splitView.addArrangedSubview(delegate.sidebarView)
    delegate.splitView.addArrangedSubview(delegate.contentArea)
    delegate.splitView.delegate = delegate
    delegate.sidebarView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    delegate.contentArea.setContentHuggingPriority(.defaultLow, for: .horizontal)
    runtime.sidebarPresentationSurface = delegate
    return (delegate, runtime)
}

@MainActor
private func expectOnlyToggleSidebar(_ runtime: RecordingAppRuntime) throws {
    try uiExpect(runtime.sentMessages.count == 1,
        "sidebar gesture should send exactly one message")
    guard case .toggleSidebar = runtime.sentMessages[0] else {
        throw UITestFailure(message: "sidebar gesture sent the wrong message")
    }
}

@MainActor
private func installSidebarReducer(on runtime: RecordingAppRuntime) {
    runtime.onSend = { [weak runtime] msg in
        guard let runtime else { return }
        var model = runtime.model
        _ = update(&model, msg)
        runtime.model = model
        runtime.reconcileSidebarPresentation()
    }
}
