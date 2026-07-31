# Teardown must converge on evidence the host can always produce

## Problem

A `TerminalPTYHost.close()` that races an in-flight spawn can never converge
through the teardown ladder. It waits out `applicationExitBound` (default 2s)
and completes only by forcing quiescence, holding a PTY master descriptor and a
live child for that whole window. A user who opens a pane and closes it inside
the spawn window pays that every time.

This surfaced as test slowness: `just test` is 147s warm, `test-terminal-pty.sh`
is 68s of it, and the single test `rapidCloseStressLeavesNoResources` is 36s.
Instrumenting it showed all 16 of its `close()` calls taking exactly 2.005s,
with the test's own settle loops contributing zero iterations. A uniform 2.005s
is a timer firing, not variable work. The slowness is the symptom; the stalled
teardown is the defect.

### Load-bearing premises

- Closing while the reducer is spawning emits no ladder commands. When the
  spawn lands, the host adopts the master descriptor, leader, and session but
  skips installing sources because ownership is sealed, so no leader-exit
  observation is ever armed.
- The ladder then signals the session and arms the session census. The child
  dies, the census drains, but the teardown state finishes only when a leader
  exit status has already been recorded -- and that status can only arrive from
  the observer that was never armed. Teardown is unreachable until the bound.
- **The census cannot see a zombie.** Session membership is resolved through
  `getsid`, which fails for an exited-but-unreaped process. Verified directly on
  Darwin: `getsid` on a zombie raises `ESRCH` while `waitpid(..., WNOHANG)`
  returns it immediately. Two consequences: a drained census does fire on the
  stalled path, and a drained census alone does **not** prove the leader was
  reaped.
- The census is evidence the host can always produce: a repeating poll it owns
  outright. Leader-exit notification is not -- kqueue `NOTE_EXIT` registration
  for an already-dead pid can fail with no error channel, and the host already
  needs a fallback poll because Darwin publishes `NOTE_EXIT` before the status
  is readable.
- The pure reducer suite already exercises this path, but supplies a leader-exit
  event the host is under no obligation to deliver in that state. The suite
  asserted a trace rather than a contract, which is why the defect shipped.

## Decision

Fix the reducer: teardown converges on the session census, and reaps the leader
on that path so the zombie guarantee is preserved. The choice between latency
and zombie-avoidance was never forced -- teardown can confirm the reap and still
finish on the census witness.

Behavioral scope: the teardown state's drain handling only. Launch, IO, resize,
and the running-close path are untouched; the latter already converges because
its observer is armed.

The distinction that must survive: a spawn that *lands* promptly enough for the
ladder to run converges through the ladder; a spawn that lands too late, or
never, is still forced at the bound. The bound remains the backstop, not the
normal path.

## Invariants

- **I1** A close racing a spawn that lands promptly -- early enough for the
  ladder to run to completion -- reaches quiescence through the ladder, with no
  forced quiescence.
- **I2** The ladder's convergence depends only on evidence the host can always
  produce. It must never depend solely on best-effort exit notification.
- **I3** (existing, preserved) The host never reports quiescence while a process
  it owns could still be running.
- **I4** Quiescence leaves no unreaped leader. A drained census is not by itself
  proof of this.
- **I5** Teardown reaps the leader exactly once and before finishing, whichever
  convergence witness arrives first.
- **I6** (existing, preserved) A close whose spawn does not land in time for the
  ladder to complete is still resolved by forcing quiescence at the bound.
- **I7** (existing, preserved) No descriptor is adopted into the host's live IO
  path after the close barrier.

## Proof obligations

- **PO1** (I1, I2) Teardown converges from a drained session alone, with no
  leader-exit observation supplied at all. Belongs in the pure reducer suite,
  where it needs no processes. Currently failing; write it first.
- **PO2** (I5) The leader is reaped exactly once and before finishing, under
  both witness orderings. Pure.
