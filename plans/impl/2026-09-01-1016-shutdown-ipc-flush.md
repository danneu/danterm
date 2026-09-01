# Plan: deterministic IPC error replies at quit (shutdown owns the exit sequence)

## Problem

When the app quits with IPC requests still pending, the pure core already
produces the right answer: `Update.swift`'s `.runtimeWillShutdown` arm
(lib/DanTermCore/Sources/DanTermCore/Update.swift:927-944) drains
`pendingSessionCreations` and `pendingInputSubmissions` and emits one
`.ipcError(-32603, "application shut down before ...")` per request. The
existing test "runtime shutdown rejects pending creation and input requests"
(lib/DanTermCore/Tests/DanTermCoreTests/UpdateSessionEventTests.swift:90-127)
pins that behavior.

The runtime loses the reply on the way out. `applicationWillTerminate`
(app/AppDelegate.swift:797-804) calls `runtime?.stopIpcServer()` BEFORE
`runtime?.shutdown()`:

- `stopIpcServer()` (app/AppRuntime.swift:736-740) calls `IpcServer.stop()`
  (app/IpcServer.swift:327-332), which schedules an async Task that
  `forceClose()`s every serviced connection (app/IpcServer.swift:387-402).
  If that Task wins the race against the main thread's drain, `writeLine`
  sees `closed == true` and silently drops the error reply
  (lib/DanTermSupport/Sources/DanTermSupport/IpcConnection.swift:475-486).
- Even when the write is enqueued in time, it runs asynchronously on the
  connection's serial write queue (IpcConnection.swift:488-503) and nothing
  waits for it before the process exits.

Honest framing: this is a determinism and diagnosability fix, not an urgent
correctness one. The CLI never hangs -- process exit closes the descriptors,
the blocking read returns EOF, `awaitReply` returns nil
(lib/DanTermClient/Sources/DanTermClient/DanTermClientSession.swift:195-216),
and `resolveReply` throws "DanTerm closed the connection" (cli/main.swift:483-489)
with a nonzero exit. But the caller nondeterministically gets either the
explanatory `-32603` reply or that generic error, so the same failure reads
differently run to run.

### Load-bearing premises (verified)

- P1: Every `[.terminate]` command funnels into the drain. The `.terminate`
  performer (app/AppRuntime.swift:1025-1034) calls `ports.terminateApp()` ->
  `NSApp.terminate` -> `applicationShouldTerminate` returns `.terminateNow`
  (app/AppDelegate.swift:785-793, a catch-all that also funnels external
  `NSApp.terminate` calls through the quit confirmation) ->
  `applicationWillTerminate` -> `runtime.shutdown()` dispatches
  `.runtimeWillShutdown` (app/AppRuntime.swift:752-757).
- P2: The pure core is already the ideal shape; the drain is tested.
- P3: `AppRuntime.shutdown()`'s closing `schedulingLifecycle.shutdown()`
  already retires the IPC server owner -- it is registered with
  `retire: { $0.stop() }` (app/AppRuntime.swift:220-224). The delegate's
  early `stopIpcServer()` call is a duplicate stop that only changes the
  ordering, and its comment at the `.terminate` performer
  (app/AppRuntime.swift:1026-1027) already claims `shutdown()` is the single
  owner of follow-on teardown. `stopIpcServer()` has exactly one caller.
- P4: The queued replies are blocking `Darwin.write`s on a per-connection
  serial queue, so a bounded wait on that queue is a flush to the kernel.

## Decision

Fold the IPC stop into `AppRuntime.shutdown()` so one function owns the exit
sequence its own comment claims to own, and add a bounded synchronous flush
between the drain and the close:

1. dispatch `.runtimeWillShutdown` and perform its `.ipcError` commands
   (already present);
2. flush the write queues of the connections those replies went to,
   synchronously, under a bound;
3. only then let teardown close the listener and force-close what remains
   (per P3, the existing `schedulingLifecycle.shutdown()` tail already does
   this).

`applicationWillTerminate` drops its `stopIpcServer()` line and the method is
deleted with it. The ordering becomes structural: a future arm that returns
`.terminate` contains nothing it could get wrong, because the delegate no
longer sequences IPC teardown at all.

This is the ideal per the design bar: the race cannot be reintroduced by
call-site ordering because the call sites that could be misordered no longer
exist. Nothing simpler achieves the flush -- reordering the delegate calls
alone removes the drop race but still exits without waiting for the async
writes.

## Invariants

