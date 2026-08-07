# Per-pane font size

## Context

Font size in DanTerm is global: `Projections.swift#desiredPaneConfig` assigns
`model.config.resolvedFontSize` to every live pane, and nothing in the model can
express "this pane is bigger." There is no keyboard path to change font size at
all -- only the Preferences panel, which edits the config for every pane at once.

The desired outcome is Cmd-plus / Cmd-minus / Cmd-0 resizing **only the focused
pane**, so a user can enlarge the pane they are reading without disturbing the
others in the split.

The render half already exists and needs no changes: `PaneConfigKey` carries a
per-pane `fontSize`, `app/Reconcile.swift#reconcilePaneConfig` diffs it per pane,
and `app/SwiftTerminalSessionView.swift#setFontSize` re-derives metrics, re-grids,
and resizes the PTY. The projection is the only reason the value is uniform.

## Decision

Store a **relative step count** on the pane -- an `Int` on `PaneModel`, default 0
meaning "follow config" -- and have the projection compute the effective size as
the configured size plus that offset. Both operands are already bounded when they
reach the projection (I3), so the sum needs no clamp of its own.

Relative rather than an absolute per-pane point size, because the stored value
should record the intent the user expressed ("bigger"), not a re-derivation of it
("15pt"). An absolute override cannot distinguish a pane the user zoomed from a
pane that merely matches the old config, so a config change must either strand the
pane at a stale size or discard the user's adjustment. With steps the question does
not arise: the projection is a pure function of `(config, pane)`, so a config change
moves zoomed and unzoomed panes alike with no reconciliation code.

Scope is the pane, matching the existing per-pane `theme` override, and zoom is
persisted across restarts.

### Keybindings

Cmd-0 currently clears the tab color (Tab > Color > Clear Color). **Clear Color
moves to Cmd-9** (verified free) and Cmd-0 becomes "Actual Size" in the View menu,
which is where every other Mac app puts it.

Increase needs two bindings: AppKit matches `charactersIgnoringModifiers`, so
Cmd-Shift-= delivers `+` and plain Cmd-= delivers `=`; one item cannot match both.
The visible View-menu item binds `+`; a second item binds `=` and is hidden while
keeping its key equivalent live, so the menu shows one row.

## Invariants

- **I1** -- Adjusting or resetting one pane's font size leaves every other pane's
  effective size unchanged.
- **I2** -- Zoom is relative to configuration: changing the configured font size
  shifts a zoomed pane by the same amount, preserving its offset. Reset returns a
  pane to exactly the configured size.
- **I3** -- Only a renderable font size reaches the render layer, and the projection
  never has to clamp to achieve that. The configured size resolves into a bounded
  renderable range, and the step range is chosen so that either endpoint of that
  range plus either end of the offset range is still renderable. (A projection-only
  clamp cannot coexist with I2 and I4: at a configured size smaller than one
  negative offset, clamping discards the preserved offset and hides steps that then
  need to be spent again before anything moves. `setFontSize` drops a non-positive
  size while `applyDiff` has already cached it as applied, which would wedge the
  pane until some other key field changed.)
- **I4** -- Zoom steps are bounded on every ingress -- adjustment and snapshot
  restore alike -- not only at projection. So N decrements followed by one increment
  always produce a visibly larger pane, repeated presses at a bound accumulate no
  hidden state, and a corrupt or hand-edited step count cannot decode into a value
  that traps or dead-presses when next adjusted.
- **I5** -- A pane at the default size persists exactly as it does today, and a
  snapshot written before this change restores to the default. No snapshot schema
  version bump.
- **I6** -- A pane's zoom travels with the pane: surviving a move to another split
  position, and inherited by a split from the pane it was split from -- the same
  treatment `theme` gets today. A new tab starts at the default.
- **I7** -- An adjustment that changes nothing (at a bound, or reset on an unzoomed
  pane) schedules no checkpoint.
- **I8** -- A pane is created at its effective size. Restoring a zoomed pane must
  not build the session at the global size and correct it on the first reconcile
  pass, which would show a size pop and send a spurious resize to a freshly forked
  shell.
