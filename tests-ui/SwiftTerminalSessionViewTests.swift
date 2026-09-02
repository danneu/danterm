// UI-harness coverage for native pointer, wheel, copy, and scrollbar routing in the Swift pane.
import Cocoa
import CoreGraphics
import DanTermProtocol
import Darwin
import PaneProcessLifecycle
import ChipArtwork
import TerminalCore
import TerminalPaneSession
import TerminalPTYHost
import TerminalRenderExecution
import TerminalRenderPlanning
@testable import DanTerm

@MainActor private var retainedSwiftPaneWindows: [NSWindow] = []

@MainActor
func swiftTerminalSessionViewTests() async {
    print("SwiftTerminalSessionView")

    await uiTest("search commands route through the Swift pane controller") {
        // Intent: every search entry point reaches the engine controller with its semantic input.
        // Why it exists: the real view gained search routing while the UI controller shim stayed
        //   incomplete, preventing the harness from compiling and leaving this adapter untested.
        // Scenario: the user types a needle, navigates both ways, clears it, and closes.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller)
        var events: [TerminalSessionEvent] = []
        pane.onEvent = { events.append($0) }

        pane.setSearchNeedle("needle")
        pane.navigateSearch(.next)
        pane.navigateSearch(.previous)
        pane.setSearchNeedle("")
        pane.endSearch()

        try uiExpect(events.isEmpty, "search routing must not report events back: \(events)")
        try uiExpect(controller.searchQueries == ["needle"],
                     "search needle routing diverged: \(controller.searchQueries)")
        try uiExpect(controller.searchNextRequests == 1, "next search was not routed once")
        try uiExpect(controller.searchPreviousRequests == 1, "previous search was not routed once")
        try uiExpect(controller.clearSearchRequests == 2,
                     "empty needle and end did not both clear search")
    }

    await uiTest("theme application resolves names and falls back to dark") {
        // Intent: complete themes apply while every unresolved name reaches the dark fallback.
        // Why it exists: hand-edited catalog misses must never retain stale pane colors.
        // Scenario: a user applies a valid theme, two invalid names, then clears the override.
        let controller = FakeTerminalPaneSessionController()
        let resolved = RenderTheme(defaultBackground: .init(red: 12, green: 34, blue: 56))
        let pane = makeTestPane(
            controller: controller,
            resolveTheme: { $0 == "Known" ? resolved : nil }
        )

        pane.applyTheme("Known")
        pane.applyTheme("Missing")
        pane.applyTheme("../Known")
        pane.clearTheme()

        try uiExpect(
            controller.appliedThemes.map(\.defaultBackground) == [
                // Construction applies the pane's config theme, which this resolver misses.
                RenderTheme.dark.defaultBackground,
                resolved.defaultBackground,
                RenderTheme.dark.defaultBackground,
                RenderTheme.dark.defaultBackground,
                RenderTheme.dark.defaultBackground,
            ],
            "theme dispatch changed on failed resolution: \(controller.appliedThemes)"
        )
    }

    await uiTest("session state carries the theme background and republishes on a theme change") {
        // Intent: `state.background` is the pane's current terminal default
        //   background before any theme is applied, and a theme swap pushes a
        //   fresh state to the observer carrying the new one.
        // Why it exists: the focus-ring gutter lives outside this view and takes
        //   its color off this channel. Without the construction-time value a
        //   pane shows an unthemed gutter until its first theme change; without
        //   the emit on `applyTheme`, it never catches up at all.
        let controller = FakeTerminalPaneSessionController()
        let themed = RenderTheme(defaultBackground: .init(red: 12, green: 34, blue: 56))
        let pane = makeTestPane(
            controller: controller,
            resolveTheme: { $0 == "Known" ? themed : nil }
        )
        let observer = SwiftPaneStateObserver()
        pane.stateObserver = observer

        let dark = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        try uiExpect(pane.state.background == dark,
                     "initial state did not carry the dark default background: \(pane.state.background)")

        pane.applyTheme("Known")

        let expected = CGColor(red: 12 / 255, green: 34 / 255, blue: 56 / 255, alpha: 1)
        try uiExpect(pane.state.background == expected,
                     "state did not follow the applied theme: \(pane.state.background)")
        try uiExpect(observer.states.last?.background == expected,
                     "theme change published no state to the observer: \(observer.states.count) states")
    }

    await uiTest("input method rect follows the published cursor cell") {
        // Intent: the input method anchor occupies the visible cursor's displayed cell box.
        // Why it exists: a zero-width top-left anchor pins IME candidates and the Emoji picker
        //   to the pane corner instead of placing them under the terminal cursor.
        // Scenario: spec-first -- a two-column cursor is visible at column 3, row 4.
        let cursor = uiTestCursor(row: 4, column: 3, columnWidth: 2)
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(
                defaultBackground: RenderTheme.dark.defaultBackground,
                cursor: cursor
            )
        )
        let pane = makeTestPane(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(pane, frame: pane.frame)
        guard let window = pane.window,
              let cellSize = pane.presentationGeometryForTesting?.cellSize
        else {
            throw UITestFailure(message: "the mounted pane resolved no presentation geometry")
        }

        let screenRect = pane.firstRect(
            forCharacterRange: NSRange(location: 0, length: 0),
            actualRange: nil
        )
        let viewRect = pane.convert(window.convertFromScreen(screenRect), from: nil)
        let expected = NSRect(
            x: CGFloat(cursor.column) * cellSize.width,
            y: CGFloat(cursor.row) * cellSize.height,
            width: CGFloat(cursor.columnWidth) * cellSize.width,
            height: cellSize.height
        )

        try uiExpect(viewRect == expected,
                     "input method rect did not follow the cursor: \(viewRect), expected \(expected)")
    }

    await uiTest("hidden cursor keeps the input method fallback rect") {
        // Intent: a frame with no visible cursor uses the established top-left placeholder.
        // Why it exists: cursor hiding removes the only terminal-owned anchor; stale cursor
        //   geometry must not keep an IME candidate window attached to a cursor that is gone.
        // Scenario: the child has applied CSI ?25l, so its published frame has no cursor.
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = makeTestPane(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(pane, frame: pane.frame)
        guard let window = pane.window,
              let cellHeight = pane.presentationGeometryForTesting?.cellSize.height
        else {
            throw UITestFailure(message: "the mounted pane resolved no presentation geometry")
        }

        let screenRect = pane.firstRect(
            forCharacterRange: NSRange(location: 0, length: 0),
            actualRange: nil
        )
        let viewRect = pane.convert(window.convertFromScreen(screenRect), from: nil)

        try uiExpect(viewRect == NSRect(x: 0, y: 0, width: 0, height: cellHeight),
                     "hidden cursor changed the input method fallback rect: \(viewRect)")
    }

    await uiTest("font size updates live cell metrics and reports the resized PTY grid") {
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller, fontSize: 13)
        pane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(pane, frame: pane.frame)

        let atThirteen = uiTestMetrics(fontSize: 13)
        let atTwentySix = uiTestMetrics(fontSize: 26)
        try uiExpect(
            controller.gridDimensions.last == expectedGrid(paneSize: pane.frame.size, metrics: atThirteen),
            "initial configured font did not size the PTY grid")

        pane.setFont(PaneFont(size: 26))

        try uiExpect(
            controller.gridDimensions.last == expectedGrid(paneSize: pane.frame.size, metrics: atTwentySix),
            "live font change did not resize the PTY grid")
        try uiExpect(pane.state.cellHeight == atTwentySix.cellSize.height,
                     "live font change did not update cell metrics")
    }

    await uiTest("font family updates live cell metrics and resizes the PTY grid") {
        // Intent: a resolved family handed to a live pane re-derives cell geometry and
        //   the grid the child process is told about.
        // Why it exists: the family reaches panes the same way the font size does, so
        //   without this the reconciler could push a family that never leaves the view.
        // Scenario: spec-first -- the user picks a new font family in Preferences and
        //   saves; open panes must repaint on the new grid with no reload.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller, fontSize: 13)
        pane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(pane, frame: pane.frame)

        let beforeFamily = controller.gridDimensions.last
        pane.setFont(PaneFont(family: UITestFontFamily.wide, size: 13))

        let wide = uiTestMetrics(fontSize: 13, fontFamily: UITestFontFamily.wide)
        try uiExpect(
            controller.gridDimensions.last == expectedGrid(paneSize: pane.frame.size, metrics: wide),
            "live family change did not resize the PTY grid")
        try uiExpect(controller.gridDimensions.last != beforeFamily,
                     "the family change left the grid where it was")
    }

    await uiTest("a family without usable metrics falls back to system monospace") {
        // Intent: a family that passes availability but cannot yield grid metrics still
        //   leaves the pane with valid metrics and grid dimensions, both at creation and
        //   on a live change away from a working family.
        // Why it exists: an unusable configured face must fall back to system monospace;
        //   synchronizePresentation used to bail outright on nil metrics, leaving a new pane
        //   blank and freezing an existing pane on its old grid until restart.
        // Scenario: spec-first -- an installed but degenerate face named in config.
        let created = FakeTerminalPaneSessionController()
        let createdPane = makeTestPane(
            controller: created,
            fontSize: 13,
            fontFamily: UITestFontFamily.unusable
        )
        createdPane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(createdPane, frame: createdPane.frame)

        // The fallback face is the one a pane with no configured family uses, so the
        // claim is stated against that pane's own geometry rather than a fixed cell box.
        let fallback = uiTestMetrics(fontSize: 13)
        try uiExpect(
            created.gridDimensions.last == expectedGrid(paneSize: createdPane.frame.size, metrics: fallback),
            "an unusable configured family left a new pane without geometry")
        try uiExpect(createdPane.state.cellHeight == fallback.cellSize.height,
                     "an unusable configured family left a new pane without cell metrics")

        let live = FakeTerminalPaneSessionController()
        let livePane = makeTestPane(
            controller: live,
            fontSize: 13,
            fontFamily: UITestFontFamily.wide
        )
        livePane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(livePane, frame: livePane.frame)
        let wide = uiTestMetrics(fontSize: 13, fontFamily: UITestFontFamily.wide)
        try uiExpect(
            live.gridDimensions.last == expectedGrid(paneSize: livePane.frame.size, metrics: wide),
            "the working family did not size the grid before the fallback case")

        livePane.setFont(PaneFont(family: UITestFontFamily.unusable, size: 13))

        try uiExpect(
            live.gridDimensions.last == expectedGrid(paneSize: livePane.frame.size, metrics: fallback),
                     "an unusable family froze an existing pane on its old grid")
    }

    await uiTest("an unclaimed pane follows a move between displays of different scale") {
        // Intent: a pane whose window reaches a display of a different backing scale
        //   resolves metrics at the new scale, reports the grid its own bounds now
        //   imply, and repaints the current frame into fresh buffers.
        // Why it exists: metrics are only valid at the scale they name, so a pane that
        //   held them across a display move would draw cells sized for the pixel grid
        //   it left. Nothing publishes on a scale change, so the repaint has to be the
        //   pane's own doing or it freezes on the old frame.
        // Scenario: spec-first -- the user drags a window from a Retina display onto an
        //   external 1x one.
        RecordingPresentationSurface.reset()
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = makeTestPane(controller: controller, fontSize: 13)
        let frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        pane.frame = frame
        let window = mountInScaledTestWindow(pane, frame: frame, scale: 2)

        guard let atTwo = uiTestMetrics(displayScale: 2, fontChoice: TerminalFontChoice(size: 13)),
              let atOne = uiTestMetrics(displayScale: 1, fontChoice: TerminalFontChoice(size: 13))
        else {
            throw UITestFailure(message: "the suite resolver refused one of the two scales")
        }
        try uiExpect(
            controller.gridDimensions.last == expectedGrid(paneSize: frame.size, metrics: atTwo),
            "the pane did not start on the grid its 2x metrics imply")
        RecordingPresentationSurface.reset()

        window.moveToDisplay(scale: 1)

        try uiExpect(pane.presentationGeometryForTesting?.renderScale == 1,
                     "the pane kept rendering at the scale it left: "
                        + "\(String(describing: pane.presentationGeometryForTesting?.renderScale))")
        try uiExpect(
            controller.gridDimensions.last == expectedGrid(paneSize: frame.size, metrics: atOne),
            "the pane did not report the grid its new metrics imply")
        try uiExpect(
            RecordingPresentationSurface.creationCount == 1,
            "the display move did not replace the presentation surface: "
                + "\(RecordingPresentationSurface.creationCount)")
        try uiExpect(
            RecordingPresentationSurface.renderedRowSets
                == [Set(0..<RenderFramePlan.rowsForTesting)],
            "the display move did not repaint the current frame: "
                + "\(RecordingPresentationSurface.renderedRowSets)")
    }

    await uiTest("a claimed pane keeps its grid across a move between display scales") {
        // Intent: a pane holding a grid override resolves metrics at the new scale and
        //   repaints, and sends the child no resize.
        // Why it exists: the override is the pane's grid outright. A display move is a
        //   fact about pixels, not a claim it may overrule, and a SIGWINCH the client
        //   never asked for would resize the program running in it.
        // Scenario: spec-first -- a phone has claimed a pane at 20x10 and the Mac window
        //   holding it is dragged onto a display of a different density.
        RecordingPresentationSurface.reset()
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = makeTestPane(
            controller: controller,
            fontSize: 13,
            gridOverride: PaneGridOverride(columns: 20, rows: 10)
        )
        let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        pane.frame = frame
        let window = mountInScaledTestWindow(pane, frame: frame, scale: 2)

        try uiExpect(
            controller.gridDimensions.last == TerminalDimensions(columns: 20, rows: 10),
            "the claim did not reach the child: \(controller.gridDimensions)")
        let submissionsBeforeMove = controller.gridDimensions.count
        RecordingPresentationSurface.reset()

        window.moveToDisplay(scale: 1)

        try uiExpect(pane.presentationGeometryForTesting?.renderScale == 1,
                     "the claimed pane kept rendering at the scale it left: "
                        + "\(String(describing: pane.presentationGeometryForTesting?.renderScale))")
        try uiExpect(controller.gridDimensions.count == submissionsBeforeMove,
                     "the display move resized a claimed pane: \(controller.gridDimensions)")
        try uiExpect(
            RecordingPresentationSurface.creationCount == 1,
            "the display move did not replace the claimed pane's surface: "
                + "\(RecordingPresentationSurface.creationCount)")
        try uiExpect(
            RecordingPresentationSurface.renderedRowSets
                == [Set(0..<RenderFramePlan.rowsForTesting)],
            "the display move did not repaint the claimed pane: "
                + "\(RecordingPresentationSurface.renderedRowSets)")
    }

    await uiTest("a font change that moves size and family rebuilds the pane once") {
        // Intent: one config change carrying a new size and a new family resolves the
        //   pane's metrics once, not once per field.
        // Why it exists: size and family reached the pane as two separate pushes, and
        //   each ran a full presentation pass -- so one font change built two font
        //   worlds and two sets of buffers, and the pane briefly ran on a grid that
        //   mixed the new size with the old family.
        // Scenario: spec-first -- the user changes both fields in Preferences and saves.
        RecordingPresentationSurface.reset()
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = makeTestPane(controller: controller, fontSize: 13)
        pane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(pane, frame: pane.frame)
        RecordingPresentationSurface.reset()

        pane.setFont(PaneFont(family: UITestFontFamily.wide, size: 26))

        try uiExpect(
            RecordingPresentationSurface.creationCount == 1,
            "one font change rebuilt the pane \(RecordingPresentationSurface.creationCount) times")
        let wideAtTwentySix = uiTestMetrics(fontSize: 26, fontFamily: UITestFontFamily.wide)
        try uiExpect(
            controller.gridDimensions.last
                == expectedGrid(paneSize: pane.frame.size, metrics: wideAtTwentySix),
            "the combined font change did not land on the new size and family together")
    }

    await uiTest("a pane that fell back to system monospace retries its configured family") {
        // Intent: a pane whose configured family yielded no usable cell box falls back,
        //   and a later rebuild at a new display scale renders the configured family
        //   again once that family is usable.
        // Why it exists: the fallback must not become the pane's font. A pane that
        //   stored the face it fell back to would render system monospace forever, and
        //   the configured family would only return on a restart.
        // Scenario: spec-first -- a face whose cell box cannot be pixel-quantized at 2x
        //   but can at 1x, on a window the user then drags to a 1x display.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(
            controller: controller,
            fontSize: 13,
            fontFamily: UITestFontFamily.wide,
            makeMetrics: { displayScale, fontChoice in
                guard fontChoice.family != UITestFontFamily.wide || displayScale == 1 else {
                    return nil
                }
                return uiTestMetrics(displayScale: displayScale, fontChoice: fontChoice)
            }
        )
        let frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        pane.frame = frame
        let window = mountInScaledTestWindow(pane, frame: frame, scale: 2)

        guard let fallbackAtTwo = uiTestMetrics(
            displayScale: 2,
            fontChoice: TerminalFontChoice(size: 13)
        ), let wideAtOne = uiTestMetrics(
            displayScale: 1,
            fontChoice: TerminalFontChoice(family: UITestFontFamily.wide, size: 13)
        ) else {
            throw UITestFailure(message: "the suite resolver refused one of the two faces")
        }
        try uiExpect(
            controller.gridDimensions.last == expectedGrid(paneSize: frame.size, metrics: fallbackAtTwo),
            "the refused family did not fall back to system monospace")

        window.moveToDisplay(scale: 1)

        try uiExpect(
            controller.gridDimensions.last == expectedGrid(paneSize: frame.size, metrics: wideAtOne),
            "the pane inherited its fallback face instead of retrying the configured family")
        try uiExpect(pane.state.cellHeight == wideAtOne.cellSize.height,
                     "the pane reported the fallback cell box after the family became usable")
    }

    await uiTest("a pane smaller than one cell still reports the floored grid") {
        // Intent: a pane whose bounds do not hold a whole grid reports the sizing floors --
        //   two columns and one row -- rather than a zero-width or zero-height grid.
        // Why it exists: a zero dimension reaches the child as an invalid winsize, and the
        //   floors are the only thing between a dragged-shut divider and that state. The
        //   harness used to re-declare the sizing function without them, so the app could
        //   have lost the floors with every UI test still green.
        // Scenario: spec-first -- the user drags a divider until the pane is a sliver.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller, fontSize: 13)
        pane.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        mountInTestWindow(pane, frame: pane.frame)

        try uiExpect(controller.gridDimensions.last == TerminalDimensions(columns: 2, rows: 1),
                     "a sliver pane did not report the floored grid: \(controller.gridDimensions)")
    }

    await uiTest("a hidden pane defers rectangle geometry and fences its final grid before reveal") {
        // Intent: frame, font, and display-scale changes submit no hidden grids; reveal
        //   submits only the final geometry, fences it, then makes the controller visible.
        // Why it exists: CHROME-3 made background-tab PTYs reflow at every cell boundary
        //   during a window drag, and an unfenced reveal can publish one old-grid frame.
        // Scenario: a mounted pane is hidden, resized, restyled, moved to 1x, and revealed.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller, fontSize: 13)
        let initialFrame = NSRect(x: 0, y: 0, width: 100, height: 200)
        pane.frame = initialFrame
        let window = mountInScaledTestWindow(pane, frame: initialFrame, scale: 2)
        let gridsAtMount = controller.gridSubmissions.count

        pane.setVisible(false)
        let callsBeforeHiddenChanges = controller.controllerCalls.count
        pane.setFrameSize(NSSize(width: 240, height: 360))
        pane.setFont(PaneFont(size: 26))
        window.moveToDisplay(scale: 1)

        try uiExpect(
            controller.gridSubmissions.count == gridsAtMount,
            "hidden presentation changes submitted grids: \(controller.gridSubmissions)"
        )

        pane.setVisible(true)

        guard let finalMetrics = uiTestMetrics(
            displayScale: 1,
            fontChoice: TerminalFontChoice(size: 26)
        ) else {
            throw UITestFailure(message: "the suite resolver refused the reveal metrics")
        }
        guard let expected = expectedGrid(paneSize: pane.frame.size, metrics: finalMetrics) else {
            throw UITestFailure(message: "the final bounds did not resolve a reveal grid")
        }
        let finalSubmission = RecordedTerminalGridSubmission(dimensions: expected, pinned: false)
        try uiExpect(
            Array(controller.controllerCalls.dropFirst(callsBeforeHiddenChanges)) == [
                .grid(finalSubmission),
                .synchronizeState,
                .visibility(true),
            ],
            "reveal did not submit, fence, then show the final grid: \(controller.controllerCalls)"
        )

        let gridsAfterReveal = controller.gridSubmissions.count
        pane.setVisible(false)
        pane.setVisible(true)
        try uiExpect(
            controller.gridSubmissions.count == gridsAfterReveal,
            "unchanged geometry submitted another grid on reveal: \(controller.gridSubmissions)"
        )
    }

    await uiTest("a pane submits its first rectangle grid before any visibility push") {
        // Intent: construction and first layout retain the eager first-grid contract.
        // Why it exists: reconciliation lays out a new pane before its first visibility sweep.
        // Scenario: a background-tab pane mounts, then receives its first hidden push.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller, fontSize: 13)
        pane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(pane, frame: pane.frame)

        pane.setVisible(false)

        try uiExpect(controller.gridSubmissions.count == 1,
                     "the first visibility push arrived before an initial grid")
        try uiExpect(controller.gridSubmissions[0].pinned == false,
                     "the rectangle-derived initial grid was pinned")
        try uiExpect(controller.visibleChanges == [false],
                     "the initial hidden push was not forwarded")
    }

    await uiTest("hidden grid overrides submit immediately with their pinnedness") {
        // Intent: an explicit claim and a later --fit release both reach a hidden PTY at once.
        // Why it exists: remote clients own claimed grid changes even when the Mac tab is hidden;
        //   pinnedness-only changes must also survive geometry deduplication.
        // Scenario: a hidden pane is claimed at its existing grid, resized, then released.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller, fontSize: 13)
        pane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(pane, frame: pane.frame)
        let initial = controller.gridSubmissions[0].dimensions
        pane.setVisible(false)

        pane.setGridOverride(PaneGridOverride(columns: initial.columns, rows: initial.rows))

        try uiExpect(controller.gridSubmissions.last == .init(dimensions: initial, pinned: true),
                     "a hidden pinnedness-only claim was deduped: \(controller.gridSubmissions)")

        pane.setFrameSize(NSSize(width: 240, height: 360))
        let submissionsAfterClaim = controller.gridSubmissions.count
        pane.setGridOverride(nil)
        guard let fitted = expectedGrid(
            paneSize: pane.frame.size,
            metrics: uiTestMetrics(fontSize: 13)
        ) else {
            throw UITestFailure(message: "the final bounds did not resolve a fitted grid")
        }

        try uiExpect(controller.gridSubmissions.count == submissionsAfterClaim + 1,
                     "--fit did not submit exactly one hidden grid: \(controller.gridSubmissions)")
        try uiExpect(controller.gridSubmissions.last == .init(dimensions: fitted, pinned: false),
                     "--fit did not submit the final unpinned rectangle grid")

        let callsBeforeReveal = controller.controllerCalls.count
        pane.setVisible(true)
        try uiExpect(
            Array(controller.controllerCalls.dropFirst(callsBeforeReveal)) == [
                .synchronizeState,
                .visibility(true),
            ],
            "reveal did not fence the explicit hidden submission: \(controller.controllerCalls)"
        )
    }

    await uiTest("a grid override drives the pane's grid and no rectangle change disturbs it") {
        // Intent: setting an override submits exactly that grid once, every later
        //   rectangle change submits nothing at all, and clearing submits exactly
        //   the grid the pane's current rectangle derives.
        // Why it exists: a claimed pane runs at the claiming client's size. If a
        //   resize still reached the child the Mac's own layout would silently
        //   undo the claim, which is the whole reason the override exists.
        // Scenario: spec-first -- the phone claims a pane at 60x30, then the user
        //   drags the Mac window's divider, then takes the pane back.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller, fontSize: 13)
        pane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(pane, frame: pane.frame)
        let gridsAtMount = controller.gridDimensions.count

        pane.setGridOverride(PaneGridOverride(columns: 60, rows: 30))

        try uiExpect(
            controller.gridDimensions.count == gridsAtMount + 1,
            "the override did not submit exactly one grid: \(controller.gridDimensions)"
        )
        try uiExpect(controller.gridDimensions.last == TerminalDimensions(columns: 60, rows: 30),
                     "the override did not reach the child: \(controller.gridDimensions)")

        pane.setFrameSize(NSSize(width: 200, height: 400))

        try uiExpect(
            controller.gridDimensions.count == gridsAtMount + 1,
            "a rectangle change under an override submitted a grid: \(controller.gridDimensions)"
        )

        pane.setGridOverride(nil)

        try uiExpect(
            controller.gridDimensions.count == gridsAtMount + 2,
            "clearing the override did not submit exactly one grid: \(controller.gridDimensions)"
        )
        try uiExpect(
            controller.gridDimensions.last
                == expectedGrid(paneSize: pane.frame.size, metrics: uiTestMetrics(fontSize: 13)),
            "clearing did not return the pane to its rectangle's grid: \(controller.gridDimensions)")
    }

    await uiTest("a font change under an override moves cell metrics but not the grid") {
        // Intent: an override fixes rows and columns, so a font change only
        //   changes how large a cell is drawn.
        // Why it exists: font size is a pixel input, not a grid input. Letting it
        //   re-derive the grid would resize a claimed pane's child every time the
        //   user pressed Cmd-+.
        // Scenario: spec-first -- the user grows the font while the phone holds a
        //   claim on the pane.
        //
        // The pane's rectangle contains the claimed grid at both font sizes, so
        // the cell box the pane draws at is the font's own. A claim the slot
        // cannot contain is drawn down to fit instead, and that case is covered
        // by its own test.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller, fontSize: 13)
        pane.frame = NSRect(x: 0, y: 0, width: 1200, height: 1200)
        mountInTestWindow(pane, frame: pane.frame)
        pane.setGridOverride(PaneGridOverride(columns: 60, rows: 30))
        let gridsAfterClaim = controller.gridDimensions.count

        pane.setFont(PaneFont(size: 26))

        try uiExpect(
            controller.gridDimensions.count == gridsAfterClaim,
            "a font change under an override submitted a grid: \(controller.gridDimensions)"
        )
        try uiExpect(pane.state.cellHeight == uiTestMetrics(fontSize: 26).cellSize.height,
                     "a font change under an override did not update cell metrics: "
                        + "\(String(describing: pane.state.cellHeight))")
    }

    await uiTest("a pane created with an override submits only that grid") {
        // Intent: a pane that starts overridden reports the override as its very
        //   first grid, with no rectangle-derived grid ahead of it.
        // Why it exists: a restored pane's child must never observe a size no
        //   client asked for. An earlier grid would reach the PTY as a real
        //   winsize and show up on the pane's tape.
        // Scenario: spec-first -- the app restarts with a pane the phone had
        //   claimed at 60x30.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(
            controller: controller,
            fontSize: 13,
            gridOverride: PaneGridOverride(columns: 60, rows: 30)
        )
        pane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(pane, frame: pane.frame)

        try uiExpect(controller.gridDimensions == [TerminalDimensions(columns: 60, rows: 30)],
                     "a pane created overridden submitted another grid: \(controller.gridDimensions)")
    }

    await uiTest("a claimed grid that fits its slot renders at native cell metrics with blank surround") {
        // Intent: a claim smaller than the pane's rectangle draws at the pane's
        //   own scale, at the top-left corner, leaving the rest of the slot empty.
        // Why it exists: the Mac shows a claimed pane as the claiming client sees
        //   it. Stretching a small grid over the slot would show the user a size
        //   nobody is running at.
        // Scenario: spec-first -- the phone claims a large Mac pane at 10x5.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller, fontSize: 13)
        pane.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
        mountInTestWindow(pane, frame: pane.frame)
        guard let window = pane.window else { throw UITestFailure(message: "pane did not mount") }
        guard let native = pane.presentationGeometryForTesting else {
            throw UITestFailure(message: "an unclaimed pane reported no presentation geometry")
        }

        pane.setGridOverride(PaneGridOverride(columns: 10, rows: 5))

        guard let claimed = pane.presentationGeometryForTesting else {
            throw UITestFailure(message: "a claimed pane reported no presentation geometry")
        }
        try uiExpect(claimed.renderScale == window.backingScaleFactor,
                     "a fitting claim did not render at the pane's own scale: \(claimed.renderScale)")
        try uiExpect(claimed.cellSize == native.cellSize,
                     "a fitting claim moved the cell box: \(claimed.cellSize) vs \(native.cellSize)")
        try uiExpect(
            claimed.surfacePixelSize.width < pane.bounds.width * window.backingScaleFactor
                && claimed.surfacePixelSize.height < pane.bounds.height * window.backingScaleFactor,
            "a fitting claim left no blank surround: \(claimed.surfacePixelSize)")
        try uiExpect(pane.layerContentsPlacement == .topLeft,
                     "the grid was not anchored at the pane's top-left corner")
    }

    await uiTest("a claimed grid larger than its slot is drawn down uniformly into the slot's pixels") {
        // Intent: an oversized claim shrinks by one factor on both axes, and the
        //   surface it renders into stays inside the pane's own pixel extent.
        // Why it exists: the shrink has to happen while drawing. A buffer sized to
        //   the claimed grid and scaled afterwards would let one remote request
        //   allocate pixels the pane never had room for.
        // Scenario: spec-first -- a phone claims 60x30 on a Mac pane too small to
        //   show that grid at its own cell size.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller, fontSize: 13)
        pane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(pane, frame: pane.frame)
        guard let window = pane.window else { throw UITestFailure(message: "pane did not mount") }
        guard let native = pane.presentationGeometryForTesting else {
            throw UITestFailure(message: "an unclaimed pane reported no presentation geometry")
        }

        pane.setGridOverride(PaneGridOverride(columns: 60, rows: 30))

        guard let claimed = pane.presentationGeometryForTesting else {
            throw UITestFailure(message: "a claimed pane reported no presentation geometry")
        }
        let scale = window.backingScaleFactor
        try uiExpect(
            claimed.surfacePixelSize.width <= pane.bounds.width * scale
                && claimed.surfacePixelSize.height <= pane.bounds.height * scale,
            "the claimed grid rendered outside the pane's pixel extent: \(claimed.surfacePixelSize)")
        try uiExpect(claimed.renderScale < scale,
                     "an oversized claim did not draw down: \(claimed.renderScale) vs \(scale)")
        // One factor on both axes, stated as "the drawn-down box is what this font renders
        // at the reported scale, carried back into the pane's own space". The two axes'
        // shrink ratios cannot be compared to each other instead: a cell box is quantized
        // to whole backing pixels, and at a heavily reduced scale a cell is a few pixels
        // across, so one pixel of rounding separates the ratios by more than any uniform
        // shrink would.
        guard let atClaimedScale = uiTestMetrics(
            displayScale: claimed.renderScale,
            fontChoice: TerminalFontChoice(size: 13)
        ) else {
            throw UITestFailure(message: "the reported render scale resolved no metrics")
        }
        let expectedCell = CGSize(
            width: atClaimedScale.cellSize.width * claimed.renderScale / scale,
            height: atClaimedScale.cellSize.height * claimed.renderScale / scale
        )
        try uiExpect(claimed.cellSize == expectedCell,
                     "the shrink was not one scale on both axes: \(claimed.cellSize) "
                        + "against \(expectedCell)")
        try uiExpect(claimed.cellSize.width < native.cellSize.width
                        && claimed.cellSize.height < native.cellSize.height,
                     "an oversized claim did not shrink the cell box: \(claimed.cellSize)")
    }

    await uiTest("pointer input maps through the transform a drawn-down claim is shown at") {
        // Intent: a click on a shrunk claimed grid names the cell drawn under the
        //   pointer, not the cell the same point would name at native cell size.
        // Why it exists: the grid the user sees and the grid the engine is told
        //   about have to be the same one. Hit-testing against the rendered cell
        //   box would offset every selection and every mouse-mode report.
        // Scenario: spec-first -- the user clicks inside a pane the phone claimed
        //   at 60x30.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller, fontSize: 13)
        pane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(pane, frame: pane.frame)
        guard let native = pane.presentationGeometryForTesting else {
            throw UITestFailure(message: "an unclaimed pane reported no presentation geometry")
        }
        pane.setGridOverride(PaneGridOverride(columns: 60, rows: 30))
        guard let claimed = pane.presentationGeometryForTesting else {
            throw UITestFailure(message: "a claimed pane reported no presentation geometry")
        }
        // Window coordinates are bottom-up; the pane is flipped, so this lands at
        // (30, 50) inside it.
        let location = NSPoint(x: 30, y: 150)
        pane.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, location: location))

        let shown = TerminalViewportCell(
            column: Int(30 / claimed.cellSize.width),
            row: Int(50 / claimed.cellSize.height)
        )
        let atNativeCellSize = TerminalViewportCell(
            column: Int(30 / native.cellSize.width),
            row: Int(50 / native.cellSize.height)
        )
        try uiExpect(shown != atNativeCellSize,
                     "the two cell boxes agree, so this test proves nothing")
        let named = controller.pointerEvents.compactMap { event -> TerminalViewportCell? in
            guard case let .down(_, cell, _, _) = event else { return nil }
            return .init(column: cell.column, row: cell.row)
        }
        try uiExpect(named == [shown],
                     "the click did not name the cell drawn under it: \(named)")
    }

    await uiTest("geometry that is not finite or is out of Int range yields no grid and no cell") {
        // Intent: both pure geometry conversions the pane view calls refuse an unusable
        //   input instead of returning a value built from it.
        // Why it exists: `Int(_:)` on a non-finite or out-of-range Double traps, so a
        //   refusal is what stands between an infinite layout value and a crash. The
        //   harness used to compile copies of both functions with no such guard.
        // Scenario: spec-first -- AppKit hands the view an infinite bound or a pointer
        //   location far outside the window.
        let unusable: [(TerminalPointSize, TerminalPointSize)] = [
            (.init(width: .infinity, height: 100), .init(width: 8, height: 16)),
            (.init(width: 100, height: .nan), .init(width: 8, height: 16)),
            (.init(width: 100, height: 100), .init(width: .infinity, height: 16)),
            (.init(width: 1e300, height: 100), .init(width: 1e-300, height: 16)),
        ]
        for (size, cellSize) in unusable {
            try uiExpect(terminalGridDimensions(size: size, cellSize: cellSize) == nil,
                         "unusable geometry produced a grid: \(size) over \(cellSize)")
        }

        let unusablePoints: [(TerminalPoint, TerminalCellSize)] = [
            (.init(x: .infinity, y: 0), .init(width: 8, height: 16)),
            (.init(x: 0, y: .nan), .init(width: 8, height: 16)),
            (.init(x: 0, y: 0), .init(width: .nan, height: 16)),
            (.init(x: 1e300, y: 0), .init(width: 1e-300, height: 16)),
        ]
        for (point, cellSize) in unusablePoints {
            try uiExpect(terminalCell(at: point, cellSize: cellSize, columns: 80, rows: 24) == nil,
                         "unusable geometry produced a cell: \(point) over \(cellSize)")
        }
    }

    await uiTest("initial theme fills before draw and the retained first plan publishes on mount") {
        // Intent: the view paints themed chrome immediately and adopts the controller's first plan.
        // Why it exists: waiting for child output creates a dark flash on restore and split inheritance.
        // Scenario: a themed controller with a retained plan mounts before its child writes a byte.
        let prefill = RenderTheme(defaultBackground: .init(red: 11, green: 22, blue: 33))
        let planned = RenderColor(red: 44, green: 55, blue: 66)
        let controller = FakeTerminalPaneSessionController(
            theme: prefill,
            currentPlan: RenderFramePlan(defaultBackground: planned)
        )
        let pane = makeTestPane(
            controller: controller,
            theme: "Prefill",
            resolveTheme: { $0 == "Prefill" ? prefill : nil }
        )

        try uiExpect(
            pane.layer?.backgroundColor?.components?.prefix(3).map { UInt8(($0 * 255).rounded()) }
                == [11, 22, 33],
            "pane did not prefill from the controller's initial theme"
        )

        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        try uiExpect(
            pane.publishedBackgroundForTesting == planned,
            "mount waited for child output instead of retaining the controller's first plan"
        )
    }

    await uiTest("engine search status maps into paired product events") {
        // Intent: each atomic engine status becomes the total and selected events the model expects.
        // Why it exists: splitting one engine value into two callbacks must preserve nil, empty,
        //   and zero-based matched semantics without leaving stale counter state.
        // Scenario: a search is cleared, misses, then selects the third of five matches.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller)
        var events: [TerminalSessionEvent] = []
        pane.onEvent = { events.append($0) }

        controller.emitSearchStatus(nil)
        controller.emitSearchStatus(.empty)
        controller.emitSearchStatus(.matched(selected: 2, total: 5))

        try uiExpect(events == [
            .searchTotal(nil), .searchSelected(nil),
            .searchTotal(0), .searchSelected(nil),
            .searchTotal(5), .searchSelected(2),
        ], "search status mapping diverged: \(events)")
    }

    await uiTest("pane registers and accepts only supported drag types") {
        // Intent: the Swift pane participates in AppKit dragging for file URLs, URLs, and strings.
        // Why it exists: destination callbacks are never sent unless the view registers its types.
        // Scenario: supported and unrelated pasteboards enter a mounted Swift-engine pane.
        let pane = makeMountedPane(controller: FakeTerminalPaneSessionController())
        try uiExpect(
            Set(pane.registeredDraggedTypes) == [.fileURL, .URL, .string],
            "pane registered unexpected drag types: \(pane.registeredDraggedTypes)"
        )

        for type in [NSPasteboard.PasteboardType.fileURL, .URL, .string] {
            let accepted = makePasteboard()
            accepted.setString("accepted", forType: type)
            try uiExpect(
                pane.draggingEntered(DraggingInfoStub(pasteboard: accepted)) == .copy,
                "supported \(type.rawValue) drag was refused"
            )
        }

        let refused = makePasteboard()
        refused.setString("ignored", forType: .init("com.example.unrelated"))
        try uiExpect(
            pane.draggingEntered(DraggingInfoStub(pasteboard: refused)).isEmpty,
            "unrelated drag was accepted"
        )
    }

    await uiTest("file drop sends shell-quoted content through bracketed paste") {
        // Intent: dropped file paths use shared drag quoting and owner-side paste policy.
        // Why it exists: a raw write would permit control injection and omit DEC 2004 markers.
        // Scenario: Finder drops a path containing a space onto a bracketed-paste pane.
        let controller = FakeTerminalPaneSessionController()
        controller.inputModes.bracketedPaste = true
        let pane = makeMountedPane(controller: controller)
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/wiggly adleman.png")])

        let performed = pane.performDragOperation(DraggingInfoStub(pasteboard: pasteboard))

        let expected = Array("\u{1B}[200~'/tmp/wiggly adleman.png'\u{1B}[201~".utf8)
        try uiExpect(performed, "file drop was not performed")
        try uiExpect(controller.inputBytes == [expected],
                     "file drop bypassed quoted bracketed paste: \(controller.inputBytes)")
        try uiExpect(controller.textInputs.isEmpty, "file drop used the raw text path")
    }

    await uiTest("browser URL drop takes priority over its plain string") {
        // Intent: a non-file URL is shell-quoted instead of falling through to plain text.
        // Why it exists: browser drags commonly advertise both URL and string representations.
        // Scenario: a link with shell metacharacters is dragged from a browser into the pane.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        let pasteboard = makePasteboard()
        let item = NSPasteboardItem()
        item.setString("https://example.com/a?x=1&y=2", forType: .URL)
        item.setString("Example link", forType: .string)
        pasteboard.writeObjects([item])

        let performed = pane.performDragOperation(DraggingInfoStub(pasteboard: pasteboard))

        try uiExpect(performed, "URL drop was not performed")
        try uiExpect(
            controller.inputBytes == [Array("'https://example.com/a?x=1&y=2'".utf8)],
            "URL drop did not retain URL priority: \(controller.inputBytes)"
        )
    }

    await uiTest("unbracketed multiline drop converts newlines and filters controls") {
        // Intent: drag input inherits unbracketed paste encoding and control filtering.
        // Why it exists: the residual auto-execute behavior must be explicit without admitting
        //   escape-sequence injection through a raw terminal write.
        // Scenario: a plain-text drag contains two lines and an embedded escape character.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        let pasteboard = makePasteboard()
        pasteboard.setString("one\u{1B}\ntwo", forType: .string)

        let performed = pane.performDragOperation(DraggingInfoStub(pasteboard: pasteboard))

        try uiExpect(performed, "multiline string drop was not performed")
        try uiExpect(controller.inputBytes == [Array("one\rtwo".utf8)],
                     "unbracketed paste encoding diverged: \(controller.inputBytes)")
    }

    await uiTest("empty drop writes nothing") {
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        let pasteboard = makePasteboard()
        pasteboard.setString("  \n", forType: .string)

        try uiExpect(
            pane.performDragOperation(DraggingInfoStub(pasteboard: pasteboard)) == false,
            "empty drop reported success"
        )
        try uiExpect(controller.inputBytes.isEmpty, "empty drop wrote terminal bytes")
        try uiExpect(controller.textInputs.isEmpty, "empty drop wrote raw text")
    }

    await uiTest("a mounted pane renders one complete frame and submits nothing at a draw seam") {
        // Intent: the first frame reaches the screen through the owned surface --
        //   one render covering every row -- and no AppKit drawing happens at all.
        // Why it exists: research/33 T25 I4. The draw seam is deleted, so a pane
        //   that came up blank, or one that quietly regrew a second render path,
        //   would both show here and nowhere else.
        // Scenario: a pane is mounted in a window, which is the first moment it
        //   has geometry to render at.
        RecordingPresentationSurface.reset()
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = makeTestPane(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)

        try uiExpect(
            RecordingPresentationSurface.renderedRowSets
                == [Set(0..<RenderFramePlan.rowsForTesting)],
            "mounting did not render exactly one complete frame: "
                + "\(RecordingPresentationSurface.renderedRowSets)"
        )
        try uiExpect(
            pane.renderCountForTesting == 1,
            "expected one render, got \(pane.renderCountForTesting)"
        )
        try uiExpect(
            pane.hasPendingPresentationForTesting == false,
            "the pane kept a pending presentation after its frame rendered"
        )
    }

    await uiTest("the presentation trace records creation, hide, reveal, and every frame") {
        // Intent: with `DANTERM_PRESENTATION_EVENT_LOG` set, a pane writes one
        //   line per presentation moment, in the order they happened, and the
        //   reveal line lands before the frame that answers it.
        // Why it exists: research/41 T3 reads tab-switch latency by subtracting
        //   a `reveal` timestamp from the `attach` that follows it. An event
        //   recorded at the wrong site -- a reveal logged after the frame, or a
        //   redundant visibility push logged as a reveal -- reads as a latency
        //   rather than as a failure, so the pairing has to be pinned here.
        // Scenario: a pane mounts and presents, is hidden, is pushed hidden a
        //   second time, is revealed, publishes its first visible frame, and
        //   then takes a theme change, which throws the swapchain away.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("presentation-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("trace.jsonl")
        setenv(TerminalPresentationEventSampler.environmentVariable, log.path, 1)
        defer { unsetenv(TerminalPresentationEventSampler.environmentVariable) }

        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = makeTestPane(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        pane.setVisible(false)
        pane.setVisible(false)
        pane.setVisible(true)
        controller.emitFrameForTest(damage: .full)
        pane.clearTheme()

        let lines = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n")
            .map { line -> [String: Any] in
                let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
                return (object as? [String: Any]) ?? [:]
            }
        try uiExpect(
            lines.map { $0["event"] as? String ?? "?" }
                == [
                    "create", "attach",
                    // Hide gives the rotation up, so the trace records the rebuild it
                    // costs the next presentation (research/41 D2).
                    "hide", "rebuild",
                    "reveal", "attach",
                    "attach",
                    "rebuild", "attach",
                ],
            "the presentation trace is not the pane's event order: "
                + "\(lines.map { $0["event"] as? String ?? "?" })"
        )
        let stamps = lines.compactMap { $0["uptimeNanoseconds"] as? UInt64 }
        try uiExpect(
            stamps.count == lines.count && stamps == stamps.sorted(),
            "the trace's timestamps are missing or out of order: \(stamps)"
        )
    }

    await uiTest("a publish renders exactly the rows its damage names") {
        // Intent: the damage a publish carries is what the render covers, and
        //   scattered rows stay scattered.
        // Why it exists: this is the drawn-row pin from the deleted draw seam,
        //   restated where the rows are now decided. AppKit used to coalesce
        //   disjoint invalidations into one union rectangle, which turned small
        //   scattered updates into near-full redraws; nothing may reintroduce
        //   that widening on the way to the surface.
        // Scenario: a TUI updates a status row near the top of a ten-row
        //   viewport, then one near the bottom, then a flood -- or an occlusion
        //   return -- publishes `.full`.
        RecordingPresentationSurface.reset()
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = makeTestPane(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        RecordingPresentationSurface.reset()
        pane.resetSurfaceCountersForTesting()

        controller.emitFrameForTest(damage: .init(rows: [1], rowCount: RenderFramePlan.rowsForTesting))
        controller.emitFrameForTest(damage: .init(rows: [8], rowCount: RenderFramePlan.rowsForTesting))
        controller.emitFrameForTest(damage: .full)

        try uiExpect(
            RecordingPresentationSurface.renderedRowSets
                == [[1], [8], Set(0..<RenderFramePlan.rowsForTesting)],
            "publishes did not render exactly their own damage: "
                + "\(RecordingPresentationSurface.renderedRowSets)"
        )
        try uiExpect(
            pane.renderCountForTesting == pane.publishCountForTesting,
            "renders (\(pane.renderCountForTesting)) diverged from publications "
                + "(\(pane.publishCountForTesting))"
        )
    }

    await uiTest("an AppKit-initiated redisplay renders nothing") {
        // Intent: a layer display callback reattaches and returns; it never
        //   renders and never asks the engine for anything.
        // Why it exists: research/33 T25 PO5's second assertion. The old draw
        //   path rendered whatever AppKit asked for, which is how an occlusion
        //   return or a sibling's relayout could bill a full glyph redraw to
        //   nobody's frame. With the pane owning its pixels there is nothing
        //   for AppKit to ask for, and this is what proves it stayed that way.
        // Scenario: a mounted pane is invalidated the way AppKit invalidates it.
        RecordingPresentationSurface.reset()
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = makeTestPane(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        pane.resetSurfaceCountersForTesting()
        RecordingPresentationSurface.reset()

        pane.needsDisplay = true
        pane.displayIfNeeded()

        try uiExpect(
            pane.layerDisplayCountForTesting >= 1,
            "AppKit never reached the layer display callback, so this pins nothing"
        )
        try uiExpect(
            pane.renderCountForTesting == 0,
            "an AppKit redisplay caused \(pane.renderCountForTesting) render(s)"
        )
        try uiExpect(
            RecordingPresentationSurface.renderedRowSets.isEmpty,
            "an AppKit redisplay reached the surface: "
                + "\(RecordingPresentationSurface.renderedRowSets)"
        )
    }

    await uiTest("a coalesced burst renders its last plan on a retry, then goes quiet") {
        // Intent: publishes that find no acquirable buffer render nothing and
        //   coalesce into one pending presentation; when a buffer frees, one
        //   retry renders the composed damage of the whole burst, and the pane
        //   then stops on its own with nothing pending.
        // Why it exists: I3's last-frame guarantee and I6's power contract meet
        //   here. Without the retry the final published plan would never reach
        //   the screen when output stops right after it; without the stop
        //   condition the retry would be periodic work on an idle pane.
        // Scenario: three publishes arrive while the render server still holds
        //   every detached buffer, then the buffers free and no further output
        //   comes.
        RecordingPresentationSurface.reset()
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = makeTestPane(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        pane.resetSurfaceCountersForTesting()
        RecordingPresentationSurface.reset()

        RecordingPresentationSurface.canAcquire = false
        controller.emitFrameForTest(damage: .init(rows: [2], rowCount: RenderFramePlan.rowsForTesting))
        controller.emitFrameForTest(damage: .init(rows: [4], rowCount: RenderFramePlan.rowsForTesting))
        controller.emitFrameForTest(damage: .init(rows: [6], rowCount: RenderFramePlan.rowsForTesting))
        try uiExpect(
            pane.renderCountForTesting == 0,
            "an unacquirable swapchain still rendered \(pane.renderCountForTesting) time(s)"
        )
        try uiExpect(
            pane.hasPendingPresentationForTesting,
            "the coalesced burst left no pending presentation to retry"
        )

        RecordingPresentationSurface.canAcquire = true
        await pumpRunLoop(untilTrue: { pane.hasPendingPresentationForTesting == false })

        try uiExpect(
            pane.hasPendingPresentationForTesting == false,
            "the pending presentation never rendered after buffers freed"
        )
        try uiExpect(
            RecordingPresentationSurface.renderedRowSets == [[2, 4, 6]],
            "the retry did not render the burst's composed damage once: "
                + "\(RecordingPresentationSurface.renderedRowSets)"
        )

        // No further output arrives; the pane must stop retrying by itself.
        let rendersAfterRetry = pane.renderCountForTesting
        await pumpRunLoop(seconds: 0.15)
        try uiExpect(
            pane.renderCountForTesting == rendersAfterRetry,
            "a quiet pane kept rendering: \(pane.renderCountForTesting) vs \(rendersAfterRetry)"
        )
    }

    await uiTest("a metrics change replaces the swapchain and re-renders the current plan") {
        // Intent: cell geometry moving -- through a font change here, through a
        //   backing-scale change on a display move, through a resize -- discards
        //   the buffers and renders the current plan afresh.
        // Why it exists: I3's trust rule. Those buffers hold pixels at the old
        //   pixel geometry; no damage value can bring them current, and bringing
        //   them current is exactly what the swapchain would otherwise try.
        //   Nothing publishes on a scale change either, so the view has to
        //   re-render on its own or the pane freezes on the old frame.
        // Scenario: a mounted pane's font size changes.
        RecordingPresentationSurface.reset()
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = makeTestPane(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        let swapchainsAtMount = RecordingPresentationSurface.creationCount
        RecordingPresentationSurface.reset()
        pane.resetSurfaceCountersForTesting()

        try uiExpect(swapchainsAtMount == 1, "mounting built \(swapchainsAtMount) swapchains")
        pane.setFont(PaneFont(size: 26))

        try uiExpect(
            RecordingPresentationSurface.creationCount == 1,
            "the metrics change did not replace the swapchain: "
                + "\(RecordingPresentationSurface.creationCount)"
        )
        try uiExpect(
            RecordingPresentationSurface.renderedRowSets
                == [Set(0..<RenderFramePlan.rowsForTesting)],
            "the replacement did not render a complete frame: "
                + "\(RecordingPresentationSurface.renderedRowSets)"
        )
    }

    await uiTest("a resized grid replaces the swapchain") {
        // Intent: a publish carrying a differently-shaped grid builds new
        //   buffers instead of trying to bring the old ones current.
        // Why it exists: I3's trust rule again, through the door a resize
        //   actually uses. Metrics are unchanged across a plain resize -- the
        //   cell box is the same -- so the shape has to be read off the plan,
        //   and a swapchain sized to the old grid would refuse or misplace
        //   every row of the new one.
        // Scenario: the engine republishes after a SIGWINCH added two rows.
        RecordingPresentationSurface.reset()
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = makeTestPane(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        RecordingPresentationSurface.reset()

        let resizedRows = RenderFramePlan.rowsForTesting + 2
        controller.currentPlan = RenderFramePlan(
            defaultBackground: RenderTheme.dark.defaultBackground,
            rowCount: resizedRows
        )
        controller.emitFrameForTest(damage: .full)

        try uiExpect(
            RecordingPresentationSurface.creationCount == 1,
            "the resized grid did not replace the swapchain: "
                + "\(RecordingPresentationSurface.creationCount)"
        )
        try uiExpect(
            RecordingPresentationSurface.renderedRowSets == [Set(0..<resizedRows)],
            "the resized grid did not render a complete frame at its new height: "
                + "\(RecordingPresentationSurface.renderedRowSets)"
        )
    }

    await uiTest("the surface census reports the live rotation this pane holds") {
        // Intent: a pane reports no swapchain before it has ever presented, then the
        //   shipping rotation's three buffers at the pane's own pixel geometry, and
        //   hiding the pane gives those buffers up entirely.
        // Why it exists: research/41 T1's attribution is derived from the live
        //   objects, so it has to be read through the production rotation -- a stand-in
        //   with one buffer would agree with a census that reported a configured depth
        //   instead of the buffers held. The hidden-pane arm is the one the footprint
        //   work reads: under research/41 D2 a hidden pane owns no pixels at all.
        // Scenario: a pane built on the live factory mounts, presents, and is hidden.
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = makeTestPane(
            controller: controller,
            makePresentationSurface: liveTerminalPanePresentationSurface
        )

        let beforeMount = try uiUnwrap(pane.readSurfaceCensus(), "an unmounted pane reported no census")
        try uiExpect(
            beforeMount.swapchain == nil,
            "a pane that never presented already owns buffers: \(String(describing: beforeMount.swapchain))"
        )

        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        controller.emitFrameForTest(damage: .full)

        let presented = try uiUnwrap(pane.readSurfaceCensus(), "a presenting pane reported no census")
        let chain = try uiUnwrap(presented.swapchain, "a presented pane reported no swapchain")
        try uiExpect(
            chain.storeCount == TerminalFrameSwapchain.defaultDepth,
            "the census did not report the shipping depth: \(chain.storeCount)"
        )
        try uiExpect(
            chain.pixelWidth > 0 && chain.pixelHeight > 0,
            "the census reported no pixel extent: \(chain.pixelWidth)x\(chain.pixelHeight)"
        )
        try uiExpect(
            chain.bytes >= chain.storeCount * chain.pixelWidth * 4 * chain.pixelHeight,
            "the census reported fewer bytes than its own buffers hold: \(chain.bytes)"
        )
        try uiExpect(presented.isVisible, "a mounted pane reported itself hidden")

        pane.setVisible(false)

        let hidden = try uiUnwrap(pane.readSurfaceCensus(), "a hidden pane reported no census")
        try uiExpect(hidden.isVisible == false, "hiding the pane did not reach the census")
        try uiExpect(
            hidden.swapchain == nil,
            "a hidden pane still owns buffers: \(String(describing: hidden.swapchain))"
        )
        try uiExpect(
            hidden.displayedStoreOutsideSwapchainBytes == nil,
            "a hidden pane still holds the frame it displayed: "
                + "\(String(describing: hidden.displayedStoreOutsideSwapchainBytes))"
        )
        try uiExpect(
            pane.layer?.contents == nil,
            "hiding the pane left a surface attached to its layer"
        )
    }

    await uiTest("a hidden pane renders nothing and a reveal presents the state it reached") {
        // Intent: while a pane is hidden no publish, retry, or re-render input builds
        //   or writes a buffer; the reveal renders exactly once, and the frame it
        //   renders is the plan the pane reached while hidden, not the one it hid on.
        // Why it exists: research/41 D2 makes hide a trust break -- the pane gives up
        //   its pixels, so the reveal must put the *current* state back. A reveal that
        //   rendered the frame from hide would show stale output for one commit, and a
        //   reveal that rendered twice would pay two from-scratch rebuilds.
        // Scenario: a mounted pane presents, is hidden, keeps taking terminal output
        //   while hidden, and is revealed.
        RecordingPresentationSurface.reset()
        let hidePlan = RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        let controller = FakeTerminalPaneSessionController(currentPlan: hidePlan)
        let pane = makeTestPane(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        controller.emitFrameForTest(damage: .full)
        pane.resetSurfaceCountersForTesting()

        pane.setVisible(false)
        // Everything a hidden pane can be asked to redraw for, and the output that
        // keeps arriving behind it.
        let hiddenPlan = RenderFramePlan(defaultBackground: RenderColor(red: 9, green: 9, blue: 9))
        controller.currentPlan = hiddenPlan
        controller.emitFrameForTest(damage: .full)
        pane.refreshPresentation()

        try uiExpect(
            pane.renderCountForTesting == 0,
            "a hidden pane rendered: \(pane.renderCountForTesting)"
        )
        try uiExpect(
            try uiUnwrap(pane.readSurfaceCensus(), "no census").swapchain == nil,
            "a hidden pane built buffers"
        )

        pane.setVisible(true)

        try uiExpect(
            pane.renderCountForTesting == 1,
            "the reveal did not render exactly once: \(pane.renderCountForTesting)"
        )
        try uiExpect(
            pane.publishedBackgroundForTesting == hiddenPlan.defaultBackground,
            "the reveal presented the frame from hide rather than the current state"
        )
        try uiExpect(
            pane.layer?.contents != nil,
            "the reveal put no surface back on the layer"
        )
    }

    await uiTest("a presentation retry armed before a hide renders nothing while hidden") {
        // Intent: a publish that coalesced arms the per-refresh retry; hiding the pane
        //   before it fires leaves the retry inert, and the reveal renders once.
        // Why it exists: research/41's open caveat -- a pane can be hidden while a
        //   presentation retry is armed, and the retry must not be able to recreate
        //   buffers after hide, which is the whole of the memory claim.
        // Scenario: no buffer is acquirable, a publish coalesces, the pane is hidden,
        //   the armed retry fires, and only then is the pane revealed.
        RecordingPresentationSurface.reset()
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = makeTestPane(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        RecordingPresentationSurface.canAcquire = false
        controller.emitFrameForTest(damage: .full)
        try uiExpect(
            pane.hasPendingPresentationForTesting,
            "the coalesced publish armed no pending presentation"
        )
        pane.resetSurfaceCountersForTesting()

        pane.setVisible(false)
        RecordingPresentationSurface.canAcquire = true
        // Meant to expire: the retry's own deadline is one display refresh, so this
        // gives it many turns to fire before the assertion that it rendered nothing.
        await pumpRunLoop(seconds: 0.15)

        try uiExpect(
            pane.renderCountForTesting == 0,
            "an armed retry rendered into a hidden pane: \(pane.renderCountForTesting)"
        )

        pane.setVisible(true)

        try uiExpect(
            pane.renderCountForTesting == 1,
            "the reveal did not render exactly once: \(pane.renderCountForTesting)"
        )
    }

    await uiTest("every trust break while a pane is hidden is answered by one reveal render") {
        // Intent: a theme swap, a font change, a backing-scale move, and a resize while
        //   the pane is hidden build no buffers at all; the reveal renders one frame at
        //   the geometry every one of those inputs left behind.
        // Why it exists: research/41 D2 -- backing scale, color space, theme, grid and
        //   font can all change while a pane is hidden, and each of them reaches the
        //   view's single render path. If any of them still allocated a rotation the
        //   hidden pane would hold pixels again, and if the reveal rebuilt per input it
        //   would pay several from-scratch renders for one switch.
        // Scenario: a mounted 2x pane is hidden, restyled, resized, moved to a 1x
        //   display, and revealed.
        RecordingPresentationSurface.reset()
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = makeTestPane(controller: controller, fontSize: 13)
        let initialFrame = NSRect(x: 0, y: 0, width: 100, height: 200)
        pane.frame = initialFrame
        let window = mountInScaledTestWindow(pane, frame: initialFrame, scale: 2)
        controller.emitFrameForTest(damage: .full)
        pane.resetSurfaceCountersForTesting()
        let chainsAtHide = RecordingPresentationSurface.creationCount

        pane.setVisible(false)
        pane.clearTheme()
        pane.setFont(PaneFont(size: 26))
        pane.setFrameSize(NSSize(width: 240, height: 360))
        window.moveToDisplay(scale: 1)

        try uiExpect(
            RecordingPresentationSurface.creationCount == chainsAtHide,
            "a hidden pane built a rotation: "
                + "\(RecordingPresentationSurface.creationCount - chainsAtHide) of them"
        )
        try uiExpect(
            pane.renderCountForTesting == 0,
            "a hidden pane rendered: \(pane.renderCountForTesting)"
        )

        pane.setVisible(true)

        try uiExpect(
            pane.renderCountForTesting == 1,
            "the reveal did not render exactly once: \(pane.renderCountForTesting)"
        )
        try uiExpect(
            RecordingPresentationSurface.creationCount == chainsAtHide + 1,
            "the reveal built more than one rotation: "
                + "\(RecordingPresentationSurface.creationCount - chainsAtHide)"
        )
        guard let revealMetrics = uiTestMetrics(
            displayScale: 1,
            fontChoice: TerminalFontChoice(size: 26)
        ) else {
            throw UITestFailure(message: "the suite resolver refused the reveal metrics")
        }
        let geometry = try uiUnwrap(
            pane.presentationGeometryForTesting,
            "the revealed pane resolved no presentation geometry"
        )
        try uiExpect(
            geometry.renderScale == revealMetrics.displayScale,
            "the reveal rendered at the pre-hide scale: \(geometry.renderScale)"
        )
    }

    await uiTest("a released pane's pixels do not come back after teardown") {
        // Intent: a pane hidden and then torn down holds no buffers, and neither the
        //   teardown nor anything armed before it puts pixels back.
        // Why it exists: research/41 D2's teardown rule -- the swapchain and its
        //   surfaces go with the view, and a closure armed before the close must be
        //   inert afterwards rather than rebuilding a rotation nobody can see.
        // Scenario: a mounted pane presents with no acquirable buffer, is hidden, and
        //   is torn down while its presentation retry is still armed.
        RecordingPresentationSurface.reset()
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = makeTestPane(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        RecordingPresentationSurface.canAcquire = false
        controller.emitFrameForTest(damage: .full)
        pane.resetSurfaceCountersForTesting()

        pane.setVisible(false)
        pane.tearDown()
        RecordingPresentationSurface.canAcquire = true
        // Meant to expire: the retry's deadline is one display refresh, so this gives
        // the closure armed before teardown every chance to fire.
        await pumpRunLoop(seconds: 0.15)

        try uiExpect(
            pane.renderCountForTesting == 0,
            "a torn-down hidden pane rendered: \(pane.renderCountForTesting)"
        )
        try uiExpect(
            try uiUnwrap(pane.readSurfaceCensus(), "no census").swapchain == nil,
            "a torn-down hidden pane still owns buffers"
        )
    }

    await uiTest("repeated tab switches leave buffers only in the pane that is showing") {
        // Intent: driving two panes the way the runtime's visibility sweep does -- one
        //   visible, one hidden, swapped back and forth, redundant pushes included --
        //   leaves exactly one rotation alive at every step.
        // Why it exists: research/41's whole memory claim is about the steady state a
        //   ten-tab user sits in, not about one hide. A leak that only showed after a
        //   few switches -- a reveal that failed to release its predecessor, a
        //   redundant push that rebuilt -- would read as a correct single hide here and
        //   as the old footprint on the chart.
        // Scenario: two mounted panes take three rounds of `AppRuntime.syncPaneVisibility`'s
        //   push pattern, with one redundant push of the visibility each already has.
        RecordingPresentationSurface.reset()
        @MainActor func makePane() -> SwiftTerminalSessionView {
            let controller = FakeTerminalPaneSessionController(
                currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
            )
            let pane = makeTestPane(controller: controller)
            pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
            mountInTestWindow(pane, frame: pane.frame)
            return pane
        }
        let first = makePane()
        let second = makePane()

        @MainActor func expectOnlyVisibleHoldsBuffers(
            showing shown: SwiftTerminalSessionView,
            hiding hidden: SwiftTerminalSessionView,
            round: Int
        ) throws {
            try uiExpect(
                try uiUnwrap(shown.readSurfaceCensus(), "no census").swapchain != nil,
                "round \(round): the showing pane holds no buffers"
            )
            let census = try uiUnwrap(hidden.readSurfaceCensus(), "no census")
            try uiExpect(
                census.swapchain == nil && census.displayedStoreOutsideSwapchainBytes == nil,
                "round \(round): the hidden pane still holds surfaces"
            )
        }

        for round in 0..<3 {
            second.setVisible(false)
            first.setVisible(true)
            first.setVisible(true)
            try expectOnlyVisibleHoldsBuffers(showing: first, hiding: second, round: round)

            first.setVisible(false)
            second.setVisible(true)
            second.setVisible(true)
            try expectOnlyVisibleHoldsBuffers(showing: second, hiding: first, round: round)
        }
    }

    await uiTest("a displayed frame the live rotation no longer holds is counted separately") {
        // Intent: while a replacement rotation has not presented, the frame still on
        //   screen is reported as bytes outside the swapchain, and that report clears
        //   once the successor presents.
        // Why it exists: a walk of rotations alone under-reports exactly here. The
        //   view retains the previous store so the screen stays valid across a
        //   replacement, and that surface is a real IOSurface the app owns.
        // Scenario: a mounted pane takes a theme change -- which replaces the rotation
        //   -- while no buffer is acquirable, then the buffers free and it presents.
        RecordingPresentationSurface.reset()
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let resolved = RenderTheme(defaultBackground: .init(red: 12, green: 34, blue: 56))
        let pane = makeTestPane(
            controller: controller,
            resolveTheme: { $0 == "Known" ? resolved : nil }
        )
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)

        let attached = try uiUnwrap(pane.readSurfaceCensus(), "a mounted pane reported no census")
        try uiExpect(
            attached.displayedStoreOutsideSwapchainBytes == nil,
            "the displayed frame was counted outside the rotation that holds it: "
                + "\(String(describing: attached.displayedStoreOutsideSwapchainBytes))"
        )

        RecordingPresentationSurface.canAcquire = false
        pane.applyTheme("Known")

        let stranded = try uiUnwrap(pane.readSurfaceCensus(), "a replaced pane reported no census")
        let strandedBytes = try uiUnwrap(
            stranded.displayedStoreOutsideSwapchainBytes,
            "the frame on screen went uncounted while its rotation was replaced"
        )
        try uiExpect(strandedBytes > 0, "the stranded frame reported no bytes")

        RecordingPresentationSurface.canAcquire = true
        controller.emitFrameForTest(damage: .full)

        let settled = try uiUnwrap(pane.readSurfaceCensus(), "a settled pane reported no census")
        try uiExpect(
            settled.displayedStoreOutsideSwapchainBytes == nil,
            "the successor presented and the old frame was still counted: "
                + "\(String(describing: settled.displayedStoreOutsideSwapchainBytes))"
        )
    }

    await uiTest("a theme change replaces the swapchain") {
        // Intent: applying a theme discards the buffers rather than trusting
        //   them for a later incremental render.
        // Why it exists: a theme repaints every row, including rows no damage
        //   will ever name. A detached buffer brought current by damage alone
        //   would keep the old theme's colors in every quiet row -- the one
        //   trust-breaking input no value comparison on geometry can see.
        // Scenario: a mounted pane is given a theme with a different background.
        RecordingPresentationSurface.reset()
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let resolved = RenderTheme(defaultBackground: .init(red: 12, green: 34, blue: 56))
        let pane = makeTestPane(
            controller: controller,
            resolveTheme: { $0 == "Known" ? resolved : nil }
        )
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        RecordingPresentationSurface.reset()

        pane.applyTheme("Known")

        try uiExpect(
            RecordingPresentationSurface.creationCount == 1,
            "the theme change did not replace the swapchain: "
                + "\(RecordingPresentationSurface.creationCount)"
        )
        try uiExpect(
            RecordingPresentationSurface.renderedRowSets
                == [Set(0..<RenderFramePlan.rowsForTesting)],
            "the theme change did not render a complete frame: "
                + "\(RecordingPresentationSurface.renderedRowSets)"
        )
    }

    await uiTest("a window color-space change replaces the swapchain at unchanged geometry") {
        // Intent: the window moving to a display with a different profile
        //   discards the buffers, even though every cell metric is identical.
        // Why it exists: the stores render into memory tagged with the window's
        //   color space so the compositor never converts. Keep the old buffers
        //   and the pane shows the previous profile's colors until something
        //   damages each row -- which for a quiet row is never. This is the one
        //   trust-breaking input that changes no geometry at all, so a
        //   metrics-only check would miss it entirely.
        // Scenario: a mounted pane's window changes color space at the same
        //   backing scale and the same grid.
        RecordingPresentationSurface.reset()
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = makeTestPane(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        guard let window = pane.window else {
            throw UITestFailure(message: "the mounted pane has no window")
        }
        let before = window.colorSpace
        RecordingPresentationSurface.reset()

        window.colorSpace = before == NSColorSpace.displayP3
            ? NSColorSpace.sRGB
            : NSColorSpace.displayP3
        pane.viewDidChangeBackingProperties()

        try uiExpect(
            RecordingPresentationSurface.creationCount == 1,
            "the color-space change did not replace the swapchain: "
                + "\(RecordingPresentationSurface.creationCount)"
        )
        try uiExpect(
            RecordingPresentationSurface.renderedRowSets
                == [Set(0..<RenderFramePlan.rowsForTesting)],
            "the color-space change did not render a complete frame: "
                + "\(RecordingPresentationSurface.renderedRowSets)"
        )
    }

    await uiTest("the screen-change refresh sees a window color-space move") {
        // Intent: the runtime's screen-change entry point applies the same
        //   presentation-input test the AppKit callback does, so a window that
        //   reaches a display with a different profile at the same backing scale
        //   rebuilds its buffers and renders again.
        // Why it exists: `AppRuntime.refreshSessionsForScreenChange` exists only
        //   because AppKit can skip `viewDidChangeBackingProperties` on a screen
        //   change, and it reached the view through a metrics-only check. An idle
        //   pane therefore kept the previous profile's colors until its next byte
        //   of output -- and a pane with no output never caught up at all.
        // Scenario: a user drags a window holding a quiet pane onto a display with
        //   a different color profile at the same backing scale.
        RecordingPresentationSurface.reset()
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = makeTestPane(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        guard let window = pane.window else {
            throw UITestFailure(message: "the mounted pane has no window")
        }
        let before = window.colorSpace
        RecordingPresentationSurface.reset()

        window.colorSpace = before == NSColorSpace.displayP3
            ? NSColorSpace.sRGB
            : NSColorSpace.displayP3
        pane.refreshPresentation()

        try uiExpect(
            RecordingPresentationSurface.creationCount == 1,
            "the screen-change refresh did not replace the swapchain: "
                + "\(RecordingPresentationSurface.creationCount)"
        )
        try uiExpect(
            RecordingPresentationSurface.renderedRowSets
                == [Set(0..<RenderFramePlan.rowsForTesting)],
            "the screen-change refresh did not render a complete frame: "
                + "\(RecordingPresentationSurface.renderedRowSets)"
        )
    }

    await uiTest("a resize that changes the grid leaves the render to the republish") {
        // Intent: a resize submits the new grid and stops there. The view does not
        //   render the plan it is holding, because that plan was built for the old
        //   shape; the engine's republish is what puts the new shape on screen.
        // Why it exists: the presentation-input test reads columns and rows off the
        //   live swapchain rather than off the dimensions just computed. Reading
        //   them off the new dimensions would render a stale plan and build buffers
        //   the next publish immediately throws away.
        // Scenario: a user drags a divider, narrowing a pane by whole cells.
        RecordingPresentationSurface.reset()
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = makeTestPane(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        let gridsAtMount = controller.gridDimensions.count
        RecordingPresentationSurface.reset()
        pane.resetSurfaceCountersForTesting()

        pane.setFrameSize(NSSize(width: 40, height: 160))

        try uiExpect(
            controller.gridDimensions.count == gridsAtMount + 1,
            "the resize did not submit one new grid: \(controller.gridDimensions)"
        )
        try uiExpect(
            RecordingPresentationSurface.creationCount == 0,
            "the resize built a swapchain before the republish: "
                + "\(RecordingPresentationSurface.creationCount)"
        )
        try uiExpect(
            pane.renderCountForTesting == 0,
            "the resize rendered the stale plan: \(pane.renderCountForTesting)"
        )

        controller.currentPlan = RenderFramePlan(
            defaultBackground: RenderTheme.dark.defaultBackground,
            columns: 5
        )
        controller.emitFrameForTest(damage: .full)

        try uiExpect(
            RecordingPresentationSurface.creationCount == 1,
            "the republish did not replace the swapchain: "
                + "\(RecordingPresentationSurface.creationCount)"
        )
        try uiExpect(
            pane.renderCountForTesting == 1,
            "the republish did not render once: \(pane.renderCountForTesting)"
        )
    }

    await uiTest("a pane resized to a zero dimension submits nothing and renders nothing") {
        // Intent: bounds with no area leave the grid, the swapchain, and the frame
        //   on screen exactly as they were.
        // Why it exists: scale and pixel size are one invariant
        //   (docs/design/2026-03-05-display-scaling.md), so a zero-area surface has
        //   no valid geometry to derive. A zero dimension reaching the child is an
        //   invalid winsize, and a zero-sized swapchain is an allocation that fails.
        // Scenario: a user drags a divider fully shut, or a pane's host collapses it
        //   to a zero-height strip during a layout pass.
        RecordingPresentationSurface.reset()
        let controller = FakeTerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = makeTestPane(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        let gridsAtMount = controller.gridDimensions.count
        RecordingPresentationSurface.reset()
        pane.resetSurfaceCountersForTesting()

        pane.setFrameSize(NSSize(width: 80, height: 0))

        try uiExpect(
            controller.gridDimensions.count == gridsAtMount,
            "a zero-height pane submitted a grid: \(controller.gridDimensions)"
        )
        try uiExpect(
            RecordingPresentationSurface.creationCount == 0,
            "a zero-height pane built a swapchain: "
                + "\(RecordingPresentationSurface.creationCount)"
        )
        try uiExpect(
            pane.renderCountForTesting == 0,
            "a zero-height pane rendered: \(pane.renderCountForTesting)"
        )
    }

    await uiTest("a metrics change publishes the new cell geometry to the state observer") {
        // Intent: new cell metrics reach the state observer, not just the pane's own
        //   live `state` getter.
        // Why it exists: `ScrollableTerminalView` is that observer and re-reads state
        //   on each callback, so a dropped emit leaves the scrollbar on its old
        //   document geometry until some unrelated event forces a sync. The existing
        //   font-size coverage reads `pane.state.cellHeight`, which is a live getter
        //   and stays correct even with the emit gone.
        // Scenario: a user changes the terminal font size in Preferences.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller, fontSize: 13)
        pane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(pane, frame: pane.frame)
        let observer = SwiftPaneStateObserver()
        pane.stateObserver = observer

        pane.setFont(PaneFont(size: 26))

        try uiExpect(
            observer.states.last?.cellHeight == uiTestMetrics(fontSize: 26).cellSize.height,
            "the metrics change published no new cell height: "
                + "\(String(describing: observer.states.last?.cellHeight))"
        )
    }

    await uiTest("semantic notifications and progress cross the AppKit adapter") {
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        var events: [TerminalSessionEvent] = []
        pane.onEvent = { events.append($0) }

        controller.emitSemanticEvents([
            .desktopNotification(title: "Build", body: "Done"),
            .progress(.set(percent: 42)),
            .progress(nil),
        ])

        try uiExpect(events == [
            .desktopNotification(title: "Build", body: "Done"),
            .report(.progress(.set(percent: 42))),
            .report(.progress(nil)),
        ], "semantic adapter diverged: \(events)")
    }

    await uiTest("mounted pane forwards fractional wheel metadata once") {
        // Intent: the Swift pane converts a line wheel event into one owner-side row intent
        //   and terminates responder-chain handling at the pane.
        // Why it exists: the enclosing terminal scroll view forwards wheel events to the
        //   pane, so calling super would bounce the same event back through the scroll view.
        // Scenario: a user wheels upward by two line units over a mounted Swift pane.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        let enclosingScrollView = WheelBounceSentinelScrollView()
        pane.nextResponder = enclosingScrollView
        let event = try makeScrollWheelEvent(
            units: .line,
            deltaY: 2,
            location: paneCellPoint(column: 2, offsetX: 0.125, row: 2, in: pane),
            modifiers: [.shift, .control],
            phase: .began
        )

        pane.scrollWheel(with: event)

        try uiExpect(controller.wheelEvents == [
            .init(
                rowDelta: -6,
                column: 2,
                row: 0,
                modifiers: [.shift, .control],
                phase: .began
            ),
        ], "unexpected wheel event: \(controller.wheelEvents)")
        try uiExpect(
            enclosingScrollView.scrollWheelCalls == 0,
            "wheel event bounced to the enclosing scroll view"
        )
    }

    await uiTest("pointer callbacks normalize cells buttons modifiers and click counts") {
        // Intent: every native left-button transition becomes one platform-neutral pointer event.
        // Why it exists: view-side routing or point-space forwarding would bypass owner policy.
        // Scenario: a Shift-double-click drag crosses cells and releases beyond the viewport.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)

        pane.mouseDown(with: try makeMouseEvent(
            type: .leftMouseDown,
            location: paneCellPoint(column: 2, offsetX: 0.125, row: 2, in: pane),
            modifiers: [.shift],
            clickCount: 2
        ))
        pane.mouseDragged(with: try makeMouseEvent(
            type: .leftMouseDragged,
            location: paneCellPoint(column: 3, offsetX: 0.875, row: 3, in: pane),
            modifiers: [.shift]
        ))
        pane.mouseUp(with: try makeMouseEvent(
            type: .leftMouseUp,
            location: NSPoint(x: pane.bounds.width * 2.5, y: -pane.bounds.height * 0.25),
            modifiers: [.shift]
        ))

        // The press and the drag land an eighth and seven eighths of the way into their
        // columns: the sub-cell position character selection resolves a boundary from has
        // to survive the view boundary, not just the column. The release is past the
        // viewport on both axes, so it clamps to the grid's last cell and says it is
        // outside.
        guard let grid = terminalGridDimensions(
            size: TerminalPointSize(width: pane.bounds.width, height: pane.bounds.height),
            cellSize: TerminalPointSize(
                width: paneCellSize(pane).width,
                height: paneCellSize(pane).height
            )
        ) else { throw UITestFailure(message: "the mounted pane resolved no grid") }
        try uiExpect(controller.pointerEvents == [
            .down(.left, cell: .init(column: 2, row: 2, offsetX: 0.125), modifiers: [.shift], clickCount: 2),
            .move(cell: .init(column: 3, row: 3, offsetX: 0.875), modifiers: [.shift]),
            .up(
                .left,
                cell: .init(
                    column: grid.columns - 1,
                    row: grid.rows - 1,
                    offsetX: 1,
                    isInsideGrid: false
                ),
                modifiers: [.shift]
            ),
        ], "pointer normalization diverged: \(controller.pointerEvents)")
        // The release past the viewport says so inside its own cell, so the pane sends the
        // one event and nothing else.
        try uiExpect(controller.linkInteractionCancellations == 0,
                     "an out-of-bounds release still sent a separate cancellation")
    }

    await uiTest("wheel direct and momentum phases reach the owner unchanged") {
        // Intent: precise fractional motion and its direct/momentum lifecycle reach the owner.
        // Why it exists: route latching and remainder ownership both depend on these boundaries.
        // Scenario: a trackpad gesture ends its direct phase and continues with momentum.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)

        for phase in [NSEvent.Phase.began, .changed, .ended] {
            pane.scrollWheel(with: try makeScrollWheelEvent(
                units: .pixel,
                deltaY: 4,
                location: paneCellPoint(column: 1, offsetX: 0.125, row: 1, in: pane),
                phase: phase
            ))
        }
        for phase in [NSEvent.Phase.began, .changed, .ended] {
            pane.scrollWheel(with: try makeScrollWheelEvent(
                units: .pixel,
                deltaY: 4,
                location: paneCellPoint(column: 1, offsetX: 0.125, row: 1, in: pane),
                momentumPhase: phase
            ))
        }

        try uiExpect(controller.wheelEvents.map(\.phase) == [
            .began, .changed, .ended, .momentumBegan, .momentumChanged, .momentumEnded,
        ], "wheel phase normalization diverged: \(controller.wheelEvents)")
        // Four points of motion is a fraction of a row, and the fraction has to survive
        // the view: quantizing here would make a trackpad scroll jump whole rows.
        let expectedRowDelta = -4 / paneCellSize(pane).height
        try uiExpect(controller.wheelEvents.allSatisfy { $0.rowDelta == expectedRowDelta },
                     "precise wheel motion was quantized in the view")
    }

    await uiTest("precise horizontal wheel motion reaches the owner in cell widths") {
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)

        pane.scrollWheel(with: try makeScrollWheelEvent(
            units: .pixel,
            deltaX: 5,
            deltaY: 0,
            location: paneCellPoint(column: 1, offsetX: 0.5, row: 1, in: pane)
        ))

        guard let event = controller.wheelEvents.first else {
            throw UITestFailure(message: "pane forwarded no wheel event")
        }
        try uiExpect(
            event.columnDelta == 5 / paneCellSize(pane).width,
            "horizontal wheel motion was dropped, inverted, or normalized by row height"
        )
    }

    // DISABLED: this test drives `pane.rightMouseDown` on an unclaimed press, so AppKit's
    // default implementation asks `menu(for:)` and pops the returned menu for real. macOS
    // injects a system "AutoFill" item into the empty menu, and the resulting menu-tracking
    // session grabs the keyboard for seconds at a time -- it steals Dan's typing in whatever
    // he is working in while `just test-ui` runs. Commented out until the pane menu is
    // presented by its owner instead of by AppKit, which is the fix that removes this
    // structurally.
//  uiTest("the pane menu is offered on the press unless the terminal claims the button") {
//      // Intent: a right-button press answers with the pane menu and forwards nothing,
//      //   while a claimed press forwards the gesture and offers no menu. Shift always
//      //   takes the press back from the terminal.
//      // Why it exists: this is the whole gesture split. AppKit pops whatever `menu(for:)`
//      //   returns from inside the press, so returning a menu for a click the terminal
//      //   claimed would eat the report the running program is waiting for.
//      // Scenario: spec-first -- the user right-clicks a plain shell, then the same pane
//      //   under a full-screen program that turned mouse reporting on, then shift-clicks it.
//      let controller = FakeTerminalPaneSessionController()
//      let pane = makeMountedPane(controller: controller)
//      let provided = NSMenu()
//      pane.paneMenuProvider = { provided }
//      let point = NSPoint(x: 17, y: 125)
//      let down = try makeMouseEvent(type: .rightMouseDown, location: point)
//
//      try uiExpect(pane.menu(for: down) === provided,
//                   "an unclaimed right press did not offer the pane menu")
//      pane.rightMouseDown(with: down)
//      try uiExpect(controller.pointerEvents.isEmpty,
//                   "an unclaimed right press reached the engine: \(controller.pointerEvents)")
//
//      controller.claimsMouseButtons = true
//      try uiExpect(pane.menu(for: down) == nil, "a claimed right press offered a menu")
//      pane.rightMouseDown(with: down)
//      pane.rightMouseUp(with: try makeMouseEvent(type: .rightMouseUp, location: point))
//      try uiExpect(controller.pointerEvents == [
//          .down(.right, cell: .init(column: 2, row: 2, offsetX: 0.125), modifiers: [], clickCount: 1),
//          .up(.right, cell: .init(column: 2, row: 2), modifiers: []),
//      ], "a claimed right press did not reach the engine: \(controller.pointerEvents)")
//
//      let shiftDown = try makeMouseEvent(
//          type: .rightMouseDown, location: point, modifiers: [.shift]
//      )
//      try uiExpect(pane.menu(for: shiftDown) === provided,
//                   "shift did not take the press back from the terminal")
//      pane.rightMouseDown(with: shiftDown)
//      try uiExpect(controller.pointerEvents.count == 2,
//                   "a shifted right press reached the engine: \(controller.pointerEvents)")
//  }

    // DISABLED: same cause as the test above -- the unclaimed press arm pops a real menu
    // through AppKit, and its tracking session steals Dan's keyboard while the UI suite runs.
//  uiTest("a right release without a forwarded press is never sent on") {
//      // Intent: the engine only ever sees a right release that pairs with a press it saw.
//      // Why it exists: AppKit consumes the release that ends menu tracking, but a stray
//      //   one can still arrive. An unpaired release -- or an unpaired press -- latches the
//      //   engine's button owner, which then swallows the next right-click a program claims.
//      // Scenario: spec-first -- the user right-clicks a plain shell to open the menu, then
//      //   a program turns mouse reporting on and the user right-clicks again.
//      let controller = FakeTerminalPaneSessionController()
//      let pane = makeMountedPane(controller: controller)
//      pane.paneMenuProvider = { NSMenu() }
//      let point = NSPoint(x: 17, y: 125)
//
//      pane.rightMouseDown(with: try makeMouseEvent(type: .rightMouseDown, location: point))
//      pane.rightMouseUp(with: try makeMouseEvent(type: .rightMouseUp, location: point))
//      try uiExpect(controller.pointerEvents.isEmpty,
//                   "a menu-owned gesture reached the engine: \(controller.pointerEvents)")
//
//      controller.claimsMouseButtons = true
//      pane.rightMouseDown(with: try makeMouseEvent(type: .rightMouseDown, location: point))
//      pane.rightMouseUp(with: try makeMouseEvent(type: .rightMouseUp, location: point))
//      try uiExpect(controller.pointerEvents == [
//          .down(.right, cell: .init(column: 2, row: 2, offsetX: 0.125), modifiers: [], clickCount: 1),
//          .up(.right, cell: .init(column: 2, row: 2), modifiers: []),
//      ], "the claimed gesture was not delivered whole: \(controller.pointerEvents)")
//  }

    await uiTest("an unclaimed control-click both focuses the pane and offers the menu") {
        // Intent: a control-click reports pane focus and returns the menu from the same
        //   call, and forwards nothing; a claimed one reaches the program as the left
        //   button AppKit delivered, carrying Control as a modifier.
        // Why it exists: AppKit asks for the menu before any mouse lifecycle on a
        //   control-click and delivers no lifecycle at all once a menu comes back, so
        //   `mouseDown` never runs. The focus half is the half that silently breaks: the
        //   menu still opens, on a pane that never became key.
        // Scenario: spec-first -- the user control-clicks an unfocused pane running a
        //   plain shell, then control-clicks one under a program that claims the mouse.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        let provided = NSMenu()
        pane.paneMenuProvider = { provided }
        var events: [TerminalSessionEvent] = []
        pane.onEvent = { events.append($0) }
        let point = paneCellPoint(column: 1, offsetX: 0.125, row: 1, in: pane)
        let down = try makeMouseEvent(
            type: .leftMouseDown, location: point, modifiers: [.control]
        )
        let up = try makeMouseEvent(type: .leftMouseUp, location: point, modifiers: [.control])

        try uiExpect(pane.menu(for: down) === provided,
                     "an unclaimed control-click did not offer the pane menu")
        try uiExpect(events == [.clickedToFocus],
                     "an unclaimed control-click reported \(events)")
        try uiExpect(controller.pointerEvents.isEmpty,
                     "an unclaimed control-click reached the engine: \(controller.pointerEvents)")

        controller.claimsMouseButtons = true
        events = []
        try uiExpect(pane.menu(for: down) == nil, "a claimed control-click offered a menu")
        pane.mouseDown(with: down)
        pane.mouseUp(with: up)
        try uiExpect(controller.pointerEvents == [
            .down(.left, cell: .init(column: 1, row: 1, offsetX: 0.125), modifiers: [.control], clickCount: 1),
            .up(.left, cell: .init(column: 1, row: 1, offsetX: 0.125), modifiers: [.control]),
        ], "a claimed control-click did not reach the program as Control plus the left button")
        try uiExpect(events == [.clickedToFocus], "a claimed control-click reported \(events)")
    }

    await uiTest("a press the view could not forward is never answered by a release") {
        // Intent: a release reaches the engine only for a press from the same physical
        //   button that reached it, on every one of the three buttons; the left click
        //   still names its pane even when its press went nowhere.
        // Why it exists: the view drops a press it cannot map to a cell, and before the
        //   first layout pass there is no geometry to map with. A release forwarded on
        //   its own is an event no press explains, which the flight tape and its replay
        //   then carry as an unpaired `.up`.
        // Scenario: spec-first -- the user clicks a pane in the instant between its
        //   creation and its first layout, and lets go once it is on screen.
        let leftController = FakeTerminalPaneSessionController()
        let leftPane = makeUnmountedPane(controller: leftController)
        let point = paneCellPoint(column: 2, offsetX: 0.125, row: 2, in: leftPane)
        var events: [TerminalSessionEvent] = []
        leftPane.onEvent = { events.append($0) }
        leftPane.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, location: point))
        try uiExpect(events == [.clickedToFocus],
                     "a click before layout did not name its pane: \(events)")
        mountInTestWindow(leftPane, frame: leftPane.frame)
        leftPane.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, location: point))
        try uiExpect(leftController.pointerEvents.isEmpty,
                     "a left release outran its press: \(leftController.pointerEvents)")

        let rightController = FakeTerminalPaneSessionController()
        rightController.claimsMouseButtons = true
        let rightPane = makeUnmountedPane(controller: rightController)
        rightPane.rightMouseDown(with: try makeMouseEvent(type: .rightMouseDown, location: point))
        mountInTestWindow(rightPane, frame: rightPane.frame)
        rightPane.rightMouseUp(with: try makeMouseEvent(type: .rightMouseUp, location: point))
        try uiExpect(rightController.pointerEvents.isEmpty,
                     "a right release outran its press: \(rightController.pointerEvents)")

        let middleController = FakeTerminalPaneSessionController()
        let middlePane = makeUnmountedPane(controller: middleController)
        middlePane.otherMouseDown(with: try makeMiddleMouseEvent(
            type: .otherMouseDown, location: point
        ))
        mountInTestWindow(middlePane, frame: middlePane.frame)
        middlePane.otherMouseUp(with: try makeMiddleMouseEvent(
            type: .otherMouseUp, location: point
        ))
        try uiExpect(middleController.pointerEvents.isEmpty,
                     "a middle release outran its press: \(middleController.pointerEvents)")
    }

    await uiTest("the middle button forwards its press and release as a pair") {
        // Intent: a mounted pane forwards a middle-button click whole, so the empty
        //   result in the pre-layout test above is the dropped press and not a path
        //   that forwards nothing at all.
        // Why it exists: the middle button enters through its own `otherMouseDown` /
        //   `otherMouseUp` overrides behind a button-number guard, which neither the
        //   left nor the right coverage exercises.
        // Scenario: spec-first -- the user middle-clicks a pane to paste the primary
        //   selection into a program that reads the mouse.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        let point = paneCellPoint(column: 2, offsetX: 0.125, row: 2, in: pane)

        pane.otherMouseDown(with: try makeMiddleMouseEvent(type: .otherMouseDown, location: point))
        pane.otherMouseUp(with: try makeMiddleMouseEvent(type: .otherMouseUp, location: point))

        try uiExpect(controller.pointerEvents == [
            .down(.middle, cell: .init(column: 2, row: 2, offsetX: 0.125), modifiers: [], clickCount: 1),
            .up(.middle, cell: .init(column: 2, row: 2, offsetX: 0.125), modifiers: []),
        ], "the middle button was not delivered as a pair: \(controller.pointerEvents)")
    }

    await uiTest("a release names the button its own press carried") {
        // Intent: a control-click released after Control comes back up pairs as `.left`
        //   on both edges, and a left and a right button held together each pair with
        //   their own press rather than with each other.
        // Why it exists: the button is the one AppKit delivered, so no modifier read at
        //   either edge may rename the gesture mid-click and leave an owner pressed
        //   forever. Overlapping buttons need one record each for the same reason.
        // Scenario: spec-first -- the user control-clicks and lets go of Control before
        //   the mouse, then presses left and right together over a program that claims
        //   both buttons.
        let cell = TerminalViewportCell(column: 2, row: 2, offsetX: 0.125)

        let controlController = FakeTerminalPaneSessionController()
        controlController.claimsMouseButtons = true
        let controlPane = makeMountedPane(controller: controlController)
        let point = paneCellPoint(column: 2, offsetX: 0.125, row: 2, in: controlPane)
        controlPane.mouseDown(with: try makeMouseEvent(
            type: .leftMouseDown, location: point, modifiers: [.control]
        ))
        controlPane.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, location: point))
        try uiExpect(controlController.pointerEvents == [
            .down(.left, cell: cell, modifiers: [.control], clickCount: 1),
            .up(.left, cell: cell, modifiers: []),
        ], "releasing Control renamed the click: \(controlController.pointerEvents)")

        let bothController = FakeTerminalPaneSessionController()
        bothController.claimsMouseButtons = true
        let bothPane = makeMountedPane(controller: bothController)
        bothPane.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, location: point))
        bothPane.rightMouseDown(with: try makeMouseEvent(type: .rightMouseDown, location: point))
        bothPane.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, location: point))
        bothPane.rightMouseUp(with: try makeMouseEvent(type: .rightMouseUp, location: point))
        try uiExpect(bothController.pointerEvents == [
            .down(.left, cell: cell, modifiers: [], clickCount: 1),
            .down(.right, cell: cell, modifiers: [], clickCount: 1),
            .up(.left, cell: cell, modifiers: []),
            .up(.right, cell: cell, modifiers: []),
        ], "overlapping buttons crossed their releases: \(bothController.pointerEvents)")
    }

    await uiTest("only a click that takes key focus reports pane focus") {
        // Intent: the gesture that hands this pane key focus reports it, and no
        //   other button reports anything.
        // Why it exists: focus reports come from interaction sites now. AppKit's
        //   window moves the responder for a left-button press -- control-click
        //   included, which arrives at this same entry point -- and moves nothing
        //   for a genuine right or middle press. A report on
        //   those would invent a focus change the user never asked for.
        // Scenario: one mounted pane takes a plain click, a control-click, a right
        //   click, and an other-button press. The other-button press is dropped by
        //   that entry point's own middle-button guard, so its arm pins the weaker
        //   claim that nothing escapes `otherMouseDown` by any path.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        var events: [TerminalSessionEvent] = []
        pane.onEvent = { events.append($0) }
        let point = paneCellPoint(column: 1, offsetX: 0.125, row: 1, in: pane)

        pane.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, location: point))
        try uiExpect(events == [.clickedToFocus], "a plain click reported \(events)")

        events = []
        pane.mouseDown(with: try makeMouseEvent(
            type: .leftMouseDown, location: point, modifiers: [.control]
        ))
        try uiExpect(events == [.clickedToFocus], "a control-click reported \(events)")

        events = []
        pane.rightMouseDown(with: try makeMouseEvent(type: .rightMouseDown, location: point))
        pane.otherMouseDown(with: try makeMouseEvent(type: .otherMouseDown, location: point))
        try uiExpect(events.isEmpty, "a right or other-button press reported \(events)")
    }

    await uiTest("gaining first responder reports nothing") {
        // Intent: a responder gain is presentation state, never a model fact.
        // Why it exists: the pane-focus pass repairs the responder to this view, and
        //   AppKit calls becomeFirstResponder from inside that call. A report here
        //   is a Msg originated by a reconcile sweep, laundered through AppKit's own
        //   responder dispatch where the lint script cannot see it.
        // Scenario: the pane is made first responder programmatically, the way the
        //   pass does it.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        var events: [TerminalSessionEvent] = []
        pane.onEvent = { events.append($0) }

        try uiExpect(pane.window?.makeFirstResponder(pane) == true, "window refused the pane")

        try uiExpect(events.isEmpty, "a responder gain reported \(events)")
        try uiExpect(controller.focusChanges.isEmpty,
                     "responder gain wrote terminal focus as \(controller.focusChanges)")
    }

    await uiTest("explicit copy fences selection and hasSelection stays cache-only") {
        // Intent: Copy fences pending selection work while menu enablement reads only cached state.
        // Why it exists: asynchronous drag consumption must not put stale text on the pasteboard.
        // Scenario: a selection ends immediately before the user invokes Copy.
        let controller = FakeTerminalPaneSessionController()
        controller.selectedTextOnFence = "alpha"
        let pane = makeMountedPane(controller: controller)
        let pasteboard = NSPasteboard(name: .init("danterm.swift-selection-test"))
        pasteboard.clearContents()
        pane.selectionPasteboard = pasteboard

        try uiExpect(pane.hasSelection == false, "selection cache unexpectedly fenced the owner")
        pane.mouseDown(with: try makeMouseEvent(
            type: .leftMouseDown,
            location: paneCellPoint(column: 0, offsetX: 0.125, row: 0, in: pane)
        ))
        pane.mouseUp(with: try makeMouseEvent(
            type: .leftMouseUp,
            location: paneCellPoint(column: 2, offsetX: 0.125, row: 0, in: pane)
        ))
        pane.copySelection()

        try uiExpect(controller.synchronizedSelectionReads == 1, "copy did not fence the owner")
        try uiExpect(pasteboard.string(forType: .string) == "alpha", "copy missed finalized text")
        try uiExpect(pane.hasSelection, "cached selection did not refresh after fenced copy")
    }

    await uiTest("Edit > Copy routes through the responder chain and validates on cached selection") {
        // Intent: the standard `copy(_:)` action copies the selection, and Edit > Copy is
        //   enabled only while a selection exists, without disturbing Paste.
        // Why it exists: the Swift engine declines Command keys in `keyDown`, so Cmd-C only
        //   works if the pane owns `copy(_:)` on the responder chain; over-broad validation
        //   would silently disable unrelated Edit items such as Paste.
        // Scenario: a user drag-selects output, presses Cmd-C, then clicks to clear it.
        let controller = FakeTerminalPaneSessionController()
        controller.selectedTextOnFence = "beta"
        let pane = makeMountedPane(controller: controller)
        let pasteboard = NSPasteboard(name: .init("danterm.swift-menu-copy-test"))
        pasteboard.clearContents()
        pane.selectionPasteboard = pasteboard
        let copyItem = NSMenuItem(
            title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"
        )
        let pasteItem = NSMenuItem(
            title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"
        )

        try uiExpect(pane.validateMenuItem(copyItem) == false,
                     "Copy was enabled with no selection")
        try uiExpect(pane.validateMenuItem(pasteItem), "Paste was disabled by copy validation")

        pane.mouseDown(with: try makeMouseEvent(
            type: .leftMouseDown,
            location: paneCellPoint(column: 0, offsetX: 0.125, row: 0, in: pane)
        ))
        pane.mouseUp(with: try makeMouseEvent(
            type: .leftMouseUp,
            location: paneCellPoint(column: 2, offsetX: 0.125, row: 0, in: pane)
        ))
        pane.copy(nil)

        try uiExpect(pasteboard.string(forType: .string) == "beta",
                     "responder-chain copy missed finalized text")
        try uiExpect(pane.validateMenuItem(copyItem), "Copy stayed disabled with a selection")
        try uiExpect(pane.validateMenuItem(pasteItem), "Paste validation tracked the selection")
    }

    await uiTest("copy-on-select writes a relayed selection only while it is armed") {
        // Intent: arming copy-on-select puts a completed selection's relayed text on the
        //   pasteboard, and disarming stops the engine relaying anything at all.
        // Why it exists: the option is a subscriber, not a branch -- if disarming only
        //   suppressed the write, the engine would still pay to extract the text.
        // Scenario: spec-first; the user unticks "Copy selection to clipboard" and drags.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        let pasteboard = NSPasteboard(name: .init("danterm.swift-copy-on-select-test"))
        pasteboard.clearContents()
        pane.selectionPasteboard = pasteboard

        pane.setCopyOnSelect(true)
        controller.emitSelectionCopy("alpha")
        try uiExpect(pasteboard.string(forType: .string) == "alpha",
                     "an armed pane did not write the relayed selection")

        pane.setCopyOnSelect(false)
        try uiExpect(controller.onSelectionCopy == nil,
                     "disarming left the engine a subscriber to extract text for")
        controller.emitSelectionCopy("beta")
        try uiExpect(pasteboard.string(forType: .string) == "alpha",
                     "a disarmed pane still reached the pasteboard")
    }

    await uiTest("a pane is armed for copy-on-select from the moment it mounts") {
        // Intent: the copy-on-select the pane was built with is live for the first
        //   selection the pointer completes, with nothing pushed after mount.
        // Why it exists: copy-on-select now rides the pane's config key onto the
        //   creation request, and the reconciler starts with that key cached. If
        //   construction ignored the value, no later pass would supply it and the
        //   option would be silently dead on every new pane.
        // Scenario: spec-first; the user drags in a pane that has just appeared.
        let controller = FakeTerminalPaneSessionController()
        let armed = makeMountedPane(controller: controller, copyOnSelect: true)
        let pasteboard = NSPasteboard(name: .init("danterm.swift-copy-on-select-mount-test"))
        pasteboard.clearContents()
        armed.selectionPasteboard = pasteboard

        controller.emitSelectionCopy("alpha")

        try uiExpect(pasteboard.string(forType: .string) == "alpha",
                     "a pane built armed did not write its first relayed selection")

        let disarmedController = FakeTerminalPaneSessionController()
        _ = makeMountedPane(controller: disarmedController, copyOnSelect: false)

        try uiExpect(disarmedController.onSelectionCopy == nil,
                     "a pane built disarmed still subscribed the engine to extract text")
    }

    await uiTest("a pane built with a config matches one the same config was pushed to") {
        // Intent: every field of a `PaneConfigKey` reaches the same pane state whether
        //   the pane was created with the key or the key was applied to it afterwards.
        // Why it exists: the reconciler seeds its cache with the key a pane mounted
        //   with and then never pushes it again, so a field construction honors
        //   differently -- or drops, as copy-on-select once did -- stays wrong for the
        //   life of the pane and no later pass corrects it.
        // Scenario: spec-first; a pane appears under a config the user already changed.
        let themed = RenderTheme(defaultBackground: .init(red: 12, green: 34, blue: 56))
        let resolveTheme: (String) -> RenderTheme? = { $0 == "Known" ? themed : nil }
        let config = PaneConfigKey(
            theme: "Known",
            font: PaneFont(family: UITestFontFamily.wide, size: 26),
            copyOnSelect: true,
            optionAsAlt: .left,
            gridOverride: PaneGridOverride(columns: 60, rows: 30)
        )

        let builtController = FakeTerminalPaneSessionController()
        let built = makeTestPane(
            controller: builtController,
            config: config,
            resolveTheme: resolveTheme
        )
        let pushedController = FakeTerminalPaneSessionController()
        let pushed = makeTestPane(
            controller: pushedController,
            config: PaneConfigKey(theme: "Unknown"),
            resolveTheme: resolveTheme
        )
        pushed.apply(config)

        let frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        built.frame = frame
        pushed.frame = frame
        mountInTestWindow(built, frame: frame)
        mountInTestWindow(pushed, frame: frame)

        try uiExpect(builtController.renderTheme.defaultBackground == themed.defaultBackground,
                     "the built pane did not carry the config's theme")
        try uiExpect(built.state == pushed.state,
                     "state differed: \(built.state) vs \(pushed.state)")
        try uiExpect(
            built.presentationGeometryForTesting?.cellSize
                == pushed.presentationGeometryForTesting?.cellSize,
            "font produced different cell boxes"
        )
        try uiExpect(builtController.gridDimensions.last == pushedController.gridDimensions.last,
                     "grid override produced different dimensions: "
                        + "\(String(describing: builtController.gridDimensions.last))")
        try uiExpect(builtController.onSelectionCopy != nil && pushedController.onSelectionCopy != nil,
                     "copy-on-select was not armed on both panes")

        for pane in [built, pushed] {
            pane.keyDown(with: try makeKeyEvent(
                keyCode: 0,
                modifiers: [.option, .leftOption],
                characters: "\u{00E5}",
                charactersIgnoringModifiers: "a"
            ))
        }
        try uiExpect(builtController.inputBytes == pushedController.inputBytes,
                     "Option-as-Alt routed differently: \(builtController.inputBytes) "
                        + "vs \(pushedController.inputBytes)")
        try uiExpect(builtController.inputBytes == [[0x1B, 0x61]],
                     "neither pane routed left Option as Alt: \(builtController.inputBytes)")
    }

    await uiTest("Cmd-C copies the same in both copy-on-select modes") {
        // Intent: arming or disarming copy-on-select leaves the explicit copy path alone.
        // Why it exists: the option governs what a gesture does, never what Cmd-C does.
        // Scenario: spec-first; the user copies by hand with the option on, then off.
        let controller = FakeTerminalPaneSessionController()
        controller.selectedTextOnFence = "gamma"
        let pane = makeMountedPane(controller: controller)
        let pasteboard = NSPasteboard(name: .init("danterm.swift-copy-on-select-cmd-c-test"))
        pane.selectionPasteboard = pasteboard

        for armed in [true, false] {
            pasteboard.clearContents()
            pane.setCopyOnSelect(armed)
            pane.copy(nil)
            try uiExpect(pasteboard.string(forType: .string) == "gamma",
                         "explicit copy changed with copy-on-select \(armed ? "on" : "off")")
        }
    }

    await uiTest("Edit > Select All routes through the responder chain and validates as enabled") {
        // Intent: the nil-targeted `selectAll(_:)` action reaches the pane through AppKit's
        //   responder-chain lookup, produces a selection the pane reports, and leaves
        //   Edit > Select All validating as enabled.
        // Why it exists: the Swift engine declines Command keys in `keyDown`, so Cmd-A only
        //   works if the pane owns `selectAll(_:)` on the responder chain; dispatching through
        //   the chain (not calling the method directly) is the point -- a direct call would pass
        //   even if the menu item stayed disabled or the action resolved to another responder.
        // Scenario: a user makes the pane first responder and presses Cmd-A.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        guard let window = pane.window else {
            throw UITestFailure(message: "mounted pane had no window")
        }
        // Dispatch from a child first responder whose `nextResponder` is the pane, so the
        // nil-targeted action resolves up the responder chain to the pane rather than being
        // called on it directly. (A key-window-scoped `NSApp.sendAction` can't run headless.)
        let probe = FirstResponderProbeView(frame: .zero)
        pane.addSubview(probe)
        try uiExpect(window.makeFirstResponder(probe), "probe could not become first responder")
        let selectAllItem = NSMenuItem(
            title: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a"
        )

        try uiExpect(
            probe.tryToPerform(#selector(NSResponder.selectAll(_:)), with: nil),
            "responder chain declined the nil-targeted Select All action"
        )

        try uiExpect(controller.selectAllRequests == 1, "Select All did not reach the owner")
        try uiExpect(pane.hasSelection, "pane reported no selection after Select All")
        try uiExpect(pane.validateMenuItem(selectAllItem), "Select All validated as disabled")
    }

    await uiTest("Command-modified keys produce no terminal input") {
        // Intent: Cmd-C and Cmd-A are owned by the menu/responder chain and never encoded as
        //   terminal input.
        // Why it exists: a fix that reintroduced a Command branch in `keyDown` would send a
        //   stray byte to the shell whenever such a shortcut fell through -- for Cmd-A, the
        //   `\x01` the line editor uses for start-of-line.
        // Scenario: the user presses Cmd-C then Cmd-A on a mounted pane with no selection.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        let before = controller.inputBytes

        pane.keyDown(with: try makeKeyEvent(keyCode: 8, modifiers: [.command], characters: "c"))
        pane.keyDown(with: try makeKeyEvent(keyCode: 0, modifiers: [.command], characters: "a"))

        try uiExpect(controller.inputBytes == before,
                     "Command key leaked terminal input: \(controller.inputBytes)")
    }

    await uiTest("Cmd-Left and Cmd-Right reach the child as Home and End") {
        // Intent: the two chords macOS assigns line-start and line-end are delivered to the
        //   child as Home and End, with the Command bit dropped and Shift preserved.
        // Why it exists: PageUp/PageDown/Home/End now scroll the pane, so these chords are the
        //   only remaining keyboard path to shell line editing. Going through
        //   `dispatchKeyEvent` is the point: a Command chord is offered to the view hierarchy
        //   as a key equivalent before the responder chain runs, so a direct `keyDown` call
        //   would prove nothing about whether the event reaches the pane at all.
        // Scenario: spec-first -- the user presses Cmd-Left, Cmd-Right, then Cmd-Shift-Left on
        //   a long shell line.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        guard let window = pane.window else {
            throw UITestFailure(message: "mounted pane had no window")
        }
        try uiExpect(window.makeFirstResponder(pane), "window refused the pane")

        dispatchKeyEvent(try makeKeyEvent(keyCode: 123, modifiers: [.command, .function]), in: window)
        dispatchKeyEvent(try makeKeyEvent(keyCode: 124, modifiers: [.command, .function]), in: window)
        dispatchKeyEvent(
            try makeKeyEvent(keyCode: 123, modifiers: [.command, .shift, .function]), in: window
        )

        try uiExpect(controller.sentKeys == [
            .init(key: .home, modifiers: []),
            .init(key: .end, modifiers: []),
            .init(key: .home, modifiers: [.shift]),
        ], "line-editing chords did not reach the child: \(controller.sentKeys)")
    }

    await uiTest("Cmd-Left with Control or Option added stays with the menu layer") {
        // Intent: only the bare Command chords are claimed, so every other Command-Left
        //   combination is still free to carry a menu shortcut.
        // Scenario: spec-first -- the user presses Cmd-Ctrl-Left and Cmd-Opt-Left.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        guard let window = pane.window else {
            throw UITestFailure(message: "mounted pane had no window")
        }
        try uiExpect(window.makeFirstResponder(pane), "window refused the pane")

        dispatchKeyEvent(
            try makeKeyEvent(keyCode: 123, modifiers: [.command, .control, .function]), in: window
        )
        dispatchKeyEvent(
            try makeKeyEvent(keyCode: 123, modifiers: [.command, .option, .function]), in: window
        )

        try uiExpect(controller.sentKeys.isEmpty,
                     "a modified Command chord was consumed: \(controller.sentKeys)")
    }

    await uiTest("OSC 52 writes and empty clears reach the injected pasteboard") {
        // Intent: delivered terminal clipboard effects write only at the AppKit boundary.
        // Why it exists: presentation gating and top-level model routing must not own OSC 52 data.
        // Scenario: a remote program writes text, then clears the general clipboard selection.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        let pasteboard = NSPasteboard(name: .init("danterm.swift-osc52-test"))
        pasteboard.clearContents()
        pane.selectionPasteboard = pasteboard

        controller.emitClipboardWrite("hello")
        try uiExpect(pasteboard.string(forType: .string) == "hello", "OSC 52 write was lost")
        controller.emitClipboardWrite("")
        try uiExpect(pasteboard.string(forType: .string) == "", "empty OSC 52 did not clear")
    }

    await uiTest("tracking area delivers mouse moves to the normalized adapter") {
        // Intent: the pane continuously forwards normalized hover motion without a mode mirror.
        // Why it exists: any-motion capture can begin from child output between native callbacks.
        // Scenario: an Option-modified pointer move lands over a visible terminal cell.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        pane.updateTrackingAreas()

        try uiExpect(pane.trackingAreas.contains { $0.options.contains(.mouseMoved) },
                     "pane installed no mouse-move tracking area")
        try uiExpect(pane.trackingAreas.contains { $0.options.contains(.mouseEnteredAndExited) },
                     "pane installed no pointer-entry/exit tracking area")
        pane.mouseMoved(with: try makeMouseEvent(
            type: .mouseMoved,
            location: paneCellPoint(column: 2, offsetX: 0.125, row: 2, in: pane),
            modifiers: [.option]
        ))
        try uiExpect(controller.pointerEvents == [
            .move(cell: .init(column: 2, row: 2, offsetX: 0.125), modifiers: [.alt]),
        ], "mouse move did not reach the owner adapter")
    }

    await uiTest("Cmd-click forwards Command and opens only boundary-valid web URLs") {
        // Intent: AppKit forwards Command intent to owner policy, then independently validates
        //   the click-time target before invoking the injected system opener.
        // Why it exists: terminal output must not reach file or custom URL handlers even if
        //   engine validation regresses or a malformed target crosses the owner boundary.
        // Scenario: a user Cmd-clicks links with valid HTTP(S), unsafe, and malformed targets.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        var opened: [URL] = []
        pane.linkOpener = { url in
            opened.append(url)
            return true
        }

        let down = try makeMouseEvent(
            type: .leftMouseDown,
            location: paneCellPoint(column: 2, offsetX: 0.125, row: 2, in: pane),
            modifiers: [.command]
        )
        let up = try makeMouseEvent(
            type: .leftMouseUp,
            location: paneCellPoint(column: 2, offsetX: 0.125, row: 2, in: pane),
            modifiers: [.command]
        )
        for target in [
            "http://example.com/path",
            "https://example.com/path",
            "HtTpS://example.com/path",
            "file:///etc/hosts",
            "javascript:alert(1)",
            "http:path",
            "http://",
            "http://example.com:0/path",
            "http://example.com:65536/path",
            "http://[/path",
        ] {
            controller.linkForCommandClick = .init(uri: target)
            pane.mouseDown(with: down)
            pane.mouseUp(with: up)
        }

        try uiExpect(
            controller.pointerEvents.first == .down(
                .left,
                cell: .init(column: 2, row: 2, offsetX: 0.125),
                modifiers: [.command],
                clickCount: 1
            ),
            "Cmd-down lost Command intent"
        )
        try uiExpect(
            controller.pointerEvents.dropFirst().first == .up(
                .left,
                cell: .init(column: 2, row: 2, offsetX: 0.125),
                modifiers: [.command]
            ),
            "Cmd-up lost Command intent"
        )
        try uiExpect(opened.map(\.absoluteString) == [
            "http://example.com/path",
            "https://example.com/path",
            "HtTpS://example.com/path",
        ], "unsafe or malformed target crossed the opener boundary: \(opened)")
    }

    await uiTest("Cmd flags changes replay the stationary pointer and update link chrome") {
        // Intent: pressing and releasing Command without moving refreshes owner hover and native
        //   chrome at the last terminal position.
        // Why it exists: AppKit does not emit mouseMoved merely because modifier flags changed.
        // Scenario: the pointer rests over a web link while the user presses and releases Cmd.
        let controller = FakeTerminalPaneSessionController()
        controller.hoveredLinkForCommandMove = .init(uri: "https://example.com/stationary")
        let pane = makeMountedPane(controller: controller)
        pane.mouseMoved(with: try makeMouseEvent(
            type: .mouseMoved,
            location: paneCellPoint(column: 2, offsetX: 0.125, row: 2, in: pane)
        ))

        pane.flagsChanged(with: try makeFlagsChangedEvent(keyCode: 55, modifiers: [.command]))

        try uiExpect(controller.pointerEvents.suffix(2) == [
            .move(cell: .init(column: 2, row: 2, offsetX: 0.125)),
            .move(cell: .init(column: 2, row: 2, offsetX: 0.125), modifiers: [.command]),
        ], "Cmd press did not replay the last pointer cell")
        let preview = pane.subviews.compactMap { $0 as? LinkPreviewView }.first
        try uiExpect(preview?.isHidden == false, "hover did not show the URL pill")
        try uiExpect(
            preview?.label.stringValue == "https://example.com/stationary",
            "URL pill did not show the hovered target"
        )
        try uiExpect(NSCursor.current == .pointingHand, "hover did not install pointing-hand cursor")

        pane.flagsChanged(with: try makeFlagsChangedEvent(keyCode: 55, modifiers: []))

        try uiExpect(controller.pointerEvents.last == .move(cell: .init(column: 2, row: 2, offsetX: 0.125)),
                     "Cmd release did not replay the last pointer cell")
        try uiExpect(preview?.isHidden == true, "Cmd release did not hide the URL pill")

        NSCursor.crosshair.set()
        controller.emitFrameForTest()
        try uiExpect(NSCursor.current == .crosshair,
                     "an unrelated render frame overwrote the current cursor")
    }

    await uiTest("pointer exit clears hover and cancels a pending link click") {
        // Intent: leaving the viewport clears presentation and invalidates the owner-side arm.
        // Why it exists: a later release must not activate a link whose gesture left the pane.
        // Scenario: the user Cmd-presses a link, leaves the pane, then releases over the old cell.
        let controller = FakeTerminalPaneSessionController()
        let link = TerminalHyperlink(uri: "https://example.com/exit")
        controller.hoveredLinkForCommandMove = link
        controller.linkForCommandClick = link
        let pane = makeMountedPane(controller: controller)
        var opened: [URL] = []
        pane.linkOpener = { url in opened.append(url); return true }

        pane.mouseMoved(with: try makeMouseEvent(
            type: .mouseMoved,
            location: paneCellPoint(column: 2, offsetX: 0.125, row: 2, in: pane),
            modifiers: [.command]
        ))
        pane.mouseDown(with: try makeMouseEvent(
            type: .leftMouseDown,
            location: paneCellPoint(column: 2, offsetX: 0.125, row: 2, in: pane),
            modifiers: [.command]
        ))
        pane.mouseExited(with: try makePointerExitEvent(
            location: NSPoint(x: pane.bounds.width + 1, y: pane.bounds.height - 2.5 * paneCellSize(pane).height),
            modifiers: [.command]
        ))
        pane.mouseUp(with: try makeMouseEvent(
            type: .leftMouseUp,
            location: paneCellPoint(column: 2, offsetX: 0.125, row: 2, in: pane),
            modifiers: [.command]
        ))

        try uiExpect(controller.linkInteractionCancellations == 1,
                     "pointer exit did not reach owner cancellation")
        try uiExpect(opened.isEmpty, "release after exit opened \(opened)")
        let preview = pane.subviews.compactMap { $0 as? LinkPreviewView }.first
        try uiExpect(preview?.isHidden == true, "pointer exit left the URL pill visible")

        controller.emitHoveredLinkForTest(link)
        try uiExpect(preview?.isHidden == true, "a stale owner frame restored hover after exit")
    }

    await uiTest("an off-grid press or release cannot open a link") {
        // Intent: whichever half of a Cmd-click lands off the grid, the gesture opens nothing.
        // Why it exists: the pane sends one message per pointer transition, and the measured
        //   insideness rides inside it, so the decision that refuses the link is the same one
        //   that reports the press or release. Nothing follows an event to correct it.
        // Scenario: the user Cmd-drags off the pane and releases, then Cmd-presses in the
        //   blank surround beside the grid and releases over the link.
        let controller = FakeTerminalPaneSessionController()
        let link = TerminalHyperlink(uri: "https://example.com/offgrid")
        controller.hoveredLinkForCommandMove = link
        controller.linkForCommandClick = link
        let pane = makeMountedPane(controller: controller)
        var opened: [URL] = []
        pane.linkOpener = { url in opened.append(url); return true }

        let onGrid = paneCellPoint(column: 2, offsetX: 0.125, row: 2, in: pane)
        let offGrid = NSPoint(x: pane.bounds.width * 2.5, y: -pane.bounds.height * 0.25)

        pane.mouseDown(with: try makeMouseEvent(
            type: .leftMouseDown, location: onGrid, modifiers: [.command]
        ))
        pane.mouseUp(with: try makeMouseEvent(
            type: .leftMouseUp, location: offGrid, modifiers: [.command]
        ))
        try uiExpect(opened.isEmpty, "a release off the grid opened \(opened)")

        pane.mouseDown(with: try makeMouseEvent(
            type: .leftMouseDown, location: offGrid, modifiers: [.command]
        ))
        pane.mouseUp(with: try makeMouseEvent(
            type: .leftMouseUp, location: onGrid, modifiers: [.command]
        ))
        try uiExpect(opened.isEmpty, "a press that began off the grid opened \(opened)")
    }

    await uiTest("a grid that shrinks under a parked pointer drops the hover chrome") {
        // Intent: the pane decides hover from where the pointer sits in the grid it has now,
        //   not from where it sat when the last pointer event arrived.
        // Why it exists: the pointer can stay still while the grid shrinks away from under it,
        //   and an insideness value stored at event time would keep the pill on a cell that is
        //   no longer on the grid.
        // Scenario: spec-first -- a remote client claims a much smaller grid while the pointer
        //   rests on a link near the pane's right edge.
        let controller = FakeTerminalPaneSessionController()
        controller.hoveredLinkForCommandMove = .init(uri: "https://example.com/parked")
        let pane = makeMountedPane(controller: controller)
        // The pane is ten 8x16 cells wide, so this parks the pointer in column 8.
        pane.mouseMoved(with: try makeMouseEvent(
            type: .mouseMoved,
            location: paneCellPoint(column: 8, offsetX: 0.125, row: 2, in: pane),
            modifiers: [.command]
        ))
        let preview = pane.subviews.compactMap { $0 as? LinkPreviewView }.first
        try uiExpect(preview?.isHidden == false, "hover did not show the URL pill")

        // A claimed 2x1 grid covers only the leftmost 16 points, leaving the pointer in the
        // blank surround with no pointer event to tell the pane so.
        guard let claimed = PaneGridOverride(columns: 2, rows: 1) else {
            throw UITestFailure(message: "a 2x1 grid was refused, so this test claims nothing")
        }
        pane.setGridOverride(claimed)
        controller.emitFrameForTest()

        try uiExpect(preview?.isHidden == true,
                     "the pill survived a grid that no longer covers the parked pointer")
    }

    await uiTest("pane maps viewport state and scrollbar commands through the controller") {
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller)
        let observer = SwiftPaneStateObserver()
        pane.stateObserver = observer

        try uiExpect(
            pane.state.scrollPosition == .init(total: 30, offset: 10, length: 20),
            "initial viewport projection was not mapped"
        )
        pane.scroll(toRow: 7)

        let changed = TerminalPaneViewportState(
            isScrollbarEnabled: false,
            projection: .init(totalRows: 12, topRow: 0, windowRows: 12, isFollowing: true)
        )
        controller.emitViewportState(changed)
        controller.emitViewportState(changed)

        try uiExpect(controller.scrolledTopRows == [7], "scrollbar row was not forwarded")
        try uiExpect(observer.states.count == 1, "duplicate state emission: \(observer.states)")
        try uiExpect(observer.states.first?.scrollbarEnabled == false, "alt state stayed enabled")
        try uiExpect(
            observer.states.first?.scrollPosition == .init(total: 12, offset: 0, length: 12),
            "changed viewport projection was not mapped"
        )
    }

    await uiTest("composition commits text before terminal key encoding") {
        // Intent: marked-text composition commits through sendText even while Kitty mode is active.
        // Why it exists: terminal key encoding must never reinterpret native Option/dead-key text.
        // Scenario: AppKit reports the marked and committed phases of Option+e, e as acute e.
        let controller = FakeTerminalPaneSessionController()
        controller.inputModes.kittyKeyboardFlags = .disambiguateEscapeCodes
        let pane = makeTestPane(controller: controller)

        let notFound = NSRange(location: NSNotFound, length: 0)
        pane.setMarkedText(
            "\u{00B4}",
            selectedRange: .init(location: 1, length: 0),
            replacementRange: notFound
        )
        pane.keyDown(with: try makeKeyEvent(keyCode: 14, modifiers: [.option]))
        pane.insertText("\u{00E9}", replacementRange: notFound)

        try uiExpect(controller.textInputs == ["\u{00E9}"], "dead-key composition did not use text path")
        try uiExpect(controller.inputBytes.isEmpty, "composition leaked into terminal key encoding")
    }

    await uiTest("Option-as-Alt routes only the configured physical side") {
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller)
        pane.setOptionAsAlt(.left)

        pane.keyDown(with: try makeKeyEvent(
            keyCode: 0,
            modifiers: [.option, .leftOption],
            characters: "\u{00E5}",
            charactersIgnoringModifiers: "a"
        ))
        pane.keyDown(with: try makeKeyEvent(
            keyCode: 15,
            modifiers: [.option, .rightOption],
            characters: "\u{00AE}",
            charactersIgnoringModifiers: "r"
        ))

        try uiExpect(controller.inputBytes == [[0x1B, 0x61]],
                     "left Option did not send legacy Alt-a: \(controller.inputBytes)")
        try uiExpect(controller.textInputs == ["\u{00AE}"],
                     "right Option did not keep native text: \(controller.textInputs)")
    }

    await uiTest("Option-as-Alt preserves character selection and terminal modifiers") {
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller)
        pane.setOptionAsAlt(.both)

        pane.keyDown(with: try makeKeyEvent(
            keyCode: 0,
            modifiers: [.option, .leftOption, .shift],
            characters: "\u{00C5}",
            charactersIgnoringModifiers: "a"
        ))
        pane.keyDown(with: try makeKeyEvent(
            keyCode: 0,
            modifiers: [.option, .leftOption, .capsLock],
            characters: "\u{00C5}",
            charactersIgnoringModifiers: "a"
        ))
        pane.keyDown(with: try makeKeyEvent(
            keyCode: 0,
            modifiers: [.option, .leftOption, .shift, .control],
            characters: "",
            charactersIgnoringModifiers: "a"
        ))

        try uiExpect(controller.inputBytes == [
            [0x1B, 0x41],
            [0x1B, 0x41],
            [0x1B, 0x01],
        ], "Option translation lost Shift, Caps Lock, or Control: \(controller.inputBytes)")
    }

    await uiTest("native Option policy keeps Alt on fixed terminal keys") {
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller)

        pane.keyDown(with: try makeKeyEvent(keyCode: 123, modifiers: [.option, .leftOption]))
        pane.keyDown(with: try makeKeyEvent(keyCode: 51, modifiers: [.option, .rightOption]))

        try uiExpect(controller.inputBytes == [
            Array("\u{1B}[1;3D".utf8),
            [0x1B, 0x7F],
        ], "fixed keys lost physical Option as terminal Alt: \(controller.inputBytes)")
    }

    await uiTest("Option-as-Alt uses the active Kitty keyboard protocol") {
        let controller = FakeTerminalPaneSessionController()
        controller.inputModes.kittyKeyboardFlags = .disambiguateEscapeCodes
        let pane = makeTestPane(controller: controller)
        pane.setOptionAsAlt(.right)

        pane.keyDown(with: try makeKeyEvent(
            keyCode: 0,
            modifiers: [.option, .rightOption],
            characters: "\u{00E5}",
            charactersIgnoringModifiers: "a"
        ))

        try uiExpect(controller.inputBytes == [Array("\u{1B}[97;3u".utf8)],
                     "right Option bypassed Kitty Alt encoding: \(controller.inputBytes)")
    }

    await uiTest("multi-stage Chinese IME commits only final text through native input") {
        // Intent: successive Chinese IME marked-text replacements stay local until AppKit
        //   commits the final candidate through the native text-input callback.
        // Why it exists: partial candidates or their backing key events must not reach the PTY,
        //   and the final commit must not also be encoded as a terminal key.
        // Scenario: Pinyin input advances through "n", "ni", and a selected Chinese candidate
        //   before AppKit commits the two-character phrase.
        let controller = FakeTerminalPaneSessionController()
        controller.inputModes.kittyKeyboardFlags = .disambiguateEscapeCodes
        let pane = makeTestPane(controller: controller)
        let notFound = NSRange(location: NSNotFound, length: 0)

        pane.setMarkedText(
            "n",
            selectedRange: .init(location: 1, length: 0),
            replacementRange: notFound
        )
        pane.setMarkedText(
            "ni",
            selectedRange: .init(location: 2, length: 0),
            replacementRange: notFound
        )
        pane.setMarkedText(
            "\u{4F60}",
            selectedRange: .init(location: 1, length: 0),
            replacementRange: notFound
        )

        try uiExpect(controller.textInputs.isEmpty, "marked text escaped before commit")
        try uiExpect(controller.inputBytes.isEmpty, "marked text used terminal key encoding")

        pane.insertText("\u{4F60}\u{597D}", replacementRange: notFound)

        try uiExpect(controller.textInputs == ["\u{4F60}\u{597D}"],
                     "Chinese IME commit did not use the text path exactly once")
        try uiExpect(controller.inputBytes.isEmpty,
                     "Chinese IME commit leaked into terminal key encoding")
        try uiExpect(pane.hasMarkedText() == false, "committed IME text remained marked")
    }

    await uiTest("control punctuation and function keys normalize into core bytes") {
        // Intent: layout-derived Control punctuation and function keys retain semantic identity.
        // Why it exists: AppKit mutates Control characters and represents function keys as PUA text.
        // Scenario: a user enters the ASCII control-punctuation set, then F3 in Kitty mode.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller)
        let cases: [(UInt16, NSEvent.ModifierFlags, [UInt8])] = [
            (49, [.control], [0x00]),
            (33, [.control], [0x1B]),
            (42, [.control], [0x1C]),
            (30, [.control], [0x1D]),
            (22, [.control, .shift], [0x1E]),
            (27, [.control, .shift], [0x1F]),
        ]
        for (keyCode, modifiers, expected) in cases {
            pane.keyDown(with: try makeKeyEvent(keyCode: keyCode, modifiers: modifiers))
            try uiExpect(controller.inputBytes.last == expected,
                         "keyCode \(keyCode) produced \(String(describing: controller.inputBytes.last))")
        }
        pane.keyDown(with: try makeKeyEvent(keyCode: 48, modifiers: [.shift]))
        try uiExpect(controller.inputBytes.last == Array("\u{1B}[Z".utf8),
                     "Shift-Tab diverged from shared input vocabulary")

        controller.inputModes.kittyKeyboardFlags = .disambiguateEscapeCodes
        pane.keyDown(with: try makeKeyEvent(keyCode: 99, modifiers: []))
        try uiExpect(controller.inputBytes.last == Array("\u{1B}[13~".utf8),
                     "F3 did not use Kitty encoding: \(String(describing: controller.inputBytes.last))")
    }

    await uiTest("a keystroke's origin is the system event's own occurrence time") {
        // Intent: both `keyDown` routes -- committed text and a fixed terminal key -- attribute
        // their bytes to the time the system created the event.
        // Why it exists: the pane recorder charges the distance between that origin and the
        // completed write to the app, so a handler that sampled its own clock instead would
        // charge every stall ahead of it to the child, which is the ambiguity the tape removes.
        // Scenario: two key events that occurred at 2.5s and 3.5s of uptime reach the pane.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller)

        pane.keyDown(with: try makeKeyEvent(
            keyCode: 40,
            modifiers: [],
            characters: "k",
            timestamp: 2.5
        ))
        pane.keyDown(with: try makeKeyEvent(keyCode: 48, modifiers: [], timestamp: 3.5))

        try uiExpect(controller.textInputs == ["k"], "typed text did not reach the controller")
        try uiExpect(controller.inputBytes == [Array("\t".utf8)], "Tab did not reach the controller")
        try uiExpect(controller.inputOrigins == [2_500_000_000, 3_500_000_000],
                     "input lost the event's own time: \(controller.inputOrigins)")
    }

    await uiTest("a GUI keystroke submitted before spawn is delivered after process start") {
        // Intent: the real AppKit key route accepts input while the pane process is spawning,
        //   then delivers it when that process starts.
        // Why it exists: GUI input shares the lifecycle path with IPC input, and the old
        //   pre-running reducer arm silently discarded keystrokes.
        // Scenario: a deterministic spawning controller receives K before its process-start edge.
        let controller = FakeTerminalPaneSessionController(processIsRunning: false)
        let pane = makeTestPane(controller: controller)

        pane.keyDown(with: try makeKeyEvent(keyCode: 40, modifiers: [], characters: "k"))

        try uiExpect(controller.textInputs == ["k"], "AppKit input did not reach the controller")
        try uiExpect(controller.deliveredTextInputs.isEmpty,
                     "spawning controller delivered the keystroke before process start")

        controller.emitProcessStarted()

        try uiExpect(controller.deliveredTextInputs == ["k"],
                     "process start did not deliver the buffered GUI keystroke exactly once")
    }

    await uiTest("a typed key stamps the wait the pane holds and reports it back on delivery") {
        // Intent: a real AppKit keystroke reads the pane's current agent wait at the moment
        //   it is submitted, and the delivered occurrence reaches the app naming that wait.
        // Why it exists: this is the only proof of the app-side origin read. Scripted input
        //   snapshots the wait inside core dispatch, so every core test would still pass if
        //   the typed path stamped nothing and no keystroke ever retracted a wait.
        // Scenario: an agent reports `waiting`, the user presses Escape in the pane.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller)
        var generation: AgentWaitGeneration? = AgentWaitGeneration(rawValue: 7)
        pane.currentAgentWaitGeneration = { generation }
        var events: [TerminalSessionEvent] = []
        pane.onEvent = { events.append($0) }

        pane.keyDown(with: try makeKeyEvent(keyCode: 53, modifiers: []))

        try uiExpect(
            controller.submittedWaitGenerations == [PaneInputWaitGeneration(rawValue: 7)],
            "the typed key did not stamp the pane's wait: \(controller.submittedWaitGenerations)"
        )
        try uiExpect(
            events == [.report(.userInputDelivered(waitGeneration: AgentWaitGeneration(rawValue: 7)))],
            "the delivered occurrence did not reach the app naming the wait: \(events)"
        )

        // A pane holding no wait stamps none, so its delivery can retract nothing.
        generation = nil
        events = []
        pane.keyDown(with: try makeKeyEvent(keyCode: 53, modifiers: []))

        try uiExpect(
            events == [.report(.userInputDelivered(waitGeneration: nil))],
            "input with no wait behind it did not report an empty occurrence: \(events)"
        )
    }

    await uiTest("pane input preserves every meaning, result, and captured wait") {
        // Intent: the one TerminalSession submission requirement preserves paste, raw text,
        //   key, and wheel payloads with one captured wait, and returns the controller result.
        // Why it exists: parallel session entry points could disagree on safety semantics,
        //   payload fields, wait forwarding, or whether a terminal rejection reached the model.
        // Scenario: IPC submits all four meanings successfully, then the terminal refuses
        //   one item of each meaning with a distinct typed reason.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller)
        controller.inputModes.bracketedPaste = true
        let wait = AgentWaitGeneration(rawValue: 7)
        let payload = "one\u{1B}[201~\ntwo"
        var results: [TerminalInputSubmissionResult] = []

        pane.submitInput(.paste(payload), waitGeneration: wait) { results.append($0) }
        pane.submitInput(.text(payload), waitGeneration: wait) { results.append($0) }
        pane.submitInput(
            .key(.character("c"), modifiers: [.ctrl, .shift]),
            waitGeneration: wait
        ) { results.append($0) }
        pane.submitInput(.wheel(.up, column: 4, row: 2), waitGeneration: wait) {
            results.append($0)
        }
        let rejectedInputs: [(PaneInputItem, PaneInputSubmissionFailure)] = [
            (.paste("refused paste"), .bufferLimitExceeded),
            (.text("refused text"), .canonicalModeTimeout),
            (.key(.named(.escape), modifiers: []), .processEnded),
            (.wheel(.down, column: 6, row: 3), .writeFailed(EIO)),
        ]
        for (input, failure) in rejectedInputs {
            controller.submissionFailure = failure
            pane.submitInput(input, waitGeneration: wait) { results.append($0) }
        }

        await pumpRunLoop(untilTrue: { results.count == 8 })

        try uiExpect(
            controller.inputBytes == [
                Array("\u{1B}[200~one[201~\ntwo\u{1B}[201~".utf8),
                encodeTerminalKey(.character("c"), modifiers: [.control, .shift], modes: controller.inputModes),
                Array("\u{1B}[200~refused paste\u{1B}[201~".utf8),
                encodeTerminalKey(.escape, modifiers: [], modes: controller.inputModes),
            ],
            "paste or key submission changed meaning: \(controller.inputBytes)"
        )
        try uiExpect(controller.textInputs == [payload, "refused text"],
                     "raw text payload changed: \(controller.textInputs)")
        try uiExpect(
            controller.wheelEvents == [
                TerminalWheelEvent(rowDelta: -1, column: 4, row: 2),
                TerminalWheelEvent(rowDelta: 1, column: 6, row: 3),
            ],
            "wheel payload changed: \(controller.wheelEvents)"
        )
        try uiExpect(
            controller.submittedWaitGenerations == Array(
                repeating: PaneInputWaitGeneration(rawValue: 7),
                count: 8
            ),
            "captured wait changed: \(controller.submittedWaitGenerations)"
        )
        try uiExpect(
            results == [
                .delivered,
                .delivered,
                .delivered,
                .delivered,
                .rejected(.bufferLimitExceeded),
                .rejected(.canonicalModeTimeout),
                .rejected(.processEnded),
                .rejected(.writeFailed(EIO)),
            ],
            "terminal results changed: \(results)"
        )
        try uiExpect(controller.deliveredTextInputs == [payload],
                     "rejected text was recorded as delivered: \(controller.deliveredTextInputs)")
        try uiExpect(
            controller.deliveredInputBytes.count == 2,
            "rejected paste or key was recorded as delivered: \(controller.deliveredInputBytes)"
        )
        try uiExpect(
            controller.deliveredWheelEvents == [
                TerminalWheelEvent(rowDelta: -1, column: 4, row: 2),
            ],
            "rejected wheel was recorded as delivered: \(controller.deliveredWheelEvents)"
        )
    }

    await uiTest("the pane forwards a session result carrying what ended the child") {
        // Intent: the result the pane hands its owner is the whole lifecycle result, exit
        //   status and launch failure included, and each arm still emits its own event.
        // Why it exists: the owner decides whether to keep a pane open from why the child
        //   ended. The harness used to model the result as two payload-free cases, so a
        //   view that dropped the payload would have kept every UI test green.
        // Scenario: spec-first -- one child is killed by a signal, and a second pane's
        //   shell cannot be launched at all.
        let controller = FakeTerminalPaneSessionController()
        var results: [PaneProcessLifecycleResult] = []
        let pane = makeTestPane(controller: controller, onSessionEnded: { results.append($0) })
        var events: [TerminalSessionEvent] = []
        pane.onEvent = { events.append($0) }

        controller.onSessionEnded?(.exited(.signaled(9)))
        controller.onSessionEnded?(.launchFailed(.noUsableShell(2)))

        try uiExpect(results == [.exited(.signaled(9)), .launchFailed(.noUsableShell(2))],
                     "the pane dropped the payload explaining the session result: \(results)")
        try uiExpect(events == [.processExited, .processLaunchFailed],
                     "the session result arms did not emit their own events: \(events)")
    }

    await uiTest("input the app originates carries the time it entered the pane") {
        // Intent: input with no system event behind it -- the IPC text and key entries -- still
        // reports an origin, taken as it enters the pane.
        // Why it exists: an absent origin means "these bytes originated at the pane owner", so
        // an unstamped IPC submission would misattribute the app's own queueing to the owner.
        // Scenario: the control socket sends one text run and one named key.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeTestPane(controller: controller)

        let before = DispatchTime.now().uptimeNanoseconds
        pane.submitInput(.text("ls"), waitGeneration: nil) { _ in }
        pane.submitInput(.key(.named(.enter), modifiers: []), waitGeneration: nil) { _ in }
        let after = DispatchTime.now().uptimeNanoseconds

        try uiExpect(controller.inputOrigins.count == 2,
                     "expected two submissions, got \(controller.inputOrigins.count)")
        for origin in controller.inputOrigins {
            guard let origin else {
                throw UITestFailure(message: "app-originated input reported no origin at all")
            }
            try uiExpect(origin >= before && origin <= after,
                         "origin \(origin) is outside the submission window")
        }
    }

    await uiTest("keyboard input runs before a sustained frame stream completes") {
        // Intent: the real AppKit key route reaches the pane controller before a
        //   continuing stream of visible frame callbacks finishes.
        // Why it exists: real-PTY convergence cannot detect a view or responder path
        //   that becomes inert while the main actor is processing visible output.
        // Scenario: one-at-a-time frame callbacks keep rearming while a queued K key
        //   event crosses `keyDown`; the stream then drains to its final frame.
        let controller = FakeTerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        let producer = SustainedFrameProducer(controller: controller, frameCount: 200)
        let keyEvent = try makeKeyEvent(keyCode: 40, modifiers: [], characters: "k")
        var inputArrivedBeforeCompletion = false
        try uiExpect(pane.window?.makeFirstResponder(pane) == true,
                     "terminal pane did not become the AppKit first responder")

        producer.start()
        DispatchQueue.main.async {
            pane.window?.sendEvent(keyEvent)
            inputArrivedBeforeCompletion = producer.isComplete == false
        }

        let hangGuard = Date(timeIntervalSinceNow: 30)
        while producer.isComplete == false, Date() < hangGuard {
            await pumpMainQueueOnce()
        }

        try uiExpect(producer.isComplete, "sustained frame stream did not converge")
        try uiExpect(inputArrivedBeforeCompletion, "keyboard input waited for final output")
        try uiExpect(controller.textInputs == ["k"], "AppKit key did not reach the pane controller")
    }

    await uiTest("numeric keypad keys retain their semantic identity") {
        // Intent: keypad text is encoded as a keypad key instead of ordinary committed text.
        // Why it exists: application-keypad mode changes bytes even though AppKit supplies a digit.
        // Scenario: the child enables DECKPAM and the user presses keypad zero.
        let controller = FakeTerminalPaneSessionController()
        controller.inputModes.applicationKeypad = true
        let pane = makeTestPane(controller: controller)

        pane.keyDown(with: try makeKeyEvent(
            keyCode: 82,
            modifiers: [.numericPad],
            characters: "0"
        ))

        try uiExpect(controller.textInputs.isEmpty, "keypad zero escaped through the text path")
        try uiExpect(controller.inputBytes == [Array("\u{1B}Op".utf8)],
                     "keypad zero lost application-keypad semantics: \(controller.inputBytes)")
    }

    await uiTest("menu and context paste share the owner-side safe-paste path") {
        // Intent: both AppKit paste entry points submit raw clipboard text to owner-side policy.
        // Why it exists: bypassing the owner could admit escape injection or skip bracket markers.
        // Scenario: Edit > Paste and the pane menu paste text containing an embedded marker.
        // The scratch pasteboard is not incidental: both entry points read
        // `selectionPasteboard`, so assigning one here keeps the harness off the
        // developer's real clipboard the way the copy tests above already do.
        let controller = FakeTerminalPaneSessionController()
        controller.inputModes.bracketedPaste = true
        let pane = makeTestPane(controller: controller)
        let pasteboard = NSPasteboard(name: .init("danterm.swift-paste-test"))
        pane.selectionPasteboard = pasteboard
        pasteboard.clearContents()
        pasteboard.setString("one\u{1B}[201~\ntwo", forType: .string)
        let expected = Array("\u{1B}[200~one[201~\ntwo\u{1B}[201~".utf8)

        pane.paste(nil)
        pane.pasteClipboard()

        try uiExpect(controller.inputBytes == [expected, expected],
                     "paste entry points diverged: \(controller.inputBytes)")
    }

    await uiTest("IPC text pastes while structured input text stays raw") {
        // Intent: paste input reaches the pane as a paste, and text input
        //   reaches it as raw committed text.
        // Why it exists: the two commands are only meaningfully different at this adapter, and
        //   the IPC `text` field is documented as the paste path -- sanitized and bracketed --
        //   while structured `input` text must arrive as if typed.
        // Scenario: an IPC caller sends `{text: ...}` and then `{input: [...]}` containing the
        //   same escape-bearing string into a pane with bracketed paste active.
        let controller = FakeTerminalPaneSessionController()
        controller.inputModes.bracketedPaste = true
        let pane = makeTestPane(controller: controller)
        let payload = "one\u{1B}[201~\ntwo"

        pane.submitInput(.paste(payload), waitGeneration: nil) { _ in }
        pane.submitInput(.text(payload), waitGeneration: nil) { _ in }

        try uiExpect(controller.inputBytes == [Array("\u{1B}[200~one[201~\ntwo\u{1B}[201~".utf8)],
                     "IPC text lost paste semantics: \(controller.inputBytes)")
        try uiExpect(controller.textInputs == [payload],
                     "structured input text gained paste semantics: \(controller.textInputs)")
    }

    await uiTest("a released pane is unreachable by every controller callback") {
        // Intent: deallocating the AppKit view while the controller still holds its
        //   callbacks releases the view and leaves no callback able to touch it.
        // Why it exists: the view's eight controller callbacks are `[weak self]` and
        //   its `isolated deinit` runs `tearDown()` to drop the tracking area and
        //   close the callback gate -- but nothing enforces any of that. Drop one
        //   `[weak self]` and the controller retains a dead view forever; skip the
        //   deinit teardown and a frame arriving after dealloc dereferences freed
        //   memory. Controller-side teardown is proven by
        //   TerminalPaneSessionControllerTests; this pins the AppKit view's own
        //   half, the same use-after-free class as the 2026-06-09 Cmd-Z SIGSEGV.
        // Scenario: a pane is mounted, takes a frame, and is torn out of its window
        //   while the controller keeps emitting frames, viewport state, clipboard
        //   writes, semantic events, search status, and hover at it.
        // The pane is built and released inside an autoreleasepool: AppKit init
        // paths routinely autorelease view references, so without draining them the
        // pane would survive regardless and a broken `[weak self]` would still pass.
        let controller = FakeTerminalPaneSessionController()
        var events: [TerminalSessionEvent] = []
        weak var released: SwiftTerminalSessionView?

        autoreleasepool {
            let pane = makeTestPane(controller: controller)
            pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
            pane.onEvent = { events.append($0) }
            released = pane

            let window = NSWindow(
                contentRect: pane.frame, styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = pane
            pane.updateTrackingAreas()
            controller.emitFrameForTest()

            window.contentView = NSView(frame: pane.frame)
        }

        try uiExpect(released == nil,
                     "the controller or a callback is still retaining the released pane")

        let deliveredBeforeRelease = events.count
        controller.emitFrameForTest()
        controller.emitViewportState(TerminalPaneViewportState(
            isScrollbarEnabled: true,
            projection: .init(totalRows: 40, topRow: 4, windowRows: 20, isFollowing: false)
        ))
        controller.emitClipboardWrite("after release")
        controller.emitSemanticEvents([.desktopNotification(title: "Late", body: "Frame")])
        controller.emitSearchStatus(.matched(selected: 1, total: 2))
        controller.emitHoveredLinkForTest(TerminalHyperlink(uri: "https://example.com/late"))

        try uiExpect(events.count == deliveredBeforeRelease,
                     "a callback reached the released pane: \(events)")
    }
}

