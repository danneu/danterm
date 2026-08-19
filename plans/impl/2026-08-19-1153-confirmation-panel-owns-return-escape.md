# Confirmation panel owns Return and Escape

## Problem

Return does not confirm the close/quit confirmation panel whenever the panel
lists running commands. The user reported it for Cmd-W pane close and expected
it to affect tab close too.

Cause: the command list is a selectable `NSTextView` that sits ahead of the
button row in the panel's key loop, so it takes first responder when the panel
opens and swallows Return. The default button never fires.

Evidence, from synthesized AppKit keypresses against a dev slot:

- Return sent 0.15s, 0.2s, 0.6s, 1.5s, and 4s after Cmd-W: never confirms.
  Waiting is not the variable; the user's "it works after a second" comes from
  something else moving focus, not from the clock.
- Cmd-W, Tab, Return: confirms immediately.
- Ablation -- a close warning raised by a pane todo with an idle shell, so the
  command list is empty and the text view is hidden: Return confirms at 0.3s.
- Escape always cancels immediately. Why it survives is not ablated: the cancel
  button also carries a key equivalent, so Escape may well travel the same walk
  and simply not be intercepted. The observed fact is that the command list eats
  Return and not Escape.

One `ConfirmationPanel` instance serves all five confirmation subjects (pane,
tab, tabs, group delete, quit), so this is one defect with one fix. Group delete
projects an empty command list and is the only subject that never shows the
symptom.

## Decision

The panel answers Return and Escape itself, before AppKit walks its subviews.
The panel holds no editable text, so those two keys can only mean "confirm the
default answer" and "cancel" -- no subview has a legitimate claim on them.

Chosen over making the command list non-focusable: that fixes only the
open-time case, breaks again as soon as the user clicks into the list to select
text, and costs mouse selection. The panel-owned rule holds for any focus-taking
subview added later.

Escape is handled in the same place for symmetry. That is a no-op today; it
makes both answers immune to interception rather than leaving one of them
working only because nothing happens to intercept it.

The confirm button keeps its Return key equivalent, which is what draws it as
the default button.

Scope: `app/ConfirmationPanel.swift` only.

## Invariants

- **I1.** While the confirmation panel is key, Return activates its default
  answer and Escape cancels, whatever subview holds first responder. The rule
  matches only an unmodified press: Command, Option, or Control with Return or
  Escape is left to travel its ordinary path, as it does for a native default
  button.
- **I2.** Return activates the same answer the default button does, including
  the group-delete case where the default answer is "move tabs" and the
  secondary button offers "close tabs".
- **I3.** The command list stays mouse-selectable, and the Copy button still
  writes the whole projected list.

## Verification

Automated coverage is deliberately skipped (see Accepted risks). Verify by hand
against a dev slot, driving real AppKit keypresses (System Events can synthesize
Cmd-W and Return; the `danterm` CLI cannot, because the defect lives above the
PTY):

1. Split a pane, start a long-running command in it so the confirmation lists a
   command, then Cmd-W and Return with no delay -- the pane closes.
2. Repeat with Escape -- the confirmation cancels.
3. Repeat for a tab close and for quit, both with a running command.
4. Delete a group that has tabs, so the confirmation shows two answers. Return
   must run the default answer, "Move to <group>", not the secondary "Close
   Tabs", and the secondary button must still work by click.
5. Click into the command list to select text, then press Return -- still
   confirms. Close and reopen a confirmation afterwards and press Return with no
   click first -- still confirms.

`just test-ui` must stay green: `tests-ui/ConfirmationPanelTests.swift` already
covers copy, sizing, scrolling, selectability, and the empty-command-area case.

## Non-goals

- `app/RemoteThemePickerSheet.swift` has the same class of bug from a different
  mechanism: its search field is first responder and its field editor eats
  Return, so Return filters instead of activating the default "Select" button.
  Not fixed here; raised for a separate decision.

## Accepted risks

- **AR1.** No automated test pins I1 or I2, skipped by instruction rather than by
  difficulty. The route exists and is cheap: `tests-ui/TodoPopoverViewTests.swift`
  already synthesizes a key event and calls `performKeyEquivalent` directly, and
  the harness `AppRuntime` shim records dispatched messages, so a test can focus
  the command text view and assert the confirm message. Risk: a later change to
  the panel's key handling regresses Return with nothing catching it.

## Rejected ideas

- **RI1.** Make the command list non-focusable (`isSelectable = false`). Fixes
  the open-time case only, loses mouse selection, and leaves the structural hole
  open for the next focus-taking subview.

## Implementation discretion

- Whether keypad Enter counts as Return, and how the unmodified-press rule in I1
  treats flags the user did not choose, such as caps lock.

## Implementation notes

- The panel claims the two keys in `sendEvent(_:)`, not in
  `performKeyEquivalent(with:)`. The first attempt used
  `performKeyEquivalent`, and hand verification against a dev slot showed it
  changed nothing: Return still never confirmed while the command list was
  present. Return reaches a default button through the responder chain, not
  through the key-equivalent walk, so a window-level `performKeyEquivalent`
  override never sees it. `sendEvent` is the earliest per-window point and runs
  before any responder walk; with it, Return confirms 0.15s after Cmd-W.
- I1's "unmodified press" is read strictly: Command, Option, Control, and Shift
  all send the event down its ordinary path. Caps lock, the function flag, and
  the keypad flag are not choices the user made about the press, so they are
  ignored -- which is also what makes keypad Enter count as Return, per the
  discretion the plan left open.
- Verification 4 (group delete, two answers) was not driven by hand. The
  group-delete confirmation is raised only from the sidebar context menu, which
  the CLI cannot open and `AXShowMenu` did not open either; `group close` over
  the CLI closes the group without a confirmation. Return runs `confirm(_:)`,
  the same selector the confirm button targets, so it cannot pick a different
  answer than the button. Verifications 1, 2, 3, and 5 all passed against a dev
  slot with real AppKit keypresses.

## Follow Up

- `app/RemoteThemePickerSheet.swift`: Return filters the list instead of
  activating the default "Select" button, because the search field's field
  editor eats it. Same class of defect, different mechanism; the plan names it
  as a non-goal and it still needs a decision.
- No automated test pins I1 or I2 (AR1). The route is cheap:
  `tests-ui/TodoPopoverViewTests.swift` already builds a synthetic key event,
  and the harness `AppRuntime` shim records dispatched messages, so a test can
  focus the command text view, hand the panel a Return event, and assert the
  confirm message. Note the event must go to `sendEvent(_:)`, not
  `performKeyEquivalent(with:)`.
