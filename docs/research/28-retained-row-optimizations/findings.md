# Findings -- append-only evidence chain

Next free ID: **F12**, which Phase 2's open resize-profile task claims (it was
written down as `F11` before this entry existed; IDs go in the order findings are
recorded, not in the order tasks were listed). Inherited baseline: `15/F18` -- the compact retained-row
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

### F6 -- screen 2 replicates, quieter than screen 1, and the browsing workload graduates

- Status: recorded. This is the second independent screen `D1` pitch 1 required,
  and it clears the gate. The freeze itself is `D2`; this entry is the evidence
  under it.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: screened at tree
  `19442eaf843050b060d0f5011109417c25a6cd79`, whose base is `e036521` (the
  preflight-annotation commit). Both physical arms bound to that one immutable
  root, so every measured difference is noise by construction. Screen 1 ran at
  tree `8eca2daf7b09` (`415fbd1`).
- Independence, stated because it is the whole claim: a **separate invocation**,
  at a different tree, 16 minutes later, after the host had been allowed to
  settle back to its floor. That is the standard `20/F11`'s replicating screens
  2 and 3 met -- separate invocations on one machine, trees differing only in
  script-level code the measured binary does not contain. It is not a different
  machine or a different day, and the Uncertainty bullet below says so.
- Conditions, and this is the **preflight's first real consumer**: the screen now
  records them itself rather than leaving them to prose. At invocation, load
  2.22/3.81/3.76 (0.22 per processor across 10), busiest external `claude` 18.8%,
  `node` 13.1%, `com.apple.DriverKit-AppleBCMWLAN` 12.0%. Before the first block,
  load 2.28/3.48/3.63, busiest external `claude` 7.7%. Both readings sit within
  0.2 of the ~2.4 floor `F3` established for this machine. AC power, 100%,
  charged. The readings live in `candidate-screen.json` under `hostConditions`;
  no threshold was applied to them, per `D1` pitch 4.
- Method: `scripts/terminal-benchmark-candidate-screen.py --workload
  retained-browse --revision HEAD`, 12 balanced ABBA/BAAB quartets, 50,000
  resampling trials per condition, seed 20260730 -- **identical to screen 1**.
  The seed is deliberately unchanged: a different one would confound "different
  data" with "different resampling", and the independence being tested is
  physical collection, not the resampler. **12 of 12 quartets kept, 0 discarded**,
  as in screen 1.
- Results, against screen 1:

  | screen | pairs | median | SD | trimmed SD | range | quick | confirm |
  | --- | ---: | ---: | ---: | ---: | --- | --- | --- |
  | 1 (`8eca2daf7b09`) | 24 | +0.19% | 0.99% | 0.90% | -1.42 .. +2.00 | 2p @1.05% | 2p @1.05% |
  | 2 (`19442eaf8430`) | 24 | -0.06% | 0.51% | 0.33% | -1.33 .. +1.45 | 2p @1.05% | 2p @0.80% |

- Observation 1, and it is the finding: **the screens replicate, and screen 2 is
  the quieter of the two** -- SD 0.51% against 0.99%, trimmed 0.33% against
  0.90%, median a third the size and of the opposite sign. Both propose the same
  `quick` cell outright. Neither discarded a quartet, and neither has an outlier
  doing the work: this is `20/F11`'s screen-1 failure mode *not* occurring,
  twice. A/A false positives are 0.0000 and detection 1.0000/1.0000 at every
  cell either screen proposes.
- Observation 2, and it is why the freeze is not the cheapest cell: the two
  screens **disagree on `confirm`'s threshold** -- 1.05% against 0.80% -- because
  screen 2's tighter spread lets a tighter threshold clear. Taking screen 2's
  0.80% would be fitting the rule to the quieter of two samples. `20/F11`'s
  precedent is the conservative envelope across replicates (max pair count, max
  threshold), which is 1.05%.
- Observation 3, the dead zone, re-measured at the frozen cell: `F5` reported
  `confirm`'s A/A strict-`inconclusive` rate at 41.4% on 2 pairs, and that
  reproduces exactly. Buying one pair-count step drops it to **28.4%** at 4
  pairs and 20.5% at 6. It never reaches zero at any pair count, and the reason
  is structural rather than statistical: `confirm`'s equivalence band is 0.75%
  and the envelope threshold is 1.05%, so a true difference inside that
  0.30-point gap is unclassifiable by construction. This is the same gap that
  made `F1`'s feed verdict unobtainable. On screen 2's own series the rate is
  0.0% at every cell -- its spread is entirely inside the band -- which is
  precisely why one screen could not have established this.
- Observation 4: `quick`'s dead zone is narrow by comparison (band 1.0% against
  threshold 1.05%) and its A/A strict-`inconclusive` rate is 8.2% at 2 pairs on
  screen 1, already inside the standard 10% gate. `quick` therefore freezes at
  the cheapest cell and `confirm` does not; the two modes are treated differently
  because their bands differ, not by preference.
