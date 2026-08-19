# Resolve cell metrics where the display scale changes, not per applied tape record (MOBILE-1)

## Problem

Every applied tape record on the phone rebuilds the CoreText font world from
scratch, on the main actor, for values that are a pure function of
(displayScale, fontSize) and cannot change between two records:

- `TerminalSurfaceView.apply` calls `ensureSurfaces` unconditionally, and
  `ensureSurfaces` constructs a `MobileObserveSurface` *before* its equality
  guard. That initializer builds one `TerminalRenderMetrics` (and a second,
  fitted one whenever the pane's grid is wider than the phone draws natively,
  which is the normal case).
- The same record rides `didChangeReplicaState` ->
  `MobileSessionController.surfaceDidLayout` -> `surfaceView.nativeGrid` ->
  `MobileContentBox.nativeGrid(fontSize:)`, which builds a third.
- Each `TerminalRenderMetrics.init` creates a CTFont, builds five
  `TerminalFace`s, and measures the printable-ASCII glyph table per face.

Source: audit finding MOBILE-1 in
`docs/scratch/2026-08-18-construction-audit.md` (impact 5, confidence 5,
vetted, with Sharper ideal and starter kit). Verified against current sources
2026-08-19; nothing has moved.

## Decision

Make the resolved metrics a value produced only where its inputs move, and
pass it down -- the audit's Sharper ideal plus the load-bearing guard hoist
its preparer's read demands. Both halves are required; neither alone is
sufficient:

1. **A kit value pairs one `MobileContentBox` with the `TerminalRenderMetrics`
   resolved for its display scale and the surface's one font size.** Its
   failable initializer takes (box, fontSize) and resolves the metrics itself,
   so box and metrics cannot disagree by construction. `MobileContentBox`
   itself stays a cheap pixel description with trivial `Equatable` -- metrics
   do not become a stored member of the box.
2. **`TerminalSurfaceView` holds one such value**, and every layout pass
   replaces it with the newly measured resolution -- including clearing it
   to nil when the current extent yields no valid box or the metrics resolve
   to nothing. A held value never answers for a dead extent: with no valid
   pairing, `nativeGrid`, placement, and fitting all report nothing, exactly
   as today's computed-per-access box does. (Metrics resolution still happens
   only when the measured box differs from the held one; an unchanged box
   keeps its pairing.) Scale changes funnel into a layout pass:
   `didMoveToWindow` (the scale reads `window?.screen.scale` first) and a
   registered display-scale trait-change handler (iOS 26 target, so
   `registerForTraitChanges`, not the deprecated override).
   `safeAreaInsetsDidChange` already schedules layout. Existing frame stores
   may remain allocated across an invalid interval.
3. **`MobileObserveSurface.init` takes the resolved pairing instead of a bare
   `fontSize`.** Its fitted branch still constructs a second
   `TerminalRenderMetrics` at the fitted scale when the grid does not fit
   natively -- that scale depends on columns and rows, so it genuinely cannot
   be precomputed at the layout edge.
4. **`MobileContentBox.nativeGrid(fontSize:)` is deleted**; the native grid
   becomes plain arithmetic over the held metrics, and
   `TerminalSurfaceView.nativeGrid` reads the held value.
5. **`ensureSurfaces` compares (columns, rows, box) before constructing
   anything.** This hoist is load-bearing, not polish: it is what keeps the
   fitted-branch font build off the unchanged-record path. The existing
   fitted-surface equality stays as the second-level guard so a box move that
   resolves to an identical drawn world (an origin-only inset shift) keeps its
   stores, exactly as today.

By construction, the record-path APIs -- `MobileObserveSurface.init` and the
native-grid derivation -- no longer take a font size, so font derivation is
expressible only through constructing the pairing value. Keeping pairing
construction itself off the record path is not structural: it is the
view-side discipline PO3 sends to implementation review.

## Invariants

- I1: Applying a record that changes neither the grid nor the content box
  performs no metrics resolution; metrics are resolved only when the box
  (extent, insets, or display scale) or the fitted grid actually changes.
- I2: Fit outcomes are value-identical to today: a too-large grid is drawn
  into no more pixels than the view has, a grid that fits keeps native scale,
  an undrawable grid is refused, and the claimed grid and drawn surface agree
  inside one box at both handset scales.
- I3: The single-reading property of `MobileContentBox` holds: the grid a
  claim names and the pixels a surface draws come from one value.
- I4: A display-scale change for the same point extent produces different
  resolved cell pixel dimensions -- held metrics cannot go silently stale.
- I5: A box change that resolves to an identical drawn world keeps the
  existing frame stores.
- I6: A view whose current extent cannot resolve a valid box or metrics
  reports no native grid, no placement, and no fit -- the held pairing is
  cleared, never left stale, so a layout-driven claim renewal cannot name
  an extent the phone no longer has.

## Proof obligations

- PO1 (I2, I3): the existing kit tests ported to the new signatures with
  every assertion unchanged -- `ObserveSurfaceTests` (all three),
  `ContentBoxTests` (including `contentBoxClaimAndDrawAgree`),
  `SurfacePlacementTests` -- pass. These are the characterization proof.
- PO2 (I4): new kit test: resolve the pairing for the same box extent at
  displayScale 3 and displayScale 2 and assert the resolved cell pixel
  dimensions differ.
