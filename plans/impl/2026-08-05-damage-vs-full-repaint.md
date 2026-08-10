# Is damage-scoped drawing slower than full repainting?

Status: answered 2026-08-05 -- no, it is 2.2x faster at 4-of-66 rows damaged,
and the margin is not close. See `## Outcome`. Design and frozen rules were
written before any number in this file was read; findings are appended in the
order they were taken.

## The question

`SwiftTerminalSessionView.draw(_:)` never repaints the whole pane when it can
avoid it. It carries exact engine row damage across publishes
(`pendingDisplayDamage`), coalesces it into maximal contiguous spans, clips the
CGContext to those spans, and filters the `RenderFramePlan` down to the damaged
rows before drawing. Each of those steps costs something. The question is
whether the total bill is smaller than just drawing every row into the whole
rect, every frame.

This is not idle: the *first* shipped version of exact sparse damage lost this
bet by a factor of two, and it took a controlled three-arm profile to find it.

## What is already settled, and why it does not answer this

[`docs/research/29-sparse-appkit-damage-clip-topology/`](../research/29-sparse-appkit-damage-clip-topology/README.md)
and [`30-cg-clip-construction-mechanics/`](../research/30-cg-clip-construction-mechanics/README.md)
own the topology and the clip construction. Their results:

| Arm | btop 179x66, whole-process CPU |
| --- | ---: |
| `d378096^` -- bounding-box dirtyRect, plan clipped to the bbox rows | 24.17% |
| `d378096` -- exact sparse damage, one CGRect per damaged row | 44.10% |
| `f3c774d` -- exact sparse damage, maximal contiguous spans | 22.94% |

So the damage machinery *has* already been measured slower than a coarser
alternative once, and the mechanism was named: Core Animation compound clip
construction (`CA::CG::ClipOp::ClipOp`, `ClipPath::prepare`,
`CA::Shape::new_shape`) grew faster than DanTerm's own draw work shrank.
29/`H3` then rejected a complexity fallback because coalescing was no slower
than the bbox parent even at the worst topology reachable at 66 rows (17 spans,
50 damaged rows).

**But none of those three arms is a full-repaint arm.** `d378096^` already
derived rows from AppKit's dirty rect and already called `clipFramePlan`:

```swift
// d378096^:app/SwiftTerminalSessionView.swift, draw(_:)
let rows = terminalRows(intersecting: dirtyRect, metrics: ..., rowCount: ...)
let plan = rows == 0..<frame.plan.rows
    ? frame.plan
    : clipFramePlan(frame.plan, to: TerminalDamage(rows: Set(rows)))
context.clip(to: dirtyRect)
```

Every measured arm scopes the plan by rows. The comparison was always
*which damage representation*, never *damage or none*. That leaves the actual
question open.

## Where damage-scoped drawing could still lose today

Three surfaces, in decreasing confidence that they matter:

1. **`clipFramePlan` at a high damage fraction.** It runs five whole-array
   `.filter`s with a `Set<Int>.contains` per run and allocates five new arrays
   (`RenderFramePlanner.swift:32-37`). At 60-of-66 damaged rows that is a
   near-full copy of the plan on top of near-full drawing. The old bbox path
   would have widened to the full frame and skipped the filters entirely
   (`rows == 0..<plan.rows` short-circuit above); the current path cannot,
   because sparse rows never widen. Doc 29's endpoints all had both arms
   clipping, so this term was never isolated.
2. **Span count scales with grid height.** Under the one-row glyph halo the
   worst case is about `ceil(rows / 4)` spans. Only 179x66 is calibrated. A
   130-row window doubles the CA clip work while the per-row drawing saving
   stays proportional.
3. **Per-row `setNeedsDisplay`.** `publish(_:)` posts one rect per damaged row,
   not per span, and AppKit then reduces them to one union rectangle anyway --
   which is the documented reason `pendingDisplayDamage` exists at all
   (`SwiftTerminalSessionView.swift:39`). So the region ops are paid and the
   result is discarded.

And one cost that is not CPU at all: doc 32 (`post-resize-repaint-loss`) is open
right now, and it is a correctness bill this machinery is uniquely able to
incur. Full repainting cannot leave a row unpainted.

## Bound on the prize

Whatever the damage machinery costs, it can only ever save the drawing it
skips. So the first thing to measure is not the cost -- it is the prize. If
clipping a 66-row frame down to 4 rows saves less than the machinery plausibly
costs, the rest of the ladder is unnecessary.

## Arms

| Arm | Change |
| --- | --- |
| `A` -- shipped | current tree, unmodified |
| `B1` -- unscoped draw | `drawingDamage(fallback:metrics:rowCount:)` returns `.full` unconditionally. No `clipFramePlan`, no span clip: the whole plan is drawn, clipped only by AppKit's dirty rect. `publish(_:)`'s per-row `setNeedsDisplay` is untouched. |
| `B2` -- full invalidation | `B1` plus `publish(_:)` calling `invalidateFullDisplay()` every frame, so the layer's dirty region is the whole pane |

