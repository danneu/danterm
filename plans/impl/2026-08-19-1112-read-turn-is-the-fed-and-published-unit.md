# XPORT-1: the read turn, not the read() syscall, is the unit that is fed and published

Source finding: XPORT-1 in `docs/scratch/2026-08-18-construction-audit.md`.

## Problem, evidence, and a corrected premise

`TerminalPTYHost.readReady` runs the whole per-chunk pipeline once per
`read()` syscall: an `Array` allocation and copy, a lifecycle event and
reducer pass, a flight-tape record, `Terminal.feed`, a reply drain, and
`publishPendingUpdate`. A pty master read can never return more than
1024 bytes (xnu clist, `TTYCLSIZE`), so a saturated 16 KiB turn pays
that pipeline 16 times, and the flight tape records kernel-buffer-sized
`.feed` events. `readReady` also allocates and zero-fills a fresh
16 KiB buffer every turn. The audit's numbers: ~1,490 pipeline trips
per `scrollback-stream` corpus instead of ~95.

**The audit's proposed fix does not work, and the plan diverges from it
deliberately.** The audit's ideal -- accumulate raw reads into a turn
buffer, run the pipeline once at turn end -- was probe-tested during
planning (C harness, blocking writer saturating a real pty, macOS
25.5.0):

- With zero work between reads, successive reads never chain: the
  reader's next `read()` returns `EAGAIN` in nanoseconds while the
  blocked writer's kernel wakeup needs microseconds. 1,024 turns of
  exactly one 1,024-byte read each; zero turns coalesced.
- With as little as ~5us of work between reads -- yielding or a pure
  busy spin -- every turn chains to the full 16 KiB cap (64 of 64).

So today's 16 KiB turns exist only because parsing (~100us/KiB) sits
inside the read loop. Deferring all processing to turn end collapses
turns to one read: pipeline trips stay ~1,490, dispatch-source firings
rise 16x, and tape events stay clist-sized. The audit's stated shape
delivers only the hoisted buffer.

The shape that achieves the finding's actual goal keeps `Terminal.feed`
per-read inside the loop (the parse is the gap that lets the writer
refill the clist) and moves everything else -- tape record, lifecycle
event, capture surfaces, publish -- to once per turn.

## Decision

Restructure the output path so the host owns byte delivery and the turn
is the unit everything downstream sees:

- `readReady` reads successive `read()` returns into successive offsets
  of one host-lifetime turn buffer and feeds the terminal directly from
  each newly filled slice (no per-read `Array`, no per-read event). The
  turn ends at the 16 KiB cap, `EAGAIN`, EOF, or a feed that produces
  terminal reply bytes.
- At turn end, exactly once: record one `.feed` event covering the
  turn's bytes on the flight tape, run the update-pending check,
  publish, and update the capture surfaces. When a reply ended the
  turn, the accumulated `.feed` is recorded before the reply is
  flushed, so the tape's causal order holds (I10).
- Output bytes leave the lifecycle reducer: `.output` /
  `.deliverOutput` are deleted. The reducer keeps `.outputEOF`,
  `.childExited`, and the drain-vs-teardown ordering -- that is its
  policy content; the byte pass-through never was. The host gates
  feeding on the reducer's phase plus its existing descriptor guards.
- `drainCommittedOutput` (the EOF drain) takes the same shape: feed
  directly, one turn-end record, then `process(.outputEOF)`.
- `Terminal` gains a public buffer-pointer feed entry point beside
  `feed(_ bytes: [UInt8])`; `feedBuffer` already exists as the private
  core.
- `readReady`'s doc comment is rewritten: its measured rationale ends
  on a premise the probe and the xnu source both refute ("a turn is
  already a single read"), and the corrected version must state the
  real dynamics -- turns fill only because parsing sits between reads.
- The XPORT-1 entry in the audit doc gets a correction note recording
  the probe result, since four downstream findings (PTY-3, PTY-4,
  XPORT-2, XPORT-4) are sequenced on this one's boundary.

Why this is the ideal and not the audit's: with feeding inside the
loop, per-read work is structurally reduced to the syscall plus the
parse -- nothing else per-read exists to optimize -- and the one
remaining per-turn `Array` is the flight tape's retention obligation
(XPORT-2's correction already established the tape keeps per-event
arrays). The audit's "sharper ideal" (event carries no bytes +
buffer-pointer feed) removes no copy while that obligation stands, and
a length-only event referencing a mutable host buffer would be unsound
anyway: the EOF drain legitimately queues events mid-reduction, and a
queued length-only event would read bytes a later turn had overwritten.

## Invariants

- I1. The byte stream the terminal parses is identical to the byte
  stream the kernel delivered, regardless of where read boundaries
  fall. (Feeding from a host buffer that later reads overwrite is
  safe: verified during planning that `TerminalInputStream` state --
  UTF-8 decoder, escape absorber, sync prefix -- accumulates by value
  and retains no reference into a fed buffer across feed calls.)
- I2. A flight-tape `.feed` event boundary is a turn boundary, never a
  kernel-buffer artifact: under saturation events may exceed 1024
  bytes; no event ever exceeds the 16 KiB turn cap.
