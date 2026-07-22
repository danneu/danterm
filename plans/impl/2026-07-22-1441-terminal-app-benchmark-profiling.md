# Terminal App Benchmarking and Agent Profiling

## Problem

DanTerm's Swift terminal engine has deterministic headless coverage but no
repeatable measurement of the real app path through PTY backpressure, parsing,
terminal state, damage, and drawing. Ad hoc commands such as
`/usr/bin/time -p jot 200000` measure when the producer finishes writing, not
when DanTerm has processed and drawn the final state -- under backpressure those
diverge, and that gap is where the Swift engine's slowness lives. There is also
no way for an LLM agent to profile the app without a human driving
Instruments.app.

The existing viability harness (`scripts/terminal-viability.sh`) already proves
the boundary this needs: an isolated, uniquely-identified, backend-selected app
bundle with isolated HOME/TMPDIR/IPC state, controlled via the `danterm` CLI
socket, observed via the env-gated characterization event log, and cleaned up
without touching a developer's live DanTerm session. The benchmark harness
reuses that boundary.

## Desired outcome

- Track the Swift engine's real end-to-end performance across commits, with
  results committed to the repo.
- See the performance cliff between the Swift engine and the libghostty backend
  on identical workloads.
- Let an LLM agent run a sustained workload, attach `sample` or `xctrace`,
  read the resulting profile, optimize, and re-measure -- with no human input.
- Give future agents one project guide that explains how to benchmark, profile,
  interpret results, preserve history, and validate an optimization safely.

## Decision

### Benchmark surface

- `just benchmark backend="swift"` -- run the full workload corpus against one
  backend; `backend="ghostty"` for the comparison run
- `just benchmark-one <workload> backend="swift"` -- one named workload
- `just benchmark-loop <workload> backend="swift"` -- sustained workload that
  runs until stopped, for external profiler attachment
- `just benchmark-sample <workload> seconds="15"` -- sustained Swift workload
  with a textual macOS `sample` profile of the app process
- `just benchmark-trace <workload> template="Time Profiler" seconds="30"` --
  same with a non-interactive `xctrace` recording plus exported symbol data

Benchmark recipes control only the isolated app they launch; they never touch
another DanTerm instance.

### Measurement contract

Each metric names one observable event and one clock source per endpoint;
endpoints of a single metric never mix clock domains.

- **Producer-write elapsed** (both backends): measured inside the producer
  process with its own monotonic clock, from immediately before its first
  workload write to the PTY to immediately after its final workload write
  returns. This is the only cross-backend metric; it measures PTY
  backpressure/drain performance only -- its endpoint proves the PTY accepted
  the final write, not that the app parsed or rendered the output -- and
  reports state that limit.
- **Final-draw elapsed** (Swift only): measured in the app's monotonic clock,
  from the app-side observation of the start marker in the incoming PTY byte
  stream (at parse time, before any drawing) to completion of the acknowledged
  final-state draw defined below. Ghostty results state this metric as
  unavailable.

The two are never conflated. Neither uses harness timestamps, process
launch/exit times, or draw-time observation of the start marker, so the
harness's own latency never enters a measurement.

Workload protocol and draw acknowledgment: each workload emits a unique
per-run start marker before its first workload byte and a completion marker
ordered after all measured output; the completion marker is the last bytes the
pane receives until measurement completes (the controlled shell configuration
suppresses trailing prompt or exit text). Draw acknowledgment is app-side and
env-gated like the existing characterization log, and binds to the identity of
the exact published frame actually consumed by the draw -- not to frame
publication or delivery, which AppKit display coalescing can supersede before
drawing. The acknowledged draw is the first completed draw whose consumed
frame contains the completion marker and the workload's expected final
terminal state, which the benchmark validates.

