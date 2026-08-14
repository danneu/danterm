# Reconstructible pane tape: state sync plus cursor resume

## Problem and desired outcome

A pane's tape stream is not self-sufficient. A reader that does not receive
every event from the pane's birth ends up with a terminal that is wrong, and
usually is not told so.

Evidence, all from `research/35/F4`:

- A client joining with `--from-now` differed from the same pane's own state on
  active screen, cursor row, cursor visibility, `applicationCursorKeys`,
  `bracketedPaste`, `mouseTracking`, and the whole of scrollback. The
  input-mode rows are the damaging ones: a client encodes keystrokes from its
  own `inputModes`, so a late joiner sends the wrong key encodings and pastes
  unbracketed purely because it joined late.
- A joiner's visible screen repairs itself at the next full repaint while
  history stays permanently empty, so a joiner can look correct and be empty.
- A backlog reader whose retained head was evicted replayed 8,940 events into
  an 80x24 grid for a 179x66 pane, because the corrective resize was among the
  evicted events and the stream's `initial` geometry is birth geometry. The
  reader was told only a byte count.
- A client dropped at sequence 10089 and reconnected with `--from-now` skipped
  216 events and received no gap record, because from the producer's view a
  from-now request lost nothing relative to what it asked for.
- There is no method that reports a pane's state at all: `pane.info` carries no
  geometry, modes, or screen state, `pane.rows` no attributes, `pane.read` text
  only.

Desired outcome: every accepted tape request yields a stream from which the
reader can reconstruct the pane's exact state, whatever the reader's start
position and whatever the recorder has evicted. Plus a one-shot way to ask a
pane what state it is in.

Load-bearing premises taken from the tree, not re-derived here:

- `TerminalFlightRecordingCursor` (sequence plus per-direction byte
  watermarks) is already a resume position, and the `start` record already
  publishes a cursor -- which is where it stays only for a stream that opens
  without a sync, per I9. `cursorSnapshot(from:)` computes exact per-direction
  loss, but only for a cursor its own recorder minted: it preconditions the
  sequence and both byte watermarks against its lifetime totals, and places the
  cursor by index arithmetic that assumes the same sequence space. Those are
  internal invariants today, because every cursor it sees came from that
  recorder. A supplied cursor makes them remote input, which I10 covers.
- The fence a state transfer needs already exists: `diagnosticCapture` returns
  terminal state and recorder transitions from one `performAccountedFence`, so
  state and stream cursor come out of a single owner-queue moment.
  `TerminalPaneSessionController.cachedTerminal` is not that route -- it is the
  last asynchronously consumed snapshot and lags the recorder's live cursor, so
  pairing it with a live cursor drops or double-applies events.
  `TerminalFlightRecordingCapture` is the narrower precedent: it fences birth
  geometry against a cursor snapshot in one value.
- The recorder is already a per-pane bounded ring buffer, and
  `PaneTapeFollowSubscriptions` already holds per-subscriber cursors.
- The engine models neither a title stack nor OSC 4 palette redefinition, and
  retains nothing from a DCS sequence once it finishes. It does retain an
  unfinished one: `TerminalInputStream` holds a `UTF8Decoder` and an
  `EscapeAbsorber` that keep a partial CSI, DCS, OSC, or SOS/PM/APC sequence
  with its parameters, intermediates, and collected payload across feeds. Colors
  stay semantic; the renderer owns the palette.
- Device-query replies accumulate in the engine and are drained by whoever owns
  the PTY. A client engine has no PTY, so nothing sends its replies.

## Decision

**Sync is one or more records in the tape stream, and its payload is terminal
bytes.**

The producer transfers pane state by serializing it back into a byte stream
that reconstructs it when fed to a reset terminal of a stated geometry. The
reader needs no new decoding machinery and no engine-internal wire format: it
already knows how to feed bytes to a terminal, which is the whole of its job.
The wire is the terminal protocol itself, so a client built against an older
engine is not broken by engine changes the way a struct-shaped state dump would
break it.

Rejected alternative and why: a structured serialization of engine state
(cells, attributes, mode flags as protocol values) is exact but couples the
wire to engine internals, needs a load-state entry point that exists for no
other reason, and makes every engine change a wire change. It buys nothing the
byte form does not already have, because anything the byte form cannot express
is state no real terminal stream could have produced.

**The broker is the recorder, and it lives in the app runtime.** No new
buffering component. The per-pane ring buffer and the per-subscriber cursors
both already exist in the app; a second ring in the bridge would duplicate them
behind a second eviction bound and a second sequence space, and would only earn
its place if a client's offline window could outrun the app-side ring -- which
sync removes as a failure mode. The bridge stays a frame proxy, so this work
does not depend on the bridge existing.

