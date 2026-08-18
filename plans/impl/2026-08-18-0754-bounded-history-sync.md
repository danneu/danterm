# Bounded history sync for pane.tape

## Problem

A reconstructible tape sync re-encodes everything the terminal retains:
`Terminal.stateSynchronization` walks all history rows plus the grid. At the
16 MiB scrollback cap that is a 19.4 MB wire payload per join or repair
(research/35/F13), and history is essentially all of it -- a fresh pane's sync
is 1.4 KB. The cost makes joins slow on a remote link and makes gap-repair
after an evicted ring (research/35/D5) a thrash risk under flood
(research/35/F12 and F13).

Load-bearing premises:

- `Terminal.stateSynchronization` has two consumers: the tape stream path
  (`pane.tape` and `pane.snapshot`, which share the stream command) and the
  iOS replica checkpoint (`PaneReplica.checkpoint`). The budget therefore
  belongs to the bounded stream, not to the encoder's default: snapshot and
  checkpoint callers keep the unbounded form. macOS recovery stores plain
  scrollback text and is unaffected.
- History rows dominate sync size; grid, alternate screen, and control state
  are screen-sized.
- Primary-screen resize reflows retained history and active rows as one
  stream (docs/design/2026-08-06-swift-terminal-engine.md D7), so a resize
  event cannot be replayed correctly against a replica whose history is
  incomplete.

## Decision

Two synchronization policies, stated separately:

- **Exact synchronization** is untouched. `pane.snapshot` keeps today's
  unbounded sync and its exact-state contract.
- **Bounded replication**: a reconstructible `pane.tape` stream carries a
  per-stream history byte budget. The budget is a request parameter,
  `syncHistoryBytes`, so a client can change it without a new DanTerm build;
  when the request omits it, the server default of 262,144 bytes (256 KiB)
  applies. Every sync the stream emits -- the opening sync and any later gap
  repair -- obeys the stream's budget. The sync record reports how many
  history rows were left out.

The budget is denominated in pre-base64 terminal-protocol bytes attributable
to history; record framing and base64 expansion are outside it.

Because of the resize premise above, a bounded stream whose replica omits
history does not replay a resize event. Resize repair uses the same
replacement unit as existing gap repair: when a fetched suffix bound for an
incomplete replica contains a resize, the stream delivers a fresh bounded
sync paired to that suffix's ending cursor in place of the whole suffix --
none of the replaced events are also delivered, and later events continue
exactly from the sync's cursor. A replica whose last sync omitted nothing is
exact and keeps receiving plain resize events, as today.

A replica is *known complete* only through this stream: it started from the
recorder's beginning with nothing evicted, or a sync on it reported
`droppedHistoryRows` of `0`. A cursor cannot carry completeness -- it is a
recorder coordinate -- so a stream resumed from a client-held cursor is
treated as history-incomplete until a sync on it establishes otherwise.

Lazy fetching of omitted history is a separate future feature; this change
only bounds what a sync carries.

Interface changes:

- `pane.tape` request: optional `syncHistoryBytes`, a whole non-negative
  number of bytes. `0` means grid-only. Negative or non-whole values are
  rejected the way other malformed tape parameters are, and a raw-mode
  request rejects the parameter as inapplicable -- raw streams never emit
  syncs. The CLI grows the matching flag, and
  `integrations/danterm/SKILL.md` is updated in the same change.
- Research doc 35's T22 records the partial answer in the same change:
  bounded history sync is this change; lazy history stays open (Non-goals).
- Sync record: gains `droppedHistoryRows`, the count of retained history rows
  the budget excluded; `0` when nothing was excluded.
  `DanTermClient.PaneTapeRecordReader` surfaces it on the assembled
  synchronization.

## Invariants

- I1: On a bounded stream, no sync's encoded history exceeds the stream's
  budget -- opening and repair syncs alike; the total payload exceeds it only
  by the screen-proportional cost of the grid, alternate screen, and control
  state, which are always carried whole.
- I2: The included history is a suffix of the source's retained history:
  replaying the sync on a fresh terminal reproduces the source grid exactly,
  and the replica's history matches the source's most recent rows verbatim.
- I3: The cut never leaves a leading wrap-continuation fragment: the oldest
  line in the replica's history is a complete logical line.
- I4: `droppedHistoryRows` equals the number of retained history rows the sync
  omitted, is `0` when the whole history fit, and survives multi-part
  assembly into the client reader's synchronization value.
- I5: A bounded stream preserves exact visible-grid replication: after
  applying each event record, and after applying each completely assembled
  synchronization (a sync's parts are one indivisible transfer, never applied
  partially), the replica's grid equals the source's. Only history may be
  incomplete, and only when a sync has reported it.
- I6: Bounding does not change when a sync is sent, with one stated
  exception: on a stream whose replica is not known complete, a fetched
  suffix containing a resize is delivered as a fresh bounded sync in its
  place. In
  particular, a request that sets `syncHistoryBytes` but can be served from
  retained events gets events, not a sync.
- I7: The exact consumers are unaffected: a pane with deep history snapshots
  its full retained state via `pane.snapshot`, and a deep-history
  `PaneReplica` checkpoint round trip preserves all retained history, as
  today.

## Proof obligations

- PO1 (I1): A terminal with history deep past the budget syncs within the
  bound, under the default and under explicit budgets including `0`; and a
  followed stream that opens under a budget, then suffers recorder eviction,
  repairs with a sync that obeys the same budget.
