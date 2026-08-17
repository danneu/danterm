# Size test deadlines as hang guards, not as races the gate can lose

## Context

`PaneTapeStreamTests` flaked three times in one day on master's `just test`,
reporting `Code=4864` and passing in isolation. The renderer it exercises has no
defect. `Code=4864` is `NSCoderReadCorruptError`, and
`CocoaError(.coderReadCorrupt)` is thrown at exactly two places in the whole
repo -- both are the expiry branches of that test file's own 2-second deadlines.
Nothing decodes anything there. The failure is, by construction, "a 2-second
deadline expired", and it is reported as a corrupt record.

That is the whole class of bug this plan removes: a test that measures nothing
about time, failing on a time measurement, and lying about why.

## Problem

Three separable defects in test harness code, plus one production constant that
forces a test to spend real seconds:

1. **The deadlines are sized as if they were calibrating something.** Two
   seconds is not a hang guard, it is a race. `just test` runs the gate as an
   oversubscribed `xargs -P` pool under `nice -n 10`
   (`scripts/run-test-suite.sh:200-208`), so every step is deliberately
   deprioritized and competing. The same class runs throughout `app-tests`,
   `cli-tests`, and the DanTermSupport tests, none of the others sighted yet --
   including spin waiters that poll a deadline on `Task.yield()` or a 10ms sleep,
   which is the shape most exposed to a starved machine. Two attempts to
   enumerate these by hand both missed sites, which is why the plan derives the
   list mechanically instead of carrying one.

2. **The expiry does not say it was an expiry.** The repo already
   has an idiom for this -- `POSIXError(.ETIMEDOUT)`, used at
   `app-tests/AppRuntimeCommandTestSupport.swift:194`,
   `app-tests/AppRuntimePendingIpcShutdownTests.swift:74`, and
   `lib/DanTermSupport/Tests/DanTermSupportTests/IpcConnectionWriteTests.swift:330`.
   Several waiters depart from it in two ways. Some report a timeout as an
   unrelated failure -- `CocoaError(.coderReadCorrupt)` in `PaneTapeStreamTests`,
   `CocoaError(.fileReadUnknown)` in both `IpcServerRemoteTests` waiters -- which
   sends the engineer looking for a read or decode bug that does not exist.
   Others return a bare `false` or `nil` into an expectation
   (`IpcConnectionLivenessTests`), which is not misleading but cannot say whether
   the awaited thing failed to happen or the test merely stopped waiting.

3. **The one test that needs concurrency competes for a pool its own suite
   saturates.** `cli-tests/PaneTapeStreamTests.swift:27` dispatches the renderer
   onto `DispatchQueue.global()`. In the same test binary, running in parallel by
   default, `cli-tests/CLICharacterizationTests.swift` holds global-queue workers
   in `accept()` across eleven subprocess-spawning tests (`:346`, `:375`) --
   including one that holds a worker for a hard-coded eight seconds (`:72`).
   A non-overcommit global queue does not grow on demand: it asks the kernel
   workqueue for a worker and collapses further requests while one is already
   outstanding (`references/libdispatch/src/queue.c#_dispatch_root_queue_poke`),
   so on a saturated, deprioritized machine a queued block can wait seconds
   before it starts running.

### Load-bearing premises

- **The deadline's size is not what proves the flushing property.** What the
  cited test proves is that each record is visible *before the next frame is
  written*, and it proves that by write/read ordering: it writes one frame,
  reads one line, then writes the next. A flush that took twenty seconds would
  still prove nothing was buffered pending a later frame, because no later frame
  was written. Raising the bound costs the assertion nothing.

- **The renderer under test cannot hang on its own.** `cli/PaneTapeStream.swift:68-105`
  is a straight blocking read-write loop: no timers, no async, no state that can
  stall once the test has already written the frame. There is no production
  defect to fix here.

- **The correct shape is already in the repo, twice over.** The principle is
  stated at `docs/evidence/2026-08-06-milestone-9-power-performance.md:59` --
  "Timeouts in the responsiveness tests are hang guards only; no elapsed
  duration is an acceptance threshold" -- but it lives in an evidence document
  and `AGENTS.md`'s Tests section says nothing about deadlines. And
  `cli-tests/CLICharacterizationTests.swift:446` reads a line off a descriptor
  with a plain blocking read and does not flake, while
  `cli-tests/PaneTapeStreamTests.swift:406` does the same job behind a 2-second
  poll and does.

