# Grapheme cluster assembly and emoji width (Milestone 2, slice 3)

Third implementation slice of [14-roadmap.md](../../plan-terminal-engine/14-roadmap.md)
Milestone 2, governed by
[05-unicode-grid-scrollback.md](../../plan-terminal-engine/05-unicode-grid-scrollback.md)
(extended grapheme clusters as the default indivisible unit, no application
opt-in) and the pinned-fixture guidance in
[docs/research/1-external-tests.md](../../docs/research/1-external-tests.md).
Deliberately sequenced before scrollback/reflow: reflow must operate on the
final indivisible cell unit, so that unit has to exist first.

## Problem

Slice 1's width-based appending covers scalar widths and combining marks but
explicitly deferred UAX #29 segmentation, ZWJ emoji sequences, emoji
modifiers, regional-indicator flags, and the VS16 narrow-to-wide upgrade to
this slice. Until clusters are the real unit, family emoji shatter across
cells, flags split into halves, and VS16 sequences render at the wrong width
-- and the scrollback/reflow slice would bake the wrong unit into line
identity.

Load-bearing evidence (verified):

- Reference clustering print path: `.ghostty-src/src/terminal/Terminal.zig`
  `print` (302-674) -- break-driven appending, VS16/VS15 width changes,
  end-of-line cluster relocation with scalar transfer, and a cursor/pending
  -wrap epilogue identical in shape to DanTerm's existing `printWide`.
- A complete, portable pairwise Unicode 17 break algorithm with a five-state
  break state (including GB9c Indic conjuncts) in Ghostty's pinned `uucode`
  dependency (Zig package cache, `uucode/src/grapheme.zig:197-415`), plus its
  class-fold recipe (`build/tables.zig:1007-1070`) and width tailorings
  (`x/config_x/wcwidth.zig`: Regional Indicators wide; modifiers, Hangul V/T,
  and Prepend never widen a cluster they join).
- Pre-staged DanTerm mechanisms in
  `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`: multi-scalar
  `GridCell` storage, the `attachTarget` lifecycle, `clearCellAndPair` pair
  discipline, `eraseCells` range widening, and `printWide`'s
  edge/spacer/cursor rules.
- The pinned-data generator pattern with dual independent generation
  (production table + exhaustive test reference):
  `scripts/generate-terminal-unicode-tables.py`, Unicode 17.0.0, SHA-256
  verified fetches.

## Decision

Implement streaming Unicode 17.0.0 extended-grapheme-cluster assembly as the
engine's default and only behavior, by replacing slice 1's width-based
zero-width appending with break-driven appending, plus a deterministic
cluster width function and the VS16/VS15 width changes ported from the
reference.

- **Pure pairwise segmenter, strict UAX #29.** A pure pairwise break
  function over a small value-type break state and a generated folded
  per-scalar break-class table -- a Swift port of uucode's
  `computeGraphemeBreak`, but strict UAX #29: uucode's emoji-modifier
  tailoring is not ported, so the official corpus passes verbatim with zero
  carve-outs. CR/LF/Control classes are included so the corpus drives the
  segmenter unfiltered, even though the terminal never feeds it controls.
- **Break-driven appending, no buffering.** The first scalar of a cluster
  prints immediately through the existing narrow/wide paths. `attachTarget`
  grows into a single optional cluster context, so "a cluster is open iff
  the context exists" is structural.
  For each printed scalar with an open context, the break decision runs
  BEFORE pending-wrap consumption and width dispatch: no-break appends to the
  target cell (with the width rule below) and never wraps; break falls
  through to the existing print path with a fresh default state. Because the
  context lives in the `Terminal` value and participates in synthesized
  equality, an unfinished cluster spanning `feed()` boundaries continues
  exactly -- chunk invariance is structural, with no flushing and no output
  latency.
- **Non-joining zero-width scalars drop invisibly.** A zero-width scalar
  that would start a cluster (no open context, or the segmenter breaks) is
  discarded without touching grid, cursor, pending wrap, or the open context
  -- so a dropped scalar is invisible to later join decisions. This is
  behaviorally equivalent to the reference's replay-from-stored-cell
  semantics (`Terminal.zig:562` drops; 368-382 replays) and subsumes slice
  1's leading-mark discard. Slice-1 behavior changes for break-class formats
  such as ZWSP that currently glue onto the previous cell.
