# Background-adaptive overlay colors

## Context

Selection, active search match, and the cursor are painted as opaque fills
whose colors are per-theme constants, chosen without reference to what is
underneath them. TUIs paint their own cell backgrounds: Claude Code and Codex
render user-message blocks as solid truecolor bands. When a theme's selection
color lands near such a band, dragging a selection across it produces no
visible change -- the selected region is indistinguishable from the
unselected text beside it. The same blindness hides the block cursor, which
is worse: a drag has motion to help you find it, a cursor does not.

No constant fixes this. There are 592 bundled themes and the TUI's color is
arbitrary truecolor, so for any fixed overlay color some theme/TUI pair
collides. The overlay color has to be a function of the background it covers.

A second gap surfaces once search and selection both adapt: today the match
fill paints over the selection fill, so a cell that is *both* selected and the
active match is pixel-identical to one that is only a match. The user asked
that this combined state read as clearly both.

## Decision

Overlay colors are resolved per fragment against the resolved cell background
beneath them, by a **continuous minimum-contrast push**: start from the
theme's color, move its brightness away from the background's until the gap
clears a fixed threshold, flipping side when clamped at an extreme. A color
that already clears the threshold is returned untouched.

Preservation is therefore conditional, and the fleet is not mostly in the
preserved case: 268 of the 592 bundled themes carry a selection color within
the threshold of their own default background, and five carry one identical to
it -- invisible today even with no TUI involved. Those themes change
appearance over unpainted background, by design. Preserving them would mean
preserving an unreadable selection, and it is what makes the guarantee below
unconditional rather than best-effort.

Three consequences are architecturally decisive:

- **Selection, match, and selected+match are one overlay layer, not stacked
  layers.** Painter's algorithm over opaque fills can express at most two
  distinguishable states on a doubly-covered cell; the top layer wins. Four
  distinguishable states therefore requires each fragment to carry a single
  resolved color chosen from its semantic state. The plan must still carry the
  state, not only the color, so planning tests can assert the state contract
  without asserting color math.
- **Fragmentation belongs in the planner, during the existing per-cell
  traversal.** Only the planner holds the background and the overlay state
  simultaneously, which the forced foreground needs; only there is the work
  damage-scoped rather than per-drawn-frame; and only there does the frame plan
  remain the complete, replayable description of the pixels that the corpus
  sweep and reuse-equivalence properties assert over. Deriving from the emitted
  background runs is rejected: they are sparse (default-background cells emit
  nothing) and they are downstream of the point where text foregrounds are
  chosen.
- **The metric is integer perceived brightness** -- the classic 0.30/0.59/0.11
  weights in fixed point, which sum to exactly 256 and so map every color to
  0...255 with `brightness(t,t,t) == t`. This is not a stylistic preference:
  `TerminalRenderPlanning` may import only `TerminalCore`, so `pow` and `cbrt`
  are unavailable, ruling out WCAG-linear and OKLab in closed form. Integer
  math also keeps the frame plan bit-deterministic, which its `Equatable`
  contract depends on.

Scope: selection fill, search-match fill, the combined fill, the forced
selection foreground, text over a match fill, and the cursor (all shapes).
The per-frame overlay color fields on the frame plan disappear; the theme's
overlay colors survive as hue seeds rather than literal paint.

## Invariants

- **I1** Every overlay fill is resolved against the resolved cell background
  actually beneath it -- after palette, reverse-video, and dim resolution.
- **I2** For every background and every theme, the four states -- unoverlaid,
  selected, active match, selected+match -- are pairwise separated by at least
  40/255 in perceived brightness.
- **I3** Text drawn over any overlay fill is separated from that fill by at
  least 100/255 in the same perceived-brightness metric used everywhere else.
- **I4** A cursor of any shape is separated from the color it is drawn over by
  at least 60/255, and its text from the cursor color by at least 100/255.
- **I5** A theme color that already satisfies its separation constraints is
  returned bit-identical -- including over unpainted default background, which
  is the only case where appearance is preserved and only for the themes that
  qualify.
- **I6** Resolution is total over all 24-bit colors, deterministic, and
  free of floating point.
- **I7** A darkening push applies one ratio to all three channels before
  quantization, and each stored channel lands within one code point of its
  ideal scaled value -- hue is preserved up to 8-bit rounding, which is the
  most any stored color can promise. (Brightening converges on the gray axis;
  see AR1.)
- **I8** The frame plan carries each fragment's semantic overlay state
  alongside its color, and overlay runs are canonical: adjacent runs on a row
  differ in state or color.
