// UI-test runner entry point plus shared harness assertions and pane divider tests.
import Cocoa

@main
struct UITestRunner {
    @MainActor
    static func main() {
        // NSApplication must be initialized for NSSplitView layout to work
        let _ = NSApplication.shared

        terminalBackendBoundaryTests()
        appPresentationLifecycleTests()
        danTermConfigStoreTests()
        swiftTerminalSessionViewTests()
        ioSurfaceLayerContentsTests()
        paneDividerViewTests()
        linkPreviewViewTests()
        paneWrapperViewTests()
        observeOnMainTests()
        scrollableTerminalViewTests()
        chipViewTests()
        paneStripViewTests()
        splitContainerViewTests()
        menuCommandPolicyTests()
        todoInputViewTests()
        sidebarSelectionCacheTests()
        sidebarScrollRevealTests()
        sidebarRenameRecycleTests()
        sidebarContextMenuTests()
        sidebarProjectionRowTests()
        tabTodoPopoverViewTests()
        themeBrowserViewTests()
        remoteThemePickerSheetTests()
        todoPopoverViewTests()
        alertsPopoverViewTests()
        preferencesPanelTests()
        confirmationPanelTests()
        singleLineLabelTests()

        print("\n\(uiTotal - uiFailures)/\(uiTotal) passed")
        if uiFailures > 0 { exit(1) }
    }
}

// MARK: - Test Harness

var uiFailures = 0
var uiTotal = 0

func uiTest(_ name: String, _ body: () throws -> Void) {
    uiTotal += 1
    do {
        try body()
        print("  \u{2713} \(name)")
    } catch let e as UITestFailure {
        print("  \u{2717} \(name): \(e.message)")
        uiFailures += 1
    } catch {
        print("  \u{2717} \(name): \(error)")
        uiFailures += 1
    }
}

struct UITestFailure: Error {
    let message: String
}

func uiExpect(_ condition: Bool, _ message: String = "assertion failed", file: String = #file, line: Int = #line) throws {
    guard condition else { throw UITestFailure(message: "\(message) (\(file):\(line))") }
}

// MARK: - Tests

func paneDividerViewTests() {
    print("PaneDividerView")

    uiTest("divider exposes splitter accessibility from model layout") {
        let splitId = SplitId()
        let divider = PaneDividerView(splitId: splitId)
        divider.apply(
            placement: PaneDividerPlacement(
                direction: .horizontal,
                splitBounds: PaneLayoutRect(x: 0, y: 0, width: 501, height: 300),
                firstChildBounds: PaneLayoutRect(x: 0, y: 0, width: 350, height: 300),
                frame: PaneLayoutRect(x: 350, y: 0, width: 1, height: 300),
                secondChildBounds: PaneLayoutRect(x: 351, y: 0, width: 150, height: 300),
                ratio: 0.7
            ),
            in: NSRect(x: 0, y: 0, width: 501, height: 300)
        )

        try uiExpect(divider.accessibilityRole() == .splitter, "divider role is not splitter")
        try uiExpect(divider.accessibilityOrientation() == .vertical,
            "side-by-side split should expose a vertical divider")
        try uiExpect((divider.accessibilityValue() as? NSNumber)?.doubleValue == 0.7,
            "divider accessibility value did not follow model layout")
    }

    uiTest("divider drag reports one clamped ratio and never moves itself") {
        let splitId = SplitId()
        let divider = PaneDividerView(splitId: splitId)
        divider.apply(
            placement: PaneDividerPlacement(
                direction: .horizontal,
                splitBounds: PaneLayoutRect(x: 0, y: 0, width: 501, height: 300),
                firstChildBounds: PaneLayoutRect(x: 0, y: 0, width: 250, height: 300),
                frame: PaneLayoutRect(x: 250, y: 0, width: 1, height: 300),
                secondChildBounds: PaneLayoutRect(x: 251, y: 0, width: 250, height: 300),
                ratio: 0.5
            ),
            in: NSRect(x: 0, y: 0, width: 501, height: 300)
        )
        let before = divider.frame
        var changes: [(SplitId, CGFloat)] = []
        divider.onRatioChanged = { changes.append(($0, $1)) }

        divider.drag(to: NSPoint(x: 20, y: 100))

        try uiExpect(changes.count == 1, "one drag event should report one ratio")
        try uiExpect(changes[0].0 == splitId && changes[0].1 == 0.2,
            "drag should report the shared 100pt clamp")
        try uiExpect(divider.frame == before, "divider moved before model layout returned")

        divider.resetToEvenSplit()
        try uiExpect(changes.last?.1 == 0.5, "double-click reset should report an even ratio")
        try uiExpect(divider.frame == before, "reset moved the divider directly")
    }
}
