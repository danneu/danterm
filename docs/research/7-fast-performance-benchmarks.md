# Fast paired A/B performance benchmarks

Research started: 2026-07-23.

## Purpose

This file owns the investigation into replacing DanTerm's slow, noisy
performance benchmark workflow with a paired, interleaved A/B runner that
answers the everyday question -- "I changed the code; is it faster?" -- in
about a minute per workload.

The campaign's null hypothesis is deliberately the simplest credible design:

- build the baseline and candidate binaries once;
- run both as persistent apps side by side (bundle ids suffixed `.a`/`.b`);
- alternate short measured blocks between them in one machine session; and
- decide from the paired per-block differences with a small fixed block count.

Interleaving makes both arms share the same thermal state, background load,
and display session, so slow machine drift cancels in the paired difference
instead of needing to be modeled. Every piece of added sophistication --
adaptive stopping rules, uncertainty machinery, distributional modeling --
must be purchased with evidence that this simple design fails validation. The
burden of proof is on complexity.

The investigation may replace the runner, result schema, fixtures, and
history. Existing benchmark data is evidence about the old method, not a
compatibility obligation. The desired endpoint is a small ladder:

- `quick`: one command comparing the working tree against a baseline binary,
  paired and interleaved, fast enough to run after every meaningful change;
- `confirm`: the same paired design with more blocks, for close results and
  durable records;
- `profile`: sustained single-candidate diagnosis of the same optimized
  workload, with exact process and binary identity;
- a canonical geometry of a window statically sized to the MacBook's built-in
  Retina screen (not the macOS fullscreen Space); and
- a Ghostty reference at an honestly shared boundary, severable from the rest
  of the campaign.

This is research, not an implementation plan. Settled behavior and
architecture must graduate to a plan or design document before implementation
begins.

## Investigation rules

- Validation is empirical: A/A no-change trials and injected known changes on
  this machine, not untested independence, distribution, or drift assumptions.
- Use release builds for performance claims. Profiled runs remain diagnostic
  and never become benchmark history.
- Measure end-to-end wall time and correctness as well as the timed operation;
  speed never excuses an invalid workload.
- The fixed paired design carries the burden of validation; added statistical
  complexity carries the burden of proving it is necessary.

## Trigger and current evidence

The current five-workload redraw command spends 10-15 minutes launching fresh
apps while timing only a small fraction of that wall time, yet its 15 batches
still do not resolve small deltas. Its fixed 80x24 geometry and history-vs-now
comparison also mismatch the screen-sized, same-session optimization question.
F1 records the measurements and structural implications.

The worktree was at `eb95e13` when this research started. No new benchmark
was run for this initial survey; F1's figures come from committed records in
`benchmarks/results/terminal-redraw.jsonl` and the harness sources.

## Performance workload ladder

The routine suite has five workloads, each retained for one distinct
performance question:

| Level | Workload | Question it answers |
|---|---|---|
| Core | Terminal feed | How quickly does the pure parser/grid/damage path consume representative terminal input? |
| Session/app | Scrollback stream | How quickly does sustained PTY output travel through backpressure, actor hops, snapshots, scrolling, and retention? |
| Serialized draw | Screen-sized content churn | How expensive is replacing the visible text while styling remains stable? |
| Serialized draw | Screen-sized style churn | How expensive is restyling stable visible text? |
| Serialized draw | Screen-sized incremental mixed updates | Does localized damage avoid full-window work when a deterministic subset of cells changes in both content and style? |

`quick` runs the one workload selected for the code path under investigation.
`confirm` runs all five. A workload remains in the ladder only while it catches
a distinct regression or changes an optimization decision.

There is no separate full-window mixed-churn workload: content and style churn
already isolate its dominant work, while incremental mixed updates answer the
distinct damage-efficiency question. Symbol-, sprite-, Unicode-, or other
specialized workloads remain opt-in diagnostics unless a demonstrated
regression proves they deserve a separate routine question.

