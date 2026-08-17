# A detected stream gap is a connection failure, and status is composed from its owners

## Problem and desired outcome

The phone's pane replica can enter `.gap` two ways, and only one of them can
recover. The code does not distinguish them, so one of them hangs forever.

- **A gap the producer declared** arrives as a `.gap` record. Because the
  subscription runs in reconstructible mode, the Mac emits that record and the
  replacement sync in the same continuation batch, so the replica returns to
  exact a few records later with no client action.
- **A gap the client detected** is set by the replica itself, with no `.gap`
  record involved, when what arrived disagrees with what it holds -- a start
  cursor that is not the one it resumed at, an event sequence that skipped, a
  resize with degenerate geometry, byte coordinates that cannot advance the
  cursor, a start that carries a position for a replica holding no state. In
  every one of these the Mac believes the stream is healthy and will never send
  another sync.

Nothing repairs the second kind. The pane-tape subscription is issued only when
a connection is established, and a gap does not throw, so no failure is ever
reported. The replica freezes on its last exact frame, the header says it is
waiting for exact state, and nothing is coming. The only exit is the user
tapping Go or backgrounding the app.

That is precisely the outcome the reconnect work set out to remove -- no state
the app can occupy may read as a hang -- and it survived because the freeze is
invisible to the layer that owns recovery.

The presentation carries the same defect in smaller form. Conditions that are
not connection states are written into the stored connection state and then
undone by hand: a gap borrows the connection-lost state plus a flag to reverse
it, and a refused non-tape request on a live connection sets a failure state
that nothing ever clears.

Desired outcome: every gap the client can detect ends in a bounded, automatic
remedy; a gap the producer declared costs nothing but a brief wait; and every
status the user sees states something that is true when it is shown.

Load-bearing premises, from the tree:

- Reconnect is exact. The established path flushes the replica checkpoint
  before each attempt and resumes from the stored cursor; a cursor the producer
  cannot place takes the existing explicit-gap-plus-fresh-sync repair. So
  ending a connection to reconcile a desynchronized stream costs a reconnect,
  not lost scrollback.
- That same stored cursor is what makes reconnect alone insufficient here. A
  detected gap can be *caused* by the position the stream resumed from, and the
  next attempt resumes from exactly that position again. A remedy that only
  reconnects would reproduce the disagreement on every attempt and spend the
  whole budget failing the same way.
- `MobileReconnectPolicy` is a pure, tested value that already owns retry
  classification, backoff, the episode budget, and the recovery phase shown
  beside the causal state. It needs a new cause, not a new mechanism.
- `MobileConnectionState` is deliberately the user's remedy vocabulary, free of
  policy; retry class and recovery phase are already kept out of it.
- The iOS app target has no test target. Every decision made in the shell today
  -- the borrowed state, the undo flag, the status composition, the severity
  choice -- is structurally untestable where it currently lives. The kit is
  where behavior becomes verifiable.
- `MobileConnectionModel` is defined and unit-tested in the kit but used by
  nothing in production: the shell reimplements its state half, and its cursor
  half was superseded by the checkpoint store.

## Decision

**A gap the client detected is a typed connection failure that enters the
existing reconnect policy, and the status line is composed by a pure kit
function from the separately owned facts that make it up.**

The replica already knows which kind of gap it is in -- it is the one that set
the state -- but does not say so. Making provenance part of the state is what
lets the remedy be decided at all, because provenance is exactly what
determines the remedy: a declared gap is a wait, and a detected gap is a
disagreement only a fresh subscription can reconcile.

Routing the detected gap through the connection-failure path rather than
repairing it in place is the structural choice. It means the app has exactly
one recovery mechanism, so a repair path without a budget cannot exist, and a
stream that desynchronizes repeatedly terminates at the same bounded episode as
any other repeating failure instead of looping on a private retry of its own.

For presentation, four independent facts each have an owner: the causal
connection state, the recovery phase, the replica's stream condition, and the
outcome of the most recent completed non-tape request. Composing them belongs
with them, in the kit, as a pure function over the four. Each is
level-triggered -- a current value an observation replaces -- so none needs an
expiry rule, and the shell can offer no single wide setter through which one
fact could be written into another's slot. That is what makes the borrow this
plan removes unspellable rather than merely discouraged.

Behavioral scope: the phone's replica state, its connection-failure vocabulary,
and its status line. No change to the wire gap record, to producer behavior, or
to the pane-tape protocol.

## Invariants

- **I1.** A gap the client detected ends the current connection with a typed
  cause and enters the reconnect policy. It never leaves the replica frozen
  with no pending remedy.
- **I2.** A gap the producer declared takes no recovery action. It is a
  transient wait that the sync already in the stream resolves.
- **I3.** The replica's state says whether it detected the gap or the producer
  declared it.
- **I4.** A detected gap is classified so an automatic attempt may follow it,
  and it draws on the one episode budget. There is no second recovery
  mechanism and no unbounded repair loop.
