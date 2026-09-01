# Baseline memory with ten tabs open

Research started: 2026-09-01.
Continues: [15-memory-footprint.md](../15-memory-footprint.md) (`15/F1`,
`15/F17`) and
[33-by-construction-perf-survey/README.md](../33-by-construction-perf-survey/README.md)
(`33/D7`, the `T25` owned pane surface and its accepted per-pane surface cost).

- [findings.md](findings.md) -- the append-only evidence chain. `F1` is the
  termwars receipt this doc opened on, beside the other three terminals. `F2`
  is the code-read that attributes most of the empty-tab baseline to pane
  swapchains, arithmetically; `F4` confirms that attribution by allocation
  class.
- [decisions.md](decisions.md) -- the decision log. `D1` is the standing rule
  for what counts as evidence here; `D2` is the closed direction gate; `D3`
  fixes the instrument.
- [series.md](series.md) -- every footprint reading, in order, one row each.
  This is the record of progress over time; a finding may interpret a row,
  but the numbers live here.
- [readings/](readings/) -- the raw JSON behind each series row, named
  `<date>-<commit>-<arm>.json`, beside the per-class captures taken on a held
  slot, named `<date>-<commit>-<tool>.txt`.

## Purpose

This doc owns **what the DanTerm process holds when a user has many tabs open
and is doing nothing**, and how to hold less of it without giving up a
correctness property the app already paid for. The working shape is termwars's
memory chart: ten tabs, one visible window, a matched grid, empty scrollback in
one arm and a filled 10,000-line scrollback in the other.

Doc 15 owned resident bytes of *terminal state* and shipped the 32-byte cell.
It noted at `15/F1` that only about a quarter of the app's footprint was the
malloc heap and left the rest -- presentation, AppKit, fonts, engines -- to a
later goal. Doc 33's `T25` then moved the pane's pixels into app-owned
IOSurfaces and accepted two to three grid-sized surfaces per displayed pane as
a risk. This doc is where those two threads meet: the process-level number a
user sees in Activity Monitor, decomposed by allocation class, with each class
carrying its own hypothesis, experiment, and verdict.

It is a sandbox on purpose. Ideas land in the ledger as `TODO`, get a
falsification gate, and either graduate to a plan or stay here as `REJECTED`
with the reason. Nothing in it is a decision until `decisions.md` says so.

## Investigation rules

- **The deciding quantity is `phys_footprint` of the whole process**, read the
  way termwars reads it (`footprint`, every pid under the bundle, median over a
  sampled window after a settle). That is the number the user and the chart
  see. Per-class attribution (`vmmap --summary`, in-app counters) explains a
  change; it never substitutes for the total.
- **Every aggregate carries its count.** A surface-bytes figure names how many
  surfaces it sums; a per-tab figure names the tab count. Zero must be
  distinguishable from "not measured"
  ([measurement-discipline](../../../agent-docs/measurement-discipline.md)).
- **Compare contemporaneously.** A before/after runs both revisions in the same
  session on the same display, scale, font, and grid. The archived receipt in
  `F1` is a trigger, not a control.
- **Idle is a state, not an assumption.** The empty arm measures panes that
  presented once and then sat. A saving that only exists because a buffer was
  never written is real in that arm and gone after three frames of output;
  record which of the two a result is, and price both when they differ.
- **A memory win may not spend a correctness property.** The depth-3 swapchain
  rule exists because a depth-2 chain wedged
  (`TerminalFrameSwapchain.swift`, `defaultDepth`). A change that shrinks
  memory by weakening that rule is a presentation redesign and needs its own
  proof, not a constant edit.
- **A memory win is also a latency claim.** Anything that makes a hidden pane
  cheaper makes revealing it dearer. Tab-switch latency for a warm and a cold
  tab is measured before and after, and a regression there is reported beside
  the bytes, not netted against them.
- **Terminal state and presentation state are separate lines.** A hypothesis
  says which it targets. The scrollback arm's delta over the empty arm is the
  terminal-state line; the empty arm is almost entirely the other.

