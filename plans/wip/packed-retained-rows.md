# Packed retained rows (doc 28 / H3, representation C6)

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
  design admission test). C6 clears it at 100% of rows in the committed corpus.
- **Content composition at depth** (`F11`, 94,990 rows): 22.54% of stored cells
  styled but only **1.66 style runs per mean row**; 0.119% multi-scalar; 1.32%
  of scalars non-ASCII at **0.903 UTF-8 bytes per stored cell**; 0.37% carrying
  a hyperlink.
- **The feed path cannot resolve ~1%** (`F1`: four schedules agree +1.03% to
  +1.45%, inside the harness's dead zone).

Every number above is reproducible from committed probes at or after the
evidence floor `dd51a12`.

## Decision

Implement `D5`'s **C6** for retained rows only.

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
  already charges), and hyperlink cells.

**Why this shape and not the two obvious alternatives** -- both were priced, and
the reasoning is what the plan must preserve:

- **Not a UTF-8 text form** (`C3`/`C4`), though it is the obvious shape and
  kitty's precedent. At 0.903 UTF-8 bytes per stored cell the text form buys
  nothing in bytes -- on the saturated pool it is *dearer*, because it pays a
  descriptor byte on every cell to make a variable-width payload navigable while
  C6 pays only on the 0.86% of cells that are exceptions. What it costs on top is
  decisive: **a column read becomes a scan from the start of the row**, and
  `retained-browse` is the guard `D3` named as most likely to fire.
- **Not a narrower cell** (`C1`/`C2`), though it is the smallest change. It
  leaves a style id on every cell, which 1.66 style runs per row says is
  redundant almost everywhere: 3.54x depth against C6's 9.41x, for a design
  simpler by roughly one table.

### Sequencing -- two separately measured steps

1. **C6 lands first and is measured alone**, against the full gate below.
2. **`H4` (aggregate storage for the packed payload) is a second, separately
   measured step.** Packing shrinks the payload ~16x while the fixed per-row
   cost does not move, so `F8`'s 89.5/10.5 split inverts to roughly **50/50**
   after C6 -- which is what earns `H4` the composition `D3` left it alive for,
   worth a further ~36%.

This ordering is a contract, not a preference: landing both at once makes an
`inconclusive` browsing result unattributable, and `D2` says to *expect*
`inconclusive` on that workload.

### Expected yield, priced against the CRLF reference payload

The headline figure is `F8`'s payload, `reference/scrollback-plain`, which is
**CRLF content**:

| quantity | now | C6 |
| --- | ---: | ---: |
| charge per retained row | 1,808.0 B | **112.0 B** |
| retained rows at 10 MiB | 5,799 | **93,622** |
| depth multiple | 1.00x | **16.14x** |

Identical at both 179x66 and 80x24 -- content-sized rows already made depth
width-independent, and `F11` re-measured that rather than assuming it.

A secondary mixed-content estimate across the saturated pool is
**1,076.9 -> 114.5 B/row (89.4%, 9.41x)**, per-stimulus ranging from 65.7% to
93.8%. It is secondary on purpose: `F11` records that the pool's *mix* is an
artifact of which recordings repeat well (`alacritty/history` alone contributes
40,772 of 94,990 rows at 4.7 stored cells per row).

**Pricing honesty (`F11`'s staircase caveat).** `benchmark/scrollback-stream`
and `benchmark/unicode-wrapping` emit bare LF with no CR, so rows accumulate
leading padding: 66.4% and 39.8% of their stored cells hold no scalar, and their
mean rows are 134 and 129 cells against ~50 for CRLF content. That flatters any
gap-compressing scheme and is not what a real program writing through a PTY
produces (the tty driver's `ONLCR` adds the CR). **No expected-yield claim in
this plan may rest on those two stimuli.**

### Predicted feed effect, stated so the screening check is decidable

**Predicted: ~+1% slower, bounded at +2%.** Packing happens where trimming
already happens -- at admission -- and adds one classification pass over each
admitted row's stored prefix (widest scalar, style runs, exceptions). That is
the same *kind* of work canonical trimming added, which `F1` bounded across four
schedules at a ~+1% point estimate and no more than ~2.5%. It is partially
offset by allocating and writing ~112 B where the current path allocates and
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
- **I5 -- a column read is O(1) in the stored column index.** This is the
  property C6 is chosen for over the text form, and the reason the browsing
  guard is expected to pass. A row with pathologically many style runs must not
  turn a row read into a quadratic walk.

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
  several of these.
- **PO4 (I4)** -- the retained-row probe's `derivationMatchesCensus` reconstructs
  the census exactly, which trips loudly if the derived shape stops describing
  the representation.
- **PO5 (I5)** -- a row-reader microbenchmark shows reconstructing a cell from
  slot + style run + exception does not scale with the row's stored width, and a
  many-style-run row does not degrade a full-row read superlinearly.
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
   to a two-armed comparison.** If a resize claim is made, screening
   `saturated-resize` toward a frozen rule via the standard pipeline is a
   prerequisite task; if no claim is made, `just terminal-resize-probe` runs
   descriptively on both arms and is reported as a distribution, as `F7` did.
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

- **A row read that is not O(1) in practice.** If reconstructing a cell from
  slot + style run + exception measurably costs more than a struct load, C6's
  whole advantage over the text form evaporates and the choice reopens toward
  `C1`/`C2` -- which keep a real cell and give up 3.54x instead of 9.41x.
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
- **A prototype feed cost above ~2%** -- then `F1`'s wall is not load-bearing
  and the longer screen is unnecessary; below it, the screen is mandatory.
- **Reflow at ~9x depth -- the largest blast radius, and what this evidence says
  least about.** `F7`'s ~98 ms median over 6,756 rows is the current arm, and
  depth is about to increase ~9x at the same budget. **A per-row-cheaper reflow
  over 9x more rows can easily be slower in total**, and that is the single most
  likely way this design produces a user-visible regression. Run
  `just terminal-resize-probe` against a prototype early rather than at the end.

## Sequencing

TDD per `AGENTS.md`: for each proof obligation, write the failing test first,
verify it fails for the expected reason, then change the code and verify it
passes. The behavioral obligations (PO2, PO3) precede the representation change;
the probe and microbenchmark obligations (PO4, PO5) precede the falsification
checks; the measured-yield obligation (PO6) is the deciding run and comes last.

## Non-goals

- Changing the live grid's `GridCell` (doc 16's closure).
- `H2` blank-row sharing -- rejected in `D4` on sizing; nothing blank-related
  composes in.
- `H5`, a compressed ancient tier -- gated on `D6`, and after a 9.41x depth
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

- **RI1 -- a UTF-8 text form for the scalar payload.** Same bytes at 0.903 UTF-8
  bytes per cell, dearer on the saturated pool, and it makes a column read a
  scan. Reopens only if depth content turns out mostly non-ASCII.
- **RI2 -- a narrower fixed cell keeping a per-cell style id.** 1.66 style runs
  per row makes the per-cell field redundant; 3.54x against 9.41x.
- **RI3 -- landing `H4`'s aggregate storage together with C6.** Makes an
  expected `inconclusive` browsing result unattributable.

## Implementation discretion

- Whether the packed row is a value type in `TerminalCore` or a buffer with
  accessors, and where the seam sits relative to `GridRow`.
- How reflow inflates and repacks a retained row.
