# One ordered event handoff per IPC connection

## Context and problem

A connection's reader produces a total order: bytes arrive, `IpcLineFramer`
splits them, and one dedicated thread walks the resulting events in sequence.
`IpcServer.beginService` then throws that order away. It hands
`IpcConnection.startReading` three separate callbacks and routes them three
different ways -- requests through `Task { await self?.dispatch(...) }`, the
close through a second unstructured `Task`, and the decode-failure audit
record written inline on the reader thread. Independently created unstructured
tasks have no ordering guarantee on an actor, so the order the server acts in
is re-established only by scheduling luck.

Four consequences, worst last:

- A `requestDropped` record can land after that connection's
  `connectionClosed` record.
- A decode failure written inline can be logged before a request that preceded
  it on the wire.
- Two pipelined requests can reach the runtime in the opposite order to the one
  the peer sent them in.
- `close` can run before a pending `dispatch`. `close` removes the connection
  state; `dispatch` opens by requiring it. A request the peer sent before
  hanging up is then silently discarded: not performed, not audited, and not
  counted in the close record's served-request total.

Evidence: the first three are read from the code. The fourth was observed --
`app-tests/IpcServerRemoteTests.swift`'s audit-sequence test failed under gate
load reporting one missing `requestDropped`, and passed in isolation.

Desired outcome: what the server does and records for one connection follows
the order its bytes arrived in, by construction rather than by luck; a request
that arrived before a close is never lost to it; and a peer cannot make the
server buffer without limit.

Load-bearing premises:

- `IpcConnection`'s reader already produces events in wire order on its own
  dedicated GCD thread, which already blocks in `read`. The order is lost only
  at the delivery boundary, so nothing about how bytes are read needs to
  change, and blocking that thread costs nothing that is not already spent.
- `beginService` is the only caller of `startReading` in shipping code; both
  the local and the tailnet accept paths funnel through it. Every remaining
  caller is a socket-level test in `lib/DanTermSupport`.
- Every audit append is synchronous and ends in `fsync` under a process-wide
  lock, so appends happen in call order and each costs on the order of a
  millisecond.
- `AppRuntime.send` runs update, command performance, and reconcile
  synchronously on the main actor, and takes a non-async closure. Nothing on
  the main actor waits on `IpcServer`, so making the reader wait on the actor
  introduces no reachable deadlock.
- Replies are not uniformly synchronous: `readDoctorPermissions` writes its
  reply from an unstructured task after `send` returns. The server therefore
  cannot promise an order for what reaches the wire, only for what it does and
  records.
- `lib/DanTermClient` has its own reader and never touches `IpcConnection`, so
  the client cannot be dragged in by a change to this boundary.
- The liveness contract's receive deadline lives on the blocking read itself
  and is untouched here.

## Decision

**One event type, one delivery route, and at most one event outstanding per
connection.**

- `IpcConnection` delivers a single ordered sequence of connection events --
  request, malformed request, close -- through one callback invoked on the
  reader thread, with the close emitted exactly once on every exit including
  the oversized-line exit. Three callbacks were what invited three routings;
  collapsing them makes "these are one ordered sequence" a fact of the type
  rather than a convention.
- The callback hands one event to the server and **waits for the server to
  finish handling it before reading further**. Ordering then follows from
  there being nothing to order: a second event does not exist until the first
  is done. Backpressure follows for the same reason, and the buffer is the
  kernel's socket buffer, which is already bounded and already pushes back on
  the peer.
- The acknowledgement is signalled by the submitting work itself, not by the
  server, so a reader is never stranded by a server that has gone away.

This shape has no queue, no bound to choose, no consumer task to own or
cancel, and no teardown protocol of its own -- out-of-order handling is not
prevented, it is inexpressible. It needs two lifetime rules, both of which the
tree already needed and neither of which holds today: a socket must be shut
down before it is closed, or a write parked at a peer that stopped reading
keeps the descriptor past teardown; and stopping the server must keep it alive
until its connection cleanup has run, or the cleanup is skipped entirely and
every idle reader is left blocked on a descriptor nobody closes.

This is deliberately scoped to the delivery boundary. The reader stays a
blocking thread per connection; replacing it with a readiness-based reader is
its own designated plan, and this boundary is what that plan would feed, so
doing this first makes it smaller rather than larger.

