# MODEL-2: sidebar outline self-repair (delete `.none`)

Audit item MODEL-2 in `docs/scratch/2026-08-18-construction-audit.md`: make
`SidebarItemStore` reject nothing, or report rejection, so a dropped row op
cannot strand the outline. The escalation-policy decision is made: take the
self-repair road and delete `SidebarOutlineMutation.none` entirely. The
`.rejected` reporting variant was declined by the user.

## Problem

`SidebarItemStore.apply` guards every op and returns `.none` when a check
fails. `.none` also means "this op legitimately produced no outline work", so
the executor (`app/SidebarView.swift#applyRowOp`) cannot tell a refused
structural op from a no-op, and the reconcile driver advances its projection
cache to `new` regardless. A refused structural op therefore desynchronizes
the mounted outline from the cache permanently: the next diff runs against a
cache that claims the op landed, so no repair is ever emitted.

Verified facts (all re-checked against the current tree):

- `computeSidebarRowOps` (`lib/DanTermCore/Sources/DanTermCore/Projections.swift:733`)
  guards only a single<->multi mode *flip*. Staying in single-group mode, it
  emits group-row ops the store always refuses:
  - The group-level `sidebarSequenceOps` call (line 743) is ungated. When the
    lone group's id changes between two single-group sweeps, it emits
    `removeGroup`/`insertGroup` and no tab ops at all (the level-2 loop skips
    a new group with no matching old group). The store refuses both
    (`guard !projection.isSingleGroupMode`), so nothing happens: the outline
    keeps the dead group's tabs and never shows the new group's. This is the
    stranding scenario.
  - The group reload-attrs loop (line 761) is also ungated. In single-group
    mode `groupItemCache` is always empty (the store's rebuild path only
    populates it in the multi-group branch), so every `.reloadGroup` emitted
    there is refused. This fires on ordinary tab open/close and unread-count
    changes in the default single-group mode. Harmless today (`.none`), but
    after `.none` becomes escalation it would be a full `reloadData()` on
    nearly every sweep -- so it must be gated in the same prerequisite commit.
- Every `return .none` in the store is a guard failure; no arm returns
  `.none` for legitimate no-work. The only production consumer of `.none` is
  `applyRowOp`'s `case .none: return`. Deleting the case is clean.
- After the diff-side gate lands, no reachable pipeline sequence produces a
  refused op: structure in the driver's cache always matches the outline
  (`advanceSidebarCache` retains only attribute fields, never row identity or
  order), and every other guard mirrors an invariant the sequential op script
  already maintains.

## Decision

Two commits, in order (the first is a shared prerequisite: CHROME-2 unblocks
on this item; RECON-1 and MODEL-1 merge after it).

**D1 -- the diff and the store agree about what a group row is.**
`computeSidebarRowOps` stops emitting any group-row op in single-group mode,
and a single-group sweep whose lone group id changed rebuilds wholesale.
This removes the only known spurious refusals, which is what makes "a refusal
escalates to a full rebuild" an acceptable cost.

**D2 -- refusal stops being expressible.** Delete
`SidebarOutlineMutation.none`. An op the store cannot apply incrementally
self-repairs: the store rebuilds itself from the projection it was handed
(the same rebuild the `.reloadAll` op runs) and returns the full-reload
mutation, which the executor already knows how to run. The driver needs no
change: after a self-repaired sweep the view painted everything from `new`,
so advancing the cache to `new` is exactly right.

## Invariants

- I1: In single-group mode, `computeSidebarRowOps` emits no group-row ops
  (insert/remove/reload/collapse of group rows). When old and new are both
  single-group and the lone group's id differs, it returns `[.reloadAll]`.
- I2: `SidebarOutlineMutation` cannot express "I refused silently". Every op
  the store cannot apply incrementally leaves the store's rows equal to the
  handed projection's rows and returns the full-reload mutation.
- I3: A full-reload mutation supersedes the remainder of the sweep's op
  script: no later op of the same sweep mutates the rebuilt store. (A stale
  op accepted after a mid-script rebuild could otherwise corrupt the store --
  e.g. a duplicate insert -- with the cache already advanced to `new`, which
  is exactly the permanent desync this item removes.)
