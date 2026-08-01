# Findings -- append-only evidence chain

### F1 -- source audit identifies five candidates and seven provisional non-candidates

- Status: established as an inspection baseline; candidate verdicts remain
  open.
- Date and investigator: 2026-08-01, agent session with Dan.
- Commit and worktree state: `e66bcc3`, dirty. The worktree already modifies
  `lib/TerminalPTY/Package.swift` and
  `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalFlightRecorder.swift` for
  the separate flight-recorder Deque work; no claim here attributes those
  changes to this investigation.
- Commands, inputs, or reproduction: repository-wide `rg` audit for
  `removeFirst`, FIFO names, head/start offsets, manual bit words, ordered
  deduplication, and array-plus-map representations; targeted reads of the
  cited production paths and pinned swift-collections 1.6.0 sources under
  `references/swift-collections/`.
- Observation:
  - `TerminalPTYHost.applyOutput` appends every PTY output chunk to
    `recentOutput`, then removes the excess prefix after 64 KiB. The buffer is
    maintained unconditionally; its array-valued consumers are package test
    APIs, not the production pane adapter.
  - `TerminalPTYHost.process` appends lifecycle events and drains them with
    `removeFirst`; `TerminalPTYHost.resumeCommandsAfterMasterClose` contains a
    second drain of the same FIFO.
  - `Terminal.ScrollbackBuffer` owns `[GridRow]`, `storageStart`, explicit
    clearing of evicted row storage, and a compaction threshold. It provides
    logical zero-based indexing, head/back removal, suffix materialization,
    equality, and bulk clear. `TerminalScrollbackRetentionTests` continuously
    proves evicted cell arrays are released rather than merely hidden behind
    the logical head.
  - `Terminal.tabStops` is `Set<Int>`. Cursor motion filters and sorts it;
    resize filters it; mutation inserts, removes, or clears nonnegative column
    indexes. Pinned `BitSet` is an ordered collection and exposes ranged member
    slices whose first/last operations match the neighbor queries.
  - `LaunchPolicy.mergedEnvironment` uses an array and linear lookup to
    preserve first-seen order while replacing later values. That is the
    defining semantic combination of `OrderedDictionary`.
  - `pendingInput` uses array contiguity directly in `Darwin.write`;
    `TerminalDamageAccumulator` is a reusable profiling-backed word array;
    CLI parsing and kitty stacks are tiny; alerts and MRU are small model-level
    arrays with broader package implications; viewport and builder arrays do
    not have sustained FIFO behavior.
- Inference: `recentOutput`, `pendingEvents`, `ScrollbackBuffer`, tab stops, and
  environment merging are legitimate research candidates because the proposed
  collection matches their existing abstraction. The other sites do not pass
  that source-level fit test today.
- Competing interpretations:
  - Matching an abstraction does not establish that a dependency or conversion
    is worthwhile. In particular, `pendingEvents` and environment merging may
    be too small or infrequent to justify any change.
  - Deque removes logical front-shift machinery but retains geometric capacity
    and uses COW; either can dominate ScrollbackBuffer's current tradeoffs.
  - BitSet's ordered lookup may simplify tab stops without moving whole-feed
    performance enough to matter.
- Uncertainty: no queue-depth, allocation, memory-census, or paired performance
  measurement was taken. The audit proves candidate fit, not benefit.
- Next action: T1-T6 in `README.md`, then independent prototypes only for the
  candidates whose proof surfaces and module costs survive that audit.

### F2 -- prior maximal ablation closes recentOutput without a new prototype

- Status: complete; candidate dropped by D1.1.
- Date and investigator: 2026-08-01, agent session with Dan.
- Commit and worktree state: current tree after `31b7250`; the flight recorder
  now uses `Deque` and `TerminalPTYHost` already depends on `DequeModule`. The
  current dirty paths do not include the TerminalPTY package.
- Commands, inputs, or reproduction: inventoried `recentOutput`,
  `setTestUpdateHandler`, `observedOutputContains`, `setTestOutputHandler`,
  `applyOutput`, and `publishPendingUpdate`; read
  `TerminalPTYHostAsyncSupport`; reconciled research 17 F9, F14, and D5.
