# Terminal Performance Benchmarking and Profiling

Use these commands when measuring or optimizing DanTerm's real terminal path.
They build optimized apps with isolated home, temporary, and IPC state. Each
command owns only the processes it launches and never selects or terminates
another DanTerm instance.

The question the comparison commands answer is always "did this code change make
the relevant terminal path faster or slower?" -- never "is this faster than it
was last week". There is no benchmark history: every directional claim compares
an explicit baseline revision with the current working tree inside one machine
session, which is what cancels the machine drift that a stored record cannot.

Speed is not the only cost these commands measure. The profiling modes attribute
CPU time, and `just benchmark-memory` measures footprint growth over a sustained
run -- see "Profile memory" below.

## Decide a change with a paired comparison

    just benchmark-quick baseline=<revision> workload=<workload>
    just benchmark-confirm baseline=<revision>

`benchmark-quick` compares one selected workload; `benchmark-confirm` compares
all ten. Both require an explicit baseline revision -- anything `git rev-parse`
accepts (`HEAD~5`, a SHA, a tag, a branch). Neither infers it from `HEAD`,
merge-base, history, or the candidate.

The common case is an uncommitted experiment measured against the commit it
started from, and nothing is stashed, committed, or checked out to do it:

    just benchmark-quick baseline=HEAD workload=content-churn

The wider the baseline gap, the more the verdict attributes to everything in
between rather than to your change alone. If you have committed since starting
the experiment, `HEAD` is no longer where you began; note the pre-change revision
before you start and name it explicitly.

The candidate is an immutable snapshot of the complete current working tree:
tracked changes plus non-ignored untracked files, captured through a scratch
index that leaves your own index untouched. Before either arm builds, the
command prints the resolved baseline commit and tree, the candidate base commit
and tree, and every captured candidate path. Read that list: it is the cheapest
moment to notice a wrong baseline or a stray file.

Both arms build only from their exported immutable trees in disjoint source and
build directories, and build products are cached by source tree identity, build
configuration, toolchain, and ignored-prerequisite digests. A cache hit re-proves
its recorded executable SHA-256 and Mach-O UUID before it can supply a measured
block. Comparing a baseline that resolves to the candidate's own tree is refused
rather than run.

The workload ladder. Pick the narrowest workload that still contains the cost
you are trying to move; a workload that does not contain it will answer
`equivalent` no matter how good the change is.

| Workload | Question it answers | What one block runs | Reach for it when |
| --- | --- | --- | --- |
| `terminal-feed` | Did parsing, grid mutation, and damage calculation get cheaper? | The four committed corpora framed into one stream, fed into a fresh 179x66 `Terminal`. No PTY, no window, no drawing. | `Terminal.feed` or other pure terminal-state work is hot. |
| `scrollback-stream` | Did sustained output get cheaper end to end? | A fresh app and terminal session per block replays 25,000 numbered lines through a real PTY, running to the final completed draw and paired on the PTY drain leg. | PTY chunking, actor hops, snapshot delivery, backpressure, scrolling, or retention is hot. |
| `content-churn` | Did replacing screen *content* get cheaper? | 50 serialized full-screen 179x66 frames; text changes every frame, style is frozen. | Glyph lookup, shaping, or text-run construction is hot. |
| `style-churn` | Did replacing *attributes* get cheaper? | 50 serialized full-screen frames; text is frozen, only truecolor fg/bg change. | Attribute or color handling is hot and no new glyphs are involved. |
| `incremental-mixed` | Does small damage stay small? | 50 serialized updates touching 4 rows of an already-settled dense screen. | You suspect localized updates are doing full-window work. |
| `retained-browse` | Did planning a frame over *retained history* get cheaper? | 2,000 headless `planFrame` calls with the viewport parked at the oldest of ~6,756 retained rows (179x66, 10,000 fed lines). No PTY, no window, no drawing. | Scrollback storage, retained-row representation, or frame planning over history is hot. Nothing else on the ladder displays history at all. |
| `kitten-feed-ascii` | Did feeding a stream of nothing but printable ASCII get cheaper? | 2 repetitions of kitten's ~2 MB random-ASCII payload, fed into a fresh 179x66 alt-screen `Terminal`. No PTY, no window, no drawing. | Line advance on the alternate screen, bulk narrow printing, or per-action parser cost is hot. |
| `kitten-feed-unicode` | Did feeding wide and multi-byte text get cheaper? | 2 repetitions of kitten's fixed CJK-plus-symbols payload, same headless collection. | Wide-cell printing or UTF-8 decoding is hot. |
| `kitten-feed-unique-unicode` | Did building combining-mark clusters get cheaper? | 2 repetitions of kitten's 262,144 cells of `a` plus three combining marks each, same headless collection. | Grapheme cluster append, spill interning, or the glyph identity path is hot. |
| `kitten-feed-csi` | Did absorbing dense escape sequences get cheaper? | 2 repetitions of kitten's ~1 MB mix of seven escape sequences and short ASCII runs, same headless collection. | Escape parsing, `REP`, or cursor and attribute handling is hot. |
| `synchronized-frames` | Did absorbing a real TUI's output get cheaper when it coalesces its frames? | A fresh app and terminal session per block replays 95 captured btop frames through a real PTY, timed to the final completed draw. Every byte sits inside a `DECSET 2026` bracket. | Parsing, damage tracking, or the synchronized-output path is hot, or a change touches what happens while drawing is suppressed. |

Every draw block is serialized: one write, then wait for that exact completed
draw before the next write. Nothing coalesces, so the per-draw number is a real
draw rather than an amortized one.

The three draw workloads deliberately freeze one axis each. A change that helps
`content-churn` but not `style-churn` moved glyph work; one that helps both
moved something under them. `incremental-mixed` is the only workload that can
catch damage-scoping regressions, and it carries the most pairs (6 in `confirm`)
because it is also the noisiest.

`retained-browse` is the opposite case and needs one warning attached. It is by
far the quietest workload here -- headless, so no window, compositor, PTY, or
WindowServer -- and it decides on a +/-1.05% threshold where the draw workloads
need 2.0-2.15%. That tightness has a cost: `confirm`'s equivalence band is 0.75%
and this threshold is 1.05%, so a real difference landing in that 0.30-point gap
reads `inconclusive` by construction, which its A/A series did 28.4% of the time
at the frozen 4 pairs. **`inconclusive` here means the difference is smaller than
the ladder resolves, not that the run was bad.** Rerunning does not fix it (doc
28 `F1`/`D2`).

Each mode lays out its complete position-balanced schedule at the frozen pair
count before the first block runs, then applies the frozen median symmetric rule
exactly once: `faster`, `slower`, `equivalent`, or `inconclusive`. There is no
early stopping, no rerun of a valid block, and no partial decision. A single
invalid block invalidates the whole invocation -- see "Run it under the stated
conditions" below.

### Read the result

    content-churn: faster (-3.20% symmetric median of 2 pairs)

| Verdict | Meaning | Do this |
| --- | --- | --- |
| `faster` / `slower` | The estimate cleared that workload's frozen directional threshold. | Believe it. Record the decision-bearing values in the commit or plan. |
| `equivalent` | The estimate sits inside the equivalence band. | The change did nothing measurable *at this boundary*. Before concluding it did nothing at all, confirm the workload actually contains the cost you moved. |
| `inconclusive` | Neither cleared the threshold nor fell inside the band. | Escalate `quick` to `confirm`, which measures more pairs at a tighter threshold. Do not rerun `quick` hoping for a different roll -- the pair count is frozen precisely so results cannot be shopped for. |

### The plan-time line is decided separately

    content-churn: equivalent (+0.11% symmetric median of 2 pairs)
        plan time: -18.40% symmetric median of 2 pairs (descriptive, no verdict -- uncalibrated)

The draw verdict and the plan line are decided separately and can disagree; a
change that plans faster while drawing slower reports exactly that.

**What the plan line measures.** The observer records every `planFrame` call
inside a block as its own sample -- wall time, thread CPU, and the number of
viewport rows it replanned (`planSample*` in `final-draw.json`). The block's
quantity, `planNanosecondsPerFullPlan`, is the median over the samples that
replanned the full 66-row viewport, reported with `fullPlanCount` beside it and
absent below 25 such samples. One class of plan rather than a sum over all of
them, because a block also holds mid-screen partial plans at roughly half the
cost, in a proportion PTY chunking sets per process: the old per-draw sum read
+7.33% on an A/A series of one binary against itself (research/38/F1).
`incremental-mixed` replans four or five rows per update and never a full
viewport, so it carries no plan line at all.