private final class WheelBounceSentinelScrollView: NSScrollView {
    private(set) var scrollWheelCalls = 0

    override func scrollWheel(with event: NSEvent) {
        scrollWheelCalls += 1
    }
}

private final class SwiftPaneStateObserver: TerminalSessionStateObserver {
    var states: [TerminalSessionState] = []

    func terminalSessionStateDidChange(_ state: TerminalSessionState) {
        states.append(state)
    }
}

@MainActor
private final class DraggingInfoStub: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(pasteboard: NSPasteboard) {
        draggingPasteboard = pasteboard
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}

@MainActor
private func makePasteboard() -> NSPasteboard {
    let name = NSPasteboard.Name("danterm-ui-drag-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    pasteboard.clearContents()
    return pasteboard
}

private func makeScrollWheelEvent(
    units: CGScrollEventUnit,
    deltaX: Int32 = 0,
    deltaY: Int32,
    location: CGPoint = .zero,
    modifiers: NSEvent.ModifierFlags = [],
    phase: NSEvent.Phase = [],
    momentumPhase: NSEvent.Phase = []
) throws -> NSEvent {
    guard let cgEvent = CGEvent(
        scrollWheelEvent2Source: nil,
        units: units,
        wheelCount: 2,
        wheel1: deltaY,
        wheel2: deltaX,
        wheel3: 0
    ) else {
        throw UITestFailure(message: "could not synthesize a wheel event")
    }
    cgEvent.location = location
    cgEvent.flags = cgEventFlags(modifiers)
    cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhaseCode(phase))
    cgEvent.setIntegerValueField(
        .scrollWheelEventMomentumPhase,
        value: momentumPhaseCode(momentumPhase)
    )
    guard let event = NSEvent(cgEvent: cgEvent) else {
        throw UITestFailure(message: "could not bridge a wheel event")
    }
    return event
}

