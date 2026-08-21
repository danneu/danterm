// UI-harness tests for PaneWrapperView's whole toolbar rendering and unified
// pane context menu: replacement semantics, menu composition and routing, and
// menu-lifetime retention of the ephemeral wrapper.
import Cocoa
import DanTermProtocol

@MainActor
func paneWrapperViewTests() {
    print("PaneWrapperView")

    uiTest("includeClipboard menu has full composition, all enabled") {
        // Intent: the terminal right-click menu (includeClipboard: true) is the
        //   toolbar menu plus a Copy/Paste clipboard section on top, with every
        //   item enabled when the pane has a selection, cwd, agent session, and
        //   splits.
        // Why it exists: pins the unified-menu contract -- one builder serves
        //   all three entry points and only the terminal entry point gets
        //   clipboard items. Spec-first.
        let fx = makePaneMenuFixture()
        fx.terminal.hasSelection = true

        let menu = fx.wrapper.makePaneMenu(includeClipboard: true)

        let items = nonSeparatorItems(menu)
        try uiExpect(
            items.map(\.title) == [
                "Copy", "Paste", "Split Right", "Split Down",
                "Copy cwd", "Copy Pane ID", "Copy Agent Session ID",
                "Zoom Pane", "Close Pane",
            ],
            "unexpected titles: \(items.map(\.title))")
        try uiExpect(items.allSatisfy(\.isEnabled), "all items should be enabled, got \(items.map { ($0.title, $0.isEnabled) })")
    }

    uiTest("includeClipboard menu disables Copy without a selection") {
        // Intent: without a terminal selection, Copy is present but disabled,
        //   and the menu's shape (item count) is identical to the with-selection
        //   menu.
        // Why it exists: pins the user decision that Copy is disabled rather
        //   than hidden, so the terminal menu's shape is stable. The old inline
        //   terminal menu hid Copy entirely. Spec-first.
        let fx = makePaneMenuFixture()
        fx.terminal.hasSelection = true
        let withSelectionCount = fx.wrapper.makePaneMenu(includeClipboard: true).items.count

        fx.terminal.hasSelection = false
        let menu = fx.wrapper.makePaneMenu(includeClipboard: true)

        let copy = try onlyItem(menu, titled: "Copy")
        try uiExpect(!copy.isEnabled, "Copy should be disabled without a selection")
        try uiExpect(menu.items.count == withSelectionCount,
                     "menu shape should be selection-independent: \(menu.items.count) vs \(withSelectionCount)")
    }

    uiTest("toolbar menu has no clipboard items") {
        // Intent: includeClipboard: false and the no-arg default both produce
        //   today's toolbar menu composition, with no Copy/Paste items.
        // Why it exists: pins that the toolbar "..." button and drag-handle
        //   right-click menus are unchanged by the unification. Spec-first.
        let fx = makePaneMenuFixture()
        fx.terminal.hasSelection = true

        let expectedTitles = [
            "Split Right", "Split Down",
            "Copy cwd", "Copy Pane ID", "Copy Agent Session ID",
            "Zoom Pane", "Close Pane",
        ]
        for menu in [fx.wrapper.makePaneMenu(includeClipboard: false), fx.wrapper.makePaneMenu()] {
            let items = nonSeparatorItems(menu)
            try uiExpect(items.map(\.title) == expectedTitles, "unexpected titles: \(items.map(\.title))")
        }
    }

    uiTest("menu actions route to the clicked pane and its terminal") {
        // Intent: performing menu items dispatches the right effects -- Copy and
        //   Paste act on the pane's terminal view; Split Right, Close Pane, and
        //   Zoom send pane-scoped messages carrying this pane's id.
        // Why it exists: pins behavioral routing (not target/selector identity),
        //   including that Zoom is pane-scoped (.toggleZoomPane(paneId:)) so a
        //   stale menu acts on the pane it was built for, not whatever tab is
        //   selected when the action fires. Spec-first.
        let fx = makePaneMenuFixture()
        fx.terminal.hasSelection = true
        let menu = fx.wrapper.makePaneMenu(includeClipboard: true)

        for title in ["Copy", "Paste", "Split Right", "Zoom Pane", "Close Pane"] {
            let item = try onlyItem(menu, titled: title)
            _ = item.target?.perform(item.action, with: item)
        }

        try uiExpect(fx.terminal.performedActions == ["copySelection", "pasteClipboard"],
                     "clipboard items should act on the terminal, got \(fx.terminal.performedActions)")
        var sawSplit = false, sawZoom = false, sawClose = false
        for msg in fx.runtime.sentMessages {
            switch msg {
            case .splitPane(let paneId, let direction, _, _):
                sawSplit = paneId == fx.paneId && direction == .horizontal
            case .toggleZoomPane(let paneId):
                sawZoom = paneId == fx.paneId
            case .requestClosePane(let paneId):
                sawClose = paneId == fx.paneId
            default:
                break
            }
        }
        try uiExpect(sawSplit, "Split Right should send .splitPane(paneId:, .horizontal)")
        try uiExpect(sawZoom, "Zoom should send .toggleZoomPane(paneId:) scoped to this pane")
        try uiExpect(sawClose, "Close Pane should send .requestClosePane(paneId:)")
    }

    uiTest("model-dependent items follow pane state") {
        // Intent: a pane with no cwd gets a disabled Copy cwd item; a pane with
        //   no agent session gets no Copy Agent Session ID item at all.
        // Why it exists: pins the two model-driven item states on the unified
        //   menu's terminal entry point (previously toolbar-menu-only behavior).
        //   Spec-first.
        let fx = makePaneMenuFixture(cwd: nil, agentSession: nil)

        let menu = fx.wrapper.makePaneMenu(includeClipboard: true)

        let copyCwd = try onlyItem(menu, titled: "Copy cwd")
        try uiExpect(!copyCwd.isEnabled, "Copy cwd should be disabled when the pane has no cwd")
        try uiExpect(menu.items.allSatisfy { $0.title != "Copy Agent Session ID" },
                     "agent session item should be absent when the pane has no agent session")
    }

    uiTest("agent menu visibility and copied id follow the session model") {
        let agent = AgentSession(kind: "claude", sessionId: "snapshot-session")!
        let fx = makePaneMenuFixture(agentSession: agent)
        fx.wrapper.menuPasteboard = NSPasteboard(
            name: .init("com.danterm.tests.agent-session.\(UUID().uuidString)")
        )

        let attachedMenu = fx.wrapper.makePaneMenu(includeClipboard: true)
        let copy = try onlyItem(attachedMenu, titled: "Copy Agent Session ID")
        _ = copy.target?.perform(copy.action, with: copy)
        try uiExpect(
            fx.wrapper.menuPasteboard.string(forType: .string) == "snapshot-session",
            "copied id should come from the session model"
        )

        let sessionId = fx.runtime.model.pane(fx.paneId)!.session!.id
        fx.runtime.model.updateSession(sessionId) {
            reduceSession(&$0, report: .agentDetached(agent))
        }
        let detachedMenu = fx.wrapper.makePaneMenu(includeClipboard: true)
        try uiExpect(
            detachedMenu.items.allSatisfy { $0.title != "Copy Agent Session ID" },
            "agent item should disappear after the snapshot detaches"
        )
    }

    uiTest("Copy Pane ID copies the wrapper's full pane UUID") {
        let fx = makePaneMenuFixture()
        fx.wrapper.menuPasteboard = NSPasteboard(
            name: .init("com.danterm.tests.pane-id.\(UUID().uuidString)")
        )

        let menu = fx.wrapper.makePaneMenu(includeClipboard: true)
        let copy = try onlyItem(menu, titled: "Copy Pane ID")
        _ = copy.target?.perform(copy.action, with: copy)

        try uiExpect(
            fx.wrapper.menuPasteboard.string(forType: .string) == fx.paneId.rawValue.uuidString,
            "Copy Pane ID should copy the pane represented by this menu"
        )
    }

    uiTest("zoom item reflects zoom and split state") {
        // Intent: a single-pane unzoomed wrapper shows a disabled "Zoom Pane";
        //   a zoomed wrapper shows an enabled "Unzoom Pane".
        // Why it exists: pins the zoom affordance states on the unified menu
        //   so the terminal right-click matches the toolbar menu. Spec-first.
        let single = makePaneMenuFixture(isZoomed: false, hasSplits: false)
        let zoomItem = try onlyItem(single.wrapper.makePaneMenu(includeClipboard: true), titled: "Zoom Pane")
        try uiExpect(!zoomItem.isEnabled, "Zoom Pane should be disabled with no splits and not zoomed")

        let zoomed = makePaneMenuFixture(isZoomed: true, hasSplits: true)
        let unzoomItem = try onlyItem(zoomed.wrapper.makePaneMenu(includeClipboard: true), titled: "Unzoom Pane")
        try uiExpect(unzoomItem.isEnabled, "Unzoom Pane should be enabled while zoomed")
    }

    uiTest("an unrendered wrapper exposes neutral zoom affordances") {
        // Intent: wrapper construction claims no zoom or split fact before its
        //   first toolbar render.
        // Why it exists: constructor booleans used to make a wrapper look
        //   rendered before reconciliation had applied a projection.
        // Scenario: spec-first staged host construction before reconciliation.
        let model = makeSinglePaneModel(hasSplits: true)
        let wrapper = PaneWrapperView(
            paneId: model.paneId,
            terminalView: TerminalView(),
            runtime: AppRuntime(model: model.model)
        )
        wrapper.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        wrapper.layoutSubtreeIfNeeded()

        let zoomButton = try paneZoomButton(in: wrapper)
        try uiExpect(zoomButtonWidth(zoomButton) < 1, "an unrendered wrapper should collapse zoom")
        let zoomItem = try onlyItem(wrapper.makePaneMenu(), titled: "Zoom Pane")
        try uiExpect(!zoomItem.isEnabled, "an unrendered wrapper should disable Zoom Pane")
    }

    uiTest("persistent wrapper zoom affordances follow toolbar projection") {
        // Intent: one wrapper changes its menu and its zoom button as the tab
        //   moves through single-pane, split, zoomed, and single-pane states.
        //   The button is present exactly while the pane is zoomed or its tab
        //   has splits.
        // Why it exists: those values were immutable construction inputs before
        //   wrapper lifetime moved up to the runtime, and the button used to be
        //   an exit from zoom only, so a split pane had no toolbar way in.
        // Scenario: the incremental-container reconciliation performance fix.
        let fx = makePaneMenuFixture(isZoomed: false, hasSplits: false)
        fx.wrapper.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        fx.wrapper.layoutSubtreeIfNeeded()
        let zoomButton = try paneZoomButton(in: fx.wrapper)
        try uiExpect(
            zoomButtonWidth(zoomButton) < 1,
            "a lone pane should collapse the button below one point, got \(zoomButton.frame.width)")

        fx.wrapper.applyToolbarRender(paneToolbarRender(hasSplits: true))
        let split = try onlyItem(fx.wrapper.makePaneMenu(), titled: "Zoom Pane")
        try uiExpect(split.isEnabled, "projected splits should enable Zoom Pane")
        try uiExpect(
            zoomButtonWidth(zoomButton) >= 15,
            "a split pane should show the button at at least 15 points, got \(zoomButton.frame.width)")

        fx.wrapper.applyToolbarRender(paneToolbarRender(isZoomed: true, hasSplits: true))
        let unzoom = try onlyItem(fx.wrapper.makePaneMenu(), titled: "Unzoom Pane")
        try uiExpect(unzoom.isEnabled, "projected zoom should enable Unzoom Pane")
        try uiExpect(
            zoomButtonWidth(zoomButton) >= 15,
            "zoomed toolbar should keep the button at at least 15 points, got \(zoomButton.frame.width)")

        fx.wrapper.applyToolbarRender(paneToolbarRender())
        let zoom = try onlyItem(fx.wrapper.makePaneMenu(), titled: "Zoom Pane")
        try uiExpect(!zoom.isEnabled, "projected single-pane state should disable Zoom Pane")
        try uiExpect(
            zoomButtonWidth(zoomButton) < 1,
            "closing back down to one pane should collapse the button again")
    }

    uiTest("a neutral whole render clears every populated toolbar field") {
        // Intent: applying one complete render replaces every toolbar field,
        //   including nil, false, and zero values in the next render.
        // Why it exists: partial-update defaults could preserve stale chrome
        //   whenever a caller omitted the field that needed to clear.
        // Scenario: spec-first whole-render replacement.
        let fx = makePaneMenuFixture(isZoomed: false, hasSplits: false)
        fx.wrapper.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        fx.wrapper.applyToolbarRender(paneToolbarRender(
            label: "busy",
            progress: .indeterminate,
            isRemote: true,
            remoteLabel: "remote",
            agentLabel: "agent",
            chipTooltip: "agent session 123",
            chipKind: .agent,
            unreadAlertCount: 4,
            totalTodoCount: 5,
            uncompletedTodoCount: 3,
            isZoomed: true,
            hasSplits: true,
            isGridClaimed: true
        ))

        fx.wrapper.applyToolbarRender(paneToolbarRender())
        fx.wrapper.layoutSubtreeIfNeeded()

        let descendants = paneWrapperDescendants(of: fx.wrapper)
        let visibleText = descendants.compactMap { view -> String? in
            guard let field = view as? NSTextField, !field.isHidden else { return nil }
            return field.stringValue
        }
        try uiExpect(visibleText.contains("Terminal"), "the neutral label should replace the populated label")
        for stale in ["busy", "remote", "agent", "4", "3"] {
            try uiExpect(!visibleText.contains(stale), "neutral render left visible toolbar text \(stale)")
        }
        guard let progress = descendants.compactMap({ $0 as? ProgressIndicatorView }).first else {
            throw UITestFailure(message: "missing progress indicator")
        }
        try uiExpect(progress.isHidden, "neutral render should hide progress")
        guard let chip = descendants.compactMap({ $0 as? ChipView }).first else {
            throw UITestFailure(message: "missing pane chip")
        }
        try uiExpect(chip.kind == .terminal, "neutral render should restore the terminal chip")
        try uiExpect(chip.toolTip == nil, "neutral render should clear the chip tooltip")
        let zoomButton = try paneZoomButton(in: fx.wrapper)
        try uiExpect(zoomButtonWidth(zoomButton) < 1, "neutral render should collapse zoom")
        let zoomItem = try onlyItem(fx.wrapper.makePaneMenu(), titled: "Zoom Pane")
        try uiExpect(!zoomItem.isEnabled, "neutral render should disable zoom")
        let releaseButton = descendants.compactMap { $0 as? PaneToolbarButton }
            .first { $0.toolTip == "Release Claimed Size" }
        try uiExpect(releaseButton?.isHidden == true, "neutral render should hide grid take-back")
    }

    uiTest("a render offered before its wrapper exists is retried unchanged") {
        // Intent: a reconcile with no wrapper does not record the desired
        //   toolbar render as applied.
        // Why it exists: the runtime cache used to advance even when optional
        //   wrapper lookup failed, so the later wrapper never received the
        //   unchanged value.
        // Scenario: spec-first session host appears after the chrome pass.
        let model = makeSinglePaneModel(cwd: nil, hasSplits: false)
        let runtime = AppRuntime(model: model.model)
        let desired = desiredPaneToolbar(in: runtime.model)
        var wrapper: PaneWrapperView?

        offerPaneToolbarRenders(desired) { _ in wrapper }
        wrapper = PaneWrapperView(
            paneId: model.paneId,
            terminalView: TerminalView(),
            runtime: runtime
        )
        offerPaneToolbarRenders(desired) { _ in wrapper }

        guard let wrapper else {
            throw UITestFailure(message: "missing wrapper after construction")
        }
        let visibleText = paneWrapperDescendants(of: wrapper).compactMap { view -> String? in
            guard let field = view as? NSTextField, !field.isHidden else { return nil }
            return field.stringValue
        }
        try uiExpect(visibleText.contains("Terminal"), "the retried render should reach the new wrapper")
    }

    uiTest("the zoom button states which direction the next click goes") {
        // Intent: tooltip, accessibility description, and accent fill all flip
        //   with the projected zoom state, in both directions, on the one
        //   persistent button.
        // Why it exists: one button now carries both directions, so its
        //   appearance is the only thing telling the user whether a click
        //   enters zoom or leaves it. Spec-first.
        let fx = makePaneMenuFixture(isZoomed: false, hasSplits: true)
        fx.wrapper.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        fx.wrapper.layoutSubtreeIfNeeded()
        let zoomButton = try paneZoomButton(in: fx.wrapper)
        let accent = NSColor.controlAccentColor.cgColor

        try uiExpect(zoomButton.toolTip == "Zoom Pane", "got \(zoomButton.toolTip ?? "nil")")
        try uiExpect(
            zoomButton.image?.accessibilityDescription == "Zoom pane",
            "got \(zoomButton.image?.accessibilityDescription ?? "nil")")
        try uiExpect(
            zoomButton.layer?.backgroundColor != accent,
            "a split pane's button should not wear the accent fill")

        fx.wrapper.applyToolbarRender(paneToolbarRender(isZoomed: true, hasSplits: true))
        try uiExpect(zoomButton.toolTip == "Unzoom Pane", "got \(zoomButton.toolTip ?? "nil")")
        try uiExpect(
            zoomButton.image?.accessibilityDescription == "Unzoom pane",
            "got \(zoomButton.image?.accessibilityDescription ?? "nil")")
        try uiExpect(
            zoomButton.layer?.backgroundColor == accent,
            "a zoomed pane's button should wear the accent fill")

        fx.wrapper.applyToolbarRender(paneToolbarRender(hasSplits: true))
        try uiExpect(zoomButton.toolTip == "Zoom Pane", "the tooltip should flip back")
        try uiExpect(
            zoomButton.image?.accessibilityDescription == "Zoom pane",
            "the accessibility description should flip back")
        try uiExpect(
            zoomButton.layer?.backgroundColor != accent,
            "the accent fill should come back off")
    }

    uiTest("the take-back affordance follows the projected claim and clears it in one click") {
        // Intent: the button appears exactly while the toolbar projection reports
        //   a claimed grid, and one click sends the clear for this pane.
        // Why it exists: a claimed grid is durable -- no Mac layout event ends it
        //   -- so the pane must carry a visible one-gesture exit, and the exit has
        //   to name the pane the user clicked.
        // Scenario: spec-first -- the phone claims a pane at its own size and the
        //   user takes the pane back at the Mac.
        let fx = makePaneMenuFixture(isZoomed: false, hasSplits: false)
        fx.wrapper.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        fx.wrapper.layoutSubtreeIfNeeded()
        guard let releaseButton = paneWrapperDescendants(of: fx.wrapper)
            .compactMap({ $0 as? PaneToolbarButton })
            .first(where: { $0.toolTip == "Release Claimed Size" }) else {
            throw UITestFailure(message: "missing take-back button")
        }
        try uiExpect(
            releaseButton.frame.width < 1,
            "an unclaimed pane should collapse the button below one point, got \(releaseButton.frame.width)")

        fx.wrapper.applyToolbarRender(paneToolbarRender(isGridClaimed: true))
        releaseButton.superview?.needsLayout = true
        releaseButton.superview?.layoutSubtreeIfNeeded()

        try uiExpect(
            releaseButton.frame.width >= 15,
            "a claimed pane should show the button, got \(releaseButton.frame.width)")
        try uiExpect(!releaseButton.isHidden, "a claimed pane should not hide the button")

        _ = releaseButton.target?.perform(releaseButton.action, with: releaseButton)

        var sawClear = false
        for msg in fx.runtime.sentMessages {
            if case .clearPaneGridOverride(let paneId) = msg, paneId == fx.paneId { sawClear = true }
        }
        try uiExpect(sawClear, "the take-back click should clear this pane's override")

        fx.wrapper.applyToolbarRender(paneToolbarRender())
        releaseButton.superview?.needsLayout = true
        releaseButton.superview?.layoutSubtreeIfNeeded()

        try uiExpect(
            releaseButton.frame.width < 1,
            "a released pane should collapse the button again, got \(releaseButton.frame.width)")
    }

    uiTest("menu keeps the wrapper alive and actions still fire after teardown") {
        // Intent: a built menu strongly retains the ephemeral wrapper, so its
        //   actions still dispatch after a reconcile releases the wrapper while
        //   the menu is tracking.
        // Why it exists: NSMenuItem.target is weak; without a strong anchor a
        //   reconcile mid-track deallocates the wrapper and every action becomes
        //   a silent no-op (latent in the old toolbar menu too). Spec-first.
        // The wrapper is constructed and released inside an autoreleasepool:
        // AppKit init paths routinely autorelease view references, and without
        // draining them the wrapper would survive anyway and the pre-fix run
        // would silently pass.
        let model = makeSinglePaneModel()
        let runtime = AppRuntime(model: model.model)
        let terminal = TerminalView()
        var menu: NSMenu?
        weak var observer: PaneWrapperView?

        autoreleasepool {
            let wrapper = PaneWrapperView(
                paneId: model.paneId, terminalView: terminal, runtime: runtime)
            wrapper.applyToolbarRender(paneToolbarRender(hasSplits: true))
            observer = wrapper
            menu = wrapper.makePaneMenu(includeClipboard: true)
        }

        try uiExpect(observer != nil, "menu items should be retaining the wrapper after the pool drains")
        guard let menu else { throw UITestFailure(message: "menu missing") }
        let close = try onlyItem(menu, titled: "Close Pane")
        _ = close.target?.perform(close.action, with: close)
        var sawClose = false
        for msg in runtime.sentMessages {
            if case .requestClosePane(let paneId) = msg, paneId == model.paneId { sawClose = true }
        }
        try uiExpect(sawClose, "Close Pane should still dispatch after the wrapper's owner released it")
    }

    uiTest("every pane-menu entry point outlines its pane while the menu tracks") {
        // Intent: each of the three menus the wrapper builds -- the terminal
        //   right-click, the "..." toolbar button, and the drag-handle
        //   right-click -- mounts the outline when it opens and removes it when
        //   it closes.
        // Why it exists: a pane is a plain NSView, so AppKit gives it none of
        //   the outline it draws for a right-clicked table row, and a menu
        //   straddling two panes gives no sign which pane it acts on. Building
        //   the outline in the shared builder is what keeps the three entry
        //   points from drifting apart. Spec-first.
        let fx = makePaneMenuFixture()
        fx.wrapper.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        fx.wrapper.layoutSubtreeIfNeeded()
        guard let dragHandle = paneWrapperDescendants(of: fx.wrapper)
            .compactMap({ $0 as? ToolbarDragHandleView }).first else {
            throw UITestFailure(message: "missing drag handle")
        }
        guard let rightClick = NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
        else {
            throw UITestFailure(message: "could not synthesize a right-click event")
        }

        let entryPoints: [(String, () -> NSMenu?)] = [
            ("terminal right-click", { fx.wrapper.makePaneMenu(includeClipboard: true) }),
            ("toolbar button", { fx.wrapper.makePaneMenu() }),
            ("drag-handle right-click", { dragHandle.menu(for: rightClick) }),
        ]
        for (name, build) in entryPoints {
            guard let menu = build() else { throw UITestFailure(message: "\(name) should yield a menu") }
            try uiExpect(!paneIsOutlined(fx.wrapper), "\(name): building a menu should not outline the pane yet")

            menu.delegate?.menuWillOpen?(menu)
            try uiExpect(paneIsOutlined(fx.wrapper), "\(name): an open menu should outline its pane")

            menu.delegate?.menuDidClose?(menu)
            try uiExpect(!paneIsOutlined(fx.wrapper), "\(name): a closed menu should leave no outline")
        }
    }

    uiTest("the outline changes neither pane layout nor hit testing") {
        // Intent: mounting and unmounting the outline leaves every laid-out
        //   subview frame in the pane identical, and leaves the same view
        //   answering a hit test in the terminal area.
        // Why it exists: the outline is a full-bounds overlay on top of the
        //   pane. If it took part in layout it would reflow the grid on every
        //   right-click, and if it answered hit tests it would swallow the
        //   clicks that dismiss the menu. Spec-first.
        let fx = makePaneMenuFixture()
        fx.wrapper.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        fx.wrapper.layoutSubtreeIfNeeded()
        let point = NSPoint(x: 250, y: 150)
        let framesBefore = paneWrapperDescendants(of: fx.wrapper).map(\.frame)
        let hitBefore = fx.wrapper.hitTest(point)

        let menu = fx.wrapper.makePaneMenu(includeClipboard: true)
        menu.delegate?.menuWillOpen?(menu)
        fx.wrapper.layoutSubtreeIfNeeded()

        try uiExpect(paneIsOutlined(fx.wrapper), "precondition: the menu should have mounted the outline")
        let framesDuring = paneWrapperDescendants(of: fx.wrapper)
            .filter { !($0 is PaneContextMenuOutlineView) }.map(\.frame)
        try uiExpect(framesDuring == framesBefore,
                     "the outline should not move any subview: \(framesDuring) vs \(framesBefore)")
        try uiExpect(fx.wrapper.hitTest(point) === hitBefore,
                     "the outline should answer no hit test, got \(String(describing: fx.wrapper.hitTest(point)))")

        menu.delegate?.menuDidClose?(menu)
        fx.wrapper.layoutSubtreeIfNeeded()

        let framesAfter = paneWrapperDescendants(of: fx.wrapper).map(\.frame)
        try uiExpect(framesAfter == framesBefore,
                     "removing the outline should restore every frame: \(framesAfter) vs \(framesBefore)")
        try uiExpect(fx.wrapper.hitTest(point) === hitBefore, "removing the outline should restore hit testing")
    }

    uiTest("the outline draws a ring at its edge and leaves the pane content clear") {
        // Intent: drawing the outline paints along its border and paints
        //   nothing in the middle.
        // Why it exists: the ring is handed to AppKit's focus-ring machinery
        //   rather than stroked by hand, so this code names no color and the
        //   mount/unmount tests would pass just as well against a view that
        //   draws nothing at all. This is the assertion that the outline is
        //   visible, and that it stays a ring rather than covering the grid.
        //   Spec-first.
        let size = NSSize(width: 200, height: 120)
        let outline = PaneContextMenuOutlineView(frame: NSRect(origin: .zero, size: size))
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { throw UITestFailure(message: "could not make a bitmap to draw into") }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        outline.draw(outline.bounds)
        NSGraphicsContext.restoreGraphicsState()

        // Any pixel along the left border: the ring AppKit draws lies outside
        // the inset path, so it covers the strip this samples.
        let edgeAlpha = (0..<6).compactMap { rep.colorAt(x: $0, y: Int(size.height) / 2)?.alphaComponent }
        try uiExpect(edgeAlpha.contains { $0 > 0.1 },
                     "the outline should paint along its border, got alphas \(edgeAlpha)")
        let centerAlpha = rep.colorAt(x: Int(size.width) / 2, y: Int(size.height) / 2)?.alphaComponent ?? 1
        try uiExpect(centerAlpha < 0.01,
                     "the outline should leave the pane content clear, got alpha \(centerAlpha)")
    }
}

