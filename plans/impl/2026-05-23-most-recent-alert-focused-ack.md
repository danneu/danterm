# Fix `goToMostRecentAlertPane` swallowing intra-tab alerts

## Context

Cmd-Shift-A (`Msg.goToMostRecentAlertPane`) is supposed to take the user to
the pane that owns the most recent unread alert. In the current
implementation it unconditionally acks every unread alert on the *currently
selected tab* before searching for "most recent unread". So if the only
unread alert lives on a non-focused pane in the current tab (e.g. one tab
with PaneA focused, PaneB has an alert), the ack step clears the only
candidate and the subsequent search returns nothing — focus stays on PaneA
and PaneB's alert is dropped on the floor.

The user expects: pressing Cmd-Shift-A in that scenario shifts focus to
PaneB within the same tab, the way it would if PaneB lived on another tab.
And repeated presses should walk through every unread alert pane, whether
the next one is in the same tab or a different tab, without skipping
siblings.

The design intent for the current ack step (per the comment + the
`testGoToMostRecentAlertPaneRepeatedPressWalksTabs` test) is "repeated
presses walk through *tabs*". We preserve and extend that to "repeated
presses walk through *panes*", which is a strict superset.

## Root cause

`app/Update.swift:932-943`, `.goToMostRecentAlertPane` handler:

```swift
case .goToMostRecentAlertPane:
    // Ack all alerts on the current tab so repeated presses walk through tabs
    var ackedPaneIds: [PaneId] = []
    if let tabId = model.selectedTabId {
        let paneIds = paneIdsForTab(tabId, in: model)
        ackedPaneIds = unreadAlertPaneIds(for: paneIds, in: model)
        for paneId in ackedPaneIds { markAlertsReadForPane(paneId, in: &model) }
    }
    guard let alert = model.alerts.first(where: { $0.isUnread && model.panes[$0.paneId] != nil }) else {
        return ackedPaneIds.isEmpty ? [] : refreshPaneAlertChromeEffects(for: ackedPaneIds) + [.reloadSidebar]
    }
    return refreshPaneAlertChromeEffects(for: ackedPaneIds) + navigateToPane(alert.paneId, in: &model)
```

The bulk ack runs *before* the target search and is independent of
`alertClearMode`, so it destroys unread alerts on non-focused sibling
panes in the current tab in both `.focus` and `.manual` modes.

## Fix

Replace the bulk-current-tab ack with a **focused-pane-only ack**. The
focused pane is the one the user is "leaving" (or has just landed on
after a previous press), so acking only that pane is the right semantic
unit: it consumes the alert on the pane that the user has implicitly
"seen", then jumps to the next unread alert anywhere — same tab or
another tab.

This dissolves both bugs:

1. Intra-tab: PaneA focused, PaneB has alert → focused pane has no
   unread alert, so nothing is acked; the search finds PaneB and we
   navigate there.
2. Multi-pane intra-tab walk: PaneA focused, PaneB and PaneC both have
   alerts → press 1 acks nothing (PaneA clean), navigates to PaneB
   (newest). Press 2: PaneB focused with unread alert (in `.manual`
   mode), so ack PaneB; search finds PaneC; navigate. Press 3: ack
   PaneC; queue empty.

New handler body:

```swift
case .goToMostRecentAlertPane:
    // Ack only the focused pane's alerts (if any), not the whole tab.
    // The focused pane is the one the user is leaving / has already
    // landed on, so it's the only "I've seen this" signal. Per-pane
    // acking lets repeated presses walk every unread alert pane across
    // tabs AND within the same tab, without skipping siblings.
    var ackedPaneIds: [PaneId] = []
    if let selTab = selectedTab(in: model),
       paneHasUnreadAlert(selTab.focusedPaneId, alerts: model.alerts) {
        markAlertsReadForPane(selTab.focusedPaneId, in: &model)
        ackedPaneIds = [selTab.focusedPaneId]
    }

    guard let alert = model.alerts.first(where: {
        $0.isUnread && model.panes[$0.paneId] != nil
    }) else {
        return ackedPaneIds.isEmpty
            ? []
            : refreshPaneAlertChromeEffects(for: ackedPaneIds) + [.reloadSidebar]
    }
    return refreshPaneAlertChromeEffects(for: ackedPaneIds)
        + navigateToPane(alert.paneId, in: &model)
```

