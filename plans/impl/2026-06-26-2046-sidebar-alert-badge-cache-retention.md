# Fix: sidebar alert badge can wedge out of sync with the toolbar bell

## Context

A tab kept showing an alert badge in the sidebar while the toolbar bell badge
showed nothing, and clicking the tab did not clear it. This is a real
correctness bug, reproduced by static analysis of the reconcile path.

Both badges are computed from one tally in one reconcile pass
(`Reconcile.swift:87` -> `reconcileSidebar(tally:)` line 94 and
`reconcileWindowChrome(tally:)` line 95), so they cannot disagree about the
live model within a pass. The observed state (tab badge > 0, bell = 0) is
therefore a *temporal* desync: the sidebar cell is stuck displaying an older
count.

Root cause -- an asymmetry between two reconcile executors:

- The bell (`reconcileWindowChrome`, `Reconcile.swift:287`) is idempotent:
  compute projection, bail if it equals the cache, else re-apply every channel.
  It always tracks `tally.total`. Robust.
- The per-tab badge executor `updateTabRow` (`SidebarView.swift:479`) is
  best-effort: it silently no-ops when the row's cell is not fetchable at that
  instant -- `store.updateTabItem` nil, `row(forItem:) < 0` (collapsed child),
  or `view(atColumn:row:makeIfNecessary:false)` nil (transiently
  un-materialized during a batch that also has structural ops).
- Critically, `reconcileSidebar` then advances the cache **unconditionally**
  via `advanceSidebarCache` (`Projections.swift:617`), which only exempts the
  inline-rename row. So a dropped `reloadTab` still advances
  `caches.sidebar[T]` to the cleared count. From then on the diff sees
  `cache == model`, so no future reconcile re-emits the op -- the cell is
  wedged. Clicking the tab can't fix it: `applySelectTab` early-returns when
  the tab is already selected (`Update.swift:2192`), and even otherwise the
  recomputed projection equals the advanced cache, so no `reloadTab` is
  emitted.

Offscreen/collapsed rows self-heal (re-materialization runs
`viewFor -> makeTabCell -> configureTabCell`, which reads the live
`currentModel`, `SidebarView.swift:574,1282,1307`). The wedge is exactly the
row that stays materialized after a dropped op.

The fix restores the cache's load-bearing invariant: **the cache entry for a
row must equal the value last painted into its cell.** This mirrors the
already-blessed rename-suppression retention in `advanceSidebarCache`
(`Projections.swift:609-616`), which retains the prior projection for a
suppressed row so its deferred reload re-fires later.

Note: `caches.sidebar` has exactly two readers, both diff-only
(`computeSidebarRowOps` at `Reconcile.swift:257`, `advanceSidebarCache` at
line 272). Nothing renders from it. So retaining an old entry can only make
the diff emit *more* ops, never fewer, and the eventual repaint always sources
the live count from `currentModel` -- retention cannot mask a newer count.

## Approach: retain-on-drop

Make the per-row badge update report when it failed to land, and have the pure
cache-advance retain those rows' prior projections so the next reconcile
re-emits the `reloadTab`/`reloadGroup` and -- the row now fetchable -- repaints.

### 1. Executors report "wedged" (`app/SidebarView.swift`)

Change `updateTabRow` (479) and `updateGroupRow` (492) to return `Bool`
meaning *wedged -- retain in cache*. Split the combined guard so the three
outcomes are distinguishable:

- painted successfully -> return `false` (no retain)
- `store.updateTabItem`/`updateGroupItem` nil (row gone from model) -> `false`
  (structurally inert; no slot in `new` to retain into anyway)
- `row < 0` (collapsed child, not materialized) -> `false` (self-heals on
  expand via `viewFor`)
