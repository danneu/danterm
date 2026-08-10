# Fix O(n^2) text-run coalescing in frame planning

## Problem

`FramePlanner.textRuns(_:)` builds each text run as an immutable value that is
rebuilt once per cell. Two costs follow, both quadratic in row length:

- The run-continuity test measures the open run's width with a `reduce` over its
  cells, evaluated once per cell.
- Extending a run allocates a new cell array and copies every element already in
  it, once per cell. Each copied cell carries a refcounted scalar array.

For a 179x66 grid that is roughly 1.06M reduce steps and 1.06M element copies
per frame, against ~11,814 cells of actual content.

Evidence: four 20s `benchmark-sample` profiles at `8a718dd`
(`.build/terminal-benchmark-profiles/`). `FramePlanner.textRuns` is the top
self-time application symbol in every one (562 / 714 / 719 / 959 samples), and
the associated `memcpy` and `swift_release` mass tracks it. It stays hot in
`style-churn` with text frozen, so the cost is the coalescing structure, not
glyph or text handling. These are diagnostic profiles and license no speed
claim; they only locate the work.

Desired outcome: the same runs, built in time and allocation linear in cells.

## Decision

Replace the immutable per-cell rebuild with a mutable accumulator for the open
run: append cells in place and carry the run's width as a running counter
incremented at each append. Emit a `RenderTextRun` only at a run boundary and at
end of row.

This is a pure refactor. The coalescing rule itself does not change, and the
planner stays damage-blind (see Non-goals).

Delivered as two commits so each can be measured independently; the second is
droppable if it does not move the number.

Critical file: `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift`.
Tests live in `lib/TerminalCore/Tests/TerminalRenderPlanningTests/`.

## Invariants

- **I1. Output identity.** For every input, the returned `[RenderTextRun]` is
  equal to what the current implementation returns -- same run count, order,
  start columns, cell sequences, and style fields.
- **I2. Continuity rule unchanged.** A run continues only when the next
  candidate's column equals the open run's start column plus its accumulated
  width, and foreground, bold, and italic all match. Otherwise a new run starts.
- **I3. Width and cells advance together.** The running width always equals the
  sum of the open run's cell widths, and is read only while a run is open.
- **I4. Filtered cells are invisible to coalescing.** Cells that produce no
  candidate (hidden, wide tail, padding, spacer head, empty scalars) never flush,
  reset, or extend an open run. A run spanning them splits only because the
  column arithmetic says so.
- **I5. No cross-row leakage.** Accumulator state does not survive a row
  boundary.

## Proof obligations

Existing coverage does not discharge these. `assertCanonical` checks ordering,
non-overlap, and non-mergeability of *adjacent* runs -- an over-merged run (two
runs wrongly fused into one) satisfies all three and passes. The corpus sweep
compares two runs of the same implementation against each other and has no
stored golden plan, so it proves determinism, not equivalence. The following
must be established by behavioral assertions on plan output:

- **PO1 (I1, I3).** Continuity arithmetic is correct across a wide cell interior
  to a longer same-style run, and across consecutive wide cells.
- **PO2 (I2, I4).** A gap in an otherwise same-style row splits the run,
  including a gap immediately following a wide cell.
- **PO3 (I3).** A style change starting a new run resets the accumulated width,
  observable as a correct start column for the run *after* next.
- **PO4 (I5).** Two rows with differing run geometry both plan correctly.
- **PO5 (I1).** Strongest available equivalence evidence: run the existing
  fixture corpus differentially against a retained copy of the old
  implementation, asserting equal output at every checkpoint. Temporary and not
  committed -- it exists to de-risk the refactor, not to become a permanent test.

New tests must pass against the *current* implementation before the refactor
lands; that is what makes them a regression net rather than a description of the
new behavior.

## Non-goals

- Making frame planning damage-aware. Planning the whole viewport regardless of
  damage is the larger finding from the same profiles and is deliberately left
  for separate work.
- Removing the per-cell scalar array copy in `Terminal.cell(row:column:)`.
- Changing what a run *is* -- no new splitting or merging behavior.

## Accepted risks

- **AR1.** `assertCanonical` cannot detect over-merging, the likelier failure
  mode for this change. Mitigated by PO1-PO4 asserting start columns and cell
  widths directly, and by PO5.
- **AR2.** An accumulator without an explicit open/closed gate can take the
  continuation branch on a row's first candidate at column 0 and still produce
  correct output by coincidence. Equivalence must be structural, not accidental.

## Verification

- `swift test --package-path lib/TerminalCore` and `just test`.
- Each commit is measured against its immediate predecessor, so the two are
  independently attributable: commit 1 against `8a718dd`, commit 2 against the
  tree committed in step 1. Run `benchmark-quick` for `content-churn` then
  `incremental-mixed`, and escalate to `benchmark-confirm` against that same
  immediate-predecessor baseline before any durable claim. Record the mode,
  workload, both tree identities, the median symmetric estimate, and the
  classification in the commit message.
- Re-run `just benchmark-sample full-screen-content-churn seconds=20` and confirm
  `FramePlanner.textRuns` self-time has dropped relative to the 8a718dd profiles.
