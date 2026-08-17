# Give each production fence a typed payload instead of an erase/un-erase enum pair

## Problem

Every controller-owned synchronous fence in the PTY layer erases its result
into `TerminalPTYProductionFenceOutput`, then immediately un-erases it at the
call site:

```swift
let fence = performAccountedFence(kind: .checkpoint, operation: .frameState)
guard case .frameState(let frameState) = fence else {
    preconditionFailure("frame-state fence returned the wrong payload")
}
```

There are eight such blocks in `TerminalPaneSession.swift`, each a crash on a
mismatch the type system could reject outright. The erasure buys nothing: the
host's `fence(countsAsProduction:)` is already generic over its return value,
and the host's dozen uncounted siblings (`fencedSnapshot`,
`fencedFlightRecordingCapture`, `fencedFlightRecordingStream`, ...) each return
their own type directly. Only the counted path erases.

Three of the eight -- `setRenderingAvailable`, `synchronizeState`, and
`readSelectedTextSynchronizing` -- are the same three lines verbatim: take a
checkpoint frame-state fence, unwrap it, `consume(frameState:result:nil,
transitions:nil)`.

Desired outcome: a fence hands back exactly the payload its operation produces,
a wrong payload is a compile error rather than a runtime crash, and the one
checkpoint-read shape exists once.

This is the audit's S30, a symptom of its T4 root cause -- the same algorithm
written twice, differing by one output shape -- whose combined fix names "one
generic counted `fence<T>`".

### Load-bearing premises

- **The generic counted path already exists.** `fence(countsAsProduction:)` is
  generic and returns the payload with the host's production entry count.
  `performProductionFence` adds only the erasure on top of it.
- **Neither enum leaves the two files.** They are `package`, and nothing in
  `app/`, `cli/`, or `tests-ui/` names them; only the two sources and two test
  files in `lib/TerminalPTY` do. The host and controller edits cannot be split
  into separately-compiling commits.
- **One fence operation is dead.** `flightRecordingStateSynchronization()` is
  `public` with zero callers and zero tests anywhere in the repo. It arrived in
  `737c99c2` and was superseded by `flightRecordingStreamFence` in `46a2da45`.
  The `.stateSynchronization` production operation exists only to serve it.
- **The fence census is externally observable.** `app/TerminalBenchmark.swift`
  emits per-kind fence counts plus `hostEntryCount` in its benchmark JSON, and
  `scripts/terminal-benchmark-validation.py` invalidates a block whose kind sums
  or host count disagree with its totals. Kinds and counts are a contract.
- **A structural gate pins the current shape.** `scripts/terminal-fence-accounting-lint.sh`,
  in `just test` with its own self-test, requires one `queue.sync` in the host,
  one counted path in the host, no production source naming an uncounted host
  fence, and exactly one production-fence call in all of `Sources` + `app`
  sitting inside the controller's accounted choke point. Its recorded purpose is
  that every controller fence is timed and attributed, cross-checked against the
  host's independently maintained raw count.
- **The census ordinal is read inside the fence.** The host increments its
  production count inside the `queue.sync` closure and returns the value it read
  there, so the count a fence reports is that fence's own ordinal.
- **The accounting has one load-bearing test.**
  `everyControllerFenceIsAccounted` pins every per-kind bucket exactly and the
  controller-versus-host cross-check; `packageTestFencesDoNotPolluteProductionCount`
  pins that uncounted host fences never advance the production census.

## Decision

Replace the operation/output enum pair with **one typed operation value**. The
host keeps a single generic production-fence entry point; the operation it takes
carries its own payload type, so `.frameState` yields a frame state and nothing
else can come back. The controller's accounted fence becomes generic over that
payload and returns it directly.

This keeps both choke points exactly where the accounting gate already pins them
-- one counted path in the host, one production-fence call inside the
controller's timed helper -- so the gate and its self-test need no edit. That is
the reason this shape wins over one named host method per operation, which would
scatter counted calls across the controller and force the gate's structural
check to be replaced by a weaker textual one: a naming rule plus per-site
proximity checks over N sites, in place of one global count with one right
answer.

The operation set stays closed: only the host can mint an operation value, so
this is not the same as handing the controller a closure over the host's
internals. That variant would keep the gate too, but only by making the host's
owner-isolated members reachable from the whole package, which trades a
documented set of six operations for "any closure over host state".

Three consequences:

- The eight `guard case`/`preconditionFailure` blocks and both enums are
  deleted. Every payload's type is known statically at its call site.
- The dead `flightRecordingStateSynchronization()` and the
  `.stateSynchronization` operation are deleted with them. The host's uncounted
  `fencedStateSynchronization()` stays; a real host test drives it.
- The three identical checkpoint reads collapse into one private controller
  helper that fences and applies the frame. Each caller keeps its own
  torn-down guard, its own full-damage prefix, and its own tail.

Critical files: `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`,
`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift`, and the
two test files that name the affected symbols. `app/TerminalBenchmark.swift` and
`scripts/terminal-fence-accounting-lint.sh` are read-only contracts this change
must not move. As the final task, once the work has landed, fill the blank
Status cell for S30 in `docs/scratch/2026-08-11-simplification-audit.md` with the
landing commit SHA; that audit defines a SHA in the ranked table as the
authoritative signal that its source reading is stale.

## Invariants

- **I1.** No fence hands back a payload the caller must un-erase. A caller that
  asks for one payload and uses another fails to compile, and no fence path
  carries a `preconditionFailure` for a payload mismatch.
- **I2.** One place in the host counts a production entry, one place performs
  the `queue.sync`, and one place in the controller times and attributes a
  production fence. No production source can take a counted fence outside that
  helper, and the existing structural gate still proves it.
