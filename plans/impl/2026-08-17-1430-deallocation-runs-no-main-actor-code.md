# Deallocation runs no main-actor code

## Problem and evidence

`AppRuntime.deinit` calls `MainActor.assumeIsolated` to run
`schedulingLifecycle.shutdown()`. A `deinit` is nonisolated and runs on whichever
executor drops the last reference, so this asserts a fact the compiler cannot
check and callers can silently break: not "the owner releases on main", but
"whoever drops the *last* reference is on main".

`IpcServer` breaks it. The server is an actor holding a `weak` runtime, but it
materializes strong temporaries on its own executor -- one across the
main-actor hop in its request dispatch, one across the `await` in its
connection-close path. Either can be the last reference.

Load-bearing premises, each verified against the tree:

- **The trap is reachable in the test suite today.** Ten tests in
  `app-tests/IpcServerRemoteTests.swift` wire a real `AppRuntime` to a real
  `IpcServer`. `IpcServer.stop()` is nonisolated and returns after spawning its
  close work, and reader callbacks spawn their own tasks, so a task can still be
  mid-`await` when the test frame drops the main-actor reference. This is a
  racy crash vector in the gate, not a theoretical one.
- **The deinit protects nothing reachable.** It has an effect only on a runtime
  deallocated without `shutdown()`, and its only genuinely leaking owner is the
  switcher `NSEvent` monitor. That monitor is armed only under
  `startsApplicationServices: true`, which occurs at exactly one site --
  `AppDelegate` -- whose owner never releases the runtime and always calls
  `shutdown()`. No test can arm it. Every other owner category is either an
  empty cancel closure or dies safely with the object.
- **The two teardown paths are not equivalent.** `AppRuntime.shutdown()` sends
  `.runtimeWillShutdown`, answers pending IPC, and unsubscribes sessions; the
  deinit runs only the scheduling census. The fallback is a second, weaker
  teardown semantics rather than a backstop for the real one.
- **`shutdown()` is already terminal and idempotent**, guarded by the scheduling
  lifecycle's permanent shutdown state, and every runtime-constructing test
  already calls it.

## Decision

Delete `AppRuntime.deinit`, and change `IpcServer` to hold a `Sendable`,
main-actor-bound dispatch handle instead of the runtime object.

The first removes the trap: a deallocation that runs no code cannot assume an
executor. The second removes the softer hazard the first leaves behind -- a
`@MainActor` runtime, holding AppKit state, deallocating on a cooperative
thread. With the handle owning a weak reference that is strengthened only
inside its main-actor body, the server structurally cannot own an `AppRuntime`
reference on its own executor. That covers both existing call sites and every
future one, because the server no longer has the object to capture.

Teardown becomes solely the owner's explicit `shutdown()`, unchanged.

Rules 2/3 of `docs/design/2026-06-09-appkit-lifetime-safety.md` say observers and
monitors remove their tokens in `deinit`, and `AGENTS.md` restates that. Their
stated intent -- no callback after teardown -- is satisfied more strongly by the
terminal, census-backed `shutdown()`, and the `AGENTS.md` sentence already admits
"or a documented owner-bound lifetime". Amend both to say so, in this change.
Two `Consequences` paragraphs in that note describe `AppRuntime`'s deinit
behavior and are already stale; correct them in the same pass.

## Invariants

- **I1.** Deallocating an `AppRuntime` runs no code that assumes main-actor
  isolation. This is a claim about deallocation-time work only; it does not make
  destruction of the runtime's AppKit-owned fields executor-independent, which is
  why I2 exists.
- **I2.** `IpcServer` never holds a strong `AppRuntime` reference, transiently or
  otherwise. Every strong reference to the runtime is created and released inside
  a main-actor body, so the server can never perform the final release.
- **I3.** Registering a request's connection and sending its message remain a
  single main-actor turn, preserving the per-connection ordering guarantee.
- **I4.** `AppRuntime.shutdown()` remains the only teardown path, terminal and
  idempotent.

## Proof obligations

- **PO1** (I1). Releasing a runtime's last reference off the main actor completes
  without trapping, establishing that deallocation performs no isolation-assuming
  work. Against the current code this fails as a process trap rather than an
  expectation failure; the test preamble says so. The proof is about
  deallocation-time work, so a runtime without application services discharges it.
- **PO2** (I2). With a dispatch in flight -- the handoff begun, its main-actor
  body not yet run -- releasing the owner's reference leaves no strong runtime
  reference held on the server's executor. This must fail on the unmodified tree,
  where the server strengthens the runtime before the hop; a proof that only
  observes retention after the handoff completes does not discharge it.
- **PO3** (I2). Closing a peer retires the runtime-owned state for that
  connection -- its pending request transports and follow subscriptions -- and not
  only the server's own audit record. The close path crosses the new boundary, so
  a handle that never forwards the close must fail this.
