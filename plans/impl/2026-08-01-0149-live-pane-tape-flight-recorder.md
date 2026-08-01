# Always-on live-pane tape flight recorder with on-demand CLI dump

## Context

The live-pane tape (`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalTapeRecorder.swift`)
is opt-in at app launch via `DANTERM_TAPE_PATH`, so it can only capture
artifacts you predicted before launching. The OSC 133 investigation
(`docs/research/24-osc-133-dialect/`) showed that is the wrong default: all
seven F16/F17 defects were pinned only by live recordings, four came off a
single unrepeatable drag, and the tape was rebuilt three times in one day
before being kept (8b30380). The missing property is retroactive capture --
the recording must already exist when the artifact is noticed.

Desired outcome: every pane in the dev app records its full drive sequence
into a bounded in-memory buffer with no opt-in; after seeing an artifact,
`danterm pane tape > tape.json` produces a replayable recording in the
committed fixture schema.

Load-bearing premises, with evidence:

- Retaining feed chunks by reference is free of copies and CoW hazards: the
  read loop materializes a fresh `[UInt8]` per PTY chunk and never mutates it,
  and the same path already memcpys every chunk into `recentOutput`
  (`TerminalPTYHost.swift#applyOutput`). Recording cost is reference retention
  plus bookkeeping.
- The fixture decoder ignores unknown JSON keys, so per-event timestamps and
  top-level truncation metadata are additive
  (`lib/TerminalCore/Sources/TerminalCoreRecording/NeutralTerminalRecording.swift`).
- `TerminalPTY` already depends on `TerminalCoreRecording`, and pane sessions
  already accumulate `NeutralTerminalRecordingEvent` values
  (`TerminalPaneSession.swift#completedRecordingEvents`) -- the event type to
  buffer exists.
- IPC replies are single newline-delimited lines capped at 16 MiB
  (`IpcLineFramer.swift#maxLineBytes`). Base64 represents arbitrary feed bytes
  inside that JSON transport with 4/3 bulk expansion; unlike hex, its alphabet
  needs no JSON escaping.
- The neutral recording schema is internal to this repository, so a new
  `base64` feed field can be added alongside the existing `hex` one. Only the
  wire needs compactness, so new encoders emit `base64` while the decoder keeps
  accepting `hex`; the 999 committed `hex` events across 43 fixtures and the
  six independent producers/consumers (`terminal-viability.sh`,
  `terminal-characterization-driver.py`, `terminal_benchmark_fixtures.py`,
  `import-alacritty-recordings.py`, `terminal-tape-to-fixture.py`,
  `TerminalTapeRecorder.swift`) do not have to move for this feature.
- Replay validation and fixture admission are distinct gates today: `replay`
  calls `NeutralTerminalProvenance.validate`
  (`NeutralTerminalRecording.swift#replay`), while corpus sweeps apply their own
  stricter admission checks. A capture source can therefore be replay-valid and
  fixture-inadmissible at the same time.
- The gate that must reject raw captures is the `Fixtures/danterm` sweep
  (`TerminalSemanticPromptInvariantTests.swift#recordingCorpus`), not
  `TerminalFixtureTests.swift#validateProvenance` -- the latter runs only over
  `fixtureURLs()`, which lists `libvterm`, `alacritty`, and `windows-terminal`
  and never `danterm`. The DanTerm sweep currently *normalizes* any non-`danterm`
  provenance to `.danTerm(...)` before replaying, so without a change it would
  launder a raw capture rather than reject it.
- Prompt-artifact sessions measure in kilobytes (every F16-F18 fixture), so a
  budget of a few MiB covers the target bug class from pane birth.
- Standalone payoff, not a dependency: with
  `plans/impl/2026-08-01-0029-prompt-anchor-invariants.md` implemented, any
  tape converted into `Fixtures/danterm/` is automatically replayed through the
  universal snapshot-invariant oracle without test edits. That oracle proves the
  snapshot-provable prompt invariants; transition invariants and resize sweeps
  stay with their targeted tests.