- **Deterministic cluster width, always 1 or 2 cells.** A cluster's width
  starts as its leading scalar's table width. VS16 forces 2 and VS15 forces 1
  when the cluster's base scalar is a valid emoji-variation-sequence base
  (pinned from `emoji-variation-sequences.txt`, so keycap bases like `#` and
  digits upgrade -- reference parity); on any other base a variation selector
  is stored but changes nothing. Any other joining scalar widens the cluster
  iff its table width is nonzero and it is not an emoji modifier, Hangul
  V/T jamo, or Prepend-class scalar (the reference's rule; SpacingMark
  matras therefore widen their cluster). The width table gains the reference's Regional Indicator
  tailoring: RI scalars are wide, so a lone RI and a flag pair are both
  stably 2 cells. This function is the whole answer to the open question on
  malformed/unsupported emoji cluster width -- no special fallback exists;
  the slice deletes the resolved question from
  [15-open-questions.md](../../plan-terminal-engine/15-open-questions.md).
- **Upgrade/downgrade reuse the wide-print discipline.** Widening a narrow
  cluster cell mid-row clears the neighbor through the existing pair
  discipline, flips the cell's kind in place preserving its scalars, writes
  the tail, and applies `printWide`'s exact cursor/pending-wrap epilogue.
  Widening at the last column relocates the cluster the way the reference
  does: spacer head in place, row marked soft-wrapped, advance (scrolling at
  the bottom row), the whole scalar list re-materialized as a pair at the new
  row start, and the context re-targeted only after all row mutation
  completes. VS15 downgrades a wide cluster in place: head flips narrow
  keeping scalars, tail frees, cursor steps back one or clears pending wrap
  at the right edge; DanTerm additionally clears a now-stale previous-row
  spacer head when downgrading at column 0, extending slice 1's spacer
  hygiene.
- **Reset points are inherited, not invented.** Exactly the events that
  reset `attachTarget` today break an open cluster: cursor movement, BS/CR/
  LF/VT/FF, motion-producing TAB, every cell-mutating erase, and soft wrap.
  Bit-identical no-ops (ignored C0, ignored CSI dispatches, ED 3) preserve an
  open cluster, as slice 2 pinned via whole-value equality. A U+FFFD from
  malformed UTF-8 needs no special case: it participates by its break class
  alone -- breaking a mid-ZWJ sequence and printing as an ordinary narrow
  cell, but joining an open cluster whose last scalar is Prepend-class
  (GB9b).
- **Generator and fixtures extend the pinned-data pattern.** The generator
  fetches four new Unicode 17.0.0 files with recorded SHA-256 pins --
  `auxiliary/GraphemeBreakProperty.txt`, `DerivedCoreProperties.txt` (InCB),
  `emoji/emoji-variation-sequences.txt`, and
  `auxiliary/GraphemeBreakTest.txt` -- and emits, alongside the regenerated
  production and reference width tables, an independently computed per-scalar
  break-class test reference and the official corpus as a generated Swift
  fixture. The corpus drives the segmenter function directly; terminal-level
  tests use representative sequences (the fixture separation is deliberate:
  the terminal intentionally deviates by dropping non-joining zero-width
  scalars and handling controls upstream).
