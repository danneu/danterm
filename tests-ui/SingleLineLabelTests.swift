// Every label that lives in a fixed-height row has to lay out one line and
// truncate, whatever string it is handed.
//
// The strings here are handed to the label directly, not through a
// `DisplayLine`, on purpose: the type keeps a multi-line value from ever
// reaching the view, and this suite proves the view would survive anyway. Two
// independent guards, asserted independently.
import Cocoa

@MainActor
func singleLineLabelTests() {
    print("SingleLineLabel")

    uiTest("every sidebar row label lays out one line and truncates") {
        let (sidebar, outline, window) = makeSingleLineSidebar()
        defer { window.close() }

        let groupCell: SidebarGroupCellView = try singleLineCell(
            for: .group(sidebarFixtureGroupId), in: outline)
        try assertSingleLine(groupCell.titleField, "sidebar group header")

        let tabCell: SidebarTabCellView = try singleLineCell(
            for: .tab(sidebarFixtureTabId), in: outline)
        try assertSingleLine(tabCell.titleField, "sidebar tab title")
        try assertSingleLine(tabCell.subtitleField, "sidebar tab subtitle")
        _ = sidebar
    }

    uiTest("the switcher row name lays out one line and truncates") {
        let row = SwitcherRowView()
        row.apply(row: SwitcherRow(tabId: TabId(), name: "one", color: nil, alertCount: 0), isCursor: false)
        try assertSingleLine(try onlySingleLineField(in: row, named: "switcher row"), "switcher row name")
    }

    uiTest("the window chrome title lays out one line and truncates") {
        let chrome = WindowChromeView(frame: NSRect(x: 0, y: 0, width: 600, height: 38))
        chrome.updateTitle("one")
        let fields = singleLineFields(in: chrome).filter { $0.stringValue == "one" }
        guard let title = fields.first else {
            throw UITestFailure(message: "chrome should show its title in a label")
        }
        try assertSingleLine(title, "window chrome title")
    }

    uiTest("the pane toolbar label and both accessories lay out one line and truncate") {
        let wrapper = makeSingleLinePaneWrapper()
        wrapper.updateToolbar(
            label: "one", isRemote: true, remoteLabel: "one", agentLabel: "one",
            chipTooltip: "one", chipKind: .agent)
        wrapper.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        wrapper.layoutSubtreeIfNeeded()

        let fields = singleLineFields(in: wrapper).filter { $0.stringValue == "one" }
        try uiExpect(fields.count == 3,
            "expected the toolbar label plus the remote and agent pills, got \(fields.count)")
        for (index, field) in fields.enumerated() {
            try assertSingleLine(field, "pane toolbar label \(index)")
        }
    }

    uiTest("Return in the sidebar rename field editor commits instead of inserting a line break") {
        // Why it exists: the tab title field goes editable for inline rename, and
        // an editable field that accepts Return would put a newline straight into
        // the model, past every admission point.
        let (sidebar, outline, window) = makeSingleLineSidebar()
        defer { window.close() }

        let cell: SidebarTabCellView = try singleLineCell(
            for: .tab(sidebarFixtureTabId), in: outline)
        let titleField = cell.titleField
        sidebar.beginRenamingTab(sidebarFixtureTabId)
        guard let editor = titleField.currentEditor() as? NSTextView else {
            throw UITestFailure(message: "rename should install a field editor")
        }

        editor.string = "renamed"
        let handled = sidebar.control(
            titleField, textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:)))

        try uiExpect(handled, "Return should be consumed as a commit")
        try uiExpect(!editor.string.contains("\n"),
            "Return must not insert a line break, got \(String(reflecting: editor.string))")
        try uiExpect(titleField.currentEditor() == nil,
            "committing should end the field editor")
    }
}

// MARK: - The assertion

/// A label lays out one line when neither a multi-line value nor a value far too
/// wide for the row makes it taller than a short one. Measured rather than read
/// off the properties, so the test does not care which of them achieves it.
func assertSingleLine(_ field: NSTextField, _ name: String) throws {
    let width: CGFloat = 120
    let one = singleLineHeight(field, "one", width: width)
    let wrapped = singleLineHeight(field, "line one\nline two", width: width)
    let wide = singleLineHeight(field, String(repeating: "wide ", count: 40), width: width)

    try uiExpect(wrapped == one,
        "\(name) grew from \(one) to \(wrapped) for a two-line string")
    try uiExpect(wide == one,
        "\(name) grew from \(one) to \(wide) for a string wider than the row")
}

