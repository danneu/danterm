# Rotate the row deque for a whole-viewport scroll

Research: [docs/research/39-kitten-render-benchmark](../../docs/research/39-kitten-render-benchmark/README.md)
(`F1`, `D3`).

## 1. Problem

A line advance on the alternate screen copies the whole screen. `moveAndFillRows`
takes its rotation branch only when the scroll also pushes rows to scrollback,
which the alternate screen never does, so every `\n` at the bottom row falls into
the general in-place shift: it copies `rowCount - 1` row values -- each one
retain/release traffic on two arrays plus a uniqueness check -- and allocates a
fresh blank row for the vacated line. At the canonical 179x66 that is 65 row
copies and one 179-cell allocation per printed line.

Evidence (`F1`): 80% of `ascii` parse samples and 35% of `unicode` sit under
`advanceToNextRow`, with leaf frames `swift_retain`/`swift_release`,
`swift_isUniquelyReferenced_nonNull_native`, and
`ContiguousArray._createNewBuffer` -> `swift_allocObject`. DanTerm feeds kitten's
`ascii` arm at 26.7 MB/s against Ghostty's 89.4.

Two load-bearing premises about existing behavior:

- The live row storage is already a `Deque` from swift-collections, and the
  primary-screen path already rotates it. Nothing about the container has to
  change; only the condition that selects the rotation.
- `pushesToScrollback` is a fact about where an evicted row goes, not about the
  shape of the move. A whole-viewport scroll that does not push to scrollback is
  reachable on the primary screen too (`DL`/`IL` with the cursor on row 0 and no
  scroll region), and those rows must keep being discarded.

Desired outcome: on uniquely owned storage -- which is what the feed path has --
a whole-viewport scroll costs one rotation per line and no row copies and no row
allocation, with no observable change to grid content, history retention, or
damage.

## 2. Decision

A whole-viewport scroll is a **rotation of the row storage**, selected by the
shape of the move -- the range covers the viewport -- in both directions and
whatever the disposal policy for the rows that leave. Disposal is unchanged and
stays a separate decision: rows leave to history exactly when they do today, and
are discarded otherwise.

A row that is discarded is **reset in place and re-enters the viewport as the
blank**, so no blank row is allocated when the storage is uniquely owned; a
retained value copy makes the reset copy-on-write instead, as I1 and I5 require.
A row that was handed to history is not recycled unless the store demonstrably
holds no reference to it.

The general in-place shift survives for a partial region, where it is the correct
primitive. With the rotation gated on the shape of the move, no combination of
alternate screen, scroll region, or `DL`/`IL` can reach the shift with a
whole-viewport range.

Rejected as the H1 fix: making a row cheap to copy (a reference-typed row). It
would cover the partial-region case as well, but it changes the value semantics
every snapshot consumer rests on and adds an indirection to every row read.

## 3. Invariants

- **I1** A whole-viewport scroll over uniquely owned row storage copies no row
  value and allocates no row, whichever screen is active and whichever direction
  it scrolls. When a retained value copy of the terminal shares the storage,
  copy-on-write is correct and expected: I5 wins, and the copy is the price of
  it. The production feed path is uniquely owned, so it pays neither.
- **I2** Which rows a scroll retains in history is decided exactly as today. A
  scroll that discards rows leaves history untouched.
- **I3** A row that re-enters the viewport as a blank is equal in value to a
  freshly made blank row at the current background-erase style: no surviving
  cells, no multi-scalar payloads, no wrap claim, no semantic-prompt mark, no
  margin provenance from its former life.
- **I4** The damage a scroll records is unchanged for every scroll shape,
  including the fallbacks a selection, search, or non-following viewport forces.
- **I5** A row still referenced by history or by a published snapshot is never
  mutated in place.
- **I6** Grid content, cursor position, and wrap-claim structure after any
  sequence of scrolls are unchanged from today, on both screens.

## 4. Proof obligations

Behavioral and structure-insensitive; a refactor that keeps the behavior keeps
these passing. All in the `TerminalCore` suite.

- **PO1 (I6)** Feeding a distinguishable pattern and then N line advances on the
  alternate screen leaves the same visible grid as before the change -- content,
  styles, cursor. Covers N greater than the row count, so every row has been
  recycled at least once.
- **PO2 (I6, I1)** The same for the other whole-viewport shapes: `SU`/`SD` with
  an amount above one and at or above the row count, reverse index at the top
  row, and whole-viewport `IL`/`DL`.
- **PO3 (I2)** On the primary screen, rows scrolled off the top still land in
  history with their content and line structure intact; a whole-viewport `DL`
  with the cursor on row 0 still retains nothing.
- **PO4 (I3)** A row carrying multi-scalar clusters, a wrap claim, a semantic
  mark, and a non-default background style, once scrolled out and back in as a
  blank, is equal to a freshly made blank row at the background-erase style in
  effect.
- **PO5 (I4)** The damage published for each whole-viewport scroll shape is the
  same value as before the change, on both screens and under the overlay,
  search, and non-following fallbacks.
- **PO5b (I3)** `memoryCensus` shows that a row carrying multi-scalar clusters,
  once scrolled out and back in as a blank, has returned its multi-scalar
  storage to the blank-row baseline -- the census counts for the recycled row
  match a freshly made blank one. Value equality cannot see this: `GridRow.==`
  compares visible cells and ignores dead entries in the private spill array, so
  an implementation could overwrite every cell, keep every old scalar array, and
  still pass PO4.
