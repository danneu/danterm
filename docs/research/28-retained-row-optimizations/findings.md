# Findings -- append-only evidence chain

Next free ID: **F3**. Inherited baseline: `15/F18` -- the compact retained-row
validation at `dd51a12`/`54d4d2d` -- is cited, not copied; read it there.

### F1 -- the trim's feed-path effect is structurally unresolvable: four schedules agree on ~+1%, which is the harness's dead zone

- Status: recorded, and it closes Phase 1's first task. This is a
  findings-grade record of **why the harness cannot produce a directional
  verdict**, not a `faster`/`slower`/`equivalent` claim. No feed-neutrality and
  no feed-regression claim is made for the trim.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: baseline `fa01b66` (logical retained-row access
  seam, before trimming), commit `fa01b66f0220e937765596cd0526d5866e7e5aa5`,
  tree `2753fd32ecb7fb141475a7b8d5e0bfdbcc35b9c0`. Candidate base `6da2bb7`,
  candidate tree `9dbdb3aa1fc8d6241a85a39b6f62b5c9a3a940da`, capturing five
  untracked working-tree paths (`TODO.md` and four `plans/wip/*.md`) -- all
  prose, none built into or reachable from `TerminalCoreBenchmark`.
- Conditions: AC power, low-power mode off, `pmset -g therm` recording no
  thermal or performance warning. **No `DANTERM_BENCHMARK_ALLOW_BATTERY`
  override was used**, unlike `15/F18`, whose feed arms both ran on battery.
  See `F2` for the one stated condition that was *not* met.
- Commands, in the order the frozen protocol prescribes:

      just benchmark-quick baseline=fa01b66 workload=terminal-feed
      just benchmark-confirm baseline=fa01b66

- Artifacts (disposable `.build/`, cited as pointers only):
  `.build/terminal-benchmark-comparisons/quick/9dbdb3aa1fc8-0000/run.json` and
  `.build/terminal-benchmark-comparisons/confirm/9dbdb3aa1fc8-0000/run.json`.

#### Baseline framing, and why `fa01b66` is the right arm

The task is the trim's feed-path effect, so the baseline is the commit the trim
landed on top of: `fa01b66` is the seam alone, `dd51a12` is the seam plus the
trim. HEAD has moved 15 commits past `dd51a12` since `15/F18`, so this
comparison nominally attributes that whole range. It is still a valid framing
for **this** question because `terminal-feed` runs the four committed corpora
into a fresh headless 179x66 `Terminal` -- no PTY, no window, no drawing -- and
the only non-test `TerminalCore` source changes in `dd51a12..HEAD` are off that
path:

- `isTrailingURLPunctuation` gained `0x5C` -- link detection, which
  `terminal-feed` never invokes.
- the reflow cursor-clamp fix (`cd57eb8`) -- the resize path, which
  `terminal-feed` never invokes.
- new benchmark-only files (`TerminalBenchmarkSparseSpanTopology`,
  `TerminalBenchmarkPresentationCoverage`, `TerminalDamageSpans`) -- draw-path
  and instrumentation code, not reachable from the feed harness.

The alternative framing -- checking `dd51a12` out into a worktree so the
candidate tree *is* the trim commit -- was rejected: it would isolate the trim
exactly but violate this doc's evidence floor, which requires numbers measured
**on current HEAD**, and other sessions are active on this branch.

#### Measurements

Four independent paired schedules now exist for the same question, two from
`15/F18` (candidate `dd51a12`, on battery) and two from this finding (candidate
`6da2bb7`+tree, on AC):

| schedule | mode | pairs | pair values | estimate | verdict |
| --- | --- | ---: | --- | ---: | --- |
| `15/F18` | quick | 2 | not recorded | **+1.13%** | `inconclusive` |
| `15/F18` | confirm | 2 | +1.60%, +1.30% | **+1.45%** | `inconclusive` |
| this, quick | quick | 2 | +0.94%, +1.66% | **+1.30%** | `inconclusive` |
| this, confirm | confirm | 2 | +0.93%, +1.13% | **+1.03%** | `inconclusive` |

