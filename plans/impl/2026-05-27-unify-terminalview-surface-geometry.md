# Pivot: unify TerminalView surface geometry sync

## Context

A review finding ("De-dupe surface scale/size calls", High/High) proposed caching
`lastPixelSize`/`lastScale` in `TerminalView` and only calling
`ghostty_surface_set_content_scale` / `ghostty_surface_set_size` on real changes,
mirroring cmux.

Verification of that finding showed the **perf premise does not hold for DanTerm**:

- Ghostty already dedups size internally — `updateSize` early-returns on identical
  pixel size: *"resizes are expensive... we check that the size actually changed"*
  (`.ghostty-src/src/apprt/embedded.zig:788`).
- Ghostty already dedups content scale at the DPI level — `contentScaleCallback`
  early-returns when DPI is unchanged: *"If our DPI didn't actually change, save a
  lot of work by doing nothing"* (`.ghostty-src/src/Surface.zig:3571`).
- cmux needs its cache because its `updateSize` runs from `forceRefresh()`, which
  fires **on every keystroke**. DanTerm has no such caller: the only callers of the
  two Ghostty functions are three AppKit lifecycle methods on cold, user-action
  paths (tab switch, split create/destroy, live resize). No display-link/timer
  drives them.

So a redundant call costs one FFI hop + a `convertToBacking` + a couple of
comparisons, not a grid reflow. Caching buys ~nothing and adds state to keep in
sync.

What the finding *did* correctly point at is a **structural problem**: the
scale+size computation is copy-pasted across three methods that have already
drifted, and each one independently re-implements a documented zero/NaN footgun.
The finding also missed the third site. `TerminalView` has **no unit tests** today
(`tests/` has zero coverage of it), so the footgun is unprotected.

**The pivot (chosen scope: unify + tests, no caching):** extract the pure
scale/size computation into one testable helper, collapse all three call sites to
call it, and add the unit tests that pin the invariants. Strictly behavior-preserving.

## The three call sites today (`app/TerminalView.swift` ~168-237)

All three derive backing size -> per-axis content scale and push both to Ghostty,
differing only in incidental ways:

| Method | size used | `convertToBacking` | zero guard | extra work |
|---|---|---|---|---|
| `viewDidMoveToWindow` | `frame` | once, on rect | `if w>0 && h>0` | `ghostty_surface_set_display_id` |
| `viewDidChangeBackingProperties` | `frame` | **twice** (rect + size) | `guard...return` | `layer?.contentsScale = ...` |
| `setFrameSize` | `newSize` | once, on size | `guard...return` | none |

The documented footguns to preserve (current comments at ~177-181, ~201-202,
~223-225): a zero frame divides to `NaN`, which Ghostty clamps to scale 1.0,
silently halving Retina; sending `0x0` corrupts terminal state (offset/double-prompt
artifacts on tab switch/split). See `docs/design/2026-03-05-display-scaling.md`.

Note: `AppRuntime.syncSurfaceDisplayID()` (`app/AppRuntime.swift:318`) calls
`viewDidChangeBackingProperties()` programmatically on every surface during a
display change, so that method's behavior must be preserved exactly.

## Changes

### 1. New pure helper — `app/SurfaceGeometry.swift`

Mirrors the established pure-helper precedent `app/ScrollbarMath.swift` (free
function, `import Foundation` only, no AppKit/GhosttyKit, guards degenerate input).
A new file under `app/` is auto-included in the SwiftPM `DanTerm` target
(`Package.swift` uses `path: "app"`), so no `Package.swift` change is needed.

```swift
// Pure content-scale + backing-pixel-size derivation for a Ghostty surface.
// No AppKit/GhosttyKit dependency so it compiles into both the app and the unit
// test build. Single source of truth for the invariant in docs/design/2026-03-05-display-scaling.md:
// Ghostty must receive backing-pixel dimensions paired with a matching per-axis
// content scale.

import Foundation

/// Geometry to push to a Ghostty surface: per-axis content scale + backing pixels.
struct SurfaceGeometry: Equatable {
    let xScale: Double
    let yScale: Double
    let pixelWidth: UInt32
    let pixelHeight: UInt32
}

/// Derive surface geometry from a logical (point) size and its backing-pixel size
/// (the result of NSView.convertToBacking).
///
/// Returns nil for any non-positive dimension. Callers MUST treat nil as "skip the
/// update": sending 0x0 to ghostty corrupts terminal state, and a divide-by-zero
/// scale (NaN) gets clamped to 1.0, silently halving Retina.
func surfaceGeometry(logicalSize: CGSize, backingSize: CGSize) -> SurfaceGeometry? {
    guard logicalSize.width > 0, logicalSize.height > 0,
          backingSize.width > 0, backingSize.height > 0 else { return nil }
    return SurfaceGeometry(
        xScale: Double(backingSize.width / logicalSize.width),
        yScale: Double(backingSize.height / logicalSize.height),
        pixelWidth: UInt32(backingSize.width),
        pixelHeight: UInt32(backingSize.height)
    )
}
```

