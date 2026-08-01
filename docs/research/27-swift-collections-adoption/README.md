# Appropriate swift-collections adoption

Research started: 2026-08-01.

- [findings.md](findings.md) -- the append-only evidence chain, beginning with
  the source audit that produced the candidate and non-candidate lists.
- [decisions.md](decisions.md) -- one take/drop decision per candidate after
  its behavioral, ownership, and cost evidence is complete.

## Purpose

This doc owns one question: **where should DanTerm replace a hand-rolled or
poorly matched standard-library container with the corresponding
apple/swift-collections data structure?** The goal is not dependency adoption
for its own sake. A conversion must make an invariant structural, delete
meaningful bookkeeping, or remove a demonstrated cost while preserving the
behavior and ownership properties of the current storage.

The flight recorder's planned linked-list-to-`Deque` conversion triggered the
broader audit. That conversion is outside this doc; it establishes that
swift-collections 1.6.0 is an accepted, pinned dependency in `TerminalPTY`, but
it does not make every superficially similar collection a good conversion.

## Investigation rules

- Read the pinned 1.6.0 source under `references/swift-collections/` before
  proposing a type. Verify its API, complexity, COW behavior, capacity policy,
  module product, and `Sendable`/`Equatable` behavior from source rather than
  memory.
- Prefer a conversion when the collection makes a current invariant structural
  or deletes a manual implementation of the same abstraction. Reject it when
  the current type has a load-bearing property the replacement lacks, such as
  contiguous bytes for a syscall.
- Preserve module layering. A type used in `TerminalCore`, `PaneLifecycle`, or
  the symlinked `DanTermCore` requires the dependency product in every package
  that compiles those sources; an otherwise minor cleanup does not justify
  broadening module dependencies silently.
- Audit behavioral coverage before prototyping. Tests protect ordering,
  retention, bounds, equality, and output contracts, never the selected
  container's private layout.
- A microbenchmark may rank containers or expose a mechanism, but it is
  diagnostic. Any durable application-level speed claim follows
  `agent-docs/terminal-performance.md`: paired candidate/baseline trees and the
  workload that actually contains the changed path.
- Hot `TerminalCore` changes require the applicable paired benchmark even when
  the intended outcome is structural, because a container crossing that path
  can regress feed throughput through COW or generic dispatch.
- Decide candidates independently. Shared package plumbing is not evidence
  that two conversions belong in one implementation plan or commit.

## Trigger and current evidence

The source audit at `e66bcc3` with a dirty worktree found five plausible sites,
ranked by fit rather than promised speed (F1). Subsequent reconciliation with
the existing CPU-profile research closed the first site without a new prototype
(F2, D1.1):

1. ~~`TerminalPTYHost.recentOutput`: a rolling 64 KiB byte window currently
   shifts retained bytes with `Array.removeFirst` after every saturated append.~~
   Dropped by D1.1: the prior maximal ablation measured no attributable benefit.
2. ~~`TerminalPTYHost.pendingEvents`: a reentrant FIFO expressed as an array
   with two `removeFirst` drain loops.~~ Dropped by D1.2: every instrumented host
   in the representative suite observed a maximum depth of one.
3. ~~`Terminal.ScrollbackBuffer`: an array, logical head offset, dead-slot
   clearing, and periodic compaction implementing a bounded random-access
   deque.~~ Dropped for this adoption pass by D1.3: memory research 15's explicit
   reopening gate remains unmet.
4. ~~`Terminal.tabStops`: a nonnegative integer set whose consumers repeatedly
   filter and sort to find ordered neighbors.~~ Dropped by D1.4: the API fit is
   exact, but the small bounded set does not justify ending TerminalCore's
   enforced import-free boundary.
5. ~~`mergedEnvironment`: a first-seen-ordered, last-value-wins map implemented
   as an array plus linear name lookup.~~ Dropped by D1.5: the prototype was
   source-line neutral and compiled the full OrderedCollections module for one
   small launch-only helper.

No new performance measurements have been taken by this investigation. Research
17 F14 already measured complete deletion of `recentOutput`, which bounds a
Deque conversion, and rejected all three replacement shapes in D5. The flight
recorder's Deque conversion has since landed at `31b7250`, so
`TerminalPTYHost` already depends on and imports `DequeModule`; the remaining
candidates cross different target or package boundaries and must justify that
cost independently.

