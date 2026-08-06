# Packaging TerminalCore for external consumers (macOS + iOS)

Scratch notes, 2026-08-05. Question: what would it take to publish DanTerm's
Swift terminal engine so other projects can build their own terminal app on it
(the way DanTerm and Ghostty.app both build on libghostty)? Plus: performance
considerations at the module boundary, and the added requirement that the core
must also work in an iOS app.

Not a plan file. Findings + recommendations.

Updated 2026-08-05 (second pass): distribution shape resolved (generated mirror
repo), naming resolved (`DanTerm*` products), a three-product lineup proposed,
and the `TerminalPaneSession` coupling audit **done** -- see "iOS", item 4.

Two sections near the end are for whoever picks this up next: "Open questions"
lists what should be settled by building the sample rather than by more
argument, and "Notes for future brainstormers" records the reasoning mistakes
this doc already made once.

## What's already true in the tree

Verified against the manifests and sources, not assumed:

- `lib/TerminalCore/Package.swift` -- 8 library products + 8 executables, all
  `.swiftLanguageMode(.v6)`, **zero `unsafeFlags`**, zero external dependencies.
- `TerminalCore` itself imports **nothing** -- not even Foundation.
- Layering is clean: `TerminalCore` -> `TerminalRenderPlanning` (TerminalCore
  only) -> `TerminalRenderExecution` (AppKit/CoreGraphics/CoreText + resources).
- `lib/TerminalPTY` references `DanTermProtocol` **only from a test target**
  (`lib/TerminalPTY/Package.swift:117`), so its shipped products are already
  app-free.
- `Terminal` is `Equatable, Sendable`; ~30 public structs / 19 public enums.

The hard part is done. What remains is distribution shape, API hygiene, the
cross-module boundary, and the iOS split.

## Gaps to close

### 1. Repo shape -- the blocking one -- RESOLVED: generated mirror

SwiftPM can only resolve a git dependency whose `Package.swift` is at the
**repo root**. There is no monorepo-subpath support. `lib/TerminalCore` is
unreachable as `.package(url:)` today.

**Decision: a generated read-only mirror repo.** The monorepo stays the only
place code is authored and the only place commits happen; CI projects `lib/`
to the root of `danneu/danterm-engine`, which is build output that happens to
be a git repo. Atomic cross-project commits are preserved because the mirror
isn't a project. Consumers write a completely ordinary
`.package(url: ".../danterm-engine", from: "1.0.0")`. No registry.

Two ways to generate it:

- **Snapshot export** -- copy the directory into a clean clone, commit
  "sync from danterm@<sha>", tag, push. ~15 lines of shell, no failure modes,
  no history fidelity. Start here.
- **Subtree split** -- `git subtree split --prefix=lib/TerminalCore`. Preserves
  per-file history, deterministic, needs `.git/subtree-cache` to stay fast.
  Only if `git blame` on the mirror is ever actually missed.

The mirror carries its own tags (`1.0.0`), which is gap #2 solved for free:
the engine's semver namespace is literally a different repo's tag namespace.

Rejected: splitting PTY into a second repo (one package with a platform matrix
is right -- iOS consumers just never depend on the PTY product); a Swift Package
Registry (adds hosting); consumers submoduling the monorepo and using
`.package(path: "vendor/danterm/lib/TerminalCore")` -- that needs zero new
repos and the submodule SHA is a real pin, but every consumer clones the whole
app and there's no semver. Tolerable while the only consumer is us, and not
after that.

**Note the asymmetry with Ghostty:** Zig's `build.zig` is at the repo root, so
Ghostty exports a dozen artifacts from a monorepo with no friction at all. The
mirror is a workaround for a SwiftPM limitation, not a design choice worth
copying from them.

### 2. Its own version namespace