- Uncertainty: two screens, one machine, one afternoon, roughly 20 minutes apart.
  That is the same exposure `20/D4` accepted for `synchronized-frames` and it
  carries the same limit -- neither screen samples a different thermal state, a
  different macOS build, or a different background population. What the pair
  does rule out is `20/F11`'s screen-1 failure: a single unlucky series
  masquerading as a workload property.
- Next action: `D2` freezes the envelope. `H1`, `H3`, `H4`, and `H5` may now end
  in a browsing verdict rather than a descriptive measurement.

### F7 -- a saturated 179-column history resizes in ~98 ms, and the two directions are separable

- Status: recorded, **descriptive by decision**. `D1` pitch 2 froze this as a
  probe rather than a candidate workload, so there is no threshold here, no
  second arm, and no verdict -- including no frame-budget verdict. That reading
  is `H1`'s to make in Phase 2.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: run at `e036521` plus the uncommitted probe sources
  this finding introduces (`lib/TerminalCore/Sources/TerminalResizeProbe*`,
  `just terminal-resize-probe`). Release configuration, headless, no window.
- Conditions: AC power, 100%, charged. Load 2.66/5.04/4.49 at 14:52, within
  0.3 of the ~2.4 floor `F3` established. A first run taken at load 11.17 --
  immediately after the probe's own release build -- produced a median of 99.03
  ms against this run's 97.98 ms, and is reported here rather than discarded
  because a 1% shift under 4x the load is itself the useful observation about
  how load-sensitive this measurement is.
- The recipe, stated because `D1` pitch 2 made stating it a condition of freezing
  it: identity `saturated-resize-v1-10000-lines-179x66-to-100`. 179x66, 10,000
  short hard-terminated ASCII lines, production scrollback budget (10,485,760
  bytes), **6,756 rows retained** after eviction and after the warm resizes, 4
  untimed warm resizes, 40 timed samples alternating 179 -> 100 -> 179.
- Distribution, which is what the probe reports instead of a number:

  | quantity | value |
  | --- | ---: |
  | samples | 40 |
  | minimum | 95.77 ms |
  | median | 97.98 ms |
  | p90 | 99.67 ms |
  | p99 / maximum | 101.38 ms |
  | mean | 97.97 ms |

- Observation 1: **the distribution is tight.** Max/min is 1.059 -- the whole
  spread of 40 samples is under 6%, with no tail and no outlier. Whatever a
  saturated resize costs, it costs it consistently, which is the property that
  makes a 40-sample probe adequate here and would not have been safe to assume.
- Observation 2, and it is the part a single number would have hidden: **the two
  directions separate cleanly.** Narrowing 179 -> 100 has a median of 96.52 ms
  (20 samples, 95.77-98.11); widening 100 -> 179 has a median of 99.33 ms (20
  samples, 97.72-101.38). The two sub-distributions barely overlap. The pooled
  median sits between them and describes neither. Recorded, not explained --
  attributing the ~2.8 ms difference is `H1`'s Phase 2 work, and the direction is
  the opposite of the naive expectation stated in the recipe's own comment (that
  narrowing, which reflows, would be the expensive one).
- Observation 3: 6,756 retained rows survive the budget here, against the 6,756
  `F5`'s browsing workload reports at the same geometry and payload. The two
  measurements are looking at the same history, which is why the stimulus was
  copied rather than reinvented.
- Uncertainty: one machine, one occasion, one geometry, one alternate width.
  Nothing here measures 80 columns, a partially-filled history, or a resize
  concurrent with feed -- and nothing here decomposes the ~98 ms into reflow,
  allocation, and eviction, which is the second half of `H1`'s question. The
  probe is committed and re-runnable, so those are runs rather than
  reconstructions.
- Next action: Phase 2's `RESEARCH` task reads this distribution against a frame
  budget and against a profile. Nothing in this entry does either.

### F8 -- stored cell bytes dominate at both widths: per-row overhead is ~10.5%, and it does not vary with pane width

- Status: recorded. This is Phase 2's H3-vs-H4 gate input, and it selects.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: `51927ce`, clean tree apart from five untracked
  prose paths. Release configuration, headless.
- Method: `just terminal-memory-probe "--json --payload scrollback-plain"` at
  179x66, and the same binary at `--columns 80 --rows 24`. Two numbers per width,
  from two different instruments deliberately: `census.cellStorageBytes` is
  **exact** (a sum over rows of `cells.count * MemoryLayout<GridCell>.stride`),
  and the attributable total is the malloc `bytesInUse` delta across the feed,
  which **includes** array headers and bucket rounding. The residual between them
  is therefore the per-row fixed overhead the census cannot see -- which is
  exactly the split this task asked for, and the reason the census documents
  itself as excluding those terms rather than absorbing them.
