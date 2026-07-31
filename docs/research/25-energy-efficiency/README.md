# Battery and energy posture of the Swift terminal engine

Research started: 2026-07-31.

- [findings.md](findings.md) -- the append-only evidence chain: what the
  engine's energy behavior is today (code inspection) and what Apple's
  guidance requires (URL-cited survey).
- [decisions.md](decisions.md) -- the auditable decision log. Empty until the
  Phase 1 measurements land; D1 is expected at the Phase 2 gate.

## Purpose

This doc owns the energy/battery posture of the Swift terminal engine that is
replacing libghostty: what the engine already does to stay idle, where it
still burns discretionary work, which Apple best practices apply, and an
improvement backlog ordered by confidence. Every external claim in this doc
carries a URL so anyone can verify it without trusting this file; every code
claim carries a `file#identifier` and the inspection commit.

The boundary it must preserve: energy work may change *when* and *at what
priority* work runs, never *whether* terminal state stays correct. Notifications
from hidden panes (a stated app design goal), recovery snapshots, and reveal
correctness are not negotiable; only cadence, QoS, and delivery scheduling are
in scope.

## Investigation rules

- A claim about Apple platform behavior cites a URL (Apple documentation
  preferred). A claim about DanTerm cites `file#identifier` plus the commit
  inspected. No unsourced claims.
- Energy measurements follow the benchmark discipline in
  [agent-docs/terminal-performance.md](../../../agent-docs/terminal-performance.md):
  repeated runs, explicit environment, verdict thresholds. Energy numbers are
  noisier than latency numbers; single-run deltas decide nothing.
- Before building any mitigation, measure its ceiling with a throwaway hack
  that deletes the work outright. If the ceiling is inside noise, the
  mitigation is rejected without implementation.
- Expected win is frequency x unit cost. Both factors get measured -- how often
  the wasteful state occurs in real usage, and what it costs when it occurs --
  before any implementation task activates.
- Energy A/B comparisons use one paired contract: a fixed-byte workload run to
  completion (equal *work*, never equal sampling time -- a variant that slows
  or backpressures the child processes fewer bytes per interval and must not
  read as "more efficient"); elapsed time and throughput reported alongside
  energy; the app process and the spawned child tree both covered, aggregated
  at coalition scope (next bullet); A/B run order randomized; `powermetrics` invocations include `--show-process-energy`,
  `--show-process-amp`, `--show-process-ipc` (the man page: cluster stats
  require it together with `--show-process-amp`), and `--show-process-qos`;
  and the decision threshold is frozen from A/A variance runs (recorded in F7)
  before any A/B verdict is read.
- One statistic decides each A/B verdict, frozen before the runs: total
  Energy Impact accumulated over the complete run -- the sampled impact summed
  across every sample from workload start to completion (never a per-sample
  average, which rewards a variant that halves reported impact by doubling
  completion time) -- aggregated at the scope of the workload's process
  coalition via `--show-process-coalition`. Coalition scope is load-bearing,
  not a convenience: per-process rows lose processes that exit between samples
  to the unattributed `DEAD_TASKS` row (the man page: coalition mode bills
  exited processes to their coalition, "disambiguating DEAD_TASK time"), so a
  transient flood producer whose exit timing differs between variants would
  otherwise move its work in and out of the summed rows. Elapsed time,
  throughput, wakeups, AMP residency, and QoS distribution are supporting
  diagnostics: they explain a verdict and gate specific claims (e.g. T7's
  residency), but when they disagree with the decision statistic, the verdict
  follows the frozen statistic and the disagreement is recorded in findings.
- Latency-sensitive levers (QoS) are gated by the existing paired benchmark
  harness (fence-wait metrics, draw-latency verdicts), not by energy numbers
  alone.

## Trigger and current evidence

During the libghostty -> Swift engine migration the question arose whether the
CPU engine has any battery/energy behavior at all: does it do minimal work in
an unselected tab, does it prevent App Nap, and how would we verify any of it.
Code inspection (F1-F5, commit `1eff9b7`, dirty worktree) answered the
architecture half; an Apple-guidance survey (F6) answered the best-practices
half. No energy measurement has been taken yet -- that is Phase 1.

Summary of the inspection:

- Rendering is fully event-driven; there is no display link, render loop, or
  poll anywhere in the hot path (F1).
- Hidden panes (unselected tab, occluded window, zoomed-away split) skip all
  render planning and drawing, but keep parsing PTY bytes so notifications,
  recovery, and instant reveal stay correct (F2).
- While hidden, main-actor frame deliveries continue at whatever rate the main
  thread can service -- coalesced to one pending, but not throttled -- and each
  delivery pays a synchronous cross-queue fence (F3).
