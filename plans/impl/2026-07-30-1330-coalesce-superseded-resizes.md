# Coalesce superseded resizes on the owner queue

## Problem

Dragging a window edge or split divider on a saturated pane makes the window
resize instantly while the pane contents lag seconds behind, and makes the shell
redraw its prompt once per column crossed.

Both follow from one fact: geometry reaches the owner queue **once per distinct
grid**, and each submission does a full `TIOCSWINSZ` plus a full reflow. The
session layer de-duplicates identical grids and nothing else, so a drag across
forty columns enqueues forty reflows.

Evidence, from `docs/research/19-owner-queue-occupancy.md`:

- One reflow costs **64 ms** at a saturated history (`19/F5`, `19/H2`; the
  checked-in probe reads 64.04 ms mean, 61.78-69.45).
- Mouse-move arrives every 8-16 ms, so utilization during a drag is **4x-8x** --
  the worst ratio in the file, worse than the held-Enter case that motivated it
  (`19/F15`).
- The backlog reaches the user through the `@MainActor` drain fence, the same
  mechanism `19/F11` measured for search.
- Each skipped-nothing submission also forwards a SIGWINCH, which `19/F15`
  observed in the live app as four complete zsh prompt redraws at four different
  `COLUMNS` values.

**Desired outcome:** a drag applies as many reflows as the owner queue can
afford and no more, always settling at the final grid, with the child told
proportionally fewer sizes.

Load-bearing premise: **a resize may be superseded only before its winsize/reflow
pair begins; once the pair begins it completes.** Not path independence -- a
reflow can evict or rewrite retained text, so applying grids A then B is not
claimed to equal applying B alone. What makes dropping superseded work correct is
that a grid never applied is never observed, by the child or by the terminal.

Precedent worth reusing rather than reinventing: the pane lifecycle **already
implements latest-wins for resize** while spawning -- a grid arriving before the
child exists replaces the pending one instead of queueing
(`lib/TerminalPTY/Sources/PaneLifecycle/PaneLifecycle.swift`). This change
extends an existing semantic into the running state.

## Decision

Latest-wins coalescing at the owner-queue submission boundary: a resize whose
work is already superseded by a newer submission is skipped entirely rather than
performed and discarded.

Chosen over gating on AppKit live-resize because it **self-paces**. The pane
reflows as often as the machine can afford -- roughly 15/s at a saturated
history, faster on a shallow one -- so contents follow the drag on every machine
without a tuned cadence, and the backlog cannot grow.

Behavioral scope is the running pane's geometry path only. No change to what a
settled resize does, to reflow itself, or to the frame-publication path.

Critical files:

- `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift` -- geometry
  submission and application.
- `lib/TerminalPTY/Tests/TerminalPTYHostTests/TerminalPTYHostTests.swift` --
  where the existing joint-FIFO ordering test lives.
- `docs/research/19-owner-queue-occupancy.md` -- `19/D4` is wrong about how this
  gets measured and must be corrected in the same change (see `RI2`).

## Invariants

- **I1.** Coalescing applies only within a **contiguous run of resize
  submissions**: any externally submitted non-resize action -- input, pointer,
  wheel, scroll, selection, search -- closes the run. Within a run, every resize
  but the newest applies **neither** its winsize nor its reflow, and the newest
  applies both. The skip covers the pair atomically: the child is never told a
  size the terminal did not reflow to, and never left unaware of one it did. A
  resize whose pair has begun applying is never superseded.
- **I2.** The most recently submitted grid always applies. A settled drag ends
  with terminal geometry and child winsize at the final size.
- **I3.** Every non-resize submission observes the geometry of the last resize
  submitted before it, preserving the host's documented joint FIFO order. This is
  what makes the run boundary in `I1` load-bearing rather than conservative
  bookkeeping: pointer hit-testing and viewport navigation read the grid.
- **I4.** A resize with nothing behind it applies as promptly as it does today.
  Coalescing adds no timer and no settle delay.

## Proof obligations

- **PO1** (I1): given a contiguous pending run of distinct grids submitted to a
  **real host** whose owner is deterministically occupied, the host applies only
  the newest grid's winsize/reflow pair and no other member's. Proven from the
  host's applied effects, so that reverting the production wiring fails it -- a
  policy unit tested in isolation does not discharge this.
- **PO2** (I2): after any burst, both the terminal's geometry and the child's
  winsize are the last grid submitted.
- **PO3** (I3): a non-resize submission between two resizes observes the earlier
  grid, proven with at least one geometry-dependent action beyond input --
  pointer or viewport navigation -- alongside the existing input ordering case.
- **PO4** (I4): a lone resize is observable without waiting on anything.

`PO1` must be a deterministic verdict, not a race: "fewer than submitted" is
satisfied by an implementation that drops one of forty and still lags 2.5
seconds, and a selector proven only in isolation is satisfied by a host that
never calls it. Determinism has to come from controlling *when the owner is
free*, not from how fast a test machine drains -- the host already distinguishes
submitted transitions from applied ones, which is the seam that makes the applied
side countable.

## Non-goals

