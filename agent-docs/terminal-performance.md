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
all five. Both require an explicit baseline revision -- anything `git rev-parse`
accepts. Neither infers it from `HEAD`, merge-base, history, or the candidate.

The common case is an uncommitted experiment measured against the commit it
started from:

    just benchmark-quick baseline=HEAD workload=content-churn

Nothing is stashed, committed, or checked out to do this. The baseline is any
revision `git rev-parse` accepts -- `HEAD~5`, a SHA, a tag, a branch -- so the
working tree can be compared against an arbitrarily old point. The wider the
gap, the more the verdict attributes to everything in between rather than to
your change alone. If you have committed since starting the experiment, `HEAD`
is no longer where you began; note the pre-change revision before you start and
name it explicitly.

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
| `scrollback-stream` | Did sustained output get cheaper end to end? | A fresh app and terminal session per block replays 25,000 numbered lines through a real PTY, timed to the final completed draw. | PTY chunking, actor hops, snapshot delivery, backpressure, scrolling, or retention is hot. |
| `content-churn` | Did replacing screen *content* get cheaper? | 50 serialized full-screen 179x66 frames; text changes every frame, style is frozen. | Glyph lookup, shaping, or text-run construction is hot. |
| `style-churn` | Did replacing *attributes* get cheaper? | 50 serialized full-screen frames; text is frozen, only truecolor fg/bg change. | Attribute or color handling is hot and no new glyphs are involved. |
| `incremental-mixed` | Does small damage stay small? | 50 serialized updates touching 4 rows of an already-settled dense screen. | You suspect localized updates are doing full-window work. |

Every draw block is serialized: one write, then wait for that exact completed
draw before the next write. Nothing coalesces, so the per-draw number is a real
draw rather than an amortized one.

The three draw workloads deliberately freeze one axis each. A change that helps
`content-churn` but not `style-churn` moved glyph work; one that helps both
moved something under them. `incremental-mixed` is the only workload that can
catch damage-scoping regressions, and it carries the most pairs (6 in `confirm`)
because it is also the noisiest.

Each mode lays out its complete position-balanced schedule at the frozen pair
count before the first block runs, then applies the frozen median symmetric rule
exactly once: `faster`, `slower`, `equivalent`, or `inconclusive`. There is no
early stopping, no rerun of a valid block, and no partial decision. A single
invalid block -- lost geometry, an occluded window, battery power, thermal
pressure, low-power mode, missing damage or draw acknowledgment -- invalidates
the whole invocation; the evidence is kept, but a new decision needs a fresh
complete run.

### Read the result

    content-churn: faster (-3.20% symmetric median of 2 pairs)

| Verdict | Meaning | Do this |
| --- | --- | --- |
| `faster` / `slower` | The estimate cleared that workload's frozen directional threshold. | Believe it. Record the decision-bearing values in the commit or plan. |
| `equivalent` | The estimate sits inside the equivalence band. | The change did nothing measurable *at this boundary*. Before concluding it did nothing at all, confirm the workload actually contains the cost you moved. |
| `inconclusive` | Neither cleared the threshold nor fell inside the band. | Escalate `quick` to `confirm`, which measures more pairs at a tighter threshold. Do not rerun `quick` hoping for a different roll -- the pair count is frozen precisely so results cannot be shopped for. |

### The plan-time line is decided separately

    content-churn: equivalent (+0.11% symmetric median of 2 pairs)
        plan time: -18.40% symmetric median of 2 pairs (faster)

    incremental-mixed: equivalent (+0.31% symmetric median of 2 pairs)
        plan time: -22.10% symmetric median of 2 pairs (descriptive, no verdict -- uncalibrated)

The draw verdict and the plan line are decided separately and can disagree; a
change that plans faster while drawing slower reports exactly that.

The three serialized-draw workloads decide on `drawNanosecondsPerDraw`, which
brackets only clipping and drawing inside `draw(_:)`. Frame planning does not
run there -- `planFrame` runs on the PTY-output path, when a pane applies child
output -- so **the draw verdict cannot see a planner change at all**. It is not
that planning is a small term in that number; it is not in that number.

That is not a small blind spot. Measured on this machine at `4ecb032`, one
accepted draw costs about 540k ns to draw against 501k-510k ns to plan on
`content-churn`, and about 86k ns to draw against 66k ns to plan on
`incremental-mixed`.

