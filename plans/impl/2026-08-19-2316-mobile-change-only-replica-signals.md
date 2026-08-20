# MOBILE-4: signal replica state and surface geometry only when they change

## Context

Audit finding MOBILE-4 (docs/scratch/2026-08-18-construction-audit.md, `#mobile-4`),
verified against the current tree this session. `TerminalSurfaceView.apply` fires
`didChangeReplicaState?(replica.state)` after every applied tape record, whether or
not the state moved. The controller's handler then dispatches `.replicaStateChanged`
-- which returns `[.redraw]` in the steady `.exact` case, composing a fresh
`MobileSessionProjection` and rewriting the status pill's labels -- and calls
`surfaceDidLayout()`, which runs `scrollChrome.refresh()` and builds a
`MobileSurfaceFacts` report. All of that runs once per PTY chunk on the main actor,
for a screen whose pixels are published on the display link and not by any of it.
Wave-1 partners MOBILE-1 (`76aed4ab`) and MOBILE-3 (`40ca4c51`) are done, so this
is unblocked; MOBILE-5 waits on it.

## Decision

Implement the finding's ideal fix: make every callback mean what it is named, so
each of the three things the shell reacts to -- the replica's state, the facts the
model acts on, and the drawn frame -- is signalled when it actually moves.

1. **Transition-only state callback.** `TerminalSurfaceView` remembers the state
   it last reported and fires `didChangeReplicaState` only when the state after
   `apply` differs. `reset(checkpoint:for:)` clears the memo, so the first record
   after a pane attach always reports once -- this keeps the model's stream fact
   seeded after the reconnect that every pane switch performs, and keeps
   `resumePolicy.replicaBecameExact()` firing on a checkpoint-restored pane's
   first record exactly as today.
2. **Change-only facts callback.** Model facts and visible chrome move on different
   clocks, so the two halves of `surfaceDidLayout()` split. `TerminalSurfaceView`
   memoizes the replica-derived facts -- `pinned` and `isAlternateScreenActive` --
   and fires a second callback only when applying a record moves them. The
   controller dispatches `.surfaceChanged` from it and does not touch the chrome.
   This is also what withdraws pinnedness on a gap: leaving `.exact` moves `pinned`
   to `nil`. `reset(checkpoint:for:)` clears this memo alongside the state memo. An
   applied record that moves neither the state nor these facts causes no work at
   all. The state-change handler now only dispatches the transition.
3. **Publish drives the chrome, and only the chrome.** `TerminalSurfaceView` gains a
   callback fired when `displayTick` actually attaches a new frame (the
   `policy.didPublish` branch, not the coalescing one). The controller wires it to
   `scrollChrome.refresh()`, because the drawn window the chrome mirrors moves
   exactly then and for no other reason. `MobileScrollDriver.replicaChanged` is
   level-triggered and idempotent when idle, so calling it at publish cadence
   instead of record cadence changes no driver semantics.
4. **Pane attach seeds once explicitly.** The `.attachPane` effect refreshes the
   chrome and reports the full facts after `surfaceView.reset`, so the chrome drops
   to `.inert` (fresh replica) or the restored geometry immediately instead of
   describing the previous pane until the first published frame. Layout keeps its
   existing job unchanged -- it is the only source of `nativeGrid`, so it still
   refreshes the chrome and reports the facts.

No `DanTermMobileKit` source changes: `MobileSessionModel`, `MobileScrollDriver`,
and `PaneReplica` keep their contracts.

## Invariants

- I1: The model receives `.replicaStateChanged` exactly when the replica's state
  differs from the last one reported since the current pane attached; the first
  record after an attach always reports.
- I2: A record that moves neither the replica's state nor its reported facts --
  which is every record in steady output flow -- composes no projection, writes no
  status-pill text, and dispatches no surface-facts report. The redraw path is only
  entered by an actual session change.
- I3: Every state transition reported to the model still produces a redraw, and
  `gap(.detected)` still ends the connection.
- I4: A remote viewport record still reaches the scroll indicator when the user is
  idle: the record damages, the frame publishes, and the publish reconciles the
  chrome.
- I5: After a pane attach, the scroll chrome describes the newly attached pane, not
  the previous one.
