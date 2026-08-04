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

### F4 -- 28 edge cases, none requiring stored width, and one arithmetic correction: `ceil(cells / width)` is wrong for lines containing wide cells

- Status: recorded. This is `D1` Part B's third input and the only Phase 1
  input that could have made `D1` no-go regardless of `F1`. **It does not.** No
  case in the inventory requires width-dependent data persisted in history, so
  `H4` is confirmed and the premise survives. What the sweep does produce is one
  correction to the *mechanism* `H1` stated -- display-row count is not
  `ceil(cells / width)` for a line containing wide cells -- and it is a change
  to the derivation, not to what is stored.
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: `dbe42f2`, the commit that recorded `F2`. **No
  file under `lib/` is added or changed by this entry** -- it is a reading and
  cataloguing pass. The two untracked paths present throughout this doc's work
  are still present and still in no build: `TODO.md` and
  `docs/scratch/2026-08-04-scroll-sample-breakdown.md`.
- Commands, inputs, or reproduction: the reference trees were read at the pins
  `just fetch-references --list` records, and DanTerm's own reflow behavior was
  read from `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` and its
  resize/wrap test suites. Observation 1's counter-example was executed against
  the real engine through a throwaway test in
  `lib/TerminalCore/Tests/TerminalCoreTests/`, deleted before this commit; its
  body is quoted below so the reading is reproducible from the doc alone.
- Artifacts: none durable.

#### What was swept

Seven implementations, chosen because most store display rows and rewrap
destructively while iTerm2 -- the doc's stated existence proof -- stores raw
lines and wraps at read, which is this design's category:

`references/iterm2/sources/LineBlock.mm`, `references/kitty/kitty/resize.c`,
`references/foot/grid.c#grid_resize_and_reflow`,
`references/wezterm/term/src/screen.rs#rewrap_lines`,
`references/vte/src/vte.cc`,
`references/windows-terminal/src/buffer/out/textBuffer.cpp#TextBuffer::Reflow`,
`references/alacritty/alacritty_terminal/src/grid/resize.rs`. Plus DanTerm's own
reflow -- `Terminal.swift#reconstructLogicalLines` and `Terminal.swift#pack`,
which already build and repack logical lines, destructively, at every width
change -- and the tests that pin it.

One correction to the README's framing fell out of the sweep and is recorded
rather than left standing: **vte is a second, partial member of the category.**
Its scrollback is a UTF-8 text stream plus an attr stream, and the wrap points
live in a separate row stream that `references/vte/src/ring.hh`'s own comment
describes as "(This stream is regenerated when the contents rewrap on resize.)"
-- so vte's *stored text* is already width-free, exactly as this design wants.
What vte does not do is defer the regeneration: `references/vte/src/ring.cc#Ring::rewrap`
rebuilds the row stream eagerly at resize instead of deriving wrap points at
read. It is therefore the halfway house between today's DanTerm and this doc's
candidate, and it is the closest thing in the sweep to a working reference for
the record format -- including for the parts iTerm2 gets to skip.

DanTerm's existing engine is the most important source in the sweep and is
easily overlooked: **`reconstructLogicalLines` is the admission rule this design
proposes, run backwards.** It joins display rows on `isSoftWrapped`, measures a
soft-wrapped row to full width and a hard-ended row to `retainedContentEnd`,
drops `.spacerHead` cells entirely, and carries one `semanticPrompt` per logical
line. That is exactly the record the arena would store. The design is therefore
not introducing a new normal form; it is deleting the round trip that converts
to it and back on every resize.

#### Observation 1 -- the one correction: display-row count is not `ceil(cells / width)` when the line contains wide cells

`H1` and `F2` both state the mechanism as "per-line display-row counts derived
as `ceil(cells / width)` from the record header". For narrow content that is
exact -- `F1` Observation 2 verified it on all 10,773 logical lines it measured,
and said in terms that it "says nothing yet about wide characters at the last
column, which `F4` owns". It is wrong for wide content, and the counter-example
is small:

    var t = try #require(Terminal(columns: 3, rows: 40))
    t.feed(Array("\u{754C}\u{754C}\u{754C}".utf8))   // three 2-cell clusters, 6 cells

