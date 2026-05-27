# Plan: centralize the view-swap TODO-popover clear in the reconciler

## Context

An open TODO popover is tracked by `model.todoPopover`, a single enum field with
`.pane` / `.tab` cases. The two scopes anchor differently: a **pane** popover
anchors to the pane wrapper's button (`wrapper.todoButtonView`, shown by the
`.showTodoPopover` case in `AppRuntime`), which is destroyed when a container
rebuilds -- so a "view swap" (the visible container removed,
rebuilt, or hidden) physically orphans it. A **tab** popover anchors to
`chromeView.tabTodoButton`, persistent window chrome (`WindowChromeView.swift:65-66`,
"Always shown") that survives container rebuilds -- so it is never physically
orphaned; closing it on a view swap is a deliberate UX policy. Today both scopes
are closed on a view swap, in two halves: the AppKit popover(s) and the model
record.

Today these two halves are split:

- The **AppKit half** is already reconciler-derived: `reconcileContainers`
  computes an inline `strandsVisible` predicate over the container-op diff and
  calls `dismissStrandedPopovers()` (`app/Reconcile.swift:114-124`).
- The **model half** is hand-scattered across **15** `clearTodoPopoverForViewSwap(&model)`
  call sites by a documented "1:1 migration rule" (the helper's own doc-comment
  at `app/ModelOperations.swift:1573-1581`).

This scatter is the root cause of a test-coverage gap (a 15-site manual rule can
only be pinned by ~15 structure-sensitive assertions; today only 3 exist) and is
a standing discipline obligation: every future view-swap handler must remember to
re-add the call, and any view-swap path that dismisses the AppKit popover but
forgets the model clear silently desyncs the two halves.

Investigation showed **13 of the 15 sites are exactly the `strandsVisible`
condition**. Deriving the model clear from that predicate preserves today's
close-on-view-swap policy for both scopes -- it clears the single `model.todoPopover`
field whenever the visible container is stranded, exactly as the scattered calls
did, and `dismissStrandedPopovers()` already dismisses both the pane and tab AppKit
pairs. (For a pane popover the clear is a physical necessity -- its anchor button is
gone; for a tab popover it is policy, since the chrome anchor persists.) The
remaining **2 sites are genuinely not view swaps** and must keep an explicit clear:

- `app/Update.swift:2410` (`navigateToPane`, same-tab branch) -- finalizes the
  open popover. `selectTab` no-ops when the tab is already selected, so for a focus
  change that produces no container op `strandsVisible` is correctly false; when
  the same navigation *also* unzooms it does reconcile, and the explicit clear is
  then a harmless idempotent duplicate.
- `tearDownCurrentSession` (`app/AppRuntime.swift`) -- bypasses the reconciler
  entirely (it removes containers directly), so no reconcile pass runs.

Safety is established: no reconcile pass and no pre-reconcile command reads
`model.todoPopover` (only update() guards and close callbacks read it, and those
fire on the next dispatch cycle), so clearing it inside `reconcileContainers` is
safe. The dispatch order is `update()` -> perform pre-reconcile commands ->
`reconcile()` (`reconcileContainers` is its first pass).

Intended outcome: one reconciler-owned rule for the common case (replacing 13
scattered calls), the view-swap-clear behavior extracted to pure unit-tested
helpers (a `ContainerOp` predicate plus the popover-state transition it drives),
and the companion `advanceSidebarCache` characterization test the original
finding requested.

## Part 1 -- The pivot: derive the popover clear from the reconciler

### 1a. Extract two pure helpers (predicate + transition)

`strandsVisible` is currently an inline expression and cannot be unit-tested, and
the model-clear it should drive is untested entirely. Extract both next to their
`ContainerOp` / `computeContainerOps` siblings in `app/ModelOperations.swift`
(the `ContainerOp` enum is at ~`:1504`).

The predicate primitive:

