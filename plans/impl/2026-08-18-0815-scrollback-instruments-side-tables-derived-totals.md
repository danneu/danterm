# Scrollback pass: one instrument set, owned side tables, derived totals

Audit findings S32, S31, S18 (docs/scratch/2026-08-11-simplification-audit.md),
implemented as one sequenced pass over
`lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift`. S31 and S18 are
symptoms of the audit's T1 root cause -- one fact held in two places that every
mutation site must move together by hand. S32 shares the file and the pass.

## Problem

Verified live against the tree on 2026-08-18; all three findings have grown
since the audit:

- **Instruments (S32).** Nine copy-pasted task-local counter enums -- eight
  opening `LogicalLineStore.swift` (lines ~31-268), one in
  `TerminalSearch.swift` -- identical but for a field name and the `record`
  arity. The store's file header says what belongs in the file; 230+ lines of
  instruments do not, and one of them is recorded only from `Terminal.swift`.
  Adding a tenth instrument means pasting the pattern again, which is exactly
  what happened since the audit counted seven.
- **Side tables (S31).** `spillsBySequence`, `fillStylesBySequence`, the
  `spillBytes` accumulator, and the `metadataBytes` charge cache are maintained
  by hand at ~15 sites; `refreshMetadataCharge()` is called 11 times, and the
  sites have drifted into three different emptiness guards for the same
  question (`spillBytes > 0`, `spillsBySequence.isEmpty == false`,
  `record.hasTrailingFill`). A missed prune leaks; a missed refresh loosens the
  `31/I2` byte bound, and only the `census` assert -- which the write path
  never reads -- catches it.
- **Grand totals (S18).** `grandDisplayRowTotal` / `grandContentUnitTotal` are
  stored and hand-adjusted at every mutation site even though the block index
  already holds them: blocks carry absolute `rowStart`/`contentStart` against
  the monotone evicted counts, so each total is an O(1) read off the last
  block. The file carries two comments explaining the double-subtract ordering
  hazard -- scar tissue from a real past bug (`removeLastDisplayRow` moved the
  totals after retiring the block). `firstBlockNumber` is the same redundancy:
  it always equals `firstRecordSequence / blockSize` while records exist, and
  `retireEmptyHeadBlocks` exists only to re-establish that.

## Decision

Three commits, in this order. Each lands green with its tests.

**1. Instrument unification.** One instrument enumeration and one task-local
tally, in their own `TerminalCore` file, replace the nine counter enums; every
record and measure site moves to the shared API. The store's file then starts
at the store. The justification prose the counters carry (`31/PO7`, `31/I7`,
`31/AR5`, `31/AR3`, the free-global-vs-member rationale) survives once, on the
new declarations.

**2. Side-table ownership.** One value type inside the store owns the spill
table, the fill table, and their byte charge; every mutation of a table moves
the charge in the same operation, so a stale charge and a divergent emptiness
guard become inexpressible. The `metadataBytes` cache and
`refreshMetadataCharge()` are deleted: `chargedBytes` sums `bytesInUse`, the
live index charge, the live open-scratch charge, and the side-table owner's
charge.

**3. Derived totals.** `grandDisplayRowTotal` and `grandContentUnitTotal`
become computed properties over the block ring; `firstBlockNumber` becomes
computed from `firstRecordSequence`; `retireEmptyHeadBlocks` is retired by
dropping the head block where the head-sequence quotient advances. The stored
fields and their maintenance sites are deleted. The two ordering-hazard comments
lose only their grand-total half: the surviving requirement -- that
`evictOneDisplayRow` and `removeLastDisplayRow` update the current block before
record removal can retire that block, or the decrement lands on the wrong
surviving block -- keeps a shorter comment at each site. This commit is
benchmark-gated (I7): if the benchmark rejects it, the stopping point is the
stored fields plus a mutation-site assertion that they equal the block-derived
values -- written here so that fallback is a decision, not a discovery.

