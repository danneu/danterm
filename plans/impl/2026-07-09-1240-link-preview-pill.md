# Link preview pill (MOUSE_OVER_LINK)

## Context

When terminal output contains an OSC 8 hyperlink, the visible anchor text can
differ from the destination URL. Today DanTerm lets you Cmd-click to open the
link but gives no way to see the URL first. libghostty already solves the hard
part: on Cmd-hover it fires `GHOSTTY_ACTION_MOUSE_OVER_LINK` with the URL
(empty string when the pointer leaves the link or Cmd is released), fully gated
by the `link-previews` config (`true`/`false`/`osc8`, default `true`) and the
Cmd-held requirement (`.ghostty-src/src/Surface.zig:1614-1651`, `:4413`).
DanTerm currently drops the action at the `default:` case of
`GhosttyApp.handleAction` (`app/GhosttyApp.swift:520`).

Goal: mirror Ghostty's browser-style link preview -- a passive pill at the
bottom-left of the hovered pane showing the URL, which sits at the
bottom-right while the pointer is inside the pill's bottom-left region
(Safari/Chrome status-bar dodge), returns to the left when the pointer leaves
that region (all while the pointer remains over the link), and disappears on
empty URL. Reference implementation: upstream
`macos/Sources/Ghostty/Surface View/SurfaceView.swift:138-180` at v1.3.1
(SwiftUI; pruned from the local `.ghostty-src` clone).

## Design

View-only chrome: never saved, sent, or asserted, so per the inject-vs-ambient
rule it stays entirely in `app/`. No `Msg`, `Command`, `ViewLocalState`, core,
or reconciler changes. No config reads -- libghostty only sends the populated
action when a preview should show.

- **Dispatch**: new `GHOSTTY_ACTION_MOUSE_OVER_LINK` case in
  `GhosttyApp.handleAction`, placed after `GHOSTTY_ACTION_MOUSE_SHAPE`
  (`app/GhosttyApp.swift:317-320`, its sibling view-scoped pointer action).
  Copy the bytes into a `String` synchronously (the C pointer is only valid
  during the callback), then `withSurfaceView(target) { $0.setHoverUrl(url) }`
  (`app/GhosttyApp.swift:286-295`). Byte-parse mirrors the OPEN_URL case
  (`app/GhosttyApp.swift:503-506`); `len == 0` -> nil.
- **Host**: the pill is a lazily created subview of the persistent
  `TerminalView` (survives container rebuilds via `AppRuntime.surfaces`,
  `app/AppRuntime.swift:25`; only `tearDownSurface` destroys it). TerminalView
  is pinned to the scroll view's visible rect
  (`app/ScrollableTerminalView.swift` `synchronizeSurfaceView`), so a subview
  positioned in its bounds space stays glued to the visible bottom edge during
  scroll for free. Hidden, never removed, after first creation.
- **Pill**: new `LinkPreviewView` in its own file so the tests-ui harness can
  compile it standalone (the real TerminalView/GhosttyApp are shimmed out by
  `tests-ui/SidebarViewTestShim.swift`). Pure Cocoa; no GhosttyKit or
  TerminalView references.
- **Dodge**: `TerminalView.mouseMoved` (`app/TerminalView.swift:368-373`)
  already receives every pane mouse-move with `pos` in the pill's coordinate
  space (the `frame.height - pos.y` flip there is for the C API only -- do not
  "fix" it). One added line feeds the pill; the side decision is a stateless
  pure function so the harness can test it. Upstream parity (v1.3.1
  `SurfaceView.swift`: `.onHover` on the LEFT pill drives `isHoveringURLLeft`
  live): the pill shows on the right exactly while the pointer is inside the
  left pill's frame, and returns to the left when the pointer leaves that
  region. Keying the decision to the fixed left frame -- not the pill's
  current frame -- is also what prevents left/right oscillation.
