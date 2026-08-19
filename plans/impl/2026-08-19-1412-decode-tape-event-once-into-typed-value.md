# MOBILE-3: decode each tape event once into a typed value

## Context

Audit finding MOBILE-3 (docs/scratch/2026-08-18-construction-audit.md, confirmed,
wave 1). Today, once per PTY chunk the Mac forwards, on the main actor:

- `PaneReplica.applyEvent` (ios/DanTermMobileKit/Sources/DanTermMobileKit/PaneReplica.swift:183-195)
  re-encodes the already-parsed `JSONValue` event back to `Data` with a fresh
  `JSONEncoder` (re-materializing the base64 feed payload), then re-decodes it
  with a fresh `JSONDecoder` into `NeutralTerminalRecordingEvent`.
- `MobileSessionModel.pinnedStatement` (MobileSessionModel.swift:483-498)
  re-parses the same tree by string subscript to answer "is this a resize and
  what does it say about pinnedness".

The audit's disease P5 names the end state: "carry a tape record as its typed
Encodable event so it is encoded exactly once, decode it once at the phone's
edge into that same typed value." This plan is the phone-edge half. The
producer half (WIRE-2) is separate and later; the constraint
here is only to not invent a second event spelling -- satisfied by carrying
`NeutralTerminalRecordingEvent` itself, decoded through its one existing
`Codable` conformance.

Outcome: past the decode point in `MobileSessionModel.receive`, no JSON tree
survives and no consumer can parse the event a second time. This also unblocks
IOS-1 (replica reports pinnedness), which is only expressible once a typed
event exists.

## Decision

- **D1 -- a `JSONValue`-backed `Decoder` bridge in `DanTermProtocol`.** A
  generic adapter (new file beside JSONValue.swift) that decodes any
  `Decodable` directly from a parsed `JSONValue` tree, with no serialization
  to `Data`. No such bridge exists today; every site round-trips through
  `JSONEncoder`/`JSONDecoder`. The bridge is what makes "decode once" literally
  true -- without it the round trip is merely relocated, and the feed payload
  (the most common record kind) is still base64-encoded and re-parsed per
  record. It reuses the event's single Codable spelling rather than
  hand-writing a second `JSONValue` decoder that can drift from the wire
  format. It is durable, not scaffolding: `DanTermProtocol` stays engine-free
  by design, so the phone-edge lift from `JSONValue` survives the later
  producer-side fix. Its obligation is not a hand-listed set of operations: it
  must support **every `Decoder` operation the event corpus of PO-I2 reaches
  transitively**. `NeutralTerminalRecordingEvent.init(from:)` already reaches
  past keyed containers -- two keyed containers with different key types on one
  decoder, `allKeys`, `contains`, `decodeIfPresent`, and an unkeyed container
  with `String` elements for the `modifiers` array on input and mouse events --
  and the corpus, not this sentence, is what pins the set.
- **D2 -- parameterize the record by its event payload.** `PaneTapeRecord` and
  `PaneTapeEventRecord` gain one generic parameter for the event payload, with
  conditional `Equatable, Sendable`. They live in `DanTermProtocol`
  (`PaneTapeRecord.swift`), which now publishes the typed record family for
  both sides of the wire, so D1 and D2 land in the same module beside
  `JSONValue`. `decodePaneTapeRecord` keeps returning the `JSONValue`
  specialization, and a mapping operation on the record replaces only the event
  payload, leaving every other case untouched. The phone specializes on
  `NeutralTerminalRecordingEvent`. `DanTermProtocol` must name no engine type
  -- every layer depends on it and the portability lint covers it -- and a type
  parameter names none, so that boundary is preserved by construction rather
  than by a second enum kept in sync by hand. There is exactly one record shape
  in the tree, so the later producer work (WIRE-2) has one shape to reconcile
  rather than two. Existing use sites keep the `JSONValue` behavior they have
  today; the compiler names the ones that must spell the specialization out.
- **D3 -- one decode point.** Both branches of `MobileSessionModel.receive`
  map the decoded `JSONValue`-specialized record into the typed-event
  specialization via the bridge. Everything downstream --
  `MobileSessionEffect.applyRecord`, `MobileSessionEvent.recordApplied`,
  `PaneReplica.apply`/`applyEvent`, `MobileSessionController`'s applyRecord
  arm, `TerminalSurfaceView.apply`, `pinnedStatement` -- carries or switches on
  the typed specialization. The encode/decode round trip in `applyEvent` is
  deleted; `pinnedStatement` matches the typed `.resize` case.
