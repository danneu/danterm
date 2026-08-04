# Packed retained rows (doc 28 / H3)

## Status -- GATE FAILED; read path profiled and fixed, admission still open

Chunk A landed the packing at `efa549f`. `PO1`-`PO5` are green and the memory
claim held to the byte: **128.0 B/row** on the CRLF reference payload, **81,920**
retained rows at 10 MiB, exactly `D6`'s figure.

Chunk B ran gate item 6 first, because it was the likeliest failure, and it
failed at **14.2x** (`F14`, `D7`). `D8` took the cap exit and fixed it: `F15`
found the pre-packing byte budget had been bounding stored *cells* implicitly at
`10 MiB / 32 B`, so `D8` restates that bound explicitly (**327,680 cells**)
beside a **16,384-row** cap derived from the fitted two-term reflow model. A row
cap alone was measured unsound -- wide content stayed at 2.66x and a
narrow-then-widen round trip destroyed half the history (8,192 -> 4,095). With
both bounds, all three content regimes resize within **1.19x** of pre-packing.

The full deciding ladder then ran at the capped HEAD and **failed** (`F16`):
four `slower` verdicts of six, worst **`retained-browse` at +19.83% against a
1.05% threshold**. Neither cap binds on that workload, so the cost is the packed
row's read -- `C6`'s own named falsification, on the constant factor `PO5` never
bounded. Memory is unambiguously won: 69 B/row and 1.27 MB live heap at 179x66,
1.12x deeper than pre-packing at roughly an eighth of the bytes.

`F17` then profiled that read. The suspected cause -- per-cell point reads
defeating `PO5`'s linear walk -- was **wrong**: the planner already took the
linear walk. What it did was materialize a whole row twice per frame, once for
`geometry` (which needs only kinds) and once for `forEachViewportCell` (which
needs only scalars and a style), where the pre-packing form returned its stored
array by reference. Three readers now get three walks, landing at `2ae37c4`:
browsing **+19.83% -> +3.27%**, and `geometry` now costs *less* than at the
baseline.

`H3` still does not graduate. Browsing misses its 1.05% threshold by 3x on a
residual that is the decode itself (~3.8 ns/cell, no localized fix visible), and
the three admission-bound workloads are unmoved because their cost is
`pack(_:)` -- 9.2% of feed self time, a frame absent at the baseline and not
attempted here, since an encoder rewrite is a shape change rather than a wiring
one.

Its disposition is **open**, and returns to the human at a much smaller size:
revert, the `C1`/`C2` pivot, or a stated trade -- now against +3.27%, with a
scratch-reusing encoder (`F18`) as the one unexplored admission lead. This block
records the failure, not a verdict.

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
required metadata, so that selection was a standing candidate. `PR1` corrected the
accounting and re-selected: `F12`/`D6` keep **C6**, and keep it under *both*
`contentIdentity` variants, so the selection never depended on how that
adjudication came out. The yield did, and is restated below.

This plan is therefore two phases with a hard boundary. **Phase 0 was
evidence-only** -- no engine code -- and closed when the corrected pricing and the
selected representation were recorded in `D6`. **Phase 1 implements the selected
representation**, and may begin.

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

Written against C6, which `D6` confirmed as the selection.

A retained row stores three things:

- **A per-row fixed-stride scalar column** -- one slot per stored cell, at a
  stride chosen *per row* from the widest single scalar that row holds: 1 byte
  below U+0100, 2 bytes below U+10000, 4 bytes otherwise. A zero slot encodes a
  never-written cell, so interior padding costs one slot rather than a
  descriptor.
- **A run-length style table** over the stored prefix, keyed by the engine's
  existing interned style ids. Style interning itself does not change.
- **A short exception list** for what a slot cannot hold: wide-cell geometry,
  multi-scalar cells (whose scalars stay in the spill allocation the budget
  already charges), hyperlink cells, and any other retained cell field the scalar
  column and style table do not carry. Entry width is **per kind, not a uniform
  3 bytes**: a column plus a kind tag covers wide-cell geometry, but a
  multi-scalar entry must carry its spill reference and a hyperlink entry must
  carry the `HyperlinkId` that resolves its target. `PR1` fixes the encoding.
- **A `contentIdentity` encoding**: per contiguous run (`D6`), with a per-cell
  fallback for a row whose run table would outgrow its cells. It is not droppable
  (`I3`).
