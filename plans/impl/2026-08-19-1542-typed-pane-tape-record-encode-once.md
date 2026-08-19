# WIRE-2: Carry a tape record as its typed event, encode once at the wire

## Context

WIRE-2 in `docs/scratch/2026-08-18-construction-audit.md`. Every recorded
terminal event on the pane-tape stream is JSON-encoded, decoded back into a
`JSONValue` tree (`app/SwiftTerminalSessionView.swift#paneTapeFollowEventJSON`),
carried through the stream policy as that tree, wrapped in a second tree by
`PaneTapeRecord.swift#encodePaneTapeRecord`, and encoded a third time by
`encodeIpcLine`. Three JSON passes and about four base64 materializations per
recorded event (one PTY read chunk each), paid whenever a tape dump, follow,
or replica stream is open. The tree can also disagree with the typed event it
was built from, and record construction carries a `try` that has no real
failure.

The prerequisite (PERSIST-6, the shared record declaration in DanTermProtocol)
and the consumer-side twin (MOBILE-3, decode-once on the phone) have both
landed. This plan is the producer-side mirror. WIRE-3, WIRE-6, PERSIST-5, and
RUNTIME-6 build on the record shape this plan settles.

Load-bearing premises, verified at HEAD:

- The read family `PaneTapeRecord<Event>` / `PaneTapeEventRecord<Event>` is
  already generic with conditional `Equatable`/`Sendable` and `mapEvent`.
- `NeutralTerminalRecordingEvent` is `Equatable, Sendable, Codable` with a
  hand-written coding that is the wire event dialect readers depend on.
- `IpcConnection.writeLine` is already generic over `Encodable`;
  `encodeIpcLine` is the single place JSON text is produced.
- The support layer never reads inside the event tree; the follow registry
  stores no events; AppRuntime stores no record-bearing values.
- No test pins wire bytes literally; the wire contract is semantic (the repo
  states this in `cli-tests/PaneTapeStreamTests.swift`).
- The `DANTERM_UI_TEST` build compiles `TerminalSession.swift` and the three
  pane-tape support files without `TerminalCoreRecording`, so the engine event
  type does not exist there while `JSONValue` does.

## Decision

Records become typed values generic over the event payload, flowing typed from
the session adapter through DanTermSupport stream policy into
`IpcConnection.writeLine`; `encodeIpcLine` performs the only JSON encode. The
JSONValue-tree record build (`encodePaneTapeRecord`) is replaced by an
`Encodable` conformance on the generic outgoing record family in
`PaneTapeRecord.swift`, spelled through the existing `PaneTapeRecordKey`
constants and paired with the untouched `decodePaneTapeRecord`. The recorded
event encodes through its own `Codable` conformance inline.

Decisive constraints:

- DanTermSupport keeps importing only DanTermProtocol. The event payload
  crosses it as a type parameter with conditional
  `Equatable`/`Sendable`/`Encodable` conformances -- never as an `any
  Encodable` existential, which would destroy the conformances the stream
  types and their tests rely on.
- Event-free records are built and held as their own typed values -- start,
  gap, and sync as the existing concrete protocol structs, end as its
  `PaneTapeEndReason` (there is no end-record struct, and `PaneTapeFollowEnd`
  carries the reason rather than a record). `PaneTapeStart` holds a typed
  `PaneTapeStartRecord` instead of a `JSONValue`, and the synchronization
  requirement's loss becomes a typed gap record. Reaching the wire is where
  they join the generic enum: an event-free record encodes through the same
  outgoing enum with an arbitrary event binding -- `JSONValue` is available
  everywhere a write happens -- so I2's single encode declaration holds on the
  RPC-result seam too, and no second spelling of `kind`/`version`/`initial`
  appears.
- `TerminalSession` stays a non-generic protocol usable as an existential,
  and no associated type. Its tape requirements name a concrete event payload
  per build; how that is arranged is D2.
- The JSON-RPC envelope keys keep one declaration: the envelope structs
  become generic over their payload, with the `JSONValue` instantiations kept
  under the existing names so decode sites do not move. The start record
  still travels typed through the RPC result seam; the follow registry stays
  non-generic (only its batch-returning method binds the parameter per call).
- The wire is semantically identical, so `paneTapeStreamVersion`, the IPC
  protocol version, every reader (CLI, iOS lift, `PaneTapeInspect`,
  `PaneTapeRecordReader`), and `integrations/danterm/SKILL.md` are untouched.

## Invariants

- I1. A pane-tape record is JSON-encoded exactly once, by `encodeIpcLine`, on
  every path it reaches the wire -- notification params and RPC result alike.
- I2. The record shape has exactly one encode declaration and one decode
  declaration, both in `PaneTapeRecord.swift`, both spelled through
  `PaneTapeRecordKey`.
- I3. The `event` value inside an event record is exactly the engine event's
  own `Codable` encoding -- same keys, same base64, `.checkpoint` still
  spelled `"expect"`. There is no second spelling of the event dialect
  anywhere in the producer.
