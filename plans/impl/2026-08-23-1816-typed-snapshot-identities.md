# Type Snapshot Identities Without Changing Recovery Semantics

## Problem and desired outcome

Snapshot identities are strings even though the live model uses phantom-typed
UUID wrappers. Every projection formats those UUIDs, equality compares the
formatted strings, and restore and scrollback grafting parse them back. This
leaves domain mistakes representable in the persisted model and performs work
that the current per-message checkpoint projection does not need.

The snapshot model should carry typed identities from capture through equality,
validation, and grafting. Encoding alone should turn them into strings. The
version 3 JSON shape and the deliberate recovery behavior for hand-authored and
partly malformed files must remain stable.

The current `TypedId` conformance is a load-bearing premise: synthesized
`Codable` emits `{"rawValue":"UUID"}`, while the persisted and IPC spelling is
the bare string `"UUID"`. Typed snapshots therefore require one canonical
single-value codec before they can preserve the wire format.

## Decision

- Give every `TypedId` one bare-UUID-string `Codable` representation. This is
  the public representation for direct encoding as well as the snapshot
  representation.
- Collapse the existing `TodoItem` and tab-todo drag payload codecs onto that
  canonical representation. The drag payload's pane source becomes a `PaneId`
  so both identities use the canonical codec. Their encoded bytes remain
  unchanged.
- Store group, tab, pane, split, selected-tab, focused-pane, and todo identity
  in snapshot values with the corresponding phantom type.
- Keep defining IDs optional. An omitted group, tab, pane, or split ID remains
  an instruction to mint an identity during validation.
- Treat selected-tab and focused-pane IDs as repairable references. Missing,
  malformed, or dangling references fall back to the first valid tab or pane as
  they do today.
- Keep todo decoding selectively lossy. A todo whose ID is a string but not a
  UUID is omitted by itself; valid siblings survive in order. Other malformed
  required todo fields still reject the file.
- Treat a malformed defining UUID as a decode failure. Startup still falls back
  to a fresh session; state import may report invalid JSON instead of invalid
  snapshot.
- Keep the persisted format at version 3. Every identity the app writes remains
  a bare uppercase UUID string under its existing key and nesting. Re-encoding
  an omitted defining ID is not a product path, so whether that key is absent or
  explicit `null` is unconstrained.

## Invariants

- **I1 - One identity representation.** A typed identity crosses a Codable
  boundary as one bare UUID string, never as a keyed wrapper.
- **I2 - Typed persisted domains.** The compiler rejects placing a pane ID in a
  tab, group, split, or todo identity field, and likewise for every other
  cross-domain substitution.
- **I3 - Hand-authored omission.** Omitting defining IDs continues to produce a
  valid model with freshly minted identities.
- **I4 - Repairable references.** Unusable selected-tab and focused-pane
  references do not prevent restoration when a valid fallback exists.
- **I5 - Todo salvage.** One malformed UUID string in either todo collection
  removes only that todo and does not remove valid siblings or reject the
  session.
- **I6 - Validation remains semantic.** Duplicate identities, cross-domain UUID
  collisions, dangling membership, and invalid tree structure remain rejected
  after UUID parsing leaves validation.
- **I7 - Stable external format.** A version 3 file produced before this change
  decodes after it, and an app-produced model encodes after it with the same JSON
  identity values and shape.

## Proof obligations

- **PO1 - Codec.** Direct encoding and decoding of each shared typed-ID domain
  proves I1, including rejection of a malformed UUID string.
- **PO2 - Wire shape.** A fixed pre-change version 3 fixture proves I7 in both
  directions: its canonical JSON text decodes, and the matching populated model
  encodes with sorted keys to exactly the same bytes. The fixture covers group,
  tab, selected-tab, focused-pane, split, pane, and todo IDs.
- **PO3 - Omitted IDs.** A hand-authored tree with omitted group, tab, pane, and
  split IDs proves I3 and the selected/focused fallback behavior in I4.
- **PO4 - Soft references.** Missing, malformed, and dangling selected-tab and
  focused-pane references prove I4.
- **PO5 - Todo recovery.** Pane and tab todo collections containing valid,
  malformed-UUID, and valid entries prove I5. Wrong JSON types and missing
  required todo fields still prove whole-file decode failure.
- **PO6 - Semantic rejection.** Existing duplicate, cross-domain collision,
  membership, and tree-validation coverage proves I6 with typed snapshots.
- **PO7 - Snapshot consumers.** Existing snapshot round-trip, export,
  checkpoint equality, and scrollback-graft behavior remains unchanged. The
  checkpoint projection cost probe still passes its fixed limit, but its result
  does not support a new speedup claim.

## Dependencies and boundaries

- The completed LOOKUP-1 cost revalidation does not block this work. Its future
  persistence-ownership rewrite must consume the typed snapshot boundary.
- This change precedes PERSIST-3 because both touch snapshot construction and
  scrollback grafting. PERSIST-3 must operate on the settled typed fields.
- WIRE-5 remains separate. Do not include its scrollback-tail policy changes.
- Do not add a format migration, compatibility shim, persisted revision counter,
  or broader lossy decoding.

## Accepted risk and implementation discretion

- **AR1 - Error wording.** A malformed defining UUID moves from snapshot
  validation failure to decode failure. The fallback behavior is unchanged, and
  this plan accepts the different import message.
- The private factoring of repairable-reference and selectively lossy todo
  decoding is implementation discretion. It must satisfy I3-I5 without keeping
  malformed identities in the typed snapshot model.

## Commit progress

- [x] 1. Canonicalize typed identity codecs across existing consumers
- [x] 2. Carry typed identities through snapshot recovery
