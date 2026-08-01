# Plan: Unify terminal recording formats

## Target formats

- One feed-payload encoding across every terminal recording family.
- The *neutral* family has exactly two document shapes: complete snapshot JSON, and stream JSONL.
- Incremental capture: unwrapped `start` / `event` / `gap` / `end` JSON Lines, discriminated by `kind` (matching the shipped `pane tape --follow` wire). The inner neutral event keeps its own `type` discriminator.
- JSON-RPC envelopes remain socket-only and are never persisted.
- Feed payloads allow exactly:

```json
{"type":"feed","base64":"..."}
{"type":"feed","text":"..."}
```

- Automated and live producers always emit `base64`.
- Readable, authored `text` fixtures remain unchanged.
- No terminal recording format emits or accepts `hex`.

## Task list

### 1. Establish strict feed-event decoding

- [ ] Make `NeutralTerminalRecordingEvent` accept the two exact feed shapes: `type + base64` or `type + text`, plus `elapsedNanoseconds` as the only allowed inert metadata key -- no other metadata is accepted on any event.
- [ ] Validate event objects by their complete allowed key sets, so missing payloads, multiple payloads, and arbitrary unknown fields all fail generically.
- [ ] Remove `invalidHex`, `decodeHex`, hex coding branches, and hex-specific ambiguity handling.
- [ ] Keep malformed base64 as a distinct data error.
- [ ] Keep `text` on semantic events such as `paste`.
- [ ] Preserve fixture checkpoint payloads and other currently valid event-specific optional fields during strict validation.
- [ ] Leave top-level recording and provenance metadata extensible; strict unknown-field rejection applies to event objects.

### 2. Migrate committed recording data

- [ ] Convert 968 neutral `feed.hex` events across 41 fixture files to byte-equivalent base64.
- [ ] Leave the 283 existing `feed.text` events unchanged.
- [ ] Convert the Ghostty characterization recording's 3 hex feeds to base64.
- [ ] Convert the compressed terminal benchmark recording's 96 hex feeds to base64.
- [ ] Use a one-time migration utility that decodes the old value, writes base64, and asserts byte-for-byte equality before replacing each file.
- [ ] Do not retain the migration utility after the tracked data is converted.
- [ ] Do not migrate `utf8-decoder-corpus.json`: its `hex` property is a purpose-specific, human-readable malformed-byte corpus, not a terminal recording event representation.

### 3. Update every recording producer and consumer

- [ ] Make the Alacritty importer emit base64.
- [ ] Update the terminal viability replay helper to decode base64 or text.
- [ ] Update the Ghostty characterization driver and Swift replay decoder to use base64.
- [ ] Update benchmark recording loading and its tests to use base64.
- [ ] Swap `hex` for `base64` in the tracked research capture scripts, including their variant-rewriting round trip and byte-count/OSC-scan summaries. Convert both to emit the complete snapshot document (version, provenance, initial, events): the drag script currently writes the bare JSONL shape whose only other producer is being deleted, and the sweep script writes a bare `{initial, events}` object with no version or provenance, so neither survives task 5's fallback removal and provenance requirement. They drive their own PTY, so keep them on the snapshot format rather than fabricating stream wrappers they have no `sequence`, `gap`, or `end` for.
- [ ] Remove terminal-feed `fromhex`, `.hex()`, and manual `%02x` encoding from these paths.
- [ ] Preserve unrelated hexadecimal concepts such as colors, hashes, and the dedicated UTF-8 byte corpus.

### 4. Delete the legacy `DANTERM_TAPE_PATH` recorder

- [ ] Delete `TerminalTapeRecorder`, its `tape?.recordFeed` / `tape?.recordResize` call sites in `TerminalPTYHost`, the `DANTERM_TAPE_PATH` environment surface, and every configuration and documentation reference to it. It is a second hand-rolled `%02x` + interpolated-JSON producer of the events `TerminalFlightRecorder` already records with a sequence counter, elapsed clock, `.liveCapture()` provenance, and base64 encoding; two producers of one grammar is the drift.
- [ ] `TerminalFlightRecorder` remains the sole in-process recorder, and stays bounded and in-memory: no file handle, no path allocation, no sink lifecycle, no teardown writer. DanTerm performs no automatic tape file IO.
- [ ] Both capture surfaces are the shipped CLI, where the operator owns any file that gets written: `danterm pane tape --pane <id>` for after-the-fact inspection of a live pane, and `danterm pane tape --pane "$PANE_ID" --follow > tape.jsonl` for durable, crash-surviving evidence during a reproduction. Every dev pane already has the flight recorder on (`dev-build.sh` sets `DanTermRecordsFlightTape`), so no new activation surface is needed.
- [ ] Leave the stream-record constructors and their value types in `DanTermSupport`. With `TerminalTapeRecorder` gone there is one in-process producer of the wrapper grammar, so there is no drift for a move to prevent.
- [ ] Correct `TerminalFlightRecordingSnapshot.initial`'s doc comment: it claims "geometry that existed before the first retained transition", but the value is construction-time geometry and eviction never adjusts it. The stale claim is what would make a future reader treat a truncated capture's geometry as trustworthy.

### 5. Teach the fixture converter the new stream format

