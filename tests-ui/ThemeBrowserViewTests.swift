// UI-harness tests for ThemeBrowserView's catalog rendering, filtering,
// selection dispatch, context-menu shape, and AppKit menu-target lifetime.
import Cocoa

/// Registers ThemeBrowserView coverage in the GhosttyKit-free UI harness.
func themeBrowserViewTests() {
    print("ThemeBrowserView")

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

    uiTest("menuNeedsUpdate with no click builds an empty menu") {
        let fx = makeThemeBrowserFixture()
        defer { fx.window.close() }
        let menu = NSMenu()
        menu.addItem(withTitle: "Stale", action: nil, keyEquivalent: "")

        fx.view.menuNeedsUpdate(menu)

        try uiExpect(menu.items.isEmpty, "menu without a clicked row should be empty")
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

    uiTest("menuDidClose breaks the anchor cycle by releasing menu payloads") {
        // Intent: closing the persistent table menu removes anchored items after
        //   AppKit finishes tracking, so the payloads anchoring the browser are
        //   released.
        // Why it exists: this menu is stored on tableView.menu; without a
        //   deferred clear it forms view -> tableView -> menu -> payload -> view.
        // Scenario: the delegate receives menuDidClose, one main run-loop turn
        //   drains the deferred clear, and the payload anchoring the browser
        //   deallocates.
        var view: ThemeBrowserView? = ThemeBrowserView(themeNames: ["Dracula", "Gruvbox Dark"])
        var menu: NSMenu?
        weak var payloadObserver: ThemeBrowserView.MenuPayload?

        guard let persistentMenu = view?.tableView.menu else {
            throw UITestFailure(message: "theme browser should own a persistent table menu")
        }
        menu = persistentMenu
        view?.buildThemeContextMenu(into: persistentMenu, forRow: 1)
        var item: NSMenuItem? = try onlyThemeMenuItem(in: persistentMenu)
        payloadObserver = try menuPayload(from: item!)
        item = nil
        try uiExpect(payloadObserver != nil, "menu item should initially retain its payload")

        view?.menuDidClose(persistentMenu)
        autoreleasepool {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        try uiExpect(menu?.items.isEmpty == true, "menuDidClose should clear anchored items after the deferred turn")
        try uiExpect(payloadObserver == nil, "menu payload should deallocate after anchored items are cleared")

        menu = nil
        view = nil
    }
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
    let tab = TabModel(id: tabId, customTitle: nil, focusedPaneId: paneId, rootNode: .leaf(pane))
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
