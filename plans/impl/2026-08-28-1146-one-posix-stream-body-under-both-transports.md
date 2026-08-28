# One POSIX stream body under both client transports

Source: audit finding CLI-10 in
`docs/scratch/2026-08-26-improvement-audit.md`, verified 2026-08-28.

## Problem

`UnixSocketTransport.receive()` and `TCPSocketTransport.receive()`
each allocate and zero a fresh 64 KiB array on every call, then copy the
bytes read into a `Data`. `receive()` runs once per wake-up on a followed
tape stream, so a chatty pane pays a 64 KiB `calloc` + memset per
notification, independent of the bytes delivered.

The `send()` and `receive()` bodies of the two transports are identical
except for the error enum each throws. Both already delegate descriptor
ownership and cancellation to `SocketDescriptorLifetime`
(`lib/DanTermClient/Sources/DanTermClient/SocketDescriptorLifetime.swift`),
so the descriptor's owner is the natural owner of the read buffer and of
the read/write loops.

Premises (verified):

- P1. Only one reader is active on a transport at a time: every
  `transport.receive()` is reached through
  `DanTermClientSession.nextLine()`, which runs under the session's
  `readLock` (`DanTermClientSession.swift:317`, `:353`). The seam
  (`ClientTransport.swift`) promises one read and one write concurrently,
  never two reads.
- P2. The close path already exists (CLI-2, commit 2e7dddc7):
  `SocketDescriptorLifetime.close()` waits for every borrower before
  releasing the descriptor, so no operation is mid-flight once close
  completes.
- P3. The server side (`DanTermSupport/IpcConnection.swift:99`) already
  allocates once per connection; it is not part of this change.

## Decision

