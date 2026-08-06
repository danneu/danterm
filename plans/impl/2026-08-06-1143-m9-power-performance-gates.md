# M9 power and performance gates

## Problem

Milestone 9 requires the power-and-performance contract in
`plan-terminal-engine/13-power-performance.md` to pass idle, hidden-pane,
visible-output, recovery-freshness, sleep/wake, responsiveness, and teardown
gates. The current test suite already proves most of the scheduling contract:

- unchanged visible terminals publish no recurring frames;
- hidden panes keep terminal, semantic, inspection, and recovery state current
  without rendering, then reveal one complete current frame;
- stalled consumers conflate output into bounded pending work and retain the
  final state; and
- recovery traces retain bounded freshness, retry failures, and become
  quiescent after a covering write.

The remaining gaps are narrower:

- sleep/wake has one successful real-system observation but no maintained
  scheduling policy or AppKit adapter proof;
- pane and PTY teardown are strongly covered, but application-runtime timers,
  debouncers, monitors, and deferred callbacks have no exhaustive post-shutdown
  proof;
- sustained-output tests prove convergence, not responsiveness through a real
  AppKit input route; and
- the benchmark suite can report whole-process CPU but cannot issue a verdict
  for the sparse clip topology that caused the `d378096` regression.

The sparse-clip trigger, attribution, revised implementation, and acceptance
measurements are preserved in
`docs/research/29-sparse-appkit-damage-clip-topology/README.md` (29/F3-F7,
29/D1-D3).

## Evidence

- `TerminalPaneSessionControllerTests#visibleCreationRetainsInitialFrame` and
  `#resultOnlyEqualSnapshotSkipsPlanning` prove unchanged and equal terminal
  states do not publish new frames.
- `TerminalPaneSessionControllerTests#hiddenCreationDefersInitialFrame`,
  `#hiddenOutputAndReveal`, and `#childExitReleasesSynchronizedGating` prove
  hidden state continuity and one complete reveal frame.
- `TerminalPaneSessionControllerTests#burstConflatesToFinalPlan` and
  `TerminalPaneSession#TerminalPaneDeliveryBoundary.scheduleFrame` prove final-
  state convergence through one bounded pending delivery.
- `RecoveryCheckpointPolicyTests` proves freshness, retry, covering success,
  idle quiescence, and termination through deterministic traces;
  `TerminalPaneSessionControllerTests#recoveryMutationClassification` and
  `#applicationExitFenceDrainsAcceptedOutput` prove the session boundary.
- `TerminalPaneSessionControllerTests#applicationExitFenceSuppressesQueuedDeliveries`,
  `#applicationTerminationDrainsRegistryWithoutMainProgress`, and
  `#ordinaryTeardownAndAppExitReleaseRegistryOwnership` close pane and PTY
  teardown, but do not enumerate application-runtime scheduling owners.
- `docs/evidence/2026-07-20-milestone-4-viability.md#Manual visual and sleep/wake observation`
  records one successful real system-sleep cycle. No production
  `NSWorkspace` sleep/wake adapter currently exists.
- `TerminalPaneSessionControllerTests#navigationOutputStressConverges` proves
  sustained-output convergence and release, but no AppKit input ordering or
  latency claim.
- Research 29/F7 proves why the existing partial-draw workload and synchronous
  draw metric missed the Core Animation regression. The `sparse-spans-max`
  workload already exists and already names whole-process CPU as its primary
  metric, but it is collected as an undecidable candidate: no frozen rule lets
  it issue a verdict.

## Owner decisions required

### OD1 -- sleep scope -- DECIDED 2026-08-06: system sleep only

The lifecycle scheduling contract covers system sleep/wake only:
`NSWorkspaceWillSleepNotification` and `NSWorkspaceDidWakeNotification`. Screen
sleep is excluded, and doc 13's ambiguous "sleep/wake" is reworded to say system
sleep, carrying the reason below so the exclusion reads as deliberate rather
than as an oversight a later reader should "fix".