- **A Swift Testing time limit cannot unwind a blocking syscall.** Already
  established in-repo and documented in comments at
  `IpcConnectionWriteTests.swift:273` and `:377`,
  `TerminalPTYHostTests.swift:699` and `:2975`, and
  `TerminalPaneSessionControllerTests.swift:2271`. So `.timeLimit` is a backstop
  that reports a failure; it is not the thing that stops the gate hanging. An
  in-test hang guard is still required.

- **`.timeLimit(.minutes(1))` per-`@Test` is house convention** across
  `lib/TerminalPTY/Tests/` and `lib/TerminalCore/Tests/`, and is absent from
  `cli-tests`, `app-tests`, `client-tests`, and the DanTermSupport tests.

- **The eight-second sleep does not need a duration at all.** It exists to hold a
  connection open and silent until the CLI gives up. The CLI's exit already
  signals that, and the fixture holds the descriptor, so holding until EOF is an
  exact statement of the same intent with no clock in it. This is what actually
  releases the parked worker; supplying the timeout separately is what shortens
  the five seconds the test still spends waiting for the CLI's own deadline.

- **A supplied timeout is a domain value, not a test-identity probe.**
  `docs/design/2026-08-17-test-seam-rule.md` R1 forbids production from querying
  test identity; R2 permits a test to supply an ordinary domain value, and R3
  states that any route satisfying both is legal. A duration read from the
  environment the CLI already reads is R2 input: `openSession` cannot distinguish
  a test's short value from a user's long one.

- **The CLI already has exactly this route, and the test already controls the
  child's environment.** `cli/main.swift:156` reads the environment once in
  `main()` and passes it as a parameter to a pure resolver; `EnvVars`
  (`lib/DanTermProtocol/.../EnvVars.swift`) holds the names. `runCLI`
  (`cli-tests/CLICharacterizationTests.swift:288-296`) sets a closed, fully
  test-controlled child environment and already has an `environment:` overload.
  No new plumbing is needed on either side.

## Decision

Treat every wall-clock value in test harness code as a hang guard, and make the
one test that needs concurrency stop depending on a shared pool.

- **Resize.** Every test-harness deadline that guards nothing timing-related is
  sized so that a passing run cannot approach it, and sits strictly below the
  `.timeLimit` backstop so it fires first and produces the legible error.
- **Rename the failure.** Expiry throws the repo's existing timeout error, never
  an error whose meaning is that data was malformed.
- **Decouple.** Test code that must run production work concurrently gets its own
  thread rather than a slot in a pool that sibling tests in the same binary can
  saturate.
- **Remove the self-inflicted load, in two steps.** The silent-endpoint fixture
  holds its connection for exactly the child's lifetime instead of for a fixed
  eight seconds -- that is what frees the parked worker. Separately, the CLI's
  socket timeout becomes a value supplied from outside the process, which is what
  removes the remaining five seconds of gate wall-clock and turns a hardcoded
  constant into a knob a real user can also set.
- **Graduate the rule** into `AGENTS.md`'s Tests section so it stops regrowing.

Scope covers the whole class, not only the sighted file: `cli-tests`,
`app-tests`, and the DanTermSupport tests.

## Invariants

- **I1.** No test-harness deadline is sized such that a passing run under gate
  load can approach it. Such deadlines exist only to stop a hang.
- **I2.** Every in-test hang guard sits strictly below the suite's time-limit
  backstop, so an expiry surfaces as that guard's own named failure rather than
  as a generic time-limit failure.
- **I3.** A hang-guard expiry reports itself as one. It is distinguishable from an
  unrelated data or I/O failure -- it never reuses an error meaning a payload was
  malformed or a read failed -- and from the negative outcome the caller was
  waiting to rule out. Where the guard throws, it throws the repo's established
  timeout error.
- **I4.** No test passes or fails on whether production was fast enough: an
  elapsed duration is never an acceptance threshold. Two uses stay legitimate --
  a generous bound that only proves an operation terminates, and an assertion
  about a duration production itself defines, such as a debounce interval.
- **I5.** Test code that runs production work concurrently does not depend on
  acquiring a slot in a thread pool shared with other tests in the same binary.
