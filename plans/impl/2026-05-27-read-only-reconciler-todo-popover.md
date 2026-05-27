# Move the view-swap popover model-clear into update(); document the read-only reconciler

## Context

The current TODO-popover cleanup solved a real problem -- the open-TODO-popover
record (`model.todoPopover`) had to be hand-cleared at ~14 scattered sites in
`update()` on every view swap, a "remember to add the call" obligation with thin
tests. It centralized the clear by deriving it in the reconciler.

But the way it centralized introduced `model.todoPopover = outcome.popover` inside
`reconcileContainers` (`app/Reconcile.swift:132`), the first model mutation in a
reconcile pass. That inverts DanTerm's core dependency direction: the reconciler is
supposed to be a read-only projection (pure projections in `ModelOperations.swift`
and thin impure executors that apply a diff to AppKit, per the `Reconcile.swift:1-12`
header), and ordinary `Msg` handling writes model state through `update()`. With
the reconciler writing a field that `update()` then reads (the `toggleTodoPopover`
guard, the close callbacks), "what is the model after message X?" is no longer
answerable from `update()` alone, and that model transition leaves the unit-tested
layer for the manual-QA-only one.

This plan keeps the useful centralization, the deleted 14-site obligation, and the
extracted/tested `containerOpsStrandVisible` predicate, then moves only the model
write back into the pure `update()` layer, restoring the read-only reconciler. It
also adopts the same-tab-navigate "preserve" behavior (fixes a latent model/AppKit
desync) and records the read-only-reconciler invariant as an ADR so the next
deviation gets caught in review.

Intended outcome: ordinary `Msg` handling again clears `model.todoPopover` only through
the fully-unit-testable `update()` layer; the reconciler keeps only the AppKit dismiss;
the invariant is documented with restore/session replacement explicitly out of scope.

## Part 1 -- Code

### 1. `app/Reconcile.swift` -- reconciler keeps only the AppKit half

Replace the popover block (currently lines 125-133: the comment + `reconcilePopover`
call + `model.todoPopover = ...` write + dismiss) with the AppKit dismiss only, reusing
the kept `containerOpsStrandVisible` predicate:

```swift
// AppKit half of view-swap popover dismissal: when the visible container is removed,
// rebuilt, or hidden, the anchored popover(s) strand -- dismiss them. The model half
// (clearing model.todoPopover) is the pure reconcileTodoPopover in update(); the two
// halves read different inputs (live tabContainers ops here, model before/after there)
// because they run in different layers (see docs/design read-only-reconciler ADR).
let previouslyVisibleTabId = tabContainers.first(where: { !$0.value.isHidden })?.key
if containerOpsStrandVisible(ops: ops, previouslyVisibleTabId: previouslyVisibleTabId) {
    dismissStrandedPopovers()
}
```

### 2. `app/ModelOperations.swift` -- delete the transition, keep the predicate, add the pure clear

- **Delete** `struct StrandedPopoverOutcome` (1573-1576) and `func reconcilePopover`
  (1580-1587). After the Reconcile.swift rewire, the only references are gone (the
  reconciler now calls `containerOpsStrandVisible` directly; the test is converted in
  Part 2).
- **Keep** `containerOpsStrandVisible` (1559-1569) unchanged -- still the reconciler's
  dismiss predicate, still its own unit test.
- **Add**, next to `reconcileMru` (~2028), the pure model half. Reuses the existing pure
  `containerShape(of:)` (1500) and `tabById(_:in:)` (458):

```swift
/// Identity of the visible container an open TODO popover is anchored to, captured
/// before a message runs. nil when no popover is open (the common path -- skips the
/// tree walk). Compared post-message by reconcileTodoPopover.
struct TodoPopoverStrandKey: Equatable {
    let visibleTabId: TabId?
    let visibleShape: ContainerShape?
}

func todoPopoverStrandKey(_ model: AppModel) -> TodoPopoverStrandKey? {
    guard model.todoPopover != nil else { return nil }
    let sel = model.selectedTabId
    return TodoPopoverStrandKey(
        visibleTabId: sel,
        visibleShape: sel.flatMap { tabById($0, in: model) }.map(containerShape(of:)))
}

/// Pure model half of view-swap popover dismissal -- the update()-layer twin of the
/// reconciler's containerOpsStrandVisible AppKit dismiss. Clears model.todoPopover iff
/// the message stranded the visible container the popover was anchored to: the selected
/// tab changed, or the selected tab's ContainerShape drifted (structure / leaf-ids /
/// zoom). A same-tab focus change strands nothing, so it is intentionally NOT a trigger
/// (matches paneBecameFirstResponder). Runs in update()'s defer next to reconcileMru;
/// previous == nil means a popover opened during this message is never cleared by it.
func reconcileTodoPopover(_ model: inout AppModel, previous: TodoPopoverStrandKey?) {
    guard let previous, model.todoPopover != nil else { return }
    let sel = model.selectedTabId
    let current = TodoPopoverStrandKey(
        visibleTabId: sel,
        visibleShape: sel.flatMap { tabById($0, in: model) }.map(containerShape(of:)))
    if current != previous { model.todoPopover = nil }
}
```