Screen sleep is excluded because occlusion already covers it. A standalone
AppKit probe run on 2026-08-06 observed, in order: `screensDidSleep` at 3.91s,
`didChangeOcclusionState -> OCCLUDED` at 3.96s, and an independent 1 Hz poll
confirming `OCCLUDED` at 4.12s -- so the display sleeping really does clear
`NSWindow.OcclusionState.visible`, and not merely as a notification-only
artifact. DanTerm already closes that loop in production:
`AppDelegate#windowDidChangeOcclusionState` calls
`AppRuntime#syncPaneVisibility`, which reads
`occlusionState.contains(.visible)` and pushes `TerminalSession#setVisible`,
which is the same input that gates `TerminalPaneSession#planIfNeeded`. That
route is currently untested end to end, which is what PO3b closes: an exclusion
resting on it requires it to be load-bearing under test.

Adding a screens adapter would therefore introduce a second input controlling
the suppression occlusion already controls, with a real risk the two disagree.
Occlusion is also strictly broader: it covers the lock screen, another app going
fullscreen, and a fully covered window, none of which post `screensDidSleep`.

Probe caveat, recorded so nobody re-derives it: the observed 2.3s gap between
`screensDidWake` and occlusion returning to `VISIBLE` is confounded by a manual
unlock during the run and is not a measurement of intrinsic wake latency. It
does not bear on this decision -- a frame deferred until the pane is genuinely
visible is what I3 requires.

### OD2 -- responsiveness scope -- DECIDED 2026-08-06: keyboard only

The gate covers keyboard input only. A keystroke must reach the child while a
sustained-output producer is still running, after which the pane converges to
the final output state with pending work bounded.

The gate remains ordering/liveness, not a guessed latency budget. Any test
timeout is a hang guard, never a latency claim. A quantitative interactive-
latency claim would require a separate calibrated metric and is not implied by
this plan.

Pointer navigation was considered and excluded. `tests-ui` already has
`makeScrollWheelEvent` and `makeMouseEvent`, so the exclusion is about gate
scope rather than harness cost; see Accepted risks for what it leaves ungated.

## Decision

### D1 -- keep scheduling semantics upstream of AppKit

Add an explicit terminal-session availability input beside visibility. Sleep
suspends frame planning while preserving PTY consumption, terminal mutation,
semantic delivery, recovery mutation tracking, and bounded accumulated damage.
Visibility and lifecycle availability remain separate inputs so an occluded
wake stays deferred without corrupting model-derived pane visibility.

Wake requests one complete current frame when the pane is visible, including
when no terminal bytes changed during sleep. When the pane is not visible, that
request remains bounded and is satisfied once on reveal. Repeated lifecycle
signals are idempotent.

The AppKit layer observes the notification pairs selected by OD1 through
`NSWorkspace.shared.notificationCenter` and forwards state transitions; system
callbacks provide inputs but do not decide terminal semantics. Observer
ownership follows the app-lifetime teardown contract.

Application deactivation alone does not suspend visible rendering: a visible
window may still need to present output while another application is active.
Activation continues to control terminal focus semantics, while occlusion and
the lifecycle state selected by OD1 control render availability.

### D2 -- make runtime shutdown an explicit terminal state

Application-runtime shutdown is idempotent, cancels every runtime-owned timer,
debouncer, monitor, subscription, and deferred callback, and prevents every
scheduling entry point from rearming afterward. The existing PTY-host source
registry remains authoritative for native descriptor/process teardown; this
plan does not duplicate it.

Shutdown exposes a deterministic scheduling trace or state snapshot sufficient
to prove that no owner-bound work remains and that callbacks captured before
shutdown become inert. Benchmark-only instrumentation is outside the production
teardown census unless it shares a production owner.

### D3 -- promote the existing sparse topology to a decision-bearing CPU gate