## Current hypotheses

### H1 -- the rolling recent-output window is not an adoption candidate

Mechanism: after 64 KiB, every output chunk appends and removes a prefix from an
`Array`, shifting the retained suffix on the serialized PTY owner queue. A
`Deque<UInt8>` represents the bounded window directly; production reads can
stay collection-based while package test APIs materialize `[UInt8]` only at
their value boundary.

Research 17 F14 ran the stronger experiment: complete deletion, which is the
maximum possible benefit of replacing the buffer. Nothing attributable vanished
from the profile, paired `scrollback-stream` changed sign between quick and
confirm runs, and D5 rejected the ring-buffer, copy-path, and production-gating
shapes. A Deque still matches the abstraction, but the two-line Array policy is
not enough bookkeeping to justify reopening a measured null result. D1.1 drops
the candidate.

### H2 -- the pending lifecycle-event FIFO is too small to justify conversion

Mechanism: `pendingEvents` exists specifically to queue events produced while
the reducer is already executing. `Deque` encodes append-at-tail/pop-at-head
without shifting. Competing explanation: the queue almost never contains more
than one or two events, so changing it deletes no meaningful mechanism and only
adds an imported type.

F3 confirmed a structurally broad exit-drain path, but F4's temporary
high-water diagnostic observed a maximum depth of one in every completed host
across the 78-test host selection, including fragmented output,
exit-before-EOF, teardown, forced cleanup, and race cases. At depth one,
`Array.removeFirst` moves no suffix. A Deque would add an import and type change
without deleting meaningful mechanism, so D1.2 drops the candidate.

### H3 -- ScrollbackBuffer remains deferred until its prior reopening gate fires

Mechanism: `ScrollbackBuffer` manually implements the exact logical interface
of a random-access deque. `Deque.popFirst` should destroy the removed `GridRow`
immediately, eliminating both dead-slot blanking and compaction while retaining
integer indexing, suffix reads, and back removal.

F5 confirms that pinned Deque APIs can preserve the logical interface and make
dead prefixes unrepresentable. However, memory research 15 D1 already selected
the O(1) vacated-slot reset, measured its remaining dead row shells at about 27
KiB, and deferred a true ring until compaction appears in a profile, compact row
storage changes move cost, or another measurement names the copy. None has
occurred; research 17 F8 attributes scrollback value traffic to required row
destruction rather than compaction. The conversion would also end
`TerminalCore`'s enforced import-free package architecture. D1.3 drops it for
this adoption pass without a prototype.

### H4 -- BitSet fits tab stops but not TerminalCore's dependency boundary

Mechanism: tab stops are nonnegative integer membership with ordered predecessor
and successor queries. `BitSet` stores that universe compactly and exposes
ordered ranged slices, avoiding `filter` plus `sort` on cursor movement.

F6 confirms that pinned APIs express forward/backward movement through ordered
ranged slices, resize through range intersection, and mutation, equality,
Sendable, and default construction directly. The existing tab-stop suite covers
the complete behavioral surface. However, tab stops are bounded by the terminal
width and the conversion would require changing TerminalCore's package manifest
and import-free purity gate for one private set. That architectural cost exceeds
the deletion of two small filter/sort expressions, so D1.4 drops the candidate
without a hot-core prototype.

### H5 -- OrderedDictionary fits launch merging but adds more machinery than it removes

Mechanism: environment merging is exactly a first-seen-ordered map whose later
layers replace the value without moving its key. `OrderedDictionary` makes that
contract structural instead of relying on array lookup and replacement.

F7 confirmed pinned in-place replacement and the O(1) ordered values projection.
F8 then prototyped the exact conversion: behavior stayed green, but the complete
diff added seven lines and removed seven across the manifest and source, while a
cold build compiled the full OrderedCollections module for one small launch-only
helper. D1.5 drops the conversion because the existing loop already states the
contract clearly and has complete behavioral coverage.

## Candidate dispositions

