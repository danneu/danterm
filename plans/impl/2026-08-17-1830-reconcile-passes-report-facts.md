# Reconcile passes report facts instead of sending messages

## Context

`tests-ui/SidebarRenameRecycleTests.swift` "group structural exits end the
exact live rename" is flaky. It failed once with "removal should clear
projected rename ownership" and passed on an immediate re-run with nothing
touched.

The test spins the main run loop for at most 0.1 seconds waiting for
`.sidebarRenameEnded` to reach a test-double runtime, then asserts it
arrived. That message is deferred through `DispatchQueue.main.async` by
`endActiveRename` in `app/SidebarView.swift`. Every other assertion in the
test is synchronous and has never flaked. The awaited event can only arrive
inside the 0.1 second window, so every passing run approaches the deadline --
the shape AGENTS.md rules out. On expiry the loop falls through to a bare
assertion, so the failure text names the wrong cause.

The deferral is not a test artifact. `endActiveRename` runs mid-traversal
inside `applySidebarOps`, and a synchronous send from there re-enters the
sidebar reconcile pass before the driver advances its projection cache: the
nested pass would diff the new model against a stale cache and issue row ops
against an outline that is mid-mutation. Verified chain: `AppRuntime.send`
carries no re-entrancy guard, `.sidebarRenameEnded` falls to `default: false`
in `Msg.coalescesReconcile`, so `reconcileDecision` returns `.reconcileNow`
and the pass runs immediately. The `isReloading` flag guards only selection
and collapse feedback, not sends.

The deferred send exists only because a leaf decided to originate a message
from inside a pass. Two distinct in-pass causes reach the deferred send, and
they are not the same kind of fact:

- **Guard-driven.** `guardSidebarRenameOps` computes `clearRename` purely, and
  the driver holds it before it calls into the view at all -- the view is
  echoing back a decision its caller already made.
- **Selection-abort.** `applyRestoreSelection` ends the rename when a
  programmatic selection change would abort a live field editor with no
  delegate callback, stranding `isEditable` into the reuse pool. This one
  cannot move into the pure core: it depends on the outline's live selected
  rows, which the projection does not hold.

A single return channel serves both, which is precisely why the channel is the
right shape rather than a wider pure guard.

A further exit leaves the same pass and does not defer at all. When the model
hands a live rename to a successor row, `applySidebarOps` calls `beginRenaming`
for the new target, and `beginRenaming` finishes any live session first through
`finishActiveRenameForPointerInteraction` -- which sends the predecessor's
commit and its end **synchronously**, from mid-traversal. This is a live
instance of the hazard RI1 rejects: the sweep re-enters against a stale cache
while the outline is mid-mutation. It is in scope here, because a channel that
leaves it in place cannot discharge PO1.

One more in-pass exit lives in a **different** pass and is **not** converted here.
`reconcilePaneFocus` moves the responder, and AppKit synchronously calls
`becomeFirstResponder` on the pane view, which forwards through the session
callback gate to a `.paneBecameFirstResponder` send -- a full nested sweep from
inside the outer one. Two things follow. First, no static call-graph check can
see this edge: it is laundered through AppKit's responder dispatch, so a green
check does not establish I1. Second, converting it means first settling whether
the pass-initiated echo is redundant, which is a behavioral question about
alert-clearing and search focus ownership, not about this flake. It is recorded
as an accepted risk with a follow-up, and the drain rule in I6 is what keeps it
from corrupting this plan's channel.

Desired outcome: the message travels back through the pass's return value, the
queue hop is gone, and the test asserts a synchronous fact with no wall-clock
value in it.

### Load-bearing premise: the message is required, not redundant

`reconcileSidebarRenameTarget` (`lib/DanTermCore/Sources/DanTermCore/Update.swift`)
clears `sidebarRenameTarget` on one condition: the target row is absent from
the model. `guardSidebarRenameOps`
(`lib/DanTermCore/Sources/DanTermCore/Projections.swift`) sets `clearRename`
for four further causes -- a collapsing group hiding the edited row, the edited
row moving as remove+insert, a wholesale rebuild, and group re-insert -- and in
all four the entity is still in the model. So of the flaky test's three exits,
only `removal` is covered by the existing chokepoint; `rebuild` and `selection`
strand a live rename in the model without the message. The channel cannot be
deleted.

## Decision

**Reconcile passes never call `send()`. A fact a pass discovers travels back in
its return value, and the runtime dispatches it after the sweep completes.**

- `reconcile()` returns the follow-up messages its passes discovered. Its
  three callers -- `AppRuntime.send`, the coalesced-reconcile timer body, and
  the post-restore sweep -- drain them as ordinary top-level sends once the
  sweep has returned and every pass cache has advanced. Draining loops until
  empty, so a follow-up's own sweep can report one.
