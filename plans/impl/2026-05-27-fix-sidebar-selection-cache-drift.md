# Fix sidebar selection cache drift after granular row moves

## Context

After the reconciler rewrite, selecting some moved tabs can show the tab's
panes while the sidebar loses its blue selection highlight. The observed live
case is the `DanTerm.app` group tab titled `5`: `danterm ls` reports its id as
the model's `selectedTabId`, so the model and container reconciler have selected
the tab correctly. The failure is confined to the sidebar's AppKit selection
restore.

The visible behavior is:

- Clicking the tab briefly flashes blue.
- The selected tab's panes become visible.
- After DanTerm handles the click and reconciles, the sidebar highlight
  disappears.
- Closing the first/topmost visible tab can also recreate the lost-selection
  highlight behavior for the surviving selected tab when it follows a prior
  cache-drifting cross-group move.
- Moving a tab across groups into the first/topmost visible sidebar position can
  recreate the same lost-selection highlight behavior. Same-group moves to the
  top have not reproduced the bug.

That shape means AppKit initially selects the row, then `reconcileSidebar`
clears or fails to restore the row selection.

## Root cause

The granular sidebar executor can desynchronize `tabItemCache` from the visible
`NSOutlineView` rows during cross-group moves, especially when the row-op script
mounts a tab at its destination before unmounting the old source row.

`computeSidebarRowOps` diffs each surviving group's tabs in new group order:

- For a later-group -> earlier-group move, the destination group's `.insertTab`
  runs before the source group's `.removeTab`.
- `SidebarView.applyRowOp(.insertTab)` currently reuses
  `tabItemCache[id]` when present.
- The source `.removeTab` later removes its old row and unconditionally removes
  `tabItemCache[t.id]`.
- The destination row remains visible, but the cache no longer maps that tab id
  to its `SidebarItem`.

The same invariant must hold for group-level operations too:

- `.insertGroup` builds child tab rows by directly reading and writing
  `tabItemCache`.
- `.removeGroup` clears each child tab cache entry directly.
- Inserted groups skip per-tab `.insertTab` ops, so flows that create or move
  selected tabs through group-level ops, such as extracting tabs to a new group,
  can reproduce the same cache drift unless group child creation uses the same
  identity-safe helper.

`removeGroup` does not appear to produce the same pre-fix selected-tab drift
under the current op ordering: group-level removals run before surviving-group
tab inserts. It should still use the identity-safe removal helper so all tab
cache mount/unmount behavior is centralized in one invariant-preserving path.

Selection restore then relies on `tabItemCache`:

```swift
guard let item = tabItemCache[id] else { continue }
let row = outlineView.row(forItem: item)
```

When the selected tab's cache entry is missing, `applyRestoreSelection` cannot
find a row for the selected tab and clears the outline selection. This explains
the brief blue flash followed by highlight disappearance.

## Design

Keep `tabItemCache` as "tab id -> currently mounted sidebar item", and make the
executor preserve that invariant across remove/insert scripts whose order is
valid structurally but not cache-safe.

Treat scope as non-limiting for this fix: prefer a clean store/executor
boundary and strong regression coverage over the smallest possible patch.

### 1. Extract a SidebarItemStore

Move the sidebar backing-store state out of `SidebarView` into a small
`SidebarItemStore` type. The store owns:

- `tabItemCache: [TabId: SidebarItem]`
- `groupItemCache: [GroupId: SidebarItem]`
- `rootItems: [SidebarItem]`
- `childItems: [GroupId: [SidebarItem]]`

Expose these as internal members, not private, so the normal unit tests can
assert object identity with `===`. Keep `SidebarItem` as the reference type for
row identity, but move it alongside the store if that lets `just test` compile
without importing AppKit.

The store should provide:

- `apply(_ op: SidebarRowOp, model: AppModel, isSingleGroupMode: Bool) -> Bool`:
  the production and test-facing primitive. It applies the backing-array/cache
  side of one row op and returns whether that backing mutation actually applied.
- `apply(_ ops: [SidebarRowOp], model: AppModel, isSingleGroupMode: Bool)`:
  a test convenience that applies a whole op script without AppKit.