**The recorder's retention bound stays a debugging parameter.** Sync makes
recovery independent of eviction, so retention no longer decides whether a
session survives. The bound is not raised, and nothing outside the debugging
value of a raw dump depends on it.

Behavioral scope:

- A tape request states its start position: the beginning, now, or a supplied
  cursor.
- The producer injects a sync exactly when the requested position is not
  reconstructible from the records it will deliver, and stream contents resume
  at the sync's own fence.
- A gap record states loss measured against the position the requester asked
  for, including the case that asked for a supplied cursor. It is exact and
  per-direction for a cursor the producer can place in its own lifetime. For a
  cursor it cannot place, per-direction counts do not exist -- the cursor names
  a different sequence and byte space -- so the record carries the total form
  instead, and never invented numbers in exact fields.
- A new one-shot method returns the same sync payload for a pane, in the same
  records, ending at its fence. It is a bounded stream rather than a single
  response, for the reason I5 gives: a full pane's payload does not fit one
  line, and the pane with deep history is the one the method exists for.
- A raw mode suppresses sync, for reading the record rather than reconstructing
  from it. A raw stream is not reconstructible and says so in its start record.
  Asked to resume from a cursor the producer cannot place, it carries the same
  total-loss gap record and continues from the retained head: it has already
  declared that reaching exact state is not what it offers.
- The finite dump of a pane's retained tape defaults to raw, because a debugger
  asked for the recorded events; a follow or resume stream defaults to
  reconstructible.

Out of scope for this plan: what a client does with the state once it has it,
geometry negotiation (`research/35/T10` owns it), and the bridge.

## Invariants

- **I1 -- reconstruction.** After applying a sync, a reader's terminal
  state equals the source pane's observable state at the sync's fence: the
  active screen's contents with attributes and which screen is active, the
  primary screen retained under an active alternate screen, the primary
  screen's whole retained history, the cursor including visibility,
  shape, blink and the saved cursor, the full input modes, and the remaining
  parser and screen modes the tape sets and never restates -- scroll region,
  origin, autowrap, tab stops, current pen, charsets, synchronized output,
  hyperlink state, and shell-integration marks. It also equals the source
  pane's unfinished input-stream state -- a partial UTF-8 scalar, and a
  sequence the absorber has begun but not dispatched, with its parameters,
  intermediates, and collected payload -- because a fence lands between two
  recorded byte chunks and nothing makes that boundary fall in ground state. An
  inactive alternate screen's
  contents are excluded: the engine blanks the alternate grid on every entry, so
  no byte stream can ever reveal what a retained inactive alternate screen
  holds, and carrying it would cost a full extra screen on every sync of any
  pane that has run a full-screen program.
- **I2 -- fence.** A sync's state and its stream cursor are taken in one
  fence, so no event can be both reflected in the state and delivered after it,
  and none can be reflected in neither.
- **I3 -- self-sufficiency.** Every stream that does not declare itself raw is
  reconstructible: a reader that applies its records in order reaches the
  source pane's exact state, for any start position and any amount of
  eviction.
- **I4 -- stated loss.** Loss is measured against the position the requester
  asked for, and any loss is stated. A resume from a supplied cursor that skips
  events reports them.
- **I5 -- the whole retained history is transferred, as one indivisible
  prefix.** A sync carries all the history the source pane retains, as one or
  more records whose payload and continuation cursor all come from the single
  fence of I2. Its records are contiguous: no recorded event is delivered
  between them, so no live output can be applied before the state it sits on
  top of. The framer's line bound sizes a record, not the transfer: the engine's
  scrollback budget and the IPC line bound are both 16 MiB, so a full pane's
  encoded history does not fit one line and a one-record transfer would drop
  history the source still holds.
- **I6 -- geometry is carried.** A sync states the geometry its bytes
  reconstruct at, which is not the recorder's birth geometry.
- **I7 -- retention independence.** No stream's ability to reach exact state
  depends on the recorder's retention bound.
- **I8 -- provenance.** A sync's records are distinguishable from recorded traffic.
  Its bytes were synthesized and were never on a PTY, so tooling that treats
  the tape as evidence does not mistake them for observed output.
- **I9 -- an incomplete sync changes nothing.** A sync takes effect at its
  completion or not at all, on the wire and at the reader alike. The producer
  publishes the sync's fence cursor when the last record completes it, never in
  the start record before it, so a cursor never names a position the reader has
  not been given everything up to. The reader applies a sync only once it is
  complete, so a stream cut partway through leaves the reader's terminal
  untouched and still exactly at the cursor it held before. Recovery is then
  ordinary resume from that cursor, with no separate retry route: the events
  since it are either retained, and replay onto state that never moved, or
  evicted, and the injection rule gives the reader a fresh sync. Without both
  halves, a reader that applied part of a reset-and-repaint payload is at no
  position at all, and every continuation it is sent lands on a mangled
  terminal.
