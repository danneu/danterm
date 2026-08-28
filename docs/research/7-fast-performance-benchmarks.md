# Fast paired A/B performance benchmarks

<!-- The paths below are deliberately gone; this doc records them as history. -->
<!-- docs-lint: allow-missing benchmarks/results/terminal-redraw.jsonl -->

Research started: 2026-07-23. **Status: CLOSED 2026-07-28. The runner shipped,
graduated to `plans/impl/2026-07-24-1423-fast-paired-performance-benchmarks.md`,
and decided every optimization verdict in docs 8-13. Phase 6 (the Ghostty
reference) was declared severable and was severed -- it was never built. Phase 5's
independent held-out certification is retired, not failed.** Read "How it held up
in use" at the end before trusting a threshold frozen here: `8/F24` showed A/A
calibration overstates real revision-pair precision, and `8/D2` routed
`incremental-mixed` off this instrument entirely.

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
- a canonical geometry of a normal window sized to a fixed large grid (179x66,
  read via `tput cols`/`tput lines` from a live DanTerm pane filling the
  built-in Retina screen) -- the grid DanTerm already presents, sidebar and
  all chrome included, at full viewport -- not the macOS fullscreen Space; and
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

## Current execution boundary

The 179x66 runner, workload contracts, median decision rules, and runtime
budgets are calibrated and ready to graduate. The production benchmark is
calibration-backed, not independently held-out-certified.

The planned held-out certification required 1,560 GUI attempts: 26 condition
cells with 60 trials each. At the observed collection cost of about 24 seconds
per attempt, that is roughly 10.4 hours before invalid replacements. That cost
is disproportionate to the everyday engineering decision this system serves.
The partially collected opaque manifest remains preserved, but its campaign is
retired without opening conditions or outcomes. Do not resume it as a
graduation gate.

Independent held-out certification remains optional future research if actual
use exposes a questionable decision or if a publication-grade error-rate claim
becomes valuable. Until then, describe the frozen rates as calibration results,
retain raw paired evidence for each real comparison, and use `confirm` for
close or consequential results.

## Performance workload ladder

The routine suite has five workloads, each retained for one distinct
performance question:

| Level           | Workload                               | Question it answers                                                                                                  |
| --------------- | -------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Core            | Terminal feed                          | How quickly does the pure parser/grid/damage path consume representative terminal input?                             |
| Session/app     | Scrollback stream                      | How quickly does sustained PTY output travel through backpressure, actor hops, snapshots, scrolling, and retention?  |
| Serialized draw | Screen-sized content churn             | How expensive is replacing the visible text while styling remains stable?                                            |
| Serialized draw | Screen-sized style churn               | How expensive is restyling stable visible text?                                                                      |
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

### H4 -- a fixed large grid exposes the costs that matter to use

A grid many times larger than 80x24 covers many times the cells and backing
pixels, so it should magnify render planning, CoreText/CoreGraphics
execution, damage, and presentation costs that dominate normal use. In
particular, a small fixed damage region is a much smaller fraction of a large
grid, so a large grid is what makes the incremental-mixed damage-efficiency
question discriminating at all. The grid is a fixed constant (D5), frozen for
the run; the window is sized once, before measurement, and no fullscreen
Space transition is involved.

Per D5 the user has scoped this runner to one machine, so the grid does not
need to be portable or dynamically matched to a display: it is a hand-chosen
constant equal to the measured full-viewport grid on the built-in screen
(179x66, sidebar and all chrome included). Machine- and
display-specificity is therefore accepted by decision, not merely tolerated.
A confirming experiment remains worthwhile but is no longer a gate: compare
80x24 and the fixed large grid on at least two known render changes to see
whether they ever rank changes differently, which decides only whether 80x24
is worth keeping as an optional fast diagnostic.

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
2. Launch both apps persistently. Size each window to the fixed canonical
   grid (D5; 179x66, the measured full-viewport DanTerm grid), converge the
   grid, and record the frozen grid, font/config, scale, point and
   backing-pixel extents, and the achieved grid. No runtime display
   interrogation.
3. Record machine state (thermal state, low-power mode) at run
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
   orientation only) and the final value frozen by canonical-geometry
   calibration before held-out validation -- report paired per-block
   differences: median ratio, sign
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

No canonical block length, block-pair count, decision threshold, or
equivalence band is selected yet. F7/F8 developed and exercised the selection
method at 80x24; the canonical values come from rerunning that method at
179x66, not from convention or from carrying the old values forward.

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
- [x] Validate that the five selected ladder workloads exercise the distinct
      questions recorded in D2; keep specialized symbol, sprite, Unicode, and
      full-window mixed cases outside the routine suite unless evidence shows one
      changes an optimization decision.

### Phase 2 -- prototype the paired runner

- [x] Prove two suffixed-bundle apps coexist cleanly: isolated homes, IPC
      namespaces, no focus or notification cross-talk, no shared-state
      collisions; record the constraints and any required launch ordering in F4.
- [x] Prototype persistent-process measured blocks with untimed resets;
      verify reset completeness via terminal state, draw counts, damage, and
      acknowledgment sequences in F5.
- [x] Implement machine-state capture (thermal state, low-power
      mode) and the per-block occlusion assertion; demonstrate a block being
      invalidated by a Space switch and by a thermal-pressure flag.
- [x] Compare A/A noise with both apps alive vs one app alive (H3); record
      in F6 and select coexistence or sequential alternation.
- [x] Select and validate an immutable baseline/candidate build strategy:
      how HEAD, a named ref, and a dirty working tree are each snapshotted and
      built without source or artifact interference, with exact source identity
      (including dirty-state identity) recorded, and with proof that each
      suffixed bundle contains the intended binary; record in F4.
- [x] Collect a pilot series from the persistent paired prototype and apply
      the Kalibera-Jones decomposition to it; select block duration and
      candidate N values from this pilot, superseding the Phase 1 orientation
      numbers, before calibration-method development begins; record in F7.
- [x] Measure the prototype's end-to-end `quick` wall time and its phase
      decomposition (build, assemble/sign, launch, converge, warm-up, blocks,
      teardown) against the D4 candidate budget; record in F7.
- [x] Prototype sustained single-candidate profiling for every surviving
      workload using the same fixture, geometry, reset behavior, and optimized
      binary as measured runs. Verify exact PID attachment with `sample` and
      `xctrace`, publish identity for external tools, preserve symbols and
      profiling artifacts, and prove profiled results cannot enter paired
      decisions or history; record in F7.

### Phase 3 -- validate the decision rule

- [x] Develop and freeze an initial five-workload calibration method at
      80x24. Treat its pair counts, thresholds, and runtime projections as
      provisional method-development evidence that must be superseded at 179x66.
- [x] Predefine the required false-positive, inconclusive, and
      detection-power rates (from D1) before any trials run. Trial counts are
      sized to those targets, not vice versa: zero false positives in 50 A/A
      trials still only bounds the rate below roughly 6% at 95% confidence.
- [x] Run a calibration set of A/A and injected-change trials to choose
      block length, block-pair counts, decision thresholds, equivalence band,
      and outlier policy; freeze the rule in D3.
- [x] Set the `quick` and `confirm` wall-time budgets in D4 from measured
      prototype runtimes. Retain the budgets across the geometry migration, but
      remeasure whether the recalibrated 179x66 rules meet them.

### Phase 4 -- geometry and compatibility identity

Per D5 the geometry is now a fixed constant on one machine, not a dynamically
display-matched window, so this phase shrinks from a display-identification
subsystem to choosing and validating a constant.

- [x] Freeze the canonical grid constant at 179x66 (the measured full-viewport
      DanTerm grid, chrome included) and size the benchmark window to reproduce
      it. Confirm a windowed (non-fullscreen-Space) DanTerm filling the screen
      reproduces 179x66 -- if the reference was captured with the menu bar hidden,
      the windowed row count could shift by about one -- and that the window stays
      fully visible and unoccluded for a complete run; record the checked AppKit
      sizing calls and the settling behavior in F9. No display-identity
      interrogation, no frame-vs-visibleFrame matching, no dynamic-mode reading.
- [x] Derive the achieved grid from the settled window and replace fixed `24`
      damage assertions with the achieved row count, so the damage contracts hold
      at the new grid.
- [x] Record the (now trivial) compatibility identity as a constant: the
      frozen grid, font/config, backing scale, backend, fixture, build, OS, and
      toolchain -- plus the machine, since results are machine-specific by
      decision. Fail rather than silently running at a different grid than the
      frozen constant.
- [x] Recalibrate block size and the per-workload pair counts and thresholds
      at the fixed large grid, superseding the 80x24 F7 and Phase 3 calibration
      numbers. Include terminal feed at 179x66: although it does not render,
      terminal construction, grid mutation, scrolling, damage tracking, and
      memory behavior depend on geometry. This is the first empirical task
      (rerunning the existing calibration machinery), not a new statistical
      design exercise.
- [x] Refreeze D3 and D4 from the 179x66 evidence. Only this freeze authorizes
      creation of a fresh held-out manifest.

### Phase 5 -- validate the canonical decision rule

- [x] Generate a new held-out manifest only after the 179x66 D3/D4 freeze,
      using fresh seeds disjoint from every calibration and superseded manifest.
      Never open or reuse an 80x24 held-out manifest.
- [x] Retire the 1,560-attempt held-out campaign as disproportionate to local
      engineering use. Preserve its partial opaque evidence without evaluating
      conditions or outcomes, and do not claim independent held-out
      certification.
- [ ] Optional future research: measure independent held-out error rates,
      symmetry, and drift robustness only if real benchmark use exposes a
      questionable decision or a publication-grade certification becomes
      valuable. Any such campaign needs a newly justified sample budget and
      fresh manifest; do not resume or selectively extend the retired one.
      **Still open as an option and still not taken, but the trigger condition
      has now partly fired and was answered another way.** Doc 8 exposed exactly
      the "questionable decision" this box anticipated -- `incremental-mixed`
      producing false verdicts -- and the resolution was not a certification
      campaign: `8/D2` routed that workload's draw comparisons to a different
      instrument entirely. Read doc 8 before spending anything here.

### Phase 6 -- Ghostty reference (severable). NOT BUILT.

This phase must not block graduation: Phases 1-4 can graduate to an
implementation plan and ship without a Ghostty baseline. **It did, and this
phase was never built.** Severability was exercised, not merely declared.

**Closed unbuilt 2026-07-28, with evidence that it is harder than it looks.**
`11/F3` attempted a DanTerm-vs-ghostty comparison on the existing harness and
found **the ghostty arm does not run at all**: the redraw workloads have no
ghostty code path, and on corpus workloads the pane's shell hangs in
`/usr/bin/login`. So the cross-backend baseline is not a matter of picking a
metric -- an arm has to be built first.

Note what this leaves unresolved. The 2x-CPU observation that opened docs 10 and
11 is **unattributed by both of them** -- feed was excluded by `10/F9`, draw by
doc 11's Outcome -- and this phase is the instrument that would have adjudicated
it. That is the strongest remaining argument for building it, and it is recorded
here rather than acted on because no scheduled work depends on the answer.

- [~] Enumerate observable timing seams in the pinned libghostty C API and
      DanTerm's Ghostty surface integration without guessing callback semantics;
      record viable boundaries in F10. **Not done; F10 is retired unpopulated.**
- [~] Run the same screen-sized synchronized-output fixture against both
      backends and compare producer throughput and backpressure at matched
      geometry; select the durable target metric in D6. **Not done; D6 is
      retired unpopulated.** Blocked in practice by the missing arm above.
- [~] If Ghostty exposes no validated completed-presentation signal,
      explicitly reject per-draw equivalence and retain throughput as the only
      cross-backend baseline. **Moot; never reached.**

### Phase 7 -- graduate and verify

- [x] Delete the old JSONL histories when their active readers and writers are
      replaced; do not archive or migrate measurements that cannot be compared
      across the method/schema boundary. Give the paired method a separate
      versioned history.
- [x] Audit behavioral coverage for fixture reset, exact completed draws,
      window geometry and occlusion guards, machine-state flags, paired
      reporting, profiling identity and history exclusion, and history
      compatibility -- plus the contracts Phases 2-3 establish empirically, so
      they cannot regress silently: source/binary identity (each suffixed bundle
      contains the intended snapshot), arm isolation, position-balanced schedule
      generation (every completed run is balanced), and the frozen decision rule
      against deterministic sample fixtures. Tests must assert observable
      contracts, not helper structure. **Discharged by the implementation, not
      by a separate audit pass**: the graduated plan
      (`plans/impl/2026-07-24-1423-fast-paired-performance-benchmarks.md`)
      carried the coverage with each of its three commits, and the suites live
      in `scripts/tests/`. `HarnessBuildContractTests` is the one worth naming
      -- it pins the harness's build flags against the harness source, because
      the runner duplicates those flags in Python and the two must not silently
      diverge.
- [x] Graduate the accepted runner and schema to
      `plans/wip/fast-paired-performance-benchmarks.md`; update
      `agent-docs/terminal-performance.md` as part of that implementation.
