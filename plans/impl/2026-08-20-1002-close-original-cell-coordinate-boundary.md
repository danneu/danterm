# Close the original-cell coordinate boundary

Work is confined to `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift`,
`lib/TerminalCore/Sources/TerminalCore/TerminalSearch.swift`, and the store,
census, and search test files.

## Problem

`forEachContentIdentity` does not compile because it clips an
`OriginalCellOffset` run against a retained window expressed as `Int`. The
compiler caught this instance, but the store still carries the same original
record coordinate as a bare `Int` in the trimmed-head base, stable text
positions, closed-record scans, and search arithmetic. Those sites can mix an
original offset with a retained-relative index without a type error.

**Evidence the hole is live.** HEAD does not build:
`LogicalLineStore.swift:1913` compares `IdentityRun.start: OriginalCellOffset`
against the `Int` `headTrimmedCells`, so the typed half and the `Int` half of
one coordinate system collided inside a single function. Two further
representations keep that collision available:

- `headTrimmedCells` numerically counts removed cells, but its stored meaning
  is "the original offset of the head record's first retained cell". Every
  reader adds or subtracts it by hand, so an `Int` derived from it reads as
  retained-relative and original interchangeably.
- `ClosedRecordScan` publishes an original coordinate as a bare
  `cellOffsetBase: Int` (`LogicalLineStore.swift:1604-1606`, built with a
  hand-written trim ternary at `:1619`), and `TerminalSearch.swift` rebuilds
  stable coordinates from it by hand at three sites (`:564`, `:605`,
  `:633-639`). Search therefore depends on arithmetic the type system does not
  check.

The two coordinate spaces cannot be merged. A head trim changes retained
indexes, while stored side-table keys and search positions must keep their
original record offsets so surviving positions do not drift and eviction stays
independent of retained match count.

## Decision

Carry `OriginalCellOffset` across the complete original-coordinate path:
trimmed-head state, side-table keys and windows, stable record positions,
closed-record scans, and search indexing. Retained-relative indexes and all
extents remain `Int`.

Make stable record positions opaque outside the store. A closed-record scan
publishes a complete starting position and derives later positions from
retained-relative distances; it does not publish a record identity beside a
raw original-offset base. Typed original ranges support the identity walks
without unwrapping merely to iterate.

Retained-to-original and original-to-retained conversion each have one
store-owned path. Raw offset values appear only where the arena representation
is encoded, decoded, or byte-addressed.

This replaces the earlier boundary that typed side-table keys but deliberately
left stable record coordinates as `Int`. It changes no public API or terminal
behavior.

## Invariants

- **I1.** An original record offset cannot be passed as a retained-relative
  index, or the reverse, without an explicit store-owned conversion.
- **I2.** A surviving `RecordTextPosition` continues to name the same cell
  after any head trim. A position whose cell or record was evicted resolves to
  nothing and never retargets.
- **I3.** Open and closed hyperlink and content-identity tables use original
  offsets in run and per-cell forms. Every walk clips them to the retained
  window before reporting values.
- **I4.** Search derives indexed boundaries from complete stable positions. It
  does not reconstruct them from a record identity and a raw offset base.
- **I5.** `RecordTextPosition` remains two machine words, and head eviction and
  closed-history maintenance remain independent of retained match density.
- **I6.** Untrimmed reads, census values, search ordering, content ranks, and
  arena accounting do not change. Behavior in every existing configuration is
  unchanged, so no existing test is edited.

## Proof obligations

- **PO1 (I1, I3).** `TerminalCore` compiles, including identity walks over open
  runs, closed runs, and positional per-cell tables, with no raw-coordinate
  escape used to silence the reported error.
- **PO2 (I3, I6).** Head-trimmed census fixtures prove that removed hyperlinks
  and identities are excluded and surviving values are reported for an open
  record, a closed run table, and a closed per-cell table.
- **PO3 (I2, I4).** A partial head trim removes a match that began in the
  evicted prefix while a later match in the same record remains indexed and
  resolves to the same text.
- **PO4 (I2, I6).** These existing store and census tests stay green
  unmodified: `recordCoordinateSurvivesHeadTrim`,
  `headTrimPreservesHeadRecordIdentity`,
  `recordIdentityExhaustionRetiresHistory`, `contentRanksUseOnlyBlockMetadata`,
  `maintainedTotalsAndContentRanksAgreeWithRecountsAfterEveryMutation`,
  `contentRanksMatchSearchProjectionUnits`, `equalitySeesEverySideTableValue`,
  `sideTablesSurviveEveryRecordOperation`,
  `cellsAppendedAfterOpenHeadTrimKeepSideTableValues`,
  `closingTrimmedOpenHeadKeepsSideTableRunsReadable`,
  `perCellIdentitiesSurviveClosingAndReopeningTrimmedOpenHead`,
  `trimmedPerCellTableIsReservedBeforeRegionSeamClosesIt`, and
  `headTrimmedIdentityRuns`.
- **PO5 (I4, I6).** These existing search tests stay green unmodified:
  `headTrimRetiresMatchStartingInEvictedCells`,
  `retainedIndexMatchesOracleAcrossStoreMutations`,
  `tailRecordReuseRetiresIndexedCoordinates`,
  `retainedIndexKeysWideAndSpilledCellsLikeAFullScan`, and
  `needleEntryBuildStreamsClosedRecordCells`. If none of them holds a match
  lying wholly inside the retained suffix of a head-trimmed closed record and
  checks it against the oracle after the trim, add one such scenario.
- **PO6 (I5).** `recordCoordinateStaysTwoWords` and the bounded search
  maintenance proofs remain green.
- **PO7.** The full `TerminalCore` package tests and `just test` pass.

## Non-goals and rejected ideas

- **Non-goal.** Do not rebase arena tables or stored positions during a head
  trim. That would make stable coordinates drift and add work proportional to
  retained metadata.
- **Non-goal.** Do not change public interfaces, persistence, terminal control
  behavior, census semantics, or the arena format.
- **Rejected.** Unwrapping `IdentityRun.start` to `Int` fixes the immediate
  compiler error but preserves the unsafe representation that caused it.
- **Rejected.** Keeping `RecordTextPosition` and closed-record scan bases as
  raw `Int` stops the newtype at the boundary where search depends on it.
- **Accepted as a subset, not a substitute.** Typing `forEachContentIdentity`
  through the existing retained-to-original conversion restores the build and
  is a legitimate first commit if the release must move before this plan
  lands. It is a strict subset of this plan: every other hand-written
  conversion site stays free to mix bases, and search keeps rebuilding
  coordinates from an `Int`.

## Implementation discretion

- Exact helper and operator names, provided the coordinate conversions and raw
  arena access remain confined to the store boundary.
- Test fixture construction and placement within the existing logical-store,
  census, and search suites.
