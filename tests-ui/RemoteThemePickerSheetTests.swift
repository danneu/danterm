// UI-harness tests for RemoteThemePickerSheet's searchable table and commit
// controls. Fixtures keep the controller in a plain, unordered window so the
// production dismiss path no-ops instead of depending on real sheet presentation.
import Cocoa

/// Registers RemoteThemePickerSheet coverage in the standalone UI harness.
@MainActor
func remoteThemePickerSheetTests() {
    print("RemoteThemePickerSheet")

    uiTest("constructs against an empty catalog with zero rows and no callback") {
        let sheet = RemoteThemePickerSheet()
        var fired = false
        sheet.onSelect = { _ in fired = true }
        _ = sheet.view

        try uiExpect(sheet.view.subviews.count > 0, "loadView should build the hierarchy")
        try uiExpect(sheet.tableView.numberOfRows == 0, "empty harness catalog should show zero rows")
        try uiExpect(!fired, "construction must not fire onSelect")
    }

    uiTest("search filter narrows rows case-insensitively") {
        let fx = makeRemotePickerFixture()
        defer { fx.window.close() }

        setSearch("gru", in: fx)

        try uiExpect(fx.sheet.tableView.numberOfRows == 2, "expected two filtered rows")
        try uiExpect(try cellText(row: 0, in: fx) == "Gruvbox Dark", "first filtered row mismatch")
        try uiExpect(try cellText(row: 1, in: fx) == "Gruvbox Light", "second filtered row mismatch")
        try uiExpect(fx.recorder.names.isEmpty, "filtering should not fire onSelect")
    }

    uiTest("theme cell wires a swatch view") {
        // Intent: the row cell built by viewFor carries a ColorSwatchView
        //   installed in the cell with the swatchView back-reference set.
        // Why it exists: cellText() only reads textField, so before this pin the
        //   swatch subtree could be dropped entirely without failing the suite;
        //   this guards the cell-factory extraction.
        // Scenario: spec-first; pins existing rendering ahead of refactoring the
        //   duplicated viewFor bodies into ThemeBrowserCellView.themeCell.
        let fx = makeRemotePickerFixture()
        defer { fx.window.close() }
        settleRemotePickerFixture(fx: fx)

        guard let cell = fx.sheet.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ThemeBrowserCellView else {
            throw UITestFailure(message: "missing theme cell at row 0")
        }
        guard let swatch = cell.swatchView else {
            throw UITestFailure(message: "cell should carry a swatch view")
        }
        try uiExpect(swatch.superview === cell, "swatch should be installed in the cell")
    }

    uiTest("clearing the filter restores all rows") {
        let fx = makeRemotePickerFixture()
        defer { fx.window.close() }

        setSearch("gru", in: fx)
        setSearch("", in: fx)

        try uiExpect(fx.sheet.tableView.numberOfRows == fx.names.count, "all rows should be restored")
        try uiExpect(fx.recorder.names.isEmpty, "clearing the filter should not fire onSelect")
    }

    uiTest("no-match filter disables select and double-click commit fires nothing") {
        let fx = makeRemotePickerFixture()
        defer { fx.window.close() }

        setSearch("zzz", in: fx)
        try uiExpect(fx.sheet.tableView.numberOfRows == 0, "no-match query should show zero rows")
        try uiExpect(!fx.sheet.selectButton.isEnabled, "Select should be disabled with no matches")

        try performDoubleAction(in: fx)

        try uiExpect(fx.recorder.names.isEmpty, "empty-results commit should not fire onSelect")
    }

    uiTest("double-click commit fires onSelect exactly once with the selected name") {
        let fx = makeRemotePickerFixture()
        defer { fx.window.close() }

        fx.sheet.tableView.selectRowIndexes(IndexSet(integer: try rowIndex(of: "Nord", in: fx)), byExtendingSelection: false)
        try uiExpect(fx.sheet.tableView.doubleAction != nil, "table should wire a double action")
        try uiExpect(fx.sheet.tableView.target === fx.sheet, "table double action should target the sheet")

        try performDoubleAction(in: fx)

        try uiExpect(fx.recorder.names == ["Nord"], "double-click should select Nord once, got \(fx.recorder.names)")
    }

    uiTest("select button commit fires onSelect exactly once with the selected name") {
        let fx = makeRemotePickerFixture()
        defer { fx.window.close() }

        fx.sheet.tableView.selectRowIndexes(IndexSet(integer: try rowIndex(of: "Dracula", in: fx)), byExtendingSelection: false)
        fx.sheet.selectButton.performClick(nil)

        try uiExpect(fx.recorder.names == ["Dracula"], "Select should pick Dracula once, got \(fx.recorder.names)")
    }

    uiTest("commit after filtering targets the filtered row index") {
        let fx = makeRemotePickerFixture()
        defer { fx.window.close() }

        setSearch("gru", in: fx)
        fx.sheet.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        fx.sheet.selectButton.performClick(nil)

        try uiExpect(fx.recorder.names == ["Gruvbox Light"], "filtered commit should pick Gruvbox Light, got \(fx.recorder.names)")
    }

    uiTest("commit with no selection fires nothing") {
        let fx = makeRemotePickerFixture()
        defer { fx.window.close() }

        try uiExpect(fx.sheet.tableView.selectedRow == -1, "fresh sheet should start without selection")
        try uiExpect(!fx.sheet.selectButton.isEnabled, "Select should start disabled without selection")

        try performDoubleAction(in: fx)

        try uiExpect(fx.recorder.names.isEmpty, "no-selection commit should not fire onSelect")
    }

    uiTest("cancel fires nothing") {
        let fx = makeRemotePickerFixture()
        defer { fx.window.close() }

        fx.sheet.cancelButton.performClick(nil)

        try uiExpect(fx.recorder.names.isEmpty, "Cancel should not fire onSelect")
    }

    uiTest("current theme preselects its row and marks the cell") {
        let fx = makeRemotePickerFixture(currentTheme: "Nord")
        defer { fx.window.close() }

        let row = try rowIndex(of: "Nord", in: fx)
        try uiExpect(fx.sheet.tableView.selectedRow == row, "current theme row should be selected")
        try uiExpect(fx.sheet.selectButton.isEnabled, "Select should be enabled for the current theme")
        try uiExpect(try cellText(row: row, in: fx) == "\u{2713} Nord", "current theme row should show checkmark")
        try uiExpect(fx.recorder.names.isEmpty, "preselection should not fire onSelect")
    }

    uiTest("filtering keeps or clears the current theme selection") {
        let fx = makeRemotePickerFixture(currentTheme: "Gruvbox Dark")
        defer { fx.window.close() }

        setSearch("gru", in: fx)

        try uiExpect(fx.sheet.tableView.selectedRow == 0, "filtered current theme should remain selected")
        try uiExpect(fx.sheet.selectButton.isEnabled, "Select should stay enabled for visible current theme")

        setSearch("nord", in: fx)

        try uiExpect(fx.sheet.tableView.selectedRow == -1, "filtered-away current theme should deselect")
        try uiExpect(!fx.sheet.selectButton.isEnabled, "Select should disable when current theme is filtered away")
        try uiExpect(fx.recorder.names.isEmpty, "filtering current theme visibility should not fire onSelect")
    }

    uiTest("selecting a row enables Select") {
        let fx = makeRemotePickerFixture()
        defer { fx.window.close() }

        fx.sheet.tableView.selectRowIndexes(IndexSet(integer: try rowIndex(of: "Solarized Dark", in: fx)), byExtendingSelection: false)

        try uiExpect(fx.sheet.selectButton.isEnabled, "Select should enable after table selection")
        try uiExpect(fx.recorder.names.isEmpty, "selecting a row should not fire onSelect before commit")
    }
}