The single `guard` is now the one place the zero/NaN footgun lives. Per-axis scale
is preserved (don't collapse to one scalar). The `UInt32(...)` truncation matches
the existing casts exactly — do not tighten the guard beyond `> 0` (that would be a
behavior change).

### 2. Funnel `TerminalView` through one method — `app/TerminalView.swift`

Add a private method that does the Cocoa `convertToBacking` and pushes the result:

```swift
// Single source of truth for pushing content scale + backing pixel size to the
// surface. The three AppKit entry points below all funnel through here so scale
// and size can never drift apart (docs/design/2026-03-05-display-scaling.md). No-op on degenerate sizes
// (view not yet laid out, or frame reset to .zero during split rebuild).
private func syncSurfaceGeometry(logicalSize: NSSize) {
    guard let surface else { return }
    let backing = convertToBacking(logicalSize)
    guard let geo = surfaceGeometry(logicalSize: logicalSize, backingSize: backing)
    else { return }
    ghostty_surface_set_content_scale(surface, geo.xScale, geo.yScale)
    ghostty_surface_set_size(surface, geo.pixelWidth, geo.pixelHeight)
}
```

Rewrite the three methods to keep their method-specific work and delegate geometry
(comments abbreviated here; keep the protocol-identifying comments per CLAUDE.md):

```swift
override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // Preserve "only act when in a window" (whole original body was inside `if let window`).
    guard let surface, let window else { return }
    if let screen = window.screen {
        ghostty_surface_set_display_id(surface, screen.displayID)
    }
    syncSurfaceGeometry(logicalSize: frame.size)
}

override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    guard surface != nil else { return }          // preserve: skip layer update too when no surface
    if let window {
        layer?.contentsScale = window.backingScaleFactor
    }
    syncSurfaceGeometry(logicalSize: frame.size)  // collapses the redundant double convertToBacking
}

override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    syncSurfaceGeometry(logicalSize: newSize)
}
```

Behavior-preservation notes:
- `viewDidMoveToWindow`: `guard let window` reproduces the original outer `if let
  window`; on removal (window == nil) nothing runs, as before. The zero-frame skip
  now lives in `syncSurfaceGeometry`.
- `viewDidChangeBackingProperties`: keep the top `surface` guard so the
  `layer.contentsScale` update is still skipped when there's no surface; it still
  runs before the geometry sync (matches today). The original called
  `convertToBacking` twice (rect then size) — equivalent because the size component
  is origin-independent; the helper does it once.
- `setFrameSize`: pass `newSize` (authoritative; equals `frame.size` after `super`).

### 3. Tests — `tests/SurfaceGeometryTests.swift`

Behavioral, structure-insensitive tests of the extracted invariants (uses the
`expect`/`expectEqual` harness; `SurfaceGeometry` is `Equatable`, and
`optional == nonOptionalLiteral` compiles via `Optional`'s `==`):

```swift
import Foundation

func surfaceGeometryTests() {
    test("Retina 2x -> scale 2, backing pixels") {
        try expect(surfaceGeometry(logicalSize: CGSize(width: 800, height: 600),
                                   backingSize: CGSize(width: 1600, height: 1200))
                   == SurfaceGeometry(xScale: 2, yScale: 2, pixelWidth: 1600, pixelHeight: 1200))
    }
    test("non-Retina 1x -> scale 1") {
        try expect(surfaceGeometry(logicalSize: CGSize(width: 800, height: 600),
                                   backingSize: CGSize(width: 800, height: 600))
                   == SurfaceGeometry(xScale: 1, yScale: 1, pixelWidth: 800, pixelHeight: 600))
    }
    test("x and y scale derived independently") {
        try expect(surfaceGeometry(logicalSize: CGSize(width: 100, height: 100),
                                   backingSize: CGSize(width: 200, height: 150))
                   == SurfaceGeometry(xScale: 2, yScale: 1.5, pixelWidth: 200, pixelHeight: 150))
    }
    test("fractional backing pixels truncate (matches UInt32 cast)") {
        let geo = surfaceGeometry(logicalSize: CGSize(width: 800, height: 600),
                                  backingSize: CGSize(width: 1601.9, height: 1200.4))
        try expectEqual(geo?.pixelWidth, 1601)
        try expectEqual(geo?.pixelHeight, 1200)
    }
    test("zero logical size -> nil (no NaN scale / 0x0 to ghostty)") {
        try expect(surfaceGeometry(logicalSize: .zero,
                                   backingSize: CGSize(width: 1600, height: 1200)) == nil)
    }
    test("zero backing size -> nil") {
        try expect(surfaceGeometry(logicalSize: CGSize(width: 800, height: 600),
                                   backingSize: .zero) == nil)
    }
    test("single zero dimension -> nil") {
        try expect(surfaceGeometry(logicalSize: CGSize(width: 800, height: 0),
                                   backingSize: CGSize(width: 1600, height: 0)) == nil)
    }
}
```

### 4. Wire the test build

- `test.sh`: add `"$SCRIPT_DIR/app/SurfaceGeometry.swift" \` to the compile list
  (next to the existing `app/ScrollbarMath.swift` line ~33). The test file is
  picked up automatically via the `tests/*.swift` glob.
- `tests/TestHarness.swift`: register `surfaceGeometryTests()` in `TestRunner.main()`
  (next to `scrollbarMathTests()` ~line 23).

### 5. Doc sync — `docs/design/2026-03-05-display-scaling.md`

The doc is ADR-style (`## Context` / `## Decision` / `## Consequences` /
`## References`). Update it in place:

- **`## Decision`** — the inline code block (~lines 27-32) and the touch-point
  bullets (~34-46): replace the raw `convertToBacking` / `set_*` snippet with the
  funnel — all entry points call `TerminalView.syncSurfaceGeometry(logicalSize:)`,
  which delegates the pure derivation to `surfaceGeometry(logicalSize:backingSize:)`
  in `app/SurfaceGeometry.swift`. Reframe the zero-size-guard prose (~48-53) as a
  single guard (`surfaceGeometry` returns nil) covering every entry point, not a
  per-method check.
- **`## Consequences`** — the zero-frame-guard note (~69-70): note the guard now
  lives in one place, so it can't be dropped from one path while surviving in
  another.
- **`## References`** (~74-75): add `app/SurfaceGeometry.swift` (`surfaceGeometry`)
  alongside the existing `app/TerminalView.swift` entry.

## Non-goals

- **No caching / dedup.** Ghostty already dedups both calls internally
  (`embedded.zig:788`, `Surface.zig:3571`) and there is no hot-path caller. Adding
  `last*` state would be redundant and a maintenance liability. (`SurfaceGeometry`
  is `Equatable`, so if profiling ever justifies it, a one-field dedup is a trivial
  follow-up — but it is explicitly out of scope here.)
- No change to the per-method extra work (display-id seeding, `layer.contentsScale`).
- No guard tightening beyond the existing `> 0` checks.

## Verification

TDD order:
1. Add `app/SurfaceGeometry.swift`, `tests/SurfaceGeometryTests.swift`, and the two
   wiring edits. Before creating the helper, the tests reference an undefined
   symbol -> `just test` fails to compile (expected red). Create the helper -> the
   new tests pass (green). Confirm the **full** suite stays green: `just test`.
2. Refactor the three `TerminalView` methods to call `syncSurfaceGeometry`. This is
   behavior-preserving and not unit-tested (Cocoa), so verify via build + manual run:
   - `just build` — compiles (helper auto-included in the app target).
   - `just build-run` — launch `DanTerm Dev.app` and check on a Retina display:
     - Fonts render crisp at correct size (content scale 2x correct).
     - Split a pane right and down, then switch tabs repeatedly — no offset or
       double-prompt artifacts (zero-frame guard still effective during rebuild).
     - Live-resize the window — grid reflows cleanly, no garbling.
     - If a non-Retina external display is available: drag the window between
       displays — fonts and mouse hit-testing stay correct (exercises
       `viewDidChangeBackingProperties` via `AppRuntime.syncSurfaceDisplayID`).

## Files

- New: `app/SurfaceGeometry.swift`, `tests/SurfaceGeometryTests.swift`
- Edit: `app/TerminalView.swift` (3 methods + 1 new private method),
  `test.sh`, `tests/TestHarness.swift`, `docs/design/2026-03-05-display-scaling.md`
