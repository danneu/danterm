# Packed retained rows (doc 28 / H3)

## Status -- C1 IMPLEMENTED AND MEASURED; five of six pass, `scrollback-stream` does not

`F19` is the deciding run, at `48f52b1` against `678bfe9` on an idle host (load
1.88, 0.19 per processor). **The pivot did what `D9` chose it to do.**
`retained-browse` -- the workload that decided against C6 at +19.83% -- came back
**at the pre-packing baseline, -0.11% against a 1.05% threshold**. `terminal-feed`
+1.50%, `incremental-mixed` +1.27% while planning frames **24.08% faster**,
`content-churn` +1.72%, `style-churn` +0.74%: all passes.

Memory: **10.49 -> 3.72 MB at 179x66** and **10.17 -> 3.40 MB at 80x24**, at
**1.11x the depth** at both. Resize holds `D8`'s line to within 1% in all three
regimes (116.9 / 56.3 / 103.8 ms). `F18`'s central prediction was confirmed to
five cells -- 327,675 retained against `D8`'s 327,680 cap -- so depth really is
representation-independent and the pivot really did cost none of it. `F18` was
pessimistic about the giveback: 123 B/row against C6's 69, not the predicted 4.12x,
because the per-row constants do not scale with the payload.

**`H3` does not graduate, on one workload.** `scrollback-stream` answers `slower`
at **+6.51%**, and it did not move between C6 and C1 -- representations differing
4x in per-row bytes -- while every other workload cleared. It is the bare-LF
staircase stimulus (`F11`): 134 stored cells per row with **66.4% holding no
scalar**, and a flat 8-byte cell charges a never-written padding cell full price.
Its drain rose 163.2 -> 180.3 ms while its draw tail fell.

That is the representation's shape, not its wiring, so no fix was improvised --
the plan's boundary makes a non-uniform cell column a stop-and-report. The
disposition returns to the human.

`F19` Observation 5 also records what nearly buried the pivot: C1's first encoder
appended each cell byte by byte and measured `terminal-feed` at **+6.19%**, worse
than the C6 encoder it exists to beat. **For a representation this small the
encoding is not the cost; the allocation and write pattern around it is** -- which
is the same class of error `F17` found on the read side.

## How the pivot was decided

C6 shipped at `efa549f`, got `D8`'s dual caps, had its read path profiled and
fixed by `F17` at `2ae37c4`, and still failed the deciding ladder on four of six
workloads. `D9` rejected it and selected **C1 -- a fixed 8-byte retained cell**,
keeping the seam, the caps, the invariants, and the whole test/probe apparatus.
This plan is now written against C1; the C6 history below is kept because the
measured reasons are what make the pivot auditable.