- **I4a.** After a detected gap, no attempt resumes from the position that
  caused it, and the refusal holds until the replica has regained an exact
  position. It is not spent by the first attempt that follows: an attempt that
  starts fresh and then fails before the replacement sync lands leaves the
  disputed position still stored and still the newest thing on disk, so a
  refusal that expired after one use would hand it straight back. Without this
  the retry reproduces the disagreement and the budget only bounds how many
  times it does so.
- **I4b.** Refusing that position is decided when the next attempt chooses
  where to start, from state the failure itself set. It is not achieved by
  deleting the durable checkpoint, because the saved position is written
  asynchronously from a snapshot taken before the save runs: a save already in
  flight carries the disputed cursor and would land after any delete. Deciding
  at attempt time is independent of what any writer does to the store, so the
  race has nowhere to live rather than being fenced off.
- **I5.** `MobileConnectionState` gains no case for stream condition or for
  recovery, and no case whose meaning is a retry rule. It stays the remedy
  vocabulary, free of policy. It may name the outcome "this connection ended
  because the replica and the producer disagreed", which is a cause like any
  other it already holds; what it may not hold is the live stream condition or
  what the app intends to do next.
- **I6.** The status line is composed by a pure function in the kit from four
  independently owned facts: the causal connection state, the recovery phase,
  the stream condition, and the outcome of the most recent completed non-tape
  request. Each has exactly one writer and no fact may be written through
  another's slot. The shell stores no presented state and holds no flag whose
  purpose is to undo a borrowed one.
- **I7.** Every status the user can see states a condition that holds at the
  moment it is shown. No status claims the app is waiting for something that
  cannot arrive.
- **I8.** A refused request that did not end the stream is reported as the
  outcome of the most recent completed non-tape request, and never as a
  connection state. Stating it as the latest outcome rather than as an event is
  what bounds it: the next completed non-tape request replaces it, a successful
  one clears it, and connection teardown clears it, so it cannot outlive the
  connection it describes or survive the condition it reports. It is a
  level-triggered fact like the other three, so it needs no expiry rule and no
  caller that has to remember to clear it.
- **I8a.** A refused request never makes a serving connection present as a
  failed one. It is something happening to a connection that is still working.
- **I9.** Presentation severity is derived from a total switch over the
  vocabulary, so a state added later cannot inherit failure styling by default.

## Proof obligations

One entry per invariant or load-bearing premise. Kit tests run with
`swift test --package-path ios/DanTermMobileKit`; the full gate is `just test`,
which includes the iOS portability gate.

- **PO1** (I1, I3). Each way the replica can detect a gap for itself yields a
  detected-provenance state, and a detected gap produces the typed connection
  failure. The coverage floor is every site that enters the gap state without a
  producer gap record, enumerated from the code rather than from this plan --
  any one left unclassified restores the freeze in that path. A site currently
  unreachable from an honest producer is still in the floor: unreachability is
  a property of today's producer, not of the replica, and it is exactly the
  path whose freeze nobody would notice.
- **PO2** (I2, I3). A producer-declared gap followed by its replacement sync
  returns the replica to exact and raises no connection failure.
- **PO3** (I4). A stream that desynchronizes repeatedly exhausts the episode
  budget and comes to rest with a manual remedy, rather than retrying without
  bound. A desync that follows a connection which served long enough to prove
  stable rearms the budget, so a rare incident cannot accumulate toward
  give-up.
- **PO3a** (I4a, I4b). Exhaustively over the failure vocabulary: after a
  detected gap the next attempt starts from a fresh position, and after every
  other failure it starts from the stored one. The convergence case is proved
  against a hostile store rather than a quiet one: with a checkpoint holding
  the disputed cursor still present -- as it would be when a save that was
  already in flight lands after the failure -- the attempt must still start
  fresh. A test that only removes the checkpoint and observes a fresh start
  cannot tell this invariant from its absence. The refusal is proved to
  outlive one attempt: with a failure intervening before the replica regains an
  exact position, the attempt after that one starts fresh too. A one-shot
  "start fresh next time" spelling must fail here.
- **PO4** (I5). The connection-state vocabulary holds no live stream condition
  and no retry rule: the states this plan adds are causes, and the map from a
  typed cause to a state stays total with no residual generic case.
- **PO5** (I6, I7). Composition over the four facts is exercised directly: a
  gap while the connection is live never composes to a connection-failure
  presentation, a recovery phase composes beside the causal state rather than
  replacing it, and writing any one fact leaves the other three unchanged --
  which is what makes the borrow this plan removes unspellable.
- **PO6** (I8, I8a). The refused-request outcome is visible when it happens,
  is replaced by the next completed non-tape request, is cleared by a
  successful one, and does not survive connection teardown. Its severity marks
  a serving connection as degraded, never as failed.
- **PO7** (I9). Severity is total over the vocabulary.
- **PO8** (premise). Exact resume across a reconnect is preserved for every
  failure that leaves the position trustworthy: the reconnect resumes from the
  stored cursor, or takes the existing explicit-gap-plus-fresh-sync repair when
  the producer cannot place it. The detected gap is the exception carved out by
  I4a, and PO3a is what fixes its boundary.

Beyond the suite, the end-to-end check is a live one and needs hardware: drive
a pane from the phone, force a desynchronization, and confirm the app recovers
on its own and the header never states a wait that cannot end.

