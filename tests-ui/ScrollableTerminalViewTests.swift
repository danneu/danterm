// UI-harness coverage for the pane's focus-ring gutter -- the permanent inset
// ScrollableTerminalView reserves around the terminal area, the ring it draws
// inside that inset, and the theme background the gutter paints -- plus the
// scroll chrome the same view sizes from published session state. Pointer
// routing for the view lives in its own suite.
import Cocoa

@MainActor
func scrollableTerminalViewTests() {
    print("ScrollableTerminalView")

    uiTest("gutter is reserved on all four sides with no ring showing") {
        // Intent: the terminal area sits inset by 2pt on every side of the
        //   scroll wrapper, with no focus ring applied.
        // Why it exists: the ring is a CALayer border, which draws inward from
        //   the layer's bounds. Unless the space is reserved unconditionally,
        //   the ring paints over the outermost glyphs.
        let fx = makeGutterFixture()

        let grid = fx.gridRectInWrapper()
        let expected = fx.scrollWrapper.bounds.insetBy(dx: 2, dy: 2)
        try uiExpect(grid == expected,
                     "terminal area \(grid) is not the wrapper bounds inset by 2pt (\(expected))")
    }

    uiTest("gutter does not move when focus and alert state change") {
        // Intent: the terminal area's size and position are identical with the
        //   ring off, on for focus, on for an alert, and back off.
        // Why it exists: a gutter that appeared only while a ring showed would
        //   reflow the grid every time focus moved between panes.
        let fx = makeGutterFixture()
        let idle = fx.gridRectInWrapper()

        var seen: [CGRect] = []
        for (focused, bell) in [(true, false), (false, true), (false, false)] {
            fx.wrapper.setFocusRing(focused: focused, hasBell: bell)
            fx.wrapper.layoutSubtreeIfNeeded()
            seen.append(fx.gridRectInWrapper())
        }

        try uiExpect(seen.allSatisfy { $0 == idle },
                     "grid geometry moved with ring state: \(idle) then \(seen)")
        try uiExpect(idle.width == fx.scrollWrapper.bounds.width - 4
                        && idle.height == fx.scrollWrapper.bounds.height - 4,
                     "grid did not shrink by the gutter on both axes: \(idle)")
    }

    uiTest("ring never draws wider than the reserved gutter") {
        // Intent: the drawn border width fits inside the space the layout
        //   reserved for it, measured from the geometry rather than from the
        //   constant that produced it.
        // Why it exists: this is the invariant the whole gutter exists for. It
        //   fails if someone later changes the ring width or the inset without
        //   the other.
        let fx = makeGutterFixture()
        let reserved = (fx.scrollWrapper.bounds.width - fx.gridRectInWrapper().width) / 2
        try uiExpect(reserved > 0, "no gutter was reserved, so the check would be vacuous")

        fx.wrapper.setFocusRing(focused: true, hasBell: false)

        let drawn = fx.scrollWrapper.layer?.borderWidth ?? 0
        try uiExpect(drawn > 0, "focus ring was not drawn at all")
        try uiExpect(drawn <= reserved, "ring width \(drawn) exceeds the reserved gutter \(reserved)")
    }

    uiTest("ring color follows focus and alert state") {
        // Intent: focused is green, alerted-and-unfocused is red, idle is no
        //   ring, and focus wins when a focused pane also has an alert.
        // Why it exists: pins the precedence the projection feeds in, and pins
        //   that the terminal view's own layer never carries the border.
        let fx = makeGutterFixture()
        let cases: [(focused: Bool, bell: Bool, color: CGColor?)] = [
            (true, false, NSColor.systemGreen.cgColor),
            (false, true, NSColor.systemRed.cgColor),
            (false, false, nil),
            (true, true, NSColor.systemGreen.cgColor),
        ]

        for (focused, bell, color) in cases {
            fx.wrapper.setFocusRing(focused: focused, hasBell: bell)
            let layer = fx.scrollWrapper.layer
            if let color {
                try uiExpect(layer?.borderColor == color,
                             "focused=\(focused) bell=\(bell) drew \(String(describing: layer?.borderColor))")
                try uiExpect((layer?.borderWidth ?? 0) > 0, "focused=\(focused) bell=\(bell) drew no ring")
            } else {
                try uiExpect((layer?.borderWidth ?? 0) == 0,
                             "idle pane still draws a ring of width \(layer?.borderWidth ?? 0)")
            }
            try uiExpect((fx.terminal.layer?.borderWidth ?? 0) == 0,
                         "the terminal view's own layer carries a border for focused=\(focused) bell=\(bell)")
        }
    }

    uiTest("gutter paints the session background from construction and after a theme change") {
        // Intent: the gutter is the pane's terminal background at the moment
        //   the pane appears, and follows every later background the session
        //   publishes.
        // Why it exists: the gutter sits outside the terminal view, so it no
        //   longer inherits that view's theme-colored layer background. Without
        //   the construction-time read, a pane would show an unthemed frame
        //   until its first theme change.
        let initial = NSColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1).cgColor
        let fx = makeGutterFixture(background: initial)

        try uiExpect(fx.scrollWrapper.layer?.backgroundColor == initial,
                     "gutter did not take the session's initial background: "
                        + "\(String(describing: fx.scrollWrapper.layer?.backgroundColor))")

        let themed = NSColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1).cgColor
        fx.terminal.emitState(TerminalSessionState(
            scrollbarEnabled: true, cellHeight: nil,
            scrollPosition: .init(total: 24, offset: 0, length: 24), background: themed))

        try uiExpect(fx.scrollWrapper.layer?.backgroundColor == themed,
                     "gutter did not follow the published background: "
                        + "\(String(describing: fx.scrollWrapper.layer?.backgroundColor))")
    }

    uiTest("a pane with no layout metrics scrolls nowhere and sizes to the viewport") {
        // Intent: a session that has not laid out a grid yet gives its document
        //   view exactly the viewport height and leaves the scroll origin at rest.
        // Why it exists: missing layout metrics is the one absence the session
        //   boundary can express. This pins what the scroll chrome does with it,
        //   so the absence cannot quietly turn into a row offset computed from a
        //   zero-height cell.
        // Scenario: spec-first -- a pane mounts before its first frame lands.
        let fx = makeGutterFixture()
        let chrome = try scrollChrome(of: fx.scrollWrapper)

        fx.terminal.emitState(TerminalSessionState(
            scrollbarEnabled: true, cellHeight: nil,
            scrollPosition: .init(total: 40, offset: 10, length: 20),
            background: NSColor.black.cgColor))

        try uiExpect(fx.terminal.state.cellHeight == nil,
                     "the session published metrics, so the absence branch is untested")
        try uiExpect(chrome.documentView?.frame.height == chrome.contentSize.height,
                     "document height \(String(describing: chrome.documentView?.frame.height)) "
                        + "is not the viewport height \(chrome.contentSize.height)")
        try uiExpect(chrome.contentView.bounds.origin.y == 0,
                     "a pane without metrics scrolled to \(chrome.contentView.bounds.origin.y)")
    }

    uiTest("a pane with metrics sizes its document to scrollback and restores its row") {
        // Intent: with a cell height published, the document view spans the whole
        //   scrollback in pixels and the clip view sits at the row the session
        //   reports.
        // Why it exists: this is the whole job of the scroll chrome, and it is the
        //   branch a test double could previously bypass by reporting no scroll
        //   position at all.
        // Scenario: spec-first -- a pane 20 rows tall, scrolled 10 rows down into
        //   40 rows of history, at a 16pt cell.
        let fx = makeGutterFixture()
        let chrome = try scrollChrome(of: fx.scrollWrapper)
        let viewport = chrome.contentSize.height

        fx.terminal.emitState(TerminalSessionState(
            scrollbarEnabled: true, cellHeight: 16,
            scrollPosition: .init(total: 40, offset: 10, length: 20),
            background: NSColor.black.cgColor))

        let expectedHeight = 40 * 16.0 + (viewport - 20 * 16.0)
        try uiExpect(chrome.documentView?.frame.height == expectedHeight,
                     "document height \(String(describing: chrome.documentView?.frame.height)) "
                        + "is not \(expectedHeight) for 40 rows at a 16pt cell")
        // AppKit measures Y from the bottom, so row 10 of 40 with 20 visible sits
        // 10 rows up from the document's bottom edge.
        try uiExpect(chrome.contentView.bounds.origin.y == 10 * 16.0,
                     "clip view sits at \(chrome.contentView.bounds.origin.y), not row 10's 160pt")
    }
}