- **I6.** A renderer that buffered instead of flushing fails the gate rather than
  hanging it.
- **I7.** The CLI's socket timeout is supplied to the process from outside it as
  an ordinary duration. Production code never asks whether it is under test, and
  cannot distinguish a test's value from a user's.
- **I8.** The pane-tape flushing property is established by the ordering of
  writes against reads, not by how quickly a record arrives.
- **I9.** The silent-endpoint fixture holds its connection for the child's
  lifetime, not for a fixed duration; it contains no wall-clock value.
- **I10.** A supplied timeout that is not a positive number is rejected loudly
  rather than silently falling back to the default.
- **I11.** The CLI's documented surface -- its usage text and
  `integrations/danterm/SKILL.md` -- states every input it reads, in the same
  change that adds one.

## Proof obligations

- **PO1 (I8, I6).** The flushing test still distinguishes a renderer that flushes
  each record from one that buffers -- a buffering renderer fails it.
- **PO2 (I3).** Every hang guard the sweep finds reports, on expiry, that it gave
  up waiting -- distinguishable both from an unrelated failure (a decode,
  corruption, or read error) and from the negative outcome the caller was testing
  for. A guard that returns a bare `false` or `nil` into an expectation satisfies
  the first half and fails the second: the failure cannot say whether the thing
  did not happen or whether the test stopped waiting for it.
- **PO3 (I7).** The shipped `danterm` binary still reports that DanTerm is not
  responding when an accepted connection never speaks, proved end-to-end against
  a real subprocess and a real socket.
- **PO4 (I7).** The CLI's default socket timeout is unchanged when nothing
  supplies one, and a supplied one is honored.
- **PO5 (I5).** The pane-tape stream tests pass with the rest of their binary's
  tests running in parallel and the machine under contention.
- **PO6 (I10).** A malformed or non-positive supplied timeout fails the command
  with a stated reason rather than being ignored.
- **PO7 (I9).** The silent-endpoint fixture releases its connection when the
  child exits, whatever the child's timeout was set to.

## Files

- `cli-tests/PaneTapeStreamTests.swift` -- the sighted flake: the dispatch at
  `:27`, the semaphore deadline at `:346`, the poll deadline at `:411`, and both
  `CocoaError(.coderReadCorrupt)` throws.
- `cli-tests/CLICharacterizationTests.swift` -- the eight-second sleep at `:72`
  and the two five-second accept waits at `:353`/`:385`.
- Every other same-class deadline, which the implementer **enumerates
  mechanically rather than from a list in this plan**. Sweep `cli-tests`,
  `app-tests`, `client-tests`, and `lib/*/Tests` for a literal duration in a
  `poll` call, a semaphore `wait(timeout:)`, a `ContinuousClock` deadline, an
  `SO_RCVTIMEO` `timeval`, and a defaulted timeout parameter, then apply I1, I3,
  and I4 to each hit. Two hand-written inventories of this class have already
  proved incomplete, so the list is derived at implementation time, not carried
  here. `app-tests/IpcServerRemoteTests.swift:616-642` and
  `lib/DanTermSupport/Tests/DanTermSupportTests/IpcConnectionLivenessTests.swift:162-173`
  and `:226-235` are worked examples: spin or poll waiters whose expiry is
  reported as an unrelated read error or as a bare negative result.
- `cli/main.swift` -- the socket timeout constant at `:24`, its two uses at
  `:245-254`, the environment read at `:156`, and the usage text's `Environment:`
  block at `:125-129`, which `:26-28` warns is hand-synced.
- `lib/DanTermProtocol/Sources/DanTermProtocol/EnvVars.swift` -- where the CLI's
  environment names live.
- `integrations/danterm/SKILL.md` -- its `## Context env vars` section at
  `:136-151` is framed as "DanTerm sets these per pane", which a caller-set input
  does not fit; it needs its own place.
- `AGENTS.md` -- the Tests section.

## Non-goals

- Unifying the duplicated descriptor fixtures. Three independent `socketpair`
  implementations and two independent line readers exist across `cli-tests` and
  `app-tests`, and `waitUntilCommandReadable` is redeclared verbatim inside
  `app-tests`. Real duplication, but not the root cause; there is no shared
  test-support target and creating one is a separate architectural decision.
