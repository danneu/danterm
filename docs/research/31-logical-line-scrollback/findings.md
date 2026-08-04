# Findings -- logical-line scrollback (doc 31)

Append-only evidence chain for
[31-logical-line-scrollback](README.md); the contract is
[../FORMAT.md](../FORMAT.md). Cross-file citations are qualified (`28/F23` is
doc 28's); bare IDs are this doc's.

Phase 1's four viability probes are all recorded below: `F1` (read path), `F2`
(counting pass), `F3` (admission), `F4` (edge-case inventory). `F5` is not a
probe -- it is the simplification-inequality accounting pass that `D1`'s frozen
rule owed at its close.

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

### F3 -- admission is not the residual either: open-line append admits a scrolled-off row 1.45x-1.60x faster than today's pack-per-row, including on `scrollback-stream`'s own row shape

- Status: recorded. `H3` **confirmed** under `31/D1`'s Part B rule for F3, frozen
  at `d6c83b0` before this probe existed in the tree. This is `D1` Part B's
  fourth and last measured input; it **cannot and does not close `D1`**, whose
  remaining debt is the simplification inequality alone. It licenses no
  production storage change, and `28/H7` stays the fallback until `D1` closes.
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: `d6c83b0` (the commit that froze this rule, written
  before this probe existed in the tree), plus the one file this entry adds --
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineAdmissionProbe.swift`,
  committed with it. **No file under `lib/TerminalCore/Sources/` is touched, and
  neither F1's nor F2's probe file is edited** -- the two admitters are new types
  in F3's own file, because F1's stores are read-oriented and built whole rather
  than incrementally. The two untracked paths present throughout this doc's work
  are still present and still in no build: `TODO.md` and
  `docs/scratch/2026-08-04-scroll-sample-breakdown.md`.
- Conditions: AC power, low-power mode off. One-minute load average **1.00
  before and 1.00 after**, well under the 2.5 gate `28/F15` established and `D1`
  adopted. Release configuration, headless, one process. The build was completed
  and the machine allowed to settle before the measured invocation, per `F2`'s
  gate-3 lesson.
- Commands:

      DANTERM_LOGICAL_LINE_PROBE=1 swift test -c release \
          --package-path lib/TerminalCore --filter TerminalLogicalLineAdmissionProbe

- Artifacts: none durable. Every number below is stdout from the probe above and
  is reproduced by re-running it; the probe prints its own gate outcomes.
- **No invocation was voided.** All six gates held on the first measured run.
  (The calibration test alone was run once beforehand to check the two new
  content classes; it produces no timing, and its calibration figures are
  identical to the measured run's.)

#### What was compared

Both arms admit the **same** engine-produced display rows, in the same order:
the rows a real `Terminal` at 179x66 retained, taken through
`retainedRowForTesting(at:)` and **materialized to full width**, because that is
the shape production admission is handed from the live grid -- `pack`'s first
walk covers every column, and charging the baseline a shorter walk than
production pays would understate it.

- **Baseline** -- today's admission, reproduced from
  `Terminal.swift#appendToScrollback`: `PackedRetainedRow.pack` per display row
  (the production encoder, which trims to canonical extent as it encodes), an
  append into the retained buffer, and the two accumulations that call site
  performs -- `Terminal.swift#scrollbackByteCost(of:)` into the charged byte
  total and `storedCellCount` into the stored-cell total. `ScrollbackBuffer` and
  `scrollbackByteCost` are `private` to `Terminal`, so the arm reproduces the
  append, the storage and the byte-cost arithmetic rather than calling them.
  That substitution is F3's stated fidelity limit, exactly as it was F1's.
- **Candidate** -- doc 31's open-line rule with `F4`'s corrected semantics: the
  row's cells are appended at the arena's write cursor into the **open** record,
  `.spacerHead` cells are dropped on the way in (`F4` case 10 -- the store never
  held one), a row that is not soft-wrapped closes the record and writes its
  header bits (`hasWideCells`, `forcedSplit`), and **the only record ever
  written is the tail** (`F4` Observation 5). Per-cell work is identical to the
  baseline's by construction, down to the zero-word omission `pack` makes, which
  is what leaves a *per-row* difference to measure.

#### Observation 1 -- the four measured classes, and the verdict D1's F3 rule reads off them

Median over 5 ABBA rounds of nanoseconds per admitted display row, at ~10,000
display rows and 179 columns. Sample count: 10,000 admitted rows per arm per
round (10,001 for `wide`), `n=5` rounds.

| class | verdict-bearing | baseline | candidate | ratio | saving | A/A control | `D1` F3 rule | result |
| --- | :---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| `mix` | yes | 623.1 ns | **389.1 ns** | **0.624x** | -234.0 ns/row | +0.18% | <= 1.00x confirms | **confirm** |
| `full` | yes | 642.4 ns | **444.0 ns** | **0.691x** | -198.4 ns/row | +0.49% | <= 1.00x confirms | **confirm** |
| `stream` | yes | 484.5 ns | **302.4 ns** | **0.624x** | -182.1 ns/row | -0.15% | <= 1.00x confirms | **confirm** |
| `wide` | **no** | 749.4 ns | 407.2 ns | 0.543x | -342.2 ns/row | -0.02% | outside the verdict | observation |

Every A/A control is under 0.5%, so all four differences are two orders of
magnitude outside the instrument's resolution. Every verdict-bearing class is at
or under 1.00x, so **`H3` is confirmed outright** rather than landing in the
neutral band: admission does not merely get no worse, it gets **1.45x to 1.60x
cheaper per admitted row**. The reject bound -- 1.09x, the ratio that would
predict a `slower` verdict on `scrollback-stream` -- is not approached from
either side.

The class that matters most to `H3` is `stream`, and it behaves like the others.
`28/F20` Observation 5 established that `benchmark/scrollback-stream` -- the
workload `H3` names as its falsifier -- retains **hard-ended CRLF rows that never
soft-wrap**, because its producer writes `\n` through a tty whose Darwin default
`OPOST|ONLCR` converts it. That is the *worst* case for this design's stated
mechanism ("fewer records, less per-row header work"): the candidate creates
**one record per display row, exactly as many as the baseline** (10,000 and
10,000, measured). It is still 0.624x. So the win is not the record-count
reduction the sketch predicted.

All six validity gates held on the quoted invocation:

1. **Cross-arm equivalence:** both stores were read back display row by display
   row, outside every timed region, and checksummed over every scalar, style id
   and kind. **Checksums identical and display-row counts equal on all four
   classes.** That is the gate that holds the candidate to re-deriving what it
   refused to store: on `wide` it must re-insert 5,124 `.spacerHead` cells at
   read, from (record cells, width) alone, and it does -- the checksums would not
   match otherwise.
2. **Non-elision:** each arm's per-round product (records, bytes, rows/cells,
   folded) matched the value computed outside the timed region on every round,
   and no product was the empty store's.