The three serialized-draw workloads decide on `drawNanosecondsPerDraw`, which
brackets the pane's render into its owned surface. Frame planning does not run
there -- `planFrame` runs on the PTY-output path, when a pane applies child
output -- so **the draw verdict cannot see a planner change at all**. It is not
that planning is a small term in that number; it is not in that number. So
judging a planner change means reading the plan line, and a change that moves
only planning correctly reads `equivalent` on all three draw verdicts.

**T25 moved this bracket, and F28 recalibrated it on the new meaning.** The old
bracket covered clipping and display-list submission; Core Animation replayed
the list after `draw(_:)` returned. The pane now rasterizes into its own
IOSurface inside the bracket. Post-T25 measurements are therefore not comparable
to pre-T25 draw figures. The operational rules below apply only to the owned-
surface bracket.

The post-move A/A screen retained directional rules for `content-churn` and
`style-churn`. It found no eligible rule for `incremental-mixed`, even when the
screen searched through 160 pairs. That cell still runs its six confirm pairs
for diagnostic comparison, but it always prints `descriptive, no verdict --
uncalibratable`. Use `benchmark-headless-draw` for a directional claim about
small-damage drawing, per
`docs/design/2026-07-27-damage-render-benchmark-routing.md#D2`.

The churn rise is itself explained (research/33 `F26`): before the move,
CoreAnimation shaded the full grid on the GPU, so no CPU account anywhere
contained the raster; the owned surface renders it in software on the main
thread. Process CPU on the full-grid workloads therefore *contains* the raster
now, and any comparison whose baseline predates the move will read high on
them for that structural reason, not from a regression in the change being
measured.

Planning is the **smaller** cost, and it shrinks ~7.6x when damage goes from 66
rows to 6, because **the planner is damage-scoped**: production planning runs
through `PaneFramePlanner.planFrame(for:presentation:damage:)`, which replans only
the rows `damage` marks and copies an undamaged row's runs forward from the
retained frame. (`RenderFramePlanner`'s free-function `planFrame(for:presentation:)`
does pass `damage: .full`, but it is not the pane path.) Measured at `4ecb032`
(`research/17/F12`): `content-churn` ~540k ns to draw against 501k-510k to plan;
`incremental-mixed` ~86k against ~66k.

**No plan/draw ratio generalizes across workloads** -- it is a property of how
much damage a workload generates, not of the code -- so do not carry one from a
doc or a profile to a workload it was not measured on
(`research/14/F1`).

No cell carries a plan rule today. The quick rules that stood for
`content-churn` and `style-churn` (2 pairs at +/-2.5%) were calibrated on the
per-draw sum, and a rule frozen for one quantity does not transfer to another;
until a human freezes one from an A/A report on the full-plan median, every
plan line reads `descriptive, no verdict -- uncalibrated`. Do not read those
percentages as decisions or borrow a draw workload's threshold for them.

A plan rule is pinned to the pair count its mode already collects -- plan time
rides the draw metric's own blocks, so it cannot buy a longer schedule, and a
rule is refused rather than applied when the series length does not match. The
line is **absent whenever either arm lacks it**, the normal case when the
baseline predates the sampler; a missing plan line never invalidates the draw
verdict.

### `scrollback-stream` reports how its block splits into drain and draw tail

    scrollback-stream: +0.10% symmetric median of 2 pairs (descriptive, no verdict -- uncalibratable)
        drain (baseline): 146.4 ms, 10.4 MB/s (1.52 MB corpus at 179x66; descriptive, no verdict)
        draw tail (baseline): 9.0 ms (5.8% of block)
        drain (candidate): 145.9 ms, 10.5 MB/s (1.52 MB corpus at 179x66; descriptive, no verdict)
        draw tail (candidate): 10.8 ms (6.9% of block)

`drain` is the time the producer spent writing the corpus into the PTY. Because
the producer blocks on `write()` once the buffer fills, that is the rate at which
the app drained it -- **the PTY throughput number**, reported per arm because it
is the marker you watch move between revisions.

**The paired estimate is the drain leg alone.** The drain is ~96% of the whole
replay (median 95.7% over 368 archived blocks) and the draw tail is the
remaining ~4-7%, so the block total this cell used to pair on was a throughput
measurement wearing a draw metric's name -- and its small tail was enough that a
few milliseconds of slot-position penalty there carried the whole cell by
several points with no code change (`research/39/F8`). So this cell now pairs on
the leg it can resolve. **A change that touches only the draw path moves this
number by nothing at all**, which is the expected reading of a real drawing win
here, not evidence against it: take that verdict from the serialized-draw
workloads, which exist for it. The draw tail is still reported, descriptively,
in the lines above.

Three limits. The rate is the app's, not the harness's: the Python producer's own
overhead is **fully absorbed** once the consumer runs at the app's real rate
(rechunking the writes moves the block by 0.0 ms there, against 20.4 ms
unthrottled, because the writer is parked on a full PTY buffer either way), so
quote the MB/s as measured. The lines are **absent rather than wrong** when an
arm predates the byte counter or the two arms drained different byte totals;
there is no assumed corpus size. And they exist only for `scrollback-stream` --
the serialized-draw workloads write one update and wait for that exact draw, so
their write time is a handshake, and no byte count is recorded for them precisely
so no rate can be derived.

Like plan time and process CPU, this decides nothing. Evidence and the survey
behind it: [docs/research/20-pty-throughput-and-interactive-stimulus.md](../docs/research/20-pty-throughput-and-interactive-stimulus.md).

### `synchronized-frames` is a candidate and issues no verdict

It is the only captured candidate -- 95 real btop frames rather than a generator
we wrote. Two things about it are not like the calibrated workloads.

**It is not a draw workload, despite being timed to a final draw.** 100% of its
bytes arrive inside a `DECSET 2026` bracket, and `planIfNeeded` returns early
while synchronized output is active, so the app parses the whole replay and draws
essentially nothing until the end. Its block is ~95% drain, and its draw tail is a
**constant ~7 ms** rather than a share of the work -- shortening the stimulus
inflates the tail's percentage without measuring one nanosecond more drawing
(`research/20/F10`). Read it as "how fast can we absorb a real TUI's output", and reach for
`content-churn` or `style-churn` for anything about drawing.

**It has no frozen rule.** `research/23/D4` demoted it to `CANDIDATE_WORKLOADS` and
removed its quick and confirm rules after fresh post-rewrite evidence refused
them (`research/23/F8`): the frozen `confirm 8p@2.15%` cell read 12-14% A/A false
positives against a 1% gate and 74-78% detection against 90%, and two
independent 48-pair screens each selected no cell. Its fixture, collector,
direct harness command, block contract, and candidate-screen path all remain
available for descriptive collection.

**Do not try to buy a tighter rule by lengthening the replay.** It was tried
(`research/20/F16`): at 1x/2x/3x the trimmed A/A pair SD is flat (1.30-1.72% / 1.65% /
1.62%), which is multiplicative noise. Lengthening also changes what the
workload measures -- the main-thread fence regime shifts at 2x, where 9 stalls
of ~16 ms become 1-2 of 126-266 ms.

Re-screen it with `scripts/terminal-benchmark-candidate-screen.py screen
--workload <name> --revision <rev>`, which searches pair count alongside threshold
-- a workload owns its blocks and so can buy more pairs, which is exactly what an
auxiliary metric cannot do (`research/17/F15`). It writes a report and never a rule.

### `sparse-spans-max` is a topology diagnostic and issues no verdict

This candidate serializes 50 draws at 179x66 whose engine damage is exactly 17
rows in 17 maximal spans. Its primary reported quantity remains whole-process
CPU per accepted draw for continuity with the candidate screen that admitted
it. The old halo-derived topology series and asynchronous Core Animation replay
it once diagnosed no longer exist.

Do not promote that CPU quantity into a verdict. Three valid 24-pair A/A screens
on 2026-08-06 produced incompatible calibration outcomes: two selected no cell,
including a controlled low-load run with 4.71% SD and a -15.05%..+7.23% range,
while the other proposed quick and confirm cells that failed independently
against the first series. The protocol therefore refused a frozen rule before
held-out confirmation or known-bad sensitivity measurement. The topology and
coverage checks still make a collected block useful for diagnosis; they do not
make the CPU difference decision-bearing. See `research/29/D3`.

