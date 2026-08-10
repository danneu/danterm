# Trackpad-scroll sample: where the CPU goes

Status: open. A single `sample(1)` reading of one heavy-scroll session, kept as
the raw evidence behind three follow-ups. Nothing here has been re-measured or
fixed yet; treat every number as one trace, not a benchmark.

## How it was taken

```
python3 fill.py 10000 179          # 10k lines x 179 cols, randomly styled text
# ... scroll it hard with trackpad swipes for the whole sample window ...
sample "$(pgrep -a 'DanTerm Dev')" 20 -mayDie -fullPaths -file /tmp/sampled.txt
```

DanTerm Dev 0.0.84, macOS 26.5.2, ARM64, physical footprint 225.4M (peak
280.3M). Observed CPU in Activity Monitor during the scroll: up to ~70%.

`sample` collected 16,372 main-thread samples in 20s, so a sample is ~1.22ms and
the main thread's sample count is its wall time. Percentages below are of
main-thread **wall**, not of CPU: a blocked frame still costs a sample.

The randomized per-cell styling is load-bearing for what this trace shows. It
defeats run coalescing in the planner and glyph-strike reuse in CoreText, so the
decoration and glyph-cache numbers are an adversarial upper bound rather than a
typical workload.

## Headline

| | samples | % of wall |
| --- | ---: | ---: |
| Main thread, blocked in kernel (`mach_msg`, `kevent`, `read`) | 9,114 | 55.7% |
| Main thread, on-CPU | 7,258 | 44.3% |

Plus the `CA::CG::Queue` thread at 3,253 samples (~19% of a core) rasterizing
glyphs. Main on-CPU + CA queue is ~63% of one core, which is consistent with the
~70% observed.

The PTY host thread has **39 samples total**. The file was fully ingested before
sampling started, so this trace contains no parsing or feed cost -- it is pure
scroll.

## Main-thread tree

```
16372  main thread
|- 6474  CFRunLoopDoObservers -> CA::Transaction::commit           (39.5%)
|  |- 3984  Layer::display_if_needed
|  |  |- 2640  SwiftTerminalSessionView.draw(_:)                   (16.1%)  <- real CPU
|  |  \-  952  CABackingStoreUpdate -> DisplayList::executeEntries ( 5.8%)
|  \- 2227  Layer::prepare_commit -> CABackingStoreGetFrontTexture
|           \- 2218  kevent_id  [BLOCKED on render server]         (13.5%)
|- 4628  __CFRunLoopServiceMachPort -> mach_msg   [IDLE]           (28.3%)
|- 2825  main-queue drain -> TerminalPaneSessionController.consume (17.3%)
|  |- 1779  planIfNeeded -> FramePlanner.plan                      (10.9%)
|  \- 1016  emitViewportStateIfNeeded -> synchronizeScrollView     ( 6.2%)
|     \-  829  ... -> setFrameSize -> synchronizeGeometry          ( 5.1%)
|        \-  616  Data.init(contentsOf:)  [FONT FILE READ]         ( 3.8%)
\- 1691  NSApplication _handleEvent
   \- 1548  routeCursorRect -> SLSCopyWindowRoutingRecords [BLOCKED] ( 9.5%)
```

## Finding 1: the Nerd Font TTF is re-read from disk on every scroll frame

785 samples (4.8%) in `TerminalRenderMetrics.init`, 616 of them (3.8%) inside
`read(2)`, plus 116 self samples of `__open`.

The path:

```
ScrollableTerminalView.synchronizeScrollView()
  -> NSClipView.scrollToPoint            (958)
  -> NSView _postBoundsChangeNotification
  -> ScrollableTerminalView bounds observer -> NSView.setFrame:
  -> SwiftTerminalSessionView.setFrameSize
  -> SwiftTerminalSessionView.synchronizeGeometry()          (829)
  -> resolvedMetrics(displayScale:)                          (804)
  -> TerminalRenderMetrics.init(...symbolsFontURL:)          (785)
  -> NerdFontSymbolsResource.face(at:pointSize:)
  -> Data(contentsOf: url) as CFData                         (616)
```

`app/SwiftTerminalSessionView.swift#synchronizeGeometry` builds a *fresh*
`TerminalRenderMetrics` on every call, then compares it to `currentMetrics` to
decide whether anything changed. Constructing it costs five `CTFont` creations
plus a whole-file read and
`CTFontManagerCreateFontDescriptorFromData`
(`lib/TerminalCore/Sources/TerminalRenderExecution/NerdFontSymbolsResource.swift#face`).
Its inputs are `(displayScale, fontSize, fontFamily)` -- none of which change
during a scroll -- so every one of those reads answers a question whose answer
was already known.

