# Pane search stops taxing the feed path

## Context

`plans/impl/2026-08-10-1631-pane-search-visible-matches.md` replaced the
whole-history rescan with an ordered match index. The index's *shape* is right
-- measurement confirms its cost is flat in scrollback depth, which is what I5
and I6 asked for. What is wrong is the scan primitive underneath it and the
bookkeeping around it, and the user feels both:

1. Opening a search over full scrollback stalls. The find bar sends
   `.searchNeedleChanged` on every keystroke, so this is the per-character cost.
2. Leaving a needle up while tailing a heavy log collapses throughput.

Measured headlessly against `TerminalCore` at 180x50, release configuration:

| | ms |
|---|---|
| `beginSearch` over 20k fed lines / 40k fed lines | 176 / 308 |
| feed 2000 lines, no search | 4.3 |
| feed 2000 lines, search open, 6-char needle, no new matches | 60.5 |
| same, 1-char needle / 24-char needle | 27.6 / 198.5 |
| same, 6-char needle, with 2500 / 5000 / 8939 existing matches | 76.2 / 92.3 / 115.9 |
| three per-frame search reads, x1000 | 509 |

Four independent causes, all in
`lib/TerminalCore/Sources/TerminalCore/Terminal.swift`:

- **P1. The scan allocates per cell.** `searchMatches` materializes
  `units: [ProjectionUnit]` for its whole window before matching, and
  `ProjectionUnit.scalars` is `[Unicode.Scalar]`, built by `Array(cell.scalars)`
  in `forEachRowTextUnit` -- one heap allocation per projected cell, even though
  `GridCell.scalars` is already the allocation-free `TerminalScalars`, whose own
  header comment describes exactly this cost on the render path. The same
  function reads rows through the `activeProjection()` facade, one `locate()`
  per row, which `Terminal.swift`'s own comment on `activeProjectionRows()`
  calls quadratic-ish for all of history. Cost works out at ~3.9 us per row,
  ~21 ns per cell -- one malloc/free pair and nothing else.
- **P2. Every scrolled row re-projects its neighbours.** `searchMatches` pads
  its window with `contextRows = max(1, needle count - 1)` rows on the left and
  one row on the right. `synchronizeSearchIndexPrefix` runs per scrolled-off row
  via `enforceScrollbackBudget`, and asks for exactly one newly closed row, so
  each row is projected `needle count + 1` times as the window slides past it.
  The predicted ratios for 1/6/24-char needles are 3 : 7 : 25; the measured
  ratios are 3 : 7.2 : 25. That accounts for the whole needle-length curve.
- **P3. Two full passes over the match list, per scrolled row.**
  `synchronizeSearchIndexPrefix` runs `confirmed.lazy.filter {...}.count` and
  `prefixMatches.removeAll {...}` *above* its `newEnd > oldEnd` guard, so both
  run even when nothing moved. Quadratic in match count, and the reason a needle
  that matches most lines of a log is worst.
- **P4. Opening a needle walks history twice.** `beginSearch` scans the whole
  stream for `matches`, then scans the prefix again for `prefixCandidates`;
  `rebuildSearchIndex` does the same. The second scan is derivable from the
  first.

## Decision

Matching becomes a **streaming scan with carried boundary state**, and the
index's per-mutation bookkeeping becomes arithmetic on a sorted sequence rather
than a filter over it.

**The scan primitive streams.** It emits `(key, start anchor, end anchor)` to a
closure instead of building a units array, derives the search key straight from
`TerminalScalars` so the ASCII single-scalar case never touches the heap, and
walks display rows through one `locate` plus `LogicalLineStore.advance(_:)`
instead of a `locate` per row. `ProjectionUnit.isHardBoundary` is not consulted
by matching at all -- only the selection-expansion walk needs it -- so the scan
stops constructing units.

The scan must keep projecting exactly what it projects today: the *painted* row
trimmed by `projectedCellEnd`, plus the seam spacer and the alt-screen
`isSoftWrapped` override that `ProjectionRows.subscript` applies. Switching to
the store's content walk would silently change match results.

