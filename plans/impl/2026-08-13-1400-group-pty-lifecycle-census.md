# Move test-only state and fault injection out of the production PTY actor (S12)

## Problem

`docs/scratch/2026-08-11-simplification-audit.md` S12, verified current on
2026-08-13. `TerminalPTYHost`
(`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`, ~2100
lines) stores ~25 test-only properties, and five production paths carry
test-driven control-flow branches:

- `spawn(_:)` threads two usleep delay knobs through the launch handoff.
- `receiveSpawn` can park `spawnSucceeded` behind an installed-sources hold.
- `childExited` runs the real `waitid` and then overwrites its result while
  transient-wait injections remain.
- `completeMasterCloseIfPossible` substitutes a `dup2` probe for the real
  `close`.
- `sourceCancellationHandlerRan` can queue acknowledgements instead of
  applying them.

The shipping teardown ladder therefore carries a parallel test-driven variant
of itself, and the seams are exercised only by timing (usleep + real races),
so the tests they serve are slower and weaker than they need to be.

Blast radius (verified): every seam consumer lives inside `lib/TerminalPTY`;
zero references from `app/`, `cli/`, `tests-ui/`, or other packages. The
non-test `TerminalPTYTestSupport` library consumes none of the seams being
removed.

## Decision

Extract the collaborators the seams stand in for as protocol witnesses
injected through the existing package init (which already injects
`captureTransitions`, `flightTapeConfiguration`, `flightTapeClock`,
`applicationExitBound`). Three witnesses, split by calling context and
syscall domain -- not fewer (the two contexts have incompatible blocking
rules) and not more (per-seam witnesses would split one authority across
injection points):

- **Spawning** (runs on the concurrent spawn queue; may block): owns the
  `PTYSpawner.spawn` call and a post-resolve delivery hook sitting exactly
  where the delivery delay sits today. The test implementation wraps the
  production one and gates `didLaunch` and delivery on semaphores, replacing
  both usleep knobs with deterministic blocking. It also records the spawned
  leader, replacing the host's `lastIssuedLaunch` property and the two
  test reads it backs.
- **Child-exit probing** (owner queue; synchronous, never blocks): owns the
  whole `waitid` probe including classification, returning
  exited / not-yet-waitable / failed. The test implementation wraps the
  production probe and reports not-yet-waitable for the first N calls.
- **Source/descriptor lifecycle** (owner queue; synchronous verdicts, never
  blocks): one authority for how sources and the master descriptor leave
  service -- the spawn-activation gate, the per-source cancellation-
  acknowledgement gate, and the close-master operation (production: one
  `Darwin.close`; test: the `dup2` probe). Gates return proceed/deferred; on
  deferred, parked state lives in the test witness, and release re-enters the
  host through a pre-hopped `@Sendable` resume closure that only enqueues.

The four census counters (`callbacksAfterTeardown`, `forcedQuiescenceCount`,
`emittedUpdateSignalCount`, `updateSignalsAfterTermination`) collapse into
one struct field nested inside `TerminalPTYResourceSnapshot`; no flat-field
compat shim.

Protocols and production implementations live in the `TerminalPTYHost`
target as `package` declarations (they appear in the package init
signature); test implementations live in the test target, which is the only
substituting consumer. The public init is untouched, and no production
caller ever passes a witness other than the production one -- the default
is the only value production code supplies.

B7 in `docs/design/2026-08-06-swift-terminal-engine.md` currently rejects
abstracting a direct system operation solely for mocking, and the
descriptor-close witness plus the always-proceed gates are exactly that
shape. B7 is amended in the same change to admit them. The admitting rule
is a property of the boundary, not of its history, so it stays decidable
from the source alone after any later refactor: a witness is admissible
only where the system boundary is genuinely nondeterministic, that
nondeterminism participates in an ownership or lifecycle invariant, and no
production input can drive it deterministically. The production
implementation must be stateless and semantically identical to the direct
call it replaces, and substitution must be confined to the owning package's
test target. Everything else keeps B7's original rejection: a deterministic
direct system call with no policy gets no abstraction, however convenient
mocking it would be.

## Invariants

- I1: The host actor holds no test-only control or fault-injection state,
  and no test-only branch, in the spawn, child-exit, master-close, or
  source-cancellation paths; it always calls the witness. Passive
  observation state -- the capture arrays, the output observers, the
  `#if DEBUG` output-window trio, and the census counters -- is explicitly
  out of scope (see Non-goals); it records what happened and steers
  nothing.
- I2: Each production witness is stateless and its body is the moved
  production lines verbatim (same `waitid` flags and classification, same
  `close`, same `PTYSpawner.spawn` call); the host call site gains no new
  branch and, on a proceed verdict, performs the action inline in the same
  owner turn as today.
