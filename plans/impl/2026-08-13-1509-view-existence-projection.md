# View existence is a projection, everywhere

## Context

The decision analysis in
`docs/scratch/2026-08-13-view-existence-projection-decision.md` concluded:
a surface with duration on screen -- shown, refreshed, dismissed -- is model
state, and its existence must be a projection of a model slot. Commands remain
only for one-shot transactions (fire-and-forget effects, or interactions
AppKit owns end to end). The forcing fact is that DanTerm receives Msgs from
IPC, PTY exits, and timers at any moment, so no surface can assume a frozen
model beneath it: every surface needs refresh-and-retract, which a fired
command cannot provide. The reconciliation ADR
(docs/design/2026-05-27-model-driven-view-reconciliation.md) already calls
view-sync commands a design smell but carves out "popover presentation"; that
carve-out is the contradiction this plan removes.

Since that analysis, `f5f42d01` (plan
`plans/impl/2026-08-13-1348-unified-close-confirmation-running-commands.md`)
landed the structural half of the confirmation work: `PendingConfirmation` is
now one transaction (subject: pane/tab/tabs/app, frozen `CloseImpact`
snapshot, quit authorization), with one emit chokepoint, one confirm/cancel
Msg pair (`confirmConfirmation` / `cancelConfirmation`), the confirm-time
growth check, the single-prompt fix, and pure copy in core. It deliberately
kept NSAlert presentation (one `showCloseConfirmation` Command,
`runConfirmation`, an `accessoryView` command detail) and listed the panel
migration as a non-goal. This plan completes that migration and the remaining
surfaces.

Remaining command-driven or imperative surfaces:

1. Close confirmations: `Command.showCloseConfirmation` -> NSAlert via
   `runConfirmation`, including a blocking windowless `runModal` fallback.
2. TODO popovers: `showTodoPopover` / `dismissTodoPopover` commands, two
   stranding sweeps, content passes gated on `handle?.isShown`. Live bug: the
   show executor can bail on a missing anchor after `update()` committed
   `model.todoPopover`, so the model says open with nothing on screen and the
   next toggle is consumed as a dismiss (double-press).
3. Alerts popover: no model state at all -- imperative
   `toggleAlertsPopover()` plus a `dismissAlertsPopover` Command.
4. Delete-group confirmation: an NSAlert built inside `SidebarView` with
   domain policy (`deleteGroupAction`, destination-group computation) decided
   view-side; it never touches `update()` or the pending slot.
5. Sidebar interaction path: a whole-`AppModel` mirror (`currentModel`)
   refreshed as a side effect of `reconcileSidebar`, inconsistently mixed
   with direct `runtime?.model` reads.

## Decision

Migrate all five. Presentation and policy decisions, taken with the user:

- **D1 -- one floating, non-modal confirmation panel.** The quit panel
  generalizes to render every `ConfirmationSubject`. All confirmations behave
  as the quit panel does today: floating, terminal stays usable. NSAlert,
  `runConfirmation`, and the `runModal` fallback are deleted. With no sheets
  left, the `beginSheetModal`/`endSheet` reentrancy surface disappears from
  the app.
- **D2 -- last request wins.** A close/quit request while a confirmation is
  pending replaces the transaction (panel reconfigures) instead of being
  silently dropped. This rewrites the landed refuse-while-pending guard and
  its no-op tests. Because replacement is normal, a panel answer must name
  the transaction it answers (I6).
- **D3 -- the panel renders the slot, copy included.** Close-subject copy
  stays derived from the frozen `CloseImpact` snapshot carried by the model
  slot -- the snapshot now lives in the model, not in a fired command, so
  projecting it is not the payload smell the analysis names. The landed
  frozen-copy + confirm-time growth-check invariants survive unchanged; a
  refresh re-emits the transaction and the panel re-renders. App-subject copy
  stays live (existing behavior).
