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
