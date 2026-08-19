# Give each running command in a confirmation its own copy action

## Context

A close or quit confirmation lists the running commands it would end. Today the
whole list is one text document with a single Copy button above it
(`app/ConfirmationPanel.swift`), so the only way to take one command is to
select it by hand: the button copies all of them or nothing.

The user wants to grab one command -- to rerun it elsewhere, or to see what a
truncated-looking line really is -- without touching the others.

The command list already arrives in full, one entry per running command, in pane
order (`ConfirmationProjection.commands`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift`).
Nothing in the model needs to change: the loss is entirely in the presentation,
which flattens that list into a single string before it reaches the screen.

## Decision

Present the commands as a list of items rather than one document. Each item
carries the command text and its own copy action, sitting on its own line above
that command at the leading edge. The list-wide Copy button goes away.

This deletes the panel's hand-built TextKit stack and its layout-manager
measurement, which exist only because the command area was one text blob: item
views size themselves, and the panel keeps deriving its own size from its
content. The scroll bound that keeps the panel on screen is unchanged.

Critical files: `app/ConfirmationPanel.swift` and a new sibling for the item
view, `tests-ui/ConfirmationPanelTests.swift`, and the explicit compile list in
`test-ui.sh` (a raw `swiftc` build that does not glob `app/`).

## Invariants

- **I1.** A confirmation with running commands shows one item per projected
  command, in projection order, with no shortening or elision.
- **I2.** Each item's copy action puts exactly its own command on the clipboard,
  replacing the clipboard's contents -- independent of what is drawn, scrolled,
  or selected, and unaffected by how many items the confirmation holds.
- **I3.** No affordance copies the whole list.
- **I4.** The panel's size is derived from its content -- each item wrapping to
  the width it is actually given, not to a constant -- bounded by a maximum that
  keeps it on screen. Past that bound every item, and its copy action, stays
  reachable by scrolling.
- **I5.** Command text is selectable and not editable.
- **I6.** A confirmation with no running commands shows no command area and no
  copy affordance.
- **I7.** A refresh that resizes an already-visible panel does not move its
  title bar.
- **I8.** Return and Escape still answer the panel while focus sits inside the
  command area, whichever of its subviews holds it.

## Proof obligations

Discharged in the UI harness (`tests-ui/ConfirmationPanelTests.swift`), which
already injects a recording clipboard through the panel's `TextPasteboard` seam.

- **PO1** (I1, I3): a projection of several commands yields that many items in
  order, each holding its command in full, and the panel holds exactly one copy
  control per projected command -- which, with PO2, leaves no room for a
  whole-list action.
- **PO2** (I2): copying from a chosen item writes only that command and clears
  first. This holds for an item the panel is too short to draw, which is the
  regression the old single-document design made unavoidable, and it holds after
  the panel is reconfigured with a different command list -- the item at a
  position copies the command that position now shows, never the one it showed
  before -- and it holds when that item's text is partly selected, where the
  whole command is still what reaches the clipboard.
- **PO3** (I4): a short list sizes the panel to fit; a list past the bound stops
  the visible area at the bound while the content stays taller, with no
  ambiguous layout. An item whose command wraps several times reports the height
  its whole wrapped text needs at the width it is given, so a list under the
  bound shows every line even when a visible scroller narrows that width.
- **PO4** (I5): an item's command text is selectable and not editable.
- **PO5** (I6): an empty command list leaves no items and no copy controls, and
  hides the command area.
- **PO6** (I7): reconfiguring between few, many, and no commands holds the
  panel's top edge.
- **PO7** (I8): with focus installed inside the command area, Return confirms
  and Escape cancels. The test asserts the focus it installed, so it fails
  rather than passing for the wrong reason if the responder it aimed at refuses
  focus, and it does not make the panel key -- a UI-harness run must not take
  the keyboard away from whatever the user is typing in.

## Non-goals

- A whole-list copy affordance, in any form.
- Changing what text is copied. The clipboard gets the display-normalized
  command, the same string the panel draws, as it does today.
- Any change to projection logic or shape. Correcting the projection's own
  comment about the copy affordance, which this change makes false, is in scope.

## Accepted risks

- **AR1.** Dragging one text selection across several commands is lost, because
  the commands stop being one text run. Per-item copy is the affordance that
  replaces it, and single-command selection survives.

## Rejected ideas

- **RI1.** Keeping the single text document and floating a button next to each
  line. A line has no stable anchor -- wrapping and scrolling move it -- so this
  needs glyph geometry to place a control, and the control still cannot say
  which command it belongs to.
- **RI2.** A table view for the list. Variable-height rows around wrapped
  command text are the case tables handle worst, for a list that holds a handful
  of entries.

## Implementation discretion

- The item view's internal composition, spacing, and button styling.
- How the item list is held against the top of the scroll view.
- Whether each copy control carries an accessibility label naming its command.

## Verification

- `just test-ui > .build/ui.log 2>&1`, then grep the log. Write the harness
  tests first and watch them fail for the stated reason before changing the
  panel.
- `just launch-slot`, then open a tab with several panes running commands and
  close it: check each command has its own copy control above it at the leading
  edge, that copying one writes only that command, that a long list scrolls,
  that selecting text in a command and pressing Cmd-C copies the selection, and
  that Return and Escape still answer. Release the slot with `just stop-slot`.

## Implementation notes

- The item's command text is a selectable, non-editable `NSTextField` rather
  than an `NSTextView`. It gives Auto Layout a real wrapped height through
  `preferredMaxLayoutWidth`, which is what lets the panel keep deriving its own
  size from its content after the hand-built TextKit stack was deleted.
- The visible list height is two constraints, not a measured constant: an
  optional "equal to the list's height" against a required "at most the bound".
  Auto Layout resolves that to the smaller of the two, so nothing measures text
  by hand any more.
- Sizing repeats until it settles. An item wraps to the width it is given, so
  its height is known only after a layout pass at the new width, and a visible
  scroller narrowing the list starts the same story again.
- The live check in `## Verification` could not be run. No CLI verb raises a
  confirmation panel: `tab close` and `pane close` treat the explicit id as the
  authorization, and `quit` is documented as unconfirmed. Driving it would mean
  synthesizing Cmd-W into the GUI, which takes the keyboard away from the user.
  The harness discharges every proof obligation, including PO7.

## Follow Up

- No CLI path opens a confirmation panel, so its presentation cannot be checked
  from an agent session. A query or verb that raises the pending confirmation
  for the current tab -- or reports the open panel's contents -- would close
  that gap; `integrations/danterm/SKILL.md` would need the new surface.
