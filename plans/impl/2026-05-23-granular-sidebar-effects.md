# Plan: Granular sidebar effects for selection and alert state

## Context

`SidebarView.reload(model:)` (`app/SidebarView.swift:280-353`) is the only path
the model has to update the sidebar today: it reconciles its item caches,
calls `outlineView.reloadData()`, then restores expansion / multi-selection /
scroll. It's emitted via the `.reloadSidebar` Effect from ~26 sites in
`app/Update.swift`.

For structural changes (tab/group create, close, move, rename, reorder) this
is the right shape. For two other categories, it's overkill:

1. **Selection-only changes.** `applySelectTab` (`app/Update.swift:2282-2300`)
   emits `.reloadSidebar` on every cmd-N, mouse click, MRU commit,
   jump-mode commit, and alert nav -- even though only `model.selectedTabId`
   changed. AppKit already supports incremental selection via
   `selectRowIndexes`, and the project already has granular cell-update
   effects (`updateSidebarTabRow` / `updateSidebarGroupRow`) introduced in
   `4ceca9c` for the same reason.

2. **Alert mark-read.** `markAlertRead`, `markAllAlertsRead`,
   `clearAlertsForPane`, `clearAlertsForTabs`, and `ackTabAlerts` flip
   `isUnread` flags on a known set of tabs and then emit `.reloadSidebar`
   to re-render badges. The inverse direction (alert *insertion* in
   `surfaceBell` at `app/Update.swift:787` -- emission at line 808 -- and
   `desktopNotification` at line 819 -- emission at line 839) already
   uses `.updateSidebarTabRow`; the clear paths are asymmetric for no
   good reason.

Result: clean architecture where **non-structural mutations use granular
effects; structural ones use `.reloadSidebar`.** Selection becomes a typed
effect with the same multi-selection policy `resolveReloadSelection`
already encodes and unit-tests.

## Scope

In:

- New `.setSidebarSelection(tabId:)` effect, used by `applySelectTab`.
- Replace `.reloadSidebar` in the five alert mark/clear paths
  (`markAlertRead`, `markAllAlertsRead`, `clearAlertsForPane`,
  `clearAlertsForTabs`, `ackTabAlerts`) with per-tab `.updateSidebarTabRow`
  (plus `.updateSidebarGroupRow` for collapsed groups), driven by the
  precomputed affected-tab set.

Out:

- All structural emitters of `.reloadSidebar` (tab/group create/close/move/
  rename/reorder, jump-mode entry/cancel, state restore/import) keep
  `.reloadSidebar`.
- `jumpModeCommit`'s `.reloadSidebar` (`app/Update.swift:2380`) stays --
  jump-mode draws letter badges on every visible tab during the mode, and
  exiting the mode requires clearing those badges from rows other than the
  one being selected. `.setSidebarSelection` only touches the selected
  row's emphasis, so a mode-exit needs the broad reload.
- `navigateToPane`'s `.reloadSidebar` (`app/Update.swift:2412`, inside
  the handler at `2393`) stays -- it runs after focus shifts within a
  tab, where multiple things may have changed and a full reload is the
  simpler contract.

## Changes

### `app/Effect.swift`

Add `case setSidebarSelection(tabId: TabId)` next to the existing sidebar
effects (line 28-30).

### `app/AppRuntime.swift`

Add a case alongside the existing sidebar handlers (line 446-453):

```swift
case .setSidebarSelection(let tabId):
    sidebarView?.applySelection(tabId: tabId, model: model)
```

### `app/SidebarView.swift`

Extract the two-phase selection restore at `app/SidebarView.swift:317-345`
into a private helper so both `reload(model:)` and the new selection-only
path share it:

```swift
private func applyRestoreSelection(_ restoreSet: Set<TabId>, selectedTabId: TabId?)
```

The helper must explicitly clear AppKit's selection when `restoreSet` is
non-empty but every member resolves to `row(forItem:) == -1` (i.e. the
target tab(s) are inside a collapsed group). Use
`outlineView.selectRowIndexes(IndexSet(), byExtendingSelection: false)`
-- this is a programmatic deselect and is not blocked by
`allowsEmptySelection = false` (which only governs user-initiated
deselect). Without this clear, today's `reload(model:)` happens to end
up with no visible selection (because `reloadData()` itself drops the
prior selection by item identity), but `applySelection` doesn't reload
so the previously-selected row would remain visually highlighted while
`model.selectedTabId` has moved to a hidden tab -- a new
sidebar/model divergence the plan must not introduce.

