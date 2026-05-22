# Batch-close multi-selected tabs from the sidebar context menu

## Context

Right-clicking a multi-tab selection in the sidebar shows "Close (N tabs)",
but the action does not uniformly close all N tabs when the batch contains
any tab that would need confirmation (multi-pane or uncompleted todos).

Root cause: `contextCloseTabs` (`app/SidebarView.swift:975-980`) loops the
selection and sends one `.requestCloseTab(id:)` per tab. The per-tab handler
(`app/Update.swift:121-135`) branches on whether the tab needs confirmation:

- Simple tabs (single pane, no uncompleted todos) dispatch straight to
  `.closeTab` and are removed in-loop -- there is no pending-confirmation
  guard on `.closeTab` itself.
- Tabs that need confirmation call `emitCloseTabConfirmation`, which guards
  the single-slot `model.pendingConfirmation` (`app/Model.swift:170-175`,
  `app/ModelOperations.swift:437`). The first such call sets the slot and
  emits one sheet; every subsequent call from the same loop trips the guard
  and returns `[]` -- silently dropped, no UI, no error.

Net effect: a 9-tab batch where every tab is multi-pane drops 8 of 9 (only
the first tab's sheet shows, and confirming it closes only that one). A
mixed batch where most tabs are simple closes the simple ones immediately
and silently drops every confirmation-needed tab after the first. Either
way, the user's intent ("close these N tabs") is partially executed without
feedback.

Every other multi-select context-menu action (Clear Custom Title, Color,
Clear Alerts, Move to New Group) already uses a single batch Msg that takes
`tabIds: [TabId]`. Close is the only loop-and-dispatch holdout.

Outcome: "Close (N tabs)" closes all N tabs after a single consolidated
confirmation sheet, matching the pattern the other batch actions already
follow.

## Decisions (from clarification)

- **Always confirm when N > 1.** Even when every selected tab is single-pane
  with no uncompleted todos, batch close shows one consolidated dialog. Hard
  to fat-finger, consistent UX.
- **N == 1 delegates to existing `.requestCloseTab`.** Preserves the current
  `Close tab "name"?` wording and per-tab rollup copy.

## Approach

Add a single batch Msg pipeline mirroring the existing single-tab one, with
one consolidated confirmation sheet instead of N stacked ones.

### New Msgs (`app/Msg.swift`)

- `case requestCloseTabs(ids: [TabId])` -- batch entry point.
- `case confirmCloseTabs(ids: [TabId])` -- user clicked Close in the sheet.
- `case cancelCloseTabs` -- user clicked Cancel in the sheet.

### New Effect (`app/Effect.swift`)

- `case showCloseTabsConfirmation(tabIds: [TabId], tabCount: Int, totalPaneCount: Int, totalUncompletedTodos: Int, isQuit: Bool)`

`isQuit` is true when closing the whole batch would empty the app, so the
copy can reflect "and quit DanTerm".

### Update handler (`app/Update.swift`)

`case .requestCloseTabs(let ids)`:
1. Normalize: filter to live tab ids and deduplicate to first occurrence,
   preserving order. Mirror the seen-set pattern used by the existing batch
   handlers (`app/Update.swift:465-470`, `:481-486`, `:502-507`,
   `:1066`-style) so `tabCount`, rollups, and `isQuit` are not inflated by
   duplicates.
2. If the normalized list is empty -> return `[]`.
3. If it has exactly one id -> `return update(&model, .requestCloseTab(id: normalized[0]))`
   (delegate using the *normalized* id, not the original `ids[0]`, so a
   stale-then-live input like `[stale, live]` still delegates to the live id
   instead of no-opping on the stale one).
4. Otherwise call new `emitCloseTabsConfirmation(&model, ids: normalized)`
   which guards the same `pendingConfirmation` slot and emits the single
   sheet effect. Roll up pane count and uncompleted todo counts across the
   batch using existing `allPaneIds` and `tabTodoRollup` helpers
   (`app/ModelOperations.swift:450`).

`case .confirmCloseTabs(let ids)`:
1. Clear `model.pendingConfirmation = nil`.
2. Apply the same live-and-dedupe normalization as `requestCloseTabs` (the
   ids round-tripped through the sheet, but a tab could have been closed by
   another path while the sheet was up, and we still want defense-in-depth
   against duplicates).
3. Iterate normalized ids and call `closeTabBody` for each, accumulating
   effects.
4. **Then branch on remaining tab count, mirroring the existing `.closeTab`
   tail (`app/Update.swift:182-195`):**
   - If `model.groups.flatMap(\.tabs).isEmpty` -> `return effects + [.terminate]`.
     Do **not** append `.reloadSidebar` or `.scheduleCheckpoint` after
     `.terminate`: `AppRuntime.perform` runs effects in order, and the
     `.terminate` arm (`app/AppRuntime.swift:596-605`) cancels both
     checkpoint timers and calls `NSApp.terminate(nil)` synchronously;
     a `.scheduleCheckpoint` after that would re-arm persistence during
     shutdown and run UI work after termination has started.
   - Otherwise append `.reloadSidebar` and `.scheduleCheckpoint` exactly
     once, then return `effects`.

`case .cancelCloseTabs`:
1. Clear `model.pendingConfirmation = nil`.
2. Return `[]`.

To avoid `.closeTab` re-prompting on the last tab during batch confirm (its
`wouldQuitFromClose` guard at `app/Update.swift:140-141` would emit a second
terminate confirmation after the user already confirmed batch close),
extract the **core removal** of `case .closeTab` into a private helper:

```swift
// Core per-tab removal: destroy surfaces, clear pane/search/alert/popover
// state, remove the tab (and empty group), and emit any selection
// rebuild/sync effects when the closed tab was selected.
//
// Does NOT emit .reloadSidebar, .scheduleCheckpoint, or .terminate, and
// does NOT check wouldQuitFromClose. The caller composes the final tail
// (terminate-if-empty vs reload+checkpoint) so the batch path can fold
// those across N closures.
private func closeTabBody(_ model: inout AppModel, id: TabId) -> [Effect]
```

The helper covers the core removal of the current `.closeTab` body
(lines 144-180 plus 187-192): the `destroySurface` loop with its
pane/alert/search/popover cleanup, the tab-popover dismiss check, the
`model.groups[groupIdx].tabs.remove(at:)` + `removeGroupIfEmpty`
mutation, fallback-selection computation, and the
`rebuildContentView` + `selectionSyncEffects` emitted when the closed tab
was the selected one. **Explicitly excluded from the helper** (stays in
`.closeTab`'s tail, where the existing single-tab contract owns them):
the empty-app `effects + [.terminate]` short-circuit at lines 182-185,
and the trailing `.reloadSidebar` / `.scheduleCheckpoint` at lines 193-195.

`case .closeTab(let id)` then becomes: guard `tabLocation`, do the existing
`wouldQuitFromClose` check, otherwise call `closeTabBody`, then run the
existing tail logic (empty-app `effects + [.terminate]` short-circuit, else
append `.reloadSidebar` + `.scheduleCheckpoint`). **Only the new batch
`.confirmCloseTabs` calls `closeTabBody` directly.** Single-tab
`.confirmCloseTab` (`app/Update.swift:994-996`) keeps dispatching `.closeTab`
unchanged, preserving the existing "confirmed last multi-pane tab close
routes to terminate confirmation" contract that
`testConfirmCloseTabLastMultiPaneRoutesToTerminate`
(`tests/UpdateTabTests.swift:515`) locks in.

### New helpers (`app/ModelOperations.swift`)

Mirror the existing per-tab versions:

- `emitCloseTabsConfirmation(&model, ids: [TabId]) -> [Effect]` --
  guards `pendingConfirmation`, sets `.closeTab`, rolls up pane and
  uncompleted-todo counts, computes `isQuit = ids.count == totalTabCount(model)`,
  emits the single `.showCloseTabsConfirmation` effect.
- `closeTabsConfirmationCopy(tabCount, totalPaneCount, totalUncompletedTodos, isQuit) -> String` --
  builds the `informativeText`. Mirrors `closeTabConfirmationCopy`
  (`app/AppRuntime.swift:1512`).
- `closeTabsConfirmationResponse(isConfirm: Bool, ids: [TabId]) -> Msg` --
  mirrors `closeTabConfirmationResponse` (`app/ModelOperations.swift:717`).

### AppKit sheet (`app/AppRuntime.swift`)

Add a `.showCloseTabsConfirmation` arm next to the existing
`.showCloseTabConfirmation` arm (currently at line 528). Build an `NSAlert`
with `"Close \(tabCount) tabs?"` (or "and quit DanTerm" when `isQuit`),
informative text from `closeTabsConfirmationCopy`, buttons
`"Close \(tabCount) Tabs"` and `"Cancel"`. On dismiss, send
`closeTabsConfirmationResponse(isConfirm:, ids:)`.

### Sidebar dispatch (`app/SidebarView.swift:975-980`)

Replace the per-id loop with a single send:

```swift
@objc private func contextCloseTabs(_ sender: NSMenuItem) {
    guard let box = sender.representedObject as? TabIdsBox else { return }
    runtime?.send(.requestCloseTabs(ids: box.ids))
}
```

## Files to modify

- `app/Msg.swift` -- add 3 cases.
- `app/Effect.swift` -- add `.showCloseTabsConfirmation`.
- `app/Update.swift` -- 3 new cases; extract `closeTabBody` from existing
  `.closeTab` case (~line 137). `.confirmCloseTab` (line 994) is left as-is
  -- only the new `.confirmCloseTabs` calls `closeTabBody` directly.
- `app/ModelOperations.swift` -- add `emitCloseTabsConfirmation`,
  `closeTabsConfirmationCopy`, `closeTabsConfirmationResponse`.
- `app/AppRuntime.swift` -- add `.showCloseTabsConfirmation` Effect arm.
- `app/SidebarView.swift` -- replace per-id loop with single `.requestCloseTabs`
  send; update the doc comment above (the "Closing N tabs dispatches N
  .requestCloseTab calls..." line is no longer accurate).
- `tests/UpdateTabTests.swift` -- add the test cases listed below.

## Tests

Add to `tests/UpdateTabTests.swift` alongside the existing
`MARK: - requestCloseTab` block. All behavioral (assert model state and
which effects emit), no structure assertions.

- `requestCloseTabs` with a *mixed* N > 1 batch (some single-pane no-todo,
  some multi-pane, some with uncompleted todos) emits exactly one
  `.showCloseTabsConfirmation` whose `tabIds` matches the normalized input
  and whose `tabCount` equals the normalized count; sets
  `pendingConfirmation = .closeTab`; removes **no** tabs yet (this is the
  key contract change vs. today, where simple tabs in a mixed batch were
  closed in-loop before the sheet appeared).
- `requestCloseTabs` with N > 1 rolls up pane count and uncompleted todos
  across the batch (use a mix of single-pane, multi-pane, tab-todo, and
  pane-todo fixtures).
- `requestCloseTabs` with N > 1 sets `isQuit = true` on the effect when
  the ids cover every live tab.
- `requestCloseTabs` with a single id delegates: behavior is identical to
  sending `.requestCloseTab(id:)` directly (same effects, same model
  mutation).
- `requestCloseTabs` with empty ids returns `[]`.
- `requestCloseTabs` filters stale ids and proceeds with the live remainder
  -- explicitly assert with `[stale, live]` (stale first) that the handler
  delegates to or operates on the live id, not the stale `ids[0]`. This
  pins down the "delegate via `normalized[0]`" contract from the update
  handler step 3.
- `requestCloseTabs` deduplicates: passing `[t1, t2, t1, t2]` produces the
  same effect/sheet as `[t1, t2]` -- `tabCount == 2`, rollups counted once
  per tab, `isQuit` reflects unique-id coverage.
- `requestCloseTabs` with a normalized N > 1 batch is a no-op when
  `pendingConfirmation` is already set: `emitCloseTabsConfirmation` trips
  the same single-slot guard that `emitCloseTabConfirmation` uses
  (`app/ModelOperations.swift:437`), so no effects emit and no tabs close.
  Scope: this assertion is **N > 1 only**. Normalized singleton inputs
  delegate to `.requestCloseTab`, which has its own per-tab branch -- a
  simple non-last tab can still close while a confirmation is pending,
  because `.requestCloseTab` only consults `pendingConfirmation` for tabs
  that would themselves need confirmation (`app/Update.swift:121-135`).
  That singleton behavior is the explicit delegation contract from step 3
  and is covered by the single-id delegation test above.
- `confirmCloseTabs` removes every tab in the id list, emits
  `destroySurface` for every pane in those tabs, and clears
  `pendingConfirmation`.
- `confirmCloseTabs` emptying-batch tail: when the batch closes every
  remaining tab, the effects end with exactly one `.terminate` and contain
  **no** `.reloadSidebar` and **no** `.scheduleCheckpoint` (the
  ordering invariant against re-arming persistence during shutdown, per
  `app/AppRuntime.swift:596-605`).
- `confirmCloseTabs` with a non-emptying batch emits exactly one
  `.reloadSidebar` and exactly one `.scheduleCheckpoint`, no `.terminate`,
  and updates `selectedTabId` to a remaining tab when the selection was
  inside the batch.
- `cancelCloseTabs` clears `pendingConfirmation` and removes nothing.

Refactor sanity: existing single-tab tests
(`testRequestCloseTabSinglePaneClosesDirectly`,
`testRequestCloseTabMultiPaneShowsConfirmation`, the two pending-guard
tests, `testConfirmCloseTabClearsPendingAndDispatches`, and crucially
`testConfirmCloseTabLastMultiPaneRoutesToTerminate` at
`tests/UpdateTabTests.swift:515`) must still pass after extracting
`closeTabBody`. The single-tab `.confirmCloseTab` path is intentionally
left dispatching `.closeTab` so the last-tab terminate re-prompt contract
is preserved. No structural assertions on the helper itself; the existing
tests are the behavioral contract.

## Verification

- `just test` -- pure unit tests pass.
- `just build-run` -- manual smoke:
  1. Open 9 tabs, all single-pane no-todo. Multi-select 9 in sidebar,
     right-click, "Close (9 tabs)". Expect one dialog ("Close 9 tabs and
     quit DanTerm?" since this empties the app), confirm, all 9 close
     and app quits.
  2. Open 9 tabs, give the first one a horizontal split (two panes) and
     add a pane-todo to the third. Multi-select 9, right-click, "Close (9
     tabs)". Expect one dialog with rollup text mentioning the panes and
     todos, confirm, all 9 close.
  3. Cancel the dialog in scenario 2; expect zero tabs closed and
     `pendingConfirmation` cleared (visible via being able to immediately
     reopen the menu and try again).
  4. Right-click a single tab (not part of any multi-select) -> "Close"
     (no suffix). Expect the existing per-tab dialog wording unchanged.