The frozen rules the estimates were graded against, read from each run's
`decisionRule`:

| mode | `terminal-feed` directional threshold | equivalence band | pair count |
| --- | ---: | ---: | ---: |
| quick | 4.5% | 1.0% | 2 |
| confirm | 2.5% | 0.75% | 2 |

- Observation 1: **all four estimates land between +1.03% and +1.45%**, and all
  six recorded pair values are positive (+0.93% to +1.66%). The point estimate
  is stable across two candidate trees, two power states, and two sessions.
- Observation 2, and it is the finding: **that band is exactly the harness's
  dead zone for this workload.** At `confirm` the estimate must clear 2.5% to
  read `slower` or fall inside 0.75% to read `equivalent`; ~+1.0-1.45% does
  neither, by construction. `terminal-feed` is also the only workload whose
  `confirm` pair count is 2 rather than 4-6, so escalation buys a tighter
  threshold but no extra pairs.
- Inference 1: **the escalation ladder is exhausted for this question.** The
  frozen protocol offers `quick` then `confirm`, both have been run validly
  twice each, and re-running is shopping, which the protocol forbids. There is
  no third mode. A `faster`/`slower`/`equivalent` verdict for the trim's feed
  effect is not obtainable from the calibrated ladder at this effect size, and
  that is a measured conclusion rather than a missing run.
- Inference 2, on what may honestly be said: the protocol's own rule is that
  neither mode can license "no regression", only "no regression above my
  threshold". So the defensible statement is: **admission-time trimming costs
  no more than ~2.5% on the feed path, with a consistent point estimate near
  +1%, direction slower.** The shipped plan's `AR2` neutrality assumption is
  neither confirmed nor refuted; it is unmeasurable at this resolution.
- Competing interpretations:
  1. The ~+1% is a real, small cost of trimming on admission (the mechanism is
     plausible: the trim does per-row work at eviction time that the seam did
     not). Favored by six of six pairs being positive.
  2. The ~+1% is arm-level bias that position balancing did not fully cancel.
     Weakened but not eliminated by reproduction across two candidate trees and
     two power states.
  3. Part of the ~+1% belongs to the 15 commits in `dd51a12..HEAD` rather than
     to the trim. Weakened by the source audit above -- but `15/F18` measured
     the same band with *none* of those commits present, which is the strongest
     evidence against this reading and for the effect being the trim's own.
- Uncertainty: no calibrated instrument in this repo resolves a 1% effect on
  `terminal-feed`. Closing this properly would require a screening pass that
  buys more pairs for `terminal-feed` (the mechanism
  `scripts/terminal-benchmark-candidate-screen.py` exists for, searching pair
  count alongside threshold), which is a tooling decision, not a rerun.
- Next action: none for the trim -- treat the feed cost as bounded above by
  2.5% and stop measuring it with this ladder. `F2` is the live thread out of
  this run and it is unrelated to the trim.

### F2 -- the same confirm run reported every non-feed workload `slower`; this is NOT the trim and NOT a verdict

- Status: recorded as a **flagged observation, deliberately not a verdict.**
  Raised here because it appeared in `F1`'s invocation and would otherwise be
  lost, not because this doc owns it. Nothing in this doc's hypotheses depends
  on it. **Do not cite these numbers as a regression claim.**
- Date and investigator: 2026-08-03, Claude (agent).
- Commit, worktree, command, and artifact: identical to `F1`'s confirm run --
  `just benchmark-confirm baseline=fa01b66`, artifact
  `.build/terminal-benchmark-comparisons/confirm/9dbdb3aa1fc8-0000/run.json`.
