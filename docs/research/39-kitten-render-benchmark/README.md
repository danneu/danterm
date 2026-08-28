# Kitten render benchmark

Research started: 2026-08-28.

- [findings.md](findings.md) -- the evidence chain. `F1` is the first profile of
  the four in-scope arms; `F2` attributes the per-action memmove; `F3` refutes
  the idle half and corrects how `F1` read `sample`; `F4` and `F5` screen and
  confirm the four decision rules; `F6` is the post-`H1` ladder run and
  re-sample.
- [decisions.md](decisions.md) -- the decision log.

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

| Arm | DanTerm (`F1`) | DanTerm after `H1` (`F6`) | Ghostty | Ghostty / DanTerm now |
| --- | --- | --- | --- | --- |
| Only ASCII chars | 26.7 MB/s | 103.4 MB/s | 89.4 MB/s | 0.9x (DanTerm ahead) |
| Unicode chars | 18.8 MB/s | 30.1 MB/s | 112.1 MB/s | 3.7x |
| Unique multi-codepoint Unicode cells | 10.7 MB/s | 11.3 MB/s | 41.5 MB/s | 3.7x |
| CSI codes with few chars | 19.3 MB/s | 19.1 MB/s | 42.2 MB/s | 2.2x |

Both DanTerm columns are unpaired and occluded: each was taken on a slot window
that was not frontmost, so the terminal was not drawing, and neither shares a
session with the Ghostty column. `F3` measured a 3x swing on Ghostty from that
state alone, so no ratio in this table is a paired result. The Phase 4 table is
where a paired, frontmost comparison gets made.

`F1` attributes every arm to `Terminal.feed` on the PTY-host thread; the main
thread is idle throughout, and rendering is not in the picture despite
`--render`. `F3` shows that thread at 98% user CPU for the whole run, so the
MB/s figures are the parser's true feed rate. Paired Ghostty runs on this host
(`F3`) put `ascii` at 28.9-86.4 MB/s depending on whether Ghostty was drawing,
so the Ghostty column above is an upper bound.

`H1` shipped (`D4`) and re-ranked what is left. `F6`'s re-sample of `ascii`
gives `printBulkNarrow` 29.0%, `execute` 17.9%, the recycled row's blank fill
17.9%, `_platform_memmove` 13.9%, `read` 11.4%, `nextAction` 9.4%, `softWrap`
7.8%; on `unicode`, `printWide` 21.7%, `_platform_memmove` 18.4%, `nextAction`
13.9%, `invalidateInspection` 8.8%, `appendToOpenClusterIfJoined` 8.3%. Read
those shares against a denominator `H1` shrank by 3.9x on `ascii`: the absolute
per-byte cost of `memmove` and `read` did not grow. `printBulkNarrow` and
`printWide` are the largest items and are the printing itself, with no
hypothesis that removes them. Of the items that have one, `H3` is next -- a
fixed per-action tax that should move all four arms -- followed by `H6`, the
per-line blank fill `H1` left behind. `H2` still owns `unique_unicode` and `H4`
still owns `csi`; `F6` shows neither arm moved.

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

### H2 -- Grapheme append allocates per scalar

Mechanism: `GridRow.appendScalar` copies the cluster into a fresh array,
appends, and re-interns it as a new spill; every joined scalar costs about three
allocations and two frees. Evidence: 60% of `unique_unicode` parse under
`appendToOpenClusterIfJoined`, leaf frames are `swift_allocObject`,
`_consumeAndCreateNew`, `malloc_size`, `_swift_release_dealloc` (`F1`).
Distinguishing experiment: buffer the open cluster outside the row and place it
once when it closes (or append in place into a per-row scalar arena); confirmed
if the allocation frames leave the profile.

### H3 -- Taking the damage snapshot copies the whole `Terminal` per action

