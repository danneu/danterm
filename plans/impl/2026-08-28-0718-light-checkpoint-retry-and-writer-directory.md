# Light checkpoint retry, one persisted-state compare, and a writer that owns no directory

Audit items PERSIST-4, PERSIST-3, SUPPORT-1 from
`docs/scratch/2026-08-26-improvement-audit.md` (Wave 10).

## Problem and evidence

Three obligations sit on call sites instead of on the value that should carry
them.

1. The light checkpoint tier advances `lightCheckpointBaseline` when it hands
   work to the writer and passes no completion
   (`app/AppRuntime.swift#performLightCheckpoint`). A failed write leaves a
   stale file on disk that is never rewritten until some *other* state
   changes. The enriched tier retries through
   `RecoveryCheckpointPolicy.writeCompleted(revision:succeeded:at:)`. Two
   tiers, one job, two rules.
2. `scheduleLightCheckpointIfNeeded` snapshots and deep-compares the whole
   model on every `send()` to decide whether to arm a 2 s window, although
   `performLightCheckpoint` compares again at fire time and writes nothing on
   equality. `retractionIsLive` exists only to keep typing away from that
   per-message snapshot. Per-snapshot cost is already measured
   (`just checkpoint-projection-cost`, under its 417 us limit); the value of
   this change is the deletion, not a recovered millisecond.
3. `CheckpointWriter.write` calls `PrivateFile.createDirectory` on the parent
   of whatever URL it is given, and that seam narrows an existing directory
   to 0700. The state export hands it a folder the user picked in
   `NSSavePanel` (`app/AppRuntime.swift`, `.exportState` arm). So an export
   chmods the user's folder, and fails outright with EPERM when the user can
   write the folder but does not own it (`/Users/Shared`). The recovery
   directory is already created at launch by `writeSessionLockFile`
   (`lib/DanTermSupport/.../RecoveryStore.swift`), and the save panel has
   `canCreateDirectories = true`, so no caller needs the writer to create
   anything.

## Decision

- Hold the light tier's baseline and its retry rule in one pure value in
  `DanTermCore`, shaped like `RecoveryCheckpointPolicy`: it yields the
  capture to write (or nothing) for the current projection, advances at
  handoff, and clears when told the write failed. `AppRuntime` stops
  owning a baseline field. The light completion is guarded by
  `schedulingLifecycle` the same way the enriched tier's is, so the two
  tiers share one lifetime rule as well as one retry rule.
- Arm the light window on any `send()` while no window is armed and the
  lifecycle is active. The persisted-state comparison happens in exactly
  one place: the fire-time capture. Delete `retractionIsLive`.
- `CheckpointWriter.write` does two things -- encode, then
  `PrivateFile.writeAtomically` -- and touches no directory. Directory
  ownership stays where it is: the recovery directory with
  `writeSessionLockFile`, the export destination with the user.

## Invariants

- I1. A failed light write invalidates coverage only when no later handoff
  superseded it; the next fired window then writes the current projection
  (never a stale one). After a successful write, an unchanged projection
  writes nothing. Handoffs are identified, as the enriched tier's are, so
  an old failure cannot clear a newer handoff's coverage.
- I2. Apart from retrying the latest failed handoff (I1), no message can
  cause a light write that would not happen today: a window that fires on a
  projection equal to the covered baseline writes nothing, the policy starts
  with the launch projection covered, and an armed window is never postponed
  by traffic.
- I3. A checkpoint or export write never changes the mode of an existing
  directory. The file itself is still created 0600.
- I4. Both checkpoint tiers, the lock, and the audit log still land in the
  recovery directory that `writeSessionLockFile` creates 0700.

## Proof obligations

- PO1 (I1, I2): core-suite test on the light policy value: a policy started
  on projection A yields no work for A; capture B, report failure, capture B
  again and get work; report success, capture B, get nothing. Overlapping
  trace: capture B, capture C, then B's failure arrives -- C stays covered
  and capturing C yields nothing; C's failure arriving instead yields work
  for the current projection.
