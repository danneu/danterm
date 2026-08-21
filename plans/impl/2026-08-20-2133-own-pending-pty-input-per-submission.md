# Own pending PTY input per submission, not as one rebased buffer

Source: XPORT-3 in `docs/scratch/2026-08-18-construction-audit.md`, verified
against the tree on 2026-08-20.

## 1. Problem

`TerminalPTYHost` keeps every byte still short of the PTY in one shared
`[UInt8]` buffer, a read offset into it, and a queue of spans whose end
coordinates are indexes into that buffer. Because a span is only meaningful
relative to the buffer's current start, any operation that moves the start
has to rewrite every span:

- `compactPendingInputIfNeeded` runs on every `enqueueInput` whenever a
  previous write left bytes behind: it copies the whole unwritten remainder
  (up to the 8 MB pending limit) and rebuilds the span queue.
- `rejectCurrentInputSpan` (added 2026-08-20 with the canonical-input gate)
  removes the head span's bytes from the middle of the buffer and rebuilds
  the span queue the same way, once per canonical timeout.

N enqueues against a backed-up child -- a stalled or slow process, a large
paste, a stream of `danterm pane send` calls -- cost O(N * remaining). The
work runs on the PTY owner's serial queue, which every main-actor fence
waits behind. Two assertions in `recordWrittenInput` police the
"span offsets match the buffer" invariant by hand.

Load-bearing premise: `flushInput` already bounds every `write()` to the
head span (`min(span.endOffset - pendingInputOffset, ...)`), so the syscall
shape never depends on submissions being contiguous with each other. The
shared buffer buys nothing the write loop uses.

## 2. Decision

Replace the shared buffer, the read offset, the span queue, and compaction
with a queue of per-submission records. Each record owns the bytes it was
submitted with -- the caller's array, no copy on enqueue -- together with
its origin, submission id, and attribution. One cursor says how much of the
head record has crossed. A running byte total serves the pending-input
limit and `resourceSnapshot().pendingInputByteCount`.

Consequences:

- A coordinate that is only valid until the next compaction no longer
  exists, so the rebase and both assertions go away by construction.
- Enqueue, head rejection, and clear are O(1) in the number of queued
  submissions and bytes (clear is O(records) to release them).
- The write loop is unchanged in shape: one contiguous pointer per
  `write()`, 64 KiB per turn, EAGAIN installs the write source, a partial
  write advances the cursor and records only what crossed.
- Rejecting the head submission (canonical timeout) is a pop; clearing the
  queue still drops the canonical hold and still answers every queued
  submission, exactly as today.

Scope is the private pending-input state of the `TerminalPTYHost` actor in
`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`. Nothing
outside that file names this state; no package, IPC, or CLI surface moves.

## 3. Invariants

- I1. Each submission completes exactly once. Submissions admitted to the
  descriptor queue complete in submission order, and `.delivered` only after
  the last byte of that submission crossed the PTY. A submission refused at
  admission (the pending-input byte limit) or by lifecycle state (sealed
  descriptor, ended process) completes immediately with its rejection, which
  may land before an earlier admitted submission that is still stalled.
- I2. Every `.write` tape event carries the origin and attribution of the
  submission its bytes came from, and the tape holds exactly the bytes the
  PTY accepted: a partial write records the written prefix and nothing
  more.
- I3. A submission that stalls under backpressure does not stop a later
  submission from being accepted into the queue, and the later one crosses
  after the earlier one with its own attribution intact.
- I4. Rejecting the head submission (canonical-mode timeout) leaves queued
  later submissions deliverable and correctly attributed.
- I5. `resourceSnapshot().pendingInputByteCount` is the number of bytes
  submitted and not yet written -- it falls as a partial write crosses and
  by the unwritten remainder when a head submission is rejected -- and the
  pending-input byte limit (`PaneProcessLifecycleReducer.pendingInputByteLimit`)
  rejects a submission on that same count.
- I6. Teardown behavior is unchanged: sealing or closing the master rejects
  everything queued as `.processEnded`, clearing the queue cancels the
  canonical hold, and an armed canonical hold never blocks release.
- I7. Syscall shape is unchanged: at most one submission per `write()`,
  bounded by the per-turn limit.

## 4. Proof obligations