- I3: Owner-queue witness calls return synchronously and never block; a
  test release never requires the owner queue (it signals a semaphore or
  invokes resumes that only enqueue). Blocking gates are legal only on the
  spawn queue, where they park exactly the thread the usleep parked.
- I4: Wire, CLI, and app-visible behavior are unchanged; the change is
  invisible outside `lib/TerminalPTY`.

## Proof obligations

- PO1 (I1): After the final step, a grep gate over the host file fails on
  any of the removed seam names; the gate lands with the change (see
  Verification).
- PO2 (I2, I4): The existing lifecycle suite -- `TerminalPTYHostTests`
  including the race-sensitive teardown tests, plus
  `TerminalPaneSessionTests` -- passes unchanged in what it asserts; run
  `scripts/test-terminal-pty.sh` repeatedly (>= 10 consecutive green runs)
  after the owner-queue and spawn witness steps.
- PO3 (I3): The rewired hold/release tests (source-cancellation holds,
  activation hold, descriptor-reuse probe) pass under parallel load; the
  rewired spawn-race tests replace their poll/usleep choreography with
  gate-edge waits and still pin the same outcomes (ladder convergence,
  forced-quiescence counts, child discarded).

## Delivery

Ordered so the suite is green after every step; each step pairs the
production change with its test rewiring, and the `package` seam functions
are deleted in the same step as the witness that replaces them.

1. Census collapse (pure representation change; ~31 mechanical test-read
   edits).
2. Child-exit probing witness (smallest; proves the init-param + `makeHost`
   pattern; rewires one test). Amend B7 in
   `docs/design/2026-08-06-swift-terminal-engine.md` in this same commit --
   the first witness is the point where the current wording is
   contradicted.
3. Source/descriptor lifecycle witness (deletes eight host properties and
   six package methods; rewires eight tests).
4. Spawning witness (riskiest, last; deletes the delay knobs and
   `lastIssuedLaunch`; rewires three tests -- prompt-spawn close,
   pre-report application exit, and resolved pre-delivery application exit;
   bumps `SpawnedPTY` /
   `PTYSpawnOutcome` to `package`).
5. Mark S12 closed in `docs/scratch/2026-08-11-simplification-audit.md`:
   record the closing commit hash(es) in the S12 summary-table row, matching
   the existing S03/S04 convention ("docs(audit): credit S12 to the commits
   that closed it").

## Non-goals / Accepted risks / Rejected ideas

- Non-goal: the `#if DEBUG` output-window trio, the capture arrays behind
  the init-injected `captureTransitions` flag, and
  `setTestUpdateHandler` / `observeTestOutput` / `deliverOutputForTesting`
  stay as they are -- they observe, they do not branch.
- Non-goal: `forceExitBoundForTesting()` stays. It is not stored state and
  not a branch -- it invokes an existing production transition, parallel to
  the blessed `applicationExitBound` injection -- and the descriptor-join
  ordering it pins cannot be reproduced by a tiny injected bound, which
  would race the cancellation handlers.
- AR1: Releasing held cancellation acknowledgements changes from one owner
  turn to N consecutive FIFO turns. The barrier property (master close only
  after the last acknowledgement) is turn-count-independent and no test
  asserts batch atomicity; noted in the relevant commit message.
- AR2: One spawn-race test (exit during a withheld spawn report) keeps a
  real-time margin for its back half: the abandonment flip happens on an
  owner queue about to block, and fencing it would require a test hook
  inside `InFlightLaunch`. The gate still makes its front half (child
  exists, report withheld) certain, so the test gets strictly stronger, not
  weaker; documented on the test.
- Rejected: folding the activation hold into the spawning witness -- it runs
  on the owner queue under a never-block contract, and the property it
  serves is source-lifecycle, not spawn.
- Rejected: a runtime production-witness census to prove no test branches
  remain -- it would add state to prove the absence of state; the type
  system plus the grep gate carry that proof.

## Verification

- `swift test --package-path lib/TerminalPTY` green after every delivery
  step; `scripts/test-terminal-pty.sh` >= 10 consecutive green runs after
  steps 3 and 4.
- Add the grep gate to the check lane in step 4: fail if the host file
  mentions any removed seam name (the kept `forceExitBoundForTesting` is
  the single allowed exception).
- Review checklist per step: production witness body is the moved lines
  verbatim; host call site has no new branch.
- `just test` for the full local gate before the audit-marking commit.

## Implementation discretion

- Protocol and type names, member signatures, gate/observer callback
  shapes, and file placement within the `TerminalPTYHost` target.
- Exact rewired choreography per test, within the I3 contract.

## Commit progress

- [x] 1. refactor(pty): group lifecycle census observations
- [x] 2. refactor(pty): inject child-exit probing
- [x] 3. refactor(pty): inject source and descriptor lifecycle
- [x] 4. refactor(pty): inject deterministic spawning
- [x] 5. docs(audit): close S12 production fault-injection finding
