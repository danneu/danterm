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
- the benchmark suite can report whole-process CPU for the sparse clip topology
  that caused the `d378096` regression, but calibration must decide whether that
  quantity is stable enough to carry a verdict.

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

### D3 -- retain the existing sparse topology as a non-deciding diagnostic

No new workload. `sparse-spans-max` is already implemented -- stimulus
(`scripts/terminal-benchmark-producer.py#SPARSE_SPAN_WORKLOADS`), per-draw
engine-damage topology recording, block contract
(`scripts/terminal-benchmark-validation.py#BLOCK_CONTRACTS`), and collection as
an undecidable candidate. It remains a candidate because controlled A/A
calibration could not support a trustworthy frozen CPU rule.

Its contract is preserved exactly as implemented, because changing the stimulus
would protect different geometry than the reproduced regression:

- The stride-four shape at 179x66 damages **17 engine rows in 17 maximal
  spans**, which the shared glyph halo expands to 50 drawing rows still in 17
  spans. The block contract is stated in engine rows, and validation judges the
  recorded engine damage rather than the bounding dirty rectangle, which cannot
  distinguish two spans from seventeen.
- A valid block is 50 accepted serialized draws, each carrying that exact
  topology, with complete CPU and topology sample coverage.

Whole-process CPU per accepted draw (`process-cpu-nanoseconds-per-draw`) remains
its primary reported metric, but it carries no verdict. Three valid 24-pair A/A
screens exposed session-dependent spread: two selected no cell at all, including
a controlled low-load run with 4.71% SD and a -15.05%..+7.23% range, while the
other proposed cells that failed independently against the first series. The
selection protocol therefore refused a rule before held-out confirmation or a
known-bad sensitivity arm could legitimately run. Existing draw workloads keep
their current primary metrics and their process-CPU quantities remain
unclassified.

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
- **I8 -- measured topology.** A sparse-topology diagnostic is valid only when
  the block proves its draw count, CPU coverage, and the exact recorded engine-
  damage row and span counts its workload contract names. Valid topology makes
  the descriptive quantity interpretable; it does not grant verdict authority
  to an uncalibrated metric.
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
  `sparse-spans-max` stimulus, engine-damage recording, and block validation keep
  passing unchanged. No frozen-rule or synthesized-arm code is added after
  calibration refused verdict authority.
- **PO6 -- sparse benchmark calibration refusal.** Preserve the independently
  collected A/A results and the exact selection outcome: no one series may be
  discarded or pooled to manufacture a passing cell. `sparse-spans-max` remains
  outside quick and confirm membership, and milestone evidence makes no claim of
  automated coverage for the historical per-row renderer regression. The
  existing controlled profiles remain its quantitative evidence; recurrence is
  an accepted risk investigated by profiling, not by a knowingly noisy gate.
- **PO7 -- responsiveness.** A real AppKit input route selected by OD2 takes
  effect while a sustained-output producer is still active, after which the
  final terminal state arrives and all pending work remains bounded. Any test
  timeout is a hang guard, not a latency claim.
- **PO8 -- full gate.** `just test` and `just test-ui` pass, the selected real
  lifecycle observation passes, and the milestone record names the evidence for
  the scheduling and responsiveness gates plus the refused CPU calibration.

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

- The sparse workload's 17-span endpoint remains a descriptive diagnostic at
  179x66, not an automated CPU gate. A recurrence of the historical renderer
  regression requires controlled profiling; the test suite protects topology
  correctness but cannot prove Core Animation processes it cheaply.
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
- **Replace the refused rule with another benchmark in this milestone.** Rejected
  because M9's maintained contract is scheduling and responsiveness, while the
  historical renderer decision already has controlled profiling evidence. A new
  performance instrument needs its own measured motivation and calibration, not
  automatic admission because this candidate was noisy.

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
- [x] 5. Make the owner census stateless so hot-path guards cannot regress
- [x] 6. Record the refused sparse-topology CPU calibration
- [ ] 7. Prove keyboard responsiveness and close the milestone evidence

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
- Shutdown state is readable only through the lifecycle's O(1) active flag. The
  owner census is a separate capture method that walks every registered owner
  and carries no state field, so a guard on census state cannot be written --
  the census is reserved for termination assertions and diagnostics.
- Three valid `sparse-spans-max` A/A screens produced incompatible calibration
  outcomes. The controlled low-load screen still selected no cell, so the
  workload remains descriptive and M9 claims no automated protection against
  the historical Core Animation regression.
