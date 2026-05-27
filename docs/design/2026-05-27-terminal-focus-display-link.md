# Terminal Focus and Display Link Recovery

Status: Accepted
Date: 2026-05-27

## Context

DanTerm hosts libghostty surfaces inside AppKit views. When a terminal pane is
rebuilt, reparented, or shown again after a tab/split transition, the AppKit
first-responder transition is also the point where the live Ghostty surface
learns that it is focused again.

Ghostty renders through a per-surface display link on macOS. A pane can appear
mounted but stop repainting if that display link is running from Ghostty's point
of view while no useful callbacks are reaching the surface after a reparenting
transition. This makes the tempting fixes misleading:

- `ghostty_surface_set_display_id` retargets the display link to a display, but
  it does not restart the focus lifecycle.
- `ghostty_surface_refresh` queues render work, but Ghostty skips ordinary
  draw-frame work while `hasVsync()` reports that the display link is running.
- Visibility is a separate lifecycle input. DanTerm sends effective visibility
  through `syncSurfaceVisibility` via `ghostty_surface_set_occlusion`, and
  Ghostty's renderer starts the display link from `setVisible` only when the
  surface is visible and already focused.

## Decision

For a reparent/focus transition, DanTerm treats AppKit focus as the display-link
recovery path. Code that needs to activate a terminal pane should make the
`TerminalView` first responder and let `TerminalView.becomeFirstResponder` call
`ghostty_surface_set_focus(surface, true)`.

DanTerm should keep display-id synchronization in screen-change paths and
visibility synchronization in occlusion/model-visibility paths. It should not
add ad hoc `set_display_id` or `refresh` nudges to terminal focus code to
recover a stalled display link.

## Consequences

Terminal focus helpers should stay small: they should make the pane's
`TerminalView` first responder and rely on the responder callback to push focus
into Ghostty.

Future fixes for repaint stalls should first identify which lifecycle input is
wrong: focus, visibility, display ID, content scale, or size. A repaint issue
should not be fixed by stacking all Ghostty surface calls together unless the
underlying lifecycle inputs are actually wrong.

Comments near focus code should qualify the rule as the reparent/focus recovery
path. They should not claim focus is the only display-link restart path because
Ghostty also starts and stops the link from visibility when the surface is
already focused.

## References

- `app/AppRuntime.swift`: `focusPaneSurface`, `syncSurfaceVisibility`,
  `syncSurfaceDisplayID`
- `app/TerminalView.swift`: `becomeFirstResponder`, `resignFirstResponder`
- `.ghostty-src/src/apprt/embedded.zig`: `ghostty_surface_set_focus`,
  `ghostty_surface_set_display_id`, `ghostty_surface_refresh`
- `.ghostty-src/src/renderer/generic.zig`: `setFocus`, `setVisible`,
  `hasVsync`, `setMacOSDisplayID`
- `.ghostty-src/src/renderer/Thread.zig`: `drawFrame`
