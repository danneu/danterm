# Decisions -- logical-line scrollback (doc 31)

Auditable decision log for
[31-logical-line-scrollback](README.md); the contract is
[../FORMAT.md](../FORMAT.md).

### D1 -- go/no-go for the logical-line store

- Status: **rule frozen 2026-08-04 at `de17e95`, before the F1 probe existed in
  the tree and before any comparison number was produced.** Verdict pending
  below. The rule is stated in full here -- instrument, comparison target,
  validity gates, thresholds and their derivations, and what the simplification
  inequality must show -- so that no threshold can be chosen after seeing a
  result.
- Evidence used (planned): F1 (read-path probe), F2 (counting pass), F3
  (admission probe), F4 (edge-case inventory -- specifically whether any edge
  case requires stored width, which rejects H4 and the premise).
- Candidate solutions: go (open Phase 2 design), no-go (fall back to the
  hybrid recorded in Rejected / `28/H7`), or narrow-go (viable but with a
  named condition, e.g. a search index requirement discovered in F1).

#### The frozen rule

**Scope.** D1 has two parts. Part A is the read path and is decided by F1
alone, because H1 names `retained-browse` parity as the go/no-go and F1 is its
falsifier. Part B is everything else -- F2, F3, F4, and the simplification
inequality -- and D1 does not close until all of it is in. **F1 can therefore
produce a `no-go` outright (the premise dies), or a `go`/`narrow-go` *on the
read path* with Part B still owed.** No F1 result licenses a production
storage change; `28/H7` stays the fallback until D1 closes.

**Instrument (Part A).** A standalone two-arm microbenchmark in
`lib/TerminalCore/Tests/TerminalCoreTests/`, release configuration, headless,
gated behind an environment variable so it is not part of `just test`'s timed
gate. Arms are interleaved ABBA within one process at a round count frozen
here: **5 measured rounds per (content class, access pattern)**, statistic =
**median over rounds of nanoseconds per display-row read**, min and max
reported alongside. It reuses the `28/F23` harness's conventions (commit
`e5da63f`): a real `Terminal` at 179x66 supplies the stimulus, every aggregate
is printed with its sample count, and the probe reports distributions rather
than verdicts.

**Comparison target.** The current retained-row read path: an array of
`Terminal.PackedRetainedRow` values produced by `PackedRetainedRow.pack` from
the `GridRow`s a real `Terminal` retained after being fed the same stimulus at
179x66, addressed by the same O(1) display-row-index-to-row mapping
`ScrollbackBuffer`'s subscript performs, and read through the same
`forEachKind` + `forEachContentCell` readers the browse path uses (`28/F17`).
`ScrollbackBuffer` itself is `private` to `Terminal`; the arm reproduces its
element type, its readers and its index arithmetic rather than calling it, and
that substitution is a stated fidelity limit of F1, not a silent one.

**Candidate.** Contiguous byte arena of variable-length logical-line records
(header carrying cell count + flags, then C1-shaped 8-byte cells), plus the
derived block index: per-line record offsets, blocked at ~256 lines, one cached
display-row total per block at the current width; display-row lookup is a
binary search over block totals then an in-block scan. Nothing width-dependent
is stored.

**Stimulus classes, both at ~10,000 display rows and 179 columns.**

1. `mix` -- reproduces `28/F23`'s measured content distribution: display-row
   cell counts with **median in [119, 154] and p95 = 179**.
