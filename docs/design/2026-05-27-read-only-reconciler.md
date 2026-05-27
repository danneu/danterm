# Read-Only View Reconciler

Status: Accepted
Date: 2026-05-27

## Context

DanTerm uses Elm architecture: user/Ghostty actions become `Msg` values,
`update(&model, msg)` is the pure model transition and returns `[Command]`, and
`AppRuntime.perform(command)` runs side effects. The view reconciler is the next
step in that pipeline: after update and pre-reconcile commands, `reconcile()`
derives AppKit and Ghostty/surface state from the current model.

The reconciler migration moved view-sync work out of `update()` and
`AppRuntime.send()` into ordered `reconcile*` passes. The intended pass shape,
from the template at the top of `app/Reconcile.swift`, is:

- pure projections and structural diff/op helpers live in
  `ModelOperations.swift`, stay AppKit-free, and are unit-tested;
- `ReconcilerCaches` stores each pass's last applied projection so the next pass
  applies only the delta;
- `Reconcile.swift` contains thin impure executors that apply the computed delta
  to AppKit views, Ghostty/surface state, and runtime-owned view handles;
- the matching `Command` case and `perform` arm disappear in the same change, so
  missed view-sync emissions become compile errors.

Commands are for true side effects and transient imperative actions: PTY/surface
creation, IPC replies, notifications, checkpoint/config writes, focus requests,
export, and popover presentation. Everything the view merely shows should be a
projection of the model. Some commands run after reconcile when they target
views the reconciler creates; that classification is explicit and exhaustive.

The "read-only reconciler" rule was implicit in that architecture, but it was
not written down. The current TODO popover view-swap cleanup writes
`model.todoPopover` inside `reconcileContainers`. That solved the scattered
update-site obligation, but crossed the layer boundary: after `update()`
returned, reconcile could mutate model state that later `update()` guards and
popover close callbacks read.

This ADR makes the rule explicit and describes the ideal shape for future
reconcile work, not just the current implementation.

## Decision

The view reconciler is a read-only projection of `AppModel`. A reconcile pass
may read `AppModel` and `ViewLocalState`; it may write AppKit views,
Ghostty/surface state, runtime-owned view handles, and `ReconcilerCaches`. It
must not write `AppModel`.

For ordinary `Msg` handling, `AppModel` transitions happen in `update()` and are
covered by behavior tests at the pure layer. If view-sync needs derived model
state, compute it in `update()` before reconcile runs. If state is genuinely
view-derived and should not be serialized or owned by the domain model, keep it
in `ViewLocalState` or a runtime-owned handle rather than writing it back into
`AppModel` from a reconcile pass.

New reconcile passes should follow the migration template:

- put pure projections and structural diff/op helpers in `ModelOperations.swift`,
  with `Equatable` outputs where possible;
- add cache fields to `ReconcilerCaches`, with reset behavior provided by
  `tearDownCurrentSession` reinitializing the cache struct;
- apply deltas in a thin `reconcileX()` executor, including explicit remove
  behavior when a projection disappears but the host view survives;
- delete the matching `Command` case, `perform` arm, and emission sites in the
  same change.

Reconcile pass ordering is part of the contract. Passes that destroy or recreate
hosts must run before passes that render into those hosts, and they must
invalidate affected host-local caches. Surface teardown runs before container
reconciliation; container reconciliation runs before pane chrome; mount-time
focus runs after pane chrome when it may target a search field the chrome pass
creates; occlusion remains last because it reads the final visible/mounted
surface state.

Post-reconcile commands target views that reconcile creates. `Command.isPostReconcile`
must stay an exhaustive switch with no `default`, so adding a command requires an
explicit phase decision.

Reconcile scheduling may coalesce only changes whose delayed application is
semantically safe. Today that means high-frequency cosmetic surface metadata.
Structural/container-affecting messages reconcile inline. Any future coalescing
of structural messages must first add a behavioral popover/surface sync test
that proves model state, AppKit teardown, and post-reconcile commands stay
aligned.

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

## Consequences

"What is the model after message X?" is answerable from `update()` and from
documented session-replacement code, not from a later AppKit projection pass.
The pure layer remains the behavioral test boundary; AppKit executors stay small
and are verified by focused manual QA where the test harness cannot import
AppKit or GhosttyKit.

Commands remain true commands. Reintroducing a command whose only job is to make
the view match the model is a design smell; it should normally be a pure
projection plus a reconcile pass instead.

Some conditions are expressed twice in layer-appropriate forms. For TODO
popovers, `update()` clears `model.todoPopover` by comparing model state before
and after a message, while `reconcileContainers` dismisses AppKit popovers from
the live `ContainerOp` diff and the previously visible container. That
duplication is accepted because each half reads the inputs its layer owns. Tests
keep the behavioral boundary aligned.

The cost of the rule is occasional extra model helpers, generation counters, or
`ViewLocalState` plumbing. The payoff is stronger directionality: `update()`
owns domain/model transitions, `Command` owns true external effects, and
`reconcile()` owns rendering the current model into AppKit and surface state.

## References

- `AGENTS.md`: Elm architecture and data flow
- `app/Reconcile.swift`: reconciler template, pass ordering, `ReconcilerCaches`
- `app/ModelOperations.swift`: pure projections, diff/op helpers, reconcile scheduling
- `plans/impl/2026-05-26-tree-owns-panes-reconciler.md`: main reconciler migration plan
- `plans/impl/2026-05-27-coalesce-reconcile-sweeps.md`: reconcile scheduling policy
- `plans/impl/2026-05-27-quit-confirmation-reconcile.md`: single-optional panel projection precedent
- `plans/impl/2026-05-27-preferences-draft-panel-visibility.md`: panel visibility as a model projection
- `plans/impl/2026-05-27-reconcile-pane-config.md`: model-generation invalidation for external config reloads