## How the number is measured

Two tiers, for two questions. Both read the same quantity through the same
code (`termwars.sample` over `procs.bundle_pids` of one staged slot bundle),
so a tier-1 reading and a tier-2 median are the same number at different
rigor. `D3` fixes this; change it there, not here.

**Tier 1 -- the spot reading, for the edit loop.** Answers "did the mechanism
move" while a change is being made. No receipt, no chart, no claim.

    python3 scripts/research/41/ten-tab-footprint.py [--arm tabs-scrollback-visible] [--hold]

The script borrows termwars' DanTerm adapter for staging, so the slot is
seeded with Menlo 13, opened to ten inert tabs, sized to the calibrated
1565x999 window, and every pane is read back at 170x60 before a sample is
taken; a grid mismatch fails the reading instead of shrinking it. Then a 5 s
settle and ten `footprint` samples at 1 s over the slot bundle's pid set. It
prints one JSON document (commit, dirty flag, achieved grids, every sample,
median, spread, pid count) and stops the slot. Save the document under
`readings/` and add a row to `series.md`. It takes focus for a moment while it
sizes the window, which is why it is not a gate test. `T1`'s attribution
counter is added to the document once it exists. `--hold` prints the document early, with the measured
pids, and keeps the slot up until stdin gives a line or SIGINT arrives; that is
how a per-class capture (`vmmap`, `footprint`) is taken against the same
process the samples came from, as `F4` did. The document also carries a
`surfaces` block, read with `danterm surfaces` from the sampled process before
the slot stops, so every tier-1 reading arrives with the app's own attribution
beside its total.

**Tier 2 -- the series row, for a claim.** termwars' memory harness, DanTerm
only, both arms:

    cd ~/Code/termwars && just memory --terminals danterm

Ten tabs, 170x60 read back on every tab through the adapter's calibrated
window geometry, Menlo 13 seeded, 2x display, settle, sampled window, three
interleaved reps. It opens real windows and takes focus, so a human picks the
moment. A claim is two harness rows in `series.md`, the pre-change commit
and the change, each staged into its own optimized slot and run in one
session. The first such pair is A/A, HEAD against HEAD, so the series carries
its own noise floor before any delta is read against it.

**The latency reading, for the other half of the trade.** A memory win here is
also a latency claim (see the investigation rules), so the same staging carries
a second instrument:

    python3 scripts/research/41/tab-switch-latency.py [--samples 12]

It stages the tier-1 slot with `DANTERM_PRESENTATION_EVENT_LOG` set, which
makes every pane append one JSON line per presentation moment -- `create`,
`reveal`, `hide`, `rebuild`, `attach` -- with a monotonic timestamp
(`app/TerminalPresentationEventSampler.swift`). The script drives the three
switches a user can make plus one that prices a rebuilt swapchain, pairs the
events per pane, and prints one JSON document with every sample and a bound on
its own write cost. The launcher forwards the variable through its
`--pass-env` allowlist; the script adds the flag with a shim because termwars'
adapter takes no launch variables of its own. Nothing is written and nothing is
paid when the variable is unset. The first reading is `F5`, and the median it
produces is the `Switch` cell of a series row.

**The write rule.** Every reading becomes a row, whichever tier took it. A
commit that claims a memory effect cites its harness rows (`41/S3`, `41/S4`),
taken from the committed revision, not the working tree that produced it. A
memory change with no rows has made no claim. The ledger task that produced
the change closes by pointing at the rows.

## Trigger and current evidence

termwars's memory run of 2026-09-01 (`F1`) measured DanTerm 0.1.25 at
`5f5ecfea` in an isolated optimized slot, ten 170x60 tabs, Menlo 13, 2x
display:

| Arm | DanTerm | kitty | Ghostty | iTerm2 |
|---|---:|---:|---:|---:|
| tabs-empty-visible | 644 MB | 253 MB | 792 MB | 197 MB |
| tabs-scrollback-visible | 819 MB | 827 MB | 944 MB | 525 MB |

