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
  numbers, and each is labelled as one or the other. **The one open question it
  left is closed: [F7](findings.md) measured the blank-line counting pass on
  2026-08-04 under the rule frozen here, and the answer leaves every decision
  below unchanged.**
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

**Amended 2026-08-04 by the external design review of `DD12` and the plan's
`I2`; the paragraph above stands as written for *charged* bytes and is
overstated for *resident* ones.** Charged bytes -- arena bytes in use plus index
plus side tables -- are bounded by the budget by construction, and that is what
the census and the plan's `PO3` check. Resident bytes are a different quantity,
bounded by **capacity plus metadata**: the first-touch reading two paragraphs up
holds only until the ring's write cursor has cycled once, after which every arena
page has been touched and stays touched, and the index is a separate allocation
outside the arena. In the blank-record regime that is a 16 MiB arena plus ~8 MiB
of index resident against a 16 MiB charged bound -- **24 MiB, 1.5x the number
this entry reads as a residency bound**. Nothing else in this decision moves: the
charge model, the depth table, the two rejected allocation policies and the
capacity-versus-in-use census requirement are unchanged. What moves is the plan's
`AR6`, promoted from an accepted risk to a gate sequenced with the eviction
measurement, because cycling the ring is exactly what makes the two quantities
differ. Sizing the arena's capacity **below** the budget is the remedy if -- and
only if -- that reading shows the overshoot matters; it is not taken here,
because no page count has been measured.

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
| trailing fill style (`DD25` as amended) | its allocation, at capacity | added 2026-08-04; one slot per record that carries a background-erase tail, none for the rest |

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

**Amended 2026-08-04 by the external design review, in two steps of the list
above and in neither case by adding an operation.**

- **Step 2 drops a forced split's continuation on the floor.** Dropping a whole
  record is right only when the record is the whole of its logical line. When the
  dropped record carries `forcedSplit` (`DD3`, and `DD6`: the follower is the
  same logical line, rejoined by adjacency with no back-pointer), dropping it
  without stamping leaves the follower reading as a **fresh** logical line -- a
  divergence from today's `Terminal.swift:3999`
  `isHistoryHeadTruncated = lastEvictedIsSoftWrapped`, which is true exactly when
  the row now at the head continues the line above it, and which inherited
  condition 10 exists to prevent diverging from. Step 2 therefore reads: drop the
  record, and **if it carried `forcedSplit`, propagate the mid-line/continuation
  bit to the follower and clear the follower's semantic-mark slot** -- the same
  two edits step 3 makes for a trim, for the reason `DD13` gives. The follower's
  header sits at the new head, so the write is the head re-head Decision 5
  already pays for, and `DD20` below reaches the same follower from the admission
  side. The plan's `PO13` gains this case; its `PO5` covers trims only.
- **Step 4 cites a cache that no longer exists.** "the cached browsing-anchor
  display row (`HR1`)" was removed by [`D3`](decisions.md) Decision 1: the
  browsing anchor **is** an absolute display row, so eviction needs no anchor
  edit at all and `evictedRowCount` plus the subtraction absorb it. Read step 4
  as: the head record's index offset, the head block's cached display-row total,
  the grand display-row total (`HR8`), `evictedRowCount`, and the charge.

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

**Amended 2026-08-04 by [`D3`](decisions.md) in two rows, and in neither case
does the arena gain a sixth operation.** Operation 2 widens from "one header bit"
to "one header bit, plus at most one appended cell": `D3` Decision 3 measured
that severing a wrap claim under a non-default background-erase style stores a
styled blank today, and materializes it as a tail append. Operation 4 gains a
second trigger: a **width change** re-establishes the open tail record's
display-row boundary at the new width by pulling its partial row back into the
live refold (`D3` Decision 4), using this same cut-and-rewind mechanism.

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
    **Closed 2026-08-04 by [F7](findings.md): the pass costs 0.761 ms at
    1,048,576 records, 21.9x inside its own one-frame bound, and its per-record
    cost is flat from 10,000 records up. The fallback is not taken.**
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
  1. ~~The blank-line counting-pass probe (open question below) measures the
     eager pass above one frame at 1,048,576 records -- then Decision 3's
     record-count bound ships as an internal safety bound, sized to keep the pass
     under a frame, and Decision 1's "one bound" becomes two.~~ **Spent
     2026-08-04: [F7](findings.md) measured 0.761 ms, 21.9x inside the bound, so
     no record-count bound ships and Decision 1's one bound stands.**
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

  **Amended 2026-08-04 by the external design review.** A pad needs the record's
  length at the moment it is placed. That is true of a closed record and **false
  of the open tail**: admission opens the record and grows it one display row at
  a time (operation 1), so it can grow into the seam long after it was placed,
  with splitting, copying down and compacting all already rejected above. The
  pad rule stands for closed records; the open tail at the seam is `DD20`, and
  the plan's `PO12` -- which already tests an open tail growing across the seam --
  is the obligation that had no decision behind it until now.
- **DD20 (added 2026-08-04 by the external design review) -- the open tail record
  is forced-split at the arena's physical end, not reserved for.** When the next
  display row admission would append does not fit before the physical end: close
  the open record at its current end with the `forcedSplit` bit (`DD3`'s bit, at
  a second trigger), write a `DD14` pad over the sub-row remainder, open the
  continuation record at offset 0, and append the row there. Readers rejoin the
  pair by adjacency (`DD6`); a head eviction that drops the first piece is
  Decision 2 step 2's amendment. Two edges, stated so they are not discovered
  later: an **empty** open record needs no split -- the pad covers the remainder
  and the record is simply (re)opened at offset 0 with no bit set -- and the pad
  is omitted when the remainder is zero, which it can be, since every record and
  cell is an 8-byte multiple.

  **Three properties checked rather than assumed.** (i) The split point is the
  record's current end, which is a **display-row boundary at the admitting
  width**, because admission appends whole display rows and measures a
  soft-wrapped row to full width (`F4` case 17, `DD5`). So nothing is copied, and
  `D3` Decision 4 / `DD16`'s "the open tail ends on a display-row boundary" holds
  for the piece being closed and trivially for the empty one being opened.
  (ii) The arena gains **no sixth mutating operation**: closing a record, writing
  a pad and opening the next are what operation 1 already does at a cap-driven
  forced split, all at the write cursor, and the middle stays immutable.
  (iii) The waste is one sub-row remainder -- at most one display row's bytes,
  ~1.4 KB at 179 columns -- charged like any other pad.

  **The recorded alternative, and why it lost.** Reserve a `DD3` cap-sized span
  (1/32 of the arena, 524,288 B) whenever a record is opened that could straddle,
  so the record provably fits and `DD3`'s forced split fires on overflow. It is
  the tidier rule and it wastes no display row to raggedness -- but the
  reservation is **charged**, so a single admitted row would push up to 3.1% of
  the arena over the budget and evict that much in one step: ~360 display rows at
  `full`. That is exactly the per-admission anchor jump `HR5` found and Decision 2
  refused ("no anchor moves further per admitted row than it does today"), so the
  variant that buys tidiness reintroduces the hazard this entry closed. The split
  variant's extra eviction is the pad, i.e. under one display row.

  **What it costs, stated rather than buried.** A forced split ends a display row
  early (`D3` Decision 1, trigger 5), so at any width other than the admitting one
  the closed piece's final display row is short **in the middle of a logical
  line** -- the raggedness `DD16` refused at the history/live seam, accepted here
  at a record/record seam only because `DD3`'s cap already accepts it. What
  changes is frequency: from "no measured input reaches the cap" to **once per
  full wrap of the ring**, which at steady state leaves one such join (two
  transiently) alive in a full history. Reopen if that is judged user-visible, or
  if the cap's own raggedness is reconsidered; the reservation above is the
  fallback and pays in depth rather than in a display row.

#### Conditions discharged and advanced

Against `D1`'s eleven carried-forward conditions:

- **Discharged: 7** (budget and eviction semantics -- the task itself) and
  **4** (`28/D11`'s trial bounds during migration; the disposition is stated,
  and the doc 28 amendment it names is doc 28's to write).
- **Advanced: 2** (eviction's mechanism is now specified precisely enough to
  measure, and the probe is named below; the measurement is still owed),
  **5** (the index's trigger points are now six -- width change, admission, head
  eviction, tail truncation, forced split, clear-all -- each riding the cached
  browsing-anchor row from `HR1`; **amended by [`D3`](decisions.md) Decision 1,
  which discharges 5: the six stand, the maintained quantity is the grand
  display-row total, and there is no cached anchor row, because `D3` Decision 2
  keeps the browsing anchor an absolute display row**), **8** (`DD3` ratified against a budget that
  is now derived rather than inherited; still unmeasured against a real
  pathological input), **9** (the side tables are charged inside the budget;
  their format is still owed), and **10** (Decision 5 adds a second case where
  the fold must reproduce today's output, alongside `HR3`).
- **Untouched: 1, 3, 6, 11.**

#### One open question this entry could not decide without a measurement -- answered 2026-08-04 by [F7](findings.md)

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

**Applied once to [F7](findings.md), which measured it at `aec227c` plus the one
probe file it adds.** The primary `arena` count-source at 1,048,576 zero-cell
records reads **0.760-0.761 ms**, on all three width changes, with every gate
held and no invocation voided. Against the rule: at-or-above required 16.67 ms
and the worst cell is 0.761 ms, **21.9x inside**. **Under 16.67 ms, so no
record-count bound ships and Decision 1's one charged-byte bound stands as
decided.** Decision 3's "keep at most N logical lines" comparison stays
*available and unbuilt*, which is where Decision 3 put it, and **reopening
condition 1 below is spent.**

Two things `F7` changes about the reasoning above rather than about the
decision. First, the ~6.4 ms extrapolation was **8.4x pessimistic**, and the
ladder says why: `F7` measured the per-record cost flat at 0.69-0.73 ns from
10,000 to 1,048,576 records, where `F2`'s content ladder rose from 1.60 to
5.49 ns/line. The pass's cost is governed by **stride, not record count** -- a
blank arena is 8 bytes per record, so the header chase is a dense scan rather
than `F2`'s one-touch-per-2.9 KB stride, and the two count-sources converge to
within 10% (against 4.3x apart at `F2`'s depth). Any future re-measure of this
pass -- notably the wide-content one inherited condition 1 asks for -- should
vary bytes per record rather than depth. Second, `F7` records **`DD15`**: a
blank logical line is stored as a zero-cell record, because today's one-cell
canonical floor (`PackedRetainedRow.pack`, `I2`) is a property of the
per-display-row store rather than of the arena. Decision 1's derived 1,048,576
rests on that reading; the alternative admits 699,050 records, i.e. strictly
fewer, so this measurement bounds it from above either way (`F7` measured that
arm too: 1.378 ms, 12.1x inside).

### D3 -- the five open `F6` hard cases and the wide-record fallback: display-row anchors kept, one grand total in the index, the BCE blank materialized, the projection facade deferred, and identity denominated per record

- Status: **decided 2026-08-04.** This is Phase 2's fourth ledger entry and the
  last design work the ledger gates the graduation task on. It **discharges
  inherited condition 5**, **advances 1, 3, 9, 10 and 11**, amends `DD8`, `DD9`,
  `F4` cases 9 and 10, `F4` Observation 5, and two rows of `D2` Decision 2's
  operation table, and adds `DD16`-`DD18`. It is a **design** decision: `D1`'s
  scoping is unchanged, no production storage change is licensed by it, and the
  paired ladder is still owed. One measurement was taken for it, and only one --
  a throwaway experiment against the real engine for `HR3`, quoted in full in
  Decision 3 so the reading is reproducible from the doc alone. Every other
  number below is quoted from a prior finding or is arithmetic over quoted
  numbers, labelled as one or the other at each use.
- Date and investigator: 2026-08-04, Claude (agent).
- Evidence used: `F6` Observation 2 (`HR1`-`HR8`, the eight sites whose mapping
  is not obviously satisfiable), `F6` Observation 1 (the mapping of all 69
  sites, and specifically `T7`/`T8` versus `R1` on the frame path), `F6`
  Observation 3 (56 of 69 sites read a count, an index or a flag), `F1`
  Observation 1 (a point read costs 0.82-1.09 us) and Observation 2 (the derived
  count matches the engine's), `F2` (the counting pass on ASCII), `F7`
  Observation 2 (the pass's cost is governed by stride, not record count), `F3`
  Observation 4 and `DD5` (admission counts display rows rather than deriving
  them), `F4` Observation 1 (the wide-cell correction and iTerm2's own loop),
  `F4` Observation 5 (the tail-mutation enumeration), `F4` cases 9, 10, 13, 15,
  17 and 23, `F5` Observation 2 (the fold moves rather than vanishes) and
  Observation 5 (the invariant tally), `D2` Decisions 1, 2 and 5 (the budget,
  the eviction step and the five mutating operations), `28/F17` (the browse
  path's two walks and their 5.2% share), `21/F1` and `21/F2` (the drag-move
  latency budget), and the tree itself at `c8f46b1`.
- Candidate solutions considered, per area: `HR1` -- cache a grand total, cache
  an anchor row, or leave both derived; `HR2` -- (a) display-row anchors kept,
  (b) a two-kind history/live address with a defined total order, (c) logical-line
  anchors throughout; `HR3` -- materialize the styled blank, add a header style
  slot, or accept the divergence; `HR6` -- keep the materializing facade or
  rewrite all fourteen readers up front; `HR7` -- per-record identity, identity
  recomputed at read, or identity stored per fold; inherited condition 1 --
  argue it closed on existing numbers, or freeze a probe.

#### Frozen inputs, stated before the decisions that read them

Six facts this entry is built on, each with its provenance.

1. **In the tree at `c8f46b1` (read, not measured).** `Terminal.swift:2081
   scrollProjection` computes `totalRows` as `scrollbackRows.count + rows.count`
   and, when browsing, `topRow` as `anchor.row - evictedRowCount` clamped to
   `maximumTop` (`:2090`-`:2099`). The browsing anchor is **already** stored as a
   `TextAnchor`, i.e. as an absolute display row (`:2131`), and `evictedRowCount`
   is the immovable origin every absolute row is expressed against.
2. **In the tree (read, not measured).** The per-frame render path does **not**
   go through `ProjectionRows`. `presentedRowGeometry` (`:3185`) reads
   `scrollbackRows[index].forEachKind` directly and `forEachViewportCell`
   (`:4066`) reads `.forEachContentCell` directly; that separation is `28/F17`'s
   fix and its doc comment says so. `ProjectionRows` (`:394`) serves the
   point-local queries and `activeProjectionRows()`'s whole-history
   materialization.
3. **Measured here (Decision 3's experiment).** Severing a retained wrap claim
   under a non-default background-erase style leaves a **styled blank stored and
   painted**: 4 stored cells against the control's 3, `styleId` 1 at the last
   column, and a public read of `bg=indexed(1)`. Under the default style the
   same operation stores 3 cells and the column reads `bg=default`.
4. **Measured here (Decision 3's experiment).** The sever is **not the only**
   site: `clearPreviousSpacer`'s scrollback branch (`F6` `X9`) reaches the same
   cell through EL and through DCH at row 0, and leaves the row **still
   soft-wrapped** -- so the styled blank is reachable on a record that stays
   open, not only on one that closes.
5. **Quoted (`F4` Observation 1).** iTerm2's fallback loop for a line containing
   wide cells is
   `references/iterm2/sources/LineBlock.mm#iTermLineBlockNumberOfFullLinesImpl`,
   and it steps `i += width` -- one probe per display row, backing off one column
   when the boundary cell is a wide tail. `F4` and this doc's README have been
   calling that fallback `O(cells)`; it is `O(display rows)` with an O(1) test
   per boundary. The correction is Decision 7's whole basis and is derived from a
   quotation already in `F4`, not from a new reading.
6. **Quoted (`F1` Observation 1, `21/F2`).** One point read of the candidate
   store costs **0.82-1.09 us**; `21/F2` measured a `.character` drag-move at
   **92-101 us** deep, with roughly six projection reads per query (`21/F1`).

#### Decision 1 (`HR1`) -- the index maintains one grand display-row total, the anchor needs no cache, and no index lookup runs per row or per read

**What the index maintains.** Beyond the per-record offsets (`F2`: offsets-only)
and the per-block cached display-row totals, exactly **one** additional scalar:

    grandDisplayRowTotal : Int   // sum of every record's display-row count at the current width

It is maintained -- not recomputed -- at the six trigger points `D2` enumerated,
and each maintenance is O(1) in the number of records:

| # | trigger | what the writer knows | maintenance |
| ---: | --- | --- | --- |
| 1 | width change | nothing; the fold changes everywhere | the eager pass rebuilds every block total and **sets** the grand total to their sum (`F2`: 0.016 ms at trial depth, `F7`: 0.761 ms at the record count the budget admits) |
| 2 | admission (`DD5`) | `k`, the display rows just admitted, **counted** rather than derived | tail block total `+= k`; grand `+= k` |
| 3 | head eviction (`D2` Decision 2) | `k`, the display rows dropped by this step | head block total `-= k`; grand `-= k`; `evictedRowCount += k` |
| 4 | tail truncation (`HR4`, `D2` operation 4) | `k`, produced by the fold that chose the cut | tail block total `-= k`; grand `-= k` |
| 5 | forced split (`DD3`) | the split offset | recount the two resulting records at the current width; adjust both totals by the delta, which is 0 or +1 because a split ends a display row early |
| 6 | clear all (ED 3, reset) | the grand total | `evictedRowCount +=` grand; both totals to 0 |

**What the anchor cache caches: nothing, because there is no anchor cache.**
`F6` `HR1` proposed "the browsing anchor must cache its display row", and `D2`
carried that forward as a fifth maintained quantity riding all six trigger
points. Decision 2 below removes the need: the browsing anchor **is** an
absolute display row (frozen input 1), so `topRow` is the subtraction the tree
already performs. Its exact invalidation set is therefore the set of events that
change what an absolute display row denotes, and there is exactly one:

- **A width change** restates the anchor along with the other nine held anchors
  (Decision 2's restatement loop). This is `F4` case 15's content anchoring and
  `resizePreservesBrowsingAnchor` is the test that already pins it.
- **Eviction** requires no anchor edit at all: `evictedRowCount` moves and the
  subtraction absorbs it, exactly as `Terminal.swift:2099` and `:3906` do today.
- **Admission, tail truncation, forced split and clear-all** do not move any
  anchor's meaning (`D2` operation 4 states this for truncation: rows keep their
  absolute stream positions and merely change which side of the seam they sit
  on; clear-all adds the grand total to `evictedRowCount`, which is the same
  arithmetic the anchors are read through).

So `D2`'s "advanced condition 5" note is amended: the trigger list stays at six,
the maintained quantity is the grand total, and no cached browsing-anchor row
exists to invalidate.

**The reader contract that makes `topRow` O(1) again**, stated as three rules the
implementation must satisfy:

1. **`scrollProjection` performs no index lookup and no fold.** `totalRows` is
   `grandDisplayRowTotal + rows.count`; `topRow` is `anchor.row - evictedRowCount`
   clamped. The same holds for `projectionRowCount` (`:3243`), the cursor stream
   row (`:969`, `:4011`), `damageActionSnapshot` (`:966`), `damagedViewportRows`
   (`:1107`) and every clamp bound in `F6` `T13`. These are the ~200 reads per
   frame `HR1` priced at 164-218 us if each became a lookup; under this contract
   each stays the two-integer arithmetic it is today.
2. **A planned frame performs at most one display-row-to-record locate.** The two
   per-visible-row walks (`T7` `presentedRowGeometry`, `T8` `forEachViewportCell`)
   locate the top row once and then advance a forward cursor record by record for
   the remaining 65 rows. A per-row binary search would be 66 lookups where one
   suffices, and `F1` measured a lookup at 0.82-1.09 us, so the difference is the
   whole of `HR1`'s hazard.
3. **A lookup is paid per anchor change, not per read.** `scroll(toTopRow:)`
   (`:2125`) and `revealSearchMatchIfNeeded` (`:3226`) convert once when the
   anchor moves; nothing re-derives it afterwards.

**Behavioral tests this contract earns** (owed by the implementation, not written
here): the grand total agrees with an independent recount after each of the six
triggers, at two widths; and a test-only counter on the index asserts that
planning one frame performs **at most one** locate, and that the number is
invariant to history depth (10 records versus 10,000). The second is the one that
pins `HR1` itself, and it is cheap: a counter, a frame, an assertion.

**What `retained-browse`'s paired ladder must show for this to be judged
sufficient, frozen here before any implementation exists.** The verdict is
`retained-browse`'s own frozen rule in
`scripts/terminal-benchmark-validation.py#DECISION_RULES` (the 1.05% directional
threshold), measured against the parent revision the change forks from, under a
rule frozen before the comparison is read:

- **Not `slower`** is the bar. `HR1` is judged sufficient on `neutral` or
  `faster`; `F1`'s conversion predicts roughly **-2%**, and a `neutral` verdict
  means the predicted win did not materialize, which is a recorded cost and not
  a failure of this decision.
- **`slower` falsifies the implementation before it falsifies the design**, and
  the diagnostic order is fixed now so it is not chosen after seeing the number:
  first the frame-locate counter (rule 2 above -- more than one locate per frame
  is an implementation defect), then the ~200-read sites (rule 1 -- any of them
  reaching the index is an implementation defect), and only if both hold does the
  `slower` verdict read as evidence against wrap-at-read, at which point
  `28/H7`'s reopening condition is met as `D1`'s closure already states.

#### Decision 2 (`HR2`) -- the stored anchor coordinate stays the absolute display row; what returns is one restatement function, not the attachment machinery

**The decision: exit (a).** `TextAnchor` (`Terminal.swift:427`) keeps its
shape -- one absolute display row plus a column, `Comparable` over a single total
order -- and every one of the fourteen ordering call sites `F6` `HR2` enumerated
is unchanged. A record address, `(record, cell offset)`, is a **transient** the
index produces on demand; it is never stored in an anchor and never crosses the
module boundary. `DD9` said the *public* coordinate does not change and
deliberately left the stored one open; this closes it in the same direction, so
the public coordinate stays a subtraction away from the stored one.

**Why not (b), the two-kind address.** It is the exit that deletes the most, and
it costs more than it deletes. A history address must survive `D2`'s head trim,
which shifts every offset in the head record, so the history side needs a
monotone cell-stream position rather than a record index -- a second immovable
origin beside `evictedRowCount`. Worse, an anchor's *kind* changes when its row
crosses the seam, so every admitted batch would have to convert any live-kind
anchor whose row is being admitted: a fixup on `appendToScrollback`, which is the
exact path `terminal-feed` and `scrollback-stream` measure and where `H3`'s named
falsifier lives. Today that conversion is free precisely because `TextAnchor` is
one space; its doc comment says so ("keeps inspection state stable while rows
migrate between viewport and scrollback"). Trading a bounded per-width-change
cost for an unbounded-in-frequency per-admission one is the wrong direction.

**Why not (c), logical-line anchors throughout.** The live grid is not a
logical-line store and this design does not make it one; a live anchor would have
to be converted through a refold on every comparison, and `Comparable` is on the
pointer path.

**What returns, stated precisely, because `X3`/`X4`'s ~130 lines were counted as
deleted.** Under (a) an absolute display row denotes a different cell after a
width change, so the ten held anchors must be restated. The restatement is *not*
the attachment machinery:

| deleted, and stays deleted | why the choice does not save it |
| --- | --- |
| `Terminal.swift:4791 sourceKey` | it keys a cell by its **scalars** because a destructive rebuild leaves no index to key by; the arena is not rebuilt, so the address is arithmetic |
| `:3686 attachments`, `:3710`/`:3744 attachment` | they *search* a unit array for the anchor and fall back through three cases; the conversion is total and needs no search |
| `:3767 textDestination` and the `cellDestinations` / `boundaryDestinations` dictionaries built per logical line | a dictionary exists to answer "where did this cell go"; the fold answers it by arithmetic, and `textDestination`'s `Optional` return and the eight `??`-threaded destination locals in `resizeWidth` go with it |
| the seven reflow-only types (`:560`, `:599`-`:639`), less the live-refold half | `ReflowCursorAnchor`'s three cases serve the **live screen's** refold, which survives under either exit and which `F5` Observation 2 and `F4` case 7 already counted as *moving* rather than deleting |

What replaces them is one function pair plus one loop: `address(ofDisplayRow:)`
and `displayRow(of:)` -- the index lookup and the fold, both of which the store
owes anyway for `T2`/`T6` and for `DD9`'s public conversion -- and a
`restateAnchorsAcrossWidthChange` loop over the ten anchors. Estimated **~40
lines returning against ~130 deleted**, so `X3`/`X4` remain a real deletion of
roughly 90 lines; the estimate is labelled as one.

**The one new ordering invariant, stated rather than discovered later:** the ten
anchors are captured as addresses **before** the index is recomputed for the new
width, and restated **after**. The capture must read the old fold, which exists
only until the eager pass runs.

**Reconciliation with `F5`'s tally, which `DD8` rests the whole `D1` verdict on.**
`F5` Observation 5 counts invariant 4, "ten anchors survive a destructive
rebuild", among five deleted. Under this decision it is **reduced, not deleted**:
the rebuild is gone and the content-keyed mapping with it, but the *renumbering*
survives and one function now owns it. Counting honestly, the tally becomes
**4.5 deleted against 4.5 added** (`F5`'s 3.5 plus this capture-then-restate
ordering). The count alone therefore no longer carries the inequality, and this
entry says so instead of rounding in its own favour. What still carries it is the
distinction `F5` drew and did not merely assert: the deleted contracts are
between the store and *every* reader, or between a resize and *every* anchor
holder; the added ones each have exactly one enforcing site, and this one is a
total function testable by a round-trip property (convert, restate, convert back)
rather than a table that can miss. `DD8` is amended accordingly below.

**What this decision preserves, checked one at a time against the four things
`F6` asked it to weigh.** Selection remap under a width change (`DD1`): the
restatement loop, and `DD1`'s "remapped, not cleared" is unaffected. Eviction
clamping (`D2` Decision 2's contract): unchanged -- `handleEviction` (`:3873`)
keeps its shape, and the clamp is still the `evictedRowCount` subtraction.
Scroll anchoring (`F4` case 15): the browsing anchor is one of the ten restated
anchors, which is also what makes Decision 1's "no anchor cache" true. The
`Comparable` contract's call sites: untouched, because the type is untouched.

#### Decision 3 (`HR3`) -- the severed wrap claim's BCE cell is materialized into the open tail record as one styled cell, and the same rule closes `X9`

**What the engine actually does, measured rather than asserted.** A throwaway
test was run against the real engine at `c8f46b1` and deleted before this commit;
its body is quoted so the reading is reproducible from the doc alone:

    var terminal = try #require(Terminal(columns: 4, rows: 2))
    terminal.feed(Array("abc\u{754C}".utf8))   // 3 narrow cells, then a 2-cell cluster
    terminal.feed(Array("\r\n".utf8))          // row 0 scrolls off, carrying its spacer
    terminal.feed(Array("\u{1B}[H\u{1B}[41m\u{1B}[L".utf8))  // IL at row 0, red BCE

| state | stored cells | kinds | style ids | `isSoftWrapped` | public column 3 |
| --- | ---: | --- | --- | :---: | --- |
| before the sever | 4 | narrow, narrow, narrow, **spacerHead** | 0,0,0,0 | true | -- |
| after, red BCE | 4 | narrow, narrow, narrow, **padding** | 0,0,0,**1** | false | kind `padding`, **`bg=indexed(1)`** |
| after, default BCE (control) | 3 | narrow, narrow, narrow | 0,0,0 | false | kind `padding`, `bg=default` |

Three things this settles that `F6` `HR3` could only assert. First, the
divergence is **exactly one cell and only under a non-default erase style**: the
control shows today's engine already stores nothing at that column when the style
is default, so the naive mapping (drop the spacer, measure a closed record to its
content end) is byte-for-byte correct in the default case and `F4` case 10's
"no-op" holds there. Second, the retained row's charged byte cost is **96 before
and 96 after**, so the cell is free in the budget's terms. Third -- and this is
new, `F6` `HR3` did not have it -- the sever is **not the only reachable site**:

    terminal.feed(Array("\u{1B}[H\u{1B}[41m\u{1B}[2K".utf8))   // EL  -> eraseCells -> clearPreviousSpacer
    terminal.feed(Array("\u{1B}[H\u{1B}[41m\u{1B}[P".utf8))    // DCH -> moveAndFillCells -> clearPreviousSpacer

Both leave 4 stored cells with `styleId` 1 at column 3 and **`isSoftWrapped`
still true**. So `F6` `X9` ("the store never held the spacer, so this is a
no-op") is wrong in the same way `F4` case 9 was, and on a record that stays
**open** rather than one that closes.

**The mechanism, chosen to reproduce today's output.** The record's trailing cells
obey `pack`'s canonical-extent rule verbatim
(`PackedRetainedRow.swift:487`-`:495`: a cell extends the stored extent when it
carries scalars, or is not `.padding`, or is not the default style). Concretely,
both repair sites become a **tail append of at most one cell** on the open tail
record:

1. Fold the open tail record at the current width. If its final display row
   occupies `width - 1` columns, the dropped spacer is the missing column. (For an
   open record that is the only way a final display row can be short: admission
   measures a soft-wrapped row to full width, `F4` case 17, and the only cell it
   drops is the spacer.)
2. If the replacement style is the **default**, do nothing -- today's `pack`
   trims that cell, so storing nothing reproduces it exactly.
3. Otherwise **append one cell**: empty scalars, the erase style id, no
   hyperlink, no content identity. At read the fold emits that column with that
   style, which is the cell the renderer paints.
4. Then, and only for the sever, flip the open/closed header bit (`F4` case 9's
   original mapping).

**Why this and not the two alternatives.** A *header style slot* was rejected: it
adds a field to every record for a case reachable on one record, and it cannot
express the `X9` variant, where the record stays open and the styled cell sits at
a boundary the fold will keep re-deriving. *Accepting the divergence* was
rejected on inherited condition 10, which exists to prevent exactly this: `D2`
Decision 5 refused the same trade for the head trim, and this entry does "the
same quality of job" the ledger asked for rather than a cheaper one.

**Amended 2026-08-04 by the plan's `DD25` amendment: this decision's mechanism is
unchanged, and the unification it now sits next to is recorded as an option not
taken.** The implementation gained a **trailing fill style** on hard-ended
records -- a per-record attribute, held in a side table keyed by record and gated
by a header bit, that says "after this line's content ends, the remainder of its
last display row is painted in this style". That is a different case from this
one in two ways: it is the *hard-ended* row's to-edge paint rather than this
entry's single column at a wrap boundary, and it is width-relative rather than
positional, which is exactly why it may not be cells. Neither objection above is
weakened: the fill is not a field in every header, and it does not express the
`X9` variant. **The option not taken:** severing could be re-spelled as "set the
trailing fill from the severed spacer's style", leaving one mechanism where there
are now two. It is not taken here because this entry's mechanism is the one that
was *measured* against the real engine (the four-state table above), and
re-spelling a measured case on the strength of an unmeasured generalization is
not licensed by an amendment that changed no number. A later slice may take it
deliberately; it would have to re-measure the same four states.

**What it costs, stated so the addition side is not understated.** `F4`
Observation 5's "all three writes are header-bit flips" becomes "two of the three
are a header-bit flip **plus at most one appended cell**, and the third
(`clearPreviousSpacer`) is an appended cell with no flip". It is still a **tail
append** -- the operation admission already performs at the write cursor -- so no
new mutating operation joins `D2`'s table of five and the "middle immutable"
premise is untouched. `D2` Decision 2's row 2 is amended below. The charge is 8
bytes, charged like any other cells.

#### Decision 4 (discovered while settling `HR3`) -- the open tail record ends on a display-row boundary at the current width, re-established by the same pull-back `HR4` already needs

Decision 3's step 1 asks the fold a question about the open tail record's final
display row, and that question only has today's answer if the record's cells end
where a display row ends. A width change breaks that: the record's cells were
admitted at `W0`, and folding them at `W1` leaves `count mod W1` cells in a short
final display row **in the middle of a logical line** that continues in the live
grid. Today `reconstructLogicalLines` joins the retained tail with the live rows
and repacks, so no such row exists; under this design the live screen refolds and
history does not, so it would. Worked case, derived: 190 admitted cells plus 31
live cells, widened to 200 columns, renders as 190 + 31 where today it renders as
200 + 21.

**The rule:** on a width change, the open tail record is truncated at its last
display-row boundary **at the new width**, and the suffix (fewer than `W1` cells)
is handed to the live screen's refold as the continued line's prefix; when those
rows scroll off again, admission re-appends them. That is `D2` operation 4's
mechanism -- fold the tail record, cut at a cell offset, hand the suffix to the
live grid, rewind the write cursor, rewrite the header and reopen -- at a new
trigger, so the arena still has exactly five mutating operations and operation 4
gains a second trigger. It does not touch the rest of history, and it is bounded
by one display row.

The alternatives are recorded as `DD16`: accept the ragged seam (user-visible,
and diverges from today's output, which inherited condition 10 forbids), or let
the fold peek at the live grid at the seam (the fold stops being a function of
(record, width) alone, which is the property the whole design leans on).

#### Decision 5 (`HR6`) -- `ProjectionRows` keeps its materializing facade for milestone 1; the borrowing cursor is milestone 2, with its priority rule frozen now

**The decision.** Milestone 1 keeps `Terminal.swift:394 ProjectionRows` as a
`RandomAccessCollection<GridRow>`; its subscript locates (record,
display-row-in-record) and folds that slice into a `GridRow`. All fourteen
readers are unchanged. The borrowing cursor (`R1`) and `activeProjectionRows()`'s
replacement by a forward walk over records (`R2`) are **milestone 2**.

**Why this is not simply deferring the hard part.** The borrow-versus-materialize
split already exists in the tree and already follows the hot/cold line (frozen
input 2): the per-frame path reads `forEachKind` and `forEachContentCell`
directly off the packed row and never touches `ProjectionRows`, which is `28/F17`'s
fix. So milestone 1 lands the arena's borrow on **exactly the path `F1`
measured**, and keeps a materializing facade on the pointer and whole-history
paths -- where today's subscript already materializes one `unpacked()` per
access. Against today, that is a wash rather than a regression: the arena's
deletion of the per-row allocation is *realized* on the frame path at milestone 1
and *not yet taken* on the pointer path. `F6` is right that this is the largest
single rewrite; it is also the one with no measured pressure behind it.

**The priority rule for milestone 2, frozen before the number.** Re-measure doc
21's `.character` drag-move at trial depth against `21/F2`'s measured 92-101 us
band, under `21`'s own instrument. **Above 121 us** (101 us plus 20%) the
borrowing cursor is promoted ahead of the rest of milestone 2; **at or under**,
milestone 2 stays scheduled and unprioritized. The 20% is the same allowance
`21/F2`'s band width implies rather than a new number: `F1` prices one point read
at 0.82-1.09 us and `21/F1` counts roughly six projection reads per query, so a
facade that materializes rather than borrows can move the query by ~5 us, and a
20% band is well outside that -- which is the point. If the drag-move exceeds it,
something other than this arithmetic is happening and it should be found before
the rewrite is scheduled.

**`DD8` re-read against `HR6`, which `F6` asked for explicitly.** Three findings.
(i) `F6`'s "by line count the projection layer is larger than the arena itself"
is a **milestone 2** statement under this decision, so it does not enlarge
milestone 1's diff. (ii) It does not move the invariant tally either way:
`ProjectionRows` is an internal facade with no cross-cutting contract, materialized
or borrowed. (iii) But Decision 2 **does** move the tally, from 5-versus-3.5 to
4.5-versus-4.5, so `DD8`'s first reopening clause ("Phase 2's implementation lands
materially larger than the prototype suggests") is not met while its second ("the
invariant argument has weakened") now is, partially. `DD8` requires both, so it
stands -- and the graduation task must re-read it against the landed
implementation rather than treating `F5`'s margin as banked. That is recorded as
an amendment at `DD8` rather than as a silent reading here.

#### Decision 6 (`HR7`) -- `contentIdentity` is a per-record run table keyed by cell offset in the logical line; `activationIdentity` keeps its semantics and the shape reader is re-denominated

**What identity becomes.** A per-record side table, in the same encoding
`PackedRetainedRow` already uses -- `(start, extent, base)` runs with the per-cell
fallback when the table would cost more than four bytes per stored cell
(`PackedRetainedRow.swift:243`-`:266`, `:499`-`:503`) -- with the key changed from
**column within a display row** to **cell offset within the logical line**.

Two alternatives are refused for stated reasons. *Recomputed at read* is
impossible: `contentIdentity` is a counter allocated at print time
(`allocateContentIdentity`), not a function of the cell's bytes, so it must be
stored or lost. *Stored per fold* is refused as a matter of principle and of
`D1`: a fold is width-dependent, so a per-fold identity table is width-dependent
persisted state and fires `D1`'s no-go trigger. Keying by line offset is the only
option that keeps the store width-free, and it is strictly better than today: a
run no longer breaks at a display-row boundary, which is the "one table per
record rather than per display row" advantage `F1` and `F3` both measured
themselves as *not* having taken.

**The consumers, named from the code, and what happens to each.**

- **`Terminal.swift:2891 activationIdentity`** -- the only production consumer.
  It computes `max(contentIdentity)` over a link range's cells and stores it in
  `InteractionLinkState` (`:529`), which is written at `:2779` and `:2850` and
  compared at `:2443`, `:2479`, `:2527` and `:2545` to decide whether a hovered
  or armed link still refers to the same content. Under the store the link range
  is a contiguous **cell-offset range** in one record (`F6` `R5`, `R6`), so the
  computation is `max` over one run-table range -- the same set of cells and the
  same maximum. A link that crosses the history/live seam takes the max of the
  record range and the live range, which is what the two-part walk does today.
  Semantics preserved exactly; `TerminalHyperlinkInteractionTests` is the suite
  that pins it and needs no new case for the unit change.
- **`Terminal.swift:2184 scrollbackRowContentIdentityShape`** -- measurement
  only. Its consumers are `TerminalContentIdentityShapeTests`,
  `TerminalPackedRetainedRowTests:400` and
  `TerminalRetainedRowProbeSupport.swift:526` (doc 28's `PR1`); there is no
  production caller. It is **re-denominated to the record**:
  `contentIdentityShape(ofRecord:)` over one logical line's stored cells. This is
  what dissolves `HR7`'s contradiction rather than papering over it: the reader's
  stated contract is "the row's own content, not the pane's width", and it is
  implemented today by deliberately reading the *unmaterialized* prefix. A
  record's stored cells are width-free by construction, so under the new store
  the contract is literally true and the caveat disappears -- there is no
  materialized trailing padding to exclude. Doc 28's `PR1` consumes the quantity
  as an aggregate, so what changes is the sample unit (one sample per logical
  line rather than per display row); doc 28 owes a one-line note saying so, and
  this entry does not write it.

**What this advances and what it does not.** Inherited condition 9 (the record
format must carry what every probe stripped) is advanced, not discharged: the
identity table's key and encoding are settled here, and the **spill table**
(`28/F11`: ~0.12% of rows), the `hyperlinkId` table and the semantic-mark slot
are still owed a format.

#### Decision 7 (inherited condition 1) -- the wide-record fallback is `O(display rows)`, not `O(cells)`; the argument is recorded, the probe and its decision rule are frozen, and it does not block graduation -- probe run 2026-08-04 by [F9](findings.md), narrow confirm

**The reframing, which is the substance of this decision.** `F4` Observation 1,
`D1`'s condition 1 and this doc's README all describe the wide-record counting
fallback as "an O(cells) scan". It is not. The fold needs to know, at each
display-row boundary, whether a 2-cell cluster straddles it -- one probe per
**display row**, not per cell. iTerm2's own fallback is exactly that loop and it
is already quoted in `F4` (frozen input 5): it steps `i += width` and backs off
one column when the boundary cell is a wide tail. DanTerm's rule is the same
statement from the other side -- `pack` inserts a `.spacerHead` when a 2-cell
unit meets a one-column gap -- so the count is obtained by walking boundaries,
not cells.

**The bracket, with the existing numbers, labelled as arithmetic.** The pass's
work is then bounded by the **grand display-row total**, which the byte budget
bounds directly. From `D2` Decision 1's table: 11,650 display rows for `full`,
16,728 for `mix`, ~15,472 for `wide`, and 1,048,576 in the degenerate blank-record
regime -- where no record is flagged and the fast path runs, which is precisely
what `F7` measured at 0.760-0.761 ms. The wide-content worst case is not depth
but **narrowness**: a CJK arena folded at the 2-column minimum puts one cluster
per display row, so ~2.08M stored cells become ~1.04M display rows and ~1.04M
boundary probes. At `F7`'s measured per-record rate (0.69-0.73 ns for a dense
8-byte-stride chase) that is under 1 ms; at a pessimistic 5 ns per probe -- a
scalar-width lookup rather than a bit test -- it is ~5 ms, inside the 16.67 ms
one-frame bound by 3.2x. `F7`'s reading is what makes the estimate credible in
shape ("the pass's cost is governed by stride, not record count", and a wide scan
is the densest stride there is) and what makes it uncertain in constant.

**Therefore: condition 1 does not block the graduation task, and it is not
closed.** The design does not change on either outcome -- the fold is the fold --
so nothing downstream waits on the number. But 3.2x on an unmeasured constant is
not `F7`'s 21.9x on a measured one, and this entry declines to spend a margin it
computed itself.

**The probe, frozen here so a follow-up runs it mechanically.** Re-run
`TerminalLogicalLineIndexProbe`'s eager recompute under `F2`'s frozen rule --
same instrument, same 9 measured rounds plus 2 warmup, same statistic (median
over rounds of wall time for one whole pass), same four validity gates
(non-elision with an independent cross-check of the total, synthetic-stimulus
fidelity within 15% against a real-engine arena at 10,000 lines, host conditions,
coverage) -- with three changes and no others:

1. **Stimulus:** `F3`'s `wide` CJK generator, so every record carries the
   `hasWideCells` bit and every boundary probe fires. `F2`'s `mix` and `full` are
   re-run unchanged as the control, since their cells never take the fallback.
2. **Depths:** the record count a full 16 MiB arena admits for that class
   (~7,500 records / ~2.08M cells, derived from `F3` Observation 4's 2,215 bytes
   per record), plus `F2`'s 10,000 and 100,000 rungs for continuity. Per `F7`,
   **vary bytes per record, not record count**: the ladder that matters is
   cells-per-record, and the blank-record end of it is already measured.
3. **Width changes:** `179 -> 100` and `179 -> 200` as `F2` froze, **plus
   `179 -> 2`**, the minimum the engine permits (`F4` case 3), because display
   rows per record -- and therefore boundary probes -- are maximised there.

**The decision rule, frozen before the number exists**, in `F2`'s own three-way
shape:

- **Confirm** -- median pass **< 1.67 ms** (a tenth of a frame) on every measured
  cell. Inherited condition 1 is discharged and nothing changes.
- **Narrow confirm** -- at or above 1.67 ms but **< 16.67 ms**. Eager stands, and
  the entry records the (class, width) cell that crosses a tenth of a frame as a
  condition on the store's depth, exactly as `F2`'s narrow-confirm did.
- **Reject** -- **>= 16.67 ms**, one 60 Hz frame, on any measured cell. Then one
  of two mitigations ships, and the choice is a human's: a **per-record cached
  display-row count** invalidated by width change (which is `DD7`'s reading
  applied a second time -- a cache, discarded rather than migrated, not stored
  width), or **lazy per-block recompute**, which the README's Rejected section
  keeps available for exactly this.

**Applied once to [F9](findings.md), which measured it at `2ac87e1` plus the one
probe file it adds.** On the deepest wide history 16 MiB admits -- 7,531 CJK
records, 2,082,012 cells, every record flagged -- the pass reads **0.056 ms** at
`179 -> 200`, **0.064 ms** at `179 -> 179`, **0.144 ms** at `179 -> 100` and
**5.439 ms** at `179 -> 2`, with every gate held and no invocation voided. The
worst cell across the arm and the cells-per-record ladder is **5.634 ms**.
Against the rule: reject required 16.67 ms and is **2.96x** away; confirm
required every cell under 1.67 ms and every `179 -> 2` cell is 1.835-5.634
ms. **The verdict is narrow confirm.** The eager recompute stands, **neither
mitigation ships**, and the recorded band-crossing cell is (`wide`, `179 -> 2`).
Two things `F9` settles about this entry's own reasoning rather than about the
design: the `O(display rows)` reframing is measured, not merely argued -- the
per-display-row cost is **5.2-5.4 ns and flat from 2 to 4,096 cells per
record**, so one frame is ~3.1-3.2M display rows against the 1.05M the budget
admits, and this
entry's 3.2x bracket at a pessimistic 5 ns per probe was right in shape and in
constant. `F9` also records **`DD23`** (a measured cell is verdict-bearing iff its
charged bytes fit the budget, which is how the continuity rungs this entry named
are read) and **`DD24`**.

#### Scoped out of this decision, deliberately

Named so a later reader can tell a gap from a silence:

- **`HR4`'s fold arithmetic** -- `D2` Decision 2 owns operation 4 and states what
  it must update; Decision 4 above adds its second trigger. How the cut offset is
  computed is the plan file's.
- **`HR5` and `HR8`** -- closed by `D2` Decision 2 and by Decision 1 above
  respectively; neither is reopened here.
- **Exact record, header, index and side-table layout** -- Phase 3's, as `D2`
  already scoped it. Decision 6 fixes identity's *key*, not its bytes.
- **The spill table, the hyperlink table and the semantic-mark slot** --
  inherited condition 9's remainder, still owed.
- **Whether doc 28's `PR1` wants per-record samples** -- doc 28's, per Decision 6.

- Behavioral verification owed (none of it written by this entry; it is the test
  list the implementation inherits, and every item is behavioral rather than
  structure-coupled, with the one deliberate exception noted):
  1. The grand display-row total agrees with an independent recount after each of
     Decision 1's six triggers, at two widths.
  2. Planning one frame performs at most one display-row-to-record locate, and
     the count does not vary with history depth. *(The one structure-coupled
     test in the list, and it is the one that pins `HR1`; a test-only counter is
     the cheapest instrument that can fail for the right reason.)*
  3. A width change preserves the selection, the search occurrence, the hovered
     and armed links, the drag pin and the browsing anchor, at widths 179, 100,
     200 and 2 -- the round trip Decision 2's restatement owes, and
     `resizePreservesBrowsingAnchor` plus the `TerminalResizeTests` /
     `TerminalSelectionTests` remap cases are the existing shape.
  4. Severing a retained wrap claim under a non-default background-erase style
     leaves the last column painted in the erase colour, and under the default
     style leaves it painted in the default -- the two rows of Decision 3's
     table, re-asserted against the new store. Same for EL and DCH at row 0
     (`X9`), where the record additionally stays open.
  5. Widening or narrowing while a logical line straddles the history/live seam
     leaves no short display row in the middle of that line (Decision 4).
  6. A hovered link's `activationIdentity` changes when any cell in its range is
     overprinted and does not change otherwise, with the link range spanning the
     history/live seam (Decision 6).
- Quantitative verification: one measurement, reported in Decision 3's table
  (stored cell counts, kinds, style ids and the public background at column 3,
  before and after a sever, under a red and a default erase style, plus the two
  `X9` paths). It is a behavioral reading of the current engine, not a benchmark,
  and nothing in this entry is a timing.
- Tradeoffs and correctness risks:
  - **The invariant margin narrows.** Decision 2 takes `F5`'s tally from
    5-versus-3.5 to 4.5-versus-4.5, and this entry declines to hide that. The
    qualitative distinction (cross-cutting versus local, and a total function
    versus a lookup table that can miss) is what carries it, and `DD8` is amended
    rather than left to be re-read favourably.
  - **Decision 3 puts a cell write back into history.** It is a tail append and
    it is charged, but "two of the three tail mutations are pure bit flips" was a
    claim `F4` made and `F5` counted, and it is now false.
  - **Decision 4 was discovered, not designed.** It follows from Decision 3's
    precondition, and no probe has exercised a width change with a logical line
    straddling the seam. It is the least-tested corner of this entry.
  - **Decision 5 defers the largest rewrite**, so milestone 1 ships an arena
    behind a facade that still allocates a `GridRow` per pointer query. That is
    parity with today, not a regression -- but it means the paired ladder at
    milestone 1 measures a store whose projection layer has not yet been paid
    for.
  - **Decision 7's bracket is arithmetic on an unmeasured constant.** The
    reframing from `O(cells)` to `O(display rows)` is read from iTerm2's loop and
    from `pack`'s own rule; the per-probe cost is not measured, which is why the
    probe is frozen rather than the condition closed.
  - **`HR1`'s reader contract is a discipline, not a mechanism.** Nothing in the
    type system stops a future call site from reaching the index inside a
    per-row loop. The frame-locate counter is the only thing that would catch it,
    which is why it is on the test list.
- Decision and rationale: the five open hard cases split cleanly into two kinds,
  and the entry treats them differently on purpose. `HR1`, `HR6` and `HR7` are
  *mechanism* questions where the tree already contains the answer -- the browse
  path already avoids `ProjectionRows`, the browsing anchor is already a display
  row, the identity table already has a run encoding -- so the decisions are to
  keep what works and name the contract that keeps it working. `HR2` and `HR3`
  are *trade* questions, and both are decided against the cheaper option: the
  anchor space stays where the cost is bounded and periodic rather than
  unbounded and per-admission, and the BCE blank is materialized rather than
  dropped, because inherited condition 10 exists to stop exactly the kind of
  silent output change that a checksum gate over spacer-free stimuli would never
  have caught. `F6` was right that the eight flagged sites were the design risk;
  what settling them shows is that seven of the eight cost the design something
  small and one of them -- `HR2` -- costs it a line in `F5`'s tally, which this
  entry pays openly rather than rounding away.
- Direction review: this entry changes no constant, no code and no default. It
  is a specification the graduation task consumes, and with it the ledger's
  "when the design settles" gate is met: `HR1`-`HR8` are all disposed of, the
  four decisions `F6` handed the graduation task are made, and inherited
  condition 5 is discharged. `28/D11` remains a live trial until doc 28 records
  its exit, and `28/H7` remains rejected with `D1`'s reopening condition.
- Reopening conditions:
  1. `retained-browse` comes back `slower` against the parent revision under its
     frozen rule, **and** Decision 1's two diagnostics (the frame-locate counter,
     the ~200 arithmetic-only reads) both hold -- then `HR1`'s mitigation is
     insufficient and the index's shape, not its discipline, is the suspect.
  2. ~~The wide-content counting probe (Decision 7) rejects -- then a per-record
     cached count or lazy per-block recompute ships, and the README's Rejected
     entry for lazy recompute is spent.~~ **Spent 2026-08-04: [F9](findings.md)
     ran the probe and returned narrow confirm, so no mitigation ships and the
     Rejected entry for lazy recompute is not spent.**
  3. `terminal-feed` or `scrollback-stream` comes back `slower` and profiling
     attributes it to anchor bookkeeping -- then Decision 2's exit (a) is the
     suspect, and exit (b)'s per-admission conversion is *not* the fallback,
     since it puts more work on that same path; the fallback is to hold fewer
     anchors.
  4. A human prefers the divergence to the cell write in Decision 3 -- then
     inherited condition 10 is being narrowed, and it should be narrowed
     explicitly rather than by omission.
  5. The drag-move re-measure in Decision 5 exceeds 121 us -- then the borrowing
     cursor is promoted, which is a scheduling change, not a design change.

#### Ratifications, amendments and new deferred decisions

- **`DD8` is amended, not overturned.** Its reading -- the inequality is
  adjudicated on invariants rather than line count -- stands, but the margin it
  reported (five deleted against three and a half added) is now **4.5 against
  4.5** by Decision 2's honest count. Its reopening condition requires *both* a
  materially larger implementation *and* a weakened invariant argument; the
  second clause is now partially met, so the graduation task must re-read `DD8`
  against the landed implementation instead of quoting `F5`'s margin. The
  amendment is noted at `DD8` in [findings.md](findings.md) rather than
  rewriting it.
- **`DD9` is extended.** It settled the *public* coordinate and deliberately left
  the stored one open; Decision 2 settles the stored one in the same direction,
  so the two are one subtraction apart and `DD9`'s "all translation happens
  inside `Terminal`" now describes both.
- **`F4` case 9 and case 10 are amended, and `F4` Observation 5 with them.**
  Severing is a header-bit flip **plus at most one appended cell**, and clearing
  a spacer is an appended cell with **no** flip -- not a no-op -- whenever the
  background-erase style is non-default. Decision 3 measured both. The amendment
  is noted at `F4` Observation 5 in [findings.md](findings.md).
- **`D2` Decision 2's operation table is amended in two rows.** Operation 2
  ("close / reopen the tail record") widens from "one header bit" to "one header
  bit, plus at most one appended cell (`D3` Decision 3)". Operation 4
  ("truncate the tail") gains a second trigger: a width change, to re-establish
  the display-row boundary at the open record's tail (`D3` Decision 4). The
  arena still has exactly five mutating operations.
- **`D2`'s advanced-condition-5 note is amended.** The six trigger points stand;
  "each riding the cached browsing-anchor row from `HR1`" does not, because
  Decision 2 makes the anchor a display row and Decision 1 therefore needs no
  anchor cache. The maintained quantity is the grand display-row total alone.
- **DD16 -- a width change pulls the open tail record's partial display row back
  into the live refold rather than leaving a ragged seam.** The alternatives are
  accepting a short display row in the middle of a logical line after a resize
  (user-visible, and the divergence inherited condition 10 forbids), or letting
  the fold read live-grid state at the seam (the fold stops being a function of
  (record, width) alone). Reopen if the pull-back is measured on the resize path
  and is not free -- it is bounded by one display row, so this is a small risk
  stated rather than a large one hidden.
- **DD17 -- `contentIdentity` runs are keyed by cell offset in the logical line,
  and the shape reader is re-denominated per record.** The alternative that keeps
  `scrollbackRowContentIdentityShape`'s display-row denomination would have to
  choose the row's cells by the current width, which is the width-dependent
  question `HR7` found the contract cannot answer. Reopen if doc 28's `PR1` needs
  per-display-row samples, which no consumer asks for today.

  **Qualified 2026-08-04 by the external design review.** This is the one place
  `DD9`'s "the public coordinate does not change" is not unqualified: no
  coordinate changes, but `scrollbackRowContentIdentityShape`'s **denomination**
  does -- per display row to per record -- so its samples change meaning. Its
  consumers are `TerminalContentIdentityShapeTests`,
  `TerminalPackedRetainedRowTests` and doc 28's `PR1`, never production, and the
  plan names it in its behavioral scope so the migration surface is not read as
  empty.
- **DD18 -- milestone 1 keeps a materializing `ProjectionRows`.** The alternative
  is rewriting fourteen readers before any ladder verdict exists. Reopen on
  Decision 5's frozen drag-move rule, which is the only measurement that can make
  the deferral wrong.

#### Conditions discharged and advanced

Against `D1`'s eleven carried-forward conditions:

- **Discharged: 5** (the block index's trigger points -- Decision 1's table
  enumerates all six, states what each maintains, and the behavioral-test list
  gives each one a test; `HR4`'s and `HR1`'s additions to the list are absorbed).
- **Advanced: 1** (the fallback is reframed as `O(display rows)` and bracketed
  with existing numbers, and its probe and decision rule are frozen for a
  follow-up; the measurement is still owed), **3** (Decision 1 states what
  `retained-browse` must show and fixes the diagnostic order before the
  comparison), **9** (identity's key and encoding are settled; the spill table,
  the hyperlink table and the semantic-mark slot are still owed), **10**
  (Decision 3 closes `HR3`, the counter-example `F6` found, and Decision 4 closes
  the seam case it exposed; the standing obligation discharges only when the
  implementation's cross-arm check passes), and **11** (`DD8` re-read and
  amended, `DD9` extended).
- **Untouched: 2** (eviction is still unmeasured on both sides), **4**, **6**
  (discharged by `F6`), **7** (discharged by `D2`), **8**.

**What remains open before graduation: nothing that is a design decision.** The
two measurements still owed -- eviction (condition 2) and the wide-content
counting pass (condition 1) -- have their mechanisms specified and, for condition
1, their probe and rule frozen; neither changes the design on either outcome. The
paired ladder (condition 3) is the acceptance dimension and is owed against a
real implementation by construction.

### D4 -- the eviction comparison's decision rule, and the `AR6` residency reading sequenced with it

- Status: **rule frozen 2026-08-04 at `de17e95`, before the eviction probe
  existed in the tree and before any eviction or residency number was produced.**
  **Run 2026-08-04 as `F8`, and both of its rules read `reject`** -- the eviction
  comparison at 1.418x-3.177x on `steady` and 1.830x-3.114x on `drain` across all
  four verdict-bearing classes, and the `AR6` residency reading on the second
  trigger (the arena resident at 1.118x today's store for the same fed input on
  `scrollback-mixed`). The rule was applied once, to the numbers as printed, and
  is not reopened by them; disposition of both rejects is a human's, as this
  entry says it is. Two things `F8` reports that this rule could not anticipate
  and that a reader of the verdict needs: gate 7 **passes at 1.000x**, so the
  per-step complexity this rule was frozen against is what the landed code does;
  and the descriptive attribution arm puts the eviction reject in the landed
  store's per-byte arena access rather than in wrap-at-read, since `F3`'s own
  prototype of the same rule re-measured at 0.52x-0.64x of today's admission in
  the same session. Four deferred decisions added (`DD29`-`DD32`), the first two
  of them the substitutions this rule's letter could not be executed with.
  This entry is the first slice of
  [the plan](../../../plans/impl/2026-08-04-1137-logical-line-scrollback-store.md)'s commit
  checklist and it produces **no number**: it states the arms, the stimuli, the
  instrument, the validity gates, the thresholds with their derivations and the
  verdicts, so that nothing downstream can be chosen after a result is seen. The
  measurement it governs is the plan's slice 4 and lands as `F8`.
- Date and investigator: 2026-08-04, Claude (agent).
- Evidence used, all quoted rather than re-measured: `D2` Decision 2 (the
  eviction step this rule prices, as amended by the external review), `D2`
  Decision 1 (the charge model, the depth table and the amended residency
  reading), `F3` Observation 4 (arena bytes and record counts per content class),
  `F3` Observation 2 (mean stored cells per display row), `F3`'s own frozen rule
  (the two-arm instrument and six gates this rule reuses), `F6` `HR5` (what
  whole-record eviction costs in four anchors and the scrollbar), `28/F20`
  Observation 1 (the 19.7% write-path subtree share) and Observation 5
  (`scrollback-stream`'s row shape), `28/F23` (the `mix` and `full` calibration
  bands), `agent-docs/terminal-performance.md` (the 95.7% drain share),
  `scripts/terminal-benchmark-validation.py#DECISION_RULES` (the frozen
  directional thresholds), and `15/F2` / `15/F4` (the charge-versus-resident
  error class the residency reading exists to refuse).
- Candidate solutions this rule can distinguish: head-granular eviction as `D2`
  Decision 2 specifies it (the design), whole-record eviction (`DD2` as
  originally written, which is the plan's `AR1` fallback), and today's
  `enforceScrollbackBudget` (the thing being replaced).

#### What this rule can and cannot decide

Like `F3`, this is a microbenchmark converting a ladder threshold into a
microbenchmark ratio through a **measured** cost share, so it reports a
prediction. It therefore **cannot land the store and cannot fail it**: landing is
the paired ladder's (`retained-browse` as the go/no-go, `terminal-feed` and
`scrollback-stream` carrying `H3`'s falsifier), and `D1`'s scoping is unchanged
-- no production storage change is licensed by this entry.

**It prices the mechanism; it does not reopen `D2` Decision 2's granularity**
unless its own reject bound below fires *and* the third arm attributes the cost
to granularity rather than to the arena. That ordering is the whole point of
freezing it now: the eviction number is the largest unmeasured term in the
campaign (`D1` condition 2), and a rule written after it would be a rule written
to fit it.

**The complexity reading this rule is frozen against**, stated because the plan's
`AR1` was corrected to it by the external review and a rule written against the
worse reading would set its bounds in the wrong place: `D2` Decision 2's steps 1
and 4 persist the head cell offset, so one trim step folds **one display row**
from that offset -- `O(width)`, or `O(cells in that row)` on the wide path -- and
draining a record costs one pass over the record across all its steps rather than
one pass per step. Gate 7 below is what holds the implementation to that reading
instead of assuming it.

#### Instrument

A standalone three-arm microbenchmark in
`lib/TerminalCore/Tests/TerminalCoreTests/`, release configuration, headless,
env-gated behind `DANTERM_LOGICAL_LINE_PROBE`, **in its own file, with `F1`'s,
`F2`'s, `F3`'s and `F7`'s probe files unedited** (the practice `F2` established
and every probe since has kept). It reuses this doc's existing harness --
`RetainedStimulus`, `buildStimulus`, `interleavedRounds`, `median`, `percentile`,
`loadAverageDescription` -- and adds only the two evicters plus the arena variant
arm C needs.

Arms are interleaved **ABBA within one process**, at **5 measured rounds + 2
warmup** per (content class, statistic), the same round count `F3` froze. Every
aggregate is reported with its min, max and sample count. Geometry is 179x66 and
depth is whatever the 16 MiB budget admits for the class, which is the point:
this is the only probe in the doc that measures a **saturated** store.

**Two measured statistics, both taken on a store already filled to the budget
outside the timed region.**

1. `steady` (**verdict-bearing primary**) -- the whole write path at steady
   state: admit one scrolled-off display row, then enforce the budget, 5,000
   times inside the timed region. Statistic = **median over rounds of nanoseconds
   per admitted display row**. This is the quantity a real pane pays, and it is
   the quantity whose ladder denominator is measured (see Thresholds).
2. `drain` (**verdict-bearing secondary**) -- eviction alone: admit 2,000 display
   rows with enforcement suppressed *outside* the timed region, then time one
   enforcement call that drains the charge back to the budget. Statistic =
   **median over rounds of nanoseconds per evicted display row**. This isolates
   the new term `AR1` names.

**Comparison target -- today's production eviction path, named.** Arm A
reproduces `Terminal.swift#enforceScrollbackBudget` exactly: the
`while scrollbackByteCount > scrollbackBudgetBytes || ...` loop, and per step
`ScrollbackBuffer.removeFirst()` (`Terminal.swift#removeFirst`, including the
slot-release write and `compactIfNeeded`), the `scrollbackByteCost(of:)`
subtraction, the `storedCellCount` subtraction and the `isSoftWrapped` read;
then once per call the `isHistoryHeadTruncated` write, the
`primaryHistoryObservation` bump and `Terminal.swift#handleEviction`. Its `steady`
statistic also carries `Terminal.swift#appendToScrollback` -- `PackedRetainedRow.pack`,
the buffer append and the two accumulations -- exactly as `F3`'s baseline did.
`ScrollbackBuffer`, `scrollbackByteCost` and `handleEviction` are `private` to
`Terminal`, so the arm reproduces them rather than calling them; that
substitution is this probe's stated fidelity limit, exactly as it was `F1`'s and
`F3`'s.

**Candidate -- arm B, the arena head-trim as `D2` Decision 2 specifies it.**
While the charge exceeds the budget: fold the head record from its **persisted
head cell offset** at the current width and take the offset beginning the next
display row (step 1); drop the whole record if that offset reaches its end, and
if the dropped record carried `forcedSplit`, propagate the continuation bit to
the follower and clear the follower's mark (step 2 as amended); otherwise advance
the head past those cells and rewrite the 8-byte header in place with its cell
count reduced, its semantic-mark slot cleared and the mid-line bit set (step 3);
update the head record's index offset, the head block's cached display-row total,
the grand display-row total, `evictedRowCount` and the charge (step 4 as
amended -- no anchor cache). Its `steady` statistic also carries the open-line
append `F3` measured, so the two arms' `steady` numbers cover the same work.

**Arm C -- whole-record eviction on the same arena** (`DD2` as originally
written). **Descriptive only and outside the verdict**, run as its own
interleaved B-versus-C pair in the same session at the same round count. It
exists for one purpose: if arm B rejects, arm C is the only thing that can say
whether the cost is the *granularity* (in which case the plan's `AR1` fallback is
on the table for a human) or the *arena* (in which case the fallback buys
nothing). Without it a reject would be read as evidence for a fallback nobody
measured.

#### Stimuli, with every calibration band cited to its source

All fed through a real `Terminal` at 179x66, so both arms evict rows the engine
actually produced, and all fed past the 16,777,216-byte budget
(`Terminal.swift#productionScrollbackBudgetBytes`) so eviction is sustained
rather than incidental.

1. `mix` -- `28/F23`'s measured content distribution. Band: display-row stored
   cells median in **[119, 154]**, p95 **179**. Verdict-bearing.
2. `full` -- `28/F23`'s `bound/wide-full-width-saturation`. Band: median and p95
   both **179**. Verdict-bearing.
3. `stream` -- `28/F20` Observation 5's measured `scrollback-stream` row shape.
   Band: median stored cells in **[55, 65]**, soft-wrapped fraction **0**. This
   is the class the threshold below is derived from, and the class where every
   record is one display row so every eviction step drops a whole record.
   Verdict-bearing.
4. `wrapped` -- **new here**, logical lines of 60,000 cells (91.6% of `DD3`'s
   65,536-cell cap, deliberately below it so the forced-split path does not fire
   inside the measured region), which fold to 336 display rows each at 179
   columns. Band: median display rows per logical line in **[330, 342]**,
   soft-wrapped fraction **>= 0.99**. It is the only class in which a step trims
   *inside* a record, so it is the only class that exercises the persisted head
   cell offset at all -- the term `AR1`'s correction is about, and `PO5`'s case.
   Verdict-bearing.
5. `wide` -- `F3`'s CJK generator. Band: at least **50%** of admitted rows
   contain a wide cell and at least one `.spacerHead` is present. **Descriptive
   only and outside the verdict**, for the reason `F3` gave: the bound below is
   derived from `scrollback-stream`, an ASCII CRLF workload, and no ladder
   threshold derives from wide content. It is measured anyway because the amended
   `AR1` names `O(cells in that row)` as the wide path's per-step cost, and that
   is better recorded as a number than as a caveat.

Out of band voids the run for that class, and the achieved distribution is
reported either way. The probe also reports, per class, records evicted, trim
steps taken, display rows evicted per admitted row, and the head record's mean
display-row span -- because those are what say whether a class exercised the
mechanism the verdict is about.

#### Validity gates. Any failure voids the invocation, and a void invocation is not a verdict and does not become one by re-running

1. **Per-arm fidelity, then cross-arm equivalence on the overlap.** The two arms
   do **not** retain the same depth at the same budget -- `F3` Observation 4
   measured the arena holding the same content in 0.744x-0.925x of the bytes
   today's budget charges -- so equality of the whole store is the wrong check.
   Instead: outside every timed region, each arm's retained content is read back
   display row by display row through `F1`'s walks and checksummed over every
   scalar, style id and kind, and each checksum must equal an independently
   computed expectation for the **suffix of the fed stream that arm should have
   retained**. Then, over the display rows both arms retain (the shorter suffix),
   the two checksums must be **identical**. A difference in either half means the
   arms did not evict the same content and no timing from that run may be quoted.
2. **Head-stamping fidelity.** The first retained display row of each arm reads
   as a mid-line continuation exactly when the row above it was soft-wrapped --
   today's `isHistoryHeadTruncated = lastEvictedIsSoftWrapped`
   (`Terminal.swift#enforceScrollbackBudget`) and the arena's mid-line bit
   (`D2` Decision 5) must agree on every measured round. This is the gate that
   holds the candidate to `I4`'s "carries no semantic mark" reading rather than
   letting a cheaper stamping produce a better number.
3. **Steady-state check, stated per statistic because the two timed regions
   differ.** In `steady`, each arm's evicted display rows must equal its admitted
   display rows within **1%**. In `drain`, each arm must evict at least the
   display rows its suppressed admissions added, again within **1%**. An arm that
   is not evicting is not measuring eviction, and a per-row ratio taken while one
   arm still has budget headroom is not a comparison. Out of tolerance voids the
   class.
4. **Non-elision.** Each timed round's product is consumed and cross-checked
   against an expectation computed outside the timed region: arm A's evicted row
   count, charged byte total and stored-cell total; arms B and C's head offset,
   records dropped, arena bytes in use and grand display-row total. A mismatch,
   or a zero, voids the run.
5. **Instrument resolution (A/A control).** An arm-A-versus-second-identical-arm-A
   control runs in the same session at the same round count, for every class and
   both statistics. Its |median difference| is the instrument's resolution, and a
   candidate-versus-baseline difference smaller than it is **reported as below
   resolution and read as an effect in neither direction**. An A/A control above
   **5%** voids the whole invocation, as in `F1` and `F3`.
6. **Host conditions**, as `28/F15` gated them and every probe in this doc has
   adopted: AC power, low-power mode off, one-minute load average below **2.5**
   read before and after.
7. **Complexity fidelity -- the gate this rule owes its own frozen reading.** On
   `wrapped`, the probe reports the per-step cost by quartile of a record's
   drain, and the **last quartile's median must be <= 1.20x the first
   quartile's**. *Derivation:* a step that re-folded the record from its start
   instead of from the persisted head cell offset would cost, on average, an
   eighth of the record's display rows in the first quartile against seven
   eighths in the last -- a **7x** separation. 1.20x sits an order of magnitude
   below that and well above gate 5's 5% resolution ceiling, so it discriminates
   the two shapes without being sensitive to noise. A failure here is an
   **implementation defect report, not a design verdict**: the arm measured is
   not the one `D2` Decision 2 specifies, and the run produces no verdict in
   either direction.
8. **Coverage.** Every aggregate printed beside its sample count; a quantity that
   could not be measured is reported absent rather than as 0
   (`agent-docs/measurement-discipline.md`).

#### Thresholds, and where each number comes from

- **Reject** -- candidate median **> 1.09x** arm A on **either** statistic on any
  verdict-bearing class.
  *Derivation, every input measured and none chosen here, and it is `F3`'s
  derivation applied to the other half of the same subtree:* `28/F20`
  Observation 1 sampled `benchmark/scrollback-stream` and put the write-path
  subtree -- `appendToScrollback` / `pack` / `compacted` / `scrollbackByteCost` /
  **`enforceScrollbackBudget`** -- at **19.7% of 15,578 `terminal-pty-host`
  thread samples**; `agent-docs/terminal-performance.md` puts the drain at
  **95.7%** of a `scrollback-stream` block (median over 368 archived blocks); and
  `scrollback-stream`'s frozen `confirm` directional threshold is **1.85%**, read
  from `scripts/terminal-benchmark-validation.py#DECISION_RULES` rather than from
  a reconstruction of it. The write path is therefore `0.197 x 0.957 = 18.85%` of
  the block, and `1.85 / 18.85 = 9.81%` is the write-path regression that first
  predicts a `slower` verdict -- so a candidate above **1.098x**, rounded down to
  **1.09x**, predicts `H3`'s own falsifier firing.
  *Why the same bound governs both statistics:* the 18.85% denominator covers
  admission and enforcement **together**, so the bound is exact for the `steady`
  statistic and conservative for `drain`. If eviction is a fraction `f` of that
  subtree, an eviction-only ratio `R` moves the block by `f x 18.85% x (R - 1)`,
  so holding eviction alone to 1.09x is the strictest admissible reading (`f = 1`)
  and any true `f < 1` makes it stricter than the ladder needs. A tighter bound is
  the conservative choice for a probe whose failure mode is clearing a falsifier
  too easily -- the same argument `F3` used to prefer the pre-fix share.
  *Why the pre-fix 19.7% and not the post-fix 15.9%:* unchanged from `F3` --
  the 15.9% re-sample "ran at load 13.6 and is attribution only" by `28/F20`'s
  own entry, and the larger share yields the tighter bound.
- **Confirm** -- candidate median **<= 1.00x** arm A on **both** statistics on
  **every** verdict-bearing class, or a difference smaller than gate 5's
  resolution. *Derivation:* this is `F3`'s confirm line reused, and it is a real
  possibility rather than a courtesy: the arena's step is pointer arithmetic plus
  at most one 8-byte header write against today's per-row `removeFirst` (a slot
  release, an amortized compaction check) plus `scrollbackByteCost` arithmetic
  over a packed row.
- **Neutral** -- every verdict-bearing class under 1.09x on both statistics, and
  at least one above 1.00x by more than the A/A resolution. The head-trim's added
  fold is real and is inside the tolerance the ladder can absorb.

#### Verdicts, and what each one triggers, stated now so it is not decided after the fact

Applied **exactly once** to the frozen statistics; the entry's verdict is the
worst cell across both statistics and every verdict-bearing class.

- **confirm** -- `AR1` is discharged as a priced term, `D2` Decision 2's
  head-granular eviction stands unchanged, and the plan's remaining slices
  proceed. The `DD19` sequencing is satisfied: the paired ladder verdict may then
  be read with eviction priced rather than with the campaign's largest unmeasured
  term still open.
- **neutral** -- the same, plus one recorded cost: the measured eviction
  regression is carried forward as a number the paired ladder must re-read
  against the real implementation before landing.
- **reject** -- the plan gains a **named condition**: the store does not land
  until either the eviction implementation clears this bound under **this same
  rule**, or the paired ladder comes back not-`slower` on `terminal-feed` **and**
  `scrollback-stream` against a real implementation, which is `H3`'s own
  falsifier and outranks a microbenchmark prediction. Disposition is a human
  decision, and a reject is not by itself a design failure -- `D3` Decision 1's
  diagnostic discipline applies here too.

**The `AR1` whole-record fallback, and the honest bar for taking it.** A reject
does not authorize it. All three of the following must hold, and the third is not
this rule's to satisfy:

1. reject fires on a verdict-bearing class;
2. arm C attributes it to **granularity**: head-granular exceeds whole-record on
   the same class by more than **1.09x** (the same conversion applied to the same
   subtree). If the two arena arms are within that, the cost is the arena's and
   switching granularity buys nothing;
3. a human accepts a **user-visible behavior change**. Whole-record eviction
   reintroduces `F6` `HR5`: up to **367 display rows dropped in one step** at 179
   columns and **32,768** at the 2-column minimum, moving the selection, the
   search occurrence, the hovered and armed links, the browsing viewport and the
   scrollbar further per admitted row than they move today. `D2` Decision 2
   **closed** that hazard rather than accepting it, and the plan's `I4` and `PO5`
   currently forbid it. It is therefore a decision this rule can only supply the
   number for.

On the corrected `AR1` reading the fallback is unlikely to be needed at all --
one display row per step, one pass per record across a full drain -- which is
precisely why the bar for taking it is stated before the number rather than
after.

#### The `AR6` residency reading, sequenced with this measurement

`AR6` was promoted from an accepted risk to a gate by the external review of `D2`
Decision 1: `I2` bounds **charged** bytes and `PO3`'s census can only see those,
while **resident** is capacity plus metadata once the ring's write cursor has
cycled. The two quantities diverge exactly when the ring cycles, and the eviction
measurement is what cycles it -- hence one slice, not two.

**Instrument.** `just terminal-memory-probe`
(`lib/TerminalCore/Sources/TerminalMemoryProbe/main.swift` over
`TerminalMemoryProbeSupport`) at 179x66, with `--json` for the artifact and
`--vmmap` for dirty allocator pages sampled through `whileResident`. **One
process per state** (`--payload NAME`), because the probe's own note records that
footprint deltas are attributable only in single-payload mode -- in a matrix run
every delta after the first understates its payload. Never `--chunk 0`, which
measures the parse spike rather than the resident cost.

**Four states, and what each one feeds.**

| state | how it is reached | what the reading feeds |
| --- | --- | --- |
| empty | `--payload empty`: a constructed pane fed nothing | `DD12`'s claim that an idle pane's reservation "costs nothing"; this is the only number that can support or refute it |
| partial | fed to ~50% of the charged budget | `D2` Decision 1's first-touch paragraph, which holds only until the cursor cycles |
| saturated | fed until the charge first reaches the budget and the first eviction has fired, before the cursor wraps | resident against the charged bound at the moment `PO3`'s census reports them equal |
| cycled | fed at least **two full physical wraps** of the arena | the only state `AR6`'s claim is about, and the only one the rule below reads |

**Reported per state**, each beside its sample count and with "not measured"
distinguished from zero: the `phys_footprint` delta, the `vmmap --summary`
MALLOC/dirty lines verbatim (the probe dumps rather than parses them, and that
stays), and the census's **capacity and bytes-in-use separately** (`DD11`, `D2`
Decision 1's reporting requirement).

**Control.** Today's store is measured at the **same fed inputs** in the same
session. It has no ring, so "cycled" for it means the same input, not the same
mechanism -- which is the point: the user-facing question is what a pane costs in
RAM for the same program output, and only a same-session control answers it
(`agent-docs/measurement-discipline.md`: give every comparison a control the
change cannot reach, measured in the same session).

**Gates.** Host conditions as gate 6 above; the census identity
(`charged <= budget`) must hold in the saturated and cycled states, and a failure
there is an **accounting** failure that voids the residency reading rather than
producing a residency verdict.

**The rule, frozen before the number exists.** Read on the cycled state, on the
probe's own payloads rather than on new ones: `scrollback-plain` (the short-line
shape closest to `stream`, which the derivation below shows is the worst measured
class for index charge), `scrollback-mixed` (closest to `mix`), and a blank-line
payload for the degenerate regime. Per content class:

- **Confirm, no remedy** -- resident per pane **<= 1.10x** the charged bound
  (16 MiB -> 17.6 MiB) on every measured content class. `AR6` is discharged and
  the arena's capacity stays at the budget.
  *Derivation:* `D2` Decision 1's model predicts resident = capacity + index +
  side tables. The index is 8 B per record, and over `D2` Decision 1's depth
  table with `F3` Observation 4's records-per-display-row the worst measured
  class is `stream` -- 33,825 records x 8 B = **270,600 B, 1.61%** of the budget
  (`mix` 0.46%, `wide` 0.36%, `full` 0.28%; arithmetic over quoted numbers, not
  measured). 1.10x leaves roughly 6x headroom over the largest predicted term for
  page granularity, allocator rounding and the two side tables -- the unmeasured
  constants this reading exists to pin.
- **Narrow confirm** -- above 1.10x and below **1.50x**. No remedy ships, and the
  reading is recorded as a condition on pane count, which is exactly what
  `DD12`'s reopening condition ("a real session's pane count makes the
  reservation visible in RSS") needs to be decidable.
  *Derivation:* 1.50x is `D2` Decision 1's **own** amended arithmetic worst case
  -- a 16 MiB arena plus ~8 MiB of index in the blank-record regime, 24 MiB
  against a 16 MiB charged bound -- so a content class landing at or under a
  number the design already states in the open is not a discovery.
- **Reject, the remedy ships** -- resident **>= 1.50x** the charged bound on any
  measured content class, **or** arena resident **> 1.10x** today's store's
  resident for the same fed input in the same session. Then the arena's capacity
  is sized **below** the budget by the measured index and side-table share, which
  costs depth by at most that same share -- 1.61% on the worst measured class,
  well inside `D2` Decision 1's 1.16x-1.32x depth gain -- and `PO3`'s census is
  what proves the new capacity holds.
  *Derivation of the second trigger:* `D2` Decision 1 committed to "no content
  class loses depth and no default changes"; its memory counterpart is that a
  user does not pay more RAM for the same program output, and 1.10x is the same
  instrument-and-page-granularity allowance the confirm line uses. `15/F2`'s 2.2x
  understatement is the error class being refused here: a charge model that
  describes a model rather than an allocation was wrong by 2.2x once already.
- **The blank-record arm is measured and reported but carries no trigger.** A
  reading at or above 1.5x there confirms `D2`'s arithmetic rather than
  discovering anything, and the degenerate regime -- the one
  `productionScrollbackRowCap` used to bound and this design deletes -- is a
  human's disposition, recorded as a named condition rather than acted on by this
  rule.

#### What this measurement does not see, stated so the entry is not over-read

The parse and grid work preceding admission, so this is not `terminal-feed`'s or
`scrollback-stream`'s block; **scheduling**, which is where `28/F20`'s residual
may actually live and which no probe in this doc touches; the read path (`F1`'s);
the width-change counting pass (`F2`'s, `F7`'s, and `D3` Decision 7's for wide
content); the resize refold, which survives this design; the **side tables**
(`hyperlinkId`, `contentIdentity`), stripped from both arms exactly as `F1` and
`F3` stripped them and conservative toward the baseline for `F3`'s reason -- under
the candidate an identity run table is built once per logical line rather than
once per display row; the **forced-split path** (`I10`, `DD20`), which `wrapped`
is deliberately sized below; multi-pane residency, since one pane is measured per
process; and correctness beyond the gates above, which is `PO5`, `PO12` and
`PO13`'s.

**A stated fidelity limit of the instrument itself:** production amortizes
`enforceScrollbackBudget` over a batch of scrolled-off rows, while the `steady`
statistic calls enforcement once per admitted row. Both arms are treated
identically, so the ratio is fair; the absolute nanoseconds-per-row figures carry
the loop prologue once per row and are upper bounds.

#### Ratifications and new deferred decisions

- **`DD2`'s amendment is not reopened.** This rule prices `D2` Decision 2's
  head-granular eviction; it does not re-litigate the choice, and arm C is
  descriptive unless the reject bound fires.
- **DD21 -- the rule adds a fifth stimulus class (`wrapped`) that `F3`'s four do
  not cover.** `mix`, `full`, `stream` and `wide` fold to a handful of display
  rows per record (and `stream` to exactly one), so under all four an eviction
  step almost always drops a whole record and the **persisted head cell offset is
  never exercised** -- the very term the amended `AR1` and gate 7 are about. The
  alternative, reusing `F3`'s four unchanged, is simpler and would leave the rule
  unable to see the mechanism it was written to price. Reopen if the class cannot
  be produced through a real `Terminal` at 179 columns, in which case it is built
  synthetically under `F2` gate 2's fidelity discipline and said so.
- **DD22 -- the verdict-bearing primary is the write path per admitted row, with
  eviction alone as the second bound rather than the only one.** The gate names
  eviction, and eviction alone is reported; but `28/F20`'s 19.7% is the only
  measured denominator in the corpus and it covers admission and enforcement
  **together**, so a bound derived from it is exact for the pair and merely
  conservative for the half. Reporting both keeps the exact conversion and the
  isolated term without choosing between them. Reopen if a future profile splits
  the subtree, which would give eviction its own share and its own exact bound.
