# Output waits read the flight tape

## Problem

`TerminalPTYHost` carries a `#if DEBUG` retention-and-notify path that exists
only so a test can wait on child output: a 64 KiB lookback window, a discarded
byte counter, a list of boxed chunk observers, and the subscribe entry point
that arms them. Nothing ships with it, but the guard is hand-maintained and no
gate checks it -- `scripts/run-test-suite.sh` has no release-configuration
build. Two consecutive plans have now discharged a "the release build stays
green" obligation by hand.

The host already runs the same mechanism in production, unguarded and always
on. `applyOutput` records the identical byte array to the flight recorder
(`flightTape.record(.feed(bytes))`) one statement before it hands it to the
debug window, and the recorder already offers cursor placement, an
edge-triggered follow notice, and an atomically rearming suffix read -- because
remote-client pane-tape streaming needs them. The debug window is a second,
smaller, worse copy of a facility that is already there.

### Evidence

- The two paths take the same bytes from the same call site. `applyOutput` is
  the only caller of `record(.feed:)`, and it passes `bytes` to both.
- The recorder strictly dominates on retention: 8 MiB / 32,768 events against
  the window's 64 KiB, and its per-subscriber `droppedFeedBytes` is exact,
  where the window's discard counter is global to the host.
- The follow surface on the host (`fencedFlightRecordingBacklogOrigin`,
  `addFlightRecordingFollowNotice`, `fencedFlightRecordingFollowSnapshot`,
  `removeFlightRecordingFollowNotice`) is `package` and carries no `#if DEBUG`.
- The host's initializer already accepts `flightTapeConfiguration` as an
  ordinary domain value defaulting to `.production`, so a test that needs a
  small tape asks for one at construction.
- A follow notice fires on the host's owner queue, inside `record`. Every fence
  on the host is `queue.sync` on that same serial queue, so a notify callback
  that fences synchronously deadlocks. `AppRuntime`'s production subscriber
  already hops off the queue for exactly this reason.

### Desired outcome

The host retains child output for tests in no way at all, and a test-support
wait is built on production APIs that ship. `#if DEBUG` in `lib/TerminalPTY`
drops from seven guarded regions to one (`stageFixtureOutput`), and the
test-support module loses its own guard entirely, so `swift build -c release`
stops being a proof obligation anyone discharges by hand for this code.

## Decision

Delete the host's test-output window, its discard counter, its observer box and
list, its subscribe entry point, and the per-read call that feeds them.

Rebuild the output waits in `TerminalPTYTestSupport` on the flight recorder's
existing subscription: arm at the recorder's backlog cursor so the retained
lookback is the first suffix read, then take a fresh suffix on every notice,
matching the `.feed` payloads incrementally. The no-gap ordering the observers
got from careful fence discipline now comes from a monotonic cursor by
construction, and a stale subscriber is detected per-subscriber instead of
host-wide.

This is the ideal rather than merely a nicer structure because it adds nothing
to production: the recording call it needs is already on the hot path for
production reasons, so there is no new per-read work, no new collaborator, and
no new host or recorder API. The only production edit is deletion. An injected
output-recorder collaborator was considered and rejected (RI1), as was pushing
every recorded event to subscribers at the recording boundary (RI4).

Decisive constraints:

- The waiter matches child output only. The tape carries input and resize
  events on the same stream; those are not output and must not satisfy a wait.
- Nothing running on the host's own queue may fence the host synchronously.
  This binds the notice callback and every terminal outcome the host reports on
  that queue, quiescence included: each must move detachment off the host queue
  before fencing, or the wait deadlocks the teardown it was watching for.
- The waiter owns detaching its own subscription on every terminal outcome --
  match, loss, quiescence, cancellation, and synchronous timeout. The host
  clears observers during teardown today; recorder notices are not cleared, and
  nothing should be added to the host to clear them.

Interface: `expectOutput`, `waitForOutput`, and `waitForOutputSynchronously`
keep their signatures, so the 22 call sites across the two suites do not
change. `observeTestOutput` ceases to exist, and its three direct callers in
the suites move onto the tape.

Their documented rule does change, and the documentation and the recorded
diagnostic change with it. Today they promise a test author that once armed,
no volume of output can defeat a match, and the diagnostic tells a caller to
arm before the flood. Under the bounded guarantee that promise is false and
that remedy is inapplicable to a caller who was already armed. The two losses
are different failures with different remedies -- output discarded before the
wait existed, against output that outran a live wait -- so they must read
differently and each must name a remedy that applies to it.

