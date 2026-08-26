// Boundary tests for the Tab menu's close items. These pin what the AppKit side
// hands the reducer: which tabs Close Tab targets and in what order, and that
// Close Pane stays out of the sidebar selection entirely. The reducer's own
// batch behavior is pinned in DanTermCoreTests; this file only covers the hop
// from the sidebar's rows into the message.
import Cocoa
import ChipArtwork
import PaneProcessLifecycle
import TerminalCore
import TerminalPaneSession
import TerminalPTYHost
import TerminalRenderExecution
import TerminalRenderPlanning
@testable import DanTerm

@MainActor
func menubarTabCloseTests() async {
    print("MenubarTabClose")

    await uiTest("Close Tab targets the sidebar selection in top-to-bottom row order") {
        // Intent: cmd+shift+w closes every tab selected in the sidebar, handing
        //   the reducer the ids in visible top-to-bottom row order.
        // Why it exists: Close Tab used to ignore the selection and close the
        //   focused tab alone, so the keyboard and the context menu disagreed
        //   about what "the tabs I picked" meant. The order matters downstream:
        //   the confirmation lists the affected running commands in it.
        // Scenario: three tabs, the first and third selected, the second
        //   focused -- so a fallback to the focused tab is distinguishable.
        let fx = try makeMenubarCloseHarness()
        try selectTabRows(fx, tabIds: [fx.tabIds[0], fx.tabIds[2]])

        fx.delegate.closeTab(nil)

        guard case .requestCloseTabs(let ids) = try onlyMenubarMessage(fx.runtime) else {
            throw UITestFailure(message: "Close Tab sent \(fx.runtime.sentMessages)")
        }
        try uiExpect(ids == [fx.tabIds[0], fx.tabIds[2]],
            "Close Tab should target the selection in row order, got \(ids)")
    }

    await uiTest("Close Pane ignores a standing sidebar selection") {
        // Intent: cmd+w keeps targeting the focused pane of the focused tab
        //   however many tabs are selected in the sidebar.
        // Why it exists: panes are not sidebar rows, so there is no pane
        //   selection to batch over; Close Tab gaining the selection must not
        //   drag Close Pane along with it.
        // Scenario: two tabs selected, then Close Pane.
        let fx = try makeMenubarCloseHarness()
        try selectTabRows(fx, tabIds: [fx.tabIds[0], fx.tabIds[2]])

        fx.delegate.closePane(nil)

        guard case .requestClosePane(let paneId) = try onlyMenubarMessage(fx.runtime) else {
            throw UITestFailure(message: "Close Pane sent \(fx.runtime.sentMessages)")
        }
        try uiExpect(paneId == fx.focusedPaneId,
            "Close Pane should target the focused pane, got \(paneId)")
    }
}

/// An AppDelegate wired to a recording runtime and a real reconciled sidebar, so
/// a menu action runs the production target rule over real outline rows.
@MainActor
private struct MenubarCloseHarness {
    let delegate: AppDelegate
    let runtime: RecordingAppRuntime
    let sidebar: SidebarView
    let outline: NSOutlineView
    let tabIds: [TabId]
    let focusedPaneId: PaneId
}

/// Three tabs in one group, the middle one focused, so a selection and the
/// fallback target are always distinguishable.
@MainActor
private func makeMenubarCloseHarness() throws -> MenubarCloseHarness {
    var panes: [PaneId] = []
    let tabs = (0..<3).map { index -> TabModel in
        let paneId = PaneId()
        panes.append(paneId)
        var pane = PaneModel(id: paneId)
        pane.session = SessionModel(id: SessionId(), titleState: .declared("tab \(index)"))
        return TabModel(
            id: TabId(), paneTree: PaneTree(root: .leaf(pane), focusedPaneId: paneId))
    }
    let model = AppModel(
        groups: [GroupModel(id: GroupId(), name: "Group", tabs: tabs)],
        selectedTabId: tabs[1].id)

    let runtime = makeUITestRuntime(model: model)
    let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 420))
    sidebar.runtime = runtime
    let outline = try uiRequire(sidebarOutlineView(in: sidebar), "expected a sidebar outline view")
    _ = applySidebarTestModel(
        model, using: SidebarReconcileDriver(), to: sidebar, outline: outline)

    let delegate = AppDelegate(instancePaths: runtime.instancePaths)
    delegate.runtime = runtime
    delegate.sidebarView = sidebar

    return MenubarCloseHarness(
        delegate: delegate,
        runtime: runtime,
        sidebar: sidebar,
        outline: outline,
        tabIds: tabs.map(\.id),
        focusedPaneId: panes[1])
}

/// Selects the given tabs by their current outline rows. Selecting dispatches a
/// selectTab of its own, so the recorder is cleared once the rows are set and
/// the menu action is the only message left to read.
@MainActor
private func selectTabRows(_ fx: MenubarCloseHarness, tabIds: [TabId]) throws {
    for (index, tabId) in tabIds.enumerated() {
        let row = try sidebarTabRow(for: tabId, in: fx.outline)
        fx.outline.selectRowIndexes(IndexSet([row]), byExtendingSelection: index > 0)
    }
    try uiExpect(fx.sidebar.selectedTabIds().count == tabIds.count,
        "expected \(tabIds.count) selected rows, got \(fx.sidebar.selectedTabIds())")
    fx.runtime.sentMessages = []
}

private func uiRequire<Value>(_ value: Value?, _ message: String) throws -> Value {
    guard let value else { throw UITestFailure(message: message) }
    return value
}

/// Reads the single message a menu action dispatched, so a test that expects one
/// dispatch fails loudly on zero or many.
@MainActor
private func onlyMenubarMessage(_ runtime: RecordingAppRuntime) throws -> Msg {
    try uiExpect(runtime.sentMessages.count == 1,
        "expected exactly one message, got \(runtime.sentMessages)")
    return runtime.sentMessages[0]
}
