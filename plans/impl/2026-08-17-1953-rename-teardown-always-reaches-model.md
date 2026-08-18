# A view-side rename teardown always reaches the model

## Context

The just-landed plan made the model a truthful record of an open inline
sidebar rename: one message begins every session, and `ls` reports it. Its
follow-up names the one hole left. This plan closes that hole at the level of
the defect class rather than the single site.

## Problem

The sidebar view holds a second record of the rename session -- which text
field actually owns the field editor -- because AppKit can abort an editor with
no delegate callback, so the model cannot derive it. That is legitimate. What
is not legitimate is that the two records are kept in step by convention:
six sites tear the view's session down, and each is separately responsible for
producing an end.

Five do, each choosing its own delivery. The click-away path delivers on a
main-queue hop captured on the view itself, so its end can be dropped if the
view goes away first.

`resetRecycledRenameState` (app/SidebarView.swift) cannot report at all: it runs
inside AppKit's `outlineView(_:viewFor:item:)` on the reuse-pool branch, where
there is no `followUps` array to append to, no pointer interaction to send on,
and a synchronous send is both forbidden by `scripts/reconcile-pass-lint.sh`
and unsafe -- it would reconcile and reload the rows AppKit is mid-way through
building. So it clears the session silently and the model keeps claiming it.

Two consequences, and the second is the load-bearing one:

- `ls` reports a session that is not on screen.
- A later rename of that same row does nothing. The pass opens an editor only
  when the projected target *changes*, and the stale target already equals the
  new one, so nothing changes and no editor opens.

The second consequence is possible only because a session is identified by the
row it edits. Evidence that this identity is already too weak: the landed work
needed a rule that an end retracts only a target-matching request, and the UI
suites' shared begin helper has to clear the target and run a throwaway pass
before it can reopen an editor on the same row.

`viewFor:` fires on scroll and on window resize, so the silent teardown is
reachable with no pass anywhere on the stack.

## Decision

**D1 -- a session has an identity, and an end names it.** Beginning a rename
mints a fresh session identity alongside the target. An end retracts the
pending request only when the identity matches, so an end belonging to a torn
-down session is inert no matter how late it arrives or which row it names.
This replaces the current target-matching rule, which cannot tell two
successive sessions on the same row apart.

The identity is phantom typed like every other entity id, and `update()` mints
it through the injected `CoreEnv` id seam. A leaf that generates its own
identity would put a nondeterministic edge inside the pure core.

D1 alone restores the user-visible behavior: a second begin on a stale row
mints a different identity, so the projection changes and the editor opens.

**D2 -- teardown and reporting are one act, with guaranteed delivery.** The
view's session lives behind a single owner whose only teardown operation
produces the end, and every teardown reports that end into the runtime's
existing reconcile follow-up queue. That queue is the sole outbox; the plan adds
no second one, and the two delegate paths stop sending directly. It already
holds a report made inside a send frame until that frame returns, and it
outlives the view, so delivery no longer depends on a view-captured hop.

What it lacks is a wake-up: a report made when no send frame is running has
nobody to drain it. So the ingress schedules a drain for such a report, and
never drains on the reporting stack.

Deferring unconditionally, rather than when the stack looks unsafe, is forced
by a gap in the frame discipline: the coalesced sweep runs a whole-model
reconcile outside any send frame, so an empty frame stack does not mean no
sweep is in flight. An ingress that drained whenever the stack was empty would
re-enter a pass mid-sweep against a stale projection cache, and would also
reconcile inside AppKit's row traversal -- a pass sending, laundered through
the queue where the lint cannot see it.

Same-turn delivery therefore comes only from a report made inside a send frame.
A pointer interaction does not run inside one: it tears the rename down at the
top of the event, before it sends anything. So that path opens a frame of its
own around the teardown and closes it there, before the event proceeds. The
frame ends at the teardown rather than wrapping the whole event because the
commit and its end have to reach the model ahead of the selection changes the
rest of the event drives -- a reconcile that ran between them would act on a
model still claiming a session the view has already given up.

