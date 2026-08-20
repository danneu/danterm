# Narrow the closed-history search index on needle append

Source finding: construction audit FIND-1 (docs/scratch/2026-08-18-construction-audit.md),
pivoted: the narrowing happens inside `beginSearch`, not behind a new app-facing API.

## Context

Every keystroke in the find field reaches `Terminal.beginSearch(query)`, which
builds a brand-new `Search` whose init scans the entire retained closed history
from record 0 (`builtSearchMatchIndex` -> `scanClosedRecordSearchUnits` over
`0..<closedRecordCount`). The scan runs on the PTY host's serial queue -- the
queue that also applies output -- so at the 16 MiB retained budget, typing a
five-character needle stalls the pane on five full history scans. The
information is already in hand: every match of "error" starts at a match of
"erro", and the previous keystroke's index holds exactly those starts.

Load-bearing premises, verified in code:

- All history mutations pass through `RetainedHistory.mutate`/`.replace`
  (RetainedHistory.swift), which synchronize the search index, so at
  `beginSearch` time a live search's index agrees with the current store
  (`retainedStart` = record 0 start, `indexedThroughRecord` = last closed
  record's identity).
- The index (`prefixMatches`) covers only closed records; the mutable suffix is
  rescanned on every read and is out of scope here.
- Grapheme-key arrays, not query strings, define the prefix relation: appending
  a combining mark rewrites the final key, so a string-prefix check would be
  wrong. Note (corrects the finding): one typed grapheme always produces one
  key in this codebase -- ss-style expansions fold inside a single `.scalars`
  key -- so multi-key appends arrive only via paste, and the refine must accept
  any append length.
- No existing test or probe case types a needle incrementally; the existing
  probe case "search: first press on a new needle" uses a distinct needle per
  iteration on purpose and cannot observe this change.

## Decision

When `beginSearch` runs while a search is live and the new query's grapheme
keys strictly extend the stored needle's keys, derive the new index from the
existing one instead of rescanning the whole history. Anything else -- no live
search, backspace, paste that is not an extension, an edit that re-segments the
final grapheme -- takes today's full build unchanged.

Decisive constraints:

- The refine reuses the one existing closed-record scanner
  (`scanClosedRecordSearchUnits`) over just the record ranges the old matches
  touch (each range widened by the appended key count, overlapping or abutting
  ranges merged). There is exactly one code path that turns cells and record
  boundaries into search units; the refine must not grow a second one.
- The trailing boundary window for the longer needle is rebuilt with the
  existing `recordSearchBoundaryWindow`, which `synchronizeIndex` already
  relies on for exactly this equivalence.
- `Search.init` stays a pure from-scratch build. `RetainedHistory.replace`
  uses it as a whole-identity-regime reset; the refine is a separate entry
  reached only from `beginSearch`.
- `Search` stays store-free (no retained `LogicalLineStore` reference); the
  refine borrows the store for the call, as `synchronizeIndex` does
  (research/31/F13 is the measured copy this prevents).
- No density fallback guard: the merged ranges of a dense needle degrade to
  the full build's own scan range, so the refine is never asymptotically worse
  than the build it replaces. (The finding proposed a guard; the range-merge
  shape makes it unnecessary.)
- `beginSearch`'s observable behavior is unchanged: same newest-match
  selection, reveal, damage, and return value on both paths.

## Invariants

- I1 -- Equivalence: after any `beginSearch` sequence, the resulting search
  state (the search value itself, its indexed record ranges, `searchStatus`,
  and match ranges) equals a single `beginSearch` of the final needle on an
  identical terminal. The refined index is value-identical to a fresh build,
  not merely equivalent.
- I2 -- Cost: a needle-append keystroke visits only the closed records covered
  by the merged neighborhoods of the old matches (each old match's records
  widened by the appended key count, overlapping or abutting ranges merged).
  History that holds no old match adds no work. A dense needle whose old
  matches spread across the whole retained history may therefore still visit
  all of it -- that is the bound, not a violation of it. A non-append keystroke
  still visits the whole closed history, and that must remain observable (no
  dead instrument).
- I3 -- Isolation: `RetainedHistory`'s doors, `Search.init`'s from-scratch
  semantics, and the mutable-suffix read path are unchanged; existing
  instrument-bounded tests keep their bounds without edits.

## Proof obligations

- PO1 (I1): an incremental-typing test comparing the typed terminal against a
  fresh-search terminal at every step, also checked against the independent
  oracle (`assertSearchIndexMatchesOracle`). The corpus must cover: a match
  crossing a closed-record boundary with a newline in the needle; wide cells;
  a combining mark whose addition re-segments the final grapheme (fallback
  path); an overlapping self-similar needle ("a", "aa", "aaa" over "aaaa");
  an append whose resulting match begins in the final closed record and ends in
  the mutable suffix, so the rebuilt boundary window is checked at the seam;
  a multi-key append in one step (paste); the first character with no prior
  search; a needle matching every line (merged ranges collapse to the full
  scan); an ss-like single-grapheme fold.
- PO2 (I2): closed records visited becomes an observable count -- a new
  `Instrument` case recorded where the closed-record scan runs. A two-depth
  test (in the style of `widthChangeSearchCostIsIndependentOfHistoryDepth`)
  holds the match layout fixed and adds only non-matching history at the deeper
  depth, then asserts the append keystroke's count is equal at both depths --
  proving that history holding no old match adds no work. A companion asserts a
  full-build keystroke's count grows with depth, so the instrument is proven
  live. The test does not claim depth-independence for a dense needle; PO1's
  match-every-line case covers that shape, where the merged ranges legitimately
  collapse to the full scan.
- PO3 (I3): the existing suite passes with no bound edits, in particular the
  three `searchIndexMaintenance`-bounded tests and the oracle tests.
- PO4 (measurement): a new occupancy probe case that types one corpus-real
  needle key by key and reports the summed per-iteration milliseconds
  (`OccupancyCase` plus a measured block in `runOccupancyProbe`). The number
  that must move, hand-compared across revisions per measurement discipline:
  that sum, from ~N full scans toward ~one. The existing new-needle case must
  not move.

## Non-goals

- Debouncing the needle anywhere on the path (hides the cost, does not remove
  it).
- The per-frame triple scan of the mutable suffix (audit FIND-2) and the
  matcher's ring representation (FIND-3) -- separate findings.
- Refining on needle shrink (backspace): the shorter needle's matches are a
  superset of the stored ones and cannot be derived from them.

## Accepted risks

- AR1: a refine that silently misses a match would show as wrong search
  results, not a crash. Guard: PO1's per-step oracle comparison plus the
  value-identity contract in I1, which fails on any divergence, including in
  the boundary window that seeds later suffix scans.

## Implementation discretion

- Range-merge bookkeeping (how record identities are mapped to indices and
  cached during the merge) and the defensive rebuild when an identity fails to
  resolve.
- Names: the refine entry point on `Search`, the instrument case, the probe
  case, and test titles.

## Commit progress

- [x] 1. Refine closed-history search indexes on needle append
- [ ] 2. Measure incremental needle entry in the occupancy probe