No new workload. `sparse-spans-max` is already implemented -- stimulus
(`scripts/terminal-benchmark-producer.py#SPARSE_SPAN_WORKLOADS`), per-draw
engine-damage topology recording, block contract
(`scripts/terminal-benchmark-validation.py#BLOCK_CONTRACTS`), and collection as
an undecidable candidate. This plan promotes that candidate to a gate and adds
nothing beside it; specifying a duplicate is a rewrite of work already merged.

Its contract is preserved exactly as implemented, because changing the stimulus
would protect different geometry than the reproduced regression:

- The stride-four shape at 179x66 damages **17 engine rows in 17 maximal
  spans**, which the shared glyph halo expands to 50 drawing rows still in 17
  spans. The block contract is stated in engine rows, and validation judges the
  recorded engine damage rather than the bounding dirty rectangle, which cannot
  distinguish two spans from seventeen.
- A valid block is 50 accepted serialized draws, each carrying that exact
  topology, with complete CPU and topology sample coverage.
- Renderer-behavior validity is **arm-specific**, not universal. An arm
  presented as the exact sparse implementation accepts neither full engine
  damage nor renderer dirty-rectangle fallback during a measured draw --
  otherwise the gate could bless a shipped implementation that never exercised
  the sparse renderer path it claims to protect. A synthesized known-bad arm's
  renderer deviation is valid and recorded in its provenance, because rejecting
  its draws would turn the regression being measured into an unmeasured block.
  Each synthesized arm records its source tree, defect-only renderer diff, and
  declared downstream behavior alongside the frozen-rule evidence.

Whole-process CPU per accepted draw (`process-cpu-nanoseconds-per-draw`) is
already its primary metric. What is missing is the frozen rule: an A/A candidate
screen selects a pair count and threshold, and a fresh held-out confirmation
freezes the exact rule before the workload can join quick or confirm verdicts.
Existing draw workloads keep their current primary metrics and their process-CPU
quantities remain unclassified.

### D4 -- close existing gates by evidence, not duplicate implementation

Idle, hidden/reveal, bounded-output, recovery-freshness, and PTY teardown close
by citing their existing deterministic behavioral proofs. New work is admitted
only where this plan names a missing observable contract. Criterion completion
updates doc 13 and the milestone roadmap with the selected OD1/OD2 scope and
the evidence that closes each gate.

## Invariants

- **I1 -- idle quiescence.** Unchanged terminal state schedules no recurring
  engine, render, or recovery work.
- **I2 -- state continuity.** Visibility loss and lifecycle suspension never
  stop PTY consumption, terminal-state updates, semantic events, or recovery
  mutation tracking.
- **I3 -- presentation resumption.** A visible wake produces exactly one
  complete current frame; an invisible wake defers that same bounded request
  until reveal.
- **I4 -- bounded output work.** Output bursts retain one conflated delivery and
  bounded damage rather than an event-by-event frame queue.
- **I5 -- recovery freshness.** Mutations remain dirty until a covering write
  succeeds, then recovery scheduling becomes quiescent.
- **I6 -- terminal shutdown.** After application-runtime shutdown, no
  owner-bound scheduled work remains, no captured callback has an effect, and
  no scheduling entry point can rearm.
- **I7 -- ordinary sleep.** DanTerm creates no macOS power assertion and never
  keeps the display awake for terminal activity.
- **I8 -- measured topology.** A sparse-topology CPU verdict is impossible
  unless the block proves its draw count, CPU coverage, and the exact recorded
  engine-damage row and span counts its workload contract names. That engine
  topology binds every arm without exception -- full engine damage is always
  invalid, because an arm that damaged a different row set measured a different
  independent variable. Only *renderer-side* behavior admits an exception: an
  arm presented as the exact sparse implementation additionally rejects
  dirty-rectangle fallback in a measured draw, while a declared synthesized
  known-bad arm may fall back there once its engine topology is proven, with the
  deviation recorded in its provenance.
