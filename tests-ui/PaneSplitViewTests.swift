// UI-test runner entry point plus shared harness assertions and pane divider tests.
//
// The suite is one Swift Testing case that drives the whole `uiTest` runner below,
// not 386 separate `@Test` functions. That is deliberate for now: the port from the
// bespoke `swiftc` harness to a test target changed the packaging, and converting
// each case as well would have made a behavior regression indistinguishable from a
// conversion slip. Per-case conversion is the follow-up.
import Cocoa
import Testing
import ChipArtwork
import PaneProcessLifecycle
import TerminalCore
import TerminalPaneSession
import TerminalPTYHost
import TerminalRenderExecution
import TerminalRenderPlanning
@testable import DanTerm

enum UITestRunner {
    @Test("the AppKit UI suite")
    @MainActor
    static func run() async throws {
        // NSApplication must be initialized for NSSplitView layout to work
        let _ = NSApplication.shared

        await terminalBackendBoundaryTests()
        await appPresentationLifecycleTests()
        await danTermConfigStoreTests()
        await swiftTerminalSessionViewTests()
        await ioSurfaceLayerContentsTests()
        await paneDividerViewTests()
        await linkPreviewViewTests()
        await badgeLabelTests()
        await paneWrapperViewTests()
        await observeOnMainTests()
        await scrollableTerminalViewTests()
        await chipViewTests()
        await paneStripViewTests()
        await splitContainerViewTests()
        await menuCommandPolicyTests()
        await todoInputViewTests()
        await sidebarSelectionCacheTests()
        await sidebarScrollRevealTests()
        await sidebarRenameRecycleTests()
        await sidebarContextMenuTests()
        await sidebarProjectionRowTests()
        await menubarTabCloseTests()
        await menubarTabColorTests()
        await tabTodoPopoverViewTests()
        await themeBrowserViewTests()
        await remoteThemePickerSheetTests()
        await todoPopoverViewTests()
        await alertsPopoverViewTests()
        await preferencesPanelTests()
        await confirmationPanelTests()
        await noticePanelTests()
        await dialogActionRowTests()
        await singleLineLabelTests()

        print("\n\(uiTotal - uiFailures)/\(uiTotal) passed")
        // Each case already printed its own name and message on the way past, so the
        // count is the verdict; the printed log is where a failure is read.
        #expect(uiFailures == 0, "\(uiFailures) of \(uiTotal) UI cases failed")
    }
}

// MARK: - Test Harness

@MainActor var uiFailures = 0
@MainActor var uiTotal = 0

// The runner drives every UI test from `@MainActor main()`, and each body
// touches AppKit views, so the harness states that isolation instead of
// leaving each caller to re-declare it.
@MainActor
func uiTest(_ name: String, _ body: () async throws -> Void) async {
    uiTotal += 1
    do {
        try await body()
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

@MainActor
func paneDividerViewTests() async {
    print("PaneDividerView")

    await uiTest("divider exposes splitter accessibility from model layout") {
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

    await uiTest("divider drag reports one clamped ratio and never moves itself") {
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
        var changes: [(SplitId, SplitRatio)] = []
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
