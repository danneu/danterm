# F2 -- TerminalRenderExecution on iOS

<!-- The paths below are deliberately gone; this doc records them as history. -->
<!-- docs-lint: allow-missing .claude/worktrees/t2-render-execution-ios -->

Promoted to its own file per [FORMAT.md](../FORMAT.md) because it carries an
itemization table, a running-app result, and three screenshot artifacts.
Referenced from [findings.md](findings.md) as `F2`.

### F2 -- the render executor needs one font seam, and the IOSurface swapchain works on iOS

- Status: settled for the simulator; the device triple is a compile result only.
  Closes the open half of H1. Rejects H2's premise -- see the inference below.
- Date and investigator: 2026-08-12, agent (T2).
- Commit and worktree state: `38676539`, in the worktree
  `.claude/worktrees/t2-render-execution-ios`. The tree is clean apart from the
  spike package and this document; the iOS platform pin and the font seam are
  applied and restored by the reproduction script, never committed, for the
  reason F1 records.
- Environment: Xcode 26.6 (17F113), Swift 6.3.3, iOS 26.5 SDKs. Simulator triple
  `arm64-apple-ios26.5-simulator`, device triple `arm64-apple-ios26.5`.
  Simulator: iPhone 17 Pro, iOS 26.5, `displayScale` 3.0.
- Commands, inputs, or reproduction:
  [ios-render-spike.sh](ios-render-spike.sh), from any directory. It applies the
  iOS pin and the font seam, builds the module for the device triple, builds the
  spike app for the simulator triple, assembles a flat iOS `.app` by hand,
  installs and launches it with `simctl`, and takes three screenshots. There is
  no Xcode project and no `xcodebuild` in the recipe: `swift build` compiles, the
  script assembles the bundle the way `build-app.sh` assembles the macOS one, and
  `simctl` runs it. Simulator only, so no signing and no provisioning.
- Result or artifact paths: the spike source is
  [ios-render-spike/](ios-render-spike/) (a scratch package, deliberately not in
  `lib/`). Screenshots are committed under [f2-artifacts/](f2-artifacts/):
  [first-frame.png](f2-artifacts/first-frame.png),
  [after-in-place-mutation.png](f2-artifacts/after-in-place-mutation.png),
  [after-reattach.png](f2-artifacts/after-reattach.png). The console log, the
  assembled bundle, and the SwiftPM build trees land in `.build-ios-t2/` at the
  repository root (gitignored; regenerate with the script).

#### Measurements or examples -- the AppKit itemization

The module names exactly one AppKit symbol. Building it for
`arm64-apple-ios26.5-simulator` with `import AppKit` replaced by `import UIKit`
and nothing else changed produces two errors, both on the same line:

```
TerminalRenderExecution.swift:94:16: error: cannot find 'NSFont' in scope
TerminalRenderExecution.swift:94:71: error: cannot infer contextual base in reference to member 'regular'
```

The reported line is 94 because the conditional import that replaced
`import AppKit` is four lines longer. In the unpatched tree the same line is
`TerminalRenderExecution.swift:90`, and it is the whole port:

```swift
?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular).fontName
```

`UIFont` answers both `monospacedSystemFont(ofSize:weight:)` and `fontName`
identically, so the seam is a `typealias PlatformFont` behind
`#if canImport(AppKit)` plus that one call site. With the seam applied, the
module builds for the simulator triple, the device triple, and macOS.

The rest of the module's iOS status, symbol by symbol:

| Symbol or type | Framework | iOS status |
|---|---|---|
| `NSFont.monospacedSystemFont(ofSize:weight:)`, `.fontName` | AppKit | The only AppKit dependency. Replaced by `UIFont`, same spelling. |
| `NSAttributedString`, `NSAttributedString.Key` | Foundation | Portable as-is. Despite the `NS` prefix these are Foundation, not AppKit; the module uses them only as the dictionary key type for `kCTFontAttributeName` and friends. No change. |
| `CTFontCreateWithName`, `CTFontGetGlyphsForCharacters`, `CTFontGetAdvancesForGlyphs`, ascent/descent/leading/underline/x-height metrics, `CTLineCreateWithAttributedString`, `CTFontCopyGraphicsFont` | CoreText | Portable as-is. |
| `CGContext`, `CGImage`, `CGDataProvider`, `CGColorSpace`, `CGBitmapInfo`, path and clip calls | CoreGraphics | Portable as-is. |
| `IOSurface(properties:)`, `.baseAddress`, `.bytesPerRow`, `.lock/.unlock`, `.isInUse` | IOSurface | Portable as-is. The framework is public on iOS and every call the store and swapchain make compiles and runs. |
| `TerminalFrameBackingStore` | -- | **Ported as-is, zero changes.** Allocates, renders, and blits on the simulator. |
| `TerminalFrameSwapchain` | -- | **Ported as-is, zero changes.** Allocates its three buffers and returns a store from `publish(plan:damage:)`. |
| The nine `*Sprite.swift` files | CoreGraphics | Portable as-is; they import CoreGraphics and `TerminalSpriteGeometry` only. |
| `NerdFontSymbolsResource` | CoreText, Foundation | Compiles as-is. Its *lookup* has an iOS bundle-layout condition -- see below. |

#### Measurements or examples -- the running app

One static `RenderFramePlan` (57x12, 19 text runs, cursor visible), rendered once
into one `TerminalFrameBackingStore`, presented three ways at once:

```
SPIKE displayScale=3.0
SPIKE metrics cell=(7.0, 13.333333333333334) pixels=21x40
SPIKE plan 57x12 textRuns=19 bgRuns=2 cursor=true
SPIKE store ok ioSurface=1197x480 bytesPerRow=4864
SPIKE PROBE-INK non-background pixels in the rendered store: 49102
SPIKE PROBE-SWAPCHAIN allocated=true published=true
SPIKE PROBE-A CGImage assigned to layer.contents; contents is nil: false
SPIKE PROBE-B IOSurface assigned to layer.contents; retained by CoreAnimation: true
SPIKE PROBE-C blit into a UIKit context produced non-background pixels: 49102
SPIKE PROBE-INUSE right after attach, ioSurface.isInUse=false
SPIKE PROBE-D rendered a second plan into the same store; nothing reattached
SPIKE PROBE-INUSE while attached, ioSurface.isInUse=true
SPIKE PROBE-E reattached the same IOSurface as layer.contents
```

[first-frame.png](f2-artifacts/first-frame.png) shows all three panels rendering
the same frame identically: colors, bold, italic, underline, reverse video,
box-drawing and block-element sprites, powerline and braille sprites, packaged
Nerd Font private-use glyphs, and the cursor. The surface's row stride is
padded (4864 bytes for 1197 px), exactly as the store's comment says to expect.

Probes D and E separate two things the macOS design keeps together. Probe D
mutates the store's pixels in place and reattaches nothing:
[after-in-place-mutation.png](f2-artifacts/after-in-place-mutation.png) shows
panel B still displaying the first frame, so CoreAnimation is not re-sampling
the surface on its own. That file is byte-identical to
[first-frame.png](f2-artifacts/first-frame.png): between the two captures the
store's pixels were completely rewritten and the screen did not change by one
byte. Probe E then reassigns the same surface as
`layer.contents`, and [after-reattach.png](f2-artifacts/after-reattach.png)
shows panel B alone switching to the second frame while A and C, which hold
copies, do not. Attach-to-publish is exactly what `TerminalFrameSwapchain` does.

`isInUse` reports `false` immediately after assignment, before the transaction
commits, and `true` four seconds later while the surface is on screen -- the
same shape the macOS swapchain's acquisition logic assumes.

#### Observation

The `import AppKit` that stopped F1 hid almost nothing. One symbol behind it is
unavailable on iOS, on one line, and the substitute has the same spelling.

#### Observation

`TerminalFrameBackingStore` and `TerminalFrameSwapchain` are neither stubbed nor
replaced: they compile, allocate, render, publish, and display on iOS with no
source change at all. The IOSurface-backed design has a direct iOS analogue --
it is the same API.

