# Metrics name the font they were built from

## Problem

`TerminalRenderMetrics` is a derived value: font inputs plus a display scale,
resolved per surface. It publishes neither input it was built from -- `baseFontName`
and `baseFontSize` are internal (`lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift:57`).
So every caller that must build a second metrics value for the same font keeps its
own copy of the inputs, and three independent surfaces already do:

- `examples/MiniTerm/Sources/MiniTerm/MiniTerminalView.swift:17-21`, whose comment
  states the reason outright.
- `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileCellMetrics.swift:33`, for
  the same reason.
- `app/SwiftTerminalSessionView.swift:246-249`, which holds `fontSize` and
  `fontFamily` as two separate fields.

Duplicated inputs drift, and the duplication has already produced two defects:

- **MiniTerm keeps stale metrics across a display move.** It re-derives only in
  `viewDidMoveToWindow` (`MiniTerminalView.swift:100-105`) and never overrides
  `viewDidChangeBackingProperties`, so a window dragged between a 2x and a 1x
  display renders cells sized for the wrong pixel grid. It is the one place in the
  repo that reads backing scale once and holds a derived value across a change --
  the rule `docs/design/2026-03-05-display-scaling.md` exists to protect.
- **A font change rebuilds metrics twice.** `PaneConfigKey`
  (`lib/DanTermCore/Sources/DanTermCore/Projections.swift:717`) is the one place
  size and resolved family already travel as a single `Equatable` value, and
  `app/Reconcile.swift:203-212` immediately splits it into `setFontSize` and
  `setFontFamily`, each of which runs a full `synchronizePresentation()`.

Load-bearing premises, both verified in the tree:

- `baseFontName`, `baseFontSize`, and `unquantizedLineHeight` have no production
  readers anywhere. They are assigned and then read only by tests, so promoting or
  replacing them migrates no shipped call site.
- The font inputs are routinely set independently, so a per-surface bundle is not
  merely cosmetic: per-pane zoom moves size alone (`Update.swift:437-457`) and
  `.fontFamilyResolved` moves family alone (`Update.swift:608-610`).

## Decision

Name the font inputs as one public value, and make it the only thing a caller
stores and the only way metrics are built.

- A public font-choice value carries the *requested* family -- a resolved name, or
  absent for the system monospace face -- and the point size. It is the value
  every embedder holds; metrics are never held across a scale change.
- `TerminalRenderMetrics` publishes the choice it was built from and takes that
  choice on construction, replacing the two loose font parameters. The resolved
  face name stays internal: request and resolution are different facts, and only
  the request is a rebuild input.
- The default choice is the system monospace face at the existing default size, so
  the 105 test sites that pass only a display scale are untouched. There is still
  one public initializer.
- DanTerm carries one font value from the reconcile boundary inward:
  `SwiftTerminalSessionView`'s two font fields become one, the metrics factory seam
  (`app/TerminalPanePresentationSurface.swift:74`) loses its third parameter, and
  the two `TerminalSession` font setters become one.
- The engine's font-choice type stops at the `DanTermCore` boundary. The pure core
  has no terminal-engine dependency and does not acquire one: `PaneConfigKey` keeps
  size and resolved family as its own plain fields, and `app/Reconcile.swift` builds
  the engine value from them at the point it already diffs that key.
- The iOS client and MiniTerm drop their shadow copies of the font size. The iOS
  copy is `public` API (`ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileCellMetrics.swift:27`),
  so it is deleted rather than narrowed, and its reader reads the metrics' own
  choice.
- MiniTerm rebuilds metrics on backing-property changes, and the gate builds
  MiniTerm so the probe fails as a compile error when the engine's public API moves.

Rejected in favor of this: a `rescaled(toDisplayScale:)` method on the metrics.
It derives metrics from metrics, which is the wrong direction -- it covers one of
the three rebuild axes so the shadow copies survive, DanTerm would never call it,
and it makes the app's family-to-system fallback (`SwiftTerminalSessionView.swift:1670-1676`)
sticky: a value that fell back once would rebuild from the fallback face forever
and never retry the configured family.

## Invariants

- **I1** Metrics publish every input a rebuild needs. A metrics value rebuilt from
  its own font choice at its own display scale equals the original.
- **I2** Metrics are derived per surface, never durable state. Every surface
  rebuilds them whenever its backing scale changes, and the type's documentation
  says so.
- **I3** One font change produces one metrics rebuild. Size and family reach a pane
  as a single value, so neither can move without the other being current.
- **I4** The app's fallback stays fresh: when a configured family yields no usable
  cell box the pane falls back to the system monospace face, and every later
  rebuild retries the configured family from the stored choice rather than
  inheriting the fallback.
- **I5** Rendering behavior is unchanged. The cell box, baseline, decoration
  offsets, and font set a given family and size produce are identical to today at
  every display scale.

## Proof obligations

- **PO1** (I1) Metrics round-trip their font choice: building from a choice,
  reading it back, and rebuilding at a different scale yields the same value as
  building directly from that choice at that scale. Covers the absent-family
  (system monospace) case, which resolves to a concrete face name and must still
  report an absent family.
- **PO2** (I2) A pane whose surface moves between two display scales follows, in
  two scenarios that differ in what the grid may do:
  - An unclaimed pane resolves new metrics and the new grid its bounds imply.
  - A pane holding a grid override resolves new metrics and keeps its grid
    exactly, sending the child no resize. The override is the grid outright, and a
    display move is not a claim it may overrule.

  Both replace the presentation surface and repaint the current frame at the new
  scale, so no pane reports new geometry while still showing pixels rendered at the
  old one. No test anywhere drives a scale transition today --
  `tests-ui/SwiftTerminalSessionViewTests.swift:773` names the case in prose and
  then exercises a font-size change instead, and `:910` changes color space at
  unchanged scale.