- **Recorded deviations from the Ghostty reference** (future differential
  traces carve these out by name): D1 strict UAX #29 emoji-modifier joining
  (uucode tailors modifiers to Emoji_Modifier_Base). D2 invalid variation
  selectors are stored scalar-exactly, not dropped. D3 cursor movement breaks
  clusters (mode-2027 Ghostty derives cluster identity from grid content and
  attaches across movement; slice 2 already pinned DanTerm's choice). D4
  VS15 downgrade at column 0 clears the stale previous-row spacer head. D5
  non-joining zero-width scalars always drop (matches Ghostty's mode-2027
  path; DanTerm has no mode toggle).

## Invariants

- I1. Chunk invariance extends to cluster assembly: identical bytes produce
  identical terminal state -- open cluster context included, participating in
  value equality -- regardless of chunking; a cluster spanning any feed
  boundary assembles identically.
- I2. Purity unchanged: no IO, no imports, no callbacks; segmentation is a
  pure function over generated pinned tables.
- I3. Segmentation fidelity: the segmenter implements Unicode 17.0.0 UAX #29
  extended grapheme clusters exactly -- every boundary of every official
  corpus case passes verbatim. Terminal assembly applies those boundaries to
  the retained stream of printed scalars -- those that survive the drop rule
  (I7) -- between reset events (I6).
- I4. Cluster atomicity: a completed cluster occupies exactly one narrow cell
  or one wideHead/wideTail pair, stores its scalars exactly and in order in
  the head cell, appears whole in screen text, and is overwritten, erased,
  and scrolled only as a whole.
- I5. Width determinism: every cluster's width is the pinned accumulation
  function, always 1 or 2; VS16/VS15 change width only on pinned valid
  emoji-VS bases; Regional Indicators are wide alone and in pairs; no
  upgrade, relocation, or downgrade corrupts neighbors, spacer heads,
  soft-wrap flags, or pending wrap, including on the minimal 2-column grid
  and when relocation scrolls the bottom row.
- I6. Reset fidelity: exactly the slice 1-2 attach-reset events break an open
  cluster; bit-identical no-op events preserve it; U+FFFD participates by
  classification alone, not special-casing -- breaking mid-ZWJ, joining
  after a Prepend-class scalar.
- I7. Dropped-scalar determinism: non-joining zero-width scalars vanish
  without affecting grid, cursor, pending wrap, or subsequent join decisions.
- I8. The slice 1-2 grid validity invariants hold after every new mutation
  path.
- I9. Recovery: adversarial grapheme-heavy byte input cannot crash, hang,
  corrupt grid structure, or prevent later valid output.

## Proof obligations

- PO1 (I3). The generated official corpus drives the break function
  directly: every boundary of every case asserted, no filtering, no
  carve-outs.
- PO2 (I3, I5). Exhaustive generated-table sweeps in the existing
  `UnicodeWidthTests` pattern: folded break classes match the independent
  reference for every scalar, and the regenerated width reference pins the RI
  tailoring and the emoji-VS-base property across the full range.
- PO3 (I1). The canonical chunk-invariance harness gains cluster fixtures --
  a family ZWJ sequence, a modifier sequence, flag pairs plus a lone RI,
  VS16 at the last column, a keycap sequence, an Indic conjunct, and
  malformed bytes interrupting a ZWJ sequence -- every 2-way and 3-way split
  and byte-at-a-time, equal to single-chunk state.
- PO4 (I4). Assembly matrix at terminal level: each representative sequence
  yields one cell/pair with exact scalar storage and stable screen text;
  overwriting either half of an upgraded pair clears the whole cluster; erase
  ranges never split one; scroll discards one whole.
- PO5 (I5). Upgrade/downgrade matrix, each case followed by the
  grid-validity sweep: VS16 mid-row over empty, narrow-occupied, and
  wide-pair-occupied neighbors; VS16 with the cluster at the last column
  (spacer head written, row soft-wrapped, scalars relocated, cursor and
  pending wrap per the wide-print rule), including at the bottom row (scroll)
  and on the 2-column grid; VS16 on an already-wide cluster (width
  unchanged); VS15 downgrade mid-row and at the right edge, including the
  column-0 stale-spacer cleanup; a variation selector on a non-base (width
  unchanged, scalar stored); flag-pair and dangling-RI geometry; a
  width-contributing joiner upgrading a narrow base (ZWJ-joined wide
  pictograph; SpacingMark matra); excluded joiners leaving a narrow cluster
  narrow (`A` + emoji modifier, U+1160 + U+1161 Hangul V pair, U+0D4E +
  U+0D4E Prepend pair).
- PO6 (I6). Reset matrix: each mutating control, movement, and erase
  interposed mid-sequence yields two clusters; ED 3, ignored C0, and ignored
  CSI dispatches interposed mid-sequence still join; a mark after movement
  does not attach; RI parity does not leak across a forced reset.
- PO7 (I7, I6). Drop matrix: leading Extend/ZWJ with no context discarded; a
  break-class format dropped mid-cluster leaves grid and context untouched
  and a following mark still joins; U+FFFD mid-ZWJ-sequence breaks, prints
  narrow, hosts a following mark, and later valid emoji assemble intact;
  U+FFFD after a printed Prepend-class scalar joins that cluster (GB9b)
  instead of printing separately.
- PO8 (I9, I8). Seeded deterministic fuzz with a grapheme-biased alphabet
  (RI/ZWJ/VS/modifier/pictograph UTF-8 bytes, controls, CSI introducers)
  ending in a sentinel: sentinel visible, full validity sweep; both existing
  fuzz harnesses stay green.
- PO9 (I1, I2, I8). Slice 1-2 suites pass with only the enumerated re-pins
  (variation-selector storage on non-emoji bases, break-class Cf attachment,
  lone-RI width, VS15 downgrade geometry), each re-pinned to the new
  contract in place; purity and import gates stay green.

Slice exit gate: `just test` green with the new tests and regenerated tables
wired in, plus the roadmap slice entry checked off. Left open for later
slices: scrollback/reflow of clustered rows, styles on clusters,
selection/search units, rendering, REP-with-cluster interplay, per-cell
storage caps, and differential traces against live Ghostty.

## Non-goals

- Mode 2027 protocol handling: clustering is unconditional per the 05
  contract; no opt-in/out surface.
- Scrollback, resize/reflow, styles, selection, and rendering.
- Bidirectional text semantics (bidi format controls drop; recorded under
  D5).
- uucode's tailored-cluster emoji-modifier divergence and its summing
  cluster widths above 2 (the reference terminal's incremental force-to-2
  rule is what is ported).
- Leading-Prepend width refinement: a Prepend-led cluster keeps its leading
  scalar's table width (nonzero-width Prepends such as U+0D4E print narrow
  and hold the cluster open via GB9b; Cf-class Prepends are zero-width and
  drop when defective); the reference punts equivalently.