- **D4 -- delete-group becomes a confirmation subject.** Its
  immediate-vs-confirm policy and destination-group naming move into
  `update()`; the sidebar sends a raw request Msg. The panel presents the
  three choices (move tabs / close tabs / cancel). Like a close subject, it
  is a frozen transaction: the slot holds the affected tab set and the
  destination group id taken when the transaction was emitted, and the panel
  renders that destination's current name. The frozen destination is part of
  the transaction's validity, so I2 refreshes the transaction when that
  group leaves the model, and the panel never has a dead destination to
  render. Both destructive choices still revalidate before committing -- if
  the frozen tab set grew, or the frozen destination is gone, the
  transaction refreshes and re-renders instead of committing.
- **D5 -- popover existence is gated on the model slot**, never on
  `handle?.isShown`. The alerts popover gains a model slot and a toggle Msg.
- **D6 -- the sidebar is a pure projection-fed renderer.** The interaction
  path reads only the last-applied `SidebarProjection` (the only source
  consistent with the rows NSOutlineView displays); facts it needs become
  projection fields; domain decisions move behind Msgs. Beginning an inline
  rename on a freshly created group becomes model state the projection
  carries, replacing the group-id-set diff across `send()`. Only an
  interactive create or extract from the sidebar sets that rename target;
  group creation from IPC or from domain logic does not, so a remote
  `group.create` never opens an editor or takes focus. The Msg that reports
  the end of editing clears the target, so the projection asks for a rename
  once.
- **D7 -- the ADR is amended in place** (an `Amended:` line under Status; the
  scratch doc carries the replacement wording verbatim): the Commands list
  loses presentation, gains the duration test and the silent-close protocol.
  The `Command.swift` header claim updates when the last presentation case
  dies.

## Invariants

- **I1 (existence).** For each migrated surface, the surface is on screen iff
  its model slot projects non-nil. No stranding sweeps, no `isShown` gates,
  no imperative toggle entry points remain.
- **I2 (no stranding).** A slot never outlives its validity, and validity is
  a named per-surface fact set that a sweep in `update()` enforces on every
  message -- the existing `reconcileTodoPopover` pattern, extended to
  `pendingConfirmation`. Validity is not the emission gate: the facts that
  decide whether to warn at all are checked once, at emission. Per surface:
  - popover: the owner is alive and still anchor-eligible under I4. A pane
    hidden when zoom activates elsewhere clears the slot on that sweep,
    since the app-layer sweep that catches it today is deleted.
  - confirmation: the subject is alive. A subject that dies (e.g. IPC closes
    the tab) retracts on that sweep. A subject that merely stops meeting the
    warning predicate -- the running command finishes mid-panel -- does not
    retract or refresh; per I5 the growth check is the only mid-life recheck
    and shrinkage commits, exactly as `f5f42d01` left it.
  - delete-group: the subject and the frozen destination are alive. A
    destination that leaves the model refreshes the transaction on that
    sweep, so the panel never renders a destination that is gone; a subject
    that shrinks to no tabs likewise refreshes, and the refreshed
    transaction is whatever the delete-group policy says for a group in that
    state.
- **I3 (silent close).** Reconciler-initiated dismissal never echoes a Msg
  back into `send()`: the executor detaches the reporting path before
  closing. AppKit-initiated transitions (click-away, panel close button)
  echo as Msgs, and those Msgs are idempotent against an already-cleared
  slot. Reconcile never synchronously re-enters `send()`.
- **I4 (anchor eligibility).** An arm that sets a popover slot guards on
  model facts alone, and the guard is anchor eligibility, not owner
  existence: the owner must be the kind of owner whose anchor the visible
  chrome currently shows -- its tab is the selected tab, and for a pane
  anchor the pane is in the visible container under any active zoom. An
  owner that exists but is not eligible leaves the slot nil, and I2 clears a
  slot whose owner loses eligibility later. Pass ordering (containers before
  popover existence) then makes the anchor realizable whenever the slot is
  set. The double-press state -- model open, nothing shown -- becomes
  unrepresentable.
- **I5 (confirmation semantics preserved).** The landed transaction
  invariants keep holding, retargeted from Command payload to projection:
  subject-only commit, quit authorization, per-pane growth check with
  refresh, copy strings byte-identical to the landed specification, command
  detail as `DisplayLine`.