- Results:

  | quantity | 179x66 | 80x24 |
  | --- | ---: | ---: |
  | attributable (malloc `bytesInUse` delta) | 11,000,160 B (11.00 MB) | 10,667,424 B (10.67 MB) |
  | stored cell bytes (exact) | 9,842,016 B (**89.5%**) | 9,525,408 B (**89.3%**) |
  | residual / per-row overhead | 1,158,144 B (**10.5%**) | 1,142,016 B (**10.7%**) |
  | row storage allocations | 5,865 | 5,823 |
  | residual per row allocation | 197.5 B | 196.1 B |
  | retained rows | 5,799 | 5,799 |
  | mean stored cells per row | 52.4 | 51.1 |

- Observation 1, and it is the gate answer: **stored cell bytes dominate,
  roughly 9:1, at both widths.** H3 (store the cells smaller) attacks 89.5% of
  attributable footprint; H4 (fewer, larger allocations) attacks 10.5%. That
  ordering is the same at 80 columns as at 179, which the shipped change's own
  logic predicts -- content dominates the charge now, so depth converges across
  pane widths and so does this split.
- Observation 2, and it is why the residual can be attributed rather than merely
  named: the malloc **block** delta is 5,929 at 179 columns against 5,865 row
  storage allocations, and 5,887 against 5,823 at 80. Sixty-four blocks separate
  them at both widths. Essentially every allocation the payload creates is a row
  array, so the residual is per-row overhead rather than a mixture of that and
  something unmeasured.
- Observation 3, arithmetic that makes the 197 B/row plausible rather than
  merely observed: a mean row holds 52.4 cells at 32 B stride = 1,678 B of
  payload. A Swift array header is 32 B, and macOS malloc's size class above
  1,710 B rounds up by roughly another 100-160 B. The two together land near the
  measured 197 B. Stated as a consistency check, not as an attribution -- nothing
  here measured the size class directly.
- Observation 4, reconciling this with `15/F18` because the two look like they
  disagree and do not: `15/F18` reported per-row overhead **growing by +2.51 MB**
  at 179 columns when compact rows replaced full-width ones. That is a delta
  against a different representation; this is a **share** of the current one.
  Both are true. Compact rows traded a large blank-cell cost for a smaller
  per-row cost and bought 3.41x depth doing it; what remains is 10.5%.
- Inference for the Phase 3 gate: **H3 is the larger target by roughly 9x and
  should be designed first**, and H4's ceiling is now a number rather than a
  suspicion -- 1.16 MB at 179 columns, and only if per-row overhead went to
  *zero*, which no aggregate-storage scheme achieves. H4 as a standalone
  candidate looks hard to justify against that ceiling; composed with H3 (which
  changes what a row costs and therefore what its bucket rounds to) it may still
  earn its place. That adjudication is `D3`'s, not this entry's.
- Uncertainty: one payload (`scrollback-plain`) at two geometries. Real histories
  are not uniformly ~52-cell plain ASCII rows, and the residual per row depends
  on where mean row length falls relative to a malloc size class -- a payload
  whose rows land just above a boundary would show a larger share. Sizing that
  is `F10`'s task (allocator behavior under ragged row sizes), which this
  finding makes concrete rather than speculative. Nothing here measures styled
  or multi-scalar content: `styledCellCount` is 0 and `multiScalarCellCount` is 0
  in both runs, so H3's packing argument is untested against the content that
  would stress it.
- Next action: `F9` (blank-row frequency, H2's ceiling) and `F10` (allocator
  behavior under ragged rows) remain. `D3` gates H3 vs H4 on this split.

### F9 -- retained history holds no blank rows at all across the committed corpus, and H2's ceiling is 0 bytes there

- Status: recorded, and it closes Phase 2's blank-row task. This sizes `H2`; it
  does not decide it, which is `D4`'s job.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: `e1af871`, clean tree apart from five untracked
  prose paths. Release configuration, headless.
- Method: `just terminal-retained-row-probe`. The probe derives each retained
  row's stored extent through the **public** row reader -- canonical form makes
  the stored extent a pure function of observable content -- and every report
  reconstructs `memoryCensus.cellStorageBytes` from those extents plus
  full-width screen rows before any byte below is used. All 39 stimuli
  reconstructed exactly. No engine change; the probe is off every measured path
  by construction (it is not timed and nothing schedules it).
- Corpus, and why it is this corpus: the stimulus bytes are supplied by the
  driver from **already-committed** content -- the five benchmark-corpus
  workloads and all 34 neutral recording fixtures under
  `Fixtures/danterm` (live PTY captures of fish/zsh/bash, several from a real
  user config with Starship) and `Fixtures/alacritty` (pinned upstream captures
  of vim, tmux, htop, git log, shell completion). Recordings replay at the
  geometry they were recorded at. The probe owns no content of its own, so no
  stimulus here was written after the question was asked.
