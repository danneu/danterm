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

The workload ladder:

| Workload | Performance question |
| --- | --- |
| `terminal-feed` | Parsing, grid mutation, Unicode handling, damage policy |
| `scrollback-stream` | PTY backpressure, actor hops, snapshots, scrolling, retention |
| `content-churn` | Glyph lookup, shaping, text-run construction, content replacement |
| `style-churn` | Attribute, color, and style-only replacement |
| `incremental-mixed` | Localized content/style damage without full-window work |

Each mode lays out its complete position-balanced schedule at the frozen pair
count before the first block runs, then applies the frozen median symmetric rule
exactly once: `faster`, `slower`, `equivalent`, or `inconclusive`. There is no
early stopping, no rerun of a valid block, and no partial decision. A single
invalid block -- lost geometry, an occluded window, battery power, thermal
pressure, low-power mode, missing damage or draw acknowledgment -- invalidates
the whole invocation; the evidence is kept, but a new decision needs a fresh
complete run.

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

Choose the narrowest paired workload that still contains the measured
bottleneck:

| Level | Measures | Appropriate when |
|---|---|---|
| `terminal-feed` | Parser, grid mutation, and damage calculation | `Terminal.feed` or other pure terminal-state work is hot. |
| `scrollback-stream` | PTY chunking, actor hops, snapshot delivery, and backpressure | Scheduling, chunk boundaries, or snapshot production is hot. |
| `content-churn`, `style-churn`, `incremental-mixed` | Render planning, CoreText work, and AppKit drawing | Main-thread planning or rendering is hot. |

A change that should affect the core and the app can be confirmed at both
boundaries with `benchmark-confirm`.

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
