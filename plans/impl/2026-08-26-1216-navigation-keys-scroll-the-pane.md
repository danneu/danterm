# fn+arrow scrolls the scrollback

## Context

On a Mac laptop there is no PageUp/PageDown/Home/End key. macOS synthesizes them
from `fn`+arrow: fn+Up arrives as keyCode 116 (`NSPageUpFunctionKey`), fn+Down as
121, fn+Left as 115 (Home), fn+Right as 119 (End). The `.function` flag is set,
but it is set for a real PageUp key on an external keyboard too, so `fn` is not
observable as a modifier. This feature is therefore "PageUp/PageDown/Home/End
scroll the pane", and fn+arrow follows for free.

DanTerm sends all four keys straight to the child, so today there is no keyboard
path to the scrollback at all -- only the wheel and the scrollbar.

macOS says all four keys scroll. `AppKit/StandardKeyBinding.dict` binds the
unmodified keys to `scrollPageUp:`, `scrollPageDown:`,
`scrollToBeginningOfDocument:`, `scrollToEndOfDocument:` -- every one a
`scroll*` selector that moves the viewport and leaves the insertion point alone.
Terminal.app follows this by deliberate omission: its `keyMappings.plist` maps
F704-F717, modified arrows, and F728 to escape sequences, and maps none of
F729/F72B/F72C/F72D, so all four fall through to those AppKit selectors.

macOS puts caret-to-line-start on Cmd+Left (`moveToLeftEndOfLine:`), not Home.
So the native design has two halves, and shipping only the first would take
line-start/line-end away without putting it anywhere:

1. PageUp/PageDown/Home/End scroll the local viewport.
2. Cmd+Left/Cmd+Right send the Home/End escape sequences to the child, so shell
   line editing keeps working under the key macOS actually assigns it.

Decisions already taken with the user: bare keys (no Shift requirement), all four
keys, both halves, and a fixed rule rather than rebindable commands -- `KeyChord`
requires at least one of cmd/ctrl/option, so a bare chord is unrepresentable and
making it configurable would mean widening the chord type for one binding.

## Design

The decision "does this navigation key scroll or reach the child" is the same
kind of decision `wheelRoute(for:terminal:)` already makes for the wheel, and it
gets the same shape: a pure routing function in `TerminalCore`
(`TerminalInteractionPolicy.swift`), interpreted by `TerminalPTYHost.applyKey`
next to the existing `applyWheel` call.

Deciding it in the shared host rather than in the AppKit view is the load-bearing
architectural choice, for three reasons:

- `applyKey` snaps the viewport to the bottom before every submission. A scroll
  routed around that snapping cannot be got wrong, because the snap lives on the
  branch that no longer runs.
- The CLI (`danterm pane input`) and the iOS client funnel through the same
  `applyKey`, so they behave identically to the keyboard without a second rule.
- The flight recorder already speaks a viewport-navigation vocabulary, so
  keyboard scrolls replay with no new tape vocabulary.

The route is its own vocabulary in `TerminalCore`; it does not reuse the
recorder's navigation enum, which lives in `TerminalCoreRecording` and is
unreachable from `TerminalCore` (Recording depends on Core, not the reverse).

### Routing contract

Evaluated in order, for a key and its modifiers against the live terminal:

| Condition | Route |
|---|---|
| Key is not PageUp / PageDown / Home / End | to the child |
| Shift, Control, or Alt held | to the child |
| Alternate screen active | to the child |
| PageUp | scroll back one window height |
| PageDown | scroll forward one window height |
| Home | scroll to the oldest retained row |
| End | resume following live output |

Notes that are contract, not detail:

- The modifier arm is the escape hatch for sending the real sequence, and it
  matches AppKit, where the shifted keys are `pageUpAndModifySelection:`, not
  scroll.
- Command is already byte-inert in the encoder and is not consulted, so a
  Command-only modifier still scrolls.
- A page is one full window height, matching Terminal.app -- no overlap row.
  Page size tracks the grid, so a resize changes it.
- The alternate-screen arm is belt-and-braces: the engine's scroll mutators are
  already no-ops there. It exists so the child still receives `ESC[5~` rather
  than the key being silently swallowed.

### Host invariants

- A scroll route must **not** record a key-input event to the flight tape.
  Recording input on a scroll would make replay send `ESC[5~` to the replica.
  The viewport navigation records itself, and only when the viewport moved.
- A scroll route completes the submission as delivered, like the existing
  empty-bytes path, so the input-wait bookkeeping stays balanced.
- The input route keeps its current behavior unchanged, snap-to-bottom included.

### Cmd+Left / Cmd+Right

`SwiftTerminalSessionView.keyDown` drops every Command-modified event to the menu
layer. Cmd+Left and Cmd+Right become an exception, delivering Home and End to the
child with the Command bit dropped and any Shift preserved. Adding Control or
Option falls back to the existing behavior, leaving those chords to the menu
layer.

All four consumed chords -- Cmd+Left, Cmd+Right, Cmd+Shift+Left, Cmd+Shift+Right
-- are reserved in the keybinding catalog. The reservation is what makes the
invariant hold: a menu key equivalent is dispatched before the pane's `keyDown`
runs, so an unreserved chord could be rebound and silently take line-start,
line-end, or their shifted forms away again.

