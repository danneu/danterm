# Findings -- append-only evidence chain

Next free ID: **F24**. **That claim is now vacant: the resize-*profile* task it was
reserved for is OBSOLETE as of 2026-08-05**, superseded by
[doc 31](../31-logical-line-scrollback/README.md) -- `9ad7cc5` deleted reflow of
history and the cell cap the profile was the prerequisite for, so the question
cannot be run as written and `D11`'s exit amendment (1.58 ms median, 2.75 ms max,
at greater depth) is the measurement that replaced it. `F24` stays the next free
ID for whatever this doc records next. The paragraph the ID was reserved under
follows, unchanged. Phase 2's open resize-*profile* task has now been renumbered
eleven times (`F11`, `F12`, `F13`, `F15`, `F17`, `F18`, `F19`, `F20`, `F21`, `F22`, `F23`)
without being
written, because IDs go in the order findings are recorded and each time something more
urgent was measured first; it is still owed and now claims `F24`. `F23` is the nearest
miss yet -- it measures resize *cost* at candidate depths and calibrates a harness against
the committed probe, but still does not read where inside reflow the time goes. The scratch-reusing encoder
lead that `F17` Observation 4 left open is **not** carried forward with it -- `D9`
declined it on the ground that even its success leaves browsing over
threshold. `F14` measured how
much a saturated resize costs and `F15` measured what it is a function of; what
neither did is read *where inside reflow* the time goes. Inherited baseline:
`15/F18` -- the compact retained-row validation at `dd51a12`/`54d4d2d` -- is
cited, not copied; read it there.

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

### F12 -- retained rows are printed contiguously, so `contentIdentity` costs 8 bytes rather than 4 per cell; the corrected table keeps C6 and cuts its yield from 16.1x to 14.1x

- Status: recorded, and it closes `PR1`, the evidence-only Phase 0 the C6 plan was
  sent back for. It corrects a pricing omission that reached `F11` and `D5`; the
  representation selection it feeds is `D6`'s. No engine packing code exists.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: `c656dfc` plus the probe extension and pricing
  correction recorded with this finding. Release configuration, headless. Every
  number at or after the evidence floor `dd51a12`.
- Why it exists: plan review found that
  `scripts/terminal-retained-row-shape.py#pack_stride_runs_exceptions` charged
  `wide + multiScalar` only. Hyperlink cells were named in C6's design and charged
  nowhere, and **no** candidate charged `contentIdentity` at all -- on the strength
  of a docstring claiming a retained cell's `contentIdentity` "has no reader here".
  That claim is false: `Terminal.swift#activationIdentity` takes a max over a
  `ProjectionRows` range, and `ProjectionRows` indexes scrollback before live, so
  link activation reads the field out of history. Every candidate in `F11` was
  therefore priced against incomplete storage, and `D5`'s 114.5-against-123.3 B/row
  margin was undecided rather than narrow.
- Method: the shape probe gains one axis, `contentIdentityRunCounts` /
  `identifiedCellCounts`, read through a new **read-only** row-scoped accessor
  (`Terminal.scrollbackRowContentIdentityShape(at:)`). Row-scoped rather than a
  field on `TerminalCell`: per
  [`docs/design/2026-07-29-cross-module-value-dispatch.md`](../../design/2026-07-29-cross-module-value-dispatch.md),
  widening a hot value type that crosses a target boundary is the mechanism to
  avoid at design time, and the accessor keeps the per-cell walk inside
  `TerminalCore`. `TerminalCell`'s layout was measured before and after and is
  unchanged (stride 72, size 72, align 8), so this is instrument, not
  representation. `just test` passes (70 steps).

#### Observation 1 -- `contentIdentity` is allocated per printed cell, not per link run

`Terminal.swift#allocateContentIdentity` is called from `printNarrow` and
`printWide` -- every printed cell -- and its own doc comment says so: "One identity
per printed cell means 32 bits is a few minutes of maximal output." So the field is
a **uniquely valued 4-byte quantity on every content cell**, not sparse link
metadata. Preserved naively that is 4 bytes against C6's 1-byte modal scalar slot,
which would be more than the payload it decorates.

But the counter increments by exactly one in print order, and `printWide` stamps a
head and its tail with a single identity. A row printed left to right therefore
holds an arithmetic sequence, which a per-run base plus extent encodes in 8 bytes
however long the row is. A row assembled by cursor moves, overwrites, or insert
mode fragments into several runs and converges on the per-cell cost. **Which price
a packed row pays is a property of recorded content, not of the design** -- so both
were charged and the measurement selects.

#### Observation 2 -- recorded content is overwhelmingly contiguous

| pool | rows | single-run rows | identity runs/row |
| --- | ---: | ---: | ---: |
| `reference/scrollback-plain` (CRLF) | 5,799 | **100.00%** | 1.000 |
| recordings (single pass) | 133 | 87.97% | 1.13 |
| **saturated replays** | 94,990 | **85.14%** | **1.20** |

`F11` inferred this from the other side -- TUI-painted rows largely do not reach
scrollback, because TUIs paint in place and nothing scrolls off -- and never
measured it. It is now measured, and the inference holds: the fragmenting
constructs are concentrated in exactly the content that stays on screen. The run
variant is the one recorded content actually pays.

The instrument can report the opposite: a row built with a cursor jump comes back
as two runs, and a row whose cells are all identified but issued out of column
order comes back as more than one. Both are pinned by unit tests, because a reader
that returned one run for every row would make this fraction 1.0 by construction
and price the cheap variant into existence.

#### Observation 3 -- the corrected table, both variants

Every candidate now carries what none of them encode in their cells: 4 B per
hyperlink cell (2 B column + 2 B `HyperlinkId`), and `contentIdentity` under either
variant. C6's exception entries are also per kind rather than a uniform 3 B -- a
multi-scalar entry additionally carries the reference that reaches its spill
allocation.

Saturated pool, current cost 1,076.9 B/row (9,736 rows at 10 MiB):

| candidate | `F11` (uncharged) | corrected, run-encoded | corrected, per-cell floor |
| --- | ---: | ---: | ---: |
| C1 | 304.6 | 317.5 | 435.2 |
| C2 | 225.0 | 233.9 | 351.6 |
| C3 | 123.3 | 137.4 | 256.1 |
| C4 | 122.2 | 129.8 | 249.2 |
| C5 | 143.9 | 158.0 | 277.8 |
| **C6** | **114.5** | **121.5** | **238.4** |

`F8`'s CRLF reference payload, current cost 1,808.0 B/row (5,799 rows), which is
the headline the plan quotes:

| candidate | `F11` (uncharged) | corrected, run-encoded | corrected, per-cell floor |
| --- | ---: | ---: | ---: |
| C3 | 160.0 | 176.0 | 400.0 |
| **C6** | **112.0** | **128.0** | **336.0** |
| C6 depth at 10 MiB | 93,622 (16.14x) | **81,920 (14.12x)** | 31,207 (5.38x) |

#### Observation 4 -- the selection survives, and survives under both variants

C6 remains cheapest on the saturated pool and on the CRLF reference payload under
**both** identity variants. That is the load-bearing result: the ranking does not
depend on how the adjudication came out, only the headline does. The C6-against-C3
margin widened rather than narrowed -- 8.8 B/row uncharged, 15.9 B/row corrected on
the saturated pool, 48.0 B/row on the reference payload -- because the metadata
charge is a constant per row that C3's larger payload cannot amortize.

- Inference for `D6`: preserve every field; charge `contentIdentity` run-encoded
  with a per-cell fallback; select C6. `D5`'s selection stands and its yield
  figures do not.
- Competing interpretation, checked rather than argued: on the "benchmark +
  recordings" pool C3 is cheaper than C6 (301.5 against 372.3 B/row). That
  inversion is **pre-existing, not caused by this correction** -- under `F11`'s own
  uncharged pricing the same pool reads 290.5 against 363.3. It is the
  `unicode-wrapping` failure mode `F11` observation 6 already named, concentrated:
  that pool is 28.8% multi-scalar rows, and C6 promotes a whole row to a wider
  stride for one wide scalar. Neither `F11` nor `D5` headlined that pool, and this
  finding does not either.
- Confidence check on the reconstruction: re-running the *old* pricing against
  these same rows reproduces `D5`'s published 123.3 and 114.5 B/row exactly, so the
  before/after comparison above is a like-for-like difference in accounting rather
  than in corpus, geometry, or method.
- Uncertainty, stated plainly:
  - **The encoding widths are proposals.** 4 B per hyperlink entry and 8 B per
    identity run are the honest shapes of the fields, but no encoder exists; a real
    implementation may find a cheaper packing or discover it needs more. The charge
    is deliberately not optimistic, and the floor variant bounds how wrong it can
    be in the expensive direction.
  - **`isSoftWrapped` and `semanticPrompt` are not charged separately.** They live
    in the `GridRow` slot every candidate already pays for, identically, so they
    cancel in the comparison. That is an accounting decision, not an omission --
    `D6` records it as one.
  - **The single-run fraction is a corpus property.** 85.14% at depth is measured
    over committed content replayed to saturation; a user whose sessions are
    dominated by cursor-addressed line editing would sit lower. The floor variant
    is what that user's C6 would cost, and it still selects C6.
  - Everything here is arithmetic over measured rows. No packing exists, so nothing
    here says what C6 costs the feed path or the browse path -- which is what
    `D3`'s success criterion exists for.
- Next action: `D6` records the field adjudications and the selection; the plan's
  yield and depth figures are restated against this table.

### F13 -- five accounting facts the C6 implementation forced, and which of them move `D6`'s model

- Status: recorded. It is an **accounting correction to `F11`/`F12`/`D6`'s pricing
  instruments**, not a new sizing claim: `D6`'s headline of **128.0 B/row on the
  CRLF reference payload stands as measured** at the packing commit. What changes
  is which of the probe's other numbers may still be quoted at HEAD, and it
  retires several of them.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: candidate `efa549f` (packed retained rows) against
  the adjacent baseline `678bfe9`, both run from the same clean tree state.
  Release configuration, headless. Every number at or after the evidence floor
  `dd51a12`.
- Conditions: AC power, no `DANTERM_BENCHMARK_ALLOW_BATTERY`. These are exact
  arithmetic over recorded rows -- no wall-clock is claimed here, so host load
  cannot perturb them.
- Commands:

      just terminal-retained-row-probe "--saturated --json"    # at efa549f
      just terminal-retained-row-probe "--saturated --json"    # at 678bfe9, worktree

- Artifacts (disposable scratch, cited as pointers): the two `--saturated --json`
  dumps. Both are reproducible by the two commands above.

#### Observation 1 -- the saturated pool changed under packing, and `F12`'s 85.14% is a pool fact rather than a definitional one

Packing changes how many rows each replay retains at the same 10 MiB, so the
`--saturated` pool is **not the same population** before and after. Run side by
side:

| quantity | `678bfe9` | `efa549f` |
| --- | ---: | ---: |
| saturated pool rows | 94,990 | 96,617 |
| single-run rows (lenient) | **85.14%** | **83.96%** |
| identity runs per row (lenient) | 1.1953 | 1.2069 |
| style runs per row | 1.662 | 1.653 |
| C6 model charge on the pool | 121.5 B/row | 108.5 B/row |

The baseline column reproduces `F12`'s published 94,990 / 85.14% / 1,076.9 /
121.5 exactly, which is what makes this a like-for-like read. So the 85.14% ->
83.96% drift is **re-weighting, not disagreement**: the same instrument on a pool
that packing itself reshaped. The C6 column moves the same way and for the same
reason -- the pool's rows got shorter on average, not the encoding cheaper.

**A separate and genuinely definitional step sits underneath it.** The encoder
charges identity runs as *strict* steps of one, because `(start, extent, base)`
is the only triple that reconstructs exactly; `F12` counted a repeat as
continuing a run, which `printWide` produces when it stamps a head and its tail
with one identity. Both counts are now reported. On `efa549f`'s pool:

| definition | single-run rows | runs/row |
| --- | ---: | ---: |
| lenient (`F12`'s, what the pricing script still charges) | 83.96% | 1.2069 |
| strict (what the encoder writes) | **82.71%** | **1.2453** |

The gap is worth **0.31 B/row** -- 0.0385 extra 8-byte run entries per row. Real,
and far below the ~12.5% bucket step `F10` set as the floor for a byte claim, so
it changes no selection and no headline. It does mean a CJK-heavy row prices
above `D6`'s model rather than below it, which is the direction that matters for
a bound.

#### Observation 2 -- the encoder pays a 13-byte per-row header that `D6`'s table charges nowhere

`PackedRetainedRow.Header.byteCount` is 13: flags(1) plus six 2-byte table
counts. `scripts/terminal-retained-row-shape.py#pack_stride_runs_exceptions` --
the function every published C6 figure comes from -- has no per-row constant term
at all. On the CRLF reference payload's 78.0 payload B/row that omission is
**16.7% of the payload**.

It did not surface in the headline because malloc rounding absorbed it: the
payload lands in the same size class either way, and the charged figure came back
at `D6`'s 128.0 B/row to the byte. That is a coincidence of one payload, not a
property. The corrected model now lives in the probe's Swift side as
`packedPayloadModelBytes` -- header, strict runs, and per-kind exception entries
included -- and `packedPayloadMatchesModel` holds it against the engine's real
bytes on every stimulus in the corpus. **The Python candidate table has not been
corrected**, because correcting it would move all six candidates by the same
per-row constant and change no ranking; it is recorded here as a stated bias
rather than repaired silently.

#### Observation 3 -- the spill directory is charged by the engine and priced by nobody

`Terminal.swift#scrollbackByteCost(of:)` charges a row carrying any multi-scalar
cell for **the directory as well as the spills**: an array header plus
`spills.capacity * MemoryLayout<[Unicode.Scalar]>.stride` on top of each spill
allocation. `D6`'s model charged only the spill arrays the references point at.
This is `I4` working as designed -- the charge describes what the row allocates,
not what a candidate predicted -- and it prices 0.81% of retained rows in the
saturated pool above their modelled cost.

#### Observation 4 -- the probe's `current` arm now prices a representation nothing stores

`price_facts` builds its `current` arm as `stored cells x 32 B` plus row overhead,
and the report-level `allocatedBytes` is the same model. At `678bfe9` that was the
truth. At `efa549f` it is a **fiction**: history holds packed blobs, and no row in
the process has that shape. Worse, the fiction moved -- 1,076.9 B/row at the
baseline against 921.8 at HEAD -- because the pool re-weighted under it, so it is
not even a stable stand-in for the old cost.

Everything derived from that arm is therefore unquotable at HEAD:
`savingFraction`, `depthMultiple`, `roundingBytes`, `rowsDroppingAClass`, and the
whole packing table's "against current" framing. The probe's still-valid outputs
are the ones that read the engine rather than model it: `composition`,
`derivationMatchesCensus`, `packedPayloadMatchesModel`,
`censusRetainedPackedPayloadBytes`, and `blankRowFraction`. **Any before/after
byte claim at HEAD comes from a two-arm run like this one, not from a single
arm's `current` column.**

#### Observation 5 -- at narrow widths the depth difference between row shapes collapses into one bucket

`TerminalScrollbackBudgetTests`'s short-vs-full-width depth test moved from 8
columns to 80. At 8 columns a packed one-cell row and a packed full-width row now
land in the same malloc size class -- a fixed slot plus a 13-byte header plus
roughly one byte per stored cell leaves too little between them to clear a step --
so they retain identically and the test's premise evaporates. At 80 columns it
clears comfortably.

This is `D3`'s admission test seen from the other side: a scheme must move a row
by more than one ~12.5% bucket step to yield bytes, and at a narrow enough width
*no* content difference does. It is not a lost property, but it does bound where a
depth claim can be read: **narrow-pane depth arithmetic is bucket-dominated, and
`F8`'s two-width discipline (179 and 80) is the reason nothing here was read at 8.**

- Inference: `D6`'s selection and its 128.0 B/row headline are untouched. What is
  retired is the single-arm framing -- the `current` column, `depthMultiple`, and
  `savingFraction` at HEAD -- and what is added is a stated upward bias in the
  Python C6 price (no header, lenient runs, no spill directory) totalling roughly
  13 B/row plus 0.31 B/row plus a 0.81%-of-rows term.
- Competing interpretation, checked rather than argued: that the 85.14% -> 83.96%
  drift was the strict/lenient change. It is not -- the baseline arm reproduces
  85.14% under the *same lenient* rule, and strict on the candidate pool is a
  further step to 82.71%. The two effects are separable and both are reported.
- Uncertainty, stated plainly:
  - The Python candidate table is knowingly optimistic for C6 by a per-row
    constant. Left uncorrected on purpose (it moves every candidate alike), but a
    future reader pricing a *new* candidate against it must add the header term
    themselves or the comparison tilts.
  - The saturated pool's mix remains `AR2`, and it is now additionally
    representation-dependent: the pool a probe builds at HEAD is not the pool it
    built at the baseline. Two-arm reads are the only way to compare across the
    change.
- Next action: none of these five moves the packing decision. They constrain how
  the probe may be quoted at HEAD, which `F14`'s resize comparison and any later
  memory read depend on.

### F14 -- a saturated resize costs 1.43 s after packing against 100 ms before: 12.1x the rows at 1.17x per row, and 14.2x the wall clock

- Status: recorded, and it is the **two-armed comparison gate item 6 of
  [`plans/impl/2026-08-03-2357-packed-retained-rows.md`](../../../plans/impl/2026-08-03-2357-packed-retained-rows.md)
  demanded**, run before landing rather than after. It is the risk that plan's
  own risk list named as "the largest blast radius, and what this evidence says
  least about", and it fired. `D7` adjudicates it; this entry is the measurement.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: baseline `678bfe9` (the commit before packing, in a
  detached worktree), candidate `efa549f` (packed retained rows). The probe's
  recipe extension is **byte-identical in both arms** -- the same two source files
  were copied into the baseline worktree, so the only difference between the arms
  is the retained-row representation.
- Conditions: AC power, no `DANTERM_BENCHMARK_ALLOW_BATTERY`, no low-power mode.
  Load average 2.26/3.21/4.26 before the baseline arm, 2.24/3.19/4.25 between
  arms, 2.81/3.20/4.21 after -- the busiest non-harness process was under 7% CPU.
  Read before trusting the verdict, per gate item 7. The arms are 14x apart; no
  load this machine was under explains a factor of fourteen.
- Commands:

      just terminal-resize-probe "--recipe saturating"    # at 678bfe9, worktree
      just terminal-resize-probe "--recipe saturating"    # at efa549f

#### Observation 1 -- the recipe had to be re-versioned, because `v1` stopped saturating

`saturated-resize-v1` feeds 10,000 lines, which saturated the pre-packing
representation (`F7`: 6,756 retained rows at the 10 MiB budget). Packed rows admit
~82,000 at the same budget, so at HEAD `v1`'s history is bounded by its **line
count** rather than by the budget -- it retains ~9,940 rows, 1.47x the baseline's
depth instead of the ~12x a saturated pane really holds. A `v1` run at HEAD
therefore understates the cost by most of an order of magnitude while printing a
perfectly well-formed distribution.

`saturated-resize-v2` feeds 120,000 lines. It is a **new frozen recipe, not an
edit of `v1`**, so `F7`'s recorded distribution and this one cannot be misread as
two arms of one comparison. `saturatingRecipeReachesTheBudgetCeiling` pins the
premise the way it is actually claimed: after setup, feeding a further 200 lines
adds no retained row.

#### Observation 2 -- the comparison

`saturated-resize-v2-120000-lines-179x66-to-100`, 20 timed samples per arm after
4 untimed, alternating 179 <-> 100 columns at the production 10 MiB budget:

| arm | retained rows | median | min | p90 | p99 / max | per row |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `678bfe9` (unpacked) | 6,756 | **100.2 ms** | 98.2 | 100.9 | 104.5 | 14.84 us |
| `efa549f` (packed) | 81,920 | **1,425.8 ms** | 1,397.3 | 1,447.3 | 1,449.3 | 17.40 us |

Both distributions are tight -- max/min is 1.06 at the baseline and 1.04 at the
candidate -- so the difference is not a tail artifact. Split by direction:

| arm | narrow 179 -> 100 | widen 100 -> 179 |
| --- | ---: | ---: |
| `678bfe9` | 98.5 ms | 100.8 ms |
| `efa549f` | 1,414.0 ms | 1,442.5 ms |

Neither direction escapes: `F7`'s observation that narrowing is the reflowing
direction survives as a ~2% asymmetry in both arms and explains none of the gap.

#### Observation 3 -- the factorization, which is what makes this decidable

The 14.2x wall-clock ratio decomposes cleanly:

- **12.13x more rows** (81,920 against 6,756) at the same byte budget. This is the
  win, working exactly as `D6` priced it -- 14.12x was the prediction on the CRLF
  reference payload, and the probe's own stimulus is CRLF ASCII.
- **1.17x more cost per row** (17.40 us against 14.84 us). Reflow now unpacks a
  blob to cells and repacks the result, where before it moved cells to cells.

So packing did **not** make per-row reflow cheaper, which `H1` had left as
genuinely unknown; it made it moderately dearer, and then multiplied it by the
depth the same change bought. `12.13 x 1.17 = 14.2`, which is the measured ratio.

The baseline arm is also an internal control: 100.2 ms over 6,756 rows reproduces
`F7`'s ~98 ms over 6,756 rows at the same geometry, on a probe binary built from
different source. Nothing about the recipe extension moved the number it inherited.

#### Observation 4 -- what 1.43 s means, stated as the responsiveness question rather than a threshold

The plan wrote the failure condition down in advance: "`F7`'s ~98 ms median
becoming most of a second would pass every other gate here while breaking the
responsiveness contract". The measured median is **1.43 s** -- past that line, not
near it. At 60 Hz it is ~86 frames. A window drag issues a resize per step, and
the shipped resize coalescing bounds how many survive, not how long one takes.

No frozen rule is invoked, because this workload has none and `D1` pitch 2
deliberately left it a probe. Gate item 6 offered exactly two exits -- screen it
toward a frozen rule and clear it, or state the trade as numbers and decide it --
and a 14x wall-clock difference is not a threshold question. This is the second
exit, and `D7` takes it.

- Inference for `D7`: the depth win and the resize cost are the *same* fact
  measured twice. Any mitigation that keeps the depth keeps most of the resize
  cost, and any mitigation that caps the depth gives back the win in proportion.
  That is a design decision, not a measurement one.
- Competing interpretation, checked rather than argued: that this is the probe's
  synthetic stimulus rather than the representation. It is not -- the per-row
  factor is 1.17x on the same content in both arms, and the remaining 12.1x is
  the row count the budget admits, which is the plan's own headline claim. A
  different stimulus changes both factors together.
- Uncertainty, stated plainly:
  - **One geometry, one machine, one payload.** 179x66 <-> 100 on ASCII CRLF
    content. The factorization is what generalizes; the absolute 1.43 s is not
    claimed beyond this recipe.
  - **No profile.** Where inside reflow the 17.40 us/row goes is not measured
    here -- unpack, repack, or the allocation traffic between them. Phase 2's open
    resize task is where that read belongs, and it is now a prerequisite of any
    mitigation rather than a curiosity.
  - **`v2` is one run per arm.** A probe, not a paired benchmark: no pairs, no
    interleaving, no frozen rule. At 14x that is enough to decide the direction
    and not enough to quote a percentage.
- Next action: `D7`. Per the plan's own instruction, the remaining gate runs
  (`terminal-feed` screen, the deciding ladder, the two-width memory read) were
  **not** run -- they would measure a shape the design decision may change.

### F15 -- reflow costs `a x rows + b x cells`, the byte budget used to bound the cell term and stopped, and a row cap alone destroys history

- Status: recorded, and it is the evidence `D8` decides on. `F14` measured *how
  much* a saturated resize costs after packing; this measures *what it is a
  function of*, which is what makes a bound designable rather than guessable. It
  also corrects a premise the cap discussion started from -- that pre-packing
  depth was ~5,800-6,800 rows -- which was wrong by an order of magnitude and
  would have produced an unsatisfiable decision rule.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: three arms, each a separate checkout, with the probe
  sources byte-identical in all three (the same two files were copied into both
  worktrees, as `F14` did). **old** = `678bfe9`, the commit before packing.
  **packed** = `c140069`, packing with no cap. **dual** = `43b9c83`, packing with
  the cell and row caps. Release configuration, headless.
- Conditions: AC power, no `DANTERM_BENCHMARK_ALLOW_BATTERY`, no low-power mode.
  Every timed arm ran behind a load gate that blocks until the one-minute load
  average is below 2.5, and host conditions were read before and after each --
  they sat between 2.0 and 2.4 throughout. One earlier batch was **discarded
  unread** because it began at load 10.48, contaminated by a test-suite run that
  had just finished; gate item 7 is what that discard implements. The
  per-stimulus depth arithmetic in Observation 1 is exact integer arithmetic over
  recorded rows and claims no wall clock, so load cannot perturb it.
- Commands:

      just terminal-retained-row-probe "--saturated --json"     # at 678bfe9
      just terminal-resize-probe "--recipe saturating"          # each of the three arms
      just terminal-resize-probe "--recipe sparse"              # each of the three arms
      just terminal-resize-probe "--recipe wide"                # each of the three arms

#### Observation 1 -- pre-packing depth ran to 82,023 rows, not ~6,800

`F7`'s and `F14`'s 6,756-row baseline is the depth the *probe's dense payload*
reached, and it is near the shallow end of the pre-packing range rather than
representative of it. Retained rows have been content-sized since doc 15, so the
byte budget bought a row count that varied with row length. Pricing every
saturated stimulus at `678bfe9`:

| stimulus | old B/row | old depth at 10 MiB |
| --- | ---: | ---: |
| `danterm/fish-u2733-title` (20 cols) | 127.8 | **82,023** |
| `alacritty/history` (105 cols) | 186.3 | **56,273** |
| `danterm/zsh-osc133-width-sweep` (12 cols) | 272.2 | 38,519 |
| `alacritty/tab_rendering` (116 cols) | 1,014.9 | 10,332 |
| pooled saturated corpus (94,990 rows) | 1,059.4 | 9,898 |
| the resize probe's dense payload | ~1,550 | 6,756 |
| `benchmark/scrollback-stream` (179 cols) | 4,607.3 | 2,276 |

The consequence is not academic. A cap rule requiring both "no user retains fewer
rows than pre-packing" and "worst-case resize within ~1.5x of 100 ms" is
**unsatisfiable**: the first demands at least 82,023 and the second at most
~8,600, an order of magnitude apart. Any cap is a depth regression against *some*
pre-packing content, and the honest question is which content and how much.

#### Observation 2 -- what the pre-packing worst case actually cost, which is not what extrapolation predicted

The natural guess is that the old format's deepest content was also its slowest
resize: 56,273 rows at `F14`'s measured 14.84 us/row extrapolates to ~835 ms, and
if that held, a cap would be bounding a pathology that already existed. **It does
not hold.** Measured on `saturated-sparse-resize-v1`:

| arm | retained rows | median | per row |
| --- | ---: | ---: | ---: |
| `678bfe9` unpacked | 50,412 | **152.0 ms** | 3.01 us |
| packed, uncapped | 124,830 | **445.2 ms** | 3.57 us |

The extrapolation failed because **per-row reflow cost is not a constant** -- it
scales with the row's length, and these rows are ~4.9 cells against the dense
payload's ~45. So the pre-packing format's deepest content resized in 152 ms, not
800, and the depth a cap gives back is depth users really had at a price they
were really paying. `F14`'s 1.17x per-row packing penalty reproduces here as
3.01 -> 3.57 us on completely different content, which is an independent
confirmation of its factorization.

#### Observation 3 -- the cost model, fitted across three content regimes

Three payloads at one geometry (179x66 <-> 100), differing only in row length,
give two equations per representation and therefore a two-term fit:

| representation | per row | per cell |
| --- | ---: | ---: |
| unpacked (`678bfe9`) | 1.59 us | **0.292 us** |
| packed (`c140069`) | 1.85 us | **0.352 us** |

The cell term dominates at any real pane width -- at 45 cells per row it is ~90%
of the cost, at 179 cells ~97%. Packing moved both terms by ~1.17x, which is the
same factor `F14` reported and is the *small* half of what it found.

**This is the mechanism behind `F14`, stated properly.** A `GridCell` cost 32 B,
so the byte budget bounded stored cells at `10 MiB / 32 B` = 327,680 however the
rows were shaped -- and the three regimes measured 304,020, 245,758 and 298,035
cells at `678bfe9`, all just under it. That is why a pre-packing saturated resize
was 87-152 ms *whatever the content was*: bytes were a cell bound in disguise. A
packed stored cell costs ~1 B, so 10 MiB now admits up to ~10 M cells and the
disguised bound is gone. Packing did not make reflow slow; it removed the thing
that had been bounding it.

#### Observation 4 -- a row cap bounds the wrong term, and destroys history

The first cap tried was rows alone, at 8,192. Measured against the same three
regimes, it bounds the regime it was sized on and misses the others:

| regime | `678bfe9` | row cap 8,192 | ratio |
| --- | ---: | ---: | ---: |
| dense (~45 cells/row) | 99.5 ms | 135.8 ms | 1.36x |
| sparse (~4.9 cells/row) | 152.0 ms | 29.3 ms | 0.19x |
| wide (179 cells/row) | 87.4 ms | **232.6 ms** | **2.66x** |

Wide content overshoots because 8,192 rows of 179 columns is 1.47 M cells in
~2.15 MB -- the row cap is satisfied and the byte budget is nowhere near reached,
while the dominant term runs free.

**And a row cap is not reflow-invariant, which is worse than the overshoot.**
Narrowing a pane multiplies row count while leaving content alone, so the cap
evicts the overflow and widening cannot restore it. Measured directly at 179
columns, 8,192-row cap, no cell cap:

    8,192 rows  ->  narrow to 100  ->  8,192  ->  widen back to 179  ->  4,095

Half a user's scrollback destroyed by one window drag, silently, with no byte
budget exceeded and no error. The byte budget never had this failure mode because
bytes are roughly conserved under rewrap while row count is not.

#### Observation 5 -- restating the old implicit bound explicitly fixes both

`D8` adds a **cell cap at 327,680** -- the pre-packing implicit ceiling at the
value it always had -- with the row cap kept as a backstop for the degenerate
regime a cell cap cannot see (`F9`'s near-empty rows store ~zero cells, so blank
history would satisfy any cell cap while leaving the per-row term unbounded), and
sized from the model at 16,384 (`D8` carries the arithmetic). Measured:

| regime | `678bfe9` | packed uncapped | dual-bound | vs old | depth vs old |
| --- | ---: | ---: | ---: | ---: | ---: |
| dense | 99.5 ms / 6,756 | 1,450.2 ms / 81,920 | **117.6 ms / 7,123** | 1.18x | 1.05x deeper |
| sparse | 152.0 ms / 50,412 | 445.2 ms / 124,830 | **57.1 ms / 16,384** | 0.38x | **3.08x shallower** |
| wide | 87.4 ms / 1,665 | 1,846.5 ms / 29,757 | **104.1 ms / 1,798** | 1.19x | 1.08x deeper |

Every regime lands within 1.19x of pre-packing, against 14.6x / 2.9x / 21.1x
uncapped. Retained cells at the bound come out at 320,535 / 79,872 / 321,842 --
the cell cap binds for dense and wide, the row cap for sparse, which is each
bound doing the job it was added for. The `678bfe9` dense arm reproduces `F14`'s
100.2 ms at 99.5 ms, which is the internal control that makes the three arms
comparable.

- Inference for `D8`: the trade is no longer resize-for-depth across the board.
  Dense and wide content get *both* -- slightly more depth and near-baseline
  resize -- because their bound was always the cell ceiling and it has been
  restored. The entire giveback is sparse content, at 3.08x shallower than
  pre-packing, and it is a real regression rather than a bounded pathology
  (Observation 2 closed the alternative).
- Competing interpretation, checked rather than argued: that the wide arm's
  232.6 ms under the row cap was the byte budget rather than the cap. It was not
  -- that history is ~2.15 MB against a 10 MiB budget, and the row count sat at
  4,064 rather than 8,192 precisely because Observation 4's destruction had
  already halved it during warm-up.
- Uncertainty, stated plainly:
  - **The simultaneous worst case is modelled, not measured.** The 145.8 ms that
    sizes the row cap assumes content at ~20 cells per row, where both bounds bind
    at once. No corpus stimulus sits there; the three measured regimes bind on one
    bound each, and the worst *measured* case is 117.6 ms.
  - **One geometry, one machine.** 179x66 <-> 100 throughout. The two-term
    factorization is what generalizes; the absolute milliseconds are not claimed
    beyond this recipe.
  - **The fit is two points per representation**, so it has no residual to report.
    It predicted the dual-bound dense arm at 142.8 ms against 135.8 measured under
    the row cap -- ~5% -- which is the only out-of-sample check it has.
  - **Below 20 columns the row cap can still bind on a narrowing** and lose
    content, because `cellCap / rowCap` = 20. `D8` takes that trade explicitly.
- Next action: `D8` decides the bounds and their values; `F16` still owes the
  profile of where inside reflow the per-cell term goes, which is what any further
  reduction depends on.

### F16 -- the deciding ladder: the memory win is real and so are four `slower` verdicts, browsing worst at +19.83%

- Status: recorded, and it is the deciding run set `D3`'s success criterion asked
  for. **`H3` does not graduate on it.** The memory claim is measured and holds;
  four of six calibrated workloads answer `slower`, and the largest is the guard
  `D3` named in advance as most likely to fire.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: candidate `43b9c83` (packing plus `D8`'s cell and
  row caps) against the adjacent baseline `678bfe9`, the commit before packing.
  Release configuration. The candidate snapshot also captured five untracked
  markdown paths, none of which is engine or benchmark code.
- Conditions: AC power, no `DANTERM_BENCHMARK_ALLOW_BATTERY`. Host conditions
  present and **read before trusting the verdicts**, per gate item 7: load
  2.06/4.16/5.55 at invocation on the operator's idle machine, busiest external
  process 29.8%. The second preflight reading (3.22) follows the run's own builds
  and is confounded by them, as the harness itself annotates. `F3`'s standing
  lesson is honoured in the framing rather than the load: the baseline is the
  **adjacent** commit, which is what made three of `F3`'s four `slower` verdicts
  evaporate.
- Commands:

      just benchmark-quick baseline=678bfe9 workload=terminal-feed
      just benchmark-confirm baseline=678bfe9
      just terminal-memory-probe "--payload scrollback-plain"
      just terminal-memory-probe "--payload scrollback-plain --columns 80 --rows 24"

#### Observation 1 -- the ladder, at `confirm`

| workload | verdict | effect | pairs / threshold |
| --- | --- | ---: | --- |
| `retained-browse` | **slower** | **+19.83%** | 4 / 1.05% |
| `scrollback-stream` | **slower** | +7.53% | 4 / 1.85% |
| `incremental-mixed` | **slower** | +4.24% | 6 / 1.85% |
| `terminal-feed` | **slower** | +3.10% | 2 / 2.5% |
| `content-churn` | equivalent | +0.44% | 4 / 2.15% |
| `style-churn` | equivalent | -0.11% | 4 / 2.0% |

`retained-browse` is not a marginal call: the frozen threshold is 1.05% and the
measured effect is nineteen times it. `D2`'s 0.30-point dead zone and `AR1`'s
"expect `inconclusive`" do not apply to a difference this size, and no rerun is
warranted -- reaching for one is the shopping `F1`'s protocol forbids, and there
is nothing ambiguous here to shop for.

**This is `C6`'s named falsification, fired.** The plan's risk list opens with
"a row read whose metadata lookup dominates -- if reconstructing a cell from slot
+ style run + exception measurably costs more than a struct load, `C6`'s whole
advantage over the text form evaporates and the choice reopens toward `C1`/`C2`".
`PO5` proved the *asymptotics* (a random read is flat in width, a full-row read
stays linear) and both microbenchmarks pass; what they never bounded is the
**constant factor**, and on the real browsing workload it is +19.83%.

#### Observation 2 -- the caps are not the cause

