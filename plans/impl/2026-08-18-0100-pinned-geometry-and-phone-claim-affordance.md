# Pinned geometry on the stream, and an honest phone claim control

Follow-up to the shipped pane grid override plan
(plans/impl/2026-08-17-1836-pane-grid-override.md) and D6 stage 2
(docs/research/35-ios-remote-client/decisions.md).

## Problem

After a successful claim, the phone's Claim button does not change: it never
becomes a release, so the phone has no exit from a durable override -- only
the Mac take-back has one. The capsule also floats over terminal cells,
covering output whether or not anything is claimed, and it stays tappable
while disconnected, when a tap sends nothing and reports nothing.

One cause: the button is static configuration, not a projection of any state
-- and the state it would need does not exist on the phone. The override
reaches `pane.info` and `ls`, but nothing in `ios/` reads it, and no live
channel carries its transitions. `grep -rn gridOverride ios/` returns
nothing.

## Load-bearing premises

- The pane tape stream is the phone's only live per-pane channel, and the
  only channel whose ordering against the pane's grid is fenced (D5). Every
  geometry-bearing wire shape already states columns and rows: the start
  record's initial geometry, the sync payload, and the resize event.
- Geometry events are minted inside the recorder's fenced sequence in the
  PTY host path, from grids the app submits; the app already flows the
  override to the session view on the per-pane reconcile channel. So the
  fact "this grid is an override" is present at the exact point where the
  stream's geometry event is produced.
- D10 checkpoints persist replica geometry beside the state bytes and
  validate version and integrity before use; a failed checkpoint is
  discarded and the phone subscribes from now.