3. **Stimulus calibration** (Observation 2), all four in band.
4. **A/A resolution:** +0.18% / +0.49% / -0.15% / -0.02%, all far under the 5%
   ceiling.
5. **Host conditions** as recorded above.
6. **Coverage:** every aggregate printed with its round count and its admitted-row
   count.

#### Observation 2 -- the stimuli, calibrated before any arm was timed

| class | display rows | logical lines | rows/line | soft-wrapped | spacers | median cells | p95 | mean | gate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `mix` | 10,000 | 5,758 | 1.74 | 42.4% | 0 | 149 | 179 | 124.2 | median in [119,154], p95 179 -- **pass** |
| `full` | 10,000 | 5,013 | 1.99 | 49.9% | 0 | 179 | 179 | 179.0 | median and p95 179 -- **pass** |
| `stream` | 10,000 | 10,000 | 1.00 | **0.0%** | 0 | 60 | 60 | 60.0 | median in [55,65], soft-wrap 0 -- **pass** |
| `wide` | 10,001 | 4,877 | 2.05 | 51.2% | **5,124** | 179 | 179 | 135.1 | >=50% wide rows (100%), >=1 spacer -- **pass** |

`mix` reproduces Part A's calibration exactly (median 149, p95 179, mean 124.2),
which is the cheapest available check that F3 and F1 measure one content model.
`stream`'s template is `benchmarks/fixtures/terminal-app.json`'s
`scrollback-stream` segment verbatim, fed with CRLF as the tty delivers it; it
measures **60** stored cells per row against `28/F20` Observation 5's "~59",
which is that entry's own rounding of the same 60-character line. `wide` puts a
wide cell in 100% of admitted rows and produces 5,124 spacers -- roughly one per
soft-wrapped row, as expected at 179 columns where 89 two-cell clusters fill 178
and the 90th meets a one-column gap.

#### Observation 3 -- the saving is per *row*, not per cell, and today's admission is ~90-95% encoder

Two readings, taken together, say what the difference is made of.

The saving barely responds to cell count. `stream` admits 60 stored cells a row
and saves 182.1 ns; `full` admits 179 -- three times as many -- and saves 198.4
ns, 1.09x as much. If the candidate were winning per cell, `full`'s saving would
be about triple `stream`'s. **It is a per-row constant**, which is the signature
of the thing the candidate deletes: one heap allocation and one
`PackedRetainedRow` value per admitted row, against a store at a cursor.

