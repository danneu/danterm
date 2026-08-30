# One action per stretch of printable text: the join runs once per segment, and the per-action cost once per stretch

Research: [docs/research/39-kitten-render-benchmark](../../docs/research/39-kitten-render-benchmark/README.md)
(`F20`, `D10`).

## 1. Problem

A cell of `a` plus three combining marks reaches the grid as four actions:
one ASCII run of one byte and one single-scalar print per mark, because a
mark is not bulk-printable and ends the run probe. Each action pays the
dispatch, the damage snapshot and diff, and the action's construction and
destroy; each mark's join repeats the cluster validation, the row and cell
reads, the inspection invalidation and the context write-back that do not
change between the marks of one cluster. Evidence (`F20`, `unique_unicode` at
HEAD): about half of the PTY-host thread is the fixed cost of an action, the
join is 27% of which under 10 points are per-scalar by nature, and the
one-cell base stamp is 12%. Prototypes (`D10`) read
`kitten-feed-unique-unicode: faster (-26.71%)` for a joiner-run action alone,
`faster (-47.25%)` with the join hoisted per segment, and `faster (-78.75%)`
for one action per text stretch -- the last with `kitten-feed-unicode: slower
(+3.08%)` and `kitten-feed-ascii: slower (+1.74%)` beside it.

Load-bearing premises about existing behavior:

- A run fed as one action leaves the grid, cursor, wrap latch, damage,
  inspection state, cluster context and REP memory equal to feeding it one
  scalar at a time, and a joiner after a run joins only its last cell
  (`TerminalBulkRunTests`).
- Feeding is chunk-invariant, and a sequence split across chunks is completed
  from the pending prefix (`TerminalInputStreamTests`,
  `TerminalStateSynchronizationTests`).
- Every scalar is decoded once and classified once, in the stream, and the
  printer reads no bytes of a run (`D9`; `TerminalInputStreamDecodeEquivalenceTests`).
- A zero-width scalar joins the open cluster or is dropped; it never places a
  cell. The join refuses a scalar past the retained-byte limit without changing
  the cell, and a width change is allowed only in the cursor relationship
  uninterrupted printing creates (`TerminalGraphemeTests`,
  `TerminalGraphemeWidthTests`).
- REP repeats what the printer last placed, and the REP memory mirrors the open
  cluster the printer opened (`TerminalRepeatTests`, `F15`).
- The synchronization stream restores the decoder's pending prefix, the open
  cluster context and the REP memory (`TerminalStateSynchronizationTests`).

Desired outcome: the per-action work is paid once per stretch of printable
text and the join's invariant work once per segment of joiners; every
observable result is unchanged; `kitten-feed-unique-unicode` reads `faster`
and no arm reads `slower`.

## 2. Decision

**The action boundary is the text stretch.** In ground state with an idle
decoder, the stream yields one action for a maximal stretch of printable text
-- printable ASCII bytes and complete well-formed non-ASCII sequences of any
classification -- ending at a control byte, an escape, an ignored C1 scalar, a
sequence the one-step decoder cannot answer, or -- once the stretch has
admitted a non-ASCII scalar and so carries scratch -- the scratch cap. A
stretch that is still pure ASCII keeps today's uncapped byte-range form. The
stream still decodes and classifies each scalar once; the stretch carries its scalars
and their classifications so the printer classifies nothing. The printer walks
the stretch once and segments it by kind: GL bytes through the narrow writer
with character-set translation, bulk-printable scalars through the writer for
their width, consecutive zero-width joiners that cannot change the cluster's
width through one join that validates the open cluster once and steps the
break state per scalar, and every other scalar through the single-scalar
print. Each segment writer takes a prefix or declines, and a declined scalar
costs one single-scalar print before the walk re-enters.

This is `D10`'s ideal. `D10` records the cheap shape -- a joiner-run action
only, base cells and bulk runs unchanged -- as the fallback if the ideal
cannot clear the two `slower` cells the prototype read; the ladder decides,
and a fallback is recorded in the research doc as the outcome.