// MARK: - Fixture

/// The pane's scroll chrome, found the way AppKit itself reaches it -- by walking the
/// wrapper's subviews -- so the scroll assertions do not depend on the wrapper's
/// private storage.
@MainActor
private func scrollChrome(of wrapper: ScrollableTerminalView) throws -> NSScrollView {
    guard let chrome = wrapper.subviews.compactMap({ $0 as? NSScrollView }).first else {
        throw UITestFailure(message: "the pane wrapper hosts no scroll view")
    }
    return chrome
}

@MainActor
private struct GutterFixture {
    let wrapper: PaneWrapperView
    let scrollWrapper: ScrollableTerminalView
    let terminal: TerminalView

    /// The terminal area's rect in the scroll wrapper's own coordinates, which is
    /// what the gutter is an inset of. Reading it through `convert` keeps the
    /// assertions blind to the scroll view and document view in between.
    func gridRectInWrapper() -> CGRect {
        scrollWrapper.convert(terminal.hostView.bounds, from: terminal.hostView)
    }
}

@MainActor
private func makeGutterFixture(
    background: CGColor = NSColor.black.cgColor
) -> GutterFixture {
    let paneId = PaneId()
    let node = SplitNodeModel.leaf(PaneModel(id: paneId, session: SessionModel(id: SessionId())))
    let tab = TabModel(id: TabId(), customTitle: nil, paneTree: PaneTree(root: node, focusedPaneId: paneId))
    let group = GroupModel(id: GroupId(), name: "g", tabs: [tab])
    var model = AppModel(groups: [group])
    model.selectedTabId = tab.id

    let terminal = TerminalView()
    // Layer-backed so "the terminal view's own layer carries no ring" is a real
    // reading of a real layer rather than a nil-coalesced default.
    terminal.wantsLayer = true
    terminal.state = TerminalSessionState(
        scrollbarEnabled: true, cellHeight: nil,
        scrollPosition: .init(total: 24, offset: 0, length: 24), background: background)
    let wrapper = PaneWrapperView(
        paneId: paneId, terminalView: terminal,
        runtime: AppRuntime(model: model))
    wrapper.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    wrapper.layoutSubtreeIfNeeded()

    return GutterFixture(wrapper: wrapper, scrollWrapper: wrapper.scrollWrapper, terminal: terminal)
}
