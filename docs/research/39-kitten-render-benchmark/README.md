# Kitten render benchmark

Research started: 2026-08-28.

- [findings.md](findings.md) -- the evidence chain. `F1` is the first profile of
  the four in-scope arms; `F2` attributes the per-action memmove; `F3` refutes
  the idle half and corrects how `F1` read `sample`; `F4` and `F5` screen and
  confirm the four decision rules; `F6` is the post-`H1` ladder run and
  re-sample; `F7` is the control run that clears `F6`'s two `slower` verdicts;
  `F8` confirms `H3` and clears its one off-target `slower` verdict the same way;
  `F9` is the `scrollback-stream` re-screen that refuses a rule; `F10` is the
  post-`H3` kitten re-run and re-profile of all four arms; `F11` confirms `H2`
  and records the two shapes the measurement rejected; `F12` confirms `H4` on
  all three cluster shapes and takes the `csi` arm 2.1x.
- [decisions.md](decisions.md) -- the decision log. `D7` is the `H4` decision;
  its Settled note records what shipped and the one shape the measurement
  rejected.

## Purpose

`kitten __benchmark__ --render` is an external, reproducible stress test that
DanTerm loses to Ghostty by 2-5x on every arm that prints text. This doc owns
closing that gap on the four arms that render something -- `ascii`, `unicode`,
`unique_unicode`, `csi` -- and owns the tooling question that comes with it:
DanTerm's A/B ladder (`just benchmark-quick` / `benchmark-confirm`) contained
none of these stimuli, so a change aimed at them had no verdict rule. Part of
the work was a calibrated arm per stimulus that replays the kitten byte streams;
those four arms are now frozen (`D2`), so a fix here is decided the same way
every other performance change is.

Out of scope, by the user's instruction: `long_escape_codes` and `images`.
DanTerm already beats Ghostty on both.

## Investigation rules

- The funnel is fixed and evidence gates every step: a cause is a hypothesis
  until a finding (`F#`) attributes it with a profile; a fix is proposed only
  as a decision (`D#`) that puts the ideal structure beside any cheaper one and
  cites the finding; a decision is implemented only after the kitten arm exists
  in the ladder; it ships only on a ladder verdict; and it closes only when the
  kitten run itself moves. No step is skipped because the answer looks obvious.
- The kitten numbers are a reproduction, not a verdict. Read
  [agent-docs/measurement-discipline.md](../../../agent-docs/measurement-discipline.md)
  and [agent-docs/terminal-performance.md](../../../agent-docs/terminal-performance.md)
  before planning against a figure here. A change ships on a ladder verdict
  (`faster` at a frozen threshold), and the kitten run is re-taken afterwards
  as the external confirmation, never the other way round.
- Run kitten against an optimized slot (`just launch-slot-optimized`), never a
  debug build, and record the pane geometry: scroll cost is linear in rows.
- The kitten benchmark defaults to the alternate screen and `--repetitions 100`.
  Do not add `--with-scrollback` without saying so; it changes which scroll
  branch runs (`F1`).
- `sample` ranks frames inside a thread; it does not measure how busy a
  dispatch workloop thread is (`F3`). For on-CPU share use `proc_pid_rusage`
  or `ps -M`, and say which tool a percentage came from.
- A kitten `--render` figure depends on whether the terminal is drawing. Record
  the window state (frontmost, occluded, `--background`) with every number,
  for Ghostty as much as for DanTerm (`F3`: 28.9 to 86.4 MB/s on one host).
- A frame name says which code is on the stack, not which work disappears when
  the code is rewritten (`37/F4`). Trace the rewrite.
- Every kitten arm exercises the same feed path, so a fix for one arm is
  measured on all four before it is called a win; a win on `ascii` that costs
  `unique_unicode` is a trade-off to record, not a regression to hide.

## Trigger and current evidence

Reproduced 2026-08-28 on an optimized slot (`F1`), kitten 0.48.2, default
repetitions, alt screen:

