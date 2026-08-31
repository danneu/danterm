# Model-owned sidebar collapse and width

Source: audit item CHROME-1 (docs/scratch/2026-08-26-improvement-audit.md,
Wave 12). Verified against the tree 2026-08-30.

## Problem

The sidebar's collapsed flag and width live only in the `NSSplitView` and are
written by three independent shell paths: the menu/toolbar toggle
(`app/AppDelegate.swift#toggleSidebar`), the launch path (which hard-sets the
divider to 200pt), and the user's divider drag. No model field, `Msg`,
projection, or snapshot key exists. Consequences, all confirmed in the tree:

- A sidebar dragged wider (e.g. 280pt) reopens at 200pt after a collapse, and
  comes back at 200pt after any relaunch.
- The state is absent from `AppModelSnapshot`, so it does not survive
  crash-restore and cannot trigger a light checkpoint.
- It is invisible to `danterm ls`.
- The chrome (`WindowChromeView.syncWithSidebarState`) is hand-synced from
  three call sites and can be told a width the split view does not have.

Every other piece of window chrome is already a projection reconciled from the
model (`desiredWindowChrome` + `reconcileWindowChrome` in `app/Reconcile.swift`),
and the pane dividers already report drags as a `Msg`
(`.splitRatioChanged`, per docs/design/2026-08-16-model-owned-pane-geometry.md
D2). The sidebar is the exception.

## Decision

Move both facts into the pure core and drive AppKit from a projection, on the
existing templates:

- `AppModel` gains one persisted sidebar field holding the collapsed flag and
  the expanded width. The width survives collapse by construction (collapsing
  never overwrites it), so reopening restores it without any remembering logic
  in the shell.
- Two new messages in `Msg.swift`'s `// View` section carry the only writes:
  the toggle gesture and the divider-drag presentation report. The drag report
  carries the complete observed presentation -- collapsed state plus width --
  because `canCollapseSubview` permits pointer-driven collapse, which a
  width-only report cannot represent. A collapse report sets the collapsed
  flag and preserves the stored expanded width. The reducer is the sole writer
  of the field.
- A pure projection in `Projections.swift` plus a reconcile pass in
  `app/Reconcile.swift` (single-struct-compare template, slotted next to
  `reconcileWindowChrome`) become the only programmatic writers of the divider
  position and of `syncWithSidebarState` (native drag stays provisional input
  per I1). The launch-path hard-set, the toggle's direct
  `setPosition` calls, and the chrome painting in `splitViewDidResizeSubviews`
  are deleted; the split-view delegate keeps only drag constraints and the
  presentation report.
- Catalog command `view.toggle-sidebar` and the chrome toggle button send the
  toggle `Msg` instead of invoking the AppKit selector (the
  `toggleAlerts` pattern).
- The field rides `AppModelSnapshot` / `toSnapshot` / `validateAndBuild`, so
  persistence, crash-restore, light-checkpoint triggering, and `exportState`
  follow from the existing machinery.
- `IpcEntityEncoder.list` emits one top-level `sidebar` object in `danterm ls`
  (the `inlineRename` precedent): `"sidebar": {"isCollapsed": <Bool>,
  "width": <Double>}`, where `width` is always the saved expanded width, also
  while collapsed. `integrations/danterm/SKILL.md` documents it in the same
  change.

The sidebar `NSSplitView` itself stays. ADR 2026-08-16 D5 keeps it outside the
pane-geometry owner until its shape changes; this change does not alter its
shape, and it makes the model the single producer of the divider position,
which is that ADR's stated precondition for any future restructuring.

## Invariants

- I1. The reducer is the only writer of the sidebar state; the reconcile pass
  is the only programmatic writer of the divider position and the chrome's
  sidebar layout. A native divider drag moves the divider directly, but it is
  provisional input: it must round-trip through the model as a presentation
  report before it is durable.
