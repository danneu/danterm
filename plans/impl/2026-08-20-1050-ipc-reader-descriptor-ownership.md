# Give the IPC connection's reader its own descriptor (PERSIST-4)

## 1. Problem and evidence

`IpcConnection` (`lib/DanTermSupport/Sources/DanTermSupport/IpcConnection.swift`)
holds one descriptor number, `fd`, and three independent users touch it: the
reader thread (`Darwin.read`), the write queue (`Darwin.write`), and the
lock-guarded shutdown in `forceClose`. One of them -- the write queue, in the
block `close()` enqueues -- releases the number for everyone. So either of the
other two can perform a syscall on a number the kernel has already handed to
another accepted connection, an audit-log file, or a checkpoint file.

Two concrete paths:

- Write side. `writeLine` and `writeBatchedNotification` read `closed` under the
  lock, unlock, and then enqueue their work. `close()` sets `closed` under the
  lock and then enqueues `Darwin.close(fd)`. The two enqueues can invert, so the
  close block runs first and the write block then calls `Darwin.write` on a
  reclaimed number.
- Read side. The reader loop runs `onEvent` between reads. A `close()` from the
  main actor (server stop, `app/AppRuntime.swift`, `app/IpcServer.swift`) can
  release the number while the reader sits in a callback; the next
  `Darwin.read(fd, ...)` then drains bytes belonging to whichever connection or
  file took the number over, and delivers them as this connection's requests.

Reachable in both directions: the reader thread calls `close()`/`forceClose()`
at loop exit while the main actor writes concurrently
(`app/AppRuntime.swift`, `app/PaneTapeBroker.swift`, `app/IpcServer.swift`). A
pane-tape follow writing while the peer hangs up is the realistic trigger.

WIRE-3 (`d95481da..9b467dd1`) moved the encode inside the queued block, so after
an inversion the block now encodes (milliseconds for a multi-MB sync chunk) and
only then writes -- the window in which the number can be reused got wider, not
narrower. The audit's "PERSIST-4 before WIRE-3" ordering and its proposed first
failing test (which relied on the inline encode) are stale.

Audit source: `docs/scratch/2026-08-18-construction-audit.md#persist-4`.

Desired outcome: no user of the connection can perform a syscall on a descriptor
number that has been released.

## 2. Decision

The reader gets its own descriptor for the socket, obtained by `dup`. Two
handles, two owners, and neither can reclaim a number out from under the other:

- **Read handle.** Created by `startReading` on the reader thread it belongs to,
  used only by that thread, and released only by that thread after the loop exit
  path has called `close()`/`forceClose()`. A connection that never starts a
  reader -- the refusal path, where `IpcServer` constructs a connection and calls
  `writeRejected` without reading (`app/IpcServer.swift:355`, `:428`) -- never
  creates one, so there is no handle without an owner.
- **Write handle.** The originally accepted descriptor, as an optional the write
  queue mutates and the lock reads. Every queued write reads it; a write that
  finds it nil does nothing to the socket and reports failure. The queued close
  shuts the socket down, releases the handle, and nils it, all inside the lock.
  `forceClose` takes the same lock to shut the socket down, so it can never
  target a number the queued close has already released, and it still bypasses a
  parked write.

The kernel refcounts the underlying socket across duplicated descriptors, and
`shutdown` acts on that socket rather than on the number
(`references/xnu/bsd/kern/kern_descrip.c#finishdup`,
`references/xnu/bsd/kern/uipc_syscalls.c#shutdown`). Socket-level options
(`SO_NOSIGPIPE`, the `SO_RCVTIMEO` deadline) likewise belong to the open file
description, so setting them through either handle covers both.

Two behavioral consequences follow and are intended:

- `close()` no longer tears the socket down merely by dropping the last handle,
  because the reader still holds one. The queued close therefore shuts the
  socket down explicitly before releasing the write handle. That is what makes
  the peer see EOF and the reader loop exit, in the same place it does today --
  after queued writes have drained.
- `forceClose()` after `close()` now interrupts a parked write instead of doing
  nothing, because the write handle survives until the queued close runs. Today
  that call is silently a no-op and the write stays parked forever.

The pre-queue `closed` checks in the write entry points stay. With the write
handle queue-confined they are no longer a second owner of descriptor
lifetime -- they only keep a caller that has been told the connection is closed
from putting more bytes on a socket that has not finished draining.