- **PO6 (I5)** A row admitted to history, and a snapshot taken before a scroll,
  are unaffected by later scrolling -- including when a retained value copy of
  the terminal shares the recycled row's buffers. This is the obligation that
  decides whether the primary-screen path may recycle at all: if the store keeps
  a reference, the path keeps allocating.
- **PO7** Partial-region scrolls are unchanged -- the existing region, `IL`/`DL`
  and overlapping-move coverage must stay green untouched.

## 5. Benchmark gate

Frozen rules from `research/39/D2`; conditions from
[agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md).
Note the pre-change revision before starting.

1. `just benchmark-quick baseline=<pre-change> workload=kitten-feed-ascii` --
   the initial decision. `faster` at 2 pairs, +/-1.70%.
2. The other three arms, measured before the change is called a win:
   `kitten-feed-unicode` (+/-1.80%), `kitten-feed-unique-unicode` (+/-1.60%),
   `kitten-feed-csi` (+/-1.45%). A win on one arm that costs another is a
   trade-off to record in the commit, not to hide.
3. `scrollback-stream` must not regress -- it is the primary-screen branch this
   change also touches. Its worst A/A estimate is 3.48 points against a 1.85%
   threshold, so a directional `slower` needs `confirm` before it is believed.
4. `just benchmark-confirm baseline=<pre-change>` before the performance claim
   is recorded anywhere durable, on the arms step 1 and step 3 decided. The
   change crosses two workload boundaries -- alternate-screen feed and
   primary-screen scrollback -- and `quick` alone cannot license either result.
5. Confirmation of `H1` itself, after the ladder verdict: re-sample the `ascii`
   arm the way `F1` was sampled. `H1` is confirmed when `advanceToNextRow` is
   below 10% of parse samples, the kitten `ascii` MB/s figure moves, and the
   profile shows no row-copy or blank-row-allocation frame under the kitten feed
   path -- that sample is what proves I1 on the production path, since a test
   cannot observe uniqueness.
6. Record the decision-bearing values -- mode, workload, both tree identities,
   the median symmetric estimate, the classification -- in the commit, and add
   the outcome to `docs/research/39-kitten-render-benchmark/findings.md` as a
   finding.

`just test` and `just lint` before the commit.

## 6. Non-goals

- The partial-region scroll (research 39 Phase 3 task 2). Rotating a sub-range is
  the same shift; removing that cost needs a cheap row move, which is a different
  decision. No kitten arm sets a scroll region, so none of them can decide it.
- The other three hypotheses (`H2`-`H4`). Each is its own change and its own gate.
- Changing which rows are retained in history, the scrollback budget, or the
  damage contract.

## 7. Accepted risks

- **AR1** The change touches the primary-screen scroll path, which
  `scrollback-stream` measures and which real sessions depend on for history.
  Bounded by PO3, PO6, and gate step 3.
- **AR2** Recycling gives a row a second life, so a stale payload that survives
  the reset would leak content from one part of the screen to another. Bounded by
  PO4, which asserts value equality with a fresh blank rather than sampling
  fields, and by PO5b for the payload storage equality cannot see.

## 8. Implementation discretion

- Whether the recycled row is reset by the row type or by the scroll site, and
  whether the reset keeps the cell buffer's capacity.
- Whether the primary-screen path recycles at all, decided by what PO6 shows
  about history's references.

## Implementation notes

- **The primary-screen path recycles too.** `LogicalLineStore.admit`
  (`LogicalLineStore.swift:728`) copies the cells it wants into its arena
  through `appendRowPrefix` (`:2780`), which reads the row through an unsafe
  buffer pointer and keeps no reference to the `GridRow` or its arrays. So a
  row handed to history is free the moment `appendToScrollback` returns, and
  `D3`'s proof obligation is discharged: both screens recycle, and `I1` holds on
  both.
- **The reset lives on the row type.** `GridRow.resetAsBlank(columns:styleId:)`
  assigns a whole fresh `GridRow` value over the recycled cell buffer instead of
  clearing field by field, so a stored property added later gets its declared
  default here exactly as it does in `makeBlankRow`. It keeps the cell buffer
  when the width already matches, and drops the row's own reference to it first
  so the write stays allocation free on uniquely owned storage.
- **The proof obligations are characterization tests, not red-then-green.** The
  change is behavior-preserving by construction, so every `PO` test was written
  first and verified green against the unchanged implementation, then verified
  green again after it. There is no state in which they can fail for the "right"
  reason first; `I1` is the only claim they cannot see, and gate step 5 is what
  proves it.
- **`PO5` needed no new test.** `recordScrollDamage` runs before the branch that
  chose the shift, with arguments the change does not touch, and
  `TerminalShiftDamageTests` already pins every whole-viewport shape and every
  fallback (selection on a pushing and a non-pushing scroll, a browsing
  viewport, the alternate screen, a top reverse index). Those tests staying
  green is the obligation.
- **The benchmark gate runs after this commit.** Gate step 6's `findings.md`
  entry is therefore not in it; see Follow Up.

## Follow Up

- Record the `H1` outcome in
  `docs/research/39-kitten-render-benchmark/findings.md` once the benchmark
  ladder in section 5 (steps 1-5, including the `benchmark-confirm` pass and the
  re-sampled `ascii` profile) has run.
