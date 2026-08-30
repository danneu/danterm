# Kitten render benchmark

Research started: 2026-08-28. Research closed: 2026-08-30 -- see
[`## Outcome`](#outcome).

- [findings.md](findings.md) -- the evidence chain. `F1` is the first profile of
  the four in-scope arms; `F2` attributes the per-action memmove; `F3` refutes
  the idle half and corrects how `F1` read `sample`; `F4` and `F5` screen and
  confirm the four decision rules; `F6` is the post-`H1` ladder run and
  re-sample; `F7` is the control run that clears `F6`'s two `slower` verdicts;
  `F8` confirms `H3` and clears its one off-target `slower` verdict the same way;
  `F9` is the `scrollback-stream` re-screen that refuses a rule; `F10` is the
  post-`H3` kitten re-run and re-profile of all four arms; `F11` confirms `H2`
  and records the two shapes the measurement rejected; `F12` confirms `H4` on
  all three cluster shapes and takes the `csi` arm 2.1x; `F13` re-profiles the
  two Unicode arms at HEAD and attributes each to one mechanism (`H8`, `H9`);
  `F14` confirms `H8` and takes the `unicode` arm 1.84x; `F15` confirms `H9` and
  takes `unique_unicode` 1.22x; `F16` re-takes the two-thread reading at HEAD
  in four window states and finds that drawing decides no MB/s; `F17`-`F19`
  confirm `H10` commit by commit and take `unicode` 1.9x; `F20` re-profiles
  `unique_unicode` after `H10` and reads half of its thread as the fixed cost
  of an action, paid four times per cell; `F21` confirms `H11` and takes
  `unique_unicode` 3.2x on the headless feed; `F22` is the closing table --
  paired, interleaved, both terminals frontmost at one `stty`-verified 61x179 --
  and DanTerm leads Ghostty on all six arms.
- [decisions.md](decisions.md) -- the decision log. `D8` is the `H8`/`H9`
  decision: both mechanisms prototyped and priced, wide runs first. `D9` reads
  `F16`, ranks `H10`, `H6` and `H7`, and chooses `H10` with both of its
  prototype shapes priced. `D10` reads `F20`, prototypes three shapes, and
  chooses `H11` -- one action per stretch of printable text -- ahead of `H6`.

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
  the window state (frontmost, occluded, hidden) with every number, for Ghostty
  as much as for DanTerm (`F3`: 28.9 to 86.4 MB/s on one host). An occluded
  DanTerm slot still draws; a hidden one is App-Nap-throttled and is no
  measurement state unless `NSAppSleepDisabled` is set for its bundle id
  (`F16`).
- A frame name says which code is on the stack, not which work disappears when
  the code is rewritten (`37/F4`). Trace the rewrite.
- Every kitten arm exercises the same feed path, so a fix for one arm is
  measured on all four before it is called a win; a win on `ascii` that costs
  `unique_unicode` is a trade-off to record, not a regression to hide.

## Trigger and current evidence

Reproduced 2026-08-28 on an optimized slot (`F1`), kitten 0.48.2, default
repetitions, alt screen:

| Arm | DanTerm (`F1`) | after `H1` (`F6`) | after `H3` (`F10`, frontmost) | after `H2` (`F11`, occluded) | after `H4` (`F12`, occluded) | after `H4` (`F13`, frontmost) | after `H8`/`H9` (`F15`, occluded) | `F16`, frontmost / not drawing | after `H10` (`F19`, `F20`, frontmost) | now: after `H11` (`F21`, frontmost) | Ghostty (user's run) | Ghostty preview (`F10`) | preview / now |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Only ASCII chars | 26.7 MB/s | 103.4 MB/s | 118.7 MB/s | 117.2 MB/s | 118.3 MB/s | 118.4 MB/s | 114.0 MB/s | -- | 116.9 / 117.9 MB/s | 119.2 / 119.4 MB/s | 89.4 MB/s | 86.4 MB/s | 0.72x (DanTerm ahead) |
| Unicode chars | 18.8 MB/s | 30.1 MB/s | 36.2 MB/s | 37.2 MB/s | 37.2 MB/s | 37.1 MB/s | 67.5 MB/s | 65.0 / 67.7 MB/s | 122.1 / 122.2 MB/s | 127.1 / 128.5 MB/s | 112.1 MB/s | 111.4 MB/s | 0.87x (DanTerm ahead) |
| Unique multi-codepoint Unicode cells | 10.7 MB/s | 11.3 MB/s | 12.6 MB/s | 21.4 MB/s | 21.3 MB/s | 21.3 MB/s | 26.2 MB/s | 25.7 / 25.8 MB/s | 26.9 / 26.5 MB/s | 52.6 / 51.7 MB/s | 41.5 MB/s | 45.6 MB/s | 0.87x (DanTerm ahead) |
| CSI codes with few chars | 19.3 MB/s | 19.1 MB/s | 20.7 MB/s | 21.7 MB/s | 46.3 MB/s | 45.1 MB/s | 45.5 MB/s | -- | 45.8 / 46.2 MB/s | 45.2 / 46.5 MB/s | 42.2 MB/s | 41.1 MB/s | 0.90x (DanTerm ahead) |

The `F11` column is the post-`H2` run at 66x179 on an occluded slot; its
`unique_unicode` figure is `D6`'s third confirmation criterion. The `F12`
column is the post-`H4` run at the same geometry and window state, and `F11` is
its control: only `csi` moves, 2.1x, and the other three sit inside their own
run-to-run spread. The `F13` column is the pre-`H8` re-run, frontmost, and
reproduces `F12` on every arm. The `F15` column was taken occluded at the
same geometry after both `D8` commits; `F14` sits between them and read
`unicode` 68.4 with the other arms unmoved. Every arm in `F15`'s run reads a few
points under `F14`, including the two out-of-scope arms the change cannot reach,
so the run carries its own offset and `unique_unicode`'s 1.22x is read against
it. The `F16` column is the same tree on the two open arms only, frontmost and
then hidden with App Nap disabled (the one non-drawing state at full clock);
the two figures agree, which is `H7`'s verdict. The `H10` column is `F19` (all
four arms) with `F20`'s `unique_unicode` re-run beside it. The `now` column is
`F21`, taken frontmost at a `stty`-verified 66x179 on an optimized slot with
the two out-of-scope arms beside it as the run's own control; both sit within a
few points of their last frontmost reading, so the run carries no offset that
would explain `unique_unicode` doubling. All four arms now read above the
Ghostty preview figure. That preview was never a closing table; `F22` is, and
it is in [`## Outcome`](#outcome) below.

The first two DanTerm columns are unpaired and occluded: each was taken on a
slot window that was not frontmost, and neither shares a session with the
Ghostty column. `F10` re-took all four arms in both window states and found no
difference between them, and `F16` shows why: an occluded slot still draws at
about a core, so the two states are the same state, and even the genuinely
non-drawing state reads the same MB/s. Those columns are comparable after all
-- but the Ghostty preview column is still not a closing table: Ghostty gave it 61 rows rather than 66, and the runs are sequential
rather than interleaved. The paired, frontmost, same-geometry comparison is
`F22`, and it agrees with the preview's direction on every arm.

`F1` attributes every arm to `Terminal.feed` on the PTY-host thread, and `F3`
shows that thread at 98% user CPU for the whole run, so the MB/s figures are the
parser's true feed rate. `F1` also read the main thread as idle; that is no
longer true at HEAD, where the draw path costs about as much CPU as the parse on
three arms without yet costing MB/s (`F10`, `H7`). Paired Ghostty runs on this
host (`F3`) put `ascii` at 28.9-86.4 MB/s depending on whether Ghostty was
drawing, so the Ghostty columns above are an upper bound.

`H1`, `H3`, `H2`, `H4`, `H8` and `H9` have all shipped (`D4`, `D5`, `D6`, `D7`,
`D8`); `F10` re-profiled all four arms after `H3`, `F11` re-profiled
`unique_unicode` after `H2`, which took the allocator out of the cluster append
and made that arm 1.7x faster, and `F12` re-ran all four after `H4`, which took
the per-cell print out of REP and made `csi` 2.1x faster. `F13` then re-profiled
the two arms DanTerm still lost and found one mechanism on each: on `unicode`,
about 80% of the thread was the single-cell print's per-scalar tax, paid because
no wide scalar was bulk-printable (`H8`); on `unique_unicode`, 27% of the thread
was the REP memory copied out of the cell after every joined scalar (`H9`). `D8`
decided both, wide runs first, and both shipped: `F14` takes `unicode` 1.84x and
`F15` takes `unique_unicode` 1.22x. What is left on `unicode` is the stream
itself -- `nextAction` is 36% of that thread and the printer decodes the same
bytes a second time (`H10`). Beside it: `H6`, 20% of the `ascii` thread and 5%
of `unicode`; `printBulkNarrow`'s pre-write scan (7% of `ascii`);
`EscapeAbsorber.consume` (13% of `csi`) and the rest of `D7`'s list on that
arm -- a style intern per print, `\e[2K`'s row fill; the `read` syscall (12% of
`ascii`); the join's own guard chain and arena work on `unique_unicode`; and, on
both Unicode arms, `apply`'s own per-action self time and the per-action damage
snapshot and record. `H3`'s memmove is gone from every arm.
`H7` -- the render thread re-typesetting every line every frame -- costs about
a core on three arms and decides no MB/s: `F16` measured both Unicode arms
with the main thread idle and read the same figures. `F13` shows half of it is
font construction and preferred-language lookups per text run, not shaping.
`D9` ranks what is left: `H10` next, priced at -65% on the `unicode` arm and
-7% on `unique_unicode` by prototype; then `H6` in a pattern-fill shape priced
at -15% on `ascii` and -4.7% on `unicode`. `H10` shipped (`F17`-`F19`) and
took `unicode` past the preview. `F20` then re-profiled `unique_unicode`, the
one arm left: four actions per 7-byte cell, and about half the thread is the
fixed cost of an action. `D10` names that `H11`, puts it ahead of `H6`, and it
shipped too (`F21`): -69.77% on the arm, 26.5 -> 52.6 MB/s on kitten, and no
per-fragment print, join or damage frame left under the stretch. What is left
on the arm is the one-cell base stamp's set-up cost and the arena's per-scalar
count and compaction work, neither with a hypothesis and neither owed a
profile, because `F22` closed Phase 4 with the arm ahead of Ghostty.

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

Demoted behind `H11` by `D10`: it lives on `ascii` and `unicode`, which
DanTerm already wins, and `unique_unicode` is the one arm still open.

Mechanism: the rotation `H1` installed recycles the evicted row by calling
`GridRow.resetAsBlank(columns:styleId:)`, which writes `columns` blank cells.
That is one 179-cell fill per line advance, and it is now the per-line residual
that the row copies used to hide. Evidence: 994 of 5546 `ascii` thread samples
(17.9%) on that one call site, and 1094 in `rotateViewportRows` overall, of
which only 55 are the deque operations (`F6`). Competing explanation: the fill
is the deque's own bookkeeping rather than the cell write -- rejected by the
line attribution, which puts 91% of the frame's samples on the `resetAsBlank`
call. `D9` read the release object: the fill is one bounds check and three
stores (8 + 4 + 2 bytes) per 16-byte cell, not a pattern fill, and at HEAD it
is 8.2% of the headless `unicode` thread (16% once `H10`'s prototype is
applied). Distinguishing experiment, run as `D9`'s cheap shape: fill the row as
one 16-byte pattern (`memset_pattern16`; `GridCell` is 14 bytes at stride 16
with no reference field), which read `kitten-feed-ascii` `faster` at -15.13%
and `kitten-feed-unicode` `faster` at -4.67% on `quick`. The ideal -- a row that
is blank by state and grows cells as they are written -- is recorded in `D9`
and not chosen: on these arms every scrolled-in row is written on the next
line, so the cells are materialized anyway, and it costs every direct cell read
tolerating a short row. Second task after `H10` (`D9`). Confirmed if the
per-cell store loop leaves `resetAsBlank` and the `ascii` arm moves.

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
`F13` reads inside the chain on both Unicode arms: `drawTextRuns` is 96-99% of
the main thread and `CTLineCreateWithAttributedString` 74-81%, and under the
glyph encoder about half is not shaping at all -- `CTFontCreateCopyWithAttributes`
-> `TFont::TFont` constructs a font object per text run (23% of the main
thread), and `TFont::SetExtras` / `ShapesAnyPreferredLanguage` ask
`CFLocaleCopyPreferredLanguages` for the preferred languages per text run
(about 35% together). Actual glyph drawing is 6-7%. So a shaped-line cache
removes all of it, and a per-frame font cache or a pre-resolved language
attribute removes the half that is not shaping.
Competing explanation: the cost is the frame cadence `--render` forces rather
than the typesetting, so a real workload drawing fewer frames would not pay it
-- the CPU share alone cannot tell those apart. Distinguishing experiment: cache
the shaped line or the glyph run across frames and re-measure the same profile;
or make the feed thread fast enough that the draw thread becomes the serial
constraint and watch MB/s. The second experiment has now run twice without
being aimed at it (`H8`, `H9`), and `F16` took the reading: with the main
thread at 0.6-1.0% (hidden, App Nap disabled) the arms read `unicode` 67.7 /
67.6 and `unique_unicode` 25.8 MB/s against 65.0 / 64.4 and 25.7 frontmost
with the main thread at 88-100% of a core, and the feed thread holds no wait
frame in any state. So this hypothesis decides no MB/s at HEAD, and `D9`
defers it. It re-enters when a non-drawing run reads faster than a frontmost
one, which is the reading to repeat after `H10` ships. Two rules `F16` adds:
an occluded slot is a drawing state (88-100% of a core), and a hidden app is
App-Nap-throttled 3-6x and is no measurement state without
`NSAppSleepDisabled`. It also maps to no ladder arm -- every `kitten-feed-*`
arm is headless -- so it cannot be gated the way the others are, and a decision
on it needs a measurement route first.

### H8 -- No wide scalar is bulk-printable, so `unicode` prints one cell per action -- CONFIRMED and fixed

Confirmed by `F14` and shipped as `D8` (commit `1c74156b`). The mechanism below
is the one the fix removed; it is kept for the record. All three criteria hold:
the paired frame table holds no `print`, `printWide` or
`appendToOpenClusterIfJoined` frame under `printBulkWide`, and the per-cell
`printWide` stacks that remain are the one pair per row the right margin leaves
no room for, which the segment declines by design; `kitten-feed-unicode` reads
`faster` at -64.65% on `confirm` with no other arm `slower`; and the kitten arm
moves 37.1 -> 68.4 MB/s. The run action carries its width rather than the
printer re-deriving it; `D8`'s Settled note says why.

Mechanism: `TerminalInputStream.nextAction` yields a `printScalarRun` only
while each scalar `isBulkPrintable`, and that predicate requires
`cellWidth == .narrow`. A CJK character ends the probe every time, so the
stream returns one `print` action per character and each pays the per-action
work (dispatch, damage snapshot, damage record), a second classification in
`print`, the whole cluster-join guard chain, and `printWide`'s per-cell work:
two inspection invalidations, a two-column destination prepare with both
neighbour probes, one identity, two copy-on-write-checked stores, a fresh
cluster context, and a REP-memory read-back. Evidence (`F13`): buckets (a),
(b), (d) and (g) -- decode and classify 24%, cell placement 22%, per-print
damage and inspection 18%, `apply`'s own self time 13% -- about 80% of the
thread, and the line attribution puts the probe's decoder step, the two
`printWide` stores, `invalidateInspection`'s epilogue and the damage snapshot
among the top lines. Competing explanation: four independent costs that each
need a fix -- rejected by the prototype, which moved the arm -62.40% with one
change. Distinguishing experiment: make bulk eligibility width-agnostic, cut
the run at a width change, and stamp wide pairs per segment; confirmed if the
per-cell `print`, `printWide` and `appendToOpenClusterIfJoined` frames leave
the CJK path and the arm moves. The prototype ran (`D8`): `kitten-feed-unicode`
`faster` at -62.40% quick, `unique-unicode` `equivalent`, and the candidate's
profile holds `printBulkWide` at 27% with the per-cell frames gone; what is
left is the stream's decode and classification (about a third), the pair
stamp, `H6`, and a second decode in `printScalarRun`.

### H9 -- The REP memory is copied out of the cell after every joined scalar -- CONFIRMED and fixed

Confirmed by `F15` and shipped as `D8` (commit `fa657d53`). The mechanism below
is the one the fix removed; it is kept for the record. All three criteria hold:
`copyScalars(of:into:)` and the whole of the arm's retain/release are gone from
the tree, and every surviving `rememberOpenCluster` sample sits under a bulk
writer or a fresh-cell print, none under the join; `kitten-feed-unique-unicode`
reads `faster` at -21.55% on `confirm` with no other arm `slower`, including
`retained-browse`; and the kitten arm moves 21.4 -> 26.2 MB/s. The mirror claim
converges instead of recording provenance, which is not the shape `D8` wrote;
its Settled note says why, and records the one equality caveat that leaves.

Mechanism: `print` calls `rememberOpenCluster` after every scalar, on the join
path as well as the fresh-cell path; it reads the target cell back through the
row and `copyScalars(of:into:)` copies the whole cluster into
`lastPrintedCluster` again -- 1 + 2 + 3 + 4 scalars over a four-scalar cell --
into a heap buffer swapped out of `self` and back, retained and released
around the swap, and grown by `replaceSubrange`. This is the unaliased form
`D6` shipped so the arena could grow in place. Evidence (`F13`):
`rememberOpenCluster` 26.7% of the `unique_unicode` thread, `copyScalars`
11.9%, `replaceSubrange` 5.3%, retain/release 8.4% all under it, and the copy
loop at `Terminal.swift:443` the top line on the arm. Competing explanation:
the cost is the swap or the row read rather than the copy -- rejected by the
line attribution and by the leaf parents. Distinguishing experiment: extend
the memory by the scalar that joined instead of re-reading the cell; confirmed
if `copyScalars` and the retain/release pair leave the join path and the arm
moves. The prototype ran (`D8`): `kitten-feed-unique-unicode` `faster` at
-21.84% quick, `unicode` `equivalent`.

### H10 -- The bytes of a scalar run are decoded twice: once to classify, once to print

Mechanism: `TerminalInputStream.nextAction` probes a run with its own decoder
copy (`TerminalInputStream.swift:107-140`), decoding every byte of the run
(`:112`) and classifying every scalar (`:128`) to decide how far the run
reaches, and then returns only the byte range and the run's width (`:144`). The
printer starts from the bytes again: `Terminal.printScalarRun`
(`Terminal.swift:8044`) walks the range once counting UTF-8 lead bytes to size a
segment (`:8055-8060`), then hands each writer a supplier that decodes the same
bytes a second time with a fresh `UTF8Decoder` (`:8062-8079`). So a CJK
character's three bytes are decoded twice and traversed a third time, and the
run action -- which exists to amortize per-scalar work -- carries none of what
the probe already learned except the width. Evidence (`F14`): with the per-cell
frames gone, `nextAction` is 36.13% of the `unicode` thread against 17.59%
before, the largest single item on the arm, and `apply` is 62.36%; on `D8`'s
prototype sample of the same stimulus `printScalarRun`'s own self time is 7.6%,
which is the re-scan and the second decode, with `printBulkWide` at 25% beside
it. `F15` reads `nextAction` at 18.39% of `unique_unicode` for the same reason.
Competing explanation: the share is the classification table read rather than
the decode, in which case removing the printer's second decode buys the 7.6%
and nothing more, and the probe is simply what a stream costs. Distinguishing
experiment: carry the run's scalar count in the action so the printer stops
re-scanning, and give the printer the probe's decoder state rather than a fresh
one, without changing what the probe does; confirmed if `printScalarRun`'s self
time leaves the profile and `kitten-feed-unicode` reads `faster`. If it moves
and `nextAction`'s share does not fall, the decode was the cost and the
classification is a separate item; if neither moves, this hypothesis is refuted
and the stream's cost is the probe. `D8` named the second decode a non-goal on
the grounds that it was small, and rejected the shape that removes it by
yielding decoded scalars -- an array per action, which `research/33/F9` sized at
60-80x the corpus. Neither of those settles the shape above, which allocates
nothing.

The experiment ran (`D9`), in two steps on the headless `unicode` feed. The
count in the action plus a stateless lead-byte decode in the printer read
`kitten-feed-unicode` `faster` at -35.63%, and the profile put the printer's
second decode at about a fifth of the thread: `printBulkWide`'s stamp line fell
from 24.9% to 4.7% self. A one-step decode of each complete well-formed
sequence in the probe, with the resumable decoder kept for the chunk tail, then
read -65.28% on `unicode` and -7.34% on `unique_unicode`, `ascii` inconclusive
at -1.25% and `csi` equivalent. So both halves of the competing explanation
fall: the decode is the cost, in the printer and in the probe alike, and the
classification is the smaller item beside it. **The next task** (`D9`): the
stream decodes each scalar once, in one step, classifies it once, and the
action carries the count and, through a feed-scoped scratch, the scalars; the
`.print` action carries its classification so the single-scalar print does not
look it up again. Confirmed when no decoder frame remains under the printer,
the resumable decoder appears under `nextAction` only on the generic path, and
both Unicode arms move.

### H11 -- `unique_unicode` pays the fixed cost of an action four times per cell -- CONFIRMED and fixed

Mechanism: a cell of the stimulus is `a` plus three combining marks (`D1`).
The stream yields the `a` as a one-byte `printASCIIRun` and each mark as its
own `.print`, because a mark is not bulk-printable and ends the run probe on
its first scalar. Each of the four actions pays `apply`'s dispatch, prologue
and stack probe, the damage snapshot and diff, the action's destroy, and
`nextAction`'s per-call entry; each mark's join then repeats the cluster
validation, the row and cell reads, the inspection invalidation and the
context write-back that are invariant across the three marks of one cluster;
and the `a` pays the bulk-narrow writer's whole set-up for a run of one cell.
Evidence (`F20`): buckets (d) + (g), the per-action damage and dispatch, are
40% of the PTY-host thread and `nextAction`'s self time another 12%; the join
is 27%, of which under 10 points are per-scalar by nature; the one-cell base
stamp is 12%. `apply` self 16.8% and `___chkstk_darwin` 3.2% are the top two
self frames; `xctrace` agrees. Competing explanation: the cost is the join's
arena and break work rather than the action count -- rejected by `D10`'s
first prototype, which changes nothing in the join and moves the arm -26.71%
by merging three actions into one. Distinguishing experiment: yield one action
per stretch of printable text and segment it in the printer, so the per-action
work runs once per stretch and the join once per run of joiners; confirmed if
the per-scalar `print` and join frames leave the stretch, the damage snapshot
appears at stretch frequency, and the arm moves. The experiment ran (`D10`),
in three steps: a joiner-run action alone reads -26.71%; with the hoisted
segment join -47.25%; the full stretch -78.75%, with `unique_unicode` at 57.5
MB/s on kitten, past the Ghostty preview -- and `unicode` +3.08% and `ascii`
+1.74% `slower` on the same prototype, which the task must clear.
Shipped as `d296901f` and `298f49d2`, and confirmed by `F21`:
`kitten-feed-unique-unicode` -69.77% on `confirm` against `b88c71a9` with no
arm `slower`, the kitten arm 26.5 -> 52.6 MB/s frontmost at 179x66, and the
per-fragment print, the per-fragment join, the one-cell base action and the
per-action damage diff all gone from the frame table. The two `slower` cells
the prototype carried were cleared inside the change; see `D10`'s Settled note.

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

`D9` decides between the three items `D8` left open: `H10` first, `H6` next in
its cheap shape, and `H7` deferred on `F16`. `H10` is done (`F19`); `D10`
then read `F20`, put `H11` ahead of `H6`, and `H11` is done too (`F21`). Every
arm this doc opened on now leads Ghostty in the paired table (`F22`), so
nothing left unchecked in this phase has a user-observable claim behind it.

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
- [x] `D5`'s tooling gate: fail `just test-tooling` when a
  `MemoryLayout<Terminal>.size`-byte `memcpy` reappears in a feed-path function
  of the release object. Shipped as `scripts/terminal-self-copy-gate.py`: the
  length comes from a release `MemoryLayout` probe in the same build (1521 size,
  1528 stride today), the scope is the named unconditional feed-path functions,
  and the injected control -- the damage snapshot back on an `@inline(never)`
  `scrollProjection` -- fails it at both sites `D5` removed. `D5`'s Settled note
  has the shape and why it is a list rather than a reachability walk. DONE
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
- [x] `H8` wide runs through the stream, then `H9` the printer-maintained
  REP memory. Decided as `D8` on `F13`, one plan and two commits, wide runs
  first:
  [plans/impl/2026-08-29-1635-wide-runs-and-rep-memory.md](../../../plans/impl/2026-08-29-1635-wide-runs-and-rep-memory.md).
  `H8` shipped as `1c74156b` and is confirmed by `F14`: `kitten-feed-unicode`
  -62.44% quick and -64.65% confirm, no other arm `slower`, the kitten `unicode`
  arm 37.1 -> 68.4 MB/s, and no per-cell print frame under `printBulkWide`.
  `H9` shipped as `fa657d53` and is confirmed by `F15`:
  `kitten-feed-unique-unicode` -22.72% quick and -21.55% confirm,
  `retained-browse` equivalent, the kitten arm 21.4 -> 26.2 MB/s, and the
  cluster copy with all of the arm's retain/release gone from the tree. The
  action carries its width and the mirror claim converges rather than recording
  provenance; see `D8`'s Settled note. DONE
- [x] `H10` the second decode: the stream decodes a run to classify it and
  `printScalarRun` decodes the same bytes again, after re-scanning them to size
  a segment. It was the largest single item on `unicode` at `F14`
  (`nextAction` 36% of the thread) and 18% of `unique_unicode` at `F15`.
  Decided as `D9`: the stream decodes each scalar once in one step, classifies
  it once, and hands the printer the count and the scalars; prototyped at
  -65.28% on `kitten-feed-unicode` and -7.34% on `kitten-feed-unique-unicode`
  with `ascii` and `csi` unmoved. Plan:
  [plans/impl/2026-08-29-1934-h10-decode-once.md](../../../plans/impl/2026-08-29-1934-h10-decode-once.md).
  Shipped as `52951595`, `d1470b52` and the scratch commit, and confirmed by
  `F17`, `F18` and `F19`: `kitten-feed-unicode` -63.10% and
  `kitten-feed-unique-unicode` -2.11% on `confirm` against the pre-change
  revision, no arm `slower`, the kitten `unicode` arm 64.7 -> 122.2 MB/s at
  `F16`'s unchanged delivery term, and the printer's one remaining decode frame
  gone from its subtree. DONE
- [ ] `H6` the per-line blank fill the rotation left behind (20% of the `ascii`
  thread, 5% of `unicode` at `F13`, 16% of the post-`H10` prototype's
  `unicode` thread; 15.4% of it at `F19`, now that `H10` halved the thread
  around it). In the pattern-fill shape
  `D9` priced at -15.13% on `kitten-feed-ascii` and -4.67% on
  `kitten-feed-unicode`; the blank-by-state ideal is recorded there and not
  chosen. Gate on `kitten-feed-ascii` and `kitten-feed-unicode`, with the
  other two arms beside them; needs its own plan, so it and `H11` do not land
  on the same cells without a control between them (`D4`). Demoted behind
  `H11` by `D10`: both of its arms are already ahead of the preview. TODO
- [x] `H11` one action per stretch of printable text, with the join run once
  per segment of joiners. Decided as `D10` on `F20`, one plan and two commits:
  [plans/impl/2026-08-30-0146-h11-text-stretch-action.md](../../../plans/impl/2026-08-30-0146-h11-text-stretch-action.md).
  Shipped as `d296901f` (the stretch action) and `298f49d2` (the segment join),
  and confirmed by `F21`: `kitten-feed-unique-unicode` -68.70% quick and
  -69.77% confirm against `b88c71a9`, no arm `slower` -- `unicode` -6.04%,
  `ascii` -3.00%, `csi` -0.30% -- `retained-browse` equivalent, the kitten arm
  26.5 -> 52.6 MB/s frontmost at 179x66, and no per-fragment print, join,
  one-cell base action or per-action damage frame left under the stretch. The
  prototype's two `slower` cells were cleared inside the change by an
  ASCII-prefix scan and a single scratch allocation, and the printer classifies
  one scalar per mark rather than none; see `D10`'s Settled note. DONE
- [ ] The one-cell base stamp's own set-up cost and the arena's per-scalar
  count, threshold and compaction work -- what `H11` leaves on
  `unique_unicode`, ranked fourth by `D10` and named as a follow-up by `H11`'s
  plan. Neither has a hypothesis, and neither gets one without a profile of
  the post-`H11` tree. Take that profile **only if Phase 4 shows a gap on
  `unique_unicode`**: the arm now reads above the Ghostty preview, so there is
  no user-observable claim behind either mechanism today. The gate resolved to
  no: `F22` reads the arm 52.4 against Ghostty's 45.0 at a shared 61x179, so
  the profile is not owed and neither mechanism is opened. NOT TAKEN
- [ ] `H1` partial-region scroll: move row handles, not `GridRow` values. TODO
- [ ] `H7` the render thread's per-frame CoreText typesetting. About a core on
  three arms and no MB/s: `F16` re-took the two-thread reading at HEAD in four
  window states and read the same figures with the main thread idle as with it
  drawing, with no wait frame on the feed thread. Deferred by `D9`. Re-take the
  same reading after `H10` ships; it re-enters only when the non-drawing run
  reads faster than the frontmost one. It maps to no ladder arm. DEFERRED
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
  `ascii`), `EscapeAbsorber.consume` (13% of `csi`), the `read` syscall (12% of
  `ascii`), and on both Unicode arms `apply`'s own per-action self time (about
  12%, `F13` bucket (g)) with the per-action damage snapshot and
  `recordDamage(from:to:)` beside it. `printWide`'s cell stores and the
  per-print damage and inspection pair on `unicode` went to `H8` and are gone;
  the same pair on `unique_unicode` (14%, `F13` bucket (d)) stays here, as do
  the join's guard chain, `shouldBreak` and `appendScalar`'s arena work, which
  `F15` reads as that arm's top items now that the rebuild is gone. `F20`
  gives the per-action items and the join's invariant half to `H11`; the
  one-cell base stamp and the arena's per-scalar count, threshold and
  compaction work have their own entry above, gated on Phase 4.
  `F10`, `F13`, `F15`, `F20`. RESEARCH
