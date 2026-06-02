// UI-test runner entry point plus shared harness assertions and pane split tests.
import Cocoa

@main
struct UITestRunner {
    static func main() {
        // NSApplication must be initialized for NSSplitView layout to work
        let _ = NSApplication.shared

        paneSplitViewTests()
        splitContainerViewTests()
        sidebarBadgeTests()
        todoInputViewTests()
        sidebarSelectionCacheTests()
        sidebarScrollRevealTests()

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

func paneSplitViewTests() {
    print("PaneSplitView")

    uiTest("isApplyingRatio guards splitViewDidResizeSubviews") {
        let splitId = SplitId()
        let splitView = PaneSplitView(splitId: splitId, ratio: 0.7)

        var ratioChangedCalls: [(SplitId, CGFloat)] = []
        splitView.onRatioChanged = { id, ratio in
            ratioChangedCalls.append((id, ratio))
        }

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = splitView

        let first = NSView()
        let second = NSView()
        first.translatesAutoresizingMaskIntoConstraints = true
        second.translatesAutoresizingMaskIntoConstraints = true
        splitView.addArrangedSubview(first)
        splitView.addArrangedSubview(second)

        // Set guard flag before giving the split view a frame (setting the
        // frame triggers splitViewDidResizeSubviews synchronously)
        splitView.isApplyingRatio = true
        splitView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        splitView.layoutSubtreeIfNeeded()

        // Guard should have prevented onRatioChanged from firing
        try uiExpect(ratioChangedCalls.isEmpty, "onRatioChanged should not fire while isApplyingRatio is true")
        // Ratio should be unchanged
        try uiExpect(splitView.ratio == 0.7, "ratio should remain 0.7, got \(splitView.ratio)")
    }

    uiTest("onRatioChanged fires when isApplyingRatio is false") {
        let splitId = SplitId()
        let splitView = PaneSplitView(splitId: splitId, ratio: 0.5)

        var ratioChangedCalls: [(SplitId, CGFloat)] = []
        splitView.onRatioChanged = { id, ratio in
            ratioChangedCalls.append((id, ratio))
        }

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = splitView

        let first = NSView()
        let second = NSView()
        first.translatesAutoresizingMaskIntoConstraints = true
        second.translatesAutoresizingMaskIntoConstraints = true
        splitView.addArrangedSubview(first)
        splitView.addArrangedSubview(second)

        splitView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        // No guard — simulate user drag
        splitView.isApplyingRatio = false
        splitView.setPosition(400, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()

        try uiExpect(!ratioChangedCalls.isEmpty, "onRatioChanged should fire when isApplyingRatio is false")
    }
}
