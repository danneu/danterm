# Checkpoint scheduling as a derivation

## Problem

The light checkpoint's schedule is hand-maintained. 47 `.scheduleCheckpoint`
sites are scattered through `update()`, plus a nested per-event switch in
`.paneSemanticsChanged` that gates on live agent attachment. Together they
approximate a rule that actually lives in the capture code: *write a checkpoint
when what we persist changed.*

The approximation is already wrong in both directions:

- **Over-schedules.** Clearing pane and tab alerts schedules a checkpoint;
  alerts are not in the persisted payload. `commandEnded` with an agent attached
  schedules a checkpoint whose bytes are identical to the previous one.
- **Silently drifts.** Nothing fails when a new persisted facet forgets to emit
  `.scheduleCheckpoint`, and nothing fails when a facet stops being persisted
  but keeps its emission site.

Desired outcome: the schedule is derived from the persisted projection, so
correct scheduling for a new facet is automatic and the two cannot disagree.

### Load-bearing premise: the command-end exception is a leftover

Under the derivation the agent-attached `commandEnded` branch disappears rather
than becoming a named exception. Confirmed against the code:

- `PaneSemanticRecoveryState.apply` ignores `.commandEnded`; the command memo is
  set on start and deliberately survives end
  (`lib/DanTermCore/Sources/DanTermCore/PaneSemanticRecovery.swift`, pinned by
  `PaneSemanticRecoveryTests`).
- The `.paneSemanticsChanged` arm mutates no model state on `.commandEnded`.
- A light checkpoint carries no scrollback, so scrollback freshness at command
  end belongs to the separate enriched tier and is unaffected.

So a command-end checkpoint persists nothing that changed. The branch is a
leftover from deleted mirror fields.

## Decision

The light checkpoint payload is a pure function of two inputs: the model
snapshot and the per-pane semantic recovery snapshots. Make that pair a named
value in core, and make it serve both roles:

- The scheduler compares the current value against the value most recently
  written, and schedules only on a difference.
- The writer builds its capture from that same value.

Because the compared value *is* the capture's input, the schedule cannot
disagree with what capture persists. Deriving from a remembered baseline rather
than a per-message before/after diff is also what makes it work at all: a pane's
recovery state is reduced in the session before the message reaches `update()`,
so no "before" view of that half exists at message time.

The baseline is the projection most recently *handed to the writer*, not the one
most recently confirmed on disk. The checkpoint writer is a single serial queue
with one work item per checkpoint, encode included, so capture order is disk
order: the last projection handed over is the last that will land. Advancing the
baseline at capture keeps comparison and eventual disk content in agreement even
with a write in flight, and needs no coordination with write completion.

The light tier's timer becomes fixed-window coalescing rather than a trailing
debounce: a difference arms the window if it is not already armed, and never
re-arms it. The window closes on a bounded schedule regardless of how much
traffic arrives, and the write is decided at close by comparing the projection
then against the baseline. Trailing-edge re-arming is what makes a continuous
message stream able to postpone a pending write forever, and that starvation is
a live data-loss path today: a shell rewriting its title on every prompt keeps
resetting the debounce. Fixed-window coalescing removes the re-arm, so no stream
-- persisted or not -- can delay a write past one window. The runtime already
uses exactly this pattern for the reconcile sweep.

`Command.scheduleCheckpoint` and all 47 emission sites are deleted. The decision
moves to the runtime's message dispatch, which recomputes the projection after
each message settles. The comparison and the projection type stay pure and
testable in core; only the memory of the last written value lives in the
runtime, mirroring how the enriched tier already splits its pure policy from its
runtime timer.

### Behavioral scope

- Alert-clearing messages stop scheduling checkpoints.
- `commandEnded` stops scheduling checkpoints.
- Any message that mutates persisted state starts scheduling one, whether or not
  it previously remembered to.
- A write whose window closes with nothing changed since the last write writes
  nothing.
- Writes now land within one bounded window of the first change since the last
  write, instead of one quiet period after the last message, so a busy pane no
  longer postpones them. Changes within a window still coalesce into one write.

Restore behavior, the checkpoint file format, the resign-active flush, and the
enriched tier are all unchanged.

## Invariants

- **I1.** A light checkpoint is written if and only if, at the moment the write
  is decided, the current persisted projection differs from the one most
  recently handed to the writer.
- **I1a.** Once the app quiesces, the last successfully written light checkpoint
  equals the current persisted projection -- including when the projection
  changes and then reverts while a write is in flight.
- **I1b.** Within a bounded interval of the first change since the last write,
  the projection current at that moment is handed to the writer -- whatever the
  rate or kind of messages arriving meanwhile. Intermediate projections within
  the interval are coalesced away, not written.
- **I2.** The value the scheduler compares is the value the writer encodes --
  there is no second derivation of "what we persist".
- **I3.** Live state that is not persisted -- zoom, progress, alerts, search,
  agent activity, live command running/idle -- never causes a checkpoint.
- **I4.** The persisted command memo survives command end, and command end alone
  schedules nothing.

## Proof obligations

