# Make the main window resizable (constraint-based sidebar split)

## Problem

The main window cannot be resized by any path: no resize cursor at the
edges, AX resize requests (Raycast hotkeys, macOS quadrant tiling) are
accepted but silently dropped, and an in-process `setFrame` snaps back
on the next layout pass.

Root cause, confirmed live in a dev slot: `sidebarView` and
`contentArea` (`app/AppDelegate.swift:117,121`) are arranged subviews
of a constraint-based `NSSplitView` but keep
`translatesAutoresizingMaskIntoConstraints = true`. AppKit converts
their frames into required `NSAutoresizingMaskLayoutConstraint`s
(sidebar.width == 300, contentArea.width == 1427, plus the vertical
equivalents), and 300 + 1 + 1427 pins the window to exactly its
current size. Flipping the flag to false on both subviews in the
running app made the very next AX resize succeed.

Secondary symptom, same cause: the window opens at whatever frame was
autosaved (`NSWindow Frame MainWindow` = 1728x1083) and can never
leave it.

## Decision

Make both arranged subviews constraint-based and let `NSSplitView`
own the divider layout, as it is designed to when its subviews opt
into Auto Layout. Extract the sidebar-split construction (split view,
sidebar, content area, priorities, delegate wiring) into one builder
used by both `AppDelegate` and the UI-test fixture
(`tests-ui/SidebarPresentationTests.swift:117-141`), which today
hand-mirrors production wiring — the mirror is how this bug escaped:
the fixture reproduced the broken wiring but no test ever resized
anything.

This stays inside D5 of
`docs/design/2026-08-16-model-owned-pane-geometry.md`: still two
arranged subviews, the split view still produces only the pane
container bounds.

## Invariants

- I1: After construction, the window accepts any size >= `minSize`
  (600x300) from every resize path (in-process `setFrame`, AX/window
  managers, edge drag); the accepted size survives the next layout
  pass.
- I2: Window resize changes only the content area; the sidebar keeps
  its width.
- I3: The existing sidebar loop is unchanged: divider drag reports the
  real width via `.sidebarPresentationReported`, model clamps to
  [200, 300], collapse preserves the last expanded width, reconcile
  applies the model width via `applySidebarPresentation` without
  echoing a report. `sidebarView.frame.width` stays meaningful (the
  reporter and existing tests read it).
- I4: The UI tests for sidebar behavior exercise the production
  construction path, not a hand-copied fixture.

## Proof obligations

- PO1 (I1): New UI test — build the production split/window layout,
  resize in both directions — shrink to `minSize` (600x300), run
  layout, assert the frame took and sticks; then grow and assert
  again. Must fail against the current wiring (shrink and grow are
  distinct failure modes: compression constraints can block one while
  the other works).
- PO2 (I2): After each PO1 resize, assert sidebar width unchanged and
  the content area absorbed the whole delta.
- PO3 (I3): Existing `tests-ui/SidebarPresentationTests.swift` and
  core sidebar tests (`UpdatePaneTests`, `SnapshotTests`) stay green.
  Additionally, a UI test moves the divider through NSSplitView's
  public path (e.g. `setPosition(_:ofDividerAt:)`) and asserts the
  runtime receives `.sidebarPresentationReported` — without the test
  invoking any delegate method directly — proving the builder wires
  the split-view delegate.
- PO4 (I4): The fixture calls the shared builder; discharged by
  inspection in review.

## Non-goals

- No migration for the stale autosaved frame; the first manual resize
  overwrites it.
- No change to model-owned sidebar state, IPC shape, or the pane
  geometry owner (D5 untouched).
- No change to `WindowChromeView` metrics handling (already
  constraint-based and driven by window notifications).

## Implementation discretion

- How the split view keeps the sidebar fixed during window resize
  (keep the `shouldAdjustSizeOfSubview` delegate method, or replace
  with `setHoldingPriority`) — whichever satisfies I2/I3.
- Builder shape and where it lives, provided both production and the
  fixture call it.

## Verification

- `just test-ui` (sidebar suites + the two new resize tests; needs a
  WindowServer, run locally).
- `just test` before commit.
- Manual: `just launch-slot`, then resize the dev window by edge drag
  and via an AX resize (System Events / window-manager hotkey);
  confirm both work and the window opens at the last size after
  relaunch. `just stop-slot <n>` after.

## Commit progress

- [x] 1. fix(window): make the main window resizable

## Implementation notes

- The pin needs two ingredients, not one. A minimal on-screen replica of the
  broken wiring (mask-translating arranged subviews, the production delegate,
  event pumping) accepts every resize. The pin appears only when the
  split-view delegate is attached after the window's first layout -- the
  order `applicationDidFinishLaunching` used (delegate wired well after
  `window.contentView` and `orderFront`). Confirmed both ways: a clean-HEAD
  dev slot drops AX resizes and pins fully after its first accepted resize,
  and an in-process probe with the late-delegate order refuses `setFrame` in
  both directions; the same probe with the delegate wired at construction, or
  with no delegate at all, resizes freely. The fix is still the plan's
  structural one, and the builder also wires the delegate at construction, so
  both ingredients are gone.
- Builder scope: `makeMainWindowContent` builds the whole content hierarchy
  (chrome constraints and root view included), not only the split. The same
  fixture-mirrors-production drift could hide a pinning constraint in the
  root assembly; window creation and chrome-button wiring stay with the
  caller.
- Implementation discretion resolved: both mechanisms are present. With the
  legacy delegate methods implemented, NSSplitView resizes subviews on its
  legacy pass, where holding priorities do not govern -- removing
  `shouldAdjustSizeOfSubview` let a window shrink redistribute the sidebar
  proportionally (280 -> 168 at minSize, caught by PO2). The delegate method
  stays; holding priorities cover constraint-driven passes.
- The resize test orders its window on screen (`orderFrontRegardless`,
  existing suite precedent, `orderOut` deferred): the pin engages only in a
  window whose layout engine is live on screen; offscreen, the same broken
  wiring accepts any `setFrame`.
- PO1's "must fail against the current wiring" was verified as a temporary
  two-site mutation after the builder refactor landed: builder reverted to
  mask-translating subviews and the fixture attaching the delegate after the
  window's first layout (master's order). The new resize test fails there
  (the broken constraints override even the reconcile-applied sidebar width
  on screen) and passes restored; 450/451 vs 451/451. The mutation is not
  committed.
- The fixture clears `runtime.sentMessages` after construction: with the
  production window and a real layout pass, construction itself emits
  split-view resize reports that two existing tests would otherwise count.

## Follow Up

- The `danterm` CLI cannot drive or observe window frames; this change was
  verified with `osascript`/System Events AX calls against a slot. Per
  AGENTS.md's remote-controllability goal, a `danterm window` command
  (report frame, set frame) would make resize regressions scriptable without
  Accessibility trust (`integrations/danterm/SKILL.md`).
