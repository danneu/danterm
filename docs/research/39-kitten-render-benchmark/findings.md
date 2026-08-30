# Findings

## F1 -- Every in-scope arm is bound by `Terminal.feed` on the PTY-host thread

**Observed** (2026-08-28, optimized slot build of the working tree at
`53230547` plus untracked scratch docs; kitten 0.48.2; `--render`, alt screen,
100 repetitions; `sample <pid>` for 5-10 s per arm at 1 ms):

| Arm | MB/s | PTY thread on-CPU share of wall | Top inclusive frames (share of `takeOutputTurn` samples) |
| --- | --- | --- | --- |
| ascii | 26.7 | 50% (3403/6760) | `advanceToNextRow` 80% (2623/3288); `printBulkNarrow` ~9%; `apply` memmove 4% |
| unicode | 18.8 | 89% (5914/6646) | `advanceToNextRow` 35% (2026/5770); `printWide` 12%; `apply` memmove 12.5% (723); `nextAction` 10% |
| unique_unicode | 10.7 | 99% (8039/8093) | `appendToOpenClusterIfJoined` 33% (2589/7858); release/dealloc under `print` 8%; `apply` memmove 12% (933); `nextAction` 7% |
| csi | 19.3 | 37% (1572/4200) | `repeatLastPrintedCluster` 37% (561/1532); `nextAction`/`EscapeAbsorber` 16%; `apply` memmove 6% |

The main thread's only work in any sample is the deferred fence
(`TerminalPaneSessionController.deferredFenceElapsed` -> `queue.sync` on the
PTY host, 113 of 6760 samples on `ascii`) and one reconcile. No draw frames
appear in any sample. During `ascii`, `ps` showed kitten at 100% CPU and
DanTerm at 123%.

Leaf attribution inside the hot frames:

- `advanceToNextRow` -> `moveAndFillRows` (`Terminal.swift:8591-8592`, the
  `moveInPlace` closure): `swift_retain`/`swift_release`/
  `swift_bridgeObjectRetain`/`Release`, `swift_isUniquelyReferenced_nonNull_native`,
  and `ContiguousArray._createNewBuffer` -> `swift_allocObject`. The
  `rotatesWholeViewport` branch never runs: it requires `pushesToScrollback`,
  which the alt screen never sets.
- `appendToOpenClusterIfJoined` -> `GridRow.appendScalar` (`Terminal.swift:382`)
  -> `Array.init`, `_ArrayBuffer._consumeAndCreateNew`, `malloc_size`,
  `GridRow.place` -> `intern` -> `compactSpills`; the matching
  `_swift_release_dealloc` shows under `print`.
- `apply` (`Terminal.swift:1886` region): `_platform_memmove` attributed to
  `Terminal.swift:0`, beside `recordDamage(from:to:)`. `DamageActionSnapshot`
  embeds a `TerminalPresentation` and two optional `TerminalTextRange`s.
- `repeatLastPrintedCluster` (`Terminal.swift:7433`) -> `printNarrow` ->
  `invalidateInspection` + `recordDamage(rows:)` per cell.

**Inferred:** four independent costs inside the terminal (scroll copy,
cluster append allocation, per-action snapshot, scalar REP) plus one pipeline
cost outside it (the idle half on the cheap arms). The parse rate while the
thread is busy is roughly 2x the reported MB/s on `ascii` and `csi`, so on
those two arms a parse fix alone caps out well short of Ghostty until the idle
is explained.

**Alternatives:** the `apply` memmove could be the `TerminalStreamAction`
payload rather than the snapshot; the idle could be kitten's own cost rather
than DanTerm's handoff. Both are Phase 1 tasks.

**Confidence:** high on the ranking and on H1/H2/H4 (leaf frames and source
agree); medium on H3 (line not attributed); low on the cause of H5.

**Unlocks:** Phase 1 attribution tasks and the arm design (`D1`).

Artifacts: the raw `sample` files were session-local and are not committed;
the table above is the compact excerpt. Re-take with
`just launch-slot-optimized`, `danterm tab new --cmd 'kitten __benchmark__ --render <arm>'`,
and `sample <pid> 8 -mayDie -file <out>`.

## F2 -- The `apply` memmove is a 1513-byte copy of `Terminal` per action, not the snapshot

**Observed** (2026-08-28, optimized slot build of the same tree, `lldb
disassemble` of `Terminal.apply(_:in:before:)`): the frame `F1` reported as
`apply+396` is the return address of `bl memcpy` at `apply+392`, with
`x2 = 0x5e9` (1513 bytes), source `x21` (`self`), destination a stack
temporary. The copy sits after the action `switch` and immediately before the
first call of the inlined `damageActionSnapshot` getter, which is
`Terminal.scrollProjection.getter` (`Terminal.swift:2761`), a `public`
computed property that is not inlined. `MemoryLayout` in a debug test run:
`DamageActionSnapshot` members sum to about 120 bytes
(`TerminalCursor?` 17, two `TerminalTextRange?` 33 each, three words, three
`Bool`s, `TerminalPresentation` 4); `TerminalStreamAction` is 66 bytes
(stride 72), sized by `CSISequence`'s `InlineArray<24, UInt16>`.

**Inferred:** the compiler materializes a full copy of `self` to call the
`scrollProjection` getter on an `inout self` inside a `mutating` method, once
per parser action, on every arm. Neither the snapshot nor the action payload
is the memmove: both are an order of magnitude smaller than 1513 bytes.
`H3`'s mechanism is therefore wrong in detail (the snapshot is already POD, as
`research/17/F7` made it) but right in shape: a fixed per-action tax, paid on
every arm, that disappears if the snapshot getter stops calling an opaque
getter on `self`.

**Alternatives:** the copy could be forced by something else in the getter
chain rather than `scrollProjection` specifically; the disassembly places it
at that call, but only a rebuild that reads `isAlternateScreenActive` and the
projection fields directly (or makes the getter `@inlinable`/internal) proves
it by removing the memcpy. That is the Phase 3 `H3` experiment.

**Confidence:** high on the size and site; medium on the exact trigger.

**Unlocks:** `H3` becomes a concrete, one-site experiment gated on all four
arms.

Artifacts: `Terminal.apply` disassembly excerpt (`+380` to `+404`):

```
add    x0, sp, #0x160
mov    x1, x21
mov    w2, #0x5e9                ; =1513
bl     memcpy
add    x20, sp, #0x160
bl     Terminal.scrollProjection.getter [inlined isAlternateScreenActive]
```

## F3 -- There is no idle half: the PTY-host thread is at 98% user CPU, and `F1`'s "on-CPU share" was a `sample` artifact

**Observed** (2026-08-28, same slot, `ascii` arm, pane 66 rows x 179
columns, kitten 0.48.2 `--render`, 100 repetitions):

- `proc_pid_rusage` polled every 0.5 s during the run: DanTerm gained
  0.50 s user + 0.02 s system per 0.52 s of wall; kitten gained 0.12 s user
  + 0.41 s system per 0.52 s of wall (100% of a core, 79% in the kernel).
- `ps -M` mid-run: one DanTerm thread at 98.2% CPU (the PTY host), the next
  at 0.3%.
- `sample` of the same run: the `terminal-pty-host` queue appeared in 2172 of
  about 6300 in-run samples, with the rest of the process's threads parked in
  `__workq_kernreturn` and the main thread in `mach_msg`. That is the "50%
  idle" figure `F1` reported. `sample` labels the queue's worker
  `Thread_<multiple>`: the dispatch workloop hops thread identities and
  `sample` does not credit every identity to the queue, so per-thread sample
  counts undercount a workloop queue. `rusage` and `ps -M` are the
  authority; `sample` remains valid for the frame ranking inside the thread.
- Inside the PTY thread's samples: `Terminal.feedBuffer` 2023 of 2076
  `takeOutputTurn` samples, the `read` syscall 66 (3%).
- kitten's writer: 88% of its samples inside the `write` syscall. kitten
  opens the tty `O_NDELAY` (`references/kitty/tools/tty/tty.go`,
  `OpenTerm`) and `WriteAll` retries `EAGAIN` in a loop with no poll, so
  whenever the tty output queue is over its high-water mark -- `TTMAXHIWAT`
  is 2048 bytes (`references/xnu/bsd/sys/tty.h:184`) and `ttwrite` returns
  `EWOULDBLOCK` past it (`references/xnu/bsd/kern/tty.c`, `ovhiwat`) -- the
  writer spins in the kernel. That spin is kitten's 79% system time. It is
  identical under Ghostty (0.11 s user + 0.42 s system per 0.52 s), so it is
  the writer's fixed behavior, not a DanTerm effect.
- Paired Ghostty runs on this host, same kitten, `--window-width=179
  --window-height=66` (Ghostty sized the grid 61x215): 86.4, 53.3, and
  28.9 MB/s across three launches. The 28.9 run was a freshly launched,
  frontmost window with the renderer thread at 58% CPU beside the reader at
  99%; the faster runs had other Ghostty windows in front. Ghostty's reader
  is CPU-bound too when it draws.

**Inferred:** `H5` is refuted. The `ascii` arm is bound by the parse in the
PTY thread, so the 26.7 MB/s in the trigger table is the thread's true feed
rate, not half of it, and a parse fix is not capped by any pipeline idle. The
delivery path -- 1024-byte kernel reads chained inside one turn, the 16 KiB
turn cap, the dispatch re-arm -- costs about 3% (the `read` share) and is not
worth an arm of its own. The kitten `--render` figure for any terminal is
sensitive to whether the terminal is actually drawing; the trigger table's
Ghostty column is an upper bound taken with rendering effectively off.

**Alternatives:** the discrepancy could be `sample` throttling the process
rather than mis-crediting threads; either way the process-level counters
stand and the conclusion does not change.

**Confidence:** high.

**Unlocks:** drops the PTY-path arm from Phase 2; moves `H5` to Rejected;
sets the rule that the Phase 4 pairing must state each terminal's window
state.

Artifacts: `rusage.c` (a `proc_pid_rusage` poller), `run-arm-rusage.sh`, and
the per-run `rusage-*.txt` / `threads-*.txt` / `*.sample.txt` files were
session-local in the agent scratchpad and are not committed. Re-take by
running the arm inside a slot tab while polling `proc_pid_rusage` for both
pids and taking `ps -M <pid>` once mid-run.

## F4 -- All four kitten arms screen clean at 12 quartets, and calibrating on the block floor was what blocked `unicode`

**Observed** (2026-08-28, `scripts/terminal-benchmark-candidate-screen.py`,
12 quartets per arm, 50,000 trials, seed 20260730, AC power, machine
otherwise idle):

First pass, at tree `029983934c37` (commit `4d8c3fab`):

| Arm | Quartets kept | A/A median | SD (trimmed) | quick / confirm |
| --- | --- | --- | --- | --- |
| ascii | 12 | +0.13% | 1.18% (0.92%) | 2 pairs, +/-1.55% |
| unicode | -- | -- | -- | could not collect |
| unique_unicode | 12 | -0.12% | 0.92% (0.75%) | 2 pairs, +/-1.5% |
| csi | 12 | -0.02% | 0.96% (0.85%) | 2 pairs, +/-1.55% |

`unicode` failed with `quartet 1 never produced four valid blocks in 4
attempts`, every discard `block-N-below-duration-floor`. Measured directly
against the arm binary, at ~167 ms per execution: six executions total
1.001-1.007 s against a 1.000 s floor, seven total 1.16-1.19 s, and the
2-iteration calibration chose six in three of six runs. Batch counts and
margins over the floor on the other arms: ascii 8 (+4.5%), unique_unicode 4
(+17%), csi 11 (+3%).

Second pass, at tree `2777b652f708` (commit `44aff52f`, calibration aiming a
fifth above the floor):

| Arm | Quartets kept | A/A median | SD (trimmed) | quick | confirm |
| --- | --- | --- | --- | --- | --- |
| ascii | 12 | +0.13% | 0.86% (0.69%) | 2 pairs, +/-1.35% | 2 pairs, +/-1.35% |
| unicode | 12 | +0.09% | 1.18% (0.68%) | 2 pairs, +/-2.6% | 4 pairs, +/-1.25% |
| unique_unicode | 12 | +0.15% | 0.98% (0.74%) | 2 pairs, +/-1.3% | 2 pairs, +/-1.3% |
| csi | 12 | -0.02% | 0.90% (0.70%) | 2 pairs, +/-1.1% | 2 pairs, +/-1.1% |

A/A false positives 0.0000 in every second-pass cell except `unicode`'s
confirm (0.0069); detection 0.956 or better throughout.

Reports: `.build/terminal-benchmark-candidate-screens/2777b652f708-{0000
unicode, 0001 ascii, 0002 unique-unicode, 0003 csi}`, and the first pass at
`029983934c37-{0000 ascii, 0002 unique-unicode, 0003 csi}`. `.build/` is
disposable; the values above are the record.

**Inferred:** every arm's A/A noise is small enough to support a rule at 2
pairs, except `unicode`, which needs 4 pairs at confirm. The `unicode`
failure was an instrument defect, not a property of the stimulus: the
calibration aimed at the same duration the collector judges a block by, so
the batch count it settled on left a margin set by batch-count discreteness
rather than by design. `csi` had the same defect latent at +3%.

**Alternatives:** the second pass's tighter thresholds could be a quieter
machine rather than the larger batches. Both passes ran on AC with the
machine idle and their host-condition readings are in the reports; the
direction is consistent across all three re-screened arms, which a load
difference would not have to produce.

**Confidence:** high for the collection outcome and the `unicode` root cause,
both reproduced directly. Medium for the exact thresholds, which are one
screen each and not yet confirmed.

**Unlocks:** Phase 2 task 1 is measurable on all four arms. Freezing still
needs the confirmation the corpus protocol requires -- re-run each selected
cell with disjoint fresh seeds at 100,000 trials -- before a human moves a
threshold into `DECISION_RULES` and the name into `WORKLOADS`. Nothing has
been written to either.

## F5 -- All four arms confirm at 100,000 trials on fresh seeds, so each has a rule a human can freeze

**Observed** (2026-08-28, tree `83badba2973b`, commit `12459885`, AC power,
machine otherwise idle). A third screen pass, needed because the confirmation
resamples whole schedule quartets and the earlier reports persisted only a flat
list of pairs -- 12 quartets per arm, 50,000 trials, seed 20260730:

| Arm | Quartets kept | A/A median | SD (trimmed) | quick | confirm |
| --- | --- | --- | --- | --- | --- |
| ascii | 12 | -0.06% | 1.27% (1.02%) | 2 pairs, +/-1.7% | 2 pairs, +/-1.7% |
| unicode | 12 | -0.08% | 1.24% (1.02%) | 2 pairs, +/-1.8% | 2 pairs, +/-1.8% |
| unique_unicode | 12 | -0.28% | 1.32% (1.00%) | 2 pairs, +/-1.6% | 2 pairs, +/-1.6% |
| csi | 12 | -0.21% | 1.60% (1.39%) | 2 pairs, +/-1.45% | 2 pairs, +/-1.45% |

Then the confirmation of exactly those eight cells, at 100,000 trials per
condition on seed base 20260828 -- disjoint from the screen's 20260730, with no
other parameter changed:

| Arm | quick | confirm | A/A false positives | Detection (positive/negative) |
| --- | --- | --- | --- | --- |
| ascii | holds | holds | 0.0000 / 0.0000 | 1.0000/1.0000, 0.9573/0.9589 |
| unicode | holds | holds | 0.0000 / 0.0000 | 1.0000/1.0000, 0.9191/0.9161 |
| unique_unicode | holds | holds | 0.0000 / 0.0000 | 1.0000/1.0000, 0.9151/0.9578 |
| csi | holds | holds | 0.0000 / 0.0000 | 1.0000/1.0000, 1.0000/1.0000 |

Each arm was confirmed on its own series, never pooled. Reports:
`.build/terminal-benchmark-candidate-screens/83badba2973b-{0000 ascii, 0001
unicode, 0002 unique-unicode, 0003 csi}`, screen and confirmation side by side
in each. `.build/` is disposable; the values above are the record.

**Inferred:** every arm supports a rule at 2 pairs in both modes, and the pair
count no longer differs between them -- F4's `unicode` confirm cell at 4 pairs
did not reproduce. Detection is the binding gate everywhere (0.915 against a
0.90 floor on `unicode` and `unique_unicode`), not the A/A false-positive rate,
which is zero in all eight cells.

**Alternatives:** this pass's thresholds sit above F4's second pass (+1.7% vs
+1.35% on ascii) on a series with a wider A/A SD (1.27% vs 0.86%), so the
machine was less quiet than in F4. That direction is the conservative one: a
noisier series buys a looser threshold, and the cells still confirmed. A quieter
re-screen would be expected to tighten them, not to overturn one.

**Confidence:** high. The screen and the confirmation are two independent
resamplings of the same evidence at the two trial counts the corpus protocol
prescribes, and the confirmation's gate audit is unit-tested to fail a cell that
stops clearing.

**Unlocks:** Phase 2 task 2's mechanical half is complete for all four arms.
What is left is the human act: move each threshold into `DECISION_RULES` and
each name out of `CANDIDATE_WORKLOADS` into `WORKLOADS`. Nothing has been
written to either, and until it is, Phase 3 reads the arms descriptively.

## F6 -- `H1` is confirmed: the row copies and the blank allocation are gone, `ascii` feeds 3.9x faster, and two unrelated arms of the ladder read `slower`

**Observed** (2026-08-28). Two measurements of commit `873431d0` (the
whole-viewport rotation with the evicted row reset in place and reused as the
blank) against its parent `da2d1023`.

### The ladder

`just benchmark-confirm baseline=da2d1023`, baseline tree `fe338bdcd243`,
candidate tree `9a2ccb72e8d5` (the working tree it captured is nine doc and plan
paths, no code). Host load 1.94/3.10/4.07 at invocation, 0.19 per processor
across 10; busiest external process `claude` at 13.2%. Total 351.7 s. Artifacts:
`.build/terminal-benchmark-comparisons/confirm/9a2ccb72e8d5-0000`.

| Workload | Pairs | Symmetric median | Verdict |
| --- | ---: | ---: | --- |
| `kitten-feed-ascii` | 2 | -123.61% | faster |
| `kitten-feed-unicode` | 2 | -41.48% | faster |
| `kitten-feed-unique-unicode` | 2 | -1.17% | inconclusive |
| `kitten-feed-csi` | 2 | +1.30% | inconclusive |
| `scrollback-stream` | 4 | -4.68% | faster |
| `terminal-feed` | 2 | -2.20% | inconclusive |
| `content-churn` | 4 | +1.76% | slower |
| `style-churn` | 4 | +0.93% | inconclusive |
| `incremental-mixed` | 6 | -0.67% | descriptive only |
| `retained-browse` | 4 | +1.20% | slower |

`scrollback-stream`'s composition: drain 42.8 ms / 35.7 MB/s baseline against
41.0 ms / 37.2 MB/s candidate, draw tail 20.7% against 20.4% of the block.
`content-churn`'s two descriptive quantities: plan time -0.22%, process CPU
+1.13%. `style-churn`: plan -0.72%, process CPU +0.81%.

The earlier `quick` gate on the same baseline read ascii -122.86%,
unicode -40.99%, unique-unicode -2.10%, csi -1.45%, all four `faster`, and
`scrollback-stream` -14.46% `faster`.

### The kitten run and the re-sampled profile

