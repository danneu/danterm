# The sidebar cell paints its projection

## Problem

The sidebar has two independent derivations from model to pixels. `desiredSidebar`
projects each row and `computeSidebarRowOps` decides *when* a row reloads; then
`configureTabCell` / `configureGroupCell` decide *what* to draw by re-deriving
from a `TabModel`/`GroupModel` plus a live `currentModel` read. Every field the
cells draw is already in `SidebarTabProjection` / `SidebarGroupProjection` --
the projection's own doc comment says it holds "everything `configureTabCell`
draws" -- so the second derivation buys nothing and can disagree with the first.

Two consequences, both real:

- **Drift.** The cell reads `currentModel`, which can be newer than the ops
  applied to that row. When the rename guard suppresses a row's reload,
  `advanceSidebarCache` retains the old projection so the reload re-fires later
  -- but the cell may already have painted the newer model, which makes the
  retry a no-op that looks correct by accident.
- **Cost.** Each cell rescans the whole alert list, twice for a tab row
  (`tabPaneChips(_:alerts:)` and `unreadAlertCount(for:alerts:)`) and once for a
  group row (`groupUnreadAlertCount(for:alerts:)`). Measured release, per
  reconcile sweep: 2.23ms for 20 rows at 1000 unread alerts, 16.4ms for 60 rows
  at 2000. Linear in alert count, per row, while the projection that already
  holds these counts gets them from one `UnreadAlertTally` per sweep.

## Decision

`SidebarItem.Kind` carries `SidebarTabProjection` / `SidebarGroupProjection`
instead of `TabModel` / `GroupModel`. The backing store, the row-op executor,
and both cell configurators then read only the projection. Nothing new is
stored: the item already is the per-row payload slot, so the cell keeps its O(1)
access and the change is a payload type swap.

The dividing rule, which the layering should make visible: **the render path
reads the projection; the interaction path -- context menus, drag and drop,
selection -- reads the model.** `applySidebarOps` keeps its model argument to
serve the second and stays the sole writer of `currentModel`; both arguments
come from one reconcile instant, so they cannot disagree.

Scope covers group rows as well as tab rows. Splitting it would leave `Kind`
holding a projection on one side and a model on the other, and would leave the
group row's alert rescan in place.

`SidebarItemStore` also stops taking `isSingleGroupMode` alongside the model,
because the projection already carries that fact.

## Invariants

- **I1.** A cell's contents are a function of the projection whose row op was
  applied to it, never of a model read at draw time.
- **I2.** A row op suppressed by the rename guard leaves the row showing its
  previous projection, and the retained cache makes the reload re-fire later.
- **I3.** No rendering path consults an alert list. Alert counts and pane-chip
  states reach a cell only through the projection.
- **I4.** Row identity and cache invariants under granular ops are unchanged:
  every displayed row stays pointer-identical to its cached item, and removed
  rows are evicted.
- **I5.** Single-group mode is one fact with one source.

## Proof obligations

- **PO1** (I1, I3): drive the real deferred-reload sequence -- suppress a tab's
  reload during an inline rename, advance the model, then end the rename so the
  cell is configured again from its retained item. The title, badge, and
  pane-strip must all still show the old projection; a further reconcile must
  then converge them to the new one. The test has to force a reconfigure after
  the model moves, or it passes today for the wrong reason: the cell was simply
  never repainted.
- **PO2** (I2): the existing deferred-reload coverage in
  `tests-ui/SidebarSelectionCacheTests.swift` (visible/off-screen nil-cell badge
  reload retention) and the rename suites in
  `tests-ui/SidebarRenameRecycleTests.swift`, carried across the conversion.
- **PO3** (I4, I5): `lib/DanTermCore/Tests/DanTermCoreTests/SidebarItemStoreTests.swift`,
  converted to drive the store with projections. Its helpers already build a
  projection and pass `isSingleGroupMode` from it, so the conversion is a
  deletion.
- **PO4** (I1, I3): a new UI test drives a group row through projection-derived
  row ops that change its collapse state, unread count, and tab count, and
  asserts the caret direction and both badges in the collapsed and expanded
  states. Nothing covers this today: the group assertions in
  `tests-ui/SidebarRenameRecycleTests.swift` are geometry only (caret button
  inset, text-field width), and `tests-ui/SidebarBadgeTests.swift` only exercises
  the `visibleAlertBadge` helper.

