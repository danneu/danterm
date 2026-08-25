# Give the terminal selection an anchor

## Problem

In every macOS text surface, a plain click leaves a position behind even though
nothing is highlighted, and a following Shift-click selects between the two
points. DanTerm cannot do this: a Shift-left press extends only when
`terminal.selectionRange` is already non-nil, and a plain click clears the
selection outright, so the press has nothing to extend from and starts a fresh
gesture instead.

Repro: click between `D` and `E` on a line of text, then Shift-click between `O`
and `P`. macOS and Chrome select `EFGHIJKLMNO`; DanTerm selects nothing.

The pointer policy does hold an anchor for the press -- but only inside
`TerminalInteractionState.selectionDrag`, which is dropped on release. The
terminal, which owns every fact that must outlive a gesture, is told only
"clear". Because no anchor survives, extension has to re-derive one from the
settled range on every press, which is also why a Shift-click inside the
selection has nothing to do and is specified as a no-op.

### Load-bearing premises

**P1 -- macOS selection pivots on an anchor, and the anchor is where the
gesture that made the selection started.** NSTextView probe, 2026-08-24, on
`ABCDEFGHIJKLMNOPQRSTUVWXYZ` dragged left-to-right from before `E` to after `O`:

| gesture | result |
|---|---|
| Shift-click between `F` and `G` (inside, near the start) | `EF` |
| Shift-click before `A` (outside, far side from the anchor) | `ABCD` |

Both results are `anchor..click`. The anchor stays at the drag's origin; the
Shift-click moves only the other end. Neither result is explicable by pinning
the endpoint farther from the click.

**P2 -- A click leaves a caret behind in non-editable text too.** Chrome probe,
2026-08-24, on a static page: a single click at offset 4 leaves
`rangeCount: 1`, `anchorOffset == focusOffset == 4`, and no highlight; a
following Shift-click at offset 15 selects `EFGHIJKLMNO`.

**P3 -- Blink is not the model to copy.** The same Chrome probe shows Blink
re-basing the anchor to the farther endpoint after each Shift-click (`4..15`
Shift-clicked at 6 gives `6..15`, not `4..6`), as does
`references/iterm2/sources/iTermSelection.m:243-263`. AppKit is the product
requirement, as it was for the 2026-08-10 extension work; P3 is recorded so the
divergence is not re-raised as a bug.

**P4 -- The current rule pins the endpoint farther from the click**
(`TerminalInteractionPolicy.swift:476-500`), and treats a click inside the
selection as a no-op for the whole gesture (`:501-504`). P1 contradicts both.

## Decision

The terminal's settled selection becomes an *anchored* selection: an anchor
boundary, a focus boundary, and the granularity, all with one lifetime. The
highlighted range is the ordered pair; no selection is still nil.

A plain character-granularity press settles an empty pair -- the caret. Other
empty selections stay what they are today: a multi-click press over blank cells
settles a present empty token or trimmed-line selection, and so does
`selectAll()` on a blank pane, both keeping Copy enabled. Only the caret is
absent from the public projections, so the settled selection carries which kind
of empty it is.

Every gesture then reduces to one rule -- **a press sets the anchor, a Shift
press keeps it, and everything moves the focus**:

- A plain left press sets anchor and focus to the pressed unit. At character
  granularity that unit is a single boundary, so the press settles a caret.
- A drag moves the focus; the anchor does not move.
- A Shift-left press, and the drag it starts, moves the focus to the pointer at
  the settled granularity and leaves the anchor where the earlier gesture put
  it. From a caret this is exactly the missing click-then-Shift-click behavior;
  inside the old range it shrinks; on the far side of the anchor it flips.
- A programmatic selection (`setSelection`, Select All) anchors at its start, so
  a following Shift-click moves its end.

This deletes machinery rather than adding it: the pointer policy no longer
derives a fixed endpoint per press, no longer records which end a drag froze,
and no longer clears -- the selection arm always settles an anchored pair, empty
for a caret.