- [x] Close this research with measured old/new suite runtime, A/A error
      rate, known-change detection power, and the Ghostty baseline status.
      **Closed 2026-07-28.** Runtime, A/A error rate and detection power are in
      D1/D4 and the Outcome. **Ghostty baseline status: not built** -- Phase 6
      was severable and was severed; `11/F3` later found the ghostty arm does
      not run at all. See the Outcome's "How it held up in use", which is the
      part this box could not have anticipated: the runner's real verdict record
      is better evidence than any closing measurement would have been.

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

  | Workload      |     Median |         Min to max | Range relative to median |
  | ------------- | ---------: | -----------------: | -----------------------: |
  | Content churn | 305,240 ns | 279,228-322,761 ns |                    14.3% |
  | Style churn   | 302,798 ns | 295,431-316,530 ns |                     7.0% |
  | Mixed churn   | 307,196 ns | 286,339-319,536 ns |                    10.8% |

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
  components. Two unchanged content-churn series were therefore
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

  | Series | Draws per launch | Overall mean | Within-launch SD (CV) | Fresh-launch SD (CV) |  Launch-mean range |
  | ------ | ---------------: | -----------: | --------------------: | -------------------: | -----------------: |
  | 1      |              233 |   304,821 ns |     20,604 ns (6.76%) |     6,543 ns (2.15%) | 294,539-319,581 ns |
  | 2      |              226 |   308,124 ns |     21,053 ns (6.83%) |     6,642 ns (2.16%) | 297,607-320,219 ns |

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

### F4 -- stable suffixed benchmark bundles coexist with isolated runtime state

- Status: Complete for coexistence and immutable source/binary identity.
- Date and investigator: 2026-07-24, Codex.
- Prototype change: `terminal-benchmark.sh` now accepts only an empty
  `DANTERM_BENCHMARK_BUNDLE_SUFFIX`, `.a`, or `.b`, producing the stable
  identities `com.danneu.danterm-terminal-benchmark.a` and `.b`. Stability
  avoids a new macOS identity and first-launch policy state on every run.
  Arbitrary and PID-derived identities remain rejected. The existing
  no-suffix single-arm recipes retain their old identity.
- Live experiment: two optimized Swift-backend `scrollback-stream` loops ran
  concurrently as PIDs 66470 and 66898. A was allowed to finish its build,
  launch, and geometry convergence before B started. Both then remained alive
  while the isolation and focus probes ran.
- Filesystem and IPC evidence:

  | Arm | Bundle id                                 | Runtime root      | Control socket                                                                             |
  | --- | ----------------------------------------- | ----------------- | ------------------------------------------------------------------------------------------ |
  | A   | `com.danneu.danterm-terminal-benchmark.a` | `/tmp/dtb.ehTwdK` | `/tmp/dtb.ehTwdK/home/Library/Caches/com.danneu.danterm-terminal-benchmark.a/control.sock` |
  | B   | `com.danneu.danterm-terminal-benchmark.b` | `/tmp/dtb.aYaFMU` | `/tmp/dtb.aYaFMU/home/Library/Caches/com.danneu.danterm-terminal-benchmark.b/control.sock` |

  Each path probe also placed Application Support, config, recovery, replay,
  and temporary data under its arm's runtime root. `lsof` showed each process
  listening only on its own socket. The roots were removed by owned-process
  teardown; the probes remain in
  `.build/terminal-benchmark-runs/2026-07-24-001340-66307/artifacts` and
  `.build/terminal-benchmark-runs/2026-07-24-001355-66719/artifacts`.

- Shared-state collision probe: both IPC models began with one tab. Creating
  an `A-ISOLATION-PROBE` tab through A's helper and socket changed A from one
  tab to two while B remained at one. This proves the suffix/home/socket
  combination routes commands to independent in-memory models rather than a
  shared application instance or socket.
- Focus probe: asking System Events to front A made PID 66470 frontmost; asking
  it to front B made PID 66898 frontmost. Neither activation selected the
  other process. The eventual paired runner must address arms by recorded PID
  (not the shared display name `DanTerm Benchmark`) and re-check frontmost PID
  at each measured block boundary.
- Notification scope: benchmark builds compile out notification-center
  delegate registration, authorization, app activation, and notification
  delivery. Measured A/B runs therefore have no notification path capable of
  crossing arms. This experiment does not claim that two production builds
  can independently exercise notifications; that behavior is outside the
  benchmark runner's contract.
- Required isolation: suffixing alone is insufficient because Foundation
  user-domain paths also depend on the process home. Each arm must retain its
  own `HOME`, `CFFIXED_USER_HOME`, explicit temporary root, app bundle, owned
  PID, identity artifact, and CLI `DANTERM_SOCK`. The runner must validate all
  probed paths before sending workload input.
- Launch ordering: bundle assembly and launch may be A then B or B then A for
  position balancing. The final paired runner must build each immutable source
  snapshot once in its own SwiftPM build directory, then assemble both bundles
  before either launch. This removes concurrent or stale cache writes from the
  arm comparison; measured block order remains independently counterbalanced.
- Limitation discovered: a first coexistence attempt with
  `full-screen-content-churn` reached the isolated path probe but timed out
  waiting for its geometry acknowledgment before B launched. The established
  scrollback loop then passed. This is not evidence against coexistence, but
  the persistent-block task must close the full-screen loop startup failure
  before render workloads can use the paired runner.
- Verification: the focused shell contract test passes and rejects loss of
  the suffix hook or a return to PID-derived identities. A live invalid
  `.invalid` suffix exited with status 2 before building or launching.
- Immutable snapshot strategy:
  - Resolve HEAD and any named revision before doing other work, recording
    both its commit id and tree id. Export that tree with `git archive`; never
    build in the caller's checkout or a mutable worktree.
  - Snapshot a dirty working tree through a temporary Git index initialized
    from HEAD, followed by `git add -A` and `git write-tree`. This includes
    tracked edits and every non-ignored untracked file while leaving the real
    index unchanged. Record the base commit plus the resulting tree id and
    export that tree exactly as for a clean revision. The caller must be shown
    the captured path list because unrelated non-ignored files are part of the
    identity too.
  - Copy the ignored build prerequisites into each exported source tree before
    building. Record and require their content digests; this experiment used
    GhosttyKit digest
    `bc9ce46674bc53a400aa1f652344b9ab479b3ccd809ef207609a81c5522ed532`
    and theme digest
    `ae2d21d22ce732bf9cd3ee1df70184a707d474eb97a1b07384259a02f714019f`.
    All three copies matched.
  - Give each snapshot a disjoint source directory, SwiftPM build directory,
    bundle directory, and runtime root. Build all arms before launch. A
    source manifest is immutable once building begins; a post-build tree-id
    recheck or changed manifest is a hard failure.
  - Copy only from that arm's recorded bin path into its suffixed bundle.
    Before signing, require byte-for-byte equality and record SHA-256 plus the
    Mach-O UUID for the build output and bundle executable. After signing,
    record the signed executable hash and retain the UUID so the launch
    identity can name the exact on-disk binary.
- Snapshot validation: three independent optimized builds completed from HEAD
  commit `515e6c6`, the named branch expression
  `experiment/swift-terminal-engine~1` at `eb95e13`, and the then-current dirty
  working tree. Their source tree ids were respectively `bd5fc24e`,
  `fc0b0535`, and `95c5fe34`; the dirty snapshot was based on `515e6c6` and
  captured the five modified and three non-ignored untracked paths reported by
  `git diff-tree`.
- Binary proof: the HEAD, named-revision, and dirty executables had distinct
  SHA-256 values `a648a2d3...`, `b76e179c...`, and `f4eea4c4...`, and Mach-O
  UUIDs `10CD4202...`, `5FAAC2E2...`, and `3CE6D51F...`. Each copied bundle
  executable passed `cmp` against only its arm's build output and repeated the
  same SHA-256. The HEAD and dirty bundles used suffix `.a`; the named-revision
  bundle used `.b`, demonstrating that source identity is independent of the
  reusable A/B runtime position.
- Artifacts: source identities, full build logs, disjoint exported sources,
  build products, test bundles, hashes, and UUIDs are under
  `.build/terminal-benchmark-snapshot-validation/2026-07-24/`; the concise
  proof is `validation-manifest.txt`.
- Decision: adopt Git tree objects as the canonical source identity and
  content hashes plus Mach-O UUIDs as the binary-to-bundle chain of custody.
  Do not use a patch filename, `git describe --dirty`, a shared checkout, or a
  shared SwiftPM build directory as an arm identity.
- Next action: collect the persistent paired pilot and select block duration
  and candidate N values in F7.

### F5 -- repeated redraw blocks complete inside one persistent process

- Status: Two-block redraw prototype proven; the production paired controller
  and workload-specific reset implementations remain to build.
- Date and investigator: 2026-07-24, Codex.
- Timeout diagnosis: F4's failed full-screen launch omitted
  `DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES`. A redraw workload name is a
  generator selection, not by itself a loop fixture; without a positive
  update count the producer cannot enter the redraw protocol. With five
  updates configured, geometry convergence and the first block completed
  normally. The failure was invocation error, not a persistent-window
  geometry defect.
- Method: one optimized `.a` Swift-backend app remained alive as PID 72500.
  It converged once to 80x24, then ran two five-draw
  `full-screen-content-churn` blocks in the same pane. Between blocks, all
  acknowledgment and result files were removed outside timing and the
  producer was invoked again in the settled shell. Temporary observer
  instrumentation allowed a completed marker sequence to reopen for the next
  start marker and cleared its sequence, duration, damage, and completion
  bookkeeping. That instrumentation was removed after collection; these
  results validate the state transition the permanent controller must
  implement rather than silently adding an unfinished runner.
- Reset boundary: the first producer's completion payload restores default
  style, restores the scroll region, leaves the alternate screen, and writes
  the expected final-state and completion fences. The next invocation waits
  for the unchanged 80x24 PTY geometry, writes a full deterministic setup
  screen, waits for both start-marker observation and the completed setup
  draw, writes and acknowledges the excluded settling frame, and only then
  starts its clock. Thus shell entry, geometry confirmation, terminal setup,
  initial invalidation, and settling are outside the measured block.
- Results:

  | Check                            |                           Block 1 |                           Block 2 |
  | -------------------------------- | --------------------------------: | --------------------------------: |
  | App PID                          |                             72500 |                             72500 |
  | Geometry                         |                             80x24 |                             80x24 |
  | Completed draws                  |                                 5 |                                 5 |
  | Dirty rows per draw              |                24, 24, 24, 24, 24 |                24, 24, 24, 24, 24 |
  | Expected final state             | `DANTERM-BENCH-FINAL-STATE-72128` | `DANTERM-BENCH-FINAL-STATE-72128` |
  | Producer interval                |                     39,255,500 ns |                     45,321,125 ns |
  | Parse-to-final-draw interval     |                     53,385,666 ns |                     61,125,917 ns |
  | Cumulative synchronous draw time |                      1,385,541 ns |                      1,337,792 ns |

  The cumulative draw totals differ by 3.45%; two blocks are a protocol proof,
  not a variance or carryover conclusion.

- Completeness evidence:
  - Terminal state: both blocks reached the same completion frame containing
    the same expected final-state fence after the completion reset sequence.
  - Draw count: both recorded exactly five unique measured sequences, so no
    setup, settling, duplicate, or coalesced draw entered the count.
  - Damage: every measured content-churn draw covered exactly all 24 rows, as
    required for this fixture.
  - Acknowledgments: each producer alternated one sequence write with the
    matching completed-draw acknowledgment; block completion waited for the
    app-side final-draw result. The second block could not reuse stale files
    because all block-1 acknowledgments were removed before invocation.
- Artifacts:
  `.build/terminal-benchmark-runs/2026-07-24-002459-72128/artifacts`
  contains `block-1-final-draw.json`, `block-1-producer.json`,
  `block-2-final-draw.json`, and `block-2-producer.json`, plus the ordinary
  harness diagnostics. The isolated runtime root was removed at teardown.
- Constraints for the permanent runner:
  - Give every block a monotonic block id and block-scoped acknowledgment and
    result paths. Deleting/reusing paths was adequate for this controlled
    prototype but is too vulnerable to stale or late events for decisions.
  - Make the observer's block transition explicit and accept a start only
    after the prior block's completion fence; reject duplicate, skipped, and
    out-of-order sequence ids.
  - Define reset completeness per workload. The redraw reset above restores
    visible terminal/render state, but it deliberately does not prove that
    scrollback retention, parser/session objects, glyph caches, allocator
    state, or steady-state caches are cold. Session and core-feed workloads
    need their own reset contracts, and H2 still requires position/carryover
    analysis plus fresh-launch spot checks.
  - Preserve steady-state caches unless a workload's user-facing question
    specifically requires cold behavior. Record which state is reset and
    which is intentionally persistent rather than calling every surviving
    cache contamination.
- Next action: implement block-scoped protocol ids as part of the paired
  controller, then add machine-state capture and per-block occlusion
  invalidation before collecting A/A data.

### F5a -- machine-state capture and per-block invalidation are proven

- Status: Complete.
- Date and investigator: 2026-07-24, Codex.
- Prototype:
  - The benchmark app samples `ProcessInfo.thermalState`, low-power mode,
    AppKit occlusion, and the window server's
    onscreen flag at block start and completion. It also records thermal,
    occlusion, active-Space, and per-draw visibility changes during the
    block.
  - `terminal-benchmark-state.py` converts all samples into stable
    invalidation reasons without silently deleting the measured result.
    Thermal pressure, low-power mode, occlusion, and an
    active-Space transition each invalidate the block.
  - State samples are atomically checkpointed as they occur. This is required
    because an off-Space window can stop drawing before it publishes a final
    draw. The harness watches that checkpoint and emits an explicit
    `block-invalidated` result with unavailable timing fields instead of
    timing out or accepting a partial measurement.
  - Benchmark apps now activate at launch, matching the design requirement
    that the measured arm be frontmost.
- TDD evidence: four validator tests cover a nominal block, a Space-change
  event that returns visible before completion, a thermal-pressure sample,
  and a low-power-mode flag. The tests failed first because the validator
  did not exist, then passed with the implementation.