- **Only the outermost send drains.** A send that arrives while a sweep is in
  flight -- from any path, including an AppKit-laundered edge this plan does
  not convert -- accumulates its follow-ups into the outermost frame instead of
  dispatching them itself. This makes the channel correct without depending on
  having found every in-pass send site, which two review rounds each enlarged.
- The conversion in this plan covers the sidebar pass. I1 is the direction for
  the whole sweep; the one unconverted violation is named as an accepted risk.
- The sidebar pass reports that it ended a live rename. `endActiveRename`
  loses its queue hop and only tears the session down; both of its in-pass
  call sites -- the guard-driven one and the selection-abort one in
  `applyRestoreSelection` -- report through the same channel.
- `cancelAbandonedInlineRenameIfNeeded` reports the same fact to whichever
  caller invoked it. Its pointer-interaction caller sends synchronously,
  matching the sibling branch in `finishActiveRenameForPointerInteraction`
  that already does.
- The successor-rename handoff reports through the same channel. When the pass
  replaces a live session, the predecessor's **commit and end both** travel
  back as messages, so the channel carries whole messages rather than a bare
  "a rename ended" flag -- a flag cannot carry the draft text the commit needs.
  The genuine pointer-interaction caller of
  `finishActiveRenameForPointerInteraction` keeps its synchronous send.
- The AppKit end-editing callback `control(_:textShouldEndEditing:)` keeps its
  deferral. Returning `true` is what permits AppKit to continue tearing down
  the field editor after the callback returns, so a synchronous send could
  reload the row whose editor AppKit still holds. This hazard is external to
  DanTerm's structure and no refactor of our code removes it. Its restored
  rationale is a deliverable below.
- Extend the **Read-Only Model Rule** in
  [docs/design/2026-05-27-model-driven-view-reconciliation.md](docs/design/2026-05-27-model-driven-view-reconciliation.md)
  to cover this. The rule currently forbids a pass writing `AppModel`
  directly; sending from a pass writes it indirectly by re-entering
  `update()`, which is the gap this plan closes. The rule is written as the
  direction with its one named exception, not as a claim already true of every
  pass -- a rule the code is known to violate silently teaches readers to
  discount it.

## Invariants

- **I1.** A converted pass originates no `Msg`: a view-discovered fact reaches
  the model only through the pass's return value. This plan converts the
  sidebar pass. "No pass sends" is the architectural direction, not yet a true
  statement about the sweep -- the pane-focus echo is the one remaining
  exception, recorded below with its follow-up.
- **I2.** A follow-up message is dispatched only after the sweep that
  discovered it has returned, so every pass cache is advanced before the
  follow-up's own sweep reads it.
- **I3.** Ending a live rename clears `sidebarRenameTarget` for every cause
  that ends it mid-pass -- whether computed by the projection guard or
  detected by the view during selection restore -- not only for a target
  removed from the model.
- **I4.** A rename ended by a genuine pointer interaction reports its end
  synchronously, in the same turn as the interaction. Ending the same session
  from inside a pass does not inherit this, whichever helper performs it.
- **I5.** A rename ended from AppKit's end-editing callback stays deferred, and
  the field editor teardown AppKit owns is never interrupted by a reconcile.
- **I6.** Follow-ups are dispatched only by the outermost send. A nested send
  never drains, so no follow-up is dispatched while a sweep is in flight.

## Proof obligations

- **PO1** (I1): no **direct** call edge from a reconcile pass reaches `send(`.
  Discharged by a static check over the pass call graph's entry files, in the
  shape of `scripts/core-purity-lint.sh` -- not by a driven sweep, which only
  covers the branches it exercises and so cannot establish an absence.
  Structure-insensitive because it names the boundary, not the passes. The check
  cannot see an edge laundered through AppKit dispatch, so it does not on its own
  establish I1; three such edge kinds exist and each carries its own
  disposition: outline mutation to delegate feedback (the `isReloading` guards),
  editor teardown to the end-editing callback (I5), and a responder move to
  `becomeFirstResponder` (the accepted risk below). I6 is the backstop for any
  edge this inventory misses.
- **PO1b** (I6): a send arriving mid-sweep does not dispatch follow-ups. Drive a
  sweep that provokes a nested send and assert the follow-ups dispatch once,
  from the outermost frame, after the outer sweep completes.
- **PO2** (I2): a follow-up's sweep observes an advanced cache. Drive a
  transition whose pass reports a follow-up and assert the nested sweep sees
  the projection the outer pass applied.
- **PO3** (I3): each mid-pass rename-ending cause clears `sidebarRenameTarget`.
  The existing flaky test covers three legs and becomes synchronous in all
  three: two guard-driven causes (target absent, wholesale rebuild) and the
  selection-abort cause. The collapse cause needs its own scenario, since no
  current test reaches it through this channel.