- [ ] Delivery: the per-turn `Array(UnsafeBufferPointer)` copy in
  `takeOutputTurn` (3-4%) and the `read` handoff. `F16` sizes it from the
  outside: `unicode`'s feed thread is 12-16% idle in `read` in every window
  state and its kitten figure is 80% of the headless feed rate (`ascii` 74%,
  `unique_unicode` 92%), so once `H10` lands the tty handoff (`F3`) is what
  caps the `unicode` figure. No hypothesis names the mechanism yet; it needs
  a profile of the read turn, not the parse. Only after `H10`. RESEARCH

### Phase 4 -- close

- [x] Re-run all six kitten arms (the two out-of-scope ones as a regression
  check) against Ghostty on the same host, same session, and record the table
  in `## Outcome`. Every fix this doc opened has shipped, and the paired table
  is the only claim left that the preview cannot carry -- it must be
  same-geometry and interleaved, and it must record each window's state (`F3`).
  Taken as `F22`: 24 runs, interleaved DanTerm/Ghostty per arm, both terminals
  frontmost and sampled once a second for the whole run with no violation, at a
  61x179 grid `stty size` reported inside both. DanTerm leads on all six arms.
  DONE

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
- RESOLVED by `F22`. Neither Ghostty column in the trigger table is a closing
  table. The first is the user's run, on another host and session. The second
  is `F10`'s preview: frontmost on this host and session, but Ghostty gave it
  61 rows against DanTerm's 66, and the two terminals ran sequentially rather
  than interleaved. `F22` is the paired, same-geometry, interleaved table with
  each window's state recorded, and it keeps the preview's direction on all six
  arms. One caveat survives it and is restated below: the two terminals do not
  share a font.