## Non-goals

- No test target for the iOS app layer. Composition moves into the kit
  precisely so it can be tested where a test target already exists.
- No change to the wire gap record, the producer's gap policy, or the
  reconstructible-mode contract.
- No ticking countdown in the status line.
- No user-facing control to stop a retry episode.

## Accepted risks

- **AR1.** A detected gap now costs a full reconnect rather than a targeted
  re-subscription on the live connection. Detected gaps mean the producer and
  the client disagree about the stream and should be rare, and reconnect is
  exact, so the heavier remedy buys a single recovery mechanism whose budget
  already exists. Chosen deliberately over the cheaper repair.

## Rejected ideas

- **RI1.** Re-subscribe on the live connection instead of ending it. It is the
  surgical remedy, but it is a second recovery mechanism needing its own bound,
  and it is not available as cheaply as it looks: the shell applies stream
  notifications without checking which subscription they belong to, so records
  from the old and new subscriptions would interleave with nothing to tell them
  apart. The socket is the only fence that exists today. Fencing on the
  subscription identity first would make this a legitimate later optimization;
  it is not a smaller change now.
- **RI2.** Give `MobileConnectionState` a case for the live stream gap. It would
  put a condition of a serving connection into the enum that names why a
  connection is not serving, which is the borrow this plan removes. Naming the
  ended-by-disagreement outcome there is a different thing and is allowed by
  I5.
- **RI3.** A watchdog that promotes a declared gap to a detected one after a
  timeout. It would also cover a producer bug, but it costs a wall-clock
  threshold and a timer to catch stalls that are already covered: a truncated
  batch is a transport failure, and the reconstructible mode that couples a
  declared gap to its replacement sync is a constant. It becomes necessary only
  if the phone ever requests a different mode.
- **RI4.** Report the detected gap by throwing from record application, which
  the shell already catches. The existing catch maps to a phone-defect cause
  whose retry class is manual, so the freeze would become a red screen the user
  still has to tap through, and it would conflate "the phone got malformed
  data" with "the phone and the Mac disagree".

## Implementation discretion

- How provenance and the composed status value are spelled, and where the
  composition function sits within the kit.
- Whether the unused `MobileConnectionModel` is absorbed into the composed
  status value or deleted outright. Either resolves the duplicate; leaving it
  as it is does not.

## Commit progress
- [x] 1. Give the replica's gap state its provenance (I3; PO1, PO2)
- [x] 2. Route a detected gap through the reconnect policy from a fresh position (I1, I2, I4, I4a, I4b, I5; PO3, PO3a, PO4, PO8)
- [x] 3. Compose the phone's status line in the kit (I6, I7, I8, I8a, I9; PO5, PO6, PO7)

## Implementation notes

- Commit 1 spells provenance as a `PaneReplicaGap` enum that wraps the
  producer's `PaneTapeGapRecord.Loss` in its `declared` case, and
  `PaneReplicaState.gap` now carries it. The plan left the spelling to
  discretion; this one makes a gap unsettable without saying who found it,
  because the loss counts are reachable only through the declared case.
- The PO1 audit test repeats three detection sites that already have tests of
  their own. The repetition is deliberate: PO1 asks for the coverage floor to
  be enumerated from the code, and one test holding the complete list is what a
  reader can audit against `PaneReplica` in a single pass.
- Commit 2 puts the refusal of a disputed position in its own kit value,
  `MobileResumePolicy`, rather than inside `MobileReconnectPolicy`. The
  reconnect policy states in its own header that no resume position belongs to
  it, and the two answer different questions: when an attempt runs, and where it
  starts. The link between them is one exhaustive switch,
  `MobileConnectionFailure.preservesResumePosition`, so the failure vocabulary
  stays the single place a new cause has to be classified.
- The refusal is cleared when the replica reports exact state, which the shell
  already observes through `didChangeReplicaState`. No new observation point was
  needed, and no attempt outcome clears it, which is what makes it outlive the
  attempt that follows the gap.
- Commit 3 spells the composition as `MobileStatus`, a kit value holding the four
  facts with one setter each and a `line(at:)` that renders them. The plan left
  the spelling and placement to discretion. The stream fact is `PaneReplicaState?`
  rather than a second vocabulary of its own, so the replica's state needs no
  translation and cannot drift from it.
- Two facts -- the stream condition and the last non-tape request outcome --
  describe a connection that is serving, so composition drops them beside any
  other connection state. That, rather than a caller who remembers to clear them,
  is what stops a stale claim from appearing next to a failure.
- Severity gained a third level, `degraded`, because I8a needs a serving
  connection with something wrong on it to read as neither normal nor failed. The
  shell's only remaining presentation decision is the color for each level.
- `MobileConnectionModel` was deleted rather than absorbed. Its state half is the
  connection fact in `MobileStatus`, and its cursor half was already superseded by
  the checkpoint store, so nothing was left to move.

## Follow Up

- Run the live end-to-end check the proof obligations name: drive a pane from the
  phone against real hardware, force a desynchronization, and confirm the app
  recovers on its own and the header never states a wait that cannot end.
