# Terminal Performance Benchmarking and Profiling

Use these commands when measuring or optimizing DanTerm's real terminal path.
They build an optimized app with a unique bundle identity and isolated home,
temporary, and IPC state. Each command owns only the app it launches and never
selects or terminates another DanTerm instance.

## Measure first

Run `just benchmark` for repeated Swift corpus measurements, or `just
benchmark-one <workload>` for one workload with the same multi-iteration
aggregation. Each command reports current timings and compatible committed
deltas, then asks whether to save the completed run. Pass `save=1` to save
without prompting or `save=0` to decline up front. Saving uses the already
completed run; it never reruns the benchmark. Confirmed unprofiled results enter
`benchmarks/results/terminal-app.jsonl`. The Mac must be connected to AC power
before either benchmark command will start.

Benchmark recipe options use `name=value` spelling and may appear in any
order, for example `just benchmark backend=ghostty save=1` or
`just benchmark-one workload=unicode-wrapping backend=swift save=0`.

Every run converges the terminal to an 80x24 grid before emitting workload
bytes. Override the target for a diagnostic run with
`DANTERM_TERMINAL_BENCHMARK_COLUMNS` and
`DANTERM_TERMINAL_BENCHMARK_ROWS`; both must be positive integers. A target
that the window cannot reach fails before measurement and reports the required
and observed grids instead of recording a result.

Deltas use the latest committed entry with the same backend, fixture, machine,
macOS version, display scale, Swift toolchain, release configuration, geometry,
schema, profiling state, and iteration count. Omitting `backend` selects Swift.
Use `backend=ghostty` explicitly only to establish or refresh the Ghostty
baseline: after changing the pinned Ghostty version, benchmark fixtures,
protocol or schema, or an environment compatibility field. A deliberate
Swift-to-Ghostty comparison requires every compatibility field except backend
to match.

The committed corpus stays deliberately small. Each workload has one dominant
performance question recorded alongside its identity and provenance in
`benchmarks/fixtures/terminal-app.json`; tests pin those questions so fixture
changes cannot silently change what a result is meant to measure:

- `scrollback-stream`: sustained output, viewport scrolling, and retention.
- `styled-screen-redraw`: complete styled TUI frame replacement.
- `unicode-wrapping`: complex text width, wrapping, and rendering.
- `incremental-screen-updates`: localized TUI mutation without full-screen work.

The imported Alacritty Vim recordings remain terminal-correctness fixtures, not
primary real-app performance workloads.

Producer-write elapsed ends when the producer's final PTY write returns. It
measures PTY backpressure and drain performance, not parsing or rendering.
Final-draw elapsed is Swift-only and measures from app-side start-marker parsing
through completion of the draw that consumed the acknowledged final frame.
The `styled-screen-redraw` producer intentionally runs without per-frame
acknowledgments, so intermediate terminal states may coalesce. It measures
consumption and backpressure rather than presentation of every submitted state.

Use `just benchmark-redraw` when the question is the cost of presenting every
complete 80x24 state. It runs content-only, style-only, and mixed pseudo-TUI
churn by default; select one with `workload=full-screen-content-churn`,
`workload=full-screen-style-churn`, or `workload=full-screen-mixed-churn`.
Options `save=0|1` and `comment=` use the same completion-before-confirmation
contract as the corpus suite. Each measured update waits for its exact
completed draw, every draw must damage all 24 rows, and sequence metadata stays
in the terminal title rather than visible grid content.

The full recording run excludes warm-up and calibration, then runs 15 fresh
optimized app batches. The content-only, style-only, and mixed workloads use at
least 50 ms of cumulative synchronous draw work per batch; at their ordinary
speed this still provides roughly 150-250 completed draws in each independent
sample without paying for thousands of serialized producer acknowledgments.
The slower symbol workloads retain the 400 ms floor. `target_ms=` explicitly
overrides either default for diagnostics.
It reports min/median/max draw count, nanoseconds per draw, cumulative draw
time, and dirty rows per draw. Confirmed unprofiled results enter
`benchmarks/results/terminal-redraw.jsonl`; deltas require an exact match on
fixture, method, machine, macOS, display scale, Swift toolchain, release
configuration, 80x24 geometry, batch count, and profiling state. The duration
floor remains recorded as methodology but is not a compatibility key because
the reported comparison is normalized nanoseconds per completed draw.

## Choose a profiler

Start with `just benchmark-sample scrollback-stream seconds=15`. The textual
profile is quick to search and usually identifies a dominant stack. Use
`just benchmark-trace scrollback-stream template="Time Profiler" seconds=30`
when call-tree filtering, thread timelines, or richer Instruments data is
needed. Both attach by numeric pid from the isolated harness identity file;
they do not find a process by name or automate Instruments.app.