- Results:

  | pool | stimuli | retained rows | blank rows | blank fraction | `H2` ceiling |
  | --- | ---: | ---: | ---: | ---: | ---: |
  | recordings only | 34 | 133 | **0** | **0.00%** | **0 B** |
  | whole corpus | 39 | 4,707 | **0** | **0.00%** | **0 B** |

- Observation 1, and it is the finding: **not one retained row in the corpus is
  blank.** Not in 133 rows of recorded shell and TUI history, not in 4,574 rows
  of generated benchmark history. `H2`'s ceiling on this evidence is exactly
  zero bytes, because the population it proposes to share is empty.
- Observation 2, the instrument's negative control, because a probe that reports
  zero must be shown able to report non-zero: fed a stream alternating content
  and blank lines, the same binary reports 467 blank rows of 935 (49.9%), and
  the unit suite pins that a bare-newline row counts as blank while a
  one-character row -- which stores one cell too -- does not. The zero is a
  measurement, not a broken detector.
- Observation 3, the mechanism behind the zero, which is worth stating because it
  is not a sampling accident: rows reach history by scrolling off the top of the
  live screen, and a blank row only gets there if a session emits blank lines
  *faster than a screenful*. Interactive shells and TUIs leave blank rows on the
  screen, where they are overwritten or redrawn, not in history. The one place
  blank history is easy to produce is a program that prints many blank lines in a
  row, which nothing in the corpus does.
- Observation 4, `H2`'s ceiling stated the way `F8` stated `H4`'s -- best case,
  zero mechanism cost, absolute bytes. Measured at the extreme rather than
  argued: a generated all-blank stimulus (`bound/all-blank-saturation`, reported
  and excluded from both pools, and labelled a bound precisely because it
  flatters `H2` maximally) saturates the 10 MiB budget at **131,072 retained
  rows**, each charging exactly **80 B** (16 B `GridRow` slot + 32 B array header
  + 32 B for its one canonical cell) and each holding a **64 B** malloc block.
  Sharing one storage allocation across all of them reclaims **8,388,544 B
  (8.00 MB, 80.0% of the budget)**. That is the true ceiling, and it is only
  reachable by a history that is *entirely* blank.
- Observation 5, the ceiling between the two extremes, since neither 0% nor 100%
  is a forecast. At the saturation regime `F8` measured, a content row charges
  1,808 B (`10,485,760 / 5,799`, and the model reproduces it exactly:
  16 + 32 + 55 x 32 at the 1,792 B size class). A blank row charges 80 B. So at
  blank fraction `f`, the ceiling is `f x 64 / (f x 80 + (1-f) x 1808)` of the
  budget:

  | blank fraction | `H2` ceiling | share of a 10 MiB budget |
  | ---: | ---: | ---: |
  | 1% | 3.7 KB | 0.036% |
  | 5% | 19.0 KB | 0.186% |
  | 10% | 40.1 KB | 0.391% |
  | 25% | 119.1 KB | 1.16% |
  | 50% | 347.1 KB | 3.39% |
  | 100% | 8.00 MB | 80.0% |

  The curve is convex and nearly flat below 50% for one structural reason:
  **canonical trimming already made a blank row cheap.** A blank row costs 80 B
  against a content row's 1,808 B, so blank rows cannot be a large *byte* share
  until they are an overwhelming *count* share. `H2` is not a small win awaiting
  a better corpus; it is a win the shipped trim already took.
- Inference for the Phase 3 gate: **`H2` is dead on sizing.** Its measured
  ceiling is 0 B, its ceiling at a blank fraction nothing in the corpus
  approaches is tens of KB, and it would still owe an answer to the charge-model
  question the README flags (charging each sharer for shared bytes overstates;
  charging once complicates eviction accounting). Recommending its rejection is
  `D4`'s to make, and this entry does not make it.
- Uncertainty, stated plainly because it is the weak part of this finding: the
  recorded pool is **133 retained rows**. Most recordings never fill a screen,
  and the two that dominate the row count are generated workloads whose templates
  contain no blank lines by construction -- so the whole-corpus 0.00% is a much
  weaker fact than its denominator suggests. What carries the conclusion is not
  the sample but the arithmetic in Observation 5: the ceiling is small at every
  blank fraction a real session could plausibly hold. A corpus of long real
  sessions would sharpen `f`; it could not move the curve. Reopening condition:
  a recorded stimulus whose retained history is more than ~50% blank rows, which
  would put `H2` back above a hundred KB and make the charge-model question worth
  answering.
- Next action: `D4` disposes of `H2` on this evidence. `F10` is the remaining
  Phase 2 sizing.

