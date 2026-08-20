# Repair the focused pane's alerts in one reconcile pass (REDUCE-3)

## Context

Audit item REDUCE-3 (docs/scratch/2026-08-18-construction-audit.md). The rule
"under `alertClearMode == .focus`, the selected tab's focused pane has no
unread alerts" is enforced by hand-written copies of the same two lines in
every arm that moves focus. The audit counted nine copies in
`lib/DanTermCore/Sources/DanTermCore/Update.swift`; a tenth landed the next
day (commit 953aa5fc, the zoom arm), confirming the defect class is growing.
One selection-changing path never got a copy: `closeTabRemoval` picks a
fallback tab with a bare `selectedTabId` write, so closing the selected tab
leaves the next tab's focused pane badged when selecting that tab by hand
would have cleared it. That is a live, testable defect today.

Desired outcome: the rule is enforced once, as a reconcile pass in the
`defer` block at the top of `update()`, beside `reconcileTabState`. All ten
copies are deleted. A model in which focus mode is on, the app is active, and
the selected tab's focused pane holds an unread alert stops being reachable,
so "this arm forgot to clear alerts" ceases to be a possible defect.

Load-bearing premises, verified against the working tree:

- The only two alert-creating sites in the core (the `.sessionBell` arm and
  `desktopAlertCommands`) skip creation exactly when the app is active and
  the pane is the selected tab's focused pane. They deliberately raise alerts
  on the focused pane while the app is inactive, and existing tests pin that
  contract (`testBellOnFocusedPaneWhileInactiveCreatesAlertAndNotification`,
  `testDesktopNotificationOnFocusedPaneWhileInactiveCreatesAlertAndNotification`,
  both asserting `isUnread == true` under default focus mode). An idempotent
  pass gated on `isAppActive` therefore cannot wipe a freshly raised alert.
- Every deleted copy clears the pane that is the selected tab's focused pane
  by the time `update()` returns (`PaneTree.adopt` and `PaneTree.zoom` both
  set `focusedPaneId`; the move/new-tab arms select the target tab; the zoom
  and close copies are fenced on the selected tab), so the pass reproduces
  each one except for the inactive-app case covered by AR1.
- No existing test asserts that a focus change while the app is inactive
  clears alerts (checked every `isAppActive = false` site in the test tree).

## Decision

Add a `reconcileFocusedPaneAlerts` pass to the `defer` block in
`Update.swift#update`: when `config.alertClearMode == .focus` and
`model.isAppActive`, mark alerts read for the selected tab's
`paneTree.focusedPaneId`. Delete all ten focus-mode copies. The audit's
starter kit (REDUCE-3, construction audit) lists the sites; the pass makes
`.appBecameActive`'s whole copy block fall out because that arm sets
`isAppActive = true` before the defer runs.

Decisive constraints:

- The pass runs after `reconcileTabState`, which repairs `selectedTabId`;
  the alert repair must read the final selection.
- The pass keys on the focused pane, not on `desiredPaneFocus`: alert
  clearing ignores whether the caret is in the terminal or its search field
  (today `.searchFieldBecameFirstResponder` clears alerts too). Do not unify
  with the app-layer focus projection REDUCE-4 will touch.
- The `isAppActive` gate is required, not optional: without it the pass
  would mark a background-raised focused-pane alert read inside the same
  `update()` call that created it, killing the dock badge and failing the
  two tests named above. This was the audit's decide-first question; the
  counting forces the gate.
- The responder arms' fences (a pane outside the selected tab must not move
  this tab's focus) are not part of the copies and stay.

## Behavior change (accepted)

Today a focus change clears the focused pane's alerts even while DanTerm is
inactive (for example a background IPC `pane.focus` or `tab.select`). With
the gate, the badge survives until the app is foregrounded, at which point
the pass clears it. This is transient, self-healing, pinned by no existing
test, and structurally unavoidable (see AR1).

## Invariants