- Thermal demonstration: run
  `2026-07-24-003554-77781` used the explicit test-only override
  `DANTERM_BENCHMARK_THERMAL_STATE_OVERRIDE=serious`. Both start and
  completion samples recorded low-power mode off, visibility true,
  and thermal state `serious`; `blockState` was invalid with reason
  `thermal-pressure-serious`. The override induces no heat and is preserved
  in the raw samples rather than masquerading as a physical event.
- Space demonstration: during run `2026-07-24-011240-1548`, a physical
  Control-Arrow Space switch produced an `active-space-change` sample. The
  harness immediately emitted `block-invalidated`; `blockState` was invalid
  with reason `active-space-changed`, and producer and final-draw timing were
  unavailable. The start and transition samples both recorded
  low-power mode off and nominal thermal state, isolating the Space
  transition as the invalidation cause.
- Space attempt: Desktop 1 and Desktop 2 were selected through Mission
  Control during four separate 500-draw blocks, with Desktop 1 restored after
  each attempt. The final attempt was
  `2026-07-24-004223-82249`. On this display/Space configuration macOS
  reported the benchmark window visible and onscreen for the whole block and
  delivered neither an AppKit occlusion transition nor
  `NSWorkspace.activeSpaceDidChangeNotification`; the block therefore
  remained valid. Treating the automation action itself as proof would make
  the guard circular, so this does not satisfy the required demonstration.
- Follow-up diagnosis: the Mission Control Spaces bar was initially collapsed,
  so its Desktop buttons reported off-screen bounds and accessibility presses
  did not change the active Space. Expanding the bar exposed the thumbnails,
  but both accessibility presses and authorized CoreGraphics mouse events
  still left the window server's current managed-Space id unchanged. One
  synchronized attempt did stop redraw acknowledgments, which exposed and led
  to the immediate-checkpoint fix above, but it did not produce independent
  proof that the managed Space changed and therefore is not counted as the
  required demonstration.
- Implementation correction found during the attempt: the harness initially
  forwarded an empty thermal override, which became an empty thermal state
  and invalidated a nominal block. Empty now means no override.
- Next action: compare A/A noise with both apps alive versus one app alive
  (H3), record the result in F6, and select coexistence or sequential
  alternation.

### F6 -- an idle coexisting arm does not widen A/A paired noise

- Status: Complete for the Phase 2 mode selection. This is a pilot comparison,
  not a claim that the two modes are statistically equivalent.
- Date and investigator: 2026-07-24, Codex.
- Method: the same optimized Swift binary ran 20 valid 100-draw
  `full-screen-content-churn` blocks under each condition. Adjacent blocks
  formed 10 A/A pairs. The single-app condition launched only the measured
  `.a` bundle for each block. In the coexistence condition, an isolated `.b`
  `scrollback-stream` app remained alive in sustained mode while the same
  `.a` blocks ran frontmost. Every measured block completed exactly 100 draws
  without a machine-state or visibility invalidation.
- Metric: per-block cumulative synchronous draw time divided by its fixed draw
  count. Pair differences use the symmetric percentage
  `200 * (second - first) / (second + first)`. H3's rejection criterion is
  widening of this paired-difference distribution, so the primary summaries
  are its sample SD and median absolute difference.
- Results:

  | Condition                | Blocks / pairs | Block CV | Paired-difference SD | Median absolute paired difference |
  | ------------------------ | -------------: | -------: | -------------------: | --------------------------------: |
  | One app alive            |        20 / 10 |   1.609% |               1.755% |                            1.485% |
  | Idle `.b` app also alive |        20 / 10 |   1.296% |               1.480% |                            0.898% |

  The coexistence-to-single paired-SD ratio is 0.844. A deterministic
  100,000-resample pair bootstrap gives a wide 95% percentile interval of
  0.396-1.478. The point estimate therefore shows no widening, but the pilot
  is too small to establish a tight equivalence bound.

- Raw symmetric pair differences:
  - One app alive: -1.597%, -0.105%, -3.518%, -2.250%, 1.618%, 0.732%,
    0.164%, 1.373%, 0.124%, -2.483%.
  - Idle `.b` app also alive: -0.533%, -0.203%, 1.040%, -0.408%, -4.059%,
    -2.480%, -2.757%, -1.005%, -0.791%, -0.751%.
- Absolute timing caveat: median block time was 27,272,586.5 ns in the
  single-app series and 28,553,754 ns in the coexistence series. Because all
  single-app blocks preceded all coexistence blocks, this 4.70% level shift
  aliases time drift with any resident-app cost and is not a causal overhead
  estimate. It does not widen the within-condition A/A difference used by
  H3, but the final counterbalanced paired controller must revisit absolute
  level and scheduler placement.
- Artifacts: the single-app blocks are
  `2026-07-24-011417-2602` through `2026-07-24-011553-7885`; the sustained
  idle app is `2026-07-24-011607-8196`; coexistence blocks are
  `2026-07-24-011632-8780` through `2026-07-24-011805-14064`, all under
  `.build/terminal-benchmark-runs/`.
- Decision: select persistent coexistence for the prototype. The observed
  paired noise did not meet H3's rejection condition, while sequential
  alternation would knowingly reintroduce launch cost and process-level
  variance. Retain sequential alternation as the fallback if the
  counterbalanced F7 pilot or canonical held-out Phase 5 validation reveals
  coexistence-dependent noise.
- Next action: validate immutable baseline/candidate source and binary
  snapshot identity, completing the remaining F4 task.

### F7 -- persistent paired pilot selects 50-draw blocks and candidate pair counts

- Status: Pilot, repetition sizing, wall-time decomposition, and sustained
  profiling proof complete.
- Date and investigator: 2026-07-24, Codex.
- Prototype: the harness now has a `persistent` mode that launches, converges,
  and publishes an exact PID without starting a measured block. After each
  untimed reset, removing the previous result and start acknowledgment lets
  the observer reopen its block-local timing, draw-sequence, damage, and
  machine-state bookkeeping. Both suffixed A/A apps therefore stayed alive
  while the controller alternated their frontmost blocks. The measured
  producer invocation explicitly switches back to `measure` mode.
- Schedule and validity: the block-length pilot collected 48 valid blocks,
  16 each at 25, 50, and 100 serialized full-screen content draws. Each
  length used four position-balanced `ABBA`/`BAAB` quartets. A second
  32-block series at 50 draws (16 adjacent A/A pairs, eight balanced
  quartets) retained all 1,600 per-draw durations for the nested
  decomposition. Every block remained visible, on the active Space, on AC
  power, in nominal thermal state, and out of low-power mode.
- Block-length comparison:

  | Draws per block | Median cumulative draw work | Median producer block | Block-mean CV | Paired-difference SD |
  | --------------: | --------------------------: | --------------------: | ------------: | -------------------: |
  |              25 |                     7.30 ms |             208.65 ms |         2.43% |                2.37% |
  |              50 |                    15.11 ms |             419.99 ms |         2.07% |                2.29% |
  |             100 |                    30.46 ms |             848.63 ms |         2.25% |                2.53% |

  Producer block time includes the serialized write/draw acknowledgment
  round trips; cumulative synchronous AppKit draw work is the comparison
  metric. Doubling from 50 to 100 draws doubled wall time without reducing
  block or paired noise. Twenty-five draws was faster but had the widest
  block-mean distribution. Select 50 draws, approximately 420 ms of measured
  producer time and 15 ms of synchronous draw work on this machine.

- Kalibera-Jones decomposition: a balanced nested random-effects ANOVA on the
  second series used draws within blocks within persistent processes.
  Relative to the 301,164 ns grand mean, the within-block draw component was
  20,227 ns SD (6.72% CV), and the between-block component after subtracting
  `within / 50` was 3,639 ns SD (1.21% CV). The two process means were
  300,825 and 301,503 ns, a symmetric difference of 0.225%; subtracting
  lower-level contributions truncated the process component to zero.
  Two processes provide only one process-level degree of freedom, so zero is
  orientation, not evidence that process variance is absent.
- Paired level: the 16 label-oriented symmetric A/A differences had mean
  0.229%, SD 2.475%, and median absolute difference 1.317%. The near-zero
  mean after position balancing is consistent with the null. The paired SD,
  rather than F3's fresh-launch CV, is the repetition-sizing input.
- Candidate repetition counts: under a normal approximation, the pilot SD
  requires 4 pairs for a 2.5 percentage-point 95% half-width, 11 for 1.5
  points, or 24 for 1 point. Carry forward 8 pairs for `quick`: it exceeds
  the arithmetic minimum for resolving D1's 5% effect and preserves two full
  balanced quartets. Carry forward 24 pairs for `confirm`: its approximate
  1-point half-width is appropriately narrower than D1's 3% effect. These
  are calibration candidates, not validated decision counts; Phase 3 may
  reject them based on false-positive, inconclusive, or detection-power
  rates, but may not tune them on the held-out trials.
- Supersession: these persistent paired estimates replace F3's
  fresh-launch orientation for block duration and candidate N. They apply to
  the serialized screen-sized content redraw question; the final runner must
  verify that other ladder workloads do not require a longer block.
- Artifacts: raw block results are
  `.build/terminal-benchmark-f7-pilot/2026-07-24/blocks.jsonl` and
  `blocks-50-raw.jsonl`. The latter preserves every per-draw duration,
  dirty-row count, machine-state sample, arm PID, schedule, producer timing,
  and final-draw timing.
- Quick wall time: after priming the exact optimized SwiftPM build directory,
  one complete cached-build run took 26.36 s for two persistent A/A arms, one
  untimed 50-draw warm-up block per arm, and 16 measured 50-draw blocks in the
  fixed `ABBABAABABBABAAB` schedule. All 16 measured blocks were valid, each
  completed exactly 50 draws, and every draw damaged all 24 rows. This uses
  44% of D4's candidate 60 s budget, leaving 33.64 s of headroom.
- Phase decomposition: an opt-in monotonic phase log in the harness measured
  5.87 s for cached build checks, 0.59 s for bundle assembly and ad-hoc
  signing, 3.02 s from process spawn to a CLI-addressable pane, 1.29 s for
  geometry convergence, 1.76 s for the untimed warm-up pair, 13.13 s for the
  measured blocks, and 0.39 s for owned teardown. These phases sum to 26.05 s;
  the remaining 0.31 s is controller startup, inter-arm orchestration, phase
  logging, and boundary handoff. Launch and convergence are deliberately
  separate: launch ends when the pane is addressable, while convergence ends
  when the producer has acknowledged the target geometry.
- Wall-time artifacts: the durable summary, raw measured blocks, per-arm phase
  events, identities, and harness logs are under
  `.build/terminal-benchmark-f7-wall/2026-07-24/`. The exact controller used
  for this prototype measurement is
  `.build/terminal-benchmark-f7-wall-controller.py`.
- Decision: retain D4's under-60-second `quick` candidate for Phase 3. This
  prototype demonstrates feasibility but does not freeze the final budget;
  D4 remains open until validated calibration and confirm-suite runtimes are
  available.
- Sustained profiling workload coverage:

  | D2 question               | Sustained target and reset boundary                                                                                                                                                                                    | Live proof                                     |
  | ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- |
  | Terminal feed             | Optimized `TerminalCoreBenchmark` repeatedly creates a fresh 80x24 `Terminal` and feeds the same deterministic composite of the four committed corpus streams. Rendering and PTY work remain absent.                   | `sample` attached to PID 43976.                |
  | Scrollback stream         | The isolated optimized app continuously replays the committed 25,000-line fixture after geometry convergence; the app/session and steady-state caches intentionally persist.                                           | `sample` attached to PID 41120.                |
  | Content churn             | The serialized redraw fixture performs its deterministic full-screen setup and excluded settling draw, then sustains exact draw-acknowledged content changes.                                                          | `sample` attached to PID 34896.                |
  | Style churn               | The matching setup/reset sustains exact draw-acknowledged style changes with fixed visible content.                                                                                                                    | `xctrace` Time Profiler attached to PID 35410. |
  | Incremental mixed updates | A dense deterministic setup and excluded settling draw precede content and RGB-style changes on rows 10-13 without a clear-screen operation. The renderer's required one-row glyph halo produces exact six-row damage. | `sample` attached to PID 47321.                |

  The prototype uses 80x24 because that is the geometry of the Phase 2
  measured-block implementation. It proves parity with those measured runs,
  not D2's eventual screen-sized geometry; the production runner must apply
  the same mechanism after its screen-sized geometry is implemented.

- Attachment and identity proof: `sample.txt` names the same numeric PID
  published by each identity. The exported xctrace table of contents names
  PID 35410 and the exact bundle executable path from its identity.
  Each app identity also records fixture and reset identity, achieved
  geometry, source commit/tree plus dirty-state digest, executable SHA-256,
  Mach-O UUID, and artifact root. The core identity records the equivalent
  pure-core boundary. `benchmark-loop` prints the same identity for an
  externally attached command-line tool.
- Preserved artifacts: every app profile directory contains the textual
  sample or `.trace` plus XML export, `profile-command.txt`, harness log,
  identity, copied symbol-bearing executable, `nm` output, and before/after
  history hashes. The content and style proofs are under
  `.build/terminal-benchmark-profiles/2026-07-24-014723-34684/` and
  `.build/terminal-benchmark-profiles/2026-07-24-014741-35205/`; incremental
  mixed and scrollback are under
  `.build/terminal-benchmark-profiles/2026-07-24-015821-47118/` and
  `.build/terminal-benchmark-profiles/2026-07-24-015211-40840/`. The core
  proof, composite fixture bytes, symbols, identity, command, and sample are
  under
  `.build/terminal-benchmark-f7-profile/2026-07-24/terminal-feed/`.
  A five-draw ordinary measured-path check is preserved at
  `.build/terminal-benchmark-runs/2026-07-24-015625-45507/artifacts/`; it
  recorded five acknowledgments and dirty-row counts `6, 6, 6, 6, 6`.
