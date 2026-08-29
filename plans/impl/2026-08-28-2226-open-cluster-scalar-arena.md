# Grow the open grapheme cluster in a per-row scalar arena instead of allocating per scalar

Research: [docs/research/39-kitten-render-benchmark](../../docs/research/39-kitten-render-benchmark/README.md)
(`F1`, `F10`, `D6`).

## 1. Problem

Every combining scalar that joins the open cluster allocates. A row keeps its
multi-scalar payloads as a table of separate arrays; the first mark on a cell
copies the base scalar into a fresh array, grows it, and re-copies it to intern
it (three allocations, two frees), and every later mark copies the payload
again because the REP memory holds a reference to the same buffer, so the
in-place append is never uniquely owned (one allocation and one free each).
The table is rebuilt three times per 179-column row on top of that.

Evidence (`F10`): `appendToOpenClusterIfJoined` is 50.4% of the PTY-host thread
on `unique_unicode`, with `malloc` 12.9%, free and dealloc 11.2%,
retain/release 15.0%, `_consumeAndCreateNew` 12.9%, `Array.init<A>` 8.9%,
`GridRow.place` 11.0% and `GridRow.intern` 4.7% under it; the same function is
10.4% of `unicode`. DanTerm feeds `unique_unicode` at 12.6 MB/s against
Ghostty's 45.6.

Load-bearing premises about existing behavior:

- A cell's scalars are read only through the row's payload accessor and the
  `TerminalScalars` collection surface, in the engine, the store, the encoder,
  search, and the renderer; no reader indexes the spill table directly.
- The open cluster is usually, but not always, the last payload its row
  created. `GridRow.appendScalar` (`Terminal.swift:382`) has a non-last
  fallback that re-forms the payload through `place`, because
  `recoverClusterContextFromGridIfNeeded` can re-open an earlier cell's cluster
  after a later cell in the same row has already spilled.
- Live spill bytes stay bounded under unbounded rewrites of one cell (the
  existing 2,097,153-rewrite test), and the census counts one multi-scalar
  allocation per live row.
- `GridRow` and `Terminal` are compiler-checked `Sendable` values, shared
  copy-on-write across the PTY host's fence copy.

Desired outcome: joining a scalar to the open cluster allocates nothing once
the row's arena has capacity; every cluster reads back exactly as before; the
`unique_unicode` and `unicode` arms read `faster`.

## 2. Decision

Each row owns **one contiguous scalar arena and a span table**; a spilled cell
indexes a span, which is an offset and a count into the arena. The open
cluster is the last span, so a join is one store at the arena tail and a count
increment. Opening a cluster appends its base and first mark as a new span.
Readers get a `TerminalScalars` that shares the arena buffer over the span's
range -- a retain, never a copy.

The target is not always the tail span: cursor movement can re-open an earlier
cell's cluster through `recoverClusterContextFromGridIfNeeded` while a later
cell in the same row already holds one. A join to a non-tail target copies that
cell's scalars plus the new scalar to the arena tail as a new span and repoints
the cell, leaving its old span dead. Dead spans, from this and from overwrites,
are reclaimed by the same amortized compaction rule the table has today.

The REP memory **stops aliasing the live payload**, so the printer's append is
uniquely owned in steady state. Sharing is still legitimate and expected: a
retained `TerminalScalars` result and the PTY host's fence copy of the terminal
both hold the arena, and the next append copies the row's storage once, as
value semantics require. Whether REP resolves its cluster from the grid when it
runs or copies it when the cluster closes is the implementer's.

This is the ideal `D6` names, and it is built as decided; `D6` records the cheap
fix (unalias and pre-size, one allocation per cluster left) and the two rejected
shapes (a per-screen arena, a parser-side buffer placed on close).

## 3. Invariants

- **I1** Appending a scalar to the open cluster performs no heap allocation
  once the row's arena has capacity for it and the row's storage is uniquely
  owned. A retain taken by a terminal copy, a frame, or a returned
  `TerminalScalars` costs at most one copy-on-write detachment on the next
  append; appends after that detachment allocate nothing again while ownership
  stays unique. Filling a row with unique four-scalar clusters costs a bounded
  number of allocations per row, not per cell or per scalar.
