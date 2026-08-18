# Serialize pane state only for syncs that ship

## Problem

`PaneTapeSyncPolicy.historyBudgetBytes`
(lib/DanTermProtocol/Sources/DanTermProtocol/PaneTapeRequest.swift) collapses
two unrelated facts into one `Int?`: `.reconstructible(nil)` means "a sync
carries every retained row" and `.raw` means "this stream never emits a sync".
Every fence caller passes that projection down, and the fence resolves a state
synchronization unconditionally. Three costs follow:

- A raw `pane.tape` stream serializes the pane's whole retained scrollback --
  up to a 19.4 MB payload at the 16 MiB cap (research/35/F13) -- at open, and
  again on every follow rearm, and the bytes are discarded: the continuation
  builder reads the synchronization only under a reconstructible policy.
- A reconstructible follow stream eagerly encodes a budget-sized sync per
  rearm and discards it whenever the batch is served from retained events,
  which is the steady state.
- The encode runs on the thread that takes the fence, and the session view
  takes it on the main actor. Only the pane-owner queue is protected today;
  that is the sole job of the deferred-serialization pairing.

Load-bearing premises:

- Whether an opening or continuation emits a sync is decidable from the cheap
  fence facts alone: start position, cursor placement, dropped-event counts,
  the `needsCompleteHistory` event flag, and the replica's history standing.
  Today's selection logic consults only those facts before touching the sync.
- Deferred serialization still states the fenced moment: the pairing
  fence-copies the terminal by value, so encoding later encodes the same
  state. This is the existing contract of the pairing type in
  lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift.
- A raw `now`-opening needs live geometry and the live cursor. It reads them
  off the resolved sync today, but both are available at the fence without
  serializing anything.
- One decide-relevant fact is an encode output, not a fence fact: on a sync
  branch the replica's history standing is `droppedHistoryRows == 0`, and the
  next fetch's decision consumes that standing. So the materialized result
  carries it forward into the follow state; the payload decision cannot,
  because at decide time it is not yet known.

## Decision

Serialization happens only downstream of the decision to emit a sync record.

- Delete the `historyBudgetBytes` projection. The policy travels whole to the
  one site that chooses events or a sync, and the encoder receives a budget
  only from the `.reconstructible` case. Below the request boundary, "a raw
  stream's history budget" has no spelling.
- Four phases own four things, and each boundary crosses as values:
  - **Capture** (`lib/TerminalPTY`). The fence takes no budget and serializes
    nothing. It returns the cheap fenced facts -- including live geometry and
    cursor -- plus an opaque handle on the fenced state. It learns nothing
    about raw versus reconstructible policy or history budgets.
  - **Decide** (`lib/DanTermSupport`). Stream policy reads only the cheap
    facts and returns a payload decision: use these events, or replace them
    with a synchronization requirement. A budget exists only inside the
    requirement. The support layer keeps holding values only -- no engine
    types, no closures, no deferred-work objects -- so lowering stays what
    the app's `paneTapeStreamFence` already does.
  - **Materialize** (`app/`). The app renders the decision off the main actor,
    in the existing record-building step, and resolves the fenced-state handle
    only for a synchronization requirement -- never on the main actor and
    never on the pane-owner queue.
  - **Deliver** (`AppRuntime`). Unchanged: lifecycle, subscription
    coordination, and transport.
- Openings and continuations share one payload-decision type, so neither
  fence entry point can grow its own answer to "events or a sync". Their
  surrounding metadata stays different.
- This makes I1 and I2 structural rather than conventional: a raw path and an
  event-served reconstructible path each hold a decision with no
  synchronization requirement in it, so there is nothing to serialize and no
  budget to carry.
- Wire behavior is identical; neither `paneTapeStreamVersion` nor
  `danTermIpcProtocolVersion` moves.

Critical files: the policy in
lib/DanTermProtocol/Sources/DanTermProtocol/PaneTapeRequest.swift; the fences
and the pairing in
lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift; the selection
logic in lib/DanTermSupport/Sources/DanTermSupport/PaneTapeStreamState.swift;
the lowering in app/SwiftTerminalSessionView.swift; the follow loop in
app/AppRuntime.swift.

## Invariants

- I1: No stream path serializes terminal state except to build a
  synchronization record the stream has already selected for the wire.
  Raw openings and continuations never serialize; a reconstructible
  continuation served from retained events never serializes.
- I2: The budget reaches the encoder only from the reconstructible policy
  case; `nil` there means "all history" and has no second meaning anywhere.
