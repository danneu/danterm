# Teardown cancels every retained dispatch source from the registry that holds them

Source: PTY-1 in `docs/scratch/2026-08-18-construction-audit.md`, verified
against the tree on 2026-08-20 and pivoted (see Decision).

## Problem

`TerminalPTYHost` owns eight dispatch sources (read, write, canonical-input
retry, process, child-exit poll, grace, session poll, exit bound). Every one
registers in `retainedSources` through `retainUntilCancellation`, and
`completeTeardownIfPossible` refuses to report quiescence until that registry
is empty. But the two teardown paths -- `finishTeardown` (ordinary ladder end)
and `exitBoundElapsed` (host-bound forced path) -- do not walk the registry.
Each hand-enumerates the cancels, in a different order.

The hazard is a quit hang, not a leak: a source that is registered but never
cancelled keeps `retainedSources` non-empty forever, `whenQuiescent` never
resolves, and the forced path cannot rescue it because it enumerates the same
stale list.

Evidence that the hazard is live in practice: the eighth source
(`canonicalInputRetrySource`, commit f77db4ad) had to have its cancel wired
into `closeMaster` and, redundantly, into `finishTeardown` -- the author could
not tell which path owned it. Nothing hangs today only because `exitBoundElapsed`
happens to end in `closeMaster()`.

Desired outcome: adding a source to the host registers it once, and both
teardown paths cancel it with no edit to either. "A teardown path that cancels
only some of the host's sources" becomes unrepresentable.

## Load-bearing premises (verified in `references/libdispatch`)

- P1. `dispatch_activate` on an already-active object is a no-op
  (`references/libdispatch/src/queue.c#_dispatch_lane_resume`, the
  `DISPATCH_ACTIVATE` arm gives up when the state is not inactive).
- P2. Releasing a never-activated source crashes
  (`references/libdispatch/src/queue.c#_dispatch_queue_xref_dispose`,
  "Release of an inactive object"), and cancelling an inactive source only
  sets the cancelled flag -- its cancel handler does not run until the source
  is activated (`references/libdispatch/src/source.c#dispatch_source_cancel`).
  So a cancelled-but-never-activated source would sit in the registry forever.
- P3. `cancel()` is idempotent, and every cancel handler runs asynchronously on
  the host's own serial queue, never inline inside `cancel()`. So cancelling a
  source a second time, or cancelling it before a later call that also cancels
  it, changes nothing observable.
- P4. `closeMaster` is not a teardown path. The reducer issues `.closeMaster`
  in the middle of the ordinary ladder and `activateIO` calls it on a sealed
  host; in both, the lifecycle sources (process, child-exit poll, grace,
  session poll, exit bound) must keep running. It also owns the descriptor
  seal, pending-input rejection, and the descriptor-join barrier that re-enters
  forced cleanup.

## Decision

D1. Teardown enumerates the registry. Both `finishTeardown` and
`exitBoundElapsed` cancel their sources by walking `retainedSources` -- every
entry, activate then cancel (P1 makes activation safe to apply uniformly; P2
makes it necessary) -- and then call `closeMaster()` for its seal, rejection,
and barrier work. No per-source cancel helper is called from either ladder.

D2. The registry entry grows only what the walk needs beyond the source
itself: whether the source is descriptor-backed (already tracked) and how to
clear the host's typed handle to it. It does not carry an activation flag: P1
makes one redundant, so the host's per-source activation bookkeeping
(`readSourceActivated`, `processSourceActivated`, the resume-before-cancel
dance in `cancelReadSource` / `cancelProcessSource`) goes away with it.

D3. The typed handle clears at cancel time, never at release
acknowledgement. The typed field means "the source this host still drives";
the registry means "sources libdispatch has not yet let go of". They
legitimately diverge between cancel and acknowledgement, and replace-on-arm
sources (grace, exit bound) depend on that: a predecessor still awaiting
release must not clear its successor's handle when it finally acknowledges.