- PO2 (I2, I3): Replaying a bounded sync onto a fresh terminal yields the
  source grid exactly and a verbatim suffix of its history whose oldest line
  is complete, including when the natural cut would split a wrapped line.
- PO3 (I4): The reported drop count matches what was omitted; a pane whose
  history fits reports `0` and its sync payload stays at today's size; a
  multi-part sync exposes the same count through `PaneTapeRecordReader` after
  assembly.
- PO4 (I5, I6): On a stream whose sync omitted history, a suffix carrying
  output, then a resize, then more output arrives as a fresh bounded sync:
  none of the replaced events are delivered, later events continue exactly
  from the sync's cursor, and the replica grid equals the source grid
  afterward, in a scenario where replaying the resize would diverge (height
  growth pulling history rows into the grid); a stream whose replica is known
  complete still receives the plain resize event. The same replacement holds
  across resume: apply a truncated sync, disconnect, resume from that sync's
  cursor onto retained events, then resize -- the resumed stream repairs with
  a sync rather than replaying the resize.
- PO5 (I6): A request served from retained events today is still served from
  events when it also sets `syncHistoryBytes`.
- PO6 (I7): A deep-history pane's `pane.snapshot` retains its full history,
  and a deep-history `PaneReplica` checkpoint round trip restores it whole --
  both with history deeper than the default budget, so a truncation could not
  hide.
- PO7: Malformed `syncHistoryBytes` values, and the parameter on a raw-mode
  request, are rejected at the request boundary, in both IPC and CLI forms.

## Non-goals

- Lazy history paging (`pane.history` or similar); this change only bounds the
  sync.
- Subscription-scoping policy (which panes a client follows); bounded sync
  merely makes such policies cheap.
- Wire compression.

## Rejected ideas

- RI1: Naming the oldest included line as a `TerminalTextPosition` in the sync
  record as a future paging handle. Deferred: position addressing belongs to
  the `pane.history` design, and adding it later breaks nothing.
- RI2: Reporting dropped history *bytes* alongside rows. Measuring them
  requires encoding the very history the budget exists to skip.
- RI3: A row-denominated budget. The knob's purpose is wire cost, which is
  bytes.
- RI4: A server-side constant only. The client must be able to vary the
  budget without a new build while remote-client experiments are running.
- RI5: Replaying resize events against a history-incomplete replica with a
  budget floor "deep enough that reflow cannot reach the missing rows".
  Rejected: the safe floor depends on reflow mechanics (D7) and grid height,
  which makes grid exactness an argument instead of an invariant; the
  resize-resync rule keeps it structural.
- RI6: Carrying a history-completeness flag inside `PaneTapeCursor` so a
  resumed stream knows the replica's state. Rejected: it leaks replication
  policy into a recorder coordinate and trusts an untrusted client value; the
  conservative default (a cursor-resumed replica is not known complete) costs
  at most an occasional bounded sync on resize.

## Implementation discretion

- How the suffix that fits the budget is chosen (measure rows from the tail,
  estimate then verify, etc.), and where the default constant lives.
- How the stream remembers that its replica omits history, and whether the
  resize-resync narrows to cases D7 can actually affect.

## Commit progress
- [x] 1. feat(engine): bound the history a state synchronization carries
- [x] 2. feat(ipc): let a pane.tape stream bound its sync history
- [x] 3. feat(tape): resync a truncated replica instead of replaying a resize
- [ ] 4. docs(research): record the bounded-sync half of T22

## Implementation notes

- The stream's mode and its history budget travel as one value,
  `PaneTapeSyncPolicy`, rather than as a mode beside an optional number. A raw
  stream emits no synchronization, so a budget on one bounds nothing; making
  that pair unrepresentable keeps the rule at the two request boundaries
  instead of at every site that reads a stream's mode. `PaneTapeStreamMode`
  stays as the wire spelling the `mode` field carries.
- Both wire numbers moved: `paneTapeStreamVersion` 4 -> 5 because the sync
  record gained a required first-part field, and `danTermIpcProtocolVersion`
  2 -> 3 because a client that speaks the new shape would reject an old
  server's sync records rather than merely miss the feature, which is the
  documented reason that number moves.
- `--sync-history-bytes` is refused whenever the resolved mode is raw, not
  only when `--raw` was explicit. A bare `pane tape` dump resolves to raw, so
  a budget there would be silently inert; requiring `--reconstructible` says
  so instead.
- The phone's follow request names the default budget explicitly rather than
  omitting the field, so the value it runs under is visible at the call site.
- The replica's history standing lives beside the cursor in
  `PaneTapeFollowSubscriptions`, not in the runtime's per-stream transport. It
  describes the same position the cursor names, so holding the two apart would
  let a fetch decide the resize question from a standing that belongs to a
  different point in the stream.
- Which events need the whole history is a typed flag on the lowered event,
  decided at the engine adapter, rather than a `"type":"resize"` peek at the
  event JSON in the support layer. Reflow is engine knowledge, and the support
  layer treats an event's body as opaque everywhere else.
- The rule fires on every recorded resize, including a pinnedness-only one that
  changes no grid and reflows nothing. Narrowing it would mean tracking the
  replica's current grid to compare against, which is more state than the
  occasional extra sync is worth.

## Follow Up

- A raw `pane.tape` stream still pays for a full state serialization it never
  sends: `TerminalPTYHost.fencedFlightRecordingStream` resolves the state
  pairing on every open, and a raw policy resolves it with no budget. Passing
  a zero budget -- or skipping the resolve outright -- for a raw stream would
  drop that cost, which is proportional to the pane's whole retained
  scrollback.