- **D4 -- refusal moves to the decode edge and stays strict.** An event record
  whose inner event does not decode ends the connection, now decided in the
  pure model at `receive` instead of replica-throw -> controller-catch.
  Unknown event types and unknown keys still refuse (a future recorder event
  kind still ends the phone's connection -- preserving today's behavior, per
  the audit's blocker 2). `PaneReplicaError.invalidEvent` is deleted;
  `.replicaRejectedRecord` remains, raised only by `PaneReplica`'s surviving
  throws (invalid geometry on start/sync records).

## Invariants

- **I1** Past `MobileSessionModel.receive`, no tape-event JSON exists: the
  record the model emits carries the typed event, so a second parse is
  unrepresentable.
- **I2** The typed lift accepts exactly what today's round trip accepts and
  refuses exactly what it refuses: bridge-decode from a `JSONValue` agrees
  with encode-to-Data-then-`JSONDecoder` on both value and success/failure --
  including at every primitive conversion boundary, not only at the event's
  own key-shape checks.
- **I3** A tape event the engine cannot decode still ends the connection; only
  the location of the refusal moves (to the decode edge), not the outcome.
- **I4** A resize event with no `pinned` key still reads as unpinned
  (pre-pinnedness recordings) -- now stated once, by the Codable init's
  `decodeIfPresent ?? false`, instead of twice.
- **I5** Replica semantics are unchanged: gap detection, cursor advance,
  sync assembly, and checkpoint behavior as currently pinned by
  `PaneReplicaTests` and `PaneReplicaCheckpointTests` -- their assertions pass
  verbatim; only their private event-construction helpers change (both
  currently build the `JSONValue` by round-tripping the typed event; they
  become direct typed construction).
- **I6** New code in `DanTermProtocol` and `DanTermMobileKit` stays portable
  (`scripts/core-purity-lint.sh --profile portable` covers the kit).

## Proof obligations

- **PO-I2** A differential corpus of event `JSONValue`s, decoded both ways --
  bridge, and today's encode-to-`Data`-then-`JSONDecoder` -- asserting the two
  agree on the decoded value and on refusal. The corpus covers, at minimum:
  - every event kind the recorder emits, in its valid spelling;
  - the malformed key shapes today's decoder refuses: unknown `type`, missing
    required key, extra key, and the feed/write encoding choice (`base64` and
    `text` both present, neither present, undecodable base64);
  - every primitive path the event decoder reaches, at its conversion
    boundaries: `Int` and `UInt64` from a fractional number, from a negative
    number, and from a number outside the type's range; a number where a
    string, bool, or array is expected and the reverse; `null` against both a
    required key and a `decodeIfPresent` key (absence and `null` must not
    become the same answer unless they are the same answer today);
  - the container paths: the `modifiers` array of strings on input and mouse
    events, empty and populated, and an array whose element is the wrong type.

  Plus bridge-level tests in `DanTermProtocolTests` on representative
  `Decodable` fixtures against `JSONDecoder` over the equivalent bytes.
- **PO-I3** Write first (fails on today's tree, survives the refactor
  untouched): in `MobileSessionModelTests`, deliver a tape-event notification
  whose `record.event` is well-formed JSON but not a decodable recording event
  (e.g. `{"type":"feed"}` with no `base64` key); assert the effects contain no
  `.applyRecord` and the session ends the way `.replicaRejectedRecord` does
  today. Today `receive` never looks inside `event`, so both assertions fail
  for the right reason. This is also the first test the refusal has ever had
  (the audit corrected itself: no existing test pins `invalidEvent`).
- **PO-I4** A new raw-frame model test: deliver a tape-event notification whose
  resize event object omits `pinned` entirely, and assert the resulting
  pinnedness claim is the unpinned one. The existing helpers all write the key
  (`tapeResizeNotification` takes `pinned` and always emits it), so no existing
  test crosses the new decode edge without it. The existing resize-with-pinned
  replica test and the existing `MobileSessionModelTests` claim-lifecycle tests
  stay as the with-key half of the pair.
- **PO-I5** `PaneReplicaTests`, `PaneReplicaCheckpointTests`,
  `MobileSessionModelTests`, and the two suites that pin the record decode --
  `PaneTapeRecordTests` in `DanTermProtocolTests` and the producer-to-reader
  `DanTermPaneTapeRoundTripTests` (`client-tests/`) -- pass with assertions
  unchanged. The round-trip suite already decodes every event kind the producer
  emits, so it is the natural place to source PO-I2's valid-spelling corpus
  from rather than restate it.

## Non-goals

- WIRE-2 (producer-side typed event) -- separate, later; no `Encoder`
  counterpart bridge now. PERSIST-6, which published the typed record family
  from `DanTermProtocol`, has landed; this plan builds on it.
- MOBILE-4 (signal replica state only on transitions) -- separate follow-up
  commit; orthogonal concern with its own regression risk.
- IOS-1 (replica reports pinnedness) -- enabled by this change, done after.
- Any *semantic* change to the decode: `decodePaneTapeRecord` still returns
  the `JSONValue` specialization and still names no engine type. The generic
  parameter of D2 is the only change to the record family.

## Accepted risks

- **AR1** `JSONValue` stores numbers as `Double`, so integers above 2^53 lose
  precision in the bridge -- exactly as they do today, because the tree was
  parsed into `JSONValue` before either path runs. The equivalence bar (I2) is
  today's round trip, not `JSONDecoder` over raw wire bytes.

## Implementation discretion

- Names of the bridge type, the generic parameter, the mapping operation, and
  the `JSONValue` typealias; whether the lift is an initializer or a free
  function; the end-failure detail string.

## Critical files

- `lib/DanTermProtocol/Sources/DanTermProtocol/` -- new bridge file (D1);
  `PaneTapeRecord.swift` for the generic parameter and mapping operation (D2);
  tests in `lib/DanTermProtocol/Tests/DanTermProtocolTests/`.
- `ios/DanTermMobileKit/Sources/DanTermMobileKit/` --
  `MobileSessionModel.swift` (`receive`, `pinnedStatement`,
  `noteRecordPinnedness`, `recordApplied` arm); `MobileSessionEffect.swift`;
  `MobileSessionEvent.swift`; `PaneReplica.swift` (`apply`, `applyEvent`,
  `advancedCursor`, error enum).
- `ios/DanTermMobileApp/Sources/DanTermMobileApp/` --
  `MobileSessionController.swift` (applyRecord arm),
  `TerminalSurfaceView.swift` (`apply`).
- `ios/DanTermMobileKit/Tests/DanTermMobileKitTests/` -- new PO-I2, PO-I3, and
  PO-I4 tests; `eventRecord(...)` helper in `PaneReplicaTests.swift:545` and
  `checkpointEvent(...)` in `PaneReplicaCheckpointTests.swift:481` become
  direct typed construction.

## Verification

TDD order: PO-I3's model test first (verify it fails for the stated reason),
bridge + its differential corpus next, then the generic parameter and the
sweep, then PO-I4.

- `swift test --package-path lib/DanTermProtocol`
- `swift test --filter DanTermPaneTapeRoundTripTests` (root package;
  assertions unchanged)
- `swift test --package-path ios/DanTermMobileKit`
- `just test` -- the full gate, including the purity lint (I6).

## Implementation notes

- PO-I2's valid-spelling corpus is written out in the new
  `TapeEventBridgeTests` rather than sourced from `DanTermPaneTapeRoundTripTests`
  as the plan suggested. That suite lives in the root package, which the
  `ios/DanTermMobileKit` package cannot import, and its event payloads are
  opaque JSON stand-ins (`{"feed":"aGk="}`) rather than typed recorder events --
  so there was nothing shareable to source. The corpus is stated as
  `NeutralTerminalRecordingEvent` values and encoded through the producer's own
  `encode(to:)`, so it is still the producer's spelling rather than a paraphrase
  of the wire format.
- The bridge decides every integer conversion with `FixedWidthInteger(exactly:)`
  over the number `JSONValue` already parsed, and every other conversion by the
  case of the `JSONValue`. Nothing about that choice is asserted by reading it;
  the two differential suites are what pin it against `JSONDecoder`.
- `PaneReplica.applyEvent` no longer throws at all once the decode leaves it, and
  `advancedCursor` lost its separate `event` argument because the record it
  already takes now carries the typed event. `PaneReplica.swift` also lost its
  `Foundation` import, which only the deleted round trip needed.
- The end-failure detail for an unreadable event is "Stream carried an
  unreadable event", beside the existing "Replica rejected the stream".