## Decision

An always-on per-pane in-memory flight recorder, dev bundle only, dumped on
demand over the existing control socket.

- **Enablement**: recording is on for every pane when the app is the dev
  bundle (`com.danneu.danterm-dev`) and absent in production. Discrimination
  follows the injectable bundle-id precedent
  (`SocketPath.swift#controlSocketPath(bundleId:)`,
  `RecoveryStore.swift#recoveryDirectoryURL(bundleId:)`), threaded to the
  host as configuration so tests control it directly.
- **Dump surface**: new CLI command `danterm pane tape`, pane-addressed like
  `pane read`, writing one JSON document to stdout in the neutral fixture
  schema (`version: 1`, provenance, initial geometry, events) that
  `NeutralTerminalRecording` decodes unchanged. The JSON-RPC reply carries the
  recording as a JSON object, and the CLI writes that document directly -- not
  a quoted string containing it. No `--out` flag; shell redirection covers it.
  A pane on a backend with no recorder (Ghostty backend, production build) gets
  a clear JSON-RPC error, not empty output.
- **Provenance**: a raw dump carries its own capture source (distinct from the
  `danterm` fixture source) that `NeutralTerminalProvenance.validate` accepts,
  so raw tapes replay. Fixture admission rejects that capture source, so a raw
  tape dropped into `Fixtures/danterm` fails the corpus sweep instead of being
  replayed with machine identifiers still in it; only the converter's output,
  which rewrites the marker to the `danterm` fixture source, is admissible. The
  rejection belongs in the `Fixtures/danterm` sweep
  (`TerminalSemanticPromptInvariantTests.swift#recordingCorpus`) and must run
  *before* that sweep's legacy provenance normalization, which would otherwise
  overwrite the capture marker it needs to see. Replay-validity and
  fixture-admissibility are separate gates.
- **Format**: the tape remains JSON, with each feed event's arbitrary bytes in
  a `base64` string. `base64` is added alongside the existing `hex` field: new
  encoders and all live dumps emit `base64`, the decoder accepts either, and
  committed `hex` fixtures and their producers stay as they are. Events also
  carry a monotonic elapsed-time field; replay ignores it. Dump output is raw and unscrubbed; scrubbing and the
  refuse-on-leak backstop remain solely in
  `scripts/terminal-tape-to-fixture.py`, whose job shrinks to
  scrub-and-verify now that the schema is already fixture-shaped.
- **Budget**: 8 MiB accounted payload per pane plus an event-count cap,
  evicting oldest whole events first. Base64 expands bulk payload to about
  10.67 MiB, leaving over 5 MiB of the 16 MiB IPC line for the JSON-RPC
  envelope, event metadata, timestamps, and small-chunk padding. The
  event-count cap and per-event accounting must also bound the encoded cost of
  many tiny chunks; PO5 proves the chosen constants against the actual encoder.
  Accounting mirrors the `scrollbackBudgetBytes` pattern.
- **Coexistence**: the `DANTERM_TAPE_PATH` streaming recorder is unchanged in
  all builds -- it remains the crash-durable opt-in, since eager file writes
  survive an app killed mid-investigation and the in-memory buffer does not.
- The CLI surface change updates `integrations/danterm/SKILL.md` in the same
  change (repo rule; a command appears in its four documented places).

Decisive constraints:

- No encoding and no I/O on the pane output path; all serialization happens
  at dump time.
- A dump blocks the pane's serial queue only long enough to copy event
  references (the `fence` pattern); encoding runs off-actor.

## Invariants

- **I1 (retroactive capture)**: a dev-bundle pane retains its full drive
  sequence -- feed chunks at real PTY read boundaries plus resizes, in order
  -- from pane birth, with no opt-in, until the budget forces eviction.
- **I2 (fidelity)**: a dumped recording decodes with
  `NeutralTerminalRecording` and replays byte- and boundary-identically to
  what the pane's `Terminal` was fed; no event is merged, split, or
  reordered.