The descriptive decomposition says the same thing from the baseline's side.
Median ns per row over 5 rounds, **not interleaved** -- these three arms run in
sequence, so they are comparable to each other and *not* to Observation 1's
interleaved figures (the `whole` column reads 4-11% above Observation 1's
baseline for exactly that reason, which is itself a measured statement about
what interleaving is worth):

| class | `pack` only | `pack` + buffer append | whole path (+ accounting) | encoder's share |
| --- | ---: | ---: | ---: | ---: |
| `mix` | 613.9 | 654.7 | 666.4 | 92.1% |
| `full` | 639.5 | 701.5 | 711.6 | 89.9% |
| `stream` | 497.0 | 512.0 | 524.7 | 94.7% |
| `wide` | 740.7 | 786.9 | 810.3 | 91.4% |

So the buffer append is 2.5-8.7 points of today's admission and the byte and
cell accounting 1.2-2.9 points; **the encoder is everything else.** A design
that kept `pack` and only changed the container could therefore recover at most
about a tenth of what the candidate recovers, which is the answer to the
competing interpretation that this is a container win.

#### Observation 4 -- the arena is also smaller than what the budget charges today, descriptively

Outside `D1`'s rule. The candidate's exact arena footprint against the byte total
today's budget charges for the same content, at the same depth:

| class | records | charged today | arena | ratio |
| --- | ---: | ---: | ---: | ---: |
| `mix` | 5,758 | 11,154,016 B | 9,982,856 B | 0.895x |
| `full` | 5,013 | 15,520,000 B | 14,360,104 B | 0.925x |
| `stream` | 10,000 | 6,560,000 B | 4,880,000 B | **0.744x** |
| `wide` | 4,877 | 12,077,312 B | 10,805,592 B | 0.895x |

The mechanism is per-record overhead: today every display row pays a 16-byte
buffer slot plus a 32-byte array header plus its blob's bucket rounding, while
the arena pays an 8-byte header per *logical line* and nothing per row.
`stream`'s 0.744x is the extreme because its rows are short, so the fixed 48
bytes a row costs today is a large share of its ~487-byte blob. This is a
byproduct, not a claim about eviction or about what the budget should be; it is
recorded because Phase 2 will have to decide what "the byte budget is the arena
size" admits.

- Observation: at ~10,000 admitted display rows and 179 columns, open-line
  append into a contiguous arena admits a scrolled-off row **faster** than
  today's pack-one-record-per-display-row admission on every content class
  measured -- 0.624x (`mix`), 0.691x (`full`), 0.624x (`stream`), 0.543x
  (`wide`, outside the verdict) -- with A/A controls under 0.5%, identical
  cross-arm checksums, and calibrated stimuli.
- Inference: `H3` is confirmed, in the direction it declined to assume. The
  campaign's residuals (`28/F20`: `scrollback-stream` +4.13%, `terminal-feed`
  +4.55% against pre-packing) are not made worse by the storage change this doc
  proposes, and the part of them that lives in admission's *encoding and storing*
  gets cheaper. The mechanism the numbers support is the same one `F1` found on
  the read side and `28/F17`/`28/F20` found twice before that: **the cost is the
  allocation and write pattern, not the encoding.** Today's admission allocates a
  blob per display row; the candidate writes the identical cell words at a cursor
  in a region it already owns.
- Competing interpretations:
  1. *The win is the container -- the buffer append and the accounting -- and is
     recoverable inside today's design.* **Measured and refuted** (Observation 3):
     those two together are 5-10% of today's admission, and the candidate's
     margin is 31-38%.
  2. *The win is per-cell work the candidate skips.* **Refuted by the shape of
     the saving** (Observation 3): tripling the stored cells per row from 60 to
     179 moves the saving by 9%, not by 200%. The cross-arm checksum independently
     proves the two arms produced the same cell words, so no per-cell work was
     skipped.
  3. *The residual `28/F20` measured is scheduling, not encoding, so making
     encoding cheaper does not remove it.* **Not refuted, and it is the most
     important limit on this entry.** The doc's own `H3` says so, citing `28/H8`.
     F3 measures admission in isolation, in one thread, with no PTY, no actor hop
     and no backpressure; it can see the encode-and-store term and nothing else.
     A -37.6% change in a term `28/F20` sampled at 19.7% of the drain thread
     *predicts* roughly -7% on `scrollback-stream`'s block, but that is a
     conversion through a share, exactly the kind of derivation `F1` was careful
     to label a prediction. Only the paired ladder against a real implementation
     can settle it.
  4. *The arms differ in what they store.* Both lost `hyperlinkId` and
     `contentIdentity`, so neither builds a side table -- the same strip Part A
     made, conservative toward the baseline for the same reason (under the
     candidate an identity run table would be built once per logical line rather
     than once per display row).