- Decision/history isolation: profile identities set `profilingActive: true`,
  `decisionEligible: false`, `historyEligible: false`, and
  `profiledTimingsAreDiagnosticOnly: true`. Each profiling command hashes
  committed history before and after and fails on any difference. An
  independent forced `save=1` suite invocation with
  `DANTERM_BENCHMARK_PROFILING=1` exited before building or prompting with
  `Profiled runs cannot enter benchmark history`; the history SHA-256
  remained
  `ccc14394b066231b3614966ed935537f23cbbf405eaf60414f9f8ba1bdd22ec3`.
  The harness now labels ordinary persistent paired arms
  `profilingActive: false`, correcting the earlier prototype identity that
  unconditionally said true. Paired decisions therefore cannot consume a
  profile identity without violating both flags.
- Follow-up completed in F9: Phase 4 moved every workload to 179x66 and
  refroze D3/D4 before any held-out validation trial was generated or exposed.

### F8 -- 80x24 calibration develops the fixed-N decision rule

- Status: Complete historical calibration. D5 superseded these 80x24 rules
  before any held-out evidence was opened; F9 contains the frozen 179x66
  replacement.
- Date and investigator: 2026-07-24, Codex.
- Live calibration source: a new calibration-only A/A run collected 96 valid
  50-draw content-churn blocks in 92.44 seconds. The fixed
  `ABBABAAB` schedule repeated 12 times, producing 48 adjacent A/B pairs in
  24 complete position-balanced quartets. Both optimized app arms stayed
  persistent. Every block completed exactly 50 draws, passed the AC,
  thermal, low-power, visibility, and active-Space checks, and retained all
  raw draw durations. No held-out trial was generated or read.
- Observed A/A noise: the 48 label-oriented symmetric paired differences had
  mean -0.746%, median -0.980%, SD 2.922%, and range -6.556% to +5.798%.
  The nonzero physical-arm tendency is large enough to matter at D1's
  effects. D3 therefore counterbalances source-to-`.a`/`.b` assignment
  across complete trials in addition to counterbalancing block order within
  each trial.
- Injected calibration method: 100,000 trials per A/A and effect condition
  resampled whole two-pair schedule quartets with replacement, preserving
  measured within-quartet dependence. Alternating trials reversed every
  paired difference to model the frozen source-to-physical-arm assignment.
  Known changes scaled the candidate side of each measured ratio by exactly
  +5%/-5% for `quick` and +3%/-3% for `confirm`, then recomputed the
  symmetric paired percentage. This is empirical deterministic timing
  injection over live noise, not claimed independent validation. The later
  held-out trials remain the only pass/fail evidence for D1.
- Content-churn-only candidate grid result:

  | Mode      | Pairs | Directional threshold | Equivalence band |                              A/A false positive | Positive power / inconclusive | Negative power / inconclusive | Wrong direction |
  | --------- | ----: | --------------------: | ---------------: | ----------------------------------------------: | ----------------------------: | ----------------------------: | --------------: |
  | `quick`   |     8 |                 2.75% |            1.00% |                                          3.811% |              92.261% / 7.387% |              94.782% / 5.218% |              0% |
  | `confirm` |    80 |                 1.75% |            0.75% | 0.640% per workload; <=3.200% suite union bound |              90.336% / 9.663% |              96.019% / 3.980% |              0% |

  Both rows clear D1's calibration targets. The earlier 24-pair confirm
  candidate failed: at a 1.75% threshold it produced about 7% A/A false
  positives and less than 90% power in one direction after physical-arm
  balancing. A 48-pair candidate cleared the per-workload targets but its
  2.3% per-workload false-positive rate could not control five simultaneous
  decisions. Increasing to 80 pairs is the smallest tested fixed count whose
  conservative five-workload union bound stays below 5% while both injected
  directions retain at least 90% power and at most 10% inconclusive results.
  This table is retained as superseded calibration history; the five-workload
  result below owns D3.

- Content-churn analysis: each block contributes cumulative synchronous draw
  time divided by its exact draw count. Each adjacent A/B pair becomes
  `200 * (candidate - baseline) / (candidate + baseline)`. The trial
  estimate is the median of all fixed-N pair differences. Estimates at or
  beyond the directional threshold are faster/slower; estimates inside the
  closed equivalence band are equivalent; the gap is inconclusive.
- Outlier policy: detect values whose median-absolute-deviation score exceeds
  3.5, record their indices and raw values, and delete none. The decision
  always uses all valid fixed-N pairs. A machine-state-invalid block
  invalidates the trial and consumes the next predeclared replacement seed;
  it is not a statistical outlier.
- Reproducibility: implementation and behavioral tests are
  `scripts/terminal-benchmark-calibration.py` and
  `scripts/tests/terminal_benchmark_calibration_test.py`. Raw blocks,
  controller, collection summary, identities, logs, and the complete
  100,000-trial report are under
  `.build/terminal-benchmark-phase3-calibration/2026-07-24/`.
- Held-out opening audit: no held-out result has been collected or inspected.
  The predeclared manifest at
  `.build/terminal-benchmark-phase3-validation/2026-07-24/manifest.json`
  contains 1,560 unique trials from seed `2026072402`: 900 `quick` trials and
  660 `confirm` suite trials, with source-to-physical-arm assignment balanced
  within every cell. That schema 1 manifest is now obsolete and remains
  unopened. `scripts/terminal-benchmark-validation.py` generates its eventual
  replacement only after a new seed is supplied and rejects incomplete result
  sets, changed trial identities, and calibration-seed reuse; its behavioral
  tests are in `scripts/tests/terminal_benchmark_validation_test.py`.
- First blocker discovered before opening held-out evidence: D3 initially
  defined every block as 50 completed draws, but D2's pure `Terminal.feed`
  workload deliberately has no rendering, and the PTY/scrollback workload
  measures a different app/session boundary. Moreover, calibration measured
  only content churn. The five-workload held-out cells therefore did not yet
  have calibrated block units or evidence that content-churn N and thresholds
  controlled their error rates. Applying the content-churn rule to them would
  have violated D1's per-workload requirement rather than validated it.
- Workload-specific block contract, defined before further evidence:

  | Workload          | Timed block and normalization                                                                                                                            | Reset boundary                                                                                                                                                               |
  | ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
  | Terminal feed     | One duration-stable fixed-execution batch lasting at least 1 second; report cumulative `Terminal.feed` nanoseconds divided by the fixed execution count. | Construct a fresh terminal at the canonical grid before every execution; corpus framing and chunks remain fixed; batch-count calibration stays outside reported samples.     |
  | Scrollback stream | One complete replay of the fixed 25,000-line fixture; report start-marker parse through the completed draw containing the expected final state.          | Launch a fresh optimized app and terminal session for every block, converge geometry, and settle before the start marker. Teardown follows completion and is outside timing. |
  | Content churn     | 50 serialized exact completed draws; report cumulative synchronous draw nanoseconds divided by 50.                                                       | Settle the dense screen before the block; acknowledge every sequence only after its matching draw completes.                                                                 |
  | Style churn       | 50 serialized exact completed draws; report cumulative synchronous draw nanoseconds divided by 50.                                                       | Same settled-screen and exact-acknowledgment boundary as content churn.                                                                                                      |
  | Incremental mixed | 50 serialized exact completed draws; report cumulative synchronous draw nanoseconds divided by 50.                                                       | Settle the dense screen before the block; require every draw's damage to match the deterministic changed-row subset.                                                         |

  Setup, reset, settling, focus changes, arm switches, and teardown remain
  outside timing for every workload. A paired comparison may combine only
  blocks with the same workload contract and fixed fixture identity.
  `scripts/terminal-benchmark-validation.py` now emits these contracts in
  schema 2 manifests, with behavioral coverage in its test file. The old
  schema 1 held-out manifest is obsolete and must remain unopened.

- Canonical-geometry blocker discovered after the calibration method froze:
  all live series in this finding used 80x24, while D5 now selects 179x66.
  The evidence below remains useful for runner and statistical-method
  development, but none of its pair counts, thresholds, damage-row
  assertions, runtime projections, or held-out manifests is final. Phase 4
  must reproduce 179x66, rerun the workload series, and refreeze D3/D4 before
  held-out collection begins.
- Terminal-feed contract pilot: one release `TerminalCoreBenchmark` process
  calibrated the fixed execution count once, then collected 32 sequential
  duration-stable A/A blocks under four repetitions of `ABBABAAB`. All blocks
  used the same four-execution batch, constructed a fresh 80x24 terminal for
  every execution, and exceeded the one-second duration floor; the shortest
  raw batch was 1.270 seconds. The 16 label-oriented symmetric paired
  differences had mean -0.181%, median -0.165%, SD 0.541%, and range -1.473%
  to +0.819%. AC power was confirmed after collection; `pmset` could not
  report thermal or CPU power warning levels, so this remains sizing evidence
  rather than a valid held-out trial. Raw measurements and the derived summary
  are under
  `.build/terminal-benchmark-phase3-feed-pilot/2026-07-24/`.
- Scrollback contract pilot: 32 independent optimized app/session launches
  collected four `ABBABAAB` schedules, for 16 adjacent A/A pairs. Each block
  replayed the fixed 25,000-line fixture and reported start-marker parse
  through the completed final draw. All blocks were valid: both machine-state
  samples reported nominal thermal state, low-power mode off, a visible
  window, and no active-Space change. Median final-draw time was 304.854 ms.
  The label-oriented symmetric paired differences had mean -0.326%, median
  -0.442%, SD 1.439%, and range -2.379% to +2.180%. Collection took 183.553
  seconds wall time, confirming that fresh app assembly, launch, convergence,
  and teardown dominate this block contract despite remaining outside its
  measured interval. Raw blocks, per-launch phase logs, and the derived
  summary are under
  `.build/terminal-benchmark-phase3-scrollback-pilot/2026-07-24/`.
- Harness correction found by the pilot: two excluded warm-ups converged
  geometry but timed out before the start-marker acknowledgment because the
  freshly launched app was not frontmost. Manually fronting the exact owned
  PID made the next excluded warm-up valid; the harness now performs that
  ownership-scoped focus step during untimed setup. A subsequent ordinary
  fresh launch passed without intervention before measured collection began.
- Style-churn calibration series: a new calibration-only A/A run collected
  96 valid 50-draw blocks in 92.31 seconds under 12 repetitions of
  `ABBABAAB`, yielding 48 adjacent pairs in 24 complete position-balanced
  quartets. Every block completed exactly 50 draws with 24 dirty rows per
  draw and passed both machine-state samples. The label-oriented symmetric
  paired differences had mean +0.354%, median +0.133%, SD 3.017%, and range
  -7.793% to +6.435%. Per-draw block means ranged from 287.730 us to
  318.772 us, with a 302.637 us median. AC power was confirmed before and
  after collection. Raw blocks, controller, identities, logs, and collection
  summary are under
  `.build/terminal-benchmark-phase3-style-calibration/2026-07-24/`.
- Incremental-mixed calibration series: a new calibration-only A/A run
  collected 96 valid 50-draw blocks in 91.87 seconds under the same
  12-repetition `ABBABAAB` schedule, again yielding 48 pairs in 24 complete
  position-balanced quartets. Every block completed exactly 50 draws, every
  draw reported the required six dirty rows, and both machine-state samples
  passed. The label-oriented symmetric paired differences had mean -0.024%,
  median +0.518%, SD 4.928%, and range -13.554% to +9.901%. Per-draw block
  means ranged from 116.639 us to 142.858 us, with a 125.130 us median. AC
  power was confirmed before and after collection. Raw blocks, controller,
  identities, logs, and collection summary are under
  `.build/terminal-benchmark-phase3-incremental-calibration/2026-07-24/`.
- Five-workload calibration result: deterministic empirical resampling used
  all five workload-specific noise series, 100,000 trials per A/A and
  injected-effect condition, whole balanced-schedule quartets, and alternating
  physical-arm mappings. `quick` freezes at 12 pairs, a 3.25% directional
  threshold, and the retained +/-1.00% equivalence band. Its worst
  per-workload A/A false-positive rate was 4.010%, worst injected detection
  power was 81.457%, worst nondirectional rate was 18.543%, and
  wrong-direction rate was 0%. `confirm` freezes at 240 pairs, a 1.50%
  directional threshold, and the retained +/-0.75% equivalence band. Its
  conservative five-workload A/A union bound was 4.540%, worst injected
  detection power was 97.637%, worst nondirectional rate was 2.363%, and
  wrong-direction rate was 0%. Both rules clear D1's calibration targets.
  Incremental mixed was limiting in both modes. The per-workload rates,
  seeds, and suite summaries are preserved in
  `.build/terminal-benchmark-phase3-cross-workload-calibration/2026-07-24/report.json`.
- Calibration correction: D1 defines an injected result that makes neither
  directional decision as inconclusive. The first analyzer counted only the
  explicit gap classification and omitted estimates inside the equivalence
  band. A behavioral regression test now requires both classifications in
  the injected nondirectional rate; the five-workload results above use the
  corrected definition.
