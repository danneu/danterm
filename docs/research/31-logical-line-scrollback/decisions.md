# Decisions -- logical-line scrollback (doc 31)

Auditable decision log for
[31-logical-line-scrollback](README.md); the contract is
[../FORMAT.md](../FORMAT.md).

### D1 -- go/no-go for the logical-line store

- Status: **rule frozen 2026-08-04 at `de17e95`, before the F1 probe existed in
  the tree and before any comparison number was produced. Closed 2026-08-04:
  the verdict is `go`, and its scoping, evidence, risks and carried-forward
  conditions are in the final section below.** The rule is stated in full here -- instrument, comparison target,
  validity gates, thresholds and their derivations, and what the simplification
  inequality must show -- so that no threshold can be chosen after seeing a
  result.
- Evidence used (planned): F1 (read-path probe), F2 (counting pass), F3
  (admission probe), F4 (edge-case inventory -- specifically whether any edge
  case requires stored width, which rejects H4 and the premise). Evidence used
  (actual): all four, plus F5, the simplification-inequality accounting pass the
  rule owed at D1's close.
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
  B, which now owes only the simplification inequality: F2, F3 and F4 are all
  in, and F4 -- the one input that could have made D1 no-go regardless of F1 --
  did not fire the trigger** (see the three Part B sections below). *(Superseded
  by the close: F5 has since landed and D1 closed `go` on 2026-08-04. This
  section is preserved as the Part A record; the closing verdict is the final
  section of this entry.)*
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
  is a human decision. *(F2, F3, F4 and F5 have since landed; see the four Part
  B sections below. D1 has closed `go`, so the "no production storage change is
  licensed" clause above still stands -- the close licenses Phase 2's design
  work only -- while `28/H7`'s status as the fallback moves from "until D1
  closes" to "reopened only by a `slower` verdict on the paired ladder".)*

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

#### Part B, frozen rule for F3 (the admission probe)

**Frozen 2026-08-04 at `393dfce`, before the F3 probe existed in the tree and
before any admission number was produced.** F3 is a Part B input: it prices the
open-line append this design admits scrollback through, against the
per-display-row pack-and-append the design replaces.

**What F3 can and cannot decide.** `H3`'s own falsifier is a **paired-ladder
verdict** -- "a `slower` verdict on `terminal-feed` or `scrollback-stream`
against the store this design replaces" -- and only a real implementation
measured on the ladder can produce one. F3 is a microbenchmark, so like Part A
it converts a ladder threshold into a microbenchmark ratio through a *measured*
cost share and reports a **prediction**. Consequently **F3 cannot make D1 no-go
and cannot close it**: D1's two no-go triggers are Part A's browse threshold
(F1, spent) and F4's stored-width trigger (spent), and neither is F3's to move.
Its outcomes are confirm, neutral, or reject, and reject attaches a *named
condition* to Part B rather than a verdict.

**Instrument.** A standalone two-arm microbenchmark in
`lib/TerminalCore/Tests/TerminalCoreTests/`, release configuration, headless,
env-gated behind `DANTERM_LOGICAL_LINE_PROBE`, **in its own file so Part A's and
Part B's existing probe arms are not edited** (the practice F2 established). It
reuses this doc's existing harness -- `RetainedStimulus`, `buildStimulus`,
`interleavedRounds`, `median`, `percentile`, `loadAverageDescription` -- and
defines only the two admitters, which are new because F1's stores are
read-oriented and built whole rather than incrementally. Arms are interleaved
**ABBA within one process**, at **5 measured rounds + 2 warmup** per (content
class), statistic = **median over rounds of nanoseconds per admitted display
row**, min and max and the sample count reported alongside. Depth ~10,000
display rows at 179 columns, the same depth and geometry Part A froze.

**Comparison target -- today's production admission path, named.** The baseline
arm reproduces `Terminal.swift#appendToScrollback` exactly: for each `GridRow`
scrolling off, `Terminal.PackedRetainedRow.pack(_:)`
(`PackedRetainedRow.swift#pack`, which trims to canonical extent as it encodes),
then `ScrollbackBuffer.append`, then the two accumulations that call site
performs -- `Terminal.swift#scrollbackByteCost(of:)` into `scrollbackByteCount`
and `storedCellCount` into `scrollbackStoredCellCount`. `ScrollbackBuffer` and
`scrollbackByteCost` are `private` to `Terminal`, so the arm reproduces the
buffer's storage and append and the byte-cost arithmetic rather than calling
them; that substitution is F3's stated fidelity limit, exactly as it was F1's.

**Candidate -- the open-line rule, with F4's corrected semantics.** One
contiguous byte arena of the same record shape F1 and F2 use (8-byte header:
cell count, flags; then C1 cell words verbatim). Per admitted display row: append
the row's cells to the **open** record at the arena's write cursor, dropping
`.spacerHead` cells (F4 case 10 -- the store never holds a spacer); a row that is
not soft-wrapped **closes** the record, writing its header and pushing its offset
into the index. Header bits are set at admission from content in hand:
`hasWideCells` (F4 Observation 1 / `DD4`, per record, not per buffer) and
`forcedSplit` at the 65,536-cell cap (`DD3`). **Mutation is tail-only** (F4
Observation 5), which is what makes the append a write at the cursor rather than
an edit. Where the README's sketch and F4 disagree, F4 wins: cells are appended
per display row into an open line rather than a record being built per line, and
a record's display-row count at the admitting width is *counted* rather than
derived, because admission knows how many rows it consumed -- `ceil` and the
wide-cell scan are the *width-change* path (`F2`), not the admission path.

**Stimulus classes, all at ~10,000 admitted display rows and 179 columns.** All
four are fed through a real `Terminal`, so the rows both arms admit are rows the
engine actually produced.

1. `mix` -- Part A's calibrated class, reproducing `28/F23`'s measured content
   distribution. Verdict-bearing.
2. `full` -- Part A's full-width class (`28/F23`'s
   `bound/wide-full-width-saturation`): every display row 179 cells.
   Verdict-bearing.
3. `stream` -- **new here, and the class closest to `H3`'s named falsifier.**
   `28/F20` Observation 5 measured what `benchmark/scrollback-stream` actually
   retains: its producer writes `\n` through a real tty whose Darwin default
   `OPOST|ONLCR` turns it into CRLF, so every retained row is a **hard-ended row
   of ~59 dense stored cells with no soft wrap at all**. That is the *worst* case
   for the candidate's "fewer records" mechanism -- one record per display row,
   the same count the baseline creates -- and it is the shape of the workload
   whose threshold this rule's bound is derived from. Verdict-bearing.
4. `wide` -- CJK content, so records carry `wideHead`/`wideTail` cells and the
   engine inserts `.spacerHead` at a one-column gap. **Descriptive only and
   outside the verdict**, because the bound below is derived from
   `scrollback-stream`, an ASCII CRLF workload, and `F4` has already recorded
   that this design's wide-content costs are unpriced. It is measured anyway so
   the gap is a number rather than a caveat.

**Forced wraps and hard newlines, stated per class rather than left implicit.**
A hard newline is one per logical line in every class; a forced (soft) wrap is
whatever the engine produced at 179 columns. The probe reports, per class,
display rows, logical lines, rows per logical line, the fraction of admitted rows
that are soft-wrapped, and the `.spacerHead` count -- because that fraction is
exactly the ratio of records to rows, which is the mechanism `H3` claims.

