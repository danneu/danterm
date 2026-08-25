// The text the phone renders outside the grid, with its presentation already stated.
//
// A terminal-authored string reaches a UIKit label only through `MobileDisplayText`, whose
// single constructor decides text-versus-emoji by the same pinned table the grid fallback
// uses. The Mac's roster projection has already done the text hygiene (controls, bidi
// overrides, whitespace); this file holds the other half, which must live on the phone
// because the table is `TerminalCore`'s and the pure core may not name it.
//
// What does not belong here: any layout or font choice. The roster outline carries identity
// beside prepared text so the UIKit shell can render and report taps without interpreting it.
import DanTermProtocol
import TerminalCore

/// A string prepared for a phone label. Constructing one is the only way to get a title
/// in front of UIKit, so an unprepared string cannot reach a label by any route.
public struct MobileDisplayText: Equatable, Sendable {
    public let text: String

    /// States the presentation Unicode defines for each single-scalar grapheme cluster
    /// that is a default-text variation base, and leaves every other cluster as it came.
    ///
    /// Segmentation is the host's own: the label lays the string out by those rules, and
    /// there is no terminal cell here to disagree with.
    public init(preparing raw: String) {
        var prepared = ""
        prepared.reserveCapacity(raw.utf8.count)
        for cluster in raw {
            prepared.append(cluster)
            if let selector = terminalPresentationSelectorToAppend(for: cluster.unicodeScalars) {
                prepared.unicodeScalars.append(selector)
            }
        }
        text = prepared
    }
}

/// One pane entry under a tab, with the exact target and artwork the shell renders.
public struct MobilePaneEntry: Equatable, Sendable {
    public let paneId: PaneId
    public let title: MobileDisplayText
    public let chip: ChipKind

    init(_ item: PaneRosterItem) {
        paneId = item.paneId
        title = MobileDisplayText(preparing: item.paneTitle)
        chip = item.chip
    }
}

/// One tab row and the pane entries it may reveal.
public struct MobilePaneTab: Equatable, Sendable {
    public let tabId: TabId
    public let title: MobileDisplayText
    /// The pane selected when the user picks the tab row.
    public let selectionPaneId: PaneId
    /// Whether expanding this tab can reveal a meaningful choice.
    public let isExpandable: Bool
    public let panes: [MobilePaneEntry]

    init(items: ArraySlice<PaneRosterItem>) {
        let first = items.first!
        tabId = first.tabId
        title = MobileDisplayText(preparing: first.tabTitle)
        selectionPaneId = items.first(where: \.isFocused)?.paneId ?? first.paneId
        panes = items.map(MobilePaneEntry.init)
        isExpandable = panes.count > 1
    }
}

/// One group section whose tabs remain in their roster order.
public struct MobilePaneGroup: Equatable, Sendable {
    public let groupId: GroupId
    public let title: MobileDisplayText
    public let tabs: [MobilePaneTab]

    init(items: ArraySlice<PaneRosterItem>) {
        let first = items.first!
        groupId = first.groupId
        title = MobileDisplayText(preparing: first.groupName)

        var tabs: [MobilePaneTab] = []
        var start = items.startIndex
        while start < items.endIndex {
            let tabId = items[start].tabId
            let end = items[start...].firstIndex { $0.tabId != tabId } ?? items.endIndex
            tabs.append(MobilePaneTab(items: items[start..<end]))
            start = end
        }
        self.tabs = tabs
    }
}

/// The selected pane's complete prepared path for the status pill.
public struct MobilePaneBreadcrumb: Equatable, Sendable {
    public let groupTitle: MobileDisplayText
    public let tabTitle: MobileDisplayText
    public let paneTitle: MobileDisplayText
    /// The complete path as one label can render it.
    public let text: String

    init(group: MobilePaneGroup, tab: MobilePaneTab, pane: MobilePaneEntry) {
        groupTitle = group.title
        tabTitle = tab.title
        paneTitle = pane.title
        text = "\(group.title.text) / \(tab.title.text) / \(pane.title.text)"
    }
}

/// The roster's ordered group, tab, and pane shape, including its initial expansion.
public struct MobilePaneOutline: Equatable, Sendable {
    public let groups: [MobilePaneGroup]
    /// The selected pane's tab when it can expand, or nil when no expansion locates it.
    public let initiallyExpandedTabId: TabId?

    init(items: [PaneRosterItem], selectedPaneId: PaneId?) {
        var groups: [MobilePaneGroup] = []
        var start = items.startIndex
        while start < items.endIndex {
            let groupId = items[start].groupId
            let end = items[start...].firstIndex { $0.groupId != groupId } ?? items.endIndex
            groups.append(MobilePaneGroup(items: items[start..<end]))
            start = end
        }
        self.groups = groups
        initiallyExpandedTabId = selectedPaneId.flatMap { selected in
            groups.lazy.flatMap(\.tabs).first { tab in
                tab.isExpandable && tab.panes.contains { $0.paneId == selected }
            }?.tabId
        }
    }

    /// Locates one pane without retaining a second flat roster projection.
    func breadcrumb(for paneId: PaneId?) -> MobilePaneBreadcrumb? {
        guard let paneId else { return nil }
        for group in groups {
            for tab in group.tabs {
                if let pane = tab.panes.first(where: { $0.paneId == paneId }) {
                    return MobilePaneBreadcrumb(group: group, tab: tab, pane: pane)
                }
            }
        }
        return nil
    }
}
