# Model master-close asynchrony as a reducer event (S17)

## Problem

Closing the PTY master is asynchronous: the host must wait for every
descriptor-backed dispatch source's cancel handler before the descriptor
is released. The lifecycle reducer models it as an ordinary command in
the middle of an atomic list -- `beginTeardown` emits close, hangup
signal, and grace scheduling together. The host compensates by
intercepting `.closeMaster` in `execute(_ commands:)`, parking the tail
in `deferredCommandsAfterMasterClose`, and replaying it later through
`resumeCommandsAfterMasterClose` -- a hand-copied second reduce loop.
Two reduce loops means every change to reduction ordering must be made
twice, and the copy is load-bearing: `signalSession` appends
`.sessionDrained` directly to the pending-event queue, so a resume path
that only executed commands would strand events.

Every other asynchronous step in this lifecycle already crosses the
host/reducer boundary as an event (`spawnSucceeded`, `childExited`,
`sessionDrained`, `graceElapsed`). Close is the one exception.

Verified premises (re-established 2026-08-13 against the post-S12 code):

- The deferral machinery is unchanged by the S12 witness injection; S12
  helps here, because `TerminalPTYResourceLifecycling` lets tests hold
  the cancellation barrier open deterministically.
- Timing is already event-shaped: the signal/grace tail runs after the
  barrier drains today, so moving it behind an event preserves observed
  behavior.
- The forced-cleanup path (`exitBoundElapsed`) supersedes the reducer
  and completes host-owned cleanup directly; it discards the deferred
  tail today (line 747).
- On the close-racing-spawn path the host adopts the spawned master,
  leader, and session even after sealing, installs no sources, and the
  close then completes synchronously inside reduction.
- No consumer of the command or event enums exists outside the reducer
  file, `TerminalPTYHost.swift`, and the two reducer test files.

## Decision

Give the reducer the event it is missing. `.closeMaster` becomes a
request that ends `beginTeardown`'s command list; the host reports
completion of the close barrier with a new
`PaneProcessLifecycleEvent.masterClosed`; the reducer emits the hangup
rung (`.signalSession(.hangup)`, `.scheduleGrace(.hangup)`) from that
transition. Delete the deferral machinery: the deferred-command field,
the resume loop, the `.closeMaster` interception in the command-list
executor, and the `preconditionFailure` in the single-command executor.
One reduce loop remains, and teardown command order depends on the state
machine, not on cancel-handler timing.

Forced cleanup stays an explicit reducer bypass. It does not emit
`.masterClosed`; the reducer it supersedes stays parked, inert, exactly
as today.

Decisive constraints:

- `.closeMaster` is the terminal command of any list that contains it.
  The reducer emits nothing after it; the next teardown work is a
  reaction to `.masterClosed`.
- The host emits `.masterClosed` only for the close the reducer asked
  for. The `.closeMaster` command records that the reducer awaits the
  completion; the barrier consumes that intent when it drains, and
  forced cleanup clears it when it supersedes the reducer. Every
  host-internal close -- `finishTeardown()`'s defensive re-close above
  all -- carries no intent and so emits nothing. This is what keeps
  the forced path a true bypass, and it does not depend on the order
  in which the host sets its finalization flag.
- Emission is per close request, not per descriptor release: a sealed
  early close (reducer not yet tearing down) and the later real teardown
  each complete their own request, and the reducer relies on receiving
  the teardown one.
- The event is delivered through the existing `process(_:)` entry so
  both completion contexts work unchanged: a barrier that drains later
  enters a fresh reduction; a close that completes synchronously inside
  reduction queues the event for the same drain.

## Invariants

- I1: The teardown ladder (hangup signal + grace) starts exactly once
  per teardown, and only after the master close has completed.
- I2 (existing, preserved): teardown converges within the application
  exit bound, and forced quiescence kills, reaps, and releases every
  owned resource before completion is published. Normal closes converge
  without forced quiescence.
- I3: The reducer stays pure and deterministic under arbitrary event
  orders: `.masterClosed` that is duplicate, late (`.finished`), or
  out of phase (any non-teardown state) emits nothing and changes no
  phase.
- I4: Teardown-progress events are inert before the close completes:
  `.graceElapsed` and `.sessionDrained` in `.tearingDown` do nothing
  until `.masterClosed` has been handled. (`.childExited` is not gated;
  reaping does not depend on the close.)
- I5: Signal-stage monotonicity: across any event order, emitted
  `.signalSession` stages never decrease, and none precedes
  `.masterClosed`.
