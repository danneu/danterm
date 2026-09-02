# Findings -- baseline memory with ten tabs open

Append-only. Cross-doc citations are qualified (`15/F1`); bare IDs are this
doc's.

`F2`'s scratch note was folded into this document and never committed, so the
path it names is gone on purpose.

<!-- docs-lint: allow-missing docs/scratch/2026-09-01-baseline-memory-owned-pane-surfaces.md -->

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

### F4 -- allocation-class capture: 31 IOSurface regions hold 579.5 MiB of a 614.4 MiB footprint

- Status: recorded; `H1` **confirmed** by allocation class. Supersedes nothing;
  it turns `F2`'s arithmetic into an observation.
- Date and investigator: 2026-09-01, agent, ledger task `T2`.
- Commit and worktree state: `36e59927`, tracked tree dirty only in
  `scripts/research/41/ten-tab-footprint.py` (the `--hold` flag this capture
  needed). No app source, no `TerminalCore` source changed.
- Commands, inputs, or reproduction: `python3
  scripts/research/41/ten-tab-footprint.py --hold`, defaults. The script stages
  the slot the usual way, samples, prints the document with its pid list, and
  holds the slot up until stdin gives a line. While it held pid 77986:
  `vmmap --summary 77986`, `vmmap 77986`, `footprint 77986`. Neither tool
  needed `sudo`. Then the hold was released and the script quit the slot.
- Result or artifact paths:
  [readings/2026-09-01-36e59927-tabs-empty-visible.json](readings/2026-09-01-36e59927-tabs-empty-visible.json)
  (the sampled document, `S2`),
  [readings/2026-09-01-36e59927-vmmap-summary.txt](readings/2026-09-01-36e59927-vmmap-summary.txt),
  [readings/2026-09-01-36e59927-vmmap-regions.txt](readings/2026-09-01-36e59927-vmmap-regions.txt)
  (the full region listing),
  [readings/2026-09-01-36e59927-footprint.txt](readings/2026-09-01-36e59927-footprint.txt).
- Measurements: median `phys_footprint` **644,252,968** bytes over one pid,
  spread 49,152; `vmmap` read the same process at 614.4M and `footprint` at
  614 MB, which is that median in MiB.

  The `IOSurface` class, with its region count:

  | Quantity | Count | Bytes |
  |---|---:|---:|
  | `2720x1860` BGRA regions, 19.3M each | 30 | 607,518,720 |
  | One `240x240` LA08 `CoreUI image IOSurface` | 1 | 131,072 |
  | `IOSurface` class, dirty = resident | 31 | 607,649,792 |
  | `F2`'s prediction for ten depth-3 chains | 30 | 607,104,000 |

  Every one of the 30 grid regions is `2720x1860 (BGRA)`, owner
  `'DanTerm Dev (1)'`, `PURGE=N`, and fully dirty. Ten of them are also
  `shared with WindowServer[471]` -- the attached buffer of each pane. One
  region is 20,250,624 bytes: `F2`'s 20,236,800-byte payload rounded up to 16 KB
  pages. The class is 0.09% above the prediction, and that 0.09% is the page
  rounding.

  Remainder, 644,252,968 - 607,649,792 = **36,603,176** bytes. Top six dirty
  categories in it, from `footprint`, each with its region count:

  | Category | Regions | Dirty |
  |---|---:|---:|
  | `MALLOC_SMALL` | 17 | 25 MB |
  | `__DATA_DIRTY` | 869 | 1834 KB |
  | `CoreAnimation` | 65 | 1424 KB |
  | `__DATA` | 962 | 1212 KB |
  | `MALLOC metadata` | 12 | 1088 KB |
  | page table | 1 | 897 KB |

  `__TEXT` is 4624 KB and entirely clean, so it is not in the footprint.
- Observation: the presentation surfaces are one named allocation class, they
  are 94.3% of the footprint, and there are exactly 30 of them for ten panes.
  No competing class is within two orders of magnitude of them.
- Inference: `H1` is confirmed. Ten panes each hold a depth-3 swapchain of
  full-grid BGRA IOSurfaces, all pages resident, whether the pane is shown or
  hidden. The `shared with WindowServer` mark on exactly ten regions confirms
  the other twenty are held by the app alone, so releasing a hidden pane's
  chain is an app-side lifetime question, not a render-server one.
- Competing interpretations: none left for the 607 MB term. The alternative
  `F2` named -- some other class summing near 607 MB -- is ruled out: the
  largest non-surface class is `MALLOC_SMALL` at 25 MB.
- Uncertainty: one capture, one build, one moment. `PURGE=N` on every surface
  says nothing about whether marking them volatile would drop them from
  `phys_footprint`; that is still `T6`. The capture does not say which of the
  three buffers in a chain a hidden pane could do without.
- Next action: `H4`'s remainder is now readable but small: `MALLOC_SMALL` is
  68% of it and everything else is under 2 MB, so `T10` stays parked. `T7`'s
  gate is one finding closer; `T3` and `T2b` are the two still owed before it.

### F5 -- a tab switch presents no frame at all today; a rebuilt swapchain costs 16.6 ms

- Status: recorded; the `T3` control, taken before any Phase 3 change.
- Date and investigator: 2026-09-01, agent session, on the machine `F1` ran on.
- Commit and worktree state: `2c544f84`, clean tree, DanTerm 0.1.25 in
  optimized dev slot 1, isolated config seeded with Menlo 13.
- Commands, inputs, or reproduction:

      python3 scripts/research/41/tab-switch-latency.py --samples 12

  The staging is the tier-1 staging (`D3`): ten inert tabs, all ten panes read
  back at 170x60, one 1565x999 window, 2x display -- the surfaces census taken
  in the same run reads 30 stores of 2720x1860 in 10 chains, 9 of 10 panes
  hidden, 607,518,720 bytes, which is the `S3` state exactly. The slot app was
  frontmost throughout, and nothing else was driving the display; the gate was
  idle.

  The instrument is the app's own presentation trace, added for this task:
  `DANTERM_PRESENTATION_EVENT_LOG` names a file and
  `TerminalPresentationEventSampler` appends one JSON line per pane event --
  `create`, `reveal`, `hide`, `rebuild`, `attach` -- each with
  `DispatchTime.now().uptimeNanoseconds`. The two timestamps of a switch are
  taken at the top of `SwiftTerminalSessionView.setVisible(true)`, before the
  reveal does any work, and immediately after the `CATransaction` that assigns
  `layer.contents`. Both are inside the process, so no screen capture and no
  second clock is in the path. Events are paired per pane, because one switch
  touches two of them.
- Result or artifact paths:
  [readings/2026-09-01-2c544f84-tab-switch-latency.json](readings/2026-09-01-2c544f84-tab-switch-latency.json)
  (every sample with its own timestamps), and the footprint reading taken in
  the same session at the same commit,
  [readings/2026-09-01-2c544f84-tabs-empty-visible.json](readings/2026-09-01-2c544f84-tabs-empty-visible.json)
  (`S4`).
- Measurements: four cases, twelve samples each, no sample discarded.

  | Case | n | Median | Min | Max |
  |---|---:|---:|---:|---:|
  | Hidden tab revealed, reveal to frame | 0 of 12 | no frame | -- | -- |
  | Hidden tab revealed, request round trip | 12 | 27.90 ms | 16.29 ms | 37.63 ms |
  | Warm visible tab reselected, round trip | 12 | 35.98 ms | 24.96 ms | 41.92 ms |
  | Cold first presentation, create to frame | 12 | 18.90 ms | 13.91 ms | 19.44 ms |
  | Swapchain rebuild on a visible pane | 12 | 16.59 ms | 10.50 ms | 43.36 ms |

  The first row is the finding, not a gap in it: across twelve reveals of nine
  different hidden tabs the trace recorded twelve `reveal` events and **zero**
  `attach` events on the revealed pane, each waited on for 5 s. There is no
  reveal-to-frame latency at this revision because there is no frame.

  Case 2 is `warmVisibleTab`: a `pane focus` on a pane of the tab already
  selected. The app records no visibility transition for it at all, so it has
  no presentation half to measure and is reported as the round trip of the
  request. Both round trips are dominated by spawning the `danterm` CLI, and
  the warm one -- which cannot do any reveal work by construction -- is the
  slower of the two, so nothing in the reveal shows above that noise.

  Case 4 is not a switch a user can make. It is the work a Phase 3 reveal would
  have to do, priced where the app already forces it: a theme change throws the
  live rotation away, and the next frame allocates a fresh depth-3 swapchain of
  three 2720x1860 BGRA surfaces, clears them, and renders all 60 rows into one.
  It is measured `rebuild` to `attach` on the visible pane at the benchmark
  grid.

  Instrument overhead: one trace line is 60 bytes to an already-open appending
  descriptor, and exactly one such write (the `reveal` or `rebuild` line) falls
  inside a measured interval. Timed against the same file in the same run, 200
  writes: median 2,541 ns, max 88,625 ns. That is 0.015% of the rebuild median,
  so no reported figure is the instrument.