- Neither terminal in `F22` runs the user's own configuration, and the two do
  not share a font. Ghostty read `~/.config/ghostty/config`, which sets only
  `command` and `scrollbar`, so it drew at its own default font and size; the
  DanTerm slot ran on launcher defaults, which are not the user's config
  either. The grid is matched and the stimulus is identical, so the feed rate
  is comparable, but the per-cell draw cost is not matched. `F16` shows drawing
  decides no MB/s on DanTerm; nothing establishes that for Ghostty, whose
  renderer thread runs at 86% during the `unicode` arm (`F22`).
- Ghostty cannot be made to give 66 rows on this display at its default font
  size: `--window-height=200` reports the same `61 179` as
  `--window-height=66` (`F22`). So `F22` pins DanTerm down to 61 rows rather
  than lifting Ghostty to 66, and its DanTerm figures are a couple of points
  under the 66-row figures in the trigger table.
- kitten's writer spins on `EAGAIN` against a 2048-byte kernel high-water
  mark (`F3`), so its process burns a core in the kernel under any terminal.
  It is not DanTerm's cost, and a headless replay will not reproduce it.
- The pane geometry for `F1` was the slot's default window, not the canonical
  179x66; scroll cost per line scales with the row count, so the ASCII share
  is geometry-dependent. `F6`'s re-sample used 66 rows x 179 columns.