Mechanism: `damageActionSnapshot` calls the public, non-inlined
`scrollProjection` getter on `inout self`, and the compiler materializes a
1513-byte copy of `Terminal` to do it, once per parser action (`F2`). The
snapshot itself is about 120 bytes of POD and is not the cost. Evidence: the
`memcpy` at `apply+392` with a 1513-byte length, sitting between the action
switch and the getter call; 12% of parse on the Unicode arms and ~4% on
`ascii` (`F1`). Distinguishing experiment: have the snapshot read
`isAlternateScreenActive` and the projection inputs directly (or make the
getter inlinable); confirmed if the `memcpy` leaves the disassembly and the
memmove leaves the profile on all four arms.

### H4 -- REP prints one scalar at a time

Mechanism: `repeatLastPrintedCluster` loops `print(scalar)` `count` times and
each `printNarrow` pays inspection invalidation and damage per cell. Evidence:
45% of CSI parse (`F1`). Distinguishing experiment: route single-scalar narrow
REP through `printBulkNarrow`; confirmed on the `csi` arm alone.

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
  no row-copy or blank-allocation frame left under the feed path. `D4` keeps it
  and leaves two unrelated `slower` cells open. DONE
- [ ] Settle `content-churn` (+1.76% `slower`) and `retained-browse` (+1.20%
  `slower`) from `F6` before another fix lands on the same cells. Neither
  workload's measured path reaches the one function `H1` changed, and neither
  rule is loose enough to dismiss on that reasoning alone, so the run is a
  `confirm` of the post-`H1` tree against itself -- a control the change cannot
  reach -- in the same session as a re-run of the real pair, with the
  `retained-browse` control on the other arm-slot parity. `D4`. TODO
- [ ] `H6` the per-line blank fill the rotation left behind (17.9% of the `ascii`
  thread). Gate on `kitten-feed-ascii` and `kitten-feed-unicode`; no decision
  written yet. TODO
- [ ] `H1` partial-region scroll: move row handles, not `GridRow` values. TODO
- [ ] `H2` open-cluster buffering or per-row scalar arena. Gate on
  `unique_unicode`; check `content-churn` for glyph-path fallout. TODO
- [ ] `H3` snapshot diet or dirty bits. Gate on all four arms; it is a fixed
  per-action cost so it should move every one of them. **Next fix on `F6`'s
  re-ranked profile** (`memmove` 13.9% of `ascii`, 18.4% of `unicode`), after
  the control run above. TODO
- [ ] `H4` bulk REP. Gate on `csi`. TODO
- [ ] Minor: the per-turn `Array(UnsafeBufferPointer)` copy in
  `takeOutputTurn` (3-4%), and per-scalar Unicode classification in
  `TerminalInputStream.nextAction` (5-10% on Unicode). Only after the five
  above; they will not decide anything on their own. TODO

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

- The Ghostty figures in the trigger table are the user's run, not a paired
  run on this host in this session; the closing table in Phase 4 must be
  paired, and must record each window's state (`F3`).
- kitten's writer spins on `EAGAIN` against a 2048-byte kernel high-water
  mark (`F3`), so its process burns a core in the kernel under any terminal.
  It is not DanTerm's cost, and a headless replay will not reproduce it.
- The pane geometry for `F1` was the slot's default window, not the canonical
  179x66; scroll cost per line scales with the row count, so the ASCII share
  is geometry-dependent. `F6`'s re-sample used 66 rows x 179 columns.
- Every DanTerm kitten figure recorded so far (`F1`, `F3`, `F6`) was taken on a
  slot window that was not frontmost, so DanTerm was not drawing. That is a
  consistent condition across the two `ascii` numbers being compared, and it is
  not the condition Phase 4 must pair in.
- `--render` did not put drawing on the profile at all, and `ps -M` (`F3`)
  shows no second busy thread in DanTerm, while Ghostty's renderer ran at 58%
  beside its reader. Whether DanTerm's draw path keeps up or the slot's
  `--background` window never draws is not established and does not change the
  ranking; the Phase 4 pairing must run both terminals frontmost.

## Outcome

Open.