`retained-browse` plans frames over 10,000 short hard-terminated lines
(`D1` pitch 1's recipe): ~100K stored cells against `D8`'s 327,680 cell cap and
10,000 rows against its 16,384 row cap. **Neither bound binds on this workload**,
so the regression is the packed row's read cost, not eviction. The same holds for
`terminal-feed`, which measures admission rather than depth.

#### Observation 3 -- the memory claim, at both geometries, and it holds

`reference/scrollback-plain`, the CRLF payload every earlier finding is
comparable against:

| geometry | retained rows | cell bytes | per row | live heap |
| --- | ---: | ---: | ---: | ---: |
| 179x66 | 6,491 | 0.84 MB | 69 B | **1.27 MB** |
| 80x24 | 6,449 | 0.54 MB | 66 B | **0.95 MB** |

Against pre-packing's 5,799 rows at 1,808.0 B/row (~10.5 MB): **1.12x deeper at
roughly an eighth of the memory**, and still width-independent, which is the
property `F11` measured rather than assumed.

Depth is now decided by `D8`'s cell cap rather than by the byte budget, and it
binds exactly -- the probe's `cells` column counts the live grid too, so
subtracting it gives 339,489 - 11,814 = **327,675** at 179x66 and
329,595 - 1,920 = **327,675** at 80x24, against a 327,680 cap. That the two
geometries land on the same retained cell count to within five cells is the cell
cap doing precisely what a content-denominated bound should.

Per `F13` Observation 4, no `savingFraction` or `depthMultiple` is quoted from a
single-arm probe run here; the before/after above is two arms.

- Inference: the trade is no longer "resize for depth" (`D8` resolved that) but
  **memory for browsing latency**. ~8x less retained-history memory and 1.12x more
  depth, against +19.83% on the workload that displays that history and three
  smaller regressions on paths that touch retained rows.
- Competing interpretation, checked rather than argued: that `D8`'s caps cause the
  regressions. They do not -- Observation 2 shows neither bound binds on the two
  worst workloads. A second candidate, that the baseline is too wide, is excluded
  by construction: `678bfe9` is the immediately preceding commit.
- Uncertainty, stated plainly:
  - **Where inside the read the 19.83% goes is unmeasured.** Binary searches over
    the style/exception tables, the identity run decode, and the blob's cache
    behaviour are all candidates and none is separated. That read is `F17`.
  - **`terminal-feed` at +3.10% exceeds the plan's own prediction** of ~+1%
    bounded at +2%. The quick reading was +2.72% and `inconclusive`; confirm made
    it `slower` at +3.10%. Because both readings sit above ~2%, `D1` pitch 3's
    reopening condition does **not** fire and the longer screen is unnecessary --
    the plan's stated escape, and the one case where exceeding a prediction makes
    less measurement necessary rather than more.
  - **`scrollback-stream`'s +7.53% is the largest surprise after browsing** and is
    unexplained. Its drain rate fell 9.2 -> 8.4 MB/s while its draw tail *improved*
    13.4 -> 9.7 ms, so the cost is on the admission side, not the draw side.
- Next action: a human decision on `H3`'s disposition. The plan's graduation rule
  admits "a trade stated as numbers and decided in a `D` entry", and this entry is
  the numbers; whether a +19.83% browsing regression is a trade anyone wants is not
  a measurement question. `C1`/`C2` -- a narrower cell that keeps a real cell and
  gives up depth (3.39x against 8.86x) for an O(1) read with no tables -- is the
  named reopening target, and `F17`'s profile is what would say whether `C6`'s read
  can be made cheap enough instead.

### F17 -- the browsing regression was two whole-row materializations per frame, not a slow decode: streaming the readers cuts +19.83% to +3.27%, and what remains is admission

- Status: recorded. It answers `F16`'s "where inside the read the 19.83% goes"
  and supplies the profile the human decision on `H3`'s disposition was made
  conditional on. **It does not graduate `H3`**: all four `slower` workloads are
  still `slower`, and `retained-browse` still misses its 1.05% threshold by 3x.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: profiled at `1d0e73a`/`4c63042` (packing plus `D8`'s
  caps), fixed at `2ae37c4`, both against the adjacent baseline `678bfe9`.
  Release configuration throughout.
- Conditions: AC power. Every directional reading was taken behind a load gate
  (`< 2.5` one-minute) per gate item 7; the profiles themselves are attribution
  and carry no verdict, per `agent-docs/terminal-performance.md`.
- Commands:

      sample <pid> 12          # TerminalBrowseBenchmark, both arms, release
      just benchmark-quick baseline=678bfe9 workload=retained-browse
      just benchmark-feed-sample scrollback-stream 20

#### Observation 1 -- the read path was never the shape the microbenchmark proved, but not in the direction predicted

The standing suspicion entering this work was that frame planning read retained
cells through per-cell **point reads** -- `cell(at:)`, a binary search per table
per cell -- rather than the linear cursor walk `PO5` benchmarked. **It does
not.** Nothing on the browsing path calls `cell(at:)`; the planner reached
`unpacked()`, which *is* the linear walk, cursor-per-table and provably linear.

The cost was the opposite shape. `unpacked()` returns a **materialized
`[GridCell]`**, and two separate readers asked for one per visible row per frame:

| site | what it wanted | what it paid | samples (of 9,738 in `planFrame`) |
| --- | --- | --- | ---: |
| `geometry` -> `presentedRows` | per-column `kind`, `isSoftWrapped` | full decode + array | 699 |
| `forEachViewportCell` | scalars + style id | full decode + array | 656 |

That is **each visible retained row decoded twice and allocated twice, every
frame**, to serve two readers that each wanted a slice of one. Against the
baseline arm profiled identically, the same two sites cost 775 and ~5 samples --
because the pre-packing representation could hand back its stored `[GridCell]`
**by reference**. The regression was never the decode being slow. It was the
decode being *requested wholesale, twice, by callers that wanted a third of it.*

- Inference: `C6`'s named falsification -- "a row read whose metadata lookup
  dominates" -- did **not** fire. What fired is a plainer thing that no proof
  obligation covered: `PO5` proved the walk's asymptotics and its constant, and
  said nothing about *how many walks a frame performs*.

#### Observation 2 -- three readers, three walks, and the measured effect of each

The fix gives each reader a walk that decodes only what it consumes, sharing the
layout rather than a decoder. Measured on `TerminalBrowseBenchmark`, ABBA, three
rounds each, load-gated:

| state | `planNanosecondsPerFrame` (head vs base) | effect |
| --- | --- | ---: |
| at `F16` | 367.4k vs 341.8k | **+19.83%** (confirm, `F16`) |
| stream both readers (`forEachCell`, `forEachKind`) | 367.4k vs 341.8k -> 358.5k vs 343.6k | **+7.5%** |
| render walk stops decoding hyperlink + identity (`forEachContentCell`) | 358.5k -> 353.4k | **+4.3%** |
| scalar slot read through an unsafe buffer, stride resolved once | 353.4k -> 353.3k | **+3.5%** |
| adjudicated | `just benchmark-quick` | **`slower`, +3.27%** (2 pairs, threshold 1.05%) |

`geometry` is now measured **below** the baseline arm (654 samples against 775):
projecting kinds never needed a scalar, a style, a hyperlink, or a content
identity, and it had been paying for all four.

One tried change is recorded as **rejected**: a non-failable
`Unicode.Scalar(UInt8)` path for the 1-byte stride, on the theory that the
failable initializer's surrogate check was per-cell cost. Measured +3.6% against
+3.5% -- no effect -- and it was reverted rather than kept. It is named here so
the next reader does not re-derive it.

#### Observation 3 -- what remains on the read side is the decode itself

After the fix, `forEachContentCell` is 302 self samples of ~9,750 (~3.1%),
which is the measured +3.27% almost exactly. That is ~3.8 ns per stored cell to
reassemble a scalar and a style id from packed bytes, against ~0 for a 32-byte
struct load out of a contiguous array. **No further localized fix is visible.**
Merging the kind walk and the content walk into one traversal is the only
remaining structural idea, and `forEachKind`'s 205 samples bound its yield at
~2%, which would still not clear 1.05%.

- Inference: the read-side residual is `C6`'s representation, not a defect in
  how it is called. Reducing it further means changing what a cell costs to
  decode -- which is `C1`/`C2`'s subject, not a tuning exercise.

#### Observation 4 -- the other three regressions are one cause, and it is admission

`F16` decomposed `scrollback-stream` as admission rather than draw. Profiling
headless `Terminal.feed` confirms it and names the frame:
**`PackedRetainedRow.pack(_:)` is 9.2% of feed self time**, the second-largest
frame after `Terminal.feed` itself (16.9%). At the baseline this frame **does not
exist** -- admission stored the `GridRow` as it stood.

Post-fix quick verdicts against `678bfe9`, each load-gated:

| workload | at `F16` | at `2ae37c4` | threshold |
| --- | ---: | ---: | ---: |
| `retained-browse` | +19.83% | **+3.27%** | 1.05% |
| `scrollback-stream` | +7.53% | **+6.34%** | 1.85% |
| `terminal-feed` | +3.10% | **+5.18%** | 2.5% |
| `incremental-mixed` | +4.24% | **+4.22%** | 1.85% |

The three admission-bound workloads are unmoved, which is the expected result of
a read-only fix and is recorded as such rather than as a surprise.

- Inference: encoding a row costs what it costs. `pack` scans every cell, sizes a
  stride, and builds up to five exception tables plus a scalar column and a blob
  -- on an ordinary row roughly four heap allocations where admission previously
  made none. A scratch-reusing single-pass encoder is a **plausible** reduction;
  it is not attempted here, because it is an encoder rewrite rather than a wiring
  change, and the brief's boundary is that a shape problem is a stop-and-report.
- Uncertainty, stated plainly: **how much of the 9.2% is recoverable is
  unmeasured.** The scan is irreducible; the allocations are not. Nobody should
  read "admission costs 9.2% of feed" as "6% is available".

#### Observation 5 -- the plan's `terminal-feed` prediction was wrong, and `D1` pitch 3's screen stays moot

The plan predicted `terminal-feed` at **~+1%, bounded at +2%**. Four readings now
exist: +2.72% (quick, `F16`), +3.10% (confirm, `F16`), +5.18% (quick, here).
Every one is above the +2% bound, so the prediction is **falsified**, and `D1`
pitch 3's reopening condition -- which fires only *below* ~2% -- does not fire.
The longer feed screen remains unnecessary. This is the correction `F16`
Observation 3 flagged, now recorded against three independent readings rather
than one.

- Next action: the human decision `F16` deferred, now with the profile it was
  made conditional on. The read path is fixed as far as wiring can fix it and the
  gate still fails, so the choice among **revert**, the **`C1`/`C2` pivot**, and
  **accepting a stated trade** returns to the human unchanged in kind but much
  changed in size: the browsing cost is +3.27%, not +19.83%, and the three
  remaining regressions have a single named cause with an unmeasured fraction of
  it recoverable. A scratch-reusing encoder is the one unexplored lead that could
  move them, and it is not started. (That lead reserved `F18` when this was
  written; `D9` then declined it and `F18` went to the C1 pricing below. The ID
  is not the lead.)

### F18 -- C1 priced exactly: 528.0 B/row on the CRLF reference payload, and under `D8`'s caps it retains the *same* rows C6 does

- Status: recorded, and it is a **pricing measurement, not a verdict**. It charges
  the C1 representation the human pivot selected against the same real retained
  rows every earlier candidate was charged against, with the two corrections `F13`
  found and the Python candidate table never took. No engine code implements C1 at
  the time of this reading; every figure here is a model over measured rows, and
  the deciding runs are what confirm or refute it.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: `52ac28b` (C6 packed, read path streamed), clean
  tree. Release configuration, headless. Every number at or after the evidence
  floor `dd51a12`.
- Conditions: AC power. These are exact arithmetic over recorded rows -- no
  wall-clock is claimed, so host load cannot perturb them.
- Commands:

      just terminal-retained-row-probe "--saturated --json"

  then the two candidates charged through the committed model's own
  `row_charge`/`good_size`, with a per-row header constant and the encoder's
  *strict* identity-run count (`F13` Observations 1 and 2).

#### Observation 1 -- the layout, and why an 8-byte cell needs no narrowing anywhere

`D5` and the Python table both priced C1 as "4 B scalar + 1 B kind + 2 B style id
+ 1 B pad", and `pack_narrow_cell`'s docstring says `StyleId` narrows to 16 bits
"against a measured style-table size". That narrowing is real risk for no gain,
and it is avoidable: a scalar needs **21 bits** (`U+10FFFF`), a kind needs 3, and
that leaves 40 bits in a 64-bit word for a **full-width 32-bit `StyleId`** with 8
bits spare. So the priced 8 bytes buy strictly more than the priced design did --
every scalar in Unicode inline, including non-BMP, and no style-table ceiling.

`HyperlinkId` (`UInt16`) does not fit alongside them and stays a side-table entry,
as it is for every candidate. It is charged, not assumed away: `F11` measured
0.37% of stored cells carrying OSC 8, which prices at **0.60 B/row** on the
saturated pool and **0.0 B/row** on the CRLF reference payload.

#### Observation 2 -- the priced table, both headline pools

Charged the way `Terminal.scrollbackByteCost` charges a real row -- 16 B row slot,
the allocator's own answer for `32 B array header + payload`, plus spills.

`reference/scrollback-plain` (the CRLF payload every headline in this doc quotes),
6,425 retained rows at 51.00 stored cells/row:

| quantity | pre-packing | C6 (shipped) | **C1** |
| --- | ---: | ---: | ---: |
| payload B/row | -- | 78.0 | **423.0** |
| charged B/row | 1,808.0 | 128.0 | **528.0** |
| against pre-packing | 1.00x | 14.12x cheaper | **3.42x cheaper** |

Saturated pool, 68,646 rows at 31.54 stored cells/row: C1 is **343.4 B/row**
charged (270.3 payload) against C6's 136.2, a ratio of 2.52x. The ratio is smaller
here than the reference payload's 4.12x for the reason `AR2` states -- the pool's
rows are shorter, so the per-row constants both candidates share are a larger
share of each.

C1's payload decomposes, per row, on the reference payload: **408.0 B of cells**
(51 x 8), **8.0 B of identity runs**, **7 B of header**, 0 B of hyperlinks. The
cells are 96.5% of it. There is no style-run table, no kind-exception table, no
spill directory and no stride tier, because the cell carries all four itself --
C1 is **two side tables against C6's five**.

#### Observation 3 -- the decisive one: under `D8`'s caps the pivot costs **zero depth**

`D8` bounds retained history at 327,680 stored cells and 16,384 rows, *and both
bounds are denominated in content rather than bytes*. At 51.00 stored cells per
row the cell cap admits 6,425 rows. That is the binding bound for **both**
candidates:

| candidate | depth by bytes | by cells | by rows | binding | footprint |
| --- | ---: | ---: | ---: | ---: | ---: |
| C6 | 81,920 | 6,425 | 16,384 | **6,425 (cells)** | 0.78 MB |
| **C1** | 19,859 | 6,425 | 16,384 | **6,425 (cells)** | **3.24 MB** |

The byte budget is slack under both, by 4.1x for C6 and 1.9x for C1, exactly as
`D8` predicted when it recorded that "the 10 MiB byte budget is now unreachable
for ordinary content". **So C1 retains the same rows C6 retains, and gives back
only memory.** Against pre-packing's ~5,799 rows at the same budget, C1 is still
**1.11x deeper at 3.1x less memory**; against C6 it is the same depth at 4.12x
more memory.

This is the fact that makes the pivot cheap, and it is not a property of C1 -- it
is a property of `D8`. Before the caps, an 8-byte cell would have cost 12.7x the
depth of a 1-byte one. The caps already neutralized depth-per-byte, which is why
paying 4x the bytes now buys back the read path for nothing that a user sees as
history length.

It also means **`D8`'s cell cap must not be re-derived from C1's bytes.** The cap
exists to bound reflow's per-cell term (`1.85 us/row + 0.352 us/cell`, `F15`),
which is a count of cells, not of bytes. C1 stores the same cells in more bytes,
so the fitted model's inputs are unchanged and the caps carry over untouched.

#### Observation 4 -- a 12-byte cell carrying `contentIdentity` inline was priced and is rejected

The one structural simplification C1 invites is folding `contentIdentity` into the
cell, which would leave admission a pure translate-copy with no scan of any kind.
Priced: **784.0 B/row** on the reference payload and 461.9 on the saturated pool,
against 528.0 and 343.4. That is **+48% memory to remove one comparison per cell
from a pass that already touches every cell** -- and the thing it removes costs
8.0 B/row, 1.9% of C1's payload, because `F12`'s contiguity holds. Rejected on
those numbers rather than on taste.

#### Observation 5 -- the predicted feed effect, stated skeptically because the last one was falsified three times

**Predicted: between -2% and +1.5%, most likely near neutral.** The reasoning, and
then the reason not to trust it:

C1's admission does strictly less classification than C6's -- no widest-scalar
scan to pick a stride tier, no style-run detection, no kind-exception table, no
spill directory -- leaving one identity-run comparison per cell on a pass that
already visits every cell. And it writes **8 B per stored cell where pre-packing
copied 32 B**, so its write traffic is *below* the baseline's, where C6's
`pack(_:)` was measured at 9.2% of feed self time (`F17` Observation 4).

Against that: **the plan's C6 feed prediction (~+1%, bounded +2%) was falsified by
three separate readings** (+2.72%, +3.10%, +5.18%, `F17` Observation 5), always in
the direction of costing more than predicted. The same reasoning style produced
that prediction. Nothing here entitles this one to more credit, and it is recorded
as the input to a gate rather than as a result.

Because the prediction is under ~2% and graduation turns on it, **`D1` pitch 3's
reopening condition fires**: the longer `terminal-feed` schedule is screened
before the deciding run. The plan's own falsification check retires that
obligation cheaply if a prototype measures the feed effect **above** ~2%, at which
point `F1`'s dead zone is not load-bearing and the screen buys nothing.

- Inference: C1 is priced at 3.42x cheaper per retained row than pre-packing and
  4.12x dearer than C6, at **identical retained depth** under `D8`'s caps, on two
  side tables instead of five. The pivot's cost is memory alone, and it is
  bounded: 3.24 MB against C6's 0.78 MB and pre-packing's ~10 MB.
- Competing interpretation, checked rather than argued: that C1's larger rows
  would cut depth and so partly undo `H3`'s win. They do not, because both caps
  count content and the byte budget binds under neither candidate. Checked by
  evaluating all three bounds for both candidates rather than by quoting the byte
  budget alone -- which is the single-arm error `F13` Observation 4 retired.
- Uncertainty, stated plainly:
  - Every figure here is a **model**, not a measurement of a C1 engine. `F13`
    Observation 2 is the standing warning: the header term was omitted from the
    Python table for the whole life of the C6 selection and only surfaced when the
    encoder was written. C1 is charged with a header here, but a real encoder can
    still find a byte the model does not know about.
  - The saturated pool is representation-dependent (`F13` Observation 1), so the
    pool figures are read at C6's pool and would re-weight under C1. The reference
    payload does not have this problem -- its rows are content-determined -- which
    is why it carries the headline.
  - The feed prediction is the weakest number in this finding and is labelled as
    such above.
- Next action: implement C1 behind the shipped seam and run `D3`'s success
  criterion. The memory read is the deciding measurement and is expected to be a
  **stated giveback against C6**, not a win against it -- the win is against
  pre-packing, and the gate's baseline is `678bfe9` for exactly that reason.

### F19 -- C1 measured: browsing and the read path are won, memory is 2.8x, resize holds `D8`'s line -- and `scrollback-stream` still answers `slower` at +6.51%

- Status: recorded, and it is **the deciding run for `D9`'s pivot**. Five of six
  calibrated workloads pass and one fails, so `H3` does not graduate. The gate's
  closing rule is unchanged and unmet: nothing may answer `slower`. The
  disposition returns to the human rather than being improvised into a second
  pivot.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: candidate `48f52b1` (C1 implemented, encoder
  single-pass) against the adjacent baseline `678bfe9` (pre-packing), both from
  clean trees. Release configuration. Every number at or after the evidence floor
  `dd51a12`.
- Conditions: AC power, no `DANTERM_BENCHMARK_ALLOW_BATTERY`. **Host conditions on
  the deciding run: load 1.88/6.74/6.81, 0.19 per processor across 10, busiest
  external `claude` 31.5% / `DanTerm` 5.6% / `nvim` 1.9%.** An earlier `confirm`
  at load 19.07 with `mobileassetd` at 81.8% was discarded before it was read as a
  verdict -- see Observation 4.
- Commands:

      just benchmark-confirm baseline=678bfe9
      just terminal-memory-probe "--payload scrollback-plain"                     # both arms
      just terminal-memory-probe "--payload scrollback-plain --columns 80 --rows 24"
      just terminal-resize-probe "--recipe saturating|sparse|wide --samples 20"

#### Observation 1 -- the verdict set, and the one that fails

| workload | pairs | threshold | C6 (`F17`) | **C1** | verdict |
| --- | ---: | ---: | ---: | ---: | --- |
| `retained-browse` | 4 | 1.05% | +3.27% | **-0.11%** | equivalent |
| `terminal-feed` | 2 | 2.5% | +5.18% | **+1.50%** | inconclusive |
| `content-churn` | 4 | 2.15% | +0.44% | **+1.72%** | inconclusive |
| `style-churn` | 4 | 2.0% | -0.11% | **+0.74%** | equivalent |
| `incremental-mixed` | 6 | 1.85% | +4.22% | **+1.27%** | inconclusive |
| **`scrollback-stream`** | 4 | 1.85% | +6.34% | **+6.51%** | **slower** |

`inconclusive` and `equivalent` are both passes; only `slower` blocks. Five
workloads moved from `slower` to a pass, and the one that decided against C6 --
`retained-browse`, the whole reason for the pivot -- came back **at the
pre-packing baseline**, a point estimate of -0.11% against a 1.05% threshold.
That is `D9`'s hypothesis confirmed: the residual C6 could not shed was the
decode, and removing the decode removed it.

The descriptive metrics say the same thing from the other side.
`incremental-mixed` plans frames **24.08% faster** than pre-packing and
`style-churn` 2.00% faster, on a read path that now loads a cell instead of
reassembling one.

**`scrollback-stream` is the exception, and it did not move.** +6.34% under C6,
+6.51% under C1, on representations whose per-row bytes differ by 4x. Its drain
went 163.2 -> 180.3 ms, so the cost is admission and only admission.

#### Observation 2 -- why that workload, and the mechanism is content shape rather than the encoder

`scrollback-stream` is one of the two corpus stimuli `F11` flagged as
**staircasing**: it emits bare LF with no CR, so each line starts where the last
ended and rows accumulate leading padding. Its measured shape is **134 stored
cells per row with 66.4% of them holding no scalar**, against ~50 cells for CRLF
content.

That is the worst possible content for a flat cell. C1 charges a never-written
padding cell the same 8 bytes it charges a printed one, so on this stimulus it
writes roughly **1,080 payload bytes per admitted row** where C6 wrote ~160 and
pre-packing moved an existing array without copying it at all. The regression is
proportional to that, and it is the only ladder workload whose rows have this
shape.

**This is a mechanism, not an exemption, and the verdict stands.**
`scrollback-stream` has a frozen decision rule and it answered `slower`; `F11`'s
staircase caveat bars *expected-yield claims* from resting on these two stimuli
and says nothing about their verdicts. It is worth recording alongside the number
that a real program writing through a PTY gets `ONLCR` from the tty driver and
does not produce rows of this shape -- but that is an argument about how much the
regression matters, which is a human decision, not one this doc can measure its
way out of.

#### Observation 3 -- the memory claim, measured at both geometries

| quantity | `678bfe9` | **C1** | C6 (`F16`) |
| --- | ---: | ---: | ---: |
| 179x66 retained rows | 5,865 | **6,491** | 1.12x deeper |
| 179x66 live heap | 10.49 MB | **3.72 MB** | 1.27 MB |
| 179x66 per row | 197 B | **123 B** | 69 B |
| 80x24 retained rows | 5,823 | **6,449** | -- |
| 80x24 live heap | 10.17 MB | **3.40 MB** | -- |
| 80x24 per row | 196 B | **121 B** | -- |

**C1 holds 1.11x more history in 2.82x less memory at 179x66, and 1.11x more in
2.99x less at 80x24.** The split does not vary with pane width, which is `F8`'s
standing property re-measured rather than assumed.

`F18`'s central prediction is confirmed exactly: **the cell cap binds and depth is
representation-independent.** At 179x66 the census reports 339,489 cells, of which
11,814 are the live grid (66 x 179), leaving **327,675 retained -- five cells
short of `D8`'s 327,680 cap**. C6 and C1 retain the same rows because both caps
count content.

Where `F18` was wrong is the size of the giveback, and it was pessimistic: it
predicted 528 B/row charged against C6's 128, a 4.12x ratio, and the probe
measures 123 B/row against 69, a **1.78x** ratio. The per-row constants -- the
16-byte slot, the 32-byte array header, and bucket rounding -- do not scale with
the payload, so a 4x payload is not a 4x row. The model was not wrong about
payload; it was quoted as though payload were the row.

#### Observation 4 -- resize holds `D8`'s line, as the caps predicted it would

| regime | pre-packing (`D8`) | at `D8`'s caps, C6 | **C1** |
| --- | ---: | ---: | ---: |
| dense | 99.5 ms | 117.6 ms | **116.9 ms** |
| sparse | 152.0 ms | 57.1 ms | **56.3 ms** |
| wide | 87.4 ms | 104.1 ms | **103.8 ms** |

All three within **1%** of `D8`'s numbers, so all three stay within 1.19x of
pre-packing. This is the expected result and it is worth stating why it was still
worth measuring: `F15`'s cost model is `1.85 us x rows + 0.352 us x cells`, whose
inputs are counts rather than bytes, and C1 stores the same cells in more bytes.
The prediction was that the caps carry over untouched. They do.

#### Observation 5 -- the encoder cost was how bytes were written, not what was encoded

Recorded because it nearly buried the pivot, and because it is the same class of
error `F17` found on the read side.

C1's first encoder appended each cell byte by byte -- eight `Array.append` calls
per stored cell, each with its own capacity and uniqueness check -- and measured
`terminal-feed` at **+6.19%**, *worse than the C6 encoder the pivot exists to
beat*, and worse than the +5.18% C6 itself measured. Writing the identical
encoding into a pre-sized buffer took it to **+2.05%**, and the deciding run reads
**+1.50%**.

Two follow-ons are recorded as **measured and rejected**, so nobody re-derives
them:

- Removing the last intermediate array (exact-size single allocation, no
  `append` anywhere) measured +2.70% against the bulk-copy form's +2.05% -- a tie
  inside noise at 2 pairs. Kept anyway, on the invariant that the blob's size is
  known before the first byte is written, and stated here as a structural choice
  rather than a speed one.
- Allocating the blob **uninitialized** (`Array(unsafeUninitializedCapacity:)`)
  to avoid memsetting a payload the writer then overwrites: `scrollback-stream`
  measured 183.1 ms drain against 180.3, no gain. Reverted rather than kept.

The generalization is worth stating once, because doc 28 has now paid for it
twice: **for a representation this small, the encoding is not the cost -- the
allocation and write pattern around it is.** `F17` found it on the read side (two
whole-row materializations per frame), and this finds it on the write side (eight
appends per cell). Neither was visible in any pricing model.

A first `confirm` run also had to be discarded before it was read: host load
19.07 with `mobileassetd` at 81.8%, which reported `scrollback-stream` at +9.74%
and `terminal-feed` at +3.00% against the idle run's +6.51% and +1.50%. `D1`
pitch 4's annotation is what made that visible, and `F2` remains the standing
incident for why the harness cannot catch it itself.

- Inference: `D9`'s pivot did what it was chosen to do. Browsing is at parity with
  pre-packing, the three other CPU regressions cleared, memory is 2.8-3.0x better
  at 1.11x the depth, and resize is unmoved. **`H3` does not graduate**, on one
  workload, for a reason that is the representation's shape rather than its
  wiring: a flat 8-byte cell charges a never-written padding cell full price, and
  `scrollback-stream`'s rows are two-thirds padding.
- Competing interpretation, checked rather than argued: that `scrollback-stream`'s
  +6.51% is the same admission cost the other workloads show, merely larger. It is
  not -- `terminal-feed` and `incremental-mixed` both cleared while this did not
  move at all between two representations differing 4x in per-row bytes, and its
  drain rose 10.5% while its draw tail *fell*. The cost tracks stored cells per
  row, which is the axis this stimulus is an outlier on.
- Uncertainty, stated plainly:
  - `terminal-feed` at +1.50% sits inside `F1`'s structural dead zone (band 0.75%,
    threshold 2.5%) and three readings of it span +1.50% to +2.70%. It is a pass,
    not a measured neutrality, and it is the one verdict here that would change
    under a longer schedule. `D1` pitch 3's screen was not run: the plan's own
    retirement condition is a prototype above ~2%, and two of three readings were.
  - Whether the padding-cell cost is recoverable **is not measured**. Any fix
    makes the cell column non-uniform, which is a representation change and a
    stop-and-report under the plan's boundary. Nobody should read "the cost is
    padding cells" as "the fix is cheap".
  - The memory figures are one payload at two geometries, as `D3` criterion 1
    specifies. The saturated pool would re-weight under C1 (`F13` Observation 1).
