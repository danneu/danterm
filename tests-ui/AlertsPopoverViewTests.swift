// UI-harness tests for AlertsPopoverView's rendered alert rows, empty states,
// selection-to-message routing, show-all control, and mark-all command.
import Cocoa

/// Runs alerts popover coverage in the AppKit UI harness.
func alertsPopoverViewTests() {
    print("AlertsPopoverView")

    uiTest("apply renders rows in order with text, time labels, and unread dots") {
        let paneId = PaneId()
        let alerts = [
            makeAlert(paneId: paneId, title: "Build done", body: "Command finished", isUnread: true, ageSeconds: 90),
            makeAlert(paneId: paneId, title: "Deploy started", body: "Waiting for output", isUnread: false, ageSeconds: 7350),
            makeAlert(paneId: paneId, title: "Daily report", body: "Summary is ready", isUnread: true, ageSeconds: 26 * 60 * 60),
        ]
        let fx = makeAlertsFixture(alerts: alerts, showAll: true, livePaneId: paneId)
        defer { fx.window.close() }

        let rows = materializedAlertRows(fx)

        try uiExpect(rows.count == 3, "expected three rendered rows")
        try uiExpect(alertRowTexts(rows[0]) == ["Build done", "Command finished", "1m"],
                     "unexpected first row text: \(alertRowTexts(rows[0]))")
        try uiExpect(alertRowTexts(rows[1]) == ["Deploy started", "Waiting for output", "2h"],
                     "unexpected second row text: \(alertRowTexts(rows[1]))")
        try uiExpect(alertRowTexts(rows[2]) == ["Daily report", "Summary is ready", "1d"],
                     "unexpected third row text: \(alertRowTexts(rows[2]))")
        try uiExpect(!(try unreadDot(in: rows[0]).isHidden), "first row unread dot should be visible")
        try uiExpect(try unreadDot(in: rows[1]).isHidden, "second row unread dot should be hidden")
        try uiExpect(!(try unreadDot(in: rows[2]).isHidden), "third row unread dot should be visible")
    }

    uiTest("empty states show tab text and toggle table and mark-all visibility") {
        do {
            let paneId = PaneId()
            let fx = makeAlertsFixture(alerts: [
                makeAlert(paneId: paneId, title: "Read alert", body: "Already handled", isUnread: false, ageSeconds: 90),
            ], livePaneId: paneId)
            defer { fx.window.close() }

            let emptyLabel = try onlyAlertLabel(titled: "No unread alerts", in: fx.vc.view)
            let markAll = try onlyAlertButton(titled: "Mark All Read", in: fx.vc.view)
            try uiExpect(!isEffectivelyHidden(emptyLabel), "No unread alerts label should be visible")
            try uiExpect(fx.scrollView.isHidden, "scroll view should be hidden with no unread alerts")
            try uiExpect(markAll.isHidden, "mark-all button should hide when no alert is unread")
        }

        do {
            let fx = makeAlertsFixture(alerts: [], showAll: true)
            defer { fx.window.close() }

            let emptyLabel = try onlyAlertLabel(titled: "No alerts", in: fx.vc.view)
            let markAll = try onlyAlertButton(titled: "Mark All Read", in: fx.vc.view)
            try uiExpect(!isEffectivelyHidden(emptyLabel), "No alerts label should be visible")
            try uiExpect(fx.scrollView.isHidden, "scroll view should be hidden with no alerts")
            try uiExpect(markAll.isHidden, "mark-all button should hide when there are no alerts")
        }

        do {
            let paneId = PaneId()
            let fx = makeAlertsFixture(alerts: [
                makeAlert(paneId: paneId, title: "Unread alert", body: "Needs attention", isUnread: true, ageSeconds: 90),
            ], livePaneId: paneId)
            defer { fx.window.close() }

            let emptyLabel = try onlyAlertLabel(titled: "No alerts", in: fx.vc.view)
            let markAll = try onlyAlertButton(titled: "Mark All Read", in: fx.vc.view)
            try uiExpect(!fx.scrollView.isHidden, "scroll view should show when rows exist")
            try uiExpect(isEffectivelyHidden(emptyLabel), "empty label should hide when rows exist")
            try uiExpect(!markAll.isHidden, "mark-all button should show when any alert is unread")
        }
    }

    uiTest("clicking the middle row sends activateAlert with that row id") {
        let paneId = PaneId()
        let alerts = [
            makeAlert(paneId: paneId, title: "One", body: "First", isUnread: true, ageSeconds: 90),
            makeAlert(paneId: paneId, title: "Two", body: "Second", isUnread: true, ageSeconds: 120),
            makeAlert(paneId: paneId, title: "Three", body: "Third", isUnread: true, ageSeconds: 150),
        ]
        let fx = makeAlertsFixture(alerts: alerts, livePaneId: paneId)
        defer { fx.window.close() }

        fx.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        try expectSingleActivateAlert(fx.runtime, "activate middle alert", alertId: alerts[1].id)
    }

    uiTest("row deselects after activate and the same row is clickable twice") {
        let paneId = PaneId()
        let alerts = [
            makeAlert(paneId: paneId, title: "One", body: "First", isUnread: true, ageSeconds: 90),
            makeAlert(paneId: paneId, title: "Two", body: "Second", isUnread: true, ageSeconds: 120),
            makeAlert(paneId: paneId, title: "Three", body: "Third", isUnread: true, ageSeconds: 150),
        ]
        let fx = makeAlertsFixture(alerts: alerts, livePaneId: paneId)
        defer { fx.window.close() }

        fx.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try uiExpect(fx.table.selectedRow == -1, "row should deselect after activate")
        fx.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        try uiExpect(fx.runtime.sentMessages.count == 2,
                     "expected two activate messages, got \(fx.runtime.sentMessages.count)")
        try uiExpect(fx.runtime.sentMessages.allSatisfy { isActivateAlert($0, alertId: alerts[1].id) },
                     "both messages should activate the same alert")
    }

    uiTest("stale-pane row still sends activateAlert with its alert id") {
        // Intent: clicking an alert row dispatches the alert id even when the
        //   alert's pane is no longer live.
        // Why it exists: stale-pane resolution is core's job, covered in
        //   UpdateAlertTests; the view contract is only to send the typed id.
        // Scenario: the alerts popover still shows a notification for a pane
        //   that has since been closed.
        let livePaneId = PaneId()
        let stalePaneId = PaneId()
        let alert = makeAlert(
            paneId: stalePaneId,
            title: "Stale pane",
            body: "Pane was closed",
            isUnread: true,
            ageSeconds: 90)
        let fx = makeAlertsFixture(alerts: [alert], livePaneId: livePaneId)
        defer { fx.window.close() }

        fx.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        try expectSingleActivateAlert(fx.runtime, "activate stale alert", alertId: alert.id)
    }

    uiTest("checkbox syncs from projection and toggling dispatches") {
        let paneId = PaneId()
        let fx = makeAlertsFixture(alerts: [
            makeAlert(paneId: paneId, title: "Read alert", body: "History row", isUnread: false, ageSeconds: 90),
        ], showAll: true, livePaneId: paneId)
        defer { fx.window.close() }
        let checkbox = try onlyAlertButton(titled: "Show all", in: fx.vc.view)

        try uiExpect(checkbox.state == .on, "show-all checkbox should sync on from projection")
        checkbox.performClick(nil)

        try uiExpect(checkbox.state == .off, "show-all checkbox should turn off after click")
        try expectSingleMessage(fx.runtime, "set show all false") { msg in
            if case .setShowAllAlerts(let showAll) = msg { return !showAll }
            return false
        }
    }

    uiTest("apply twice re-renders without dispatching") {
        // Intent: applying a fresh projection to an open controller replaces rows
        //   and control state without sending messages.
        // Why it exists: pins the d797b50 reconcile path where production
        //   re-applies changed alert projections to an already-open popover.
        // Scenario: an unread-only view refreshes into all-read history.
        let paneId = PaneId()
        let fx = makeAlertsFixture(alerts: [
            makeAlert(paneId: paneId, title: "Unread", body: "First projection", isUnread: true, ageSeconds: 90),
        ], livePaneId: paneId)
        defer { fx.window.close() }

        var model = fx.model
        model.alerts = [
            makeAlert(paneId: paneId, title: "Read one", body: "First", isUnread: false, ageSeconds: 90),
            makeAlert(paneId: paneId, title: "Read two", body: "Second", isUnread: false, ageSeconds: 120),
            makeAlert(paneId: paneId, title: "Read three", body: "Third", isUnread: false, ageSeconds: 150),
        ]
        model.showAllAlerts = true
        fx.vc.apply(desiredAlertsPopover(in: model))
        settleAlertsFixture(fx)

        let checkbox = try onlyAlertButton(titled: "Show all", in: fx.vc.view)
        let markAll = try onlyAlertButton(titled: "Mark All Read", in: fx.vc.view)
        try uiExpect(fx.table.numberOfRows == 3, "apply should render three history rows")
        try uiExpect(checkbox.state == .on, "show-all checkbox should resync on")
        try uiExpect(markAll.isHidden, "mark-all should hide when refreshed alerts are all read")
        try uiExpect(fx.runtime.sentMessages.isEmpty, "render-only apply should not dispatch")
    }

    uiTest("Mark All Read sends markAllAlertsRead") {
        let paneId = PaneId()
        let fx = makeAlertsFixture(alerts: [
            makeAlert(paneId: paneId, title: "Unread alert", body: "Needs attention", isUnread: true, ageSeconds: 90),
        ], livePaneId: paneId)
        defer { fx.window.close() }

        try onlyAlertButton(titled: "Mark All Read", in: fx.vc.view).performClick(nil)

        try expectSingleMessage(fx.runtime, "mark all read") { msg in
            if case .markAllAlertsRead = msg { return true }
            return false
        }
    }
}

