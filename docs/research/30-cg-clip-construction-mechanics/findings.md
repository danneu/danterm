# Findings -- CG clip construction mechanics

Continues doc 29; qualified citations like `29/F3` refer to
[../29-sparse-appkit-damage-clip-topology/findings.md](../29-sparse-appkit-damage-clip-topology/findings.md).

Evidence provenance for the disassembly findings (F2--F4): macOS 26.5.2
(build 25F84), arm64, CoreGraphics loaded from the dyld shared cache,
disassembled 2026-08-03 via lldb attached to the probe program in F2's
reproduction recipe. These are observations of one OS build's implementation,
not API contract; re-verify on a new macOS major before citing as current.

## F1 -- the public contract says clip-to-rects is path-based

**Observed.** The macOS SDK header
(`CoreGraphics.framework/Headers/CGContext.h`, clipping sections) documents:

- `CGContextClip`: "Intersect the context's path with the current clip path
  and use the resulting path as the clip path for subsequent rendering
  operations."
- `CGContextClipToRect`: "Intersect the current clipping path with `rect`.
  Note that this function resets the context's path to the empty path."
- `CGContextClipToRects`: "Intersect the current clipping path with the
  clipping region formed by creating a path consisting of all rects in
  `rects`. Note that this function resets the context's path to the empty
  path."

