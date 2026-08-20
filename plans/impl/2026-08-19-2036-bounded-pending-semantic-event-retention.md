# XPORT-4: one bounded retention policy for pending semantic events

## Problem

`TerminalPaneDeliveryBoundary` coalesces host update signals while a main hop is
outstanding by building a whole new `TerminalPTYUpdateSignal` per merge:
`state.pendingSignal.map { $0.merging(newer: signal) } ?? signal`, where
`merging` concatenates `semanticEvents + newer.semanticEvents`.

Two things are wrong with that, and the second is the important one.

1. Every merge copies all events retained so far, so K merges before main runs
   cost O(K^2) copying.
2. The accumulation has no bound at all. The engine bounds its *own* pending
   work -- title, cwd, and progress coalesce to their newest value, discrete
   events stop at a count limit, and retained bytes stop at a byte limit shared
   with hyperlink metadata
   (`lib/TerminalCore/Sources/TerminalCore/Terminal.swift#admitDiscreteSemanticEvent`).
   `publishPendingUpdate` then flattens that bounded accumulator into a plain
   array and hands it across the queue boundary, where the bound is gone. Each
   drain is bounded; the sum of drains is not.

   Failure scenario: the main thread stalls (a modal, a slow display pass, a
   spinning app). A pane keeps emitting bells, OSC 9 notifications, and OSC 133
   command marks. The host read loop keeps running on its own queue, so it keeps
   draining up to a full engine budget per turn and merging it into
   `pendingSignal`. Retained bytes grow with the stall for as long as the child
   keeps writing. That is untrusted terminal output growing retained per-pane
   pending work with no explicit bound, which
   [engine design](../../docs/design/2026-08-06-swift-terminal-engine.md) J1
   forbids and J6 states the shape of. Making the growth linear instead of
   quadratic only changes how long exhaustion takes.

Evidence: `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#TerminalPTYUpdateSignal.merging`
and the two merge sites in
`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift#TerminalPaneDeliveryBoundary`
(`scheduleUpdate` and the test-only `stagePendingSignal`).

Vetted scope (audit XPORT-4, impact 2 x confidence 5): the quadratic term is
real but unloaded in practice -- semantic events arrive roughly one per OSC 133
prompt mark, so no workload can measure it. This is a correctness and
resource-bound fix, not a measurable perf win; do not run the benchmark ladder
for it.

## Decision

- D1. J6 retention for terminal semantic events becomes one reusable TerminalCore
  surface, and the only implementation of that rule. It owns event
  classification (replaceable versus discrete), per-event byte cost, the count
  limit, the byte limit, coalescing of replaceable values, and admission. The
  engine accumulator and `TerminalPTYUpdateSignal`'s merge both use it, so the
  two layers cannot drift into two versions of J6. The engine's hyperlink
  metadata shares the same byte budget, so the engine contributes its retained
  hyperlink bytes to the same accounting rather than keeping a parallel one.
- D2. The merge becomes a mutating in-place accumulation on
  `TerminalPTYUpdateSignal`, performed at both boundary merge sites inside the
  existing `Mutex` critical section. Build no new signal until the hop (or
  fence) that delivers it takes the whole value. Scalar signal fields (clipboard
  write, result, `processStarted`, history generation) and input
  acknowledgements stay in the signal itself -- they are not terminal semantic
  events and D1's surface does not cover them.

## Invariants

- I1. The accumulated payload is bounded. Across any number of host signals
  collapsed into one main hop, retention obeys the D1 count and byte limits.
  Excess discrete events are dropped as complete units, never truncated.
- I2. Replaceable terminal values -- title, working directory, and progress --
  coalesce to their newest value, which takes the newest value's position in
  stream order.
- I3. I1 outranks I2 under byte pressure: when a newer replaceable value cannot
  be admitted within the byte limit, the previously retained value is kept and
  the newer one is dropped. This is the engine's existing behavior
  (`Terminal#admittedCoalescedSemanticEvent` returns the existing value), and D1
  makes it one rule rather than two.
- I4. Input acknowledgements coalesce by wait generation: at most one
  `PaneSemanticEvent.userInputDelivered` is retained per distinct generation
  value, counting the absent generation as one such value. This preserves every
  possible retraction, because whether an acknowledgement retracts a wait
  depends only on its generation
  (`lib/DanTermCore/Sources/DanTermCore/PaneLifecycleReducer.swift#retractsWait`),
  so a second acknowledgement carrying a generation already delivered cannot
  change the model. Acknowledgements are not terminal-originated and are never
  dropped for byte pressure.
- I5. Apart from the bounds, the delivered payload is unchanged: several host
  signals collapsing into one main hop deliver exactly once, with retained
  events in host order, no duplication, newest clipboard write and result, OR'd
  `processStarted`, and max history generation.
- I6. A synchronous fence (`takePendingSignal`) takes and clears the whole
  accumulation atomically, so a checkpoint consume cannot overtake urgent work
  already signaled toward the main hop, and the main hop already queued at that
  moment delivers nothing.

## Proof obligations

- PO1 (D1): the engine's existing semantic-event bound tests pass unchanged once
  the engine is rebuilt on the shared surface. They are the proof that
  extraction preserved the engine's J6 behavior, including the hyperlink bytes
  that share the budget.