- Observation:
  - Production maintains the rolling 64 KiB array, but no production consumer
    reads it. Its snapshots, callbacks, and subsequence queries are package-test
    support, including the late-observer contract after host quiescence.
  - Research 17 F14 deleted both maintenance statements and measured the maximal
    possible benefit. Nothing attributable disappeared from the profile;
    `scrollback-stream` changed from -2.65% in quick mode to +0.85% in confirm
    mode, and the apparent `style-churn` improvement moved with unrelated plan
    time. D5 rejected the ring-buffer, copy-path, and production-gating shapes.
  - A Deque conversion would retain the same package-test Array boundaries and
    replace only the two-line append-and-trim policy. Complete deletion already
    bounds its possible application-level benefit.
- Inference: H1's original ranking omitted a directly applicable closed
  decision. The candidate does not satisfy this investigation's benefit bar and
  should not consume a second prototype or paired run.
- Uncertainty: the code has moved since research 17, but the rolling-buffer
  mechanism and its consumer boundary are unchanged. No new evidence identifies
  a changed workload or cost that would invalidate F14/D5.
- Next action: T2, the `pendingEvents` queue-shape audit.

### F3 -- pendingEvents is a real reentrant FIFO with one potentially broad batch

- Status: complete; H2 survived to the diagnostic resolved in F4.
- Date and investigator: 2026-08-01, agent session with Dan.
- Commit and worktree state: `8dd5172`, dirty only outside the TerminalPTY
  package when the audit began.
- Commands, inputs, or reproduction: traced every `process(_:)`,
  `pendingEvents`, `execute(_:)`, `drainCommittedOutput`,
  `resumeCommandsAfterMasterClose`, and `signalSession` reference in
  `TerminalPTYHost.swift`; read `PaneLifecycleReducer.handle(_:)` and the pinned
  `Deque.popFirst()` implementation; mapped the reducer and host suites.
- Observation:
  - External submissions and Dispatch callbacks are serialized on the owner
    queue. They call `process(_:)` with `isReducing == false`, so the appended
    event is removed and handled before another queue callback can interleave.
    Their pending shape is one event.
  - Command interpretation has two synchronous reentrant producers. A
    `.signalSession` command can append one `.sessionDrained` witness directly.
    A `.drainOutput` command reads the committed PTY bytes in 16 KiB chunks and
    calls `process(.output(...))` for every chunk, followed by `.outputEOF`,
    while the outer reduction still owns the drain loop.
  - For `C` committed bytes, that exit-before-EOF path can therefore queue
    `ceil(C / 16 KiB) + 1` events before the reducer resumes. The code accepts
    `C` from the positive `Int32` returned through the bytes-available ioctl and
    imposes no smaller queue bound. Array head removal shifts every remaining
    event in that batch, so this is not structurally a single deferred slot.
  - `resumeCommandsAfterMasterClose` is a second FIFO drain because source
    cancellation may suspend command interpretation after `.closeMaster`. Its
    deferred teardown tail can append one session-drained witness; it does not
    create the broad output batch.
  - `LifecycleReducerTests.exitBeforeEOF` pins output delivery before EOF,
    master close, session signaling, and reporting. The host tests
    `largeFragmentedOutput`, `exitBeforeEOFConverges`, and
    `shutdownCompletionJoinsDispatchSources` cover byte order before exit,
    final committed output before the result, and resumption only after the
    master/source join. These are behavioral and container-insensitive.
  - Pinned swift-collections 1.6.0 implements unique-storage `Deque.popFirst()`
    in O(1) and `append(_:)` in amortized O(1). `pendingEvents` never escapes the
    host, so no read path shares its COW storage before the next mutation.
- Inference: `pendingEvents` is not merely a one-element deferral. Deque would
  make its FIFO role structural and remove repeated suffix shifts from the only
  path that can accumulate a batch. The already-landed target dependency keeps
  the source delta local to `TerminalPTYHost.swift`.
- Competing interpretation: ordinary operation and the session-drain path still
  use a one-element queue, and representative exit tests may observe only one
  committed chunk. The prototype should record actual high-water marks before
  D1 takes a cleanup whose broad shape is possible but uncommon.
- Uncertainty: this audit establishes the code-level bound, not the Darwin PTY
  queue's typical committed-byte count at leader exit.
- Next action: T8, with diagnostic queue-depth observation during the host and
  lifecycle suites before the temporary instrumentation is removed.

### F4 -- representative hosts never accumulate more than one pending event