Two facts fall out. The empty baseline is 2.5x kitty's and 3.3x iTerm2's, with
no terminal history in play. And the scrollback arm adds only 174 MB over it,
which is the terminal-state line doc 15 already optimized. The empty baseline
is where the bytes are.

`F2` attributes that baseline by arithmetic: every pane that has ever
presented owns a depth-3 swapchain of full-grid BGRA IOSurfaces, and each
surface is cleared on creation so all of it is resident. At this geometry that
is 20.2 MB per surface, 60.7 MB per pane, 607 MB for ten -- 94% of the measured
total. Hidden tabs keep theirs. The remaining 37 MB holds the app, ten
terminal engines, ten live grids, PTYs, fonts, caches, and allocator overhead.

## Current hypotheses

### H1 -- hidden panes' swapchains are the baseline -- CONFIRMED (`F4`)

`vmmap` at `36e59927` reads 31 `IOSurface` regions, 607,649,792 bytes, all
dirty; 30 are `2720x1860` BGRA panes-sized surfaces and ten of those are shared
with the WindowServer. That is 0.09% above the arithmetic below, and the
largest competing class is `MALLOC_SMALL` at 25 MB.

Mechanism: `SwiftTerminalSessionView` creates a swapchain lazily on first
presentation and never releases it on hide; the layer keeps the displayed
surface attached. Supported by the `F2` code-read and by the near-identity
between the arithmetic and the measured total. Competing explanation: some
other class (font atlases, engine arenas) happens to sum to a similar figure.
Distinguished by one `vmmap --summary` on the empty arm: an IOSurface or
IOKit-mapped line near 607 MB confirms; anything else rejects.

### H2 -- the eager clear is what makes unwritten buffers resident -- CONFIRMED (`F7`)

Mechanism: `TerminalFrameBackingStore.init` runs `memset` over the whole
surface. Fresh IOSurface pages would otherwise fault in on first write, so an
idle pane that presented once would hold one resident buffer, not three.
The competing explanation -- that IOSurface wires or pre-touches its memory
regardless, so the clear changes nothing -- is ruled out: a build without the
clear reads 240,764,008 bytes against a contemporaneous 645,301,568 (`F7`,
`S7`, `S8`), which is the twenty never-rendered buffers exactly. As predicted,
the saving is idle-only (see the investigation rule): three panes given output
took 117 MB of it back, and it decides nothing about H1's fix.

### H3 -- the scrollback line is budget-bounded and already near its floor

Mechanism: the scrollback arm adds 17.4 MB per tab for 10,000 lines of 170
columns. Doc 15 and doc 31 put the logical-line store at roughly this cost at
its 16 MB budget, so the line is doing what it was designed to do. Competing
explanation: per-row overhead or style-table growth adds a term worth
chasing. Distinguished by `15`'s census probe on one of the ten panes. If
confirmed, this doc leaves the line alone and says so.

### H4 -- the 37 MB remainder is not one thing

Mechanism: ten engines, ten grids, PTYs, AppKit, fonts, and the allocator's
own overhead, none dominant. Nothing yet supports or refutes it. Distinguished
by the same `vmmap` as H1 plus a `heap` census once H1's term is out of the
way; until then it is noise under a 607 MB signal.

## Decided direction (`D2`)

**A hidden pane is detached and untrusted.** It presents nothing, its layer
holds no contents, and its buffers are either gone or purgeable-volatile.
Hide detaches the layer contents in a committed and flushed transaction,
then marks every buffer the render server reports free volatile; the one
buffer the server still holds (`F8`: the attached one, 44 of 44) is re-asked
on a bounded per-refresh retry and marked when it frees. Reveal restores the
buffers and renders the current plan once -- 1.37 ms when the pages are
intact (`F8`) -- and rebuilds the swapchain, the path a theme change takes
today, when any buffer came back discarded. A surface goes volatile only
while it is detached and reported free, which is the same premise the
swapchain already writes under (`tests-ui/IOSurfaceLayerContentsTests.swift`
pin two), so no composited surface can show undefined pixels.