- **I2** Every cluster reads back identically through every reader: the
  engine's cell and row accessors, the state-synchronization encoder, search,
  and the geometry the renderer consumes. This holds for combining sequences,
  ZWJ sequences, regional-indicator flags, wide bases with marks, a cluster at
  the 256-byte limit, a cluster whose width upgrades or downgrades mid-way, and
  a cluster re-opened by cursor movement while a later cell in the same row
  holds its own cluster.
- **I3** A cluster survives every row movement unchanged: scroll and viewport
  rotation, insert and delete, resize with and without reflow, alternate-screen
  entry and exit, and admission to scrollback and read-back from it.
- **I4** Live spill bytes per row stay bounded under unbounded rewrites of one
  cell -- including the dead spans that re-forming a non-tail cluster leaves
  behind -- and the census reports at most one multi-scalar allocation per live
  row. A row that has never held a cluster reports none; a row recycled as a
  blank may still report its retained arena allocation, because the census
  measures allocated capacity and `resetAsBlank` keeps it on purpose (AR2).
  Live multi-scalar *cells* are zero for both.
- **I5** `GridRow` and `Terminal` keep compiler-checked `Sendable` and
  whole-value `==`; a terminal copied before a feed is unaffected by the feed,
  and a `TerminalScalars` value already returned to a reader keeps reading the
  scalars it was returned for -- both when the feed extends a cluster whose
  arena the copy or the value shares.
- **I6** REP repeats the last printed cluster exactly as before, including a
  cluster completed by marks after its base and a cluster REP is asked to
  repeat after the grid it came from was overwritten.

## 4. Proof obligations

Behavioral and structure-insensitive; a refactor that keeps the behavior keeps
these passing.

- **PO1 (I1)** After printing a full row of unique four-scalar clusters, the
  census's cell storage grows by no more than the scalars' bytes plus a fixed
  per-row slack, and the multi-scalar allocation count is one for that row.
  A second identical row costs the same. Read against the existing bound
  test's style; the number is a contract about memory, not about a helper.
- **PO2 (I2)** For each cluster class named in I2, the cell read through the
  public cell accessor, the row read through the scrollback and viewport
  accessors, the encoder's output, and a search hit all agree with the input
  scalars. This includes the recovered non-tail case: print multi-scalar
  clusters at columns 0 and 2, move the cursor back to just after column 0,
  print another joining mark, and read both cells -- column 0 gains the mark
  and column 2 is untouched. Repeating that recovery many times leaves the
  row's live spill bytes bounded (I4). Existing grapheme, width-upgrade, and
  encoder tests stay green untouched.
- **PO3 (I3)** A row holding several clusters, one at column 0 and one at the
  margin, round-trips through each movement named in I3 with every cluster
  intact and no cluster moved to a different cell. Existing scroll, reflow,
  and alternate-screen tests stay green untouched.
- **PO4 (I4)** The existing rewrite-bound and allocation-count tests stay
  green untouched; a row that never held a cluster reports zero multi-scalar
  allocations after being scrolled through and recycled as a blank. A row that
  did hold a cluster reports zero live multi-scalar cells after the same
  recycling, and printing a cluster into that recycled row adds no further
  multi-scalar allocation.
- **PO5 (I5)** With a cluster's base and first mark already printed -- so the
  arena exists and is shared -- copy the terminal and separately retain the
  `TerminalScalars` the cell accessor returns, then feed another mark to the
  original. The copy reads the two-scalar cluster, the retained value still
  reads its two scalars, and the original reads all three. `GridRow` compiles
  as `Sendable` with no `@unchecked`.
- **PO6 (I6)** REP after a multi-scalar cluster repeats the whole cluster.
  It still repeats the cluster that was printed after the source cell was
  overwritten, after enough rewrites of that row to force a compaction, and
  after the source row scrolled away and its slot was recycled as a blank.
  Existing REP tests stay green untouched.

## 5. Benchmark gate

Frozen rules from `research/39/D2`; conditions from
[agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md).
Note the pre-change revision before starting.

1. `just benchmark-quick baseline=<pre-change> workload=kitten-feed-<arm>` on
   `unique-unicode` (+/-1.60%) and `unicode` (+/-1.80%), which must read
   `faster`; and on `ascii` (+/-1.70%) and `csi` (+/-1.45%), which must not
   read `slower`. An arm that misses is recorded, not hidden.
