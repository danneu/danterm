# The sidebar has one reconcile driver, one group painter, one op interpreter

## Context

Three findings in `docs/scratch/2026-08-11-simplification-audit.md` -- S33,
S44, S58 -- are the remaining sidebar entries. They are one effort because
they all describe the same seam from different sides: the row-op pipeline has
no single owner, so the pipeline is copied into tests, the group row is
painted twice, and the op script is interpreted twice.

`8c34a41f` settled the adjacent data-flow question (the interaction path reads
the last-applied `SidebarProjection`, not `runtime.model`). That commit's UI
run is also the evidence for S33: it broke the four hand-written pipeline
copies in `tests-ui/`, which is exactly the failure mode the finding predicts
-- a production change that the copies must be edited to match, one file at a
time, with nothing forcing them to agree.

Three duplications, current as of this tree:

1. **The pipeline is re-implemented in tests.** `reconcileSidebar`
   (`app/Reconcile.swift:226`) runs six steps: `desiredSidebar` ->
   `computeSidebarRowOps` against `caches.sidebar` -> read the view-owned
   rename sidecar -> `guardSidebarRenameOps` -> `applySidebarOps` ->
   `advanceSidebarCache`. `app/Reconcile.swift` is deliberately absent from
   `test-ui.sh`'s source list (the harness substitutes a fake `AppRuntime`),
   so no UI test can call it. Five test files therefore build their own:
   `SidebarProjectionRowTests` (`applyProjectionRowTransition`),
   `SidebarRenameRecycleTests` (`applyRenameRecycleTransitionResult`),
   `SidebarSelectionCacheTests` (`applySidebarTransitionResult`, which
   **omits the rename guard entirely** and hardcodes
   `suppressedRenameTarget: nil`), plus inlined initial-apply copies in
   `SidebarContextMenuTests` and `SingleLineLabelTests`. Two of the copies
   carry a `runtime: AppRuntime` parameter their bodies never read. The
   materialize-rows loop exists four times, the outline finder five times, the
   row lookup twice, the bell-alert fixture three times.

2. **The group row has two painters.** `SidebarView.applyGroupCollapseState`
   repaints a group cell from a `collapsed: Bool` parameter, while
   `updateGroupRow` paints the same cell from the item's stored projection
   through `SidebarGroupCellView.apply`. `applyGroupCollapseState` mutates a
   *local copy* of the projection, so the painted cell and the item payload can
   disagree. It is also redundant work on the delegate path: the
   `.toggleGroupCollapse` send in `outlineViewItemDidCollapse` /
   `outlineViewItemDidExpand` reconciles synchronously, emits a
   `setGroupCollapsed` op, and repaints the row before the delegate's own call
   runs.