- Per-op helpers for `SidebarView` to call while it issues matching
  `NSOutlineView` mutations. The production path must still mutate the backing
  array before calling `insertItems` / `removeItems`, preserving the current
  AppKit contract.
- A lookup helper for tests, e.g. `displayedTabItem(_:)`, that returns the
  currently displayed `SidebarItem` instance for a live tab id.

After every row-op script, the store invariant is:

- Every live displayed tab has `tabItemCache[tab.id]` pointing to the exact
  displayed `SidebarItem` instance.
- The `selectedTabId`, when live and displayed, satisfies the same invariant.
- Truly removed tabs are absent from `tabItemCache`.

### 2. Preserve the backing-store / outline-view mutation contract

Keep today's guard behavior: if an op references a missing model entity, missing
parent, or missing backing row, `SidebarView` must skip both the backing-store
mutation and the matching `NSOutlineView` mutation.

`SidebarItemStore.apply(_ op:model:isSingleGroupMode:) -> Bool` is the contract
boundary:

- Structural ops (`.reloadAll`, `.insertGroup`, `.removeGroup`, `.insertTab`,
  `.removeTab`) return `true` only when the backing mutation was applied.
- Structural ops return `false` when the target entity, parent, or backing row is
  absent or the index is invalid; the store leaves its arrays and caches
  unchanged.
- `SidebarView` calls `outlineView.reloadData`, `insertItems`, or `removeItems`
  only when the structural store apply returns `true`.
- Non-structural ops (`.reloadGroup`, `.setGroupCollapsed`, `.reloadTab`) do not
  change the backing structure and return `true`. `SidebarView` should keep
  their existing row-update/collapse guards and ignore the return value for
  structural outline mutations.

This prevents a refactor from moving the guard into the store while still
issuing an AppKit mutation for an op the backing store skipped.

### 3. Add identity-safe cache helpers

In `SidebarItemStore`, add helpers for incremental op execution:

- `makeFreshTabItem(for:)`: always creates a fresh `SidebarItem` from the live
  `TabModel`, stores it in `tabItemCache`, and returns it.
- `removeCachedTabItemIfCurrent(_:)`: removes `tabItemCache[tab.id]` only when
  the cache points to the exact removed row object.

All tab item cache mutation in the incremental row-op executor should go
through these helpers. Do not leave a direct child-tab `tabItemCache[...] = ...`
or `removeValue(forKey:)` path in `.insertGroup`, `.removeGroup`, `.insertTab`,
or `.removeTab`.

Do not route `reconcile(model:)` / `.reloadAll` through these helpers. The full
reload path deliberately reuses cached `SidebarItem`s before replacing the
entire backing store, which is what preserves row identity across `reloadData`.
The fresh-item rule is only for incremental insert ops, where reusing a still
mounted item is the source of the bug.

For `.reloadAll`, reuse cached items for live rows, then prune cache entries
whose ids are absent from the new model. This preserves identity for surviving
rows while making topmost-tab close and group-mode-flip closes evict the truly
removed tab.

### 4. Patch tab and group row-op execution

Change `.insertTab` to use `makeFreshTabItem(for:)` instead of blindly reusing
`tabItemCache[id]`.

Change `.removeTab` in both single-group and multi-group branches to capture the
removed `SidebarItem` first, mutate the backing array, and clear the cache only
through `removeCachedTabItemIfCurrent`.

Change `.insertGroup` child row construction to use `makeFreshTabItem(for:)` for
each child tab instead of directly reusing and writing `tabItemCache`.

Change `.removeGroup` child cleanup to use `removeCachedTabItemIfCurrent` for
each child row object instead of unconditionally clearing by tab id. This is an
invariant cleanup, not a separate known pre-fix selected-tab regression under
the current `computeSidebarRowOps` ordering.

This keeps these cases correct:

- Later group -> earlier group move: insert creates a fresh destination item;
  source remove does not clear the destination cache.
- Earlier group -> later group move: source remove clears the old cache; later
  insert creates and caches a new item.
- Same-group reorder: remove clears old cache; insert creates and caches a new
  item.
- Cross-group move into topmost position: the moved tab's new first visible row
  is cached as the displayed row instance, not a stale source row.
