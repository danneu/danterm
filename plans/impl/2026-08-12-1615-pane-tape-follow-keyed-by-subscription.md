# Pane-tape follow state keyed by subscription (audit S38)

## Problem

One follow stream's runtime state is spread over four containers in
`app/AppRuntime.swift` (~190-196): the pure `PaneTapeFollowSubscriptions`
plus three sidecar maps, one of which (`paneTapeFollowConnections`) is keyed
by *connection* id while everything else is keyed by *subscription* id. The
connection entry is shared by every stream on that socket but removed one
subscription at a time, so two follows on one socket break each other:

- `discardPaneTapeFollow` deletes the shared connection entry; the sibling's
  next lookup in `fetchPaneTapeFollow` fails and the sibling is silently
  dropped -- no `end` record, no error.
- `endPaneTapeFollowers` `continue`s past siblings whose connection entry was
  already consumed, skipping their promised `end` record.

The many-streams-per-connection case is reachable (the IPC framer dispatches
every request on a socket) and explicitly modeled by the support layer
(`connectionClosed` returns an array). The documented contract in
`integrations/danterm/SKILL.md` -- "a pane close writes an `end` record" --
is violated. Two latent defects ride along:

- `discardPaneTapeFollow`'s `closeConnection: false` flag is ineffective:
  cancelling the scheduling token fires its cancel closure, which is
  `connection.close()`, so the socket closes anyway.
- The `.terminate` arm of `perform` re-clears all four maps immediately
  before `NSApp.terminate` reaches `shutdown()`, which clears them again.

This precedes the iOS tape broker (`docs/scratch/2026-08-12-ios-app.md`
sec. 8.3): the broker's resume semantics should attach to one subscription
value, not four maps that must agree.

## Decision

Do the audit's ideal fix. One stream value per subscription id holds the
stream's transport resources (its `IpcConnection`, scheduling token, and
recorder-notice registration) together; the connection-keyed map is deleted.
Every teardown site becomes: ask the pure layer which subscriptions end,
then dispose exactly those streams' resources.

Decisive constraints:

- **Two containers, split by lifetime.** `PaneTapeFollowSubscriptions`
  (lib/DanTermSupport) stays the pure per-subscription state machine;
  the resources value lives in one runtime map keyed by the same
  subscription id. Subscriber state and transport resources have different
  lifetimes -- the tape broker will keep the former across a connection
  drop and replace the latter -- so they must not be fused into one
  generic container. The resources map and its disposal helper are
  main-actor confined: they live on `@MainActor AppRuntime`, and
  `PaneTapeFollowNoticeRegistration` is itself `@MainActor`.
- **Socket close semantics (decided):** ending a stream writes its `end`
  record and retires that subscription's resources. The connection is never
  closed because a follow ended -- the client owns the socket lifetime, and
  a socket may carry unrelated requests the follow layer knows nothing
  about. It closes when the peer closes it (the existing
  `connectionClosed` sweep) or at app shutdown. Today's CLI is unaffected:
  it returns as soon as it reads the `end` record
  (`cli/PaneTapeFollowStream.swift`), and the server already serves further
  requests on a live connection (`IpcServer.dispatch`).
- **Failure ends (decided):** a stream retired by an internal failure while
  its socket is alive (batch prepare fails, encode throws, notice
  registration fails) writes an `end` record with a failure reason, instead
  of today's bare close. Additive wire change;
  `integrations/danterm/SKILL.md` is updated in the same change.
- **Every follow write for a connection enters one ordered enqueue path.**
  Batches and terminators alike go through the connection's serial write
  queue from a single enqueue site, so a subscription's `end` is serialized
  after every batch already accepted for it and nothing for that
  subscription is written after it. Today's per-record hop through the
  concurrent global queue lets a prepared batch and a pane-close terminator
  reach the socket in either order, which would make the terminal record
  non-terminal. The follow write helpers move to `DanTermSupport` (they
  touch only `IpcConnection` / protocol types) so socketpair tests exercise
  the production write path. The relocated helper keeps `IpcConnection`'s
  completion contract unchanged: the completion is
  `@MainActor @Sendable`, `IpcConnection.deliver` already hands it back
  asynchronously on the main actor in FIFO order with the writes queued
  behind it, and the helper adds no further actor or queue hop to completion
  delivery.