- Every DanTerm kitten figure before `F10` (`F1`, `F3`, `F6`) was taken on a
  slot window that was not frontmost. `F10` took all six arms in both states
  and found every pair inside its own run-to-run spread, and `F16` shows both
  states draw, so those figures compare cleanly to a frontmost one. `F22` pairs
  frontmost anyway, because the Ghostty side of the comparison is not
  state-independent (`F3`: 28.9 to 86.4 MB/s on one arm), and it verifies the
  state once a second inside every run rather than only before and after.
- `--render` **does** put drawing on the profile at HEAD, which reverses what
  `F1` and `F3` recorded. `F10` measures the main thread at about 1.0 core on
  `unicode` and `unique_unicode`, 0.6 on `csi` and 0.24 on `ascii`, beside a
  PTY-host thread at about 1.0 core, all of it CoreText and CoreGraphics work.
  It does not change the MB/s ranking -- `F16` reads the same figures with the
  main thread idle -- and it is `H7`, deferred.
- `H7`'s reading was re-taken at HEAD (`F16`) and the draw thread does not
  bind: the figures are the same with the main thread idle. Two window-state
  rules come with it. "Occluded" in this doc has always been a drawing state
  at HEAD (the main thread at 88-100% of a core behind another window), so
  every figure in the trigger table was taken drawing and they compare. A
  hidden or minimized app is App-Nap-throttled 3-6x with its main thread idle
  and its child kitten throttled with it; the only non-drawing state at full
  clock is hidden with `NSAppSleepDisabled` set for the slot's bundle id, and
  no kitten figure is taken hidden without it.