## Current hypotheses

### H1 -- interleaved pairing cancels the noise that makes small deltas expensive

Proposed mechanism: when A and B blocks alternate within one session, slow
drift (thermals, background load, display state) contributes nearly equally
to both arms and cancels in the paired difference. The remaining noise is
fast block-to-block jitter, which a small fixed number of block pairs can
average out.

Competing explanations: fast jitter may itself be large or structured
(multimodal, autocorrelated) enough that a small fixed design still
misclassifies changes near the effect of interest; or drift may be fast
relative to the alternation period and fail to cancel.

Confirm via A/A trials (the same binary installed as both `.a` and `.b` --
nearly free, since one build serves both arms) and injected known-change
trials. H1 is supported if the fixed paired design meets the D1 accuracy
target within the D4 time budget. If it fails, the escalation path is a
validated adaptive design -- but only then.

### H2 -- persistent processes with per-block resets preserve decision validity

One launch per arm, with an untimed reset and settling phase between measured
blocks, should remove nearly all lifecycle overhead. The risk is carryover:
terminal state, glyph and layout caches, allocator state, or accumulated
scrollback could make later blocks unrepresentative or order-dependent.

Confirm by instrumenting reset completeness (terminal state, damage counts,
acknowledgment sequences), comparing block statistics across positions within
a run, and spot-checking persistent-process results against a handful of
fresh-launch samples. Steady-state caches are arguably the representative
condition for everyday use; cold start can remain a separate startup
benchmark rather than contaminating this one.

### H3 -- two coexisting app instances do not contaminate each other's blocks

Both arms live simultaneously as separate bundles (bundle ids appending `.a`
and `.b`) with isolated homes and IPC. Only the arm being measured is
frontmost and visible; the idle arm receives no output. Risks: WindowServer
or GPU contention from the second app's mere existence, focus and
notification cross-talk, occlusion throttling of the idle arm affecting
shared state, and scheduler placement (performance vs efficiency cores)
differing between arms.

Confirm by comparing A/A noise with both apps alive against A/A noise with a
single app alive. Reject coexistence if the second app measurably widens the
paired-difference distribution; the fallback is alternating sequential
launches, which reintroduces some lifecycle cost but keeps the pairing.

### H4 -- screen-sized Retina geometry exposes the costs that matter to use

A window statically sized to the built-in display covers many times the
cells and backing pixels of 80x24, so it should magnify render planning,
CoreText/CoreGraphics execution, damage, and presentation costs that dominate
normal use. The window is sized once, before measurement; the achieved grid
is derived from the settled window and frozen for the run. No fullscreen
Space transition is involved.

A screen-sized history is machine- and display-specific. That is acceptable
for local optimization if compatibility metadata is exact. Confirm the
geometry matters by comparing 80x24 and screen-sized rankings for at least
two known render changes; if they always agree, the cheaper geometry may
deserve a larger role.

### H5 -- the fast runner can preserve deep single-arm profiling

The paired decision workflow answers whether a change is faster; agents still
need a sustained diagnostic mode to discover where CPU time is spent and why
the result changed. Each workload should therefore run continuously against
the candidate alone, outside paired measurement, while publishing the exact
app PID, symbol-bearing binary, source identity, workload, geometry, and
artifact location.

Confirm that macOS `sample`, `xctrace` Time Profiler, and an externally
attached command-line profiler can observe the same optimized workload used by
`quick` and `confirm`. Preserve the textual sample, trace and export, symbols,
identity, and harness log. Profiling changes execution conditions, so its
timings are diagnostic evidence only and must never enter paired decisions or
benchmark history.

## Candidate direction, pending evidence

The runner shape under the null hypothesis:

1. Build baseline and candidate once. Assemble and sign two bundles whose
   bundle ids append `.a` and `.b`, each with an isolated home, temp, and
   IPC namespace.