- Operational blocker: the statistically valid common `confirm` rule requires
  480 measured blocks per workload. In particular, its fresh-app scrollback
  blocks make the complete suite incompatible with D4's intended routine
  benchmark role before any 60-trial held-out validation campaign is
  attempted. No new held-out manifest is generated while this blocker is
  open.
- Calibrated-rule wall-time projection: proportional extrapolation from each
  workload's live collection gives the following end-to-end estimates. Feed
  uses the 40.928 seconds of measured batch time in its 32-block pilot and is
  therefore a lower bound because its pilot did not record process setup.
  Scrollback uses its complete 183.553-second controller wall time. The draw
  workloads use their complete 96-block controller wall times, including
  two persistent launches, warm-ups, and teardown. Proportional scaling is
  deliberately simple; it slightly overcharges fixed draw setup at high N
  and undercharges it at low N.

  | Workload                     | 12-pair `quick` | 240-pair `confirm` |
  | ---------------------------- | --------------: | -----------------: |
  | Terminal feed                |       >=30.70 s |         >=613.92 s |
  | Scrollback stream            |        137.66 s |         2,753.29 s |
  | Content churn                |         23.11 s |           462.21 s |
  | Style churn                  |         23.08 s |           461.55 s |
  | Incremental mixed            |         22.97 s |           459.34 s |
  | Complete five-workload suite |      >=237.52 s |       >=4,750.31 s |

  Thus the common rule misses the candidate budget in both forms that matter:
  one scrollback `quick` comparison takes about 2.3 minutes rather than under
  60 seconds, and the complete `confirm` suite takes about 79.2 minutes rather
  than under 5 minutes. The estimates are sufficient to reject the design;
  spending that time on a live common-N run would not change the decision.

- New calibration design, selected before collecting more evidence: retain
  each workload's fixed block contract, median symmetric paired estimator,
  complete-quartet resampling, physical-arm reversal, equivalence semantics,
  and no-peeking rule, but choose a separate fixed pair count and directional
  threshold for each workload. `Quick` continues to control false positives
  per workload. `Confirm` controls the five simultaneous decisions with a
  conservative sum of workload-specific A/A false-positive rates no greater
  than 5%; every workload must independently retain D1's detection,
  nondirectional, and wrong-direction targets. Candidate pair counts remain
  positive multiples of two so every decision contains complete schedule
  quartets. This prevents quiet terminal-feed and scrollback series from
  inheriting the count required by incremental mixed. It is a new calibration
  cycle, not post-hoc interpretation of the common-N result.
- Workload-specific screen: deterministic 5,000-trial grid cells selected the
  lowest tested complete-quartet count that cleared every per-workload target.
  The limiting incremental-mixed confirm boundary was then refined with
  20,000-trial cells at thresholds from 1.55% through 1.70%; its empirical
  median distribution changes sharply across that narrow interval, so these
  remain screening estimates rather than a frozen result.

  | Mode                        |      Feed | Scrollback |    Content |      Style | Incremental |
  | --------------------------- | --------: | ---------: | ---------: | ---------: | ----------: |
  | `quick` pairs / threshold   | 2 / 2.50% |  2 / 2.50% |  4 / 3.25% |  4 / 3.25% |  12 / 3.25% |
  | `confirm` pairs / threshold | 2 / 1.00% | 12 / 1.75% | 80 / 1.75% | 24 / 2.00% | 100 / 1.60% |

  Quick screening false-positive rates were 0%, 0%, 4.020%, 3.560%, and
  3.880% in table order; worst directional detection was 80.88% and worst
  nondirectional rate was 19.12%. Confirm screening false-positive rates were
  0%, 0.240%, 0.580%, 0.940%, and 1.895%, for a conservative 3.655% sum.
  Worst confirm directional detection was 90.02% and worst nondirectional
  rate was 9.98%. No screened cell made a wrong-direction decision above
  D1's limit.

- Screened-rule runtime projection: the workload-specific quick suite is
  about 66 seconds total, and every individual quick comparison is under 23
  seconds before feed setup. The confirm suite is about 534 seconds (8.9
  minutes): approximately 5 seconds feed, 138 seconds scrollback, 154 seconds
  content, 46 seconds style, and 191 seconds incremental mixed. Workload-
  specific counts remove about 89% of the common rule's projected 79.2-minute
  runtime, but confirm still misses D4's candidate five-minute target.
- Reproducibility: `select_candidate` in
  `scripts/terminal-benchmark-calibration.py` enforces all false-positive,
  detection, nondirectional, and wrong-direction limits simultaneously and
  chooses the lowest passing fixed pair count. Its behavioral test rejects a
  lower count that misses either injected direction.
- Full workload-specific calibration: the ten screened cells each received
  100,000 deterministic trials per A/A and injected-effect condition. The
  screened 3.25% content-quick threshold narrowly failed its positive-effect
  target at 79.636% detection and 20.364% nondirectional results. Calibration
  therefore screened 3.20%, 3.15%, and 3.10% on that cell only and selected
  the highest threshold clearing all quick targets. A fresh final seed at
  3.20% produced 4.514% A/A false positives, 81.201% positive detection with
  18.799% nondirectional results, and 84.809% negative detection with 15.191%
  nondirectional results. The other nine cells retained their screened
  parameters.

  | Mode                        |      Feed | Scrollback |    Content |      Style | Incremental |
  | --------------------------- | --------: | ---------: | ---------: | ---------: | ----------: |
  | `quick` pairs / threshold   | 2 / 2.50% |  2 / 2.50% |  4 / 3.20% |  4 / 3.25% |  12 / 3.25% |
  | `confirm` pairs / threshold | 2 / 1.00% | 12 / 1.75% | 80 / 1.75% | 24 / 2.00% | 100 / 1.60% |

  Final quick A/A false-positive rates were 0%, 0%, 4.514%, 3.365%, and
  4.099% in table order; worst detection was 81.201%, worst nondirectional
  rate was 18.799%, and wrong-direction rate was 0%. Final confirm A/A rates
  were 0%, 0.253%, 0.663%, 1.003%, and 1.820%, giving a conservative 3.739%
  suite union bound. Its worst detection was 90.316%, worst nondirectional
  rate was 9.684%, and wrong-direction rate was 0%. Every frozen cell clears
  D1. Seeds, condition counts, rates, suite summaries, and the content-quick
  amendment are preserved in
  `.build/terminal-benchmark-phase3-workload-specific-calibration/2026-07-24/report.json`.

- D4 outcome: pair counts did not change from screening, so the calibrated
  projections remain about 66 seconds for a complete quick suite and 534
  seconds (8.9 minutes) for confirm. The confirm rule misses D4's five-minute
  candidate by about 78%; D4 does not relax the routine budget to accept it.
  The variance-reduced calibration design is predeclared as follows:
  - Keep the calibrated workload contracts, paired symmetric percentages,
    complete-quartet resampling, physical-arm reversal, equivalence band,
    fixed-N execution, and no-deletion outlier policy. Quick retains its
    calibrated median rule because it already meets its runtime target.
  - Confirm replaces the sample median with the 20% winsorized mean. Sort all
    valid pair differences, let `k = floor(0.20 * N)`, replace the lowest
    `k` values with value `k`, replace the highest `k` values with value
    `N - k - 1`, and average all `N` values. This preserves every pair in the
    denominator while bounding tail leverage. Counts remain positive
    multiples of two.
  - Screen confirm pair counts `2, 4, 6, 8, 12, 16, 24, 32, 40, 48, 64, 80,
100` and directional thresholds from 0.80% through 2.50% in 0.05-point
    increments, retaining the +/-0.75% equivalence band. A cell is eligible
    only when both 3% directions have at least 90% detection, at most 10%
    nondirectional results, and no more than D1's wrong-direction limit.
  - Among eligible cells, enumerate five-workload combinations whose A/A
    false-positive-rate sum is at most 5%. Select the combination with the
    lowest projected complete-suite wall time from the measured workload
    costs; break ties by lower total pair count, then workload-table order.
    Screen with 5,000 trials per condition and freeze with fresh seeds at
    100,000 trials per condition.
  - Accept the design only if the frozen rule still clears every D1 target
    and projects below five minutes. Otherwise retain the calibrated median
    rule as statistically valid but operationally slow and explicitly set
    D4 to that slower workflow; do not add another estimator after seeing
    these results.

  `winsorized_mean` and the estimator-selectable decision path live in
  `scripts/terminal-benchmark-calibration.py`; its behavioral test fixes the
  tail count, clamping, and all-observation mean.

- Variance-reduced confirm screen: the predeclared 2,275 cells received 5,000
  deterministic trials per A/A and injected-effect condition. Threshold-grid
  analysis reused each pair count's resampled estimates without changing its
  seed or decisions; a behavioral equivalence test compares a grid cell with
  an independently calibrated cell. Suite selection enumerated the eligible
  fixed-count choices under the 5% A/A union bound and selected:

  | Workload          | Pairs | Threshold | A/A false positive | Positive detection / nondirectional | Negative detection / nondirectional |
  | ----------------- | ----: | --------: | -----------------: | ----------------------------------: | ----------------------------------: |
  | Terminal feed     |     2 |     2.50% |                 0% |                      94.44% / 5.56% |                      93.82% / 6.18% |
  | Scrollback stream |     4 |     2.15% |                 0% |                      90.66% / 9.34% |                      91.06% / 8.94% |
  | Content churn     |    48 |     1.65% |              4.28% |                      91.14% / 8.86% |                      93.90% / 6.10% |
  | Style churn       |    32 |     2.00% |              0.22% |                      90.42% / 9.58% |                      92.30% / 7.70% |
  | Incremental mixed |    40 |     2.10% |              0.20% |                      90.64% / 9.36% |                      92.14% / 7.86% |

  The conservative A/A sum is 4.70%; no selected cell made a wrong-direction
  decision. The 126-pair suite projects to 281.54 seconds (4 minutes 41.5
  seconds), narrowly below D4's five-minute candidate target and about 47%
  faster than the calibrated median suite's 534-second projection. Complete
  cells, seeds, workload costs, and the deterministic selection are in
  `.build/terminal-benchmark-phase3-winsorized-screen/2026-07-24/report.json`;
  the reproducible runner is
  `scripts/terminal-benchmark-winsorized-screen.py`.

- Variance-reduced confirm freeze: exactly the five screened cells received
  100,000 deterministic trials per condition with fresh seeds `20262100`
  through `20262104`. No parameter was changed after screening.

  | Workload          | Pairs | Threshold | A/A false positive | Positive detection / nondirectional | Negative detection / nondirectional |
  | ----------------- | ----: | --------: | -----------------: | ----------------------------------: | ----------------------------------: |
  | Terminal feed     |     2 |     2.50% |                 0% |                    93.849% / 6.151% |                    93.792% / 6.208% |
  | Scrollback stream |     4 |     2.15% |                 0% |                    90.751% / 9.249% |                    91.318% / 8.682% |
  | Content churn     |    48 |     1.65% |             4.192% |                    91.622% / 8.378% |                    93.647% / 6.353% |
  | Style churn       |    32 |     2.00% |             0.233% |                    90.359% / 9.641% |                    92.564% / 7.436% |
  | Incremental mixed |    40 |     2.10% |             0.157% |                    90.470% / 9.530% |                    92.409% / 7.591% |

  The conservative A/A sum is 4.582%, worst detection is 90.359%, worst
  nondirectional rate is 9.641%, and wrong-direction rate is 0%. The
  unchanged 281.54-second projection is below five minutes. Every
  predeclared accuracy and runtime gate passes, so this design freezes the
  D3 confirm rule and closes D4. The report and explicit gate audit are in
  `.build/terminal-benchmark-phase3-winsorized-calibration/2026-07-24/report.json`;
  the reproducible runner is
  `scripts/terminal-benchmark-winsorized-freeze.py`.

- Superseded held-out schema 2 manifest: after D3 and D4 froze, manifest seed
  `2026072403` generated 1,560 unique trial identities and seeds: 900 quick
  trials and 660 confirm suite trials across 26 cells of exactly 60 trials.
  Every cell assigns 30 trials to each physical candidate arm, and no trial
  seed overlaps a calibration seed. The manifest embeds the five workload
  contracts and the exact workload-specific quick and confirm estimators,
  pair counts, thresholds, and equivalence bands. Its immutable artifact is
  `.build/terminal-benchmark-phase3-validation-schema2/2026-07-24/manifest.json`
  with SHA-256
  `844c15dc97c465c20cc72e1033b1267e2138a374506139d968bd46d443f564d9`.
  A pre-collection audit found that it omitted D1's required predeclared
  replacement schedule, so it is superseded without collecting or inspecting
  any outcome. The obsolete schema 1 manifest remains unopened.
- Replacement-capable schema 2 manifest freeze: manifest seed `2026072404`
  retains the same 1,560 primary trial identities, 26 cells, condition
  structure, physical-arm balance, block contracts, and decision rules. It
  attaches eight ordered replacement seeds to every primary identity. Across
  primary and replacement attempts, all 14,040 seeds are unique. Invalid
  attempts retain their raw evidence and reasons in an append-only ledger;
  the next attempt must consume that identity's next seed, and collection
  stops rather than improvising if its reserve is exhausted. The immutable
  artifact is
  `.build/terminal-benchmark-phase3-validation-schema2-replacements/2026-07-24/manifest.json`
  with SHA-256
  `385cf3104cc30cd658300334ff977805922f73a8d0bce65c3165c0d606979b58`.
  The behavioral contract is in
  `scripts/tests/terminal_benchmark_validation_test.py`.
