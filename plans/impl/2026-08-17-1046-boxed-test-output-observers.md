# Boxed test-output observers

## Problem

Registering a test-output observer on `TerminalPTYHost` while a few hundred
kilobytes of child output cross a real PTY kills the test process with a stack
overflow (SIGBUS). Not a failed expectation -- process death, which reports as
`exited with unexpected signal code 10` and names no test.

The path is `#if DEBUG`, so nothing ships with the defect. It became reachable
when the host suite moved onto childless real PTY channels: output now arrives
in ~200-byte read turns instead of one synchronous staged call, so a chunk count
that used to be 1 is now thousands, and more tests will want large output over
time.

### Evidence

Reproduced headlessly: a childless PTY channel, a bare
`observeTestOutput { _ in true }`, and 512 KiB written at the child end. The
same 512 KiB with no observer registered is fine, and so is 4 MiB.

The cause is confirmed by ablation. Removing the copy-empty-refill step in
`recordTestOutput` removes the symptom; taking the local copy without mutating
the stored array also removes it; dropping `keepingCapacity` does not. So the
store-back is what builds the chain.

A standalone probe with no PTY and no host reproduces it and names the
mechanism: iterating a Swift `Array` whose `Element` is a **function type** with
`for x in array` yields each element wrapped in a fresh reabstraction thunk that
captures the original closure. Re-storing that loop-bound value grows the stored
closure by one wrapper layer per chunk, and releasing the result recurses one
stack frame per layer. The probe shows the stored closure's context pointer
changing every round under the dance and staying fixed when the element is
boxed in a class. This is language behavior, not an optimizer artifact: it
happens identically at `-Onone` and `-O`, and it is not specific to `@Sendable`
-- a plain function element wraps too. Reading the element by subscript, or
through `filter` / `removeAll(where:)`, does not wrap.