- Inserted group with moved tabs: group child creation creates currently-mounted
  destination items without reusing source rows.
- Removed group cleanup: group child removal follows the same identity-safe cache
  cleanup rule as `.removeTab`.
- Close tab: removed row is the cached row, so the cache entry is cleared.
- Reload-all close: surviving rows reuse cached identity, while the closed tab is
  pruned from `tabItemCache`.

This is order-independent in the useful direction: even if a stale cache entry
exists when an incremental insert runs, the always-fresh insert re-establishes
`tabItemCache[id]` as the newly mounted row instead of reusing stale or
currently-mounted identity.

### 5. Keep SidebarView thin over the store

Make `SidebarItemStore` the single owner of `rootItems`, `childItems`,
`tabItemCache`, and `groupItemCache`, but keep thin computed-property shims in
`SidebarView` if that minimizes churn:

```swift
private var rootItems: [SidebarItem] { store.rootItems }
private var childItems: [GroupId: [SidebarItem]] { store.childItems }
private var tabItemCache: [TabId: SidebarItem] { store.tabItemCache }
private var groupItemCache: [GroupId: SidebarItem] { store.groupItemCache }
```

Use the shims for data source, drag/drop, rename, context-menu, emphasis, scroll,
and caret code while routing all backing-state mutation through
`SidebarItemStore`. The shims are read-only accessors; they must not create a
second source of truth.

### 6. Do not change selection policy

Do not patch `resolveReloadSelection`. Its rule is still right: preserve a live
multi-selection when it contains the focused tab, otherwise collapse to the
focused tab. The bug is that the executor loses the selected tab's item identity
before that rule is applied.

## Files to modify

- `app/SidebarView.swift`
  - Replace direct `tabItemCache`, `groupItemCache`, `rootItems`, and
    `childItems` storage with `SidebarItemStore`.
  - Keep thin computed-property shims for those four values if they reduce churn
    in data source, drag/drop, rename, context-menu, emphasis, scroll, and caret
    code.
  - Keep the data source and `NSOutlineView` mutation order unchanged.
  - Gate each structural `reloadData`, `insertItems`, and `removeItems` call on
    the matching `SidebarItemStore.apply(_ op:model:isSingleGroupMode:)`
    returning `true`.

- `app/SidebarItemStore.swift`
  - Add `SidebarItem` and `SidebarItemStore`.
  - Add `apply(_ op:model:isSingleGroupMode:) -> Bool` and a whole-script test
    convenience.
  - Add identity/cache helpers.
  - Update `.insertGroup`, `.removeGroup`, `.insertTab`, and `.removeTab`
    executor branches so every tab item mount/unmount path uses the helpers.
  - Make `.reloadAll` / full rebuild reuse live cached items and prune removed
    cache entries.

- `tests/SidebarItemStoreTests.swift`
  - Add store cache-identity regressions for move-up, cross-group moving into
    topmost position, inserted-group child construction, group removal with one
    moved-out survivor and one closed child, same-group reorder, plain close,
    and topmost-tab close.
  - Treat standalone close cases as invariant guards, not as fail-first proof of
    the observed cache-drift bug.
  - Add a pure contract test for `apply(_ op:model:isSingleGroupMode:) -> Bool`.

- `tests/TestHarness.swift`
  - Register `sidebarItemStoreTests()`.

- `test.sh`
  - Add `app/SidebarItemStore.swift` to the explicit `swiftc` source list.

- `tests-ui/SidebarViewTestShim.swift`
  - Provide the smallest test-only definitions needed to compile
    `app/SidebarView.swift` in the UI test target, including `paneDragType` and
    a minimal `AppRuntime` surface for the symbols `SidebarView` references.
    Keep the shim in `tests-ui` so production code remains unchanged.

- `tests-ui/SidebarSelectionCacheTests.swift`
  - Add a focused Cocoa/UI regression for the real `SidebarView.applySidebarOps`
    executor and native `NSOutlineView` selection restore.

- `tests-ui/PaneSplitViewTests.swift`
  - Register the new sidebar selection cache test in `UITestRunner.main`.