- Uncertainty:
  - **No eviction.** Today's `enforceScrollbackBudget` / `removeFirst` against
    `DD2`'s whole-record eviction is not measured here, by the frozen rule.
    Both arms grow into a store that is never bounded, and a real pane at steady
    state evicts on every admitted row. This is the largest thing F3 does not
    see, and it is Phase 2's.
  - **A microbenchmark is not a workload.** Parsing, grid mutation and damage all
    run before admission on a real feed, and none of it is here. The -7%
    prediction above is a conversion, not a measurement.
  - **One depth, one geometry, one machine, one session.** ~10,000 display rows
    at 179x66, as with `F1` and `F2`.
  - **The `wide` margin is larger and unattributed.** `wide` costs the baseline
    749.4 ns/row against `full`'s 642.4 while storing *fewer* cells per row (mean
    135.1 against 179.0), so its extra cost is per-cell work on wide clusters
    that the candidate also performs. Why the candidate's absolute saving is
    nonetheless 342 ns rather than ~200 is not explained by the per-row constant
    Observation 3 establishes, and no counter was read. It is recorded as an
    observation and not built on.
  - **The forced-split path is unexercised.** No class reaches 65,536 cells, so
    only the per-row bound check was measured.
  - **The prototype is still not a store.** No search, no selection, no semantic
    marks beyond a header slot, no spill table (the arm `fatalError`s on a
    multi-scalar cell rather than encoding one silently).
- Deferred decisions, continuing `F4`'s numbering; each took the obvious, simple
  choice rather than blocking:
  - **DD5 -- a record's display-row count is *counted* at admission, not
    derived.** Admission knows how many rows it consumed, so the block's cached
    display-row total is incremented as rows arrive and no `ceil` -- and no
    `hasWideCells` scan (`F4` Observation 1) -- runs on the write path at all.
    `F2`'s counting pass therefore belongs to the width-change path exclusively.
    The alternative, deriving the count at close, would pay the wide-cell scan on
    every admitted line for a number the writer already has.
  - **DD6 -- a forced split leaves no back-pointer.** The `forcedSplit` bit sits
    on the record that was cut and the continuation simply follows it in the
    arena; readers rejoin by adjacency. The alternative -- a `continuesPrevious`
    bit on the follower -- is one flag more state for a case no measured input
    reaches, and can be added later without changing the format.
