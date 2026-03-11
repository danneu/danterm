# Progress Indicator in Pane Toolbar

## Context

Claude Code (and other tools) emit OSC 9;4 escape sequences to report task progress. libghostty already parses these into `GHOSTTY_ACTION_PROGRESS_REPORT` callbacks, but DanTerm silently drops them. We want to show a small radial progress indicator before the pane title in the toolbar, matching the states: set (0–100%), indeterminate, error, pause, remove.

## Plan

### 1. Model — add progress state to `PaneModel`

**`app/Model.swift`**

```swift
enum ProgressState: Equatable {
    case set(percent: UInt8)       // 0–100
    case indeterminate
    case error(percent: UInt8?)
    case pause(percent: UInt8?)
}

struct PaneModel: Equatable {
    // ... existing fields ...
    var progress: ProgressState? = nil   // nil = no indicator shown
}
```

### 2. Msg — add ghostty callback message

**`app/Msg.swift`**

```swift
// Ghostty callbacks section:
case surfaceProgress(paneId: PaneId, state: ProgressState?)
```

State is `nil` for the `remove` action (clears the indicator).

### 3. GhosttyApp — handle the action callback

**`app/GhosttyApp.swift`** — add a new case in `handleAction()`, matching the existing `DispatchQueue.main.async` pattern used by all other callbacks:

```swift
case GHOSTTY_ACTION_PROGRESS_REPORT:
    if let surface = Self.targetSurface(target),
       let bridge = Self.surfaceBridge(from: surface),
       let paneId = bridge.paneId {
        let raw = action.action.progress_report
        let progress: UInt8? = raw.progress >= 0 ? UInt8(raw.progress) : nil
        let state: ProgressState?
        switch raw.state {
        case GHOSTTY_PROGRESS_STATE_REMOVE:       state = nil
        case GHOSTTY_PROGRESS_STATE_SET:          state = .set(percent: progress ?? 0)
        case GHOSTTY_PROGRESS_STATE_ERROR:        state = .error(percent: progress)
        case GHOSTTY_PROGRESS_STATE_INDETERMINATE: state = .indeterminate
        case GHOSTTY_PROGRESS_STATE_PAUSE:        state = .pause(percent: progress)
        default:                                  state = nil
        }
        DispatchQueue.main.async { [weak self] in
            self?.runtime?.send(.surfaceProgress(paneId: paneId, state: state))
        }
    }
    return true
```

### 4. Update — handle the message

**`app/Update.swift`**

```swift
case .surfaceProgress(let paneId, let state):
    model.panes[paneId]?.progress = state
    return []
```

### 5. AppRuntime — unified toolbar refresh

**`app/AppRuntime.swift`**

Add `.surfaceProgress` to the toolbar-refresh switch (alongside `.surfaceTitle` / `.surfaceCwd`):

```swift
case .surfaceTitle(let paneId, _), .surfaceCwd(let paneId, _), .surfaceProgress(let paneId, _):
    refreshPaneToolbar(for: paneId)
```

Extend both `refreshPaneToolbar(for:)` and `refreshPaneToolbars()` to pass progress through the single unified call:

```swift
func refreshPaneToolbar(for paneId: PaneId) {
    guard let contentArea = contentArea else { return }
    let (title, cwd) = paneToolbarText(for: paneId, in: model)
    let progress = model.panes[paneId]?.progress
    findPaneWrapper(for: paneId, in: contentArea)?.updateToolbar(title: title, cwd: cwd, progress: progress)
}

func refreshPaneToolbars() {
    guard let contentArea = contentArea else { return }
    forEachPaneWrapper(in: contentArea) { wrapper in
        let (title, cwd) = paneToolbarText(for: wrapper.paneId, in: model)
        let progress = model.panes[wrapper.paneId]?.progress
        wrapper.updateToolbar(title: title, cwd: cwd, progress: progress)
    }
}
```

### 6. PaneWrapperView — radial progress indicator

**`app/PaneWrapperView.swift`**

Replace the existing `updateToolbar(title:cwd:)` with a unified entry point. Add a small radial indicator before the title label.