- Status: complete; candidate dropped by D1.2.
- Date and investigator: 2026-08-01, agent session with Dan.
- Commit and worktree state: `8dd5172`; temporary diagnostic instrumentation
  was applied only to `TerminalPTYHost.swift` and removed after the run. The
  production source is byte-for-byte back at its pre-diagnostic state.
- Commands, inputs, or reproduction: temporarily updated a per-host high-water
  count after each of the three `pendingEvents` enqueue sites and emitted it at
  completed teardown only when `DANTERM_PENDING_EVENTS_DIAGNOSTIC` was set; ran
  `DANTERM_PENDING_EVENTS_DIAGNOSTIC=1 swift test --package-path lib/TerminalPTY
  --filter TerminalPTYHostTests`.
- Observation:
  - All 78 selected tests in four suites passed. The opt-in external ssh/tmux
    tests remained skipped by their existing gate.
  - Every completed instrumented host emitted
    `DANTERM_PENDING_EVENTS_MAX=1`. This includes the large 256 KiB fragmented
    output case, the leader-exit-before-EOF final drain, source-cancellation
    join, forced cleanup, rapid create/close races, and chatty-output shutdown.
  - At depth one, `Array.removeFirst()` removes the sole element and shifts no
    retained suffix. The broad formula in F3 remains structurally true, but the
    representative behavioral suite found no instance of it producing a batch.
  - No Deque prototype was needed to decide the candidate. Converting the
    storage would add `import DequeModule` and change one private property plus
    two drains; it would delete no separate head index, compaction, or ownership
    mechanism.
- Inference: H2 resolves to its competing explanation. Existing Array storage
  is the simpler representation for the observed single deferred event, despite
  the target already carrying the dependency.
- Uncertainty: the external ssh/tmux suite and arbitrary real workloads were not
  observed. This is enough for a structural-cleanup decision because no speed
  claim exists and the conversion can be reopened if a sustained batch is ever
  demonstrated.
- Next action: T3, the independent `ScrollbackBuffer` contract audit.

### F5 -- ScrollbackBuffer fits Deque, but its explicit reopening gate is unmet

- Status: complete; candidate dropped for this adoption pass by D1.3.
- Date and investigator: 2026-08-01, agent session with Dan.
- Commit and worktree state: `8dd5172`; no TerminalCore source or package change.
- Commands, inputs, or reproduction: enumerated every `ScrollbackBuffer` method
  and caller; read pinned swift-collections 1.6.0 Deque collection, removal,
  storage, equality, and Sendable sources; mapped TerminalCore budget,
  retention, resize, copy-isolation, equality, history, and census tests;
  reconciled memory research 15 F4/D1/backlog and CPU research 17 F8.
- Observation:
  - The current wrapper provides O(1) logical count and random access,
    amortized-O(1) append/front removal, indexed mutation, suffix and full Array
    projections, tail removal, bulk clear with optional capacity retention, and
    logical equality. It manually clears the evicted row, advances
    `storageStart`, and periodically copies the live suffix after at least 1,024
    dead slots reach half the backing Array.
  - Pinned `Deque<GridRow>` supports the same random-access, append,
    `popFirst`, tail-removal, remove-all, equality, Sendable, and sequence
    construction needs. Unique-storage append is amortized O(1), front removal
    is O(1), and removal moves the element out of its slot, so the evicted
    `GridRow.cells` allocation is not retained by the container.
  - Deque grows capacity by roughly 1.5x, retains that opaque capacity across
    front removals, and exposes no public capacity. Its COW mutations are O(n)
    when storage is shared. `Terminal` is a value passed through snapshots and
    copied by `withUnlimitedScrollbackForTesting`; the current Array has the same
    COW category, but only paired feed/scrollback evidence could establish that
    the replacement does not change its cost.
  - Existing coverage is container-insensitive and sufficient for a future
    prototype: `TerminalScrollbackRetentionTests` continuously proves immediate
    row-cell release and clear; budget/census tests prove bounds and accounting;
    resize tests exercise suffix/tail removal and reconstruction; copy and
    bounded/unbounded oracle tests exercise COW independence; history,
    selection, search, fixture, and equality suites cover ordering and logical
    value semantics.
  - Memory research 15 D1 already evaluated a true ring, selected the current
    O(1) slot reset, and measured the remaining dead storage as row shells near
    27 KiB rather than the prior 19-22 MiB cell-retention defect. Its backlog
    permits reopening only when compaction copying is measured, compact row
    storage changes move economics, or a profile attributes time to
    `compactIfNeeded`.
  - None of those conditions is present. Research 17 F8 attributes the sampled
    scrollback value traffic mostly to required destruction of evicted nested
    cell storage, not compaction, and no current profile artifact or research
    finding names `compactIfNeeded`.
  - `TerminalCore` currently has no package dependency and the test gate runs
    `core-purity-lint.sh --forbid-imports` over its sources. Deque adoption would
    require a deliberate package and purity-architecture change, not merely the
    local type replacement that `TerminalPTYHost` can make.
