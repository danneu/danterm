# Disable implicit CA animation on TerminalView's contentsScale update

## Context

`TerminalView` hosts a Ghostty surface. Ghostty's Metal renderer makes the
view *layer-hosting*: it assigns its own `IOSurfaceLayer` to the view's
`.layer` and only then sets `wantsLayer = true`
(`.ghostty-src/src/renderer/Metal.zig:108-126`).

AppKit auto-suppresses Core Animation's implicit actions only for
layer-*backed* views (where AppKit creates the layer). On a layer-*hosting*
view, the layer behaves like a standalone `CALayer`, so a write to an
animatable property can trigger a default implicit animation.

`app/TerminalView.swift:198` writes `layer?.contentsScale = window.backingScaleFactor`
bare in `viewDidChangeBackingProperties` (fires when the window moves between
displays of different backing scale, or DPI changes). Ghostty guards this exact
write with a disabled-actions `CATransaction` and documents the rationale -- an
implicit scale animation on the layer contents "looks pretty janky"
(`SurfaceView_AppKit.swift:826-845`); cmux does the same
(`GhosttyTerminalView.swift:3619-3622`). DanTerm is missing this guard.

This is a verified gap against the upstream we build on: the same code path,
same layer-hosting setup, with a documented reason for the guard. (We have not
independently reproduced the visual artifact; the justification is parity with
Ghostty's documented idiom, and the change is the exact low-risk reference
pattern.) Outcome: the backing-scale update matches Ghostty's guarded behavior.

## Approach

Inline the `CATransaction.begin()` / `setDisableActions(true)` / `commit()`
wrap around the single `contentsScale` write, exactly as Ghostty and cmux do.
One call site does not warrant a shared helper.

Wrap only the `contentsScale` write. Leave the following
`ghostty_surface_set_content_scale` / `ghostty_surface_set_size` calls outside
the transaction -- they are C calls into Ghostty, not CALayer mutations (matches
Ghostty's reference, which wraps only the layer write).

## Out of scope (possible follow-up)

`setFocusBorder` (`app/TerminalView.swift:641-653`) also mutates this hosted
layer (`borderWidth` / `borderColor`) bare, so it is theoretically the same
class of issue. It is deliberately **not** changed here: no focus-ring
fade/lag is currently observed. If a concrete, reproducible symptom appears
later, handle it as a separate follow-up tied to that symptom.

## Changes

In `app/TerminalView.swift`, `viewDidChangeBackingProperties` (around 196-199):

```swift
// Update layer's contentsScale. The view is layer-hosting (Ghostty assigns
// its IOSurfaceLayer to .layer), so AppKit does not suppress Core Animation's
// implicit actions for us. Wrap the write to avoid an implicit scale animation
// on backing-scale changes. Matches Ghostty (SurfaceView_AppKit.swift:838-844).
if let window = window {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.contentsScale = window.backingScaleFactor
    CATransaction.commit()
}
```

## Verification

No automated test: this is Core Animation rendering behavior on a hosted layer
with no model-observable output. Asserting on `CALayer` implicit-animation
state would be fragile and structure-sensitive, which the repo's behavioral,
structure-insensitive test bar excludes.

1. **Compile:** `just build` (builds `.build/DanTerm Dev.app`).
2. **Backing-scale change (if a second display with a different backing scale
   is available):** `just build-run`, then drag the window between a Retina and
   a non-Retina display. The terminal contents should not show a blurry/animated
   scale transition during the move. If no such display is available, the
   `just build` compile check plus parity with Ghostty's documented idiom is
   the bar.