- **I10 -- a cursor is meaningful only to the recorder that minted it.** Every
  published cursor carries the identity of the recorder lifetime that minted
  it, and a supplied cursor carries it back. The producer places a supplied
  cursor in its own lifetime before using it, and a cursor it cannot place --
  wrong lifetime, or out of range for the right one -- is by definition not
  reconstructible: on a reconstructible stream it takes the fresh-sync branch of
  the injection rule, on a raw stream the branch that rule already has for raw,
  and either way loss is stated as total against the position the requester
  asked for. It is
  never an error the client must handle on its own, because resuming across an
  app restart is the ordinary case a recovered pane produces, and a second
  recovery route is what I9 exists to avoid. Without this, a stale cursor whose
  sequence happens to fall under the new lifetime's head looks reconstructible,
  so the reader is spliced onto another lifetime's events with no sync and no
  gap; and one whose sequence falls above it reaches a precondition, so a
  remote argument kills the app.

## Proof obligations

- **PO1 (I1).** Round-trip: drive a terminal through a corpus that reaches each
  class of state named in I1, serialize, feed the result to a fresh terminal at
  the stated geometry, and assert the two terminals' state is equal. The corpus
  includes an alternate-screen program with modes set, wide characters,
  soft-wrapped history, a saved cursor, hyperlinks, shell-integration marks,
  and a pane sitting at the engine's hyperlink and semantic-metadata cap --
  the only place where replaying in a different order can admit a different
  surviving set than the source retained. Equality is asserted over the
  observable state named in I1, not over the bytes produced. A second round-trip
  takes the sync with the fence inside an unfinished input: a split UTF-8
  scalar, and a partial CSI, DCS, and OSC sequence. It then feeds the
  continuation bytes to both terminals and asserts they still agree, which is
  what fails when a reset reader prints a DCS payload the source absorbs.
- **PO2 (I2).** Events recorded concurrently with a sync appear exactly once in
  the reader's result: neither dropped between state and cursor, nor applied
  twice on top of state that already includes them.
- **PO3 (I3, and the prescribed acceptance test).** A client joins a pane
  already running a full-screen program, the program exits, and the client's
  scrollback depth and `inputModes` match the source pane's. The assertion is
  on state the screen does not restore by itself; a visible-screen assertion
  would pass against a sync that carried nothing, because F4 showed the
  visible screen heals through a prompt repaint.
- **PO4 (I4).** A reader that drops at a known sequence and resumes from it
  receives either a contiguous continuation or a gap stating the exact
  per-direction loss -- never silence. This pins the F4 reconnect case, where
  216 skipped events were reported as nothing.
- **PO5 (I7).** With the recorder's whole retained tape evicted past the
  reader's position, the reader still reaches the source pane's exact state.
  This pins the F4 eviction case, where an evicted resize left a reader
  replaying into an 80x24 grid for a 179x66 pane.
- **PO6 (I5).** A pane whose retained history exceeds one IPC line is
  transferred in full: every record is accepted by the framer, and the reader's
  history depth and contents equal the source pane's.
- **PO7 (I6).** A sync taken after a pane has resized reconstructs at the
  current geometry, not the birth geometry.
- **PO8 (the mode contract in Behavioral scope).** Request selection behaves as
  stated: a finite dump defaults to raw and a follow or resume stream to
  reconstructible; a raw stream carries no sync and declares itself raw; a
  reconstructible stream carries a sync exactly when the requested position is
  not reconstructible from the records it will deliver, and none when it is;
  and the one-shot method's state payload reconstructs the same state as the
  streamed form, including on a pane whose payload exceeds one line. Without
  this, an implementation can pass PO1 through PO7 while contaminating a
  debugging dump with synthesized bytes.
- **PO9 (I5, I9).** A multi-record sync delivered while the pane keeps writing,
  cut before each of its records in turn, with the reader's previous cursor
  still fully retained by the recorder -- the case where the injection rule
  correctly sends continuation records rather than a second sync. No cut
  interleaves live output with the sync; no cut before completion leaves the
  reader holding a resumable cursor from that stream or changes the reader's
  terminal; and a reader that resumes from its unchanged previous cursor after
  each cut, and finally completes, reaches the source pane's exact state having
  applied the sync exactly once.
- **PO10 (I10).** A resume with a cursor from a previous recorder lifetime,
  both below and above the new lifetime's head, yields a fresh sync with total
  loss stated -- never a trap, and never a silent splice onto the new
  lifetime's events. The below-head case is the one that looks correct: its
  numbers are in range, so only the lifetime identity distinguishes it.

