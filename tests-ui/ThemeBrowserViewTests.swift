// UI-harness tests for ThemeBrowserView's catalog rendering, filtering,
// selection dispatch, context-menu shape, and AppKit menu-target lifetime.
import Cocoa

/// Registers ThemeBrowserView coverage in the standalone UI harness.
func themeBrowserViewTests() {
    print("ThemeBrowserView")

    uiTest("runtime catalog projects complete swatches and resolves names without paths") {
        // Intent: one decoded entry drives both browser colors and the renderer bridge.
        // Why it exists: separate parsing paths can drift, and untrusted names must never become paths.
        // Scenario: the browser renders a packed theme and a remote traversal-like key is rejected.
        let catalog = ThemeCatalog(data: fixtureThemeCatalogData())

        try uiExpect(catalog.names == ["Fixture"], "runtime names diverged: \(catalog.names)")
        guard let colors = catalog.swatchColors(named: "Fixture") else {
            throw UITestFailure(message: "missing fixture swatch")
        }
        guard let background = colors.background.usingColorSpace(.sRGB) else {
            throw UITestFailure(message: "swatch background is not convertible to sRGB")
        }
        let channels = (
            UInt8((background.redComponent * 255).rounded()),
            UInt8((background.greenComponent * 255).rounded()),
            UInt8((background.blueComponent * 255).rounded())
        )
        try uiExpect(
            channels == (4, 5, 6),
            "swatch did not project the decoded theme background: \(channels)"
        )
        try uiExpect(
            catalog.renderTheme(named: "Fixture")?.defaultBackground
                == RenderColor(red: 4, green: 5, blue: 6),
            "renderer bridge did not project the decoded theme"
        )
        try uiExpect(catalog.renderTheme(named: "../Fixture") == nil,
                     "path traversal resolved outside exact catalog keys")
    }

    uiTest("unreadable and malformed catalogs expose no partial themes") {
        // Intent: resource failures collapse to an empty catalog rather than partial theme state.
        // Why it exists: runtime theme completeness is all-or-nothing across the packed resource.
        // Scenario: the bundle read fails or returns malformed JSON during application startup.
        try uiExpect(ThemeCatalog(data: nil).names.isEmpty, "missing resource exposed themes")
        try uiExpect(
            ThemeCatalog(data: Data("{not-json".utf8)).names.isEmpty,
            "malformed resource exposed themes"
        )
    }

    uiTest("constructs against an empty catalog and applies a projection without dispatch") {
        let runtime = AppRuntime()
        let view = ThemeBrowserView()
        view.runtime = runtime
        view.reloadTable()
        view.apply(ThemeBrowserProjection(currentThemeName: nil))

        try uiExpect(runtime.sentMessages.isEmpty, "apply must not dispatch")
    }

    uiTest("search filter narrows rows case-insensitively") {
        let fx = makeThemeBrowserFixture()
        defer { fx.window.close() }

        setSearch("gru", in: fx)

        try uiExpect(fx.view.tableView.numberOfRows == 2, "expected two filtered rows")
        try uiExpect(try cellText(row: 0, in: fx) == "Gruvbox Dark", "first filtered row mismatch")
        try uiExpect(try cellText(row: 1, in: fx) == "Gruvbox Light", "second filtered row mismatch")
    }

    uiTest("theme cell wires a swatch view") {
        // Intent: the row cell built by viewFor carries a ColorSwatchView
        //   installed in the cell with the swatchView back-reference set.
        // Why it exists: cellText() only reads textField, so before this pin the
        //   swatch subtree could be dropped entirely without failing the suite;
        //   this guards the cell-factory extraction.
        // Scenario: spec-first; pins existing rendering ahead of refactoring the
        //   duplicated viewFor bodies into ThemeBrowserCellView.themeCell.
        let fx = makeThemeBrowserFixture()
        defer { fx.window.close() }
        settleThemeBrowserFixture(fx)

        guard let cell = fx.view.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ThemeBrowserCellView else {
            throw UITestFailure(message: "missing theme cell at row 0")
        }
        guard let swatch = cell.swatchView else {
            throw UITestFailure(message: "cell should carry a swatch view")
        }
        try uiExpect(swatch.superview === cell, "swatch should be installed in the cell")
    }

    uiTest("clearing the filter restores all rows") {
        let fx = makeThemeBrowserFixture()
        defer { fx.window.close() }

        setSearch("gru", in: fx)
        setSearch("", in: fx)

        try uiExpect(fx.view.tableView.numberOfRows == fx.names.count, "all rows should be restored")
    }

    uiTest("no-match filter yields zero rows") {
        let fx = makeThemeBrowserFixture()
        defer { fx.window.close() }

        setSearch("zzz", in: fx)

        try uiExpect(fx.view.tableView.numberOfRows == 0, "no-match query should show zero rows")
    }

    uiTest("selection sends setPaneTheme for the focused pane") {
        let fx = makeThemeBrowserFixture()
        defer { fx.window.close() }

        fx.view.tableView.selectRowIndexes(IndexSet(integer: try rowIndex(of: "Nord", in: fx)), byExtendingSelection: false)

        try expectSingleSetPaneTheme(fx.runtime, paneId: fx.paneId, themeName: "Nord")
    }

    uiTest("selection after filtering targets the filtered index") {
        let fx = makeThemeBrowserFixture()
        defer { fx.window.close() }

        setSearch("gru", in: fx)
        fx.view.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        try expectSingleSetPaneTheme(fx.runtime, paneId: fx.paneId, themeName: "Gruvbox Light")
    }

    uiTest("re-selecting the current theme sends nothing") {
        let fx = makeThemeBrowserFixture(currentTheme: "Nord")
        defer { fx.window.close() }

        fx.view.tableView.selectRowIndexes(IndexSet(integer: try rowIndex(of: "Nord", in: fx)), byExtendingSelection: false)

        try uiExpect(fx.runtime.sentMessages.isEmpty, "re-selecting current theme should not dispatch")
    }

    uiTest("apply moves selection and checkmark without dispatching") {
        let fx = makeThemeBrowserFixture()
        defer { fx.window.close() }

        fx.view.apply(ThemeBrowserProjection(currentThemeName: "Nord"))
        settleThemeBrowserFixture(fx)

        let nordRow = try rowIndex(of: "Nord", in: fx)
        try uiExpect(fx.view.tableView.selectedRow == nordRow, "Nord row should be selected")
        try uiExpect(try cellText(row: fx.view.tableView.selectedRow, in: fx) == "\u{2713} Nord", "Nord row should show checkmark")
        try uiExpect(!fx.view.resetButton.isHidden, "reset button should show with a current theme")
        try uiExpect(fx.runtime.sentMessages.isEmpty, "apply should not dispatch")
    }

    uiTest("apply nil clears checkmark, reset visibility, and selection") {
        let fx = makeThemeBrowserFixture(currentTheme: "Nord")
        defer { fx.window.close() }

        fx.view.apply(ThemeBrowserProjection(currentThemeName: nil))
        settleThemeBrowserFixture(fx)

        try uiExpect(fx.view.resetButton.isHidden, "reset button should hide without a current theme")
        try uiExpect(fx.view.tableView.selectedRow == -1, "selection should clear")
        try uiExpect(try cellText(row: try rowIndex(of: "Nord", in: fx), in: fx) == "Nord", "Nord row should not show checkmark")
        try uiExpect(fx.runtime.sentMessages.isEmpty, "apply should not dispatch")
    }

    uiTest("filtering keeps the current theme's row selected without dispatch") {
        let fx = makeThemeBrowserFixture(currentTheme: "Gruvbox Dark")
        defer { fx.window.close() }

        setSearch("gru", in: fx)

        try uiExpect(fx.view.tableView.selectedRow == 0, "filtered current theme should remain selected")
        try uiExpect(fx.runtime.sentMessages.isEmpty, "filtering should not dispatch")
    }

    uiTest("filtering away the current theme deselects") {
        let fx = makeThemeBrowserFixture(currentTheme: "Nord")
        defer { fx.window.close() }

        setSearch("gru", in: fx)

        try uiExpect(fx.view.tableView.selectedRow == -1, "filtered-away current theme should deselect")
        try uiExpect(fx.runtime.sentMessages.isEmpty, "filtering should not dispatch")
    }

    uiTest("reset button sends setPaneTheme nil") {
        let fx = makeThemeBrowserFixture(currentTheme: "Nord")
        defer { fx.window.close() }

        fx.view.resetButton.performClick(nil)

        try expectSingleSetPaneTheme(fx.runtime, paneId: fx.paneId, themeName: nil)
    }

    uiTest("close button calls toggleThemeBrowser") {
        let fx = makeThemeBrowserFixture()
        defer { fx.window.close() }

        fx.view.closeButton.performClick(nil)

        try uiExpect(fx.runtime.themeBrowserToggles == 1, "close should toggle browser exactly once")
        try uiExpect(fx.runtime.sentMessages.isEmpty, "close should not send model messages")
    }

    uiTest("context-menu builder yields Copy Name carrying the row's theme and a strong anchor") {
        let fx = makeThemeBrowserFixture()
        defer { fx.window.close() }
        let menu = NSMenu()

        fx.view.buildThemeContextMenu(into: menu, forRow: 1)

        try uiExpect(menu.items.count == 1, "expected one context menu item")
        let item = menu.items[0]
        try uiExpect(item.title == "Copy Name", "unexpected item title: \(item.title)")
        try uiExpect(item.target === fx.view, "Copy Name should target the browser")
        try uiExpect(item.action != nil, "Copy Name should have an action")
        let payload = try menuPayload(from: item)
        try uiExpect(payload.themeName == fx.names[1], "payload theme mismatch")
        try uiExpect(payload.anchor === fx.view, "payload should anchor the browser")
    }

    uiTest("builder clears stale items and yields empty for row -1") {
        let fx = makeThemeBrowserFixture()
        defer { fx.window.close() }
        let menu = NSMenu()
        menu.addItem(withTitle: "Stale", action: nil, keyEquivalent: "")

        fx.view.buildThemeContextMenu(into: menu, forRow: -1)

        try uiExpect(menu.items.isEmpty, "miss-click menu should be empty")
    }

    uiTest("builder yields empty for out-of-bounds row") {
        let fx = makeThemeBrowserFixture()
        defer { fx.window.close() }
        let menu = NSMenu()

        fx.view.buildThemeContextMenu(into: menu, forRow: fx.names.count)

        try uiExpect(menu.items.isEmpty, "out-of-bounds menu should be empty")
    }

    uiTest("builder reads the active filter") {
        let fx = makeThemeBrowserFixture()
        defer { fx.window.close() }
        let menu = NSMenu()

        setSearch("gru", in: fx)
        fx.view.buildThemeContextMenu(into: menu, forRow: 0)

        let payload = try menuPayload(from: try onlyThemeMenuItem(in: menu))
        try uiExpect(payload.themeName == "Gruvbox Dark", "builder should use filtered row names")
    }

    uiTest("a right-click on a row yields a menu carrying that row's theme") {
        let fx = makeThemeBrowserFixture()
        defer { fx.window.close() }

        let menu = try themeContextMenu(rightClickingRow: 1, in: fx)
        let payload = try menuPayload(from: try onlyThemeMenuItem(in: menu))

        try uiExpect(payload.themeName == fx.names[1], "menu payload theme mismatch: \(payload.themeName)")
    }

    uiTest("a right-click that misses every row yields no menu") {
        let fx = makeThemeBrowserFixture()
        defer { fx.window.close() }
        let table = fx.view.tableView
        let below = NSPoint(x: 10, y: CGFloat(fx.names.count + 4) * table.rowHeight)
        let event = try makeThemeRightClickEvent(at: table.convert(below, to: nil), in: fx)

        try uiExpect(table.menu(for: event) == nil, "a click past the last row should yield no menu")
    }

    uiTest("a right-click marks the clicked row so AppKit outlines it") {
        // Intent: after a right-click, the table knows which row was clicked.
        // Why it exists: AppKit draws the context-menu outline only from
        //   NSTableView's own menu(for:), which is also what sets clickedRow. An
        //   override that builds the menu itself and never delegates leaves
        //   clickedRow at -1 and the clicked row undrawn, so the user cannot tell
        //   which theme Copy Name would copy.
        // Scenario: the user right-clicks the second theme in the list while a
        //   different theme is selected.
        let fx = makeThemeBrowserFixture()
        defer { fx.window.close() }

        _ = try themeContextMenu(rightClickingRow: 1, in: fx)

        try uiExpect(fx.view.tableView.clickedRow == 1,
            "clickedRow should be the right-clicked row, got \(fx.view.tableView.clickedRow)")
        try uiExpect(fx.view.tableView.menu == nil,
            "the table view should hold no menu once menu(for:) returns")
    }

    uiTest("menu keeps the browser alive and Copy Name still fires after teardown") {
        // Intent: a built menu strongly retains the ephemeral theme browser, so
        //   Copy Name still works after the browser's owner releases it.
        // Why it exists: NSMenuItem.target is weak; without a representedObject
        //   anchor, toggling the browser away mid-track can turn Copy Name into
        //   a silent no-op. Spec-first.
        // Scenario: the context menu is built, the browser owner goes away, and
        //   the still-tracking menu item fires against a recording pasteboard.
        let menu = NSMenu()
        let pasteboard = RecordingThemePasteboard()
        weak var observer: ThemeBrowserView?

        autoreleasepool {
            var view: ThemeBrowserView? = ThemeBrowserView(themeNames: ["Dracula", "Gruvbox Dark"])
            observer = view
            view?.pasteboard = pasteboard
            view?.buildThemeContextMenu(into: menu, forRow: 1)
            view = nil
        }

        try uiExpect(observer != nil, "menu payload should retain the browser after owner teardown")
        let item = try onlyThemeMenuItem(in: menu)
        let payload = try menuPayload(from: item)
        guard let target = item.target as? NSObject else {
            throw UITestFailure(message: "Copy Name target should still be alive")
        }
        try uiExpect(target === payload.anchor, "Copy Name target should be the anchored browser")
        _ = target.perform(item.action, with: item)
        let copied = pasteboard.string(forType: .string)
        payload.anchor.pasteboard = NSPasteboard.general
        try uiExpect(copied == "Gruvbox Dark", "Copy Name should write to recording pasteboard")
    }

    uiTest("the per-click menu, its item, and its payload all deallocate after dismissal") {
        // Intent: nothing survives one right-click. The browser stores no menu,
        //   so the whole menu graph goes away once AppKit releases it.
        // Why it exists: a menu stored on the table view closes the cycle
        //   view -> tableView -> menu -> item -> payload -> view, which leaks the
        //   browser and needs a deferred clear to break. Spec-first.
        // Scenario: a right-click builds a menu, tracking ends, and one run-loop
        //   turn later the menu, its item, and its anchor payload are all gone.
        let fx = makeThemeBrowserFixture()
        defer { fx.window.close() }
        weak var menuObserver: NSMenu?
        weak var itemObserver: NSMenuItem?
        weak var payloadObserver: ThemeBrowserView.MenuPayload?

        try uiExpect(fx.view.tableView.menu == nil, "the table view should hold no persistent menu")

        try autoreleasepool {
            let menu = try themeContextMenu(rightClickingRow: 1, in: fx)
            let item = try onlyThemeMenuItem(in: menu)
            menuObserver = menu
            itemObserver = item
            payloadObserver = try menuPayload(from: item)
        }
        autoreleasepool {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }

        try uiExpect(menuObserver == nil, "the per-click menu should deallocate after dismissal")
        try uiExpect(itemObserver == nil, "the menu item should deallocate after dismissal")
        try uiExpect(payloadObserver == nil, "the anchor payload should deallocate after dismissal")
    }

    uiTest("the browser deallocates once its owner and its menu are both gone") {
        // Intent: the anchor payload retains the browser for the menu's lifetime
        //   and no longer.
        // Why it exists: the anchor is what keeps Copy Name working across a
        //   mid-track teardown, and it must not become a permanent retain cycle.
        //   Spec-first.
        // Scenario: an unowned browser builds a menu; dropping the menu and the
        //   owning reference deallocates the browser.
        weak var browserObserver: ThemeBrowserView?

        autoreleasepool {
            var view: ThemeBrowserView? = ThemeBrowserView(themeNames: ["Dracula", "Gruvbox Dark"])
            browserObserver = view
            var menu: NSMenu? = NSMenu()
            view?.buildThemeContextMenu(into: menu!, forRow: 1)
            menu = nil
            view = nil
        }

        try uiExpect(browserObserver == nil, "the browser should deallocate with no menu holding it")
    }
}