- I3. Replay of the recorded tape reproduces the same screen state as
  the live terminal (existing contract, must survive the boundary
  change).
- I4. Trickle latency is unchanged: a turn that reads once and hits
  `EAGAIN` publishes immediately; no timer, debounce, or retry is
  introduced anywhere on the read path.
- I5. Bytes never reach the terminal in a lifecycle state where the
  reducer would previously have dropped them (spawning, post-EOF
  running, teardown, finished).
- I6. Worst-case fence wait is unchanged: the 16 KiB turn cap and the
  one-publish-per-turn cadence bound the serial queue's longest
  contiguous slice exactly as today.
- I7. The read path performs no per-read heap allocation and no
  per-turn buffer zero-fill; the turn buffer is allocated once per
  host.
- I8. Terminal replies (DSR, DA, XTGETTCAP, ...) are drained after
  every feed and flushed synchronously, as today; a feed that produces
  a reply ends the turn, so a reply never waits on later reads.
  Protocol round-trip behavior stays byte-for-byte equivalent.
- I9. The two EOF orderings keep today's behavior. EOF-before-exit:
  final-byte work publishes (an update signal fires) immediately at
  the EOF edge -- nothing waits on the child's exit, which may be
  indefinitely later -- and the result is reported separately when it
  exists. Exit-before-EOF (the committed drain): the drain's bytes are
  applied and its tape record and captures land before the result is
  reported, so a fence taken on the result signal sees the final frame
  and its transitions.
- I10. The flight tape preserves causal order: the `.feed` event
  containing a query is recorded before the `.write` event of the
  reply it produced. No recorded `.feed` spans both sides of a reply
  write.

## Proof obligations

- PO1 (I1, I3): a payload several kernel buffers long, with control
  sequences (long SGR run, OSC 8) deliberately straddling the old
  1024-byte boundaries, produces the same screen state and a tape whose
  replay equals the fenced snapshot. Deterministic; passes before and
  after.
- PO2 (I2): no recorded `.feed` event ever exceeds the 16 KiB turn
  cap -- deterministic before and after. The other half of I2 (events
  larger than 1024 bytes occur under saturation) is a scheduling
  coincidence a starved gate runner can legitimately never observe, so
  it is not a gate test: it moves to the non-gating verification below.
- PO3 (I4): a single small write publishes without waiting for anything
  (existing trickle-path tests must hold; the childless-channel tests
  exercise exactly this).
- PO4 (I5): output arriving around EOF and teardown edges is delivered
  or dropped exactly as the reducer decided before. Verified during
  planning that the host's existing guards cover every reducer state
  that drops output (source activation gates pre-running states; the
  descriptor seal, set in the same reduction that leaves running, gates
  teardown; readReady cancels its source at EOF and a straggler re-read
  re-emits idempotent `.outputEOF`). Pinned by the existing lifecycle
  and host suites.
- PO5 (I3): the existing tape/replay suites (`stateSynchronization...`,
  `followFence...`, recorder suite) pass unchanged -- they assert
  concatenation and replay equality, not chunk boundaries.
- PO6 (I7): allocation claims are measured, not asserted in tests:
  Time Profiler per `agent-docs/terminal-performance.md`, comparing
  per-read frame counts under `readReady` against baseline.
- PO7 (I8, I10): a payload whose tail is a query (e.g. `ESC[6n`)
  produces a tape where the `.feed` containing the query precedes the
  reply's `.write`, and the reply bytes reach the child end.
  Deterministic: one write, one read, the reply ends the turn.
- PO8 (I9): EOF-first needs a new test on the update-signal surface --
  the existing `eofBeforeExit` waits on the flight tape, which a
  publish-withholding implementation still satisfies. The scenario:
  after the child closes the PTY but before the test permits it to
  exit, an update signal has fired and a fence shows the final output
  while the result is still unreported; then the exit is permitted and
  the result arrives. Exit-first is already pinned:
  `consumptionFencePairsFrameAndExitMetadata` waits on the result
  signal and asserts one fence returns the final frame, its
  transitions, and the result together; it and
  `exitBeforeEOFConverges` must stay green.

## Verification beyond tests

- Coalescing evidence (the deferred half of I2): a manual run of the
  spinning-writer scenario, or the trace below, must show recorded
  `.feed` events larger than 1024 bytes under saturation. Non-gating:
  whether the writer refills within the parse window is the
  scheduler's choice, so this is an observation to make once on a
  quiet machine, not a pass/fail test.
- `just benchmark-quick baseline=HEAD workload=scrollback-stream` --
  honest expectation set by the audit itself: the A/A noise floor
  (~3.48 points) may swallow the win; the deciding instrument is
  `just benchmark-trace scrollback-stream template="Time Profiler"`,
  where per-read pipeline frames (`publishPendingUpdate`,
  `TerminalFlightRecorder.record`, `swift_allocObject` under
  `readReady`) must fall roughly 16:1 while `Terminal.feed` frames stay.
- `just test` (gate) and the existing byte-plane suites.

## Non-goals