### Existing `goToMostRecentAlertPane` tests

Traced against `tests/UpdateAlertTests.swift`. Eight of the existing
tests have identical outcomes under focused-pane-only ack; one encodes
the old bulk-ack contract directly and must be updated as part of this
change.

**Unchanged outcomes:**

- `testGoToMostRecentAlertPaneNavigatesToPaneAndTab` (line 349): focused
  pane on tab2 has no alert → no ack; navigates to paneA. Same outcome.
- `testGoToMostRecentAlertPaneSkipsStaleAlert` (line 372): focused
  pane on tab2 has no alert → no ack; navigates to first valid alert
  (paneA). Same outcome.
- `testGoToMostRecentAlertPaneNoAlerts` (line 401): focused pane has no
  alert → no ack; no alerts → empty effects. Same outcome.
- `testGoToMostRecentAlertPaneUsesCurrentTabAfterMove` (line 409):
  focused pane on tab3 has no alert → no ack; navigates to paneA on
  tab2. Same outcome.
- `testGoToMostRecentAlertPaneSkipsReadAlerts` (line 439): focused pane
  on tab3 has no alert → no ack; navigates to paneA. Same outcome.
- `testGoToMostRecentAlertPaneAcksCurrentTabFirst` (line 470): manual
  mode; focused pane = paneB on tab2 with unread alert → ack paneB
  (matches the test's "current tab's alert should be acked" assertion);
  navigate to paneA. The test's `alertTestHasRefreshPaneBorder(effects,
  paneId: paneB)` still holds because `refreshPaneAlertChromeEffects`
  is called for `[paneB]`. Same outcome.
- `testGoToMostRecentAlertPaneAcksCurrentTabThenNoMoreAlerts` (line 505):
  manual; single tab, focused = paneA with alert → ack paneA; no
  remaining unread → refresh chrome + reloadSidebar. Same outcome.
- `testGoToMostRecentAlertPaneRepeatedPressWalksTabs` (line 533):
  manual; press 1 from tab3 (paneC focused, no alert) → no ack,
  navigate to paneA. Press 2 on tab1 (paneA focused, has alert) → ack
  paneA, navigate to paneB. Press 3 on tab2 (paneB focused, has alert)
  → ack paneB, done. Identical to today.

**Test that must be updated to the new contract:**

`testGoToMostRecentAlertPaneAcksAllPanesInSplit` (line 581) directly
asserts the *old* bulk-ack-the-whole-tab behavior:

```swift
// tab2 selected, paneC focused, paneB + paneC + paneA all unread
try expect(... paneB unread == false, "paneB alert should be acked")  // sibling
try expect(... paneC unread == false, "paneC alert should be acked")  // focused
```

Under focused-pane-only ack, only the focused pane (`paneC`) gets
acked; the sibling (`paneB`) stays unread until the user actually
navigates to it. The user-visible improvement this delivers is exactly
the bug fix: sibling alerts are no longer silently lost when the user
moves away from a split tab.

Update this test to encode the new contract — rename it and rewrite
the assertions:

```swift
test("testGoToMostRecentAlertPaneAcksOnlyFocusedPaneInSplit") {
    var model = makeModel()
    model.config.alertClearMode = .manual
    createTab(&model)  // tab1 with paneA
    let paneA = model.groups[0].tabs[0].focusedPaneId

    createTab(&model)  // tab2 (selected), split into paneB + paneC
    update(&model, .splitPane(direction: .horizontal))
    let paneC = model.groups[0].tabs[1].focusedPaneId
    let tab2PaneIds = allPaneIds(model.groups[0].tabs[1].rootNode)
    let paneB = tab2PaneIds.first(where: { $0 != paneC })!

    // Alert ordering: paneA newest (at 0), paneB at 1, paneC at 2
    model.alerts.insert(AlertModel(
        id: AlertId(), kind: .bell, paneId: paneA,
        title: "DanTerm", body: "tab1 alert", createdAt: Date(), isUnread: true
    ), at: 0)
    model.alerts.insert(AlertModel(
        id: AlertId(), kind: .bell, paneId: paneB,
        title: "DanTerm", body: "split pane B", createdAt: Date(), isUnread: true
    ), at: 1)
    model.alerts.insert(AlertModel(
        id: AlertId(), kind: .bell, paneId: paneC,
        title: "DanTerm", body: "split pane C", createdAt: Date(), isUnread: true
    ), at: 2)

    let effects = update(&model, .goToMostRecentAlertPane)

    // Only the focused pane (paneC) is acked
    try expect(model.alerts.first(where: { $0.paneId == paneC })?.isUnread == false,
        "focused pane's alert should be acked")
    // Non-focused sibling (paneB) is NOT acked — that's the bug fix
    try expect(model.alerts.first(where: { $0.paneId == paneB })?.isUnread == true,
        "non-focused sibling alert should remain unread (not lost)")
    // Other-tab alert (paneA) untouched
    try expect(model.alerts.first(where: { $0.paneId == paneA })?.isUnread == true,
        "paneA alert should still be unread")

    // Navigation goes to the top remaining unread alert (paneA, newest)
    try expect(hasEffect(effects) {
        if case .makeFirstResponder(let pid) = $0, pid == paneA { return true }
        return false
    }, "should navigate to paneA (top unread after acking paneC)")

    // Chrome refresh only for the acked pane
    try expect(alertTestHasRefreshPaneBorder(effects, paneId: paneC),
        "should refresh acked focused pane border")
}
```

### Reused helpers (already defined)

- `selectedTab(in:)` — `app/ModelOperations.swift:336`
- `paneHasUnreadAlert(_:alerts:)` — `app/ModelOperations.swift:869`
- `markAlertsReadForPane(_:in:)` — `app/Update.swift:2476`
- `navigateToPane(_:in:)` — `app/Update.swift:2393` (handles
  alert-clear-on-focus, zoom-on-navigate, refresh effects)
- `refreshPaneAlertChromeEffects(for:)` — `app/Update.swift:2498`

The `unreadAlertPaneIds(for:in:)` and `paneIdsForTab(_:in:)` helpers
that the old handler used are no longer needed in this case (other
callers keep them).

## Files touched

- `app/Update.swift` — modify `.goToMostRecentAlertPane` case only.
- `tests/UpdateAlertTests.swift` —
  - Add the three new regression tests in the "Regression tests" section
    below.
  - Update `testGoToMostRecentAlertPaneAcksAllPanesInSplit` (line 581)
    to the new focused-pane-only contract; the rewritten test is shown
    in the "Existing tests" section above.

No changes to `Msg.swift`, `Effect.swift`, `Model.swift`, or any view code.
No new helpers needed.

## Regression tests (red before fix, green after)

Add inside the existing `// MARK: - goToMostRecentAlertPane Tests` section
in `tests/UpdateAlertTests.swift`. Use the same setup style as the
surrounding tests (`makeModel()`, `createTab(&model)`, `update(&model,
.splitPane(direction: .horizontal))` to add a second pane to the current
tab — see `testPaneBecameFirstResponderMarksAlertsRead` at line 184 for
the pattern).