| Arm | DanTerm (`F1`) | after `H1` (`F6`) | after `H3` (`F10`, frontmost) | after `H2` (`F11`, occluded) | now (`F12`, occluded) | Ghostty (user's run) | Ghostty preview (`F10`) | preview / now |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Only ASCII chars | 26.7 MB/s | 103.4 MB/s | 118.7 MB/s | 117.2 MB/s | 118.3 MB/s | 89.4 MB/s | 86.4 MB/s | 0.73x (DanTerm ahead) |
| Unicode chars | 18.8 MB/s | 30.1 MB/s | 36.2 MB/s | 37.2 MB/s | 37.2 MB/s | 112.1 MB/s | 111.4 MB/s | 3.0x |
| Unique multi-codepoint Unicode cells | 10.7 MB/s | 11.3 MB/s | 12.6 MB/s | 21.4 MB/s | 21.3 MB/s | 41.5 MB/s | 45.6 MB/s | 2.1x |
| CSI codes with few chars | 19.3 MB/s | 19.1 MB/s | 20.7 MB/s | 21.7 MB/s | 46.3 MB/s | 42.2 MB/s | 41.1 MB/s | 0.89x (DanTerm ahead) |

The `F11` column is the post-`H2` run at 66x179 on an occluded slot; its
`unique_unicode` figure is `D6`'s third confirmation criterion. The `F12`
column is the post-`H4` run at the same geometry and window state, and `F11` is
its control: only `csi` moves, 2.1x, and the other three sit inside their own
run-to-run spread. `csi` is the second arm on which DanTerm passes the Ghostty
preview figure, but that preview is not a closing table (see below), so this is
a direction and not a ranking.

The first two DanTerm columns are unpaired and occluded: each was taken on a
slot window that was not frontmost, so the terminal was not drawing, and neither
shares a session with the Ghostty column. `F10` re-took all four arms in both
window states and found no difference between them, so those columns are
comparable after all -- but the Ghostty preview column is still not a closing
table: Ghostty gave it 61 rows rather than 66, and the runs are sequential
rather than interleaved. The paired, frontmost, same-geometry comparison is
still Phase 4's job.

`F1` attributes every arm to `Terminal.feed` on the PTY-host thread, and `F3`
shows that thread at 98% user CPU for the whole run, so the MB/s figures are the
parser's true feed rate. `F1` also read the main thread as idle; that is no
longer true at HEAD, where the draw path costs about as much CPU as the parse on
three arms without yet costing MB/s (`F10`, `H7`). Paired Ghostty runs on this
host (`F3`) put `ascii` at 28.9-86.4 MB/s depending on whether Ghostty was
drawing, so the Ghostty columns above are an upper bound.

`H1`, `H3`, `H2` and `H4` have all shipped (`D4`, `D5`, `D6`, `D7`); `F10`
re-profiled all four arms after `H3`, `F11` re-profiled `unique_unicode` after
`H2`, which took the allocator out of the cluster append and made that arm 1.7x
faster, and `F12` re-ran all four after `H4`, which took the per-cell print out
of REP and made `csi` 2.1x faster. Of the hypotheses that remain, `H6` is next
-- 20% of the `ascii` thread, the per-line blank fill `H1` left behind, and
4.4% of `unicode`. Beside them sits a large block of cost that no hypothesis
covers: `printWide`'s cell stores (26% of `unicode`), `printBulkNarrow`'s
pre-write scan (7% of `ascii`), the per-print `invalidateInspection` and
`recordDamage` pair (15% of `unicode`, 15% of `csi`), `EscapeAbsorber.consume`
(13% of `csi`), and the `read` syscall (12% of `ascii`). On `csi` those shares
are read against the pre-`H4` thread; `F12` leaves that arm's remainder as
`D7`'s list -- the stream decoder at about a third of the thread, a style
intern per print, `\e[2K`'s row fill -- and none of it has a hypothesis yet.
Unicode decoding,
classification and grapheme breaking are about 26% of `unicode`, which is much
larger than the 5-10% the minor ledger item was written for. `H3`'s memmove is
gone from every arm. `H7` -- the render thread re-typesetting every line every
frame -- is new, costs about a core on three arms, and decides no MB/s today.

## Current hypotheses

### H1 -- Alt-screen scroll copies every row per line -- CONFIRMED and fixed

Confirmed by `F6` and shipped as `D4` (commit `873431d0`). The mechanism below
is the one the fix removed; it is kept for the record. The distinguishing
experiment ran, and its `advanceToNextRow < 10%` half is the one clause `F6`
had to re-read: the fix shrank the denominator 3.9x, so the frame reads 22.1%
of `ascii` parse while costing about 14x less per byte, and the samples still
under it are the new blank fill (`H6`), not the row copy the clause named.

Mechanism: `moveAndFillRows` takes the `moveInPlace` branch whenever
`pushesToScrollback` is false, which is always on the alt screen, so each line
advance copies `rows` `GridRow` values (three retain/release pairs and a
uniqueness check each) and allocates one blank row. Evidence: 80% of ASCII and
35% of Unicode parse samples under `advanceToNextRow` (`F1`). Competing
explanation: the cost is `recordScrollDamage` or `severWrapClaim`, not the
copies -- rejected by the line attribution (8592, the assignment) and the
retain/release/alloc leaf frames. Distinguishing experiment: rotate the deque
for the whole-screen alt case and re-sample; confirmed if `advanceToNextRow`
drops below 10% of parse and `ascii` MB/s moves.

### H2 -- Grapheme append allocates per scalar -- CONFIRMED and fixed

Confirmed by `F11` and shipped as `D6` (commit `2dc17304`). The mechanism below
is the one the fix removed; it is kept for the record. The distinguishing
experiment ran and both halves hold: every allocator frame together is 0.85% of
the append subtree, against about 37% before, and the kitten arm moves 12.6 ->
21.4 MB/s. The arena shipped without the span table, and readers copy a cluster
out rather than share the arena; `D6`'s Settled note says why.

Mechanism: a row keeps its multi-scalar payloads as a table of separate arrays
(`GridRow.spills`, `Terminal.swift:323`). The first mark on a cell takes
`appendScalar`'s slow path (`:382-390`): copy the inline base into a fresh
array, grow it, and copy it again to intern it -- three allocations, two frees
-- and the table is rebuilt at 32, 64 and 128 entries, three times per
179-column row. Every later mark takes the in-place path (`:384-386`) and copies
anyway, because `rememberOpenCluster` (`:7966-7973`) stores the same buffer in
`lastPrintedCluster` for REP, so it is never uniquely referenced -- one
allocation and one free per mark. About five allocations and four frees per
four-scalar cell. Evidence (`F10`): `appendToOpenClusterIfJoined` is 50.4% of the
`unique_unicode` PTY-host thread with `GridRow.appendScalar` 31.4% under it,
and the leaves are the allocator -- `malloc` 12.9%, free and dealloc 11.2%,
retain/release 15.0% (144 samples under `GridRow.scalars(of:)`),
`_ArrayBuffer._consumeAndCreateNew` 12.9%, `Array.init<A>` 8.9%,
`GridRow.place` 11.0%, `GridRow.intern` 4.7%. The same function is 10.4% of
`unicode`, mostly the guard chain on scalars that do not join; only the
allocator share is this hypothesis. `unique_unicode` feeds at 12.6 MB/s against
Ghostty's 45.6 (3.6x), `unicode` at 36 against 111 (3.1x). Competing
explanation: the cost is the grapheme-break decision rather than the storage --
rejected by the leaf frames, which are allocation and release, not
`shouldBreak`. Distinguishing experiment: give each row one flat scalar arena
with a span table so the open cluster grows at the arena tail, and stop the REP
memory aliasing the live payload (`D6`); confirmed if the allocator frames leave
the subtree of `appendToOpenClusterIfJoined` and the `unique_unicode` arm moves.

### H3 -- A mutating `Terminal` method copies the whole value to read its own state -- CONFIRMED and fixed

Confirmed by `F8` (the release object and the ladder) and closed by `F10` (the
kitten re-run, `D5`'s third criterion). The mechanism below is the one the fix
removed; it is kept for the record. `_platform_memmove` is now 0.34% of the
`ascii` thread, 0.16% of `unicode`, 0.10% of `csi`, and on `unique_unicode` its
2.5% is array growth, not a whole-value copy.

Mechanism: inside a `mutating` method `self` is an `inout` access, and calling a
non-inlined non-mutating member of `Terminal` on it makes the compiler
materialize a 1513-byte copy of the value first (`F2`). Two sites pay it
unconditionally on the feed path: `damageActionSnapshot` calling the public
`scrollProjection` getter, once per parser action and once per feed, and
`recoverClusterContextFromGridIfNeeded` calling `gridClusterPredecessor`, once
per print. The snapshot itself is about 120 bytes of POD and is not the cost;
`@inlinable` is not the knob, since both sides are one module. The release
object holds 58 sites of the shape; the other 56 are guarded or off the feed
path (`D5`). Evidence: the `memcpy` at `apply+392` with a 1513-byte length
(`F2`); on `F6`'s profile, 94% of the `_platform_memmove` samples on both
`ascii` and `unicode` sit under those two sites, 62% and 30% under `apply` and
the cluster site on `ascii`, 92% under `apply` on `unicode` (`D5`).
Distinguishing experiment: derive the projection from its inputs and resolve
the predecessor on the screen, so neither is a call on `inout self`; confirmed
if no copy of `MemoryLayout<Terminal>.size` bytes remains in the release
disassembly of any feed-path function, and all four arms move. The criterion is
read by copy size in the object, not as an absence of `_platform_memmove`
samples under either site: a profile stack carries no length, and small copies
legitimately stay on those paths (`F8`).

### H4 -- REP prints one scalar at a time -- CONFIRMED and shipped

Mechanism: `repeatLastPrintedCluster` (`Terminal.swift:7777-7795`) loops
`print(scalar, recoversGridContext: false)` `count` times, and every repeat
pays the single-cell print's per-call work: `invalidateInspection` and
`recordDamage(rows:)`, a content identity, `prepareDestination`'s two
wide-neighbour probes, and several copy-on-write uniqueness checks; only the
cell store and the cursor advance are per-cell by nature. The arm makes this
exact: its one REP band is ``\e[10`a\e[100b``, so every REP is `a` x100 at
column 10 of a 179-column row, never wrapping. Evidence (`F10`):
`repeatLastPrintedCluster` 56.3% of the `csi` thread, `printNarrow` 35.7%,
`invalidateInspection` 15.0%, `recordDamage(rows:)` 9.2%, uniqueness 7.6%,
`prepareDestination` 5.4%, the `print` call line the top leaf at 11.9%.
Competing explanation: the cost is the cluster memory rather than the print
path -- rejected by the leaf frames, which are all under `printNarrow`.
Distinguishing experiment: print the repeat as one run per row segment on the
bulk path and re-sample; confirmed if no per-cell `print` frame remains under
`repeatLastPrintedCluster` and the `csi` arm moves. The narrow-only prototype
ran (`D7`): `kitten-feed-csi` `faster` at -71.74% quick, the other three arms
`equivalent`, and the function fell from 56.3% to 9.6% of the thread with only
the segment stamp under it. The decision is the general run -- narrow, wide
and multi-scalar clusters -- not the narrow cut alone.

Confirmed by `F12` and shipped as `D7` (commits `ed2224cc` and `b5ea8ee6`).
All three criteria hold: the paired frame-presence table shows every per-cell
`print`, `printNarrow`, `printWide` and `appendToOpenClusterIfJoined` frame
present on the baseline and absent on the candidate for all three cluster
shapes, with damage, inspection and destination preparation surviving at
per-segment frequency; `kitten-feed-csi` reads `faster` at -73.05% on `confirm`
with no other arm `slower`; and the kitten arm moves 21.7 -> 46.3 MB/s.

### H6 -- A whole-viewport scroll still fills a whole row of blanks per line

Mechanism: the rotation `H1` installed recycles the evicted row by calling
`GridRow.resetAsBlank(columns:styleId:)`, which writes `columns` blank cells.
That is one 179-cell fill per line advance, and it is now the per-line residual
that the row copies used to hide. Evidence: 994 of 5546 `ascii` thread samples
(17.9%) on that one call site, and 1094 in `rotateViewportRows` overall, of
which only 55 are the deque operations (`F6`). Competing explanation: the fill
is the deque's own bookkeeping rather than the cell write -- rejected by the
line attribution, which puts 91% of the frame's samples on the `resetAsBlank`
call. Distinguishing experiment: none proposed yet. A blank row is a run of one
repeated value, so the shapes worth pricing are a memset-class fill and not
materializing the blank cells at all (a row that knows it is blank to column N).
Confirmed if `rotateViewportRows` leaves the `ascii` profile and the arm moves.

### H7 -- The render thread re-typesets every line on every frame

Mechanism: `TerminalFrameSwapchain.presentPending` -> `drawRenderFrame`
(`TerminalRenderExecution.swift:683`) -> `CGContextRef.drawTextRuns` (`:1246`)
calls `CTLineCreateWithAttributedString` per line per frame, so CoreText
shapes and encodes the glyphs again for every frame in which a line is drawn,
with nothing cached between frames; on the arms with little text the same
thread instead spends itself on CoreGraphics fills (`CGContextFillRect` ->
`memset_pattern16` on `ascii`, anti-aliased path fill on `csi`). Evidence
(`F10`): on `unicode` and `unique_unicode` the main thread is 99.6% of the
samples under the main-queue callback and about 1.0 core, beside a PTY-host
thread at about 1.0 core; `csi` about 0.6 core; `ascii` about 0.24. All of it
is real CPU -- CoreText and CoreGraphics frames, no `ulock_wait` or `psynch`.
Competing explanation: the cost is the frame cadence `--render` forces rather
than the typesetting, so a real workload drawing fewer frames would not pay it
-- the CPU share alone cannot tell those apart. Distinguishing experiment: cache
the shaped line or the glyph run across frames and re-measure the same profile;
or make the feed thread fast enough that the draw thread becomes the serial
constraint and watch MB/s. Note what this hypothesis does **not** claim: it
decides no MB/s today, because the feed thread is the bottleneck and `F10`'s
frontmost and occluded figures are identical on all six arms. It also maps to no
ladder arm -- every `kitten-feed-*` arm is headless -- so it cannot be gated the
way the others are, and a decision on it needs a measurement route first.

## Task ledger

### Phase 1 -- reproduce and attribute

- [x] Reproduce all four arms on an optimized slot and sample each. `F1`. DONE
- [x] Attribute the `apply` memmove to a line (`H3`). `F2`: a 1513-byte copy
  of `Terminal` before the `scrollProjection` getter. DONE
- [x] Explain the idle half (`H5`). `F3`: there is none; the PTY thread is at
  98% user CPU and `F1` misread `sample`. DONE
- [x] Recover the exact kitten byte streams. `D1`: the generator is now in
  `references/kitty/tools/cmd/benchmark/main.go`; two arms are unseeded
  random, so the fixture is a seeded port, not a recording. DONE

### Phase 2 -- a calibrated arm

- [x] Headless: four sibling workloads, `kitten-feed-ascii`,
  `kitten-feed-unicode`, `kitten-feed-unique-unicode`, and `kitten-feed-csi`,
  one per arm rather than corpora under `terminal-feed`, which feeds its whole
  corpus as one block and would give the four arms one shared verdict. The
  generator is a Swift port of `references/kitty/tools/cmd/benchmark/main.go`
  held to it by `scripts/kitten-benchmark-parity-lint.py`; the collector is
  `terminal-feed`'s, fed generated bytes instead of committed ones. All four
  entered `CANDIDATE_WORKLOADS` with no rule, per
  [plans/impl/2026-08-28-1145-kitten-feed-headless-arm.md](../../../plans/impl/2026-08-28-1145-kitten-feed-headless-arm.md).
  DONE
- [x] A/A series and a frozen threshold for whichever arm graduates, per
  [agent-docs/measurement-discipline.md](../../../agent-docs/measurement-discipline.md).
  All four arms were screened at 12 quartets and 50,000 trials and each selected
  cell confirmed at 100,000 trials on disjoint seeds (`F4`, which also carries
  the instrument defect that first blocked `kitten-feed-unicode`, commit
  `44aff52f`, and `F5`). `D2` then froze them: each arm decides at 2 pairs in
  both `quick` and `confirm`, ascii +/-1.7%, unicode +/-1.8%, unique-unicode
  +/-1.6%, csi +/-1.45%. All four names are in `WORKLOADS` and out of
  `CANDIDATE_WORKLOADS`, so `benchmark-confirm` runs them and
  `benchmark-quick workload=kitten-feed-<arm>` decides one. DONE

### Phase 3 -- fixes, each gated by the arm

- [x] `H1` whole-screen alt-scroll rotation; reuse the evicted row as the blank.
  Gate on the kitten arm plus `scrollback-stream` (the primary-screen branch
  must not regress). Decided as `D3`: the rotation is selected by the shape of
  the move (the range covers the viewport), not by whether the scroll pushes to
  scrollback, and the discarded row is reset in place instead of a blank being
  allocated. The row storage is already a `Deque`, so nothing about the
  container changes. Plan:
  [plans/impl/2026-08-28-1410-h1-alt-scroll-rotation.md](../../../plans/impl/2026-08-28-1410-h1-alt-scroll-rotation.md).
  Shipped as `873431d0` and confirmed by `F6`: `kitten-feed-ascii` `faster` at
  -123.61% and `kitten-feed-unicode` at -41.48% under `confirm`,
  `scrollback-stream` `faster` at -4.68%, kitten `ascii` 26.7 -> 103.4 MB/s, and
  no row-copy or blank-allocation frame left under the feed path. `D4` keeps it;
  the two unrelated `slower` cells it left open are cleared by `F7`. DONE
- [x] Settle `content-churn` (+1.76% `slower`) and `retained-browse` (+1.20%
  `slower`) from `F6` before another fix lands on the same cells. Neither
  workload's measured path reaches the one function `H1` changed, and neither
  rule is loose enough to dismiss on that reasoning alone, so the run is a
  `confirm` of the post-`H1` tree against itself -- a control the change cannot
  reach -- in the same session as a re-run of the real pair, with the
  `retained-browse` control on the other arm-slot parity. `D4`. Ran as `F7`:
  the change-free control called a direction on both cells (`content-churn`
  -1.54% `faster`, `retained-browse` +1.66% `slower`) while the re-run of the
  real pair read both `equivalent`, so neither verdict is attributable to
  `873431d0` and `H1` is fully closed. DONE
- [x] `H3` read the projection and the cluster predecessor from their inputs,
  not through a getter on `inout self`, and gate the feed path against a
  `Terminal`-sized copy returning. Gate on all four arms plus the full
  `confirm`; it is a fixed per-action cost so it should move every one of them.
  **The next task in this ledger**, on `F6`'s re-ranked profile (`memmove`
  13.9% of `ascii`, 18.4% of `unicode`); the control run ahead of it is done
  (`F7`). Decided as `D5`, which widens the hypothesis to the second site and
  records the storage-box ideal it does not build. Plan:
  [plans/impl/2026-08-28-1714-h3-terminal-self-copy.md](../../../plans/impl/2026-08-28-1714-h3-terminal-self-copy.md).
  Confirmed by `F8`: both copies are gone and all four arms plus `terminal-feed`
  read `faster` twice. Closed by `F10`, which is `D5`'s third criterion: the
  kitten arms read `ascii` 118.7, `unicode` 36.2, `unique_unicode` 12.6 and
  `csi` 20.7 MB/s frontmost at 66x179, up 7-20% on `F6`, and `memmove` is under
  0.4% of three of the four threads. DONE
- [ ] `D5`'s tooling gate: fail `just test-tooling` when a
  `MemoryLayout<Terminal>.size`-byte `memcpy` reappears in a feed-path function
  of the release object. Parked by the user; it is the one piece of `D5` that
  did not ship, and without it nothing stops site 59. TODO
- [x] `H2` a per-row scalar arena, so the open cluster grows in place, plus an
  unaliased REP memory. Decided as `D6`, shipped as `2dc17304`, confirmed by
  `F11`: `kitten-feed-unique-unicode` -50.52% and `kitten-feed-unicode` -3.26%
  faster, `ascii` and `csi` clear, `content-churn` and `retained-browse`
  equivalent, and the kitten arm 12.6 -> 21.4 MB/s. The span table and the
  reader-shared arena in `D6`'s text did not survive measurement; see `D6`'s
  Settled note. Plan:
  [plans/impl/2026-08-28-2226-open-cluster-scalar-arena.md](../../../plans/impl/2026-08-28-2226-open-cluster-scalar-arena.md).
  DONE
- [x] `H4` bulk REP, shipped as `D7` in `ed2224cc` and `b5ea8ee6`. REP prints
  one run of `count` identical cells per row segment on the bulk path, and the
  single-cell print takes only the cells the bulk path declines. `F12`:
  `kitten-feed-csi` -73.05% on `confirm` with no other arm `slower`, the kitten
  arm 21.7 -> 46.3 MB/s, and no per-cell print frame left under REP on any of
  the three cluster shapes. The range-prepare shape in `D7`'s text replaced a
  per-cell destination refusal that made the wide path dead on a repainted CJK
  row; see `D7`'s Settled note. Plan:
  [plans/impl/2026-08-29-1345-bulk-rep-runs.md](../../../plans/impl/2026-08-29-1345-bulk-rep-runs.md).
  DONE
- [ ] `H6` the per-line blank fill the rotation left behind (20% of the `ascii`
  thread, 4.4% of `unicode`). Gate on `kitten-feed-ascii` and
  `kitten-feed-unicode`; no decision written yet. **The next task in this
  ledger**: it is the top item on the arm DanTerm already wins, so it buys the
  least against Ghostty, but it is the largest remaining share with a
  hypothesis. TODO
- [ ] `H1` partial-region scroll: move row handles, not `GridRow` values. TODO
- [ ] `H7` the render thread's per-frame CoreText typesetting. It costs about a
  core on three arms and no MB/s today, and it maps to no ladder arm. Measure
  and decide after `H2` -- either from a shaped-line cache prototype or once the
  feed thread is fast enough for the draw thread to bind. TODO
- [ ] `printBulkNarrow` refuses a destination cell that is not `.narrow` or
  `.padding`, so an ASCII byte run written over a row of wide cells falls out
  of the bulk path once per cell. `printBulkCluster` (`H4`) meets the same
  obligation once for a whole range, and the two could share that range
  prepare; `F12` records why the range form is equivalent rather than merely
  cheaper. Unmeasured and not a hypothesis: no arm and no frozen workload feeds
  ASCII over wide content, so there is no evidence it costs anything today.
  What it would take to act: a profile of a real stimulus -- a program
  repainting a CJK line with ASCII, which is what a pane redraw over CJK output
  does -- showing `printNarrow` frames under `printASCIIRun`, plus a workload
  that reproduces it and can be frozen. Until such a stimulus exists, treat a
  proposal to unify them as a change with no measurement behind it and refuse
  it on `D2` grounds. RESEARCH
- [ ] Unattributed cost, carried so it is not lost -- none of these has a
  hypothesis: `printBulkNarrow`'s `readingRowCells` pre-write scan (7% of
  `ascii`), `printWide`'s head and tail cell stores (26% of `unicode`), the
  per-print `invalidateInspection` and `recordDamage` pair (15% of `unicode`,
  15% of `csi`), `EscapeAbsorber.consume` (13% of `csi`), and the `read` syscall
  (12% of `ascii`). `F10`. RESEARCH
- [ ] Minor: the per-turn `Array(UnsafeBufferPointer)` copy in
  `takeOutputTurn` (3-4%), and per-scalar Unicode decoding and classification in
  `TerminalInputStream.nextAction`, which `F10` prices at about 26% of the
  `unicode` thread rather than the 5-10% this line was written for. Only after
  the fixes above; they will not decide anything on their own. TODO

### Phase 4 -- close

- [ ] Re-run all six kitten arms (the two out-of-scope ones as a regression
  check) against Ghostty on the same host, same session, and record the table
  in `## Outcome`. TODO

## Rejected

- `H5` (the pipeline is half idle on the cheap arms). `F3`: the PTY-host
  thread runs at 98% user CPU for the whole `ascii` run; `read` is 3% of it.
  The 50% figure in `F1` came from `sample`'s per-thread counts, which
  undercount a dispatch workloop queue. The PTY-path arm that depended on it
  is dropped from Phase 2.

## Open questions and caveats

- The four `kitten-feed-*` arms now have one whole-`confirm` A/A data point,
  which `D2` said they lacked: all four read `equivalent` on `F7`'s change-free
  control, largest magnitude 0.72% against thresholds of 1.45-1.80%. One
  invocation is not a control series, so the freeze still rests on the
  calibration screens.
- `scrollback-stream` called `faster` twice in `F7`'s session, once on identical
  code. That matches its known record -- worst A/A estimate 3.48 points against
  a 1.85% threshold, 3 of 8 false directional calls -- so it is a fact about
  that rule, owned by `research/7`, not something this doc fixes. Read any
  `scrollback-stream` direction here as unreliable in both directions. The rule
  is now vacated, and the re-screen that could have replaced it refused one
  (`F9`), so every `scrollback-stream` number in this doc is descriptive.
- Neither Ghostty column in the trigger table is a closing table. The first is
  the user's run, on another host and session. The second is `F10`'s preview:
  frontmost on this host and session, but Ghostty gave it 61 rows against
  DanTerm's 66, and the two terminals ran sequentially rather than interleaved.
  Phase 4's table must be paired, same-geometry, and must record each window's
  state (`F3`).
- kitten's writer spins on `EAGAIN` against a 2048-byte kernel high-water
  mark (`F3`), so its process burns a core in the kernel under any terminal.
  It is not DanTerm's cost, and a headless replay will not reproduce it.
- The pane geometry for `F1` was the slot's default window, not the canonical
  179x66; scroll cost per line scales with the row count, so the ASCII share
  is geometry-dependent. `F6`'s re-sample used 66 rows x 179 columns.
- Every DanTerm kitten figure before `F10` (`F1`, `F3`, `F6`) was taken on a
  slot window that was not frontmost, so DanTerm was not drawing. `F10` took all
  six arms in both states and found every pair inside its own run-to-run spread,
  so those figures compare cleanly to a frontmost one. Phase 4 still pairs
  frontmost, because the Ghostty side of the comparison is not state-independent
  (`F3`: 28.9 to 86.4 MB/s on one arm).
- `--render` **does** put drawing on the profile at HEAD, which reverses what
  `F1` and `F3` recorded. `F10` measures the main thread at about 1.0 core on
  `unicode` and `unique_unicode`, 0.6 on `csi` and 0.24 on `ascii`, beside a
  PTY-host thread at about 1.0 core, all of it CoreText and CoreGraphics work.
  It does not change the MB/s ranking today -- the feed thread binds, and the
  frontmost and occluded figures are identical -- and it is now `H7`.

## Outcome

Open.