- **I3.** Every surviving fence keeps its kind and its count. The controller's
  attributed total still equals the host's independently maintained census, and
  the benchmark artifact's per-kind and host-count fields keep their meaning.
- **I4.** The timed unit stays the fence itself. No work moves inside a fence
  closure, and no projection built from a fence payload moves inside the
  controller's clock window.
- **I5.** A checkpoint read still fences and applies the frame in one
  synchronous main-actor step, and the full-damage union still precedes the
  applied frame's own damage union.
- **I6.** Counted and uncounted host fences stay distinctly named, and no host
  fence takes the counting decision as a call-site argument. An uncounted fence
  therefore cannot select production accounting, and a production source reaches
  the counted entry point only through the controller's accounted helper. The
  counted entry point stays reachable from package test targets, which is what
  makes the naming and the gate the enforcement rather than access control.

## Proof obligations

- **PO1** (I3) -- every production fence charges exactly one entry to the kind
  it charges today, and the controller total equals the host census. Extend the
  existing accounting test so all three checkpoint entry points that now share
  one helper are each shown to charge one checkpoint fence.
- **PO2** (I6) -- an uncounted host fence still leaves the production census at
  zero.
- **PO3** (I2) -- the structural gate still fails a production source that takes
  a counted fence outside the accounted helper, and its self-test still passes
  unedited.
- **PO4** (I5) -- a checkpoint read never publishes a stale row, a fenced
  selection read observes pointer input taken in the same step, and a hidden
  wake still defers its repaint until reveal.
- **PO5** (I3) -- benchmark block validation still promotes a consistent
  `fenceMetrics` object and still invalidates a perturbed one.
- **PO6** -- `just test` passes, and a slot-launched app still opens a pane,
  renders output, and quits gracefully through its teardown fence.

## Non-goals

- Moving fence timing or kind attribution out of the controller. See RI2.
- Retiring the uncounted host fences, or repointing their tests at the counted
  ones. Their distinct names are I6.
- Deduplicating the `TerminalFlightRecordingStateSynchronization` assembly that
  remains at the host and stream-fence sites. Separate, optional, and it must
  not move a timing boundary.

## Accepted risks

- **AR1.** Deleting a `public` controller method. It has no callers, and this
  app has one user who upgrades by replacing the bundle.

## Rejected ideas

- **RI1.** The finding's own cheaper fallback -- keep the enums and add
  unwrapping helpers so the crash text exists once. It keeps the erasure and the
  runtime crash, which are the defect.
- **RI2.** Move timing and kind attribution into the host so the counted methods
  time themselves and the controller-side gate could be deleted. It costs more
  than it removes. It destroys the cross-check the accounting rests on: the
  host's raw census is the backstop that sees a bypass the controller cannot, and
  the benchmark validator asserts the two numbers agree, so one owner of both
  numbers cannot cross-check itself. It needs a lock rather than a fence, because
  the view reads a fence counter on every publish and a fenced read would itself
  be an unaccounted fence. The wait can only be measured outside the owner
  queue while the ordinal must be read inside it, so the counters split in two
  anyway. The deterministic clock the tests inject also drives the publish
  deadline, so it would have to exist in both places and agree. And the host
  would store a kind it cannot interpret or validate, since the same payload is
  fenced under two different kinds -- so misattribution, the error that would
  actually corrupt the artifact, stays a call-site convention either way.
- **RI3.** One host method per payload taking the counting decision as a
  parameter. It defeats the gate's name-based bypass check: a counted fence and
  an uncounted one become the same call spelled with a different argument, so no
  rule over names can tell a production bypass from a test inspection. It also
  forces every test call site to spell out a flag and discard a count it does not
  want.
- **RI4.** Assembling a fence payload's expensive projection inside the host's
  counted method. Full-history serialization would land inside the controller's
  clock window and inflate a benchmarked metric.
- **RI5.** Pass the accounting inputs into the host's counted methods while
  leaving the storage in the controller. It cannot stop a caller from handing
  over throwaway metrics, so it buys a stronger convention rather than a proof,
  and it still drags the uninterpretable kind into the host.

## Implementation discretion

- Where the typed operation value is declared and how its cases reach the host's
  owner-isolated payload builders, so long as the builders stay shared between
  the counted and uncounted paths and the host's internals are not widened
  further than that placement requires.
- Whether the shared diagnostic payload gets its own builder for symmetry with
  the consumption payload, provided each keeps its own transition-versus-drain
  order.

## Commit progress

- [x] 1. refactor(pty): give each production fence a typed payload
- [x] 2. docs(scratch): mark S30 landed in the simplification audit

The audit tick is its own commit because the cell it fills is the landing
commit's SHA, which cannot exist inside that commit.

## Implementation notes

- The typed operation is a generic struct holding one owner-isolated builder
  closure, and only the host's own file can mint a value: the `package static`
  factories are the whole operation set. The host's payload builders moved from
  `private` to `fileprivate`, and the close and handler-install steps became
  named `fileprivate` builders of their own, so the factories reach them without
  widening host internals past that one file.
- The diagnostic payload took the optional builder the discretion clause allows,
  so the counted and uncounted diagnostic fences share one drain-then-transitions
  read.
- One character class in `scripts/terminal-fence-accounting-lint.sh` had to widen
  to `performAccountedFence[<(]`: the accounted choke point now carries a generic
  parameter list, so the regex that finds it no longer sees `(` right after the
  name. Every check the gate performs is unchanged, and its self-test passes
  unedited.

## Follow Up

- `TerminalFlightRecordingStateSynchronization` is still assembled twice, in
  `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift` at
  `fencedStateSynchronization()` and `fencedFlightRecordingStream(from:)`. This
  plan named it a non-goal because deduplicating it must not move a timing
  boundary.
