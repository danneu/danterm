# Back the flight recorder with `Deque` instead of a hand-rolled list

## Context

`TerminalFlightRecorder` (`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalFlightRecorder.swift`)
is the bounded in-memory capture of one pane's PTY drive sequence. Its storage is
a hand-rolled singly-linked list (`Node` class, `head`/`tail`, a manual `deinit`
unlink loop that exists only to stop recursive release from blowing the stack at
32,768 links) plus a `retainedNodesBySequence: [UInt64: Node]` side index whose
sole purpose is letting `cursorSnapshot(from:)` jump to a mid-list start.

That index is unnecessary. Sequences are assigned exactly one per append and
eviction only ever removes a prefix, so a retained event's position is just
`sequence - firstRetainedSequence` -- arithmetic, not a hash lookup. Backing the
events with an integer-indexed random-access circular buffer deletes the
dictionary, the node allocations, and the `deinit` hazard at once.

The motivation is that deletion: ~60 fewer lines of container bookkeeping, one
fewer lifetime hazard, and no side index to keep coherent with the list. This
matters now because `plans/impl/2026-08-01-1329-pane-tape-follow-stream.md` adds
a polling pump that calls `cursorSnapshot` repeatedly per subscription;
`cursorSnapshot` is the seam that plan depends on and its signature does not
move.

Container choice was settled by an off-tree microbenchmark of the four candidate
containers in isolation (release build, production bounds, 64-byte chunks,
measured 2026-08-01 on this machine). `Deque` won on both steady-state
`record()` throughput and worst-case single-op latency. Two candidates were
rejected on that evidence: array-with-head-offset, whose periodic compaction
memmove costs 160-173 us on a single `record()` -- on the PTY owner queue; and
`RigidDeque`, which is faster still and does compile on this toolchain, but
allocates its fixed capacity eagerly, so every pane would pay ~1.75 MiB up front
even when `budgetBytes` binds first and most of it stays dead, and it is not
exported from the `Collections` umbrella.

Those numbers rank containers against each other. They are **not** an
application-level performance claim, and this plan makes none -- see
`Non-goals / accepted risks`.

Desired outcome: identical observable behavior, with the dictionary, the node
allocations, and the `deinit` gone.

## Approach

Add the dependency to `lib/TerminalPTY/Package.swift`:

```swift
.package(url: "https://github.com/apple/swift-collections.git", exact: "1.6.0")
```

Pinned `exact` deliberately. `Package.resolved` is gitignored (`.gitignore`), so
a range requirement would let a fresh resolve drift off the version
`scripts/fetch-references.py#REFERENCES` pins, contradicting the rule in
`agent-docs/reference-sources.md` that the source you read matches the code you
build. Add `.product(name: "DequeModule", package: "swift-collections")` to the
`TerminalPTYHost` target only -- the `Collections` umbrella would drag
`BitCollections`, `HashTreeCollections`, `HeapModule`, `OrderedCollections`, and
`_RopeModule` into every downstream build for one type.

In `TerminalFlightRecorder.swift`, replace the linked list and its side index
with a single `Deque` of per-event slots carrying the same three fields the
`Node` carries today (the event, its payload byte count, and its cumulative
payload watermark). `Node`, `head`, `tail`, `retainedNodesBySequence`, the
separate `eventCount`, and the entire `deinit` all go away. `cursorSnapshot`
locates its start by index arithmetic off the first retained sequence instead of
a dictionary lookup, and handles the caught-up and fully-drained cases without
reaching past the end.

Behavior that must not change: both `precondition`s in `cursorSnapshot`, the
`hasGap` computation, every field of every returned value type, both retention
limits, and all four accounting counters (`accountedBytes`, `droppedEventCount`,
`droppedPayloadBytes`, `totalPayloadBytes`).

`fromNowOrigin()`, `backlogOrigin()`, `payloadBytes(of:)`, all the
`TerminalFlightRecording*` value types, and both fence wrappers in
`TerminalPTYHost.swift#TerminalPTYHost` are untouched. No caller changes: the
recorder is `package`, its only stored reference is
`TerminalPTYHost.flightTape`, and every read already materializes fresh
`[TerminalFlightRecordingEvent]` arrays.

Two invariants become load-bearing and must be written down as doc comments,
because nothing in the type system enforces them:

- **I1 -- contiguity.** For a non-empty buffer, slot `i` holds sequence
  `slots[0].event.sequence + i`. This is what makes the index arithmetic valid.
  It holds because `record()` is a single straight-line path with no early
  return -- every append increments `nextSequence` exactly once -- and bounds
  enforcement is the only remover and pops only the head. A future "skip empty
  feeds" fast path in `record()` would silently corrupt every `cursorSnapshot`
  with no compile error, so back the comment with a debug assertion. An empty
  buffer is a valid state (a fresh recorder, and any recorder that bounds have
  fully drained) and must satisfy the assertion trivially rather than trapping.
- **I2 -- no escaping copy.** `Deque` is COW, so every retained copy of the deque
  that outlives the next mutation costs one O(n) buffer copy on the owner queue
  at that mutation. One escape is one copy, not a permanent tax -- but the
  snapshot paths run repeatedly, so returning deques instead of arrays would pay
  it repeatedly. Snapshots must keep returning `[TerminalFlightRecordingEvent]`.

## Non-goals / accepted risks

- **AR1 -- high-water slot storage.** `Deque` grows geometrically and never
  shrinks on eviction, so a pane that once reached `eventLimit` retains slot
  storage for the next capacity step at or above 32,768 elements for its
  lifetime, even if `budgetBytes` later evicts it down to a handful of events.
  Accepted, not measured, on the sole grounds that it is bounded and per-pane --
  no claim that payload is the larger term, since under small feeds it is not.
  Document it on the storage declaration so it reads as deliberate.
