# Pane focus ring gets its own gutter

## Context

Every pane draws a 2pt ring around its terminal area: green when the pane is
the focused one in a split, red when it has unacknowledged alerts. Today that
ring is a `CALayer` border on `SwiftTerminalSessionView` itself
(`app/SwiftTerminalSessionView.swift#setFocusBorder`), and a layer border draws
*inward* from the layer's bounds. The terminal grid surface starts at the very
same bounds origin, so the ring paints over the outermost 2pt of glyphs on all
four sides.

The fix is to reserve space for the ring instead of stealing it from content: a
permanent gutter, the same width as the ring, on all four sides of the terminal
area. The gutter is always present -- it does not appear and disappear with
focus -- so a pane's grid geometry never shifts when focus moves.

Decisions already made with the user:

- Gutter is **2pt**, matching the existing 2pt ring, so the ring sits entirely
  inside the gutter and never touches a glyph.
- When no ring is showing, the gutter paints the **terminal theme's default
  background**, so it reads as invisible padding rather than as a frame around
  each pane.

## Contract

- **I1.** The ring's width and the reserved gutter's width are one number, not
  two that happen to agree. A `CALayer` border draws inward from its bounds, so
  a gutter narrower than the ring puts the ring back on top of glyphs.
- **I2.** The gutter is present whether or not a ring is showing, on all four
  sides of the terminal area. Focus and alert changes never move a glyph.
- **I3.** The terminal grid keeps a `(0, 0)` local origin inside
  `SwiftTerminalSessionView`. The gutter is taken out of that view's *frame*,
  never out of the space inside it.
- **I4.** The gutter paints the pane's current terminal background -- from the
  moment the pane appears, not only after the first theme change.
- **I5.** Ring colors and their precedence are unchanged: focused is green,
  alerted-and-unfocused is red, otherwise no ring. Focus wins when both hold.

## Approach

Shrink the terminal view rather than move content inside it.

`ScrollableTerminalView` (`app/ScrollableTerminalView.swift`) already owns the
frame math for the pane's terminal area (`layout()` sets
`scrollView.frame = bounds` and `hostView.frame.size = scrollView.bounds.size`)
and already observes session state as `TerminalSessionStateObserver`. It becomes
the owner of the gutter, the ring, and the gutter's background color. The
terminal view keeps its bounds origin at `(0,0)`; it simply gets a smaller
frame.

I3 is what makes the change safe. Everything that converts points to cells --
`normalizedCell(at:)`, `pointerIsOutsideGrid(_:)`, `showPaneMenu(at:)`,
`firstRect(forCharacterRange:)`, `terminalGridDimensions(size:cellSize:)`, the
scrollbar padding term in `ScrollbarMath.swift`, and the benchmark's window-size
delta math -- assumes the grid starts at the view's origin. Shrinking the view
keeps every one of those assumptions true with no edit.

### Ownership

The ring is pane chrome, so it is driven like the rest of the pane chrome.
`PaneHost` (`app/PaneHost.swift#PaneHost`) keeps the session and its
`PaneWrapperView` alive together across container tree edits, and
`findPaneWrapper(for:)` resolves the wrapper through that host rather than
through whichever container currently parents it. `reconcileContainers()` runs
before `reconcileFocusBorders()`, so the wrapper is always in place when the
ring is pushed.

So `reconcileFocusBorders` applies its `BorderState` through
`findPaneWrapper(for:)` -- the same route `reconcilePaneToolbars` and the search
overlay reconcilers already take -- and the wrapper hands it to the scroll
wrapper it built. `TerminalSession.setFocusBorder` and its implementation go
away entirely; the terminal session stops carrying pane chrome it does not own.

### Theme propagation

The gutter is outside the terminal view, so it no longer inherits that view's
theme-colored layer background. The pane's current background has to reach the
gutter's owner both at construction and on every subsequent theme change; the
session-state channel `ScrollableTerminalView` already observes is the natural
carrier, which means the state a theme change produces has to reach observers
(today a theme swap emits nothing). The terminal view keeps painting its own
layer background -- that still fills the sub-cell letterbox strip inside the
grid area.

## Rejected ideas

- **Inset the content inside the terminal view** (grid surface moved to a
  sublayer at an inset frame, host layer full-size). Gets the theme-colored
  gutter for free, but violates I3: it moves the grid origin off `(0, 0)` and
  requires editing every point-to-cell consumer listed above. An off-by-one
  there shows up as mis-hit selections and link hovers at the pane edges -- a
  subtle failure mode the frame-shrinking approach cannot produce.

## Implementation discretion