- Inference: Deque is a technically viable future representation, and the
  existing behavioral proof surface is ready for it, but this audit supplies no
  evidence that clears the project's recorded reopening bar. Dependency
  adoption elsewhere does not change that conclusion.
- Uncertainty: the periodic compaction cost has still never been isolated. That
  is the named reason to profile if a user-visible or measured scrollback cost
  later points here; it is not a reason to prototype speculatively now.
- Next action: T4, the independent BitSet API and tab-stop proof-surface audit.

### F6 -- BitSet is an exact tab-stop fit with disproportionate module cost

- Status: complete; candidate dropped by D1.4.
- Date and investigator: 2026-08-01, agent session with Dan.
- Commit and worktree state: `8dd5172`; no TerminalCore source or package change.
- Commands, inputs, or reproduction: inventoried every `tabStops` read and
  mutation; read pinned swift-collections 1.6.0 BitSet initialization, ranged
  slicing, bidirectional collection, range intersection, membership mutation,
  equality, storage, and Sendable sources; read all dedicated tab-stop tests and
  the TerminalCore manifest/purity gate.
- Observation:
  - The stored universe is always nonnegative terminal columns. Initialization
    inserts the every-eight defaults; HTS inserts the cursor column; TBC removes
    one or all; resize discards columns outside `0..<newColumnCount` and adds
    defaults only for newly introduced columns.
  - HT and CHT need ordered successors; CBT needs ordered predecessors. The
    current Set implementation filters and sorts for each navigation, and HT
    separately filters and computes `min()`.
  - Pinned `BitSet` is a sorted bidirectional collection of nonnegative Int
    members. `tabStops[members: (cursor.column + 1)...]` exposes successors and
    `tabStops[members: ..<cursor.column]` exposes predecessors without sorting;
    stepping or reversing those slices expresses CHT/CBT counts. Membership is
    O(1), `formIntersection(0..<newColumnCount)` expresses resize truncation,
    and insert/remove/remove-all/default sequence construction are direct.
    BitSet is Sendable and Equatable by member set.
  - `TerminalTabStopTests` covers custom insert/clear, invalid forms, HT at the
    last column, multi-stop forward/backward movement and clamping, pending
    state, resize retention/defaulting, and equality. `TerminalTests` covers the
    default-stop and padding result. These tests are behavioral and
    representation-insensitive; no container-specific test is missing.
  - The set is bounded by terminal width and normally contains roughly one stop
    per eight columns. The current allocations and sort are real but small; no
    profile or user-facing symptom names them.
  - The product is `BitCollections`, not the `Collections` umbrella. Even that
    narrow dependency requires adding swift-collections and the product to
    `lib/TerminalCore/Package.swift`, importing `BitCollections` in
    `Terminal.swift`, and replacing the local gate that currently runs
    `core-purity-lint.sh --forbid-imports` over TerminalCore. Unlike
    TerminalPTYHost, TerminalCore does not already carry this dependency.
- Inference: BitSet makes ordered nonnegative membership structural, but the
  removed mechanism is too small to justify a package-architecture change on
  its own. Shared future plumbing cannot be counted before another TerminalCore
  adoption independently earns it.
- Uncertainty: no diagnostic allocation count or paired feed run was taken.
  Neither would decide the architectural mismatch without a measured tab-stop
  bottleneck, so stopping before the prototype is the cheaper valid decision.
- Next action: T5, the OrderedDictionary launch-environment audit.

### F7 -- OrderedDictionary preserves launch environment order and precedence directly

- Status: complete; structural case survives to T11.
- Date and investigator: 2026-08-01, agent session with Dan.
- Commit and worktree state: `8dd5172`; baseline LaunchPolicyTests green before
  the prototype.
