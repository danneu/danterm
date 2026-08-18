# Model-Driven View Reconciliation

- Status: Accepted
- Date: 2026-05-27
- Amended: 2026-08-13 -- presentation with duration is always a projection;
  2026-08-16 -- pane containers became flat model-owned projections
- Extended by: [Model-Owned Pane Geometry](2026-08-16-model-owned-pane-geometry.md)

> **2026-08-16: pane container mechanism replaced; reconciliation rule
> retained.** Pane containers no longer use keyed structural view-tree patches,
> nested split views, wrapper reparenting, or a zoom overlay. A surviving tab
> receives its current model root, and its flat container derives pane and
> divider frames through the pure layout defined by the extending note. The
> general rules below still bind: reconciliation is model-driven, preserves
> long-lived hosts, runs in order, and does not write AppModel.

## Context

DanTerm uses Elm architecture: user/Ghostty actions become `Msg` values,
`update(&model, msg)` is the pure model transition and returns `[Command]`, and
`AppRuntime.perform(command)` runs side effects. The view reconciler is the next
stage in that pipeline: after update and commands, `reconcile()` derives AppKit
and session state from the current model.

The reconciler migration moved view-sync work out of `update()` and
`AppRuntime.send()` into ordered `reconcile*` passes. The intended pass shape,
from the template at the top of `app/Reconcile.swift`, is:

- pure projections and structural diff/op helpers live in
  `Projections.swift`, stay AppKit-free, and are unit-tested;
- `ReconcilerCaches` stores each pass's last applied projection so the next pass
  applies only the delta;
- `Reconcile.swift` contains thin impure executors that apply the computed delta
  to AppKit views, session state, and runtime-owned view handles;
- the matching `Command` case and `perform` arm disappear in the same change, so
  missed view-sync emissions become compile errors.

## Architectural Goal

DanTerm uses retained-mode, model-driven view reconciliation. AppKit views,
Terminal sessions, panels, and runtime handles are long-lived host objects. After
each model transition, `reconcile()` derives small desired projections from
`AppModel`, diffs them against `ReconcilerCaches`, and patches the existing
hosts.

The goal is to make displayed view state a consequence of the model without
rebuilding all AppKit objects, scattering one-off view-sync commands through
`update()`, or hiding model transitions inside AppKit code.

## Decision

View-sync work should be expressed as ordered reconcile passes rather than
one-off commands whose only purpose is to make views match the model.

New reconcile passes should follow the migration template:

- put pure projections and structural diff/op helpers in `Projections.swift`,
  with `Equatable` outputs where possible;
- add cache fields to `ReconcilerCaches`, with reset behavior provided by
  `tearDownCurrentSession` reinitializing the cache struct;
- apply deltas in a thin `reconcileX()` executor, including explicit remove
  behavior when a projection disappears but the host view survives;
- delete the matching `Command` case, `perform` arm, and emission sites in the
  same change.

Commands are for true side effects and one-shot transactions: PTY/session
creation, session focus signaling, IPC replies, notifications,
checkpoint/config writes, export, process termination, and interactions whose
lifecycle AppKit owns end to end (menu tracking, drag sessions, system file
panels). A command's effect is an event: it fires, completes, and no later model
transition should refresh or retract it.

Anything with duration on screen is state, not an event. If a surface can be
shown, refreshed, and dismissed -- a panel, sheet, popover, or overlay -- its
existence is a projection of a model slot, following the single-optional
projection template. The test for a new case: ask what should happen if the
model changes while the surface is visible. If the answer is "the surface
updates or goes away", it is a projection. If its lifecycle cannot react and
only its result matters, it is a command, and the result re-enters as a Msg.

Hosts with native transitions (a transient popover's click-away close, the
window close button, outline row collapse) share ownership with AppKit under
one protocol: AppKit-initiated transitions report back as Msgs through a
delegate or target-action; reconciler-initiated transitions are silent -- the
executor cancels or detaches the reporting path before closing, because the
model already knows. A reconcile pass must never synchronously re-enter
`send()`.

## Pass Shapes

DanTerm uses a few explicit pass shapes rather than a generic virtual tree:

- keyed projections for per-pane values such as borders, toolbar renders,
  search overlays, and Ghostty config;
- structural op diffs for host trees such as tab containers and sidebar rows;
- single projection compares for persistent hosts such as window chrome,
  switcher, confirmation, preferences, and theme browser state.

A pure projection or diff helper should have behavioral tests that prove the
observable contract: unchanged projections do not require host mutation, and
changed projections produce the expected delta.

## Read-Only Model Rule

