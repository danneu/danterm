# Benchmark variance regression on `incremental-mixed`

Research started: 2026-07-27.

> ## Handoff -- read this first
>
> **The cause is found and all four fixes are refuted. The recommended next step
> is recalibration at higher pair counts, which needs no new mechanism.**
>
> ### What is wrong, in one paragraph
>
> `incremental-mixed` draws do not vary randomly. They get 26-41% slower from a
> block's first draw to its last, in ~95 of 96 blocks, because **macOS lowers the
> app's CPU clock during the block**. The recent optimizations left the main
> thread ~96% idle and the governor demotes a thread that idle. The render path
> is **not** regressed -- it is measurably faster. This is **D1**, confirmed by
> **F14**: the slowdown is a quantized staircase whose steps land at the same
> wall-clock moments in two disjoint timers (draw and plan), ~80 ms apart. Only a
> frequency governor does that.
>
> ### The trap that cost this investigation the most
>
> **The ramp is a symptom, not the driver.** It cancels in pairing, so removing
> it does not help -- proven twice, by re-analysis (**F15**) and by building the
> fix and measuring it (**F17**, where flattening the ramp *tripled* the variance).
> The quantity that actually breaks verdicts is block-to-block **level** variation
> (**F16**). Justify any new idea against level CV, never against the ramp.
>
> ### Do not re-propose these -- all refuted with evidence
>
> | idea | killed by |
> | --- | --- |
> | widen the threshold | R5 |
> | it is the physical arm / ABBA position | R1, R2 (F2) |
> | machine drift or thermal state | R3 (F3), and F16 shows no session drift |
> | a single commit caused it | **F12** -- it grows monotonically across four revisions |
> | restore the removed per-frame cost | R10 (**F10** -- the floor also dropped in the clean control) |
> | bimodal draw cost | R9 (**F9**) |
> | ramp-robust statistic / truncate the block | **F15** -- 11 estimators, none near target; truncation wrecks the clean control |
> | shorten the block below the first step | **F16** -- blocks do not start at the same rung either |
> | pin frequency or core affinity | **F14** -- it is frequency, and macOS exposes no userspace floor |
> | **pacer holding occupancy constant** | **F17** -- built, measured twice, made it worse |
>
> ### Next action: recalibration helps `quick` only -- `confirm` is not cheaply recoverable (F20)
>
> **The earlier "48 pairs recovers 1.75%" recommendation is WITHDRAWN by F20.**
> It was screened against only the A/A false-positive rate at a 5% injected
> effect. `confirm`'s real gate is a **3% effect with detection >= 0.90**, and
> under it 48 pairs is not eligible at all: the tightest threshold clearing A/A
> FP is 2.05%, where detection is 0.71 and 29% of trials are inconclusive.
>
> Re-derived with the repo's own calibration machinery under each mode's real
> gates -- and validated by reproducing the frozen 2-pair `quick` / 6-pair
> `confirm` counts on the clean 2026-07-24 reference:
>
> | mode | frozen | actual cost to beat it |
> | --- | --- | --- |
> | `quick` (5% effect, detect >= 0.80) | 2 pairs @ 3.8% | **12 pairs @ 3.25%**, ~1.1 min |
> | `confirm` (3% effect, detect >= 0.90) | 6 pairs @ 1.85% | **100 pairs @ 1.65%**, detect 0.93, ~9 min |
>
> So: recalibration is cheap and works for `quick`. For `confirm` it costs ~17x
> the wall-clock and lands *marginally* over the detection floor (0.93 vs 0.90)
> on a single session's data, where F18 puts session variation at ~2x. **Treat
> "recalibration restores `confirm`" as unproven.** `confirm` is the mode that
> actually decides damage-scoping changes, so this materially strengthens the
> case for the headless in-process benchmark below.
>
> Recalibration still clears the "no hacks" rule and is not R5 -- it buys
> precision with time rather than widening a threshold. Use
> `scripts/terminal-benchmark-median-fallback.py`. A human moves the frozen rule.
>
> ### The strategic route, now measured rather than assumed (F21)
>
> Move damage-scoping regression detection to the **headless in-process draw
> benchmark**. It **already exists**: `TerminalDrawBenchmark` in
> `lib/TerminalCore`, run by `just benchmark-draw`, already has a
> `damage-clipped` scenario and already batches to 400 ms so the thread stays
> ~100% occupied and the governor never demotes.
>
> F21 measured it over six runs. Within-run CV is **0.58-0.85%**. Raw between-run
> CV is **2.8-3.6%** -- no better than the GUI benchmark, because arms are
> separate processes. But the drift is **common-mode** across all cells, so an
> in-run **ratio** cancels it: 160x50 damage-clipped/full-frame has **CV 0.256%**
> across six runs, and the clipped/full separation is 11.5x.
>
> **The design constraint is hard: compare ratio-wise within one process, or
> interleave both arms' batches in one process.** Raw cross-run comparison
> inherits the drift and buys nothing. Use 160x50, not 80x24 (4-5x more stable).
>
> It does **not** cover damage *generation* -- which rows `setNeedsDisplay` and
> AppKit's coalescing mark dirty -- so the GUI benchmark stays for end-to-end
> validation. The untested step is two separately compiled arms interleaved in
> one process; that is the next pilot.
>
> ### Standing rules for anyone collecting data here
>
> - **Same-session control, every time.** F17's 12-block pilot looked like a
>   success purely because it was compared across sessions. Session-to-session
>   variation in these statistics is ~2x (F18), so cross-session *magnitudes* are
>   unreliable; within-block *shapes* (F11-F14) are robust.
> - **Verify no benchmark apps survive** before, between and after every series:
>   `pgrep -f "MacOS/DanTerm Benchmark"`. Match the binary path -- the bare name
>   also matches the shell doing the checking and reports a phantom orphan.
> - **A finished run looks hung for ~2 minutes.** The wrapper does not exit on
>   SIGINT, so `close()` waits its full 30 s per arm. Known, unfixed, F19.
> - The primary readout is the **within-block ramp** (F11) for diagnosing and
>   **block-level CV** (F16) for judging a fix. F9's block-floor readout is
>   withdrawn (R10).
>
> ### State of the tree
>
> - `cc3918d fix(benchmark): stop a killed harness wrapper from orphaning its app`
>   -- the F19 fix, committed with tests.
> - The F17 pacer was **reverted**; it is refuted and deliberately not in the tree.
> - Clean 2026-07-27 series **copied out of the disposable `.build/` tree** to
>   `~/danterm-benchmark-evidence/2026-07-27/` -- the two rerun series plus all
>   three 2026-07-24 reference workloads. That copy is the durable one; the
>   `.build/rerun-{paced,unpaced}/` originals survive only until `just clean`.
>
> ### Related files
>
> `plans/wip/continue-elegant-boot.md` (F7 -- the original observation) and
> `plans/wip/f7-arm-confound-diagnosis.md` (interim diagnosis, rejected here as
> R1/R2). Both untracked and both superseded by this file for the variance
> question.

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
- **Nothing in `scripts/` is modified to collect evidence.** Diagnostic tooling
  stays out of the shipped scripts until a direction gate selects it.