`D2` records the ideal beside it: visible-lifetime release, where a hidden
pane owns no swapchain at all. It is the simpler structure and the same idle
bytes; what is wrong with it is the reveal, which becomes a from-scratch
rebuild on every tab switch (16.59 ms median, 43 ms tail, `F5`). `T8`
therefore lands the ideal first as a commit that stands alone, and the
volatile fast path as a second commit whose latency and bytes `T9` reports
on their own, so the trade is visible before merge. The shape, the hide and
reveal sequences, every trust break while hidden, the verification list, and
the open uncertainties are all in `D2`.

## Task ledger

### Phase 1 -- establish the baseline by allocation class

- [x] `T0` `DONE` -- `scripts/research/41/ten-tab-footprint.py`, the tier-1
  recipe over termwars' adapter. First reading is `S1` (`F3`), and it lands
  within 0.1% of the harness receipt in `F1` on a tree unchanged since. Still owed:
  two consecutive HEAD runs
  once `S1` gives a spread to judge them by. `T1`'s attribution now rides in the
  document.
- [x] `T1` `DONE` -- `danterm surfaces` reports the live census: swapchains,
  stores, surface bytes, visible and hidden panes, and the pane ids it could
  not measure. Derived at read time by walking the installed panes, never
  counted (`D4`). The tier-1 script embeds it, and the first reading is `S3`:
  607,518,720 bytes over 30 stores in 10 chains, 9 of 10 panes hidden.
- [x] `T2` `DONE` -- The script grew a `--hold` flag; `vmmap --summary`,
  `vmmap`, and `footprint` were taken on the held slot pid at `36e59927`.
  `F4` records 31 `IOSurface` regions holding 607,649,792 bytes, 30 of them
  `2720x1860` BGRA, against `F2`'s predicted 607,104,000. H1 confirmed. The
  remainder is 36,603,176 bytes, of which `MALLOC_SMALL` is 25 MB.
- [ ] `T2b` `TODO` (deferred by user 2026-09-01; run before the first
  before/after claim) -- `S1`, the A/A pair: a tier-2 run of HEAD against HEAD
  in two slots, so the series has a noise floor. Nothing below is read as a
  delta until this row exists.
- [x] `T3` `DONE` -- `F5`. Revealing a hidden tab presents no frame at all at
  `2c544f84`: twelve reveals, twelve `reveal` events, zero frames, because the
  pane's last frame never left its layer. A cold first presentation is 18.90 ms
  (n=12) and a from-scratch swapchain rebuild on a visible pane -- the work
  every Phase 3 shape would move onto a reveal -- is 16.59 ms (n=12), with a
  43 ms tail. Series row `S4`.
- [ ] `T4` `TODO` -- Run doc 15's census probe on one scrollback-arm pane to
  confirm or reject H3. Destination: `F6`.

### Phase 2 -- price the cheap experiments

- [x] `T5` `VETTING` -- `F7`. H2 confirmed: removing the eager clear takes the
  empty arm from 645,301,568 to 240,764,008 bytes (`S7`, `S8`), which is the
  twenty buffers ten idle panes never render into. Nothing relied on the clear
  -- a full render covers the whole surface, the incremental path only runs on
  a buffer that has had one, and no store reaches a layer before it is
  rendered. The saving is idle-only: a pane given three frames of output pays
  39 MB of it back, and three such panes paid back 117 MB. The removal is kept
  in this branch with a test that pins the guarantee it rests on. `T7` still
  decides the lifetime question; this does not.
- [x] `T6` `VETTING` -- `F8`. Both questions answered. Volatile pages leave
  `phys_footprint` at once, with no memory pressure: 645,039,424 bytes on the
  clean tree, 98,501,952 on the throwaway, taken in one session (`S6`, `S5`),
  and `vmmap` reads 27 of the 30 pane surfaces `PURGE=V` with `0K` dirty. The
  reveal presents a real frame in 1.37 ms (n=12), against `F5`'s no frame at
  all and against a 6.32 ms rebuild in the same run. The render server had
  **not** released the surface: 44 of 44 hides marked one still-`isInUse`
  buffer volatile, after a committed and flushed detaching transaction. The
  build was reverted; the diff is
  [readings/2026-09-01-951b4393-t6-throwaway.diff](readings/2026-09-01-951b4393-t6-throwaway.diff).