- Observation: hiding a tab in DanTerm today detaches nothing. The pane's last
  frame stays attached to its layer for the whole time it is hidden, the pane
  is idle so nothing new is published, and revealing it therefore costs the
  reconcile and the visibility push and no pixels whatever. A pane that must
  build buffers before it can show anything costs 16.59 ms at this geometry.
- Inference: the reveal side of the memory trade is currently free, and the
  price of the candidate direction is a real number rather than a worry. Every
  one of the three Phase 3 shapes moves a reveal from "no frame" to "at least
  one frame", so the regression is not marginal: it is the whole of case 4,
  which is 16.59 ms of median added latency at 170x60 on a 2x display, with a
  tail to 43 ms. Two of the three shapes could beat that -- one frozen surface
  per hidden pane presents the old frame immediately and pays only for the two
  it dropped when the pane next publishes, and a purgeable-volatile chain pays
  the fault-in but not the allocation or, if the last frame survives volatility,
  possibly nothing at all. Visible-lifetime release cannot: it has no buffers to
  show, so its reveal is case 4 at best, and its 607 MB saving has to be worth a
  switch that goes from no frame at all to 16.6 ms, and 43 ms at the tail.
- Competing interpretations: the 16.59 ms of case 4 is a latency, not CPU time
  -- it includes the pane's publish pacing to the display's refresh, so a share
  of it is a wait, not work. That is the right quantity for this question (it
  is what the user waits) but it means the number cannot be read as "the render
  costs 16.59 ms of CPU". The two round-trip rows are not app-side latencies at
  all; they bound the switch end to end, CLI spawn included.
- Uncertainty: one session, one machine, one geometry, one arm. The reveal
  result depends on the panes being idle: a hidden pane with pending output
  publishes on reveal, and that case is unmeasured here because the staged tabs
  run `exec sleep 100000` and can produce no output. Case 4 is a proxy for a
  Phase 3 reveal, not a Phase 3 reveal: it rebuilds on a pane that is already
  visible and laid out, so a real reveal would add whatever the visibility
  transition itself costs on top.
- Next action: `T7` now has `F4` and `F5`. `T2b` and `T4` are what remain
  before the direction gate; whichever direction `D2` selects must report this
  table again after the change, per the investigation rule that a memory win is
  also a latency claim.

### F7 -- the eager clear is the whole of the idle surface term: 645 MB falls to 241 MB without it

- Status: recorded; `H2` **confirmed**, and the saving is idle-only exactly as
  the hypothesis said. The clear is removed in the tree this finding was
  written on (`T5`).
- Date and investigator: 2026-09-01, agent, ledger task `T5`.
- Commit and worktree state: control at `951b4393`, clean tree. The modified
  arm is the same commit with three lines deleted from
  `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalFrameBackingStore.swift`
  -- the `lock`/`memset`/`unlock` that cleared a fresh surface -- and nothing
  else. Both readings were taken in one session on the same machine, display,
  scale, font, and grid, control first.

**What the clear guaranteed.** Nothing that any code path asks for.

  - A full render decides every pixel of the surface. `drawRenderFrame`
    (`lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift`)
    fills the whole frame rect with the plan's default background in `.copy`
    blend mode before it draws anything else, and that rect is the surface
    exactly: the store's initializer allocates `cellWidthPixels * columns` by
    `cellHeightPixels * rows` pixels while `TerminalRenderMetrics.cellSize` is
    `cellWidthPixels / displayScale`, so the point-space fill maps onto the
    whole pixel extent with nothing left over. A pane that renders a claimed
    grid smaller than its slot renders into a surface sized to that grid and
    shows the difference as layer surround, not as unwritten pixels
    (`app/SwiftTerminalSessionView.swift`, `presentationGeometryForTesting`).
  - The incremental path never reads a pixel a full render did not write.
    `TerminalFrameSwapchain.render` applies damage only when the buffer's
    `isCurrent` bit is set, and only the first render into that buffer sets
    it, so `apply(plan:damage:)` always builds on a complete frame.
  - No unrendered surface can reach a layer. A store is attached only in
    `SwiftTerminalSessionView.presentAttempt`, on the value `publish` or
    `retryPendingPresentation` returned, and `TerminalFrameSwapchain`'s
    `presentPending` renders into the buffer before it returns it.
  - Nothing in the erase path depends on it either. `apply`'s erase spans and
    the translation's stale strips are derived from the row-reach ledger and
    the plan, never from the pixels' prior value, and `translateRows` moves
    pixels the store itself wrote.
  - The row stride can exceed `width * 4` and CoreGraphics never writes that
    padding. Those bytes are outside the surface's declared width, so nothing
    samples them, and the byte-equality tests compare `direct.width` pixels
    per row, not the stride.
  - History says the same. The clear arrived with the malloc-backed store,
    where `initializeMemory(as:repeating:count:)` was what made raw allocated
    memory initialized before CoreGraphics could be pointed at it; `79ba5ec3`
    moved the pixels into an IOSurface and kept the zeroing as a `memset`.
  - The SDK documents no zero-fill guarantee for a fresh IOSurface -- neither
    `IOSurfaceRef.h` nor `IOSurfaceObjC.h` in the macOS SDK says anything
    about the initial contents of an allocation -- and this result does not
    need one: no pixel a viewer can see is ever unwritten.

- Commands, inputs, or reproduction:

      python3 scripts/research/41/ten-tab-footprint.py            # control
      python3 scripts/research/41/ten-tab-footprint.py --hold     # modified

  Both are the `D3` staging: optimized slot, Menlo 13, ten inert tabs, the
  1565x999 window, every pane read back at 170x60, 5 s settle, ten samples at
  1 s. The modified run held its slot so the fault-back probes below could
  drive the same process.
- Result or artifact paths:
  [readings/2026-09-01-951b4393-t5-control-tabs-empty-visible.json](readings/2026-09-01-951b4393-t5-control-tabs-empty-visible.json)
  (`S7`, control),
  [readings/2026-09-01-951b4393+T5-tabs-empty-visible.json](readings/2026-09-01-951b4393+T5-tabs-empty-visible.json)
  (`S8`, the throwaway build),
  [readings/2026-09-01-951b4393+T5-faultback-fresh-pane.json](readings/2026-09-01-951b4393+T5-faultback-fresh-pane.json),
  [readings/2026-09-01-951b4393+T5-faultback-echo.json](readings/2026-09-01-951b4393+T5-faultback-echo.json).
- Measurements: ten samples per arm, one pid per arm, ten tabs per arm, every
  pane read back at 170x60.

  | Arm | n | Median `phys_footprint` | Spread | `surfaces` (mapped) |
  |---|---:|---:|---:|---|
  | Control, `951b4393` | 10 | 645,301,568 | 507,904 | 607,518,720 (30 stores, 10 chains, 9/10 hidden) |
  | Clear removed, `951b4393+T5` | 10 | 240,764,008 | 32,768 | 607,518,720 (30 stores, 10 chains, 9/10 hidden) |

  The saving is **404,537,560 bytes**, 62.7% of the control. Twenty surfaces
  of 20,250,624 bytes -- the two buffers per pane that ten idle panes never
  render into -- are 405,012,480, so the measured saving is 0.1% short of
  dropping exactly those twenty from residency. The app's own attribution is
  identical to the byte in both arms, which is `D4`'s stated design: it counts
  mapped `allocationSize`, and after this change mapped size and resident
  bytes are meant to diverge.

  Fault-back, on the held modified process (pid 99670), read with `footprint`:

  | Moment | `phys_footprint` | Change |
  |---|---:|---:|
  | Ten staged idle tabs | 230 MB | -- |
  | One new foreground tab running `sh` | 288 MB | +58 MB |
  | That tab after three rounds of `seq 1 200` | 289 MB | +1 MB |
  | Staged pane 1 given 12 echoed lines | 328 MB | +39 MB |
  | Staged pane 2 given 12 echoed lines | 367 MB | +39 MB |
  | Staged pane 3 given 12 echoed lines | 406 MB | +39 MB |

  The staged tabs run `exec sleep` and print nothing of their own, so output
  was made the way a user makes it: each pane was focused, which selects its
  tab and makes it visible, and twelve lines were typed into it, which the tty
  echoes and the visible pane renders. Each such pane cost **39 MB**, which is
  the two 20,250,624-byte buffers it had never written. Three panes brought
  117 MB of the 405 MB back.
