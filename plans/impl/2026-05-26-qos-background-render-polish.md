# QoS / background-render polish (mirror Ghostty)

## Context

Goal: study Ghostty's QoS handling and improve DanTerm's background rendering
and idle CPU/power use.

**Key finding -- the big stuff is already done.** Ghostty's QoS/background-render
logic lives *inside libghostty's per-surface render thread*, not in Ghostty's
Swift app. Ghostty's macOS app is itself just an embedder of the same C API
DanTerm uses, and it earns those optimizations by feeding libghostty three
signals. DanTerm already feeds all three, the same way:

- per-surface focus via `becomeFirstResponder`/`resignFirstResponder` ->
  `ghostty_surface_set_focus` (`app/TerminalView.swift:257,268`)
- per-surface occlusion via `windowDidChangeOcclusionState` + the reconcile pass,
  folding in tab-selected/zoom -> `ghostty_surface_set_occlusion`
  (`app/AppDelegate.swift:691`, `app/Reconcile.swift:77`, `app/AppRuntime.swift:284`)
- app focus via `applicationDidBecome/ResignActive` -> `ghostty_app_set_focus`
  (`app/AppRuntime.swift:572`)

So DanTerm already inherits the 3-tier render-thread QoS (`utility` occluded /
`user_initiated` visible-unfocused / `user_interactive` focused --
`.ghostty-src/src/renderer/Thread.zig:setQosClass`), the `CVDisplayLink`
start-only-when-focused+visible gating (`.ghostty-src/src/renderer/generic.zig:1029,1053`),
cursor-blink suspend on unfocus, and `drawFrame` skip when occluded. DanTerm even
handles the per-surface display-id and content-scale plumbing many embedders miss.

This plan covers the two remaining gaps vs Ghostty. They are incremental polish,
not a new subsystem.

Testing note: Change 1 is pure AppKit/GhosttyKit glue, not unit-testable without
Cocoa (the suite covers pure model/update logic) -- manual verification. Change 2
is dispatch glue; its pure inputs (`toInitFile`, `graftScrollback`) are already
covered by existing tests, and its correctness is an ordering/fencing argument
(below) rather than a unit test.

---

## Change 1: retarget the CVDisplayLink when the window changes monitors

**Problem.** `ghostty_surface_set_display_id` is called only once, in
`viewDidMoveToWindow` (`app/TerminalView.swift:174`). There is no
`windowDidChangeScreen` handler, so when the window is dragged to a different
monitor the per-surface `CVDisplayLink` keeps vsyncing at the original display's
refresh rate.

**Impact.** Move a window from the 120Hz built-in display to a 60Hz external
(common docked setup) and every surface's render thread keeps waking at 120Hz --
roughly 2x the necessary render-thread wakeups and GPU frames per pane. The
reverse (60->120) under-renders/janks. `viewDidChangeBackingProperties` does not
cover same-scale monitor moves.