/// True while the wrapper is showing the context-menu outline.
@MainActor
private func paneIsOutlined(_ wrapper: PaneWrapperView) -> Bool {
    paneWrapperDescendants(of: wrapper).contains { $0 is PaneContextMenuOutlineView }
}

/// Returns every descendant used to inspect private wrapper affordances behaviorally.
private func paneWrapperDescendants(of root: NSView) -> [NSView] {
    root.subviews.flatMap { [$0] + paneWrapperDescendants(of: $0) }
}

// MARK: - Fixtures

private struct PaneMenuFixture {
    let wrapper: PaneWrapperView
    let runtime: AppRuntime
    let terminal: TerminalView
    let paneId: PaneId
}

/// One group / one tab / one pane-under-test (plus a sibling leaf when
/// hasSplits) so model-driven items (Copy cwd, agent session) see real state.
private func makeSinglePaneModel(
    cwd: String? = "/tmp/project",
    hasSplits: Bool = true
) -> (model: AppModel, paneId: PaneId) {
    let paneId = PaneId()
    var pane = PaneModel(id: paneId, session: SessionModel(id: SessionId()))
    pane.session?.cwd = cwd

    let rootNode: SplitNodeModel = hasSplits
        ? .split(id: SplitId(), direction: .horizontal,
                 first: .leaf(pane),
                 second: .leaf(PaneModel(id: PaneId(), session: SessionModel(id: SessionId()))),
                 ratio: 0.5)
        : .leaf(pane)
    let tab = TabModel(id: TabId(), customTitle: nil, paneTree: PaneTree(root: rootNode, focusedPaneId: paneId))
    let group = GroupModel(id: GroupId(), name: "g", tabs: [tab])
    var model = AppModel(groups: [group])
    model.selectedTabId = tab.id
    return (model, paneId)
}

