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

The redraw suite excludes warm-up and calibration, then runs 15 fresh optimized
app batches with at least 400 ms of cumulative synchronous draw work per batch.
It reports min/median/max draw count, nanoseconds per draw, cumulative draw
time, and dirty rows per draw. Confirmed unprofiled results enter
`benchmarks/results/terminal-redraw.jsonl`; deltas require an exact match on
fixture, method, machine, macOS, display scale, Swift toolchain, release
configuration, 80x24 geometry, batch count, duration floor, and profiling
state.

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
