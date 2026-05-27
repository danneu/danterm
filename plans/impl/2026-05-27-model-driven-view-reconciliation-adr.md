# ADR Refactor: Model-Driven View Reconciliation

## Summary

Refactor the existing read-only reconciler ADR into a broader architecture ADR
named `Model-Driven View Reconciliation`. The read-only rule remains, but
becomes one design invariant within the larger pattern: retained AppKit/Ghostty
hosts, model-derived projections, per-pass caches, and targeted host mutations.

Use `git mv` to rename:

- From: `docs/design/2026-05-27-read-only-reconciler.md`
- To: `docs/design/2026-05-27-model-driven-view-reconciliation.md`

Update durable references only:

- `docs/design/index.md`
- the comment in `app/Reconcile.swift` that currently says
  `read-only-reconciler ADR`

Leave historical implementation plans under `plans/` unchanged.

## New ADR Content

Replace the ADR body with this content:

```markdown
# Model-Driven View Reconciliation

Status: Accepted
Date: 2026-05-27

## Context

DanTerm uses Elm architecture: user/Ghostty actions become `Msg` values,
`update(&model, msg)` is the pure model transition and returns `[Command]`, and
`AppRuntime.perform(command)` runs side effects. The view reconciler is the next
stage in that pipeline: after update and pre-reconcile commands, `reconcile()`
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

## Architectural Goal

DanTerm uses retained-mode, model-driven view reconciliation. AppKit views,
Ghostty surfaces, panels, and runtime handles are long-lived host objects. After
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

- put pure projections and structural diff/op helpers in `ModelOperations.swift`,
  with `Equatable` outputs where possible;
- add cache fields to `ReconcilerCaches`, with reset behavior provided by
  `tearDownCurrentSession` reinitializing the cache struct;
- apply deltas in a thin `reconcileX()` executor, including explicit remove
  behavior when a projection disappears but the host view survives;
- delete the matching `Command` case, `perform` arm, and emission sites in the
  same change.

Commands are for true side effects and transient imperative actions: PTY/surface
creation, IPC replies, notifications, checkpoint/config writes, focus requests,
export, and popover presentation. Everything the view merely shows should be a
projection of the model. Some commands run after reconcile when they target
views the reconciler creates; that classification is explicit and exhaustive.

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
and diff helpers derive desired state from `AppModel` and `ViewLocalState`.
Thin reconcile executors may also read runtime-owned host/view state needed for
host presence, visibility, anchors, and open-state. Reconcile passes may write
AppKit views, Ghostty/surface state, runtime-owned view handles, and
`ReconcilerCaches`. They must not write `AppModel`.

For ordinary `Msg` handling, `AppModel` transitions happen in `update()` and are
covered by behavior tests at the pure layer. If view-sync needs derived model
state, compute it in `update()` before reconcile runs. If state is genuinely
view-derived and should not be serialized or owned by the domain model, keep it
in `ViewLocalState` or a runtime-owned handle rather than writing it back into
`AppModel` from a reconcile pass.

## Ordering And Host Lifetime

Reconcile pass ordering is part of the contract. Passes that destroy or recreate
hosts must run before passes that render into those hosts, and they must
invalidate affected host-local caches.

Surface teardown runs before container reconciliation. Container reconciliation
runs before pane chrome because container rebuilds recreate pane wrapper hosts.
Mount-time focus runs after pane chrome when it may target a search field the
chrome pass creates. Occlusion remains last because it reads the final
visible/mounted surface state.

Post-reconcile commands target views that reconcile creates.
`Command.isPostReconcile` must stay an exhaustive switch with no `default`, so
adding a command requires an explicit phase decision.

## Scheduling And External Invalidation

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

## Non-Goals

This is not a virtual DOM or generic component reconciler. DanTerm does not build
a full intermediate UI tree and recursively diff it.

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

Some conditions are expressed twice in layer-appropriate forms. For TODO
popovers, `update()` clears `model.todoPopover` by comparing model state before
and after a message, while `reconcileContainers` dismisses AppKit popovers from
the live `ContainerOp` diff and the previously visible container. That
duplication is accepted because each half reads the inputs its layer owns. Tests
keep the behavioral boundary aligned.

The cost of this architecture is occasional extra model helpers, generation
counters, host-lifetime invalidation, or `ViewLocalState` plumbing. The payoff is
stronger directionality: `update()` owns domain/model transitions, `Command` owns
true external effects, and `reconcile()` owns rendering the current model into
AppKit and surface state.

## References

- `AGENTS.md`: Elm architecture and data flow
- `app/Reconcile.swift`: reconciler template, pass ordering, `ReconcilerCaches`
- `app/ModelOperations.swift`: pure projections, diff/op helpers, reconcile scheduling
- `plans/impl/2026-05-26-tree-owns-panes-reconciler.md`: main reconciler migration plan
- `plans/impl/2026-05-27-coalesce-reconcile-sweeps.md`: reconcile scheduling policy
- `plans/impl/2026-05-27-quit-confirmation-reconcile.md`: single-optional panel projection precedent
- `plans/impl/2026-05-27-preferences-draft-panel-visibility.md`: panel visibility as a model projection
- `plans/impl/2026-05-27-reconcile-pane-config.md`: model-generation invalidation for external config reloads
```

## Implementation Changes

- Rename the ADR file with `git mv` so history is preserved.
- Update `docs/design/index.md` entry to:
  `- [2026-05-27: Model-Driven View Reconciliation](2026-05-27-model-driven-view-reconciliation.md)`
- Update the comment in `app/Reconcile.swift` from `read-only-reconciler ADR` to
  `model-driven view reconciliation ADR`.
- Do not update historical plan files under `plans/`; they are implementation
  records, not current navigation.

## Test Plan

- No unit tests are needed because this is a docs/comment-only refactor.
- Verify durable references with:
  `rg -n "read-only-reconciler|Read-Only View Reconciler" docs app`
  Expected result: no matches.
- Verify the new ADR is indexed:
  `rg -n "Model-Driven View Reconciliation|model-driven-view-reconciliation|model-driven view reconciliation ADR" docs/design app`
  Expected result: index entry, ADR title, and the updated `app/Reconcile.swift`
  comment.
- Optionally run `git diff --check` to catch whitespace issues.

## Assumptions

- The ADR date stays `2026-05-27` because this is a refactor of the same accepted
  decision, not a new decision.
- Historical implementation plans remain unchanged even though they mention the
  old ADR name.
- The implementation should not change reconciler behavior, tests, or source
  comments unrelated to this ADR reference.
