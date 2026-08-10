# Per-screen saved cursor

## Context

Running `claude` in a pane, pressing ctrl-g to edit the prompt in nvim, and
quitting nvim leaves the pane's screen scrambled: Claude's whole UI is repainted
several rows too high, overlapping text that was already on screen (`▐▛███▜▌`**`ant`**`Claude`,
` `**`6`**`▘▘`**`9`**`▝▝`). Ghostty replays the same byte stream correctly.

Root cause: `Terminal` keeps one `savedCursor` slot (`Terminal.swift:658`) shared
by the primary and alternate screens. xterm and Ghostty scope the saved cursor to
the screen buffer -- Ghostty says so outright at
`references/ghostty/src/terminal/Terminal.zig#restoreCursor` ("The primary and
alternate screen have distinct save state") and at `#switchScreenMode` ("1049
unconditionally saves the cursor on enabling, even if we're already on the
alternate screen"), saving into the *active* screen's slot.

Claude's ctrl-g flow produces **nested** `1049h`, captured from a real PTY:

```
\e[?1049h \e[2J \e[H       <- claude enters alt, clears, homes
  \e[?1049h ...            <- nvim enters alt again (nested)
  \e[?1049l                <- nvim leaves
\e[?1049l                  <- claude leaves
```

DanTerm's nested `1049h` calls `saveCursor()` unconditionally and overwrites the
one slot with the alt-screen home position `(0,0)`. Both `1049l`s then restore
`(0,0)`. Claude's renderer is a relative-diff painter (`\e[nA`/`\e[nG`/`\e[nB`,
no absolute CUP, no full erase), so the frame anchors at row 0 and skipped
columns leak the old text.

Proven by ablation: replaying the captured stream into `Terminal(89x40)` ends
with the cursor at row 6 and the UI collapsed to the top; deleting only the
nested `\e[?1049h` (and its matching `\e[?1049l`) ends at row 13 and reproduces
Ghostty's output exactly.

The same shared slot has a second live symptom: any full-screen app that uses
`ESC 7` / `CSI s` destroys the shell's DECSC slot underneath it.

## Outcome

DanTerm replays the nested-1049 stream to the same screen and cursor as Ghostty,
and a save taken on one screen is invisible from the other.

## Direction

Both screens become retained values that own their screen-scoped state, so no
per-screen field can be swapped in one direction and forgotten in the other, and
neither screen's state is destroyed by a switch.

Today's stash, `InactivePrimaryScreen` (`Terminal.swift:569`), already holds a
partial bundle: `rows`, a resize-only cursor copy, and the semantic-content pair.
Widen it into the whole per-screen value -- grid rows, cursor, pending wrap, saved
cursor, semantic content, and the screen's Kitty keyboard stack (today the
separate `primaryKittyKeyboardStack` / `alternateKittyKeyboardStack` pair at
`Terminal.swift:665`) -- and give `Terminal` a private computed property that
extracts and installs the live fields as that value. The resize-only
`resizeCursor` / `isResizePendingWrap` fields disappear into the value's ordinary
`cursor` / `isPendingWrap`, and `activeKittyKeyboardStack`'s screen test
disappears into the live field.

`Terminal` then holds the live fields plus one inactive value and a stored
active-screen discriminator. The inactive slot is empty only until the alternate
screen is first entered; after that it always holds whichever screen is not live,
so the alternate's state survives an exit. Switching is one symmetric swap of the
property plus a flip of the discriminator.

This is a load-bearing rename, not a cosmetic one. Today `inactivePrimaryScreen?.rows ?? rows`
resolves to the primary grid only because the slot is empty whenever the primary
is live; once the slot can hold the alternate screen, the idiom silently returns
the wrong grid. The readers that spell it split two ways, and the split has to be
made explicit rather than inherited:

- `primaryHistoryText` and `primaryHistoryTailText` (`Terminal.swift:2541`, `:2559`)
  always mean the primary grid, and must go through one accessor keyed off the
  discriminator. They feed recovery and export, so returning a retained alternate
  grid here would capture a dead TUI frame as shell history.
- `rowStructure` (`Terminal.swift:2507`) means the *active* grid -- its ternary is
  a tautology today -- and reads plain `rows`.

On top of the raw swap, one function encodes the xterm mode rules (modelled on
`references/ghostty/src/terminal/Terminal.zig#switchScreenMode`, whose comments
cite the xterm source it was read from):

- `1049` on entry saves the cursor **before** switching, so the save always lands
  in the outgoing screen's slot -- including the nested case, where no switch
  happens and the save lands on the alternate screen.
- `1049` on exit switches, then restores from the primary's slot. A redundant
  exit restores the same slot again and is idempotent.
- Cursor carry happens only when the active screen actually changes: `1047` and
  `1049`-entry copy the live cursor onto the screen being switched to, which is
  what the current global live cursor already achieves. Making it explicit is what
  lets the swap be symmetric. Mode `47` stays unimplemented and inert.
- Entering the alternate screen when it is already active must not disturb the
  stashed primary. Today a `if isAlternateScreenActive == false` guard does this;
  after the change it falls out of "no switch happened".
- Both `1047` and `1049` clear the grid on entry, as they do today. Nothing clears
  it on exit, so a retained alternate grid is only ever observed after it has been
  cleared by the next entry.

Resets are the one place that must reach past the discriminator: DECSTR and RIS
clear *both* screens' Kitty keyboard stacks today (`TerminalKittyKeyboardTests.resets`),
and that stays true.

Resize keeps its existing shape (`Terminal.swift:1986-2047`), generalized to run
from either side of the switch: the primary is reflowed, the alternate is
rectangle-clipped, and each is handled whether it is the live screen or the
inactive one -- a retained alternate must not survive a resize at the old
geometry. Each screen's saved cursor is clamped against the grid it was saved from
rather than against whichever grid happens to be active.