`integrations/danterm/SKILL.md` must record that `pane input` with PgUp, PgDn,
Home, or End scrolls the pane on the normal screen instead of sending bytes.

## Tests

TDD, spec-first. Write each failing first and confirm the reason before fixing.

**Routing policy** (`lib/TerminalCore/Tests/TerminalCoreTests/TerminalInteractionPolicyTests.swift`)
-- the whole table, no AppKit:

- Each of the four keys, unmodified on the normal screen, routes to its row of
  the table above.
- Each of the four routes to the child when the alternate screen is active, and
  again when Shift, Control, or Alt is held.
- A Command-only modifier still scrolls.
- Keys outside the four -- an arrow, a function key, a character -- always route
  to the child, unmodified and on either screen.
- Page size tracks a resize: grow the grid, assert the scroll distance follows.

**Host behavior** (`lib/TerminalPTY/Tests/TerminalPTYHostTests/TerminalPTYHostTests.swift`)
-- observable end to end:

- PageUp with scrollback present moves the viewport back a page and writes no
  bytes to the child.
- Home reaches the oldest retained row; End resumes following.
- PageUp while the alternate screen is active writes `ESC[5~` and leaves the
  viewport alone.
- After a PageUp scroll, an ordinary character keypress snaps back to the bottom.
- A scroll records a viewport event and no input event on the flight tape, and
  replaying the tape reproduces the viewport without sending bytes.

**Keybinding reservations** (`lib/DanTermCore/Tests/DanTermCoreTests/KeybindingPreferencesTests.swift`):

- `effectiveBindings` rejects an override on each of Cmd+Left, Cmd+Right,
  Cmd+Shift+Left, and Cmd+Shift+Right, with a reserved-chord diagnostic.

**AppKit dispatch** (`tests-ui/SwiftTerminalSessionViewTests.swift`) -- these must
go through real dispatch, not a direct `keyDown` call. Mount the pane as the
window's first responder and post the events through `NSWindow.sendEvent`, so the
test exercises key-equivalent handling ahead of the responder chain and actually
proves the chords reach the view:

- Cmd+Left and Cmd+Right deliver Home and End with no Command modifier.
- Cmd+Shift+Left keeps Shift.
- Cmd+Ctrl+Left and Cmd+Opt+Left are not consumed by the pane.

## Non-goals and accepted risks

- **AR1.** A program running on the *normal* screen that reads PageUp/PageDown/
  Home/End stops receiving them unmodified. Accepted: this is the macOS platform
  binding and Terminal.app's behavior, the user chose bare keys over Shift-gating
  with that cost stated, essentially every full-screen program takes the
  alternate screen, and any modifier still sends the real sequence.
- **AR2.** Unix-style Home/End at the shell moves to Cmd+Left/Cmd+Right. Accepted:
  that is where macOS puts line-start/line-end, and the reserved chords keep it
  there.

## Implementation discretion

Names of the new route type and routing function, the shape of the branch in
`applyKey`, how the view recognizes the two Command chords, and the exact
diagnostic text for a reserved chord. None change observable behavior, an
invariant, or the layer boundaries above.

## Verification

1. Targeted suites for the packages touched, plus `just lint`, in the edit loop.
2. `just test` before the commit; `just test-ui` separately for the AppKit half.
3. Live check with `just launch-slot`:
   - `seq 1 500` in the pane, then fn+Up / fn+Down page through the scrollback and
     fn+Left / fn+Right jump to the ends; the scrollbar thumb tracks each one.
   - Type any character and confirm the viewport snaps back to live output.
   - `vim` and `less` (alternate screen): fn+Up/Down page the document and the
     pane does not scroll.
   - At the shell prompt, type a long line and confirm Cmd+Left / Cmd+Right move
     the caret to its ends.
4. Drive it headlessly to confirm the CLI path agrees: `danterm pane input` with
   PgUp leaves the pane browsing per `danterm pane info`, and End returns it to
   following.

## Implementation notes

- The keybinding reservation test went into
  `lib/DanTermCore/Tests/DanTermCoreTests/CommandCatalogTests.swift`, not
  `KeybindingPreferencesTests.swift` as the plan says: `effectiveBindings` and
  its sibling reserved-chord test (`nativeReservationConflict`) both live there.
- The AppKit test could not post its events through `NSWindow.sendEvent` alone.
  `sendEvent` does not offer a Command chord to the view hierarchy as a key
  equivalent -- `NSApplication` does that, and it is scoped to the key window,
  which the headless harness cannot produce. The test dispatches through a
  helper that models AppKit's real order instead: the window's
  `performKeyEquivalent` first, and only an unclaimed event on to `sendEvent`.
  That still proves what the plan asked for -- the chord is claimed ahead of the
  responder chain -- and the unclaimed cases prove `keyDown` does not take it
  either.
- The view claims the two chords in `performKeyEquivalent`, and only while it is
  its window's first responder, so an unfocused pane and a focused search field
  both leave the event alone. `keyDown`'s existing Command guard is untouched.
- The UI harness's fake controller now records each `sendKey` with its key and
  modifiers. The bytes it already recorded cannot show whether the Command bit
  was dropped, because Command is byte-inert in the encoder.