- [ ] Continue accepting complete `pane tape` snapshot documents.
- [ ] Accept unwrapped follow-stream JSONL, never raw JSON-RPC envelopes.
- [ ] Require one `start` record first, then `event` records whose `sequence` increases by exactly one, with an optional final `end`. A stream that just stops at EOF with no `end` record is valid and convertible: that is the crash case `--follow` redirection exists to capture, and the app manufactures no terminator on the way down. The first sequence is arbitrary, since a `--from-now` stream legitimately begins mid-history. Increasing-but-not-contiguous is not enough: a stream missing a whole line reads as 41 then 43, well-formed and ordered, and concatenates terminal states that never occurred -- the outcome an explicit `gap` is refused for.
- [ ] Validate the `start` record's provenance exactly as the snapshot path does (`source == danterm-live-capture`), so an already-scrubbed fixture cannot be re-scrubbed and re-stamped.
- [ ] Flatten each stream wrapper into a neutral recording event, carrying `elapsedNanoseconds` into the fixture event.
- [ ] Refuse any capture that dropped events, on both document shapes: a `gap` record anywhere in a stream, or `truncation` reporting dropped events in a snapshot. Delete `--allow-truncated`; there is no escape on either path. Dropped events mean the recorder evicted history the consumer never saw, and no surviving part can be trusted: the events on either side of an interior loss concatenate into a sequence that never occurred, and a leading loss may have swallowed a `resize`, leaving `initial` describing geometry that no longer applies. Both mint a fixture that replays cleanly against the wrong terminal.
- [ ] Preserve base64 feeds as base64 and readable text feeds as text after scrubbing.
- [ ] Remove the converter's hex branch and old bare-JSONL fallback.
- [ ] Reject malformed stream order, invalid event shapes, multiple starts, and records after `end`.

### 6. Add permanent schema enforcement

- [ ] Add a corpus audit over the feed-payload encoding only: every feed in every family carries exactly one of `base64` or `text`. The audit does not assume a shared event vocabulary across families.
- [ ] Ensure the audit covers neutral fixtures, Ghostty characterization data, and compressed benchmark recordings.
- [ ] Test arbitrary-byte base64 round trips and readable text round trips.
- [ ] Test generic rejection of missing, duplicate, and unknown event fields.
- [ ] Test snapshot-to-fixture and stream-to-fixture conversion.
- [ ] Test rejection of a leading `gap`, an interior `gap`, a truncated snapshot, a silent sequence jump, and malformed stream ordering. Update the existing truncation test to assert unconditional refusal.
- [ ] Test that a stream ending at EOF without an `end` record converts successfully, so the crash-evidence path cannot regress into refusal.
- [ ] Test that the converter rejects a well-formed `pane.tape.event` JSON-RPC notification, so transport envelopes can never be read as persisted stream records.
- [ ] Test the converter parser over one committed follow-stream sample, and that the shipped follow producer emits feed events in the neutral encoding. That sample is what binds the one producer to the one parser.
- [ ] Run all replay suites before and after migration to prove observable terminal results are unchanged.
- [ ] Run the full `just test` gate.

### 7. Update active documentation

- [ ] Document snapshot JSON as the complete replay artifact format.
- [ ] Document follow JSONL as the incremental capture format:

```sh
danterm pane tape --pane "$PANE_ID" --follow > tape.jsonl
```

- [ ] Document that the fixture converter accepts either format.
- [ ] Update `integrations/danterm/SKILL.md` and active research capture recipes. Any live `DANTERM_TAPE_PATH` recipe becomes either an after-the-fact snapshot or `--follow` redirection.
- [ ] Leave historical implementation plans and research narratives unchanged, including the OSC 133 write-up's account of capturing through `DANTERM_TAPE_PATH`; they accurately record what was done and why compatibility existed at that time.

## Non-goals and accepted risks

- Schema merge across recording families is out of scope. The Ghostty characterization corpus (`replay.events[]`, `initialColumns`, string checkpoints) and the compressed benchmark recording (`dimensions`, no version/provenance) keep their own schemas; only their feed encoding changes.
- Salvaging a capture that dropped events is out of scope on every path: an operator whose stream or snapshot lost events re-captures rather than converting a partial one. Accepted because dropped events can hide a `resize`, and a fixture that replays cleanly against the wrong geometry is worse than no fixture -- the corpus exists to be a faithful record.
- Automatic persistence of terminal evidence is out of scope. The flight recorder is bounded and dies with its pane, so an after-the-fact snapshot may be truncated or unavailable after a crash; an operator who needs durable evidence runs `pane tape --follow` and redirects stdout while reproducing. Accepted for simplicity, and because the alternative defaults every dev pane into unbounded disk growth, synchronous file IO on the PTY path, retention cleanup, and automatic persistence of verbatim output that can contain secrets. Retention policy and post-exit recovery are deferred until a demonstrated need justifies them.
- Recording stays a dev-build capability. Production ships `DanTermRecordsFlightTape = false` and its plist cannot be edited without breaking notarization, so an artifact seen only in production `DanTerm.app` must be reproduced in a dev build to be captured. Accepted rather than shipping a production recording surface, which would put capture of verbatim terminal output one flag away for every user.
- Strict unknown-field rejection now governs an on-disk crash-survival format and a live IPC stream, so a newer app adding one event field makes older tooling reject whole recordings instead of ignoring the field. Accepted: generic rejection is what makes a malformed or half-written tape fail loudly, and a lenient reader would silently drop the fields a future investigation depends on.

## Recommended delivery order

1. Add new stream conversion and base64 producer support while legacy decoding still keeps the tree green.
2. Mechanically migrate all tracked fixtures and recordings with byte-equivalence checks.
3. Delete `TerminalTapeRecorder` and the `DANTERM_TAPE_PATH` surface outright -- nothing replaces it -- and move the research scripts to base64.
4. Remove hex and bare-JSONL compatibility, add strict event validation and the permanent corpus audit.
5. Update documentation and run the complete gate.

## Commit progress

- [x] 1. Add stream fixture conversion and base64 producer support
- [ ] 2. Migrate committed recordings to base64
- [ ] 3. Remove the legacy tape recorder and update research producers
- [ ] 4. Enforce strict recording schemas and audit the corpus
- [ ] 5. Document the unified recording formats and run the full gate
