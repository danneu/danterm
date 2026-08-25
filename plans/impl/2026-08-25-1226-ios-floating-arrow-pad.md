# iOS per-pane floating arrow pad

## Problem

The iOS bottom bar gives four narrow slots to the arrow keys. Those keys are
harder to hit than the terminal navigation they serve warrants, and they take
space from every other accessory key even when the user does not need them.

The desired result is one bottom-bar toggle that reveals a larger 2x2 arrow
pad over the terminal. The user can move the pad away from pane-specific TUI
content, and a terminal tap can dismiss it without losing the tap's normal
focus behavior.

Load-bearing premises verified in the current tree and UIKit documentation:

- `MobileAccessoryKey` and `MobileInputMapper` already carry all four arrow
  meanings through the owner-side input path. This is a presentation change,
  not a new input or wire capability.
- The selected `PaneId` is already part of `MobileSessionProjection`, so local
  pad state can follow pane identity without deriving identity in UIKit.
- UIKit's standard buttons provide press states and accessibility, and Apple
  recommends at least a 44x44pt hit region for iOS controls
  ([Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)).
- A pan recognizer attached to a control can win once movement becomes a drag,
  while an ordinary tap remains the control action
  ([Attaching gesture recognizers to UIKit controls](https://developer.apple.com/documentation/uikit/attaching-gesture-recognizers-to-uikit-controls),
  [Handling pan gestures](https://developer.apple.com/documentation/uikit/handling-pan-gestures)).
- The app targets iOS 26, whose standard button configurations include Liquid
  Glass for floating controls
  ([Build a UIKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/284/?time=1044)).

## Decision

Replace the bottom bar's four arrow buttons with one arrow-pad toggle. The
accessory enum stays the full key vocabulary, including all four arrows, because
the pad routes through those same cases. The bar stops building its row from
`allCases` and takes an explicit ordered row list that omits the arrows; that
type's doc comment changes in the same commit. The toggle shows this fixed
directional order:

```text
[ Up   ] [ Down  ]
[ Left ] [ Right ]
```

The pad is floating UIKit chrome made from standard glass buttons. Each button
has at least a 44x44pt hit region and sends the existing accessory-key action.
The pad stays open after an arrow tap.

Visibility and preferred position are pure, per-pane presentation state in
`DanTermMobileKit`. A pane starts with the pad hidden and its preferred
position at bottom-trailing. A toggle, terminal dismissal, or completed drag
updates only that pane. State is keyed by `PaneId`, which is a UUID and is
never reused, and it is never pruned: it lasts for the app run, so surviving a
temporary disconnect needs no rule. Only the selected pane's entry is ever read,
so an entry for a pane that is gone is unobservable.

Position is stored in normalized terminal coordinates. UIKit owns only the
in-progress drag. When a drag ends, it commits the position for the pane on
which the drag began, so a concurrent pane change cannot write to the wrong
pane. Rotation and keyboard movement resolve the preferred position again
rather than replacing it with a temporary clamp.

The pad is a sibling layered above `TerminalInputView`, never inside its
subtree. That view carries the scroll pan recognizer as well as tap-to-focus and
long-press, so a pad inside it would give its own drag and taps to those
recognizers too.

Only a tap on the terminal surface dismisses the pad. The same tap continues
through the existing terminal focus path. Bottom-bar actions, sheets,
scrolling, long-press, and arrow-pad gestures do not dismiss it. The toggle
still hides it directly.

## Invariants

- **I1 -- Input identity.** Every floating arrow tap reaches the same
  `MobileAccessoryKey` mapping, modifier-latch behavior, and owner-side
  encoding as the arrow button it replaces. Dragging sends no arrow.
- **I2 -- Pane ownership.** Each pane independently owns visibility and
  preferred position. Switching away and back restores both, and an event for
  one pane cannot alter another pane's state.
- **I3 -- Focus and dismissal.** A terminal tap hides the current pane's pad
  and still performs normal terminal focus behavior. No other outside gesture
  hides it implicitly.
- **I4 -- Stable placement.** The displayed pad remains inside the visible safe
  terminal region, below the status pill and above the keyboard-riding bottom
  bar. Rotation and keyboard changes never overwrite the saved preferred
  position.
- **I5 -- Native control behavior.** The four directions remain separate
  standard buttons with visible press states, 44pt-or-larger hit regions, and
  useful accessibility labels. The toggle exposes shown/hidden state.
- **I6 -- Accessible movement.** Assistive-technology users can move a visible
  pad among the four corners without performing the touch drag, using UIKit
  accessibility actions
  ([UIAccessibilityCustomAction](https://developer.apple.com/documentation/uikit/uiaccessibilitycustomaction)).

## Proof obligations

- **PO1 (I1).** Existing and new mapper/model tests prove all four directions
  produce the established input and consume a modifier latch once, and that the
  bar's row list omits the arrows while the mapper still maps all four. Live
  verification proves a drag sends nothing: latch Ctrl, drag from each of the
  four buttons, and confirm the pane receives no input and the latch is still
  armed.
- **PO2 (I2).** Pure model tests prove independent defaults, toggle, dismissal,
  movement, and pane switching. One scenario starts a drag on pane A, switches
  the selection to B, and ends the drag: A's position changes and B's does not.
- **PO3 (I3).** Live iOS verification proves one terminal tap both dismisses
  and focuses, while scrolling, long-press, bottom-bar actions, sheets, and
  arrow taps leave visibility unchanged. Dragging the pad does not scroll the
  terminal.
- **PO4 (I4).** Pure placement tests prove normalized restoration and safe
  clamping across portrait, landscape, and keyboard-visible rectangles. Live
  verification proves the pad does not cover the status pill or bottom bar.
- **PO5 (I5-I6).** Live verification with VoiceOver proves direction labels,
  toggle state, focus order, corner movement actions, press feedback, and hit
  targets. Verify Reduce Motion behavior as part of the same pass.

Run the targeted `DanTermMobileKit` suite and `just lint` during the TDD loop,
build and exercise the iOS app on a simulator or device, then run `just test`
before commit.

## Non-goals

- No press-and-hold repeat, edge snapping, or position persistence across app
  launches.
- No input-protocol, wire-format, terminal-engine, or macOS behavior change.
- No implementation of the planned jump-to-bottom pill. When that pill lands,
  its placement must avoid a visible arrow pad rather than claim the same
  bottom-trailing space.

## Rejected ideas

- **RI1 -- Keep four arrows in the bottom bar.** This preserves the small hit
  targets and permanent width cost that the feature exists to remove.
- **RI2 -- Store placement only in the view controller.** That makes
  pane-specific restore and lifecycle policy unproved mutable UIKit state,
  contrary to the app's pure model/update boundary.
- **RI3 -- Add a full-screen dismissal layer.** It would compete with terminal
  focus, selection, and scrolling. The terminal's existing tap path already
  provides the exact dismissal boundary.
- **RI4 -- Prune pad state when a pane leaves.** Nothing observable depends on
  it: entries are tiny, `PaneId` is never reused, and only the selected pane's
  entry is read, so pruning would only add a rule that fights the session
  model's refusal to treat a roster as news about the streamed pane.
- **RI5 -- Use drag-and-drop APIs.** The gesture repositions local chrome; it
  does not transfer content. A pan recognizer states that behavior directly.

## Implementation discretion

- Exact button dimensions above the 44pt minimum, spacing, symbols, margins,
  and show/hide animation.
- Internal type and file names, provided the pure per-pane ownership and UIKit
  translation boundary remain intact.

## Commit progress
- [x] 1. feat(ios): own arrow-pad placement as pure per-pane state
- [x] 2. feat(ios): float the arrow pad over the terminal

## Implementation notes

- The pad's state is a pure value type the shell holds, not a case in
  `MobileSessionEvent`. That enum's own header says a view's local decision --
  raising a keyboard, a scroll position inside a sheet -- is not a session
  fact, and pad visibility is exactly that. RI2 is still honored: the state and
  its placement arithmetic are pure and tested in `DanTermMobileKit`, and the
  view controller only holds the value and translates for UIKit.
- Position is stored as the pad's share of the *free* space the region leaves
  around it, not as a fraction of the region itself. Resolving is then exact in
  both directions and a region smaller than the pad clamps to an edge with no
  special case.
- `MobileArrowPadPlacement` reports leading and top insets rather than a frame,
  so the layout stays a leading/top constraint pair and UIKit mirrors it for a
  right-to-left interface without the pure model knowing about interface
  direction.
- The pad is built from a private four-case direction enum rather than from
  `MobileAccessoryKey`, so a key that is not a direction cannot reach a pad
  button. That is what the bottom row's appearance type gets from having no
  `default`, stated as a type instead of as a switch.
- The pad is inserted directly above the terminal's input view, which leaves
  the bottom bar and the status pill above it in z-order. In a region too
  short for the pad -- landscape with the keyboard up -- the pad slides under
  the opaque bar instead of covering it, so I4 holds even where no placement
  could fit.
- Show and hide resolve the placement directly instead of calling
  `setNeedsLayout`. The redraw path runs on every published frame, and one
  layout pass per frame would sit behind the terminal's output.

## Follow Up

- Run the remaining live obligations the plan names and this change could not
  prove in a test: PO1's drag-sends-nothing check (latch Ctrl, drag from each
  of the four buttons, confirm the pane received no input and the latch is
  still armed), and PO5's VoiceOver and Reduce Motion pass over the direction
  labels, the toggle's shown state, focus order, and the four corner
  movement actions. The iOS app package has no test target, so these have no
  other proof.
- When the planned jump-to-bottom pill lands, its placement must avoid a
  visible arrow pad rather than claim the same bottom-trailing space
  (`MobileRootViewController.arrowPadRegion`).
