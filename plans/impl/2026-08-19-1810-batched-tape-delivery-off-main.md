# WIRE-3: deliver a tape batch as one notification, encoded off the main actor

Source: WIRE-3 in [docs/scratch/2026-08-18-construction-audit.md](../../docs/scratch/2026-08-18-construction-audit.md).

## Problem

A followed pane tape delivers each batch as one `pane.tape.event` notification
per record: `writePaneTapeRecords`
(`lib/DanTermSupport/Sources/DanTermSupport/PaneTapeRecords.swift`) loops over
the batch calling `IpcConnection.writeNotification` once per record, restating
the subscription id in every envelope and issuing one `write` syscall per
record. Separately, `IpcConnection.writeLine` JSON-encodes on the calling
thread before handing bytes to the connection's serial write queue, so every
record on the follow path is encoded on the main actor: `deliverPaneTapeFollowBatch`,
`finishPaneTapeFollowStart` (whose opening records include the multi-megabyte
sync chunks of a reconstructible follow), and the end-record writers in
`app/AppRuntime.swift` are all main-actor callers. The finite-dump path hops to
a utility queue precisely to avoid this cost, so the path that runs
continuously while a replica mirrors a pane is the one paying it.

Load-bearing premises:

- PERSIST-6 and WIRE-2 have landed (`9967905a..b0ef4e7a`, `c0e4c026..c4d7ef21`,
  `3c51c633`): records are typed end to end, the notification envelope has one
  declaration (`PaneTapeEventNotification` in DanTermProtocol) that the
  producer and every reader instantiate, and `writeNotification` already takes
  generic `Encodable` params.
- The reader enforces a per-line framing bound (`IpcLineFramer.maxLineBytes`),
  and sync records already chunk their payload at a quarter of it, so a batch
  of several sync records encoded on one line can exceed the bound. A split
  rule is mandatory, not optional.
- Every party to this wire lives in this repo (client library, CLI, mobile
  kit, research spikes), so the internal wire shape may break freely.

Desired outcome: delivering a batch costs one envelope, one encode, and one
queued line -- produced on the write queue, never the main actor -- and a
batch is atomic on the wire except when the line bound forces a split. Fewer
write syscalls follow, but syscall count is diagnostic evidence, not a
promise: the writer loops on partial writes and must keep doing so.

## Decision

Two independent structural moves, in this order:

1. **Encode on the write queue.** `IpcConnection.writeLine` hands the
   `Encodable` value to the serial write queue and encodes there. Enqueue
   order is unchanged, so wire order is preserved, and there is no longer any
   thread but the write queue where line encoding can happen -- for every IPC
   write, not just tapes. Failure keeps its only existing channel, the
   completion delivered on the main queue; no caller reads a synchronous
   failure today.
2. **One notification per batch.** The `pane.tape.event` params carry the
   batch's records as an ordered array instead of one record. The envelope
   changes shape once at its single declaration and every reader follows it.
   A batch whose encoded line would exceed the line bound splits at record
   boundaries into consecutive notifications. The shape change advances
   `danTermIpcProtocolVersion`: a peer speaking the previous number would
   silently ignore every batched notification, which is exactly the skew the
   constant's contract refuses at hello.

Why this shape: the batch is already the atomic delivery unit in the model
(`PaneTapeBatch`); making it the wire unit removes the per-event envelope and
per-event queued write, and removes the place where the number of envelopes
and the number of events can diverge, by construction rather than by care.

No measured gate exists for this change (audit: no calibrated workload covers
it). The win is structural; a Time Profiler trace showing encode frames gone
from the main thread is diagnostic evidence, not an acceptance test.

## Invariants

- I1: JSON encoding of an IPC line runs on that connection's serial write
  queue -- never inline in the write call, and never on the main actor. (The
  queue is an execution context, not a dedicated thread; the contract is
  queue isolation, not thread identity.)
- I2: A delivered tape batch reaches the wire as a single notification
  carrying its records in order; it splits only when its encoded line would
  exceed the line bound, and only at record boundaries.
- I3: No emitted line exceeds the framing bound the reader enforces.
- I4: The stream ordering contract is unchanged: the start record precedes
  every record of its stream, records appear on the wire in the order they
  were handed over, and a stream's terminator is its last record.
