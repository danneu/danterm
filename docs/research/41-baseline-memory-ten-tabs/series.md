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

`Spread` is max minus min across one row's samples: how flat the process was
while sampled, not session noise. `Surfaces` is `T1`'s attributed surface
bytes with the count it sums. From `danterm surfaces` it reads
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
