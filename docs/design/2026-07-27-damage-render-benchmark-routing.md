# 2026-07-27: Benchmark Routing for Damage-Scoped Render Changes

- Status: Accepted
- Date: 2026-07-27

## Context

DanTerm decides render-path performance changes with a paired A/B benchmark
(`just benchmark-quick` / `just benchmark-confirm`) across the calibrated
workload ladder. One of
them, `incremental-mixed`, is the only workload that measures
damage-*proportional* work, so it is the only instrument that can catch a
regression in damage scoping -- the optimization area the Swift engine's render
path is actively built around.

That workload broke. Its paired standard deviation moved from **1.49%** to
**6.26%**, and the harness began returning false directional verdicts at roughly
**40%** on A/A controls, where both arms carry byte-identical code. A benchmark
that reports "slower" on identical code cannot adjudicate anything. Because the
frozen decision thresholds were calibrated against the clean distribution, every
damage-scoping change was effectively undecidable.

The full investigation is
[docs/research/8-benchmark-variance-regression.md](../research/8-benchmark-variance-regression.md).
This note records the two decisions that came out of it, because a decision that
lives only in a research doc cannot be found by someone changing the render path
a year from now.

## The mechanism (D1)

`incremental-mixed` draws do not vary randomly. They get **26-41% slower from a
block's first draw to its last**, in ~95 of 96 blocks. The cause is **macOS
lowering the app's main-thread CPU clock during the block**: recent render
optimizations left the main thread ~96% idle, and the platform governor demotes a
thread that idle.

The render path is **not** regressed. It is measurably faster. The benchmark got
noisier *because* the code got faster, which is why the noise appeared without
any commit that could be blamed for it -- it grows monotonically across four
revisions rather than appearing at one.

The confirming evidence is that the slowdown is a **quantized staircase whose
steps land at the same wall-clock moments in two disjoint timers** (the draw
timer and the plan timer), roughly 80 ms apart. Only a frequency governor
produces that signature. macOS exposes no userspace floor for it: neither
frequency pinning nor core affinity is available to an unprivileged app.

Two traps here cost the investigation the most time, and both are worth carrying
forward:

- **The within-block ramp is a symptom, not the driver.** It cancels in pairing.
  Removing it does not help -- proven twice, once by re-analysis over eleven
  estimators and once by building the fix and measuring it, where flattening the
  ramp *tripled* the variance. The quantity that actually breaks verdicts is
  block-to-block **level** variation. Justify any future idea against block-level
  CV, never against the ramp.
- **A/A precision does not transfer to a revision pair.** An A/A control cannot
  see any bias that requires the two arms to hold different code, and when a
  positive control was finally run it exposed two such biases that every prior
  A/A had passed.

## Decision (D2)

**Do not repair the GUI benchmark's `incremental-mixed` variance. Route around
it.**

Four collection-side repairs were designed and refuted, the last one by building
it and measuring it. Since the mechanism is a platform governor with no userspace
control surface, damage-*drawing* regression detection moves to a **headless
in-process paired comparison**, `just benchmark-headless-draw`, which sidesteps
the mechanism by construction: it batches work past a 400 ms floor so the thread
stays near 100% occupied and the governor never demotes it.

This is not a retreat to an unmeasured instrument. The headless route was
characterized before it was adopted: the paired spread was established across
independently compiled arms, code-layout bias was bounded below ~0.21%, a
positive control on a genuinely different revision found and fixed two order
biases, and both remaining error floors were measured rather than asserted.
**Honest resolution on a real revision pair is ~0.5-1%**, against the 3% question
`confirm` was built to answer and no longer delivers.

**The recalibration of `confirm` is declined, not deferred.** Recovering it on
the degraded distribution costs ~100 pairs and ~9 minutes to land marginally over
its detection floor on a single session's data, which is not worth buying once
the 3% question has a better instrument.

## Consequences

### The coverage split, which is the load-bearing part

| question | instrument | state |
| --- | --- | --- |
| damage *drawing* -- cost of `drawRenderFrame` with a row restriction, including row selection | `just benchmark-headless-draw` | healthy, ~0.5-1% on a revision pair; baseline reset 2026-08-20 when row selection moved inside the bracket |
| damage *generation* -- which rows `setNeedsDisplay` and AppKit's dirty-rect coalescing mark | `just benchmark-quick` on `incremental-mixed` | **degraded, and staying that way** |
| published-frame work outside `drawRenderFrame` | `just benchmark-quick` on `incremental-mixed` | **degraded, and staying that way** |

The 2026-08-20 row-indexed frame-plan change deleted `clipFramePlan`. Its
damage-clipped arm now retains the full plan and passes the damaged row set into
the timed draw. Results before and after that change are not comparable because
the bracket now includes O(damaged rows) selection that previously ran before it.

**This decision accepts a coverage gap; it does not close one.** A change that
alters which rows get marked dirty has no healthy directional instrument. Since
the post-T25 recalibration (`research/33/F28`), `incremental-mixed` runs its
blocks but issues no verdict. Use its topology and percentage descriptively,
pair mechanism claims with direct structural evidence, and route drawing cost
to the headless comparison.

### Constraints any user of the headless comparison inherits

- **The two arms must compile under distinct Swift module names.** Swift classes
  register with the ObjC runtime, which dedups by name across images *even under
  `RTLD_LOCAL`*. A collision makes both arms run one arm's code while still
  printing plausible numbers. A guard enforces this; do not route around it.
- **Each checkout must keep the exact `TerminalCore` directory basename**, since
  SwiftPM derives a path dependency's identity from it.
- **Read `orderBiasPercent` before believing `realEffectPercent`.** A residual
  systematic order bias of +0.30% is real but slot-bound, so counterbalancing
  removes it from the claimable number -- but only if the run is counterbalanced.
- **An A/A control near zero is a red gate, not a formality.** It is the check
  that catches a broken module-name or basename guard.
- **No threshold is frozen for this instrument.** `--threshold` is caller-supplied
  and labelled as such in the report. Freezing one requires a screening pass a
  human signs off.

### Rules that remain in force

- **No hacks.** Widening a threshold, adding retries to the comparison path,
  dropping a warm-up block, or excluding outliers were all rejected a priori and
  remain rejected. The calibration path may retry whole quartets; the comparison
  path may not.
- **No performance claim from an A/A series.** Those are variance measurements.

## Reopen if

- A change needs a verdict on damage *generation* at better than
  `benchmark-quick`'s degraded resolution.
- The governor's behavior changes under a future macOS release -- in which case
  the mechanism (D1) should be re-measured before any repair is attempted, since
  every refuted candidate was refuted against the current behavior.

## References

- [docs/research/8-benchmark-variance-regression.md](../research/8-benchmark-variance-regression.md)
  -- the investigation: D1 and D2 in its decision log, the refuted candidates in
  its rejected list, and the findings behind every number quoted here.
- [agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md)
  -- the user-facing contract for `just benchmark-headless-draw`, including what
  it cannot see.
- `scripts/terminal-headless-draw-compare.py`, `scripts/terminal-headless-draw-arm.swift`
  -- the instrument.
- `scripts/terminal-benchmark-median-fallback.py` -- the screening machinery whose
  threshold grids reach 0.30%, low enough to express what this instrument
  resolves.