### The four `kitten-feed-*` arms replay kitten's own stimulus

`kitten-feed-ascii`, `kitten-feed-unicode`, `kitten-feed-unique-unicode`, and
`kitten-feed-csi` replay the stimulus `kitten __benchmark__ --render` sends, on
the four arms where research 39 measured DanTerm 2-5x behind Ghostty. They are
headless and collected exactly like `terminal-feed`: a fresh 179x66 terminal per
execution, one sample per block, the same one-second floor, the same machine-state
probe and battery rule. Only the byte source differs.

**One arm per workload, deliberately.** Research 39 needs a verdict per arm on
every fix. A combined stream would average a win on `csi` against three flat arms
and hide it, so each arm owns its blocks and is screened, frozen, and gated on its
own.

**The stimulus is generated, not committed, and its identity says so.** The
`TerminalCoreBenchmark generate <arm>` command in the collection's immutable root
produces the bytes once and both physical arms receive that one stream. Each
arm's identity names the arm, the repetition count, the seed, 179x66, and a
SHA-256 of the framed bytes including the untimed setup and teardown boundaries
(`KITTEN_FEED_FIXTURE_IDENTITIES`). Anything that moves a byte or a boundary
moves the digest, and blocks collected under the old stimulus stop validating --
which is what keeps a threshold frozen for one stimulus from judging another.
`scripts/kitten-benchmark-parity-lint.py` holds the generator to the pinned kitty
sources it was ported from.

**Only the middle portion is timed.** kitten starts its clock after writing the
terminal state and stops it before the deferred restore, so the harness charges
the sample for the payload repetitions and nothing else. A change that only speeds
up RIS or alt-screen teardown cannot move these arms, because kitten does not
measure it either.

**Calibration aims a fifth above the floor, not at it.** The batch count is chosen
so a sample clears 1.2 s, while a block is still invalidated below 1.0 s. Aiming at
the floor picked the first batch count that cleared it, and the margin left over was
whatever batch-count discreteness gave: `kitten-feed-unicode` costs ~167 ms per
execution, so six executions landed at 1.003 s and about half its blocks were
discarded as `block-below-duration-floor` -- the arm could never finish a quartet.
With the margin, a below-floor block means the machine was disturbed, which is the
only thing that discard can usefully report. The cost is proportionally more machine
time per block.

**Each arm decides on its own frozen threshold, the same cell in both modes:**
2 pairs at +/-1.70% for `ascii`, +/-1.80% for `unicode`, +/-1.60% for
`unique-unicode`, and +/-1.45% for `csi`. They were screened at 12 quartets and
50,000 trials, then each selected cell was confirmed at 100,000 trials on fresh
disjoint seeds, per arm and never pooled (`research/39/F5`). A/A false positives
were 0.0000 in all eight cells; detection is the binding gate, at 0.915 against
the 0.90 floor on the two Unicode arms. Because `confirm`'s equivalence band is
0.75%, a real difference between 0.75% and the arm's threshold reads
`inconclusive` by construction -- the same gap `retained-browse` has, and
rerunning does not close it. Do not lengthen the repetition count to buy a
tighter rule without a finding that the noise on that arm is additive.

### The third reported quantity: whole-process CPU per accepted draw

The three serialized-draw workloads also report
`processCPUNanosecondsPerDraw`: CPU time summed over **every thread**, taken from
`task_info(TASK_ABSOLUTETIME_INFO)` and charged to each accepted draw as the delta
since the previously accepted one. T25 removed the known asynchronous display-
list replay that originally justified this quantity: software rasterization is
now inside the main-thread draw bracket. Process CPU remains useful because it
also includes parsing, planning, observer work, and any other process thread.
It is a broad diagnostic, not a better draw timer.

**And the churn workloads are frame-rate-capped, not CPU-bound.** `research/17/F16` traced
`full-screen-content-churn` at 179x66 and at 80x25 -- a 5.9x change in per-frame
glyph work -- and the draw rate was 119.10/s and 119.32/s, pinned at the built-in
120Hz panel's refresh in both. So a CPU reduction on these workloads is not a
throughput win, because there is no throughput headroom to win, and a cost living
off the main thread has no metric here that can decide it: not the draw rule
(wrong thread), not the frame rate (pinned), not process CPU (uncalibratable,
below).

Four things it is not, each of which invites a misreading:

1. **It is not latency.** Work moved off the critical path onto an idle core reads
   as neutral. It answers "did we stop doing work" -- the right question for
   replay cost and the only one that maps to battery.
2. **It is not a per-draw bracket.** The interval between two accepted draws
   contains everything the process did in it: this draw, parsing, planning, and
   the observer's own acknowledgment writes. The series is meaningful in
   aggregate, not at a single index.
3. **It cannot be calibrated, so it never carries a verdict.** It is reported
   through `UNCALIBRATED_BLOCK_METRICS`, which consults no rule table; there is no
   code path by which it can classify. That is settled, not pending: the A/A
   screening pass ran (`research/17/F15`) and no threshold clears the accuracy gates on any
   workload in either mode, because an auxiliary metric rides the deciding
   metric's blocks and so cannot buy the extra pairs that would close the gap.

   **What you may still do with it** (`research/17/D6`): use a co-movement to *undermine* a
   draw verdict -- if plan time and CPU shift by the same amount on a change with
   no causal path to planning, that is arm-level drift, and `research/17/F14` caught a
   spurious `faster` exactly this way. Use a CPU move with no draw move as a reason
   to profile for work outside the render bracket. Never use it to *confirm* a win, and never
   quote a difference as an effect: on `style-churn`, 5 of 24 pure-noise pairs sit
   at or below -3.02%.
4. **It includes the instrument**, which on `incremental-mixed` is a large term --
   the observer's acknowledgment `open()` alone was 9.8% of that workload's on-CPU
   total (`research/17/F2`).

The line is absent whenever either arm lacks it, exactly like plan time, which is
the normal case for any baseline predating this reading.

Recalibrate an auxiliary metric's rules with
`scripts/terminal-benchmark-plan-calibration.py --metric {plan,process-cpu}
--revision <rev>`, which collects an A/A series with both arms bound to one
immutable root and reports the threshold clearing the gates at the pair count that
mode already collects. `--metric` selects from `CALIBRATABLE_METRIC_TABLES`; both
quantities ride the same blocks, so one collection can screen either, and the
report and its artifact directory are named for the metric that was screened. It
never edits the frozen rules: a human moves
`DECISION_RULES[mode]["planWorkloads"]` after reading the report. A report that
proposes nothing is a real answer -- see point 3 above and `research/17/F15`.

### Run it under the stated conditions

The thresholds are calibrated for a fully visible, unoccluded 179x66 window on
one MacBook on AC power. Changing the machine, geometry, workload contract, or
decision rule requires recalibrating before directional claims resume. While a
comparison runs, leave the machine otherwise idle: competing load biases both
arms unequally.

Any of these invalidates a block, and one invalid block invalidates the whole
invocation: lost geometry, an occluded window, battery power, thermal pressure,
low-power mode, missing damage or draw acknowledgment. **An invalid invocation
is not a verdict and never becomes one by retrying.** The evidence is kept, but
a new decision needs a fresh complete run -- so fix the condition (AC power,
uncover and focus the windows, let it cool) and run again from scratch.

Every invocation writes its complete evidence to
`.build/terminal-benchmark-comparisons/<mode>/<run>/run.json`: both source and
binary identities, the schedule, raw and normalized blocks, the decision rule,
the decision, flagged outliers, invalidations, and phase timings. `.build/` is
disposable, so when a result justifies an engineering change, record the
decision-bearing values inline in the commit or plan -- mode, workload, both
tree identities, the median symmetric estimate, and the classification -- and
cite the artifact path only as a supplementary pointer.

Expect a cached quick comparison to finish in under 60 seconds and a cached
confirm suite in under five minutes. The first run against a new tree pays for
compilation, which the command reports separately from the comparison phase.

Run `quick` for the routine question. Run `confirm` when the quick result is
close, the change crosses workload boundaries, or the decision warrants the
stronger ten-workload evidence.

### What this instrument does on identical source (A/A), per workload

The non-draw cells below come from the 2026-08-05 control in `research/31/F18`.
The three serialized-draw cells come from the post-T25 control in
`research/33/F28`: eight complete `confirm` invocations whose source differed
only by a Markdown marker, after a 24-pair screen and an independent 100,000-
trial freeze. Both ran on one MacBookPro18,1 at 179x66.