- **I9 -- responsive visible output.** The AppKit input routes selected by OD2
  take effect before sustained output completes, and the pane subsequently
  converges to the final output state.

## Proof obligations

- **PO1 -- existing scheduling gates.** Preserve the deterministic idle,
  hidden/reveal, final-state conflation, and recovery-policy traces cited in the
  problem statement; no elapsed-time-only substitute closes these claims.
- **PO2 -- lifecycle scheduling.** A headless trace proves visible planning,
  suppression during every lifecycle state selected by OD1, current state and
  semantics while suspended, idempotent transitions, exactly one full current
  frame on visible wake, deferred wake while hidden, and inert transitions
  after teardown.
- **PO3 -- AppKit lifecycle adapter.** An integration proof shows that the
  selected `NSWorkspace` notifications reach the session scheduling seam through
  the workspace notification center and cannot reach it after owner teardown.
  Real sleep/wake evidence corroborates this adapter but does not replace the
  deterministic proof.
- **PO3b -- occlusion route.** An AppKit integration proof drives an occlusion
  transition through `AppDelegate#windowDidChangeOcclusionState` and shows it
  reaching the terminal-session visibility seam, and that restoring visibility
  produces the expected reveal. OD1 excludes a screen-sleep adapter *because*
  this route covers screen sleep, so that route must be load-bearing under test:
  today no test names either `windowDidChangeOcclusionState` or
  `AppRuntime#syncPaneVisibility`, and the cited hidden/reveal tests would all
  stay green if the forwarding were deleted.
- **PO4 -- runtime teardown.** Arm every production runtime-owned category of
  scheduled work, shut down twice, and prove through an explicit trace that the
  owner census is empty, captured callbacks are inert, and scheduling cannot
  restart. Existing PTY source-registry tests remain the proof for native
  resources.
- **PO5 -- sparse benchmark instrument.** The existing behavioral tests for the
  `sparse-spans-max` stimulus, engine-damage recording, and block validation
  keep passing unchanged; promotion adds no new stimulus or topology instrument
  to prove. New tests are admitted for exactly two things: the frozen rule
  itself -- that no verdict is issued before a rule exists and that the frozen
  rule is applied once it does -- and I8's arm-specific validity: a block whose
  measured draws report full engine damage is invalid for every arm, and a block
  reporting dirty-rectangle fallback is invalid unless the arm declares a
  synthesized known-bad provenance.
- **PO6 -- sparse benchmark calibration.** The exact candidate
  pair-count/threshold cell clears all four `select_candidate` gates -- false
  positive, detection, inconclusive, and wrong direction -- and clears them on
  each independently collected series on its own, not only pooled, on both the
  screening evidence and the fresh disjoint confirmation. Only then are the rule
  and workload membership frozen.

  Sensitivity is then judged, not assumed. The frozen rule classifies the
  shipped coalesced implementation as equivalent to itself, then applies
  unchanged to a synthesized shipped-tree arm restoring uncoalesced `d378096`
  per-row rectangle emission -- no threshold adjustment, no repeated sampling.
  Rejection grants the historical-per-row-regression coverage claim.
  Non-rejection is a permitted outcome, not a stuck gate: `sparse-spans-max`
  keeps its frozen rule and membership as a maximum-topology cost-bound guard,
  its documentation may not claim coverage of the historical per-row regression,
  and the criterion-2 record names which branch was taken. Under that branch the
  gate closes on the cost-bound claim while the documented deterministic
  btop-shaped candidate workload is evaluated, and that candidate is admitted
  only if its measured separation justifies its calibration and run-time cost.
  Arm validity follows D3: the shipped arm's draws are invalid if the renderer
  falls back to dirty rectangles, while the synthesized arm's declared deviation
  is valid and recorded with its provenance.
