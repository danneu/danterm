# A followed pane pays no synchronous fence and no terminal copy

## Context

Every pane records its drive sequence into an always-on bounded flight
recorder on the PTY owner queue (`TerminalPTYHost.swift#finishOutputTurn`,
`TerminalFlightRecorder.swift#production`: 8 MiB / 32,768 events). A
`pane.tape --follow` subscriber reads that ring over the control socket
(`app/PaneTapeBroker.swift`). The plan for a remote (iOS, Mac-to-Mac)
frontend (`docs/scratch/2026-08-12-ios-app.md`) makes this stream the
primary way a second client observes a pane, so its cost to the observed
pane is the cost of remote observation.

Today an observer taxes the local pane, and the code that serves it is split
in a way that makes the tax structural:

1. **One subscription, two owners.** A follow stream's position is held
   twice. The main actor holds cursor, in-flight, and pending flags
   (`DanTermCore/PaneTapeFollow.swift#PaneTapeFollowSubscriptions`); the
   recorder holds `isOutstanding` per subscriber
   (`TerminalFlightRecorder.swift#FollowNotice`). Every batch reconciles the
   halves: owner append -> notify -> hop to main -> claim fetch -> `queue.sync`
   back onto the owner to take the suffix and clear the notice in one turn
   (`#followCursorSnapshot`) -> global queue -> hop to main -> advance cursor
   -> write -> completion hops to main -> release. The synchronous hop exists
   only because the owner does not know where the subscriber is.
2. **The fence fires at owner-turn rate.** The render fence is throttled to
   the display refresh interval (`TerminalPaneSession.swift`,
   `earliestNextFenceNanoseconds`). The follow fence
   (`SwiftTerminalSessionView.swift#paneTapeFollowBatch`) is not: it is taken
   on the main actor as soon as the owner appends, so a burst of PTY output
   stalls the main actor once per owner turn for as long as a follower is
   attached.
3. **Every follow fence copies the live `Terminal`** into a state pairing
   (`TerminalPTYHost.swift#followedStatePairing`) and the batch holds that
   copy off-queue until it resolves, even when it ships raw events. The
   render path already holds one copy between frames
   (`TerminalPaneSession.swift#consume`, `cachedTerminal`), so the owner
   already pays one copy-on-write break per frame; a follower adds one more
   per batch, at owner-turn rate rather than frame rate.
4. **Every opening maps the whole ring**, regardless of start mode:
   `#fencedFlightRecordingStream` calls `cursorSnapshot(from: .beginning)`
   even for a cursor resume or `--now`. A reconnecting remote client, which
   resumes from a cursor, pays a full 32,768-slot map under the fence on
   every attach.
5. **No cap on followers per pane.** Nothing refuses the N-th follower, so
   any per-turn bound on observer work is only as good as the client count.

Load-bearing premises, with evidence:

- The recorder's append edge already runs on the owner queue and is already
  edge-triggered per subscriber (`TerminalFlightRecorder.swift#append`,
  `#addFollowNotice`). Taking the suffix inside that same owner turn adds no
  new hop.
- Stream policy is pure and decides events-vs-synchronize from the cursor
  facts and the mapped suffix (dropped count, and a scan for events that
  need complete history); only the materialize phase needs terminal state
  (`PaneTapeStreamState.swift#decidePaneTapeContinuation`).
- JSON encoding is already off the main actor and runs on the connection's
  serial write queue (`IpcConnection.swift#writeLine`). That queue is
  already the background queue a push from the owner needs. Its completions
  are delivered on the main queue (`IpcConnection.swift#deliver`).
- A stalled peer is already bounded by structure on the tape path: a
  subscription has one batch in flight until its write completes, so a
  connection whose peer stops reading holds at most one batch per
  subscription in its write queue. Connections have separate write queues,
  so one stalled peer cannot delay another connection. No transport change
  is needed for I6; see RI3. The liveness bound
  (`IpcConnection.swift#run`, `IpcLivenessBound`) bounds incoming silence
  only, and local peers have none, so it does not reclaim a peer that keeps
  sending but never reads.
