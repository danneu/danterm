// The pure Model -> PaneRoster projection. It reads only the roster's own
// inputs, so equality of two projections is the whole test of whether anything
// a roster consumer can see has changed -- which is what lets a push decide to
// send by comparing projections rather than by watching for specific messages.
//
// The roster's wire shape lives in DanTermProtocol; who receives one lives in
// the app runtime. Neither belongs here.
import Foundation
import DanTermProtocol

/// Projects every pane, in group then tab then split-tree order, with the tab
/// title already resolved so a client renders it verbatim.
///
/// Every title goes through `DisplayLine` before it is encoded: the roster is
/// display-only text, so the terminal-authored strings the model keeps verbatim
/// for IPC and checkpoints must not reach a client's label unprepared.
func paneRoster(in model: AppModel) -> PaneRoster {
    var panes: [PaneRosterItem] = []
    for group in model.groups {
        let groupName = DisplayLine(group.name).text
        for tab in group.tabs {
            let tabTitle = DisplayLine(rosterTabTitle(tab)).text
            let isSelectedTab = tab.id == model.selectedTabId
            forEachPane(in: tab.paneTree.root) { pane in
                panes.append(PaneRosterItem(
                    groupId: group.id,
                    groupName: groupName,
                    tabId: tab.id,
                    tabTitle: tabTitle,
                    paneId: pane.id,
                    paneTitle: DisplayLine(rosterPaneTitle(pane)).text,
                    chip: ChipKind(agent: pane.session?.agent ?? .none),
                    isSelectedTab: isSelectedTab,
                    isFocused: pane.id == tab.paneTree.focusedPaneId
                ))
            }
        }
    }
    return PaneRoster(panes: panes)
}

/// The roster's own pane resolution: the display one, except the cwd stays
/// unabbreviated. A roster entry is what an agent targets a pane by, and `~` is
/// not a path the caller can hand back.
private func rosterPaneTitle(_ pane: PaneModel) -> String {
    paneClaimedTitle(pane) ?? pane.session?.cwd ?? placeholderPaneTitle
}

/// Resolves a tab's title the way a roster consumer would have to otherwise:
/// the user's custom title, then a terminal title that says something, then the
/// command the focused pane is running. Deliberately not `tabDisplayTitle`,
/// which has no command fallback and abbreviates the home directory.
private func rosterTabTitle(_ tab: TabModel) -> String {
    if let customTitle = tab.customTitle { return customTitle }
    let focused = tab.paneTree.focusedPane
    let title = rosterPaneTitle(focused)
    if title != placeholderPaneTitle { return title }
    return focused.runningCommand ?? title
}
