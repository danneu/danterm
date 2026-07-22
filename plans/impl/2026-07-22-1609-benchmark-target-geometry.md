# Cross-backend comparable benchmark geometry

## Problem

The real-app benchmark measures each backend at whatever grid its font
metrics happen to produce in the fixed 1000x600 window: Swift 94x35,
Ghostty 99x31. Wrapping, scrolling, and redraw workloads all scale with
columns x rows, so Swift-vs-Ghostty comparisons are invalid. The
compatibility key already includes `geometry`, so today the two backends
can never even find a common baseline.

Evidence: the producer reports geometry from the PTY winsize
(`scripts/terminal-benchmark-producer.py`); each backend derives its grid
from view size / its own cell metrics (`app/SwiftTerminalSessionView.swift`
`synchronizeGeometry`, `app/TerminalView.swift` + `ghostty_surface_size`).

## Decision

Require a harness-chosen target geometry (default 80x24, overridable via
environment) for every benchmark run, both backends:

- The harness passes the target to the benchmark app; app-side,
  env-gated benchmark code resizes the window until the session's
  achieved grid equals the target. Each backend reports its achieved
  grid through a benchmark-only seam on `TerminalSession` (Swift: its
  tracked dimensions/metrics; Ghostty: `ghostty_surface_size`).
- The producer refuses to start measuring until the PTY reports exactly
  the target columns x rows, failing with a clear mismatch message after
  a bounded wait. This is the verification gate for both backends and
  both measure and loop modes.
- The harness independently asserts the emitted metrics carry the target
  geometry and fails the run otherwise.
- `geometry` stays in the compatibility key unchanged; history format,
  schema version, timing definitions, and existing committed history are
  untouched. Old natural-geometry baselines simply stop matching, by
  design.

## Invariants

- I1: A completed benchmark run's recorded geometry equals the requested
  target geometry, for both backends.
- I2: A run that cannot establish the target geometry fails before any
  measurement is recorded, with an error naming required and observed
  geometry.
- I3: Results measured at different geometry never produce a delta
  against each other; identical compatibility keys (including geometry)
  still match.
- I4: Producer-write and final-draw timing definitions are unchanged. The
  geometry gate completes before any workload bytes are emitted and
  before the producer's timing clock starts, in both measure and loop
  mode, so waiting for geometry is never inside a measured interval and
  never precedes a profile at the wrong grid.

## Proof obligations

- PO1 (I2/I4): behavioral test of the producer-side geometry gate —
  accepts a late-arriving match, rejects a persistent mismatch with an
  error naming required and observed geometry, and proves ordering: with
  a match that only arrives after several observations, no workload bytes
  are emitted and the timing clock has not started until the match, in
  both measure and loop mode.
- PO2 (I3): behavioral test that a geometry difference is not a
  compatible baseline and an identical geometry still is.
- PO3 (I1): an automated end-to-end test launches the benchmark app for
  each backend at a requested target geometry and asserts the geometry
  the run actually reports equals it. This is the only gate that proves
  app-side convergence works rather than merely being wired up; it may
  live in the GUI-dependent gate (`just test-ui`) if it needs a
  WindowServer.
- PO4 (I4): existing suite tests keep passing unchanged.

## Non-goals

- No change to benchmark timing definitions, schema version, or the
  committed `benchmarks/results/terminal-app.jsonl`.
- No general user-facing window-size-in-cells feature; enforcement is
  benchmark-build-only (`DANTERM_TERMINAL_BENCHMARK`).

## Accepted risks

- AR1: If the target grid is unreachable (window min size, tiny screen),
  the run fails rather than degrades; that is the intended behavior.
- AR2: The first saved runs after this change start a fresh baseline per
  backend at the target geometry (no compatible prior history).

## Implementation discretion

- Window-resize convergence mechanics (polling cadence, delta
  computation from achieved grid and cell size, attempt bounds).
- Exact env variable names carrying the target geometry.

## Critical files

`scripts/terminal-benchmark.sh`, `scripts/terminal-benchmark-producer.py`,
`scripts/terminal-benchmark-suite.py`, the benchmark-gated app code
(`app/TerminalBenchmark.swift` plus the two session views behind
`TerminalSession`), the benchmark script tests under `scripts/tests/`, and
`agent-docs/terminal-performance.md`.

## Verification

- The benchmark script test gates in `just test`, plus the new
  end-to-end geometry gate (PO3).
- Manual confirmation on a GUI session with AC power:
  `just benchmark-one plain-scrolling save=0` and the same with
  `backend=ghostty` both report the target geometry.

## Commit progress

- [x] 1. feat(benchmark): enforce comparable target geometry

## Implementation notes

- The harness gate and app-side convergence must land together: enabling the
  default 80x24 producer gate before the app can resize its session would make
  every real benchmark time out, so the original two slices were combined.
