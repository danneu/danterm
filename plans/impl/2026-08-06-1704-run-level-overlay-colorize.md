# Run-level overlay colorize and closed-form brightness resolution

## Context

The background-adaptive overlay work
(plans/impl/2026-08-06-1431-background-adaptive-overlay-colors.md) resolves
overlay colors per overlaid cell inside the planner's traversal, even though
every input to that resolution varies at run granularity: selection and match
are contiguous per-row column ranges, and cell backgrounds are coalesced into
maximal runs regardless. The result is O(columns) resolver invocations per
overlaid row -- each building temporary avoidance arrays, worst case a
256-target brute-force brightness scan -- to produce a plan that carries
O(fragments) distinct colors. The mismatch also forced per-cell overlay
machinery into the hot traversal: parallel optional per-cell storage, dual
traversal closures, and the branch-dance the parent plan's implementation
notes record as the fix for a 7.79% no-overlay regression.

Goal: make overlay resolution cost proportional to output size by structure,
not by caching; delete the per-cell overlay machinery rather than tune it; and
replace the resolver's brute-force search with closed-form arithmetic. The
steady-state (no selection, no search) path must not regress.

The parent plan's invariants I1-I11 continue to bind; nothing here weakens
them.

## Decision

Two commits, in this order because the first commit's gate is bit-identity
and that gate is forfeited if colors change in the same window.

**1. Colorize at run granularity.** The traversal emits semantic layers only;
overlay state and color leave the per-cell path entirely. A per-row colorize
step -- damage-scoped exactly like run construction, running only for
replanned rows -- partitions the row into overlay state segments from the
selection/match ranges, intersects them with the row's background partition
into fragments, resolves each fragment's fill once, and rewrites the text and
decoration runs the fragments cover. Per-overlaid-row resolution count becomes
the fragment count (state segments crossed with background transitions), not
the column count. The per-cell overlay machinery is deleted, not bypassed: no
per-cell overlay storage, no dual traversal paths, no per-cell state
classification.

This commit produces a bit-identical `RenderFramePlan` for every input. The
existing suite carried through unmodified -- corpus sweep,
reuse-equals-from-scratch, every exact-value planning and execution test --
plus the additive characterization tests PO2-PO4 pin against the pre-refactor
implementation, is the gate. It is the strongest one available and the reason
the layer restructure and the resolver change must not share a commit.

**2. Closed-form resolver.** Replace the brightness search's 256-target scan
and its walk-until-valid loops with forbidden-interval arithmetic: each
avoided color forbids one brightness interval; the resolver takes the allowed
achieved brightness nearest the seed, darker on tie, probing a bounded
neighborhood to absorb 8-bit quantization and verifying every candidate
against all avoided colors. Resolved colors may differ from the scan's in
quantization edge cases; the invariant suite, not scan-output equality, is
the contract.

## Invariants

- **I1** Commit 1 yields a bit-identical `RenderFramePlan` for every input
  (terminal state x presentation x damage x retention lineage). Commit 1 may
  add test files and new assertions, but modifying a pre-existing assertion or
  fixture is evidence of a defect, not a cost of the refactor.
- **I2** An overlay fill is a function of (state, resolved cell background
  beneath the fragment, theme) alone, resolved once per fragment -- and the
  background it sees is the cell's own, before any cursor presentation is
  applied to the cell, so a block cursor inside a selection does not fragment
  or recolor the overlay run it sits on.
- **I3** Attribution granularity is pinned to today's behavior: overlay
  coverage is per column; glyph recoloring follows the cell's start column;
  decoration recoloring is per column. A wide glyph can therefore split
  mid-glyph in the decoration layer but never in the text layer.
- **I4** Every layer remains canonical-maximal over its final per-column
  keys under the existing continuation predicates, including merges across
  fragment boundaries and across the border between rewritten and unrewritten
  spans, where coincidentally equal colors must still coalesce.
