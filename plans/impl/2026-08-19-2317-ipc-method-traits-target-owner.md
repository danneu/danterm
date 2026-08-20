# IPC-4: one traits value and one target owner for the IPC method catalog

## Problem

Adding one IPC request method today means editing seven parallel enumerations
of the same ~34-case catalog:

- four Bool attribute switches on `IpcRequestMethod` -- `terminatesInstance`,
  `isTargeting`, `requiresLocalCaller`, `producesAuditRecord`
  (`lib/DanTermProtocol/Sources/DanTermProtocol/IpcRequest.swift:101-171`);
- `IpcRequest.targetParameterKeys` (`IpcRequest.swift:394-416`);
- the target half of `IpcRequest.params` (`IpcRequest.swift:418-510`);
- `IpcRequest.auditTarget`
  (`lib/DanTermProtocol/Sources/DanTermProtocol/IpcAuditDescriptor.swift:91-122`).

Each switch is exhaustive, so an omission is caught -- but the catalog list is
spelled seven times, and the three target projections independently type the
same key strings (`"afterTabId"` appears in all three), so they can diverge in
spelling or content with no compiler complaint. Two of the seven are dead
weight: `isTargeting` and `targetParameterKeys` are public production
properties with no production caller. The decoder does not read
`targetParameterKeys`; it reads wire keys directly. Both exist only to select
and configure tests.

This is audit item IPC-4 (`docs/scratch/2026-08-18-construction-audit.md`,
anchor `ipc-4`, as corrected there). Its prerequisite IPC-3 landed
(`177c07ef`). IPC-1 rewrites the audit descriptor against the target owner
this plan creates, so this must land first.

## Decision

- **D1 -- method traits.** `IpcRequestMethod` gains one traits value returned
  from a single exhaustive switch carrying its three actual method policies:
  instance termination, local-caller authority, and audit production. The three
  surviving Bool properties become one-line projections of it, so no consumer
  (`cli/main.swift`, `IpcDispatch.swift`, `IpcServer.swift`, tests) changes.
  The switch has no `default` arm and the traits value has no defaulted field:
  a new catalog case must not compile until all three are explicitly decided.
- **D2 -- one target owner.** `IpcRequestMethod.isTargeting` and
  `IpcRequest.targetParameterKeys` are both deleted. Target data gets exactly
  one owner: a per-request target description, produced by a single exhaustive
  switch over the request catalog, carrying the request's **named target
  entries** -- ordered wire key to typed id, and nothing else. Two projections
  derive from it: the target portion of `params` writes the entries, and the
  audit target is the entries with ids lowercased. Id lowercasing happens once,
  in the audit projection (the redaction step). Non-target discriminators that
  co-vary with a target -- `tab.new`'s `position` -- stay in `params`; the
  description owns id-bearing entries only.

  Because both wire encoding and the audit record read the entries, an entry
  that is wrong or missing breaks the round-trip and audit proofs. There is no
  target metadata left that only tests consume.
- **D3 -- behavioral no-op.** Wire encoding, decode errors, CLI behavior,
  dispatch authority checks, and durable audit records are unchanged. In
  particular:
  - Decode acceptance stays the decoder's own contract, written where it is
    read. The todo methods keep accepting either `pane` or `tab` while a
    request carries one; that either-key rule was never expressed by the
    deleted vocabulary property.
  - The audit target remains the named-entities map -- it keeps `todoId` for
    the todo mutations and lowercased UUID spellings.

## Invariants

- **I1.** The three method classifications answer exactly as today: `quit` is
  the only instance-ending and the only local-caller method, and `ping` is the
  only unaudited method.
- **I2.** A method added to the catalog cannot silently inherit any of the
  three classifications or its target description; the compiler forces an
  explicit decision for each.
- **I3.** Audit target content is unchanged: same keys (including `todoId` on
  todo mutations), same lowercased id values.
- **I4.** Every audit-target entry agrees with the request's wire params: the
  key exists in `params` and the value is the same UUID up to case. Because
  both come from the same entries, an audit record naming a key or id the wire
  never carried is not expressible.