- I1: A caller whose request is pending at orderly quit receives the
  explanatory `-32603` reply, deterministically rather than as one side of a
  race, whenever the reply reaches the kernel before the total flush bound of
  I3 expires. Expiry is governed by AR1.
- I2: `AppRuntime.shutdown()` is the sole owner of the IPC exit sequence
  (drain, then flush, then close). No delegate method or `.terminate`-returning
  arm sequences any part of it.
- I3: Quit never blocks unboundedly on a peer. The flush guarantee is "bytes
  handed to the kernel, or peer provably gone" -- never "peer read it" -- and
  the total wait is bounded and small (operator-facing quit latency).
- I4: `lib/DanTermCore` is unchanged.

Scope of I1: it holds only for the `NSApp.terminate` funnel (P1), which the
`applicationShouldTerminate` catch-all makes total for every in-process and
external terminate request. A crash, SIGKILL, or an unhandled signal never
reaches `applicationWillTerminate`; on those paths the caller keeps getting
the generic connection-closed error, and the invariant claims nothing.

### Effects on the rest of `applicationWillTerminate`

The reorder moves the IPC stop from before `prepareRecoveryForApplicationExit`
to inside `shutdown()` after it. In the window between them the main thread
never yields, incoming IPC work dispatches to the main actor and so cannot
interleave, and `registerIpcConnection` guards on `schedulingLifecycle.isActive`
(app/AppRuntime.swift:707-710), so a request landing in the window is closed,
not serviced. `terminalBackend?.terminateForApplicationExit()` and
`deleteSessionLockFile` remain after `shutdown()`, undisturbed.

## Proof obligations

- PO1 (P2, drain): already discharged by the existing pure test cited above.
  No new core test.
- PO2 (I1 + I3, flush behavior): behavioral test in `lib/DanTermSupport`
  against a real socketpair/pipe: a reply enqueued before the flush is
  readable by the peer once the flush returns; a peer that has stopped
  reading a full backlog does not hold the flush past its bound. Deadlines
  per agent-docs/test-timing.md.
- PO3 (I1 + I3, runtime wiring): extend the existing app-level harness
  `app-tests/AppRuntimePendingIpcShutdownTests.swift` so it proves the
  wiring, not just eventual delivery. Two behaviors:
  - Both pending replies are readable by their peers as soon as
    `runtime.shutdown()` returns, with no manual `connection.close()` first.
    Today's test reads only after closing by hand, so it would still pass if
    `shutdown()` omitted or misordered the flush.
  - With several pending connections whose peers have stopped reading a full
    socket backlog, `shutdown()` returns within one total bound, not one bound
    per connection. This is the observable form of I3's "total wait": an
    implementation that waits the bound once per connection fails it.
- PO4 (I2): structural, discharged by review, not by a test -- a test
  asserting call order inside `shutdown()` would pin private structure and
  fail the test bar. The deletion of `stopIpcServer()` and its call site IS
  the guarantee.
- PO5 (I4): no diff under `lib/DanTermCore`.

## Non-goals

- No guarantee on crash/SIGKILL/unhandled-signal exits.
- No "peer read it" acknowledgment; kernel handoff is the ceiling.
- No change to CLI nil-reply semantics (`resolveReply` keeps treating a
  missing reply as expected success for instance-ending methods).
- No per-arm rejection logic: the drain stays in the one
  `.runtimeWillShutdown` arm; nothing is multiplied across
  `.terminate`-returning arms.

## Accepted risks

- AR1: The bounded wait is irreducible. A peer that is wedged but not
  provably gone can still lose the reply when the bound expires, and every
  quit with a stuck peer pays up to the bound. Accepted: the alternative is
  an unbounded quit hang, which is strictly worse.

## Rejected ideas

- RI1: Just swap the two delegate calls (`shutdown()` before
  `stopIpcServer()`). Removes today's drop race but leaves the ordering as a
  property of three sequenced calls in a delegate method -- exactly the shape
  that produced the bug -- and still exits without flushing the async writes.
- RI2: Wait for the peer to acknowledge the reply. Unbounded quit; violates I3.

## Implementation discretion

- The shape of the flush surface (on `IpcConnection`, the transport wrapper,
  or the runtime) and how `shutdown()` knows which connections the drain
  wrote to.
- The numeric flush bound; if a test freezes it, follow
  agent-docs/measurement-discipline.md.

## Commit progress

- [x] 1. feat(ipc): add bounded connection write flushing
- [ ] 2. fix(shutdown): flush pending IPC errors before server teardown