- PO2 (I1, I2, I3): one behavioral test at the boundary, written first and
  failing against the current code. Accumulate more than the count limit of
  discrete events across several merges, along with repeated titles, working
  directories, and progress values. Observe a single delivery whose discrete
  events are capped, whose retained bytes are within the byte limit, and whose
  title, cwd, and progress are each the newest value at the newest position.
  Add the byte-pressure case: a retained payload near the byte limit followed by
  a replaceable value that cannot fit, where the older value survives. The
  current concatenating merge fails this on the count bound and on coalescing.
- PO3 (I4): a behavioral test that accumulates repeated acknowledgements --
  several with no generation, several sharing one generation, and one carrying a
  different generation -- and observes one retained acknowledgement per distinct
  generation value. Pair it with a model-level assertion that a wait held at a
  given generation is still retracted by the single surviving acknowledgement
  that carries it.
- PO4 (I5): the existing `TerminalPaneSessionTests` suites pass unchanged --
  they assert `onSemanticEvents` ordering and result adoption across staged and
  flushed signals. Add scalar-field coverage across two merges within PO2's
  test, which no existing test exercises: `stagePendingUpdateSignalForTesting`
  is called once in the whole suite.
- PO5 (I6): a new behavioral test. No existing test covers this --
  `flushedSignalResultStillYieldsRecording` stages exactly one signal and
  asserts a recording, and `synchronizeStateNeverPublishesAStaleRow` is about
  render-plan freshness, not pending-signal merge and take ordering. The test
  must arrange a *real* scheduled delivery, not a staged payload:
  `stagePendingSignal` writes `pendingSignal` without setting
  `isUpdateScheduled` or enqueuing a hop, so a staged-only setup proves fence
  delivery and clearing while never exercising the stale queued callback. Drive
  a real `scheduleUpdate`, accumulate a multi-field payload behind it, run a
  synchronous fence, and assert that the fence delivers the accumulation once
  and the already-queued callback delivers nothing.

## Non-goals

- No change to publish cadence or to what the signal carries.

## Rejected ideas

- A field-by-field accumulator struct in the boundary's `State` (the audit's
  original ideal). It duplicates the signal's field list in a second place and
  adds a second construction site for the same result. D1 shares the retention
  rule without duplicating the signal's fields.
- Do not drain the engine until the consumer takes the payload, so the engine's
  own bounded accumulator is the only accumulator in the path and the boundary
  holds a flag. This is the structurally ideal shape -- the pending payload
  exists only because the host drains eagerly on its own queue and then has to
  park the result. Rejected because the main hop would then need a synchronous
  fence into the host queue on every delivered frame, which is the main-thread
  cost the asynchronous hop exists to avoid, plus a reverse wakeup so a payload
  parked behind a stalled hop still ships when the child goes quiet. Raise it
  again only if the delivery boundary grows further state.

## Files

- `lib/TerminalCore/Sources/TerminalCore/` -- the D1 retention surface, and
  `Terminal`'s accumulator rebuilt on it.
- `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift` --
  `TerminalPTYUpdateSignal`: the bounded mutating merge.
- `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift` --
  both `TerminalPaneDeliveryBoundary` merge sites accumulate in place instead of
  rebuilding.
- Tests in `lib/TerminalCore/Tests/` and
  `lib/TerminalPTY/Tests/TerminalPaneSessionTests/TerminalPaneSessionControllerTests.swift`.

Ordering note: PTY-3 and PTY-4 also edit `TerminalPTYHost.swift`, but in
textually disjoint regions (read loops, capture buffers); this change needs no
sequencing against them.

## Verification

1. Write the PO2, PO3, and PO5 tests; run them against unmodified code and see
   PO2 fail on the count bound and on coalescing.
2. Apply the change; targeted runs:
   `swift test --package-path lib/TerminalCore` and
   `swift test --package-path lib/TerminalPTY --filter TerminalPaneSessionTests`.
3. `just test` for the full gate.

## Implementation discretion

- The shape of the D1 surface and how the engine supplies the hyperlink bytes
  that share its budget, as long as one implementation serves both layers.
- The name and shape of the mutating merge, and which stored properties become
  `var`.
- Whether the boundary's two merge sites share one helper.

## Commit progress
- [x] 1. Extract J6 semantic-event retention into one TerminalCore surface (D1, PO1)
- [ ] 2. Bound the pending update signal's accumulation on that surface (D2, I1-I6, PO2-PO5)

## Implementation notes

- The shared surface (`TerminalSemanticEventRetention`) does not own stream
  order or the reclaim of external bytes. Order arrives from the caller because
  the PTY accumulator numbers input acknowledgements in the same sequence as
  terminal events (D2/I4), and one counter has to cover both. External bytes
  stay with the caller because a closure that reclaims them would have to
  capture the engine's whole `self` while the accumulator already holds
  exclusive access to one of its properties. Instead `admit` reports *why* it
  refused (`.droppedForCount` versus `.droppedForBytes`), and the engine sweeps
  dead hyperlink targets and retries once -- exactly the old control flow, with
  no sweep on a count refusal.
- `Terminal.maximumTerminalMetadataBytes` survives as a name for the retention
  surface's own `maximumRetainedBytes`, because the hyperlink admission
  arithmetic reads it too and one constant is what keeps the two halves of the
  budget from diverging.