```swift
/// Does this container-op script strand the previously-visible tab -- i.e. is the
/// visible container removed, rebuilt, or hidden? This is the "view swap" condition.
/// A pane TODO popover anchored to that container's wrapper button is physically
/// orphaned when it holds; a tab popover (anchored to persistent window chrome) is
/// not, but is closed on view swap by policy. Pure + top-level so the rule is
/// unit-testable (the reconcile pass wiring it is manual-QA-only).
func containerOpsStrandVisible(ops: [ContainerOp], previouslyVisibleTabId: TabId?) -> Bool {
  guard let visible = previouslyVisibleTabId else { return false }
  return ops.contains { op in
    switch op {
    case .remove(let t), .rebuild(let t): return t == visible
    case .setVisible(let t, let v): return t == visible && !v
    }
  }
}
```

The transition helper, which computes **both** the new popover record and the
teardown decision so the meaningful `current -> nil` semantics are pinned in pure
code (not just the Bool). Use a named `Equatable` struct, not a tuple, so
`expectEqual` can assert the whole outcome in one line (tuples can't conform to
`Equatable`); `TodoPopoverScope` is already `Equatable`:

```swift
/// The TODO-popover outcome of a container reconcile. On a view swap the record
/// clears (close-on-view-swap policy, both scopes) and the AppKit teardown runs;
/// otherwise nothing changes. `dismissStranded` gates `dismissStrandedPopovers()`,
/// which dismisses both pane + tab popover pairs and cancels any pane drag, so it
/// tracks the predicate -- not whether a record is set. Pure so the transition is
/// unit-tested; reconcileContainers just applies the result.
struct StrandedPopoverOutcome: Equatable {
  var popover: TodoPopoverScope?
  var dismissStranded: Bool
}

func reconcilePopover(
  current: TodoPopoverScope?, ops: [ContainerOp], previouslyVisibleTabId: TabId?
) -> StrandedPopoverOutcome {
  if containerOpsStrandVisible(ops: ops, previouslyVisibleTabId: previouslyVisibleTabId) {
    return StrandedPopoverOutcome(popover: nil, dismissStranded: true)
  }
  return StrandedPopoverOutcome(popover: current, dismissStranded: false)
}
```

### 1b. Apply the outcome in `reconcileContainers`

Replace the inline predicate + AppKit-only dismiss (`app/Reconcile.swift:114-124`)
with a `reconcilePopover` call that applies both halves. Clear the model record
*before* `dismissStrandedPopovers()` to preserve today's invariant (by the time
the AppKit dismiss's close-callback fires, the record is already nil):

```swift
let previouslyVisibleTabId = tabContainers.first(where: { !$0.value.isHidden })?.key
let outcome = reconcilePopover(
    current: model.todoPopover, ops: ops, previouslyVisibleTabId: previouslyVisibleTabId)
// A view swap closes the open TODO popover (both scopes): the model record (was the
// scattered clearTodoPopoverForViewSwap calls in update()) and the AppKit popover(s).
// Safe to clear the model here -- no reconcile pass or pre-reconcile command reads
// model.todoPopover; close callbacks fire next cycle and see it already nil.
model.todoPopover = outcome.popover
if outcome.dismissStranded { dismissStrandedPopovers() }
```

Note: this is the first model mutation in a reconcile pass (sibling passes mutate
only `caches.*` / `viewLocalState`). It is deliberate and bounded -- `todoPopover`
is ephemeral, no pass reads it, and computing the outcome in a tested pure helper
keeps the untested reconcile-pass surface down to applying two precomputed fields.

### 1c. Retire the 13 scattered `update()` clears

Delete the `clearTodoPopoverForViewSwap(&model)` line (and its now-stale adjacent
comment) at all 13 COVERED sites. Match by handler/context, not raw line number
(numbers shift as lines are removed):

| Handler (file) | Why covered |
|---|---|
| foreground `createTab` (Update) | tab switch -> hide old visible |
| `splitPane` on selected tab (Update) | selected-tab shape drift -> rebuild |
| `closePane` on selected tab (Update) | selected-tab shape drift -> rebuild |
| `movePane` on selected tab (Update) | selected-tab shape drift -> rebuild |
| `movePaneToTab` (Update) | tab switch to target -> hide old |
| `movePaneToNewTab` (Update) | tab switch to new -> hide old |
| `focusDirection` unzoom (Update) | isZoomed is part of ContainerShape -> rebuild |
| `surfaceCreationFailed` w/ selection move (Update) | old visible tab removed/hidden |
| `deleteGroup` w/ selection move (Update) | old visible container removed/hidden |
| `toggleZoomPane` zoom + unzoom (Update, 2 sites) | shape drift -> rebuild |
| `applySelectTab` (Update) | tab switch -> hide old |
| `closeTabBody` w/ selection move (Update) | old visible tab removed |

