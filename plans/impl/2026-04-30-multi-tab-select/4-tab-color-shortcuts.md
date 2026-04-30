# Plan: Tab-color shortcuts honor sidebar multi-selection

## Context

After the multiselect branch added multi-tab selection
(`SidebarView.outlineView.selectedRowIndexes`) and the recent unification
refactor dropped the singular `.setTabColor` Msg in favor of plural-only
`.setTabColors(tabIds:color:)`, one asymmetry remains: the keyboard/menu
path for tab color (cmd-1/2/3 = red/orange/yellow, cmd-0 = clear) still
operates on `model.selectedTabId` (the single focused tab), even when the
user has selected multiple tabs in the sidebar. The right-click context
menu in the sidebar partly does the right thing (it acts on the full
selection) but only toggles off in the single-tab case.

Goal: route the keyboard/menu path through the same selection source the
context menu uses, so cmd-1 on a 3-tab selection colors all three; and
extend toggle-off to multi-selection so re-applying a color that every
targeted tab already has clears them all. The unified rule covers any
selection size.

## Verified state of the world

(Only claims with cited `file:line` -- no invented APIs.)

- `app/Msg.swift:43` -- `case setTabColors(tabIds: [TabId], color: TabColor?)`
  is the only color Msg variant. No singular form exists.
- `app/Update.swift:388-405` -- `.setTabColors` handler dedupes/validates
  `tabIds` (`tabLocation(id, in: model) != nil`) and returns `[]` if the
  resulting `validIds` is empty. So the dispatcher does not need to filter
  invalid IDs -- but it DOES need to avoid sending an empty-array Msg when
  the user has nothing selected, since that would be a no-op disguised as
  an action.
- `app/ModelOperations.swift:989-992` (planning-time) -- `toggleColorIfMatch(current:requested:)`
  free function returning `nil` when `requested == current`, else
  `requested`. This change subsumes it into the new
  `resolveColorForBatch` and removes the primitive (and its 4 tests),
  since extending toggle-off to multi-selection collapses single- and
  multi-tab into one all-share check.
- `app/AppDelegate.swift:14-15` -- AppDelegate holds `var runtime: AppRuntime!`
  and `var sidebarView: SidebarView!`. Both are force-unwrapped IUOs assigned
  during setup (runtime at L40, sidebarView at L82). No additional threading
  is required to reach the sidebar from the dispatcher methods.
- `app/AppDelegate.swift:287-301` -- the Tab > Color submenu wires three
  color items with `keyEquivalent: "1"|"2"|"3"`, each with action
  `setTabColorFromMenu(_:)` and a `tag` matching its `TabColor.allCases`
  index, plus a "Clear Color" item with `keyEquivalent: "0"` and action
  `clearTabColor(_:)`. These are the only call sites for either selector
  in the menu definition.
- `app/AppDelegate.swift:426-434` -- buggy `setTabColorFromMenu` reads
  `runtime.model.selectedTabId` and dispatches `.setTabColors(tabIds: [tabId], ...)`.
- `app/AppDelegate.swift:436-439` -- buggy `clearTabColor` reads the same
  singular `selectedTabId`.
- `app/SidebarView.swift:191-192` -- outline view sets
  `allowsEmptySelection = false` and `allowsMultipleSelection = true`.
- `app/SidebarView.swift:480-484` -- `outlineView(_:shouldSelectItem:)` returns
  true only for `.tab` kinds. Group rows cannot be selected at all, so
  `outlineView.selectedRowIndexes` is steady-state guaranteed to contain
  only tab rows.
- `app/SidebarView.swift:910-921` (planning-time) -- `contextSetTabColors`
  had the single-vs-multi asymmetry inline: if `info.tabIds.count == 1`
  run `toggleColorIfMatch`; else use `info.color` directly. This change
  replaces that branch with a call to the new `resolveColorForBatch`,
  which generalizes the toggle-off rule to any selection size (so multi
  context-menu picks now also toggle off when every targeted tab
  already shares the requested color).