func singleLineHeight(_ field: NSTextField, _ value: String, width: CGFloat) -> CGFloat {
    let saved = field.stringValue
    defer { field.stringValue = saved }
    field.stringValue = value
    guard let cell = field.cell else { return 0 }
    return cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height
}

// MARK: - Fixtures

private let sidebarFixtureGroupId = GroupId()
private let sidebarFixtureTabId = TabId()

/// A sidebar with one group and one single-pane tab, so both cell kinds and the
/// tab's cwd subtitle are all mounted.
@MainActor
private func makeSingleLineSidebar() -> (SidebarView, NSOutlineView, NSWindow) {
    let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 420))
    sidebar.runtime = AppRuntime()
    let window = NSWindow(
        contentRect: sidebar.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = sidebar
    window.layoutIfNeeded()
    let outline = findSingleLineOutlineView(in: sidebar)!

    let paneId = PaneId()
    var pane = PaneModel(id: paneId)
    pane.session = SessionModel(id: SessionId(), title: "one", cwd: "/tmp")
    let model = AppModel(
        groups: [
            GroupModel(id: sidebarFixtureGroupId, name: "one", tabs: [
                TabModel(id: sidebarFixtureTabId, paneTree: PaneTree(root: .leaf(pane), focusedPaneId: paneId)),
            ]),
            GroupModel(id: GroupId(), name: "second", tabs: []),
        ],
        selectedTabId: sidebarFixtureTabId)
    let projection = desiredSidebar(in: model)
    sidebar.applySidebarOps(
        computeSidebarRowOps(old: nil, new: projection),
        model: model, projection: projection, renameTargetToEnd: nil)
    outline.layoutSubtreeIfNeeded()
    window.layoutIfNeeded()
    return (sidebar, outline, window)
}

@MainActor
private func makeSingleLinePaneWrapper() -> PaneWrapperView {
    let paneId = PaneId()
    let pane = PaneModel(id: paneId, session: SessionModel(id: SessionId()))
    let tab = TabModel(id: TabId(), customTitle: nil, paneTree: PaneTree(root: .leaf(pane), focusedPaneId: paneId))
    var model = AppModel(groups: [GroupModel(id: GroupId(), name: "g", tabs: [tab])])
    model.selectedTabId = tab.id
    return PaneWrapperView(
        paneId: paneId, terminalView: TerminalView(),
        isZoomed: false, hasSplits: false, runtime: AppRuntime(model: model))
}

@MainActor
private func singleLineCell<Cell: NSTableCellView>(
    for target: RenameTarget,
    in outline: NSOutlineView
) throws -> Cell {
    for row in 0..<outline.numberOfRows {
        guard let item = outline.item(atRow: row) as? SidebarItem else { continue }
        let matches: Bool = {
            switch (target, item.kind) {
            case (.tab(let expected), .tab(let tab)): return expected == tab.id
            case (.group(let expected), .group(let group)): return expected == group.id
            default: return false
            }
        }()
        guard matches,
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? Cell
        else { continue }
        return cell
    }
    throw UITestFailure(message: "missing cell for \(target)")
}

private func requireField(_ field: NSTextField?) throws -> NSTextField {
    guard let field else { throw UITestFailure(message: "cell should have a text field") }
    return field
}

@MainActor
private func onlySingleLineField(in root: NSView, named name: String) throws -> NSTextField {
    let fields = singleLineFields(in: root).filter { $0.stringValue == "one" }
    guard fields.count == 1 else {
        throw UITestFailure(message: "expected one label in the \(name), got \(fields.count)")
    }
    return fields[0]
}

@MainActor
private func singleLineFields(in root: NSView) -> [NSTextField] {
    root.subviews.flatMap { view -> [NSTextField] in
        let nested = singleLineFields(in: view)
        return (view as? NSTextField).map { [$0] + nested } ?? nested
    }
}

@MainActor
private func findSingleLineOutlineView(in root: NSView) -> NSOutlineView? {
    for view in root.subviews {
        if let outline = view as? NSOutlineView { return outline }
        if let found = findSingleLineOutlineView(in: view) { return found }
    }
    return nil
}
