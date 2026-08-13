# Pane Tape JSONL Replay and Inspect Output

## Problem

`danterm pane tape` writes a complete snapshot as one minified JSON document.
A production-sized tape can therefore be one multi-megabyte line that editors
and agents cannot inspect effectively. `--follow` already uses JSON Lines, but
its version 1 stream is a separate output contract from the finite snapshot.
Base64 is appropriate for exact replay, but opaque during investigation.

The command needs one bounded, line-oriented recording format for finite and
followed captures, plus a readable view that does not weaken the exact replay
artifact.

## Decision

`pane tape` will emit version 2 JSON Lines for both finite and followed
captures. The default remains exact replay. `--format inspect` selects a
derived, agent-readable view:

```text
danterm pane tape --pane <pane-id> [--follow] [--from-now] [--format replay|inspect]
```

The record order is `start`, optional `gap`, zero or more `event` records, then
`end` when the producer can state a clean end. A finite dump fences one atomic
snapshot and ends with `reason: "snapshot-complete"`. A followed pane close
ends with `reason: "pane-closed"`, and a follow stream DanTerm cannot keep
going ends with `reason: "stream-failed"`; abrupt app exit may leave a follow
stream at EOF. Every start record declares `capture: "snapshot"` or `capture: "follow"`
and `format: "replay"` or `format: "inspect"`. The CLI changes only the format
field when deriving inspect output. This lets persisted-stream readers require
`snapshot-complete` for a finite capture while accepting EOF as the end of a
crash-surviving follow capture.

Replay records keep base64 and exact event boundaries. Inspect records replace
each feed or write payload with ordered structured spans. Maximal valid UTF-8
runs become `text` spans, C0 bytes and DEL become individually named `control`
spans, and other undecodable bytes become coalesced lowercase, space-separated
`hex` spans. Inspect does not interpret CSI, OSC, DCS, or other terminal
sequences. UTF-8 is classified within each recorded event, so a scalar split
across events remains split and appears as hex in each event.

Every event carries its lifetime sequence number. Feed and write events also
carry `byteOffset` and `byteLength`; offsets are zero-based and independent for
the feed and write directions. Start cursors and gaps carry enough independent
feed/write byte positions to locate retained bytes and report exact loss.

The app and JSON-RPC transport carry replay records only. The CLI transforms
one unwrapped replay record at a time for inspect output. The finite path uses
the same sequenced recorder snapshot and record construction as follow rather
than retaining an independent snapshot serializer.

The raw version 2 stream remains distinct from committed neutral fixtures.
`scripts/terminal-tape-to-fixture.py` validates complete replay streams and
flattens them into the existing version 1 neutral fixture document.

## Invariants

- Both formats preserve event order, boundaries, sequence numbers, timing,
  input-origin timing, geometry, truncation facts, direction, byte offsets, and
  byte lengths.
- Replay base64 round-trips every payload byte exactly.
- Inspect spans are unambiguous and account for every payload byte exactly;
  literal text that resembles a control label cannot be mistaken for one.
- A finite dump includes only events present at its fence, even if new output or
  pane closure occurs while records are being delivered.
- Each JSON-RPC transport line carries at most one tape record, and each CLI
  output line is that independently valid JSON record. No socket or stdout line
  contains the whole recording.
- A gap reports exact event, feed-byte, and write-byte loss since the requested
  cursor. A truncated finite dump still succeeds, while fixture conversion
  rejects it.
- Premature EOF is an error for a finite dump. EOF after a follow start remains
  a valid crash-surviving capture, and a closed stdout pipe remains a clean
  consumer termination.
- Encoding and socket delivery stay off the main actor and do not add unbounded
  recorder or transport storage.

## Proof Obligations

- Recorder tests prove independent feed/write offsets across interleaved byte,
  resize, and empty-payload events; eviction gaps; backlog origins; and
  `--from-now` origins.
- Stream tests prove finite fencing and termination, shared finite/follow record
  shapes with explicit capture modes, contiguous sequences across follow
  batches, exact timing metadata, independently parseable transport and stdout
  lines, and the distinct EOF contracts.
- Inspect tests prove ASCII, multibyte UTF-8, literal control-like text, every
  named control, DEL, invalid bytes, empty payloads, and a UTF-8 scalar split
  across two source events. Replay and inspect must retain identical non-payload
  metadata.
- Converter tests prove complete finite and followed replay streams produce the
  same neutral fixture behavior. They reject inspect streams, gaps, legacy
  snapshot JSON, legacy version 1 JSONL, malformed ordering, sequence or offset
  jumps, bad lengths, malformed base64, a snapshot capture without its required
  end, and records after end. They accept a follow capture that ends at EOF,
  `pane-closed`, or `stream-failed`: its events are exact replay evidence up to
  the point the stream stopped.
- The isolated live CLI test parses the default and inspect JSONL outputs and
  converts a complete replay capture. The implementation passes `just test` and
  `just test-cli`.