### F10 -- malloc's size classes are proportional, not quantized, so ragged rows keep their savings: 71.1% on paper, 70.8% realized

- Status: recorded, and it closes Phase 2's allocator task. This is the
  measurement `F8` said would make its stated uncertainty concrete.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: `e1af871`, clean tree apart from five untracked
  prose paths. Release configuration, headless.
- Method: the same run as `F9`. Per retained row the probe computes the real
  request (`32 B array header + storedCells x 32 B stride`) and asks
  **`malloc_good_size`** what the allocator returns for it -- libmalloc's own
  answer, not a size-class table written from memory, which is the same choice
  doc 15's `D4` made when it charged `Array.capacity` instead of predicting
  buckets. The driver independently models the classes in Python and the two are
  compared per stimulus; all 39 agreed. The gate test sweeps the model against
  `malloc_good_size` directly, and that sweep already caught a real divergence
  above the small zone's 32 KB limit (irrelevant to rows, fixed anyway).
- Results, for the stimuli that produce retained history:

  | stimulus | rows | mean stored cells | rounding | paper saving | realized saving | B/row overhead |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: |
  | `reference/scrollback-plain` (`F8`'s payload) | 5,799 | 51.0 | 7.1% | 71.1% | **70.8%** | 160.0 |
  | `benchmark/scrollback-stream` | 2,267 | 134.0 | 6.2% | 25.0% | **25.0%** | 320.0 |
  | `benchmark/unicode-wrapping` | 2,307 | 128.6 | 7.4% | 28.0% | **27.1%** | 364.4 |
  | `danterm/milestone-4-viability` | 55 | 31.7 | 9.6% | 59.7% | **62.4%** | 142.5 |
  | `alacritty/history` | 74 | 4.4 | 2.4% | 94.9% | **95.1%** | 36.3 |
  | pooled (benchmark + recordings) | 4,707 | -- | 6.84% | -- | -- | -- |

  "Paper saving" is ragged storage against full-width storage before either side
  meets the allocator; "realized" is the same comparison after both do.
- Observation 1, and it is the answer to the task's question: **size-class
  rounding does not eat the savings.** The worst gap between paper and realized
  is 0.9 percentage points (`unicode-wrapping`, 28.0% -> 27.1%), and on two
  stimuli the realized saving is *larger* than the paper one -- because the
  full-width row being compared against rounds up harder than the ragged rows do.
  `H3`'s savings survive contact with the allocator.
- Observation 2, the mechanism, and it is why the answer comes out this way
  rather than by luck: macOS malloc's classes above 256 B are **four buckets per
  octave** -- 320/384/448/512, then 640/768/896/1024, then 1280/1536/1792/2048,
  and so on. That is ~12.5% granularity, and it is **geometric, not a fixed
  quantum**. Rounding is therefore proportional to the request: a row that
  shrinks by 60% keeps roughly 60% of that as real bytes, at any size. Had the
  allocator used a flat 512 B quantum in this range -- the shape it is easy to
  assume -- a shrink smaller than 512 B per row would have delivered nothing, and
  the answer to this task would have been the opposite one.
- Observation 3, the consequence for `H3`, stated as a design constraint rather
  than a caveat: **a packing scheme must shrink a row's request by more than one
  bucket step (~12.5%) to be guaranteed to yield any bytes at all.** Below that
  it may round back into the same class and deliver exactly zero, however clean
  the arithmetic looks. Above it, savings scale. `15/H6`'s packing proposals
  (packed scalars, run-length styles) target multiples of that step, so this is a
  floor `H3` clears rather than a wall it hits -- but it is a floor any specific
  `H3` design has to be checked against before it is built.
- Observation 4, ragged rows do **not** fragment: rounding costs 6.2%-9.6% of
  allocated bytes across stimuli whose stored extents range from 1 to 179 cells,
  with 29 distinct lengths in `unicode-wrapping` and 25 in
  `milestone-4-viability`. Uniform-length `scrollback-plain` sits at 7.1%, in the
  middle of that band. Variety in row length is not what drives the overhead;
  where the mean length falls inside its octave is.
- Observation 5, reconciling with `F8`, which measured this residual by a
  completely different route and left it as a "consistency check, not an
  attribution". `F8` reported 197.5 B of per-row overhead at 179 columns from a
  malloc `bytesInUse` delta. Replaying its exact payload here: every row stores
  51 cells, requests 1,664 B, and gets the 1,792 B class -- **32 B header +
  128 B rounding = 160.0 B per row**, uniform. The model reproduces `F8`'s census
  exactly (retained 9,463,968 B + screen 66 x 179 x 32 = 9,842,016 B, matching to
  the byte) and accounts for 10,797,312 B of `F8`'s 11,000,160 B attributable
  total -- **98.2%**. The remaining 202,848 B is ~37 B per row that the row
  arrays do not explain: history's own buffer holds a 16 B `GridRow` slot per row
  plus its capacity slack. So `F8`'s 197.5 B/row is now split: 160 B belongs to
  the row's cell allocation, ~37 B to the container holding the rows. `F8`'s
  guess of "roughly another 100-160 B" of rounding was right at the top of its
  range.
- Observation 6, and it matters for `H4` rather than `H3`: that ~37 B per row is
  **not** reclaimable by `H3` (it is not cell bytes) and only partly by `H4` (an
  aggregate-storage scheme still needs a per-row descriptor). It is 2.0% of a
  saturated 179-column footprint. `F8`'s `H4` ceiling of 1.16 MB stands; this
  finding says where about a fifth of it lives.
- Uncertainty: one allocator on one platform, which is the only one DanTerm ships
  on -- but the class ladder is a libmalloc implementation detail, not a
  contract, and a future macOS could change it. That risk is bounded by the fact
  that the *budget* reads `Array.capacity` rather than modelling classes, so the
  charge stays honest even if this model goes stale; only this finding's
  arithmetic would need re-running (`just terminal-retained-row-probe`, which
  compares the model against libmalloc on every run and would show a
  `MISMATCH`). Nothing here measures styled or multi-scalar content beyond what
  `unicode-wrapping` contains, so `H3`'s packing argument remains untested against
  the content that would stress it -- the same gap `F8` named.
- Next action: `D3` gates H3 vs H4 on `F8`'s split plus this finding's
  survival check.

### F11 -- retained rows are ASCII text with occasional long style runs: 22.5% of cells at depth are styled, 0.12% are multi-scalar, and packing prices at 8-16x depth

- Status: recorded, and it closes the evidence gap `F8`, `F10` and `D3` all named.
  This sizes the content `H3`'s packing argument is about; the selection is `D5`'s.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: `34de2e7` plus the probe extension recorded with this
  finding, clean tree apart from untracked prose paths. Release configuration,
  headless.
- Method: `just terminal-retained-row-probe "--saturated"`. The committed shape
  probe gains a third reduction, `RetainedRowComposition`, carried as parallel
  per-row arrays index-aligned with `storedCellCounts`: styled cells, multi-scalar
  cells, empty-scalar cells, scalars, non-ASCII scalars, UTF-8 bytes, style runs,
  distinct styles, wide cells, hyperlink cells, and the widest single-scalar value.
  Composition is read over the **stored prefix only** -- the public row reader
  materializes rows to full width, and counting the trailing default cells would
  report the pane's width rather than the row's content; the unit suite pins that.
  Benchmark-only code, off every measured path: nothing here is timed and nothing
  schedules it. `just test` passes (70 steps).
- Corpus, and the one thing that is new about it: the stimulus bytes are still
  supplied by the driver from **already-committed** content. What is added is a
  `saturated/` variant of each stimulus -- the *same committed bytes* replayed
  until the retained history fills the 10 MiB budget, with the repeat count derived
  from what one pass actually charged. That was necessary because of Observation 1;
  it is pooled separately from the recordings precisely because repetition
  manufactures depth, so it answers "what does this content cost at depth" and is
  **not** evidence about how often such content reaches depth.

#### Observation 1 -- the reason the gap existed: styled content never reached history in one pass

Every styled stimulus in the corpus retains **zero** rows in a single replay.
`styled-screen-redraw`, `incremental-screen-updates`, `synchronized-frames` (btop),
`tmux_htop`, `vim_24bitcolors_bce`, `vim_large_window_scroll`, `vim_simple_edit` --
0 retained rows each, and repeating them to the byte cap leaves them at 0. That is
not a sampling accident and it is the mechanism `F9` observation 3 already
described from the other side: **TUIs paint in place.** They position the cursor
and redraw; nothing scrolls off the top, so nothing is retained. `F8`'s and
`F10`'s zero styled-cell counts were reporting this fact, not missing it.

The styled content that *does* reach history comes from line-oriented output --
shell prompts, `ls` colors, `git log`, completion listings -- which is exactly what
the repeated recordings supply.

#### Observation 2 -- what a retained row is made of

| pool | stimuli | rows | stored cells | styled cells | multi-scalar cells | empty-scalar cells | non-ASCII scalars | wide cells | style runs/row | UTF-8 B/cell |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| recordings (single pass) | 34 | 133 | 2,231 | **1.79%** | 0.00% | 0.81% | 1.36% | 1.61% | 1.03 | 1.017 |
| benchmark + recordings | 39 | 4,707 | 602,663 | 0.01% | 0.42% | 53.08% | 4.41% | 2.53% | 1.00 | 0.526 |
| **saturated replays** | 39 | **94,990** | **2,791,196** | **22.54%** | **0.119%** | 12.36% | **1.32%** | 0.74% | **1.66** | 0.903 |

The saturated pool is the one a packing scheme should be priced against: 94,990
retained rows of committed content at depth, against 133 in the recorded pool.
Four facts carry the design:

1. **Styling is common but extremely runnable.** 22.54% of stored cells at depth
   are styled, yet the mean row holds **1.66 style runs**. A styled row is not a
   confetti of per-cell colors; it is two or three long spans (a prompt segment, a
   filename, a diff line). Run-length styles are not a bet -- they are what the
   content already is.
2. **Content is ASCII.** 1.32% of scalars are non-ASCII and mean UTF-8 is 0.903
   bytes per stored cell. A one-byte scalar slot is viable for most rows, and the
   probe now records the widest *single-scalar* value per row so the tier (1/2/4
   bytes) can be chosen from data rather than assumed.
3. **Multi-scalar content is rare and does not dominate bytes.** 0.119% of stored
   cells hold more than one scalar. They cluster: 2.25% of rows contain at least
   one, and those rows carry 9.5% of charged bytes because they are long, not
   because clusters are expensive.
4. **Hyperlinks are not zero.** 10,334 stored cells (0.37%) carry OSC 8 metadata at
   depth. Small, but a packing scheme has to represent them rather than assume them
   away -- which `F8`'s and `F10`'s runs could not have told anyone.

#### Observation 3 -- what each row class contributes, in `F9`'s per-row-charge terms

Charges are the engine's own (`Terminal.scrollbackByteCost`: 16 B row slot +
`malloc_good_size(32 + cells x 32)` + spills), which reproduces `F9`'s 1,808 B
content row and 80 B blank row exactly -- the unit suite pins both.