- Next action: `D1` Part B's last measured input is in. **Part B now owes exactly
  one thing: the simplification inequality** (`D1`'s frozen paragraph "What the
  simplification inequality must show"), which is a reading and accounting pass
  over the deletion and addition lists, not a measurement. `D1` does not close on
  this entry and Phase 2 does not open. Two things this entry hands forward:
  Observation 3's decomposition says any future admission work belongs in the
  encoder rather than the container, and Observation 4 prices the arena against
  what the budget charges today, which the budget-and-eviction task in Phase 2
  will need.

### F5 -- the simplification inequality holds, and it holds on invariants rather than on line count: five cross-cutting invariants deleted against three local ones added

- Status: recorded. This is `D1` Part B's last owed input and the only one that
  is not a measurement -- the frozen rule calls it "a reading and accounting
  pass over the deletion and addition lists". It closes `D1`; the verdict and
  its scoping are in [decisions.md](decisions.md).
- Date and investigator: 2026-08-04, Claude (agent).
- Commit and worktree state: `3fd09fd`, the commit that recorded `F3`. **No file
  under `lib/` is added or changed by this entry** -- like `F4`, it is a reading
  and accounting pass. Line numbers below are read at `3fd09fd`. The two
  untracked paths present throughout this doc's work are still present and still
  in no build: `TODO.md` and
  `docs/scratch/2026-08-04-scroll-sample-breakdown.md`.
- Commands, inputs, or reproduction: the deletion side was enumerated by reading
  `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`,
  `lib/TerminalCore/Sources/TerminalCore/PackedRetainedRow.swift` and the
  `lib/TerminalCore/Tests/TerminalCoreTests/` suites named below; the addition
  side was enumerated from this doc's own three probe files, which are the
  candidate's only existing implementation, plus `F4`'s and `F3`'s deferred
  decisions (`DD1`-`DD6`), which are what settle its semantics.
- Artifacts: none durable.

#### What the rule asks, restated before it is answered

`D1`'s frozen paragraph "What the simplification inequality must show" names six
things the deletion list **must actually contain** -- history reflow mutation,
`productionScrollbackCellCap`, `productionScrollbackRowCap`, the `28/D8`
cost-model derivations and their tests, narrow-then-widen eviction machinery, and
continuation-flag bookkeeping in retained history -- and three properties the
addition list **must have**: pure, unit-testable, and free of any width-dependent
persisted state. The README states the same gate as a magnitude: the deletion
list "must exceed" the addition list. Both readings are answered below, and they
do not answer the same way, which is the substance of this entry.

#### Observation 1 -- the deletion side, named against real code sites

All six named items are present in the tree and are genuinely removed. What each
one actually is:

| # | rule's item | the code that is it | disposition |
| ---: | --- | --- | --- |
| 1 | history reflow mutation | `Terminal.swift:4288` `resizeWidth` (286 lines), `:4575` `reconstructLogicalLines` (137), `:4713` `pack(line:columns:)` (65), `:3686`-`:3791` `attachments` / two `attachment` overloads / `textDestination` (106), `:560`+`:599`-`:639` the seven reflow-only types (46), `:4791` `sourceKey` (3) | history is never rebuilt; see Observation 2 for the part that moves rather than vanishes |
| 2 | `productionScrollbackCellCap` | `Terminal.swift:784`, its 21-line derivation at `:763`-`:783`, the live `scrollbackCellCap` `:856`, `scrollbackStoredCellCount` `:860` and its two maintenance sites (`:3974`, `:3994`), `recomputedScrollbackStoredCellCount` `:2314`, and the cap's clause in `enforceScrollbackBudget`'s `while` (`:3990`) | deleted: the doc comment says in terms that the cap exists to bound reflow's dominant term, and there is no such term |
| 3 | `productionScrollbackRowCap` | `Terminal.swift:815`, its 29-line derivation at `:786`-`:814`, `scrollbackRowCap` `:853`, the row clause at `:3989` | deleted: it bounds the `1.85 us/row` term for `28/F9`'s blank-row regime, and `F4` case 28 shows blank rows fold into near-zero-cell records the byte budget already bounds |
| 4 | the `28/D8` cost-model derivations and their tests | the ~50 lines of doc comment carrying `1.85 us/row + 0.352 us/cell`, the `cellCap / 20` ratio and the 600.5 ms price; six of `TerminalScrollbackBudgetTests.swift`'s 21 tests (`:220`, `:257`, `:290`, `:341`, `:403`, `:761`); `TerminalHistoryDepthSizingProbe.swift` (294 lines, whose whole purpose is pricing candidate cap sets and their resize cost) | deleted; `TerminalResizeProbe` / `TerminalResizeProbeSupport` (344 lines) survives but loses its subject -- it would measure a live-screen refold plus `F2`'s counting pass |
| 5 | narrow-then-widen eviction machinery | not a module but an invariant: the cell cap's content-denomination exists solely to hold it (`Terminal.swift:767`-`:770`), the row cap documents a lossy region below 20 columns (`:800`-`:806`), `narrowThenWidenPreservesCappedHistory` (`TerminalScrollbackBudgetTests.swift:290`) pins it, and `resizeWidth` re-enforces the budget at `:4571` after every rebuild | deleted by construction: a width change does not touch the arena, so a narrow-then-widen cycle is a no-op on storage and the lossiness question becomes unrepresentable |
| 6 | continuation-flag bookkeeping in retained history | `PackedRetainedRow.swift:101` `softWrapBit` + `:149` accessor + pack/unpack at `:506`/`:289`, one bit **per display row**; the three tail mutations that keep it truthful (`Terminal.swift:6369` `severScrollbackWrapClaim`, `:6387` `restoreWrapClaimBeforeCursor`, `:6436` `clearPreviousSpacer`, plus `:6460` `setScrollbackCell`, 65 lines); `isHistoryHeadTruncated` (`:866`, maintained at `:3999` and `:5385`, asserted 14 times in `TerminalScrollbackBudgetTests`); `.continuation` stamping into retained rows (`:4731`, `:4746`) | reduced, not erased: the flag becomes one open/closed bit per **logical line**, two of the three mutations become header-bit flips on the tail record and the third disappears (`F4` Observation 5), `isHistoryHeadTruncated` becomes always-false (`DD2`), and `.continuation` is stamped at read (`F4` case 16) |

Summed as lines of `Terminal.swift`, the reflow-shaped code is **~660 lines**,
the cap machinery ~75, and the tail-mutation trio ~65: about **790 of 6,470
lines, 12% of the file**.

#### Observation 2 -- the honest subtraction: the fold is not deleted, it moves

`pack(line:columns:)` is the function that turns one logical line into display
rows at a width. Every rule in it -- the `.spacerHead` at a one-column gap
(`Terminal.swift:4734`), the `isSoftWrapped` marking (`:4726`), the
`.continuation` stamping (`:4731`, `:4746`) -- is exactly what the candidate has
to do **at read time** instead. So of that ~660 lines, roughly **70 move rather
than vanish**: `pack`'s fold minus its two destination dictionaries, plus
`retainedContentEnd` (`:4779`, which becomes admission's trailing-blank rule,
`F4` case 17). `F4` already said this from the other direction --
`reconstructLogicalLines` is the admission rule run backwards -- and the correct
statement of the deletion is therefore **the round trip, not the wrapping**.

What *is* deleted outright inside that machinery is everything that exists only
because the rebuild is destructive and identities must survive it: the
`sourceKey` coordinate space, the `cellDestinations` and `boundaryDestinations`
dictionaries built per logical line, `ReflowRowMetadata`, `ReflowCursorAnchor`'s
three cases, `ReflowTextAttachment`, and the four `attachments` computations plus
the eight destination locals and their `??` threading in `resizeWidth`
(`:4319`-`:4354`, `:4356`-`:4365`, `:4443`-`:4498`, `:4531`-`:4564`) -- about
**130 lines whose entire job is carrying ten anchors across a rebuild that no
longer happens**. `F4` Observation 4 priced the replacement: one address
conversion, because (logical line, offset) becomes the stored address.

Also deleted and easy to miss: `resizeWidth:4522`-`:4523` re-walks all of history
after every width change to recompute the charged byte and stored-cell totals.
Under the arena the byte total is the write cursor.

#### Observation 3 -- the addition side, stated at full cost

Six items, not the rule's four. `F4` added one and `F3`'s `DD5` removed work from
another; two more are named here because an inequality argued by omission is
worthless.

1. **The contiguous byte arena.** A record is an 8-byte header (cell count,
   flags, a semantic-mark slot) plus C1 cell words. Pure value type over
   `[UInt8]`; no clock, no IO, no AppKit. Unit-testable, and `F1`'s and `F3`'s
   cross-arm checksum gates are already the shape those tests take.
   Width-dependent persisted state: none -- `F1` Observation 2 reconstructed the
   engine's own display-row count for all 10,773 logical lines from (record,
   width) alone.