D2 is what makes the model truthful. D1 is what makes D2 safe: buffered ends
are delayed ends, and a delayed end that named only a row could retract a
session opened in the meantime -- reachable inside a single pass, where a row
reload recycles the edited cell and a later step of the same pass opens an
editor on that row.

The `ls` wire shape does not change; the session identity stays internal.

## Invariants

- **I1.** Every teardown of the view's rename session produces an end. No path
  can clear the session without one.
- **I2.** An end retracts the model's pending request only when it names the
  same session. An end from a superseded or already-torn-down session changes
  nothing, including when it names the same row as the live one.
- **I3.** An end reaches the model without waiting for a later reconcile pass,
  at the latest on the next main-queue turn, and its delivery does not depend
  on the reporting view still being alive.
- **I4.** Beginning a rename on a row whose editor was silently destroyed opens
  an editor.
- **I5.** Reporting an end never dispatches it. Delivery happens only at a
  drain point: the exit of the outermost send frame, or a scheduled later drain
  for an end reported with no frame open.

## Proof obligations

- **PO1 (I1, I3).** A cell recycle that kills a live editor with no reconcile
  pass on the stack leaves the model reporting no open session.
- **PO2 (I1).** Every teardown cause reachable in the UI harness that does not
  hand the editor to a successor ends with the model reporting no open session.
  The enumeration includes the Enter/Esc commit and the click-away commit. A
  handoff ends the predecessor and leaves the successor open; PO3 and PO4
  cover it.
- **PO3 (I2).** An end produced by a session that has already been superseded
  leaves the successor's session open, in the case where both name the same
  row.
- **PO4 (I2, I4).** A pass that recycles the edited cell and then opens an
  editor on that same row leaves the editor open and the model reporting it.
- **PO5 (I4).** After a silent teardown, a begin on that row opens an editor --
  the symptom the follow-up reported.
- **PO6.** The existing guarantee that a pointer interaction reports what it
  discovered in the same turn survives the outbox, and it reports before the
  interaction's own selection changes. The discriminating case is a click-away
  onto an already-selected row, where the interaction sends nothing afterwards
  that could carry the end for it.
- **PO7 (I5).** An end reported with no send frame open is not delivered on the
  reporting stack: the model still names the session when the reporting call
  returns, and names none once the turn unwinds. This is the AR1 window,
  observed on purpose.
- **PO8 (I3).** An end reported with no send frame open still reaches the model
  when the sidebar is released before the drain runs.

## Non-goals

- **Preserving the draft on a recycle.** A recycle discards typed-but
  -uncommitted text today and still will. Committing text the user never
  confirmed, on an event the user did not cause, is a separate and arguable
  behavior change.
- **Exposing the session identity outside the process.** It is an internal
  identity; `ls` keeps reporting the row.
- **Making the editor survive a recycle.** AppKit owns the reuse pool and
  destroys the editor without telling us; the view's job is to report that
  honestly, not to prevent it.

## Accepted risks

- **AR1.** In the AppKit-traversal case the model can claim an open session
  until the deferred drain runs. An IPC read already queued for the main actor
  can run first and return one stale `ls` result. Accepted: a synchronous
  report is not available on that stack, the window is one main-queue turn, and
  the next read is correct.

## Rejected ideas

- **RI1.** Give the recycle site its own pending-ends buffer drained by the
  pass. It fixes this call site and leaves the other four paired by convention,
  so the next teardown path added falls into the same trap. It also leaves the
  end undelivered until some later pass happens to run.
- **RI2.** Have the pass reconcile the view's session toward the projected
  target instead of opening on change, so a lost end self-heals. Rejected when
  the current behavior landed: it reopens an editor that a selection change
  just ended, because the model has not yet seen the end that same pass
  reported.
- **RI3.** Delete the view's session record and let the model be the only one.
  Not available: AppKit destroys field editors with no callback, so the view
  holds a fact the model cannot derive.

## Implementation discretion

- How the session identity reaches the view.

## Critical files

- `app/SidebarView.swift` -- the six teardown sites, including the
  `NSTextFieldDelegate` Enter/Esc and click-away paths that send directly
  today, plus `beginRenaming`, the
  `followUps` accumulation in `applySidebarOps`, and the `sendNow` interaction
  path. Reuse the existing `finishActiveRename` / `endActiveRename` /
  `cancelAbandonedInlineRenameIfNeeded` message-producing shape; they already
  return the ends, they just need one delivery channel.