- Resumable collection controller core: the validation runner now verifies
  the frozen manifest's SHA-256 before starting or resuming, replays every
  JSONL ledger entry against the manifest's exact primary/replacement seed
  order, stops at the first incomplete identity, and durably appends each
  valid or invalid attempt with `fsync`. Its seed-derived plans use only
  complete `ABBA`/`BAAB` quartets, map the frozen logical candidate to its
  predeclared physical arm, collect one workload for `quick`, and collect all
  five workloads for every `confirm` trial. Collection plans deliberately
  omit the held-out condition and perform no injection, estimation, or
  decision, so partial collection cannot expose a validation outcome.
  Behavioral coverage is in
  `scripts/tests/terminal_benchmark_validation_test.py`.
- Manifest-driven terminal-feed collector: the validation runner now consumes
  the controller's condition-free physical-arm block plan, frames the same
  committed four-stream corpus for either arm's release
  `TerminalCoreBenchmark`, performs one discarded duration-floor calibration,
  and reuses that execution count for every interleaved measured block.
  `TerminalCoreBenchmark --fixed` provides the non-recalibrating one-sample
  boundary. Evidence retains the calibration samples, every block's logical
  role and physical arm, fixed execution count, cumulative and normalized feed
  nanoseconds, and start/completion machine-state samples. A short block,
  non-AC or changing power source, low-power mode, or non-nominal thermal state
  invalidates the whole attempt without deleting any raw evidence or changing
  the fixed count. Behavioral coverage is in
  `scripts/tests/terminal_benchmark_validation_test.py`.
- Manifest-driven scrollback-stream collector: each condition-free planned
  block invokes the selected arm's optimized app harness once, which creates
  and tears down a fresh isolated process and terminal session around exactly
  one committed 25,000-line replay. The app's final-draw result now records
  the exact start marker that opened the timer; the shell artifact also records
  the fixture identity, process id, and pane/session id. Collection retains the
  complete raw artifact and validates the Swift backend, workload, fixture,
  80x24 geometry, unique process/session identities, producer-write event,
  start and final-state marker forms, completed-draw event, timing order, and
  every captured machine-state sample. Any violation invalidates the whole
  attempt without dropping evidence. Behavioral coverage is in
  `scripts/tests/terminal_benchmark_validation_test.py`.
- Manifest-driven content-churn collector: each condition-free planned block
  stays bound to one persistent process and pane per physical arm. Collection
  requires explicit completion evidence for the dense setup/start-marker draw
  and excluded settling draw before accepting exactly 50 ordered,
  draw-acknowledged updates. The app result now retains sequences 1 through 50
  alongside every draw duration and dirty-row count, so the collector validates
  serialization directly, requires all 24 rows for every measured draw, and
  checks the cumulative and per-draw metric without discarding invalid raw
  artifacts. Reuse of a process or pane across physical arms, or a changed
  process or pane within one arm, invalidates the attempt. Behavioral coverage
  is in `scripts/tests/terminal_benchmark_validation_test.py`.
- Next task superseded by Phase 4: the 80x24 validation machinery remains
  unopened. Recalibrate all five workloads at 179x66 before completing any
  held-out collector or generating a replacement manifest.

### F9 -- the Swift benchmark reproduces and enforces the canonical 179x66 grid

- The benchmark harness, suite, sustained profiling identities, core-feed
  terminal factory, and validation collectors now default to the fixed
  179x66 grid. Environment overrides remain available only for explicit
  diagnostics; canonical collection rejects any artifact whose achieved grid
  differs from 179x66.
- The AppKit sizing path remains deliberately small. After pane creation,
  `TerminalBenchmarkGeometryController` reads the backend's achieved columns,
  rows, and cell point size. Every 20 ms it adjusts `NSWindow.setContentSize`
  by only the cell-sized difference between achieved and target columns/rows,
  then stops when both match. The producer independently reads the live PTY
  size and does not acknowledge geometry or emit workload bytes until it sees
  exactly 179x66.
- The end-to-end Swift GUI proof on 2026-07-24 converged an ordinary benchmark
  window to 179x66 at backing scale 2 and completed the 25,000-line scrollback
  replay. The app-side block samples were visible, on-screen, low-power mode
  off, and thermal state nominal at both start and completion. Producer-write
  elapsed was 353,473,709 ns and final-draw elapsed was 372,788,917 ns in the
  first canonical proof; a second cached-build proof also passed. Evidence is
  under `.build/terminal-benchmark-runs/2026-07-24-115939-37331/artifacts/`
  and `.build/terminal-benchmark-runs/2026-07-24-120109-38604/artifacts/`.
- Full-screen draw validation no longer assumes 24 rows. It requires every
  measured draw's dirty-row count to equal the rows in the achieved canonical
  geometry. Incremental mixed remains four deterministic center rows; the
  app-side glyph-halo contract remains exactly six dirty rows at 179x66.
- Compatible app history now includes an explicit terminal-configuration
  identity for the Swift system-monospaced 13-point built-in default, alongside
  the already recorded grid, backing scale, backend, fixture, source commit,
  release configuration, OS, toolchain, and machine model/chip. A mismatch in
  any compatibility field prevents a delta rather than silently comparing
  unlike runs.
- A first non-history core-feed pilot confirmed that the release benchmark
  emits the canonical geometry in its compatibility identity and creates a
  fresh 179x66 terminal for every execution. On the styled-screen-redraw
  corpus, three duration-stable samples selected two executions per sample
  and measured 826,717,187 ns, 826,786,396 ns, and 829,575,875 ns per
  execution. The complete cached-build command took 11.28 seconds wall time.
  This is feasibility evidence only; it is not the cross-workload calibration
  and does not refreeze D3 or D4.
- Ghostty did not acknowledge 179x66 before the current 20-second harness
  timeout. That does not block Phase 4: D6 makes Ghostty a severable Phase 6
  comparison, while canonical calibration is for the Swift engine. Preserve
  the failure as a Phase 6 input rather than weakening the Swift geometry or
  extending the calibration boundary.
- Full-containment correction: the first persistent content series exposed a
  flaw in the GUI proof after visual inspection. Both 179x66 windows were
  offset from the display's top-left and extended off-screen, while AppKit and
  CoreGraphics still reported them visible because part of each window was
  onscreen. That series is invalid and remains preserved under
  `.build/terminal-benchmark-phase4-content-calibration/2026-07-24/`; an
  interrupted style attempt under
  `.build/terminal-benchmark-phase4-style-calibration/2026-07-24/` is also
  invalid. `TerminalBenchmarkGeometryController` now anchors a converged
  window to the active screen's visible-frame top-left, and the state recorder
  reports visibility only when the visible frame contains the complete window
  frame. The corrected end-to-end proof passed at 179x66 under
  `.build/terminal-benchmark-runs/2026-07-24-121509-55604/artifacts/`.
- Canonical A/A collections after that correction:

  | Workload          | Blocks / pairs | Paired SD | Paired median | Wall time |
  | ----------------- | -------------: | --------: | ------------: | --------: |
  | Terminal feed     |        32 / 16 |    0.279% |       -0.016% |   55.89 s |
  | Scrollback stream |        32 / 16 |    2.170% |       -0.179% |  185.80 s |
  | Content churn     |        96 / 48 |    1.293% |       -0.999% |  114.10 s |
  | Style churn       |        96 / 48 |    1.266% |       -1.489% |  114.51 s |
  | Incremental mixed |        96 / 48 |    3.210% |       -0.131% |  101.65 s |

  Feed used fresh 179x66 terminals and a fixed two-execution duration-stable
  batch. Scrollback used a fresh optimized app and session for every block.
  Each draw series used two persistent, fully contained apps and 50 exact
  acknowledged draws per block. All accepted GUI state samples were nominal,
  low-power mode was off, and the complete window was visible. Raw evidence is
  under the corresponding
  `.build/terminal-benchmark-phase4-*-calibration-contained/2026-07-24/`
  directories; derived pair summaries are under
  `.build/terminal-benchmark-phase4-derived/2026-07-24/`.

- Predeclared confirm-screen result: the existing 2,275-cell winsorized screen
  ran 5,000 deterministic trials per condition with fresh seed base
  `20262500`. It selected no eligible five-workload suite. Style churn's
  persistent A/A offset made a directional decision in at least 81.68% of
  otherwise accuracy-eligible cells, so no combination could satisfy the 5%
  conservative false-positive bound. The complete report is
  `.build/terminal-benchmark-phase4-winsorized-screen/2026-07-24/report.json`.
  This is a collection-protocol failure, not permission to relax D1.
- Bundle-arm diagnosis: reversing launch order left arm B faster in a second
  48-pair style series (median -1.256%). Swapping only the stable `.a` and `.b`
  bundle suffixes between logical arms reversed the sign in a 16-pair
  diagnostic (median +1.510%, SD 1.284%). The level shift therefore follows
  the stable bundle namespace rather than logical label or launch order.
  Evidence is under
  `.build/terminal-benchmark-phase4-style-reverse-launch-diagnostic/2026-07-24/`
  and
  `.build/terminal-benchmark-phase4-style-swapped-bundle-diagnostic/2026-07-24/`.
- Shared-namespace correction: two concurrent processes can retain isolated
  app paths, homes, temporary roots, sockets, and PID-scoped activation while
  using the same stable benchmark bundle identifier. A 16-pair style
  diagnostic reduced the median offset to +0.610%. Full 48-pair replacement
  series then measured content median +0.163% / SD 1.164%, style median
  +0.398% / SD 1.156%, and incremental median -0.552% / SD 1.502%. All
  blocks passed geometry, complete-frame visibility, state, acknowledgment,
  and damage checks. The corrected series and wall times are under
  `.build/terminal-benchmark-phase4-{content,style,incremental}-shared-bundle-calibration/2026-07-24/`.
  These supersede the separate-namespace draw series for calibration.
- Corrected confirm screen: the unchanged 5,000-trial grid, using fresh seed
  base `20263000`, selected 20 total pairs: feed 2 at 2.50%, scrollback 4 at
  2.00%, content 4 at 2.10%, style 4 at 2.05%, and incremental 6 at 1.75%.
  Its screened conservative A/A bound was 4.14% and its projected wall time
  was 86.72 seconds. Every screened detection, nondirectional, and
  wrong-direction gate passed. The report is
  `.build/terminal-benchmark-phase4-winsorized-screen-shared-bundle/2026-07-24/report.json`.
- Corrected confirm freeze: exactly those five cells received 100,000 trials
  per condition with fresh seeds `20263500` through `20263504`. The freeze
  failed the predeclared acceptance rule: scrollback's positive 3% condition
  produced 89.796% detection and 10.204% nondirectional results, narrowly
  missing the fixed 90% / 10% gates. The conservative A/A sum was 4.274%,
  wrong-direction rate was 0%, and projected wall time remained 86.72
  seconds. No threshold or pair count changes after seeing this result. The
  rejected freeze is preserved at
  `.build/terminal-benchmark-phase4-winsorized-freeze-shared-bundle/2026-07-24/report.json`.
- Median fallback screen: the fixed complete-quartet count grid was screened
  with 5,000 trials per condition and fresh seed base `20264000`. Quick used
  its 5% injected effect and +/-1.00% equivalence band; confirm used its 3%
  effect and +/-0.75% band. Both retained the median symmetric paired
  estimator and fixed D1 accuracy gates. The selected cells were:

  | Mode                        |      Feed | Scrollback |   Content |     Style | Incremental |
  | --------------------------- | --------: | ---------: | --------: | --------: | ----------: |
  | `quick` pairs / threshold   | 2 / 4.50% |  2 / 4.05% | 2 / 4.05% | 2 / 4.05% |   2 / 3.80% |
  | `confirm` pairs / threshold | 2 / 2.50% |  4 / 1.85% | 4 / 2.15% | 4 / 2.00% |   6 / 1.85% |

  Quick's slowest workload projected to 23.23 seconds. Confirm selected 20
  total pairs with a 3.04% screened A/A union bound and an 86.72-second
  complete-suite projection. The complete grid and selection are preserved
  in
  `.build/terminal-benchmark-phase4-median-fallback-screen/2026-07-24/report.json`.

- Median fallback freeze: exactly those ten cells received 100,000 trials per
  condition with disjoint fresh seeds based at `20265000`; no parameter was
  changed after screening. All quick workloads passed: A/A false positives
  were 0%, worst detection was 81.218%, worst nondirectional rate was
  18.782%, wrong-direction rate was 0%, and the slowest workload remained
  23.23 seconds. Confirm also passed: its conservative A/A union bound was
  3.025%, worst detection was 90.750%, worst nondirectional rate was 9.250%,
  wrong-direction rate was 0%, and its projected complete runtime remained
  86.72 seconds. The frozen report and explicit gate audit are in
  `.build/terminal-benchmark-phase4-median-fallback-freeze/2026-07-24/report.json`;
  `scripts/terminal-benchmark-median-fallback.py` reproduces the screen and
  freeze.
- D3/D4 outcome: the statistically valid predeclared median fallback passes
  at 179x66 and is now the frozen quick and confirm rule. Its measured
  per-pair controller costs project every quick comparison below 60 seconds
  and the complete confirm invocation below five minutes. The executable
  manifest rules now contain the frozen cells.