2. Launch both apps persistently. Size each window statically to the
   built-in Retina display's frame, converge the grid, and record display
   identity, mode, scale, point and backing-pixel extents, and the achieved
   grid.
3. Record machine state (thermal state, AC power, low-power mode) at run
   start and around every measured block.
4. Run untimed warm-up in both arms until a simple stabilization gate is met
   or a short cap expires.
5. Alternate short measured blocks between arms with within-run
   counterbalancing. Randomize only among position-balanced schedules (for
   example, ABBA/BAAB) so monotonic drift cannot favor either arm. An untimed
   fixture reset and settling phase separates blocks. Arm switches are
   excluded from measurement; the measured arm must be frontmost and
   unoccluded for the whole block or the block is invalid. Both windows need
   not be simultaneously visible.
6. After N block pairs -- candidate N chosen from the Phase 2
   persistent-runner pilot (the Phase 1 old-data decomposition is
   orientation only) and the final value frozen through Phase 3 calibration
   and held-out validation -- report paired per-block differences: median ratio, sign
   consistency, raw samples, detected outliers without silent deletion,
   machine-state flags, every invalidation reason, and total wall time
   alongside measured time.
7. `quick` uses the minimum validated N. `confirm` uses a larger fixed N and
   is the only mode that earns durable history. `profile` never enters
   history: it runs the selected candidate workload as a sustained single arm,
   publishes its exact PID and binary identity, and accepts `sample`,
   `xctrace`, or another attached profiler.

A/A validation is nearly free in this design: install the same binary as
both arms and the entire pipeline exercises itself against a true null.

No block length, block-pair count, decision threshold, or equivalence band
is selected yet. Those numbers come from F3 and F8, not convention.

## Task ledger

### Phase 1 -- size the design from measured variance

- [x] Extract raw batch values from committed history and staged artifacts
  (or rerun two unchanged commits if needed) and decompose variance into
  within-block, between-block, and between-launch components, following the
  Kalibera-Jones repetition-sizing method; record in F3. This decomposition
  is preliminary orientation only: the old fresh-launch records cannot
  reveal persistent-process block variance, A/B covariance, reset
  carryover, or alternation effects. Final block duration and candidate N
  values come from the Phase 2 pilot series, not from this data.
- [x] Define minimum effects of interest: the smallest regression worth
  blocking in `quick` and the smallest worth recording in `confirm`; record
  the user-facing rationale in D1.
- [ ] Validate that the five selected ladder workloads exercise the distinct
  questions recorded in D2; keep specialized symbol, sprite, Unicode, and
  full-window mixed cases outside the routine suite unless evidence shows one
  changes an optimization decision.

### Phase 2 -- prototype the paired runner

- [ ] Prove two suffixed-bundle apps coexist cleanly: isolated homes, IPC
  namespaces, no focus or notification cross-talk, no shared-state
  collisions; record the constraints and any required launch ordering in F4.
- [ ] Prototype persistent-process measured blocks with untimed resets;
  verify reset completeness via terminal state, draw counts, damage, and
  acknowledgment sequences in F5.
- [ ] Implement machine-state capture (thermal state, AC power, low-power
  mode) and the per-block occlusion assertion; demonstrate a block being
  invalidated by a Space switch and by a thermal-pressure flag.
- [ ] Compare A/A noise with both apps alive vs one app alive (H3); record
  in F6 and select coexistence or sequential alternation.
- [ ] Select and validate an immutable baseline/candidate build strategy:
  how HEAD, a named ref, and a dirty working tree are each snapshotted and
  built without source or artifact interference, with exact source identity
  (including dirty-state identity) recorded, and with proof that each
  suffixed bundle contains the intended binary; record in F4.
- [ ] Collect a pilot series from the persistent paired prototype and apply
  the Kalibera-Jones decomposition to it; select block duration and
  candidate N values from this pilot, superseding the Phase 1 orientation
  numbers, before Phase 3 validation begins; record in F7.
