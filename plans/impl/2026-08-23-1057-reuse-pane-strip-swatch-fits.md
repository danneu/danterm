# Fitting stops measuring text it did not need to measure

## Context

Two draw paths answer a layout question by running a search that builds and
measures text on every repaint, for inputs that did not change.

**The pane strip.** `PaneStripView.plan(width:)` (`app/PaneStripView.swift:103`)
calls `overflowLabel(count:).size().width` inside its shrinking loop.
`overflowLabel` resolves `effectiveAppearance.bestMatch`, builds a `ChipStyle`
palette, allocates an `NSAttributedString`, and hands it to CoreText -- for a
width that depends only on the digit count and a fixed 9pt system font.
`draw(_:)` then re-runs `plan` and builds the label a third time. One repaint of
a multi-pane row costs roughly four to six appearance walks, string
allocations, and text measurements. The repaint fires per visible row per frame
during a sidebar width drag: `SidebarView.swift:86` `SidebarRowView.setFrameSize`
-> `resizeHostedCells()` -> `PaneStripView.swift:80` sets `needsDisplay` on any
width change.

The loop itself is short. `count` is seeded width-bounded
(`min(total, floor((width + spacing) / slot))`, slot 15pt) and the `+N` label
costs about one slot, so it decrements once or twice -- not `count` times, as
the originating audit item RECON-5 first claimed and then corrected.

**The theme swatch.** `swatchTextFit` (`app/ThemeSwatchViews.swift:45`) is the
same shape in worse form: a linear search from the text area's height down to
4pt in 0.5pt steps, rebuilding and measuring an `NSMutableAttributedString`
every iteration, called straight from `ColorSwatchView.draw`. Its only input is
the text area's size, and that size is pinned by constraints
(`ThemeSwatchViews.swift:163`, width 50), so the search resolves to the same
answer every time it runs. It has no test of any kind today.

**No instrument covers either path.** The benchmark ladder never draws the
sidebar or the theme browser, and `benchmark-headless-draw` is bound to
`TerminalCore`'s `drawRenderFrame`. Nothing here is claimed as a measured win,
and no number should be reported as one. The case for the change is structural:
in both places a derived value with fixed inputs is recomputed from scratch on a
paint path, and in the pane strip's case a geometry question reaches for a theme
to answer it.

**Second premise.** Fitting is the property the pane strip exists for -- no pane
count overflows the row, and the focused chip is never the one elided -- and it
is proven today only in `tests-ui`, which `scripts/run-test-suite.sh:162` skips
(`--skip DanTermUITests`, the gate is headless). So the strip's central claim
does not run in `just test`.

## Decision

**Fitting becomes pure arithmetic in the core; appearance and font metrics are
supplied to it, never reached from inside it.**

Move the pane strip's fitting arithmetic into a new pure geometry file in
`lib/DanTermCore/Sources/DanTermCore/`, following the precedent of
`ScrollbarMath.swift` -- CGFloat geometry, `Foundation` only, internal functions
the app calls same-module through the tracked `app/DanTermCore` symlink, tested
by `lib/DanTermCore/Tests/DanTermCoreTests/`. The overflow label's width enters
as an injected function of count, which is what makes the fitting pure and lets
the gate sweep it. `TabPaneChip` already lives in the core
(`ModelOperations.swift:693`), so nothing new crosses the boundary.

`PaneStripView` keeps two jobs and no third: supply real font metrics for a
count, and paint. The colored `NSAttributedString` becomes reachable only from
`draw(_:)`, for the one count actually drawn. Because the fitting function has
no access to a view, appearance-independence of the plan stops being a claim
anyone has to check and becomes a property of where the code lives.

For the swatch, the derived fit is computed when its input size changes rather
than on every paint. Same rule, different key; the two are not unified (see D3).

**Reuse is asserted, not assumed.** Each view names its measurer as a
collaborator with the shipping implementation as the default, following the
seam the pane view already uses for the resolver that turns a font choice into
cell geometry (`plans/wip/2026-08-21-1757-ui-suite-as-a-test-target.md`) -- a
seam for the same reason, that the real answer reads the machine's fonts and the
behavior has to be provable without depending on them. A test supplies a
counting measurer and drives repaints. Production behavior and every call site
are unchanged; the default is the real measurer.

The paint path is also arranged so that `plan(width:)` and `draw(_:)` read a
stored derived value rather than measuring. That placement is a readability
property, not a compiler-enforced one -- both live on the same view and nothing
stops a future edit from reaching past it -- which is why the reuse is carried
by I8 and PO5 rather than by where the code sits.

Behavioral scope: none. Nothing about what either view draws changes -- chip
size, spacing, label text, colors, the swatch's fitted point size, and the
repaint triggers all stay exactly as they are.

Files: `app/PaneStripView.swift`, `app/ThemeSwatchViews.swift`, one new pure
file under `lib/DanTermCore/Sources/DanTermCore/`, one new suite under
`lib/DanTermCore/Tests/DanTermCoreTests/`, `tests-ui/PaneStripViewTests.swift`,
and swatch coverage under `tests-ui/`, which has none today.

## Invariants

The strip's fitting invariants hold over its supported domain: at least one
chip, and a width greater than zero.