- `row >= 0` but row off-screen
  (`!outlineView.visibleRect.intersects(outlineView.rect(ofRow: row))`), cell
  nil -> `false`. AppKit discards off-screen cell views, so a nil cell here is
  ordinary, not a wedge; the row self-heals via `viewFor` when scrolled back.
  Retaining it would re-emit `.reloadTab` every reconcile until it scrolls
  into view -- needless churn (the F1 over-retention case). This is the same
  visibility predicate the UI harness already uses
  (`assertSidebarRowOffScreen`/`assertSidebarRowVisible`,
  `tests-ui/SidebarSelectionCacheTests.swift:479-503`).
- `row >= 0`, row **visible**, but `view(atColumn:row:makeIfNecessary:false)`
  nil -> `true` (the genuine wedge: on-screen yet not fetchable this cycle --
  e.g. transiently un-materialized mid-batch alongside structural ops -- so
  nothing re-triggers a configure). Evaluate the visibility check at the same
  instant as the cell fetch.

Name the return for its meaning (e.g. `-> Bool // wedged`), not "painted", so
callers don't conflate "painted" with "nothing to retry".

### 2. Accumulate dropped ids (`app/SidebarView.swift`)

There are **four** call sites; all must feed one accumulator:

- `applyRowOp` `.reloadTab` arm (338) and `.reloadGroup` arm (310)
- `applyRestoreSelection` rename-resync (430-431) -- the latent twin the
  reported bug shares: when a selection change ends a live rename, these inline
  resync calls can wedge the just-suppressed row, and the cache then advances
  with `suppressedRenameTarget == nil`.

Thread two `inout` sets (`Set<TabId>`, `Set<GroupId>`) through `applyRowOp`
and `applyRestoreSelection`; insert the id when the executor returns `true`.
`applySidebarOps` (244) returns the accumulated
`(tabs: Set<TabId>, groups: Set<GroupId>)`.

### 3. Extend the pure cache-advance (`lib/DanTermCore/Sources/DanTermCore/Projections.swift`)

Add two params (default `= []` so the existing call/tests stay source-compatible):

```swift
func advanceSidebarCache(
  old: SidebarProjection?, new: SidebarProjection,
  suppressedRenameTarget: RenameTarget?,
  unappliedTabIds: Set<TabId> = [], unappliedGroupIds: Set<GroupId> = []
) -> SidebarProjection
```

Compose with -- do not replace -- the rename retention: start from the
rename-merged result, then for each unapplied tab id retain its old full
projection (mirror lines 624-632), and for each unapplied group id retain its
old reload-attrs only (`name`/`unreadAlertCount`/`tabCount`/`isFirst`, mirror
636-640) -- never collapse/tabs (structural, applied independently). Factor the
per-entry retain into a small helper reused by both the rename branch and the
dropped-id loop. Skip ids with no matching old entry or no new slot
(structurally inert).

Rename-target / dropped-set interaction: a guard-suppressed reload normally
does not enter the dropped set (its op is suppressed, not dropped, so the
rename retention is its only retainer). But the `applyRestoreSelection`
rename-resync path clears `sidebarRenameTarget` *before* re-running
`updateTabRow`/`updateGroupRow` (`SidebarView.swift:427` -> 430-431), so that
just-cleared target can both wedge and land in the dropped set while
`advanceSidebarCache` sees `suppressedRenameTarget == nil`. So do not assume
the two retentions are disjoint: retain every dropped id regardless of rename
state, and if a dropped id ever coincides with the suppressed-rename target,
both branches retain the same old projection, so they compose idempotently.

### 4. Wire it up (`app/Reconcile.swift:267-273`)

Capture `applySidebarOps`'s returned dropped sets and pass them into the
extended `advanceSidebarCache` call.

## Critical files

- `app/SidebarView.swift` -- executor return values + accumulator (changes 1-2)
- `lib/DanTermCore/Sources/DanTermCore/Projections.swift` -- `advanceSidebarCache` (change 3)
- `app/Reconcile.swift` -- wiring (change 4)
- `lib/DanTermCore/Tests/DanTermCoreTests/ReconcileTests.swift` -- pure regression tests
- `tests-ui/SidebarSelectionCacheTests.swift` (+ `SidebarRenameRecycleTests.swift`) -- app-layer bridge regression

