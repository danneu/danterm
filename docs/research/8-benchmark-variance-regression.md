# Benchmark variance regression on `incremental-mixed`

Research started: 2026-07-27.

> **Continuing this file?** Read [Purpose](#purpose) and
> [Investigation rules](#investigation-rules), then the
> [Task ledger](#task-ledger) for the first unchecked item. The next action is
> the `b7f5c12` bisect probe (Phase 2) with a `content-churn` control;
> [Reproduction recipes](#reproduction-recipes) has the exact commands, the
> driver source, and the analysis snippet. Read **F9** before choosing a readout
> -- the block floor, not the paired SD, is the primary signal. Check
> [Rejected](#rejected) before proposing anything; five plausible explanations
> are already excluded with evidence, including the two the investigation
> started from.
>
> Related, both untracked and both superseded by this file for the variance
> question: `plans/wip/continue-elegant-boot.md` (F7 section -- the original
> observation) and `plans/wip/f7-arm-confound-diagnosis.md` (the interim
> diagnosis, whose arm/positional conclusions are rejected here as R1/R2).

## Purpose

This file owns one question: **why did the `incremental-mixed` paired-benchmark
metric become roughly four times noisier than the distribution its frozen
decision thresholds were calibrated against, and what is the correct fix?**

It exists because the harness is currently returning false directional verdicts
at ~40% on that workload, which makes it unable to decide any change to the
damage-scoped render path -- the one thing it is the only workload able to see.
The decision boundary this file must preserve: **`incremental-mixed` is the only
workload that can catch damage-scoping regressions**, so "retire it" or "widen
its threshold until it stops lying" are not acceptable outcomes. The instrument
must be repaired, then recalibrated.

It supersedes the arm-confound framing recorded as F7 in
`plans/wip/continue-elegant-boot.md` and the interim diagnosis in
`plans/wip/f7-arm-confound-diagnosis.md`; both are kept, and the reasons their
hypotheses were rejected are in [Rejected](#rejected).

## Investigation rules

- **No hacks.** Widening a threshold, adding retries to the comparison path,
  dropping a warm-up block, or excluding outliers are all rejected a priori:
  each hides the defect rather than removing it. The instrument gets fixed at
  its cause, and only then is a threshold recalibrated from a clean series.
- **A recalibration is the last step, never the first.** A threshold refrozen
  against a degraded distribution permanently encodes the degradation.
- **Cross-revision variance comparisons require a same-session control.**
  Every `incremental-mixed` series must be interpretable only alongside a
  `content-churn` series that is known clean; without it, machine drift and an
  instrument regression are indistinguishable. See F3.
- **An invalid block is not a data point.** The calibration path may retry whole
  quartets (it decides nothing); the comparison path may not. Do not import
  retries into `terminal-benchmark-compare.py`.
- **Diagnostic tooling lives outside the repo** (session scratchpad) until a
  direction gate selects it. Nothing in `scripts/` is modified to collect
  evidence.
- **No performance claim about any commit** may be made from these series. They
  are unpaired, single-arm, A/A variance measurements. A directional claim needs
  `benchmark-quick`/`confirm`, which is exactly the instrument under repair.

## Trigger and current evidence

`just benchmark-quick baseline=HEAD workload=incremental-mixed` returned two
contradictory verdicts minutes apart on 2026-07-27, and an **A/A control** --
byte-identical compiled code on both arms -- returned `faster -9.97%`, a larger
false verdict than the real comparison it was checking.

The original reading (F7 in `continue-elegant-boot.md`) was that the verdict
tracked the *physical arm*. That reading is **rejected**; see R1.

Smallest useful summary of what is actually wrong, from F2 and F4:

| series | paired SD | within-block per-draw CV | between-block SD | false quick verdicts |
| --- | --- | --- | --- | --- |
| `incremental-mixed` 2026-07-24 (thresholds frozen here) | **1.49%** | 8.73% | **1.26%** | **0 / 24** |
| `incremental-mixed` today at `HEAD` | **6.26%** | **17.41%** | **4.18%** | **10 / 24** |
| `content-churn` 2026-07-24 | 1.15% | 5.83% | 0.96% | 0 / 24 |
| `content-churn` today at `HEAD` | 1.37% | 5.06% | 1.09% | 0 / 24 |

The frozen `incremental-mixed` rules are `quick` = 2 pairs at 3.8%, `confirm` =
6 pairs at 1.85%. The calibration gate that froze them required an A/A false
positive rate <= 0.05. It is now ~0.40.

Provenance and caveats: all "today" series were collected in one session on
2026-07-27 with the machine held idle by the operator, on the tree at
`4061096` unless stated. The 2026-07-24 reference series survive on disk under
`.build/terminal-benchmark-phase4-*-shared-bundle-calibration/2026-07-24/blocks.jsonl`
and were copied to the session scratchpad before `just test` wiped `.build/`.
An agent session was attached to the machine throughout; it cannot be removed by
an agent running the benchmark, and F3 is the control that bounds its effect.

## Current hypotheses

### H1 -- an instrument change between 2026-07-24 and `b834a44` inflated the variance

**Mechanism (generic):** something landed in the benchmark observer, the timing
instrumentation, or the render path that made the short 6-row draw path far more
variable per draw and far less repeatable per block, without affecting the
66-row workloads.

**Supporting evidence:** F4 (both variance axes moved for `incremental-mixed`,
neither for `content-churn`); F5 (the inflation is present at `b834a44`, which
predates both commits originally suspected); F7 (the window is bounded on both
sides).

**Competing explanations:** machine or session conditions (rejected by F3);
per-arm or positional bias (rejected by F2).

**Status:** strongly supported as a class. The remaining work is to name the
commit, which is H2/H3/H4.

**Window, established by F7:** after `b7f5c12` (2026-07-24 20:19) and at or
before `b834a44` (2026-07-27 10:44). Candidates, in order:
`b7f5c12`, `df80150`, `760e848`, `847f5c8`, `8e9bc45`, `b834a44`.

### H2 -- `b7f5c12` (the plan timer) added per-frame instrumentation that perturbs the draw path

**Mechanism:** `b7f5c12 feat(benchmark): report frame-planning time beside the
draw verdict` added timing around `planFrame`, which runs on the PTY-output
path. Per-frame clock reads and the extra bookkeeping land on the same thread
that must then service the draw. On an 880 us draw this is noise; on a 180 us
draw it is a much larger fraction, and the *variance* it contributes does not
have to be small just because the mean cost is.

**Distinguishing experiment:** collect a single-arm A/A series at `b7f5c12` and
at its parent `9c2b1a5`. `b7f5c12` is the first commit *known* to postdate the
calibration series, so it is the correct first bisect probe.

**Complication:** `terminal-benchmark-plan-calibration.py` requires the plan
metric and will refuse any revision before `b7f5c12`. Probing `9c2b1a5` or
earlier needs a draw-only collector driver (Phase 2 task).

**Confirms if:** `b7f5c12` shows paired SD ~5% and `9c2b1a5` shows ~1.5%.

### H3 -- `df80150` (observer cost reduction) removed incidental per-draw serialization

**Mechanism:** `df80150 perf(benchmark): stop the observer from outweighing the
drawing it measures` cut the observer's per-frame cost by roughly 5x (18-22% of
the main thread down to 3.3-3.9%, per
`plans/wip/benchmark-instrumentation-cost.md`). Expensive, *uniform* per-frame
work acts as a regularizer: it dominates and smooths the timing. Removing it
exposes the underlying variability of the short draw path. Under this
hypothesis the observer optimization is correct and desirable, and what it
revealed was always there -- which would make the fix belong in the render path
or the workload contract, not in the observer.

**Distinguishing experiment:** A/A series at `df80150` and its parent `b7f5c12`.

**Confirms if:** `b7f5c12` is clean and `df80150` is not.

**Note:** H2 and H3 are adjacent commits and are jointly resolved by one series
at `b7f5c12` plus one at `df80150`.

### H4 -- a planner change made short-damage draw cost bimodal -- REJECTED

**Rejected by F9**; kept for the record, full reasoning in **R9**. The mechanism
was a data-dependent fast/slow path in text-run construction introduced by
`9c2b1a5` / `647aa5a`, which would have shown up as two modes. Both the pooled
and the per-block distributions are single-peaked, so there are no modes to
separate -- the elevated CV is spread, not separation.

### H5 -- the short-damage draw path is intrinsically variable and something merely unmasked it

**Mechanism:** the variability is a real property of drawing 6 damaged rows --
glyph cache residency, dirty-rect coalescing in AppKit, or backing-store reuse --
and no commit "caused" it; a commit merely stopped hiding it by removing work
that had been setting a floor under every draw.

**Why it matters:** this is the hypothesis under which the correct fix is *not*
a revert. It would mean the workload contract or the render path needs to
change, and it is the reading most consistent with the "no hacks" constraint
producing real work rather than a revert.

**Supporting evidence:** **F9** -- the block floor fell ~8% while the tail grew,
which is the signature of a removed regularizer rather than added work. This is
now the leading hypothesis jointly with H3, which is its specific form (the
removed regularizer being the observer cost `df80150` cut).

**Distinguishing evidence:** if the bisect finds no single commit that flips the
variance, or if the flip coincides with a commit that only *removed* work, H5 is
the live reading. If it coincides with a commit that *added* work, H2 revives.

**Open sub-question, from F9:** "a fixed cost was removed" and "draw cost became
input-dependent" both drop the floor and fatten the tail, and they need
different repairs. The bisect alone does not separate them; see the Phase 3
task.

## Candidate direction, pending evidence

**Provisional and not yet justified.** No direction is selected. The shape the
evidence currently points at, in decreasing confidence:

1. Name the commit (Phase 2). Until then, any direction is speculation.
2. If H2 -- make the plan timer's per-frame cost not land on the measured path,
   or make it opt-in per invocation so the draw verdict is collected by an
   instrument that is not also timing the planner.
3. If H3 or H5 -- the target is the render path or the workload contract, and the
   right first move is a profile of the short-damage draw (Phase 3), not a
   harness change.
4. Only then, recalibrate `incremental-mixed` from a fresh two-arm series and
   re-freeze `DECISION_RULES`.

## Task ledger

### Phase 1 -- establish evidence and reproduction

- [x] Reproduce the false verdict on an idle machine with paired A/A controls.
      Result in **F1**.
- [x] Separate arm, position, and noise with a single-arm A/A series. Result in
      **F2**; rejections in **R1**, **R2**.
- [x] Establish a same-session clean control that rules out machine drift.
      Result in **F3**; rejection in **R3**.
- [x] Localize which variance axis moved (per-draw vs per-block). Result in
      **F4**.
- [x] Audit the frozen thresholds' provenance and the two leads carried in from
      the handoff. Result in **F6**; rejections in **R4**, **R8**.

### Phase 2 -- attribute the cause

- [x] Walk the recent history back far enough to exonerate or implicate the two
      commits under immediate suspicion. Result in **F5** (both exonerated).
- [x] Bound the regression window on both sides without spending machine time,
      by dating the calibration series from its own artifact schema. Result in
      **F7**; rejection in **R7**.
- [ ] **Collect a single-arm A/A series at `b7f5c12`** (first commit known to
      postdate the calibration series). Record paired SD, within-block CV,
      between-block SD, and simulated 2-pair false-verdict rate in a new finding.
      Decision gate: SD >= ~4% implicates `b7f5c12` or earlier (H2/H4);
      SD <= ~2% clears it and moves the window to `df80150`..`b834a44` (H3).
- [ ] **Collect a paired `content-churn` series at the same revision** as a
      same-session control, per the investigation rules. A bisect point without
      its control is not admissible evidence.
- [ ] **Build a draw-only A/A collector driver** in the session scratchpad, since
      `terminal-benchmark-plan-calibration.py` refuses any revision before
      `b7f5c12` (it requires the plan metric). Needed to probe `9c2b1a5` and
      earlier if the gate above implicates them. Must reuse
      `COMPARE.production_collectors` so the block contract is identical to
      production.
- [ ] **Continue the bisect** to a single commit, recording each probe as a
      finding. Budget for the F8 collection obstruction at every pre-`4061096`
      revision.
- [ ] **Decision gate D1:** name the commit and the mechanism class (added work,
      removed work, or unmasked pre-existing variance). Do not proceed to a fix
      before this gate.

### Phase 3 -- characterize the mechanism

- [x] **Test whether the per-draw distribution is bimodal** rather than merely
      wider, pooled and per-block. Result in **F9**: unimodal both ways, the
      spread grew in both directions, and the block floor dropped ~8%.
      H4 rejected (**R9**); H3/H5 strengthened; H2 demoted.
- [ ] **Determine what set the old floor.** F9 says a uniform per-frame cost was
      removed; name it. If it is the observer work `df80150` cut, the observer
      optimization is correct and the fix is elsewhere -- which is the H5 reading
      and the one that produces real work rather than a revert.
- [ ] Distinguish "a fixed cost was removed" from "draw cost became
      input-dependent" (F9's competing interpretation). These need different
      repairs and the bisect alone will not separate them.
- [ ] Profile the short-damage draw path per
      `agent-docs/terminal-performance.md` (`just benchmark-sample`), collecting
      at least two textual profiles before treating a stack as stable. Only
      after the bimodality question is answered.
- [ ] Determine whether the variance is attributable to work inside `draw(_:)`
      or to scheduling around it. The draw timer brackets only clipping and
      drawing, so a scheduling answer changes what the fix can even target.

### Phase 4 -- direction gate

- [ ] **Decision D2:** select the fix, with candidates compared and correctness
      risks recorded. Report findings and pause for review before implementing,
      per `agent-docs/terminal-performance.md`.

### Phase 5 -- implement and verify

- [ ] Implement only the selected direction, TDD, with structure-insensitive
      behavioral tests.
- [ ] Re-collect the single-arm A/A series and confirm paired SD returns to
      ~1.5% with a clean `content-churn` control alongside.

### Phase 6 -- recalibrate and close

- [ ] Collect a fresh **two-arm** `incremental-mixed` A/A series matching the
      production shape (96 blocks / 48 pairs / 24 quartets).
- [ ] Re-screen and re-freeze `DECISION_RULES` via
      `scripts/terminal-benchmark-median-fallback.py`. A human moves the frozen
      rule after reading the report.
- [ ] Settle the F7 measurement still owed on `4061096` in
      `plans/wip/continue-elegant-boot.md`, which is blocked on this file.
- [ ] Graduate the settled decision to `docs/design/` and record here where it
      went.

## Reproduction recipes

Everything below is operational detail a continuing agent needs. It is here
rather than in a session scratchpad because scratchpads do not survive a
handoff.

### Where the evidence lives, and how fragile it is

| what | path | status |
| --- | --- | --- |
| 2026-07-24 reference series (the pre-regression anchor) | `.build/terminal-benchmark-phase4-{incremental,content,style}-shared-bundle-calibration/2026-07-24/blocks.jsonl` | **survives today, but `.build/` is disposable -- `just clean` destroys it** |
| single-arm series collected 2026-07-27 | `.build/terminal-benchmark-plan-calibration/c9562e10c053-{0000,0001}/blocks.json` | disposable |
| bisect probes | `.build/terminal-benchmark-attribution/<tree>-NNNN/blocks.json` | disposable |
| the five A/A comparison runs of F1 | `.build/terminal-benchmark-comparisons/quick/` | disposable |

**Copy the 2026-07-24 series somewhere durable before running `just clean`.** It
is the only surviving record of the distribution the thresholds were frozen
against. Every statistic this file draws from it is already tabulated in F4, F5
and F9, so losing the raw data degrades the investigation but does not end it --
and the pre-regression revision can be re-measured today, which is what the
Phase 2 bisect does anyway.

Two different on-disk shapes, both carrying `drawDurationsNanoseconds`:

- `blocks.jsonl` (2026-07-24): one JSON object per line, keys
  `arm` (`"A"`/`"B"` source label), `ordinal`, `result`, `state`. Draw data at
  `row["result"]`.
- `blocks.json` (all 2026-07-27 series): `{workload: [quartet, ...]}` where each
  quartet is a list of 4 blocks. Draw data at
  `block["artifact"]["finalDraw"]`; the per-block metric is
  `block["drawNanosecondsPerDraw"]`, role at `block["measurementRole"]`.

### Collecting a single-arm A/A series

The standard probe, for any revision at or after `b7f5c12`:

    python3 scripts/terminal-benchmark-plan-calibration.py \
      --revision <rev> --workload incremental-mixed --quartets 24 --trials 2000

This binds both physical slots to one source root and schedules every block on
slot `a`, so **the arm term is zero by construction** while launch order and
window stacking stay identical to production. Its printed report covers *plan*
time only -- **ignore it** and read `blocks.json` for the draw metric.

**The default retry allowance of 4 is not enough below `4061096`** (F8). Raise it
by calling the module directly; this modifies no repository source:

```python
# scratchpad driver: python3 driver.py <revision> <quartets> <max-attempts>
import importlib.util, pathlib, sys
ROOT = pathlib.Path("/Users/dan/Code/danterm-terminal-engine")
spec = importlib.util.spec_from_file_location(
    "plancal", ROOT / "scripts/terminal-benchmark-plan-calibration.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.run_calibration(
    revision=sys.argv[1], workloads=("incremental-mixed",),
    quartets=int(sys.argv[2]), trials=500, seed=20260727,
    repository_root=ROOT,
    cache_root=ROOT / ".build/terminal-benchmark-arms",
    artifacts_root=ROOT / ".build/terminal-benchmark-attribution",
    maximum_attempts=int(sys.argv[3]))
```

`python3 driver.py b7f5c12 12 25` is the shape that worked for `b834a44` and
`8e216bc`.

**Revisions before `b7f5c12` need a different collector.** `run_calibration`
requires the plan metric and raises "blocks report no plan time" without it. A
draw-only driver must build an A/A schedule and call
`COMPARE.production_collectors(schedule, artifacts, arm_roots={"a": root, "b":
root}, repository_root=root)` directly, reusing the production collectors so the
block contract is identical. This is an open Phase 2 task.

### Reading a probe

Primary readout is the **block floor**, per F9 -- lower variance than the paired
SD, so it localizes with fewer quartets.

```python
import json, statistics as st
sym = lambda a, b: 200 * (b - a) / (a + b)

def probe(path, workload="incremental-mixed"):
    kept = json.load(open(path))[workload]
    blocks = [b["artifact"]["finalDraw"]["drawDurationsNanoseconds"]
              for q in kept for b in q]
    floors = [sorted(d)[len(d) // 10] for d in blocks]   # in-block p10
    meds   = [st.median(d) for d in blocks]
    pairs  = []
    for q in kept:
        for i in (0, 2):
            r = {q[i]["measurementRole"]:   q[i]["drawNanosecondsPerDraw"],
                 q[i+1]["measurementRole"]: q[i+1]["drawNanosecondsPerDraw"]}
            pairs.append(sym(r["A"], r["B"]))
    q2 = [st.median(pairs[i:i+2]) for i in range(0, len(pairs), 2)]
    return {
        "blockFloorMedian": st.median(floors),
        "blockFloorSpan":   max(floors) - min(floors),
        "blockMedianSDpct": 100 * st.pstdev(meds) / st.mean(meds),
        "pairedSDpct":      st.pstdev(pairs),
        "falseQuick":       f"{sum(abs(x) >= 3.8 for x in q2)}/{len(q2)}",
    }
```

Reference values to compare against (F9): clean = block floor median **161396**
ns, span **18208**, block-median SD **1.44%**, paired SD **1.49%**, 0/24 false.
Degraded at `HEAD` = **148376**, span **33208**, **4.65%**, **6.26%**, 10/24.

### Operating conditions

- **The operator must hold the machine idle** for every series; ask and wait.
  The benchmark takes over the screen.
- A 24-quartet `incremental-mixed` series is ~110 s of measurement plus build or
  cache time; budget 5-15 min per probe, more for a cold build or heavy retries.
- **Run long collections detached.** A foreground call is capped at 10 minutes
  and will be killed mid-collection, wasting the run.
- Each probe needs a paired `content-churn` control at the same revision, per
  the investigation rules.

## Findings log

### F1 -- the false verdict reproduces on an idle machine

- **Status:** closed.
- **Date:** 2026-07-27.
- **Commit and worktree state:** baseline `HEAD` = `4061096`; candidate = working
  tree, differing from `HEAD` only in untracked `.md` files, so **both arms
  carry byte-identical compiled code**. Arm assignment steered by re-rolling the
  candidate tree hash, whose parity `physical_candidate_arm()` reads, via a
  scratch `plans/wip/*.md` file since removed.
- **Command:** `just benchmark-quick baseline=HEAD workload=<workload>`.
- **Artifacts:** `.build/terminal-benchmark-comparisons/quick/` (disposable;
  copied to session scratchpad).
- **Measurements** -- blocks in collection order, `A` = baseline role, `B` =
  candidate role. A quick invocation is a single ABBA quartet, so the candidate
  always holds slots 1 and 2. Metric `drawNanosecondsPerDraw`.

  | run | cand arm | block order (role/arm = ns) | pairs | estimate | verdict |
  | --- | --- | --- | --- | --- | --- |
  | `33419afa7ae7-0000` | a | A/b=187007 B/a=176312 B/a=187822 A/b=187821 | -5.89, 0.00 | -2.94% | inconclusive |
  | `93005623add7-0000` | b | A/a=163585 B/b=179089 B/b=191456 A/a=181965 | +9.05, +5.08 | +7.07% | **slower (false)** |
  | `fc9b8e5d4c1c-0000` | b | A/a=157983 B/b=191270 B/b=181889 A/a=191709 | +19.06, -5.26 | +6.90% | **slower (false)** |
  | `b99cf98083b1-0000` | a | A/b=167595 B/a=161422 B/a=196140 A/b=172449 | -3.75, +12.85 | +4.55% | **slower (false)** |
  | `24f27cca1ca1-0000` (content-churn) | b | A/a=863845 B/b=878392 B/b=866734 A/a=882211 | +1.67, -1.77 | -0.05% | equivalent |

- **Observation:** 3 of 4 `incremental-mixed` A/A controls returned a false
  `slower` verdict. All five runs were `decisionEligible: true` with empty
  `invalidationReasons`.
- **Inference:** these are valid invocations producing wrong answers, not failed
  measurement conditions. The frozen 3.8% threshold does not cover the current
  distribution.
- **Competing interpretations:** at the time, the candidate-arm split (+0.80%
  on arm a, +6.98% on arm b) looked like a per-arm offset. Superseded by F2.
- **Uncertainty:** n=4. Insufficient on its own to characterize the
  distribution, which is why F2 was collected.

### F2 -- there is no per-arm offset and no positional bias

- **Status:** closed. **Supersedes the arm reading in F1 and in F7 of
  `plans/wip/continue-elegant-boot.md`.**
- **Date:** 2026-07-27. **Commit:** `4061096`.
- **Reproduction:**
  `python3 scripts/terminal-benchmark-plan-calibration.py --revision HEAD
  --workload incremental-mixed --quartets 24 --trials 2000`, then reading
  `blocks.json` for the **draw** metric (the script's own report covers plan
  time only).
- **Why this design:** the script binds both physical slots to one source root
  (`arm_roots={"a": root, "b": root}`) and schedules every block on slot `a`,
  while still launching both apps. So window stacking and launch order are
  identical to production and **the arm term is exactly zero by construction.**
- **Artifacts:** `.build/terminal-benchmark-plan-calibration/c9562e10c053-0000/`.
- **Measurements:** 24 quartets / 96 blocks / 48 pairs, 0 discarded.
  - Position means: `p0=187065  p1=185935  p2=187720  p3=187285` ns.
  - Inner slots (1,2 -- always the candidate) vs outer (0,3): **mean -0.18%**,
    SD 4.97%, n=24.
  - Paired symmetric differences: median -0.50%, mean -1.36%, **SD 6.26%**,
    range -14.58%..+12.09%.
  - Simulated 2-pair `quick` estimates over +/-3.8%: **10 / 24**.
- **Observation:** a series with zero arm term and no measurable positional
  contrast still produces false verdicts at the observed rate.
- **Inference:** the phenomenon is neither the arm nor the schedule. It is the
  width of the underlying distribution.
- **Competing interpretations:** none surviving. Given a per-pair SD of 6.26%, a
  2-pair median has SE ~4.4%, so F1's four estimates averaging +3.89% sit ~1.8
  SE from zero and the arm split differs by ~1.4 SE. Neither is significant;
  F1's apparent structure is what 6% noise looks like through four samples.
- **Uncertainty:** none material for the claim made.
- **Next action:** unlocked F3 and F4.

### F3 -- `content-churn` is clean in the same session, on both days

- **Status:** closed. **This is the control that licenses every cross-day
  variance comparison in this file.**
- **Date:** 2026-07-27. **Commit:** `4061096`.
- **Reproduction:** same command as F2 with `--workload content-churn`.
- **Artifacts:** `.build/terminal-benchmark-plan-calibration/c9562e10c053-0001/`.
- **Measurements:** 24 quartets / 96 blocks / 48 pairs, 0 discarded. Per-draw
  mean 880508 ns; paired symmetric median +0.02%, mean -0.30%, **SD 1.37%**,
  range -3.75%..+2.19%; simulated 2-pair estimates over +/-4.5%: **0 / 24**.
- **Observation:** 1.37% today against 1.15% on 2026-07-24 -- essentially
  unchanged, and clean by the same gate `incremental-mixed` now fails.
- **Inference:** machine conditions on 2026-07-27 are comparable to 2026-07-24.
  Machine drift, thermal state, and agent-session load are excluded as
  explanations for the `incremental-mixed` inflation, because they would have to
  act on one workload and not the other measured minutes apart.
- **Competing interpretations:** a confound that scales with draw duration could
  in principle affect only the short workload. That is not "machine conditions";
  it is H5, and it is retained.
- **Uncertainty:** one control workload. `style-churn` was not collected and
  would strengthen this.

### F4 -- both variance axes moved, and only for `incremental-mixed`

- **Status:** closed.
- **Date:** 2026-07-27.
- **Reproduction:** per-draw duration distributions from
  `drawDurationsNanoseconds`, 96 blocks each, comparing the surviving
  2026-07-24 calibration series against the F2/F3 series at `HEAD`.
- **Measurements:**

  | workload | axis | 2026-07-24 | today at `HEAD` |
  | --- | --- | --- | --- |
  | `incremental-mixed` | within-block per-draw CV | 8.73% | **17.41%** |
  | | between-block mean spread | 1.26% | **4.18%** |
  | | per-draw mean | 178987 ns | 187002 ns |
  | `content-churn` | within-block per-draw CV | 5.83% | 5.06% |
  | | between-block mean spread | 0.96% | 1.09% |
  | | per-draw mean | 930313 ns | 880508 ns |

- **Observation:** for `incremental-mixed` the per-draw jitter roughly doubled
  **and** block means scatter roughly three times as widely. For `content-churn`
  neither moved, and its mean improved 5.4%.
- **Inference:** two distinct effects may be in play -- a per-draw one and a
  per-block one -- and the per-block one (`between-block SD`) is what drives
  paired verdicts. A fix must move `between-block SD`; moving only the per-draw
  CV would not restore the thresholds.
- **Competing interpretations:** a single underlying cause could produce both
  (e.g. heavier-tailed per-draw cost inflating block means). Not yet
  distinguished.
- **Uncertainty:** whether the per-draw distribution is bimodal or merely wider
  is **unmeasured**; it is a Phase 3 task and it discriminates H4/H5.

### F5 -- `4061096` and `8188b9a` are both exonerated

- **Status:** closed.
- **Date:** 2026-07-27.
- **Reproduction:** single-arm A/A series per revision, as F2. Pre-`4061096`
  revisions required raising the calibration retry allowance to 25 attempts via
  a scratchpad driver calling `run_calibration(maximum_attempts=...)`; no
  repository source was modified.
- **Artifacts:** `.build/terminal-benchmark-attribution/`,
  `.build/terminal-benchmark-plan-calibration/c9562e10c053-0000/`.
- **Measurements** (`CV` = within-block per-draw; `blockSD` = between-block):

  | revision | what it adds | q | mean ns | paired SD | CV | blockSD | false quick |
  | --- | --- | --- | --- | --- | --- | --- | --- |
  | 2026-07-24 ref | thresholds frozen here | 24 | 178987 | **1.49%** | 8.73% | **1.26%** | 0/24 |
  | `b834a44` 07-27 10:44 | before damage-scoped planning | 12 | 172253 | **4.75%** | 10.41% | **6.77%** | 4/12 |
  | `8e216bc` 07-27 12:16 | `8188b9a` damage-scoped planning | 12 | 187734 | 5.18% | **15.91%** | 6.57% | 5/12 |
  | `4061096` = `HEAD` | the observer fix | 24 | 187002 | 6.26% | **17.41%** | 4.18% | 10/24 |

- **Observation:** `b834a44` -- which predates both suspects -- already carries the
  verdict-driving inflation in full (blockSD 6.77% against the reference's
  1.26%).
- **Inference:** neither `4061096` (the row-limited scan, settling gate, and
  ungated block-boundary probes) nor `8188b9a` (damage-scoped planning) caused
  the regression. This directly settles the cost worry F7 in
  `continue-elegant-boot.md` was trying to measure: it is not visible here.
- **Competing interpretations:** none for the exoneration. Note separately that
  `8188b9a` *did* roughly double the within-block CV (10.41% -> 15.91%) and
  raise the per-draw mean +9.0% -- but these are **unpaired cross-invocation
  numbers**, not a paired comparison, so machine drift between invocations is
  uncontrolled. Recorded as a flag for Phase 6, **not** as a finding about that
  commit.
- **Uncertainty:** the two middle rows are 12 quartets, not 24, because of the
  F8 retry cost (3 quartets discarded of 15 in each). `blockSD` is also
  non-monotonic across the four rows (1.26, 6.77, 6.57, 4.18); with differing
  sample sizes this reads as "inflated from `b834a44` onward" rather than a
  trend. Neither caveat affects the exonerations.
- **Bias direction:** the 2026-07-24 reference is a **two-arm** series and the
  three new ones are **single-arm**. That biases against the finding rather than
  for it -- a two-arm series can only carry more variance, so 1.49% is if anything
  an overestimate of what a single-arm series would have shown then.

### F6 -- threshold provenance is sound; two handoff leads are dead

- **Status:** closed.
- **Date:** 2026-07-27.
- **Observations:**
  - The `incremental-mixed` **draw** rule was frozen from
    `.build/terminal-benchmark-phase4-incremental-shared-bundle-calibration/2026-07-24/blocks.jsonl`
    (`scripts/terminal-benchmark-median-fallback.py`,
    `WORKLOADS["incrementalMixed"]`). That directory carries separate
    `A-identity.json` and `B-identity.json` plus two harness logs -- **two real
    app processes on two physical slots** -- over 96 blocks / 48 pairs / 24
    quartets with a schedule alternating both `QUARTET_PATTERNS`.
  - The `"physicalArm": "a"` hardcode flagged in the handoff is in
    `scripts/terminal-benchmark-plan-calibration.py`, which builds the
    **plan-time** series only. **The draw thresholds do not share that
    provenance.**
  - `.build/f7-pilot-a.json` and `.build/f7-pilot-b.json` are harness identity
    files from an unrelated 2026-07-24 `full-screen-content-churn` profiling run
    (`profilingActive: true`). Irrelevant.
- **Inference:** the thresholds were correctly derived from a production-shaped
  series. They are not miscalibrated; they describe a distribution the
  instrument no longer produces.
- **Latent gap recorded, not acted on:** `simulate` in
  `scripts/terminal-benchmark-calibration.py` negates the paired differences on
  alternating trials (`"physicalArmMapping":
  "source-labels-swapped-on-alternating-trials"`), forcing the modelled A/A
  distribution symmetric. It therefore sizes a threshold against a bias's
  *magnitude* but is blind to its *direction*. That is valid only if production
  counterbalances the arm, which `physical_candidate_arm()` and `make_schedule()`
  do not. **This did not cause the observed failures** (F2 shows no directional
  bias to be blind to), but it should be revisited at Phase 6.

### F7 -- the calibration series is dated to a two-hour window, bounding the bisect

- **Status:** closed. **This finding cost no machine time and excluded a
  suspect.**
- **Date:** 2026-07-27.
- **Method:** date the surviving 2026-07-24 series by which fields its own block
  records carry, then map those to the commits that introduced them.
- **Measurements:**
  - The 2026-07-24 blocks carry `machineStateSamples` of length **2**
    (`reason: "start"` and its end counterpart) -- i.e. **not** per-draw
    sampling. `8a718dd perf(benchmark): drop the per-draw WindowServer
    visibility round-trip` (2026-07-24 18:30) had therefore **already landed**.
  - The 2026-07-24 block `result` keys are `clock, cumulativeDrawNanoseconds,
    dirtyRowCounts, drawCount, drawDurationsNanoseconds, drawSequences,
    elapsedNanoseconds, event, expectedFinalState, machineStateSamples,
    startMarker` -- with **no** `cumulativePlanNanoseconds`, `planCount`,
    `planDurationsNanoseconds`, or `planFrameCount`. `b7f5c12 feat(benchmark):
    report frame-planning time beside the draw verdict` (2026-07-24 20:19) had
    therefore **not** landed.
- **Inference:** the calibration series was collected between **18:30 and 20:19
  on 2026-07-24**. The regression window is therefore `b7f5c12` .. `b834a44`,
  candidates in order: `b7f5c12`, `df80150`, `760e848`, `847f5c8`, `8e9bc45`,
  `b834a44`.
- **Consequence:** `8a718dd` is **excluded** (R7). `9c2b1a5` (19:08) and
  `647aa5a` (19:44) fall *inside* the 18:30..20:19 window and cannot be resolved
  by this method -- they are excluded only if the series postdates them, which is
  unknown. H4 is retained on that basis.
- **Uncertainty:** the method dates the *harness build* that produced the series,
  which is the arm build, not the operator's checkout. That is the right thing
  to date for this purpose.

### F8 -- collection is obstructed at every pre-`4061096` revision

- **Status:** closed; a standing constraint on Phase 2.
- **Date:** 2026-07-27.
- **Observations:** `df80150` produced **zero** valid quartets in 4 attempts.
  `b834a44` and `8e216bc` each needed a 25-attempt allowance and discarded 3
  quartets of 15. The cause is the stale-marker defect root-caused and fixed by
  `4061096` itself (F3 in `plans/wip/continue-elegant-boot.md`): a completed
  `incremental-mixed` block leaves its start marker on row 65, and the next
  block can be opened by it.
- **Inference:** any bisect across `4061096` pays a retry tax on
  `incremental-mixed`, and `df80150` specifically may not be collectable at all
  at reasonable cost. Budget for it, and consider whether probing `df80150`
  requires cherry-picking `4061096`'s marker fix onto it -- which would change the
  binary under test and must be recorded as such if done.
- **Next action:** feeds the Phase 2 tasks.

### F9 -- the distribution is unimodal and widened in both directions; the floor dropped

- **Status:** closed. **Rejects H4; substantially favours H3 over H2.**
- **Date:** 2026-07-27. Cost no machine time -- both series were already on disk.
- **Method:** pooled all 4800 individual `drawDurationsNanoseconds` values from
  each 96-block series and compared their distributions.
- **Measurements:**

  | statistic | 2026-07-24 (clean) | `4061096` (degraded) | change |
  | --- | --- | --- | --- |
  | min | 107708 | 120833 | -- |
  | **p10** | **160666** | **146208** | **-9.0%** |
  | p25 | 168792 | 163250 | -3.3% |
  | **median** | **177708** | **182938** | **+2.9%** |
  | p75 | 188000 | 206417 | +9.8% |
  | **p90** | **198375** | **231791** | **+16.8%** |
  | max | 304625 | 372584 | -- |
  | p90-p10 spread | 37709 | 85583 | **+127%** |

- **Observation:** both histograms are **single-peaked**. The degraded series is
  not two modes; it is one much wider, right-skewed mode. Critically the spread
  grew in *both* directions: the 10th percentile fell 9% while the 90th rose
  17%, around a median that barely moved (+2.9%).
- **Inference:** a large population of draws is now **faster** than almost any
  draw was in the clean series. That is not what added per-frame work looks like
  -- added work raises the floor. It is what **removing a uniform per-frame cost**
  looks like: the removed work was acting as a regularizer, setting a floor and
  compressing the distribution around it. This is the mechanism in **H3** (and
  the general form in **H5**).
- **Consequences for the hypotheses:**
  - **H4 rejected.** There is no bimodality, so a data-dependent fast/slow path
    in text-run construction is not the shape of this. See R9.
  - **H2 weakened.** `b7f5c12` adds per-frame timing work; that should raise the
    floor, and the floor fell. Retained but demoted -- the bisect still tests it,
    and a timer could in principle *displace* other work.
  - **H3 strengthened.** `df80150` cut the observer's per-frame cost ~5x. Under
    this reading the observer optimization is *correct*, and what it exposed was
    always a property of the short-damage draw path.
  - **H5 strengthened** for the same reason, and it is the reading under which
    the fix is **not** a revert.
- **Competing interpretations:** a change that made draw cost more
  *input-dependent* rather than removing a fixed cost would also drop the floor
  and raise the tail. That is not distinguished here and matters for the fix:
  "restore a floor" and "remove the input-dependence" are different repairs.
- **Per-block view, closing the pooling caveat:** block medians are unimodal in
  both series too, so pooling did not smear a per-block separation.

  | statistic | 2026-07-24 | `4061096` |
  | --- | --- | --- |
  | block medians, range | 171730 .. 184667 | 166313 .. 206458 |
  | block medians, SD | 1.44% | **4.65%** |
  | block floor (in-block p10), median | 161396 | **148376** (-8.1%) |
  | block floor, range | 153500 .. 171708 (span 18208) | 135417 .. 168625 (span **33208**) |

  So the floor did not merely drop in the pooled view: **every block's floor
  dropped, and the floors themselves became roughly twice as variable.** A block
  no longer has a stable minimum draw cost, which is a direct account of why
  block means stopped repeating (F4's `between-block SD`).
- **Uncertainty:** this compares the two endpoints, not the bisect points.
- **Next action:** run this same percentile comparison at every Phase 2 probe.
  **Treat "where did the block floor move" as the primary bisect readout** -- it
  is a sharper and lower-variance signal than the paired SD, so it should
  localize the commit with fewer quartets per probe than an SD comparison needs.

## Decision log

_No decisions taken yet. **D1** (name the commit and mechanism class) is the
Phase 2 gate; **D2** (select the fix) is the Phase 4 gate._

## Rejected

### R1 -- the verdict tracks the physical arm

The original F7 reading in `plans/wip/continue-elegant-boot.md`. Rejected by
**F2**: a single-arm series, where the arm term is zero by construction, still
produces 10/24 false verdicts. Independently, the 2026-07-24 two-arm A/A series
measured an arm offset of only **-0.73%**, and across the 18 archived comparison
runs the sign of the estimate does not track the candidate arm (candArm=b mean
+1.49%, candArm=a mean +1.85%).

**Reopen if:** a directional arm offset appears in a series where the workload
variance is otherwise back to ~1.5%. Note F6's latent gap would hide it from the
calibration.

### R2 -- an ABBA positional bias inflates the candidate slots

An intermediate reading of F1 that decomposed the four runs into a +3.89%
positional and a +3.09% per-arm bias, reasoning that a single-quartet `quick`
schedule always puts the candidate in the two inner slots and that ABBA cancels
only *linear* drift. Rejected by **F2**: over 24 quartets the inner-vs-outer
contrast is **-0.18%** and the four slot means lie within 1% of each other.

The mechanism is sound in principle and the arithmetic was right; the input was
four samples from a 6% noise process. Kept as a caution about n.

### R3 -- machine drift, thermal state, or agent-session load

The rival hypothesis the original handoff flagged as most likely. Rejected by
**F3**: `content-churn` collected in the same sessions, minutes apart, is clean
on both days (1.15% -> 1.37%). A machine-level confound cannot act on one
workload and not the other. Additionally the false verdicts became *more*
reproducible once the machine was idle, not less.

**Reopen if:** a confound is identified that scales with draw duration -- but
that is H5, not "machine conditions".

### R4 -- the per-arm `.a`/`.b` bundle namespace

Ruled out by construction, not by argument: `PersistentDrawArms.start()` sets
`DANTERM_BENCHMARK_BUNDLE_SUFFIX: ""`, with the comment "the frozen calibration
removed the stable .a/.b namespace offset while retaining per-launch homes,
sockets, and paths." Already fixed before this investigation. Do not
re-litigate.

### R5 -- widen the threshold to cover the observed spread

Rejected a priori by the investigation rules, and quantitatively: holding a 5%
false-positive rate against today's 6.26% spread needs a threshold near 12-15%,
which would make `incremental-mixed` incapable of detecting anything it exists
to detect. It would also encode the degradation permanently.

### R6 -- counterbalance the physical arm across quartets, or rebalance the schedule

Proposed while R1/R2 were still live. Rejected because F2 shows neither the arm
nor the schedule is implicated, so this would change the distribution the
thresholds were calibrated against **for no benefit** -- forcing a recalibration
to fix a non-problem.

Note the separate, still-valid observation in F6 that production does not
counterbalance the arm while the calibration's simulation assumes it does. That
is a modelling gap to revisit at Phase 6, not a fix for this defect.

### R7 -- `8a718dd`, dropping the per-draw WindowServer visibility round-trip

Excluded by **F7**: the 2026-07-24 calibration series carries only 2
`machineStateSamples`, so it was collected *after* that commit landed. The
mechanism was attractive -- removing a per-draw round-trip removes a per-draw
regularizer -- and it survives in spirit as **H3**, attached to `df80150`.

### R8 -- the `physicalArm: "a"` hardcode in the plan calibration

The handoff's "strong lead". Rejected by **F6**: it belongs to the plan-time
series only; the draw thresholds come from a real two-arm series.

### R9 -- a planner change made short-damage draw cost bimodal (H4)

Proposed because the within-block per-draw CV doubled (8.73% -> 17.41%), which
is a per-draw effect and suggested two modes -- plausibly a data-dependent
fast/slow path introduced by `9c2b1a5` / `647aa5a` in text-run construction.

Rejected by **F9**: pooling all 4800 per-draw values at each endpoint shows both
distributions are **single-peaked**. The degraded one is one wider, right-skewed
mode, not two. The elevated CV is spread, not separation.

**Reopen if:** a per-block (rather than pooled) view shows blocks separating
into fast and slow populations -- pooling across 96 blocks could in principle
smear a per-block bimodality into one wide mode.

## Open questions and caveats

- **The exact commit is unknown.** The window is `b7f5c12`..`b834a44`, with
  `9c2b1a5`/`647aa5a` unresolved inside the 2026-07-24 dating window.
- **Whether the per-draw distribution is bimodal is unmeasured**, and it is the
  cheapest remaining discriminator (Phase 3, data already on disk).
- **`between-block SD` is the quantity that matters**, not `within-block CV`. A
  fix that improves only the latter would not restore the thresholds.
- **`df80150` may not be collectable** at acceptable cost (F8). If probing it
  requires cherry-picking the marker fix, the binary under test is no longer
  that commit and the result must say so.
- **`style-churn` was never collected** as a second control. F3 rests on one
  control workload.
- **An agent session was attached** to the machine for every measurement in this
  file. F3 bounds its effect but does not eliminate it.
- **No claim in this file is a performance claim about any commit.** All series
  are unpaired single-arm A/A variance measurements.
- **`4061096`'s owed timing measurement** (F7 in
  `plans/wip/continue-elegant-boot.md`) remains owed and is blocked on Phase 5.

## Outcome

Investigation in progress.

- **Phase 1 complete.** The defect is real, reproduces on an idle machine, and
  is a ~4x widening of the `incremental-mixed` draw distribution -- not an arm
  offset (R1), not a schedule bias (R2), not machine conditions (R3).
- **Phase 2 partially complete.** Window bounded to `b7f5c12`..`b834a44` (F7),
  with `4061096`, `8188b9a`, `8a718dd` and the two handoff leads all excluded.
  The exact commit is not yet named.
- **Phase 3 partially complete, ahead of schedule.** F9 characterized the shape
  without spending machine time: the distribution is unimodal and the **block
  floor dropped ~8%** while the tail grew, i.e. a uniform per-frame cost that
  used to regularize every draw is gone. This favours H3/H5 -- under which the
  observer optimization was *correct* and merely exposed a real property of the
  short-damage draw path, so the fix is unlikely to be a revert.

Next action is the `b7f5c12` bisect probe with its `content-churn` control,
reading the **block floor** as the primary signal (F9) rather than the paired SD.