- I6: Forced cleanup never restarts the ladder and never reports a
  result through the superseded reducer.

## Proof obligations

- PO1 (I1): reducer tests -- close from running emits only the close
  request (self-exit adds the reap); `.masterClosed` in `.tearingDown`
  emits exactly the hangup rung.
- PO2 (I3): reducer tests -- duplicate `.masterClosed`, `.masterClosed`
  in `.finished`, and `.masterClosed` in each non-teardown state are
  no-ops. `closingWhileSpawning` is one of those states and gets its own
  case: it reports publicly as `.spawning`, so a test written against
  the public phase would not prove that an early `.masterClosed` is
  inert between the close request and spawn completion.
- PO3 (I4): reducer tests -- pre-close `.graceElapsed(.hangup)` and
  `.sessionDrained` are ignored; after `.masterClosed` the
  hangup -> terminate -> kill escalation is unchanged, and the
  close-while-spawning path still converges.
- PO4 (I5): the interleaving suite's drivers inject `.masterClosed`
  where the host would emit it, and its invariant assertion is
  strengthened to reject any signal before `.masterClosed` -- otherwise
  the monotonicity check is silently hollowed out by traces that never
  signal.
- PO5 (I2, I6): the existing host suite passes unchanged. Named gates:
  the session-coverage ladder test, the rapid close stress
  (forced-quiescence count stays zero), the close-racing-spawn
  convergence test (the synchronous-completion context), and the
  forced-shutdown-with-held-barrier test. That last one does not prove
  I6 on its own: it starts from an explicit close, so the parked
  reducer holds no exit result to report and the assertions still pass
  even if forced cleanup emits `.masterClosed`. Add a host test that
  does prove it -- let a child exit put a real result in the teardown
  context, hold the close barrier, force cleanup, release the barrier,
  and assert the superseded reducer neither publishes that result nor
  restarts normal completion.
- TDD order binds: new reducer tests first, red against the current
  reducer, then the reducer change, then the host change and deletions.

## Non-goals

- No change to escalation stages, grace durations, signal choice, or
  the session census.
- No redesign of the forced-cleanup path beyond clearing the pending
  close intent; it remains a reducer bypass (a dedicated
  forced-cleanup reducer event was considered and rejected -- the
  bypass is already explicit and fully host-owned).
- Not adopting S17's cheaper fallback (shared drain-loop helper); the
  event design deletes the second loop instead of sharing it.

## Implementation discretion

- Where the reducer records "close completed" (e.g. a flag in the
  teardown context) and how the host stores the pending close intent,
  provided I1-I6 hold.

## Files

- `lib/TerminalPTY/Sources/PaneProcessLifecycle/PaneProcessLifecycle.swift`
  -- event, `beginTeardown`, `handleTeardown`.
- `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift` --
  close intent recorded by the `.closeMaster` executor case, consumed
  in `completeMasterCloseIfPossible`, cleared by forced cleanup;
  executor simplification, deletions.
- `lib/TerminalPTY/Tests/PaneProcessLifecycleTests/LifecycleReducerTests.swift`
  -- new tests; the shared expected-command helpers and their six use
  sites gain a `.masterClosed` step.
- `lib/TerminalPTY/Tests/PaneProcessLifecycleTests/LifecycleInterleavingTests.swift`
  -- inject the event; strengthen the invariant assertion.
- `lib/TerminalPTY/Tests/TerminalPTYHostTests/TerminalPTYHostTests.swift`
  -- stale comment about replaying superseded ladder commands (~line
  1300); the new forced-path result assertion from PO5.
- `docs/scratch/2026-08-11-simplification-audit.md` -- mark S17's table
  row with the commit hash, as prior retirements do.

## Verification

- `swift test --package-path lib/TerminalPTY` for the reducer,
  interleaving, and host suites (the host suite forks real children;
  it is the behavioral gate).
- `just test` for the full local gate before commit.

## Delivery

Two commits. The lifecycle implementation stays atomic because reducer-first
cannot be green in between (with the tail gone and no emitter, every teardown
parks at hangup-never-sent), and a transitional dual-mode reducer contradicts
I1. The audit status follows separately because a commit cannot contain its own
hash.

## Commit progress

- [x] 1. refactor(pty): model master close completion as a reducer event
- [x] 2. docs(audit): mark S17 master close reducer work complete

## Implementation notes

- Delivery was split into an implementation commit and an audit-status commit
  because the S17 status must name the implementation commit's hash.