Both keep the engine's damage tracking -- the terminal still computes which rows
changed, which feeds retained-row reuse in the planner, a separate
optimization. They remove only the *view-side* consumption.

**Why the arm is split, decided before rung 2 ran and before any rung-2 number
was read.** `B2` is the arm this doc set out to build, and it cannot be measured
on the calibrated ladder: `collect_incremental_mixed`
(`scripts/terminal-benchmark-validation.py`) requires `dirtyRowCounts == 6` on
all 50 draws, and `B2` reports 66, so every block fails `wrong-damage-row-count`
and the invocation is invalid rather than slow. That is the gate working -- the
workload's identity is `...-v2-four-rows-six-damage-179x66`, and an arm that
dirties the whole pane is no longer running that workload.

So rung 2 measures `B1`, which answers the narrower question: **given that
AppKit has already scoped the dirty rect, does scoping the plan and the clip on
top of it pay for itself?** Note the bias this introduces, in `B1`'s favour:
`B1` still gets the rasterization saving for free, because its `[dirtyRect]`
clip discards the ink of the 60 rows it needlessly drew. So `B1` pays only for
issuing the drawing commands, not for rasterizing them. A `slower` verdict for
`B1` is therefore strong evidence for scoping; a `faster` one is weak evidence
against it, and would need `B2` on rung 4 to mean anything.

`B2` is answerable only on rung 4, whose btop stimulus grades damage submission
but imposes no topology contract -- and which issues no verdict, only
attribution.

Both arms fail `just test-ui`, which pins exact drawn-row sets. That is expected
and is not a signal about either arm.

## Frozen decision rules

Frozen 2026-08-05 before the first measurement, per
[measurement-discipline](../../agent-docs/measurement-discipline.md).

- **R1 (prize).** If the headless clipped-vs-full draw ratio at 4-of-66 damaged
  rows is below 2x, stop: the machinery cannot be paying for itself and `B`
  ships. At or above 2x, continue.
- **R2 (primary).** `A` ships unless the unscoped arm is `faster` on
  `incremental-mixed` under `just benchmark-quick` with no `slower` verdict on
  any other workload. A `slower` or `equivalent` verdict keeps `A`.
- **R3 (CA veto).** Because the draw verdict is blind to Core Animation replay
  (about 1/23 of an `incremental-mixed` frame is inside the draw bracket), an
  `equivalent` R2 result does *not* clear the unscoped arm. It escalates to a
  controlled whole-process CPU comparison on the btop stimulus, read the way
  29/`F5` read it: separated medians across eight foreground-verified batches
  per arm, or no claim.

R2 and R3 were frozen against a single arm `B`. Splitting it into `B1`/`B2`
(above) does not restate them: they are read against `B1` on rung 2, and `B1`'s
one-sided bias is what decides how much a given verdict is worth.
- **R4 (scope).** Any verdict claimed here is claimed at 179x66 only. The
  height-scaling exposure (`ceil(rows/4)`) is a separate calibration and does
  not inherit this one's result.

## Instrument ladder

| Rung | Command | Decides | Blind to |
| --- | --- | --- | --- |
| 1 | `scripts/damage-prize-sweep.py` (new, see below) | The prize: ns/draw for a plan clipped to N rows vs the full frame, interleaved in one process | Damage generation, `clipFramePlan`, CGContext clip setup, CA replay -- it times drawing an already-scoped plan only |
| 2 | `just benchmark-quick baseline=<rev> workload=incremental-mixed` | R2. The calibrated main-thread draw bracket, plus uncalibrated plan-time and process-CPU lines | CA replay (wrong thread); cannot carry a verdict on process CPU |
| 3 | `just benchmark-confirm baseline=<rev>` | R2's no-`slower`-anywhere half | same |
| 4 | `just benchmark-sample btop-scroll 20` + controlled `top` batches | R3 | Nothing relevant, but issues no verdict and is not comparable across sessions -- attribution plus hand-read separated medians only |

Rung 1 exists because `terminal-headless-draw-compare.py`'s axis is two
*checkouts* at one scenario; it cannot compare two scenarios on one checkout.
The new script reuses that file's arm builder, ctypes loader, ABBA schedule and
400 ms occupancy floor, and varies `clipRows` instead of the checkout.

Preconditions for rungs 2-4 (from
[terminal-performance](../../agent-docs/terminal-performance.md)): 179x66,
visible unoccluded window, AC power, no thermal pressure, machine otherwise
idle. One invalid block invalidates the whole invocation.

## Findings

### F1 -- the instrument's own control

