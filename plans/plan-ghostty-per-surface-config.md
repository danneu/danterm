# Plan: Fix CONFIG_CHANGE Target Scoping

## Context

`GHOSTTY_ACTION_CONFIG_CHANGE` fires with two distinct targets:

- **`GHOSTTY_TARGET_APP`** — global config reload (user edited config file)
- **`GHOSTTY_TARGET_SURFACE`** — per-surface derived config update

The current handler (`GhosttyApp.swift:235`) doesn't check the target. It
unconditionally replaces `GhosttyApp.config` and sends `.configDidChange`
(triggering `rebuildContentView`), so a surface-scoped config change overwrites
the app-level config and applies one pane's scrollbar setting to every pane.

The fix: make scrollbar visibility a per-TerminalView property instead of a
single global. App-target changes fan out to all views; surface-target changes
update only the addressed view. This matches Ghostty's own pattern
(`.ghostty-src/macos/Sources/Ghostty/Ghostty.App.swift:2112`).

## Files to Change

### 1. `app/TerminalView.swift`

Add a `scrollbarEnabled` property alongside the existing `cellSize`/`scrollbarState`:

```swift
var scrollbarEnabled: Bool = true {
    didSet { scrollDelegate?.scrollbarConfigDidChange() }
}
```

### 2. `app/ScrollableTerminalView.swift`

**Remove `scrollbarEnabled` init parameter.** Read it from
`terminalView.scrollbarEnabled` instead.

Add `scrollbarConfigDidChange()` method (called by TerminalView's `didSet`):

```swift
func scrollbarConfigDidChange() {
    scrollView.hasVerticalScroller = terminalView.scrollbarEnabled
}
```

In `init`, set `scrollView.hasVerticalScroller = terminalView.scrollbarEnabled`
(replacing the removed parameter).

### 3. `app/GhosttyApp.swift`

**Extract a helper** to read the scrollbar setting from any config:

```swift
static func readScrollbarEnabled(from config: ghostty_config_t?) -> Bool {
    guard let config = config else { return true }
    var v: UnsafePointer<Int8>?
    let key = "scrollbar"
    guard ghostty_config_get(config, &v, key, UInt(key.utf8.count)) else { return true }
    guard let ptr = v else { return true }
    return String(cString: ptr) != "never"
}
```

**Simplify `scrollbarEnabled`** to use the helper:

```swift
var scrollbarEnabled: Bool { Self.readScrollbarEnabled(from: config) }
```

**Replace the CONFIG_CHANGE handler** with target-scoped handling:

```swift
case GHOSTTY_ACTION_CONFIG_CHANGE:
    let changeConfig = action.action.config_change.config
    switch target.tag {
    case GHOSTTY_TARGET_APP:
        let newConfig = ghostty_config_clone(changeConfig)
        if let old = self.config { ghostty_config_free(old) }
        self.config = newConfig
        // Fan out to all surfaces
        let enabled = Self.readScrollbarEnabled(from: newConfig)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for (_, view) in self.runtime?.surfaces ?? [:] {
                view.scrollbarEnabled = enabled
            }
        }

    case GHOSTTY_TARGET_SURFACE:
        // Update only the addressed surface
        if let surface = Self.targetSurface(target),
           let bridge = Self.surfaceBridge(from: surface),
           let view = bridge.view {
            let enabled = Self.readScrollbarEnabled(from: changeConfig)
            view.scrollbarEnabled = enabled
        }

    default:
        break
    }
    return true
```

The `changeConfig` pointer is valid for the callback duration — we read
`scrollbarEnabled` synchronously. Only clone for app-target (retained for
future reads).

### 4. `app/PaneWrapperView.swift`

Remove `scrollbarEnabled` parameter from init (revert to pre-scrollbar
signature). ScrollableTerminalView now reads from `terminalView.scrollbarEnabled`.

### 5. `app/SplitContainerView.swift`

Remove `scrollbarEnabled` stored property and init parameter. Stop passing it
to `PaneWrapperView`.

### 6. `app/AppRuntime.swift`

Stop passing `scrollbarEnabled` to `SplitContainerView` in
`rebuildContentView()`.

**Seed initial value** in `makeTerminalView()` (line ~724, after setting
`view.runtime = self`):

```swift
view.scrollbarEnabled = ghosttyApp.scrollbarEnabled
```

This ensures every new TerminalView starts with the correct scrollbar setting
from the current app config, rather than defaulting to `true`.

### 7. `app/Msg.swift` + `app/Update.swift`

Remove `case configDidChange` from `Msg` and its handler in `Update`. Config
changes now go directly to the view layer without passing through the Elm
architecture (same pattern as RENDER, MOUSE_SHAPE, CELL_SIZE, SCROLLBAR).

## Verification

1. `just build` — compiles
2. `just test` — all tests pass
3. Manual (`just build-run`):
   - Set `scrollbar = never` in ghostty config, reload — all panes hide scrollbar
   - Set `scrollbar = system`, reload — all panes show scrollbar
   - Surface-scoped config change doesn't affect other panes
