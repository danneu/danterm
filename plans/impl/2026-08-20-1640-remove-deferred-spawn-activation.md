# Remove deferred spawn activation

## Problem

`TerminalPTYHost` has two paths that deliver `.spawnSucceeded` to the
reducer, and only one of them is guarded. `receiveSpawn`
(`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift:1784`)
checks `generation == spawnGeneration` and discards a superseded launch.
But when `resourceLifecycle.gateSpawnActivation(resume:)` returns
`.deferred`, the parked resume closure calls `enqueueSpawnActivation()`
(:1825), which posts `process(.spawnSucceeded)` carrying no generation and
re-checking nothing.

If teardown finishes while the activation is parked, the late release
restarts the teardown ladder on a quiescent host: `finishTeardown` (:2584)
bumps `spawnGeneration`, cancels the retained sources, closes the master,
and sets `teardownFinished`; the released `.spawnSucceeded` then reaches a
reducer still in `.closingWhileSpawning`, which runs `beginTeardown` and
returns `[.closeMaster]`; `closeMaster` (:2413) has no `teardownFinished`
guard and fires `.masterClosed`; that arm returns `[.signalSession(.hangup),
.scheduleGrace(.hangup)]`, and `scheduleGrace` registers a fresh timer in
`retainedSources` after quiescence. `completeTeardownIfPossible` guards on
`teardownFinished == false`, so the host is never released again.
Observable: `resourceSnapshot().isReleased` becomes true, then flips back
to false and stays false.

**Where the state comes from.** The parked window is not a production
interleaving. `receiveSpawn` records `masterFD`/`leaderPID`/`sessionID`,
installs sources, calls `process(.spawnSucceeded)`, and `process` executes
the resulting `.activateIO` synchronously in the same owner-queue turn
(:1449, :1703, :1857). `SystemTerminalPTYResourceLifecycle
.gateSpawnActivation` returns `.proceed` unconditionally, so nothing
suspends inside that turn and no production event can enter it. The only
way to sit between installation and activation is the injected witness
`ControlledTerminalPTYResourceLifecycle.holdSpawnActivation`.

That witness violates
[docs/design/2026-08-06-swift-terminal-engine.md](../../docs/design/2026-08-06-swift-terminal-engine.md)
`B7`: a lifecycle witness is allowed only where the system boundary is
genuinely nondeterministic. `gateSpawnActivation` is not a boundary at
all -- it is a suspension point manufactured between two synchronous
statements.

## Decision

Delete the deferred spawn-activation path instead of guarding it.

- Remove `gateSpawnActivation` from `TerminalPTYResourceLifecycling` and
  from `SystemTerminalPTYResourceLifecycle`.
- Remove `enqueueSpawnActivation` from the host; `receiveSpawn` calls
  `process(.spawnSucceeded)` directly after installing sources.
- Remove the activation hold from `ControlledTerminalPTYResourceLifecycle`.
- `receiveSpawn`'s existing generation check stays as the single
  generation-guarded delivery boundary, and becomes the only one.

This makes a late activation unrepresentable rather than defended, and it
removes protocol surface, host code, witness state, and test scaffolding.
Guarding the resume instead would keep an unreachable interleaving alive
and add mechanism to fence it.

The sibling gate stays. `gateSourceCancellationAcknowledgement` sits on a
real asynchronous edge -- a Dispatch source's cancellation handler runs on
its own schedule after `cancel()` -- so it satisfies `B7`. It is also
already id-keyed, and `sourceCancellationHandlerRan` re-checks
`retainedSources[id] != nil`, so a late acknowledgement is a no-op.

The activate-before-cancel calls in `cancelAllRetainedSources` (:929),
`cancelReadSource` (:2447), and `cancelProcessSource` (:2454) stay. They
are generic cancel-safety for any retained source, not a defense of the
spawn-activation window. `closeMaster`'s comment (:2415) says the opposite
-- that a close can race source installation before the reducer activates
IO -- and `I2` makes that state impossible, so the comment is rewritten to
state the generic reason instead.

## Invariants

- **I1.** There is exactly one path from a spawn outcome to
  `.spawnSucceeded`, and it applies the `generation == spawnGeneration`
  check. Nothing can deliver a spawn event without passing that check.
