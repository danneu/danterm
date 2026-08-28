# Skip the tab diff for a group the sidebar op script just remounted

Source: `docs/scratch/2026-08-26-improvement-audit.md`, MODEL-1.

## Problem

`computeSidebarRowOps` (`lib/DanTermCore/Sources/DanTermCore/Projections.swift`)
diffs the sidebar in two levels. Level 1 turns a group reorder into
`removeGroup` + `insertGroup`; an inserted group arrives carrying its tabs from
the *new* projection (`SidebarItemStore.apply` rebuilds `childItems` on
`.insertGroup`, and the test harness `applySidebarRowOps` models the same). Level
2 then diffs tabs for every group present in `old`, which includes the group
level 1 just remounted, and emits tab ops whose indices describe a child list
the store no longer holds.

Evidence: `old = [A(t1), B(t2)]`, `new = [B(t2, t3), A(t1)]` yields
`[.removeGroup(1), .insertGroup(B, 0), .insertTab(t3, B, 1)]`; model-apply gives
`[B(t2, t3, t3), A(t1)]`. The existing model-apply harness (`checkRowOps`,
`lib/DanTermCore/Tests/DanTermCoreTests/ReconcileTests.swift`) proves it once the
case is added.

Premise (verified): no reducer arm reaches this input today. `.reorderGroup` is
the sole writer of group order and changes nothing else, and no coalesced sweep
batches a reorder with a tab-membership change. This is a latent trap that goes
live the first time an arm reorders a group and moves a tab in one message.

## Decision

The fact "which groups did level 1 rebuild" gets one owner: the sequence diff
reports the ids it re-inserted, and the tab diff skips those groups the same way
it already skips brand-new ones. The caller never re-derives the set.

Rejected: return `[.reloadAll]` whenever group order changes. Correct, but it
discards every row cell and any in-progress inline rename on a plain group drag,
which is what the incremental script exists to avoid.

Scope: `Projections.swift` only, plus tests. No change to `SidebarRowOp`,
`SidebarItemStore`, or `SidebarView`.

## Invariants

- I1. For any pair of projections in the same group mode,
  applying `computeSidebarRowOps(old, new)` to `old` yields `new`.
- I2. A structural tab op (`.insertTab` / `.removeTab`) is emitted only for a
  group whose child rows level 1 left in place; a remounted or newly inserted
  group receives none. Repaint-only ops (`.reloadTab`) are unaffected.
- I3. A plain group reorder (no tab-membership change) still yields an
  incremental script, not `.reloadAll`.

## Proof obligations

- PO1 (I1, I2): cases for a group reorder combined with a tab added to the
  moved group, and with a tab removed from it. Each runs `checkRowOps` (I1) and
  asserts the op list carries no `.insertTab` / `.removeTab` whose `groupId` is
  the moved group (I2). Both fail today.
- PO2 (I3): the existing `"reorder groups (isFirst flips)"` case keeps passing
  and its ops contain no `.reloadAll`.

## Non-goals

- Reachability from any current reducer arm; the fix guards a future edit.
- CHROME-4 (one record of the last applied sidebar projection): touches the
  driver and view, not this diff. Independent.

## Implementation discretion

- How `sidebarSequenceOps` surfaces the re-inserted ids (tuple return vs.
  `inout` set).

## Verification

`swift test --package-path lib/DanTermCore --filter ReconcileTests` red then
green; `just lint`; `just test` before commit. Then tick MODEL-1 in the audit's
`## Plan of work` (line ~344) with `-- done <sha>`.

## Commit progress

- [x] 1. fix(sidebar): skip structural tab ops after a group remount
- [ ] 2. docs(audit): mark MODEL-1 complete
