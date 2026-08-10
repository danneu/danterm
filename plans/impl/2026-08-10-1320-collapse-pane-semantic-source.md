# Collapse the duplicate source of truth for pane semantics

## Problem

The same envelope stream feeds two reducers. The pane-owned semantic stream
(`PaneSemanticStream`, owned per-session by `SwiftTerminalSessionView`) is the
live model that plans/impl/2026-08-10-1113-live-pane-semantic-model.md shipped;
the flat `AppModel.Pane` fields -- `isRemote`, `remoteSession`,
`remoteThemeOverride`, `agentSession`, `lastCommand` -- are mirrors of it, fed
by six legacy Msgs that the boundary now synthesizes *from* semantic
transitions. The pane toolbar already mixes the two (command from the snapshot,
remote/agent chips from the model), and the facet reducer deliberately
decoupled command-end from connection-end, so divergence between the two
answers to "is this pane remote?" is designed in, not hypothetical.

Load-bearing premises, established by exploration:

- Every producer of the legacy Msgs already routes through the semantic
  reducer (`terminalMessages(for:paneId:semanticSnapshot:)` translates
  transitions to Msgs); there is no remaining direct OSC-to-Msg path. Agent
  IPC likewise applies the event on the pane owner first and round-trips the
  transition.
- The engine parser already enforces the 64 KiB semantic value bound before
  events are admitted; the `update()`-side `fitsTerminalMetadataValueLimit`
  guards on command and remote identity are a second, independent layer.
- Checkpoint capture runs on the main actor in both light and enriched paths,
  and `graftScrollback` is the established pattern for pane-owned data
  entering the persisted snapshot. `mergeCheckpoints` copies only scrollback
  from enriched into light, so light must carry everything else itself.
- Restore never rehydrates `lastCommand`/`agentSession` into the model; the
  persisted DTOs are consumed once for launch-env prefill and the agent
  replay hint.
- The init file is not recovery-private. `loadValidatedInitFile` serves three
  surfaces -- checkpoint restore, the `--init <path>` launch flag, and the
  "Import State..." menu item -- against files that "Export State..." writes
  or a user hand-authors; id-less entries are a documented hand-authoring
  convenience. So a format change is a change to a user-facing file format,
  and "our writer always emits X" is never sufficient reason to stop reading
  a field.
- `config.remoteTheme` is non-optional, and `remoteThemeOverride` only ever
  holds it, so the override is a stored copy of a derivable value.

## Decision

Make the connection, agent, and command facets the only representation of
live pane semantics. Delete all five flat fields. Concretely:

- **Consumers read snapshots.** The pane-toolbar projection sources
  remote/agent state from the semantic snapshot map it already receives; the
  pane menu's agent-session read comes from the session's snapshot, not the
  model.
- **Theme becomes pure derivation.** The effective theme is a function of the
  pane's stored theme, the config, and the connection facet: remote panes
  render `config.remoteTheme`; otherwise `pane.theme` falls back to the
  config default. `remoteThemeOverride` and both config-reload recompute
  loops are deleted; the pane-config projection takes the snapshot map and
  reconcile's theme diff applies changes.
- **The boundary collapses to one Msg.** The six legacy Msg cases plus
  `agentNeedsAttention` are replaced by a single message carrying the pane id
  and the semantic transition, emitted for every `didChange` transition.
  `update()` keeps only the product decisions: checkpoint scheduling and the
  waiting-alert path.
- **Checkpoints graft from the pane owner.** The two persisted projections --
  the restore-prefill command and the agent resume hint -- are gathered from
  sessions at capture time and grafted onto the structural snapshot, the same
  shape as the scrollback graft, in the light path, the enriched path, and
  state export. Because the live snapshot deliberately forgets a finished
  command, the pane owner keeps a small pure recovery memo (last started
  command; cleared on teardown) beside the stream -- outside the reducer
  file, whose charter excludes product projections. The persistence codec's
  pane encoder stops reading model fields.
