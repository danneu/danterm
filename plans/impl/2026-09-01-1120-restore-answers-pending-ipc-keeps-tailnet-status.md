# Restore answers its pending IPC work and keeps the process facts

## Context

UPDATE-4 in `docs/scratch/2026-08-26-improvement-audit.md`, re-verified live
2026-09-01. The `.restoreSession` arm (`Update.swift:915-922`) installs a whole
staged `AppModel` over the live one and carries only `noticeQueue` and
`isAppActive` (the runtime carries `config` and `resolvedFontFamily` at stage
time), so every other field resets to its default. Two live bugs:

1. `tailnetStatus` resets to the disabled default. `IpcServer.publish`
   (`IpcServer.swift:316-320`) only publishes transitions of the server's own
   copy, so nothing re-sends the wiped value: after a recovery-prompt restore or
   File > Import State, `danterm tailnet status` and the preferences Listener
   row report no listener for the rest of the process.
2. `pendingSessionCreations` and `pendingInputSubmissions` are wiped unanswered:
   a `danterm tab new` or `danterm pane input` in flight when a restore commits
   hangs forever.

This is the pivot, not the audit's ideal. The full session/process split of
`AppModel` misclassifies the pending maps: `commitRestoreSession` destroys the
sessions those requests wait on, so they must be answered, not carried,
whichever half they live in. The split stays a Wave 15 item, to be re-pitched on
the corrected census. UPDATE-2 has since landed the per-pane rejection machinery
and its cause vocabulary (`tearDownPanes` / `rejectPendingIpcWork` /
`PendingIpcRejectionCause`, `Update.swift:1948-2032`), while
`.runtimeWillShutdown` (`Update.swift:927-944`) still words its own wholesale
rejection inline.

## Decision

- In the `.restoreSession` arm: carry the live `tailnetStatus` onto the
  installed model, and answer every pending IPC request in the live model
  before the staged model replaces it.
- Unify wholesale rejection: `.runtimeWillShutdown` and `.restoreSession`
  answer-and-clear both pending maps through one shared path, each naming its
  own cause in the existing cause vocabulary, so no site can word the ritual
  differently or perform half of it.
- Shutdown replies keep their current text verbatim; restore replies name the
  restore as the cause, in parallel phrasing, with the same error code
  (-32603).

## Invariants

- I1: a session restore preserves the process facts the reducer arm is
  responsible for: `isAppActive`, `noticeQueue`, and now `tailnetStatus`.
  (`config` and `resolvedFontFamily` reach the arm already carried at stage
  time; that carry is outside this change.)
- I2: no pending IPC request is silenced: when a restore commits, every request
  pending in the live model -- including one attached to no live pane --
  receives exactly one `.ipcError` reply, and a multi-submission input request
  is answered once, not once per submission.
- I3: shutdown behavior is unchanged: `.runtimeWillShutdown` still answers both
  maps once per request with its existing wording.

## Proof obligations

- PO1 (I1): dispatch `.tailnetStatusChanged(.listening(...))`, then
  `.restoreSession` with a snapshot-built model; the installed model still
  reports listening. Existing `UpdateRestoreTests` cover `isAppActive` and
  `noticeQueue`; the stage-time appearance carry keeps its helper-level test
  (`UpdatePaneFontSizeTests`).
- PO2 (I2): with a pending session creation, a multi-item pane-input request in
  flight for a live pane, and a multi-submission input entry whose pane is
  absent from the live tree, `.restoreSession` returns one `.ipcError` per
  request -- code -32603, message naming the restore -- plus the install
  command, and both maps are empty after. Mirror
  `runtimeShutdownRejectsEveryPendingPaneEffect`
  (`UpdateSessionEventTests.swift:90-127`).
- PO3 (I3): the shutdown rejection test pins code -32603 and both existing
  shutdown messages verbatim -- `runtimeShutdownRejectsEveryPendingPaneEffect`
  today checks only request ids and map clearing, so extend it before the
  unification -- and it stays green through the refactor.

## Non-goals and accepted risks

- The `AppModel` session/process split (UPDATE-4's ideal). Separate Wave 15
  work; its write-up needs the corrected premise that the pending maps are
  answer-obligations, not carryable process state.
- Carrying the pending maps across a restore -- rejected: the sessions those
  requests wait on are destroyed by the restore, so a carried entry can never
  complete.
- Re-publishing tailnet status from the server after a restore; the carry makes
  it unnecessary.
- Carrying any other reset field (`alerts`, popover/panel state, `focusClock`,
  `sidebar`): resetting them with the session is correct today.
- AR1 (accepted risk): no end-to-end test pins that the app runtime applies the
  stage-time appearance carry during staging; the helper-level test is the
  guard. The runtime layer sits outside the gate's unit suites, and this change
  does not touch the staging path.

## Files

- `lib/DanTermCore/Sources/DanTermCore/Update.swift` -- the `.restoreSession`
  and `.runtimeWillShutdown` arms, the cause vocabulary, the rejection helpers.
- `lib/DanTermCore/Tests/DanTermCoreTests/UpdateRestoreTests.swift` -- PO1, PO2.
- `docs/scratch/2026-08-26-improvement-audit.md` -- when this lands, annotate
  the Wave 15 UPDATE-4 checklist entry: correctness half done via this pivot,
  split remains open.

No CLI surface change: the error path and code already exist, and SKILL.md does
not document per-cause wording.

## Verification

- TDD: write PO1 and PO2 first and watch each fail for its stated reason
  (tailnet resets to the disabled default; no `.ipcError` commands returned).
- `swift test --package-path lib/DanTermCore --filter UpdateRestoreTests` and
  `--filter UpdateSessionEventTests`, plus `just lint`, in the loop.
- `just test` before the commit.

## Implementation discretion

- The shared rejection path's name and shape, provided I2's totality holds (the
  map sweep, not a pane walk, is what answers orphaned entries -- as shutdown's
  sweep does today).

## Implementation notes

- The shared path is `rejectAllPendingIpcWork(in:cause:)`, a map sweep beside
  the per-pane `rejectPendingIpcWork`, and the two wholesale causes join the
  existing `PendingIpcRejectionCause` vocabulary as `.applicationShutDown` and
  `.sessionRestored`. The restore's parallel phrasing is "session restored
  before the pane process started" / "session restored before pane input was
  delivered".