- [ ] Measure the prototype's end-to-end `quick` wall time and its phase
  decomposition (build, assemble/sign, launch, converge, warm-up, blocks,
  teardown) against the D4 candidate budget; record in F7.
- [ ] Prototype sustained single-candidate profiling for every surviving
  workload using the same fixture, geometry, reset behavior, and optimized
  binary as measured runs. Verify exact PID attachment with `sample` and
  `xctrace`, publish identity for external tools, preserve symbols and
  profiling artifacts, and prove profiled results cannot enter paired
  decisions or history; record in F7.

### Phase 3 -- validate the decision rule

- [ ] Predefine the required false-positive, inconclusive, and
  detection-power rates (from D1) before any trials run. Trial counts are
  sized to those targets, not vice versa: zero false positives in 50 A/A
  trials still only bounds the rate below roughly 6% at 95% confidence.
- [ ] Run a calibration set of A/A and injected-change trials to choose
  block length, block-pair counts, decision thresholds, equivalence band,
  and outlier policy; freeze the rule in D3.
- [ ] Measure final false-positive, inconclusive, and detection rates on a
  separate held-out set of A/A and injected-change trials, run only after
  the rule is frozen; record in F8. Tuning and validation must never share
  trials.
- [ ] Verify decision symmetry and drift robustness on the frozen rule:
  reversing A/B labels must reverse the reported effect without changing
  its magnitude beyond expected noise, and a controlled within-run drift
  must not systematically favor either arm under the selected
  counterbalancing scheme; record in F8.
- [ ] Escalate to an adaptive design only if the frozen fixed design fails
  the held-out F8 targets -- and any adaptive rule must be validated
  against optional-stopping bias by simulating its actual peeking schedule,
  not just its final decision.
- [ ] Set the `quick` and `confirm` wall-time budgets in D4 from measured
  prototype runtimes.

### Phase 4 -- geometry and compatibility identity

- [ ] Inventory the AppKit/CoreGraphics APIs for identifying the built-in
  display, reading its current mode and frame, sizing a window to it, and
  converting the content rect to backing pixels; record checked signatures
  and lifecycle constraints in F9. Decide frame vs visibleFrame.
- [ ] Derive the achieved grid dynamically from the settled window and
  replace fixed `24` damage assertions with the achieved row count.
- [ ] Define and validate the compatibility identity: display identity,
  current mode, refresh rate when available, points, backing pixels, scale,
  font/config, achieved grid, backend, fixture, build, OS, and toolchain.
  Fail rather than silently falling back to a different display or geometry.
- [ ] Compare 80x24 and screen-sized rankings for at least two known render
  changes; decide in D5 whether 80x24 remains as a secondary fast
  diagnostic.

### Phase 5 -- Ghostty reference (severable)

This phase must not block graduation: Phases 1-4 can graduate to an
implementation plan and ship without a Ghostty baseline.

- [ ] Enumerate observable timing seams in the pinned libghostty C API and
  DanTerm's Ghostty surface integration without guessing callback semantics;
  record viable boundaries in F10.
- [ ] Run the same screen-sized synchronized-output fixture against both
  backends and compare producer throughput and backpressure at matched
  geometry; select the durable target metric in D6.
- [ ] If Ghostty exposes no validated completed-presentation signal,
  explicitly reject per-draw equivalence and retain throughput as the only
  cross-backend baseline.

### Phase 6 -- graduate and verify

- [ ] Decide whether old JSONL history is archived, migrated as legacy, or
  deleted; never compare numbers across the method/schema boundary.
- [ ] Audit behavioral coverage for fixture reset, exact completed draws,
  window geometry and occlusion guards, machine-state flags, paired
  reporting, profiling identity and history exclusion, and history
  compatibility -- plus the contracts Phases 2-3 establish empirically, so
  they cannot regress silently: source/binary identity (each suffixed bundle
  contains the intended snapshot), arm isolation, position-balanced schedule
  generation (every completed run is balanced), and the frozen decision rule
  against deterministic sample fixtures. Tests must assert observable
  contracts, not helper structure.