## 3. Invariants

The reference feed for every equivalence claim below is the same bytes fed one
byte per call. One byte keeps an ASCII action to a single GL byte and drives
every non-ASCII scalar through the resumable decoder's pending prefix and out
of the one-step path, so the reference runs the single-scalar print rather than
the stretch's segment writers. A scalar-at-a-time feed would not: a complete
scalar fed from ground state yields a one-scalar stretch, so both sides would
take the new writer and a segment-join defect could compare equal to itself.

- **I1** Token equivalence: expanding every stretch to one GL print per ASCII
  entry and one print per other scalar yields the same scalar-level token
  stream as today for any input and any chunking, including a stretch ending
  at each of the boundaries above and a stretch longer than the cap.
- **I2** Grid equivalence: feeding any byte sequence, in any chunking, leaves
  the grid, cursor, wrap latch, soft-wrap flags, margin provenance, content
  identities, cluster context, REP memory, drained damage and inspection state
  equal to the reference feed. The cases that must hold beyond today's run
  cases: a base followed by combining marks, a ZWJ emoji sequence,
  a variation selector that changes the width mid-cluster, a regional-indicator
  pair, a wide base with marks, a cluster split across a chunk boundary, marks
  past the retained-byte limit, ASCII inside a non-ASCII stretch under a
  non-ASCII GL character set and under a pending single shift, and joiners
  arriving with no open cluster, with a cluster recovered from the grid, and
  with one restored by the synchronization stream.
- **I3** Damage equivalence: the damage drained after a stretch equals the
  damage drained from the reference feed of the same bytes, including a stretch
  that wraps and one that scrolls.
- **I4** REP after a stretch repeats the cluster the stretch left open, marks
  included, with the width the cluster ended at.
- **I5** Synchronization round trip: a terminal restored mid-stretch and
  mid-cluster continues to the same grid, cluster context and REP memory as
  the terminal that fed it whole, and its encoder reads the same pending
  prefix.
- **I6** Arena census: a stretch that joins marks leaves the row's arena
  holding exactly the live clusters the stretch placed -- one record per live
  cluster, holding that cluster's scalars in order, and nothing else.
- **I7** Cost: the damage snapshot and diff, the dispatch and the action's
  destroy run once per stretch; the cluster validation, inspection
  invalidation and context write-back run once per joiner segment; nothing is
  allocated per scalar, per segment or per action beyond the bounded
  feed-scoped scratch; the arms the change does not target do not slow.

## 4. Proof obligations

Behavioral and structure-insensitive; a refactor that keeps the behavior
keeps these passing.

- **PO1 (I1)** The existing token-stream expectations, re-stated through the
  scalar-level expansion, stay green; a stretch's carried count and scalars
  match an independent decode of its bytes wherever a stretch appears.
- **PO2 (I2)** Whole-terminal equivalence between a fed stretch and the
  reference feed over the cases I2 names, plus the existing narrow, wide and
  mixed run cases.
- **PO3 (I3)** Drained damage compared between the two feeds for a wrapping
  and a scrolling stretch.
- **PO4 (I4)** REP after each cluster shape I2 names matches the cluster typed
  that many more times.
- **PO5 (I5)** A synchronization round trip taken mid-stretch and mid-cluster
  reproduces the pending prefix, the context and the memory, and completes
  the cluster identically.
- **PO6 (I6)** The arena census after a stretch of marked cells matches an
  expectation written out in the test -- which cells hold a cluster record and
  the scalars each record holds -- not only the reference feed's census.
- **PO7 (I7)** No shipped surface counts snapshots, dispatches or allocations,
  so I7 is carried by structure -- the printer's segment walk is the only place
  a stretch is spent, and the scratch is the only buffer a segment writer may
  hold -- and by the benchmark ladder, which is what a lost amortization or a
  per-segment temporary would move. Frame presence is corroboration, not a count
  (`D10`, `F19` AR4).

