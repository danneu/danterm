# Forward effective per-surface visibility to libghostty

## Context

The previously shipped plan forwards **window** occlusion to libghostty so
the renderer thread can pause Metal draws and drop QoS when the whole
window is hidden. It misses a much bigger case in normal usage:
non-selected tabs and zoomed-sibling panes inside the visible window.
Their surfaces stay at `.user_interactive` QoS and keep drawing even
though nothing reaches the screen.

Ghostty's own macOS app does not solve this either: it uses
`NSWindowTabGroup`, and AppKit reports each window as `.visible` even
when it is the non-selected tab in a group. The window-occlusion signal
alone is not enough for any libghostty-based terminal with in-app tabs.

This plan replaces "fan window-occlusion to every surface" with "fan
effective per-surface visibility to every surface," where effective
visibility is a pure function of the model + the window's occlusion
state. It dissolves the original "what about background-tab surfaces?"
problem, removes the special-case initial-sync added by the previous
plan, and is a small, self-contained step toward a future "view
hierarchy as a projection of the model" refactor (see the Future
work section below).

## Effective visibility, defined

A surface is "effectively visible" iff **all** are true:

1. `windowVisible` (the window's `occlusionState.contains(.visible)`)
2. The pane belongs to `model.selectedTabId`
3. If the selected tab is zoomed (`tab.isZoomed == true`), the pane is
   the tab's `focusedPaneId`

Rule 3 falls out of how `rebuildContentView` already renders a zoomed
tab: `displayNode = .leaf(tab.focusedPaneId)`
(`app/AppRuntime.swift:1399-1401`). Sibling panes in a zoomed tab are
not in the view tree.

## Design

### 1. Pure predicate in ModelOperations

Add to `app/ModelOperations.swift`:

```swift
// Compute expected libghostty occlusion state for every pane reachable
// from a tab's split tree. Forward-only iteration -- no reverse lookup
// needed. Panes not present in the map have no opinion (caller defaults
// to visible to match libghostty's own initial state).
func effectiveSurfaceVisibility(
    in model: AppModel,
    windowVisible: Bool
) -> [PaneId: Bool] {
    var out: [PaneId: Bool] = [:]
    let selected = model.selectedTabId
    for group in model.groups {
        for tab in group.tabs {
            let tabIsSelected = (tab.id == selected)
            for paneId in allPaneIds(tab.rootNode) {
                let visible = windowVisible
                    && tabIsSelected
                    && !(tab.isZoomed && paneId != tab.focusedPaneId)
                out[paneId] = visible
            }
        }
    }
    return out
}
```

Reuses the existing `allPaneIds(_:)` traversal already in
`ModelOperations.swift`. No new helpers, no reverse PaneId -> TabId
lookup needed.

### 2. Diffing fan-out on AppRuntime

Add to `app/AppRuntime.swift`:

```swift
// Cache of the last value pushed to each surface. Skips redundant FFI
// calls AND must agree with `surfaces` at all times -- see
// `tearDownCurrentSession`, which clears this map before
// `commitRestoreSession` swaps in staged surfaces. Snapshot restore
// reuses pane IDs verbatim, so a stale entry on a new background-tab
// surface would short-circuit the first sync and leave it at
// libghostty's default visibility. The cache is not optional.
private var surfaceVisibility: [PaneId: Bool] = [:]

// Recompute every surface's effective visibility and push any changes
// to libghostty. Cheap to call: O(panes) traversal plus FFI only on
// changed entries. Idempotent -- safe to call from any post-mutation
// hook.
func syncSurfaceVisibility() {
    let windowVisible = window?.occlusionState.contains(.visible) ?? true
    let desired = effectiveSurfaceVisibility(
        in: model,
        windowVisible: windowVisible
    )
    for (paneId, view) in surfaces {
        guard let surface = view.surface else { continue }
        // Panes in surfaces but not in the desired map are orphans
        // (shouldn't happen, but libghostty's default is visible=true).
        let expected = desired[paneId] ?? true
        if surfaceVisibility[paneId] != expected {
            ghostty_surface_set_occlusion(surface, expected)
            surfaceVisibility[paneId] = expected
        }
    }
    // Drop stale entries for surfaces that have been destroyed.
    surfaceVisibility = surfaceVisibility.filter { surfaces[$0.key] != nil }
}
```

### 3. Three hook points

**(a) Window-occlusion delegate** (replaces the previous plan's
fan-out call).

`app/AppDelegate.swift:windowDidChangeOcclusionState(_:)`: replace the
call to `runtime?.applyOcclusionToAllSurfaces(visible)` with
`runtime?.syncSurfaceVisibility()`. The window's current occlusion is
re-read inside `syncSurfaceVisibility`, so no parameter needed.

**(b) End of `send()`** -- the catch-all for any model mutation.

`app/AppRuntime.swift:send(_:)`: after the effect-processing loop
completes (around line 214, before the `appResignedActive` defensive
backstop), add `syncSurfaceVisibility()`. This single hook covers every
visibility-affecting Msg with no need to touch individual Update cases:

- `selectTab` / `selectAdjacentTab` / `mruCycleCommit`
- `createTab` (foreground and `--background`)
- `closeTab` / `closePane` (selection may change to another tab)
- `toggleZoomPane` (rule 3 turns on/off)
- `splitPane` (new surface in selected tab)
- Any future Msg that mutates `selectedTabId`, `isZoomed`, or
  `focusedPaneId`

Reentrant `send()` calls (e.g., `surfaceCreationFailed`) each run their
own sync at the outermost level. The diff cache + libghostty's own
short-circuit make redundant syncs free.

**(c) End of `commitRestoreSession`** -- snapshot restore bypasses
`send()`.

`app/AppRuntime.swift:commitRestoreSession`: after the existing
`rebuildContentView()` call (around line 1261), add
`syncSurfaceVisibility()`. This catches the restore path, where
`makeTerminalView` is called directly for every pane (selected and
unselected tabs alike) without going through `send()`.

### 4. Cache lifetime: clear on teardown

`commitRestoreSession` calls `tearDownCurrentSession()` and then does
`surfaces = staged.surfaces` ([AppRuntime.swift](../../app/AppRuntime.swift):1248-1254).
Restore staging reuses snapshot pane IDs verbatim
([AppRuntime.swift](../../app/AppRuntime.swift):1177-1198), so a
restored `PaneId` can collide with an entry from the previous session.
If the new surface's expected visibility happens to equal the cached
value (e.g., both `false` because both were background tabs), the diff
check in `syncSurfaceVisibility` short-circuits and the new surface
keeps libghostty's default `visible: true` -- stuck-on visibility for a
background-tab surface.

Fix: treat the cache as surface-lifetime state. In
`tearDownCurrentSession()` ([AppRuntime.swift](../../app/AppRuntime.swift):1224),
add `surfaceVisibility.removeAll()` right after the surfaces loop. That
single line makes the cache always agree with the live `surfaces`
dictionary across both reload paths (restore and import). The
filter-stale-entries line at the bottom of `syncSurfaceVisibility` then
only handles per-pane destruction (closePane / closeTab) during a
normal session, where pane IDs are not reused.

### 5. Removals

The previous plan's two pieces become redundant and should be deleted:

- **`AppRuntime.applyOcclusionToAllSurfaces(_:)`** (lines ~330-336).
  Its sole caller (the delegate method) now calls
  `syncSurfaceVisibility()`. Delete the function entirely.

- **The initial-sync block at the end of `makeTerminalView`**
  (lines ~1304-1309). Both flows that create surfaces now run
  `syncSurfaceVisibility` shortly after creation: the normal
  `.createSurface` effect flow ends in `send()`'s post-effect sync,
  and the restore flow ends in `commitRestoreSession`'s sync. The
  initial-sync becomes dead code.

After the removals, all per-surface occlusion handling lives in exactly
one place (`syncSurfaceVisibility`) driven by exactly one pure predicate
(`effectiveSurfaceVisibility`).

## Files

- `app/ModelOperations.swift` -- add `effectiveSurfaceVisibility(in:windowVisible:)`.
- `app/AppRuntime.swift` -- add `surfaceVisibility` cache + `syncSurfaceVisibility()`;
  add the call at the end of `send()`'s effect loop; add the call at
  the end of `commitRestoreSession`; add `surfaceVisibility.removeAll()`
  inside `tearDownCurrentSession()`; delete `applyOcclusionToAllSurfaces`;
  delete the initial-sync block in `makeTerminalView`.
- `app/AppDelegate.swift` -- replace the `applyOcclusionToAllSurfaces`
  call inside `windowDidChangeOcclusionState` with
  `syncSurfaceVisibility()`.
- `tests/ModelOperationsTests.swift` -- add the new predicate test
  cases inside the existing `modelOperationsTests()` function. The
  custom runner ([TestHarness.swift](../../tests/TestHarness.swift):5)
  invokes test groups by name, so a standalone
  `EffectiveVisibilityTests.swift` would compile but never execute.

No changes to `Msg.swift`, `Update.swift`, `Effect.swift`,
`Model.swift`, `TerminalView.swift`, or `SplitContainerView.swift`. No
new Msg/Effect surface. No model state added.

## Verification

### Automated

The new behavior lives in a pure function over `AppModel`, so it is
fully unit-testable in the Foundation-only harness. Add tests for
`effectiveSurfaceVisibility` covering:

1. `windowVisible: false` -> every reachable pane false.
2. Single tab, single pane, window visible -> that pane true.
3. Two tabs (A selected, B not), window visible -> A's panes true,
   B's panes false.
4. Selected tab zoomed with two panes -> `focusedPaneId` true, the
   other false.
5. Selected tab zoomed with one pane -> that pane true (zoom is a
   no-op on a single-leaf tab).
6. `selectedTabId == nil` (edge case during teardown) -> every pane
   false.
7. Selected tab with nested splits (deeper than one level) -> every
   leaf true.

Each test constructs a small `AppModel` literal and asserts on the
returned `[PaneId: Bool]`. Add the cases inside the existing
`modelOperationsTests()` function in
`tests/ModelOperationsTests.swift` so the manually-wired runner picks
them up. Use the same `AppModel` constructors and helpers already used
by other entries in that file.

Run:

- `just test` -- new tests must pass; existing tests untouched.
- `just build` -- must succeed. The `send()` and
  `commitRestoreSession` hooks compile only through a full build
  (the test harness excludes AppKit/GhosttyKit).

### Manual

From `just build-run`:

1. **Per-tab visibility kicks in.** Open three tabs, run `top` in
   each. Activity Monitor's Energy or CPU tab should show the
   non-selected tabs' renderer threads dropping CPU. Switching tabs
   should swap which one stays active. (Sanity check, not strict
   pass/fail.)
2. **Zoom hides sibling panes.** Open one tab, split into two panes,
   run `top` in both. Toggle zoom on one pane. The hidden pane's
   renderer thread should drop activity; un-zoom should restore it.
3. **Background tab create starts hidden.** With one tab in focus,
   send `danterm tab new --background --cmd 'top'` over IPC (or use
   whatever in-app shortcut creates a background tab). The new tab's
   surface should start at low QoS; switching to it should bring it
   up.
4. **Restore preserves the rule.** Force-quit DanTerm with multiple
   tabs open, relaunch, accept the restore prompt. Non-selected tabs'
   surfaces should be at low QoS from the moment restore completes.
5. **Window occlusion still works.** Hide the app (Cmd-H) -- all
   surfaces (selected tab included) drop QoS. Unhide -- only the
   selected tab's panes (and the focused one if zoomed) come back up.
6. **No visible regressions.** Animated content in the selected tab
   (`cmatrix`, `htop`) keeps animating smoothly across tab switches.
   Search overlay, jump mode, and MRU switcher still work normally.
7. **In-process import does not strand background surfaces visible.**
   The stale-cache bug only manifests when the cache survives the
   `tearDownCurrentSession` -> `commitRestoreSession` swap, so a
   process restart (which starts with an empty cache) cannot catch a
   missing `surfaceVisibility.removeAll()`. Reproduce in-process with
   this exact sequence: (a) launch DanTerm with one tab (tab 1).
   (b) Open a second tab (tab 2 is now focused). (c) Run `top` in
   tab 2. (d) Select tab 1 so tab 2 is in the background -- this
   state is what populates the cache with `tab2pane: false`.
   (e) Export state to a JSON file from the menu. (f) Import that
   same file from the menu without quitting. (g) Leave tab 1
   selected; do **not** click tab 2. Watch tab 2's renderer activity
   in Activity Monitor -- it should drop to low QoS within a second
   of the import completing. Without the cache-clear, the new
   background-tab surface keeps libghostty's default `visible: true`
   and stays at `.user_interactive` until manually selected.

## Future work (not in this plan)

The next step in the broader direction is to stop tearing down the
view tree on tab switch -- keep every tab's container mounted, swap
`isHidden` instead of rebuilding. That folds into the same model
because `effectiveSurfaceVisibility` already encodes the rule the
hidden-flag would need. Out of scope here.
