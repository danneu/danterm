# Terminal Performance Benchmarking and Profiling

Use these commands when measuring or optimizing DanTerm's real terminal path.
They build an optimized app with a unique bundle identity and isolated home,
temporary, and IPC state. Each command owns only the app it launches and never
selects or terminates another DanTerm instance.

## Measure first

Run `just benchmark backend=swift` for repeated corpus measurements. It appends
unprofiled results to `benchmarks/results/terminal-app.jsonl` and reports deltas
only against the latest committed entry with the same backend, fixture,
machine, macOS version, display scale, Swift toolchain, release configuration,
geometry, schema, and profiling state. Use `backend=ghostty` to measure the same
PTY workload against Ghostty. A deliberate Swift-to-Ghostty comparison requires
every compatibility field except backend to match.

The committed corpus covers plain scrolling, long-line wrapping, mixed Unicode,
dense style and truecolor changes, full redraw and scroll-region updates, and a
pinned Alacritty Vim recording. Run one case with `just benchmark-one <workload>
backend=swift`; workload names and provenance live in
`benchmarks/fixtures/terminal-app.json`.

Producer-write elapsed ends when the producer's final PTY write returns. It
measures PTY backpressure and drain performance, not parsing or rendering.
Final-draw elapsed is Swift-only and measures from app-side start-marker parsing
through completion of the draw that consumed the acknowledged final frame.

## Choose a profiler

Start with `just benchmark-sample plain-scrolling seconds=15`. The textual
profile is quick to search and usually identifies a dominant stack. Use
`just benchmark-trace plain-scrolling template="Time Profiler" seconds=30`
when call-tree filtering, thread timelines, or richer Instruments data is
needed. Both attach by numeric pid from the isolated harness identity file;
they do not find a process by name or automate Instruments.app.

Use `just benchmark-loop plain-scrolling backend=swift` when attaching another
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
