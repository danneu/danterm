# Reconcile sweep cost: delete the MRU projection, not just its allocations

Follow-up to `plans/impl/2026-08-31-1859-reducer-per-message-budget.md`, whose
probe fired its frozen rule and reopened this work.

## Problem and evidence

Every `Msg` pays `update()`'s unconditional `defer` sweep, and the sweep's
`reconcileTabState` re-derives the live tab set from scratch on every message:
`liveTabIds` builds a `Set<TabId>` (hashing every tab id), and
`tabStateIsCanonical` builds a second one to verify `mruOrder` is a live
permutation (`lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift`, the
`reconcileTabState` / `tabStateIsCanonical` pair). The probe landed in 263e5b38
(`just reducer-dispatch-cost`) measured per-dispatch medians of ~6.6 us at 8
tabs, ~13.9 us at 32, ~41 us at 128 -- ~35 us of the 128-tab cost scales with
tab count, ~35x over the probe's frozen 1000 ns budget bound, on the app's
highest-frequency message (title reports at 30-60 Hz).

The scaling cost exists because `mruOrder` is a stored projection of the tab
tree: a second copy of "which tabs exist", in recency order, that can drift
whenever an arm changes tab membership. The chokepoint therefore verifies the
whole projection against the whole tree on every message. The verification is
the cost; making it allocation-free does not stop it from being O(all tabs,
hashed) work per message.

Desired outcome: the per-message tail does no work that scales with tab count
beyond an allocation-free, hash-free existence check, and the probe's own
frozen rule stops firing.

## Decision

Delete `mruOrder` as stored model state. MRU recency becomes a fact each tab
owns: a monotone focus stamp recorded on the tab whenever it becomes the
selection, including a selection made while a cycle is active. A tab's
recency then dies with the tab -- there is no
projection to drift, so there is nothing for the per-message sweep to verify
or repair. Recency *order* is derived only at the rare read sites: freezing a
cycle's order when one starts, and repairing a dead selection.

What remains in the unconditional tail is one allocation-free check: is
`selectedTabId` still a live tab (early-exit scan of the tree), plus the O(1)
stamp write when the selection is newly focused. The tail stays unconditional
on every path (the MODEL-5 dependency), and it keeps owning selection repair
so removal paths stay silent about selection -- this deliberately does not
foreclose the reconciliation-owned pane-teardown design the prior plan shelved;
a future existence pass can share the same tail.

This is the ideal per the design bar: the simplest structure in which the
per-message scaling cost can't happen is the one with no per-message invariant
to check. Alternatives considered are in `Rejected ideas`.

Behavioral scope: MRU cycling, the switcher panel's displayed order, selection
repair after any removal, and restore all keep their observable behavior
(pinned by I2-I5). `AppModelSnapshot` is unaffected -- MRU state was already
ephemeral and never serialized.

## Invariants

- I1 **Unconditional tail.** The reconcile tail runs on every `update()` call,
  on every path. No dirty flag, generation counter, or per-arm signal gates it.
- I2 **MRU order is focus history.** The order a cycle freezes lists live tabs
  by recency of becoming the selection, most recent first with the current
  selection at the front, and tabs never focused this run trailing in
  flattened group/tab order. Restore starts with empty history: selected tab
  first, then flattened order.
- I3 **Frozen while cycling.** A cycle resolves against the order it froze at
  its start; nothing that happens during the cycle changes that order. Stepping
  the cursor changes no selection and so changes no recency, but any actual
  selection change during a cycle -- the committed choice, or a `.selectTab`
  from another input -- stamps recency like any other. Tabs removed
  mid-cycle disappear from the resolved order with the existing cursor-remap
  behavior.
- I4 **Removal leaves no trace and owes no announcement.** A removed tab
  contributes nothing to any later MRU order, and removal paths still make no
  selection decision of their own: the chokepoint repairs a dead selection to
  the most recently focused survivor, else the first live tab in flattened
  order, else nil. The deliberate-selection exceptions (close family,
  movePaneToTab) keep their behavior.
- I5 **Per-message work does not scale with tab count.** The steady-state
  tail's 128-vs-8-tab median dispatch delta stays under the frozen 1000
  ns/dispatch bound. This is the measured requirement PO1 reads; deleting the
  stored projection is the architectural means, and neither the invariant nor
  the probe asserts that particular operations (allocation, hashing) are
  absent.

