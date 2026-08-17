# Make a confirmation's running commands readable and copyable

## Context

A close confirmation asks the user to decide about a running command, then
refuses to show it. Three losses stack up:

- The pure core shortens the command to 59 characters plus an ellipsis
  (`boundedCommandDetail`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift`),
  so the model hands the view a lossy string and keeps no full one.
- The panel truncates again: a single-line tail-truncating label inside a
  hard-asserted 460x190 window (`app/ConfirmationPanel.swift`).
- When more than one pane is running something, the projection carries no
  command at all. The dialog says "2 running commands" and names neither. The
  quit confirmation, the most destructive path, never names a command at all.

There is also no way to get the command out. The text is a non-selectable
label, and nothing copies it.

The root cause is that the command is modelled as decoration rather than as a
value. Because the only string in the view is already shortened, a copy button
bolted on today would copy an ellipsis. Desired outcome: a confirmation carries
its commands in full, the panel presents as many as fit and scrolls the rest,
and the user can take them.

## Decision

The projection carries the complete command list; the view decides only how it
is presented.

- Every confirmation that would end running commands carries one entry per
  running command, replacing the single optional entry. The single-command case
  becomes a one-element list, so "no command when plural" stops being a special
  case.
- The quit confirmation carries its commands too. It derives them from the live
  model, the way it already derives its live pane count -- quit copy updates as
  panes close while the panel is open, and that behavior stays.
- Length bounding leaves the core. `DisplayLine` flattening stays -- it is a
  safety boundary (controls and bidi overrides), not a length rule.
- The panel presents the commands as one selectable, wrapping document inside a
  scroll view. The panel sizes to its content up to a bound that keeps it on
  screen; past that the document scrolls. Nothing is elided, so a long command
  or a large command set costs scrolling, never reachability.
- A copy affordance sits with the commands, and the document text is
  selectable. The clipboard write goes through an injectable seam, as
  `app/ThemeBrowserView.swift` already does, so a test can observe a copy
  without touching clipboard services.

Critical files: `ModelOperations.swift`, `Model.swift`, `Projections.swift` in
`lib/DanTermCore/Sources/DanTermCore/`, and `app/ConfirmationPanel.swift`.

`app/ConfirmationPanel.swift` is not in the UI harness compile list, so it
cannot be tested at all today. Adding it, and its new test file, to
`test-ui.sh` and the runner in `tests-ui/PaneSplitViewTests.swift` is part of
this change.

## Invariants

- **I1.** A confirmation names every running command among the panes it would
  close -- quit included -- in pane order, each flattened by the display
  boundary and never shortened by length.
- **I2.** The panel's copy affordance puts exactly those commands on the
  clipboard, in order, one per line, independent of what is currently drawn or
  selected.
- **I3.** The panel's size is derived from its content, bounded by a maximum
  that keeps it on screen. Content beyond that bound is reachable by scrolling.
- **I4.** The command text is selectable, and Cmd-C copies the current
  selection, as standard text behavior requires.
- **I5.** A confirmation with no running commands shows no command area and no
  copy affordance.
- **I6.** A refresh that resizes an already-visible panel does not move its
  title bar.

## Proof obligations

- **PO1** (I1): a command longer than the old 60-character bound survives into
  the projection intact; a confirmation covering several running panes projects
  one entry per pane in order; and a pending quit projects the commands running
  across the whole app, still decrementing as panes close. Core tests
  (`lib/DanTermCore/Tests/DanTermCoreTests/CloseConfirmationTests.swift`,
  `ModelOperationsTests.swift`) currently assert the length bound and the live
  quit rollup; the bound assertions become assertions of its absence, and the
  quit rollup assertions extend to commands.
- **PO2** (I1): the existing hostile-input sweep in `DisplayBoundaryTests.swift`
  still shows every projected command flattened, for close and quit alike.
- **PO3** (I2): the copy affordance writes every projected command to a
  recording pasteboard, including a set large enough that the panel scrolls
  rather than showing them all. This is the regression the change exists to
  prevent.
- **PO4** (I3, I6): the panel's frame matches its fitting size while that fits
  the bound, stops growing at the bound and scrolls instead, and holds its top
  edge across a resize on reconfigure.
- **PO5** (I4, I5): the command text reports itself selectable, and an empty
  command list leaves no command text or copy control in the panel.

PO3 through PO5 need a new `tests-ui/ConfirmationPanelTests.swift`, following
`tests-ui/PreferencesPanelTests.swift`: construct the panel against the harness
`AppRuntime`, apply a projection, lay out, then measure.

## Non-goals

- No CLI or IPC surface for opening, reading, or answering confirmations.
- No change to CLI close authorization: an explicit pane or tab id still
  authorizes the close without a dialog.
- Reporting what a CLI close destroyed (running command, unfinished todos) is a
  real gap, but a separate change.

## Rejected ideas

- **RI1.** Adding an `--ask` flag to CLI close so an agent could observe this
  dialog. The flag would exist only to serve a test, and a scripted close that
  blocks on a human answer is a hang.
- **RI2.** Keeping the length bound in the core and copying a separate raw
  command. Two strings for one value is what makes the current bug possible;
  the panel must copy what it was given.
- **RI3.** Freezing an app-wide close impact when the quit confirmation opens.
  Quit copy is deliberately a live rollup that follows the model while the
  panel is open; freezing it would break that.

## Implementation discretion

- Whether the pasteboard seam is shared with `ThemeBrowserView`'s existing
  protocol or declared alongside the panel.

## Verification

- `just test` -- core suites, including the rewritten close-confirmation
  assertions, the extended quit-rollup assertions, and the display-boundary
  sweep.
- `just test-ui` -- the new panel suite. Run it once into a file and grep the
  file.
- Live check, which the harness cannot cover: `just launch-slot`, start a long
  command in a pane, press Cmd-W, and confirm the dialog reads the command
  across several lines, that the copy button yields the full text, and that
  select-all followed by Cmd-C yields the same. Repeat with several panes
  running commands and quit the instance to see the quit dialog name them.
  Release the slot with `just stop-slot <n>` afterwards.

## Implementation notes

- The pasteboard seam is shared with `ThemeBrowserView`, which the plan left to
  discretion. Sharing it meant renaming `ThemeNamePasteboard` to `TextPasteboard`
  and moving it to its own `app/TextPasteboard.swift`: the old name describes a
  theme name, so reusing it for commands would have made the protocol lie about
  what it carries, and neither panel owns a seam both need.
- `PaneModel.runningCommand` is new. The live quit rollup and `closeImpact` both
  need to turn a session's command state into an optional, and a second copy of
  that unwrap is a second place for the two to disagree about what "running"
  means.
- The panel measures its command document through an explicit TextKit 1 stack and
  sets the document view's frame from that measurement, rather than letting a
  display pass size it. The visible height is a cap, so a document still at its
  old size would clip its own text instead of scrolling -- and the UI harness
  lays out headlessly, where no display pass runs at all.
- The heading label now wraps, which the plan did not ask for. It sits in the
  same fixed column as everything else, and a long tab title in `Close tab
  "<title>"?` would otherwise be the one thing left eliding in a panel whose
  point is that nothing elides. Called out because it is a behavior change
  outside the plan's contract, small as it is.
- The panel states one width and derives its height. The bound is a constant
  rather than a query against the current screen, so the bound the tests pin is
  the bound that ships.

## Follow Up

- **Resolved by the commit after this one.**
  `integrations/shell-integration/danterm.fish:38` shortened every reported
  command to 57 bytes, so a fish user's confirmation still named a partial
  command -- not because the model shortened it, but because the shell never
  reported the rest. macOS `base64` wraps its output at 76 columns, and
  `string replace -a '\n' ''` matches the two characters backslash and n, not a
  real newline, so the wrapped payload survives and the value is cut at the
  first line. Running the helper in fish decodes to 57 of 86 input bytes.
  `danterm.bash:37` and `danterm.zsh:41` use `tr -d '\n'` and are unaffected,
  which is what isolates the cause to the fish helper.