- Superseded Phase 5 held-out manifest: only after that D3/D4 freeze, manifest
  seed `2026072405` generated 1,560 trial identities across the 26
  predeclared 60-trial cells, with eight ordered replacements per identity.
  All 14,040 primary and replacement seeds are unique, have zero overlap
  with every superseded manifest seed, and avoid every declared Phase 4
  calibration seed range. Physical candidate assignment is balanced 780/780.
  The manifest embeds the canonical 179x66 block contracts and exact frozen
  median rules. Its immutable artifact is
  `.build/terminal-benchmark-phase5-validation/2026-07-24/manifest.json`
  with SHA-256
  `97c46ebcf1882e1268b105cd12af72e8ce3f13e8a552228629a930660e3942ad`.
  No held-out outcome was collected or inspected while freezing it. The first
  collection command later exposed the held-out `aa` condition because its
  supposedly condition-free stdout and artifact directory included the
  semantic trial id. The attempt was mechanically valid, but no measurement
  payload or ledger content was inspected. Collection stopped immediately.
  This is a blinding-protocol failure, so the manifest and its one-attempt
  ledger remain preserved but are superseded in full.
- Opaque Phase 5 replacement manifest: collection-facing status, artifact
  directories, and ledger entries now identify work only by its zero-based
  manifest-order `collectionIndex`. The condition-bearing semantic id remains
  inside the unopened manifest for final evaluation and cannot escape through
  those collection surfaces. A regression test pins stdout, filesystem, and
  ledger opacity. Fresh manifest seed `2026072406` generated the same 1,560
  trial and 14,040 unique-seed structure with 780/780 physical-arm balance and
  zero seed overlap with the superseded Phase 5 manifest. Its immutable
  artifact is
  `.build/terminal-benchmark-phase5-validation-opaque/2026-07-24/manifest.json`
  with SHA-256
  `31e283f7a5dca2c0a2018476b2e200787974fb94f8e6bbb7a4f2351ee8e514ab`.
  Collection indices 0 through 13 were observed to pass the mechanical
  validity checks on attempt 0 with no invalidation reasons. No condition,
  measurement payload, ledger content, or artifact content was inspected.
  The campaign was then retired unevaluated: 1,560 attempts at the observed
  roughly 24 seconds each would take about 10.4 hours, which is
  disproportionate to this local engineering benchmark. The partial evidence
  remains preserved and must not be selectively extended or presented as a
  held-out accuracy result.
- Phase 5 collection readiness: the condition-free collector now covers all
  three persistent draw workloads through one shared serialized-draw
  validator. Content and style churn require all 66 rows of damage for each
  of 50 ordered completed draws (producer sequences 0 through 49);
  incremental mixed requires the predeclared
  six-row glyph-halo damage around its four changed rows. A trial-attempt
  collector runs every workload in the manifest plan, retains each workload's
  raw evidence, and combines invalidation reasons without carrying or exposing
  the held-out condition. The production persistent draw-block runner now
  reopens the observer block, fronts only the app named by the arm identity,
  resolves that app's live pane through its isolated socket, injects an exact
  50-update producer, and retains the start-draw and settling acknowledgments
  with the raw producer and final-draw records. Its lifecycle owner launches
  exactly two isolated harnesses, preserves the shared stable bundle namespace
  selected by canonical calibration, requires the frozen 179x66 geometry and
  matching Swift workload identities before exposing either arm, and tears
  down only the harness processes it owns. Full-window containment remains a
  measured-block validity requirement, so a partly offscreen window cannot
  enter a valid attempt. Behavioral coverage is in
  `scripts/tests/terminal_benchmark_validation_test.py`. The condition-free
  attempt controller now hash-verifies and replays the ledger, selects exactly
  the next predeclared primary or replacement seed, closes all attempt-owned
  resources on success or interruption, and durably appends only complete
  evidence. It returns an opaque collection index, seed, validity, and
  invalidation reasons without exposing the held-out condition. A production
  collector factory now
  binds only the workloads present in that plan to the concrete feed,
  scrollback, and serialized-draw runners. It starts one workload-specific
  persistent lifecycle for each planned draw workload and closes all started
  lifecycles in reverse order on completion or partial startup failure. The
  independent terminal-feed machine-state sampler now compiles one native
  ProcessInfo probe per attempt before measurement, then records thermal state,
  low-power mode, and the `pmset` power source immediately before and after
  each feed block. Malformed probe or power output aborts rather than producing
  valid-looking evidence. The production `collect-one` command now requires
  explicit manifest, frozen SHA-256, ledger, artifact, and physical A/B root
  arguments; it optionally accepts the repository root. It compiles the feed
  state probe only for attempts whose condition-free plan contains terminal
  feed, invokes the tested single-attempt controller, and prints only its
  condition-free status. The previous positional manifest-generation command
  remains compatible. All pre-execution machinery is now complete. No
  replacement-manifest held-out outcome has been inspected; the campaign
  is retired rather than pending execution.

## Decision log

### D1 -- minimum effects of interest and required accuracy rates

- Status: Effect sizes and accuracy rates fixed before Phase 3 trials.
- Scope: this decision owns both halves of the accuracy contract -- the
  minimum effect sizes worth detecting, and the required false-positive,
  inconclusive, and detection-power rates for `quick` and `confirm` at
  those effect sizes. Phase 3 trial counts are sized to these rates and the
  frozen design passes or fails against them; they may not be chosen ad hoc
  during validation.
- Decision:
  - `quick` has a 5% minimum effect of interest. A candidate at least 5%
    slower than its paired baseline is worth blocking; an improvement of the
    same magnitude is worth calling faster. The calibrated observed-estimate
    threshold is necessarily lower than 5% so a noisy estimate of a true 5%
    effect can attain greater than 50% detection power; it is a detection
    boundary, not a redefinition of the minimum true effect being validated.
  - `confirm` has a 3% minimum effect of interest in either direction. This
    is the smallest change worth a durable faster/slower claim and benchmark
    record. Smaller estimates remain raw evidence, not a claimed change.
  - Effects are relative within one workload and compatible geometry. No
    cross-workload averaging may let a large improvement hide a 5%
    workload regression.
  - `quick` must have at most a 5% false-positive rate, at least 80%
    detection power at a true effect of either +5% or -5%, and at most a
    20% inconclusive rate at either effect. A false positive is any
    directional faster/slower decision in an A/A trial.
  - `confirm` must have at most a 5% family-wise false-positive rate, at
    least 90% detection power at a true effect of either +3% or -3%, and at
    most a 10% inconclusive rate at either effect. Its false-positive unit
    is the complete five-workload invocation: any directional claim from
    any workload makes that A/A trial a false positive. Per-workload rates
    that compound above 5% for the suite do not satisfy this contract.
  - Detection power is the probability of the correct directional decision,
    measured separately for positive and negative injections and for each
    workload rather than pooling them. An inconclusive result is a result
    that makes neither directional decision. A wrong-direction result is
    neither a detection nor an inconclusive result and is an independent
    safety failure.
  - The original independent-certification design required every held-out
    condition cell to contain 60 independent trials. `quick`
    has one A/A, one positive-effect, and one negative-effect cell for each
    of the five workloads (900 trials total). `confirm` has 60 complete-suite
    A/A trials plus positive- and negative-effect cells for each workload
    (660 complete-suite trials total); only the named workload is injected
    in an effect cell, so unchanged workloads also exercise the suite's
    multiplicity control. A correct `confirm` detection requires the named
    workload's injected direction and no directional claim from an unchanged
    workload. Rates and their acceptance bounds use exact one-sided 95%
    Clopper-Pearson intervals:
    - Each `quick` workload's A/A cell and the `confirm` suite A/A cell pass
      only with zero directional decisions in 60 trials. The upper bound is
      4.87%, below the 5% target.
    - Each `quick` injected direction passes with at least 54 correct
      decisions, at most 6 inconclusive results, and zero wrong-direction
      decisions in 60 trials. The corresponding lower power bound is
      81.21% and upper inconclusive bound is 18.79%.
    - Each `confirm` injected direction passes with at least 59 correct
      decisions, at most 1 inconclusive result, and zero wrong-direction
      decisions in 60 trials. The corresponding lower power bound is
      92.34% and upper inconclusive bound is 7.66%.
    - Zero wrong-direction decisions in 60 trials bounds that failure rate
      below 4.87%. Any wrong-direction result therefore fails the safety
      gate even when the power and inconclusive counts would otherwise pass.
  - Such held-out trials are generated only after D3 freezes the rule at
    the canonical 179x66 geometry.
    Calibration trials are disjoint, are never counted toward these
    denominators, and cannot be added selectively after results are
    inspected. An invalidated machine-state trial has no decision and is
    replaced from the predeclared condition and seed schedule; its raw
    evidence and invalidation reason remain preserved.
- Scope supersession: the 60-trial, 26-cell design above remains the statistical
  requirement for making the original independent held-out-certification
  claim. It is not required to graduate or use the local benchmark runner.
  The estimated 10.4-hour GUI campaign was retired as disproportionate after
  opaque collection began. Therefore this research claims only the measured
  calibration rates, not independently held-out-confirmed rates. A future
  certification effort must justify its value and sample budget before
  generating a fresh manifest.
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
  that have affected optimization decisions. Exact binomial sizing is why
  the held-out A/A set contains 60 trials: zero false positives in 50 would
  still have a 5.82% one-sided 95% upper bound and could not establish the
  selected 5% target.
- Consequence for Phase 3: calibration may choose the fixed-N rule and its
  thresholds, but it may not weaken these rates or inspect held-out trials.
  Failure of either injected direction, the suite-level A/A gate, or the
  wrong-direction safety gate rejects that mode's rule.

### D2 -- redraw workload set

- Status: Five-question ladder validated; the Phase 2 incremental fixture must
  close the mixed-update gap identified below.
- Decision: `confirm` runs the five workloads in Performance workload ladder.
  `quick` selects exactly one of them for the path under investigation. Each
  workload owns one decision question and must retain the following boundary:

  | Workload                               | Required stimulus and measured boundary                                                                                                                                                                              | Distinct decision                                                                                                                          |
  | -------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
  | Terminal feed                          | A deterministic representative mix of plain scrolling output, styled TUI control traffic, Unicode width/grapheme input, and localized editing, timed around pure `Terminal.feed` with rendering and PTY work absent. | Did parser, grid, Unicode, or damage-policy work change independently of actors, PTY backpressure, and drawing?                            |
  | Scrollback stream                      | Sustained PTY output that exceeds the viewport and grows retained history, timed through the optimized app/session path.                                                                                             | Did chunking, backpressure, actor hops, snapshot production, scrolling, or retention change even when pure feed and drawing remain stable? |
  | Screen-sized content churn             | Serialized completed full-window draws whose visible cell content changes while style placement and values remain fixed.                                                                                             | Did glyph lookup, shaping, text-run construction, or content replacement change without style invalidation as the explanation?             |
  | Screen-sized style churn               | Serialized completed full-window draws whose visible cell content remains fixed while foreground/background styles change.                                                                                           | Did attribute/color resolution or restyling change without new text as the explanation?                                                    |
  | Screen-sized incremental mixed updates | Serialized completed draws after a settled dense screen; a deterministic proper subset of cells changes in both content and style, and every draw records its exact damage.                                          | Does localized damage avoid full-window planning and execution while still exercising both text and style invalidation?                    |

- Validation against current fixtures:
  - `scrollback-stream` already supplies 25,000 numbered lines and exercises
    sustained output, viewport scrolling, and history growth through the app.
  - The current redraw generator behaviorally isolates content and style:
    tests prove successive content frames change text with identical style
    escapes and successive style frames change style escapes with identical
    text. Exact draw acknowledgments keep coalescing from changing the
    boundary.
  - The current localized draw acceptance workload proves one-row damage and
    was decisive for retaining dirty-rect clipping: it measured about a 97.1%
    reduction from the full-frame path. It is not yet the selected mixed
    fixture, however. Successive updates change the sequence marker but reuse
    fixed style escapes. Phase 2 must vary style values as well as content,
    select a deterministic subset at screen-sized geometry, and assert that
    observed damage matches that subset.
  - The existing core corpus can run behind the `swift-core` boundary, but no
    one current corpus member is the representative mix required above.
    Phase 2 must compose or replace it rather than silently naming the
    ASCII-only scrollback or the styled-only redraw fixture "terminal feed."
- Overlap audit:
  - A separate full-window mixed-churn workload is rejected. Content and style
    churn isolate its two causes, while incremental mixed updates supply the
    only additional question -- whether bounded damage prevents full-window
    work. The old full-window mixed results tracked the same ordinary redraw
    scale and did not drive a different optimization decision.
  - The session workload is not a duplicate of core feed: its value is the
    PTY/backpressure/actor/snapshot/retention path deliberately absent from the
    pure core measurement.
  - Incremental mixed updates are not a cheaper content/style sample: their
    acceptance criterion is damage proportionality, which full-window churn
    cannot test.
- Specialized diagnostics:
  - Unicode remains represented in the routine core-feed mix, but a
    Unicode-heavy wrapping corpus stays opt-in for changes to width,
    grapheme, fallback-font, or wrapping code.
  - The btop-shaped symbol workload exposed the braille fallback regression
    and changed the sprite-rendering decision; the curated sprite workload
    then served as a coverage yardstick. They remain mandatory targeted
    diagnostics when sprite classification, geometry, fallback routing, or
    executor dispatch changes, with bitmap and membership tests as their
    standing correctness guards. They do not join every `confirm` run because
    they answer which specialized glyph family is slow, not a sixth broad
    pipeline question.
  - A specialized diagnostic graduates into the routine ladder only if it
    catches a regression outside its owning path, reverses a decision made
    from one of the five routine workloads, or exposes a broad user workload
    not represented by the required core mix and draw stimuli.
- Consequence for Phase 2: the prototype may reuse current mechanisms and
  corpus segments, but it may not claim the five-workload ladder is
  implemented until the representative core mix and screen-sized incremental
  mixed fixture meet the contracts above.

