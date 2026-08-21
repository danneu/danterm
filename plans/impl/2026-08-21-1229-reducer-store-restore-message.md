# Put `AppModel` behind a reducer store and make restore a `Msg`

Source: RUNTIME-1 in `docs/scratch/2026-08-18-construction-audit.md`
(verified against HEAD `f9d4417a` on 2026-08-21).

## 1. Problem, outcome, evidence

**Problem.** Session restore and import (`app/AppRuntime.swift#commitRestoreSession`,
reached from launch `--init`, the launch recovery prompt, and File > Import)
replace the whole application model without going through `update()`. Because
the assignment skips the reducer, the commit hand-replays part of what the
reducer's `defer` block does for every other message -- and only part:
`update()` runs five normalizers (`reconcileTabState`, `reconcileFocusedPaneAlerts`,
`reconcileTodoPopover`, `reconcilePendingConfirmation`,
`reconcileSidebarRenameTarget`); the commit replays one. Every future
normalizer must be remembered a second time on this path, and nothing makes the
omission visible. Two side effects of the bypass are already recorded elsewhere
as accepted risks: notices queued when a restore commits are dropped with the
rest of the model, and the launch prompt keeps the IPC server closed because an
IPC-driven `update()` could race a wholesale model replacement
(`plans/impl/2026-08-20-0210-runtime-notice-panel.md`, AR2 and AR4).

**Desired outcome.** A small reducer store privately owns `AppModel` and exposes
only a read-only value plus `dispatch(_:)`, whose only mutation is through
`update()`. `AppRuntime` holds the store as a `let` and exposes the model only
for reading. Restore and import deliver a validated model to the store as a
`Msg`; the reducer installs it, normalizes it the way it normalizes every other
state, and returns a command that swaps the live pane-host table for the staged
one. The runtime's restore code shrinks to staging plus one dispatch.

**Evidence (all re-verified at HEAD).**
- Only two writes into `model` exist outside `init` in `app/`:
  `tearDownCurrentSession` (`model.todoPopover = nil`) and `commitRestoreSession`
  (`model = staged.model`). The first is dead: it writes the old model one
  statement before the whole model is replaced, and a snapshot-built model never
  carries a `todoPopover`.
- `commitRestoreSession` open-codes the send frame: baseline reset, cancel
  coalesced sweep, `reconcileTabState(&model)`, sweep + drain.
- Prerequisite RUNTIME-3 landed (`b93df543`): the launch prompt is a projected
  notice, answered through `.noticeAnswered` -> `.resolveLaunchRestore` ->
  a main-queue hop -> `bootstrapFromValidatedRestore`. All three commit callers
  (that hop, `bootstrapFromSnapshot` at launch, the import sheet completion) run
  outside any send frame, so a `send` from them opens a clean frame.
- `dispatchInFrame` performs commands before it reconciles, so a command that
  swaps the host table runs before the first post-restore sweep with no extra
  mechanism.
- Precedent for a runtime-held payload read by a payload-free command:
  `pendingLaunchRestore` + `.resolveLaunchRestore`.
- Test sites assign to `runtime.model` and its fields directly
  (`app-tests/AppRuntimeAutosplitTests.swift`, `AppRuntimeIpcCommandTests.swift`,
  `AppRuntimeDialogSurfaceTests.swift`, `AppRuntimePendingIpcShutdownTests.swift`,
  `tests-ui/AppPresentationLifecycleTests.swift`); these tests can instead give
  the runtime its initial model or use production messages after construction.
- No open plan, branch, or worktree touches the restore commit, `Update.swift`,
  `Msg.swift`, or `Command.swift`.

## 2. Decision

**Direction.** Add a small reducer store that privately owns `AppModel`, exposes
it as a read-only value, and offers one mutation entry point that calls
`update()`. `AppRuntime` owns the store immutably and dispatches normal messages
and shutdown through it. Add a reducer message carrying the validated, staged
`AppModel` (pure core, so it crosses no purity boundary). The `update()` arm
installs it, carries the live `noticeQueue` over, and returns one payload-free
command; the runtime performs that command by tearing the live session down and
installing the staged pane-host table it holds in a runtime field.

**Why.** The separate owner makes a direct runtime mutation fail to compile;
`private(set)` on an `AppRuntime` property would still permit every method in
the type to mutate it. This makes "restore forgot what update() does"
unwritable: the normalizers run because the model changed through the reducer,
not because someone remembered. The staging half stays in the runtime, so a
failed build still leaves the live session untouched, and no AppKit type crosses
into the core.

**Behavioral scope.**
- Launch `--init`, the launch recovery prompt (Restore), and File > Import all
  commit through the new message. Their user-visible outcome is unchanged
  except as the invariants below state.
- Notices queued before a restore commits survive it (closes the notice plan's
  AR2).
- A restore or import is checkpointed like any other model change: the command
  arm no longer resets the light-checkpoint baseline. (D1)
- Staging (`stageValidatedRestore`), session construction, replay files, and
  the appearance carry-over (`carryingLiveAppearance`, which must happen
  before sessions are built from the model) are unchanged.

**Decisive constraints.**
- The command that swaps the host table carries no payload: the staged hosts
  live in a runtime field filled by staging and consumed by the command arm.
- The host swap runs before the first post-restore sweep. `dispatchInFrame`'s
  perform-then-reconcile order already guarantees this; the plan relies on it
  and does not add a second mechanism.
- Tests give a runtime synthetic initial model state at construction. Mutations
  after construction use production messages. This keeps tests that seed
  pending submissions, font state, or a model paired with their own terminal
  host from invoking a host-swap command without a staged host table.

