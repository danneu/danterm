# Local pointer selection lifetime under mouse reporting

## Context

Inside a TUI that enables mouse tracking (opencode), the local selection has no
way out. Shift is the only arm that still selects, and two failures follow from
that:

- Nothing removes a selection. A plain press is routed to the report arm and
  settles nothing, and nothing in the app calls the clear path that
  `TerminalPaneSession.clearSelection()` already exposes. Once a Shift drag
  highlights text, the highlight can survive for the session.
- A Shift press pivots on a caret -- an empty settled selection that draws
  nothing. Under tracking the only gesture that can place that caret is a Shift
  press, which is also the gesture that consumes it. So the first Shift click
  reads as inert and the second one highlights a span between two points the
  user never saw chosen.

The caret pivot arrived with `83af23e0` for AppKit parity, and G6 records it as
live. That parity is deliberate and stays: outside mouse reporting a plain click
places the caret on purpose, and the Shift-click after it selects between the
two points the user picked. What breaks is the Shift press that mints a caret
of its own: under reporting that is the only caret anyone can place, so every
one of them is invisible.

No terminal we track extends from an invisible selection: ghostty
(`Surface.zig:3903`), kitty (`mouse.c:387`), and iTerm2 (`PTYMouseHandler.m:332`)
all require a visible selection. Ghostty and iTerm2 also clear a local selection
when they report a press to the child (`Surface.zig:3996`,
`PTYMouseHandler.m:300`). DanTerm adopts that pointer lifetime rule without
claiming a common wheel policy across the reference terminals.

Outcome: a reported press takes the local selection away, and the only hidden
caret that survives a gesture is the one a plain click aimed.

## Direction

Three rules, all decided inside the existing pointer policy and settled through
the existing pointer applier.

1. **A press the report arm owns clears the local selection.** It still sends
   the same bytes to the child. Pointer policy emits one selection effect, so
   clearing and settling a selection cannot both happen for the same event.
   (`83af23e0` made `TerminalSelectionMutation` a struct rather than an
   alternative because the caret was then the only way to express "no
   selection". A report-arm clear has no unit, boundary, or granularity to
   name, so the effect becomes a set-or-clear alternative again.)

2. **Only a plain press can leave a caret behind.** A press that the selection
   arm owns settles the hidden caret its drag needs. At release, the caret
   survives only if a plain press placed it while the child did not own the
   mouse -- the one caret the user aimed. A caret a Shift press minted is
   gesture-local and goes when the gesture ends. The rule reads the press, not
   the release, so a mode change during a held gesture cannot alter what that
   gesture leaves behind. Output and reflow during a held gesture keep using the
   terminal's existing anchored-selection behavior.

3. **While the child owns the mouse, Shift multi-click starts a new
   selection.** A Shift single-click extends a visible selection and otherwise
   starts its own gesture-local caret. Under mouse reporting a Shift
   double-click replaces any existing selection with the token under the
   pointer, and a Shift triple-click replaces it with the line, because no plain
   click is available to move the anchor there first. This keeps Shift as the
   local escape hatch inside a mouse-reporting application, including the
   opencode workflow of Shift-double-clicking a file path. With reporting off
   the plain click exists, so Shift extension stays click-count independent, as
   it is today.

A drag continues to pivot on the anchor the terminal holds, caret included,
while the left button remains latched to the selection arm. A Shift drag with a
visible selection extends it; without one it starts from its own press.

G6 in `docs/design/2026-08-06-swift-terminal-engine.md` is amended in the same
commit. It keeps the plain-click caret and the Shift-click that follows it, and
gains two departures: a reported press clears the local selection, and only a
plain press leaves a caret that outlives its gesture. Its captured-mouse clause
gains the second one -- Shift-left no longer runs the same rule end to end,
because under capture a Shift multi-click replaces the selection instead of
extending it.

### Invariants

- A pointer decision cannot both settle a selection and clear one; the two are
  alternatives in one selection effect, not independent fields.
- A caret survives release only when a plain press placed it while the child
  did not own the mouse. Every other gesture leaves either a visible selection
  or nothing, so a hidden caret can never pivot a gesture the user did not aim.
- Every live and replay consumer settles the decision through
  `applyTerminalPointerDecision`, so both reach the same selection state.

## Non-goals and accepted risks

- Clear-on-typing. Ghostty gates it behind a setting; it is a separate
  behavior with its own argument, and neither failure above needs it.
- Clear-on-wheel. Child-directed scrolling can make a highlight stale, but it
  is an independent lifetime policy with fractional-input and publication
  behavior of its own. This plan fixes pointer dismissal without taking that
  scope on.
- Any change to copy-on-select, to what a completed gesture relays, or to the
  Cmd-click link arms.
- Making unmodified drag or multi-click selection work while the child owns the
  mouse. Shift remains the local escape hatch.
- **Accepted risk:** under mouse reporting, a Shift double-click over an
  existing selection relays the intermediate extension to copy-on-select before
  the token replaces it, because macOS delivers the gesture as a
  `clickCount: 1` press and release followed by a `clickCount: 2` press. The
  final selection and the final clipboard content are the token; suppressing the
  intermediate write would need the policy to guess at a click that has not
  arrived.

## Rejected ideas