- `test-ui.sh`
  - Add `app/SidebarItemStore.swift` before `app/SidebarView.swift`, plus
    `tests-ui/SidebarViewTestShim.swift` and
    `tests-ui/SidebarSelectionCacheTests.swift`, to the explicit `swiftc`
    source list.

## Tests

### Primary SidebarItemStore coverage

Add normal `just test` coverage for `SidebarItemStore.apply`. The existing pure
`ReconcileTests` only model projection shape; these store tests model
`SidebarItem` object identity and `tabItemCache`. The move and inserted-group
cases are the primary fail-first cache-drift coverage. Standalone close tests
are invariant guards: they should keep proving cache eviction and survivor
identity, but they are not expected to fail before this fix by themselves.

Add a shared assertion helper:

1. Walk the store's displayed live tab rows in model/projection order.
2. For each live displayed tab, assert `store.tabItemCache[tab.id] != nil`.
3. Assert the cached item is `===` the displayed row instance.
4. Assert any explicitly removed tab id is absent from `store.tabItemCache`.
5. Assert `selectedTabId`, when non-nil and live, satisfies the displayed-row
   identity assertion.

Test 0, store apply mutation contract:

1. Seed a `SidebarItemStore` with an initial model using the whole-script apply
   helper.
2. Capture a lightweight snapshot of `rootItems`, `childItems`,
   `tabItemCache`, and `groupItemCache` identities.
3. Apply structural ops that cannot be fulfilled, including a missing group
   insert, missing tab insert, missing parent insert in multi-group mode,
   out-of-range group remove, and missing/out-of-range tab remove.
4. Assert each missing structural op returns `false` and leaves the store
   snapshot unchanged.
5. Apply representative non-structural ops (`.reloadGroup`,
   `.setGroupCollapsed`, `.reloadTab`) and assert they do not change backing
   structure and return `true`; `SidebarView` must ignore their return value for
   structural outline mutations.

Test A, later group -> earlier group tab move:

1. Build an old model with three groups: `A`, `B`, `C`.
2. Put tab `moved` in group `C`; select some other visible tab.
3. Instantiate `SidebarItemStore` and apply the initial sidebar ops
   (`computeSidebarRowOps(old: nil, new:
   desiredSidebar(oldModel))`).
4. Build a new model where tab `moved` is now in earlier group `A` and
   `selectedTabId == moved`.
5. Apply `computeSidebarRowOps(old: desiredSidebar(oldModel), new:
   desiredSidebar(newModel))` through the store whole-script apply helper.
6. Assert:
   - `store.tabItemCache[moved] != nil`.
   - The cached `moved` item is `===` the displayed row instance.
   - Every live displayed tab satisfies the cache identity invariant.

In the TDD red step, run this test against unpatched code and record the actual
failure. The expected pre-fix symptom at the store layer is a missing or
mispointed cache entry after the move-up script.

Test B, cross-group move tab into topmost visible position:

1. Build an old model/projection with at least two groups where tab `moved` is
   visible in a non-first group, and another tab is currently the first visible
   sidebar tab.
2. Build a new model/projection where `moved` has crossed into the first group
   at index 0, is the first/topmost visible tab, and `selectedTabId == moved`.
3. Apply `computeSidebarRowOps(old: desiredSidebar(oldModel), new:
   desiredSidebar(newModel))` through the store whole-script apply helper.
4. Assert:
   - `store.tabItemCache[moved] != nil`.
   - The cached `moved` item is `===` the displayed topmost row instance.
   - Every live displayed tab satisfies the shared cache identity invariant.

This pins the observed topmost-position repro as a cross-group move. Do not use
a same-group move-to-index-0 shape as the primary regression, because that path
has not reproduced the lost-highlight behavior.

Test C, inserted-group child path:

1. Build an old model with groups `A` and `B`, with tab `moved` in `B`.
2. Build a new model where a newly inserted group `New` contains `moved` and
   `selectedTabId == moved`.
3. Apply the computed row ops through the store whole-script apply helper.
4. Assert the shared cache identity invariant, especially for `moved`.

This protects the `.insertGroup` branch, where inserted groups bring child tabs
without per-tab `.insertTab` ops.

Test D, group removal with one moved-out survivor and one closed child:

1. Build an old model with group `RemoveMe` containing tabs `survivor` and
   `closed`, plus an earlier surviving group `A`.