- **PO7 -- responsiveness.** A real AppKit input route selected by OD2 takes
  effect while a sustained-output producer is still active, after which the
  final terminal state arrives and all pending work remains bounded. Any test
  timeout is a hang guard, not a latency claim.
- **PO8 -- full gate.** `just test` and `just test-ui` pass, the selected real
  lifecycle observation passes, and the milestone record names the evidence for
  all seven criterion-2 gates.

## Non-goals

- Measuring battery life, Energy Impact, or claiming an energy reduction from
  CPU time alone.
- Suspending or throttling PTY parsing while hidden or asleep.
- Adding cursor blinking, a display link, a GPU renderer, or a macOS power
  assertion.
- Reopening the maximal-span clip decision or adding a clip-complexity fallback
  without a new separated whole-process CPU regression.
- Turning `sample` counts or the synchronous draw timer into a proxy for
  whole-process CPU.

## Accepted risks

- The sparse workload's 17-span endpoint is specific to 179x66 and the current
  one-row glyph halo. Its verdict protects the reproduced regression geometry,
  not every possible future grid height.
- A behavioral responsiveness gate establishes progress and ordering, not a
  numerical upper bound on input latency. A stronger claim requires separate
  measurement and calibration.
- **OD2's keyboard-only scope leaves the scroll route ungated.** Keyboard input
  is a PTY write handed to the pane owner; a scroll is
  `scrollWheel -> sendWheel -> Terminal.scroll(byRows:)`, which mutates the same
  terminal being flooded and calls `Terminal#recordPresentationFullDamage`, so
  it forces a full repaint while planning is already saturated. That is the
  heavier interaction and it is not covered. The bet is that main-thread
  starvation would surface on the keyboard route first, since both routes share
  the main thread. Reopen if a scroll-during-flood stall is ever observed in
  daily use -- the harness already has `makeScrollWheelEvent`, so the gate can
  be widened without new infrastructure.

## Rejected ideas

- **Treat AppKit notification handlers as the scheduling policy.** Rejected
  because identical lifecycle inputs must produce identical work requests
  independently of AppKit timing.
- **Add another PTY teardown registry.** Rejected because the existing native
  source registry already proves descriptor/process cancellation; the uncovered
  owner is the application runtime.
- **Freeze the first CPU rule that passes a candidate screen.** Rejected because
  rule selection and confirmation on the same random series overfit noise.

## Implementation discretion

- The representation of lifecycle availability and deterministic scheduling
  traces, provided visibility and lifecycle state remain distinct inputs.
- The runtime scheduled-work census and test scheduler shape, provided every
  production owner category participates and post-shutdown rearming is
  impossible.

## Commit progress

- [x] 1. Suspend terminal frame planning across system sleep and wake
- [x] 2. Forward workspace lifecycle and window occlusion through AppKit
- [x] 3. Make application-runtime shutdown terminal and observable
- [x] 4. Gate hot-path scheduling guards on a cheap active read
- [ ] 5. Freeze and apply the sparse-topology CPU benchmark gate
- [ ] 6. Prove keyboard responsiveness and close the milestone evidence

## Implementation notes

- Lifecycle wake uses the existing accounted frame-state fence before planning,
  so output already accepted by the PTY owner joins the single complete resume
  frame and its previously queued delivery becomes inert.
- The AppKit integration proof compiles the production lifecycle extensions
  against harness-substituted delegate, runtime, and session owners, exercising
  real notification and occlusion forwarding without opening live PTYs or IPC.
- Runtime scheduling uses one main-actor token census across six owner
  categories. Shutdown enters its terminal state before invoking cancellation,
  so queued one-shot and repeating callbacks fail closed through the same gate.
- Shutdown guards on paths that fire at output-delivery or reconcile frequency
  read the lifecycle's O(1) active flag, never the owner-census snapshot, whose
  construction walks every registered owner and is reserved for termination
  assertions and diagnostics.