@MainActor
private func makePaneMenuFixture(
    cwd: String? = "/tmp/project",
    agentSession: AgentSession? = AgentSession(kind: "claude", sessionId: "abc123"),
    isZoomed: Bool = false,
    hasSplits: Bool = true
) -> PaneMenuFixture {
    let (model, paneId) = makeSinglePaneModel(cwd: cwd, hasSplits: hasSplits)
    let runtime = AppRuntime(model: model)
    let terminal = TerminalView()
    if let agentSession, let sessionId = runtime.model.pane(paneId)?.session?.id {
        runtime.model.updateSession(sessionId) {
            reduceSession(&$0, report: .agentAttached(agentSession))
        }
    }
    let wrapper = PaneWrapperView(
        paneId: paneId, terminalView: terminal, runtime: runtime)
    wrapper.applyToolbarRender(paneToolbarRender(isZoomed: isZoomed, hasSplits: hasSplits))
    return PaneMenuFixture(wrapper: wrapper, runtime: runtime, terminal: terminal, paneId: paneId)
}

/// Finds the wrapper's one zoom button by identifier. The tooltip states the
/// direction of the next click, so it is not a stable handle.
@MainActor
private func paneZoomButton(in wrapper: PaneWrapperView) throws -> PaneToolbarButton {
    guard let button = paneWrapperDescendants(of: wrapper)
        .compactMap({ $0 as? PaneToolbarButton })
        .first(where: { $0.identifier == PaneWrapperView.zoomButtonIdentifier }) else {
        throw UITestFailure(message: "missing persistent zoom button")
    }
    return button
}

