# Decisions -- by-construction performance survey

One entry per stable ID. `D1` is a standing rule for the whole doc; `D2`-`D4`
record the three tensions the survey inherited from earlier docs rather than
resolved, so that the next agent argues them deliberately instead of
rediscovering them.

### D1 -- a complexity win counts as a win, on its own evidence

- Status: **settled**, and it governs how every task in this doc is judged.
- Evidence used: `agent-docs/perf-granularity-mismatch.md`, closing paragraph of
  "The fix pattern": *"Report the mismatch even where current cost is
  acceptable: the same mismatch is usually also a complexity smell, and the
  flatten/compute/re-coalesce code plus its dedup/memo/optional-array
  scaffolding disappears with the fix. That scaffolding is the structure
  apologizing."* Also `30/D1`, which shipped a folded `clip(to:)` explicitly as
  a simplification with no win the ladder could resolve, and is the precedent
  that this project already accepts such changes.
- Candidate solutions considered for how to rank tasks:
  - Rank by predicted percentage only. Rejected: it deletes most of this doc,
    because `F8` shows seven runtime items and `F4` shows the geometry item are
    unscoreable by any calibrated rule -- ranking by a number nobody can measure
    means ranking by guess.
  - Rank speed first, complexity as a tiebreak. Rejected: it reproduces the
    failure the granularity doc was written about, where a cache that hides a
    mismatch outranks the structural lift that deletes it.
  - Rank by what the change makes **impossible**, and record speed and
    complexity as two separate, independently sufficient justifications.
    Selected.
- Tradeoffs and correctness risks: the obvious failure mode is licensing
  churn -- "it is cleaner" is exactly the argument the Workflow-level design bar
  warns about when it is used to justify effort nobody asked for. The guard is
  that a complexity claim must still be *falsifiable and verified*, not
  asserted: it needs its one-off script like any other task, and the script
  measures the structure (call sites deleted, allocations reached zero, a state
  that can no longer be constructed), not the wall clock.
- Decision and rationale: a task in this doc may be justified by **either** a
  measured speed or memory improvement, **or** by deleting a class of possible
  wrong states or a body of compensating scaffolding -- and a task that does
  only the latter is not thereby second-tier. What a task may **not** do is
  claim a speed win it did not measure. Each task states which of the two it is
  claiming, and `Verification` proves that one.

  The practical consequence for this doc: `T20` (damage carries words end to
  end), `T11` (geometry off the frame path), `T17` (inline CSI storage), `T18`
  (exact fills) and the `PackedRetainedRow` retirement in `F3` are all
  legitimate on complexity grounds alone, and should be written up that way in
  the commit rather than padded with a percentage that the ladder cannot
  support.

### D2 -- damage carrying words: reopened as a complexity change, not as a speed claim

- Status: **recommendation only; no direction taken.** Gated on `T3`.
- Evidence used: `F2` (four independent verticals reached the same
  representation); `30/D2`, which rejected precisely this change and wrote *"do
  not reopen this for the sort"*; `27/F9`/`27/D2`, which rejected
  swift-collections `BitArray` for the accumulator's internals with a reopening
  gated on preserving reusable storage and the public determinism seam.
- Candidate solutions:
  - Leave it. The accumulator already holds words; only the public seam
    flattens. Cost is bounded by ~66 rows per frame.
  - Change the public seam type to carry the words, keeping the accumulator's
    internals and its reusable storage untouched.
  - Adopt a library bitset throughout. Rejected upstream by `27/D2`, and it ends
    `TerminalCore`'s import-free boundary.
- Tradeoffs and correctness risks: `TerminalDamage.rows` is public and read by
  tests and two benchmark harnesses; those rewrites are free under this repo's
  no-back-compat rule. The real gain is that a width-bounded bitset makes an
  out-of-range row **unrepresentable**, so `init(rows:)`'s `filter { $0 >= 0 }`
  sanitizer and the test that pins it both delete -- along with the `sorted()`
  and the three redundant set constructions. The real risk is re-litigating a
  decision another doc already made on its own terms.
