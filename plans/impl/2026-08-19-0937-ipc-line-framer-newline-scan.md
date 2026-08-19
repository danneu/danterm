# WIRE-1: Frame IPC lines by scanning for the newline, not byte-at-a-time

Source: docs/scratch/2026-08-18-construction-audit.md, WIRE-1 (4x5, small,
wave 1, confirmed + vetted).

## Problem

`IpcLineFramer.append` (lib/DanTermProtocol/Sources/DanTermProtocol/IpcLineFramer.swift)
is a per-byte loop with a `Data.append(byte)` call per non-newline byte -- a
non-inlinable cross-module call with a uniqueness and bounds check per byte.
It runs on every byte that crosses the IPC socket in both directions: the
app's read loop (`IpcConnection.startReading`) feeds it 4 KB reads, and every
client (`danterm` CLI via `DanTermClientSession.nextLine`, the iOS replica)
feeds it every reply and tape record. A `pane tape dump` or a followed mirror
stream carries megabytes, and even the everyday `danterm pane read` of a large
scrollback pulls its whole reply through this loop.

## Decision

Rewrite `append` as a whole-slice newline scan: search the unscanned region
for 0x0A with `withUnsafeBytes` + `memchr`. A line wholly contained in one
chunk is emitted as a slice of that chunk with no accumulation; only a line
that spans chunks touches the carry buffer, appended as one contiguous range.
The oversize check becomes arithmetic on the pending length instead of a
per-byte test.

`memchr` is load-bearing, not one option among two: `Data.firstIndex(of:)`
resolves to the default per-element Collection loop and keeps the
byte-at-a-time shape this change exists to delete.

By construction, a line that arrives whole inside one read has no separate
buffered copy at all -- no state that can disagree with the input.

This is a pure performance refactor: every input shape must frame identically
before and after.

## Invariants

- I1 (chunk invariance): any byte stream produces the identical event
  sequence regardless of how it is split into `append` calls.
- I2 (oversize boundary): a line of exactly `maxLineBytes` bytes followed by
  a newline is a valid `.line`. A line whose pending length exceeds
  `maxLineBytes` emits exactly one `.oversized`, and emits it as soon as the
  bound is exceeded -- without waiting for a newline that may never arrive.
- I3 (resync): after an oversize refusal, bytes are dropped until the next
  0x0A with nothing emitted, and the line after that newline frames
  correctly.
- I4 (empty lines): an empty line is emitted as a zero-length `.line` event
  in sequence with its neighbors (both consumers skip empties themselves).
- I5 (public surface): `IpcFrameEvent` (`.line(Data)` / `.oversized`) and the
  member set `init` / `append` / `maxLineBytes` do not change -- the file
  header pins this as the only public surface in the pure-core/support split.
  An emitted `.line` may now be a non-zero-based `Data` slice; both consumers
  are vetted safe (`IpcConnection` decodes with `JSONDecoder`,
  `DanTermClientSession` appends to `unread`; neither indexes from zero).

## Proof obligations

Characterization first: the current tests cover less than the audit claims
(no empty-line, no resync-after-oversize, no exact-boundary case). Write the
new cases in
lib/DanTermProtocol/Tests/DanTermProtocolTests/IpcLineFramerTests.swift
**before** touching production code and confirm they pass on the current
tree -- they are the safety net, not a red step.

- PO1 (I1): the same byte stream delivered as one chunk and as multiple
  chunks produces identical event sequences. Required split positions, the
  ones most likely to break slice arithmetic: mid-line; a chunk that is only
  `"\n"` (the carry holds the whole line, the chunk contributes zero bytes);
  a chunk boundary immediately after a newline (the carry must be empty);
  and a zero-length chunk mid-stream, which emits nothing and disturbs
  nothing. Existing `splitFrameReassemblesAfterSecondChunk` also covers
  reassembly.
- PO2 (I2): exactly `maxLineBytes` + newline emits `.line`;
  `maxLineBytes + 1` bytes emits `.oversized` even when no newline ever
  arrives (existing `oversizedLineEmitsRejectionEvent` pins the no-newline
  half). The boundary state must cross `append` calls: appending exactly
  `maxLineBytes` bytes in one call and the newline in a later call still
  emits `.line`, and a pending length carried from earlier calls that
  exceeds the bound in a later call emits `.oversized`.
