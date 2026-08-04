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
  draw metric missed the Core Animation regression. The benchmark already
  records whole-process CPU and topology, but neither is currently a primary,
  decision-bearing workload contract.

## Owner decisions required

### OD1 -- sleep scope

Choose whether the lifecycle scheduling contract covers system sleep/wake only,
or both system and screen sleep/wake. The same headless policy can serve either
scope, but the AppKit notification inputs and required real-system evidence
differ. This decision must also make doc 13's currently ambiguous "sleep/wake"
wording explicit.

### OD2 -- responsiveness scope

Choose the representative real AppKit input contract during sustained visible
output:

- keyboard input only; or
- keyboard plus pointer navigation.

The minimum behavioral gate is ordering/liveness, not a guessed latency budget:
the input effect must be observed while output is still in progress, followed
by final-state convergence. A quantitative interactive-latency claim would
require a separate calibrated metric and is not implied by this plan.

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

### D3 -- promote sparse topology to a whole-process CPU benchmark

Add a permanent `sparse-many-runs` workload using the proven stride-four shape
at 179x66. Whole-process CPU per accepted draw is its primary decision metric,
not an auxiliary quantity. Every valid block proves that the intended
independent variable reached drawing: exactly 50 damaged rows in 17 maximal
spans, no full-damage path, no dirty-rectangle fallback, and complete CPU and
topology sample coverage for the accepted draws.

The workload begins as collectable but undecidable. An A/A candidate screen may
select a pair count and threshold because CPU is primary for this workload; a
fresh held-out confirmation must then freeze the exact rule before it can join
quick or confirm verdicts. Existing draw workloads keep their current primary
metrics and their process-CPU quantities remain unclassified.

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
  unless the block proves its geometry, draw count, CPU coverage, and exact
  post-halo span topology.
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
- **PO4 -- runtime teardown.** Arm every production runtime-owned category of
  scheduled work, shut down twice, and prove through an explicit trace that the
  owner census is empty, captured callbacks are inert, and scheduling cannot
  restart. Existing PTY source-registry tests remain the proof for native
  resources.
- **PO5 -- sparse benchmark instrument.** Behavioral tests prove the producer's
  stride-four topology, rejection of missing or wrong topology/CPU coverage,
  primary pairing on whole-process CPU, and the absence of a verdict before a
  rule is frozen.
- **PO6 -- sparse benchmark calibration.** A/A evidence selects a candidate
  pair-count/threshold cell, and fresh disjoint evidence confirms its false-
  positive and detection requirements before the rule and workload membership
  are frozen. The final gate can reproduce a known per-row-clip regression and
  classify the shipped coalesced implementation as equivalent or better than
  its parent.
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