Attach a short code comment to the empty-IndexSet branch inside
`applyRestoreSelection` summarizing this reasoning. The branch has no
pure-update test coverage (it depends on AppKit's runtime selection
model; verified only via smoke step 4), so a future refactorer
inspecting `applyRestoreSelection` could strip it as dead code without
the comment.

This branch is reachable via `selectAdjacentTab` (`app/Update.swift:121`,
`adjacentTabId` in `app/ModelOperations.swift:400-410`) which flattens
across groups without filtering collapsed ones, so cmd-shift-N can land
on a tab inside a collapsed group.

Add the public entry point:

```swift
func applySelection(tabId: TabId, model: AppModel) {
    isReloading = true
    defer { isReloading = false }
    currentModel = model
    let priorSelectedTabIds: Set<TabId> = ...  // snapshot as in reload() lines 285-290
    let liveTabIds: Set<TabId> = Set(model.groups.flatMap(\.tabs).map(\.id))
    let restoreSet = resolveReloadSelection(
        priorSelectedTabIds: priorSelectedTabIds,
        liveTabIds: liveTabIds,
        selectedTabId: tabId)
    applyRestoreSelection(restoreSet, selectedTabId: tabId)
    refreshRowEmphasis(focusedTabId: tabId)
    // scroll-into-view mirroring reload() lines 348-352
}

/// Walk every visible tab row and recompute its
/// `SidebarRowView.forceEmphasizedSelection` against `focusedTabId`.
/// Mirrors what `outlineView(_:rowViewForItem:)` (lines 467-478) does
/// during reloadData, so a selection-only path keeps the focused-tab
/// accent color when the terminal pane holds first responder.
private func refreshRowEmphasis(focusedTabId: TabId?) {
    for row in 0..<outlineView.numberOfRows {
        guard let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView else { continue }
        let rowTabId: TabId? = {
            guard let item = outlineView.item(atRow: row) as? SidebarItem,
                  case .tab(let tab) = item.kind else { return nil }
            return tab.id
        }()
        rowView.forceEmphasizedSelection = shouldForceSidebarRowEmphasis(
            rowTabId: rowTabId, focusedTabId: focusedTabId)
    }
}
```

Notes:

- Does not call `reconcile()` or `reloadData()`.
- `currentModel = model` happens **first** so `shouldForceSidebarRowEmphasis`
  and any other reads inside selection/emphasis code see the new
  `selectedTabId`.
- `isReloading = true` guards the `selectionDidChange` notification path
  (`app/SidebarView.swift:491-500`) so the programmatic selection doesn't
  bounce back as a `.selectTab` Msg.
- `refreshRowEmphasis` is the per-row equivalent of what `reloadData()`
  achieves indirectly by re-invoking `rowViewForItem` for each visible row
  (`app/SidebarView.swift:467-478`). Without it, the previously-focused
  row keeps `forceEmphasizedSelection = true` and the newly-focused row
  draws with grey selection while the terminal holds first responder.
- If `tabItemCache` has no entry for `tabId`, `applyRestoreSelection` silently
  skips -- matches the existing `updateTabRow` / `updateGroupRow` convention
  (`app/SidebarView.swift:370, 386`). The invariant is "every tab in the
  model has a cached sidebar row before `applySelectTab` runs"; in current
  call sites this holds.

### `app/Update.swift`

Change `markAlertsReadForPane` (line 2476) to return `Bool` -- true iff
any alert flipped from unread to read. Annotate `@discardableResult` so
the existing 12 callers (lines 250, 343, 423, 488, 534, 799, 830, 938,
952, 960, 2293, 2403) don't need `_ =` decoration:

```swift
@discardableResult
private func markAlertsReadForPane(_ paneId: PaneId, in model: inout AppModel) -> Bool {
    var changed = false
    for i in model.alerts.indices where model.alerts[i].paneId == paneId && model.alerts[i].isUnread {
        model.alerts[i].isUnread = false
        changed = true
    }
    return changed
}
```