private func makeMouseEvent(
    type: NSEvent.EventType,
    location: NSPoint,
    modifiers: NSEvent.ModifierFlags = [],
    clickCount: Int = 1
) throws -> NSEvent {
    guard let event = NSEvent.mouseEvent(
        with: type,
        location: location,
        modifierFlags: modifiers,
        timestamp: 1,
        windowNumber: 0,
        context: nil,
        eventNumber: 1,
        clickCount: clickCount,
        pressure: 1
    ) else {
        throw UITestFailure(message: "could not synthesize \(type)")
    }
    return event
}

/// `NSEvent.mouseEvent(with:)` builds an other-button event whose `buttonNumber` is
/// always zero, which the pane's middle-button guard rejects, so the middle button can
/// only be driven through a CGEvent that carries the number -- the same detour the wheel
/// helper above takes for its phase fields.
///
/// `location` is the same window-space point every other event helper here takes. A
/// CGEvent's own space has its origin at the top left of the main display and
/// `NSEvent(cgEvent:)` flips it back around that same display, so the flip is undone up
/// front rather than left for each caller to reason about.
private func makeMiddleMouseEvent(
    type: CGEventType,
    location: NSPoint
) throws -> NSEvent {
    let flipped = CGPoint(
        x: location.x,
        y: CGDisplayBounds(CGMainDisplayID()).height - location.y
    )
    guard let cgEvent = CGEvent(
        mouseEventSource: nil,
        mouseType: type,
        mouseCursorPosition: flipped,
        mouseButton: .center
    ) else {
        throw UITestFailure(message: "could not synthesize \(type)")
    }
    // A source-less CGEvent is born carrying whatever modifier keys are physically down
    // right now, so the flags are stated rather than inherited: without this the test
    // reads the keyboard of whoever is at the machine while the suite runs.
    cgEvent.flags = []
    guard let event = NSEvent(cgEvent: cgEvent) else {
        throw UITestFailure(message: "could not bridge \(type)")
    }
    return event
}