### Test 1 — focus mode: intra-tab navigation + badge clears

```swift
test("testGoToMostRecentAlertPaneIntraTabNavigatesToAlertPane") {
    var model = makeModel()
    createTab(&model)
    let paneA = model.groups[0].tabs[0].focusedPaneId

    // Split → paneB is created and becomes focused
    update(&model, .splitPane(direction: .horizontal))
    let paneB = model.groups[0].tabs[0].focusedPaneId

    // Re-focus paneA so the alert pane (paneB) is NOT the focused pane
    update(&model, .paneBecameFirstResponder(paneId: paneA))
    try expectEqual(model.groups[0].tabs[0].focusedPaneId, paneA)

    // Unread alert on paneB
    model.alerts.insert(AlertModel(
        id: AlertId(), kind: .bell, paneId: paneB,
        title: "DanTerm", body: "intra-tab", createdAt: Date(), isUnread: true
    ), at: 0)

    let effects = update(&model, .goToMostRecentAlertPane)

    // Focus effect emitted
    try expect(hasEffect(effects) {
        if case .makeFirstResponder(let pid) = $0, pid == paneB { return true }
        return false
    }, "should focus paneB")

    // Model focus moved to paneB (so tab title/header derive from paneB)
    try expectEqual(model.groups[0].tabs[0].focusedPaneId, paneB,
        "tab's focusedPaneId should be paneB after navigation")

    // Tab badge cleared (focus mode auto-clears alerts on the newly focused pane)
    try expectEqual(model.alerts[0].isUnread, false,
        "paneB's alert should be marked read after focus moves to it (focus mode)")
}
```

