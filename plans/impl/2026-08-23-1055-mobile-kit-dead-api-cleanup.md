# The mobile kit publishes one answer per question, and the case with no producer says so

## Problem and desired outcome

Audit item IOS-5 named five public `DanTermMobileKit` entry points reachable
only from their own tests, and proposed deleting all five together. Re-checked
against the tree, the five are not one thing. Three are dead, one is already
gone, and one is finished behavior waiting for a trigger that has not been
built.

Three are dead, with no caller outside the test target:

- `MobileResumePolicy.resumeCheckpoint(stored:)`. The policy publishes two
  answers to one question -- a Bool and a pass-through of the caller's own
  value. Production asks the Bool: `MobileSessionModel` reads
  `trustsStoredPosition`, and the shell does the `? load : nil` itself. The
  Bool is the deliberate one; its own doc comment states why ("a refused
  position costs no read").
- `MobileDeadlineTimer.isPending`. No caller. Its doc comment describes callers
  that "schedule one flush per dirty period" and use it to leave a pending
  deadline alone -- a pattern the model replaced with its own
  `checkpointDeadlineIsArmed` flag. The comment now points a reader at a
  scheduling design that no longer exists.
- `PaneReplicaCheckpointStore.remove()`. No caller anywhere, production or test.
  `load(for:)` already deletes a corrupt or foreign-pane record on its own catch
  path, so the file has one deleter and one caller-facing way to reach it.

Two are not work:

- `MobileConnectionState.listingPanes` was deleted in `c4d44d50`, after the
  audit was written.
- `MobileReconnectEvent.userCancelled` is designed behavior with no producer
  yet, not dead vocabulary. Its `handle` branch is a full behavior: it clears
  the in-flight attempt and sets the standing to manual, which makes a clock
  tick and a network-path change inert while leaving a pane gesture as the way
  back. `plans/impl/2026-08-17-1346-ios-client-automatic-reconnect-policy.md`
  records that the phone has no stop control today and names the affordance --
  a stop control on `ConnectionHeaderView` -- as follow-up work.

The audit read `userCancelled` as dead for a reason the code supplies: its doc
comment says "The user dropped the connection or the attempt", which describes
a producer that does not exist, and nothing on the case says otherwise. A
reader of that enum has no reason to open a plan file in `plans/impl/`.

Desired outcome: the kit publishes one answer per question; a checkpoint file is
deleted in one place; no doc comment describes a caller that no longer exists;
and the one case that legitimately has no producer states that where a reader
of the enum will find it.

## Decision

Delete the three dead entry points and let the compiler prove nothing else
wanted them. Extend the doc comment on `MobileReconnectEvent.userCancelled` to
state that it has no producer yet and that the stop control is follow-up work.

`ResumePolicyTests` moves onto `trustsStoredPosition` rather than losing its
assertions: those are the only coverage of the trust rules, and the rules
survive the deletion untouched.

Critical files, all under `ios/DanTermMobileKit/`:

- `Sources/DanTermMobileKit/MobileResumePolicy.swift`
- `Sources/DanTermMobileKit/MobileDeadlineTimer.swift`
- `Sources/DanTermMobileKit/PaneReplicaCheckpoint.swift`
- `Sources/DanTermMobileKit/MobileReconnectEpisode.swift` (comment only)
- `Tests/DanTermMobileKitTests/ResumePolicyTests.swift`
- `Tests/DanTermMobileKitTests/DeadlineTimerTests.swift`

## Invariants

- **I1.** `MobileResumePolicy` publishes exactly one answer about a stored
  position: whether it is trusted. Nothing passes a checkpoint value through
  the policy.
- **I2.** A checkpoint file is deleted in exactly one place -- the recovery path
  inside `PaneReplicaCheckpointStore.load(for:)`.
- **I3.** Every public case of `MobileReconnectEvent` either has a producer in
  the model, or its own doc comment states that it has none and why.

## Proof obligations

- **PO1** (I1). The failure vocabulary decides trust: every
  `MobileConnectionFailure` except a detected desynchronization leaves a stored
  position trustworthy, and that one alone refuses it. Discharged by the
  existing vocabulary sweep in `ResumePolicyTests`, restated against
  `trustsStoredPosition`.
- **PO2** (I1). The refusal outlives the one attempt that follows it, and ends
  only when the replica is exact again. Discharged by the existing
  refusal-lifetime tests, restated the same way.
- **PO3.** A cancelled deadline delivers nothing. Already discharged by
  `DeadlineTimerTests.schedulingReplacesAndCancellingDrops`, whose "nothing
  arrived after the deadline passed" assertion is the behavioral claim; the
  `isPending` line beside it is not.
- **PO4** (I2). A corrupt or foreign-pane record does not survive a load.
  Already discharged by `PaneReplicaCheckpointStoreTests`.
- **PO5** (I3). Cancel clears the in-flight attempt and rests until a gesture.
  Already discharged by the cancel half of
  `ReconnectEpisodeTests.restAfterBackgroundingAndCancel`, which is unchanged.

No new test. This is subtraction: the remaining suites passing untouched is the
evidence that nothing behavioral was carried by the deleted symbols.

**Verification.** `swift test --package-path ios/DanTermMobileKit` and
`./scripts/ios-portability-gate.sh`. Both are already steps in `just test`, so
the gate covers this change end to end.

## Non-goals

- Building the phone's stop control. `userCancelled` keeps its case, its
  `handle` branch, and its test; only its doc comment changes.
- Any change to `MobileConnectionState`. The case IOS-5 named is already gone.

## Rejected ideas

- **A gate step that fails when a public kit symbol has no caller outside the
  test target.** It cannot distinguish dead code from designed behavior whose
  producer is not built yet, which is exactly `userCancelled`. It would either
  fail on that case -- making a lint the reason to delete working design -- or
  need a per-symbol opt-out marker, and once that marker exists it does the
  whole job on its own. I3's doc comment is that marker, without the gate.
  Separately, the sweep is only tractable because the kit has one consumer
  (`ios/DanTermMobileApp`); it would not generalize to `lib/TerminalCore`, whose
  consumers include benchmark targets and un-gated research scripts, so a
  kit-scoped gate would read as a tree-wide guarantee it does not give.

## Implementation discretion

- Whether `ResumePolicyTests`' checkpoint-building helper survives. It exists
  only to feed the deleted API; with the assertions on a Bool, nothing in that
  file needs a checkpoint value.