- **The two row-level `GridRow` fields, carried whole**: `isSoftWrapped` and
  `semanticPrompt`. Neither is derivable from cells -- `isSoftWrapped` is what
  width reflow uses to rejoin a wrapped line out of history, and
  `semanticPrompt` is what OSC 133 prompt navigation anchors on -- so a packed
  row that lost either would change observable content after a resize or break
  prompt jumps, while passing every cell-wise check. PO3 pins both.

**Why this shape and not the two obvious alternatives** -- both were priced, and
the reasoning is what the plan must preserve:

- **Not a UTF-8 text form** (`C3`/`C4`), though it is the obvious shape and
  kitty's precedent. At 0.903 UTF-8 bytes per stored cell the text form buys
  nothing in bytes -- on the saturated pool it is *dearer*, because it pays a
  descriptor byte on every cell to make a variable-width payload navigable while
  C6 pays only on the 0.86% of cells that are exceptions. What it costs on top is
  decisive: **reaching a column's scalar becomes a scan from the start of the
  row**, where C6's is a multiply. Both forms then pay a bounded metadata lookup
  (`I5`), so the difference is the O(row width) scalar decode, not the whole cell
  read. `retained-browse` is the guard `D3` named as most likely to fire.
- **Not a narrower cell** (`C1`/`C2`), though it is the smallest change. It
  leaves a style id on every cell, which 1.66 style runs per row says is
  redundant almost everywhere: 3.39x depth against C6's 8.86x, for a design
  simpler by roughly one table.

### Sequencing -- two separately measured steps

1. **C6 lands first and is measured alone**, against the full gate below.
2. **`H4` (aggregate storage for the packed payload) is a second, separately
   measured step.** Packing shrinks the payload ~14x while the fixed per-row
   cost does not move, so `F8`'s 89.5/10.5 split inverts to roughly **50/50**
   after C6 -- which is what earns `H4` the composition `D3` left it alive for,
   worth a further ~36%.

This ordering is a contract, not a preference: landing both at once makes an
`inconclusive` browsing result unattributable, and `D2` says to *expect*
`inconclusive` on that workload.

### Expected yield, priced against the CRLF reference payload

The headline figure is `F8`'s payload, `reference/scrollback-plain`, which is
**CRLF content**:

Priced on `D6`'s corrected accounting, which charges every field a retained row
must preserve. `D5`'s uncorrected figures are shown beside them because the plan
quoted them before `PR1` ran.

| quantity | now | C6 (`D6`) | C6 as `D5` had it |
| --- | ---: | ---: | ---: |
| charge per retained row | 1,808.0 B | **128.0 B** | 112.0 B |
| retained rows at 10 MiB | 5,799 | **81,920** | 93,622 |
| depth multiple | 1.00x | **14.12x** | 16.14x |

Identical at both 179x66 and 80x24 -- content-sized rows already made depth
width-independent, and `F11` re-measured that rather than assuming it.

A secondary mixed-content estimate across the saturated pool is
**1,076.9 -> 121.5 B/row (88.7%, 8.86x)**. It is secondary on purpose: `F11`
records that the pool's *mix* is an artifact of which recordings repeat well
(`alacritty/history` alone contributes 40,772 of 94,990 rows at 4.7 stored cells
per row).

**The floor these figures sit above.** `D6` charges `contentIdentity` per
contiguous run because `F12` measured 85.14% of retained rows at depth (100% of
the CRLF payload) as printed contiguously. On content that fragments, C6 pays the
per-cell floor instead: **336.0 B/row and 5.38x** on the reference payload,
238.4 B/row on the saturated pool. C6 is still the cheapest candidate there -- the
selection does not depend on the contiguity, only the yield does.