**Validity gates. Any failure voids the invocation, and a void invocation is not
a verdict and does not become one by re-running.**

1. **Cross-arm equivalence.** After admission -- outside every timed region --
   both stores are read back display row by display row and checksummed over
   every scalar, style id and kind, using Part A's walks. The two checksums and
   the two display-row counts must be identical. This is the gate that holds the
   candidate to re-deriving the spacers it dropped and the wraps it did not
   store; a difference means the arms did not admit the same content and no
   timing from that run may be quoted.
2. **Non-elision.** Each timed round's product is consumed and cross-checked
   against an expectation recomputed outside the timed region: the baseline's
   row count, charged byte total and stored-cell total; the candidate's record
   count, arena byte total and display-row total. A mismatch, or a zero, voids
   the run.
3. **Stimulus calibration.** `mix`: display-row stored-cell counts median in
   **[119, 154]** and p95 **179** (`28/F23`'s band, unchanged from Part A).
   `full`: median and p95 both **179**. `stream`: median stored cells in
   **[55, 65]** and soft-wrapped fraction **0** (`28/F20` Observation 5's
   measured shape). `wide`: at least **50%** of admitted rows contain a wide
   cell and at least one `.spacerHead` is present -- a failure here voids the
   `wide` observation only, since it carries no verdict. Out of band voids the
   run for that class, and the achieved distribution is reported either way.
4. **Instrument resolution (A/A control).** A baseline-vs-second-identical-
   baseline control runs in the same session at the same round count, for every
   class. Its |median difference| is the instrument's resolution, and **a
   candidate-vs-baseline difference smaller than it is reported as below
   resolution and read as an effect in neither direction.** An A/A control above
   **5%** voids the whole invocation, as in Part A.
5. **Host conditions**, as `28/F15` gated them and Parts A and B adopted: AC
   power, low-power mode off, one-minute load average below **2.5** read before
   and after.
6. **Coverage.** Every aggregate printed beside its sample count; a quantity
   that could not be measured is reported absent rather than as 0
   (`agent-docs/measurement-discipline.md`).

**Thresholds, and where each number comes from.**

- **Reject `H3`** -- candidate median **> 1.09x** baseline on any
  verdict-bearing class.
  *Derivation, all three inputs measured and none chosen here:* `28/F20`
  Observation 1 sampled `benchmark/scrollback-stream` and put the admission
  subtree (`appendToScrollback` / `pack` / `compacted` / `scrollbackByteCost` /
  `enforceScrollbackBudget`) at **19.7% of 15,578 `terminal-pty-host` thread
  samples**; `agent-docs/terminal-performance.md` states the drain is **95.7%**
  of a `scrollback-stream` block (median over 368 archived blocks); and
  `scrollback-stream`'s frozen `confirm` directional threshold is **1.85%**,
  read from `scripts/terminal-benchmark-validation.py#DECISION_RULES` rather
  than from a reconstruction of it. Admission is therefore
  `0.197 x 0.957 = 18.85%` of the block, and `1.85 / 18.85 = 9.81%` is the
  admission regression that first predicts a `slower` verdict -- so a candidate
  above **1.098x**, rounded down to **1.09x**, predicts `H3`'s own falsifier
  firing.
  *Why the pre-fix share and not the post-fix one:* `28/F20` Observation 2
  re-sampled the subtree at **15.9%** after the encoder fix that is in the tree
  today, which would give a looser 1.12x -- but that sample "ran at load 13.6 and
  is attribution only" by its own entry, while the 19.7% reading was taken under
  stated conditions. The larger share yields the tighter bound, and a tighter
  bound is the conservative choice for a probe whose failure mode is clearing a
  falsifier too easily.
  *Why no second bound from `terminal-feed`:* `H3` names it too, but **no
  finding in the corpus measures admission's share of `terminal-feed`** (`28/F17`
  measured 9.2% of feed self time for the *`C6`* encoder this design's baseline
  replaced, which is a different encoder). A bound cannot be derived from a share
  that was never measured, so none is, and F3's prediction is explicitly about
  `scrollback-stream` alone.
- **Confirm `H3`** -- candidate median **<= 1.00x** baseline on **every**
  verdict-bearing class, or a difference on that class smaller than the A/A
  resolution. *Derivation:* `H3`'s claim is literally "admission gets no worse",
  so parity or better is what confirms it; the resolution clause is gate 4
  applied, not a widening of the claim.
- **Neutral** -- every verdict-bearing class under 1.09x, and at least one class
  above 1.00x by more than the A/A resolution. `H3`'s "no worse" does not hold
  strictly, but no class predicts a `slower` verdict on the workload `H3` names.

**What each outcome means for `D1` Part B**, stated now so it is not decided
after the fact:

- **confirm** -- Part B's admission input is in and clean. `D1` then owes only
  the simplification inequality.
- **neutral** -- the same, plus one recorded cost: the measured admission
  regression is carried into Phase 2 as a number the paired ladder must re-read
  against a real implementation before any production storage change.
- **reject** -- Part B gains a **named condition**: `D1` may not close `go` on
  Part B until either an admission design clears this bound under **this same
  rule**, or a paired `confirm` on `scrollback-stream` against a real
  implementation comes back not-`slower`. Disposition is a human decision.
  `D1` does not become no-go on F3 alone.

**What F3 does not measure**, stated so the entry is not over-read: **eviction**
(today's `enforceScrollbackBudget` / `ScrollbackBuffer.removeFirst` against
`DD2`'s whole-record eviction, which is unspecified in cost and is Phase 2's, as
`F1` already recorded); the **parse and grid work** that precedes admission on a
real feed, so this is not `terminal-feed`'s or `scrollback-stream`'s block; the
**side tables** (`hyperlinkId`, `contentIdentity`), stripped from the stimulus so
neither arm builds them, exactly as Part A stripped them and for the same reason
-- the strip is conservative toward the baseline, because under the candidate an
identity run table would be built once per logical line instead of once per
display row; the **forced-split path** beyond its per-row bound check, since no
class reaches 65,536 cells; and **anything about read cost after admission**,
which is Part A's.

**Outcome, applied once to the frozen statistics.** [F3](findings.md) measured,
at ~10,000 admitted display rows and 179 columns, median over 5 ABBA rounds of
nanoseconds per admitted display row:

| class | verdict-bearing | baseline | candidate | ratio | A/A control | result |
| --- | :---: | ---: | ---: | ---: | ---: | --- |
| `mix` | yes | 623.1 ns | 389.1 ns | **0.624x** | +0.18% | confirm |
| `full` | yes | 642.4 ns | 444.0 ns | **0.691x** | +0.49% | confirm |
| `stream` | yes | 484.5 ns | 302.4 ns | **0.624x** | -0.15% | confirm |
| `wide` | no | 749.4 ns | 407.2 ns | 0.543x | -0.02% | observation only |

All six gates held on the first measured invocation and **no invocation was
voided**: cross-arm checksums and display-row counts identical on all four
classes (including the 5,124 `.spacerHead` cells the candidate refuses to store
and re-derives at read); every arm's per-round product matched the value computed
outside the timed region; `mix` calibrated at median 149 / p95 179 inside
`28/F23`'s band and `stream` at median 60 cells with a soft-wrapped fraction of
**0.000**, reproducing `28/F20` Observation 5's shape; A/A controls all under
0.5%; AC power, low-power mode off, load average 1.00 before and after.