/// Synthesizes the right-click AppKit would deliver over `row` and returns the
/// menu the table view builds for it.
private func themeContextMenu(rightClickingRow row: Int, in fx: ThemeBrowserFixture) throws -> NSMenu {
    settleThemeBrowserFixture(fx)
    let table = fx.view.tableView
    let rowRect = table.rect(ofRow: row)
    let center = NSPoint(x: rowRect.midX, y: rowRect.midY)
    let event = try makeThemeRightClickEvent(at: table.convert(center, to: nil), in: fx)
    guard let menu = table.menu(for: event) else {
        throw UITestFailure(message: "no context menu for row \(row)")
    }
    return menu
}

private func makeThemeRightClickEvent(at windowPoint: NSPoint, in fx: ThemeBrowserFixture) throws -> NSEvent {
    guard let event = NSEvent.mouseEvent(
        with: .rightMouseDown,
        location: windowPoint,
        modifierFlags: [],
        timestamp: 1,
        windowNumber: fx.window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
    ) else {
        throw UITestFailure(message: "could not synthesize a right-click")
    }
    return event
}

/// Builds one complete packed entry for the app-side catalog and bridge tests.
private func fixtureThemeCatalogData() -> Data {
    Data(
        """
        {"schemaVersion":1,"themes":[{
          "schemaVersion":1,"name":"Fixture","foreground":"#010203",
          "background":"#040506","cursor":"#070809","cursorText":"#0a0b0c",
          "selectionBackground":"#0d0e0f","selectionForeground":"#101112",
          "ansiPalette":[
            "#000000","#000001","#000002","#000003","#000004","#000005",
            "#000006","#000007","#000008","#000009","#00000a","#00000b",
            "#00000c","#00000d","#00000e","#00000f"],
          "provenance":{"collection":"source","ghosttyVersion":"v1.3.1","release":"release"}
        }]}
        """.utf8
    )
}