- The model knows an override exists, not who set it (shipped plan's I3);
  presentation keys off override presence, never a grid comparison (shipped
  plan's I6 -- the reasoning carries to the phone: a coincidental match
  between the replica's grid and the phone's native grid is not a claim).

## Decision

**The pane's replicated geometry becomes one two-part fact: the grid, plus
whether it is pinned.** Pinned means the grid is an override; unpinned means
it is slot-derived. This is the collapsed origin bit D6 stage 3 anticipated:
under the model-owned geometry ADR only two grid writers remain -- the slot
projection and `pane.resize` -- and the stream states which one produced the
current grid. It is derivable by every replica from the stream, stores no
ownership and no identity, and so passes D3's derivability sentence exactly
as stage 3's origin metadata was argued to.

Every geometry-bearing stream shape states pinnedness, and the replicated
fact is defined at the host's applied-geometry boundary, where recording
and apply already sit side by side: every geometry fact the authoritative
terminal applies is recorded as exactly one event, the existing resize
coalescer supersedes on the complete grid-plus-pinnedness value, and a
pinnedness change at an equal grid is an applied change -- today it
produces no event at all and would leave any observer permanently wrong.
A submission superseded before applying is observed by no one: not the
child, the terminal, the tape, or any replica.

Both compatibility boundaries move with the shape. The handshake's
protocol number bumps with the tape version: a tape shape an old peer
cannot read is exactly the incompatible behavior D9 made the protocol
number reject, so skew in either direction is refused at hello, before any
stream starts. The replica checkpoint's private format version bumps: a
checkpoint written before pinnedness fails validation and takes D10's
discard-and-subscribe-from-now path -- carried as an optional field
instead, an old checkpoint would restore as exact with a guessed
pinnedness. The shipped plan's "no new stream record kind" clause (its I5)
is deliberately superseded: shapes extend, the D5 fence semantics do not
change, and backwards compatibility is not a constraint.

**On the phone, the claim control becomes a pure projection** of four facts:
connection state, selected pane, the replica's pinnedness, and whether a
native grid is computable. Claim is offered exactly when a claim can be
sent; Release -- the fit form -- is offered exactly while the pane is
pinned. Release is the phone's one-gesture exit, symmetric with the Mac
take-back, and honest under no-ownership: it acts on presence, not tenure,
and is offered whoever pinned the pane. The control occupies its own layout
space instead of floating over cells. This lifts the shipped plan's
stage-4 non-goal on a phone-side release control, at the user's direction.

The cheap alternative, named per the design bar: keep the wire as is and
flip phone-local button state on `pane.resize` replies. One file, no
protocol change -- and it lies exactly when the Mac takes back or a third
client resizes, which is the class of bug ("the button does not say what it
can do right now") this plan exists to remove. Rejected; the trade-off is
recorded here so the choice is the user's.

Scope: the stream and checkpoint shape change with reader and replica
updates on both platforms; the phone control's projection, actions, and
placement; `integrations/danterm/SKILL.md` updated in the same change where
it documents tape record shapes; when this ships, amend the D6 stage-2
record: the geometry event now states its writer, the weaker form of stage
3's origin metadata, adopted for replica presentation rather than clobber
suppression.

## Invariants

- I1 -- The stream states the pane's geometry as one fact -- columns, rows,
  pinned -- in the start record, the sync payload, and every geometry event.
  The fact is recorded at the applied boundary: each geometry fact the
  authoritative terminal applies produces exactly one event, grid and
  pinnedness apply atomically with no observable intermediate state, a
  pinnedness-only change at an equal grid is an applied change, and a
  submission superseded before applying is observed by no one -- not the
  child, the terminal, the tape, or any replica.
- I2 -- A pinnedness-only transition is invisible to the child process: no
  size change, no signal, no cell content change.
- I3 -- An exact replica holds the authoritative pinnedness at its cursor
  through every path: live events, sync repair, and checkpoint restore plus
  replay. No side channel -- request replies, the pane list, polling --
  feeds claim presentation.
- I4 -- The phone's claim control is a pure projection of connection state,
  selected pane, replica pinnedness, and native-grid computability: Claim
  exactly when a claim can be sent, Release exactly while the replica is
  exact and pinned, and nothing offered that cannot be sent. Pinnedness is
  unavailable whenever the replica is not exact -- gaps included -- so a
  stale Release is never shown. No stored UI state, no grid comparison.
- I5 -- No ownership state: the phone never states who pinned a pane, and
  Release is offered whenever pinned regardless of writer. Last writer wins,
  unchanged.
- I6 -- Claim sends the surface's native grid; Release sends only the fit
  form; no other phone gesture sends a resize (typing and scrolling never
  claim).
- I7 -- The control occupies its own layout space: no terminal cell renders
  beneath it, claimed or not.
- I8 -- Mac behavior is unchanged: take-back, remote-sized rendering, and
  `pane.info`/`ls` reporting stay as shipped, and no Mac presentation keys
  off the stream's pinned bit.
- I9 -- No stale format ever passes as exact: a peer on the other side of
  the shape change is refused at the handshake by the protocol number,
  before any stream starts, and a checkpoint written before pinnedness
  fails format validation and is discarded.

## Proof obligations

- PO1 (I1) -- Producer tests: set at a different grid, set at the current
  grid, clear to an equal grid, clear to a different one -- each emits
  exactly one geometry event with the right pinnedness; a rapid
  different-grid set followed by a clear leaves the child, the
  authoritative terminal, the tape, and a replica agreeing on one applied
  sequence; the start record and the sync payload state it.
- PO2 (I2) -- Host-level test: a pinnedness-only transition changes no PTY
  size and no cell content.
- PO3 (I3, I9) -- Replica tests: pinnedness tracks through event
  application, sync replacement, and a checkpoint round-trip of a pinned
  pane; a stale checkpoint heals through replayed transitions or
  gap-plus-sync; a pre-pinnedness checkpoint is rejected and discarded
  before any replica restoration.
- PO4 (I4, I5, I6) -- Kit-level projection truth table: disconnected,
  awaiting synchronization, connected unpinned, connected pinned, declared
  gap, detected gap, no whole cell; the claim request carries the native
  grid and the release request carries the fit form.
- PO5 (I7) -- On-device or simulator acceptance: with a claimed pane and an
  unclaimed pane, no terminal cell sits under the control. (There is no
  headless iOS UI harness; the projection half is PO4's.)
- PO6 (I1) -- End-to-end against a live slot: `danterm pane resize` at the
  pane's current grid flips pinnedness on a following tape with no grid
  change, and `--fit` flips it back; reader tests pin the bumped stream
  version.
- PO7 (I8) -- The shipped plan's Mac suites stay green.
- PO8 (I9) -- Handshake tests: the client refuses a hello carrying the
  previous protocol number before any stream starts, and the served number
  moved with the tape shape.

## Non-goals

- Showing who claimed, or any tenure or arbitration change.
- Live pane-list replication (title, focus, and membership staleness are a
  different problem; nothing here precludes solving it later).
- Auto re-claim on rotation or keyboard changes, typing-claims, hybrid
  reflow (D6 stage-4 polish, unchanged).
- Any change to `pane.resize` itself: wire form, validation, and CLI stay
  as shipped.

## Accepted risks

- AR1 -- The protocol and checkpoint version bumps orphan un-upgraded
  peers and stored checkpoints: an old peer is refused at hello, and a
  pre-pinnedness checkpoint is discarded at the cost of a from-now
  resubscribe. One user, who upgrades both ends by replacing the apps.
- AR2 -- Whenever the replica is not exact -- before the first start or
  sync record, and during gap repair -- pinnedness is unknown and Release
  is withheld, so it can appear one round trip late.
- AR3 -- Claim stays offered while pinned, so re-claiming after rotation is
  one tap; tapping it at the already-pinned grid resends an idempotent
  resize.
- AR4 -- A phone Release drops a claim another client deliberately set;
  last-writer-wins by design (D6), one user on both ends.

## Rejected ideas

- RI1 -- Derive "claimed" from replica grid == native grid. A coincidental
  match is not a claim, and unrelated resizes would flicker the control;
  the shipped plan's I6 reasoning, carried to the phone.
- RI2 -- Phone-local claim state flipped on request replies. Goes stale on
  Mac take-back or any third-client resize -- the same "button lies" class
  this plan removes.
- RI3 -- Polling `pane.info`. Unordered against the stream, so a poll
  interleaving with a geometry event shows contradictory states; adds a
  timer the design does not need.
- RI4 -- A model-events side channel (a live `ls` subscription) as the
  carrier. Solves a larger, different problem, is unordered against the
  pane stream for the one fact that must agree with the grid, and can layer
  later without conflict.
- RI5 -- A separate policy record kind beside the geometry event. A set
  would then be two records with an observable intermediate state,
  violating I1's atomicity.

## Implementation discretion

- Where the control lives on screen and its concrete form (one composite
  control or two), within I4 and I7.
- The pinned bit's field naming and encoding, and which layer of the
  recorder plumbing carries it into the event, within I1 and I2.

## Commit progress

- [x] 1. The pane tape states whether a pane's grid is pinned
- [x] 2. The phone's replica holds pinnedness through events, sync, and checkpoints
- [ ] 3. The phone's claim control projects pinnedness and takes its own layout space

## Implementation notes

- Pinnedness is carried as a second field beside the grid at each layer's own
  geometry type rather than added to the engine's `TerminalDimensions`, which is
  what the PTY is told and what launch policy resolves: `PaneGridSubmission`
  (submission through the applied boundary), `NeutralTerminalGeometry` (recorded
  and streamed geometry), and `PaneTapeDimensions` (the wire shape). The engine's
  replay geometry type, `NeutralTerminalDimensions`, stays grid-only because
  replay has no use for the bit.
- The neutral recording event decodes `pinned` as optional, defaulting to false,
  so the stored fixture corpus recorded before pinnedness still decodes; it is
  always written on encode. Wire skew is refused at the handshake by the protocol
  number, so no peer reaches that decode with a stale shape. The alternative --
  requiring the key -- would have meant rewriting every fixture carrying a resize,
  which is outside this plan's scope and changes no behavior.
- The handshake number moved from two independent literals to one shared
  constant, `danTermIpcProtocolVersion` in `DanTermProtocol`. The server wrote its
  number as a literal at the write site, so bumping the client alone would have
  locked every peer out with no test failing.
- A pane's birth pinnedness is derived from whether its launch request named a
  grid (`TerminalPaneLaunchRequest.initialDimensions != nil`) rather than stored
  separately, because only a restored override supplies one. A second stored field
  could disagree with the geometry it describes.
- The replica takes pinnedness from a sync payload, a resize event, and a checkpoint, but
  not from a start record. A start states the producer's current geometry, while a resumed
  replica sits at its own cursor and the events between the two are still to be replayed;
  adopting the start's bit would report a transition the replica has not reached yet. The
  events that follow carry it instead.
- An event's pinnedness lands only where the event's own cursor advance lands, so a record
  the replica rejects leaves the held bit alone. Otherwise a malformed event could unpin a
  pane in the replica while the terminal and cursor stayed at the previous position.
- `PaneReplica.pinned` is computed from the state rather than cleared on a gap: the last
  exact fence must survive for `checkpoint(for:)`, which is defined to capture that fence
  even while the replica is frozen behind a gap.