Against the thresholds above: confirm required **<= 1.00x on every
verdict-bearing class**, and the worst is 0.691x; reject required **> 1.09x**,
which nothing approaches. **`H3` is confirmed outright** rather than landing in
the neutral band -- admission does not merely get no worse, it gets 1.45x-1.60x
cheaper per admitted row, *including* on `stream`, the class that reproduces the
row shape of the very workload `H3` names as its falsifier and where the
candidate creates exactly as many records as the baseline creates rows.

What this does **not** license, stated because the result invites over-reading:
F3 measures the encode-and-store term alone. `H3`'s own caution -- that `28/F20`'s
residuals may be scheduling rather than encoding -- is untouched by it, and the
conversion from a -37.6% admission change to roughly -7% on `scrollback-stream`'s
block is a prediction through `28/F20`'s share, not a measurement. Eviction is
not measured at all. Only the paired ladder against a real implementation
settles either.

**Part B therefore owes exactly one thing: the simplification inequality** -- the
frozen paragraph above titled "What the simplification inequality must show".
`F2`, `F3` and `F4` are all in, no measured input remains, and the remaining debt
is a reading and accounting pass rather than a measurement. `D1` does not close
on F3, Phase 2 does not open, `28/H7` remains the fallback, and no production
storage change is licensed. F3 also records two deferred decisions continuing
`F4`'s numbering: `DD5` (a record's display-row count is counted at admission,
not derived, so no wide-cell scan runs on the write path) and `DD6` (a forced
split leaves no back-pointer; readers rejoin by adjacency).

#### Part B, F5's outcome (the simplification inequality) and D1's close

Like `F4`, `F5` needs no frozen measurement rule because it produces no number.
The rule it is read against was frozen at `de17e95` in the paragraph above titled
"What the simplification inequality must show", and it has two clauses.

**Clause 1 -- the deletion list must actually contain six named items.** Applied
once to [F5](findings.md) Observation 1: all six are present in the tree at
`3fd09fd` and all six are genuinely removed.

| rule's item | present at | disposition |
| --- | --- | --- |
| history reflow mutation | `Terminal.swift:4288` `resizeWidth`, `:4575` `reconstructLogicalLines`, `:4713` `pack(line:columns:)`, `:3686`-`:3791` the attachment machinery, `:560`+`:599`-`:639` seven reflow-only types | history is never rebuilt; ~660 lines, of which ~70 move to read/admission rather than vanish |
| `productionScrollbackCellCap` | `Terminal.swift:784` + 21-line derivation + `scrollbackCellCap`/`scrollbackStoredCellCount` and their two maintenance sites | deleted -- its own doc comment says it bounds reflow's dominant term |
| `productionScrollbackRowCap` | `Terminal.swift:815` + 29-line derivation + `scrollbackRowCap` + the `while` clause at `:3989` | deleted -- `F4` case 28 shows the byte budget bounds the blank-row regime directly |
| the `28/D8` cost-model derivations and their tests | ~50 lines of doc comment; six of `TerminalScrollbackBudgetTests.swift`'s 21 tests; `TerminalHistoryDepthSizingProbe.swift` (294 lines) | deleted; `TerminalResizeProbe`/`Support` survives but loses its subject |
| narrow-then-widen eviction machinery | the cell cap's content-denomination (`:767`-`:770`), the row cap's documented lossy region (`:800`-`:806`), `narrowThenWidenPreservesCappedHistory`, `resizeWidth:4571`'s re-enforcement | deleted by construction: a width change does not touch the arena, so the lossiness question is unrepresentable |
| continuation-flag bookkeeping in retained history | `PackedRetainedRow.swift:101`/`:149` (one bit per **display row**), the three tail mutations at `Terminal.swift:6369`/`:6387`/`:6436`, `isHistoryHeadTruncated`, `.continuation` stamping at `:4731`/`:4746` | reduced to one open/closed bit per **logical line**; two mutations become header-bit flips, the third disappears (`F4` Observation 5) |

**Clause 2 -- the addition list must be pure, unit-testable, and free of any
width-dependent persisted state.** Applied once to `F5` Observation 6: all three
hold. Every addition is a function of bytes in hand (no clock, no id, no IO --
`lib/TerminalCore` takes none of those); the probes already demonstrate the test
shape, and it is a strong one (read both stores back row by row and checksum
every scalar, style id and kind -- `F3` gate 1 is what holds the candidate to
re-deriving the 5,124 spacers it refuses to store); and nothing width-shaped is
written into a record. The one width-dependent quantity, the block index's cached
totals, is a cache -- recomputable from the arena alone, cross-checked as such by
`F2` gate 1, and discarded rather than migrated at a width change. `F5` records
that reading as `DD7` rather than asserting it silently, because the stricter
reading would have made `D1` no-go the moment the index was sketched at
`de17e95`.

**The magnitude reading, conceded rather than buried.** The README states the
same gate as "the deletion list must exceed the addition list". On lines of code
that is close to a wash: ~720 net lines deleted against a ~350-400 line prototype
that has no spill table, no side tables, no eviction and no search, so a
production version is plainly larger. `F5` declines to rest the verdict there and
records the choice as `DD8`. What carries the inequality is invariants: **five
cross-cutting contracts deleted** (history is always at the current width; a
narrow-then-widen cycle must not evict; the per-display-row continuation flag
stays truthful under three tail edits; ten anchors survive a destructive rebuild;
three bounds whichever binds first) **against three and a half local ones added**
(one open record at the tail; cached block totals valid or discarded; no record
exceeds 1/32 of the budget and readers rejoin by adjacency; `hasWideCells` set
iff a wide cell is present, where being wrong the safe way is still correct). The
deleted contracts span the store and every reader; the added ones live inside the
store, enforceable by one writer and testable by one gate. Two deletions are
stronger than upheld invariants -- `F4` case 18's "two hard-ended lines must not
join when widening" becomes unrepresentable, and a width change that does not
touch storage has nothing to evict.

**The inequality holds.** Both clauses of the frozen rule are satisfied and the
magnitude clause is satisfied on the unit `DD8` selects.

#### Verdict (D1, closed 2026-08-04)

- Status of the verdict: **closed. Part A answered `go` on the read path
  (`F1`); Part B is now complete -- `F2` confirmed `H2`, `F4` confirmed `H4` and
  did not fire the stored-width no-go trigger, `F3` confirmed `H3` outright, and
  `F5` finds the simplification inequality holds.** No frozen threshold in this
  entry was failed by any input.