- **The pane DTO loses its redundant and lenient parts.** Two format defects
  sit directly under the encoder being rewritten, so they are fixed here
  rather than left for a follow-up. `PaneLaunchSnapshot` is deleted, and with
  it the second cwd: one pane has one working directory, so the format should
  offer one field to say so rather than a `launch?.cwd`-else-`pane.cwd`
  fallback between two spellings of the same thing. (DanTerm's own writer
  always fills both from the same `abbreviateHome(pane.cwd)` value, so no
  checkpoint changes meaning; a hand-authored file that today sets a
  `launch.cwd` distinct from `cwd` expresses the same intent afterward by
  setting `cwd`.) The command becomes a scalar on `PaneSnapshot`,
  `resolveLaunch` reads `pane.cwd` unconditionally, and the graft carries one
  value per pane like the scrollback graft. The persisted agent session stops
  being a raw value that loading trusts and consumption silently re-checks.
  Its hand-written `init(from:)` turns a missing or wrongly typed
  `kind`/`sessionId` into `""`, and a strictly decoded pair of strings can
  still fail `AgentSession`'s validating init; either way the bad value
  reaches `recoveryReplayText`, which drops the hint with no signal. Loading
  validates through `AgentSession` instead, so a present agent session it
  rejects fails the load and nothing downstream of a successful load can hold
  an invalid one. Capture is unaffected: the graft reads an already-validated
  live `AgentSession`, so DanTerm's own writer cannot emit a value this
  rejects. Both changes move the on-disk shape, so `appInitFileVersion` goes
  to 3.
- **`ls` reports live semantics.** The `ls` reply defers to the runtime,
  which attaches per-pane live semantics in the same encoding `pane.info`
  already uses (`paneSemanticInspectionValue`). Nothing in the live query
  path reads the init-file DTOs afterward; their readers are the three
  snapshot-loading surfaces below.
  `integrations/danterm/SKILL.md` is updated in the same change.
- **The size guard moves to admission.** The model-side 64 KiB cap on
  command and remote identity moves to the engine-to-pane event lowering, so
  the two-layer defense now protects the state everything reads. A remote
  identity is bounded by its combined size, `user.utf8.count +
  host.utf8.count`, matching what the engine parser already admits; only the
  command is bounded as a single string. The title/cwd/notification guards in
  `update()` stay where they are.

## Invariants

- I1 **Single source.** No `AppModel` field mirrors a semantic facet. Every
  consumer -- toolbar, pane menu, theme, IPC, checkpoint -- reads the
  pane-owned snapshot or a value grafted from it at use time.
- I2 **Theme.** A pane whose connection facet is remote renders
  `config.remoteTheme`; a local pane renders `pane.theme` or the config
  default. A `remoteTheme` config change takes effect on live remote panes
  without model mutation. Setting a pane theme while remote changes only the
  theme shown after the connection ends.
- I3 **Checkpoint contents.** A checkpoint written after a command starts
  carries that command as restore prefill, including after the command ends.
  The agent hint appears on attach and is absent after detach. Light
  checkpoints carry both projections themselves (the merge stays
  scrollback-only).
- I4 **Checkpoint scheduling.** Command start and agent attach/detach
  schedule a checkpoint; command end schedules one only while an agent is
  attached; remote transitions do not schedule.
- I5 **Waiting alert.** A transition to waiting activity on an unfocused pane
  raises the alert/notification path; the focused pane is suppressed.
  Non-waiting activity changes raise nothing.
- I6 **Admission cap.** A terminal-originated command whose UTF-8 size
  exceeds 64 KiB, or a remote identity whose combined `user` plus `host`
  UTF-8 size exceeds 64 KiB, never enters pane-owned semantic state.
- I7 **`ls`.** Each pane in `ls` output carries its live semantics in the
  `pane.info` encoding, correct as of reply time.
- I8 **Reconcile immediacy.** Remote and attach/detach transitions reconcile
  inline; command and activity transitions may coalesce (current behavior
  preserved).
- I9 **Snapshot loading.** All three loading surfaces -- checkpoint restore,
  `--init`, and Import State -- consume the persisted launch prefill and
  agent replay hint exactly as today, and resolve the launch cwd from
  `PaneSnapshot.cwd` alone. A snapshot carrying an `agentSession` that
  `AgentSession` would reject -- structurally malformed or structurally valid
  but failing kind/session-id validation -- fails to load instead of loading
  silently agent-less. An absent `agentSession` still loads as no agent.