- Next action: none taken. The disposition returns to the human with this verdict
  set, per the instruction not to improvise a second pivot.

### F20 -- the `scrollback-stream` regression is admission's *copies*, not its bytes: folding the trim into the encoder buys -6.69%, and the staircase `F19` blamed is not in that workload at all

- Status: recorded. It closes the write-pattern task, and it **corrects `F19`'s
  stated mechanism** -- which was mine, and which this finding's own instrument
  contradicts. The `slower` verdict `F19` reported stands; the explanation it
  attached does not. Phase 2's resize-*profile* task is renumbered an eighth time
  and now claims `F21`.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: candidate base `1a3e1c9`, candidate tree
  `57483d78f75d3ea4a35068396aadfe2312a7e67c`, capturing four working-tree paths
  (`TODO.md`, `PackedRetainedRow.swift`, `Terminal.swift`,
  `TerminalPackedRetainedRowTests.swift`). Two baselines, on purpose: `678bfe9`
  (pre-packing, the gate question) and `1a3e1c9` (pre-fix `C1`, which is the only
  baseline that prices the fix itself).
- Conditions: AC power, low-power mode off. Reported per run below; the machine
  was busier this session than `F19`'s, and Observation 4 is what that cost.
- Commands:

      just benchmark-sample scrollback-stream 20            # before and after
      just benchmark-report <dir> '--thread terminal-pty-host --top 12'
      python3 ./scripts/terminal-benchmark-compare.py confirm --baseline 678bfe9
      python3 ./scripts/terminal-benchmark-compare.py confirm --baseline 1a3e1c9

