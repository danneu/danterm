# Next Unread Alert Behavior

## Summary

Change Cmd-Shift-A's visible menu title to `Next Unread Alert` and change its
behavior from "walk unread panes globally" to "clear the current tab, then jump
to the latest unread alert in another tab; only fall back to an unfocused pane in
the current tab when no other tab has unread alerts."

No public API or CLI changes. Keep the internal `goToMostRecentAlertPane`
message/selector names for now to minimize churn.

## UX Goal

Cmd-Shift-A should be a fast triage key for alert-driven work. When the user is
done with the current tab, they can hit the shortcut to clear that tab's unread
state and fly to the next tab that still needs attention. Same-tab pane hopping
is a fallback for the "no other tab needs work" case, not the primary loop.

## Key Changes

- In `AppDelegate`, change the Pane menu item title from
  `Go to Most Recent Unread Alert` to `Next Unread Alert`; keep the Cmd-Shift-A
  shortcut and existing selector.
- In `README.md`, update the Keybinds table row for Cmd-Shift-A to the same
  `Next Unread Alert` action label so docs match the menu.
- In the `Msg.goToMostRecentAlertPane` update branch:
  - Capture the selected tab and its live pane IDs before any navigation.
  - Treat only live unread alerts as candidates; ignore stale-pane alerts for navigation.
  - If any other tab has a live unread alert, mark all unread alerts in the original current tab as read, then navigate to the newest live unread alert outside the original current tab.
  - If no other tab has live unread alerts, find the newest live unread alert in an unfocused pane of the current tab. If one exists, navigate to that pane, then mark all unread alerts in the current tab as read.
  - If no other tab alert and no unfocused current-tab alert exist, just clear unread alerts in the current tab and emit no focus command.
- Update the branch comment to explain the UX goal above: the shortcut is for
  finishing the current tab and moving to the next tab that needs work, with
  same-tab navigation only as the fallback when no other tab has unread alerts.
- Preserve existing destination behavior from `navigateToPane`: focus-mode may
  clear the destination pane on focus, while manual mode does not clear the
  destination tab until the next shortcut press.

## Test Plan

- Update alert-navigation tests so old "walk panes within current tab" behavior
  is no longer expected.
- Verify the README Keybinds row documents Cmd-Shift-A as `Next Unread Alert`.
- Add or adjust core tests for:
  - Current tab has an unread sibling pane and another tab has an unread alert: one press clears all current-tab alerts and jumps to the other tab, not the sibling pane.
  - No other tab has unread alerts and current tab has an unread unfocused pane: one press focuses the latest unread sibling pane and then clears all current-tab alerts, including in manual mode.
  - Current tab has only focused-pane alerts and no other tab alerts: one press clears current-tab alerts and does not emit `makeFirstResponder`.
  - Repeated presses walk alert-bearing tabs by clearing the tab just visited before moving to the next tab with unread alerts.
  - Read alerts and stale-pane alerts are skipped for navigation.
- Run TDD-style:
  - First run `swift test --package-path lib/DanTermCore --filter UpdateAlertTests` after test edits and confirm the expected failure.
  - Then implement the update logic and rerun the same filter.
  - Finally run `just test`.

## Assumptions

- "Alerts" means unread alerts only.
- "Other tabs" means tabs other than the tab selected when Cmd-Shift-A was pressed.
- Clearing the current tab is explicit shortcut behavior and ignores
  `alertClearMode`; manual mode still preserves destination alerts until that
  destination tab becomes the current tab and the shortcut is pressed again.
- Internal names stay unchanged in this pass; only the user-visible menu item
  becomes `Next Unread Alert`.