`scripts/terminal-pty-host-test-seam-lint.sh` keeps its list of banned names
unchanged. The removed names do not belong on it: that list enforces R1 of
`docs/design/2026-08-17-test-seam-rule.md` -- a production component asking
whether it is under test -- and the observer window never violated R1. It is
being deleted because it is a redundant copy, not because it was illegal. The
same document's Consequences section names the debug output-observer window as
a construct that stays; that sentence describes a thing this change removes and
is updated with it.

## Invariants

- **I1** A wait sees the output the host still retains, then every later chunk
  in stream order, with no gap across the join between them. A match is decided
  within one uninterrupted run of output: reported loss is a hard boundary, so
  partial progress from before it is never combined with bytes after it, and a
  needle the child never emitted contiguously cannot satisfy a wait.
- **I2** A wait armed before output that would bury its answer is satisfied by
  that output however it is split across read turns, for any volume in between
  that the host still retains. Beyond retention the wait reports loss under I3;
  it never reports a false absence.
- **I3** A wait whose answer may lie in output the host can no longer produce
  resolves at once as a recorded issue naming the loss, rather than suspending.
- **I4** Input the host writes toward the child, and resizes, never satisfy a
  wait on child output.
- **I5** How much output a wait observes does not bound how much output a host
  can take, and does not grow what the wait itself holds: a wait retains only
  bounded matching progress, never the output it has already matched against.
- **I6** A satisfied wait implies the terminal has already applied the matched
  bytes, so a fenced read taken afterwards sees them.
- **I7** A wait releases what it captured and gives up its subscription at
  every terminal outcome, whether or not the host is still live, and no
  unsatisfied wait can keep a host from quiescing. Output the host retains
  still answers a wait armed after quiescence.
- **I8** The host holds no state, entry point, or per-read work whose only
  purpose is a test-support wait.

## Proof obligations

- **PO1** (I1) A wait armed after output has already been applied sees the
  retained output and the chunks after it as one ordered stream, including
  across the join. This is the spec the superseded observer path bought and it
  transfers unchanged. Separately, a needle whose halves straddle a reported
  loss does not satisfy a wait, so partial progress cannot bridge a gap.
- **PO2** (I2) A match armed before a flood is satisfied by a marker printed
  after it, including when a read boundary splits the marker. Separately, a
  match armed before output that exceeds the host's configured retention
  resolves as a loss report rather than as an absence, so the bound on I2 is
  proved to be loud rather than silent.
- **PO3** (I3) A wait for a marker the host no longer retains resolves
  promptly as a recorded issue. The retention that makes this reachable is a
  tape configuration supplied at host construction, not a flood sized against
  the production budget.
- **PO4** (I4) Bytes the host transmits to the child do not satisfy a wait for
  the same bytes as output.
- **PO5** (I5) A host with a wait armed for the whole stream takes roughly a
  megabyte of child output and reaches a fenced snapshot showing the tail. The
  failure this guards is process death, not a failed expectation.
- **PO6** (I6) Existing coverage that a fenced read after a satisfied wait sees
  the matched bytes keeps passing. The tape records before the terminal feeds,
  where the observers ran after, so this ordering is now carried by the fence
  rather than by statement order and is re-proved, not assumed.
- **PO7** (I7) A wait that is never satisfied releases what it captured once
  the host has quiesced, and the host reaches quiescence with such a wait
  outstanding. A cancelled wait and a wait that hits its synchronous timeout
  each release what they captured while the host is still live. A wait armed
  after quiescence is still answered from retained output.
- **PO8** (I8) The host source contains no test-output retention or observer
  surface, and the arming, draining, and detaching fences do not advance the
  production fence count.

## Non-goals

- Gating or removing `stageFixtureOutput`. It stays `#if DEBUG` and stays the
  host's only guarded region. Whether to defend that one guard with a
  release-configuration build step or a lint is a separate decision.
- Changing the recorder's production retention budget.
- Adding any recording, retention, or delivery mechanism to the host or the
  recorder. The production edit this plan permits is deletion of the host's
  test-output surface; the pane-tape follow API, its consumers, and the
  recorder's own behavior are untouched.

## Accepted risks