**Pricing honesty (`F11`'s staircase caveat).** `benchmark/scrollback-stream`
and `benchmark/unicode-wrapping` emit bare LF with no CR, so rows accumulate
leading padding: 66.4% and 39.8% of their stored cells hold no scalar, and their
mean rows are 134 and 129 cells against ~50 for CRLF content. That flatters any
gap-compressing scheme and is not what a real program writing through a PTY
produces (the tty driver's `ONLCR` adds the CR). **No expected-yield claim in
this plan may rest on those two stimuli.**

### Predicted feed effect, stated so the screening check is decidable

**Predicted: ~+1% slower, bounded at +2%.** Unchanged by `D6`: the corrected
encoding adds an identity-contiguity check to the same per-cell walk the
classification pass already makes, which does not change its order of magnitude.

Packing happens where trimming already happens -- at admission -- and adds one
classification pass over each admitted row's stored prefix (widest scalar, style
runs, exceptions, identity runs). That is
the same *kind* of work canonical trimming added, which `F1` bounded across four
schedules at a ~+1% point estimate and no more than ~2.5%. It is partially
offset by allocating and writing ~128 B where the current path allocates and
copies ~1,808 B.

**This prediction is under ~2%, so `D1` pitch 3's reopening condition fires.**
`scripts/terminal-benchmark-candidate-screen.py --workload terminal-feed` must
be screened on a longer schedule **before** the deciding run, not after an
ambiguous one. If a prototype measures the feed effect above ~2%, the screen is
unnecessary and `F1`'s wall is not load-bearing for this change.

## Invariants

- **I1 -- the live grid is untouched.** `GridCell` and the live grid's
  representation do not change. This is retained-only storage; doc 16's closure
  is an inherited boundary.
- **I2 -- canonical trimmed form holds.** A retained row's stored cells remain a
  pure function of its observable content.
- **I3 -- the observability contract holds.** Every column below `columnCount`
  reads as it did before, including cells reconstructed from a zero slot, a
  style run, or an exception entry.
- **I4 -- budget-charge coherence holds.** What the budget charges a row
  continues to describe what that row actually allocates.
- **I5 -- a random cell read never scans the row.** The scalar slot is O(1) by
  fixed stride. The applicable style run and any exception are found by binary
  search over column-ordered tables, so a random read is
  O(1) + O(log runs + log exceptions) -- not O(1) overall, which variable-length
  tables cannot give. Full-row iteration advances both cursors and stays linear
  in the row's stored width; it must never re-search per cell. This is still the
  property C6 is chosen for over the text form, whose scalar payload costs
  O(row width) to reach a column at all. A row with pathologically many style
  runs must not make a full-row read superlinear.

## Proof obligations

- **PO1 (I1)** -- the live-grid behavioral suite passes unchanged; no live-grid
  representation change is introduced.
- **PO2 (I2)** -- a retained row's stored extent is unchanged from the current
  canonical trim for the same written content, across blank, ragged, trailing-
  whitespace, and full-width rows.
- **PO3 (I3)** -- retained rows round-trip: content written, scrolled off, and
  read back matches cell-for-cell across the axes C6 encodes separately -- plain
  ASCII, non-ASCII at each stride tier, interior never-written gaps, styled runs,
  wide cells, multi-scalar cells, and hyperlink cells, including rows combining
  several of these. A row carrying the combined metadata case must survive all
  three paths, not just admission: **admission**, **width reflow**, and **height
  transfer back into the live grid**. Concretely, an OSC 8 cell that scrolls into
  history and returns still resolves its target, and a link armed across it is
  still adjudicated by whatever `PR1` decided about `contentIdentity`. Two
  further axes are row-shaped rather than cell-shaped: a soft-wrapped
  multi-row line survives admission plus width reflow rejoined (and a
  prompt-marked row read back from history keeps its `semanticPrompt` mark),
  and a fragmented-identity row -- assembled by cursor moves so its run table
  would outgrow its cells -- round-trips through the per-cell fallback with
  `activationIdentity` still adjudicating correctly over it.
- **PO4 (I4)** -- the retained-row probe's `derivationMatchesCensus` reconstructs
  the census exactly, which trips loudly if the derived shape stops describing
  the representation.
- **PO5 (I5)** -- a row-reader microbenchmark shows a random cell read is flat in
  the row's stored width and no worse than logarithmic in its run and exception
  counts, and that a full-row read of a many-style-run row stays linear rather
  than degrading to a quadratic walk. `retained-browse` validates the same
  contract on the real workload.
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
   count before and after at both widths, recorded in its own `D` entry. Per
   `D5` this is not expected to be a trade -- strictly more depth for strictly
   fewer bytes per row -- so that entry states the new depth rather than
   adjudicating a giveback. If it *is* a trade, it is decided as numbers before
   landing.
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
6. **Resize is now two-armed.** C6 changes what reflow unpacks and repacks on
   every retained row, which is exactly the "change expected to move resize
   cost" that `D1` pitch 2 named as the gate for upgrading `F7`'s committed
   probe. **That gating criterion is met, so this experiment converts the probe
   to a two-armed comparison -- and the comparison decides, it does not
   describe.** Reflow now runs over ~9x more retained rows, so a descriptive
   distribution is not an acceptable outcome: `F7`'s ~98 ms median becoming most
   of a second would pass every other gate here while breaking the responsiveness
   contract. This clears one of exactly two ways, both **before landing**:
   screen `saturated-resize` toward a frozen rule via the standard pipeline and
   clear it, or state the measured resize-for-depth trade as numbers and decide
   it in a `D` entry. Declining to make a resize claim is not a third way out.
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

## Risks, and what falsifies C6 early

Run these against a prototype before the full ladder, cheapest first. Each has a
stated threshold and a named consequence.

- **A row read whose metadata lookup dominates.** If reconstructing a cell from
  slot + style run + exception measurably costs more than a struct load -- `I5`'s
  logarithmic term swamping the O(1) one -- C6's whole advantage over the text
  form evaporates and the choice reopens toward `C1`/`C2`, which keep a real cell
  and give up 3.39x instead of 8.86x.
- **Rows carrying many style runs.** The selection rests on 1.66 runs per row.
  Above roughly **8 runs per mean row** at depth, the style table stops being
  nearly free and `C1`'s per-cell style id becomes competitive again.
  `just terminal-retained-row-probe "--saturated"` reports
  `meanStyleRunsPerRow` directly -- one command.
- **Rows that are mostly non-ASCII.** C6 promotes a whole row to a 2- or 4-byte
  stride for one wide scalar; `unicode-wrapping` already shows the failure mode
  (544.0 B/row against the text form's 343.4). If recorded content at depth
  showed most rows above U+00FF, the text form wins on bytes and the browse
  trade-off must be re-argued rather than assumed.
- **Retained rows whose `contentIdentity` is fragmented.** A row printed
  left-to-right is one run and costs a constant; a row assembled by cursor moves,
  overwrites, or insert-mode splits into many. If the measured single-run
  fraction at depth is low, C6 pays nearer `PR1`'s floor -- 4 bytes on every
  stored cell against a 1-byte modal scalar slot -- and the headline is restated
  rather than quoted. This is a `PR1` output, so it falsifies before Phase 1
  starts rather than during it.
- **A prototype feed cost above ~2%** -- then `F1`'s wall is not load-bearing
  and the longer screen is unnecessary; below it, the screen is mandatory.
- **Reflow at ~9x depth -- the largest blast radius, and what this evidence says
  least about.** `F7`'s ~98 ms median over 6,756 rows is the current arm, and
  depth is about to increase ~9x at the same budget. **A per-row-cheaper reflow
  over 9x more rows can easily be slower in total**, and that is the single most
  likely way this design produces a user-visible regression. Run
  `just terminal-resize-probe` against a prototype early rather than at the end;
  gate item 6 is what forces the result to be adjudicated rather than reported.

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
- `H5`, a compressed ancient tier -- gated on `D7`, and after an 8.86x depth
  improvement very likely dead on sizing.
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

`RI1` and `RI2` are rejections *relative to C6*, re-confirmed on `D6`'s corrected
pricing -- the metadata charge is a per-row constant that C3's larger payload
cannot amortize, so correcting it widened both margins rather than narrowing them.

- **RI1 -- a UTF-8 text form for the scalar payload.** Same bytes at 0.903 UTF-8
  bytes per cell, dearer on the saturated pool (137.4 against 121.5 B/row), and it
  makes a column read a scan. Reopens only if depth content turns out mostly
  non-ASCII -- which is the one pool where it does win, and which `F11` and `D6`
  both decline to headline for the reason `AR2` states.
- **RI2 -- a narrower fixed cell keeping a per-cell style id.** 1.66 style runs
  per row makes the per-cell field redundant; 3.39x against 8.86x.
- **RI3 -- landing `H4`'s aggregate storage together with C6.** Makes an
  expected `inconclusive` browsing result unattributable.

## Implementation discretion

- Whether the packed row is a value type in `TerminalCore` or a buffer with
  accessors, and where the seam sits relative to `GridRow`.
- How reflow inflates and repacks a retained row.