- **No forwarding suppression over the pill**: `mouseMoved` keeps sending
  every position to libghostty unconditionally, exactly like upstream
  (`SurfaceView_AppKit.swift` `mouseMoved` has no pill guard). Consequence,
  also upstream/browser parity: moving the pointer off the link -- including
  onto the pill itself -- makes `mouseRefreshLinks` fire the empty-URL
  action (`.ghostty-src/src/Surface.zig:1636-1651`) and the pill hides. The
  dodge is therefore only observable when the hovered link itself lies
  inside the pill's bottom-left footprint, so the pointer stays on the link
  while crossing pill frames. Do NOT guard `ghostty_surface_mouse_pos` on
  pill regions: that would freeze cursor-shape and mouse-report positions
  whenever the pointer crosses a pane's bottom corners with a preview up,
  and would pin a stale pill on screen while the pointer is off-link. No
  flicker in the hide case: the empty-URL action and the local
  `pointerMoved` both land within the same event-loop pass, before the next
  display update.
- **Clear on pane exit**: libghostty treats a negative mouse position as
  "pointer left the viewport" and clears hover state itself, firing
  `.mouse_over_link` with an empty URL (`.ghostty-src/src/Surface.zig:4629-4655`).
  DanTerm never sends one today (only `mouseMoved`/`mouseDragged` forward
  positions), so a pointer leaving the pane directly from a hovered link
  would strand a visible pill and stale link state. Fix: mirror upstream's
  `mouseEntered`/`mouseExited` (`SurfaceView_AppKit.swift:954-996`, present
  in the pruned clone) -- see TerminalView integration below. The pill then
  hides via the normal empty-URL action round-trip; no separate local hide
  path.

### LinkPreviewView (new file `app/LinkPreviewView.swift`)

Ghostty-parity styling, not SearchOverlayView's HUD styling (this is passive
page chrome, not an interactive panel):

- `NSTextField(labelWithString:)` label, small system font, `.labelColor`,
  single line, `lineBreakMode = .byTruncatingMiddle`,
  `cell?.truncatesLastVisibleLine = true`. Non-private for tests
  (SearchOverlayView precedent).
- 5pt padding all sides; width capped at container width (long URLs truncate
  in the middle rather than overflow).
- Background: `wantsLayer = true`, `wantsUpdateLayer` + `updateLayer()` setting
  `NSColor.windowBackgroundColor.cgColor` (AppKit re-invokes on light/dark
  flips). No border, no shadow, no animation.
- Single-corner rounding, radius 9, via `layer?.maskedCorners`: only the
  inner-top corner is rounded. Non-flipped view, so top = MaxY: left side
  rounds `.layerMaxXMaxYCorner` (top-right), right side `.layerMinXMaxYCorner`
  (top-left). Edges touching pane borders stay square.
- `override func hitTest(_:) -> NSView? { nil }` -- the pill must never steal
  events from the terminal (`ProgressIndicatorView` precedent,
  `app/PaneWrapperView.swift:699`).

Pure helpers in the same file (harness-testable without a window):

```swift
enum LinkPreviewSide { case left, right }

/// Stateless: .right while the pointer is inside the LEFT pill's frame,
/// .left otherwise (mirrors Ghostty v1.3.1, where the left pill's live
/// `.onHover` drives the side). Keyed to the fixed left frame regardless of
/// where the pill currently sits, so it cannot oscillate.
func linkPreviewDodgeSide(pointer: NSPoint,
                          leftPillFrame: NSRect) -> LinkPreviewSide

/// Bottom-left or bottom-right anchor, width capped at container width.
func linkPreviewFrame(side: LinkPreviewSide, fittingSize: NSSize,
                      containerWidth: CGFloat) -> NSRect
```

Class API:

- `show(url:)` -- set text, unhide. Side is not sticky state: every
  `pointerMoved` (and the immediate dodge in `setHoverUrl`) rederives it from
  the pointer and the left frame.
- `hide()` -- hide.
- `layoutPill(in bounds: NSRect)` -- manual frames, no autolayout (frame math
  stays a pure function; host frame is manually mutated on every scroll tick).
- `pointerMoved(to point: NSPoint, in bounds: NSRect)` -- computes the left
  frame via `linkPreviewFrame(.left, ...)`, applies `linkPreviewDodgeSide`;
  on change re-lays-out. No-op when hidden.

### TerminalView integration (`app/TerminalView.swift`)

- `private var linkPreview: LinkPreviewView?` -- lazily created, owned here so
  it survives container rebuilds.