## Invariants

- **I1.** For one connection, the order in which the server dispatches
  requests, records decode failures, answers a malformed line, and records the
  close is the order the reader produced them in.
- **I2.** A request that arrived before the peer's close is dispatched and
  counted in that connection's served-request total. This binds for a
  peer-initiated close and for reclamation at the silence bound; it does not
  bind across server stop, where the server abandons pending work by design.
- **I3.** The reader emits exactly one close event per connection, on every
  exit, and emits nothing after it. Server stop remains a second, independent
  close source whose record may precede pending events; the connection state
  is removed once, so only one `connectionClosed` record is ever written.
- **I4.** No reader thread or file descriptor outlives the server that owns it,
  and neither a peer that has stopped reading nor a server that has gone away
  can prevent that.
- **I5.** A peer cannot make the server buffer arriving requests unboundedly:
  sustained arrival faster than the server handles stops the reader rather
  than growing memory. This governs the inbound path only; what the server has
  already decided to send is not bounded here.

## Proof obligations

Deterministic:

- **PO1 (I1).** A connection that sends a good request, a malformed line, and
  another good request in one write, then closes, produces audit records in
  exactly that order. The sequence must arrive without a reply round trip
  between lines; round-tripping hides the defect.
- **PO2 (I3).** Exactly one close is observed per connection on each exit:
  peer close, silence bound, and oversized line.
- **PO3 (I4).** After server stop, a peer that had stopped reading -- so the
  connection's write is parked -- reaches end of stream. The test must drop
  its own reference to the server as soon as it has called stop, before it
  waits: holding one alive would prove nothing about the teardown that
  production performs.

Repetition-based -- the pre-fix failure is a race, so these pin the invariant
and detect the old defect only across iterations:

- **PO4 (I2).** A request written immediately before the peer closes its end is
  served, answered, and included in the close record's count. Run it enough
  times that a pre-fix regression is caught, and state the iteration count.
- **PO5 (I2).** The same shape with no id: the drop record precedes the close
  record. This is the observed flake.

I5 has no test: observing that a reader is waiting requires stalling the
server and inspecting a thread, which is structure-sensitive and would flake.
It follows from at-most-one-outstanding, which PO1 already exercises.

## Non-goals

- The readiness-based connection reader -- its own designated plan.
- The order in which replies reach the wire. `readDoctorPermissions` answers
  from an unstructured task after `send` returns, so no per-connection reply
  order can be promised without sequencing every asynchronous completion,
  which is a larger contract than this problem needs. This plan constrains
  what the server does and records.
- The client's reader in `lib/DanTermClient`.
- Automatic client retry and backoff -- its own designated plan.

## Accepted risks

- **AR1.** Moving the decode-failure record onto the actor means a peer
  flooding malformed lines blocks the actor, and therefore other connections,
  on that record's `fsync`. Accepted rather than split across two append
  mechanisms: the write-ahead gate must stay synchronous because service is
  conditioned on its durability, and a non-uniform audit path costs more than
  this does at a cap of eight remote connections.
- **AR2.** A reader waiting on the server is not inside `read`, so the silence
  bound is not being measured then, and reclamation of a peer that dies during
  a long request is delayed by that request. Accepted: a reader waiting on the
  server means the server is behind, which is not the condition the bound
  exists to detect.
- **AR3.** A connection no longer reads its next line while handling the
  current one, where today it could parse ahead. End to end this changes
  little, because the main actor already serialized the work; unread requests
  now wait in the kernel's socket buffer instead of in the process, and a peer
  pipelining behind a heavy request feels it as flow control.
- **AR5.** A connection's outbound write queue is unbounded: a peer that
  sends reply-producing requests and never reads parks the writer, and the
  encoded replies pile up in process memory. This is untouched here and
  predates the plan -- the inbound throttle does not reach it, because each
  request is handled promptly and it is the answers that accumulate. Bounding
  it needs write-side backpressure that does not block the main actor, which
  is a separate architectural change.
- **AR4.** The null-id parse error moves into the ordered handler for
  uniformity, which puts its audit record and its reply on one timeline. Its
  position relative to an asynchronously completed reply is still not
  promised, per the non-goal above.

## Rejected ideas