`python3 scripts/damage-prize-sweep.py --control --rounds 8`, both arms
full-frame, 179x66 btop-shaped, MacBookPro18,1 on AC power, working tree at
`8991f26a` plus this doc and the new script (neither reaches `lib/TerminalCore`,
which is what the arms build from).

| | value |
| --- | ---: |
| Median ratio | 0.985 |
| Range | 0.948 -- 1.040 |
| SD | 2.2% |

The arms are interchangeable, so a ratio can be read. But 2.2% SD is three
times the paired comparator's ~0.7%, because this script reads a raw adjacent
ratio rather than the quartet's symmetric-difference estimator. **This
instrument resolves a 2x claim comfortably and a 10% claim not at all.** Any
sweep row landing within roughly 0.95--1.04 is "no difference measured here",
not "no difference".

### F2 -- the prize is large, linear in damaged rows, and negative at full damage

`python3 scripts/damage-prize-sweep.py --clip-rows 4 8 16 33 50 66 --rounds 8`,
same session and conditions as F1.

| Damaged rows | Fraction | Full-frame | Clipped | Ratio | Ratio range |
| ---: | ---: | ---: | ---: | ---: | --- |
| 4 | 6% | 15.003 ms | 1.015 ms | **14.76x** | 14.29 -- 15.29 |
| 8 | 12% | 14.855 ms | 1.940 ms | 7.70x | 7.34 -- 7.88 |
| 16 | 24% | 14.977 ms | 3.824 ms | 3.89x | 3.81 -- 4.00 |
| 33 | 50% | 14.814 ms | 7.811 ms | 1.88x | 1.85 -- 1.97 |
| 50 | 76% | 14.924 ms | 12.090 ms | 1.23x | 1.21 -- 1.28 |
| 66 | 100% | 14.764 ms | 15.962 ms | 0.93x | 0.90 -- 0.96 |

Three readings.

**The prize is real and it is enormous at the damage sizes that dominate.** Draw
cost is very nearly proportional to damaged rows -- about 0.23 ms per row, with
the full-frame arm reproducing 14.76--15.00 ms across six independent
preparations. **R1 is cleared with two orders of magnitude to spare** (14.76x
against a 2x floor), so the ladder continues.

**The clip is not free, and at 100% damage it is a net loss.** The 66-row row
costs 8% more clipped than unclipped, with a range (0.90--0.96) that sits below
the control's median but overlaps its lower half. So the honest claim is
*clipping every row is no faster than not clipping, and probably slightly
slower* -- not a measured 8% penalty. Two caveats sharpen this rather than
dismiss it: the arm builds its clip as one CGRect **per row**, which for 66
contiguous rows is the uncoalesced topology 29/`F3` found pathological rather
than the app's single span, and clip *construction* sits outside the timed
region, so what is measured is only rasterizing under an already-built clip.

**The crossover is between 76% and 100% damage.** Below it, clipping wins; the
question is only what the machinery costs. This bounds surface 1 from the list
above: `clipFramePlan`'s five whole-array filters buy nothing once damage
approaches full, and the shipped code has no widen-to-full short-circuit the way
the bbox parent did.

### F3 -- what these milliseconds are, and are not

15 ms for a full-frame draw is ~27x the `content-churn` draw bracket's ~540k ns
(`17/F12`). That is not a contradiction: this arm rasterizes into a
`CGBitmapContext` immediately, while the app's `draw(_:)` writes into a
Core Animation display-list recorder and rasterization happens later on the
`CA::CG::Queue` thread. The 2026-08-04 scroll sample shows both halves
separately -- `draw(_:)` at 2,640 main-thread samples, `CABackingStoreUpdate ->
DisplayList::executeEntries` at 952, and a `CA::CG::Queue` thread at 3,253.

So the F2 table cannot be added to, subtracted from, or compared against the
GUI draw verdict. **What it does describe is rasterization work -- which in the
app lands mostly off the main thread, in exactly the region 29's regression
lived in and exactly the region the calibrated draw verdict is blind to.** That
makes it the right proxy for the prize on the CA side, and the wrong number for
any main-thread claim.

### F4 -- unscoped drawing is 2.2x slower on the calibrated ladder

`just benchmark-quick baseline=69cb87c7 workload=incremental-mixed`, arm `B1`
against the shipped tree.

```
incremental-mixed: slower (+121.27% symmetric median of 2 pairs)
  plan time:   -0.94% (descriptive, no verdict -- uncalibrated)
  process CPU: +6.96% (descriptive, no verdict -- uncalibrated)
```

- baseline tree `ee1f720d201d` (commit `69cb87c7`), candidate tree `ad122ab125f3`
- artifacts: `.build/terminal-benchmark-comparisons/quick/ad122ab125f3-0000`
- host: load 0.27/processor at invocation, busiest external process 34.6%
  (the agent session itself). Reported by the instrument, no threshold applied;
  both arms are interleaved under the same conditions and the effect is two
  orders of magnitude above any plausible drift.