- `func setHoverUrl(_ url: String?)` -- nil hides; otherwise create-on-first-use,
  `show`, `layoutPill(in: bounds)`, then one immediate dodge using
  `window?.mouseLocationOutsideOfEventStream` converted to view coords (covers
  the pill appearing under a stationary pointer -- Cmd pressed with the mouse
  already resting bottom-left -- where no mouseMoved will fire).
- One line in `mouseMoved` after `ghostty_surface_mouse_pos`:
  `linkPreview?.pointerMoved(to: pos, in: bounds)`.
- One line in `setFrameSize` (`app/TerminalView.swift:232-235`) after
  `syncSurfaceGeometry`: `linkPreview?.layoutPill(in: bounds)`.
- `override func mouseExited(with event: NSEvent)` (new) -- mirrors upstream
  `SurfaceView_AppKit.swift:976-996`: return early if
  `NSEvent.pressedMouseButtons != 0` (drags keep delivering `mouseDragged`
  outside the view, so no clear is needed), else
  `ghostty_surface_mouse_pos(surface, -1, -1, mods)` with
  `Self.ghosttyMods(event.modifierFlags)`. libghostty responds by clearing
  its hover state and firing the empty-URL `.mouse_over_link`, which hides
  the pill through the existing `setHoverUrl(nil)` path -- one clear path, no
  direct local hide.
- `override func mouseEntered(with event: NSEvent)` (new) -- mirrors upstream
  `SurfaceView_AppKit.swift:954-973`: forward the current position + mods.
  Upstream marks this as load-bearing: after the `-1,-1` exit, mouse-report
  logic depends on the position being back in the viewport.
- No tracking-area change: `updateTrackingAreas` already requests
  `.mouseEnteredAndExited` (`app/TerminalView.swift:242`); only the overrides
  are missing today.

### GhosttyApp wiring (`app/GhosttyApp.swift`)

```swift
case GHOSTTY_ACTION_MOUSE_OVER_LINK:
    // Empty URL = pointer left the link or Cmd released. libghostty already
    // gates on Cmd-hover and the link-previews config.
    let v = action.action.mouse_over_link
    var url: String?
    if v.len > 0, let ptr = v.url {
        url = String(data: Data(bytes: ptr, count: Int(v.len)), encoding: .utf8)
    }
    let hoverUrl = url
    withSurfaceView(target) { $0.setHoverUrl(hoverUrl) }
    return true
```

## Tests (TDD order)

New `tests-ui/LinkPreviewViewTests.swift` with `func linkPreviewViewTests()`
using `uiTest`/`uiExpect` (mimic `tests-ui/PaneWrapperViewTests.swift`).
Most are trivial spec-first: descriptive titles, no preamble; test 3 earns
one (pins the upstream-parity dodge region: the decision is keyed to the
fixed LEFT frame, not the pill's current frame, so hovering the right-side
pill sends the preview back left instead of oscillating).

1. dodge: pointer inside the left pill's frame -> .right
2. dodge: pointer outside the left pill's frame -> .left
3. dodge: region is the left frame regardless of current side -- a pointer
   over the right pill's frame (outside the left frame) still yields .left
4. frame: left side anchors at origin (0,0)
5. frame: right side anchors at bottom-right (maxX == containerWidth, y == 0)
6. frame: width capped at container width for long URLs
7. show unhides and displays the URL; hide hides
8. integration: pointerMoved out of the left region moves the frame back to
   bottom-left (flip-back companion to test 12)
9. hitTest returns nil at every point
10. label truncates middle on a single line
11. maskedCorners: left rounds only top-right; right rounds only top-left
12. integration: pointerMoved into the left region moves the frame to
    bottom-right

The GhosttyApp case and TerminalView glue stay manual-QA, consistent with all
existing action handling (the harness shims both files). The
TerminalView/libghostty interaction -- hover clearing when the pointer moves
off the link onto the pill -- is covered by manual QA step 2.

## File-by-file changes (ordered)

1. `tests-ui/LinkPreviewViewTests.swift` (new) -- the 12 tests.
2. `app/LinkPreviewView.swift` (new) -- skeleton first (enum + stub pure
   functions + no-op class) so the harness compiles and tests fail on
   assertions, not compile errors.
