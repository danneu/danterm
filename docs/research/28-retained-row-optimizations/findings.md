# Findings -- append-only evidence chain

Next free ID: **F6**. Inherited baseline: `15/F18` -- the compact retained-row
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
- **Resolved by `F3`.** The isolating run was taken; three of the four `slower`
  verdicts did not survive it. Read `F3` before citing anything above.

### F3 -- the isolating run: three of `F2`'s four `slower` verdicts were baseline-width artifacts, and one survives

- Status: recorded. **Resolves `F2`** and refines `F1`'s competing
  interpretations. Closes the `F2` follow-up task.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: baseline `dd51a12` (compact retained-row storage,
  i.e. the trim itself), tree `a73d8c5b1628bf44ec5e8e3dd4457059aaa3eca1`.
  Candidate base `30ecfab`, candidate tree
  `61df251a49d5339a3f24ab4e7c8cef1e7bdc46dc`, same five untracked prose paths
  as `F1`. Command: `just benchmark-confirm baseline=dd51a12`. Artifact:
  `.build/terminal-benchmark-comparisons/confirm/61df251a49d5-0000/run.json`.
- Why this baseline: `F2`'s run spanned `fa01b66..HEAD`, which contains both
  the trim and 15 later commits. Moving the baseline to `dd51a12` removes the
  trim from the range, so this run measures **only** the post-trim renderer and
  instrumentation work. Comparing the two runs attributes each signal to one
  side or the other.
- Conditions: AC power, no thermal or performance warning. Pre-run host load
  was driven down from 5.52 to a plateau of ~2.4 by idling this session for six
  minutes before launch (samples: 4.82, 4.69, 4.18, 3.63, 3.41, 3.24, 2.83,
  2.90, 2.63, 2.24, then 2.37-3.11 for a further three minutes). That is this
  machine's floor with the user's desktop running; `WindowServer` alone holds
  ~45% and did not go quiet.

#### The two runs side by side

| workload | vs `fa01b66` (`F2`) | vs `dd51a12` (this) | survives? |
| --- | --- | --- | --- |
| `terminal-feed` | +1.03% inconclusive | **-0.69% equivalent** | no |
| `scrollback-stream` | +4.46% **slower** | **-0.11% equivalent** | **no** |
| `content-churn` | +4.02% **slower** | **+1.48% inconclusive** | **no** |
| `style-churn` | +3.47% **slower** | **+3.09% slower** | **yes** |
| `incremental-mixed` | +7.96% **slower** | +2.95% slower | see below |

Pair values, this run: `terminal-feed` -0.85, -0.52; `scrollback-stream` -2.92,
+0.25, -0.46, +2.53; `content-churn` +2.71, +0.65, +2.32, +0.50; `style-churn`
+3.13, +4.06, +3.05, +2.53; `incremental-mixed` +6.92, -4.93, -8.03, +2.61,
+8.95, +3.30.

- Observation 1: **`scrollback-stream` and `content-churn` collapsed.** A
  +4.46% `slower` became `equivalent` at -0.11% with sign-mixed pairs, and
  +4.02% became `inconclusive`. Neither signal is attributable to the post-trim
  commits.
- Observation 2, and it disqualifies one of `F2`'s four: **`incremental-mixed`
  is noise-dominated.** Its six pairs run -8.03% to +8.95% with mixed signs.
  The median crosses the 1.85% threshold and the harness prints `slower`, but a
  sign-mixed series with a 17-point spread is not a directional result. The
  protocol already flags this workload as the noisiest on the ladder.
- Observation 3, the survivor: **`style-churn` reproduces.** +3.47% against
  `fa01b66` and +3.09% against `dd51a12`, with tight, uniformly positive pairs
  (+2.53% to +4.06%) in both runs. Nearly identical estimates across the two
  baselines place the cost in `dd51a12..HEAD`, not in the trim.
- Inference 1, refining `F1`: `terminal-feed` reads **-0.69% equivalent**
  across the post-trim range, so the persistent ~+1% of `F1` sits in
  `fa01b66..dd51a12` -- the trim itself. This **strengthens `F1`'s competing
  interpretation 1** (a real, small admission cost of trimming) and
  **effectively eliminates interpretation 3** (that the ~+1% belonged to the
  later commits). `F1`'s bound is unchanged and no verdict becomes available;
  only the attribution sharpens.
- Inference 2: `F2` was mostly an artifact of a 15-commit-wide baseline
  compounded by host load. Three of four verdicts vanished under the correct
  adjacent baseline. **A wide-baseline comparison is a smoke alarm, not a
  diagnosis** -- it says "something in this range", and only a narrower baseline
  says what.