Optimized slot 1 at `873431d0`, kitten 0.48.2, `--render`, alternate screen,
66 rows x 179 columns (`F1`'s geometry), **window not frontmost** -- it sat
occluded behind the canonical instance, because `launch-slot-optimized` is
unattended. No Ghostty pairing was taken.

| Arm | MB/s, run 1 | MB/s, run 2 | `F1` | Move |
| --- | ---: | ---: | ---: | ---: |
| ascii | 103.4 | 103.8 | 26.7 | 3.9x |
| unicode | 30.1 | 30.1 | 18.8 | 1.60x |
| unique_unicode | 11.3 | 11.3 | 10.7 | 1.06x |
| csi | 19.1 | 19.3 | 19.3 | 1.00x |
| long_escape_codes | 177.9 | 178.3 | -- | out of scope |
| images | 206.1 | 206.0 | -- | out of scope |

`sample` on the PTY-host thread, `ascii` (5546 samples, `takeOutputTurn` 99.5%,
`feedBuffer` 86%) and `unicode` (5566 samples):

| Frame | ascii, share of thread | ascii in `F1` | unicode | unicode in `F1` |
| --- | ---: | ---: | ---: | ---: |
| `advanceToNextRow` | 22.1% (1226) | 80% | 4.5% (252) | 35% |
| `printBulkNarrow` / `printWide` | 29.0% (1606) | ~9% | 21.7% (1209) | 12% |
| `_platform_memmove` | 13.9% (772) | 4% | 18.4% (1023) | 12.5% |
| `execute` | 17.9% (992) | -- | -- | -- |
| `read` | 11.4% (631) | 3% (`F3`) | -- | -- |
| `nextAction` | 9.4% (522) | -- | 13.9% (772) | 10% |
| `softWrap` | 7.8% (431) | -- | -- | -- |
| `appendToOpenClusterIfJoined` | -- | -- | 8.3% (459) | -- |

Under `advanceToNextRow`, everything `H1` named is gone. Across the whole
`ascii` thread: `swift_allocObject` 18 samples (0.32%),
`_ArrayBuffer._consumeAndCreateNew` 7, `swift_release` 32, `swift_retain` 9,
`swift_isUniquelyReferenced_nonNull_native` 41; the leaves under
`advanceToNextRow` itself total under 25 samples, one of them on
`_consumeAndCreateNew`. What remains inside `rotateViewportRows` (1094 samples,
19.7%) is 994 samples on `Terminal.swift:8656`, the
`recycled.resetAsBlank(columns:styleId:)` call -- the 179-cell blank fill, 17.9%
of the thread -- plus 32 on `append` and 23 on `removeFirst`/`removeLast`.

Sample logs: `ascii.sample.txt` (`sample 24309 7 1 -mayDie`, 400 repetitions),
`unicode.sample.txt` (`sample 24309 8 1`, 200 repetitions), aggregated by
`agg.py`; all three were session-local in the agent scratchpad and are not
committed. The tables above are the record.

**Inferred:**

- The mechanism `H1` named is removed. `D3`'s I1 -- a whole-viewport scroll over
  uniquely owned storage copies no row value and allocates no row -- is what the
  profile now shows on the production feed path, which is the only place it can
  be observed at all. The `ascii` arm's ladder verdict, the 3.9x kitten move, and
  the disappearance of the retain/release/uniqueness/allocation leaves are three
  independent readings of the same change.
- **The `advanceToNextRow < 10% of parse` criterion is not met on `ascii`
  (22.1%), and the per-byte reading is the one to take.** The criterion was
  written against a denominator that the fix itself shrank by 3.9x. Per byte fed,
  the frame costs 0.80/26.7 before against 0.221/103.4 after, about 14x less;
  `unicode` is 0.35/18.8 against 0.045/30.1, about 12x less. This is exactly the
  README rule that a frame name says which code is on the stack, not which work
  disappears when the code is rewritten (`37/F4`): the surviving samples under
  the frame are not the row copy the criterion was aimed at, they are
  `resetAsBlank`'s cell fill, which is new code the fix introduced in place of an
  allocation. Read as a share, the criterion punishes a fix for succeeding. Read
  per byte, or read by which leaf frames remain, `H1` is confirmed on both
  counts. The share criterion should not be restated for a future fix without
  naming its denominator.
- **The ascii profile has a new shape.** `printBulkNarrow` is now the largest
  single item (29.0%, from ~9%), and `memmove` (13.9%, from 4%) and `read`
  (11.4%, from `F3`'s 3%) grew for the same denominator reason -- their absolute
  per-byte cost is unchanged and the parse around them got cheaper. `read`
  growing to 11.4% is the first sign the delivery path `F3` measured at 3% and
  dismissed is worth re-checking once the parse is cheaper still, though it is
  not yet a hypothesis.
- **The remaining per-line cost is the blank fill, not a copy.** 994 samples on
  `resetAsBlank` is 17.9% of the `ascii` thread: the fix traded 65 row-value
  copies plus one 179-cell allocation for one 179-cell fill. That is a large win
  and an obvious next target, and it is a different mechanism from `H1`.
- **`unique_unicode` and `csi` did not move, and the two modes disagree about
  them.** `quick` called both `faster` (-2.10% and -1.45%) and `confirm` called
  both `inconclusive` (-1.17% and +1.30%, and note `csi` changed sign). Their
  frozen rules are 2 pairs at +/-1.60% and +/-1.45% in both modes (`D2`), so
  `quick`'s two estimates sat within 0.5 and 0.0 points of the threshold. A
  2-pair rule evaluated within a fraction of a point of its own threshold is
  reporting which side of the line one median landed on, not a reproducible
  direction. The kitten run agrees with `confirm`: 10.7 -> 11.3 MB/s and
  19.3 -> 19.1 MB/s are nothing. So the honest reading is that `H1` moved the two
  arms that scroll a lot per byte and left the two that do not, which is what its
  mechanism predicts, and the `quick` calls were threshold-edge noise. This is a
  property of a 2-pair rule near its threshold, not a defect in the arms:
  `F5`'s confirmation gates detection at 0.915-1.000 for an injected effect at
  the threshold, and an effect at half the threshold is below what either mode
  resolves.
- **The two `slower` verdicts are not explained, and I do not claim they are
  noise.** Taking them one at a time:
  - `content-churn` decides on `drawNanosecondsPerDraw`. Its stimulus is
    `redraw_screen` in `scripts/terminal-benchmark-producer.py`, which builds
    "one dense pseudo-TUI frame without scrolling or last-column writes": the
    frame homes the cursor with `\x1b[H`, writes 66 rows one column short of the
    grid, and emits no newline after the last row. So the measured phase never
    performs a whole-viewport scroll, and `moveAndFillRows` -- the only function
    the commit changed -- is not on its path. The verdict metric is the draw,
    which is a different thread and a different subsystem again, and the plan
    time under it moved -0.22%. Against that, the rule is not a loose one: its
    frozen threshold is 1.50%, its worst A/A estimate over eight whole
    invocations was 0.99 points, and it made 0 of 8 false directional calls
    (`research/33/F28`, tabulated in
    [agent-docs/terminal-performance.md](../../../agent-docs/terminal-performance.md)).
    +1.76% is above both. Process CPU +1.13% is a second, uncalibrated quantity
    pointing the same way. So the mechanism says unreachable and the calibration
    says believable, and one measurement cannot settle which is right.
  - `retained-browse` decides on `planNanosecondsPerFrame` over retained
    history, with the viewport parked at the oldest rows; the plan reads
    `LogicalLineStore`, not live `GridRow`s, so the changed function is not on
    its measured path either. Its *setup* is on the changed path: it feeds
    10,000 lines through the primary screen, which now rotates and recycles
    instead of copying and allocating. History content is identical -- `admit`
    copies cells into its arena and keeps no reference to the row -- but the
    allocation sequence that produced the arena is not, so a heap-layout effect
    on the later plan is conceivable and unmeasured. There is also a known
    confound of the right size: the physical arm slot is derived from the
    candidate tree's own hex parity and moves this cell by about 0.6 points with
    no code change at all, against a 1.05% threshold, while a re-run of the same
    tree pair reproduces to within 0.3 points. So a plain re-run of this pair
    would reproduce the same slot and cannot separate the two.

  What would settle each: for `content-churn`, an A/A control the change cannot
  reach -- a `confirm` of the post-`H1` tree against itself with only a marker
  differing -- run in the same session as a re-run of the real pair; if the
  control shows the same +1.7%, the cell moved for a reason that is not this
  commit. For `retained-browse`, the same control, plus a candidate tree whose
  hex parity puts it on the other arm slot, because that is the only way to
  price the known confound. A profile of either cell is the fallback if the
  control comes back clean and the difference persists.
- The window was occluded for the whole kitten run, so the MB/s figures here are
  a not-drawing terminal, comparable to `F1` (also a slot window) but not to any
  frontmost figure and not to Ghostty. `F3` showed that state moves the same arm
  by 3x on Ghostty. Nothing in this finding rests on the absolute MB/s: the
  verdict is the ladder, and the kitten number is the external confirmation that
  it moved.

**Alternatives:** the `ascii` gain could in principle be the compiler laying out
`Terminal.swift` differently rather than the rotation; a 4.2x symmetric estimate
and the specific disappearance of exactly the leaf frames `F1` named make that
implausible. The two `slower` cells could be a real cost of the change reaching
them by a route neither of the readings above found; the controls named are what
would find it.

**Confidence:** high that `H1` is fixed and that `ascii` and `unicode` moved for
the reason claimed. Medium on `unique_unicode` and `csi` being genuinely
unmoved -- two 2-pair estimates and one kitten run agree, but no mode called
them `equivalent`. Low on the two `slower` verdicts, which is why `D4` does not
close them.

**Unlocks:** Phase 3 task 1 is DONE (`D4`). The re-ranked profile puts
`resetAsBlank`'s per-line fill (17.9% of `ascii`) and `H3`'s memmove (13.9% of
`ascii`, 18.4% of `unicode`) ahead of the rest; `H2` and `H4` are untouched by
this change, as their arms' verdicts show.

## F7 -- The control run clears `873431d0`: a change-free `confirm` moves both disputed cells further than the real pair does

**Observed** (2026-08-28). Two `benchmark-confirm` invocations in one session,
the control paired with a re-run of `F6`'s real pair, as `D4` prescribed.
`confirm` refuses `--workload` by design, so both runs are full ten-workload
confirms.

The arm slot is `physical_candidate_arm(candidate_tree)` -- `a` if
`int(tree, 16) & 1` else `b` -- and the quartet phase is bit 1 of the same
value, so both are properties of the candidate tree's hex and nothing else.
Parity was arranged with no code change: a scratch marker file
(`docs/scratch/2026-08-28-h1-control-marker.md`, deleted after the runs)
<!-- docs-lint: allow-missing docs/scratch/2026-08-28-h1-control-marker.md -->
carried a nonce that was tuned until the snapshot tree's low bits gave the
wanted arm and phase. No run's code differs from the tree it names.

### Run 1 -- the real pair, re-run on `F6`'s slot and phase

`just benchmark-confirm baseline=da2d1023`. Baseline tree `fe338bdcd243`
(`F6`'s), candidate tree `2e3245cbda8b`, arm `a`, phase 0 -- the same slot and
phase `F6` ran on. Total 369.2 s. Artifacts
`.build/terminal-benchmark-comparisons/confirm/2e3245cbda8b-0000`.

| Workload | Pairs | Symmetric median | Verdict | `F6` |
| --- | ---: | ---: | --- | ---: |
| `kitten-feed-ascii` | 2 | -123.36% | faster | -123.61% |
| `kitten-feed-unicode` | 2 | -40.36% | faster | -41.48% |
| `kitten-feed-unique-unicode` | 2 | -0.46% | equivalent | -1.17% |
| `kitten-feed-csi` | 2 | -1.23% | inconclusive | +1.30% |
| `scrollback-stream` | 4 | -8.78% | faster | -4.68% |
| `terminal-feed` | 2 | -2.17% | inconclusive | -2.20% |
| `content-churn` | 4 | -0.31% | equivalent | +1.76% |
| `style-churn` | 4 | -0.37% | equivalent | +0.93% |
| `incremental-mixed` | 6 | +0.80% | descriptive only | -0.67% |
| `retained-browse` | 4 | +0.12% | equivalent | +1.20% |

`scrollback-stream`'s composition: drain 42.9 ms / 35.5 MB/s baseline against
40.4 ms / 37.7 MB/s candidate, draw tail 31.7% against 24.0%. `content-churn`:
0 outliers, plan time -0.14%, process CPU +0.25%. `style-churn`: plan +0.65%,
CPU +0.64%. Host at invocation: load 1.74/1.94/2.50, 0.17 per processor across
10; `claude` 5.6%, DanTerm 4.8%, WindowServer 3.6%. Before the first block:
4.25/2.80/2.75, 0.43 per processor; `mlhostd` 12.0%,
`spotlightknowledged.updater` 8.1%.

### Run 2 -- the control, the post-`H1` tree against itself

`just benchmark-confirm baseline=4f178e59`, `4f178e59` being HEAD, a docs-only
commit over `873431d0`; the working tree's code is identical to it. Baseline
tree `64decb05cb2a`, candidate tree `97f8c7bd9741`, arm `b`, phase 0 -- the
other arm parity, which `D4` asked for on `retained-browse`. Total 537.0 s.
Artifacts `.build/terminal-benchmark-comparisons/confirm/97f8c7bd9741-0000`.

| Workload | Pairs | Symmetric median | Verdict |
| --- | ---: | ---: | --- |
| `kitten-feed-ascii` | 2 | -0.35% | equivalent |
| `kitten-feed-unicode` | 2 | +0.72% | equivalent |
| `kitten-feed-unique-unicode` | 2 | -0.13% | equivalent |
| `kitten-feed-csi` | 2 | -0.25% | equivalent |
| `scrollback-stream` | 4 | -5.96% | faster |
| `terminal-feed` | 2 | +0.04% | equivalent |
| `content-churn` | 4 | -1.54% | faster |
| `style-churn` | 4 | -0.03% | equivalent |
| `incremental-mixed` | 6 | -3.78% | descriptive only |
| `retained-browse` | 4 | +1.66% | slower |

`scrollback-stream`: 1 outlier, drain 42.0 ms / 36.3 MB/s against
40.3 ms / 37.8 MB/s, draw tail 23.1% against 20.2%. `content-churn`: 1 outlier,
plan +0.33%, CPU -1.64%. `style-churn`: plan -1.37%, CPU +0.52%. Host at
invocation: load 1.88/3.13/3.03, 0.19 per processor; Finder 7.3%, `claude`
6.3%. Before the first block: 2.28/2.76/2.90, 0.23 per processor.

**Inferred:**

- **`F6`'s two `slower` verdicts are not attributable to `873431d0`.** The
  control has no code difference at all, and it still emits a directional call
  on both disputed cells, each past its own frozen threshold:
  `content-churn` `faster` at -1.54% against a 1.50% threshold, and
  `retained-browse` `slower` at +1.66% against 1.05%. A cell that calls a
  direction on identical code cannot be read as evidence about a commit. The
  real pair, re-run on `F6`'s exact slot and phase, then read both cells flat --
  `content-churn` -0.31% and `retained-browse` +0.12%, both `equivalent` -- while
  `H1`'s wins reproduced closely (`ascii` -123.36% against -123.61%, `unicode`
  -40.36% against -41.48%). Three readings agree: the change is not on either
  cell's path, the same pair does not reproduce the two `slower` calls, and the
  change-free control moves them further than the change does. `D4`'s open item
  is settled and neither cell needs a profile.
- **Two caveats stay attached to that reading.** The `retained-browse` control
  ran on arm `b`, so its +1.66% mixes the roughly 0.6-point arm-slot confound
  with between-invocation noise, and the two figures are not separated here. And
  the session's two `content-churn` estimates, -1.54% and -0.31%, straddle zero,
  which is itself a statement about that cell's between-invocation spread rather
  than about either tree.
- **All four `kitten-feed-*` arms read `equivalent` on the control.** That is the
  first whole-`confirm` A/A data point for them; `D2` froze them on a calibration
  series and noted they had no invocation-level A/A record. Four arms, four
  `equivalent` calls, largest magnitude 0.72% against thresholds of 1.45-1.80%.
  One invocation is not a control series, so this does not replace one, but it is
  evidence in the direction the freeze assumed.
- **`scrollback-stream` called `faster` on identical code.** -5.96% on the
  control, and -8.78% on the real pair where `F6` read -4.68%. That workload's
  worst A/A estimate is already 3.48 points against a 1.85% threshold and it made
  3 of 8 false directional calls in the control it was frozen against
  ([agent-docs/terminal-performance.md](../../../agent-docs/terminal-performance.md)),
  so this is that rule behaving as its own calibration says it does, not a new
  effect. It is a fact about the rule and belongs to `research/7`, which owns the
  ladder; this doc records it and does not fix it. It also means `F6`'s
  `scrollback-stream` `faster` was never load-bearing: `D3` asked only that the
  primary-screen branch not regress.

**Alternatives:** the control could be flat in truth and both of its directional
calls could be one unlucky invocation, leaving `F6`'s `slower` pair unexplained.
The re-run of the real pair is what rules that reading out -- it landed on the
same slot and phase as `F6` and read both cells `equivalent`, so there is no
surviving version of the story in which the commit moves them.

**Confidence:** high that neither `slower` cell is attributable to `873431d0`.
Medium on the magnitude of the arm-slot confound inside `retained-browse`'s
+1.66%, which this session priced only as "at most all of it". Low-value, by
design, on any single number here: the whole point of the run is the comparison
between the two invocations, not either invocation's estimate.

**Unlocks:** `D4`'s open item closes and the control-run ledger task is DONE, so
`H1` is fully closed. The next fix is `H3`, in `F6`'s ordering, with both
disputed cells cleared ahead of it.

## F8 -- Both feed-path terminal copies are gone, all four kitten arms and `terminal-feed` move, and `scrollback-stream`'s `slower` call is off-target and reproduces without the change

**Observed** (2026-08-28). The `D5` change -- the projection derived from its
five inputs by one function that the public getter and the damage snapshot both
call, and the cluster predecessor resolved on `ScreenState` -- measured against
its parent `abfdba28` under the `D2` rules. Four `quick` arms, two full
`confirm` invocations, three `scrollback-stream` probes, and a read of the
release object.

### The release object

`swift build -c release --package-path lib/TerminalCore`, then `otool -tvV` over
`TerminalCore.build/Terminal.swift.o`. A whole-terminal copy is a `memcpy` whose
length immediate is `MemoryLayout<Terminal>.size` = 1513 (`mov w2, #0x5e9`).

The object holds **48** such sites, down from `D5`'s 58, and none of them is on
the feed path. `apply`, `feedBuffer`, `print`, and `printBulkNarrow` are inlined
into `Terminal.feed(UnsafeBufferPointer<UInt8>)`, which carries no 1513-byte
copy; `recoverClusterContextFromGridIfNeeded` survives as its own symbol and
carries none either. The absence is not vacuous: both public `feed` overloads
and the recovery symbol are present in the object and were read by name.

What remains nearest the feed path is guarded, and is `D5`'s own second bucket:
four sites in `recordDamage(from:to:)`, all of them the
`damagedViewportRows(for:)` calls reached only when the selection or the hovered
link changed, and one in `appendToOpenClusterIfJoined`, the
`clusterTargetCanChangeWidth` call reached only when a combining mark would
change a cluster's width. Neither runs on an ordinary printed character.

### The `quick` ladder

`just benchmark-quick baseline=abfdba28`, one arm per invocation.

| Arm | Symmetric median | Threshold | Verdict | Artifacts |
| --- | ---: | ---: | --- | --- |
| `kitten-feed-ascii` | -15.05% | 1.70% | faster | `quick/106c2fb163ac-0000` |
| `kitten-feed-unicode` | -18.94% | 1.80% | faster | `quick/b8dd0b3363ad-0000` |
| `kitten-feed-unique-unicode` | -13.86% | 1.60% | faster | `quick/35a7e6d79406-0000` |
| `kitten-feed-csi` | -8.46% | 1.45% | faster | `quick/14c374bbe3b3-0000` |

All four move, which is what a per-action cost predicts, and each is 5x to 10x
its own threshold.

### The two `confirm` runs

`just benchmark-confirm baseline=abfdba28`, twice, on the same candidate change;
baseline tree `e84ee1a1d835`, candidate trees `cad436a6a0b7` and `e237f37506f1`,
arm `a`, phase 0 both times. Totals 375.7 s and 371.8 s. Artifacts
`.build/terminal-benchmark-comparisons/confirm/{cad436a6a0b7,e237f37506f1}-0000`.

| Workload | Pairs | Run 1 | Run 2 | Verdict |
| --- | ---: | ---: | ---: | --- |
| `kitten-feed-ascii` | 2 | -15.75% | -16.12% | faster, faster |
| `kitten-feed-unicode` | 2 | -17.61% | -18.55% | faster, faster |
| `kitten-feed-unique-unicode` | 2 | -12.25% | -12.69% | faster, faster |
| `kitten-feed-csi` | 2 | -7.80% | -7.83% | faster, faster |
| `terminal-feed` | 2 | -10.96% | -10.57% | faster, faster |
| `scrollback-stream` | 4 | +9.54% | +11.25% | slower, slower |
| `content-churn` | 4 | +0.03% | +0.56% | equivalent, equivalent |
| `style-churn` | 4 | -0.30% | +0.16% | equivalent, equivalent |
| `retained-browse` | 4 | +0.37% | +0.31% | equivalent, equivalent |
| `incremental-mixed` | 6 | -0.54% | +3.52% | descriptive only |

The five feed-path cells reproduce each other to within 1 point across two
independent invocations. The two cells `F6` disputed, and `F7` cleared with a
change-free control, both read `equivalent` here in both runs. Host at
invocation: run 1 load 1.84/3.04/3.89, 0.18 per processor across 10, with
`NotificationCenter` at 41.4% and `WindowServer` at 25.3% -- a busy invocation
snapshot that the block-level machine-state samples did not invalidate; run 2
load 3.16/2.88/3.44, 0.32 per processor, busiest external process `claude` at
5.9%.

### The `scrollback-stream` cell, and why it is not this change

Three probes, all `just benchmark-quick baseline=abfdba28` on physical arm `b`:

| Candidate | Code delta from `abfdba28` | Verdict | Drain, base -> cand | Draw tail, base -> cand |
| --- | --- | --- | --- | --- |
| `quick/ff7b652d6140-0000` | `Terminal.swift` only | inconclusive +2.85% | 42.1 -> 41.3 ms | 15.8 -> 18.4 ms |
| `quick/4aec460a7957-0000` | `Terminal.swift` only, cluster site alone | slower +12.77% | 41.25 -> 41.27 ms | 10.5 -> 17.6 ms |
| `quick/a5db326a2a10-0000` | **none** | slower +5.16% | 41.9 -> 42.4 ms | 14.7 -> 17.0 ms |

Three independent lines say the `slower` call is not attributable to the change.

- **The damage the two trees publish is byte-identical.** A separate
  equivalence probe, run by the repository owner on 2026-08-28 and recorded here
  from its operator's report, compared 39,799 per-action records -- damaged rows
  and shift, the whole `scrollProjection`, and a viewport hash -- across the real
  scrollback corpus, viewport scroll and resize states, a byte-at-a-time feed,
  the alternate screen, and a grapheme stress stream. Both trees hash to
  `8a8a38e5`. The natural hypothesis, that the derived projection disagrees with
  the old getter somewhere the ladder can see, is refuted: this is code motion.
- **The slowdown sits entirely in the draw tail, which the diff does not
  touch.** In the cluster-only bisect the drain leg is identical to the digit on
  both arms -- 41.3 ms and 37.0 MB/s either way -- while the cell reads +12.77%,
  all of it from a draw tail that moves 10.5 -> 17.6 ms. `scrollback-stream`'s
  drain is the only leg the feed path is in.
- **A change-free control reproduces the call.** With `Terminal.swift` reverted
  to `abfdba28` and no code delta at all, the cell still read `slower` at
  +5.16%, with the same draw-tail shape.

The common factor is position, not code: across every probe the candidate landed
on physical slot `b` and its draw tail sat at 17.0-18.4 ms whether or not the
change was present, while the one cached baseline binary on slot `a` swung
10.5-15.8 ms. That is a slot-position draw-tail penalty stacked on this cell's
known record of 3 directional calls in 8 A/A comparisons
([agent-docs/terminal-performance.md](../../../agent-docs/terminal-performance.md),
and `F7`, where the same cell called `faster` at -5.96% on identical code).

**Inferred:**

- **`H3` is confirmed on the ladder and in the object.** Both unconditional
  whole-terminal copies are gone from the release object, all four kitten arms
  and `terminal-feed` move `faster` in two independent `confirm` runs, and the
  per-arm moves are 5x to 10x their thresholds. The `D5` prediction that a
  per-action cost moves every arm holds. `D5`'s third criterion, the external
  `kitten __benchmark__ --render` re-run of `ascii` and `unicode`, is **not
  taken here** and is still owed before the ledger task closes; by this doc's
  own rules the kitten run is the closing step, never the verdict.
- **`scrollback-stream`'s `slower` verdict is an off-target, non-reproducing
  call and is recorded as such.** It is off-target because the mechanism it would
  have to run through is the drain leg, and the drain leg does not move; it is
  non-reproducing because a tree with no code difference produces the same call.
  No profile is owed on it.
- **The slot-position draw-tail confound belongs to `research/7`.** The ladder
  pairs a cached baseline binary against a freshly built candidate and assigns
  each a physical slot from the candidate tree's low bits; on this session's
  evidence a candidate on slot `b` pays a draw-tail penalty of several
  milliseconds that has nothing to do with its code. `research/7` owns the rule
  and the runner; this doc records the observation and does not fix it. `F7`
  priced the same confound at "at most all of" a +1.66% `retained-browse` call
  and left it bounded but unpriced; this session's three probes are the first
  ones that isolate it in a cell's composition.

**Alternatives:** the change could genuinely cost the draw tail through some
path the diff does not name, and the control could be one unlucky invocation.
The cluster-only bisect rules that reading out on its own -- a draw tail that
moves 7 ms while the drain moves 0.01 ms is not a feed-path effect -- and the
change-free control agrees with it independently.

**Confidence:** high that `H3` is confirmed and that the five feed-path cells
are real, on two invocations that agree within a point. High that the
`scrollback-stream` call is not attributable to the change. Medium on the size
of the slot-position penalty, which three probes bound but do not measure.

**Unlocks:** the `H3` ledger task's ladder half is done. Two pieces remain
before it closes: the tooling gate that keeps the copy from returning, and the
external kitten re-run.

## F9 -- After the three repairs, `scrollback-stream` still selects no rule: its drain leg is a 6.2% A/A stimulus, so the cell stays vacated

**Observed** (2026-08-28, revision `eaa78201`, tree
`83f7541572f177fffbc6e0f1393c4cfd60733e2a`, AC power, machine otherwise idle).
Every archived `scrollback-stream` series was incomparable after the three
repairs -- collected through the `.a`/`.b` bundle namespace and paired on
`finalDrawNanoseconds` -- so the screen was collected fresh. 12 quartets,
50,000 trials, seed 20260829, all 12 quartets kept and none discarded:

| quantity | value |
| --- | --- |
| deciding metric | `producerWriteNanoseconds` (the drain leg) |
| pairs | 24 |
| A/A median | +0.75% |
| SD | 6.23% (trimmed 4.86% over 22 pairs) |
| range | -15.79% .. +12.51% |
| `quick` | no threshold clears the gates at any searched pair count |
| `confirm` | no threshold clears the gates at any searched pair count |

Host at invocation: load 1.36/1.91/1.83, 0.14 per processor across 10, busiest
external `spotlightknowledged.updater` 10.2%; AC power, battery charged. The
search covers pair counts 2, 4, 6, 8, 12, 16 and 24 and thresholds from 0.80%
to 3.00% in 0.05-point steps.

The confirmation was run anyway, at 100,000 trials on seed base 20260901 --
disjoint from the screen's 20260829 -- and reports what it has to report: the
screen proposed no cell in either mode, 0 of 2 modes confirmed. Artifacts:
[f9-artifacts/candidate-screen.json](f9-artifacts/candidate-screen.json) and
[f9-artifacts/candidate-confirm.json](f9-artifacts/candidate-confirm.json).

**Inferred:**

- **The cell stays vacated, and now on measured grounds rather than on a bad
  record.** The vacating in `95d0a263` was a judgement about a threshold that
  had been frozen below its own noise. This is the A/A series that the vacating
  note asked for, taken on the quantity the cell now decides on, and it refuses
  a rule outright.
- **The drain leg is not the quiet leg it looked like.** `F8` read the drain as
  stable to the digit -- 41.25 ms against 41.27 ms across a bisect pair -- and
  that reading is what moved the metric in `71c3ab28`. Within one session and
  one pair it is stable; across 24 A/A pairs its spread is 6.23% with a
  32-point range. Both readings are true, and only the second one is the
  quantity a threshold has to survive. Moving the metric was still right: the
  cell now measures the leg a feed-path change is in. It just does not follow
  that the leg is decidable.
- **The spread is a broadly noisy stimulus, not a rare event.** Trimming the two
  most extreme pairs moves the SD from 6.23% to 4.86%, so no small number of
  outliers is carrying it. That is the opposite of `synchronized-frames`' first
  screen, where one pair at -16% tripled the SD.
- **The searched grid stops at 3.00%, and widening it would buy nothing.**
  `confirm`'s own effect size is 3%, so a directional threshold above 3.00%
  cannot detect the effect the mode exists to detect. There is no honest rule
  above the ceiling to reach for.

**Alternatives:** the shared bundle namespace could itself be what widened this
cell -- consecutive fresh apps now launch into one bundle identity and its
caches, where the `.a`/`.b` split alternated them. Nothing here measures that,
and no pre-repair series on the drain leg exists to compare against, so it is an
open question rather than a competing reading. A quieter machine would be
expected to narrow the series, but not by the factor a rule would need: the
cheapest clearing cell is absent at every pair count through 24, not marginal at
one of them.

**Confidence:** high that no rule is available on this evidence. The screen kept
all 12 quartets with no discards, the block contract validated the deciding
metric on every one of the 48 blocks, and the refusal is unanimous across both
modes and all seven searched pair counts. Medium on the cause of the width,
which is unattributed.

**Unlocks:** nothing to freeze. `scrollback-stream` keeps its schedule, reports
its estimate and its two composition lines, and issues no verdict. A future rule
needs the width explained first -- the namespace question above is the one lead
this session produced.

## F10 -- The `H3` kitten re-run closes `D5`: all four arms move, the window state moves nothing, and the render thread is the second busy core

**Observed** (2026-08-28, `34c28902`, optimized slot 1, kitten 0.48.2,
`--render`, alternate screen, default repetitions). The pane was pinned with
`danterm pane resize 179x66` and `stty size` confirmed 66x179 inside it, so the
geometry matches `F1` and `F6`. Frontmost was achieved with
`open -b com.danneu.danterm-dev.1` -- the `danterm` CLI has no activate verb --
and verified by `osascript` reading `frontmost is true` before, during, and
after each run. Occluded means the slot window sat behind the canonical DanTerm
instance, which is the state every previous kitten figure in this doc was taken
in.

### The kitten run

| Arm | occluded | frontmost | `F6` | `F1` | move vs `F6` |
| --- | ---: | ---: | ---: | ---: | ---: |
| ascii | 116.9 / 119.2 | 118.7 / 119.7 | 103.4 | 26.7 | +13-16% |
| unicode | 36.2 / 36.1 | 36.2 / 35.2 | 30.1 | 18.8 | +17-20% |
| unique_unicode | 12.6 / 12.6 | 12.6 / 12.6 | 11.3 | 10.7 | +11% |
| csi | 20.5 / 20.7 | 20.7 / 20.8 | 19.1 | 19.3 | +7-9% |
| long_escape_codes | 180.6 / 179.8 | 179.1 / 171.9 | 177.9 | -- | out of scope |
| images | 202.0 / 202.2 | 206.0 / 196.1 | 206.1 | -- | out of scope |

Every occluded/frontmost pair sits inside its own run-to-run spread, so the
window state moves nothing on any of the six arms.

### Ghostty preview -- **not** the Phase 4 closing table

`/Applications/Ghostty.app` was launched for this run with
`--window-width=179 --window-height=66`, but `stty size` inside it reports
**61x179**: Ghostty does not honour the row request exactly, which `F3` also
saw. The runs are frontmost and on the same host and session as the DanTerm
column, but they are sequential, not interleaved. Two differences from the
Phase 4 contract -- a five-row-shorter grid on an arm whose cost is linear in
rows, and no interleaving -- so these are a preview, not the closing table.

| Arm | Ghostty | DanTerm frontmost | Ghostty / DanTerm |
| --- | ---: | ---: | ---: |
| ascii | 86.4 / 83.8 | 118.7 / 119.7 | 0.71x (DanTerm ahead) |
| unicode | 111.4 / 110.4 | 36.2 / 35.2 | 3.1x |
| unique_unicode | 45.6 / 45.5 | 12.6 / 12.6 | 3.6x |
| csi | 41.1 / 43.1 | 20.7 / 20.8 | 2.0x |
| long_escape_codes | 78.5 / 76.9 | 179.1 / 171.9 | 0.44x (DanTerm ahead) |
| images | 57.7 / 54.9 | 206.0 / 196.1 | 0.28x (DanTerm ahead) |

### Per-thread CPU

Whole-process cores, from `ps -o time=` deltas over 8 s of steady feeding:
`ascii` 1.22 (identical frontmost and occluded), `unicode` 1.98,
`unique_unicode` 1.99, `csi` 1.57 and 1.55. An `xctrace` Time Profiler on
`ascii` over 10 s collected 11889 on-CPU samples, 1.09 cores, split
PTY-host workloop identities 44.8 + 23.6 + 12.2 = 80.6% and main thread 19.4%.
No third busy thread appears on any arm. `ps -M` still cannot report a thread
identity here, which is `F3`'s point.

The main thread's share of sample stacks under
`_dispatch_main_queue_callback_4CF` -- all of it real CPU, CoreText and
CoreGraphics frames with no `ulock_wait` or `psynch` -- is `ascii` 25.0%,
`unicode` 99.6%, `unique_unicode` 99.6%, `csi` 60.9%. Against the process
totals that puts the main thread at about 0.24, 1.0, 1.0 and 0.6 cores beside a
PTY-host thread pinned at about 1.0 core on every arm.

What the main thread is doing:

- `ascii`: `FramePlanner.plan` -> `CGContextFillRect` ->
  `_platform_memset_pattern16`, 47.6% of the main thread, plus
  `CGSColorMaskCopyARGB8888` 22.1%.
- `unicode` and `unique_unicode`: `TerminalFrameSwapchain.presentPending` ->
  `drawRenderFrame` (`TerminalRenderExecution.swift:683`) ->
  `CGContextRef.drawTextRuns` (`:1246`) -> `CTLineCreateWithAttributedString`
  -> `TGlyphEncoder::EncodeChars` -> `TFont::ShapesAnyPreferredLanguage`. That
  is CoreText typesetting the lines from scratch on every frame.
- `csi`: CoreGraphics anti-aliased path fill (`aa_distribute_edges` 14.3%,
  `aa_render` 10.6%, `aa_intersection_event` 4.4%) plus `memset_pattern16`
  7.8%.

### The four profiles

`sample <pid> 7 1 -mayDie`, frontmost, aggregated by `F6`'s `agg.py` method;
shares are inclusive and are of the PTY-host thread. Logs were session-local in
the agent scratchpad and are not committed; the tables are the record.

`ascii` -- 4959 samples, 700 repetitions, 12.4 s, 112.6 MB/s:

| Frame | share | `F6` | `F1` |
| --- | ---: | ---: | ---: |
| `feedBuffer` | 83.9% | 86% | -- |
| `apply` | 71.6% | -- | -- |
| `printASCIIRun` | 42.8% | -- | -- |
| `printBulkNarrow` | 28.7% | 29.0% | ~9% |
| `advanceToNextRow` | 25.1% | 22.1% | 80% |
| `moveAndFillRows` | 24.1% | -- | -- |
| `rotateViewportRows` | 22.4% | 19.7% | -- |
| `execute` | 19.6% | 17.9% | -- |
| `read` | 12.4% | 11.4% | 3% (`F3`) |
| `print` | 11.9% | -- | -- |
| `nextAction` | 10.1% | 9.4% | -- |
| `softWrap` | 9.1% | 7.8% | -- |
| `_platform_memmove` | 0.34% | 13.9% | 4% |

`ascii` leaves: `rotateViewportRows` `Terminal.swift:8692`, the
`recycled.resetAsBlank(columns:styleId:)` call, 994 samples = 20.0%, reached
from `lineFeed` (1214 samples in the frame) and `softWrap` (602);
`printBulkNarrow:7830`, the `writeNarrowCells` call, 14.6%; `read` 12.4%;
`nextAction` `TerminalInputStream.swift:87`, the printable-ASCII run scan, 7.7%;
`printBulkNarrow:7797`, the `readingRowCells` pre-write scan that counts
writable narrow cells, 6.8%; `apply` `Terminal.swift:0` 2.0%. The
allocation-class leaves are all gone or trivial: `memmove` 0.34%, `malloc`
0.36%, `free` 0.36%, retain/release 1.79%, uniqueness 1.33%, `memset` 0.02%.

An Instruments cross-check on `ascii`, PTY threads only, agrees:
`feedBuffer` 82.6, `apply` 69.7, `printBulkNarrow` 28.5, `advanceToNextRow`
26.1, `moveAndFillRows` 25.1, `lineFeed` 17.2, `read` 12.4, `printGLByte` 12.3,
`softWrap` 9.3, `nextAction` 8.5; leaves `IndexingIterator.next()` 19.2%
(1816 of its 1837 samples under `moveAndFillRows:8649`, the `rotateViewportRows`
call -- the same inlined blank fill), `read` 12.4, `nextAction:87` 8.1,
`writeNarrowCells:7871` (`cells[column + offset] = GridCell(...)`) 7.6,
`printBulkNarrow:7800` 5.8, `apply:1944` 4.8, `GridCell.init:222` 3.6. The two
tools disagree only on how they symbolize the blank fill (`:8692` against
`:8649` -> `IndexingIterator.next`), not on the answer.

`unicode` -- 4993 samples, 250 repetitions:

| Frame | share | `F6` | `F1` |
| --- | ---: | ---: | ---: |
| `feedBuffer` | 93.5% | -- | -- |
| `apply` | 73.2% | -- | -- |
| `print` | 46.5% | -- | -- |
| `printWide` | 26.4% | 21.7% | 12% |
| `nextAction` | 17.2% | 13.9% | 10% |
| `appendToOpenClusterIfJoined` | 10.4% | 8.3% | -- |
| `invalidateInspection` | 9.4% | 8.8% | -- |
| `recordDamage(from:to:)` | 5.8% | -- | -- |
| `advanceToNextRow` | 5.7% | 4.5% | 35% |
| `moveAndFillRows` | 5.5% | -- | -- |
| `rotateViewportRows` | 5.2% | -- | -- |
| `GeneratedPackedUnicodeTables.classification` | 4.8% | -- | -- |
| `GraphemeBreakState.shouldBreak` | 4.6% | -- | -- |
| `_platform_memmove` | 0.16% | 18.4% | 12.5% |

`unicode` leaves: `nextAction` `TerminalInputStream.swift:103`, the per-byte
`probe.next(bytes[probeIndex])` decoder probe, 6.3%; `rotateViewportRows:8692`
4.4%; `apply` `Terminal.swift:0` 4.4%; `classification` `generated.swift:3040`
3.9%; `read` 3.8%; uniqueness 4.3% (194 of 216 samples under `printWide`);
`malloc` 0.96%, `free` 0.80%, retain/release 1.16%. `printWide`'s hot lines are
`Terminal.swift:8303` and `:8310`, the head and tail `GridCell` stores.

`unique_unicode` -- 5084 samples, 100 repetitions, about 13.9 s:

| Frame | share | `F1` |
| --- | ---: | ---: |
| `feedBuffer` | 97.1% | -- |
| `apply` | 86.7% | -- |
| `print` | 70.4% | -- |
| `appendToOpenClusterIfJoined` | 50.4% | 33% of thread / "60% of parse" |
| `GridRow.appendScalar` | 31.4% | -- |
| `RefCounts::doDecrementSlow` | 16.9% | -- |
| `_swift_release_dealloc` | 14.5% | -- |
| `_ArrayBuffer._consumeAndCreateNew` | 12.9% | -- |
| `GridRow.place` | 11.0% | -- |
| `printASCIIRun` | 9.0% | -- |
| `Array.init<A>` | 8.9% | -- |
| `nextAction` | 8.4% | 7% |
| `swift_allocObject` | 7.8% | -- |

`unique_unicode` leaves, grouped: `malloc` 12.9% (parents
`swift_slowAllocTyped` 204, `malloc_size` 172, `_consumeAndCreateNew` 137,
`Array.init` 108); free and dealloc 11.2% (`_swift_release_dealloc` 436);
retain/release 15.0% (parents `GridRow.scalars(of:)` 144, `print` 119,
`appendToOpenClusterIfJoined` 100); uniqueness 3.8% (`appendScalar` 103);
`memmove` 2.5%, of which 126 of 129 samples are under `_consumeAndCreateNew`
-- array growth, not a whole-value copy; `memset` 1.9%, all under `_xzm_free`;
`GridRow.intern` 4.7%. The shape is unchanged since `F1`.

`csi` -- 5154 samples, 250 repetitions:

| Frame | share | `F1` |
| --- | ---: | ---: |
| `feedBuffer` | 96.4% | -- |
| `apply` | 79.0% | -- |
| `repeatLastPrintedCluster` | 56.3% | 37% of thread / 45% of parse |
| `printNarrow` | 35.7% | -- |
| `nextAction` | 16.1% | 16% (with the absorber) |
| `invalidateInspection` | 15.0% | -- |
| `EscapeAbsorber.consume` | 13.0% | -- |
| `recordDamage(rows:)` | 9.2% | -- |
| `TerminalDamage.record(rows:)` | 7.2% | -- |
| `prepareDestination` | 7.1% | -- |
| `printASCIIRun` | 5.1% | -- |
| `printBulkNarrow` | 4.8% | -- |
| `_platform_memmove` | 0.10% | 6% |

`csi` leaves: `repeatLastPrintedCluster` `Terminal.swift:7538`, the
`print(scalar, recoversGridContext: false)` call, 11.9%; `:7537`, the
`for scalar in cluster.scalars` loop, 2.4%; `:7536` 1.0%; `printNarrow:8238`,
the `writeNarrowCells` call, 5.9%; uniqueness 7.6% (parents `printNarrow` 192,
`TerminalDamage.record` 120); `prepareDestination:8829` and `:8825`, the
wide-head and wide-tail neighbour checks, 3.0% and 2.4%; `read` 2.4%; `malloc`
0.10%, `free` 0.04%, retain/release 0.43%. `EscapeAbsorber.consume`'s samples
are on lines 396, 397, 443 and 484.

**Inferred:**

- **`D5`'s confirmation criterion 3 is met, so `H3` is closed.** The criterion
  asked for the kitten `ascii` and `unicode` figures to move, recorded with
  window state and geometry. They moved, at 66x179 in both window states:
  `ascii` 103.4 -> about 118, `unicode` 30.1 -> about 36. Criteria 1 and 2 were
  met by `F8`. `unique_unicode` (+11%) and `csi` (+7-9%) moved too, which is
  what a fixed per-action cost predicts and what the ladder called; the sizes
  are the ones `F8`'s ladder predicted for each arm.
- **`H3`'s copy is gone from every arm's profile, not just from the object.**
  `_platform_memmove` is 0.34% of `ascii`, 0.16% of `unicode`, 0.10% of `csi`,
  and on `unique_unicode` its 2.5% is array growth under
  `_consumeAndCreateNew`. `F6` read 13.9% and 18.4% on the first two arms. This
  is a corroboration of `F8`, not the criterion: the criterion is the copy size
  in the release object, because a profile stack carries no length.
- **Window state moves no arm, so every earlier occluded figure in this doc is
  comparable to a frontmost one.** That was an open caveat from `F1`, `F3` and
  `F6`. It does not follow that drawing is free -- see below -- only that the
  feed thread is the binding constraint at these rates.
- **`--render` does put drawing on the profile at HEAD, and the README's
  standing caveat that it never did is wrong.** On three of the four in-scope
  arms the main thread costs about as much CPU as the parse: about 1.0 core on
  `unicode` and `unique_unicode`, 0.6 on `csi`, beside a PTY-host thread at
  about 1.0. It does not decide MB/s today, because the feed thread is still
  the serial bottleneck and the numbers are identical frontmost and occluded.
  It is a hypothesis about what happens next, filed as `H7`.
- **The per-arm reading.**
  - `ascii`: the blank fill (`H6`) is the top single item at 20%. Beside it,
    `printBulkNarrow` splits into the cell stamp (14.6%) and a 6-7% pre-write
    scan that no hypothesis covers; `read` at 12.4% has no hypothesis either
    (the minor ledger item names the `Array(UnsafeBufferPointer)` copy in
    `takeOutputTurn`, not the syscall); `execute` at 19.6% has none;
    `nextAction:87` is the minor item. `H3` is gone from this arm.
  - `unicode`: `printWide` at 26% is the largest item and has no hypothesis.
    Decode, classification and grapheme breaking together are about 26%, which
    is the minor ledger item, now much larger than the 5-10% it was written
    for. `appendToOpenClusterIfJoined` is 10% -- the same `H2` mechanism that
    owns `unique_unicode`. `H6` is 4.4%. `invalidateInspection` plus
    `recordDamage` is 15% with no hypothesis. `H3` is gone.
  - `unique_unicode`: `H2` exactly as `F1` described it, and its share grew
    because `H1` and `H3` removed cost elsewhere. Nothing on this arm maps
    anywhere else.
  - `csi`: `H4` exactly -- per-scalar `print` into `printNarrow`, paying
    `invalidateInspection`, `recordDamage` and a uniqueness check per cell.
    `EscapeAbsorber.consume` at 13% and the `prepareDestination` neighbour
    probes at 5.4% map to nothing. `H3` is gone.

**Alternatives:** the Ghostty preview's `unicode` and `unique_unicode` leads
could be partly the five missing rows rather than a real gap, since scroll cost
is linear in rows; that cuts the wrong way for DanTerm on `ascii`, where DanTerm
is ahead anyway. The main thread's CoreText cost could be an artifact of
`--render`'s draw-every-frame pattern rather than a cost real workloads pay;
`H7`'s experiment is what separates those.

**Confidence:** high that `H3` is closed and that all four arms moved. High that
window state is irrelevant at these rates, on twelve paired figures. High that
the main thread is doing CoreText typesetting per frame. Medium on the Ghostty
ratios, which are a preview at the wrong row count and unpaired in time.

**Unlocks:** the `H3` ledger task closes, less its tooling gate, which the user
parked and which is carried as its own TODO. Phase 3 re-ranks to `H2`, `H4`,
`H6`. `H7` is new and unranked. The unhypothesised items above are carried as
one ledger line so they are not lost.

## F11 -- `H2` lands: one scalar arena per row makes `unique_unicode` 1.7x faster on kitten and takes every allocator frame out of the cluster append

**Observed** (2026-08-29, working tree over `e0b4ad8f`, baseline `4e696dfc`
= `F10`'s tree). `H2` shipped in two commits: the first gives REP its own
cluster buffer so the printer's append is uniquely owned, the second replaces
the per-cell array table with one scalar arena per row, each cluster stored as
its own scalar count followed by its scalars and indexed by the cell's word.

### The ladder

`just benchmark-confirm baseline=4e696dfc`, one invocation, on an idle machine.

| Workload | Pairs | Symmetric median | Verdict |
| --- | ---: | ---: | --- |
| `kitten-feed-unique-unicode` | 2 | -50.52% | faster |
| `kitten-feed-unicode` | 2 | -3.26% | faster |
| `kitten-feed-csi` | 2 | -4.53% | faster |
| `kitten-feed-ascii` | 2 | +0.17% | equivalent |
| `terminal-feed` | 2 | -0.47% | equivalent |
| `content-churn` | 4 | -0.54% | equivalent |
| `style-churn` | 4 | +1.72% | inconclusive |
| `retained-browse` | 4 | +0.22% | equivalent |
| `scrollback-stream` | 4 | +0.26% | descriptive only |
| `incremental-mixed` | 6 | -6.35% | descriptive only |

`scrollback-stream`: drain 40.8 ms / 37.4 MB/s baseline against 41.1 ms /
37.1 MB/s candidate, draw tail 21.8% against 19.5%. `content-churn`: plan time
-0.25%, process CPU -0.63%. `retained-browse`: 1 flagged outlier, retained.

The ladder ran before four review edits that changed comments, one unreachable
precondition, and two loop index forms. The two decisive arms were re-measured
on the committed tree and agree: `unique-unicode` -48.99%, `unicode` -3.00%.

### The kitten run

Optimized slot 1 at the candidate tree, kitten 0.48.2, `--render`, alternate
screen, 66 rows x 179 columns pinned with `danterm pane resize 179x66`, window
**occluded** (the slot is unattended), which `F10` proved moves nothing.

| Arm | this run | `F10` occluded | `F1` | move vs `F10` |
| --- | ---: | ---: | ---: | ---: |
| unique_unicode | 21.4 | 12.6 | 10.7 | 1.70x |
| unicode | 37.2 | 36.2 | 18.8 | 1.03x |
| ascii | 117.2 | 116.9 | 26.7 | 1.00x |
| csi | 21.7 | 20.5 | 19.3 | 1.06x |

Ghostty's `unique_unicode` preview figure is 45.6 MB/s, so this closes about a
quarter of that gap and leaves `unique_unicode` still the worst arm.

### The re-sampled profile

`sample` for 8 s on the headless `unique-unicode` feed (`TerminalCoreBenchmark
--profile`), 6611 thread samples.

| Frame | share of the append subtree | in `F10` (share of thread) |
| --- | ---: | ---: |
| `appendToOpenClusterIfJoined` (inclusive) | 1649 samples = 24.9% of thread | 50.4% |
| `GridRow.appendScalar` | 22.1% | -- |
| `invalidateInspection` + `recordDamage` | 31.9% | -- |
| `GraphemeBreakState.shouldBreak` | 14.1% | -- |
| `GridRow.compactClusters` | 3.9% | -- |
| every allocator frame together | 0.85% | ~37% (malloc 12.9, free/dealloc 11.2, `_consumeAndCreateNew` 12.9) |

`GridRow.intern`, `Array.init<A>` and retain/release under the append are gone
outright. What remains of the allocator is 14 samples of array growth and the
`compactClusters` reclaim, both amortized over a row rather than paid per
scalar.

**Inferred:**

- **The allocation per joining scalar is gone, and it was most of the arm.**
  `unique_unicode` halving on the ladder, the kitten figure moving 1.70x, and
  the allocator dropping from about 37% of the append to 0.85% are three
  readings of the same change. The arm's remaining cost is the guard chain,
  damage recording and grapheme breaking -- none of which `H2` was about.
- **The payload type's width is a real cost, and sharing the arena is not worth
  it.** The first shape returned a `TerminalScalars` naming a range in the row's
  arena. That needed a fourth enum case, which took the type from 9 to 25 bytes
  and cost `retained-browse` 10.3% and `content-churn` 1.8% -- `AR1` exactly,
  and measured, not argued. Copying a cluster out on the few reads that want a
  value, and giving the printer's per-scalar readers their own accessors
  (`firstScalar(of:)`, `scalarsEqual`, `copyScalars(of:into:)`), keeps the type
  at its original width and both cells read `equivalent`.
- **A row may hold only two heap references.** An intermediate shape kept the
  span table as a second array beside the arena. That alone cost
  `kitten-feed-unicode` 55%: the third refcounted field turned every row access
  into an outlined copy, and ARC went from 0.7% of the thread to 29%. Storing
  each cluster's length in the arena in front of it removes the table, and the
  regression with it. Anything added to `GridRow` should be read against this.
- **REP's memory must not reach a heap buffer per printed scalar.** Commit 1's
  first shape held the cluster in a plain array and refilled it after every
  printed scalar, which cost `unicode` 18% on its own -- invisible until the
  arena change was measured against commit 1 rather than against `F10`'s tree.
  Holding the first scalar inline and only the rest in a buffer restores it.

**Alternatives:** `style-churn`'s +1.72% is inconclusive and sits inside the
between-invocation spread `F7`'s control measured on the neighbouring cells
(-1.54% and +1.66% on identical code); nothing in the change touches attribute
handling, and its plan time read -3.20%. `incremental-mixed`'s -6.35% is
descriptive only and is not claimed.

**Confidence:** high on `unique_unicode`, which agrees across the ladder, the
kitten run and the profile. High that the allocator is out of the append.
Medium on `unicode` and `csi`, whose ladder wins are small and whose kitten
figures moved 3-6%.

**Unlocks:** `H2` closes. The `unicode` remainder (`printWide`, decode,
classification) and `H4` are next; the `invalidateInspection` plus
`recordDamage` pair is now 32% of the append subtree on `unique_unicode` and
15% of `unicode`, still with no hypothesis.

## F12 -- `H4` lands: REP prints as one run of identical cells, and kitten's `csi` arm goes 2.1x

**Observed** (2026-08-29, working tree over `ed2224cc`, baseline `754c3b50`
= the tree before `H4`). `H4` shipped in two commits: the first fills a narrow
single-scalar REP through the stream's own bulk narrow writer, the second adds
a bulk writer for the wide and multi-scalar shapes, which stamps the remembered
cluster into whole cells instead of replaying its scalars through the
segmenter.

### The ladder

`just benchmark-confirm baseline=754c3b50`, one invocation, on an idle machine.

| Workload | Pairs | Symmetric median | Verdict |
| --- | ---: | ---: | --- |
| `kitten-feed-csi` | 2 | -73.05% | faster |
| `kitten-feed-ascii` | 2 | +1.42% | inconclusive |
| `kitten-feed-unicode` | 2 | +0.76% | inconclusive |
| `kitten-feed-unique-unicode` | 2 | +1.05% | inconclusive |
| `terminal-feed` | 2 | +1.18% | inconclusive |
| `content-churn` | 4 | -0.51% | equivalent |
| `style-churn` | 4 | +1.18% | inconclusive |
| `retained-browse` | 4 | +0.39% | equivalent |
| `scrollback-stream` | 4 | -0.29% | descriptive only |
| `incremental-mixed` | 6 | -11.95% | descriptive only |

`scrollback-stream`: drain 42.0 ms / 36.3 MB/s baseline against 41.9 ms /
36.4 MB/s candidate, draw tail 31.8% against 27.8%. `content-churn`: plan time
+0.06%, process CPU -0.10%. `retained-browse`: 1 flagged outlier, retained.
The `quick` ladder on the same tree agrees: `csi` -73.15% `faster`, `ascii`
+0.94% and `unicode` +0.27% `equivalent`, `unique-unicode` +1.04%
`inconclusive`.

The ladder ran before one review edit that takes the memory's single-scalar
copy off the heap on the wide path, which no kitten arm exercises. The decisive
arm was re-measured on the committed tree and agrees: `csi` -72.67%.

Commit 1's own confirm ladder read `kitten-feed-unique-unicode: slower
(+1.80%)` on an arm that never executes REP, and carried it as a follow-up
rather than an explanation. It did not persist: the same cell reads
`inconclusive (+1.05%)` here and `equivalent (-0.60%)` on the first `quick`
ladder of this commit. It was between-invocation spread, which is what `F7`'s
control measured on these cells.

### The kitten run

Optimized slot 1 at the candidate tree, kitten 0.48.2, `--render`, alternate
screen, 66 rows x 179 columns pinned with `danterm pane resize 179x66`,
`stty size` confirming `66 179` inside the pane, window **occluded** (the slot
is unattended), which `F10` proved moves nothing. Two runs.

| Arm | this run | `F11` occluded | `F10` occluded | `F1` | move vs `F11` |
| --- | ---: | ---: | ---: | ---: | ---: |
| ascii | 118.3 / 117.8 | 117.2 | 116.9 / 119.2 | 26.7 | 1.01x |
| unicode | 37.2 / 37.1 | 37.2 | 36.2 / 36.1 | 18.8 | 1.00x |
| unique_unicode | 21.3 / 21.3 | 21.4 | 12.6 / 12.6 | 10.7 | 1.00x |
| csi | 46.3 / 45.9 | 21.7 | 20.5 / 20.7 | 19.3 | 2.13x |

Only `csi` moves, and it moves 2.1x. The other three sit inside their own
run-to-run spread against `F11`, which is the correct control: `F11`'s tree is
this comparison's baseline. `csi` at 46.3 MB/s also passes the 41.1-43.1 MB/s
Ghostty figure in `F10`'s preview, so of the four arms `csi` joins `ascii` as
one where DanTerm is ahead. That preview is not the Phase 4 closing table and
its Ghostty column was taken at 61 rows, so this is a direction, not a ranking.

### The frame-presence confirmation

`I4` is a cost invariant that no shipped surface counts, so it is read by which
frames are present under REP rather than by a share -- a share would flatter the
fix, which shrinks its own denominator. `repeatLastPrintedCluster` inlines away
in a release build, so the subtree is taken at every REP-owned frame
(`repeatLastPrintedCluster`, `repeatCluster`, `repeatNarrowScalar`,
`printBulkCluster`).

Three stimuli, each on a plain row with no wrap, fed to `TerminalCoreBenchmark
--profile` at 179x66 and sampled with `sample <pid> 10 1 -mayDie`: kitten's own
`csi` arm for narrow single-scalar, and two one-off streams that repeat one
cluster per row for the other two shapes -- `CUP` + `U+754C` + `CSI 87 b` for
wide, and `CUP` + `a` + `U+0301` + `CSI 177 b` for multi-scalar. The one-off
streams are recorded here and do not become frozen workloads; they carry no
threshold, because the frames are the reading.

| Shape | tree | subtree samples | `print`/`printNarrow`/`printWide` | `appendToOpenClusterIfJoined` | `prepareDestination` | `invalidateInspection` | `recordDamage` | segment stamp |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| narrow | `754c3b50` | 4029 | 2560 | 148 | 526 | 1054 | 368 | -- |
| narrow | candidate | 737 | absent | absent | absent | 19 | 3 | `printBulkNarrow` 708 |
| wide | `754c3b50` | 6713 | 4992 | 63 | 685 | 2323 | 783 | -- |
| wide | candidate | 6707 | absent | absent | 19 | 45 | 6 | `printBulkCluster` 6084 |
| multi-scalar | `754c3b50` | 7152 | 1191 | 3359 | 249 | 1021 | 342 | -- |
| multi-scalar | candidate | 7786 | absent | absent | 3 | 6 | 1 | `printBulkCluster` 7622 |

The baseline column is what makes the candidate column readable: an empty
subtree is "not measured", not "measured zero", and the baseline shows every
per-cell frame present on the same stimulus. `prepareDestination`,
`invalidateInspection` and `recordDamage` survive on the candidate at
per-segment frequency, which is what `I4` asks for. The absolute subtree counts
are not comparable across trees -- `--profile` loops the fixture, so a faster
tree runs more iterations in the same window -- and no direction is claimed
from them.

**Inferred:**

- **REP's cost was the print call, not the cell.** The `csi` arm gives up 73%
  of its feed time and 2.1x on kitten for a change that stores exactly the same
  cells; what it stops paying is one damage record, one inspection
  invalidation, one identity allocation and two wide-neighbour probes per
  repeated cell.
- **A remembered cluster is a cell, so it can be stamped rather than replayed.**
  The memory only ever mirrors a cell the printer produced -- a scalar the
  segmenter refused to join, or a width change it refused to make, never
  reaches it -- so the cluster and its cell width together are what re-feeding
  it produces again. That is what lets the wide and multi-scalar runs skip the
  segmenter outright, and it is also what makes the repeats independent of each
  other, which replaying only achieved by clearing the cluster context before
  every repeat.
- **`prepareDestination` is a range obligation, and treating it as one is what
  makes a wide run useful.** The first shape of the cluster writer copied
  `printBulkNarrow` and refused any destination cell that was not narrow or
  padding. That made the wide path dead on the case that matters -- a program
  repainting a line of CJK -- because the row it overwrites is already full of
  wide pairs. Preparing the whole range once instead is both simpler and
  equivalent: only the two boundaries can straddle the range, and a partner a
  repeat severs mid-run is one the run stores over anyway. The wide profile
  above is on a repainted row, and it takes the bulk path.

**Alternatives:** the four `inconclusive` cells all sit inside the
between-invocation spread `F7`'s control measured on identical code (-1.54% and
+1.66%), none of the paths they exercise is touched, and the `quick` ladder
reads three of them `equivalent`. `incremental-mixed`'s -11.95% is descriptive
only and is not claimed.

**Confidence:** high on `csi`, which agrees across both ladders, the kitten run
and the profile. High that the per-cell work is out of REP on all three cluster
shapes, which the paired frame-presence table reads directly.

**Unlocks:** `H4` closes. The rest of the `csi` arm is `D7`'s list and none of
it has a hypothesis yet: the stream decoder's per-CSI parameter allocation, the
style intern per print, `\e[2K`'s row fill, and the per-action damage snapshot.

## F13 -- The HEAD re-profile of both Unicode arms: `unicode` pays a per-scalar tax four times per CJK character because no wide scalar is bulk-printable, and `unique_unicode`'s new top item is the REP memory rebuilt after every joined scalar

**Observed** (2026-08-29, HEAD `0e1dc83b`, optimized slot 1, kitten 0.48.2,
`--render`, alternate screen, 100 repetitions, 66 rows x 179 columns pinned
with `danterm pane resize 179x66`, window **frontmost**, two runs per arm).
`sample <pid> 8 1 -mayDie` per arm, aggregated by `F6`'s method; an `xctrace`
Time Profiler on `unicode` beside it. Logs are session-local
(`unicode.sample.txt`, `unique_unicode.sample.txt`, the xctrace export) and
are not committed; the tables are the record.

### The kitten run

| Arm | this run | `F12` occluded | `F11` occluded | `F10` frontmost | `F1` | Ghostty preview (`F10`) | preview / now |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| ascii | 118.4 / 117.0 | 118.3 / 117.8 | 117.2 | 118.7 / 119.7 | 26.7 | 86.4 | 0.73x (DanTerm ahead) |
| unicode | 37.1 / 37.3 | 37.2 / 37.1 | 37.2 | 36.2 / 35.2 | 18.8 | 111.4 | 3.0x |
| unique_unicode | 21.3 / 21.3 | 21.3 / 21.3 | 21.4 | 12.6 / 12.6 | 10.7 | 45.6 | 2.1x |
| csi | 45.1 / 46.0 | 46.3 / 45.9 | 21.7 | 20.7 / 20.8 | 19.3 | 41.1 | 0.89x (DanTerm ahead) |
| long_escape_codes | 181.5 / 180.3 | -- | -- | 179.1 / 171.9 | -- | 78.5 | out of scope |
| images | 198.7 / 207.3 | -- | -- | 206.0 / 196.1 | -- | 57.7 | out of scope |

Every arm reproduces `F12` inside its own spread. The two Unicode arms are the
two DanTerm still loses, at 3.0x and 2.1x against the preview.

### Per-thread CPU, and what the render thread does (`H7`)

Whole-process cores from `ps -o time=` deltas: `unicode` 1.99, `unique_unicode`
2.00. The main thread is 99.5% and 99.6% of its own sample stacks under
`_dispatch_main_queue_callback_4CF`, all of it real CPU, so both arms run at
about 1.0 core on the main thread beside about 1.0 core on the PTY host. The
main-thread chain is `H7` exactly: `receiveUpdateSignal` ->
`consume(frameState:result:)` -> `planIfNeeded` -> publish/present ->
`TerminalFrameSwapchain.presentPending` -> `drawRenderFrame` ->
`CGContextRef.drawTextRuns` (95.7% / 98.7% of the main thread) ->
`CTLineCreateWithAttributedString` (74.1% / 80.9%).

Two facts inside that chain are new, and they are `H7`'s evidence from here
on. Under `TGlyphEncoder::EncodeChars` (69.5% / 65.7% of the main thread):

- `TAttributes::CopyOfFontWithLigatureSetting` ->
  `CTFontCreateCopyWithAttributes` -> `CTFontCreateWithFontDescriptor` ->
  `TFont::TFont` is 22.8% / 23.0% of the main thread. CoreText constructs a
  font object per text run, per frame.
- `TFont::SetExtras` -> `ScriptAndLangSysFromCanonicalLanguageInternal` ->
  `CFLocaleCopyPreferredLanguages` -> `_CFPreferencesCopyAppValue` is
  11.2% / 10.8%, and `TFont::ShapesAnyPreferredLanguage` ->
  `IsAnyLangSysTagInPreferredLanguages` is 23.8% / 24.0%. About a third of the
  main thread asks the preferences system which languages the user prefers,
  once per text run, once per frame.

Actual drawing is small beside that: `TLine::DrawGlyphs` 7.2% / 6.1%,
`CGContextFillRect` 2.4%.

### `unicode` -- PTY-host thread, 5042 samples

Inclusive shares of the thread, `F10` beside where it reported the frame:

| Frame | share | `F10` |
| --- | ---: | ---: |
| `feedBuffer` | 92.30% | 93.5% |
| `apply` | 72.53% | 73.2% |
| `print` | 39.85% | 46.5% |
| `printWide` | 25.41% | 26.4% |
| `nextAction` | 17.59% | 17.2% |
| `invalidateInspection` | 9.76% | 9.4% |
| `appendToOpenClusterIfJoined` | 8.15% | 10.4% |
| `recordDamage(from:to:)` | 7.04% | 5.8% |
| `advanceToNextRow` | 5.04% | 5.7% |
| `rememberOpenCluster` | 5.02% | -- |
| `moveAndFillRows` | 4.94% | 5.5% |
| `read` | 4.52% | 3.8% |
| `GraphemeBreakState.shouldBreak` | 4.30% | 4.6% |
| `rotateViewportRows` | 4.28% | 5.2% |
| `classification` | 4.24% | 4.8% |
| `resetAsBlank` | 3.83% | -- |
| `prepareDestination` | 3.43% | -- |
| `execute` | 3.37% | -- |
| `recordDamage(rows:)` | 3.15% | -- |
| `printBulkNarrow` | 2.92% | -- |
| `printScalarRun` | 2.86% | -- |
| outlined destroy of `TerminalStreamAction` | 2.52% | -- |
| `_platform_memmove` | 0.10% | 0.16% |

Leaves: the allocator is absent (`malloc` 0.14%, `free` 0.14%, retain/release
0.34%); uniqueness checks 3.99%, of which 3.49 points are under `printWide`.
Top lines: `TerminalInputStream.swift:103`, the per-byte
`probe.next(bytes[probeIndex])` decoder probe, 6.94%; `Terminal.swift:673`,
the `resetAsBlank` fill loop, 3.57%; `generated.swift:3040`, the stage-two
table lookup, 3.21%; `Terminal.swift:2212` `let after = damageActionSnapshot`
2.68%; `:1883` `recordDamage(from:to:)` entry 2.20%; `:8761` the wide-head
store 1.96%; `:5077` `invalidateInspection` epilogue 1.86%; `:8147` the
`writeNarrowCells` call 1.82%; `:2213` the `recordDamage` call 1.59%; `:2215`
`apply` epilogue 1.53%; `:9287` `prepareDestination`'s wide-tail probe 1.41%;
`:8415` `rememberOpenCluster` reading the cell back 1.25%; `:8768` the
wide-tail store 1.05%.

### `unique_unicode` -- PTY-host thread, 5108 samples

`F10`'s pre-`H2` shares beside, where the frame existed:

| Frame | share | `F10` |
| --- | ---: | ---: |
| `feedBuffer` | 95.79% | 97.1% |
| `apply` | 81.25% | 86.7% |
| `print` | 27.11% | 70.4% |
| `rememberOpenCluster` | 26.66% | -- |
| `appendToOpenClusterIfJoined` | 22.67% | 50.4% |
| `GridRow.copyScalars(of:into:)` | 11.94% | -- |
| `nextAction` | 11.16% | 8.4% |
| `printASCIIRun` | 8.81% | 9.0% |
| `recordDamage(from:to:)` | 8.10% | -- |
| `printBulkNarrow` | 7.32% | -- |
| `invalidateInspection` | 5.62% | -- |
| `Array.replaceSubrange` | 5.32% | -- |
| `GridRow.appendScalar` | 4.95% | 31.4% |
| `shouldBreak` | 3.84% | -- |
| `classification` | 3.66% | -- |
| uniqueness stubs | 5.36% | 3.8% |
| `swift_release` | 2.55% | -- |
| `swift_retain` | 2.25% | -- |
| `setClusterCount` | 1.76% | -- |
| `beginCluster` | 1.64% | -- |
| `memmove` | 0.94% | 2.5% |
| `compactClusters` | 0.92% | -- |
| `_consumeAndCreateNew` | 0.04% | 12.9% |

Leaves: retain/release 8.38%, all of it under `rememberOpenCluster`;
uniqueness 5.36% (`copyScalars` 1.61, `appendScalar` 0.90,
`appendToOpenClusterIfJoined` 0.72, `replaceSubrange` 0.72, `setClusterCount`
0.47); `memmove` 1.49% under `replaceSubrange`. Top lines: `Terminal.swift:443`,
`copyScalars`' `for position in 1..<count { memory.extend(...) }`, 4.23%;
`TerminalInputStream.swift:103` 2.96%; `generated.swift:3040` 2.74%; `:2212`
2.56%; `:2213` 2.21%; `:1883` 1.96%; `:2189` the `apply` switch dispatch
1.47%; `:8505` `appendScalar`'s arena append 1.35%; `:8147` 1.27%; `:8415`
`rememberOpenCluster` reading the cell back 1.25%; `:442`
`memory.set(arena[offset + 1])` 1.08%.

### Buckets

Self time, summing to the thread, `unicode` / `unique_unicode`, with the
ledger line that owned each before this finding:

| Bucket | `unicode` | `unique_unicode` | owner before `F13` |
| --- | ---: | ---: | --- |
| (a) decode + classify + grapheme | 23.94% | 16.95% | Minor line |
| (b) cell placement | 21.50% | 5.62% | Unattributed line |
| (c) cluster join + REP memory | 10.04% | 44.13% | none; new residue |
| (d) per-print damage + inspection | 17.67% | 13.98% | Unattributed line |
| (e) line advance + blank fill | 4.84% | 0.18% | `H6` |
| (f) delivery (`read`, the turn copy) | 4.64% | 1.86% | Minor line |
| (g) other | 17.37% | 17.29% | none |

Bucket (g) is `apply`'s own self time -- the `@inline(never)` per-action
switch, prologue and epilogue -- 12.67% / 12.08%, the `TerminalStreamAction`
destroy 1.90% / 2.47%, and the `feedBuffer` loop.

### Reading the `unicode` path, scalar by scalar

The corpus is CJK: 3-byte UTF-8, wide, break class `.other`, nothing joins.
For each such scalar, in order:

1. `nextAction`'s scalar-run probe (`TerminalInputStream.swift:91-135`) copies
   the decoder, steps it per byte, and per decoded scalar pays
   `utf8ByteCount`, the re-encode-length check (`:110`),
   `isIgnoredDecodedScalar`, and `terminalUnicodeClassification` (`:119`) --
   and then **always** ends the run, because `isBulkPrintable`
   (`UnicodeBulkPrinting.swift:5`) requires `cellWidth == .narrow`. No wide
   scalar is ever bulk-printable, so `nextAction` returns `.print(scalar)` for
   100% of this corpus, one action per character.
2. Each action pays `apply`'s dispatch, `damageActionSnapshot` (`:2212`) and
   `recordDamage(from:to:)` (`:2213`).
3. `Terminal.print` (`:8347`) classifies the same scalar a second time, and
   `appendToOpenClusterIfJoined` runs the whole guard chain and
   `GraphemeBreakState` per scalar even though nothing can join, because
   `printWide` rebuilds `clusterContext` at `:8777` for every cell.
4. `printWide` per cell: the head store at `:8761` and the tail store at
   `:8768`, each a copy-on-write-checked two-level subscript write (it owns
   3.49 of the 3.99 uniqueness points); **two** `invalidateInspection` calls
   (`:8711` and `:8742`) against one per run on the bulk path;
   `prepareDestination` over two columns with the wide-head and wide-tail
   neighbour probes (`:9283`, `:9287`); `allocateContentIdentity` and
   `backgroundEraseStyleId` per cell against `reserveContentIdentities` once
   per run; a fresh `ClusterContext`; `rememberOpenCluster` reading the cell
   back; and the wrap, insert-mode and single-shift tests re-run per cell plus
   the right-margin wide-wrap branch (`:8715-8740`).

So buckets (a), (b), (d) and (g) -- about 80% of the thread -- all trace to
one structural fact: run granularity never engages on a wide scalar.

### Reading the `unique_unicode` path

`H2` worked: the allocator is gone from the append (`_consumeAndCreateNew`
12.9% -> 0.04%). What it uncovered is `rememberOpenCluster` at 26.7% of the
thread. `print` calls it after **every** scalar, on the join path (`:8355`)
and on the fresh-cell path (`:8383`). Each call reads the cell back through
the row, and for a spilled cell `copyScalars(of:into:)` (`:435-445`) re-copies
the **entire** open cluster into `lastPrintedCluster`: a four-scalar cell
copies 1 + 2 + 3 + 4 = 10 scalars over its four prints, into a heap
`[Unicode.Scalar]` that is moved out of `self` and back by a swap, retained
and released across it, and grown by `replaceSubrange`. That is the whole of
bucket (c)'s 44%: the join itself (`appendScalar` 4.95%) is small.

### xctrace cross-check on `unicode`

2.12 cores; main thread 50.0%, PTY host 50.0%. PTY-host self time: `apply`
9.29%, `nextAction` 7.52%, `UTF8Decoder.next` 5.47%, `invalidateInspection`
4.67%, `recordDamage` 4.65%, `read` 4.10%, `printWide` 4.05%,
`Array._getElement` 3.79%, `IndexingIterator.next` 3.60%, `classification`
2.95%. It agrees with `sample` modulo symbolization.

**Inferred:**

- **`unicode` is one mechanism, not four.** The four buckets that make up
  80% of the thread are the flat per-scalar tax of the single-cell print
  path, paid because the stream never yields a run for a wide scalar. The
  single change that moves most of it is a bulk run for wide non-joining
  scalars, which is `H8`. `D8` prototyped it and read
  `kitten-feed-unicode: faster (-62.40%)`.
- **`unique_unicode`'s top item is `D6`'s own shape.** `D6` unaliased the
  REP memory so the arena could grow in place, and did it by copying the
  cluster out after every printed scalar. The copy is quadratic in the
  cluster length, and it is now the largest single item on the arm. That is
  `H9`. `D8` prototyped extending the memory by the one scalar that joined
  and read `kitten-feed-unique-unicode: faster (-21.84%)`.
- **`H7` has a finer mechanism than "re-typesets every line".** Half of the
  main thread's typesetting is not shaping: it is constructing a font object
  per run and asking the preferences system for the preferred languages per
  run. A shaped-line cache would remove all of it; a per-frame font cache or
  a pre-resolved language attribute would remove the half that is not
  shaping. Still no MB/s today, and still no ladder arm.
- **What the two mechanisms leave.** After `H8` the `unicode` thread is the
  stream's decode and classification (about a third), the wide cell stamp
  (about a quarter), `H6`'s blank fill, and a second decode inside
  `printScalarRun`; after `H9` the `unique_unicode` thread is the guard
  chain, damage and inspection, and the grapheme break. Neither has a
  hypothesis for those.

**Alternatives:** the `unicode` buckets could be read as four independent
costs each needing its own fix; `D8`'s prototype is what rejects that,
since one change moved -62%. `rememberOpenCluster`'s 26.7% could be the
swap dance rather than the copy; the line attribution (`:443`, the copy
loop, is the top line on the arm) and the retain/release parent say it is
the copy and the buffer it fills.

**Confidence:** high on both mechanisms; each is read three ways (frame,
line, and a prototype that moves the arm). High on the `H7` detail, which
two arms agree on. The kitten figures are a reproduction of `F12`, not new
evidence.

**Unlocks:** `H8` and `H9` enter the hypothesis list with prototypes behind
them; `D8` orders them and writes the plan. The Minor and Unattributed
ledger lines give up what `H8` now owns.

## F14 -- `H8` lands: a wide run stamps a row segment at a time, `kitten-feed-unicode` reads `faster` at -64.65% on confirm, and the kitten `unicode` arm goes 37.1 -> 68.4 MB/s

**Observed** (2026-08-29, pre-change revision `0e1dc83b`, baseline tree
`0ecbe498`, candidate tree `7914c8c9`). The change makes bulk-print
eligibility a property of the scalar rather than of its width, cuts a scalar
run where the width changes, and gives the printer a wide segment writer
beside the narrow one.

### Ladder

`just benchmark-quick baseline=0e1dc83b workload=kitten-feed-<arm>`, one arm at
a time:

| Arm | quick verdict | frozen threshold |
| --- | --- | --- |
| kitten-feed-unicode | **faster** (-62.44% symmetric median of 2 pairs) | +/-1.80% |
| kitten-feed-unique-unicode | equivalent (-0.62%) | +/-1.60% |
| kitten-feed-ascii | inconclusive (-1.25%) | +/-1.70% |
| kitten-feed-csi | equivalent (+0.29%) | +/-1.45% |

`just benchmark-confirm baseline=0e1dc83b`, all ten workloads:

| Workload | verdict |
| --- | --- |
| terminal-feed | equivalent (-0.34% of 2 pairs) |
| scrollback-stream | -0.63% of 4 pairs (descriptive, uncalibratable) |
| content-churn | inconclusive (-1.18% of 4 pairs) |
| style-churn | inconclusive (-1.19% of 4 pairs) |
| incremental-mixed | +7.85% of 6 pairs (descriptive, uncalibratable) |
| retained-browse | equivalent (+0.66% of 4 pairs, 3 flagged outlier pairs retained) |
| kitten-feed-ascii | inconclusive (-1.30% of 2 pairs) |
| kitten-feed-unicode | **faster** (-64.65% of 2 pairs) |
| kitten-feed-unique-unicode | inconclusive (-0.97% of 2 pairs) |
| kitten-feed-csi | equivalent (+0.63% of 2 pairs) |

No arm reads `slower` on either mode, and `retained-browse` -- the cell `D6`'s
first shape cost 10.3% -- reads `equivalent`. Artifacts:
`.build/terminal-benchmark-comparisons/quick/7914c8c9c356-0000` and
`.build/terminal-benchmark-comparisons/confirm/7914c8c9c356-0000`.

### Which frames are present

`sample <pid> 8 1 -mayDie` on each arm's own release `TerminalCoreBenchmark
--profile` fed the `unicode` fixture, one arm per run, machine otherwise idle.
Baseline 329 stacks / 6026 weighted samples; candidate 463 / 6023. Inclusive
share of the one thread:

| Frame | baseline | candidate |
| --- | ---: | ---: |
| `apply(_:in:before:)` | 78.28% | 62.36% |
| `printScalarRun` | 2.72% | 42.62% |
| `printBulkWide` | -- | 25.22% |
| `nextAction` | 17.59% | 36.13% |
| `Terminal.print(_:recoversGridContext:)` | 43.96% | 7.99% |
| `printWide` | 29.84% | 4.93% |
| `invalidateInspection(inViewportRows:...)` | 12.03% | 1.81% |
| `appendToOpenClusterIfJoined` | 8.65% | 1.73% |
| `recordDamage(from:to:)` | 7.37% | 2.71% |
| `recordDamage(rows:)` | 4.45% | 0.86% |
| `rememberOpenCluster` | 5.41% | 2.54% |
| `prepareDestination` | 3.80% | 0.53% |

Every remaining `printWide` stack in the candidate arrives through
`printScalarRun -> print -> printWide` and carries the wrap machinery
(`restoreWrapClaimBeforeCursor`, `moveAndFillRows`) under it: that is the one
pair per row the right margin leaves no room for, which the segment declines
by design. No `print`, `printWide` or `appendToOpenClusterIfJoined` frame
appears under `printBulkWide`. Its whole subtree is the per-segment set:
`recoverClusterContextFromGridIfNeeded` 25 samples, `rememberOpenCluster` 12,
`prepareDestination` 8, `invalidateInspection`/`recordDamage` 8,
`reserveContentIdentities` 1, `backgroundEraseStyleId` 1. `writeWideCells`
and `writeNarrowCells` are absent from both trees: the optimizer inlines them
into their callers.

### External confirmation

`kitten __benchmark__ --render`, kitten 0.48.2, alternate screen, 100
repetitions, optimized slot (`just launch-slot-optimized`), pane pinned to
179x66 with `danterm pane resize`, window present but **not frontmost** (the
slot launches detached), so the like-for-like column is `F12`'s occluded run:

| Arm | now | `F13` frontmost | `F12` occluded | Ghostty preview (`F10`) | preview / now |
| --- | ---: | ---: | ---: | ---: | ---: |
| ascii | 118.7 | 118.4 / 117.0 | 118.3 / 117.8 | 86.4 | 0.73x (DanTerm ahead) |
| unicode | **68.4** | 37.1 / 37.3 | 37.2 / 37.1 | 111.4 | 1.63x |
| unique_unicode | 21.4 | 21.3 / 21.3 | 21.3 / 21.3 | 45.6 | 2.1x |
| csi | 46.3 | 45.1 / 46.0 | 46.3 / 45.9 | 41.1 | 0.89x (DanTerm ahead) |
| long_escape_codes | 170.2 | 181.5 / 180.3 | -- | 78.5 | out of scope |
| images | 191.4 | 198.7 / 207.3 | -- | 57.7 | out of scope |

The `unicode` arm moves 1.84x and no other arm moves outside its own spread.

**Inferred:**

- **The wide arm's cost was the per-cell granularity, not the wide cell.**
  One change -- letting the run carry a width instead of insisting on narrow
  -- removed two thirds of the arm, and the frame table says where it went:
  the four per-scalar taxes `F13` named (`print`'s dispatch, the second
  classification, the join guard chain, and the single-cell print's own
  prologue) each collapse to once per row segment.
- **The remaining `unicode` cost has moved to the stream.** `nextAction` is
  now 36% of the thread and `apply` 62%, so the decode and classification
  `D8` left as a non-goal is now the largest single item on the arm, with the
  segment stamp itself second at 25%.
- **`unique_unicode` is untouched, as designed.** Its arm reads
  `equivalent`/`inconclusive` on both modes and its kitten figure does not
  move: no `unique_unicode` cell is wide, so no run of its scalars is a wide
  run. That arm is the second commit's.

**Alternatives:** the -64.65% could be a build or cache artifact rather than
the change; the frame table rejects that, since the frames that disappear are
exactly the ones the change stops calling, and the external kitten run moves
the same direction on the same arm and no other.

**Confidence:** high. The verdict is read on both `quick` and `confirm`
against the same pre-change revision, the mechanism is read directly by
frame presence on paired samples of the same stimulus, and the kitten arm
moves 1.84x.

**Unlocks:** `H8` closes. `H9` -- the REP memory rebuilt after every joined
scalar -- is next and unaffected by this commit. What `unicode` has left is
the stream's own decode and classification, the printer's second decode
inside `printScalarRun`, and `H6`'s blank fill; none has a hypothesis.

## F15 -- `H9` lands: the printer mirrors the REP memory instead of rebuilding it, `kitten-feed-unique-unicode` reads `faster` at -21.55% on confirm, and the kitten `unique_unicode` arm goes 21.4 -> 26.2 MB/s

**Observed** (2026-08-29, pre-change revision `1c74156b`, baseline tree
`705c7586`, candidate tree `071d2c87`). The change makes the REP memory a
mirror the printer maintains from what it places: a scalar that joins a cluster
the printer opened extends the memory, and only a context the printer did not
open -- recovered from the grid, or restored by the synchronization stream --
still copies the target cell out of the row.

### Ladder

`just benchmark-quick baseline=1c74156b workload=kitten-feed-<arm>`, one arm at
a time:

| Arm | quick verdict | frozen threshold |
| --- | --- | --- |
| kitten-feed-unique-unicode | **faster** (-22.72% symmetric median of 2 pairs) | +/-1.60% |
| kitten-feed-unicode | equivalent (-0.00%) | +/-1.80% |
| kitten-feed-ascii | equivalent (+0.43%) | +/-1.70% |
| kitten-feed-csi | equivalent (-0.92%) | +/-1.45% |

`just benchmark-confirm baseline=1c74156b`, all ten workloads:

| Workload | verdict |
| --- | --- |
| terminal-feed | inconclusive (-0.92% of 2 pairs) |
| scrollback-stream | -2.48% of 4 pairs (descriptive, uncalibratable) |
| content-churn | equivalent (+0.47% of 4 pairs) |
| style-churn | inconclusive (+1.33% of 4 pairs) |
| incremental-mixed | +0.36% of 6 pairs (descriptive, uncalibratable) |
| retained-browse | equivalent (+0.16% of 4 pairs) |
| kitten-feed-ascii | equivalent (+0.36% of 2 pairs) |
| kitten-feed-unicode | equivalent (-0.16% of 2 pairs) |
| kitten-feed-unique-unicode | **faster** (-21.55% of 2 pairs) |
| kitten-feed-csi | faster (-1.57% of 2 pairs) |

No arm reads `slower` on either mode, and `retained-browse` -- the cell `D6`'s
first shape cost 10.3%, named again for this commit -- reads `equivalent`.
Artifacts: `.build/terminal-benchmark-comparisons/quick/071d2c873f1b-0000` and
`.build/terminal-benchmark-comparisons/confirm/071d2c873f1b-0000`.

### Which frames are present

`sample <pid> 8 1 -mayDie` on each arm's own release `TerminalCoreBenchmark
--profile` fed the `unique-unicode` fixture, one arm per run, machine otherwise
idle. Baseline 351 stacks / 6648 weighted samples; candidate 347 / 6641.
Inclusive share of the one thread:

| Frame | baseline | candidate |
| --- | ---: | ---: |
| `apply(_:in:before:)` | 83.94% | 75.37% |
| `Terminal.print(_:recoversGridContext:)` | 28.78% | 36.82% |
| `rememberOpenCluster` | 27.12% | 4.20% |
| `GridRow.copyScalars(of:into:)` | 11.60% | -- |
| `appendToOpenClusterIfJoined` | 23.71% | 30.64% |
| `nextAction` | 11.01% | 18.39% |
| `printASCIIRun` | 9.66% | 12.32% |
| `printBulkNarrow` | 8.15% | 10.63% |
| `recordDamage(from:to:)` | 7.64% | 8.90% |
| `invalidateInspection(inViewportRows:...)` | 7.25% | 8.04% |
| `GridRow.appendScalar(_:at:)` | 5.08% | 5.59% |
| `swift_release` | 2.80% | -- |
| `swift_retain` | 2.62% | -- |

The cluster copy and the whole of the arm's retain/release are gone from the
tree, which is `F13`'s reading of this cost inverted. Every `rememberOpenCluster`
sample left in the candidate arrives under a bulk writer or the fresh-cell print
-- 271 samples under `printBulkNarrow`, 8 under `printASCIIRun`'s inlined
`print` -- and none under `appendToOpenClusterIfJoined`, whose subtree is now
the join's own work: `appendScalar` 345, `shouldBreak` 289, `invalidateInspection`
366, `recordDamage(rows:)` 151, `firstScalar` 55. `LastPrintedCluster.extend`
never appears: the optimizer inlines it into the join.

### External confirmation

`kitten __benchmark__ --render`, kitten 0.48.2, alternate screen, 100
repetitions, optimized slot (`just launch-slot-optimized`), pane pinned to
179x66 with `danterm pane resize`, window present but **not frontmost**:

| Arm | now | `F14` | `F13` frontmost | `F12` occluded | Ghostty preview (`F10`) | preview / now |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| ascii | 114.0 | 118.7 | 118.4 / 117.0 | 118.3 / 117.8 | 86.4 | 0.76x (DanTerm ahead) |
| unicode | 67.5 | 68.4 | 37.1 / 37.3 | 37.2 / 37.1 | 111.4 | 1.65x |
| unique_unicode | **26.2** | 21.4 | 21.3 / 21.3 | 21.3 / 21.3 | 45.6 | 1.74x |
| csi | 45.5 | 46.3 | 45.1 / 46.0 | 46.3 / 45.9 | 41.1 | 0.90x (DanTerm ahead) |
| long_escape_codes | 158.6 | 170.2 | 181.5 / 180.3 | -- | 78.5 | out of scope |
| images | 177.6 | 191.4 | 198.7 / 207.3 | -- | 57.7 | out of scope |

This whole run reads a few points under `F14` on every arm except the one the
change touches -- `long_escape_codes` and `images`, which the change cannot
reach, are down 7% -- so the run's own offset is the control and
`unique_unicode` still moves 1.22x against it.

**Inferred:**

- **The rebuild was the cost, not the memory.** `F13` put
  `rememberOpenCluster` at 26.7% of the arm with all of its retain/release
  underneath; extending the memory by the scalar that just joined removes both
  outright and moves the calibrated arm -21.55%. The `k`-times-with-growing-
  length copy was the whole item.
- **Provenance is what the mirror needs, and only two paths supply it.** The
  claim is carried on the cluster context, so everything that invalidates the
  look-behind expires it; the only writers that can leave a memory and a
  context naming different cells are the synchronization stream's own
  `repeat=none` and `repeat-add`, which drop the claim explicitly.
- **`unique_unicode` is now the join itself.** With the rebuild gone, the arm's
  top items are the join's guard chain and `appendScalar`'s arena work, under a
  `print` that still costs a per-scalar action. No hypothesis names either.

**Alternatives:** the -21.55% could be machine drift rather than the change;
the frame table rejects that, since the frames that disappear are exactly the
ones the change stops calling, and the kitten arm moves up on the one arm while
every other arm on the same run moves down.

**Confidence:** high. The verdict is read on both `quick` and `confirm` against
the same pre-change revision, the mechanism is read directly by frame presence
on paired samples of the same stimulus, and the kitten arm moves 1.22x against a
run whose other arms all read low.

**Unlocks:** `H9` closes, and with it every hypothesis `D8` opened. What is left
on the two Unicode arms has no hypothesis: the stream's own decode and
classification (`nextAction`, now 18% of `unique_unicode` and 36% of
`unicode`), the printer's second decode inside `printScalarRun`, the per-action
damage snapshot, and `H6`'s blank fill.

## F16 -- The two-thread reading at HEAD: the draw thread costs a core and decides no MB/s, a non-drawing DanTerm feeds both Unicode arms at the same rate, and `unicode`'s feed thread is 12-16% idle in `read`

**Observed** (2026-08-29, HEAD `a844a082`, optimized slot 1, kitten 0.48.2,
`--render`, alternate screen, 100 repetitions, pane pinned to 179x66 with
`danterm pane resize` and `pane info` reporting `{"columns":179,"rows":66}`
before every run). Four window states, each verified with `osascript` reading
the frontmost process name before and during the run:

- **occluded**: the slot window behind the user's DanTerm, which stayed
  frontmost.
- **frontmost**: `open -b com.danneu.danterm-dev.1`, `DanTerm Dev (1)`
  frontmost.
- **hidden**: the slot process set not visible through System Events.
- **hidden, App Nap off**: `defaults write com.danneu.danterm-dev.1
  NSAppSleepDisabled -bool YES`, slot relaunched (pid 24157), then hidden as
  above. The default was deleted afterwards.

Beside every kitten figure: whole-process cores from `ps -o time=` polled
every 0.25 s and read over the interior of the run; per-thread `%CPU` from one
`ps -M` taken 1.2-2.5 s into the run (its first row is the main thread); and a
1 s `sample` at the same moment, read for the main thread's share under
`_dispatch_main_queue_callback_4CF` and for wait frames under the PTY-host
thread.

| Arm | state | MB/s | process cores | main thread `%CPU` | PTY-host `%CPU` | kitten `%CPU` |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| unicode | occluded | 68.5 / 64.3 / 64.8 | 1.81 / 1.89 | 88.3 / 89.4 | 85.3 | 93.0 |
| unicode | frontmost | 65.0 / 64.4 | 1.80 / 1.81 | 87.5 / 87.7 | 83.7 / 87.6 | -- |
| unicode | hidden | 22.2 / 16.4 | 0.90 / 0.91 | 0.6 / 1.3 | -- | 91.9 / 92.3 |
| unicode | hidden, App Nap off | 67.7 / 67.6 | 0.96 / 0.95 | 0.6 / 0.6 | 87.9 | 91.0 / 92.9 |
| unique_unicode | occluded | 25.7 | 1.94 | 99.6 | -- | -- |
| unique_unicode | frontmost | 25.7 / 25.7 | 1.89 / 1.88 | 99.4 / 100.0 | 100.0 / 100.0 | -- |
| unique_unicode | hidden | 4.5 | 0.93 | 2.2 | -- | 102.0 |
| unique_unicode | hidden, App Nap off | 25.8 | 0.99 | 1.0 | 99.4 | 100.6 |

A `--` is a value the run did not record, not a zero: the PTY-host column was
cut from the first three `ps -M` listings, and kitten's own line was added to
the runner after them.

The `sample` reading agrees with `ps -M`. Occluded `unicode`: 775 of the main
thread's 780 stacks sit under `_dispatch_main_queue_callback_4CF`, in the
`drawTextRuns` chain `F13` describes; the PTY-host thread's 775 stacks hold no
`ulock_wait`, `__psynch` or `mach_msg2_trap` frame, and 59 of them (7.6%) end in
the `read` syscall. Occluded `unique_unicode`: 19 of 793 (2.4%) in `read`, no
wait frames. Hidden with App Nap off, the main thread's stacks are the idle
`mach_msg` loop.

The headless rate of the same stimulus, `TerminalCoreBenchmark --fixed 1 5` on
the release build fed the arm's own fixture (two repetitions per execution):
`unicode` 44.5 ms per execution for 3.62 MB, about 81 MB/s; `unique_unicode`
126 ms for 3.5 MB, about 28 MB/s; `ascii` 27.1 ms for 4.2 MB, about 155 MB/s.
Against `F15`'s kitten figures that is 80%, 92% and 74% of the headless rate
reaching the terminal through the PTY.

**Inferred:**

- **`H7` does not bind, and the reading is now clean.** With the main thread
  at 0.6-1.0% and the process at one core, the two arms feed at 67.7 / 67.6
  and 25.8 MB/s, inside the spread of the runs where the main thread draws at
  88-100% of a core. Drawing costs a core on both arms and decides no MB/s; the
  feed thread alone sets the rate, and it waits on nothing (`F13`'s condition
  for `H7` to bind -- the feed thread outrunning the draw thread -- has not
  arrived even after `H8` and `H9`).
- **Occluded has never meant non-drawing at HEAD.** Behind another window the
  main thread still draws at 88-100% of a core, so `F10`'s "identical frontmost
  and occluded" compared two drawing states. The README's reading that an
  occluded slot "was not drawing" was true when `F3` took it (the main thread
  at 0.3%, before `H1` made the feed fast enough to matter) and is not true
  now. The only non-drawing state at full clock is a hidden app with App Nap
  disabled.
- **A hidden app is throttled, not idle.** Hidden with App Nap on, the process
  still burns 0.9 cores and kitten 92-102%, yet the arms fall 3-6x; that is App
  Nap moving the app and its child kitten to a low-power state, and it says
  nothing about drawing. Never take a kitten figure from a hidden or
  minimized app without `NSAppSleepDisabled`.
- **`unicode`'s remaining ceiling has a delivery term.** Its PTY-host thread
  runs at 84-88% in every state, with the gap under `read`, and the kitten
  figure is 80% of the headless feed rate; `unique_unicode`'s thread is pinned
  at 100% and its kitten figure is 92% of headless. So a parse fix on `unicode`
  moves the kitten figure by less than it moves the ladder arm, and once the
  parse is fast enough the tty handoff (`F3`: kitten spins on `EAGAIN` against
  a 2048-byte high-water mark) is what sets the number. That is the ledger's
  delivery line, not `H7`, and `ascii` at 114 MB/s through the same path
  bounds it from below.

**Alternatives:** the 84-88% could be the draw thread stalling the feed thread
through the fence copy rather than the tty; the hidden App-Nap-off runs
reject that, since the PTY thread reads the same 87.9% with the main thread
idle. The hidden-state collapse could be a DanTerm bug rather than App Nap;
`NSAppSleepDisabled` alone restoring the full rate says it is the system's
throttle.

**Confidence:** high on the verdict, read three ways (MB/s across four
states, per-thread CPU, wait frames) on both arms. Medium on the size of the
delivery term, which is one headless measurement per arm and not a paired one.

**Unlocks:** `H7` stays deferred with numbers behind it, and `D9` can rank
`H10` and `H6` on the feed thread alone. The README's window-state caveat is
corrected. Phase 4's closing table gains a rule: the DanTerm figure is taken
frontmost, never hidden.

Artifacts: the runner (`run-arm.sh`), the `ps` poller, the `ps -M` listings,
the per-run `sample` files and the aggregation scripts were session-local in
the agent scratchpad and are not committed; the tables are the record.

## F17 -- `H10`'s first commit: the run action carries its scalar count and the printer decodes by lead byte, `kitten-feed-unicode` reads `faster` at -31.18% on confirm

**Observed** (2026-08-29, pre-change revision `5f71a9b3`, baseline tree
`baddb4b8`, candidate tree `b42b217a`). This is commit 1 of `D9`'s three, the
cheap shape `D9` measured: the stream's run action carries the number of
scalars its range holds, and the printer sizes each segment from that count
and decodes each scalar from its lead byte instead of re-scanning the range
for lead bytes and stepping every byte through `UTF8Decoder`. The stream still
decodes each run byte through the resumable decoder; that is commit 2.

### Ladder

`just benchmark-quick baseline=5f71a9b3 workload=kitten-feed-<arm>`, one arm at
a time:

| Arm | quick verdict | frozen threshold |
| --- | --- | --- |
| kitten-feed-unicode | **faster** (-29.91% symmetric median of 2 pairs) | +/-1.80% |
| kitten-feed-unique-unicode | equivalent (-0.36%) | +/-1.60% |
| kitten-feed-ascii | faster (-1.85%) | +/-1.70% |
| kitten-feed-csi | equivalent (-0.30%) | +/-1.45% |

`just benchmark-confirm baseline=5f71a9b3`, all ten workloads:

| Workload | verdict |
| --- | --- |
| terminal-feed | equivalent (-0.70% of 2 pairs) |
| scrollback-stream | +2.82% of 4 pairs (descriptive, uncalibratable) |
| content-churn | equivalent (+0.14% of 4 pairs) |
| style-churn | equivalent (+0.43% of 4 pairs) |
| incremental-mixed | +2.94% of 6 pairs (descriptive, uncalibratable) |
| retained-browse | equivalent (-0.21% of 4 pairs) |
| kitten-feed-ascii | inconclusive (-1.47% of 2 pairs) |
| kitten-feed-unicode | **faster** (-31.18% of 2 pairs) |
| kitten-feed-unique-unicode | inconclusive (+1.56% of 2 pairs) |
| kitten-feed-csi | inconclusive (+1.26% of 2 pairs) |

No arm reads `slower` on either mode. The `ascii` quick reading of -1.85% is a
direction on an arm this commit cannot reach -- no ASCII byte enters a scalar
run -- so it is read against `F7`'s change-free control, and `confirm` puts the
same arm at -1.47%, inside its own band. `content-churn` and `retained-browse`
are read against that control too, per `D4`, and both read `equivalent`.
Artifacts: `.build/terminal-benchmark-comparisons/quick/b42b217abe8a-0000`
through `-0003` and `.build/terminal-benchmark-comparisons/confirm/b42b217abe8a-0000`.

**Inferred:**

- **The printer's re-scan and its state-machine decode were about a third of
  the `unicode` arm.** `D9` sized the printer's second decode at about a fifth
  of the feed thread and the re-scan at 6%; removing both reads -31.18%, which
  is the two of them plus what the count saves the segment loop.
- **The stream's own decode is what is left.** `unique_unicode` does not move,
  which is the expected shape: its scalars still reach the printer one action
  at a time, and the probe still decodes every run byte twice-over on both
  arms. Commit 2 is aimed there.

**Alternatives:** the -31.18% could be a build or cache artifact rather than
the change. Against that: the arm that moves is exactly the arm whose bytes go
through `printScalarRun`, the three arms that do not use that path all read
inside their bands on `confirm`, and the reading repeats on both modes against
the same pre-change revision.

**Confidence:** medium-high. The verdict is read on both `quick` and `confirm`
and the arm selection matches the mechanism, but the frame-presence
corroboration `D9`'s gate asks for is taken once for the whole change, after
the last kept commit, so this commit's mechanism is carried by structure and by
the ladder alone.

**Unlocks:** commit 2 -- the probe decoding a complete well-formed sequence in
one step, and the single-scalar action carrying the classification the stream
already read -- which is the commit `unique_unicode` is gated on.