**What C6 measured, and why it was rejected.** The memory claim held to the byte
(**128.0 B/row**, `D6`'s figure reproduced). Gate item 6 failed first at
**14.2x** (`F14`/`D7`) and `D8` fixed it with two content-denominated caps --
327,680 stored cells and 16,384 rows -- returning every content regime to within
**1.19x** of pre-packing. The full ladder then failed (`F16`), worst
`retained-browse` at **+19.83%** against 1.05%. `F17` profiled that read: the
suspected per-cell point reads were **not** the cause (the planner already took
`PO5`'s linear walk); two readers were materializing a whole row each, per
visible row per frame. Streaming all three readers cut browsing to **+3.27%** and
put `geometry` *below* the baseline arm -- and the gate still failed, because
what remains is the decode itself (~3.8 ns/cell) plus `pack(_:)` at 9.2% of feed
self time on the three admission-bound workloads.

**Why C1 costs no depth, which is the fact that makes the pivot cheap.** `D8`'s
caps count *content*, not bytes. At 51.00 stored cells per row the cell cap
admits **6,425 rows under either representation** -- the byte budget is slack by
4.1x under C6 and 1.9x under C1 (`F18`). So C1 retains exactly the rows C6
retains and gives back only memory: **528.0 B/row against C6's 128.0 and
pre-packing's 1,808.0** -- still **3.42x cheaper per row than pre-packing**, at
~3.1x total memory improvement instead of ~12.8x. Before `D8`, an 8-byte cell
would have cost 12.7x the depth of a 1-byte one and this pivot would have been
unaffordable. **The caps already took away depth-per-byte, which is the objective
C6 was selected over C1 to serve.**

What the bytes buy is the read path: a column read becomes a load at a fixed
offset with no decode, no cursor and no table, and admission becomes a
translate-copy of 8 bytes per cell where pre-packing copied 32. `D9` records the
trade and the human judgement behind it; `F18` prices it.

## Problem and desired outcome

Retained history is the dominant term in DanTerm's terminal memory footprint,
and a retained row currently pays for a full cell struct per stored cell whether
or not it uses one. Doc 28's `F8` put **89.5% of saturated attributable
footprint in stored cell bytes** at 179 columns and 89.3% at 80 -- a 9:1
ordering over per-row overhead that does not vary with pane width.

The desired outcome is a retained-row representation that stores the same
observable content in far fewer bytes, so the same 10 MiB budget admits
substantially more scrollback depth, with no regression on the feed path or the
browsing path.

### Load-bearing premises, and the evidence for each

- **Stored cell bytes are the large side.** `F8`, both widths.
- **Ragged savings survive the allocator.** `F10`: macOS malloc above 256 B is
  four buckets per octave (~12.5%, geometric), so rounding is proportional to
  the request; ragged storage realized 70.8% against 71.1% on paper.
- **A packing scheme must shrink a row's request by more than one ~12.5% bucket
  step** or the saving can round back to zero (`F10`, adopted by `D3` as a
  design admission test). C6 clears it at 100% of rows in the committed corpus,
  on `D6`'s corrected pricing.
- **Content composition at depth** (`F11`, 94,990 rows): 22.54% of stored cells
  styled but only **1.66 style runs per mean row**; 0.119% multi-scalar; 1.32%
  of scalars non-ASCII at **0.903 UTF-8 bytes per stored cell**; 0.37% carrying
  a hyperlink.
- **The feed path cannot resolve ~1%** (`F1`: four schedules agree +1.03% to
  +1.45%, inside the harness's dead zone).

Every number above is reproducible from committed probes at or after the
evidence floor `dd51a12`.

## What is decided, and what Phase 0 decides

**Decided now, and not reopened by Phase 0:** retained rows get a packed,
immutable representation; packing happens at scrollback admission, where
canonical trimming already happens; the live grid is untouched (`I1`). The
invariants, proof obligations, and verification gate below hold for whatever
representation is chosen -- `I5`, PO3, and PO5 name a slot/run/exception shape
and would be restated in the chosen form, but their contracts (no row scan on a
random read, metadata survives every path, the win is measured) do not change.

**Decided by Phase 0, which has run.** `D5` selected C6 on pricing that omitted
required metadata; `PR1` corrected the accounting and `F12`/`D6` re-selected C6
under *both* `contentIdentity` variants.

**Superseded by `D9`, on evidence Phase 0 could not have had.** C6 was
implemented, capped, profiled and measured, and it failed the deciding ladder;
`D9` rejects it and selects **C1**. What changed is not the pricing -- `D6`'s
arithmetic was reproduced to the byte -- but two things no priced table contains:
the measured cost of the decode (`F17`), and `D8`'s caps making depth
representation-independent (`F18`). `D5`'s reason for preferring C6 over C1 was
depth per byte; `D8` retired that contest before the ladder ran.

This plan is therefore two phases with a hard boundary. **Phase 0 was
evidence-only** -- no engine code -- and closed with `D6`. **Phase 1 implements
the selected representation**, which is now C1.

## Phase 0 -- complete the metadata accounting and select the representation (CLOSED by `F12`/`D6`)

**Outcome.** Every field is preserved and none dropped; `contentIdentity` is
charged per contiguous run, because `F12` measured **85.14%** of retained rows at
depth (and 100% of the CRLF reference payload) as printed contiguously. C6 remains
cheapest on both headline pools under both variants, and the C6-against-C3 margin
widened from 8.8 to 15.9 B/row on the saturated pool. `D6` carries the field-by-
field adjudication table and supersedes `D5`'s byte figures.

The rest of this section is the specification `PR1` ran against, kept because the
reasoning is what makes the corrected table auditable.

`D5` priced C6 from `scripts/terminal-retained-row-shape.py#pack_stride_runs_exceptions`,
which charges `wide + multiScalar` only. Hyperlink cells are named in the design
and charged nowhere. And `pack_narrow_cell`'s premise that a retained cell's
`contentIdentity` "has no reader here" is wrong:
`Terminal.swift#activationIdentity` takes `max(contentIdentity)` over a
`ProjectionRows` range, which spans retained rows, so safe link activation reads
it out of history. Every candidate was therefore priced against incomplete
storage, and C6's 114.5 B/row against C3's 123.3 was not a decided margin.

The stakes are not rounding: `contentIdentity` is allocated **once per printed
cell** (`Terminal.swift#allocateContentIdentity`, called from both print paths),
so it is a uniquely-valued 4-byte field on every content cell, on a scheme whose
modal scalar slot is **1 byte**. Preserved naively it is the difference between
C6's headline and no headline at all. But the values are not arbitrary: the
counter increments by one per printed cell, so a row printed left-to-right
without interruption holds an arithmetic sequence that a per-run base plus length
encodes in a handful of bytes. **Which of those two prices C6 actually pays is a
property of recorded content, not of the design** -- so `PR1` measures it rather
than assuming it, and charges the comparison both ways.

**Dropping `contentIdentity` is rejected, not open.** `activationIdentity` reads
zero as "this run has no identity", so a dropped field would silently stop
adjudicating links that live in scrollback -- an `I3` violation with no reader
that tolerates it, and `linkArmTracksRunIdentity` already pins the adjacent case.

**`PR1` -- the Phase 0 work, in order:**

1. **Inventory** every field a retained row must preserve: `GridCell`'s
   `scalars`, `kind`, `styleId`, `hyperlinkId`, `contentIdentity`, and
   `GridRow`'s `isSoftWrapped` and `semanticPrompt`.
2. **Adjudicate each** as preserved, deterministically regenerated, or
   deliberately dropped. A drop must name the reader that tolerates it; a drop no
   reader tolerates violates `I3`.
3. **Extend the probe's read surface to `contentIdentity`, read-only.** The
   probe reads retained rows through the public row reader, which does not expose
   the field, so no candidate can currently be charged for it at all -- step 4
   cannot run until this does. The measurement it must yield, per retained row:
   the number of maximal runs whose identities are contiguous in print order, and
   how many stored cells carry no identity. **The fraction of retained rows that
   are a single run is the number this step exists to produce**, because that is
   what decides between the two prices in step 4. `F11` inferred it optimistically
   (TUI-repainted rows largely do not reach scrollback) and never measured it.
   This is measurement machinery, not the packing change: it adds no stored
   property to any hot value type and keeps the per-cell walk inside
   `TerminalCore`, per
   [`docs/design/2026-07-29-cross-module-value-dispatch.md`](../../docs/design/2026-07-29-cross-module-value-dispatch.md),
   whose row-scoped-read precedent it follows deliberately rather than widening
   `TerminalCell`.
4. **Charge the corrected encoding** -- per-kind exception widths, spill
   references, hyperlink metadata, and `contentIdentity` -- in every candidate's
   pricing function, so C1-C6 are compared on one accounting. `contentIdentity`
   is charged **in two variants across every candidate**, and the corrected table
   reports both:
   - **Floor** -- preserved per cell, 4 bytes on every stored cell. The price if
     step 3's contiguity measurement comes back poor.
   - **Target** -- preserved as per-run base plus extent, so a contiguously
     printed row pays a small constant.
   Neither is the assumed answer. The measured single-run fraction selects
   between them, and if the floor is what recorded content forces, C6's headline
   is restated at the floor rather than quoted at the target.
5. **Prove the charge is complete before trusting the comparison.** The existing
   pricing tests feed `hyperlinkCellCounts` as all zeros, which is why the
   original omission survived review: a fixture that never exercises a field
   cannot catch a candidate that never charges it. Add a combined-metadata
   fixture with **nonzero** counts on every axis -- hyperlink, multi-scalar
   spill, wide-cell, non-ASCII stride tier, styled runs, and `contentIdentity`
   under both variants -- and assert every candidate's charge moves by the
   expected amount as each count is raised. A candidate whose price does not move
   when a field it must preserve is added is under-charging, and the fixture
   fails. This is the `I4` regression proof at pricing time, ahead of PO4's
   runtime check.
6. **Re-run** `just terminal-retained-row-probe "--saturated"` and select from
   the corrected table.

**Phase 0 exited** when the corrected per-candidate table under both
`contentIdentity` variants, the measured single-run fraction that selects between
them, step 2's field adjudications, and the selected representation were recorded
in `D6` -- which also supersedes `D5`'s uncorrected 114.5 B/row figure and its
claim that a retained cell's `contentIdentity` has no reader.

## Phase 1 -- implement the selected representation

Written against C1, which `D9` selected after C6 was implemented and measured.

A retained row stores a **fixed 8-byte cell per stored cell**, plus two side
tables and a small header. Nothing is chosen per row: no stride tier, no run
table, no exception list, no branch on a row variant.

- **The cell, 8 bytes.** A scalar needs 21 bits (`U+10FFFF`), a kind needs 3, and
  that leaves 40 bits in a 64-bit word for a **full-width 32-bit `StyleId`** with
  8 bits spare for flags. Exact bit allocation is implementation discretion, but
  two properties are not: **every scalar in Unicode stays inline**, including
  non-BMP -- there is no exception path for an emoji -- and **`StyleId` is not
  narrowed**, so no style-table ceiling is introduced. `D5`'s C1 sketch narrowed
  it to 16 bits against a measured table size; that was risk for no gain and is
  not carried over. A multi-scalar cell puts its **spill index** in the scalar
  field and marks it with a kind bit, so the spill directory C6 needed in the blob
  disappears.
- **A hyperlink side table**, 4 bytes per entry (2 B column + 2 B `HyperlinkId`).
  `HyperlinkId` is the one retained field that does not fit alongside the other
  three, and `F11` measured 0.37% of stored cells carrying OSC 8 -- small, not
  zero, and charged rather than assumed away (**0.60 B/row** pooled, 0.0 on the
  CRLF payload).
- **A `contentIdentity` encoding**: per contiguous run (`D6`), 8 bytes per run,
  with a per-cell fallback for a row whose run table would outgrow its cells. It
  is not droppable (`I3`). It costs **8.0 B/row** on the reference payload,
  because `F12`'s contiguity holds.
- **A per-row header**, 7 bytes: flags (1) plus three 2-byte counts (stored
  cells, hyperlink entries, identity entries). C6's was 13 for six counts. The
  header is charged here from the start, which it was not for C6 -- `F13`
  Observation 2 is the incident.
- **The two row-level `GridRow` fields, carried whole**: `isSoftWrapped` and
  `semanticPrompt`, in the header's flag byte. Neither is derivable from cells --
  `isSoftWrapped` is what width reflow uses to rejoin a wrapped line out of
  history, and `semanticPrompt` is what OSC 133 prompt navigation anchors on -- so
  a packed row that lost either would change observable content after a resize or
  break prompt jumps, while passing every cell-wise check. PO3 pins both.

**Why this shape.** It is the one that makes a column read a load at a fixed
offset with nothing to decode, which is what `F17` measured C6 paying ~3.8 ns per
cell to avoid needing. The three alternatives were priced and are rejected in
`RI1`, `RI2`, `RI4` and `RI5` below with their measured reasons. The one that
matters most is the shipped one: **C6 is rejected on a measured verdict set, not
on pricing** -- its arithmetic was right and its read was too slow.

### Sequencing -- two separately measured steps

1. **C1 replaces C6 in place and is measured alone**, against the full gate
   below. The encoder/decoder pair swaps inside `ScrollbackBuffer`; C6's stride,
   run and exception machinery is deleted once green.
2. **`H4` (aggregate storage for the packed payload) is a second, separately
   measured step**, unchanged as a contract. Its *size* is not carried over:
   `D5`'s "50/50 split, worth a further ~36%" was computed for a ~1 B cell, and
   C1's 8 B cell makes the payload the dominant term again. `H4` is re-priced
   before it is run, not assumed.

This ordering is a contract, not a preference: landing both at once makes an
`inconclusive` browsing result unattributable, and `D2` says to *expect*
`inconclusive` on that workload.

### Expected yield, priced against the CRLF reference payload

The headline figure is `F8`'s payload, `reference/scrollback-plain`, which is
**CRLF content**. Priced by `F18` on `D6`'s corrected accounting *plus* `F13`'s
two corrections -- a per-row header constant, and the strict identity-run count
the encoder actually writes:

| quantity | pre-packing | C6 (shipped, rejected) | **C1** |
| --- | ---: | ---: | ---: |
| payload B/row | -- | 78.0 | **423.0** |
| charge per retained row | 1,808.0 B | 128.0 B | **528.0 B** |
| against pre-packing | 1.00x | 14.12x | **3.42x** |
| retained rows at `D8`'s caps | ~5,799 | 6,425 | **6,425** |
| footprint at that depth | ~10 MB | 0.78 MB | **3.24 MB** |

**Depth is identical, and that is the point.** `D8`'s bounds count content --
327,680 stored cells, 16,384 rows -- so at 51.00 stored cells per row the cell cap
admits 6,425 rows under either representation. The byte budget binds under
neither (slack 4.1x for C6, 1.9x for C1). **The expected yield of this plan is
therefore a memory claim only**: ~3.1x less than pre-packing at ~1.11x its depth,
where C6 delivered ~12.8x. Quoting a depth multiple against the byte budget here
would be the single-arm error `F13` Observation 4 retired.

C1's 423.0 B/row payload decomposes as **408.0 B of cells** (51 x 8), 8.0 B of
identity runs, 7 B of header, 0 B of hyperlinks -- the cells are 96.5% of it, so
this design has almost no overhead left to tune and almost nothing to get wrong.

A secondary mixed-content estimate across the saturated pool is **343.4 B/row**
against C6's 136.2. It is secondary on purpose (`AR2`): the pool's mix is an
artifact of which recordings repeat well, its rows are shorter (31.54 stored
cells), and it is representation-dependent (`F13` Observation 1).

**The floor these figures sit above.** `D6` charges `contentIdentity` per
contiguous run because `F12` measured 85.14% of retained rows at depth (100% of
the CRLF payload) as printed contiguously. On content that fragments, C1 pays the
per-cell floor: +4 B on every stored cell, so **732.0 B/row** on the reference
payload. C1 is far less exposed to this than C6 was -- the identity encoding is
1.9% of its payload against 6.3% of C6's -- which is one of the pivot's smaller
robustness gains.

**Pricing honesty (`F11`'s staircase caveat).** `benchmark/scrollback-stream`
and `benchmark/unicode-wrapping` emit bare LF with no CR, so rows accumulate
leading padding: 66.4% and 39.8% of their stored cells hold no scalar, and their
mean rows are 134 and 129 cells against ~50 for CRLF content. That flatters any
gap-compressing scheme and is not what a real program writing through a PTY
produces (the tty driver's `ONLCR` adds the CR). **No expected-yield claim in
this plan may rest on those two stimuli.** It bites less under C1, whose cost is
flat in stored cells with no gap compression to flatter, but the bar is unchanged.

### Predicted feed effect, stated so the screening check is decidable

**Predicted: between -2% and +1.5%, most likely near neutral** (`F18`
Observation 5).

C1's admission does strictly less classification than C6's: no widest-scalar scan
to pick a stride tier, no style-run detection, no kind-exception table, no spill
directory -- one identity-run comparison per cell on a pass that already visits
every cell. And it writes **8 B per stored cell where pre-packing copied 32 B**,
so its write traffic is *below* the baseline's, against C6's `pack(_:)` measured
at 9.2% of feed self time (`F17`).

**Treat this prediction skeptically, and the reason is in this plan's own
history.** The C6 prediction two sections up -- "~+1% slower, bounded at +2%" --
was falsified by three separate readings (+2.72%, +3.10%, +5.18%), always in the
direction of costing more than predicted, and it was produced by the same style of
reasoning as this one. The prediction is an input to a gate, not a result.

**This prediction is under ~2%, so `D1` pitch 3's reopening condition fires.**
`scripts/terminal-benchmark-candidate-screen.py --workload terminal-feed` is
screened on a longer schedule **before** the deciding run, not after an ambiguous
one. The cheap retirement stands: if the implemented C1 measures a feed effect
**above** ~2% at `quick`, `F1`'s dead zone is not load-bearing and the screen buys
nothing.

## Invariants

- **I1 -- the live grid is untouched.** `GridCell` and the live grid's
  representation do not change. This is retained-only storage; doc 16's closure
  is an inherited boundary.
- **I2 -- canonical trimmed form holds.** A retained row's stored cells remain a
  pure function of its observable content.
- **I3 -- the observability contract holds.** Every column below `columnCount`
  reads as it did before, including cells reconstructed from a padding cell, a
  spill index, or a side-table entry.
- **I4 -- budget-charge coherence holds.** What the budget charges a row
  continues to describe what that row actually allocates.
- **I5 -- a random cell read never scans the row.** Under C1 this becomes
  **trivial for the cell itself**: fixed stride, no run search, no exception
  table, so scalar + kind + style id is one load at `base + column * 8`. The
  contract is unchanged, not weakened -- the two side tables are still
  column-ordered and still found by binary search, so a random read that needs a
  hyperlink or an identity is O(1) + O(log entries), and full-row iteration
  advances a cursor per table rather than re-searching per cell. What C6 needed
  this invariant to *argue* (that O(1) plus a bounded lookup beats a scan), C1
  gets structurally, and `F17` measured the difference the argument was hiding:
  the constant factor `PO5` never bounded.

## Proof obligations

- **PO1 (I1)** -- the live-grid behavioral suite passes unchanged; no live-grid
  representation change is introduced.
- **PO2 (I2)** -- a retained row's stored extent is unchanged from the current
  canonical trim for the same written content, across blank, ragged, trailing-
  whitespace, and full-width rows.
- **PO3 (I3)** -- retained rows round-trip: content written, scrolled off, and
  read back matches cell-for-cell. **The axes do not change with the
  representation and the battery re-runs unchanged** -- plain ASCII, non-ASCII at
  each of C6's former stride tiers (still worth exercising: they are content
  classes, and C1 must show they cost it nothing), interior never-written gaps,
  styled runs, wide cells, multi-scalar cells, and hyperlink cells, including rows
  combining several of these. A row carrying the combined metadata case must
  survive all three paths, not just admission: **admission**, **width reflow**,
  and **height transfer back into the live grid**. Concretely, an OSC 8 cell that
  scrolls into history and returns still resolves its target, and a link armed
  across it is still adjudicated over `contentIdentity`. Two further axes are
  row-shaped rather than cell-shaped: a soft-wrapped multi-row line survives
  admission plus width reflow rejoined (and a prompt-marked row read back from
  history keeps its `semanticPrompt` mark), and a fragmented-identity row --
  assembled by cursor moves so its run table would outgrow its cells --
  round-trips through the per-cell fallback with `activationIdentity` still
  adjudicating correctly over it. `narrowThenWidenPreservesCappedHistory` runs
  with them, because `D8`'s caps are unchanged and the round trip it pins is a
  property of the caps rather than of the encoding.
- **PO4 (I4)** -- the retained-row probe's `derivationMatchesCensus` reconstructs
  the census exactly, which trips loudly if the derived shape stops describing
  the representation. Its pricing model (`packedPayloadModelBytes` /
  `packedPayloadMatchesModel`) is **updated to C1** -- 7 B header, 8 B per stored
  cell, hyperlink entries, strict identity runs -- and held against the engine's
  real bytes on every stimulus in the corpus, as it was for C6.
- **PO5 (I5)** -- a row-reader microbenchmark shows a random cell read is flat in
  the row's stored width and no worse than logarithmic in its side-table entry
  counts, and that a full-row read stays linear rather than degrading to a
  quadratic walk. `retained-browse` validates the same contract on the real
  workload -- and, after `F17`, is the measurement that actually decides it: `PO5`
  proved C6's asymptotics and C6 still lost by 19.83% on constants.
  **These two tests are wall-clock and contention-sensitive.** If one fails,
  capture the log and change nothing; loosening a margin is a decision, not a fix.
- **PO6 (premise: the win is real)** -- the measured yield is reported against
  the CRLF reference payload at both geometries, per the gate below.

## Verification gate

`H3` is a memory claim and a CPU claim at once, so it clears only if the memory
claim is *measured* and neither CPU path answers `slower`. All of `D3`'s
criterion, unchanged:

1. **The deciding measurement.** `just terminal-memory-probe` at **both 179x66
   and 80x24**, reported in `F8`'s split -- stored cell bytes against per-row
   overhead -- with `just terminal-retained-row-probe` supplying the allocation
   decomposition. Absolute bytes and a percentage, both widths, both stated.
2. **The depth effect is stated and decided, never discovered.** Retained row
   count before and after at both widths. `F18` predicts **no depth effect at
   all** relative to C6 -- `D8`'s caps count content, so the cell cap binds under
   both -- and ~1.11x more depth than pre-packing. That prediction is *checked*,
   not assumed: if the measured depth moves, it is a trade and gets decided as
   numbers in a `D` entry before landing.
3. **Browsing, under `D2`'s frozen rule.** `retained-browse` must not answer
   `slower`: `quick` 2 pairs, +/-1.05%, band 1.0%; `confirm` 4 pairs, +/-1.05%,
   band 0.75%. **`inconclusive` is an acceptable pass and is expected** --
   `D2` wrote the 0.30-point dead zone into the rule itself, and reaching for a
   rerun on seeing it is the shopping `F1`'s protocol forbids.
4. **Admission.** `terminal-feed` must not answer `slower`: `quick` 2 pairs,
   +/-4.5%, band 1.0%; `confirm` 2 pairs, +/-2.5%, band 0.75%. The predicted
   effect above is under ~2%, so the longer screen runs first.
5. **The four standing ladder guards**, none of which may answer `slower`:
   `scrollback-stream` (4 pairs, +/-1.85%), `content-churn` (4, +/-2.15%),
   `style-churn` (4, +/-2.0%), `incremental-mixed` (6, +/-1.85%).
   `style-churn`'s ~3% residual from `F3`/`F4` needs no exemption -- it lives in
   `dd51a12..e4556c0` and sits in both arms of an adjacent-baseline comparison.
6. **Resize, at the caps, across all three regimes.** C1 changes what reflow
   unpacks and repacks on every retained row, so `D1` pitch 2's upgrade gate is
   still met and the comparison still **decides rather than describes**. What
   changed is the question: `D8` already answered the depth-for-resize trade
   (`F14`/`D7` -> `F15`/`D8`), and the caps that answered it are
   representation-independent, so this run is a **confirmation that C1 holds the
   `D8` line**, not a fresh adjudication. Run the two-armed `saturated-resize-v2`
   plus the sparse and wide recipes against `678bfe9`, and check all three regimes
   land near `D8`'s numbers (117.6 ms dense / 57.1 ms sparse / 104.1 ms wide,
   within 1.19x of pre-packing). A regime that drifts materially above them is a
   `slower` result on the one axis the caps exist to bound, and it stops the gate
   the way `F14` did.
7. **Every deciding run carries `summary.hostConditions`**, present with both
   pre-launch readings and **read before the verdict is trusted**. `D1` pitch 4
   admitted this as an annotation, not a gate: it will not refuse a contaminated
   run, and `F2` is the standing incident where the harness graded one
   `decisionEligible: true` under load average 4.73/5.89/8.92. A run whose host
   conditions are absent or unread is not a deciding run.
8. **Framing.** Baseline is the adjacent commit, not a wide range (`F3`: three of
   four `slower` verdicts evaporated when the baseline narrowed). AC power, no
   `DANTERM_BENCHMARK_ALLOW_BATTERY`. Every number at or after `dd51a12`.

Graduation: `faster` on a workload that *contains the moved cost*, nothing else
`slower`, or a trade stated as numbers and decided in a `D` entry before it lands.

## Risks, and what falsifies C1 early

Run these before the full ladder, cheapest first. Each has a stated threshold and
a named consequence. **C6's falsification list is retired**: it was about style
runs, stride tiers and exception lookups, none of which C1 has. What replaces it
is shorter, because C1 has less to be wrong about.

- **A read that is still slower than a struct load.** The whole pivot rests on
  `F17`'s reading that C6's residual ~3.8 ns/cell *is* the decode. If C1 measures
  `retained-browse` materially above 1.05% with a flat 8-byte cell and no decode
  left to remove, then the cost is packing as such -- the seam, the indirection,
  the loss of a stored `[GridCell]` returned by reference -- and **revert is the
  remaining exit, not a third representation.** `D9`'s reopening condition says
  so, and this is the check that fires it. Run `retained-browse` at `quick` first,
  before anything else on the ladder.
- **A feed cost above ~2%** -- then `F1`'s wall is not load-bearing and `D1`
  pitch 3's longer screen is unnecessary; below it, the screen is mandatory before
  the deciding run. Run `terminal-feed` at `quick` second, for that reason alone.
- **Resize drifting off `D8`'s line in any of the three regimes.** The caps are
  representation-independent and C1 stores the same cells, so dense/sparse/wide
  should land near 117.6 / 57.1 / 104.1 ms. They are the numbers `F14` taught this
  plan not to take on faith, and gate item 6 forces the result to be adjudicated.
- **Memory landing materially above `F18`'s 528.0 B/row.** `F13` Observation 2 is
  the standing incident: C6's 13-byte header was charged nowhere until the encoder
  was written. C1 is charged with a 7-byte header here, but a real encoder can
  still find a byte the model does not know about, and `packedPayloadMatchesModel`
  is what catches it on every stimulus rather than at the headline.
- **Retained rows whose `contentIdentity` is fragmented.** Unchanged as a risk and
  much smaller as an exposure: the identity encoding is 1.9% of C1's payload
  against 6.3% of C6's, so the per-cell floor moves C1 from 528.0 to 732.0 B/row
  rather than from 128.0 to 336.0. It no longer threatens the selection at all,
  only the headline's second decimal.

## Test-first order within Phase 1

TDD per `AGENTS.md`: for each proof obligation, write the failing test first,
verify it fails for the expected reason, then change the code and verify it
passes. The behavioral obligations (PO2, PO3) precede the representation change;
the probe and microbenchmark obligations (PO4, PO5) precede the falsification
checks; the measured-yield obligation (PO6) is the deciding run and comes last.

## Non-goals

- Changing the live grid's `GridCell` (doc 16's closure).
- `H2` blank-row sharing -- rejected in `D4` on sizing; nothing blank-related
  composes in.
- `H5`, a compressed ancient tier -- gated on `D10`. Less obviously dead under C1
  than under C6, since retained footprint is ~4x larger; still not this plan's
  work, and `D8`'s caps mean it would buy footprint rather than depth.
- `H7`, viewport-adjacent reflow -- a doc 28 research entry, not implemented here.
- The scratch-reusing encoder -- declined by `D9`, because even its success leaves
  browsing over threshold.
- Renderer measurement, which belongs to doc 18.

## Accepted risks

- **AR1 -- an `inconclusive` browsing verdict is a pass, and is expected.**
  `D2`'s frozen rule has a 0.30-point dead zone; the escalation ladder is
  exhausted at `confirm` and re-running is shopping.
- **AR2 -- the saturated pool's mix is an artifact.** Its composition is real
  but its mix reflects which recordings repeat well. Mitigated by pricing per
  stimulus and by headlining the CRLF reference payload.
- **AR3 -- saturated replays restart a stimulus mid-state**, so the *sequence*
  of content is not one any session would produce, even though every measured
  row is a real row (`derivationMatchesCensus` reconstructed every census).

## Rejected ideas

- **RI1 -- a UTF-8 text form for the scalar payload (`C3`/`C4`).** Same bytes at
  0.903 UTF-8 bytes per cell, dearer than C6 was on the saturated pool (137.4
  against 121.5 B/row), and it makes a column read a scan from the start of the
  row. Rejected harder under C1 than under C6: C1 is chosen precisely for the read
  path, and the text form is the candidate with the worst one. Reopens only if
  depth content turns out mostly non-ASCII, which `F11` and `D6` both decline to
  headline for the reason `AR2` states -- and even then it would be a memory
  argument against a design whose memory is now the cheap side of the trade.
- **RI2 -- C6, the shipped fixed-stride/style-run/exception form.** *Not* rejected
  on pricing: `D6`'s arithmetic was reproduced to the byte and C6 remains ~4.1x
  cheaper per retained row than C1. Rejected on the measured verdict set (`D9`) --
  four `slower` of six, worst `retained-browse` at +19.83%, which `F17`'s
  read-path fix cut to **+3.27%** and no further, because what remains is the
  decode itself at ~3.8 ns/cell. The three admission-bound workloads
  (`scrollback-stream` +6.34%, `terminal-feed` +5.18%, `incremental-mixed` +4.22%)
  are `pack(_:)` at 9.2% of feed self time, a frame absent at the baseline.
  Reopening condition: a machine or workload where 2.5 MB of retained-history
  memory outranks ~3.8 ns per browsed cell, or an encoder and decoder that remove
  both costs -- the evidence to re-decide it is `F11`-`F18` and stays in the repo.
- **RI3 -- landing `H4`'s aggregate storage together with the representation.**
  Makes an expected `inconclusive` browsing result unattributable. Unchanged.
- **RI4 -- `C2`, a second 4-byte all-ASCII cell form.** Rejected by `D9` on design
  rather than price: it reintroduces a per-row variant and a branch on every read,
  to buy bytes this plan has just decided are the cheap side of the trade. One
  code path is the point of the pivot.
- **RI5 -- a 12-byte cell carrying `contentIdentity` inline.** The one
  simplification C1 invites, since it would leave admission a pure translate-copy
  with no scan of any kind. Priced by `F18`: **784.0 B/row** on the reference
  payload against 528.0, and 461.9 against 343.4 on the saturated pool. That is
  **+48% memory to remove one comparison per cell** from a pass that already
  visits every cell, and what it removes costs 8.0 B/row -- 1.9% of the payload --
  because `F12`'s contiguity holds. Reopens only if the measured single-run
  fraction collapses, at which point the identity side table costs 4 B/cell
  anyway and inlining it is free.

## Implementation discretion

- The exact bit allocation inside the 8-byte cell, subject to the two properties
  Phase 1 states: every Unicode scalar inline, and `StyleId` not narrowed.
- Whether the packed row is a value type in `TerminalCore` or a buffer with
  accessors, and where the seam sits relative to `GridRow`. The seam is inherited
  from C6 and does not move.
- How reflow inflates and repacks a retained row.
- Whether `F17`'s three streaming readers stay three or collapse. They are a
  read-path fix, not a C6 artifact: `forEachContentCell` and `forEachKind` still
  decode less than a whole row, and `TerminalRetainedRowReadPathTests` pins their
  agreement with the public row reader either way.