- Serializing the CLI test suite. `@Suite(.serialized)` would mask contention
  rather than remove it, and would slow the gate.
- Changing `cli/PaneTapeStream.swift`. It has no defect.
- Reducing the CLI's default timeout for users. Only the ability to supply one
  changes.

## Accepted risks

- **AR1.** A genuine buffering regression now takes tens of seconds to fail
  instead of two. Accepted: a slow honest failure is worth more than a fast false
  one, and it costs the extra time only on a real regression.
- **AR2.** The time-limit backstop reports a failure without unwinding a blocked
  syscall, so a test that hangs below its guard could still hold a worker.
  Accepted: the in-test guard is the real bound, and this is already the
  understood behavior everywhere `.timeLimit` is used in this repo.
- **AR3.** The supplied timeout becomes a permanent public input, documented in
  two hand-synced places with no automated check, and it is inherited by every
  pane's shell -- so a stray export in a profile would change CLI behavior
  everywhere. Accepted: rejecting a malformed value loudly (I10) keeps that
  failure visible rather than silent, and one documented input is honest where a
  hidden flag would not be.
- **AR4.** Once the fixture holds until the child exits (I9), the flake
  contribution is gone and the supplied timeout is justified by gate wall-clock
  and by being a real user knob, not by the flake. Accepted deliberately: the
  hardcoded constant is the reason a test had to spend real seconds at all, and
  leaving it invites the next sleep-to-outlast.

## Rejected ideas

- **RI1. Delete the in-test deadlines and rely on `.timeLimit` alone.** It is the
  simplest structure on paper -- no wall-clock value in the test at all -- but the
  repo has already established that a time limit cannot unwind a blocking read.
  The gate would report the failure and then hang.
- **RI2. Raise the deadlines and stop there.** Leaves the pool coupling in place,
  so the flake returns whenever contention grows past the new number. It trades a
  structural fix for a bigger constant.
- **RI3. A hidden CLI flag for the timeout instead of a supplied value.**
  "Hidden" means documented nowhere, which contradicts `SKILL.md` being the source
  of truth for the CLI surface -- a surface change that refuses to state itself.
  Unhidden, it is strictly worse than the chosen route: same documentation cost,
  real parser work in the hand-rolled global-flag loop, and it cannot be set once
  for a whole test file.
- **RI4. Drop the subprocess and call a parameterized entry point in-process.**
  Cheapest, and legal under the test-seam rule, but it destroys the coverage.
  `CLICharacterizationTests` exists to characterize the shipped binary; in-process
  it would stop proving the exit status, the stderr wording, and that the real
  socket-level timeout fires.

## Implementation discretion

- The exact hang-guard durations, subject to I1 and I2.
- The supplied timeout's name, units, and the shape of the resolver that reads
  it, subject to I7, I10, and I11.

## Verification

The starvation mechanism is a hypothesis until it is ablated, so establish the
baseline before changing anything:

1. Reproduce first. Run the CLI test binary in a loop under artificial machine
   load until the flake appears, and record the rate. Without this the fix cannot
   be shown to have done anything.
2. Ablate. The claim is that the dispatch at `cli-tests/PaneTapeStreamTests.swift:27`
   waits on a pool its own binary saturates. Moving that one call off the shared
   pool, with the deadlines left at two seconds, should make the flake disappear
   on its own. If it does not, the mechanism is wrong and the plan needs
   revisiting before the rest of it lands.
3. Then the rest: `just test` green, and green again under the same artificial
   load, to discharge PO5. `swift test --filter PaneTapeStreamTests` in isolation
   still passes.
4. Discharge PO1 by making the renderer buffer, watching the flushing test fail
   for the buffering reason, and reverting.
5. Discharge PO3 and PO4 through the existing characterization test against the
   real subprocess.

## Commit progress

- [x] 1. Run the pane-tape renderer off the shared dispatch pool and guard its waits legibly
- [x] 2. Report every remaining test hang-guard expiry as a timeout, and graduate the rule into AGENTS.md
- [ ] 3. Hold the silent-endpoint fixture for the child's lifetime instead of eight seconds
- [ ] 4. Supply the CLI's socket timeout from outside the process, and document it

## Implementation notes