- Where the shared width constant lives and how it is spelled.
- How the wrapper exposes the ring to `Reconcile`, and how the background color
  is carried on the session-state channel.
- Whether the point-to-`CGColor` conversion is shared or re-derived.

## Files

`app/ScrollableTerminalView.swift` (gutter inset, ring, gutter background),
`app/SwiftTerminalSessionView.swift` (drop `setFocusBorder`, publish the
background on state and on theme change), `app/TerminalSession.swift` (state
carries the background; the ring leaves the protocol), `app/PaneWrapperView.swift`
(retain the scroll wrapper, expose the ring), `app/Reconcile.swift` (route
through `findPaneWrapper`), plus `test-ui.sh`, the UI runner, and the test shims
that stand in for `ScrollableTerminalView` or implement `setFocusBorder`.

No changes to `lib/` -- `terminalGridDimensions` and `ScrollbarMath` keep their
current meanings.

## Tests

### Harness promotion

Every invariant here is a fact about the production `ScrollableTerminalView`, so
the tests have to run against that file and not a stand-in. Today they cannot:
`tests-ui/SidebarViewTestShim.swift` declares a no-op `ScrollableTerminalView`
that substitutes for the real one in the whole-module UI harness, so a wrapper
built in a test has a bare `NSView` where the gutter, ring, and background live.
Tests written against it would pass while the shipped view has no gutter at all.

The change therefore includes promoting the real view into the harness --
deleting the shim declaration, adding the view and the `ScrollbarMath` functions
it calls to `test-ui.sh`'s source list, and calling the new suite from the UI
runner, which invokes each suite function explicitly rather than discovering it.
Promotion is the documented price of the harness's substitution seam
([docs/design/2026-08-06-ui-harness-whole-module-substitution.md](../../docs/design/2026-08-06-ui-harness-whole-module-substitution.md)).
Confirm it by watching a new test fail for the intended reason before the
production change lands; a suite that is silently never compiled or never
invoked also "passes".

### Cases

New UI test file, in the style of `tests-ui/PaneWrapperViewTests.swift`, driven
through a real pane wrapper over the existing session test shim. Written first,
confirmed failing, then made to pass. Each item names the invariant it proves:

1. **I2 -- gutter is reserved unconditionally.** After layout at a known size,
   the scroll view's frame is inset on all four sides and the terminal host's
   size matches it, asserted with the ring *off*.
2. **I2/I3 -- grid shrinks by the gutter and holds still.** The dimensions the
   session receives correspond to the bounds minus the gutter on both axes, and
   do not change when focus is toggled on and off.
3. **I1 -- the ring cannot overlap content.** With the ring on, the drawn border
   width does not exceed the reserved gutter. This is the invariant the whole
   change exists for, and it is the test that fails if someone later changes one
   of the two numbers without the other.
4. **I5 -- state maps to the right ring.** Focused, alerted-unfocused, idle, and
   focused-and-alerted map to green, red, none, and green. The terminal view's
   own layer carries no border in any of the four.
5. **I4 -- gutter is themed from the start.** The gutter's color matches the
   session's initial default background before any theme change, and matches the
   new theme's default background after one.

## Implementation notes

- The gutter, the ring, and the gutter's background all live on
  `ScrollableTerminalView`'s **own** layer rather than on a separate ring
  subview. Its bounds are the full pane area and the scroll view is inset by
  `focusRingWidth`, so a layer border drawing inward lands exactly on the
  reserved strip. That makes I1 structural: one view, one width, and no second
  frame to keep in sync.
- `TerminalSessionState.background` is a `CGColor`, not the engine's
  `RenderColor`. `app/TerminalSession.swift` also compiles in the UI harness,
  where `TerminalRenderPlanning` does not exist, so the state type cannot name
  an engine color. `SwiftTerminalSessionView` converts once, at the same seam
  that already colors its own layer.
- `PaneWrapperView` exposes two members for the scroll wrapper: `setFocusRing`
  is the chrome route the reconciler takes (matching `updateToolbar` and the
  search overlay), and `scrollWrapper` is what the gutter tests measure
  geometry through. Each has its own caller; neither stands in for the other.
- I4's two halves are pinned in two suites, because they are facts about two
  different files: the new `ScrollableTerminalViewTests` covers the gutter
  taking its color from the state channel at construction and afterwards, and
  `SwiftTerminalSessionViewTests` covers `state.background` being the current
  theme's and `applyTheme` publishing at all (a theme swap previously emitted
  nothing).
- The stale `TerminalView.setFocusBorder` reference in
  `Projections.swift#BorderState` was corrected. The plan's "no changes to
  `lib/`" is about behavior; leaving a comment pointing at a deleted method
  would have been worse.