For sites guarded by "selection moved" (`surfaceCreationFailed`, `deleteGroup`,
`closeTabBody`): when selection does *not* move, no clear fired before and
`strandsVisible` is false -- consistent. When it does move, the old visible
container is removed/hidden -> `strandsVisible` true -> reconciler clears. So
deletion is behavior-preserving.

### 1d. Keep the 2 genuinely-distinct clears; delete the now-misleading helper

Neither remaining site is a view swap, so the name `clearTodoPopoverForViewSwap`
becomes a lie. **Delete the helper** (`app/ModelOperations.swift:1573-1581`) and
inline `model.todoPopover = nil` with an accurate intent comment at each:

- `app/Update.swift:2410` (inside `navigateToPane`, the `!tabSwitched` branch):
  ```swift
  // Same-tab navigation finalizes the open popover. selectTab no-ops when the tab is
  // already selected, so applySelectTab's clear didn't run. For a focus change with no
  // container op the reconciler's view-swap clear won't fire either, so clear here;
  // when the same navigation also unzooms (a ContainerShape drift -> rebuild), the
  // reconciler clears too and this is a harmless idempotent duplicate.
  model.todoPopover = nil
  ```
- inside `tearDownCurrentSession` (`app/AppRuntime.swift`):
  ```swift
  model.todoPopover = nil  // session teardown bypasses the reconciler; clear the record directly
  ```

Deleting the helper also removes the `clearTodoPopoverForViewSwap` grep signal
entirely, so the retired discipline can't silently creep back.

### 1e. Refresh the now-stale doc comments

- `app/Reconcile.swift:114-116` -- update to state the reconciler owns both halves.
- the `dismissStrandedPopovers` doc-comment (`app/AppRuntime.swift`) -- drop the
  "the model half is the pure `clearTodoPopoverForViewSwap` in update()" clause;
  the model half now runs right beside this call in `reconcileContainers`.

## Part 2 -- `advanceSidebarCache` characterization test

`advanceSidebarCache` (`app/ModelOperations.swift:1410`) is pure, guards a
documented drift bug ("a cancelled rename would strand a stale badge"), and is
the only member of its reconcile-helper family with zero tests. Add a `test(...)`
block to the existing `reconcileTests()` suite in `tests/ReconcileTests.swift`,
reusing the in-file builders `sbTabFull`, `sbGroup`, `sbProj` and the
`RenameTarget` `.tab(id)` / `.group(id)` constructors (same style as the existing
`guardSidebarRenameOps` tests). Cases:

- **Suppressed `.tab(id)`**: build `old`/`new` where tab `id` differs in title +
  `unreadAlertCount` and a sibling tab also differs. Assert the result's tab `id`
  equals the *old* projection (retained), and the sibling equals the *new*.
- **Suppressed `.group(id)`**: build `old`/`new` where the group differs in
  reload-attrs (`name`, derived `unreadAlertCount`/`tabCount`, `isFirst`) *and*
  structurally (`isCollapsed`, `tabs`). Assert the result retains old `name` /
  `unreadAlertCount` / `tabCount` / `isFirst` but takes new `isCollapsed` + `tabs`.
- **`nil` suppressedRenameTarget**: returns `new` unchanged.
- **Suppressed target absent from `new`** (e.g. `.tab(a)` but `a` removed): the
  guard returns `new` unchanged.
- **`old == nil`**: returns `new` unchanged.

## Part 3 -- Trim the 3 relocated assertions

