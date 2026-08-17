# One presentation-input detector in the pane view

## Context

`SwiftTerminalSessionView` answers "did a presentation input move?" twice,
with two tests of different width:

- `synchronizeGeometry()` re-renders when `metrics != currentMetrics`.
- `rerenderIfSurfaceInputsChanged()` re-renders when the full `SurfaceInputs`
  tuple -- columns, rows, metrics, **color space** -- differs from the live
  swapchain's.

`metrics` is a field of `SurfaceInputs`, so the first test is a strict subset
of the second. Correctness then depends on each entry point calling the right
combination: the two window hooks call both, while `setFrameSize`,
`setFontSize`, `setFontFamily`, and `refreshBackingProperties()` call only the
narrow one.

That asymmetry is a live defect on the exact path the wide detector exists for.
`AppRuntime.refreshSessionsForScreenChange` exists because AppKit can skip
`viewDidChangeBackingProperties` on a screen change (`app/AppRuntime.swift:466-478`),
and it reaches the view through `refreshBackingProperties()`, which cannot see a
color-space move. A window moving to a display with a different profile at the
same backing scale therefore leaves the pane showing the previous profile's
colors. It self-heals on the next publish, because `surfaceSwapchain` does
compare color space -- so the failing case is a pane with no output.

Desired outcome: one entry point, one test, and no caller able to select a
partial check.

## Direction

Merge the two into a single private `synchronizePresentation()`, and route every
entry point through it: `setFrameSize`, `viewDidMoveToWindow`,
`viewDidChangeBackingProperties`, `setFontSize`, `setFontFamily`, and the
protocol-facing screen-change method.

This is research/33 T25 I3 -- the swapchain trust rule -- stated once instead of
approximated in two places. The merged method is the only place that decides
whether buffers can still be trusted.

Rename the protocol member `refreshBackingProperties()` to `refreshPresentation()`
(`app/TerminalSession.swift:155`, its caller in `AppRuntime`, and the three empty
stub conformances in `tests-ui/` and `app-tests/`). The old name describes the
AppKit callback it imitates, not the job it does, and that false implication is
what let the hole open.

## Invariants

1. **One render trigger.** Exactly one predicate in the view decides whether a
   presentation input moved, and it compares the whole `SurfaceInputs` tuple. No
   entry point can re-render on a narrower test.

2. **The comparison's columns and rows come from the live swapchain, not from
   newly computed grid dimensions.** A grid resize republishes through
   `controller.setGridDimensions`, and presenting the *old* plan under the *new*
   shape would render a stale plan and build a swapchain the next publish
   immediately replaces. Columns and rows live in `SurfaceInputs` to key
   swapchain identity in `surfaceSwapchain`, not to drive the detector. This
   looks like an omission and needs a comment saying it is not.

3. **No live swapchain counts as a difference.** With no buffers, the current
   plan has never reached the screen, so it must render. This preserves today's
   first-geometry case, where `synchronizeGeometry` renders on a metrics change
   before any swapchain exists.

4. **The non-positive-dimension guard stays.**
   `docs/design/2026-03-05-display-scaling.md` holds that scale and pixel size
   are one invariant and the guard is part of it, not a defensive check. The
   merged method keeps the same bail on zero bounds, absent window, unusable
   metrics, or refused grid dimensions.

5. **State emission stays gated on a metrics change.** `metricsChanged` survives
   as the trigger for `emitStateIfNeeded()`; it stops being a render trigger.
   `emitStateIfNeeded` reads `controller.viewportState`, and `setFrameSize` fires
   continuously during a divider drag, so an unconditional call would add a
   viewport read per drag frame for no observable gain.

## Behavioral scope

Every entry point now sees a color-space move, because invariant 1 gives them all
the same test. The screen-change path is where that fixes a live defect; on
`setFrameSize`, `setFontSize`, and `setFontFamily` it means a color-space move
that coincides with a resize or a font change re-renders there too, instead of
waiting for the next publish. Those extra renders are intended -- they are
invariant 1 holding, not a regression.

Everything else is intended to be behavior-preserving, including the mount
sequence -- one swapchain and one full-frame render on mount, as
`tests-ui/SwiftTerminalSessionViewTests.swift:361` already pins.

## Non-goals

- Changing when a pane publishes state, or what `emitStateIfNeeded` reports.
- Touching the swapchain, the retry, or `applyResolvedTheme`'s own
  discard-and-render path. A theme change breaks trust in a way no value
  comparison can see, so it stays a separate explicit discard.
- Reworking `AppRuntime.refreshSessionsForScreenChange`'s deferral. The
  one-main-loop-turn delay is orthogonal and still needed.

## Accepted risks

- With invariant 3, a persistent swapchain allocation failure means every
  `setFrameSize` retries a full render. That path is already broken, and
  retrying is the correct response to it; worth a comment rather than a guard.

## Rejected ideas