| workload | frozen threshold | worst A/A estimate seen | reading rule | directional A/A verdicts |
| --- | ---: | ---: | --- | ---: |
| `terminal-feed` | 2.50% | 0.86 | distrust differences under **0.9 points** | 0 / 8 |
| `scrollback-stream` | none (vacated, and a re-screen refused a new one) | 3.48 | descriptive only; no directional claim | **3 / 8** under the vacated rule |
| `content-churn` | 1.50% | 0.99 | distrust differences under **1.0 point** | 0 / 8 |
| `style-churn` | 1.75% | 1.75 | distrust differences under **1.8 points** | 0 / 8 |
| `incremental-mixed` | none | 5.55 | descriptive only; no directional claim | 0 / 8 by construction |
| `retained-browse` | 1.05% | 0.89 | **0.3 points** with the arm slot held fixed; **0.9** across slots | 0 / 8 |

The four `kitten-feed-*` arms are deliberately absent: their thresholds
(1.45-1.80%) were frozen from a within-series screen and confirmation
(`research/39/F5`), and no whole-invocation A/A control has been run on them yet.
Read point 3 below before treating their screened noise as this table's quantity.

Four things to carry away:

1. **The re-armed content and style rules made no false directional call across
   eight whole invocations.** Incremental estimates still ranged widely and
   changed sign, so refusing that rule is the useful result, not unfinished
   calibration. It cannot emit `faster` or `slower`.
2. **`retained-browse` is the ladder's most repeatable cell and its margin is
   still mostly spent.** Run-to-run scatter is 0.06-0.28 points, the best here --
   but the *physical arm slot*, which `physical_candidate_arm` derives from the
   candidate tree's own hex parity, moves the estimate by ~0.6 points against a
   1.05% threshold. Re-running the same candidate tree measures the same thing to
   within 0.3 points; changing the tree can move the cell by 0.6 with no code
   change at all.
3. **This is between-invocation noise, which is wider than a frozen rule's
   within-series screen.** The eight-run gate adds app launches, slot assignment,
   and host drift. F28's content/style result is the held-out check that the
   post-T25 cells survive that wider quantity. The same run also produced one
   false directional result each on `scrollback-stream` and `retained-browse`;
   those unrelated rules retain F18's caveat and are not evidence for the draw
   recalibration.
4. **`scrollback-stream`'s rule is vacated, because it also pays a slot-position
   penalty in its draw tail.** The cell keeps its schedule and reports its
   estimate; it emits no `faster` or `slower`, like `incremental-mixed`. The
   threshold that stood here was 1.85% against a worst A/A estimate of 3.48
   points, so it was miscalibrated on its own record before the draw tail was
   understood. On 2026-08-28 (`research/39/F8`) a candidate on physical
   slot `b` held a draw tail of 17.0-18.4 ms across three probes whether or not
   the change under test was present, while the cached baseline binary on slot
   `a` swung 10.5-15.8 ms. The cell called `slower` at +9.54% and +11.25% in two
   `confirm` runs on a diff that was verbatim code motion -- the damage both
   trees publish is byte-identical over 39,799 per-action records -- and it still
   called `slower` at +5.16% on a tree with **no code delta at all**. Every one
   of those calls sat in the draw tail; the drain leg, which is the only leg a
   feed-path change is in, matched to the digit. The cell now pairs on that
   drain leg alone, so the tail no longer enters the estimate -- but it is still
   reported beside it, and a movement there is position, not code. This is the
   same `physical_candidate_arm` slot effect point 2 prices for
   `retained-browse`.

   **That A/A series has now been taken, and it refused a rule**
   (`research/39/F9`, 2026-08-28, at `eaa78201`). 12 quartets on the drain leg:
   24 pairs, median +0.75%, SD 6.23% (trimmed 4.86%), range -15.79%..+12.51%,
   and no threshold clears the gates at any pair count through 24 in either
   mode. So the cell stays vacated on its own measurement, not on the old
   record. The drain is stable *within* a session and 6.2% *across* A/A pairs;
   only the second quantity is the one a threshold has to survive. Do not go
   looking for a wider threshold either: the searched grid stops at 3.00%, which
   is `confirm`'s own effect size, so nothing above it could detect what the
   mode exists to detect.

   **Two reading rules, and which reports each one covers.** The bias itself was
   removed at `eaa78201`: every measured arm now runs in one bundle namespace,
   which `research/7` had measured as a bias carrier in its own right. Reports
   written before that commit still exist, and on those the old rule stands --
   a `slower` call on `scrollback-stream` whose movement is in the draw tail is
   not believed until a change-free control run reproduces it. On reports from
   `eaa78201` onward the cell issues no direction at all, so there is no verdict
   to distrust; read its estimate through the drain and draw tail lines above,
   and treat a movement in the tail as position, not code.

**Two schedule properties since 2026-08-27 (research/38/F2, `D2`).** Each
persistent draw arm runs one discarded block right after it starts, before any
scheduled block, because an arm's first block drew 6-8% above every block after
it; the run record keeps it as `warmupBlocks` beside `rawBlocks`. And a run's
first quartet is ABBA or BAAB by a bit of the candidate tree (`quartetPhase` in
`run.json`), so quick mode's single quartet does not put the baseline first in
every invocation.

## When to measure

Running a comparison on your own initiative is welcome -- you do not need to be
asked. What follows is about reading the result honestly, not about permission.

Know what each mode can see before you spend one. `quick` decides at 2 pairs per
workload with directional thresholds of 2.0-4.5% and a 1.0% equivalence band;
`confirm` uses 2-6 pairs at 1.5-2.5% with a 0.75% band. So `quick` cannot
distinguish a 2% regression from noise -- it reports `inconclusive`, which is the
absence of an answer. Neither mode can license "no regression"; they can only
license "no regression above my threshold."

Measure when you have a hypothesis the result would settle:

- You intend to claim a change is faster. Run `quick`, then `confirm` before the
  claim goes anywhere durable.
- You are changing a path a profile just named as hot. You have a specific
  prediction; a comparison accepts or rejects it.
- You are refactoring the feed or render path and "this changes no performance"
  is itself part of the claim. Only `confirm` has the sensitivity to support
  that; `quick` returning `equivalent` does not.

Sanity-checking a change you are merely unsure about is a legitimate reason to
run one, and an `equivalent` at `confirm`'s thresholds is real evidence. But an
`inconclusive` or an invalid invocation leaves you exactly where you started: say
so plainly rather than reporting that the change was benchmarked and looked fine.

When the honest answer is that you have no hypothesis yet, profile the
suspicious path instead. That is the cheaper question and usually the one you
actually have.

Two things that are not hypotheses, and have each cost real time here:

- **A profile share is not a trigger.** The draw path already fits the 60Hz
  frame budget (`research/11/F7`, `research/11/F8`), so "this
  function is N% of the draw" does not by itself justify a render optimization.
  Name what a user would observe differently, or leave it.
- **Date a number before you plan against it.** Every figure in this guide and
  in `docs/research/` is a measurement of one tree at one commit, and the commit
  that invalidates it does not come back to update the prose. This guide's
  plan/draw figures were once 1.7x-17.5x too high because damage scoping landed
  three days after they were written, and the stale claim kept a parked backlog
  item alive (`research/17/F5`). Check the commit a
  number names against what has landed since.

## Choose a profiler

Profiling is diagnostic only. It builds from the local checkout, runs one
isolated sustained workload, and cannot decide anything.

Pick by the shape of the question, not by cost -- both modes cost one build and
one sustained run.

Reach for `just benchmark-trace scrollback-stream template="Time Profiler"
seconds=30` for any question phrased as a share: which frame owns the time,
what fraction the feed path costs, whether a change moved the distribution. Its
Time Profiler records on-CPU samples only, so its percentages mean what they
appear to mean.

Reach for `just benchmark-sample scrollback-stream seconds=15` when the
question is "what is this thread doing" or "does this path appear at all" --
where a stack is present, and blocked stacks are part of the answer. Its
percentages need the correction in the next section before they mean anything.

Both attach by numeric pid from the isolated harness identity file; they do not
find a process by name or automate Instruments.app, and neither needs an
Instruments session to read -- see the next section.