## Proof obligations

TDD per AGENTS.md; all entries behavioral and structure-insensitive.

- PO1 (I1): toolbar projection renders remote/agent chips from snapshots
  alone; a pane with no snapshot renders local/no-agent. The pane menu is
  covered separately because it reads twice -- item visibility and the copied
  id: with an attached agent the menu shows the item and copying yields the
  snapshot's session id; after detach the item is gone.
- PO2 (I2): derivation table for effective theme over local/remote x pane
  theme x config; config-reload and prefSave produce the new remote theme in
  the pane-config projection with no model mutation; the
  set-theme-while-remote scenario.
- PO3 (I3): capture-and-decode round trip pins prefill-survives-command-end
  and hint-cleared-on-detach, run separately over each of the three capture
  routes -- light checkpoint, enriched checkpoint, and state export -- since
  they are three independent construction sites. The light case also
  discharges the merge-unchanged claim.
- PO4 (I4): scheduling table over transitions.
- PO5 (I5): waiting-transition alert with focus suppression, via the new arm.
- PO6 (I6): oversized command/identity is rejected at admission; an at-limit
  value passes. The identity cases straddle the combined bound -- a `user` +
  `host` pair summing to exactly 64 KiB passes, one byte more is rejected --
  so a per-string check cannot satisfy it. (Replaces the `update()`-side limit
  tests for these two values; title/cwd/notification limit tests are
  untouched.)
- PO7 (I7): `ls` reply carries pane semantics matching the `pane.info`
  encoding, over at least two panes holding distinct live
  command/connection/agent state, asserting each pane carries only its own.
- PO8 (I8): coalescing decision per transition kind.
- PO9 (I9): existing restore tests stay green (launch prefill, agent replay
  hint), including tilde expansion of the restored cwd now that it resolves
  from one field. New cases at `loadValidatedInitFile`, which all three
  surfaces share, so they hold for `--init` and Import State too: a wrongly
  typed `agentSession` field and a structurally valid one whose `sessionId`
  fails `AgentSession` validation (a `;` is outside the allowed set) each
  throw rather than loading a pane with no agent, while an omitted
  `agentSession` loads normally.

Existing suites carrying the rewrites: `UpdateRemoteTests` (mostly deleted;
theme survivors become derivation tests), `TerminalBackendBoundaryTests`
(collapses to didChange gating), `ExportTests`/`SnapshotTests`/
`CheckpointCaptureTests` (graft round trips), `UpdateIpcTests`,
`ModelOperationsTests`, `app-tests/PaneSemanticRoutingTests` (admission cap),
`LivePaneSemanticReducerTests` and `PaneSemanticConsumerTests` (unchanged).

## Non-goals

- Persisting the live facets themselves; only the two product projections
  are checkpointed.
- Command history: the recovery memo retains exactly one last-started
  command.
- Any change to the reducer's facet transition semantics.

## Accepted risks

- AR1: `ls` output shape changes (per-pane `semantics` replaces the
  checkpoint-projection command and agent-session fields); SKILL.md is
  rewritten with it. One-user product; format breaks are sanctioned by
  AGENTS.md.
- AR2: `ls` no longer shows a finished command (live command is idle after
  end, where the old field lingered). The lingering value was recovery data
  in a listing costume; this is a correctness gain accepted as a visible
  change.
- AR3: a same-session re-attach while waiting now schedules one extra
  debounced checkpoint (activity resets to working, so the transition
  registers as changed). The 2s debounce absorbs it; persisted bytes are
  identical.
- AR4: non-waiting activity transitions now produce a no-op update plus a
  coalesced reconcile sweep that previously didn't happen; the sweep diffs to
  empty and the boundary stops encoding product policy.
- AR5: bumping `appInitFileVersion` to 3 invalidates every version-2 file at
  once -- the checkpoint on disk at upgrade (costing one fresh session), every
  previously exported state file, and every hand-authored `--init` file. Only
  Import State reports it as a dialog; `--init` prints the unsupported-version
  line to the console and launches a default session, so a user driving a saved
  layout sees a blank startup with no in-app signal. This is the version gate's
  designed behavior, not a new failure mode, and AGENTS.md sanctions the break.