Nothing outside `Terminal.swift` reads either type, and no persistence format
encodes them, so the change is contained.

## Non-goals

- Making the scroll region, origin mode, tab stops, or the mouse and input modes
  per-screen. Ghostty keeps these on the terminal, not the screen; they are not
  implicated. (The Kitty keyboard stacks are already per-screen and move into the
  screen value, which changes no behavior.)
- Implementing mode `47`. It is unhandled and inert today, and
  `TerminalAlternateScreenTests.switchSideStateAndUnsupportedMode` pins that.
- Changing whether RIS clears the saved cursor. DanTerm currently preserves it
  across RIS and DECSTR (pinned by `TerminalResetTests`); that deviation from
  xterm is real but separate from this bug.
- Adding the captured `claude` + `nvim` byte stream as a recorded fixture. The
  nesting pattern is three sequences long and reads better as a written test; a
  10 KB capture would pin Claude's current renderer, not the terminal contract.

## Accepted risks

- Once a pane has entered the alternate screen, the process holds two screen-sized
  grids for the rest of the pane's life instead of releasing the alternate one at
  exit, and `memoryCensus` reports both as resident. Bounded by one screen, matches
  Ghostty, and is what the census comment at `Terminal.swift:2334` already
  describes; blanking the retained grid at exit is a one-line follow-up if it ever
  shows up in a measurement.

## Existing tests that assert the bug

These pin the shared-slot behavior and must be corrected, not preserved:

- `TerminalAlternateScreenTests.mode1049OrderingAndRedundantOperations`
  (`lib/TerminalCore/Tests/TerminalCoreTests/TerminalAlternateScreenTests.swift:38`)
  -- feeds the nested `1049h` case and expects the alt-screen save to win. It must
  expect the primary's own save.
- `TerminalPresentationModeTests.savedAppearanceCrossesScreens`
  (`lib/TerminalCore/Tests/TerminalCoreTests/TerminalPresentationModeTests.swift:102`)
  -- asserts that cursor appearance saved on the alternate screen restores on the
  primary. Invert it: the two slots are independent.
- `TerminalAlternateScreenTests.switchesPreserveSharedState:105` -- its DECSC case
  saves and restores on the primary either way, so its expectation survives, but
  it no longer belongs under "shared state".
- `TerminalAlternateScreenTests.alternateResizeClampsCursorsAndMargins:183` --
  saves on the alternate screen and restores after returning to the primary.
  Restore while still on the alternate screen to keep testing the clamp it is
  named for.

The `libvterm` and `danterm` JSON fixtures do not cross screens with a save and
are unaffected.

The adapted Alacritty `saved_cursor_alt` fixture does cross screens. Its manifest
already classifies it as an independent-screen proof, but its viewport expectation
pins the shared-slot corruption and must be corrected to the independent-slot output.

## Verification

Behavioral proofs, at the level of one entry per claim:

1. **The incident.** Feeding the nested-`1049` pattern (`1049h`, clear, home,
   `1049h`, `1049l`, `1049l`) around printed content returns the cursor to the row
   it occupied before the first `1049h`, and leaves the primary grid intact.
2. **Slot isolation.** A save taken on the primary is not readable from the
   alternate screen and is not disturbed by a save taken there; and the reverse.
   Covers `ESC 7`/`ESC 8`, `CSI s`/`CSI u`, and `1048`, which share one slot per
   screen.
3. **Cursor appearance follows the slot.** The visibility/shape/blink half of the
   saved state is per-screen too (replaces `savedAppearanceCrossesScreens`).
4. **The alternate screen's state survives an exit.** A save taken on the
   alternate screen is still restorable after leaving and re-entering it; the same
   holds for that screen's Kitty keyboard stack.
5. **Resize reaches the inactive screen from either side, grid and saved cursor.**
   Resizing while the alternate screen is active leaves the inactive primary's
   saved cursor restorable and inside the resized primary grid, including off a
   wide-cell tail. Resizing while the primary is live leaves the retained alternate
   at the new geometry with its saved cursor clamped against its own grid, so a
   save taken on the alternate screen restores to a valid position after exit,
   resize, and re-entry -- including a save whose column the resize turns into a
   wide-cell tail, which nothing after the resize can recognize.
6. **`1047` still carries the live cursor** across entry and exit, mode `47`
   remains fully inert, and a redundant `1049l` on the primary is idempotent.
7. **The two projection routes stay distinct.** `primaryHistoryText` and
   `primaryHistoryTailText` report the primary screen from either side of the
   switch, including after an alternate exit; `rowStructure` reports the live grid,
   which is the alternate one while a full-screen app is running.
8. Existing chunk-invariance, equality, and `expectValidGrid` coverage in
   `TerminalAlternateScreenTests`, `TerminalSavedCursorTests`, and the fuzz
   fragments in `TerminalTests` continues to pass unchanged.

End-to-end, outside the unit tests:

- Replay the captured stream headlessly and confirm the screen now matches the
  Ghostty output. Re-capture with a PTY harness that spawns `claude` with
  `EDITOR=nvim`, writes `\x07` (ctrl-g), then `:q\r`, and records the raw fd --
  the byte stream, not the GUI, is the reproduction.
- Then `just launch-slot`, run `claude` in a pane, ctrl-g, `:q`, and confirm the
  UI repaints below the prior frame instead of over the top of the screen.
- `just test`.

## Implementation notes

- The plan's fixture inventory omitted the adapted Alacritty `saved_cursor_alt`
  expectation. The full TerminalCore run identified it as another assertion of the
  shared-slot bug, so the implementation corrects it with the unit tests above.