2. **The block-summed wrap index.** Per-line record offsets, blocked ~256 lines,
   one cached display-row total per block at the current width; offsets-only, per
   `F2`. This is the design's one genuinely new *mutable derived* structure, and
   it has **four maintain-or-recompute trigger points**: a width change (discard
   and recompute eagerly -- `F2`: 0.016 ms at trial depth), admission (`DD5`
   increments the tail block's total as rows arrive), eviction at the head
   (unspecified -- see below), and a forced split (one record becomes two).
   Nothing survives a flush, which is the property Observation 5 turns on, but
   the invalidation discipline is real and is new.
3. **The open-line rule.** Exactly one open record, always the arena's tail; a
   hard-ended row closes it. `F4` Observation 5 licenses the "tail only" premise
   by enumerating today's three history writes and finding all three target
   `scrollbackRows.indices.last`. `F3` measured the rule at 0.624x-0.691x of
   today's admission.
4. **The forced-split rule.** 65,536 cells, derived as 1/32 of the byte budget
   (`DD3`); a `forcedSplit` header bit; readers rejoin by adjacency with no
   back-pointer (`DD6`). One documented wart, bounded up front, and unexercised
   by every probe so far.
5. **The `hasWideCells` fast/slow split** (added by `F4`). A per-record content
   bit selecting `ceil((cells + spacers) / width)`'s O(1) path or an O(cells)
   scan. Weakest possible addition: always scanning would be correct, so the
   design does not depend on the bit existing.
6. **Spacer re-derivation at read.** The store never holds a `.spacerHead`, so
   every read re-inserts it from (record cells, width). `F3`'s gate 1 proved the
   derivation total -- 5,124 spacers re-derived on the `wide` class with
   identical checksums -- but it is work the reader does that today's store does
   not, and `F1`'s 0.608x browse figure was measured on stimuli with **zero**
   spacers.

Two further costs that are not permanent additions but are not free either, and
that the inequality must not be allowed to hide:

- **Eviction from the front of an arena is unpriced on both sides.** Today's
  `Terminal.swift:3978` `enforceScrollbackBudget` plus `ScrollbackBuffer`'s
  `removeFirst` (`:338`) and `compactIfNeeded` (`:371`) is the incumbent; `DD2`'s
  whole-record eviction is the candidate; nothing has compared them, and whole-
  record eviction additionally needs the index's head to move with it (trigger
  point 3 above). `F1`, `F3` and this doc's README all flag it, and it is the
  largest single hole in Phase 1's evidence.