- PO3 (I1): two distinct proofs, neither carried by PO1 (the kit tests
  construct `MobileObserveSurface` directly and never reach the view).
  Native-metrics ownership is proved structurally only for the record-path
  APIs: their fontSize-taking forms are deleted, so a per-record derivation
  through them no longer compiles. Implementation review must verify the two
  view-side disciplines with no automated cover (no app test target): the
  `(columns, rows, box)` comparison precedes `MobileObserveSurface`
  construction in `ensureSurfaces`, and pairing resolution occurs only in
  the layout refresh, never lazily on the record path. A counting test is
  rejected as mechanism-assertion, per the audit.
- PO4 (I2): the native grid derived from held metrics equals what
  `nativeGrid(fontSize: 11)` produced -- the ported `ContentBoxTests`
  native-grid assertions carry this.
- PO5 (I6): no automated cover (view-side); verified by implementation
  review with PO3's guard ordering -- the layout refresh must replace the
  held optional unconditionally, not only on a successful resolution.
- PO6: a `reset(checkpoint:for:)` that runs before the first layout pass
  still gains surfaces at that first layout pass (a checkpoint-restored
  quiet pane must not stay blank waiting for a record). Verified by
  implementation review; no reachable scenario is known today, but the
  outcome if reached is a blank pane.
- I5 and the view-side refresh have no automated cover: the app package has
  no test target. Manual proof: rotate the device / move between displays
  while an observed pane floods.

## Non-goals

- Routing a typed `.resize` transition out of the record stream to take
  `ensureSurfaces` off the per-record path (the original finding's second
  half; the audit's Sharper ideal drops it -- once metrics are held, the
  per-record call is arithmetic and the machinery buys nothing).
- The per-record `surfaceDidLayout` / `scrollChrome.refresh()` cadence
  (MOBILE-4) and damage-fed rendering (MOBILE-2) stay untouched.
- No change to `lib/TerminalCore`: mobile re-calls the
  `TerminalRenderMetrics` initializer at the fitted scale, the same pattern
  `app/SwiftTerminalSessionView.fittedMetrics` uses on macOS.

## Accepted risks

- A remote resize or rotation that genuinely changes the fit still builds a
  font set once; unavoidable, since the fitted scale depends on the grid.
- The view-side refresh hooks are only manually verifiable (no app test
  target); the kit-level PO2 pins the metric-vs-scale relationship they rely
  on.
- A record arriving between a bounds/inset change and the next layout pass
  fits, and can renew a standing claim, against the previous extent for up
  to one runloop turn (today both reads measure the box fresh per access).
  Accepted: the layout pass that follows refreshes the pairing and fires
  `surfaceDidLayout`, correcting both; the window is one turn and
  self-healing.

## Critical files

- `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileObserveSurface.swift`
- `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileContentBox.swift`
- new kit file for the pairing value
- `ios/DanTermMobileApp/Sources/DanTermMobileApp/TerminalSurfaceView.swift`
- `ios/DanTermMobileKit/Tests/DanTermMobileKitTests/{ObserveSurfaceTests,ContentBoxTests,SurfacePlacementTests}.swift`
  (signature ports; assertions unchanged)

Reused as-is: `fittedRenderScale`
(`lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderFit.swift`),
`MobileSurfaceGrid.init?(widthPixels:heightPixels:cellWidthPixels:cellHeightPixels:)`.

## Verification

- `just test` -- runs `swift test --package-path ios/DanTermMobileKit`,
  `scripts/ios-portability-gate.sh` (the new kit type must cross-compile),
  `scripts/core-purity-lint.sh --profile portable` over the kit, and
  `scripts/tests/ios-app_test.sh` (catches app-side compile breaks).
- Manual on device: flood an observed pane, rotate, and confirm the drawn
  cells stay correct; rotation is the workload that would show stale metrics.

## Implementation discretion

- The pairing value's name (e.g. `MobileCellMetrics`) and whether it is
  `Equatable` (the view compares boxes, so it need not be).
- The exact funneling of scale-change hooks into the layout pass, provided
  both a window move and a trait change reach the refresh.

## Implementation notes

- The pairing value is `MobileCellMetrics`, and it stores the font size alongside the
  box and the metrics. The fitted branch of `MobileObserveSurface.init` has to re-resolve
  the same font at a smaller scale, and `TerminalRenderMetrics.baseFontSize` is internal
  to `TerminalRenderExecution`, so the size has to be carried rather than read back.
- `TerminalSurfaceView.geometry` changed meaning and gained a sibling. It is now the grid
  the replica asked for, and the new `fittedFor` records the `(columns, rows, box)` the
  frame stores were built for. That split is what satisfies PO6: `geometry` was
  previously written only after a successful allocation, so a `reset(checkpoint:)` that
  ran before the first layout pass left it nil and no later layout pass would refit --
  the restored pane would stay blank until a record arrived. It is now written at the top
  of `ensureSurfaces`, before any guard.
- `fittedFor` is recorded only on a path that leaves the stores consistent with it, so a
  failed store allocation still retries on the next call.
- PO2 lives in its own `CellMetricsTests.swift` rather than in `ObserveSurfaceTests`,
  which is about the fit rather than about the pairing.

## Follow Up

- `scripts/tests/ios-app_test.sh` only checks `scripts/ios-app.sh`'s usage string; it
  never compiles `ios/DanTermMobileApp`. `just test` therefore does not catch an app-side
  compile break, contrary to what this plan's Verification section assumed. The
  portability gate cross-compiles the app package, so the gap is narrower than it looks,
  but the test's name and the plan both overstate what it proves.