- **I3 (bounded memory)**: retained memory is bounded by the budget,
  accounting payload plus per-event overhead; eviction drops oldest whole
  events and releases their payload storage.
- **I4 (truncation honesty)**: a tape that has ever evicted is marked
  truncated with dropped event/byte counts, and the converter refuses to
  produce a fixture from it without an explicit override -- a truncated tape
  no longer starts at pane birth, so its replay is not trustworthy.
- **I5 (no accidental fixtures)**: a raw dump replays (its capture provenance
  is valid) but fails fixture admission until the converter processes it.
- **I6 (wire fit)**: every tape admitted by both buffer bounds, including the
  worst permitted small-chunk distribution, base64-encodes within a single IPC
  reply line.
- **I7 (production is clean)**: a production-bundle pane retains nothing.
- **I8 (timestamps are inert)**: per-event timestamps are monotonic, and
  their presence or absence is invisible to replay.

## Proof obligations

- **PO1 (I1, I2)**: a host-level test drives feeds and resizes, dumps,
  decodes the dump payload directly as a `NeutralTerminalRecording` document
  (not as a quoted string), and replays it: the resulting grid equals the
  directly-fed grid and chunk boundaries survive the round trip.
- **PO2 (I3)**: overshooting the budget evicts the minimal oldest prefix and
  the accounting includes per-event overhead (mirroring the
  `TerminalScrollbackBudgetTests` style, including a small-chunk case where
  overhead dominates payload).
- **PO3 (I4)**: eviction sets the truncation metadata; the converter's
  self-test refuses a truncated tape by default, and under the explicit
  override accepts it and carries its truncation metadata into the converted
  document.
- **PO4 (I5)**: a raw dump replays successfully, but a raw dump placed in
  `Fixtures/danterm` is refused by that directory's corpus sweep rather than
  normalized and replayed; the converter's output passes both gates.
- **PO5 (I6)**: tapes at the byte-budget and event-count boundaries, including
  one-byte feed chunks, produce complete JSON-RPC responses under the IPC line
  cap when encoded by the production encoder.
- **PO6 (I7)**: a production-configured host retains no events.
- **PO7**: CLI parse coverage for `pane tape` (usage errors, pane
  addressing) in the DanTermProtocol suite, plus the unsupported-backend
  error path.
- **PO7b**: an update-layer test (the `UpdateIpcTests` pattern already used for
  `Methods.paneRead`) proves the method resolves the addressed pane and emits
  the dump command for it, and errors on a missing or unknown pane.
- **PO8 (I8)**: a dump with timestamps replays identically to the same dump
  with timestamps stripped.
- **PO9**: the neutral recording codec round-trips arbitrary bytes through the
  `base64` field, rejects malformed base64, still decodes `hex` events, and
  decodes a recording mixing both fields; committed `hex` fixtures replay to
  their existing expectations unchanged.

## Non-goals

- A Debug-menu dump action (CLI only for now; menu can come later).
- Scrubbing in Swift -- one scrubber implementation, in the converter.
- A global cross-pane memory cap; the bound is per-pane.
- Flight recording in production builds.
- Timing-aware replay; timestamps are captured, not consumed.
- Sweeping raw local tapes in tests; tapes enter the test corpus only
  through conversion to committed fixtures.
- Migrating committed `hex` fixtures to `base64`; that churn buys nothing this
  feature needs.

## Accepted risks

- **AR1 (two feed encodings)**: the schema carries both `hex` and `base64`
  feed fields indefinitely. Accepted: the duality is decode-only -- no new
  producer emits `hex` -- and it is far cheaper than migrating 999 events
  across 43 fixtures and six independent producers for a feature that only
  needs compactness on the wire.

## Rejected ideas

- **Fixed-slot circular buffer**: byte-budgeted, variable-size events form a
  queue, not a slot ring; a ring adds capacity semantics the eviction rule
  cannot use.
- **Hex feed encoding for new dumps**: doubles binary payload size against a
  16 MiB line cap. Base64 preserves the same JSON workflow at 4/3 bulk
  expansion. (Existing `hex` fixtures are still decoded -- see AR1.)