- The recorder is always-on regardless of subscribers; its cost is the
  accepted baseline and is not in scope.

## Decision

The recorder is the single owner of follow-subscription state. The observer
path is a push from the owner's append edge, and it never sees `Terminal`
unless it has already decided to ship a synchronization.

- **D1 One owner.** A follow subscription -- cursor, `replicaHistoryIsComplete`,
  readiness (`ready` / `inFlight`), and a decision hook -- lives in the
  recorder on the owner queue. The broker owns only transport lifetime:
  subscription id -> connection and shutdown token. `PaneTapeFollowSubscriptions`
  is deleted. `paneTapeOpening` and `paneTapeFollowBatch` collapse into one
  path: opening is `addFollowSubscription(at: cursor)`, which returns the
  opening prefix (`start` facts and backlog) and registers the subscription
  `inFlight`. The broker writes `start` and the backlog; only when that whole
  prefix has flushed does it arm the subscription with `markReady`, carrying
  the materialized prefix's resulting `replicaHistoryIsComplete`. If the
  prefix fails to flush, the broker removes the subscription. A live record
  therefore cannot precede `start`, and a failed opening leaves nothing
  registered. The broker enqueues `start` and the opening payload on the
  connection's serial write queue; an opening sync resolves lazily there, and
  the prefix completion is the only edge that can arm live delivery.
- **D2 Push at the append edge, decide before copy.** In the owner turn that
  appends, for each subscription that is `ready` and trails: take the suffix
  from its stored cursor, run the decision against that recorder-vocabulary
  snapshot (dropped counts plus the predicate scan for an event that needs
  complete history), advance the stored cursor, mark `inFlight`, and hand the
  decided batch to the subscription's `deliver` closure. A `.synchronize`
  decision takes the state pairing (terminal value, pinned geometry,
  continuation cursor) in that same turn -- an O(1) value copy -- and the
  batch carries it unresolved; a raw-events batch never takes one. Lowering
  recorder events into `PaneTapeEvent` records and serializing a sync's grid
  and history both run on the connection's serial write queue when the job
  reaches the front, never on the owner queue and never on the main actor.
  `deliver` does nothing but enqueue that job. On success, the write
  completion re-arms with
  `recorder.markReady(id, replicaHistoryIsComplete:)` posted asynchronously
  to the owner queue; the value is the delivered batch's materialized result,
  which for a sync is known only after serialization reports how much history
  fit. The recorder installs that value before it decides any trailing suffix.
  No synchronous fence exists on the batch path. Whether the completion
  reaches the owner queue directly from the write queue or via the main queue
  is implementation discretion; I1 is the invariant, and a synchronous hop
  is the thing forbidden.
- **D3 Policy stays above the recorder.** `TerminalPTY` must not import
  `DanTermCore`, so the recorder stores a `@Sendable` decision closure the
  broker builds from `PaneTapeSyncPolicy` and `decidePaneTapeContinuation`.
  The recorder owns the state machine; the caller owns the policy.
- **D4 Open with the minimum capture the decision needs.** The opening
  fence classifies the start mode and places the requested cursor first
  (cursor arithmetic), then maps only what that outcome consumes, and
  applies policy to what it mapped: `.beginning` maps the backlog; a placed
  cursor maps its suffix, and policy then reads that suffix (dropped count,
  resize scan); `--now` maps nothing; an unplaceable cursor under raw
  policy maps the retained ring (today's total gap plus every retained
  event); an unplaceable cursor under reconstructible policy maps nothing
  and takes synchronization inputs. Every `start` record and opening
  payload is what it is today for that start mode and policy (`SKILL.md`,
  "Geometry is one fact on this stream"). Whole-backlog delivery is
  unchanged.
- **D5 Follower cap.** Each pane admits at most a fixed number of follow
  subscriptions. A follow request over the cap fails with a JSON-RPC error
  as the reply to `pane.tape` and writes no `start`; existing followers are
  unaffected. The cap is documented in `SKILL.md`.