### D3 -- block design and decision rule

- Status: Frozen at 179x66 from the Phase 4 median fallback calibration.
- Decision:
  - A measured block uses the workload-specific timed unit, normalization,
    and reset boundary in F8. The three draw workloads contain 50 exact
    completed draws. Terminal feed uses a duration-stable fresh-terminal
    batch of at least 1 second. Scrollback uses one fixed 25,000-line replay
    through its completed final draw in a fresh app/session. Setup, reset,
    settling, focus changes, arm switches, and teardown remain outside timing.
  - Pair counts and directional thresholds are workload-specific:

    | Mode                        |      Feed | Scrollback |   Content |     Style | Incremental |
    | --------------------------- | --------: | ---------: | --------: | --------: | ----------: |
    | `quick` pairs / threshold   | 2 / 4.50% |  2 / 4.05% | 2 / 4.05% | 2 / 4.05% |   2 / 3.80% |
    | `confirm` pairs / threshold | 2 / 2.50% |  4 / 1.85% | 4 / 2.15% | 4 / 2.00% |   6 / 1.85% |

    Every count contains complete `ABBA`/`BAAB` position-balanced quartets.
    Source baseline/candidate assignment to physical `.a`/`.b` positions
    alternates across trials according to a seed schedule fixed before
    collection.

  - Reduce each block to the normalized scalar timing defined by its workload
    contract. Convert each adjacent source-oriented pair to the symmetric
    percentage `200 * (candidate - baseline) / (candidate + baseline)`.
    Both modes use the median of every valid fixed-N pair. The predeclared
    winsorized confirm attempt failed its fresh freeze, so the median fallback
    is the frozen confirm estimator.
  - `Quick` uses the workload-specific threshold table above and the closed
    +/-1.00% equivalence band. Its calibrated worst per-workload A/A
    false-positive rate is 0%, worst injected detection is 81.218%, worst
    nondirectional rate is 18.782%, and wrong-direction rate is 0%.
  - `Confirm` uses the workload-specific threshold table above and the closed
    +/-0.75% equivalence band. Its calibrated conservative five-workload A/A
    union bound is 3.025%, worst injected detection is 90.750%, worst
    nondirectional rate is 9.250%, and wrong-direction rate is 0%.
  - MAD scores above 3.5 flag outliers for reporting only. No statistically
    valid block or pair is deleted or rerun. Machine-state invalidation rejects
    the complete trial under the predeclared replacement schedule and
    preserves its raw evidence.
  - The rule has no early stopping or optional peeking. Adaptive escalation
    remains forbidden unless this exact fixed design fails held-out F8.

- Evidence: F9 records the corrected 179x66 shared-namespace series, rejected
  winsorized freeze, and predeclared median fallback screen and freeze. The
  fallback used 5,000 screening trials and 100,000 fresh freeze trials per
  condition. Its exact sources, seeds, cells, and gate audit are preserved in
  the Phase 4 median fallback artifacts.
- Validation boundary: the cross-workload D3 rule is now refrozen at 179x66,
  so a new held-out manifest may be generated with fresh seeds disjoint from
  every Phase 4 calibration seed. Every 80x24 manifest remains superseded and
  no held-out outcome has been generated or inspected. Any later D3 change
  likewise discards held-out trials collected under the superseded rule and
  restarts validation with new seeds.

### D4 -- workflow runtime budgets

- Status: Frozen at 179x66 from the Phase 4 median fallback calibration.
- Budgets: under 60 seconds for one `quick` workload
  comparison and under 5 minutes for the complete `confirm` suite, including
  cached build and harness overhead.
- Evidence: proportional projections use the corrected 179x66 controllers'
  complete wall times, including their applicable launch, warm-up, measured
  block, and teardown costs. Every selected two-pair quick workload projects
  below 24 seconds; scrollback is limiting at 23.23 seconds. The 20-pair
  complete median confirm suite projects to 86.72 seconds. Both clear the
  unchanged budgets without relaxing either accuracy or runtime gates.
- Decision: freeze these workload-specific runtime results. Held-out execution
  must also record live wall time and fails operational acceptance if actual
  runtime exceeds the same budgets.

### D5 -- canonical render geometry

- Status: Decided and calibrated. Canonical geometry is a single fixed large
  grid.
- Scope decision (user): this runner will only ever run on the user's own
  MacBook. CI, cross-machine trends, and other displays are explicitly out of
  scope. Geometry therefore does not need to be portable, machine-general, or
  dynamically matched to whatever display is attached; it needs to be a fixed,
  reproducible size that is representative of real full-viewport use on this
  one machine.
- Selected geometry: a single fixed grid, frozen as a constant, matching the
  grid DanTerm already presents when its normal window (sidebar and all chrome
  included) fills the built-in Retina screen. The size is not derived by
  interrogating the display at runtime; it is a hand-chosen constant equal to
  a measured reference.
- Reference measurement: 179x66 (`tput cols` = 179, `tput lines` = 66),
  measured directly inside a DanTerm Dev window whose Swift-backend terminal
  pane filled the built-in screen with the sidebar and all app chrome present.
  Because it was read from the live pane, it already nets out titlebar, tab
  bar, sidebar, and padding -- it is the real usable terminal grid of a
  full-viewport DanTerm, not a raw display size to be reduced. The canonical
  grid is therefore 179x66 itself, with no margin subtraction. This replaces
  the earlier "dynamically size a window to the built-in display" direction:
  same intent (screen-scale area, roughly 6x the 1,920 cells of 80x24), far
  less machinery, and reproducible because it is a constant.
- Why not dynamic display-sizing: identifying the built-in display, reading
  its current mode/frame, deciding frame vs visibleFrame, and building a
  compatibility identity that fails rather than falling back all solve a
  portability problem the user does not have. A fixed constant on one machine
  with a fixed font is deterministic in points and backing pixels without any
  of it. The compatibility identity collapses to recording the constant grid,
  font, and machine rather than a runtime display interrogation.
- 80x24: dropped as the canonical target. It survives only as an optional fast
  diagnostic if the Phase 4 ranking comparison later shows it is worth
  keeping; it is no longer a portability hedge, since portability is out of
  scope.
- Consequence: leaving 80x24 invalidates the F7 and Phase 3 block-size and
  threshold calibration, which was all measured at 80x24. It also invalidates the
  associated D3/D4 freeze and every predeclared 80x24 held-out manifest.
  Recalibrating at the fixed large grid (rerunning the existing calibration
  machinery) is the immediate next empirical task, before held-out
  validation, not a new statistical design exercise.
- Terminal-feed consequence: use a fresh 179x66 `Terminal` for every fixed
  execution. Rendering is absent, but grid allocation and mutation,
  scrolling, damage tracking, and memory behavior are geometry-sensitive.
- Still open (Phase 4, minor): confirm 179x66 is reproduced by a windowed
  (non-fullscreen-Space) DanTerm filling the screen -- if the reference was
  captured with the system menu bar hidden, the windowed row count could shift
  by about one -- and that the window at that grid stays fully visible and
  unoccluded across a full run.
- Next action: implement and verify the fixed 179x66 geometry, update damage
  contracts, rerun all workload calibration and live runtime measurements,
  then refreeze D3/D4. Do not generate or inspect held-out evidence first.

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
pixels -- which a normal window at the fixed large canonical grid (D5)
captures. Reopen only if evidence shows the fullscreen presentation path
itself differs enough to change an optimization decision.

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

### Archiving or migrating old history

The old schema's 80x24 geometry, fixed batch count, and history-comparison
model conflict with the new goals. Delete both obsolete JSONL histories when
the paired workflow replaces their active consumers; retaining incompatible
measurements adds maintenance surface without supporting a future decision.

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
- Resolved (D5): results are intentionally machine/display-specific and that
  is accepted -- the user runs this only on one MacBook, so no CI or
  cross-machine benchmark is needed. No portable smaller benchmark is
  required; 80x24 survives only as an optional fast diagnostic.
- Do 80x24 and the fixed large grid ever rank real changes differently?
  A worthwhile but non-gating Phase 4 check that only decides whether 80x24
  is worth keeping as an optional fast diagnostic (D5).

## Outcome

Calibration is complete at the fixed 179x66 grid. The frozen design is a
persistent, paired, interleaved A/B runner over two isolated apps sharing one
stable benchmark bundle namespace, with fully contained windows and
workload-specific median fixed-N rules. Fresh Phase 4 screening and freeze
seeds passed the calibration gates in D1 and the runtime budgets in D4 for
both quick and confirm. The condition-free collectors cover all five workload
contracts, and the
persistent draw workloads have a production block runner over already
converged arm identities. Persistent arm lifecycle orchestration and the
resumable hash-pinned single-attempt controller are complete and tested. The
production collector composition now binds that controller to all five
concrete runners and owns their selective startup and cleanup. The independent
terminal-feed machine-state sampler is complete and tested, including a real
native probe compile. The production command-line entry point is also complete,
requires the frozen manifest hash and both physical arm roots, and exposes only
opaque collection indices.

The planned independent held-out certification is retired, not failed. Its 26
cells of 60 trials would require 1,560 GUI attempts, or about 10.4 hours at the
observed 24-second attempt cost. Opaque indices 0 through 13 were observed to
pass mechanical validity before collection stopped; no condition or outcome
was inspected. That partial manifest remains preserved and unevaluated. The
system therefore graduates with calibration-backed thresholds and does not
claim independently held-out-certified error rates. The next step is to move
the accepted runner and schema into an implementation plan and use them on real
optimization work. Independent certification and adaptive statistics remain
optional escalation paths if practical use supplies evidence that they are
needed.

## How it held up in use -- closing note, 2026-07-28

**CLOSED.** The runner graduated to
`plans/impl/2026-07-24-1423-fast-paired-performance-benchmarks.md`, which is
fully implemented (all three commits), and `just benchmark-quick` /
`benchmark-confirm` shipped. It then did the job it was built for: **every
optimization verdict in docs 8 through 13 was decided on it**, including several
that reversed a plausible hypothesis -- `12/F8` (`scrollback-stream` +6.74%,
which reverted a change a spike had projected at -9.7%) and `9/F4` (plan time
-46.86%). An instrument that reverses your prior is doing its job.

**It also found its own limit, which is the more useful outcome.** The above
retirement note says certification stays optional "if practical use supplies
evidence that it is needed". Practical use supplied that evidence within days,
and the answer turned out not to be certification:

- **`incremental-mixed` degraded to the point of false verdicts** --
  [8-benchmark-variance-regression.md](8-benchmark-variance-regression.md).
  Cause: macOS demotes the app's CPU clock when the recent optimizations left
  the main thread ~96% idle. The instrument was measuring the CPU's power state.
  This is a **property of GUI-based paired timing on an efficient app**, not a
  defect in the paired design -- and notably not something a held-out
  certification campaign would have caught, since it emerged only after the app
  got fast enough to trigger it.
- **`8/D2` routed around it** rather than repairing it: damage-*drawing*
  comparisons moved to the headless in-process `just benchmark-headless-draw`,
  which holds ~100% occupancy by construction. Damage *generation* stays with a
  degraded `benchmark-quick`, and that coverage gap is accepted, not closed.
- **`8/F24` is the methodological correction this file should carry forward.**
  A real revision pair exposed two order biases that the A/A control was
  structurally incapable of showing, so **A/A precision overstates
  revision-pair precision**. Every threshold frozen here was calibrated on A/A
  series. They were not invalidated, but anyone re-deriving a threshold should
  screen against a real revision pair as well.
- **The physical arm slot is a second, unpriced source of bias, and on
  `scrollback-stream` it is large enough to fabricate a verdict** --
  `39/F8`. `physical_candidate_arm` gives each arm a slot from the candidate
  tree's own hex parity, so the slot is a property of the tree, not of the
  change. On 2026-08-28 a candidate on slot `b` held a draw tail of 17.0-18.4 ms
  across three probes regardless of whether the change under test was present,
  against 10.5-15.8 ms for the cached baseline binary on slot `a`. That was
  enough to make the cell read `slower` at +9.54% and +11.25% in two `confirm`
  runs on a change that was verbatim code motion, and `slower` again at +5.16%
  on a tree with no code delta at all -- all of the movement in the draw tail,
  none in the drain leg the change could reach. `39/F7` had already bounded the
  same effect at "at most all of" a +1.66% `retained-browse` call. The reading
  rule now recorded for users is in
  [../../agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md):
  a `slower` call on `scrollback-stream` whose movement is in the draw tail is
  not believed until a change-free control run reproduces it. That is a caveat,
  not a repair -- the runner still pairs one cached baseline binary on one slot
  against one freshly built candidate on the other, and nothing holds the slot
  fixed across the two arms of a comparison.
- The `confirm` recalibration this file's machinery would have supplied is
  **declined, not deferred** (`8/F20`): ~100 pairs and ~9 minutes to land
  marginally over the detection floor.

**Ghostty baseline status: not built.** Phase 6 was declared severable and was
severed. `11/F3` later found the ghostty arm does not run at all -- no ghostty
code path for the redraw workloads, and a shell that hangs in `/usr/bin/login`
on corpus workloads. The cross-backend question that motivated it remains
unattributed (see Phase 6).

**Reopening condition.** A new workload shows verdict instability that
`8/D2`'s routing does not cover, or a threshold needs re-deriving -- in which
case screen against a real revision pair per `8/F24`, not an A/A series alone.
Removing the slot-position bias itself, rather than reading around it, is also a
reopening: it is a property of how this runner assigns arms to slots, and the
caveat above buys time rather than fixing it.