- **PO3** (I2) Every close/exit interleaving converges when only the census
  witness is supplied. Pure. This is the structural pin for the whole bug class,
  and the gap that let the defect through -- the existing interleaving coverage
  always supplies both witnesses.
- **PO4** (I1) A close racing a spawn that lands promptly records no forced
  quiescence and completes strictly inside the bound. Integration. Both halves
  are required: without the timing half, a ladder rescued by the bound would
  still satisfy the rest. Must run against the real default bound -- a shortened
  bound would pass for the wrong reason.
- **PO5** (I4) No unreaped leader survives quiescence on the census path. The
  leader is a direct child of the test process, so this is exactly assertable.
  This obligation decides whether the host needs a bounded reap escalation.
- **PO6** (I6) A close whose spawn is withheld past the bound still forces
  quiescence and still leaves no live child. Covered by existing tests, which
  must keep passing unchanged.
- **PO7** (I1, I3) Repeated create-then-immediately-close cycles leave no
  descriptor and no child behind, and record no forced quiescence. The existing
  stress test carries this once its convergence assertion is added.

## Non-goals

- Shell-integration fixed sleeps (~6s across three shells) and the build-script
  waste in `test-terminal-pty.sh` / `terminal-capture-api-gate_test.sh`. Real
  and separately actionable; out of scope.
- Lowering `applicationExitBound` for the stress test. It would make the test
  fast while hiding the defect -- teardown would still be forced, just sooner.
  Speed must come from the fix.

## Rejected ideas

- **RI1** Restore leader-exit observation after the close barrier by arming the
  process source post-seal. Rejected on I2: it rests convergence on a
  registration that can silently fail for an already-dead pid, leaving the bound
  as the real fallback intermittently. It also makes reachable a window where
  the exit is cancelled before dispatch and then dropped by the closing-while-
  spawning state, converting a bounded stall into a permanent one.
- **RI2** Finish on a drained census without reaping. Rejected on I4: the census
  cannot see a zombie, so this leaks an unreaped child for the app's lifetime.

## Accepted risks

- **AR1** Two existing pure tests encode the defect as a golden trace -- one
  asserts that a drained session yields no commands. They must be rewritten as
  part of this change. This is a deliberate contract revision, not test-patching
  to fit an implementation, and it should be argued as such in the commit
  message.
- **AR2** On the running-close path a census-first finish can cancel a
  still-armed exit observer. A suppressed-then-delivered callback is counted
  against the post-teardown callback census that quiescence already asserts is
  zero, so the failure mode is loud rather than silent.
- **AR3** The census path reaps without the reapability proof the exit path
  carries. PO5 is the detector; the remedy, if it fires, is a bounded blocking
  reap justified by the already-empty census.
- **AR4** Real teardown now runs on a path that has effectively always been
  force-cleaned, so latent defects there become newly reachable. PO7's census is
  the guard.

## Verification

- Write PO1 first and confirm it fails because the drain yields no commands and
  the state stays in teardown -- not for any other reason.
- `swift test --package-path lib/TerminalPTY` for the pure and host suites.
- `./scripts/test-terminal-pty.sh` for the full gate, including the solo
  fd-census lane. The stress test is reran by name there; do not rename it.
- `just test` end to end, including the reducer's purity lint.
- Re-time `just test`. Expect the PTY step to fall from 68s and the total from
  147s. The figure is an outcome, not an acceptance criterion.

## Implementation discretion

- Whether the host needs an additional bounded reap escalation, and its shape.
  Decided by PO5, not in advance.
- The seam used to make the spawn race deterministic in the integration test,
  provided it proves PO4 without asserting on internal command ordering.
- Correcting the host comments that still describe leader observation surviving
  the close barrier, so the next reader does not re-derive this bug.

## Implementation notes

- PO5 observed `waitpid(..., WNOHANG) == 0` after the census-first reducer path,
  so `reapLeader()` now escalates that specific result to SIGKILL plus the
  existing blocking reap after the PTY master is closed. An already-reapable
  leader keeps the nonblocking path.
