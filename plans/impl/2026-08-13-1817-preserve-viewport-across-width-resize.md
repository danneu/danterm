# Preserve Viewport Layout Across Width-Resize Round Trips

## Problem

A primary-screen width resize can consume blank rows below the cursor. A later
resize back to the original width cannot recover that layout because the first
resize discarded the viewport alignment that distinguished those blanks from
space available for history pull-back. Retained history then enters the
viewport, and an application that redraws at its original coordinates leaves a
stale shifted copy of its composer visible.

The defect reproduces headlessly from the affected Codex pane. Removing only
the 89 -> 59 -> 89 resize pair removes the artifact. A reduced 10-column by
6-row case reproduces it only when retained history is present, which places the
fault at the primary history/live reflow seam rather than in Codex, AppKit, or
the renderer.

## Decision

Primary-screen width reflow will preserve viewport alignment across a series of
consecutive width changes. A series that starts above the bottom records the
viewport's top logical position and the cursor's logical attachment, including
its distance into never-written trailing padding, and restates both after each
width change. A series that starts on the bottom keeps the existing
bottom-follow behavior.

The engine will keep the recorded top position when the reflowed cursor and
live content fit. It will shift only as far as needed to keep the cursor and
trailing live content visible. Space released by widening becomes never-written
blank rows below live content before retained history may enter the viewport.
If eviction removes the recorded position, the engine clamps it to retained
content.

Output that mutates the primary screen, a height change, explicit viewport
navigation, reset, or a screen transition ends the series and establishes a new
layout. Output applied to the alternate screen does not end a primary resize
series because it cannot change the stashed primary layout. In a combined height
and width resize, the height leg ends the prior series and the width leg may
start a new series from the post-height layout. Invalid and same-size resize
requests remain bit-identical no-ops.

The contract governs primary reflow even while the alternate screen is active.
A series may start and continue as behind-alternate width changes reflow the
stashed primary. Entering or leaving the alternate screen remains a terminating
screen transition.

This state is part of the terminal value because it changes the result of a
later resize. The implementation will reuse the engine's logical-address and
anchor-restatement model. No public API changes.

## Invariants

- I1. Returning to an earlier width without an intervening layout-establishing
  event restores the earlier primary viewport, cursor attachment including
  never-written trailing-padding distance, and history/live seam.
- I2. Intermediate widths keep the cursor and trailing live content visible
  without converting consumed trailing viewport blanks into pulled history.
- I3. A resize series that starts with the cursor on the bottom retains the
  existing behavior: widening may pull eligible retained history into freed
  rows.
- I4. Width reflow preserves full-history logical text and grid validity at
  every intermediate width.
- I5. Alternate-screen rectangle resize and the explicit browsing viewport
  contract remain unchanged; primary reflow behind the alternate screen still
  satisfies I1-I4.

## Proof Obligations

- PO1 (I1, I2, I4). Use TDD: first add a failing reduced regression from the
  Codex composer incident. Start with retained history, two full-width live
  lines, a composer row, and trailing blank rows; resize 10 -> 5 -> 10. Assert
  exact viewport text and row structure, cursor state, scrollback row count,
  history/live seam, and unchanged full-history text.
- PO2 (I1, I2). Exercise a multi-step series such as
  10 -> 7 -> 5 -> 8 -> 10 so the proof requires durable alignment rather than
  a special inverse-pair calculation. Include a cursor parked in never-written
  trailing padding and assert that its original column is restored.
- PO3 (I3). Keep the existing bottom-cursor width-growth proof green and assert
  that eligible history still enters freed rows.
- PO4. For each terminating event -- primary-screen output, height change,
  viewport navigation, reset, and screen entry or exit -- prove that a later
  width change cannot resurrect the layout from the ended series. Cover the
  ordered height-then-width behavior of a combined resize.
- PO5 (I1, I5). Perform a width round trip while the alternate screen is active,
  with alternate-screen output between the width changes. Then reveal the
  primary and assert its viewport, cursor, and history/live seam are restored
  while the alternate rectangle behavior remains unchanged.
- PO6 (I1, I4). Force scrollback budget eviction past a recorded top position
  during a resize series. Assert that restoration clamps to retained content,
  does not resurrect evicted rows, and preserves full-history and grid
  invariants.
- PO7 (I4, I5). Run the primary and alternate resize tests, then the full local
  gate.

The regression test will include the required Intent, Why it exists, and
Scenario preamble and will name the Codex composer incident.

## Rejected Ideas

- Do not change AppKit resize delivery or renderer behavior. Headless replay
  already produces the wrong grid.
- Do not disable history pull-back. That would break the bottom-follow resize
  contract.
- Reject stateless reflow that stops consuming trailing viewport blanks and
  instead displaces every new continuation into history. It would make a width
  round trip self-inverse, but it breaks the pinned shrink behavior in
  `widthShrinkDoesNotSelfPush` and
  `widthShrinkCountsAllContinuationsAboveCursor`.

## Non-goals

- Restoring a pre-drag layout across height changes is not part of the width
  resize-series contract. A combined resize establishes its post-height layout
  before its width leg begins a new series.

## Documentation

Amend `docs/design/2026-08-06-swift-terminal-engine.md` D7 to state the
consecutive-width-resize viewport contract.
