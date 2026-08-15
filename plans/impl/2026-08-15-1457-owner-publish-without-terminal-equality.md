# Owner-queue publish without whole-Terminal equality

## Problem

A pointer move over a pane with deep retained history freezes the pane's owner
queue. During the 2026-08-15 iOS smoke, slot 1 ran `tree .` (saturating the
~15 MiB history arena), and ambient mouse motion then pinned the owner queue at
~100% CPU; a single keystroke took seconds to echo because it was queued behind
the pointer backlog. The 3-second sample
(`/tmp/DanTerm_Dev_(1)_2026-08-15_134035_Kyn2.sample.txt`) puts 2235 of ~2250
owner-queue samples inside `TerminalPTYHost.applyPointer`'s
`terminal != previousTerminal` (TerminalPTYHost.swift:1265), all in
`LogicalLineStore.==` / `recordsHoldTheSameContent`'s word-compare loop. The
main AppKit loop was idle and the tailnet reader was blocked normally in
`read`; the transport is blameless.

Mechanism: seven sites in `TerminalPTYHost` decide "did this mutation change
anything worth publishing?" by copying the whole `Terminal` value and comparing
after the mutation -- `applyPointer`, `applyLinkCancellation`,
`applyClearSelection`, `applySearch`, `applySelectAll`,
`applyViewportNavigation`, and `applyResize`. `Terminal.==` includes
`LogicalLineStore.==`, which is O(retained history) even after `research/31/F13`
M4's remedy made it compare stored bytes instead of decoded cells. Each queued
mouse move pays one full-history scan on the serial owner queue, and everything
else -- keyboard input included -- waits behind it.

This is the second workaround on the same site: F13 M4 measured the decoded-cell
`==` at 9.32% of whole-process CPU under ambient mouse motion, and the fix
shrank the constant while keeping the O(history) term. The structural problem --
the host re-derives, at whole-value cost, an answer the mutation already
computed -- was never removed. This is the granularity-mismatch shape
`agent-docs/perf-granularity-mismatch.md` warns about.

## Load-bearing premises

