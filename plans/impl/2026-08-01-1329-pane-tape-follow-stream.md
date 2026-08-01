# Follow a live pane tape as a JSON Lines stream

## Context

`danterm pane tape --pane <id>` (shipped by
`plans/impl/2026-08-01-0149-live-pane-tape-flight-recorder.md`) answers one
question: *what already happened*. It fences the pane's 8 MiB flight recorder,
encodes the whole ring as one JSON document, and closes the connection. That is
the right shape for producing a replay fixture after an artifact is noticed.

It is the wrong shape for the other half of the workflow: an agent watching a
pane *while* the user drives it. Repeated snapshotting re-serializes the entire
backlog every poll, gives no way to tell new bytes from old, and the dump only
becomes readable once the whole 16 MiB-capped line lands.

Desired outcome: `danterm pane tape --pane <id> --follow` prints the bounded
backlog and then every new event as it happens, one complete JSON object per
line, so a reader gets usable records immediately and can detect anything it
missed. `--from-now` skips the backlog when only the live tail matters.

Load-bearing premises, with evidence:

- The transport already supports server-initiated frames: `IpcConnection`
  reads in a loop (`IpcConnection.swift#startReading`) and writes the `hello`
  notification unsolicited (`#writeHello`). Nothing else uses that capability.
- Exactly one *response* per request id is structurally enforced --
  `IpcConnection.swift#takeResponseId` removes the mapping -- so a stream must
  be notifications after a single reply, not repeated replies.
- The recorder's ring is already the natural per-subscriber buffer: it is
  bounded, ordered, and evicts oldest-first
  (`TerminalFlightRecorder.swift#enforceBounds`). It has no sequence numbers
  today, so a reader cannot tell eviction from delivery.
- The dump path proves the fence discipline this needs: `fencedFlightRecording`
  copies event *references* on the owner queue and encoding happens off-actor
  (`TerminalPTYHost.swift#fencedFlightRecording`,
  `SwiftTerminalSessionView.swift#flightRecordingEncoder`).
- The event JSON already exists and is correct: `NeutralTerminalRecordingEvent`
  encodes as `{"type":"feed","base64":"..."}` /
  `{"type":"resize","columns":N,"rows":N}`
  (`NeutralTerminalRecording.swift`). A stream record wraps that value; it does
  not re-derive it.
- `AppRuntime` drops its connection reference after one reply (every handler
  does `ipcConnections.removeValue(forKey: reqId)`), and `IpcServer` never tells
  the runtime a connection closed. Both are prerequisites for a subscription
  that outlives its reply.
- The CLI cannot stream as written: `SO_RCVTIMEO` is 5 s
  (`cli/main.swift#socketTimeoutSeconds`), so any idle pane would abort with
  "DanTerm is not responding".
- Dev-only gating is already in place and needs no new mechanism: the recorder
  exists only when the bundle id is `com.danneu.danterm-dev`
  (`SwiftTerminalBackend.swift`), and `pane.tape` already refuses ambient pane
  context (`Update.swift`, `resolvePane(requireExplicit: true)`).

## Decision

A cursor-polled subscription over the existing control socket, delivered as
JSON-RPC notifications and rendered by the CLI as JSON Lines.

- **Surface**: `danterm pane tape --pane <id> [--follow] [--from-now]`.
  Without `--follow` the command is byte-for-byte what it is today.
  `--from-now` is a usage error without `--follow`. Explicit `--pane` stays
  required; a backend with no recorder still gets the existing
  `-32603 pane tape unavailable for this terminal backend` error.