- Inference 3, on why the wide run was still worth taking: per-commit A/B
  cannot see accumulation below its own threshold. `F1` established that
  `terminal-feed` cannot resolve ~1% and cannot buy extra pairs, so fifteen
  consecutive 1% regressions would each read `equivalent`/`inconclusive` while
  the range total reached ~16%. The wide baseline is the only instrument on the
  ladder that detects sub-threshold drift. It should be run periodically, never
  as a decision instrument.
- **Instrumentation note, and it changes the guard design.** Host load was
  sampled every 5 s across this invocation: it rose monotonically from 3.23 at
  launch to 9.68 at the end (n=51, median 3.80). That rise is the benchmark's
  own builds and GUI app, not competing load. **Load average measured during a
  run is therefore confounded by the run itself and cannot serve as an
  idleness gate.** A usable guard has to sample before launch, or exclude the
  harness's own process tree. This is the concrete input to `D1`'s guard pitch.
- Competing interpretations for the `style-churn` survivor, unresolved:
  1. Real cost in the sparse-damage renderer work (`d378096`, `f3c774d`,
     `24c3d03`, `3fbd487`).
  2. Benchmark instrumentation added to the accepted-draw path (`13f82c8`,
     `de377f1`) billing itself to what it observes -- doc 28's
     measurement-machinery rule recurring, with `6747e82`/`2eaac68` as
     precedent. `style-churn` freezes text and varies only attributes, so a
     fixed per-accepted-draw cost is a larger share of its smaller frame.
  3. Residual host load. Weakened: the pairs are tight and uniformly positive
     across two independent runs at different baselines.
- Uncertainty: this run did not bisect, so `style-churn`'s ~3% is not yet
  attributed between the renderer work and its instrumentation. That bisect is
  one confirm against `13f82c8~1`, which separates the app from its instrument
  in a single run.
- Next action: hand the `style-churn` survivor to the renderer docs (29/30)
  with the `13f82c8~1` bisect named above. **Not this doc's to fix**: if the
  cause is the renderer work it belongs to their owners, and this session
  stopped short of the bisect rather than guess. `D1` carries the idleness-guard
  pitch and the `terminal-feed` screening question.

**The bisect named above was run; see `F4`.** It closes interpretation 2:
`13f82c8..HEAD` is a 4.05% *speedup* on `style-churn`, so the instrumentation
cannot explain the survivor, and the cost localizes to `dd51a12..e4556c0`.

### F4 -- the named bisect exonerates the instrumentation: `style-churn` is 4% *faster* since `13f82c8~1`, so `F3`'s survivor predates it

- Status: recorded. Resolves `F3`'s open attribution and closes interpretation 2
  (benchmark instrumentation on the accepted-draw path). The residual cost is
  handed to docs 29/30 unfixed, per this doc's boundary.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: baseline `13f82c8~1` = `e4556c0`, commit
  `e4556c035168db8524f08fe4cde8b560007423af`, tree
  `368def17e75ac2169319efdc1f03a173978650bc`. Candidate base `b332843`,
  candidate tree `e05aa52ff89ebaccccb460c190014fcce159eabd`, capturing five
  untracked prose paths (`TODO.md` and four `plans/wip/*.md`), none reachable
  from any measured binary.
- Why this baseline is the one that separates app from instrument: all four
  sparse-damage renderer commits (`d378096`, `f3c774d`, `24c3d03`, `3fbd487`)
  are *already in* `e4556c0`. So this run holds the renderer work fixed on both
  arms and varies only `13f82c8` onward -- the accepted-draw topology recorder,
  the coverage publication, and the two later repairs to it.
- Method: `just benchmark-confirm baseline=13f82c8~1`, one invocation, no
  reruns. `decisionEligible: true`, `invalidationReasons: []`. Conditions: AC
  power (100%, charged), no `DANTERM_BENCHMARK_ALLOW_BATTERY` override, 179x66.
- Pre-launch host reading, recorded because `F3` made it a stated obligation:
  load 2.88/3.47/4.24 at 14:06:02, `WindowServer` at 1.2%, no second agent
  session, and a transient `signpost_reporter` burst (27% CPU, load ~4.4) waited
  out before launch. This is within 0.5 of the ~2.4 floor `F3` established for
  this machine.