**R2 is satisfied in the direction that keeps `A`.** The rule required `faster`
to displace the shipped path; the measurement is `slower`, so R3's Core
Animation veto is never reached and no further rung is needed to settle the
question as posed.

The strength of this is in `B1`'s bias. `B1` was constructed one-sided in its
own favour -- it keeps the rasterization saving for free, because its
`[dirtyRect]` clip discards the ink of the 60 rows it needlessly drew, so it
pays only to *issue* the drawing commands, never to rasterize them. It was still
2.2x slower. Removing that advantage can only widen the gap.

Two smaller readings, neither carrying a verdict. Plan time moved -0.94%, which
is the expected null: `clipFramePlan` runs in `draw(_:)`, not on the planning
path, so removing it should not move the plan line and did not. Process CPU rose
6.96% against a draw bracket that rose 121%, which is consistent with the draw
bracket being roughly 1/23 of an `incremental-mixed` frame (`17/F12`).

## Outcome

**The shipped damage-scoped draw path is not slower than full repainting. It is
substantially faster, and the margin is not close.** At the damage size the
`incremental-mixed` workload models -- 4 rows plus halo, of 66 -- scoping the
plan and the clip is worth 2.2x on the calibrated draw metric (F4), and the
rasterization it avoids downstream is worth about 15x (F2). No rung produced
evidence in the other direction at that damage size.

Two things this does **not** settle, both narrower than the question asked:

1. **Full damage is a real crossover, and exhaustive row damage now skips plan
   clipping.** F2
   puts the break-even between 76% and 100% of rows damaged, and at 100% the
   clipped arm was no faster and possibly slightly slower. The pre-`d378096`
   bbox path had a widen-to-full short-circuit (`rows == 0..<plan.rows`), but
   sparse rows could not reach one because `TerminalDamage.isFull` is a
   separate flag meaning "cannot be expressed safely as viewport rows" -- not
   "covers every row" (`TerminalDamage.swift:8-15`). Before the follow-up,
   `TerminalDamage(rows: Set(0..<66))` therefore reported `isFull == false`, and
   a frame where *every* row was damaged still took the clipped branch: five
   whole-array `clipFramePlan` filters that discarded nothing and allocated
   five full copies, then a span clip that coalesced to the one rect `.full`
   would have used anyway.

   That made the high-damage overhead in the app almost entirely
   `clipFramePlan`, **not** the clip -- which F2 does not measure, since
   `clipFramePlan` sits outside its timed region and its 66-rect clip is not the
   app's single span. F2 and this point agree in direction but are not the same
   term; at that point neither had been measured on the real draw path.

   It also means the first candidate is not a threshold. Recognizing
   "`rows` covers every viewport row" and taking the `.full` branch is a
   predicate fix with no policy attached, which is the shape doc 30 accepts on
   proven non-regression alone. A damage-*fraction* threshold (widen at, say,
   80%) is the aggressive version and does need calibration. 29/`H3` disposes of
   neither: it rejected a threshold on *span count*, on the evidence that
   coalescing never lost.

   Follow-up measured 2026-08-05 with `just benchmark-confirm baseline=HEAD`:
   baseline commit `61d8b231bcc3c3ec310f29dd6d97d57b215f382d`, baseline tree
   `fccc1cd7f1ffaf70c1d7ac3976b1bd78a8a4bdd5`, candidate tree
   `4dd4b4a08848258e4c2005d15fd0c644bd98c6cd`. The exhaustive-row fast path
   returned the plan unchanged only when the damage set exactly covered the
   plan's row range; damage semantics and the partial-damage path stayed
   unchanged. The confirm verdicts were `terminal-feed` inconclusive (+0.86%),
   `scrollback-stream` equivalent (+0.62%), `content-churn` **faster** (-3.03%),
   `style-churn` inconclusive (-1.85%), `incremental-mixed` equivalent (-0.07%),
   and `retained-browse` equivalent (+0.37%). No workload read `slower`, so the
   frozen measured-improvement rule adopted the fast path. Artifact:
   `.build/terminal-benchmark-comparisons/confirm/4dd4b4a08848-0000`.
2. **`B2` was never measured.** Whether full *layer invalidation* changes the
   Core Animation picture is unanswered; it is unanswerable on the calibrated
   ladder and would need rung 4. Given F4's margin it is hard to see it
   mattering, but "hard to see" is not a measurement.

Neither of these is a reason to revisit the shipped path. They are the two
places where a follow-up could still find something.

## Next

Nothing further on the question as posed or on exhaustive-row plan clipping.
A damage-fraction threshold short of 100% would start from F2's crossover and
needs a fresh frozen rule, a damage-fraction sweep on the real app rather than
the headless arm, and its own doc under `docs/research/`.
