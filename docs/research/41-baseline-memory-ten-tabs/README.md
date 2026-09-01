# Baseline memory with ten tabs open

Research started: 2026-09-01.
Continues: [15-memory-footprint.md](../15-memory-footprint.md) (`15/F1`,
`15/F17`) and
[33-by-construction-perf-survey/README.md](../33-by-construction-perf-survey/README.md)
(`33/D7`, the `T25` owned pane surface and its accepted per-pane surface cost).

- [findings.md](findings.md) -- the append-only evidence chain. `F1` is the
  termwars receipt this doc opened on, beside the other three terminals. `F2`
  is the code-read that attributes most of the empty-tab baseline to pane
  swapchains, arithmetically but not yet by allocation class.
- [decisions.md](decisions.md) -- the decision log. `D1` is the standing rule
  for what counts as evidence here; `D3` fixes the instrument.
- [series.md](series.md) -- every footprint reading, in order, one row each.
  This is the record of progress over time; a finding may interpret a row,
  but the numbers live here.
- [readings/](readings/) -- the raw JSON behind each series row, named
  `<date>-<commit>-<arm>.json`.

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

    python3 scripts/research/41/ten-tab-footprint.py [--arm tabs-scrollback-visible]

The script borrows termwars' DanTerm adapter for staging, so the slot is
seeded with Menlo 13, opened to ten inert tabs, sized to the calibrated
1565x999 window, and every pane is read back at 170x60 before a sample is
taken; a grid mismatch fails the reading instead of shrinking it. Then a 5 s
settle and ten `footprint` samples at 1 s over the slot bundle's pid set. It
prints one JSON document (commit, dirty flag, achieved grids, every sample,
median, spread, pid count) and stops the slot. Save the document under
`readings/` and add a row to `series.md`. It takes focus for a moment while it
sizes the window, which is why it is not a gate test. `T1`'s attribution
counter is added to the document once it exists.

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

### H1 -- hidden panes' swapchains are the baseline

Mechanism: `SwiftTerminalSessionView` creates a swapchain lazily on first
presentation and never releases it on hide; the layer keeps the displayed
surface attached. Supported by the `F2` code-read and by the near-identity
between the arithmetic and the measured total. Competing explanation: some
other class (font atlases, engine arenas) happens to sum to a similar figure.
Distinguished by one `vmmap --summary` on the empty arm: an IOSurface or
IOKit-mapped line near 607 MB confirms; anything else rejects.

### H2 -- the eager clear is what makes unwritten buffers resident

Mechanism: `TerminalFrameBackingStore.init` runs `memset` over the whole
surface. Fresh IOSurface pages would otherwise fault in on first write, so an
idle pane that presented once would hold one resident buffer, not three.
Competing explanation: IOSurface wires or pre-touches its memory regardless,
so the clear changes nothing. Distinguished by removing the clear in a throwaway
build and re-reading the empty arm. Even if confirmed, this is an idle-only
saving (see the investigation rule) and it decides nothing about H1's fix.

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

## Candidate direction, pending evidence

Provisional: **presentation buffers live only for a pane's visible lifetime.**
Only a pane that can currently present owns a swapchain; terminal state lives
for the session. Hide detaches the layer contents, commits, and releases the
swapchain; reveal builds a fresh one and presents the current state with full
damage. It preserves depth-3 exactly where the chain is in use and attacks the
whole of H1's term. It is provisional because H1 is not yet confirmed by
allocation class, because reveal latency is unmeasured, and because two
cheaper shapes (a purgeable-volatile hidden chain, one frozen surface per
hidden pane) have not been priced against it.

## Task ledger

### Phase 1 -- establish the baseline by allocation class

- [x] `T0` `DONE` -- `scripts/research/41/ten-tab-footprint.py`, the tier-1
  recipe over termwars' adapter. First reading is `S1` (`F3`), and it lands
  within 0.1% of the harness receipt in `F1` on a tree unchanged since. Still owed:
  `T1`'s attribution counter in the document, and two consecutive HEAD runs
  once `S1` gives a spread to judge them by.
- [ ] `T1` `TODO` -- Add attribution the app can report: live swapchains, live
  stores, surface bytes, visible panes, hidden panes. Zero distinct from
  unmeasured. Destination: a `danterm` query or a frame-rate-log line, and
  `F3`.
- [ ] `T2` `TODO` -- With the tier-1 script's slot staged (add a `--hold`
  flag that samples and then waits for a keypress before quitting), take `vmmap --summary`
  (and `footprint --vmObjectDirty` if it separates IOSurface) on the slot pid
  at HEAD. Record the
  IOSurface / IOKit-mapped line and the malloc line. Confirms or rejects H1.
  Destination: `F4`.
- [ ] `T2b` `TODO` -- `S1`, the A/A pair: a tier-2 run of HEAD against HEAD
  in two slots, so the series has a noise floor. Nothing below is read as a
  delta until this row exists.
- [ ] `T3` `TODO` -- Measure tab-switch latency at HEAD: warm visible tab,
  hidden tab, cold first presentation. Method and numbers to `F5`. Begin
  before any Phase 3 change so the control is not confounded.
- [ ] `T4` `TODO` -- Run doc 15's census probe on one scrollback-arm pane to
  confirm or reject H3. Destination: `F6`.

### Phase 2 -- price the cheap experiments

- [ ] `T5` `RESEARCH` -- Remove the eager clear in a throwaway build and
  re-read the empty arm (H2). Record the idle saving and confirm three frames
  of output brings the buffers back. Check nothing in the erase path relied on
  the clear. Destination: `F7`.
- [ ] `T6` `RESEARCH` -- Mark a hidden pane's surfaces purgeable-volatile
  after detaching the layer contents; on reveal mark non-volatile and force
  every buffer to render again. Two things to learn: whether volatile
  IOSurface pages leave `phys_footprint` on this macOS, and whether the render
  server has released the surface by the time it goes volatile. Destination:
  `F8`.

### Phase 3 -- direction gate and implementation

- [ ] `T7` `VETTING` -- Decide between visible-lifetime release, the
  purgeable-volatile chain, and one frozen surface per hidden pane, on `F4`,
  `F5`, `F7`, `F8`. Explicit gate: no implementation before `D2` is recorded.
- [ ] `T8` `TODO` -- Implement the selected direction behind the existing
  visibility transition in `SwiftTerminalSessionView` and
  `TerminalPaneSession`, with the behavioral coverage listed under `D2`.
  Destination: a plan file, then commits.
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

- `F2` is arithmetic that matches the total to within 6%; it is not an
  allocation-class observation until `T2` lands.
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
