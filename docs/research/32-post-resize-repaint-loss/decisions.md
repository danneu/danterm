# Decisions -- post-resize repaint loss

Next free ID: **D2**.

## `D1` -- a view size change forces the next draw to full damage

**Date.** 2026-08-05.

**Decision.** `SwiftTerminalSessionView#setFrameSize` calls
`invalidateFullDisplay()` whenever the new size differs from the old one. The
sparse-damage clip in `#draw` is left exactly as doc 29 and doc 30 shipped it.

**The gate.** Phase 3 opened with three candidates. One was struck before the
gate ran: restoring the unconditional `dirtyRect` fill would blank undamaged
rows the clipped plan never redraws, which is the defect `d3780961` existed to
prevent (`F6`). That left two.

| | forces full repaint on resize | defers the damage snapshot |
| --- | --- | --- |
| depends on `H1`'s ordering being right | **no** | yes |
| touches steady-state sparse damage | no | no |
| new ordering state | none | yes |
| size | one guarded call | structural |

**Why this one.** The deciding criterion was not simplicity, it was
**independence from an unmeasured claim**. `H1`'s ordering -- that the
full-damage snapshot is spent before the layer takes its new size -- is still
inferred from source; the Phase 1 instrumentation that would confirm it has not
been run. A deferral fix presupposes that ordering, so a green test would not
distinguish "fixed for the right reason" from "fixed by coincidence". Forcing a
full repaint is correct under *any* ordering, including ones nobody has
enumerated, so it survives `H1` being answered either way.

**Why `setFrameSize` and not `synchronizeGeometry`.** The first draft gated on a
grid-dimensions change inside `#synchronizeGeometry`. That is wrong for
sub-cell resizes: widening three points on an eight-point cell discards the
layer's backing store while leaving the column and row counts identical, which
is most of the frames in a live drag and therefore most of `F8`'s flicker. The
invariant is about the view's *size*, so the guard belongs where the size
changes.

**Cost, and why it does not pay against doc 29 or doc 30.** Those wins are
steady-state: their own tests describe scattered TUI status-row updates, the
typing and redraw path. This fires only on resize, which is already the
expensive path -- `28/D11` measures the same reflow recipe at 1.58 ms. The three
sparse-clip regression tests still pass, which is the standing guard that the
optimization was not blunted.

**Evidence.** `tests-ui/SwiftTerminalSessionViewTests.swift`, "the first draw
after a resize fills every row", failed with rows `[0...6]` unfilled and passes
with the change. Full UI suite 208/208; `just test` 77/77.

**Fallback.** If a full repaint per resize frame shows up as drag-smoothness
cost, the deferral becomes an optimization layered on top of this correctness
fix rather than an alternative to it. Measure with the benchmark harness in
`agent-docs/terminal-performance.md` before reaching for it.

**Not yet closed.** Confirmation in the real app -- `F8`'s fast-drag flicker
absent, and the `F1` recipe clean in zsh -- is still outstanding at the time of
writing.