- PO5 (I1, runtime seam): `DanTermAppTests` (`app-tests/`, in `just test`,
  with `TemporaryInstancePaths` and the existing runtime fixtures): make one
  light write fail, restore writability without changing persisted state,
  fire another window, and assert the same projection lands on disk. Fails
  today.
- PO2 (I2): existing `CheckpointCaptureTests` and the runtime checkpoint
  tests stay green; `just checkpoint-projection-cost` runs once after the
  change as a control that the fire-time compare did not regress. No timing
  claim is made in the commit.
- PO3 (I3): `CheckpointWriterTests`: a write into an existing 0755 directory
  leaves it 0755 and the file 0600. Fails today.
- PO4 (I4): `RecoveryStoreTests` "a lock written into a world-readable
  directory narrows both" already covers the directory half;
  `InstancePathsTests` "both checkpoint tiers ... land in one directory"
  must create the directory via `writeSessionLockFile` before the checkpoint
  writes. The two `CheckpointWriterTests` assertions that the *directory*
  comes out 0700 are deleted; their file-mode assertions stay.

## Accepted risks

- AR1. If `claimSessionLock` fails at launch the recovery directory may not
  exist and both tiers fail for the run; the light tier then retries every
  window with a cheap failed open. The handshake already surfaces that
  failure to the user. Say so in the SUPPORT-1 commit message.
- AR2. A chatty session with no persisted change now fires one timer per
  2 s and finds nothing to write.

## Non-goals

- Reporting a failed recovery write to the user.
- Any change to `IpcAuditLogWriter`, `ControlSocketListener`, or the
  scrollback replay writer, which create parents under instance-owned paths.

## Implementation discretion

- Whether the light completion feeds the policy through the existing
  `applyRecoveryAction` shape or a sibling; only I1 and the shared
  lifecycle guard are contract.

## Commit progress

- [x] 1. fix(checkpoint): retry failed light writes without per-message projection
- [x] 2. fix(persistence): stop checkpoint writes from mutating destination directories
- [x] 3. docs(audit): record the persistence fix commits

## Implementation notes

- The light policy reports its outcome through its own `writeCompleted`, not through
  `applyRecoveryAction`: the enriched action enum is about timers, and the light tier
  arms its window from `send()` rather than from an outcome. Implementation discretion
  in the plan allowed either shape.
- A failed light write does not arm a window of its own. It withdraws coverage, and the
  next armed window writes -- which is what I1 states. A session that goes completely
  silent right after a failed write therefore keeps the stale file until the next
  message, the same exposure the tier had before this change.
- `performLightCheckpoint` now checks `schedulingLifecycle.isActive` before it captures,
  as `performEnrichedCheckpoint` already did, so the policy cannot take coverage of a
  projection whose completion token shutdown would then refuse.
- `AppRuntimeAlertAgeRefreshTests` counted every armed `.timer`. A message now always
  arms the light window, so its assertions became deltas, matching the pattern
  `AppRuntimeCoalescedReconcileTests` already used for the same reason.
- PO2: `just checkpoint-projection-cost` ran once after the change and passed
  (`verdict=pass`; per-scenario medians 224/226/274 us against the 417 us limit). No
  timing claim is made in the commit.
- The writer's directory create was load-bearing for four test fixtures, which the plan's PO4
  named only for `InstancePathsTests`. Each one now takes the launch step that creates the
  directory in the app: `CreatedFilePrivacyTests` and the runtime checkpoint test in
  `AppRuntimeSessionCommandTests` call `claimSessionLock`, and `LaunchRecoveryTests`'
  `RecoveryFixture` creates the directory itself, because claiming a lock there would change
  what the handshake tests observe.
- `CheckpointWriterTests` creates its own temporary directory in the shared helper. The
  0700-directory assertions are gone per PO4, and the narrowing test now asserts the opposite
  for the directory: a 0755 destination comes out 0755, which is PO3.