- **AR2 -- no application-level performance claim.** The container
  microbenchmark ranks containers, not trees. `agent-docs/terminal-performance.md`
  requires `benchmark-quick` then `benchmark-confirm` before a speed claim goes
  anywhere durable, and this refactor is not justified by one -- it is justified
  by the deleted dictionary, node allocations, and `deinit`. So no paired
  benchmark is run and no faster-in-the-app claim is made here or in the commit
  message. If a future change wants to claim the flight recorder got cheaper end
  to end, that claim owes the paired `scrollback-stream` run at that time.

## Rejected ideas

- Array with head offset -- periodic compaction memmove, 160-173 us on a single
  `record()` on the PTY owner queue.
- `RigidDeque` -- eager fixed-capacity allocation (~1.75 MiB per pane regardless
  of use) and not exported from the `Collections` umbrella.

## Implementation discretion

Reserved for implementation, because deciding them differently changes no
observable behavior: the slot type's declaration and name; the exact form of the
contiguity assertion (subject to I1's empty-buffer requirement); whether the
snapshot paths map or slice; the order the methods are edited in.

## Tests

`lib/TerminalPTY/Tests/TerminalPTYHostTests/TerminalFlightRecorderTests.swift`
already covers eviction on all three bounds, gap accounting after eviction,
gap-excludes-already-delivered, both origins, production-bounds extremes, and the
encoded-document round trip -- and none of it touches internal representation, so
it all carries over unchanged as the primary safety net.

This is a behavior-preserving refactor, so these are characterization tests, not
red-green: they must be written and land **green against the current linked-list
code first**, then re-run against the `Deque` version. That ordering is the whole
point -- a test that only ever ran after the change proves nothing about
equivalence.

Auditing every existing `cursorSnapshot` call site shows `firstRetainedSequence`
and `offset` are **never both non-zero**. So the specific bug this refactor can
introduce -- indexing by the absolute sequence and forgetting to subtract
`firstRetainedSequence` -- passes the entire current suite and then returns wrong
events, or traps, in production. Four tests close that:

1. **Cursor inside the retained range after eviction** (non-negotiable). Bounds
   `eventLimit: 3`, record 5 distinct-size feeds so sequences 0-1 evict, then read
   from a cursor at sequence 3. Assert `firstRetainedSequence == 2`,
   `events.map(\.sequence) == [3, 4]`, and no gap. This is the offset>0 /
   firstRetained>0 cell nothing currently reaches.
2. **Caught-up cursor after eviction.** Same recorder, cursor at `nextSequence`.
   Assert empty events, `firstRetainedSequence == 2`, no gap, `nextCursor`
   unchanged. Covers offset-at-end against a non-zero base.
3. **Fully drained recorder.** `budgetBytes: 0`, record two feeds. Assert empty
   snapshot, `accountedBytes == 0`, and that a `.beginning` cursor reports
   `firstRetainedSequence == nextSequence` with both events counted as dropped.
   Covers the empty-buffer fallbacks, which no test currently reaches, and is the
   case I1's assertion must not trap on.
4. **Ring wraparound at scale** (non-negotiable). `.production` bounds, ~3x
   `eventLimit` single-byte feeds. Assert `snapshot()` yields the contiguous run
   ending at `nextSequence - 1` (check first, last, and count -- not the whole
   array) and that a mid-range `cursorSnapshot` returns the exact expected suffix.
   A linked list cannot get ordering wrong across wraparound; a circular buffer
   can, and `productionBoundsFitIPCLine` records exactly `eventLimit` events so it
   never evicts and never wraps.

Each gets the three-section preamble from AGENTS.md, with Scenario written as
spec-first behavior -- there is no incident to name.

## Verification

1. `just fetch-references swift-collections` so the pinned 1.6.0 source is local
   while implementing.
2. `swift test --package-path lib/TerminalPTY --filter TerminalFlightRecorderTests`
   -- the four new tests green on the unmodified recorder, before any refactor.
3. Refactor, then re-run the same filter. Full package:
   `./scripts/test-terminal-pty.sh`, which also covers
   `TerminalPTYHostTests#TerminalPTYHostTests.liveFlightRecordingRoundTrip` (the
   end-to-end path over a real PTY). Debug configuration, so I1's assertion is
   live for tests 3 and 4.
4. `just test` for the whole local gate. `scripts/core-purity-lint.sh` only lints
   `lib/TerminalPTY/Sources/PaneLifecycle` within this package, not
   `TerminalPTYHost`, so no lint invocation changes -- confirm it still passes
   rather than assuming.
5. Live check: `just build-run`, then from a second pane
   `danterm pane tape --pane <id>` and confirm the dumped recording still replays.
   Exercise eviction by generating more than `eventLimit` events first (e.g. a
   long `yes | head -c` burst) so the wraparound path runs in the real app.
6. Note for the first build only: `build-app.sh` and `dev-build.sh` resolve into
   separate `.build` trees, so swift-collections is fetched more than once. CI has
   network at resolve time and no SwiftPM cache to update
   (`.github/workflows/ci.yml` caches only GhosttyKit), so no CI change is needed.

## Commit progress

- [x] **Characterization tests.** Add the four `cursorSnapshot`/wraparound tests
      to `TerminalFlightRecorderTests.swift`. Green against the existing
      linked-list implementation, no production code touched.
- [ ] **Swap the container.** Add the pinned dependency to
      `lib/TerminalPTY/Package.swift`, replace the list and dictionary with a
      `Deque` in `TerminalFlightRecorder.swift`, delete `Node`/`deinit`, and
      document I1, I2, and AR1.