- I6: The model's stored `pinned` and `isAlternateScreenActive` never lag the
  replica across a display frame. Record application reports them the moment they
  move, so no action the model offers -- the release the claim control projects,
  the routing a scroll gesture takes -- depends on when a frame publishes. In
  particular `pinned` is never `true` while the replica is not exact.

## Proof obligations

- PO1 (I3, I6): a new `MobileSessionModelTests` test drives `.replicaStateChanged`
  through `awaitingSynchronization -> exact -> gap(.declared) -> exact`, asserting
  a redraw per transition, and asserts `gap(.detected)` ends the connection. The
  same test asserts that a `.surfaceChanged` report carrying `pinned: nil` withdraws
  the release action -- the model half of I6, which the new wiring depends on. It
  pins existing behavior, so it passes before the shell change lands; the TDD
  fail-first step does not apply.
- PO2 (I4): existing `MobileScrollTests` (`scrollDriverLatchesReflectionDuringInteraction`,
  `scrollDriverReflectsWhenIdle`) pin the driver semantics the move depends on;
  they must stay green untouched.
- PO3 (I1, I2, I5, and the wiring half of I6): live in the app executable target,
  which has no test target (`MobileSessionController.swift` states this
  constraint). Coverage is the portability-gate compile plus the manual
  verification below; the view-side memos follow the existing `previousCursor`
  before/after pattern already in `apply`.

## Non-goals

- Guarding the status pill's label writes (`ConnectionStatusPillView.show`): once
  reports are transitions, redraws are rare and the writes are fine where they are.
- Batching the record drain or moving the replica off the main actor (MOBILE-5).
- Suppressing `.redraw` in the model for unchanged projections.

## Rejected ideas

- RI1: the audit's cheaper fallback (guard label writes, skip redraw on unchanged
  projection in the model) -- leaves the per-record projection composition and
  chrome work in place and puts change detection in the wrong layer.
- RI2: comparing state before/after `apply` without a reset-cleared memo -- drops
  the first-record report after an attach, silently making the resume policy's
  distrust clearing depend on the fresh-sync path alone.

## Accepted risks

- AR1: chrome reconciliation and the driver's alternate-screen mode flip are
  learned at publish cadence, up to one frame later than today. A record applied
  while the replica is not exact publishes nothing, so the chrome holds its last
  state during a gap or sync wait -- matching the frozen pixels it overlays. Only
  the chrome is on this clock; the facts the model acts on are on the record clock
  (I6).

## Files

- `ios/DanTermMobileApp/Sources/DanTermMobileApp/TerminalSurfaceView.swift` --
  state memo and facts memo with their change guards in `apply`, both cleared in
  `reset`, publish callback in `displayTick`.
- `ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileSessionController.swift` --
  split `surfaceDidLayout()` into a facts-only report and a chrome-plus-facts
  refresh; the state-change handler dispatches only the transition; wire the new
  facts callback to the facts-only report, the publish callback to
  `scrollChrome.refresh()` alone, and `.attachPane` to the chrome-plus-facts path.
- `ios/DanTermMobileKit/Tests/DanTermMobileKitTests/MobileSessionModelTests.swift`
  -- PO1 test, using the existing `Session` driver and house preamble style.

## Verification

1. `swift test --package-path ios/DanTermMobileKit` (PO1, PO2).
2. `./scripts/ios-portability-gate.sh --package ios/DanTermMobileApp` (the only
   thing that compiles the app target).
3. `just test` before commit.
4. Manual (optional, simulator via `scripts/ios-app.sh sim`): attach a pane, flood
   it (`yes` in the observed pane), confirm the status pill and scroll indicator
   still behave; run a full-screen program and confirm a scroll still routes to it;
   switch panes and confirm the chrome resets; kill the server mid-stream and
   confirm the pill reports the end.

After landing, mark MOBILE-4 done in the audit checklist as a separate
`docs(audit)` commit, following the MOBILE-1/MOBILE-3 convention.

## Follow Up

- Mark MOBILE-4 done in `docs/scratch/2026-08-18-construction-audit.md` as a
  separate `docs(audit)` commit, following the MOBILE-1/MOBILE-3 convention.