- **AR1** A wait now wakes through a queue hop instead of a synchronous
  callback, so it resolves one hop later than before. Accepted: the hop is
  forced by the host's fence design, it is the same hop production already
  takes, and no wait's correctness depends on resolving within a turn -- I6
  covers the one ordering property that did.
- **AR2** An armed match is now bounded by the recorder's retention rather than
  absolute: if more than the whole tape budget is recorded between a wakeup and
  the suffix read that follows it, the marker can be evicted before the wait
  sees it. Accepted: this needs the wait's queue to be starved across hundreds
  of full read-and-parse turns, and the outcome is I3's loud loss report naming
  its own remedy, not a false absence. Buying the absolute bound back costs a
  per-event production push path (RI4).

## Rejected ideas

- **RI1 Inject an output-recorder collaborator the host calls per read.** A
  clean seam, but it adds a call per read turn to production for a test's
  benefit, and a cross-module value call on the hot read path runs into
  `docs/design/2026-07-29-cross-module-value-dispatch.md`. The tape call is
  already there.
- **RI2 Keep the window and defend the guard with a release build in the
  gate.** Measured at roughly 35s against a 79s `just test`, and it buys a
  check on a construct that should not exist. It remains the right answer for
  whatever guard survives, which is why the gate question is a live follow-up
  rather than a closed one.
- **RI3 Add the removed names to the test-seam lint.** The list enforces R1,
  and these names never violated it; adding them would make the list a
  changelog and blunt the rule it encodes.
- **RI4 Give the recorder a lossless subscription that pushes every event to
  subscribers at the recording boundary,** so a matcher consumes payload inline
  and never depends on a deferred read. This restores the absolute armed match,
  but it is `recordTestOutput`'s observer loop relocated into the recorder and
  made unguarded: a shipping build would pay a per-event closure dispatch on the
  read path for a guarantee no production consumer wants, since pane-tape
  streaming coalesces deliberately. It trades the plan's premise -- that
  production gains nothing -- for a bound whose absence is loud and whose
  failure window needs sustained queue starvation to reach (AR2).

## Implementation discretion

- How a wait serializes its own suffix reads against notice-driven ones.
- Whether the wait's subscription state lives in the existing expectation value
  or beside it.

## Implementation notes

- Each wait owns a serial queue, and every suffix read of that wait runs on it:
  the arming read, each notice-driven read, and every detachment. The notice
  fires inside the arming fence, so its read is enqueued before the arming read
  and FIFO order is what makes the cursor advance monotonically.
- The arming read is taken synchronously rather than left to that first notice,
  because `Issue.record` needs a current test and a notice-driven read has
  none. A loss found by either read is therefore reported from the arming
  caller's own task; a loss found later is reported by `satisfied()`.
- The two losses are told apart by whether the read that found the gap was the
  wait's first: a first-read gap is output that was already off the tape when
  the wait was armed, and any later gap is output that outran a live wait.
- A wait detaches before it publishes its answer, not after, so whoever sees the
  answer also sees the subscription gone. That is what lets the fence-count test
  stay synchronous.
- `TerminalPTYOutputExpectation` gained a public `subscriptionId`, which is how a
  test proves the wait gave its subscription up. The superseded weak-witness
  proof does not transfer: the closure the host held used to be written by the
  test, and now it is written by the library.
- The retention-bounded proofs build hosts with tiny tape configurations
  (`retainingNothing`, `retainingOneEvent`) instead of flooding a production
  budget, so a loss is a property of the host under test rather than a race
  between a flood and the machine the suite runs on.
- `containsSubsequence` is now a forward scan over unsafe buffers instead of over
  slices. The lookback a wait matches against grew from a 64 KiB window to the
  whole retained tape, so every retained byte crosses that loop once per armed
  wait.
- The quiescence fallback holds the wait weakly. A host keeps its quiescence
  observers until it quiesces, and the subscription -- not that list -- should
  decide how long the host holds a wait. An armed wait is held by its own notice,
  so the reference resolves for every wait the fallback has to answer.
- `TerminalPTYTestSupport` gained a `TerminalCoreRecording` dependency, because a
  wait now reads `NeutralTerminalRecordingEvent` values off the tape.

## Follow Up

- The gate still has no release-configuration build step, so the one `#if DEBUG`
  region left in `lib/TerminalPTY` (`stageFixtureOutput`) remains a guard nothing
  checks. This plan's non-goals left that decision open, and RI2 measured a
  release build at roughly 35s against the gate.