The view reconciler is a read-only projection of `AppModel`. Pure projections
and diff helpers derive desired state from `AppModel` and explicit values that
thin executors read from runtime-owned view handles. Executors may read host or
view state needed for host presence, visibility, anchors, open-state, or a pure
guard, but they pass only the narrow value that helper needs. Reconcile passes
may write AppKit views, session state, runtime-owned view handles, and
`ReconcilerCaches`. They must not write `AppModel`.

A pass writes `AppModel` indirectly if it calls `send()`, because the send
re-enters `update()`. So the rule covers that too: **a reconcile pass originates
no `Msg`.** A fact a pass discovers about the view goes into the runtime's
outbox (`ReconcileOutbox`), which dispatches it after the sweep has returned and
every pass cache has advanced. Sending from mid-pass instead re-enters the whole
sweep: the nested pass diffs the new model against a cache the outer pass has not
advanced yet, and issues view ops against a host that is mid-mutation.

The outbox is the sole channel out of a view, and reporting into it never
dispatches on the reporting stack. That is what lets a teardown report from a
place no pass can reach -- AppKit's own row traversal, where a recycled cell
takes a live field editor with it -- instead of clearing view state silently and
leaving the model claiming a session that is gone.

The rule holds for every pass, with no exception. `reconcilePaneFocus` moves the
responder and AppKit synchronously calls `becomeFirstResponder`, which used to
reach a `.paneBecameFirstResponder` send; the pane view no longer reports a
responder gain at all. Key focus into a pane target is reported by the gesture
that asks for it -- the terminal click and the search-field click -- so a
responder move with nobody behind it changes no model state, and the next pass
repairs it. Two things keep the rule robust rather than merely true today:

- `scripts/reconcile-pass-lint.sh` rejects a direct call edge from a pass to
  `send(`, over the sweep's entry files and a marked region of `SidebarView`. It
  cannot see an edge laundered through AppKit dispatch, so it does not on its own
  establish the rule.
- Only the outermost send dispatches follow-ups. A send arriving while a sweep is
  in flight -- from any path, including an AppKit-laundered one -- accumulates
  into the frame already running (`ReconcileFollowUps`). This is what makes the
  channel correct without depending on having enumerated every in-pass send site.

Delivery is therefore never immediate, and the two paths it takes are deliberate.
A report made inside a send frame is delivered when the outermost frame closes. A
report made with no frame open -- AppKit's `control(_:textShouldEndEditing:)`,
which must return before the field editor finishes tearing down, or a cell recycle
inside `viewFor:` -- wakes a drain on the next main-queue turn. A fact discovered
by a genuine pointer interaction still reaches the model in the same turn as the
interaction: that path opens a send frame of its own around the teardown, so its
report is delivered before the event goes on to change the selection.

For ordinary `Msg` handling, `AppModel` transitions happen in `update()` and are
covered by behavior tests at the pure layer. If view-sync needs derived model
state, compute it in `update()` before reconcile runs. If state is genuinely
view-derived and should not be serialized or owned by the domain model, keep it
on its natural runtime-owned view handle rather than writing it back into
`AppModel` from a reconcile pass.

## Ordering And Host Lifetime

Reconcile pass ordering is part of the contract. Passes that destroy or recreate
hosts must run before passes that render into those hosts, and they must
invalidate affected host-local caches.

Container reconciliation runs before session teardown so a removed pane leaves
the mounted tree before teardown releases its runtime-owned `PaneHost`. Pane
chrome then renders into the surviving persistent wrappers. Pane-focus
reconciliation runs after pane chrome because active search may target a field
that pass creates. Occlusion remains last because it reads the final
visible/mounted session state.

Pane focus is a single non-cached projection. The selected tab's `PaneTree`
chooses its focused pane, and active search state records whether that pane's
terminal or search field owns focus. The AppKit executor compares the
projection with the live first responder on every sweep so a tree patch that
temporarily detaches a wrapper can be repaired even when the desired model value
did not change. A deliberate non-pane claimant in the main window is preserved;
the window itself is unclaimed. Field-editor-backed controls resolve through
their live editing control before claimant classification.

Container reconciliation reserves whole-tree construction for a tab that has no
cached shape, including the clean cache after restore. A surviving tab is patched
by stable pane and split ids. Tree edits reparent existing wrappers, and zoom
temporarily reparents the focused wrapper into a full-container overlay while
the unchanged split tree stays mounted, hidden, and laid out at normal geometry.
Unzoom returns the wrapper to its keyed split position.

There is no pre/post command phase split. AppKit pane focus is applied by the
ordered reconciler after its target views exist.

## Scheduling And External Invalidation