- The PTY host queue's QoS is unspecified -- no explicit classification (F4).
- Nothing prevents App Nap or takes power assertions; thermal/Low Power Mode
  notifications are observed by the benchmark harness but the app never adapts
  (F5).

## Current hypotheses

### H1 -- hidden-flood delivery churn is a measurable energy cost

Mechanism: each hidden-pane delivery wakes the main thread and pays a ~0.15ms
sync-fence floor (F3); macOS's energy-impact model weights wakeups heavily, so
even low CPU% could show up as energy impact. Confirmed if the F9 ceiling hack
(drop deliveries while hidden) moves powermetrics energy/wakeup numbers beyond
noise on the flood workload; rejected otherwise. Competing explanation: H2.

### H2 -- parse CPU dominates delivery churn, making QoS the larger lever

Mechanism: the parser runs ~10 MB/s on the host queue
(`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#readReady`
doc comment); under flood that is a sustained core, dwarfing per-delivery fence
costs. If true, E-core placement via QoS saves more than any delivery
throttle. Distinguished from H1 by the per-thread CPU split in F7 and the two
ceiling hacks (F9 vs F10) measured separately.

### H3 -- App Nap can backpressure hidden jobs through the PTY drain

Mechanism: App Nap regulates a napped app's CPU, I/O, and timers
([Extend App Nap](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html)).
The child shell is a separate process and does not nap, but its writes block
once the kernel PTY buffer fills, so a throttled drain in the napped app slows
the child. Confirmed if, with the workload held constant, a fully occluded
*napping* run completes measurably slower than the same occluded run held
un-napped by a temporary scoped activity assertion, nap state verified in both
(F8); rejected if wall-clock is equal within variance. (Occluded-vs-visible is
not the comparison: visible runs also pay planning and drawing, which would
mask or imitate nap backpressure.)

### H4 -- the hidden-flood scenario is rare enough that only QoS matters

Mechanism: an idle background tab already costs ~zero (F1/F2); the waste only
exists while a nonvisible pane produces sustained output. If dogfooding
telemetry (F11) shows the absolute avoidable work is small -- little wall-clock
time spent nonvisible-with-output, few bytes parsed there, low accumulated
delivery/fence cost -- the delivery throttle's real-world win collapses
regardless of its flood-workload ceiling.

## Candidate direction, pending evidence

Tier the pane's duty cycle by visibility, never by correctness -- one policy
for every nonvisible pane:

| State | Reads/parse | Main-actor delivery | Planning/draw |
| --- | --- | --- | --- |
| Visible | event-driven | immediate (today) | immediate (today) |
| Nonvisible (hidden tab, occluded window, zoomed-away) | unchanged | bounded cadence ~500ms-1s + urgent bypass | off (today) |

The bounded cadence is load-bearing for the recovery boundary: primary-history
mutation reaches the runtime only through delivery
(`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift#consume`
-> `onPrimaryHistoryMutation`), so any nonvisible mode without a bounded
delivery interval silently stops recovery checkpoints for a long-running
silent build. Urgent = semantic events (bell -> notification), clipboard
writes, child exit -- delivered immediately. Reveal and explicit reads fence
first (`synchronizeState()` already exists for exactly this), then plan one
complete frame. The occluded case needs no separate tier: the cadence timer's
generous leeway lets App Nap coalesce or defer it, so nap regulation -- not a
second policy -- is what deepens the occluded state. Provisional: Phase 1
evidence decides whether Phase 3 is built at all.

## Task ledger

Ordered by confidence: Phase 1 is pure measurement (highest confidence, no
risk), Phase 2 is high-confidence/low-risk change plus ceiling probes, Phase 3
activates only if Phase 1-2 evidence justifies it.

### Phase 1 -- establish the baseline (measure, change nothing)