Rewire `applySelectTab` (currently line 2282-2300). Note: `.rebuildContentView`
stays in this handler because tab switching legitimately swaps the entire
pane tree, which is distinct from the alert paths above that only need
per-pane border refreshes. The content rebuild incidentally refreshes
the newly-focused pane's bell border on focus-mode auto-clear, so no
explicit `.refreshPaneBorder` is needed here.

```swift
private func applySelectTab(_ model: inout AppModel, id: TabId) -> [Effect] {
    guard id != model.selectedTabId else { return [] }
    var effects: [Effect] = []
    if let oldTabId = model.selectedTabId {
        for oldPaneId in paneIdsForTab(oldTabId, in: model) {
            effects.append(.focusSurface(paneId: oldPaneId, focused: false))
        }
    }
    model.selectedTabId = id
    var alertsCleared = false
    if model.config.alertClearMode == .focus, let tab = selectedTab(in: model) {
        alertsCleared = markAlertsReadForPane(tab.focusedPaneId, in: &model)
    }
    effects.append(.rebuildContentView)
    effects.append(.setSidebarSelection(tabId: id))
    if alertsCleared {
        effects.append(.updateSidebarTabRow(tabId: id))
        if let group = groupForTab(id, in: model), group.isCollapsed {
            effects.append(.updateSidebarGroupRow(groupId: group.id))
        }
    }
    effects.append(contentsOf: selectionSyncEffects(for: model))
    effects.append(.scheduleCheckpoint)
    return effects
}
```

The "emit updateSidebarTabRow + maybe updateSidebarGroupRow when group is
collapsed" pattern mirrors the existing convention in `syncFocusedPaneChrome`
(`app/Update.swift:2452-2469`; sidebar emission block at `2462-2466`) and
the alert-insertion paths `surfaceBell` (handler `787`, emission `808`)
and `desktopNotification` (handler `819`, emission `839`).

Convert the five alert mark/clear paths. Each one already precomputes
the affected pane set via `unreadAlertPaneIds(for:in:)` and emits
`refreshPaneAlertChromeEffects(for: affectedPaneIds)` (helpers at
`app/Update.swift:2481-2505`) -- a per-pane pair of
`.refreshPaneBorder` + `.refreshPaneToolbar` that handles the bell-border
color *and* the toolbar bell-count badge in one shot. **Keep those
`refreshPaneAlertChromeEffects(...)` emissions intact -- both halves
are observable chrome that drops if the helper is replaced or
narrowed.** The conversion replaces only the trailing `.reloadSidebar`
with the granular sidebar effects. For each path, compute the
affected-tab set from the already-known affected pane set (group tabs
by `tabForPane`/`tabLocation`), emit one `.updateSidebarTabRow` per
affected tab, and emit `.updateSidebarGroupRow` per unique affected
collapsed group:

- **`markAlertRead(alertId)`** (line 898-906): currently emits
  `refreshPaneAlertChromeEffects(for: [paneId]) + .reloadSidebar`. Map
  the alert's pane to its tab via `tabForPane(paneId, in: model)` and
  replace `.reloadSidebar` with `.updateSidebarTabRow(tabId:)` and (if
  group collapsed) `.updateSidebarGroupRow`. The
  `refreshPaneAlertChromeEffects(...)` emission stays. **Stale-pane
  case**: if `tabForPane` returns nil (the pane was destroyed but the
  alert outlived it -- in practice this Msg is only sent from tests
  today, since the popover uses `activateAlert`, but the converted
  code must still handle the case), drop the sidebar update entirely
  and emit only `refreshPaneAlertChromeEffects(for: [paneId])`. Mirrors
  the stale-pane shape of `activateAlert` below.
- **`markAllAlertsRead`** (line 908-911): currently emits
  `refreshPaneAlertChromeEffects(for: affectedPaneIds) + .reloadSidebar`
  after computing `affectedPaneIds = unreadAlertPaneIds(in: model)`
  pre-clear. Reuse the same affected-pane set to derive unique tab ids;
  emit one `.updateSidebarTabRow` per affected tab and one
  `.updateSidebarGroupRow` per unique affected collapsed group, in
  place of `.reloadSidebar`. The
  `refreshPaneAlertChromeEffects(...)` block stays.