`just benchmark-feed-sample` is narrower than either: it samples `Terminal.feed`
alone, headless and without a display, isolating parse and grid cost from the
planning and drawing that share the app's main thread. Its `--profile` harness
requires a declared duration and exits on its own after the cycle in flight at
the deadline finishes. The driver sets that duration to the warmup, sample
window, and a small teardown margin.

For a manual per-arm profile, give the harness a regular fixture file and set
its duration above the `sample` window. For example:

```sh
swift build --package-path lib/TerminalCore --configuration release \
    --product TerminalCoreBenchmark
bin_dir="$(swift build --package-path lib/TerminalCore --configuration release \
    --show-bin-path)"
"$bin_dir/TerminalCoreBenchmark" generate kitten-feed-unicode > /tmp/danterm-feed.fixture
"$bin_dir/TerminalCoreBenchmark" --profile 20 < /tmp/danterm-feed.fixture &
profile_pid=$!
sample "$profile_pid" 15
wait "$profile_pid"
```

The duration is the backstop even if the shell or sampler disappears. Standard
input must be a regular file, so a terminal, pipe, or FIFO fails before the
harness reads it.

Both CPU modes take an Instruments template, but only the CPU templates record
an exportable table. Recording with `Allocations` or `Leaks` succeeds and then
exports nothing, so `benchmark-trace` checks the trace's schemas and fails with
the list rather than leaving an empty report behind. For memory, use the mode
below.

Use `just benchmark-loop scrollback-stream` when attaching another
command-line diagnostic tool. It prints the identity JSON -- pid, workload,
fixed backend provenance, executable SHA-256, Mach-O UUID, source identity -- and continues until
interrupted. Stop it with Ctrl-C; the harness then terminates only its own app.

If attachment is refused, grant Developer Tools access to the invoking terminal
in System Settings and retry. The benchmark app is ad-hoc signed with
`get-task-allow`; the harness verifies the entitlement before launch. `xctrace`
also uses `--no-prompt`, so a permission problem fails with diagnostics instead
of waiting for UI.

## Profile live btop scrolling

The sparse AppKit damage regression was found by profiling a real btop under a
held arrow key, not by any workload above -- so that stimulus is a workload of
the three profiling commands. It is the only one whose content is the host's live
process table.

```sh
just benchmark-sample btop-scroll 20
just benchmark-trace btop-scroll "Time Profiler" 20
just benchmark-loop btop-scroll
```

`sample` and `trace` take a whole-number recording window of **1 to 20 seconds**,
positionally, and require it: there is no default. `loop` takes no duration --
it alternates Down and Up in 10-second legs until you Ctrl-C it.

**Preconditions, all checked before anything is compiled, built, or launched.**
`btop` must be on PATH, and the invoking shell must already hold Accessibility
permission to synthesize keyboard input (System Settings > Privacy & Security >
Accessibility). A missing binary or a refused permission ends the run in
seconds rather than after a release build.

**Leave the machine alone for the length of a bounded capture.** The app has to
stay frontmost and fully presented for every sampled instant of the measured
interval, so switching windows -- Cmd-Tab, clicking another app, a full-screen
notification -- invalidates the run. That is the gate working, not a flake: the
identity will name how many samples lapsed.

**What a run does.** It builds the isolated optimized app under a fresh
HOME/TMPDIR/ZDOTDIR, `exec`s the resolved absolute btop in the owned pane so the
PTY has exactly one foreground process, waits until the device's live `stty size`
reports the canonical 179x66, activates the app, then holds one arrow key with
CGEvent input at the host's own repeat cadence -- pressed before the profiler
starts recording and released only after it stops.

**What makes a run valid.** The bounded modes grade themselves and exit nonzero
if they cannot stand behind what they recorded: the profiler window must lie
wholly inside the held key, the profiler must have parsed samples, the app must
have submitted damage, it must have stayed frontmost and fully presented for
every sampled instant of the measured interval, and its drawing must be of the
same order as the input it was sent -- at least one damage sample per four
delivered key events. That last gate is the only one that crosses the seam
between "input was posted" and "the app drew": every other gate grades one side
alone, so a run whose keystrokes never reached the app passes all of them while
profiling btop's idle repaint. A `trace` additionally proves its template
exported a time-profile table. Missing measurement is never reported as
zero -- a section that could not be proved is absent from the identity and its
reason is listed in `capture.invalidReasons`. **An invalidated run still writes
its bundle**; that list is what you act on.

**Two of those gates also divide by the measured interval**, because a count
above zero says only that an observer existed. Foreground/presentation samples
must reach 5/s of the profiler window, and parsed profiler samples must reach
5/s as well. The app samples focus on its own 100 ms wall-clock timer -- not on
the draw path, which would make the sample rate a function of the activity being
measured -- so a healthy run measures ~10/s (measured: 227 samples over a 20.6s
window) whatever its frame rate, and the floor still passes a run whose main
thread was unavailable for half the window. Neither floor grades how fast the
app drew: damage topology deliberately has no per-second floor, because a low
draw rate is the finding the diagnostic exists to report, and the honest
normalizer for drawing is the stimulus that asked for it -- the
draws-per-key-event ratio above. Together the two answer different failures: a
main-thread hang stops the focus sampler too, so it surfaces as too few samples
for the interval rather than as a clean, thinly observed one.

**Artifacts** land in the same `.build/terminal-benchmark-profiles/<run>/` as
every other profile. `identity.json` is extended in place -- there is no second
provenance file -- with the btop executable path and version, effective config
path and digest, owned btop pid/PTY/geometry, input mechanism and permission,
measured stimulus legs and repeat cadence, the profiler/stimulus overlap,
topology and presentation coverage deltas, the stimulus-response ratio, machine
state, and the capture verdict. The presentation and profiler coverage sections
each also carry `measuredIntervalSeconds`, `samplesPerSecond`, and the floor
they were graded against, so a bundle says how densely it was observed and not
only that it was. `loop` additionally publishes `btop-stimulus-live.json` with the
direction and start of the leg it is currently holding, so an agent attaching its
own profiler can bracket and validate its own window.

**This workload can never decide anything.** It is refused by `benchmark-quick`,
`benchmark-confirm`, `benchmark-memory`, calibration, and every other
decision-bearing path, and every artifact it writes carries
`decisionEligible: false`. Its content is whatever processes happen to be running,
so two runs are not comparable and `sample`'s counts are not whole-process CPU.
Use it to find out *where* time goes in a real interactive TUI; use a calibrated
workload to decide whether a change helped.

Two limits worth knowing before you read a result. The stimulus follows the
host's own key-repeat settings and records them, so event rates differ between
machines. And a loop leg can reach the end of a short process list and idle out
the rest of its 10 seconds -- loop issues no coverage verdict at all, which is
why an attaching agent must validate its own window.

## Read a profile without Instruments

Every profiling mode writes `profile-report.json` and `profile-folded.txt`
beside its raw artifact and prints a per-thread and top-self-frame summary to
stdout, so a run is readable end to end with no GUI step. The `.trace` bundle
opens only in Instruments.app and its `--toc` export carries no samples; the
`time-profile.xml` written next to it is the actual sample rows, and it is what
the report parses.

The JSON holds totals, per-thread and per-binary shares, the hottest self and
inclusive frames, and the hottest stacks. `profile-folded.txt` is the standard
folded format -- feed it to `flamegraph.pl` or speedscope unchanged.

Re-report an artifact you already have, including one captured before the
report existed, with `just benchmark-report <dir>`. It accepts a profile
directory, a `.trace` bundle (which it exports first), an exported XML, or a
`sample.txt`. Pass flags through as one quoted argument:
`just benchmark-report <dir> '--state Running --thread Main --top 40'`.

### State a profile's costs per frame, not per second

`sample` and `trace` modes also write `frame-accounting.json`, which is how a
profile share becomes a per-frame cost:

```
cost per frame = (node share x on-CPU total) / (drawsPerSecond x traceSeconds)
```

The app publishes a running count of **every** draw and plan-publish -- not only
the ones a measured block accepts, since a `loop`-mode app never completes a block
-- and the profiling script snapshots it before the profiler attaches and after it
detaches.