- `app/SidebarView.swift:717-727` and `:285-290` -- two existing call sites
  use the row-to-TabId pattern `outlineView.item(atRow: row) as? SidebarItem`
  + `case .tab(let tab) = item.kind`. The new helper mirrors this exactly.

## Chokepoint invariants

Two chokepoints, one for the action target and one for the policy:

1. **Action target**: the set of "tabs the user is acting on" comes from
   exactly one source: `SidebarView.outlineView.selectedRowIndexes`,
   mapped to TabIds via the existing row-to-tab pattern. This source is
   steady-state non-empty and tab-only (per the AppKit configuration
   cited above). Both the keyboard/menu dispatchers and the context-menu
   dispatcher consult this source; `model.selectedTabId` is the focus
   concept and is NOT the action target.

2. **Color-resolution policy**: the toggle-off rule (re-applying a
   color that every targeted tab already has clears them all;
   otherwise sets every tab to the requested color) lives in exactly
   one pure helper, `resolveColorForBatch(tabIds:requested:in:)` in
   `app/ModelOperations.swift`. Both dispatchers call it; neither
   reproduces the all-share check inline. The rule is uniform across
   selection sizes -- single-tab is a degenerate case of the multi-tab
   all-share rule. `Update.swift` stays oblivious and just applies the
   color to the given tabIds.

## Changes

### 1. `app/ModelOperations.swift` -- add `resolveColorForBatch`, remove `toggleColorIfMatch`

New free function that replaces the planning-time `toggleColorIfMatch`
(L989-L992). It encapsulates the entire toggle-off policy that
previously lived inline in `SidebarView.contextSetTabColors`:

```swift
// Resolves the TabColor to apply when a user-initiated color action
// targets `tabIds`. Single source of truth for the dispatcher's
// toggle-off policy, shared by AppDelegate (keyboard/menu) and
// SidebarView (right-click).
//
// Rule: re-applying a color that EVERY targeted tab already has clears
// them all (toggle-off). Otherwise, set every tab to `requested`. This
// unifies single- and multi-tab behavior:
//   - 1 tab matching requested      -> nil (clear)
//   - 1 tab differing from requested -> requested (set)
//   - N tabs all matching requested -> nil (clear all)
//   - N tabs mixed/none matching    -> requested (set all)
//
//   - count == 0:        returns nil (fail-closed; callers should guard).
//   - requested == nil:  returns nil (explicit clear path; no toggle).
//
// Tabs whose ids don't resolve in `model` count as not-matching, so a
// stale id never produces a spurious clear. Update.swift filters those
// ids out before applying.
func resolveColorForBatch(
    tabIds: [TabId],
    requested: TabColor?,
    in model: AppModel
) -> TabColor? {
    guard !tabIds.isEmpty else { return nil }
    guard let req = requested else { return nil }
    let allShareRequested = tabIds.allSatisfy { id in
        tabById(id, in: model)?.color == req
    }
    return allShareRequested ? nil : req
}
```