- **Adding `rerenderIfSurfaceInputsChanged()` to the two entry points that lack
  it.** This is the audit's cheaper fallback. It closes today's hole but keeps
  the two-detector shape that produced it, so the next entry point added has the
  same chance of picking the wrong combination.

## Critical files

- `app/SwiftTerminalSessionView.swift` -- the merge, and all six call sites.
- `app/TerminalSession.swift` -- the protocol member rename.
- `app/AppRuntime.swift` -- the one production caller.
- `tests-ui/SidebarViewTestShim.swift`, `app-tests/PaneHostHeadlessTests.swift`,
  `app-tests/AppRuntimeCommandTestSupport.swift` -- empty stub conformances.
- `tests-ui/SwiftTerminalSessionViewTests.swift` -- new and existing coverage.
- `docs/scratch/2026-08-11-simplification-audit.md` -- mark S19 as landed
  after the implementation commit exists.

## Verification

The UI harness constructs and drives this view directly, so every obligation
below is a real behavioral test. TDD: the first one must fail before the merge,
for the stated reason.

| Claim | Proof |
|---|---|
| The screen-change path sees a color-space move (the defect) | Mount a pane, change `window.colorSpace` at unchanged scale and grid, drive the screen-change entry point, and expect one swapchain replacement and a full-frame render. Model it on the existing test at `tests-ui/SwiftTerminalSessionViewTests.swift:635`, which does the same through `viewDidChangeBackingProperties`. **Must fail before the change.** |
| Invariant 1, through the AppKit hook | The existing color-space test at `:635` stays green against the single entry point. |
| Invariant 2 | A `setFrameSize` that changes the grid does not itself render the stale plan; the swapchain is replaced by the controller's republish, not by the view. |
| Invariant 3 | The existing mount test at `:361` (one complete frame, nothing submitted) and the metrics-change test at `:525` stay green. |
| Invariant 4 | Mount a pane, reset its counters, set one frame dimension to zero, and expect no grid submission, no swapchain replacement, and no render. The existing tests do not reach this: `:168` uses a positive 10x10 frame, and `:185` calls the pure geometry functions directly rather than through the view. Both stay green as well. |
| Invariant 2's premise: a quiet resize republishes | A controller-level test in `lib/TerminalPTY/Tests/TerminalPaneSessionTests/TerminalPaneSessionControllerTests.swift`: resize a quiet visible session and expect a full frame at the new dimensions with no terminal output following. Existing resize coverage there pairs a resize with printed output (`:1311`, `:1387`, `:1429`), so the quiet case is unproven -- and it is what the view now deliberately declines to render itself. |
| Invariant 5 | Install a state observer on a mounted pane, change the font metrics, and expect the observer to receive the new cell height. The existing font-size test at `:95` reads `pane.state.cellHeight`, which is a live getter and stays correct even if the emit is dropped; the only observer-based emit test (`:65`) covers the theme path. `ScrollableTerminalView` is the observer and re-reads state on each callback, so a lost emit leaves the scrollbar on its old document geometry until some unrelated event triggers a sync. |
| Behavior preservation elsewhere | The resize test at `:562` and the theme test at `:599` stay green. |

Run with `just test-ui > .build/ui.log 2>&1`, then grep the log. It needs a
WindowServer connection, so run it from a GUI session, not headless. Follow with
`just test` for the rest of the gate.

Then confirm in the real app: `just launch-slot`, drag a window between two
displays with different color profiles while a pane sits idle, and check the
pane's colors do not wait for the next byte of output.

## Final audit bookkeeping

After the implementation is committed and its commit SHA exists, put that SHA
in S19's Status cell in
`docs/scratch/2026-08-11-simplification-audit.md`. Commit this audit update as
the final documentation commit; a commit cannot record its own SHA.

## Commit progress
- [x] 1. One presentation-input detector in the pane view (merge, rename, tests)
- [ ] 2. Record S19's landing SHA in the simplification audit

## Implementation notes

- The protocol rename landed first, as its own mechanical step, so the
  screen-change test could go red on behavior -- "did not replace the swapchain:
  0" -- rather than on a missing symbol.
- The comparison is inlined in `synchronizePresentation` rather than kept as a
  private helper it calls. A helper would still be one predicate, but it would
  also be a second callable method, which is the shape the defect came from.
- `docs/design/2026-03-05-display-scaling.md`'s supersession banner named
  `synchronizeGeometry` as the code that carries its invariant, so the rename
  updated it. The plan did not list that file. The audit's S19 body and the
  research docs keep the old names, which is correct: they are history.
- The two-display check at the end of Verification is not done. The agent's
  environment has one display, so nothing here can move a window between two
  color profiles. The UI harness covers the same move through the screen-change
  entry point.

## Follow Up

- `tests-ui/SidebarRenameRecycleTests.swift:605` ("group structural exits end the
  exact live rename") failed once during this work -- "removal should clear
  projected rename ownership" -- and passed on an immediate re-run with nothing
  in the sidebar touched. It is flaky, and nothing in this commit reaches it.