- Artifacts (disposable `.build/`, pointers only):
  `.build/terminal-benchmark-profiles/2026-08-03-223047-40508` (before),
  `.build/terminal-benchmark-profiles/2026-08-03-223728-52200` (after),
  `.build/terminal-benchmark-comparisons/confirm/57483d78f75d-0000` (vs `678bfe9`),
  `.build/terminal-benchmark-comparisons/confirm/57483d78f75d-0001` (vs `1a3e1c9`).

#### Observation 1 -- admission is 19.7% of the drain thread, and half of it is copying cells rather than encoding them

Sampling the sustained workload and filtering to
`com.danneu.danterm.terminal-pty-host`, the subtree rooted at
`appendToScrollback` / `pack` / `compacted` / `scrollbackByteCost` /
`enforceScrollbackBudget` is **19.7% of 15,578 thread samples**. What is *in* it
is the finding:

| frame | share of thread |
| --- | ---: |
| `PackedRetainedRow.pack(_:)` (self) | 4.6% |
| `GridRow.compacted()` (self) | 2.4% |
| `initializeWithCopy for GridCell` | 1.6% |
| `swift_arrayInitWithCopy` | 1.4% |
| `swift_retain` | 1.2% |
| `swift_arrayDestroy` | 0.7% |
| `outlined consume of TerminalScalars.Storage` | 0.5% |

Roughly five points of the thread are spent **copying 32-byte `GridCell`s and
retaining their scalar payloads** -- `compacted()` allocating a second cell array
to drop a suffix the encoder was about to stop at anyway, and the encoder's own
two `enumerated()` walks copying each element again.

#### Observation 2 -- the fix, and what it is worth: -6.69% on `scrollback-stream` against pre-fix `C1`

Two changes, both inside `C1`'s uniform-cell shape, so no representation change
was needed or made:

1. **`pack` trims as it encodes.** Trimming is a decision about
   `storedCellCount`, which is the packed row's own field. All three call sites
   drop `.compacted()`; `GridRow.compacted()` stays as the independent statement
   of `I2` that the tests hold the encoder against, and calls nothing on the
   measured path.
2. **A never-written cell encodes to a zero word, and the blob is already zero,
   so the writer skips it.** This is the bulk fill, spelled as an omission.

`confirm` against `1a3e1c9`, host load 4.48/4.15/4.50 at invocation
(0.45 per processor), 3.54 before the first block:

| workload | verdict |
| --- | --- |
| `scrollback-stream` | **faster (-6.69%, 4 pairs)**; drain 184.3 -> 173.8 ms, draw tail 12.0 -> 9.1 ms |
| `content-churn` | equivalent (-0.12%) |
| `incremental-mixed` | equivalent (+0.39%) |
| `retained-browse` | equivalent (+0.40%) |
| `terminal-feed` | inconclusive (+1.67%) -- `F1`'s dead zone |
| `style-churn` | slower (+3.86%) -- see Observation 4 |

Re-sampled after the change, the admission subtree is **15.9%** of the thread and
`initializeWithCopy for GridCell` and `compacted()` are absent from the profile
entirely. That sample ran at load 13.6 and is attribution only.

#### Observation 3 -- against pre-packing it is still `slower`, at +4.13%

`confirm` against `678bfe9`, host load 2.03/4.03/4.64 at invocation (0.20 per
processor), 1.88 before the first block, busiest external `claude` 53.0% /
`DanTerm` 6.7%:

| workload | pairs | threshold | verdict |
| --- | ---: | ---: | --- |
| `retained-browse` | 4 | 1.05% | equivalent (-0.33%) |
| `incremental-mixed` | 6 | 1.85% | inconclusive (+1.17%), plan time -24.72% |
| `content-churn` | 4 | 2.15% | inconclusive (+1.70%) |
| `style-churn` | 4 | 2.0% | slower (+2.36%) -- see Observation 4 |
| `scrollback-stream` | 4 | 1.85% | **slower (+4.13%)**; drain 163.0 -> 171.9 ms |
| `terminal-feed` | 2 | 2.5% | **slower (+4.55%)** |

The fix moved `scrollback-stream` a long way and did not clear the gate.
`terminal-feed` reads `slower` here where `F19` read +1.50%; the two numbers are
from different machine sessions and the protocol does not license comparing them,
so what is recorded is that this session's reading is above threshold.

#### Observation 4 -- a control failed, and it is stated rather than used

`style-churn` answered `slower` in **both** runs (+2.36% and +3.86%). It cannot
have: `full-screen-style-churn` frames begin with `ESC[H` and omit the final
newline (`scripts/terminal-benchmark-producer.py#redraw_screen`), so the workload
never scrolls a row into history and therefore **never calls `pack` at all**. The
only candidate change in run two is the encoder. So the ladder was reading roughly
two to four points high on that workload while these numbers were taken.

That is recorded as a limit on this session's readings, **not** as grounds to
discard the ones that came out badly. No block was declared invalid and nothing
was re-run: the frozen protocol's whole point is that a verdict cannot be shopped
for, and "the control drifted" is exactly the argument that would let it be.

#### Observation 5 -- the staircase `F19` blamed is not in this workload; `ONLCR` removes it

`F19` attributed the regression to `F11`'s staircase -- 134-cell rows, 66.4% of
stored cells holding no scalar -- and that attribution is **wrong**, for a reason
`F11` itself had already written down and this finding failed to read.

- The stimulus emits bare LF: its template is
  `DANTERM-SCROLLBACK-{index:05d} sustained plain-text output payload\n`
  (`benchmarks/fixtures/terminal-app.json`, `scrollback-stream`, one segment
  repeated 25,000 times).
- But the benchmark producer runs **inside the pane's shell** and writes with
  `os.write(1, ...)` (`scripts/terminal_benchmark_fixtures.py#write_all`), so its
  bytes cross a real tty. `PTYSpawner` calls `openpty` with a `nil` termios
  (`lib/TerminalPTY/Sources/TerminalPTYHost/PTYSpawner.swift#PTYSpawner`), which
  installs Darwin's defaults: `references/xnu/bsd/sys/ttydefaults.h#TTYDEF_OFLAG`
  is `OPOST | ONLCR`.
- Measured directly rather than argued: a default `pty.openpty()` slave reports
  `OPOST` and `ONLCR` set, and `os.write(slave, b"one\ntwo\n")` is read from the
  master as `b"one\r\ntwo\r\n"`.

So the terminal receives **CRLF**, each line starts at column 0, and a retained
row is ~59 dense stored cells with no interior padding. The staircase is real, but
it belongs to the *probe*, which feeds the same corpus bytes to `Terminal`
directly with no tty in between. **Two stimuli share one name**, and `F19` priced
the CPU workload with the probe's shape.

The corroboration runs the same way elsewhere: Alacritty opens its pty with no
termios override and adjusts only `IUTF8`
(`references/alacritty/alacritty_terminal/src/tty/unix.rs#new`), and tmux sets
`c_oflag = OPOST|ONLCR` explicitly for the pane it hands a program
(`references/tmux/client.c#client_main`) while clearing those same flags on the
outer terminal it writes control sequences *to*
(`references/tmux/tty.c#tty_raw_start`) -- the opposite direction, which is what
confirms the flag governs program-to-terminal output.

- Inference: the write-pattern fix was the right instrument and it worked -- the
  cost was `compacted()`'s array copy and the encoder's element copies, which is
  the third time doc 28 has found the allocation and write pattern rather than the
  encoding (`F17` on reads, `F19` Observation 5 on writes, this on both). It did
  not clear the gate. **`H3` still does not graduate**, on `scrollback-stream` at
  +4.13% against a 1.85% threshold.
- What this closes, and it closes it against `H3`'s interest: the stimulus-fidelity
  question does not arise. `benchmark/scrollback-stream` is an ordinary program
  writing `\n` to a tty -- the most common shape output takes -- and the tty gives
  it CRLF. There is nothing unproducible about it, no `23/D4`-style demotion to
  propose, and no governance entry to write. The regression is over **dense,
  realistic CRLF rows**, which makes it matter *more* than `F19` claimed, not less.
- Competing interpretation, checked rather than argued: that the remaining +4.13%
  is the blank-cell cost the fix did not reach. It is not -- there are no blank
  cells in these rows. What remains is `C1`'s translate-copy on ~59 dense cells
  per admitted row (~472 payload bytes), which pre-packing did not pay at all
  because it stored the row's own array by reference.
- Uncertainty, stated plainly:
  - The `terminal-feed` readings are not settled. `+1.67%` against pre-fix `C1` and
    `+4.55%` against pre-packing were taken in the same session as a failing
    control, and `F1` says this workload's dead zone cannot resolve differences of
    this size anyway. No claim is made that the fix helped or hurt feed.
  - Whether the residual admission cost is further reducible is **not measured**.
    The profile still shows ~1.2% `swift_arrayInitWithCopy` and ~1.2%
    `swift_retain` under `pack`; nobody has attributed them.
  - Observation 5 corrects a mechanism, not a verdict. Every `slower` reading in
    `F19` was a real reading of a real workload.
- Next action: none taken. The disposition returns to the human as a decision
  package -- accept `scrollback-stream` as a trade, or fund further work on
  admission -- per the instruction not to improvise a second pivot.

### F21 -- `style-churn` was never a control for this range: its read path changed. Isolating the change that changed it clears it at `equivalent`, and turns up a regression on a different workload

- Status: recorded. It answers the control question `F19`/`F20` left open, and it
  **does not invalidate either run** -- the invalidation branch required
  `style-churn` to be untouched, and it is not. It also opens a new, isolated
  `slower` reading on `incremental-mixed` that no prior finding attributes. Phase
  2's resize-*profile* task is renumbered a ninth time and now claims `F22`.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: audit over `678bfe9..3402656`. Isolation run:
  baseline `52ac28b` (tree `ada2edf5fa5cf2f207fd0ae026f73dbe0b1528e8`), candidate
  base `2ae37c4` (tree `994e47769b4c38fa8188c2845141e33191dc76b6`), no
  working-tree changes -- an exact parent/child pair, measured out of a detached
  worktree so the candidate arm is the commit itself.