- Results:

  | workload | verdict | estimate | pairs |
  | --- | --- | ---: | --- |
  | `terminal-feed` | equivalent | -0.26% | -0.09, -0.44 |
  | `scrollback-stream` | equivalent | -0.18% | -1.20, +3.41, -2.17, +0.83 |
  | `content-churn` | **faster** | **-4.46%** | -3.54, -4.86, -4.06, -5.77 |
  | `style-churn` | **faster** | **-4.05%** | -6.32, -0.84, -3.31, -4.78 |
  | `incremental-mixed` | inconclusive | +1.29% | +12.02, -18.53, -8.80, +7.79, +14.92, -5.21 |

- Observation 1, and it is the finding: **`style-churn` is 4.05% faster at
  `HEAD` than at `13f82c8~1`, on four of four pairs, all negative.** A range
  that is a net speedup cannot be the source of a regression measured at its
  own endpoint. `13f82c8`'s accepted-draw instrumentation is therefore **not**
  the explanation for `F3`'s +3.09%, and this doc's measurement-machinery rule
  did **not** recur. `F3`'s interpretation 2 is closed.
- Observation 2, mechanism, and it agrees: a source audit of `13f82c8` reaching
  `HEAD` shows `TerminalBenchmarkSparseSpanRecorder.init?(workload:)` returns
  nil for every workload but `sparse-spans-few`/`-max`, and every added site in
  `app/TerminalBenchmark.swift` is guarded by `sparseSpanRecorder != nil` or
  `?.`. What `style-churn` actually gained is two nil checks and one restructured
  branch. The commit's own claim -- "nothing here runs for the other five
  workloads" -- is what the measurement independently found.
- Observation 3: `content-churn` is also 4.46% faster over the same range, on
  four of four negative pairs. Two independent draw workloads agreeing in
  direction and magnitude points at a shared draw-path improvement in
  `13f82c8..HEAD`; the strongest candidates are `6747e82` and `2eaac68`, which
  are precisely the two commits that moved earlier instrumentation *off* the
  draw path. That is this doc's measurement-machinery rule paying out rather
  than being violated. Not claimed as attributed -- no run isolates it.
- Inference, and it is cross-run rather than a verdict: `F3` measured `HEAD`
  +3.09% against `dd51a12`; this run measures `HEAD` -4.05% against `e4556c0`.
  Composing them localizes the regression to **`dd51a12..e4556c0`** -- the four
  sparse-damage renderer commits plus `e4556c0`'s benchmark-only stimulus.
  Stated as an inference, deliberately: the two runs are separate invocations on
  separate hosts-in-time, and the protocol does not let a difference of
  differences carry a verdict. The *within-run* claim -- that `13f82c8..HEAD`
  contains no `style-churn` regression -- needs no composition and is what
  Observation 1 rests on.
- Uncertainty: the residual cost is localized to a five-commit range, not to a
  commit. A confirm against `d378096~1` would bound the renderer work's own
  contribution, and one against `3fbd487` would separate the coalescing change
  from the sharing refactor. Neither was run: attributing renderer cost is not
  this doc's, and guessing between four commits is not evidence.
- `incremental-mixed` remains sign-mixed (+14.92 to -18.53 here, -8.03 to +8.95
  in `F3`) and is again not directional. `F3`'s disqualification holds across
  both runs; the harness classified it `inconclusive` here, which is the right
  answer for this stimulus.
- **For docs 29/30's owners, flagged:** the shipped sparse-damage renderer work
  carries a `style-churn` cost of roughly 3-7% that survived two independent
  confirm runs at two baselines. It is not an artifact of the benchmark's own
  instrumentation -- that hypothesis was tested here and failed. Doc 29 records
  the sparse-clip work as shipped on the strength of the btop-scroll result;
  this is the counterweight on the styled-attribute workload, and neither doc's
  outcome currently names it. The +3.09% endpoint figure likely **understates**
  the `dd51a12..e4556c0` effect, because the commits after `e4556c0` netted a
  speedup on this same workload, so the renderer range's own cost is partly
  masked at HEAD; a single `confirm` of `dd51a12` against `e4556c0` is the run
  that would size it directly, and that run is doc 29's owner's to make.
- Next action: none in this doc. `D1`'s admitted items proceed; the renderer
  attribution is handed over with the range and the two bounding runs named
  above.

### F5 -- the browsing workload screens as the quietest on the ladder, and one screen is not graduation

- Status: recorded. Implements and screens `D1` pitch 1. The workload is
  **admitted as a candidate**; no threshold was frozen and none may be until a
  second independent screen agrees, per `D1`'s own gate.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: screened at tree
  `8eca2daf7b09aba5700662f1280ca27733017ad7` (`415fbd1`, the commit that adds
  the workload). Both physical arms bound to that one immutable root, so every
  measured difference is noise by construction.
