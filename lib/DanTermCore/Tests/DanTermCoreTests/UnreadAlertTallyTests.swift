// Tests for the single-pass unread-alert tally, the only definition of "how many
// unread alerts". Each expectation is a literal count, including the stale-pane
// distinction between the global total and the tree-restricted tab/group rollups.
import Foundation
import Testing

@testable import DanTermCore

private func testAlert(_ paneId: PaneId, unread: Bool = true, offset: TimeInterval = 0) -> AlertModel {
    AlertModel(
        id: AlertId(),
        kind: .bell,
        paneId: paneId,
        title: "DanTerm",
        body: "test",
        createdAt: Date(timeIntervalSince1970: offset),
        isUnread: unread
    )
}

private func splitTab(_ tabId: TabId, _ first: PaneId, _ second: PaneId) -> TabModel {
    TabModel(id: tabId, paneTree: PaneTree(root: .split(
            id: SplitId(),
            direction: .horizontal,
            first: .leaf(PaneModel(id: first)),
            second: .leaf(PaneModel(id: second)),
            ratio: 0.5
        ), focusedPaneId: first))
}

@Suite struct UnreadAlertTallyTests {
    @Test("unreadAlertTally rolls unread alerts up to pane, tab, group, and total")
    func unreadAlertTallyRollsUpEveryLevel() {
        // Intent: the tally reports the unread count at every level, summing
        //   a split tab's panes and a group's tabs, and ignoring read alerts.
        // Why it exists: the tally is the only definition of "how many unread
        //   alerts", so every level it reports has to be stated outright.
        // Scenario: spec-first representative model -- two groups, split and
        //   leaf tabs, a read alert, and repeated alerts on one pane.
        let g1 = GroupId(), g2 = GroupId()
        let t1 = TabId(), t2 = TabId(), t3 = TabId(), t4 = TabId()
        let p1 = PaneId(), p2 = PaneId(), p3 = PaneId(), p4 = PaneId(), p5 = PaneId()
        let tab1 = TabModel(id: t1, paneTree: PaneTree(root: .leaf(PaneModel(id: p1)), focusedPaneId: p1))
        let tab2 = TabModel(id: t2, paneTree: PaneTree(root: .leaf(PaneModel(id: p2)), focusedPaneId: p2))
        let tab3 = splitTab(t3, p3, p4)
        let tab4 = TabModel(id: t4, paneTree: PaneTree(root: .leaf(PaneModel(id: p5)), focusedPaneId: p5))
        var model = AppModel(groups: [
            GroupModel(id: g1, name: "Work", tabs: [tab1, tab2]),
            GroupModel(id: g2, name: "Home", tabs: [tab3, tab4]),
        ], selectedTabId: t1)
        model.alerts = [
            testAlert(p1, unread: false, offset: 1),
            testAlert(p2, offset: 2),
            testAlert(p3, offset: 3),
            testAlert(p4, offset: 4),
            testAlert(p5, offset: 5),
            testAlert(p5, offset: 6),
        ]

        let tally = unreadAlertTally(for: model)

        #expect((tally.byPane[p1] ?? 0) == 0)
        #expect((tally.byPane[p2] ?? 0) == 1)
        #expect((tally.byPane[p3] ?? 0) == 1)
        #expect((tally.byPane[p4] ?? 0) == 1)
        #expect((tally.byPane[p5] ?? 0) == 2)

        #expect((tally.byTab[t1] ?? -1) == 0)
        #expect((tally.byTab[t2] ?? -1) == 1)
        #expect((tally.byTab[t3] ?? -1) == 2)
        #expect((tally.byTab[t4] ?? -1) == 2)

        #expect((tally.byGroup[g1] ?? -1) == 1)
        #expect((tally.byGroup[g2] ?? -1) == 4)

        #expect(tally.total == 5)
    }

    @Test("unreadAlertTally counts stale-pane alerts only in total")
    func unreadAlertTallyCountsStalePaneAlertsOnlyInTotal() {
        // Intent: stale-pane unread alerts contribute to the global total
        //   without appearing in any tab or group rollup.
        // Why it exists: `total` intentionally counts every unread alert,
        //   while the tab and group buckets are tree-restricted.
        // Scenario: stale alert shape handled by activateAlert when the
        //   pane no longer exists.
        let livePane = PaneId()
        let stalePane = PaneId()
        let tab = TabModel(id: TabId(), paneTree: PaneTree(root: .leaf(PaneModel(id: livePane)), focusedPaneId: livePane))
        let group = GroupModel(id: GroupId(), name: "General", tabs: [tab])
        var model = AppModel(groups: [group], selectedTabId: tab.id)
        model.alerts = [testAlert(stalePane)]

        let tally = unreadAlertTally(for: model)

        #expect(tally.total == 1)
        #expect(tally.byPane[stalePane] == 1)
        #expect((tally.byTab[tab.id] ?? -1) == 0)
        #expect((tally.byGroup[group.id] ?? -1) == 0)
    }

    @Test("unreadAlertTally handles empty, read-only, repeated, and zero-count buckets")
    func unreadAlertTallyEdges() {
        // Intent: the tally excludes read alerts, sums repeated unread
        //   alerts, and still writes zero-valued tab/group keys.
        // Why it exists: projections use defensive dictionary lookups, but
        //   the builder contract says every live tab/group is represented.
        // Scenario: one empty model and one two-tab group where only the
        //   second tab has repeated unread alerts.
        var empty = makeModel()
        createTab(&empty)
        let emptyTab = empty.groups[0].tabs[0]
        let emptyTally = unreadAlertTally(for: empty)
        #expect(emptyTally.byPane.isEmpty)
        #expect(emptyTally.total == 0)
        #expect((emptyTally.byTab[emptyTab.id] ?? -1) == 0)
        #expect((emptyTally.byGroup[empty.groups[0].id] ?? -1) == 0)

        let p1 = PaneId(), p2 = PaneId()
        let tab1 = TabModel(id: TabId(), paneTree: PaneTree(root: .leaf(PaneModel(id: p1)), focusedPaneId: p1))
        let tab2 = TabModel(id: TabId(), paneTree: PaneTree(root: .leaf(PaneModel(id: p2)), focusedPaneId: p2))
        let group = GroupModel(id: GroupId(), name: "General", tabs: [tab1, tab2])
        var model = AppModel(groups: [group], selectedTabId: tab1.id)
        model.alerts = [
            testAlert(p1, unread: false, offset: 1),
            testAlert(p2, offset: 2),
            testAlert(p2, offset: 3),
        ]

        let tally = unreadAlertTally(for: model)

        #expect((tally.byPane[p1] ?? 0) == 0)
        #expect((tally.byPane[p2] ?? 0) == 2)
        #expect(tally.total == 2)
        #expect((tally.byTab[tab1.id] ?? -1) == 0)
        #expect((tally.byTab[tab2.id] ?? -1) == 2)
        #expect((tally.byGroup[group.id] ?? -1) == 2)
    }
}