- **Scope.** `pane.tape` (finite dump and follow), `PaneTapeBroker`, and
  `TerminalFlightRecorder`'s subscription interface. `IpcConnection` gains
  one generic lazy write job: a `@Sendable` builder the write queue invokes
  to produce the value it then encodes and a generic acknowledgement returned
  only after a successful flush, so a sync resolves on that queue in batch
  order and reports its resulting history standing. The benchmark harness gains
  a paired observer-tax topology over the existing `scrollback-stream` corpus.
  `DanTermSupport` stays free of terminal types. The CLI and every JSON Lines
  record shape are unchanged; the over-cap error is new.

## Invariants

- **I1 (no main-actor fence on follow).** After a stream is open, no follow
  batch performs a synchronous main-to-owner fence.
- **I2 (no idle terminal copy).** A follow batch that ships raw events never
  takes a state pairing and retains no `Terminal` value. A sync batch takes
  exactly one.
- **I3 (bounded owner work per turn).** The owner-queue work observers add
  to any single append turn is at most one suffix take and one
  recorder-vocabulary predicate decision per ready subscriber, plus an O(1)
  pairing copy when a synchronization is decided; with D5 that is a fixed
  bound per pane. No event lowering or serialization runs on the owner queue.
- **I4 (one owner).** No follow-subscription position exists outside the
  owner queue. The broker cannot name a cursor.
- **I5 (cursor order).** Every event a stream delivers has a sequence at or
  after the cursor its `start` record published; geometry changes after that
  cursor arrive only as events or syncs. Every stream's first record is
  `start`, and no live record precedes the opening prefix.
- **I6 (isolation across connections).** A connection whose peer stops
  reading cannot delay delivery on any other connection, and holds at most
  one undelivered batch per subscription plus that subscription's `end`.
- **I7 (edge-triggered push).** A burst of PTY output yields at most one
  batch per subscriber while that subscriber is `inFlight`; the next push
  waits for a successful `markReady`, which installs the delivered batch's
  resulting `replicaHistoryIsComplete` before the next decision.
- **I8 (atomic sync).** When a batch ships a synchronization, its state
  bytes, geometry, focus, and continuation cursor come from one owner turn.

## Proof obligations

- **PO1 (I1, I7):** count owner-queue fences and pushes while a followed
  pane ingests a multi-chunk burst; follow adds zero fences and at most one
  push per `markReady`.
- **PO2 (I2):** with a counting pairing source installed on the recorder,
  drive a burst that decides raw events on every batch; the pairing count is
  zero and the batch count is nonzero. Drive one that decides
  `.synchronize`; the pairing count equals the sync count. Counting the
  pairing, not the serializer, is what catches a raw batch that captures
  `Terminal` without serializing it.
- **PO3 (I3, I5, D4):** open streams in each start mode on a pane whose ring
  is at both caps and whose retained history contains a resize; a placed
  cursor resume and a `--now` opening map no slot before the requested
  cursor; an unplaceable cursor under raw policy still yields the total gap
  and every retained event, and under reconstructible policy a
  synchronization with the total gap; each `start` record states the same
  cursor and geometry facts it does today (the existing
  `PaneTapeStreamStateTests` opening cases, including the unplaceable ones,
  pass unchanged); no delivered event precedes the published cursor.
- **PO4 (I4, I5, lifecycle):** the recorder's subscription state machine is
  tested standalone in `TerminalPTY` by feeding appends and `markReady`
  calls and asserting the `deliver` sequence, with no dispatch queue
  involved. Every observable lifecycle scenario the deleted
  `PaneTapeFollowTests` cover moves to a recorder or broker boundary test:
  output injected between `start` and the end of the opening prefix arrives
  after the prefix (`start`, opening records, then live records); a failed
  opening flush leaves no subscription; pane close writes exactly one
  `end(paneClosed)` per stream and leaves siblings on other panes intact;
  connection close retires that connection's streams and no others; a failed
  batch write drops the stream with no `end`; shutdown removes every stream.
  A gap that materializes a history-truncated sync updates the recorder's
  history standing, so a later resize selects another sync instead of raw
  events.