- The `.terminate` follow pre-pass is deleted; `shutdown()` (reached via
  `applicationWillTerminate`) is the single teardown owner. App exit still
  yields EOF without `end`, as SKILL.md documents.

## Invariants

- I1: Every follow stream that ends while the app is alive and its transport
  is still writable receives exactly one `end` record on its own
  subscription, regardless of other streams on the same socket or pane.
  (Pane close keeps reason `pane-closed`; internal failure uses a distinct
  failure reason.) A transport failure terminates every stream on that
  transport by EOF instead -- see accepted risks.
- I2: Retiring one subscription never disturbs a sibling: a sibling on the
  same connection or pane keeps receiving batches and later gets its own
  `end` record.
- I3: Ending a stream never closes its connection. On the wire, a
  subscription's `end` arrives after every batch already accepted for it and
  nothing more arrives for that subscription; siblings and unrelated
  requests on the same socket continue to be served.
- I4: Disposing a stream releases exactly its own resources: its recorder
  notice is disarmed and its scheduling token is retired (no census leak),
  and nothing of a sibling's.
- I5: All follow state is keyed by subscription id; no connection-keyed
  container exists.

## Proof obligations

- PO1 (I2, I5): pure support tests -- with two streams on one connection,
  retiring one leaves the sibling claiming fetches at its own cursor.
- PO2 (I1): pure support tests -- pane close returns every ended stream's
  terminator, one per affected subscription, and streams on other panes are
  untouched.
- PO3 (I4): pure support tests -- connection close and remove-all report
  every affected subscription so the runtime can dispose each one's
  resources; unaffected subscriptions remain claimable.
- PO4 (I3): socketpair tests against the relocated production write helper
  (pattern: `lib/DanTermSupport/Tests/DanTermSupportTests/IpcConnectionWriteTests.swift`) --
  a batch enqueued immediately before a terminator for the same subscription
  arrives before it, the socket stays writable after the `end`, and a
  further write on the connection still reaches the peer.
- PO5 (I1): the SKILL.md follow contract gains the failure reason and stays
  accurate about pane close and app exit.

Existing coverage kept: the cursor/in-flight tests in
`PaneTapeFollowTests.swift` are untouched; the fan-out test reshapes to the
new return shapes. TDD per house rules: each pure test lands red first.