- **The flake did not reproduce, so the mechanism was measured instead.** Over
  100 runs of the CLI test binary failed to produce a single failure: serial
  rounds under 24 and 48 CPU spinners, and 8 to 16 concurrent copies of the
  binary under `nice`, mimicking the gate's oversubscribed pool. Verification
  step 1 asked for a reproduction rate and none was obtained on this machine.
- **The ablation was run against a direct measurement of the dispatch site
  rather than against the failure.** Temporary instrumentation recorded the
  submit-to-start latency of the block at `cli-tests/PaneTapeStreamTests.swift:27`.
  On the shared global queue it measured about 0.19s at 8x concurrency and about
  0.37s at 16x -- scaling with load, and unbounded in principle. Moved to a
  dedicated thread, the same measurement collapsed to about 0.00005s. The
  machine carried ambient load from other work throughout, so the absolute
  numbers are not trustworthy and are not treated as thresholds; the load-scaling
  direction and the four-orders-of-magnitude contrast are what the claim rests on.
- **The suite gets `.timeLimit` at the suite level, not per `@Test`.** The plan
  recorded per-`@Test` as the house convention in `lib/`, but the backstop exists
  to bound tests that do not yet exist as much as the ones that do, and this file
  is one suite. Guards are 30 seconds against a 1-minute backstop, and the whole
  suite passes in under 0.06 seconds, so I1 and I2 hold with a wide margin.

### Slice 2

- **The mechanical sweep found seven files still holding guards.** `cli-tests/CLICharacterizationTests`
  (two accept waits whose expiry was discarded outright),
  `app-tests/IpcServerRemoteTests` (two spin waiters throwing
  `CocoaError(.fileReadUnknown)`, plus a 2-second `SO_RCVTIMEO` surfacing as
  `EAGAIN`), `app-tests/AppRuntimePendingIpcShutdownTests` and
  `app-tests/AppRuntimeCommandTestSupport` (2-second polls whose expiry became a
  `-1` indistinguishable from a read error),
  `lib/DanTermSupport/.../IpcConnectionWriteTests` (a defaulted 2-second poll and
  two 2-second semaphore probes returning `nil`),
  `lib/DanTermSupport/.../IpcConnectionLivenessTests` (a 2-second poll and a
  4-second spin waiter returning `nil`), and
  `lib/DanTermSupport/.../DebouncerTests` (two 3-second semaphore waits). Every
  guard is now 30 seconds under a 1-minute suite backstop. `lib/TerminalPTY` and
  `lib/TerminalCore` already conform -- 20-second guards under per-`@Test`
  1-minute backstops -- so the sweep left them alone.
- **Two durations are meant to expire, so they are named apart from the guards.**
  `IpcServerRemoteTests.connectWhenSlotReleases` learns the slot is still held by
  not being greeted, and `IpcConnectionWriteTests.silentPeerFailsTheRead` exists
  to prove the reads give up. Raising the shared guard would have made the first
  loop turn over once in 30 seconds and the second spend a minute. Both now
  supply a short probe value explicitly at the call site, leaving the guard high
  for every read that does expect an answer.
- **Guards that return a bool were kept as bools where the expiry is the negative
  outcome.** `IpcConnectionLivenessTests.reachedEndOfStream` polls for a teardown;
  "the deadline passed" and "the socket is still open" are the same observation,
  so I3's second half has nothing to separate. Every other waiter that returned a
  bare `false` or `nil` now throws `POSIXError(.ETIMEDOUT)`. The AGENTS.md rule
  names this exception rather than stating a ban the repo does not keep.
- **PO2 was discharged by ablation, not by inspection.** Dropping the liveness
  guard to 50ms made the expiry surface as `Error Domain=NSPOSIXErrorDomain
  Code=60 "Operation timed out"`, named against the waiting line.

## Follow Up

- `lib/DanTermSupport/Tests/DanTermSupportTests/IpcConnectionLivenessTests.swift:50`
  asserts `elapsed < .seconds(2)` after a 0.4-second liveness bound. The lower
  bound is production's own number, but the 1.6 seconds of slop above it is
  invented by the test, so under gate load this can still fail on "production was
  fast enough". Left alone because the sweep's criteria name deadlines, not
  elapsed assertions, and removing the upper bound loses the claim that a dead
  peer is not held past the bound. Decide whether production should state a
  reclaim margin the test can assert against instead.
