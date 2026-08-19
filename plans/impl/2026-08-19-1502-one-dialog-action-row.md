# One dialog action row, so a popup cannot lay its buttons out wrong

## Context

The close-tab confirmation draws its buttons left-aligned, in the order
`[Cancel] [Close Tabs] [Close Tab]`. macOS puts a dialog's buttons in a
trailing-aligned row with the default action rightmost. The panel's own comment
states the intent ("the buttons keep their natural width and sit at its trailing
edge") and the code does not achieve it.

The cause is a layout contradiction in `app/ConfirmationPanel.swift:94-123`.
`column.alignment = .leading` pins the button row's leading edge, and
`buttonStack.trailingAnchor.constraint(equalTo: column.trailingAnchor)` pins the
other edge, so the row stretches to the full column width.
`NSStackView(views:)` puts its views in the **leading** gravity area, so the
buttons pack left and the slack lands on the right.

This is not one panel's bug. There is no shared idea of "a dialog action row" in
`app/`, so each hand-rolled surface re-derives the layout, and the three that
need a trailing pair each got it wrong in a different way:

| Surface | Renders as | Should be |
|---|---|---|
| `app/ConfirmationPanel.swift:94` | `[Cancel] [Close Tabs] [Close Tab]`, left-aligned | trailing pair/triple, default rightmost |
| `app/RemoteThemePickerSheet.swift:84-88` | `[Cancel]` pinned to the far-left corner, `[Select]` to the far-right | `[Cancel] [Select]` together at the trailing edge |
| `app/TodoPopoverController.swift:201-208` | `[Save] [Cancel]`, left-aligned, reversed | `[Cancel] [Save]` at the trailing edge |

The intended outcome: one type owns the convention, every dialog surface uses
it, and the ordering is decided once instead of at each call site.

### Load-bearing premises

- **The panel's answer branch reads its own view state.**
  `ConfirmationPanel.confirm(_:)` (line 292) decides which `Msg` to send by
  asking `secondaryButton.isHidden`. The view infers model state from a
  visibility flag it set itself.
- **The projection does not describe the buttons, only two titles.**
  `ConfirmationProjection` (`lib/DanTermCore/Sources/DanTermCore/Projections.swift:1067`)
  carries `confirmTitle: DisplayLine` and `secondaryTitle: DisplayLine?`. Cancel
  is invented by the view and never projected, and there is no field naming the
  default, the destructive action, or the order.
- **`ConfirmationProjection: Equatable` is load-bearing.**
  `Reconcile.reconcileConfirmation()` (`app/Reconcile.swift:280`) diffs the
  projection to decide whether to reconfigure the panel, so anything added to it
  must be `Equatable`. `Msg` is not `Equatable`, so a choice cannot carry a
  `Msg`; it carries a small `Equatable` answer the view maps once.
- **The hidden secondary still takes space.** `secondaryButton.isHidden` is set
  without `detachesHiddenViews`, unlike the todo popover's header stacks
  (`app/TodoPopoverController.swift:157`). Building the row from a list of
  choices removes the hidden button entirely, so the question does not arise.
- **The delete-group case is the only three-button confirmation**, and it is the
  only one with two affirmative answers: confirm `Move to <group>` ->
  `.chooseDeleteGroupConfirmation(id:moveTabs: true)`, secondary `Close Tabs` ->
  `moveTabs: false`.
- **Every affected surface is already in the UI harness.** `test-ui.sh` compiles
  `ConfirmationPanel.swift`, `RemoteThemePickerSheet.swift`, and
  `TodoPopoverController.swift`, and `tests-ui/` has a suite for each. A new
  `app/` file must be added to that compile list and its suite registered in
  `tests-ui/PaneSplitViewTests.swift:20-38`.
- **The delete-group layout has no harness coverage today.**
  `makeConfirmationProjection` in `tests-ui/ConfirmationPanelTests.swift:268`
  always passes `secondaryTitle: nil`, so no test has ever drawn the
  three-button row or exercised the `moveTabs` mapping.
- **A real app models this as an ordered list of actions with roles.** iTerm2's
  warning layer takes `NSArray<iTermWarningAction *>` where each action carries a
  label and a `destructive` flag, and feeds them to `NSAlert` in order
  (`references/iterm2/sources/iTermWarning.m#-makeAlert`,
  `references/iterm2/sources/iTermWarning.h#iTermWarningAction`). Its two-button
  alerts add the affirmative action first and `Cancel` second
  (`references/iterm2/sources/SSHFilePanel.swift#SSHFilePanel`,
  `references/iterm2/sources/PTYSession.m#-tmuxGatewayShouldForceDetach`), which
  under `NSAlert`'s right-to-left placement renders as `[Cancel] [Default]`.
  Ghostty only ever builds two-button alerts, in the same order
  (`references/ghostty/macos/Sources/Features/Terminal/BaseTerminalController.swift#closeWindowImmediately`).

## Decision

Four moves.

**1. A dialog action row type owns the convention.** A new
`app/DialogActionRow.swift` holds one view that takes actions with roles and
lays them out the macOS way. It is the only place in the app that knows where a
dialog button goes.

```swift
/// Where one action sits in the macOS button order. The row, not the caller,
/// turns a role into a position, so no surface can order its buttons wrong.
enum DialogActionRole { case defaultAction, cancel, alternate }

/// One button a dialog offers: what it says, what it costs, what it does.
struct DialogAction {
    let title: String
    let role: DialogActionRole
    var isDestructive: Bool = false
    var isEnabled: Bool = true
    let perform: () -> Void
}

/// The trailing-aligned action row every DanTerm dialog uses, so button order
/// and alignment are stated once instead of at each call site.
@MainActor final class DialogActionRow: NSView {
    init(actions: [DialogAction], reservesKeyEquivalents: Bool = true)
    func setActions(_ actions: [DialogAction])
    var buttonsInVisualOrder: [NSButton] { get }   // leading -> trailing
    func button(for role: DialogActionRole) -> NSButton?
}
```

Mechanics that make trailing packing correct -- this is exactly what today's
code gets wrong:

- One internal horizontal `NSStackView` with the default
  `distribution = .gravityAreas`, `alignment = .centerY`, `spacing = 12`, pinned
  to all four edges of the row view.
- Alternates go in with `addView(_:in: .leading)`; cancel then the default go in
  with `addView(_:in: .trailing)`. A gravity-area stack pins its `.trailing`
  views to the trailing edge and its `.leading` views to the leading edge, and
  all slack lands in the middle. With no alternates the leading area is empty and
  the cancel/default pair hugs the trailing edge, so the two-button case comes
  out right from the same code path.
- `setHuggingPriority(.defaultLow, for: .horizontal)` so the row stretches to the
  width its host gives it. That stretch is what the trailing gravity needs to
  bite.
- `setActions` clears both gravity areas and builds fresh buttons, so no hidden
  button ever holds space and `detachesHiddenViews` never comes up.
- Per button: `bezelStyle = .push`, `hasDestructiveAction = action.isDestructive`,
  equal heights constrained to the first button, and `target`/`action` routed
  back to the stored `perform` closure by button identity.
- Key equivalents when `reservesKeyEquivalents`: `"\r"` on the default (which is
  also what paints it blue) and `"\u{1b}"` on cancel.
- Alternates get `.defaultHigh` horizontal compression resistance and
  `byTruncatingTail`; cancel and the default keep `.required`, so a long
  alternate title truncates rather than blowing out the dialog width.
- Leading/trailing rather than left/right, so RTL flips for free.

**2. The model states the choices; the view states only the convention.**
`ConfirmationProjection` drops `confirmTitle` and `secondaryTitle`. Roles are
structural rather than a field, so "two default buttons" and "a confirmation you
cannot cancel" are both unrepresentable:

```swift
/// What answering a confirmation means, in model terms. Equatable so the
/// projection stays diffable; the panel is the only thing that maps one to a Msg.
enum ConfirmationAnswer: Equatable, Sendable {
    case confirm
    case cancel
    case deleteGroup(moveTabs: Bool)
}

/// One button a confirmation offers: its copy, its answer, and whether it
/// destroys work.
struct ConfirmationChoice: Equatable, Sendable {
    let title: DisplayLine
    let answer: ConfirmationAnswer
    var isDestructive: Bool = false
}

struct ConfirmationProjection: Equatable {
    let id: ConfirmationId
    let title: DisplayLine
    let informativeText: String
    let commands: [DisplayLine]
    let confirm: ConfirmationChoice         // the default answer, drawn rightmost
    let cancel: ConfirmationChoice          // always present; the model owns its copy
    let alternatives: [ConfirmationChoice]  // other answers, on the leading side
}
```

Each `desiredConfirmation` branch fills it:

- `.app`: confirm `Quit` (destructive), cancel `Cancel`, no alternatives.
- `.pane`: confirm `Close Pane` (destructive).
- `.tab`: confirm `Close Tab` (destructive).
- `.tabs`: confirm `Close N Tabs` (destructive).
- `.deleteGroup`: confirm `Move to <group>` answering `.deleteGroup(moveTabs: true)`,
  not destructive; one alternative `Close Tabs` answering
  `.deleteGroup(moveTabs: false)`, destructive.

`ConfirmationPanel` stores the projection instead of a bare id, and every way a
user can answer -- a click, Return, Escape, closing the window -- funnels through
one mapping:

```swift
/// The single seam between a model-owned answer and a Msg.
private func answer(_ choice: ConfirmationChoice) {
    guard let id = projection?.id else { return }
    switch choice.answer {
    case .confirm: runtime?.send(.confirmConfirmation(id: id))
    case .cancel: runtime?.send(.cancelConfirmation(id: id))
    case .deleteGroup(let moveTabs):
        runtime?.send(.chooseDeleteGroupConfirmation(id: id, moveTabs: moveTabs))
    }
}
```

`secondaryButton`, `confirmButton`, the local `cancelButton`, `chooseCloseTabs`,
and the `secondaryButton.isHidden` branch are all deleted. The reserved
Return/Escape handling in `sendEvent(_:)` (lines 259-288) stays and resolves
through the projection: Return answers `confirm`, Escape answers `cancel`.

**Weighed against the cheap fix** -- keep the projection as-is and only correct
the view's gravity area and order. It fixes the screenshot in about eight lines.
It is rejected because the panel stays hard-coded to three buttons, keeps
deciding which message to send by reading a hidden view, leaves Cancel's copy
owned by the view while every other word in the dialog is model-owned, and
leaves the projection unable to say that an answer destroys work. The bug being
fixed is that layout and answer knowledge are scattered; the cheap fix keeps
them scattered.

**3. The other two surfaces adopt the row.**

- `app/RemoteThemePickerSheet.swift`: one `DialogActionRow` holding
  `[Select (default, disabled until a row is chosen), Cancel]`, pinned
  leading/trailing/bottom at the existing 12pt insets, with
  `scrollView.bottomAnchor == actionRow.topAnchor - 12`. The two corner pins and
  both `keyEquivalent` lines go away. `selectButton` and `cancelButton` become
  computed accessors reading the row, so the existing suite and the
  enable/disable logic keep working untouched.
- `app/TodoPopoverController.swift`: one `DialogActionRow` holding
  `[Save (default), Cancel]` built with `reservesKeyEquivalents: false`, because
  `editInput.textView` already classifies Return and Escape and a key equivalent
  on Save would fight it. Because the edit column is `.leading`-aligned, the row
  needs `widthAnchor == editContainer.widthAnchor` or it gets only its fitting
  width and trailing gravity has no slack to work with -- the same root cause as
  the original bug, one file over. `saveButton`/`cancelButton` become accessors,
  so the first-responder restore at lines 375-387 is unchanged. The
  `nextKeyView` chain (lines 432-440) is derived from the drawn order rather
  than restated, so it cannot desync from the layout:

```swift
let chain: [NSView] = [editInput.textView] + editButtons.buttonsInVisualOrder
for (view, next) in zip(chain, chain.dropFirst() + [chain[0]]) { view.nextKeyView = next }
```

**4. The confirm panel adopts the rest of the alert convention.** Blank the
panel's window title (`title = ""`) so the heading is not repeated in the title
bar, the way a native alert has no title bar at all. Keep `.closable` so
`windowShouldClose` still cancels the transaction.

Critical files: `app/DialogActionRow.swift` (new),
`app/ConfirmationPanel.swift`, `app/RemoteThemePickerSheet.swift`,
`app/TodoPopoverController.swift`,
`lib/DanTermCore/Sources/DanTermCore/Projections.swift`, `test-ui.sh`,
`tests-ui/PaneSplitViewTests.swift`, plus the suites under Proof obligations.

## Invariants

- **I1.** No dialog surface states a button position. Ordering and alignment
  come from `DialogActionRow` alone; a call site supplies titles, roles, and
  handlers.
- **I2.** In any dialog action row, the default button is rightmost, cancel is
  immediately left of it, and every other action is left of cancel, separated
  toward the leading edge.
- **I3.** A dialog action row's trailing edge sits at its container's trailing
  content inset. No dialog action row is leading-aligned, and no pair is split
  across opposite corners.
- **I4.** A confirmation panel renders exactly the choices the projection
  carries. The panel invents no button and hides none, and every confirmation
  has exactly one default answer and exactly one cancel answer.
- **I5.** The message sent for an answer is derived from the answered choice,
  never from a view's visibility or position.
- **I6.** Return answers the `confirm` choice and Escape the `cancel` choice,
  whatever holds first responder in the panel.

## Proof obligations

Pure suite (`swift test --package-path lib/DanTermCore`):

- **PO1** (I4) -- all five subjects project a cancel answer of `.cancel` and a
  confirm answer that is not `.cancel`, so no branch can ship a dialog you
  cannot back out of. Existing assertions at
  `CloseConfirmationTests.swift:24,32`, `ProjectionsTests.swift:302`, and
  `UpdateGroupTests.swift:81,145` are restated against `confirm.title`.
- **PO2** (I4) -- the delete-group confirmation carries one alternative titled
  `Close Tabs` answering `.deleteGroup(moveTabs: false)`, and a confirm answering
  `.deleteGroup(moveTabs: true)` (`UpdateGroupTests.swift:60-91`).
- **PO3** (I4) -- quit, close pane, close tab, close tabs, and the `Close Tabs`
  alternative are marked destructive; `Move to <group>` is not.
- **PO4** -- two projections differing only in an alternative are not equal, so
  the `reconcileConfirmation` diff still reconfigures the panel.

UI harness (`just test-ui`), new `tests-ui/DialogActionRowTests.swift`:

- **PO5** (I2) -- given three actions in scrambled order, the titles sorted by
  `frame.minX` read alternate, cancel, default. Asserted from frames, not from
  stack-view properties.
- **PO6** (I3) -- the default's `frame.maxX` equals the row's `bounds.maxX`, and
  in the two-action case cancel's `frame.minX` is past the row's midpoint. That
  second assertion is the exact regression: today Cancel sits at x is about 0.
- **PO7** (I2) -- an alternative sits at the leading edge and is separated from
  the cancel/default pair by more than the row spacing.
- **PO8** (I5) -- clicking each button runs its own action exactly once.
- **PO9** -- the row assigns Return and Escape only when it reserves them, and
  neither when built with `reservesKeyEquivalents: false`.
- **PO10** (I4) -- setting three actions and then two leaves two buttons, still
  hugging the trailing edge. This is the hidden-button defect stated
  behaviorally.

UI harness, existing suites:

- **PO11** (I2, I3) -- `ConfirmationPanelTests.swift`: a delete-group projection
  draws `Close Tabs`, `Cancel`, `Move to General` in that left-to-right order,
  with the rightmost button's trailing edge at the content inset. This is the
  first harness coverage of the secondary path at all.
- **PO12** (I5) -- each of those three buttons sends the message its choice
  names, read off the fake runtime's `sentMessages`.
- **PO13** (I6) -- synthesized Return sends `.confirmConfirmation` for a
  close-tab confirmation and `.chooseDeleteGroupConfirmation(moveTabs: true)`
  for a delete-group one, with a command item holding first responder. This is
  the regression pin for the deleted `isHidden` branch.
- **PO14** (AR2) -- a confirmation with a very long confirm title keeps its
  rightmost button inside `contentView.bounds`, and a second `configure` with
  the same projection leaves the panel frame unchanged. That is the
  `sizeToContent()` convergence check, stated behaviorally.
- **PO15** (I2, I3) -- `RemoteThemePickerSheetTests.swift`: Cancel is drawn left
  of Select, adjacent rather than at opposite corners, with Select's trailing
  edge at the container inset. The existing enable/disable and `onSelect` tests
  keep passing through the accessors.
- **PO16** (I2, I3) -- `TodoPopoverViewTests.swift`: in edit mode Cancel is drawn
  left of Save at the trailing inset; walking `nextKeyView` from the edit input
  visits the buttons in ascending `frame.minX` order and closes back on the
  input; and Return in the edit input still runs the existing input command
  rather than being taken by Save.
- **PO17** -- `just test` and `just test-ui` both pass.

## Verification

1. `swift test --package-path lib/DanTermCore` for the projection changes, then
   `just test` for the whole gate.
2. `just test-ui > .build/ui.log 2>&1`, then grep the log.
3. `just launch-slot | tail -1`, then in the slot start a long-running command in
   a pane and press Cmd-W to raise the real confirmation, screenshot it, and
   confirm `[Cancel] [Close Tab]` sits at the trailing edge with a red default
   and no repeated title bar text. Repeat for a group delete to see the
   three-button row, for Preferences -> Browse to see the theme sheet, and for a
   todo edit to see the Save/Cancel row. `just stop-slot <n>` when done.

Note: the `danterm` CLI cannot open or answer a confirmation today -- it
deliberately bypasses the gate (`integrations/danterm/SKILL.md:351,448`) -- so
step 3 is a GUI stimulus. Adding a CLI route is out of scope here.

## Non-goals

- Header and toolbar button rows: the alerts popover header, the todo popover
  header actions, `ThemeBrowserView`'s header, `PreferencesPanel`'s grid, and
  `SearchOverlayView`. These are not dialog action rows and the convention does
  not apply to them.
- The four `NSAlert` sites (`app/AppDelegate.swift:163,596,607`,
  `app/AppRuntimePorts.swift:47`). AppKit already orders and aligns them, and the
  restore prompt already adds its default first.
- Making the confirmation panel modal, or replacing it with `NSAlert`. The panel
  is deliberately non-modal and transaction-id addressed.
- A CLI route for opening or answering a confirmation.

## Accepted risks

- **AR1.** The three-button order is a judgement call. The rule adopted here --
  alternatives on the leading side, cancel next to the default -- is Apple's
  Save / Don't Save / Cancel shape, and it is what most of iTerm2's three-button
  warnings do (`references/iterm2/sources/iTermAPIHelper.m`,
  `iTermPasteHelper.m`, `iTermScriptImporter.m` all pass `OK, Cancel, <other>`).
  Some iTerm2 sites instead park Cancel last, which lands it furthest left
  (`references/iterm2/sources/KeysPreferencesViewController.m`). That
  inconsistency is the "every site re-derives it" failure being removed here.
  The rule lives in one place, so reversing it later is a one-line change.
- **AR2.** `column.widthAnchor.constraint(equalToConstant: 460)` is required, so
  a three-button row wider than 460 breaks a constraint and logs. Fixed as part
  of this change: make it `greaterThanOrEqualToConstant:` with a required upper
  bound, and let the alternate's lowered compression resistance truncate past
  that. The label width equalities keep wrapping correct at the wider size, and
  `DisplayLine` guarantees single-line titles so no button wraps. PO14 pins the
  result.
- **AR3.** With a `>=` width, `fittingSize` now depends on the row too, so a wide
  row widens the panel, which re-wraps the labels, which changes the height --
  one more feedback edge through `sizeToContent()`'s loop (lines 190-217). The
  loop already compares both dimensions over four passes, and row width settles
  on the first pass without depending on height.
- **AR4.** Inside `ConfirmationPanel`, `sendEvent` intercepts Return and Escape
  and never calls `super`, so the row's key equivalents never fire there; they
  remain for the default button's blue tint and for the other two surfaces. A key
  equivalent on an alternate would be dead in that panel. Both paths funnel
  through `answer(_:)`, so they cannot diverge in meaning. Document this in the
  row's doc comment.
- **AR5.** Marking `Close Tabs` destructive turns it red. That is a deliberate,
  visible copy change, not just a layout fix.

## Rejected ideas

- **RI1.** Fix only the gravity area in `ConfirmationPanel` and leave the other
  two surfaces. It repairs the screenshot and leaves the cause: three surfaces,
  three hand-rolled layouts, no shared rule.
- **RI2.** Keep `confirmTitle` / `secondaryTitle` and add an ordering field. It
  grows the projection without removing the view's invented Cancel or its
  `isHidden` branch, and still cannot express a confirmation with a different
  number of answers.
- **RI3.** A flat `[choice]` list with a role on each choice, rather than
  `confirm` / `cancel` / `alternatives` fields. It allows a projection with two
  defaults or no cancel, which the field split makes unrepresentable.
- **RI4.** Replace the panel with `NSAlert` to get the convention free. It is
  modal and it cannot carry the scrolling per-command copy list the panel exists
  to show.

## Implementation discretion

- Whether `DialogActionRow` is an `NSView` subclass or a factory returning a
  configured `NSStackView`, so long as I1 holds and the drawn order is readable
  from outside for tests.
- Whether each adopting surface keeps stored button references or computed
  accessors onto the row.
- The exact upper bound on the confirmation panel's width, and the exact spacing
  constants, provided they come from AppKit's standard metrics and are stated
  once.

## Commit progress
- [x] 1. feat(app): one dialog action row that owns macOS button order
- [x] 2. refactor(app): confirmations project their choices
- [x] 3. refactor(app): theme sheet and todo editor adopt the action row

## Implementation notes

- The plan names `app/TodoPopoverControllerBase.swift`, which the preceding
  commit renamed to `app/TodoPopoverController.swift`. The plan's path
  references were updated; the surface and its layout are unchanged.
- `DialogActionRow` uses `setContentHuggingPriority(_:for:)`, not the plan's
  `setHuggingPriority(_:for:)` -- the latter is `NSStackView`'s, not `NSView`'s.
- The plan's truncation rule ("alternates get `.defaultHigh`, cancel and the
  default keep `.required`") reads as if `.required` were NSButton's default.
  It is not: NSButton ships at `.defaultHigh` horizontally, so setting the
  alternate to `.defaultHigh` would be a no-op and nothing would truncate first.
  Cancel and the default are raised to `.required` instead, leaving the
  alternate at the default and making it the one that gives.

- AR2's "required upper bound" on the panel column is implemented as three
  constraints, not two: a required floor at the text width, a required ceiling
  at `confirmationMaxColumnWidth`, and a `.defaultHigh` equality at the text
  width. Without the optional equality the column would satisfy the floor at any
  width and stretch to the ceiling for every confirmation.
- `ConfirmationChoice.isDestructive` and `ConfirmationProjection.alternatives`
  are `var` with defaults, so the four single-answer branches state neither.

- PO15 was stated as "Cancel sits past the container midpoint". The remote
  theme sheet is 300pt wide and the pair plus spacing is about 166pt, so a
  trailing-aligned Cancel legitimately starts left of the midpoint. The
  assertion pins the same regression from the other side instead: Cancel is no
  longer at the leading inset, and the two buttons are adjacent.
- The todo editor's button spacing goes from 8pt to the row's shared 12pt,
  because the row states the constant once for the whole app.
- Verification step 3 (a live slot, screenshots of all four surfaces) was not
  run: the harness frame assertions cover the drawn geometry, and another
  agent was editing build scripts in this working tree at the time.