- Making reflow itself cheaper. The residual 64 ms is a settled discrete action,
  and by `19/F14`'s threshold that is below the felt line; halving it would be
  imperceptible. The defect is doing it forty times, not doing it slowly.
- The stacked-prompt question. `19/F15` leaves open whether prompts stack because
  of the SIGWINCH storm or because of a reflow cursor bug, and names the test
  that decides it. If this change makes the symptom disappear, that is evidence,
  not a diagnosis -- and the open question stays open.
- Any change to `19/C2`, `19/C3`, or `19/C5`, all rejected as premature by
  `19/D4`.

## Accepted risks

- **AR1.** Coalescing is deliberately conservative around every non-resize
  submission: a drag with interleaved typing, pointer traffic, or scrolling
  coalesces less than a bare drag. Correctness of `I3` is worth more than the
  throughput given up, and a drag is mostly bare.
- **AR3.** Coalescing may make the stacked-prompt symptom rarer before it is
  diagnosed. Accepted because `I4` leaves a lone settled resize untouched, so the
  discriminating test in `19/F15` stays exactly as valid after this change as
  before it -- concealment would require changing the settled path, which this
  change does not.
- **AR2.** How many reflows a drag applies becomes machine- and depth-dependent.
  That is the point of self-pacing, and it means no test may assert an exact
  count. This constrains live drags only; `PO1` holds the owner deterministically
  and does assert an exact selection.

## Rejected ideas

- **RI1.** Freezing pane contents until the drag ends (gate on AppKit
  live-resize). Makes the drag perfectly smooth at the cost of stale, stretched
  contents for the whole gesture, and would require verifying that live-resize
  reporting covers split-divider drags.
- **RI2.** Adding a drag-drain case to `just terminal-occupancy-probe`, which is
  what `19/D4` currently recommends. The probe measures `Terminal` directly and
  deliberately, per its own header; coalescing lives above that, in the host. No
  case added to the probe as architected can observe this fix. The verdict comes
  from `PO1`/`PO2` instead -- coalescing is a countable property, so it needs no
  threshold, no calibration, and no paired arm. The probe keeps its existing
  narrower job of pricing the residual single reflow.
- **RI3.** Coalescing at the session layer behind a debounce timer. Adds latency
  to settled resizes, violating `I4`, to solve a problem the queue can solve
  without one.

## Verification

- `just test` for the gate, plus the `TerminalPTYHost` suite for `PO1`-`PO4`.
- Live check: run `scripts/saturate-scrollback.sh`, then drag the window edge and
  a split divider. Contents should follow the drag rather than trailing it, and
  settle at the correct width.
- In the same live session, run `19/F15`'s discriminating test -- resize one
  notch, let it settle fully, repeat -- and record whether a single settled
  resize duplicates a prompt. It is not a gate on this change (`I4` leaves that
  path unchanged), but the session is the cheapest place to collect it, and a
  positive result outranks this performance work for whatever comes next.

## Implementation discretion

- Where the coalescing decision state lives, how it is synchronized across the
  submitting thread and the owner queue, and whether it is extracted as a
  separately testable unit.
- Whether the skip is taken before or after the lifecycle state machine sees the
  event, provided `I1` and `I2` hold.

## Implementation notes

- The decision state is a `Mutex`-guarded `(run, index)` pair in a separate
  `ResizeCoalescer`, not actor state: "is there a newer submission" is written by
  whatever thread submits and read on the owner queue. The skip is taken before
  the lifecycle reducer sees the event, which `Implementation discretion` allows
  and which keeps the pending-resize latest-wins the reducer already does intact.
- The run boundary is enforced structurally rather than by convention: every
  `nonisolated` non-resize submission now goes through `queueClosingResizeRun()`
  instead of touching `queue` directly, so a future entry point cannot silently
  omit it. `submitStart` closes the run too -- it is not in `I1`'s enumerated
  list, but closing on it can only coalesce less, never more.
- Frame fences (`fencedSnapshot`, `fencedFrameState`) deliberately do **not**
  close a run. They are reads rather than submissions, and the view fences once
  per frame during a drag, so closing on them would defeat coalescing entirely.
- `PO1`'s deterministic occupancy comes from blocking inside the pane-menu
  callback -- the one production entry point that runs caller code on the owner
  queue -- rather than adding a test-only seam to the host.
- `PO3` proves the run boundary with a line-granularity click whose stream row is
  resolved from the viewport height, calibrated against both grids first so the
  two possible answers are known to differ.
- Doc 19's status header and its Phase 5 checklist were corrected alongside `D4`,
  because both repeated the probe recommendation `RI2` retracts.

## Follow Up

- `docs/research/README.md:32` still reads "`C2`-`C4` still gated" for doc 19;
  `C4` is now landed. Left untouched because that file has unrelated unstaged
  edits in the working tree.
- The live check in `Verification` has not been run: drag a window edge and a
  split divider on a pane saturated by `scripts/saturate-scrollback.sh` and
  confirm contents follow the drag and settle at the correct width.
- `19/F15`'s single-settled-resize test is still open
  (`docs/research/19-owner-queue-occupancy.md:225`). The live session above is the
  cheapest place to collect it, and a positive result outranks this work.
