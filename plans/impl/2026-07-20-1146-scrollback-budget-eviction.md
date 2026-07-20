# Milestone 6 slice 2: 10 MiB scrollback budget and eviction

## Context

`plan-terminal-engine/05-unicode-grid-scrollback.md` fixes a 10 MiB per-pane
scrollback budget with oldest-first eviction at grapheme boundaries, truncation
marking, and the viewport outside the budget. Scrollback is unbounded today:
`Terminal.scrollbackRows` is a plain array with no accounting or cap. The
Milestone 2 reflow slice (`plans/impl/2026-07-18-0119-primary-scrollback-reflow.md`,
AR1) deliberately deferred the budget and reserved the scroll-off push as the
seam where it lands. Milestone 6 slices 4 (selection/search anchors) and 6
(viewport offset, eviction clamp) depend on this slice existing first.

Verified premises (against `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`):

- Exactly three sites grow `scrollbackRows`: the scroll-off push
  (`moveAndFillRows`, :1761, gated primary-active at :1652), height-shrink
  displacement (`resizeHeight`, :398), and the width-reflow re-split
  (`resizeWidth`, :514). Two sites shrink it: height-growth pull-back
  (:410-414) and ED 3 (:1130).
- `GridRow.isSoftWrapped` means "continues into the next row" (`softWrap()`
  :1634; projection join :251). The fact that a row is a mid-line continuation
  lives only on the row *before* it, which eviction deletes -- so truncation
  marking requires new state.
- Row boundaries are always grapheme boundaries: clusters live inside one
  cell's `scalars`, wide pairs never straddle rows (`spacerHead` defers the
  head). Whole-row eviction can never split a cluster or produce invalid UTF-8.
- The wrap-repair helpers (:1848, :1877) touch only `scrollbackRows.last`
  behind optional binds -- front eviction cannot misdirect them, and an
  eviction that empties scrollback makes them no-op safely.
- Cursor, saved cursor, and the reflow cursor destination are viewport-relative
  (`resizeWidth` converts before returning, :517-520); the viewport is never
  evicted, so no cursor state can dangle.
- Alt screen never pushes to scrollback (existing gate); while alt is active,
  resize reflows the stashed primary against the same shared `scrollbackRows`.

## Decision

- **D1. Cost model -- pinned literals, all cells counted.** The budget is
  10_485_760 bytes per `Terminal`, covering only `scrollbackRows` (viewport
  and stashed inactive-primary rows excluded). Cost is a pure function of the
  retained rows:
  - cost(scrollback) = sum of rowCost over retained rows
  - rowCost(row) = 16 + sum of cellCost over all cells, including padding,
    wideTail, and spacerHead cells
  - cellCost(cell) = 32 + 8 x scalars.count
  Styled attributes are covered by the flat 32-byte cell overhead
  (`TerminalStyle` is fixed-size). The constants are pinned numeric literals,
  never `MemoryLayout`-derived: eviction points are observable behavior on an
  `Equatable` value and must be platform- and toolchain-independent. The model
  tracks real memory within a small factor (~2x today).
- **D2. Accounting and eviction cost -- both amortized O(1) per line feed.**
  A stored byte total is updated at every site that mutates `scrollbackRows`
  (add on push and displacement, subtract on pull-back and eviction, zero on
  ED 3) and recomputed wholesale at the width-reflow re-split.
  Recompute-on-demand is rejected: enforcement runs on every bottom-row line
  feed and would make the feed path quadratic in scrollback size. The same
  bound binds removal: once the budget is full, every line feed evicts, so
  dropping the oldest row must be amortized O(1) rather than a whole-history
  shift (at the 2-column minimum a full budget retains ~10^5 rows). The
  representation that achieves it is implementation discretion.
- **D3. Eviction -- whole rows, oldest first, strictly-over trigger.** While
  total > budget, remove the front row and subtract its cost. Exactly-at-budget
  retains. No special case for a single row exceeding the whole budget (giant
  combining-mark clusters): the same loop empties scrollback and the line's
  tail survives in the viewport.