## 5. Benchmark gate

Frozen rules from `research/39/D2`; conditions from
[agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md).
Note the pre-change revision before starting.

1. `just benchmark-quick baseline=<pre-change> workload=kitten-feed-<arm>` on
   all four arms after each commit: `unique-unicode` (+/-1.60%) must read
   `faster`; no arm may read `slower`. `ascii` (+/-1.70%) and `unicode`
   (+/-1.80%) are not read against a control here: the prototype showed the
   change can reach them, so a `slower` on either is a cost to remove before
   the commit lands, and a commit that cannot remove it falls back to the
   cheap shape with the reading recorded.
2. `just benchmark-confirm baseline=<pre-change>` before any performance
   claim is recorded anywhere durable; `content-churn` and `retained-browse`
   read against `F7`'s change-free control per `D4`, `retained-browse` named
   because the segment join writes the arena in a new pattern.
3. Corroboration, after the ladder verdict, read by which frames are present
   against a pre-change sample of the headless `unique-unicode` feed: no
   per-scalar print or join frame under the stretch for a joiner the segment
   join accepts, and the damage snapshot and diff at stretch frequency;
   subtree sample counts recorded on both trees. The external confirmation is
   the kitten `unique_unicode` figure moving, taken frontmost at 179x66 with
   the other three arms beside it and read against `F16`'s delivery term.
4. Final acceptance: the whole change against the pre-change revision, on
   both modes. `kitten-feed-unique-unicode` `faster`, no arm `slower`. A miss
   is recorded as the outcome.
5. Record the decision-bearing values -- mode, workload, both tree
   identities, the median symmetric estimate, the classification -- in each
   commit, and add the outcome to
   `docs/research/39-kitten-render-benchmark/findings.md` as a finding.

`just test`, `just lint`, and the `TerminalCore` suite before each commit.

## 6. Non-goals

- The one-cell base stamp's own set-up cost and the arena's per-scalar count,
  threshold and compaction work: `D10` leaves both without a hypothesis until
  a profile after this change.
- `H6`'s blank fill (demoted behind this task by `D10`).
- Segmentation in the stream: the break decision stays with the printer,
  which owns the grid state it depends on.
- Any change to what a joiner may do to a cell: the byte limit, the width
  rules and the drop of an unjoined zero-width scalar are unchanged.

## 7. Accepted risks

- **AR1** The token stream changes shape and the parser suites that state it
  re-state it. Accepted because the scalar-level expansion is the contract
  those suites pin (I1), and the grid suites passed unchanged on the
  prototype.
- **AR2** A stretch that mixes ASCII with non-ASCII carries ASCII through the
  scratch, where a pure ASCII run carries none. Accepted because a pure ASCII
  stretch keeps its byte-range form, so the arms with no non-ASCII pay nothing
  new; the gate reads `ascii` directly.
- **AR3** A stretch carrying non-ASCII is bounded by the scratch cap and a
  longer one becomes several actions over the same cells. Accepted as in `D9` (AR3): the
  split changes cost, not results, and I1 and I2 pin the over-cap case.
- **AR4** I7 is not provable by the instruments this repo has. Accepted
  because it is carried by structure and by the ladder (PO7).

## 8. Rejected ideas

- A cluster action (base plus joiners as one token): the base is usually the
  last cell of a bulk run, so the stream would cut a run one scalar early to
  attach the joiners, which is the cost the run exists to remove.
- Segmentation in the stream: the break decision depends on grid state the
  stream cannot see.
- A cheaper per-action path alone: it lowers a tax paid four times per cell
  instead of paying it once.

## 9. Implementation discretion

- How the stretch carries classifications beside scalars, and how the printer
  finds each segment's extent, provided nothing is allocated per action and
  the bulk arms pay no per-scalar re-read the prototype's `unicode` reading
  attributes to it.