## Frozen success criterion

Pre-registered here, before any candidate exists, reusing the instrument and
bound frozen by the prior plan (budget arithmetic, not data: 1000 ns/dispatch
of state-scaling cost at 60 Hz is 0.006% of a core):

- `just reducer-dispatch-cost` on the changed tree, unchanged workload,
  sample count, tab counts, and bound, must print
  `verdict=sweep-is-not-a-per-message-cost` -- the 128-vs-8-tab median delta
  under 1000 ns/dispatch -- with valid coverage, on each of 3 runs on an idle
  machine (the same protocol the firing result used).
- The probe's coverage check reads `model.mruOrder.count`, which this change
  deletes; the coverage read is adapted to an equivalent witness of the new
  representation and must still refuse a verdict (`verdict=not-measured`,
  exit 2) when the workload is deliberately broken, re-verified per
  `agent-docs/measurement-discipline.md`. The decision rule, cells, bound, and
  workload are frozen and do not change.

The criterion is self-controlled (both cells measured in one session by one
binary), so no cross-revision comparison is needed to read it.

## Proof obligations

- PO1 (I5, criterion): the frozen success criterion above, including the
  broken-workload coverage re-verification.
- PO2 (I2, I3): the existing MRU behavioral net stays green --
  `UpdateMruTests`' cycle traversal, wrap, commit/cancel, and mid-cycle
  removal coverage, asserted against observable behavior (which tab is
  selected after cycle messages; the order `mruCycle.frozenOrder` shows the
  switcher), not against a stored `mruOrder`. Tests that today assert
  `model.mruOrder` contents migrate to that observable surface; a migrated
  test must still fail when the behavior it pins is broken. One test is new,
  covering the mid-cycle selection change: start a cycle, select tab A through
  `.selectTab`, cancel, then select tab B outside any cycle; the next cycle's
  frozen order must read B, A, ... -- A's mid-cycle selection stamped its
  recency, matching today's hoist-on-reconcile behavior.
- PO3 (I4): existing selection-repair coverage stays green across every
  removal family (close tab/pane/others, group delete, creation failure,
  restore), including "most recently focused survivor wins" and the
  never-focused fallback order.
- PO4 (I1): the reconcile-dependent tests recorded by the prior plan
  (`UpdateTodoTests` popover preservation, move-pane alert preservation) and
  `reducer-command-discard-lint.sh` stay green.
- PO5 (I2, restore): after a restore with no focus history, one full cycle
  visits tabs in selected-then-flattened order.

## Non-goals / accepted risks / rejected ideas

- **Non-goal:** the non-scaling part of the dispatch cost (the ~6.6 us 8-tab
  floor: alert-feed scan, linear session lookup, command plumbing). The frozen
  rule reads only the scaling delta.
- **Non-goal:** indexing `pane(_:)` / `tabLocation` -- `Model.swift`'s
  no-stored-index trade stands; `selectionSite`'s existing early-exit scans
  are untouched.
- **AR1:** the tail keeps one O(live tabs) early-exit equality scan per
  message (selection liveness). Accepted: it allocates and hashes nothing,
  the budget bound is the arbiter, and removing it would take a stored index
  or a dirty flag (RI2/RI3).
- **RI1: allocation-free rewrite of `tabStateIsCanonical` keeping `mruOrder`.**
  The micro-optimization. Membership testing without a set is O(n^2) or needs
  reusable scratch storage a pure value-type reducer has nowhere to keep; with
  `OrderedSet<TabId>` (checked `references/swift-collections` --
  OrderedCollections gives O(1) membership, BitCollections needs dense indices
  UUID-backed `TypedId`s don't have) the per-message verification against the
  live tree still walks and hashes every tab. The projection, and so the
  scaling verification, survives.
- **RI2: dirty flag / structure generation counter to skip the sweep.** O(1),
  but reintroduces a "remember to signal" obligation on every current and
  future membership-mutating path -- the exact failure mode the chokepoint
  exists to make inexpressible, and already rejected by the prior plan.
- **RI3: cache the live-tab set on the model.** A second stored projection of
  the tree, with its own drift-and-reconcile problem; trades the disease for
  itself.

## Critical files

- `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift` --
  `reconcileTabState`, `tabStateIsCanonical`, `liveTabIds` callers,
  `resolveLiveCycle`.
- `lib/DanTermCore/Sources/DanTermCore/Model.swift` -- `mruOrder` (deleted),
  the tab-owned stamp, `MruCycleState` doc comment.
- `lib/DanTermCore/Sources/DanTermCore/Update.swift` -- the `defer` tail,
  `mruCycleStep`'s freeze.
- `scripts/reducer-dispatch-cost-probe.swift` -- the coverage read only.
- `lib/DanTermCore/Tests/DanTermCoreTests/UpdateMruTests.swift` and the other
  suites asserting `model.mruOrder`.

## Verification

TDD the migrated behavioral tests first; `swift test --package-path
lib/DanTermCore` plus `just lint` in the loop; `just test` before commit;
`just test-tooling` for the probe's coverage change; then the frozen success
criterion's three probe runs.

## Implementation discretion

- The stamp's representation (counter placement, type, how "already newest" is
  detected without a scan) and the derivation sites' mechanics, provided I2-I5
  hold and the criterion passes.