/// Lays the toolbar out before reading the button's width, so the assertion
/// sees the constraint the last render set rather than the old frame.
@MainActor
private func zoomButtonWidth(_ button: PaneToolbarButton) -> CGFloat {
    button.superview?.needsLayout = true
    button.superview?.layoutSubtreeIfNeeded()
    return button.frame.width
}

private func nonSeparatorItems(_ menu: NSMenu) -> [NSMenuItem] {
    menu.items.filter { !$0.isSeparatorItem }
}

private func onlyItem(_ menu: NSMenu, titled title: String) throws -> NSMenuItem {
    let matches = menu.items.filter { $0.title == title }
    try uiExpect(matches.count == 1, "expected exactly one \"\(title)\" item, got \(matches.count)")
    return matches[0]
}

/// Supplies neutral values for fields a test does not exercise while keeping
/// the `PaneToolbarRender` initializer exhaustive in one shared UI fixture.
func paneToolbarRender(
    label: DisplayLine = "Terminal",
    progress: ProgressState? = nil,
    isRemote: Bool = false,
    remoteLabel: DisplayLine? = nil,
    agentLabel: DisplayLine? = nil,
    chipTooltip: DisplayLine? = nil,
    chipKind: ChipKind = .terminal,
    unreadAlertCount: Int = 0,
    totalTodoCount: Int = 0,
    uncompletedTodoCount: Int = 0,
    isZoomed: Bool = false,
    hasSplits: Bool = false,
    isGridClaimed: Bool = false
) -> PaneToolbarRender {
    PaneToolbarRender(
        label: label,
        progress: progress,
        isRemote: isRemote,
        remoteLabel: remoteLabel,
        agentLabel: agentLabel,
        chipTooltip: chipTooltip,
        chipKind: chipKind,
        unreadAlertCount: unreadAlertCount,
        totalTodoCount: totalTodoCount,
        uncompletedTodoCount: uncompletedTodoCount,
        isZoomed: isZoomed,
        hasSplits: hasSplits,
        isGridClaimed: isGridClaimed
    )
}