- **D4. Truncation marking -- one Terminal-level flag.** New public read-only
  `isHistoryHeadTruncated: Bool`. After every eviction batch:
  flag = (last evicted row's `isSoftWrapped` == true). Self-correcting in both
  directions; not row-attached, so it survives reflow trivially (the truncated
  head line is the stream's first logical line and can never be re-joined).
  Projections emit no marker text -- the head line simply begins at the oldest
  retained cell; rendering an indicator is later-slice renderer policy. ED 3
  clears the flag and zeroes the account (deliberate app-directed erasure, not
  eviction). Height-growth pull-back leaves the flag untouched.
- **D5. Enforcement -- one internal routine, evict after reflow.** A single
  internal enforcement function performs D3 + D4 and is the only code that
  evicts. It runs at the end of each growth site. For width resize: reflow
  first over all retained content, then recompute and evict at the new width
  (cost is width-dependent; narrowing can legitimately trigger eviction with no
  new bytes fed). Alt-active resize needs nothing special -- the same
  `resizeHeight`/`resizeWidth` paths run against the stashed primary and the
  shared scrollback.
- **D6. No cursor or anchor clamping in this slice.** Cursor, saved cursor,
  pending wrap, and cluster context are viewport-relative and the viewport is
  never counted or evicted, so eviction cannot invalidate them. No selection,
  search, or viewport-offset state exists in the engine yet; the seam left for
  slices 4/6 is exactly the single enforcement function (I10), where a clamp or
  evicted-row counter installs later.
- **D7. Test knob -- internal override, public init pins 10 MiB.** The budget
  is stored per-Terminal; the public `init?(columns:rows:)` always pins
  10_485_760, and an internal (`@testable`-reachable) affordance overrides it
  for deterministic small-budget proofs. Budget participates in value equality
  (terminals with different budgets genuinely behave differently).

## Invariants

- **I1 (budget bound).** After any public mutating operation returns,
  cost(scrollbackRows) <= the active budget.
- **I2 (deterministic cost).** Cost is exactly the D1 function of row, cell,
  and scalar counts; identical inputs produce identical eviction points on
  every platform and toolchain.
- **I3 (accounting coherence).** The cached byte total equals a from-scratch
  recompute over `scrollbackRows` at every observation point.
- **I4 (oldest-first minimal eviction).** Eviction removes only whole rows,
  strictly oldest-first, only from `scrollbackRows`, stopping at the first
  state within budget. Viewport rows and stashed inactive-primary rows are
  never counted and never evicted.
- **I5 (retained content untouched).** Eviction deletes; it never edits a
  surviving row. All existing grid invariants hold over retained rows; the
  newest scrollback row's wrap/spacer identity is undisturbed; retained content
  is valid UTF-8 with whole clusters and whole wide pairs.
- **I6 (truncation marking).** After every eviction batch,
  `isHistoryHeadTruncated` == (last evicted row was soft-wrapped); the flag
  survives reflow, never alters projected text, and ED 3 clears it with the
  account zeroed.
- **I7 (operation-local conservation -- suffix property).** For every
  operation, compare the bounded result with an unlimited-budget twin cloned
  from the exact same pre-operation state. The bounded result's
  `primaryHistoryText` equals the twin's text minus a possibly-empty removed
  prefix, and both viewports are identical. Later history-consuming resizes may
  legitimately make an execution that was unlimited from initialization
  diverge from the bounded execution, so no suffix relationship is claimed
  between those globally independent histories after that point. Resize never
  duplicates or discards content except through eviction or by consuming the
  retained history available in its own pre-operation state.
- **I8 (cursor immunity).** Eviction never modifies cursor, saved cursor,
  pending wrap, cluster context, modes, or any viewport row.
- **I9 (determinism and chunk invariance).** Identical event sequences produce
  equal `Terminal` values regardless of feed chunking, including across
  eviction-triggering pushes.
- **I10 (single seam).** Every eviction -- scroll-off, height shrink, width
  reflow, alt-active resize -- executes through the one internal enforcement
  function; slices 4/6 extend only that function.

## Proof obligations

Tiny budgets come from the D7 override unless stated.

- **PO1 (I1, I7 below budget).** Transparency: every existing suite and every
  fixture replay passes unchanged at the production budget, with zero manifest
  edits. The existing fixture corpus (whole-`Terminal` equality across all
  chunkings) is the proof that budget state does not perturb below-budget
  behavior. `resizeFuzzMaintainsGridValidity` stays byte-identical -- its
  history-invariance assertion remains a true theorem below budget.
- **PO2 (I2).** Cost-model pin: literal expected costs for canonical rows
  (blank, full ASCII, wide CJK, spacerHead, multi-scalar emoji clusters),
  freezing the D1 constants against drift.
- **PO3 (I1, I4).** Boundary behavior: filling to exactly-at-budget evicts
  nothing; one further row evicts exactly the oldest row; a larger overshoot
  evicts the minimal count.
- **PO4 (I4, I5, I6).** Truncation: a mid-soft-wrapped-line cut sets the flag
  and leaves the projection an exact suffix of the severed line; a
  hard-boundary cut clears it; a cut at a spacerHead/wideHead seam stays
  structurally valid; a single row costing more than the whole budget empties
  scrollback with the viewport untouched.
- **PO5 (I3, I6).** ED 3 reset: count zero, flag cleared, and accumulation
  restarts from zero afterward.
- **PO6 (I6, I7).** Resize-path eviction: a height shrink whose displacement
  crosses the budget; a width reflow over a truncated head (mark survives,
  retained text stays a suffix of the pre-resize projection); height-growth
  pull-back of the truncated head row (flag persists per D4).
- **PO7 (I4).** Alt interplay: alt-screen scrolling never pushes and never
  evicts; a resize while alt is active evicts primary scrollback identically
  and both projections stay consistent.
- **PO8 (I1, I3, I4, I6, I7, I9).** Operation-local twin-oracle fuzz: a seeded
  deterministic sweep drives a tiny-budget terminal through random input,
  resizes, and ED 3. Before each operation, clone its complete state and raise
  only the clone's budget to effectively unlimited, then apply the same
  operation to both. Per step: budgeted `primaryHistoryText` is a suffix of the
  operation-local twin's; both viewports match; any removed-row count identifies
  the last evicted row and therefore the truncation flag; cached total ==
  recomputed total; grid validity holds. Random resize actions change one axis
  at a time, matching the engine's canonical height-then-width phases; the
  existing combined-resize proof establishes their composition. Continue the
  bounded execution across steps, but discard the twin after its one operation
  because later history-consuming resizes can correctly read different retained histories.
  Per seed: replaying the recorded script under a different chunking yields
  whole-value `Terminal` equality.
- **PO9 (I1, I2 production wiring).** Real 10 MiB crossing through the public
  API only (no override): feed enough content to cross the budget and assert
  the recomputed total is <= 10_485_760 yet within one row's cost of it, the
  oldest lines are evicted, and the newest retained line is intact.
  Time-limited; the one test allowed to touch the production constant.
- **PO10 (I1, I3).** The shared grid-validity assertion used across existing
  suites also asserts the budget bound and cached == recomputed, upgrading
  every existing sweep into a coherence proof.
- **PO11 (I8).** Cursor and control-state immunity, proved per eviction path
  (scroll-off push, height shrink, width reflow) against a no-eviction twin
  started from the same pre-operation state and compared immediately after the
  operation -- before any later operation can legitimately consume the now
  differing histories. Cover cursor, saved cursor, pending wrap, cluster
  continuation, and modes; where a piece of that state has no direct accessor,
  expose it behaviorally (cursor restore, a combining mark, a mode-sensitive
  sequence) and compare the resulting viewports.

Slice exit gate: `just test` green (all packages plus lint scripts), plus a
Milestone 6 slice sub-bullet in `plan-terminal-engine/14-roadmap.md` linking
the promoted plan.

## Non-goals

- Selection, search, viewport-offset anchors, or their eviction clamping
  (slices 4 and 6; this slice only provides the I10 seam).
- A compact cell/row storage representation (05 implementation discretion;
  the observable contract is representation-independent).
- A configurable or user-visible budget (05 non-goal).
- Renderer/UI presentation of the truncation flag.
- Changes to the recovery projection caps in 06 (4,000 lines / 400,000
  clusters remain a separate, smaller cap downstream of this budget).
- New fixtures or manifest changes: libvterm delegates scrollback storage to
  the embedder and has no byte-budget case to adopt (verified against the
  manifest inventory); authored cases without upstream provenance belong in
  unit suites per repo convention.

## Accepted risks

- **AR1.** The D1 model approximates real allocation (~within 2x today);
  a future compact representation changes the ratio but not the contract.
- **AR2.** After scrollback fully drains via pull-back, later viewport
  overwrites can make a persisting truncation flag conservative (the marked
  content no longer exists). It remains a truthful "an older prefix was lost"
  marker until ED 3 or a flag-clearing eviction. Documented, not repaired.
- **AR3.** PO9 feeds megabytes through the public parser in debug builds
  (estimated low single-digit seconds, time-limited); accepted in the default
  gate since package compilation already dominates `just test`.

## Rejected ideas

- **RI1.** `MemoryLayout`-derived costs: toolchain-dependent eviction points on
  an `Equatable` value.
- **RI2.** Intra-row cell-prefix trimming for the giant-row case: breaks the
  fixed-width row invariant for an adversarial-only input.
- **RI3.** Per-row truncated flag: only the stream head can ever be truncated;
  row-attached state must thread through reflow and pull-back for no gain.
- **RI4.** Marker text injected into projections: corrupts recovery/export
  round-trips; marking is metadata.
- **RI5.** Evict-before-reflow on width change: cost is width-dependent, so the
  discarded set would diverge from the contract's evict-after-reflow semantics.
- **RI6.** Logical-line-granularity eviction: one long line pins unbounded
  memory, defeating the budget.
- **RI7.** A monotonic evicted-row counter now: no consumer this slice; the
  I10 single-seam function admits it compatibly later.
- **RI8.** A fixture-schema repeat/large-feed affordance for a budget fixture:
  would exist for one provenance-less case PO9 covers better in-process.

## Implementation discretion

- Front-removal data structure and cost-cache plumbing, provided I3/I10 and
  D2's amortized-O(1) bound hold.
- Exact shape of the internal budget override and test-only accessors.

## Implementation notes

- The front-removal buffer uses a logical head index and periodically compacts
  after a proportional number of removals, preserving amortized O(1) eviction
  without making physical storage layout part of `Terminal` equality.
- I7 and PO8 use an operation-local unlimited twin. The original global twin
  premise contradicted the accepted behavior where later resizes consume the
  different histories created by an earlier eviction.

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` -- the sole
  implementation seam: scrollback storage and accounting, the five mutation
  sites named in Context, and the new enforcement routine.
- `lib/TerminalCore/Tests/TerminalCoreTests/` -- budget suites and the shared
  grid-validity assertion.
- `plan-terminal-engine/14-roadmap.md` -- slice sub-bullet at exit.
