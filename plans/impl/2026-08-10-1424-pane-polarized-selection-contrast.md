# Pane-polarized selection contrast

## Problem

DanTerm resolves the selection overlay fill per cell: it takes the theme's
selection seed and moves it to the nearest brightness at least 40 levels from
the selected cell's resolved background, on whichever side is closer to the
seed. Two consequences of "nearest side wins" break how selection reads:

- The fill can land next to the terminal's default canvas. The selection then
  looks like a hole cut through a TUI-painted surface down to the canvas,
  not like a highlight.
- The push direction flips as cell backgrounds cross the seed, so two nearby
  surfaces in one drag can get one darkened and one lightened fragment. The
  current property suite pins this flip as accepted behavior
  (`OverlayContrastPropertyTests.pushDirectionHasSingleDiscontinuity`).

Reproduced incident, Monokai Remastered (canvas `#0c0c0c`, brightness 12;
selection seed `#343434`, brightness 52):

| Surface | Background | Selection fill today |
| --- | --- | --- |
| Claude Code user-message band | `#373737` (55) | `#0f0f0f` (15) -- reads as canvas |
| Codex user-message band | `#292929` (41) | `#515151` (81) -- correct lightened gray |

A 14-level difference between two TUI surfaces reverses what selection looks
like. Both fills satisfy the current local-contrast invariant; the contract is
what is wrong, not the execution.

Evidence this is a theme class, not one bad theme: 268 of the 592 bundled
themes place their selection seed within 40 brightness levels of their own
canvas, so any TUI surface near the seed reproduces the failure under them.

Desired outcome: selection has one coherent meaning per pane -- it pushes a
surface toward the theme's ink -- and can never be mistaken for the canvas.

## Decision

Selection polarity becomes a pane-level constant, and the canvas becomes a
competitor. The rule: a brightness is admissible when it clears the minimum
fill separation from both the selected cell's resolved background and the
theme's default background. The fill is the admissible brightness nearest the
seed's brightness on the pane's preferred side of the cell background, and the
seed's hue is carried unchanged. Reaching it may move the seed either up or
down -- the preferred direction names which side of the cell background the
result lands on, not which way the search travels from the seed. Only when the
preferred side of the cell background holds no admissible brightness does
resolution fall back to the opposite side.

The preferred direction derives from the theme's ink relationship: lighten
when the default foreground is at least as bright as the default background
(ties lighten), darken otherwise. This is theme-native, handles
middle-brightness themes without an arbitrary constant, and never contradicts
a bundled theme's own expressed polarity: 0 of 592 bundled themes place their
seed 40 or more levels from the canvas on the anti-ink side.

Scope is the selection fill only. The search, combined
selection-plus-search, cursor, and glyph-contrast resolutions keep their
current contracts, and the canvas does not join their avoidance sets: adding
it to every rung of the overlay ladder pushes the worst-case forbidden
brightness width past the 0-255 domain and makes the resolver's "no
admissible color" precondition reachable. Selection's own two competitors
forbid at most 160 of 256 levels, so a fill always exists on at least one
side.

Exact preservation of the theme's seed is demoted below coherence: the seed
is returned exactly when it already satisfies the invariants below, and
otherwise contributes its hue, plus the brightness the result stays nearest
to.

## Invariants

For a pane with theme canvas C, preferred direction D as decided above, a
selected cell with resolved background B, and resulting fill F, with the
minimum fill separation at its existing value (40 brightness levels):

- I1 Visibility: F is at least the minimum separation from B.
- I2 Canvas distinctness: F is at least the minimum separation from C.
- I3 Pane polarity: F lies on side D of B (beyond the minimum separation)
  whenever any admissible brightness exists on that side; the opposite side
  is used only when side D is exhausted against the 0-255 gamut.
- I4 Hue and preservation: F is the theme's selection seed moved in
  brightness only, and is the seed exactly when the seed already satisfies
  I1-I3.
- I5 Totality and purity: resolution is a pure deterministic function of
  (theme, cell background) and returns a qualifying fill for every 24-bit
  background under every theme, including backgrounds and canvases at the
  gamut extremes.
- I6 Unchanged neighbors: search, selection-plus-search, cursor, and
  overlay-text resolution keep their current contracts, and the overlay
  ladder's pairwise separations still hold with the new selection fill as
  their competitor.

## Proof obligations

