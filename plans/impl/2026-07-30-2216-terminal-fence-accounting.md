# Fence Accounting By Construction

## Problem and desired outcome

The benchmark fence-stall instrument -- main-actor time blocked fencing a
pane's owner queue -- has broken silently twice: it first shipped latched at
drain time (losing stalls from suppressed publishes), then `50c5240` added a
second untimed fence to the consume path and the bracket omitted a measured
38-57% of the wait (`docs/research/23-pty-benchmark-alignment.md` `F4`). The
single-fence fix (`23/F5`) repaired today's bracket but left the structure
that allowed silent breakage:

- Timing lives at one call site in `TerminalPaneSessionController`; nothing
  detects a fence the bracket does not span. Checkpoint, teardown, and init
  fences on the same queue are invisible.
- The instrument code is compiled only in benchmark builds, so `just test`
  never compiles it, let alone tests it.
- The artifact fields are read by no script and pinned by no test -- the same
  recorded-but-unreported trap that hid the PTY throughput number for the
  harness's whole life (`20/F2`).

Desired outcome: every main-actor fence onto the owner queue is accounted by
construction and attributed to a kind; coverage is self-reported and
cross-checked so an unaccounted fence is detectable; the accounting is
testable by the plain package suite; and the fence quantities are promoted
into benchmark blocks as descriptive values.

## Decision

Split the accounting by what each layer can know:

- **The controller times and attributes.** `TerminalPaneSessionController` is
  the sole production caller of every host fence; all its host fences route
  through one accounted path that records wait time and count per kind
  (delivery/consume, checkpoint, teardown/exit, init/handler-install,
  diagnostic). The consume fence feeds both the existing per-delivery
  flush pipeline and the new cumulative totals from one clock pair.
- **The host counts raw entries.** A single internal primitive performs every
  `queue.sync` in `TerminalPTYHost` and counts entries, partitioned so
  package-test fences do not pollute production counts. The host count is the
  backstop that sees a bypass the controller cannot.
- **A static gate pins the structure.** A lint (with self-test, wired into
  `just test` beside the existing boundary lints) enforces that `queue.sync`
  occurs only in the host's single primitive and that the controller names
  host fence entry points only inside the accounted path.
- **The accounting is always compiled.** No `#if DANTERM_TERMINAL_BENCHMARK`
  in the package for accounting; only the app-side observer and artifact
  writing stay benchmark-gated. This makes the instrument package-testable
  and removes the untested-`#if` rot class outright.
- **The observer samples, never accumulates per-frame, for the new totals.**
  Block values are deltas of the controller's cumulative monotone counters,
  sampled at start-marker detection and again at block completion, via a
  completion-time read of the one measured controller that is dropped at
  teardown. Checkpoint fences with no subsequent publish are thereby counted
  without inventing publishes. The block-boundary policy itself -- baseline
  at start marker, delta at completion, invalidation after the exit fence,
  re-baseline at the next persistent start marker -- is an always-compiled
  package component; the benchmark-gated observer is thin glue that feeds it
  boundary events and reads its results.
- **Validation promotes and cross-checks.** Blocks carry the fence
  quantities; a present-but-inconsistent artifact (kind sums disagreeing with
  totals, controller count disagreeing with host count) is invalidated;
  absent fields are not.

Critical files: `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift`,
`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`,
`app/TerminalBenchmark.swift`, `app/SwiftTerminalSessionView.swift`,
`scripts/terminal-benchmark-validation.py` (+ its test), a new lint in
`scripts/` with a self-test in `scripts/tests/`, and the `justfile` wiring.

## Invariants

**I1.** Every main-actor fence onto a pane's owner queue is accounted exactly
once and attributed to a kind, including the controller's init-time fences.
A fence that bypasses accounting fails `just test` (static gate) or produces
a controller/host count mismatch.

**I2.** The four existing artifact fields (`cumulativeFenceStallNanoseconds`,
`fenceStallFrameCount`, `maxFenceStallNanoseconds`,
`fenceStallDurationsNanoseconds`) keep their exact meaning: per-delivery
consume fence only, promoted at accepted draws, completion write outside the
draw-series guard.

**I3.** Over any span, delivery-kind cumulative wait equals the sum of
flushed per-delivery stalls plus the unflushed pending stall -- the two
accounting schemes on the one shared fence agree.