Reconcile scheduling may coalesce only changes whose delayed application is
semantically safe. Today that means high-frequency cosmetic session metadata,
background-pane alert badges from bell/desktop-notification events, and
shell-integration command events. These feed only sidebar/window/focus-border/
toolbar badge chrome, the pane toolbar, and per-pane theme config; they never
change `ContainerShape`. Structural/container-affecting messages reconcile
inline. Any future coalescing of structural messages must first add a behavioral
popover/session sync test that proves model state, AppKit teardown, and
responder reconciliation stay aligned.

If external state changes what a projection should apply while the model value
looks unchanged, prefer an explicit model event or generation value included in
the projection over imperative cache pokes. This keeps the pass model-driven and
unit-testable, as with the pane-config generation pattern.

Restore and session replacement are outside ordinary `Msg` handling. They may
replace the whole model and may directly clear ephemeral runtime/model slots
while tearing down a live session. These bypasses must reset `ReconcilerCaches`
before the post-restore reconcile so the next pass is a clean build, and the
write site must explain why it bypasses `update()`.

Other exceptions to read-only reconcile require either an ADR update or an
explicit in-code justification plus a behavioral test proving the exception does
not observe stale, double-written, or out-of-order state.

## Projection Scan Cost

Projection passes still rebuild `allPanes` locally rather than sharing a
precomputed pane list. That cost is accepted because the scheduling policy above
coalesces the rapidly-firing cosmetic triggers (title, cwd, progress,
bell/desktop-notification alert badges, and shell command events) to about 75 ms
while structural messages reconcile inline. Pane and tab counts are not capped --
`createTab` and `splitPane` enforce no ceiling -- so the assumption remains that
interactive use stays human-scale.

Unread-alert counts are no longer local repeated scans. A credible high-pane and
high-tab latency report triggered the measured fix: `reconcile()` now computes
one `UnreadAlertTally` per model snapshot and threads it through the alert
consumers in focus borders, pane toolbar badges, sidebar tab/group rollups,
window chrome, and the MRU switcher. That reduces the alert portion from
O(panes/tabs x alerts), including sidebar per-tab set allocations, to
O(alerts + panes + tabs) plus O(1) lookups in each projection. The total alert
scan remains bounded by the `model.alerts` hard cap, while tab/group rollups are
restricted to panes reachable from each split tree.

Do not precompute further reconcile inputs speculatively. The alert-count tally
was added only after the hot path had a concrete high-pane/high-tab report; apply
the same bar to future shared inputs, especially `allPanes`, so the pure
projection layer does not accrete context bags for negligible cold-path work.

## Non-Goals

This is not a virtual DOM or generic component reconciler. The container pass
diffs only its explicit split-tree projection, keyed by the pane and split ids
the model already owns; other hosts keep their purpose-built pass shapes.

This is not Solid-style fine-grained reactivity. DanTerm does not track signal
dependencies from individual model fields to individual view sinks.

This is not a license to rebuild all AppKit hosts after every message. Host
identity and cache invalidation remain part of each pass's contract.

## Consequences

"What is the model after message X?" is answerable from `update()` and from
documented session-replacement code, not from a later AppKit projection pass.
The pure layer remains the behavioral test boundary; AppKit executors stay small
and are verified by focused manual QA where the test harness cannot import
AppKit or GhosttyKit.

Commands remain true commands. Reintroducing a command whose only job is to make
the view match the model is a design smell; it should normally be a pure
projection plus a reconcile pass instead.

Popover and confirmation existence is a projection of `model.todoPopover` and
`model.pendingConfirmation`. The pure invariant that these slots never outlive
their subject (owner pane/tab alive and anchored) is maintained in `update()`
and tested at the pure layer; reconcile passes rely on it and on pass ordering,
and contain no stranding sweeps.

The cost of this architecture is occasional extra model helpers, generation
counters, host-lifetime invalidation, or explicit view-state inputs. The payoff is
stronger directionality: `update()` owns domain/model transitions, `Command` owns
true external effects, and `reconcile()` owns rendering the current model into
AppKit and session state.

## References

- `AGENTS.md`: Elm architecture and data flow
- `app/Reconcile.swift`: reconciler template, pass ordering, `ReconcilerCaches`
- `lib/DanTermCore/Sources/DanTermCore/Projections.swift`: pure view projections
  + structural diff/op helpers
- `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift`: shared model
  helpers, reconcile scheduling (`reconcileDecision`)
- `plans/impl/2026-05-26-tree-owns-panes-reconciler.md`: main reconciler migration plan
- `plans/impl/2026-05-27-coalesce-reconcile-sweeps.md`: reconcile scheduling policy
- `plans/impl/2026-05-27-quit-confirmation-reconcile.md`: single-optional panel projection precedent
- `plans/impl/2026-05-27-preferences-draft-panel-visibility.md`: panel visibility as a model projection
- `plans/impl/2026-05-27-reconcile-pane-config.md`: model-generation invalidation for external config reloads