- An `inconclusive` or invalid run is not a result; report it as such.

## Implementation discretion

- Whether to reserve capacity for the accumulated cells or the result array.
- How the open/closed state of the accumulator is represented, provided AR2 is
  addressed structurally.

## Commit progress

- [x] **1. Linear coalescing.** Replace the per-cell run rebuild with the
  accumulator and running width; remove the now-unused width helper. Includes the
  PO1-PO4 tests, which must be written first and shown passing against the current
  implementation. Benchmark against `8a718dd` before moving on.
- [x] **2. Fuse candidate construction.** Build candidates inline in the
  coalescing loop, removing the per-row intermediate array and its struct copies;
  drop the candidate type if nothing else uses it. Must preserve I4 -- a skipped
  cell continues the loop without touching accumulator state -- and must take each
  cell's column from the enumeration, not a separate counter. Benchmark against
  the commit-1 tree, not `8a718dd`, so this commit's contribution is attributable
  on its own and the commit can be dropped if it does not move the number.

## Implementation notes

- **Commit 1, AR2.** The open/closed gate is `OpenTextRun?`: the accumulator is
  the payload of an `Optional`, so there is no closed state whose fields could be
  read, and the continuation branch is unreachable unless a run is genuinely
  open. `startColumn` and the style fields are `let`; `cells` and `width` are
  `private(set)` and only advance together in `extend(with:)`, which is I3 held
  structurally rather than by convention.
- **Commit 1, PO5.** Discharged and reverted, not committed. A temporary
  `legacyTextRuns()` (verbatim pre-refactor coalescing) plus a temporary corpus
  test compared old against new over both fixture directories, replaying every
  feed/resize/viewport event with the cursor both visible and hidden: 1,014
  comparisons, 8,980 runs, all equal. Both scaffolds were deleted afterward.
- **Commit 1, measurement.** The targeted symbol moved decisively; the
  end-to-end draw number did not. Two 20s `benchmark-sample`
  `full-screen-content-churn` profiles on the candidate tree put
  `FramePlanner.textRuns` self-time at 130 and 137 samples, against 562 / 714 /
  719 / 959 in the four `8a718dd` profiles, and it is no longer the top self-time
  application symbol. The paired comparison against `8a718dd` did not turn that
  into an end-to-end win: `benchmark-quick` returned `inconclusive` for both
  `content-churn` (-1.02%, 2 pairs) and `incremental-mixed` (-2.55%, 2 pairs).
  One valid `benchmark-confirm` classified `terminal-feed` and `content-churn`
  `equivalent` (-0.05%, -0.23%), `scrollback-stream` and `style-churn`
  `inconclusive` (+0.80%, +1.36%), and `incremental-mixed` `slower` (+3.21%, 6
  pairs, 1 flagged outlier retained). Two further `benchmark-confirm`
  invocations were invalid (`incremental-mixed` block contract violations) and
  are not results. The `incremental-mixed` sign is not stable across runs
  (-2.55% quick vs +3.21% confirm), so that workload is unresolved rather than a
  measured regression, and no durable speed claim is made for this commit.
- **Commit 1, post-commit re-measurement.** A fourth, valid `benchmark-confirm`
  against `8a718dd` inverted the one `slower` verdict: `incremental-mixed`
  `faster` (-3.65%, 4 flagged outliers) against the earlier `slower` (+3.21%),
  with `content-churn` drifting `equivalent` -> `inconclusive` (+2.13%). Two
  valid confirms with opposite signs at the same magnitude means that workload
  does not resolve at this effect size; there is no regression and no win. Two
  further sample profiles put `textRuns` self-time at 94 and 103 samples,
  consistent with the earlier 130 / 137.
- **Commit 2, kept without a speed claim.** The plan made commit 2 droppable if
  it did not move the number, and it does not. Against the commit-1 tree,
  `benchmark-confirm` returned `terminal-feed` (+0.05%), `scrollback-stream`
  (+0.09%), and `style-churn` (+0.34%) `equivalent`, with `content-churn`
  (+1.86%) and `incremental-mixed` (+1.45%) `inconclusive` -- every sign
  non-negative. A `benchmark-quick` `faster` (-6.13%, 2 pairs) on
  `incremental-mixed` did not reproduce under confirm and is not a result.
  Sample profiles put `textRuns` self-time at 114 and 137 against commit 1's 94
  and 103: flat to slightly worse, because the candidate closure was already
  inlined into `textRuns`, so removing the intermediate array bought nothing
  measurable. Kept on the user's call for its own merits -- one fewer type, one
  fewer per-row allocation, and the filtering rule now sits beside the
  coalescing it feeds -- explicitly not as a performance change.
- **Commit 2, I4 and columns.** `OpenTextRun` now takes `ResolvedCellStyle`
  directly instead of a candidate struct, which is what let `TextCandidate` go.
  Filtered cells `continue` the loop without reading or writing `open`, and the
  column comes from `cells.enumerated()` rather than a counter of admitted
  cells, so the continuity arithmetic is unchanged. The PO1-PO4 tests from
  commit 1 carried over unmodified and are the regression net for this.
