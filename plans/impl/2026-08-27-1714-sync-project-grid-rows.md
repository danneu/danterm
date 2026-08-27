# Sync encoder: serialize the projected stream for grid rows

Source: `docs/scratch/2026-08-27-sync-encoder-blank-tail-seam.md`.

## 1. Problem

State synchronization drifts on a live-grid row that is blank, soft-wrapped,
and whose margin is a wide-wrap spacer (`\e[4G` + U+754C on a 4x2 grid, default
pen). The grid stores that margin as a plain padding cell and derives the
spacer on read through `DisplayRowProjector`. The encoder projects history rows
(`TerminalStateSynchronizationEncoder.swift:116-123`) but hands grid rows to
the writer raw (`:124`, and the two alternate-screen paths at `:156` and
`:286`). The writer sees four blanks, emits no cursor move for a padding run
that reaches the margin, and the next row's wide head prints at column 0 of
the wrong row. The replica ends with row 0 = U+754C, hard, and row 1 blank.

Evidence (scratch doc, section 1): the 4x1 history-seam case passes; the 4x2
live-grid case and the same under an active 1049 screen fail on `rowStructure`
and six cells. `reconstructsDerivedWideWrapGap` covers the shape but passes
only because its styled margin emits an `ECH` that leaves the cursor in place.

Premise: the projector is the single owner of the margin rule (its header
comment; commits 36542d8c, d51a2272). The bug is a second reader that bypasses
it.

## 2. Decision

The writer serializes projected cells for every row, but takes the row's
synchronization metadata (`wrap=`, `mark=`) from the original row. Projection
is a display contract: it gates a stale wrap claim (`isSoftWrapped` +
`.erase`) to a hard row, and the wire must still say `wrap=stale`. So the
writer's input is a pair per row -- projected cells for screen
reconstruction, the source row for row state -- for the history seam, the
primary grid, and the live and retained alternate grids alike. The wide-wrap
margin then reaches the writer as a `.spacerHead`, and the existing spacer-head
branch prints the deferred wide head. Alternate grids get a projector built
over a bare grid; the primary path keeps the existing projector.

Also in scope, while the branch is open:

- The per-row `wrap=` state addresses the row it describes, not the row the
  deferred wide head wrapped onto.
- Delete the dead encoder block in `Terminal.swift` (~1300-1491: the second
  `StateSynchronizationWriter` and the style/cursor/grapheme helpers only it
  uses). `charsetSynchronizationState` stays; the decoder uses it.

Rejected: emitting `CSI nC` from the padding branch when the row is
soft-wrapped (option B). It re-derives "this blank is a spacer" from provenance
inside the writer, leaving two owners of the margin rule. Rejected: absolute
cursor positioning per row (option C); history rows are replayed by printing
and scrolling, so no CUP can address them.

## 3. Invariants

- I1. Every cell the sync writer serializes comes from a projected row; a
  wide-wrap margin is never handed to the writer as padding. Every `wrap=` and
  `mark=` the writer emits comes from the original row, so a stale wrap claim
  survives the round-trip.
- I2. Replaying a synchronization onto a fresh terminal reproduces every cell
  and every row's structure (wrap claim, content end, margin kind) for the
  primary grid, the active alternate grid, and a retained inactive alternate
  grid, regardless of pen style.
- I3. A soft-wrapped row that reaches the writer must leave the replica cursor
  on its margin: either its cells print through the margin, or the margin is a
  spacer head. Any other shape is a programming error and traps.
- I4. The `wrap=`/`mark=` row state for row N lands on row N in the replica.
- I5. The projector needs no history store to project a grid; the alternate
  screens carry none.

## 4. Proof obligations

- PO1 (I1, I2): round-trip a blank wide-wrap row in the live primary grid
  (4x2, `\e[4G` U+754C, default pen). Red today at `rowStructure`.
- PO2 (I2): the same shape with the alternate screen active via 1049. Red
  today.
- PO3 (I2, I5): the same shape retained under an inactive alternate screen
  entered with 1047 (1049 clears on re-entry, so it cannot prove this). The
  comparison happens after both terminals re-enter the alternate screen with
  `DECSET 47`; the active-grid comparison alone cannot see the retained grid.
- PO4 (I2): keep `reconstructsDerivedWideWrapGap`; it pins restyle and
  hyperlink identity across the gap. Keep `reconstructsStaleWrapClaim`; it
  pins the metadata half of I1.
- PO5 (I2): a seeded randomized round-trip over narrow and wide glyphs,
  `CSI nG` jumps, and erases on a small grid, a few hundred iterations. Its
  seed is chosen so it fails on the observable-state mismatch before the fix.
- PO6 (I3): if a soft-wrapped projected row with a non-spacer margin and cells
  stopping short of the margin is reachable through the public API, assert it
  traps; if unreachable, the precondition stands as documentation.
- PO7 (I4): a round-trip where the blank wide-wrap row and its follower carry
  distinct semantic marks; each mark lands on its own row in the replica.
  Final wrap structure alone cannot see the ordering, because the follower's
  state repairs it.

All round-trips compare through the existing `expectObservableState` in
`TerminalStateSynchronizationTests.swift`.

## 5. Non-goals

- A wire spelling for `.wideWrap` provenance. The replica's own reprint of the
  wide head restores it; I2 covers the observable result.
- Changing the on-wire format beyond the row-state ordering.

## 6. Implementation discretion

- How the bare-grid projector is constructed (a second initializer versus a
  history-free factory), as long as I5 holds and the primary path keeps using
  the existing projector.

## 7. Verification

1. Land PO1-PO3, PO5, and PO7 first; PO1-PO3 and PO5 fail at
   `rowStructure`, PO7 at the semantic mark rows.
2. Implement; `swift test --package-path lib/TerminalCore --filter
   TerminalStateSynchronizationTests` green, PO4 still green.
3. `just lint`, then `just test` before commit.

## Commit progress

- [x] 1. fix(sync): serialize projected rows with source metadata
- [ ] 2. refactor(core): remove the dead synchronization encoder

## Implementation notes

- The retained alternate replay captures its saved cursor, keyboard stack, and semantic state
  before it paints rows. Those state replays can mutate the current row, so painting last lets
  each projected row establish its final cells, wrap provenance, and mark exactly once.
