# Pane-tape sync from slices, then the pure policy into core (WIRE-6 + PERSIST-5)

One plan, three commits, in this order. WIRE-6 rewrites the sync-record
builder inside `PaneTapeStreamState.swift`, and PERSIST-5 moves that file:
doing the byte-carrier change first means the move relocates settled files
(the audit's X3 ordering). A final commit marks both findings done in the
audit document. Prerequisites PERSIST-6, WIRE-2, and WIRE-3 have all landed.

## Problem

**WIRE-6.** A reconstructible sync serializes a pane's whole retained state --
unbounded when `historyBudgetBytes` is nil, which is what `pane.snapshot`
requests. Before those bytes reach the wire they are duplicated: the chunker
copies every chunk out of the payload (`Array(bytes[range])` in
`makePaneTapeSynchronizationRecords`, eagerly for all chunks), so the record
array collectively owns a second whole copy of the payload, and the wire
encode copies each chunk again into a `Data` and then a base64 `String`
(`PaneTapeRecord.swift`, the `.sync` arm of `encode(to:)`). Peak residency is
a multiple of the payload size, on the one path that exists because payloads
are large.

**PERSIST-5.** About 800 lines of pure, deterministic decision logic -- the
events-vs-synchronize stream policy (`PaneTapeStreamState.swift`), the follow
subscription machine (`PaneTapeFollow.swift`), and the record builders
(`PaneTapeRecords.swift`) -- live in DanTermSupport, the layer the pure-core
ADR reserves for portable side effects. The pure lint's IO/nondeterminism
bans cover only `lib/DanTermCore/Sources/DanTermCore`, so nothing stops a
`Date()` or a `DispatchQueue` from creeping into a decision, and the layer
story in the ADR reads wrong. The comparable policy for the other stream,
`RecoveryCheckpointPolicy`, is already in core.

### Load-bearing premises (verified against the current tree)

- The three pane-tape files import only Foundation and DanTermProtocol; the
  single impure symbol is the `connection: IpcConnection` parameter of
  `writePaneTapeRecords`, now a thin wrapper over the generic
  `writeBatchedNotification` (post WIRE-3).
- Only `app/AppRuntime.swift` and `app/SwiftTerminalSessionView.swift` use
  these types outside the three files themselves; nothing else in Support
  does.
- DanTermCore's nested package already depends on DanTermProtocol, and
  `IpcLineFramer` is public in DanTermProtocol, so the moved code needs no new
  dependency of its own. The root `DanTermPaneTapeRoundTripTests` target is the
  exception: it reaches the record builders through `@testable import
  DanTermSupport`, and the root `Package.swift` gives it no DanTermCore
  dependency, so the move has to retarget it.
- TerminalCore imports no Foundation anywhere; `Terminal.feed` takes
  `[UInt8]` or `UnsafeBufferPointer<UInt8>`, and `TerminalStateSynchronization`
  carries `bytes: [UInt8]`.
- The wire encoder is a plain `JSONEncoder` (`encodeIpcLine`), whose default
  data strategy is base64 with the same alphabet and padding as
  `base64EncodedString()`, so encoding a `Data` field directly produces
  byte-identical output.

## Decision

**D1 (WIRE-6).** The payload gets one owning buffer, and a sync record names
a range of it instead of owning a duplicate. Type the payload as `Data` from
the engine boundary down: `PaneTapeStateSynchronization.bytes` and
`PaneTapeSyncRecord.bytes` become `Data`; the chunker slices that one buffer
(`Data` slices share storage); base64 is produced at wire-encode time by
encoding the `Data` field directly, and no record retains it. (The existing
splitter may encode a chunk more than once -- see AR2.) The decode side
mirrors it: base64 decodes to `Data`, the reader's assembler accumulates
`Data`, and the replica feeds the engine without re-materializing an array.
The engine keeps `[UInt8]` -- TerminalCore stays Foundation-free -- so the
one whole-payload copy that remains is the `[UInt8]` -> `Data` conversion at
the engine boundary in app.

**D2 (PERSIST-5).** Move `PaneTapeStreamState.swift`, `PaneTapeFollow.swift`,
and the pure content of `PaneTapeRecords.swift` into
`lib/DanTermCore/Sources/DanTermCore/`, with `PaneTapeStreamStateTests` and
`PaneTapeFollowTests` following into DanTermCoreTests. `writePaneTapeRecords`
-- the one function that touches a connection -- moves to `app/`, which
already owns the connection registry and every call site. The connection
ordering and splitting tests in `IpcConnectionWriteTests` are rehosted on the
generic `writeBatchedNotification` API: what they pin is connection behavior,
not tape policy.

## Invariants

- **I1.** Wire bytes are byte-identical for every record kind: same chunk
  bound (`IpcLineFramer.maxLineBytes / 4`), same `part`/`parts`, transfer
  facts on the first part only, cursor on the last part only, and an empty
  payload still yields exactly one record with an empty base64.
- **I2.** Between the engine boundary and the last encoded sync line, the
  payload bytes exist in exactly one buffer; every sync record references a
  range of it. Base64 for a chunk exists only transiently inside the wire
  encode of that chunk's line.
- **I3.** The pane-tape decision code compiles and tests in the standalone
  DanTermCore package, which is what enforces the dependency isolation, and it
  sits inside the pure lint profile's target, so the IO and nondeterminism
  tokens that profile names become gate failures in stream policy. The lint is
  a denylist regression guard, not a proof of purity.
- **I4.** DanTermSupport retains no pane-tape code. Outside core and
  protocol, the only pane-tape symbol is the app's single wire funnel, which
  remains the one site that puts tape records on a connection. Every target that
  reaches the builders follows them, including the root producer-to-client
  round-trip target, which takes a DanTermCore dependency and imports the
  builders from there.
- **I5.** Stream behavior is unchanged: the policy, follow, and
  connection-ordering test suites keep their assertions (modulo the byte
  carrier's type) and pass after both commits.

## Proof obligations

- **PO1 (I1).** Golden-record coverage: a payload spanning three chunk
  boundaries, a payload of exactly the chunk bound, and the empty payload --
  the encoded notification lines must be byte-identical before and after the
  type change. The root producer-to-client round-trip target keeps proving the
  producer and the client's reader agree, across both commits.
- **PO2 (I2).** By construction: the record field's type is a slice of the
  payload buffer, so a copy has no place to exist. No allocation-counting
  test -- that would pin structure, not behavior. Review verifies the slice
  typing survives the boundary crossings (chunker, encoder, decoder,
  assembler).
- **PO3 (I3).** `swift test --package-path lib/DanTermCore` runs the moved
  suites; `scripts/core-purity-lint.sh` covers the moved files by covering
  their new directory.
- **PO4 (I5).** Moved tests pass verbatim. The `IpcConnectionWriteTests`
  pins -- a terminator never overtakes an enqueued batch, a batch travels as
  one notification, an over-bound batch splits at record boundaries in order
  -- survive rehosted on `writeBatchedNotification`.
- **PO5 (I1, I5).** The existing replica round-trip tests (PaneReplica
  applying a sync from a real terminal) stay green, proving the decode side's
  `Data` path reproduces the grid.

## Non-goals

- RUNTIME-6 (extracting the follow broker out of AppRuntime) -- next in the
  audit's chain, deliberately after this move.
- BUILD-1 (declaring purity profiles per target) -- it records the layout
  this plan settles.
- Reworking `writeBatchedNotification`'s halving strategy. A multi-chunk sync
  group is first encoded as one over-bound line, then halved and re-encoded;
  that is WIRE-3's design and unchanged here.

## Accepted risks

- **AR1.** One whole-payload copy remains at the engine boundary, because
  deleting it would put Foundation into TerminalCore or an unsafe-lifetime
  view at the boundary. The copies this plan removes are the resident ones;
  this one is single and transient.
- **AR3.** Nothing measures peak residency, so a `Data` field holding an owning
  copy instead of a slice would pass every test. Rejected because an elapsed- or
  bytes-threshold probe is a measurement gate this project does not accept as a
  pass/fail criterion, and PO2's construction plus review of the four boundary
  crossings is the coverage that fits.

- **AR2.** Transient encode-time memory is still payload plus one encoded
  line (and the halving re-encode repeats work for multi-chunk groups). That
  is the cost of a line-framed wire, not of the record representation.

## Rejected ideas

- **RI1.** Making TerminalCore emit `Data` so no boundary copy exists:
  rejected because the engine is deliberately Foundation-free, and one
  bounded copy does not justify changing that.
- **RI2.** Keeping `[UInt8]` and typing records as `ArraySlice<UInt8>`:
  slices as stored public protocol fields make the codec asymmetric (decode
  produces `Data` anyway) and still need a per-chunk `Data` copy at encode.
- **RI3.** Producing sync records lazily (the audit finding's suggestion):
  unnecessary once records hold slice headers -- eager construction of the
  record array no longer duplicates the payload.
- **RI4.** Leaving the policy in Support and adding a third lint profile for
  the pane-tape files: buys the guard but forks the profile list per file
  group and leaves the ADR's layer story wrong; the move costs little more.

## Implementation discretion

- Where in `app/` the wire funnel lands and what it is named.
- How the replica feeds `Data` to the engine without a copy (the
  `UnsafeBufferPointer` feed overload is available).

## Commit progress

- [x] WIRE-6: sync payload as `Data` slices end to end; wire bytes
  byte-identical (I1, I2; PO1, PO2, PO5).
- [ ] PERSIST-5: pane-tape policy and its tests into DanTermCore, the wire
  funnel into `app/`, connection pins rehosted, the root round-trip target
  retargeted onto DanTermCore (I3, I4, I5; PO1, PO3, PO4).
- [ ] Mark PERSIST-5 and WIRE-6 done in
  `docs/scratch/2026-08-18-construction-audit.md`: check both checklist
  entries and append the implementing commit hashes, matching the existing
  done-entry convention.

## Implementation notes

- **WIRE-6 golden coverage (PO1).** The chunk bound is 4 MiB, so a literal
  golden line is not writable. `syncPartsCarryTheirChunkAsBase64` instead
  encodes the produced records through the real notification encoder, reads
  each part's `base64` field back off the wire, and compares it to
  `Data(expectedChunk).base64EncodedString()` computed in the test -- an
  independent statement of the chunk boundaries and the base64 alphabet, both
  of which the carrier change could have moved. Part numbering is asserted
  beside it; transfer-on-first and cursor-on-last stay pinned by the two
  neighbouring tests. The test was written and passed against the `[UInt8]`
  carrier first, so it is a real before-and-after pin.
- **Encoding the payload field.** The sync arm now hands `Data` straight to
  the keyed container rather than building a base64 `String`. That relies on
  the wire being JSON, whose default data strategy is the same alphabet and
  padding; the record type has one encoder, `encodeIpcLine`.