- [ ] T1 Idle wakeup check: idle DanTerm with several tabs open, Activity
  Monitor "Idle Wake Ups" (target <= 1/s per Apple's timer guide) and
  `sudo timerfires -p <pid>`. Record in F7. Also confirm the "App Nap" column
  engages when fully occluded.
- [ ] T2 Hidden-flood baseline: fixed-byte flood workload run to completion in
  a hidden pane, measured under the paired contract (investigation rules) --
  including the A/A variance runs that freeze the decision threshold -- plus
  the per-thread CPU split (main thread vs host queue) via Instruments or
  `top`. This is the H1-vs-H2 discriminator, and its `--show-process-qos`
  distribution is T5's premise. Record in F7.
- [ ] T3 Delivery-rate instrumentation: `TerminalPaneFenceMetrics.delivery.count`
  (`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift#TerminalPaneFenceMetrics`)
  is an in-memory controller property with no sampling surface in a running
  app -- benchmark artifacts capture fence totals only at draw boundaries,
  which a hidden pane never produces. Add measurement instrumentation: emit
  timestamped, visibility-tagged counter snapshots through the
  characterization harness, then sample the hidden flood. Record in F7.
- [ ] T4 App Nap backpressure check (H3): two fully occluded runs of the same
  fixed workload -- one naturally napping, one held un-napped by a temporary
  scoped activity assertion (measurement scaffolding only, removed after) --
  with nap state verified in both (Activity Monitor's App Nap column),
  repeated runs. Occluded-vs-visible is not the comparison; it confounds nap
  state with planning/draw cost. Record in F8. Begin only after T1 confirms
  nap actually engages, else the null result is unarguable.

### Phase 2 -- high-confidence changes and ceiling probes

- [ ] T5 Classify the host queue's QoS. The queue at
  `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#queue` is
  created without an explicit QoS class, so its placement today is whatever
  the system infers; Apple: "It is very important that you have your work
  correctly classified"
  ([Prioritize Work at the Task Level](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheTaskLevel.html)).
  Premise: T2's baseline `--show-process-qos` distribution, showing where the
  work actually runs before any reclassification is judged. Probe both
  shapes -- fixed `.userInitiated` and fixed `.utility` (relying on sync-fence
  QoS boosting from the main actor for the visible path) -- through the paired
  benchmark harness for typing-echo and draw-latency regressions, and through
  the T2 contract for the energy delta. Decision gate: D1.
- [ ] T6 Ceiling hack for the delivery throttle (H1): measurement branch that
  suppresses the entire hidden main-actor delivery, *including its
  scheduling* -- the `TerminalPaneDeliveryBoundary.scheduleFrame` hop is never
  enqueued while hidden
  (`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift#TerminalPaneDeliveryBoundary`)
  -- while PTY reading and parsing stay unchanged. Guarding inside
  `consumeHostUpdate` is not the hack: that closure runs inside the hop the
  boundary already scheduled, so every main-thread dispatch and wakeup -- the
  cost H1 says dominates -- would survive and understate the ceiling. Rerun T2
  under the same contract, diff. The delta is the *maximum* win of any real
  throttle. If inside the frozen threshold, Phase 3 T8 is rejected without
  implementation. Record in F9.
- [ ] T7 Ceiling hack for QoS (H2): hardcode the host queue to `.utility`,
  rerun T2 under the same contract, diff energy and E-core (AMP) residency.
  A residency verdict requires the per-cluster fields to actually appear in
  the output (they need `--show-process-ipc` alongside `--show-process-amp`,
  per the contract); if they are absent, fix the invocation before recording
  anything. Record in F10.
- [ ] RESEARCH T11 Dogfooding opportunity counter (H4): characterization-style
  instrumentation recording, over a normal day: wall-clock time each pane
  spends nonvisible while producing output, bytes parsed in that state, and
  delivery/fence-count deltas attributable to it -- then estimate the absolute
  avoidable work over the window. Raw delivery share is not the metric: it is
  endogenous to main-thread service rate and burst shape, and one brief flood
  can dominate it. Decides whether the flood-workload ceiling matters in
  practice. Record in F11.

### Phase 3 -- conditional improvements (gated on Phase 1-2 evidence)

- [ ] T8 Nonvisible delivery cadence with urgent bypass (the single policy in
  Candidate direction). Begin only after T6 shows a ceiling above the frozen
  threshold and T11 shows the scenario occurs. Cadence timer gets generous
  leeway (Apple floor: 10% of interval; use 50-100% for a background-only
  timer,
  [Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)).
  Behavioral obligations, all deterministically tested: urgent classes
  (semantic events incl. bell, clipboard writes, child exit) deliver
  immediately; a primary-history mutation reaches the runtime within one
  cadence interval *plus the timer's maximum leeway* -- at 100% leeway that is
  2x the interval, and that inclusive bound is what the test asserts, since a
  leeway-granted timer may legitimately fire that late; OS suspension of the
  process (App Nap deferring the timer) is outside the scheduling bound and is
  acceptable because recovery resumes with the process; explicit reads and reveal
  fence first and observe post-flood state; after reveal, the rendered frame
  for a given byte stream equals the always-visible frame for the same
  stream; the cadence timer is cancelled on pane teardown; and the
  delivery-count test asserts the cadence itself.
- [ ] T10 Targeted App Nap assertion, only if T4 confirms H3: scoped
  `ProcessInfo.beginActivity` around running jobs
  ([ProcessInfo](https://developer.apple.com/documentation/foundation/processinfo)).
  The job boundary is the semantic command lifecycle the engine already
  emits -- acquire on `.commandStarted`, release on `.commandEnded`
  (`lib/TerminalCore/Sources/TerminalCore/TerminalSemanticEvent.swift#commandStarted`)
  -- not the shell process (pane-lifetime, i.e. the rejected standing
  assertion) and not output recency (no reliable end boundary; leaks the
  assertion or drops it mid-silent-build). A pane whose shell reports no
  command marks never acquires an assertion. Proof obligations: the assertion
  is released on `.commandEnded` and on pane teardown (no leaked activity
  outlives its referent). Preemptive assertions are rejected (see Rejected).
- [ ] TODO T12 Thermal / Low Power Mode adaptation: coarsen the nonvisible
  cadence under `.serious`/`.critical` thermal state or Low Power Mode
  ([Respond to Thermal State Changes](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/RespondToThermalStateChanges.html)).
  The observation plumbing already exists in
  `app/TerminalBenchmark.swift#TerminalBenchmarkObserver` (benchmark builds
  observe both notifications); the app never adapts. Proof obligation: the
  baseline cadence is restored when the thermal/power state clears. Lowest
  priority.

## Rejected

### Read-side throttling (pausing or slowing the PTY read source while hidden)

Considered as the obvious "batch reads" move. Rejected because the kernel PTY
buffer is small; draining every interval T caps the child's write throughput at
roughly buffer/T -- e.g. ~16 KiB per 100ms is ~160 KB/s -- silently slowing a
user's background build via backpressure (the classic hidden-terminal
complaint). Total parse CPU is proportional to bytes regardless of batching,
so the trade buys host-queue wakeups (cheap, E-core-able under T5) at the cost
of user-visible child stalls. Reopen only if measurement shows host-queue
wakeups (not parse CPU) dominate hidden-flood energy *and* a buffer-size probe
shows the throughput cap is not binding. Exact kernel buffer size is
unverified -- see open questions.

### Preventing App Nap with a standing assertion

Considered as protection for background jobs. Rejected: nap eligibility is the
engine's structural advantage (F5, F6), and a standing assertion while any
shell has a job running would defeat napping nearly always. Apple's guidance is
assertions for *user-initiated* work, scoped to the operation
([Extend App Nap](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html)).
T10 is the narrowly-scoped version, and only if H3 is confirmed.

### A separate occluded-window "urgent-only" tier

Considered as a deeper third tier below the hidden-tab cadence. Rejected:
primary-history mutation reaches the runtime only through delivery
(`TerminalPaneSession.swift#consume` -> `onPrimaryHistoryMutation`, consumed by
the runtime's recovery scheduling), so a mode with no bounded delivery
interval silently stops recovery checkpoints for a long-running occluded build
that rings no bell, writes no clipboard, and does not exit -- violating the
recovery boundary in Purpose. One bounded-cadence policy covers every
nonvisible pane, and App Nap already regulates the occluded process further
without a second policy. Reopen only if measurement shows the occluded state
needs more than the shared cadence *and* a separate bounded-freshness
mechanism for recovery is designed first.

### Parse-side deferral (spooling raw bytes unparsed while hidden)

Considered as the only way to cut hidden-flood parse CPU. Rejected: total
parse cost is unavoidable if state must stay exact, so deferral only trades
wakeups for staleness; it delays OSC/bell semantics (breaking the
notification design goal), and a bounded spool ends in either forced
backpressure (first rejection) or unbounded memory. Reopen only if H2 is
confirmed *and* T5's E-core placement is shown insufficient.

## Open questions and caveats

- The macOS kernel PTY buffer size is asserted from memory, not measured; the
  read-side rejection's throughput arithmetic needs a fill-test probe before
  anyone reopens that idea.
- The ~0.15ms fence floor and ~10 MB/s parse rate are quoted from the
  `readReady` doc comment's earlier measurements, not re-measured at this
  commit.
- Whether Metal (as opposed to OpenGL, which Apple documents as disqualifying)
  prevented App Nap under the libghostty backend is unverified; the
  comparative claim in F6 is scoped to what Apple documents.
- powermetrics requires sudo; T2/T6/T7 need an interactive session or a
  pre-authorized sudoers entry, and their artifact handling should follow
  [agent-docs/terminal-performance.md](../../../agent-docs/terminal-performance.md).
- Related prior work: doc [19](../19-owner-queue-occupancy.md) (owner-queue
  occupancy and fence waits) and doc [20](../20-pty-throughput-and-interactive-stimulus.md)
  (drain cost, flood stimulus) own the measurement machinery T2-T3 reuse.

## Outcome

Investigation in progress.
