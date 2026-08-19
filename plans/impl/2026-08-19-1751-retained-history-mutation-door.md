# Retained history behind a synchronization-carrying mutation door (INTERACT-1)

## Context

`Terminal` holds its retained history (`LogicalLineStore`) as a bare private
stored property, and the retained search index (`Terminal.Search`) stores match
endpoints as record coordinates that stop resolving when history changes which
records it owns. Keeping the index valid is a pushed obligation: seven
hand-placed `synchronizeSearchIndexPrefix()` calls across unrelated code paths
(budget eviction, ED 3, two resize tail-pulls, wrap-claim sever and restore, a
test helper), and nothing makes a new history mutation call it. A missed call
is a process trap: `resolvedSearchMatchRange` in
`lib/TerminalCore/Sources/TerminalCore/TerminalSearch.swift` ends in
`preconditionFailure("the search index retained a retired record coordinate")`.

The trap is latent today: every mutation that changes record ownership is
followed by a covering sync before any search read (verified site by site --
`setWidth` and the admit loop are covered only because a budget pass happens to
follow them). So this is a pure structural refactor: make the omission
inexpressible instead of merely absent.

Source: INTERACT-1 in `docs/scratch/2026-08-18-construction-audit.md`,
including its Correction: Swift `private` does not bind within the ~7,800-line
Terminal.swift, so a funnel method declared there is a tidier version of the
same pushed obligation. The funnel must live behind a type in a different file.

Sequencing (the audit's X1 resolution): this lands before FIND-1 (incremental
index narrowing -- changes what the refresh does) and PARSE-6 (moves search
into an inspection value -- changes where the state lives). The funnel must be
shaped so each of those edits one place, not the mutation sites.

## Decision

Move the store behind a wrapper struct in a new file in the same target
(`lib/TerminalCore/Sources/TerminalCore/`), replacing
`private var history: LogicalLineStore` on `Terminal`:

- Reads stay direct: the wrapper exposes the store read-only (`private(set)`
  storage), so the ~51 read sites in Terminal.swift are a mechanical rename
  and pay no copy or accessor cost.
- Mutation is possible only through doors declared in the wrapper's own file,
  and **every door requires the search slot (`inout Search?`) as a parameter
  and brings the index back into agreement with the store after the mutation
  body releases it**. Two doors, and they owe different work: a scoped
  mutation (closure over the store `inout`) synchronizes incrementally, and a
  whole-store replacement (for the `rebased(toBudgetBytes:)` test seam)
  *rebuilds* the retained index from the replacement store. The bare
  initializer is used only where no search can exist yet (`Terminal.init`).
- Terminal routes its mutation sites through one private helper that supplies
  the slot and keeps the no-search path free of `search`'s load-bearing
  `didSet`; `synchronizeSearchIndexPrefix()` dissolves into it and is deleted.
  PARSE-6 later retypes the slot parameter and edits that helper; FIND-1 later
  changes what `synchronizeIndex` does internally. Neither touches a mutation
  site.
- Why the wrapper does not own `Search` too: the search design deliberately
  keeps `Search` store-free (research/31/F13 -- a second live store reference
  makes the arena non-uniquely referenced on every read), and PARSE-6 gives
  search a different owner.

Decisive constraints:

- The mutation body runs with direct `inout` access to the stored store -- no
  intermediate copy anywhere on the path (research/31/F13: a live second
  reference at mutation time copies every touched chunk).
- One synchronization per logical mutation, not per store call: the scrollback
  admit loop is one door body per batch; the wrap-claim sever's two store
  calls are one body.
- The synchronization runs after the store access ends, against a short-lived
  read-only copy (the same overlap-breaking idiom
  `synchronizeSearchIndexPrefix` uses today).
- At the three sites that also observe evictions, order becomes mutate ->
  search sync -> `syncHistoryEvictions()` (today the last two are reversed).
  Verified disjoint: `handleEviction` never touches search;
  `synchronizeIndex` reads only the store and its own index.
- `setWidth` and the tail spacer repair, previously covered only incidentally,
  go through the door like everything else (their syncs early-return, which is
  the cheap no-op the design counts on).
- The replacement door rebuilds rather than synchronizes, because a
  replacement store carries a fresh identity regime.
  `rebased(toBudgetBytes:)` builds a new `LogicalLineStore` whose record
  identities restart at 1, and `synchronizeIndex` reads a lower trailing
  identity as an ordinary tail regression: it would then compare retained
  match coordinates minted under the old regime against positions in the new
  one, keeping matches that now name different content and dropping valid
  ones. The rebuild discards the index and re-derives it from the replacement
  store (the same construction `Search.init` performs), so no coordinate
  crosses a regime boundary.

## Invariants

- I1: A history mutation that changes record ownership cannot complete without
  the retained search index being brought back into agreement with the store
  -- incrementally for a scoped mutation, by rebuild for a whole-store
  replacement. The door's signature binds the two, and there is no other route
  to a store mutation.
- I2: Behavior across every history-mutating path is unchanged, including
  retire-never-retarget for match endpoints
  (`docs/design/2026-08-06-swift-terminal-engine.md#G9`).
- I3: The search maintenance cost model is unchanged: no per-row
  synchronization on the admit path; a no-op synchronization stays O(1) and
  records nothing on `Instrument.searchIndexMaintenance`; the no-search path
  stays one nil test and does not fire `search`'s `didSet`.
- I4: The store's copy-on-write behavior is unchanged: mutation happens in
  place on the uniquely referenced store; no door holds a live copy across a
  write.

## Proof obligations

