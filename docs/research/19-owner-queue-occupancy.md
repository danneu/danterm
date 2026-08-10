# Owner-queue occupancy and the main-thread fence

Research started: 2026-07-30. **Status: CLOSED -- Phases 1-5 done (`F1`-`F16`,
`D1`-`D4`); see `## Outcome`. The search thread is closed: `C1` is landed and
measured (`257bfee`), and `C2`/`C3`/`C5` are all rejected as premature by `D4`. `C4` (resize) cleared
its gate and is landed as latest-wins coalescing at the host's submission
boundary; `D4`'s claim that it would be measured by a new probe case is corrected
at its own heading. `F15`'s single-settled-resize test ran on 2026-08-05 and came
back on `D4`'s first branch (`F16`): settled resizes are clean and the stacked
prompts need the storm. Every ledger item is now closed. The session's incidental
discovery, rows that stop being painted after a settled resize, is a repaint
defect rather than a reflow one; it moved to
[doc 32](32-post-resize-repaint-loss/README.md), which fixed it in `44b875cd`.
`F16`'s further claim that the resize-storm debris was the shell's own race is
**retracted** -- see the correction at `F16` and `32/F10`. It tracked DanTerm's
zsh integration failing to load, and is gone now that it loads; nothing about it
is open or unowned.**
Deliverable is an inventory of every job that can run on `TerminalPTYHost`'s
serial queue with its bound (or the absence of one), a measured occupancy
distribution for the unbounded ones, and a per-candidate verdict for anything
worth changing.

Phase 1's four results: **20 distinct jobs, of which four have no bound** (`F1`) --
search, select-all, resize/reflow, and the exit-path drain, with the two IO turns
correctly capped-and-re-firing. **The queue is per host** (`F2`), so every
candidate is self-contention: the pane a long job stalls is the pane that asked
for it, which retires the teardown jobs and keeps the three user-facing ones.
**Search is worse-shaped than the seed said** (`F3`): it is O(cells) in
*allocations* before it is a scan, nothing is cached across steps, and one
next-match keypress runs the whole-history scan **twice** because
`searchStatus` recomputes it for the match counter. And **one job is
proportional to the machine rather than to the terminal** (`F4`): the teardown
census enumerates every process on the box and calls `getsid()` per pid, on a
10 ms poll, which no workload-shaped instrument in this project can see.

Phase 2 then measured the three user-facing ones, and they are large. **One search
keystroke holds the pane's queue for 88 ms at a saturated history** -- 5.3 frames
at 60Hz -- and one reflow step for 53.7 ms (`F5`, with copy-on-write ruled out by
control). The cost is **flat per cell across a 27x range** (`F6`: 140 ns/cell for
search, 170 for reflow), so the depth at which each first blows a frame is
arithmetic rather than a measurement: **~333 rows for a search keystroke**, ~548
for a reflow. And the stimulus is worse than per-action: the needle debounce is
**zero for needles of three characters or more** (`F7`), so typing a six-character
term accumulates ~350 ms of occupancy while the user is still typing. `F6` also
corrects `F3`'s emphasis -- the matching loop is 78% of a search and materializing
the projection units is the minority cost.

