# Narrow focus and alert-ack effects away from `.rebuildContentView`

## Context

`AppRuntime.rebuildContentView()` (`app/AppRuntime.swift:1377-1471`) is heavy:
it tears down every content subview, recreates the `SplitContainerView`,
defocuses then re-focuses every surface, resets first responder, dismisses
todo popovers, and rehydrates the search overlay and theme browser. It is
designed for cases where the split-tree topology actually changed.

Today it also runs for two kinds of mutation that don't change topology:

- **Focus-only:** `.paneBecameFirstResponder` (`app/Update.swift:526-548`)
  mutates only `tab.focusedPaneId`. The visible effect should be: old pane's
  green border off, new pane's green border on, sidebar/title chrome sync.
- **Alert-only:** 7 alert ack / read sites in `app/Update.swift` mutate only
  `alerts[i].isUnread`. The visible effect should be: each affected pane's
  red bell border and per-pane toolbar alert badge recomputed, the global
  bell badge auto-fires from `AppRuntime.swift:219-223`, sidebar rows refresh.

Running the full rebuild for these can cause focus glitches (overlays
clobbered, search field stolen), unnecessary churn (subview teardown), and
forces tests to assert structure-sensitive effect names instead of behavior.

A narrow effect already exists for this shape (`.updatePaneAlertBorder`)
but it hardcodes `setFocusBorder(false, ...)` in the handler, so it cannot
replace the rebuild on the focused-with-bell case. We extend it.

## Approach

Three changes, all small and aligned:

### 1. Generalize the narrow border effect

Rename `Effect.updatePaneAlertBorder(paneId:)` to
**`Effect.refreshPaneBorder(paneId:)`** in `app/Effect.swift:27`.

In the handler at `app/AppRuntime.swift:442-444`, compute both bits from
the model rather than hardcoding focus state:

```swift
case .refreshPaneBorder(let paneId):
    let isFocused = isFocusedAndVisible(paneId, in: model)
    let hasBell = paneHasUnreadAlert(paneId, alerts: model.alerts)
    surfaces[paneId]?.setFocusBorder(isFocused, hasBell: hasBell)
```

Add a small pure helper `isFocusedAndVisible(_ paneId:, in model:)` in
`app/ModelOperations.swift` next to `paneHasUnreadAlert`. It returns `true`
only when the pane is the focused pane of the selected tab **and** that tab
is not single-pane (mirrors the `isSinglePane` guard at
`app/AppRuntime.swift:1422-1427`). This keeps the green-border invariant
intact (no green on single-pane tabs), makes the predicate directly
unit-testable, and avoids duplicating the same model-only logic later.

The model is the single source of truth; callers say "this pane's border
may be stale, recompute it."

### 2. Replace `.rebuildContentView` in focus-only and alert-only sites

In `app/Update.swift`, replace `.rebuildContentView` with narrow effects at
exactly these 8 sites — 1 focus-only + 7 alert-only (already classified —
STRUCTURAL sites stay as-is):

**Focus-only (1 site):**

- `.paneBecameFirstResponder` (`Update.swift:526-548`): capture
  `oldFocusedId` (done at line 528), then emit
  `[.refreshPaneBorder(oldFocusedId), .refreshPaneBorder(paneId)]` instead
  of `.rebuildContentView`. Keep the existing `syncFocusedPaneChrome` call
  and `.scheduleCheckpoint`. If `alertClearMode == .focus` clears unread
  alerts for the newly focused pane, also emit `.refreshPaneToolbar(paneId:)`
  for that pane so its toolbar badge clears without relying on a rebuild.
  Do **not** emit `.makeFirstResponder(paneId)`:
  this message is dispatched from `TerminalView.becomeFirstResponder` at
  `app/TerminalView.swift:254-263` *after* AppKit has already moved focus
  to the view, so re-requesting first responder here would create
  circular focus churn. Caller-initiated focus paths like `.focusDirection`
  (`Update.swift:524`) already emit `.makeFirstResponder` before AppKit
  fires the callback, so the keyboard-driven path stays intact.