Sequencing rationale: commit 1 is mechanical and moves the instruments out of
the file before the riskier edits; commit 3 goes last because it alone carries
a perf gate and its fallback must not entangle the other two.

## Invariants

- **I1** A measurement observes exactly its own body's spend. Nested
  measurements -- of a different instrument or of the same one -- neither zero
  nor double-count an enclosing measurement, and recording with no active
  measurement remains a no-op. (Three existing test sites in
  `TerminalSearchTests.swift` nest measures today.)
- **I2** Every existing recording site keeps its operation: the same events
  are counted at the same points before and after unification. (Restates the
  invariant the search-unification plan recorded for the search cost
  counters.)
- **I3** The side-table byte charge cannot be stale: only the type that owns
  the tables can move them, and each mutation updates the charge in the same
  operation. A full recount agrees with the maintained charge after every
  mutation trigger.
- **I4** `chargedBytes` stays O(1) on the write path (the `research/31/F8`
  premise for caching it at all): every term is either computed from live
  capacities or maintained by the single owner of the state it prices.
- **I5** The `31/I2` byte bound and eviction depth are unchanged: the same
  history at the same budget retains the same rows before and after commit 2.
- **I6** The grand display-row and content-unit totals equal the independent
  recounts after every mutation. After commit 3 a block update and a total
  update cannot disagree, because there is only one update.
- **I7** Commit 3 is not called free, and it changes both the retained-history
  read path and the history mutation path, so two calibrated workloads decide
  it: `retained-browse` for the read path and `terminal-feed` for the mutation
  path. `just benchmark-confirm baseline=<pre-commit-3 rev>` is the authority
  for both -- `quick` may be run first for a cheap signal, but it decides
  nothing here, because "this changes no performance" is a claim only `confirm`
  has the sensitivity to support (agent-docs/terminal-performance.md). `faster`
  or `equivalent` on both accepts. Anything else triggers the fallback named in
  the Decision: `slower` on either, or `terminal-feed: inconclusive`, which is
  the absence of an answer. The single documented exception is
  `retained-browse: inconclusive`, which that doc states means the difference is
  smaller than the ladder resolves; it accepts. `scrollback-stream` is recorded
  as descriptive evidence only -- it covers the same mutation path as the
  narrower `terminal-feed`, and it emitted false directional verdicts in 3 of 8
  identical-source invocations, so it cannot decide this.
- **I8** No external surface changes anywhere in the pass: instruments,
  tables, and totals are internal; tests reach them via `@testable` as today.

## Proof obligations

- **PO1** (I1) A spec test for the shared tally's nesting semantics -- an
  inner measurement of another instrument and of the same instrument, each
  leaving the outer result intact -- plus the existing nested sites in
  `TerminalSearchTests.swift` staying green.
- **PO2** (I2) The existing counter-calibration tests (the `>= 1` guards that
  distinguish "not measured" from "measured zero", per
  agent-docs/measurement-discipline.md) pass unmodified in meaning across all
  three test packages that measure (`TerminalCoreTests`,
  `TerminalRenderPlanningTests`, both `TerminalPTY` test targets).
- **PO3** (I3) The existing oracle test "The maintained charge agrees with a
  full recount after each of the six triggers"
  (`TerminalLogicalLineStoreTests.swift`) stays, with the drift assertion
  living wherever the charge now lives.
- **PO4** (I5) The existing budget and charge tests stay green: charged bytes
  under budget on content and blanks, spill-table charge retention, trailing
  fill charged and released, capacity-reserve tests.
- **PO7** (I5) A new behavioral fixture pins retention depth, which the tests
  in PO4 do not: they prove the charge agrees with its recount and stays under
  capacity, so an implementation that consistently overcharges a side table
  passes them while evicting extra history. Feed a history with spills and
  trailing fills at a budget where the side-table charge decides the boundary,
  then assert the retained row count and the oldest retained row's content --
  the same values before and after commit 2.
