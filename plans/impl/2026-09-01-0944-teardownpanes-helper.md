# One tearDownPanes helper for the five pane-teardown sites (UPDATE-2 fallback)

## Problem

When a pane leaves the tree, its pending IPC work must be rejected and its
alerts pruned from the global feed. That ritual is hand-written at five sites in
`lib/DanTermCore/Sources/DanTermCore/Update.swift`, and three of them also carry
a popover clear that a later chokepoint made dead. Every new removal path must
re-derive the ritual, and the five copies already drift on the dead half.

**Evidence.** The five sites, all in `Update.swift`, verified against the
current file on 2026-09-01:

- the `.sessionCreationFailed` arm (per-pane loop over the failing tab)
- `deleteGroupBody` (per-pane loop over every tab in the group)
- `closePaneBody` (the `.surviving` case)
- `closeOtherPanesBody` (per removed sibling)
- `closeTabRemoval` (per-pane loop over the closing tab)

Each calls `rejectPendingIpcWork` then `removeAlertsForPane`. Three of them
(`closePaneBody`, `closeOtherPanesBody`, `closeTabRemoval`) also clear
`model.todoPopover` for `.pane(paneId)`, and `closeTabRemoval` carries a fourth
clear for `.tab(id)` -- four popover-clear blocks in total. All four are dead
work: `reconcileTodoPopover` runs in `update()`'s unconditional `defer` and
retracts any popover whose anchor left the model on the same message (the audit
entry in `docs/scratch/2026-08-26-improvement-audit.md`, UPDATE-2, vetted this
line by line; the two sites that omit the clear are already correct because of
it).

**Load-bearing premise.** The `defer`-time reconcile sweep retracts a todo
popover whose pane or tab is gone, on the same message, with no help from the
teardown site. Deleting the four blocks is safe iff this holds.

## The abandoned ideal, and why (design bar)

The ideal fix for UPDATE-2 was reconciliation-owned pane teardown: an existence
pass in the reconcile tail that drops alerts and rejects pending IPC work for
any pane no longer in `model.allPaneIds`, deleting all five rituals and making
"a removal path forgot the ritual" inexpressible. It was abandoned on
2026-08-31: the UPDATE-7 probe
(`plans/impl/2026-08-31-1859-reducer-per-message-budget.md`) fired its frozen
decision rule -- the reconcile sweep has a real per-message cost that scales
with tab count (~35 us of a ~41 us title report at 128 tabs), and the existence
pass would add more of exactly that cost to every message. That is a genuine
constraint on the ideal, not an effort judgment.

