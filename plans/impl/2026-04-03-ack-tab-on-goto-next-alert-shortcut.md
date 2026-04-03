# Plan: cmd-shift-a acks current tab before navigating to next alert

## Context

When pressing cmd-shift-a (`goToMostRecentAlertPane`), the user wants to work through their "alert todo list" by repeatedly pressing the shortcut. Currently, if the current tab has unread alerts, the user must first cmd-. (ack tab alerts) then cmd-shift-a (navigate to next). This change makes cmd-shift-a automatically ack the current tab's alerts before searching for the next unread alert.

## Change 1: Update.swift (lines 814-818)

Replace the `.goToMostRecentAlertPane` case. Mirror the `hadUnread` guard pattern from `.ackTabAlerts` (line 830) to only ack + refresh when there were actually unread alerts:

```swift
case .goToMostRecentAlertPane:
    // Ack all alerts on the current tab so repeated presses walk through tabs
    var ackedCurrentTab = false
    if let tabId = model.selectedTabId {
        let paneIds = paneIdsForTab(tabId, in: model)
        if model.alerts.contains(where: { $0.isUnread && paneIds.contains($0.paneId) }) {
            for paneId in paneIds {
                markAlertsReadForPane(paneId, in: &model)
            }
            ackedCurrentTab = true
        }
    }
    guard let alert = model.alerts.first(where: { $0.isUnread && model.panes[$0.paneId] != nil }) else {
        return ackedCurrentTab ? [.rebuildContentView, .reloadSidebar] : []
    }
    return navigateToPane(alert.paneId, in: &model)
```

Key decisions:
- Ack happens regardless of `alertClearMode` — this is an explicit user action, matching `.ackTabAlerts`
- Only returns refresh effects when alerts were actually cleared and there's nothing to navigate to. True no-op (no alerts anywhere) still returns `[]`
- `navigateToPane` already includes `.rebuildContentView` and `.reloadSidebar`, so the `ackedCurrentTab` flag only matters on the no-navigation path

## Change 2: UpdateAlertTests.swift

**No changes to existing tests** — `testGoToMostRecentAlertPaneNoAlerts` (line 390) keeps expecting 0 effects since true no-op behavior is preserved.

**Add new tests** (after line 457, before `// MARK: - filteredAlerts`). All fixtures use explicit `insert(..., at: 0)` / `insert(..., at: N)` to control `model.alerts` ordering, since `first(where:)` picks the lowest-index unread valid alert.

All tests use `model.config.alertClearMode = .manual` so that `selectTab` (called via `navigateToPane`) does not auto-clear the destination pane's alerts, allowing us to assert read/unread state precisely.

1. `testGoToMostRecentAlertPaneAcksCurrentTabFirst` — Setup: manual mode. tab1 with paneA, tab2 (selected) with paneB. Insert alert for paneA at index 0, alert for paneB at index 1. Press `goToMostRecentAlertPane`. Assert: paneB's alert marked read, navigates to tab1/paneA, paneA's alert still unread.

2. `testGoToMostRecentAlertPaneAcksCurrentTabThenNoMoreAlerts` — Setup: manual mode. Single tab (selected) with one unread alert. Press `goToMostRecentAlertPane`. Assert: alert marked read, no `.makeFirstResponder` effect (no navigation to another tab), returns `[.rebuildContentView, .reloadSidebar]`.

3. `testGoToMostRecentAlertPaneRepeatedPressWalksTabs` — Setup: manual mode. tab1 with alert (index 0), tab2 with alert (index 1), tab3 selected. First press: tab3 has no alerts (no-op ack), navigates to tab1. Second press: auto-acks tab1, navigates to tab2. Third press: auto-acks tab2, no more unread alerts, returns `[.rebuildContentView, .reloadSidebar]`.

4. `testGoToMostRecentAlertPaneAcksAllPanesInSplit` — Setup: manual mode. Selected tab has two split panes (paneA, paneB) each with an unread alert. Another tab has an unread alert. Press `goToMostRecentAlertPane`. Assert: both paneA and paneB alerts marked read, navigates to the other tab.

## Files to modify

- `app/Update.swift` — `.goToMostRecentAlertPane` case (~10 lines changed)
- `tests/UpdateAlertTests.swift` — 4 tests added (no existing tests changed)

## Verification

1. `just test` — all existing + new tests pass
2. `just build` — compiles
