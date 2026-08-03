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
| `scrollback-stream` | Did sustained output get cheaper end to end? | A fresh app and terminal session per block replays 25,000 numbered lines through a real PTY, timed to the final completed draw. | PTY chunking, actor hops, snapshot delivery, backpressure, scrolling, or retention is hot. |
| `content-churn` | Did replacing screen *content* get cheaper? | 50 serialized full-screen 179x66 frames; text changes every frame, style is frozen. | Glyph lookup, shaping, or text-run construction is hot. |
| `style-churn` | Did replacing *attributes* get cheaper? | 50 serialized full-screen frames; text is frozen, only truecolor fg/bg change. | Attribute or color handling is hot and no new glyphs are involved. |
| `incremental-mixed` | Does small damage stay small? | 50 serialized updates touching 4 rows of an already-settled dense screen. | You suspect localized updates are doing full-window work. |
| `synchronized-frames` | Did absorbing a real TUI's output get cheaper when it coalesces its frames? | A fresh app and terminal session per block replays 95 captured btop frames through a real PTY, timed to the final completed draw. Every byte sits inside a `DECSET 2026` bracket. | Parsing, damage tracking, or the synchronized-output path is hot, or a change touches what happens while drawing is suppressed. |

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
        plan time: -18.40% symmetric median of 2 pairs (faster)

    incremental-mixed: equivalent (+0.31% symmetric median of 2 pairs)
        plan time: -22.10% symmetric median of 2 pairs (descriptive, no verdict -- uncalibrated)

The draw verdict and the plan line are decided separately and can disagree; a
change that plans faster while drawing slower reports exactly that.

The three serialized-draw workloads decide on `drawNanosecondsPerDraw`, which
brackets only clipping and drawing inside `draw(_:)`. Frame planning does not
run there -- `planFrame` runs on the PTY-output path, when a pane applies child
output -- so **the draw verdict cannot see a planner change at all**. It is not
that planning is a small term in that number; it is not in that number. So
judging a planner change means reading the plan line, and a change that moves
only planning correctly reads `equivalent` on all three draw verdicts.

Planning is the **smaller** cost, and it shrinks ~7.6x when damage goes from 66
rows to 6, because **the planner is damage-scoped**: production planning runs
through `PaneFramePlanner.planFrame(for:presentation:damage:)`, which replans only
the rows `damage` marks and copies an undamaged row's runs forward from the
retained frame. (`RenderFramePlanner`'s free-function `planFrame(for:presentation:)`
does pass `damage: .full`, but it is not the pane path.) Measured at `4ecb032`
(`17/F12`): `content-churn` ~540k ns to draw against 501k-510k to plan;
`incremental-mixed` ~86k against ~66k.

**No plan/draw ratio generalizes across workloads** -- it is a property of how
much damage a workload generates, not of the code -- so do not carry one from a
doc or a profile to a workload it was not measured on
(`docs/research/14-live-scroll-workload-profile.md` `F1`).

The plan estimate is normalized over the same 50 accepted draws, and only two
cells carry a rule:

- In `quick`, `content-churn` and `style-churn` have **their own calibrated
  rule** -- 2 pairs at +/-2.5%, equivalence band 1.0% -- and classify plan time
  independently of the draw verdict. Its thresholds come from a plan-time A/A
  series, not from the draw thresholds, because the two metrics have different
  noise.
- Everything else reports a bare percentage marked `no verdict`. That is a
  measured conclusion, not unfinished work: `incremental-mixed` plans a handful
  of rows, so its per-draw quantity is small and jittery (A/A SD 5.75% over
  -6.6%..+12.0%), and `confirm` claims a 3% effect at 4 pairs that no threshold
  reaches while holding A/A false positives under 1%. Do not read those
  percentages as decisions or borrow a calibrated workload's threshold for them.

A plan rule is pinned to the pair count its mode already collects -- plan time
rides the draw metric's own blocks, so it cannot buy a longer schedule, and a
rule is refused rather than applied when the series length does not match. The
line is **absent whenever either arm lacks it**, the normal case when the
baseline predates the timer; a missing plan line never invalidates the draw
verdict.

### `scrollback-stream` reports how its block splits into drain and draw tail

    scrollback-stream: equivalent (+0.10% symmetric median of 2 pairs)
        drain (baseline): 146.4 ms, 10.4 MB/s (1.52 MB corpus at 179x66; descriptive, no verdict)
        draw tail (baseline): 9.0 ms (5.8% of block)
        drain (candidate): 145.9 ms, 10.5 MB/s (1.52 MB corpus at 179x66; descriptive, no verdict)
        draw tail (candidate): 10.8 ms (6.9% of block)

`drain` is the time the producer spent writing the corpus into the PTY. Because
the producer blocks on `write()` once the buffer fills, that is the rate at which
the app drained it -- **the PTY throughput number**, reported per arm because it
is the marker you watch move between revisions.