- **Stdout shape** (`--follow`), one complete JSON object per line:

  ```
  {"kind":"start","version":1,"provenance":{...},"initial":{"columns":120,"rows":40}}
  {"kind":"event","sequence":42,"elapsedNanoseconds":123456,"event":{"type":"feed","base64":"SGVsbG8="}}
  {"kind":"event","sequence":43,"elapsedNanoseconds":234567,"event":{"type":"resize","columns":100,"rows":30}}
  {"kind":"gap","droppedEventCount":7,"droppedPayloadBytes":8192}
  {"kind":"end","reason":"pane-closed"}
  ```

  `version` is the *stream* protocol version, independent of the recording
  schema version. `provenance` and `initial` are carried so a stream is in
  principle reassemblable into a replayable tape; no tooling does that (see
  Non-goals). `initial` is the recorder's birth geometry for a backlog stream
  and the pane's current geometry for `--from-now`. `event` is the value
  `NeutralTerminalRecordingEvent` already encodes -- one encoder, no second
  dialect.

  For `--from-now`, `initial` and the starting cursor must come from a **single
  owner-queue fence**. Reading current geometry and the next sequence
  separately lets a resize land between them, so the stream would claim one
  geometry while its first event belongs to another -- a silently wrong
  reconstruction. One atomic snapshot returns both.

- **Wire shape**: the JSON-RPC *result* for the `pane.tape` request is the
  `start` record. Every later record arrives as a notification (no id) with
  method `pane.tape.event` and params
  `{"subscription": "<id>", "record": {...}}`. The socket stays a coherent
  JSON-RPC stream; the CLI unwraps `record` and writes it as one stdout line.
  The server writes the `end` record and then closes the connection.

- **Delivery**: a polling pump coordinated by `AppRuntime`, running only while at
  least one subscription exists, takes a cursored snapshot per subscription
  through the owner fence and writes the resulting batch. The recorder's ring is
  the buffer; the per-subscriber bound is **one batch in flight** -- no new fetch
  is issued for a subscription until its previous batch has been handed to the
  socket. A reader that cannot keep up simply falls behind the ring, which
  surfaces as a sequence discontinuity, which becomes a `gap` record. No
  observer, queue, or callback is added to the PTY output path.

- **Sequencing**: the recorder assigns a lifetime-monotonic sequence to every
  recorded event, never reused and never reset by eviction. A snapshot reports
  the first retained sequence and the next sequence to be assigned, so a
  subscriber computes its gap exactly rather than estimating it. Gap
  `droppedPayloadBytes` is exact too (a cumulative-payload watermark carried per
  retained event is the cheapest way to get that; mechanism is discretion).

- **Termination**: an explicit `end` record (then connection close) is written
  only while the app stays alive to write it -- the pane disappearing is the
  case that matters (`pane-closed`). **App quit terminates the stream as a clean
  EOF, not an `end` record**: `AppRuntime` calls `NSApp.terminate` synchronously
  (`AppRuntime.swift#perform`) while `IpcConnection` writes on a private queue
  (`IpcConnection.swift#writeLine`), so a queued `app-quitting` record can lose
  the race with process exit and would make `end` a promise the app cannot keep.
  A client that reads EOF without an `end` record exits 0 -- the app went away.
  A client disconnect or a failed socket write drops the subscription silently;
  `IpcServer` gains a close notification to the runtime so subscriptions cannot
  outlive their connection.

- **Testability seam**: the lifecycle and cursor/batch/gap logic is portable, not
  AppKit -- it lives in `DanTermSupport` beside `PaneTapeDumpPreparation.swift`,
  which means it must obey that module's dependency invariant: DanTermSupport
  depends on DanTermProtocol plus Foundation/Darwin, and on nothing in
  TerminalPTY or TerminalCore (`lib/DanTermSupport/Package.swift`). So the
  portable layer consumes a **support-owned value representation** of a batch of
  recorded events, built from protocol primitives and `JSONValue`;
  `AppRuntime` adapts the fenced `TerminalFlightRecordingSnapshot` into that
  representation at the module boundary it already crosses, and supplies the
  fence and the socket write. That adaptation and the JSON encoding of each
  record run **off the main actor**, on the same off-actor discipline the dump
  path already uses -- the fence copies references and nothing else.
  `AppRuntime` is `@MainActor` and `IpcConnection.swift#writeLine` encodes
  synchronously on its caller, so encoding a full 8 MiB / 32,768-event backlog
  inline would hang AppKit for exactly as long as the user is trying to drive
  the pane -- the workflow this change exists to serve.

- **Enablement**: unchanged. Follow inherits dev-bundle gating from the recorder
  itself; production panes have no recorder and answer with the existing
  unsupported-backend error. Output stays raw and unscrubbed, which is why the
  command stays explicit-pane-only.