- Observation: `H2` is confirmed and its idle-only caveat is confirmed with
  it. Removing the clear takes the ten-tab empty arm from 645 MB to 241 MB,
  and every pane that renders three frames pays 39 MB of that back. A pane
  with a live shell reaches full residency within seconds rather than
  gradually: the new `sh` tab was already at its full chain at the first
  reading after creation, so its `seq` rounds added nothing.
- Inference: the eager clear was doing no work for correctness and 405 MB of
  work for the kernel. It should go. It is not, however, an answer to `H1`:
  the term it removes comes back the moment a user actually uses the tabs, and
  a user with ten busy tabs holds the full 607 MB again. `T7` still has to
  decide the lifetime question on `F4` and `F5`.
- Competing interpretations: the modified arm could be smaller because the app
  is doing less work at startup rather than holding fewer pages -- ruled out
  by the fault-back table, which puts the missing bytes back two buffers at a
  time as panes render, and by the surface census, which reports the same
  mapped bytes in both arms. The 39 MB per pane could be the pane's other
  costs rather than its buffers; the figure is 96% of two surfaces and repeats
  three times on three panes that already existed and had already presented.
- Uncertainty: one session, one machine, one arm, tier-1 rigor -- and `T2b`'s
  A/A pair still does not exist, so the series has no noise floor. The delta
  is 800x the within-run spread of either row, which is why it is reported as
  a result; a tier-2 pair is still owed before any landed claim. The fault-back
  numbers are `footprint`'s MB granularity, not byte-exact. Nothing here
  measures whether the first render into a never-written buffer is slower than
  into a cleared one; the page faults it takes are the same ones the clear
  used to take at creation, moved to first use, and `F5`'s rebuild figure was
  measured with the clear in place.