- PO1 (I1, I2): `retainedIndexMatchesOracleAcrossStoreMutations` in
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalSearchTests.swift` stays
  green, unweakened -- it drives feed, both resize directions, wrap-claim
  sever and restore, ED 3, budget eviction, and a forced split against an
  independent oracle.
- PO2 (I2): the existing net stays green: TerminalSearchTests,
  TerminalScrollbackBudgetTests, TerminalResizeTests,
  TerminalStaleWrapClaimTests, TerminalPromptAnchorResizeSweepTests,
  TerminalLogicalLineStoreTests; then the full package and `just test`. No
  test asserts sync-call placement, so nothing pins the deleted structure.
- PO3 (I3): the four instrument-bounded search tests stay green at their
  existing bounds (width no-op `== 0`; seam movement `> 0`; logarithmic
  maintenance `<= 32`; head eviction `dense == empty` and `<= 2`). If the
  eviction bound trips because one batch's sync split in two, the fix is
  structural -- merge the admit and evict mutations into one door body --
  never a weakened bound.
- PO4 (I3, I4): paired benchmark against the recorded pre-change revision:
  `just benchmark-quick baseline=<rev> workload=terminal-feed`, expecting
  `equivalent` (distrust deltas under the workload's stated noise floor). On a
  regression verdict, sample the feed path (`just benchmark-feed-sample`) for
  arena-copy frames under `admit` before suspecting anything else.
- PO5 (I1, I2): a new oracle test for the replacement door -- feed a terminal
  past its budget so the store has already evicted records, start a search
  that matches in retained history, then replace the store through the door.
  The resulting `searchStatus` and the resolved match ranges agree with the
  independent oracle, and no read traps. This is the case incremental
  synchronization cannot serve, so it fails against a replacement door that
  synchronizes instead of rebuilding.

## Non-goals

- Eviction observation (`historyEvictionsObserved` / `syncHistoryEvictions`)
  stays on Terminal outside the door: it reads a monotone counter, so a missed
  call delays observation rather than trapping, and its reaction mutates
  selection and viewport state a store wrapper cannot own.
- No change to what `synchronizeIndex` does (FIND-1) or where search state
  lives (PARSE-6).
- No test asserting the funnel's existence or call placement
  (structure-sensitive, forbidden by house test rules).

## Accepted risks

- AR1: A mutation site could deliberately mint an inactive slot to bypass
  synchronization. Accepted: the by-construction claim targets forgetting, not
  sabotage; the one legitimate minted slot (the helper's no-search fast path)
  carries a comment saying so.

## Rejected ideas

- RI1: A monotone ownership counter plus an assertion at read time (the
  audit's cheaper fallback) -- detects the omission instead of preventing it.
- RI2: The wrapper owning `Search` as well -- reintroduces the store-adjacent
  live reference research/31/F13 measured, and fights PARSE-6's ownership.
- RI3: Passing `&search` directly at every mutation site instead of through
  the helper -- fires the load-bearing `didSet` even when no search exists
  (new work on the hottest path) and multiplies PARSE-6's edit points.

## Implementation discretion

- Wrapper, door, and helper names; the helper's slot-handling shape (take/swap
  versus copy); whether replacement is a door or a rebuilding initializer
  -- free within I1's signature binding.
- Grouping of multi-statement door bodies, within I3's one-synchronization-
  per-logical-mutation constraint.

## Verification

1. Full package green at baseline
   (`swift test --package-path lib/TerminalCore`); record the pre-change
   revision for PO4.
2. Write PO5's replacement-door oracle test.
3. Land the wrapper, the retype, and the funnel as one compile-driven step:
   after the property is retyped, the compiler enumerates every `history.`
   use -- reads take the read path, the eleven mutation sites take a door. No
   behavioral edits ride along.
4. Targeted suites first
   (`swift test --package-path lib/TerminalCore --filter TerminalSearchTests`,
   run once into a file), then the PO2 suites, then the full package and
   `just test`.
5. PO4's paired benchmark.

Critical files: `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`, a new
wrapper file beside it, `TerminalSearch.swift` (logic unchanged; the sync it
hosts becomes the door's exit call),
`lib/TerminalCore/Tests/TerminalCoreTests/TerminalSearchTests.swift`.

## Implementation notes

- The slot is moved into a local rather than passed as `&search`. `search` is an
  observed property, so an `inout` on it is a formal access to the whole
  terminal and the compiler rejects it as overlapping the door's access to
  `history`. `withHistoryDoor` swaps the slot out and back, which is also what
  keeps the no-search fast path free of the `didSet`. The search-present path
  now fires that `didSet` twice (swap out, write back) instead of once; both
  fires are on the path that already pays a full index synchronization, and the
  first short-circuits on the link slots only.
- Two thin routers over one slot supplier: `mutateHistory` for the scoped door
  and `replaceHistory` for the replacement door, both built on
  `withHistoryDoor`. PARSE-6 retypes the slot in `withHistoryDoor` alone.
- The admit loop got its own door body, so `feed` now synchronizes twice per
  scrolled batch (once after admission, once after `evictToBudget`) where it
  synchronized once. PO3's four instrument bounds all held unchanged, so the
  admit and evict mutations were left as separate logical mutations rather than
  merged.
- `RetainedHistory` conforms to `Equatable` and `Sendable` because `Terminal`
  does and synthesis needs it; the synthesized `==` forwards to the store's,
  which is what `Terminal` compared before.

## Follow Up

- PO4's paired benchmark is unrun: the machine was loaded (load ~15 across 10
  processors, external `swift-frontend` at 96-100%) through both attempts, which
  returned contradictory verdicts (`slower +18.69%`, then `equivalent +0.48%`)
  on 2 pairs each. Re-run `just benchmark-quick baseline=f90eb86a
  workload=terminal-feed` on an idle machine, and on a regression verdict sample
  the feed path with `just benchmark-feed-sample` for arena-copy frames under
  `admit`.
