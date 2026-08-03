# Repeatable live-btop profiling workload

## Problem

The sparse AppKit damage regression was discovered by a manually assembled live
btop profile rather than by the benchmark suite. Reproducing that diagnostic
required an isolated optimized app, canonical geometry, live PTY verification,
controlled arrow input, profiler attribution, damage-topology accounting, and
executable and machine-state provenance. Those steps currently survive only in
the research record and disposable artifacts, so the next investigation would
have to rebuild the instrument before it could investigate the product.

The supporting evidence and benchmark blind spot are preserved in
`docs/research/29-sparse-appkit-damage-clip-topology/` (F3-F7 and D3).

## Desired outcome

Live btop becomes a workload of the existing profiling commands:

```sh
just benchmark-sample btop-scroll 20
just benchmark-trace btop-scroll "Time Profiler" 20
just benchmark-loop btop-scroll
```

The existing profile identity and activity path let an agent address the exact
owned app from loop mode and attach or report another profiler without a second
btop-specific front-end.

For `btop-scroll`, sample and trace durations are whole numbers from 1 through
20 and describe the profiler's requested recording window. Loop runs until
interrupted and alternates Down and Up in 10-second legs.

## Decision

Admit `btop-scroll` only to the existing sample, trace, and loop profiling
modes. Memory profiling, every calibrated comparison, and every other
decision-bearing entry point reject it. The workload reuses the harness's
optimized isolated app, fresh HOME/TMPDIR/ZDOTDIR, canonical 179x66 geometry,
explicit bundled-CLI pane targeting, foreground activation, activity snapshots,
identity artifacts, and owned-process teardown.

Before any build or launch, resolve btop to an executable absolute path and
preflight permission to synthesize input. Launch that exact binary in the owned
pane. Readiness requires a uniquely owned btop process and PTY whose live `stty`
size is 66 rows by 179 columns.

Generate arrow input through CGEvent-level synthesis targeted at the owned
foreground app, using and recording the host's repeat cadence. A bounded capture
starts the stimulus before profiler recording begins and releases it only after
recording ends. Record measured stimulus and profiler start/stop times, and
invalidate any capture whose profiler window is not fully contained in the
stimulus window. Loop releases one direction before pressing the other and
releases the active key on every exit.

During a bounded capture, the existing continuous activity publisher also
samples whether the owned app remains foreground and whether its canonical
window remains visible, unoccluded, and contained on screen. The capture is
invalid if either condition lapses inside the measured interval or if the
publisher cannot prove coverage for that interval.

Bounded captures difference the profiling harness's existing before/after
activity snapshots into a topology delta. A valid capture requires parsed
profiler samples, positive topology coverage, and full stimulus/profiler
overlap; missing measurement is never reported as zero. Loop publishes its
current stimulus direction and timing beside the existing identity and activity
path so an attaching agent can bracket and validate its own window.

Extend the existing profile identity rather than creating another provenance
format. It records the input mechanism and permission result, btop absolute
path and version, fresh-home status, effective config path and hash, owned btop
PID and PTY, repeat timing and direction changes, measured profiler/stimulus
overlap, topology coverage, and measured machine state. Existing source,
binary, dirty-tree, symbol, geometry, command, and diagnostic-status fields
remain authoritative.

An invalid or failed bounded capture exits nonzero and preserves every partial
artifact collected before the failure so an agent can diagnose why the run was
rejected.

## Invariants

- **I1 -- profiling-only workload.** `btop-scroll` is unreachable from
  `benchmark-quick`, `benchmark-confirm`, calibration, and every other
  decision-bearing collection path.
- **I2 -- bounded interface.** Sample and trace accept only an explicit 1-20
  second whole-number recording duration; loop accepts no duration and stops
  only when interrupted.
- **I3 -- owned isolation.** Every app, pane, shell, btop, stimulus, and profiler
  process belongs to the invocation; cleanup never selects or terminates another
  DanTerm or btop process.
- **I4 -- live workload identity.** Profiling starts only after the owned btop
  process and PTY are uniquely identified and `stty` reports 66 by 179.
- **I5 -- attributable stimulus.** Arrow input traverses the real AppKit event
  path while the owned app remains foreground and its canonical window remains
  presented, every transition and exit releases the active key, and a bounded
  profiler window lies wholly inside the measured stimulus lifetime.
- **I6 -- measured coverage.** A successful bounded capture contains parsed
  profiler samples and a topology delta with a positive sample count. A trace
  also proves that its template exported time-profile rows. Counted continuous
  samples prove foreground and presentation coverage across the measured
  interval.
- **I7 -- reproducible provenance.** Every run records enough source, binary,
  btop configuration, workload, timing, geometry, process, input-permission,
  and machine-state identity to explain whether two executions had matching
  conditions.
- **I8 -- diagnostic status.** Every identity and report remains explicitly
  ineligible for a performance verdict or cross-session history; profiler
  samples are never presented as whole-process CPU.

## Proof obligations

- **PO1 -- admission and preflight.** Behavioral tests prove btop's profiling-
  only admission to sample, trace, and loop; memory and every decision-bearing
  mode reject it. They also prove all duration bounds and rejection of a missing
  btop executable or input permission before build or launch.
- **PO2 -- stimulus and overlap.** Separately invocable logic, tested with an
  injected clock and profiler boundary events, proves repeat timing, direction
  changes, release-before-press, release on every exit, measured timestamps, and
  rejection of any profiler window not contained by the stimulus.
