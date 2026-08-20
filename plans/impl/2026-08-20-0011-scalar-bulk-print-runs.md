# Derive the bulk-print run predicate from the scalar record (UNI-2, pivoted)

## Context

Audit finding UNI-2 (docs/scratch/2026-08-18-construction-audit.md): the run
granularity that makes plain text cheap is keyed on a byte property --
`byte >= 0x20 && byte <= 0x7E` in `TerminalInputStream.isPrintableASCII` --
rather than on the grid property it stands for. The generated table classifies
921,871 scalars (all box drawing, block elements, braille, Cyrillic, Greek,
Latin-1 letters) with the exact record of ASCII 'A': narrow, grapheme-break
`.other`, no emoji flags. Each of those still arrives as one `.print(scalar)`
action and pays the full per-cell path -- classification, cluster-join
attempt, inspection invalidation, style read, one-cell write, REP bookkeeping,
and one damage snapshot per action. A full-screen btop or ncurses frame is
nearly all such scalars, so it runs on the slow path ASCII was explicitly
lifted out of.

The audit's proposed mechanics are stale: since it was written, the GL
character-set work landed (`e0d2e80c`, `d61c196e`) and `.printASCIIRun` now
means "one GL print per byte" -- each byte charset-translated at write time --
while `.print` carries an already-decoded scalar no character set touches
(contract pinned in the action's doc comment). A decoded-scalar run therefore
cannot ride the existing run action; it needs a sibling. UNI-1 landed as
`bd0e1c0b`, so the 29-entry typed palette exists and the predicate is
derivable in Swift from the record's own fields -- no generator run and no
unicode.org network dependency.

Desired outcome: text made of bulk-safe scalars feeds at run granularity
regardless of script, and "which characters can be stamped in bulk" has one
statement (the scalar record) instead of three (a byte range, a prose
invariant, a range-scanning test).

## Decision

- D1. Add a second run action -- working name `.printScalarRun`, a byte range
  into the fed chunk like `.printASCIIRun` -- meaning one `.print` per decoded
  scalar in the range: never charset-translated, never a unit the per-scalar
  path could not produce. `.printASCIIRun` keeps its GL semantics unchanged.
- D2. The predicate is a property computed from
  `TerminalUnicodeClassification`'s own fields -- narrow width, grapheme-break
  `.other`, none of the three emoji flags -- in a hand-written companion to
  the generated file (precedent: `CanonicalCaseless.swift` beside
  `CanonicalCaseless.generated.swift`). The generated file is not touched.
- D3. The parser recognizes the run in ground/idle state by decoding ahead
  directly from the chunk with a probe copy of the decoder (a POD value;
  `self`'s decoder stays untouched and idle, preserving the
  Equatable-between-feeds contract and `synchronizationPrefix`). A clean
  first scalar that fails the predicate returns as a single `.print` from the
  same decode.
- D4. Bytes below 0x80 never enter a scalar run: they stop the probe and are
  recognized by the existing GL-run arm. Without this rule a locking shift
  would print an untranslated ASCII byte (DEC graphics `l` must become
  `U+250C`, not stay `l`). Mixed streams alternate the two run actions.
- D5. A run range contains only complete, valid UTF-8 sequences: the probe
  commits a scalar only when every decode step consumed its byte and the
  bytes consumed equal the scalar's UTF-8 length. This excludes every
  replacement-scalar error path (whose maximal-subpart re-offer must replay
  through the incremental decoder identically) while keeping genuinely
  encoded U+FFFD eligible.
- D6. The reducer arm is a sibling of `printASCIIRun` with the same
  take-a-prefix-or-decline loop, built on one shared body for the decline
  guards, cuts, and write tail (identity straddle, inspection invalidation,
  spacer retirement, cell write, REP bookkeeping), with two front doors: GL
  bytes with charset translation, decoded scalars without. Prefix arithmetic
  is in scalars, not bytes, where they diverge.
- D7. The shared cell writer's supplier contract becomes "called exactly once
  per offset, ascending": it captures the last written scalar during its
  single pass instead of re-calling the supplier afterward. This is what
  makes a sequential-decode supplier legal with no scratch collection, and it
  removes the redundant re-call from the existing ASCII path too. The cluster
  context's retained byte count then reflects the true multi-byte length
  automatically.
- D8. The calibrated corpus (`benchmarks/fixtures/terminal-app.json`) is not
  touched. The `terminal-feed` harness concatenates every manifest workload
  into one stream, and that workload's 2.50% rule is frozen against that exact
  four-corpus stimulus, so adding a fifth workload changes the measured series
  the rule was calibrated on. Re-freezing needs the corpus's two-stage
  screen-then-confirm protocol, which is separate work. The
  box-drawing/braille win is therefore reported descriptively, from an
  uncommitted scratch stream fed to the same release benchmark binary on both
  arms.

## Invariants

- I1 (equivalence): feeding any byte sequence produces a `Terminal` equal to
  feeding the same bytes one byte at a time. Run recognition changes only
  cost -- never grid, cursor, cluster, identity, wrap, charset, or
  damage-visible state.
- I2 (chunk invariance): the expanded action stream and the stream reducer's
  value are identical for every split of the same bytes, including splits
  inside a multi-byte scalar and at run boundaries; a trailing partial scalar
  stays out of the run and replays through the incremental decoder.
- I3 (single statement): the bulk-run predicate is derived from the scalar
  record; the change introduces no new hardcoded scalar or byte range list.
- I4 (no materialization): no token array and no per-run scratch collection
  of scalars or offsets is materialized on the feed path (research/33/F9).
- I5 (GL separation): charset translation continues to happen exactly and
  only where raw GL bytes become scalars; a scalar run is never translated
  and never contains a byte below 0x80.
- I6 (one decode per layer): the action carries bytes, not scalars (RI2), so
  each admitted scalar is decoded twice by construction -- once by the parser
  probe, once by the reducer's sequential supplier. Neither layer decodes the
  same scalar a second time, and no layer adds a third pass: a clean non-bulk
  scalar becomes `.print` from the probe's own decode. Accepted exception in
  AR1.

## Proof obligations

- PO1 (I1): chunk-and-granularity equivalence scenarios containing
  bulk-printable multi-byte content, asserting full-`Terminal` equality
  against per-character replay across the existing chunk-size sweep. The
  existing sweep fixtures contain no bulk multi-byte scalars (only wide,
  prepend, and combining ones), so new scenarios are required, not optional.
  They must cover the risk families the design review identified: the
  GL/scalar boundary under a locking shift with interleaved ASCII and
  box-drawing bytes; margin wrap under both DECAWM states; overwrite of wide
  cells; an open prepend cluster; a combining mark and a variation selector
  arriving after a run; insert mode; the content-identity wrap straddle; and
  REP after a run.
- PO2 (I2): parser split sweeps over runs, including splits mid-scalar and at
  run boundaries, comparing both the expanded stream and the stream value
  (the existing tuple-comparing helper). Malformed sequences and lone
  continuation bytes adjacent to runs expand identically to byte-at-a-time;
  encoded U+FFFD inside a run stays in the run (D5).
- PO3 (I3): a predicate premise test parallel to
  `printableASCIIIsNarrowAndBreaksOther`: representative bulk families (box
  drawing, braille, Cyrillic, Greek, Latin-1) satisfy the predicate; known
  joiners and wides (combining mark, ZWJ, VS16, CJK, prepend, a variation
  base, Hangul jamo, regional indicator) do not. The existing 0x20...0x7E
  table test keeps passing unchanged.
- PO4 (I5): a token-level test pinning that a mixed ASCII/multi-byte stream
  yields alternating `.printASCIIRun`/`.printScalarRun` tokens, and the
  locking-shift scenario from PO1 pinning translated output.
- PO5 (I6, AR2): `just benchmark-quick baseline=HEAD workload=terminal-feed`
  over the byte-identical committed corpus must not read slower. That is one
  aggregate verdict read under the workload's frozen rule; the harness exposes
  no per-workload arm. The box-drawing/braille win is reported descriptively
  (D8), never as a directional claim.
- First failing test (TDD): the parser token test -- feeding a box-drawing
  row in ground state yields exactly one `.printScalarRun` with the index
  advanced (today: one `.print` per scalar). The identity-run-count grid
  check cannot serve as a bulk-path detector: the per-character path also
  mints contiguous identities, and by house rule every grid test passes both
  before and after the bulk path exists.

Every test in `TerminalASCIIRunTests`, `TerminalInputStreamTests` (including
the malformed and C1 fixtures), and the content-identity shape suite must
keep passing unchanged; `expandedFeed` (test-side) gains a sequential-decode
expansion of the new action so parser suites keep asserting scalar-level
streams.

## Non-goals

- No change to `.printASCIIRun` semantics, GL translation, or single-shift
  bookkeeping.
- No generator (`scripts/generate-terminal-unicode-tables.py`) change and no
  table regeneration.
- UNI-3/FEED-5 (grapheme classifier set representation) and UNI-4
  (canonical-caseless affectedness) stay separate.
- No search-path changes (FIND-1 is being worked in parallel in
  `TerminalSearch.swift`).

## Accepted risks

- AR1: the clean non-bulk scalar that terminates a run is decoded twice --
  once ending the probe, once as the next call's first scalar. Once per run
  boundary, not per scalar; avoiding it would require mid-feed state on the
  Equatable stream value, which its contract forbids.
- AR2: a non-bulk scalar is classified twice (probe and per-scalar print).
  One extra table read on paths already doing cluster/wide work; gated by
  PO5's aggregate `terminal-feed` verdict rather than pre-emptively carrying
  classification in the action.
- AR3: the regression gate is the aggregate `terminal-feed` verdict, so a
  regression confined to Unicode-heavy content could be diluted by the
  ASCII-dominated corpora sharing the stream. Sharpening it means calibrating
  and freezing a new decision rule under the corpus's two-stage protocol,
  which is separate work.
- AR4: the off-manifest improvement stream is not a frozen fixture, so its
  exact bytes are not reproducible across implementations. It decides nothing
  -- it is descriptive, no verdict -- and freezing a stimulus is what a
  calibrated workload is for.

## Rejected ideas

- RI1: widening `.printASCIIRun` to cover decoded scalars -- its pinned
  contract is one charset-translated GL print per byte; decoded scalars must
  never translate, so one action cannot carry both semantics.
- RI2: carrying a scalar count or classification in the action -- bloats a
  POD Equatable action with values derivable from the bytes, adds a
  consistency obligation every consumer must trust, and still would not make
  a sequential supplier legal (D7 is what does).
- RI3: emitting the predicate from the generator as a stored palette field --
  regeneration needs unicode.org access, and a property computed from the
  landed record's own fields is the same single statement without it.

## Implementation discretion

- The probe loop's internal shape (fused lead-byte/cell-kind scan vs.
  separate bounded scans) and the companion file's name/placement.
