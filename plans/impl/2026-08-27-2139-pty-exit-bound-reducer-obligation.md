# Make the PTY exit bound a reducer obligation

Audit item: PTY-1 in `docs/scratch/2026-08-26-improvement-audit.md`
(Wave 8, "Attach the PTY host's obligations to values").

## 1. Problem

`TerminalPTYHost` has one mechanism that guarantees teardown finishes: the
exit bound (`armExitBound` -> `exitBoundElapsed` -> forced session kill,
leader reap, abandon of an in-flight launch). It is armed from exactly one
place, `beginShutdown` -- the path a human or app quit takes. The teardown
ladder has a second entrance, a child that exits on its own
(`.childExited` -> `beginTeardown` in `PaneProcessLifecycle`), and that
entrance arms nothing. If the session never drains (a member `kill(2)`
refuses, e.g. a setuid background job), the host polls the census forever,
never reports the exit to the pane, and the pane handle stays retained. The
bound cannot kill such a member either (AR2); what it guarantees is that the
host stops, reports, and releases.

Verified against the tree (`TerminalPTYHost.swift:908-930`, `:1713`;
`PaneProcessLifecycle.swift:313-315`, `:352-357`, `:443-459`). Not fixed
since 6d978789 introduced the bound.

Load-bearing premises:

- P1. Every entry into `.tearingDown` emits `.closeMaster`; a
  `.requestClose` while `.spawning` moves to `.closingWhileSpawning` and
  emits no `.closeMaster` until the spawn returns. So the bound cannot be
  "armed on `.closeMaster`" alone: a bootstrap stalled before `execve`
  would be unbounded, and the bound is what abandons that launch.
- P2. `.requestClose` in `.idle` finishes immediately and needs no bound.
- P3. The reducer already owns timer obligations as commands
  (`.scheduleGrace` / `.cancelGrace`); the host interprets them.

Desired outcome: no reducer state that needs a bound can exist in the host
without the bound armed, and that fact is checkable without a process.

## 2. Decision

Move the obligation from the host call site to the reducer state that
carries it. The reducer emits an arm-the-bound command exactly once, on
entry to the bounded region (`.closingWhileSpawning`, `.tearingDown`); the
host interprets it; `beginShutdown` stops arming on its own.

Why this over the audit's vetted fix (arm in both host sites): two host arm
sites are two places to forget, and the invariant would still be a host
property provable only with a live process. As a reducer command it is a
pure-reducer property with a pure test, matching P3.

Scope: `lib/TerminalPTY/Sources/PaneProcessLifecycle/PaneProcessLifecycle.swift`,
`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`, and their
test targets. No CLI, protocol, or app-layer change.

Ordering constraint with the rest of Wave 8: this touches `beginShutdown`,
the command switch, and the reducer; PTY-6 touches the census functions.
Disjoint code, either order compiles. Land after GATE-4 if it has rewritten
`closeRacingPromptSpawnUsesTeardownLadder`, and re-read that test either way.

## 3. Invariants

- I1. The reducer emits the arm-the-bound command exactly once per ladder:
  on the transition that crosses from an unbounded state into the bounded
  region `{.closingWhileSpawning, .tearingDown}`, whatever event and prior
  state caused it, and never again while inside it. `.idle` -> `.finished`
  is not a crossing.
- I2. A host whose reducer is in the bounded region has the exit bound
  armed; the host arms it only by interpreting that command. One deadline
  per ladder follows from I1, so a later `requestShutdown` on a host already
  in the ladder cannot extend it.
- I4. Existing expiry behavior is unchanged: the host attempts SIGKILL on
  every enumerable session member, reaps the owned leader, abandons an
  in-flight launch, and releases ownership; a ladder that converges first
  cancels the bound and scores no forced quiescence.
- I5. Lifetime rules hold as today: the timer stays behind `[weak self]`
  and the retained-source registry; nothing new is stored.

## 4. Proof obligations

- PO1 (I1, P1, P2). `PaneProcessLifecycleTests`: the existing lifecycle
  interleaving test asserts, for every close/exit event ordering it already
  enumerates (including `.requestClose` while `.drainingOutput` and
  `.spawnSucceeded` after `.closingWhileSpawning`), that the command stream
  contains the arm command exactly once iff the ladder was entered; plus a
  direct case that `.requestClose` from `.idle` emits none.
- PO2 (I2, the bug). `TerminalPTYHostTests`: host with a 1ms bound running
  the `teardown` probe; the test kills the leader itself (the host sees a
  natural `.childExited`, no `requestShutdown`); assert `whenQuiescent`
  fires, `resourceSnapshot().isReleased`, `forcedQuiescenceCount == 1`, and
  every owned pid is gone. On the current tree the ladder converges at its
  own SIGKILL stage and the forced count is 0; the fix makes the 1ms bound
  win over the ~300ms ladder, moving it to 1. This is a plumbing proof; the
  unkillable-member case is not reproducible in a test (AR2).
- PO3 (I2). `applicationExitTerminationOnTornDownHostReturnsImmediately`
  stays green.
- PO4 (I4). The existing forced-bound and close-while-spawning suites in
  `TerminalPTYHostTests` (`applicationExitTerminationForcesQuiescenceWithinBound`,
  `closeRacingPromptSpawnUsesTeardownLadder`, the abandon-launch tests) stay
  green with no assertion weakened. One live requested-shutdown case among
  them additionally asserts `armedExitBoundCount == 1` at quiescence, so a
  host-side arm left beside the reducer command fails (I2).

Gate: `swift test --package-path lib/TerminalPTY` for both targets, then
`just test` before the commit.

## 5. Non-goals / Accepted risks / Rejected ideas

- Non-goal: changing the default bound (2s) or the grace ladder.
- Non-goal: PTY-6's `SessionCensus`, PTY-2/8/9's sweep changes.
- AR1. A slow-but-honest drain past the bound is now forced on natural
  exit too. The grace ladder totals ~300ms against a 2s bound; the workload
  that shows this is the uninterruptible member the bound exists for.
- AR2. A session member `kill(2)` refuses (e.g. a setuid-root background
  job) survives expiry: the forced kill ignores `EPERM` and the host releases
  ownership after one census. The bound's promise is that the *host* stops
  and reports, not that a process it cannot signal dies; the alternative is
  the unbounded poll this plan removes.
- RI1. Arm in both host sites (the audit's vetted fix): keeps the
  obligation on call sites and the proof on live processes.
- RI2. Arm only in the `.closeMaster` arm: leaves a stalled bootstrap
  unbounded (P1).

## 6. Implementation discretion

- The command's name and whether `.finishTeardown` or a separate command
  cancels the bound, provided I2/I4 hold.
- How the natural-exit host test kills the leader (test-side `kill` is
  enough; no probe mode change required).

## Audit bookkeeping

After the commit lands: tick `- [ ] [PTY-1]` in `## Plan of work` of the
audit file and append `-- done <sha>`.

## Commit progress

- [x] 1. fix(pty): make the exit bound a reducer obligation
- [x] 2. docs(audit): mark PTY-1 complete