- **PO5 (I6, D5):** with the peer of one connection not reading and the pane
  bursting, that connection's write queue holds one batch per subscription
  and no more; a subscriber on a second connection to the same pane keeps
  delivering. The cap-plus-one follow request receives the JSON-RPC error
  and no `start`, and every existing follower keeps delivering.
- **PO6 (I3, I5, I8):** adapt the connection's existing queue-context and
  write-order probes for the lazy path: its builder runs on that connection's
  serial write queue, not inline, on the owner queue, or on the main actor;
  raw-event lowering and sync serialization both happen there, and the result
  reaches the wire between eager writes enqueued before and after it. A resize
  landing between the owner turn that takes a pairing and the lazy job that
  serializes it cannot produce a sync whose bytes, geometry, and cursor
  disagree.
- **PO7 (existing behavior):** the finite dump (`pane.tape` without
  `--follow`) yields the same decoded record sequence and fields as today;
  the CLI tests pass with only wiring updates.
- **PO8 (observer tax, paired and measured):** land the benchmark topology and
  its counters before the optimization, then compare that revision with the
  completed candidate using identical instrumentation. Each fresh app and pane
  runs the committed `scrollback-stream` corpus with 0, 1,
  `max(1, cap / 2)`, and cap followers (equal follower counts deduplicated).
  A followed arm opens `pane.tape --follow --raw --now`, waits for `start` to
  flush before admitting the corpus, drains continuously, and does not finish
  until both the final draw and the follower's final event have arrived. The
  schedule position-balances revisions and follower counts. For each revision,
  report observer tax (followed minus unfollowed) for observed-pane PTY drain
  time/rate and end-to-end block time, plus follower completion time,
  per-subscriber owner-queue nanoseconds per append turn and sample count, and
  follow-fence, push, synchronization, and state-pairing counts. Compare the
  baseline and candidate observer taxes; reject a block whose byte total,
  terminal event, follower completion, or follower count differs between its
  arms. A zero with zero samples is absent, not zero, and an injected fixed
  per-subscriber delay moves the owner-cost result
  (`agent-docs/measurement-discipline.md`). This is descriptive evidence until
  the topology has its own A/A calibration: it cannot borrow
  `scrollback-stream`'s frozen verdict or threshold. PO1 and PO2 remain the
  decision-bearing structural proofs for zero follow fences and zero raw-event
  pairings.

## Non-goals

- Making the recorder opt-in or subscriber-gated; its baseline cost stays.
- Network transport, resume across reconnect, or the observe/claim geometry
  question from the iOS brainstorm. D1 is the home a resume command will
  land in (`addFollowSubscription(at: cursor)`), but the command is not in
  scope.
- Reducing base64 or JSON encoding cost.
- Chunked ring storage (see RI5).
- Bounding a stalled connection's non-tape notifications. They can
  accumulate until the connection is torn down; that is transport behavior
  that predates this plan and is not observer cost.

## Accepted risks

- **AR1.** D2 moves decision execution onto the PTY owner queue. The decision
  is cursor math plus a predicate scan over the recorder snapshot already
  mapped; lowering each event into a stream record stays on the write queue.
  I3 bounds the owner work per turn, so ingest latency grows by a bounded
  constant per subscriber.
- **AR2.** A stalled connection holds up to one batch per subscription (a
  batch is bounded by the ring, 8 MiB, or one sync) until the connection is
  torn down -- by the peer, by the silence bound if the peer also stops
  sending, or by app shutdown. The tape path's memory is bounded per
  subscription and per pane (D5), not in time. Its subscriptions also keep
  their follower-cap slots for that whole interval, so one local client that
  opens the cap and stops reading prevents later follows on that pane until
  the client exits or the app shuts down. A time bound is a transport decision
  outside this plan.