- A per-cell scalar-count cap (AR3).

## Accepted risks

- AR1. Deviations D1-D5 will surface in future differential traces; each is
  carved out by name above.
- AR2. Terminal equality is sensitive to an open trailing cluster: two grids
  with equal cells can compare unequal in context state -- intended,
  mirroring slice 2's collection-state equality.
- AR3. Unbounded scalar accumulation in one cell under pathological Extend
  runs, linear in input size; carried from slice 1's uncapped zero-width
  appending, bounded later by the storage-budget slice.
- AR4. New pinned files' SHA-256 values are recorded at first fetch, the
  same trust model as slice 1's three files.
- AR5. The width-contributing set is reproduced from DanTerm's own tables
  plus break classes rather than uucode's precomputed bit; exotic scalars
  could diverge from the reference and would land in differential-trace
  carve-outs.

## Rejected ideas

- RI1. Ghostty-style content-derived cluster identity (re-deriving the open
  cluster from the neighboring cell on every print): attaches marks across
  cursor movement, contradicting the slice-2 pinned reset contract, and
  costs a per-print replay of stored scalars; the persistent context is
  chunk-invariant by construction.
- RI2. Dropping invalid variation selectors (reference behavior): rejected
  for a uniform no-break-means-append rule and scalar-exact cell storage;
  recorded as D2.
- RI3. Gating VS16 on Extended_Pictographic instead of pinned emoji-VS
  bases: avoids one fetched file but breaks keycap sequences and reference
  parity.

## Implementation discretion

- Break-class enum encoding, whether the break function stays direct or
  precomputes a pair table, cluster-context field shape, and any always-break
  ASCII fast path (behavior-neutral here given the drop rule).
- Generated-file granularity (extend `UnicodeProperties.generated.swift` vs
  sibling files), fixture Swift encoding, and test-file organization.
- Commit slicing (each commit green; a natural split is tables+segmenter+
  corpus, then break-driven assembly, then width policy+upgrade mechanics).
- Source/test/generated-file placement and naming.

## Commit progress

- [x] 1. Add pinned grapheme tables, the pure segmenter, and official corpus coverage
- [x] 2. Assemble grapheme clusters through break-driven terminal attachment
- [ ] 3. Apply cluster width policy and upgrade/downgrade geometry