**Indicator host**: A non-hit-testing NSView (~12x12pt) containing two CAShapeLayers:
- `trackLayer` — full circle, faint stroke (for determinate states background ring)
- `arcLayer` — the progress arc / spinner arc

Override `hitTest` to return `nil` so the drag handle underneath still receives events.

**Toolbar layout changes**:
- Add `progressIndicator` view as a toolbar subview, positioned before `toolbarLabel`
- `progressIndicator.leadingAnchor` = toolbar leading + 8
- `toolbarLabel.leadingAnchor` = `progressIndicator.trailingAnchor` + 4 (when visible) or toolbar leading + 8 (when hidden)
- Use a stored constraint reference to swap the label's leading anchor depending on visibility. When `progressIndicator.isHidden = true`, activate the label-to-toolbar constraint; when visible, activate the label-to-indicator constraint.

**Unified update method**:

```swift
func updateToolbar(title: String, cwd: String?, progress: ProgressState? = nil) {
    toolbarLabel.stringValue = formatToolbarLabel(title: title, cwd: cwd)
    applyProgressState(progress)
}
```

**Two distinct methods for rendering**:

- **`applyProgressState(_ state: ProgressState?)`** — called from `updateToolbar`. Handles state transitions:
  - `nil`: hide indicator, deactivate indicator-leading constraint, activate label-to-toolbar constraint, remove animations, store `currentProgress = nil`
  - `.set(percent)`: show indicator, accent-color stroke, set `arcLayer.strokeEnd = percent/100`, no animation on arcLayer (implicit CATransaction for smooth updates). Show `trackLayer` as background ring.
  - `.indeterminate`: show indicator, accent-color stroke, `arcLayer.strokeEnd = 0.25`, add repeating `CABasicAnimation` on `transform.rotation.z`. Hide `trackLayer`.
  - `.error(percent)`: same as `.set` but red stroke; if percent is nil, treat as indeterminate-red
  - `.pause(percent)`: same as `.set` but orange stroke; if percent is nil, full ring orange
  - Stores `currentProgress` for layout use.

- **`layoutProgressIndicator()`** — called from `layout()`. Geometry-only: recomputes the circular `CGPath` for both shape layers based on current indicator frame. Does not touch colors, visibility, or animations.

Store `currentProgress: ProgressState?` on PaneWrapperView for layout to reference.

### 7. Tests

**`tests/UpdateGhosttyTests.swift`** — pure model tests:

- `surfaceProgress` with `.set` stores state in model
- `surfaceProgress` with `nil` clears it
- `surfaceProgress` for unknown pane is a no-op
- Progress state survives across title/cwd updates

The radial indicator rendering and toolbar refresh pipeline are **verified manually** — these cannot be unit-tested without AppKit.

## Files to modify

1. `app/Model.swift` — add `ProgressState` enum, `progress` field on `PaneModel`
2. `app/Msg.swift` — add `surfaceProgress` case
3. `app/GhosttyApp.swift` — handle `GHOSTTY_ACTION_PROGRESS_REPORT`
4. `app/Update.swift` — handle `.surfaceProgress`
5. `app/AppRuntime.swift` — unified toolbar refresh with progress
6. `app/PaneWrapperView.swift` — radial indicator, unified `updateToolbar`, constraint swapping
7. `tests/UpdateGhosttyTests.swift` — unit tests

## Verification

1. `just test` — all existing + new tests pass
2. `just build-run` — launch DanTerm
3. `printf '\e]9;4;1;50\a'` — accent-colored ring at 50% before pane title
4. `printf '\e]9;4;3\a'` — spinning arc indicator before title
5. `printf '\e]9;4;2;75\a'` — red ring at 75% before title
6. `printf '\e]9;4;4;60\a'` — orange ring at 60% before title
7. `printf '\e]9;4;0\a'` — indicator disappears, title shifts left
8. `for i in $(seq 0 5 100); do printf '\e]9;4;1;%d\a' $i; sleep 0.1; done; printf '\e]9;4;0\a'` — smooth ring fill animation
