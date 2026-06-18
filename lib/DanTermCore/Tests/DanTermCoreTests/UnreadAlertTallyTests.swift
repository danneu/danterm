// Tests for the single-pass unread-alert tally. These pin numerical equivalence
// to the retained helper functions, including the stale-pane distinction between
// global totals and tree-restricted tab/group rollups.
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
    TabModel(
        id: tabId,
        focusedPaneId: first,
        rootNode: .split(
            id: SplitId(),
            direction: .horizontal,
            first: .leaf(PaneModel(id: first)),
            second: .leaf(PaneModel(id: second)),
            ratio: 0.5
        )
    )
}

@Suite struct UnreadAlertTallyTests {
    @Test("unreadAlertTally matches retained alert helpers")
    func unreadAlertTallyMatchesHelpers() {
        // Intent: the new single-pass tally returns the same per-pane,
        //   per-tab, per-group, and total counts as the retained helpers.
        // Why it exists: the tally replaces repeated helper scans on the
        //   reconcile hot path, so it must remain a numerical equivalent.
        // Scenario: spec-first representative model -- two groups, split
        //   and leaf tabs, read and unread alerts, and repeated alerts on
        //   one pane.
        let g1 = GroupId(), g2 = GroupId()
        let t1 = TabId(), t2 = TabId(), t3 = TabId()
        let p1 = PaneId(), p2 = PaneId(), p3 = PaneId(), p4 = PaneId(), p5 = PaneId()
        let tab1 = splitTab(t1, p1, p2)
        let tab2 = TabModel(id: t2, focusedPaneId: p3, rootNode: .leaf(PaneModel(id: p3)))
        let tab3 = splitTab(t3, p4, p5)
        var model = AppModel(groups: [
            GroupModel(id: g1, name: "Work", tabs: [tab1, tab2]),
            GroupModel(id: g2, name: "Home", tabs: [tab3]),
        ], selectedTabId: t1)
        model.alerts = [
            testAlert(p1, offset: 1),
            testAlert(p1, offset: 2),
            testAlert(p2, unread: false, offset: 3),
            testAlert(p3, offset: 4),
            testAlert(p5, offset: 5),
            testAlert(p5, unread: false, offset: 6),
        ]

        let tally = unreadAlertTally(for: model)

        for paneId in model.allPaneIds {
            let unreadCount = model.alerts.count { $0.isUnread && $0.paneId == paneId }
            #expect((tally.byPane[paneId] ?? 0) == unreadCount)
            #expect(((tally.byPane[paneId] ?? 0) > 0) == paneHasUnreadAlert(paneId, alerts: model.alerts))
        }
        for group in model.groups {
            #expect((tally.byGroup[group.id] ?? -1) == groupUnreadAlertCount(for: group, alerts: model.alerts))
            for tab in group.tabs {
                #expect((tally.byTab[tab.id] ?? -1) == unreadAlertCount(for: tab, alerts: model.alerts))
            }
        }
        #expect(tally.total == totalUnreadAlertCount(model: model))
    }

    @Test("unreadAlertTally counts stale-pane alerts only in total")
    func unreadAlertTallyCountsStalePaneAlertsOnlyInTotal() {
        // Intent: stale-pane unread alerts contribute to the global total
        //   without appearing in any tab or group rollup.
        // Why it exists: totalUnreadAlertCount intentionally counts every
        //   unread alert, while tab/group helpers are tree-restricted.
        // Scenario: stale alert shape handled by activateAlert when the
        //   pane no longer exists.
        let livePane = PaneId()
        let stalePane = PaneId()
        let tab = TabModel(id: TabId(), focusedPaneId: livePane, rootNode: .leaf(PaneModel(id: livePane)))
        let group = GroupModel(id: GroupId(), name: "General", tabs: [tab])
        var model = AppModel(groups: [group], selectedTabId: tab.id)
        model.alerts = [testAlert(stalePane)]

        let tally = unreadAlertTally(for: model)

        #expect(tally.total == 1)
        #expect(tally.total == totalUnreadAlertCount(model: model))
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
        let tab1 = TabModel(id: TabId(), focusedPaneId: p1, rootNode: .leaf(PaneModel(id: p1)))
        let tab2 = TabModel(id: TabId(), focusedPaneId: p2, rootNode: .leaf(PaneModel(id: p2)))
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