- **PO1.** For each persisted facet -- tab/group structure, selection, focused
  pane, titles, cwd, colors, themes, font steps, todos, command memo, agent
  session -- a mutation changes the projection.
- **PO2.** For each non-persisted facet named in I3, a mutation leaves the
  projection unchanged.
- **PO3.** Repeating a projection writes nothing; changing it writes; reverting
  before the window closes writes nothing.
- **PO3a.** A change and then a reversion while an earlier write is in flight
  ends with the reverted projection as the last successful write (I1a).
- **PO3b.** An unbroken stream of messages after a persisted change -- both
  non-persisted ones and further persisted ones -- does not postpone the write
  past one window, and what that write carries is the projection current at the
  window's close (I1b).
- **PO4.** A checkpoint capture built from a projection encodes the same bytes
  as the existing light-checkpoint path (I2).
- **PO5.** Command end leaves the projection unchanged while an agent is
  attached (I4).

The existing per-message emission pins in
`lib/DanTermCore/Tests/DanTermCoreTests/CheckpointTests.swift` are rewritten as
projection-difference assertions; the negative pins there (zoom, bell, export,
activation) become PO2 cases.

## Non-goals

- Changing the enriched tier's mutation-driven policy or its window.
- Persisting any facet that is not persisted today.
- Unit-testing the runtime's checkpoint timer, which is untested today and stays
  that way. The write decision it drives is pure and is tested directly.

## Accepted risks

- **AR1.** Every message now costs one model-snapshot walk plus one pass over
  live sessions, on a dispatch path that had no such cost. The runtime already
  treats title, cwd, progress, alert, split-ratio, and command messages as
  high-frequency streams driven by terminal output and live drag, so the cost is
  not assumed immaterial -- it is gated by measurement below, and accepted only
  if that gate passes.
- **AR2.** A failed light-checkpoint write is not retried; disk stays stale
  until the projection changes again. This matches today's behavior -- the light
  tier has never retried -- and the enriched tier, which persists the same model
  structure, does retry. Adding light-tier retry is separate work.

## Rejected ideas

- **RI1.** Comparing the model and recovery *inputs* instead of the projection.
  Cheaper, but the model carries non-persisted state, so it would reintroduce
  exactly the over-scheduling this change removes (I3).
- **RI2.** Keeping the emission sites and deriving only the pane-semantics
  switch. Leaves the drift and the alert over-scheduling in place, so it does
  not deliver the stated outcome.
- **RI3.** Keeping the trailing debounce and adding a second remembered
  projection (last observed) so only genuine changes re-arm it. Two baselines
  instead of one, and it still starves: a stream that changes persisted state on
  every message -- a title-rewriting prompt, a live split-drag -- re-arms every
  time, so I1b would still fail.

## Critical files

- `lib/DanTermCore/Sources/DanTermCore/CheckpointCapture.swift` -- home for the
  projection value and the capture built from it.
- `lib/DanTermCore/Sources/DanTermCore/Persistence.swift`,
  `Model.swift` -- snapshot types need value equality.
- `lib/DanTermCore/Sources/DanTermCore/Update.swift`, `Command.swift`,
  `Msg.swift` -- emission sites, the command case, and the stale coalescing
  comment that references it.
- `app/AppRuntime.swift` -- message dispatch, the remembered baseline, the
  light-checkpoint timer and write, and the resign-active flush.

## Verification

- `just test`.
- **Cost gate (AR1).** Measure the per-message projection cost against the
  runtime's own high-frequency drivers -- a title-rewriting output stream and a
  continuous split-drag -- on a session large enough to matter, with the
  acceptance rule written down before the numbers are taken
  (`agent-docs/measurement-discipline.md`). Failing the gate means the
  projection must be made cheaper, not that the derivation is abandoned.
- Live: run the app on an isolated slot (`just launch-slot`), drive it with
  `danterm --socket`, and watch the light checkpoint file's mtime. Renaming a
  tab or changing a theme writes; toggling zoom, ringing the bell, and ending a
  command under an attached agent do not.

## Implementation discretion

- Where the projection is recomputed within the dispatch path, so long as it
  observes the settled model and precedes the resign-active flush.

## Implementation notes

- Cost-gate acceptance rule, fixed before measurement: in an optimized core probe with
  128 live panes and 100,000 measured projections per workload, both the title-update and
  split-drag workloads must report a median projection cost below 417,000 ns per message.
  That is 5% of an 8.33 ms 120 Hz input interval, the tighter runtime budget; every reported
  aggregate must include its sample count. A failure requires a cheaper projection design.
- Cost-gate result: the optimized probe passed. The title-update workload measured 97,431
  ns/message across 100,000 projections; the split-drag workload measured 51,904 ns/message
  across 100,000 projections. Both are below the fixed 417,000 ns/message limit.
- Live verification exposed that raw recovery entries for sessions without a matching model pane
  could compare unequal even though grafting discarded them and encoded identical bytes. The
  projection now canonicalizes the model and recovery pair into the final grafted light snapshot
  at construction, so its equality is exactly the writer's payload equality.