| pool | class | rows | share of rows | share of charged bytes | mean B/row | mean stored cells |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| saturated | plain | 73,560 | 77.44% | 59.16% | 822.7 | 22.2 |
| saturated | styled | 19,293 | 20.31% | 31.38% | 1,663.7 | 45.9 |
| saturated | multi-scalar | 1,356 | 1.43% | 6.78% | 5,116.2 | 143.2 |
| saturated | styled + multi-scalar | 781 | 0.82% | 2.69% | 3,518.1 | 104.1 |
| recordings | plain | 131 | 98.50% | 92.70% | 598.4 | 15.7 |
| recordings | styled | 2 | 1.50% | 7.30% | 3,088.0 | 90.0 |

So against `F9`'s 1,808 B figure: a styled row at depth costs **1,663.7 B** and a
plain one **822.7 B**, and the difference is length, not styling -- styled rows are
twice as long (45.9 cells against 22.2), and the styling itself adds nothing to the
current representation because every cell already carries a 4-byte style id whether
it uses one or not. **That is the whole of `H3`'s opportunity on the style axis:
the current cell pays for styling unconditionally, and the content is 1.66 runs per
row.**

#### Observation 4 -- what each candidate representation would charge for these exact rows

Priced by the committed probe against every retained row in the pool, through the
same allocator and the same charge model. `D3`'s admission test -- a row's request
must shrink by more than one ~12.5% bucket step -- is reported as the share of rows
whose size class strictly drops. Every candidate clears it at **100% of rows** in
every pool, which is the expected outcome of shrinking a 32-byte cell and not a
close call.