- **I2.** Every source the host installs for a spawn is activated in the
  same owner-queue turn it is installed in, or is not installed at all
  (`descriptorOwnershipSealed`). No owner turn ends with a suspended,
  unactivated spawn source.
- **I3.** Once `resourceSnapshot().isReleased` is true, it stays true:
  `retainedSources` remains the single authority on what teardown owns,
  and nothing joins it after quiescence.
- **I4.** Spawn adoption behavior is unchanged: a current-generation spawn
  is adopted exactly as today, and a superseded one is still discarded
  with its child released off the owner queue.

## Proof obligations

All proofs speak through `resourceSnapshot()`, submission completions, and
the shutdown completion callback -- never private fields or helper names.
`scripts/terminal-pty-host-test-seam-lint.sh` forbids new test-control
seams on the host; this plan removes one and adds none.

- **PO1 (I1, I3).** The buffered-input tests at TerminalPTYHostTests.swift
  :212, :239, and :268 drop `holdSpawnActivation` and instead park the
  spawn at its launch report. That hold is a real worker-to-owner
  boundary: the blocking spawn parks before reporting the launch, so the
  host is genuinely mid-spawn with input pending. Their assertions
  (pending until delivered, rejected on close, whole-submission overflow
  rejection) are unchanged. The hold must keep these tests childless --
  they belong to the suite that forks no child process, so the launch-report
  control wraps their existing `ChildlessPTYChannel` rather than
  `ControlledTerminalPTYSpawner`, which launches through
  `SystemTerminalPTYSpawner` and would fork real shells into a suite that
  runs beside process-wide lifecycle tests.
- **PO2 (I4).** Existing spawn-adoption tests and the superseded-launch
  discard tests keep passing unchanged.
- **PO3 (I2).** `closeDuringSpawnJoinsInactiveSources` (:3183) and
  `forcedShutdownJoinsInactiveSources` (:3224) are deleted. Both stage
  "sources installed but never activated, then shutdown", which `I2` makes
  unreachable: a shutdown that arrives before delivery seals descriptor
  ownership in `beginShutdown` (:879), so `receiveSpawn` installs no
  sources, and a shutdown cannot arrive after installation because
  activation is in the same turn. Forced-quiescence coverage is not lost --
  `forcedQuiescenceCount == 1` is still asserted at :3024, :3106, :3141,
  and :3582. Held source-cancellation-acknowledgement coverage is not lost
  either; those tests keep their acknowledgement holds and drop only the
  activation hold.

## Non-goals / Rejected ideas

- **RI1: generation-guard the deferred resume.** Rejected. It fences a
  window that only the test witness can open, and keeps a `B7`-violating
  seam alive to be defended by later plans.
- **RI2: blanket `teardownFinished` guards in `closeMaster` and
  `scheduleGrace`.** Rejected. With the deferred path gone there is no
  entry into that state, and guards in the ladder's interior would mask a
  future missing generation check instead of letting it fail loudly. If a
  later incident shows a second entry path, guard that path's entry.
- **RI3: generation-stamped gate token, or a generation on the reducer
  event.** Moot once the gate is gone; the reducer must also stay free of
  host-side launch bookkeeping.
- **Non-goal:** the source-cancellation acknowledgement gate. Real
  boundary, already id-keyed and re-checked; no change.
- **Accepted risk AR1:** `activateIO`'s sealed-ownership arm (:1858) and
  the activate-before-cancel calls have no test that reaches them through
  the spawn window any more. They are cheap, idempotent, and protect any
  future source, so this plan keeps them without manufacturing a seam to
  exercise them.

## Implementation discretion

- Whether `ControlledTerminalPTYResourceLifecycle` keeps a shared hold
  helper after the activation hold is removed, and how the three rewritten
  input tests order their launch-report release relative to close.

## Implementation notes

- The launch-report hold `PO1` calls for reuses the existing
  `ControlledTerminalPTYSpawner` rather than adding a second test spawner. The
  helper grew a `wrapping:` parameter that defaults to
  `SystemTerminalPTYSpawner()`, so the three rewritten input tests pass their
  own `ChildlessPTYChannel` and still fork no child, and every existing caller
  is unchanged. `waitForDeliveryPermission` now delegates to the wrapped
  spawner before applying its own hold.
- All three rewritten tests release the launch report after the close they
  stage, matching the order the old activation hold used.