- AR6: validating `agentSession` at load widens the blast radius of one bad
  field from a dropped agent hint to a rejected file, which for a
  hand-authored or imported snapshot means a typo in a session id costs the
  whole load. Accepted: failing loudly beats loading a pane that silently lost
  its agent hint, an omitted `agentSession` still loads as no agent so
  hand-authors who leave it out are unaffected, and every other pane field
  already fails the whole load this way.

## Rejected ideas

- RI1: keep `lastCommand` in `AppModel` as a recovery fold (like cwd/title).
  Reintroduces the mirror pattern for one field and keeps a legacy Msg
  alive; the memo-plus-graft keeps persistence uniform with scrollback.
- RI2: `ls` preserves today's checkpoint-projection fields byte-for-byte via
  graft. Couples the CLI listing format to the recovery file format forever.
- RI3: structural-only `ls`. Shrinks the documented discovery surface
  (finding a pane by agent session would need per-pane `pane.info` calls),
  against the remote-controllability goal.

## Implementation discretion

- Home and shape of the recovery memo type and the per-pane capture value
  (constrained only by: pure, core-testable, outside
  `LivePaneSemanticReducer.swift`).
- Whether `PaneToolbarRender` keeps flat fields or carries facets.
- Whether `AgentSessionSnapshot` survives as a distinct DTO validated at the
  load boundary or collapses into a throwing `AgentSession` decode. Both
  satisfy the invariant; the second also retires the "validate again at
  consumption" note in `AgentSession.swift`'s header, which the load-time
  check makes obsolete either way.
- The deferred-`ls` mechanism (new Command case vs generalizing the
  `readPaneInfo` pattern).

## Critical files

Core: `Model.swift`, `Msg.swift`, `Update.swift`,
`TerminalBackendBoundary.swift`, `ModelOperations.swift`,
`Projections.swift`, `Persistence.swift`, `CheckpointCapture.swift`,
`PaneSemanticConsumers.swift`, `Command.swift` (all under
`lib/DanTermCore/Sources/DanTermCore/`).
App: `SwiftTerminalSessionView.swift`, `TerminalSession.swift`,
`AppRuntime.swift`, `Reconcile.swift`, `PaneWrapperView.swift`.
Docs: `integrations/danterm/SKILL.md`, `TerminalMetadataBounds.swift` header
(name the new second layer), `docs/terminal-capabilities.md`.
Shim: `tests-ui/SidebarViewTestShim.swift`.
Harness: `test-ui.sh` (explicit core-source list).

Reuse: `paneSemanticInspectionValue` (ls encoding), the `graftScrollback`
leaf-walk pattern, the snapshot map Reconcile already builds, the
`readPaneInfo` deferred-reply pattern, `fitsTerminalMetadataValueLimit` (for
the single-string command bound; the identity bound is over the pair's
combined size, so it is not a per-string reuse).

## Verification

`just test` (gate) and `just test-ui` (shim). Manual smoke via
`just launch-slot` with an explicit `--socket`: `danterm ls` shows the new
per-pane semantics; `danterm pane info` unchanged; `danterm agent attach`
then `ls` finds the session; ssh into a host and back retheme-and-reverts;
change `remoteTheme` in config while an ssh session is live and reload;
kill -9 the app mid-command and relaunch to confirm the restore prefill and
agent replay hint still appear.

## Commit progress

- [x] 1. feat(recovery): graft pane semantic recovery state
- [x] 2. feat(persistence): validate the version 3 pane format
- [x] 3. refactor(semantics): remove pane semantic mirrors

## Implementation notes

- Commit 2 keeps `AgentSessionSnapshot` as a strict DTO. Wrongly typed fields
  fail decoding, while `validateAndBuildDetailed` validates decoded values
  through `AgentSession` and rejects invalid values before restore succeeds.
- Commit 3 uses a dedicated deferred `readPaneList` command. The core builds
  the structural listing, then the runtime adds each pane owner's live
  semantics immediately before replying.