private struct AlertsFixture {
    let vc: AlertsPopoverViewController
    let runtime: AppRuntime
    let window: NSWindow
    let model: AppModel
    let paneId: PaneId
    let table: NSTableView
    let scrollView: NSScrollView
}

private func makeAlertsFixture(
    alerts: [AlertModel],
    showAll: Bool = false,
    livePaneId: PaneId? = nil
) -> AlertsFixture {
    let paneId = livePaneId ?? PaneId()
    let tabId = TabId()
    let pane = PaneModel(id: paneId)
    let tab = TabModel(id: tabId, customTitle: nil, focusedPaneId: paneId, rootNode: .leaf(pane))
    let group = GroupModel(id: GroupId(), name: "Group", tabs: [tab])
    var model = AppModel(groups: [group])
    model.selectedTabId = tabId
    model.alerts = alerts
    model.showAllAlerts = showAll

    let runtime = AppRuntime(model: model)
    let vc = AlertsPopoverViewController()
    vc.runtime = runtime
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
        styleMask: [.titled],
        backing: .buffered,
        defer: false)
    window.contentView = vc.view
    vc.apply(desiredAlertsPopover(in: model))
    window.layoutIfNeeded()
    vc.view.layoutSubtreeIfNeeded()
    let table = findAlertTable(in: vc.view)!
    let scrollView = findAlertScrollView(in: vc.view, table: table)!
    materializeAlertRows(table)
    return AlertsFixture(
        vc: vc,
        runtime: runtime,
        window: window,
        model: model,
        paneId: paneId,
        table: table,
        scrollView: scrollView)
}

