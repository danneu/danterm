# Declare the pane-tape event envelope once

## Context

Follow-up from WIRE-2 (`plans/impl/2026-08-19-1542-typed-pane-tape-record-encode-once.md`),
which gave the pane-tape record one declaration in DanTermProtocol and made it
travel typed to the wire. The envelope around that record did not move: the
`pane.tape.event` params carry two keys, `subscription` and `record`, and they
are spelled twice.

- The writer declares them as an `Encodable` shape in
  `lib/DanTermSupport/Sources/DanTermSupport/PaneTapeRecords.swift`.
- The reader pulls the same two keys out of a `JSONValue` as string literals in
  `lib/DanTermClient/Sources/DanTermClient/PaneTapeRecordReader.swift`.

Nothing forces the two spellings to agree. A reader that drifts from the writer
on a key name, on nesting, or on whether a field is optional still compiles on
both sides, and the disagreement shows up only as a stream that silently stops
producing records.

Desired outcome: the two keys have exactly one declaration in the repo, and the
notification's shape is decided in one place that both sides consume.

Load-bearing premises, verified at HEAD:

- The record shape itself already has one declaration, in DanTermProtocol.
- `lib/DanTermProtocol/Sources/DanTermProtocol/JSONValueDecoder.swift` decodes
  any `Decodable` straight out of a parsed `JSONValue` tree, with no trip back
  through bytes, so a shared shape costs the reader no re-encode.
- Decoding a `JSONValue` payload out of a `JSONValue` is value-identity,
  including for `null` and for numbers.
- The reader deliberately does not decode the carried record into the typed
  record family: a record kind this build does not know passes through to the
  consumer intact.
- `lib/DanTermClient/Package.swift` and `lib/DanTermSupport/Package.swift` both
  already depend on DanTermProtocol, and no boundary lint constrains adding a
  wire type there.

## Decision

The envelope gets one declaration, in DanTermProtocol, generic over the record
it carries, conditionally conforming so the writer encodes and the reader
decodes that single shape. Its keys come from the property declarations, so a
second spelling cannot exist.

Two constraints are architecturally decisive:

- **Generic over the carried record, not over the producer's event type.**
  Binding the record type would force the reader through the typed record
  family and lose unknown-kind pass-through. The reader instantiates the
  envelope with `JSONValue`; the writer instantiates it with the typed record.
- **Recognition moves down with the shape.** Matching the method and rejecting
  a notification that is not a pane-tape event belong to the shared
  declaration, so no production module outside DanTermProtocol spells any part
  of this envelope. The method name already lives there.

## Invariants

- **I1.** The `pane.tape.event` params keys have exactly one declaration in
  production code. Every production encoder and decoder of those params goes
  through that declaration; no production module outside DanTermProtocol
  spells the keys. A test may spell the wire contract independently, which is
  what PO4's fixtures do.
- **I2.** The reader carries the record forward without decoding it into the
  typed record family, so a record kind this build does not know still reaches
  the consumer intact.
- **I3.** A notification that is not a pane-tape event, or whose params do not
  match the envelope shape, is rejected outright. There is no partial value.
- **I4.** One record on the wire is still produced by a single JSON encode.

## Proof obligations

- **PO1.** I1: no production spelling of the envelope's keys exists outside
  its one declaration.
- **PO2.** I2: a record whose kind the decoder does not know survives the
  reader unchanged.
- **PO3.** The identity premise: a carried tree containing a null, a
  fractional number, and nested containers comes back equal.
- **PO4.** I3: each rejection case yields nothing -- wrong method, absent
  params, params that are not an object, and each key missing or ill-typed.
- **PO5.** I4: the existing single-encode pins from WIRE-2 stay green; this
  plan adds no new coverage for it.

## Non-goals

- Changing the record shape, the method name, or anything else on the wire.
  This plan is a source-level dedupe with no observable protocol change.
- Changing what the CLI does with a carried record. It re-encodes the tree
  today and continues to.

## Rejected ideas

- **RI1.** Hoist only the key strings into a shared constant both sides
  reference. It pins the spellings but not the shape, so a reader can still
  drift on nesting or optionality with both sides compiling -- which is the
  failure this plan exists to remove.
- **RI2.** Fold the subscription id into the record so that no envelope
  exists. Subscription is transport routing and the record is content, and the
  same records go into finite dumps, where no subscription applies.

## Accepted risks

- **AR1.** Decoding the envelope rebuilds the carried tree node by node rather
  than handing over the already-parsed value. The work is proportional to the
  record's node count, on a path that has just parsed that same tree. The ideal
  is a `JSONValueDecoder` raw-value identity path: when the target type is
  `JSONValue`, hand back the existing member instead of re-walking it, which
  removes the cost while the envelope keeps synthesized decoding. Accepted and
  deferred: that path is a `JSONValueDecoder` optimization independent of this
  dedupe, and it changes no shape this plan declares.

## Implementation discretion

- **D1.** The shared type's name, its conformance set, and its initializer
  surface.
- **D2.** How I1 is held -- by the type system alone, a test, or a lint. The
  type system carries the production half by construction once both sides
  consume the shared declaration.

## Implementation notes

- The shared type keeps the writer's name, `PaneTapeEventNotification`, and its
  `subscription` property, so the reader's former `PaneTapeStreamNotification`
  and its `subscriptionId` property are gone. Readers name the record type
  explicitly -- `PaneTapeEventNotification<JSONValue>(method:params:)` -- because
  the recognizing initializer gives Swift nothing to infer the parameter from.
- The two T5/T23 spike files under `docs/research/35-ios-remote-client/` link
  the shipped `DanTermClient` and were updated with the same mechanical change.
  Nothing in the gate builds them, so leaving them broken would have gone
  unnoticed until someone re-ran the spike.
