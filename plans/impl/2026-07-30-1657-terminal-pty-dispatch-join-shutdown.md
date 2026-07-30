# Unify TerminalPTY shutdown around a Dispatch join barrier

## Problem and desired outcome

TerminalPTY now avoids Swift task groups during application exit, but
exit-reachable code still has three lifecycle weaknesses:

- Main-actor relay tasks and host continuations can remain suspended when
  `applicationWillTerminate` blocks main.
- Descriptor-backed Dispatch sources are canceled before their PTY descriptor
  is closed, but teardown does not wait for cancellation handlers as required
  by [Apple's Dispatch source guidance](https://developer.apple.com/documentation/dispatch/dispatchsourceprotocol/setcancelhandler(handler:)).
- Ordinary close and application exit expose overlapping APIs and reducer
  events despite sharing one teardown policy.

The desired outcome is one shutdown transaction:

`request shutdown -> stop deliveries -> cancel and join sources -> close PTY
-> resolve child/spawn ownership -> publish quiescence`

Application termination may block until that transaction completes because
AppKit terminates the process after `applicationWillTerminate` returns.
Completion must remain truthful rather than racing cleanup against an
application-level timeout.

## Decision and interface changes

- Keep `TerminalPTYHost` as an actor bound to its serial Dispatch executor.
  Apple's custom-executor and `assumeIsolated` APIs support this low-level
  ownership pattern; do not replace it with a queue-protected class or
  per-pane thread.
- Give the host one idempotent shutdown operation used by natural exit, pane
  close, test runners, and application exit. Remove the reducer's
  `.appTermination` event and retain one close event because termination
  origin does not change lifecycle policy.
- Preserve two distinct boundary operations:
  - A synchronous controller fence stops all UI deliveries, initiates
    shutdown, and returns the final accepted terminal snapshot for recovery.
  - A process-lifetime handle requests shutdown or registers a quiescence
    observer without retaining the pane controller.
- Replace the app-facing async termination method with dispatch callbacks:
  - `whenQuiescent` observes natural or requested completion without
    initiating shutdown. Observers run on the host queue, including observers
    registered after quiescence.
  - `requestShutdown` initiates shutdown and completes only at quiescence.
  - Async convenience wrappers remain package/test-support only and wrap the
    callback API outside the production exit path.
- Move backend registry removal directly onto `whenQuiescent`. Remove
  `TerminalPaneSessionController.onTeardownCompleted` and the main-delivery
  cleanup path so registry lifetime depends only on host ownership.
- Keep `TerminalBackend.terminateForApplicationExit()` synchronous. It
  snapshots the registry, requests every remaining host's shutdown, and waits
  on a `DispatchGroup` with no outer timeout.

### Dispatch resource ownership

- Install a cancellation handler on every Dispatch source when the source is
  created.
- Retain and count a source until its cancellation handler runs; calling
  `cancel()` is only a request and must not reduce the resource census.
- Seal descriptor ownership when shutdown is requested. After that point no
  read or write source may be created, and queued input or write-ready work is
  discarded instead of installing or rearming a source.
- Ensure every source admitted to the resource census can run its cancellation
  handler. A source that has not been activated must be activated before
  cancellation rather than left permanently suspended.
- Treat read/write source cancellation handlers as the PTY descriptor's join
  barrier. Close the master exactly once, from the final descriptor-source
  cancellation handler after every source monitoring that descriptor has
  acknowledged cancellation.
- Treat process and timer cancellation handlers as callback joins. Host
  quiescence cannot publish until all source cancellation handlers have run.
- Split forced shutdown into nonblocking phases:
  1. Seal descriptor ownership, request source cancellation, and return to the
     owner queue.
  2. After descriptor cancellation handlers close the master, kill and reap
     the owned session and abandon any in-flight launch.
  3. Publish quiescence only after process ownership, spawn ownership, sources,
     callbacks, and pending writes are all resolved.
- Keep every phase from shutdown request through observer delivery on
  host-owned queues. No source join, process cleanup, registry removal, or
  quiescence observer may require main-queue progress.
- Preserve the existing truthful behavior when kernel launch, process census,
  or reap operations exceed the nominal host bound. No completion may precede
  cleanup.

### Swift concurrency removal from the exit-reachable path

- Replace pointer, link, search, and frame-update `Task { @MainActor ... }`
  relays with one stoppable main-queue delivery boundary.
- Preserve ordered delivery for semantic callbacks and coalescing for frame
  wakeups. Both modes check the stopped state before enqueue and again before
  invocation.
- Stop this boundary before the recovery fence initiates host shutdown;
  already queued blocks become inert.
- Remove the production `AsyncStream` update channel and use the dispatch
  update callback as the only host notification mechanism.
- Remove continuation-bearing result, output, and teardown waiters from the
  production host. Recreate any needed async waiting in test-support code by
  observing dispatch callbacks and reading fenced state.
- Add an architecture gate covering `lib/TerminalPTY/Sources/` and the
  production Swift backend adapter so new `Task`, `Task.detached`,
  `AsyncStream`, or continuation-based shutdown bridges cannot enter the
  application-exit ownership path. Exempt `lib/TerminalPTY/TestSupport/` and
  `lib/TerminalPTY/Tests/`, where async adapters remain legitimate.

## Invariants

- **I1.** Application exit creates or resumes no Swift task, async stream
  consumer, or continuation in TerminalPTY.
- **I2.** A shutdown completion means the PTY descriptor is closed, every
  Dispatch source cancellation handler has run, pending writes are discarded,
  the child session is resolved, and no host callback can execute later.
- **I3.** Pane close, natural child exit, close-during-spawn, and application
  exit converge through the same shutdown transaction.
- **I4.** Every registered quiescence observer fires exactly once; observers
  registered after completion fire immediately.
- **I5.** Main-actor callbacks accepted before the exit fence are either
  delivered before the fence or suppressed afterward; none cross the fence.
- **I6.** The backend retains every host until I2 is true and waits for every
  retained host before returning from application termination.
- **I7.** Forced teardown closes the PTY through its cancellation barrier
  before performing a blocking reap.
- **I8.** Requesting shutdown permanently seals the descriptor-source census:
  no later work can create or rearm a source, and every counted source is in a
  state whose cancellation handler is guaranteed to run.
- **I9.** Shutdown request, source joins, native cleanup, registry removal, and
  quiescence observers require only host-owned queues; none depends on main
  making progress.

## Proof obligations

- Prove source cancellation, descriptor closure, child cleanup, observer
  delivery, and backend group completion occur in that order, using
  controllable synchronization seams rather than elapsed-time sleeps.
- Exercise fd-number reuse after rapid pane teardown and prove a canceled
  source cannot read from or write to the replacement descriptor.
- Submit a write after cancellation is requested but before the final
  descriptor cancellation handler, and prove it is discarded without creating
  a source or touching a reused descriptor.
- Cover live, naturally exited, already-closing, already-quiescent,
  stalled-ladder, unresolved-spawn, and resolved-but-undelivered-spawn hosts
  through the same shutdown API. Close-during-spawn must include installed but
  inactive sources and prove their cancellation handlers run.
- Queue frame, pointer, link, and search deliveries behind the main actor,
  apply the exit fence, and prove every queued delivery becomes inert.
- Block main while a complete host shutdown runs and prove native cleanup,
  registry removal, every quiescence observer, and backend group completion
  finish without main-queue progress.
- Prove ordinary pane teardown and application exit have identical native
  resource outcomes and exactly-once registry removal. Register an observer
  strictly after quiescence and prove immediate delivery; also prove
  exactly-once delivery when observation and a shutdown request are both
  pending.
- Update existing lifecycle tests to use the single close event and move async
  stream/waiter conveniences into test support.
- Run `swift test --package-path lib/TerminalPTY`, `just test`, and the
  architecture gate.
- Manually repeat fresh-launch Cmd-Q, pointer/search activity followed
  immediately by Cmd-Q, and saturated-scrollback resize followed by Cmd-Q.
  Confirm clean exit with no crash report or surviving owned process.

## Boundaries and assumptions

- Process-census performance, the unidentified original corrupting write,
  terminal rendering, resize coalescing, and process-broker/session-survival
  designs are out of scope.
- A dedicated per-pane IO thread is rejected: Ghostty's stop/join/destroy
  ordering is adopted, but Dispatch cancellation handlers provide DanTerm's
  join primitive without changing its executor architecture.
- WezTerm/iTerm2-style kill-without-wait destruction is rejected because it
  cannot satisfy truthful quiescence.
- Exact helper type names and test instrumentation are implementation
  discretion; the shutdown transaction, cancellation-handler barrier,
  callback boundary, and public handle semantics are fixed.

## Commit progress

- [x] 1. refactor(pty): unify shutdown observation around host callbacks
- [x] 2. fix(pty): join dispatch resources before publishing quiescence
- [x] 3. fix(terminal): fence UI delivery without Swift concurrency
- [ ] 4. fix(app): retain terminal hosts through exit quiescence