A repo-wide sweep of `app/` and `lib/` found exactly one instance of this shape:
`testOutputObservers`. Every other function-typed collection either never
iterates (`inputCompletions`), iterates only to invoke and discard
(`quiescenceObservers`, `CheckpointCapture`'s scrollback reads), or already
holds the closure inside a reference box -- `TerminalFlightRecorder`'s follow
notices are that shape today and are the in-package precedent.

### Desired outcome

An observed output stream of any length cannot build a per-chunk release chain.
The trap for test authors goes away with it: today the rule "no test may push
more than a few hundred KiB past an armed match" lives only in a promoted plan's
`## Follow Up`, where the next author will not find it.

## Decision

Give a subscribed observer an identity: store observers as a reference-typed
box that holds the closure and is never read out and written back as a function
value. The copy-empty-refill step in `recordTestOutput` stays exactly as it is
-- boxing is what makes it safe, so its stated reason for existing survives
untouched.

This is the structure in which the defect cannot occur, rather than a rule
against writing the code that triggers it: a class reference is copied verbatim
by every traversal form, so no future edit to this loop can reintroduce the
chain. Verified against the real host -- with the box in place, 4 MiB through a
registered observer costs the same as 4 MiB with none, and the package suite
stays green.

`observeTestOutput`'s signature does not change. Callers keep passing a closure
and keep getting the discarded-byte count back.

Two smaller pieces travel with it:

- The regression test below is the durable home for the constraint the plan's
  `## Follow Up` was holding. Once the bug is gone the constraint is gone too,
  so nothing needs rehoming; the promoted plan stays as it is, because plans are
  history.
- A short rule in AGENTS.md **Code Style**, scoped to callbacks that survive a
  traversal of the collection holding them: keep those behind stable reference
  identity rather than storing a loop-bound function value back. A collection
  that only invokes its elements and discards them is unaffected, which is what
  `quiescenceObservers` does. The hazard is invisible at the call site and the
  correct shape already exists in the same package, so the rule is worth three
  lines.

## Invariants

- **I1** An observer sees the retained lookback as its first chunk and every
  later chunk in stream order with no gap between them.
- **I2** An observer that returns `false` receives no further chunks; one that
  returns `true` receives the next chunk.
- **I3** A host tears down with no observer still subscribed, and the retained
  lookback survives teardown so a wait armed afterwards can still be answered.
- **I4** The number of output chunks an observer receives does not bound how
  much output a host can take. Applying N chunks to an observed host costs no
  more stack than applying one.
- **I5** Nothing changes for a shipping build: the observer path stays
  `#if DEBUG`, and the host never asks whether it is under test.

## Proof obligations

- **PO1** (I4) A host on a childless real PTY channel with a bare observer
  registered takes roughly a megabyte of child output and reaches a fenced
  snapshot showing the tail. At HEAD this kills the process; note in the test
  preamble that the failure mode it guards is process death, not a failed
  expectation, since a reader who sees no assertion about stack depth will
  otherwise not know what the size is for. It belongs in the unserialized
  childless suite -- it forks nothing.
- **PO2** (I1, I2) A test on `observeTestOutput` directly: an observer
  registered after output has already been applied sees the retained lookback
  and the chunks that follow it as one ordered stream with no gap, including
  across the join between the two; and one that returns `false` receives nothing
  afterwards. Existing coverage does not discharge this -- it pins continuity
  from one applied chunk to the next, and that the lookback answers a wait, but
  not the join between replay and stream and not the drop-on-`false` edge. This
  change rewrites the loop that decides both.
- **PO3** (I3) A test that teardown releases a still-subscribed observer: what
  the observer captured is deallocated once the host has quiesced, and no chunk
  reaches it afterwards. Existing coverage that a wait armed after quiescence is
  still answered from the lookback keeps passing unchanged.
- **PO4** (I5) `scripts/terminal-pty-host-test-seam-lint.sh` and the release
  build both stay green.

## Non-goals

- Capping, coalescing, or throttling output chunks. The chunk count was never
  the problem; a per-chunk closure wrapper was.
- Changing the bounded lookback window or the discard rule `expectOutput`
  already documents. That rule is unrelated to this defect and stays as is.
- Migrating the other function-typed collections found by the sweep. None has
  the store-back shape, so there is nothing to fix in them.

## Rejected ideas

- **RI1 Keep bare closures and stop re-storing them** -- replace the dance with
  `removeAll(where:)`, which the probe confirms is chain-free over 200k rounds.
  Rejected: it fixes this line rather than the shape, so re-introducing the
  copy-empty-refill dance re-introduces the crash, and it calls arbitrary
  observer code while the array is being mutated in place.
- **RI2 Document the output-volume limit instead of fixing it** -- a `///` on
  `observeTestOutput` capping observed output at a few hundred KiB. Rejected:
  it makes a language artifact into a permanent constraint on every future test,
  and the ceiling it names is not derivable from anything a caller can see.
- **RI3 A lint for the pattern** -- rejected: deciding whether a loop-bound
  element is function-typed and gets stored back needs type information a grep
  does not have, and there is one instance in the repo.

## Implementation discretion

- Where the box type lives and what it is called.

## Implementation notes

- The box, `TestOutputObserver`, is nested inside the `TerminalPTYHost` actor
  rather than declared at file scope. `TerminalFlightRecorder.FollowNotice` is
  the in-package precedent for nesting, but there is a second reason here: the
  host is an actor, and `observeTestOutput` is `nonisolated` and reaches its
  state through a `@Sendable` fence closure. The box is not `Sendable`, so it
  has to be built inside that closure -- which is where the existing `append`
  already was, so the call site did not move.
- PO3 asserts release rather than a post-teardown delivery attempt. A first
  version wrote more bytes at the child end after `close()` and expected no
  chunk; the write itself fails, because the host closes the master during
  teardown, so there is no way to offer a torn-down host another chunk. The
  weak-reference check carries the same claim more directly: the host was the
  observer's last owner, so a host that still held it could still call it.
- PO2 passes at HEAD as well as after the change. It is a spec-lock on the loop
  the change rewrites -- the join between replay and stream, and the
  drop-on-`false` edge, had no test before -- not a regression test for the
  crash. PO1 is the one that fails at HEAD, and it fails by killing the test
  process with signal 10, as the plan describes.
