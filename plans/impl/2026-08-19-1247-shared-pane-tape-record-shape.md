# Publish the pane-tape record shape once in DanTermProtocol

PERSIST-6 from `docs/scratch/2026-08-18-construction-audit.md`; that entry's
starter kit (change-site list, test inventory) is implementation reference,
this plan is the contract.

## Problem

The pane-tape record shape is spelled by hand on both sides of the wire.
Producers build `[String: JSONValue]` with literal keys in
`lib/DanTermSupport/Sources/DanTermSupport/PaneTapeRecords.swift` (start,
exact gap, event, end) and `PaneTapeStreamState.swift` (total gap, chunked
sync); the reader re-spells every key in
`lib/DanTermClient/Sources/DanTermClient/PaneTapeRecordReader.swift`; and
`lib/DanTermProtocol/Sources/DanTermProtocol/PaneTapeInspect.swift` switches
on the same literals a third time. A renamed or newly optional key compiles
clean everywhere and fails only at runtime, mid-stream. The stream's shared
vocabulary (version, format, capture modes, end reasons, cursor codec)
already lives in DanTermProtocol; the record shape is the part that escaped.

Verified against the tree on 2026-08-19: no shared type or key declaration
exists, and the audit entry's file inventory is accurate.

## Decision

Move the typed record family -- `PaneTapeRecord`, its payload structs,
`decodePaneTapeRecord`, and the numeric-domain validators -- from
DanTermClient into DanTermProtocol, and define the matching encode beside it.
Every record key spelling is declared exactly once there, and the encode, the
decode, and `paneTapeInspectRecord` all read that one declaration.

Producers construct the typed record and encode it at the existing `make...`
boundaries; the encode result stays `JSONValue`, so `PaneTapeBatch`,
`writePaneTapeRecords`, and the notification path are untouched.

The decode stays hand-written over `JSONValue`. Its leniency and validation
are behavior -- an unknown record kind decodes as `.unknown`, an unknown
capture mode is malformed, numeric fields are domain-checked -- and the
client keeps receiving the record as arrived bytes so a replay consumer
forwards what arrived. The by-construction win this plan claims is therefore
one declaration of the spellings and one type family, not "one encode and
one decode".

Consumers -- the CLI, `ios/DanTermMobileKit`, `ios/DanTermMobileApp` -- use
the moved types from DanTermProtocol; all already import it.

## Invariants

- I1 **Wire identity.** Every record kind encodes to exactly the JSON object
  the current literals produce, including the omissions: an absent origin
  stamp, an absent byte span, a withheld start cursor, and the sync record's
  first-part-only and last-part-only fields. The decode-only states --
  `.unknown(kind:)`, which has already discarded every field but the kind,
  and an end whose reason this build could not name -- are outside the
  encoder's accepted domain: it refuses them rather than emitting a lossy
  object. Making them unencodable by construction is the ideal form of that
  refusal.
- I2 **Decode compatibility.** The decoder accepts exactly the inputs it
  accepts today and rejects exactly what it rejects today; its asymmetric
  leniency (unknown kind fine, unknown capture malformed, numeric domains
  validated) is preserved.
- I3 **Single spelling.** Each record key is declared once, in
  DanTermProtocol, and every reader and writer of that key -- encode, decode,
  inspect -- goes through the declaration.
- I4 **Whole shape.** The typed start record carries every field the producer
  writes, provenance included; decoding does not become stricter to achieve
  that.
- I5 **Layering.** No new dependency edges; DanTermProtocol stays
  iOS-portable.

## Proof obligations

- PO1 (I1, characterization first): before anything moves, fill the two
  round-trip holes in `client-tests/PaneTapeRoundTripTests.swift` on the
  current tree -- the total-gap record, and a start record with a withheld
  cursor -- and watch them pass. After the move the whole suite passes
  verbatim; it is the only target linking producer and reader.
- PO2 (I1): the literal-JSON assertions in
  `lib/DanTermSupport/Tests/DanTermSupportTests/PaneTapeFollowTests.swift`
  and `PaneTapeStreamStateTests.swift` pass unchanged -- they pin the
  external contract, which `integrations/danterm/SKILL.md` documents and
  which must not move by a byte.
- PO3 (I2): the reader suite (unknown kind, unknown capture, numeric
  domains, total-vs-exact gap, withheld cursor) passes against the moved
  decoder; the suite moves with the decoder into DanTermProtocol's tests.
- PO4 (I3): `PaneTapeInspectTests` pass unchanged, including the
  whole-object pass-through for records the transform cannot derive from.
- PO5 (I5): `just test`, `swift test --package-path ios/DanTermMobileKit`,
  and `scripts/ios-portability-gate.sh` all green;
  `cli-tests/PaneTapeStreamTests.swift` unchanged.