- Conditions: AC power, low-power mode off. Load at invocation 1.27/2.18/3.01
  (0.13 per processor across 10), 1.77 before the first block; busiest external
  `claude` 36.7%, `zsh` 3.4%, `DanTerm` 2.7%.
- Commands:

      git show 2ae37c4 -- lib/TerminalCore/Sources/TerminalCore/Terminal.swift
      git worktree add --detach <scratch>/wt-2ae37c4 2ae37c4
      python3 ./scripts/terminal-benchmark-compare.py confirm --baseline 52ac28b \
          --repository-root <scratch>/wt-2ae37c4

- Artifacts (disposable `.build/`, pointers only):
  `.build/terminal-benchmark-comparisons/confirm/994e47769b4c-0002`.

#### Observation 1 -- the claim "`style-churn` cannot be affected, it never calls `pack`" is true and irrelevant

`style-churn` never scrolls a row into history (`terminal-benchmark-producer.py#redraw_screen`
starts each frame at `ESC[H` and omits the final newline), so no admission code
runs. That covers the *write* side only. The *read* side is where a draw workload
spends its time, and `2ae37c4` rewrote both readers the frame planner uses --
for **every** row, live rows included, not just retained ones:

- `geometry` stopped materializing `presentedRows` and now builds
  `presentedRowGeometry`, which allocates a blank-filled `[TerminalCellGeometry]`
  per row and overwrites `min(row.cells.count, columnCount)` entries.
- `forEachViewportCell(row:_:)` stopped iterating `windowRow.cells` inline. Every
  cell now goes through a local `emit` closure that also writes
  `storedCount = column + 1` per cell.

A live row reaches both of those. So `style-churn` is **not a control for
`678bfe9..HEAD`** -- a workload whose measured path the range edits cannot
falsify the range.

#### Observation 2 -- and yet the change that changed its path measures `equivalent` on it

One `confirm` of `2ae37c4` against its parent `52ac28b`:

| workload | threshold | symmetric median | verdict |
| --- | ---: | ---: | --- |
| `retained-browse` | 1.05% | +0.16% | equivalent |
| `style-churn` | 2.0% | **-0.41%** | **equivalent** |
| `scrollback-stream` | 1.85% | -0.17% | equivalent |
| `content-churn` | 2.15% | +1.03% | inconclusive |
| `terminal-feed` | 2.5% | -0.95% | inconclusive |
| `incremental-mixed` | 1.85% | **+2.15%** | **slower** |

So the `+2.36%` `F20` reported on `style-churn` is **not attributable to the
commit that rewired its readers**, which is the only commit in the range that
touches its path at all. It is left unexplained: either it is the harness's own
spread on this workload (`agent-docs/terminal-performance.md` records 5 of 24
pure-noise `style-churn` pairs exceeding its band), or it belongs to a commit
whose mechanism nobody has proposed. No claim is made either way.

#### Observation 3 -- `incremental-mixed` at `+2.15%`, isolated to the reader rewiring

This is a new reading, not a restatement. `2ae37c4`'s own commit message priced
itself on `retained-browse`; nobody measured what the same rewiring costs a
workload that draws incremental updates over a *live* screen, where the new
`presentedRowGeometry` allocates a full-width kind array per row per frame that
the old path did not, and `forEachViewportCell` pays a closure call per cell. It
answers `slower` at +2.15% against a 1.85% threshold, with plan time +5.99%.

The whole-range runs read this workload at +1.27% (`F19`) and +1.17% (`F20`),
both `inconclusive`, which is consistent with a real ~2% cost partly offset by
the rest of the range -- `F19`/`F20` also measured plan time **24% faster**
across the full range. It is not consistent with the two being the same number.

#### Observation 4 -- what this does and does not license

- It **does not** invalidate `F19` or `F20`. Invalidation was conditional on
  `style-churn` being untouched by the range; Observation 1 shows it is not, so
  there is no failed control, and therefore no ground to re-measure. `F20`'s
  table stands as the deciding table and `H3` does not graduate on it.
- It **does** retire the phrase "control failure" from this doc's vocabulary for
  this range. `F20` used it, in good faith, on an argument that covered only the
  admission path. The correct statement is narrower and worse: **the ladder as
  run has no workload that this range provably cannot touch**, so nothing in it
  was serving as a control.
- The `incremental-mixed` reading is one `confirm` at one commit. It is a
  finding, not a gate: it isolates a cost, and what to do about it is a decision.
- Limits: no profile was taken of the `incremental-mixed` regression, so the
  attribution to the two rewired readers is *by construction* (they are the only
  production change in `2ae37c4`) and not *by measurement* of where the time
  went.
- Next action: none taken. This joins the decision package rather than starting
  a fix, per the instruction not to change code before the table exists.

### F22 -- the campaign's first wide-baseline reading: against pre-campaign DanTerm, HEAD feeds 2.4x faster and browses 2.2x faster while retaining 4.2x the history. Four of six workloads cannot reach that baseline at all

- Status: recorded. **Wide-baseline descriptive.** No verdict is issued and none
  may be quoted as one: the frozen per-workload thresholds were calibrated for
  adjacent comparisons and do not apply across a range this wide, so every
  number here is a direction and a magnitude, not a classification. It also may
  not be cited as adjacent evidence for any change inside the range. This is the
  smoke alarm `F2`/`F3` said the campaign needed and had never run. Phase 2's
  resize-*profile* task is renumbered a tenth time and now claims `F23`.
- Date and investigator: 2026-08-03, Claude (agent).
- Commit and worktree state: candidate `ba13d18` (tree
  `dc0404b3831f91fe5554ce4eb50787374d500f5f`), capturing one untracked
  working-tree path (`TODO.md`, prose, in no build). Baseline: the synthetic
  audit commit `98600c004309d88442a6ac9914e1f38cdae25d62` (tree
  `3626d5fdd83ee6051e9275c3b28bd222eb1d18f6`), built in a detached worktree and
  on no branch. Observation 1 pins what it is and Observation 2 what had to be
  added to compile it.
- Conditions: AC power, low-power mode off, thermal state nominal in every
  sampled block. `terminal-feed` load at invocation 1.20/1.29/1.65 (0.12 per
  processor across 10), 2.24 before the first block (confounded by this run's
  own builds); busiest external `claude` 28.4%. `retained-browse` 1.81/1.68/1.75
  (0.18 per processor) at both readings; busiest external `bluetoothd` 2.3%. No
  concurrent agent session other than this one.
- Commands:

      git worktree add --detach <scratch>/base-6c58c45 ba13d18
      git -C <scratch>/base-6c58c45 checkout 6c58c45 -- \
          lib/TerminalCore/Sources/TerminalCore \
          lib/TerminalCore/Sources/TerminalRenderPlanning \
          lib/TerminalCore/Sources/TerminalRenderExecution
      python3 ./scripts/terminal-benchmark-compare.py quick \
          --baseline 98600c004309d88442a6ac9914e1f38cdae25d62 --workload terminal-feed
      python3 ./scripts/terminal-benchmark-compare.py quick \
          --baseline 98600c004309d88442a6ac9914e1f38cdae25d62 --workload retained-browse

- Artifacts (disposable `.build/`, pointers only):
  `.build/terminal-benchmark-comparisons/quick/dc0404b3831f-0000` (feed) and
  `-0001` (browse).

#### Observation 1 -- the baseline is `6c58c45`, and it is the docs' own pre-change revision

`6c58c45` ("docs(design): record the damage-render benchmark routing decision",
2026-07-27) is the parent of `07c0cd3 perf(terminal): store cell scalars inline
instead of one array per cell`, the campaign's first shipped engine change.
`07c0cd3`'s own commit message reads "Measured against 6c58c45", and doc 9's
Phase 5 ledger names the same revision, so this baseline is quoted from the
record rather than reconstructed.

One shipped engine change is **inside** the baseline and therefore outside this
audit: `8188b9a perf(terminal): plan only the rows the terminal damaged`
(2026-07-27) is an ancestor of `6c58c45`. `17/F5` credits it with implementing
doc 9's H2. Everything this audit reports is net of damage-scoped planning, and
a reader comparing to an even earlier tree would see a larger win than the one
below.

#### Observation 2 -- what "the baseline arm" contains, exactly

The arm is not pre-campaign DanTerm whole. It is `6c58c45`'s
`TerminalCore` + `TerminalRenderPlanning` + `TerminalRenderExecution` with
**everything else at `ba13d18`** -- harness, stimulus fixtures, producer, app,
and PTY are common-mode across both arms by construction. That scopes the audit
to the core engine's accumulated drift and excludes the app-side render work
(docs 13, 29, 30) and the PTY work (docs 19, 20, 23), which sit identically in
both arms.

Four additions were required to compile it. None is on a measured path, and each
is named here so a later reader can price it rather than trust it:

1. `TerminalDefaultColors.swift` copied verbatim, plus a `Terminal` extension
   whose `init` and `setDefaultColors` accept the value and ignore it.
   `b5197a0 feat(terminal): answer default color queries` postdates the baseline;
   ignoring it reproduces the baseline's behavior, which is to answer no OSC
   10/11 query. Neither measured stimulus contains one.
2. `TerminalDamageSpans.swift` copied verbatim into `TerminalRenderPlanning`.
   Three pure functions over a `Set<Int>`, read by HEAD's benchmark instrument.
3. A `RenderTheme.defaultColors` projection, placed in `TerminalPaneSession`
   rather than in an engine target, that reads two fields the baseline already
   has.
4. App-side shims for `39abdbf feat(renderer): support complete theme
   presentation`: `ThemeRenderBridge` returns the single `RenderTheme.dark` the
   pre-campaign renderer had, and `TerminalRenderMetrics` gains initializers that
   discard the font size and family HEAD added and delegate to the baseline's.

Item 4 is the reason Observation 3 stops where it does. Those shims *execute* on
any workload that runs the app, so on those workloads the comparison would be
measuring the shims.

#### Observation 3 -- the comparability table

Comparable means the stimulus bytes and the measured code path are identical
across the range. Established by compiling and by reading each block's own
identity fields, not by inspection.

| workload | class | basis |
| --- | --- | --- |
| `terminal-feed` | **comparable** | headless `TerminalCoreBenchmark`, built unmodified from HEAD's harness; fixtures and producer come from the baseline arm, so both arms are driven by one immutable copy |
| `retained-browse` | **comparable** | headless `TerminalBrowseBenchmark`, built unmodified; both arms report `stimulusIdentity` `retained-browse-v1-10000-lines-oldest-row-179x66` and the *same* `planCellChecksum` 5,940,000, so the frame planned is identical content |
| `content-churn` | **not comparable** | drives the real app, so Observation 2's item-4 shims run |
| `style-churn` | **not comparable** | same |
| `incremental-mixed` | **not comparable** | same |
| `scrollback-stream` | **not comparable** | same; `reset` is `fresh-optimized-app-and-terminal-session-per-block` |
| memory probe (both geometries) | **not measured** | `TerminalMemoryCensus` does not exist at the baseline; `TerminalMemoryProbe` does not build there |
| resize probes (all three regimes) | **not measured** | `TerminalResizeProbeSupport` needs `productionScrollbackBudgetBytes`, which is `internal` at the baseline; making it `public` is an engine edit |

The four app-driven workloads have a second, independent blocker:
`app/TerminalBenchmark.swift` is 538 lines behind HEAD's block contract at the
baseline, so its published blocks would not satisfy HEAD's validation even if
the engine API matched. A full-ladder wide run needs a baseline no older than
`39abdbf` (2026-07-31) -- roughly docs 27-30 -- which is close enough to HEAD
that it would mostly re-measure ground the adjacent runs already cover. Whether
`39abdbf` exactly suffices was not tested.

#### Observation 4 -- the descriptive results

Two pairs per workload, `quick` mode. Percentages are the harness's symmetric
form, `(candidate - baseline) / mean`; the ordinary form is given beside it
because the two differ a lot at this magnitude and a reader must not mistake one
for the other.

| workload | baseline | HEAD | symmetric | ordinary | pair spread |
| --- | ---: | ---: | ---: | ---: | ---: |
| `terminal-feed` | 3,200.3 / 3,194.4 ms | 1,345.2 / 1,345.1 ms | **-81.55%** | **-57.9%** (2.38x faster) | 0.15 pp |
| `retained-browse` | 739.8 / 738.5 us/frame | 335.6 / 335.7 us/frame | **-75.09%** | **-54.6%** (2.20x faster) | 0.18 pp |

Both pair spreads are under 0.2 percentage points against effects of 75-82%, so
neither reading is close to anything the instrument could confuse with noise.

Depth, measured in the same blocks rather than modeled: the browse arms report
`retainedRowCount` **1,717 at the baseline and 7,281 at HEAD** from the identical
10,000-line stimulus at 179 columns -- **4.24x the history**, retained while
planning the same frame in less than half the time. Both are under `D8`'s 16,384
row cap, so neither arm is clipped by it.