- **I1.** Within the domain, the visible run plus the overflow label never
  exceeds the width the strip was given, except at the floor: where not even one
  chip fits, exactly one is shown and overhangs.
- **I2.** The visible run holds the greatest chip count that satisfies I1. A
  strip never elides a chip that would have fit.
- **I3.** Outside the domain -- no chips, or a width of zero or less -- the strip
  shows nothing and counts every pane as hidden. This is today's behavior and it
  is preserved, not redesigned.
- **I4.** The focused chip is always inside the visible run.
- **I5.** The run starts at the first chip and slides forward only as far as it
  takes to keep the focused chip inside it.
- **I6.** The width the fitting reserves for the `+N` label equals the width of
  the label `draw(_:)` paints.
- **I7.** A swatch draws its text at the largest size on its existing search grid
  that fits the text area. Where no size on the grid fits, it uses the smallest
  size the grid reaches and the text overhangs. The grid and its floor are
  today's behavior, preserved rather than redesigned.
- **I8.** A repaint whose inputs have not changed asks its measurer for nothing.
  A pane count or swatch size not seen before asks for exactly the measurement
  it needs.

## Proof obligations

- **PO1** (I1, I2, I4, I5) -- pure tests in the core suite, sweeping pane counts,
  widths, and focus positions against supplied label metrics, and covering the
  floor case rather than skipping it. These run in `just test`, headless. The
  four existing fitting tests in `tests-ui/PaneStripViewTests.swift` are the
  source material and move here; the paint tests (marks, rings,
  both-marks-at-once) stay where they are.
- **PO2** (I3) -- pure tests at the domain edges: zero chips, and a width of zero
  or less. The existing sweep skips exactly these
  (`tests-ui/PaneStripViewTests.swift:165`, `guard !plan.visible.isEmpty else
  { continue }`), so an empty-run regression has nothing to fail against today.
- **PO3** (I6) -- a UI-harness test, because only there are the metrics real.
  This is the bridge that makes PO1's synthetic widths stand for the font's
  actual ones.
- **PO4** (I7) -- a UI-harness test over a sweep of swatch sizes, partitioned by
  which case the size falls in: the chosen size fits and is the grid's largest
  candidate; the chosen size fits and the next candidate up does not; no
  candidate fits, so the floor is chosen and the text overhangs. New coverage --
  the swatch's fitting rests on nothing today, and a reused fit must not be the
  change that discovers this.
- **PO5** (I8) -- a test per view driving repeated paints through a counting
  measurer: a repaint at unchanged inputs adds no calls, and a first-seen count
  or size adds exactly the calls it needs. Independent of how the derived value
  is stored, so a change of storage keeps it passing.

## Non-goals

- No visual change to either view, and no change to when either repaints.
- No new instrument. Neither path is on the benchmark ladder and this plan does
  not put it there.

## Accepted risks

- **AR1.** PO1 runs in the gate but on supplied metrics; PO3 ties those to the
  real font but runs only under `just test-ui`. A real-font regression is
  therefore caught by a suite the gate skips. Accepted: the alternative is
  leaving all of I1-I5 outside the gate, which is the situation today.
- **AR2.** Reusing a measured label width for the process's life bakes in the
  system font's metrics. `NSFont.systemFont(ofSize:weight:)` takes an explicit
  point size and macOS does not scale it -- only the
  `preferredFont(forTextStyle:)` family scales -- so this holds today. If that
  ever stops being true, the reused width is wrong and PO3 is what would say so.

## Rejected ideas

- **D1.** A `static let` table of label widths over "every count a strip can
  show" (RECON-5's first proposal, retracted by its own follow-up): pane count
  per tab has no bound, and it would eagerly measure counts nobody displays.
- **D2.** Deriving the label width from the system font's glyph advances for `+`
  and the digits. It bets on equal-width figures in the system font -- an
  unstated compatibility assumption -- and buys nothing over reusing a
  measurement.
- **D3.** One shared fit/memo helper across the pane strip and the swatch. The
  two searches shrink different things against different keys, so the shared
  thing would name caching without dissolving anything; and the strip's fitting
  now lives in the pure core, which cannot reach a Cocoa-side helper.

## Implementation discretion

- How each derived measurement is stored and keyed, on either view.
- Whether the pure fitting is one function or a small namespace, and what it is
  called.

## Verification

1. `swift test --package-path lib/DanTermCore` -- the new pure fitting suite
   passes and the four migrated cases keep their assertions.
2. `just test` -- the gate, which now covers I1-I5 for the first time.
3. `just test-ui` -- PO3, PO4 and PO5, plus the pane strip's unchanged paint
   tests.
4. `just lint` -- `core-purity-lint.sh` on the new core file: `Foundation` only,
   no Cocoa import, no side-effecting token.
5. `just launch-slot`, then drag the sidebar wide and narrow with a multi-pane
   tab visible, and open the theme browser: both views look exactly as they did.
   This is a no-regression check by eye, not a measurement, and should be
   reported as one.

## Commit progress

- [x] 1. Move pane-strip fitting into the pure core
- [x] 2. Reuse pane-strip overflow measurements
- [x] 3. Reuse theme-swatch text fits