- I2. Collapsing and reopening the sidebar -- by toggle or by pointer drag --
  restores the previously dragged width exactly; relaunch and crash-restore
  restore both facts.
- I3. Only an admitted width can be observed: any width entering the model --
  from a drag report or a restored snapshot -- lands inside [200, 300]
  (the existing drag bounds). The min bound and `minSidebarWidth` are one
  constant.
- I4. Applying the projection originates no `Msg`: the reconcile pass setting
  the divider position must not re-enter as a drag report, even though
  `splitViewDidResizeSubviews` fires during `setPosition` (same rule
  `SplitContainerView` already obeys for pane dividers).
- I5. A sidebar state change triggers a light checkpoint via the existing
  snapshot-equality policy; no new checkpoint plumbing.
- I6. Width is CGFloat in the model, Double on the wire (the `SplitRatio`
  serialization convention).

## Proof obligations

- PO1 (I1, I2): reducer test -- drag report of 280, then toggle twice; model
  reports collapsed, then expanded at 280. (`lib/DanTermCore` suite, sibling of
  the `.splitRatioChanged` tests in `UpdatePaneTests.swift`.)
- PO2 (I2, I3, N3): snapshot round-trip -- the field survives
  `toSnapshot` / `validateAndBuild`; an out-of-range persisted width is
  admitted to the bounds on restore (pattern: `SnapshotTests.swift`
  "restore admits split ratios"); a version-3 JSON fixture that omits the
  sidebar key decodes and restores to expanded/200 (the hand-written
  `AppModelSnapshot` decoder hard-fails on a missing key unless it defaults,
  and every existing on-disk snapshot lacks the key).
- PO3 (I5): a sidebar message changes `LightCheckpointProjection`
  (pattern: `CheckpointCaptureTests.swift` `.splitRatioChanged` cases).
- PO4 (I1, I2, I4): `tests-ui` -- drive the divider to 280 and toggle twice via
  the catalog command path; the split view's sidebar width returns to 280, and
  a reconcile-applied position emits no drag `Msg` (pattern:
  `SplitContainerViewTests.swift` no-feedback assertions). Also: a
  pointer-driven collapse and re-expansion round-trips through the model and
  restores the stored width; and after drag, collapse, and reopen, the
  chrome's observable sidebar geometry (separator/title alignment) matches the
  split view's actual state. Runs under `just test-ui` (WindowServer required,
  outside the gate). This is the first coverage of the sidebar toggle path.
- PO5: `danterm ls` output includes the sidebar state; the `ls` encoder test
  suite pins the shape.

Note `tests-ui/MenuCommandPolicyTests.swift` asserts the View-menu item list;
it must stay green (the menu item remains, only its dispatch changes).

## Non-goals

- N1. No `view.*` IPC method or CLI subcommand to toggle/set the sidebar --
  read visibility via `ls` only. Full CLI control is a later change.
- N2. No replacement of the sidebar `NSSplitView` with the flat model-owned
  geometry container (ADR D5 defers it).
- N3. No snapshot version bump: the field is additive; old init files without
  it restore to the default expanded/200 state.

## Accepted risks

- AR1. The reconcile pass now writes the divider position, so a pass running
  mid-drag could fight the pointer. The single-struct-compare cache skips
  unrelated sweeps while the desired projection is unchanged, but a queued
  drag report does change the projection, so the pass replays the reported
  position once -- writing back the position the divider already holds. That
  replay is accepted: it is idempotent against the split view's actual state,
  and I4 guarantees it originates no further `Msg`.

## Implementation discretion

- How the reconcile pass reaches the split view (a `weak var` on `AppRuntime`
  like the existing four view refs, or an injectable surface for testability).
- Whether the width bound is enforced by a validated value type (the
  `SplitRatio` pattern) or a reducer clamp, provided I3 holds.

## Commit progress

- [x] 1. feat(chrome): make sidebar presentation model-owned
