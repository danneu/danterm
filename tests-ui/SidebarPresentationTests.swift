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

    // Intent: any window size >= minSize is accepted from an in-process
    // setFrame and survives the next layout pass, with the sidebar keeping its
    // width and the content area absorbing the whole delta.
    // Why it exists: arranged subviews translating their autoresizing masks
    // into required constraints, with the split-view delegate attached only
    // after the first layout, pinned the window to its exact frame; every
    // resize path (AX, window managers, setFrame) was silently dropped.
    // Scenario: the live incident -- the main window stuck at its autosaved
    // 1728x1083 frame, immune to Raycast hotkeys and macOS tiling.
    await uiTest("window accepts shrink to minSize and grow; only content flexes") {
        let fixture = sidebarPresentationFixture()
        let window = fixture.delegate.window!
        // On screen, because only there does NSWindow enforce content
        // constraints on the window size -- the live symptom's path.
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        fixture.runtime.model.sidebar = SidebarPresentation(isCollapsed: false, width: 280)
        fixture.runtime.reconcileSidebarPresentation()
        window.layoutIfNeeded()
        let sidebarWidth = fixture.delegate.sidebarView.frame.width
        try uiExpect(sidebarWidth == 280, "fixture did not start at the applied sidebar width")

        // Shrink to minSize, then grow: compression constraints can block one
        // direction while the other works, so both are asserted.
        let shrunk = NSSize(width: AppDelegate.minWindowWidth, height: AppDelegate.minWindowHeight)
        let grown = NSSize(width: 1400, height: 900)
        for size in [shrunk, grown] {
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
            window.layoutIfNeeded()
            try uiExpect(window.frame.size == size,
                "resize to \(size) did not survive layout: \(window.frame.size)")
            try uiExpect(fixture.delegate.sidebarView.frame.width == sidebarWidth,
                "window resize changed the sidebar width to \(fixture.delegate.sidebarView.frame.width)")
            let splitView = fixture.delegate.splitView!
            let expectedContent = splitView.bounds.width - sidebarWidth - splitView.dividerThickness
            try uiExpect(fixture.delegate.contentArea.frame.width == expectedContent,
                "content area did not absorb the resize delta: "
                    + "\(fixture.delegate.contentArea.frame.width) vs \(expectedContent)")
        }
    }

    // Intent: a divider move through NSSplitView's public path reaches the
    // model as a report, without the test calling any delegate method.
    // Why it exists: proves the builder wires the split-view delegate; a
    // fixture that hand-wired the delegate could pass while production did not.
    // Scenario: spec-first.
    await uiTest("divider move through the split view reports presentation") {
        let fixture = sidebarPresentationFixture()
        fixture.runtime.model.sidebar = SidebarPresentation(isCollapsed: false, width: 280)
        fixture.runtime.reconcileSidebarPresentation()
        fixture.delegate.window.layoutIfNeeded()
        fixture.runtime.sentMessages = []

        fixture.delegate.splitView.setPosition(250, ofDividerAt: 0)
        fixture.delegate.window.layoutIfNeeded()

        let reportedWidths = fixture.runtime.sentMessages.compactMap { msg -> CGFloat? in
            guard case .sidebarPresentationReported(let isCollapsed, let width) = msg,
                  !isCollapsed else { return nil }
            return width
        }
        try uiExpect(reportedWidths.contains(250),
            "divider move did not report the new width: \(fixture.runtime.sentMessages)")
    }
}

// The production construction path: the shared content builder plus a window
// shaped like the real one (same style mask and minimum size, no autosave
// name so tests never touch the developer's saved frame).
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
    let content = makeMainWindowContent(
        chromeView: delegate.chromeView,
        splitViewDelegate: delegate
    )
    delegate.splitView = content.splitView
    delegate.sidebarView = content.sidebarView
    delegate.contentArea = content.contentArea
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.minSize = NSSize(width: AppDelegate.minWindowWidth, height: AppDelegate.minWindowHeight)
    window.contentView = content.rootView
    delegate.window = window
    runtime.sidebarPresentationSurface = delegate
    window.layoutIfNeeded()
    // Construction layout can emit split-view resize notifications; tests
    // assert from a settled, silent state.
    runtime.sentMessages = []
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