- **I9** Overlay planning never alters background runs; the overlay stays its
  own layer.
- **I10** Overlay runs are retained and damage-scoped per row, and a reused
  frame plan equals a from-scratch plan -- including when the background under
  a stationary selection is rewritten, when the match moves into or out of a
  selection, when the cursor enters or leaves a selected cell, and when
  scrollback eviction shifts a match's viewport row.
- **I11** Existing overlay geometry is unchanged: no match runs on the
  alternate screen, no runs for an absent or empty selection, viewport
  clipping and damage clipping behave as before.

## Proof obligations

- **PO1** (I2, I5, I6) A property test sweeping every bundled theme against a
  truecolor domain asserts pairwise separation and idempotence. The domain must
  include a truecolor lattice -- the reported incident is a truecolor SGR
  background, so a 256-palette domain would not reproduce it -- plus, per
  theme, its own background, selection, cursor, and foreground colors and each
  of those perturbed by one unit, which is the adversarial class the incident
  belongs to. The sweep must assert its own coverage: a theme count that fails
  loudly rather than iterating zero themes, and no silent drop of an unparsed
  theme.
- **PO2** (I3, I4) The same sweep asserts text-over-fill and cursor separation
  for every state, including a cursor inside a selection and inside a match.
- **PO3** (I7, AR3) Pin the one-code-point rounding bound on a darkening push
  over the full 24-bit domain, and that sweeping the background's brightness
  across its full range for a fixed seed flips the push direction at most once.
- **PO4** (I1) A plan over a cell whose background was painted by the TUI to
  the theme's own selection color still yields a distinguishable selection --
  the regression test for the reported incident.
- **PO5** (I2, at the pixel level) Rendering selection-only, match-only, and
  both over one background yields three mutually distinct fills, each distinct
  from the background. This replaces the current assertion that an overlap
  reads as the match alone.
- **PO6** (I1, I3, I4) Every adaptive color the production path emits is proven
  to satisfy the resolver's contract as planned or drawn, not only as resolved
  in isolation: selection-only, match-only, and the combined state, each with
  its text, and a cursor of every shape, all over a cell background that
  collides with the theme's seed. Without this the resolver can be correct
  while a planner or executor path still emits a flat color.
- **PO7** (I8, I9) Canonical-form assertions covering overlay runs corpus-wide,
  and the existing proof that a selection leaves background runs untouched.
- **PO8** (I10) Reuse-equals-from-scratch across the four scenarios named in
  I10.
- **PO9** (I11) The existing geometry tests survive, adapted to the merged
  overlay layer.
- **PO10** Planning cost is measured, not assumed: the calibrated plan-time
  workloads before and after, read as the plan line rather than the draw
  verdict, since frame planning does not run inside the draw path. The
  steady-state path with neither selection nor search active must show no
  regression. If the executor change cannot be measured because no benchmark
  scenario carries overlay runs, say so explicitly rather than reporting an
  A/A comparison as evidence.

## Non-goals

- Highlighting non-active search matches. No API exposes them today.
- Any user-facing configuration for overlay colors. Every renderer color is
  baked today and the theme catalog exposes only theme-name selection.
- Adding fields to the theme catalog. The existing derived search color is
  precedent for keeping this renderer-side, and the packer validates an exact
  key set, so a catalog field is a four-layer change for no behavioral gain.

## Accepted risks

- **AR1** Brightening a saturated seed converges it toward gray, so a
  saturated match color over a bright TUI block washes toward pale. Mitigated
  by breaking ties toward the darker candidate, which is better on both chroma
  preservation and contrast ratio. Not otherwise addressed: a chroma floor
  needs a chroma model and a second unjustifiable constant.
- **AR2** Themes with an achromatic selection color yield a gray band over
  colorful backgrounds -- legible, but colorless. Same reasoning as AR1.
- **AR3** Exactly one discontinuity per seed, where the seed's brightness
  equals the background's; a TUI animating its block color through that point
  flips the push direction once. Both sides are equally correct, and this is
  the specific property the rejected two-regime design failed.
- **AR4** The resolver sees one cell and cannot know its chosen color collides
  with an unrelated element elsewhere on screen. Strictly better than a
  constant that collided with everything at once.
- **AR5** The separation thresholds are a deliberate visibility heuristic and
  carry no minimum WCAG contrast: the two metrics disagree badly on saturated
  colors, where pure green against near-white clears the 100/255 gap at about
  1.3:1. Measuring WCAG instead would take a checked-in transfer table and a
  second metric alongside the one the fills are actually pushed in, and it
  would still not constrain the push. Every state remains distinguishable,
  which is what the reported incident is about; guaranteed text legibility on
  saturated seeds is not promised.