2. `just benchmark-confirm baseline=<pre-change>` before the performance claim
   is recorded anywhere durable. `content-churn` is the glyph-path check: its
   draw metric reads every cell's scalars through the changed `TerminalScalars`
   surface. Read it and `retained-browse` against `F7`'s change-free control,
   not in isolation.
3. Confirmation of `H2` itself, after the ladder verdict, read by **which
   frames are present** under `appendToOpenClusterIfJoined` on a re-sample of
   `unique_unicode` taken the way `F10` was: no `malloc`, `free`,
   `_swift_release_dealloc`, `_ArrayBuffer._consumeAndCreateNew`,
   `Array.init<A>`, `GridRow.intern` or `compactSpills` in its subtree. A share
   is not the criterion, because the fix shrinks the denominator. The external
   confirmation is the kitten `unique_unicode` MB/s figure moving, recorded
   with window state and geometry, with `unicode` beside it.
4. Record the decision-bearing values -- mode, workload, both tree identities,
   the median symmetric estimate, the classification -- in the commit, and add
   the outcome to `docs/research/39-kitten-render-benchmark/findings.md` as a
   finding.

`just test`, `just lint`, and the `TerminalCore` suite before the commit.

## 6. Non-goals

- The scrollback store's own spill side table, which copies one array per
  spilled cell at admission. It is not on the kitten path and has its own
  workload; `D6` names it as a separate question.
- The guard chain in `appendToOpenClusterIfJoined` that decides a scalar does
  not join, which is the remainder of `unicode`'s 10.4% once the allocator
  share is gone.
- `H4`, `H6`, `H7`, and the unattributed `unicode` costs (`printWide`,
  decoding, classification).

## 7. Accepted risks

- **AR1** `TerminalScalars` is consumed per cell across the `TerminalCore`
  target boundary, and a new storage arm on its inlinable accessors can cost
  the render path what
  [docs/design/2026-07-29-cross-module-value-dispatch.md](../../docs/design/2026-07-29-cross-module-value-dispatch.md)
  measured before. Accepted because the gate reads `content-churn` for exactly
  that, and the doc's rule (spell out the index arithmetic, keep the arms
  inlinable) is followed for the new arm.
- **AR2** The arena grows amortized, so the first cluster in a genuinely fresh
  row still allocates. Accepted because `resetAsBlank` is changed to keep the
  arena's capacity while clearing every live span, so on the alternate screen
  the allocation happens once per recycled row slot and not once per line
  printed. Today's `resetAsBlank` drops the spill storage, so this is new
  behavior, not an existing `H1` property; its contract -- a recycled row
  equals a freshly made row through `==` and through every reader -- is
  unchanged, and only the census's capacity measure sees the difference
  (I4, PO4).

## 8. Rejected ideas

- The cheap fix alone (unalias the REP memory, pre-size the first payload). It
  leaves one allocation per multi-scalar cell and the table rebuilds; `D6`
  prices it and keeps its unalias half inside the chosen structure.
- A per-screen arena, and buffering the open cluster in the parser until it
  closes. Both are priced and rejected in `D6`.

## 9. Implementation discretion

- The span table's shape, the compaction threshold, and whether the span
  range lives in `TerminalScalars` as a slice of the arena or as a buffer plus
  range, provided no reader copies.
- How REP keeps its cluster memory without aliasing the live payload.

## Commit progress
- [x] 1. Keep REP's cluster memory in its own buffer instead of aliasing the row payload
- [ ] 2. Grow the open cluster in a per-row scalar arena instead of a per-cell array table

## Implementation notes

- Commit 1 is a pure restructuring: REP repeated the same clusters before and
  after it, so it has no test that fails first. Its new test is the `PO6` guard,
  written to pin REP's behavior before the payload storage moves under it.
- `LastPrintedCluster` holds `[Unicode.Scalar]` and is emptied rather than set
  to nil. A fresh `TerminalScalars` per remembered cluster would allocate once
  per multi-scalar cluster -- the printer refreshes this memory after every
  scalar it prints -- and a buffer kept across clusters allocates nothing in
  steady state. An empty `scalars` is the absence of a memory.
- `rememberOpenCluster` now copies the cluster instead of retaining it, so
  remembering a cluster of `n` scalars costs `O(n)` per printed scalar rather
  than one retain. Bounded: a cluster is at most 256 UTF-8 bytes, and the copy
  replaces one allocation and one free per scalar.