**Prefix advance carries the window instead of re-reading it.** Under the
dormant convention the prefix scan already uses -- `lastContentRow` supplied as
the boundary, so every non-soft-wrapped row below it emits its `"\n"` -- a row's
unit stream is a function of that row alone and of no later row. That is what
makes closed records scannable once and never again. So the index carries the
last `needle count - 1` units ending exactly at the boundary, and advancing the
prefix by k rows scans exactly k rows: no left context, and no right context at
all, because a match ending past the boundary is not a prefix match. Dormancy
stays resolved by counting, never by rescanning.

The carried window is dropped from the front on head eviction (a unit that no
longer exists cannot start a match) and rebuilt by a bounded backward walk
whenever the boundary regresses, the needle changes, a reflow rebuilds, or the
window is shorter than the available history should allow. The rebuild is the
fallback that makes an unenumerated store mutation degrade to a rescan rather
than to wrong matches.

**Eviction and truncation become arithmetic.** `prefixMatches` is sorted by both
`start` and `end`, so head eviction drops a prefix and tail truncation drops a
suffix, each located by binary search. With survivors `[d, M-t)` and confirmed
count `C`, the new confirmed count is `max(0, min(C, M - t) - d)` -- exactly
what today's linear filter computes, in O(1). When neither the boundary nor the
retained start moved, the whole call is skipped. `prefixMatches` becomes a
`Deque` so a head drop does not memmove the list on every scrolled row.

**Opening a needle walks history once.** Scan `evictedRowCount..<prefixEnd`
under the dormant convention to get `prefixMatches`, derive
`confirmedPrefixMatchCount` with the existing
`prefixMatchCount(in:throughContentRow:)` binary search against the real last
content row, and take the full ordered sequence -- for the initial position, the
reveal, and the return value -- from the bounded `currentSearchMatches` read.
The equivalence holds in all three cases (`L >= P`, `L < P`, and no content
anywhere, where the count must be forced to zero). `rebuildSearchIndex` collapses
the same way.

**`beginSearch` gains the alt-screen guard its readers already have.**
`searchStatus`, `activeSearchMatchRange` and `searchMatchRanges` all return
nothing under the alternate screen, so today a search begun there maintains an
index nobody can read over a projection with an alt-specific soft-wrap override.
Making `beginSearch` a no-op there is the existing contract (parent plan I11)
stated once instead of three times, and it deletes the only case the carried
window would otherwise have to model.

Critical files: `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`
(`searchMatches`, `synchronizeSearchIndexPrefix`, `rebuildSearchIndex`,
`beginSearch`, `forEachRowTextUnit`, `SearchMatchIndex`,
`widenedSearchDamageRows`), `LogicalLineStore.swift` (a display-row walk built
on `locate` + `advance`), `lib/TerminalCore/Package.swift` (`DequeModule`),
`lib/TerminalCore/Tests/TerminalCoreTests/TerminalSearchTests.swift`.

## Invariants

These extend, and do not replace, the parent plan's I1-I11.

- **J1.** Feeding output with a search open re-projects each row that scrolls
  off a bounded constant number of times -- a count independent of the needle's
  length. It does not say the feed path holds *no* needle-scaled term: the
  matcher compares O(needle length) per unit and the parent plan's I9 requires
  the damage radius to span the needle. J1 is about re-projection, which is the
  term that made a 24-character needle 7x a 1-character one; AR-D holds the two
  residual terms.
- **J2.** Feed cost is also independent of how many matches history already
  holds.
- **J3.** Opening or editing a needle walks each retained display row at most
  once.
- **J4.** The set of matches is unchanged by all of this. The scan agrees with
  an oracle that is independent of the scan: project the stream to a string and
  find the needle in it under the same case folding.
- **J5.** A store mutation that moves neither the closed-prefix boundary nor the
  retained start does no index work at all.