- I3: Delivered records are unchanged for every request shape -- raw dump and
  follow at each start position, reconstructible openings, gap repair, resize
  resync, and `pane.snapshot` -- including budget observance and
  `droppedHistoryRows`.
- I4: A sync built on demand states the fence's moment: its bytes, geometry,
  cursor, and `droppedHistoryRows` describe the fenced copy, regardless of
  what the live terminal ingested between the fence and the encode.

## Proof obligations

- PO1 (I1): Each of these builds its records without invoking the
  serialization seam, observed at the seam itself: raw openings (dump from
  the beginning, follow from now, resume from a placed cursor, resume
  unplaceable), a raw follow continuation rearming through the follow fence,
  and an event-served reconstructible continuation. The raw follow stream is
  covered at both entry points: the shared decision type makes the answer
  uniform, but each entry point wires its own facts into it.
- PO2 (I3): The existing tape suite's assertions survive the new
  construction -- bounded-budget observance, dropped-row reporting, gap
  repair, resize resync, snapshot completeness, and the request-boundary
  rejections. Many of those tests build the fence types this change deletes,
  so they are rewritten in the same change and could silently weaken; two
  things guard that. The reader-side wire suite in
  lib/DanTermClient/Tests/DanTermClientTests/PaneTapeRecordReaderTests.swift
  is the anchor, because its types do not move. And every path whose record
  assembly crosses the new decide/materialize boundary -- the raw
  `now`-opening, plus the sync-emitting opening and continuation -- keeps
  asserting whole record values, not record shapes.
- PO3 (I4): Feed the source more output between the fence and the demand,
  then serialize: the sync replays to the fenced grid and history, for an
  opening and for a follow rearm.
- I2 is discharged by construction: once the projection is deleted, no API
  below the request boundary accepts or stores a budget outside the
  reconstructible case, and the build enforces it.

## Non-goals

- Lazy history paging (research 35, T22's open half).
- Changing when a sync is emitted, the default budget, or any wire shape.
- Specialising `replicaHistoryIsComplete` away from dump and snapshot
  captures (already adjudicated: one selection rule for all three).

## Accepted risks

- AR1: The fence result holds a copy-on-write reference to the fenced
  terminal until its records are built, instead of releasing it at the fence.
  The window is the same one that held the eagerly encoded bytes before, one
  prepare step per stream at a time, and the raw path -- previously the worst
  payer -- now holds no encoded bytes at all.

## Rejected ideas

- RI1: Pass a zero budget for raw streams. Still encodes a grid-sized sync
  nobody reads, still types a raw stream as having a history budget, and the
  continuation builder's discard remains what saves us.
- RI2: Keep eager resolution behind a three-case requirement (none / bounded
  / unbounded) with an optional synchronization in the fence. Fixes the raw
  waste, but the steady-state reconstructible rearm still encodes a discarded
  sync, and a reconstructible fence with an absent sync becomes
  representable, guarded by convention instead of construction.
- RI3: Decide events-versus-sync inside the engine so the fence knows whether
  to serialize. That moves replication policy into the recorder layer; the
  current split stays -- the engine flags mechanics such as
  `needsCompleteHistory`, the support layer owns the policy.

## Implementation discretion

- How the fenced-state handle and the payload decision are spelled as types,
  and the exact types crossing the engine/support boundary -- so long as the
  handle stays opaque to the decide phase and the decision stays a value.
- Whether the fence's live-geometry-and-cursor facts reuse an existing origin
  type.

## Implementation notes

- The opening decision splits by policy case rather than reading a budget
  computed once: `rawOpening` returns a `PaneTapeEventOpening` outright, so a
  raw stream has no type in which a synchronization requirement could sit, and
  `reconstructibleOpening` is the only function that binds a budget. This makes
  I1 structural for the raw path as well as I2, at the cost of stating the
  shared `.beginning` and placed-`.cursor` event branches in both.
- The raw `now`-opening reads its live geometry from the recorder's tracked
  geometry (`fromNowOrigin`), not from the terminal's own column and row
  counts. `applyResize` records the resize event and resizes the terminal in
  one owner turn, so the two agree at every fence; they could only diverge on a
  grid `Terminal.resize` rejects (`columns >= 2, rows >= 1`), which no pane grid
  submission produces. A live dev instance published the same 179x66 the
  sync-derived path did.
- `TerminalFlightRecordingStreamFence` and `TerminalFlightRecordingFollowFence`
  dropped `Equatable`: they now hold the state pairing, which holds a
  `Terminal`. Nothing compared either fence.
- `TerminalFlightRecordingStatePairing` and its `resolve` moved from `package`
  to `public`, because the materialize phase lives in `app/`, outside the
  TerminalPTY package.