private final class SelectRecorder {
    var names: [String] = []
}

private struct RemotePickerFixture {
    let sheet: RemoteThemePickerSheet
    let window: NSWindow
    let recorder: SelectRecorder
    let names: [String]
}

private func makeRemotePickerFixture(
    names: [String] = ["Dracula", "Gruvbox Dark", "Gruvbox Light", "Nord", "Solarized Dark"],
    currentTheme: String? = nil
) -> RemotePickerFixture {
    let sheet = RemoteThemePickerSheet(themeNames: names)
    sheet.currentThemeName = currentTheme
    let recorder = SelectRecorder()
    sheet.onSelect = { recorder.names.append($0) }

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
        styleMask: [.titled],
        backing: .buffered,
        defer: false)
    window.contentView = sheet.view
    sheet.viewDidAppear()
    let fx = RemotePickerFixture(sheet: sheet, window: window, recorder: recorder, names: names)
    settleRemotePickerFixture(fx: fx)
    return fx
}

private func setSearch(_ value: String, in fx: RemotePickerFixture) {
    fx.sheet.searchField.stringValue = value
    fx.sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fx.sheet.searchField))
    settleRemotePickerFixture(fx: fx)
}

private func cellText(row: Int, in fx: RemotePickerFixture) throws -> String {
    settleRemotePickerFixture(fx: fx)
    guard let cell = fx.sheet.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ThemeBrowserCellView,
          let text = cell.textField?.stringValue else {
        throw UITestFailure(message: "missing theme cell at row \(row)")
    }
    return text
}

private func rowIndex(of title: String, in fx: RemotePickerFixture) throws -> Int {
    for row in 0..<fx.sheet.tableView.numberOfRows {
        if try cellText(row: row, in: fx).trimmingCheckmark == title { return row }
    }
    throw UITestFailure(message: "missing theme row titled \(title)")
}

private func performDoubleAction(in fx: RemotePickerFixture) throws {
    guard let target = fx.sheet.tableView.target as? NSObject,
          let action = fx.sheet.tableView.doubleAction else {
        throw UITestFailure(message: "table double action should be wired")
    }
    _ = target.perform(action)
}

private func settleRemotePickerFixture(fx: RemotePickerFixture) {
    fx.window.layoutIfNeeded()
    fx.sheet.view.layoutSubtreeIfNeeded()
    fx.sheet.tableView.layoutSubtreeIfNeeded()
}

private extension String {
    var trimmingCheckmark: String {
        if hasPrefix("\u{2713} ") { return String(dropFirst(2)) }
        return self
    }
}