private func makePointerExitEvent(
    location: NSPoint,
    modifiers: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    guard let event = NSEvent.enterExitEvent(
        with: .mouseExited,
        location: location,
        modifierFlags: modifiers,
        timestamp: 1,
        windowNumber: 0,
        context: nil,
        eventNumber: 1,
        trackingNumber: 1,
        userData: nil
    ) else {
        throw UITestFailure(message: "could not synthesize mouseExited")
    }
    return event
}

private func cgEventFlags(_ modifiers: NSEvent.ModifierFlags) -> CGEventFlags {
    var flags: CGEventFlags = []
    if modifiers.contains(.shift) { flags.insert(.maskShift) }
    if modifiers.contains(.control) { flags.insert(.maskControl) }
    if modifiers.contains(.option) { flags.insert(.maskAlternate) }
    return flags
}

private func scrollPhaseCode(_ phase: NSEvent.Phase) -> Int64 {
    if phase.contains(.began) { return 1 }
    if phase.contains(.changed) { return 2 }
    if phase.contains(.ended) || phase.contains(.cancelled) { return 4 }
    return 0
}

private func momentumPhaseCode(_ phase: NSEvent.Phase) -> Int64 {
    if phase.contains(.began) { return 1 }
    if phase.contains(.changed) { return 2 }
    if phase.contains(.ended) || phase.contains(.cancelled) { return 3 }
    return 0
}