2. Build a new model where `RemoveMe` is removed, `survivor` has moved into
   group `A`, `closed` is absent, and `selectedTabId == survivor`.
3. Apply `computeSidebarRowOps(old: desiredSidebar(oldModel), new:
   desiredSidebar(newModel))` through the store whole-script apply helper.
4. Assert:
   - `store.tabItemCache[survivor] != nil`.
   - The cached `survivor` item is `===` the displayed row instance in group
     `A`.
   - `store.tabItemCache[closed] == nil`.
   - Every live displayed tab satisfies the shared cache identity invariant.

This covers `.removeGroup` child cleanup without depending on it being the known
selected-tab drift path.

Test E, same-group reorder:

1. Build an old single-group or multi-group model where tab `moved` is not at
   its final index.
2. Build a new model where the same group contains the same tab ids in a new
   order and `selectedTabId == moved`.
3. Apply the computed row ops through the store whole-script apply helper.
4. Assert every live displayed tab, including `moved`, satisfies the shared
   cache identity invariant and no cache entries were lost.

Test F, plain close invariant guard:

1. Build an old model/projection where selected tab `closed` is visible but is
   not the first visible tab.
2. Build the new model/projection after closing `closed`, with a visible
   surviving tab selected.
3. Apply the computed close ops through the store whole-script apply helper.
4. Assert the selected survivor is cached as its displayed row, `closed` is
   evicted, and every live displayed tab satisfies the shared invariant.

This is an invariant guard for ordinary close behavior, not a fail-first
reproduction of the cache-drift selection bug.

Test G, standalone topmost-tab close invariant guard:

1. Build an old model/projection with one group whose first visible tab is the
   selected tab `closed`, followed by survivor tab `next`.
2. Build the new model/projection after closing `closed`, with `selectedTabId ==
   next`.
3. Apply `computeSidebarRowOps(old: desiredSidebar(oldModel), new:
   desiredSidebar(newModel))` through the store whole-script apply helper.
4. Assert:
   - `store.tabItemCache[next] != nil`.
   - The cached `next` item is `===` the displayed row instance.
   - `store.tabItemCache[closed] == nil`.
   - Every live displayed tab satisfies the shared cache identity invariant.

This is an invariant guard for standalone topmost close behavior. The actual
close repro is covered by the UI sequence that first creates cache drift with a
cross-group move.

Test H, topmost-tab close across multi-group -> single-group invariant guard:

1. Build an old model/projection with at least two groups where the first
   topmost visible tab `closed` is selected.
2. Close `closed` so the surviving model selects the first visible survivor.
   Prefer the shape where closing the top group leaves one group, forcing
   `computeSidebarRowOps` to emit `.reloadAll` through a multi-group ->
   single-group mode flip.
3. Apply the close transition through the store whole-script apply helper.
4. Assert the same selected-cache, displayed-identity, and removed-tab-eviction
   invariants as Test G.

Test H keeps the full rebuild path honest when closing the topmost tab also
changes group display mode. It is still an invariant guard unless paired with a
preceding cache-drifting move in the real `SidebarView` path.

### UI regression

Add a mandatory focused `tests-ui` regression for the real
`SidebarView.applySidebarOps` path. The pure `SidebarItemStoreTests` suite is
still the primary fail-first coverage for cache identity, but this test proves
the AppKit bridge restores native row selection instead of only repairing the
cache.

Test UI-1, real sidebar executor preserves selected-row highlight:

1. Create a `SidebarView` in a small test `NSWindow` so `NSOutlineView` row views
   and selection state are materialized.
2. Build an old model/projection that matches a cache-drift repro, preferably
   the later-group -> earlier-group or cross-group topmost move.
3. Apply the initial ops through `SidebarView.applySidebarOps`.
4. Assert or log `visibleTabIdsInRowOrder()` immediately after the initial
   offscreen apply. The test must fail early if rows did not materialize.
5. Select the moved tab's current source row in the `NSOutlineView` to simulate
   AppKit's immediate click selection before the reconcile pass.
6. Build the new model/projection where that tab has moved and
   `selectedTabId == moved`.
