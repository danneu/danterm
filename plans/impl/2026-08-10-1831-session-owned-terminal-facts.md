# Session-Owned Terminal-Reported Facts: the SessionModel Migration

## Context

Terminal-reported facts about a pane live in two owners today: values (title,
cwd, progress) as `PaneModel` fields, and lifecycles (command, connection,
agent, integration) in a runtime-owned `PaneLifecycleStream` that pure code
reads through a sampled `PaneLifecyclesView` argument. The split is governed by
`docs/design/2026-08-10-terminal-reported-pane-facts.md`, whose D1 test is
subtle enough that it exists specifically to stop facts being placed by
accident. The dual ownership also forces compensating apparatus: the
`livePaneState:` parameter on `update()`, the checkpoint recovery graft
(`PaneLifecycleRecoveryState` + `graftLifecycleRecovery`), and the reentrant
`Command.applyPaneLifecycleIpc` reply-ordering convention.

This migration dissolves the boundary: every terminal-reported fact ends with
its terminal session, so a session owns all of them. A new pure `SessionModel`
in `DanTermCore`, carrying a typed `SessionId` and nested in the pane it serves,
holds them all; value vs lifecycle decides only reduction behavior inside the
session, not ownership. The old ADR's Rejected section named the two proofs this
design owes, and the design supplies both: session-end cleanup becomes
structural (the session dies with the pane's leaf), and agent IPC reply ordering
becomes structural once the reducer runs inside `update()`.

Decisions made with the user:

1. **Pane and session lifecycle behavior is unchanged.** Session end still
   closes the pane (engine ADR F9 stands); the model merely becomes
   replacement-ready. Two observable differences are accepted deliberately:
   post-restore checkpoint bytes now preserve the recovery memo, and the IPC
   agent-event error for a vanished pane becomes the standard "pane not found"
   (both detailed under Accepted risks).
2. **All reports session-keyed.** Values, lifecycles, bell, and desktop
   notification all arrive as session-keyed Msgs; a report carrying an unknown
   `SessionId` is dropped purely.
3. **One unified report reducer.** Flat `SessionModel` fields, one
   `SessionReport` vocabulary, one pure reducer: values assign, lifecycles keep
   the ordered rules currently in `PaneLifecycleReducer.swift`.
4. **Persistence becomes a pure projection.** `SessionModel` absorbs the
   recovery memo (`lastCommand`, `lastAgentSession`); the graft apparatus is
   deleted. The scrollback graft stays (engine-owned text).

## Decision

### Types (DanTermCore)

- `SessionTag` / `typealias SessionId = TypedId<SessionTag>` beside the other
  tags in `Model.swift`. Minted via `SessionId(rawValue: env.newId())`
  wherever a `PaneId` for a fresh session is minted (createTab, splitPane,
  restore decode).
- `SessionModel` carries its own `id: SessionId` -- the session is identified by
  the value, not by a key in a table:
  - values: `title` (default "Terminal"), `cwd`, `progress` -- assignment.
  - lifecycles: `integration`, `command`, `connection`, `agent` -- the
    existing enum types and ordered rules, unchanged.
  - recovery memo: `lastCommand` (set on commandStarted, never cleared by
    commandEnded), `lastAgentSession` (set on attach, cleared on accepted
    detach, seeded on restore without a live `agent` attachment). Stored, not
    derived: restore must represent "restorable but not attached".
- **The pane owns its session by nesting: `PaneModel.session: SessionModel?`.**
  There is no session table and no foreign key. A pane owns zero or one
  session; removing the pane's leaf removes the session with it; detaching
  assigns nil; replacing a session assigns one nested value. `PaneModel` keeps
  `id`, `theme`, `fontSizeSteps`, `todos` and loses `title`, `cwd`, `progress`.
- Lookups on `AppModel` beside `pane(_:)`: the pane owning a given `SessionId`
  (tree scan by `session?.id`, no stored index -- the same asymptotic cost as
  resolving a report's target pane under any keying), and a mutating accessor
  for a pane's session.
- Fresh sessions seed `title` from `launch.title` when the launch supplies one,
  in both createTab and splitPane -- the behavior `PaneModel.title` carries
  today. This moves with `title` itself, so the fact never has two owners even
  mid-sequence.
- `SessionReport` enum: value cases (`title`, `cwd`, `progress`) + lifecycle
  cases (the nine current `PaneLifecycleEvent` transitions). Bell and desktop
  notification are NOT report cases -- they are stateless occurrences, kept as
  separate session-keyed Msgs so the reducer stays total.
- One pure reducer over `SessionModel` replaces `reducePaneLifecycles`; memo
  coupling lives inside the same acceptance guards. `PaneLifecycleStream`,
  `PaneLifecycleTransition`, `PaneLifecycleRecoveryState`, `PaneLifecyclesView`,
  and `PaneLifecycleEvent` are deleted.

### Msg and Command surface

- New: `.sessionReport(sessionId:report:)`, `.sessionBell(sessionId:)`,
  `.sessionNotification(sessionId:title:body:)`, `.sessionEnded(sessionId:)`,
  `.sessionCreationFailed(sessionId:)`.
- Deleted: `.sessionTitle`, `.sessionCwd`, `.sessionProgress`,
  `.paneLifecycleChanged`, pane-keyed `.sessionBell`, `.desktopNotification`,
  `.sessionClosed`, pane-keyed `.sessionCreationFailed`.
- Search and `.paneBecameFirstResponder` stay pane-keyed (model-owned
  lifecycle / view fact, per both ADRs).
- `.sessionReport` handling in `update()`: resolve the owning pane by session id
  (unknown id drops purely); one admission gate in `TerminalMetadataBounds.swift`
  covering the title, cwd, command, and remote-identity byte limits (relocated
  from the runtime's per-event guards); reduce; compute `didChange` by
  before/after struct comparison. The
  `.agentActivityChanged(_, .waiting)` background-pane alert fires only when
  `didChange` -- this gate is mandatory because the runtime's old `didChange`
  Msg filter is gone (without it, repeated identical activity reports spam
  alerts).
- `Command.createSession(sessionId:paneId:cwd:command:launchCommand:)` --
  gains `sessionId`, loses the dead `waitAfterCommand`.
- `Command.applyPaneLifecycleIpc` deleted: `agent.attach` / `agent.activity` /
  `agent.detach` reduce inside `dispatchIpc` (recursive `update` with the
  session report) and append `.ipcReply` in the same command list. Ordering is
  structural: the model reflects the transition when the reply command exists,
  and commands perform in emission order. Reply stays unconditional `ok`,
  matching today.
- `Msg.coalescesReconcile`: same partition re-expressed -- value reports,
  command start/end, and activity coalesce; integration/remote/attach/detach
  stay inline; bell/notification coalesce.
- Runtime `sessions` dict stays keyed by `PaneId` (all outbound commands are
  pane-addressed; `reconcileSessionExistence` diffs against `model.allPaneIds`
  unchanged). `SessionId`'s runtime job is inbound tagging only:
  `perform(.createSession)` wires `onEvent` with both ids captured.

### Chrome and projections

- `TabModel.title` / `subtitle` / `displayTitle` computed properties and
  `deriveTabChrome(from: PaneModel)` are replaced by model-level lookups in
  `ModelOperations.swift` that derive chrome from the focused pane's session
  (no session -> ("Terminal", nil)). Deleting the computed trio makes the
  compiler enumerate every consumer (sidebar, switcher, window title, alert
  location, IPC `tab.title`); all already hold `model`.
- `desiredPaneToolbar`, `desiredPaneConfig`, `alertPresentation`, and
  `windowTitle` drop `livePaneState:` and read the pane's session.
  `effectiveTheme` takes the session's `connection`. The pane command chrome
  text takes the running-command string directly, so `PaneWrapperView` no
  longer re-inflates a `PaneLifecycles` value.
- `currentCwd(in:)`, splitPane inheritance, and `tab.new` caller-cwd
  inheritance read the source pane's session -- still pure and synchronous.

### IPC projection

`IpcEntityEncoder` reads each pane's session directly, and the pane inspection
fields emit the identical flat `command` / `connection` / `agent` /
`integration` objects, with identical defaults for a pane with no session. The
flat wire shape (`title`, `cwd`, plus the four objects) is byte-identical; the
exact-shape tests in `UpdateIpcTests.swift` must pass with assertions
unchanged.

### Persistence and restore

- The pane snapshot takes title/cwd/`command: lastCommand` /
  `agentSession: lastAgentSession` from the pane's session, and
  theme/todos/fontSizeSteps from the pane. `PaneSnapshot` on-disk shape
  unchanged.
- Light checkpoint becomes `toSnapshot(model)` alone. Deleted:
  `graftLifecycleRecovery`, `captureLifecycleRecovery`,
  `LightCheckpointProjection`'s recovery dict. Scrollback graft and the
  enriched tier untouched.
- Restore mints a `SessionId` per leaf and seeds the nested session with the
  snapshot's title, cwd, and recovery memo, lifecycles at defaults (`agent:
  .none` -- restorable, not attached). Restored chrome is identical to today,
  and the minted sessionId is passed into event wiring.

### Runtime

`SwiftTerminalSessionView` and the `TerminalSession` protocol lose
`lifecycleStream`, `lifecycleRecovery`, `applyLifecycleEvent`,
`lifecycleSnapshot`, `lifecycleRecoverySnapshot` -- the runtime owns zero
terminal-reported state. `TerminalSessionEvent` collapses its state-bearing
cases into `.report(SessionReport)`; `terminalMessages(for:sessionId:paneId:)`
lowers report/bell/notification/closeRequested session-keyed and
search/first-responder pane-keyed, with no `didChange` filter (the reducer
refuses no-ops). `AppRuntime.livePaneStateView` and both `Reconcile.swift`
view-passing call sites are deleted; `update()` becomes
`update(&model, msg, env:)`.

### ADR

New ADR (commit 1) whose decision is: a session owns every terminal-reported
fact because the fact ends with that session; the pane owns its session by
nesting, so an orphan session is unrepresentable; value vs lifecycle determines
reduction behavior, not ownership; `PaneModel` contains no copied session
state; IPC and persistence are projections; explicit `SessionId` makes a late
report from a dead or replaced session structurally droppable. It records the
two proofs the old ADR demanded. Old ADR keeps `Status: Accepted`, gains
`Superseded by:` + dated blockquote note (house pattern); `docs/design/
index.md` row added; AGENTS.md reading-table row re-pointed. Point-of-edit
code comments citing D1/D2/D3 are re-pointed in the commit that transforms
their file.

## Invariants

- I1: a session exists only as a pane's nested value, so there are no orphan
  sessions and no session attached to two panes. Removing a pane removes its
  session structurally, in the same tree mutation.
- I2: every `SessionId` minted in a live model is distinct, so resolving a
  session id yields at most one pane.
- I3: under current behavior every tree pane has a session from birth to death;
  the Optional is the replacement-ready seam, and all pure consumers render
  session-less defaults ("Terminal", nil cwd, idle/local/none/neverReported).
- I4: a session-keyed Msg whose `SessionId` matches no live session -- report,
  bell, notification, session-end, or creation-failure alike -- changes nothing
  and emits nothing.
- I5: an agent IPC reply is emitted only in a command list produced by the
  same `update()` pass that reduced the transition it reports.
- I6: the flat IPC pane shape and the `PaneSnapshot` on-disk shape are
  unchanged by this migration.
- I7: a report exceeding the metadata byte limits is refused in `update()`, for
  every bounded string (title, cwd, command, remote identity, notification
  text).

## Proof obligations

- I1/I2: after each pane-removal Msg, no session survives its pane, and every
  live session id is unique (SessionStoreTests), plus the restore-seeding test.
- I4: for both an unknown and a replaced `SessionId`, each of `.sessionReport`
  (lifecycle and value variants -- "a title report from a replaced session does
  not retitle the replacement"), `.sessionBell`, `.sessionNotification`,
  session-end, and `.sessionCreationFailed` changes nothing and emits nothing.
  Three of these need their own cases rather than a shared one: bell and
  notification alert the user, so misrouting them is visible rather than merely
  wrong, and creation-failure closes a pane, so a stale one would destroy the
  replacement's live state.
- I5: rewritten agent IPC tests asserting reply and reduced state in one
  command list; repeated `.agentActivityChanged(.waiting)` produces one alert.
- I6: the two exact-shape IPC tests pass with assertions unchanged;
  SnapshotTests round-trip snapshot -> restore -> light projection -> identical
  snapshot.
- I7: a core-level admission test replacing the deleted
  `PaneLifecycleRoutingTests` coverage -- at-limit strings admitted and
  over-limit strings refused, for title, cwd, command, combined remote identity,
  and notification text. This must land in the same commit that removes the
  runtime guard, or the byte contract is briefly untested.
- Fresh sessions inherit `launch.title` in both createTab and splitPane; the
  existing `UpdateIpcTests` cases pinning this stay green.
- Split/tab cwd inheritance: set cwd via a session report, split, assert the
  emitted `createSession`.
- Pane-owned content unaffected: CustomTitleTests, UpdateThemeTests,
  UpdatePaneFontSizeTests, UpdateTodoTests, UpdateSearchTests stay green with
  near-zero diff.

## Non-goals

- Restart / hold-open / detached-pane features: session end still closes the
  pane; engine ADR F9 stands.
- Exposing `sessionId` over IPC or persisting it; restore mints fresh ids.
- Re-keying search, first-responder, or any user-initiated Msg.
- `ProgressState` range-typing (carried accepted risk from the 1701 plan).

## Accepted risks

- **Post-restore checkpoints now preserve `lastCommand` / `lastAgentSession`.**
  Today the first checkpoint after restore drops them (the graft overwrites
  with freshly-empty runtime state). Seeding makes restore -> checkpoint
  idempotent -- a deliberate improvement, but changed bytes on disk.
- **IPC agent-event error for a vanished pane changes message**: standard
  "pane not found" instead of `-32603 "pane session no longer available"`.
- **No-op lifecycle reports now traverse `update()`** (the runtime `didChange`
  filter is gone); cost is one no-op update per redundant report, plus a
  reconcile scheduled by that report's case in the coalescing partition,
  bounded by envelope cadence.
- **GoldenMasterTests regenerates in commits 2, 3, and 4** (id-sequence shifts
  and dump-shape changes). Review each dump diff against that commit's
  intended model change; never blind-record. The fixed id sequence in
  `makeTestEnv` may need widening.
- **tests-ui churn**: both shims lose stream members and `test-ui.sh`'s
  hardcoded source list must mirror file deletions/renames; `just test-ui`
  runs explicitly after commits 3 and 4 since the gate cannot catch it.
- **Coalescing re-derivation** happens twice (commits 3 and 4); the
  reconcileDecision test is updated first each time.

## Rejected ideas

- Dual-write staging (runtime stream and model reducer both live during a
  transition commit): two owners is the disease this migration cures.
- A `[SessionId: SessionModel]` store with `PaneModel.sessionId` as a foreign
  key, or a stored reverse `[SessionId: PaneId]` index: both make orphan
  sessions and attachment disagreement representable, and buy nothing --
  resolving a report needs the owning pane anyway, so the dictionary saves no
  tree scan.
- Values-first sequencing: the intermediate state holds exactly the facts
  whose session-scoping the old ADR denies while the genuinely session-scoped
  facts still live in the runtime.
- Bell/notification as `SessionReport` cases: they store nothing; vacuous
  reducer arms would make the reducer non-total.
- A compatibility shim keeping pane-keyed value Msgs beside session-keyed
  ones: one user, no compat constraint.

## Critical files

- `lib/DanTermCore/Sources/DanTermCore/` -- `Model.swift` (SessionId, nesting,
  TabModel chrome removal, restore seeding), `Update.swift` (new Msg arms,
  unified admission + reducer, IPC agent dispatch), `PaneLifecycleReducer.swift`
  and `PaneLifecycleConsumers.swift` (become the session reducer and session
  inspection), plus `Msg`, `Command`, `Persistence`, `CheckpointCapture`,
  `Projections`, `AlertPresentation`, `ModelOperations`, `IpcEntityEncoder`,
  `TerminalBackendBoundary`, `TerminalMetadataBounds`.
- Deleted: `PaneLifecyclesView.swift`, `PaneLifecycleRecovery.swift`,
  `app-tests/PaneLifecycleRoutingTests.swift` (its byte-limit coverage moves to
  the core admission test).
- `app/{AppRuntime,SwiftTerminalSessionView,TerminalSession,Reconcile,
  PaneWrapperView}.swift`;
  `tests-ui/{SidebarViewTestShim,SwiftTerminalSessionViewTestShim}.swift` +
  `tests-ui/test-ui.sh` source list.
- `docs/design/` new ADR + superseded note + `index.md`; `AGENTS.md` reading
  table.

## Verification

- `just test` green at every commit boundary; `just test-ui` run explicitly
  after commits 3 and 4.
- Live slot after commits 3 and 4: `just launch-slot`, then with an explicit
  `danterm --socket`: `ls` / `pane info` flat shape identical to
  pre-migration for the same state; agent attach/activity/detach round-trip;
  run a command, split, confirm cwd inheritance; kill a shell, confirm the
  pane closes; checkpoint -> relaunch -> restored title/cwd/todos present.
- Final greps return nothing in executable vocabulary: `PaneLifecyclesView`,
  `livePaneState`, `applyPaneLifecycleIpc`, `graftLifecycleRecovery`,
  `PaneLifecycleEvent`.
- `integrations/danterm/SKILL.md`: verify against the live slot that no change
  is needed (flat shape preserved); do not assume.

## Commit progress

- [x] 1. docs: supersede terminal-reported-pane-facts with the session-owned
  facts ADR
- [x] 2. core: add SessionId and the pane-nested SessionModel (mint on
  create/restore; no facts move yet; SessionStoreTests + GoldenMaster regen)
- [x] 3. core!: reduce session lifecycles inside update(); runtime stops
  owning terminal-reported state (SessionReport lifecycle cases, unified
  admission with its byte-limit test, agent IPC in-pass reply, delete
  PaneLifecyclesView/applyPaneLifecycleIpc/graft apparatus and
  PaneLifecycleRoutingTests, tests-ui shims)
- [x] 4. core!: move title, cwd, and progress into SessionModel; chrome and
  persistence read the pane's session (value report cases, launch.title
  seeding, bell/notification re-key, TabModel chrome lookups, restore seeding,
  exact-shape IPC tests
  unchanged)
- [x] 5. docs: re-point residual references and comments (fold into 4 if
  trivially small)