- Test result: `swift test --package-path lib/TerminalCore --filter
  TerminalRenderExecution` passes, 158 tests in 29 suites (the one known issue
  is `BitmapComparisonTests`' deliberate mismatch), and `just test-ui` passes
  459 of 459. No test relied on the clear.
- Recommendation: **drop the clear**, which is what this branch does. The
  three candidates were: keep it, clear only the part of the surface a full
  render does not write, or drop it. The middle one has nothing to clear --
  the surface is the grid and a full render covers all of it -- so it reduces
  to the third. Relying on a documented IOSurface zero-fill was rejected as a
  reason: the SDK promises none, and the guarantee this rests on is DanTerm's
  own, that a buffer is rendered before it is shown. That guarantee is now a
  test rather than an assumption, which is the part of this that is worth
  keeping whatever `T7` decides.
- Next action: `T7`. The clear's removal is kept in this branch with a
  behavioral test that pins the guarantee it depended on -- a full render
  covers every pixel of the surface whatever it held before -- so a later
  change that stops covering the surface fails a test instead of showing a
  viewer uninitialized memory.
### F8 -- a hidden pane's volatile surfaces leave `phys_footprint` at once: 645 MB to 98.5 MB, and the reveal costs 1.37 ms

- Status: recorded; the `T6` experiment, on a throwaway build that was measured
  and then reverted. It answers both questions the ledger asked, and the answer
  to the second one is a hazard the shape has to design around.
- Date and investigator: 2026-09-01, agent session, on the machine `F1` ran on.
- Commit and worktree state: `951b4393`. Two arms in one session, both staged
  into optimized dev slot 1 from this worktree:
  - **modified** -- the throwaway change of this task in the tracked tree, saved
    as
    [readings/2026-09-01-951b4393-t6-throwaway.diff](readings/2026-09-01-951b4393-t6-throwaway.diff)
    and reverted after the readings.
  - **control** -- the same commit with that diff stashed, tree clean, run
    between the modified footprint reading and the modified latency reading.
- Commands, inputs, or reproduction:

      python3 scripts/research/41/ten-tab-footprint.py --hold        # both arms
      python3 scripts/research/41/tab-switch-latency.py --samples 12 # modified

  While each `--hold` held its pid: `vmmap <pid>`, `vmmap --summary <pid>`,
  `footprint <pid>`. No `sudo`, and no memory pressure was applied -- see
  Measurements.

  The API, cited from the SDK rather than guessed. `IOSurfaceObjC.h:217`:

      - (kern_return_t)setPurgeable:(IOSurfacePurgeabilityState)newState
                             oldState:(IOSurfacePurgeabilityState * __nullable)oldState
          API_AVAILABLE(macos(10.13), ios(11.0), watchos(4.0), tvos(11.0));

  The states are `IOSurfaceTypes.h:29-34`: `kIOSurfacePurgeableNonVolatile` (0),
  `kIOSurfacePurgeableVolatile` (1), `kIOSurfacePurgeableEmpty` (2),
  `kIOSurfacePurgeableKeepCurrent` (3). `IOSurfaceRef.h:444-447` states what the
  returned old state means: `Volatile` is "was volatile, but the contents were
  not discarded", `Empty` is "was empty and the contents have been discarded".
  Swift imports the type as an option set, so non-volatile is the empty set
  (`IOSurfacePurgeabilityState([])`) and the other three arrive as
  `.purgeableVolatile`, `.purgeableEmpty` and `.purgeableKeepCurrent` -- checked
  by compiling a probe against the macOS 26.5 SDK, not read from memory.
- Mechanism as implemented: inside the pane view's existing visibility
  transition and nowhere else. On `setVisible(false)` the view sets
  `layer.contents = nil` in a `CATransaction` with actions disabled, commits it,
  calls `CATransaction.flush()`, then marks every surface it holds -- the
  swapchain's three buffers plus `displayedStore` when the rotation has already
  outlived it -- `.purgeableVolatile`, recording `IOSurface.isInUse` at that
  instant. `swapchain` and `displayedStore` are left exactly as they were: this
  shape gives up the pixels, not the buffers. On `setVisible(true)` the view
  marks every one of them non-volatile, reads the returned old state, then calls
  `requireEveryBufferToRenderAgain()` and `rerenderCurrentPlan()`
  **unconditionally**, not only when a buffer came back empty. Unconditional is
  both simpler and the right thing to price: the layer has no contents while the
  pane is hidden, so a reveal must render whatever the kernel did, and every
  buffer other than the displayed one is stale regardless.

  The two observations ride in the presentation trace as new event kinds rather
  than as a payload field, so `tab-switch-latency.py`'s line format does not
  change: `hideVolatileFree`, `hideVolatileInUse` and `hideVolatileFailed` at
  hide; `revealIntact`, `revealDiscarded`, `revealNonVolatile` and `revealFailed`
  at reveal.
- Result or artifact paths:
  [readings/2026-09-01-951b4393-t6-tabs-empty-visible.json](readings/2026-09-01-951b4393-t6-tabs-empty-visible.json)
  (`S5`),
  [readings/2026-09-01-951b4393-tabs-empty-visible.json](readings/2026-09-01-951b4393-tabs-empty-visible.json)
  (`S6`, the control),
  [readings/2026-09-01-951b4393-t6-vmmap-regions.txt](readings/2026-09-01-951b4393-t6-vmmap-regions.txt),
  [readings/2026-09-01-951b4393-t6-vmmap-summary.txt](readings/2026-09-01-951b4393-t6-vmmap-summary.txt),
  [readings/2026-09-01-951b4393-t6-footprint.txt](readings/2026-09-01-951b4393-t6-footprint.txt),
  [readings/2026-09-01-951b4393-vmmap-regions.txt](readings/2026-09-01-951b4393-vmmap-regions.txt),
  [readings/2026-09-01-951b4393-footprint.txt](readings/2026-09-01-951b4393-footprint.txt),
  [readings/2026-09-01-951b4393-t6-tab-switch-latency.json](readings/2026-09-01-951b4393-t6-tab-switch-latency.json),
  [readings/2026-09-01-951b4393-t6-presentation-events.jsonl](readings/2026-09-01-951b4393-t6-presentation-events.jsonl)
  (the raw trace the hide and reveal counts come from),
  [readings/2026-09-01-951b4393-t6-reveal-tab-a.png](readings/2026-09-01-951b4393-t6-reveal-tab-a.png)
  and
  [readings/2026-09-01-951b4393-t6-reveal-tab-b.png](readings/2026-09-01-951b4393-t6-reveal-tab-b.png)
  (the on-screen check),
  [readings/2026-09-01-951b4393-t6-throwaway.diff](readings/2026-09-01-951b4393-t6-throwaway.diff).
- Measurements.

  **The footprint, both arms of one session, ten empty tabs at 170x60.** Ten
  samples at 1 s after a 5 s settle, one pid each, all ten panes measured on both
  arms.

  | Arm | Commit | n | Median bytes | Spread | Surfaces (app) |
  |---|---|---:|---:|---:|---|
  | modified, idle | `951b4393+T6` | 10 | **98,501,952** | 606,208 | 607,518,720 (30 stores, 10 chains, 9/10 hidden) |
  | control, same session | `951b4393` | 10 | 645,039,424 | 458,752 | 607,518,720 (30 stores, 10 chains, 9/10 hidden) |
  | `S4`, prior session | `2c544f84` | 10 | 644,777,256 | 475,136 | 607,518,720 (30 stores, 10 chains, 9/10 hidden) |

  The contemporaneous delta is **546,537,472 bytes**, 84.7% of the control
  total. Twenty-seven surfaces at the page-rounded 20,250,624 bytes `F4`
  measured are 546,766,848, so the drop is 0.04% below the whole of the hidden
  panes' surface term. The app's own attribution did not move by one byte on
  either arm, which is what `D4` said it would do: `allocationSize` is mapped
  size, and mapped size is what a volatile surface keeps.

  **No memory pressure was applied, and none was needed.** `memory_pressure -l
  warn` was the fallback for the case where volatile pages stay in the footprint
  until the kernel reclaims them. That case did not happen: the footprint was
  already 98.5 MB at idle, one settle after the tabs were staged.

  **The `PURGE` census, on the held pid of each arm.** Every `2720x1860 (BGRA)`
  region, owner `'DanTerm Dev (1)'`:

  | Arm | `2720x1860` regions | `PURGE=V` | `PURGE=N` | Dirty on the V regions |
  |---|---:|---:|---:|---|
  | modified | 30 | 27 | 3 | `0K` on every one |
  | control | 30 | 0 | 30 | `19.3M` on every one |

  The three `PURGE=N` regions in the modified arm are the visible pane's
  rotation, and one of them carries `shared with WindowServer[471]`. The
  modified process has no `PURGE=V` region outside those 27. The tools agree
  with each other:

  | Tool | modified | control |
  |---|---|---|
  | `footprint`, process total | 94 MB | 615 MB |
  | `footprint`, `IOSurface` dirty | 58 MB (32 regions) | 580 MB (31 regions) |
  | `footprint`, `IOSurface` reclaimable | 521 MB | 0 B |
  | `vmmap --summary`, `IOSurface` | 579.5M virtual, 58.1M dirty, 32 regions | not captured |

  `MALLOC_SMALL` is 25 MB on both arms, so nothing outside the surfaces moved.

  **Question one -- do volatile IOSurface pages leave `phys_footprint` on this
  macOS?** Yes, at once, with no memory pressure. `footprint` moves the bytes
  from `Dirty` to `Reclaimable` and stops counting them in the total.

  **Question two -- has the render server released the surface by the time it
  goes volatile?** No. Across 44 hide episodes in the traced run -- three stores
  each, 132 store observations -- the split was identical every time:

  | Per hide episode | Stores | Episodes |
  |---|---:|---:|
  | `hideVolatileFree` (`isInUse` false) | 2 | 44 of 44 |
  | `hideVolatileInUse` (`isInUse` true) | 1 | 44 of 44 |
  | `hideVolatileFailed` | 0 | 0 |

  That is 88 free and 44 in use, and the one in use is the attached buffer, every
  time. The detaching `CATransaction` was committed **and**
  `CATransaction.flush()`ed before the read, and the surface was still reported
  in use. This agrees with pin two of
  `tests-ui/IOSurfaceLayerContentsTests.swift` -- freeing is presentation-driven,
  and a hidden pane presents nothing -- but this experiment marks the surface
  volatile anyway. Nothing bad was observed: the pane is off screen, `PURGE=V`
  took on all 27 hidden surfaces including the 9 that were attached at their
  hide, and no reveal in the whole session found a discarded buffer.

  **What the kernel did to the pages.** Across 35 reveals, 105 store
  observations:

  | Reveal old state | Count |
  |---|---:|
  | `revealIntact` (`kIOSurfacePurgeableVolatile`, pages survived) | 105 |
  | `revealDiscarded` (`kIOSurfacePurgeableEmpty`) | 0 |
  | `revealNonVolatile` | 0 |
  | `revealFailed` | 0 |

  The machine was never under memory pressure during the run, so the discarded
  path is **unmeasured**, not measured as never happening. A reveal after a real
  discard is the case this reading does not price.

  **The latency, modified build, n=12 per case, `F5`'s staging exactly.**

  | Case | n | Median | Min | Max | `F5` at `2c544f84` |
  |---|---:|---:|---:|---:|---|
  | Hidden tab revealed, reveal to frame | **12 of 12** | **1.37 ms** | 0.80 ms | 2.34 ms | no frame (0 of 12) |
  | Hidden tab revealed, request round trip | 12 | 78.33 ms | 28.81 ms | 179.77 ms | 27.90 ms |
  | Warm visible tab reselected, round trip | 12 | 53.43 ms | 10.41 ms | 215.88 ms | 35.98 ms |
  | Cold first presentation, create to frame | 12 | 9.43 ms | 8.78 ms | 13.12 ms | 18.90 ms |
  | Swapchain rebuild on a visible pane | 12 | 6.32 ms | 5.69 ms | 10.89 ms | 16.59 ms |

  The last four rows are not comparable across sessions: the cold and rebuild
  cases both read about 2.5x faster here than in `F5`'s session on a code path
  this change does not touch, so the machine state differs, and the two
  round-trip rows are dominated by the `danterm` CLI spawn in both. The
  in-session comparison is the one that carries: **a reveal of a hidden pane
  costs 1.37 ms, and a from-scratch swapchain rebuild in the same run costs
  6.32 ms.** The volatile reveal is 4.6x cheaper than the work a
  visible-lifetime release would have to do on every reveal, measured on the
  same build in the same session.

  Instrument overhead: 200 timed writes of one trace line against the file the
  app appends to, median 1,667 ns, max 37,666 ns. One such write falls inside
  the reveal-to-attach interval, 0.12% of the 1.37 ms median. The change adds
  three lines per hide and three per reveal; all of them are outside the
  measured interval except the reveal's own `reveal` line, which `F5` carried
  too.

  **On-screen correctness.** Two tabs in a debug slot, each with distinct text
  on screen. Switching away and back rendered the correct content in both
  directions, captured in the two PNGs above. A spot check, not a suite.
- Observation: the whole of the hidden-pane surface term leaves the process
  footprint the moment the surfaces are marked volatile, and the reveal that
  buys it back is a real frame in 1.37 ms rather than the 6.32 ms a rebuild
  costs or the "no frame at all" the app shows today. The surfaces stay mapped
  and stay owned, so nothing about the swapchain's shape, depth or acquisition
  rule changes, and the depth-3 rule the README protects is untouched.
- Inference: for `D2` this shape beats visible-lifetime release on both axes at
  once. It takes the same 546 MB -- 27 of 30 surfaces, which is also the most
  visible-lifetime release could take, because the visible pane must keep its
  rotation -- and it does it with a reveal 4.6x cheaper than the rebuild that
  shape must pay. It beats one-frozen-surface-per-hidden-pane on memory: the
  frozen shape leaves 9 resident surfaces, 182 MB, where this leaves none. Its
  reveal is dearer than the frozen shape's, which shows its old frame with no
  render at all, but 1.37 ms buys a *current* frame, which is a correctness
  property the frozen shape has to solve separately.
- Competing interpretations: the 546 MB is a `phys_footprint` fact, not a
  physical-memory fact. The pages are still mapped and, while intact, still
  backed; the kernel has been told it may take them and has not. Under real
  pressure the same reading would show the discard the process is now exposed
  to -- which is the point of the mechanism, but it means the win is "the
  process stops being charged" rather than "the machine gets 546 MB back now".
  The 1.37 ms reveal is likewise the intact-pages case only; a reveal whose
  buffer came back `Empty` needs the same full render, so its cost should be
  nearer the 6.32 ms rebuild less the allocation.
- Uncertainty: one session, one machine, one geometry, one arm, one build of
  each side. The discarded-pages reveal is unmeasured. The staged tabs are idle
  (`exec sleep`), so a hidden pane with pending output is unmeasured here as it
  was in `F5`. The on-screen check is two tabs by hand, not a test.
- Correctness seam that remains, and it is the real one: **a surface goes
  volatile while the render server still holds it**, 44 times out of 44. For the
  pane's own hidden window that is invisible, but the system composites hidden
  content in places the app does not control -- Mission Control, window
  thumbnails, screen capture, an app-switcher preview. A discard under pressure
  would put undefined pixels wherever the render server draws from that surface,
  and `IOSurfaceRef.h:438-440` says exactly that: a surface marked volatile and
  later found empty leaves "any texture objects bound to the IOSurface" with
  "undefined content in them". The ideal shape marks only the surfaces the
  render server reports free and leaves the attached one non-volatile until it
  goes free -- that costs 9 of the 546 MB at this staging, about 182 MB of the
  saving if the attached buffer never frees while hidden, and removes the hazard
  entirely. Which of those two it costs is the one measurement this experiment
  owes before `D2` is written, and it is a variant of the same throwaway.
- Next action: `T7`. `D2` now has `F4`, `F5` and `F8`; `F7` is `T5`'s. If `D2`
  selects this direction, `D2`'s behavioral coverage needs one more line: a
  hidden pane's surface is never marked volatile while `isInUse` reports the
  render server still holds it.

### F9 -- `D2` is implemented: the ten-tab idle baseline is 56.9 MB, and the volatile fast path buys no latency over the ideal

- Acted on by `D5`: commit 2 was reverted in `3c5dfef6` on this reading; the
  numbers below stand as measured.
- Status: recorded; the `T8` implementation reading, taken on both landed
  commits in one session. It is a tier-1 pair, not the tier-2 claim `D3`
  requires; `T9` still owes that.
- Date and investigator: 2026-09-01, agent session, on the machine `F1` ran on.
- Commit and worktree state: branch `research41`, clean tree, two commits.
  - `8ccdec4d` -- `T8` commit 1, `D2`'s ideal: hide detaches the layer contents
    in a committed and flushed transaction, drops `displayedStore`, and discards
    the swapchain; nothing presents while hidden; the reveal reconciles the
    geometry and renders once.
  - `471e8c01` -- `T8` commit 2, the fast path: hide keeps the rotation and
    calls `TerminalFrameSwapchain.releasePixels()`, which marks every buffer
    `IOSurfaceIsInUse` reports free `kIOSurfacePurgeableVolatile` and reports how
    many the render server still holds; a bounded per-refresh retry re-asks about
    those; the reveal calls `reclaimPixels()` and replaces the rotation when any
    buffer came back `Empty` or refused.
- Commands, inputs, or reproduction, in the order run, on one staged slot each:

      python3 scripts/research/41/ten-tab-footprint.py        # 471e8c01
      python3 scripts/research/41/tab-switch-latency.py --samples 12  # 471e8c01
      python3 scripts/research/41/ten-tab-footprint.py        # 8ccdec4d
      python3 scripts/research/41/tab-switch-latency.py --samples 12  # 8ccdec4d

- Result or artifact paths:
  [readings/2026-09-01-471e8c01-tabs-empty-visible.json](readings/2026-09-01-471e8c01-tabs-empty-visible.json)
  (`S9`),
  [readings/2026-09-01-471e8c01-tab-switch-latency.json](readings/2026-09-01-471e8c01-tab-switch-latency.json),
  [readings/2026-09-01-8ccdec4d-tabs-empty-visible.json](readings/2026-09-01-8ccdec4d-tabs-empty-visible.json)
  (`S10`),
  [readings/2026-09-01-8ccdec4d-tab-switch-latency.json](readings/2026-09-01-8ccdec4d-tab-switch-latency.json).
- Measurements.

  **The footprint, ten empty tabs at 170x60, one pid, all ten panes measured on
  both arms.** Ten samples at 1 s after a 5 s settle.

  | Arm | Commit | n | Median bytes | Spread | Surfaces, mapped (app) | Surfaces, non-volatile (app) |
  |---|---|---:|---:|---:|---|---|
  | commit 1 + 2 | `471e8c01` | 10 | **56,902,928** | 475,160 | 607,518,720 (30 stores, 10 chains) | 60,751,872 (3 of 30 stores) |
  | commit 1 alone | `8ccdec4d` | 10 | **56,935,312** | 491,520 | 60,751,872 (3 stores, 1 chain) | 60,751,872 (3 of 3 stores) |

  Against `S4`'s 644,777,256 at `2c544f84`, that is 587.8 MB gone, 91% of the
  baseline `F1` opened on. The two arms differ by 32,384 bytes, 0.06%, which is
  inside both spreads: **the volatile fast path took no bytes commit 1 had not
  already taken.** That is what `D2`'s table predicted -- both shapes leave the
  same residual, which is zero here -- and it is why the arms are worth
  distinguishing only by what they cost a reveal.

  **The census the arms disagree about.** Commit 1 leaves a hidden pane no
  rotation, so nine of ten panes report `"swapchain": null` and the app
  attributes three surfaces. Commit 2 keeps all thirty mapped and marks
  twenty-seven volatile, so the mapped figure is `S3`'s 607,518,720 to the byte
  and the new `nonVolatileBytes` is 60,751,872. Both arms therefore say the
  process is charged for exactly the visible pane's three buffers, and both
  medians agree with that.

  **The latency, n=12 per case, `F5`'s staging exactly, both arms in the same
  session.**

  | Case | `471e8c01` | `8ccdec4d` | `F8` at `951b4393+T6` | `F5` at `2c544f84` |
  |---|---|---|---|---|
  | Hidden tab revealed, reveal to frame | **4.76 ms** (12 of 12; 0.80--4.94) | **4.61 ms** (12 of 12; 2.44--5.25) | 1.37 ms | no frame (0 of 12) |
  | Swapchain rebuild on a visible pane | 5.12 ms (2.50--5.70) | 4.59 ms (2.70--5.32) | 6.32 ms | 16.59 ms |
  | Cold first presentation, create to frame | 13.89 ms | 14.07 ms | 9.43 ms | 18.90 ms |
  | Warm visible tab reselected, round trip | 26.02 ms | 23.99 ms | 53.43 ms | 35.98 ms |

  **The fast path did not reproduce `F8`'s advantage.** In `F8`'s session a
  volatile reveal was 1.37 ms against a 6.32 ms rebuild, 4.6x. Here the reveal
  costs 4.76 ms with the pages kept and 4.61 ms with the rotation rebuilt from
  scratch, which is the same number within the spread of either. The rebuild
  itself is the term that moved: `F5` measured it at 16.59 ms, and it is 4.6 ms
  in this branch. `T5` is the difference -- a fresh rotation no longer `memset`s
  three whole surfaces on creation, so the allocation the ideal pays on every
  reveal costs almost nothing, and what is left in both arms is the one full
  render a reveal must do either way.

  **The render server does let go, and quickly.** `D2`'s uncertainty 1 is
  answered. At every hide the split was `F8`'s exactly -- two buffers free, one
  still in use, 0 failures -- and the bounded retry then found that buffer free
  after 1 to 3 ticks in every episode the trace window captured; the budget
  (120 ticks) never expired, and the idle census after the settle reads 27 of 27
  hidden buffers volatile, so the residual is **0 surfaces, 0 bytes**, not the
  0-to-182 MB `D2` allowed for. Across 12 reveals the trace recorded 36
  `revealIntact` and no `revealDiscarded`, `revealNonVolatile`, `revealFailed`,
  or `hideVolatileFailed`.

  Instrument overhead: 200 timed writes of one trace line, median 2,125 ns, max
  42,375 ns; one such write falls inside the reveal-to-attach interval, 0.04% of
  the 4.76 ms median.
- Observation: `D2`'s two properties both hold in the tree, and the idle
  baseline is 56.9 MB in both arms. The reveal now presents a real frame, which
  it did not at `F5`, and costs 4.6 to 4.8 ms whichever arm is in.
- Inference: **commit 2 is not earning its structure on this evidence.** It buys
  0.06% of the bytes and no measurable reveal latency over commit 1, and it costs
  one purgeability state per buffer, a bounded retry, a three-way reclaim
  outcome, and a census field. `D2` said in as many words that if commit 2's
  measurement shows its state does not earn its latency, dropping commit 2
  leaves the ideal in the tree, and that is what these numbers say. The counter
  is that `F8`'s 1.37 ms was real on a build without `T5`: what removed the fast
  path's advantage is that `T5` made the ideal's rebuild cheap, so the two are
  coupled and dropping either changes the other's price. The census field earns
  its keep either way -- it is what makes a volatile saving attributable at all.
- Competing interpretations: the reveal medians could be dominated by a term
  neither commit touches (the fence, the plan, the AppKit commit), in which case
  both arms are measuring that term and the fast path's advantage is real but
  below it. `F8`'s 1.37 ms argues against a floor that high, but `F8`'s session
  also read the cold and rebuild cases about 2.5x faster than `F5`'s, so
  cross-session comparison is weak here and only the in-session pair carries.
- Uncertainty: one session, one machine, one geometry, the empty arm only, and
  tier 1 rather than tier 2. The discarded-pages reveal is still unmeasured --
  no `revealDiscarded` occurred, because no memory pressure was applied. The
  staged tabs are idle, so a hidden pane with pending output is unmeasured. What
  a window thumbnail shows for an occluded window whose panes are detached
  (`D2`'s uncertainty 4) was not checked.
- Next action: `T9` -- the tier-2 pair against the pre-change commit, plus the
  `memory_pressure` discard reading, and the decision on whether commit 2 stays.

### F10 -- the tier-2 claim: 644 MB to 57 MB idle, 821 MB to 273 MB with scrollback, against an 82 KB noise floor

- Status: recorded; `T2b` and `T9`. The doc's first tier-2 rows, its first A/A
  noise floor, and the paired claim `D3` has been owed since `T0`.
- Date and investigator: 2026-09-01, agent session, on the machine `F1` ran on.
- Commit and worktree state: four checkouts of this repo, each built into its
  own optimized slot inside one run.
  - `951b4393` -- the pre-research baseline, the last commit before `T5`; the
    `S1`-through-`S4` family. Linked worktree.
  - `ed59e1fb` -- `T5` in the tree, `T8` not yet. Linked worktree.
  - `296284d6` -- `HEAD`, the shipped shape: `T5` plus `T8` commit 1, with
    commit 2 reverted (`D5`). Measured **twice**, from the main checkout and
    from a linked worktree of the same commit; that pair is `T2b`.
  - `76920c1c` -- `296284d6` plus one research-script fix, for the tier-1
    readings taken beside the run. No app code differs.
- Commands, inputs, or reproduction:

      cd ~/Code/termwars && python3 -m termwars memory --terminals \
        "danterm,danterm@<wt>/r41-aa,danterm@<wt>/r41-pre,danterm@<wt>/r41-t5"

      python3 scripts/research/41/ten-tab-footprint.py          # twice
      python3 scripts/research/41/tab-switch-latency.py --samples 12

  Ten tabs, 170x60 read back on every pane, Menlo 13 seeded into each slot's
  own config, 2x display, 60 s settle, 60 s sampled at 1 s, both arms, three
  round-robin interleaved reps. Host `MacBookPro18,1`, macOS 26.5.2.
- Result or artifact paths:
  [readings/2026-09-01-memory-harness-t2b-t9.json](readings/2026-09-01-memory-harness-t2b-t9.json)
  (`S11`-`S18`; the receipt is also
  `~/Code/termwars/results/memory-2026-09-01-202939.json`),
  [readings/2026-09-01-76920c1c-tabs-empty-visible.json](readings/2026-09-01-76920c1c-tabs-empty-visible.json)
  (`S19`),
  [readings/2026-09-01-76920c1c-tabs-empty-visible-repeat.json](readings/2026-09-01-76920c1c-tabs-empty-visible-repeat.json)
  (`S20`),
  [readings/2026-09-01-76920c1c-tab-switch-latency.json](readings/2026-09-01-76920c1c-tab-switch-latency.json).
- Measurements.

  **Coverage first.** All 24 trials returned `ok`. Every one sums **one pid**,
  reports an **empty `missingPids`** on all 56 of its samples, and read
  `170x60` back on all ten panes (`gridVerified: true`). No reading here has a
  missing pid, so no row is disqualified. The 56 samples inside a trial are
  byte-identical in all 24 trials, so a row's spread is the span of its three
  rep medians and nothing else.

  **The A/A noise floor (`T2b`).** The same commit, built from two checkouts
  into two slots, interleaved.

  | Arm | `S15` main checkout | `S17` worktree twin | Difference | Relative |
  |---|---:|---:|---:|---:|
  | tabs-empty-visible | 56,525,712 | 56,443,816 | **81,896** | **0.145%** |
  | tabs-scrollback-visible | 272,974,880 | 273,974,304 | **999,424** | **0.366%** |

  Nothing below is read as a delta unless it clears these.

  **The claim (`T9`), pre against post, both arms.** n is samples; the reps
  are three per row.

  | Arm | `951b4393` (`S11`, `S12`) | `296284d6` (`S15`, `S16`) | n pre / post | Spread pre / post | Delta | Percent | Delta / floor |
  |---|---:|---:|---:|---:|---:|---:|---:|
  | tabs-empty-visible | 644,089,152 | **56,525,712** | 167 / 168 | 147,480 / 196,632 | **-587,563,440** | **-91.22%** | **7,175x** |
  | tabs-scrollback-visible | 821,396,896 | **272,974,880** | 168 / 168 | 1,654,784 / 360,472 | **-548,422,016** | **-66.77%** | **549x** |

  Read against the A/A twin instead of the main checkout, the same deltas are
  -587,645,336 (-91.24%) and -547,422,592 (-66.65%): the choice of which HEAD
  build is "the" post arm moves the claim by less than the floor, which is what
  the floor was measured to establish.

  **Where the bytes went, split by the optional third revision (`S13`, `S14`).**

  | Arm | `951b4393` | `ed59e1fb` (`T5` only) | `296284d6` (`T5`+`T8`) | `T5`'s share | `T8`'s share |
  |---|---:|---:|---:|---:|---:|
  | empty | 644,089,152 | 279,626,928 | 56,525,712 | -364,462,224 (62.0%) | -223,101,216 (38.0%) |
  | scrollback | 821,396,896 | 497,861,952 | 272,974,880 | -323,534,944 (59.0%) | -224,887,072 (41.0%) |

  Both steps are thousands of times the floor (4,450x and 2,724x on the empty
  arm), so the split is a claim in its own right and not an artifact of one
  ordering.

  **The scrollback arm's own line.** Scrollback minus empty is 177,307,744 at
  `951b4393`, 218,235,024 at `ed59e1fb`, and 216,449,168 at `296284d6`. The
  terminal-state line did not shrink; it appears to have **grown by 39,141,424
  bytes**, and that growth is `T5`'s, not a regression. It is already present at
  `ed59e1fb`, `T8` does not move it (the two post rows differ by less than the
  scrollback spread), and it is 96.6% of two 20,250,624-byte surfaces: the
  visible pane's two never-rendered buffers cost nothing in the empty arm and
  fault in the moment that pane renders scrollback output. This is `F7`'s
  fault-back table showing up at the process level, and it is exactly the
  investigation rule that says an idle-only saving is priced in both arms.

  **The two tiers agree (`D3`).** Same session, minutes apart.

  | Reading | Tier | Median | Spread | n |
  |---|---|---:|---:|---:|
  | `S19` script, `76920c1c` | 1 | 57,000,848 | 65,536 | 10 |
  | `S20` script, `76920c1c` | 1 | 56,738,728 | 98,304 | 10 |
  | `S15` harness, `296284d6` | 2 | 56,525,712 | 196,632 | 168 |
  | `S17` harness, `296284d6` | 2 | 56,443,816 | 114,688 | 168 |

  The widest gap between a tier-1 and a tier-2 total is 557,032 bytes, 0.99%,
  and the tier-1 band sits above the tier-2 band, which is what a 5 s settle
  against a 60 s one predicts. `D3`'s assertion that the two tiers read the same
  quantity at different rigor holds. The other half of that assertion also
  holds, and is the reason `D3` exists: `S19` and `S20` are the *same build read
  twice by tier 1* and differ by 262,120 bytes, **3.2x the tier-2 A/A floor**.

  **The pre arm reproduces the trigger.** `F1`'s archived receipt read
  644,465,984 empty and 818,709,944 scrollback at `5f5ecfea`. `S11` and `S12`,
  six hours later at `951b4393` with three reps instead of one, read 644,089,152
  and 821,396,896 -- 0.06% and 0.33% away. The pre arm is the same machine state
  the doc opened on. The other three terminals were not re-measured in this run,
  so `F1`'s kitty, Ghostty and iTerm2 columns stand as archived and are not
  restated here.

  **Latency beside the bytes (`S19`), n=12 per case, `F5`'s staging.**

  | Case | `76920c1c` | `8ccdec4d` (`F9`) | `2c544f84` (`F5`) |
  |---|---|---|---|
  | Hidden tab revealed, reveal to frame | **5.39 ms** (2.46--6.14) | 4.61 ms | no frame (0 of 12) |
  | Swapchain rebuild on a visible pane | 5.25 ms (3.40--6.17) | 4.59 ms | 16.59 ms |
  | Cold first presentation, create to frame | 14.13 ms (12.70--16.66) | 14.07 ms | 18.90 ms |
  | Warm visible tab reselected, round trip | 23.39 ms (16.31--26.96) | 23.99 ms | 35.98 ms |

  Instrument overhead: 200 timed writes, median 2,292 ns, max 64,000 ns; one
  falls inside the reveal interval, 0.04% of the median. `D5`'s reopening bar is
  a reveal median above 8 ms; 5.39 ms is under it, so the fast path stays out on
  the same arithmetic that removed it.
- Observation: at the ten-tab staging the process holds **56.5 MB idle where it
  held 644.1 MB**, and **273.0 MB with 10,000 lines per tab where it held
  821.4 MB**. Both deltas are hundreds to thousands of times the contemporaneous
  A/A floor. `T5` is the larger half and `T8` the smaller one, in both arms.
- Inference: this is a claim under `D1` and `D3` and not a session artifact. The
  process total moved, the class `F4` attributed moved with it (the census reads
  three surfaces where it read thirty), and the latency is reported beside it
  rather than netted against it -- a reveal now presents a real frame in 5.39 ms
  where it presented none at all. `D1`'s three conditions are met on both arms.
  The A/A pair is what licenses the reading: at 0.145% on the empty arm, a
  91.22% delta is 7,175 floors wide, so no plausible session effect explains it.
- Competing interpretations: the four arms share one machine state, so a drift
  that moved all four equally would cancel and one that moved them unequally
  would show in the interleaving -- the reps are round-robin and each row's three
  rep medians span at most 0.6% (empty) and 1.5% (scrollback). The scrollback
  arm's larger spreads are the writing itself, not the change. The one reading
  that is not from the run is `S19`'s `Switch` cell, taken at `76920c1c`;
  nothing in that commit touches app code.
- Uncertainty: one machine, one geometry, one display scale, one font. The
  discard path under real memory pressure is still unmeasured and now
  unmeasurable in this branch, because `D5` reverted the code that could take it
  (`T9`'s original list had it). The empty arm's remaining 56.5 MB is
  uncensused beyond the three visible surfaces -- that is `T10`. `T4`'s
  scrollback census (H3) is still owed, and the 216.4 MB scrollback line above
  is a total, not an attribution. A first attempt at the latency reading
  returned `unmeasured` on every case (zero trace events) because the launcher
  shim had been silently disconnected; it was fixed in `76920c1c` and re-taken,
  and the instrument's own coverage field is what caught it.
- Next action: `T4` (H3's census) and `T10` (the 56.5 MB remainder). `T2b` and
  `T9` are closed by this finding.

### F12 -- the remainder censused: 25 MB of malloc heap and one 20.25 MB attached buffer, and nothing else over 4.6%

- Status: recorded; `T10`. `H4` **rejected as written**: the remainder is not
  "not one thing". Two classes hold 80.7% of it, and the largest single owner
  inside either of them is 6.4% of the process.
- Date and investigator: 2026-09-01, agent, ledger task `T10`.
- Commit and worktree state: `0dc62749`, tracked tree clean (`dirty: false` in
  the document). No app source and no `TerminalCore` source changed for this
  reading.
- Commands, inputs, or reproduction: `python3
  scripts/research/41/ten-tab-footprint.py --hold`, defaults. While it held
  pid 97272: `vmmap --summary 97272`, `vmmap 97272`, `footprint 97272`,
  `heap -s -guessNonObjects 97272`, `heap -s -z 97272`. None needed `sudo` and
  `heap` did not need the process made debuggable, so the `vmmap -v` fallback
  was not used. `danterm surfaces` was **not** run from the shell: the installed
  CLI predates the command and answered `unknown command`. The census quoted
  below is the same read, taken by the script through the slot's control socket
  from the same process before the hold was released.
- Result or artifact paths:
  [readings/2026-09-01-0dc62749-remainder-tabs-empty-visible.json](readings/2026-09-01-0dc62749-remainder-tabs-empty-visible.json)
  (the sampled document with its `surfaces` block, `S21`),
  [readings/2026-09-01-0dc62749-remainder-vmmap-summary.txt](readings/2026-09-01-0dc62749-remainder-vmmap-summary.txt),
  [readings/2026-09-01-0dc62749-remainder-vmmap-regions.txt](readings/2026-09-01-0dc62749-remainder-vmmap-regions.txt),
  [readings/2026-09-01-0dc62749-remainder-footprint.txt](readings/2026-09-01-0dc62749-remainder-footprint.txt),
  [readings/2026-09-01-0dc62749-remainder-heap.txt](readings/2026-09-01-0dc62749-remainder-heap.txt),
  [readings/2026-09-01-0dc62749-remainder-heap-zones.txt](readings/2026-09-01-0dc62749-remainder-heap-zones.txt).
- Measurements.

  **Coverage first.** Ten panes, all ten read back at `170x60`, one pid, empty
  `missingPids`, `fontVerified` and `foregroundVerified` true. Median
  `phys_footprint` **57,672,616** bytes over ten samples, spread 475,136.
  `vmmap` read the same process at `55.0M` -- 57,671,680 bytes, 936 bytes from
  the median -- so the class capture and the sampled row are the same moment to
  within 0.002%. Every share below is against 57,672,616. The app's own census
  read **60,751,872 bytes in 3 stores, 1 chain, 9 of 10 panes hidden, 0 panes
  unmeasured**, which is `T8`'s shape holding: nine hidden panes own no pixels.
  `phys_footprint_peak` is 99 MB, from the staging, not from the idle state.

  **The class table.** Dirty bytes as `footprint` prints them, with the region
  count each sums. `footprint` rounds above 1 MB, so the MB figures carry the
  tool's precision and no more; the `IOSurface` line is exact because the
  surface geometry pins it.

  | Category | Regions | Dirty | Share |
  |---|---:|---:|---:|
  | `MALLOC_SMALL` | 16 | 25 MB | 45.4% |
  | `IOSurface` | 5 | 20,381,696 | 35.3% |
  | `CoreAnimation` | 65 | 2592 KB | 4.6% |
  | `__DATA_DIRTY` | 869 | 1834 KB | 3.3% |
  | `__DATA` | 962 | 1212 KB | 2.2% |
  | `MALLOC metadata` | 12 | 1072 KB | 1.9% |
  | everything under 1 MB, 22 categories | 5264 | 3979 KB | 7.1% |

  The 22 small categories, largest first: page table 641 KB, CG image 592 KB,
  untagged `VM_ALLOCATE` 448 KB, CoreUI image data 400 KB, `__AUTH` 349 KB,
  `MALLOC_TINY` 288 KB, unused dyld shared cache 285 KB, stack 192 KB,
  `__DATA_CONST` 160 KB, Accelerate image backing stores 128 KB, `__AUTH_CONST`
  112 KB, `__TPRO_CONST` 112 KB, and ten more at 64 KB or less. `__TEXT` is
  4656 KB and entirely clean, so it is not in the footprint.

  **The `IOSurface` line, mapped against resident.** Three regions, one per store
  of the visible pane's depth-3 swapchain, `2720x1860 (BGRA)`, 20,250,624 bytes
  each, 60,751,872 mapped -- exactly the app's own census. Only **one** is
  resident: `SurfaceID 0x5b`, the one marked `shared with WindowServer[471]`,
  20,250,624 bytes dirty. The other two read `19.3M` virtual and `0K` resident,
  which is `T5`'s removed clear showing at the region level: a buffer never
  rendered into costs no pages. So **33.3% of the mapped surface bytes are
  resident**, and 40,501,248 bytes are mapped and untouched. The class's other
  two regions are one `240x240 (LA08)` `CoreUI image IOSurface` at 131,072 bytes
  and one 16 KB read-only region with no dirty pages.

  **`MALLOC_SMALL` split by `heap`.** Six zones, 105,478 nodes,
  **18,057,352 bytes live**. The zone table puts `DefaultMallocZone` at 24.8M
  dirty against 16.8M allocated -- **8178 KB, 33%, of dirty-and-swapped
  fragmentation**. So the 25 MB class is roughly 18.1 MB of live allocations and
  7 to 8 MB of small-zone slack.

  Live bytes by owner, from `heap`'s per-class table grouped by binary image:

  | Owner | Nodes | Bytes | Of live heap | Of process |
  |---|---:|---:|---:|---:|
  | DanTerm and engine Swift types | 2518 | 4,596,432 | 25.5% | 8.0% |
  | AppKit, CoreAutoLayout, Foundation, CoreUI | 35,105 | 3,735,027 | 20.7% | 6.5% |
  | `non-object` (untyped malloc, no backtrace) | 19,528 | 3,413,307 | 18.9% | 5.9% |
  | CoreFoundation containers | 23,168 | 2,188,736 | 12.1% | 3.8% |
  | CoreGraphics, CoreText, QuartzCore, CoreSVG | 8468 | 1,436,272 | 8.0% | 2.5% |
  | ObjC and block runtime | 9677 | 1,314,880 | 7.3% | 2.3% |
  | Swift runtime and stdlib | 3252 | 942,360 | 5.2% | 1.6% |
  | everything else, 14 images | 3230 | 430,338 | 2.4% | 0.7% |

  **`heap`'s top ten classes by bytes.**

  | Class | Count | Bytes | Of process | Scope |
  |---|---:|---:|---:|---|
  | `Swift._ContiguousArrayStorage<TerminalCore.Terminal.GridCell>` | 1200 | 3,686,400 | 6.4% | per pane |
  | `non-object` | 19,528 | 3,413,307 | 5.9% | mixed |
  | `Class.methodCache._buckets` | 1181 | 887,232 | 1.5% | per process |
  | `Swift Metadata` | 38 | 398,784 | 0.7% | per process |
  | `NSMutableDictionary (Storage)` | 1289 | 315,760 | 0.5% | per process |
  | `_NSViewLayoutAux` | 623 | 279,104 | 0.5% | per view |
  | `Swift._ContiguousArrayStorage<Swift.UInt8>` | 428 | 246,896 | 0.4% | mixed |
  | `CFString` | 4702 | 246,832 | 0.4% | per process |
  | `CGPath[48]` | 237 | 238,784 | 0.4% | per process |
  | `CGRegion[16]` | 106 | 206,336 | 0.4% | per process |

  **Per pane against per process.** Ten of a thing is per pane, and the counts
  say so directly. The engine's per-pane classes:

  | Class | Nodes | Bytes | Per pane |
  |---|---:|---:|---:|
  | `GridCell` row arrays | 1200 (120 per pane) | 3,686,400 | 368,640 |
  | Flight-recorder `_DequeBuffer`s | 16 | 105,472 | 10,547 |
  | `_DequeBuffer<Terminal.GridRow>` | 24 | 60,928 | 6093 |
  | `TerminalPTYHost` | 10 | 30,720 | 3072 |
  | `RenderPlanRow` arrays | 10 | 25,600 | 2560 |
  | Style tables, both directions | 20 | 10,240 | 1024 |
  | Semantic events, kitty flags, PTY sources, pending input, line-store blocks | 50 | 6400 | 640 |
  | **Total** | | **3,925,760** | **392,576** |

  The 1200 `GridCell` arrays are 120 per pane: 60 rows on the primary screen and
  60 on the alternate. Each is 3072 bytes, and that number is bucket rounding --
  170 columns at `MemoryLayout<GridCell>.stride` of 16 is 2720 bytes, plus a
  32-byte array header is 2752, and the small zone's 512-byte quantum rounds it
  to 3072. **11.6% of the largest per-pane class is the allocator's rounding**,
  384,000 bytes over the ten panes.

  Per process, the app's own largest heap objects are the theme table
  (`_DictionaryStorage<String, DanTermTheme>`, 114,688 bytes), the tab-model
  array (114,688), and the theme colour arrays (592 nodes, 56,832). Everything
  else on the app's side is under 30 KB. The only per-pane AppKit signal the
  class names carry is `_NSViewLayoutAux` at 623 nodes; a pane's view tree is
  not one object, so the AppKit and CoreAutoLayout band cannot be split by name
  and needs a per-tab slope instead (`T14`).
- Observation: the idle ten-tab process is two classes and a tail. One malloc
  heap of 25 MB, whose largest single owner is 3.69 MB and a third of which is
  allocator slack. One resident IOSurface of 20,250,624 bytes, which is the
  pixels the user is looking at. Nothing else in the process reaches 4.6%.
- Inference: `H4` said the remainder was "not one thing", with nothing dominant,
  and that is now wrong in both halves. Two classes hold 80.7% of it. But the
  practical reading it implied survives, for a different reason: the two
  dominant classes are not *reducible* things. The `IOSurface` term is the one
  buffer a displayed pane must have, so releasing it means not showing the pane.
  The `MALLOC_SMALL` term is 105,478 allocations with no owner over 6.4%, so it
  can only be attacked as a long tail or as allocator behaviour, never as one
  fix. The largest per-pane class in the whole process is the grid's cell
  storage at 368,640 bytes per pane, 3,686,400 bytes for ten -- **deleting every
  byte of terminal grid state in all ten panes would save 18% of what one
  visible pane's attached buffer costs.** The next order of magnitude, 57.7 MB
  down to about 6 MB, would have to remove the displayed buffer *and* nearly the
  whole malloc heap, which is AppKit, CoreFoundation, and the ObjC runtime as
  much as it is DanTerm. No single class in this census is worth a plan.
- Competing interpretations: (a) `MALLOC_SMALL` could hide a per-pane term the
  class names do not carry -- `non-object` is 3.41 MB with no type at all, and
  the AppKit band cannot be split by name; `T13` and `T14` are the gates for
  that. (b) The 8 MB of zone fragmentation could be transient, since the process
  peaked at 99 MB during staging and a freed-then-reused heap keeps its pages;
  `T12` is the gate. (c) One capture at one moment, as `F4` was.
- Uncertainty: one build, one host, one geometry, one moment, and an idle state
  reached by staging that peaked at 99 MB. `heap` ran without
  `MallocStackLogging`, so 18.9% of the live heap has no attributable type. The
  census says nothing about the scrollback arm, where `T4` still owes `H3` its
  answer.
- Next action: `H4` is rewritten and replaced by `H5`, `H6`, and `H7`; the
  ledger gains `T12`, `T13`, and `T14`. None of the three is a memory plan --
  each is an attribution gate that decides whether one exists.
