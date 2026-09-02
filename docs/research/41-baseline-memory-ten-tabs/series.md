# Series -- the ten-tab footprint over time

The one place every footprint reading goes, in the order it was taken.
Append-only; rows are cited as `41/S<n>`. A row is a reading of one build
under the fixed staging (ten tabs, 170x60 read back, Menlo 13, 2x, one
visible window). The raw document for each row lives under `readings/`.

`How` says what took the reading. `script` is
`scripts/research/41/ten-tab-footprint.py`: one slot, 5 s settle, ten
samples. `harness` is termwars' `just memory --terminals danterm`: 60 s
settle, 60 samples, three interleaved reps, and a receipt under
`~/Code/termwars/results/`. Either is a valid row; the harness is the one to
use for a paired claim, and a claim is two rows taken in the same session
(before and after) whose difference clears the A/A spread.

A harness run may name a checkout per arm --
`--terminals danterm@<path>,danterm` -- so two revisions are built into their
own slots and their reps interleaved inside one run. That is what makes a
paired claim one session rather than two; `S11` through `S18` are four
revisions of one such run.

`Spread` is max minus min across one row's samples: how flat the process was
while sampled, not session noise. `Surfaces` is `T1`'s attributed surface
bytes with the count it sums. From `danterm debug surfaces` it reads
`<bytes> (<stores> stores, <chains> chains, <hidden>/<total> hidden, app)` and is
written `unmeasured` when the read failed or any pane went unmeasured; a row may
instead name a `vmmap` class total, which says what the process held, not what
the app thinks it owns. `Switch` is `T3`'s hidden-tab reveal latency, read
with `scripts/research/41/tab-switch-latency.py` from the app's own
presentation trace: the median of `reveal` to the first `attach` on the
revealed pane, written `<median> (n=<samples>)`. It is `no frame (n=<samples>)`
when a reveal presented nothing at all, which is a measured answer and not a
missing one, and `unmeasured` when no reading was taken. `Note` names the
change under test, or `baseline`, or `A/A` for a repeat of a build already in
the table.