- **I5** Precedence is unchanged: hover's underline color is the
  pre-selection foreground; the selection foreground is forced wherever the
  overlay state involves selection; the overlay push rewrites foregrounds
  only; the block cursor wins over the push on its span; the cursor fill
  resolves against the cursor cell's overlay fill when one covers it,
  otherwise its background.
- **I6** Colorize runs only for replanned rows; retained rows carry final
  runs and are copied forward untouched; the no-overlay path allocates no
  per-row overlay storage (a performance invariant -- the parent plan
  records the regression that rule prevents).
- **I7** The resolver remains total over 24-bit color, deterministic,
  float-free, and importable under the purity lint; a seed already clearing
  its separations is returned bit-identical; separation thresholds are
  unchanged; ties at equal distance break darker; each seed's push direction
  flips at most once across a background brightness sweep; admissibility and
  distance are judged on achieved post-quantization brightness -- never the
  requested target -- with every candidate verified against all avoided
  colors.

## Proof obligations

- **PO1** (I1) The whole suite passes on commit 1 with no pre-existing
  assertion or fixture changed: the characterization tests PO2-PO4 add are
  written first and observed passing against the pre-refactor implementation,
  and both they and the pre-existing suite pass unchanged after the refactor.
- **PO2** (I2, I5) An exact-value test pins overlay runs, fills, and text
  foregrounds for a block cursor inside a selection over a non-default
  background -- the input where resolving against the cursor-rewritten
  background would diverge. Written before the refactor, pinning today's
  output.
- **PO3** (I3) A test pins a selection boundary aimed mid-wide-glyph. The
  tail-only input I3's asymmetry describes turns out to be unreachable through
  the planner's inputs -- `Terminal.setSelection` snaps both endpoints to cell
  boundaries -- so the test pins the reachable consequence instead: overlay
  coverage, the glyph's color, and its decorations all start at the glyph's
  head column, which a per-column text layer would violate.
- **PO4** (I4) A test pins coincidental coalescing: adjacent fragments whose
  fills resolve equal, and two distinct base foregrounds pushed to one color,
  each emit a single merged run.
- **PO5** (I6) Reuse-equals-from-scratch still covers the parent plan's four
  retention scenarios, and the calibrated `retained-browse` and
  `content-churn` plan lines against the pre-change revision show no
  regression -- both recorded perf cliffs in the parent plan's notes sit
  exactly where this refactor operates.
- **PO6** (I7) The existing property suite passes unmodified on commit 2: the
  592-theme sweep's separations and idempotence, the full-domain rounding
  bound, and the single-discontinuity sweep.
- **PO7** (I7) A new property test proves the nearest-result contract the
  existing suite never checks, using an independent oracle: for each input it
  enumerates the requested-target domain, keeps the candidates admissible
  against every avoided color by achieved post-quantization brightness, and
  asserts the resolver's result matches the oracle's behavioral tuple --
  admissible, minimum achieved-brightness distance from the seed, darker on
  tie. It compares that tuple rather than exact RGB, since several colors can
  satisfy it. Inputs cover the avoidance-set sizes the planner actually passes
  and seeds sitting on quantization boundaries.

## Non-goals

- No visible pixel change in commit 1, and in commit 2 none outside
  quantization edge cases of the search itself.
- No caches or memoization anywhere; deduplication comes from structure.
- No executor changes; it already consumes runs and reads no overlay state.
- No new calibrated workload for overlay-active planning. The ladder carries
  none today, and the win is claimed as a complexity-class argument, not a
  percentage.

## Accepted risks

- **AR1** The overlay-active speedup itself is unmeasurable by the calibrated
  ladder; what is measured is steady-state non-regression. Accepted: the
  structural claim (resolution count equals fragment count) is checkable by
  reading, and a new workload would cost more than the change.