| Rank | Current storage | Candidate | Expected reason to take it | Required gate |
| --- | --- | --- | --- | --- |
| Closed | `TerminalPTYHost.recentOutput` array | `Deque<UInt8>` | Dropped by D1.1: prior maximal ablation found no attributable benefit | Reopen only with new evidence that invalidates research 17 F14/D5 |
| Closed | `TerminalPTYHost.pendingEvents` array | `Deque<PaneLifecycleEvent>` | Dropped by D1.2: representative hosts observed depth one | Reopen only if a workload demonstrates sustained multi-event batches |
| Closed | `Terminal.ScrollbackBuffer` | `Deque<GridRow>` | Dropped by D1.3: prior ring-buffer reopening gate remains unmet | Reopen on measured compaction cost, changed row-move economics, or equivalent new evidence |
| Closed | `Terminal.tabStops` set | `BitSet` | Dropped by D1.4: exact fit does not justify TerminalCore dependency architecture | Reopen only with a broader independently justified TerminalCore collections dependency or measured tab-stop cost |
| Closed | launch environment array | `OrderedDictionary<String, EnvironmentEntry>` | Dropped by D1.5: exact fit produced no source economy and broadened the target build | Reopen only if the merge becomes shared, materially larger, or independently measured |

The ranking sets investigation order, not commit grouping. D1 records a
separate take/drop verdict for each row.

## Task ledger

### Phase 1 -- verify the source audit and proof surfaces

- [x] **T1 / F2 -- recent-output contract and prior-decision reconciliation.**
      Inventoried every consumer and reconciled research 17 F14/D5. Production
      has no reader; package-test callbacks require arrays and late evidence;
      complete deletion already measured no attributable benefit, so D1.1 drops
      the candidate without reopening its output contract.
- [x] **T2 / F3 -- lifecycle queue shape.** Traced every reentrant path into
      `process(_:)`. Ordinary owner-queue entries drain one event immediately;
      exit-before-EOF can enqueue `ceil(committedBytes / 16 KiB)` output events
      plus EOF before reduction resumes, while session signaling can enqueue one
      drain witness. Existing reducer and host tests cover FIFO output delivery,
      exit convergence, and master-close cancellation resumption.
- [x] **T3 / F5 -- scrollback contract and prior-gate reconciliation.** Mapped
      every operation to pinned Deque APIs and existing budget, retention,
      resize, copy, equality, and census coverage. Research 15 D1 already
      deferred this exact ring conversion behind evidence that still does not
      exist; the import-free `TerminalCore` gate adds an architectural cost.
      D1.3 drops it for this pass without prototyping.
- [x] **T4 / F6 -- BitSet API fit and dependency review.** Pinned ranged slices,
      range intersection, mutation, equality, Sendable, and construction APIs
      cover every tab-stop operation, and existing tests cover the behavioral
      contract. D1.4 drops the conversion because one small private set does not
      justify changing TerminalCore's manifest and import-free purity gate.
- [x] **T5 / F7 -- OrderedDictionary semantics.** Pinned keyed assignment and
      `updateValue` replace in place, new keys append, and `values.elements`
      preserves the ordered `[EnvironmentEntry]` boundary. Launch-policy tests
      cover cross-layer duplicates, deterministic output, final pane precedence,
      and root fallback ordering. The localized package cost survives to T11.
- [x] **T6 / F9 -- non-candidate audit.** Rechecked all seven sites against
      their current consumers, bounds, behavioral coverage, and module cost.
      Each original rejection held; F9 records why none was promoted.

### Phase 2 -- prototype candidates independently

- [x] **T7 -- resolve recentOutput after T1.** No new prototype: research 17 F14
      already tested the maximal form by deleting the buffer entirely, so a
      Deque cannot produce a larger benefit. D1.1 records the drop.
- [x] **T8 -- resolve pendingEvents after T2.** An environment-gated high-water
      diagnostic ran the host selection before any container conversion. All 78
      selected tests passed and every completed host reported depth one. The
      diagnostic was removed; D1.2 drops the conversion without adding a
      structure-only test or retaining prototype code.
- [x] **T9 -- resolve ScrollbackBuffer after T3.** No prototype: research 15 D1
      already evaluated and deferred the true ring shape, and F5 found none of
      its explicit reopening evidence. D1.3 keeps the existing buffer.