| S | Date | Commit | Arm | How | Median bytes | Spread | Surfaces | Switch | Document | Note |
|---|---|---|---|---|---:|---:|---|---|---|---|
| S1 | 2026-09-01 | `5ffdb5ae` | empty | script | 643,892,520 | 409,600 | unmeasured | unmeasured | [json](readings/2026-09-01-5ffdb5ae-tabs-empty-visible.json) | baseline (`F3`) |
| S2 | 2026-09-01 | `36e59927` | empty | script | 644,252,968 | 49,152 | 607,649,792 (31 regions, `vmmap`) | unmeasured | [json](readings/2026-09-01-36e59927-tabs-empty-visible.json) | `T2` capture slot (`F4`) |
| S3 | 2026-09-01 | `19dc5cc6` | empty | script | 643,990,824 | 557,056 | 607,518,720 (30 stores, 10 chains, 9/10 hidden, app) | unmeasured | [json](readings/2026-09-01-19dc5cc6-tabs-empty-visible.json) | `T1` lands; first in-app attribution |
| S4 | 2026-09-01 | `2c544f84` | empty | script | 644,777,256 | 475,136 | 607,518,720 (30 stores, 10 chains, 9/10 hidden, app) | no frame (n=12) | [json](readings/2026-09-01-2c544f84-tabs-empty-visible.json) | `T3` lands; presentation trace added (`F5`) |
| S5 | 2026-09-01 | `951b4393+T6` | empty | script | 98,501,952 | 606,208 | 607,518,720 (30 stores, 10 chains, 9/10 hidden, app) | 1.37 ms (n=12) | [json](readings/2026-09-01-951b4393-t6-tabs-empty-visible.json) | throwaway, not merged (`T6`, `F8`) |
| S6 | 2026-09-01 | `951b4393` | empty | script | 645,039,424 | 458,752 | 607,518,720 (30 stores, 10 chains, 9/10 hidden, app) | unmeasured | [json](readings/2026-09-01-951b4393-tabs-empty-visible.json) | `S5`'s control, same session, clean tree (`F8`) |
| S7 | 2026-09-01 | `951b4393` | empty | script | 645,301,568 | 507,904 | 607,518,720 (30 stores, 10 chains, 9/10 hidden, app) | unmeasured | [json](readings/2026-09-01-951b4393-t5-control-tabs-empty-visible.json) | `T5` control, clean tree (`F7`) |
| S8 | 2026-09-01 | `951b4393+T5` | empty | script | 240,764,008 | 32,768 | 607,518,720 (30 stores, 10 chains, 9/10 hidden, app) | unmeasured | [json](readings/2026-09-01-951b4393+T5-tabs-empty-visible.json) | throwaway, not merged: the eager surface clear removed (`F7`) |
| S9 | 2026-09-01 | `471e8c01` | empty | script | 56,902,928 | 475,160 | 607,518,720 mapped, 60,751,872 non-volatile (30 stores, 3 non-volatile, 27 volatile, 10 chains, 9/10 hidden, app) | 4.76 ms (n=12) | [json](readings/2026-09-01-471e8c01-tabs-empty-visible.json) | `T8` commit 2: hidden panes' free buffers volatile (`F9`); reverted in `3c5dfef6` (`D5`) |
| S10 | 2026-09-01 | `8ccdec4d` | empty | script | 56,935,312 | 491,520 | 60,751,872 (3 stores, 1 chain, 9/10 hidden, app) | 4.61 ms (n=12) | [json](readings/2026-09-01-8ccdec4d-tabs-empty-visible.json) | `T8` commit 1 alone, same session as `S9` (`F9`); the shipped shape (`D5`) |
| S11 | 2026-09-01 | `951b4393` | empty | harness | 644,089,152 | 147,480 | unmeasured | unmeasured | [json](readings/2026-09-01-memory-harness-t2b-t9.json) | `T9` pre (`F10`) |
| S12 | 2026-09-01 | `951b4393` | scrollback | harness | 821,396,896 | 1,654,784 | unmeasured | unmeasured | [json](readings/2026-09-01-memory-harness-t2b-t9.json) | `T9` pre (`F10`) |
| S13 | 2026-09-01 | `ed59e1fb` | empty | harness | 279,626,928 | 180,152 | unmeasured | unmeasured | [json](readings/2026-09-01-memory-harness-t2b-t9.json) | `T5` in, `T8` not (`F10`) |
| S14 | 2026-09-01 | `ed59e1fb` | scrollback | harness | 497,861,952 | 3,719,192 | unmeasured | unmeasured | [json](readings/2026-09-01-memory-harness-t2b-t9.json) | `T5` in, `T8` not (`F10`) |
| S15 | 2026-09-01 | `296284d6` | empty | harness | 56,525,712 | 196,632 | 60,751,872 (3 stores, 1 chain, 9/10 hidden, app; `S19`) | 5.39 ms (n=12, `S19`) | [json](readings/2026-09-01-memory-harness-t2b-t9.json) | `T9` post, main checkout (`F10`) |
| S16 | 2026-09-01 | `296284d6` | scrollback | harness | 272,974,880 | 360,472 | unmeasured | unmeasured | [json](readings/2026-09-01-memory-harness-t2b-t9.json) | `T9` post, main checkout (`F10`) |
| S17 | 2026-09-01 | `296284d6` | empty | harness | 56,443,816 | 114,688 | unmeasured | unmeasured | [json](readings/2026-09-01-memory-harness-t2b-t9.json) | `T2b` A/A, worktree twin of `S15` (`F10`) |
| S18 | 2026-09-01 | `296284d6` | scrollback | harness | 273,974,304 | 4,177,920 | unmeasured | unmeasured | [json](readings/2026-09-01-memory-harness-t2b-t9.json) | `T2b` A/A, worktree twin of `S16` (`F10`) |
| S19 | 2026-09-01 | `76920c1c` | empty | script | 57,000,848 | 65,536 | 60,751,872 (3 stores, 1 chain, 9/10 hidden, app) | 5.39 ms (n=12) | [json](readings/2026-09-01-76920c1c-tabs-empty-visible.json) | tier-1 beside the harness pair (`F10`) |
| S20 | 2026-09-01 | `76920c1c` | empty | script | 56,738,728 | 98,304 | 60,751,872 (3 stores, 1 chain, 9/10 hidden, app) | unmeasured | [json](readings/2026-09-01-76920c1c-tabs-empty-visible-repeat.json) | `S19` repeated, same session (`F10`) |
| S21 | 2026-09-01 | `0dc62749` | empty | script | 57,672,616 | 475,136 | 60,751,872 mapped, 20,250,624 resident (3 stores, 1 chain, 9/10 hidden, app; `vmmap`) | unmeasured | [json](readings/2026-09-01-0dc62749-remainder-tabs-empty-visible.json) | `T10` capture slot: the remainder census (`F12`) |
| S22 | 2026-09-01 | `0dc62749` | scrollback | script | 290,694,224 | 98,304 | 60,751,872 (3 stores, 1 chain, 9/10 hidden, app); 58.1M dirty over 5 regions (`vmmap`) | unmeasured | [json](readings/2026-09-01-0dc62749-tabs-scrollback-visible.json) | `T4` capture slot (`F11`); the doc's first scrollback-arm script row |
| S23 | 2026-09-01 | `0dc62749` | empty | script | 57,639,848 | 5,554,176 | 60,751,872 (3 stores, 1 chain, 9/10 hidden, app); 19.4M dirty over 5 regions (`vmmap`) | unmeasured | [json](readings/2026-09-01-0dc62749-tabs-empty-visible.json) | `S22`'s control, same session (`F11`) |