- P1. `Terminal` already records each mutation's consumer-visible effect in
  O(1) through the damage funnel (`recordDamage(since:)` diffs O(1)
  presentation snapshots; scroll, search, and resize record full damage), and
  `hasPendingConsumerWork` is the delivery obligation: work a frame consumer
  must be woken to drain. The recording is not an exact "did visible state
  change" bit, and the plan does not treat it as one. Some recordings are
  deliberately conservative: re-hovering the identical link damages its rows
  by contract ("the damage snapshot deliberately detects writes rather than
  inequality", pinned in `TerminalHyperlinkInteractionTests`), and repeating a
  `beginSearch` records full damage. Those recordings also change the damage
  accumulator, so today's equality gate signals them too -- publishing what
  was recorded is parity, not a regression. `applyOutput` already gates on
  pending work and never compares terminals, even under output floods.
- P2. Armed-link state is the one interaction state with no damage path, and it
  is not consumer-readable (`armedLink` is internal; no public getter), so a
  publish on arm-only change carries no observable information.
- P3. No production code outside the seven host sites compares whole `Terminal`
  values (repo sweep of `app/` and `lib/`, tests excluded).
- P4. For frame work the update signal is an edge-triggered wakeup, not a
  payload: the drain reads the current terminal, so any frame-only mutation
  covered by an undrained signal is delivered by that drain. Output signals
  are different -- they carry urgent payloads (clipboard, semantic events,
  the primary-history generation, the child result) that must not wait on the
  drain, which is why their classification is generation-sensitive and stays
  as is.

## Decision

What a mutation records is the authority on its consumer-visible effect; the
host delivers what was recorded and never re-derives change by comparing
values. Delete every `previousTerminal` copy and whole-value comparison
from `TerminalPTYHost`. Keep the one delivery funnel
(`markUpdatePending` / `publishPendingUpdate`), but classify the reason for a
signal per class, each with O(1) state -- an update signal is not one kind of
event, and the classes have different coverage rules:

- Frame-only interaction work (the seven sites: selection, hover, search,
  viewport, resize damage) only wakes a future frame drain. It signals iff
  pending frame work exists that no undrained signal already covers; the work
  generation plays no part, because the pending drain reads the current
  terminal. Resize's primary-history generation bump rides the next signal or
  drain, which is how a text flood under saturated damage already delivers it.
- Output-driven work keeps `applyOutput`'s existing generation-sensitive
  classification unchanged: new urgent payloads (clipboard writes, semantic
  events) may require another signal before the deferred drain.
- Lifecycle events (process start, the child's result) signal without
  requiring any terminal consumer work, exactly as today.

This is the ideal fix for the measured freeze, not a mitigation: publish
classification becomes O(1) at every site, and the incident's path -- ambient
pointer motion, which mutates at most hover and selection state -- does no
history-proportional work at any depth, regardless of pointer-event queue
length. Interaction work intrinsic to a mutation is out of scope and
unchanged: explicit link resolution walks the active projection, and
selection, search, and select-all read projected content. Whole-Terminal
equality leaves production entirely and remains a test oracle.

Behavioral deltas, both intended:

- D1. An arm-only transition no longer emits an update signal (P2: nothing
  observable changed).
- D2. A frame-only interaction mutation whose repaint is already covered by an
  undrained signal emits no further signal -- including when it damages rows
  disjoint from the already-pending damage (P4). Nothing is lost: the pending
  drain delivers it.

Everything else is parity: signals on every recorded effect not already
covered, deliberately conservative recordings included (identical re-hover and
repeated begin-search signal by design, as they do today); an interaction that
records nothing emits nothing; search `onStatus`, copy-on-select,
pane-menu, and open-link callbacks unchanged; `setDefaultColors` (already
outside the equality pattern) unchanged.

Doc accuracy travels with the change: `LogicalLineStore.==`'s doc comment and
the wired attribution probe's claim that two equal terminals are "applyPointer's
own case" both describe the pointer path as an equality caller and must stop
saying so.

## Invariants

- I1. No production owner-queue path copies a `Terminal` for comparison or
  evaluates whole-Terminal (or whole-store) equality, and publish
  classification is O(1) at every site. The ambient pointer-move path that
  caused the incident does no work proportional to retained history; every
  interaction keeps only its mutation's intrinsic cost (explicit link
  resolution and selection walk the active projection, search scans, resize
  reflows) with nothing added on top.
- I2. Update delivery has one funnel and per-class classification, scoped to
  terminal-mutation publication: a frame-only interaction signals iff pending
  frame work exists that no undrained signal already covers; output keeps its
  existing urgent-payload classification; lifecycle-driven signals (process
  start, child result) are preserved unconditionally and never depend on
  terminal consumer work.
- I3. Every consumer-visible `Terminal` mutation records its effect into the
  pending-consumer-work state, per its own damage contract (deliberately
  conservative recordings included). This existing Terminal obligation is now
  load-bearing for all interaction paths, not just `feed`, and the recording
  is the sole authority the host publishes from.
- I4. The applied-transitions capture records a viewport navigation iff the
  navigation changed the viewport, decided from O(1) viewport state -- including
  while full damage is already pending, where the work generation cannot answer.
- I5. `Terminal` and `LogicalLineStore` equality semantics are unchanged; they
  remain the value-semantics oracle tests rely on.

## Proof obligations

- PO1 (I1). An architecture-boundary test, in the house task-local counter
  style, asserts that applying each interaction event class on a host whose
  terminal holds deep retained history performs zero whole-store equality
  comparisons.
- PO2 (I2). Per site: an interaction that records pending work emits a signal
  and the next drained frame reflects it; an interaction that records nothing
  emits none. Audit existing host tests first; classes to cover: selection
  set/clear, select-all, pointer-driven hover set/clear, link cancellation,
  search begin/next/previous/clear (with `onStatus` still firing on a
  recording-free search), scroll by/to/bottom, resize (changed and
  same-size), and a pointer move that mutates nothing. Include the
  conservative-recording parity cases: identical re-hover and repeated
  identical begin-search after a drain each signal, as today.
- PO3 (I2, D2). With an undrained signal outstanding, a further frame-only
  mutation emits no second signal, and the eventual drain's frame carries it.
  Two scenarios: saturated full damage, then a selection, drained once with the
  selection present; and partial damage, signaled, then an interaction damaging
  disjoint rows -- no second signal, one drain carries both.
- PO7 (I2). Lifecycle delivery is untouched: a result-only exit (no terminal
  consumer work) still emits its signal. Audit existing host lifecycle tests;
  add the case only if missing.
- PO4 (D1, P2). An arm-only transition emits no signal, and no consumer
  -observable state differs across it.
- PO5 (I4). Transition capture parity: a navigation that moves the viewport is
  recorded, a clamped no-op is not, and the changed case still records while
  full damage is already pending.
- PO6 (I3, P1). Each interaction mutation's recording contract is pinned at
  the `Terminal` level for selection, hover, scroll, search, and resize --
  what it records on change, on a recording-free no-op, and in the
  deliberately conservative cases (identical re-hover, repeated or unchanged
  search operations). Audit existing TerminalCore coverage and fill gaps
  (scroll no-op vs change is the likely hole; identical re-hover is already
  pinned).
- Validation (not a gate): replay the incident on a slot -- `tree .` to
  saturation, streamed pointer moves, then a keystroke -- and confirm prompt
  echo. No timing threshold is frozen
  (`agent-docs/measurement-discipline.md`).

## Non-goals / Rejected ideas / Accepted risks

- N1. Speeding up `LogicalLineStore.==`. After this change it has no production
  caller; O(history) is fine for a test oracle.
- N2. Touching the iOS client or tailnet transport. The sample clears them.
- N3. Bounding interaction work intrinsic to a mutation -- explicit link
  resolution's and selection's active-projection walks, search scans, resize
  reflow. Pre-existing costs, unchanged by this plan.
- RI1. Coalescing pointer events on the owner queue. Masks the cost instead of
  removing it, keeps O(history) per drained event, and loses per-event
  semantics (gesture completion, click arming). Likely to be re-proposed
  because it looks like the direct fix for "queued mouse moves"; the queue
  depth is only harmful because each entry is expensive.
- RI2. A chunk-storage-identity fast path inside `==` (the copied value shares
  CoW storage, so identical-buffer chunks could short-circuit). This is the
  cheap fix: small diff, keeps the pattern. Rejected because it is the third
  workaround on the same site -- it keeps an O(record count) floor per mouse
  move, makes cost depend on accidental sharing, and preserves the structure
  in which the host re-derives what the mutation knew, so the class of freeze
  can recur.
- RI3. A per-mutation "did consumer-visible state change" report as the
  publish authority, combined with the outstanding-signal flag. Rejected: it
  creates a second authority that can disagree with the recorded damage, and
  when it does, a deliberately conservative repaint (identical re-hover
  damages its rows by contract) is recorded but never signaled, stranding the
  repaint until an unrelated wake. A report defined to agree with the
  recording is the recording; one authority cannot drift.
- AR1. The single funnel leans entirely on I3. A future consumer-visible
  mutation that fails to record pending work goes unpublished, where equality
  would have caught it. Accepted because equality was itself the wrong oracle
  (it also fired on invisible state, which is how D1 existed), the obligation
  is already documented at Terminal's damage funnel, and PO6 pins it per
  mutation class.

## Implementation discretion

- The shape of the hoisted gate in the host (wrapper closure vs shared
  predicate helper), and how the viewport-change report reaches the transition
  capture (Bool-returning scroll mutations vs O(1) before/after viewport
  reads).
- Placement and naming of the PO1 counter instrument.
