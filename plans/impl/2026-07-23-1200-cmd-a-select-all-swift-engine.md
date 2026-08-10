# Cmd-A selects the whole stream in the Swift engine

## Context

Edit > Select All (`app/AppDelegate.swift:281`) is a nil-targeted item wired to
`NSResponder.selectAll(_:)`. Nothing in the responder chain implements it, so
AppKit disables the item and declines its Cmd-A key equivalent in both backends.
This is the same defect just fixed for Cmd-C: the shortcut was never DanTerm's,
and the Swift pane's `keyDown` Command guard means an unclaimed chord is simply
dropped.

Unlike the other gaps found in that audit, this one is not an engine feature
gap. `Terminal.setSelection(_ range:)` already clamps both endpoints into the
live stream, so whole-buffer selection is expressible today with no new
selection machinery -- only the plumbing from the responder chain down to the
terminal owner is missing.

Outcome: pressing Cmd-A in a Swift-engine pane selects the entire retained
stream -- scrollback through viewport, matching Ghostty and Terminal.app -- so
the existing Cmd-C path can copy it.

## Direction

Extend the existing selection plumbing rather than introducing a parallel path.
The mutation travels the same route as pointer-driven selection and
`clearSelection()`: a terminal-value mutation, enqueued on the terminal owner's
FIFO, exposed on the session controller, invoked from a responder-chain method
on the pane view.

Critical files, outermost in:

- `app/SwiftTerminalSessionView.swift` -- `selectAll(_:)` responder method
  (an `NSResponder` override, unlike `copy(_:)`).
- `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift`
- `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`
- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`

## Invariants

- Selecting all covers the whole retained stream, not the viewport: the
  resulting selected text equals the terminal's full-history projection.
- Whole-stream extent is computed inside the terminal value. No caller outside
  `TerminalCore` derives stream bounds to build the range.
- Select-all on an empty or blank buffer is well-defined and does not trap.
- The mutation is ordered against pointer input and output on the terminal
  owner's existing serialization, and republishes only when the terminal value
  actually changed.
- `keyDown` gains no Command-key branch; Cmd-A is owned entirely by the menu
  and responder chain.
- Existing menu validation is unchanged: Select All is enabled whenever a
  Swift pane is first responder, and Copy's selection-dependent validation
  still applies only to Copy.

## Non-goals

- The libghostty `TerminalView` backend. It matches `super+a` internally; this
  plan does not alter its behavior.
- Any other unclaimed Ghostty default bind from the prior audit (search,
  font size, `clear_screen`, prompt jumps). Those are engine feature gaps.
- Auto-scrolling the viewport to reveal the selection.

## Accepted risks

- Claiming Cmd-A means the chord can never reach the line editor as `\x01`.
  Accepted: it costs nothing today (the Command guard already drops it), Ctrl-A
  is unaffected, and it matches every mainstream macOS terminal.

## Verification

Behavioral proofs, TDD-first:

1. Whole-stream extent -- with content evicted into scrollback, select-all's
   text equals the full-history projection, and the selection starts at the
   first retained row. Discharges the first two invariants.
2. Empty/blank buffer -- select-all on a fresh terminal selects the empty
   full-history projection: selected text equals `fullHistoryText` and a
   selection is present, rather than the terminal being left unselected. This
   distinction is load-bearing because selection presence drives `hasSelection`
   and therefore Copy enablement.
3. Responder-chain ownership -- with the pane as first responder, the
   nil-targeted `selectAll(_:)` action dispatched through AppKit's
   responder-chain lookup (not by calling the method on the pane directly)
   reaches the pane, produces a selection the pane reports, and leaves
   Edit > Select All validating as enabled. Dispatching through the chain is
   the point: a direct call would pass even if the menu item stayed disabled
   or the action resolved to another responder.
4. No input leak -- Cmd-A on a mounted pane sends no bytes to the shell.
   Guards the `keyDown` invariant against a regression that re-adds a Command
   branch.

Proofs 1-2 belong with the existing core selection suite; 3-4 with the pane's
UI-harness suite (`just test-ui`, which needs a WindowServer and is excluded
from `just test`).

End-to-end: `just build-run`, produce more output than one screen, press Cmd-A
then Cmd-C, and paste elsewhere to confirm the scrollback came through.
Confirm Edit > Select All is no longer greyed out.

## Implementation notes

- Proof 3's responder-chain dispatch uses a child `FirstResponderProbeView`
  (whose `nextResponder` is the pane) and `probe.tryToPerform(selectAll:)`
  rather than `NSApp.sendAction(_:to:nil:)`. The latter resolves the target
  through the key window's first responder, and the UI harness has no active
  key window headless, so it returned false; dispatching from a child up the
  chain proves the same "resolves to the pane, not a direct call" property
  without depending on app activation.
- Proof 4 extends the existing "Command-modified keys produce no terminal
  input" UI test with a Cmd-A `keyDown` alongside the existing Cmd-C, rather
  than adding a separate test -- both guard the identical `keyDown` Command
  branch and share one scenario.
