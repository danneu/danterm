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
  watermarks) is already a resume position, `cursorSnapshot(from:)` already
  computes exact per-direction loss against an arbitrary cursor, and the
  `start` record already publishes a cursor. The missing piece at the protocol
  edge is only the ability for a requester to supply one.
- `TerminalFlightRecordingCapture` already fences geometry against a cursor
  snapshot in one value, for the same reason a state transfer needs a fence.
- The recorder is already a per-pane bounded ring buffer, and
  `PaneTapeFollowSubscriptions` already holds per-subscriber cursors.
- The engine models neither a title stack, nor OSC 4 palette redefinition, nor
  DCS state (DCS is absorbed and discarded). Colors stay semantic; the renderer
  owns the palette.
- Device-query replies accumulate in the engine and are drained by whoever owns
  the PTY. A client engine has no PTY, so nothing sends its replies.

## Decision

**Sync is a record in the tape stream, and its payload is terminal bytes.**

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
- The producer injects a sync record exactly when the requested position is not
  reconstructible from the records it will deliver, and stream contents resume
  at the sync's own fence.
- A gap record states exact per-direction loss measured against the position
  the requester asked for, including the case that asked for a supplied cursor.
- A new one-shot method returns the same sync payload for a pane.
- A raw mode suppresses sync, for reading the record rather than reconstructing
  from it. A raw stream is not reconstructible and says so in its start record.

Out of scope for this plan: what a client does with the state once it has it,
geometry negotiation (`research/35/T10` owns it), and the bridge.

## Invariants

- **I1 -- reconstruction.** After applying a sync record, a reader's terminal
  state equals the source pane's state at the sync's fence: both screens'
  contents with attributes and which is active, the primary screen's retained
  history to the depth the record states, the cursor including visibility,
  shape, blink and the saved cursor, the full input modes, and the remaining
  parser and screen modes the tape sets and never restates -- scroll region,
  origin, autowrap, tab stops, current pen, charsets, synchronized output,
  hyperlink state, and shell-integration marks.
- **I2 -- fence.** A sync record's state and its stream cursor are taken in one
  fence, so no event can be both reflected in the state and delivered after it,
  and none can be reflected in neither.
- **I3 -- self-sufficiency.** Every stream that does not declare itself raw is
  reconstructible: a reader that applies its records in order reaches the
  source pane's exact state, for any start position and any amount of
  eviction.
- **I4 -- stated loss.** Loss is measured against the position the requester
  asked for, and any loss is stated. A resume from a supplied cursor that skips
  events reports them.
- **I5 -- stated truncation.** A sync record states the history depth it
  carries. A record that could not carry the pane's full history says so; it
  never truncates silently. The record fits one IPC line.
- **I6 -- geometry is carried.** A sync record states the geometry its bytes
  reconstruct at, which is not the recorder's birth geometry.
- **I7 -- retention independence.** No stream's ability to reach exact state
  depends on the recorder's retention bound.
- **I8 -- provenance.** A sync record is distinguishable from recorded traffic.
  Its bytes were synthesized and were never on a PTY, so tooling that treats
  the tape as evidence does not mistake them for observed output.

## Proof obligations

- **PO1 (I1).** Round-trip: drive a terminal through a corpus that reaches each
  class of state named in I1, serialize, feed the result to a fresh terminal at
  the stated geometry, and assert the two terminals' state is equal. The corpus
  includes an alternate-screen program with modes set, wide characters,
  soft-wrapped history, a saved cursor, hyperlinks, and shell-integration
  marks. Equality is asserted over state, not over the bytes produced.
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
- **PO6 (I5).** A pane whose history exceeds what one record can carry produces
  a record that states the depth it carried and is accepted by the framer.
- **PO7 (I6).** A sync taken after a pane has resized reconstructs at the
  current geometry, not the birth geometry.

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
- **AR2 -- sync cost on a metered link.** A sync carries the live grid and a
  history tail, so a reconnect on cell data is not free. Accepted: it replaces
  replaying up to the recorder's whole retained tape, which is larger.
- **AR3 -- superseded events are not delivered.** When a sync is injected into
  a backlog read, retained events before its fence are not sent, because
  applying them after the state would double-apply them. A reader that wants
  those bytes asks for the raw stream.

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
- **DCS state, OSC 4 palette redefinition, and the title stack.** F4 listed
  these as unprobed. They are not gaps in the sync payload: the engine does not
  model them, so there is no state to carry. They become sync work only if the
  engine starts modelling them, and PO1 is what will say so.
- **OSC 11 background override.** Query traffic is visibly present in captured
  streams, but the engine answers the query from host-configured defaults and
  retains no override, so there is no retained state to transfer.
  Revisit with the same trigger as the item above.

## Deliverables

- A sync record in the tape stream and a one-shot method returning the same
  payload, both documented in `integrations/danterm/SKILL.md` in the same
  change as the CLI surface that reaches them.
- A start-position argument on the tape request that accepts a supplied cursor,
  replacing the two-state beginning-or-now choice.
- The stream version moves, and the existing capture-mode and end-reason
  spellings that already use the word "snapshot" for a finite dump are renamed,
  so "snapshot" names one thing.

## Implementation discretion

- Where the serializer lives inside the engine module, and the exact byte
  sequences it emits for a given state -- PO1 constrains the result, not the
  encoding.
- How the history-depth bound in I5 is chosen, provided the depth carried is
  stated and the record fits one IPC line.