- Commands, inputs, or reproduction: read `LaunchPolicy.mergedEnvironment` and
  all LaunchPolicyTests; read pinned swift-collections 1.6.0
  `OrderedDictionary` keyed subscript, `updateValue`, values projection,
  Sendable, sequence, and storage sources; ran
  `swift test --package-path lib/TerminalPTY --filter LaunchPolicyTests`.
- Observation:
  - The public and host-facing contract remains `[EnvironmentEntry]`. The local
    helper traverses inherited, advertised, then pane entries; the first
    occurrence fixes position and every later occurrence replaces the complete
    entry in place, making the last value win without moving its name.
  - Pinned OrderedDictionary keyed assignment and `updateValue(_:forKey:)`
    overwrite `_values[index]` when the key exists and append both key and value
    only when it is new. `values.elements` returns the ordered values as an
    Array in O(1), so `OrderedDictionary<String, EnvironmentEntry>` preserves the
    existing value boundary without a map or per-entry projection.
  - OrderedDictionary is conditionally Sendable, though the local value never
    escapes before projection. Equality is irrelevant because the helper
    returns the existing Equatable Array contract.
  - `LaunchPolicyTests.environmentOverrides` pins first-seen ordering while TERM
    and DANTERM_PANE receive later values. `paneEnvironmentHasFinalPrecedence`
    adds another advertised duplicate and pins the final pane value.
    `cwdFallbacksAreAccessibleAndUnique` separately pins requested/home/root
    ordering; the collection change cannot reach it but the same suite protects
    the complete resolved plan.
  - The baseline run passed 11 tests. No behavior change is proposed, so these
    representation-insensitive tests are the right before/after proof; a test
    that names OrderedDictionary would be strictly worse.
  - `PaneLifecycle` is not subject to TerminalCore's import-free gate. The
    TerminalPTY package already pins swift-collections 1.6.0 for
    TerminalPTYHost; the prototype needs only the `OrderedCollections` product
    on the PaneLifecycle target and one source import. The product adds the
    ordered-collections module to this target even though the package download
    is already paid.
- Inference: this candidate both matches the exact invariant and has a localized
  dependency cost. The remaining question is concrete source economy: whether
  the package-product/import delta is smaller than the manual helper it deletes.
- Uncertainty: launch environments are small and launch-only, so there is no
  speed claim and no useful performance measurement. T11 decides only the
  structural and maintenance tradeoff.
- Next action: T11, prototype the helper and compare the complete diff before
  taking or dropping it.

### F8 -- OrderedDictionary is behaviorally correct but buys no source economy

- Status: complete; candidate dropped by D1.5 and prototype removed.
- Date and investigator: 2026-08-01, agent session with Dan.
- Commit and worktree state: `8dd5172`; the prototype touched only
  `lib/TerminalPTY/Package.swift` and `LaunchPolicy.swift`, then both files were
  restored exactly. No production code change remains.
- Commands, inputs, or reproduction: added the `OrderedCollections` product to
  PaneLifecycle, imported it, replaced the Array lookup loop with
  `OrderedDictionary<String, EnvironmentEntry>` keyed assignment and
  `values.elements`; ran the same targeted command as F7; inspected the complete
  diff; removed the prototype.
- Observation:
  - The candidate LaunchPolicyTests passed the same 11 tests as the baseline,
    confirming deterministic first-seen order, last-layer values, pane
    precedence, and the unaffected root fallback chain.
  - The complete source delta was seven insertions and seven deletions across
    two files. In `mergedEnvironment`, four loop-body lines disappeared, but an
    external type declaration, values projection, import, and three-line target
    dependency replaced them.
  - The cold candidate build compiled the full OrderedCollections product --
    OrderedDictionary, OrderedSet, hash-table, and support source files -- before
    rebuilding PaneLifecycle and its dependents. The package download was
    already present, but the target/module build and conceptual dependency were
    new.
  - The existing helper is private, launch-only, linear in a small environment,
    and already covered behaviorally. The prototype made no speed claim and no
    performance measurement was warranted.
- Inference: the candidate is abstraction fit without net simplification. It
  broadens the target build and reader vocabulary while leaving source size and
  observable behavior unchanged, which fails this investigation's adoption bar.
