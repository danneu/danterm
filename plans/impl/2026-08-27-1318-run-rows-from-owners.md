# The frame planner pass: one owner for a run's row, the damage, the match cursor, the readout

Source: `docs/scratch/2026-08-26-improvement-audit.md`, Wave 6 group
DRAW-1 + PROBE-7 + DRAW-7 + SELECT-7 + SELECT-2 (`## Combine these`, "The frame
planner pass"). Verified against the tree on 2026-08-27; every cited line is
current.

## 1. Problem

`RenderFramePlanner.swift` and the vocabulary beside it carry five mirrors of
facts that already have an owner:

- **Run row.** `RenderFramePlan.rows[i]` is row `i` by construction
  (`3bea76c5`), yet all four run types (`RenderBackgroundRun`,
  `RenderOverlayRun`, `RenderTextRun`, `RenderDecorationRun`) also store
  `row: Int`. Four `translated(to:)` extensions and the shifted-reuse branch in
  `FramePlanner.plan` exist only to renumber that field on every scroll frame,
  and `RenderPlanAssertions.assertCanonical` spends four assertions checking
  the mirror agrees.
- **Marker scan restriction.** `TerminalBenchmarkMarkers.scan(_:limitedToRows:)`
  takes `Set<Int>?`; its one shipped caller (`app/TerminalBenchmark.swift
  #scanMarkers`) materializes a `TerminalDamage` into an array and then a set
  per frame, and `nil` and `.full` are two spellings of "every row".
- **Overlay resolution.** While a search is live, each replanned row projects
  every viewport match (`compactMap`, O(M) per row) and then each cell scans the
  row's match list (`first(where:)`, O(K) per cell). `viewportMatches` is
  already ascending by start (`TerminalSearch#readout` walks the sorted match
  array forward), so one advancing cursor answers both questions. Matches may
  overlap (`"aaa aa"` / `"aa"` yields starts at 0, 1, 4), and the first match
  in that order wins a contested cell today.
- **Row clipping.** `hoveredColumns` and `columns` clip a stream range to a
  viewport row with two different endings. Both hover producers
  (`Terminal#explicitLink`, `#detectedLink`) yield non-empty in-range ranges,
  so the difference is unobservable today and exists only to be diverged from.
- **Search readout.** `TerminalSearchStatus` is an enum so "matches exist but
  none is selected" is unrepresentable; `TerminalSearchReadout` then places
  `status` beside an optional `activeMatch`, reintroducing that state one level
  up, and `TerminalSearch#readout` carries an unreachable `?? matches.count - 1`
  because the type permits it.

## 2. Decision

Land all five as one pass in three commits (section 7). Direction:

- **D1.** Delete `row` from the four run types. A run's row is the index of the
  `RenderPlanRow` that holds it, and every consumer that needs the row reads it
  from the row it is iterating. Copying a retained row across a scroll shift is
  one array-element copy, whatever the shift.
- **D2.** `scan` takes a `TerminalDamage`; `.full` is the only spelling of
  "scan everything". The scanner answers "did this frame write the marker", so
  it treats every row of the damage's shift region as written -- the expansion
  the caller performs by hand today moves into the scanner, and the caller
  passes the frame's damage as recorded. `TerminalBenchmarkMarkers` gains `TerminalCore` as a
  dependency (as `TerminalBenchmarkTopology` already has); its "dependency-free"
  header wording goes.
- **D3.** A replanned row resolves its search overlays with one cursor that
  advances through `viewportMatches` in start order, and the row body no longer
  projects the whole viewport match list. Matches may overlap: for a cell more
  than one match covers, the earliest match in that order supplies the overlay
  state, exactly as the ordered scan does today. `TerminalSearchReadout
  .viewportMatches` states its ascending-by-start order in its doc comment; the
  planner depends on it.
- **D4.** One row-clip rule. `hoveredColumns` is deleted; hover goes through
  `columns`.
- **D5.** The readout cannot hold a counter without its highlight. This is a
  pivot from the audit's fold-into-`TerminalSearchStatus`: the status is the
  overlay counter *and* `TerminalPaneSession`'s change key, and a range inside
  it would republish an unchanged counter whenever eviction moves the selected
  match. So `TerminalSearchStatus` stays as it is, and `TerminalSearchReadout`
  becomes the value with two shapes -- no matches, or a counter with a
  non-optional active range and the viewport matches -- with `status` derived
  from it so the four `.status` readers (`TerminalPaneSession`,
  `TerminalPTYHost`, `OccupancyProbe`, the planner) do not change. The engine
  builds the matched shape straight from the resolved match, so the dead
  default disappears with the optional; if the active range ever fails to
  resolve to a public range, the whole readout resolves to the no-matches
  shape rather than a half-populated pair.

Behavioral scope: no pixel changes, no terminal behavior changes, no CLI or
wire changes. Every existing behavioral test passes with its assertions
unedited; only structure-sensitive reads of `run.row` in tests are rewritten.

## 3. Invariants

- **I1.** A run's row and the index of the `RenderPlanRow` holding it cannot
  disagree, because the run does not carry one.
- **I2.** An incremental frame that reuses retained rows across a scroll shift
  equals a fresh full plan of the same terminal state, and draws
  byte-identical pixels to a full redraw.
- **I3.** A marker scan restricted by a damage value reports exactly the
  markers in the rows that damage changed -- its damaged rows and every row of
  its shift region -- and a `.full` restriction reports the same markers as an
  unrestricted scan.
- **I4.** For a row with any number of search matches, selection, and hover,
  the planned overlay and decoration runs are identical before and after the
  cursor and the row-clip unification.
- **I5.** The readout the engine publishes is `.matched` iff it carries an
  active range, and that range is among `viewportMatches` whenever the
  selected match is on screen.
- **I6.** `TerminalPaneSession` emits the search status once across an
  eviction that moves the selected match's coordinates but leaves the counter
  unchanged.

## 4. Proof obligations

- **PO1 (I1).** Compile-time: the four run types have no row field. The four
  `run.row == rowIndex` assertions in `assertCanonical` are deleted, not
  rewritten.
- **PO2 (I2).** Existing `PaneFramePlanningTests` reuse-across-scroll cases and
  `BitmapTestSupport`'s redraw-equivalence check, assertions unchanged.
- **PO3 (I3).** `TerminalBenchmarkMarkersTests`' restricted-scan expectations
  restated against a `TerminalDamage` built from the same rows, one case for
  `.full` vs unrestricted, and one where the marker sits on a shift-region row
  that is not a damaged row.
- **PO4 (I4).** Existing `SearchMatchRenderPlanningTests` and
  `SelectionRenderPlanningTests` unchanged; add a row where the selection
  straddles two matches with one active, a row with overlapping matches where
  the active one is not the earliest (overlay runs identical to today's
  ordered scan), and a hovered link that ends at the
  last column and one that spans a soft-wrap seam (decoration columns
  identical).
- **PO5 (I5).** A `TerminalSearchTests` case: several matches, navigate, and
  assert over the public readout that status and highlight agree and the
  active range is in `viewportMatches` when on screen.
- **PO6 (I6).** A `TerminalPaneSessionTests` case pinning one status emission
  across an eviction that shifts the selected match.
- **PO7 (D3, cost).** Per `agent-docs/measurement-discipline.md`: a
  search-dense workload (80x25 of `e`, needle `e`) in the existing `planFrame`
  timing harness in `TerminalBrowseBenchmarkSupport` (the draw benchmark times
  prepared drawing only). Baseline and candidate measured interleaved in the
  same run, sample count emitted; the no-search workload must not move.
  Reported in the commit, not frozen as a threshold.

## 5. Non-goals / Accepted risks / Rejected ideas

- **NG1.** The engine's display-row value (GRID-2/GRID-4, Wave 7's input) is a
  different row from `RenderPlanRow`. This pass neither introduces nor depends
  on it; ordering against GRID-2 is free.