- **I6 (replacement, and answers name their transaction).** Under D2,
  emitting a request while a transaction is pending yields a slot holding
  the new transaction, alone. Each transaction carries a model-issued
  identity; the projection carries it, and every panel answer (confirm,
  cancel, delete-group choice) names the identity it answers. `update()`
  ignores an answer whose identity is not the current slot's, so an answer
  from a replaced transaction can never commit its replacement. The identity
  only authenticates the answer: the commit still uses the subject and
  frozen impact stored in the slot.
- **I7 (sidebar source).** No sidebar interaction handler reads
  `runtime.model` or a stored `AppModel`; every fact comes from the applied
  projection or arrives as a Msg answered by `update()`.

## Proof obligations

Pure-layer, Swift Testing, in `lib/DanTermCore/Tests/DanTermCoreTests/`;
each names the claim, cases are the implementer's.

- **PO1 (I1).** Per surface: slot set -> projection non-nil with the expected
  content; slot nil -> projection nil. The landed confirmation POs
  (PO1-PO5, PO7-PO10 of the promoted plan) keep passing with emission
  asserted on the slot/projection instead of a Command; the copy-exactness
  and display-boundary sweeps (`DisplayBoundaryTests.swift`,
  `CustomTitleTests.swift`) retarget to the projection payload.
- **PO2 (I2).** `pendingConfirmation` strand tests mirroring the existing
  `reconcileTodoPopover` suite in `UpdateTodoTests.swift`: subject removed by
  another message -> slot clears; unrelated changes -> slot survives. Same
  suite for a mid-life eligibility loss: a TODO popover open on pane A, zoom
  activates on pane B -> slot clears.
- **PO3 (I4).** Toggling a popover for an anchor-eligible owner opens the
  slot; a request for an absent owner, and a request for a live owner that
  is not anchor-eligible (its tab is not selected; a pane hidden under
  zoom), both leave the slot nil; a second toggle closes it. The close echo for a stale owner does not clobber a
  newer slot (existing test, kept).
- **PO4 (I6).** Request B while A is pending -> slot holds B (rewrites the
  landed refuse-while-pending no-op tests). Confirming with A's identity
  after the replacement is a no-op: B stays pending and nothing closes. The
  same holds for every other answer type -- cancel, move-tabs, close-tabs --
  each with A's identity leaves B pending and the model unchanged.
- **PO5 (D4).** The delete-group arm reproduces `deleteGroupAction` policy
  from `update()`: immediate delete, confirm-with-choices, refusal for the
  last group; destination-group naming derived in core. Existing
  `deleteGroupAction` coverage in `ModelOperationsTests.swift` migrates with
  it. Revalidation: a tab moved into the group while the transaction is
  pending refreshes the transaction instead of closing the newcomer, and a
  destination group deleted while pending refreshes it on the I2 sweep, so
  the panel never renders a destination that is gone and no answer can move
  tabs somewhere the panel never showed.
- **PO6 (D5).** Alerts popover: toggle opens/closes the slot;
  `.activateAlert` clears it (replacing the two `dismissAlertsPopover`
  emissions); the click-away close echo against a slot `.activateAlert`
  already cleared is a no-op, mirroring the TODO popover's race guard (I3).
- **PO7 (I7/D6).** `desiredSidebar` carries the facts the handlers need
  (single-group drop target, delete enablement, context-menu inputs, rename
  target); tests in the existing `desiredSidebar` section of
  `ModelOperationsTests.swift`. Rename target as transitions, not just as a
  field: an interactive create or extract sets it on the new group, an IPC
  or domain create leaves it nil, and the end-of-editing Msg clears it.

App-layer behavior (panel rendering, popover anchoring, outline interaction)
is covered by the Verification walkthrough; the AppKit executors stay
manual-QA per the ADR.

## Non-goals

- Changing when confirmations fire or what they say: triggers, copy strings,
  growth-check semantics, and IPC's unguarded `pane.close`/`tab.close` are
  all as `f5f42d01` left them.
- The sidebar pane-rows feature and visibility toggle noted in `TODO.md`.
- Migrating surfaces the line classifies as transactions: context-menu
  tracking, drag sessions, system file panels, `terminate`, `activateApp`.