- I1: After any `update()` call, when `alertClearMode == .focus` and
  `isAppActive`, the selected tab's focused pane has no unread alerts --
  regardless of which message ran, including tab-close fallback selection.
- I2: An alert raised on the selected tab's focused pane while the app is
  inactive is not cleared by automatic reconciliation before the app becomes
  active. Explicit acknowledgement (`.markAlertRead`, `.markAllAlertsRead`,
  `.clearAlertsForPane`, `.goToMostRecentAlertPane`) still clears it, as
  today.
- I3: Automatic reconciliation touches only the selected tab's focused pane:
  no message clears a background pane's or background tab's unread alerts
  through the pass. Explicit acknowledgement commands are unaffected.
- I4: Manual mode (`alertClearMode == .manual`) is untouched: no focus
  change or app activation clears alerts.

## Proof obligations

- PO1 (I1, the live defect; write this failing test first): in focus mode,
  raise an unread alert on tab A's focused pane, select tab B, close tab B.
  Tab A becomes selected and its focused pane's alert is read. Fails today
  because `closeTabRemoval` never clears.
- PO2 (I1, regression net for the ten deletions): in focus mode with the app
  active, after each focus-moving route -- select tab, move pane to tab,
  focus direction, last-pane close that moves focus, zoom to a sibling -- no
  unread alert survives on the selected tab's focused pane. Passes today;
  must still pass with the copies gone. Existing coverage:
  `testSelectTabFocusModeMarksFocusedPaneAlertsRead` and siblings
  (UpdateTabTests), `paneFocusClearsTargetPaneAlertsInFocusMode`
  (UpdateIpcTests); add scenarios where none exists.
- PO3 (I2): pinned by the two existing inactive focused-pane tests in
  UpdateSessionEventTests; they must pass unchanged. Add one test pinning
  the accepted behavior change: with the app inactive, a focus change onto a
  pane with an unread alert leaves it unread, and `.appBecameActive` then
  clears it.
- PO4 (I3): pinned by `testAppBecameActiveLeavesBackgroundPaneAlertUnread`
  (UpdateLifecycleTests) and the two-leg closePane test (UpdatePaneTests);
  unchanged.
- PO5 (I4): pinned by the existing manual-mode tests (UpdateLifecycleTests,
  UpdatePaneTests, UpdateAlertTests); unchanged.

## Non-goals

- The `.focusSession(focused: false)` loops in `applySelectTab` and the move
  arms stay: deriving terminal focus is REDUCE-4.
- The non-focus-gated `markAlertsReadForPane` uses stay: manual clear
  commands, `.goToMostRecentAlertPane`, and the one-unread-per-pane step in
  the two alert-raising helpers.
- No app-layer reconcile changes; this pass lives in the pure core.

## Accepted risks

- AR1: The inactive-focus-change behavior delta above. Preserving today's
  behavior is incompatible with any state-invariant pass: clearing on a
  background focus change but not on a background raise requires knowing
  which transition happened, which is per-arm code -- the structure being
  removed. Rejected variants: an ungated pass (breaks the tested
  background-alert contract in the same update call) and a gated pass plus
  per-arm copies for the inactive case (reintroduces the copy class to
  protect a badge nobody can see).

## Implementation discretion

- Where `reconcileFocusedPaneAlerts` and `markAlertsReadForPane` live
  (`markAlertsReadForPane` is private to Update.swift; the sibling passes
  live in ModelOperations.swift -- one of the two moves, subject to
  `scripts/core-purity-lint.sh`).

## Verification

TDD per AGENTS.md: PO1's test first, red for the stated reason, then the
pass, then delete the copies. Full check:
`swift test --package-path lib/DanTermCore`, then `just test`. Also re-read
the UpdateAlertTests manual-mode tests around `.goToMostRecentAlertPane`
before assuming they are untouched (the audit flags one that uses manual
mode specifically to keep the focus path out of the way).