Saturated pool (current: **1,076.9 B/row**, 9,736 rows at a 10 MiB budget):

| candidate | B/row | saving | depth | x depth | + `H4` arena B/row | + `H4` depth |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| C1 narrow 8 B cell | 304.6 | 71.7% | 34,421 | 3.54x | 252.6 | 41,510 |
| C2 narrow 4 B ASCII cell | 225.0 | 79.1% | 46,602 | 4.79x | 177.0 | 59,250 |
| C3 UTF-8 text + style runs | 123.3 | 88.6% | 85,066 | 8.74x | 83.4 | 125,707 |
| C4 C3 + uniform-style shortcut | 122.2 | 88.6% | 85,786 | 8.81x | 81.7 | 128,363 |
| C5 fixed stride + runs + kind byte | 143.9 | 86.6% | 72,858 | 7.48x | 101.8 | 102,953 |
| **C6 fixed stride + runs + exceptions** | **114.5** | **89.4%** | **91,618** | **9.41x** | **73.2** | **143,204** |

`F8`'s payload (`reference/scrollback-plain`), which is the one number directly
comparable to every earlier finding, at **both** widths -- and identical at both,
because content-sized rows already made depth width-independent:

| geometry | current | C1 | C3 | C6 | C6 + `H4` |
| --- | ---: | ---: | ---: | ---: | ---: |
| 179x66 | 1,808.0 B/row (5,799 rows) | 464.0 (3.90x) | 160.0 (11.30x) | **112.0 (16.14x)** | 73.0 (24.8x) |
| 80x24 | 1,808.0 B/row (5,799 rows) | 464.0 (3.90x) | 160.0 (11.30x) | **112.0 (16.14x)** | 73.0 (24.8x) |