/// Runs the main run loop for `seconds`, so main-queue work the pane scheduled
/// -- the pending-presentation retry above all -- actually gets to run.
@MainActor
private func pumpRunLoop(seconds: TimeInterval) async {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        await pumpMainQueueOnce()
    }
}

/// Pumps until `condition` holds, or gives up after a deadline generous enough
/// that a slow machine cannot fail the test while a genuinely stalled retry
/// still does.
@MainActor
private func pumpRunLoop(untilTrue condition: () -> Bool, deadline: TimeInterval = 30.0) async {
    let end = Date().addingTimeInterval(deadline)
    while Date() < end && condition() == false {
        await pumpMainQueueOnce()
    }
}

@MainActor
private func makeMountedPane(
    controller: FakeTerminalPaneSessionController,
    copyOnSelect: Bool = DanTermConfig.default.copyOnSelect
) -> SwiftTerminalSessionView {
    let pane = makeUnmountedPane(controller: controller, copyOnSelect: copyOnSelect)
    mountInTestWindow(pane, frame: pane.frame)
    return pane
}

/// A pane sized but not in a window, so it has resolved no geometry yet: the state a
/// freshly created pane is in until its first layout pass, and the only way to test what
/// an input that arrives before that resolution does.
@MainActor
private func makeUnmountedPane(
    controller: FakeTerminalPaneSessionController,
    copyOnSelect: Bool = DanTermConfig.default.copyOnSelect
) -> SwiftTerminalSessionView {
    let pane = makeTestPane(controller: controller, copyOnSelect: copyOnSelect)
    pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
    return pane
}

