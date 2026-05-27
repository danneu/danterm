# Plan: Reconcile Open TODO Popovers

## Summary

Add projection-driven reconciler paths for pane TODO and tab TODO popovers,
following the alerts popover pattern from `d797b50` but preserving TODO-specific
view-local state: compose draft, edit draft, selected row, first responder,
shortcut-help child popover, and post-reorder selection.

The root fix is to stop the popover tables from reading `runtime.model` directly
for rendering. `ModelOperations.swift` will expose pure model projections;
`Reconcile.swift` will push those projections into open popovers after every
`send()`; the view controllers will apply projections without overwriting local
editing/focus state.

No simpler pivot is recommended. A global "call rebuildRows on every send" hook
would be smaller, but it keeps view reads coupled to `runtime.model`, bypasses
the read-only reconciler direction, and is easier to regress. The robust version
is projection-per-popover with shared TODO state helpers.

## Key Changes

- Add pure projections in `app/ModelOperations.swift`:
  - `PaneTodoPopoverProjection: Equatable`
    - `paneId: PaneId`
    - `rows: [TodoItem]`
    - `hasCompleted: Bool`
  - `desiredPaneTodoPopover(paneId:in:) -> PaneTodoPopoverProjection?`
    - returns nil if the pane no longer exists.
  - `TabTodoPopoverProjection: Equatable`
    - `tabId: TabId`
    - `rows: [TabTodoRow]`
    - `paneOrder: [PaneId]`
    - `tabHasCompleted: Bool`
  - `desiredTabTodoPopover(tabId:in:) -> TabTodoPopoverProjection?`
    - reuses `buildTabTodoRows`, includes pane order for keyboard cross-bucket
      movement, and keeps "Clear completed" scoped to tab-owned todos only.

- Add pure state-preservation helpers:
  - Extend `TodoPopoverState` with a retargeting rebuild helper, e.g.
    `reconcileEditTarget(resolve:)`, so edit mode can either keep the same
    target, retarget it, or fall back to list mode.
  - Add `resolveTabTodoEditTarget(_:in:)` in `ModelOperations.swift`, scoped to
    the current `TabTodoPopoverProjection` or its `rows`: prefer the exact
    `TabTodoEditTarget`, then fall back to the same `todoId` only by scanning the
    open tab's projected rows. Do not scan `AppModel`; `TabTodoEditTarget.tab`
    carries only a todo UUID, while the controller's `tabId` is external, so a
    model-wide resolver can incorrectly match another tab.
  - Add `newlyAddedTabTodoTarget(previousTabTodoIds:in:)` in
    `ModelOperations.swift`: from an updated `TabTodoPopoverProjection`, return
    the first `.tab(todoId:)` whose id was not in the captured pre-add tab-id set.
  - Keep pane selection keyed by `UUID`; keep tab selection keyed by
    `TabTodoEditTarget` but allow cross-bucket retargeting by todo id.

- Add caches and reconcile passes in `app/Reconcile.swift`:
  - `ReconcilerCaches.paneTodoPopover: PaneTodoPopoverProjection?`
  - `ReconcilerCaches.tabTodoPopover: TabTodoPopoverProjection?`
  - `reconcilePaneTodoPopover()`
    - projects only when `todoPopover?.isShown == true` and
      `model.todoPopover == .pane(paneId)`.
    - applies to `TodoPopoverViewController`.
    - clears cache to nil when closed, hidden, or model scope no longer matches.
  - `reconcileTabTodoPopover()`
    - same shape, gated by `tabTodoPopover?.isShown == true` and
      `model.todoPopover == .tab(tabId)`.
  - Wire both late in `reconcile()`, after `reconcileAlertsPopover()` and before
    `reconcileThemeBrowser()` / `syncSurfaceVisibility()`.

- Refactor `app/TodoPopoverView.swift`:
  - Store `private var projection = PaneTodoPopoverProjection(...)`.
  - Replace `todos` computed reads from `runtime.model` with `projection.rows`.
  - Replace `rebuildRows(...)` with `apply(_:)`.
  - `apply(_:)` must capture compose text before syncing, preserve edit draft if
    still editing the same todo, reload rows from projection, restore selection
    by id, and fall back to nearest row only when the selected/edit item
    disappeared.
  - Existing actions should `send(...)` and then repair selection/focus against
    the already-applied projection; remove post-send model-reading rebuilds.

