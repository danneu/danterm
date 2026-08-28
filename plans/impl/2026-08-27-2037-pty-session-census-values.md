# Attach the PTY host's session obligations to values

Audit items PTY-6, PTY-2, PTY-9, PTY-8 from
`docs/scratch/2026-08-26-improvement-audit.md` (Wave 8, "The PTY session
census"). PTY-1 (arm the exit bound in the `.closeMaster` arm) is a sibling
change that lands after this one and reuses the seam this plan adds.

## 1. Problem and evidence

`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift` enumerates
the owned session with `sessionMembers` and sweeps it in two places
(`applySessionCensus`, `killOwnedSession`). Verified against the tree:

- The census is a bare `[pid_t]`; both consumers re-filter it with `getsid`
  and one takes the session id back as a parameter. The rule "a member is a
  pid in this session" is written three times.
- `proc_listallpids` returns a byte count (`references/xnu/bsd/kern/proc_info.c:381,
  478-480`); `sessionMembers` treats it as an element count. It is safe only
  because the buffer is zero-filled and 4x oversized, which also makes the
  capacity retry and the trailing `return nil` unreachable.
- Each stage sweeps once (`sessionPollStageSignaled`). A member that enters
  the census after the `.kill` sweep is never signalled, and `.kill` has no
  later stage to rescue it; the 10 ms poll then runs until the exit bound.
- `signalSession` appends `.sessionDrained` to the reducer's queue directly;
  every other producer goes through `process`. Correct today only because its
  single caller runs inside a reduction.
- `killOwnedSession` runs after the exit bound has elapsed and loops with no
  deadline until a census succeeds. Once the byte-count fix lands, a nil
  census becomes reachable, so the deadline stops being hypothetical. Its
  comment claims every process group "has actually been enumerable and
  signalled", which is true of a moment, not of the session.
- No census can be injected. Every ladder test drives real processes via
  `PTYProbe teardown`, and a member that appears after the `.kill` sweep
  cannot be built with real processes, so the late-member hole has no test.

## 2. Decision

Move each obligation onto a value that carries it, behind one injected seam:

- **D1 -- a census seam.** The host takes a fourth injected dependency beside
  the spawner, child-exit probe, and resource lifecycle: a session census
  witness that enumerates a session and signals a pid it enumerated. It is
  the only reader of `proc_listallpids` and the only sender of signals to
  census members. The host keeps its own authority for the fallback
  process-group kill, the leader kill, and the leader reap, which need no
  census. The system witness reads the syscall's result in bytes.
- **D2 -- a census value.** The witness returns a `SessionCensus` that names
  the session it enumerated and its members. Only the witness can mint one.
  Consumers iterate it; none re-filters.
- **D3 -- a per-stage sweep value.** The host's stage/latch pair becomes one
  pure value: the current stage plus the pids already signalled at it. Each
  poll signals the members not yet in the set; advancing a stage starts a
  fresh set. The value is unit-testable with no host.
- **D4 -- one reducer entry.** `process` is the only writer of the reducer
  queue; `signalSession` calls it in both arms.
- **D5 -- bounded forced kill.** `killOwnedSession` retries a failed census
  until its own deadline, then falls through to the group kill and the leader
  kill, records the unenumerated outcome in `TerminalPTYLifecycleCensus`, and
  returns. Its comment states what it guarantees: every member enumerable at
  that moment.

Ordering with PTY-1: this plan lands first. PTY-1's natural-exit test uses
the D1 seam (a census that never empties) instead of a real process, and
asserts the D5 counter is untouched where it forces the bound.

## 3. Invariants

- **I1.** Every census-derived signal goes to a member of the session the
  census named; no consumer re-derives membership. The fallback group kill
  and leader kill target the host's own session id and leader pid and need
  no census.
- **I2.** While the poll is armed, every member present in a census is
  signalled at the current stage exactly once, including a member that first
  appears after the stage's first sweep and including at `.kill`.
- **I3.** A stage that advances re-signals every member at the new stage;
  SIGCONT accompanies every signal except SIGKILL.
- **I4.** A `.sessionDrained` produced anywhere in the host advances the
  reducer, whether or not a reduction is in progress.
- **I5.** When the census stays unavailable, forced cleanup stops retrying
  in bounded time and proceeds to the fallback: the leader's group and the
  leader are killed, the leader reap begins, and the snapshot records that
  the session was not enumerated. With a reapable leader (the ordinary case),
  quiescence is then published.
- **I6.** Forced quiescence with a census that fails then succeeds kills every
  enumerated member and records no unenumerated outcome.
- **I7.** The system census's decode of a syscall result is a pure function
  of the byte count and the buffer: it yields at most the pids the kernel
  wrote, and an exact-capacity result is a failure (possible truncation),
  never a short list.
- **I8.** Existing ladder behavior is unchanged: the owned session's
  foreground, background, stopped, and signal-resistant jobs all exit on close;
  a sibling host's session is untouched; `forcedQuiescenceCount == 0` on an
  ordinary close.

## 4. Proof obligations

- **PO1 (I2, I3)** -- pure sweep-value tests: a census at `.kill` signals all
  members; a later census with one more member signals only that member; a
  new stage signals everyone again.
- **PO2 (I1, I2, I4)** -- host test with a controlled census: members through
  `.hangup`, `.terminate`, `.kill`, then a poll that adds a pid; the recorded
  signals show SIGKILL reached the new pid once; an empty census then drains
  the host with `forcedQuiescenceCount == 0`.
- **PO3 (I5)** -- controlled census that always fails; `forceExitBoundForTesting`;
  `whenQuiescent` fires (under the suite's ordinary hang guard, with no
  elapsed-time assertion), the snapshot is released, the unenumerated counter
  is 1, the real leader is reaped.
- **PO4 (I6)** -- controlled census that fails twice then returns members;
  every member receives SIGKILL; counter is 0.
- **PO5 (I7)** -- pure decode tests on the system witness: a byte count
  smaller than the buffer yields exactly `count / 4` pids; an exact-capacity
  byte count yields a failure; a negative count yields a failure. A live
  check, if any, asserts only containment (the test's own pid is a member of
  its own session).
- **PO6 (I8)** -- the existing `teardownLadderCoversSessionAndPreservesSibling`,
  `applicationExitTerminationForcesQuiescenceWithinBound`,
  `reArmedGraceSourceKeepsDrivingTeardown`, and the
  `TerminalPaneSessionControllerTests` release assertions stay green.

## 5. Non-goals / accepted risks / rejected ideas

- **NG1.** Rescuing a session member that survives SIGKILL (EPERM,
  uninterruptible wait). The sweep does not; the exit bound (PTY-1) ends the
  poll and forced cleanup kills what it can without waiting on members.
- **AR3.** The leader reap after the forced kill stays a blocking `waitpid`,
  as the existing code documents on purpose (`reapLeaderAfterKill`: giving up
  would publish quiescence over a zombie this process still owns). A
  SIGKILLed leader that never becomes reapable is a kernel-level fault this
  plan does not address; I5's bound covers the census, not the reap.
- **NG2.** Arming the exit bound on the natural-exit path. That is PTY-1.
- **AR1.** The sweep set is keyed by pid, not by a unique process identity.
  A pid the census loses and regains within a stage is not re-signalled, and
  a pid reused by a new session member within the same stage is treated as
  already signalled. Both need Darwin to recycle a pid inside a ladder stage
  of at most 200 ms; the exit bound (PTY-1) ends any resulting stall, and a
  unique-identity lookup would cost a syscall per member per 10 ms poll.
- **AR2.** Reporting quiescence after an unenumerated forced kill can leave a
  stopped job in its own process group alive. It trades a leaked process for
  an unkillable app and is recorded in the snapshot rather than hidden.
- **RI1.** Sweep unconditionally at `.kill` only, keeping the latch elsewhere.
  Leaves the `.hangup`/`.terminate` window open and keeps two sweep rules.
- **RI2.** A census-only seam without `signal`. Fake pids are then unobservable
  (`kill` can only ESRCH), so PO2 cannot be written.

## 6. Implementation discretion

- The forced-kill retry deadline's length and the counter's name. Constraint:
  the deadline is a host constant separate from `applicationExitBound`, which
  has already elapsed when the loop runs.
- Whether the sweep value lives in its own file. Constraint: it is pure and
  `package`-visible so `TerminalPTYHostTests` reaches it without `@testable`.

## Verification

- `swift test --package-path lib/TerminalPTY --filter TerminalPTYHostTests` into
  a file, grep for the PO1-PO6 titles and for `failed`.
- `just lint`, then `just test` before commit.
- After landing: tick PTY-6, PTY-2, PTY-9, PTY-8 in the audit's
  `## Plan of work` with the commit hash.

Critical files: `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`
and `lib/TerminalPTY/Tests/TerminalPTYHostTests/`. The seam and both values are
`package`-visible in the `TerminalPTYHost` target.

## Commit progress

- [x] 1. refactor(pty): attach session obligations to census values

## Implementation notes

- The forced census retry bound is 50 ms with a 1 ms retry interval. It starts
  only after the host's application-exit bound has already elapsed.

## Follow Up

- Tick PTY-6, PTY-2, PTY-9, and PTY-8 in
  `docs/scratch/2026-08-26-improvement-audit.md` with this commit's hash.
- Investigate why broad TerminalPTY and root app test runs time out across
  unrelated output, childless-channel, pane-publishing, and IPC tests while the
  focused census tests and lint gate pass.