- [x] **T10 -- resolve BitSet tab stops after T4.** No prototype: F6 rejects the
      package-boundary cost before a hot-core implementation or benchmark is
      warranted. Reopen under D1.4's explicit conditions.
- [x] **T11 -- prototype OrderedDictionary after T5.** Baseline and candidate
      LaunchPolicyTests both passed 11 tests. The complete prototype was 7
      insertions and 7 deletions across two files and compiled the full
      OrderedCollections module. The prototype was removed; F8 and D1.5 record
      the drop. No launch-time speed claim or measurement was made.

### Phase 3 -- decide and graduate

- [x] **D1 -- take/drop each ranked candidate.** F2-F8 drop all five ranked
      candidates independently; none clears its structural, measured, module,
      or maintenance-cost gate.
- [x] Extract each cohesive accepted conversion, behavioral obligations, and
      quantitative gate into a plan. No conversion was accepted, so there is
      no implementation plan to extract.
- [x] Close this doc after every candidate and provisional rejection has a
      recorded disposition and accepted work has either graduated to plans or
      been explicitly parked. D1 and D2 record all twelve dispositions; no
      accepted work remains.

## Rejected

F9 rechecked these source-inspection rejections against their current callers,
bounds, coverage, and package implications. D2 retains all seven.

### `pendingInput` -> Deque

Reject. The write path deliberately uses an array plus offset so
`Darwin.write` receives one contiguous byte region through `withUnsafeBytes`.
A circular buffer can split its readable bytes and would add syscall or
linearization machinery. Reopen only if profiles identify input-buffer
compaction or retention as a real cost and a segmented-write design is compared.

### `TerminalDamageAccumulator` -> BitArray or BitSet

Reject. The reusable word array is profiling-backed hot-path
machinery: it records bounded row damage without hashing and materializes the
public `Set<Int>` only when drained. Reopen only if a current profile names it
again and a candidate preserves reusable storage and the public determinism
seam.

### CLI parser argument arrays -> Deque

Reject. CLI argument lists are tiny, short-lived, and outside a
hot path; `removeFirst` is simpler than adding a collection dependency to the
protocol package. Reopen only for a materially larger streaming grammar.

### Kitty keyboard stacks -> Deque

Reject. Each stack is explicitly bounded to eight elements, so
front removal moves at most seven `UInt16` values. Reopen only if the terminal
contract raises that bound substantially.

### Alerts -> Deque

Reject. Alerts are capped at 100 and the UI/model contract uses
newest-first array traversal and filtering. The app-level model and symlinked
core would pay broader dependency plumbing for a small bounded shift. Reopen if
alert retention or update frequency grows materially.

### MRU tab order -> OrderedSet

Reject. The tab count is small, array order is part of the model
contract, and reconciliation intentionally accepts malformed input long enough
to canonicalize duplicates and dead IDs. Reopen if tab scale or repeated MRU
reconciliation becomes measured work, or if the model contract changes to make
invalid order unrepresentable.

### Viewport row arrays and short-lived construction arrays -> Deque

Reject. Viewport rows need ordinary indexed and contiguous-array
operations, while builder arrays append and consume in bulk rather than evicting
from the front. Reopen only for a specific call site with sustained FIFO use.

## Caveats and reopening conditions

- The flight-recorder Deque conversion landed at `31b7250`; the current
  worktree does not modify the TerminalPTY package. Candidate experiments must
  still use immutable baseline/candidate trees so unrelated work is not
  attributed to a container conversion.
- Deque and BitSet capacity are implementation details. Memory decisions use
  measured allocation or project census values, never logical count times
  element stride alone.
- `Terminal` is a value type. Any replacement inside it must audit snapshots
  that intentionally share COW storage across read-only projection boundaries;
  an otherwise O(1) container can create an O(n) first mutation.
- The flight recorder plan imports `DequeModule` only into `TerminalPTYHost`.
  `BitSet`, `OrderedDictionary`, and any `DanTermCore` use need their own product
  and package-boundary decisions.

## Outcome

Investigation closed. D1.1-D1.5 independently drop all five ranked candidates,
and D2 retains all seven non-candidate rejections after the F9 audit. No new
swift-collections conversion, implementation plan, or performance claim is
approved by this doc. The already-landed flight-recorder Deque remains the only
adoption in scope of the triggering work.