- **PO4** (I1, I2). The existing remote-IPC suite stays green with requests in
  flight while the owning frame releases the runtime.
- **PO5** (I3). Per-connection ordering of served requests, drops, and close
  records is unchanged -- discharged by the existing ordering tests.
- **PO6** (I4). `shutdown()` stays terminal and idempotent, and the owner census
  empties -- discharged by the existing scheduling-lifecycle tests.

## Non-goals

- Changing what `AppRuntime.shutdown()` does, or when its owner calls it.
- Reintroducing deallocation-time cleanup in any form, including a
  compiler-checked one.

## Accepted risks

- **AR1.** With no deallocation-time cleanup, a future owner that releases a
  runtime without calling `shutdown()` leaks the switcher event monitor for the
  process lifetime. Accepted because no current or test-constructible owner can
  arm that monitor, and the failure mode it replaces is a crash rather than a
  late cleanup.

## Rejected ideas

- **RI1.** `isolated deinit` running the scheduling census -- the house idiom,
  with six precedents in `app/`. Rejected: it preserves a second, partial
  teardown semantics whose only distinct effect guards an owner nothing can
  reach, and it adds an asynchronous lifetime tail with no ordering against
  process exit. It makes the trap impossible without removing the redundancy
  that produced it.
- **RI2.** Weak-capturing the runtime at each `IpcServer` call site. Rejected:
  it turns a lifetime invariant into a coding convention every future call from
  the actor must re-observe, and it leaves the object available to capture.
- **RI3.** Having `IpcServer` hold the runtime strongly. Rejected: the runtime
  owns the server, so this is a retain cycle.

## Implementation discretion

- The handle's shape -- one closure per runtime entry point, or a small struct
  of them -- provided I3 keeps registration and send in one main-actor body.
- How the test fixture in `app-tests/IpcServerRemoteTests.swift` builds a handle
  for the runtime-less cases it currently covers by passing nil.

## Critical files

`app/AppRuntime.swift` (delete the deinit; build the handle where it constructs
the server), `app/IpcServer.swift` (stored handle and its three call sites),
`app-tests/IpcServerRemoteTests.swift` (fixture), a new test for PO1 and PO2,
`docs/design/2026-06-09-appkit-lifetime-safety.md`, `AGENTS.md`, and the note's
row in `docs/design/index.md`.

## Verification

1. Write the PO1, PO2, and PO3 tests first, and run them against the unmodified
   tree. PO1 dies in `AppRuntime.deinit` -- the expected red state. PO2 and PO3
   must fail as ordinary expectations; a green PO2 or PO3 there means the test
   is not exercising the window it claims to.
2. Apply the change, then `just test`. PO4, PO5, and PO6 are discharged by
   suites that already exist, so a green gate is the evidence for them.
3. Run the remote-IPC suite repeatedly (it already iterates its timing-sensitive
   proofs) to exercise the race that made the trap reachable.
4. `just test` includes `scripts/docs-lint.py`; the doc amendment must keep the
   note's `Status`/`Date` header shape and its existing `allow-missing` marker.
5. Launch a slot and exercise IPC end to end -- `danterm --socket <slot> ...` for
   a request, a follow stream, and `quit` -- to confirm the handle change did not
   alter live request handling or clean shutdown. Release the slot afterward.

## Commit progress
- [x] 1. Give IpcServer a main-actor dispatch handle instead of the runtime
- [ ] 2. Delete AppRuntime.deinit and amend the lifetime-safety rules

## Implementation notes

- The handle is one `serve` closure that registers the transport and sends the
  message together, plus a `connectionClosed` closure. One closure per entry
  point would have split registration from the send and lost I3.
- PO1 lives in its own file, `app-tests/AppRuntimeDeallocationTests.swift`,
  because it needs no server. That also lets it land with the deinit deletion,
  in the second commit, while PO2 and PO3 land with the handle in the first.
- Verification step 1 is wrong about PO3: the code before this change does
  forward the close, so PO3 passes there. It was shown to discriminate by
  mutation instead -- deleting the forward makes it fail. PO2 does fail on the
  unmodified tree as an ordinary expectation, and PO1 dies as a process trap,
  both as the plan says.
- PO2 needs the request parked at the main-actor boundary before it releases
  the owner's reference. It syncs on the `requestStarted` audit record, which
  the server writes just before the handoff, and then waits a fixed 250ms. No
  signal exists between that record and the strong capture the old code made,
  and holding the main actor means the wait cannot overshoot the handoff.
- PO3 keeps a request pending with `tab.new`: the recording session never
  reports its process start, so the reply waits and the transport stays
  registered. It syncs on the runtime's own subscription census, then proves
  the retirement through the socket -- `shutdown()` answers pending IPC, so the
  peer reads an answer instead of end-of-stream if the close never arrived.