- **J6.** Every mutation the store admits either maps to a prefix drop, a suffix
  drop, or a forward advance of the carried window -- or it invalidates the
  window and forces a bounded rebuild. There is no fourth outcome. The detector
  is exactly as strong as the store's own immutable-middle invariant
  (`LogicalLineStore.swift` I5: the head record's header and the tail record are
  the only writable bytes, and a head write is a trim that moves the retained
  start). A producer that rewrote a retained byte in the middle would move none
  of the observables and would not be detected -- that is a violation of the
  store's I5, and the store's own oracle tests are where it must be caught, not
  here.

## Proof obligations

- **PO-A.** J4, and the fixed point everything else is rewritten against. A new
  oracle test that does not call `searchMatches`: project the whole stream to a
  string, segment it into grapheme units, fold **each unit independently**, and
  compare the needle's separately segmented and independently folded units
  against every overlapping window of the stream's units, mapping the winning
  windows to anchors. Whole-string folding is *not* the oracle: it matches `"ss"`
  against `"ß"`, which `canonicalCaselessSearchLimits` asserts must fail, so an
  oracle built that way would bless a changed match set and pull the streaming
  rewrite toward the wrong semantics. This lands **before** the scan is touched.
  The existing
  `windowedMatchesEqualWholeSequenceRestriction` and
  `retainedIndexMatchesFullRescanAcrossStoreMutations` compare the index to
  `scannedSearchMatchRanges`, which is the same primitive on both sides -- they
  pin index-versus-scan, not scan-versus-truth, so a change to what a row
  projects passes them silently.
- **PO-B.** J1 -- `ProjectionRowCounter.measure` around a fixed feed with a
  search open returns the same count for a 1-character and a 24-character
  needle, and that count is proportional to the rows fed.
- **PO-C.** J2 -- the same measurement is unchanged between a needle matching
  nothing and a needle matching most rows.
- **PO-D.** J3 -- `ProjectionRowCounter.measure { beginSearch }` over deep
  history returns approximately the retained row count, not twice it, and
  `WholeProjectionCounter` stays at zero.
- **PO-E.** J5 -- a mutation that closes no record and evicts nothing spends
  zero projection rows.
- **PO-F.** J6 -- extend
  `retainedIndexMatchesFullRescanAcrossStoreMutations`, which today only feeds
  and resizes, to each boundary regression the store can produce:
  `truncateTail` via both resize directions, `reopenTailRecord` via
  `restoreWrapClaimBeforeCursor`, `removeAll` via `ED 3`, and head eviction with
  a non-empty carried window. Add a needle spanning the prefix boundary and a
  needle longer than the units history holds. Each asserts against PO-A's
  oracle.
- **PO-G.** The existing dormancy assertions keep passing unchanged --
  `blankRowBoundariesFollowTheFullProjection` is the one that fails if the
  derived confirmed count is not forced to zero when the stream holds no
  content, and the `"\n"` case of
  `windowedMatchesEqualWholeSequenceRestriction` is the `L < P` path of the
  single-scan equivalence.
- **PO-I.** The alt-screen guard on `beginSearch` is covered behaviorally.
  `alternateScreenReportsNoSearch` today discards `beginSearch`'s result and
  asserts only on the guarded reads, so deleting the new guard leaves the suite
  green. Assert that `beginSearch` returns false under the alternate screen and
  that leaving the alternate screen afterwards reveals no search state -- the
  reads still report nothing, and no index survives to be advanced by later
  output.
- **PO-H.** `navigationUsesTheOrderedIndex` keeps its counter assertions
  meaningful: the new streaming walk must still record into
  `ProjectionRowCounter` for the rows it walks, or that test silently becomes a
  no-op.

## Experiments

Each fix is measured before it is trusted. The probe is a throwaway
`@Test` under `lib/TerminalCore/Tests/TerminalCoreTests/`, run with
`swift test --package-path lib/TerminalCore -c release --filter <name>`, and
deleted when the slice lands; the permanent guard is the counter test named in
the proof obligations. Per `agent-docs/measurement-discipline.md`, every
directional claim is a before/after pair taken in one machine session -- no
threshold is frozen into a test on wall clock.