Phase 3's ranking turns on where that time actually lands. **A search never blocks
the main thread by itself** (`F8`) -- it is enqueued async -- but the consume
task's per-delivery fence is `@MainActor`, so **a search in a pane that is also
producing output becomes an app-wide main-thread block** of the same 88 ms, while
on an idle pane the harm stays confined to a late result. So `D1` ranks a cached
match list first (removes the doubling and makes navigation O(1)), a bounded
re-enqueuing scan second (this file's own rule prefers a bound, but `C1` shrinks
its frequency first), a non-materializing walk third, and reflow fourth pending
its own rate measurement. Raising the search debounce is **not** proposed despite
`F7` -- it hides the cost rather than removing it. `D2` records why none of this
needs a calibrated benchmark rule: no existing workload searches at all, and at
5x-50x the effects are decidable by a stopwatch, so the recommended first commit
is landing `F5`'s probe as a checked-in occupancy benchmark.
Phase 4 took `C1` and it worked, but almost nothing about the plan survived
contact. Chasing the reported symptom first turned up a **correctness bug, not an
occupancy one** (`F10`): an evicted match discarded the whole search including the
needle, so on a streaming pane Enter was not slow, it was dead. That is fixed
(`364af5c`) and it partly re-attributes `F9`. Re-measuring then found the quiet
pane costs **99.3 ms per press, not `F5`'s 88** (`F11`), and that the chop is the
fence rather than the scan -- each queued press also stalls the main actor. Two
structural facts settled the design: **no frame ever reads the match list** (`F12`,
only the single selected match), and **`D1` named the wrong invalidation hook**
(`F13`) -- the right one is `notePrimaryHistoryDamage`, whose own comment already
documents the fail-safe invariant a cache needs, while `D1`'s guess would have
been actively wrong through a `hasInteractionState` hole. `D3` records the result:
held Enter on a quiet saturated pane goes **99.3 ms -> ~0.00 ms**, a new needle
99.3 -> 51.4, and streaming 99.3 -> 48.8 (one scan per press survives there, which
is `C5`'s job now). `D2`'s recommended first commit -- landing the probe as a
checked-in benchmark -- was **not** done, and `D3` says why that was the right call
and what it costs.

Phase 5 closed the search thread by running the comparison `F9` owed, and it came
back **negative** (`F14`): a streaming pane still pays a full 48.8 ms rescan per
press and the user cannot feel it. The model is what that confirms -- `F11`'s
inequality, re-evaluated, puts the queue at ~0.73 utilization instead of above 1.0,
so nothing accumulates and the fence never parks behind a backlog. The durable
result is a **threshold this file had wrong**: `D1` ranked against the 16.7 ms
frame budget, but what predicts felt behavior is the *arrival interval of the
gesture driving the job* (66 ms at default key repeat). On that rule `C5`, `C2`,
and `C3` are all rejected as premature (`D4`) -- each attacks a cost the live app
has already reported as fine -- with a shared reopening condition on scrollback
depth. What is left is **resize**, predicted from source and then confirmed
(`F15`): one reflow per distinct grid with no coalescing, against mouse-move
arrival, for 4x-8x utilization -- the worst ratio in the file. It also forwards one
SIGWINCH per grid to the child, which is visible in the screenshot as four complete
zsh prompt redraws at four different `COLUMNS` values. Whether those *stack* rather
than overwrite because of the storm or because of a reflow cursor bug is
deliberately left open, and `F15` names the twenty-second test that decides it --
`F10` is the standing reason this file does not guess at that seam.
Continues: the fence fix landed in `f75019a` and the read-turn cap in `a990606`
(see `agent-docs/terminal-performance.md`); no prior research doc owns this area.

## Purpose

Docs 9-18 are all about CPU cost per unit of work. This file is about a
different axis that only became load-bearing on 2026-07-29: **how long a single
job holds the owner queue, and who waits behind it.**

`TerminalPTYHost` is the engine's only actor. It binds its `unownedExecutor` to
one `DispatchSerialQueue`, so actor jobs, the read/write dispatch sources, the
child-exit source, and the timers all share a single FIFO. Everything else in
the terminal engine -- `TerminalCore`, `TerminalRenderPlanning`,
`TerminalRenderExecution` -- is pure synchronous value code with no concurrency
of its own, so this queue is the only place in the engine where occupancy is a
question at all.

Two changes made that occupancy matter more than it did:

1. **`f75019a` replaced `await host.frameState()` with a blocking
   `host.fencedFrameState()`.** The drain of damage has to be indivisible from
   the `consume` that records it, which is what the fence buys. The cost is that
   the main thread no longer suspends and reschedules -- it *blocks* until the
   queue reaches it. **Main's per-frame latency floor is now the duration of
   whatever job is already running on the owner queue.**
2. **`a990606` capped the read turn at 16 KiB**, precisely because the read
   handler was the longest routinely-running job and the fence made its length
   visible. That change was measured (mean 5.94 ms / max 6.66 ms stall on a
   flood before the cap; 24% off the termination test after).

The read turn is now bounded. **Nothing established what else on that queue is
unbounded**, and that is this file's question. The read cap was sized against a
flood workload; a job that only runs on user action would never have appeared in
that measurement at all.

## Investigation rules

Inherited and non-negotiable:

- **No implementation of a code candidate before a user direction gate**, per
  `agent-docs/terminal-performance.md`.
- **Never assert an API's behavior from memory** (AGENTS.md "Don't guess"); read
  the local source.
- **On-CPU instrument only for ranking**; a `sample`-derived number is history,
  never a size.

Added here, because the axis is different:

- **Occupancy is wall-clock, not CPU.** A job that blocks on a syscall holds the
  queue exactly as hard as one that burns CPU, and the fence makes main pay for
  both identically. So the usual "re-size it on an on-CPU instrument" rule
  (doc 14's `14/F6`) is *inverted* here: an on-CPU profile would understate
  precisely the jobs that matter most. Size occupancy with
  `lastFenceStallNanoseconds` or with explicit wall-clock brackets.
- **Every size must name the stimulus that produces it.** `17/F17` is the
  cautionary case: a mechanism confirmed at 16.8% under one stimulus read 0.42%
  under a realistic one. A job that is unbounded *in principle* is not
  interesting until a plausible user action makes it long.
- **A bound is worth more than a speedup.** The read path was not made faster; it
  was made to yield and re-fire. Prefer that shape -- chunk and re-enqueue --
  over optimizing a job that remains unbounded, because the second leaves the
  tail in place.
- **The existing instrument reports occupancy, but only where it is polled.**
  `lastFenceStallNanoseconds` accumulates per delivery and flushes at publish, so
  it sees queue time observed *by the fence*. A long job that runs while no frame
  is being published is invisible to it. Say so wherever it is the source.

## Task ledger

### Phase 1 -- inventory the queue's jobs and their bounds

- [x] Enumerate every entry point that reaches the owner queue (63 `queue.async`
      / `assumeIsolated` / `setEventHandler` sites at time of writing) and reduce
      them to the distinct *jobs* that run. Record for each: what triggers it,
      what its work is proportional to, and whether it has a bound. **Done --
      `F1`.**
- [x] Classify each job as bounded (names its limit and its re-fire path),
      bounded-in-practice (names the quantity and why it is small), or unbounded.
      **Done -- `F1`. Four unbounded jobs, one of them a category this file did
      not anticipate (`F4`).**
- [x] For each unbounded job, name the stimulus that would make it long and
      whether that stimulus is realistic. **Done -- `F1`'s table, scoped by `F2`.**
- [x] Establish who can actually be blocked by a long job. **Done -- `F2`, and it
      is narrower than the file assumed: the queue is per host.**

### Phase 2 -- measure the unbounded ones

- [x] Bracket each unbounded job in wall-clock under its named stimulus. **Done --
      `F5`. All three user-facing jobs exceed a 60Hz frame by 3-5x at a saturated
      history, and the per-cell constant is flat across a 27x range (`F6`).**
- [x] Rule out the probe's own confounds before reporting. **Done -- `F5`'s
      copy-on-write control and its degenerate-floor correction.**
- [x] Establish whether the stimulus is per-action or per-keystroke. **Done --
      `F7`, and it is per-keystroke.**
- [x] Cross-check against `lastFenceStallNanoseconds` where a frame is being
      published concurrently, and record where the instrument is blind. **Done --
      `F8`. The stall reaches the main thread only through a fence, the counter
      covers the fence that fires unprompted, and it is blind to the two that a
      user triggers directly.**

### Phase 3 -- rank and pitch

- [x] Rank by measured tail against the frame budget, not by mean. **Done --
      `D1`.**
- [x] For each candidate, state the smallest first experiment and which rule
      decides it. **Done -- `D1`, and `D2` records why no existing calibrated rule
      is needed.**
- [x] User direction gate before any implementation. **Cleared 2026-07-30 for
      `C1` only.** `C2`-`C4` remain gated.

### Phase 4 -- take `C1`

- [x] Diagnose the live-app symptom before optimizing it. **Done -- `F10`, and it
      was a correctness bug rather than occupancy. Fixed in `364af5c`.**
- [x] Re-measure the reported case directly, rather than inferring it from `F5`.
      **Done -- `F11`. 99.3 ms per press, and the fence is the mechanism.**
- [x] Establish what actually reads the match list before caching it. **Done --
      `F12`. No frame does; only search mutations.**
- [x] Find the invalidation seam and prove it with a test that fails against an
      uninvalidated cache. **Done -- `F13`, and `D1`'s named hook was wrong.**
- [x] Land `C1` and measure before/after on the same probe. **Done -- `D3`.**
- [x] Decide `C5` (incremental tail rescan) against the streaming cost `C1`
      leaves. Needs the `--stream` comparison `F9` still owes. **Done -- `F14`.
      The comparison came back negative and `C5` is rejected; `D4` records the
      threshold it changed.**

### Phase 5 -- the search thread is closed; resize is what is left

- [x] Run the `--stream` comparison and decide `C5` on it. **Done -- `F14`.**
- [x] Re-rank `C2`/`C3` against the threshold `F14` established rather than
      against the frame budget `D1` used. **Done -- `D4`. Both rejected as
      premature, with a shared reopening condition on scrollback depth.**
- [x] Test `D1`'s fourth-ranked candidate against the live app before pitching it.
      **Done -- `F15`. Confirmed, and it is a rate problem rather than a cost
      problem, which `H2` had left open.**
- [x] Run the single-settled-resize test from `F15`, which decides whether `C4` is
      a performance change or a correctness bug wearing one. **Done 2026-08-05 --
      `F16`. `D4`'s first branch: settled single resizes are clean and the
      stacking needs the storm. The session's incidental discovery -- rows that
      stop being painted after a settled resize -- is a repaint defect and moved
      to doc 32. The same finding's debris attribution is retracted; see the
      correction at `F16`.**
- [x] ~~Add an N-distinct-grids drain case to `just terminal-occupancy-probe`.~~
      **Dropped, not done.** The probe measures `Terminal` directly and coalescing
      lives above it in the host, so no case it can carry observes the fix; the
      verdict came from a host test instead. See the correction under `D4`.
- [x] User direction gate before any `C4` implementation. **Cleared, and `C4` is
      landed: latest-wins coalescing at the owner-queue submission boundary, with
      any non-resize submission closing the run.**

## Findings

Everything in Phase 1 is read from source, not measured. These are findings about
*structure* -- what is proportional to what, and what has a bound. Every duration
is Phase 2's, and no finding here sizes anything.

### `F1` -- the inventory: four jobs on the owner queue have no bound

Reducing the 63 sites to distinct jobs gives 20. Seventeen are bounded or trivially
small; the table lists only what the classification turns on.

| Job | Trigger | Proportional to | Bound |
| --- | --- | --- | --- |
| `readReady` | read source | bytes available | **16 KiB, re-fires** (`TerminalPTYHost.swift:963`) |
| `flushInput` | write source, any input | pending bytes | **64 KiB, re-fires** (`:878`) |
| `drainCommittedOutput` | `.drainOutput` on exit | `FIONREAD` at entry | **snapshot, no re-fire** (`:1052`) |
| `applySearch` | user search / next / prev | **cells in history** | **none** (`:692`) |
| `applySelectAll` | Cmd-A | **cells in history** | **none** (`:713`) |
| `applyResize` | window drag, split drag | **cells in history** | **none** (`:1107`) |
| `sessionMembers` | teardown, then every 10 ms | **processes on the machine** | **none** (`:1206`) |
| `applyPointer` | mouse move / drag | viewport hit-test | small, viewport-scoped |
| `applyOutput` | inside a read turn | its chunk | inherits the read turn's |
| `childExited` | process source, 5 ms poll | one `waitid` | constant |

The two bounded IO turns are bounded in the shape this file prefers: they cap the
turn and let a level-triggered source re-fire, so the tail is the cap and not the
backlog. **`drainCommittedOutput` looks bounded and is not** -- it reads exactly
the `FIONREAD` count sampled at entry, with no cap and no re-fire, so its length
is whatever the kernel buffer held at that instant. It runs once, on the exit
path.

`applySelectAll` was not in this file's seeds and belongs with `H1`: `selectAll`
(`Terminal.swift:2104`) calls the same `projectionUnits()` that search does, so
Cmd-A on a long history pays `H1`'s cost without needing a needle.

### `F2` -- the queue is per host, which narrows the whole question

`queue` is an instance property assigned in `init` (`TerminalPTYHost.swift:177`),
so **every pane has its own serial queue**, and distinct queues target the global
concurrent queue and genuinely run in parallel. A long job in pane A cannot delay
pane B's fence, its output, or its frames.

That scopes every candidate in `F1` to self-contention: the pane whose frames a
long job delays is the same pane that asked for the long job. It makes the
teardown jobs much less interesting (the pane is closing; nobody is publishing its
frames) and keeps `applySearch`, `applySelectAll`, and `applyResize` interesting,
because in all three the user is looking at the pane that is about to stall.

One instrument note that follows from it: all these queues share the string label
`"com.danneu.danterm.terminal-pty-host"`, so a profile with several panes open
cannot attribute a queue to a pane by label alone.

### `F3` -- search's cost shape is worse than `H1` stated, and in a different way

`H1` described a scan. The scan is the cheaper half.

`projectionUnits()` (`Terminal.swift:2693`) materializes **one `ProjectionUnit`
per cell** over history and viewport, and each unit carries a heap-allocated
`[Unicode.Scalar]`. `searchMatches` (`:2895`) then allocates *another*
`[Unicode.Scalar]` per candidate start index. So the job is O(cells) in
allocations before it is O(cells x needle) in comparisons, and doc 15's work
raised the cell count on purpose -- at 179x66 with ~1,768 rows of history that is
on the order of 300k units per call.

And it is per *step*: `beginSearch`, `searchNext`, and `searchPrevious` each call
`searchMatches` from scratch (`:2577`, `:2588`, `:2603`), because no match list is
cached. Holding down next-match re-runs the whole thing per keypress. **Fixed by
`C1` (`D3`); the line numbers here describe the code before `257bfee`.**

**Twice per step, in fact.** `searchStatus` (`:2060`) is a computed property whose
body is another full `searchMatches` call, and `applySearch` reads it on every
mutation to feed the overlay's match counter (`TerminalPTYHost.swift:707`). So one
next-match keypress is two whole-history scans, not one. The redundancy is
deliberate and documented -- `searchStatus`' own doc comment says it recomputes
"from the same scan navigation uses, so it never disagrees with the selected
match" -- which is a correctness argument for sharing a result, and it is
currently satisfied by computing the same result twice. It is read only on search
mutations, not per frame; that was worth checking and is the one piece of good
news here.

This changes what the eventual fix probably is. `H1` offered "cached match list,
chunked scan, or both"; the shape now says a cached match list would serve both
callers and remove the doubling, and that the cheap independent move is a
`forEachProjectionUnit` walk that never materializes the array -- the callback
form already exists (`:2708`) and `projectionUnits()` is only the wrapper that
collects it (`:2693`). **Still not a proposal.** Phase 2 owes a number first, and
`agent-docs`' direction gate applies.

### `F4` -- a job proportional to the machine, not to the terminal

`sessionMembers` (`TerminalPTYHost.swift:1206`) calls `proc_listallpids` to
enumerate **every process on the machine**, then calls `getsid()` once per pid to
filter for session members -- one syscall per process, so several hundred to a few
thousand on a normal Mac. It runs on the owner queue from `signalSession`, and
then from a **10 ms repeating poll** (`:1245`) for as long as teardown takes.

This is a category the file's seeds did not anticipate: its cost is set by
unrelated system load, so it is invisible to every workload-shaped instrument this
project owns, and a machine with many processes makes it longer without anything
in DanTerm changing. `F2` says it cannot block another pane, and a closing pane's
frames matter little -- so the interesting case is not the fence at all but
**application exit**, where every pane runs this poll on its own queue
concurrently against a bounded exit timeout.

Filed as a finding rather than a candidate. It has no established cost, and the
right instrument for it is not the fence counter.

### `F5` -- all three user-facing jobs exceed a frame by 3-5x at a real history

Measured with a release-build probe that calls the `Terminal` methods directly.
That is legitimate here rather than a shortcut: `F1`'s jobs run *synchronously* on
the owner queue, so a job's duration is its occupancy, and interposing the queue
would only add its own overhead to the reading. Wall-clock throughout, per this
file's inverted rule. History is built by feeding plausible shell output at 179x66
until the 10 MiB budget stops admitting rows; medians of 9, on an otherwise quiet
machine.

| History | Cells | `beginSearch` | One keypress | `selectAll` | `resize` |
| --- | --- | --- | --- | --- | --- |
| saturated (1,702 rows) | 316,472 | 44.3 ms | **88.0 ms** | 10.0 ms | **53.7 ms** |
| shallow (135 rows) | 35,979 | 5.16 ms | 10.3 ms | 1.09 ms | 6.08 ms |
| viewport only (0 rows) | 11,814 | 1.65 ms | 3.31 ms | 0.36 ms | 1.87 ms |

A 60Hz frame is 16.667 ms and a 120Hz frame is 8.333 ms. **At a saturated history
one search keystroke holds the pane's queue for 5.3 frames at 60Hz and 10.6 at
120Hz**, and one reflow step holds it for 3.2 / 6.4. "One keypress" is
`searchNext` plus the `searchStatus` recompute `F3` found; the host pays both on
every mutation (`TerminalPTYHost.swift:707`).

Two confounds were checked before these were believed:

- **Copy-on-write in the probe, not the job.** Every row above mutates a copy of a
  `base` terminal that stays alive, so a mutation of `rows` could pay a CoW the
  reading would charge to the job. A control that gives each iteration a
  uniquely-owned terminal reads 43.99 ms for `beginSearch` and 52.93 ms for
  `resize` against 44.26 and 53.67 -- inside the noise. CoW is not in the numbers.
- **The obvious floor is degenerate.** An empty terminal reads 0.006 ms, which is
  not a small measurement of the work but a measurement of
  `forEachProjectionUnit`'s early return: it stops immediately when no row holds
  content (`Terminal.swift:2713`). The honest floor is the "viewport only" row --
  a full screen with nothing scrolled off -- which still costs 3.31 ms per
  keystroke.

The saturated depth here is 1,702 rows against doc 15's ~1,768 at the same
geometry; the difference is this probe's line-length mix, and nothing in the
reading turns on it.

### `F6` -- the cost is flat per cell, and the matching loop is 78% of it

Across a 27x range of cell counts the per-cell constant does not move:

| Job | 316,472 cells | 35,979 cells | 11,814 cells |
| --- | --- | --- | --- |
| `beginSearch` | 140 ns/cell | 143 ns/cell | 140 ns/cell |
| `selectAll` | 31.6 ns/cell | 30.3 ns/cell | 30.8 ns/cell |
| `resize` | 170 ns/cell | 169 ns/cell | 158 ns/cell |

So the jobs are linear in cells with no threshold or cliff, which makes them
predictable in the one way that matters: **the depth at which each first exceeds a
frame is arithmetic, not a measurement.** At 179 columns and 60Hz, one search
keystroke (2 x 140 ns/cell) crosses 16.667 ms at ~59,500 cells -- **about 333
rows**, or 267 rows of scrollback behind a full screen. At 120Hz it is ~167 rows.
`resize` crosses at ~548 rows. These are shallow histories, not extreme ones.

The decomposition also **revises `F3`'s emphasis**. `selectAll` is
`projectionUnits()` plus trivial work, so 31 ns/cell prices the unit
materialization `F3` led with -- and search costs 140. The candidate-array-per-start-index
matching loop is therefore ~109 ns/cell, **78% of a search**, and materializing the
units is the minority cost. `F3` said "O(cells) in allocations before it is a
scan"; the truer statement is that both halves allocate per cell and the scan half
is over three times the larger. Any fix that only avoids materializing the array
addresses the smaller share.

### `F7` -- the stimulus is per-keystroke, because the debounce is zero

`F5`'s "one keypress" figure would not matter if the app searched once per
committed needle. It does not. `sendSearchNeedle` (`app/AppRuntime.swift:669`)
debounces **300 ms for one- and two-character needles and zero for three or
more** -- the comment says so explicitly ("immediate for empty or 3+ chars"). So
from the third character on, every keystroke fires a full `beginSearch`
immediately.

Typing a six-character needle into a pane with a saturated history is therefore
four immediate searches at 88 ms, **~350 ms of queue occupancy accumulated while
the user is still typing**, on the queue that also feeds that pane's output and
serves its draw fence. The debounce is inverted relative to cost: it protects the
cheap short needles and lets the expensive long ones through ungated.

Recorded as a finding, not a candidate. Raising the debounce is an obvious lever
and a bad first move -- it hides the cost rather than removing it, and by `F6` the
cost is still there at 333 rows.

### `F8` -- the stall reaches the main thread only through a fence, and one of the three fences is uncounted

A search does not block the main thread by itself: `enqueueSearch` is
`queue.async` (`TerminalPTYHost.swift:319`), so the user's keystroke returns
immediately and the 88 ms is spent on the pane's own queue. Main pays only if it
performs a `queue.sync` fence while that job is running. There are three kinds of
main-thread fence, and they differ in a way that matters:

1. **The per-delivery fence in the consume task**
   (`TerminalPaneSession.swift:246`, `:252`). Fires whenever the child produces
   output. This is the one that turns a pane-local stall into an **app-wide**
   one -- the consume task is `@MainActor`, so the block is the main thread, and
   every other pane, the menu bar, and every window freeze with it. **Counted** by
   `lastFenceStallNanoseconds`.
2. **`synchronizeState()`** (`:357`), on the checkpoint cadence. **Not counted** --
   the counter's own doc comment says so.
3. **`readSelectedTextSynchronizing()`** (`:406`), on a copy. **Not counted**, same
   reason.

The consequence is that severity depends on whether the searched pane is *also
producing output*. On an idle pane the harm is confined and honest: the search
result arrives 88 ms late and nothing else is affected. On a pane with a live
child it is a whole-application main-thread block of the same duration.

Where the instrument is blind is mostly benign and once is not. `lastFenceStallNanoseconds`
misses fences 2 and 3, but fence 1 is the only one that fires unprompted, so the
counter covers the case the user does not choose. The exception is a natural
pairing: **Cmd-A then Cmd-C**. `applySelectAll` costs 10 ms at a saturated history
(`F5`), and `readSelectedTextSynchronizing` fences directly behind it -- a
main-thread block that no counter in this project records. Small today at 10 ms;
recorded because `F6` says it grows linearly and the instrument will not warn.

This also settles a scoping question `F2` left open. `F2` said contention is
per-pane; `F8` narrows *and* widens it -- the queue contention is per-pane, but
the main thread is shared, so a long job in one pane's queue reaches every pane
through fence 1.

### `F9` -- in the live app the symptom is repeat navigation, and it is a queueing knee

First real-app test, user-run on an optimized build against
`scripts/saturate-scrollback.sh` at a saturated history. **Incrementally typing a
needle is responsive, and single Enter steps are responsive. Holding Enter down is
"really weirdly choppy."**

That is a sharper result than the probe alone gives, and the adjective is the
informative part. One `searchNext` is ~88 ms (`F5`), which is under the ~100 ms
threshold where a single discrete action reads as instant -- so per-keystroke
typing and single steps land inside the budget a person grades them against, and
`F7`'s zero debounce turns out not to be the felt problem. Held-down key repeat
arrives every 30-90 ms depending on the system setting, which puts **arrival
interval at roughly service time**. That is the knee of the queueing curve: mean
throughput still looks acceptable while latency variance explodes. Uniform
slowness would be felt as lag; utilization near 1.0 is felt as chop, which is
exactly the word that came back.

So the ranking in `D1` survives but its *justification* changes. `C1` was ranked
first on total time removed; it should be ranked first because it is the candidate
aimed at the one case that is actually unpleasant -- repeated navigation on an
**unchanged** needle, which a cached list turns into index arithmetic and drops
utilization from ~1.0 to nil. `C2`'s bound and `C3`'s constant factor both attack
the first scan, which by this test nobody notices.

The user called it a pathological case, which is fair, and worth fixing anyway on
the strength of the mechanism rather than the stimulus: the same ~1.0 utilization
is reached at a far shallower history the faster the key repeat, and `F6` says
where.

Still untested at time of writing: the same searches against **live streaming
output**, which is `F8`'s app-wide case and is expected to be qualitatively worse
rather than merely slower. `scripts/saturate-scrollback.sh --stream` exists for
that comparison. **If both modes feel alike, `F8` has the severity wrong.**

**Amended by `F10`.** The streaming half of this finding is partly misattributed:
a search whose match had been evicted was returning false unconditionally, so some
of what a user felt on a streaming pane was a dead key rather than a slow one. The
quiet-pane result above stands unchanged and is pure occupancy, and `F11` measures
both sides of the knee it describes.

### `F10` -- part of the streaming symptom was a correctness bug, not occupancy

Reported after `F9`, with a screenshot: on a pane that was still streaming, once
the selected match had been pushed off the end of scrollback, **Enter stopped
responding entirely** and the overlay froze on its last count, with no way back
except retyping the needle.

Reproduced headlessly, so this is mechanism and not inference. Both paths that
invalidate a stale occurrence -- `handleEviction` when the match scrolls out of
history, and `invalidateInspection` when output overwrites its row -- set
`search = nil`, discarding **the needle along with the occurrence**. `searchNext`
opens with `guard let search else { return false }`, so it then returned false
forever. The recovery for exactly this state already existed and was already
documented: `reattachToNewestMatch` (`Terminal.swift:2619`), whose doc comment
describes the symptom precisely ("navigation would refuse to move until the user
retyped the needle"). It was simply unreachable, because both callers destroyed
the query before it could run. `selection` five lines above the eviction site had
the correct treatment all along -- clamp its start forward, drop only when
entirely gone -- and search had the crude version.

Fixed in `364af5c` by releasing `.range` and keeping the query, with one
spec-first test per path.

**This re-attributes part of `F9`.** That finding read the streaming symptom as
queueing, and the queueing is real and measured -- but on a *streaming* pane an
unknown share of what a user felt was Enter genuinely doing nothing rather than
doing something slowly. `F9`'s quiet-pane result is untouched: no eviction is
happening there, so that chop was always occupancy. The lesson is the ordering
one -- the doc had a measured mechanism in hand and reached for it to explain a
qualitative report, and was partly wrong. **Reproduce a reported symptom before
attributing it to the mechanism you are already holding.**

### `F11` -- the quiet-pane press costs 99.3 ms, and the fence is what makes it chop

`F5` priced one keypress at 88.0 ms as `searchNext` plus the `searchStatus`
recompute. Re-measured directly on the reported case -- 179x66, production 10 MiB
budget, 316,472 cells, 1,702 history rows, release build, 40 samples -- it splits
evenly and costs more:

| | mean | min | max |
| --- | --- | --- | --- |
| `searchNext()` alone | 49.78 ms | 48.99 | 51.67 |
| `searchStatus` alone | 49.76 ms | 49.08 | 51.35 |
| one `applySearch(.next)` job | 99.32 ms | 97.87 | 101.36 |

The two halves are within 0.04 ms of each other, which is the strongest available
confirmation of `F3`'s claim that the job is literally the same scan twice. The
~13% gap against `F5`'s 88 ms is machine state between runs, not a shape
difference; nothing in either reading turns on it.

**10.1 presses per second is the ceiling.** macOS key repeat is 15/s at the
default setting and 66/s at the fastest, so held Enter arrives **1.5x to 6.5x
faster than the queue can serve it** -- `F9`'s knee, now with both sides of the
inequality measured rather than one side estimated.

The mechanism `F9` left implicit is the fence. Every search job that changes the
terminal calls `publishPendingUpdate`, and the consumer answers with
`host.fencedFrameState()` -- a `queue.sync` from `@MainActor`
(`TerminalPaneSession.swift:246`, `F8`'s fence 1). So the main thread parks until
the queue reaches it, waiting out **every search job still ahead of it**. That is
why the symptom is chop rather than a steady 10 fps: main alternates between
running and sitting in a ~99 ms fence, so frames land in clumps. It also means the
backlog outlives the keypress -- nothing between the overlay and `queue.async`
coalesces repeats (`AppRuntime.swift:689` -> `navigateSearch` -> `searchNext` ->
`enqueueSearch`), so two seconds of held Enter at 30/s enqueues six seconds of
work.

Worth noting the file already predicted this shape. `lastPlanFenceStallNanoseconds`'
doc comment (`TerminalPaneSession.swift:115`) describes exactly this stall for a
child flooding its pty. Search is a second producer of the same stall, and unlike a
flood the user drives it directly from the keyboard.

### `F12` -- nothing reads the match list per frame, which is what makes `C1` cheap

Checked before caching anything, because a cache is only worth building if the
thing it feeds is not already on the hot path.

**The renderer only ever reads the single selected match.**
`RenderFramePlanner.swift:199` and `Terminal.swift:698` both take
`activeSearchMatchRange`; neither takes the list. And `searchStatus` has exactly
one non-test caller in the whole engine: `applySearch`
(`TerminalPTYHost.swift:707`). So **streaming output on its own triggers zero
scans** -- with an overlay open and no keypresses, a pane can print indefinitely
without search costing anything. The scan is entirely keystroke-driven.

Two consequences. It bounds `C1`'s risk: a cache that is wrong can only produce a
wrong count or a wrong navigation target on a keypress, never a wrong frame.
And it sets the ceiling on any future all-matches highlighting, which is a real
UX option this engine does not currently take -- today only the active match
highlights, and that is the reason the whole area is affordable. If that ever
changes, the per-frame requirement changes shape entirely, and `C1`'s cache is
what would make it possible rather than absurd.

### `F13` -- `D1` named the wrong invalidation hook, and the right one documents its own invariant

`D1` guessed the staleness hook "likely already exists in
`primaryHistoryObservation`". Close, and wrong in a way worth recording.

The seam is **`notePrimaryHistoryDamage()`** (`Terminal.swift:812`) -- the funnel
`primaryHistoryObservation` is bumped *from*, reached by all three of
`recordFullDamage`, `recordDamage(row:)`, and `recordDamage(rows:)`. What makes it
the right hook is not that it is a funnel but that **the comment above it already
states the exact invariant a match cache needs**: bumping is the default "so the
failure mode of a future miscategorized call site is a redundant recovery write,
never a lost one," and the non-bumping variants are reserved for mutations that
touch `viewportState`/`search` alone, never cell storage. A cache hung there
inherits that direction for free -- a miscategorized site costs a redundant
rescan, never a stale answer. One caveat: the clear must sit *above* the
`isAlternateScreenActive` guard, since a search begun under the alternate screen
scans that screen's rows.

The obvious-looking alternative would have been a live bug. `invalidateInspection`
is where the stale-occurrence logic lives, so it reads as the natural home -- but
its row-range path early-returns on `guard hasInteractionState`
(`Terminal.swift:3060`), so when no search, selection, or link is open, content
mutations **never reach it**. Search a needle, clear it, let the pane stream,
search the same needle again: the cache would have answered from the first search.
That sequence is now a test.

The general point, and the reason this is a finding rather than a note: **the
codebase had already solved the classification problem this candidate needed, for
a different consumer, and said so in a comment.** `D1` proposed inventing an
invalidation story. The work was reading enough to find the one already there.

### `F14` -- the `--stream` comparison came back negative, and the model predicted it

The comparison `F9` owed, run in the live app on the optimized dev build against
`scripts/saturate-scrollback.sh --stream`. User's report, verbatim: **"stepping
search on streaming now feels good. holding enter feels good on streaming vs
quiet."**

That is a negative result for `C5` and a positive one for `F11`'s model, which is
the more valuable half. The streaming pane still pays a full rescan per press --
48.8 ms by `D3`'s table, five frames, unchanged by `C1` -- and **it cannot be
felt.** The reason is the inequality `F11` set up, evaluated on the other side of
the fix:

| | service time | presses/second | vs. 15/s key repeat |
| --- | --- | --- | --- |
| before `C1` | 99.3 ms | 10.1 | arrival exceeds service; utilization > 1.0 |
| after `C1`, streaming | 48.8 ms | 20.5 | utilization ~0.73 |

Nothing about the *job* got acceptable. What changed is that the queue stopped
accumulating, so no press waits behind an unbounded number of predecessors and the
`@MainActor` fence never parks behind a backlog. `F9` called the symptom chop
rather than lag and attributed it to utilization near 1.0; that attribution now has
a confirming prediction rather than only a consistent story.

**The durable output is a threshold this file had wrong.** `D1` ranked candidates
against the 16.7 ms frame budget. The budget that actually predicted the user's
experience is **the repeat interval of the gesture driving the job** -- 66 ms at
the default 15/s key repeat. A 48.8 ms job under a 66 ms interval is invisible; a
99.3 ms job under it is intolerable. Occupancy above one frame is not by itself a
defect, which is why three of this file's five candidates shrink on this finding.

Two limits worth stating rather than burying. This was tested at **one** key-repeat
setting; at macOS's fastest (66/s, 15 ms interval) 48.8 ms is back above the line,
so the result is "not felt at default repeat," not "not felt." And it is one user's
qualitative report on one machine -- adequate for a 2x effect against a threshold
this far away, and not the kind of evidence that should settle anything close.

### `F15` -- resize is confirmed in the live app, and the same missing coalescing hits the child

Predicted from source before it was tested, which is worth recording because this
file's previous two live checks (`F9`, `F10`) both went the other way. User's
report: the window resizes instantly while the pane contents take a long time to
catch up, plus "weird jank where the prompt gets repeated multiple times on some
resizes." Screenshot attached to the 2026-07-30 session.

**The lag is `C4` with no coalescing.** `applyResize`
(`TerminalPTYHost.swift:1107`) is reached once per *distinct* grid --
`setGridDimensions` (`TerminalPaneSession.swift:341`) de-duplicates identical
dimensions and nothing else, and `host.resize` enqueues async. So a drag is not one
64 ms reflow; it is one per column boundary crossed. Narrowing across forty columns
queues ~2.5 seconds of work, which the window's own resize never waits for. Same
shape as held Enter before `C1`, at worse odds: mouse-move arrives every 8-16 ms
against 64 ms of service, so utilization is 4x-8x rather than `F11`'s ~1.5x-6.5x.

**The second symptom shares the cause but not, necessarily, the explanation.** Line
1115 does a `TIOCSWINSZ` per distinct grid, so the kernel sends the child one
SIGWINCH per grid too -- the storm is not only ours to absorb, it is forwarded. The
stacked prompts in the screenshot are the evidence: reading down them, the zsh
right-prompt truncates `orb` / `orbst` / `orbstac` / `orbstack` while the left goes
`…repo:` to `repo:`. Those are four complete prompt redraws at four different
`COLUMNS` values, not rendering corruption.

What is **not** established is why they stack instead of overwrite. That requires
the cursor to end up somewhere the shell does not expect after a reflow, and the
two candidates -- our reflow's cursor placement, or zsh losing its own redraw race
under a storm -- are not distinguished by anything measured. `F13` is the standing
reason not to guess here.

The discriminating test is cheap and belongs to Phase 5: **resize one notch, let it
settle fully, repeat.** If each settled single resize is clean, the duplication is
caused by the storm and coalescing fixes both symptoms at once. If a single settled
resize also duplicates a prompt, there is a reflow cursor bug underneath, which
coalescing would only make rarer -- and that outranks the performance finding, the
same way `F10` did.

### `F16` -- the test ran: storm artifact, and it is the shell's -- **debris half retracted**

**Correction, 2026-08-05.** The `D4`-first-branch result below stands: a settled
single resize is clean and the stacking needs the storm. The debris attribution
does not. `32/F10` establishes that the debris tracked DanTerm's zsh integration
failing to load in slotted dev apps, and that it is gone now that it loads. The
two paragraphs it licensed -- "the storm's debris is not ours" and "what nobody
owns" -- are struck below. Nothing is unowned; the question that paragraph opened
does not exist.

Run 2026-08-05, interactively, in a `just build` dev app at `69f6cbc8` --
`C4`'s coalescing (`02f3ba1a`, `0935ccc4`) and the logical-line cutover
(`9ad7cc5`) both included. Human observation of a live pane, uninstrumented;
full property lists and the three-terminal table are in `32/F1` and `32/F2`.

**`D4`'s first branch.** A settled single-column resize does not duplicate a
prompt, in either direction, in fish or in zsh. The duplication needs the storm,
and the storm needs a continuous drag.

**~~And the storm's debris is not ours.~~ Retracted.** The claim was that the
same fast-shake stimulus produced the same fragment debris in Terminal.app and
iTerm2 (`32/F2`), with `32/F9`'s grid reading as confirmation, so DanTerm was
rendering faithfully what the shell emitted. Both supports failed: the panes
compared had DanTerm's zsh integration absent, and neither of the other two
terminals could ever have carried it, so the agreement that looked decisive was
guaranteed regardless of cause (`32/F10`). `F15`'s two candidate explanations for
the stacking were therefore never narrowed to the second one here.

**The debris did not move to doc 32, and did not need to.** Doc 32 excluded it by
its own boundary and fixed only the repaint defect. It stopped being a defect on
its own once the integration loaded.

**The lag half is separately settled.** `F15` priced a reflow step at ~53.7-64 ms
and derived 4x-8x owner-queue utilization from it. `28/D11`'s amendment records the
same `saturated-wide-resize-v1` recipe at 1.58 ms median after `9ad7cc5`, with the
surviving live-screen refold at 1.46 ms widening and 2.65 ms narrowing. The pane no
longer lags the window during a drag, which the session confirmed by hand.

**What the test found instead.** On a settled single-column widen, rows above the
live prompt stop being painted -- DanTerm-only, present with the shell integration
disabled, and provably not a data loss: selecting the rows, scrolling them, or
pushing content into scrollback brings them back unchanged. That is a repaint
defect, not a reflow one, and it is nothing this doc predicted. **This, and only
this**, is what moved out of this doc; it owns
**[32-post-resize-repaint-loss](32-post-resize-repaint-loss/README.md)**, which
attributed it to `d3780961` and fixed it in `44b875cd`.

**~~What nobody owns.~~ Void.** This paragraph asked whether DanTerm could reduce
the debris despite the race being the shell's, and reasoned from `C4`'s
coalescing already being pulled without the debris going away. The premise was
wrong in both halves: the race was not established as the shell's, and the debris
did go away -- to the shell integration loading, not to any resize lever. There
is no unowned question here.

It is worth keeping as a record of how the wrong question got framed. "Not our
defect" was correctly identified as not closing the inquiry, and the follow-up
was then aimed at the resize rate, the variable this doc had been studying for
five phases, rather than at whether the attribution was sound. The available
lever was mistaken for the likely cause.

**Uncertainty.** The reproduction is a hand-driven mouse drag, and the fragment
pattern differs from `F15`'s screenshot -- whole stacked prompts there, mid-row
fragments here. The clause that previously closed this ("the three-terminal
control makes it the shell's either way") is retracted with the rest.

**Next action.** None owed by this doc.

## Decisions

### `D1` -- rank: fix the repeat scans first, bound the remaining one second

**Status: `C1` landed 2026-07-30 (`257bfee`), see `D3`. `C2`-`C4` still gated.**

Ranked by measured tail against the frame budget (`F5`), then by how much of the
tail each candidate actually removes.

**`C1` -- cache the match list per needle.** Highest, and after `F9` it is the only
candidate aimed at the symptom a person actually reports. `F3`/`F6` say one
keystroke runs the whole-history scan twice and `searchNext` re-runs it from
scratch; a match list computed once per needle and shared with `searchStatus`
makes navigation index arithmetic and removes the doubling outright. Takes
88 ms/keystroke to ~44 ms on the needle change and ~0 on every step after -- which
by `F9` is the difference between a queue at ~100% utilization and an idle one.
Simple in the sense that matters: no new concurrency, no chunking, no cancellation
story. Named risk, and it is the
real work: **staleness**. Output arriving during an open search invalidates the
list, and `searchStatus`' existing doc comment shows the codebase already reasons
about a stale occurrence ("output arrived while a failed search was open"), so
the invalidation hook likely already exists in `primaryHistoryObservation`.
Smallest first experiment: a spec-first test that a search's reported total
updates after output arrives, written before any caching, so the cache cannot pass
by freezing a stale answer.

**`C2` -- bound the remaining scan.** Second, and second only because `C1` shrinks
its frequency first. This file's own rule prefers a bound to a speedup, and after
`C1` exactly one unbounded scan per needle remains. The shape is the one
`a990606` gave the read path: cap the work per turn, re-enqueue, let the result
land a turn later. Cost is a real cancellation/generation story -- a needle
changed mid-scan has to abandon the old one -- which is why it ranks below the
change that removes most of the calls.

**`C3` -- stop materializing the projection units.** Third, as a constant factor
on whatever survives. `forEachProjectionUnit` already exists
(`Terminal.swift:2708`) and `projectionUnits()` is only the wrapper that collects
it. Worth 31 of 140 ns/cell in search (22%) and nearly all of `selectAll`, which
`C1` and `C2` do not touch at all -- so this is the only candidate that helps the
Cmd-A path `F8` found uncounted.

**`C4` -- reflow.** Fourth. Real at 53.7 ms (`F5`) but no candidate is obvious:
reflow genuinely has to touch every row, and `H2`'s open question is its *rate*,
which Phase 2 did not measure. Needs its own measurement before it needs a pitch.

**Not proposed: raising the search debounce.** `F7` found it inverted -- zero for
the expensive long needles, 300 ms for the cheap short ones -- so there is an
obvious tempting change here. It hides the cost rather than removing it, and by
`F6` the cost is still there at 333 rows. Revisit only as a complement after
`C1`, never instead of it.

### `D2` -- these candidates need no calibrated benchmark rule, and that is unusual here

Doc 18 inherited a hard rule: a candidate outside the draw bracket must name the
rule that decides it, or rank below every candidate inside it. Docs 17 and 18 both
paid real cost discovering that an undecidable candidate is not worth starting
(`17/D7`, `17/F15`).

That rule is satisfied here in an unusual way: **no existing workload searches at
all** -- `benchmark-quick`'s five workloads are feed, scrollback, and churn -- so
none of the calibrated rules apply, and none is needed. `17/F15` refused
`processCPUNanosecondsPerDraw` a rule because its paired A/A spread was 1.88-8.75%
against candidates worth a few percent. The candidates here are worth **5x to
50x**, against a probe whose spread across 9 samples is under 3% (`F5`). An effect
that size is decidable by a stopwatch, and pretending it needs a paired benchmark
would be ceremony.

What it does need is for the stopwatch to be reproducible. `F5`'s probe currently
lives in a scratchpad; if any of `D1` is taken, the probe should land as a checked-in
occupancy benchmark first, so the before/after is re-runnable by someone who did
not write it. **That is the recommended first commit** regardless of which
candidate follows, and unlike the candidates it is not a behavior change.

### `D3` -- `C1` landed; the staging was wrong and `D2`'s first commit was skipped

Landed in `257bfee`. Measured on `F11`'s probe, same pane, before and after:

| Case | Before | After |
| --- | --- | --- |
| held Enter, quiet pane | 99.3 ms | **~0.00 ms** |
| first press on a new needle | 99.3 ms | 51.4 ms |
| Enter with output arriving between presses | 99.3 ms | 48.8 ms |

The first row is `F9`'s reported symptom, removed at the source: the queue goes
from 150-650% utilization under key repeat to idle. The other two rows are the
duplicate scan `F3` found, now paid once instead of twice.

**The proposed staging did not survive.** The plan was to remove the duplicate
scan first as a free 2x, then add the cache behind it. That first step is
unsound in isolation: with no cache, the only way to serve one scan to both
callers is to return the status from the mutating entry points, which changes
`TerminalCore`'s public API for what is supposed to be a pure refactor. The cache
subsumes it at no cost instead -- `searchNext` mutates only `search.range` and
never cell storage, so by `F13`'s invariant the list it builds is still valid when
`searchStatus` reads it microseconds later in the same job. **The "obviously
smaller first step" was larger than the thing it was meant to de-risk.**

Two implementation notes worth keeping. The cache is excluded from value equality
via `ObservationGeneration`'s always-equal shape, because `applySearch` publishes a
frame on `terminal != previousTerminal` and a cache fill is not a change any
consumer can observe -- without that, filling the cache would itself emit a frame.
And `searchStatus` is a get-only property on a value type, so it cannot fill a
cache; it reads one and falls back to a scan, while the mutating navigation
entry points do the filling. That asymmetry is why the ordering inside a job
matters and is worth not "tidying" later.

**Method, recorded because it is the part worth repeating.** Three freshness tests
were written first and passed against the *uncached* code -- characterization, not
red-green. To prove they had teeth, the cache was then built with **no
invalidation at all**: six tests failed with twelve issues, and three of the six
were pre-existing tests nobody had written for this purpose. Only then was the
invalidation added. A cache's whole failure mode is silently serving a stale
answer, and a test suite that has never been shown to fail against a stale answer
is not evidence.

**`D2`'s recommended first commit was skipped, then paid back.** That decision said
to land `F5`'s probe as a checked-in occupancy benchmark *before* taking any
candidate. It was not done, and the reasoning `D2` itself supplies is why --
effects of 5x-50x are decidable by a stopwatch, and the before/after here is
99.3 ms to 0.00 ms, which no one needs a harness to believe. The cost is real and
should be stated rather than waved away: **the 99.3 ms baseline in this file is
permanently unreproducible**, because the code that produced it is gone. Anyone
re-deriving it has to check out `364af5c`. Landing the probe afterwards does not
undo that -- a harness cannot measure a revision that no longer exists -- which is
the whole argument for `D2`'s ordering and the reason to treat this as a debt
that was incurred rather than avoided.

The probe now exists as `just terminal-occupancy-probe`
(`lib/TerminalCore/Sources/TerminalOccupancyProbe`), so `C5` starts from a
measurable baseline rather than this one. It reproduces `F5`'s pane exactly --
316,472 cells, 1,702 history rows at 179x66 -- which is the strongest available
check that its corpus matches the one those numbers came from. Five cases: a new
needle, held Enter quiet, held Enter with output arriving, Cmd-A, and one reflow
step. Its stimulus is kept line-for-line identical to
`scripts/saturate-scrollback.sh` on purpose, so the felt behavior in the live app
and the measured behavior here are the same workload; if one changes, both must.

Two things about it are worth knowing before reading its output. It reports **no
rate below 0.01 ms** rather than a large one: a bracket around a cache hit reads a
few hundred nanoseconds, and dividing that into 1000 produces a confident
"3.8 million presses/second" that is the timer's noise floor printed beside a real
key-repeat rate. And it has **no paired arm and no threshold** -- comparison is by
hand across two checkouts. That is deliberate per `D2` and is exactly what makes it
insufficient for anything smaller than the effects this file deals in.

### `C5` -- incremental tail rescan, the streaming case `C1` leaves

New candidate, and the natural successor. `C1` invalidates the whole list on any
cell-storage write (`F13`), so a pane that is printing pays one full scan per
press -- 48.8 ms, half of what it was and still five frames.

The shape follows from two structural facts. Matches are stored in **absolute**
stream coordinates, so eviction renumbers nothing: surviving matches keep their
identity, and eviction is a prefix drop rather than a rebuild. And output appends
at the tail, so it only ever dirties rows near the end. Keeping a
`validThroughRow` high-water mark alongside the list, pushed back by
`notePrimaryHistoryDamage`'s row range instead of cleared outright, makes a
rescan cost the viewport (~66 rows, ~1.6 ms) rather than all of history (~1,768
rows, ~49 ms), with total work proportional to bytes written -- the same order as
feeding the data in the first place.

Three named edges, all of which need their own tests. A match can span rows via
soft wrap, so the rescan must restart `queryScalars.count` units before the
boundary or miss matches straddling it. `forEachProjectionUnit` stops at
`lastContentRow` and emits a row's trailing newline unit only when
`rowIndex < lastContentRow` (`Terminal.swift:2708`), so a unit that did not exist
becomes real when more output arrives *without that row being invalidated* -- the
rescan has to start at least one row earlier. And scrollback is not strictly
append-only: `severScrollbackWrapClaim` and `clearPreviousSpacer` write to
scrollback rows (`:5526`, `:5596`), touching only wrap claims and trailing
spacers, which does change projection. All three already route through `F13`'s
seam; they are listed because a design that assumes "history is immutable" would
be wrong in exactly three places.

Ranks against `C2`/`C3` on evidence this file does not have. `F9` still owes the
`--stream` comparison, and `C5` is only worth its edge cases if searching a
tailing pane is a real workflow rather than a plausible one.

**Rejected 2026-07-30 by `F14`, on exactly the evidence it named as its gate.**
The comparison came back negative: the streaming case is not felt. Kept in place
rather than deleted because the reasoning is the reusable part -- absolute
coordinates make eviction a prefix drop, and the three edges are properties of
this engine that any future incremental design still has to handle. Reopening
condition in `D4`.

### `D4` -- the search thread is closed; the threshold changed, and reflow inherits the file

`F14` and `F15` land together, and between them they re-rank everything this file
has left. The re-ranking is driven by a **new deciding rule**, so that comes first.

**The rule `D1` should have used.** `D1` ranked by measured tail against the 16.7 ms
frame budget. `F14` shows the budget that predicts felt behavior is **the arrival
interval of the gesture driving the job**, and that a job several frames long is
invisible when nothing queues behind it. So the question for every remaining
candidate is not "does this exceed a frame" but **"does service time exceed the
interval at which the user can re-trigger it"**. This is not a calibrated
benchmark rule and does not pretend to be -- it is a screening rule for deciding
what is worth measuring, in a file whose effects are 5x-50x (`D2`).

Applied to the board:

| | service | driving gesture | interval | verdict |
| --- | --- | --- | --- | --- |
| `C5` streaming search | 48.8 ms | key repeat | 66 ms | **rejected** (`F14`) |
| `C2` bound the first scan | 52.6 ms | one keypress per needle | n/a, not repeated | **rejected** |
| `C3` non-materializing walk | ~22% of a scan; Cmd-A 7.9 ms | discrete action | n/a | **rejected** |
| `C4` resize/reflow | 64 ms | mouse-move during a drag | 8-16 ms | **taken up** (`F15`) |

`C2` and `C3` are rejected on the same argument as `C5`, and it is worth being
explicit that this is a reversal. Both attack a scan that happens **once per
needle**, and `F9` established from the live app that typing a needle and single
Enter steps are responsive. A candidate whose whole benefit lands on an action the
user has already reported as fine is not worth a cancellation story (`C2`) or a
traversal rewrite (`C3`). `C3` additionally lost its distinguishing argument along
the way: `D1` pitched it as "the only candidate that helps the Cmd-A path," and the
probe reads Cmd-A at **7.92 ms**, inside a 60Hz frame. That is consistent with
`F5`'s 31 ns/cell rather than new -- what is new is noticing that the path it
uniquely helps already fits its budget.

Both stay listed rather than deleted, with one shared reopening condition: **a
history materially deeper than doc 15's ~1,768 rows.** `F6`'s per-cell constant is
flat, so at 4x the depth the first scan is ~210 ms and crosses the threshold for a
discrete action on its own. Neither is wrong; both are premature.

**`C4` is now the file's remaining candidate, and it is not the one-liner it
looks like.** The shape is right there -- reflow is idempotent on the final size
and every intermediate grid is discarded anyway, so collapsing the queue to the
newest pending grid is small. What makes it a design question rather than a patch
is the `TIOCSWINSZ` on `TerminalPTYHost.swift:1115`: the intermediate grids are not
purely internal, they are **told to the child**. Dropping them changes what the
shell is told, not only what we render, and `F15`'s stacked prompts are the
evidence that the child's response to that stream is already not benign.

So `C4` is **not authorized by this decision**, and the gate is a finding rather
than a preference. `F15`'s single-settled-resize test has to run first, because it
decides which problem `C4` is solving:

- **Clean single resize** -> the duplication is a storm artifact, coalescing fixes
  the lag and the jank together, and `C4` is a performance change with a nice
  side effect.
- **Duplicated single resize** -> there is a reflow cursor bug underneath.
  It outranks `C4` outright, gets diagnosed first, and coalescing would have
  buried it by making it rare. That is `F10`'s pattern for the second time in this
  file: **the live-app symptom that looks like slowness turns out to have a
  correctness bug inside it**, and chasing the performance framing first would
  have hidden it both times.

`D2` applies to `C4` in full, and unlike `C1` it can be honored: the probe exists,
`just terminal-occupancy-probe` already measures a reflow step, and the baseline
(64.04 ms mean, 61.78-69.45) is recorded before any change. What the probe does
**not** measure is the drag *rate*, which is the whole of `H2` and the entire
reason `C4` matters -- a coalescing fix would leave the per-step number untouched
and be a total success. Any `C4` measurement therefore needs a stimulus the probe
does not currently have: N distinct grids submitted back-to-back, timed to drain.
Adding that case is the honest first commit here, and it is not a behavior change.

> **The paragraph above is wrong about where the verdict comes from, and no such
> probe case was added.** The probe drives `Terminal` directly and deliberately,
> per its own header; coalescing lives a layer up, at `TerminalPTYHost`'s
> submission boundary, so no case added to the probe as architected can observe
> it. The mistake was assuming `D2` implies a probe case whenever it applies. It
> does not here, because coalescing is a **countable** property rather than a
> durational one: with the owner held deterministically occupied, a burst of N
> distinct grids applies exactly one winsize/reflow pair, which needs no
> threshold, no calibration, and no paired arm. That is what
> `supersededResizesSkipBothWinsizeAndReflow` in `TerminalPTYHostTests` asserts,
> from the host's applied effects and the child's observed `SIGWINCH` size, and
> it is the verdict `C4` shipped on. The probe keeps its narrower existing job of
> pricing the residual single reflow, whose 64 ms this change does not touch.

## Open hypotheses

Revised by Phases 1 and 2. `H1` and `H2` are **answered** -- mechanism confirmed
and size measured -- and become Phase 3's candidates. `H3` is retired. `H4` stands
unmeasured and lowest-priority.

### `H1` -- search and select-all are unbounded and re-scan per step

**Answered.** Mechanism in `F1`/`F3`, size in `F5`/`F6`, stimulus in `F7`. 88 ms
per keystroke at a saturated history, crossing a 60Hz frame at ~333 rows, fired
ungated from the third character typed. Widened in Phase 1 to include
`applySelectAll`, which at 31 ns/cell is a third the cost and shares the same
`projectionUnits()` walk.

Both parts now closed. The fence does observe the stall, and that is the mechanism
rather than a detail (`F11`): each press publishes an update whose consumer blocks
`@MainActor` in `queue.sync` behind the whole backlog. Of the three fixes, the
cached match list was taken and measured (`D3`); the non-materializing walk
(`C3`) and the chunked scan (`C2`) remain open, both now attacking only the single
scan `C1` leaves per needle.

### `H2` -- resize/reflow is unbounded and fires repeatedly

**Answered, and its open half is now answered too.** 170 ns/cell, 53.7 ms at a
saturated history (64.0 on the checked-in probe), crossing a 60Hz frame at ~548
rows. Distinguished from `H1` by stimulus rather than size: a live window or split
drag fires it whenever the drag crosses a cell-width boundary, so its *rate* was
the open question and `F5` measured only its length.

The rate half is closed by `F15`, from source and confirmed in the live app: **one
reflow per distinct grid, no coalescing, no debounce**, against mouse-move arrival
of 8-16 ms. That is 4x-8x utilization -- the worst ratio in the file, worse than
held Enter ever was -- and it is why the pane visibly trails the window. It also
forwards a SIGWINCH per grid to the child. `D1` ranked this fourth on the grounds
that "a fix is far less obvious, since reflow genuinely has to touch every row";
that reasoning was sound about making reflow *faster* and irrelevant to the actual
defect, which is doing it forty times when one would do. `D4` promotes it to the
file's remaining candidate.

### `H3` -- the write turn is capped at 4x the read turn

**Answered by `F1`, and it is not a defect.** The write turn caps at 64 KiB and
re-fires through its write source (`:878`, `:911`), which is the same shape the
read path got in `a990606`. The asymmetry is a difference in constant, not in
kind, and no stimulus is known that makes the write path the longest job on the
queue -- a paste large enough to matter still yields every 64 KiB. Retired; revisit
only if Phase 2 measures a write turn near the read turn's tail.

### `H4` -- `drainCommittedOutput` has no cap and no re-fire

New, from `F1`. It reads the full `FIONREAD` count sampled at entry
(`TerminalPTYHost.swift:1052`), so a child that dies having just written a large
burst produces one unbounded job. Lowest priority of the four: it runs once, on
the exit path, on a pane that is closing, which by `F2` blocks nothing a user is
watching. Recorded so the inventory is complete, not because it looks worth
fixing.

## Pre-rejected

- **Adding a second queue anywhere in the engine.** `TerminalCore`,
  `TerminalRenderPlanning`, and `TerminalRenderExecution` are pure value types
  with a single owner; a queue there buys no safety they lack and adds an async
  seam through the draw path. The app's other queues (`checkpointIOQueue`,
  `IpcServer.acceptQueue`) already have the right shape.
- **Moving search off the owner queue onto its own queue.** It would need its own
  `Terminal` snapshot and a staleness story for results that arrive after the
  screen has changed. That is a large change to buy something a bound may buy for
  a fraction of the cost. Reconsider only if Phase 2 shows a job whose duration
  cannot be chunked.
- **Undoing the fence.** The atomicity it provides is the fix for a real
  published-stale-row bug, verified red-then-green. Occupancy is the price, and
  this file is about paying it down, not about refunding it.

## Outcome

**Shipped, and the queue question is answered.** The deliverable was an inventory
of every job on `TerminalPTYHost`'s serial queue with its bound, an occupancy
measurement for the unbounded ones, and a per-candidate verdict. All three exist:
`F1` inventories the four unbounded jobs, `F5` prices the three user-facing ones
at 3-5x a frame, and `D1` and `D4` between them dispose of all five candidates.

Two landed. `C1` -- stop rebuilding the match list per step -- landed in
`257bfee` and is measured. `C4` -- latest-wins resize coalescing at the host's
submission boundary -- landed in `02f3ba1a` and `0935ccc4`, verified by
`supersededResizesSkipBothWinsizeAndReflow` rather than by a benchmark, because
coalescing is a **countable** property and not a durational one (`D4`'s own
amendment, which corrects the probe case that decision had promised).

Three did not. `C2`, `C3`, and `C5` are rejected by `D4` as premature on one
shared argument: a candidate whose whole benefit lands on an action the user
already reports as responsive is not worth its complexity. They stay listed
rather than deleted.

**What outlived the candidates.** `D4` replaced the deciding rule `D1` had used,
and that reversal is the file's most portable result. Ranking by "does this
exceed the 16.7 ms frame budget" is wrong; the budget that predicts felt
behavior is **the interval at which the driving gesture can re-trigger the job**.
A job several frames long is invisible when nothing queues behind it. That single
change of rule rejected three candidates and promoted the fourth.

Twice in this file the live-app symptom that looked like slowness had a
correctness bug inside it: `F10` in the streaming case, and again in `F16`, whose
single-settled-resize test was run to price a performance change and instead
found rows that stop being painted. Both times the performance framing would have
buried the bug -- `C4`'s coalescing in particular would have made the repaint
defect rarer without fixing it.

**Reopening condition.** A history materially deeper than doc 15's ~1,768 rows
reopens `C2`, `C3`, and `C5` together. `F6`'s per-cell cost is flat, so at
roughly 4x that depth the first scan reaches ~210 ms and crosses the threshold
for a discrete action on its own. Nothing else here reopens: the fence and the
read cap that motivated the file are unchanged, and the queue's remaining
unbounded jobs are the ones `D4` deliberately left.

**What left this file, and what did not.** The repaint defect `F16` found owns
[doc 32](32-post-resize-repaint-loss/README.md); it was attributed to `d3780961`
and fixed in `44b875cd`. The resize-storm debris did not leave with it and did
not need to: `32/F10` retracts the attribution `F16` made, and the debris turned
out to track DanTerm's zsh integration failing to load rather than anything about
resize. It is gone now that the integration loads. Nothing here is unowned.

**A third correction-shaped lesson, added after closing.** This doc already
recorded two (`D4` replacing `D1`'s deciding rule; a correctness bug twice hiding
inside a slowness symptom). The debris retraction is the third and the sharpest:
a control can be blind and look strong for the same reason. Comparing DanTerm
against Terminal.app and iTerm2 felt decisive because it was broad, but neither
of the other two could ever have carried the variable that mattered, so their
agreement was guaranteed whatever the cause. The follow-up question this doc then
framed -- can DanTerm reduce the debris by resizing the child less often? -- aimed
at the lever already in hand rather than at whether the attribution was sound.
`32/README.md`'s Outcome states the general form.