- **Migration.** Phase 2's first task exists because the invariant "history is
  always at the current width" dies, and every display-row-indexed call site --
  `projectionRows`, `activationIdentity`'s range scan, `primaryHistoryText`,
  scrollbar math, selection, search -- must be re-expressed. That is a one-time
  cost, but it is a cost, and it is unenumerated.

#### Observation 4 -- on line count, the inequality is close to a wash, and this entry says so

The candidate's only existing implementation is this doc's probes. `F1`'s arena
plus derived index plus read walk is `TerminalLogicalLineReadProbe.swift:257`-`:560`,
about **303 lines**; `F3`'s open-line admitter is
`TerminalLogicalLineAdmissionProbe.swift:247`-`:458`, about **211**, of which the
read-back checksum is test scaffolding. Call the storage core **~350-400 lines**
of prototype -- and it has no spill table (`F1`'s arm calls `fatalError` on a
multi-scalar cell, and `28/F11` measured spills in ~0.12% of real rows), no
hyperlink or content-identity side tables, no semantic marks beyond a header
slot, no eviction and no search. A production version is plainly larger.

Against ~720 net lines deleted (790 less the ~70 that move), that is a win of
roughly 300 lines on a 6,470-line file, with an error bar wide enough to swallow
it. **The magnitude reading of the inequality is therefore weak**, and this
entry declines to rest the verdict on it. `DD8` records that choice.

#### Observation 5 -- on invariants, the inequality is not close

The reading that does carry it. What a maintainer must currently hold true, and
can currently get wrong:

| # | invariant deleted | who has to hold it today |
| ---: | --- | --- |
| 1 | history is always at the current width | every reader, and `resizeWidth` must re-establish it across the whole store before any of them runs |
| 2 | a narrow-then-widen cycle must not evict | the cell cap's content-denomination exists only for this, the row cap documents where it fails (below 20 columns), and one test pins the seam |
| 3 | the per-display-row continuation flag stays truthful under three tail edits | `severScrollbackWrapClaim`, `restoreWrapClaimBeforeCursor`, `clearPreviousSpacer`, plus `isHistoryHeadTruncated` at every eviction |
| 4 | ten anchors survive a destructive rebuild | four `attachments` computations, a source-key coordinate space, two destination dictionaries per logical line, three cursor-anchor cases |
| 5 | three bounds, whichever binds first | bytes, rows and cells, each with its own maintenance at two sites, its own derivation, and its own eviction clause |

| # | invariant added | who has to hold it |
| ---: | --- | --- |
| 1 | exactly one open record, always the arena tail | the admission path alone |
| 2 | cached block totals are valid for the current width, or discarded | the index alone, at four trigger points |
| 3 | no record exceeds 1/32 of the byte budget, and readers rejoin splits by adjacency | the admission path and the copy/search readers |
| 3.5 | `hasWideCells` is set iff the record holds a wide cell | the admission path -- and being wrong the safe way is still correct, which is why it counts as a half |

Five against three and a half, and the two sides are not the same kind of thing.
The deleted invariants are **cross-cutting**: each one is a contract between the
store and every reader, or between a resize and every anchor the terminal
carries. The added ones are **local**: each is a contract inside the store,
enforceable by one writer and testable by one gate.

Two of the deletions are stronger still, because they delete a failure mode
rather than a test of one. `F4` case 18 -- two hard-ended lines must not join
when widening -- becomes unrepresentable, since a record boundary *is* a hard
newline. And a width change that does not touch storage cannot evict, so
invariant 2 is not merely upheld but has nothing left to be about.

Against that, one addition has no analogue today and must be stated as a new
risk, not folded into the tally: **a stale block index**. Today there is no
derived width-dependent cache at all -- the store is at the width -- so this
design trades an eagerly-maintained truth for a derived cache with four trigger
points. It is the one item on the addition side that can grow, and `DD7` records
why it is nonetheless not "width-dependent persisted state" in `D1`'s sense.

#### Observation 6 -- the rule's three properties of the addition list, answered one at a time

- **Pure.** Every addition is a function of bytes already in hand: arena
  construction, index recompute, open-line append, forced split, wide-cell
  bit, spacer re-derivation. None reads a clock, a home directory, an id
  generator, or the filesystem. All six live under `lib/TerminalCore`, which
  takes no such input in the first place.
- **Unit-testable.** All three probes already demonstrate the test shape and it
  is a strong one: read the two stores back display row by display row and
  checksum every scalar, style id and kind. `F3` gate 1 is the proof that this
  catches the interesting failure -- it is what holds the candidate to
  re-deriving the 5,124 spacers it refused to store. `F2` gate 1's independent
  cross-check of the counting pass's total is the second shape.