3. `test-ui.sh` -- add `app/LinkPreviewView.swift` to the app section (near
   `SearchOverlayView.swift`) and the test file to the tests block.
4. `tests-ui/PaneSplitViewTests.swift` -- register `linkPreviewViewTests()` in
   `UITestRunner.main`. Run `just test-ui`; new tests fail for the expected
   reason.
5. `app/LinkPreviewView.swift` -- real implementation; `just test-ui` green.
6. `app/TerminalView.swift` -- property, `setHoverUrl`, mouseMoved +
   setFrameSize hooks, mouseEntered/mouseExited overrides.
7. `app/GhosttyApp.swift` -- the action case.

## Verification

- `just test-ui` -- new suite green, existing suites unaffected.
- `just test` -- stays green (nothing outside `app/` + `tests-ui/` changes;
  core purity lint untouched).
- Manual QA (`just build-run`):
  1. `printf '\e]8;;https://example.com/some/very/long/path/to/truncate\e\\click me\e]8;;\e\\\n'`
     then Cmd-hover "click me": pill bottom-left, windowBackgroundColor fill,
     only top-right corner rounded, URL middle-truncated in a narrow pane.
  2. Dodge (needs the link inside the pill's footprint): print the link so
     it sits on the bottom rows (just above the prompt, short pane), then
     Cmd-hover it there: pill appears at bottom-right instead of covering
     the link (top-left corner rounded). Move along the link out of the
     pill's bottom-left footprint: pill returns to bottom-left. Move the
     pointer off the link onto the pill itself: pill disappears -- leaving
     the link clears hover (upstream/browser parity) -- with no intermediate
     flicker.
  3. Release Cmd / move off the link: pill disappears. Re-hover: back at
     bottom-left.
  4. While Cmd-hovering a link, move the pointer straight out of the pane
     without leaving the link first -- across a split divider into a sibling
     pane, and separately out the window edge: pill disappears immediately
     (mouseExited -> `-1,-1` -> empty-URL action). Re-enter the pane: no
     stale pill until a link is hovered again, and mouse-dependent behavior
     (selection, mouse reports) still works after re-entry.
  5. `echo https://example.com` -- Cmd-hover the plain URL: pill shows it
     (regex link path).
  6. Scroll while hovering, split, resize divider/window, zoom: pill stays
     glued to the visible bottom edge, clipped to its own pane.
  7. Toggle dark/light mode with the pill visible: background follows.
  8. Sanity: Cmd-click still opens (OPEN_URL untouched); focus border still
     renders; typing/IME/selection unaffected. Drag a selection out of the
     pane and back: no mid-drag clear (mouseExited returns early while a
     button is down).
  9. Optional: `link-previews = osc8` in ~/.config/ghostty/config -- plain-URL
     hover shows no pill, OSC 8 hover does (gating is upstream; no DanTerm
     code involved).

## Risks

1. **Subviews on a layer-hosting view** (main risk). TerminalView is
   layer-hosting (Ghostty assigns its IOSurfaceLayer to `.layer`; see comment
   at `app/TerminalView.swift:218`). Apple advises against subviews on
   layer-hosting views, but AppKit composites layer-backed subviews above the
   hosted layer, Ghostty never touches sublayers, and DanTerm already mutates
   this layer directly (`setFocusBorder`, `app/TerminalView.swift:669-681`).
   Validate first in manual QA (step 1) before polish. Fallback if the pill
   does not composite: host it in `ScrollableTerminalView` above the scroll
   view, keep the hover state on TerminalView, and re-show at wrapper init via
   the existing cached-state re-sync pattern.
2. **Focus border overlap**: the 2pt border paints over the pill's bottom/left
   2pt (CALayer borders composite above sublayers). Ghostty has the same
   overlap; accept unless QA looks bad.
3. **Coordinate space**: `mouseMoved`'s `pos` and the pill frame share
   TerminalView's non-flipped bounds space. The y-flip at
   `app/TerminalView.swift:372` is for the C API only.

## Follow Up

- Run the manual QA checklist in `plans/impl/2026-07-09-1240-link-preview-pill.md`, especially layer-hosted pill compositing, dodge behavior, and pane-exit clearing in a live DanTerm window.