| # | Idea | Experiment | What would refute it |
|---|---|---|---|
| 1 | The scan's cost is allocation, not work | Feed-with-search probe before and after the streaming rewrite, at a fixed 6-char needle | Per-row cost does not fall by roughly the ratio of cells to matches, meaning the cost was elsewhere |
| 2 | The needle-length curve is the context window | Re-run the 1 / 6 / 24-char needle sweep after the carried window lands | The curve survives, meaning a second needle-scaled term dominates -- most likely `widenedSearchDamageRows` |
| 3 | The match-count term is the linear filter and the array memmove | Re-run the 2500 / 5000 / 8939-match sweep after the arithmetic and `Deque` land | Cost still grows with match count, meaning a third O(M) site exists |
| 4 | The second history walk is pure duplication | `beginSearch` probe at 20k and 40k lines before and after | Time does not roughly halve, meaning the two scans were not equal in cost |
| 5 | Damage widening is a small residual | `widenedSearchDamageRows` sweep in isolation once 1-3 land | It is not small, in which case it becomes a slice of its own rather than a cleanup |

The end-to-end check is the real app, not the probe: `just launch-slot`, fill a
pane's scrollback, open the find bar and type a needle, then leave it up while
tailing a heavy log and confirm throughput. Drive the pane over `danterm` per
`integrations/danterm/SKILL.md`. The gate is `just test`.

## Non-goals

- No change to what matches. Every semantic in the parent plan -- literal,
  canonical-caseless, grapheme units, soft-wrap and hard-boundary handling --
  is held fixed, which is what PO-A exists to prove.
- No change to the overlay, the counter, or any rendering.
- No new benchmark workload in the `just benchmark-*` ladder.
- No debouncing in the app layer. Per-keystroke cost is addressed by making the
  scan cheap, not by deferring it.

## Accepted risks

- **AR-A.** The carried window is new mutable state on a path where a wrong
  value means wrong highlights, not a stale count. It is mitigated by making
  the invalidation rule a detector rather than an enumeration (J6): the fast
  path asserts its precondition and the fallback is a bounded rescan, and a
  needle change rebuilds from scratch so no error outlives the current needle.
- **AR-B.** `TerminalCore` today has no package dependencies. Adding
  `swift-collections` for `Deque` is the smallest correct fix for the head-drop
  memmove, the pin already exists in `lib/TerminalPTY/Package.swift`, and
  AGENTS.md prefers it to a hand-rolled ring. The alternative -- an array plus
  a dropped-head offset and periodic compaction -- keeps the zero-dependency
  property at the cost of hand-rolling the thing AGENTS.md says not to
  hand-roll.
- **AR-D.** Two needle-scaled terms survive on the feed path: the matcher's
  O(needle length) per-unit comparison, and the damage radius the parent plan's
  I9 requires. Neither re-projects a row, so neither is measurable by
  `ProjectionRowCounter`; experiments 2 and 5 measure them on the clock, and
  RJ3 and slice 6 are the named escalations if either dominates. Not fixed
  pre-emptively because a needle is user-typed and short, and because a matcher
  with a failure table is worse than a clear loop until measurement asks for it.
- **AR-E.** `projectedCellEnd` on a soft-wrapped row is width-dependent, so a
  forced-split record carrying a background-erase fill projects a
  width-dependent number of trailing spaces -- a live violation of the engine
  contract's E1, on the copy path as much as the search path. This plan
  preserves it rather than fixing it: it is pre-existing, it is not introduced
  or worsened here, and correcting it changes copied text and match results,
  which this plan's Non-goals hold fixed so the streaming rewrite has a stable
  oracle. It is the named precondition of the follow-up below.
- **AR-C.** Resize stays slow. `rebuildSearchIndex` runs on every width reflow
  and pays a full history walk; this plan halves it but does not remove it, so
  dragging a window with the find bar up remains proportional to scrollback
  depth. That is the follow-up below, and it is a deliberate ordering choice,
  not an oversight.

## Rejected ideas

- **RJ1. Caching the per-frame snapshot inside `Terminal`.** The three reads per
  frame cost ~0.5 ms today and roughly a fifth of that once the scan streams --
  below the noise floor. A cache is also the wrong shape: `Terminal` is an
  `Equatable` value published per frame, and `reportedTotalGrowsWithArrivingOutput`
  exists to fail the moment a stale answer is served. If the three reads are
  worth merging it is for the structural reason that they can disagree, as one
  `searchPresentation(in:)` read, and that is a separate change.
