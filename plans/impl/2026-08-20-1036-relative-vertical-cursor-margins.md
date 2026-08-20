# Clamp relative vertical cursor motion to the scroll margins

Source: BUG-03 / PARSE-1 in `docs/scratch/2026-08-18-construction-audit.md`,
verified against the current tree on 2026-08-20 (pivot: same bug, different
clamp rule than the audit proposed).

## 1. Problem and evidence

CUU/VPB, CUD/VPR, CNL, and CPL (`CSI A k B e E F`) are relative vertical
motions. DanTerm routes them through the same clamp as absolute positioning
(CUP/HVP/VPA), whose row bound is the scroll region only when DECOM is on and
the full screen otherwise (`lib/TerminalCore/Sources/TerminalCore/Terminal.swift`,
`dispatchCSI` arms and `movePositionedCursor` / `positioningRowRange`). With
DECSTBM set and DECOM off -- the common configuration -- a relative move walks
the cursor out of the region.

Reproduced: `Terminal(columns: 80, rows: 24)`, feed `CSI 1;10r CSI 3;1H CSI 20B`,
cursor row is 22; the references give 9.

Load-bearing premises:

- P1. DEC VT510 (CUU/CUD) and the majority of references clamp relative
  vertical motion to the margins independently of DECOM, *per direction*:
  moving up stops at the top margin unless the cursor starts above it (then
  the top line); moving down stops at the bottom margin unless the cursor
  starts below it (then the bottom line). `references/xterm/cursor.c#CursorUp`
  / `#CursorDown`, `references/ghostty/src/terminal/Terminal.zig#cursorUp` /
  `#cursorDown`, `references/wezterm/term/src/terminalstate/mod.rs` (`Cursor::Up`),
  `references/windows-terminal/src/terminal/adapter/adaptDispatch.cpp#_CursorMovePosition`,
  `references/iterm2/sources/VT100Grid.m#moveCursorUp` / `#moveCursorDown`.
  kitty (`references/kitty/kitty/screen.c#screen_cursor_up`) clamps to the
  margins only when the cursor starts inside them; alacritty, libvterm, and
  foot gate on DECOM like DanTerm today. The spec plus five-of-nine decides it.
- P2. No existing test or fixture pins the current behavior. The only fixture
  that combines DECSTBM with a relative vertical move
  (`Tests/TerminalCoreTests/Fixtures/libvterm/state-mode.json`) runs it under
  DECOM, where old and new bounds agree.
- P3. The workload is already named in `Terminal.swift` (comments near
  `retainsRowsScrolledOffTop`): inline-viewport TUIs that pin a footer with
  `CSI 1;N r`; today a large CUD lands on the footer row and the next print
  overwrites it.

## 2. Decision

Give the terminal two cursor-motion entry points chosen by motion kind:
absolute positioning (CUP/HVP/CHA/VPA, CUF/CUB, CHT/CBT, DECRC) keeps the
DECOM-dependent bound it has today; relative vertical motion (the six finals
A/k, B/e, E, F) gets its own bound computed per P1 from the active scroll
region, with no DECOM test. A relative move can then no longer inherit the
absolute clamp by construction: the bound follows from which entry point the
dispatch arm calls.

Scope: `lib/TerminalCore` only. No CLI, protocol, or renderer change.

## 3. Invariants

- I1. With a scroll region set and regardless of DECOM, a relative upward
  move (CUU/VPB/CPL) from a row at or below the top margin stops at the top
  margin; from a row above the top margin it stops at row 0.
- I2. Symmetrically, a relative downward move (CUD/VPR/CNL) from a row at or
  above the bottom margin stops at the bottom margin; from a row below it, at
  the last screen row.
- I3. With no scroll region set, all six relative finals behave exactly as
  today (the bound is the whole screen).
- I4. Absolute and horizontal motion (CUP/HVP/CHA/VPA/CUF/CUB/CHT/CBT) and
  DECRC keep their current DECOM-dependent row bound.
- I5. Every relative vertical motion still clears pending-wrap and cluster
  state and never scrolls; CNL/CPL still reset the column to 0.

## 4. Proof obligations

Behavioral tests in `lib/TerminalCore/Tests/TerminalCoreTests/` (the
scroll-region suite is the natural home), written first and failing for the
stated reason before the code change:

- PO1 (I1, I2): region set, DECOM off, cursor inside the region; large CUU,
  CPL, VPB stop at the top margin and CUD, CNL, VPR at the bottom margin.
  Fails today (cursor reaches row 0 / last row).
- PO2 (I1, I2, the per-direction half): cursor above the region moving down a
  large count stops at the bottom margin; cursor below the region moving up
  stops at the top margin. Fails today, and distinguishes the chosen rule
  from the inside-only one (RI1).
- PO3 (I1, I2): cursor above the region moving up reaches row 0; cursor below
  the region moving down reaches the last row. Passes today and must keep
  passing.
- PO4 (I3, I4): the existing `CSICursorMovementTests`,
  `TerminalModeTests` (DECOM-on relative moves), `TerminalSavedCursorTests`,
  `TerminalScrollRegionTests`, and `TerminalFixtureTests` (including
  `libvterm/state-mode.json` with its unchanged deviation manifest) stay
  green.
- PO5 (I5): one table-driven test over all six relative finals (`A k B e E F`)
  with a scroll region active and DECOM off, cursor inside the region. Each
  final clears pending wrap and the combining-attachment target, leaves grid
  and scrollback content unchanged, and `E`/`F` land on column 0. Existing
  side-state coverage reaches only `B`/`e` and only without a region
  (`CSICursorMovementTests.movementClearsPendingState` /
  `movementDoesNotScroll`), so the four finals this plan reroutes to the new
  entry point are otherwise unproven for I5.

## 5. Non-goals / Accepted risks / Rejected ideas

- Non-goal: horizontal margins (DECSLRM) and any horizontal analogue of this
  clamp. DanTerm does not implement left/right margins.
- Non-goal: IND/NEL/RI. They scroll at the margins already through
  `lineFeed` / `reverseIndex` and are not part of this change.
- RI1. The audit's proposed rule "clamp to the region when the cursor starts
  inside it, else to the screen" (kitty's). Rejected: it diverges from the DEC
  text and the majority of references when the cursor starts outside the
  region and moves across it (P1).
- RI2. Keeping the DECOM-gated clamp because alacritty/libvterm/foot do.
  Rejected: it breaks the footer-pinning workload (P3), and the spec is
  explicit.

## 6. Implementation discretion

- Shape of the relative entry point (signed delta vs. target row, name,
  whether it shares the column clamp and the pending-state reset with the
  absolute helper) -- constrained only by I1-I5.

## Verification

1. `swift test --package-path lib/TerminalCore --filter TerminalScrollRegionTests`
   -- new tests fail before the change, pass after.
2. `swift test --package-path lib/TerminalCore` -- whole package green (PO4).
3. `just test` -- the local gate.