- I4. Wire compatibility is semantic: each record kind emits the same keys
  and values as before, with absent fields omitted rather than null; a
  `pane.tape.event` notification's params still carry `subscription` and
  `record`; the start record still arrives as the originating request's
  result and still decodes as `.start`; one framed line per record, each
  within the framer bound.
- I5. The per-event record path cannot fail: constructing a record from a
  recorded event is non-throwing, and the follow-batch closure drops
  `throws`.
- I6. DanTermSupport compiles and its tests pass standalone with the event
  parameter instantiated as `JSONValue`; it gains no engine import.
- I7. The UI-test build keeps compiling without the engine event type.

## Proof obligations

- PO1 (I1, I2, I4): the encode/decode drift pin. For every record kind --
  start with and without cursor and provenance, exact and total gap, event
  across the optional-field combinations, multi-part sync with transfer
  facts, every end reason -- encoding through the real wire path and decoding
  with `decodePaneTapeRecord` yields the expected read record.
  `client-tests/PaneTapeRoundTripTests.swift` is the designated home; its
  existing cases migrate to this form.
- PO2 (I3): the event-dialect golden. A record built from real
  `NeutralTerminalRecordingEvent`s (including feed with non-ASCII bytes and
  `.checkpoint`) carries an `event` value equal to the event's own
  `JSONEncoder` encoding. `app-tests/PaneTapeFollowEncodingTests.swift`
  retargets to this.
- PO3 (I4): the envelope pin. A typed-params request line and a typed-result
  response line decode as the `JSONValue`-instantiated envelopes with equal
  fields.
- PO4 (I4): the sync chunk-bound tests keep encoding real notification lines
  through the typed path and asserting they fit the framer bound; the
  empty-payload synchronization still ships one part.
- PO5 (I5): compiles-as-proof -- the deleted `try`s and the non-throwing
  follow-batch closure are type-level facts; the migrated stream-policy
  suites keep their behavioral assertions passing.
- PO6 (I6): the existing gate step `swift test --package-path
  lib/DanTermSupport` stays green with tests instantiating `JSONValue`.
- PO7 (I7): `just test-ui` passes (outside the gate; run explicitly).
- PO8 (I4): existing `cli-tests/PaneTapeStreamTests` stay green. They pin the
  CLI renderer's behavior against hand-written record bytes, not the
  producer's encode, so they are a reader-side regression guard only.
- PO9 (I1, I4): the RPC-result seam. A real `pane.tape` dump driven over the
  runtime's socket puts a decodable start record at `result` and event records
  at `params.record`, read as real socket bytes. `app-tests` is the home; the
  harness exists (`AppRuntimeCommandTestSupport` injects a `tapeOpening` and
  the suite already reads real response lines).

## Non-goals

- WIRE-3 (encode on the write queue; one notification per batch), WIRE-6
  (sync base64 copies), PERSIST-5, RUNTIME-6. The settled shape must not
  block them: after this change one typed record is the unit `writeLine`
  receives, which is exactly what WIRE-3 batches.
- No CLI surface, reader, or wire-version change.

## Accepted risks

- AR1. The once-per-stream provenance lift (`NeutralTerminalProvenance` ->
  `JSONValue` via a Data round trip) stays, and with it the `throws` on the
  opening closure. The full ideal is an Encodable-to-JSONValue encoder dual
  of the existing `JSONValueDecoder`; it buys nothing per-event and is left
  to any future work that wants provenance typed. Hand-building the
  provenance object would fork its key vocabulary and is worse.
- AR2. An encode failure now surfaces as a dropped line on the write path
  instead of a request error at record construction. For the real event
  vocabulary the failure is unreachable -- which is the point of I5.
- AR4. On the follow path, per-event JSON encoding (including the base64 of
  feed bytes) moves from the utility queue onto the main actor: today
  `prepareBatch()` builds the tree with its base64 strings off-main and only
  the final serialization runs on main. Total encode work drops, but
  main-actor work plausibly rises on a busy pane. WIRE-3 (encode on the write
  queue) retires this; the finite dump path is unaffected because it writes
  from inside its own utility block.
- AR3. Integer fields above 2^53 now emit exact digits where the old
  `Double(...)` build emitted pre-rounded ones. `JSONValue`-based readers
  parse into `Double` and round identically, so reader behavior is unchanged
  and the wire strictly improves.

## Rejected ideas

- RI1. Carrying the event as `any Encodable`: destroys the
  `Equatable`/`Sendable` conformances the stream types and their tests need.
- RI2. Hand-building the event's `JSONValue` in the adapter (the audit's
  cheaper fallback): creates a second spelling of the event dialect that a
  test must pin against the engine's, the exact drift I3 forbids.
- RI3. A parallel outgoing-only envelope struct family: restates the
  envelope keys a second time; the generic-with-typealias form keeps one
  declaration.
- RI4. Making `TerminalSession` generic or giving it an associated event
  type: it is used existentially and compiled in the UI-test build, and the
  cheaper arrangements in D2 make it unnecessary.

## Implementation discretion

- D1. Envelope genericization mechanics (rename-plus-typealias vs
  hand-written conformances if conditional Codable synthesis refuses), and
  whether the typed wire writes are overloads beside the `JSONValue`
  signatures -- constrained only by I2/I4 and by existing implicit-member
  call sites continuing to compile.