**Read this before concluding a drawing change failed on this workload.** The
drain is ~96% of the measured block (median 95.7% over 368 archived blocks), so
the draw tail is ~4-7% and **a change touching only the draw path can move
`scrollback-stream`'s verdict by at most about 4%.** A flat verdict there is the
expected reading of a real drawing win, not evidence against it. That also means
the verdict has always been ~96% a throughput measurement wearing a draw
metric's name.

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
(`20/F10`). Read it as "how fast can we absorb a real TUI's output", and reach for
`content-churn` or `style-churn` for anything about drawing.

**It has no frozen rule.** `23/D4` demoted it to `CANDIDATE_WORKLOADS` and
removed its quick and confirm rules after fresh post-rewrite evidence refused
them (`23/F8`): the frozen `confirm 8p@2.15%` cell read 12-14% A/A false
positives against a 1% gate and 74-78% detection against 90%, and two
independent 48-pair screens each selected no cell. Its fixture, collector,
direct harness command, block contract, and candidate-screen path all remain
available for descriptive collection.

**Do not try to buy a tighter rule by lengthening the replay.** It was tried
(`20/F16`): at 1x/2x/3x the trimmed A/A pair SD is flat (1.30-1.72% / 1.65% /
1.62%), which is multiplicative noise. Lengthening also changes what the
workload measures -- the main-thread fence regime shifts at 2x, where 9 stalls
of ~16 ms become 1-2 of 126-266 ms.

Re-screen it with `scripts/terminal-benchmark-candidate-screen.py --workload
<name> --revision <rev>`, which searches pair count alongside threshold -- a
workload owns its blocks and so can buy more pairs, which is exactly what an
auxiliary metric cannot do (`17/F15`). It writes a report and never a rule.

### The third reported quantity: whole-process CPU per accepted draw

The draw verdict times elapsed work between two points on the **main thread**, so
work on any other thread is invisible to it at any size. That is not a corner
case: `docs/research/17-cpu-profile-sweep.md` `F6` found the largest single cost
in the app -- Core Animation recomputing every glyph's bounds while replaying the
display list -- living entirely in that blind spot.

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
   contains everything the process did in it: this draw, the *previous* draw's
   asynchronous replay, parsing, planning, and the observer's own acknowledgment
   writes. That width is deliberate -- replay does not finish inside the draw that
   queued it, so any narrower bracket would exclude the thing worth measuring --
   but it means the series is meaningful in aggregate, not at a single index.
3. **It cannot be calibrated, so it never carries a verdict.** It is reported
   through `UNCALIBRATED_BLOCK_METRICS`, which consults no rule table; there is no
   code path by which it can classify. That is settled, not pending: the A/A
   screening pass ran (`17/F15`) and no threshold clears the accuracy gates on any
   workload in either mode, because an auxiliary metric rides the deciding
   metric's blocks and so cannot buy the extra pairs that would close the gap.

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
run one, and an `equivalent` at `confirm`'s thresholds is real evidence. But an
`inconclusive` or an invalid invocation leaves you exactly where you started: say
so plainly rather than reporting that the change was benchmarked and looked fine.

When the honest answer is that you have no hypothesis yet, profile the
suspicious path instead. That is the cheaper question and usually the one you
actually have.

Two things that are not hypotheses, and have each cost real time here:

- **A profile share is not a trigger.** The draw path already fits the 60Hz
  frame budget (`docs/research/11-render-frame-budget.md` `F7`, `F8`), so "this
  function is N% of the draw" does not by itself justify a render optimization.
  Name what a user would observe differently, or leave it.
- **Date a number before you plan against it.** Every figure in this guide and
  in `docs/research/` is a measurement of one tree at one commit, and the commit
  that invalidates it does not come back to update the prose. This guide's
  plan/draw figures were once 1.7x-17.5x too high because damage scoping landed
  three days after they were written, and the stale claim kept a parked backlog
  item alive (`docs/research/17-cpu-profile-sweep.md` `F5`). Check the commit a
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
overshoots: 20.1 s counted for a 12 s trace, 67% long (`17/F11`). The artifact
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

That rule and the rest of the measurement discipline these commands rest on --
emit a count beside every aggregate, a missing field is not a zero, read a gate
from the code that owns it, a screen is not a freeze, give every comparison a
control the change cannot reach -- are in
[measurement-discipline.md](measurement-discipline.md). Read it before building
a new metric, freezing a decision rule, or acting on a difference between two
numbers.

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

`just test-terminal-btop-gui` is the matching opt-in proof for the live btop
diagnostic above. It runs a bounded `sample` and a `Time Profiler` `trace` and
requires each to come back with parsed samples, positive damage topology, a
contained overlap, and a live 179x66 PTY; it then steals the foreground
mid-capture and requires that run to be rejected, by exit status and by a
preserved reason naming the lapse; it watches `loop` turn a leg around; and it
checks that teardown left no stimulus arm running and did not signal an
unrelated btop it started alongside. It additionally needs `btop` on PATH and
Accessibility permission, and it drives four real profiling runs, so it is
slower still. Name phases to run one: `just test-terminal-btop-gui loop`.

Its judgments are pure functions graded against fixtures in
`scripts/tests/terminal_btop_gui_proof_test.py`, which does run in `just test` --
an opt-in proof whose rules are only exercised live would go green exactly when
the diagnostic breaks.
