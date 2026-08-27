// Boundary tests for the Tab menu's color items. These drive the real menu
// builder and shared dispatcher so color identity cannot split across channels.
import Cocoa
import ChipArtwork
import DanTermProtocol
import PaneProcessLifecycle
import TerminalCore
import TerminalPaneSession
import TerminalPTYHost
import TerminalRenderExecution
import TerminalRenderPlanning
@testable import DanTerm

@MainActor
func menubarTabColorTests() async {
    print("MenubarTabColor")

    await uiTest("each color item dispatches the color named by its command") {
        // Intent: every color row dispatches the color its own command names.
        // Why it exists: the old menu item also carried an allCases index in tag, so the
        //   command and index could disagree and silently select the wrong color.
        // Scenario: each real color item gets a deliberately wrong legacy tag before dispatch.
        let fx = makeMenubarColorHarness()
        let colorMenu = try colorSubmenu(in: AppDelegate.makeTabMenu())

        for (index, color) in TabColor.allCases.enumerated() {
            let title = commandDescriptor(color.configurableCommand).title
            let menuItem = try onlyItem(in: colorMenu, titled: title)
            menuItem.tag = (index + 1) % TabColor.allCases.count
            fx.runtime.sentMessages = []

            fx.delegate.performConfiguredCommand(menuItem)

            try expectOnlyColorMessage(
                fx.runtime, tabId: fx.tabId, color: color, context: title)
        }
    }

    await uiTest("color submenu covers every color and Clear Color dispatches nil") {
        // Intent: the submenu offers every declared color once plus Clear Color.
        // Why it exists: a new color must appear in the real menu, and clearing must keep its
        //   distinct nil payload while the colored rows move to one identity channel.
        // Scenario: inspect the built submenu, then dispatch its Clear Color row.
        let fx = makeMenubarColorHarness()
        let colorMenu = try colorSubmenu(in: AppDelegate.makeTabMenu())
        let colorTitles = TabColor.allCases.map { color in
            commandDescriptor(color.configurableCommand).title
        }

        for title in colorTitles {
            _ = try onlyItem(in: colorMenu, titled: title)
        }
        try uiExpect(
            colorMenu.items.filter { colorTitles.contains($0.title) }.count == TabColor.allCases.count,
            "color submenu should contain each declared color exactly once"
        )

        let clear = try onlyItem(in: colorMenu, titled: "Clear Color")
        fx.delegate.performConfiguredCommand(clear)
        try expectOnlyColorMessage(
            fx.runtime, tabId: fx.tabId, color: nil, context: "Clear Color")
    }
}

@MainActor
private struct MenubarColorHarness {
    let delegate: AppDelegate
    let runtime: RecordingAppRuntime
    let tabId: TabId
}

@MainActor
private func makeMenubarColorHarness() -> MenubarColorHarness {
    let paneId = PaneId()
    let tab = TabModel(
        id: TabId(),
        paneTree: PaneTree(root: .leaf(PaneModel(id: paneId)), focusedPaneId: paneId)
    )
    let model = AppModel(
        groups: [GroupModel(id: GroupId(), name: "Group", tabs: [tab])],
        selectedTabId: tab.id
    )
    let runtime = makeUITestRuntime(model: model)
    let delegate = AppDelegate(
        instancePaths: runtime.instancePaths, configURL: uiTestAbsentConfigURL())
    delegate.runtime = runtime
    return MenubarColorHarness(delegate: delegate, runtime: runtime, tabId: tab.id)
}

@MainActor
private func colorSubmenu(in tabMenu: NSMenu) throws -> NSMenu {
    guard let menu = tabMenu.items.first(where: { $0.title == "Color" })?.submenu else {
        throw UITestFailure(message: "Tab menu should contain the Color submenu")
    }
    return menu
}

@MainActor
private func onlyItem(in menu: NSMenu, titled title: String) throws -> NSMenuItem {
    let matches = menu.items.filter { $0.title == title }
    try uiExpect(matches.count == 1, "expected one \(title) item, got \(matches.count)")
    return matches[0]
}

@MainActor
private func expectOnlyColorMessage(
    _ runtime: RecordingAppRuntime,
    tabId: TabId,
    color: TabColor?,
    context: String
) throws {
    try uiExpect(runtime.sentMessages.count == 1,
                 "\(context) should send one message, got \(runtime.sentMessages)")
    guard case .setTabColors(let ids, let actualColor) = runtime.sentMessages[0] else {
        throw UITestFailure(message: "\(context) sent \(runtime.sentMessages[0])")
    }
    try uiExpect(ids == [tabId], "\(context) should target the selected tab")
    try uiExpect(actualColor == color, "\(context) dispatched \(String(describing: actualColor))")
}