Recommended fix: memoize metrics on that triple, or at minimum cache the symbols
`CTFont` so the file is read once per process. This is the cheapest win in the
trace by a wide margin and touches no rendering behavior.

## Finding 2: plan + draw are the genuine rendering cost (~25%)

`FramePlanner.plan(reusing:damage:)` -- 1,532 samples (9.4%):

| child | samples |
| --- | ---: |
| `inspectedCells(row:geometry:cursorSpan:)` | 478 |
| `decorationRuns(row:cells:)` | 447 |
| `textRuns(row:cells:)` | 404 |
| `backgroundRuns(row:cells:)` | 52 |

`drawRenderFrame(_:metrics:in:)` -- 2,822 samples (17.2%):

| child | samples |
| --- | ---: |
| `CGContextRef.drawTextRuns` | 1,504 (of which `draw_glyphs` 949) |
| `CGContextRef.drawDecorationRuns` | 805 (`CGContextFillRect`/`FillRects` 307) |
| `CGContextFillRect` (backgrounds) | 257 |
| `create_color` | 181 |

Two smells:

- **Decoration fills dominate more than they should.** 805 samples for
  underline/strikethrough against 1,504 for all glyph drawing. With randomized
  styling the decorations do not coalesce into runs, so each becomes its own
  `CGContextFillRect`, and CoreGraphics re-derives fill state per rect:
  `CGColorCompare` 233 self samples, `CG::CompareEntryStateDrawing` 132,
  `CG::DisplayList::getEntryFillState` 101. Worth checking whether adjacent
  same-style decorations are being merged, and whether the fills can be batched
  into a single `CGContextFillRects` call per color.
- **Per-run color re-resolution.** Inside `drawTextRuns`,
  `RenderColor.cgColor(in:)` (75), `Dictionary.subscript.getter` (29) and
  `Dictionary.emptyValuesKeepingCapacity()` (23) point at a color dictionary
  being consulted (and possibly reallocated) per run. `resolveCellStyle` is 220
  inclusive / 103 self, and `pow` shows 86 self samples with
  `RenderANSIColors.subscript.getter` at 75 -- color-space math running per cell
  rather than once per distinct color. A per-frame resolved-color table would
  fold most of this away.

## Finding 3: ~23% of main-thread wall is blocked, not busy

- **2,218 samples (13.5%)** in `CABackingStoreGetFrontTexture` ->
  `_dispatch_sync_f_slow` -> `kevent_id`. The main thread is stalled waiting for
  the CA render queue to hand back the front texture -- back-pressure from
  finding 2's rasterization. The `CA::CG::Queue` thread's own top costs are
  `TGlyphOutlineDictionaryCache::Copy` (428, 13.2% of that thread),
  `_platform_memmove` (311) and `CA::OGL::GlyphCache::emit_glyphs` (151): glyph
  cache churn from many distinct font/style strikes. Reducing distinct strikes
  (or moving to a glyph atlas we own) shortens this stall as a side effect.
- **1,548 samples (9.5%)** in `SLSCopyWindowRoutingRecordsForScreenLocation`, a
  synchronous mach IPC to WindowServer, reached via
  `NSApplication.sendEvent:` -> `routeCursorRect` -> `_NSFindWindowUnderMouse`.
  This fires per scroll event because a cursor rect is registered. If per-event
  cursor-rect routing is not needed during scroll, `discardCursorRects` (or not
  installing the rect) recovers most of it. It is blocked time rather than CPU,
  but it serializes against event delivery, so it is paid in scroll latency.

## What this trace exonerates

The retained-row and history work is not the bottleneck here.
`Terminal.PackedRetainedRow.forEachContentCell` is 53 self samples,
`PackedRetainedRow.u64` is 32, and `Terminal.forEachViewportCell` is 466
inclusive -- and most of that 466 is the planner closure running per cell, not
row decoding. Geometry re-derivation (finding 1) and CoreGraphics glyph/fill
throughput (findings 2 and 3) are what cost the scroll.

## Caveats before acting

- One trace, one machine, one adversarial input. Re-measure with a controlled
  before/after per
  [agent-docs/measurement-discipline.md](../../agent-docs/measurement-discipline.md)
  before claiming any of these as improvements.
- The randomized styling inflates decoration and glyph-cache costs relative to
  ordinary terminal output. Finding 1 is style-independent; findings 2 and 3 are
  not.
- Sample attributes blocked time to whatever frame is on top, so the two
  "blocked" entries in finding 3 are latency, not CPU, and will not show up in a
  CPU-time profiler the same way.