- `lib/DanTermCore/Sources/DanTermCore/ReconcileFollowUps.swift` and
  `app/AppRuntime.swift` -- the queue that becomes the sole outbox, and the
  drain it already runs after the outermost send frame.
- `lib/DanTermCore/Sources/DanTermCore/` -- `Model.swift` (the pending request),
  `Msg.swift` (begin and end), `Update.swift` (the retraction rule and the
  row-removal retraction), `Projections.swift` (what the pass compares),
  `IpcEntityEncoder.swift` (unchanged wire shape).
- `tests-ui/SidebarTestSupport.swift` -- the shared begin helper; its
  clear-then-pass workaround should fall away once identity distinguishes two
  begins on one row.
- `tests-ui/SidebarRenameRecycleTests.swift`, and the rename tests in
  `lib/DanTermCore/Tests/DanTermCoreTests/CustomTitleTests.swift` and
  `UpdateIpcTests.swift`.

The existing `testResetRecycledRenameState` and `testForceNextNilCell*` seams
drive the recycle and unmaterialized-row paths without depending on AppKit
timing; the proofs use them rather than provoking a real scroll.

## Verification

- `just test` and `just test-ui`, both green.
- Ablate the delivery: with the outbox drain removed, PO1 fails. PO5 does not
  isolate delivery -- it passes on the identity change alone.
- Ablate the deferral: with the ingress draining on the reporting stack, PO7
  fails.
- Ablate the identity: with the retraction rule back to target matching, PO3
  and PO4 fail.
- Live check on a slot -- `just launch-slot`, double-click a sidebar row to
  open an editor, scroll it out of view and back, then `danterm --socket <slot>
  ls` reports no open rename, and renaming that row again opens an editor.

## Commit progress
- [x] 1. Give an inline sidebar rename session its own identity (D1)
- [x] 2. Deliver every view-side rename teardown through the reconcile outbox (D2)

## Implementation notes

- The model stores the whole session (`AppModel.sidebarRename`) and keeps
  `sidebarRenameTarget` as a derived read-only accessor. The row-op guard and
  the `ls` encoder ask only which row is being edited, so they were left
  reading the row rather than being widened to the session.
- The UI harness compiles the model but not the reducer (`test-ui.sh` does not
  include `Update.swift`), so its shared begin helper cannot call
  `update(.beginSidebarRename)`. It mints the session through one named helper,
  `recordRenameBegin`, which stands in for the reducer's mint. The
  clear-then-throwaway-pass workaround the plan called out is gone.
- Making the outbox the sole channel left the pass's return channel with no
  producer, so it is gone: `reconcile()`, `reconcileSidebar`, `applySidebarOps`
  and `SidebarReconcileResult` no longer carry `[Msg]`. Keeping an always-empty
  return would have been a second way to deliver an end, which is the coupling
  this plan removes.
- The queue and the wake-up live in a new `app/ReconcileOutbox.swift` rather than
  inline in `AppRuntime`, so the UI harness -- whose `AppRuntime` is a shim --
  exercises the real buffering, frame, and wake-up rules instead of a copy. The
  pure ordering rule stays in `ReconcileFollowUps`, which gains one predicate,
  `needsScheduledDrain`, for the owner to act on.
- Enter and Esc now land one main-queue turn later, like the click-away path:
  they report with no send frame open. The plan grants a frame of its own only to
  the pointer interaction, whose commit must beat the selection changes the rest
  of the event drives.
- The live GUI check in Verification was not run. Neither the double-click that
  opens an editor nor the scroll that recycles its row can be driven through the
  CLI, so the slot check was limited to launching the app and reading `ls`. The
  two ablations were run and behave as the plan predicted: removing the wake-up
  fails PO1, and draining in the ingress fails PO7.

## Follow Up

- `danterm` cannot begin an inline sidebar rename, so the plan's live check
  (double-click a row, scroll it out of view and back, read `ls`) has no
  programmatic path. An IPC method that begins the rename the way a double-click
  does would make this class of behavior testable from the CLI.
