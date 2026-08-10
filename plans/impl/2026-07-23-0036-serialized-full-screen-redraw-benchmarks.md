# Serialized full-screen redraw benchmarks

## Problem and desired outcome

The existing `styled-screen-redraw` workload sends terminal states as fast as
the PTY accepts them, so the app may coalesce intermediate states. It does not
isolate the repeated complete draws observed while navigating a TUI such as
lazygit.

Add deterministic optimized-app benchmarks that require every submitted
full-screen state to finish drawing. Record a release-mode baseline for the
current Swift renderer before using the benchmarks to guide optimization.

## Decision

Use one deterministic 80x24 ASCII pseudo-lazygit screen for three controlled
workloads:

- `full-screen-content-churn`: every row's text changes while style regions
  remain stable.
- `full-screen-style-churn`: text remains unchanged while truecolor foreground
  and background styles change across every row.
- `full-screen-mixed-churn`: text and styles both change across every row.

Serialize frames by submitting one update and waiting for that exact frame to
finish drawing before submitting the next. Sequence tracking stays outside the
visible terminal content so it does not contaminate the style-only workload.

Generalize the existing `benchmark-draw-app` draw-acceptance harness for these
workloads and persistence rather than creating a parallel optimized-app draw
harness.

Expose `just benchmark-redraw` with optional `workload=`, `save=0|1`, and
`comment=` arguments. With no workload it runs all three variants. Preserve the
existing blast-style workload, but clarify that it measures consumption and
backpressure with coalescing permitted rather than presentation of every state.
Update both `agent-docs/terminal-performance.md` and the fixture question in
`benchmarks/fixtures/terminal-app.json` so operator guidance and its pinned
contract agree.

Each workload uses an excluded warm-up and calibration followed by 15 fresh
optimized-app batches. Each measured batch contains at least 400 ms of
cumulative synchronous draw work. Report draw count, nanoseconds per draw,
cumulative draw time, and dirty rows per draw as min/median/max distributions.

Store results in dedicated append-only redraw history because direct Swift draw
metrics are not compatible with the producer and final-draw records in
`terminal-app.jsonl`. Compatibility includes fixture identity, benchmark
method, machine, macOS, display scale, Swift toolchain, release configuration,
80x24 geometry, batch count, duration floor, and profiling state.

After committing the benchmark implementation, run
`just benchmark-redraw save=1` against the unoptimized renderer and commit the
three baseline records separately.

## Invariants

- Every measured update produces exactly one acknowledged completed draw before
  the next update is submitted.
- Every measured draw damages all 24 rows.
- The screen stays populated without scrolling or last-column autowrap.
- Direct draw timing includes the complete synchronous view draw and excludes
  setup, calibration, acknowledgment waits, and app startup.
- Completed results are staged before save confirmation, profiled runs cannot
  enter history, and deltas compare only exactly compatible records.
- Renderer optimization and caching begin only after the baseline is recorded
  and reviewed.

## Proof obligations

- Prove that all three workloads populate 24 rows without scrolling or
  autowrap and exercise their declared content and style behavior.
- Prove that writes and completed draws alternate, no frame is skipped or
  acknowledged twice, and sequence tracking does not alter visible text.
- Prove that setup and calibration are excluded and that an unexpected draw
  count or dirty-row count fails the run.
- Prove that calibration meets the duration floor, aggregation uses every
  expected batch, compatibility rejects mismatched environments, and saved
  history contains the exact staged bytes.
- Run the focused benchmark tests and `just test` before collecting the release
  baseline from the committed benchmark implementation.

## Non-goals and accepted constraints

- Ghostty comparison is excluded because direct completed-draw instrumentation
  exists only for the Swift backend.
- Fixed-rate responsiveness and dropped-frame measurement are deferred; these
  benchmarks isolate per-frame rendering cost.
- Unicode shaping remains covered by the existing Unicode workload. These
  redraw benchmarks use ASCII to isolate content and style churn.
- Accepted risk: the existing localized-draw workload remains history-less
  because it retains its current role as a local acceptance diagnostic; this
  plan's persistent baselines cover the three new full-screen workloads.

## Implementation discretion

- Exact pseudo-lazygit wording and palette are left to implementation, provided
  the workload invariants and fixture identities remain stable.

## Commit progress

- [x] 1. Add serialized full-screen redraw benchmark harness
- [x] 2. Record Swift renderer full-screen redraw baselines