Results identify backend, commit, machine identity (hardware model and chip,
e.g. "MacBookPro18,3 / Apple M1 Pro", read from the system, not hardcoded),
macOS version, display scale, toolchain, build configuration
(optimized/debug), result-schema version, terminal geometry, fixture
identity, and whether profiling was active. All of these form the
compatibility key: a historical delta is presented only between entries whose
key matches, so a result from different hardware (a CI runner, a new laptop),
a macOS upgrade, a Retina-scale change, a schema revision, or a debug build
never forms a delta against existing history. Profiled runs are diagnostic
evidence and never enter history. Reports use distribution summaries (min/median/max over repeated
iterations), not one best run. Regressions are informational, never blocking.

### Corpus

No network or external-tool dependency at run time. Deterministic committed
byte-stream fixtures with recorded provenance:

- plain scrolling and long-line wrapping
- mixed Spanish, Chinese, combining-mark, and emoji output
- dense style and truecolor changes
- full-screen redraws and scroll-region updates
- one representative real application recording (reuse an existing committed
  tmux/Vim recording fixture)

The same fixture bytes and app configuration run against both backends.

### History

Results append to versioned machine-readable files under
`benchmarks/results/`, committed to the repo. Each entry carries the full
environment metadata above, so a later comparison can refuse incompatible
pairs. `just benchmark` prints the delta against the most recent compatible
committed entry. No CI workflow in this plan.

### Isolation, profiling, and artifacts

Each invocation launches an optimized build as an isolated app following the
viability-harness pattern: unique bundle identity, isolated filesystem and IPC
state, controlled shell configuration, stable window size, recorded geometry,
diagnostics preserved on failure, only run-owned resources removed. The
benchmark app is signed with the `get-task-allow` entitlement so `sample` and
`xctrace` can attach; a missing profiling permission produces an actionable
refusal, not an interactive prompt.

Sustained mode publishes machine-readable process and workload identity (pid,
workload, paths) to a file while it runs; the profiling recipes attach to that
exact pid. Profiling operates through `sample` and `xctrace` only -- no
Instruments.app UI automation. Profile artifacts record the workload and the
symbol-bearing binary needed to interpret them.

### Agent guidance

The implementation adds `agent-docs/terminal-performance.md` as the operating
guide for benchmark and profiling work, and links it from the topic-doc list in
`AGENTS.md` so agents are directed to read it before measuring or optimizing
terminal performance. The guide documents:

- when the fast textual `sample` profile is sufficient and when to use the
  richer `xctrace` Time Profiler recording
- that every benchmark/profiling command controls only its isolated app and how
  the exact target pid is selected
- where committed benchmark results, transient run diagnostics, textual
  profiles, traces, exported data, and symbol-bearing binaries are written
- that historical regression comparisons require the same backend while an
  intentional Swift-to-Ghostty comparison requires every compatibility field
  except backend to match
- that profiled timings are diagnostic and must never enter committed history
- that producer-write elapsed measures PTY backpressure/drain only, while
  final-draw elapsed is the Swift-only parse-to-acknowledged-draw metric
- the correctness tests appropriate to the changed parser, terminal-state,
  PTY, damage, or renderer path, followed by an unprofiled measurement under
  compatible conditions

## Commits

Narrow first; each commit vets an assumption before the surface grows.

1. **One workload, Swift only, both metrics.** The app-side marker-observation
   and draw-acknowledgment hooks (timestamped, env-gated, app layer only) plus
   a minimal harness that launches the isolated optimized app, runs the
   plain-scrolling workload, and reports producer-write elapsed and final-draw
   elapsed as JSON. `just benchmark-one` only. This vets the entire
   measurement design; if frame-identity draw acknowledgment doesn't hold up
   here, stop and rethink.
2. **Ghostty comparison.** `backend="ghostty"` support, final-draw reported as
   unavailable, side-by-side output. The cliff becomes visible.
3. **Committed history.** Result schema with environment metadata, append to
   `benchmarks/results/`, delta-vs-last-compatible reporting, and `just
   benchmark` running the (still small) corpus with repeated iterations and
   distribution summaries.