- Selected direction: **go.** Phase 2 opens as a **design** phase.
- Exact scoping, because a result this favourable invites over-reading:
  1. **`go` licenses Phase 2's design work and nothing else.** No production
     storage change is licensed by this verdict. Every Phase 1 number is a
     microbenchmark, and the README's first acceptance dimension gives the
     verdict to the paired benchmark ladder: `retained-browse` is the go/no-go
     and `terminal-feed` / `scrollback-stream` carry `H3`'s named falsifier.
     Those verdicts are still owed, against a real implementation, under rules
     frozen before the comparisons are read.
  2. **The three microbenchmark wins are predictions at the frame, not
     measurements of it.** `F1`'s 0.608x/0.610x browse converts to roughly -2% on
     `retained-browse` through `28/F17`'s ~5.2% share; `F3`'s 0.624x-0.691x
     admission converts to roughly -7% on `scrollback-stream`'s block through
     `28/F20`'s 19.7% share. Both conversions are labelled predictions in their
     own entries and stay predictions here.
  3. **`H3`'s own caution survives.** `28/F20`'s residual may be scheduling
     rather than encoding (`28/H8`); this store does not address scheduling, and
     `F3` could not see it.
  4. **Milestone 1 only** for the eager index recompute (`F2`), and the
     forced-split cap is derived rather than measured (`DD3`).
- Evidence used: `F1` (read path), `F2` (counting pass), `F3` (admission), `F4`
  (edge-case inventory), `F5` (the simplification inequality). Four measured
  inputs and one accounting pass; no measured input remains outstanding at
  Phase 1's scope.
