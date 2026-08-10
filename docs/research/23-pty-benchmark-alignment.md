# PTY benchmark alignment with the dispatch-join PTY rewrite

Research started: 2026-07-30. **Status: CLOSED -- `D1`, `D3`, and `D4` are
implemented; `D2` completed with a negative screen. `F1`-`F3` are from source;
`F4`-`F9` are measured/verified.**
Continues: [20-pty-throughput-and-interactive-stimulus.md](20-pty-throughput-and-interactive-stimulus.md)
(closed with `20/D5`'s decline; this file inherits its two surviving
actionables). Adjacent to doc 19 (owner-queue occupancy, LIVE) and doc 22
(application-exit corruption, closed), whose fix grew into the rewrite this
file measures against.

## Purpose

The PTY layer was rewritten on 2026-07-30
([plans/impl/2026-07-30-1657-terminal-pty-dispatch-join-shutdown.md](../../plans/impl/2026-07-30-1657-terminal-pty-dispatch-join-shutdown.md),
commits `a932c5f`..`a1c00b9`, with precursors `6d97878` and `50c5240` from doc
22's Phase F). The benchmark system was built and calibrated against the old
PTY and has not been re-examined. This file owns three questions:

1. **Instrument integrity.** Do the PTY-coupled brackets still measure what
   their names and consumers assume -- specifically the fence-stall bracket,
   whose delivery path was rebuilt underneath it (`F2`)?
2. **Calibration validity.** `synchronized-frames`' frozen rule was screened on
   the pre-rewrite tree the same day the tree changed, is already fragile per
   screen (`20/F15`: confirm detection fails on two of three individual
   screens), and skipped the 100,000-trial confirmation stage the other five
   workloads had. This file inherits closing that gap and must decide *which
   tree* the closure characterizes (`D2`).
3. **Coverage.** The rewrite's central product -- a truthful shutdown
   transaction whose completion certifies quiescence -- is exercised by no
   benchmark and no harness path; the harness kills the app rather than
   quitting it (`F3`). Whether exit-to-quiescence latency, newly measurable,
   earns an instrument is this file's new question (`D3`).

Scope boundary, inherited from doc 20: this file is about **what the benchmark
system measures and reports**, not about making anything faster. Cross-project
comparability remains rejected (doc 20, Rejected).

## Investigation rules

Inherited:

- **No implementation of a code candidate before a user direction gate**
  (`agent-docs/terminal-performance.md`).
- **Distinguish the three brackets by name every time** --
  `feedDurationNanoseconds`, `producerWriteNanoseconds`,
  `finalDrawNanoseconds` (doc 20).
- **Any derived rate names its denominator** (doc 20).
- **A metric with no frozen rule reports a bare percentage and never a
  verdict** (`17/D6`).
- **Read a gate from the code that owns it, not from a reconstruction of it**
  (`20/F15`).
- **A screen is not a freeze** (`20/F15`): selection at 50,000 trials, then the
  exact cell re-run at 100,000 trials with disjoint fresh seeds and no
  parameter changed after screening.

Added here:

- **Stamp every quoted PTY-coupled number with its delivery era.** The boundary
  is `50c5240` (2026-07-30 16:02). Before it: stream-delivered updates and one
  timed fence per delivery. After it: callback-only updates and two fences per
  delivery with only the second timed (`F2`). Doc 19's stall numbers and doc
  20's fence-regime table are pre-boundary; nothing measured today is
  comparable with them until `D1` resolves the bracket.
- **A claim worded around "the consume task" or "the update stream" is
  mechanism-bound and stale.** The bracket-level claims those documents make
  survive; re-derive mechanism wording from `TerminalPaneDeliveryBoundary` and
  `TerminalPTYHost.setUpdateHandler` before repeating any of it.

## Trigger and current evidence

Opened 2026-07-30 by the user, immediately after the dispatch-join shutdown
plan landed, with doc 20 stale: partially implemented, its close condition
(`20/D5` decided) met, and its instruments never re-checked against the
rewrite. The rewrite's benchmark-relevant changes, read from the plan and the
commits:

- `6d97878` / `50c5240` (doc 22 Phase F, 15:42/16:02) -- removed Swift
  Concurrency from the exit path, replaced the stream-driven update consumer
  with `setUpdateHandler` plus a coalescing main-queue delivery
  (`TerminalPaneUpdateDelivery`), and split the consume path's single timed
  fence into two fences (`F2`).
- `a932c5f`..`a1c00b9` (16:58-18:45) -- unified shutdown observation around
  host callbacks, joined Dispatch resources before publishing quiescence,
  renamed the delivery class to `TerminalPaneDeliveryBoundary` and routed
  pointer/link/pane-menu callbacks through it instead of `Task { @MainActor }`,
  removed the production `AsyncStream` channel (async conveniences now live in
  `TerminalPTYHostTestSupport`), and retained hosts in a termination registry
  until quiescence.

Provenance: `F1`-`F3` are read at `a1c00b9`, worktree clean but for research
docs. Nothing is measured; every claim below that needs a number says so.

## Current hypotheses

### H1 -- the fence-stall bracket undercounts, systematically and silently, since `50c5240`

**Result: confirmed on bracket coverage, refuted on the proposed split
mechanism (`F4`).** The first fence is material, but the second does not meet a
drained queue consistently and was larger in one of the two blocks.

Proposed mechanism: `consumeHostUpdate`
(`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift#consumeHostUpdate`)
performs two `queue.sync` fences per delivery. The first,
`fencedConsumptionMetadata()`, is untimed and is the one that waits behind an
in-flight read turn; the timed second, `fencedFrameState()`, then meets a
queue that the first sync just drained. The bracket therefore excludes most of
the wait it exists to measure, and the miss renders as a *small stall* -- the
reassuring answer exactly when the instrument is blind, the failure shape
`agent-docs/terminal-performance.md` ("Make an instrument report its own
coverage") catalogs.

Competing explanation: deliveries are coalesced, so by the time main runs the
scheduled wakeup the read turn that requested it has often finished, the
metadata sync lands on an idle queue, and the miss is negligible.

Distinguishing experiment: time both syncs separately (benchmark-build-only
change) under `scrollback-stream` and `synchronized-frames`, and read the
split. Cheap: one build, two quick blocks. Feeds `D1`.

### H2 -- the frozen decision rules survive the rewrite

Grounds for expecting survival (`F1`): the frame-delivery coalescing predates
the plan (rename, not rebuild), the removed `Task` relays are pointer, link,
and pane-menu callbacks off the frame path, the drain path (read turns, the
16 KiB cap) is untouched, and the harness kills the app before any of the new
exit code runs (`F3`) -- so block-level noise should be unchanged.

Stated to be checked, not assumed, because `synchronized-frames` is the
workload with no margin: false-positive rates at 0.0084-0.0095 against a 0.01
gate (`20/F11`) and per-screen detection failures (`20/F15`). Even a small
noise shift moves it. If `D2` selects fresh post-rewrite screens, they are
this hypothesis's check on the one workload where it matters; the other five
workloads' rules are far older than this rewrite and carry real margin, so
they are checked only if evidence appears (see Rejected).

### H3 -- exit-to-quiescence latency is now measurable and unowned

The rewrite makes shutdown completion truthful (plan invariants I2/I6):
quiescence publishes only after every source cancellation handler has run, the
PTY is closed, and the child is resolved -- and `whenQuiescent` observers give
it a timestamp. That converts "how long does exit take under load" from
unobservable to a callback delta. No instrument owns it; the plan's own
verification was manual Cmd-Q. Whether it earns one, and in what shape, is
`D3` -- with `19/F4`'s warning attached: the teardown process census is
proportional to machine load, not terminal state, so any measured number is
machine-shaped and a calibrated rule is likely refused by its own noise.

## Selected direction

`D1` selected and implemented the single-fence consume: the frame-state drain
returns lifecycle metadata alongside the frame state from one owner-queue
transaction. This restores the single timed sync that existed before
`50c5240`, folds the whole per-delivery wait back inside the bracket, and
halves the per-delivery fence count. See `F5`. `D3` selected package-level
coverage rather than a new benchmark: the real registry shutdown test now
uses chatty output and enforces the existing 3-second stress ceiling, while
the harness keeps its post-result SIGTERM cleanup. See `F7`. `D2` selected
fresh post-fix screens, and both refused every confirm cell in the predeclared
grid. See `F8`; `D4` resolves the resulting benchmark-policy decision by
demoting the workload without deleting its instrument (`F9`).

## Task ledger

### Phase 1 -- instrument integrity

- [x] Decompose what the rewrite changed on benchmark-coupled paths and what
      it only renamed -- recorded in `F1`.
- [x] Audit the fence-stall bracket against the rebuilt consume path --
      recorded in `F2`.
- [x] Run `H1`'s experiment: time both consume-path syncs under
      `scrollback-stream` and `synchronized-frames` and record the split --
      recorded in `F4`, feeds `D1`.
- [x] Sanity-check the drain bracket end to end on the new tree: one
      `scrollback-stream` block, composition inside `20/F2`'s envelope
      (drain share 89.9-97.9%). Measured 91.45% in `F4`; `H2` stays scoped to
      `synchronized-frames`.

### Phase 2 -- harness lifecycle

- [x] Audit harness teardown against the new shutdown transaction -- recorded
      in `F3`.
- [x] Verify `F3`'s platform claim cheaply: send SIGTERM to a scratch app
      instance and confirm `applicationWillTerminate` does not run --
      recorded in `F6`.
- [x] Pin the missing intersection in the package suite: chatty owner work,
      the real termination registry path, and the existing 3-second ceiling
      -- recorded in `F7`.
### Phase 3 -- calibration and coverage gates

- [x] `D1` direction gate: fix the fence bracket. **Single-fence consume
      selected by the user and implemented; recorded in `F5`.**
- [x] `D2` direction gate: venue for `synchronized-frames`' missing
      100,000-trial confirmation stage -- archived pre-rewrite series or fresh
      post-rewrite screens. **Fresh screens selected by the user; recorded in
      `F8`.**
- [x] Execute the selected `D2` path; record whether `confirm 8p@2.15%`
      survives, and its per-screen detection this time. **It fails both fresh
      screens and pooled evidence; no confirm cell reached the 100,000-trial
      stage.**
- [x] `D3` direction gate: does exit-to-quiescence latency earn an instrument,
      and in what shape? Includes deciding whether the harness keeps killing
      the app or adopts a graceful quit -- they share the exit path.
      **Package-test coverage selected by the user and implemented; recorded
      in `F7`.**
- [x] `D4` direction gate: respond to a calibration screen that refuses the
      workload -- demote `synchronized-frames` to a collectable candidate or
      retain a frozen rule the fresh evidence rejects. **Demotion selected by
      the user and implemented; recorded in `F9`.**

## Findings log

### F1 -- what the rewrite changed on benchmark-coupled paths, and what it only renamed

- Status: complete, from source; nothing measured.
- Date: 2026-07-30, read at `a1c00b9`.
- Observation, delivery path: the coalescing main-queue frame delivery
  **predates the dispatch-join plan**. `TerminalPaneUpdateDelivery` (one
  scheduled wakeup at a time, stoppable) arrived in `50c5240`; `34122b3`
  renamed it `TerminalPaneDeliveryBoundary`, kept `scheduleFrame`'s logic
  identical (the `isScheduled` flag renamed `isFrameScheduled`), and added
  `enqueue` for ordered semantic callbacks. The `Task { @MainActor }` relays
  the plan removed carried pointer, link, and pane-menu callbacks -- none on
  the frame path a benchmark block measures.
- Observation, host boundary: the production `AsyncStream` update channel is
  gone; `setUpdateHandler` is the only host notification mechanism, and async
  conveniences live in `TerminalPTYHostTestSupport`
  (`TerminalPTYHostAsyncSupport.swift`). An architecture gate
  (`scripts/terminal-exit-concurrency-lint.sh`) keeps Swift Concurrency out of
  `lib/TerminalPTY/Sources/` and the production backend adapter.
- Observation, harness coupling: the harness couples to the app through
  environment variables and artifact files only -- `TerminalBenchmarkObserver`
  reads env vars, the producer and validation scripts read JSON artifacts. No
  script links the package APIs the rewrite changed, so nothing in `scripts/`
  breaks mechanically.
- Observation, eras: every measurement doc 20 recorded predates the rewrite.
  Its screens and re-reads were committed between 11:57 and 13:04 on
  2026-07-30 (`6950d51`..`6024c08`); `50c5240` landed at 16:02 and the plan
  commits at 16:58-18:45. So the frozen `synchronized-frames` rule, the
  fence-regime table in `20/F16`, and doc 19's stall numbers all characterize
  the **pre-rewrite** app.
- Inference: the rewrite's frame-path impact is plausibly nil (`H2`), its
  instrument impact is real (`F2` -- introduced by the precursor commit, not
  the plan), and its teardown impact is unexercised (`F3`). The three questions
  in Purpose are exactly these three observations.
- Uncertainty: "off the frame path" is a structural claim; `H1`'s experiment
  and the Phase 1 drain sanity block are what turn it into a measured one.
- Next action: Phase 1 measurements.

### F2 -- the fence-stall bracket lost its first fence at `50c5240`

- Status: complete, from source; magnitude unmeasured.
- Date: 2026-07-30, read at `a1c00b9`.
- Reproduction: compare `git show 50c5240 --`
  `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift`
  against the current `consumeHostUpdate`.
- Observation: before `50c5240`, the consume path made **one** `queue.sync`
  per delivery -- `fencedFrameState()` -- and the benchmark bracket timed it;
  lifecycle result/transitions arrived with the stream element. After
  `50c5240`, the update callback carries no payload, so the consume path first
  calls `fencedConsumptionMetadata()` -- a second `queue.sync` on the same
  serial queue -- and only then the timed `fencedFrameState()`. The metadata
  sync is untimed.
- Inference: the untimed first sync is the one that queues behind whatever
  read turn is running when main wakes; by the time the timed sync runs, the
  queue was just drained, so it waits at most behind turns enqueued in the
  gap. If that reading is right, `pendingFenceStallNanoseconds` (and the
  `cumulativeFenceStallNanoseconds` / `maxFenceStallNanoseconds` fields every
  block reports) now systematically understate the per-delivery fence wait --
  and the direction of the error is always *down*, the reassuring direction.
  This is the third instance of the instrument-coverage failure shape
  `agent-docs/terminal-performance.md` catalogs, and the second time this
  specific counter is involved (it first shipped latched at drain time).
- Consequence for comparability: fence-stall numbers recorded before and after
  `50c5240` are different quantities. `20/F16`'s regime table (9 stalls of
  ~16 ms at 1x; 1-2 of 126-266 ms at 2x+) was measured pre-boundary with the
  honest single-fence bracket and stands *for that era*; nothing measured
  today can be laid beside it until `D1` resolves the bracket.
- Competing interpretation: `H1`'s -- coalescing means the metadata sync
  usually finds an idle queue and the miss is negligible. Cheap to
  distinguish; do not argue it from source.
- Uncertainty: entirely unmeasured. The finding is the bracket's shape, not
  its size.
- Next action: `H1`'s experiment, then `D1`.

### F3 -- the harness never runs the shutdown transaction the PTY was rewritten under

- Status: complete, from source and verified against an isolated optimized
  DanTerm app in `F6`.
- Date: 2026-07-30, read at `a1c00b9`.
- Observation, harness side: `scripts/terminal-benchmark.sh#terminate_owned_pid`
  tears the app down with SIGTERM, polls for exit at 40 x 0.05 s (a 2-second
  grace), then SIGKILLs. Teardown runs after the block's results are already
  on disk (the deadline loop waits for the result artifacts first).
- Observation, app side: nothing in `app/` installs a SIGTERM handler, and
  AppKit's default disposition for SIGTERM is immediate process termination --
  `applicationShouldTerminate` / `applicationWillTerminate` run on a Quit
  Apple event or Cmd-Q, not on a signal. So under every benchmark run the
  truthful-quiescence transaction (`terminateForApplicationExit`'s untimed
  `DispatchGroup` wait, host retention until quiescence, source joins) **never
  executes**. The child shell is cleaned up by the kernel side of process
  death: the master closes, the session gets SIGHUP.
- Inferences, three of them:
  1. **Pair wall-clock accounting is not perturbed by the rewrite's exit
     work.** `20/F12`'s "~98% of a pair is build/launch/window/teardown" was
     measured pre-rewrite, but the teardown it prices is a kill, and a kill it
     remains.
  2. **No benchmark or harness path can regress-test the rewrite's exit
     behavior.** The plan's proof obligations end at package tests and manual
     Cmd-Q; the app-level exit path has no automated instrument at all. That
     is the coverage gap `D3` weighs.
  3. **If the harness ever adopts a graceful quit, the 2-second grace meets a
     deliberately unbounded transaction**, and a SIGKILL mid-transaction
     becomes possible under exactly the machine-load conditions `19/F4`
     describes (the process census scales with the machine, not the
     terminal). Choosing kill-vs-quit should be a decision inside `D3`, not a
     default inherited from before the rewrite.
- Verification: `F6` installed a temporary benchmark-only marker at the start
  of `applicationWillTerminate`, then let the ordinary harness terminate its
  owned app. The marker remained absent.
- Next action: `D3`.

### F4 -- both consume fences are material; their split changes by workload

- Status: complete, measured with a temporary benchmark-build-only split
  timer; the probe was removed after measurement.
- Date: 2026-07-30, post-rewrite tree based at `a1c00b9`.
- Method: time `fencedConsumptionMetadata()` and `fencedFrameState()`
  separately at their existing call site, carry each through the same
  publish-time accumulation as the existing stall field, and run one valid
  optimized 179x66 block of each PTY workload. These are diagnostic blocks,
  not paired decisions; no performance verdict is claimed.
- `scrollback-stream`: `producerWriteNanoseconds` 142,056,708 ns,
  `finalDrawNanoseconds` 155,333,916 ns -- drain share 91.45%, inside
  `20/F2`'s 89.9-97.9% envelope. Across 38 published-frame charges, the
  metadata fence cost 33,856,757 ns and the frame fence cost 54,433,293 ns;
  maxima were 1,416,500 ns and 1,700,291 ns. The existing metric reports
  61.65% of the combined 88,290,050 ns and omits 38.35%.
- `synchronized-frames`: `producerWriteNanoseconds` 158,505,083 ns,
  `finalDrawNanoseconds` 172,412,875 ns -- drain share 91.93%. Across four
  published-frame charges, the metadata fence cost 67,300,301 ns and the
  frame fence cost 50,292,539 ns; maxima were 28,594,168 ns and 21,503,376
  ns. The existing metric reports 42.77% of the combined 117,592,840 ns and
  omits 57.23%.
- Observation: `H1` got the coverage conclusion right and the queue model
  wrong. The first fence is not negligible, but neither does it reliably
  drain the queue for the second: the second was 1.61x the first under
  `scrollback-stream`, while the first was 1.34x the second under
  `synchronized-frames`. Coalescing changes the split, not the need to count
  both.
- Consequence: today's reassuringly small `cumulativeFenceStallNanoseconds`
  is not a stable fraction of the wait it names. Era-labeling cannot make it
  truthful, and timing only the first fence instead would merely move the
  blind spot.
- Artifacts:
  `.build/terminal-benchmark-runs/2026-07-30-192127-79732/artifacts`
  (`scrollback-stream`) and
  `.build/terminal-benchmark-runs/2026-07-30-192231-82116/artifacts`
  (`synchronized-frames`).
- Next action: `D1`.

### F5 -- the consume path is one atomic, fully timed fence again

- Status: complete, implemented and verified.
- Date: 2026-07-30, post-rewrite tree based at `a1c00b9`.
- Change: `TerminalPTYHost.fencedConsumptionState()` now returns the drained
  `TerminalPTYFrameState`, lifecycle result, and optional captured transitions
  from one `queue.sync`. `TerminalPaneSessionController.consumeHostUpdate`
  calls that boundary once and, in benchmark builds, times the whole call.
  The separate untimed `fencedConsumptionMetadata()` boundary is gone.
- Behavioral proof: a test written first failed because the combined boundary
  did not exist, then passed with the implementation. It starts a real child
  that prints its final frame and exits, and asserts one consumption read
  carries non-empty damage, the final terminal text, exit result, and captured
  feed transition together.
- Verification: the complete `lib/TerminalPTY` suite passed (132 tests in 10
  suites), followed by the full `just test` local gate: all package suites,
  the two-lane TerminalPTY runner, purity/boundary/concurrency lints, benchmark
  and build contracts, and shell integration tests. An optimized post-change
  `scrollback-stream` block was valid and reported the restored whole-fence
  field (`cumulativeFenceStallNanoseconds` 80,641,205 ns across 78
  published-frame charges, max 1,572,667 ns). This single block validates the
  instrument path; it is not a performance comparison or verdict.
- Artifact:
  `.build/terminal-benchmark-runs/2026-07-30-192836-94863/artifacts`.
- Consequence: post-`F5` fence numbers again name the whole per-delivery
  consume fence. They remain a third delivery era and are not numerically
  comparable with either pre-`50c5240` measurements or the two-fence era
  without an explicit paired experiment.
- Next action: `D2`; its fresh screens can now characterize the settled
  post-fix delivery path.

### F6 -- SIGTERM bypasses AppKit termination; registry stress quiesces in 361 ms

- Status: complete, measured with two temporary probes; both were removed.
- Date: 2026-07-30, post-`F5` worktree based at `a1c00b9`.
- SIGTERM method: a benchmark-only write at the first line of
  `AppDelegate.applicationWillTerminate` targeted a unique path in
  `/private/tmp`. One valid optimized `scrollback-stream` run then exited
  through the harness's unchanged `terminate_owned_pid`.
- SIGTERM result: the harness sent SIGTERM to its owned DanTerm process and
  the marker remained absent. `applicationWillTerminate`, recovery
  preparation, `terminateForApplicationExit`, and the registry's
  `requestShutdownAndWait` did not run. This verifies `F3` against DanTerm
  itself.
- Coverage audit: package tests already split the desired proof in two.
  `applicationTerminationClosesMultipleLivePanes` applies a 3-second ceiling
  to concurrent close of stalled-input, chatty-output, and ordinary hosts, but
  drives `host.close()` through a Swift task group.
  `applicationTerminationDrainsRegistryWithoutMainProgress` drives the real
  process-lifetime `TerminalPaneTerminationRegistry.requestShutdownAndWait`
  path and proves quiescence while main is blocked, but uses quiet children
  and carries no latency ceiling.
- Registry probe: temporarily change the live child in the registry test to
  the continuously writing `chatty` probe and time only
  `requestShutdownAndWait`. The transaction completed in 361,016,750 ns;
  both quiescence observers fired and both hosts released. One run is enough
  to size a generous behavioral ceiling, not to claim a latency distribution.
- Inference: the missing coverage is the intersection of two tests that
  already exist -- saturated owner work, through the registry path, with the
  same generous 3-second ceiling. It does not require a new benchmark
  workload, result field, calibration rule, or graceful app teardown.
- Next action: `D3`.

### F7 -- registry shutdown is permanently covered under chatty output

- Status: complete, implemented and verified.
- Date: 2026-07-30, post-`F5` worktree based at `a1c00b9`.
- Change:
  `applicationTerminationDrainsRegistryWithoutMainProgress` now runs its live
  pane with the continuously writing `chatty` probe, times only
  `TerminalPaneTerminationRegistry.requestShutdownAndWait`, and asserts the
  same 3-second ceiling as the existing direct-host stress test.
- Behavioral scope: the test still proves both quiescence observers run, the
  registry releases both handles, and both native hosts are released while
  main is synchronously occupied by the registry transaction. The changed
  stimulus adds continuous owner-queue work to that production registry path.
- Verification: the focused Swift Testing run passed in 0.651 seconds end to
  end. The assertion deliberately exposes no measured latency as a benchmark
  result: 3 seconds is a coarse regression ceiling with generous machine-load
  headroom, not a calibrated performance rule.
- Consequence: the harness keeps SIGTERM cleanup after result capture. Graceful
  quit and a standalone exit-latency instrument remain rejected unless a live
  shutdown symptom creates a question and a decision rule for either one.
- Next action: `D2`.

### F8 -- two fresh screens refuse every confirm cell

- Status: complete, measured; the 100,000-trial stage was not admissible.
- Date: 2026-07-30, post-`F5` tree
  `63d72cd1ce26e87de32bc295c30e658160ca4cb9`, materialized from unreferenced
  snapshot commit `dbc304d6ff42e3b91201f7e99474d2d0512c7b90`.
- Method: two independent 1x `synchronized-frames` A/A screens, each with both
  physical arms bound to that immutable tree, 24 balanced quartets (48 pairs),
  50,000 trials per condition, and fresh seeds `20262301` and `20262302`.
  Both ran on AC with the machine otherwise idle. Every quartet was valid;
  neither screen discarded or retried one.
- Screen results:

  | screen | elapsed | median | SD | trimmed SD | range | quick | confirm |
  | --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
  | 1 | 528.070 s | -0.53% | 3.36% | 2.48% | -14.53 .. +5.16% | 24p @2.75% | none |
  | 2 | 460.578 s | -0.61% | 4.31% | 3.62% | -8.58 .. +11.00% | 24p @2.55% | none |

- Independent-and-pooled selection: `select_candidate` found no confirm cell
  on screen 1, screen 2, or their 48-quartet pool. Pooled quick selected
  24p@2.50%; the cheapest quick cell that clears every gate on both screens
  independently and pooled is the conservative 24p@2.75% cell. That does not
  make a deciding workload: this workload's standing quick guidance is to
  treat quick as a screen and let confirm decide, and confirm has no rule.
- Frozen-cell audit, run through `select_candidate`'s owning calibration code:
  `quick 6p@2.65%` has A/A false-positive rates 0.1119 / 0.1657 / 0.1237 on
  screen 1 / screen 2 / pooled evidence, against the 0.01 gate; screen 2 also
  misses positive detection at 0.8971. `confirm 8p@2.15%` is further outside:
  false positives are 0.1275 / 0.1355 / 0.1239, detection spans
  0.7367-0.7779 against 0.90, inconclusive results span 0.2204-0.2631 against
  0.10, and wrong-direction results are nonzero.
- Confirmation-stage result: **not run by construction.** The protocol says a
  screen selects one exact cell and only that cell receives 100,000 trials
  with disjoint fresh seeds. Both screens and pooled evidence returned
  `confirm: null`; changing the pair-count grid, threshold grid, estimator, or
  stimulus after seeing that result would be a new screen, not confirmation.
- Comparison with the pre-rewrite era: the archived 1x screens had trimmed SD
  1.30-1.72% and selected confirm cells; these read 2.48% and 3.62% and select
  none. This refutes `H2` for `synchronized-frames` on the settled post-fix
  tree. It does not reopen the other five workloads: `F4` kept the PTY drain
  composition inside its inherited envelope, and no new evidence measured
  their distributions.
- Artifacts:
  `.build/terminal-benchmark-doc23-d2-screen-1/63d72cd1ce26-0000`
  and
  `.build/terminal-benchmark-doc23-d2-screen-2/63d72cd1ce26-0000`.
- Resulting action: `D4` demotes the refused workload; implemented in `F9`.

## Decision log

### D1 -- restore a truthful fence bracket

- Status: **decided and implemented.**
- Evidence used: `F2` (shape), `F4` (magnitude and competing-mechanism
  result), user direction selecting candidate 1, and `F5` (implementation and
  verification).
- Candidate solutions:
  1. **Single-fence consume.** Return the lifecycle metadata from the
     frame-state drain in one `queue.sync`, restoring the pre-`50c5240` shape
     the bracket was written for. Fixes the instrument by construction and
     halves per-delivery fences. Production change: the metadata and frame
     state become one atomic snapshot -- strictly tighter ordering than
     today's two snapshots, but a change to the delivery path all six
     workloads run through.
  2. **Time both syncs.** Wrap `fencedConsumptionMetadata()` in the same
     benchmark-build-only timing and add it to the pending stall. No
     production-path change; leaves two fences paying two queue waits per
     delivery forever.
  3. **Leave it, era-label the metric.** Free, and permanently dishonest in
     the silent direction; acceptable only if `H1`'s measurement shows the
     miss is genuinely negligible.
- Tradeoffs: (1) changes production ordering, so it needs lifecycle and damage
  correctness tests rather than resting on a timer; its tighter atomic
  snapshot is also the simplest state contract and removes one synchronous
  queue crossing per delivery. (2) repairs the reported sum with the least
  production-code change, but preserves two separately ordered snapshots and
  two fences forever. (3) is rejected by `F4`: the omitted share is 38.35% in
  one workload and 57.23% in the other, so it is neither negligible nor
  stable.
- Recommendation: **(1), single-fence consume.** Have one owner-queue sync
  return the drained frame state plus lifecycle result/transitions, time that
  whole sync under the benchmark flag, and cover the tighter snapshot with
  tests that force exit metadata and frame damage to arrive together. This
  restores the metric's pre-`50c5240` meaning by construction instead of
  teaching the observer to add two partial brackets.
- Decision: **taken and kept.** The implementation matches the recommendation
  and its behavioral proof passed. No performance verdict is attached; `D1`
  repairs what the metric means.

### D2 -- venue for `synchronized-frames`' missing confirmation stage

- Status: **decided and completed with a negative screen.**
- Evidence used: `20/F15` (the frozen confirm cell fails detection on screens
  3 and 4 individually; the confirmation stage was skipped), `F1` (every
  archived screen predates the rewrite), doc 7's two-stage protocol, user
  direction selecting candidate 2, and `F8` (two fresh screens plus the
  independent-and-pooled gate audit).
- Candidate solutions:
  1. **Run the 100,000-trial confirmation on the archived 1x series**
     (screens 2-4). Costs only compute -- the stage is resampling over
     already-measured pairs -- but the series characterize a delivery path
     that no longer exists, so it closes the procedural gap while leaving the
     evidentiary one open.
  2. **Collect fresh 1x A/A screens on the current tree, then confirm**
     (recommended). Two screens at ~8-10 s/pair, 48 pairs each -- roughly
     10-20 minutes of idle machine apiece per `20/F11`'s accounting -- then
     the 100,000-trial stage with disjoint fresh seeds on whatever cell the
     fresh screens select, verified per-series and pooled. The frozen cell
     either survives against today's app or is replaced by one that does.
  3. **Nothing.** Leaves a cell that fails detection on two of three screens
     deciding real verdicts, on the workload with no false-positive margin.
- Tradeoffs and correctness risks: (2) is the only option that also answers
  `H2` where it is thinnest -- it measures post-rewrite noise on the exact
  workload whose rule has no margin. Its risk is the known one: screen-to-
  screen variability is real (`20/F13`'s screen 4), so two fresh screens must
  be read with `20`'s per-series-and-pooled standard, not enveloped. (1) is
  not worthless -- if the frozen cell fails confirmation even on its own
  era's data, no fresh measurement is needed to unfreeze it -- but it cannot
  *validate* the cell for today's tree.
- Recommendation: **(2)**, with (1) as a free first step only if its failure
  would already settle the question. Sequencing note: run after `D1` resolves,
  so the screens are collected with whatever bracket fix is chosen rather
  than needing a third era.
- Decision: **candidate 2 taken; its screen stage refused the workload.** Both
  fresh series and their pool select no confirm cell, so there is no exact
  screened cell eligible for the inherited 100,000-trial stage. The frozen
  `8p@2.15%` cell fails every accuracy gate by wide margins. `D2` is complete:
  "no confirmation may run" is the protocol's negative result, not an
  incomplete execution. `D4` demotes the workload in response.

### D3 -- exit-to-quiescence coverage

- Status: **decided and implemented.**
- Evidence used: `F3` (harness/app source), `F6` (SIGTERM verification,
  existing-test split, and 361 ms saturated registry probe), `19/F4`
  (machine-shaped process census), user direction selecting candidate 1, and
  `F7` (permanent coverage and verification).
- Candidate solutions:
  1. **Strengthen the existing registry package test and keep harness
     SIGTERM** (recommended). Make its live child `chatty`, time
     `requestShutdownAndWait`, and assert the existing 3-second stress ceiling.
     This covers the production registry transaction under owner-queue
     saturation while preserving the harness's post-result, owned-process
     kill semantics.
  2. **Add a standalone exit-latency diagnostic command.** Report a bare
     request-to-quiescence duration with no verdict. More discoverable for
     future investigations, but duplicates test setup and has no present
     performance question that would tell an operator what to do with the
     number.
  3. **Make benchmark teardown graceful and report exit latency.** Sends a
     Quit event after every block and waits for `applicationWillTerminate`.
     This exercises the app hook, but couples every performance block to
     confirmation/recovery UI and a deliberately unbounded, machine-shaped
     census after its result is already complete. A 2-second fallback can
     SIGKILL the exact transaction the metric claims to observe.
  4. **Nothing.** Leaves saturation and the real registry path tested
     separately. Behavior is well covered, but the intersection the rewrite
     made important remains unpinned.
- Tradeoffs: candidate 1 adds no product API and no calibrated statistic. Its
  3-second ceiling is a coarse behavioral regression guard, not a performance
  verdict; the one-run 361 ms probe leaves roughly 8x headroom for machine
  census variance. Candidate 2 creates a permanent instrument without a
  decision rule or live symptom. Candidate 3 changes benchmark lifecycle
  without improving any deciding metric and makes kill-vs-quit nondeterminism
  part of routine measurement.
- Recommendation: **(1).** Exit-to-quiescence earns a behavioral ceiling on
  the package-level production registry path, not a benchmark metric. Keep the
  benchmark harness's SIGTERM cleanup: it owns only its process, runs after
  result capture, and should not pretend to measure graceful quit.
- Decision: **taken and kept.** The existing registry test now covers the
  saturated intersection under the 3-second ceiling. No production API,
  benchmark result field, calibration rule, or harness lifecycle changed.

### D4 -- response to a refused deciding workload

- Status: **decided and implemented.**
- Evidence used: `F8` (two independent screens and pooled evidence select no
  confirm cell; both frozen cells fail), `20/F9` (the workload covers a real
  synchronized-output path no other workload does), and the benchmark
  contract that `WORKLOADS` means a calibrated set with a rule in both modes.
- Candidate solutions:
  1. **Demote `synchronized-frames` to `CANDIDATE_WORKLOADS`** (recommended).
     Remove its quick and confirm entries from `DECISION_RULES`, keep its
     fixture, collector, block contract, direct harness command, and candidate
     screen support. Routine paired comparison returns to the five workloads
     whose rules remain valid; the captured workload stays collectable and
     descriptive until a future screen can graduate it again.
  2. **Extend the calibration design and re-screen.** Add pair counts beyond
     24, change estimator or grids, or create a different stimulus. This is a
     new calibration investigation, not confirmation. At 8-10 seconds per
     pair, even the current 24-pair quick cell is already a 3-4 minute workload
     leg, and a threshold above the injected 3% confirm effect cannot meet the
     detection contract. No present mechanism predicts which redesign helps.
  3. **Retain the frozen rules.** Keeps coverage in routine comparisons but
     knowingly labels noise: fresh A/A false positives are 11-17% for quick
     and 12-14% for confirm against a 1% gate. This contradicts the reason the
     calibration system exists.
- Tradeoffs: candidate 1 loses an automatic verdict on a unique real-TUI path,
  but the fresh evidence says that verdict is not available. It preserves the
  instrument and its provenance without pretending collection implies
  decidability. Candidate 2 could recover a rule only by opening a new
  research axis after the predeclared screen failed; doc 20 already found that
  replay length is not a supported lever. Candidate 3 is not an evidentiary
  option.
- Recommendation: **(1).** Demote rather than delete. A captured workload with
  no honest rule is a candidate, exactly the state `CANDIDATE_WORKLOADS`
  represents. Reopen graduation on two independent screens selecting one
  confirm cell that clears every gate separately and pooled, followed by the
  missing 100,000-trial confirmation.
- Decision: **candidate 1 taken.** `synchronized-frames` is now the sole
  `CANDIDATE_WORKLOADS` entry and is absent from both routine decision-rule
  tables. Its fixture, block contract, collector, direct harness command, and
  candidate-screen path remain intact. A workload-set regression test pins the
  distinction, and the validation and comparison suites pass (`F9`).

## F9 -- the refused workload is demoted without deleting its instrument

- `synchronized-frames` is absent from `WORKLOADS`, routine quick selection,
  the confirm ladder, and both `DECISION_RULES` workload tables.
- It is present in `CANDIDATE_WORKLOADS` and `BLOCK_CONTRACTS`; its production
  collector still validates the captured fixture, the direct benchmark harness
  still admits the corpus workload, and the candidate-screen driver admits the
  union of calibrated and candidate workloads.
- TDD verification: the new candidate-only contract failed first because
  `CANDIDATE_WORKLOADS` was empty. After the policy change, the workload-set
  tests pass (4 tests), the validation tests pass (45 tests), and the comparison
  tests pass (54 tests).
- Result: routine comparison again contains only the five workloads with
  supported rules. The unique synchronized-output instrument remains available
  for descriptive collection and a future predeclared graduation attempt.

## Rejected

### Recalibrating all six workloads because the app changed

Considered because the rewrite is the largest change to the delivery path
since the rules were frozen. Rejected as a default posture: the corpus has
never rescreened per app change -- the paired interleaved-arm design keeps
verdicts honest because both arms carry the same tree, and frozen thresholds
characterize noise that drifts slowly. The five original workloads carry real
margin and a 100,000-trial confirmation stage already (doc 7);
`synchronized-frames` is the exception on both counts and `D2` handles it.
Reopen for the other five only on evidence: a Phase 1 drain composition
outside `20/F2`'s envelope, or fresh `D2` screens showing noise outside the
frozen envelopes on more than the one workload.

### Cross-project comparability

Remains rejected; see doc 20's Rejected section. Not relitigated here.

## Open questions and caveats

- **Doc 19 (LIVE) words its fence model around the removed consume task.** Its
  quantities are bracket-level and survive; its mechanism wording ("the
  consume task's per-delivery fence") is stale per this file's second added
  rule. Doc 19 owns occupancy; flagged here so its next update re-derives the
  wording from `TerminalPaneDeliveryBoundary`.
- **The 5x replay anomaly (`20/F16`) remains unowned.** `D2`'s fresh 1x
  screens were noisier, not quieter, and add no mechanism for the old 5x
  result. Do not chase it here.
- **The vtebench payload import stays unclaimed**, logged in doc 20's Open
  questions. Not imported here.
- **`20/H3` (drain as the deciding metric) stays parked in doc 20** with its
  reopening condition (`scrollback-stream` returning `inconclusive` often
  enough to obstruct work). Not imported here.
- **Storage is owned elsewhere.** `plans/wip/bounded-benchmark-storage.md`
  owns benchmark storage retention; any artifact this file's measurements
  produce lands in existing roots, and no new storage root is introduced
  without registering there if that plan lands.

## Outcome

Investigation closed. `F4` confirms the fence-stall
bracket has omitted a material and workload-dependent share since `50c5240`:
38.35% of combined fence wait in one `scrollback-stream` block and 57.23% in
one `synchronized-frames` block. It refutes the proposed mechanism -- the
second fence is not consistently cheap -- while leaving the integrity finding
stronger. `F5` restores one atomic, fully timed consume fence and verifies it
through the real PTY suite and benchmark harness. The drain bracket remains
inside its inherited envelope (91.45%), so `H2` does not reopen for the other
five workloads. From source: every number doc 20 recorded characterizes the
pre-rewrite delivery path (`F1`), and no benchmark path exercises the
  rewritten shutdown because the harness kills the app before AppKit's
  termination hooks can run (`F3`, verified in `F6`). `F7` closes the missing
  exit-coverage intersection on the package-level production registry path:
  chatty output now runs under the existing 3-second behavioral ceiling, and
  benchmark cleanup remains SIGTERM. `F8` then refutes `H2` where this file
  predeclared it was thinnest: two fresh 48-pair `synchronized-frames` screens
  independently select no confirm cell, pooled evidence selects none, and the
  frozen `8p@2.15%` cell now produces 12-14% A/A false positives and only
  74-78% detection. The 100,000-trial stage correctly did not run because no
  exact cell survived screening. `D4` therefore demotes the workload back to a
  collectable candidate while preserving its fixture and instrument (`F9`).
  Routine quick and confirm comparisons again issue verdicts only for the five
  workloads whose frozen rules remain supported.