**Reference.** Ghostty's `windowDidChangeScreen` in
`.ghostty-src/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:764`
does *two* things: (a) `ghostty_surface_set_display_id(surface, screen.displayID)`
("this will be used with the CVDisplayLink to ensure the proper refresh rate is
going"), and (b) an explicit `DispatchQueue.main.async { viewDidChangeBackingProperties() }`
nudge -- added for ghostty-org/ghostty#2731 ("blurry text moving between monitors
with different scaling") because the automatic backing-properties callback is not
reliable on the screen-move path. We mirror both. DanTerm's `TerminalView` is a
plain `NSView` like Ghostty's `SurfaceView`, so it is subject to the same #2731
behavior, and Change 1 adds exactly the screen-move path that triggers it.

**Fix.** Mirror DanTerm's existing `windowDidChangeOcclusionState` -> runtime ->
loop-surfaces pattern (single-window app, so all surfaces share `window?.screen`).
(Considered the per-view alternative -- each `TerminalView` observing
`NSWindow.didChangeScreenNotification`, as Ghostty's SurfaceView does -- but the
centralized fan-out matches DanTerm's existing occlusion handling and avoids
per-view observer lifecycle for a single-window app.)

In `app/AppDelegate.swift`, after `windowDidChangeOcclusionState` (line 694):

```swift
// NSWindowDelegate: window moved to a different monitor. Retarget each
// surface's CVDisplayLink to the new display so vsync matches its refresh rate.
func windowDidChangeScreen(_ notification: Notification) {
    guard notification.object is NSWindow else { return }
    runtime?.syncSurfaceDisplayID()
}
```

In `app/AppRuntime.swift`, next to `syncSurfaceVisibility` (after line 300),
reusing the existing `NSScreen.displayID` extension (`app/TerminalView.swift:705`):

```swift
/// Push the active monitor's display id to every live surface so libghostty's
/// per-surface CVDisplayLink re-syncs to that monitor's refresh rate. Without
/// this a window dragged between monitors keeps vsyncing at the old display's
/// rate (a 120Hz->60Hz move burns ~2x frames per pane). Mirrors Ghostty's
/// windowDidChangeScreen.
func syncSurfaceDisplayID() {
    guard let displayID = window?.screen?.displayID else { return }
    for (_, view) in surfaces {
        guard let surface = view.surface else { continue }
        ghostty_surface_set_display_id(surface, displayID)
    }
    // Mirror Ghostty: nudge content scale on the next runloop turn in case the
    // new monitor has a different backing scale. The automatic
    // viewDidChangeBackingProperties is unreliable on the screen-move path
    // (ghostty-org/ghostty#2731 -- blurry/mis-sized text). The override is
    // idempotent, so a same-scale move just re-sends current values (cheap).
    DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        for (_, view) in self.surfaces { view.viewDidChangeBackingProperties() }
    }
}
```

---

## Change 2: offload periodic checkpoint disk I/O off the main thread

**Problem.** Both checkpoint writers run fully on `.main`
(`app/AppRuntime.swift:846,871,878`). The enriched writer also reads scrollback
from every live surface. The disk encode+write blocks the main thread.

**Constraints (both required for correctness).**

1. *Synchronous termination/flush.* `performEnrichedCheckpoint` is also called
   from `applicationWillTerminate` (`app/AppDelegate.swift:712`), and
   `flushPendingCheckpoint` runs on `appResignedActive` (`app/AppRuntime.swift:824`)
   precisely so the latest state is durable before the app may be killed. Those
   paths must block until the bytes are written.
2. *Total write ordering + fencing.* If sync writes ran inline on the caller
   while async writes ran on a queue, an older queued async write could land
   *after* a newer sync write and clobber it; and an async write already in
   flight on `appResignedActive` (when nothing is "pending") would not be fenced
   before a kill. So **every** write -- sync and async -- must go through one
   shared serial queue.

**Fix.** One shared serial utility queue near the checkpoint fields
(`app/AppRuntime.swift:62`). Async paths enqueue; sync paths `queue.sync` (which,
on a serial queue, runs FIFO after any pending async write and blocks the caller
until done -- giving both ordering and fencing). Model access and scrollback
reads stay on the caller (main); only encode+write move to the queue.

```swift
// Shared serial queue for ALL checkpoint disk I/O. Serial + .atomic writes give
// total ordering (a newer write can't be overtaken by an older queued one) and a
// single drain point for fencing. qos .utility keeps periodic writes off the UI
// critical path.
private static let checkpointIOQueue = DispatchQueue(label: "danterm.checkpoint.io", qos: .utility)

private func writeCheckpoint(_ initFile: AppInitFile, to url: URL, async: Bool) {
    let dir = recoveryDirectoryURL()
    let work = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(initFile) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
    if async {
        Self.checkpointIOQueue.async(execute: work)
    } else {
        Self.checkpointIOQueue.sync(execute: work)  // FIFO after pending async; blocks until durable
    }
}

private func performLightCheckpoint(async: Bool) { ... writeCheckpoint(initFile, to: lightCheckpointURL(), async: async) }
func performEnrichedCheckpoint(async: Bool) { ... writeCheckpoint(..., to: enrichedCheckpointURL(), async: async) }
```

`flushPendingCheckpoint` must fence even when nothing is pending:

```swift
func flushPendingCheckpoint() {
    checkpointTimer?.cancel()
    checkpointTimer = nil
    if checkpointPending {
        performLightCheckpoint(async: false)   // sync: drains prior writes, then writes latest
    } else {
        Self.checkpointIOQueue.sync {}          // fence any in-flight async write before the app may die
    }
}
```

`async` is intentionally non-defaulted so every call site is explicit. Call-site
routing:
- debounce timer handler (`app/AppRuntime.swift:816`): `performLightCheckpoint(async: true)`
- enriched timer handler (`:838`): `performEnrichedCheckpoint(async: true)`
- `flushPendingCheckpoint` (`:828`): sync (above)
- `applicationWillTerminate` (`app/AppDelegate.swift:712`): `performEnrichedCheckpoint(async: false)`

Light and enriched share the one queue, so a single `queue.sync` at termination
drains in-flight writes of both kinds before exit. `queue.sync` from main on a
distinct serial queue does not deadlock.

---

## Out of scope (deliberate)

- **Removing the `GHOSTTY_ACTION_RENDER` handler** (`app/GhosttyApp.swift:223`).
  Verified against the source: `must_draw_from_app_thread` defaults to `false`
  (`.ghostty-src/src/renderer/Thread.zig:26-30`) and is declared `true` only in
  the GTK apprt (`src/apprt/gtk/App.zig:22`). In `drawFrame`
  (`Thread.zig:502-510`) the app-thread `redraw_surface` push -- the only source
  of `GHOSTTY_ACTION_RENDER` -- happens only under that flag; the embedded/macOS
  path calls `renderer.drawFrame()` directly on the render thread. So the action
  effectively never fires in DanTerm's build. The handler is harmless dead code,
  not a per-frame main-queue cost; removing it is unrelated cleanup, not a QoS
  win, so it is excluded here.
- **Occlusion-gating the enriched checkpoint.** Behavior change (on-disk
  scrollback goes stale while backgrounded) for a 10-min-cadence task; the I/O
  offload already addresses the cost.
- **Dropping focus on app-resign while the window stays visible.** Ghostty
  behaves identically (keeps rendering a visible background window so you can
  watch a side terminal). Matching it is correct.

---

## Verification

1. `just build` -- compiles clean (debug dev build).
2. `just test` -- existing pure suite still green (guards no regression in
   model/checkpoint serialization helpers).
3. **Change 1 (manual, needs 2 monitors at different refresh rates):** open
   DanTerm on the 120Hz display, start steady output (e.g. `yes`), drag the
   window to the 60Hz monitor. Confirm render cadence/CPU follows the new
   monitor (Activity Monitor / `powermetrics`, or a `CVDisplayLink`-rate log);
   before the fix the render thread stays pinned to the old rate. Then, with
   monitors of *different backing scale* (e.g. 2x built-in + 1x external), drag
   the window across and confirm text stays crisp and correctly sized after the
   move -- this exercises the #2731 content-scale path the backing nudge guards,
   which the refresh-cadence check alone would miss. Single-monitor users:
   confirm no regression on normal use.
4. **Change 2 (manual):** trigger a light checkpoint (mutate state, wait 2s) and
   an enriched one (wait for the timer); confirm both files appear under the
   recovery dir with valid JSON. Quit the app and confirm the final enriched
   checkpoint is written (sync path intact). Switch away rapidly after a state
   change and confirm the resign-flush still produces the latest light
   checkpoint (ordering/fencing intact).