This plan is the documented fallback: one helper, called explicitly. The
trade-off is real and stays on the record -- the helper removes the drift
between copies but keeps the "did you remember to call it" obligation on every
future removal path, which is the class the ideal would have deleted. If the
per-message budget is ever bought back (UPDATE-7's follow-ups), the ideal
becomes available again.

## Decision

Introduce one helper, `tearDownPanes`, in `Update.swift`, and make it the only
way a teardown site performs the ritual. All five sites call it; the four dead
popover-clear blocks are deleted, not moved into the helper.

**The helper's contract:**

- Tearing down a pane means: reject its pending IPC work (the session-creation
  reply still waiting on spawn, and any pending input submissions), each with an
  `.ipcError`, and prune its alerts from the global feed. Nothing else -- the
  popover, session existence, containers, and sidebar are the reconcile
  chokepoint's, and the helper must not duplicate them.
- The caller names the cause (`pane closed` vs `process failed to start`); the
  cause words both error replies together, so a site can never mix the wordings.
- Precondition, owned by the caller: the panes are still resolvable in the model
  when the helper runs -- the session-creation half is found through the pane's
  live session -- so each site tears down before it mutates the tree, as the
  five sites already do.
- The helper takes the batch a site removes (one pane or many), so a
  multi-pane site is one call, not a hand-rolled loop around a one-pane helper.

The helper's signature, decomposition, and whether it reuses or absorbs
`rejectPendingIpcWork` and `removeAlertsForPane` are implementation discretion.

## Invariants

- **I1.** Removing a pane by any path (close pane, close others, close tab,
  delete group, session-creation failure) rejects its pending session-creation
  reply and its pending input submissions with `.ipcError`, worded by the
  cause the site names. The two wordings (`.paneClosed` vs
  `.processFailedToStart`) are user-visible IPC error text and are preserved
  exactly.
- **I1a.** When the removing message also empties the app, every rejection
  command it emits precedes the `.terminate` in the same command list, so the
  runtime delivers the replies before it quits.
- **I2.** No alert owned by a removed pane survives in `model.alerts` after the
  removing message.
- **I3.** A todo popover anchored to a removed pane, or to a closed tab, is
  retracted by the end of the same `update()` call -- with the explicit clears
  deleted, this is carried entirely by the reconcile sweep.
- **I4.** This is a pure refactor everywhere else: for every message, the
  resulting model and command list are unchanged.

## Proof obligations

Behavioral, structure-insensitive: every test below drives `update()` and
asserts model state and commands; a refactor that keeps the behavior must keep
them green. `DanTermCore` is pure -- `swift test --package-path lib/DanTermCore`.

- **PO1 (I1, I2, I4). The teardown matrix.** Each of the five paths (close
  pane, close others, close tab, delete group with `moveTabs: false`,
  `.sessionCreationFailed`), with a pending session creation and a pending
  input submission both seeded against the removed pane, and an alert seeded
  for it, produces: the pane gone, no alert for it in `model.alerts`, and an
  `.ipcError` for each pending request carrying the exact code and message the
  path's cause words. No test asserts either wording today, and only
  close-other-panes covers both pending-work kinds, so this matrix -- not the
  existing suites -- is what pins I1 and the group path's alert pruning. Write
  it first against the current code; it must pass before and after.
- **PO2 (I1a).** A close of the last tab, and a `.sessionCreationFailed` that
  empties the app, each with pending IPC work seeded against a removed pane,
  return every `.ipcError` before the `.terminate`.
- **PO3 (I2, I4).** The existing alert-feed pruning tests stay green
  unmodified.
- **PO4 (I3, the load-bearing premise).** A todo popover anchored to a pane is
  retracted when that pane is removed by a path whose explicit clear this plan
  deletes (pane close and tab close), and one that never had a clear
  (group delete); a `.tab`-anchored popover is retracted on tab close. These
  tests pin the premise, so the deletion of the four blocks is proven safe
  rather than argued.

## Non-goals

- No change to the reconcile chokepoint, `update()`'s `defer`, or any
  per-message pass -- that is exactly what the probe ruled out.
- No change to the `.sessionCreationFailed` fallback branch that prunes alerts
  for a pane already in no tree; it is not one of the five sites and its
  behavior is unchanged.
- No new teardown responsibilities (session teardown, container removal stay
  with reconciliation).

## Accepted risks

- **AR1.** Future removal paths must still remember to call the helper; the
  compiler does not enforce it. Accepted because the ideal that would enforce
  it by construction costs per-message time the probe showed is real (see the
  design-bar section above).

## Completion bookkeeping

On completion, mark UPDATE-2 complete in
`docs/scratch/2026-08-26-improvement-audit.md` (the Wave checklist entry and
the item's status), recording that it landed via the `tearDownPanes` fallback
with the four dead popover lines deleted.

## Implementation discretion

- The helper's exact signature and whether `rejectPendingIpcWork` /
  `removeAlertsForPane` survive as private pieces inside it or are inlined.
- Test placement within the existing `lib/DanTermCore` suites.

## Implementation notes

- The helper is `tearDownPanes(_ paneIds: some Sequence<PaneId>, in:cause:)`
  and keeps `rejectPendingIpcWork` and `removeAlertsForPane` as the two private
  pieces it calls, rather than inlining them. `rejectPendingIpcWork`'s doc now
  names `tearDownPanes` as its only caller.
- The two sites that walked a tree with `forEachPane` now pass
  `allPaneIds(tab.paneTree.root)` instead. That materializes one array per
  teardown where the walk allocated none. It is on removal paths only, not on
  the per-message budget UPDATE-7 measured, and it buys one call per site
  instead of a hand-rolled loop, which the plan's contract asks for.
  `allPaneIds` visits panes in the same left-to-right tree order as
  `forEachPane`, so the emitted command order is unchanged (I4).
- PO2's "close of the last tab" is driven through `.requestCloseTab` on a
  two-pane tab, not `.closeTab`. A plain `.closeTab` on the last tab returns a
  quit confirmation whose confirm arm returns only `.terminate`; it never
  reaches `closeTabRemoval`, so it emits no rejections to order. The close
  confirmation is the only last-tab path that both tears down and terminates.

## Follow Up

- Answering the quit confirmation (`Update.swift`, the `(.quit, .confirm)` arm)
  returns `[.terminate]` alone. Any pending `pane.input` submission or
  session-creation reply is abandoned with no `.ipcError`, so an IPC caller
  waiting on one gets no reply when the app quits that way. Out of scope here --
  no pane leaves the tree on that path -- but it is the same class of dropped
  reply this plan's I1a protects on the other last-tab paths.