4. **Agent profiling and operating guide.** `benchmark-loop`,
   `benchmark-sample`, `benchmark-trace`, the pid/identity file,
   `get-task-allow` signing, the profiled-runs-never-enter-history guard,
   `agent-docs/terminal-performance.md`, and its `AGENTS.md` topic-doc link.
5. **Corpus expansion.** Remaining fixtures (unicode mix, styles, redraw and
   scroll-region, the reused application recording), each with provenance.

## Commit progress

Check a box only when the commit is landed (implemented, tested, committed).

- [x] 1. One workload, Swift only, both metrics
- [x] 2. Ghostty comparison
- [x] 3. Committed history
- [ ] 4. Agent profiling
- [ ] 5. Corpus expansion

## Invariants

- **I1:** A benchmark measures terminal output through a real DanTerm-owned
  PTY; redirected producer-only controls are never reported as terminal
  throughput.
- **I2:** Producer-write elapsed and Swift final-draw elapsed remain distinct
  measurements; each metric's endpoints are the named observable events and
  come from that metric's single clock domain.
- **I3:** Cross-backend reports compare only equivalent metrics and conditions;
  Ghostty is evidence, not a performance requirement.
- **I4:** Profiling targets only the isolated app by pid, and profiled timings
  never enter committed history.
- **I5:** Fixture identity and measurement environment travel with every
  result, so incompatible samples cannot form a regression claim.
- **I6:** Benchmarking and profiling add no timing, IO, or framework dependency
  to the pure TerminalCore layer; the sentinel hook lives in the app layer.

## Proof obligations

- **PO1:** A controlled workload yields ordered start-marker, producer-write,
  and acknowledged-draw evidence, and the acknowledged frame's terminal state
  is correct; the Ghostty run of the same workload omits the draw metric
  explicitly. Behavioral scenarios include: multiple frames published before a
  single AppKit draw (coalescing), and output following the workload body
  before suppression takes effect -- in both, acknowledgment names the frame
  actually consumed by the draw and that frame contains the expected final
  state. Covers I1-I3.
- **PO2:** Repeated identical runs aggregate valid distributions, and
  comparison rejects entries whose compatibility key differs in any component
  (fixture, geometry, backend, machine, OS, display scale, toolchain, build
  configuration, schema version, profiling state). Covers I3 and I5.
- **PO3:** `benchmark-loop` exposes the isolated target pid, sustains the
  workload for collection, yields a usable `sample`/`xctrace` artifact, and
  stops owned processes cleanly; a profiled run cannot append to history.
  The agent guide leads a fresh agent to the correct profiler for the task,
  identifies every result/artifact location, distinguishes both metric and
  comparison contracts, and names the relevant correctness-test and unprofiled
  re-measurement workflow. Covers I4.
- **PO4:** Interruption, invalid fixtures, and profiler failure preserve
  diagnostics and cannot mutate or terminate unowned state.
- **PO5:** Existing package tests, boundary checks, and purity lints remain
  green. Covers I6.

## Non-goals and accepted risks

- Input-to-photon latency and physical display scanout are non-goals; final
  draw means DanTerm's synchronous drawing work for the final state returned.
- Instruments.app GUI automation is a non-goal; `xctrace` is the supported
  non-interactive interface.
- CI benchmarking, hidden-pane/reveal measurement, and blocking regression
  thresholds are out of scope; each can be a later plan once committed history
  establishes per-workload variance.
- `xctrace` attachment to an ad-hoc-signed binary is assumed to work with the
  `get-task-allow` entitlement; commit 4 verifies this before building on it,
  and falls back to `sample`-only if macOS policy blocks it.

## Implementation discretion

- Internal workload-driver, timestamp-correlation, and artifact-aggregation
  structure is discretionary provided the measurement and ownership invariants
  hold. Sharing launch/teardown code with the viability harness by extraction
  or by a parallel script is discretionary.
- Fixture sizes, warmup counts, and iteration counts may be tuned to keep runs
  useful without silently changing fixture semantics or comparison identity.