2. `full` -- full-width content: every display row 179 cells
   (`28/F23`'s `bound/wide-full-width-saturation` class).

**Access patterns.**

1. `sequential browse` -- the retained-browse pattern: one display-row index
   lookup per frame, then 66 consecutive display rows read forward, each read
   doing both walks (`forEachKind` for geometry, `forEachContentCell` for
   render), which is what `28/F17` left the frame path doing.
2. `random seek` -- a point read at a uniformly random display-row index:
   lookup plus the same two walks, one row per operation.

**Validity gates. Any failure voids the invocation, and a void invocation is
not a verdict and does not become one by re-running.**

1. **Cross-arm equivalence.** Both arms accumulate a checksum over every
   scalar, style id and kind they read. The checksums must be identical for
   every measured pattern. A difference means the arms are not reading the same
   content and no timing from that run may be quoted.
2. **Stimulus calibration.** The `mix` class's measured median and p95 must
   land in the band above. Out of band -> the probe reports the achieved
   distribution and the run is void for `mix`.
3. **Instrument resolution (A/A control).** A baseline-vs-second-identical-
   baseline control runs in the same session at the same round count, for every
   pattern. Its |median difference| is the instrument's resolution. **A
   candidate-vs-baseline difference smaller than the A/A resolution is reported
   as below resolution and is not read as an effect in either direction.** If
   the A/A control itself exceeds 5%, the instrument is too noisy and the whole
   invocation is void.
4. **Host conditions**, as `28/F15` gated them: AC power, low-power mode off,
   one-minute load average below 2.5 read before and after.
5. **Coverage.** Every aggregate is printed beside its sample count, and a
   quantity that could not be measured is reported absent rather than as 0
   (`agent-docs/measurement-discipline.md`).

**Thresholds, and where each number comes from.**

- `sequential browse`, **both** content classes: candidate median
  **<= 1.20x** baseline.
  *Derivation:* `28/F17` measured the two retained-row read walks at 302 + 205
  self samples of ~9,750 in `planFrame` -- **~5.2% of frame-planning time** --
  and that same decode delta read as +3.27% on `retained-browse`. At a 5.2%
  share, a 20% regression of the read walk is ~1.04% at the frame, which sits
  at `retained-browse`'s frozen 1.05% directional threshold
  (`agent-docs/terminal-performance.md`). A candidate above 1.20x therefore
  predicts a `slower` verdict on the workload H1 named as its falsifier.
- `random seek`, **both** content classes: candidate median **<= 3.0x**
  baseline **and** candidate absolute **<= 5.0 us** per point read.
  *Derivation:* random seek is not on the frame path, so a frame-share
  threshold does not apply to it; the latency budget is doc 21's. `21/F2`
  measured a `.character` drag-move at **92-101 us** deep, with roughly six
  projection reads per query plus its application (`21/F1`). A point read at
  <= 5.0 us keeps the whole read component under ~30 us -- a minority of the
  cost the indexed-read direction was funded to remove, rather than its new
  dominant term. The 3.0x ratio is the separate guard that a structurally O(1)
  lookup is not traded for a walk whose constant merely happens to be small at
  this depth.

**Verdicts (Part A), applied exactly once to the frozen statistics.**

- **no-go** -- `sequential browse` exceeds 1.20x on either content class. H1 is
  falsified, the premise of the design fails at the acceptance dimension the
  README makes primary, and `28/H7` (the hybrid) is the direction. Phase 2 does
  not open.
- **narrow-go** -- `sequential browse` passes on both classes, `random seek`
  fails either of its two bounds. Phase 2 may open only with the named
  condition that the index be refined (smaller blocks, or per-line display-row
  counts stored beside the offsets) and re-measured against **this same rule**
  before any production storage change. Disposition is a human decision.
- **go (read path)** -- both patterns pass on both classes. Part A is
  satisfied; D1 remains open on Part B.

**What the simplification inequality must show (Part B, at D1's close).** The
deletion list must actually contain: history reflow mutation,
`productionScrollbackCellCap`, `productionScrollbackRowCap`, the `28/D8`
cost-model derivations and their tests, narrow-then-widen eviction machinery,
and continuation-flag bookkeeping in retained history. The addition list --
arena, block-summed wrap index, open-line rule, forced-split rule -- must be
pure, unit-testable, and free of any width-dependent persisted state. **If F4
surfaces one edge case that genuinely requires storing wrap or width state,
D1 is no-go regardless of F1**, because that entry breaks the property every
other deletion on the list descends from.

#### Verdict

- Status of the verdict: **Part A answered 2026-08-04. D1 remains open on Part
  B, which now owes only F3 and the simplification inequality: F2 and F4 are
  both in, and F4 -- the one input that could have made D1 no-go regardless of
  F1 -- did not fire the trigger** (see "Part B, F4's outcome" below).
- Selected direction (Part A, the read path): **go**.
- Quantitative verification: [F1](findings.md), measured at `eee1832` plus the
  probe it adds. Median over 5 ABBA rounds of nanoseconds per display-row read,
  ~10,000 display rows, 179 columns.

  | pattern | class | baseline | candidate | ratio | rule | result |
  | --- | --- | ---: | ---: | ---: | --- | --- |
  | sequential browse | `mix` | 882.3 ns | 536.3 ns | **0.608x** | <= 1.20x | pass |
  | sequential browse | `full` | 1,270.4 ns | 774.7 ns | **0.610x** | <= 1.20x | pass |
  | random seek | `mix` | 915.3 ns | 822.3 ns | **0.898x**, 0.82 us | <= 3.0x and <= 5.0 us | pass |
  | random seek | `full` | 1,361.0 ns | 1,092.7 ns | **0.803x**, 1.09 us | <= 3.0x and <= 5.0 us | pass |

  All five validity gates held: cross-arm checksums identical on every measured
  pattern; `mix` calibrated at median 149 / p95 179, inside `28/F23`'s band;
  A/A controls -0.64% / +0.21% / -0.43% / -0.88%, so every difference above is
  an order of magnitude outside the instrument's resolution; AC power,
  low-power mode off, load average 1.48 before and 1.44 after. One earlier
  invocation was voided unread of its verdict for an A/A control of -6.91%, and
  F1 records it rather than dropping it.
- Behavioral verification: the candidate's derived display-row count matched
  the engine's for all 10,773 logical lines measured, at both content classes,
  with no width-dependent state stored (`F1` Observation 2).
- Tradeoffs and correctness risks: F1's largest fidelity limit is that the
  baseline arm reproduces `ScrollbackBuffer`'s three-line subscript rather than
  calling it (the type is `private`), and that neither arm carries hyperlink or
  content-identity side tables -- a strip that is conservative toward the
  baseline. The prototype has no admission, eviction, spill table, open-line
  rule or forced split, and F1 sees nothing about resize. Those are `F2`/`F3`'s
  and Phase 2's, not evidence this entry may borrow against.
- Decision and rationale: the read path clears the gate H1 expected it to
  struggle with, and clears it in the opposite direction -- wrap-at-read
  browsed **1.64x faster** than today's store on both content classes. H1's
  competing explanation (that the added indirection lands on `28/F17`'s path
  and gives back its win) is not merely unsupported; the deflationary reading
  of the win -- that it is ARC on today's per-read row copy rather than storage
  shape, and so recoverable without any redesign -- was measured directly and
  refuted (`F1` Observation 3). The surviving mechanism is layout: 10,000
  separately allocated row blobs against one contiguous region.

  What this does **not** license, stated because a result this favourable
  invites over-reading: F1 measures a read walk in isolation, not a frame. The
  1.20x threshold was derived by converting a read-walk change into a
  `retained-browse` frame change; the same conversion predicts roughly -2% at
  the frame, and only the paired ladder against a real implementation can
  confirm that.
- Direction review: **Part A only. Phase 2 does not open on this entry.** D1
  stays open pending F2 (the eager counting pass), F3 (admission), F4 (the
  edge-case inventory, whose stored-width finding can still make D1 no-go), and
  the simplification inequality above. No production storage change is licensed
  by this verdict, and `28/H7` remains the fallback until D1 closes. The
  disposition of Phase 1 -- whether to continue funding it on this evidence --
  is a human decision. *(F2 and F4 have since landed; see the two Part B
  sections below. F3 and the inequality remain owed and this review stands.)*

#### Part B, frozen rule for F2 (the eager counting pass)

**Frozen 2026-08-04 at `9b2f37a`, before the F2 probe existed in the tree and
before any counting-pass number was produced.** F2 is a Part B input: it prices
the eager block-total recompute the human chose for milestone 1, against H2's
bounds.

**What F2 can and cannot decide.** H2's reject condition reopens the *lazy
per-block recompute* recorded in Rejected; it does not falsify the logical-line
store. **F2 therefore cannot make D1 no-go.** Its outcomes are: eager confirmed
for milestone 1, eager confirmed with a recorded depth condition, or eager
rejected and the index-refresh strategy reopened -- the last of which changes
Phase 2's design, not D1's direction.

**Instrument.** A standalone probe in
`lib/TerminalCore/Tests/TerminalCoreTests/`, release configuration, headless,
env-gated, in its own file so Part A's probe bodies are not edited. **9 measured
rounds** per (content class, depth, count-source, width change), plus 2 warmup
rounds; statistic = **median over rounds of wall time for one whole pass**, min
and max and the round count reported alongside. There are no two arms to
interleave: F2 measures an absolute cost against a frozen bound, not a ratio.

**What is timed.** Exactly one call of the eager recompute: discard every cached
block total and rebuild `blockPrefix` for a new width by reading one cell count
per logical line and doing one divide. Nothing else -- no arena construction, no
allocation of the stimulus, no read walk.

**Two count-sources, because the sketch and the prototype disagree and the
difference is the whole cost.**

1. `arena` (**primary**): the count is read from each line's record header
   through `lineOffsets`, which is what the candidate direction describes -- the
   index holds offsets, the count lives in the record. This is a pointer chase
   over the whole arena.
2. `counts` (**alternative**): the count is read from a dense parallel array,
   which is what F1's prototype happens to do. This is a sequential scan of
   `8 x lineCount` bytes and buys its speed with 8 bytes per line of extra index
   state.

F2 reports both. If the primary clears H2 the alternative is unnecessary; if
only the alternative clears it, that is a priced design change for Phase 2, not
a free result to quote.

**Depths and classes.** 10,000 and 100,000 logical lines, at both `mix` and
`full` (the same two classes and the same generators D1 Part A froze), at 179
columns. `28/D11`'s trial depth is ~10,000 *display* rows, which these
generators reach in roughly 3,300-3,700 logical lines, so the 10,000-line figure
bounds the trial depth from above and is the figure the reject condition is read
against.

**Width changes.** `179 -> 100` (narrow; display-row count rises) and
`179 -> 200` (widen). The same-width recompute is recorded as a floor. All three
do identical work per line, so a large spread between them is itself a finding.

**Validity gates. Any failure voids the invocation, and a void invocation is not
a verdict and does not become one by re-running.**

1. **Non-elision.** Every timed pass's result is consumed, and the resulting
   total display-row count is cross-checked against an independently computed
   sum of `ceil(cells / width)` over the same lines. A mismatch, or a total of
   zero, voids the run. A counting pass is exactly the shape of loop an
   optimizer can delete, and a deleted loop reports a very good number.
2. **Synthetic-stimulus fidelity.** A 100,000-line arena of wide content cannot
   be built by feeding a real `Terminal` at this probe's cost, so it is built
   synthetically: the same generators supply the cell counts, headers are
   written, and cell payload bytes are allocated but not populated -- admissible
   only because the counting pass provably never reads a cell byte. **Control:**
   at 10,000 lines, both arenas are built -- the real-engine one through Part
   A's `buildStimulus`, and the synthetic one from the same cell counts -- and
   the pass is measured on each. Their medians must agree within **15%**. Wider
   than that, and the synthetic depth extension is void: F2 reports the
   10,000-line real figure only and records 100,000 as not measured.
3. **Host conditions**, as Part A gated them: AC power, low-power mode off,
   one-minute load average below 2.5 read before and after.
4. **Coverage.** Every aggregate is printed beside its sample count, and a
   quantity that could not be measured is reported absent rather than as 0.

**Thresholds, and where each number comes from.**

- **Confirm H2** -- median pass at **100,000 lines <= 10.0 ms**, on both content
  classes and both width changes, for the primary count-source.
  *Derivation:* this is H2's own bound, written into `README.md` at `de17e95`
  when the doc was opened and before any probe existed; F2 adopts it unchanged
  rather than restating it after seeing a number.
- **Reject H2, reopening lazy per-block recompute** -- median pass at
  **10,000 lines >= 16.67 ms**, one whole 60 Hz frame, on either class.
  *Derivation:* `28/D11`'s shipped trial depth is the depth a user runs at
  today, 10,000 logical lines bounds it from above (see Depths), and one frame
  is the project's standing unit for "this is now visible"
  (`28/F23`'s resize discussion reads 1.43 s as ~86 frames). A resize also has
  to refold the live screen; a counting pass that alone costs a frame is the
  dominant term rather than the rounding error H2 claims it is.
- **Narrow confirm** -- 100,000 lines exceeds 10.0 ms but 10,000 lines stays
  under **1.67 ms** (10% of a frame). *Derivation:* at a tenth of a frame the
  pass cannot be the term a user perceives at trial depth, so eager survives
  milestone 1; F2 then records the depth at which the 10 ms bound is crossed as
  a condition on growing the store's depth, and lazy stays available rather
  than adopted.

**What F2 does not measure**, stated so the entry is not over-read: the rest of
a resize (refolding the live screen, which this design does not remove), the
lookup cost after a recompute (Part A's `random seek`, already measured), the
cost of building or evicting from the arena (F3's), and anything about
correctness of wrapping at a width other than 179 beyond the cross-check in
gate 1.

**Outcome, applied once to the frozen statistics.** [F2](findings.md) measured
the primary count-source at **0.015-0.016 ms at 10,000 logical lines** and
**0.545-0.641 ms at 100,000**, on both classes and all three width changes, with
all four gates held (one earlier invocation was voided on the load gate and is
recorded in F2). Against the thresholds above: confirm required <= 10.0 ms at
100,000 and the worst cell is 0.641 ms; reject required >= 16.67 ms at 10,000
and the worst cell is 0.016 ms. **H2 is confirmed, eager recompute stands for
milestone 1, and lazy per-block recompute stays rejected.** Part B advances by
one input and D1's direction is unchanged, exactly as the scope note above said
it must be. The one design input F2 produces for Phase 2: the index stays
offsets-only, because the primary source clears the bound without a parallel
counts array.

#### Part B, F4's outcome (the edge-case inventory)

F4 needs no frozen measurement rule, because it produces no number: it is a
reading-and-cataloguing pass, and the rule it is read against was already frozen
at `de17e95` in the paragraph above titled "What the simplification inequality
must show". That paragraph states the only way F4 can move D1:

> **If F4 surfaces one edge case that genuinely requires storing wrap or width
> state, D1 is no-go regardless of F1.**

**Applied once to [F4](findings.md): the trigger does not fire.** 28 cases were
catalogued from seven pinned reference trees plus DanTerm's own reflow path
(`Terminal.swift#reconstructLogicalLines`, `Terminal.swift#pack`) and its
resize/wrap test suites. Every case is decidable as a pure function of (logical
line, current width) plus live-grid state. **No entry requires width-dependent
data persisted in history**, so `H4` is confirmed and the property every
deletion on D1's list descends from survives.

Two cases want a bit in the record header, and neither is a width:

- `hasWideCells` (case 2) -- a content property known free at admission, which
  selects the O(1) `ceil` path or an O(cells) scan for display-row counting. It
  is an optimization: always scanning would be correct, so the design does not
  depend on it even being stored.
- `forcedSplit` (case 26) -- the marker the candidate direction already
  sketched, so that copy and search rejoin a split line logically.

**What F4 changes, and what it does not.** It changes the *mechanism* stated in
`H1` and assumed by `F2`: display rows are `ceil((cells + spacers) / width)`, not
`ceil(cells / width)`, because a 2-cell cluster meeting a one-column gap starts
the next row rather than splitting. That is a change to a derivation, not to
what is stored, and so it is outside the frozen trigger's terms. It does not
change D1's direction, and it does not open Phase 2.

**One item is added to Part B's addition list**, which the simplification
inequality must carry when D1 closes: the fast/slow display-row count split
(header bit plus scan fallback). Against it, F4 removes work from the addition
side too -- the four `attachments` computations in `Terminal.swift#resizeWidth`
collapse into one address conversion, because a (logical line, offset) pair
becomes the stored address rather than a per-resize transient.

**One new condition on Phase 2, recorded here so it is not lost in the finding:**
`F2`'s 0.016 ms counting pass was measured on ASCII stimuli, where every record
took the `ceil` path. The wide-record scan is unpriced. `H2` cleared its bound by
15.6x, but that margin is not measured against a wide-content stimulus and must
not be quoted as though it were.

F4 also records four deferred decisions (`DD1`-`DD4`: selection is remapped
rather than cleared; eviction evicts whole records; the forced-split cap is
65,536 cells derived as 1/32 of the byte budget; the wide-cell bit is per record
rather than iTerm2's buffer-wide sticky flag). Each took the obvious, simple
choice and each is a human's to revisit.

**Part B therefore owes exactly two things: `F3` (the admission probe) and the
simplification inequality.** `28/H7` remains the fallback until D1 closes, and
no production storage change is licensed.