D4. `closeMaster` keeps cancelling exactly the I/O plane (read, write,
canonical-input retry) with targeted cancels and keeps its position in each
ladder: last in `exitBoundElapsed`, where it is what drives forced cleanup once
the descriptor sources have joined. In `finishTeardown` the relative order of
the registry walk and `closeMaster` is inert by P3.

D5. While in the region, the comment on `exitBoundElapsed` that cites `I2` by
bare id (a plan id, which AGENTS.md forbids citing) restates the invariant
inline: the bound must not be satisfied by abandoning ownership of a session
that may still be running.

Behavioral scope: none. This is a structural refactor. `resourceSnapshot()`
keeps its shape, no reducer command changes, no public or `package` surface
changes, no new test-control seam on the host
(`scripts/terminal-pty-host-test-seam-lint.sh` binds).

## Invariants

- I1. Every source the host has registered and not yet released is cancelled
  by both teardown paths, including a source registered after this change by
  code that edits neither path.
- I2. Every registered source is activated before the host can wait on its
  release; a host never reaches the state "waiting on a source whose cancel
  handler cannot run".
- I3. An ordinary master close leaves the lifecycle sources running; the ladder
  after `.closeMaster` still signals, escalates, and reaps. Only teardown
  cancels them.
- I4. On the forced path, every driver of the reducer is cancelled before the
  master closes, and forced kill-and-reap begins only after the descriptor
  sources have joined.
- I5. A replace-on-arm source keeps driving the host while its predecessor is
  still awaiting release; the predecessor's release never disturbs the
  successor.
- I6. (Existing, unchanged.) Quiescence means the registry is empty, the
  master is closed, and no launch remains adoptable; `resourceSnapshot()
  .isReleased` is the one observable, and both teardown paths reach it.

## Proof obligations

All through `resourceSnapshot()`; no test names a private field or cancel
helper. There is no first failing test: the tree today cannot exhibit the
hang, so the obligations are characterization plus new coverage for the
sources that no test currently tears down armed.

- PO1 (I1, I6). Shutdown while the canonical-input retry hold is armed (an
  oversized canonical line pending against a long `canonicalInputWait`),
  on the ordinary path and on the forced path
  (`forceExitBoundForTesting()`): the host reaches `isReleased` and the held
  submission resolves `.processEnded`. No canonical-input test asserts release
  today.
- PO2 (I1, I6). Shutdown while the child-exit poll and session poll are both
  armed, ordinary and forced, reaches `isReleased`. The poll is armed by
  injecting a child-exit probe that keeps reporting not-yet-waitable
  (`TransientChildExitProbe` in the host suite is the existing shape;
  collaborator injection, no host seam).
- PO3 (I2). `closeDuringSpawnJoinsInactiveSources` keeps passing; add the same
  scenario on the forced path -- the bound expires while sources are installed
  but not yet activated -- and assert `isReleased`.
- PO4 (I4). `forcedShutdownWaitsForDescriptorJoin` and
  `applicationExitTerminationForcesQuiescenceWithinBound` keep passing
  unchanged; any change in them means the refactor changed behavior.
- PO5 (I3). The ordinary-ladder suites that escalate through hangup,
  terminate, and kill (each stage re-arming grace) and the rapid
  create-close races keep passing and reach `isReleased`. These do not cover
  I5: they let every predecessor acknowledge its cancellation before the
  successor is armed, so a successor-clobbering implementation passes them.
- PO7 (I5). Predecessor and successor overlap, driven through the existing
  lifecycle-gate collaborator: hold source cancellation acknowledgements
  (`holdSourceCancellationAcknowledgements`), escalate the ladder so grace
  re-arms while the predecessor's acknowledgement is still deferred, then
  release the held acknowledgements. The successor must still drive the host:
  the ladder reaches kill and the host reaches `isReleased` from the ordinary
  path, without the application-exit bound firing. An implementation that
  clears or disables the successor's typed handle when the predecessor
  acknowledges fails this and passes PO1-PO6. Same shape for `armExitBound`
  where a second arm overlaps the first one's deferred acknowledgement.
