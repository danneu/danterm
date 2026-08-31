# One verdict at the phone's record edge

Combined fix for audit findings MOBKIT-3 + MOBKIT-1
(docs/scratch/2026-08-26-improvement-audit.md): decide everything about
an incoming tape record -- decodable?, readable?, end-of-stream? -- in
one function at the model's edge, and delete the record round trip
through the shell.

## Problem

`MobileSessionModel` treats "this build cannot read what arrived"
three different ways, and learns about end-of-stream by a pointless
round trip:

- `receive`'s notification arm skips a record that fails
  `decodePaneTapeRecord` (`continue`). A skipped `.event` record leaves
  the replica's sequence cursor behind, so the next record trips the
  gap guard, the model ends with `.streamDesynchronized`, and that
  failure discards the stored checkpoint. One malformed record costs
  the user their scrollback and blames the Mac ("Stream out of step
  with the Mac") for something the phone could not parse.
- `receive`'s response arm bare-returns `[]` on the same failure. That
  reply carries the stream's `.start` record, so the phone parks in
  `.serving` showing "Connected" with no stream and no timer that will
  ever notice.
- `take` already ends the connection (`.deviceSetup`, "Stream carried
  an unreadable event") when an event fails to lift -- the correct
  verdict, stated only for one of the three failure paths.
- The model learns a record was `.end` only after the shell applies it
  and dispatches `.recordApplied` back -- a whole-record round trip
  whose sole consumer reads one case, on a record the replica ignores
  (`PaneReplica.apply`: `case .end, .unknown: break`).

Nil from `decodePaneTapeRecord` always means malformed, never a
forward-compat unknown kind (those decode to `.unknown`), so neither
skip is a compatibility allowance. The end-of-stream path is reachable
today only through the untested UIKit shell; no kit test reaches
`.streamEnded` through the model.

## Decision

Rewrite `MobileSessionModel.take` to be the single edge: it receives
the raw `JSONValue`, decodes the record, lifts its event, notes
pinnedness, decides end-of-stream, and emits `.applyRecord` only for a
record that survives all of that. Both `receive` arms call it. Delete
`MobileSessionEvent.recordApplied` and the shell's dispatch of it
(`MobileSessionController`, `.applyRecord` arm keeps only the apply and
the `.replicaRejectedRecord` failure path).

Files: `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionModel.swift`,
`MobileSessionEvent.swift`, `MobileSessionEffect.swift` (doc comment),
`ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileSessionController.swift`.

## Invariants

- I1: Every path from wire bytes to the replica runs through one
  function with one failure verdict. A record this build cannot read --
  undecodable record or unliftable event, in either `receive` arm --
  ends the connection with `.deviceSetup` and an unreadable-stream
  detail. No path skips a record or silently drops a reply: a matching
  tape success reply with no `result` also ends with `.deviceSetup`
  (the scenario that failure's own doc comment names).
- I2: An `.end` record ends the connection with
  `.streamEnded(reason:)` from `take`; no effect is issued for it and
  no shell event reports it back.
- I3: `.streamDesynchronized` is no longer reachable via a malformed
  record; a malformed record leaves the stored resume position trusted
  (the ending failure's `preservesResumePosition` is true).
- I4: The shell never tells the model about a record the model
  authored: `MobileSessionEvent` has no `recordApplied` case.

## Proof obligations

Behavioral tests in `MobileSessionModelTests`, driven through
`.frameReceived` as the suite already does:

- PO1 (I1): a notification batch holding one well-formed `.event`
  record followed by a malformed record ends the connection, and the
  status wording is the unreadable-stream detail, not "out of step".
- PO2 (I1): a tape-subscription response with no `result`, and one
  whose `result` does not decode, each end the connection instead of
  leaving the model `.serving`.
- PO3 (I3): after the malformed-record disconnect, a reconnect still
  resumes from the stored checkpoint.
- PO4 (I2): a notification carrying an `.end` record ends the
  connection with `.streamEnded` and its reason -- written from
  scratch; no such test exists.
- PO5 (I4): compiler-discharged by deleting the case.
- PO6 (AR1): a notification carrying a record of an unknown kind
  leaves the model connected -- pins that the malformed/forward-compat
  boundary survives the decode moving into `take`.

## Accepted risks

- AR1: Build skew (phone binary older than a Mac-side change to a
  record's required fields) now drops the connection instead of
  limping. Intended: it matches what `take` already does for events,
  and the limp was worse (desync + discarded checkpoint). A *new*
  record kind still decodes to `.unknown` and is unaffected.
- AR2: An `.end` record mid-batch now ends the connection before later
  records in the same batch are applied. No producer emits records
  after `.end` (`PaneTapeBroker`, core `PaneTapeRecords` all place it
  last), so this is a behavior change only on a batch that does not
  occur.

## Non-goals

- No change to `PaneReplica`, the producer/broker side, or the wire
  format.
- No touch of `MobileSessionController.beginStream` / `send`
  (MOBKIT-6's territory).

## Verification

- `swift test --package-path ios/DanTermMobileKit --filter MobileSessionModelTests`
- `just lint`, then `just test` before commit.
- Grep `recordApplied` across `ios/` returns nothing.

## Commit progress

- [x] 1. fix(ios): decide tape records at the model edge
- [ ] 2. docs(audit): mark MOBKIT-3/1 complete

## Implementation notes

- `take` accepts an optional `JSONValue` rather than a decoded record, so
  the "matching tape reply with no `result`" case reaches the same
  verdict through the same function instead of a second branch in
  `receive`. This is what makes I1's "one function, one failure verdict"
  literal rather than approximate.
- The failure detail is now "Stream carried an unreadable record" for
  both the undecodable record and the unliftable event. The old wording
  named the event alone, which would have been wrong for two of the
  three paths the one verdict now covers.
- PO3's test passes before the fix as well: at the model's level
  `.streamDesynchronized` is only reachable through
  `.replicaStateChanged(.gap(.detected))`, which the shell dispatches,
  so no model-only test can reproduce the old skip-then-desync sequence.
  The test still pins I3 against a future regression.
