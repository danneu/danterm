# Milestone 6 slice 11: application-requested cursor shapes

## Context

The renderer contract requires the initial presentation to honor the
application-requested cursor shape. TerminalCore already models DECSCUSR as
`TerminalCursorShape.block`, `.underline`, or `.bar`, but the render-planning
boundary previously dropped that choice and always produced a filled block.

This slice delivers cursor shapes only. Application-requested cursor blinking,
including focus/visibility/activation gating and timer lifecycle, is explicitly
deferred. This slice therefore does not claim to complete the renderer's cursor
behavior or close the Milestone 6 renderer gate.

## Decision

- **D1 -- Explicit shape input.** `RenderPresentation` carries
  `TerminalCursorShape`, and the pane session threads the terminal's current
  request into every planned frame. Planning remains deterministic over
  explicit inputs.
- **D2 -- Preserve block rendering.** Block cursors keep the existing baked
  foreground/background override. Underline and bar cursors leave the covered
  cell's colors untouched and carry shape, normalized span, and resolved cursor
  color in `RenderCursor` metadata.
- **D3 -- Final overlay pass.** The executor draws underline and bar cursors in
  a final pixel-aligned overlay pass. The planner and executor share the same
  wide-head/wide-tail normalized span through the render plan.
- **D4 -- No periodic work.** This slice adds no timer, focus input, activation
  input, phase state, or recurring redraw work.

## Invariants

- **I1 (shape rendering).** DECSCUSR block, underline, and bar shapes produce
  distinct renderer output.
- **I2 (block compatibility).** Block cursor planning and execution retain the
  existing baked-style behavior.
- **I3 (cell preservation).** Underline and bar overlays do not replace the
  covered cell's normal foreground, background, glyph, or decoration planning.
- **I4 (wide-cell consistency).** A cursor on either half of a wide cell snaps
  to the same two-column span for every shape.
- **I5 (redraw equivalence).** Cursor-row partial redraw and full redraw produce
  identical output for every shape.
- **I6 (quiescence).** Shape support introduces no periodic work.

## Proof obligations

- **PO1 (I1-I4).** Planner tests prove shape metadata, block overrides,
  underline/bar cell-color preservation, hidden-cursor omission, and wide-cell
  snapping for all shapes.
- **PO2 (I1, I3).** Bitmap tests prove underline and bar geometry at 1x, 1.5x,
  and 2x backing scales without changing neighboring cells or pixels outside
  the overlay.
- **PO3 (I2, I5).** Existing block proofs remain green, and incremental
  cursor-row redraw matches a fresh full frame for block, underline, and bar.
- **PO4 (I5).** The neutral-fixture corpus uses each terminal snapshot's actual
  cursor shape while proving damage-overlay equivalence.
- **PO5.** `just test`, `just build`, and `just test-ui` pass.

## Non-goals

- Application-requested cursor blinking or blink-phase state.
- Visibility, render-focus, or application-activation blink gating.
- Timer ownership, scheduling, reset behavior, or teardown proofs for blinking.
- A hollow or outline cursor variant for unfocused panes.
- Configurable cursor shape, blink interval, or preference plumbing.
- Declaring the Milestone 6 renderer cursor contract complete.

## Accepted risks

- **AR1.** The renderer continues to show blinking DECSCUSR variants as steady
  cursors until the deferred blinking work is planned and implemented.
- **AR2.** The roadmap's cursor-behavior gate remains open; this plan proves only
  its shape-rendering portion.

## Rejected ideas

- **RI1.** Moving block cursors into the overlay pass would change established
  glyph and corpus behavior without helping shape support.
- **RI2.** Adding partial blinking infrastructure now would leave timer and
  lifecycle behavior without its complete focus, activation, and teardown
  contract.

## Implementation discretion

- Underline and bar thickness, provided it is pixel-aligned and at least one
  backing pixel.

## Commit progress

- [x] 1. Plan and render DECSCUSR cursor shapes (planning, executor overlay pass, corpus updates)

## Follow Up

- Write a new plan before implementing application-requested cursor blinking.
  It must cover deterministic demand/phase policy, cursor-row-only damage,
  synchronized-output publication, pane visibility and render focus, app
  activation fan-out, AppKit timer ownership/reset, teardown safety, explicit
  scheduling traces, and the remaining Milestone 6 roadmap gate.