Decisive constraints:

- No encoding, no I/O, and no new callback on the PTY output path *or the main
  actor*. The pump's owner-queue work is a reference copy, exactly as the dump's
  is, and everything downstream of the fence -- adaptation, encoding, writing --
  happens off both.
- A slow or stalled reader must never block the PTY owner queue, and must never
  grow unbounded memory: it falls behind the ring and gets a `gap`.
- The existing snapshot command's output document is unchanged, byte for byte.

## Invariants

- **I1 (immediate lines)**: every record reaches the reader as a complete line
  as soon as it is produced -- stdout is written unbuffered per record, and no
  record waits on a later one.
- **I2 (backlog then live)**: a `--follow` stream with no `--from-now` starts at
  the oldest retained event and continues into new ones with no duplicate and no
  silently missing event; `--from-now` starts at the next sequence to be
  assigned and emits no backlog, with its `start.initial` geometry and its
  starting cursor read in one owner-queue fence so a concurrent resize cannot
  put them out of step.
- **I3 (sequences are total and stable)**: sequences are lifetime-monotonic,
  contiguous over recorded events, never reused, and unaffected by eviction; the
  cursor a subscriber reports advances monotonically.
- **I4 (gaps are exact and honest)**: if any event between the cursor and the
  first retained event was evicted, exactly one `gap` record is emitted before
  the next `event` record, and its `droppedEventCount` and `droppedPayloadBytes`
  are the exact counts for that range -- not lifetime totals and not estimates.
  This covers subscription time as well as steady state: a backlog stream over
  an already-truncated recorder emits one `gap` before its first `event`, so a
  reader is never handed a silently incomplete history.
- **I5 (no back-pressure onto the PTY)**: a stalled reader produces no growth in
  retained memory beyond the recorder's existing budget, no queued-write growth
  beyond one batch per subscription, and no additional owner-queue work.
- **I6 (bounded termination)**: a followed stream always terminates -- with an
  `end` record followed by connection close when the pane disappears, and with
  clean EOF when the app exits. A disconnected client's subscription is dropped
  on the next tick at the latest, and a dropped subscription performs no further
  fences.
- **I7 (snapshot untouched)**: `pane tape --pane <id>` without `--follow`
  produces the identical document it produces today, and the recorder's
  `encodedRecording()` gains no field.
- **I8 (one event dialect)**: the `event` object inside a stream record is
  exactly what `NeutralTerminalRecordingEvent` encodes; stream and snapshot can
  never disagree about how a feed or resize is represented.
- **I9 (dev-only, explicit-pane-only)**: a production-bundle pane answers
  `--follow` with the unsupported-backend error and starts no subscription; a
  `--follow` without an explicit `--pane` is a usage error.

## Proof obligations

- **PO1 (I2, I3, I4)**: recorder tests for the cursored snapshot -- returns exactly
  the events at or after the cursor; sequences survive eviction; the first
  retained sequence advances by exactly the number evicted; a cursor pointing
  into evicted range reports the exact dropped count and payload bytes for that
  range (including a case where eviction happens *after* some of those events
  were already delivered, so lifetime totals would give the wrong answer); and
  the `--from-now` origin returns current geometry and next sequence from one
  call, so no caller can compose them from two reads.
- **PO2 (I2, I4)**: batch-construction tests in `DanTermSupportTests` -- backlog
  start, `--from-now` start, an empty tick emits nothing and does not move the
  cursor, a gap emits exactly one `gap` record positioned before the next
  `event`, consecutive batches never duplicate or skip a sequence, and a backlog
  subscription over a recorder that has *already* evicted emits exactly one
  leading `gap` carrying the exact evicted event and payload-byte counts.
- **PO3 (I5, I6)**: subscription-lifecycle tests in `DanTermSupportTests` -- a
  subscription with a batch in flight is not fetched again on the next tick;
  completing the batch re-enables it; a vanished pane produces an `end` once and
  then nothing further; a closed connection removes every subscription it owned.
- **PO4 (I7)**: a test pins the snapshot document for a fixed recorder state, so
  adding sequence tracking cannot leak a field into `encodedRecording()`.