- **PO4** (I4): the pointer-interaction path reports the end with no run-loop
  pump, in both its editor-present and abandoned-editor branches. The
  editor-present branch is already covered synchronously.
- **PO4b** (I1, I4): the successor-rename handoff. Drive a transition that moves
  the rename target from a live-edited row to another row; assert the
  predecessor's commit carries its draft and both its messages dispatch after
  the sweep, and that the successor's editor is active. Reverting this leg to a
  synchronous send must fail.
- **PO5** (I5): the end-editing callback still commits its draft and ends
  ownership. If a test drives this path it uses a 30-second guard that throws
  `POSIXError(.ETIMEDOUT)` on expiry -- a deadline a passing run cannot
  approach, since arrival is one queue drain away.
- **PO6** (premise): the existing model-level chokepoint does not cover
  `rebuild` or `selection`. The ablation is deleting the reported message
  outright -- not deferring it again: `removal` still passes on the chokepoint
  alone while `rebuild` and `selection` fail.

## Deliverables beyond the behavior change

- Delete the run-loop pump and its 0.1-second deadline from the flaky test.
  Assert the reported fact at the driver boundary instead; the existing
  result-returning transition helper in the same file is the shape to reuse.
- Restore the lost rationale comment on the end-editing deferral. It once read
  "Defer to avoid reentrant reloadData while text field is ending editing" and
  was dropped in a later refactor, leaving the only load-bearing deferral in
  the file unexplained.
- Extend the Read-Only Model Rule section as stated in the Decision.

## Non-goals

- Changing what `.sidebarRenameEnded` does in `update()`.
- Reworking `guardSidebarRenameOps`, the projection diff, or cache advance.
- Re-sizing the 5-second guard in `tests-ui/ObserveOnMainTests.swift`. Its
  0.01-second value is a run-loop slice, not a deadline, and its loop exits on
  first delivery, so it is not this class of problem. Worth tightening
  opportunistically, separately.

## Accepted risks

- **AR1.** In the `removal` case `sidebarRenameTarget` is now cleared twice --
  once by the model-level chokepoint, once by the follow-up. The write is
  idempotent and the second clear is a no-op.
- **AR2.** Draining follow-ups until empty admits an unbounded loop if a
  follow-up's sweep reports itself. Termination rests on the reported facts
  being self-clearing rather than on the set of reporting sites being small:
  a pass reports only while view and model disagree, and dispatching the
  follow-up removes the disagreement, so the next sweep has nothing to report.
- **AR3.** `reconcilePaneFocus` still originates `.paneBecameFirstResponder`
  through AppKit's responder dispatch, so I1 is not yet true for the whole
  sweep. Left unconverted because the fix turns on whether the pass-initiated
  echo is redundant -- its handler skips alert-clearing and the focus mutation
  when the target already matches the model, which a pass-issued move does,
  leaving only search focus ownership -- and that is a behavioral question with
  its own test surface, unrelated to this flake. I6 keeps it from dispatching
  this plan's follow-ups mid-sweep. Follow-up below.

## Rejected ideas

- **RI1.** Send synchronously from `endActiveRename`. The verified re-entrancy
  chain in Context makes this a production correctness bug, not a
  simplification.
- **RI2.** Send from `reconcileSidebar` immediately after the driver returns.
  The cache is advanced by then, but the send would still re-enter the full
  sweep from inside it -- the same class of hazard, moved.
- **RI3.** Inject a deferral seam so tests can drain the queue
  deterministically. This makes the asynchrony observable instead of removing
  it, and leaves the leaf originating messages mid-pass.
- **RI4.** Queue re-entrant sends inside `AppRuntime.send`. Fixes the hazard
  without fixing the shape: the view still originates sends mid-pass, now
  silently queued, and it hides that the fact is already in hand before the
  send.
- **RI5.** Add a selection cause to `guardSidebarRenameOps` so the projection
  guard, not the view, decides that a selection change ends a rename. The
  decision depends on the outline's live selected rows, which the projection
  does not hold, and `applyRestoreSelection` already detects it correctly
  in-pass -- so this duplicates a working detection in a place that cannot see
  its inputs.
- **RI6.** Raise the test's deadline to 30 seconds with an `ETIMEDOUT` expiry.
  The legitimate cheap fix -- it ends the flake and makes the failure honest.
  Rejected because it keeps a wall-clock value in a test whose subject is
  fully synchronous, and leaves the production ordering window in place.
- **RI7.** Drop the outermost-only drain rule and instead convert the
  pane-focus echo here, so no pass sends at all. The end state is right and is
  the recorded follow-up, but it does not belong in this plan: converting the
  echo requires settling whether a pass can carry search focus ownership
  itself, a behavioral question with its own test surface and no bearing on the
  flake. Dropping the drain rule is separately wrong -- it returns the
  channel's correctness to a claim of complete edge enumeration, and each
  successive reading of this call graph found an in-pass exit the previous one
  missed. The drain rule holds whether or not the echo is converted.