## Non-goals and Rejected Ideas

- Non-goal: interpret terminal control-sequence semantics in inspect output.
  Doing so would require a separate parser-level design.
- Non-goal: make inspect output replayable or acceptable fixture evidence.
- Rejected: hex byte arrays as the canonical representation. They are larger
  and less token-efficient than base64.
- Rejected: keep pretty-printed snapshot JSON alongside JSONL. One shared stream
  contract removes the structural mismatch.
- Rejected: preserve the old raw-capture formats. DanTerm's internal CLI does
  not require a compatibility flag or migration shim.

## Documentation

Update CLI help and `integrations/danterm/SKILL.md` with the new grammar,
replay and inspect examples, JSONL-oriented `jq -s` recipes, truncation and EOF
behavior, and the warning that raw tapes contain unscrubbed terminal traffic and
potentially unechoed input. Amend
`docs/design/2026-08-06-swift-terminal-engine.md` J12 to record stable lifetime
sequence and per-direction byte coordinates as part of the flight-tape
contract.

## Implementation Discretion

- Internal record-builder names and module placement are left to
  implementation, provided finite and follow output share one behavioral path.
- Span coalescing mechanics and internal UTF-8 validation machinery are left to
  implementation as long as the inspect invariants hold.

## Commit progress

- [x] 1. Give the pane recorder independent feed and write byte coordinates
- [x] 2. Emit version 2 pane-tape JSON Lines for finite and followed captures
      Non-green until slice 4: `scripts/tests/danterm-cli_test.sh` still asserts
      `jq -e '.events'` against the version 1 single-document output. `just test`
      stays green; only `just test-cli` fails. (In fact that script aborted even
      earlier, on a pre-existing break slice 4 had to repair before the tape
      assertion was reachable at all.)
- [x] 3. Add `pane tape --format inspect` with structured payload spans
- [x] 4. Convert version 2 replay streams into neutral fixtures

## Implementation notes

- The recorder keeps four flat `Int` byte coordinates (per-direction totals on
  the recorder, per-direction watermarks on each slot, and the two cursor
  fields) rather than one `DirectionalByteCounts` value that would make a
  cross-direction subtraction unrepresentable. The flat names are the names the
  version 2 records put on the wire, so one type would have to be unpacked at
  every serialization site. The gap subtraction is pinned instead by a test
  whose two cursor watermarks differ from each other and from the retained
  head's, so reading either coordinate from the other stream changes the answer.
- Eviction accumulates no loss totals at all. Loss is not a property of the
  recorder but of the distance between a reader's cursor and the retained head,
  so `cursorSnapshot` measures it there, from the head slot's own watermarks.
  (Commit 1 kept one combined counter for the finite snapshot serializer;
  commit 2 removed that serializer, and the counter with it.)
- The finite dump encodes and enqueues its start reply and all its trailing
  records from one utility-queue block, rather than writing the trailing records
  from the start reply's main-actor completion. A dump can carry the whole
  retained tape, so encoding it on the main actor would hitch the panes being
  drawn. Order survives because each write encodes inline and hands its bytes to
  the connection's own serial write queue.
- The app target now depends on `TerminalPTYHost` and names the recorder's value
  types directly. The alternative kept the app off that module by passing cursor
  coordinates through `TerminalPaneSession` one `Int` at a time, which is a
  workaround rather than a boundary: this view is the adapter between the
  recorder vocabulary and the portable stream vocabulary, so naming both sides
  is its job.
- The inspect span classifier decodes UTF-8 itself instead of asking Foundation.
  A string decoder is free to normalize what it reads, and Foundation's swallows
  a byte-order mark: `String(bytes: [0xEF, 0xBB, 0xBF], encoding: .utf8)` returns
  an empty string, so three real payload bytes disappeared and the spans stopped
  accounting for every byte. The explicit decoder was checked against a reference
  UTF-8 decoder over every one-, two-, and three-byte sequence, sampled four-byte
  sequences, and every truncated prefix.
- Slice 4 also repairs four pre-existing breaks in
  `scripts/tests/danterm-cli_test.sh`: it compared the handle's app pid to the
  launcher's pid (never equal, so the script aborted there and everything after
  it had been dead for a long time), a help grep expected a `todo` usage string
  the CLI no longer prints, teardown killed an already-exited launcher, and
  teardown never killed the app, so every failed run leaked one of the eight
  shared dev slots. Splitting those repairs into their own commit was tried and
  rejected: with the repairs alone the script reaches the old `jq -e '.events'`
  tape assertion, which slice 2 already invalidated, so a repair-only commit
  cannot be green at that point in history. The repairs and the new tape
  assertions are what make `just test-cli` pass, and neither half does alone.
- The inspect transform lives in `DanTermProtocol` rather than in `cli/`, even
  though only the CLI applies it. It is a pure record-to-record function, and
  putting it beside the stream vocabulary makes it testable in a fast package
  suite instead of only through a socket.