- **I5.** Decode behavior is unchanged: every catalog method round-trips, and
  removing a request's target keys still fails with today's exact error
  message for that target form.

## Proof obligations

- **PO1 (I1, I2).** Existing pins stay green unmodified:
  `IpcRequestTests.quitIsTheOnlyInstanceEndingMethod`,
  `quitIsTheOnlyLocalCallerMethod`, and the `IpcLivenessTests` unaudited-set
  filter. `IpcLivenessTests`' ping assertions lose their `isTargeting` and
  `targetParameterKeys` lines; the adjacent `IpcRequest.ping.params.isEmpty`
  already states that ping names nothing.
- **PO2 (I3).** Existing `IpcAuditDescriptorTests` stay green unmodified --
  `todoStateChangeIsAuditedByStateAndOwner` pins `todoId` retention and
  lowercasing; `launchAuthorityIsRetained` and the pane tests pin the entity
  keys.
- **PO3 (I4).** New test looping over `representativeCLICommands()`: for every
  request, each audit-target entry's key is present in `request.params` and its
  value equals the params value lowercased. This test must pass against the
  current code before the rewrite (it pins existing agreement, there is no
  behavior change to go red on) and must survive it.
- **PO4 (I5).** `everyCatalogMethodRoundTrips` stays green and keeps forcing
  every catalog method to have a representative request.
  `everyTargetingCatalogMethodRejectsAbsentTarget` becomes an independent
  behavioral oracle rather than a consumer of production metadata:
  - `representativeCLICommands()` covers **every distinct target form**, not
    just every method name. Today's only `tab.new` entry is group-anchored, so
    the after-tab anchor is added.
  - Each targeting fixture entry states its own missing-target mutation and
    exact expected message -- `position=afterTab requires afterTabId` for the
    after-tab form, `pane or tab required` for a todo owner, and so on. The
    expectation is declared per entry, not derived from key count, and a
    targeting entry without one fails rather than skips.

## Non-goals

- IPC-1: deriving the whole audit descriptor from `params` and closing the
  `group.new` launch-audit gap. This plan only lands the single target owner
  IPC-1 builds on; `auditDescriptor`'s launch/input handling is untouched.
- Changing decode error vocabulary, wire key spellings, or `params` encoding.

## Rejected ideas

- **RI1.** "Audit target = `params` filtered by a target-key list" (the audit
  item's original wording): the audit record and the wire object have different
  contracts, so this drops `todoId` from the durable log and flips id casing.
  Superseded by D2's shared entries with two projections.
- **RI2.** Expressing the Bool properties as small exceptional sets
  (`self == .quit`): a new method would silently inherit the majority answer,
  which is exactly what the exhaustive switches exist to prevent.
- **RI3.** Keeping `isTargeting` or `targetParameterKeys`, as traits fields or
  as a second half of the target description: neither has a production caller,
  and test-only production metadata can return a wrong or empty answer that
  makes the test it configures skip instead of fail. Deleting both leaves the
  entries -- which wire encoding and the audit record both depend on -- as the
  only place target data is decided.

## Implementation discretion

- The shape and names of the traits value and the target description (struct of
  Bools, enum of target forms, entry tuples versus a small entry type, etc.),
  provided each is built by one exhaustive switch with no defaulted fields.

## Files

- `lib/DanTermProtocol/Sources/DanTermProtocol/IpcRequest.swift`
- `lib/DanTermProtocol/Sources/DanTermProtocol/IpcAuditDescriptor.swift`
- `lib/DanTermProtocol/Tests/DanTermProtocolTests/IpcRequestTests.swift`
  (PO3's new test, PO4's fixture and expectation edits)
- `lib/DanTermProtocol/Tests/DanTermProtocolTests/IpcLivenessTests.swift`
  (drops the two deleted-property lines)

## Verification

1. Add the PO3 test and the PO4 fixture/expectation edits first, and confirm
   they pass against the unmodified code.
2. `swift test --package-path lib/DanTermProtocol` after the rewrite -- every
   other existing test unmodified and green.
3. `just test` as the final gate.