**Alert-only (7 sites):**

- `.ackAllAlertsAcrossTabs`-style path at `Update.swift:492`
- `.markAlertRead` at `Update.swift:903`
- `.markAllAlertsRead` at `Update.swift:911`
- `.activateAlert` stale-pane branch at `Update.swift:920`
- `.goToMostRecentAlertPane` ack-current-tab branch at `Update.swift:941`
- `.clearAlertsForPane` at `Update.swift:953`
- `.ackTabAlerts` at `Update.swift:961`

For each, replace `.rebuildContentView` with targeted alert-chrome refresh
effects for every affected pane: `.refreshPaneBorder(pid)` plus
`.refreshPaneToolbar(pid)`, via `refreshPaneAlertChromeEffects` at
`Update.swift:2498-2505`. Use the existing `paneIdsForTab` helper and the
existing `markAlertsReadForPane` helper to identify affected panes. Keep
`.reloadSidebar` and any `.dismissAlertsPopover` already in the effect list.

The global toolbar bell badge requires no new explicit update effect — it
auto-fires from `AppRuntime.swift:219-223` whenever `totalUnreadAlertCount`
changes. The per-pane toolbar alert badge is different: it is rendered inside
each `PaneWrapperView`, so it must get `.refreshPaneToolbar(paneId:)` when a
narrow alert path changes that pane's unread count. The old rebuild path
implicitly did this through `refreshPaneToolbars()`.

For paths that touch multiple panes (e.g. `markAllAlertsRead`), emit one
alert-chrome refresh pair per affected pane. Cheap — the handlers are a layer
write plus one pane toolbar update — and avoids rebuilding the entire content
view.

Update those two existing emit sites to use the new name
(`.refreshPaneBorder` instead of `.updatePaneAlertBorder`) and to emit the
matching `.refreshPaneToolbar(paneId:)`, because creating an unread alert also
increments the pane toolbar badge.

### 3. Lock in the new effect contract in tests

The whole point of the refactor is the effect-graph change: focus-only
and alert-only paths must stop emitting `.rebuildContentView` and must
start emitting targeted alert-chrome refreshes for the affected panes. Model-state
assertions alone don't catch a regression that re-introduces the heavy
rebuild — the model would still update correctly. So each refactored
test gets three layers:

1. **Model state** (already present in most tests, add where missing):
   e.g. `model.alerts.first(where: { $0.id == alertId })?.isUnread == false`,
   `selectedTab(in: model)?.focusedPaneId == expectedId`.
2. **Negative effect assertion** — assert
   `!hasEffect(effects) { if case .rebuildContentView = $0 { true } else { false } }`
   on each of the 8 refactored branches. This is the contract this
   refactor establishes; without it the refactor can silently regress.
3. **Positive effect assertion** — assert one
   `.refreshPaneBorder(paneId)` and, when the pane's unread count changes,
   one `.refreshPaneToolbar(paneId)` per affected pane. This is
   structure-sensitive in name but contract-sensitive in intent: it pins down
   "this branch updates this pane's alert chrome," which is the user-visible
   behavior the model alone can't express (borders and pane toolbar badges live
   in the view).

This goes beyond a pure "behavioral only" rewrite, but the AGENTS.md
rubric warns against structure-sensitive *implementation pinning*, not
against contract assertions. The effect graph is the contract here.

Affected test files:

- `tests/UpdateAlertTests.swift` — `testMarkAlertRead`,
  `testMarkAllAlertsRead`, `testActivateAlert` (stale-pane variant),
  `testGoToMostRecentAlertPane`, `testClearAlertsForPane`,
  `testAckTabAlerts`, ack-all-tabs variant.
- `tests/UpdatePaneTests.swift` — only the `.paneBecameFirstResponder`
  tests at lines ~161-185 and ~591-595 (the split/close/move tests assert
  STRUCTURAL rebuilds and stay as-is). The focus-mode alert-clear test also
  asserts `.refreshPaneToolbar` for the newly focused pane when its unread
  alerts are cleared. Add a sibling negative test for the same focus callback
  with no alert clear (manual clear mode or no unread alert) that asserts
  `.refreshPaneToolbar(paneId:)` is not emitted, so the toolbar refresh stays
  conditional on `clearedAlerts`.