- Behavioral verification: `F1` Observation 2 (derived display-row count matches
  the engine's for all 10,773 logical lines, no width-dependent state stored);
  `F3` gate 1 (both stores read back row by row with identical checksums and
  display-row counts on all four classes, including 5,124 spacers the candidate
  refuses to store and re-derives at read); `F2` gate 1 (every counting pass's
  total cross-checked against an independently computed sum, and responding
  correctly to width); `F4` Observation 2 (28 edge cases, zero requiring stored
  width).
- Quantitative verification: the three tables above -- `F1`'s read path,
  `F2`'s counting pass, `F3`'s admission -- each measured under a rule frozen
  before its probe existed in the tree, with every validity gate held on the
  quoted invocation and every voided invocation recorded rather than dropped.
- Tradeoffs and correctness risks:
  - **Eviction is unpriced on both sides** and is the largest unmeasured term in
    Phase 1's evidence. `DD2`'s whole-record eviction additionally needs the
    block index's head to move with it, which nobody has designed.
  - **One new failure mode with no analogue today: a stale block index.** Today
    the store *is* at the width; the design trades that eagerly-maintained truth
    for a derived cache with four trigger points (width change, admission,
    head eviction, forced split). `DD7` explains why it is still not
    width-dependent persisted state; it remains the one addition that can grow.
  - **The addition list is sized from a prototype**, missing spills (~0.12% of
    real rows, `28/F11`), hyperlink and content-identity side tables, semantic
    marks beyond a header slot, search and eviction. The addition side carries
    the larger error bar, which is why every carried-forward condition below is
    on that side.
  - **The wrapping rule is not deleted, it moves** to read time (`F5`
    Observation 2). The read path must reproduce `pack`'s spacer, continuation
    and soft-wrap semantics exactly; `F3`'s cross-arm checksum is the model for
    the test that proves it.
- Decision and rationale: the design was funded to answer one question -- can
  history be stored unwrapped and wrapped at read without regressing the read
  path -- and the answer is not merely yes but faster, on the read path
  (0.608x/0.610x), on random seek (0.898x/0.803x), on admission
  (0.624x/0.691x/0.624x), and in footprint (0.744x-0.925x of what the budget
  charges today). The counting pass the design deletes reflow *into* costs
  0.016 ms at the depth `28/F23` priced at 600.5 ms of reflow. The one input that
  could have killed the premise regardless of any timing -- an edge case
  requiring stored width -- was swept across seven reference trees plus DanTerm's
  own reflow path and ~40 resize/wrap tests, and does not exist. And the
  simplification the README made a co-equal acceptance dimension is real, on the
  unit that matters: five engine-spanning contracts deleted against three and a
  half store-local ones added.
- Direction review: **`28/H7` (the hybrid) stays in Rejected and is no longer the
  fallback for `D1`'s purposes.** Its reopening condition becomes a Phase 2
  failure -- a `slower` verdict on the paired ladder against a real
  implementation -- rather than a `D1` no-go. The disposition of Phase 2, and
  whether to fund it now, remains a human decision.

**Conditions and unpriced terms Phase 2 inherits.** Listed here rather than left
in the findings, because a verdict that carries conditions must carry them where
the verdict is read.

1. **The wide-record counting fallback is unpriced** (`F4` Observation 1 and
   Uncertainty; `F2`'s stimuli were ASCII, so every record took the O(1) `ceil`
   path). Re-run `F2`'s probe against a wide stimulus. `H2` cleared its bound by
   15.6x, but that margin was not measured on wide content and must not be
   quoted as though it were.
2. **Eviction is unmeasured on both sides** (`F1`, `F3`, and the README's open
   question): today's `Terminal.swift:3978` `enforceScrollbackBudget` /
   `ScrollbackBuffer.removeFirst` against `DD2`'s whole-record eviction, plus
   the index-head invariant whole-record eviction adds. A real pane at steady
   state evicts on every admitted row, so `F3`'s admission win is measured on
   the half of the write path that was easy to isolate.
3. **The paired ladder is owed.** `retained-browse` (the README's go/no-go),
   `terminal-feed` and `scrollback-stream` (`H3`'s named falsifier), against a
   real implementation, under rules frozen before the comparisons are read. The
   arc baseline for the descriptive wide reading is pinned at `de17e95`, and
   that reading is accounting only, never a verdict.
4. **`28/D11`'s trial bounds.** The caps this design deletes are currently
   shipped as a dogfood trial whose verdict (human: keep the caps, the hitch is
   livable) is recorded in conversation but not yet as a doc 28 decision
   amendment. Phase 2's budget task must state what happens to them during
   migration.
5. **The block index's four trigger points** -- width change, admission
   increment (`DD5`), head eviction, forced split -- must be enumerated and each
   given a behavioral test. This is the design's one new invalidation
   discipline (`F5` Observation 3).
6. **The display-row-indexed call-site enumeration** (Phase 2's first ledger
   task). The invariant that dies is "history is always at the current width",
   and `28/H7`'s entry already names it.
7. **Budget and eviction semantics** (Phase 2's second ledger task): arena size
   as the byte budget, what "keep N logical lines" means as a user-facing knob,
   and `F3` Observation 4's 0.744x-0.925x footprint ratio as the input.
8. **The forced-split cap is derived, not measured** (`DD3`). No pathological
   input -- `cat` of a binary, minified JSON -- has been fed to a real engine to
   see what a session actually produces, and no probe class reaches 65,536
   cells.
9. **The record format must carry what every probe stripped**: the spill table
   (`F1`'s arm calls `fatalError` on a multi-scalar cell; `28/F11` measures
   spills in ~0.12% of rows), `hyperlinkId` and `contentIdentity` side tables
   (the strip was conservative toward the baseline, so the candidate's identity
   run table -- one per logical line rather than one per display row -- is an
   unbuilt advantage, not a free one), and semantic marks beyond a header slot.
10. **The read path must reproduce `pack`'s fold exactly** -- `.spacerHead` at a
    one-column gap, `isSoftWrapped` marking, `.continuation` stamping -- because
    the fold moves to read time rather than being deleted (`F5` Observation 2).
11. **`DD1`-`DD8` are a human's to revisit.** `DD7` in particular: the stricter
    reading of "width-dependent persisted state" would reopen `D1`.

### D2 -- budget and eviction semantics: one charged-byte bound at the same 16 MiB, eviction display-row granular at the head, and no line-count knob

- Status: **decided 2026-08-04.** This is Phase 2's second ledger task and it
  discharges inherited conditions 4 and 7, ratifies `DD3`, amends `DD2`, and
  advances 2, 5, 8, 9 and 10. It is a **design** decision: `D1`'s scoping is
  unchanged, no production storage change is licensed by it, and the paired
  ladder is still owed. No measurement was taken for this entry -- every number
  below is either quoted from a prior finding or is arithmetic over quoted
  numbers, and each is labelled as one or the other.
- Date and investigator: 2026-08-04, Claude (agent).
- Evidence used: `F3` Observation 4 (the arena's measured footprint against what
  the budget charges today -- the input `D1`'s closure names for this task),
  `F3` Observation 2 (the stimuli's mean stored cells per row, which is what
  converts a footprint into a depth), `F4` Observation 3 (the forced-split
  derivation, offered for ratification here), `F4` case 27 and case 28 (eviction
  granularity, and the blank-row regime the row cap exists for), `F6` `HR4`
  (the tail truncation), `HR5` (what whole-record eviction costs in four anchors
  and the scrollbar), `HR8` (the grand display-row total), `X13` (the six
  per-row charge sites and the side-table question), `28/F23` Observations 1-3
  (charged bytes per row, and which bound binds), `28/D8` (why there are three
  bounds at all), `28/D11` (the trial bounds and their three exits), `15/F4`
  (the eviction leak whose proof `DD11` restates), `F2` (the counting pass,
  which is the only term that scales with record count).
- Candidate solutions considered: (a) keep three bounds, re-denominated;
  (b) **one charged-byte bound** with whole-record eviction (`DD2` as written);
  (c) one charged-byte bound with head-granular eviction (`DD2`'s recorded
  alternative); (d) a byte bound plus a user-facing "keep N lines" knob.

#### Frozen inputs, stated before the decisions that read them

Four facts this entry is built on, each with its provenance, so a reader can
tell what was measured from what was reasoned.

1. **Measured (`F3` Observation 4).** At ~10,000 admitted display rows and 179
   columns the arena holds the same content in **0.744x-0.925x** of the bytes
   today's budget charges: `mix` 9,982,856 B against 11,154,016; `full`
   14,360,104 against 15,520,000; `stream` 4,880,000 against 6,560,000; `wide`
   10,805,592 against 12,077,312. Records: 5,758 / 5,013 / 10,000 / 4,877.
2. **Measured (`F3` Observation 2).** Mean stored cells per display row: `mix`
   124.2, `full` 179.0, `stream` 60.0, `wide` 135.1.
3. **In the tree today.** `Terminal.swift:761 productionScrollbackBudgetBytes`
   is **16,777,216** (16 MiB), not the 10 MiB this doc's `README.md` trigger
   section quotes from `28/F23`. `28/D11` raised it, *because the caps needed
   it*: 89,500 rows x 1,552 charged B/row is 14.80 MiB and 10 MiB stopped a
   full-width fill at 6,756 rows.
4. **Correction, derived here from 1-3 (arithmetic, not measured).** The
   README's "the byte budget binds nothing today" is a `28/D8`-era fact measured
   at `D8`'s caps and a 10 MiB budget (peak 3.38 MB of 10 MiB). At `28/D11`'s
   bounds it is no longer true: a class retains
   `min(cellCap / cellsPerRow, rowCap, budget / chargedBytesPerRow)` rows, which
   for `F3`'s four classes gives

   | class | cells/row | cell cap gives | row cap gives | byte budget gives | binds today |
   | --- | ---: | ---: | ---: | ---: | --- |
   | `mix` | 124.2 | 14,412 | 89,500 | 15,041 | cell |
   | `full` | 179.0 | 10,000 | 89,500 | 10,810 | cell |
   | `stream` | 60.0 | 29,833 | 89,500 | 25,575 | **byte** |
   | `wide` | 135.1 | 13,249 | 89,500 | 13,894 | cell |

   So the budget already binds for short-line content, and `D11`'s cell cap
   binds for everything else at exactly the depth it was sized to buy. The
   README's trigger bullet is corrected in place to point here.

#### Decision 1 -- the byte budget is the arena, the number stays 16 MiB, and it is re-derived rather than inherited

**The bound.** One bound, and it is charged bytes:

    arenaBytesInUse + indexBytes + sideTableBytes  <=  scrollbackBudgetBytes

`28/D8`'s cell cap and row cap are deleted (`F6` `X6`, `X7`), because both exist
only to bound the two terms of a reflow this design does not perform. What
replaces "whichever of three binds first" is not a fourth bound but the
observation that the surviving one is **denominated in the thing it protects**:
the budget bounds memory, and memory is the only resource retained history still
consumes proportionally.

**The arena is the budget, allocated once.** The arena's capacity *is*
`scrollbackBudgetBytes`. It is allocated once at pane construction and never
grown, never compacted and never shrunk; the write cursor wraps and the head
advances, so at steady state the store performs no allocation at all. Two
alternatives rejected with reasons rather than left implicit:

- *Grow geometrically to the budget.* Rejected: a doubling policy leaves up to
  one growth step of resident slack that no charge model can see, which is the
  exact shape of the error `15/F4` found (a charge that describes a model rather
  than an allocation was wrong by 2.2x once already).
- *Linear arena with `memmove` compaction.* Rejected: it puts a copy of up to
  16 MiB on the admission path, and every stored offset has to be rebased.
  `15/F4`'s leak was born in a compaction threshold
  (`storageStart >= 1_024 && storageStart * 2 >= storage.count`); this design
  does not need one and should not acquire one.

Because the arena is written from the front and touched page by page, resident
memory follows first touch rather than capacity, and a pane that never fills its
history never pays for the region it reserved. The census must therefore report
**capacity and bytes-in-use separately** -- that reporting requirement is what
`DD11`'s restatement of `15/F4`'s leak proof becomes concrete against.

**The headline property, which today's store does not have.** Total resident
retained-history bytes are bounded by the budget *by construction*: in-use plus
metadata is the bound, and capacity is the same number. Today's budget is a
model of allocations checked against reality by a second model
(`Terminal.swift:2307 recomputedScrollbackByteCount`); under the arena the
arena's share of that identity is the distance between two pointers.

**What is charged, answering `X13` and inherited condition 9.** Everything
retained history allocates, and the side tables are **inside** the budget rather
than beside it:

| term | charge | note |
| --- | --- | --- |
| record header + cells | exact bytes written | an identity, not a model |
| block index | 8 B per record, at the deque's *capacity* | doc 15's `D4` rule: charge what the allocator gave, not what was asked for |
| per-block cached totals | ~1/256 of a record's index cost | amortized; not modelled separately |
| spill table (`28/F11`: ~0.12% of rows) | its allocation, as today | the record format still owes its shape (condition 9) |
| `hyperlinkId` / `contentIdentity` side tables | their allocations, at capacity | one table per *record* now, not per display row (`HR7`) |

Charging the index per record is not bookkeeping: it is what bounds the
degenerate regime `productionScrollbackRowCap` exists for. A blank logical line
costs 8 arena bytes and 8 index bytes, so 16 MiB admits **1,048,576** blank
records (derived). Without the index charge it would admit 2,097,152 and the
index would silently double the store's footprint.

**The number: 16 MiB, unchanged, and re-derived.** `28/D11`'s derivation
(89,500 rows x 1,552 charged B/row) dies with the caps that produced it, so the
number needs its own basis or it is inherited by accident. The basis is the same
human-chosen depth target `D11` encoded -- **10,000 display rows of full-width
179-column content** -- priced in arena terms from frozen input 1: 14,360,104
arena bytes + 40,104 index bytes = **13.74 MiB measured**, and the next power of
two is 16,777,216. The negative check: 10 MiB holds 7,281 rows of that class,
below the depth the human has been dogfooding under `D11`, so reverting the
budget to 10 MiB would be a user-visible loss taken at migration.

**What the same 16 MiB buys, per content class** (derived from frozen inputs 1
and 2; both columns exclude spills and the two side tables, which `F3` stripped
from both arms, so the ratio is like-for-like and the absolute depths are
upper bounds):

| class | binds today | depth today | depth on the arena | change |
| --- | --- | ---: | ---: | ---: |
| `mix` (real-corpus distribution) | cell cap | 14,412 | **16,728** | 1.16x |
| `full` (179-column saturation) | cell cap | 10,000 | **11,650** | 1.17x |
| `stream` (CRLF short lines) | byte budget | 25,575 | **33,825** | 1.32x |
| `wide` (CJK) | cell cap | 13,249 | **15,472** | 1.17x |
| blank lines (degenerate) | row cap | 89,500 | **1,048,576** | 11.7x |

**No content class loses depth at migration, and no default changes.** That is
the migration property worth having: the store changes, the constant does not,
and every measured class gets 1.16x-1.32x deeper for free because the arena
spends fewer bytes on the same content.

#### Decision 2 -- eviction is byte-driven, display-row granular at the head, and never copies

`DD2`'s whole-record eviction is **amended** (see the amendment note below).
`HR5` is the reason: a whole-record step drops up to 367 display rows at 179
columns and 32,768 at the 2-column minimum, which is user-visible in four
anchors and the scrollbar, and `F4` case 27 priced only its memory consequence.
`DD2`'s own recorded alternative is taken now rather than later, exactly as
`F6`'s next action recommends.

**The eviction step.** While the charge exceeds the budget:

1. Fold the head record from its current head cell offset at the **current
   width** and take the cell offset that begins its next display row.
2. If that offset reaches the record's end, drop the whole record: free its
   header and cells, remove its index entry, and advance the head to the next
   record.
3. Otherwise **trim the head record's prefix**: advance the arena head past
   those cells and rewrite the record's 8-byte header immediately before the new
   head, with its cell count reduced, its semantic-mark slot cleared, and a
   header bit marking it a mid-line continuation (Decision 5). The header write
   always fits, because a display row is at least one cell and a cell is 8 bytes.
4. Update, in the same step: the head record's index offset, the head block's
   cached display-row total, the grand display-row total (`HR8`), the cached
   browsing-anchor display row (`HR1`), `evictedRowCount`, and the charge.

**Termination measure is display rows, not bytes.** A trim of a one-cell display
row frees 8 bytes and spends 8 on the rewritten header, so a step can free
nothing; every step nonetheless drops at least one display row and history is
finite, so the loop terminates. Stating the measure explicitly is what keeps
that from being a latent hang.

**Nothing is copied and nothing moves.** Eviction advances a pointer and
rewrites at most one header. This is the second and last place the writer
touches the arena outside the tail, which narrows `F4` Observation 5's
"mutation is tail-only" premise to its true form: **the middle is immutable; the
head record's header and the tail record are the only writable bytes.**

**Ring reuse, and the one wart.** The write cursor wraps to the front of the
region when it reaches the end. A record must stay contiguous -- that contiguity
is the whole of `F1`'s measured 1.64x -- so a record that would straddle the
wrap point is preceded by a **pad record**: a header with a pad flag and a byte
length, which the head skips like any other record and which is charged like any
other bytes. The waste is bounded by one record, i.e. 1/32 of the arena by
`DD3`, and in practice by one line. Splitting a record across the seam was
rejected (every reader would have to handle two segments), as was copying the
record down (a copy on the admission path).

**The reader-facing contract does not change.** Because eviction stays
display-row granular, `Terminal.swift:3873 handleEviction` keeps its shape and
its semantics: it takes the count of display rows dropped, drops the selection
when it is entirely evicted and clamps its start forward otherwise, releases the
search occurrence and the hovered and armed links whose start precedes the new
first retained row, and clamps the browsing anchor. **No anchor moves further
per admitted row than it does today**, so `HR5`'s user-visible hazard is closed
rather than accepted, and the scrollbar's per-eviction jump is unchanged.

**`HR4`'s tail truncation is part of this mechanism, not a separate one.** The
arena has exactly five mutating operations, and this entry owns the list:

| # | operation | direction | effect on the arena |
| ---: | --- | --- | --- |
| 1 | admit a scrolled-off row (open-line append, `F3`) | back, grows | write cells at the cursor; per-block and grand totals += rows |
| 2 | close / reopen the tail record (hard newline; `severScrollbackWrapClaim`, `restoreWrapClaimBeforeCursor`) | back, neutral | one header bit |
| 3 | evict at the head (this decision) | front, shrinks | advance head; at most one header rewritten |
| 4 | **truncate the tail** (`resizeHeight` grow, `Terminal.swift:4256`-`:4278`) | back, shrinks | fold the tail record at the current width, cut at the cell offset beginning the k-th-from-last display row, hand the suffix to the live grid, rewind the write cursor, rewrite the tail header and reopen it, decrement both totals by k and the charge by the cells freed; if the cut consumes the whole record, drop it and its index entry -- the new tail record is closed by construction, because a record boundary is a hard newline |
| 5 | clear all history (ED 3, reset) | both | head = tail; `evictedRowCount` += the grand total; index emptied |

Operations 3, 4 and 5 are the only ones that shrink the arena, and 4 is the only
one that shrinks it from the back. Operation 4 does not touch
`evictedRowCount` and moves no anchor: the rows keep their absolute stream
positions and merely change which side of the history/live seam they sit on.

**The invariant that replaces `isHistoryHeadTruncated`** (`DD10` deletes the
public flag; the fact it asserted still has to be true of something):

> `evictedRowCount` counts display rows dropped at the width in force when they
> were dropped and only ever increases; the oldest retained record is a
> **suffix** of the logical line that produced it whenever its head has been
> trimmed, and it reads as a mid-line continuation for as long as it survives.

That is testable without a public property -- it is a statement about what the
fold emits at the top of history -- which is why `DD10` still stands.

#### Decision 3 -- "keep N logical lines" ships as nothing: no user-facing knob, and if one is ever added its unit is bytes or lines, never display rows

DanTerm exposes **no scrollback configuration at all** today: the three bounds
are `static let` constants and the public initializer enforcing them is itself a
pinned invariant. So the question is not "what does the existing knob become"
but "does this design's cheapness justify inventing one", and the answer is no
for milestone 1:

- A record-count bound would restore the "three bounds, whichever binds first"
  invariant that `F5` Observation 5 counts among the five deleted ones. Adding
  it back to spend a cheapness is the trade this doc exists to refuse.
- **"N lines" does not mean what a user thinks it means under this store.** Every
  mainstream terminal's `scrollback_lines` counts *display rows* (`kitty` 2,000,
  `tmux` 2,000, `alacritty` 10,000, `foot` 1,000, `xterm` 1,024). A logical line
  can be 367 display rows, so "keep 10,000 logical lines" and "keep 10,000 lines
  of scrollback" differ by up to two orders of magnitude on the same content.
- **A display-row knob is the one denomination that is actually unsafe.** The
  index maintains a grand display-row total, so `while grandTotal > N: evict` is
  enforceable in O(1) per step -- and it would be *lossy under narrowing* in
  precisely the way `28/D8`'s row cap is (`narrowThenWidenPreservesCappedHistory`
  is the pinned failure), because narrowing multiplies display rows while leaving
  content alone. That reintroduces `F5` invariant 2 -- "a narrow-then-widen cycle
  must not evict" -- which this design otherwise makes *unrepresentable*. Any
  future knob must therefore be denominated in **bytes** (the honest unit: it is
  what the store spends) or, if lines are demanded, in **logical lines** (a
  content property, safe under a width change).

**What is enforceable, recorded so the option is not lost.** "Keep at most N
logical lines" is one extra comparison in the eviction loop (`recordCount > N`)
and needs no new state, because the index knows its record count. It is left
unbuilt, not unavailable, and it is the fallback the open question below names.

#### Decision 4 -- what happens to `28/D11`'s trial bounds at migration

`28/D11` shipped three bounds as a dogfood trial with an explicit exit
condition -- "this entry is provisional by construction and expires when the
human picks exit 1, 2, or 3". Two of the three bounds are deleted by this design
and the third survives unchanged, so the migration's obligation is to the
*trial*, not to the numbers.

| `28/D11` bound | value | disposition at migration |
| --- | ---: | --- |
| `productionScrollbackCellCap` | 1,790,000 | **deleted, no analogue.** It bounds reflow's dominant term (`0.352 us x cells`); there is no reflow of history to bound |
| `productionScrollbackRowCap` | 89,500 | **deleted, no analogue.** It bounds reflow's row term and the blank-row regime; the row term is gone and the blank-row regime is bounded by the index charge (Decision 1) |
| `productionScrollbackBudgetBytes` | 16,777,216 | **kept at the same number, on a new derivation** (Decision 1). `D11`'s derivation is deleted with the caps that produced it |

**What the migration owes the trial's human verdict.** `D11` gave the human three
exits and the recorded verdict is exit 1 (keep the caps; the ~600 ms hitch is
livable), held in conversation and never written back as a doc 28 amendment.
This design does not get to take that decision by deleting its subject. Two
things follow, and this entry states both rather than assuming either:

1. **The trial keeps running unchanged until the store lands.** Nothing here
   edits a constant. `D11`'s reopening condition is its own verdict, and a
   migration that silently deletes the caps would retire a live trial by side
   effect.
2. **The migration creates a fourth exit, and doc 28 has to record it.** Exit 4
   -- *the cause is removed*: a width change stops touching history, so the
   question "is a 600 ms reflow livable at this depth" becomes unrepresentable
   rather than answered. The honest close is a doc 28 amendment that records the
   human's exit-1 verdict **and** notes that the successor removed the cost the
   verdict accepted, with the resize measurement re-taken against the new store.
   Until that amendment exists, `D11` is an open trial and this doc's
   implementation must not be read as closing it.

The depth the human has been dogfooding is preserved: 10,000 display rows of
full-width content becomes 11,650 (Decision 1's table), so exit 1's subjective
verdict is not being reversed by a depth cut smuggled in with the store change.

#### Decision 5 -- the head-trim's read semantics, and what this decision adds

Trimming the head record's prefix (Decision 2) leaves a record whose first cell
is not a line start, which the fold has to say something about. The choice, and
it is chosen to *reproduce today's output* rather than for convenience:

- The trimmed head record carries one header bit meaning **"this record starts
  mid-line"**. Its first display row is stamped `.continuation` exactly as
  today's retained rows are when the head is cut inside a logical line, which is
  what `isHistoryHeadTruncated` described.
- Its **semantic-mark slot is cleared**, because the mark referred to a line
  start that no longer exists.
- The bit is a content property, width-independent, set by the one writer, and
  reachable only on the head record. It does not reopen `D1`'s stored-width
  trigger, and `DD7`'s reading is untouched.

**The addition-side accounting, stated because `F5`'s inequality is a live gate.**
This entry adds three things to the addition list: a head cell offset plus the
head re-head (one write site, one 8-byte header), one header bit, and the
per-record index charge. It deletes two of the three bounds, their two
derivations, their five maintenance sites and the "whichever binds first"
invariant. The inequality is not close on this entry.

#### Scoped out of this decision, deliberately

Named so a later reader can tell a gap from a silence:

- **Exact record, header and index layout** -- Phase 3's, for the plan file.
  This entry fixes what is *charged* and what each operation must *update*, not
  how the bytes are arranged.
- **`HR1`, `HR2`, `HR4`'s fold arithmetic and `HR6`** -- the four design
  decisions `F6` hands to the graduation task. Decision 2 states what operation
  4 must update; it does not choose the anchor coordinate space (`HR2`) or the
  `topRow` caching strategy (`HR1`).
- **`HR3`** -- the severed-wrap BCE cell is a user-visible divergence for a
  human to dispose of, and it is not a budget or eviction question.
- **Whether the arena's capacity should ever shrink for an idle pane** --
  `DD12`, taken as "no" for milestone 1.

- Behavioral verification owed (none of it written by this entry; it is the test
  list the implementation inherits, and every item is behavioral rather than
  structure-coupled):
  1. Feeding past the budget leaves total charged bytes at or under the budget,
     for each of `F3`'s four content classes and for a blank-line history.
  2. Eviction drops display rows one at a time under a pathological head record:
     admit a record spanning many display rows, evict, and assert the browsing
     anchor and the selection move by the same amount they move on ordinary
     content. This is `HR5`'s regression test and it fails under `DD2` as
     originally written.
  3. A trimmed head record's first display row reads as a continuation and
     carries no semantic mark; the fold output is otherwise identical to the
     untrimmed record's tail. (`F3` gate 1's cross-arm checksum is the model.)
  4. `resizeHeight` grow with the cursor on the last row pulls the right rows
     back, and the grand display-row total, the per-block total and the charge
     all agree with a recount afterwards.
  5. A narrow-then-widen cycle evicts nothing, at any width down to 2 columns --
     the property `28/D8`'s row cap could not hold and this design makes
     unrepresentable.
  6. `15/F4`'s leak proof in arena terms (`DD11`): bytes-in-use falls when
     records are evicted, and capacity does not grow.
- Quantitative verification: none, and none is claimed. Every figure here is
  quoted from `F3`, `F2`, `28/F23` or the tree, or is arithmetic over them; the
  arithmetic is labelled derived at each use.
- Tradeoffs and correctness risks:
  - **The blank-line regime grows 11.7x in record count** (89,500 -> 1,048,576).
    Bytes are bounded, but record count is the input to `F2`'s eager counting
    pass, and `F2` measured only to 100,000 lines. See the open question below;
    this is the one place where a decision here could be wrong in a way a user
    feels, and the fallback (a record-count bound) is one comparison away.
  - **Eviction is still unmeasured** (inherited condition 2). This entry
    specifies the mechanism so it *can* be measured; it does not measure it, and
    the head-trim adds a fold walk per eviction step that today's `removeFirst`
    does not pay.
  - **The pad record wastes up to one record's bytes** at each wrap of the ring.
    Bounded by `DD3` at 1/32 of the arena, typically one line, and charged.
  - **Charging the index per record makes the depth content-dependent in a
    second way.** Short lines now pay 8 bytes of index against ~500 bytes of
    content; the effect is under 2% for every measured class and 50% only in the
    degenerate blank-line case, which is the case the charge exists for.
  - **First-touch residency is an assumption about the allocator**, not a
    measurement. If the arena is allocated in a way that touches every page, an
    empty pane costs 16 MiB resident instead of nearly nothing. That is an
    implementation constraint this entry states, and the census test above is
    what would catch a violation.
- Decision and rationale: the design was funded to make the byte budget the only
  bound, and this entry takes that literally -- one charged-byte bound, at the
  same 16 MiB constant, re-derived from the arena's own measured footprint so
  the number survives losing the derivation that produced it. Every measured
  content class gets deeper at the same number, so migration costs the user no
  scrollback. The one place the simple choice was refused is eviction
  granularity: `DD2`'s whole-record step is simpler to implement and would have
  been a silent user-visible regression in four anchors and the scrollbar, so
  `DD2`'s own recorded alternative is adopted now, at the cost of one header bit
  and one extra write site into the arena. And the knob the ledger asked about
  is not built, because the honest unit for it (display rows) is the one
  denomination that would reintroduce the narrow-then-widen lossiness this
  design otherwise makes unrepresentable.
- Direction review: this entry changes no constant, no code and no default. It
  is a specification the graduation task consumes. `28/D11` remains a live trial
  until doc 28 records its exit.
- Reopening conditions:
  1. The blank-line counting-pass probe (open question below) measures the eager
     pass above one frame at 1,048,576 records -- then Decision 3's record-count
     bound ships as an internal safety bound, sized to keep the pass under a
     frame, and Decision 1's "one bound" becomes two.
  2. A measured eviction regression against today's
     `enforceScrollbackBudget` / `removeFirst` under a rule frozen before the
     comparison is read -- then the head-trim's fold walk is the first suspect
     and whole-record eviction (`DD2` as written) is the fallback, with `HR5`
     accepted as a behavior change.
  3. The budget's number moves -- then `DD3`'s forced-split cap moves with it by
     construction, since the cap is stated as a fraction of the budget.
  4. A human decision to expose scrollback configuration at all, which makes
     Decision 3's unit question live rather than hypothetical.

#### Ratifications, amendments and new deferred decisions

- **`DD3` is ratified.** `F4` Observation 3 offered "no record exceeds 1/32 of
  the byte budget" as a derivation to be ratified in Phase 2. Decision 1 keeps
  the budget at 16,777,216, so the cap stays **65,536 cells** (524,288 B) and the
  rule -- not the number -- is what is adopted: the cap moves if the budget does.
- **`DD2` is amended, not overturned.** Its recorded form ("eviction evicts
  whole records") is superseded by Decision 2's head-granular eviction, which is
  `DD2`'s own recorded alternative ("advancing a head offset inside the first
  record so eviction stays display-row granular ... not needed for milestone 1").
  `F6` `HR5` is the evidence that changed the answer: the granularity is
  user-visible in four anchors and the scrollbar, which `F4` case 27 did not see
  because it priced only the memory consequence. The amendment is noted at
  `DD2` in [findings.md](findings.md) rather than rewriting it.
- **`DD10` stands.** `isHistoryHeadTruncated` is still deleted; Decision 2's
  invariant plus Decision 5's header bit carry what it asserted, without a public
  property.
- **`DD11` is made concrete.** The census reports arena capacity and
  bytes-in-use separately, and the leak proof becomes "bytes-in-use falls when
  records are evicted, and capacity does not grow" -- which a fixed-capacity
  arena makes trivially checkable.
- **DD12 -- the arena is allocated once at the budget's size and never grows or
  shrinks.** An idle pane keeps its reservation. The alternative, releasing the
  region when history empties, buys back address space that costs nothing and
  adds a state transition to the one data structure the whole design leans on.
  Reopen if a real session's pane count makes the reservation visible in RSS.
- **DD13 -- a trimmed head record reads as a mid-line continuation and loses its
  semantic mark** (Decision 5). The alternative -- folding it as a fresh line
  start -- is one bit cheaper and diverges from today's output, which inherited
  condition 10 exists to prevent.
- **DD14 -- a record that would straddle the ring's wrap point is preceded by a
  pad record.** The alternatives are splitting the record (every reader handles
  two segments, and `F1`'s win is contiguity) or copying it down (a copy on the
  admission path). The pad wastes bounded bytes and is charged.

#### Conditions discharged and advanced

Against `D1`'s eleven carried-forward conditions:

- **Discharged: 7** (budget and eviction semantics -- the task itself) and
  **4** (`28/D11`'s trial bounds during migration; the disposition is stated,
  and the doc 28 amendment it names is doc 28's to write).
- **Advanced: 2** (eviction's mechanism is now specified precisely enough to
  measure, and the probe is named below; the measurement is still owed),
  **5** (the index's trigger points are now six -- width change, admission, head
  eviction, tail truncation, forced split, clear-all -- each riding the cached
  browsing-anchor row from `HR1`), **8** (`DD3` ratified against a budget that
  is now derived rather than inherited; still unmeasured against a real
  pathological input), **9** (the side tables are charged inside the budget;
  their format is still owed), and **10** (Decision 5 adds a second case where
  the fold must reproduce today's output, alongside `HR3`).
- **Untouched: 1, 3, 6, 11.**

#### One open question this entry could not decide without a measurement

**Does the eager counting pass survive the blank-line regime?** Decision 1
admits 1,048,576 blank records at 16 MiB (derived), against the 100,000 lines
`F2` measured. `F2`'s numbers are 0.015-0.016 ms at 10,000 lines and
0.545-0.641 ms at 100,000 -- so the per-line cost is roughly 1.6 ns at 10,000
and 6 ns at 100,000, which `F2` Observation 3 attributes to cache residency. A
linear extrapolation at the 100,000-line rate puts 1,048,576 records at ~6.4 ms;
if residency degrades further it is worse. `F2`'s own reject bound is one 60 Hz
frame (16.67 ms). **That is arithmetic, not a measurement, and it is inside the
bound by less than 3x.**

The probe, stated so it can be run without re-deriving it: re-run
`TerminalLogicalLineIndexProbe`'s eager recompute at 1,048,576 zero-cell records
under `F2`'s frozen rule -- same gates, same width changes, same statistic. The
decision rule, frozen here before the number exists: **at or above 16.67 ms,
Decision 3's record-count bound ships as an internal safety bound** sized to keep
the pass under a frame at the measured per-record rate; **under 16.67 ms**, the
one-bound design stands as decided. This is deliberately not run here -- this is
a design task -- and it does not block the graduation task, because both
outcomes are one comparison in one loop.