## Tests

Pure regression test in `ReconcileTests.swift`, modeled on the existing
`advanceSidebarCacheRetainsSuppressedAttrs` (362-415) and reusing its
file-private helpers (`sbProj`, `sbGroup`, `sbTabFull`, `computeSidebarRowOps`).
Behavioral, structure-insensitive assertions:

1. **Retain re-emits.** old: tab A bell=1; new: tab A bell=0. With
   `unappliedTabIds: [A]`, the returned cache keeps A at bell=1, and
   `computeSidebarRowOps(old: returned, new:)` contains `.reloadTab(A)`. This
   is the core invariant: a dropped paint stays pending instead of being
   silently swallowed.
2. **Empty set advances fully.** Same projections, empty unapplied sets ->
   returns `new` (A=0) -> `computeSidebarRowOps` emits no `.reloadTab(A)`
   (guards against over-retention churn).
3. **Group variant.** `unappliedGroupIds: [G]` retains G's old
   `unreadAlertCount` so `.reloadGroup(G)` re-emits; collapse/tabs still take
   `new`.
4. **Composition.** A rename target on tab B plus a disjoint dropped tab A in
   one call: both B (rename) and A (dropped) keep old projections; an
   unrelated sibling takes `new`.

The existing test at 362-415 keeps passing unchanged (defaulted params).

### App-layer bridge (`tests-ui/`, AppKit UI harness)

The pure tests above pin the cache semantics but cannot catch a miswired
bridge -- a wrong `updateTabRow` return polarity, `applySidebarOps` dropping
the accumulated sets, or a missed rename-resync call site would all leave them
green. Add a focused regression alongside the existing real-SidebarView suites
(`SidebarSelectionCacheTests.swift` / `SidebarRenameRecycleTests.swift`), which
already drive a real `SidebarView` + `NSOutlineView` + `NSWindow` through
`applySidebarOps` (`makeSidebarSelectionHarness`, `applySidebarTransition`,
`materializeSidebarRows`) and ship the visibility helpers change 1 reuses
(`assertSidebarRowVisible` / `assertSidebarRowOffScreen`,
`SidebarSelectionCacheTests.swift:479-503`).

**Harness gap to close first.** The existing `applySidebarTransition`
(`SidebarSelectionCacheTests.swift:314`) returns `newProjection` directly and
never calls `advanceSidebarCache`, so feeding it back as the next `old` models
the *old* unconditional-advance behavior and skips the retain-on-drop contract
entirely -- a convergence test built on it would pass trivially. Cases 4 and 5
must run through a production-faithful helper that mirrors `reconcileSidebar`:
capture the dropped sets `applySidebarOps` now returns and seed
`advanceSidebarCache(old: oldProjection, new: newProjection,
suppressedRenameTarget:, unappliedTabIds: dropped.tabs,
unappliedGroupIds: dropped.groups)`, returning *that advanced projection* as
the `old` for the next transition. Either thread this into
`applySidebarTransition` (backward-compatible: with empty drops and a nil
rename target, `advanceSidebarCache` returns `new`, so existing callers are
unaffected) or add a sibling helper for the bridge tests.

Assert:

1. **Painted row reports not-wedged.** A visible, materialized tab row whose
   badge changes: `updateTabRow` returns `false` and `applySidebarOps` returns
   empty dropped sets. Guards against an always-`true`/inverted return.
2. **Off-screen row is not retained.** With an overflow model
   (`sidebarOverflowModel`) so some rows scroll off-screen, reload an
   off-screen tab: its id is absent from the returned dropped set. Guards
   change 1's visibility boundary against the F1 churn case.