- **RI1.** Making the audit-sequence test wait for the drop record before
  closing the socket. It hides the misordering and leaves the lost-request bug
  alive; it adds a wait to a test to accommodate an ordering the server should
  not have.
- **RI2.** Returning an `AsyncStream` from `startReading`. It forces all seven
  socket-level tests in `lib/DanTermSupport` to become async -- three of them
  block their thread in socket syscalls and would move onto the cooperative
  pool -- introduces async to a module that has none, places the ordering
  guarantee in the layer that never lost it, and cannot express backpressure,
  because yielding from a synchronous producer never blocks.
- **RI3.** A buffered per-connection channel drained by a consumer task. It
  reaches the same ordering guarantee through a queue, a bound, a stored task,
  and a teardown protocol that must wake a producer blocked on the channel --
  a second blocking location that closing the socket cannot reach. Waiting for
  each event removes the queue the race lives in.
- **RI4.** A per-connection serial dispatch queue that hops to the actor. Each
  hop creates a task, so the ordering problem returns unless the queue blocks
  on every hop.

## Critical files

- `lib/DanTermSupport/Sources/DanTermSupport/IpcConnection.swift` -- the event
  type and the single delivery callback replacing the three; close emitted on
  every exit, including the oversized-line exit that returns from inside the
  framing loop; a shutdown-then-close path reachable for any connection, not
  only one reclaimed at the silence bound.
- `app/IpcServer.swift` -- `beginService` submits each event and waits for it;
  `dispatch`, the decode-failure record, the null-id parse reply, and `close`
  become that handler's arms; `closeConnections` shuts sockets down before
  closing them, and `stop` keeps the server alive until it has run.
- `lib/DanTermSupport/Tests/DanTermSupportTests/IpcConnectionLivenessTests.swift`
  and `IpcConnectionWriteTests.swift` -- seven call sites collapse their
  closures into one switch, staying synchronous and thread-based. The
  malformed-envelope test keeps its recovered-method assertion; its `-32700`
  wire assertion moves to the app tests with the reply itself.
- `app-tests/IpcServerRemoteTests.swift` -- the audit-sequence test becomes
  deterministic and needs no wait added; PO1 through PO5 belong beside it.

## Implementation discretion

- The acknowledgement primitive, provided it signals unconditionally and does
  not block a cooperative-pool thread.

## Verification

`just test` is the gate. Targeted: `swift test --package-path lib/DanTermSupport`
covers the delivery boundary, and `swift test --scratch-path .build-app-tests`
covers the ordering the audit log records. PO1 through PO3 are deterministic.
PO4 and PO5 are repetition-based: report the iteration count rather than
treating one green run as proof.

## Implementation notes

- The acknowledgement is a `DispatchSemaphore` the submitted `Task` signals from
  a `defer`, so it is signalled whether the handler returns, throws, or finds
  the server already gone. The reader thread that waits on it is the connection's
  own GCD thread, which already blocked in `read`, so no cooperative-pool thread
  is blocked.
- Teardown is two named operations rather than one. `close()` releases the
  descriptor behind the writes already queued, so the answer to the peer's last
  request still reaches it; `forceClose()` shuts the socket down first and is
  used only where the peer has stopped participating -- reclamation at the
  silence bound and server stop. Making every close force the shutdown was tried
  first and lost PO4's reply: a peer that half-closes its write end is still
  reading, and the forced shutdown truncated the answer it was owed.
- The decode-failure record now reads the caller from the live connection state,
  like `dispatch` does, instead of the caller captured when service began. A
  malformed line on a connection the server has already forgotten therefore
  records nothing, which matches how a request on that connection is treated.
- PO3 waits for every request it sent to be answered before it stops the server.
  Stopping with requests still in flight releases `AppRuntime` from the server's
  task rather than from the test, and `AppRuntime.deinit` requires the main
  actor -- see the follow up below.

## Follow Up

- `AppRuntime.deinit` (`app/AppRuntime.swift:270`) calls `MainActor.assumeIsolated`,
  which traps when the last reference is released off the main actor.
  `IpcServer.dispatchToRuntime` holds a strong reference across its main-actor
  hop and drops it on the actor's executor, so any owner that releases the
  runtime while a request is in flight crashes the process instead of failing.
  Production is safe only because AppDelegate outlives the server. Either give
  the hop a reference it cannot own last, or make the deinit safe off main.