- **Free of width-dependent persisted state.** Nothing width-shaped is written
  into a record: the header carries a cell count and content flags. The one
  width-dependent quantity in the design is the block index's cached totals, and
  it is a cache -- fully recomputable from the arena (`F2` measured exactly that
  pass, and cross-checked its output against an independently computed sum),
  discarded rather than migrated at every width change, and never consulted to
  decide what a record *is*. `DD7` records this reading.

- Observation: all six items `D1` requires on the deletion list are present in
  the tree at `3fd09fd` and are genuinely removed or reduced to a header-bit
  flip; the addition list has six members rather than four; and the two lists
  compare differently under two different units -- close to a wash on lines of
  code, five cross-cutting invariants against three and a half local ones on
  invariants.
- Inference: **the simplification inequality holds**, on the invariant reading,
  and `D1`'s three properties of the addition list are all satisfied. The
  argument is not that the design is smaller. It is that the design moves the
  wrapping rule from a destructive whole-history rebuild to a derivation at
  read, which deletes five contracts that span the entire engine and adds three
  and a half that live inside one store.
- Competing interpretations:
  1. *The inequality is being rescued by choosing a favourable unit.* The
     strongest objection, and Observation 4 concedes the unfavourable unit
     outright rather than burying it. The defence is that `D1`'s own rule is
     stated in terms of *what the lists contain*, not how long they are, and
     that the campaign's whole trigger (`28/D8`) was an invariant problem --
     "depth is latency" -- not a volume problem. `DD8` records the choice so it
     can be disputed.
  2. *`pack`'s fold moving to read time means the deletion is smaller than it
     looks.* Correct, and Observation 2 states it as the honest subtraction: ~70
     of ~790 lines move. It does not change the invariant tally, because the
     fold at read time is a pure function of (record, width) with no contract
     attached to it.
  3. *The block index is width-dependent persisted state, so the addition list
     fails `D1`'s third property outright.* Answered in Observation 6 and
     recorded as `DD7`. The distinguishing test the design leans on is whether
     the store can be reconstructed with no width anywhere in it; `F1`
     Observation 2 and `F2` gate 1 both demonstrate that it can.
  4. *An accounting pass cannot see the cost of code that does not exist yet.*
     True and unfixable at this stage. Everything on the addition side is sized
     from a prototype missing spills, side tables, eviction and search, so the
     addition list is the side with the larger error bar -- which is why the
     conditions carried into Phase 2 are all on that side.
- Uncertainty:
  - **Eviction is unpriced on both sides**, and it adds an index-head invariant
    nobody has designed. This is the largest term in the whole inequality that
    has no number attached to it.
  - **The addition list is sized from a prototype, not an implementation.** No
    spill table, no hyperlink or content-identity side tables, no search, no
    eviction. Each of those is on the addition side, and each will grow it.
  - **The migration is unenumerated.** Phase 2's call-site task is exactly the
    measurement of how large the one-time cost is, and it has not been done.
  - **The counting pass is still unpriced on wide content** (`F4`, `F2`), which
    is an addition-side cost that no reading here can settle.
  - **This is an accounting pass, not a measurement.** It reports what code
    exists and what contracts it carries. Nothing in it is a benchmark, and
    nothing in it substitutes for the paired ladder.
- Deferred decisions, continuing `F3`'s numbering; each took the obvious, simple
  choice rather than blocking:
  - **DD7 -- the block index's cached display-row totals are read as a cache,
    not as "width-dependent persisted state" under `D1`'s addition-list
    clause.** The test applied: the store can be reconstructed from its own
    bytes with no width anywhere in it (`F1` Observation 2, `F2` gate 1), and
    the cache is discarded rather than migrated at a width change. The stricter
    reading -- that any width-dependent byte anywhere in the design violates the
    clause -- would make the clause unsatisfiable by any wrap-at-read design
    that indexes at all, including iTerm2's, and would therefore have made `D1`
    no-go the moment the index was sketched at `de17e95`. A human may prefer the
    stricter reading; it would reopen `D1`.
  - **DD8 -- the inequality is adjudicated on invariants and cross-cutting
    coupling, not on line count.** Line count alone is close to neutral
    (Observation 4) and its error bar is wider than its margin, so resting the
    verdict on it would be resting it on noise. Reopen if Phase 2's
    implementation lands materially larger than the prototype suggests *and* the
    invariant argument has weakened -- either one alone does not reopen it.
- Next action: `D1` closes. Its verdict, scoping, and the conditions Phase 2
  inherits are in [decisions.md](decisions.md); the ledger in
  [README.md](README.md) is updated to match. Phase 2 opens as a **design**
  phase only -- no production storage change is licensed by `D1`, because every
  Phase 1 number is a microbenchmark and the README's first acceptance dimension
  gives the verdict to the paired ladder.