- Recommendation: take it as a **complexity change under `D1`**, sequenced as a
  rider on `T9` or `T14` -- both change the damage representation for an
  independent reason, which is the exact reopening condition `30/D2` itself
  names ("reopen only if the damage representation is being changed for another
  reason and the ordered form falls out for free"). Do **not** pitch it as a
  speed win: `17/F5` measured `clipFramePlan` at 0.05% on `incremental-mixed`
  and 0.00% elsewhere, and `31/F18` rates that cell's reading rule at 4.9
  points, so no honest verdict is available. Standalone and unsequenced, it is a
  re-litigation of `30/D2`; ridden on `T9`/`T14` with `T3`'s diff-shape counts in
  hand, it is the condition that decision asked for.
- Behavioral verification: the row set a consumer sees must be identical before
  and after -- an equality test over the two representations across the four
  corpora, plus the existing damage tests.
- Decision and rationale: pending `T3`.

### D3 -- POD `GridCell`: the reopening clause is arguable, and must be argued in writing first

- Status: **no direction taken.** `T19` may not begin without this entry
  completed.
- Evidence used: `12/F7`, `12/F8` (implemented, +6.74% on `scrollback-stream`,
  reverted at `94a1528`); `16/D1`/`16/F3` (stride 24 reverted; 32 divides 64 and
  is a resting point); `28/D10` (a smaller retained cell rejected; `H8` named as
  the successor); `15/F12`, `15/F15` (measure the stride and the malloc bucket,
  do not reason about them); `9ad7cc5` (deleted `[GridRow]` scrollback).
- Candidate solutions:
  - Do nothing; treat `12/F8` as settled.
  - `28/H8` deferred packing: move *when* the encode runs, off the drain thread.
  - `T19`: make the live cell word identical to the retained word and give
    cluster scalars a `Terminal`-owned table, so the encode has nothing left to
    do and every `[GridCell]` operation becomes a `memcpy`.
- Tradeoffs and correctness risks: `12/F8`'s written reopening clause is *"either
  row-move traffic stops being hot on `scrollback-stream`, or cluster scalars
  find an owner that does not enlarge the row"*, and the survey argues both
  halves now hold -- doc 12's version put the store on `GridRow` (16 B and one
  refcounted field, to 32 B and two), whereas a terminal-owned table adds no
  refcounted field at all, and `9ad7cc5` confined `[GridRow]` move traffic to the
  live viewport. `12/F8`'s stated killer invariant -- that a cell's scalars
  resolve only against its owning row, so every relocation must re-intern --
  evaporates when the owner is the terminal, because cells relocate freely within
  a terminal and never across one. Against that: this is the third attempt at
  this area, spill reclamation needs a sweep, and a stride change is a history
  depth change that must be checked in malloc buckets at both 80 and 179 columns
  before anything is predicted.
- Recommendation: write the argument out here, with the clause quoted and each
  half answered, before writing code. If the argument cannot be made in writing
  without hedging, that is the answer.
- Decision and rationale: pending.

### D4 -- `lastPlannedTerminal`: split the retention from the check

- Status: **no direction taken.** Gated on the assertion described below.
- Evidence used: survey code-read of
  `TerminalPaneSession.swift#planIfNeeded` -- `guard pendingDamage != .none`
  at line 990, then `|| terminal != lastPlannedTerminal` at 992; `31/DD52`,
  which declined a store-identity/generation token for its silent-wrong-answer
  (torn frame) mode and left a 14.8x residual explicitly unspent; `31/D5` on
  publish-copy costs.
- Candidate solutions:
  - Leave both.
  - Delete only the retention (stop holding a second whole `Terminal`
    generation, which also holds a second reference to every arena chunk and so
    defeats copy-on-write uniqueness on the next in-place append), keeping the
    comparison against a cheaper witness.
  - Replace the check with a content generation counter. This is what `31/DD52`
    declined.
- Tradeoffs and correctness risks: the third option's risk is not performance
  but silence -- a mutation that changes presentation without bumping the
  generation stops repainting, which is the worst failure mode in that file. The
  second option's risk is much smaller and is mostly a question of what the
  cheaper witness is.