`toggleColorIfMatch` is removed: it had a single production caller
(`resolveColorForBatch`), and the unified all-share rule subsumes its
semantics. Its 4 tests are removed for the same reason; the new
`resolveColorForBatch` cases (see Decision #5) cover both the
single-tab and multi-tab branches behaviorally.

### 2. `app/SidebarView.swift` -- add `selectedTabIds()`

Public method on `SidebarView` returning `[TabId]` from
`outlineView.selectedRowIndexes`, using the same row-to-TabId pattern
already in `reload` (L285-L290) and `contextTargetTabIds` (L721-L726):

```swift
// Public: tabs currently multi-selected in the sidebar. Steady-state non-empty
// because allowsEmptySelection=false. The compactMap's `case .tab` guard is
// defensive: outlineView(_:shouldSelectItem:) already prevents group rows from
// entering the selection, so this filter mirrors the reload-snapshot pattern
// (SidebarView.swift L285-L290) for consistency rather than covering a real
// steady-state case.
func selectedTabIds() -> [TabId] {
    return outlineView.selectedRowIndexes.compactMap { row in
        guard let item = outlineView.item(atRow: row) as? SidebarItem,
              case .tab(let tab) = item.kind else { return nil }
        return tab.id
    }
}
```

### 3. `app/AppDelegate.swift` -- rewrite the two dispatchers

Replace `setTabColorFromMenu` (L426-L434) and `clearTabColor` (L436-L439).
Both read tab IDs through one private helper that prefers the sidebar's
real selection and falls back to `model.selectedTabId` only if the sidebar
is somehow unavailable (transient nil during teardown -- shouldn't occur
in steady state, but the fallback is cheap and matches the existing IUO
contract). The toggle-off policy goes through `resolveColorForBatch`;
this dispatcher contains no policy branches.

Approximate shape (planner refines during implementation):

```swift
@objc func setTabColorFromMenu(_ sender: NSMenuItem) {
    let colors = TabColor.allCases
    guard sender.tag >= 0, sender.tag < colors.count else { return }
    let tabIds = currentColorTargetTabIds()
    guard !tabIds.isEmpty else { return }
    let resolved = resolveColorForBatch(
        tabIds: tabIds, requested: colors[sender.tag], in: runtime.model)
    runtime.send(.setTabColors(tabIds: tabIds, color: resolved))
}

@objc func clearTabColor(_ sender: Any?) {
    let tabIds = currentColorTargetTabIds()
    guard !tabIds.isEmpty else { return }
    // Clear is unambiguous: never toggles, no policy decision needed.
    runtime.send(.setTabColors(tabIds: tabIds, color: nil))
}

// Action target for tab-color shortcuts. Prefers the sidebar's actual
// multi-selection; falls back to the focused tab if the sidebar isn't
// reachable (transient teardown only -- IUOs are set in
// applicationDidFinishLaunching before any menu can dispatch).
private func currentColorTargetTabIds() -> [TabId] {
    if let sidebar = sidebarView {
        let ids = sidebar.selectedTabIds()
        if !ids.isEmpty { return ids }
    }
    return runtime.model.selectedTabId.map { [$0] } ?? []
}
```

(`if let sidebar = sidebarView` directly optional-binds the IUO; no
cast needed.)

### 4. `app/SidebarView.swift` -- route `contextSetTabColors` through the helper

The planning-time `contextSetTabColors` (L910-L921) had the single-vs-multi
branch inline. Replace its body so the policy is sourced from
`resolveColorForBatch` instead:

```swift
@objc private func contextSetTabColors(_ sender: NSMenuItem) {
    guard let info = sender.representedObject as? SetTabColorsInfo,
          !info.tabIds.isEmpty,
          let model = runtime?.model else { return }
    let resolved = resolveColorForBatch(
        tabIds: info.tabIds, requested: info.color, in: model)
    runtime?.send(.setTabColors(tabIds: info.tabIds, color: resolved))
}
```

User-visible behavior change: a multi-tab right-click pick where every
selected tab already has the requested color now CLEARS them all
(previously the multi branch always set). This brings the context menu
into alignment with the unified all-share rule and matches the
keyboard/menu path -- consistency was the motivation for collapsing the
two branches.

### 5. No changes to `Msg.swift` or `Update.swift`. The plural Msg and
the validIds filter are already correct -- both stay oblivious to the
toggle-off policy.

## Decisions on the open questions

1. **AppDelegate -> SidebarView reference**: already exists
   (`AppDelegate.swift:15`). No new wiring.

2. **Other call sites for `clearTabColor`**: only the menu wiring at
   `AppDelegate.swift:301`. No other `#selector(clearTabColor` references
   surfaced in the audit. Same for `setTabColorFromMenu` -- only L295.
   The change is contained to those two dispatchers.

3. **Helper extraction (`resolveColorForBatch`)**: ACCEPT. Without it,
   the toggle-off policy lives inline in two view-layer dispatchers
   (`AppDelegate.setTabColorFromMenu` and
   `SidebarView.contextSetTabColors`), neither of which is in
   `test.sh`'s compiled subset. The behavioral rule that decides whether
   cmd-1 on an already-red tab clears or stays red would have zero
   automated coverage. Extracting it into `ModelOperations.swift`:
   - puts both call sites on the same code path (one source of truth
     for the policy; the all-share check lives in exactly one place);
   - makes the rule a pure function over `(tabIds, requested, model)`,
     which IS in the compiled test subset, so the new
     `ModelOperationsTests` cases give the policy genuine behavioral
     regression coverage;
   - shrinks the dispatchers to a single call each.

   The "two call sites is below the abstraction threshold" heuristic
   loses to the test-coverage argument here: the toggle-off rule is
   the entire point of this change and should be tested.

4. **`selectedTabIds()` edge cases**:
   - **Group rows**: cannot enter the selection at all
     (`SidebarView.swift:480-484`). The defensive `compactMap` guard is
     redundant but matches `reload`'s snapshot pattern verbatim, so keep
     it -- pattern parity beats one-line savings, and the compiler
     elides nothing here.
   - **Empty selection**: cannot occur in steady state
     (`allowsEmptySelection = false`, `SidebarView.swift:191`). May
     transiently occur during reloads. The `currentColorTargetTabIds`
     fallback to `model.selectedTabId` covers this. If even that is
     nil, the dispatcher returns silently.
   - **Sidebar nil**: AppDelegate's IUO is assigned in
     `applicationDidFinishLaunching` (L82) before any menu dispatch is
     possible. The optional-binding fallback is belt-and-braces.

5. **Tests**: add behavioral coverage for `resolveColorForBatch` in
   `tests/ModelOperationsTests.swift` and remove the four
   `toggleColorIfMatch` tests (the primitive is gone).
   `ModelOperations.swift` is in `test.sh`'s compiled subset, so this
   is the right home. Required cases (one assert each):
   - **empty batch returns nil**: `resolveColorForBatch(tabIds:[], requested:.red, in: model)` ==
     `nil`. Locks in the empty-batch contract so the helper fails
     closed if a future caller forgets the empty-guard.
   - **single, same color clears**: model has one tab with `.red`,
     `resolveColorForBatch(tabIds:[t], requested:.red, in: model)` ==
     `nil`. Locks in the toggle-off semantic.
   - **single, different color sets**: model has one tab with `.red`,
     called with `requested:.orange` -> `.orange`.
   - **single, uncolored sets**: model has one tab with no color
     (`color == nil`), called with `requested:.red` -> `.red`. Covers
     the "first-time apply" path.
   - **multi, all share requested clears**: model has two tabs both
     `.red`, called with `requested:.red` -> `nil`. Locks in the
     extension of toggle-off to multi-selection.
   - **multi, all uncolored sets requested**: two tabs with `color == nil`,
     called with `requested:.red` -> `.red`. Covers the nil-color
     branch of the all-share check (uncolored tabs do not "share" a
     non-nil requested color).
   - **multi, mixed colors set requested**: model has tabs `.red` and
     `.orange`, called with `requested:.red` -> `.red`.
   - **explicit nil (clear) on single colored**: tab is `.red`, called
     with `requested: nil` -> `nil`.
   - **explicit nil (clear) on multi**: two `.red` tabs, called with
     `requested: nil` -> `nil`.

   Out of scope for tests:
   - `selectedTabIds()`: thin AppKit-bound wrapper over
     `outlineView.selectedRowIndexes`. View-coupled, not in the
     compiled test subset (which is `Model.swift`,
     `ModelOperations.swift`, `Msg.swift`, `Effect.swift`,
     `Update.swift`, plus a few utilities). Verified manually.
   - `currentColorTargetTabIds` in `AppDelegate.swift`: also outside
     the compiled subset. The primary sidebar-selection branch is
     exercised by every multi-tab manual case. The
     `model.selectedTabId` fallback fires only on transient sidebar
     unavailability and is genuinely untested -- acknowledged, not
     worth the harness needed to test it.
   - `Update.swift` `.setTabColors` handler tests already exist and
     are unchanged.

## Files modified

- `app/ModelOperations.swift` -- add `resolveColorForBatch(tabIds:requested:in:)`
  free function; remove `toggleColorIfMatch` (subsumed).
- `app/SidebarView.swift` -- add `selectedTabIds()` method; refactor
  `contextSetTabColors` (planning-time L910-L921) to call
  `resolveColorForBatch`. The refactor extends toggle-off to
  multi-tab right-clicks (a deliberate, user-visible behavior change
  that brings the context menu into alignment with the unified rule).
- `app/AppDelegate.swift` -- rewrite `setTabColorFromMenu` (L426-L434)
  and `clearTabColor` (L436-L439) to read tabs from the sidebar
  selection; add private `currentColorTargetTabIds()` helper. Color
  policy delegates to `resolveColorForBatch`.
- `tests/ModelOperationsTests.swift` -- add the 9
  `resolveColorForBatch` cases enumerated above; remove the 4
  `toggleColorIfMatch` cases (primitive gone).
- `app/Update.swift` and `tests/UpdateTabTests.swift` -- comment-only
  updates: references to `toggleColorIfMatch` retargeted to
  `resolveColorForBatch`. No code changes.

## Out of scope (per the task brief)

- Multi-window support (`runtime.model.selectedTabId` is per-app).
- Other shortcuts that read `model.selectedTabId` (cmd-w close, etc.) --
  separate decision per-shortcut.
- Sidebar selection-model changes (drag/drop, multi-select gestures,
  `selectedRowIndexes` reconciliation).
- Visual menu state (enabled/disabled, color swatches, checkmarks
  reflecting current selection).

## Verification

Build: `just build` (compile-check) then `just build-run` to launch.

Manual checklist (run in the dev app):

1. **Single-tab toggle-off preserved**: select one uncolored tab,
   cmd-1 -> turns red. cmd-1 again -> clears. cmd-2 on red -> turns
   orange. cmd-0 on orange -> clears.
2. **Multi-tab cmd-1 sets a mixed selection**: cmd-click to
   multi-select 3 tabs (mix of colored and uncolored). cmd-1 -> all
   three become red. Re-applying when not all share the requested
   color always sets, never clears.
3. **Multi-tab cmd-1 toggle-off**: with the now-all-red selection
   from step 2, cmd-1 -> all three clear. This is the "all share
   requested color clears" rule.
4. **Multi-tab cmd-0 clears all**: select 3 colored tabs, cmd-0 ->
   all three colors clear (no toggle on explicit clear).
5. **Multi-tab from Tab > Color menu**: same as cmd shortcut, via
   menu click. (Same selector path.)
6. **Right-click context menu mirrors keyboard path**: right-click
   multi-selection, choose Red -> all colored red. Right-click again
   on the same all-red selection, Red -> all clear. Right-click a
   single tab, Red -> red; same tab, Red -> clears. Both paths now
   share the same all-share rule.
7. **Group rows do not appear in `selectedTabIds()`**: switch to
   multi-group mode, cmd-click to attempt to multi-select a group row
   -- AppKit refuses (per L480-L484). cmd-1 colors only the tabs in
   the existing tab-row selection.

`just test` runs the new `resolveColorForBatch` cases plus the existing
suite. The new cases lock in the all-share toggle-off semantics
behaviorally; the manual checklist above verifies the view-coupled glue
(`selectedTabIds`, the steady-state branch of
`currentColorTargetTabIds`, menu selectors).