#### Observation

The packaged Nerd Font symbols face does not load from a naively assembled iOS
bundle, and fails silently as tofu rather than as an error. The first assembly of
this spike copied SwiftPM's generated `TerminalCore_TerminalRenderExecution.bundle`
beside the executable; every private-use glyph rendered as a missing-glyph box.
`NerdFontSymbolsResource.packagedURL()` looks in `Bundle.main` at
`NerdFontsSymbolsOnly/SymbolsNerdFontMono-Regular.ttf` first and then, when
`Bundle.main` is a `.app`, deliberately returns nil rather than consulting
`Bundle.module`. Copying the `.ttf` into the app bundle at that path -- what
`scripts/bundle-theme-resources.sh` does for the macOS app -- fixed it. This is
a bundle-assembly requirement for any real iOS client, not a portability defect.

#### Inference

H1's `TerminalRenderExecution` clause is confirmed and was slightly pessimistic.
It predicted "an `NSFont`/`UIFont` seam and a decision about the IOSurface-backed
swapchain". The seam is real and is one typealias. There is no swapchain decision
to make: the swapchain ports unchanged.

#### Inference

H2's framing no longer fits the evidence. It asks whether CPU-composed frames
present acceptably "without IOSurface", with a `CVPixelBuffer`/`CAMetalLayer`
path as the competing explanation because that would be "the closer analogue to
the existing N-buffer swapchain". The existing N-buffer swapchain is available
verbatim, so the choice T3 must measure is not "CGImage vs a substitute for the
swapchain" but "CGImage copy per frame vs the actual swapchain, both on iOS".
D2 should be restated against those two, and the ideal -- one presentation
implementation shared by both platforms, since the pane owns its pixels on
either -- is now on the table rather than aspirational.

#### Inference

The whole render stack the client needs is portable: with F1's six modules and
this one, nothing in the engine or presentation path requires a second
implementation for iOS. What remains platform-specific is the ~200 lines of view
shell H1's candidate direction already scoped -- `CADisplayLink` in place of
`CVDisplayLink`, UIKit view lifecycle, and touch input.

#### Competing interpretations

The simulator is not the device. Simulator CoreAnimation runs against the Mac's
own render server and GPU, so "IOSurface displays as layer contents" could in
principle be a simulator affordance that a real device does not share. Nothing
here rules that out; the device triple result in this finding is a compile, not a
run. This is the single most important thing T3 should confirm first, before it
measures anything, because the D2 restatement above depends on it.

#### Competing interpretations

A render is not a session. This finding presents one static frame; it says
nothing about sustained publish rates, incremental `apply` paths under real
damage, scroll translation correctness on iOS, or energy. `renderFull` and
`blit` ran; `apply`, `translateRows`, and the swapchain's acquisition rotation
were exercised only to the extent that one `publish` exercises them.

#### Uncertainty

`isInUse` was sampled twice, seconds apart, not under the tight
publish-attach-retry cadence the swapchain actually runs. The macOS contract --
"a detached surface reported free stays free" -- is pinned by
`tests-ui/IOSurfaceLayerContentsTests.swift` against real AppKit. There is no
equivalent iOS pin, and this finding does not establish one.

#### Uncertainty

Font parity is untouched. The spike used the system monospace font at 11pt; the
user's configured family and its ligature behavior on a phone remain the open
question the README already records.

#### Uncertainty

`DanTermSupport` still exports nothing (F1), so the spike could not link the
IPC or tape-follow half. The spike drives a local `Terminal` with literal bytes
instead. T16 owns that.

#### Next action

- T3 runs on a real device and confirms, before measuring, that probe B holds
  there. If it does, T3's comparison is `CGImage` per frame against
  `TerminalFrameSwapchain` unchanged, not against a `CAMetalLayer` substitute.
- D2 is restated against those two candidates.
- T16 gains a second item: whatever ships the packaged symbols face into an iOS
  bundle, since `packagedURL()`'s `.app` branch is the reason a naive assembly
  fails silently.
- The font seam itself lands with the iOS platform pins, in T16, not here.
