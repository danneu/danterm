# Follow subscriptions hold only placed cursors

Source: improvement audit PTY-3 (`docs/scratch/2026-08-26-improvement-audit.md#pty-3`),
verified 2026-08-27 as a pivot: the trap is unreachable in production, but the
"can this cursor name a position in my lifetime" rule is stated three times in
`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalFlightRecorder.swift`.

## Problem

`TerminalFlightRecorder` owns a total, non-trapping classifier, `cursorPlacement`,
that answers whether a cursor can be placed in this recorder lifetime. Two other
paths restate a subset of that rule as a trap:

- `addFollowSubscription` `precondition`s one of the seven conditions and returns
  `Bool` only for the follower cap, so a cursor the recorder could refuse would
  kill the process instead of returning `false`.
- `pushFollowSubscription` feeds the subscription's stored cursor into the
  raw-cursor `cursorSnapshot`, whose checked guard `preconditionFailure`s when
  placement fails -- a second trap on the follow path.

Every production cursor that reaches these paths is minted by the same recorder
(`app/PaneTapeBroker.swift#finishPreparedFollow` passes `opening.nextCursor`, a
`streamFence` snapshot cursor), so no user-visible behavior is wrong today. The
cost is structural: a subscription can hold a coordinate the recorder cannot
place, and the rule that says it can't lives in three places.

## Decision

Make `cursorPlacement` the single ingress for a follow subscription's cursor.
`addFollowSubscription` classifies the incoming cursor and refuses (`false`) on
`.unplaceable`; the subscription stores a cursor that only placement can mint;
the push path snapshots that placed cursor without validation or a trap. The
`precondition` in `addFollowSubscription` goes, because the state it guarded
against is no longer representable. The raw-cursor `cursorSnapshot(from:)` stays
as a checked convenience for its existing package callers
(`TerminalPTYHost.swift#fencedFlightRecording`, `streamFence`, tests): its guard
delegates to `cursorPlacement` rather than restating the rule, and an
arbitrary raw cursor still needs a defined failure.

Scope: `lib/TerminalPTY` only. The host fence
(`TerminalPTYHost.swift#addFlightRecordingFollowSubscription`) and the app caller
(`SwiftTerminalSessionView.swift#addPaneTapeFollowSubscription`) already
propagate `false`, so they do not change. `integrations/danterm/SKILL.md` does
not change: no registration accepted today is refused after this.

## Invariants

- I1. A registered follow subscription holds only a cursor this recorder placed;
  a subscription holding an unplaceable coordinate is not representable.
- I2. `addFollowSubscription` never traps on its cursor argument. An
  unplaceable cursor (foreign lifetime, sequence past the head, watermark past
  the totals, or watermark disagreeing with the retained position) returns
  `false` and registers nothing.
- I3. A subscription registered at a cursor minted by this recorder delivers
  its first batch by the snapshot contract, unchanged from today: with no
  eviction gap, starting at the cursor's `nextSequence` with zero drops; with a
  gap, starting at the retained head with the exact drop count.
- I4. The placement rule (`cursorPlacement`'s conditions) is stated once. The
  follow path never re-validates or traps; the raw-cursor `cursorSnapshot`
  keeps delegating to `cursorPlacement`.

## Proof obligations

`lib/TerminalPTY/Tests/TerminalPTYHostTests/TerminalFlightRecorderTests.swift`,
run with `swift test --package-path lib/TerminalPTY --filter TerminalFlightRecorder`.

- PO1 (I1, I2). Record a few events, then attempt registration with each of:
  a cursor whose `recorderLifetimeId` is a fresh UUID; one whose `nextSequence`
  exceeds the recorder's head; one whose feed or write watermark exceeds the
  recorder's total; and one whose watermarks are within the totals but disagree
  with the retained position for its sequence. Each returns `false`,
  `hasFollowSubscription(id:)` is false, and a later `record` plus
  `markFollowSubscriptionReady` delivers nothing to that subscription's
  `deliver`. Today the first two cases trap; the last two prove registration
  uses the classifier's full result, not a subset.
- PO2 (I3, no-gap branch). Register at `cursorSnapshot(from: .beginning).nextCursor`, record
  more events, mark ready; the delivered snapshot's first event sequence equals
  the cursor's `nextSequence` and `droppedEventCount == 0`. Existing follow tests
  at lines 74-163 of the test file already cover most of this; extend rather
  than duplicate.
- PO3 (I3, gap branch). A cursor minted before eviction that the
  recorder can still place (the `cursor.nextSequence < firstRetainedSequence`
  branch of `coordinatesMatchRetainedPosition`) is still accepted and delivers
  the retained suffix with an exact drop count. Existing `cursorSnapshot`
  eviction tests (around lines 392-451) pin the snapshot half; add the
  registration half.
- PO4 (I4). Structural, not a test: after the change, the recorder has no
  `precondition` on a cursor in the follow registration or push path. The
  reviewer checks this by reading.

## Non-goals

- Changing `PaneTapeCursor`, `recorderCursor`, or anything in `app/` or
  `DanTermCore`. The placed-cursor type is recorder-internal (`package` at most).
- Changing `streamFence`, the raw-cursor `cursorSnapshot(from:)` contract,
  `.beginning` handling, or the `unplaceablePolicy` surface. `.beginning` stays a pre-placement special case that `cursorSnapshot`
  maps to the backlog cursor before classifying.
- Any CLI or `SKILL.md` change.

## Rejected ideas

- RI1. Turn the `precondition` into `guard ... else { return false }` in place.
  Removes one trap, leaves the placement rule in three places and leaves
  `cursorSnapshot`'s `preconditionFailure` next in line on the push path.
- RI2. Validate again inside `pushFollowSubscription`. Double-classifies every
  push for a condition I1 already makes impossible.
- RI3. Remove the checked guard from the raw-cursor `cursorSnapshot(from:)`.
  Its guard is a delegation to `cursorPlacement`, not a copy of the rule, and
  `fencedFlightRecording(from:)` can still hand it an arbitrary cursor; without
  the guard that cursor reaches index arithmetic or an untruthful fallback.

## Implementation discretion

- Shape of the recorder-private placed-cursor value that only the classifier
  mints, and the name of the placed-only snapshot path the push uses.

## Commit progress

- [x] 1. fix(terminal-pty): store placed cursors in follow subscriptions

## Implementation notes

- The private `placedCursor(from:)` classifier owns the placement conditions and
  mints the stored proof value. The package-facing `cursorPlacement(from:)`
  delegates to it and keeps its snapshot-valued API. This avoids mapping the
  retained suffix only to discard it during follow registration.
