# Forward window occlusion state to libghostty

## Context

DanTerm doesn't tell libghostty when its window becomes occluded. Ghostty's
own macOS app does (`.ghostty-src/macos/Sources/Features/Terminal/BaseTerminalController.swift:1255-1262`),
and the libghostty renderer thread reacts to that signal by pausing its
Metal draws and dropping its macOS QoS class from `.user_interactive`
down to `.utility` (`.ghostty-src/src/renderer/Thread.zig:265-289`). With
no signal, DanTerm's renderer threads stay at the higher priority even
when the window is fully hidden, minimized, on another space, or
covered by an opaque window — wasting CPU and battery.

The fix is the smallest possible: wire up the `NSWindowDelegate`
occlusion-change callback and call `ghostty_surface_set_occlusion` on
every live surface.

## Design

Three small additions:

### 1. AppDelegate: NSWindowDelegate callback

`AppDelegate` is already the main window's `NSWindowDelegate`
(`app/AppDelegate.swift:60`, existing `windowShouldClose` at line 684).
Add next to it:

```swift
// NSWindowDelegate: forward window occlusion changes to libghostty so its
// renderer thread can pause Metal draws and drop to .utility QoS when the
// window is fully occluded. Mirrors Ghostty's reference impl at
// BaseTerminalController.swift:1255.
func windowDidChangeOcclusionState(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    let visible = window.occlusionState.contains(.visible)
    runtime?.applyOcclusionToAllSurfaces(visible)
}
```

### 2. AppRuntime: surface fan-out

`AppRuntime` owns `surfaces: [PaneId: TerminalView]`
(`app/AppRuntime.swift:21`); each `TerminalView` exposes
`surface: ghostty_surface_t?`. Add:

```swift
// Forward occlusion state to every live libghostty surface. Mirrors
// BaseTerminalController.swift:1257-1261.
func applyOcclusionToAllSurfaces(_ visible: Bool) {
    for view in surfaces.values {
        if let surface = view.surface {
            ghostty_surface_set_occlusion(surface, visible)
        }
    }
}
```

Keeping the fan-out on `AppRuntime` avoids pulling `GhosttyKit` imports
into `AppDelegate` and matches the existing pattern where all
ghostty-surface interaction sits on `AppRuntime`.

### 3. AppRuntime.makeTerminalView: sync occlusion on creation

A surface created while the window is already occluded would otherwise
stay at the higher renderer-thread QoS until the next occlusion
transition. `viewDidMoveToWindow` is the wrong hook for the initial
sync because DanTerm intentionally keeps live surfaces detached from
the window in several flows:

- `tab new --background` creates the tab without selecting it, so its
  surfaces are never placed into the split container view tree.
- Unselected background splits inside non-selected tabs are not
  rebuilt either.
- Snapshot restore stages every pane up front; only the selected
  tab's panes get attached to the window.

In all of these cases `viewDidMoveToWindow` never fires, so the new
surface stays at the higher QoS until something later forces a window
attach (often: user switches to that tab).

`AppRuntime` already holds `weak var window: NSWindow?`
(`app/AppRuntime.swift:23`), so the simpler and more universal place
is inside `makeTerminalView` itself, immediately after the
`TerminalView` is constructed (the surface is created synchronously in
`TerminalView.init`, so `view.surface` is already populated by the
time `makeTerminalView` returns).

Add at the end of `makeTerminalView` (`app/AppRuntime.swift:1283`),
before `return view`:

```swift
// Sync initial occlusion to the freshly-created surface. Surfaces
// created while the window is hidden/occluded (background-tab create,
// snapshot restore of unselected tabs, unselected splits) never fire
// viewDidMoveToWindow until much later, so without this they stay at
// .user_interactive QoS until the next window visibility change.
// Default to `true` (visible) when no window is wired yet — matches
// libghostty's own default.
if let surface = view.surface {
    let visible = window?.occlusionState.contains(.visible) ?? true
    ghostty_surface_set_occlusion(surface, visible)
}
```

## Files

- `app/AppDelegate.swift` — add `windowDidChangeOcclusionState(_:)`
  alongside the existing `windowShouldClose`.
- `app/AppRuntime.swift` — add `applyOcclusionToAllSurfaces(_:)` and
  the initial-sync line at the end of `makeTerminalView`.

No changes to `Msg.swift`, `Update.swift`, `Effect.swift`, `Model.swift`,
`ModelOperations.swift`, `TerminalView.swift`, or any test file. No new
model state, no new effects, no changes to the checkpoint code path.

## Verification

### Automated

No new unit tests. The change is thin AppKit-to-C-API plumbing; both
endpoints are unmockable in the Foundation-only test harness
(`test.sh` excludes `GhosttyKit` and AppKit), and there's no pure
decision worth unit-testing.

Run both:

- `just test` — must still pass; the pure model is untouched, so all
  existing tests should be unaffected.
- `just build` — must succeed. `test.sh` does not compile
  `AppDelegate.swift` or `AppRuntime.swift`, so a build is the only
  automated check that the new `NSWindowDelegate` signature, the
  `AppRuntime` fan-out, and the `ghostty_surface_set_occlusion` call
  all compile.

### Manual

From a `just build-run`:

1. **Renderer pause is wired.** Open Activity Monitor's Energy tab.
   Compare an idle pane visible vs occluded for ~30s. Energy Impact /
   CPU% should drop while occluded (Cmd-H or cover with an opaque
   full-screen window). This is a sanity check that
   `ghostty_surface_set_occlusion` is reaching libghostty; not a
   strict pass/fail since absolute numbers depend on hardware and
   background load.
2. **Multiple surfaces all get the signal.** Open two tabs, each with
   a split (4 surfaces total). Hide the window; bring it back.
   Nothing visible should break — no surfaces stuck blank, no
   freezes, no log spam.
3. **Re-show resumes rendering.** Run something animated in a pane
   (`htop`, `top`, `cmatrix` if installed). Hide the window for >30s.
   Restore. The animation should resume within a frame or two with no
   stutter.