- I5: A completion attached to a batch reports the flush of the whole batch,
  and reports failure if any part of it -- encoding included -- fails.
- I6: The CLI's `pane tape` stdout shape is unchanged: one record per line,
  regardless of how records were grouped into notifications.

## Proof obligations

- PO1 (I1): encoding does not run inline in the write call, runs on the
  connection's write queue, and never runs on the main actor.
- PO2 (I2, I4): a multi-record batch arrives as one notification with its
  records in order, and the existing follow tests still see every record in
  wire order across a pane close and a mid-stream failure.
- PO3 (I2, I3): a batch whose encoded size exceeds the line bound arrives as
  multiple notifications, each within the bound, together carrying every
  record in the original order.
- PO4 (I4): a record belonging to a sibling stream on the same connection,
  handed over after another stream's terminator, reaches the wire after it --
  connection-wide FIFO, with no record ever following its own stream's
  terminator.
- PO5 (I5): a batch containing a value that fails to encode reports failure
  through its completion; a flushed batch reports success.
- PO6 (I6): each production reader the wire change touches -- the CLI stream
  renderer and the mobile session model -- handles a multi-record
  notification identically to the equivalent per-record stream: every record
  processed in order, one CLI stdout line per record, and unchanged
  end/failure classification.
- PO7: a peer greeting with the previous protocol number is refused at hello,
  before any tape stream begins.

## Non-goals

- WIRE-6's payload copies (sync bytes materialized several times before
  base64) stay as they are.
- PERSIST-4 (confining the descriptor to the write queue) is separate work.
  It edits the same function; the textual conflict is accepted and whichever
  lands second rebases.
- No compatibility shim for the one-record-per-notification wire shape; every
  reader in the repo moves in the same change.
- No change to record shapes, the start reply, or the terminator vocabulary.

## Accepted risks

- AR1: Batching raises peak line size. I3's split rule is the bound, and its
  cost -- occasionally more than one notification per batch -- is accepted.
- AR2: Encode failures surface later (on the write queue rather than at the
  call site). Nothing observable is lost: the completion is already the only
  failure channel, and I5 makes it strictly more informative than today,
  where only the final record of a batch carries a completion and a failed
  middle record is invisible.

## Rejected ideas

- RI1: Batch at the byte level only -- encode per record, concatenate into
  one syscall, keep per-record envelopes. Rejected: it keeps the envelope
  cost per event and keeps the divergence between event count and envelope
  count that I2 exists to remove.

## Implementation discretion

- D1: How a batch's encoded size is measured against the line bound and how
  records group under it (encode-then-split, greedy grouping, estimate) --
  constrained only by I2 and I3.
- D2: The mechanism a test uses to observe the encoding context for PO1.

## Commit progress
- [x] 1. Encode every IPC line on the connection's write queue
- [x] 2. Deliver a tape batch as one `pane.tape.event` notification

## Implementation notes

- Slice 1: moving the encode across the queue boundary makes the written value
  cross an isolation domain, so `writeLine` and its three callers
  (`writeSuccess`, `writeNotification`, `writePaneTapeRecords`, plus the app's
  `IpcRequestTransport.writeSuccess`) now require `Sendable` as well as
  `Encodable`. Every existing caller already satisfied it.
- Slice 1: an encode failure reports through the completion and deliberately
  does *not* close the connection, unlike a failed write. No byte of the failed
  line reached the socket, so the peer's stream is short a record rather than
  corrupt, and closing would take out the connection's other streams. This
  keeps AR2's promise that nothing observable changes.
- Slice 2 (D1): the split is encode-then-halve, and it runs on the write queue.
  Measuring a group's size means encoding it, and encoding at the call site
  would put the JSON pass back on the actor slice 1 took it off, so
  `IpcConnection` gained `writeBatchedNotification`: it takes the elements plus
  a closure that wraps one group in the notification's params, encodes on the
  write queue, and halves a group whose line passes the bound. A group of one
  that still does not fit goes out whole -- there is no boundary left to split
  at, which is the same line the producer would have written before batching
  existed, and `TerminalFlightRecorderTests` is what holds a single record
  inside the bound.
- Slice 2: `docs/research/35-ios-remote-client`'s spikes still read the
  one-record envelope. They are historical measurement artifacts, no gate step
  builds them, and they speak protocol 3, so an upgraded app refuses them at
  hello before any record shape matters.
