// UI-harness coverage for the pane's focus-ring gutter: the permanent inset
// ScrollableTerminalView reserves around the terminal area, the ring it draws
// inside that inset, and the theme background the gutter paints. Pointer and
// scrollbar routing for the same view live in their own suites.
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
            scrollbarEnabled: true, cellHeight: 0, scrollPosition: nil, background: themed))

        try uiExpect(fx.scrollWrapper.layer?.backgroundColor == themed,
                     "gutter did not follow the published background: "
                        + "\(String(describing: fx.scrollWrapper.layer?.backgroundColor))")
    }
}

// MARK: - Fixture

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
        scrollbarEnabled: true, cellHeight: 0, scrollPosition: nil, background: background)
    let wrapper = PaneWrapperView(
        paneId: paneId, terminalView: terminal,
        isZoomed: false, hasSplits: false, runtime: AppRuntime(model: model))
    wrapper.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    wrapper.layoutSubtreeIfNeeded()

    return GutterFixture(wrapper: wrapper, scrollWrapper: wrapper.scrollWrapper, terminal: terminal)
}