private struct ThemeBrowserFixture {
    let view: ThemeBrowserView
    let runtime: AppRuntime
    let window: NSWindow
    let tabId: TabId
    let paneId: PaneId
    let names: [String]
}

private func makeThemeBrowserFixture(
    names: [String] = ["Dracula", "Gruvbox Dark", "Gruvbox Light", "Nord", "Solarized Dark"],
    currentTheme: String? = nil
) -> ThemeBrowserFixture {
    let tabId = TabId()
    let paneId = PaneId()
    var pane = PaneModel(id: paneId)
    pane.theme = currentTheme
    let tab = TabModel(id: tabId, customTitle: nil, paneTree: PaneTree(root: .leaf(pane), focusedPaneId: paneId))
    let group = GroupModel(id: GroupId(), name: "Themes", tabs: [tab])
    var model = AppModel(groups: [group])
    model.selectedTabId = tabId

    let runtime = AppRuntime(model: model)
    let view = ThemeBrowserView(themeNames: names)
    view.runtime = runtime

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
        styleMask: [.titled],
        backing: .buffered,
        defer: false)
    let contentArea = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    window.contentView = contentArea
    contentArea.addSubview(view)
    NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo: contentArea.topAnchor),
        view.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
        view.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
    ])
    view.reloadTable()
    view.apply(desiredThemeBrowser(in: runtime.model))
    settleThemeBrowserFixture(view: view, window: window)

    return ThemeBrowserFixture(view: view, runtime: runtime, window: window, tabId: tabId, paneId: paneId, names: names)
}