/// A child view that can hold first-responder status so a nil-targeted action can be dispatched
/// up the responder chain (child -> pane) instead of being invoked on the pane directly.
private final class FirstResponderProbeView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// Produces a bounded one-callback-at-a-time frame stream for AppKit input ordering tests.
@MainActor
private final class SustainedFrameProducer {
    private let controller: FakeTerminalPaneSessionController
    private var remainingFrameCount: Int
    private(set) var isComplete = false

    init(controller: FakeTerminalPaneSessionController, frameCount: Int) {
        self.controller = controller
        remainingFrameCount = frameCount
    }

    func start() {
        scheduleNextFrame()
    }

    private func scheduleNextFrame() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            controller.emitFrameForTest()
            remainingFrameCount -= 1
            if remainingFrameCount == 0 {
                isComplete = true
            } else {
                scheduleNextFrame()
            }
        }
    }
}

@MainActor
private func mountInTestWindow(_ view: NSView, frame: NSRect) {
    let window = NSWindow(contentRect: frame, styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    retainedSwiftPaneWindows.append(window)
}

/// A window whose backing scale a case can state and then move.
///
/// It is the only way the suite can drive a display transition: a real window reports
/// whatever scale the machine it runs on has, and no test may depend on the developer
/// having two displays of different density attached.
private final class ScaledTestWindow: NSWindow {
    var scale: CGFloat = 2
    override var backingScaleFactor: CGFloat { scale }

    /// Moves the window to a display of a different density, exactly as AppKit reports
    /// it: the scale changes, then the mounted view is told its backing properties did.
    @MainActor
    func moveToDisplay(scale newScale: CGFloat) {
        scale = newScale
        contentView?.viewDidChangeBackingProperties()
    }
}

@MainActor
private func mountInScaledTestWindow(
    _ view: NSView,
    frame: NSRect,
    scale: CGFloat
) -> ScaledTestWindow {
    let window = ScaledTestWindow(
        contentRect: frame,
        styleMask: [],
        backing: .buffered,
        defer: false
    )
    window.scale = scale
    window.isReleasedWhenClosed = false
    window.contentView = view
    retainedSwiftPaneWindows.append(window)
    return window
}

/// Dispatches one key event the way AppKit does for a Command chord: the view hierarchy is
/// offered the key equivalent first, and only an unclaimed event reaches the responder chain.
/// `NSApp.sendEvent` would carry the whole truth, including the menu, but it is scoped to the
/// key window, which the headless harness has no way to produce.
@MainActor
private func dispatchKeyEvent(_ event: NSEvent, in window: NSWindow) {
    guard window.performKeyEquivalent(with: event) == false else { return }
    window.sendEvent(event)
}

private func makeKeyEvent(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    characters: String = "",
    charactersIgnoringModifiers: String? = nil,
    timestamp: TimeInterval = 1
) throws -> NSEvent {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: timestamp,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
        isARepeat: false,
        keyCode: keyCode
    ) else {
        throw UITestFailure(message: "could not synthesize keyCode \(keyCode)")
    }
    return event
}

private extension NSEvent.ModifierFlags {
    static let leftOption = Self(rawValue: UInt(NX_DEVICELALTKEYMASK))
    static let rightOption = Self(rawValue: UInt(NX_DEVICERALTKEYMASK))
}

private func makeFlagsChangedEvent(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags
) throws -> NSEvent {
    guard let event = NSEvent.keyEvent(
        with: .flagsChanged,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 1,
        windowNumber: 0,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: keyCode
    ) else {
        throw UITestFailure(message: "could not synthesize flagsChanged for keyCode \(keyCode)")
    }
    return event
}