- **`clearAlertsForPane(paneId)`** (line 949-953): single pane -> single
  tab; replace `.reloadSidebar` with `.updateSidebarTabRow` (+ collapsed
  group row). `refreshPaneAlertChromeEffects(for: [paneId])` stays.
- **`clearAlertsForTabs(tabIds)`** (line 474-492): currently already
  enumerates `affectedPaneIds` pre-clear and emits
  `refreshPaneAlertChromeEffects(...) + .reloadSidebar`. Compute the
  affected tab set from `validIds` filtered to those that had unread
  alerts, emit one `.updateSidebarTabRow` per such tab and one
  `.updateSidebarGroupRow` per unique affected collapsed group,
  replacing `.reloadSidebar`. The chrome block stays. Triggered by
  sidebar alert-badge clicks (`app/SidebarView.swift:118`) and the
  context-menu batch-clear (`app/SidebarView.swift:970`), so this
  conversion is what protects field-editor stability during those
  high-frequency UI gestures.
- **`ackTabAlerts`** (line 955-961): tab is `model.selectedTabId`;
  currently emits `refreshPaneAlertChromeEffects(for: affectedPaneIds)
  + .reloadSidebar`. Keep `refreshPaneAlertChromeEffects(...)` intact;
  replace `.reloadSidebar` with `.updateSidebarTabRow(tabId:
  selectedTabId)` and (if its group is collapsed)
  `.updateSidebarGroupRow`. **Do not introduce `.rebuildContentView`
  here** -- existing tests assert it is absent
  (`!alertTestHasRebuildContentView(effects)`), and the per-pane
  border+toolbar refresh is what handles the bell-chrome update.
- **`activateAlert` stale-pane branch** (line 916-921): currently emits
  `refreshPaneAlertChromeEffects(for: [alert.paneId]) + .reloadSidebar
  + .dismissAlertsPopover`. Since the pane is gone there is no live
  tab whose badge needs refreshing -- the alert just disappears from
  the popover. Drop the `.reloadSidebar`; keep
  `refreshPaneAlertChromeEffects(for: [alert.paneId])` (AppRuntime
  handles destroyed-surface paneIds gracefully, matching current
  behavior) and `.dismissAlertsPopover`. Do **not** introduce
  `.rebuildContentView` -- the existing test
  `testActivateStaleAlertMarksReadButNoNavigation` (line 106-127)
  covers the stale path with both
  `alertTestHasRefreshPaneBorder` and
  `alertTestHasRefreshPaneToolbar`, and is the template for the new
  shape.
- **`goToMostRecentAlertPane` ack-current-tab branch** (line 932-943):
  currently emits `refreshPaneAlertChromeEffects(for: ackedPaneIds) +
  .reloadSidebar` when no more unread remain. Same shape as
  `ackTabAlerts`: keep `refreshPaneAlertChromeEffects(...)` intact,
  replace `.reloadSidebar` with per-affected-tab `.updateSidebarTabRow`
  + per-affected-collapsed-group `.updateSidebarGroupRow`.

`jumpModeCommit`'s trailing `.reloadSidebar` (line 2380, inside the
valid-target branch of the handler at `app/Update.swift:2370-2382`)
**stays**.
Although `applySelectTab` now handles the selected row's selection and
emphasis, jump mode draws a letter badge on every visible tab while the
mode is active (`configureTabCell` lines 1201-1216, gated by
`currentModel?.jumpMode?.keyMap[tab.id]`). When commit clears
`model.jumpMode = nil`, those badges must be removed from rows other
than the newly-selected one -- only a full `reloadData()` (via
`.reloadSidebar`) reinvokes `configureTabCell` on every visible row.
A future refinement could add a per-row "refresh jump badge" pass to
`applySelection`, but it's out of scope here.

Side effect of keeping the trailing reload: `jumpModeCommit`
valid-target dispatches both `.setSidebarSelection(tabId:)` (via
`applySelectTab`) and `.reloadSidebar`. The reload subsumes the
selection update in the same dispatch cycle. This is accepted -- end
state is correct in one frame, and splitting `applySelectTab` into an
"emit selection?" flag would balloon the surface for marginal gain
(jump-mode commit is a low-frequency keystroke).