### Phase 3 -- direction gate and implementation

- [x] `T7` `DONE` -- `D2`. Decided on `F4`, `F5`, `F7`, `F8`: a hidden pane
  is detached and untrusted; its free buffers go purgeable-volatile, the one
  the render server still holds waits on a bounded retry, and a reveal
  renders once or rebuilds when a buffer was discarded. The ideal
  (visible-lifetime release) is recorded beside it with what it loses, and
  `T8` lands it first. Gate closed; implementation may start.
- [ ] `T8` `TODO` -- Implement `D2` behind the existing visibility
  transition in `SwiftTerminalSessionView` and `TerminalFrameSwapchain`, as
  two commits: first visible-lifetime release (hide is a trust break, no
  presentation while hidden, the retry made safe, one render per reveal),
  then the volatile-when-free fast path (`releasePixels` / `reclaimPixels`
  on the swapchain, the bounded pixel-release retry, the census's purgeable
  state, and pin four in `IOSurfaceLayerContentsTests.swift`). Behavioral
  coverage is listed under `D2`. Destination: a plan file, then commits.
- [ ] `T9` `TODO` -- Series row for the landed change: a tier-2 pair against
  the pre-change commit, `T1`'s attribution and `T3`'s latency beside the
  medians. Destination: `series.md` and `## Outcome`.

### Phase 4 -- the remainder

- [ ] `T10` `TODO` -- Once H1's term is gone, census the remainder (H4):
  per-engine, per-grid, font, AppKit. Open new hypotheses only for a class
  that is a double-digit share of what is left.

## Rejected

### Depth-2 swapchains

Saves one surface per pane (202 MB at ten tabs) and reopens the documented
cold-pipeline wedge: a retry that cannot acquire presents nothing, so nothing
flushes the pipeline holding the only detached buffer. Reopen only with a
presentation design that proves two buffers cannot wedge; that is not a
memory task.

### Rendering hidden panes at lower resolution or a smaller grid

Breaks the contract that grid, metrics, and displayed surface agree, and buys
nothing a hidden pane needs: a pane that is not shown needs no pixels at all.

### Starting with cells, PTY buffers, or font caches

They live in the 6% remainder. Deleting all of it saves less than releasing
one surface from two panes. Parked as `T10`, not rejected forever.

## Open questions and caveats

- `F4` closes `F2`'s arithmetic caveat, but it is one capture of one build at
  one moment. It says nothing about what the surfaces would cost if they were
  marked volatile (`PURGE=N` on all 31); `F8` answers that on a throwaway
  build, where 27 of the 30 pane surfaces read `PURGE=V` and the process
  footprint is 98.5 MB.
- `F8` measured a hidden pane's surface going volatile while the render server
  still reported it in use, 44 times out of 44. A discard under real memory
  pressure would then hand undefined pixels to whatever composites that hidden
  window -- Mission Control, a window thumbnail, a screen capture. Any
  purgeable shape has to mark only the surfaces reported free, and what that
  costs of the saving is unmeasured.
- The Core Animation render server can hold a detached surface past the app's
  release. Any lifetime change needs the real-AppKit IOSurface test in
  `tests-ui/IOSurfaceLayerContentsTests.swift` extended to cover hide, not a
  reference-count test.
- A pane can be hidden while a presentation retry is armed. The retry must
  not be able to recreate buffers after hide.
- Backing scale, color space, theme, grid, and font can all change while a
  pane is hidden. Reveal must treat every one as a trust break.
- The receipt's other three terminals are context for scale, not targets:
  they count different process sets (kitty sums three pids) and the chart
  makes no directional claim.

## Outcome

Investigation in progress.