- **I9** -- A restored model carries structure, not appearance. `AppModel.config`
  and `resolvedFontFamily` are ephemeral (loaded from disk at launch, never
  snapshotted), so a model rebuilt from a snapshot has them at their defaults; the
  live values are carried onto it before any session is created from it and before
  it is committed. Without this a restored +2 pane under a configured size of 18
  is built at 15 and the committed model reverts to 13, breaking I2 and I8. The
  carry-over is a pure function of (restored model, live config, live resolved
  family) so it can be asserted through `desiredPaneConfig`.

## Proof obligations

Behavioral tests in `lib/DanTermCore/Tests/DanTermCoreTests/`, asserting through
`desiredPaneConfig` and snapshot round-trips rather than reading the stored field,
except where the stored bound is itself the contract (I4). Swift Testing idiom and
`makeModel()` / `createTab` / `update` helpers as in `UpdateThemeTests.swift`.

- **PO1** (I1) -- In a split tab, adjusting the focused pane changes its projected
  size and not its sibling's.
- **PO2** (I2) -- A zoomed pane and an unzoomed sibling both shift by the same
  delta when the configured size changes, preserving the offset between them; reset
  lands on the configured size exactly. This is the case that distinguishes this
  design from an absolute override -- say so in the preamble.
- **PO3** (I3) -- At each endpoint of the configured-size range, a pane at each end
  of the step range projects a renderable size. A configured value outside the
  range -- including one small enough to make the old projection-only clamp
  necessary -- resolves to the nearest endpoint.
- **PO4** (I4) -- Many decrements followed by one increment project a larger size
  than the floor. Separately, a snapshot carrying an out-of-range step count
  (including `Int.max`) restores to the bound rather than trapping, and then
  behaves exactly like a pane adjusted to that bound: an inward adjustment changes
  the projected size, reversing it returns to the bound, and a further outward
  adjustment is the no-op PO7 requires.
- **PO5** (I5) -- Round-trip preserves a non-default zoom; a snapshot JSON with no
  zoom key restores to the default; an unzoomed pane writes no zoom key.
- **PO6** (I6) -- A split inherits the source pane's zoom; a new tab does not; a
  zoomed pane moved to another split position keeps its projected size.
- **PO7** (I7) -- Neither of the two no-op paths returns any command: reset on an
  unzoomed pane, and an adjustment on a pane already at a bound.
- **PO8** (I1, menu path) -- An adjustment with no explicit pane targets the
  focused pane of the selected tab; one naming a pane in a background tab targets
  that pane. Mirrors the `.toggleZoomPane` contract.
- **PO9** (I9) -- A model rebuilt from a snapshot containing a +2 pane, carried
  over a live config whose font size is not the default, projects the effective
  size (configured + 2) for that pane and the configured size for an unzoomed one.
  The same assertion covers the configured theme and resolved font family, which
  this path drops today.

I8's remaining half -- that the runtime passes the effective size to session
creation rather than the configured one -- is wiring with no pure seam; it is
covered by inspection plus the manual check below.

## Non-goals

- No `danterm` CLI / IPC surface. A `font-size` sibling to `theme set --pane` is a
  clean follow-on; it is out of scope here, so `integrations/danterm/SKILL.md` is
  untouched.
- No window-wide or tab-wide zoom scope.
- No UI indicator that a pane is zoomed.

## Accepted risks

- **AR1** -- Moving Clear Color to Cmd-9 breaks that shortcut for anyone using it.
  Accepted deliberately: Cmd-0 as "actual size" is the stronger convention.

## Rejected ideas

- **RI1** -- Absolute per-pane point size. An optional override does distinguish an
  adjusted pane from an unadjusted one, so no extra flag is needed -- but it fails
  I2: when the configured size changes, the adjusted pane is stranded at its old
  absolute size, and the only alternatives are discarding the adjustment or writing
  reconciliation code to shift every override. Steps make the question moot.
- **RI2** -- Multiplicative or fractional steps. Loses an exact return to the
  configured size, and produces near-identical sizes that still pass the change
  check and trigger a full re-raster and PTY reflow for no visible difference.
- **RI3** -- Keeping zoom in the view instead of the model. The reconciler applies
  theme, size, and family together only when the projected key changes, so the next
  theme change or font-family resolution would silently snap a view-owned zoom back
  to the global size. It also could not persist or be tested without Cocoa.

## Critical files

- `lib/DanTermCore/Sources/DanTermCore/Model.swift` -- the pane field, the snapshot
  field, and the restore path (where a persisted step count is bounded, I4).