private func setSearch(_ value: String, in fx: ThemeBrowserFixture) {
    fx.view.searchField.stringValue = value
    fx.view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fx.view.searchField))
    settleThemeBrowserFixture(fx)
}

private func cellText(row: Int, in fx: ThemeBrowserFixture) throws -> String {
    settleThemeBrowserFixture(fx)
    guard let cell = fx.view.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ThemeBrowserCellView,
          let text = cell.textField?.stringValue else {
        throw UITestFailure(message: "missing theme cell at row \(row)")
    }
    return text
}

private func rowIndex(of title: String, in fx: ThemeBrowserFixture) throws -> Int {
    for row in 0..<fx.view.tableView.numberOfRows {
        if try cellText(row: row, in: fx).trimmingCheckmark == title { return row }
    }
    throw UITestFailure(message: "missing theme row titled \(title)")
}

private func settleThemeBrowserFixture(_ fx: ThemeBrowserFixture) {
    settleThemeBrowserFixture(view: fx.view, window: fx.window)
}

private func settleThemeBrowserFixture(view: ThemeBrowserView, window: NSWindow) {
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.tableView.layoutSubtreeIfNeeded()
}

private func expectSingleSetPaneTheme(
    _ runtime: AppRuntime,
    paneId: PaneId,
    themeName: String?
) throws {
    try uiExpect(runtime.sentMessages.count == 1, "expected one setPaneTheme message, got \(runtime.sentMessages.count)")
    guard let msg = runtime.sentMessages.first else { return }
    if case .setPaneTheme(let actualPaneId, let actualThemeName) = msg {
        try uiExpect(actualPaneId == paneId, "pane id mismatch")
        try uiExpect(actualThemeName == themeName, "theme name mismatch: \(String(describing: actualThemeName))")
    } else {
        throw UITestFailure(message: "unexpected message: \(String(describing: msg))")
    }
}

private func onlyThemeMenuItem(in menu: NSMenu) throws -> NSMenuItem {
    try uiExpect(menu.items.count == 1, "expected one theme menu item, got \(menu.items.count)")
    return menu.items[0]
}

private func menuPayload(from item: NSMenuItem) throws -> ThemeBrowserView.MenuPayload {
    guard let payload = item.representedObject as? ThemeBrowserView.MenuPayload else {
        throw UITestFailure(message: "missing ThemeBrowserView.MenuPayload")
    }
    return payload
}

private final class RecordingThemePasteboard: ThemeNamePasteboard {
    private var value: String?

    @discardableResult
    func clearContents() -> Int {
        value = nil
        return 0
    }

    @discardableResult
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        guard dataType == .string else { return false }
        value = string
        return true
    }

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        guard dataType == .string else { return nil }
        return value
    }
}

private extension String {
    var trimmingCheckmark: String {
        if hasPrefix("\u{2713} ") { return String(dropFirst(2)) }
        return self
    }
}