`v0.0.84` is the app's tag. The engine needs independent semver, because the
moment someone pins it, the public surface becomes a contract. Solved by the
mirror (gap #1): different repo, different tag namespace, no collision.

**Naming decision.** Brand it. The `swift-` prefix (`swift-collections`,
`swift-nio`) is Apple/SSWG house style, not a general Swift convention --
independent packages overwhelmingly use brand names (Alamofire, Kingfisher,
GRDB, Sourcery), and `libghostty` is branded with its app name without anyone
being confused about what Ghostty.app embeds. Package/repo `danterm-engine`;
products `DanTermVT`, `DanTermRender`, `DanTermPTY`. `VT` names the subsystem
the way `ghostty-vt` does, which also avoids a
`DanTermTerminalCore`-next-to-`DanTermCore` stutter.

Note that package name and module name can differ, so the cheap version is to
brand only the `.library(name:)` and leave modules as `TerminalCore` et al --
the `swift-collections`/`OrderedCollections` pattern. Cheaper, but the brand
never appears at call sites, which is probably the half worth having. Renaming
modules is a real mechanical diff; decide before tagging 1.0, since it's the
one thing semver won't let us fix later.

### 3. Public vs `package` access

There is exactly **one** use of the `package` access modifier across
`lib/TerminalCore/Sources`. Every cross-target seam inside the package is
spelled `public`, so internal plumbing *is* the published API. Sweep it:
anything only `TerminalRenderPlanning` / `TerminalRenderExecution` needs from
`TerminalCore` becomes `package`, and what's left is the intended API.

**Better mechanism, stolen from Ghostty:** `src/lib_vt.zig` is a hand-curated
re-export facade whose header says it "reproduces a lot of `terminal/main.zig`
but is separate because we may want to withhold parts of `terminal` that are
not ready for public consumption or are too Ghostty-internal." Do that: one
`API.swift` per stable product that re-exports the intended surface, everything
else drops to `package`. The published surface becomes one reviewable file
instead of an emergent property of ~30 scattered `public` declarations.

### 4. Strip DanTerm identity from the engine

Baked in as literals, not config:

- `TERM_PROGRAM=DanTerm` (`TerminalPaneLaunch.swift:104`)
- XTVERSION reply `DanTerm \(programVersion)` (`Terminal.swift:4538`)
- The `DanTermShell=1` OSC selector (`Terminal.swift:1393`,
  `dispatchDanTermShell`)
- `NeutralTerminalRecording.danTerm(test:)` provenance, `DANTERM-BENCH-*`
  markers

A host app needs to supply its own program name/version and shell-integration
selector. Turn them into an injected `TerminalHostIdentity` (neutral default),
or the library announces itself as DanTerm to every consumer's shell.

### 5. Split off the dev tooling

**Corrected count:** the package ships **8 library products and 8 executables**,
not the 6/5 in the first pass. Executables: `TerminalCoreBenchmark`,
`TerminalDrawBenchmark`, `GlyphPreview`, `TerminalMemoryProbe`,
`TerminalOccupancyProbe`, `TerminalBrowseBenchmark`, `TerminalResizeProbe`,
`TerminalRetainedRowProbe`. All get built by consumers' `swift build` and drag
AppKit into the graph.

Worse: `TerminalBenchmarkMarkers`, `TerminalBenchmarkTopology`, and
`TerminalBenchmarkCoverage` are shipped `.library` products, so the benchmark
harness's API is currently part of the public contract. The dev-tools cut is
bigger than "move the executables."

Move all of it to a sibling `danterm-engine-devtools` package. **Dependency
direction matters:** devtools depends on the engine, never the reverse. A
root-manifest `.package(path: "DevTools")` would make every consumer resolve
and build it, undoing the entire point.

### 6. License + the bundled font

No `LICENSE` at the repo root. Also
`Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly/SymbolsNerdFontMono-Regular.ttf`
is a 2.5 MB binary redistributed into every consumer app. There's a `LICENSE`
next to it -- surface it in top-level licensing.

**Preferred fix: don't embed it at all.** Have `DanTermRender` take a symbol
font from the host and ship the Nerd Font in `Examples/MiniTerm` instead. That
removes a product *and* the redistribution-licensing obligation, at the cost of
one README paragraph for adopters. Fallback if the ergonomic hit is too rough:
a separate opt-in `DanTermNerdFont` product. Try host-supplied first. (See iOS
section: on iOS this is straight app download size, so it goes from
nice-to-have to necessary either way.)

### 7. `exact:` pins are hostile to consumers

`lib/TerminalPTY/Package.swift:19` pins `swift-collections` at
`exact: "1.6.0"`. Any consumer who also uses swift-collections at a different
version gets an unresolvable graph. Use `.upToNextMinor(from: "1.6.0")`.

### 8. Platform floor

`.macOS(.v26)` is deliberate for DanTerm, brutal for adopters. Decide
consciously rather than inheriting. With iOS added, becomes
`platforms: [.macOS(.v26), .iOS(.v26)]` -- and Catalyst / visionOS are close to
free if CoreText is the rendering substrate.

### 9. Prove it with a sample app

The real test is a `MiniTerm` demo depending *only* on the published products --
the Ghostty.app-to-libghostty analogue. It will immediately surface every API
currently reached around via same-module access. Ship it in-repo (`Examples/`)
so CI keeps it honest.

### 10. Standalone CI + docs

Verify `swift build && swift test` in a *bare* clone of just the package
(fixtures live under `Tests/TerminalCoreTests/Fixtures`, so this should work,
but it was not confirmed). Add a README with an embed-a-terminal walkthrough
and a DocC catalog.

## Performance across the module boundary

`docs/design/2026-07-29-cross-module-value-dispatch.md` measured
`TerminalScalars`'s unannotated `RandomAccessCollection` surface at **20.6% of
the draw region**; annotating it bought **-19.98% / -20.41% / -12.94%**. That
was across *our own* targets. A third-party render loop crosses the same
boundary, and their side can't be fixed by refactoring ours.

### Constraints

- **Conservative CMO has been on by default in SPM release builds since Swift
  5.8.** It serializes and specializes *generic* functions across module
  boundaries automatically. It does **not** cover non-generic public accessors
  on value types -- exactly the cost the profile found.
- **Aggressive CMO (`-cross-module-optimization`, `-enable-cmo-everything`) is
  only reachable via `.unsafeFlags` -- and `.unsafeFlags` makes products
  ineligible as a versioned dependency of any other package.** Hard wall, and
  the single most important packaging constraint: those flags cannot ship.
  `@inlinable` + `@usableFromInline` is the only supported lever. Consumers who
  want aggressive CMO must pass `-Xswiftc` on their own build.
- **Do not enable library evolution (`-enable-library-evolution`).** It's for
  binary-stable frameworks and it *pessimizes* everything -- resilient (opaque)
  value-type layout, no cross-module inlining of non-`@frozen` types. Ship
  source, not an xcframework. This is where the libghostty analogy misleads:
  libghostty is a binary C-ABI artifact, which works because C has a stable ABI.
  The Swift equivalent costs exactly the optimization that matters here.
- Because distribution is **source**, `@inlinable` carries no ABI hazard --
  every consumer recompiles. It's cheap here in a way it isn't for Apple's own
  frameworks.

### Actions

1. Only 2 files in `TerminalCore` currently carry any of
   `@inlinable` / `@usableFromInline` / `@frozen` (16 occurrences, i.e.
   `TerminalScalars`). Audit the *public* hot path -- per-cell/per-row
   accessors, index arithmetic, `Collection` conformances -- and annotate it
   before adopters build render loops on top.
2. **Keep hot entry points concrete, not generic.** A generic public entry point
   handed an unspecialized type from a consumer module goes through witness
   tables and type metadata, and it will never show up in *our* profile.
3. **Prefer batched API shapes over per-cell accessors.**
   `forEachViewportCell(row:_:)` -- one cross-module call per row with per-cell
   work kept inside the module -- avoids the mechanism instead of paying to
   annotate around it. Highest-leverage item on the list, because API shape is
   the one thing semver won't let you fix later.

   **The concrete target is `RenderFramePlan`.** It is five arrays
   (`backgroundRuns`, `selectionRuns`, `searchMatchRuns`, `textRuns`,
   `decorationRuns`) allocated per frame and handed across a module boundary --
   exactly the traffic the 2026-07-29 doc measured. Publishing it freezes that
   shape for every adopter. Whatever batched/borrowed form it should have,
   decide it before 1.0.
4. Wire the existing benchmarks into the package's own CI as a gate, so a
   public-API change doesn't silently regress downstream.

## iOS

### The layering already survives the port

| Target | Imports | iOS-ready? |
|---|---|---|
| `TerminalCore` | *nothing* | Yes, as-is |
| `TerminalRenderPlanning` | `TerminalCore` only, zero platform types | Yes, as-is |
| `TerminalSpriteGeometry` | `Foundation` | Yes, as-is |
| `TerminalRenderExecution` | AppKit, CoreGraphics, CoreText | ~1 line of work |
| `TerminalPTY` | `openpty`, `posix_spawn`, `fork`, `execve`, `ioctl` | **Never** |

There are currently **zero** `#if os(...)` / `canImport` guards anywhere in
`lib/TerminalCore/Sources`. That's a feature. Keep it that way in
`TerminalCore` and `TerminalRenderPlanning` permanently.

### TerminalRenderExecution's AppKit dependency is essentially one line

The whole 2011-line target uses exactly two AppKit-ish names:
`NSAttributedString` (10 sites) and `NSFont` (1 site). But `NSAttributedString`
and `NSAttributedString.Key` are *Foundation*, available on iOS, and every
attribute key passed is a portable CoreText constant (`kCTFontAttributeName`,
`kCTForegroundColorAttributeName`, `kCTLigatureAttributeName`). Everything doing
real work is `CTFont` / `CTLine` / `CGContext` / `CGGlyph`.

The single genuine AppKit call is `TerminalRenderExecution.swift:82`:

```swift
?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular).fontName
```

That's a *default-font policy* decision sitting inside a renderer. Hoist it out
-- have the host supply the fallback font name -- and `import AppKit` becomes
`import Foundation` with no platform guard at all. Right fix regardless of iOS.

### The real blocker: iOS has no PTY

Third-party iOS apps cannot `fork`/`exec`. `posix_spawn` is denied by the
sandbox and `openpty` can't reach `/dev/ptmx`. `TerminalPTY` is macOS-only,
forever; no restructuring changes that.

So the engine's public boundary has to be **bytes in / bytes out**, with process
spawning as one *optional, macOS-only* implementation. `TerminalCore` already is
that boundary -- `feed(_ bytes: [UInt8])` / `drainReplyBytes() -> [UInt8]`, no
imports. The work:

1. Define the byte-source seam as a protocol in a small platform-neutral target
   (`TerminalSessionKit` or similar): give me bytes, take my bytes, tell me
   about resize and EOF.
2. Make `TerminalPTY` one conformance of it, `.macOS`-only.
3. iOS consumers bring their own conformance -- SSH (swift-nio-ssh), mosh, a
   WebSocket to a remote agent, or a bundled interpreter.
4. **`TerminalPaneSession` PTY coupling -- AUDITED, and it is coupled.**
   `TerminalPaneSession.swift:221` holds `private let host: TerminalPTYHost`
   and constructs it internally at `:311`. No protocol, no injection;
   `TerminalPTYHost` is a manifest-level dependency of the target
   (`lib/TerminalPTY/Package.swift:41`).

   The good news is the *shape*: it's a stored property plus a factory method,
   not PTY concepts smeared through the logic. So the refactor is one type's
   dependency inverted -- extract the protocol, make `TerminalPTYHost` one
   conformance, have `TerminalPaneSession` hold the protocol -- rather than a
   redesign. Wants a full read of the file before that's promised, but the
   shape is favorable.

   This is the **highest-value item on the entire list**: it is simultaneously
   the iOS unlock, the reason the session-seam target exists at all, and the
   natural home for the host-identity config (gap #4) and the host-supplied
   scrollback budget (jetsam note below).

### Other iOS consequences

- **Scrollback budget is hardcoded.** `Terminal.swift:737`:
  `public static let productionScrollbackBudgetBytes = 10_485_760`. 10 MB per
  pane is fine on a Mac; on iOS with jetsam watching it needs to be a
  host-supplied value, not a `static let`. This is an API-shape decision -- fix
  it before tagging 1.0.
- **The 2.5 MB Nerd Font matters much more.** On iOS that's straight app
  download size. Separate opt-in product becomes necessary, not optional.
- **Testing:** `swift test` can't run an iOS test bundle. Needs
  `xcodebuild test -destination 'platform=iOS Simulator,name=...'` as a second
  gate step in `scripts/run-test-suite.sh`, plus a simulator build in CI to
  catch accidental AppKit reintroduction. Cheap belt-and-braces: a CI step that
  greps the portable targets for `import AppKit`.
- **Renderer headroom:** the CoreText / `CGContext` path is portable, but an
  iPad at 120 Hz with a large grid is a tighter budget than a Mac. The
  `RenderPlanning` / `RenderExecution` split means a Metal executor can be
  written later against the same `RenderFramePlan` without touching the planner.
  Don't build it now -- just don't let anything platform-specific leak back into
  the plan type.
- **CMO and binary size:** the one caveat the Swift Forums CMO thread flags
  specifically for mobile is binary size from aggressive inlining. That lands
  conveniently: since `.unsafeFlags` bars shipping `-cross-module-optimization`
  anyway, we're already restricted to `@inlinable`, which is per-declaration.
  Use that granularity deliberately -- annotate the measured hot surface, not
  the API sweepingly.

## How Ghostty divides itself

Read from the pinned `.ghostty-src/` checkout at 1.3.1. Everything is in **one
repo**; the split is by build artifact, not by repo.

| Artifact | Kind | What it is | Stability |
|---|---|---|---|
| `ghostty` | executable | The app, one binary per apprt (GTK, macOS). | product |
| `libghostty` | `.so`/`.a` + `include/ghostty.h` | The big internal library: terminal + renderer + termio + font + input + config + apprt surface. What `GhosttyKit.xcframework` wraps. | `build.zig#build`: "not stable for general purpose use" |
| `libghostty-vt` | `.so`/`.a` + `include/ghostty/vt.h` + `.pc` | The extracted VT engine: parser, screen, pagelist, styles, OSC/DCS/APC, selection, search. No renderer, no PTY, no config. | "functionality extremely stable, API may change without warning" |
| `ghostty-vt` | Zig module | Same code, for Zig consumers. | same |
| `ghostty-vt-c` | Zig module | Same, built `c_abi = true`; what the C artifact is generated from. | same |
| `src/lib/` | internal | C-ABI binding machinery (allocator, string, struct, enum, union shims). | internal |

Two things worth stealing beyond the names: the curated `src/lib_vt.zig` facade
(see gap #3), and headers namespaced as a tree -- `ghostty/vt.h`,
`ghostty/vt/osc.h`, `ghostty/vt/key/encoder.h`. Brand is the directory,
subsystem is the path.

### Mapping

| Ghostty | DanTerm today | Proposed |
|---|---|---|
| `ghostty` | `DanTerm.app` | `DanTerm` (unchanged) |
| `ghostty-vt` | `TerminalCore` | `DanTermVT` |
| curated in `src/lib_vt.zig` | *nothing* | `DanTermVT/API.swift` |
| `ghostty-vt-c` | *nothing* | *skip* -- only for non-Swift consumers; defer past 1.0 |
| `libghostty` `renderer/` | `TerminalRenderPlanning` + `TerminalRenderExecution` | `DanTermRender` (both stay separate *targets*) |
| `libghostty` `font/` | `TerminalSpriteGeometry` | folded into `DanTermRender` |
| `src/pty.zig` + `termio/` | `TerminalPTY` | `DanTermPTY` (macOS only) |
| `src/benchmark/` | 8 executables + 3 benchmark libs | sibling `danterm-engine-devtools` |
| `libghostty` (the big one) | -- | **no analogue, deliberately.** It exists because Zig->Swift needs a C ABI boundary; we're Swift on both sides. |
| `macos/` | `app/` + `DanTermCore` + `DanTermSupport` | unchanged |

Divergences that matter: Ghostty gets monorepo + clean external consumption for
free (root `build.zig`); we generate a mirror to get both. And `libghostty-vt`
has no iOS story and never needed one -- our VT/PTY split is a platform
boundary, which is a stronger reason to keep them separate products than
Ghostty ever had.

## Proposed product lineup

One package, `danterm-engine`. **Three products.**

The first draft of this section had eight, which was a mistake: it transcribed
Ghostty's internal artifact list instead of asking what needs to be separately
dependable. Ghostty in fact publishes exactly *one* public artifact
(`libghostty-vt`).

**Targets are not products.** The internal layering stays exactly as it is --
same targets, same seams, same test boundaries. A *product* is a unit someone
can depend on without the others, and it earns existence only if depending on
it separately avoids a real cost.

| Product | Bundles targets | Cost it lets a consumer avoid | Platforms | Tier |
|---|---|---|---|---|
| `DanTermVT` | `TerminalCore` (parser, screen, pagelist, styles, selection, search, OSC/DCS/APC, `feed`/`drainReplyBytes`), the input encoders, the session protocol + `TerminalHostIdentity` | none -- this is the floor | all | stable |
| `DanTermRender` | `RenderPlanning`, `RenderCoreText`, `SpriteGeometry` | CoreText / CoreGraphics / font machinery, if you only want VT state | all | provisional |
| `DanTermPTY` | `PTYHost`, `PaneSession`, `PaneLifecycle` | swift-collections -- and **existing at all on iOS** | **macOS** | stable |

### What didn't earn a product, and what would change that

| Candidate | Why not | Promotion criterion |
|---|---|---|
| `DanTermSession` | A protocol and two config structs. Nothing is avoided by depending on it alone -- it lives *in* `DanTermVT`. The extraction refactor is still the top-value work; it just doesn't need its own product. | never, realistically |
| `DanTermRenderPlan` split from the executor | Justified only by a hypothetical Metal backend. Keep the *targets* split so the seam survives. | the day a second executor exists |
| `DanTermSprites` | Nobody wants glyph geometry without a renderer. | an adopter shipping their own executor |
| `DanTermVTRecording` | A testing convenience, not an adopter need. | an adopter asks for replay/fixtures |
| `DanTermNerdFont` | See gap #6 -- prefer removing the embedded font entirely over shipping a product to opt out of it. | the host-supplied-font ergonomics prove too painful |

**The asymmetry that settles it:** adding a product later is a minor bump;
removing one is a major bump. Every product shipped at 1.0 is a promise. Start
at three and grow on demand.

### What `DanTermRender` actually is

Worth stating plainly, because the name undersells it and it bundles two
things with quite different reuse profiles.

**The planner (~1290 lines)** answers *what marks go where*. `planFrame()` takes
terminal state plus a `RenderPresentation` (theme, cursor shape, visibility) and
returns a `RenderFramePlan`: columns, rows, the three background colors, then
`backgroundRuns` / `selectionRuns` / `searchMatchRuns` / `textRuns` /
`decorationRuns` / `cursor`. Nothing in it is CoreText, AppKit, or a pixel --
it is a **backend-agnostic display list** of runs with resolved RGB. Getting
there is the work nobody wants to redo: merging cells into style runs, resolving
SGR plus a 16-color palette into concrete colors, selection and search-match
overlay spans, cursor placement, and damage spans so a redraw touches four rows
instead of the screen. It's also where the subtle bugs live -- wide characters,
grapheme clusters, run boundaries.

**The executor (~1320 lines) plus sprites (~740)** answer *how those marks get
painted*: CTFont / CTLine / CGContext, plus procedural geometry for the glyphs
fonts don't provide (box drawing, braille, powerline, block elements, legacy
computing, geometric shapes). Those must land on exact pixel boundaries or
box-drawing shows hairline gaps.

Why it's a product at all: without it an adopter has a correct terminal state
machine they cannot see, and faces ~3,300 lines of the fiddliest code in a
terminal before rendering their first character. That's the difference between
"build your own terminal on this" being a real claim and a technically-true one.

The reuse objection you'd expect -- "a competitor wants their own look, so
they'll replace it" -- mostly doesn't apply. Look is `RenderTheme` and font
choice, and both are *inputs* to the planner. The plan dictates content, not
appearance.

**Open tension.** The two halves don't deserve the same tier. The planner is
arguably as stable as `DanTermVT`; the executor is a reference implementation
that happens to be the one DanTerm ships, and an adopter who wants Metal
discards it entirely and keeps only `RenderFramePlan`. That suggests the real
contract is *the plan type*, with the executor bundled as a reference impl --
which would argue for a different name and a split tier. Deliberately not
resolved here; see "Open questions" below.

Sibling packages, path-dep'd, never shipped to consumers:

| Package | Contains | Why separate |
|---|---|---|
| `danterm-engine-devtools` | 8 executables + the 3 benchmark libs | Today consumers build all of it and pull in AppKit. Biggest single cut. |
| `Examples/MiniTerm` | ~300-line macOS terminal on published products only | The Ghostty.app-to-libghostty analogue (gap #9). CI builds it, so it fails the moment the public API is insufficient. |
| `Examples/MiniTermMobile` | iOS app, `DanTermVT` + a stub byte source over a socket | Proves the PTY split is real; catches accidental AppKit reintroduction. |

### What this changes beyond renames

- **The session seam is new** -- a target inside `DanTermVT`, not a product.
  Today the transport seam doesn't exist as a type; it's implied by
  `TerminalPTY`. It's also the natural home for the two wrongly-hardcoded
  values: `TERM_PROGRAM`/XTVERSION (gap #4) and
  `productionScrollbackBudgetBytes` (iOS/jetsam). One new target absorbs both.
- **The font stops being embedded** -- see gap #6. `DanTermRender` takes a
  symbol font from the host; the Nerd Font ships in `Examples/MiniTerm`. Today
  every renderer consumer ships 2.5 MB unconditionally.
- **The planner/executor target split survives even though the product doesn't,**
  so a future Metal executor can be written against the same `RenderFramePlan`
  and promoted to its own product at that point.

### Tiers are load-bearing

Copy Ghostty's honesty verbatim: functionality is extremely stable because it's
extracted from a terminal in daily real-world use; the *API* may change without
warning. That framing is what lets a usable `0.x` ship while
`DanTermRender` churns. Concretely: `stable`
products get the `@inlinable` pass and semver guarantees; `provisional` and
`unstable` get a README line and are free to break on minor bumps.

Without the per-product `API.swift` (gap #3), "stable" is a claim about ~30
public structs nobody has audited. With it, it's a claim about one file.

## Repos

Two. The mirror design is specifically why this doesn't grow with the product
count.

| Repo | Role | Written by | Tags |
|---|---|---|---|
| `danneu/danterm` | Source of truth. Everything authored, including all of `lib/`. Unchanged. | us | `v0.0.84` (app) |
| `danneu/danterm-engine` | Generated mirror. `lib/TerminalCore` + `lib/TerminalPTY` projected to the root. Never hand-edited. | CI | `1.0.0` (engine) |

Devtools and examples get no repos -- they live inside the mirror as sibling
packages depending *upward* on the root (see gap #5):

```
danterm-engine/
├── Package.swift             <- the products. Zero path deps.
├── Sources/DanTermVT/ ...
├── DevTools/Package.swift            <- .package(path: "..")
└── Examples/
    ├── MiniTerm/Package.swift        <- .package(path: "../..")
    └── MiniTermMobile/Package.swift
```

Mirror-repo setup, all one-time: description + topics (this is the repo people
land on); `LICENSE` at root (gap #6; the Nerd Font's own license stops being our
problem if the font isn't embedded); a deploy key with write access, private half stored as a secret in
`danneu/danterm`; and **no branch protection on `main`**, since the sync
force-pushes. In the monorepo: a `just sync-engine [version]` recipe plus a
workflow running it on push-to-master and on engine version tags. That recipe
is the only new code either repo needs.

## What an adopter could actually build

### macOS competitor: yes, genuinely

Better than expected, because `TerminalInputEncoding.swift` is already public:
`encodeTerminalKey`, `encodeTerminalMouse`, `encodeTerminalPaste`,
`encodeTerminalFocus`, with `kittyKeyboardFlags`, SGR mouse encoding, bracketed
paste, application cursor keys. Input encoding is the piece most extracted
engines omit and the most miserable to reimplement -- Ghostty ships a whole
`ghostty/vt/key/encoder.h` for it.

| They get | They still write |
|---|---|
| VT state machine, scrollback, selection, search | Window / tab / split UI |
| Key, mouse, paste, focus encoding | Keybinding map and config format |
| PTY spawn, process lifecycle, resize | Theming, color scheme loading |
| Render planning + CoreText executor | Preferences, persistence, IPC |
| Sprite geometry | Clipboard policy, scroll UI, symbol font choice |
| `TerminalPaneSession` orchestration | |

That last row is the sleeper: ~900 lines of boring, easy-to-get-wrong glue
between "bytes arrived" and "here's a frame plan," shipped as a product. More
batteries than `libghostty-vt` provides.

Caveats until gap #4 lands: `TERM_PROGRAM=DanTerm`, the XTVERSION reply, and
the `DanTermShell=1` OSC selector leak our identity into their app. Also `TERM`
is hardcoded to `xterm-256color` (`TerminalPaneLaunch.swift:102`) and we ship no
terminfo -- a *gift* to adopters (nothing for their users to install), but a
competitor wanting their own `TERM` entry has to plumb it.

### iOS: blocked on exactly one thing

The engine layer is fine -- `DanTermVT` imports nothing, input encoding is pure,
`RenderPlanning` has no platform types, and the CoreText executor is one
`NSFont.monospacedSystemFont` call from portable.

What's missing is that an iOS app must supply bytes from somewhere other than a
PTY (SSH, mosh, a socket to a remote agent) and **there is no seam to plug that
into** -- `TerminalPaneSession` builds a `TerminalPTYHost` itself. So an iOS
adopter today gets `DanTermVT` and re-implements the entire session layer: read
loop, damage coalescing, resize propagation, feeding the planner. Doable, and
it means rewriting the most valuable non-VT asset we have.

One refactor away, and it's the session-seam extraction above.

## Suggested order

Sample app first (it finds the real API gaps) -> session-seam extraction
(unlocks iOS, absorbs the host-identity and scrollback-budget fixes) ->
`package`-access sweep behind per-product `API.swift` + de-DanTerm-ing ->
`@inlinable` pass on the newly-final public surface -> devtools cut, mirror
recipe, license, tags. Annotating before the surface is final is wasted work.

## Open questions -- resolve by building, not by reasoning

These four came up repeatedly and each time more argument produced no more
certainty. They are all answerable cheaply by the `MiniTerm` sample, which is
why the sample is first in the order. Do not re-litigate them in prose.

| Question | What settles it |
|---|---|
| Should `DanTermRender` split into plan-vs-executor products, and does the planner deserve `stable` while the executor stays `provisional`? | Build `MiniTerm`, then try a second executor (even a trivial one). If the planner needed no changes, it's stable and the split is real. |
| What shape should `RenderFramePlan` have across a module boundary? | Profile `MiniTerm`'s draw loop. Our own profile can't see a consumer's cost. |
| Rename modules to `DanTerm*`, or brand only the products? | Write `MiniTerm`'s imports both ways and read them. This is a call-site aesthetics question, and call sites are the evidence. |
| Is the `TerminalPaneSession` seam extraction actually contained? | Read the file end-to-end. The audit checked coupling *shape* (stored property + factory), not every use. |

## Notes for future brainstormers

**The mistake this doc already made once.** The first pass at the product
lineup had eight products, arrived at by transcribing Ghostty's artifact list
and renaming each row. That is exactly the failure AGENTS.md warns about:
"References are input, not authority... their structure encodes their history,
not our constraints." It was caught only by asking a different question --
*what does a consumer avoid by depending on this separately?* -- which
immediately collapsed eight to three. The irony worth remembering: copying
Ghostty *harder* would have given fewer products, since they publish exactly one
public artifact.

This doc is about mirroring Ghostty, so the next reader is at unusually high
risk of the same move. Ghostty is a good source of *edge cases they already
found* (the curated `lib_vt.zig` facade, `TERM_PROGRAM` as config, the honest
stability disclaimer). It is not a source of structure.

**Cluster gaps by fix, not by symptom.** Three separately-numbered gaps --
DanTerm identity literals (#4), the hardcoded scrollback budget, and iOS's
missing byte source -- turned out to be one refactor: extract the session seam,
and all three land in the new type. The numbered gap list is a symptom
inventory; it is not a work breakdown. Re-cluster before sequencing.

**Verify before promoting a gap.** Two first-pass claims were wrong on
inspection: the product count (6/5, actually 8/8, and three of the extra
libraries were *benchmark harness API* shipped publicly), and the assumption
that input encoding would need writing (it's already public in
`TerminalInputEncoding.swift`, which is the single biggest thing an adopter
gets for free). Both were one grep away. The gaps that survive contact with the
tree are the ones worth planning around.

## Sources

- [Brave new world: best practices for cross-module optimization](https://forums.swift.org/t/brave-new-world-best-practices-for-cross-module-optimization/66869)
- [SE-0193: Cross-module inlining and specialization](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0193-cross-module-inlining-and-specialization.md)
- [SwiftSetting.unsafeFlags](https://developer.apple.com/documentation/packagedescription/swiftsetting/unsafeflags(_:_:))
- [Unsafe flags block SPM consumers (Factory #289)](https://github.com/hmlongco/Factory/issues/289)
- [Library Evolution in Swift](https://www.swift.org/blog/library-evolution/)
- [Understanding @inlinable in Swift](https://swiftrocks.com/understanding-inlinable-in-swift)
- `.ghostty-src/` at 1.3.1: `build.zig#build`, `src/build/GhosttyZig.zig#init`,
  `src/build/GhosttyLibVt.zig`, `src/lib_vt.zig`, `include/ghostty/vt.h`