- **AR2** Commit 2 may alter resolved colors where scan and closed form round
  differently. Every such color still satisfies I7's separation, idempotence,
  and tie-break contract, and nothing in the suite or the app pins scan
  outputs.
- **AR3** The text/decoration attribution asymmetry at wide glyphs (I3) is
  inherited, not designed; this plan preserves it rather than unifying it.

## Rejected ideas

- **RI1** Keyed memoization of resolved overlay styles. Hides the granularity
  mismatch instead of removing it, adds a cache-correctness obligation, and
  leaves the per-cell machinery alive.
- **RI2** A resolve-on-transition accumulator inside the per-cell traversal.
  Same asymptotics, but keeps the dual traversal paths and per-cell overlay
  storage this plan exists to delete.
- **RI3** Keeping the brute-force scan after commit 1. Viable -- per-fragment
  call counts make it affordable -- but the closed form is simpler: no
  force-unwrap justified by prose, O(colors) instead of O(256 x colors), and
  the walk's semantics fall out as the single-interval case.

## Critical files

- `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift`
  -- the traversal, the per-cell overlay machinery to delete, run
  construction, cursor policy, and the home of the colorize step.
- `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderColorResolution.swift`
  -- the resolver whose search commit 2 replaces; its public contract and
  call sites are otherwise unchanged.
- `lib/TerminalCore/Sources/TerminalRenderPlanning/PaneFramePlanner.swift`
  -- retention; expected to survive unchanged, which PO5 checks.
- `lib/TerminalCore/Tests/TerminalRenderPlanningTests/` -- the characterization
  tests PO2-PO4 add land here, written and passing before the refactor within
  commit 1; `OverlayContrastPropertyTests.swift` is where PO7's oracle joins
  the existing resolver properties.

## Verification

- `swift test --package-path lib/TerminalCore` for planning, execution, and
  resolver suites; `just test` for the full gate including the purity lint.
- PO5's paired measurement via `just benchmark-quick baseline=<pre-change
  revision>` on `retained-browse` and `content-churn`, read as the plan line
  per agent-docs/terminal-performance.md.
- End to end: `just launch-slot`, drag a selection across a TUI-painted
  block, Cmd-F a term inside it, and confirm selection, match, overlap, and
  cursor remain the same four distinguishable states as before the refactor.

### Final benchmark pause

- [ ] After implementation and tests are complete, pause before the PO5
  benchmark. Tell the user it is ready so they can put the MacBook on AC
  power, leave it idle, and keep the benchmark window visible; wait for
  explicit confirmation, then run against the pre-change revision and report
  the measurements and verdicts.

## Commit progress
- [x] 1. perf(render): colorize overlays at run granularity
- [ ] 2. perf(render): resolve brightness separation in closed form

## Implementation discretion

- Where the colorize step sits inside the planner and the shape of its
  per-row inputs and outputs, within I6's damage-scoping rule.
- How the pre-cursor background reaches fragment resolution (reordering the
  cursor rewrite vs. preserving the covered span's originals), within I2 and
  I5.

## Implementation notes

- **Commit 1, cursor ordering.** Of the two options I2/I5 left open, the
  colorize step reorders rather than preserves: fragments are resolved from the
  cells' own backgrounds first, the block cursor then rewrites its span's cells,
  and the push spans handed to the text and decoration layers are the fragments
  *minus* the cursor's columns. The overlay layer keeps the unsplit fragment, so
  a cursor inside a selection neither recolors nor divides the overlay run.
- **Commit 1, PO3 is unreachable as written.** `Terminal.setSelection` routes
  both endpoints through `normalizedCellPosition`, which snaps them to cell
  boundaries, so a tail-only selection cannot be constructed through the
  planner's inputs and I3's text/decoration asymmetry has no reachable witness.
  PO3 was rewritten to pin the reachable consequence instead. I3 and AR3 still
  describe the attribution rules the code implements; they are simply not
  separable by a test today.