- PO6 (I4, and I2 as its guard): the start round-trip asserts that an
  arbitrary provenance value the producer stamps arrives in the decoded typed
  start record, and a sibling case asserts that an otherwise valid start
  record carrying no provenance still decodes. The pair pins both halves at
  once: today's decoder drops provenance entirely, so the first case fails
  until the typed record carries it, and the second stops the fix from
  turning provenance into a required key the current decoder accepts
  without.

## Non-goals

- `PaneTapeBatch.records` stays `[JSONValue]`; `writePaneTapeRecords` and
  `IpcConnection.writeNotification` are out of scope (WIRE-2/WIRE-3
  territory, sequenced after this).
- The recorded event's inner encoding (`event.base64` and the inspect spans)
  is the engine's event vocabulary, not the record shape; its keys are not
  part of the shared declaration.

## Rejected ideas

- RI1 **Codable end-to-end now** (the audit's "sharper ideal"): a Codable
  encode reaches `PaneTapeBatch`, `writePaneTapeRecords`, and
  `IpcConnection.writeNotification` -- WIRE-2's large scope -- and would put
  the wire format at stake in one big change. Encoding to `JSONValue` now and
  rewriting under WIRE-2 later writes the encode twice; that is the accepted
  cost.
- RI2 **Shared key enum without moving the type** (the audit's cheaper
  fallback): kills typo drift but leaves two type families free to disagree
  about which fields are optional.

## Implementation discretion

- How the producer-side values (`PaneTapeEvent` with its non-wire
  `needsCompleteHistory`, DanTermSupport's `PaneTapeStateSynchronization`,
  `PaneTapeDimensions`) map onto the shared payload structs, and where sync
  chunking mechanics sit, provided chunk-size policy stays producer-side.
- Test-target relocation mechanics and module-qualification cleanup in
  `client-tests/PaneTapeRoundTripTests.swift` (the two modules currently
  collide on `PaneTapeStateSynchronization`).

## Commit progress
- [x] 1. test(tape): pin the total-gap and withheld-cursor records end to end
- [x] 2. refactor(tape): publish the typed record family from DanTermProtocol
- [x] 3. refactor(tape): encode pane-tape records from the shared declaration

## Implementation notes

- Commit 2 moved the record family, its decode, and the numeric validators into
  `lib/DanTermProtocol/Sources/DanTermProtocol/PaneTapeRecord.swift`, and left
  `PaneTapeStateSynchronization` and `PaneTapeSyncAssembler` in DanTermClient:
  assembling a multi-part transfer is a reader's job, not part of the record
  shape. The two modules therefore still collide on the synchronization name in
  `client-tests/PaneTapeRoundTripTests.swift`, and that file keeps its module
  qualification.
- `PaneTapeRecordKey`, `PaneTapeRecordKind`, and `PaneTapeLoss` are public
  although only the decode and the inspect view read them in commit 2. The
  producer's encode is the third reader, and it lands in commit 3.
- The start record's `provenance` is decoded as an optional `JSONValue`, and its
  initializer defaults it to nil so a test that builds a start record by hand
  states only the fields it cares about.
- I1's refusal is a separate enum, `PaneTapeOutgoingRecord`: the read family
  minus `.unknown` and minus an end whose reason this build cannot name, with
  `end` carrying a non-optional reason. The encode takes only that enum, so the
  two lossy states cannot be handed to it at all -- no runtime check, and no
  encoder branch that has to decide what to emit for them.
- The sync record's four first-part-only fields stay four independent optionals
  on `PaneTapeSyncRecord`, matching the decode. The encoder emits the geometry
  object only when columns, rows, and pinned are all present. Grouping them into
  one optional struct would make the together-or-nothing rule structural, but it
  changes the decoded type every reader already consumes, which is wider than
  this entry's slice.

## Follow Up

- ~~`PaneTapeSyncRecord` in
  `lib/DanTermProtocol/Sources/DanTermProtocol/PaneTapeRecord.swift` holds its
  four first-part-only fields (`columns`, `rows`, `pinned`,
  `droppedHistoryRows`) as independent optionals, so both the decode and the
  encode enforce "all four or none" by hand. Folding them into one optional
  struct would make the rule structural; it touches every reader of the decoded
  sync record (`PaneTapeSyncAssembler`, the CLI, `ios/DanTermMobileKit`).~~
  Done: the four fields are now one optional `PaneTapeSyncRecord.Transfer`, so
  the encode emits them together and the assembler reads one value. The decode
  still names the rule once, where it turns four independently malformed wire
  fields into that value or a rejection.
