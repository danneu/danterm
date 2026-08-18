// UI-harness coverage for native pointer, wheel, copy, and scrollbar routing in the Swift pane.
import Cocoa
import CoreGraphics
import PaneProcessLifecycle

@MainActor private var retainedSwiftPaneWindows: [NSWindow] = []

@MainActor
func swiftTerminalSessionViewTests() {
    print("SwiftTerminalSessionView")

    uiTest("search commands route through the Swift pane controller") {
        // Intent: every search entry point reaches the engine controller with its semantic input.
        // Why it exists: the real view gained search routing while the UI controller shim stayed
        //   incomplete, preventing the harness from compiling and leaving this adapter untested.
        // Scenario: the user opens find, types a needle, navigates both ways, clears it, and closes.
        let controller = TerminalPaneSessionController()
        let pane = SwiftTerminalSessionView(controller: controller)
        var events: [TerminalSessionEvent] = []
        pane.onEvent = { events.append($0) }

        pane.startSearch()
        pane.setSearchNeedle("needle")
        pane.navigateSearch(.next)
        pane.navigateSearch(.previous)
        pane.setSearchNeedle("")
        pane.endSearch()

        try uiExpect(events == [.searchStarted("")], "search start did not mount the overlay")
        try uiExpect(controller.searchQueries == ["needle"],
                     "search needle routing diverged: \(controller.searchQueries)")
        try uiExpect(controller.searchNextRequests == 1, "next search was not routed once")
        try uiExpect(controller.searchPreviousRequests == 1, "previous search was not routed once")
        try uiExpect(controller.clearSearchRequests == 2,
                     "empty needle and end did not both clear search")
    }

    uiTest("theme application resolves names and falls back to dark") {
        // Intent: complete themes apply while every unresolved name reaches the dark fallback.
        // Why it exists: hand-edited catalog misses must never retain stale pane colors.
        // Scenario: a user applies a valid theme, two invalid names, then clears the override.
        let controller = TerminalPaneSessionController()
        let resolved = RenderTheme(defaultBackground: .init(red: 12, green: 34, blue: 56))
        let pane = SwiftTerminalSessionView(
            controller: controller,
            resolveTheme: { $0 == "Known" ? resolved : nil }
        )

        pane.applyTheme("Known")
        pane.applyTheme("Missing")
        pane.applyTheme("../Known")
        pane.clearTheme()

        try uiExpect(
            controller.appliedThemes.map(\.defaultBackground) == [
                resolved.defaultBackground,
                RenderTheme.dark.defaultBackground,
                RenderTheme.dark.defaultBackground,
                RenderTheme.dark.defaultBackground,
            ],
            "theme dispatch changed on failed resolution: \(controller.appliedThemes)"
        )
    }

    uiTest("session state carries the theme background and republishes on a theme change") {
        // Intent: `state.background` is the pane's current terminal default
        //   background before any theme is applied, and a theme swap pushes a
        //   fresh state to the observer carrying the new one.
        // Why it exists: the focus-ring gutter lives outside this view and takes
        //   its color off this channel. Without the construction-time value a
        //   pane shows an unthemed gutter until its first theme change; without
        //   the emit on `applyTheme`, it never catches up at all.
        let controller = TerminalPaneSessionController()
        let themed = RenderTheme(defaultBackground: .init(red: 12, green: 34, blue: 56))
        let pane = SwiftTerminalSessionView(
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

    uiTest("font size updates live cell metrics and reports the resized PTY grid") {
        let controller = TerminalPaneSessionController()
        let pane = SwiftTerminalSessionView(controller: controller, fontSize: 13)
        pane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(pane, frame: pane.frame)

        try uiExpect(controller.gridDimensions.last == TerminalDimensions(columns: 12, rows: 12),
                     "initial configured font did not size the PTY grid")

        pane.setFontSize(26)

        try uiExpect(controller.gridDimensions.last == TerminalDimensions(columns: 6, rows: 6),
                     "live font change did not resize the PTY grid")
        try uiExpect(pane.state.cellHeight == 32, "live font change did not update cell metrics")
    }

    uiTest("font family updates live cell metrics and resizes the PTY grid") {
        // Intent: a resolved family handed to a live pane re-derives cell geometry and
        //   the grid the child process is told about.
        // Why it exists: the family reaches panes the same way the font size does, so
        //   without this the reconciler could push a family that never leaves the view.
        // Scenario: spec-first -- the user picks a new font family in Preferences and
        //   saves; open panes must repaint on the new grid with no reload.
        let controller = TerminalPaneSessionController()
        let pane = SwiftTerminalSessionView(controller: controller, fontSize: 13)
        pane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(pane, frame: pane.frame)

        pane.setFontFamily(TerminalRenderMetrics.wideFamily)

        try uiExpect(controller.gridDimensions.last == TerminalDimensions(columns: 6, rows: 12),
                     "live family change did not resize the PTY grid")
    }

    uiTest("a family without usable metrics falls back to system monospace") {
        // Intent: a family that passes availability but cannot yield grid metrics still
        //   leaves the pane with valid metrics and grid dimensions, both at creation and
        //   on a live change away from a working family.
        // Why it exists: an unusable configured face must fall back to system monospace;
        //   synchronizePresentation used to bail outright on nil metrics, leaving a new pane
        //   blank and freezing an existing pane on its old grid until restart.
        // Scenario: spec-first -- an installed but degenerate face named in config.
        let created = TerminalPaneSessionController()
        let createdPane = SwiftTerminalSessionView(
            controller: created,
            fontSize: 13,
            fontFamily: TerminalRenderMetrics.unusableFamily
        )
        createdPane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(createdPane, frame: createdPane.frame)

        try uiExpect(created.gridDimensions.last == TerminalDimensions(columns: 12, rows: 12),
                     "an unusable configured family left a new pane without geometry")
        try uiExpect(createdPane.state.cellHeight == 16,
                     "an unusable configured family left a new pane without cell metrics")

        let live = TerminalPaneSessionController()
        let livePane = SwiftTerminalSessionView(
            controller: live,
            fontSize: 13,
            fontFamily: TerminalRenderMetrics.wideFamily
        )
        livePane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(livePane, frame: livePane.frame)
        try uiExpect(live.gridDimensions.last == TerminalDimensions(columns: 6, rows: 12),
                     "the working family did not size the grid before the fallback case")

        livePane.setFontFamily(TerminalRenderMetrics.unusableFamily)

        try uiExpect(live.gridDimensions.last == TerminalDimensions(columns: 12, rows: 12),
                     "an unusable family froze an existing pane on its old grid")
    }

    uiTest("a pane smaller than one cell still reports the floored grid") {
        // Intent: a pane whose bounds do not hold a whole grid reports the sizing floors --
        //   two columns and one row -- rather than a zero-width or zero-height grid.
        // Why it exists: a zero dimension reaches the child as an invalid winsize, and the
        //   floors are the only thing between a dragged-shut divider and that state. The
        //   harness used to re-declare the sizing function without them, so the app could
        //   have lost the floors with every UI test still green.
        // Scenario: spec-first -- the user drags a divider until the pane is a sliver.
        let controller = TerminalPaneSessionController()
        let pane = SwiftTerminalSessionView(controller: controller, fontSize: 13)
        pane.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        mountInTestWindow(pane, frame: pane.frame)

        try uiExpect(controller.gridDimensions.last == TerminalDimensions(columns: 2, rows: 1),
                     "a sliver pane did not report the floored grid: \(controller.gridDimensions)")
    }

    uiTest("a grid override drives the pane's grid and no rectangle change disturbs it") {
        // Intent: setting an override submits exactly that grid once, every later
        //   rectangle change submits nothing at all, and clearing submits exactly
        //   the grid the pane's current rectangle derives.
        // Why it exists: a claimed pane runs at the claiming client's size. If a
        //   resize still reached the child the Mac's own layout would silently
        //   undo the claim, which is the whole reason the override exists.
        // Scenario: spec-first -- the phone claims a pane at 60x30, then the user
        //   drags the Mac window's divider, then takes the pane back.
        let controller = TerminalPaneSessionController()
        let pane = SwiftTerminalSessionView(controller: controller, fontSize: 13)
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
        try uiExpect(controller.gridDimensions.last == TerminalDimensions(columns: 25, rows: 25),
                     "clearing did not return the pane to its rectangle's grid: \(controller.gridDimensions)")
    }

    uiTest("a font change under an override moves cell metrics but not the grid") {
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
        let controller = TerminalPaneSessionController()
        let pane = SwiftTerminalSessionView(controller: controller, fontSize: 13)
        pane.frame = NSRect(x: 0, y: 0, width: 1200, height: 1200)
        mountInTestWindow(pane, frame: pane.frame)
        pane.setGridOverride(PaneGridOverride(columns: 60, rows: 30))
        let gridsAfterClaim = controller.gridDimensions.count

        pane.setFontSize(26)

        try uiExpect(
            controller.gridDimensions.count == gridsAfterClaim,
            "a font change under an override submitted a grid: \(controller.gridDimensions)"
        )
        try uiExpect(pane.state.cellHeight == 32,
                     "a font change under an override did not update cell metrics: \(pane.state.cellHeight)")
    }

    uiTest("a pane created with an override submits only that grid") {
        // Intent: a pane that starts overridden reports the override as its very
        //   first grid, with no rectangle-derived grid ahead of it.
        // Why it exists: a restored pane's child must never observe a size no
        //   client asked for. An earlier grid would reach the PTY as a real
        //   winsize and show up on the pane's tape.
        // Scenario: spec-first -- the app restarts with a pane the phone had
        //   claimed at 60x30.
        let controller = TerminalPaneSessionController()
        let pane = SwiftTerminalSessionView(
            controller: controller,
            fontSize: 13,
            gridOverride: PaneGridOverride(columns: 60, rows: 30)
        )
        pane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(pane, frame: pane.frame)

        try uiExpect(controller.gridDimensions == [TerminalDimensions(columns: 60, rows: 30)],
                     "a pane created overridden submitted another grid: \(controller.gridDimensions)")
    }

    uiTest("a claimed grid that fits its slot renders at native cell metrics with blank surround") {
        // Intent: a claim smaller than the pane's rectangle draws at the pane's
        //   own scale, at the top-left corner, leaving the rest of the slot empty.
        // Why it exists: the Mac shows a claimed pane as the claiming client sees
        //   it. Stretching a small grid over the slot would show the user a size
        //   nobody is running at.
        // Scenario: spec-first -- the phone claims a large Mac pane at 10x5.
        let controller = TerminalPaneSessionController()
        let pane = SwiftTerminalSessionView(controller: controller, fontSize: 13)
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

    uiTest("a claimed grid larger than its slot is drawn down uniformly into the slot's pixels") {
        // Intent: an oversized claim shrinks by one factor on both axes, and the
        //   surface it renders into stays inside the pane's own pixel extent.
        // Why it exists: the shrink has to happen while drawing. A buffer sized to
        //   the claimed grid and scaled afterwards would let one remote request
        //   allocate pixels the pane never had room for.
        // Scenario: spec-first -- a phone claims 60x30 on a Mac pane too small to
        //   show that grid at its own cell size.
        let controller = TerminalPaneSessionController()
        let pane = SwiftTerminalSessionView(controller: controller, fontSize: 13)
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
        let horizontal = claimed.cellSize.width / native.cellSize.width
        let vertical = claimed.cellSize.height / native.cellSize.height
        try uiExpect(abs(horizontal - vertical) < 0.0001,
                     "the shrink was not uniform: \(horizontal) horizontally, \(vertical) vertically")
        try uiExpect(horizontal < 1, "an oversized claim did not shrink the cell box: \(horizontal)")
    }

    uiTest("pointer input maps through the transform a drawn-down claim is shown at") {
        // Intent: a click on a shrunk claimed grid names the cell drawn under the
        //   pointer, not the cell the same point would name at native cell size.
        // Why it exists: the grid the user sees and the grid the engine is told
        //   about have to be the same one. Hit-testing against the rendered cell
        //   box would offset every selection and every mouse-mode report.
        // Scenario: spec-first -- the user right-clicks inside a pane the phone
        //   claimed at 60x30.
        let controller = TerminalPaneSessionController()
        let pane = SwiftTerminalSessionView(controller: controller, fontSize: 13)
        pane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(pane, frame: pane.frame)
        guard let native = pane.presentationGeometryForTesting else {
            throw UITestFailure(message: "an unclaimed pane reported no presentation geometry")
        }
        pane.setGridOverride(PaneGridOverride(columns: 60, rows: 30))
        guard let claimed = pane.presentationGeometryForTesting else {
            throw UITestFailure(message: "a claimed pane reported no presentation geometry")
        }
        var menuCells: [TerminalViewportCell] = []
        pane.paneMenuHandler = { menuCells.append($0) }

        // Window coordinates are bottom-up; the pane is flipped, so this lands at
        // (30, 50) inside it.
        let location = NSPoint(x: 30, y: 150)
        pane.rightMouseDown(with: try makeMouseEvent(type: .rightMouseDown, location: location))
        pane.rightMouseUp(with: try makeMouseEvent(type: .rightMouseUp, location: location))

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
        try uiExpect(menuCells == [shown],
                     "the click did not name the cell drawn under it: \(menuCells)")
    }

    uiTest("geometry that is not finite or is out of Int range yields no grid and no cell") {
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

    uiTest("initial theme fills before draw and the retained first plan publishes on mount") {
        // Intent: the view paints themed chrome immediately and adopts the controller's first plan.
        // Why it exists: waiting for child output creates a dark flash on restore and split inheritance.
        // Scenario: a themed controller with a retained plan mounts before its child writes a byte.
        let prefill = RenderTheme(defaultBackground: .init(red: 11, green: 22, blue: 33))
        let planned = RenderColor(red: 44, green: 55, blue: 66)
        let controller = TerminalPaneSessionController(
            theme: prefill,
            currentPlan: RenderFramePlan(defaultBackground: planned)
        )
        let pane = SwiftTerminalSessionView(controller: controller)

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

    uiTest("engine search status maps into paired product events") {
        // Intent: each atomic engine status becomes the total and selected events the model expects.
        // Why it exists: splitting one engine value into two callbacks must preserve nil, empty,
        //   and zero-based matched semantics without leaving stale counter state.
        // Scenario: a search is cleared, misses, then selects the third of five matches.
        let controller = TerminalPaneSessionController()
        let pane = SwiftTerminalSessionView(controller: controller)
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

    uiTest("pane registers and accepts only supported drag types") {
        // Intent: the Swift pane participates in AppKit dragging for file URLs, URLs, and strings.
        // Why it exists: destination callbacks are never sent unless the view registers its types.
        // Scenario: supported and unrelated pasteboards enter a mounted Swift-engine pane.
        let pane = makeMountedPane(controller: TerminalPaneSessionController())
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

    uiTest("file drop sends shell-quoted content through bracketed paste") {
        // Intent: dropped file paths use shared drag quoting and owner-side paste policy.
        // Why it exists: a raw write would permit control injection and omit DEC 2004 markers.
        // Scenario: Finder drops a path containing a space onto a bracketed-paste pane.
        let controller = TerminalPaneSessionController()
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

    uiTest("browser URL drop takes priority over its plain string") {
        // Intent: a non-file URL is shell-quoted instead of falling through to plain text.
        // Why it exists: browser drags commonly advertise both URL and string representations.
        // Scenario: a link with shell metacharacters is dragged from a browser into the pane.
        let controller = TerminalPaneSessionController()
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

    uiTest("unbracketed multiline drop converts newlines and filters controls") {
        // Intent: drag input inherits unbracketed paste encoding and control filtering.
        // Why it exists: the residual auto-execute behavior must be explicit without admitting
        //   escape-sequence injection through a raw terminal write.
        // Scenario: a plain-text drag contains two lines and an embedded escape character.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        let pasteboard = makePasteboard()
        pasteboard.setString("one\u{1B}\ntwo", forType: .string)

        let performed = pane.performDragOperation(DraggingInfoStub(pasteboard: pasteboard))

        try uiExpect(performed, "multiline string drop was not performed")
        try uiExpect(controller.inputBytes == [Array("one\rtwo".utf8)],
                     "unbracketed paste encoding diverged: \(controller.inputBytes)")
    }

    uiTest("empty drop writes nothing") {
        let controller = TerminalPaneSessionController()
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

    uiTest("a mounted pane renders one complete frame and submits nothing at a draw seam") {
        // Intent: the first frame reaches the screen through the owned surface --
        //   one render covering every row -- and no AppKit drawing happens at all.
        // Why it exists: research/33 T25 I4. The draw seam is deleted, so a pane
        //   that came up blank, or one that quietly regrew a second render path,
        //   would both show here and nowhere else.
        // Scenario: a pane is mounted in a window, which is the first moment it
        //   has geometry to render at.
        TerminalFrameSwapchain.resetForTesting()
        let controller = TerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = SwiftTerminalSessionView(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)

        try uiExpect(
            TerminalFrameSwapchain.renderedRowSetsForTesting
                == [Set(0..<RenderFramePlan.rowsForTesting)],
            "mounting did not render exactly one complete frame: "
                + "\(TerminalFrameSwapchain.renderedRowSetsForTesting)"
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

    uiTest("a publish renders exactly the rows its damage names") {
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
        TerminalFrameSwapchain.resetForTesting()
        let controller = TerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = SwiftTerminalSessionView(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        TerminalFrameSwapchain.resetForTesting()
        pane.resetSurfaceCountersForTesting()

        controller.emitFrameForTest(damage: .init(rows: [1]))
        controller.emitFrameForTest(damage: .init(rows: [8]))
        controller.emitFrameForTest(damage: .full)

        try uiExpect(
            TerminalFrameSwapchain.renderedRowSetsForTesting
                == [[1], [8], Set(0..<RenderFramePlan.rowsForTesting)],
            "publishes did not render exactly their own damage: "
                + "\(TerminalFrameSwapchain.renderedRowSetsForTesting)"
        )
        try uiExpect(
            pane.renderCountForTesting == pane.publishCountForTesting,
            "renders (\(pane.renderCountForTesting)) diverged from publications "
                + "(\(pane.publishCountForTesting))"
        )
    }

    uiTest("an AppKit-initiated redisplay renders nothing") {
        // Intent: a layer display callback reattaches and returns; it never
        //   renders and never asks the engine for anything.
        // Why it exists: research/33 T25 PO5's second assertion. The old draw
        //   path rendered whatever AppKit asked for, which is how an occlusion
        //   return or a sibling's relayout could bill a full glyph redraw to
        //   nobody's frame. With the pane owning its pixels there is nothing
        //   for AppKit to ask for, and this is what proves it stayed that way.
        // Scenario: a mounted pane is invalidated the way AppKit invalidates it.
        TerminalFrameSwapchain.resetForTesting()
        let controller = TerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = SwiftTerminalSessionView(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        pane.resetSurfaceCountersForTesting()
        TerminalFrameSwapchain.resetForTesting()

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
            TerminalFrameSwapchain.renderedRowSetsForTesting.isEmpty,
            "an AppKit redisplay reached the surface: "
                + "\(TerminalFrameSwapchain.renderedRowSetsForTesting)"
        )
    }

    uiTest("a coalesced burst renders its last plan on a retry, then goes quiet") {
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
        TerminalFrameSwapchain.resetForTesting()
        let controller = TerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = SwiftTerminalSessionView(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        pane.resetSurfaceCountersForTesting()
        TerminalFrameSwapchain.resetForTesting()

        TerminalFrameSwapchain.canAcquireForTesting = false
        controller.emitFrameForTest(damage: .init(rows: [2]))
        controller.emitFrameForTest(damage: .init(rows: [4]))
        controller.emitFrameForTest(damage: .init(rows: [6]))
        try uiExpect(
            pane.renderCountForTesting == 0,
            "an unacquirable swapchain still rendered \(pane.renderCountForTesting) time(s)"
        )
        try uiExpect(
            pane.hasPendingPresentationForTesting,
            "the coalesced burst left no pending presentation to retry"
        )

        TerminalFrameSwapchain.canAcquireForTesting = true
        pumpRunLoop(untilTrue: { pane.hasPendingPresentationForTesting == false })

        try uiExpect(
            pane.hasPendingPresentationForTesting == false,
            "the pending presentation never rendered after buffers freed"
        )
        try uiExpect(
            TerminalFrameSwapchain.renderedRowSetsForTesting == [[2, 4, 6]],
            "the retry did not render the burst's composed damage once: "
                + "\(TerminalFrameSwapchain.renderedRowSetsForTesting)"
        )

        // No further output arrives; the pane must stop retrying by itself.
        let rendersAfterRetry = pane.renderCountForTesting
        pumpRunLoop(seconds: 0.15)
        try uiExpect(
            pane.renderCountForTesting == rendersAfterRetry,
            "a quiet pane kept rendering: \(pane.renderCountForTesting) vs \(rendersAfterRetry)"
        )
    }

    uiTest("a metrics change replaces the swapchain and re-renders the current plan") {
        // Intent: cell geometry moving -- through a font change here, through a
        //   backing-scale change on a display move, through a resize -- discards
        //   the buffers and renders the current plan afresh.
        // Why it exists: I3's trust rule. Those buffers hold pixels at the old
        //   pixel geometry; no damage value can bring them current, and bringing
        //   them current is exactly what the swapchain would otherwise try.
        //   Nothing publishes on a scale change either, so the view has to
        //   re-render on its own or the pane freezes on the old frame.
        // Scenario: a mounted pane's font size changes.
        TerminalFrameSwapchain.resetForTesting()
        let controller = TerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = SwiftTerminalSessionView(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        let swapchainsAtMount = TerminalFrameSwapchain.creationCountForTesting
        TerminalFrameSwapchain.resetForTesting()
        pane.resetSurfaceCountersForTesting()

        try uiExpect(swapchainsAtMount == 1, "mounting built \(swapchainsAtMount) swapchains")
        pane.setFontSize(26)

        try uiExpect(
            TerminalFrameSwapchain.creationCountForTesting == 1,
            "the metrics change did not replace the swapchain: "
                + "\(TerminalFrameSwapchain.creationCountForTesting)"
        )
        try uiExpect(
            TerminalFrameSwapchain.renderedRowSetsForTesting
                == [Set(0..<RenderFramePlan.rowsForTesting)],
            "the replacement did not render a complete frame: "
                + "\(TerminalFrameSwapchain.renderedRowSetsForTesting)"
        )
    }

    uiTest("a resized grid replaces the swapchain") {
        // Intent: a publish carrying a differently-shaped grid builds new
        //   buffers instead of trying to bring the old ones current.
        // Why it exists: I3's trust rule again, through the door a resize
        //   actually uses. Metrics are unchanged across a plain resize -- the
        //   cell box is the same -- so the shape has to be read off the plan,
        //   and a swapchain sized to the old grid would refuse or misplace
        //   every row of the new one.
        // Scenario: the engine republishes after a SIGWINCH added two rows.
        TerminalFrameSwapchain.resetForTesting()
        let controller = TerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = SwiftTerminalSessionView(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        TerminalFrameSwapchain.resetForTesting()

        let resizedRows = RenderFramePlan.rowsForTesting + 2
        controller.currentPlan = RenderFramePlan(
            defaultBackground: RenderTheme.dark.defaultBackground,
            rows: resizedRows
        )
        controller.emitFrameForTest(damage: .full)

        try uiExpect(
            TerminalFrameSwapchain.creationCountForTesting == 1,
            "the resized grid did not replace the swapchain: "
                + "\(TerminalFrameSwapchain.creationCountForTesting)"
        )
        try uiExpect(
            TerminalFrameSwapchain.renderedRowSetsForTesting == [Set(0..<resizedRows)],
            "the resized grid did not render a complete frame at its new height: "
                + "\(TerminalFrameSwapchain.renderedRowSetsForTesting)"
        )
    }

    uiTest("a theme change replaces the swapchain") {
        // Intent: applying a theme discards the buffers rather than trusting
        //   them for a later incremental render.
        // Why it exists: a theme repaints every row, including rows no damage
        //   will ever name. A detached buffer brought current by damage alone
        //   would keep the old theme's colors in every quiet row -- the one
        //   trust-breaking input no value comparison on geometry can see.
        // Scenario: a mounted pane is given a theme with a different background.
        TerminalFrameSwapchain.resetForTesting()
        let controller = TerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let resolved = RenderTheme(defaultBackground: .init(red: 12, green: 34, blue: 56))
        let pane = SwiftTerminalSessionView(
            controller: controller,
            resolveTheme: { $0 == "Known" ? resolved : nil }
        )
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        TerminalFrameSwapchain.resetForTesting()

        pane.applyTheme("Known")

        try uiExpect(
            TerminalFrameSwapchain.creationCountForTesting == 1,
            "the theme change did not replace the swapchain: "
                + "\(TerminalFrameSwapchain.creationCountForTesting)"
        )
        try uiExpect(
            TerminalFrameSwapchain.renderedRowSetsForTesting
                == [Set(0..<RenderFramePlan.rowsForTesting)],
            "the theme change did not render a complete frame: "
                + "\(TerminalFrameSwapchain.renderedRowSetsForTesting)"
        )
    }

    uiTest("a window color-space change replaces the swapchain at unchanged geometry") {
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
        TerminalFrameSwapchain.resetForTesting()
        let controller = TerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = SwiftTerminalSessionView(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        guard let window = pane.window else {
            throw UITestFailure(message: "the mounted pane has no window")
        }
        let before = window.colorSpace
        TerminalFrameSwapchain.resetForTesting()

        window.colorSpace = before == NSColorSpace.displayP3
            ? NSColorSpace.sRGB
            : NSColorSpace.displayP3
        pane.viewDidChangeBackingProperties()

        try uiExpect(
            TerminalFrameSwapchain.creationCountForTesting == 1,
            "the color-space change did not replace the swapchain: "
                + "\(TerminalFrameSwapchain.creationCountForTesting)"
        )
        try uiExpect(
            TerminalFrameSwapchain.renderedRowSetsForTesting
                == [Set(0..<RenderFramePlan.rowsForTesting)],
            "the color-space change did not render a complete frame: "
                + "\(TerminalFrameSwapchain.renderedRowSetsForTesting)"
        )
    }

    uiTest("the screen-change refresh sees a window color-space move") {
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
        TerminalFrameSwapchain.resetForTesting()
        let controller = TerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = SwiftTerminalSessionView(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        guard let window = pane.window else {
            throw UITestFailure(message: "the mounted pane has no window")
        }
        let before = window.colorSpace
        TerminalFrameSwapchain.resetForTesting()

        window.colorSpace = before == NSColorSpace.displayP3
            ? NSColorSpace.sRGB
            : NSColorSpace.displayP3
        pane.refreshPresentation()

        try uiExpect(
            TerminalFrameSwapchain.creationCountForTesting == 1,
            "the screen-change refresh did not replace the swapchain: "
                + "\(TerminalFrameSwapchain.creationCountForTesting)"
        )
        try uiExpect(
            TerminalFrameSwapchain.renderedRowSetsForTesting
                == [Set(0..<RenderFramePlan.rowsForTesting)],
            "the screen-change refresh did not render a complete frame: "
                + "\(TerminalFrameSwapchain.renderedRowSetsForTesting)"
        )
    }

    uiTest("a resize that changes the grid leaves the render to the republish") {
        // Intent: a resize submits the new grid and stops there. The view does not
        //   render the plan it is holding, because that plan was built for the old
        //   shape; the engine's republish is what puts the new shape on screen.
        // Why it exists: the presentation-input test reads columns and rows off the
        //   live swapchain rather than off the dimensions just computed. Reading
        //   them off the new dimensions would render a stale plan and build buffers
        //   the next publish immediately throws away.
        // Scenario: a user drags a divider, narrowing a pane by whole cells.
        TerminalFrameSwapchain.resetForTesting()
        let controller = TerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = SwiftTerminalSessionView(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        let gridsAtMount = controller.gridDimensions.count
        TerminalFrameSwapchain.resetForTesting()
        pane.resetSurfaceCountersForTesting()

        pane.setFrameSize(NSSize(width: 40, height: 160))

        try uiExpect(
            controller.gridDimensions.count == gridsAtMount + 1,
            "the resize did not submit one new grid: \(controller.gridDimensions)"
        )
        try uiExpect(
            TerminalFrameSwapchain.creationCountForTesting == 0,
            "the resize built a swapchain before the republish: "
                + "\(TerminalFrameSwapchain.creationCountForTesting)"
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
            TerminalFrameSwapchain.creationCountForTesting == 1,
            "the republish did not replace the swapchain: "
                + "\(TerminalFrameSwapchain.creationCountForTesting)"
        )
        try uiExpect(
            pane.renderCountForTesting == 1,
            "the republish did not render once: \(pane.renderCountForTesting)"
        )
    }

    uiTest("a pane resized to a zero dimension submits nothing and renders nothing") {
        // Intent: bounds with no area leave the grid, the swapchain, and the frame
        //   on screen exactly as they were.
        // Why it exists: scale and pixel size are one invariant
        //   (docs/design/2026-03-05-display-scaling.md), so a zero-area surface has
        //   no valid geometry to derive. A zero dimension reaching the child is an
        //   invalid winsize, and a zero-sized swapchain is an allocation that fails.
        // Scenario: a user drags a divider fully shut, or a pane's host collapses it
        //   to a zero-height strip during a layout pass.
        TerminalFrameSwapchain.resetForTesting()
        let controller = TerminalPaneSessionController(
            currentPlan: RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        )
        let pane = SwiftTerminalSessionView(controller: controller)
        pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
        mountInTestWindow(pane, frame: pane.frame)
        let gridsAtMount = controller.gridDimensions.count
        TerminalFrameSwapchain.resetForTesting()
        pane.resetSurfaceCountersForTesting()

        pane.setFrameSize(NSSize(width: 80, height: 0))

        try uiExpect(
            controller.gridDimensions.count == gridsAtMount,
            "a zero-height pane submitted a grid: \(controller.gridDimensions)"
        )
        try uiExpect(
            TerminalFrameSwapchain.creationCountForTesting == 0,
            "a zero-height pane built a swapchain: "
                + "\(TerminalFrameSwapchain.creationCountForTesting)"
        )
        try uiExpect(
            pane.renderCountForTesting == 0,
            "a zero-height pane rendered: \(pane.renderCountForTesting)"
        )
    }

    uiTest("a metrics change publishes the new cell geometry to the state observer") {
        // Intent: new cell metrics reach the state observer, not just the pane's own
        //   live `state` getter.
        // Why it exists: `ScrollableTerminalView` is that observer and re-reads state
        //   on each callback, so a dropped emit leaves the scrollbar on its old
        //   document geometry until some unrelated event forces a sync. The existing
        //   font-size coverage reads `pane.state.cellHeight`, which is a live getter
        //   and stays correct even with the emit gone.
        // Scenario: a user changes the terminal font size in Preferences.
        let controller = TerminalPaneSessionController()
        let pane = SwiftTerminalSessionView(controller: controller, fontSize: 13)
        pane.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        mountInTestWindow(pane, frame: pane.frame)
        let observer = SwiftPaneStateObserver()
        pane.stateObserver = observer

        pane.setFontSize(26)

        try uiExpect(
            observer.states.last?.cellHeight == 32,
            "the metrics change published no new cell height: "
                + "\(String(describing: observer.states.last?.cellHeight))"
        )
    }

    uiTest("semantic notifications and progress cross the AppKit adapter") {
        let controller = TerminalPaneSessionController()
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

    uiTest("mounted pane forwards fractional wheel metadata once") {
        // Intent: the Swift pane converts a line wheel event into one owner-side row intent
        //   and terminates responder-chain handling at the pane.
        // Why it exists: the enclosing terminal scroll view forwards wheel events to the
        //   pane, so calling super would bounce the same event back through the scroll view.
        // Scenario: a user wheels upward by two line units over a mounted Swift pane.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        let enclosingScrollView = WheelBounceSentinelScrollView()
        pane.nextResponder = enclosingScrollView
        let event = try makeScrollWheelEvent(
            units: .line,
            deltaY: 2,
            location: .init(x: 17, y: 125),
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

    uiTest("pointer callbacks normalize cells buttons modifiers and click counts") {
        // Intent: every native left-button transition becomes one platform-neutral pointer event.
        // Why it exists: view-side routing or point-space forwarding would bypass owner policy.
        // Scenario: a Shift-double-click drag crosses cells and releases beyond the viewport.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)

        pane.mouseDown(with: try makeMouseEvent(
            type: .leftMouseDown,
            location: .init(x: 17, y: 125),
            modifiers: [.shift],
            clickCount: 2
        ))
        pane.mouseDragged(with: try makeMouseEvent(
            type: .leftMouseDragged,
            location: .init(x: 31, y: 111),
            modifiers: [.shift]
        ))
        pane.mouseUp(with: try makeMouseEvent(
            type: .leftMouseUp,
            location: .init(x: 200, y: -40),
            modifiers: [.shift]
        ))

        // Cells are 8 points wide here, so x=17 and x=31 land an eighth and seven eighths of
        // the way into their columns: the sub-cell position character selection resolves a
        // boundary from has to survive the view boundary, not just the column.
        try uiExpect(controller.pointerEvents == [
            .down(.left, column: 2, row: 2, offsetX: 0.125, modifiers: [.shift], clickCount: 2),
            .move(column: 3, row: 3, offsetX: 0.875, modifiers: [.shift]),
            .up(.left, column: 9, row: 9, modifiers: [.shift]),
        ], "pointer normalization diverged: \(controller.pointerEvents)")
        try uiExpect(controller.linkInteractionCancellations == 1,
                     "out-of-bounds release did not cancel link interaction first")
    }

    uiTest("wheel direct and momentum phases reach the owner unchanged") {
        // Intent: precise fractional motion and its direct/momentum lifecycle reach the owner.
        // Why it exists: route latching and remainder ownership both depend on these boundaries.
        // Scenario: a trackpad gesture ends its direct phase and continues with momentum.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)

        for phase in [NSEvent.Phase.began, .changed, .ended] {
            pane.scrollWheel(with: try makeScrollWheelEvent(
                units: .pixel,
                deltaY: 4,
                location: .init(x: 9, y: 143),
                phase: phase
            ))
        }
        for phase in [NSEvent.Phase.began, .changed, .ended] {
            pane.scrollWheel(with: try makeScrollWheelEvent(
                units: .pixel,
                deltaY: 4,
                location: .init(x: 9, y: 143),
                momentumPhase: phase
            ))
        }

        try uiExpect(controller.wheelEvents.map(\.phase) == [
            .began, .changed, .ended, .momentumBegan, .momentumChanged, .momentumEnded,
        ], "wheel phase normalization diverged: \(controller.wheelEvents)")
        try uiExpect(controller.wheelEvents.allSatisfy { $0.rowDelta == -0.25 },
                     "precise wheel motion was quantized in the view")
    }

    uiTest("automatic menus stay suppressed and owner menu requests arrive after right up") {
        // Intent: only the serialized owner can authorize a terminal-view context menu.
        // Why it exists: AppKit's automatic down-time lookup races child mouse-capture modes.
        // Scenario: an uncaptured right-click opens after up, then a captured click does not reopen.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        var menuCells: [TerminalViewportCell] = []
        pane.paneMenuHandler = { menuCells.append($0) }
        let down = try makeMouseEvent(type: .rightMouseDown, location: .init(x: 17, y: 125))
        let up = try makeMouseEvent(type: .rightMouseUp, location: .init(x: 17, y: 125))

        try uiExpect(pane.menu(for: down) == nil, "AppKit menu lookup was not suppressed")
        pane.rightMouseDown(with: down)
        try uiExpect(menuCells.isEmpty, "pane menu opened before button-up")
        pane.rightMouseUp(with: up)
        try uiExpect(menuCells == [.init(column: 2, row: 2)], "pane menu did not follow owner up")

        controller.allowsPaneMenu = false
        pane.rightMouseDown(with: down)
        pane.rightMouseUp(with: up)
        try uiExpect(menuCells.count == 1, "captured right-click reopened the dismissed menu")
    }

    uiTest("control click uses the owner right-button lifecycle") {
        // Intent: macOS Control-click is normalized as a right-button gesture before owner policy.
        // Why it exists: AppKit otherwise asks for a menu before delivering the mouse lifecycle.
        // Scenario: a shell Control-click opens the pane menu only after its synthesized right up.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        var menuCells: [TerminalViewportCell] = []
        pane.paneMenuHandler = { menuCells.append($0) }
        let down = try makeMouseEvent(
            type: .leftMouseDown,
            location: .init(x: 9, y: 143),
            modifiers: [.control]
        )
        let up = try makeMouseEvent(
            type: .leftMouseUp,
            location: .init(x: 9, y: 143),
            modifiers: [.control]
        )

        try uiExpect(pane.menu(for: down) == nil, "control-click menu lookup was not suppressed")
        pane.mouseDown(with: down)
        pane.mouseUp(with: up)

        try uiExpect(controller.pointerEvents == [
            .down(.right, column: 1, row: 1, offsetX: 0.125, modifiers: [.control], clickCount: 1),
            .up(.right, column: 1, row: 1, modifiers: [.control]),
        ], "control-click escaped the right-button owner lifecycle")
        try uiExpect(menuCells == [.init(column: 1, row: 1)], "control-click menu was not deferred")
    }

    uiTest("only a click that takes key focus reports pane focus") {
        // Intent: the gesture that hands this pane key focus reports it, and no
        //   other button reports anything.
        // Why it exists: focus reports come from interaction sites now. AppKit's
        //   window moves the responder for a left-button press -- control-click
        //   included, which arrives here and is routed onward as a right click --
        //   and moves nothing for a genuine right or middle press. A report on
        //   those would invent a focus change the user never asked for.
        // Scenario: one mounted pane takes a plain click, a control-click, a right
        //   click, and an other-button press. The other-button press is dropped by
        //   that entry point's own middle-button guard, so its arm pins the weaker
        //   claim that nothing escapes `otherMouseDown` by any path.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        var events: [TerminalSessionEvent] = []
        pane.onEvent = { events.append($0) }
        let point = NSPoint(x: 9, y: 143)

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

    uiTest("gaining first responder reports nothing and only tells the engine") {
        // Intent: a responder gain is presentation state, never a model fact.
        // Why it exists: the pane-focus pass repairs the responder to this view, and
        //   AppKit calls becomeFirstResponder from inside that call. A report here
        //   is a Msg originated by a reconcile sweep, laundered through AppKit's own
        //   responder dispatch where the lint script cannot see it.
        // Scenario: the pane is made first responder programmatically, the way the
        //   pass does it.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        var events: [TerminalSessionEvent] = []
        pane.onEvent = { events.append($0) }

        try uiExpect(pane.window?.makeFirstResponder(pane) == true, "window refused the pane")

        try uiExpect(events.isEmpty, "a responder gain reported \(events)")
        try uiExpect(controller.focusChanges == [true],
                     "focus reached the engine as \(controller.focusChanges)")
    }

    uiTest("explicit copy fences selection and hasSelection stays cache-only") {
        // Intent: Copy fences pending selection work while menu enablement reads only cached state.
        // Why it exists: asynchronous drag consumption must not put stale text on the pasteboard.
        // Scenario: a selection ends immediately before the user invokes Copy.
        let controller = TerminalPaneSessionController()
        controller.selectedTextOnFence = "alpha"
        let pane = makeMountedPane(controller: controller)
        let pasteboard = NSPasteboard(name: .init("danterm.swift-selection-test"))
        pasteboard.clearContents()
        pane.selectionPasteboard = pasteboard

        try uiExpect(pane.hasSelection == false, "selection cache unexpectedly fenced the owner")
        pane.mouseDown(with: try makeMouseEvent(
            type: .leftMouseDown,
            location: .init(x: 1, y: 159)
        ))
        pane.mouseUp(with: try makeMouseEvent(
            type: .leftMouseUp,
            location: .init(x: 17, y: 159)
        ))
        pane.copySelection()

        try uiExpect(controller.synchronizedSelectionReads == 1, "copy did not fence the owner")
        try uiExpect(pasteboard.string(forType: .string) == "alpha", "copy missed finalized text")
        try uiExpect(pane.hasSelection, "cached selection did not refresh after fenced copy")
    }

    uiTest("Edit > Copy routes through the responder chain and validates on cached selection") {
        // Intent: the standard `copy(_:)` action copies the selection, and Edit > Copy is
        //   enabled only while a selection exists, without disturbing Paste.
        // Why it exists: the Swift engine declines Command keys in `keyDown`, so Cmd-C only
        //   works if the pane owns `copy(_:)` on the responder chain; over-broad validation
        //   would silently disable unrelated Edit items such as Paste.
        // Scenario: a user drag-selects output, presses Cmd-C, then clicks to clear it.
        let controller = TerminalPaneSessionController()
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
            location: .init(x: 1, y: 159)
        ))
        pane.mouseUp(with: try makeMouseEvent(
            type: .leftMouseUp,
            location: .init(x: 17, y: 159)
        ))
        pane.copy(nil)

        try uiExpect(pasteboard.string(forType: .string) == "beta",
                     "responder-chain copy missed finalized text")
        try uiExpect(pane.validateMenuItem(copyItem), "Copy stayed disabled with a selection")
        try uiExpect(pane.validateMenuItem(pasteItem), "Paste validation tracked the selection")
    }

    uiTest("copy-on-select writes a relayed selection only while it is armed") {
        // Intent: arming copy-on-select puts a completed selection's relayed text on the
        //   pasteboard, and disarming stops the engine relaying anything at all.
        // Why it exists: the option is a subscriber, not a branch -- if disarming only
        //   suppressed the write, the engine would still pay to extract the text.
        // Scenario: spec-first; the user unticks "Copy selection to clipboard" and drags.
        let controller = TerminalPaneSessionController()
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

    uiTest("Cmd-C copies the same in both copy-on-select modes") {
        // Intent: arming or disarming copy-on-select leaves the explicit copy path alone.
        // Why it exists: the option governs what a gesture does, never what Cmd-C does.
        // Scenario: spec-first; the user copies by hand with the option on, then off.
        let controller = TerminalPaneSessionController()
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

    uiTest("Edit > Select All routes through the responder chain and validates as enabled") {
        // Intent: the nil-targeted `selectAll(_:)` action reaches the pane through AppKit's
        //   responder-chain lookup, produces a selection the pane reports, and leaves
        //   Edit > Select All validating as enabled.
        // Why it exists: the Swift engine declines Command keys in `keyDown`, so Cmd-A only
        //   works if the pane owns `selectAll(_:)` on the responder chain; dispatching through
        //   the chain (not calling the method directly) is the point -- a direct call would pass
        //   even if the menu item stayed disabled or the action resolved to another responder.
        // Scenario: a user makes the pane first responder and presses Cmd-A.
        let controller = TerminalPaneSessionController()
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

    uiTest("Command-modified keys produce no terminal input") {
        // Intent: Cmd-C and Cmd-A are owned by the menu/responder chain and never encoded as
        //   terminal input.
        // Why it exists: a fix that reintroduced a Command branch in `keyDown` would send a
        //   stray byte to the shell whenever such a shortcut fell through -- for Cmd-A, the
        //   `\x01` the line editor uses for start-of-line.
        // Scenario: the user presses Cmd-C then Cmd-A on a mounted pane with no selection.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        let before = controller.inputBytes

        pane.keyDown(with: try makeKeyEvent(keyCode: 8, modifiers: [.command], characters: "c"))
        pane.keyDown(with: try makeKeyEvent(keyCode: 0, modifiers: [.command], characters: "a"))

        try uiExpect(controller.inputBytes == before,
                     "Command key leaked terminal input: \(controller.inputBytes)")
    }

    uiTest("OSC 52 writes and empty clears reach the injected pasteboard") {
        // Intent: delivered terminal clipboard effects write only at the AppKit boundary.
        // Why it exists: presentation gating and top-level model routing must not own OSC 52 data.
        // Scenario: a remote program writes text, then clears the general clipboard selection.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        let pasteboard = NSPasteboard(name: .init("danterm.swift-osc52-test"))
        pasteboard.clearContents()
        pane.selectionPasteboard = pasteboard

        controller.emitClipboardWrite("hello")
        try uiExpect(pasteboard.string(forType: .string) == "hello", "OSC 52 write was lost")
        controller.emitClipboardWrite("")
        try uiExpect(pasteboard.string(forType: .string) == "", "empty OSC 52 did not clear")
    }

    uiTest("tracking area delivers mouse moves to the normalized adapter") {
        // Intent: the pane continuously forwards normalized hover motion without a mode mirror.
        // Why it exists: any-motion capture can begin from child output between native callbacks.
        // Scenario: an Option-modified pointer move lands over a visible terminal cell.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        pane.updateTrackingAreas()

        try uiExpect(pane.trackingAreas.contains { $0.options.contains(.mouseMoved) },
                     "pane installed no mouse-move tracking area")
        try uiExpect(pane.trackingAreas.contains { $0.options.contains(.mouseEnteredAndExited) },
                     "pane installed no pointer-entry/exit tracking area")
        pane.mouseMoved(with: try makeMouseEvent(
            type: .mouseMoved,
            location: .init(x: 17, y: 125),
            modifiers: [.option]
        ))
        try uiExpect(controller.pointerEvents == [
            .move(column: 2, row: 2, offsetX: 0.125, modifiers: [.alt]),
        ], "mouse move did not reach the owner adapter")
    }

    uiTest("Cmd-click forwards Command and opens only boundary-valid web URLs") {
        // Intent: AppKit forwards Command intent to owner policy, then independently validates
        //   the click-time target before invoking the injected system opener.
        // Why it exists: terminal output must not reach file or custom URL handlers even if
        //   engine validation regresses or a malformed target crosses the owner boundary.
        // Scenario: a user Cmd-clicks links with valid HTTP(S), unsafe, and malformed targets.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        var opened: [URL] = []
        pane.linkOpener = { url in
            opened.append(url)
            return true
        }

        let down = try makeMouseEvent(
            type: .leftMouseDown,
            location: .init(x: 17, y: 125),
            modifiers: [.command]
        )
        let up = try makeMouseEvent(
            type: .leftMouseUp,
            location: .init(x: 17, y: 125),
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
                column: 2,
                row: 2,
                offsetX: 0.125,
                modifiers: [.command],
                clickCount: 1
            ),
            "Cmd-down lost Command intent"
        )
        try uiExpect(
            controller.pointerEvents.dropFirst().first == .up(
                .left,
                column: 2,
                row: 2,
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

    uiTest("Cmd flags changes replay the stationary pointer and update link chrome") {
        // Intent: pressing and releasing Command without moving refreshes owner hover and native
        //   chrome at the last terminal position.
        // Why it exists: AppKit does not emit mouseMoved merely because modifier flags changed.
        // Scenario: the pointer rests over a web link while the user presses and releases Cmd.
        let controller = TerminalPaneSessionController()
        controller.hoveredLinkForCommandMove = .init(uri: "https://example.com/stationary")
        let pane = makeMountedPane(controller: controller)
        pane.mouseMoved(with: try makeMouseEvent(
            type: .mouseMoved,
            location: .init(x: 17, y: 125)
        ))

        pane.flagsChanged(with: try makeFlagsChangedEvent(keyCode: 55, modifiers: [.command]))

        try uiExpect(controller.pointerEvents.suffix(2) == [
            .move(column: 2, row: 2, offsetX: 0.125),
            .move(column: 2, row: 2, offsetX: 0.125, modifiers: [.command]),
        ], "Cmd press did not replay the last pointer cell")
        let preview = pane.subviews.compactMap { $0 as? LinkPreviewView }.first
        try uiExpect(preview?.isHidden == false, "hover did not show the URL pill")
        try uiExpect(
            preview?.label.stringValue == "https://example.com/stationary",
            "URL pill did not show the hovered target"
        )
        try uiExpect(NSCursor.current == .pointingHand, "hover did not install pointing-hand cursor")

        pane.flagsChanged(with: try makeFlagsChangedEvent(keyCode: 55, modifiers: []))

        try uiExpect(controller.pointerEvents.last == .move(column: 2, row: 2, offsetX: 0.125),
                     "Cmd release did not replay the last pointer cell")
        try uiExpect(preview?.isHidden == true, "Cmd release did not hide the URL pill")

        NSCursor.crosshair.set()
        controller.emitFrameForTest()
        try uiExpect(NSCursor.current == .crosshair,
                     "an unrelated render frame overwrote the current cursor")
    }

    uiTest("pointer exit clears hover and cancels a pending link click") {
        // Intent: leaving the viewport clears presentation and invalidates the owner-side arm.
        // Why it exists: a later release must not activate a link whose gesture left the pane.
        // Scenario: the user Cmd-presses a link, leaves the pane, then releases over the old cell.
        let controller = TerminalPaneSessionController()
        let link = TerminalHyperlink(uri: "https://example.com/exit")
        controller.hoveredLinkForCommandMove = link
        controller.linkForCommandClick = link
        let pane = makeMountedPane(controller: controller)
        var opened: [URL] = []
        pane.linkOpener = { url in opened.append(url); return true }

        pane.mouseMoved(with: try makeMouseEvent(
            type: .mouseMoved,
            location: .init(x: 17, y: 125),
            modifiers: [.command]
        ))
        pane.mouseDown(with: try makeMouseEvent(
            type: .leftMouseDown,
            location: .init(x: 17, y: 125),
            modifiers: [.command]
        ))
        pane.mouseExited(with: try makePointerExitEvent(
            location: .init(x: 81, y: 125),
            modifiers: [.command]
        ))
        pane.mouseUp(with: try makeMouseEvent(
            type: .leftMouseUp,
            location: .init(x: 17, y: 125),
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

    uiTest("pane maps viewport state and scrollbar commands through the controller") {
        let controller = TerminalPaneSessionController()
        let pane = SwiftTerminalSessionView(controller: controller)
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

    uiTest("composition commits text before terminal key encoding") {
        // Intent: marked-text composition commits through sendText even while Kitty mode is active.
        // Why it exists: terminal key encoding must never reinterpret native Option/dead-key text.
        // Scenario: AppKit reports the marked and committed phases of Option+e, e as acute e.
        let controller = TerminalPaneSessionController()
        controller.inputModes.kittyKeyboardFlags = 1
        let pane = SwiftTerminalSessionView(controller: controller)

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

    uiTest("multi-stage Chinese IME commits only final text through native input") {
        // Intent: successive Chinese IME marked-text replacements stay local until AppKit
        //   commits the final candidate through the native text-input callback.
        // Why it exists: partial candidates or their backing key events must not reach the PTY,
        //   and the final commit must not also be encoded as a terminal key.
        // Scenario: Pinyin input advances through "n", "ni", and a selected Chinese candidate
        //   before AppKit commits the two-character phrase.
        let controller = TerminalPaneSessionController()
        controller.inputModes.kittyKeyboardFlags = 1
        let pane = SwiftTerminalSessionView(controller: controller)
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

    uiTest("control punctuation and function keys normalize into core bytes") {
        // Intent: layout-derived Control punctuation and function keys retain semantic identity.
        // Why it exists: AppKit mutates Control characters and represents function keys as PUA text.
        // Scenario: a user enters the ASCII control-punctuation set, then F3 in Kitty mode.
        let controller = TerminalPaneSessionController()
        let pane = SwiftTerminalSessionView(controller: controller)
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

        controller.inputModes.kittyKeyboardFlags = 1
        pane.keyDown(with: try makeKeyEvent(keyCode: 99, modifiers: []))
        try uiExpect(controller.inputBytes.last == Array("\u{1B}[13~".utf8),
                     "F3 did not use Kitty encoding: \(String(describing: controller.inputBytes.last))")
    }

    uiTest("a keystroke's origin is the system event's own occurrence time") {
        // Intent: both `keyDown` routes -- committed text and a fixed terminal key -- attribute
        // their bytes to the time the system created the event.
        // Why it exists: the pane recorder charges the distance between that origin and the
        // completed write to the app, so a handler that sampled its own clock instead would
        // charge every stall ahead of it to the child, which is the ambiguity the tape removes.
        // Scenario: two key events that occurred at 2.5s and 3.5s of uptime reach the pane.
        let controller = TerminalPaneSessionController()
        let pane = SwiftTerminalSessionView(controller: controller)

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

    uiTest("a GUI keystroke submitted before spawn is delivered after process start") {
        // Intent: the real AppKit key route accepts input while the pane process is spawning,
        //   then delivers it when that process starts.
        // Why it exists: GUI input shares the lifecycle path with IPC input, and the old
        //   pre-running reducer arm silently discarded keystrokes.
        // Scenario: a deterministic spawning controller receives K before its process-start edge.
        let controller = TerminalPaneSessionController(processIsRunning: false)
        let pane = SwiftTerminalSessionView(controller: controller)

        pane.keyDown(with: try makeKeyEvent(keyCode: 40, modifiers: [], characters: "k"))

        try uiExpect(controller.textInputs == ["k"], "AppKit input did not reach the controller")
        try uiExpect(controller.deliveredTextInputs.isEmpty,
                     "spawning controller delivered the keystroke before process start")

        controller.emitProcessStarted()

        try uiExpect(controller.deliveredTextInputs == ["k"],
                     "process start did not deliver the buffered GUI keystroke exactly once")
    }

    uiTest("a refused submission names its reason and reaches the app boundary rejected") {
        // Intent: when lifecycle policy refuses a submission, the reason stays attached to
        //   the terminal result, and the pane reports the refusal to the app as a rejection.
        // Why it exists: an input that never crossed the descriptor must not read as
        //   delivered anywhere. The harness used to model the result as a payload-free
        //   `rejected`, so no UI test could tell one refusal from another -- or check that
        //   a refusal leaves the delivered-input record untouched.
        // Scenario: spec-first -- the pane's pending-input bound is already full when the
        //   user pastes, and then the child's shell fails to launch at all.
        let controller = TerminalPaneSessionController()
        controller.submissionFailure = .bufferLimitExceeded
        let pane = SwiftTerminalSessionView(controller: controller)
        var results: [TerminalInputSubmissionResult] = []
        pane.sendInputText("ls") { results.append($0) }
        controller.submissionFailure = .launchFailed(.noUsableShell)
        pane.sendInputText("pwd") { results.append($0) }

        pumpRunLoop(untilTrue: { results.count == 2 })

        try uiExpect(
            controller.completedResults == [
                .rejected(.bufferLimitExceeded),
                .rejected(.launchFailed(.noUsableShell)),
            ],
            "a refused submission lost the reason it was refused: \(controller.completedResults)"
        )
        try uiExpect(results == [.rejected, .rejected],
                     "a refused submission did not reach the app as a rejection: \(results)")
        try uiExpect(controller.deliveredTextInputs.isEmpty,
                     "a refused submission was recorded as delivered: \(controller.deliveredTextInputs)")
    }

    uiTest("the pane forwards a session result carrying what ended the child") {
        // Intent: the result the pane hands its owner is the whole lifecycle result, exit
        //   status and launch failure included, and each arm still emits its own event.
        // Why it exists: the owner decides whether to keep a pane open from why the child
        //   ended. The harness used to model the result as two payload-free cases, so a
        //   view that dropped the payload would have kept every UI test green.
        // Scenario: spec-first -- one child is killed by a signal, and a second pane's
        //   shell cannot be launched at all.
        let controller = TerminalPaneSessionController()
        var results: [PaneProcessLifecycleResult] = []
        let pane = SwiftTerminalSessionView(controller: controller) { results.append($0) }
        var events: [TerminalSessionEvent] = []
        pane.onEvent = { events.append($0) }

        controller.onSessionEnded?(.exited(.signaled(9)))
        controller.onSessionEnded?(.launchFailed(.noUsableShell))

        try uiExpect(results == [.exited(.signaled(9)), .launchFailed(.noUsableShell)],
                     "the pane dropped the payload explaining the session result: \(results)")
        try uiExpect(events == [.processExited, .processLaunchFailed],
                     "the session result arms did not emit their own events: \(events)")
    }

    uiTest("input the app originates carries the time it entered the pane") {
        // Intent: input with no system event behind it -- the IPC text and key entries -- still
        // reports an origin, taken as it enters the pane.
        // Why it exists: an absent origin means "these bytes originated at the pane owner", so
        // an unstamped IPC submission would misattribute the app's own queueing to the owner.
        // Scenario: the control socket sends one text run and one named key.
        let controller = TerminalPaneSessionController()
        let pane = SwiftTerminalSessionView(controller: controller)

        let before = DispatchTime.now().uptimeNanoseconds
        pane.sendInputText("ls")
        pane.sendInputKey(.named(.enter), modifiers: [])
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

    uiTest("keyboard input runs before a sustained frame stream completes") {
        // Intent: the real AppKit key route reaches the pane controller before a
        //   continuing stream of visible frame callbacks finishes.
        // Why it exists: real-PTY convergence cannot detect a view or responder path
        //   that becomes inert while the main actor is processing visible output.
        // Scenario: one-at-a-time frame callbacks keep rearming while a queued K key
        //   event crosses `keyDown`; the stream then drains to its final frame.
        let controller = TerminalPaneSessionController()
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

        let hangGuard = Date(timeIntervalSinceNow: 2)
        while producer.isComplete == false, Date() < hangGuard {
            RunLoop.main.run(mode: .default, before: hangGuard)
        }

        try uiExpect(producer.isComplete, "sustained frame stream did not converge")
        try uiExpect(inputArrivedBeforeCompletion, "keyboard input waited for final output")
        try uiExpect(controller.textInputs == ["k"], "AppKit key did not reach the pane controller")
    }

    uiTest("numeric keypad keys retain their semantic identity") {
        // Intent: keypad text is encoded as a keypad key instead of ordinary committed text.
        // Why it exists: application-keypad mode changes bytes even though AppKit supplies a digit.
        // Scenario: the child enables DECKPAM and the user presses keypad zero.
        let controller = TerminalPaneSessionController()
        controller.inputModes.applicationKeypad = true
        let pane = SwiftTerminalSessionView(controller: controller)

        pane.keyDown(with: try makeKeyEvent(
            keyCode: 82,
            modifiers: [.numericPad],
            characters: "0"
        ))

        try uiExpect(controller.textInputs.isEmpty, "keypad zero escaped through the text path")
        try uiExpect(controller.inputBytes == [Array("\u{1B}Op".utf8)],
                     "keypad zero lost application-keypad semantics: \(controller.inputBytes)")
    }

    uiTest("menu and context paste share the owner-side safe-paste path") {
        // Intent: both AppKit paste entry points submit raw clipboard text to owner-side policy.
        // Why it exists: bypassing the owner could admit escape injection or skip bracket markers.
        // Scenario: Edit > Paste and the pane menu paste text containing an embedded marker.
        // The scratch pasteboard is not incidental: both entry points read
        // `selectionPasteboard`, so assigning one here keeps the harness off the
        // developer's real clipboard the way the copy tests above already do.
        let controller = TerminalPaneSessionController()
        controller.inputModes.bracketedPaste = true
        let pane = SwiftTerminalSessionView(controller: controller)
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

    uiTest("IPC text pastes while structured input text stays raw") {
        // Intent: `Command.sendText` reaches the pane as a paste, and `Command.sendInputText`
        //   reaches it as raw committed text.
        // Why it exists: the two commands are only meaningfully different at this adapter, and
        //   the IPC `text` field is documented as the paste path -- sanitized and bracketed --
        //   while structured `input` text must arrive as if typed.
        // Scenario: an IPC caller sends `{text: ...}` and then `{input: [...]}` containing the
        //   same escape-bearing string into a pane with bracketed paste active.
        let controller = TerminalPaneSessionController()
        controller.inputModes.bracketedPaste = true
        let pane = SwiftTerminalSessionView(controller: controller)
        let payload = "one\u{1B}[201~\ntwo"

        pane.sendText(payload)
        pane.sendInputText(payload)

        try uiExpect(controller.inputBytes == [Array("\u{1B}[200~one[201~\ntwo\u{1B}[201~".utf8)],
                     "IPC text lost paste semantics: \(controller.inputBytes)")
        try uiExpect(controller.textInputs == [payload],
                     "structured input text gained paste semantics: \(controller.textInputs)")
    }

    uiTest("runtime and responder focus signals are deduplicated") {
        // Intent: logical pane focus and first-responder callbacks share one transition funnel.
        // Why it exists: AppKit and reconcile commonly report the same transition back-to-back.
        // Scenario: a pane gains and loses focus through both signal sources with mode 1004 active.
        let controller = TerminalPaneSessionController()
        controller.inputModes.focusReporting = true
        let pane = SwiftTerminalSessionView(controller: controller)

        pane.setFocused(true)
        _ = pane.becomeFirstResponder()
        pane.setFocused(true)
        _ = pane.resignFirstResponder()
        pane.setFocused(false)

        try uiExpect(controller.focusChanges == [true, false],
                     "focus funnel emitted duplicates: \(controller.focusChanges)")
        try uiExpect(controller.inputBytes == [Array("\u{1B}[I".utf8), Array("\u{1B}[O".utf8)],
                     "focus reports were not owner-gated: \(controller.inputBytes)")
    }

    uiTest("a released pane is unreachable by every controller callback") {
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
        let controller = TerminalPaneSessionController()
        var events: [TerminalSessionEvent] = []
        weak var released: SwiftTerminalSessionView?

        autoreleasepool {
            let pane = SwiftTerminalSessionView(controller: controller)
            pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
            pane.onEvent = { events.append($0) }
            released = pane

            let window = NSWindow(
                contentRect: pane.frame, styleMask: [], backing: .buffered, defer: false)
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

    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }

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
    deltaY: Int32,
    location: CGPoint = .zero,
    modifiers: NSEvent.ModifierFlags = [],
    phase: NSEvent.Phase = [],
    momentumPhase: NSEvent.Phase = []
) throws -> NSEvent {
    guard let cgEvent = CGEvent(
        scrollWheelEvent2Source: nil,
        units: units,
        wheelCount: 1,
        wheel1: deltaY,
        wheel2: 0,
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
private func pumpRunLoop(seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
}

/// Pumps until `condition` holds, or gives up after a deadline generous enough
/// that a slow machine cannot fail the test while a genuinely stalled retry
/// still does.
@MainActor
private func pumpRunLoop(untilTrue condition: () -> Bool, deadline: TimeInterval = 2.0) {
    let end = Date().addingTimeInterval(deadline)
    while Date() < end && condition() == false {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
}

@MainActor
private func makeMountedPane(controller: TerminalPaneSessionController) -> SwiftTerminalSessionView {
    let pane = SwiftTerminalSessionView(controller: controller)
    pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
    mountInTestWindow(pane, frame: pane.frame)
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
    private let controller: TerminalPaneSessionController
    private var remainingFrameCount: Int
    private(set) var isComplete = false

    init(controller: TerminalPaneSessionController, frameCount: Int) {
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
    window.contentView = view
    retainedSwiftPaneWindows.append(window)
}

private func makeKeyEvent(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    characters: String = "",
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
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    ) else {
        throw UITestFailure(message: "could not synthesize keyCode \(keyCode)")
    }
    return event
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