Move the read buffer and the `send`/`receive` loops into the object that
owns the descriptor: `SocketDescriptorLifetime` (or one sibling helper it
wholly owns -- implementer's choice). Each transport's `send`/`receive`
becomes a one-line call that maps the shared outcome (timed out, read
failed, write failed, peer closed, cancelled) onto its own public error
enum. The buffer is allocated once per instance and lives as long as its
owning object; close guarantees only that no operation touches it after
close completes.

Behavioral scope: no change to any public error case, to the seam
protocol, to the session, or to the wire. Client CPU per delivered
notification drops; nothing else moves.

## Invariants

- I1. `receive()` performs no heap allocation proportional to the buffer
  size per call after the first; its cost is proportional to the bytes
  read plus the returned `Data`.
- I2. The returned `Data` is an independent copy. A later `receive()`
  never mutates a value an earlier call returned.
- I3. Each transport still throws exactly the error cases it throws
  today, for the same conditions: `timedOut` on EAGAIN/EWOULDBLOCK,
  `readFailed`/`writeFailed` on other errno, `peerClosed` on a
  zero-byte write, `DanTermClientTransportError.cancelled` after close,
  and empty `Data` at EOF.
- I4. Close semantics are unchanged: close wakes a blocked read, waits
  for active operations, and rejects every later operation. The buffer
  is not touched by any operation after close completes.
- I5. The two transports contain no duplicated POSIX loop. Adding a
  third conformance over a descriptor reuses the shared body.

## Proof obligations

- PO1 (I1). A socketpair test, for both transports, warms the stream
  with one read, then drives `receive()` many times with small chunks
  while an instrument counts allocation *events* of at least the buffer
  size. The count must be zero and the number of sampled receives must be
  nonzero. Live-heap statistics do not discharge this: the current body
  frees its 64 KiB array before returning, so live bytes stay flat today.
  The test must be shown to fail against the current per-call allocation
  before the fix lands (TDD red). `UnixSocketTransport` already has a
  `connectedDescriptor:` init for socketpair tests; `TCPSocketTransport`
  needs an equivalent or a loopback listener as
  `TCPSocketTransportTests.swift` already uses.
- PO2 (I2). Two consecutive `receive()` calls with different payloads;
  the first result is unchanged after the second call.
- PO3 (I3). The existing typed-error tests
  (`TCPSocketTransportTests`: "every TCP connection rejection stays a
  typed session error"; `ClientSessionTests`: partial-write, send
  failure, cancellation cases) must pass unchanged. Add one per-transport
  case for each mapped outcome that no existing test reaches.
- PO4 (I4). Existing cancellation tests ("cancelling a loopback session
  wakes a blocked reader without a frame", "cancelling a blocked reader
  returns no frame and closes only once", "cancellation waits for an
  active send") pass unchanged. Those session tests run against test
  doubles, so add one real-transport test (socketpair or loopback, as
  `ClientSessionTests` "a partial socketpair write ..." already does with
  a peer that stops reading): close while a shared-body `send` is
  blocked, prove close does not complete before that send releases its
  borrow, and prove a later operation throws
  `DanTermClientTransportError.cancelled`.
- PO5 (P1, I1 safety). The single-reader rule is restated at the buffer
  property, and the seam doc in `ClientTransport.swift` keeps its "one
  read and one write" sentence.

Gate: `swift test --package-path lib/DanTermClient`, then `just lint`,
then `just test` before commit. The audit's measurement
(`scripts/terminal-pane-tape-observer-tax.py` at the follower cap) is
optional confirmation, not a gate; PO1 is the structural proof.

## Non-goals / Accepted risks / Rejected ideas

- NG1. No change to `IpcConnection` (server side) or
  `TailnetWhoisResolver`; neither has the per-call allocation.
- NG2. No change to buffer size (64 KiB stays; shrinking it trades one
  fixed cost for more syscalls on large `pane snapshot` syncs).
- NG3. No unification of the two public error enums. They are the
  transport's user-facing vocabulary and differ deliberately
  (`unresolvedHost`, `accessDenied`, ...).
- RI1. A stored buffer on each transport (the finding's literal fix):
  fixes the allocation twice and leaves the duplicated loops.
- RI2. Reading straight into the session's framer buffer: would move
  byte-level IO above the transport seam, which the seam exists to hide.
- AR1. A shared body throws one internal outcome type that each
  transport maps; a mapping omission would surface as a compile error
  (exhaustive switch), not a runtime gap.

## Implementation discretion

- Whether the shared body is `SocketDescriptorLifetime` itself or a
  helper it owns, and whether the buffer is `[UInt8]` or a raw
  allocation; either way it lives for the owning object's lifetime.
- The allocation-event instrument PO1 uses (Darwin `malloc_logger`
  hook, a counting malloc zone, or similar).

## Commit progress

- [x] 1. refactor(client): share one buffered POSIX stream body

## Implementation notes

- The shared body is `SocketDescriptorLifetime` itself, and it keeps that name even
  though it now owns the buffer and the loops as well as the descriptor: the plan
  names the type, and a rename is outside the change it describes.
- The buffer is one raw allocation freed in `deinit` after `close()` returns, which
  is what makes the free safe -- close waits for every borrower.
- PO1's instrument is Darwin's `malloc_logger` hook, filtered to the sampling
  thread so a parallel test cannot contribute a count. Its suite is serialized
  because the hook is process-wide. Against the old body it counted 64 events for
  64 receives on each transport; against the new one, zero.
- PO3 is discharged for every outcome a real socket can produce: `timedOut` on both
  transports, `readFailed` through a TCP peer that resets, `writeFailed` through a
  departed socketpair peer, EOF as empty data on both, and `cancelled` in the close
  test. `peerClosed` stays unreached: POSIX cannot return zero from a stream write
  with a nonzero count, so it is a defensive branch with no observable trigger. The
  exhaustive switch is what keeps it honest, per AR1.
- `TCPTestListener` became internal so the shared-body suite can drive the same
  loopback peer instead of copying it.
- The close-during-send test waits for the socket to stop being writable rather
  than for a signal from the sending thread: the signal fires before the call, not
  inside it, and the earlier version raced close ahead of the blocked write.
- PO4 asks the real-transport test to prove close does not complete before the
  blocked send releases its borrow. That exact ordering is not provable from
  outside the transport: close wakes the write, so the release and close's return
  land microseconds apart in either order, and asserting the order would be a race
  rather than a proof. The deterministic proof of the wait is the existing
  `ClientSessionTests` "cancellation waits for an active send", whose double
  controls when the write releases. The real-transport test therefore proves what
  only a real socket can: a write blocked inside the shared body is woken by close,
  ends in the transport's own stream vocabulary rather than as `cancelled`, and
  every later operation is fenced.

## Follow Up

- `just test` is red on master for an unrelated reason: the `DanTermProtocol` test
  target does not compile. `lib/DanTermProtocol/Tests/DanTermProtocolTests/IpcRequestTests.swift:510`
  passes `outputMode:` to `CLICommand`, which commit `0211f226` removed.