- **Do not hide working context in a private session scratchpad.** A scratchpad
  dies with the session, so anything left there is lost at exactly the moment a
  handoff needs it -- and a number whose driver did not survive cannot be
  checked, only re-derived or trusted. This is not hypothetical: F20 overturned a
  headline recommendation precisely because the driver behind it was gone. Put
  in-flight drivers, one-off queries and raw readouts in [Scratch](#scratch) at
  the bottom of this file. When something earns permanence, promote it to
  [Reproduction recipes](#reproduction-recipes) or a finding and delete the
  scratch copy.
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

| series | paired SD | within-block per-draw CV | between-block SD | **within-block ramp** | false quick verdicts |
| --- | --- | --- | --- | --- | --- |
| `incremental-mixed` 2026-07-24 (thresholds frozen here) | **1.49%** | 8.73% | **1.26%** | **-0.2%** (3/96 blocks) | **0 / 24** |
| `incremental-mixed` today at `HEAD` | **6.26%** | **17.41%** | **4.18%** | **+41.1%** (95/96 blocks) | **10 / 24** |
| `content-churn` 2026-07-24 | 1.15% | 5.83% | 0.96% | +0.7% (0/96) | 0 / 24 |
| `content-churn` today at `HEAD` | 1.37% | 5.06% | 1.09% | -0.9% (1/96) | 0 / 24 |

The ramp column was added last and it is the one that matters (F11). The first
three columns are all *consequences* of it: a metric that drifts 41% within a
block reads as a wide distribution when its draws are pooled.

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

### H6 -- the app's main thread is progressively demoted within a block because the optimizations left it too idle -- CONFIRMED (D1)

**Confirmed by F14** and adopted as the mechanism at **D1**. F14 found the ramp
is a quantized staircase whose steps land at the *same wall-clock moments* in
both the draw and the plan timer, ~80 ms apart -- a governor's decision period
and P-state ladder. The intervention experiment described at the end of this
section is no longer needed to *establish* the mechanism; it now serves to
validate whichever fix D2 selects. F14 also refines the mechanism to **frequency
reduction** (total excursion 1.446x) rather than efficiency-core migration.


**Mechanism:** `incremental-mixed` draws 6 rows. After `df80150` (observer cost)
and `8188b9a` (damage-scoped planning), the app's main thread does ~3.8% of
wall-clock work during a block (F13) -- it is idle ~96% of the time, in ~8.7 ms
gaps between 50 short bursts. macOS responds to a thread with that duty cycle by
lowering its frequency and/or migrating it to an efficiency core. The demotion
deepens over the ~440 ms block, so every timed region gets progressively slower,
and it resets between blocks because the inter-block work (marker writes,
settling, relaunch) re-boosts the thread.

**Supporting evidence, all of it already collected:**

- **F13 is the near-decisive one:** the draw timer and the plan timer ramp
  *in lockstep* (41.1% vs 41.2% at `HEAD`). They bracket disjoint work in
  unrelated code -- `draw(_:)` under CoreGraphics versus `planIfNeeded` on the
  PTY-output path. No algorithmic change can slow both by the same amount. A
  slower *processor* can, and that is the only class of cause that can.
- **F13's correlation:** across four revisions the ramp is monotonically inverse
  to main-thread duty cycle (17.8% duty / 10.8% ramp -> 3.7% / 25.2% ->
  3.8% / 41.1%). Each optimization removed work, lowered the duty cycle, and
  deepened the ramp.
- **F11:** `content-churn` and `style-churn` never ramp at any revision. They
  hold the main thread at 21-22% duty -- enough to stay boosted.
- **F12:** the ramp grew progressively across the recent history rather than
  flipping at one commit, which is what a *dose-response* to accumulated work
  reduction looks like and is not what a single defect looks like.
- **F11:** the ramp is uniform across all four quartet slots and resets every
  block, so it is block-local, not process-lifetime accumulation.

**What it would mean:** the render path is not regressed -- it is genuinely
faster (first-draw cost fell from 181 us to 139 us, F11). The *instrument* is
measuring the CPU scheduler. The fix belongs in the harness: hold the measured
thread in a stable power state for the duration of a block, so the metric
reports the code rather than the frequency. This satisfies the "no hacks" rule
-- it removes a confound rather than hiding it -- and it is not a revert.

**Distinguishing experiment (the next action):** re-collect an
`incremental-mixed` series at `HEAD` with the app's duty cycle artificially
restored, and see whether the ramp disappears. Two independent ways to do it,
and they should agree:

1. Raise the duty cycle: have the benchmark harness burn main-thread time
   between draws (a spin, not a sleep) to restore ~20% occupancy. Predicts the
   ramp collapses toward 0% and paired SD returns to ~1.5%.
2. Remove the scheduler's freedom instead: pin the arm processes to
   performance cores / a fixed QoS for the block. Predicts the same.

**Confirms if:** either intervention flattens the ramp without touching render
or planner code. **Refuted if:** the ramp survives at restored duty cycle -- in
which case the lockstep of F13 needs another explanation and H5 revives.

**Relation to the others:** H6 is the specific mechanism H5 was groping at, and
it subsumes H3 -- `df80150` really was one of the commits that lowered the duty
cycle, but it is one contributor among several, not *the* commit. H1's premise
(a single commit) is refuted by F12.

### H1 -- an instrument change between 2026-07-24 and `b834a44` inflated the variance -- REFUTED AS STATED

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

**Status:** the *class* is still right -- an instrument change did this -- but
**"a commit" is wrong.** F12 measures the ramp at four revisions and finds it
grows monotonically (`b834a44` 10.8% -> `8188b9a` 25.2% -> `8e216bc` 37.0% ->
`4061096` 41.1%) from 0% in the clean series. There is no single commit to name;
several successive commits each made it worse. The bisect-to-one-commit framing
that drove Phase 2 is retired, and H2/H3/H4 with it as separate candidates.

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

**Status: superseded.** F12 shows no single-commit boundary exists, and F13
shows added per-frame timing work is the wrong sign anyway. Subsumed by H6,
under which `b7f5c12`'s timer is a bystander. Not separately tested.

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

**Status: absorbed into H6.** The intuition was right in kind and wrong in
mechanism. `df80150` did remove a large uniform per-frame cost, but F10 shows
removing it did not widen anything by itself, and F12 shows it is one of several
commits that deepened the ramp rather than the one that started it. Under H6 its
real effect was to lower the main thread's duty cycle, which is the quantity
that matters. The conclusion H3 drew still holds: **the observer optimization is
correct and the fix is not a revert.**

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

**Status: sharpened into H6, and its central claim now looks wrong.** H5 said the
variability is a real property of *drawing 6 damaged rows*. F13 refutes that
specific form -- the planner, which is not drawing anything, ramps identically --
so it is not a property of the draw path. What survives, and is now H6, is H5's
structural claim: no commit caused this, the optimizations merely moved the app
into a regime where the platform behaves differently. H5 remains the fallback if
the H6 probe fails.

**Open sub-question, from F9, now answered:** neither "a fixed cost was removed"
nor "draw cost became input-dependent". F11 shows the cost is *ordinal-dependent*
within a block at constant damage -- a third shape neither option covered.

## Candidate directions for D2

**D1 is taken; D2 is not, and all four candidates are now refuted.** F15/F16
narrowed four to one against data already on disk; F17 then built the survivor
and measured it, and it made the metric worse. **There is no live candidate.**

**The finding that reframes the search:** two independent routes now say the same
thing -- F15 (the ramp cancels in pairing, so no estimator that targets it helps)
and F17 (removing the ramp in collection actively hurts). **The ramp is a
symptom, not the driver.** D1's mechanism stands -- the governor demotion is real
and F14 proves it -- but the demotion's *visible* effect, the within-block ramp,
is not what breaks the verdicts. What breaks them is block-to-block **level**
variation (F16), and no intervention tried so far moves it.

Any new candidate must therefore be justified against level CV directly, and
**must be measured with a same-session unpaced control** (F18): without one, F17
would have been reported as a success.

**The requirement, stated precisely.** Not "flatten the ramp" -- F15 shows the
ramp largely cancels in pairing already. The quantity that must move is
**block-level CV, from 3.83% to ~0.5%** (F16). And the stricter form: **the
clock a block is measured at must not depend on the code under test**, or a
change that makes drawing faster leaves the app more idle, invites more
demotion, and partially masks its own improvement. A fix that stabilizes the
clock without breaking that dependency leaves a systematic bias against
improvements in place.

**Candidate A -- hold occupancy constant with a pacer. REFUTED by F17 (built and measured).**
Implemented and collected 24 quartets paced against 24 unpaced in one session.
It flattened the ramp exactly as designed (+33.0% -> +6.7%, 95/96 -> 40/96
blocks) and **tripled block-level CV anyway** (2.07% -> 5.75%, paired SD
3.97% -> 5.12%). Leading explanation: two arm apps spinning ~21% of a core each,
plus the producer, contend in a way that varies block to block -- a new source of
level variance traded for the ramp. A larger budget would worsen that, so budget
tuning is not the obvious next move. Original rationale retained below.

After each draw completes, busy-wait (not sleep) until a fixed wall-clock
deadline, so the main thread's occupancy per frame period is **constant
regardless of how long the draw took**.
*For:* it is the only candidate that satisfies the stricter requirement -- a
faster draw simply spins longer, so the governor sees identical load whatever
the arm's code does, which closes the feedback loop. The occupancy target is not
arbitrary: `content-churn` demonstrates on the same machine, in the same
session, through the same harness, that ~21% occupancy yields 0.86% level CV and
1.37% paired SD (F16). Both arms run the identical pacer, so the comparison
stays valid.
*Against and must be verified:* the spin burns the resource under measurement,
so it must be shown not to perturb the draw itself (cache and allocator state);
the absolute per-draw number will shift, which is fine for a relative metric but
breaks continuity with historical absolute figures; and the deadline must exceed
the slowest expected draw or the pacer silently stops pacing.
*Note the realism objection is weaker than it looks:* `incremental-mixed` is
already a scripted synthetic workload with embedded markers, not a recording of
real use. The question is whether the *comparison* is valid, and under a
symmetric pacer it is.

**Candidate B -- shorten the block below the first step. REFUTED by F16.**
The premise was that the first plateau is a clean, flat region. It is not:
subtracting the 7-draw sampling floor from the early-plateau CV leaves ~3.8% of
true level variation, essentially all of the 3.83% total. **Blocks do not start
at the same rung.** Shortening cannot reach 1.49% at any block length. F15
confirms it empirically -- the 7-draw estimator is the *worst* of the eleven
tested (paired SD 8.73%, 16/24 false).

**Candidate C -- pin frequency or core residency. REFUTED.**
F14's 1.446x excursion is a frequency change, not core migration, so affinity is
the wrong lever; and macOS exposes no supported per-process frequency floor.

**Candidate D -- make the statistic ramp-robust. REFUTED by F15.**
Ordinal matching moves paired SD only 6.26% -> 5.68%, because the ramp is common
to both blocks in a pair and the symmetric difference already cancels it.
Truncation reaches ~4.0% at best and **wrecks the clean control** (`content-churn`
1.37% -> 3.33%, 0/8 -> 5/8 false confirms). No estimator tested comes near
1.49%. The fix cannot live in the statistic.

**Then, and only then:** recalibrate `incremental-mixed` from a fresh two-arm
series and re-freeze `DECISION_RULES` (Phase 6).

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
- [x] ~~Collect a single-arm A/A series at `b7f5c12`~~ -- **retired by F12.** The
      ramp is progressive across revisions, so there is no boundary to bisect to.
- [x] ~~Collect a paired `content-churn` series at each bisect point~~ -- the
      control was instead obtained from series already on disk (F10, F12), which
      is what showed the bisect framing was wrong.
- [x] ~~Build a draw-only A/A collector driver~~ -- **no longer needed.** It
      existed only to probe pre-`b7f5c12` revisions for the bisect.
- [x] ~~Continue the bisect to a single commit~~ -- **retired by F12.** Ramp:
      0% (clean) -> 10.8% (`b834a44`) -> 25.2% (`8188b9a`) -> 37.0% (`8e216bc`)
      -> 41.1% (`HEAD`). Monotonic, no boundary.
- [x] ~~Run the H6 duty-cycle probe~~ -- **not needed to establish the
      mechanism.** F14 confirmed H6 from data already on disk: the ramp is a
      quantized staircase and both timers step at the same wall-clock moments.
      The intervention moves to Phase 5, where it validates the chosen fix.
- [x] **Decision gate D1 -- TAKEN.** Mechanism class: platform CPU frequency
      demotion of an under-occupied main thread. See the [Decision log](#decision-log).

### Phase 3 -- characterize the mechanism

- [x] **Test whether the per-draw distribution is bimodal** rather than merely
      wider, pooled and per-block. Result in **F9**: unimodal both ways, the
      spread grew in both directions, and the block floor dropped ~8%.
      H4 rejected (**R9**); H3/H5 strengthened; H2 demoted.
- [x] ~~Determine what set the old floor~~ -- **dissolved by F10.** The floor
      dropped in the clean `content-churn` control too, so it is a benign
      general speedup, not the defect. Nothing needs to be restored.
- [x] ~~Distinguish "a fixed cost was removed" from "draw cost became
      input-dependent"~~ -- **neither.** F11: the cost is *ordinal-dependent*
      within a block at constant 6-row damage, which is a third shape the
      question did not offer.
- [x] **Determine whether the variance is work inside `draw(_:)` or scheduling
      around it.** Answered by **F13**: the plan timer, on a disjoint code path,
      ramps by the same 41%. It is not work inside `draw(_:)`. This was correctly
      identified here as the question that changes what the fix can target, and
      it did.
- [x] ~~Profile the short-damage draw path~~ -- **not applicable under D1.** A
      sample profile would show the same stacks running at a lower clock. It
      cannot see a frequency change, so it would mislead rather than inform.
- [x] **Explain the residual between-block SD.** Answered by **F16**: it is
      block-*level* variation (true CV 0.38% clean -> 3.83% degraded), it grows
      through the block (early 5.93% -> late 11.76%), and early and late levels
      are uncorrelated. This -- not the ramp -- is the quantity a fix must move.

### Phase 4 -- direction gate

- [x] **All four D2 candidates refuted** (F15, F16, F17). The pacer was built,
      measured twice, and made the metric worse; it has been reverted.
- [ ] **D2 remains unmade.** No mechanism-level fix is known. The recommended
      path forward does not require one -- see Phase 6.

- [ ] **Decision D2:** select the fix from the candidates in
      [Candidate directions for D2](#candidate-directions-for-d2), with
      correctness risks recorded. **This is the next action.** Report findings
      and pause for review before implementing, per
      `agent-docs/terminal-performance.md`. F15/F16 refute candidates B, C and D;
      only the pacer form of A survives, and its open risks are listed there.

### Phase 5 -- implement and verify

- [ ] Implement only the selected direction, TDD, with structure-insensitive
      behavioral tests.
- [ ] Re-collect the single-arm A/A series and confirm **block-level CV falls to
      ~0.5%** (F16, the primary acceptance criterion), the per-block ramp returns
      to within +/-5% (F11), paired SD returns to ~1.5%, and the `content-churn`
      control stays clean -- the last confirming the pacer adds no drift of its
      own.
- [ ] **Verify the pacer does not perturb the draw.** Compare per-draw cost at
      matched occupancy with and without the spin; a shift means the pacer is
      polluting cache or allocator state and is measuring something else.
- [ ] **Check the residual between-block SD separately.** De-ramping alone only
      moved it 4.65% -> 4.25% (F11), so a flat ramp is necessary but may not be
      sufficient to restore the thresholds. If it survives, that is new work, not
      a reason to widen a threshold.

### Phase 6 -- recalibrate and close

- [x] **Re-derive the pair-count table under the real per-mode gates** (F20).
      Done as re-analysis, no machine time. The earlier 48-pair recommendation is
      withdrawn: it used an FP-only gate at a 5% effect. Under the real gates
      `quick` needs **12 pairs @ 3.25%** (~1.1 min) and `confirm` needs
      **100 pairs @ 1.65%** at detection 0.93 (~9 min).
- [ ] **Decide whether `confirm` is worth recalibrating at all.** At ~17x the
      wall-clock for a marginal pass (0.93 against a 0.90 floor, single session,
      ~2x session variation per F18), the honest options are: accept a slow
      `confirm`, accept that `confirm` cannot decide `incremental-mixed` until
      the instrument is repaired, or build the headless benchmark (Phase 7).
      **This is a judgement call for a human, and it is the real next decision.**
- [ ] Confirm the F20 numbers on a fresh **two-arm** series before any freeze --
      session variation is ~2x (F18), and `confirm`'s 100-pair result is close
      enough to its gate that a fresh series could move it either way.
- [ ] Collect a fresh **two-arm** `incremental-mixed` A/A series matching the
      production shape (96 blocks / 48 pairs / 24 quartets).
- [ ] Re-screen and re-freeze `DECISION_RULES` via
      `scripts/terminal-benchmark-median-fallback.py`. A human moves the frozen
      rule after reading the report.
- [ ] Settle the F7 measurement still owed on `4061096` in
      `plans/wip/continue-elegant-boot.md`, which is blocked on this file.
- [ ] Graduate the settled decision to `docs/design/` and record here where it
      went.

### Phase 7 -- deferred harness work, not blocking

- [ ] **Fix the wrapper's SIGINT handling** (F19). `terminal-benchmark.sh` traps
      `INT`/`TERM` and its persistent-mode tail polls on `sleep 0.25`, where bash
      should run the trap within ~250 ms; something defers or swallows it, so
      `close()` waits the full 30 s per arm and then SIGKILLs. Costs ~2 min of
      apparent hang per run and is the reason apps were orphaned at all. The
      orphan *consequence* is fixed and committed; this cause is not.
- [x] **Scope the headless in-process draw benchmark** (F21). Done, no machine
      idle time. It already exists as `TerminalDrawBenchmark` with a
      `damage-clipped` scenario, already runs at ~100% occupancy, and resolves
      **0.256%** ratio-wise at 160x50 -- far below the 3% `confirm` needs.
- [ ] **Pilot two separately compiled arms interleaved in one process.** This is
      the one untested assumption in F21: the drift cancels because all cells are
      measured microseconds apart in one process, and it is unproven that two
      independently built arms stay common-mode. Build both arms' draw paths into
      one binary (or dlopen both), alternate batches, and report the ratio.
      **Do not build a cross-process headless comparison** -- F21 shows it
      inherits the 2.8-3.6% between-run drift and gains nothing over the GUI
      benchmark.
- [ ] **Decide what the headless benchmark is allowed to decide.** It cannot see
      damage *generation* regressions (`setNeedsDisplay` / AppKit dirty-rect
      coalescing) or `clipFramePlan`'s own cost. Write the split down before it
      is used to gate a change, so the GUI benchmark's remaining job is explicit.

## Reproduction recipes

Everything below is operational detail a continuing agent needs. It is here
rather than in a session scratchpad because scratchpads do not survive a
handoff.

### Where the evidence lives, and how fragile it is

| what | path | status |
| --- | --- | --- |
| **durable copy of everything below** | `~/danterm-benchmark-evidence/2026-07-27/` | **survives `just clean`**; made 2026-07-27. Prefer this path |
| 2026-07-24 reference series (the pre-regression anchor) | `.build/terminal-benchmark-phase4-{incremental,content,style}-shared-bundle-calibration/2026-07-24/blocks.jsonl` | `.build/` is disposable; copied to the durable path above |
| single-arm series collected 2026-07-27 | `.build/terminal-benchmark-plan-calibration/c9562e10c053-{0000,0001}/blocks.json` | disposable |
| bisect probes | `.build/terminal-benchmark-attribution/<tree>-NNNN/blocks.json` | disposable |
| the five A/A comparison runs of F1 | `.build/terminal-benchmark-comparisons/quick/` | disposable |

**These artifacts are still only in `.build/` and a session scratchpad, and a
session scratchpad does not survive a handoff.** F10, F11, F12 and F13 were all
derived from data already on disk without spending machine time, which is the
strongest argument for keeping it: the raw series has now paid for itself three
times over, answering questions nobody had thought to ask of it. **Before
running `just clean`, copy `.build/terminal-benchmark-phase4-*-shared-bundle-calibration/2026-07-24/`,
`.build/terminal-benchmark-plan-calibration/` and
`.build/terminal-benchmark-attribution/` somewhere durable.** Every statistic
cited here is tabulated in F4, F5, F9, F10, F11, F12 and F13, so losing the raw
data degrades the investigation but does not end it.

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

**Primary readout is the within-block ramp**, per F11. It separates clean from
degraded at 3/96 blocks against 95/96, so a handful of quartets is enough to
read it -- far fewer than an SD comparison needs. Run it on
`planDurationsNanoseconds` as well as `drawDurationsNanoseconds`: F13 makes the
lockstep of the two the mechanism signal.

The block-floor readout F9 prescribed is **withdrawn** (R10); the floor moves for
a benign reason (F10).

```python
import json, statistics as st

def slope(y):
    """Total % rise across a block, least-squares, normalized to its own mean."""
    n = len(y); xm = (n - 1) / 2; ym = st.mean(y)
    num = sum((i - xm) * (v - ym) for i, v in enumerate(y))
    den = sum((i - xm) ** 2 for i in range(n))
    return 100 * (num / den) * n / ym

def ramp(path, workload="incremental-mixed"):
    blocks = [b["artifact"]["finalDraw"]
              for q in json.load(open(path))[workload] for b in q]
    out = {}
    for metric in ("drawDurationsNanoseconds", "planDurationsNanoseconds"):
        ys = [b[metric] for b in blocks if b.get(metric)]
        if not ys:
            continue
        sl = [slope(y) for y in ys]
        out[metric[:4]] = {
            "rampMedianPct": round(st.median(sl), 1),
            "blocksRamping": f"{sum(x > 10 for x in sl)}/{len(sl)}",
        }
    duty = [100 * (b["cumulativeDrawNanoseconds"] + b.get("cumulativePlanNanoseconds", 0))
            / b["elapsedNanoseconds"] for b in blocks]
    out["dutyCyclePct"] = round(st.median(duty), 2)
    return out
```

Reference values (F11, F12, F13). A probe is **clean** if the draw ramp is within
+/-5% and fewer than ~10% of blocks rise above 10%:

| series | draw ramp | blocks ramping | duty | paired SD |
| --- | --- | --- | --- | --- |
| clean 2026-07-24 | -0.2% | 3/96 | -- | 1.49% |
| `HEAD` degraded | +41.1% | 95/96 | 3.8% | 6.26% |
| `content-churn` `HEAD` (control) | -0.9% | 1/96 | 21.4% | 1.37% |

For the older paired-SD and floor statistics, the F9-era snippet is preserved in
this file's git history; F4, F9 and F10 already tabulate everything it computed.

### Screening pair counts against the real gates (F20's readout)

Use this before recommending any pair count. The trap F20 fell into is screening
on the A/A false-positive rate alone: that sets only the *floor* on a threshold.
Each mode's injected-effect detection gate sets the *ceiling*, and for `confirm`
it is the binding one.

The gates are not the same for the two modes -- take them from `MODES` in
`scripts/terminal-benchmark-median-fallback.py`, do not assume:

| mode | effect | detect >= | inconclusive <= | wrong direction <= |
| --- | --- | --- | --- | --- |
| `quick` | **5%** | 0.80 | 0.20 | 0.05 |
| `confirm` | **3%** | 0.90 | 0.10 | 0.05 |

A single-arm `blocks.json` loads into the same quartet form
`calibration.load_quartets()` builds from a production JSONL series -- the
schedule is ABBA per quartet either way, so pair on `measurementRole`:

```python
def load_single_arm_quartets(path, workload):
    """Mirror load_quartets() over the single-arm blocks.json shape."""
    quartets = []
    for group in json.load(open(path))[workload]:
        assert sorted(b["measurementRole"] for b in group) == ["A", "A", "B", "B"]
        differences = []
        for first, second in zip(group[::2], group[1::2]):
            values = {}
            for row in (first, second):
                draw = row["artifact"]["finalDraw"]
                values[row["measurementRole"]] = (
                    draw["cumulativeDrawNanoseconds"] / draw["drawCount"])
            differences.append(CAL.symmetric_difference(values["A"], values["B"]))
        quartets.append(differences)
    return quartets
```

Then run `CAL.calibrate_threshold_grid(quartets, pair_count=N, effect_percent=...,
directional_thresholds=..., equivalence_band=..., trial_count=4000, seed=...,
estimator="median")` at each count in `PAIR_COUNTS`, keep the reports passing
*all four* gates, and take the **lowest** eligible `directionalThresholdPercent`.

**Always validate the screen against the 2026-07-24 reference first.** A correct
implementation reproduces the frozen rules: `quick` first eligible at 2 pairs,
`confirm` first eligible at 6. If it does not, the screen is wrong, not the data.
Widen the threshold grid if a degraded series returns "none eligible" at low
counts -- `quick`'s default grid tops out at 4.55% and a 2-pair degraded screen
needs ~5.5%.

### Detecting the staircase (F14's readout)

Use this when a probe's ramp is non-zero and you need to know whether it is a
governor step pattern or something else. Two signatures matter: the step fit
beating the linear fit, and the **draw and plan breaks landing at the same
times**. Feed it the per-ordinal medians across all blocks, not one block.

```python
import json, statistics as st

def per_ordinal_medians(path, workload, metric="drawDurationsNanoseconds"):
    blocks = [b["artifact"]["finalDraw"]
              for q in json.load(open(path))[workload] for b in q]
    ys = [b[metric] for b in blocks if b.get(metric)]
    n = min(len(y) for y in ys)
    gap_ms = st.median([b["elapsedNanoseconds"] / b["drawCount"] / 1e6 for b in blocks])
    return [st.median([y[i] for y in ys]) for i in range(n)], gap_ms

def step_fit(med, k):
    """Best k-segment piecewise-constant fit by DP. Returns (R^2, break ordinals)."""
    n = len(med)
    def sse(a, b):
        s = med[a:b]; m = st.mean(s); return sum((x - m) ** 2 for x in s)
    INF = float("inf")
    D = [[INF] * (k + 1) for _ in range(n + 1)]; D[0][0] = 0
    BK = [[None] * (k + 1) for _ in range(n + 1)]
    for j in range(1, k + 1):
        for i in range(1, n + 1):
            for t in range(j - 1, i):
                v = D[t][j - 1] + sse(t, i)
                if v < D[i][j]: D[i][j] = v; BK[i][j] = t
    cuts = []; i = n
    for j in range(k, 0, -1):
        t = BK[i][j]; cuts.append(t); i = t
    ym = st.mean(med); tot = sum((v - ym) ** 2 for v in med)
    return 1 - D[n][k] / tot, sorted(c for c in cuts if c > 0)
```

Compare `step_fit(med, 5)` against a plain linear R^2, then run it for both
metrics and convert breaks to milliseconds with `cut * gap_ms`. Reference at
`HEAD` (F14): draw linear 0.9224, draw 5-step **0.9785** with breaks at
61/140/236/314 ms; plan breaks at 70/148/227/323 ms. `content-churn`: linear
0.088, no step structure.

### Recovering which revision an artifact directory holds

Artifact directory names are **tree hashes**, not commit hashes, and no identity
file records the revision. Map them back with:

    for r in $(git log --format=%h -20); do
      echo "$r $(git rev-parse $r^{tree} | cut -c1-12)"
    done

This is how F12 recovered `b834a44`, `8188b9a`, `8e216bc` and `df80150` from
probe directories that had otherwise lost their provenance.

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

- **Status:** closed. **No longer binding** -- it constrained the bisect, which
  F12 retired. Kept because it stays true of any future pre-`4061096`
  collection, and because it explains the reduced block counts in F5 and F12.
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

- **Status:** closed, **with its inference withdrawn by F10/F11 (see R10).** The
  measurements below stand and are still cited. What does not stand is the
  conclusion that a removed regularizer explains the widening, and the
  instruction to bisect on the block floor. Read F10 and F11 next.
- **Rejects H4** -- that part holds, and F11 explains *why* the distribution is
  unimodal-but-wide.
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
- **Next action -- WITHDRAWN.** This finding prescribed "treat where the block
  floor moved as the primary bisect readout". F10 shows the floor moves in the
  clean control too, so it discriminates nothing; R10 records the withdrawal.
  The replacement readout is the within-block ramp (F11).

### F10 -- the block floor dropped in `content-churn` too, so the floor drop is not the defect

- **Status:** closed. **Corrects the inference in F9**; see R10.
- **Date:** 2026-07-27. Cost no machine time; ran F9's own readout on the
  control workload, which F9 never did.
- **Method:** the F9 percentile and block-floor comparison, applied to
  `content-churn` (and `style-churn` for 2026-07-24) as well as
  `incremental-mixed`.
- **Measurements:**

  | series | pooled p10 | pooled p90 | p90-p10 | block-floor median | floor SD | block-median SD |
  | --- | --- | --- | --- | --- | --- | --- |
  | `incremental-mixed` 07-24 | 160666 | 198375 | 37709 | 161396 | 2.25% | 1.44% |
  | `incremental-mixed` `HEAD` | 146204 | 231604 | **85400** | 148376 (**-8.1%**) | 3.97% | **4.65%** |
  | `content-churn` 07-24 | 871583 | 1012425 | 140842 | 873750 | 0.94% | 0.99% |
  | `content-churn` `HEAD` | 835125 | 942129 | **107004** | 836687 (**-4.2%**) | 0.72% | 0.98% |
  | `style-churn` 07-24 | 877079 | 1022421 | 145342 | 880312 | 0.97% | 1.15% |

- **Observation:** the floor fell in **both** workloads. In `content-churn` the
  whole distribution shifted down uniformly (p10 -4.2%, median -5.3%, p90 -6.9%)
  and got **tighter**, not wider. In `incremental-mixed` the floor fell while
  the p90 rose 16.8%.
- **Inference:** the floor drop is a **real, general speedup** delivered by the
  recent optimizations, and it is present where the variance is clean. It
  therefore cannot be the cause of the variance inflation. F9 read one series
  and attributed both the floor drop and the widening to a single removed
  regularizer; the control shows the two are separate phenomena and only the
  widening needs explaining.
- **Consequence:** the "primary bisect readout is the block floor" instruction
  at the end of F9 is **withdrawn**. The floor moves for a benign reason. F11
  supplies the readout that replaces it.
- **Uncertainty:** none material. `style-churn` at `HEAD` was not collected, so
  the second control is single-day.
- **Note on small discrepancies with F9's table:** F9 reports p10 146208 / p90
  231791 where this finding reports 146204 / 231604, from linear interpolation
  between order statistics rather than nearest-rank. Same data, different
  percentile convention; nothing turns on it.

### F11 -- `incremental-mixed` draws ramp ~41% within every block; the clean series is flat

- **Status:** closed. **This is the defect.** Primary readout for all further
  probes.
- **Date:** 2026-07-27. Cost no machine time -- all series were already on disk.
- **Method:** for each block, least-squares slope of `drawDurationsNanoseconds`
  against draw ordinal, expressed as total % rise across the block's 50 draws.
  Also the median duration at each ordinal, bucketed into deciles.
- **Measurements** -- decile medians, normalized to each series' own first
  decile:

  | series | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
  | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
  | `incremental-mixed` 07-24 | 1.00 | 1.01 | 0.99 | 1.01 | 1.00 | 1.00 | 1.00 | 1.00 | 0.99 | 1.00 |
  | `incremental-mixed` `HEAD` | 1.00 | 1.12 | 1.11 | 1.24 | 1.26 | 1.33 | 1.34 | 1.44 | 1.43 | **1.45** |
  | `content-churn` `HEAD` | 1.00 | 1.00 | 0.99 | 1.00 | 0.99 | 1.00 | 0.99 | 0.99 | 0.99 | 0.98 |

  Per-block ramp distribution:

  | series | median rise | p10 | p90 | blocks rising >10% |
  | --- | --- | --- | --- | --- |
  | `incremental-mixed` 07-24 | **-0.2%** | -6.1% | +5.3% | **3 / 96** |
  | `incremental-mixed` `HEAD` | **+41.1%** | +22.9% | +57.6% | **95 / 96** |
  | `content-churn` 07-24 | +0.7% | -3.2% | +4.0% | 0 / 96 |
  | `content-churn` `HEAD` | -0.9% | -9.2% | +5.2% | 1 / 96 |

  Absolute first and last draw, `incremental-mixed`:

  | series | draw[0] median | draw[49] median |
  | --- | --- | --- |
  | 07-24 (clean) | 181250 ns | 175021 ns |
  | `HEAD` | **138604 ns** | **209334 ns** |

- **Observation:** at `HEAD` a block's first draw is **24% faster** than any
  typical draw in the clean series, and its last draw is **20% slower**. The
  clean series is flat end to end. `dirtyRowCounts` is a constant **6** at every
  ordinal in every series, so the draw is not being asked to do more work as the
  block progresses -- the same 6 rows cost 41% more by the end.
- **Block-local, not cumulative:** ramp and floor are uniform across all four
  quartet slots (41.0 / 38.7 / 42.8 / 42.4%), so it resets between blocks and
  carries nothing across a quartet or a process lifetime.
- **Inference:** the widening is not a wider random distribution. It is a
  **systematic within-block drift**, and the pooled series is a mixture of a
  moving mean -- which is exactly why it looked unimodal-but-wide in F9, why the
  p10 fell (early draws), and why the p90 rose (late draws), all at once.
- **The residual noise is unchanged.** The share of total excess-over-floor held
  by the slowest 1 / 5 / 10% of draws is nearly identical in all four series
  (~4% / ~15% / ~26-30%). Once the ramp is accounted for, the distribution shape
  is the same as it was on 2026-07-24. Nothing became noisier; something became
  *sloped*.
- **Competing interpretations:** the ramp explains the growth in per-draw spread
  and in the pooled percentiles. It does **not** by itself explain the
  between-block SD: de-ramping each block moves the block-median SD only from
  4.65% to 4.25%. So block *levels* vary for a further reason, most likely
  block-to-block variation in ramp steepness (SD 13.7% across blocks) interacting
  with where the block's median lands. This is an open sub-question, and it
  matters because between-block SD is what drives paired verdicts (F4).
- **Next action:** report per-block ramp at every future probe. It separates
  clean from degraded far more sharply than any other statistic here -- 3/96
  against 95/96 -- so a probe needs only a handful of quartets to read.

### F12 -- the ramp grew progressively across the recent history; there is no single commit

- **Status:** closed. **Refutes H1 as stated and retires the bisect.**
- **Date:** 2026-07-27. Cost no machine time -- re-read the F5 probe artifacts
  under the F11 readout.
- **Method:** per-block ramp (F11) computed on every `incremental-mixed` series
  already on disk, with the revision recovered by matching each artifact
  directory's tree hash against `git rev-parse <rev>^{tree}`.
- **Measurements** (chronological):

  | revision | what it landed | blocks | ramp median | blocks rising >10% | block floor |
  | --- | --- | --- | --- | --- | --- |
  | 2026-07-24 ref | pre-`b7f5c12` | 96 | **-0.2%** | **3 / 96** | 161396 |
  | `b834a44` 07-27 10:44 | observer fix landed, full-viewport planning | 48 | **+10.8%** | 27 / 48 | 147416 |
  | `8188b9a` 07-27 ~11 | damage-scoped planning | 24 | **+25.2%** | 23 / 24 | 143646 |
  | `8e216bc` 07-27 12:16 | | 48 | **+37.0%** | 48 / 48 | 148458 |
  | `4061096` = `HEAD` | observer/marker fix | 96 | **+41.1%** | 95 / 96 | 148376 |

  `content-churn` and `style-churn` at `8188b9a`: ramp -0.6% / +0.4%,
  1/24 and 0/24 blocks rising. Flat, like every other day.

- **Observation:** the ramp is **monotonically increasing in commit order**, from
  absent to universal. At `b834a44` it is half-present -- 27 of 48 blocks ramp --
  which is what the middle of a dose-response curve looks like, not what a
  defect's on/off boundary looks like.
- **Inference:** no commit "caused" this. Successive commits each deepened it.
  Naming one is impossible and the Phase 2 bisect is therefore retired -- which
  also removes the F8 collection-obstruction blocker and the need for the
  draw-only collector driver, since neither is required any more.
- **Uncertainty:** the two 48-block rows are 12 quartets with 3 discarded each
  (F8), and the `8188b9a` row is 24 blocks. The ramp separation is large enough
  (10.8% against -0.2%, with 27/48 against 3/96) that sample size does not
  threaten the ordering. The window's early end is still unmeasured: nothing
  between `b7f5c12` and `b834a44` has been probed, so where the ramp *first*
  appears is unknown -- but under F13 that question no longer has an answer worth
  buying.

### F13 -- draw and plan ramp in lockstep, and the ramp tracks main-thread duty cycle

- **Status:** closed. **The mechanism finding. Establishes H6.**
- **Date:** 2026-07-27. Cost no machine time.
- **Method:** apply the F11 ramp readout to `planDurationsNanoseconds` as well as
  `drawDurationsNanoseconds`, and compute per-block duty cycle as
  `(cumulativeDrawNanoseconds + cumulativePlanNanoseconds) / elapsedNanoseconds`.
- **Why this is the right test:** the two timers bracket **disjoint work in
  unrelated code**. The draw timer wraps `clipFramePlan` + `drawRenderFrame`
  inside `draw(_:)` under CoreGraphics (`app/SwiftTerminalSessionView.swift:143`
  and `:167`). The plan timer wraps `planFrame` in `planIfNeeded` on the
  PTY-output path. They share no data structure and no call path.
- **Measurements** -- ramp of each metric:

  | series | draw ramp | plan ramp |
  | --- | --- | --- |
  | `incremental-mixed` `HEAD` | **+41.1%** | **+41.2%** |
  | `incremental-mixed` `8188b9a` | +25.2% | +27.1% |
  | `incremental-mixed` `b834a44` | +10.8% | +4.3% |
  | `content-churn` `HEAD` | -0.9% | -0.2% |

  Duty cycle against ramp:

  | series | draw duty | draw+plan duty | ms/block | gap between draws | draw ramp |
  | --- | --- | --- | --- | --- | --- |
  | `content-churn` `HEAD` | 9.38% | **21.41%** | 467 | 9.3 ms | **-0.9%** |
  | `content-churn` `8188b9a` | 9.58% | **22.05%** | 459 | 9.2 ms | **-0.6%** |
  | `incremental-mixed` `b834a44` | 1.98% | **17.77%** | 434 | 8.7 ms | **+10.8%** |
  | `incremental-mixed` `8188b9a` | 2.00% | **3.70%** | 441 | 8.8 ms | **+25.2%** |
  | `incremental-mixed` `8e216bc` | 2.11% | **3.83%** | 435 | 8.7 ms | **+37.0%** |
  | `incremental-mixed` `HEAD` | 2.13% | **3.82%** | 437 | 8.7 ms | **+41.1%** |

- **Observation 1 -- lockstep.** At `HEAD` two unrelated timed regions slow by
  41.1% and 41.2% over the same block. That is not a coincidence available to any
  algorithmic explanation.
- **Observation 2 -- dose-response.** Ramp is monotonically inverse to duty
  cycle across every row. The single largest step, `b834a44` -> `8188b9a`, is
  damage-scoped planning cutting duty from 17.8% to 3.7% and the ramp jumping
  from 10.8% to 25.2%. Every workload above ~20% duty is flat; every workload
  below ~4% ramps hard.
- **Inference:** the app's main thread is being **progressively slowed by the
  platform**, not by its own code. An `incremental-mixed` block is ~96% idle in
  8.7 ms gaps between 50 short bursts; macOS lowers frequency and/or migrates
  such a thread to an efficiency core, and the demotion deepens over the block.
  Between blocks the harness's own work re-boosts it, which is why F11 sees the
  ramp reset every block and stay uniform across quartet slots.
- **Consequence:** the render path is **not** regressed. It is faster --
  first-draw cost fell from 181 us to 139 us (F11) -- and `content-churn`
  improved uniformly (F10). The instrument is reporting the CPU's power state.
  The repair belongs in the harness.
- **Competing interpretations, both retained until the H6 probe runs:**
  - The correlation spans four revisions and one machine. Duty cycle and
    "recency of the optimizations" are collinear here; only the intervention
    experiment separates them.
  - Something other than duty cycle could slow both timers together -- memory
    bandwidth contention from another process, or a shared allocator lock.
    `machineStateSamples` reports `thermalState: nominal` and
    `lowPowerMode: false` at both ends of every block, so thermal throttling and
    Low Power Mode are already excluded.
- **Uncertainty:** `machineStateSamples` carries only start/completion entries,
  so there is no per-draw record of frequency or core class. Confirming the
  mechanism directly would need either the intervention experiment (H6) or
  per-draw `mach` CPU-number sampling, which the harness does not collect.
- **Next action:** the H6 duty-cycle probe. It is the whole of Phase 2 now.

### F14 -- the ramp is a staircase, and both timers step at the same wall-clock moments

- **Status:** closed. **This is the confirmation of H6.** Cost no machine time.
- **Date:** 2026-07-27.
- **Method:** take the per-ordinal median across all 96 blocks (which averages
  out per-draw noise and leaves only structure common to every block), then fit
  a piecewise-constant model by dynamic programming and compare it against a
  linear fit. Repeat independently for `drawDurationsNanoseconds` and
  `planDurationsNanoseconds`. Convert break ordinals to wall-clock using the
  block's own 8.73 ms inter-draw interval.
- **Measurements** -- `incremental-mixed` at `HEAD`:

  | model | R^2 (draw) | params |
  | --- | --- | --- |
  | linear | 0.9224 | 2 |
  | 3-level step | 0.8962 | 5 |
  | 4-level step | 0.9522 | 7 |
  | **5-level step** | **0.9785** | 9 |
  | 6-level step | 0.9819 | 11 |

  The 5 fitted levels: **143994 -> 162363 -> 182235 -> 195648 -> 208176 ns**,
  i.e. ratios **1.000 -> 1.128 -> 1.266 -> 1.359 -> 1.446**.

  **Break times, the two timers compared:**

  | metric | break 1 | break 2 | break 3 | break 4 |
  | --- | --- | --- | --- | --- |
  | draw | **61 ms** | **140 ms** | **236 ms** | **314 ms** |
  | plan | **70 ms** | **148 ms** | **227 ms** | **323 ms** |
  | difference | +9 ms | +8 ms | -9 ms | +9 ms |

  `content-churn` at `HEAD`, same analysis: linear R^2 = **0.088**, best 5-level
  step R^2 = 0.39 with breaks at 9 ms and 364-430 ms -- i.e. no structure, the
  fit is chasing noise. Level ratios span 1.000 to 0.965. Flat.

- **Observation 1 -- it is a staircase, not a drift.** A 5-level step model beats
  a linear one (0.9785 vs 0.9224) despite the per-ordinal medians being smooth
  estimates. The levels are discrete and the plateaus are flat.
- **Observation 2 -- the steps are regularly spaced.** Break spacings are 61, 79,
  96, 79 ms. Roughly one step every ~80 ms.
- **Observation 3 -- and this is the decisive one -- the two timers step
  together.** Draw and plan breaks agree to within +/-9 ms, which is **one
  inter-draw interval (8.73 ms)** -- the resolution limit of this measurement.
  Two timers bracketing disjoint work on unrelated code paths change speed at the
  same wall-clock instants, four times in a row.
- **Inference:** **H6 is confirmed.** No property of the app's own code can make
  `draw(_:)` under CoreGraphics and `planFrame` on the PTY-output path step to a
  new speed simultaneously, at quantized levels, at regular ~80 ms intervals.
  That is a CPU frequency governor changing P-state under a thread it has judged
  idle. The regular interval is the governor's decision period; the quantization
  is its P-state ladder.
- **Refinement on the mechanism:** the total excursion is **1.446x**. That is
  consistent with a **frequency reduction** across a few P-states, not with
  migration to an efficiency core, which on this class of hardware would cost
  substantially more than 1.45x. So the fix should target frequency residency,
  not core affinity -- which makes core pinning the weaker of the two
  interventions proposed under H6.
- **Why `content-churn` is exempt, restated precisely:** it holds the thread at
  21% duty, the governor never demotes it, and its per-ordinal medians carry no
  step structure at all (linear R^2 = 0.088).
- **Competing interpretations:** an app-internal cause would have to be a shared
  resource that both code paths contend for, that degrades in discrete steps at
  regular wall-clock intervals independent of draw ordinal, and that resets
  between blocks. No such resource is plausible, and none is proposed. The
  remaining honest caveat is that this is one machine and one macOS version.
- **Uncertainty:** the break times are resolved only to one inter-draw interval
  (8.73 ms), so "the two timers step together" is established to within that
  bound, not more finely. Sharper resolution would need per-draw timestamps,
  which the harness does not record.
- **Consequence for the fix:** the render path is exonerated outright. The repair
  is to make the harness hold the measured thread in a stable frequency state for
  the duration of a block. See D1.

### F15 -- no analysis-side estimator recovers the clean distribution; the fix must be in collection

- **Status:** closed. **Negative result. Refutes candidates B and D of D2.**
- **Date:** 2026-07-27. Cost no machine time -- pure re-analysis of the F2/F3
  A/A series, where the true answer is known to be zero.
- **Method:** recompute the paired symmetric difference under alternative
  estimators and compare paired SD and simulated false-verdict rates against the
  production block-mean estimator. Both arms carry identical code, so any
  non-zero result is instrument noise.
- **Measurements** -- `incremental-mixed` at `HEAD`, quick threshold 3.8%:

  | estimator | paired SD | false quick | false confirm |
  | --- | --- | --- | --- |
  | **block mean (production)** | **6.26%** | **10/24** | **3/8** |
  | block median | 7.00% | 10/24 | 3/8 |
  | first 5 draws | 8.89% | 16/24 | 6/8 |
  | first 7 draws (one plateau, F14) | 7.88% | 13/24 | 6/8 |
  | first 15 draws | 4.98% | 10/24 | 4/8 |
  | **first 20 draws** | **4.03%** | 7/24 | 3/8 |
  | first 25 draws | 4.13% | **5/24** | **0/8** |
  | first 35 draws | 5.60% | 8/24 | 4/8 |
  | ordinal-matched, median of syms | 5.90% | 9/24 | 4/8 |
  | ordinal-matched, mean of syms | 5.68% | 9/24 | 4/8 |
  | ordinal-matched, first 7 only | 8.73% | 16/24 | 7/8 |

  Same estimators on the **clean `content-churn` control** (threshold 4.5%):
  block mean **1.37%** / 0-24 false; first 25 draws **3.33%** with **5/8 false
  confirms**; ordinal-matched 1.31-1.33% / 0-24.

- **Observation 1 -- ordinal matching barely helps.** 6.26% -> 5.68%. The reason
  is structural: the ramp is *common to both blocks in a pair*, so the symmetric
  difference of block means already cancels it. Matching ordinals cancels the
  same common trajectory a second time and removes almost nothing new. This is
  the same fact F11 recorded from the other direction (de-ramping moved
  block-median SD only 4.65% -> 4.25%).
- **Observation 2 -- truncation trades one noise for another and loses.** The
  best truncation (20-25 draws) reaches ~4.0-4.1%, still ~2.7x the 1.49% target,
  and the improvement is bought by discarding ramp-contaminated draws at the cost
  of sampling noise. **The control proves the trade is bad:** on `content-churn`,
  which has no ramp to remove, truncation is pure loss -- 1.37% -> 3.33%, turning
  a 0/8 false-confirm rate into 5/8. An estimator that wrecks the clean workload
  is not a fix.
- **Inference:** **the fix cannot live in the statistic.** The variance is in the
  collected data, not in how it is summarized. Candidate D (ramp-robust
  statistic) is refuted directly. Candidate B (shorten the block) is refuted in
  its analysis-equivalent form and badly weakened in its collection form, since
  the 7-draw first plateau is the *worst* performing estimator tested.
- **Uncertainty:** truncation-in-collection is not exactly truncation-in-analysis
  -- a genuinely shorter block would re-boost more often. But F16 shows the early
  plateau's *level* is already 3.8% variable, which is the fatal objection and
  does not depend on that distinction.

### F16 -- the variance is in block LEVEL, not in the ramp, and it grows through the block

- **Status:** closed. **Names the quantity any fix must move.** No machine time.
- **Date:** 2026-07-27.
- **Method:** split the observed block-mean CV into the sampling floor implied by
  per-draw noise *about each block's own trend* (`residual CV / sqrt(n)`) and the
  residual true block-to-block level variation.
- **Measurements:**

  | series | per-draw CV about trend | sampling floor | observed block-mean CV | **true block-LEVEL CV** |
  | --- | --- | --- | --- | --- |
  | `incremental-mixed` 07-24 | 8.52% | 1.20% | 1.26% | **0.38%** |
  | `incremental-mixed` `HEAD` | 11.98% | 1.69% | 4.18% | **3.83%** |
  | `content-churn` 07-24 | 5.80% | 0.82% | 0.96% | **0.49%** |
  | `content-churn` `HEAD` | 4.79% | 0.68% | 1.09% | **0.86%** |

  Where within a block that level variation sits:

  | series | early plateau CV (draws 0-6) | late plateau CV (last 7) | r(early, late) |
  | --- | --- | --- | --- |
  | `incremental-mixed` 07-24 | 2.95% | 2.77% | +0.06 |
  | `incremental-mixed` `HEAD` | **5.93%** | **11.76%** | **-0.16** |
  | `content-churn` `HEAD` | 3.52% | 3.12% | -0.07 |

- **Observation 1 -- block-level CV is the whole story.** It went 0.38% -> 3.83%,
  a **10x** increase, and `3.83% * sqrt(2) = 5.4%` accounts for most of the
  observed 6.26% paired SD. Everything else -- the ramp, the per-draw CV, the
  floor -- is either downstream of this or cancels in pairing.
- **Observation 2 -- blocks diverge as they run.** Level variation grows from
  5.93% early to 11.76% late (clean: 2.95% -> 2.77%, flat). Each block descends
  its own staircase at its own times, so late draws land on different rungs in
  different blocks.
- **Observation 3 -- and blocks do not start alike either.** Subtracting the
  7-draw sampling floor (11.98%/sqrt(7) = 4.53%) from the 5.93% early CV leaves
  ~3.8% of *true* early-level variation, against ~0% for the clean series. Blocks
  begin at different rungs. **This is what kills the short-block candidate:** even
  a 7-draw block would carry ~3.8% level variation, so shortening cannot reach
  the 1.49% target no matter how the sampling noise is handled.
- **Observation 4 -- early and late levels are uncorrelated** (r = -0.16), so
  this is not a per-block constant offset that could be normalized away. The
  trajectory diverges independently of where it started.
- **No session drift:** first-half vs second-half early level differs by -1.6%
  (`incremental-mixed` `HEAD`) and -0.3% (`content-churn`), so thermal drift
  across the ~40-minute collection is not a contributor. Consistent with R3.
- **Inference:** the fix must **stop the governor from moving during and between
  blocks**, not summarize around it. The target is block-level CV <= ~0.5%.
- **The control also supplies the target's feasibility proof:** `content-churn`
  on the *same machine, same session, same harness* holds 21% occupancy and
  achieves 0.86% level CV and 1.37% paired SD. A clean instrument is reachable
  here; it just requires the thread to stay busy.

### F17 -- the pacer flattens the ramp and makes the variance worse; candidate A refuted

- **Status:** closed. **Re-collected clean and confirmed** -- see the
  re-collection table below. The original series were contaminated by orphaned
  apps (F19); the repeat, run after that fix with zero orphans verified before,
  between and after, reproduces the same result. **Candidate A is refuted.**
- **Date:** 2026-07-27, afternoon session.
- **What was built:** `paceFrame` in `app/TerminalBenchmark.swift`, called once
  per accepted frame after its acknowledgment is written. It spins (never sleeps)
  until the frame's total main-thread busy time reaches a fixed budget, so
  occupancy is constant regardless of how long planning and drawing took. Gated
  on `DANTERM_BENCHMARK_FRAME_BUSY_BUDGET_NS`, absent by default. Budget 1.8 ms
  against an 8.7 ms frame period, targeting the ~21% occupancy at which
  `content-churn` is clean.
- **Reproduction:** scratchpad driver calling `run_calibration` with
  `resolve_baseline` replaced by `SNAPSHOT.snapshot_candidate`, so the arm is
  built from the working tree. 24 quartets each. **Paced and unpaced series were
  collected back to back in one session**, per the investigation rules.
- **Measurements** -- `incremental-mixed`, same session, same working tree:

  | | ramp median | blocks ramping | **level CV** | paired SD | per-draw mean | false quick |
  | --- | --- | --- | --- | --- | --- | --- |
  | **paced** | **+6.7%** | 40/96 | **5.75%** | **5.12%** | 168336 ns | 6/24 |
  | **unpaced** | +33.0% | 95/96 | **2.07%** | **3.97%** | 179200 ns | 3/24 |

- **Observation 1 -- the pacer did exactly what it was designed to do.** The ramp
  fell from +33.0% to +6.7% and blocks ramping from 95/96 to 40/96. Per-draw mean
  fell 6%, consistent with the clock staying higher. The frame period (8687 vs
  8723 us) and block duration (434 vs 436 ms) are unchanged, so the spin did not
  stretch the block.
- **Observation 2 -- and the variance got worse anyway.** Block-**level** CV,
  the quantity F16 identified as the one that must come down, nearly **tripled**:
  2.07% -> 5.75%. Paired SD rose 3.97% -> 5.12%.
- **Clean re-collection**, after the F19 orphan fix, same session, same tree,
  zero orphans verified before / between / after, both workloads in both arms:

  | series | ramp | blocks ramping | **level CV** | paired SD | per-draw mean | false quick |
  | --- | --- | --- | --- | --- | --- | --- |
  | **paced** `incremental-mixed` | **+9.0%** | 43/96 | **7.38%** | **4.36%** | 163597 ns | 9/24 |
  | **unpaced** `incremental-mixed` | +26.3% | 92/96 | **2.75%** | **3.98%** | 177511 ns | 6/24 |
  | paced `content-churn` | -0.7% | 3/96 | 0.95% | 1.68% | 873662 ns | 0/24 |
  | unpaced `content-churn` | -0.7% | 3/96 | 1.55% | 1.70% | 876158 ns | 0/24 |

  The result reproduces: the ramp falls (26.3% -> 9.0%, 92/96 -> 43/96), the mean
  falls 8% as the clock stays higher, and **level CV rises 2.75% -> 7.38%**
  anyway. `content-churn` is a clean internal control -- the pacer is inert there
  (its 2.1 ms measured busy time already exceeds the 1.8 ms budget), and paced
  and unpaced are indistinguishable, which shows the difference in
  `incremental-mixed` is attributable to the pacer and not to the session.
- **Inference:** **flattening the ramp does not fix the metric.** This is F15's
  conclusion arriving a second time by a different route, and more forcefully:
  F15 showed the ramp cancels in pairing, so removing it should not help; F17
  shows removing it actively hurts. Candidate A is refuted, and with it the last
  of the four D2 candidates.
- **Leading explanation, not directly tested:** the paced ramp is inconsistent
  rather than absent -- 40 of 96 blocks still rise more than 10%. Two arm apps
  spinning ~21% of a core each, plus the producer process, contend for cores in a
  way that varies block to block. That contention would be a *new* source of
  block-level variation, which is what the numbers show. If so, a larger budget
  makes it worse, not better, so budget tuning is not the obvious next move.
- **The `content-churn` control could not test the pacer, and says something
  else instead.** Its measured busy time is 2.097 ms per frame, already **above**
  the 1.8 ms budget, so `paceFrame`'s guard returns early and the pacer is
  **inert** for that workload. Its numbers therefore isolate session conditions
  rather than the intervention -- see F18.

### F18 -- session-to-session drift is large, and it moves the two workloads in opposite directions

- **Status:** **partly retracted.** The magnitudes were confounded by
  accumulating orphan load (F19), and the clean re-collection does not reproduce
  the headline claim. **The "opposite directions" result should be treated as a
  contamination artifact, not a property of the machine.** Across the three
  unpaced measurements of the day, level CV was 3.83% (morning), 2.07%
  (contaminated afternoon) and 2.75% (clean re-run) for `incremental-mixed`, and
  0.86% / 2.49% / 1.55% for `content-churn` -- both vary by roughly 2x with no
  consistent direction, which is ordinary session noise rather than the
  systematic opposite-direction effect this finding claimed.
- **What survives, and it matters:** session-to-session variation of ~2x in these
  variance statistics is real, so **cross-session magnitude comparisons remain
  unreliable** and the rule this finding argued for -- a same-session control for
  every intervention -- stands. F16's "0.38% -> 3.83%" should still be read as
  uncertain by about a factor of two; the degradation is real (every
  2026-07-27 measurement is far above the 2026-07-24 reference's 0.38%) but its
  size is not pinned down.
- **Date:** 2026-07-27. Two sessions the same day, morning and afternoon, same
  machine, operator holding it idle for both.
- **Measurements** -- unpaced in both cases (`content-churn`'s pacer was inert,
  F17):

  | series | morning | afternoon | direction |
  | --- | --- | --- | --- |
  | `incremental-mixed` level CV | 3.83% | **2.07%** | **improved** |
  | `incremental-mixed` paired SD | 6.26% | **3.97%** | **improved** |
  | `content-churn` level CV | 0.86% | **2.49%** | **degraded** |
  | `content-churn` paired SD | 1.37% | **2.23%** | **degraded** |
  | `content-churn` per-draw mean | 880508 ns | 931027 ns | +5.7% |

- **Observation:** both workloads moved substantially between two sessions of the
  same day with no code change, and **in opposite directions**. A simple "the
  machine got noisier" account does not fit.
- **Consequence for this file:** cross-session magnitude comparisons are weaker
  than they were assumed to be when F10-F16 were written.
  - **Unaffected:** F11 (the ramp), F12 (its progression), F13 (the lockstep),
    F14 (the staircase). These are *within-block structural* facts -- a shape
    measured inside each block -- and a level shift between sessions cannot
    manufacture a 41% monotonic ramp in 95 of 96 blocks or make two timers step
    together.
  - **Weakened:** F16's headline "level CV 0.38% -> 3.83%". The degradation is
    still real -- 2.07% in the best session measured is far above the 2026-07-24
    reference's 0.38% -- but its *magnitude* is uncertain by roughly a factor of
    two, and 3.83% should not be treated as the number to beat.
  - **Weakened:** any comparison in F4, F5, F9 or F10 that reads a variance
    magnitude across days rather than a shape.
- **Inference:** the investigation rule requiring a same-session control was
  right and is now shown to be *more* necessary than it appeared. It should be
  extended: **a same-session control is required for every intervention, not only
  for cross-revision comparisons.** F17 would have reported a spurious success
  without one -- its 12-block pilot, compared against the morning's unpaced
  series, appeared to cut block-mean CV from 4.18% to 1.73%.
- **Uncertainty:** the cause of the drift is unknown. Thermal accumulation across
  ~40 minutes of continuous benchmarking is the obvious candidate but does not
  explain the opposite directions. Not investigated; it is a caveat, not a lead.

### F19 -- the harness orphans benchmark apps, contaminating every later series in a session

- **Status:** closed, **fixed**. A harness defect, not a property of the app
  under test.
- **Date:** 2026-07-27, found by the operator noticing eight `DanTerm Benchmark`
  icons still in the Dock after the F17 collection had finished.
- **Observation:** eight orphaned apps were alive, in pairs launched at 15:25:15,
  15:27:46, 15:27:55 and 15:39:23, all from the working-tree arm build. Set
  against the collection windows:

  | series | window | orphans alive during it |
  | --- | --- | --- |
  | F17 pilot | -> 15:26:50 | 0 (leaked 2) |
  | **F17 paced** | 15:27 -> 15:39 | **2+** |
  | **F17 unpaced control** | 15:39 -> 15:43 | **6** |

- **Mechanism:** `PersistentDrawArms.close()` sends SIGINT to the
  `terminal-benchmark.sh` wrapper, waits 30 s, then SIGKILLs it. The wrapper does
  trap `INT`/`TERM` and stop the app it owns -- but **a SIGKILLed shell never runs
  its trap**, so the app it launched is orphaned. Why the wrapper failed to exit
  within its grace period was not established and is not needed for the fix:
  ownership of the app survives the wrapper regardless, because the identity file
  records the app's own pid and `start()` already validates it.
- **Fix:** `close()` now probes each recorded app pid for liveness and SIGKILLs
  any that outlived its wrapper. Liveness is probed first so an app its wrapper
  did stop is left alone, which keeps a recycled pid from being signalled. Two
  behavioral tests pin both halves; the existing teardown test could not catch
  this because its fake process always exited on `wait()`, so the SIGKILL path was
  never exercised.
- **Consequence -- F17 and F18 are contaminated and must be re-collected.** The
  unpaced control that F17 treats as its clean baseline ran with the *most*
  background load of the three series, which is backwards. The orphans were
  `SN` (sleeping, low priority) at 0.0% CPU when found, and their accumulated CPU
  time is most plausibly work done while they were still active arms, so the
  contamination is probably modest -- but "probably modest" does not support a
  conclusion about a 2% effect, and the orphans still held windows and
  WindowServer resources, which a draw benchmark that gates on window visibility
  is not entitled to ignore.
- **Consequence -- "the operator held the machine idle" was not true.** Every
  investigation rule and finding that leans on an idle machine leans on an
  assumption the harness was quietly violating within a session. F18's
  session-to-session drift, including its odd opposite-direction result, is now
  equally explicable as accumulating orphan load and should not be treated as a
  property of the machine until re-measured.
- **Scope of the doubt:** morning-session runs left no orphans behind, and all
  eight strays came from the afternoon's working-tree build, so the F1-F16 series
  are not implicated by direct evidence. That is weaker than a guarantee -- an
  orphan from an earlier session could have been cleaned up by other means -- so
  treat it as "no evidence of contamination" rather than "known clean".
- **Fix verified:** the re-collection ran two full series that previously leaked
  2-4 apps each and finished with **zero orphans**.
- **Standing requirement added:** verify no benchmark apps survive before a
  series, between series, and after the last one. **Match on the binary path,
  not the bare name:** `pgrep -f "MacOS/DanTerm Benchmark"`. The naive pattern
  `pgrep -f "DanTerm Benchmark"` also matches any shell whose command line
  mentions it -- including the monitoring command doing the checking -- and
  reports a phantom orphan.
- **Not fixed, and separate work:** the wrapper does not exit on SIGINT, so
  `close()` waits the full 30 s per arm before SIGKILLing it -- roughly two
  minutes of dead time at the end of every run, during which a finished
  collection looks hung. That stall is *why* the SIGKILL happens and therefore
  why apps were orphaned; this fix reaps the orphans rather than preventing
  them. Root cause not diagnosed: `terminal-benchmark.sh` does trap `INT`/`TERM`
  and its persistent-mode tail polls on `sleep 0.25`, where bash should run the
  trap within ~250 ms. Something defers or swallows it.

### F20 -- the Phase 6 pair-count table was derived under the wrong gate; `confirm` needs ~100 pairs, not 48

- **Status:** closed. Re-analysis only, no machine time.
- **Date:** 2026-07-27, checking the handoff's recommended action before spending
  a collection on it.
- **What was wrong:** the handoff's table held **only** the A/A false-positive
  rate at 5%, and scored detection against a **5% injected effect** for both
  modes. The frozen calibration gates are stricter and mode-specific: `quick` is
  5% effect / detection >= 0.80 / inconclusive <= 0.20, but **`confirm` is a 3%
  effect / detection >= 0.90 / inconclusive <= 0.10**. Screening `confirm`
  against a 5% effect with no detection gate makes it look far cheaper than it is.
- **Method, and why it is trustworthy:** the repo's own
  `terminal-benchmark-calibration.calibrate_threshold_grid` was run over the
  frozen `PAIR_COUNTS` grid with each mode's real gates, taking the *lowest*
  eligible threshold at each count (A/A FP <= 5% sets the floor; detection sets
  the ceiling). Validated against the clean 2026-07-24 reference, where it
  reproduces the frozen rules exactly: `quick` first eligible at **2 pairs** and
  `confirm` first eligible at **6 pairs**, the two frozen counts, with the frozen
  3.8% / 1.85% thresholds sitting above the computed floors.
- **Reproducing the handoff's numbers confirms the diagnosis.** Re-running with
  its method -- FP-only gate, 5% effect -- returns 2 -> 5.50%, 6 -> 3.95%,
  10 -> 3.35%, 48 -> 2.00% against its published 5.85 / 4.00 / 3.45 / 1.75. The
  shape matches within seed noise, so the gap is the gate, not the data.
- **Corrected table** (same clean 2026-07-27 unpaced series, real gates):

  | mode | frozen | handoff claim | **actual** |
  | --- | --- | --- | --- |
  | `quick` (5% effect, detect >= 0.80) | 2 pairs @ 3.8% | 10 pairs @ 3.45% | **12 pairs @ 3.25%** (~1.1 min) |
  | `confirm` (3% effect, detect >= 0.90) | 6 pairs @ 1.85% | 48 pairs @ 1.75% | **100 pairs @ 1.65%**, detect 0.93 (~9 min) |

- **48 pairs does not restore `confirm`, and not marginally.** At 48 pairs the
  tightest threshold clearing A/A FP <= 5% is **2.05%**, and there detection at a
  3% effect is **0.71** against the required 0.90, with **29% inconclusive**
  against a 10% cap. The eligible band is empty at every count below 100.
- **The `quick` half of the recommendation survives**, shifted: 12 pairs supports
  3.25%, tighter than the frozen 3.8%, for ~1.1 min. It is 6x the pair count for
  a modestly better threshold.
- **`confirm` at 100 pairs is marginal, not comfortable.** Detection is 0.93
  against a 0.90 floor, on one session's data, where F18 puts session-to-session
  variation at ~2x. A fresh series could easily push it out of eligibility
  entirely. Treat "recalibration restores `confirm`" as **unproven**, not as the
  settled plan.
- **Same-session control is clean**, so this is not a session artifact: the
  `content-churn` arm of the same series has `confirm` eligible at **4 pairs @
  1.45%** and `quick` at **2 pairs @ 1.90%**, both comfortably better than their
  frozen rules.
- **Consequence:** the handoff's headline ("48 pairs recovers 1.75%, slightly
  better than the frozen 1.85% `confirm`") is withdrawn. Recalibration is still
  the cheapest path for `quick`, but it does **not** cheaply restore `confirm`,
  which is the mode that actually decides damage-scoping changes at the 3% effect
  size those changes live at. This materially strengthens the case for the
  headless in-process benchmark (Phase 7) over recalibration alone.

### F21 -- the headless draw benchmark already exists, resolves far below 3%, but only ratio-wise

- **Status:** closed as a scoping result. Phase 7's strategic option is viable and
  much cheaper than assumed, with one hard design constraint.
- **Date:** 2026-07-27. Six runs of the existing headless benchmark; no operator
  idle time and no screen takeover.
- **It does not need to be built.** `TerminalDrawBenchmark` is already an
  executable product of `lib/TerminalCore`, run by `just benchmark-draw`, with
  support in `TerminalDrawBenchmarkSupport`. It already has a **`damage-clipped`
  scenario** clipping to 4 rows (the app's `incremental-mixed` uses 6), alongside
  `full-frame`, across 80x24 and 160x50 grids.
- **It already has the property D1 predicts matters.** `measureDurationStable`
  auto-scales a batch until each sample exceeds 400 ms, then times whole batches.
  The thread is ~100% occupied for the entire sample, so the governor never
  demotes it -- the mechanism behind the whole regression is absent by
  construction.
- **Within-run precision is excellent:** per-draw CV across the 15 samples of a
  run is **0.58-0.85%**, against the GUI benchmark's 17.41% per-draw CV.
- **But raw between-run CV is 2.8-3.6%, which alone would not beat the GUI
  benchmark.** Arms are separate processes, so a comparison sees the between-run
  number, and 3% is exactly the effect size `confirm` must resolve. Measured
  per-draw medians across six runs:

  | cell | between-run CV | within-run CV |
  | --- | --- | --- |
  | 80x24 full-frame | 3.62% | 0.85% |
  | 80x24 damage-clipped | 2.81% | 0.72% |
  | 160x50 full-frame | 3.27% | 0.75% |
  | 160x50 damage-clipped | 3.03% | 0.58% |

- **The drift is common-mode, and that is the whole finding.** Every cell moves
  together run to run -- run 4's four cells scaled 1.0897 / 1.0607 / 1.0689 /
  1.0646, a single ~7% machine-state excursion, not four independent ones.
  Dividing out one scale factor per run drops residual CV to **0.29-0.90%**, and
  an in-run **ratio** does the same without needing to estimate anything:

  | ratio | CV across 6 runs |
  | --- | --- |
  | 160x50 damage-clipped / full-frame | **0.256%** |
  | 160x50 damage-clipped / 80x24 damage-clipped | 0.295% |
  | 160x50 full-frame / 80x24 full-frame | 1.140% |
  | 80x24 damage-clipped / full-frame | 1.357% |

- **Design constraint, and it is not optional:** a headless comparison must be
  **ratio-based within a single process**, or interleave both arms' batches in
  one process. Comparing raw per-draw times across separately launched runs
  inherits the 2.8-3.6% between-run drift and buys nothing. The GUI benchmark
  cannot do this -- its arms are separate app processes -- which is precisely why
  it cannot cancel the same drift.
- **Prefer the large grid.** 160x50 ratios are 4-5x more stable than 80x24
  (0.256% vs 1.357%), consistent with longer batches averaging more work per
  sample. A production headless comparison should not use 80x24.
- **Headroom against a damage-scoping regression is enormous.** The
  damage-clipped/full-frame ratio at 160x50 is **0.0867** -- an 11.5x separation
  measured with 0.256% CV. A regression that failed to narrow the plan would move
  that ratio toward 1.0; even a 3% inflation of the clipped path is ~12 CV away.
- **What it covers, and what it does not.** `clipFramePlan` is called once in
  `PreparedDraw.init`, *outside* the timer, so:
  - **Visible:** regressions in what `clipFramePlan` *produces* (retaining too
    many rows inflates the drawn plan) and in `drawRenderFrame`'s cost.
  - **Invisible:** the cost of `clipFramePlan` itself, which the app's draw timer
    does bracket.
  - **Invisible, and the more important gap:** *damage generation* -- which rows
    get marked dirty via `setNeedsDisplay` and AppKit's dirty-rect coalescing.
    Headless, the damage set is supplied by the harness. "The app dirties too
    much" regressions stay GUI-only, so the GUI benchmark is not retired.
- **Caveat:** six runs over ~4 minutes on one machine. The common-mode factor
  drifted 0.983 -> 1.071 monotonically enough to look like warming, so the drift
  itself is *not* solved -- it is made cancellable. Whether it stays common-mode
  across a longer series, a rebuild, or two separately compiled arms is untested,
  and two-arm interleaving is the specific thing that must be piloted next.

## Decision log

### D1 -- mechanism class: platform CPU frequency demotion of an under-occupied main thread

- **Taken:** 2026-07-27, on F11 + F12 + F13 + F14. **D2 (select the fix) is
  still open** and remains the Phase 4 gate.
- **D1 was reframed before it was taken.** As written it asked for "the commit
  and the mechanism class". F12 showed there is no commit -- the defect grows
  monotonically across four revisions rather than flipping at a boundary -- so
  only the mechanism-class half is answerable, and this decision answers that.

**The decision.** The `incremental-mixed` verdict failures are not caused by any
change to the render path, the planner, the observer, or the schedule. They are
caused by **the CPU lowering the app's clock during a measurement block**,
because the recent optimizations reduced the main thread's duty cycle to ~3.8%
and the governor demotes a thread that idle. The metric is reporting the
processor's power state, not the code's cost.

**Evidence chain, in the order it forced the conclusion:**

1. **F11** -- the widening is a systematic within-block ramp (95/96 blocks,
   +41%), not increased noise. Residual noise shape is unchanged from
   2026-07-24.
2. **F12** -- the ramp grows monotonically across revisions, so no commit caused
   it; something progressive did.
3. **F13** -- the plan timer, on a disjoint code path, ramps by the same 41.2%,
   and ramp is inversely related to duty cycle across every series measured.
4. **F14** -- both timers step in quantized levels at the **same wall-clock
   moments**, four times per block, at regular ~80 ms intervals. Only a governor
   does that.

**What this rules out, and what it means for the code:** the render path is
exonerated. It is measurably *faster* -- first-draw cost fell 181 us -> 139 us
(F11) and `content-churn` improved uniformly by ~5% (F10). Every optimization in
the window (`df80150`, `8188b9a`, `4061096`) was correct and is kept. Their only
fault is that they made the app efficient enough to fall below the governor's
occupancy threshold, which is a property of the *benchmark's* workload shape, not
of the product.

**What this obliges:** the fix is in the harness, and it must make a block's
measurement occur at a stable clock. This is a confound removed, not hidden, so
it satisfies the investigation rules. Recalibration follows the fix, never
precedes it.

**Reopen if:** the intervention selected at D2 fails to flatten the ramp. That
would mean F14's synchronized quantized steps have some other cause, and H5
revives.

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

**Still rejected, and now explained.** F11 gives the positive account the
rejection lacked: the distribution is neither one mode nor two, it is a mixture
along a within-block ramp. A monotonic drift produces exactly the wide,
single-peaked, right-skewed shape F9 measured.

### R10 -- a removed uniform per-frame cost widened the distribution (F9's inference)

F9 observed that the `incremental-mixed` block floor fell ~8% while the tail
grew, and inferred that a per-frame cost had been acting as a regularizer --
setting a floor under every draw and compressing the distribution around it.
That inference made H3/H5 the leading hypotheses and made the block floor the
prescribed bisect readout.

Rejected by **F10**: the floor fell in `content-churn` too (-4.2%), where the
distribution got *tighter* rather than wider and where every variance statistic
stayed clean. A floor drop that coincides with reduced variance in the control
cannot be the cause of increased variance in the subject. F9 measured one series
and fused two independent phenomena -- a benign general speedup and the actual
defect -- into one mechanism.

The F9 *measurements* stand and are still cited; only its inference and its
"read the block floor" instruction are withdrawn. The replacement readout is the
within-block ramp (F11).

**Kept as a caution about controls:** F9 was careful, quantitative, and wrong
because it skipped a control the investigation rules already required. The rule
"cross-revision variance comparisons require a same-session control" was written
for machine drift; it applies just as much to any statistic read off one series.

## Open questions and caveats

- **There is no exact commit** (F12). The question "which commit" is retired;
  "which mechanism" is open and H6 is the leading answer.
- **H6 is confirmed (F14, D1), but on one machine and one macOS version.** The
  mechanism is generic to Apple silicon power management, so it should reproduce
  elsewhere -- but the specific numbers this file relies on (the ~80 ms step
  period, the 61 ms first step, the ~20% occupancy threshold, the 1.446x
  excursion) are machine-specific and must not be treated as constants. Candidate
  B depends on the 61 ms figure directly.
- **The within-revision test had no power, and this is worth knowing.** Trying to
  break the duty-cycle / revision-recency collinearity by correlating ramp
  against inter-draw gap *across blocks of one revision* failed: the gap is fixed
  by the workload's feed rate and varies only ~2% (8665 vs 8848 us), so there is
  no leverage. Do not retry it. Note also that the apparent r(ramp, duty) = +0.71
  at `HEAD` is **circular** -- duty is computed from cumulative draw+plan time, so
  a steeper ramp mechanically raises it. What actually settled the question was
  F14's step-timing, not any correlation.
- **The residual between-block SD is unexplained.** De-ramping moves it only
  4.65% -> 4.25% (F11), and `between-block SD` is the quantity that drives paired
  verdicts (F4). Flattening the ramp may not on its own restore the thresholds.
- **The harness records no per-draw CPU state.** `machineStateSamples` carries
  start and completion entries only, so frequency and core class over a block are
  unobserved. That is why H6 needs an intervention rather than a measurement.
  Thermal throttling and Low Power Mode *are* excluded -- both samples report
  `thermalState: nominal`, `lowPowerMode: false` in every block.
- **The 2026-07-24 reference has no plan metric** (it predates `b7f5c12`), so
  F13's duty-cycle column cannot be computed for the clean series. The pre-`b7f5c12`
  duty cycle is inferred from the `b7f5c12` commit message (~1.15M ns planning
  per frame, plus the observer at 18-22% of the main thread) to have been far
  higher than today's 3.8%, but it is **not measured**.
- **`style-churn` was never collected at `HEAD`** as a second same-session
  control. F3 rests on one control workload; F10 and F12 add `style-churn` only
  at 2026-07-24 and `8188b9a`, where it is flat.
- **Where the ramp first appears is unmeasured.** Nothing between `b7f5c12` and
  `b834a44` was probed. Under H6 this question has no useful answer, but it
  becomes live again if H6 is refuted.
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
- **Phase 2 is complete in the only sense available.** The bisect is **retired,
  not finished**: F12 measures the defect at four revisions and finds it grows
  monotonically (0% -> 10.8% -> 25.2% -> 37.0% -> 41.1%) rather than flipping at
  a boundary. There is no commit to name. What replaced the bisect is a
  mechanism, and D1 was reframed to ask for that instead -- and then taken.
- **Phase 3 is complete, and cost no machine time.** F10 through F14 were all
  derived from series already on disk:
  - **F11 names the defect.** `incremental-mixed` draws get ~41% slower from a
    block's first draw to its last, in 95 of 96 blocks, at constant 6-row
    damage; the clean series is flat (3/96). The "4x noisier distribution" is
    not noise -- it is a systematic within-block ramp read as spread.
  - **F13 names the mechanism.** The plan timer, bracketing disjoint work on an
    unrelated code path, ramps by the *same* 41%. No algorithmic change can do
    that; a slowing processor can. Ramp is monotonically inverse to main-thread
    duty cycle across every series measured -- flat above ~20% occupancy, severe
    below ~4%.
  - **F10 corrects F9** and withdraws its readout (R10): the block floor also
    dropped in the clean `content-churn` control, so it is a benign speedup, not
    the defect.
  - **F14 confirms the mechanism and closes D1.** The ramp is a quantized
    staircase: a 5-level step model fits the per-ordinal medians at R^2 = 0.979
    against 0.922 for a linear fit, with steps every ~80 ms. Decisively, the
    draw and plan timers step at the **same wall-clock moments** -- breaks at
    61/140/236/314 ms and 70/148/227/323 ms, agreeing to within one 8.7 ms
    inter-draw interval. Only a CPU frequency governor makes two unrelated code
    paths change speed simultaneously in quantized steps.
- **The answer inverted.** The render path is not regressed -- it is faster
  (first draw 181 us -> 139 us; `content-churn` improved ~5% uniformly). Every
  optimization in the window was correct and is kept. Their only fault is that
  they made the app efficient enough to drop below the governor's occupancy
  threshold. The harness is measuring the CPU's power state, so the repair
  belongs there, and it removes a confound rather than hiding one.
- **Phase 4 has no live candidate.** F15 prototyped eleven estimators and F16
  decomposed the variance, refuting three of the four fix candidates. F17 then built the last survivor -- the
  pacer -- and measured it against a same-session unpaced control: it flattened
  the ramp as designed and **tripled block-level CV**. **D2 is unmade.** The
  pacer is uncommitted, gated off by default, and refuted.

**The search is reframed, not stalled.** D1's mechanism stands: F14's
synchronized quantized staircase is not in doubt. But two independent routes --
F15 (the ramp cancels in pairing) and F17 (removing it in collection hurts) --
agree that **the ramp is a symptom, not the driver.** The quantity that breaks
verdicts is block-to-block *level* variation (F16), and nothing tried moves it.

**Recalibration was expected to route around that, and F20 shows it only half
does.** Screened under each mode's real gates rather than an A/A false-positive
rate alone, `quick` recovers cheaply -- 12 pairs supports 3.25%, tighter than the
frozen 3.8%, for ~1.1 min. **`confirm` does not.** Its 3%-effect /
detection >= 0.90 gate admits nothing below 100 pairs, and even there detection
is 0.93 against a 0.90 floor on one session's data. Recalibration still buys
precision with time rather than widening a threshold, so it satisfies the "no
hacks" rule -- but it does not deliver a usable `confirm`, and `confirm` is the
mode that decides damage-scoping changes at the effect size those changes live
at.

That leaves the instrument **partially recoverable**: usable for coarse 5%
screening, still unable to adjudicate a 3% change on `incremental-mixed`. Finding
what sets a block's level remains the open scientific question. With
recalibration now shown insufficient for `confirm`, the headless in-process draw
benchmark is no longer merely the strategic fallback -- it is the only identified
route back to a 3%-capable verdict on this workload.

**F21 then showed that route is short.** The headless benchmark already exists,
already has a damage-clipped scenario, and already runs at the ~100% occupancy
that makes D1's mechanism inapplicable. Measured, it resolves **0.256%**
ratio-wise -- an order of magnitude below the 3% `confirm` needs, against a
regression signal with 11.5x of headroom. The catch is structural rather than
mechanical: its between-run drift is as bad as the GUI benchmark's, and only
cancels because a ratio taken inside one process cancels it. So the remaining
work is not "make the measurement quieter" but "get both arms into one process",
and the open risk is whether two separately compiled arms stay common-mode.

That leaves a coherent division of labour to confirm: the headless benchmark
adjudicates the cost of drawing a scoped plan at 3% and below, and the GUI
benchmark keeps the part headless cannot see -- whether the app marks the right
rows dirty in the first place.

## Scratch

**Ephemeral. Any agent may wipe this section, and a handoff should**, since
scratch goes stale faster than anything else here. Nothing below is load-bearing:
if a finding depends on it, that finding is under-documented -- promote the
material to [Reproduction recipes](#reproduction-recipes) and delete it here.

It exists because the alternative is worse. A private session scratchpad
disappears at handoff, taking with it the drivers behind published numbers; F20
is the case in point. Working material is cheaper to carry here and throw away
than to reconstruct.

Keep entries dated and attributed to the finding they served, so a later reader
can tell live scaffolding from residue.

### F20 driver -- pair-count screen under the real per-mode gates (2026-07-27)

Superseded in spirit by the recipe in
[Screening pair counts against the real gates](#screening-pair-counts-against-the-real-gates-f20s-readout),
which carries the method and the validation requirement. This is the exact
runnable form, kept only until someone needs the shape again.

Usage: `python3 <file>.py <blocks.json> [workload] [trials]`. Validate against
the 2026-07-24 reference before trusting a run: it must reproduce `quick` first
eligible at 2 pairs and `confirm` at 6.

```python
#!/usr/bin/env python3
"""Re-derive the Phase 6 pair-count/threshold table using the REPO's calibration
machinery instead of the prior session's ad-hoc bootstrap.

Loads a single-arm blocks.json (ABBA quartets, both slots bound to one root) into
the same quartet-of-two-paired-differences form load_quartets() produces from a
production JSONL series, then runs calibrate_threshold_grid at each pair count.
"""
import importlib.util
import json
import pathlib
import sys

ROOT = pathlib.Path("/Users/dan/Code/danterm-terminal-engine")
spec = importlib.util.spec_from_file_location(
    "cal", ROOT / "scripts/terminal-benchmark-calibration.py")
CAL = importlib.util.module_from_spec(spec)
spec.loader.exec_module(CAL)

PAIR_COUNTS = (2, 4, 6, 8, 12, 16, 24, 32, 40, 48, 64, 80, 100)


def load_single_arm_quartets(path, workload):
    """Mirror load_quartets() exactly, over the single-arm blocks.json shape."""
    data = json.load(open(path))[workload]
    quartets = []
    for group in data:
        if len(group) != 4:
            raise ValueError("incomplete quartet")
        if sorted(b["measurementRole"] for b in group) != ["A", "A", "B", "B"]:
            raise ValueError("quartet is not two A and two B")
        differences = []
        for first, second in zip(group[::2], group[1::2]):
            if first["measurementRole"] == second["measurementRole"]:
                raise ValueError("adjacent pair shares a role")
            values = {}
            for row in (first, second):
                draw = row["artifact"]["finalDraw"]
                values[row["measurementRole"]] = (
                    draw["cumulativeDrawNanoseconds"] / draw["drawCount"])
            differences.append(CAL.symmetric_difference(values["A"], values["B"]))
        quartets.append(differences)
    return quartets


# Same gates the frozen median-fallback screen applies.
MODES = {
    "quick": dict(effect=5, band=1.0, detect=0.80, nondir=0.20, wrong=0.05,
                  grid=tuple(round(1.05 + 0.05 * i, 2) for i in range(70))),
    "confirm": dict(effect=3, band=0.75, detect=0.90, nondir=0.10, wrong=0.05,
                    grid=tuple(round(0.80 + 0.05 * i, 2) for i in range(35))),
}


def eligible(report, rule):
    effects = (report["conditions"]["positive"], report["conditions"]["negative"])
    return (report["conditions"]["aa"]["falsePositiveRate"] <= 0.05
            and all(c["detectionRate"] >= rule["detect"]
                    and c["inconclusiveRate"] <= rule["nondir"]
                    and c["wrongDirectionRate"] <= rule["wrong"]
                    for c in effects))


def screen(quartets, mode, trials, seed_base, seconds_per_pair):
    rule = MODES[mode]
    rows = []
    for index, count in enumerate(PAIR_COUNTS):
        reports = CAL.calibrate_threshold_grid(
            quartets, pair_count=count, effect_percent=rule["effect"],
            directional_thresholds=rule["grid"], equivalence_band=rule["band"],
            trial_count=trials, seed=seed_base + index, estimator="median")
        ok = [r for r in reports if eligible(r, rule)]
        if not ok:
            rows.append((count, None, None, None))
            continue
        best = min(ok, key=lambda r: (r["directionalThresholdPercent"],
                                      r["conditions"]["aa"]["falsePositiveRate"]))
        rows.append((count, best["directionalThresholdPercent"],
                     best["conditions"]["positive"]["detectionRate"],
                     count * seconds_per_pair))
    return rows


if __name__ == "__main__":
    path = sys.argv[1]
    workload = sys.argv[2] if len(sys.argv) > 2 else "incremental-mixed"
    trials = int(sys.argv[3]) if len(sys.argv) > 3 else 4000
    quartets = load_single_arm_quartets(path, workload)
    flat = [v for q in quartets for v in q]
    import statistics as st
    print(f"source: {path}")
    print(f"workload: {workload}  quartets={len(quartets)} pairs={len(flat)}")
    print(f"paired SD = {st.pstdev(flat):.2f}%   median |diff| = "
          f"{st.median(abs(v) for v in flat):.2f}%")
    # Per-block seconds observed this session; used only for the wall-clock column.
    seconds_per_pair = 2 * 2.7
    for mode in ("quick", "confirm"):
        print(f"\n== {mode} (effect {MODES[mode]['effect']}%, "
              f"detect>={MODES[mode]['detect']}, A/A FP<=5%) ==")
        print(f"{'pairs':>6} {'min threshold':>14} {'detect':>8} {'wall (min)':>11}")
        # Fixed per-mode seed offset: hash() on a str is randomized per process,
        # so using it here would make the screen unreproducible run to run.
        for count, threshold, detect, wall in screen(
                quartets, mode, trials,
                90_000 + (0 if mode == "quick" else 10_000), seconds_per_pair):
            if threshold is None:
                print(f"{count:>6} {'-- none eligible':>14}")
            else:
                print(f"{count:>6} {threshold:>13.2f}% {detect:>8.2f} "
                      f"{wall/60:>11.1f}")
```

### F21 raw pilot -- headless draw benchmark, six runs (2026-07-27)

Runs preserved at `~/danterm-benchmark-evidence/2026-07-27/headless-draw-pilot/`
(`draw-run-1..6.json`). Regenerate with the release binary, not `swift run`:

```sh
BIN=$(swift build --package-path lib/TerminalCore -c release \
  --product TerminalDrawBenchmark --show-bin-path)/TerminalDrawBenchmark
for i in 1 2 3 4 5 6; do "$BIN" 15 > draw-run-$i.json; done
```

Per-draw medians (us). The point is the *columns moving together*, which is what
makes an in-run ratio work:

| run | 80x24 full | 80x24 clipped | 160x50 full | 160x50 clipped | scale |
| --- | --- | --- | --- | --- | --- |
| 1 | 3605.5 | 714.7 | 15182.6 | 1316.4 | 0.987 |
| 2 | 3593.9 | 713.5 | 15075.2 | 1311.2 | 0.983 |
| 3 | 3627.6 | 713.7 | 15215.9 | 1319.1 | 0.989 |
| 4 | 3952.3 | 769.0 | 16501.7 | 1424.0 | **1.071** |
| 5 | 3626.1 | 735.3 | 15659.8 | 1356.2 | 1.011 |
| 6 | 3816.8 | 745.4 | 15988.3 | 1381.4 | 1.037 |

Analysis: divide each cell by its column median to get a per-run scale factor,
then take ratios within a run. Residual CV after removing the scale factor is
0.29-0.90%; the 160x50 clipped/full ratio is 0.256% without removing anything.
