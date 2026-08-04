# Findings -- logical-line scrollback (doc 31)

Append-only evidence chain for
[31-logical-line-scrollback](README.md); the contract is
[../FORMAT.md](../FORMAT.md). Cross-file citations are qualified (`28/F23` is
doc 28's); bare IDs are this doc's.

Reserved by the Phase 1 ledger and not yet run:

- **F2** -- the eager counting pass at 10,000 and 100,000 lines.
- **F3** -- the admission probe: open-line append vs row-record admission.
- **F4** -- the edge-case inventory mined from `references/`, cited
  `file#identifier`.

### F1 -- the read path is not the hazard: wrap-at-read browses 1.64x faster than today's store, and random seek is faster too

- Status: recorded. This is the go/no-go input `31/D1` Part A decides on, and
  it answers `H1`'s falsifier in the opposite direction from the one the
  hypothesis was written to guard against. **It settles the read path only.**
  Nothing here licenses a production storage change; `F2`, `F3`, `F4` and the
  simplification inequality are all still owed, and `28/H7` remains the
  fallback until D1 closes.
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: `eee1832` (the commit that froze `D1`'s rule,
  written before this probe existed in the tree), plus the one file this entry
  adds --
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineReadProbe.swift`,
  committed with it. **No file under `lib/TerminalCore/Sources/` is touched.**
  Two untracked paths were present and are in no build: `TODO.md` and
  `docs/scratch/2026-08-04-scroll-sample-breakdown.md`.
- Conditions: AC power, low-power mode off. One-minute load average 1.48 before
  the quoted invocation and 1.44 after, both under the 2.5 gate `28/F15`
  established and `D1` adopted. Release configuration, headless, one process.
- Commands:

      DANTERM_LOGICAL_LINE_PROBE=1 swift test -c release \
          --package-path lib/TerminalCore --filter TerminalLogicalLineReadProbe

- Artifacts: none durable. Every number below is stdout from the probe above and
  is reproduced by re-running it; the probe prints its own gate outcomes.

#### What was compared

Both arms are built from **one** `RetainedStimulus`: the display rows a real
`Terminal` at 179x66 actually retained, taken through
`retainedRowForTesting(at:)`, with the logical lines recovered from those rows
by joining on `isSoftWrapped`. So the candidate stores exactly the cells the
baseline stores -- this is a comparison of storage shape, not of two wrap
implementations.

- **Baseline** -- today's shape: one `Terminal.PackedRetainedRow` per display
  row, produced by the production `pack`, addressed at an O(1) index, read
  through the production `forEachKind` + `forEachContentCell` walks
  (`28/F17`'s two readers). `ScrollbackBuffer` is `private` to `Terminal`, so
  the arm reproduces its element type, readers and index arithmetic rather than
  calling it. That substitution is F1's stated fidelity limit.
- **Candidate** -- doc 31's sketch: one contiguous byte arena of
  variable-length logical-line records (8-byte header carrying cell count and
  flags, then C1 cell words verbatim), plus the derived block index (per-line
  record offsets, 256 lines per block, one cached display-row total per block);
  display-row lookup is a binary search over block totals then an in-block scan
  that reads each line's cell count out of its record header.

#### Observation 1 -- the four measured cells, and the verdict D1's rule reads off them

Median over 5 ABBA rounds of nanoseconds per display-row read, at ~10,000
display rows and 179 columns. Sample counts: 19,800 reads per browse round,
20,000 per seek round.

| pattern | class | baseline | candidate | ratio | A/A control | `D1` rule | result |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| sequential browse | `mix` | 882.3 ns | **536.3 ns** | **0.608x** | -0.64% | <= 1.20x | pass |
| sequential browse | `full` | 1,270.4 ns | **774.7 ns** | **0.610x** | -0.43% | <= 1.20x | pass |
| random seek | `mix` | 915.3 ns | **822.3 ns** | **0.898x** | +0.21% | <= 3.0x, <= 5.0 us | pass |
| random seek | `full` | 1,361.0 ns | **1,092.7 ns** | **0.803x** | -0.88% | <= 3.0x, <= 5.0 us | pass |

Every A/A control is under 1%, so all four differences are an order of
magnitude outside the instrument's resolution. Random seek's absolutes -- 0.82
and 1.09 us -- are 4.6x and 3.4x inside `D1`'s 5.0 us bound.

All five validity gates held on the quoted invocation:

1. **Cross-arm checksums identical** on all four measured patterns, so the arms
   provably read the same scalars, style ids and kinds in the same order.
2. **Stimulus calibration:** `mix` measured display-row cell counts at median
   **149**, p95 **179**, mean 124.2 -- inside `28/F23`'s band ([119, 154] /
   179) and near its pooled real-corpus mean of 128.3. `full` is 179 flat.
   `mix`'s length distribution was tuned against this gate alone, before any
   arm was timed.
3. **A/A resolution:** -0.64% / +0.21% / -0.43% / -0.88%, all far under the 5%
   ceiling.
4. **Host conditions** as recorded above.
5. **Coverage:** every aggregate printed with its sample count; the wrap check
   (below) reports a reason string rather than a silent pass.

**One earlier invocation was discarded unread of its verdict, and is recorded
rather than hidden.** It read an A/A control of **-6.91%** on `mix`/random
seek, above `D1`'s 5% ceiling, which voids the whole invocation by the frozen
rule. Its four ratios were 0.606x / 0.889x / 0.605x / 0.816x -- materially the
same as the quoted run, which is why the discard costs nothing but is reported
anyway: a rule that is only honoured when it would change the answer is not a
rule. A third invocation, taken while the descriptive sweep test ran
concurrently in the same process, read 0.597x / 0.896x / 0.594x / 0.787x. The
ratios reproduce across all three; only the quoted one is a valid invocation.

#### Observation 2 -- the wrap arithmetic is exact, which is the design's premise and not only its performance

`verifyWrapArithmetic` reported `ok` for both classes: the candidate's derived
display-row count equals the engine's retained row count (10,000 on both), and
`ceil(cells / 179)` reproduces the engine's own display-row count **for every
one of the 5,758 (`mix`) and 5,013 (`full`) logical lines**. Nothing
width-dependent is stored anywhere in the candidate; the index was built by one
eager pass and only read thereafter.

That is a small but real confirmation of the premise `H4` will be tested
against properly in `F4`: for this content, unwrapping history and re-wrapping
it at the same width is lossless and needs no stored wrap state. It says
nothing yet about wide characters at the last column, which `F4` owns.

Arena sizes, reported for `F2`'s and Phase 2's benefit: 9.98 MB (`mix`) and
14.36 MB (`full`) for 10,000 display rows. The `full` figure sits within 3% of
`28/F23`'s independently measured 14.80 MiB charge for the same content class
at the same depth, which is a useful cross-check that the two probes are
holding the same amount of content.

#### Observation 3 -- the leading competing interpretation was measured, and refuted

The obvious deflation of a 1.64x browse win is that it is not about storage
shape at all: `ScrollbackBuffer`'s subscript returns a `PackedRetainedRow` **by
value**, and that struct owns two Swift arrays, so every row read could be
paying a retain/release pair the arena never pays. If that dominated, the win
would be recoverable inside today's design with a borrowing accessor and no
storage change whatsoever -- which would make this finding an argument for a
one-line fix rather than for a redesign.

Measured directly, as a descriptive third arm outside `D1`'s rule: the same
baseline store, the same walks, the row borrowed in place through
`withUnsafeBufferPointer` instead of copied out.

| class | copying (today's shape) | borrowed | ratio |
| --- | ---: | ---: | ---: |
| `mix` | 881.5 ns | 890.7 ns | 1.010x |
| `full` | 1,269.6 ns | 1,276.8 ns | 1.006x |

Borrowing is **not faster** -- if anything marginally slower, and within
resolution of zero either way. The per-read copy is not where the difference
lives, so the competing interpretation is refuted and the remaining mechanism
is the one the design predicted: 10,000 separately allocated row blobs read
through a pointer indirection versus one contiguous region walked forward.

#### Observation 4 -- what the block index costs, descriptively

Outside `D1`'s rule, which is frozen at the design's stated ~256 lines per
block. Random seek only, 20,000 seeks, same stimulus:

| blockSize | `mix` ns/seek | `full` ns/seek |
| ---: | ---: | ---: |
| 32 | 677.5 | 1,029.5 |
| 64 | 697.4 | 959.1 |
| 128 | 800.9 | 1,018.4 |
| 256 | 870.0 | 1,166.6 |
| 1,024 | 1,544.6 | 1,873.9 |

The in-block scan is a real term: 32 -> 1,024 lines per block costs 2.3x on
`mix`. At the rule's 256 the candidate is still faster than the baseline's
O(1)-indexed read, and 64 would buy roughly another 170 ns/seek if a later
finding ever needs it. This exists so a future `narrow-go` on seek has a
measured starting point instead of a guess about which way to move the
parameter.

- Observation: at ~10,000 display rows and 179 columns, the logical-line arena
  plus derived block index reads **faster** than today's per-display-row packed
  store on both access patterns and both content classes -- 0.608x/0.610x on
  sequential browse and 0.898x/0.803x on random seek -- with A/A controls under
  1%, identical cross-arm checksums, and exact wrap arithmetic on all 10,773
  logical lines measured.
- Inference: `H1` is confirmed, and its competing explanation is refuted.
  The added wrap-at-read indirection does not give back `28/F17`'s win; it does
  not cost anything measurable at all. The mechanism the numbers support is
  memory layout: today's store is 10,000 separate heap blobs and the arena is
  one contiguous region, so a sequential browse walks forward through prefetched
  memory instead of chasing a pointer per row. The per-frame index lookup is
  amortized over 66 rows and disappears; even unamortized (random seek) the
  binary search plus in-block scan costs less than the allocation-chasing it
  replaces.
- Competing interpretations:
  1. *ARC on the per-read row copy, not layout.* **Measured and refuted** --
     Observation 3.
  2. *The arms differ in what they store, not how.* Both lost `hyperlinkId` and
     `contentIdentity`, so neither carries a side table. That strips a real
     candidate advantage (under the candidate an identity run table would be
     built once per logical line rather than once per display row), so it is
     conservative toward the baseline, and the cross-arm checksum proves the
     cells read are identical.
  3. *The baseline arm is not `ScrollbackBuffer`.* It reproduces the buffer's
     element type, readers and index arithmetic rather than calling it, because
     the type is `private`. A behavioral difference between the two would have
     to live in code the arm does not contain -- the subscript is three lines --
     but this is the entry's largest fidelity limit and is named as such.
  4. *A microbenchmark is not a frame.* This measures the read walk in
     isolation. `D1`'s 1.20x threshold was derived by converting a read-walk
     change into a `retained-browse` frame change through `28/F17`'s ~5.2%
     share; the same conversion says a 0.61x read is worth roughly -2% at the
     frame, which is a prediction this entry does **not** claim to have
     verified. Only the paired `retained-browse` ladder can, and only against a
     real implementation.
- Uncertainty:
  - **Depth.** Measured at one depth (~10,000 display rows). The candidate's
    seek cost is O(log blocks) + O(blockSize) and so should be depth-robust,
    but that is an argument, not a measurement. The baseline's O(1) index does
    not degrade with depth either, so the ratio could move in either direction
    at 100,000 rows.
  - **Content.** ASCII, single-scalar cells, no hyperlinks, no wide characters,
    no spills. The arena prototype has no spill table at all and calls
    `fatalError` if the stimulus produces a multi-scalar cell, precisely so a
    silent encoding difference cannot appear as a speed difference. Real
    history has spills in ~0.12% of rows (`28/F11`).
  - **The prototype is not a store.** It has no admission path, no eviction, no
    open-line rule, no forced split, and no side tables. `F3` measures
    admission; eviction from the front of an arena is Phase 2's problem and is
    not priced anywhere yet.
  - This entry cannot see anything about resize, which is the whole reason the
    design exists. `F2` owns that.
- Next action: `D1` Part A's verdict is recorded in
  [decisions.md](decisions.md) as **go (read path)**. The Phase 1 ledger
  continues with `F2` (the eager counting pass at depth), then `F3`
  (admission), then `F4` (the edge-case inventory, which can still make D1
  no-go). Two things this entry hands forward: the `blockSize` sweep in
  Observation 4 is the starting point if seek cost ever becomes the binding
  constraint, and `F2` can reuse this probe's `LogicalLineArena.recomputeIndex`
  directly -- it is the eager pass H2 describes.

### F2 -- the eager counting pass is 0.016 ms at trial depth and 0.64 ms at 100,000 lines, 15x inside H2's bound

- Status: complete. `H2` **confirmed** under `31/D1`'s Part B rule, frozen at
  `497d181` before this probe existed in the tree. This is a Part B input to
  `D1`; it cannot and does not move `D1`'s direction (the rule says so
  explicitly), and it does not open Phase 2.
- Date and investigator: 2026-08-04, agent.
- Commit and worktree state: measured at `497d181` plus the one file this
  finding adds (`TerminalLogicalLineIndexProbe.swift`) and the three members it
  needed on `F1`'s arena (a synthetic initializer, a second counting-pass
  variant, and the independent cross-check total). No file under
  `lib/TerminalCore/Sources/` is touched; `F1`'s arms are unedited.
- Commands, inputs, or reproduction:

      DANTERM_LOGICAL_LINE_PROBE=1 swift test -c release --package-path lib/TerminalCore \
        --filter TerminalLogicalLineIndexProbe

  Conditions: AC power, low-power mode off, one-minute load average **1.49
  before and 1.49 after**. 9 measured rounds plus 2 warmup per cell; statistic
  is the median over rounds of one whole pass, min and max and `n` beside every
  aggregate.

#### What was measured

One call of the eager recompute: discard every cached block total and rebuild
`blockPrefix` for a new width, reading one cell count per logical line and doing
one divide. Nothing else is inside the timed region.

`31/D1` named two count-sources, and the difference between them is the whole
cost:

- `arena` (**primary**) -- the count is read from each line's record header
  through `lineOffsets`, which is what the candidate direction sketches: the
  index stores offsets and the count lives in the record. A strided chase across
  the whole arena.
- `counts` (**alternative**) -- the count is read from a dense parallel array,
  which is what `F1`'s prototype happened to do. A sequential scan of
  `8 x lineCount` bytes, bought with 8 bytes per line of extra index state.

#### Observation 1 -- the measured passes, and the bound D1 reads them against

Median milliseconds per whole pass, primary `arena` source, `n=9` per cell.
10,000-line figures are the real-engine arena; 100,000-line figures are the
synthetic one (gate 2 below).

| class | width change | 10,000 lines | 100,000 lines |
| --- | --- | ---: | ---: |
| `mix` | 179 -> 179 | 0.016 ms | 0.547 ms |
| `mix` | 179 -> 100 | 0.015 ms | 0.550 ms |
| `mix` | 179 -> 200 | 0.015 ms | 0.545 ms |
| `full` | 179 -> 179 | 0.016 ms | 0.557 ms |
| `full` | 179 -> 100 | 0.016 ms | 0.639 ms |
| `full` | 179 -> 200 | 0.016 ms | 0.641 ms |

The `counts` alternative, same cells: **0.013 ms** at 10,000 lines in every one
of the six, and 0.127-0.136 ms at 100,000.

Read against `31/D1`'s frozen thresholds:

- **Confirm H2** required the 100,000-line median at or under **10.0 ms** on
  both classes and both width changes. Worst cell measured: **0.641 ms**. Passes
  with a 15.6x margin.
- **Reject** required 10,000 lines at or above **16.67 ms** (one 60 Hz frame).
  Worst cell measured: **0.016 ms**, about 1,000x under the line. Nowhere near
  rejection.
- The narrow-confirm band is not entered.

So: **H2 confirmed, eager recompute stands for milestone 1, and the lazy
per-block alternative stays in Rejected.** The primary count-source clears the
bound on its own, so the design does *not* need the parallel counts array --
that is the one Phase 2 input this entry produces.

For scale against what the pass replaces: 10,000 logical lines of `mix` content
is **17,248 display rows** at 179 columns, 1.72x the depth `28/F23` priced at a
600.5 ms synchronous reflow. The counting pass over it is 0.016 ms. The
comparison is a division between two separately measured numbers, not a paired
measurement, so treat the ratio as an order of magnitude (about 4 orders) rather
than a figure.

#### Observation 2 -- the gates

1. **Non-elision.** Every timed pass's total was cross-checked against a sum
   computed by an unblocked route; all 324 passes in the primary measurement
   matched, as did the ladder's 108, and no total was zero. The totals themselves are reported (`mix` at 179: 17,248 display rows
   from 10,000 lines; at 100: 26,498; at 200: 15,892 -- the pass responds to
   width, which is what it is for). A counting loop is exactly what an optimizer
   deletes, and this gate is why the numbers above are of a loop that ran.
2. **Synthetic-stimulus fidelity.** The 10,000-line arena was built both ways --
   through `F1`'s real-engine `buildStimulus` and synthetically from the same
   per-line counts -- and both were measured in every cell. Ratios spanned
   **0.975x to 1.062x**, inside the 15% the rule allows, and the two arenas
   agreed exactly on byte count and line count. The synthetic extension to
   100,000 lines is therefore admissible.
3. **Host conditions.** Load 1.49 before and after, AC power, low-power off.
   **One earlier invocation was discarded, and is recorded rather than
   hidden**: it read load 2.97 before and after, above the 2.5 the rule freezes,
   because `swift test` compiled the newly added file in the same command and
   the probe then measured itself under its own build. Its numbers were within a
   few percent of the ones above, which is exactly why discarding it had to be
   automatic -- a gate that is only honoured when it would change the answer is
   not a gate. The quoted run pre-builds and waits for the machine to settle.
4. **Coverage.** `n=9` beside every median, with min and max.

#### Observation 3 -- the cost per line is not constant with depth, measured rather than interpolated

Descriptive ladder, width 179 -> 100, nanoseconds per logical line:

| class | source | 10,000 | 30,000 | 100,000 |
| --- | --- | ---: | ---: | ---: |
| `mix` | `arena` | 1.60 | 1.70 | 5.49 |
| `mix` | `counts` | 0.68 | 0.68 | 0.68 |
| `full` | `arena` | 1.57 | 2.17 | 5.50 |
| `full` | `counts` | 0.68 | 0.72 | 0.68 |

The middle point was measured rather than assumed, because two points would not
have shown that the `arena` source's per-line cost is flat to 30,000 lines and
then roughly triples by 100,000 while `counts` stays flat throughout. The
mechanism this is consistent with is cache residency: at 100,000 lines the arena
is 172 MB (`mix`) or 287 MB (`full`) and the header chase touches one line per
~2.9 KB of it, while the dense counts array is 800 KB at the same depth and
stays resident. This is an explanation the data fits, not an attributed cause --
no counter was read.

A depth where this matters is far away and probably unreachable: at 100,000
lines of wide content the arena is 172-287 MB, which the 10 MiB byte budget
(`28/F23`: peak 3.38 MB observed) would have evicted from long before. **H2's
100,000-line bound therefore stresses a depth the current byte budget makes
unreachable**, which is the right way to test a bound and the wrong way to
describe a workload.

#### Observation 4 -- an instrument caveat, recorded because it is visible in the numbers

The `counts` source reads 0.013 ms at 10,000 lines in the main measurement and
0.007 ms in the ladder, at the same depth and width. The difference is that the
main measurement holds a 172-287 MB neighbour arena resident while it measures
the small ones and the ladder does not. Both are three orders of magnitude
inside every bound, so nothing here turns on it -- but it is the size of the
effect memory pressure has on this instrument, and a future reading that wants
tighter resolution than that should not take these cells as interchangeable.

- Observation: the eager block-total recompute costs 0.015-0.016 ms at 10,000
  logical lines and 0.545-0.641 ms at 100,000, for the count-source the
  candidate direction actually sketches, at both content classes and for
  narrowing, widening and same-width rebuilds.
- Inference: `H2` holds. Recounting display rows is cheap enough that a resize
  under this design has no meaningful history-side cost, which is the property
  the whole doc trades reflow away for. The eager choice needs no defence at
  milestone 1, and the index can stay as sketched -- offsets only, no parallel
  counts array.
- Competing interpretations:
  - *The loop was optimized away.* Refuted by gate 1: every pass's total was
    consumed and cross-checked, and the totals differ correctly by width.
  - *The synthetic arena is not the real one.* It is not, and that is why gate 2
    exists: at the depth where both can be built they agree within 6.2%. What
    the synthetic arena reproduces is geometry -- record sizes, header offsets,
    total footprint -- which is all the counting pass touches.
  - *This is fast because the stimulus is small.* The ladder is the answer: the
    per-line cost does grow, and it is still 0.64 ms at a depth the byte budget
    makes unreachable.
  - *A microbenchmark is not a resize.* Correct, and this entry does not claim
    otherwise -- see Uncertainty.
- Uncertainty:
  - **The pass is not the resize.** A resize also refolds the live screen, which
    this design does not remove and this probe does not measure. F2 prices the
    term the design deletes reflow *into*, not the whole event.
  - **No lookup follows the recompute here.** The index is rebuilt and then
    thrown away; a real width change is followed by reads, which Part A measured
    separately and which this entry does not compose with.
  - **Nothing about eviction.** An arena that has evicted from its front has a
    different offset structure than one that only ever grew. Unmeasured.
  - **One machine, one session.** As with `F1`.
- Next action: `D1` Part B advances -- `F2` is in, `F3` (admission) and `F4`
  (the edge-case inventory, which can still make `D1` no-go) remain. Two things
  this entry hands forward: keep the index offsets-only (the primary
  count-source clears the bound without the parallel array), and if a future
  design does want the counts array, this entry has already priced what it buys
  (4.3x on the pass at 100,000 lines, nothing that matters at trial depth).