- **PO5 (I8)**: a test asserts a stream `event` payload equals
  `JSONEncoder().encode(NeutralTerminalRecordingEvent)` for both a feed and a
  resize, so the two paths cannot drift.
- **PO6 (I9)**: `DanTermProtocol` parser coverage -- `--follow`, `--follow
  --from-now`, `--from-now` alone (usage error), `--follow` without `--pane`
  (usage error), unknown flags -- plus an `UpdateIpcTests` case proving
  `pane.tape` with `follow: true` resolves the addressed pane and emits the
  follow command, and errors on a missing or unknown pane.
- **PO7 (I1)**: a CLI-level test that the stream renderer writes one complete
  line per record through the unbuffered stdout path (not `print`), and stops
  cleanly on an `end` record and on EOF.
- **PO8 (I1, I5, I6)**: one integration test over a real local Unix socket,
  driving hello -> `start` response -> `event`/`gap` notifications ->
  termination through the production framing and connection paths. PO2/PO3/PO7
  each test one side of the seam and all pass even if the wiring between them is
  wrong; this is the only obligation that fails when the response precedes no
  notifications, notifications arrive out of order or unwrapped incorrectly, a
  write completion never fires (so the in-flight flag latches and the stream
  silently stalls), or the connection closes before the final record is flushed.
  It also covers both terminations: `end`-then-close, and client disconnect
  dropping the subscription.

## Non-goals

- Capturing input events. The recorder's boundary is PTY feed and resize, so a
  followed stream shows the *output caused by* keystrokes, mouse, focus changes,
  and pastes -- not those actions themselves. Widening the event boundary is a
  separate change.
- Reassembly tooling. `pane tape` (snapshot) plus
  `scripts/terminal-tape-to-fixture.py` remains the one supported path from a
  live pane to a committed fixture. The stream carries enough to be reassembled;
  nothing in this change does it.
- Following more than one pane per invocation, or an all-panes firehose.
- Follow in production builds.
- Timing-faithful playback; `elapsedNanoseconds` stays inert metadata.
- A Debug-menu follow action.

## Rejected ideas

- **Push observer on the PTY owner queue**: a per-subscriber bounded queue fed
  from `record()` gives lower latency but puts a callback on the hot output path
  and adds a second eviction/gap accounting to get right. The ring is already a
  correct bounded buffer; polling it with a cursor reuses that accounting.
- **An `AsyncStream`/`AsyncChannel` from the recorder to the subscriber**: the
  same push design in Swift-concurrency clothing. `.bufferingNewest(n)` bounds
  the buffer and drops oldest, but it never reports *what* it dropped, so I4's
  exact gap counts would still need lifetime sequence numbers on events -- the
  whole mechanism the poll design already has, plus a redundant second buffer
  and a `yield` on the PTY output path. The consumer is also a `DispatchQueue`
  socket write under a `@MainActor` Elm runtime, not an async context.
- **Raw JSON Lines straight onto the socket**: simplest CLI, but the connection
  stops being JSON-RPC mid-stream, breaking any other client or future
  multiplexed request on that socket.
- **Repeated `pane tape` snapshots from the client**: re-serializes the whole
  ring every poll, cannot distinguish new events from old, and gives no gap
  signal -- this is the status quo the change exists to replace.
- **A separate streaming socket or transport**: a second listener, a second
  path convention, and a second auth story for a dev-only debugging surface.
- **Emitting the backlog as one bulk record**: reintroduces the 16 MiB line
  problem the per-event stream avoids, and makes the reader special-case its
  first line.

## Implementation discretion

- Pump cadence and mechanism, and the concurrency shape *within* the pump: the
  "one batch in flight" handshake may be an `await`ed write or a completion
  callback plus an in-flight flag. This is a code shape, not a design change --
  no channel or stream carries events out of the recorder either way (see
  Rejected ideas).
- Every name introduced by this change -- types, files, methods, subscription id
  format -- and where within each named module they sit. The module boundary in
  the Decision is load-bearing; the naming inside it is not.
- How the recorder serves a cursored snapshot cheaply, and how the exact gap
  byte count is carried.