- PO6 (I6). `shutdownCompletionJoinsDispatchSources`,
  `ordinaryTeardownAndAppExitReleaseRegistryOwnership`, and "application
  termination drains the retained registry while main is blocked" keep
  passing; the canonical-input suite keeps passing.

## Non-goals

- No change to which sources exist, when they are installed, or what they do.
- No unification with the single timers in `DanTermSupport/Debouncer.swift`
  or `app/AppRuntime.swift`; they hold one source each and have no registry.
- No new `package` entry point or debug hook on the host.

## Accepted risks

- AR2. No proof obligation starts red. The hazard this plan closes is a
  teardown path that forgets a source, which the current hand-written cancels
  happen to cover, so the obligations are characterization plus the new
  coverage in PO1-PO3 and PO7; unrepresentability, not a live bug, is the
  outcome.
- AR1. D2 relies on P1 (activate is a no-op on an active object). It is
  verified against the pinned libdispatch checkout, not documentation; the
  citation is in Load-bearing premises so a future libdispatch bump can
  re-check it.

## Rejected ideas

- RI1. Clear the typed handle when the cancellation is acknowledged (the
  audit preparer's suggestion). Breaks I5: `scheduleGrace` and `armExitBound`
  replace a source whose predecessor is still in the registry, and the
  predecessor's acknowledgement would clear the successor's handle.
- RI2. Fold `closeMaster` into the registry walk. P4: it runs mid-ladder where
  lifecycle sources must survive, and its position in the forced path is
  load-bearing.
- RI3. Carry an activation flag per registry entry (the audit's original
  shape). Redundant under P1; it preserves the bookkeeping the walk exists to
  remove.

## Implementation discretion

- Whether `closeMaster`'s three I/O-plane cancels stay as targeted calls or
  select their entries through a plane tag on the registry. The hang hazard is
  closed either way by D1; a tag is only worth adding if it reads simpler.
- Whether the registry entry type lives in `TerminalPTYHost.swift` or a
  sibling file in the same target (the seam lint pins the host's path, not the
  target's file list).

## Implementation notes

- D2 says the registry entry carries "how to clear the host's typed handle".
  That is a `SourceSlot` tag on each entry plus one `forgetSource(_:)` switch,
  not a per-entry closure: the host is an actor, so a stored closure that
  touches its state would have to capture the host and would put a retain
  cycle in the registry. The switch also makes the obligation compile-time --
  a new source has to add a case before the file builds again.
- PO7 does not discriminate the way the plan claims. Under D1 the registry
  walk cancels a successor whose typed handle an RI1 implementation had
  cleared, so RI1 converges too and the test passes either way. It stands as
  characterization of I5: every ladder stage re-arms grace over a predecessor
  that has not released yet, and teardown still converges on its own.
- The `armExitBound` half of PO7 has no scenario. `beginShutdown` guards on
  `shutdownRequested`, so a host arms its bound exactly once and two arms
  cannot overlap.
- PO1 and PO2 drive their forced halves with `forceExitBoundForTesting()`
  while cancellation acknowledgements are held, rather than with a short
  `applicationExitBound`. A 1 millisecond bound raced the ordinary ladder and
  lost, which made the forced assertions flaky rather than deterministic.

## Follow Up

- A spawn whose activation gate is released after the host has already
  reached quiescence registers a fresh retained source, so
  `resourceSnapshot().isReleased` flips back to false after teardown
  finished. Seen while writing `forcedShutdownJoinsInactiveSources` in
  `lib/TerminalPTY/Tests/TerminalPTYHostTests/TerminalPTYHostTests.swift`;
  the owner is `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`.
  The test now holds the acknowledgements so the spawn resumes before
  teardown completes, which avoids the case rather than fixing it.
