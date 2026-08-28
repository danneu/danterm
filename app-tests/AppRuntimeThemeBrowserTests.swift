// Behavioral coverage for the runtime-owned theme browser reconcile pass.
import Cocoa
import Testing
@testable import DanTerm

/// Proves that model transitions alone create, remove, layer, and tear down the browser.
@MainActor
struct AppRuntimeThemeBrowserTests {
    @Test("the toggle message creates and removes the theme browser")
    func toggleCreatesAndRemovesBrowser() throws {
        let runtime = makeCommandTestRuntime(RecordingAppRuntimePorts())
        defer { runtime.shutdown() }
        let contentArea = makeContentArea()
        runtime.contentArea = contentArea

        runtime.bootstrapFromTestSnapshot(makeCommandSnapshot(paneId: PaneId(rawValue: UUID())))
        runtime.send(.toggleThemeBrowser)

        _ = try #require(contentArea.subviews.first { $0 is ThemeBrowserView })

        runtime.send(.toggleThemeBrowser)

        #expect(contentArea.subviews.contains { $0 is ThemeBrowserView } == false)
    }

    @Test("a restore removes an open theme browser and the next sweep keeps it absent")
    func restoreRemovesBrowser() throws {
        let runtime = makeCommandTestRuntime(RecordingAppRuntimePorts())
        defer { runtime.shutdown() }
        let contentArea = makeContentArea()
        runtime.contentArea = contentArea

        runtime.bootstrapFromTestSnapshot(makeCommandSnapshot(paneId: PaneId(rawValue: UUID())))
        runtime.send(.toggleThemeBrowser)
        _ = try #require(contentArea.subviews.first { $0 is ThemeBrowserView })

        runtime.bootstrapFromTestSnapshot(makeCommandSnapshot(paneId: PaneId(rawValue: UUID())))
        #expect(contentArea.subviews.contains { $0 is ThemeBrowserView } == false)

        runtime.reconcile()
        #expect(contentArea.subviews.contains { $0 is ThemeBrowserView } == false)
    }

    @Test("the theme browser stays above existing and newly built tab containers")
    func browserStaysAboveTabContainers() throws {
        let runtime = makeCommandTestRuntime(RecordingAppRuntimePorts())
        defer { runtime.shutdown() }
        let contentArea = makeContentArea()
        runtime.contentArea = contentArea

        runtime.bootstrapFromTestSnapshot(makeCommandSnapshot(paneId: PaneId(rawValue: UUID())))
        runtime.send(.toggleThemeBrowser)
        contentArea.layoutSubtreeIfNeeded()

        let point = NSPoint(x: 700, y: 300)
        try expectThemeBrowserHit(in: contentArea, at: point)

        runtime.send(.createTabInSelectedGroup())
        contentArea.layoutSubtreeIfNeeded()

        try expectThemeBrowserHit(in: contentArea, at: point)
    }
}

/// Builds the retained content host used by the runtime's AppKit reconcile passes.
@MainActor
private func makeContentArea() -> NSView {
    NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
}

/// Asserts the behavioral z-order contract through hit testing rather than sibling order.
@MainActor
private func expectThemeBrowserHit(in contentArea: NSView, at point: NSPoint) throws {
    var hit = try #require(contentArea.hitTest(point))
    while let superview = hit.superview, hit is ThemeBrowserView == false {
        hit = superview
    }
    #expect(hit is ThemeBrowserView)
}