3. **The op script is interpreted twice.** `SidebarItemStore.apply` switches
   over all eight `SidebarRowOp` cases and answers a `Bool`. `applyRowOp`
   switches over the same eight and re-derives what the store already decided
   with: the parent item (`groupItemCache[groupId]`), the index, and the
   single-vs-multi-group branch -- which it reads from `isSingleGroupMode`
   (the view's stored projection) while the store reads it from the passed
   projection. Two sources for one predicate. The three reload-ish cases
   (`.reloadTab`, `.reloadGroup`, `.setGroupCollapsed`) also write the item
   payload twice: `store.apply` calls `updateTabItem`/`updateGroupItem`, then
   `updateTabRow`/`updateGroupRow` calls the same method again with the same
   projection.

The audit's Status column must end up truthful about all three.

## Decision

One production reconcile driver, one projection-fed group painter, one op
interpreter.

- **D1 -- a `SidebarReconcileDriver` value owns the pipeline and the diff
  cache.** New file `app/SidebarReconcileDriver.swift`, promoted into
  `test-ui.sh`'s source list. It holds the `SidebarProjection?` diff cache and
  exposes one entry point that takes an `AppModel`, an `UnreadAlertTally`, and
  the `SidebarView` to drive; a tally-less convenience overload mirrors
  `desiredSidebar(in:)` for callers that have no tally in hand.
  `reconcileSidebar` shrinks to a guard plus one driver call.
  `ReconcilerCaches.sidebar` is deleted, and re-creating the driver is what
  `tearDownCurrentSession`'s `caches = ReconcilerCaches()` reset becomes --
  the reset is the driver's construction, not a second mechanism.

  It is a separate type rather than a method on `SidebarView` so the view stays
  a renderer and executor, and so "fresh driver" keeps meaning "next pass is a
  full rebuild" without a reset method on the view. It does not touch
  `AppRuntime`, which is why the substituting harness can compile it.

- **D2 -- the UI tests drive the driver, and the copies are deleted.** All
  five test files construct a driver and call it. The three transition helpers,
  the two inlined initial-apply blocks, the four materialize loops, the five
  outline finders, the duplicate row/cell lookups and bell-alert fixtures
  collapse into one shared `tests-ui/` helper file (also promoted into
  `test-ui.sh`). `applySidebarOps` keeps only one caller -- the driver -- and
  says so in its doc comment.

  `SidebarSelectionCacheTests` gains the rename-guard step it was missing, so
  its cache-retention assertions start describing the shipped pipeline.

- **D3 -- `SidebarItemStore.apply` returns the AppKit mutation, not a Bool.**
  The result names exactly the outline work and everything needed to do it:
  nothing to do; a full rebuild (carrying each group item's desired collapse
  state, so `restoreCollapseState` stops re-walking the projection); insert
  rows at an index under a parent item; remove rows at an index under a parent
  item; set an item's collapsed state; repaint an item. `applyRowOp` becomes a
  switch over that result and re-derives nothing -- no parent lookup, no index
  recomputation, no `isSingleGroupMode` read.

- **D4 -- reload ops update the store exactly once.** With the item arriving in
  the mutation result, `updateTabRow` / `updateGroupRow` take the
  `SidebarItem` to paint instead of a bare id, and stop calling back into the
  store. They keep returning the "on-screen row could not fetch its cell" Bool
  that feeds `advanceSidebarCache`'s retention.

- **D5 -- one group painter.** `applyGroupCollapseState` is deleted. The
  `setGroupCollapsed` executor issues the outline collapse/expand and then
  paints through the same path `reloadGroup` uses, from the item's own
  projection, tracking its unapplied group id the same way. The calls in
  `outlineViewItemDidCollapse` / `outlineViewItemDidExpand` are dropped
  entirely; those handlers keep only the `.toggleGroupCollapse` send, which
  already reconciles and repaints. `Update.swift`'s unconditional toggle is
  what makes that guaranteed.

- **D6 -- one final commit records the outcome in the audit file.** A commit
  cannot carry its own sha, so commits 1-3 leave
  `docs/scratch/2026-08-11-simplification-audit.md` untouched and a fourth
  commit records all three at once, when every sha is known: the Status column
  for S33, S44 and S58, a **Status note** in each `### SNN` section saying what
  landed (the file's own rule is that a sha'd row means the section describes
  code that no longer exists), and the "Settle these first" sidebar bullet
  rewritten from "S33 and S44 remain as follow-on work" to say the sidebar
  thread is closed.

## Invariants

- **I1 (one pipeline).** Exactly one implementation of the six-step sequence
  exists in the tree. No file under `tests-ui/` calls `desiredSidebar`,
  `computeSidebarRowOps`, `guardSidebarRenameOps`, `advanceSidebarCache`, or
  `applySidebarOps` to assemble a pass of its own; every UI test that drives
  the sidebar goes through the driver.
- **I2 (step order preserved).** The driver runs guard-before-apply, and reads
  the rename sidecar twice exactly as production does today: once before the
  guard, and once *after* apply for `advanceSidebarCache`'s
  `suppressedRenameTarget`, so a rename that `applySidebarOps` ended yields nil
  there.
- **I3 (fresh driver == full rebuild).** A newly constructed driver has no
  cache, so its first pass emits `reloadAll`. Session teardown constructs a new
  driver; nothing else clears the cache.
- **I4 (the store decides, the bridge obeys).** For every op, the decision of
  whether the outline mutates, under which parent, at which index, and in which
  group mode is taken once, inside `SidebarItemStore.apply`. The executor
  performs the returned mutation and takes no such decision of its own. The
  store never mutates while returning a result the executor drops on the floor.
- **I5 (one payload write per reload).** Applying a `reloadTab`, `reloadGroup`
  or `setGroupCollapsed` op writes the item's projection payload exactly once.
- **I6 (one group painter).** A group cell's caret, bell badge and tab-count
  badge are painted from one code path, fed only by the item's stored
  projection. No painter takes a collapse flag as a parameter, so the painted
  caret and the item payload cannot disagree.

## Proof obligations

Pure-layer obligations are Swift Testing in
`lib/DanTermCore/Tests/DanTermCoreTests/`; UI-layer ones are `uiTest` cases in
`tests-ui/`. Each names the claim; the cases are the implementer's.

- **PO1 (I4, I5).** `SidebarItemStoreTests` retargets from the Bool to the
  mutation result: for each op, a valid application yields the mutation naming
  the same parent, index and item the current executor re-derives, and a
  rejected application (out-of-range index, unknown id, wrong group mode, a
  structural op in the wrong single/multi mode) yields "nothing to do" with the
  store snapshot unchanged. `applyContractMissingStructuralOpsSkipMutations`
  is rewritten rather than kept: it currently pins the reload ops returning
  `true` for an unknown id, which the mutation result replaces with "nothing to
  do".
- **PO2 (I3).** The scenario must be able to fail: a fresh driver applied to a
  *fresh, empty* view materializes every row the model calls for. Driving a
  second driver at the already-populated view proves nothing, because a
  correctly-rebuilding driver and one that wrongly kept the first driver's
  cache both leave the same rows on screen. So: apply driver A to view A, then
  apply a newly constructed driver B to an empty view B under the same model,
  and assert view B shows the full row set. Assert on observable rows, not on
  the cache field.
- **PO3 (I2, I1).** The rename-guard behavior the copies were testing survives
  through the driver: a reload of the live-editing row is suppressed while
  structural ops apply; a structural op on that row ends the edit; the
  suppressed row's prior projection is retained so the deferred attribute
  update re-fires on a later pass. `SidebarSelectionCacheTests`' retention
  cases now run with the guard in place.
- **PO4 (I6).** Collapsing and expanding a group -- through the disclosure
  triangle, through the caret button, and through a model-driven
  `setGroupCollapsed` op -- leaves the caret glyph, bell badge and tab-count
  badge matching the projection in every case. The existing
  `SidebarProjectionRowTests` group-chrome case covers the model-driven path;
  the delegate paths are what the deletion puts at risk and need their own
  cases.
- **PO5 (I1).** The sidebar UI suites keep passing while every helper they used
  to own is gone -- the suites are the regression net for the driver
  extraction, which is why the driver lands first.

## Non-goals

- Changing what the sidebar shows, when it diffs, or the shape of
  `SidebarProjection` / `SidebarRowOp`. This is one behavior-preserving
  refactor; a projection field change would be separate work.
- Making `tests-ui` an ordinary SwiftPM test target. The whole-module
  substitution seam stays as
  `docs/design/2026-08-06-ui-harness-whole-module-substitution.md` decided;
  promoting two files into `test-ui.sh` is the known cost of that seam, paid
  here.
- The other open sidebar-adjacent audit rows (S13, S25) and the sidebar
  pane-rows feature in `TODO.md`.
- Deduplicating `updateTabRow` and `updateGroupRow` into one generic painter.
  They are structurally identical modulo id type, store method and cell class,
  and that is worth doing -- but it is a fourth finding, not part of these
  three, and folding it in would blur what the S44/S58 status notes claim.

## Accepted risks

- **AR1.** `test-ui.sh`'s source list is hand-maintained and rots silently; two
  new files are two more entries. The ADR above already accepts this, and a
  missing entry fails `just test-ui` loudly at compile time.
- **AR2.** Deleting the delegate-path `applyGroupCollapseState` calls makes the
  caret depend on the `.toggleGroupCollapse` send producing a model change and
  a synchronous reconcile. `Update.swift`'s toggle is unconditional, so this
  holds today; PO4's delegate cases are what keep it holding.
- **AR3.** The mutation result must preserve the exact index semantics the
  sequential op script relies on. Inconsistent NSOutlineView batch indices
  crash hard rather than degrade, so the store's index guards move verbatim.

## Implementation discretion

- The spelling of the mutation result (enum case names, whether the collapse
  states ride on the rebuild case or come from a separate store accessor) and
  of the driver's entry point.
- Whether the driver is a struct held by value or a final class; either
  satisfies I3 as long as construction is the only reset.
- How the shared `tests-ui/` helper file is split, and whether it absorbs the
  duplicated model fixtures (`sidebarSelectionModel`, `renameRecycleModel`, the
  three bell-alert builders) or only the outline/row/cell utilities.

## Verification

1. `swift test --package-path lib/DanTermCore` for the store and projection
   suites, then `just test`.
2. `just test-ui > .build/ui.log 2>&1` from a GUI session, then grep the log.
   This is the load-bearing run for the whole plan: it is the only place the
   driver and the AppKit executors are exercised together.
3. `bash ./dev-build.sh --no-install` to confirm the app target compiles.
4. End to end in an isolated slot (`just launch-slot`, explicit
   `danterm --socket <slot>`):
   - Collapse and expand a group by the disclosure triangle and by the caret
     button; the caret, bell badge and tab-count badge all update, and the
     state survives switching tabs.
   - Create and delete groups, move a tab between groups, and flip between
     single-group and multi-group mode; rows land in the right parent with no
     outline crash.
   - Start an inline rename on a tab, then close that tab from another
     terminal via `danterm tab close --tab <id>`, and separately start a rename
     and collapse its group; in both cases the edit ends and the row does not
     strand a blank title.
   - Rename a group while its row is being reloaded by unrelated activity (run
     a command in a pane of that group to churn the projection); the typed text
     is not overwritten, and the row picks up the pending attrs after the edit
     ends.
   - Restore a session (quit with `danterm --socket <slot> quit`, relaunch);
     the sidebar rebuilds from scratch rather than diffing against a stale
     cache.
5. `python3 scripts/docs-lint.py` (or the gate step that runs it) after the
   audit-file edits.

## Commit progress

- [x] 1. refactor(sidebar): one reconcile driver the UI tests drive
      (D1, D2; I1, I2, I3; PO2, PO3, PO5 -- adds
      `app/SidebarReconcileDriver.swift` and the shared `tests-ui/` helper,
      deletes `ReconcilerCaches.sidebar` and all five test-side pipeline
      copies)
- [x] 2. refactor(sidebar): the store returns the outline mutation
      (D3, D4; I4, I5; PO1 -- rewrites `SidebarItemStore.apply`'s return,
      `applyRowOp`, `updateTabRow` / `updateGroupRow`, and
      `SidebarItemStoreTests`)
- [ ] 3. refactor(sidebar): one projection-fed group painter
      (D5; I6; PO4 -- deletes `applyGroupCollapseState` and its two delegate
      calls)
- [ ] 4. docs(audit): close the sidebar thread
      (D6 -- records the shas of commits 1-3 in the S33, S58 and S44 rows,
      adds each section's Status note, and rewrites the "Settle these first"
      sidebar bullet)