Apple's QuartzDemo sample states the same equivalence: clip-to-rects "is
functionally equivalent to adding each rectangle to the current path and then
calling CGContextClip()"
([QuartzClippingView sample listing](https://developer.apple.com/library/archive/samplecode/QuartzDemo/Listings/QuartzDemo_QuartzClippingView_swift.html)).

**Inferred.** At the *documented* level there is no reason to prefer
`clip(to: [CGRect])` over the shipped addRect loop for multiple rects. Any
real difference has to come from the implementation, which is what F2--F4
establish.

**Confidence.** High; these are verbatim header comments from the installed
SDK.

**Unlocks.** The disassembly probe (F2).

## F2 -- `CGContextClipToRects` dispatch: count 1 takes a different road

**Reproduction recipe.** Compile and disassemble in a scratch directory:

```c
// cgprobe.c
#include <CoreGraphics/CoreGraphics.h>
int main(void) {
    CGContextRef ctx = CGBitmapContextCreate(0, 8, 8, 8, 0,
        CGColorSpaceCreateDeviceRGB(), (uint32_t)kCGImageAlphaPremultipliedLast);
    CGRect r = CGRectMake(0, 0, 4, 4);
    CGContextClipToRects(ctx, &r, 1);
    return 0;
}
```

```
clang cgprobe.c -framework CoreGraphics -o cgprobe
lldb -b -o "b main" -o run \
     -o "disassemble -n CGContextClipToRects" \
     -o "disassemble -n CGContextClipToRect -c 60" \
     -o "disassemble -n CGContextClip" \
     ./cgprobe
```

(An unrelated Swift thunk also matches `-n CGContextClipToRects`; the C entry
point is the one whose body checks the `CTX?` magic constant.)

**Observed.** `CoreGraphics'CGContextClipToRects` on this build:

- validates the context (magic `0x43545854` "CTXT"/"XTC" constant check);
- if `count == 1`, loads the four rect doubles and **tail-calls
  `CGContextClipToRect`**:

  ```
  0x19656019c <+56>:  cmp    x2, #0x1
  0x1965601a0 <+60>:  b.ne   0x19656020c    ; multi-rect body
  0x1965601a4 <+64>:  ldp    d0, d1, [x20]
  0x1965601a8 <+68>:  ldp    d2, d3, [x20, #0x10]
  ...
  0x1965601cc <+104>: b      0x1964cf240    ; CGContextClipToRect
  ```

- if `count > 1`, releases the context's current path (the CFRelease of the
  slot at context+0xa8, i.e. an implicit `beginPath`), calls
  `CGContextAddRects`, and tail-calls the internal `clip(ctx, 0)` routine --
  the **same address `CGContextClip` branches to** (`CGContextClip` is
  literally `mov w1, #0; b clip`):

  ```
  0x196560228 <+196>: bl     0x196568284    ; CGContextAddRects
  ...
  0x196560250 <+236>: b      0x19651ff20    ; clip
  ```

**Inferred.** For two or more rects, `clip(to: [CGRect])` and the shipped
`beginPath()` / `addRect` loop / `clip()` are the *identical* CoreGraphics
code path -- the header's equivalence claim (F1) is literally true in the
implementation. For exactly one rect, `clip(to:)` silently upgrades to the
`CGContextClipToRect` route, which F3 shows is materially different.

**Alternatives considered.** None credible; the disassembly is unambiguous on
this build. The finding could rot across OS releases (recipe above re-checks).

**Confidence.** High for this build; medium across future OS versions.

**Unlocks.** F3 (what the single-rect road does), F5 (what the shipped code
misses).

## F3 -- `CGContextClipToRect` never builds a path

**Observed.** `CoreGraphics'CGContextClipToRect` validates the rect for
NaN/infinity, then calls `CGGStateClipToRect` directly on the gstate and
clears the current path afterward -- no `CGPath` object is created at any
point:

```
0x1964cf2b0 <+112>: ldr    x0, [x19, #0x60]   ; gstate
0x1964cf2b4 <+116>: bl     0x1964cf30c        ; CGGStateClipToRect
0x1964cf2b8 <+120>: ldr    x0, [x19, #0xa8]   ; current path slot
0x1964cf2bc <+124>: cbz    x0, ...            ; (release it if present)
```

**Inferred.** A single-rect clip has a dedicated, path-free construction
route. Combined with F4 (the gstate keeps rect clips as rect clip-stack
entries), a one-rect clip avoids both path allocation and generic path-clip
handling downstream.

**Confidence.** High for construction; the downstream rasterization benefit
is inferred from F4 plus 29's measured per-rect scaling, not directly
observed.

**Unlocks.** H1 and D1.

## F4 -- the path route specializes single-rect paths only; no rect-list clip exists

**Observed.** The internal `clip` routine posts an error for an empty path,
then calls `CGGStateClipToOwnedPath`. That function's call graph on this
build:

```
CGGStateClipToOwnedPath
  -> CGPathIsRect                       ; whole-path single-rect test
  -> CGClipCreateWithRect               ; taken when the path IS one rect
  -> CGClipCreate                       ; taken otherwise (generic path clip)
  -> maybeCopyClipState
  -> CGClipStackAddClip
```

`CGClipCreate` itself just allocates and stores the clip entry
(`malloc_type_malloc`, retain/release traffic); no call that would scan a
path for a rectangle sequence appears in it, and an
`image lookup -r -s 'SequenceOfRects' CoreGraphics` over the loaded image
matched nothing relevant.

**Inferred.**

1. A clip path that `CGPathIsRect` accepts (exactly one rect) is stored as a
   rectangular clip-stack entry even when it arrived through the path API.
2. A path of two or more disjoint rects is stored as a *generic path clip*.
   CoreGraphics' public API offers no union-of-rects region clip at all --
   repeated `CGContextClipToRect` calls intersect, so a union can only be
   expressed as a path.
3. Therefore the per-rect cost that 29/F3 measured (Core Animation compound
   clip construction scaling with row-rect count) is paid downstream of a
   generic path clip, and **maximal-span coalescing already sits at the
   floor**: for >= 2 spans there is nothing cheaper to ask CG for. The only
   remaining reachable win is the single-span case (F3).

**Alternative interpretations.** The rasterizer below `CGClipStackAddClip`
could still specialize almost-rectangular paths; that layer was not
disassembled. This would only make the multi-span case cheaper than assumed,
not change any recommendation here.

**Confidence.** High for the construction-layer dispatch; medium for the
"floor" claim about layers below it.

**Unlocks.** Confirms 29/H1's mechanism one level deeper; bounds this doc's
scope to the single-span case plus simplifications.

## F5 -- the shipped code always takes the path route; precedent agrees rects and paths are different roads

**Observed (in-repo).** `app/SwiftTerminalSessionView.swift#draw(_:)` builds
the clip as:

```swift
context.beginPath()
for span in terminalDamageMaximalContiguousSpans(drawingDamage.rows) {
    context.addRect(...)
}
context.clip()
```

This constructs a CGPath unconditionally, so even a partial draw whose damage
coalesces to a single span takes the generic `CGClipCreate` route of F4
instead of the `CGGStateClipToRect` route of F3.

**Observed (precedent).** WebKit's CG backend
([`Source/WebCore/platform/graphics/cg/GraphicsContextCG.cpp`](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/graphics/cg/GraphicsContextCG.cpp),
fetched 2026-08-03) keeps the two roads separate: `clip(const FloatRect&)`
calls `CGContextClipToRect` directly, and only `clipPath` uses
`CGContextClip`/`CGContextEOClip` with a built path. It also uses
`CGContextFillRects` for multi-rect fills rather than path fills.

**Inferred.** Replacing the loop with one `context.clip(to: rects)` call:

- is bit-identical CG work for >= 2 spans (F2);
- automatically upgrades the 1-span case to the path-free route (F2, F3);
- replaces N bridged Swift->C calls with one;
- deletes the `beginPath()`/`clip()` pair from the view code.

Predicted direction: equivalent-or-faster, never slower. How often the 1-span
upgrade fires is an empirical question -- the `damageTopology` histogram
shipped in `f3c774d` (`TerminalBenchmark.swift#observeDamageTopology`)
measures exactly this and should be read before attributing any win to H1
rather than to noise.

**Confidence.** High on the mechanics; the magnitude is expected to be small
(the draws in question already cost ~0.06 ms, 29/F6) and may not clear the
benchmark's equivalence band, which is why D1 is framed as
simplification-first.

**Unlocks.** D1.

## F6 -- the second `clip(to: dirtyRect)` is load-bearing, but foldable

**Observed.** After the span clip and the background fill, `draw(_:)` applies
`context.clip(to: dirtyRect)` before glyph drawing. The fill itself is
`context.fill(dirtyRect)` and is bounded by its own rect; the span clip is
bounded by the damage rows. So the second clip's only effect is to trim glyph
drawing to `dirtyRect`.

AppKit's documentation implies the context already arrives clipped to the
update region: `NSView.getRectsBeingDrawn(_:count:)` describes using the rect
list to "avoid unnecessary drawing that would be completely clipped away"
([doc](https://developer.apple.com/documentation/appkit/nsview/getrectsbeingdrawn(_:count:))),
and `NSView.draw(_:)` says AppKit "creates an appropriate drawing context and
configures it for drawing to the view"
([doc](https://developer.apple.com/documentation/appkit/nsview/draw(_:))).
Neither statement is written for the layer-backed backing-store path
specifically, and 29/F2 already found AppKit's invalid-region reporting on
this layer-backed view degraded to the bounding union -- so the pre-clip's
exact shape is documented-adjacent, not proven.

**Inferred.** The second clip is *not* dead code to be deleted on the
strength of those quotes. Its correctness function: it guarantees glyphs land
only where this pass just refilled the background. If AppKit ever delivered a
`dirtyRect` narrower than the pending damage spans (e.g. damage consumed on
the first of several per-rect draw callbacks), glyphs outside `dirtyRect`
would otherwise blend their antialiased edges over pixels whose background
was not refilled -- the same double-blend failure mode that makes the clip
non-optional against `clipFramePlan` alone.

However, the same guarantee survives a fold: intersect each span rect with
`dirtyRect` *before* a single `clip(to:)` call. Union of per-span
intersections equals (union of spans) intersect `dirtyRect`, so the resulting
clip region is exactly what the two stacked clips produce today, with one
clip-stack entry instead of two -- and clamping can only reduce the rect
count, so more draws land on F3's single-rect road.

**Alternative interpretations.** If AppKit's pre-clip is in fact always at
least as tight as `dirtyRect`, today's second clip and the folded intersection
are both redundant-but-free with it; nothing in D1 depends on which is true.

**Confidence.** High on the region-algebra equivalence; medium on the
narrower-dirtyRect scenario ever occurring in practice (it is guarded either
way).

**Unlocks.** D1's exact shape (clamped spans, single clip call).

## F7 -- the damage representation round-trips through a Set it never needed

**Observed.** The damage pipeline
(`lib/TerminalCore/Sources/TerminalCore/TerminalDamage.swift`):

- `TerminalDamageAccumulator` stores damage as a `[UInt64]` bitset -- already
  ordered, dense, and O(words) to scan.
- `drain()` explodes the bitset into an unordered `Set<Int>`
  (`TerminalDamageAccumulator.drain`), allocating and hashing per row.
- The view's halo expansion (`terminalDamageRowsWithGlyphHalo`) walks the Set
  with per-element membership probes.
- `terminalDamageMaximalContiguousSpans` then calls `rows.sorted()` every
  partial draw to recover the ordering the bitset had for free, plus an
  allocation for the sorted array and one for the spans.
- `terminalDamageMaximalContiguousSpanCount` guards `row == Int.min` against
  `row - 1` overflow; `TerminalDamage.init(rows:)` filters negative rows, so
  that branch is unreachable -- dead code documenting a value that cannot
  occur.

**Inferred.** If `TerminalDamage` carried the bitset (or `[Range<Int>]`)
instead of `Set<Int>`:

- spans fall out of one linear word scan, no sort, no hashing;
- the halo becomes word-level `w | (w << 1) | (w >> 1)` with cross-word
  carries;
- `formUnion` becomes word-wise OR;
- the `Int.min` guard and the span-sorting helper disappear.

At <= ~100 viewport rows every deleted operation is nanoseconds; this is a
simplification with a non-regression gate (D2), not a performance claim --
consistent with `agent-docs/measurement-discipline.md` on not acting on
unmeasured differences.

**Alternative interpretations / risk.** `TerminalDamage.rows: Set<Int>` is
public API inside `TerminalCore` with tests against it; if threading a new
representation outward grows the diff past what the deleted conversions
justify, the correct disposition is REJECTED with that reason recorded. The
finding stands either way; the decision is D2's.

**Confidence.** High on the mechanics (all code cited above is in-tree).

**Unlocks.** D2.

## F8 -- benchmark instrumentation posture (verified 2026-08-03)

The topology accounting shipped alongside the span clip in `f3c774d` is itself
a change to the measurement system, so this doc audits its cost posture -- and
freezes that posture as the bar any future instrumentation change must meet
(D4). Three layers of gating were verified in the current tree:

**Observed.**

1. **Compiled out of production.** The `DANTERM_TERMINAL_BENCHMARK` compile
   flag is passed only by `scripts/terminal-benchmark.sh`
   (`-Xswiftc -DDANTERM_TERMINAL_BENCHMARK`); `just build` /
   `just build-optimized` never define it. The observer call site in
   `SwiftTerminalSessionView.draw(_:)` sits inside
   `#if DANTERM_TERMINAL_BENCHMARK`, so dev and release apps carry zero
   instrumentation code, not merely disabled code.
2. **No-ops in verdict runs.** Inside benchmark builds, the per-draw
   accounting (`TerminalBenchmark.swift#observeCompletedDraw`) is gated on
   `activityPath`, which is non-nil only when
   `DANTERM_TERMINAL_BENCHMARK_ACTIVITY_PATH` is set to a non-empty value
   (the observer's init explicitly maps empty to nil). Paired comparison runs
   (`terminal-benchmark-compare.py` -> `terminal-benchmark.sh`) leave it
   empty; only the profiling/monitoring path
   (`terminal-benchmark-profile.sh`) sets it. So the histogram work does not
   run during the runs that produce `faster`/`slower`/`equivalent` verdicts.
3. **No IO on the draw path.** When accounting is active, the draw path only
   increments counters and dictionary entries; the JSON snapshot write
   belongs exclusively to the 100 ms presentation-sampling timer
   (`TerminalBenchmark.swift#publishActivity` and the comment on
   `startPresentationSampling`). The draw-path publish was deliberately
   removed in an earlier revision; the code comments pin that ownership.

**Inferred.** The residual observer effect is confined to profiling runs with
the activity path set: a few dictionary-hash updates per draw on the main
thread, which land in whole-process CPU attribution. Within one run this is
uniform. The one hazard left open is **cross-arm asymmetry**: a profile that
compares two revisions whose *instrumentation code differs* (e.g. parent
without topology accounting vs candidate with it) folds the instrumentation
delta into the CPU comparison. 29/F5's three-arm comparison had this shape;
its margins (roughly 2x effects) dwarf the delta, but the hazard belongs in
the rules, not in per-run vigilance.

**Alternative interpretations.** None material; all three gates are directly
readable in the cited code.

**Confidence.** High; verified against the working tree on 2026-08-03.

**Unlocks.** D4 (the standing gate for instrumentation changes) and the
matching investigation rule in README.md.

## Citations

- macOS SDK `CoreGraphics.framework/Headers/CGContext.h` -- clipping and
  clipping-convenience sections (quoted in F1).
- Local disassembly, CoreGraphics, macOS 26.5.2 (25F84), arm64 -- recipe in
  F2 (basis of F2--F4).
- [CGContextClip](https://developer.apple.com/documentation/coregraphics/1455262-cgcontextclip),
  [CGContextClipToRect](https://developer.apple.com/documentation/coregraphics/1454716-cgcontextcliptorect)
  -- public API docs.
- [QuartzDemo clipping sample](https://developer.apple.com/library/archive/samplecode/QuartzDemo/Listings/QuartzDemo_QuartzClippingView_swift.html)
  -- Apple's equivalence statement (F1).
- [WebKit GraphicsContextCG.cpp](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/graphics/cg/GraphicsContextCG.cpp)
  -- precedent (F5).
- [NSView.draw(_:)](https://developer.apple.com/documentation/appkit/nsview/draw(_:)),
  [NSView.getRectsBeingDrawn(_:count:)](https://developer.apple.com/documentation/appkit/nsview/getrectsbeingdrawn(_:count:))
  -- AppKit dirty-region statements (F6).
- In-repo: `app/SwiftTerminalSessionView.swift#draw(_:)`,
  `app/SwiftTerminalSessionView.swift#terminalDamageMaximalContiguousSpans`,
  `lib/TerminalCore/Sources/TerminalCore/TerminalDamage.swift#TerminalDamageAccumulator`,
  `app/TerminalBenchmark.swift#observeDamageTopology`.
- Ancestor evidence: 29/F2 (bounding-union invalid regions), 29/F3 (per-row
  clip regression and the whole-process CPU rule), 29/F5 (three-arm
  coalescing result), 29/F6 (acceptance stimuli reused here).