- **PO5** (I6) The existing recount-oracle test "Display and content totals
  agree with independent recounts after every mutation" and the
  `TerminalLogicalLineFoldTests` total assertions stay green;
  `independentDisplayRowRecount()` and its content sibling remain the oracle
  and are not derived from the same source as the totals.
- **PO6** (I7) The benchmark protocol in I7, run and recorded in the commit
  message of commit 3 (or of the fallback): mode, workload, both tree
  identities, the median symmetric estimate, and the classification, for both
  deciding workloads and for the descriptive `scrollback-stream` line.

## Non-goals

- No restructuring of `Terminal.swift` or the search subsystem; the recording
  sites there change spelling only.
- No change to the `Census` reporting shape, the benchmark harness, or any
  threshold.
- The open-tail scratch tables (`openHyperlinks`, `openIdentityRuns`) keep
  their current ownership; only the sequence-keyed tables and their charge move
  into the new owner.

## Accepted risks

- **AR1** Commit 3 may be rejected by either deciding workload. Accepted: the
  fallback (stored totals plus a derived-equality assertion at mutation sites)
  is the honest stopping point and is pre-authorized above.
- **AR2** The shared tally trades nine direct field accesses for one
  instrument-indexed access on recording paths. All sites are same-module, so
  docs/design/2026-07-29-cross-module-value-dispatch.md imposes no constraint;
  the record path stays an inlineable task-local read either way.
- **AR3** Commit 2 is not benchmark-gated, so a constant-factor feed-path cost
  from summing `chargedBytes` on each read could land unmeasured. Accepted: I4
  already forbids the shape that would matter (any term that is not O(1) off
  live capacities or maintained by its owner), and gating a commit whose only
  exposure is a few additions per evicted row buys less than the run costs.

## Implementation discretion