- **RJ2. Extension-aware rebuild when the new needle extends the old.** It is
  the only change that makes per-keystroke cost independent of scrollback
  depth, but a full scan should land near 30 ms once the scan streams, and this
  adds a second code path plus a `locate` per surviving match. Revisit if
  measurement says 30 ms is not enough.
- **RJ3. KMP in place of the ring-window comparison.** The inner loop is O(needle
  length) per unit, a second needle-length factor that P2 currently hides. It
  becomes visible only for long needles, and the sweep in experiment 2 will say
  whether it matters. Adopting it unmeasured trades a clear loop for a failure
  table nobody asked for.
- **RJ4. Reading rows through the store's content walk or
  `forEachFoldedCell`.** Cheaper, and it changes match results: search projects
  the painted row trimmed by `projectedCellEnd`, which includes a soft-wrapped
  row's trailing fill columns as spaces.

## The ideal, and why it is next rather than now

The structure in which the prefix-advance scan does not exist keys matches by
`(record sequence, unit offset, unit length)` rather than by display row. A
record's unit stream is its cells plus one `"\n"` iff it ends its logical line,
so the scan runs once per record at close, with no display-row folding in it at
all; eviction becomes dropping records off the front with no coordinate rewrite;
and **resize costs nothing**, which deletes `rebuildSearchIndex` and AR-C with
it. Every display-row awkwardness in this plan -- the boundary that can regress
three ways, the invalidation table, the eviction arithmetic -- exists because
`closedPrefixDisplayRowCount` is a lossy projection of the real immutability
seam, which is the closed record.

Its precondition is that a record's text projection be width-invariant, and
today it is not quite: `projectedCellEnd` on a soft-wrapped row is
`min(columnCount, cells.count)`, so a forced-split record carrying a
background-erase fill projects a width-dependent number of trailing spaces.
Fixing that means defining the record's projection directly instead of folding
and re-projecting -- which also fixes the same leak on the **copy** path, since
`text(in:)` goes through the same `forEachRowTextUnit`. That is a real
correctness wart, not only a perf obstacle.

It is next rather than now because the user made that call with this section in
front of them: local fixes now, record-keyed index next. The design bar puts the
choice between the ideal and the cheaper fix with the user, and this is that
choice, made explicitly rather than by omission. Supporting it: every piece this
plan builds -- the streaming primitive, the carried window, the single scan, the
eviction arithmetic -- is reused verbatim by the record-keyed index, so nothing
here is thrown away; and its headline is resize while the reported symptoms are
typing and tailing.

What the ordering does *not* do is make E1 acceptable. AR-E records the
violation as live and unfixed, and the follow-up's first move is defining the
record's projection directly -- for copy and search together -- rather than
folding and re-projecting.

## Commit progress

- [x] 1. Pin the scan's match set with an oracle independent of the scan
- [x] 2. Stream the row scan without materializing units or allocating per cell
- [x] 3. Advance the prefix from a carried boundary window instead of re-reading context
- [x] 4. Reduce eviction and truncation to arithmetic on the sorted match sequence
- [x] 5. Build the index from a single walk of history
- [x] 6. Measure the per-row damage widening; if it is not small, drop its
      per-call `Set` allocation and sort, keeping the I9 radius intact

## Implementation notes

- The TerminalCore purity gate now allowlists the plan's `DequeModule` dependency while retaining
  the pure-profile IO and nondeterminism bans.
- A same-session release probe of 500,000 single-row widening calls measured the old `Set` and
  sort path at 0.131/0.311/0.756 seconds for 1/6/24-unit needles. Contiguous range arithmetic
  stayed below 0.001 seconds in each arm, so slice 6 took the conditional cleanup.

## Follow Up

- Define a width-invariant record text projection shared by copy and search, then key search
  matches by record sequence and unit offsets so width reflow does not rebuild deep history in
  `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`.