- PO3 (I3): after a refusal, bytes up to the next newline are discarded and
  the line after it frames correctly -- proven in both compositions: the
  refusal, the discarded bytes, the resync newline, and the following line
  delivered in separate `append` calls (the discard state survives between
  calls), and all delivered in one `append` call, which must return
  `[.oversized, .line(following)]` (the scan loop continues past the refusal
  instead of early-returning).
- PO4 (I4): an empty line between two full lines emits three events in
  order, the middle one zero-length.
- PO5 (I5, existing tests): the four `IpcLineFramerTests`, the
  `ClientSessionTests` split-across-chunks case, and the app-tests oversize
  end-to-end case (`eachExitRecordsExactlyOneClose`, `.oversizedLine` arm,
  run by `just test`) all stay green with no edits.

Do not assert the framer's internal buffer shape in any test.

## Non-goals / Accepted risks

- Non-goal: no change to the wire format, the event type, or either consumer
  (`IpcConnection.swift`, `DanTermClientSession.swift` need no edit).
- Non-goal: WIRE-2 (typed tape records) and WIRE-3 (batch notifications) are
  separate audit items.
- Non-goal: no new benchmark harness. No calibrated instrument on the
  performance ladder reaches this path -- state plainly that the win is
  unmeasurable by an existing command.
- Accepted risk: the win is argued structurally, not measured. The work
  model is one `memchr` scan per chunk segment and at most one contiguous
  carry append per chunk, which beats one cross-module call per byte for the
  reads both feeders actually produce (4 KB and whole replies). Degenerate
  tiny reads (a one-byte chunk pays scan setup the per-byte loop did not)
  could in principle regress and stay unmeasured; the transport contract
  permits any positive read size, but no feeder produces such streams.

## Implementation discretion

- Internal carry representation (`Data` vs `[UInt8]`) and the scan-loop
  structure, within I5's public-surface pin.
- How the carry buffer is reset after emitting a cross-chunk line (CoW makes
  `removeAll(keepingCapacity:)` moot once the event holds the buffer).

## Files

- lib/DanTermProtocol/Sources/DanTermProtocol/IpcLineFramer.swift -- the
  whole production change.
- lib/DanTermProtocol/Tests/DanTermProtocolTests/IpcLineFramerTests.swift --
  the new characterization cases.

## Verification

1. `swift test --package-path lib/DanTermProtocol` -- new cases green before
   the rewrite, everything green after.
2. `swift test --package-path lib/DanTermClient` -- the split-across-chunks
   client-session case.
3. `just test` -- the full gate, which includes the app-tests oversize
   end-to-end case (`scripts/run-test-suite.sh` runs
   `swift test --scratch-path .build-app-tests`).

## Implementation notes

- A refusal that finds a newline later in the same chunk resynchronizes
  inline instead of entering the discard state and re-scanning for that
  newline on the next loop turn. The old per-byte loop could not tell the
  two apart; the scan already knows where the newline is. PO3's
  one-call case pins the behavior either way.
- A line contained in one chunk is emitted as `data[index..<newline]`, a
  non-zero-based `Data` slice, which is what makes the no-copy path real.
  I5 admits this and both consumers were vetted; the gate's end-to-end
  CLI and app IPC tests exercise it against `JSONDecoder` for real.
- The oversize check is `carry.count + segment.count > maxLineBytes` on
  the whole pending line, so it fires on the segment that crosses the
  bound rather than on a byte. PO2's two-chunk case pins that the count
  carries across `append` calls.

## Follow Up

- The first `just test` run of this change failed 8 cases in
  `CLICharacterizationTests` and 1 in `AppRuntimeSessionCommandTests`,
  all with `DanTerm is not responding` or `NSPOSIXErrorDomain Code=60`
  after ~30 seconds. The same filter passes in 0.27 seconds alone, and a
  second full gate run passed all 103 steps, so these are load flakes:
  the client liveness deadline these tests depend on is not sized far
  enough above what the oversubscribed gate pool can deliver. Worth
  resizing that deadline, per the house rule that no test may fail on
  whether production was fast enough.