- Refactor `app/TabTodoPopoverView.swift`:
  - Store `private var projection = TabTodoPopoverProjection(...)`; table rows
    come only from `projection.rows`.
  - `apply(_:)` preserves compose draft, edit draft, selected target, first
    responder, and retargets selection/edit when a todo moves across tab/pane
    buckets.
  - Use `projection.paneOrder` and row counts derived from `projection.rows` for
    keyboard reorder and adjacent-bucket movement.
  - Preserve current post-add selection behavior without reading the model:
    before `send(.addTabTodo)`, capture tab item ids from `projection.rows`; after
    `send` returns and synchronous reconcile has applied the updated projection,
    select `newlyAddedTabTodoTarget(previousTabTodoIds:in:)` so Tab from compose
    still lands on the newly appended tab item.
  - Keep active drag payload/drop handling AppKit-local; after drop, `send(...)`
    triggers reconcile, then selection is restored to the moved todo's new target.

- Update first-show wiring in `app/AppRuntime.swift`:
  - For `.showTodoPopover` and `.showTodoPopoverForTab`, call
    `vc.loadViewIfNeeded()` and `vc.apply(desired...!)` before `popover.show(...)`.
  - Do not seed reconciler caches from command handling; the reconcile pass owns
    cache updates.
  - Keep existing delegate model-close messages.

## Tests

- Add red-first projection tests in `tests/ModelOperationsTests.swift`:
  - Pane projection returns rows, pane id, and completed visibility.
  - Pane projection returns nil for missing pane.
  - Tab projection includes tab rows, pane section rows, pane order, and tab-only
    completed visibility.
  - Tab projection changes when a pane todo, tab todo, or pane title changes while
    the popover would remain open.
  - Cross-bucket resolver maps `.tab(todoId)` to `.pane(paneId,todoId)` and vice
    versa when the item moved.
  - Scoped resolver regression: if the same todo id exists in another tab outside
    the open tab's projection, retargeting must return nil rather than preserving
    edit mode against that other tab.
  - Post-add selection helper returns the newly appended tab item by comparing a
    pre-add id set with the updated projection rows, with no model read.

- Add pure state tests in `tests/TodoPopoverStateTests.swift`:
  - Retargeting edit mode preserves compose draft.
  - Missing edit target exits edit mode and preserves compose draft.
  - Tab TODO retarget keeps edit mode across cross-bucket movement.
  - Rejected save still preserves compose draft and edit mode.

- Existing update tests remain the source of truth for open/close model scope and
  dismiss commands; do not add AppKit-specific unit tests.

- Verification commands:
  - `just test`
  - `just build`

## Manual QA

- Pane popover: open with existing tasks, add/toggle/delete/reorder tasks from
  another path while open; rows update without losing compose text or current
  selection.
- Pane edit mode: start editing a task, mutate other todos externally; edit field
  text and focus remain. Delete the edited task externally; popover exits edit
  mode and selects nearest row or compose.
- Tab popover: open with tab and pane sections, mutate tab todos and pane todos
  externally; section rows update live.
- Tab cross-bucket: move selected or edited item between tab and pane buckets;
  selection/edit target follows the same todo id.
- Drag/drop: reorder within a pane, within tab todos, and across tab/pane
  buckets; moved row remains selected after reconcile.
- First-show: open each TODO popover with preexisting rows and no later `send()`;
  rows render immediately.
- Click-away/programmatic close: cache clears on the next reconcile, reopen shows
  current rows.

## Risks And Out Of Scope

- Do not move compose text, edit text, selected row, first responder, or
  shortcut-help popover into `AppModel`.
- Do not attempt to preserve an active mouse drag if an unrelated background
  update reloads rows mid-drag; AppKit owns that transient drag session.
- Do not change TODO open/close command semantics or `model.todoPopover`
  ownership.
- Do not refactor the two popover controllers into a shared base class in this
  change; share only small pure helpers where they reduce risk.