### 3. `app/Update.swift` -- wire into the existing defer; drop the 2410 clear

- At line 13, capture before and call inside the existing choke point. `reconcileMru`
  only reads `selectedTabId` and writes `mruOrder`, so running the popover clear after
  it is safe:

```swift
let strandedPopoverPrev = todoPopoverStrandKey(model)
defer {
    reconcileMru(&model)
    reconcileTodoPopover(&model, previous: strandedPopoverPrev)
}
```

- In `navigateToPane` (2342-2371): delete the `if !tabSwitched { model.todoPopover = nil }`
  block and its comment (2358-2365), and delete the now-dead `let tabSwitched =
  !commands.isEmpty` (it is used only by that block -- verified). Leave a short comment in
  its place so a future reader does not "re-fix" it:

```swift
// No popover clear on same-tab navigation: the anchor button and the visible container
// stay intact, so nothing is stranded (consistent with paneBecameFirstResponder). A
// cross-tab navigate cleared via the nested selectTab; an unzoom drifts the shape and
// clears via update()'s reconcileTodoPopover.
```

### 4. `app/AppRuntime.swift` -- comments only

- `tearDownCurrentSession` (1170): keep the inline `model.todoPopover = nil` -- this path
  bypasses the reconciler *and* `update()`, so it must clear directly. Comment is accurate.
- `dismissStrandedPopovers` doc-comment (1328-1336): it currently says
  "`reconcileContainers` calls this **after clearing the model record** ...". That is no
  longer true -- the reconciler no longer clears the record. Update it to: the reconciler
  calls this when the visible container is hidden/rebuilt/removed
  (`containerOpsStrandVisible`); the model record is cleared separately by
  `reconcileTodoPopover` in `update()`.

## Part 2 -- Tests