## Follow Up

- Convert or suppress the pass-initiated `.paneBecameFirstResponder` echo, so
  I1 holds for the whole sweep. First establish whether the echo is redundant
  for a pass-issued responder move: if only search focus ownership survives,
  the pass can carry that fact itself and the echo can be suppressed rather
  than routed.
- Run the live GUI check of the five mid-pass rename-ending causes by hand, or
  add the CLI surface that would let an agent run it. Nothing in
  `integrations/danterm/SKILL.md` starts an *inline* sidebar rename -- `group
  rename` sets a name outright, and the edit session only begins from the menu's
  `.createGroupInteractively` or a double-click -- so the five scenarios in
  Verification could not be driven from the CLI.

## Implementation notes

- The drain rule lives in a pure `ReconcileFollowUps`
  (`lib/DanTermCore/Sources/DanTermCore/ReconcileFollowUps.swift`) rather than as
  a depth counter inline in `AppRuntime`. `app/AppRuntime.swift` is in no test
  target -- the UI harness compiles its own `AppRuntime` shim -- so PO1b had
  nowhere to be driven otherwise. The type is pure ordering logic over `Msg` and
  sits beside `reconcileDecision`, which factors out the same kind of rule.
- PO1's static check is `scripts/reconcile-pass-lint.sh`. It bans `send(`
  outright in `app/Reconcile.swift` and `app/SidebarReconcileDriver.swift`, and
  inside a marker-delimited region of `app/SidebarView.swift` -- that file is
  both a pass executor and an interaction handler, so a whole-file ban is wrong
  there. A missing or duplicated marker fails, so deleting the fence is not a way
  to pass. `beginRenaming` moved into the region.
- `beginRenamingTab`/`beginRenamingGroup` finish the predecessor and dispatch its
  commit *before* installing the successor session, rather than letting
  `beginRenaming`'s own finish report to them. This keeps the existing ordering
  regression ("successor ownership must not exist while the prior rename
  dispatches"); only the pass path relies on the finish inside `beginRenaming`.
- PO6's ablation ran at the pure layer, not in the UI harness. The harness's shim
  runtime never calls `update()`, so `reconcileSidebarRenameTarget` does not
  execute there and the harness cannot tell the legs apart. A core test asserts
  the chokepoint's scope directly instead. The channel itself was ablated in the
  harness: returning no follow-ups from `applySidebarOps` fails exactly the four
  tests that pin it and nothing else.
- The collapse scenario needs two groups. `computeSidebarRowOps` skips collapse
  ops in single-group mode, since the lone group has no caret.

## Implementation discretion

- How the follow-up messages are carried and accumulated through the sweep.

## Verification

- `just test-ui` -- the sidebar rename suites are the direct subject. Run once
  into a file and grep it.
- `just test` -- the pure-layer gate, for the `Update.swift` and
  `Projections.swift` premises.
- TDD order: PO3's `rebuild` and `selection` scenarios must go red before the
  channel exists and green after. Confirm the flaky test's assertion passes
  with the pump deleted, not merely with the deadline raised.
- Ablation for PO6: with the follow-up channel disabled, `removal` still
  passes while `rebuild` and `selection` fail. This is what establishes that
  the existing chokepoint does not cover them.
- Live check via the CLI (`integrations/danterm/SKILL.md`), one step per
  mid-pass cause, confirming each time that the editor exits and the row shows
  its model-backed name: rename a **tab** and collapse its containing group
  (the collapse cause -- only a tab rename can hit it, since collapsing a group
  keeps its own row visible); rename a **group** and close a different group
  (rebuild); rename a group and switch tabs (selection-abort); rename a group
  and close that group (target absent); rename a group and then start renaming
  a different row while the first edit is live (successor handoff -- the first
  draft must commit).

## Critical files

- `app/SidebarView.swift` -- the three deferred sends, `applySidebarOps`,
  `applyRestoreSelection`'s selection-abort exit, the `beginRenaming` handoff,
  `finishActiveRenameForPointerInteraction` and its two callers.
- `app/SidebarReconcileDriver.swift` -- the pass result and cache advance.
- `app/Reconcile.swift` -- the sweep and the sidebar pass.
- `app/AppRuntime.swift` -- `send`, the coalesced timer body, the post-restore
  sweep.
- `tests-ui/SidebarRenameRecycleTests.swift` -- the flaky test and its
  transition helpers.
- `docs/design/2026-05-27-model-driven-view-reconciliation.md` -- the
  Read-Only Model Rule.
