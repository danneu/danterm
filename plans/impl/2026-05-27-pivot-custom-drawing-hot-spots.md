# Plan: pivot the "custom drawing hot spots" finding

## Context

A review finding flagged two custom-draw views as performance "hot spots" and
proposed high-effort remedies (cache render inputs, `wantsUpdateLayer`,
concurrent drawing, targeted dirty rects). Verification showed the framing was
wrong on both counts, so this is a **pivot**, not the proposed fix:

- **`PaneDragOverlayView`** is not a bug. `update()` invalidates the whole view
  via `needsDisplay = true`, but that is *correct*: the highlight rect moves
  between panes during a drag, so the previous highlight must be erased, and the
  whole `draw(_:)` is a single rounded-rect fill + stroke. A "targeted dirty
  rect" would either leave ghost artifacts or require unioning old+new rects for
  no real gain. `wantsUpdateLayer`/concurrent drawing do not apply (used nowhere
  in the app). **No logic change.**

- **`ColorSwatchView.draw`** computes its font fit with an inline
  ~40-iteration loop (`NSFont.monospacedSystemFont` + a probe
  `NSAttributedString.size()` per step) buried mid-`draw(_:)`. The fit is
  geometry-only -- per-swatch colors are applied separately, after the loop --
  so the loop is a self-contained unit worth pulling into a named helper. The
  swatch geometry is in fact fixed (**50pt wide x 24pt rows** in both browsers,
  `app/ThemeBrowserView.swift:54,265`, `app/RemoteThemePickerSheet.swift:30`),
  so the fit is a recomputed constant -- but the path is cold, so we extract for
  readability and **deliberately do not cache** (see section 1).

Honest impact: this is a cold path (a preferences theme browser), so the only
win is readability -- a shorter `draw(_:)` and a named helper -- not
performance. The fitting loop still runs per draw; caching it would save only
imperceptible cold-path work, so it is deliberately omitted. Effort is **low**,
contrary to the finding's "High" rating, which only applied to the misguided
layer/concurrency rewrite. The plan also adds **no regression test** (see
section 3).

## Changes

### 1. Extract the font-fit into a helper -- `app/ThemeSwatchViews.swift`

Pull the fitting loop (current lines 41-55) out of `draw(_:)` into a small
helper so `draw(_:)` reads as a short sequence of named steps. Keep the
algorithm **byte-for-byte identical** (same 0.5 step, same `> 4` floor, same
pre-loop seed at `fontSize = textArea.height`, same fit predicate) so the
rendered output does not change.

```swift
/// Bold/regular monospaced fonts at the size where "test█" just fits a swatch's
/// text area, plus the rendered size used to center it.
fileprivate struct SwatchTextFit {
    let bold: NSFont
    let regular: NSFont
    let textSize: NSSize
}

/// Largest monospaced size at which "test█" fits within `textAreaSize` (minus
/// horizontal padding). Geometry-only -- no dependence on per-swatch colors.
fileprivate func swatchTextFit(textAreaSize: NSSize, padding: CGFloat = 3) -> SwatchTextFit
```

`draw(_:)` calls `swatchTextFit(textAreaSize: textArea.size)` directly and uses
`fit.bold` / `fit.regular` / `fit.textSize`. The colored
`NSMutableAttributedString` is still rebuilt per draw (foreground colors are
per-swatch); only the geometry-only fitting moves into the helper.

Design choices:

- **No cache.** The loop runs per draw, as before. The swatch geometry is fixed
  so the fit is effectively a recomputed constant, but the path is cold (a
  preferences browser), so memoizing it would save only imperceptible work while
  adding mutable per-view state. The extraction is purely a readability change.
- Keep `swatchTextFit` `fileprivate`: its only caller is `ColorSwatchView` in
  the same file, so file-local scope keeps the surface minimal.

### 2. Document the intentional invalidation -- `app/PaneDragOverlayView.swift`

No behavior change. Add a comment on `update(rect:intent:)` (line 19) so the
"hot spot" finding does not recur:

```swift
// Invalidate the whole view, not a sub-rect: the highlight moves between panes
// during a drag, so the previous highlight must be erased too. The draw is a
// single rounded rect, so full invalidation is already cheap.
```

### 3. No regression test (deliberate)

`swatchTextFit` is a self-contained geometry helper with two near-identical
callers (`ThemeBrowserView`, `RemoteThemePickerSheet`), and the extraction is
behavior-preserving (the loop moves byte-for-byte). Its correctness is
self-evident and confirmed by eye in the running app, so there is nothing
fragile for a test to guard. A test would also add a 4th hand-maintained entry
to `test-ui.sh` plus latent fragility -- its standalone-compile assumption
breaks the moment `ThemeSwatchViews.swift` gains an app-internal dependency --
i.e. maintenance cost for no protected invariant. So none is added.

On the TDD norm: AGENTS.md's "write the failing test first" targets *new
behavior or bug fixes*; this change is neither (rendered output is unchanged),
so a characterization test is not warranted here.

## Files

- `app/ThemeSwatchViews.swift` -- extract `swatchTextFit` + `SwatchTextFit`, call from `draw` (no cache)
- `app/PaneDragOverlayView.swift` -- comment only

## Verification

1. **Compiles + renders**: `just build-run`, open Preferences -> theme browser.
   Swatches render identically to before (same "test█" sizing, palette bar,
   colors). Scroll the full theme list -- no visual change.
2. **Tests unaffected**: `just test` still green (no test files touched).
3. **No regression to drag overlay**: drag a pane; drop-zone highlights still
   appear/clear correctly (no code change, just the comment).
