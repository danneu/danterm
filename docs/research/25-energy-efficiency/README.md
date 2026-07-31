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
- The PTY host queue is created with no QoS class (F4).
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
the child. Confirmed if a timed build in a fully occluded window runs
measurably slower than the same build visible (F8); rejected if wall-clock is
equal within variance.

### H4 -- the hidden-flood scenario is rare enough that only QoS matters

Mechanism: an idle background tab already costs ~zero (F1/F2); the waste only
exists while a hidden pane produces sustained output. If dogfooding telemetry
(F11) shows hidden deliveries are a small share of real usage, the delivery
throttle's real-world win collapses regardless of its flood-workload ceiling.

## Candidate direction, pending evidence

Tier the pane's duty cycle by visibility, never by correctness:

| State | Reads/parse | Main-actor delivery | Planning/draw |
| --- | --- | --- | --- |
| Visible | event-driven | immediate (today) | immediate (today) |
| Hidden tab | unchanged | cadence ~500ms-1s + urgent bypass | off (today) |
| Occluded window | unchanged | urgent-only | off (today) |

Urgent = semantic events (bell -> notification), clipboard writes, child exit.
Reveal fences first (`synchronizeState()` already exists for exactly this),
then plans one complete frame. Provisional: Phase 1 evidence decides whether
any of the Phase 3 rows are built at all.

## Task ledger

Ordered by confidence: Phase 1 is pure measurement (highest confidence, no
risk), Phase 2 is high-confidence/low-risk change plus ceiling probes, Phase 3
activates only if Phase 1-2 evidence justifies it.

### Phase 1 -- establish the baseline (measure, change nothing)

- [ ] T1 Idle wakeup check: idle DanTerm with several tabs open, Activity
  Monitor "Idle Wake Ups" (target <= 1/s per Apple's timer guide) and
  `sudo timerfires -p <pid>`. Record in F7. Also confirm the "App Nap" column
  engages when fully occluded.
- [ ] T2 Hidden-flood baseline: flood workload in a hidden pane;
  `sudo powermetrics --samplers tasks` energy impact + idle wakeups, per-thread
  CPU split (main thread vs host queue) via Instruments or `top`. This is the
  H1-vs-H2 discriminator. Record in F7.
- [ ] T3 Delivery-rate observation: hidden flood, sample
  `TerminalPaneFenceMetrics.delivery.count`
  (`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift#TerminalPaneFenceMetrics`)
  per second. The counter already exists; no code change. Record in F7.
- [ ] T4 App Nap backpressure check (H3): timed build, fully occluded window
  vs visible, repeated runs. Record in F8. Begin only after T1 confirms nap
  actually engages, else the null result is unarguable.

### Phase 2 -- high-confidence changes and ceiling probes

- [ ] T5 Classify the host queue's QoS. The queue at
  `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#queue` is
  created with no QoS class; Apple: "It is very important that you have your
  work correctly classified"
  ([Prioritize Work at the Task Level](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheTaskLevel.html)).
  Probe both shapes -- fixed `.userInitiated` and fixed `.utility` (relying on
  sync-fence QoS boosting from the main actor for the visible path) -- through
  the paired benchmark harness for typing-echo and draw-latency regressions,
  and through T2's powermetrics setup for the energy delta. Decision gate: D1.
- [ ] T6 Ceiling hack for the delivery throttle (H1): measurement branch that
  drops `consumeHostUpdate` entirely while hidden, rerun T2, diff. The delta
  is the *maximum* win of any real throttle. If inside noise, Phase 3 T8 is
  rejected without implementation. Record in F9.
- [ ] T7 Ceiling hack for QoS (H2): hardcode the host queue to `.utility`,
  rerun T2, diff energy and E-core residency. Record in F10.
- [ ] RESEARCH T11 Dogfooding frequency counter (H4): characterization-style
  counter logging deliveries split by visibility over a normal day. Decides
  whether the flood-workload ceiling matters in practice. Record in F11.

### Phase 3 -- conditional improvements (gated on Phase 1-2 evidence)

- [ ] T8 Hidden-tab delivery cadence with urgency bypass. Begin only after T6
  shows a ceiling worth having and T11 shows the scenario occurs. Cadence
  timer gets generous leeway (Apple floor: 10% of interval; use 50-100% for a
  background-only timer,
  [Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)).
  Reveal path fences via `synchronizeState()` before planning. Delivery-count
  test asserts the cadence and that a bell still fences immediately.
- [ ] T9 Occluded-window urgent-only tier. Depends on T8's machinery; the
  upstream signal split (window occlusion vs tab selection) already exists in
  `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#effectiveSurfaceVisibility`
  before it is collapsed to one bool.
- [ ] T10 Targeted App Nap assertion, only if T4 confirms H3: scoped
  `ProcessInfo.beginActivity` around running jobs whose output is being
  drained ([ProcessInfo](https://developer.apple.com/documentation/foundation/processinfo)).
  Preemptive assertions are rejected (see Rejected).
- [ ] TODO T12 Thermal / Low Power Mode adaptation: coarsen hidden cadence
  under `.serious`/`.critical` thermal state or Low Power Mode
  ([Respond to Thermal State Changes](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/RespondToThermalStateChanges.html)).
  The observation plumbing already exists in
  `app/TerminalBenchmark.swift#TerminalBenchmarkObserver` (benchmark builds
  observe both notifications); the app never adapts. Lowest priority.

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