- D2. Exact generic-bound placement (constrain `Encodable` only at the wire
  seam; leave policy functions unbounded), and how `TerminalSession`'s tape
  requirements name their event payload per build -- a per-build typealias, or
  compiling the four tape requirements and their defaults out of the UI-test
  build with the same `#if !DANTERM_UI_TEST` that already guards their
  implementations in `SwiftTerminalSessionView.swift`. Constrained by I6/I7
  and by not growing the UI-test harness file list.

## Critical files

- `lib/DanTermProtocol/Sources/DanTermProtocol/PaneTapeRecord.swift`,
  `Envelope.swift`
- `lib/DanTermSupport/Sources/DanTermSupport/PaneTapeRecords.swift`,
  `PaneTapeStreamState.swift`, `PaneTapeFollow.swift`, `IpcConnection.swift`
- `app/SwiftTerminalSessionView.swift`, `app/TerminalSession.swift`,
  `app/AppRuntime.swift`, `app/IpcServer.swift`
- Tests: `client-tests/PaneTapeRoundTripTests.swift`,
  `app-tests/PaneTapeFollowEncodingTests.swift`,
  `app-tests/AppRuntimeCommandTestSupport.swift`,
  `lib/DanTermSupport/Tests/DanTermSupportTests/PaneTapeStreamStateTests.swift`,
  `PaneTapeFollowTests.swift`, `IpcConnectionWriteTests.swift`

Ordering constraint: the envelope and protocol-record steps can land alone
(the protocol step may keep a temporary `JSONValue` bridge for the old encode
entry point), but the support-and-app sweep is one indivisible change because
`app/DanTermSupport` compiles same-module into the app target.

## Verification

`just test` (covers the protocol, support, client round-trip, and app-tests
suites plus the purity and docs lints), then `just test-ui` explicitly for the
UI-test build. For an end-to-end check: `just launch-slot | tail -1`, run
`danterm --socket <slot> pane tape follow` against a busy pane and confirm a
reader sees an unchanged stream, then `just stop-slot <n>`.

## Commit progress
- [x] 1. protocol: make the JSON-RPC envelopes generic over their payload
- [x] 2. protocol: give the outgoing pane-tape record its own Encodable conformance
- [x] 3. support+app: carry pane-tape records typed to the wire and encode once

## Implementation notes

- The record's coding keys are a `CodingKey` struct with one static member per key,
  each built from `PaneTapeRecordKey`. A `String`-raw-valued `CodingKey` enum would
  have written every spelling a second time as a literal, and a nested struct inside
  the now-generic record cannot hold static members at all, so the struct sits at file
  scope beside the conformance.
- The commit 2 slice leaves the shape with two writers for one commit: the new
  `Encodable` conformance and the `JSONValue` builder the support producer still calls.
  Making the builder forward to the conformance would need either a `try!` or a lossy
  fallback, because the builder's callers are non-throwing, so the builder keeps its own
  body until commit 3 deletes it. A transitional test pins the two writers to the same
  object, and it goes away with the builder.
- PO1's drift pin landed in the protocol package
  (`PaneTapeRecordEncodingTests.swift`) rather than in
  `client-tests/PaneTapeRoundTripTests.swift`: at this slice the producer still builds
  JSON trees, so no client-tests case can exercise the typed encode. Migrating the
  existing producer-driven cases to the typed path stays with commit 3.
- D2 resolved as a per-build `PaneTapeSessionEvent` typealias, but it lives in
  `app/SwiftTerminalSessionView.swift`, not beside the `TerminalSession` requirements it
  serves: `scripts/terminal-backend-boundary-lint.sh` allows an engine import only in the
  adapter files, and naming `NeutralTerminalRecordingEvent` needs one. The session protocol
  keeps its four tape requirements in both builds.
- D1 resolved as one generic declaration for `writeSuccess` and `writeNotification` rather
  than typed overloads beside the `JSONValue` ones. Overloads would have left two ways to
  write the same line; the cost is that the four call sites passing a case literal now spell
  `JSONValue.object(...)`, which an unbound generic cannot infer.
- The migrated stream-policy suites assert typed records -- record kinds, gap counts, sync
  parts -- instead of the JSON they used to build. The wire keys those assertions used to
  pin now have one home each: the protocol package's encode/decode round trip, and the
  producer-to-reader round trip in `client-tests`.
- PO4's second half had no test to keep: nothing pinned that a synchronization serializing
  to no bytes still ships one part. That test is new here, beside the chunk-bound one.

## Follow Up

- The `pane.tape.event` params keys are declared twice: `PaneTapeEventNotification` in
  `lib/DanTermSupport/Sources/DanTermSupport/PaneTapeRecords.swift` writes `subscription`
  and `record`, and `lib/DanTermClient/Sources/DanTermClient/PaneTapeRecordReader.swift`
  reads them back as string literals. The duplication predates this change, and the record
  shape it wraps now has one declaration, so the envelope around it is the only spelling
  left that two sides maintain by hand.