- No flight-recorder byte ring (XPORT-2 -- audited separately and
  deferred; the per-turn retained array is accepted here).
- No change to turn size, publish cadence policy, or fence semantics.
- No reshaping of `PaneProcessLifecycleEvent` beyond deleting the
  output cases -- input, resize, and teardown flow are untouched.

## Accepted risks

- AR1. Update-signal occurrences that today publish after each 1 KiB
  chunk (semantic events surfaced by parsing, frame damage) publish at
  turn end, up to ~1.6 ms later under saturation. Replies are exempt:
  a reply ends the turn (I8), so nothing a child waits on is delayed.
- AR2. Deleting `.output`/`.deliverOutput` retires the reducer-level
  tests for output pass-through and interleaving; the ordering they
  pinned moves to host-level suites. In particular "late output after
  close is dropped" stops being tested policy and becomes structurally
  unrepresentable -- no feed path exists past the descriptor seal --
  which is the trade this plan makes deliberately.

## Implementation discretion

- The exact turn-end bookkeeping split between `readReady` and
  `drainCommittedOutput`, provided both share one buffer and one
  recording path.
- Whether readReady asserts `reducer.phase == .running` at entry
  (verified redundant with the seal/activation guards, but cheap
  documentation of I5).

## Critical files

- `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift` --
  `readReady`, `drainCommittedOutput`, `applyOutput`, `process`,
  publish bookkeeping, the new turn buffer, the doc comment.
- `lib/TerminalPTY/Sources/PaneProcessLifecycle/PaneProcessLifecycle.swift`
  -- delete the output event/command cases.
- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` -- public
  buffer-pointer feed beside `feed(_:)`.
- `lib/TerminalPTY/TestSupport/TerminalPTYTestSupport/ChildlessPTYChannel.swift`
  -- a saturating (tight-retry) writer helper, used only by the
  non-gating coalescing observation.
- `lib/TerminalPTY/Tests/PaneProcessLifecycleTests/` -- output-case
  literals stop compiling (six sites per the audit's starter kit).
- `lib/TerminalPTY/Tests/TerminalPTYHostTests/TerminalPTYHostTests.swift`
  -- new PO1/PO2 tests beside the existing childless-host suites.
- `docs/scratch/2026-08-18-construction-audit.md` -- correction note on
  XPORT-1.

## Implementation notes

- The turn buffer is a stored `[UInt8]` entered through
  `withUnsafeMutableBufferPointer`, not a manually allocated
  `UnsafeMutableBufferPointer`. It is allocated and zero-filled once at host
  construction either way, so I7 holds, and this shape needs no `deinit` and no
  reasoning about what an actor's `deinit` may touch.
- `takeOutputTurn` is shared by both callers and does not publish. `readReady`
  publishes itself when the turn ended without EOF; on EOF, and on the whole
  committed drain, `process(.outputEOF)` publishes on its own reduction. That
  keeps the drain's publish count exactly what it is today: the drain runs
  nested inside a reduction, so a publish of its own would have added an update
  signal ahead of the reported result.
- `readReady` does not assert `reducer.phase == .running` (the plan left this to
  discretion). The source-activation and descriptor-seal guards already make the
  other phases unreachable, and an assertion would be the only place in the read
  path reading reducer state.
- The DEBUG fixture seam keeps a `applyFixtureTurn` helper beside
  `stageFixtureOutput` rather than its own `#if DEBUG` region, because
  `scripts/terminal-pty-host-test-seam-lint.sh` allows exactly one such region
  under `lib/TerminalPTY/Sources`.
- The saturating child-end writer landed as a `pace:` parameter on
  `ChildlessPTYChannel.writeFromChild` and is used by the PO1 and PO2 tests, not
  only by the manual observation: without it the writer sleeps a millisecond
  between attempts, the descriptor is empty between reads, and PO2 would assert
  a cap no turn ever approaches.
- PO8 needed a new test-support wait, `waitForUpdate(within:where:)`, because
  every existing wait either polls fences (which drain the host whether or not
  it ever woke a consumer) or reads the flight tape (which records before
  publishing). Its predicate drains the frame state, which is what a real
  consumer does and what re-arms the host's next redraw signal.
- The coalescing observation deferred out of PO2 was made once on a quiet
  machine: the PO2 payload (~32 KiB, saturating writer) records 3 feed events,
  the largest exactly 16384 bytes. Both halves of I2 are therefore observed,
  and only the cap is gated.

## Follow Up

- The non-gating performance verification in this plan was not run and is the
  user's to make on a quiet machine: `just benchmark-quick baseline=HEAD
  workload=scrollback-stream`, then `just benchmark-trace scrollback-stream
  template="Time Profiler"` to confirm that `publishPendingUpdate`,
  `TerminalFlightRecorder.record`, and `swift_allocObject` frames under
  `readReady` fall roughly 16:1 while `Terminal.feed` frames stay (PO6).
- `docs/scratch/2026-08-18-construction-audit.md` still lists XPORT-1 unchecked
  in its wave-1 checklist; mark it done in the audit-marking pass that this repo
  keeps as its own commit.