- [ ] Graduate the accepted runner and schema to an implementation plan,
  then update `agent-docs/terminal-performance.md` as part of that
  implementation.
- [ ] Close this research with measured old/new suite runtime, A/A error
  rate, known-change detection power, and the Ghostty baseline status.

## Findings log

### F1 -- the current runner pays full lifecycle cost per sample and history comparison inherits machine drift

- Status: Initial survey complete; instrumented phase timing lands with the
  Phase 2 prototype.
- Date and investigator: 2026-07-23, Claude.
- Commit and worktree state: `eb95e13`; unrelated untracked
  `plans/wip/plan-this-wire-cmd-f-zazzy-cookie.md` preserved.
- Sources inspected: `scripts/terminal-draw-acceptance.py`,
  `scripts/terminal-benchmark.sh`, `scripts/terminal-benchmark-producer.py`,
  `app/TerminalBenchmark.swift`, `agent-docs/terminal-performance.md`, and
  `benchmarks/results/terminal-redraw.jsonl`.
- Measurements or examples: the default five-workload suite performs 80 app
  launches (one warm-up plus 15 measured per workload). At `d19103f`, the
  content/style/mixed workloads each show roughly 3.2 s of cumulative
  measured drawing inside command spans of roughly 85-95 s, with min-to-max
  batch-normalized ranges of 14.3%, 7.0%, and 10.8% of median:

  | Workload | Median | Min to max | Range relative to median |
  |---|---:|---:|---:|
  | Content churn | 305,240 ns | 279,228-322,761 ns | 14.3% |
  | Style churn | 302,798 ns | 295,431-316,530 ns | 7.0% |
  | Mixed churn | 307,196 ns | 286,339-319,536 ns | 10.8% |

  The ranges are not confidence intervals, but they reject the assumption
  that 15 fresh launches make small percentage changes trustworthy.
- Observation: nearly all wall time is harness lifecycle repeated per batch,
  and even 15 fresh launches leave ranges too wide to trust small deltas
  against history.
- Inference: the two structural fixes are amortizing the lifecycle
  (persistent arms) and removing drift from the comparison (pairing both
  binaries in one session). Shrinking draw-work duration further attacks the
  wrong term.
- Competing interpretations: launch-to-launch variation could itself be part
  of the population of interest; the timestamps behind the 85-95 s figure
  include save/report overhead rather than a clean phase decomposition.
- Uncertainty: no instrumented phase timing yet; wall-time shares are
  estimated from committed record timestamps.
- Next action: Phase 1 variance decomposition (F3), then the Phase 2
  prototype.

### F2 -- external precedent for pairing, interleaving, and empirically sized repetition

- Status: Initial literature survey complete.
- Date and investigator: 2026-07-23, Claude.
- Evidence:
  - Kalibera and Jones, "Rigorous Benchmarking in Reasonable Time" (ISMM
    2013), decomposes variance across experimental levels and uses the
    measured variance and cost at each level to choose where repetition buys
    precision. Its iteration/execution/build hierarchy maps directly to
    DanTerm's frame/block/process question and provides the method for F3:
    <https://kar.kent.ac.uk/33611/>.
  - Google Benchmark supports randomized interleaving of repetitions
    explicitly to reduce the impact of machine-state drift:
    <https://google.github.io/benchmark/user_guide.html>.
  - Sequential-analysis literature documents optional-stopping bias: rules
    that peek repeatedly inflate false-positive rates unless the peeking
    schedule is accounted for. Any future adaptive rule must be validated by
    simulating its actual schedule.
  - Apple cautions that `backingScaleFactor` is a backing scale, not a
    statement of physical pixel density:
    <https://developer.apple.com/documentation/appkit/nswindow/backingscalefactor>.
  - Ghostty's macOS renderer is Metal-based with a dedicated render thread,
    so no synchronous-draw-return boundary comparable to DanTerm's exists:
    <https://github.com/ghostty-org/ghostty>.