- Instrument naming, the tally's storage layout, and the new file's name.
- The exact split of cached versus live-computed terms inside `chargedBytes`,
  provided I3 and I4 hold.

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift` -- all three
  commits.
- `lib/TerminalCore/Sources/TerminalCore/TerminalSearch.swift`,
  `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` -- recording sites
  (commit 1).
- New instruments file under `lib/TerminalCore/Sources/TerminalCore/`.
- Measure sites across `lib/TerminalCore/Tests/TerminalCoreTests/`,
  `lib/TerminalCore/Tests/TerminalRenderPlanningTests/`, and
  `lib/TerminalPTY/Tests/` (commit 1, mechanical).
- `docs/scratch/2026-08-11-simplification-audit.md` -- stamp each finding's
  Status cell with its landing commit, matching the audit's own convention.

## Verification

Per commit: TDD (failing test first where a new invariant is pinned -- PO1 is
the one genuinely new test), then
`swift test --package-path lib/TerminalCore`, the two `TerminalPTY` test
targets for the cross-package measure sites, and `just test` before each
commit. Commit 3 additionally runs the I7 benchmark protocol
before the implementation is accepted.

## Commit progress
- [x] 1. Instrument unification
- [x] 2. Side-table ownership
- [x] 3. Derived totals (landed as the pre-authorized fallback; I7 rejected the
      derivation)

## Implementation notes

- The shared tally links each `measure` scope to the one it nests inside and
  forwards every recording outward, so an enclosing measurement keeps counting
  through a nested one. That is the reading of I1 that keeps every existing
  count identical: the nine separate task-locals already let an outer scope of
  one instrument observe its own body through an inner scope of another, and
  every nested site in the suite pairs two different instruments. The same
  rule also settles the same-instrument case the old shape left undefined --
  each scope counts the operation exactly once.
- `record`'s amount label is `count:` for every instrument, replacing the old
  `rows:` / `cells:` / `units:` spellings.
- The side-table owner keeps a maintained `chargedBytes` refreshed inside each
  of its mutating methods, rather than computing the charge on every read. The
  hash-table term needs a bucket-count loop per dictionary, and `chargedBytes`
  is read once per admission and once per eviction step, which is the cost
  `research/31/F8` Observation 3 recorded. The store's other terms -- the index
  charge and the open-scratch charge -- are plain capacity arithmetic, so those
  are read live and their eight `refreshMetadataCharge()` calls simply went
  away.
- `census` reports the side-table line from a full recount rather than the
  maintained total, so the existing oracle test compares two independently
  derived numbers (PO3). `openScratchBytes` stays inside that census line, which
  keeps the `Census` shape unchanged as the Non-goals require.
- `dropHeadRecord` used to skip the fill table when the record carried no fill
  bit. The owner asks `fillStylesBySequence.isEmpty` instead, which costs one
  hash probe per eviction in a history that holds any fill at all. Taken so the
  three drifted emptiness guards collapse to guards the owner alone states; the
  eviction fast path for a store with no side tables is unchanged.
- The audit's ranked-findings Status cell holds commit hashes, which a commit
  cannot carry for itself, so S32 got the file's other convention -- a
  `**Status note.**` paragraph in its section. The hash cell still needs a
  stamp.
- **Commit 3 landed the fallback: I7 rejected the derivation.** The derived form
  was built in full -- computed `grandDisplayRowTotal` and
  `grandContentUnitTotal` over the block ring, computed `firstBlockNumber`, the
  eight maintenance sites deleted, and `retireEmptyHeadBlocks` replaced by one
  head-block drop where the head-sequence quotient advances across
  `dropHeadRecord`'s `firstRecordSequence += 1`. It passed `just test` and the
  whole `TerminalCore` suite, and then the benchmark refused it. Evidence (PO6),
  `just benchmark-confirm baseline=5dfdc6b4`, baseline tree
  `dad1ea862c75c98fe0fedc57b3aa387b9fe10fac`, candidate tree
  `46c8a59a142538e7da7a985db99b725a1fa29d39`:
  - `retained-browse`: **slower**, +1.17% symmetric median of 4 pairs (deciding;
    threshold 1.05%). This is the reject.
  - `terminal-feed`: equivalent, +0.10% symmetric median of 2 pairs (deciding;
    accepts on its own).
  - `scrollback-stream`: faster, -4.54% symmetric median of 4 pairs
    (descriptive only per I7, and inside its own 3.5-point distrust band).
  - Non-deciding cells, recorded for completeness: `content-churn` slower
    +6.27%, `style-churn` equivalent +0.19%, `incremental-mixed` -3.03%
    (uncalibratable). The two churn cells cannot be attributed to this change --
    it touches no drawing path -- and no rerun was taken, because the schedule is
    frozen and a valid invocation is not re-rolled.
  - Artifact: `.build/terminal-benchmark-comparisons/confirm/46c8a59a1425-0000`.
- What landed instead is exactly what the Decision pre-authorized: the stored
  fields, plus `assertGrandTotalsAgreeWithBlockIndex()` comparing both totals
  with the block-derived values. It runs from a `defer` at the top of every store
  operation that can move a total -- `admit`, `closeOpenRecord`,
  `reopenTailRecord`, `repairClearedSpacer`, `forceSplitOpenRecord`,
  `evictOneDisplayRow` (so `evictToBudget` too), `truncateTail`, `removeAll`,
  `setWidth` -- rather than inside the helpers that move the totals, because a
  helper runs mid-operation where the two representations are transiently and
  legitimately out of step: `addContentUnits(_:toBlockContaining:)` decrements an
  earlier block whose successor's `contentStart` only becomes right again once
  the emptied tail block retires. The operation boundary is the first point where
  equality is required.
- The assertion was proved non-vacuous before it was kept: dropping
  `grandDisplayRowTotal -= 1` from `evictOneDisplayRow` made
  `TerminalLogicalLineStoreTests` fail on it, and restoring the line made the
  suite green again.

## Re-measurement of the I7 reject (2026-08-18)

The rejecting number does not reproduce, and a decision-grade run accepts the
derivation. Commit 3's `retained-browse: slower +1.17%` was re-measured three
times; every run returns `equivalent` on both deciding workloads.

| run | baseline | candidate tree | arm | load at invocation | `retained-browse` | `terminal-feed` |
| --- | --- | --- | --- | ---: | --- | --- |
| original (commit 3) | `5dfdc6b4` | `46c8a59a1425` | `a` | 14.78 | **slower +1.17%** | equivalent +0.10% |
| arm flip | `5dfdc6b4` | `d05d288b23c4` | `b` | 9.10 | equivalent +0.30% | equivalent -0.74% |
| exact reproduction | `5dfdc6b4` | `46c8a59a1425` | `a` | 4.44 | equivalent -0.00% | equivalent -0.61% |
| **decision** | **`78f49c1d`** | `167ecd3841ad` | `a` | **1.70** | **equivalent -0.26%** | **equivalent +0.58%** |

The first three hold the compiled source byte-identical to the rejected
candidate: the reproduction reuses the identical candidate tree and therefore the
identical physical arm, and the arm-flip tree differs from it by one untracked log
file that no build reads, which is the `research/33/F28` technique for varying the
slot while holding source fixed. The decision run is the one that matters for
re-landing: its baseline is the commit carrying the fallback, so it prices the
derived form against what actually shipped.

What this establishes:

- **The derivation is accepted under I7.** The decision run reads `equivalent` on
  both deciding workloads, at the quietest host conditions of the four (0.17 per
  processor), with no invalidations. I7's rule is `faster` or `equivalent` on
  both, so this accepts.
- **The arm slot is not the variable.** The two arms sit 0.30 points apart, less
  than the ~0.6 points agent-docs/terminal-performance.md attributes to a slot
  change. The same tree on the same arm moved 1.17 points between the original
  and the reproduction, far outside that doc's 0.3-point same-tree scatter. The
  likeliest cause is the original invocation's host conditions: it began at load
  14.78, while three test suites from the same session were still draining.
- **The original invocation never supported a decision.** It is not reproducible,
  so it is evidence neither for nor against the derivation. The reading rule for
  the re-measurement was written before any run and fixed that outcome in
  advance, including the bar against a third tie-break run.
- **The middle two runs were taken on a noisy machine, and the decision run was
  not.** On identical source, `style-churn` read `equivalent +0.32%` then `faster
  -2.61%` -- a false directional verdict past both its 1.75% threshold and its
  1.8-point distrust floor, from a rule that made 0 false calls across the 8 A/A
  invocations of `research/33/F28`; `scrollback-stream` likewise went `slower
  +2.60%` then `faster -3.43%`. The decision run, taken after waiting for load to
  fall below 2.0, produced no directional verdict anywhere in the suite. That is
  what separates it from the two before it.
- **`content-churn: slower +6.27%` from commit 3 was noise.** It reads
  `inconclusive` at +0.88%, +1.24% and +0.98% across the three re-runs.

So the structural fix S18 asks for is not blocked by measurement. The stored
fields and `assertGrandTotalsAgreeWithBlockIndex()` can be replaced by the
derived form; the assertion is worth keeping only until that lands, since a
computed total cannot drift from the block index.

Artifacts (`.build/` is disposable; the values above are the durable record):
`.build/terminal-benchmark-comparisons/confirm/` holding `46c8a59a1425-0000`,
`d05d288b23c4-0000` and `167ecd3841ad-0000`.

## Follow Up

- Stamp the S32, S31 and S18 rows' Status cells in
  `docs/scratch/2026-08-11-simplification-audit.md` with their landing commit
  hashes. All three sections now carry a `**Status note.**` paragraph; only the
  ranked-table cell is pending, because a commit cannot carry its own hash.
- **Superseded by the re-measurement above.** The +1.17% does not reproduce, so
  there is nothing to attribute yet. The decomposition run this bullet proposed
  (a candidate deriving *only* `firstBlockNumber`, to separate the division from
  the two ring subscripts) is still the right probe, but only if a reproducible
  cost is established first.