- **Keep the caret after release and teach Shift to ignore it.** Fixes the
  immediate trap but leaves invisible settled state available to another
  consumer. Ending the caret with its gesture establishes the stronger
  lifetime invariant and keeps the same within-gesture anchor behavior.
- **Clear the caret on every selection-owned release.** One uniform rule, but
  it undoes the AppKit parity G6 records: click-then-Shift-click in a plain
  shell would stop selecting between the two points.
- **Decide the caret's fate from the mouse-reporting mode at release.** Reads
  one live fact instead of remembering the press, but the mode can change
  between press and release: a plain click in a shell that starts a TUI loses
  its caret, and a Shift gesture that outlives the TUI keeps an invisible one
  that re-arms the two-click trap. The fact that matters is whether the user
  could aim the caret, which the press already knows.
- **Replace the caret with a second gesture-anchor system.** Removes invisible
  selection state entirely but duplicates the terminal's anchored tracking
  across output, reflow, and scrollback changes. The caret remains useful as an
  internal held-gesture representation; only its cross-gesture lifetime is the
  problem.
- **Draw the caret** (option C). Closes the class in both modes and keeps the
  AppKit idiom, but puts a second insertion bar next to the terminal cursor and
  is renderer work rather than policy work.

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift` --
  decides the report-arm clear, gesture-local caret release, and Shift
  multi-click precedence.
- `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionApply.swift` --
  gives pointer decisions one alternative selection effect that can settle or
  clear through the existing applier.
- `docs/design/2026-08-06-swift-terminal-engine.md` -- G6 gains the
  reporting-scoped caret lifetime and the reported-press clear.

## Verification

Red-phase tests already exist in
`lib/TerminalCore/Tests/TerminalCoreTests/TerminalSelectionUnderMouseReportingTests.swift`:
the reported-press test fails, and the two-Shift-click test passes today because
it pins the trap and must flip. `reportedWheelClearsSelection` in that file is
outside this plan and is deleted from it before the commit, parked with the
clear-on-wheel follow-up rather than landing red in the gate.

Proof obligations:

- A press the child receives leaves no selection behind, for every button it
  can report.
- A Shift press keeps its caret through movement and clears it on release when
  the gesture makes no visible selection. Two Shift presses in a row therefore
  select nothing, in either mode.
- A plain click still leaves the caret its later Shift-click selects from (G6
  parity), which is only reachable with mouse reporting off.
- Mouse reporting turning on or off between a press and its release does not
  change what the gesture leaves behind, in either direction.
- A Shift drag still selects, which is the one gesture that must keep working
  while the child owns the mouse.
- A Shift single-click extends an existing visible selection.
- Under mouse reporting, a Shift double-click over an existing selection,
  driven as the full press/release/press sequence macOS delivers, ends with the
  pointed token selected and with the token as the copy-on-select text; a Shift
  triple-click ends with the line.
- With mouse reporting off, a Shift double-click over an existing selection
  still extends from its anchor, unchanged by click count.
- A replayed recording and a live session reach the same selection state across
  a reported press and a selection-owned release.

Run `swift test --package-path lib/TerminalCore` (the pointer, selection, and
WezTerm-adapted suites read selection outcomes and will need their expectations
reconciled), then `just test` before committing.

End-to-end, in the app: launch a slot, run opencode, Shift-drag to select, then
click once in the TUI and confirm the highlight is gone. With a selection
already visible, Shift-double-click a file path and confirm the path replaces
the old selection. Shift-click twice in different places and confirm no hidden
caret creates a selection between them. Outside the TUI, click once in the
shell and Shift-click elsewhere: the span between the two points still selects,
and a Shift-double-click over it still extends rather than replacing.

## Commit progress

- [x] 1. feat(selection): clear the local selection on a reported press
- [x] 2. fix(selection): end a Shift-placed caret with its gesture
- [ ] 3. feat(selection): let Shift multi-click restart a selection under mouse reporting

## Implementation notes

- The red-phase test file arrives one slice at a time rather than whole. The
  Shift-caret test in it pinned the trap as current behavior, so landing it in
  commit 1 would have committed an assertion that commit 2 inverts. Commit 1
  carries only the reported-press proofs; the caret tests arrive with the
  commit that changes the caret.
- `SettledSelectionOutcome` in the test assertions helper gained a `.cleared`
  case, so a test states "the press took the selection away" rather than
  reading `terminal.selectionRange` alone. Two existing expectations in
  `TerminalInteractionPolicyTests` that read `.unchanged` for a captured-mouse
  press now read `.cleared`; both already meant "this press settles no
  selection".

- The press fact the release needs travels in the button latch itself:
  `pointerOwners` now holds a private `TerminalPointerGesture` whose `.selection`
  case carries `caretOutlivesGesture`, rather than a second field on
  `TerminalInteractionState`. A separate field could describe a caret rule for a
  button that owns no gesture; the payload cannot exist without one. It costs the
  arm comparisons a `.consumption` hop.
- `Terminal.holdsCaret` is internal. Pointer policy is its only consumer, and a
  caret is engine-side state no host acts on, so it stays out of the public
  selection surface until something outside the module needs it.

## Follow Up

- Clear-on-wheel. The red-phase file carried a `reportedWheelClearsSelection`
  test, dropped here with the plan's non-goal. A reported wheel tick still
  leaves a stale highlight over text it scrolled away, and closing that needs
  its own decision about fractional input and publication.