Before the series: termwars' receipt `memory-2026-09-01-140511.json` read
`5f5ecfea` at 644,465,984 (empty) and 818,709,944 (scrollback), n=1. It is
the trigger, recorded as `F1`, and `S1` reproduces it to 0.09%.

`S3` is the first row whose `Surfaces` cell comes from the app rather than
from `vmmap`. Its 607,518,720 bytes are exactly `F4`'s 30-region pane line; the
131,072 bytes between it and `F4`'s 607,649,792 class total are that capture's
one `CoreUI image IOSurface`, which no pane owns and the census does not claim.

`S4` carries the first `Switch` cell. Its total is 787 KB above `S3` and its
surface attribution is identical to the byte, so the difference is session
noise in the non-surface remainder, not an effect of the presentation trace --
which writes nothing at all unless `DANTERM_PRESENTATION_EVENT_LOG` names a
file, and wrote 60 bytes per pane event when it did. The switch reading itself
is `F5`, taken on this same commit in the same session from its own staged
slot.

`S5` and `S6` are the first pair taken in one session on one machine: `S5` is
the `T6` throwaway (a hidden pane's surfaces marked purgeable-volatile, `F8`),
`S6` is the same commit with that diff stashed. Neither is a claim -- `S5`'s
build was reverted and never merged, and both are tier-1 script rows, not the
tier-2 pair `D3` requires. The 546,537,472-byte difference between them is
0.04% under the 27 hidden-pane surfaces `F4` measured, and both rows carry the
identical `Surfaces` cell, because a volatile surface keeps its mapped size and
loses only its resident pages. `S6` inherits `S4`'s `no frame` switch result by
construction, not by measurement, so its `Switch` cell is `unmeasured`.
`S7` and `S8` are `T5`'s pair, taken in one session, control first: the same
commit with and without `TerminalFrameBackingStore`'s eager `memset` of a fresh
IOSurface. `S8` was measured on a working tree, not on a commit, which is what
`+T5` in its `Commit` cell means -- it is a probe of a mechanism, not a claim
for a landed change. Their `Surfaces` cells are identical to the byte because
that census reports mapped `allocationSize` (`D4`); the 404,537,560-byte
difference between the two totals is residency, not mapping. The saving is
idle-only: `F7`'s fault-back table shows a pane paying 39 MB back the moment it
renders three frames.

`S9` and `S10` are `T8`'s own pair, taken in one session on one machine with the
tabs restaged between them: `S9` is the landed branch (commit 1 + commit 2) and
`S10` is commit 1 alone. Both are tier-1 script rows, so neither is the tier-2
claim `D3` requires -- `T9` still owes that -- but they are contemporaneous with
each other, which is what makes the 32,384-byte difference between them
readable: it is 0.06% of either total and inside both spreads, so the volatile
fast path took no bytes that commit 1 had not already taken. Their `Surfaces`
cells differ in kind rather than in size. Commit 1 leaves nine hidden panes with
no rotation at all, so the app attributes three surfaces; commit 2 leaves all
thirty mapped and marks twenty-seven of them volatile, so the mapped figure is
`S3`'s 607,518,720 to the byte and only the non-volatile 60,751,872 follows the
process total. Both arms therefore charge the process for exactly the visible
pane's three buffers, which is what both rows' medians show.

Neither row is comparable to `S5`'s 98,501,952. `T5` is in this branch and was
not in that throwaway, so the visible pane's own two never-rendered buffers cost
nothing here and cost 40 MB there.

`S11` through `S18` are the doc's first tier-2 rows and its first paired
claim (`F10`, `T2b` and `T9`). All eight come out of **one** harness run --
receipt `~/Code/termwars/results/memory-2026-09-01-202939.json`, archived as
this doc's `readings/2026-09-01-memory-harness-t2b-t9.json` -- which built
four checkouts and interleaved their reps, so they share a session, a display,
a scale, a font and a grid by construction rather than by care. Their order in
the table is by revision, not by clock: the run took them round-robin. Every
trial reports one pid, an empty `missingPids` on every one of its samples, and
`170x60` read back on all ten panes. A trial holds 55 to 56 samples -- see
`F10`'s n column -- and those samples are byte-identical in every one of the 24
trials, a 60 s settle leaves nothing moving, so each row's `Spread` is the span
of its three rep medians, which is the only variation the harness saw.

`S15` and `S17` are the same commit built from two different checkouts, which
is what `T2b` asked for: the A/A pair. They differ by 81,896 bytes on the empty
arm and 999,424 on the scrollback arm, and that is the noise floor every other
difference in this table is read against. Read the scrollback floor with the
caveat `F10` discloses: `S18`'s own three rep medians span 4,177,920 bytes,
4.2x that floor, because the writing itself moves the arm while it is sampled.
A scrollback delta is therefore trusted only when it clears the floor by a wide
margin, as the 549x claim does.

`S15` and `S16` carry their `Surfaces` and `Switch` cells from `S19`, not from
the harness -- the harness reads no census and no presentation trace. `S19` was
taken in the same session, minutes later, on `76920c1c`, whose only difference
from `296284d6` is a research script (`F10`); the cells name `S19` so no reader
takes them for a harness measurement.

`S19` and `S20` are the same build read twice by the tier-1 script in one
session. They differ by 262,120 bytes, 0.46%, which is 3.2x the tier-2 A/A
floor in `S15`/`S17` and is the concrete reason `D3` puts a claim at tier 2.
Both sit 0.4% to 0.8% above the tier-2 rows for the same code, which is what a
5 s settle against a 60 s one buys.

`S22` and `S23` are `T4`'s pair, taken in one session on one machine at one
commit: the scrollback arm and its empty control, each held after sampling so
`vmmap` and `footprint` could read the same process the median came from
(`F11`). `S22` is the first script row this doc has on the scrollback arm.
Their `Surfaces` cells are identical from the app, which is the point: both arms
map three surfaces for one visible pane and none for the nine hidden ones. What
differs is residency, and only `vmmap` can say so, which is why both cells carry
a class figure beside the app's. `S23`'s spread is 5,554,176 because its first
three samples were still settling, 63.1 MB down to 57.6 MB; its median is within
1.1% of `S19` and `S20` and the capture was taken after the samples. The pair's
arm delta is 233,054,376, which is 7.7% above `F10`'s tier-2 pair -- a tier-1
attribution reading, with the total still decided at tier 2 (`D1`, `D3`).
