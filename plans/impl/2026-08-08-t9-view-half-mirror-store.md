# T9 view half: an owned mirror frame store realizes shift damage at the drawing seam

## Problem, outcome, evidence

A paced producer's scroll frame submits ~11,570 glyph occurrences to express
~178 changed cells, because the drawing seam folds the carried shift into
region-wide row damage (`clipFramePlan`, `SwiftTerminalSessionView.publish`;
research/33 `F21`). Glyph submission is priced per occurrence including
off-main-thread bounds work (`17/F6`), so this fold is the remaining scroll
cost after the engine/planner half landed. The desired outcome is `D7`'s
second half: a scrolled frame's drawing cost is the damaged rows plus the
halo, not the region.

Load-bearing premises, all measured:

- The seam already carries the shift end to end; only the two fold sites
  discard it (`F21`).
- AppKit's backing store cannot realize a translation: `scroll(_:by:)`
  preserves no bits on a layer-backed view and silently repaints the
  copy-destination region (`F22`). Any translation must happen in memory the
  view owns; AppKit's store is a blit target only.
- A row shift is integral in backing pixels by construction
  (`TerminalRenderMetrics.cellHeightPixels`).
- The paced regime is the win regime and sits under the display rate; the
  flood regime gains nothing from translation (`F19`, `F13`).

## Decision

Per the `D7` addendum (recorded against `F22`): the view keeps one grid-sized
mirror bitmap at backing-pixel resolution. A shift-carrying publish translates
the mirror's region in place and renders only damaged rows into it through the
existing executor; `draw(_:)` satisfies its dirty rect by blitting from the
mirror instead of re-executing glyph runs. The mirror is maintained only while
it pays: a `.full` publish marks it stale at zero cost, and stale-mirror
drawing is the existing folded path unchanged. The change lands as one
separately revertible slice stack, degrading to the planner-only win if
reverted.

## Invariants

- I1 **Pixel equivalence.** Every displayed frame is byte-identical to a
  full redraw of the published plan, in every regime and across every
  mirror-validity transition.
- I2 **Countable win.** With a valid mirror, a shift-carrying publish submits
  glyph occurrences only for the damage-set rows plus the glyph halo.
- I3 **Flood untouched.** A `.full` publish performs no mirror work, and the
  stale-mirror publish and draw paths are behaviorally today's paths.
- I4 **One validity bit.** Whether the mirror may serve a draw is a single
  owned validity state; no consumer enumerates known-good conditions. Any
  uncertainty (fresh store, geometry, scale, theme, first frame) resolves to
  stale, and stale never renders worse than current behavior.
- I5 **Exact translation.** The mirror translation is an integral
  backing-pixel row move of exactly the recorded `(region, delta)`; a shift
  the mirror cannot realize exactly falls back to the folded redraw.

## Proof obligations

- PO1 (I1): headless byte-equality on the owned store -- translate plus
  damaged-row render equals a from-scratch full render -- across the `D7`
  scenario matrix: whole-viewport scroll, `DECSTBM` sub-region, at-budget,
  composed shifts, overlay/cursor rows, wide glyphs and sprites at the halo
  boundary.
- PO2 (I2): `t5-scroll-amplification.py` `glyphs/frame` falls from 11,570 to
  the ideal plus halo at one line per delivery, with the
  `rewrite-bottom-row` control unmoved.
- PO3 (I3): the flood arm of the same probe is unchanged, and the calibrated
  ladder reads `scrollback-stream`, `content-churn`, and `style-churn` as
  non-regressing.
- PO4 (I1, I4): view-level pins in the UI harness covering path selection and
  invalidation: a shift publish with a valid mirror invalidates and blits the
  translated region; every stale-mirror trigger falls back to the folded
  path; the existing drawn-row and clip-rect pins keep holding on that path.
- PO5: live re-runs after landing: `t9-lines-per-delivery.sh` (paced shape
  unchanged at O(1) rows), and `t4-publish-rate.sh` for `F20`'s prediction
  that the flood publish rate rides up once whole-screen drawing stops
  bounding the cycle.

## Non-goals

- Full store ownership via `wantsUpdateLayer`/`layer.contents` (the `D7`
  addendum's named alternative; becomes the follow-up only if the blit shows
  up in the gates).
- Translating or trusting AppKit's backing store in any form.
- Reclaiming mirror memory on idle or occlusion.

## Accepted risks

- One grid-sized bitmap per pane that enters the paced-scroll regime
  (~28 MB for a full-screen 2x pane), retained for the pane's lifetime.
  Rationale: allocation churn at the flood/paced boundary is the alternative,
  and only panes that scroll paced output pay.
- A region-wide blit per drawn scroll frame while the mirror is valid: the
  unavoidable residue of `F22` (the on-screen store cannot translate), and
  cheap relative to the glyph submission it replaces.

## Implementation discretion

- Mirror storage, blit API, and buffer reuse strategy, provided I5's
  exactness holds.
- Test-seam shape in the UI harness for observing path selection and blits.

## Commit progress

- [x] Mirror store type in the render-execution module with PO1's
  byte-equality suite (green headless). (`0e92778d`)
- [x] View integration: publish-side maintenance, draw-side blit, validity
  transitions; PO4's harness pins. (`10eff94a`, harness repair `630b56e5`)
- [x] Instrumentation reconciled (benchmark draw observation, t5 probe's
  view-facing model) and PO2/PO3 recorded. (`fa99391a`; PO2 glyphs/frame
  11,570 -> 1,086, PO3 ladder non-regressing with `scrollback-stream`
  `faster` -3.55%)
- [x] Live PO5 runs, calibrated ladder, research ledger closure (finding
  `33/F23`, README `T9` entry, `D7` status).
