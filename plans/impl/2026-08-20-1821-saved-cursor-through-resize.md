# Carry the saved cursor through every resize the live cursor survives (BUG-16 + BUG-17)

## 1. Problem

The DECSC slot (`screen.savedCursor`, a position plus pending-wrap flag) is not
tracked through a primary-screen resize. `Terminal.swift#resizeHeight` shifts
only the live cursor when rows move into or out of history, and
`Terminal.swift#resizeWidth` reflows only the live cursor; the saved slot is
clamped into the new rectangle afterwards by `clampScreenCursorState`. So a
DECRC after a resize lands on different text than was saved.

Audit findings BUG-16 (width) and BUG-17 (height) in
`docs/scratch/2026-08-18-construction-audit.md` reproduce on the current tree;
both are the same defect. The user-visible path is `CSI ?1049h` (implicit save
of the shell's cursor), a window resize while vim/less/htop runs, then
`CSI ?1049l`: the shell's cursor comes back rows or columns away from its
prompt and the next prompt overwrites output.

Evidence, not authority (engine design doc A4): kitty
`kitty/screen.c#rewrap` tracks the main and alternate saved cursors as extra
tracked cursors beside the live one; ghostty `src/terminal/Screen.zig#resize`
pins `saved_cursor`, rewrites it after reflow, re-derives `pending_wrap`, and
homes it when it leaves the active area. xterm adjusts only on alternate-screen
growth and does not reflow. Follow kitty and ghostty.

Premise that is load-bearing: DECSC saves a *screen* position. Under ordinary
scrolling it does not follow content (xterm, kitty, ghostty all keep a plain
row/column), so storing the slot as a stream-absolute anchor is wrong; the
slot follows content only during a resize, exactly as the live cursor does.

## 2. Decision

Carry the saved cursor through every primary-screen resize in two ordered
stages. The stages are not symmetric: the live cursor decides the new layout,
and the saved cursor is a passenger through it.

1. **The live cursor alone determines the resized layout.** It keeps viewport
   priority: the row delta a height change produces, and which trailing blank
   rows the resize trims or keeps, are decided by the live cursor and the
   content, never by the saved slot. This stage is byte-for-byte today's
   behavior (I7).
2. **The saved cursor is then mapped through that completed transformation.**
   It does not re-run layout; it is displaced by the row delta stage 1
   produced, or reflowed through the same attachment code path the live cursor
   went through (same logical cell, boundary for a pending wrap,
   trailing-padding distance for a position past content), and its
   pending-wrap flag is whatever that mapping yields for it. Two fallbacks
   apply when there is no cell to follow: a row that left the active area
   takes the live cursor's off-screen policy (I3), and a position on a
   never-written blank row keeps its offset below the content and clamps
   (I8). Either fallback may land the saved slot on a different cell than the
   live cursor's rule would -- that is expected, because stage 2 never feeds
   back into stage 1.

Also:

- The alternate screen is unchanged: its rows keep their coordinates (D10),
  so clamping its saved slot stays correct.
- The primary's saved slot is carried whether or not the alternate screen is
  active at resize time.

Scope: `lib/TerminalCore` only -- `Terminal.swift` resize paths and
`SavedCursorState`. No IPC, persistence, or rendering change. Engine design doc
D7 gains a sentence stating the two stages: a resize's layout is decided by the
live cursor, and the saved cursor is mapped through the resulting displacement
or reflow by the same attachment rules, with the off-screen and blank-row
fallbacks above.

## 3. Invariants

- I1. After a primary-screen height change, DECRC lands on the same cell
  (same logical content) that DECSC saved, whenever that cell is still on
  screen.
- I2. After a primary-screen width change, DECRC lands on the same logical
  cell that DECSC saved, with the same attachment rules the live cursor uses
  (cell, pending-wrap boundary, trailing-padding distance).
- I3. A saved position whose row leaves the active area on a shrink follows
  the live cursor's existing policy: row 0, column kept, then the usual
  clamp.
- I4. The saved slot's pending-wrap flag after a width change is true only
  when the reflowed position sits at the new right edge, and DECRC's
  existing re-arm rule (`autowrap && column == columnCount - 1`) is
  unchanged.
- I5. The saved cursor is carried through a resize regardless of which
  screen is active: `CSI ?1049h`, resize, `CSI ?1049l` restores the shell's
  cursor onto its saved cell.
- I6. Alternate-screen resize behavior is unchanged: no reflow, cells keep
  coordinates, both cursors clamp off wide tails (D10).
- I7. Resize outside of DECSC/DECRC is unchanged: the live cursor, history,
  selection, search, hover, and browsing anchors land exactly where they do
  today. The live cursor keeps viewport priority: which trailing blank rows a
  resize trims or keeps is decided by the live cursor alone, never by the
  saved one.
- I8. A saved position on a never-written blank row below the content has no
  text to follow; across a width change it keeps its row offset below the
  reflowed content (then the usual clamp), and across a height shrink it
  clamps into the new rectangle.

## 4. Proof obligations

Behavioral, content-relative tests in `lib/TerminalCore/Tests/TerminalCoreTests`
(assert the cell under the restored cursor, not a coordinate, wherever the
coordinate is incidental):

- PO1 (I1): print a marker, DECSC on it, move below, shrink rows so top rows
  enter history, DECRC -> the cursor's cell is the marker. Includes the audit
  BUG-17 probe (4x6, save at row 4, shrink to 3 rows -> row 1, not the
  clamped row 2).
- PO2 (I1): shrink, then grow back so history is pulled back in -> DECRC is
  on the marker again.
- PO3 (I3): shrink so the saved row falls into history -> DECRC at row 0 with
  its column kept (clamped to the width).
- PO4 (I2): the audit BUG-16 probe -- `abcdefgh` at 4 columns, save on `f`,
  widen to 8 -> DECRC on `f` (row 0, column 5); and the inverse narrowing
  where the saved cell wraps to the next row.
- PO5 (I2, I4): save with pending wrap armed at the old right edge, widen ->
  DECRC sits one past the old content with pending wrap off; narrow back so
  the position is at the new edge -> pending wrap re-armed.
- PO6 (I2): save on a blank cell past the end of a line's content, change
  width -> the restored cursor keeps its distance from the content end.
- PO7 (I5): shell-style story -- prompt marker, `CSI ?1049h`, full-screen
  drawing, shrink rows and narrow columns while alternate is active,
  `CSI ?1049l` -> cursor on the prompt marker; the alternate's own saved slot
  is not shifted.
- PO8 (I6): existing alternate-screen resize tests keep passing unchanged.
- PO9 (I7, I8): the existing resize, reflow, prompt-anchor sweep, scrollback
  budget, state-synchronization, selection, and search suites and the
  `TerminalTests` fuzz pass unchanged; only the expectations that pinned the
  clamp-only behavior change (`TerminalSavedCursorTests.swift`
  `restoreClampAndPendingTripleGate` resize steps, and
  `TerminalAlternateScreenTests.swift` `inactiveScreenResizeClampsSavedCursors`
  for the primary's slot). Each rewritten expectation asserts the cell under
  the restored cursor; the "re-arm pending wrap only at an active edge" gate
  that the old resize steps exercised gets its own non-resize assertion.
- PO10 (I8): save on a blank row two rows below the last content row, change
  width -> DECRC is two rows below the reflowed content end.
- PO11 (RI1): the screen-relative premise, pinned without a resize -- print a
  marker, DECSC on it, scroll the marker up by several lines (no resize),
  DECRC -> the cursor is back at the saved *screen* coordinate, on whatever
  text now occupies it, not on the marker. This fails if the saved slot is
  ever turned into a durable content anchor, which the resize tests alone
  would not catch.

## 5. Non-goals / Accepted risks / Rejected ideas

- NG1. No change to what DECSC saves or DECRC restores apart from position
  tracking (BUG-12, BUG-13, BUG-32 are separate).
- NG2. No tracking of the alternate screen's saved slot through reflow:
  alternate content does not reflow (D10).
- RI1. Store the saved slot as a stream-absolute `TextAnchor` and restate it
  with the selection/search anchors. Rejected: DECSC is screen-relative under
  scrolling; an absolute anchor would drift after every scrolled line. PO11
  pins this against a later implementation quietly making the slot durable.
- RI2. Patch only the height shrink (the finding's literal fix). Rejected as
  the recommendation: leaves the grow branch and the width reflow (BUG-16)
  wrong in the same functions; the ideal is one tracking for both cursors.
- AR1. ghostty homes an off-screen saved cursor to (0,0); kitty clamps.
  DanTerm follows its own live-cursor policy (I3). Unspecified by any
  standard; consistency with the live cursor is the rationale.
- AR2. Once a shrink has pushed the saved row into history (I3), a later
  grow that pulls rows back shifts the saved row down with them, so it
  points at pulled text rather than the original cell. The link was already
  severed; kitty behaves the same way.
- AR3. A saved cursor with pending wrap at the old right edge reflows as a
  line boundary (one past the last cell, pending off when that fits),
  which is DanTerm's live-cursor spelling; ghostty pins the cell instead.
  One rule for both cursors is the rationale.

## 6. Implementation discretion

- How `reconstructLogicalLines`/`pack` generalize from one cursor to a list
  (a list of tracked positions, or a second call) -- provided both cursors go
  through the same attachment code path.

## Verification

- `swift test --package-path lib/TerminalCore --filter TerminalSavedCursorTests`
  and `--filter TerminalAlternateScreenTests`, `TerminalResizeTests`,
  `TerminalPromptAnchorResizeSweepTests`.
- `just test` for the full gate.
- Live: `just launch-slot`, run `vim` in a pane, drag the window shorter and
  narrower, `:q` -> the shell prompt's cursor is where the prompt is; then
  `just stop-slot <n>`.

## Implementation notes

- Section 6's discretion: `reconstructLogicalLines` now takes a list of tracked
  cursors and returns one attachment each, and the per-line resolution moved out
  of `resizeWidth`'s loop into `reflowDestination`. Both cursors go through that
  one function, so the cell, boundary, and trailing-padding rules cannot drift
  apart.
- I8 needed an attachment case of its own (`belowContent`) rather than a reuse of
  the trailing-padding rule: the refold reconstructs rows only down to the last
  content row, so a saved row under that has no line to attach to and is placed
  by its offset below the reflowed content end.
- PO9's replacement gate assertion is a non-resize step at the end of
  `restoreClampAndPendingTripleGate`: a save taken at the right edge with no wrap
  pending restores without one, which is the case the old resize step happened to
  cover.

## Follow Up

- `docs/scratch/2026-08-18-construction-audit.md` still lists BUG-16 and BUG-17
  as open, and its "Existing test" notes still describe the two expectations this
  change rewrote. Both rows need a status pass.