- `tests/UpdateGhosttyTests.swift` — assertions at lines 33-39 and 211-217
  reference the old `.updatePaneAlertBorder` case name and must be
  renamed to `.refreshPaneBorder`; also assert `.refreshPaneToolbar` for
  those alert-creation paths so the pane toolbar badge increments without
  relying on a rebuild.
- `tests/ModelOperationsTests.swift` — add direct coverage for
  `isFocusedAndVisible`: focused pane in a multi-pane selected tab returns
  true, focused pane in a single-pane selected tab returns false, a pane in a
  non-selected tab returns false, and a non-focused pane returns false.

The STRUCTURAL test assertions stay. They're still structure-sensitive,
but flipping them would expand scope without benefit; this plan addresses
that anti-pattern only where it intersects with the refactor.

## Verification

1. **Unit tests pass:** `just test`. No *positive* `.rebuildContentView`
   expectations remain on any of the 8 refactored branches; each refactored
   branch instead carries (a) model-state assertions, (b) a negative
   `!hasEffect(.rebuildContentView)` assertion, (c) one positive
   `.refreshPaneBorder(paneId)` assertion per affected pane, and (d) one
   positive `.refreshPaneToolbar(paneId)` assertion for every affected pane
   whose unread alert count changes. The focus callback tests also include
   the negative case proving `.refreshPaneToolbar(paneId:)` is not emitted
   when focus does not clear unread alerts. `ModelOperationsTests` directly
   covers `isFocusedAndVisible` for selected/non-selected, focused/non-focused,
   and single-pane/multi-pane cases.
2. **App build:** `just build` (debug build to `.build/DanTerm Dev.app`).
3. **Manual focus path:** launch `just build-run`, open a tab, split into
   two panes. Click between panes and confirm the green border moves
   cleanly with no visible flash, search overlay survives a focus change,
   and the theme browser (if open) keeps its focus.
4. **Manual alert paths:** in a split, trigger a bell in the unfocused
   pane (e.g. `printf '\a'` in that pane via DanTerm IPC). Confirm:
   - red border appears on the unfocused pane
   - dock + global toolbar bell badge increment
   - pane toolbar badge increments on the alerted pane
   - clicking the focused pane (focus-only path) doesn't disturb the
     unfocused pane's red border
   - acking via Cmd-Shift-. (`ackTabAlerts`) clears the red border and the
     pane toolbar badge without visible rebuild flash; sidebar row updates and
     the global badge decrements
5. **Regression check:** structural ops still work — split a pane, close a
   pane, switch tabs, zoom and unzoom. These still call
   `.rebuildContentView` and should be unchanged.

## Files touched

- `app/Effect.swift` — rename one case.
- `app/AppRuntime.swift` — rename handler case and generalize border
  computation to call `isFocusedAndVisible`.
- `app/ModelOperations.swift` — add the pure `isFocusedAndVisible` helper near
  `paneHasUnreadAlert`.
- `app/Update.swift` — 8 narrow-site rewrites (1 focus + 7 alert),
  2 emit-site renames, targeted pane-toolbar refreshes for alert count
  changes.
- `tests/UpdateAlertTests.swift`, `tests/UpdatePaneTests.swift` — drop
  stale `.rebuildContentView` assertions, add model-state assertions
  where missing, add negative-rebuild plus positive `.refreshPaneBorder`
  and `.refreshPaneToolbar` contract assertions per affected pane, including
  the negative focus-callback toolbar-refresh case.
- `tests/UpdateGhosttyTests.swift` — rename the two
  `.updatePaneAlertBorder` case references at lines 33 and 207 to
  `.refreshPaneBorder` and assert `.refreshPaneToolbar` for alert-creation
  paths.
- `tests/ModelOperationsTests.swift` — add direct predicate tests for
  `isFocusedAndVisible`.