No AppRuntime-level harness: there is no construction seam, and after this
change the runtime's follow role is mechanical disposal and terminator
routing through one helper (audit's recommended split). What that leaves
unautomated is recorded under accepted risks.

## Non-goals

- The tape broker itself (ring buffers, sequence numbers,
  `pane.tape.resume`) -- separate 8.3 work this refactor prepares for.
- Deduplicating `tearDownSession` vs `tearDownCurrentSession` (separate
  audit item); both keep calling the same follow teardown entry point.
- An injection seam for constructing `AppRuntime` in tests (audit tracks it
  under T2).

## Rejected ideas

- Generic single container (support struct owns an opaque resources
  payload): fuses subscriber state with transport resources, which the
  broker must split for resume, and the payload adds a generic parameter
  plus test freight without making any decision more testable.
- Refcounting or last-one-out checks on the existing connection-keyed map
  (audit's cheaper fallback): keeps four hand-synced containers and the
  keying mismatch that caused the bug.

## Accepted risks

- A pure subscription without a matching resources entry remains
  representable across the two containers. Confined structurally: one
  install site writes both together, and every removal funnels through one
  disposal helper; a lookup miss is programmer error, not a silent drop.
- Delivery-write failure still retires the stream without an `end` record:
  the transport already closed the socket itself, and siblings are swept by
  the connection-close path. This is the EOF case SKILL.md documents, and
  the case I1 excludes.
- The runtime's own follow behavior has no automated coverage: resource
  lookup, sibling disposal, token cancellation, notice cancellation, and the
  routing of internal failures (batch prepare, encode, notice registration)
  into the failure `end` path. PO1-PO4 pin the pure subscription decisions
  and the connection write ordering those calls rely on, but not the runtime
  wiring itself, and PO5 only updates documentation. Building the harness
  needs the `AppRuntime` construction seam this plan de-scopes (audit T2);
  the live check in Verification is the compensating control for the
  reported defect.

## Implementation discretion

- Naming and placement of the runtime resources value and disposal helper
  (avoid `PaneTapeFollowStream` -- taken by `cli/PaneTapeFollowStream.swift`
  in the CLI target), including whether the follow cluster moves to a
  cross-file `AppRuntime+PaneTapeFollow.swift` extension.
- Exact return shapes of the reshaped pure API (terminator records, id
  arrays) and the failure reason string.

## Critical files

- `lib/DanTermSupport/Sources/DanTermSupport/PaneTapeFollow.swift` -- pure
  state machine's removal ops report which subscriptions ended and what to
  dispose.
- `app/AppRuntime.swift` -- three sidecar maps collapse to one
  subscription-keyed resources map; teardown sites fold over it;
  `.terminate` follow pre-pass deleted; follow write helpers move out.
- `lib/DanTermSupport/Tests/DanTermSupportTests/PaneTapeFollowTests.swift`,
  `.../IpcConnectionWriteTests.swift` (pattern source for PO4).
- `integrations/danterm/SKILL.md` -- follow contract update (PO5).

## Verification

1. `swift test --package-path lib/DanTermSupport` -- new pure and
   socketpair tests (PO1-PO4) plus existing suite.
2. `just test` -- full local gate.
3. Live check via `just launch-slot`, covering the runtime disposal path:
   open two follows on one socket against different panes, close one pane,
   and confirm the retired stream gets its `end` record while the sibling
   keeps delivering batches on the still-open socket; then close the second
   pane and confirm its `end` record. Single
   `danterm pane tape --pane <id> --follow` still terminates exactly as
   today on pane close.

## Implementation notes

- The runtime resources value is `PaneTapeFollowTransport`, a file-private
  `@MainActor` struct in `app/AppRuntime.swift`, held in
  `paneTapeFollowTransports`. The follow cluster stayed in `AppRuntime.swift`
  rather than moving to a cross-file extension: stored properties must live in
  the main declaration, so the split would have forced the map to internal and
  reopened the containment that the one-disposal-helper rule depends on.
- The pure removal ops split by what the socket is still owed rather than by
  caller: `end(_:reason:)` returns the terminator, `remove(_:)` reports only
  whether a stream was dropped. `PaneTapeFollowRemoval` is deleted, and
  `PaneTapeFollowEnd` drops its `connectionId`, because the runtime now finds
  every transport under the subscription id.
- Each stream's shutdown census token keeps `connection.close()` as its cancel
  closure, so app teardown still yields the documented EOF. Every teardown
  short of shutdown retires the token with `run` instead, which is what makes
  ending a stream leave its socket open.
- The relocated write helper enqueues on the caller's thread instead of hopping
  through the global concurrent queue. `IpcConnection.writeNotification` already
  puts the line on that connection's serial write queue, so the hop bought
  nothing but the reordering this plan set out to remove.
- `PaneTapeFollowFetch` also loses its `connectionId`. Once a fetch resolves its
  transport under the subscription id, that field is the same coarse coordinate
  the change exists to remove, and leaving it would invite a future fetch path
  to route by connection again.
- The failure reason string is `stream-failed`.
- Drive-by, outside the plan's scope: the existing
  `closedPathCompletionIsAsynchronousAndOnMain` test raced its own
  `order.record(.returned)` against the main-queue delivery it asserts about, so
  it could see the completion first. It never ran on the main actor, unlike every
  production caller of these completions. The new socketpair test shares its
  suite and made the race reproducible -- it failed twice here -- so the test now
  runs `@MainActor`, which both matches its callers and makes the ordering
  decidable. Eight consecutive suite runs are clean.