Planning is the **smaller** cost on both, and it shrinks by ~7.6x when damage goes
from 66 rows to 6, because **the planner is damage-scoped**. Production planning
runs through `PaneFramePlanner.planFrame(for:presentation:damage:)`, which replans
only the rows `damage` marks and copies an undamaged row's runs forward from the
retained frame instead of re-inspecting its cells. (`RenderFramePlanner`'s
free-function `planFrame(for:presentation:)` does pass `damage: .full`, but it is
not the pane path -- reading it as the production entry point is the likely origin
of the superseded claim below.)

> Superseded text, kept because a reader may be working from it: this section
> previously said one draw cost ~0.9M ns to draw and ~1.16M ns to plan on
> `content-churn`, ~0.16M/~1.15M on `incremental-mixed`, that planning was the
> larger cost in both, and that "the planner plans the whole viewport
> regardless". All four claims were wrong. Damage scoping landed in `8188b9a`,
> three days after the text was written, and the figures were 1.7x-17.5x too
> high. See `docs/research/17-cpu-profile-sweep.md` `F5` (the mechanism) and
> `F12` (the replacement numbers). **Date a performance number before planning
> against it.**

So each of those workloads also reports a plan-time estimate, normalized over
the same 50 accepted draws:

- In `quick`, `content-churn` and `style-churn` carry **their own calibrated
  rule** -- 2 pairs at +/-2.5%, equivalence band 1.0% -- and report a `faster` /
  `slower` / `equivalent` / `inconclusive` classification for plan time, decided
  independently of the draw verdict. The thresholds come from a plan-time A/A
  series, not from the draw thresholds, because the two metrics have different
  noise.
- Everything else reports a bare percentage marked `no verdict`, and that is a
  measured conclusion rather than unfinished work:
  - `incremental-mixed` plans only a handful of damaged rows, so its per-draw
    plan quantity is small and jittery: A/A spread SD 5.75% over a
    -6.6%..+12.0% range. No threshold clears the gates.
  - `confirm` claims a 3% effect at 4 pairs, and no threshold reaches it while
    holding A/A false positives under 1% -- the best cell measured either
    0.0198 false positives or 0.633 detection.

  Do not read those percentages as decisions, and do not borrow a calibrated
  workload's threshold for them.

A plan rule is pinned to the pair count its mode already collects. Plan time is
measured on the very same blocks as the draw metric, so it cannot buy itself a
longer schedule, and a rule is refused rather than applied when the series
length does not match the count it was calibrated at.
- The line is **absent whenever either arm lacks it**, which is the normal case
  when the baseline revision predates the timer. A missing plan line never
  invalidates the draw verdict.
- Judging a planner change means reading this line. Judging a drawing change
  means reading the draw verdict. A change that moves only planning will
  correctly read `equivalent` on all three draw verdicts.

### The third reported quantity: whole-process CPU per accepted draw

The draw verdict times elapsed work between two points on the **main thread**, so
work on any other thread is invisible to it at any size. That is not a corner
case: `docs/research/17-cpu-profile-sweep.md` `F6` found the largest single cost
in the app -- Core Animation recomputing every glyph's bounds while replaying the
display list -- living entirely in that blind spot. **Do not quote its 16.8%
figure**: that share came from a stimulus republishing every glyph on screen 120
times a second, and `17/F17` measured the same node at **27.3 us/draw against
801.0 -- 29.3x smaller -- under a damage-scoped draw**, with `17/F3`'s 1.85% on
`scrollback-stream` agreeing. The mechanism is real and elastic (`17/F16`, 95.1%
of linear); the magnitude was the benchmark's. The blind spot is the durable
point here, not the number that was found in it.

So the three serialized-draw workloads also report
`processCPUNanosecondsPerDraw`: CPU time summed over **every thread**, taken from
`task_info(TASK_ABSOLUTETIME_INFO)` and charged to each accepted draw as the delta
since the previously accepted one. Measured at `4ecb032` (`17/F12`):

| workload | draw (main thread) | process CPU (all threads) | ratio |
| --- | ---: | ---: | ---: |
| `content-churn` | ~540k ns | ~4.9M-5.2M ns | ~9.0x-9.5x |
| `style-churn` | ~546k ns | ~5.2M ns | ~9.4x |
| `incremental-mixed` | ~86k ns | ~2.0M ns | **~23x** |