3. **Genuine wedge accumulates.** Drive one deterministic visible-row /
   nil-cell trigger -- e.g. an op batch that interleaves a structural op
   (insert/remove) with a `.reloadTab` for a still-visible row AppKit has not
   yet materialized, run through `applySidebarOps` without pre-materializing
   that row, so `view(atColumn:row:makeIfNecessary:false)` is nil at executor
   time (this mirrors the real incident: a coalesced reload riding a batch that
   also carries structural ops). Assert `updateTabRow` returns `true` and the
   id appears in `applySidebarOps`'s returned tab set. This is the *same*
   trigger case 4 reuses.
4. **Convergence repaints.** Reusing case 3's dropped paint (the retention-aware
   helper retained the old count in the cache), run a second transition through
   that same helper -- now materializing the row -- so the re-emitted
   `.reloadTab` finds the fetchable cell and the visible badge equals the live
   model count. The user-facing guarantee -- and it only holds if (a) case 3's
   drop is a *real* `applySidebarOps` drop, not a hand-seeded `unappliedTabIds`,
   and (b) the second diff runs against the *retention-advanced* cache, not
   against `newProjection`.
5. **Rename-resync site is wired.** Extend a `SidebarRenameRecycleTests`
   scenario where a selection change ends a live rename: a dropped inline
   resync feeds the accumulator (covers the fourth call site, 430-431). Drive
   re-emit through the same retention-aware helper so the suppressed target
   threads into `advanceSidebarCache` as production does.

Cases 1 and 2 are deterministic on their own. Cases 3 and 4 **share one
deterministic trigger** (the visible-row / nil-cell drop above) and stand or
fall together: case 4's whole point is that the drop flowed through the real
app-layer bridge, so it must consume case 3's genuine `applySidebarOps` drop,
never a hand-seeded `unappliedTabIds` (that bypasses the bridge this section
exists to cover). Case 5 needs the rename-resync variant of the same trigger.
If no in-harness trigger can be built, cases 3 *and* 4 are both infeasible as
written -- do not keep 4 alone. Then add a deterministic test seam (e.g. a
test-only hook that forces the nil-cell branch of `updateTabRow`) so the bridge
is still exercised end-to-end before claiming bridge coverage; only if even
that is rejected do you drop to cases 1/2 plus reasoning, and then state
plainly that the dropped-set bridge is unverified. The pure tests remain the
primary guarantee for retain/re-emit semantics regardless.

## Verification

1. `just test` -- runs protocol XCTest + core Swift Testing (incl. the new
   `ReconcileTests` cases) + core-purity lint + shell self-tests. Must pass.
2. `just test-ui` (GUI session only) -- compiles and runs the AppKit UI
   harness, including the new bridge regression. Needs a WindowServer
   connection, so it is outside the `just test` gate and fails headless; run
   it from any logged-in GUI shell (an agent's included). Must pass.
3. Optional manual smoke (`just build-run`): in a split tab, drive a
   background-pane bell storm (`printf '\a'` loop in the non-focused pane while
   another tab is selected), confirm the sidebar tab badge and the toolbar
   bell badge agree, then clear via the alerts popover and confirm both drop to
   zero together and stay in sync.

## Out of scope (related but separate, not this incident)

- `tally.total` counts stale-pane alerts while `byTab` is tree-restricted
  (`ModelOperations.swift:718-728`) -- a documented divergence that makes the
  bell over-count, the opposite direction; not the reported symptom.
- `applySelectTab` clears only `tab.focusedPaneId` (`Update.swift:2202`), so a
  split tab's non-focused-pane alert survives a tab click -- a real but
  separate "click doesn't clear" path (there the bell *would* show a count).

## Implementation notes

- The UI bridge tests use a `DANTERM_UI_TEST`-only `SidebarView` hook to force
  the next row cell fetch to behave like a visible nil-cell drop. That keeps
  the dropped-id accumulator covered end-to-end without relying on AppKit view
  recycling timing.