## Non-goals

- Geometry negotiation between a client and the pane. F4 settled that stream
  geometry is unconditional; `research/35/T10` decides observe versus claim.
- Persisting a snapshot across app restarts. Sync is a live fence of a live
  pane.
- Buffering in the bridge, or any subscription that outlives its connection.
  Resume is the client re-asking from its cursor.
- Any change to how a client renders or encodes input from the state it
  receives.

## Accepted risks

- **AR1 -- serializer drift.** The serializer is a second expression of engine
  state and can fall behind a new mode the engine starts modelling. Accepted
  because PO1 fails loudly when it does, and because the alternative -- a
  structured state wire -- has the same exposure plus a versioned format.
- **AR2 -- sync cost on a metered link.** A sync carries the live grid and the
  pane's whole retained history, so a reconnect on cell data is not free.
  Accepted: it is
  expected to be smaller than replaying the recorder's retained tape in the
  flooding and long-offline cases, and is unverified for a quiet pane with deep
  history and little recent traffic, where sync may carry the whole scrollback
  to avoid replaying a few bytes. `research/35/T20` sizes both.
- **AR3 -- superseded events are not delivered.** When a sync is injected into
  a backlog read, retained events before its fence are not sent, because
  applying them after the state would double-apply them. A reader that wants
  those bytes asks for the raw stream.
- **AR4 -- a deferred sync is held alongside the reader's own state.** I9 makes
  the reader hold the sync aside until it completes, so a client peaks at its
  committed terminal plus either the complete encoded sync or a scratch
  terminal, its choice. The encoded form is larger than the pane's scrollback
  storage -- that is why I5 needs several records -- so the peak is not bounded
  by the engine's scrollback budget; `research/35/T20` sizes it. Accepted:
  transient, and it buys a recovery route that is ordinary resume rather than a
  second protocol mode.

## Rejected ideas

- **RI1 -- structured state serialization** as the wire format. See Decision.
- **RI2 -- raising the recorder's retention bound** to make backlog replay a
  reliable recovery path. It makes recovery probabilistic in memory instead of
  guaranteed, and F4 showed the failure is silent and geometric.
- **RI3 -- a broker in the bridge.** A second ring buffer, a second bound, and
  a dependency on a process that does not exist yet, for a durability property
  sync already provides.

## Deferred, with the reason

- **Two engines answering one query.** A writer client's engine generates
  replies for `ESC[6n` and `ESC[0c` that the Mac engine also generates. This is
  an input-direction question, not a state-transfer one: the rule it needs is
  that only the engine owning the PTY answers, and a client never forwards its
  own drained replies. It belongs with the input surface work, not here.
- **Completed DCS sequences, OSC 4 palette redefinition, and the title stack.**
  F4 listed these as unprobed. They are not gaps in the sync payload: the engine
  keeps nothing once a DCS sequence finishes, and models neither a palette
  override nor a title stack, so there is no settled state to carry. They become
  sync work only if the engine starts modelling them, and PO1 is what will say
  so. An unfinished DCS sequence is a different thing and is carried: it lives in
  the absorber, and I1 covers it.
- **OSC 11 background override.** Query traffic is visibly present in captured
  streams, but the engine answers the query from host-configured defaults and
  retains no override, so there is no retained state to transfer.
  Revisit with the same trigger as the item above.

## Deliverables

- A sync in the tape stream and a one-shot method returning the same
  payload, both documented in `integrations/danterm/SKILL.md` in the same
  change as the CLI surface that reaches them.
- A start-position argument on the tape request that accepts a supplied cursor,
  replacing the two-state beginning-or-now choice. Published cursors carry
  their recorder lifetime's identity per I10, so the cursor's wire form changes
  wherever it appears.
- The stream version moves, and the existing capture-mode and end-reason
  spellings that already use the word "snapshot" for a finite dump are renamed,
  so "snapshot" names one thing.

## Implementation discretion

- Where the serializer lives inside the engine module, and the exact byte
  sequences it emits for a given state -- PO1 constrains the result, not the
  encoding.
- How a sync payload is split across records, provided every record fits one
  IPC line, the whole payload and its continuation cursor come from the single
  fence of I2, and the reader can tell the transfer is complete.

## Implementation notes

- `--from-cursor` accepts the exact cursor JSON object emitted by `start` and
  `sync` records. The IPC request carries that cursor as a structured start
  position instead of making each caller transcribe its fields.

## Commit progress

- [x] 1. Bind resume cursors to recorder lifetimes and validate supplied positions
- [x] 2. Serialize exact terminal state and fence it with the recorder cursor
- [x] 3. Add reconstructible and raw tape stream state machines
- [x] 4. Expose pane state and cursor resume through IPC, CLI, client, and docs