private func makeAlert(
    paneId: PaneId,
    title: String,
    body: String,
    isUnread: Bool,
    ageSeconds: TimeInterval
) -> AlertModel {
    AlertModel(
        id: AlertId(),
        kind: .bell,
        paneId: paneId,
        title: title,
        body: body,
        createdAt: Date(timeIntervalSinceNow: -ageSeconds),
        isUnread: isUnread)
}

private func settleAlertsFixture(_ fx: AlertsFixture) {
    fx.window.layoutIfNeeded()
    fx.vc.view.layoutSubtreeIfNeeded()
    fx.table.layoutSubtreeIfNeeded()
    materializeAlertRows(fx.table)
}

@discardableResult
private func materializedAlertRows(_ fx: AlertsFixture) -> [NSView] {
    settleAlertsFixture(fx)
    return (0..<fx.table.numberOfRows).compactMap {
        fx.table.view(atColumn: 0, row: $0, makeIfNecessary: true)
    }
}

private func materializeAlertRows(_ table: NSTableView) {
    table.layoutSubtreeIfNeeded()
    for row in 0..<table.numberOfRows {
        _ = table.view(atColumn: 0, row: row, makeIfNecessary: true)
        _ = table.rowView(atRow: row, makeIfNecessary: true)
    }
}