**The draw verdict therefore constrains about one ninth of what a frame costs on
the churn workloads, and about one twenty-third on `incremental-mixed`.** An
`equivalent` draw verdict is a true statement about the draw bracket and a nearly
empty one about total cost. Read this line before concluding a change was free.

**And the churn workloads are frame-rate-capped, not CPU-bound.** `17/F16` traced
`full-screen-content-churn` at 179x66 and at 80x25 -- a 5.9x change in per-frame
glyph work -- and the draw rate was 119.10/s and 119.32/s, pinned at the built-in
120Hz panel's refresh in both. The glyph-bounds cost that scaled 5.62x between those
two runs was being paid *while every frame still landed*. Two consequences when
reading any result on these workloads: a CPU reduction is not a throughput win
because there is no throughput headroom to win, and a cost living off the main
thread has no metric here that can decide it -- not the draw rule (wrong thread),
not the frame rate (pinned), and not process CPU (uncalibratable, point 3 above).

Four things it is not, each of which invites a misreading:

1. **It is not latency.** Work moved off the critical path onto an idle core reads
   as neutral. It answers "did we stop doing work" -- the right question for
   replay cost and the only one that maps to battery.
2. **It is not a per-draw bracket.** The interval between two accepted draws
   contains everything the process did in it: this draw, the *previous* draw's
   asynchronous replay, parsing, planning, and the observer's own acknowledgment
   writes. That width is deliberate -- replay does not finish inside the draw that
   queued it, so any narrower bracket would exclude the thing worth measuring --
   but it means the series is meaningful in aggregate, not at a single index.
3. **It cannot be calibrated, so it never carries a verdict.** It is reported
   through `UNCALIBRATED_BLOCK_METRICS`, which consults no rule table; there is no
   code path by which it can classify. That is settled, not pending: the A/A
   screening pass was run (`17/F15`, 24 paired A/A blocks per workload) and **no
   threshold clears the accuracy gates on any workload in either mode**. The
   false-positive gate and the detection gate cross with no overlap -- the closest
   case, `content-churn`/`quick`, reaches a 0.0000 false-positive rate only at a
   +/-3.0% threshold where detection has already fallen to 0.8320 against a 0.90
   gate. Its paired A/A spread: SD 1.88% (`content-churn`), 3.52% (`style-churn`),
   8.75% (`incremental-mixed`, one pair at -27.63%). Because an auxiliary metric
   rides the deciding metric's own blocks, it cannot buy more pairs, which is the
   only knob that would close the gap.

   **What you may still do with it** (`17/D6`): use a co-movement to *undermine* a
   draw verdict -- if plan time and CPU shift by the same amount on a change with
   no causal path to planning, that is arm-level drift, and `17/F14` caught a
   spurious `faster` exactly this way. Use a CPU move with no draw move as a reason
   to profile for off-main-thread work. Never use it to *confirm* a win, and never
   quote a difference as an effect: on `style-churn`, 5 of 24 pure-noise pairs sit
   at or below -3.02%.
4. **It includes the instrument**, which on `incremental-mixed` is a large term --
   the observer's acknowledgment `open()` alone was 9.8% of that workload's on-CPU
   total (`17/F2`).

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
proposes nothing is a real answer -- see point 3 above and `17/F15`.

An invalid invocation is not a verdict and never becomes one by retrying. It
means a stated measurement condition failed, so fix the condition -- put the
machine on AC power, stop covering or unfocusing the benchmark windows, let it
cool -- and run again from scratch. While a comparison runs, leave the machine
otherwise idle: the windows must stay visible and unoccluded for every measured
block, and competing load biases both arms unequally.

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

The thresholds are calibrated for a fully visible, unoccluded 179x66 window on
one MacBook on AC power. Changing the machine, geometry, workload contract, or
decision rule requires recalibrating before directional claims resume.

Run `quick` for the routine question. Run `confirm` when the quick result is
close, the change crosses workload boundaries, or the decision warrants the
stronger five-workload evidence.

## When to measure

Running a comparison on your own initiative is welcome -- you do not need to be
asked. What follows is about reading the result honestly, not about permission.