- Observation: mature tools reduce noise structurally (interleaving, paired
  designs, explicit warm-up, setup outside measurement) before reaching for
  statistical sophistication, and size repetition from measured variance.
- Inference: the null-hypothesis design follows precedent, not just
  parsimony. The locally validated inputs it still needs are the D1 effect
  sizes and the F3 variance components.
- Next action: F3.

### F3 -- the old runner's fresh-launch level dominates short-block precision

- Status: Phase 1 orientation complete; Phase 2 pilot data must supersede it.
- Date and investigator: 2026-07-24, Codex.
- Commit and worktree state: `488e824`; unrelated untracked
  `plans/wip/plan-this-wire-cmd-f-zazzy-cookie.md` preserved. Temporary
  reporting-only instrumentation exposed the per-draw durations already held
  by `TerminalBenchmarkObserver`; it was removed after collection and did not
  alter the timed renderer path.
- Data inventory: the 24 committed redraw records and existing staged records
  retain only min/median/max summaries, not the 15 raw launch values or
  per-draw values. Those summaries cannot identify nested variance
  components. Two unchanged, AC-powered content-churn series were therefore
  collected at 80x24 with 15 fresh app launches each. Every launch completed
  exactly 233 draws in series 1 or 226 draws in series 2; all draws damaged
  exactly 24 rows. The raw research artifacts are
  `.build/terminal-benchmark-staged/terminal-redraw-20260724-000200.jsonl`
  and
  `.build/terminal-benchmark-staged/terminal-redraw-20260724-000407.jsonl`.
- Method: for each balanced series, a nested random-effects ANOVA used draws
  within fresh app launches. The within-launch component is the pooled
  per-draw residual variance. The fresh-launch component is
  `max(0, variance(launch means) - within variance / draws per launch)`.
  This is the Kalibera-Jones variance-decomposition step, applied only to
  levels the old harness actually repeats.
- Measurements:

  | Series | Draws per launch | Overall mean | Within-launch SD (CV) | Fresh-launch SD (CV) | Launch-mean range |
  |---|---:|---:|---:|---:|---:|
  | 1 | 233 | 304,821 ns | 20,604 ns (6.76%) | 6,543 ns (2.15%) | 294,539-319,581 ns |
  | 2 | 226 | 308,124 ns | 21,053 ns (6.83%) | 6,642 ns (2.16%) | 297,607-320,219 ns |

  The two series means differ by 1.08%. Treating that difference as a third
  nested variance level would yield an estimated series SD of about 0.52%
  after subtracting the variance of 15 launch means, but two series provide
  only one degree of freedom, so that number is not a credible component
  estimate.
- Observation: averaging roughly 230 draws makes the within-launch
  contribution to a launch mean only about 1.4 microseconds, while the
  estimated fresh-launch component remains about 6.6 microseconds. More draws
  inside the same old batch therefore buy little precision; repetition is
  needed above the draw level.
- Orientation-only sizing: if the fresh-launch component were the relevant
  independent block variance, a normal-approximation 95% relative half-width
  would require about 18 repetitions for 1%, 5 for 2%, or 2 for 3%. These are
  not candidate `quick` or `confirm` counts: the approximation omits paired
  covariance, persistent-process carryover, alternation, and validated
  decision error rates.
- Structural limitation: one old measured batch is one fresh app launch.
  There is no repeated block within a persistent launch, so between-block and
  between-launch variance are aliased and cannot be decomposed separately.
  Calling the fresh-launch component "between-block" would merely rename the
  same level. The Phase 2 pilot must repeat measured blocks inside each
  persistent arm, then estimate draw, block, process, and paired-difference
  components from that hierarchy.
