# Divider grab offset stored on every press

Source: docs/scratch/2026-08-26-improvement-audit.md, INPUT-8 (Wave 12).

## Problem

`PaneDividerView.mouseDown` returns early on a double-click before it
computes `dragOffset`, and `mouseUp` clears the stored offset between
clicks. A drag that continues out of the second click therefore reaches
`mouseDragged` with no offset, and the fallback branch treats the raw
pointer position as the divider position. Because the double-click just
reset the split to 0.5, the pointer sits near the *old* divider
position, so the first drag event can yank the divider most of the way
back -- the jump is bounded by the distance between the old and reset
positions, not by the 7pt hit strip.

Verified live at `app/PaneDividerView.swift:93-116` on master.

## Decision

On a double-click, run `resetToEvenSplit()` first; its model round trip
is synchronous (ADR 2026-08-16 D2), so `placement` is the post-reset
placement when it returns. Then capture the grab offset through the
same path every press uses, anchored to the placement now in effect.
`mouseDragged` requires `dragOffset` and subtracts it unconditionally;
the branch that guesses a grab point is deleted. `dragOffset` stays
optional with one meaning -- "a drag is in progress, grabbed at this
offset"; nil means no drag.

This stays inside the view's gesture bookkeeping. The ADR's D2/D4 are
unchanged: the divider still only reports gestures and waits for the
model round trip.

## Invariants

- I1. A double-click first resets the split to 0.5, and a continued
  drag then moves the *reset* divider by the pointer's travel -- it
  never re-anchors to the pre-reset divider position.
- I2. A drag with no recorded press on this divider reports no ratio.

## Proof obligations

- PO1 (I1): behavioral test in `tests-ui/SplitContainerViewTests.swift`
  (runs under `just test-ui`, not the gate). Start at a ratio well away
  from 0.5, deliver a `clickCount: 2` press near the divider, apply the
  reported 0.5 reset through the synchronous round trip (the
  `runtime.onSend` -> `setRootNode` pattern already in the file), then
  deliver a drag with known pointer travel and assert the reported
  ratio equals the reset divider position plus that exact travel.
- PO2 (I2): drag event delivered with no prior press reports no ratio
  change.

Both tests are written before the implementation and observed to fail
for their expected reasons (PO1 on the stale-anchor jump, PO2 on the
current guess-a-grab-point fallback).

## Non-goals

- No change to who owns the ratio (the model round trip, per the ADR).
- No change for a press with nil `placement`; it still stores nothing,
  and by I2 a following drag does nothing.

## Verification

TDD per the proof obligations above; `just test-ui` for the suite;
`just test` before commit.

After the commit, tick INPUT-8's box in
`docs/scratch/2026-08-26-improvement-audit.md` `## Plan of work`
(line ~392) with `-- done <sha>`.

## Commit progress

- [x] 1. fix(divider): preserve the post-reset grab offset
- [ ] 2. docs(audit): mark INPUT-8 complete