The clear is no longer an `update()`-level responsibility, so the 3 existing
update()-level assertions that pin it will fail (pure update() tests don't run
the reconciler). Their behavior relocates to the `reconcilePopover` transition test
plus the existing `computeContainerOps` tests (which already prove a selection
switch / shape drift produces a hide/remove/rebuild op). From each test below,
remove only the `model.todoPopover = ...` setup line and the
`model.todoPopover == nil` assertion; keep every structural assertion, and rename
to drop the "...clears stranded popover" suffix:

- `tests/UpdateTabTests.swift:82-96` (`testSelectTab...`)
- `tests/UpdatePaneTests.swift:253-270` (`closePane with remaining panes...`)
- `tests/UpdatePaneTests.swift` cross-tab-move test (the `:648`/`:677` body)

Unaffected (different mechanisms, leave as-is): `UpdateTodoTests` closePane/toggle
clears (the closed pane owns its popover; emits `.dismissTodoPopover`),
`UpdateTabTodoTests` scope clears.

## Files to modify

- `app/ModelOperations.swift` -- add `containerOpsStrandVisible` + `reconcilePopover` (and `StrandedPopoverOutcome`); delete `clearTodoPopoverForViewSwap`.
- `app/Reconcile.swift` -- apply the `reconcilePopover` outcome (model clear + dismiss) in `reconcileContainers`; refresh comment.
- `app/Update.swift` -- delete 13 clear calls; inline the same-tab clear at `navigateToPane`.
- `app/AppRuntime.swift` -- inline the teardown clear; refresh `dismissStrandedPopovers` doc.
- `tests/ReconcileTests.swift` -- add `reconcilePopover` transition test + `advanceSidebarCache` test.
- `tests/UpdateTabTests.swift`, `tests/UpdatePaneTests.swift` -- trim the 3 relocated assertions.

## TDD sequencing

1. Add the `reconcilePopover` transition test against the not-yet-extracted helpers
   (fails to compile) -> extract both helpers (1a) -> test passes. This is the
   primary guard for the relocated behavior: it pins the full `current -> nil`
   transition, not just the Bool. Cases (build `ops` from the `ContainerOp` truth
   table): current `.pane(p)` + a stranding op (`.rebuild` / `.remove` /
   `.setVisible(_, false)` on the visible tab) -> `(nil, true)`; current `.tab(t)`
   + stranding op -> `(nil, true)`; current `.pane(p)` + non-stranding ops (op on a
   background tab, `.setVisible(visible, true)`, or empty) -> `(.pane(p), false)`;
   current `nil` + stranding op -> `(nil, true)`; current `nil` + non-stranding ->
   `(nil, false)`; `nil` previouslyVisibleTabId -> `(current, false)`. These
   exercise `containerOpsStrandVisible` transitively; add a couple of direct
   predicate cases only if desired.
2. Add the `advanceSidebarCache` characterization test (Part 2). It pins existing
   behavior, so it should pass on first run; sanity-check it fails if the
   suppressed-row retention is removed.
3. Wire `reconcileContainers` (1b), retire the 13 calls (1c), inline the 2 kept
   clears + delete the helper (1d), refresh comments (1e).
4. Trim the 3 relocated assertions (Part 3).

## Verification

- `just test` -- the `reconcilePopover` transition test, the `advanceSidebarCache`
  test, and the 3 trimmed tests all pass; full suite green.
- `just build` -- compiles after the helper deletion + rewiring (the deleted
  `clearTodoPopoverForViewSwap` symbol has no remaining references).
- Manual QA (the reconcile-pass wiring is manual-QA-only per the test file's
  stated boundary). With a dev build, in each case open a TODO popover then:
  1. **Tab switch** (sidebar click / cmd+number) -> popover dismisses; re-toggling
     the *same* popover re-opens it (proves the model record was cleared, not just
     the AppKit view).
  2. **Split the visible tab** -> dismisses.
  3. **Close a sibling pane** (visible rebuild) -> dismisses.
  4. **Move a pane to another tab** (open a `.tab` popover first) -> dismisses.
  5. **Zoom / unzoom** the visible tab -> dismisses.
  6. **Same-tab navigation** (jump/directional focus to another pane in the same
     tab) -> popover finalizes (2410 path intact).
  7. **Session restore / teardown** with a popover open -> cleared (1169 path).
