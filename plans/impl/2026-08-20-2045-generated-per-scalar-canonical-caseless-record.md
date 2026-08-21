# UNI-4: one generated per-scalar record for the canonical caseless key path

Source finding: UNI-4 in docs/scratch/2026-08-18-construction-audit.md
(verified 2026-08-20 against the tree; `CanonicalCaseless.swift` is unchanged
since `edd3eeb0`, UNI-1 and UNI-2 have landed, nothing in flight touches the
caseless tables or the generator's caseless section).

## Problem

Search keys every non-ASCII grapheme through `canonicalCaselessKey` in
`lib/TerminalCore/Sources/TerminalCore/CanonicalCaseless.swift`, which is
`canonicalDecomposition -> flatMap(fullCaseFold) -> canonicalDecomposition`.
For a scalar with no canonical decomposition and no case fold -- every CJK
ideograph, box-drawing character, braille pattern, and most of everything
else -- that is three hand-written binary searches over
`GeneratedCanonicalCaselessTables.decompositionScalars` (2,081 entries) and
`foldScalars` (1,585 entries) that all return "absent", plus a one-element
heap array from `fullCaseFold`, plus the intermediate arrays of the two
passes. A multi-scalar cluster pays a fourth search per scalar
(`canonicalCombiningClass` over 403 ranges) to order it. The scan reaches it
from `TerminalSearch.swift#searchGraphemeKey(for: TerminalScalars)`, which
also copies the cell's scalars into an `Array` first. This runs once per
scanned cell on the closed-history index build, on every non-append needle
edit, and on the live-projection scan.

Two facts the finding did not state:

- Its proposed shape -- two "affected" bits and "no scalar affected, return
  the input unchanged" -- is wrong for clusters. U+0301 has neither a
  decomposition nor a fold but has combining class 230, so
  `[a, U+0301, U+0323]` must still reorder to `[a, U+0323, U+0301]`. Any
  early return needs the combining class, which is the fourth search.
- Hanging the bits on the feed path's classification palette
  (`UnicodeProperties.generated.swift`, 29 entries, shift 7, two `UInt8`
  stages, 32,128 bytes) would fragment its block dedup: mapped scalars are
  scattered across Latin, Greek, Cyrillic, Semitic, Indic, Hangul, CJK
  compatibility, and math blocks, so many shared stage-two blocks split, the
  feed table grows, and `terminal-feed` has to be re-confirmed for a
  property the feed path never reads.

## Decision

Generate one per-scalar record for the search key path and make every
scalar-level question on that path a table read. The record answers, for
any scalar: its canonical combining class, its canonical decomposition or
that it has none, and its full case fold or that it has none. Hangul
syllables stay algorithmic. With that record, no binary search remains on
the key path: `exactIndex` and `canonicalCombiningClass` cease to exist
rather than being bypassed for some scalars, and the three current
"absent" verdicts become one lookup.

The record is a second two-stage table emitted into
`CanonicalCaseless.generated.swift`, beside the existing decomposition and
fold pools, built by the same packer the classification palette uses
(`scripts/generate-terminal-unicode-tables.py#packed_classification_tables`,
which is generic over hashable records, and `#index_element_type`). It does
not touch the feed path's palette: affectedness is a search-only property,
and the two paths share no caller.

Key construction stops allocating for the common case: `canonicalCaselessKey`
takes the cell's scalars without an `Array` copy, `fullCaseFold` returns
`TerminalScalars` (inline for the identity and one-to-one cases), and a
single inert scalar -- no decomposition, no fold, combining class zero --
yields its search key without building any array. Multi-scalar keys still
materialize as `SearchGraphemeKey.scalars([Unicode.Scalar])`; see N1.

Files: `scripts/generate-terminal-unicode-tables.py`
(`canonical_caseless_source`, the write step in `main`),
`lib/TerminalCore/Sources/TerminalCore/CanonicalCaseless.generated.swift`
(regenerated, never hand-edited), a new test-side generated reference for
combining classes under `lib/TerminalCore/Tests/TerminalCoreTests/`
(pattern: `UnicodeReference.generated.swift`),
`lib/TerminalCore/Sources/TerminalCore/CanonicalCaseless.swift`,
`lib/TerminalCore/Sources/TerminalCore/TerminalSearch.swift` (the two
`searchGraphemeKey` overloads near line 906; the call sites at 615 and 769
already hand over `TerminalScalars`), and the tests named under proofs.
`UnicodeProperties.generated.swift` does not change.

## Invariants

- I1: Every canonical caseless key is unchanged: canonical decomposition,
  full case folding, canonical ordering, and the D145 pipeline produce the
  same scalars as today for every input, including Hangul and clusters
  whose only non-trivial property is combining class.
- I2: The record's combining class equals the pinned Unicode 17.0 value for
  every scalar in the codespace, and scalars outside the pinned data are
  starters.
- I3: The feed path's classification table is byte-identical before and
  after; no search-only property rides the feed palette.
- I4: Of the artifacts one generator run writes, only
  `CanonicalCaseless.generated.swift` and the new test-side reference
  change; every other artifact comes back byte-identical, proving the input
  data did not drift.
- I5: Emitted arrays stay flat, explicitly typed literals, and the packer
  fails loudly if an index outgrows its element type (both inherited from
  the classification packer).

## Proof obligations

- PO1 (I1): `CanonicalCaselessTests.officialNormalizationCorpusMatches`
  (20,034 lines; Part 1 enumerates every decomposing scalar, so a record
  that wrongly calls one inert fails here),
  `officialCaseFoldingCorpusMatches` (every C and F mapping), and
  `canonicalCaselessKeyOrder`. Add key-level tests that pass before and
  after and name the cases the finding's shape would have broken: an inert
  combining mark still orders (`[a, U+0301, U+0323]` keys to
  `[a, U+0323, U+0301]`); a CJK ideograph, a box-drawing character, and a
  braille pattern key to themselves; U+00E0 (decomposes, no fold) and
  U+0410 (folds, no decomposition) key correctly so the two properties are
  not conflated. All assert returned keys, not table shape.
- PO2 (I2): one sweep over the whole codespace comparing the production
  record's combining class against the independently emitted test-side
  reference, the same pattern `UnicodeWidthTests` uses against
  `UnicodeReference.generated.swift`.
- PO3 (I1, end to end): `TerminalSearchTests.foldingAndUnicodeExactness`
  asserts the cell ranges search reports for precomposed and decomposed
  forms and for both cases, against literal expectations; that is the
  end-to-end proof that a canonical or caseless key divergence changes what
  search returns. `independentSearchMatchRanges` calls `canonicalCaselessKey`
  on both sides, so it proves projection, grapheme segmentation, and match
  integration, not key correctness.
- PO4 (I3, I4): before regenerating, copy every file the generator writes;
  after regenerating, compare each copy byte for byte against the new file.
  The manifest today is `UnicodeProperties.generated.swift`,
  `UnicodeReference.generated.swift`, `GraphemeReference.generated.swift`,
  `GraphemeBreakCorpus.generated.swift`, `CanonicalCaseless.generated.swift`,
  and the normalization and case-folding corpora; this change adds the
  combining-class reference. Only `CanonicalCaseless.generated.swift` and the
  new reference may differ; every other artifact must come back identical.
  The comparison is over the written files themselves, not `git diff`, which
  would skip the new file until it is staged and would not name the runtime
  and test sources this change also edits.
- PO5 (size, honest report): `size -m` on the release TerminalCore object
  before and after, reported once in the commit message. No instrument on
  the ladder sees this path and `terminal-feed` never calls it, so no
  benchmark verdict gates the change; the claim is the absence of the
  searches and the allocations, by construction, and the commit says so
  rather than naming a workload that would report `equivalent`.

## Non-goals

- N1: `SearchGraphemeKey.scalars([Unicode.Scalar])` and `NeedleWindow.Unit`
  keep their array payload; removing that allocation ripples into the
  matcher and the test oracle and is a follow-on.
- N2: A justfile recipe or gate step that regenerates or diff-checks the
  generated files.
- N3: Any change to how often search rebuilds its index (`0a46037b`
  already limits full rebuilds to non-append edits).

## Accepted risks

- AR1: The record table may be larger than the ~26 KB of sorted arrays it
  replaces (estimate from the committed data: tens of KB, a few dozen
  distinct 128-entry blocks plus a record list on the order of the ~3,000
  mapped scalars). It is search-only and off the feed path; PO5 reports
  the real number.
- AR2: A one-to-two or one-to-three case fold still allocates:
  `TerminalScalars` is inline only for zero and one scalars.
- AR3: Regeneration needs the nine pinned UCD files, via network or
  `--data-dir`; none are under `references/`, and only two are committed as
  fixtures.

## Rejected ideas

- RI1: Two affectedness bits on the feed palette (the finding's first
  shape) -- fragments the feed table's dedup and forces a feed re-confirm
  for a property the feed never reads.
- RI2: Two affectedness bits in a standalone table, leaving combining
  class and the mapped scalars on binary search (the finding's sharper
  shape) -- unsound as an early return for clusters without the combining
  class, and keeps `exactIndex` plus two sorted key arrays as a second
  description of the same sets.
- RI3: A minimum-mapped-scalar threshold as a cheap early return -- CJK,
  box drawing, and braille all sit above both thresholds, so it misses the
  motivating case entirely.
- RI4: An `Instrument` counting table probes as the first failing test --
  with no search left on the path there is nothing to count; PO1's new
  key-level cases and PO2 are the behavioral net.

## Implementation discretion

- D1: Record encoding -- palette of records versus parallel arrays indexed
  by a palette index, whether decompositions are emitted fully resolved or
  resolved recursively through the record, and how "no mapping" is
  represented -- bounded only by I5.
- D2: The borrowed-scalar parameter form for `canonicalCaselessKey` and
  `canonicalDecomposition` (a generic collection or `TerminalScalars`);
  both call sites are internal to TerminalCore.

## Verification

1. Copy the generator's output manifest aside, regenerate with
   `python3 scripts/generate-terminal-unicode-tables.py [--data-dir <dir>]`,
   then compare each artifact byte for byte against its copy (PO4).
2. `swift test --package-path lib/TerminalCore --filter CanonicalCaselessTests`
   and `--filter TerminalSearchTests` (PO1-PO3), run once each into a file
   under `.build/` and grepped.
3. `just test` for the gate.
4. `size -m` on the release TerminalCore object before and after (PO5).

## Merge notes

`plans/wip/plan-the-ideal-refactor-ancient-gray.md` (STORE-4b) edits the
scan loops in `TerminalSearch.swift` around lines 595-630 and 755-780; this
plan edits the key overloads near 906-931 and leaves the call lines alone.
Overlap is low but both touch the same file.

## Implementation notes

- D1 resolved: canonical decompositions are emitted fully resolved, so the
  runtime walks a flat pool slice and no longer recurses through the table per
  component. Identical mappings are interned, so the many scalars that fold or
  decompose to the same run share one pool slice. "No mapping" is a zero length,
  which is what makes the absence of a decomposition and the absence of a fold
  one lookup apart. The palette is five parallel arrays rather than an array of
  structs, for the same swift-frontend reason the file header already gives.
  The shared packer chose shift 6, with a `UInt8` first stage and a `UInt16`
  second stage.
- D2 resolved: `canonicalCaselessKey` and `canonicalDecomposition` take
  `some Collection<Unicode.Scalar>`. With that, the two `searchGraphemeKey`
  overloads collapse into one generic function, so scanning a painted cell no
  longer copies its `TerminalScalars` into an array at all -- not even for a
  multi-scalar cluster, which the plan expected to keep paying for the copy.
- `canonicallyOrder` no longer builds a parallel `classes` array. A combining
  class is now one table read, so the insertion sort reads it from the scalar in
  place and there is no second array to keep in step.
- Hangul is a trap the record shape creates: a syllable decomposes
  arithmetically and therefore carries no table mapping, so its record reports
  "maps to itself" and the search shortcut would wrongly key a syllable to
  itself. `isCanonicalCaselessIdentity` excludes the syllable range explicitly.
  Removing that guard fails only the new Hangul search test, so nothing else in
  the suite covered it.
- PO5, release TerminalCore objects: `__DATA,__const` 101,303 -> 142,947 bytes
  (+41,644), `__TEXT,__text` 559,128 -> 562,220 bytes (+3,092). That lands where
  AR1 predicted, tens of KB, for a table that is search-only and off the feed
  path.

## Follow Up

- N1 is now the only allocation left on the key path: `SearchGraphemeKey.scalars`
  and `NeedleWindow.Unit` still carry `[Unicode.Scalar]`, so a multi-scalar
  cluster allocates once per scanned cell. Removing that payload ripples into
  the matcher in `lib/TerminalCore/Sources/TerminalCore/TerminalSearch.swift` and
  into the test oracle `independentSearchMatchRanges` in
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalSearchTests.swift`.
- Nothing in `just test` regenerates the Unicode tables or diff-checks them, so a
  hand-edit to any `*.generated.swift` under `lib/TerminalCore` passes the gate.
  A step in `scripts/run-test-suite.sh` would need the nine pinned UCD files,
  which are not in the tree; only `NormalizationTest-17.0.0.txt` and
  `CaseFolding-17.0.0.txt` are committed as fixtures.
