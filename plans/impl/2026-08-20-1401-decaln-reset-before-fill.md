# DECALN resets position and rendition before it fills (BUG-08 + BUG-14)

## Problem

`ESC # 8` (DECALN) in `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`
(`dispatchEscape(_ sequence:)`) fills the screen with 'E' in the *full*
current SGR pen and leaves the cursor, the scroll margins, origin mode, and
the pen exactly as it found them. DanTerm's contract is that DECALN is a
known-state reset plus fill. Two audit findings
(`docs/scratch/2026-08-18-construction-audit.md`, BUG-08 and BUG-14) describe
the two halves of this one defect; both reproduce on the current tree.

Supporting evidence (evidence, not authority -- see
[docs/design/2026-08-06-swift-terminal-engine.md](../../docs/design/2026-08-06-swift-terminal-engine.md)
A4):

- `references/xterm/charproc.c#CASE_DECALN`: clear ORIGIN, clear pending
  wrap, `resetRendition` (attributes off, colours kept), `resetMargins`, home
  the cursor, then fill. xterm cites DEC STD 070.
- `references/ghostty/src/terminal/Terminal.zig#decaln`: pen reduced to
  fg/bg, scrolling region reset to the whole grid, origin off,
  `setCursorPos(1, 1)`, then fill; test "decaln preserves color" pins the
  colour half and shows a following scroll moving the whole screen.
- kitty and foot reset margins and home the cursor only; alacritty and
  wezterm fill with default cells and move nothing; libvterm fills with the
  current pen and moves nothing. DanTerm today matches libvterm. DanTerm's
  contract follows DEC STD 070's known-state reset, which xterm and ghostty
  implement in full.

Who notices: vttest's alignment and margin pages, and any program that uses
DECALN as a known-state fill before positioning absolutely.

## Decision

DECALN becomes: sever history's wrap claim on row 0 (already done), turn
origin mode off, drop the scroll region, reduce the pen to its foreground and
background colours, fill every cell of the active screen with 'E' in that
colour-only pen, and home the cursor with pending wrap cleared. Nothing else
changes: the saved cursor (DECSC slot), tab stops, charsets, hyperlink pen,
modes other than DECOM, and the inactive screen are untouched.

The "colours only" pen already exists as the erase pen
(`Terminal.swift#backgroundEraseStyle`, the pen every blanking path uses), and
cursor homing as `moveCursor(row:column:)`; the fix is reuse, not a new
helper. `resetControlState()` is too wide (modes, charsets, tab stops, whole
pen) and is not the tool here.

## Invariants

- I1. After DECALN the cursor is at row 0, column 0, with no pending wrap,
  regardless of origin mode or margins beforehand.
- I2. After DECALN, origin mode is off and the scroll margins are the full
  screen: the next absolute CUP lands on its literal row, and a scroll of one
  row moves every row of the screen.
- I3. Every cell DECALN writes holds 'E' styled with the pen's foreground and
  background colours and no other attribute, and the live pen afterwards is
  that same colour-only style, so output printed after DECALN is not bold,
  underlined, reversed, etc. unless the program asks again.
- I4. DECALN does not touch the saved cursor or the tab stops.
- I5. Cells DECALN writes carry no hyperlink, and DECALN does not end an
  active hyperlink: a character printed after DECALN still carries the
  hyperlink that was open before it.

## Proof obligations

Behavioral tests in `lib/TerminalCore/Tests/TerminalCoreTests/` that feed
bytes and observe the public surface (`geometry.cursor`,
`cell(row:column:)?.style`, `currentStyle`). `CSIEraseTests.swift` already
names DECALN in its header and is the natural home.

- PO1 (I1, I2): set a region and origin mode, DECALN, assert the cursor is
  home; a following absolute CUP reaches a row outside the old region; a
  following one-row scroll blanks row 0 and leaves the last row 'E'.
- PO2 (I3): set bold/underline/reverse plus indexed fg/bg, DECALN, assert a
  corner cell and the live pen both equal the colour-only style; print one
  character and assert it carries that same style.
- PO3 (I4): DECSC before DECALN, DECRC after -> original position; a custom
  tab stop set before DECALN still stops a following HT.
- PO4 (I5): open an OSC 8 hyperlink, DECALN while it is still open, assert
  the filled cells carry no hyperlink; then print a character and assert it
  still carries that hyperlink. `TerminalHyperlinkTests.penSemantics` closes
  the link before DECALN, so it cannot see either half.

Write each test first and watch it fail for the reason the invariant names,
then change the code.

## Non-goals / Accepted risks

- Non-goal: DECSLRM left/right margins and DECDWL/DECDHL line attributes
  (xterm's `xterm_ResetDouble`) -- DanTerm does not implement them, so there
  is nothing to reset.
- Non-goal: any change to how DECALN records damage or invalidates
  inspection; `invalidateInspection(inViewportRows:)` already covers it.
- Accepted risk: alacritty and wezterm drop colours on DECALN; DanTerm's
  contract keeps them. The test preamble states the DanTerm contract -- fill
  in the colour-only pen -- so the choice is visible.

## Follow-through

- Mark BUG-08 and BUG-14 done in
  `docs/scratch/2026-08-18-construction-audit.md` with the commit hash.
- Gate: `swift test --package-path lib/TerminalCore --filter CSIEraseTests`
  and `--filter TerminalHyperlinkTests` during work; `just test` before
  commit.

## Implementation discretion

- Whether the reset steps run before or after the row fill, and whether the
  filled-cell style is taken from the erase-pen id or the (now equal) current
  pen id.

## Implementation notes

- The reset runs before the fill and takes the filled style from the current
  pen id after reducing that pen to `backgroundEraseStyle`, so cell style and
  live pen come from one value and cannot drift. The plan left this order to
  discretion.
- `moveCursor(row: 0, column: 0)` replaces the old trailing
  `clearPendingMotionState()`; it already clears pending wrap and the open
  cluster, so nothing else is needed to home the cursor.
- `TerminalHyperlinkTests.penSemantics` printed its last two characters at
  columns 5 and 6 because DECALN used to leave the cursor alone. With the
  cursor now homed they land on columns 0 and 1, so the two expectations move.
  The test still checks exactly what its title claims about the link pen.
- PO3 (saved cursor, tab stops) and PO4 (hyperlinks) passed before the code
  change: both invariants already held by construction. They stay as guards
  against a later, wider reset.

## Follow Up

- Mark BUG-08 and BUG-14 done in
  `docs/scratch/2026-08-18-construction-audit.md` with this commit's hash. The
  hash does not exist until the commit lands, so it needs its own
  `docs(audit): ...` commit, which is how BUG-35 was recorded.