- **NG2.** `RenderCursor.row` stays: the cursor is a frame-level record, not a
  member of a row.
- **AR1.** Adding `TerminalCore` to `TerminalBenchmarkMarkers` lets the engine
  into a module whose header calls it dependency-free. Accepted: the sibling
  topology module already depends on it, the scan only asks the damage a
  membership question, and the alternative keeps a wider type than the callee
  needs.
- **AR2.** The advancing cursor assumes `viewportMatches` ascending by start.
  Accepted because the engine already produces it that way; the doc comment
  makes the contract explicit, and PO4 catches a producer that breaks it.
- **RI1.** Folding the active range into `TerminalSearchStatus.matched` (the
  audit's ideal). Rejected: it makes the session's change key fire on
  coordinate motion (I6).
- **RI2.** Keeping `row` and fast-pathing only `delta == 0`. Rejected: removes
  nothing representable and every real scroll still pays the copy.
- **RI3.** A per-row column-to-state lookup table for overlays. Rejected: a
  mirror of the match list sized to the row.

## 6. Implementation discretion

- How `RenderPlanRowSelection` hands the row index to the executor's four
  drawing loops, and whether the five test-only
  `RenderFramePlan+FlatTestAccessors.swift` copies yield `(row, run)` pairs or
  the tests index `plan.rows` directly.
- The concrete shape of the two-state `TerminalSearchReadout` (enum vs struct
  with a nested non-optional payload), provided `status` remains a derived
  `TerminalSearchStatus?`-compatible read at the existing call sites.

## Commit progress

- [x] 1. refactor(render): derive run and marker rows from their owners
- [ ] 2. refactor(render): resolve row overlays through one cursor and clip rule
- [ ] 3. refactor(search): make matched readouts carry an active range

Each commit: targeted suites for `lib/TerminalCore` (and `lib/TerminalPTY` for
commit 3) plus `just lint` in the loop; `just test` before the commit. After
commit 3, tick the five `- [ ]` boxes in the audit's `## Plan of work` with the
commit hashes.

## Implementation notes

### Commit 1

- **Plan-time verdict on `content-churn` is not evidence against this commit.**
  Quick screens read the plan line `slower` (+5..+6.5%) on every candidate that
  removed `row`, while the headless `retained-browse` cell (a pure `planFrame`
  loop) read `equivalent` and the optimized `FramePlanner.plan` code shrank
  (11548 -> 10172 text bytes, matching closures within 1%). The per-frame
  samples explain it: a content-churn block mixes full plans (~320 us) with
  partial ones (~110-200 us, a plan taken mid-screen), the full-plan median
  is flat across arms, and in every candidate run on disk the baseline role
  (`A`, first in quick's single ABBA quartet) drew 9-14 partial plans per
  block against the candidate's 0-7. The skew is not a fixed property of the
  role: a later A/A run (`draw-calibration/310a8352d7ad-0000`) had it
  reversed. It is between-process variance the 2-pair rule does not absorb. A one-quartet A/A control at `HEAD` against itself
  (`scripts/terminal-benchmark-plan-calibration.py --metric plan --revision
  HEAD --workload content-churn --quartets 1`, artifact
  `.build/terminal-benchmark-plan-calibration/310a8352d7ad-0000`) reproduced
  the shape with identical code: +7.33%, range +5.35..+9.31%, partial counts
  12/9 vs 4/2. The frozen quick plan rule is therefore reading the
  partial-plan mix, not planner cost. Follow-up outside this plan: either
  recalibrate the quick plan rule (a fresh A/A series now fails its own gate)
  or make the plan metric compare like with like, e.g. report the full-damage
  plan median beside the per-draw sum. `benchmark-confirm` carries no plan
  verdict, so the commit's performance claim rests on its five draw verdicts.
- **Confirmation on the committed code.** `just benchmark-confirm baseline=HEAD`
  (artifact `.build/terminal-benchmark-comparisons/confirm/7b37c6512d0d-0000`,
  same source as this commit; only this note changed afterwards):
  `terminal-feed` equivalent +0.32%, `style-churn` equivalent -0.20%,
  `retained-browse` faster -10.47% (pairs -10.3..-10.7%), `content-churn`
  draw slower +3.43% (pairs +4.55, -1.41, +4.28, +2.57), `scrollback-stream`
  slower +3.63% (pairs -1.66, +38.29, +8.93, -42.78). The two `slower` calls
  were checked on the instrument built for the code that changed:
  `scripts/terminal-headless-draw-compare.py --both-directions --rounds 8`
  against the cached `HEAD` checkout, text-shaped full frame
  (`--workload text-shaped --clip-rows 0`): realEffect -0.06%, order bias
  -0.26%; sprite workload with the default 4-row clip: realEffect -0.12%,
  order bias +0.14%. Both sit inside the instrument's ~0.5-1% resolution, so
  `drawRenderFrame` on this plan shape did not move. The scrollback pairs
  span -43..+38%, which is the F18 caveat on that rule, not a measurement of
  this change. The quick plan-time `slower` calls are the role bias recorded
  above (`style-churn` quick: draw equivalent -0.95%, plan +2.92% with the
  same 10/1 vs 5/0 partial-plan split).
- **Draw A/A control.** `terminal-benchmark-plan-calibration.py --metric draw
  --revision HEAD --workload content-churn --quartets 2` (artifact
  `.build/terminal-benchmark-draw-calibration/310a8352d7ad-0000`): 4 A/A
  pairs, median +0.61%, SD 1.98%, range -1.39..+3.33%; the first block of the
  run drew at 3325 us against 3083-3140 us for the rest, so one quartet
  carries a warm-up slope ABBA only partly cancels. The confirm's +3.43%
  content-churn draw call sits at the edge of that A/A range rather than
  clearly outside it, and the headless paired instrument above reads it at
  -0.06%; the two together are why this commit treats it as not established,
  not as disproved.