- Whether the width-cut run action survives as a token or folds into the
  stretch, provided I1 holds.

## Commit progress

- [x] 1. The action boundary is the text stretch, walked by segment kind
- [ ] 2. One join per segment of zero-width joiners

## Implementation notes

- The work splits in two because the stretch action and the segment join are
  separately gateable: entry 1 makes the stretch the action boundary and pays
  the per-action cost once per stretch, with joiners still costing one
  single-scalar print each; entry 2 hoists the join's invariant work to once
  per joiner segment (I6, PO6). If entry 1's ladder regresses, the two halves
  are told apart by which commit moved it.
- Entry 1's shape: the stream yields
  `printTextStretch` over a `TerminalStretchScratch` (a scalar span beside a
  segment-kind span), `printScalarRun` is gone, and `Terminal.printTextStretch`
  walks the scratch once into GL, bulk-narrow, bulk-wide and single-scalar
  segments. `just lint` passes and the `TerminalCore` suite passes at 1594
  tests.
- The first ladder reading of entry 1 reproduced the prototype exactly:
  `unique-unicode faster (-47.43%)`, `csi equivalent (-0.86%)`, and the two
  `slower` cells `D10` warned about -- `ascii (+1.91%)` and `unicode (+3.04%)`.
  Section 5.1 makes both a cost to remove before the commit lands, and section 9
  grants the discretion to remove them, so two changes followed:
  - The stream's stretch probe now scans the printable-ASCII prefix in its own
    tight loop before the mixed loop begins, so an ASCII byte is not tested
    against the scratch state per byte. Measured: `ascii` moved from
    `slower (+1.91%)` to `faster (-2.27%)`.
  - The scratch became two spans -- scalars and segment kinds -- instead of one
    span of `{scalar, classification, kind}` elements. One span of elements cost
    every bulk scalar a 12-byte store and a strided load where the old scalar
    run stored 4 bytes, which is what the `unicode` arm was reading; apart, the
    scalar span keeps the shape the bulk writers have always loaded and a bulk
    scalar costs one extra byte. The trade-off this takes: the stretch no longer
    carries the classification record, so a `.single` scalar and a declined bulk
    scalar read the table once inside `print` (which already looks one up when
    none is handed to it). That is one lookup per mark, not per bulk scalar, so
    section 9's proviso -- "the bulk arms pay no per-scalar re-read" -- holds,
    while section 2's stricter "the printer classifies nothing" does not. If the
    stricter reading is the one that matters, the alternative is a third span
    holding records for the non-bulk scalars only.
  Two spans then read `slower (+2.71%)` on `csi`, an arm the change does not
  target, against its frozen `+/-1.45%`. The cause was the second allocation,
  not the second span: `feedBuffer` took one temporary allocation per span, and
  a feed pays for the scratch whether or not it holds any text, so `csi` carried
  a cost only the text arms earn back. `TerminalStretchScratch.withScratch` now
  carves both spans out of one temporary allocation, which is the only way a
  scratch is made. Measured: `csi` moved from `slower (+2.71%)` back to
  `equivalent (+0.67%)`.
- The ladder that decides entry 1, all four arms against `b88c71a9` in `quick`
  mode, candidate tree `239fa0447c` (`quick/239fa0447c7b-0000..0003`):
  `unique-unicode faster (-52.38%)` against `+/-1.60%`,
  `unicode faster (-4.83%)` against `+/-1.80%`,
  `ascii equivalent (+0.06%)` against `+/-1.70%`, and
  `csi equivalent (+0.67%)` against `+/-1.45%`. Section 5.1 is met: the target
  arm reads `faster` and no arm reads `slower`, so the ideal shape stands and
  `D10`'s cheap fallback is not taken.
- Section 5's per-commit record goes in each commit message; the
  `findings.md` entry is written once, on the final commit, from the final
  acceptance reading (5.4).