- Whether the two front doors share one parameterized function or two thin
  wrappers over the shared tail.

## Measurement

- Regression gate (PO5): `just benchmark-quick baseline=HEAD
  workload=terminal-feed` with the committed corpus unchanged, read as one
  aggregate verdict under its frozen rule.
- Improvement report, descriptive only: a scratch box-drawing/braille
  TUI-redraw stream generated under `.build/`, framed the way the feed harness
  frames its corpus and fed to the release `TerminalCoreBenchmark` on both
  arms, plus `just benchmark-feed-sample` on an existing workload for
  attribution. No directional claim comes from either.

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/TerminalInputStream.swift` -- new
  action case and run recognition.
- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` -- reducer arm,
  shared bulk core, cell-writer supplier contract (currently
  `printASCIIRun`/`printBulkASCII`/`writeNarrowCells`, ~6746-6953).
- New hand-written companion for the predicate beside
  `UnicodeProperties.generated.swift`.
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalInputStreamExpansion.swift`,
  `TerminalInputStreamTests.swift`, `TerminalASCIIRunTests.swift` -- expansion
  helper and new tests.

## Verification

1. TDD order: the parser token test first (fails today), then predicate
   premise test, then the equivalence/chunk scenarios as the implementation
   lands.
2. `swift test --package-path lib/TerminalCore` for the targeted suites;
   `just test` as the full gate.
3. Benchmarks per Measurement; run once into a file under `.build/` and grep.

## Implementation notes

- The decision-bearing `terminal-feed` comparison used baseline tree
  `ff24491593e00fdce0f3ae33373db52b42c4d7aa` and candidate tree
  `5c7b101978ac7ebd4ff63ffa450baf2e0179bb4d`. Quick was inconclusive at -1.39%,
  so the prescribed escalation to confirm resolved it as equivalent at -0.72%.
- An uncommitted 120-frame, 179x66 box-drawing and braille redraw stream measured
  descriptive medians of 97,507,140 ns on the baseline and 33,970,276 ns on the
  candidate (-96.65% symmetric). This stimulus has no frozen identity or rule and
  makes no directional claim.
- The attribution-only `styled-screen-redraw` sample collected 16,660 samples.
  `Terminal.printBulkNarrow` held 18.9% self time and
  `TerminalInputStream.nextAction` held 8.1%.