- Inference: H2's persistent-process reset is the leverage point to test.
  It removes the approximately 2.15% fresh-launch component from ordinary
  block repetition if reset carryover remains controlled, while pairing can
  cancel slower series drift. The old data supports the runner shape but
  cannot choose its block duration or N.
- Uncertainty: only content churn was rerun because Phase 1 is orientation,
  not workload calibration. Draw durations within a launch are ordered and
  may be autocorrelated, so the within-launch SD is descriptive rather than
  an independence claim. The temporary raw artifacts are build products and
  are not durable history.
- Next action: define D1's effects of interest, then collect the Phase 2
  persistent paired pilot that supersedes these estimates in F7.

## Decision log

### D1 -- minimum effects of interest and required accuracy rates

- Status: Effect sizes fixed; accuracy rates remain open until they are
  predefined before Phase 3 trials.
- Scope: this decision owns both halves of the accuracy contract -- the
  minimum effect sizes worth detecting, and the required false-positive,
  inconclusive, and detection-power rates for `quick` and `confirm` at
  those effect sizes. Phase 3 trial counts are sized to these rates and the
  frozen design passes or fails against them; they may not be chosen ad hoc
  during validation.
- Decision:
  - `quick` has a 5% minimum effect of interest. A candidate at least 5%
    slower than its paired baseline is worth blocking; an improvement of the
    same magnitude is worth calling faster. Smaller estimates may be shown,
    but `quick` must not turn them into a directional decision.
  - `confirm` has a 3% minimum effect of interest in either direction. This
    is the smallest change worth a durable faster/slower claim and benchmark
    record. Smaller estimates remain raw evidence, not a claimed change.
  - Effects are relative within one workload and compatible geometry. No
    cross-workload averaging may let a large improvement hide a 5%
    workload regression.
- User-facing rationale: `quick` is the everyday guardrail. Five percent is
  large enough to matter when repeated across hot terminal paths and large
  enough that a roughly one-minute check can reasonably be expected to
  resolve it. Ten percent would miss regressions large enough to erase
  several ordinary optimizations. Requiring `quick` to resolve 3% would spend
  its time budget on changes that often do not alter an optimization
  decision.

  `confirm` runs less often and produces durable evidence, so it purchases
  sensitivity to 3%. The branch has produced both large wins (about 20% and
  31%) and smaller incremental changes (about 2%, with a 1% slowdown treated
  as neutral in context). A 3% bar records meaningful cumulative movement
  without promoting every 1-2% fluctuation or incidental trade-off into a
  performance claim.
- Why not an absolute frame-time threshold: the ladder spans terminal feed,
  session throughput, serialized draw, and incremental damage at a
  screen-sized geometry. They have no single user-facing absolute unit or
  budget. Relative thresholds answer the shared A/B question; raw absolute
  timings remain in every report and a future workload-specific latency
  contract can add an absolute gate if product evidence justifies one.
- Evidence: F3 estimates about 2.15% fresh-launch CV in the old unpaired
  runner and shows why persistent pairing must replace it before these effects
  can be judged. The optimization index records changes from about 1-2% to
  31%, establishing that 3% and 5% separate marginal movement from changes
  that have affected optimization decisions.
- Still required before Phase 3: predefine false-positive, inconclusive, and
  detection-power targets separately for `quick` and `confirm`. Those rates,
  not these effect sizes alone, determine calibration and held-out trial
  counts.

### D2 -- redraw workload set

- Status: Direction set by user.
- Selected ladder and rationale: see Performance workload ladder.
- Excluded from the routine suite: a separate full-window mixed-churn
  workload, plus symbol-, sprite-, Unicode-, and other specialized cases
  without evidence that they catch a distinct regression or change an
  optimization decision.

### D3 -- block design and decision rule

- Status: Open.
- Evidence needed: F3 (variance components) and F8 (A/A and injected-change
  validation).
- Candidate solutions: fixed-N paired design with a simple robust comparison
  (the null hypothesis); a bounded adaptive stop only if fixed-N fails F8.