**Use `measured.drawsPerSecond`; do not use `measured.draws` as the draw count
during the trace.** Both snapshots necessarily sit outside the profiler's window
and a profiler spends seconds attaching and saving, so the counted window
overshoots: 20.1 s counted for a 12 s trace, 67% long (`research/17/F11`). The artifact
separates `measured` from `estimated` and carries that warning in its own text.
The rate is only a valid conversion because these workloads are sustained and
steady-state; nothing here would notice if one started trending. Without it a
trace cannot be normalized per frame at all -- the available frame-count proxies
(`__open`, `iokit_user_client_trap`, `mach_msg2_trap`) disagree by 1.7x.

One reading trap, and it is the reason the thread filter exists: `sample`
captures every thread whether or not it is on-CPU, so an idle app's report is
mostly `__workq_kernreturn` and `mach_msg2_trap`, and every thread's share
converges on an equal slice. Those are parked threads, not cost. Filter to the
thread you care about before reading shares. `xctrace`'s Time Profiler records
running samples only, so its shares need no such correction.

## Profile memory

Two instruments, and picking the wrong one is the most expensive mistake in this
section. They answer different questions and neither substitutes for the other:

| Question | Tool |
| --- | --- |
| Is something growing without bound? | `just benchmark-memory` |
| What does terminal state cost, and did my change shrink it? | `just terminal-memory-probe` |

**`benchmark-memory` cannot answer the second question.** Asked to confirm a
~22 MB saving it reported the *fixed* build as larger than the leaky one. Two
reasons, both structural rather than bad luck: a memgraph is one sample of a
quantity that sawtooths as buffers compact, and the GUI app's IOSurface
compositing churned 50 MB over the same window -- more than twice the effect. It
is a leak detector. Use it as one (`research/15/F6`).

### `just terminal-memory-probe` -- exact, headless, deterministic

Feeds a payload matrix -- empty, full screen, and a 10K-line scrollback in plain,
unicode, styled, and mixed content -- to a fresh `Terminal` with no GUI, no
renderer, and no sampling, then reports `Terminal.memoryCensus`: exact
`MemoryLayout` stride arithmetic, not malloc buckets and not process pages. Two
runs print identical census numbers, so a before/after diff is a real comparison.

```
just terminal-memory-probe                                # full matrix at 179x66
just terminal-memory-probe "--json"                       # machine-readable
just terminal-memory-probe "--payload scrollback-plain"   # attributable footprint
just terminal-memory-probe "--columns 80 --rows 24"
just terminal-memory-probe "--payload scrollback-plain --vmmap"   # dirty allocator pages
just terminal-memory-probe "--chunk 0"                    # single-shot feed: parse spike, not resident cost
```

The probe executable lives in `lib/TerminalHostTools`, not `lib/TerminalCore`. It
shells out to `/usr/bin/vmmap` through `Process`, which does not exist off the
Mac, and `TerminalCore` declares iOS support for every target it holds. Its
measuring code -- `TerminalMemoryProbeSupport`, which is what the numbers come
from -- stayed in `TerminalCore` and is unchanged. Only the package path moved:
`just terminal-memory-probe` is still the entry point, and a direct build is
`swift build -c release --package-path lib/TerminalHostTools --product
TerminalMemoryProbe`.

It reports cell bytes, bytes per cell, row allocations, and the content shape
that sizes representation work -- styled cells, distinct styles, multi-scalar
spills, hyperlink cells, and content identities.

Retained per-cell census fields count stored arena cells, not cells synthesized
by the width-dependent display fold, so those retained counts are width-free.

Three traps. **Only a `--payload` run has an attributable footprint delta**: in a
full-matrix run all payloads share one process and the allocator reuses pages a
previous payload freed, so every delta after the first understates its payload.
Census numbers are exact either way. And **a payload can silently stop
exercising what it is named for**: the mixed payload originally concatenated
three blocks, so at the production budget only the last survived eviction and
`scrollback-mixed` measured byte-identical to `scrollback-styled`. If you add a
payload, assert its composition at a depth that actually evicts.

And **the probe feeds in 4 KB chunks on purpose** -- do not "simplify" it to one
`feed` call. `Terminal.feed` materializes one action per input token for the whole
call, so a single-shot 620 KB feed allocates ~37 MB of transient blocks that land
in the footprint delta and look exactly like resident cost. That mistake put
coverage at 0.35 when the true figure is 0.87, and it survived a
competing-interpretations pass before `--chunk` caught it (`research/15/F7`). The
census is chunk-invariant and a test pins that, so chunking costs nothing.

For the split between live bytes, bucket rounding, and allocator slack, use
`--vmmap`: it shells out to `vmmap --summary` *while the terminal is still
resident* and prints the malloc regions, where DIRTY is what the footprint
charges. Do not try to derive that split from `MallocHeapSnapshot.bytesAllocated`
-- that is reserved address space, ~20 MB of which exists before a byte is fed,
and differencing it against footprint yields numbers that come out negative.

One rule for anything you build on top: **do not assert on a heap delta in a
test.** `mallocHeapSnapshot()` reads the whole process, and the test runner runs
suites in parallel, so a neighbour's allocations land in your window -- a draft
test read 76 MB of "overhead" that belonged to other suites. Delta claims belong
to the probe binary, which owns its process.

`Terminal.memoryCensus` is public, so a one-off question does not need the probe
-- call it from a test. It exists precisely so that measuring the grid no longer
means widening `private` members and reverting, which is how the censuses in
research doc 12 were taken and why none of them can be re-run.

### Before you shrink `GridCell`

Four rounds of this took the cell 72 -> 32 bytes (`research/15/F10`,
`research/15/F14`, `research/15/F15`).
Three rules came out of it, and each cost a wrong measurement to learn.

**A smaller cell is not a smaller row.** What the process pays is the malloc
bucket the row's cell array lands in, not `columns * stride`. Between ~43 and 56
bytes a 179-column row costs the *same*, so `F12`'s narrowing reached stride 48,
was worth -26% at 80 columns, and **cost 1.8 MB at 179** -- the budget charged
less while the allocator charged the same, so it admitted 15% more rows for
nothing. It was implemented, measured, and reverted, then retaken unchanged once
`D4` fixed what the budget charged. Check both widths, and check the bucket
before predicting the win.

**Field order is worth as much as a field.** Swift lays stored properties out in
declaration order and never reorders them, so the widest-aligned member belongs
first. In `F15` the reorder alone moved nothing (48 -> 48) and the id alone
reached only 40; together they reached 32. Measure `MemoryLayout.stride` on the
candidate rather than reasoning about it -- reasoning about it was wrong there.

**The stride is also the cache-line alignment, and 32 divides 64.** This is the
one that stopped the series. Doc 16 reached stride 24 with zero interior padding
-- worth +19% history at 179 columns and +49% at 80, with the malloc bucket
moving at *both* widths, which no earlier shrink managed -- and it was reverted
because `incremental-mixed` came back `slower` in two independent confirm runs
(+1.95%, +3.39%). At stride 32 a 64-byte line holds exactly two cells and every
cell is line-aligned; at 24 they straddle, so a per-cell read that touched one
line sometimes touches two. The sign splits by access pattern, not by workload:
bulk sequential work (`scrollback-stream`, `terminal-feed`) got *faster* from the
smaller working set while scattered draw reads got slower. Treat 32 as a resting
point. A candidate stride that does not divide 64 needs the paired benchmark
before anything else, and 20 is no better than 24 on this axis.

**Stride 16 cleared the gate after row traffic changed.** The 2026-08-24 ROW-2
retry made the live cell the arena's word plus two sentinel ids, with cluster
payloads owned by the live row. `benchmark-confirm baseline=04b7a1d1` measured
`terminal-feed` faster by 29.58%, `scrollback-stream` faster by 22.74%, and
`incremental-mixed` down 5.28% on its descriptive, uncalibratable reading
(artifact `.build/terminal-benchmark-comparisons/confirm/73c8912baa7f-0000`).
`retained-browse` was faster by 30.50%, not the expected equivalent control;
the retained arena bytes did not change, but live projected-cell work still
benefited from the representation. The exact memory probe measured stride 16
at both widths. Its live-screen term halved from 378,048 to 189,024 bytes at
179x66 and from 61,440 to 30,720 bytes at 80x24. No payload's
`multiScalarAllocationCount` rose. The earlier stride-24 result still binds:
the useful property is that the stride divides 64, not merely that it is small.

**Moving a field out of the cell can make the write path faster, not slower.**
`F11` counted 9-23 million style writes per corpus and predicted an intern table
would charge every one. It does not, because every cell write sources its style
from the SGR pen: cache the id on the pen, invalidate in `didSet`, and the write
sites store four bytes where they used to copy nineteen. Plan time fell 6-9%.
The general form: if a field is written per cell but *changed* per mode switch,
the indirection belongs on the thing that changes.