- Conditions, sampled before launch: AC power (100%, charged), load
  2.62/4.36/4.38 at 14:26:00, falling to 2.39 during collection -- the quietest
  this machine reached all session, against the ~2.4 floor `F3` established.
- Method: `scripts/terminal-benchmark-candidate-screen.py --workload
  retained-browse --revision HEAD`, 12 balanced ABBA/BAAB quartets, 50,000
  resampling trials per condition, seed 20260730. Pair count searched
  cheapest-first alongside the threshold -- which `17/F15` records an auxiliary
  metric cannot do and a workload can, because it owns its blocks. **12 of 12
  quartets kept, 0 discarded.**
- The stimulus, resurrected from `15/F18` rather than reinvented: 179x66, 10,000
  short hard-terminated lines, viewport parked at the oldest retained row (6,756
  rows survive the production budget), 20 warm and 2,000 measured `planFrame`
  calls per block, with a cell-coverage checksum that invalidates the whole
  invocation if two arms did not plan the same frame.
- A/A spread: **24 pairs, median +0.19%, SD 0.99% (trimmed 0.90%, 22 pairs),
  range -1.42%..+2.00%.** No pair required discarding and no outlier drove the
  spread -- contrast `20/F11`'s screen 1, where one block of 24 set the SD and
  had to be thrown out.
- Proposed cells, neither frozen:

  | mode | pairs | threshold | A/A false positives | detection (+/-) | wrong direction |
  | --- | ---: | ---: | ---: | --- | ---: |
  | quick | 2 | +/-1.05% | 0.0000 | 1.0000 / 1.0000 | 0.0000 |
  | confirm | 2 | +/-1.05% | 0.0000 | 1.0000 / 1.0000 | 0.0000 |

- Observation 1, and it is the finding: **this is the cheapest and tightest cell
  any workload on the ladder has produced.** `confirm` would decide on 2 pairs at
  +/-1.05% where `style-churn` needs 4 at 2.00%, `scrollback-stream` 4 at 1.85%,
  and `incremental-mixed` 6 at 1.85%. The mechanism is not subtlety, it is
  scope: this workload is headless. No window, no compositor, no PTY, no
  WindowServer -- and `F2`/`F3` established that those are where the ladder's
  noise lives.
- Observation 2, and it is the caveat the table above does not show:
  **`confirm`'s A/A `inconclusive` rate is 41.4%.** `select_candidate` applies
  `maximum_inconclusive_rate` to the effect conditions only, never to A/A, so
  that number is real and ungated. In practice a genuinely equivalent change
  would read `inconclusive` two times in five at the selected `confirm` cell,
  because the 0.75% band and the 1.05% threshold leave a narrow dead zone that a
  2-pair median lands in often. `quick`'s equivalent figure is 8.2%. This is the
  same structural dead zone `F1` hit on `terminal-feed` -- there it was fatal
  because escalation could not buy pairs; here it is not, because this workload
  owns its blocks and a screen may propose 4.
- Inference: if a second screen replicates, the honest rule to freeze is
  probably **not** the cheapest cell. Buying the next pair count up would trade
  machine time for a much lower A/A inconclusive rate, and `20/F11`'s precedent
  is to take the conservative envelope across replicates rather than the
  cheapest single result. That is a decision for whoever runs screen 2, stated
  here so it is not re-derived.
- Uncertainty, and it is the reason nothing is frozen: **one screen cannot
  distinguish an unlucky series from an unstable workload.** `20/F11` is the
  precedent and it is not hypothetical -- its screen 1 proposed 12 pairs and its
  screens 2 and 3 proposed 6 and 4 at three times the threshold. `D1` requires
  two independent screens clearing A/A false positives under 1% at 90%
  detection; this is screen 1 of 2. Until screen 2 lands, every browsing claim
  in this doc stays a paired descriptive measurement, exactly as `15/F18`'s was.
- Sanity check against the result being replaced: this harness measures 342,263
  ns per browsing frame plan at 300 measured calls, against `15/F18`'s 319,461
  ns candidate median. Same regime, so the resurrected recipe is measuring the
  quantity the deleted probe measured. The line content differs slightly (the
  payloads are not byte-identical), so the two numbers are not directly
  comparable and no comparison is claimed.
- Next action: run screen 2 on an independent occasion. If it replicates, freeze
  the conservative envelope across both, move `retained-browse` from
  `CANDIDATE_WORKLOADS` into `WORKLOADS`, and add its rule to `DECISION_RULES`.
  Only then can `H1`, `H3`, `H4`, and `H5` end in a verdict.