- **PO3** (I3) A config change that moves both size and family rebuilds the pane's
  metrics once.
- **PO4** (I4) A pane that fell back from an unusable family to system monospace
  and then changes display scale renders the configured family again once it is
  usable. Extends the existing fallback coverage at
  `tests-ui/SwiftTerminalSessionViewTests.swift:146`, which uses the injected
  metrics seam and the `UITestFontFamily.unusable` stand-in.
- **PO5** (I5) The existing metrics suite
  (`lib/TerminalCore/Tests/TerminalRenderExecutionTests/RenderMetricsTests.swift`)
  passes with its expected geometry unchanged; only how it names font inputs
  changes.
- **PO6** (I2) MiniTerm builds in the gate, and its window follows a move between
  displays of different backing scale. The gate build is the standing proof; the
  display move is verified by hand, since the example has no test target.
- **PO7** The gate's own suite (`scripts/tests/run-test-suite_test.sh`) fails if the
  MiniTerm build leaves the gate. Gate membership is what makes MiniTerm a standing
  API probe rather than a stale example, so dropping it must not be a silent green.

## Non-goals

- The internal `CTFont` construction seam stays internal and test-only. It is
  outside I1 by construction: a file-backed face that is deliberately not
  process-registered cannot be named by a family string, which is the seam's whole
  purpose.
- Font *resolution* -- deciding whether a configured family name is installed --
  stays where it is (`app/DanTermConfigStore.swift:35`). Only resolved names reach
  the render layer, as today.
- The other snags in `docs/scratch/2026-08-26-terminal-engine-reusability.md`.

## Accepted risks

- **AR1** The `CTFont` seam builds its grid from the default system face and then
  overwrites the font set (`TerminalRenderExecution.swift:101-134`), so its cell
  box is not derived from the face it draws with. This is pre-existing and
  unrelated to the font choice, but the round-trip invariant makes it visible.
  Left as-is; the seam has three test call sites and no production caller.
- **AR2** PO2 and PO4 live in the AppKit UI suite, which needs a WindowServer and
  is therefore outside `just test`. The gate cannot prove the scale-transition
  behavior; `just test-ui` must be run for this change.
- **AR3** MiniTerm's gate step costs one more engine compile against the gate's
  shared core budget: it resolves `TerminalCore` and `TerminalPTY` through its own
  package. Accepted -- it is one SwiftPM build into a warm per-purpose scratch, the
  same shape as every other package step in `scripts/run-test-suite.sh`, and a
  probe that is not built is not a probe.

## Implementation discretion

- Whether the display scale or the font choice comes first in the initializer, and
  how the default choice is spelled.
- How the UI suite drives a scale transition against a test window.

## Verification

- `swift test --package-path lib/TerminalCore --filter RenderMetrics` and
  `just lint` during the loop.
- `just test` before the commit -- it must now include a MiniTerm build
  (`scripts/run-test-suite.sh:161-202` enumerates the package paths).
- `just test-ui` for PO2, PO3, and PO4.
- `just launch-slot`, then change font size and family through preferences and
  confirm the pane re-renders correctly at each.
- Run MiniTerm and drag its window between displays of different backing scale for
  PO6.

## Close-out

The last step, in the same commit as the change, is to settle snag 2 in
`docs/scratch/2026-08-26-terminal-engine-reusability.md`, in the shape snag 3 uses:
mark the heading done, point at the promoted plan, record that the shipped fix is a
font-choice value rather than the `rescaled(toDisplayScale:)` method the snag
proposed and why, note the two defects the snag missed -- MiniTerm's stale metrics
across a display move, and DanTerm's double rebuild on a font change -- and keep the
original record of the snag below. The remaining snags stay open, so the file keeps
its scratch status.

## Implementation notes

- `TerminalSession.setFont` takes `size: Double, family: String?`, not the engine's
  `TerminalFontChoice`. `scripts/terminal-backend-boundary-lint.sh` confines engine
  imports to seven named adapter files, and `app/TerminalSession.swift` and
  `app/Reconcile.swift` are not among them -- so the engine value stops at the
  adapter boundary, one step short of where the plan drew it. The pair becomes a
  `TerminalFontChoice` inside `SwiftTerminalSessionView`, which is an adapter. I3
  holds as written: size and family reach the pane in one call, and PO3 proves the
  single rebuild.
- `MobileCellMetrics.init` keeps a plain `fontSize: CGFloat` for the same reason:
  `ios/DanTermMobileApp` has no dependency on the `TerminalRenderExecution` product,
  and adding one for a single constant would widen the client's dependency graph for
  nothing. The shadow copy the plan named -- the `public let fontSize` field -- is
  gone, and `MobileObserveSurface` re-resolves from `metrics.fontChoice`.
- `baseFontSize` is deleted rather than kept: it was the same number as
  `fontChoice.size` at every call site. `baseFontName` stays, internal, because the
  resolved face name is a different fact from the request.
- `makeTestPane` gained a `makeMetrics:` seam. PO4 needs a resolver that refuses a
  family at one display scale and accepts it at another, and no shared resolver can
  answer both ways at once.

## Follow Up

- `TerminalSessionRequest` still carries `fontSize` and `fontFamily` as two fields
  (`app/TerminalSession.swift:155-158`), and `AppRuntime.makeTerminalSession` passes
  them as two parameters. The creation path has the same two-fields-that-drift shape
  the setters just lost; it is out of this plan's scope because the plan enumerated
  the setters only.