Scope: one source file, one test file. No wire change, no public API change in
`lib/`, no caller edits.

## 3. Invariants

- I1. Every descriptor number the connection holds is used and released by
  exactly one owner: the reader thread, or the write queue. No number is ever
  shared between the two, on any path including a failed `dup`.
- I2. No syscall runs on a released descriptor number.
- I3. A write the connection does not perform reports `false` through its
  completion, on the main queue, after the write call has returned (the existing
  uniform-delivery rule).
- I4. `close()` still drains: every write enqueued before it reaches the peer
  before the socket is torn down. `close()` is idempotent, and after it the peer
  sees EOF and the reader loop exits.
- I5. `forceClose()` fails a parked write immediately, whether or not `close()`
  has already run.
- I6. Wire order and batching behavior are unchanged.

## 4. Proof obligations

- PO1 (I2, read side). Drive the reader into an `onEvent` callback and hold it
  there; call `close()`; force the released number to be reclaimed by a live
  socket the test owns (`dup2` onto that exact number); release the callback.
  The connection must deliver no event carrying bytes written to the reclaimed
  socket, and the reclaimed socket's owner must still read those bytes itself.
  Red on the current implementation, which reads them.
- PO2 (I5). With a write parked against a peer that has stopped reading, call
  `close()` and then `forceClose()`. The parked write fails and its completion
  reports `false` within the test's guard. Red on the current implementation,
  where `forceClose` after `close` performs no shutdown.
- PO3 (I2, release paths). Wait for the connection to release everything, then
  reclaim its former numbers with live sockets the test owns. Call `close()`
  again, call `forceClose()`, and call both public write paths -- `writeLine`
  through a public entry point and `writeBatchedNotification`. Every completion
  reports `false`, no byte reaches the reclaimed sockets, and they stay usable.
- PO4 (I1, refusal path). A connection that is constructed and refused with
  `writeRejected`, and never started reading, releases every descriptor it took:
  after the close settles, its accepted number is free and no other number the
  test can account for is still held.
- PO5 (I4, I6). Existing `IpcConnectionWriteTests` pass unchanged, in particular
  the ordering, completion, closed-path, batch, and encode-on-queue tests.
- PO6. Existing `IpcConnectionLivenessTests` pass unchanged, in particular "the
  bound is honored while a write to an unreading peer is parked".
- PO7. `app-tests/IpcServerRemoteTests.swift` passes (integration net).

Every wall-clock value in these tests is a hang guard: 30 seconds under a
`.timeLimit(.minutes(1))` backstop, expiring as `POSIXError(.ETIMEDOUT)`.

## 5. Non-goals / Accepted risks / Rejected ideas

- Non-goal: a stress reproduction of the enqueue inversion as a gate test. It
  can only pass vacuously on broken code.
- Non-goal: sharing a descriptor owner with
  `lib/DanTermClient/Sources/DanTermClient/SocketDescriptorLifetime.swift`. Its
  close releases now; `IpcConnection.close()` drains first. Both packages depend
  only on `DanTermProtocol`, so sharing needs a new home. Note the difference in
  the commit message so nobody unifies them blind.
- Accepted risk: the write-side enqueue inversion itself has no red test. It
  needs two threads to interleave inside `writeLine` and `close()`, which no
  public seam exposes deterministically. Separate ownership makes it structurally
  impossible instead, and PO3 covers the release paths that would show the
  damage.
- Accepted risk: under descriptor exhaustion the reader's `dup` fails and the
  connection reads nothing, ending at once with its close reason. That is what
  exhaustion means for a connection either way; the only outcome I1 forbids is
  falling back to sharing the write handle's number with the reader, and no
  other path is affected because -1 is never a live number.
- Rejected: re-checking `closed` inside the queued block (audit's "cheaper
  fallback"). Two owners of one fact; the invariant stays a convention, and it
  leaves the read side untouched.
- Rejected: confining the single descriptor to the write queue alone. It fixes
  only the write path and leaves the reader using the same released number.
- Rejected: a third `dup` owned by the lock purely for `forceClose`'s shutdown.
  The lock can guard the write handle for that one call instead, which is the
  same guarantee with one fewer descriptor and one fewer owner.

## 6. Implementation discretion

- How each handle is represented (optional field vs box), and how
  `writeBatchedNotification` reports a write skipped on a released handle versus
  a failed socket write.

## Verification

- `swift test --package-path lib/DanTermSupport --filter IpcConnection`
- `just test`