Know what each mode can see before you spend one. `quick` decides at 2 pairs per
workload with directional thresholds of 3.8-4.5% and a 1.0% equivalence band;
`confirm` uses 2-6 pairs at 1.85-2.5% with a 0.75% band. So `quick` cannot
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
run one, and an `equivalent` at `confirm`'s thresholds is real evidence. Two
things to keep straight when you do. First, a comparison answers "is this tree
different from that tree" -- it is not a regression watch, and there is no stored
history to watch against. Second, an `inconclusive` or an invalid invocation
leaves you exactly where you started: say so plainly rather than reporting that
the change was benchmarked and looked fine.

When the honest answer is that you have no hypothesis yet, profile the
suspicious path instead. That is the cheaper question and usually the one you
actually have.

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
planning and drawing that share the app's main thread.

Both CPU modes take an Instruments template, but only the CPU templates record
an exportable table. Recording with `Allocations` or `Leaks` succeeds and then
exports nothing, so `benchmark-trace` checks the trace's schemas and fails with
the list rather than leaving an empty report behind. For memory, use the mode
below.

Use `just benchmark-loop scrollback-stream backend=swift` when attaching another
command-line diagnostic tool. It prints the identity JSON -- pid, workload,
backend, executable SHA-256, Mach-O UUID, source identity -- and continues until
interrupted. Stop it with Ctrl-C; the harness then terminates only its own app.

If attachment is refused, grant Developer Tools access to the invoking terminal
in System Settings and retry. The benchmark app is ad-hoc signed with
`get-task-allow`; the harness verifies the entitlement before launch. `xctrace`
also uses `--no-prompt`, so a permission problem fails with diagnostics instead
of waiting for UI.

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
overshoots: 20.1 s counted for a 12 s trace, 67% long (`17/F11`). The artifact
separates `measured` from `estimated` and carries that warning in its own text.
The rate is only a valid conversion because these workloads are sustained and
steady-state; nothing here would notice if one started trending.

Without this, a trace cannot be normalized per frame at all. Before it existed,
the three available frame-count proxies (`__open`, `iokit_user_client_trap`,
`mach_msg2_trap`) disagreed by 1.7x, which forced `17/F5` to rest on commit
history instead of on its own measurement.

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
is a leak detector. Use it as one. (`docs/research/15-memory-footprint.md`, F6.)

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