7. Apply the computed transition ops through `SidebarView.applySidebarOps`.
8. Assert:
   - `visibleTabIdsInRowOrder()` contains `moved` at the expected destination.
   - The selected row indexes contain the destination row for `moved`.
   - The materialized row view for that row reports `isSelected == true`, proving
     the native selected row remains highlighted.
   - The outline item at that row is the displayed `SidebarItem` instance for
     `moved`.

Implement `visibleTabIdsInRowOrder()` and row-selection inspection as UI-test
helpers that find the private `NSOutlineView` through the `SidebarView` view
hierarchy, so production API does not grow just for this regression.

Test UI-2, close after drift keeps survivor highlighted:

1. Create a `SidebarView` in a small test `NSWindow`.
2. Build and apply an initial model with at least two groups where tabs `closed`
   and `survivor` both start in a later group.
3. Apply a cross-group move transition through `SidebarView.applySidebarOps`
   where both `closed` and `survivor` move into the first group as the first two
   visible tabs, ordered `[closed, survivor, ...]`, and
   `selectedTabId == closed`. This makes both tabs take the pre-fix
   insert-before-remove cache-drift path.
4. Build a close transition that removes `closed` and selects `survivor`.
5. Apply that close transition through `SidebarView.applySidebarOps`.
6. Assert:
   - `visibleTabIdsInRowOrder()` no longer contains `closed`.
   - The selected row indexes contain the destination row for `survivor`.
   - The materialized row view for `survivor` reports `isSelected == true`.
   - The outline item at that row is the displayed `SidebarItem` instance for
     `survivor`.

This is the fail-first close repro because the post-close selected survivor is
itself a pre-fix cache-drifted tab. Standalone close tests remain pure invariant
guards because the old `.removeTab` path already evicts only the removed id and
`resolveReloadSelection` can select a live focused survivor when no prior cache
drift exists.

Run this UI suite last because the harness uses Swift `do` / `catch`, which
will not catch an Objective-C `NSException` if AppKit rejects an invalid
outline-view mutation.

### UI test wiring

`test-ui.sh` compiles a fixed source list. The implementation must update that
list so the new regression actually runs:

- Add `app/SidebarItemStore.swift` before `app/SidebarView.swift`.
- Add `app/SidebarView.swift`.
- Add the test-only shim file before `SidebarView.swift` if Swift name lookup
  requires it.
- Add `tests-ui/SidebarSelectionCacheTests.swift`.
- Register `sidebarSelectionCacheTests()` last in `UITestRunner.main`.

Before implementing the test body, compile once with the new source list and
shim to expose missing dependencies. Keep the shim minimal: only add symbols
needed by `SidebarView` for this offscreen test, and avoid broad production
stubs that could hide real compile errors.

### Verification

Run:

```sh
just test
just test-ui
just build
```

`just test` guards the pure row-op and store contract behavior. `just test-ui`
guards the real AppKit executor and native selection highlight. `just build`
guards the production app target after the `SidebarView` refactor.

## Manual verification

After automated verification passes, run the live app and check:

- In the current reproduced state, click `DanTerm.app` -> tab `5`; the panes
  should switch and the tab row should keep the blue highlight.
- Click the already-focused tab `5`; it should remain highlighted instead of
  flashing and disappearing.
- Move a tab from a later group to an earlier group, then select it; highlight
  should persist.
- Move a tab from a lower group into the topmost sidebar position, then select
  it; highlight should persist.
- Move a tab from an earlier group to a later group, then select it; highlight
  should persist.
- Reorder tabs within one group; selected-row highlight and multi-selection
  behavior should remain correct.
- Move a tab across groups into the topmost position, close that topmost
  selected tab, and verify the surviving selected tab keeps the blue highlight.
- Close a first/topmost selected tab without a preceding move; selection should
  fall back normally and the cache should not retain the closed tab.
- Close a selected moved tab; selection should fall back normally, with no stale
  highlighted row.

## Out of scope

- Reworking `computeSidebarRowOps` ordering. Its sequential script is already
  shape-correct and tested; the problem is the executor's cache invariant.
- Changing multi-selection policy.
- Changing split-container reconcile behavior. The selected panes already follow
  `selectedTabId` correctly.