**I4.** The accounting and the block-boundary sampling policy compile and
are behaviorally tested under plain
`swift test --package-path lib/TerminalPTY`, with no benchmark flag.

**I5.** New artifact quantities exist per block: total fence wait, per-kind
wait and count, and the host's production-fence entry count over the same
span. Every aggregate ships with its count, on the artifact's declared
clock. No ordering is asserted between the existing per-delivery cumulative
field and the new total -- their block-boundary rules differ.

**I6.** Promoted blocks treat an absent fence field as absent (never zero,
never an invalidation); an artifact whose fence fields are present but
internally inconsistent is invalid.

**I7.** Fence quantities render no verdict and enter no decision table.

**I8.** A draw observed after the application-exit fence cannot sample a
torn-down controller; a block still open at exit remains a failed block with
no phantom totals.

**I9.** In persistent mode, fences occurring between blocks appear in no
block's totals.

## Proof obligations

**PO1 (I1).** The gate's self-test passes on the real tree and fails on a
synthetic bypass (a second `queue.sync` in the host; a controller fence call
outside the accounted path). A package test over a scenario mixing consume,
checkpoint, and teardown fences proves controller and host counts equal --
including a fresh controller's init fences -- and that package-test fences
leave production counts untouched.

**PO2 (I2).** Package tests pin the frozen flush semantics: a suppressed
publish carries its stall forward; a non-draining publish does not
double-charge. These are the regression tests that would have caught both
historical breakages.

**PO3 (I3).** The equality is asserted across a span containing suppressed
and accepted publishes with a nonzero unflushed remainder.

**PO4 (I4).** The tests above run in the plain package suite; `just test` is
green with no flagged lane added.

**PO5 (I5, I8, I9).** Package tests over the block-boundary policy component
prove start-marker baselining, completion-delta computation, exit-fence
invalidation (a still-open block yields no totals), and persistent-mode
re-baselining (fences between blocks land in no block). One valid live
benchmark block then carries the new fields with internally consistent sums.

**PO6 (I6, I7).** Python tests pin promotion presence, the absent-is-not-zero
distinction, inconsistency invalidating a block, and the absence of any new
verdict or comparison-table rendering.

End-to-end verification: `just test`, then one
`./scripts/terminal-benchmark.sh scrollback-stream swift` block inspected for
the new fields and their consistency.

## Ordering

Instrument before reporting, with a revert boundary between them:

1. Package accounting (always-compiled) + host single-sync primitive and
   entry counter, tests first.
2. Lint gate + self-test + `justfile` wiring.
3. Block-boundary policy component (package, tests first) + observer glue +
   artifact fields.
4. Validation promotion + Python tests.

## Non-goals and rejected ideas

- **Non-goal:** any calibrated rule, comparison-table rendering, or verdict
  for fence quantities; no consumer exists yet (`17/D6`).
- **Non-goal:** changing harness lifecycle (SIGTERM teardown stays), any
  workload, or any frozen decision rule.
- **Rejected: host-side timing.** The wait must be measured from the calling
  side of `queue.sync`; the host cannot see the contended wait from inside
  the block, cannot attribute why the fence happened, and would need new
  cross-thread synchronization to store results.
- **Rejected: benchmark-gated accounting with a flagged test lane or
  env-conditional package define.** Both leave the instrument untested by
  default or fight the build/test caching; untested instrument code is the
  rot class this plan exists to kill.
- **Accepted risk:** always-compiled accounting costs two commpage clock
  reads plus integer adds per fence, at a consume rate coalesced to
  main-loop-turn frequency -- well under 0.02% of one core, inside no
  calibrated bracket (visible only as noise in the uncalibrated process-CPU
  metric).

## Implementation discretion

- Choke-point structure, counter visibility, and how the controller's
  init-time fences are bracketed under Swift definite-initialization rules,
  provided the counts include them (I1).
- The observer's completion-time controller access mechanism, provided
  exactly one measured controller feeds it and teardown drops it (I8).
- Lint mechanism (occurrence pinning vs allowlist) and all field names.

## Commit progress

- [x] 1. Account for terminal owner-queue fences by construction
- [ ] 2. Promote fence totals into benchmark blocks

## Implementation notes

- The test-only synchronous output seam now feeds the terminal owner directly
  and publishes its pending update, so delivery-flush accounting is deterministic
  without waiting for a live child lifecycle transition. Production output still
  enters through the lifecycle reducer.
