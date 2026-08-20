# RUNTIME-2: Give the theme browser a model slot so reconcileThemeBrowser owns its existence

Audit item RUNTIME-2 in docs/scratch/2026-08-18-construction-audit.md.

## Problem

The theme browser is the one panel whose existence is pushed imperatively
instead of projected from the model. `AppRuntime.toggleThemeBrowser()` creates
or removes the view, installs constraints, and hand-calls two reconcile passes
outside the ordered sweep; `reconcileThemeBrowser` must ask the view whether it
exists before it can compute a projection. Because the fact lives in a view
field, the browser is invisible to `update()`, and the out-of-band call pair is
already asymmetric: the close path calls `reconcilePaneFocus()` and the open
path does not.

## Decision

Model-projected existence, on the shape the other panels already use: a
`themeBrowserOpen` flag on `AppModel`, a payload-free toggle Msg, an optional
projection gated on the flag, and a reconcile pass that creates the view on the
nil -> non-nil transition and removes it on the reverse. The menu action and
the browser's own close button both send the Msg; the imperative
`AppRuntime.toggleThemeBrowser` and its out-of-band pass calls disappear. The
view populates its own rows when it is built, so the pass only creates and
constrains it.

Ordering (decided by the user; do not reopen): the theme-browser pass moves
above `reconcilePaneFocus()` in the sweep, so closing the browser repairs pane
focus in the same sweep. This follows the rule already stated in
docs/design/2026-05-27-model-driven-view-reconciliation.md: a pass that
destroys a focused view runs before the focus repair.

**Named ideal, deferred:** the real ideal is to run every focus pass last --
move `reconcilePaneFocus()` to the end of the sweep, after every
view-existence pass, retiring the whole class "a pass destroyed a focused view
after the focus repair ran" for every panel at once. It is deferred, not
rejected: it silently reorders focus repair against six other passes that no
headless test can cover (app-tests never build an NSWindow; tests-ui cannot
compile app/Reconcile.swift), and mixing that into a change scoped to one
panel would make any later focus regression ambiguous. Schedule it with
REDUCE-4, which adds a second focus pass and therefore forces the "focus
passes run last" rule to be stated anyway.

## Invariants

- I1: "The browser is on screen but the model does not know it" is not
  representable: the view exists iff the projection is non-nil, and the
  projection is driven only by the model flag.
- I2: Every interactive existence change comes from a Msg, so it runs the whole
  ordered sweep -- including `reconcilePaneFocus`, which runs after the browser
  pass and repairs first responder on close in the same sweep. Session
  replacement is the one non-Msg path, covered by I6.
- I3: Opening the browser does not steal key focus from the terminal.
- I4: Reconcile passes originate no Msg (existing `reconcile-pass-lint.sh`
  boundary; the new pass creation path must respect it).
- I5: Z-order: the browser overlays every tab container. Containers built
  while the browser is open insert below it (`buildAndInsertContainer`
  contract), and the pass creates the browser above existing containers.
- I6: A restore/import commit resets ephemeral panel state. `tearDownCurrentSession`
  removes the browser view before it resets `ReconcilerCaches`, the same order the
  preferences panel already uses, so nil keeps meaning "already gone" for the
  first post-restore sweep and no orphaned view survives.
- I7: The projection's content rule is unchanged: it reports the focused
  pane's user-set theme (`pane.theme`, not `effectiveTheme`).

## Proof obligations

- PO1 (I1, I2): app test -- send the toggle Msg, assert the content area gains
  a `ThemeBrowserView` subview; send it again, assert the subview is gone.
  Fails today: the Msg does not exist, and nothing creates the view from a
  sweep.
- PO2 (I1): core test -- the projection is nil while the flag is false and
  non-nil after the toggle arm runs.
- PO3 (I7): existing ProjectionsTests content tests keep passing, updated for
  the optional signature.
- PO4: existing tests-ui browser-content tests (apply/filter/reset/context
  menu) keep passing; the close-button test inverts to assert the Msg is sent
  instead of a shim counter bump.
- PO5 (I2, I3, the focus half): not assertable in the gate -- focus repair
  needs an `NSWindow` plus the real runtime, which no test target can pair.
  Verify live in a slot: toggle the browser, confirm via `danterm --socket <s>
  focus` that the terminal reclaims focus after close and keeps it after open.
- PO6 (I6): app test -- open the browser, commit a restore, assert the content
  area holds no `ThemeBrowserView` and a following sweep leaves it absent.
- PO7 (I5): app test -- with a container already built, open the browser and
  assert a hit test at a point both cover lands inside the browser; build a
  second tab's container and assert the same point still lands inside the
  browser. Hit testing, not sibling order, is what I5 means.
- PO8: tests-ui -- a freshly constructed `ThemeBrowserView` renders its catalog
  rows with no external `reloadTable()` call, so no creation path can open an
  empty browser by forgetting one.

## Non-goals

- Moving `reconcilePaneFocus()` to the end of the sweep (the named ideal;
  deferred to REDUCE-4).
- Persisting the flag into snapshots; it is ephemeral like
  `alertsPopoverOpen`.
- Any change to the browser's view-local state (filter text, table focus) or
  content rules.

## Accepted risks

- AR1: The browser now closes across a restore/import commit instead of
  surviving it (ephemeral flag resets with the model). Consistent with the
  preferences panel and popovers; per-instance UI chrome, one user.

## Implementation discretion

- Whether teardown-ish update arms beyond the toggle clear the flag (the
  alerts-popover template clears only on its own messages; nothing else is
  required).