## Rejected ideas

- **RI1** Alpha blending the overlay. Blending a color with itself is
  invisible, so it softens the failure without removing it -- and it is shipped
  as a default elsewhere, which is not evidence that it works.
- **RI2** Threshold-else-derive: keep the theme color when it clears a bar,
  otherwise derive from the background. Two code paths producing visually
  unrelated colors, and a TUI animating its block color flips between them
  frame to frame.
- **RI3** OKLab or WCAG-linear contrast. Unavailable without Foundation under
  the purity lint, and gamut clipping in a perceptual space shifts hue, a new
  failure class the integer push does not have.
- **RI4** Three stacked overlay layers. Cannot express the combined state.
- **RI5** The existing three-candidate search-color derivation. It defends
  against the wrong background -- the theme's, not the cell's -- which is the
  bug; it is subsumed, and the search color becomes a plain hue seed.

## Critical files

- `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderColorResolution.swift`
  -- home for the brightness metric, the separation predicate, and the push;
  already holds the pure palette/reverse/dim resolution these join.
- `lib/TerminalCore/Sources/TerminalRenderPlanning/TerminalRenderPlanning.swift`
  -- the overlay run type and its state, the frame plan's overlay color fields,
  and the retired search-color derivation.
- `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift`
  -- the per-cell traversal, its hoisted per-row spans, the override order,
  overlay run emission, retained rows, and damage clipping. The hoisting
  discipline documented in this file is load-bearing for planning cost.
- `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift`
  -- the two hoisted overlay fills collapse into one per-run loop.
- `lib/TerminalCore/Tests/TerminalRenderPlanningTests/RenderPlanAssertions.swift`
  -- where canonical overlay form gets asserted corpus-wide.

Sequencing is decisive in one respect: land the layer merge and retention
change while the colors are still today's flat constants, so that commit is
pixel-identical and the riskiest plumbing can be benchmarked and proven
against the existing tests before any color changes. Adaptive colors and the
cursor's participation follow on top.

## Verification

- `swift test --package-path lib/TerminalCore` for the resolver, planning,
  and execution suites; `just test` for the full gate, which includes the
  purity lint that constrains what the resolver may import.
- The planning-cost measurement in PO10 via the existing benchmark recipes,
  taken against the pre-change revision.
- End to end in the app: `just build-run` (or `just launch` in a worktree),
  run Claude Code or Codex in a pane so user-message blocks are painted, and
  confirm a drag across a block is visible; then Cmd-F for a term inside the
  selection and confirm match, selection, and their overlap are three
  distinguishable states. Repeat under a light theme and under a theme whose
  selection color is close to the block color.

### Final benchmark pause

- [x] After implementation and tests are complete, pause before starting the PO10
  benchmark. Tell the user that the benchmark is ready to run so they can put the
  MacBook on AC power, leave it fully idle, and keep the benchmark window visible.
  Wait for the user's explicit confirmation, then run the benchmark against the
  pre-change revision and report the final measurements, verdicts, and any coverage
  limitations to the user.

## Implementation discretion

- Where resolved colors are memoized, and at what granularity.
- How the theme sweep reads the bundled themes, given they sit outside the
  package that owns the resolver.
- The specific hue seed for the search-match color.

## Commit progress

- [x] 1. Merge selection and search into retained semantic overlay runs
- [x] 2. Resolve overlay fills and text against each cell background
- [x] 3. Adapt every cursor shape and close the theme-wide contrast proof

## Implementation notes

- Semantic overlay state is stored beside the hot `PlannedCell` payload and allocated
  only when selection or search is active. Storing it in every planned cell made the
  no-overlay `retained-browse` workload 7.79% slower; the branch-free optional row
  storage restored an equivalent -0.39% result against the pre-change revision.
- No calibrated executor workload carries overlay runs, so this plumbing-only executor
  collapse has no meaningful draw benchmark in the current ladder.
- Active matches retain the existing ochre candidate as their stable hue seed, while
  the combined state uses the former blue candidate; brightness separation, rather
  than either literal seed, now carries the semantic distinction.
- Cursor resolution runs once after the existing row traversal and is retained with
  undamaged rows. A separate cursor-cell lookup made calibrated `content-churn` plan
  time 7.91% slower; the final shape measured 3.78% faster, while `style-churn` was
  inconclusive at -1.97% and no-overlay `retained-browse` was 3.70% faster against the
  pre-change revision.