- **`tests/ReconcileTests.swift` (359-394):** convert the `reconcilePopover` /
  `StrandedPopoverOutcome` transition test into a `containerOpsStrandVisible` Bool-predicate
  test (the predicate is what the reconciler still uses). Map each case: `.rebuild` /
  `.remove` / `.setVisible(_, false)` on the visible tab -> `true`; an op on a background
  tab / `.setVisible(_, true)` / empty ops / `nil` previouslyVisibleTabId -> `false`. Drop
  the popover-record dimension (now `update()`'s concern, covered below).

- **`tests/UpdateTodoTests.swift`:** add the behavioral `reconcileTodoPopover` group
  (these restore the update-level assertions that belong with TODO-popover model state).
  All drive `update()` and check the record:
  - **Clear matrix:** table-drive both popover scopes (`.pane(p1)`, `.tab(t1)`) across
    both clear triggers:
    - **selection change clears:** two tabs, t1 selected with the scoped popover open,
      `update(.selectTab(t2))` -> nil.
    - **selected-tab shape change clears:** t1 selected with the scoped popover open,
      `update(.splitPane(paneId: p1, direction: .horizontal))` -> nil.
  - **same-tab focus PRESERVES:** split tab (p1, p2), `todoPopover = .pane(p1)`,
    `update(.paneBecameFirstResponder(paneId: p2))` -> still `.pane(p1)` (the
    selection/shape-drift boundary / over-clear guard).
  - **background-tab op PRESERVES:** tab1 selected with `todoPopover = .pane(p)`, mutate
    background tab2's shape -> preserved.
  - **opened-this-message survives:** no popover, `update(.toggleTodoPopover(p))` ->
    `.pane(p)` (the `previous == nil` guard).

- **`tests/UpdateIpcTests.swift`:** add **paneFocus same-tab PRESERVES** next to the
  existing `pane.focus` tests (373-433), reusing file-private `sendIpc` (1737) /
  `contextForSelectedPane` (1746). Open a popover, then `sendIpc(&model, method:
  Methods.paneFocus, ...)` targeting a pane in the already-selected, **unzoomed** tab ->
  popover preserved. This is the sole guard on the one behavior change in this plan
  (the current same-tab `navigateToPane` clear becomes preserve), and pins the
  no-longer-present model/AppKit desync.

## Part 3 -- ADR: read-only view reconciler

Create `docs/design/2026-05-27-read-only-reconciler.md` with this exact content:

```markdown
# Read-Only View Reconciler

Status: Accepted
Date: 2026-05-27

## Context

DanTerm uses Elm architecture: user/Ghostty actions become `Msg` values,
`update(&model, msg)` is the pure model transition and returns `[Command]`, and
`AppRuntime.perform(command)` runs side effects. The view reconciler is the next
step in that pipeline: after update and pre-reconcile commands, `reconcile()`
derives AppKit and Ghostty/surface state from the current model.

The reconciler migration moved view-sync work out of `update()` and
`AppRuntime.send()` into ordered `reconcile*` passes. The intended pass shape,
from the template at the top of `app/Reconcile.swift`, is:

- pure projections and structural diff/op helpers live in
  `ModelOperations.swift`, stay AppKit-free, and are unit-tested;
- `ReconcilerCaches` stores each pass's last applied projection so the next pass
  applies only the delta;
- `Reconcile.swift` contains thin impure executors that apply the computed delta
  to AppKit views, Ghostty/surface state, and runtime-owned view handles;
- the matching `Command` case and `perform` arm disappear in the same change, so
  missed view-sync emissions become compile errors.

Commands are for true side effects and transient imperative actions: PTY/surface
creation, IPC replies, notifications, checkpoint/config writes, focus requests,
export, and popover presentation. Everything the view merely shows should be a
projection of the model. Some commands run after reconcile when they target
views the reconciler creates; that classification is explicit and exhaustive.

The "read-only reconciler" rule was implicit in that architecture, but it was
not written down. The current TODO popover view-swap cleanup writes
`model.todoPopover` inside `reconcileContainers`. That solved the scattered
update-site obligation, but crossed the layer boundary: after `update()`
returned, reconcile could mutate model state that later `update()` guards and
popover close callbacks read.

This ADR makes the rule explicit and describes the ideal shape for future
reconcile work, not just the current implementation.

## Decision

The view reconciler is a read-only projection of `AppModel`. A reconcile pass
may read `AppModel` and `ViewLocalState`; it may write AppKit views,
Ghostty/surface state, runtime-owned view handles, and `ReconcilerCaches`. It
must not write `AppModel`.

For ordinary `Msg` handling, `AppModel` transitions happen in `update()` and are
covered by behavior tests at the pure layer. If view-sync needs derived model
state, compute it in `update()` before reconcile runs. If state is genuinely
view-derived and should not be serialized or owned by the domain model, keep it
in `ViewLocalState` or a runtime-owned handle rather than writing it back into
`AppModel` from a reconcile pass.

New reconcile passes should follow the migration template:

- put pure projections and structural diff/op helpers in `ModelOperations.swift`,
  with `Equatable` outputs where possible;
- add cache fields to `ReconcilerCaches`, with reset behavior provided by
  `tearDownCurrentSession` reinitializing the cache struct;
- apply deltas in a thin `reconcileX()` executor, including explicit remove
  behavior when a projection disappears but the host view survives;
- delete the matching `Command` case, `perform` arm, and emission sites in the
  same change.

Reconcile pass ordering is part of the contract. Passes that destroy or recreate
hosts must run before passes that render into those hosts, and they must
invalidate affected host-local caches. Surface teardown runs before container
reconciliation; container reconciliation runs before pane chrome; mount-time
focus runs after pane chrome when it may target a search field the chrome pass
creates; occlusion remains last because it reads the final visible/mounted
surface state.

Post-reconcile commands target views that reconcile creates. `Command.isPostReconcile`
must stay an exhaustive switch with no `default`, so adding a command requires an
explicit phase decision.

Reconcile scheduling may coalesce only changes whose delayed application is
semantically safe. Today that means high-frequency cosmetic surface metadata.
Structural/container-affecting messages reconcile inline. Any future coalescing
of structural messages must first add a behavioral popover/surface sync test
that proves model state, AppKit teardown, and post-reconcile commands stay
aligned.

If external state changes what a projection should apply while the model value
looks unchanged, prefer an explicit model event or generation value included in
the projection over imperative cache pokes. This keeps the pass model-driven and
unit-testable, as with the pane-config generation pattern.

Restore and session replacement are outside ordinary `Msg` handling. They may
replace the whole model and may directly clear ephemeral runtime/model slots
while tearing down a live session. These bypasses must reset `ReconcilerCaches`
before the post-restore reconcile so the next pass is a clean build, and the
write site must explain why it bypasses `update()`.

Other exceptions to read-only reconcile require either an ADR update or an
explicit in-code justification plus a behavioral test proving the exception does
not observe stale, double-written, or out-of-order state.

## Consequences

"What is the model after message X?" is answerable from `update()` and from
documented session-replacement code, not from a later AppKit projection pass.
The pure layer remains the behavioral test boundary; AppKit executors stay small
and are verified by focused manual QA where the test harness cannot import
AppKit or GhosttyKit.

Commands remain true commands. Reintroducing a command whose only job is to make
the view match the model is a design smell; it should normally be a pure
projection plus a reconcile pass instead.

Some conditions are expressed twice in layer-appropriate forms. For TODO
popovers, `update()` clears `model.todoPopover` by comparing model state before
and after a message, while `reconcileContainers` dismisses AppKit popovers from
the live `ContainerOp` diff and the previously visible container. That
duplication is accepted because each half reads the inputs its layer owns. Tests
keep the behavioral boundary aligned.

The cost of the rule is occasional extra model helpers, generation counters, or
`ViewLocalState` plumbing. The payoff is stronger directionality: `update()`
owns domain/model transitions, `Command` owns true external effects, and
`reconcile()` owns rendering the current model into AppKit and surface state.

## References

- `AGENTS.md`: Elm architecture and data flow
- `app/Reconcile.swift`: reconciler template, pass ordering, `ReconcilerCaches`
- `app/ModelOperations.swift`: pure projections, diff/op helpers, reconcile scheduling
- `plans/impl/2026-05-26-tree-owns-panes-reconciler.md`: main reconciler migration plan
- `plans/impl/2026-05-27-coalesce-reconcile-sweeps.md`: reconcile scheduling policy
- `plans/impl/2026-05-27-quit-confirmation-reconcile.md`: single-optional panel projection precedent
- `plans/impl/2026-05-27-preferences-draft-panel-visibility.md`: panel visibility as a model projection
- `plans/impl/2026-05-27-reconcile-pane-config.md`: model-generation invalidation for external config reloads
```

Add to `docs/design/index.md` under `## Notes`:

```markdown
- [2026-05-27: Read-Only View Reconciler](2026-05-27-read-only-reconciler.md)
```

## Design notes

- **Equivalence with the reconciler's predicate.** "An op strands the previously-visible
  tab" (`containerOpsStrandVisible`) reduces to "selection changed OR the selected tab's
  shape drifted" -- exactly `reconcileTodoPopover`'s clear triggers. So the 13 view-swap
  cases covered by the current predicate stay covered; only the same-tab-navigate case
  changes (preserve).
- **Two halves, two layers, two signals -- intentional.** The model half (update, model
  before/after) and the AppKit half (reconciler, live `tabContainers` ops) read different
  inputs by design. Today, container-affecting messages reconcile inline:
  `Msg.coalescesReconcile` is limited to high-frequency surface metadata, so view-swap
  messages run `reconcile()` immediately after `update()`. If future scheduling coalesces
  container-affecting messages, add a behavioral popover-sync test that proves the model
  clear and AppKit dismiss stay aligned before enabling it.
- **Recursion is safe.** `update()` calls itself (`selectAdjacentTab`, last-pane
  `closePane`, `navigateToPane`). `reconcileTodoPopover` is clear-only (monotonic) and
  guarded on `todoPopover != nil`, so a nested defer clearing first just makes the outer
  defer a no-op.
- **One behavior change:** same-tab navigate-to-pane preserves the record instead of
  nil-ing it (the desync fix), pinned by the new IPC test.

## Verification

- `just test` -- the converted `containerOpsStrandVisible` predicate test, the new
  `reconcileTodoPopover` group, and the IPC preserve test pass; full suite green.
- `just build` -- compiles after deleting `reconcilePopover` / `StrandedPopoverOutcome`
  (confirm no remaining references) and the `navigateToPane` cleanup.
- Manual QA (`just build-run`):
  - Open a pane TODO popover, then switch tabs / split / zoom the pane -> popover
    dismisses.
  - Open a pane TODO popover, then programmatically focus a different pane in the same
    unzoomed tab with `danterm pane focus <pane-id>` -> popover stays, and re-toggling
    re-opens it (proves the record is still set -- no desync).
  - Open a pane TODO popover, then mouse-click a different pane in the same unzoomed tab
    -> AppKit closes the transient popover via the delegate callback, and re-toggling opens
    it cleanly (proves no stale record).
  - Repeat the view-swap dismiss and click-away stale-record checks with a tab TODO popover.

## Out of scope

- The alternative consistent design -- moving `todoPopover` out of `AppModel` into
  `ViewLocalState` so the view layer owns it end-to-end -- is viable but larger and not
  needed: `update()` reads `todoPopover` for its guards, so it is genuinely model state.
- The existing `advanceSidebarCache` characterization test stays as-is.