The anchor is engine state, not view state, for the reason the 2026-08-10 plan
gave for granularity: it must survive the same output, scrolls, evictions, and
width reflows the selection survives, and it must replay identically from a
recorded pointer stream.

Public selection projections keep their present meaning: highlighting,
`selectedText`, the selection range, copy-on-select, Copy menu enablement, and
repaint damage are unchanged by the caret's existence.

`docs/design/2026-08-06-swift-terminal-engine.md` G6 states the superseded
three-arm behavior and is amended by this change.

## Invariants

- **I1 -- The click leaves a caret.** A left press with no Shift settles an
  empty selection at the pressed boundary at character granularity, and a
  following Shift-left press selects from there to its own boundary.
- **I2 -- One anchor rule.** A Shift-left press, and every drag sample of the
  gesture it starts, moves the focus to the pointer at the settled granularity
  and leaves the anchor unmoved -- inside the old range, outside it, or across
  the anchor. The selection is the ordered anchor-focus pair.
- **I3 -- Anchor provenance.** While its boundary is still retained, the anchor
  is the boundary or unit the selection-making gesture began at; a programmatic
  selection anchors at its start. Eviction is the one thing that moves it, under
  I5.
- **I4 -- The caret is invisible.** A caret produces no highlight, no selected
  text, no selection range, no copy, no Copy-menu enablement, and no repaint
  damage. Empty selections that are not carets -- a multi-click press over blank
  cells, `selectAll()` on a blank pane -- keep their present behavior.
- **I5 -- One lifetime.** Anchor, focus, and granularity are stored, pinned,
  restated, clamped, and dropped together, exactly as the selection range is
  today: they survive output, local scrolling, and height resize; a width reflow
  keeps them attached to the same logical content; an alternate-screen switch
  and a hard reset drop them. Eviction clamps an evicted boundary -- anchor or
  focus -- forward to the first retained boundary and keeps its role, and drops
  the selection only when the whole of it is evicted.
- **I6 -- Preserved behavior.** Shift selection stays local under mouse capture
  and sends no bytes to the child; extension still inherits the settled
  granularity and ignores the extending press's click count; token,
  trimmed-line, Cmd-click link, and Select All unit behavior are unchanged.
- **I7 -- Completion.** Every Shift-left gesture completes once on release,
  firing copy-on-select when the resulting text is non-empty.

## Proof obligations

- **PO1 -- I1:** the click-then-Shift-click repro selects the text between the
  two points, including when the plain click first replaced an existing
  selection.
- **PO2 -- I2, I3:** both probe cases in P1 reproduce, plus extension from a
  caret, extension away from the anchor, and a Shift drag that crosses the
  anchor and comes back; a programmatic selection extends from its start. A
  gesture whose origin is its *newer* end keeps that origin as the anchor
  through a width reflow, which orders its endpoints.
- **PO3 -- I4:** a caret is absent from every public selection projection --
  range, text, highlight, Copy enablement, and repaint damage -- while a
  multi-click press over blank cells and `selectAll()` on a blank pane each
  still report a present, copyable, empty selection.
- **PO4 -- I5:** an anchor set before appended output, scroll migration, height
  resize, and width reflow still addresses the same logical position
  afterwards, and keeps its geometric position when output overwrites the cells
  under it; eviction of the older boundary clamps it and keeps its role, whether
  that boundary is the anchor or the focus, while an alternate-screen switch and
  a hard reset drop the selection.
- **PO5 -- I6, I7:** captured-mouse Shift gestures emit no child bytes,
  granularity inheritance survives every extending click count, and gesture
  completion fires once per gesture.
- **PO6 -- Replay parity:** the same pointer stream produces the same terminal
  state through the live host and through neutral replay, with no
  recording-format change.

## Accepted risks

- **AR1 -- Shift-click can now discard selected text.** On the far side of the
  anchor it selects `anchor..click` rather than growing the range, and inside
  the range it shrinks. This is P1's measured AppKit behavior and the point of
  the change, but it is a visible break from what DanTerm does today.