### `just benchmark-memory` -- the leak detector

`just benchmark-memory scrollback-stream 90 15` runs the same isolated workload
and polls `footprint` on an interval, writing `memory-report.json`: the whole
footprint curve, growth from baseline to final, a least-squares bytes-per-second
rate, and per-category growth. The third argument is the warmup, and growth is
measured only after it -- scrollback is intentionally bounded and the caches
intentionally fill, so baselining at launch reports the design working as a leak
on every run. `seconds` must exceed the warmup.

It also brackets the measured window with two memory graphs and leaves
`heap --diffFrom` output in `heap-diff.txt`, which names the classes behind any
growth. Capturing a graph suspends the target briefly; that is why there are two
rather than one per interval, and one more reason these numbers stay diagnostic.

This is deliberately not leak detection. `leaks` reports only unreachable
allocations, and the failures this codebase actually produces -- scrollback
retaining past its bound, a cache that never evicts, damage snapshots
accumulating -- are all reachable from a live root. `leaks` prints zero for
every one of them while the footprint climbs.

Read the two artifacts in order, because the heap diff answers a narrower
question than it appears to. It lists allocations present at the end that were
not in the baseline graph, which for a workload churning through a bounded ring
is mostly replacement, not accumulation: a flat 42-second `scrollback-stream`
run grows 0.1 MB in footprint while its diff reports 25 MB of new
`_ContiguousArrayStorage<GridCell>` nodes. Those are the ring's rows being
replaced. Establish from `growthBytes` and `growthBytesPerSecond` that something
grew, then use the diff to name it. Reading the diff first invents a leak.

## Microbenchmarks

`just benchmark-draw` and `just benchmark-draw-app` measure CoreText drawing and
localized real-app draw cost. Their output is diagnostic: it is unpaired, it is
not recorded, and it cannot support a cross-session regression claim. Use them
to inspect a hot path, then decide with `benchmark-quick`.

### `just benchmark-headless-draw` -- paired, and precise where the GUI benchmark is not

This one **is** paired, and it is the exception to "decide with `benchmark-quick`"
for one specific question. It builds two draw arms as dynamic libraries from two
`TerminalCore` checkouts, loads both into a single process, and alternates their
batches ABBA.

    just benchmark-headless-draw                        # A/A control on this tree
    just benchmark-headless-draw 8 /path/TerminalCore   # 8 rounds against a checkout

Parameters are positional -- they carry defaults, so `rounds=8` does not bind.

**Three content workloads, one per executor path**, selected with the script-level
`--workload` flag (`python3 ./scripts/terminal-headless-draw-compare.py
--workload <name> ...`), because the justfile recipe passes only rounds and a
checkout. `btop-shaped` (the default) is dense sprite art the executor draws as
rects and which reaches CoreText zero times. `text-shaped` is printable ASCII,
which measures the batched `CTFontGetGlyphsForCharacters` plus
`CTFontDrawGlyphs` fast path. `fallback-shaped` is CJK, kana, CJK Extension B
and `a`-plus-combining-mark clusters, none of which the base face's cmap maps or
the ASCII batch can carry, so every one of them goes through the shaped-cluster
cache -- the path research 40 owns and the other two workloads never touch. It
was named for what that path used to be: an attributed string and a `CTLine` per
cell per frame, which research 40 replaced with one typesetting per (face,
cluster) and a batched submission (`40/F3`). A change to one path is invisible to
the other two workloads, so name the workload in any claim.

**Why it exists.** `incremental-mixed` under `benchmark-quick` can no longer
resolve a 3% change: the optimized main thread is ~96% idle during a block, macOS
lowers its clock, and no collection-side fix removed it. Batching draws past a
400 ms floor holds this benchmark's thread near 100% occupancy so the governor
never demotes it, and interleaving cancels the drift that remains. Paired SD is
~0.7% against the GUI benchmark's 3.98% degraded and 1.49% at its best.

**What it cannot see, which is the important part.** The timed region is
`drawRenderFrame` on a row-indexed plan, including selection of its restricted
rows. It does **not** cover damage *generation* -- which rows `setNeedsDisplay`
and AppKit's dirty-rect coalescing mark. A change that dirties too much looks
free here. That question stays with `benchmark-quick` on `incremental-mixed`,
whose coarse verdict is still the only one that sees it.

**Its A/A precision is not its precision on a revision pair.** Against itself it
holds ~0.7% paired SD and a mean within 0.1% of zero, but an A/A control cannot
reveal how much worse a real revision pair is, because there both arms hold
identical code. **Treat ~0.5-1% as the honest resolution for a revision claim,
not the A/A figures.** That range is measured over 18 cold rebuilds of one
revision pair, and decomposes into rebuild-to-rebuild SD of 0.25-0.37% (every
rebuild produces a distinct dylib -- Swift release builds are not
byte-reproducible here -- and averaging runs shrinks this term) plus a residual
order bias of ~+0.3% that averaging does *not* shrink, which is why ~0.5% is a
floor rather than a starting point. A shift of ~0.3% between two of your runs is
therefore expected, not evidence that something broke, and re-running needs no
fresh A/A control to interpret.

**A claim needs both directions, which is why the recipe passes
`--both-directions` whenever a candidate checkout is given.** A real difference
reverses when the arms swap slots; an order bias does not. The report splits them
into `realEffectPercent` (claimable) and `orderBiasPercent` (diagnostic), and the
direction runs are themselves scheduled ABBA, because running forward first every
time puts it immediately after the rebuild and reintroduces the asymmetry.
**Read `orderBiasPercent` before believing `realEffectPercent`**: it should sit
near zero, and if it is comparable to the effect the measurement is asymmetric
and neither direction is trustworthy.

**One decision rule is frozen, for `fallback-shaped` only.** Every report carries
a `decision` block: for that workload it states the rule -- `realEffectPercent`
from one `--both-directions` invocation at 8 rounds per direction, at +/-1.00%,
valid only when `orderBiasPercent` is below 2.5% -- and reads the run against it.
A run that missed the frozen cell (wrong round count, an order bias at or above
the guard) reads `invalid` rather than carrying a verdict, and a single-direction
run of that workload reads `descriptive`: it decides nothing at any magnitude,
because this arm carries a +1.0 to +1.7% slot bias that only swapping the arms
removes. The threshold is a false-positive floor from ten A/A invocations, not a
screened detection cell, so a reading under about 3% is descriptive too. The
other workloads have no frozen rule, and their `decision` block says so;
`--threshold` stays caller-supplied and is reported apart, under
`callerThreshold`. The rule and its evidence:
[docs/research/40-per-cell-coretext-typesetting/decisions.md](../docs/research/40-per-cell-coretext-typesetting/decisions.md)
`D1`.

**Two traps, both enforced in code rather than left to memory.** The arms must
compile under different Swift module names, because Swift classes register with
the ObjC runtime, which dedups by name across images even under `RTLD_LOCAL` --
a collision makes both arms run one arm's code while still printing plausible
numbers. And each `TerminalCore` checkout must keep that exact directory
basename, since SwiftPM derives a path dependency's identity from it. Run the
default A/A control after any change to the harness; a control that does not sit
near 0% is the signal that one of these has broken.

Evidence, limits and the pilots behind all of this: F21-F25 in
[docs/research/8-benchmark-variance-regression.md](../docs/research/8-benchmark-variance-regression.md).

### Keep the observer out of the profile

`TerminalBenchmarkObserver` runs on the draw path, so its own cost shows up in
every sample profile and inside `scrollback-stream`'s wall clock. It once cost
more main-thread time than the drawing it exists to measure -- 18% of the thread
in `full-screen-content-churn` and 22% in `full-screen-incremental-mixed-churn`,
against 3.3% and 3.9% now. Three invariants keep it there; treat a profile where
the observer is prominent again as a regression in the instrument, not a finding
about the app.

- **Marker detection never rebuilds the frame as a `String`.** It goes through
  `TerminalBenchmarkMarkerScanner`, which scans the plan's scalars in place.
  `scripts/tests/terminal-benchmark-harness_test.sh` fails if a `frameText`
  helper reappears.