- Measurements (the four non-feed workloads of the same invocation):

  | workload | verdict | estimate | pairs | pair values |
  | --- | --- | ---: | ---: | --- |
  | `content-churn` | `slower` | +4.02% | 4 | +1.26, +3.46, +4.58, +6.19 |
  | `style-churn` | `slower` | +3.47% | 4 | +3.36, +4.56, +2.55, +3.57 |
  | `incremental-mixed` | `slower` | +7.96% | 6 | +11.88, +0.40, +7.34, +8.58, +12.47, +1.82 |
  | `scrollback-stream` | `slower` | +4.46% | 4 | +4.39, +4.53, +4.34, +9.01 (1 flagged outlier, retained) |

  Auxiliary lines, all uncalibrated and decision-free: plan time -0.19%
  (`content-churn`), +0.02% (`style-churn`), +5.38% (`incremental-mixed`);
  process CPU -0.25%, -1.06%, -3.91% on the same three.

- **Why this is not a verdict.** The protocol's stated conditions require the
  machine to be otherwise idle, because competing load biases both arms
  unequally. It was not: during and after the run, `uptime` reported load
  averages of 4.73 / 5.89 / **8.92** (1/5/15 min), with `WindowServer` at
  44-49% CPU, a second agent session at ~17%, and `node` at ~11%. The harness
  does not gate on host load -- `invalidations` and `invalidationReasons` are
  both empty and the run self-reports `decisionEligible: true` -- so **the
  instrument cannot see this violation and reported a verdict anyway.** That
  gap is itself the durable content of this entry.
- **Why it is also not dismissible as load.** The schedule is
  position-balanced, which cancels monotonic drift, and 20 of 20 pairs across
  four workloads are positive. Bursty competing load raises variance and can
  bias, but the uniform sign is not the signature of noise. The wide dispersion
  on `incremental-mixed` (+0.40% to +12.47%) is, however, exactly the signature
  of a contaminated measurement.
- Observation: process CPU moved *down* (-0.25% to -3.91%) on the same three
  workloads whose draw time moved up. Per the protocol's `17/D6` rule, a
  co-movement may be used to undermine a draw verdict but never to confirm one;
  here the two metrics move in *opposite* directions, which is a reason to
  distrust the draw verdicts further, not less.
- Inference: whatever this is, **it is not the retained-row trim.** The trim is
  a scrollback-storage change on the admission path; `content-churn` and
  `style-churn` replay 50 serialized full-screen frames and never build deep
  history. The 15 commits in `dd51a12..HEAD` contain the far more plausible
  candidates, and they are draw-path by construction: the sparse-damage
  preservation and coalescing work (`d378096`, `f3c774d`, `24c3d03`,
  `3fbd487`) and, notably, the instrumentation added *to the accepted-draw
  path* (`13f82c8` records sparse-span topology on accepted draws, `de377f1`
  publishes foreground and presentation coverage). Doc 28's own
  measurement-machinery rule exists for precisely this failure mode, and
  `6747e82`/`2eaac68` are the prior incidents of it.
- Competing interpretations, unresolved and roughly equally weighted:
  1. A real draw-path regression somewhere in `dd51a12..HEAD`.
  2. Benchmark instrumentation added since `fa01b66` billing itself to the path
     it observes -- the standing incident, recurring.
  3. Host-load contamination inflating all four estimates.
- Uncertainty: high, and it is not reducible by re-running under the same
  conditions. The isolating measurement is a confirm against a **nearer
  baseline** -- `dd51a12`, or each renderer commit in turn -- on a genuinely
  idle machine. That separates "the trim" from "everything after it" and, run
  against `13f82c8~1`, separates the app from its instrument.
- Next action: **not this doc's, and not this session's.** Recorded and flagged
  for the user. Doc 29 (sparse AppKit damage clip topology) and doc 30 (clip
  construction mechanics) own the renderer commits in this range; whichever
  picks it up should start from the `dd51a12` baseline above. No fix should be
  attempted before the isolating run exists.