- **AR2 -- The 2026-08-10 extension tests encode the superseded rule.** The
  before/after/inside cases in `TerminalInteractionPolicyTests.swift:1491` and
  the inside-selection copy suppression in
  `TerminalPaneSessionControllerTests.swift:590` assert P4 and must be restated
  against P1, not preserved.

## Non-goals

- No visible caret or second cursor: the click point is remembered, never drawn.
- No keyboard-driven selection (Shift-arrow), and no selection drag-and-drop.
- No persistence of selection or anchor through session recovery.

## Rejected ideas

- **Keep the anchor in `TerminalInteractionState`.** It would not survive
  release, which is the entire bug, and a persistent copy there cannot share the
  selection's replacement and drop lifetime -- the same reason the 2026-08-10
  plan rejected holding granularity in interaction state.
- **Add a separate caret field beside the range.** Two slots means two
  lifetimes, two invalidation paths, and a reachable state where both are set.
  The caret is the degenerate anchored selection.
- **Treat every empty selection alike.** Present-for-all would enable Copy on
  any click; absent-for-all would break blank-pane Select All and a multi-click
  press over blank cells. The settled selection distinguishes the caret from
  them instead.
- **Copy Blink's nearest-endpoint rule.** It matches neither P1 nor the
  product's AppKit requirement, and it needs no anchor only because it discards
  the user's pivot on every click.

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift` -- the
  `.selection` arm of `pointerDownDecision`, `extensionDecision`, and the drag
  samples in `decidePointerArm`.
- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` -- the settled-selection
  slot, its public projections, and the pin/restate/evict paths.
- `docs/design/2026-08-06-swift-terminal-engine.md` -- G6.
- Tests: `TerminalInteractionPolicyTests.swift`, `TerminalSelectionTests.swift`,
  `TerminalPTYHostTests.swift`, `TerminalPaneSessionControllerTests.swift`.

## Verification

Targeted suites during the loop (`swift test --package-path lib/TerminalCore`,
then `lib/TerminalPTY`) plus `just lint`; `just test` before the commit. Then
drive the real app -- `just launch-slot`, print a known line, and walk both
probe cases and the click-then-Shift-click repro by hand, since no pointer
gesture is reachable from the CLI.

## Implementation discretion

- The internal spelling of the anchored selection and of a collapsed one.
- Whether the pointer decision's clear mutation is deleted or left unused once
  the selection arm stops emitting it.

## Implementation notes

- **One rule at token and line granularity: the pointer's whole unit joins the
  selection as soon as the pointer is inside it.** The old code ran two rules --
  a plain union for a fresh drag, and, for an extension, "a pointer resting
  exactly on the next unit's start boundary leaves that unit out". The plan
  requires one rule and does not say which. I kept the plan's own wording ("moves
  the focus to the pointer at the settled granularity") and restated the two
  boundary legs of the granularity-inheritance tests, which is one step past what
  AR2 named.
- **The pin machinery is deleted.** `Terminal.PinnedTextRange`, `pinnedRange`,
  `resolvedRange`, and the row-numbering epoch existed only for the in-flight
  drag anchor, which now lives in the terminal. One behavior follows: a drag
  survives a width reflow instead of being retired by it, which is what I5 asks
  of every selection boundary.
- **`TerminalSelectionMutation` is a struct, not an enum.** With the caret
  settling an anchored pair, no arm emits `.clear` and the enum had one case
  left. `Terminal.clearSelection()` stays for Escape and the host.
- **Tests settle each press before the drag samples that follow it.** The anchor
  is terminal state, so a press that is never applied leaves nothing to pivot on.
  `decideAndApply` and the `settledSelection` projection both live in
  `TerminalSelectionDecisionAssertions.swift`.

## Follow Up

- The plan's manual leg is unrun: walk both P1 probe cases and the
  click-then-Shift-click repro in the real app (`just launch-slot`). No pointer
  gesture is reachable from the CLI, so it needs a person at the pane.