- **The scan crosses the module boundary as one concrete call.** SwiftPM does
  not specialize a library's generics for another module, so handing the runs
  over as a lazy generic sequence replaced String cost with type-metadata and
  unspecialized-iterator cost of the same size. `scan(_ plan:)` takes the whole
  `RenderFramePlan` for that reason.
- **Acknowledgments are bare `open`/`close`, not `FileManager.createFile`,**
  which does a protected-temporary-file write plus `rename` for what is a
  zero-byte existence flag.

`TerminalBenchmarkMarkersTests` is the only automated cover for detection
semantics, since `DanTermAppTests` does not build with
`DANTERM_TERMINAL_BENCHMARK` and so never compiles the observer; it checks the
scan against a transcription of the replaced implementation. Changing detection means changing
that test, and `just test-terminal-benchmark-gui` is what proves the
acknowledgments still flow.

## Choose the benchmark boundary from the profile

Use a real application or interactive scenario to discover the concrete hot
operation, then reduce that operation into a deterministic workload for routine
optimization. Preserve the properties the profile shows are relevant, such as
PTY bytes, read chunk boundaries, update cadence, snapshot consumption, or
drawing. Do not assume a core microbenchmark represents an app regression when
the observed cost sits outside the core.

Then pick the narrowest paired workload that still contains the measured
bottleneck, using the workload ladder table above. A change that should affect
the core and the app can be confirmed at both boundaries with
`benchmark-confirm`.

## Investigate and report before optimizing

Profile workloads in an order driven by the reported problem, starting with the
workload nearest the observed symptom. Collect at least two textual profiles
before treating a sampled stack as a stable bottleneck. Use a Time Profiler
trace when samples cannot distinguish CPU cost from scheduling, actor
contention, or main-thread stalls.

Before changing code, report the findings to the user and pause to brainstorm
the solution. The report should contain:

- The workload at the bottleneck's narrowest valid boundary.
- Profiles collected and their artifact paths.
- Top concrete bottlenecks, ordered by expected impact.
- Evidence for each bottleneck: hot functions, own-time or sample share, thread,
  call path, and whether it appeared across profiles.
- Any important uncertainty or competing interpretation.
- Two or three candidate solutions for the leading bottleneck.
- Tradeoffs and correctness risks for each candidate.
- The agent's recommended first experiment and why it is the smallest useful
  test of the hypothesis.

Do not present broad areas such as "rendering is slow" as findings. Name the
repeated concrete work and its call path, for example: every incremental update
rebuilds the complete render plan, or every visible cell creates a separate
CoreText line.

Do not implement an optimization until the user has had an opportunity to
review the evidence and choose or revise the proposed direction.

## Make an instrument report its own coverage

Every metric here must be able to say "not measured" separately from "measured
zero". An instrument whose blind spot renders as `0` reports the reassuring
answer exactly when it is blind, and nothing downstream can tell the difference
-- so the failure is silent and always in the direction that ends the
investigation early.

That rule and the rest of the measurement discipline these commands rest on --
emit a count beside every aggregate, a missing field is not a zero, read a gate
from the code that owns it, a screen is not a freeze, give every comparison a
control the change cannot reach -- are in
[measurement-discipline.md](measurement-discipline.md). Read it before building
a new metric, freezing a decision rule, or acting on a difference between two
numbers.

## Performance optimization index

The engine began with intentionally straightforward implementations. This
index records the places where profiling justified additional complexity so a
future reader can distinguish deliberate performance machinery from incidental
cleverness. Percentages are approximate reductions in median duration measured
when each change landed, relative to the code immediately before it rather than
to the original naive baseline. They are historical orientation, not
reproducible measurements or permanent performance guarantees; a current claim
comes from `just benchmark-quick` / `just benchmark-confirm`.

- **[Bounded damage bitset](../plans/impl/2026-07-22-1736-terminal-core-feed-throughput-recovery.md)
  -- about 20% faster core feed.** A reusable viewport-
  row bitset replaced per-scalar `Set<Int>` allocation, hashing, and union while
  preserving the public `TerminalDamage` value. The trade-off is separate
  internal and consumer-facing damage representations, with set materialization
  deferred until drain.
- **[Packed Unicode lookup and cached look-behind class](../plans/impl/2026-07-22-1736-terminal-core-feed-throughput-recovery.md)
  -- about 31% faster core feed after the damage change.** One generated
  two-stage lookup replaced repeated binary searches for width, emoji
  properties, and grapheme-break class, and the segmenter now retains the
  preceding class. The trade-off is a larger generated table and a less direct
  classification path.
- **[Generation counters for change detection](../plans/impl/2026-07-22-1736-terminal-core-feed-throughput-recovery.md)
  -- no measured core-feed gain on styled redraw.** Monotonic generations
  replaced whole-`Terminal` copies for pending-work detection and repeated
  O(history) string comparisons for recovery notifications. Styled redraw was
  about 1% slower than the preceding result, within the role of this slice as a
  scrollback-specific fix. The saved results do not include an immediately
  preceding scrollback run, so no isolated scrollback percentage is claimed.
  The trade-off is explicit mutation accounting and conservative history-change
  signaling.
- **[Inline single-scalar grid cells](../plans/impl/2026-07-22-1736-terminal-core-feed-throughput-recovery.md)
  -- about 2% faster core feed than the prior best result.** Empty and
  single-scalar clusters stay inline while multi-scalar graphemes spill to an
  array. The trade-off is a specialized three-case storage representation and
  more involved upgrade and downgrade paths.
- **[Sparse AppKit damage retention](../plans/impl/2026-08-01-2219-preserve-sparse-appkit-terminal-damage.md)
  -- about 65% less direct draw time and 8% less whole-process CPU in the final
  two-distant-row acceptance run.** The view retains and merges exact engine
  damage until `draw(_:)`, then clips both the frame plan and graphics context
  to maximal contiguous sparse-row spans instead of AppKit's bounding dirty
  rectangle. Per-row clip rectangles initially doubled CPU during controlled
  btop scrolling; span coalescing restored CPU to equivalent or better than the
  parent and remained no slower at the 17-span maximum for the measured 179x66
  grid. The trade-off is an explicit view-owned full-invalidation path plus
  benchmark-only topology accounting; the percentages describe a controlled
  distant-row workload, not a calibrated general verdict.

## Optimize safely

### Measure pane-tape observer tax

Use the dedicated descriptive topology before and after changing the pane-tape
follow path:

    just benchmark-pane-tape-observer-tax baseline=<revision>

The run compares fresh apps at 0, 1, 4, and 8 raw followers over the committed
`scrollback-stream` corpus. It reports followed-minus-unfollowed PTY drain and
end-to-end block time, follower completion, owner-queue time with its sample
count, and follow fence, push, synchronization, and state-pairing counts. It
rejects incomplete followers and mismatched corpus byte totals. The report is
descriptive until this topology has its own A/A calibration; it issues no
verdict and does not borrow the `scrollback-stream` threshold.

Note the pre-change revision before you start -- that is the baseline the
comparison needs. Change one dominant path at a time, protect the behavioral
invariant with structure-insensitive tests, run the relevant package tests and
`just test`, then run `just benchmark-quick baseline=<pre-change revision>
workload=<workload>` and let the paired result accept, reject, or revise the
experiment. Record its decision-bearing values in the commit or plan.

## Artifacts

- Paired comparison evidence, one directory per invocation:
  `.build/terminal-benchmark-comparisons/<mode>/<run>/`.
- Pane-tape observer-tax evidence:
  `.build/pane-tape-observer-tax/<run>/`.
- Cached immutable arm source and build products:
  `.build/terminal-benchmark-arms/`.
- Per-run app logs and measurement evidence:
  `.build/terminal-benchmark-runs/<run>/artifacts/`.
- Identity, harness log, textual profiles, traces, exported trace data, an
  `nm` symbol listing, and a copy of the symbol-bearing executable:
  `.build/terminal-benchmark-profiles/<run>/`.

Everything above lives under the disposable `.build/` tree that `just clean`
removes. Nothing is committed, and no command appends to a durable record.

## GUI contract proof

`just test-terminal-benchmark-gui` is the opt-in proof that the measured
workloads still hold their GUI-dependent contract: canonical geometry, complete
window containment and non-occlusion throughout measured blocks, per-workload
reset and damage evidence, process-scoped activation, and ownership limited to
the apps the run launched. It needs a logged-in GUI session with Accessibility
access and takes several minutes, so it stays out of `just test` alongside
`just test-terminal-viability`.