- **CBOR or MessagePack tape**: the control socket is still JSON-RPC, so a
  binary document would need base64 wrapping on the wire or a second transport.
  That adds a codec and makes fixtures harder to inspect without avoiding the
  current IPC constraint.
- **Runtime start/stop toggle as the primary mechanism**: recording that
  starts after the artifact is seen defeats retroactive capture, which is
  the point.
- **`--out` flag**: the CLI writes raw stdout today and redirection covers
  the need; no file-writing precedent exists in the CLI.

## Implementation discretion

- Buffer structure and compaction strategy, the event-count cap value, and
  the per-event overhead constant -- provided I3 holds.
- How the dev-bundle flag travels from app to host configuration.

## Critical files

- `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift` and
  `TerminalTapeRecorder.swift` (or a sibling) -- buffer, budget, truncation
  metadata, fence-served snapshot.
- `lib/TerminalCore/Sources/TerminalCoreRecording/NeutralTerminalRecording.swift`
  -- add the `base64` feed field beside `hex` (encode `base64`, decode either),
  and add the capture provenance source that `validate` accepts. Committed
  fixtures are untouched.
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalSemanticPromptInvariantTests.swift`
  (`#recordingCorpus`) -- the `Fixtures/danterm` sweep must reject the capture
  source ahead of its existing provenance normalization.
- `lib/DanTermProtocol/Sources/DanTermProtocol/` -- `CLIParser.swift`,
  `Methods.swift`, a pane-tape args file following the `ReadPaneArgs.swift`
  pattern.
- `lib/DanTermCore/Sources/DanTermCore/Update.swift` and `Command.swift` --
  the new method resolves a pane and emits a command, following
  `Methods.paneRead`.
- `app/AppRuntime.swift`, `app/TerminalBackend.swift` (the `TerminalSession`
  protocol), `app/SwiftTerminalSessionView.swift`,
  `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift` --
  command execution down to the host fence and the JSON-RPC reply.
- `cli/main.swift` -- stdout rendering.
- `scripts/terminal-tape-to-fixture.py` -- accept fixture-schema input, rewrite
  the capture provenance marker to the `danterm` fixture source, refuse
  truncated tapes without the override, keep scrub-and-verify.
- `integrations/danterm/SKILL.md` -- the four documented places.
- Reuse: `NeutralTerminalRecordingEvent` / `TerminalCoreRecording` (already a
  `TerminalPTY` dependency), `TerminalPTYHost.swift#fence(countsAsProduction:)`,
  the bundle-id injection precedent named above.

## Verification

- `just test` -- protocol, core, PTY, and script gates; PO1-PO9 live inside
  targeted suites (`swift test --package-path lib/TerminalPTY`,
  `--package-path lib/DanTermCore`, `--package-path lib/DanTermProtocol`) plus
  the converter self-test.
- End to end: `just build-run`; generate output and drag-resizes in a pane;
  `env DANTERM_SOCK=~/Library/Caches/com.danneu.danterm-dev/control.sock
  danterm pane tape > /tmp/tape.json` (the dev-app socket caveat from the
  research README); convert with `scripts/terminal-tape-to-fixture.py`; drop
  the fixture into `Fixtures/danterm/` locally and watch the corpus sweep
  replay it.
- Production check: a production-configured build answers `pane tape` with
  the unsupported error and retains nothing.

## Commit progress

- [x] 1. feat(recording): add compact live-capture schema support
- [x] 2. feat(pty): retain bounded live-pane flight recordings
- [x] 3. feat(ipc): expose pane tape dumps through the CLI
- [ ] 4. feat(fixtures): convert and document live-pane tape captures

## Implementation notes

- Swift's default `JSONEncoder` escapes `/`, which can double slash-heavy base64
  payloads and violate the IPC bound. The shared IPC line encoder now disables
  slash escaping; PO5 covers the worst-case payload through that production path.