- `lib/DanTermCore/Sources/DanTermCore/DanTermConfig.swift` -- `resolvedFontSize`,
  which today applies no bounds at all (I3).
- `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift` -- the effective-size
  computation and its bounds, beside `effectiveTheme`.
- `lib/DanTermCore/Sources/DanTermCore/Projections.swift` -- `desiredPaneConfig`.
- `lib/DanTermCore/Sources/DanTermCore/Msg.swift`, `Update.swift` -- adjust and
  reset messages, modeled on `.setPaneTheme` and `.toggleZoomPane`; split
  inheritance beside the existing `theme` inheritance.
- `lib/DanTermCore/Sources/DanTermCore/Persistence.swift` -- snapshot write.
- `app/AppRuntime.swift` -- session creation and restore staging, which pass the
  configured size today beside an already-effective theme (I8); `stageValidatedRestore`
  and `commitRestoreSession`, where the live config is carried onto the restored
  model (I9). Config is assigned to the model exactly once, at init, and the restore
  commit replaces the model wholesale.
- `app/AppDelegate.swift` -- View menu items, handlers, and the Clear Color rebind.

Existing tests to reconcile: the golden-master model dump gains the new pane field,
and `UpdateThemeTests#splitPaneWithoutThemeProjectsDefaults` asserts a whole
`PaneConfigKey` -- keep it a whole-value assertion rather than weakening it.

## Verification

- `just test` -- the full local gate, including the new suites and the golden
  master.
- `just launch-slot`, then in one window: split a pane, Cmd-plus a few times on the
  focused pane and confirm only that pane grows and its shell reflows to the new
  grid; Cmd-0 returns it to the configured size; Cmd-9 clears a tab color and Cmd-0
  no longer does. Verify Cmd-= (no shift) also increases and that the View menu
  shows a single "Increase Font Size" row -- the hidden-key-equivalent binding is
  the one part of this that is AppKit behavior rather than code-visible.
- With a non-default configured font size and a pane zoomed, quit and relaunch: the
  pane comes back zoomed, at the right size immediately rather than resizing after
  appearing (I8), and the configured size and theme survive the restore (I9).
- Edit the configured font size in Preferences while a pane is zoomed and confirm
  the pane keeps its offset (I2, the load-bearing behavior).

## Implementation discretion

- The step increment, the step range, the configured-size range, and the renderable
  bounds are chosen at implementation time subject to I3 and I4.
- Whether adjust and reset are two messages or one is a shape choice.

## Commit progress
- [x] 1. feat(core): per-pane font-size zoom in model, projection, and snapshot
- [x] 2. feat(app): bind per-pane font-size zoom to the View menu

## Implementation notes

- Bounds chosen for I3/I4: configured size resolves into `8...72`
  (`DanTermConfig.fontSizeRange`), zoom spans `-4...24` whole points
  (`paneFontSizeStepRange`), so every sum lands inside `renderableFontSizeRange`
  (`4...96`) by construction. `renderableFontSizeRange` exists only as the named
  contract the I3 test asserts against; no production code reads it.
- `resolvedFontSize` also rejects a non-finite configured size. JSON cannot
  express one today, but the guard is what makes the clamp total.
- Adjust and reset are two messages, mirroring `.setPaneTheme` /
  `.toggleZoomPane` rather than one message with an enum payload.
- `.adjustPaneFontSize` bounds its `steps` argument before adding it to the
  pane's, so no caller can overflow the sum.
- I9's carry-over lands in `stageValidatedRestore` alone, not also in
  `commitRestoreSession`: staging builds the sessions and returns the model that
  commit installs, so carrying once at the top of staging covers both halves of
  the invariant. `restoredModel` replaces `loaded.model` throughout that
  function so the two cannot drift apart.
- Session creation falls back to the configured size when the pane is missing
  from the model, matching how the adjacent `themeName` argument already
  degrades.

## Follow Up

- Preferences accepts any positive finite font size
  (`lib/DanTermCore/Sources/DanTermCore/Update.swift:689`), but
  `resolvedFontSize` now clamps to `8...72`. A user who types 200 sees 200 in
  the panel while panes render at 72. Either validate the draft against
  `DanTermConfig.fontSizeRange` at save, or show the resolved value back.