#### Observation 5 -- packing inverts `F8`'s 89.5 / 10.5 split, which promotes `H4`

`F8` measured stored cell bytes at 89.5% of attributable footprint and per-row
overhead at 10.5%. Under C6 the payload shrinks by ~16x while the row slot (16 B),
the array header (32 B) and size-class rounding do not move at all. On `F8`'s
payload the post-packing split is roughly **51% payload / 49% fixed per-row cost**
(112.0 B/row = 57 B payload + 32 B header + 7 B rounding + 16 B slot); on the
saturated pool it is **50% / 50%** (114.5 = 57.2 payload+spills, 41.3 header and
rounding, 16 slot). The arena column above is that half: composing `H4` into the
selected candidate buys a further **36%** at depth (114.5 -> 73.2 B/row).

`D3` kept `H4` alive only as a composition inside `H3`'s design. This is the
measurement that says the composition matters: `H4` alone was a 1.16 MB ceiling
against 11.00 MB, and after packing it is half the remaining cost.

#### Observation 6 -- C6 beats the text form *and* keeps O(1) column reads

C3 (variable-width UTF-8) and C6 (per-row fixed-stride scalar slot) cost almost the
same, and on the saturated pool C6 is **cheaper** (114.5 against 123.3 B/row). The
reason is Observation 2: at 0.903 UTF-8 bytes per cell, "one byte per scalar" and
"UTF-8" are the same number for nearly every row, and C6 spends its per-cell
descriptor byte only on the exceptions (wide cells and multi-scalar cells, 0.86% of
cells combined) instead of on every cell. C3 pays a descriptor byte per cell to
make its variable-width payload navigable at all.

The consequence is the important one and it is not a byte count: **C6's column read
stays O(1)** -- a fixed per-row stride makes column -> offset a multiplication --
while C3's is a scan from the start of the row. `retained-browse` is the guard
`D3` says is most likely to fire, and this is the axis it fires on.

Where C6 loses is rows containing a scalar above U+00FF: the whole row moves to a
2- or 4-byte slot. `unicode-wrapping` is that case (C6 544.0 B/row against C3's
343.4), and it is why the tier is chosen per row from measured data rather than
globally.

- Inference for `D5`: the content supports a packing scheme, and specifically
  supports **run-length styles plus a narrow fixed-width scalar slot**. It does not
  support a design whose win comes from compressing blank space (`F9` killed that)
  or from per-cell style dictionaries (1.66 runs per row makes them pointless).
  `H4` composes and is now worth ~36% on top rather than ~10%.
- Competing interpretation, and it is the one that most threatens these numbers:
  the saturated pool's *composition* is real but its *mix* is an artifact of which
  recordings happen to repeat well. `alacritty/history` alone contributes 40,772 of
  94,990 rows at 4.7 stored cells per row, which pulls the pooled mean charge down
  hard; `fish_cc` contributes 2,372 rows at 67.5% styled cells, which pulls the
  styled fraction up. The per-stimulus table in the probe output is the defense --
  every candidate is priced per stimulus, and C6's saving ranges from **65.7%**
  (`alacritty/history`, 4.7-cell rows where fixed per-row cost dominates) to
  **93.8%** (`F8`'s payload). No stimulus shows C6 below C1.
- Uncertainty, stated plainly:
  - **The two deepest single-pass workloads staircase.** `benchmark/scrollback-stream`
    and `benchmark/unicode-wrapping` emit bare `\n` with no `\r`, so each line starts
    where the previous ended and rows accumulate leading padding: 66.4% and 39.8% of
    their stored cells hold *no scalar*, and their mean row is 134 and 129 cells
    against ~50 for CRLF content. This inflates the "benchmark + recordings" pool's
    53.08% empty-scalar figure and flatters any scheme that compresses gaps. It does
    not touch `F8`'s or `F10`'s headline numbers (both used the CRLF
    `reference/scrollback-plain` payload) and it does not touch the saturated pool's
    composition materially, but it is a corpus property worth knowing and it is not
    what a real program writing through a PTY produces (the tty driver's `ONLCR` adds
    the CR).
  - Saturated replays restart a stimulus mid-state; a recording ending inside an alt
    screen or a partial escape sequence replays from there. Every report carries
    `derivationMatchesCensus` and all of them reconstructed the census exactly, so
    the rows measured are real rows -- but the *sequence* of content is not a
    sequence any session would produce.
  - Every candidate is arithmetic, not an implementation. These numbers say what a
    representation would cost the budget; they say nothing about what it costs the
    feed path or the browse path, which is what `D3`'s success criterion exists for.
- Next action: `D5` selects a representation on this evidence and states the risks
  its experiment must watch.