- Uncertainty: compile work is cached after the first build and was not timed as
  a product metric. The decision does not depend on a build-time claim; the
  structural delta alone is net neutral.
- Next action: T6, recheck the seven provisional non-candidates before closing
  the investigation.

### F9 -- all seven provisional non-candidates remain rejected

- Status: complete; no site promoted, and D2 retains all seven rejections.
- Date and investigator: 2026-08-01, agent session with Dan.
- Commit and worktree state: `8dd5172`, dirty outside the audited production
  paths. This task made no production or package change.
- Commands, inputs, or reproduction: re-read each storage declaration,
  mutation, and consumer; mapped the behavioral tests and explicit bounds; and
  checked the relevant package dependency boundary. This was a structural
  audit, not a performance experiment.
- Observation:
  - `TerminalPTYHost.pendingInput` appends bytes, advances
    `pendingInputOffset` after partial writes, and passes the remaining suffix
    directly to `Darwin.write` through `Array.withUnsafeBytes`. Each owner turn
    writes at most 64 KiB and leaves the contiguous suffix queued behind a
    dispatch write source. Backpressure tests queue 4 MiB, prove the pending
    byte census, bounded shutdown, and post-seal discard. Deque would make a
    wrapped readable region possible and require segmented writes or
    linearization without deleting the offset needed for partial syscalls.
  - `TerminalDamageAccumulator` is already the specialized representation a
    generic bit collection would replace: a reusable `[UInt64]`, direct bounded
    bit mutation, in-place clear/reset, full-frame escalation, and delayed
    `Set<Int>` materialization only at the public drain seam. Dedicated damage
    tests cross word boundaries, reset sizes, deduplicate rows, and cover full
    escalation. Research 17 sampled the accumulator but provides no new result
    that overturns the profiling-backed local word representation; adopting
    BitCollections would also end TerminalCore's import-free boundary.
  - CLI parsing copies or removes prefixes only in short-lived command argument
    arrays. Most parsers already use integer indexing; the remaining removals
    consume optional flag/value pairs or the two required pairs of `agent
    attach`. The protocol package has no external dependency, and its parser
    suite pins accepted commands and exact errors. There is no streaming queue
    or growing grammar state for Deque to model.
  - The primary and alternate Kitty keyboard stacks are independently capped
    at `kittyKeyboardStackDepth == 8`. Overflow moves at most seven `UInt16`
    values, while push, last-value query/update, tail pop, reset, and value
    equality all fit Array directly. `TerminalKittyKeyboardTests` pins the cap,
    oldest eviction, per-screen isolation, negotiation, and reset behavior.
  - Alerts are newest-first model state capped at 100. They are inserted at the
    front and evicted at the back, but callers also filter the complete history,
    remove arbitrary pane-owned entries, mutate matching alerts, compare model
    values, and project Array rows in display order. The cap and ordering are
    explicitly tested. Deque would improve one bounded insertion while
    broadening the symlinked DanTermCore package boundary and complicating its
    dominant whole-list operations.
  - `mruOrder` deliberately admits empty, duplicate, stale, and incomplete
    arrays from restore-like or transient states, then `reconcileMru` preserves
    the first live occurrence, appends missing live tabs, and hoists selection
    only outside an active frozen cycle. Tests explicitly pin each malformed
    input and canonicalization result. OrderedSet would make duplicates
    unrepresentable before the repair seam and would not replace the frozen
    Array snapshot or indexed cycle cursor.
  - Live viewport rows are fixed-height indexed arrays; height resize performs
    occasional bulk prefix displacement or insertion, width resize maps every
    row, and render/projection code depends on random access and Array value
    boundaries. Reflow, projection, damage, and other builder arrays append and
    then traverse or materialize in bulk. The only sustained front-evicting row
    store is `ScrollbackBuffer`, already decided separately by D1.3.
- Inference: every site still has either a load-bearing Array property, a small
  explicit bound, a richer repair/value contract than the proposed collection,
  or no repeated FIFO behavior. None makes enough current mechanism
  structural, deletes enough bookkeeping, or removes a demonstrated cost to
  justify promotion.
- Uncertainty: future scale or profiles can reopen the narrow conditions listed
  in README. This audit does not claim that Array is universally faster; it
  establishes that no present conversion clears this investigation's adoption
  bar.
- Next action: close the investigation with no implementation plans extracted.