- PO1 Incident regression, byte-driven: feed truecolor SGR backgrounds
  `#373737` and `#292929` into `Terminal`, select across both bands under
  Monokai Remastered, and assert the planned overlay fills satisfy I1-I3 --
  both fragments lightened, neither near the canvas. Assert behavior, not
  exact RGB.
- PO2 Fleet sweep: extend the bundled-theme sweep
  (`OverlayContrastPropertyTests.bundledThemeContrastSweep`) so all 592
  themes x the existing background corpus prove I1-I4 for selection while
  the existing ladder, cursor, and text separations continue to hold (I6).
  The sweep's current expectation that a seed clearing only the cell
  background is preserved exactly is superseded by I4.
- PO3 Polarity, full domain: sweeping cell-background brightness 0-255 under
  fixed dark, light, and degenerate-seed themes, the fill's contrast
  direction relative to the cell never flips on the preferred side; any flip
  occurs only at gamut exhaustion (I3). This replaces
  `pushDirectionHasSingleDiscontinuity` as the selection-level contract; that
  test pins the behavior this plan removes.
- PO4 Totality: adversarial (seed, canvas, background) combinations,
  including near-black and near-white values and seed-equals-canvas, resolve
  without hitting the no-admissible-color precondition (I5). Include the case
  where the preferred side is admissible but only away from the seed --
  lightening theme, canvas 250, cell background 0, seed 230, whose only
  admissible band is 40-210 and whose answer is 210.
- PO5 Pixel proof: a selection spanning the default canvas and a painted band
  renders with the band's fragment visibly filled, not erased to
  canvas-adjacent pixels (`SelectionExecutionTests`).

## Non-goals

- Changing search, combined, cursor, or glyph-push polarity or their
  avoidance sets.
- Editing any bundled theme file.
- Changing the brightness metric or the minimum separation values.

## Accepted risks

- AR1: Surfaces brighter than the seed on a dark theme (and the mirror case
  on light themes) now resolve to fills near the ink pole -- a visible change
  from today's dark fills there. This is the point of the polarity contract.
- AR2: A drag across surfaces of different brightness produces fragments of
  different fill brightness, all on one side. Coherent direction, not one
  flat color, is the contract; this matches current behavior.
- AR3: An external (non-bundled) theme whose seed sits 40+ levels from the
  canvas on the anti-ink side loses its exact seed everywhere except where it
  qualifies under I3; hue is retained. Zero bundled themes are affected.

## Rejected ideas

- RI1: Canvas avoidance alone, keeping nearest-side ranking. Fixes the
  incident but leaves the polarity flip expressible for other surface pairs.
- RI2: Direction from the seed-canvas relationship with an ink-direction
  fallback. Respects a theme-expressed polarity, but no bundled theme ever
  disagrees with ink direction, so the extra rule buys nothing.
- RI3: Blending the seed with the cell background. A mix of two nearby colors
  stays near both; blending redistributes contrast and cannot create it.
- RI4: Seedless fill (push the cell background itself). Cannot flip, but
  discards the theme's selection hue everywhere and can still land near the
  canvas for surfaces darker than the canvas.
- RI5: A fixed brightness midpoint as the direction signal. Arbitrary for
  middle-brightness themes; the ink relationship is theme-native.

## Implementation discretion

- Tie-breaking and candidate ranking within the admissible side, and how the
  quantization-drift probing carries over.
- How the pane direction is computed and threaded (derived per call from the
  theme vs precomputed); whether the generic bidirectional resolver and its
  oracle tests survive unchanged for the other ladder rungs.

## Critical files

- `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderColorResolution.swift`
  -- selection rung of `resolveOverlayFill`, direction derivation.
- `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift`
  -- call site; per-fragment resolution and run coalescing already pass the
  theme through.
- Tests: `OverlayContrastPropertyTests.swift`,
  `SelectionRenderPlanningTests.swift`, `RenderColorResolutionTests.swift`
  (planning); `SelectionExecutionTests.swift` (pixels).

## Verification

TDD order: PO1 first, failing against the current resolver for the expected
reason (the `#373737` fragment resolves dark). Then the resolver change, then
PO2-PO5.

- `swift test --package-path lib/TerminalCore --filter TerminalRenderPlanningTests`
- `swift test --package-path lib/TerminalCore --filter SelectionExecutionTests`
- `just test` as the full gate.
- Optional live confirmation: `just launch-slot`, switch the pane theme to
  Monokai Remastered, run a TUI painting a `#373737`-class band, select
  across it -- the band must lighten, not read as erased.