- Whether the `end` reason set grows beyond `pane-closed`.

## Critical files

- `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalFlightRecorder.swift` --
  sequence assignment and cursored/`--from-now` snapshots. Do not change
  `encodedRecording()`.
- `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`
  (`#fencedFlightRecording`) and
  `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift`
  (`#flightRecordingSnapshot`) -- the fence to extend, and the reference-copy
  discipline to preserve.
- `lib/DanTermSupport/Sources/DanTermSupport/` -- the portable batch/lifecycle
  layer, beside `PaneTapeDumpPreparation.swift`; and `IpcConnection.swift`,
  whose `writeLine` currently swallows both flush completion and write failure.
- `lib/DanTermProtocol/` (method name, tape arg parsing, CLI output mode) and
  `lib/DanTermCore/` (`Update.swift`, `Command.swift`) -- `pane.tape` reads the
  follow params and emits a follow command, classified non-mutating beside
  `.dumpPaneTape`.
- `app/AppRuntime.swift` (subscription storage, pump, per-tick fence and write,
  `end` on pane loss), `app/IpcServer.swift` (close notification to the runtime),
  and the backend/session accessors beside `flightRecordingEncoder()`.
- `cli/main.swift` -- streaming request path: no `SO_RCVTIMEO` in follow mode,
  `SIGPIPE` ignored with a clean exit on `EPIPE`, unbuffered per-record stdout
  writes, exit on `end` or EOF; plus the usage text.
- `integrations/danterm/SKILL.md` -- the same four documented places the
  snapshot command occupies, plus a follow recipe.
- Reuse: `NeutralTerminalRecordingEvent` encoding, `encodeIpcLine`
  (`Envelope.swift`, already `withoutEscapingSlashes`),
  `preparePaneTapeDump`'s unsupported-backend contract, `fence(countsAsProduction: false)`.

## Verification

- `just test` -- protocol, core, DanTermSupport, PTY, and purity gates carry
  PO1-PO8. Targeted: `swift test --package-path lib/TerminalPTY`,
  `--package-path lib/DanTermSupport`, `--package-path lib/DanTermProtocol`,
  `--package-path lib/DanTermCore`.
- End to end: `just build-run`, then in a second shell
  `env DANTERM_SOCK=~/Library/Caches/com.danneu.danterm-dev/control.sock danterm pane tape --pane <id> --follow`.
  Type in the pane and drag-resize it; confirm lines appear as you act, not in
  a burst at the end.
- Backlog vs. tail: run once without `--from-now` (leading events describe
  history already on screen) and once with it (nothing until you type).
- Backlog responsiveness: fill a pane's recorder near its 8 MiB budget, then
  start a backlog follow while typing in another pane -- the UI must not stall
  while the backlog encodes.
- Gap: `--follow` a pane, suspend the reader (`kill -STOP` the `danterm`
  process), run something high-volume in the pane long enough to overrun the
  8 MiB ring, resume -- expect a `gap` record with non-zero counts and no
  duplicated sequence.
- Termination: close the followed pane -> `{"kind":"end","reason":"pane-closed"}`
  and the client exits 0. Quit the app while following -> the client sees EOF
  and exits 0 with no `end` record. Separately `^C` the client and confirm the
  app keeps running with no leaked subscription (a later `danterm ls` still
  responds promptly).
- Pipe behavior: `danterm pane tape --pane <id> --follow | head -3` exits
  cleanly.
- Regression: `danterm pane tape --pane <id> > /tmp/tape.json` still converts
  through `scripts/terminal-tape-to-fixture.py` unchanged.

## Commit progress

- [x] 1. feat(pty): sequence flight recordings and serve cursor snapshots
- [x] 2. feat(ipc): add the portable pane-tape follow layer and method
- [x] 3. feat(app): stream pane tape events to follow subscribers
- [x] 4. feat(cli): follow a pane tape as JSON Lines

## Implementation notes

- Cursor snapshots index retained nodes by lifetime sequence so an active tail
  copies only the returned suffix instead of rescanning the full recorder ring;
  the index remains bounded by the recorder's existing event limit.