- Live (non-snapshot) copy for close subjects. Accepted risk, mirroring the
  landed design: the panel's close copy can lag the live model until a
  growth refresh re-emits; the growth check keeps the commit honest.

## Accepted risks

- **AR1.** `popoverDidClose` delivery timing from `performClose` is
  undocumented; I3's silent-close protocol is designed to be correct whether
  it fires synchronously or after animation.
- **AR2.** Showing a popover from a reconcile pass runs after
  `reconcilePaneFocus` in the sweep, where today's command path ran before
  it. Verify during the TODO-popover slice that the focus pass preserves the
  popover as a deliberate claimant on the show sweep; if not, existence
  passes move before pane focus, which the ADR's ordering contract permits.
- **AR3.** Non-modal close confirmations are a deliberate UX change: the
  user can keep typing in the terminal under an open confirmation, and a
  keyboard-driven close request replaces it (D2).

- **AR4.** Popover slots carry no transaction identity, unlike
  confirmations (I6). A close echo that arrives after the same popover
  reopened can close it again, costing one extra toggle; nothing is
  destroyed, and PO3's stale-owner case already covers the clobbering
  variant. Identity there would be state paid for a cosmetic race.

## Implementation discretion

- How the panel renders per-subject choices (two buttons vs three) and how
  each choice maps onto the confirm/cancel Msgs or a delete-group choice
  Msg.
- The spelling of the alerts-popover slot, the rename-initiation slot, and
  the silent-close mechanics (delegate detach vs lifecycle token).

## Verification

1. `swift test --package-path lib/DanTermCore`, then `just test`; `just
   test-ui` from a GUI session for the AppKit harness.
2. `bash ./dev-build.sh --no-install` to confirm the app target compiles.
3. End to end in an isolated slot (`just launch-slot`, explicit `danterm
   --socket <slot>`):
   - Close confirmations: rerun the promoted plan's walkthrough (running
     command in a pane, Cmd+W / Shift+Cmd+W / last-tab quit chain); every
     prompt is now the floating panel, terminal stays typeable underneath,
     and the monospaced command detail renders in the panel.
   - Retraction: with a tab-close confirmation up, `danterm tab close` the
     subject tab from another terminal -- the panel disappears and a
     following Cmd+Q raises the quit panel (slot did not strand).
   - Replacement: with a confirmation up for tab A, request close of tab B;
     the panel reconfigures to B; confirming closes only B.
   - TODO popover: toggle open/close from menu key, pane toolbar button, and
     chrome button; click-away closes and the next toggle opens (no
     double-press); close the popover's tab via `danterm tab close` -- the
     popover retracts.
   - Alerts popover: bell button toggles; clicking an alert row navigates
     and closes it; click-away then toggle reopens.
   - Delete-group: context menu on a group with tabs offers the three
     choices from the panel; destination-group name matches the adjacent
     group; last group refuses.
   - Sidebar: drag a tab between groups and onto single-group mode targets;
     multi-select context menu actions; create a group / extract tabs and
     confirm inline rename begins on the new group.

## Commit progress

- [x] 1. docs(design): amend the reconciliation ADR -- presentation with
      duration is always a projection (D7; wording from the scratch doc)
- [x] 2. feat(confirm): project the confirmation panel for every subject
      (D1, D2, D3; I1, I2, I5, I6; PO1, PO2, PO4 -- deletes
      `showCloseConfirmation`, `runConfirmation`, the `runModal` fallback)
- [x] 3. feat(confirm): route delete-group confirmation through the model
      (D4; PO5 -- deletes the SidebarView NSAlert)
- [x] 4. feat(todo): project TODO popover existence (D5; I1-I4; PO1, PO3 --
      deletes both popover Commands and both stranding sweeps; fixes the
      double-press bug)
- [x] 5. feat(alerts): project alerts popover existence (D5; PO6 -- deletes
      `toggleAlertsPopover` and `dismissAlertsPopover`)
- [ ] 6. refactor(sidebar): interaction path reads the applied projection
      (D6; I7; PO7 -- deletes `currentModel`)
