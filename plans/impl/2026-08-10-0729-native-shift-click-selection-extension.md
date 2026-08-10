# Native Shift-Click Selection Extension

## Problem

DanTerm routes Shift-modified pointer input to local selection even when the
child has captured the mouse, but every Shift-left press starts a new gesture.
A character press therefore clears a settled selection instead of extending
it.

AppKit provides the target behavior. A real `NSTextView` probe on 2026-08-10
established these load-bearing premises:

- Shift-clicking outside a selection moves the endpoint on that side to the
  pointer.
- A Shift gesture that begins inside the selection leaves it unchanged, even
  if the pointer then drags outside.
- A gesture armed outside may drag back through the old selection, shrinking
  or reversing around its fixed opposite endpoint.
- Extension inherits the settled selection's character, word, or paragraph
  granularity. The extending click's click count does not replace it.
- At word granularity, merely reaching the next word's boundary excludes that
  word; entering it includes the word as a unit.
- The selection's canonical start boundary belongs to the before-selection
  extension arm, while its canonical end boundary belongs to the
  inside-selection no-op region. At paragraph granularity, the exact boundary
  before an adjacent paragraph excludes it; entering the paragraph includes it
  as a unit.

The same outside-extension direction appears in
`sources/iTermSelection.m#beginExtendingSelectionAt:` and
`kitty/screen.c#do_update_selection`. These references corroborate the probe;
AppKit behavior remains the product requirement.

## Decision

Selection range and extension granularity will be one settled terminal state.
The terminal remains the owner because both properties must survive the same
overwrites, scrolls, evictions, and width reflows. Pointer interaction policy
will remain pure and will derive both live behavior and neutral replay.

Shift-left press will have three outcomes:

- With no selection, it starts a fresh local selection as it does today.
- Outside a selection, it fixes the opposite endpoint and extends the endpoint
  on the pressed side using the settled granularity.
- Inside a selection, it is a local no-op for the whole press-drag-release
  gesture.
- A press at the selection's canonical start boundary uses the before-selection
  arm; a press at its canonical end boundary uses the inside-selection arm.

The initial outside press and subsequent drag samples will follow one extension
rule. Character extension resolves the existing sub-cell boundary. Token and
trimmed-line extension retain DanTerm's established selection units while
matching AppKit's adjacent-boundary behavior: the exact boundary before an
adjacent unit excludes it, while entering a token or logical line includes that
unit.

The binding interaction contract in
`docs/design/2026-08-06-swift-terminal-engine.md` G6 will be amended with this
behavior in the implementation change.

## Invariants

- **I1 -- Local ownership:** Shift selection never sends pointer bytes to the
  child, including fresh, extending, and inside-selection no-op gestures.
- **I2 -- Gesture continuity:** Once an outside Shift press chooses a side, the
  opposite endpoint stays attached to the same retained text and the settled
  granularity stays latched for that whole gesture, including if the moving
  endpoint crosses the fixed endpoint and temporarily clears the selection.
- **I3 -- Granularity continuity:** Extension uses the settled selection's
  granularity and ignores the extending click's click count.
- **I4 -- Selection lifetime:** Granularity survives every mutation that
  preserves the range and disappears whenever the selection is cleared or
  dropped.
- **I5 -- Replay parity:** A recorded pointer stream produces the same selected
  range, selected text, and future extension behavior as the live path without
  a recording-format change.
- **I6 -- Completion:** A real extension completes the existing
  copy-on-select path once on release; an inside-selection no-op does not.
- **I7 -- Existing behavior:** Plain selection, Cmd-click link activation,
  token rules, trimmed-line rules, and programmatic Select All retain their
  current behavior. Programmatic selections begin at character granularity.

## Proof obligations

- **PO1 -- Native extension:** Prove extension before and after a selection,
  the distinct start- and end-boundary outcomes, inside-selection no-op
  behavior, and shrink/reversal through collapse and back out at token
  granularity after an outside press.
- **PO2 -- Selection units:** Prove that character, token, and trimmed-line
  selections retain their granularity for extending press click counts 1, 2,
  and 3, including the token- and logical-line-boundary exclusion rules.
- **PO3 -- Lifetime:** Prove that output, scrolling, partial eviction, and
  width reflow preserve extension state when they preserve the selection, and
  that reset or full eviction drops it safely.
- **PO4 -- Routing and completion:** Prove that captured mouse modes receive no
  Shift pointer bytes, every outside extension completes copy-on-select once on
  release even when its range is unchanged, and only an inside-selection no-op
  suppresses completion.
- **PO5 -- Live/replay agreement:** Prove host application and neutral replay
  converge on equal terminal state from the same pointer events.
- **PO6 -- Regression gate:** Write each new behavioral proof first, confirm it
  fails for the expected missing-extension reason, then pass targeted
  TerminalCore and TerminalPTY tests followed by `just test`.

## Non-goals and rejected ideas

- **Non-goal:** Persist selection or granularity through recovery. The engine's
  existing recovery contract excludes selection state.
- **Non-goal:** Add selection dragging to the pasteboard or change ordinary
  clicks inside selected text.
- **Rejected:** Implement extension in the AppKit view. The view already
  forwards the required modifier, click, drag, release, and sub-cell data; UI
  policy there would diverge from replay.
- **Rejected:** Keep settled granularity in `TerminalInteractionState`, whether
  transiently or persistently. A transient value loses native word and line
  extension after release; a persistent value cannot share the selection's
  replacement and drop lifetime, so it can attach stale granularity to a
  programmatic selection.

## Implementation discretion

- The internal representation of the settled selection and fixed endpoint is
  discretionary as long as it satisfies the lifetime and replay invariants.
- Test grouping and helper decomposition are discretionary; proof obligations,
  not file placement, define coverage.
