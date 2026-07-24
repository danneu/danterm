# Terminal Performance Benchmarking and Profiling

Use these commands when measuring or optimizing DanTerm's real terminal path.
They build optimized apps with isolated home, temporary, and IPC state. Each
command owns only the processes it launches and never selects or terminates
another DanTerm instance.

The question these commands answer is always "did this code change make the
relevant terminal path faster or slower?" -- never "is this faster than it was
last week". There is no benchmark history: every directional claim compares an
explicit baseline revision with the current working tree inside one machine
session, which is what cancels the machine drift that a stored record cannot.

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

Start with `just benchmark-sample scrollback-stream seconds=15`. The textual
profile is quick to search and usually identifies a dominant stack. Use
`just benchmark-trace scrollback-stream template="Time Profiler" seconds=30`
when call-tree filtering, thread timelines, or richer Instruments data is
needed. Both attach by numeric pid from the isolated harness identity file;
they do not find a process by name or automate Instruments.app.

Use `just benchmark-loop scrollback-stream backend=swift` when attaching another
command-line diagnostic tool. It prints the identity JSON -- pid, workload,
backend, executable SHA-256, Mach-O UUID, source identity -- and continues until
interrupted. Stop it with Ctrl-C; the harness then terminates only its own app.

If attachment is refused, grant Developer Tools access to the invoking terminal
in System Settings and retry. The benchmark app is ad-hoc signed with
`get-task-allow`; the harness verifies the entitlement before launch. `xctrace`
also uses `--no-prompt`, so a permission problem fails with diagnostics instead
of waiting for UI.

## Microbenchmarks

`just benchmark-draw` and `just benchmark-draw-app` measure CoreText drawing and
localized real-app draw cost. Their output is diagnostic: it is unpaired, it is
not recorded, and it cannot support a cross-session regression claim. Use them
to inspect a hot path, then decide with `benchmark-quick`.

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