- PO1 (I3, I2, I1): a large submission stalls against a childless channel
  nobody reads; a second submission with a different origin is accepted;
  draining the child end completes both in order and the tape's per-origin
  `.write` bytes concatenate to exactly each submission's own payload;
  `pendingInputByteCount` counts both submissions while stalled and reaches
  zero after the drain (I5). New test; nothing today combines a stalled
  prefix with a second enqueue. It passes on the current tree -- write it
  first as characterization.
- PO2 (I4, I5): a canonical-mode child holds an oversized line; a short line is
  submitted before the timeout fires; the oversized one is rejected with
  `.canonicalModeTimeout`, the short one is `.delivered`, the child echoes
  it, and no oversized bytes reach the master. While the short line is still
  queued, `pendingInputByteCount` drops to exactly its unwritten byte count,
  so the rejected head releases its own capacity (I5). New test (today's test
  submits the probe only after rejection). Passes on the current tree.
- PO3 (I1, I2, I5, I6, I7): the existing host suite in
  `lib/TerminalPTY/Tests/TerminalPTYHostTests/TerminalPTYHostTests.swift`
  passes unchanged -- in particular "descriptor close rejects a partially
  written submission", "input the child has not accepted stays out of the
  tape", "accepted input is recorded as transmitted, under the origin it was
  submitted with", "pre-spawn input overflow rejects the whole later
  submission", "synchronous input and resize submissions preserve their
  shared FIFO order", "input submitted after shutdown sealing cannot rearm
  descriptor IO", "teardown releases a host whose canonical input hold is
  armed", and the canonical-input tests. The test helpers that poll
  `pendingInputByteCount` keep their meaning.
- PO4: `lib/TerminalPTY/Tests/TerminalPaneSessionTests/ControllerSubmissionsWithoutOrigin.swift`
  passes unchanged.
- PO5 (I5, I1): on an already-running host under real backpressure (nobody
  reads the child end), a first submission stalls with only a prefix across
  the master; the test reads `pendingInputByteCount`, submits exactly the
  remaining capacity under `pendingInputByteLimit`, and expects that
  submission to be accepted; one more byte is rejected with
  `.bufferLimitExceeded` while the earlier submissions are still queued;
  draining the child end completes the queue and `pendingInputByteCount`
  returns to zero, after which a fresh submission is accepted again. New
  test; the existing overflow test exercises the pre-spawn limit in
  `PaneProcessLifecycleReducer`, never the host's own enqueue-time check.
  It pins the host's running byte total, which this refactor rewrites.
- No elapsed-time assertion. The quadratic term is established by reading
  the two rebase sites; the honest measurement (stop the child, issue N
  sends, watch per-send time go flat) is a bench note, not a gate.

## 5. Non-goals / Accepted risks / Rejected ideas

- Non-goal: changing pre-spawn input buffering, which lives in
  `PaneProcessLifecycleReducer`, not in the host's queue.
- Non-goal: any new observation seam on the host;
  `scripts/terminal-pty-host-test-seam-lint.sh` stays green.
- AR1: the pending limit bounds bytes, not submission count. A flood of
  one-byte submissions under backpressure allocates one record per
  submission, as today it allocates one span per submission; the byte limit
  is the same bound it was.
- AR2: a partially written head record keeps its already-written prefix
  alive until the record pops, while the byte limit counts only unwritten
  bytes -- so a pane can hold close to 16 MB of payload storage while
  reporting at most the 8 MB pending limit. Today's enqueue-time compaction
  reclaims that prefix instead. Accepted: freeing the prefix means adding
  head-record compaction -- a threshold and a copy of the head's remainder --
  which is exactly the kind of hand-held buffer state this plan exists to
  delete. The retention is bounded and per-pane, so it does not earn that
  state back.
- RI1: `Deque<UInt8>` as the shared buffer (the audit's original ideal) --
  cannot hand `write()` a contiguous pointer; rejected.
- RI2: absolute lifetime-byte span coordinates plus half-buffer compaction
  (the audit's Correction) -- keeps a shared buffer, a base offset, and a
  compaction threshold that exist only to serve a contiguity the write loop
  never needed; strictly more hand-held state than per-submission records.

## 6. Implementation discretion

- Record shape, the name of the running total, and whether the head cursor
  lives in the record or beside the queue.