## Tests

### Changed assertions (swap surface)

The actual swap surface is narrower than first inventoried. Only two
test files have `.reloadSidebar` assertions tied to paths the plan
converts:

- `tests/UpdateJumpTests.swift` -- `jumpModeCommit` valid-target branch
  keeps its `.reloadSidebar` assertion (mode-exit clears badges across
  rows) and gains a `.setSidebarSelection(tabId:)` assertion for the
  selection itself, contributed by `applySelectTab`.
- `tests/UpdateAlertTests.swift` -- swap `.reloadSidebar` assertions for
  `.updateSidebarTabRow(tabId:)` per affected tab on the five converted
  paths (including `clearAlertsForTabs`). **Keep the existing
  `alertTestHasRefreshPaneBorder(...)` and
  `alertTestHasRefreshPaneToolbar(...)` positive assertions and the
  `!alertTestHasRebuildContentView(...)` negative assertions in those
  tests unchanged** -- the per-pane chrome refresh
  (`refreshPaneAlertChromeEffects` -> `.refreshPaneBorder` +
  `.refreshPaneToolbar`) stays, and `.rebuildContentView` must continue
  to be absent from alert paths. Both helpers are defined in the same
  test file (`alertTestHasRefreshPaneBorder` at line 1061,
  `alertTestHasRefreshPaneToolbar` at line 1068) and are paired across
  every alert-path assertion site. Specifically, also catch the two
  non-mark/clear branches the plan touches:
  - `testGoToMostRecentAlertPaneAcksCurrentTabThenNoMoreAlerts`
    (currently line 492-527) -- replace its `.reloadSidebar` assertion
    with `.updateSidebarTabRow(tabId: selectedTabId)` (the
    ack-current-tab branch's new shape) and a negative assertion that
    no `.reloadSidebar` is emitted. The existing
    `alertTestHasRefreshPaneBorder` and
    `alertTestHasRefreshPaneToolbar` assertions for paneA stay.
  - `testActivateStaleAlertMarksReadButNoNavigation` (currently line
    106-135) -- add a negative assertion that no `.reloadSidebar` is
    emitted. The existing `alertTestHasRefreshPaneBorder`,
    `alertTestHasRefreshPaneToolbar`, and
    `!alertTestHasRebuildContentView` assertions stay. The stale-pane
    branch's new shape is
    `refreshPaneAlertChromeEffects(for: [alert.paneId])` +
    `.dismissAlertsPopover` only -- no badge refresh, no reload, no
    rebuild.

### New tests

These add positive coverage for `.setSidebarSelection` and the
conditional row-update emissions. Test placement follows the Msg
domain:

- `tests/UpdateTabTests.swift`:
  - `applySelectTab` emits `.setSidebarSelection(tabId: new)`. Today
    no test in this file asserts on `.reloadSidebar` for selection
    paths, so this is a pure addition.
  - `applySelectTab` in `.focus` mode emits `.updateSidebarTabRow(tabId: new)`
    iff the new tab's focused pane had unread alerts; emits no row
    update when no alerts were cleared. The two `.focus`-mode
    behaviors prove the true/false branches of the new
    `markAlertsReadForPane` return value via the public `update` API,
    without exposing the private helper.
  - `applySelectTab` to a tab whose group is collapsed emits both
    `.updateSidebarTabRow` and `.updateSidebarGroupRow` when alerts
    cleared.
- `tests/UpdateAlertTests.swift`:
  - `markAllAlertsRead` with unread alerts spanning two tabs emits
    exactly two `.updateSidebarTabRow` effects (one per tab), no
    `.reloadSidebar`.
  - `clearAlertsForTabs` with two tabs (one had unread, one didn't)
    emits exactly one `.updateSidebarTabRow` for the tab that had
    unread, no `.reloadSidebar`. Returns `[]` when neither had unread
    (existing guard).
  - `markAlertRead` with a stale paneId (no live tab) emits
    `refreshPaneAlertChromeEffects(for: [paneId])` only -- no
    sidebar update, no reload.

The collapsed-group-target visibility behavior is verified manually in
smoke step 4 (`applyRestoreSelection`'s empty-IndexSet clear), since
that branch depends on AppKit's runtime selection model and isn't
exercised by the pure update tests.

The closure-based `hasEffect`/`effectCount` helpers in `TestHarness.swift`
need no changes.

## Verification

`just test` to confirm pure-update behavior.

`just build-run` smoke test:

1. Open 3+ tabs across 2 groups; press cmd-1/2/3 -- highlight tracks
   selection, no perceptible reload pop or scroll snap.
2. Shift-click a 3-tab multi-selection, then cmd-click a member -- multi
   stays. Then cmd-N to a fresh tab -- multi collapses to just the new tab
   (matches `resolveReloadSelection` policy).
3. With `alertClearMode = .focus`: trigger a bell on tab B, click tab A,
   then click tab B -- bell badge clears in the row and (if group is
   collapsed) in the group row, in one frame.
4. Set up two groups, collapse the second; tab on the *first* group is
   focused. Press cmd-shift-N (Next Tab -- selection-only via
   `.selectAdjacentTab`) until selection walks into the collapsed group.
   Expected: `model.selectedTabId` and the active pane move to the
   hidden tab, AND the sidebar shows **no** highlighted row (rather than
   leaving the previously-focused tab highlighted, which would indicate
   `applyRestoreSelection`'s empty-IndexSet clear didn't run). Press
   cmd-shift-P to walk back -- the original tab is re-highlighted.
5. Open the alerts popover, click "Mark all as read" with unread alerts in
   3 tabs -- all three badge counts disappear, no full sidebar reload.
6. Trigger a bell on tab B, then click tab B's bell badge in the sidebar
   (`clearAlertsForTabs` path) -- badge clears, no reload pop.
7. Select 3 tabs, right-click -> "Clear alerts" with at least one having
   unread alerts -- affected badges clear in place, no reload pop.
8. Inline-rename a tab; while the field editor is open, click another
   tab's bell badge to clear its alerts -- the rename field editor must
   not lose focus or get clobbered (the `clearAlertsForTabs` conversion
   removes the full reload that previously risked this).
9. Hold cmd-tab to MRU-cycle through 4 tabs, release on a target -- sidebar
   lands on it with no double-reload pop and the new tab draws with the
   blue accent color while the terminal pane has first responder
   (verifies `refreshRowEmphasis`).
10. Activate jump mode, press a letter -- single transition, no flicker;
    jump-letter badges disappear from every tab (verifies the kept
    `.reloadSidebar` in `jumpModeCommit`).

## Risks

- **Re-entrance**: `applySelection` must hold `isReloading = true` across the
  entire `selectRowIndexes` call (both phases). The existing `defer` pattern
  in `reload` is the template.
- **`markAllAlertsRead` affected-set computation**: must enumerate affected
  tabs *before* the loop that clears `isUnread`, otherwise the post-state
  has zero unread alerts and the affected set is empty. Easiest shape:
  build `Set<TabId>` via `model.alerts.filter { $0.isUnread }.compactMap
  { tabIdForPane($0.paneId, in: model) }` first, then run the clearing
  loop, then emit per-tab effects.
- **`tabIdForPane` cost**: the per-alert pane->tab lookup walks `model.groups`.
  For mass clears with many alerts, prefer building a `[PaneId: TabId]` map
  once and reusing it. Negligible at typical N but worth the helper.
- **Inline rename + cmd-N selection**: rename text editor lives on the
  *old* tab's row. Switching tabs via `.setSidebarSelection` doesn't disturb
  other rows' cells (no `reloadData`), so the editor survives intact. This
  is actually an improvement over today's reload-then-restore round trip.
- **Row emphasis ordering**: `applySelection` must set `currentModel = model`
  *before* `refreshRowEmphasis` so the latter reads the new
  `selectedTabId`. Same ordering principle as `reload()`'s reconcile step
  preceding row-view rebuild.
- **Target in collapsed group**: `selectAdjacentTab` (cmd-shift-N/P) can
  land on a tab whose group is collapsed. `applyRestoreSelection` must
  detect "non-empty restoreSet but every member's row = -1" and call
  `selectRowIndexes(IndexSet(), byExtendingSelection: false)` to drop the
  now-stale visual selection. `allowsEmptySelection = false` does not
  block programmatic empty selections; it only governs user-initiated
  deselect.