## 3. Invariants

- I1. After store initialization, `update()` is the only code that mutates the
  stored `AppModel`. `AppRuntime` and its extensions can read the value but
  cannot assign to it or mutate its fields.
- I2. A restored or imported model is normalized by every reducer normalizer
  before the first sweep sees it: populated `mruOrder` with the selected tab at
  its head, unread alerts on an active focused pane cleared in focus mode, an
  ineligible `todoPopover` retracted, a pending confirmation whose subject is
  gone retracted, and a stale sidebar rename target retracted.
- I3. After the commit, the live pane-host table equals the staged one -- every
  restored pane has a host, and no host from the replaced session survives
  (records, replay files, and scheduled work are torn down as today).
- I4. Notices queued in the live model when a restore commits are still queued
  after it, in order.
- I5. A restore or import that fails during staging leaves the live session,
  the live model, and the live host table untouched.
- I6. The first post-restore sweep is a clean build against reset reconciler
  caches, and the roster is pushed exactly once if it changed.

## 4. Proof obligations

- PO1 (I1): the compiler -- the store's private model, its sole mutation entry
  point, the runtime's immutable store reference and get-only model view, plus
  the gate building `app/`, `app-tests`, and `tests-ui` prove that no runtime or
  test writer exists outside the store.
- PO2 (I2): core test -- send the restore message with a model whose `mruOrder`
  is empty, whose active focused pane has an unread alert in focus-clear mode,
  whose `todoPopover` names an ineligible pane, whose pending confirmation names
  a missing subject, and whose sidebar rename target names a missing row; assert
  all five normalized results and that the returned commands are exactly the
  host-swap command.
- PO3 (I3): app test in the `app-tests/AppRuntimeSessionCommandTests.swift`
  style -- bootstrap twice through the public entry point and assert the host
  table equals the second snapshot's panes; the existing "a whole-session
  restore tears down every live pane and its scheduled work" and the
  re-bootstrap debouncer test stay green.
- PO4 (I4): app or core test -- queue a notice, restore, assert the notice is
  still at the head of the queue and its panel is still projected.
- PO5 (I5): app test -- a staging failure (session creation refused by the
  recording ports) leaves `model`, `paneHosts`, and the census unchanged.
- PO6 (I6): app tests -- after restore, the first `.mruCycleStepped` yields a
  non-nil switcher projection (today's "populated mruOrder after restore"
  behavior, now owed by the reducer); the restore roster test asserts the
  changed roster is pushed exactly once.
- PO7 (checkpoint): app test -- commit a restore whose persisted projection is
  materially different from the prior model, flush the pending light
  checkpoint, and verify the checkpoint file contains the restored state.
- PO8 (launch prompt path): existing `requestRestorePrompt` tests in
  `app-tests/AppRuntimeNoticeTests.swift`, `IpcServerOwnershipTests.swift`, and
  `AppRuntimeDialogSurfaceTests.swift` stay green.

## 5. Non-goals / Accepted risks / Rejected ideas

- N1. Starting the IPC server before the launch prompt is answered (notice
  plan AR4). This plan makes it safe; a follow-up moves it.
- N2. Changing what a snapshot carries or how staging builds sessions.
- AR1. A restore now schedules a light checkpoint of the restored state. Funded:
  it is the state the user would want recovered after a crash, and it removes a
  special case. (D1)
- RI1. Merging the restored session into the live one (keeping IPC-created tabs)
  instead of replacing it. "Restore replaces the session" is the established
  semantic; merging is a different feature.
- RI2. A test-only `model` setter to keep direct-assignment tests
  compiling. It would be a second writer, which is the thing being removed.

## 6. Implementation discretion

- D1. Whether the command arm keeps any baseline bookkeeping at all beyond
  what `dispatchInFrame` already does; the plan only requires that a restore
  is checkpointed.
- D2. Exact names of the message and command, and whether teardown of the old
  session stays one helper or folds into the command arm.

## Critical files

- `lib/DanTermCore/Sources/DanTermCore/Msg.swift`, `Command.swift`,
  `Update.swift` -- the message, the command, the arm (plus
  `noticeQueue` carry-over).
- `app/AppRuntime.swift` -- `commitRestoreSession`, `tearDownCurrentSession`,
  `perform`, the reducer store and read-only model view, initializer injection,
  and the staged-hosts field.
- Tests: `lib/DanTermCore/Tests/DanTermCoreTests/` (new core test),
  `app-tests/AppRuntimeSessionCommandTests.swift` (new app tests),
  `app-tests/AppRuntimeRosterPushTests.swift`, and the seeding sites listed in
  section 1.

## Verification

- `just test` (gate) and `just test-ui > .build/ui.log 2>&1` for the
  `tests-ui` seeding site.
- Manual: `just launch-slot`, create tabs, `danterm --socket <slot> quit`,
  relaunch the slot, choose Restore; then File > Import a state file while a
  notice is queued and confirm the notice stays up and the imported tabs
  appear. `just stop-slot <n>` when done.

## Implementation notes

- `IpcServerRuntimeMessage` carries only the sendable IPC request cases across
  the server-to-main-actor boundary. `AppRuntime` reconstructs `Msg` on the main
  actor, so adding the restore message's `AppModel` payload does not weaken the
  boundary with unchecked sendability.

## Follow Up

- Start the IPC server before the launch restore prompt is answered now that
  restore cannot replace the model outside the reducer (`app/AppRuntime.swift`).