## Critical files

- `lib/DanTermCore/Sources/DanTermCore/SidebarItemStore.swift` -- `SidebarItem.Kind`
  payload and every `apply`/`update*` entry point.
- `app/SidebarView.swift` -- the row-op executor, both cell configurators,
  `applyGroupCollapseState`, and the ~25 `case .tab(let tab)` / `.group(let group)`
  sites, nearly all of which already use nothing but the id.
- `app/Reconcile.swift` -- `reconcileSidebar` already computes the projection it
  passes to `computeSidebarRowOps`; it hands the same value to the executor.
- `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift` -- delete
  `tabPaneChips(_:alerts:)`, whose only caller was the cell.

`tabForBadgeHit` and `contextMenu(forTab:clickedRow:)` are the only two places
that take a whole `TabModel`; both use nothing but `tab.id`, and the menu already
re-looks-up live models from `currentModel`.

## Non-goals

- Selection stays view-owned and stays out of the projection.
- The context menu's own alert scan stays. It runs once on a click over the live
  model, and it is not a render path.
- No change to what the sidebar shows.

## Accepted risks

- The payload swap touches many sites in `SidebarView.swift`. All are
  compiler-caught, and the only behavior that can change is where a stale
  payload was previously masked by a `currentModel` read -- which is the drift
  being removed, so a resulting test failure is information, not noise.
- `groupUnreadAlertCount(for:alerts:)` loses its last production caller and
  survives as the reference implementation `unreadAlertTally` is checked
  against. Its doc comment says so, rather than leaving it looking live.

## Rejected ideas

- **Items carry only ids, with the view looking up a stored projection.** The
  item's payload is the row's *last applied* state, which is exactly what makes
  a suppressed reload meaningful; a lookup returns the newest projection and
  reintroduces the drift this change removes.
- **Putting `selectedTabId` in the projection** so the executor needs no model.
  Selection is view-owned by design, and the projection's exclusion of it is
  what keeps a focus change from being a row diff.

## Implementation discretion

- Whether the live tab-id set for selection restore keeps coming from the model
  or is derived from the projection.
- The shape and placement of the by-id projection lookup the store needs.

## Commit progress

- [x] Single commit. The payload type change does not compile in halves: the
      store's callers and the cells move with it. Green `just test`,
      `just test-ui`, and `icon/render-check.sh` before committing.

## Verification

- `just test` and `just test-ui`; `icon/render-check.sh` for the unchanged chip
  artwork.
- Live in a dev slot (`just launch-slot`, drive with an explicit
  `danterm --socket`): a tab holding both an unread bell and an agent pane shows
  the same badge and dots as before; rename a tab while an agent flips between
  working and idle, which exercises the suppressed-reload path.

## Implementation notes

- **Implementation discretion, resolved.** The live tab-id set for selection
  restore still comes from the model (`liveTabIds(in: model)`) -- selection is
  the interaction path, so it stays on the model side of the dividing rule. The
  by-id projection lookup is two methods on `SidebarProjection` itself
  (`group(_:)` / `tab(_:)`), next to the type the store needs them for.
- **`isSingleGroupMode` became a stored property on `SidebarView`.** It was a
  computed read of `currentModel.groups.count`, which would have been the second
  source I5 forbids once the store stopped taking the flag. It is now assigned
  from `projection.isSingleGroupMode` in `applySidebarOps`, so the data source
  and the drop handlers describe the rows actually mounted.
- **`updateTabRow` / `updateGroupRow` take the projection, not the model.**
  They refresh the item payload before configuring the cell, so they need the
  same projection the ops carried; they no longer write `currentModel`, which
  `applySidebarOps` already owns.
- **The interaction-path entry points take ids.** `tabForBadgeHit` returns a
  `TabId`, and the two context-menu builders take `GroupId` / `TabId`. Both used
  nothing but the id, and taking a whole model through a render-path payload was
  the coupling the split removes.
- **PO4 compares rendered caret bitmaps.** An SF Symbol `NSImage` reports no
  name and never compares equal to a second image of the same symbol, so the
  caret direction is asserted against a reference symbol's `tiffRepresentation`.
- **`ChipKindTests` lost its two-overload agreement assertion** along with the
  deleted `tabPaneChips(_:alerts:)`; the test's own subject (an alert marking
  only its own pane) is unchanged.
