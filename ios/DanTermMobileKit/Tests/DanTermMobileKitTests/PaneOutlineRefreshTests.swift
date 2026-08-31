// Behavioral tests for the decision the pane picker makes on every roster update:
// whether the rows it already shows can be redrawn in place, or the list has to be
// rebuilt because the rows themselves moved.
@testable import DanTermMobileKit
import DanTermProtocol
import Foundation
import Testing

@Test("A pane title change refreshes only that pane's row")
func paneTitleChangeRefreshesOnePaneRow() {
    // Intent: same rows, new text -> a refresh naming the one row that reads differently.
    // Why it exists: an agent renames its pane several times a second to move an icon
    //   through the title. Rebuilding the list for that scrolls the reader back to the
    //   top mid-choice.
    // Scenario: pane 202 goes from "claude" to "* claude" while the picker is open.
    let before = outline(
        [pane(1, tab: 101, pane: 201, title: "zsh"), pane(1, tab: 101, pane: 202, title: "claude")]
    )
    let after = outline(
        [pane(1, tab: 101, pane: 201, title: "zsh"), pane(1, tab: 101, pane: 202, title: "* claude")]
    )
    let refreshed = after.rowsNeedingRefresh(
        since: before,
        previousSelection: id(201),
        selection: id(201)
    )
    #expect(refreshed == [.pane(id(202))])
}

@Test("An unchanged outline asks for no refresh at all")
func unchangedOutlineRefreshesNothing() {
    let items = [pane(1, tab: 101, pane: 201, title: "zsh")]
    let before = outline(items)
    let after = outline(items)
    #expect(
        after.rowsNeedingRefresh(since: before, previousSelection: id(201), selection: id(201))
            == []
    )
}

@Test("A group or tab rename refreshes that row alone")
func containerRenameRefreshesItsOwnRow() {
    let before = outline(
        [pane(1, group: "Work", tab: 101, tabTitle: "Tab", pane: 201, title: "zsh")]
    )
    let after = outline(
        [pane(1, group: "Home", tab: 101, tabTitle: "Tab", pane: 201, title: "zsh")]
    )
    #expect(
        after.rowsNeedingRefresh(since: before, previousSelection: id(201), selection: id(201))
            == [.group(groupId(1))]
    )
}

@Test("Moving the selection refreshes the rows that carry the checkmark")
func selectionMoveRefreshesBothPaneRows() {
    // Intent: the checkmark is rendered state, so a selection move is a refresh, not a
    //   rebuild.
    let items = [
        pane(1, tab: 101, pane: 201, title: "zsh"),
        pane(1, tab: 101, pane: 202, title: "claude"),
    ]
    let before = outline(items)
    let after = outline(items)
    #expect(
        after.rowsNeedingRefresh(since: before, previousSelection: id(201), selection: id(202))
            == [.pane(id(201)), .pane(id(202))]
    )
}

@Test("Moving the selection between single-pane tabs refreshes the two tab rows")
func selectionMoveRefreshesTabRowsThatCarryTheCheckmark() {
    // Intent: a tab that cannot expand stands for its one pane and draws that pane's
    //   checkmark, so the mark moving is a refresh of the two tab rows.
    // Why it exists: the pane rows under a one-pane tab are never shown, so naming them
    //   instead would leave the old checkmark on screen.
    let items = [
        pane(1, tab: 101, tabTitle: "Left", pane: 201, title: "zsh"),
        pane(1, tab: 102, tabTitle: "Right", pane: 202, title: "claude"),
    ]
    let before = outline(items)
    let after = outline(items)
    #expect(
        after.rowsNeedingRefresh(since: before, previousSelection: id(201), selection: id(202))
            == [.tab(tabId(101)), .tab(tabId(102)), .pane(id(201)), .pane(id(202))]
    )
}

@Test("A tab whose single pane row gains a sibling asks for a rebuild")
func addedPaneAsksForRebuild() {
    // Intent: new rows and a changed disclosure cannot be painted onto the rows on
    //   screen, so the answer is nil and the caller rebuilds.
    let before = outline([pane(1, tab: 101, pane: 201, title: "zsh")])
    let after = outline(
        [pane(1, tab: 101, pane: 201, title: "zsh"), pane(1, tab: 101, pane: 202, title: "claude")]
    )
    #expect(
        after.rowsNeedingRefresh(since: before, previousSelection: id(201), selection: id(201))
            == nil
    )
}

@Test("Reordering panes under a tab asks for a rebuild")
func reorderedPanesAskForRebuild() {
    // Intent: the identities match as a set but not in order, and the outline's order is
    //   the list's order.
    let first = pane(1, tab: 101, pane: 201, title: "zsh")
    let second = pane(1, tab: 101, pane: 202, title: "claude")
    let before = outline([first, second])
    let after = outline([second, first])
    #expect(
        after.rowsNeedingRefresh(since: before, previousSelection: id(201), selection: id(201))
            == nil
    )
}

@Test("A closed group asks for a rebuild")
func closedGroupAsksForRebuild() {
    let before = outline(
        [pane(1, tab: 101, pane: 201, title: "zsh"), pane(2, tab: 102, pane: 202, title: "claude")]
    )
    let after = outline([pane(1, tab: 101, pane: 201, title: "zsh")])
    #expect(
        after.rowsNeedingRefresh(since: before, previousSelection: id(201), selection: id(201))
            == nil
    )
}

// MARK: - Fixtures

private func pane(
    _ group: Int,
    group name: String = "Work",
    tab: Int,
    tabTitle: String = "Tab",
    pane: Int,
    title: String
) -> PaneRosterItem {
    PaneRosterItem(
        groupId: groupId(group),
        groupName: name,
        tabId: tabId(tab),
        tabTitle: tabTitle,
        paneId: id(pane),
        paneTitle: title,
        chip: .terminal,
        isSelectedTab: true,
        isFocused: false
    )
}

private func outline(_ items: [PaneRosterItem]) -> MobilePaneOutline {
    MobilePaneOutline(items: items)
}

private func wireId(_ value: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012d", value))!
}

private func id(_ value: Int) -> PaneId { PaneId(rawValue: wireId(value)) }
private func groupId(_ value: Int) -> GroupId { GroupId(rawValue: wireId(value)) }
private func tabId(_ value: Int) -> TabId { TabId(rawValue: wireId(value)) }