- **PO3 -- artifacts and coverage.** Separately invocable artifact logic proves
  topology subtraction, missing-versus-zero handling, positive sample gates,
  trace export validation, counted foreground/presentation samples and lapse
  invalidation, effective btop-config identity, and the extended profile
  identity without asserting shell source layout. Every invalidation path exits
  nonzero while preserving the partial diagnostic bundle.
- **PO4 -- live proof.** Opt-in GUI runs prove a fresh optimized app can launch
  the resolved btop at a live 179x66 PTY, deliver foreground CGEvent arrow input,
  produce nonempty sample and Time Profiler reports with positive topology and
  valid overlap, invalidate a bounded run when another app takes foreground,
  alternate a loop leg, and tear down without a stuck key or an unrelated-
  process signal.
- **PO5 -- repository and operator contract.** Existing benchmark harness and
  command tests remain green, new non-GUI behavioral tests join `just test`, and
  `agent-docs/terminal-performance.md` documents the exact positional sample,
  trace (`just benchmark-trace btop-scroll "Time Profiler" 20`), and loop
  commands, their preconditions and artifacts, and their attribution-only
  status.

## Non-goals

- Turning live btop into a calibrated benchmark or permanent performance
  threshold.
- Measuring or claiming battery use, Energy Impact, or whole-process CPU.
- Comparing revisions, choosing a baseline, or deriving a directional verdict.
- Expanding the `danterm` CLI surface.

## Accepted risks

- **AR1 -- host repeat settings.** The stimulus follows and records the host's
  repeat timing, so machines may produce different event rates. This diagnostic
  reproduces local held-key behavior; cross-machine comparison is out of scope.
- **AR2 -- fixed loop legs.** A short process list may reach an end before a
  10-second leg finishes and leave an idle tail. Loop exposes live activity and
  direction state but issues no coverage verdict; an attaching agent must
  bracket and validate its own profiling window.
- **AR3 -- canonical workload.** The 179x66 geometry and 20-second recording cap
  cover the reproduced incident rather than every window size or arbitrarily
  long process list. Broader coverage belongs in a calibrated deterministic
  workload.

## Rejected ideas

- **RI1 -- add a CPU verdict.** Rejected because the profiling modes are
  attribution instruments and `sample` mixes running and blocked counts that
  cannot stand in for whole-process CPU.
- **RI2 -- target an existing user pane.** Rejected because implicit focus,
  unknown geometry and configuration, and ambiguous process ownership would
  destroy the diagnostic's provenance and teardown guarantees.
- **RI3 -- add a btop-specific profiling front-end.** Rejected because the
  existing profiling harness already owns profiler modes, identity, activity
  snapshots, symbols, reporting, and teardown; duplicating that surface would
  create two contracts for the same behavior.

## Commit progress
- [x] 1. feat(benchmark): add a held-arrow stimulus with measured overlap
- [x] 2. feat(benchmark): publish foreground and presentation coverage
- [ ] 3. feat(benchmark): add btop workload identity and coverage artifacts
- [ ] 4. feat(benchmark): admit btop-scroll to sample, trace, and loop profiling
- [ ] 5. feat(benchmark): prove and document the live btop-scroll diagnostic

## Implementation notes

- **Where the stimulus boundary landed (commit 1).** Every timing decision --
  cadence, repeat scheduling, direction changes, containment -- is Python in
  `scripts/terminal_btop_stimulus.py`, and only CGEvent posting and the
  permission preflight are native, in `scripts/terminal-btop-stimulus-arm.swift`.
  That split is what lets PO2 be proved against an injected clock; the arm holds
  no policy beyond releasing whatever key it left down when stdin closes or a
  signal arrives.
- **The repeat train is synthesized, not inherited (commit 1).** A synthetic
  `CGEvent` key-down does not auto-repeat the way real HID input does, so the
  driver emits the repeats itself at the host's cadence with
  `keyboardEventAutorepeat` set. Two consequences the plan did not spell out: a
  `KeyRepeat` of 0 (a settable value) is clamped to one 1/60 s tick and the
  clamp is recorded, and a driver that fell behind resyncs to now instead of
  bursting the repeats it missed -- a real held key does not catch up.
- **The profiler wait is bounded (commit 1).** `run_bounded_capture` takes a
  required `profiler_timeout_seconds`. I5 asks that every exit release the key,
  and an unbounded wait on a wedged profiler is not an exit at all: it holds an
  arrow down in the operator's live session indefinitely.

- **Coverage counting is its own module (commit 2).** The counting rules went
  into a new `TerminalBenchmarkCoverage` target rather than into
  `TerminalBenchmarkTopology`, whose file header scopes it to sparse-span damage
  topology. Same split as commit 1: the pure counters are headlessly tested, and
  the app-side observer keeps only the two AppKit probes
  (`NSApplication.shared.isActive` and the existing full window-presentation
  check) that produce the booleans.
- **Three cumulative counters, not a lapse flag (commit 2).** The activity
  snapshot publishes lifetime `sampleCount`, `foregroundSampleCount`, and
  `presentedSampleCount`; a bounded capture differences two snapshots, so a
  lapse inside the measured interval shows up as a foreground/presented delta
  short of the sample delta, and an interval nobody sampled shows up as a zero
  sample delta. The `presentationCoverage` key is omitted entirely when no state
  recorder exists to feed it, so "not measured" never renders as clean zeros.
  The activity snapshot's `schemaVersion` moved to 2 for the added vocabulary;
  nothing currently reads that field.

## Implementation discretion

- The internal boundary between the existing harness and the new workload-
  specific readiness, stimulus, overlap, and topology-delta logic.
- The machine-state sampling cadence, provided its coverage is counted and can
  invalidate a bounded capture.