- I4: A full rebuild never destroys a live inline rename's field editor
  without ending the rename session first. (The rename guard only requests
  ending the edit for op-level `.reloadAll`; a store-escalated rebuild
  happens after the guard ran, so the executor must end the rename itself.)

## Proof obligations

- PO1 (I1, diff level): single-group identity change returns `[.reloadAll]`;
  a single-group attr-only change (tab count, unread) emits no group op; the
  existing multi-group group-churn gauntlet is untouched.
- PO2 (I1, end to end -- the commit-1 failing test): seed a
  `SidebarItemStore` from single-group model A (group G1, tab t1), apply
  `computeSidebarRowOps(desiredSidebar(A), desiredSidebar(B))` with B's
  projection (group G2, tab t2). The store displays t2 and not t1. Fails
  today: the diff emits two group ops, the store refuses both, nothing
  happens.
- PO3 (I2): every formerly-refused op (the existing rejected-ops table,
  wrong-mode group ops included) returns the full-reload mutation and leaves
  the store's rows equal to the handed projection's rows. The existing test
  "rejected row ops return none without changing the store" asserts the old
  contract and is rewritten to this one.
- PO4 (I3, executor level in `tests-ui`): drive a real `SidebarView` through
  `applySidebarOps` with a script containing an unappliable op followed by a
  stale op. The outline ends equal to the projection; the stale op does not
  corrupt the rebuilt store. A hand-built store script cannot prove this --
  stopping the script is the executor's behavior, not the store's.
- PO5 (I4, executor level in `tests-ui`): with an inline rename active, a
  sweep whose script contains an unappliable op ends the rename session; no
  stranded editable field survives the rebuild. Only a real field editor can
  show this, so this test cannot live at the core-store boundary.

## Non-goals

- No change to `SidebarReconcileDriver`'s API or `SidebarReconcileResult`
  (the existing tests-ui suites keep compiling and passing unchanged; PO4 and
  PO5 add new ones).
- No reporting of the escalation upward (declined `.rejected` variant).

## Accepted risks

- AR1: A refused op now costs a full `reloadData()` of the outline. Accepted:
  after D1 no reachable sequence produces one, so this is a safety net, and
  bounded damage (one rebuild) replaces unbounded damage (a permanently wrong
  outline).
- AR2: The escalation exposes no public rejection or result field -- nothing
  upstream of the store can read that a sweep escalated. Accepted explicitly
  by the user when declining `.rejected`. (Tests still observe the outcome:
  PO4 and PO5 assert it through `applySidebarOps`.)
- AR3: A rebuild escalated mid-script does not discard unapplied-row results
  recorded earlier in the same sweep, so the driver keeps those rows' old
  attrs in its cache and the next sweep repaints them once more. Accepted:
  the rebuild already painted the correct attrs and the extra repaint is
  redundant work, not a wrong outline; clearing the sets would add
  coordination between the executor's op loop and the store for no behavior
  change.

## Rejected ideas

- RI1: `.rejected` case + driver-level escalation and result reporting --
  declined; its only benefit over self-repair was reporting the escalation
  upward.
- RI2: The audit's original ideal (derive row indices from the projection so
  `apply` is total): the mutation must keep carrying the index NSOutlineView
  consumes, and the store's mounted rows and the projection remain two
  structures, so disagreement stays representable -- it only moves.
- RI3: On refusal, keep the old cache and let the next sweep repair: leaves
  the outline wrong for an unbounded interval, since nothing guarantees a
  next sweep.

## Implementation discretion

- How the executor stops the script after a full reload and how the store
  shares the rebuild between the `.reloadAll` arm and the guard exits.

## Commit progress

- [x] 1. `computeSidebarRowOps` emits no group-row ops in single-group mode;
  a lone-group identity change rebuilds wholesale (D1, I1; tests PO1, PO2
  written first and failing).
- [ ] 2. Delete `SidebarOutlineMutation.none`; unappliable ops self-repair
  via full rebuild; the executor stops the script after a full reload and
  ends a live rename first (D2, I2-I4; tests PO3-PO5; rewrite the
  rejected-ops store test; drop the executor's `.none` arm).
