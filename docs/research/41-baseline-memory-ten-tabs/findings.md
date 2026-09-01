# Findings -- baseline memory with ten tabs open

Append-only. Cross-doc citations are qualified (`15/F1`); bare IDs are this
doc's.

### F1 -- termwars memory receipt, 2026-09-01, ten tabs

- Status: recorded; archived trigger, not a control.
- Date and investigator: 2026-09-01, termwars run driven by the user.
- Commit and worktree state: DanTerm 0.1.25 at `5f5ecfea`, optimized dev slot
  1, isolated config seeded with Menlo 13.
- Commands, inputs, or reproduction: `just memory` in the termwars checkout (then named termwars);
  receipt at `/Users/dan/Code/termwars/results/memory-2026-09-01-140511.json`.
  Host `MacBookPro18,1`, macOS 26.5.2, 2x display. Grid 170x60 requested and
  read back as 170x60 on every tab of every terminal. 10 tabs, scrollback
  limit 10,000, settle 5 s, 10 samples at 1 s.
- Measurements: median `phys_footprint`, bytes, with the pid count each bar
  sums.

  | Terminal | pids | tabs-empty-visible | tabs-scrollback-visible |
  |---|---:|---:|---:|
  | DanTerm 0.1.25 | 1 | 644,465,984 | 818,709,944 |
  | kitty 0.48.2 | 3 | 252,823,904 | 826,772,264 |
  | Ghostty 1.3.1 | 1 | 792,118,928 | 944,441,240 |
  | iTerm2 3.6.6 | 2 | 196,642,208 | 525,322,160 |

  DanTerm's ten samples on the empty arm were flat within 66 KB.
- Observation: DanTerm's empty baseline is 2.5x kitty's and 3.3x iTerm2's.
  Filling scrollback adds 174,243,960 bytes to DanTerm, 17.4 MB per tab.
- Inference: the empty baseline holds a large term that has nothing to do
  with terminal history. The scrollback delta is the terminal-state line doc
  15 optimized and is in the range its 16 MB budget predicts.
- Competing interpretations: the settle may be short enough that some class
  had not finished growing or shrinking; the flat samples argue against it.
- Uncertainty: one rep per arm. The run is a trigger for attribution, not a
  before/after control.
- Next action: `T2`, the allocation-class capture.

### F2 -- every presented pane owns a resident depth-3 swapchain

- Status: verified by code-read at HEAD; arithmetic only, not yet observed by
  allocation class.
- Date and investigator: 2026-09-01, agent code-read; originally written up in
  `docs/scratch/2026-09-01-baseline-memory-owned-pane-surfaces.md`.
- Commit and worktree state: the three files below are unchanged since
  `5f5ecfea`.
- Commands, inputs, or reproduction: read
  `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalFrameSwapchain.swift`
  (`defaultDepth = 3`, the initializer building one store per buffer),
  `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalFrameBackingStore.swift`
  (one BGRA IOSurface per store at backing-pixel size, then `memset` over its
  whole byte range under lock), and `app/SwiftTerminalSessionView.swift`
  (`surfaceSwapchain` creates lazily on first presentation; `attach` sets
  `layer.contents`; nothing on hide clears `swapchain` or `displayedStore`).
- Measurements or examples: Menlo 13 at 2x has a 7.82666015625 pt advance
  and a 15.1328125 pt line height; each backing dimension rounds up, so a
  cell is 16x31 px.

  | Quantity | Arithmetic | Bytes |
  |---|---:|---:|
  | Surface pixels | `(170 * 16) x (60 * 31)` | `2720 x 1860` |
  | One BGRA surface | `10,880 bytes/row * 1,860 rows` | 20,236,800 |
  | One depth-3 swapchain | `x 3` | 60,710,400 |
  | Ten swapchains | `x 10` | 607,104,000 |

  `bytesPerRow` comes from IOSurface and is tight for these properties. Ten
  swapchains are 94.2% of `F1`'s 644,465,984. The remainder is 37,361,984.
- Observation: the `memset` makes all three buffers resident at creation,
  whether or not a buffer is ever rendered. termwars focuses every tab once
  while verifying the grid, so every pane presents once and creates its chain.
  Tab changes hide the pane and gate its planning but release nothing.
- Inference: H1. Ten live grids at a 16-byte `GridCell` stride are 1.6 MB,
  0.25% of the total, so cells are not a competing term. Empty scrollback
  reserves address space but touches no pages.
- Competing interpretations: another class could coincidentally sum near 607
  MB. The fit is close enough to make that unlikely, not impossible.
- Uncertainty: arithmetic, not an allocation-class observation. Whether
  removing the `memset` would leave unwritten buffers non-resident (H2) is
  untested.
- Next action: `T2` to observe the class; `T5` for H2.

### F3 -- tier-1 baseline at HEAD, ten empty tabs: 643,892,520 bytes

- Status: recorded as `S1` in `series.md`; the first reading of the tier-1
  instrument, and the baseline this doc works to improve.
- Date and investigator: 2026-09-01, agent, via
  `scripts/research/41/ten-tab-footprint.py`.
- Commit and worktree state: `5ffdb5ae`, tracked tree dirty only in
  `docs/research/README.md` (this doc's index row); no source changed.
- Commands, inputs, or reproduction: `python3
  scripts/research/41/ten-tab-footprint.py`, defaults. Optimized dev slot 1,
  Menlo 13 seeded and verified installed, 10 tabs running `exec sleep`,
  window 1565x999 through Accessibility, slot verified frontmost, every pane
  read back at 170x60 through `pane rows`. Settle 5 s, 10 samples at 1 s.
- Result or artifact paths:
  [readings/2026-09-01-5ffdb5ae-tabs-empty-visible.json](readings/2026-09-01-5ffdb5ae-tabs-empty-visible.json).
- Measurements: median `phys_footprint` **643,892,520** bytes over one pid;
  spread across the ten samples 409,600 bytes; no missing pids.
- Observation: the harness receipt in `F1` read 644,465,984 on `5f5ecfea`
  under the same staging with a 60 s settle and 60 samples. The two agree to
  0.09%, on a tree that has not touched the swapchain, backing store, or
  session view between the two commits.
- Inference: the tier-1 script measures the same quantity as the harness and
  is stable enough at a 5 s settle to steer the edit loop. The baseline this
  doc starts from is 644 MB, and `F2`'s 607 MB surface term still fits it.
- Competing interpretations: agreement between two readings of the same
  build says nothing about session noise across builds; that is `S1`'s job.
- Uncertainty: one run. The attribution counter (`T1`) is not in the
  document yet, so the surface term is still arithmetic.
- Next action: `T2` on this staged slot; `T2b` for the A/A pair.