Pre-fix failure mode: the bulk ack clears paneB's alert before the
"first unread" search runs, the search returns nil, no
`.makeFirstResponder` effect is emitted, and `focusedPaneId` stays on
paneA. The focus-effect and `focusedPaneId == paneB` assertions both
fail. The `isUnread == false` assertion, by itself, would also pass
pre-fix because the bulk ack already clears paneB — it's included as
a forward guard to ensure the *post-fix* badge state is correct
(focus-mode auto-clear via `navigateToPane`, not via spurious bulk
ack); it is not the red→green signal for this bug.

### Test 2 — manual mode: intra-tab navigation without spurious ack

```swift
test("testGoToMostRecentAlertPaneIntraTabDoesNotAckSiblingInManualMode") {
    var model = makeModel()
    model.config.alertClearMode = .manual
    createTab(&model)
    let paneA = model.groups[0].tabs[0].focusedPaneId

    update(&model, .splitPane(direction: .horizontal))
    let paneB = model.groups[0].tabs[0].focusedPaneId

    update(&model, .paneBecameFirstResponder(paneId: paneA))

    model.alerts.insert(AlertModel(
        id: AlertId(), kind: .bell, paneId: paneB,
        title: "DanTerm", body: "intra-tab", createdAt: Date(), isUnread: true
    ), at: 0)

    let effects = update(&model, .goToMostRecentAlertPane)

    try expect(hasEffect(effects) {
        if case .makeFirstResponder(let pid) = $0, pid == paneB { return true }
        return false
    }, "should focus paneB")

    // Manual mode + focused pane had no alert → no ack happens
    try expectEqual(model.alerts[0].isUnread, true,
        "paneB's alert should remain unread (manual mode, no spurious ack)")
}
```

Pre-fix failure mode: the bulk ack runs unconditionally and clears
paneB's alert; the unread-state assertion fails *and* no navigation
happens, so the makeFirstResponder assertion also fails.

### Test 3 — manual mode: repeated presses walk panes within a tab

This guards against F1 (multi-pane intra-tab ping-pong) — the case
where two sibling panes both have unread alerts.