- Recommendation: before either, land a temporary assertion under the benchmark
  recording whether `terminal != lastPlannedTerminal` **ever** disagrees with
  `pendingDamage != .none`. If it never disagrees across the corpora, the check
  is provably redundant and its removal becomes evidence-backed rather than
  argued -- and that same evidence is what `31/DD52` lacked. If it does
  disagree, the cases it catches are the specification for what a generation
  counter would have to cover.
- Decision and rationale: pending the assertion.

### D5 -- the parser streams, but not one token at a time: `T7` waits for `T8`

- Status: **settled for now, on measurement.** `T7` is implemented, gated, and
  parked; the implementation is `scripts/research/33/t7-streaming-parser.patch`.
- Evidence used: `F15` (this task's own before/after run: token equivalence, a
  31 MB parse spike deleted, `slower` +5.43% on `scrollback-stream` under
  `benchmark-confirm` and +1.66% headless); `F9` (the array is real in an `-O`
  build and costs 60-80x the corpus's byte count in allocator traffic); `F10`
  (ASCII runs are 8.3 to 44.8 characters); `12/F8` and `16/F3`, the two prior
  engine changes this project implemented and reverted on a measured regression
  of +6.74% and a repeated `slower`.
- Candidate solutions considered:
  - **Land it.** Rejected: the memory it buys is not paid at production's
    delivery size. The spike it deletes is 31 MB under single-shot feeding, and
    the PTY host feeds at most 16 KiB per turn, where the array is 1.5 MB and 15
    allocations into reused buckets. The drain cost, by contrast, is paid on
    every turn. Two prior reverts set the precedent that a measured
    `scrollback-stream` regression is not traded for a structural improvement.
  - **Keep tuning the codegen.** Partly done and then stopped: extracting the
    per-action dispatch behind `@inline(never)` and passing the chunk as an
    `UnsafeBufferPointer` took the regression from +10.00% to +5.43%, and three
    further shapes (moving the parser state to a local for the loop, letting the
    optimizer choose, making the damage snapshot `mutating`) were all worse --
    the last by 18-22%. What remains is a per-token call boundary, and no
    attribute deletes that.
  - **A bounded stack batch** -- parse into a fixed-capacity inline buffer and
    drain it. Not attempted. It would keep both loops tight and allocate nothing,
    but it is the flatten-then-re-read structure `T7` exists to delete, with a
    capacity constant added; it should only be reached for if the `T8` pairing
    below also fails.
  - **Pair it with `T8`.** Selected. `T8` makes the parser's output granularity a
    run of printable ASCII rather than a character, and `F10` sized those runs at
    8.3 to 44.8 characters. The per-token cost `F15` measured is a call, an
    indirect 32-byte return and a defensive copy of `Terminal`, all of which
    amortize by that factor -- so the pair is the first shape in which deleting
    the array can be cheaper than keeping it.
- Tradeoffs and correctness risks: parking has a cost of its own -- a patch file
  rots against the tree, and `T8` is a larger change than `T7` with real
  correctness edges (wide-cell overwrite, the right margin in both `DECAWM`
  states, insert mode). The mitigation is that `t7-streaming-parser.py` builds
  its own arms from the patch, so the day it stops applying is the day the gate
  fails loudly rather than silently. The alternative risk, landing now, is a
  known 1.7-5.4% regression on the hottest path in the engine in exchange for
  memory nobody is short of.
- Decision and rationale: **`T7` does not land alone.** It is re-scoped as the
  second half of `T8`: build bulk ASCII runs, then re-run `T7`'s gate, and land
  the pair only if `scrollback-stream` reads at least `equivalent`. The ledger's
  ranking of `T7` and `T8` as two independently confident items is corrected --
  they are one change. Nothing here reopens `F9`'s numbers, which were about
  allocator traffic and remain correct; what `F15` corrects is the inference that
  traffic of that size is a *cost worth a call per token*.
- Behavioral verification, already satisfied and to be re-run with `T8`: token
  equivalence against `F9` at three chunkings, `peakLiveActions == 1`, the full
  1,020-test `TerminalCore` suite including the 67-fixture 7-byte-split replay,
  and chunk-invariant footprint within 2 MB.