- The probe's adapted coverage witness, provided the frozen decision rule,
  cells, bound, and workload are untouched and the broken-workload check
  still refuses a verdict.

## Implementation notes

- **Stamp representation.** Each `TabModel` owns a `UInt64 focusStamp`, and
  `AppModel` owns one `focusClock` that names the newest stamp handed out.
  "Already the newest focus" is therefore a stamp-versus-clock equality, not a
  search: a steady selection costs one comparison per message. Stamp 0 means
  "never focused this run", which doubles as the tie-break `tabsByRecency` and
  the repair fallback both need -- ties resolve to flattened group/tab order.
- **The tail stamps on every path.** `reconcileTabState` stamps a live selection
  and a repaired one alike, so "the selected tab carries `focusClock`" holds
  after every message. `tabsByRecency` gets "the selection leads the order" from
  that invariant instead of a separate hoist step.
- **The cycling guard is gone.** The old code skipped the hoist while
  `mruCycle != nil`. Nothing replaces it: a selection made mid-cycle stamps like
  any other (I3), and the cycle is unaffected because it resolves against the
  order it froze. Observable behavior is unchanged -- the old code hoisted the
  same tab on the first reconcile after the cycle ended.
- **Probe coverage witness.** `mru=<count>` becomes `recency=<count>` plus
  `selection_newest=<bool>`: the derived order still covers every tab, and the
  selected tab still carries the newest stamp, which is what proves the tail ran.
- **Deleted with the projection.** `moveToFront`, `tabStateIsCanonical`, and
  `selectionIsLive` had no other callers, and the unit tests that pinned the
  stored order's shape (dedup, append-missing, prune-ghost, no-early-out) went
  with them: they asserted the representation, not a behavior. The behavior they
  guarded -- every live tab appears exactly once, in recency order -- is now
  pinned on `tabsByRecency` and through the switcher.
- **A monotone stamp leaks into model equality.** A message sequence that
  creates a tab and destroys it again leaves the model it started from, but with
  a higher focus clock. `AppRuntimeSessionCommandTests`' failed-restore test
  compares whole models across exactly such a round trip, so it now compares the
  recency *order* plus the models with focus history normalized. The leak is
  inherent to any cheap representation: a canonical one would have to renumber
  the stamps on every removal, and removals are only visible to the per-message
  tail -- which is the O(all tabs) work this plan exists to delete.

## Result

The frozen criterion passes. Three runs of `just reducer-dispatch-cost` on an
idle machine, unchanged workload, sample count, cells, and bound, each printed
`verdict=sweep-is-not-a-per-message-cost` with valid coverage:

| tabs | median ns/dispatch (before) | median ns/dispatch (after) |
|---|---|---|
| 8 | ~6600 | 3750 |
| 32 | ~13900 | 3750 |
| 128 | ~41000 | 3750 |

The 128-vs-8 delta is 0 ns on all three runs, against the 1000 ns bound the
prior plan froze and this one reused; the firing result it replaces was
~34700 ns. The dispatch cost no longer moves with the tab count at all, and the
8-tab floor fell as well because the two per-message `Set<TabId>` builds are
gone.

Coverage re-verified per `agent-docs/measurement-discipline.md`: with the
workload deliberately broken -- dispatching into a throwaway copy, so the
measured model sees neither the title change nor the tail -- the probe printed
`title_changes=0 ... selection_newest=false`,
`verdict=not-measured reason=coverage-validation-failed`, and exited 2.