No memory number is reported. `15/F1`'s pre-campaign census (222.0 MB process
footprint, 48.2 MB of `[GridCell]` row storage) is a *different instrument* on a
different scenario and is not convertible into the retained-bytes figure
`F20`'s probe reports; quoting the two side by side would invent a comparison
neither measured.

#### Observation 5 -- the smoke alarm reading

**Empty.** There is no comparable workload on which HEAD is slower than
pre-campaign DanTerm, so no bisect is opened and no follow-up work is filed
under this observation.

The honest limit on that sentence: it covers two of six workloads. The four it
does not cover are the draw-path workloads, and they are exactly where an
accumulation drift would be least visible to these two. What the audit
establishes is that the parse/feed path and the browse/plan path did not
accumulate a regression; it says nothing either way about the draw path, and no
instrument in this run could have.

#### Observation 6 -- the decision input for `H3`

`F21` left `H3`'s disposition with the human on `F20`'s table, where C1's
residuals are `scrollback-stream` +4.13% and `terminal-feed` +4.55%. This audit
prices those residuals against where HEAD actually sits:

- `terminal-feed` is the one residual this run can place absolutely. HEAD feeds
  a fixed batch in 1,345 ms against pre-campaign 3,197 ms. C1's +4.55% is
  ~61 ms on that batch -- it gives back about **3.3% of a 1,855 ms win**, and
  leaves the feed path 2.30x faster than it started rather than 2.38x.
- `scrollback-stream` **cannot** be placed absolutely: it is one of the four
  not-comparable workloads. Its +4.13% remains a purely adjacent number, and
  nothing here says whether sustained plain output is above or below its
  pre-campaign cost.
- `retained-browse` is where C1 was supposed to pay off, and the absolute
  reading is the strongest number in this audit: browsing is 2.20x faster than
  pre-campaign while holding 4.24x the history.

So the accept-as-trade option spends a slice of a large win on the one residual
that can be checked, and an unknown on the other. That asymmetry is the finding;
which way it should decide the disposition is not.

### F23 -- sizing 10,000 retained rows at 179 columns: the ~150 ms budget buys 10,000 rows only at 37 cells/row, and measured content is 45-179. Full-width 10k costs 600.5 ms and 14.8 MiB

- Status: recorded. **Descriptive sizing measurement, and a decision package for
  a bound change that has not been made.** No default is changed here, no cap
  constant is edited, and no threshold is frozen. Every candidate below is an
  option priced against `D8`'s existing model and budget; choosing one reopens
  `D8` and is a human decision. Phase 2's resize-*profile* task is renumbered an
  eleventh time and now claims `F24` -- this entry measures resize *cost at
  candidate depths*, which is not the profile of *where inside reflow the time
  goes* that `F14`/`F15` left owed.
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: `ab60a0b` (tree
  `d46fbee7fe81a5c0fff6146e6f0d497d318a2a3e`), plus two untracked paths --
  `TODO.md` (prose, in no build) and
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalHistoryDepthSizingProbe.swift`,
  the harness this entry adds, committed with it.
- Conditions: AC power, low-power mode off. No paired benchmark was run and no
  verdict is claimed, so the corpus's calibration gate does not apply; the
  numbers are probe distributions and engine counters, both of which are
  deterministic except the resize timings, which are reported as
  median/min/max over 20 samples.
- Commands:

      just terminal-retained-row-probe "--json"
      just terminal-resize-probe "--recipe wide"
      DANTERM_HISTORY_DEPTH_PROBE=1 swift test -c release \
          --package-path lib/TerminalCore --filter TerminalHistoryDepthSizingProbe

- Artifacts: the retained-row probe's JSON and the sizing probe's stdout are
  disposable; every number quoted below is reproduced by re-running the three
  commands above. The full-width stimulus fed to the retained-row probe is
  `ResizeProbePayload.wide`'s line, generated by the driver rather than
  committed, and labelled `bound/wide-full-width-saturation` for the same reason
  `bound/all-blank-saturation` is: it is a synthetic ceiling, not a sample of
  what real sessions retain.

#### Observation 1 -- what retained rows hold at 179 columns, per content class

From the retained-row probe, which reads the cells-per-row distribution through
the public row API. `censusRetainedStoredCellCount` and `derivationMatchesCensus`
both agree with the engine on every row below, so the extents are the engine's.

| content class | rows | cells/row median | p95 | mean | payload B/row |
| --- | ---: | ---: | ---: | ---: | ---: |
| `benchmark/scrollback-stream` | 2,445 | 119 | 179 | 134.0 | 1,086.8 |
| `benchmark/unicode-wrapping` | 2,546 | 161 | 179 | 128.6 | 1,070.4 |
| pooled real corpus (benchmark + recordings) | 5,124 | 154 | 179 | 128.3 | 1,054.3 |
| `reference/scrollback-plain` (~50-col lines) | 6,425 | 51 | 51 | 51.0 | 423.0 |
| `bound/wide-full-width-saturation` (179-col lines) | 1,830 | 179 | 179 | 179.0 | 1,447.0 |
| `alacritty/history` (shell history) | 74 | 2 | 2 | 4.4 | 50.2 |

**The headline is the p95.** At 179 columns the corpus's two retaining benchmark
workloads sit at p95 = 179 cells/row -- their upper tail *is* the worst case, and
their median is 119-161. "Typical" and "full-width" are not far apart at this
width, which is why the two candidate definitions in Observation 3 do not
separate as cleanly as the question assumes they will.

The B/row column above is the **packed payload**, which is what the retained-row
probe reports and is not what the byte budget is compared against. The engine
charges a row its slot, array header, capacity slack and any spill directory
(`scrollbackByteCost`). Measured through `scrollbackByteCount` -- the counter the
budget actually tests -- the charge is:

| payload | cells/row | charged B/row |
| --- | ---: | ---: |
| wide (179-col lines) | 179.0 | 1,552.0 |
| dense (~50-col program output) | 45.0 | 464.0 |
| sparse (shell history) | 4.9 | 108.0 |

Charged is ~1.07x payload on the wide class. Every byte figure in Observations 2
and 3 is the charged one.

#### Observation 2 -- which bound binds first today, and the arithmetic behind it

A class retains `min(cellCap / cellsPerRow, rowCap, budget / chargedBytesPerRow)`
rows. With `cellCap` 327,680, `rowCap` 16,384 and `budget` 10 MiB:

| content class | cells/row | cell cap gives | row cap gives | byte budget gives | **binds** | measured rows |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| wide | 179.0 | 1,830 | 16,384 | 6,756 | **cell** | 1,830 |
| dense | 45.0 | 7,281 | 16,384 | 22,598 | **cell** | 7,281 |
| sparse | 4.9 | 66,873 | 16,384 | 97,090 | **row** | 16,384 |

The measured column is the sizing probe's, and it reproduces the arithmetic
exactly. The crossover is `cellCap / rowCap` = **20.0 cells/row**: above it the
cell cap binds, below it the row cap does. Every real content class measured in
Observation 1 is at 45 cells/row or above, so **the cell cap is the operative
bound at 179 columns for everything except shell history and blank lines.**

The byte budget binds nothing today: the deepest charged footprint any class
reaches under the caps is 3.38 MB of 10 MiB (dense, 7,281 rows). That is `D8`'s
recorded consequence -- the budget became a memory backstop rather than the
depth bound -- confirmed at this geometry.

**Today's depth at 179 columns is therefore 1,830 rows of full-width content,
7,281 of ordinary program output, and 16,384 of shell history.** The 10,000-row
target is already met for sparse content and is a 1.4x-5.5x increase for the
rest.

#### Observation 3 -- two candidates, priced through `D8`'s frozen model

`D8`'s model is `1.85 us x rows + 0.352 us x cells`, its budget is ~150 ms, and
its stated multiple is against the **99.5 ms pre-packing baseline**. A candidate
must also state a row cap, and the row cap is not free to choose: narrowing to
`W` columns multiplies row count by up to `cellsPerRow / W`, so a row cap below
`cellCap / W` evicts content that widening cannot restore. `D8` bought
losslessness down to 20 columns at `cellCap / rowCap` = 20; holding that property
is what sets each candidate's row cap below.

**Candidate (a) -- 10,000 rows of typical content**, sized from the ~50-col
program-output class (51 cells/row measured, 45 on the probe's line):
`cellCap` 510,000, `rowCap` 25,500, budget unchanged at 10 MiB.

- Byte check: 464.0 B/row x 11,333 rows = **5.02 MiB**. 10 MiB covers it.
- Row-cap check: 25,500 = 510,000 / 20, so losslessness to 20 columns holds.
- Worst case, both bounds binding: `1.85 x 25,500 + 0.352 x 510,000` = **226.7 ms**,
  **2.28x** the baseline.
- Measured at the depth it actually reaches (11,333 rows, 509,985 cells):
  **179.0 ms**, **1.80x** baseline, 1.19x the budget.

**Candidate (b) -- 10,000 rows of full-width content**: `cellCap` 1,790,000,
`rowCap` 89,500 (= 1,790,000 / 20), budget must rise.

- Byte check: 1,552.0 B/row x 10,000 rows = **14.80 MiB**. 10 MiB does **not**
  cover it, and this is measured rather than derived: at the production budget
  the candidate's wide fill stopped at **6,756 rows** with the *byte* bound
  binding, not 10,000. Reaching 10,000 needs a budget of ~16 MiB.
- Worst case, both bounds binding: `1.85 x 89,500 + 0.352 x 1,790,000` =
  **795.7 ms**, **8.00x** baseline.
- Measured at 9,968 rows / 1,784,172 cells: **600.5 ms** (min 594.1, max 632.9),
  **6.04x** baseline, **4.00x** the budget.

A third setting was measured because it is the one a reader would reach for
first, and it fails for a reason time alone does not show. **Candidate (b) with
`rowCap` left at 10,000** prices at 296.3 ms -- half of (b)'s cost -- but only
because the first narrowing to 100 columns **evicted 5,032 of its 10,000 rows**,
irrecoverably. `cellCap / rowCap` is 179 there, so every narrowing below 179
columns destroys history. It is not a cheaper candidate; it is a candidate that
does not hold 10,000 rows.

#### Observation 4 -- the harness is calibrated against the committed probe

The sizing probe fills at candidate bounds and then times width changes with
`measureSaturatedResize`'s alternation, warmup and clock. Its first point is a
calibration, not a result: at production bounds with the wide payload it must
reproduce `just terminal-resize-probe --recipe wide`.

| | retained rows at start | median resize |
| --- | ---: | ---: |
| committed probe, `saturated-wide-resize-v1` | 1,798 | 107.0 ms (104.7-109.0) |
| sizing probe, production bounds | 1,798 | 104.4 ms (102.8-108.7) |

Same depth, medians within 2.5%. The candidate numbers in Observation 3 are read
off the same harness.

The frozen model **overpredicts** measured cost by 7.7-12.0% at all four points
(116.6 vs 104.4; 646.5 vs 600.5; 200.5 vs 179.0; 322.2 vs 296.3). It is
conservative in the safe direction, and both the modelled and measured figures
are quoted above rather than one standing for the other.

#### Observation 5 -- what this means for `D8`'s budget, and where `H7` enters

Rearranging the model at a fixed 10,000 rows: `150,000 us - 1.85 x 10,000` leaves
131,500 us for the cell term, which is **373,580 cells, or 37.4 cells/row**.

> **The ~150 ms budget buys 10,000 retained rows only if those rows average 37
> cells or fewer.** Measured content at 179 columns is 45 (program output), 51
> (the plain reference payload), 128-154 (the benchmark corpus) and 179
> (full-width).

Equivalently: at 179 cells/row the budget buys **2,313 rows**, which is why
today's cell cap lands the wide class at 1,830.

So no definition of "10,000 lines at 179 columns" fits `D8`'s budget as it
stands. Candidate (a) misses by 1.19x-1.51x; candidate (b) misses by 4.0x-5.3x
and additionally needs the byte budget raised ~1.6x, which would give back a
large share of the retained-memory win `D10` had just banked (3.72 MB at 179x66
becomes ~15 MB for the wide class).

This is precisely the condition `D8` named in its reopening clause and `H7`
(hybrid lazy reflow) was parked for: both caps exist only because reflow visits
every retained row, and both candidates' prices are that visit. A reflow path
that does not visit every row breaks the depth-is-latency coupling, and raising
the caps is the thing it would be raised *for*. **`H7` is the prerequisite for
candidate (b), not an optimization that would follow it.** Candidate (a) is the
only one reachable without `H7`, and only by widening `D8`'s budget from ~150 ms
to ~230 ms (2.28x the baseline rather than 1.46x).

What this entry does not settle: whether 10,000 rows is the right target at all,
which definition of it the product wants, and whether a resize budget of 2.28x
the pre-packing baseline is acceptable. Those are `D8`'s to reopen.