Measured against the real engine: **3 display rows, where `ceil(6 / 3)` predicts
2.** Five wide clusters (10 cells) at width 3 measure 5 rows against a predicted
4. Narrow content and wide content that happens to divide evenly both match, so
this is not a case a casual check finds.

The mechanism is `Terminal.swift#pack`, and it is deliberate:

    if unit.cells.count == 2, columns - column == 1 {
        packedRows[row].cells[column] = GridCell(kind: .spacerHead, ...)
        packedRows[row].isSoftWrapped = true

A 2-cell cluster that meets a row with one column left does not split; a
`.spacerHead` fills the column and the cluster starts the next row. The exact
count is `ceil((cells + spacers) / width)`, and `spacers` -- the number of wide
clusters that land on a boundary -- is a function of *where* the wide cells sit,
so it needs a scan of the record's cells, not a read of its header.

**This is a derivation change, not a storage change.** `spacers` is computed from
(logical line, width) exactly as the design requires; nothing width-dependent is
persisted. Every surveyed implementation that wraps at read pays the same price
in the same place: iTerm2 splits precisely here, with
`references/iterm2/sources/LineBlock.mm#LineBlockNumberOfFullLinesFastPath`
(`MAX(0, length - 1) / width`, i.e. `ceil`) guarded by a flag, falling through
to `references/iterm2/sources/LineBlock.mm#iTermLineBlockNumberOfFullLinesImpl`,
whose whole body is the correction:

    for (int i = width; i < length; i += width) {
        if (ScreenCharIsDWC_RIGHT(buffer[i])) { --i; }
        ++fullLines;
    }

vte reaches the same place from the other side, and its version is worth having
because it shows the correction is intrinsic to the content rather than to
iTerm2's data structure: `references/vte/src/ring.cc#Ring::rewrap` wraps *early*
rather than padding --

    if (col >= columns - attr_change.attr.columns() + 1) {
        /* Wrap now */
        new_record.width = col;
        new_record.soft_wrapped = 1;

-- and records the short `width` on the row. No spacer is stored either way; the
display row is simply narrower than the terminal, which is the same statement as
"the count is not `ceil(cells / width)`".

The intended DanTerm behavior is the same split, with one deliberate divergence.
iTerm2's `mayHaveDoubleWidthCharacter` is a **sticky, buffer-wide, one-way**
flag (`references/iterm2/sources/LineBuffer.m#setMayHaveDoubleWidthCharacter:`
sets it and never clears it, and
`references/iterm2/sources/iTermLineBlockArray.m#setAllBlocksMayHaveDoubleWidthCharacters`
then discards every cached width count), so one CJK character anywhere
permanently downgrades the entire buffer to the scanning path -- which is why
iTerm2 needs three further layers of memoization
(`LineBlock.mm`'s `_numberOfFullLinesCache`, `LineBlockMetadata`'s
`number_of_wrapped_lines`, and
`references/iterm2/sources/iTermDoubleWidthCharacterCache.h`) to make it
tolerable. DanTerm should carry the bit **per record**, in the header flags the
sketch already has: it is a property of one logical line's content, it is known
at admission for free (the admitting row's cells are in hand), and it is
width-independent, so a width change never invalidates it. A record without the
bit keeps the O(1) `ceil`; a record with it pays an O(cells) scan.

The bit is an optimization, not a correctness requirement -- always scanning
would also be correct -- which is the strongest form this finding can take
against `D1`'s no-go trigger: the correction does not even need a stored flag,
let alone stored width.

#### Observation 2 -- the inventory

28 cases. `stored width?` answers `D1`'s no-go trigger directly: **`yes` means
the case is decidable from (logical line, width) plus live-grid state; `flag`
means it additionally wants a width-independent content bit in the record
header; `NO` would be a no-go trigger.** There are no `NO` rows.

| # | input / scenario | intended DanTerm behavior under the logical-line store | stored width? |
| ---: | --- | --- | :---: |
| 1 | wide cluster meets a row with one column left | insert `.spacerHead` at read/refold time, start the cluster on the next display row; never store the spacer | yes |
| 2 | display-row count of a line containing wide cells | `ceil((cells + spacers) / width)`; scan the record when its `hasWideCells` header bit is set, `ceil(cells / width)` otherwise (Observation 1) | flag |
| 3 | cluster wider than the whole pane | unreachable: `Terminal.swift#resize` refuses `columns < 2` and `desiredClusterWidth` caps a cluster at 2 cells. Keep the guard rather than adopting a policy | yes |
| 4 | VS16 upgrades a placed narrow cluster to 2 cells at the last column | live-grid concern only; the relocation happens before the row can scroll off, so history sees the settled cells | yes |
| 5 | multi-scalar grapheme cluster at a wrap boundary | a cluster is one cell (plus its tail), so it is atomic in the record and can never straddle a boundary | yes |
| 6 | cursor sits on a soft-wrapped line during a width change | refold the live screen only; the cursor never anchors into history because a row the cursor is on has not scrolled off | yes |
| 7 | pending wrap (`isPendingWrap`) armed at a width change | live-screen refold keeps today's boundary-anchor rule; `Terminal.swift#pack`'s `boundaryDestinations` moves to the refold, unchanged | yes |
| 8 | cursor parked in trailing blanks past the content end | live-screen refold keeps today's `.trailingPadding` distance rule, including the "squeezed-out trailing blank defers its wrap" clamp | yes |
| 9 | the wrap claim on the last retained row is severed or restored | flip the tail record's open/closed header bit: severing closes the open line, restoring reopens it. No cell is rewritten, and only the tail is touched | yes |
| 10 | a `.spacerHead` on the last retained row is cleared | no-op: the store never held the spacer | yes |
| 11 | alternate screen, width change | never reflowed; clip and pad the rectangle as `Terminal.swift#resizedRectangle` does today. Unaffected by this design | yes |
| 12 | alternate screen, scrollback admission | never admitted; the alt seam in `ScrollbackBuffer`'s reader stays as it is | yes |
| 13 | selection endpoints across a width change | remap through (logical line, cell offset), which becomes the *native* address instead of a transient reflow attachment | yes |
| 14 | search range and hovered/armed hyperlink ranges across a width change | same remap as 13; the four attachment computations in `resizeWidth` collapse into one address conversion | yes |
| 15 | browsing viewport anchor (scroll anchoring) across a width change | content-anchored, as today: the anchor is the top row's first cell, expressed as (logical line, offset) | yes |
| 16 | OSC 133 marks and `.continuation` stamping across a width change | one semantic mark per record (the header's mark slot); continuation rows are stamped at read, as `Terminal.swift#pack` already does | yes |
| 17 | trailing blanks: hard-ended row vs soft-wrapped row | admission measures a soft-wrapped row to full width and a hard-ended row to `retainedContentEnd`, exactly `reconstructLogicalLines`'s rule | yes |
| 18 | two hard-ended lines must not join when widening | two records; a record boundary is a hard newline by construction, so the failure mode is unrepresentable rather than merely tested against | yes |
| 19 | interior spaces of a continued row survive a narrowing | they are ordinary cells in the record; nothing distinguishes them from text | yes |
| 20 | a row emptied mid-line (prompt blanking) must not splice its old width into the next reflow | strictly removed: once a row is admitted its cells are frozen, so no later width change re-measures it. The live-screen rule still applies to rows that have not scrolled off | yes |
| 21 | DECAWM off, printing at the right margin | the row never soft-wraps, so it closes a record at its retained content end; measured: `"\u{1B}[?7l0123456789"` at 5 columns retains `01239` and no wrap flag | yes |
| 22 | hard tabs | already resolved to cursor motion at parse time (`Terminal.swift#execute`, `0x09`); history stores cells, never a tab | yes |
| 23 | styles, BCE padding, wide tails and spacers synthesized at a new width | style ids travel with cells; the synthesized wide tail and spacer inherit the head's style, as `reflowSynthesizesCoherentWideTailsAndSpacerHeads` pins | yes |
| 24 | DECDWL / DECDHL line attributes | not supported by DanTerm and not proposed here. If added, the attribute is a per-line content property that belongs in the record header, still not a stored width | yes |
| 25 | a single logical line with no hard newline, longer than history | one record that grows until the forced-split cap; no reference caps this (Observation 3) | yes |
| 26 | the forced-split cap itself | split at a fixed cell count with a `forcedSplit` header bit so copy, search and text extraction rejoin logically (Observation 3) | flag |
| 27 | eviction at the head of the arena | evict whole records. The head-truncation flag `isHistoryHeadTruncated` becomes always-false, and the budget can undershoot by at most one record, which the cap bounds (deferred decision DD2) | yes |
| 28 | degenerate history of blank rows | blank rows fold into records with near-zero cells, so the byte budget bounds them directly. This is the regime `productionScrollbackRowCap` exists for, and the row cap is on the deletion list | yes |

#### Observation 3 -- the forced-split cap: no reference caps a logical line, so the cap is DanTerm's own bound and needs its own derivation

The README proposes 65,536 cells "to be justified or replaced in F4". The sweep
found **no implementation that caps the length of a single logical line or the
number of display rows one may span.** What each has instead is an aggregate
bound the long line simply consumes:

- iTerm2 grows a block to fit: `references/iterm2/sources/LineBuffer.m#reallyAppendLine:length:partial:width:metadata:continuation:`
  allocates `length + prefix_len + block_size` for a line too long for the
  current block, with the in-source comment "this is the case when the line is
  freaking huge". Its only line-shaped cap is `iTermLineBlockMaxLines = 10000`
  in `references/iterm2/sources/LineBlock.mm#reallyAppendLine:length:partial:width:metadata:continuation:cert:`,
  which bounds lines *per block* to keep serialized state small, not line length.
- kitty: none; the bound is `scrollback_lines` (default 2,000,
  `references/kitty/kitty/options/definition.py`), and
  `references/kitty/kitty/options/utils.py#scrollback_lines` maps a negative
  value to `2 ** 32 - 1`.
- foot: none; the ring is a power of two capped at 2^30 rows in the resize path
  of `references/foot/render.c`.
- alacritty: none per line; `references/alacritty/alacritty_terminal/src/grid/resize.rs#Grid::shrink_columns`
  ends with `reversed.truncate(self.max_scroll_limit + self.lines)`, an aggregate
  row bound (default history 10,000).
- windows-terminal: none; an over-long line circles the ring inside
  `references/windows-terminal/src/buffer/out/textBuffer.cpp#TextBuffer::Reflow`.
- wezterm: none in `references/wezterm/term/src/screen.rs#Screen::rewrap_lines`,
  which joins a logical line unboundedly. It does cap logical-line *scanning* at
  `MAX_LOGICAL_LINE_LEN: usize = 1024`, declared inside both
  `references/wezterm/term/src/screen.rs#Screen::for_each_logical_line_in_stable_range`
  and its `_mut` twin, with the comment "Avoid pathological cases where we have
  eg: a really long logical line (such as 1.5MB of json) that we previously
  wrapped." That is the closest precedent in the sweep to a per-logical-line
  bound, it names exactly the input this doc's open question names, and it is
  still a *consumer* limit rather than a storage split.

Two near-precedents, then, and both degrade a feature rather than split the
line. vte's is the second:
  `references/vte/src/vtedefines.hh` defines
  `VTE_RINGVIEW_PARAGRAPH_LENGTH_MAX 500` -- "Maximum length of a paragraph, in
  lines, that might get proper RingView (BiDi) treatment" -- consumed by
  `references/vte/src/ringview.cc#RingView::update` and
  `references/vte/src/bidi.cc#BidiRunner::paragraph`. Past 500 display rows vte
  keeps the paragraph whole and gives up a *feature* on it.

So the cap is not a compatibility requirement, and the references supply no
number to adopt -- 1,024 cells and 500 display rows are thresholds past which a
*feature* is dropped, not lengths a store refuses to hold. What they do supply
is the shape of the argument: every one of them bounds *the store*, and lets one
line consume as much of that bound as it wants. DanTerm's reason for a cap is narrower and real -- the arena is one
contiguous region, a record must fit inside it, and eviction granularity is one
record (case 27) -- so the cap should be derived from the arena rather than
guessed.

**The proposed 65,536 already is that derivation, and the entry records it
rather than leaving it a guess.** A C1 cell is one `UInt64` (8 bytes;
`PackedRetainedRow.swift`'s `Header.cellStyleShift` and the `u64` accessors), the
production byte budget is `Terminal.productionScrollbackBudgetBytes` =
16,777,216, and `65,536 x 8 = 524,288` bytes = **1/32 of the arena**. Stated as a
rule -- *no single record may exceed 1/32 of the byte budget* -- the number
follows from the budget instead of from taste, moves with it, and bounds both
hazards it exists for: the worst-case eviction undershoot is 1/32 of history,
and the worst-case in-block wide-cell scan (Observation 1) is 65,536 cells.
Recorded as a derivation offered by F4, to be ratified in Phase 2 (DD3).

For scale on what a real pathological line costs: at 179 columns a
65,536-cell record is 367 display rows, and at the minimum 2 columns it is
32,768 -- under `productionScrollbackRowCap`'s 89,500, so a single forced-split
segment cannot alone exhaust any current bound.

#### Observation 4 -- where the references disagree, and what DanTerm does

Six disagreements matter to this design. In each, DanTerm's existing behavior
is already pinned by its own tests, so the intended behavior is "keep it", and
the reference split is recorded so it is not re-litigated.

| question | the split | DanTerm |
| --- | --- | --- |
| selection across a width change | **cleared:** kitty (`references/kitty/kitty/screen.c#screen_resize` calls `clear_all_selections`), alacritty (`references/alacritty/alacritty_terminal/src/term/mod.rs#Term::resize`: `if old_cols != num_cols { self.selection = None; }`). **remapped:** foot (tracking points through `references/foot/grid.c#grid_resize_and_reflow`), iTerm2 (`references/iterm2/sources/VT100ScreenMutableState+Resizing.m#convertRange:toWidth:to:inLineBuffer:tolerateEmpty:`), vte (markers 4 and 5 of the seven in `references/vte/src/vte.cc#Terminal::screen_set_size`, with block selection alone cleared) | remap, and keep remapping: `TerminalResizeTests` and `TerminalSelectionTests` pin it, and the logical-line store makes the remap cheaper, not harder (case 13) |
| a cluster wider than the pane | **discarded:** kitty (`references/kitty/kitty/resize.c#multiline_copy_src_to_dest`). **replaced by a blank:** foot (`references/foot/grid.c#grid_resize_and_reflow`) | unreachable behind the `columns >= 2` guard; adopt neither policy (case 3) |
| trailing blanks on a continued row | **trimmed:** kitty trims unwritten cells only (`references/kitty/kitty/resize.c#init_src_line`), windows-terminal trims to `MeasureRight` (`references/windows-terminal/src/buffer/out/Row.cpp#ROW::MeasureRight`, which returns full width for a wrap-forced row). wezterm trims by *character*, `references/wezterm/wezterm-surface/src/line/line.rs#Line::wrap` truncating at the last cell whose `str() != " "`, which also discards a blank carrying a non-default background. **not trimmed:** foot explicitly re-extends a continued row to full width; vte does not trim in `Ring::rewrap` at all and instead shrinks rows at write time and strips trailing nondefault-background blanks at read (`references/vte/src/vte.cc#Terminal::get_text`) | full width for a soft-wrapped row, `retainedContentEnd` for a hard-ended one -- the same rule, and already what `reconstructLogicalLines` does (case 17). Note DanTerm trims by cell *kind*, not by character, so wezterm's BCE-blank loss is not reachable here; `bceOnlyPaddingRemainsStyleBlindAcrossResize` pins that |
| viewport across a width change | **numeric:** kitty leaves `scrolled_by` untouched. **content-anchored:** foot adds the viewport to its tracking points; vte anchors on the row below the bottom visible row, after two special cases for "was at bottom" and "was at top" (`references/vte/src/vte.cc#Terminal::screen_set_size`) | content-anchored, pinned by `resizePreservesBrowsingAnchor` (case 15) |
| hard tabs in history | **not stored:** wezterm (`references/wezterm/term/src/terminalstate/mod.rs#TerminalState::c0_horizontal_tab` moves the cursor and writes nothing), kitty, foot. **stored:** vte writes a real `'\t'` cell spanning up to `VTE_TAB_WIDTH_MAX` = 15 columns when the tab lands past existing content (`references/vte/src/vteseq.cc#Terminal::move_cursor_tab_forward`), and the span survives its rewrap unchanged rather than re-snapping to the new tab stops | not stored, as today (case 22). vte's smart tab is worth knowing exists -- it is a per-cell content property, so it would fit a record header without introducing a width -- but it buys copy fidelity DanTerm has not asked for |
| DECDWL / DECDHL line attributes | **unimplemented:** vte stubs all three (`references/vte/src/vteseq.cc#Terminal::DECDWL`: "Probably not worth implementing"). **implemented and silently dropped by reflow:** wezterm sets `LineBits` in `references/wezterm/wezterm-surface/src/line/line.rs#Line::set_double_width` but `#Line::wrap` builds fresh rows with `bits = NONE`, and its `#test_dec_double_width` performs no resize, so the loss is untested. **partially handled:** windows-terminal refuses to reflow a non-single-width row and force-newlines around it | unimplemented, and this doc does not propose adding it (case 24). If it is ever added, wezterm's silent drop is the failure to avoid |

Where the sweep *agrees* is worth one line, because it is the shape cases 6-8
and 13-15 all want. Every implementation that remaps anything across a width
change converts (row, column) into an offset into the unwrapped logical text,
carries it through, and converts back. vte's is the most complete and is the
model to take to Phase 2: `CellTextOffset { text_offset, fragment_cells,
eol_cells }` (`references/vte/src/ring.hh`, `Ring::CellTextOffset`), computed by
`references/vte/src/ring.cc#Ring::frozen_row_column_to_text_offset` and reversed
by `#Ring::frozen_row_text_offset_to_column`. The three fields are exactly the
three cases DanTerm's reflow anchor enum already distinguishes -- an offset in
the line, a position *inside* a wide cluster, and a position at or past
end-of-line -- and vte carries seven such markers simultaneously (cursor, saved
cursor, below-viewport, below-current-paragraph, two selection endpoints).
DanTerm carries ten today, through the four `attachments` computations in
`Terminal.swift#resizeWidth`. Under the logical-line store that offset *is* the
stored address, so the conversion happens once at the boundary instead of twice
per resize.

#### Observation 5 -- the immutability premise survives, but only because every history mutation is confined to the tail record

The design says "scrolled-off content is immutable, so the open line only ever
grows at its end". That is a claim about today's engine, and today's engine does
write into retained history. Every such write was enumerated: there are exactly
three, all in `Terminal.swift`, and **all three target
`scrollbackRows.indices.last` and no other index**:

- `Terminal.swift#severScrollbackWrapClaim` -- clears `isSoftWrapped` and
  replaces a trailing `.spacerHead`, reached only through
  `Terminal.swift#severWrapClaim(before:replacementStyleId:)` at row 0.
- `Terminal.swift#restoreWrapClaimBeforeCursor` -- sets `isSoftWrapped` back to
  true on the last retained row.
- `Terminal.swift#clearPreviousSpacer` -- clears a `.spacerHead` on the last
  retained row when column 0 or 1 of the top viewport row is cleared.

Under the logical-line store these become: close the open record, reopen it, and
nothing at all (the spacer was never stored). All three are header-bit flips on
the arena's tail, which is the one record the append path already writes. The
premise holds, and the cases are 9 and 10 in the inventory.
`TerminalInspectionInvalidationTests`' "scrollback-tail wrap and spacer edits
invalidate that retained row" is the existing test that pins this surface, and
it is the test to re-point at the new store.

#### Deferred decisions

Recorded here so a human can revisit; each took the obvious, simple choice
rather than blocking.

- **DD1 -- selection is remapped, not cleared, across a width change.** Two
  references clear it (Observation 4). Keeping DanTerm's remap is chosen because
  it is existing pinned behavior and this design makes it cheaper; the
  alternative would be a user-visible regression taken for implementation
  convenience.
- **DD2 -- eviction evicts whole records.** The simple choice. The cost is that
  `isHistoryHeadTruncated` becomes always-false and the byte budget can
  undershoot by up to one record. The alternative -- advancing a head offset
  inside the first record so eviction stays display-row granular -- is real and
  cheap to add later, and is not needed for milestone 1.
- **DD3 -- the forced-split cap is 65,536 cells, stated as "no record exceeds
  1/32 of the byte budget".** Same number the README proposed, now with a
  derivation (Observation 3) instead of a guess. Reopen if the budget changes
  shape or if Phase 2 finds the eviction granularity or the wide-cell scan binds.
- **DD4 -- the `hasWideCells` header bit is carried per record, not per buffer.**
  iTerm2's buffer-wide sticky flag is the alternative and is rejected on
  DanTerm's own constraint: a per-record bit costs one flag in a header that
  already exists, is computed free at admission, and never needs the three
  memoization layers iTerm2 added to survive its own pessimism.

- Observation: 28 edge cases were catalogued from seven reference
  implementations and DanTerm's own reflow path and tests. Every one is
  decidable as a pure function of (logical line, current width) plus live-grid
  state. **Zero cases require width-dependent data persisted in history.** One
  case (2) corrects the arithmetic `H1` and `F2` assumed, and one (26) wants a
  `forcedSplit` marker; both are content properties, not widths.
- Inference: `H4` is **confirmed** and `D1`'s no-go trigger does not fire. The
  design's core premise -- nothing width-shaped survives in storage -- holds
  against the full set of inputs the references' test suites exist to surface.
  Two things it hands to Phase 2 beyond the table: display-row counting needs a
  per-record `hasWideCells` bit and an O(cells) fallback, and the forced-split
  cap now has a derivation rather than a guess.
- Competing interpretations:
  1. *The inventory is only as good as the sweep, and a case was missed.* The
     honest limit of a cataloguing pass. Two things bound it: the sweep is
     anchored on DanTerm's own reflow implementation and its ~40 resize/wrap
     tests, which is a set already hardened against real incidents, and the
     references were read for their *tests* as well as their code precisely
     because a test suite is a record of what bit somebody. What would change
     the answer is a case that needs stored width. The two trees that separate
     text from wrap points -- iTerm2 and vte -- both keep every width-derived
     number in a structure they are willing to throw away
     (`references/iterm2/sources/iTermLineBlockArray.m#setAllBlocksMayHaveDoubleWidthCharacters`
     discards the whole cache collection; vte's row stream "is regenerated when
     the contents rewrap on resize"), which is weak but real evidence that the
     category is empty.
  2. *Case 2 is really a no-go in disguise -- a scan is a hidden cost, and a
     hidden cost is a hidden dependency on width.* It is not: the scan reads the
     record's own cells and the current width, both of which the design already
     has. The flag that avoids the scan is a content property. `D1`'s trigger is
     "requires storing wrap or width state", and no reading of case 2 reaches it.
  3. *`ceil` was always known to be wrong and this finding is bookkeeping.* `F1`
     Observation 2 explicitly reserved the question for `F4` rather than
     assuming either answer, and `F2` measured a pass built on the `ceil`
     assumption. Recording the correction is what keeps `F2`'s number from being
     quoted at content it does not cover -- see Uncertainty.
- Uncertainty:
  - **`F2`'s counting pass is priced for narrow content only.** Its `mix` and
    `full` stimuli are ASCII, so every line took the O(1) `ceil` path. A history
    of CJK or emoji output makes the eager pass an O(cells) walk of the flagged
    records. `H2` cleared its bound by 15.6x, so there is margin, but the margin
    is not measured against a wide-content stimulus and must not be assumed to
    transfer. This is a named Phase 2 measurement, not a resolved question.
  - **The forced-split cap is derived, not measured.** Observation 3 gives it a
    rule; no pathological input (`cat` of a binary, minified JSON) was fed to a
    real engine to see what a session actually produces.
  - **`references/windows-terminal/` in this checkout is partial** -- it has
    `src/buffer/`, `src/terminal/`, `src/types/` and no `src/host/` or
    `src/cascadia/` -- so its alternate-screen and selection behavior could not
    be read, and cases 11-13 rest on the other six trees. Its reflow and cursor
    evidence is complete.
  - **iTerm2 has no LineBuffer unit tests in this tree.** Every iTerm2 citation
    above is production code, and the category's existence proof is therefore an
    argument from a shipping implementation rather than from its test suite.
  - **The inventory is decisions, not code.** Nothing here has been implemented
    or measured end to end; each row is a claim about what the design must do,
    to be discharged by Phase 2's call-site enumeration.
- Next action: `D1` Part B has `F4` in and its verdict is unchanged in
  direction -- **still `go` on Part A, still open on Part B, and the no-go
  trigger is now known not to fire.** Owed: `F3` (the admission probe) and the
  simplification inequality. Two amendments this entry writes back into the
  README: `H1`'s and the candidate direction's `ceil(cells / width)` becomes
  "`ceil` for narrow records, scan for wide ones", and the forced-split cap's
  open question closes into DD3's derivation. One new open question opens: the
  eager counting pass is unpriced on wide content.