- **AR3.** The observer path still costs the owner queue bounded work per
  subscriber per append turn (suffix take plus decision). PO8 measures it.
- **AR4.** A fresh `.beginning` opening still maps the whole retained ring
  under one owner fence (a few MB of struct copies, once per attach). Cursor
  resumes, which is what a reconnecting remote does, no longer pay it (D4).
  If the remaining attach stall matters, RI5 is the fix.
- **AR5.** The write completion may reach the owner queue through an
  asynchronous main-queue hop if the implementation keeps `IpcConnection`'s
  `@MainActor` completions. That is an enqueue, not a fence; I1 holds.
- **AR6.** A stalled connection retains one unresolved `Terminal` pairing
  per in-flight sync until its write job runs; I7 and D5 bound that to one
  per subscription and cap per pane. The owner pays one copy-on-write break
  on its next mutation for that pairing, and no further breaks on account of
  the same pairing.
- **AR7.** Resolving a followed synchronization blocks later writes on the same
  connection, including other streams and JSON-RPC replies, while the serial
  write queue walks the grid and retained history. Only one sync resolves on a
  connection at a time, and the follow policy's `historyBudgetBytes` bounds
  the serialized history; preserving socket order requires this serialization.

## Rejected ideas

- **RI1 Keep the main-actor fence, shrink its body.** Removes the terminal
  copy but not the owner-queue serialization behind the fence, so the render
  path still queues behind observers.
- **RI2 A separate remote-observation path for iOS.** Duplicates the stream
  and forks its invariants; the bridge inherits this path unchanged.
- **RI3 A per-connection undelivered-byte bound in `IpcConnection`.**
  The writer captures unencoded values, so a byte counter cannot see a job's
  size until the serial queue encodes it; enforcing a bound would need
  admission accounting with a conservative pre-encode charge. Not needed:
  I7's one-batch-in-flight already bounds the tape path per subscription,
  and D5 bounds subscriptions per pane. A drop-on-full socket is
  rejected for the same reason as before: it drops records inside a
  JSON-RPC stream other methods share and can leave a partial line.
- **RI4 Keep the main-actor subscription state and add an owner-side push.**
  Leaves two owners for one cursor and replaces the synchronous fence with a
  cross-queue reconciliation protocol. Deleting the second owner is smaller
  and removes the class of bug.
- **RI5 Chunked ring storage.** Make the ring a deque of sealed immutable
  chunks so a whole-backlog snapshot is O(chunks) references and eviction is
  per chunk. This is the ideal fix for AR4 and would make the ring itself the
  shared publication remote readers consume. Deferred, not rejected: D4
  removes the common case (cursor resume), and the remaining cost is one
  bounded stall per fresh attach. Revisit if PO8 or a real attach workload
  shows it.
- **RI6 Chunked backlog delivery.** Deliver a `.beginning` backlog in bounded
  chunks through the live path. Bounds per-turn owner work but exposes the
  reader to eviction between chunks, changes what a reader can observe on
  attach, and needs eviction-injection tests. RI5 gets the same bound
  without the semantic change.
- **RI7 Rewrite `close()` to not drain.** The drain is deliberate: a peer
  that leaves of its own accord is owed its last reply. `forceClose()`
  already covers the stalled case.

## Implementation discretion

- The cap value for D5.
- Whether the write completion posts `markReady` to the owner queue directly
  from the write queue or via the main queue (AR5).
- The shape of the lazy write-job API on `IpcConnection`, as long as the
  builder runs on the write queue in enqueue order and returns its generic
  acknowledgement only after a successful flush.

## Commit progress

- [x] 1. perf(pane-tape): add the paired observer-tax benchmark
- [x] 2. refactor(ipc): add ordered lazy write jobs
- [x] 3. refactor(pane-tape): move follow ownership to the recorder and cap followers
- [ ] 4. perf(pane-tape): open streams with the minimum required capture

## Implementation notes

- The follower cap is 8. The benchmark fixes its topology at 0, 1, 4, and 8
  followers, and commit 3 must enforce the same cap.