It reports cell bytes, bytes per cell, row allocations, and the content shape
that sizes representation work -- styled cells, distinct styles, multi-scalar
spills, hyperlink cells, and content identities.

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
competing-interpretations pass before `--chunk` caught it (doc 15's F7). The
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

Four rounds of this took the cell 72 -> 32 bytes (doc 15, `F10`/`F14`/`F15`).
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

**Why it exists.** `incremental-mixed` under `benchmark-quick` can no longer
resolve a 3% change: the optimized main thread is ~96% idle during a block, macOS
lowers its clock, and no collection-side fix removed it. Batching draws past a
400 ms floor holds this benchmark's thread near 100% occupancy so the governor
never demotes it, and interleaving cancels the drift that remains. Paired SD is
~0.7% against the GUI benchmark's 3.98% degraded and 1.49% at its best.

**What it cannot see, which is the important part.** The timed region is
`drawRenderFrame` on an already-clipped plan. So it does **not** cover damage
*generation* -- which rows `setNeedsDisplay` and AppKit's dirty-rect coalescing
mark -- nor `clipFramePlan`'s own cost. A change that dirties too much looks free
here. Those questions stay with `benchmark-quick` on `incremental-mixed`, whose
coarse verdict is still the only one that sees them.

**Its A/A precision is not its precision on a revision pair.** Against itself it
holds ~0.7% paired SD and a mean within 0.1% of zero. Comparing two *different*
revisions is worse, and an A/A control cannot reveal by how much, because there
both arms hold identical code. **Treat ~0.5-1% as the honest resolution for a
revision claim, not the A/A figures.** That range is measured, over 18 cold
rebuilds of one revision pair, and it decomposes into:

- **Rebuild-to-rebuild SD of the estimate, 0.25-0.37%.** Every rebuild produces a
  distinct dylib -- Swift release builds are not byte-reproducible here -- so
  re-running is not free of it. Averaging several runs shrinks this term.
- **A residual order bias of ~+0.3%**, reported per run as `orderBiasPercent`. It
  is slot-bound, not revision-bound, so counterbalancing already removes it from
  `realEffectPercent`; it is not load order, which was tested and exonerated.
  Averaging does *not* shrink this term, which is why ~0.5% is a floor rather
  than a starting point.

**Re-running does not need a fresh A/A control to interpret it.** A/A shifts
across rebuilds by the same amount the revision pair does, so the rebuild floor
belongs to the instrument rather than to cross-revision comparison. A shift
between two of your runs is expected at ~0.3%, not evidence that something broke.

**A claim needs both directions, which is why the recipe passes
`--both-directions` whenever a candidate checkout is given.** A real difference
reverses when the arms swap slots; an order bias does not. The report splits them
into `realEffectPercent` (claimable) and `orderBiasPercent` (diagnostic). The
direction runs are themselves scheduled ABBA -- forward, reverse, reverse,
forward -- because running forward first every time puts it immediately after the
rebuild and reintroduces the asymmetry.

**Read `orderBiasPercent` before believing `realEffectPercent`.** It should sit
near zero. If it is comparable to the effect, the measurement is asymmetric and
neither direction is trustworthy; that is the tool reporting its own failure
rather than you having to suspect it.

**No decision rule is frozen for it.** It reports statistics; `--threshold` is
caller-supplied and labelled as such in the report. A frozen rule needs a
screening pass a human signs off, per the calibration rules above.

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
semantics, since `app/` has no test target; it checks the scan against a
transcription of the replaced implementation. Changing detection means changing
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

Four instances cost real time on this code, all the same shape:

- A mutation harness grepped for `✘`, which Swift Testing does not emit (it uses
  `􀢄`). Caught mutations rendered as clean runs.
- `cumulativePlanNanoseconds` is promoted from pending to accepted only when a
  draw is accepted, and `scrollback-stream` accepts none. It reads `0.00` on the
  one workload whose sustained output the number was wanted for.
- The fence-stall counter first shipped latched at drain time, so a delivery
  whose publish the synchronized-output guard suppressed lost its stall
  entirely -- understating precisely the full-screen TUI floods worth measuring.
- A flake rate sampled from single-test runs (~1 failure in 60) instead of
  full-suite runs (~3 in 14). Twenty clean runs in the wrong denominator prove
  nothing, at any sample size.

Practical rules:

- Emit a count beside every aggregate. `cumulative...Nanoseconds` without its
  sample count cannot distinguish "no cost" from "no samples". Assert a floor on
  that count where the number drives a decision.
- Check that a new field is actually present in the artifact before reading its
  value. Both benchmark blind spots above were guards inherited by copying a
  neighbouring metric's emit site.
- Prefer the continuous quantity to the thresholded one. A pass/fail at a 60s
  time limit is one bit; the test's wall time underneath it shows a distribution
  shifting before any verdict flips. The read-turn cap moved the termination
  test from 7.70s to 0.82s and the PTY suite from 116s to 12.7s -- visible in
  timings long before it would have been visible in a pass rate.
- Verify a weakened or cheapened measurement still detects what it was built to
  detect, by reintroducing the defect and confirming it goes red.
- Derive nothing that one more run could measure.
- Give every comparison a control the change cannot reach, measured in the same
  session. A read-turn constant in `TerminalPTYHost` cannot touch the 679 pure
  `TerminalCore` tests, so those are the control for any claim about the PTY
  suite's wall time. This is what separates an effect from a machine state: a
  9.1x PTY "speedup" read out of two archived gate logs evaporated when the
  control showed the untouched core suite had moved 13x across the same pair.
  Measured properly, interleaved and same-session, the real effect was 24%.
  Every comparative claim that survived this investigation came from
  contemporaneous interleaved arms; every one that fell came from comparing logs
  across sessions. Subtracting medians of two
  comparisons put the read-turn cap's cost at ~+1%; measured directly against
  the same baseline it was +3.69%.

## Optimize safely

Note the pre-change revision before you start -- that is the baseline the
comparison needs. Change one dominant path at a time, protect the behavioral
invariant with structure-insensitive tests, run the relevant package tests and
`just test`, then run `just benchmark-quick baseline=<pre-change revision>
workload=<workload>` and let the paired result accept, reject, or revise the
experiment. Record its decision-bearing values in the commit or plan.

## Artifacts

- Paired comparison evidence, one directory per invocation:
  `.build/terminal-benchmark-comparisons/<mode>/<run>/`.
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