## Outcome

Closed 2026-08-30. The trigger was a 2.2x to 6.0x loss to Ghostty on the four
kitten arms that print text. DanTerm now leads Ghostty on all six arms, paired
on one host and session, interleaved run by run, both terminals frontmost and
drawing, at a 61x179 grid `stty size` reported inside both. `F22` is the
measurement; DanTerm `d5514a4f` on an optimized slot, Ghostty 1.3.1, kitten
0.48.2, `--render`, alternate screen, default repetitions.

| Arm | DanTerm r1 | DanTerm r2 | Ghostty r1 | Ghostty r2 | Ghostty / DanTerm | trigger (`F1`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Only ASCII chars | 116.6 | 117.0 | 82.9 | 86.6 | 0.73x | 3.3x behind |
| Unicode chars | 125.3 | 125.1 | 105.9 | 105.0 | 0.84x | 6.0x behind |
| Unique multi-codepoint Unicode cells | 52.4 | 52.4 | 44.9 | 45.0 | 0.86x | 3.9x behind |
| CSI codes with few chars | 44.6 | 46.2 | 40.8 | 40.5 | 0.90x | 2.2x behind |
| Long escape codes | 169.3 | 168.7 | 72.1 | 72.2 | 0.43x | out of scope |
| Images | 193.9 | 192.0 | 53.5 | 53.6 | 0.28x | out of scope |

MB/s. Below 1.00 means DanTerm is ahead. Per arm: `ascii` went from 3.3x
behind to 1.38x ahead, `unicode` from 6.0x behind to 1.19x ahead,
`unique_unicode` from 3.9x behind to 1.17x ahead, and `csi` from 2.2x behind
to 1.12x ahead. DanTerm's own figures moved 4.4x, 6.7x, 4.9x and 2.4x on those
four arms; Ghostty did not get slower. The two out-of-scope arms are the
regression check and are unchanged: `long_escape_codes` 2.34x ahead and
`images` 3.60x ahead, both within a few points of their last reading, so
nothing was traded away to win the other four.

Beside the MB/s, both terminals spend about two cores and kitten spends one
against each (`F22`): DanTerm 2.00 process cores with its main thread drawing
at 100% and the parse on a dispatch workloop, Ghostty 1.82 with an idle main
thread and two workers at 95% and 86%.

Eight fixes carry the four arms, each gated on a frozen ladder arm before it
shipped: `H1` the alt-screen row copies (`D4`), `H3` the per-action `Terminal`
copy (`D5`), `H2` the per-scalar cluster allocation (`D6`), `H4` bulk REP
(`D7`), `H8`/`H9` wide runs and the printer-maintained REP memory (`D8`),
`H10` decoding each scalar once (`D9`), and `H11` one action per stretch of
printable text (`D10`). The tooling half of the research shipped with them:
four calibrated `kitten-feed-*` workloads with frozen decision rules (`D2`),
so any future change to these paths is decided the same way every other
performance change is, and `D5`'s guard, which fails `just test-tooling` when a
whole-`Terminal` copy returns to a feed-path function of the release object.

The remaining unchecked lines in the Phase 3 ledger are outside this closing
claim: `H6` is demoted, `H7` is
deferred on `F16`, the `unique_unicode` follow-up is not taken because its
Phase 4 gate resolved to no, and the rest are unattributed cost carried so it
is not lost. None of them has a user-observable claim behind it today.