private func findAlertTable(in view: NSView) -> NSTableView? {
    if let table = view as? NSTableView { return table }
    for subview in view.subviews {
        if let found = findAlertTable(in: subview) { return found }
    }
    return nil
}

private func findAlertScrollView(in view: NSView, table: NSTableView) -> NSScrollView? {
    if let scrollView = view as? NSScrollView, scrollView.documentView === table { return scrollView }
    for subview in view.subviews {
        if let found = findAlertScrollView(in: subview, table: table) { return found }
    }
    return nil
}

private func alertRowTexts(_ row: NSView) -> [String] {
    // AlertsPopoverView.makeAlertRow adds text fields flat in title, body, time
    // order; this keeps the tests independent of styling details.
    row.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
}

private func unreadDot(in row: NSView) throws -> NSView {
    let matches = row.subviews.filter { type(of: $0) == NSView.self }
    try uiExpect(matches.count == 1, "expected one unread dot candidate, got \(matches.count)")
    return matches[0]
}

private func allSubviews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
    var result: [T] = []
    if let typed = view as? T { result.append(typed) }
    for subview in view.subviews {
        result.append(contentsOf: allSubviews(of: type, in: subview))
    }
    return result
}

private func isEffectivelyHidden(_ view: NSView) -> Bool {
    var current: NSView? = view
    while let candidate = current {
        if candidate.isHidden { return true }
        current = candidate.superview
    }
    return false
}

private func onlyAlertButton(titled title: String, in view: NSView) throws -> NSButton {
    let matches = allSubviews(of: NSButton.self, in: view).filter { $0.title == title }
    try uiExpect(matches.count == 1, "expected one button titled \(title), got \(matches.count)")
    return matches[0]
}

private func onlyAlertLabel(titled title: String, in view: NSView) throws -> NSTextField {
    let matches = allSubviews(of: NSTextField.self, in: view).filter { $0.stringValue == title }
    try uiExpect(matches.count == 1, "expected one label titled \(title), got \(matches.count)")
    return matches[0]
}

private func expectSingleMessage(
    _ runtime: AppRuntime,
    _ description: String,
    matches: (Msg) -> Bool
) throws {
    try uiExpect(runtime.sentMessages.count == 1,
                 "expected one message for \(description), got \(runtime.sentMessages.count)")
    guard let msg = runtime.sentMessages.first else { return }
    try uiExpect(matches(msg), "unexpected message for \(description): \(String(describing: msg))")
}

private func expectSingleActivateAlert(
    _ runtime: AppRuntime,
    _ description: String,
    alertId: AlertId
) throws {
    try uiExpect(runtime.sentMessages.count == 1,
                 "expected one message for \(description), got \(runtime.sentMessages.count)")
    guard let msg = runtime.sentMessages.first else { return }
    guard case .activateAlert(let actual) = msg else {
        throw UITestFailure(message: "unexpected message for \(description): \(String(describing: msg))")
    }
    try uiExpect(actual == alertId,
                 "\(description) id mismatch: expected \(alertId.rawValue), got \(actual.rawValue)")
}

private func isActivateAlert(_ msg: Msg, alertId: AlertId) -> Bool {
    if case .activateAlert(let actual) = msg { return actual == alertId }
    return false
}