```swift
test("testGoToMostRecentAlertPaneRepeatedPressWalksPanesInTab") {
    var model = makeModel()
    model.config.alertClearMode = .manual
    createTab(&model)
    let paneA = model.groups[0].tabs[0].focusedPaneId

    // Add paneB (becomes focused after split)
    update(&model, .splitPane(direction: .horizontal))
    let paneB = model.groups[0].tabs[0].focusedPaneId

    // Add paneC (becomes focused after split)
    update(&model, .splitPane(direction: .vertical))
    let paneC = model.groups[0].tabs[0].focusedPaneId

    // Re-focus paneA so it's the focused pane; paneB + paneC are siblings
    update(&model, .paneBecameFirstResponder(paneId: paneA))
    try expectEqual(model.groups[0].tabs[0].focusedPaneId, paneA)

    // Two unread alerts in this tab: paneB (newest), paneC (older)
    model.alerts.insert(AlertModel(
        id: AlertId(), kind: .bell, paneId: paneC,
        title: "DanTerm", body: "older", createdAt: Date(), isUnread: true
    ), at: 0)
    model.alerts.insert(AlertModel(
        id: AlertId(), kind: .bell, paneId: paneB,
        title: "DanTerm", body: "newer", createdAt: Date(), isUnread: true
    ), at: 0)

    // Press 1: paneA focused (no alert) → no ack; jump to paneB (newest)
    update(&model, .goToMostRecentAlertPane)
    try expectEqual(model.groups[0].tabs[0].focusedPaneId, paneB,
        "press 1 should land on paneB")
    try expect(model.alerts.first(where: { $0.paneId == paneB })?.isUnread == true,
        "paneB unread after press 1 (manual mode, no clear-on-focus)")
    try expect(model.alerts.first(where: { $0.paneId == paneC })?.isUnread == true,
        "paneC unread after press 1 (sibling not spuriously acked)")

    // Press 2: paneB focused (has alert) → ack paneB; jump to paneC
    update(&model, .goToMostRecentAlertPane)
    try expectEqual(model.groups[0].tabs[0].focusedPaneId, paneC,
        "press 2 should land on paneC, not bounce back to paneB")
    try expect(model.alerts.first(where: { $0.paneId == paneB })?.isUnread == false,
        "paneB acked on press 2 (focused pane consumed)")
    try expect(model.alerts.first(where: { $0.paneId == paneC })?.isUnread == true,
        "paneC unread until landing focus completes press 3")

    // Press 3: paneC focused (has alert) → ack paneC; queue empty
    update(&model, .goToMostRecentAlertPane)
    try expect(model.alerts.first(where: { $0.paneId == paneC })?.isUnread == false,
        "paneC acked on press 3")
    try expect(!model.alerts.contains(where: { $0.isUnread }),
        "all alerts read after walking through siblings")
}
```

Pre-fix failure mode: press 1's bulk ack clears both paneB and paneC
alerts in one shot and emits no navigation effect; subsequent presses
have nothing to do. Multiple assertions fail starting with the
"press 1 should land on paneB" focus check.

## Verification

1. `just test` — run pure unit tests. The three new tests should fail
   first (red), then pass after the handler change (green).
2. Re-run the existing `goToMostRecentAlertPane` tests in the same
   file (lines 347-610-ish) to confirm no regressions in the
   walk-through-tabs behavior, stale-pane handling, or read-skipping
   cases. Note that `testGoToMostRecentAlertPaneAcksAllPanesInSplit`
   has been rewritten (and renamed to
   `testGoToMostRecentAlertPaneAcksOnlyFocusedPaneInSplit`) as part of
   this change — it encodes the new focused-pane-only contract.
3. `just build-run` — manual smoke test of the user's scenario:
   - Open DanTerm, split the current tab into two panes.
   - In the unfocused pane, trigger a bell (e.g. `printf '\a'`).
   - Press Cmd-Shift-A.
   - Verify focus shifts to the bell pane (border highlights, cursor
     moves) and the tab badge clears.
   - Optional: split into three panes, trigger bells in two unfocused
     panes, and confirm successive Cmd-Shift-A presses walk through
     both before doing anything to other tabs.

## Implementation notes

- Kept the current `sidebarAlertUpdateEffects` path for acked panes instead
  of the sample handler's full sidebar reload, matching the repo's existing
  targeted sidebar refresh behavior.