- Recommendation: fixed-N paired.

### D4 -- workflow runtime budgets

- Status: Open.
- Candidate starting targets: under 60 seconds for one `quick` workload
  comparison and under 5 minutes for the complete `confirm` suite, including
  cached build and harness overhead.
- Recommendation: treat as hypotheses until the Phase 2 prototype measures
  what is feasible.

### D5 -- canonical render geometry

- Status: Direction set by user; details open.
- Selected direction: canonical runs use a window statically sized to the
  MacBook's built-in Retina display at its current user-selected mode, with
  recorded point and backing-pixel extents and a dynamically derived grid.
  Native macOS fullscreen Spaces are out (see Rejected).
- Open details: frame vs visibleFrame, and whether 80x24 survives as a
  secondary fast diagnostic (Phase 4 comparison decides).

### D6 -- Ghostty comparison boundary

- Status: Open; severable from graduation.
- Recommendation: establish matched screen-sized synchronized-output
  throughput first. Add a serialized completed-presentation comparison only
  if both backends expose validated equivalent signals.

## Rejected

### Native macOS fullscreen Space as the canonical geometry

User decision. A fullscreen Space adds transition/settle noise, monopolizes
the machine during runs, and complicates occlusion and focus handling, while
the cost driver that matters is the number of visible cells and backing
pixels -- which a window statically sized to the built-in screen captures.
Reopen only if evidence shows the fullscreen presentation path itself
differs enough to change an optimization decision.

### History-vs-now as the primary quick comparison

F1 shows why same-session pairing, not drift-confounded history, must answer
the `quick` question; history remains only for durable `confirm` records.

### Adaptive stopping rule as the starting design

Per H1 and D3, adaptive stopping is reserved for an F8 failure of the simpler
fixed design.

### Fresh app process per measured batch, even with fewer launches

F1 shows that process-level independence did not buy decision-grade precision
for its lifecycle cost; arbitrarily lowering the count preserves that cost
model without evidence about decision errors. Fresh launches survive only as
a carryover cross-check (H2) and a fallback if coexistence fails (H3).

### Preserving old history at the expense of the new method

The old schema's 80x24 geometry, fixed batch count, and history-comparison
model conflict with the new goals. Keep it readable as legacy evidence, but
never compare numbers across the method boundary.

### Comparing DanTerm AppKit draw time with Ghostty Metal submission time

The operations end at different points in different rendering architectures.
Such a ratio would look precise while answering no stable question. Use a
shared externally observable boundary (throughput with backpressure) or
present separate backend-specific diagnostics.

## Open questions and caveats

- What should the default baseline arm for `quick` be: HEAD, a named ref,
  or a kept baseline binary? (The build/snapshot mechanics are a Phase 2
  task; only the default choice remains open.)
- What regression size is worth blocking locally (D1 input): 3%, 5%, 10%,
  or an absolute frame budget per workload?
- Is the paired unit a per-block total or a per-draw normalized value, and
  does draw-count variation between arms add noise to the normalized form?
- Does the idle second app measurably affect the measured arm (H3), and
  does scheduler placement (performance vs efficiency cores) differ between
  arms?
- Is steady-state cache behavior the right default, with cold start split
  into a separate startup benchmark?
- Can the runner prevent display sleep and refresh-rate switching without
  adding behavior unlike normal use?
- Screen-sized results are intentionally machine/display-specific. What
  smaller benchmark, if any, should remain for CI or cross-machine trends?
- Do 80x24 and screen-sized geometries ever rank real changes differently
  (Phase 4 decides D5's secondary-diagnostic question)?

## Outcome

Investigation in progress. The leading direction is a persistent, paired,
interleaved A/B runner over two coexisting suffixed-bundle apps, windows
statically sized to the built-in Retina display, with a small fixed block
count sized from measured variance and validated by A/A and injected-change
trials. Adaptive statistics are an escalation path, not the plan. No
benchmark implementation or canonical history has changed.
