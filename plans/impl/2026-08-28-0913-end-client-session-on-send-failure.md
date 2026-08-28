# A failed send ends the client session

Source: `docs/scratch/2026-08-26-improvement-audit.md`, CLI-2 (Wave 11), pivoted
from the transport-level fix it proposes.

## Problem

`DanTermClientTransport.send` (`lib/DanTermClient/Sources/DanTermClient/ClientTransport.swift`)
promises "Writes every byte, or throws. A partial write is the transport's
problem to retry." Neither conformance retries: `TCPSocketTransport.send` and
`UnixSocketTransport.send` throw `.timedOut` / `.writeFailed` part way through a
newline-framed line and leave the stream open. `DanTermClientSession.send`
rethrows without tearing down. The session can therefore hold a state that is
"open but framing-desynchronized": a second request appended to a truncated
line yields one corrupt frame at the server.

Every caller today (`PeerLivenessMonitor` via `peerDeclaredSilent`,
`MobileSessionController.beginStream`, the one-shot CLI) closes the session by
hand after a send failure, so the corruption is unreachable in this tree. The
contract is still false, and its enforcement is repeated at each caller and
owed by the next one.

## Decision

Enforce the rule once, in `DanTermClientSession`: any error thrown by
`transport.send` ends the session (records a death reason, cancels, and throws
an end-of-session error). The seam's doc changes to what is true: a transport
writes every byte or throws, and after a throw the stream is unusable and the
session closes it.

Why the session and not the transports (the audit's proposal):

- One enforcement point holds for every conformance -- both sockets, the test
  doubles, and any future transport -- instead of being re-implemented per
  socket file.
- The audit's placement would close from inside `SocketDescriptorLifetime.withDescriptor`,
  which waits for its own borrow to return: a self-deadlock. The close has to
  happen after the borrow returns, i.e. at the call site, which is the session.
- Distinguishing "no byte written" from "some bytes written" buys nothing: no
  caller retries a send. Treating every send failure as terminal makes the
  distinction unrepresentable.

Callers that already cancel on send failure (`peerDeclaredSilent`,
`MobileSessionController.beginStream`) keep working through the existing
idempotent lifecycle; deleting their now-redundant cancel is in scope where the
observable outcome is unchanged. The watchdog keeps recording `peerSilent`
first, so that reason still wins over the generic send-failure reason.

## Invariants

- I1. After `DanTermClientSession.send` throws, the session is cancelled: the
  transport has been closed, and every later `send` throws an end-of-session
  error without reaching the transport.
- I2. A blocked or later read on a session ended by a send failure reports the
  failure as a death reason, not as a caller-requested `cancelled` and not as a
  silent end of stream. The underlying transport error remains observable from
  the first `send`'s throw.
- I3. A send failure on a session the watchdog already declared silent, or that
  its owner already cancelled, keeps the earlier reason.
- I4. The seam doc and the two transports agree: no transport promises a retry.

## Proof obligations

- PO1 (I1): a scripted transport whose `send` throws after accepting part of
  the line; the first `send` throws, `close` was called on the transport, a
  second `send` throws an end-of-session error and delivers no bytes.
- PO2 (I1, real sockets): a socketpair with a tiny send buffer and a peer that
  never reads; an oversized request fails, and a second request never reaches
  the peer after it starts reading.
- PO3 (I2): the reader parked in `awaitReply` / `nextFrame` on that session
  wakes with the send-failure death reason.
- PO4 (I3): watchdog-declared silence followed by a send failure still reports
  `peerSilent`; owner cancel followed by a send failure still reports
  `cancelled`.

Tests live in `lib/DanTermClient/Tests/DanTermClientTests` beside
`ClientSessionTests.swift` and `ClientLivenessTests.swift`. Timing values, if
any, follow `agent-docs/test-timing.md`.

## Non-goals

- CLI-10 (per-instance read buffer): blocked on its own measurement; the close
  path it needs already exists and is unchanged here.
- Retrying a partial write inside a transport (the audit's cheaper fallback):
  rejected, it makes `sendTimeout` unbounded exactly when the peer is wedged.
- No CLI surface change; `integrations/danterm/SKILL.md` is untouched.

## Implementation discretion

- The spelling of the send-failure death reason in `DanTermClientError`
  (a new case carrying or wrapping the transport error) and whether the first
  `send` rethrows the transport error or the death reason, so long as I2 holds.

## Verification

- `swift test --package-path lib/DanTermClient` into a file, grep for failures.
- `just lint`, then `just test` before commit.

## Commit progress

- [x] 1. fix(client): end the session on any send failure (session teardown,
      seam doc, redundant caller cancels removed, tests for I1-I4)
- [x] 2. docs(audit): mark CLI-2 complete -- tick its `## Plan of work` line in
      `docs/scratch/2026-08-26-improvement-audit.md` with `-- done <hash of 1>`;
      CLI-10 stays unticked (blocked on measurement)

## Implementation notes

- The new session death reason joins MobileKit's exhaustive failure maps as a
  transient lost connection that preserves the stored resume position.
- `sendFailed` carries no associated error. The first `send` rethrows the exact
  transport error, while later operations need only the stable terminal reason;
  this keeps `DanTermClientError` equatable and sendable.