Use `just benchmark-loop scrollback-stream backend=swift` when attaching another
command-line diagnostic tool. It prints the identity JSON and continues until
interrupted. The file records the exact pid, workload, backend, app binary, and
run diagnostics. Stop it with Ctrl-C; the harness then terminates only its own
app.

## Choose the benchmark boundary from the profile

Use a real application or interactive scenario to discover the concrete hot
operation, then reduce that operation into a deterministic workload for routine
optimization. Preserve the properties the profile shows are relevant, such as
PTY bytes, read chunk boundaries, update cadence, snapshot consumption, or
drawing. Do not assume a core microbenchmark represents an app regression when
the observed cost sits outside the core.

Choose the narrowest benchmark level that still contains the measured
bottleneck:

| Level | Measures | Appropriate when |
|---|---|---|
| Core microbenchmark | Parser, grid mutation, and damage calculation | `Terminal.feed` or other pure terminal-state work is hot. |
| Session/package benchmark | PTY chunking, actor hops, snapshot delivery, and backpressure | Scheduling, chunk boundaries, or snapshot production is hot. |
| Optimized app benchmark | Render planning, CoreText work, and AppKit drawing | Main-thread planning or rendering is hot. |

When practical, replay one neutral deterministic fixture at multiple levels. A
fast core benchmark alongside a slow app benchmark is useful evidence that the
optimization belongs above the core; an app rerun also confirms that a core
improvement affects the user-visible path. Name the fixture for the behavior it
exercises, such as incremental styled-row selection, rather than for the
application that exposed it.

## Investigate and report before optimizing

Before choosing a workload, inspect `benchmarks/results/terminal-app.jsonl` for
the latest mutually compatible Swift and Ghostty results. Compare only entries
whose compatibility fields match as described above, and use their median
producer-write values to rank regressions; compare final-draw values only
between backends that expose that metric.

Profile workloads in an order driven by the current compatible benchmark
results. Start with the largest regression or the workload most relevant to the
reported problem. When there is no stronger signal, use this default order:

1. `styled-screen-redraw` -- full-frame planning and drawing.
2. `incremental-screen-updates` -- damage propagation, coalescing, and PTY
   backpressure.
3. `unicode-wrapping` -- decoding, width calculation, wrapping, and glyph work.
4. `scrollback-stream` -- sustained mutation, retention, copying, and viewport
   updates.

Collect at least two textual profiles before treating a sampled stack as a
stable bottleneck. Use a Time Profiler trace when samples cannot distinguish
CPU cost from scheduling, actor contention, or main-thread stalls.

Before changing code, report the findings to the user and pause to brainstorm
the solution. The report should contain:

- Workload and compatible unprofiled baseline.
- Profiles collected and their artifact paths.
- Top concrete bottlenecks, ordered by expected impact.
- Evidence for each bottleneck: hot functions, own-time or sample share, thread,
  call path, and whether it appeared across profiles.
- Which benchmark phase the evidence explains: producer backpressure, final
  draw, or both.
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

After agreeing on a direction, change one dominant path at a time. Protect the
behavioral invariant with structure-insensitive tests, run the relevant package
tests and `just test`, then rerun the same unprofiled workload under compatible
conditions. Profiled runs are diagnostic evidence and must not be saved as
benchmark history.

If attachment is refused, grant Developer Tools access to the invoking terminal
in System Settings and retry. The benchmark app is ad-hoc signed with
`get-task-allow`; the harness verifies the entitlement before launch. `xctrace`
also uses `--no-prompt`, so a permission problem fails with diagnostics instead
of waiting for UI.

## Artifacts and history

- Committed history: `benchmarks/results/terminal-app.jsonl`.
- Serialized complete-draw history:
  `benchmarks/results/terminal-redraw.jsonl`.
- Completed runs awaiting confirmation: `.build/terminal-benchmark-staged/`.
  Only confirmed runs enter committed history; declined and failed partial runs
  remain here for inspection or manual promotion.
- Per-run app logs and measurement evidence:
  `.build/terminal-benchmark-runs/<run>/artifacts/`.
- Identity, harness log, textual profiles, traces, exported trace data, an
  `nm` symbol listing, and a copy of the symbol-bearing executable:
  `.build/terminal-benchmark-profiles/<run>/`.

Profiled runs are diagnostic evidence only. They never enter committed history;
the history command refuses to run when profiling is active. Preserve a useful
profile directory while investigating, but do not commit it.

## Optimize safely

Use the profile to choose one hot path, then run the behavioral tests for the
layer changed: parser and terminal state changes belong in `TerminalCore` tests,
PTY or backpressure changes in `TerminalPTY`, and damage/render planning changes
in their focused package tests plus the AppKit UI harness when visible geometry
is affected. Run `just test` as the repository gate. Finally, rerun the
unprofiled benchmark under compatible conditions. Only the unprofiled result is
valid performance history.
