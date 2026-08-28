# Decisions

## D1 -- Fixture source for the kitten byte streams

DECIDED 2026-08-28: port the generator, do not record.

The generator is `references/kitty/tools/cmd/benchmark/main.go`. It was
outside the sparse cone, but the pinned commit's objects were already local,
so `just fetch-references kitty` now includes `references/kitty/tools/cmd/benchmark`
and `references/kitty/tools/tty` (the writer whose behavior `F3` cites).

What the generator does, per arm, before the `\x1b[m\x1b[H\x1b[2J` +
`Running: ...\r\n` reset that follows every repetition:

- `ascii`: 2,097,165 bytes drawn by uniform index from kitten's 88-entry
  `ascii_printable` + `control_chars` string, using an unseeded `math/rand/v2`.
  It is an indexed string and not a set: space appears twice in it, so space is
  twice as likely as any other character. An earlier reading of this decision
  said "94 printable ASCII characters", which is neither the count nor the
  distribution.
- `unicode`: a fixed Chinese lorem ipsum plus a fixed misc-Unicode block plus
  `\n\t`, repeated 1024 times. Deterministic.
- `unique_unicode`: 262,144 cells of `a` followed by three combining marks
  from U+0300..U+036F, indexed base-112 by the cell number. Deterministic.
- `csi`: chunks chosen by an unseeded random draw from seven fixed escape
  strings and a random ASCII run of 1-72 bytes, until 1,048,593 bytes.

Two of the four arms are random and unseeded, so a recording is bit-exact to
one run and nothing else; "bit-exact to what kitten sends" does not exist for
`ascii` or `csi`. A port with a fixed seed is regenerable, reproducible across
machines, and statistically the same stimulus. It also makes the alt-screen
wrapper (`\x1b[?1049h`, `\x1b[?25l`, the per-repetition reset, the
`\x1b[5n` x3 tail) part of the fixture rather than an artifact of one capture.

Rejected alternative: capture one run with `danterm pane tape` and commit the
bytes. It is available today with no code, but 200 MiB per arm is not a
fixture that belongs in the repository, and it freezes one random draw.

Ideal beside it: the same port, plus a periodic check that the local
`references/kitty/tools/cmd/benchmark/main.go` still matches the constants the port encodes.
`just test-tooling` can assert the string constants against the reference
file once the port exists; that is the Phase 2 headless task's job.

DONE: `scripts/kitten-benchmark-parity-lint.py` parses
`references/kitty/tools/cmd/benchmark/main.go` and
`references/kitty/tools/tui/loop/terminal-state.go` for every constant the port encodes, asks the built executable for its
own account of them, and pins both reference files by hash.

## D2 -- Freeze the four `kitten-feed-*` decision rules

DECIDED 2026-08-28: freeze all four arms at 2 pairs, the same cell in `quick`
and `confirm` -- `kitten-feed-ascii` +/-1.70%, `kitten-feed-unicode` +/-1.80%,
`kitten-feed-unique-unicode` +/-1.60%, `kitten-feed-csi` +/-1.45%. Each name
moves out of `CANDIDATE_WORKLOADS` into `WORKLOADS`, and each threshold into
both `DECISION_RULES` tables.

The evidence is `F5`, and it is the two-stage protocol the corpus requires, not
a screen: 12 quartets per arm at 50,000 trials on seed 20260730 selected the
cells, then those exact cells were re-run at 100,000 trials on seed base
20260828 -- disjoint seeds, no parameter changed after screening -- at tree
`83badba2973b`. Every arm was confirmed on its own series and never pooled, so
no arm rides on another's evidence. A/A false positives are 0.0000 in all eight
cells. Detection is the binding gate, at 0.915 against the 0.90 floor on the two
Unicode arms; that is what sets the thresholds, and it is why none of them can
be tightened by asking for it.

This is the step a script must not take, which is the whole reason Phase 2 task 2
sat open: `terminal-benchmark-candidate-screen.py` writes a report and never a
rule. The act here is a human reading `F5` and accepting it.

Runtime, checked rather than assumed. `research/7/D4` budgets the complete
`confirm` suite at under five minutes including cached build and harness
overhead, and nothing in the scripts enforces that number -- it lives in `D4`
and in
[agent-docs/terminal-performance.md](../../../agent-docs/terminal-performance.md).
`D4` froze it against an 86.72-second projection for the 20-pair suite; the
suite now carries 24 pairs plus these 8. `F5`'s screens took 2.6-5.3 minutes for
12 quartets of one arm, so 1 quartet of each of four arms is 52-106 seconds of
added collection. The suite stays under the budget, with less headroom than
before. Anything that adds another workload should re-check it against a
measured confirm run rather than this projection.

Rejected alternative: leave them as candidates and read Phase 3 descriptively.
That is what `F5` was collected to end. A fix measured on an arm that cannot
decide is an anecdote, and the funnel in this doc says a fix ships on a ladder
verdict.

Not decided here: whether the arms belong in the A/A control table in
[agent-docs/terminal-performance.md](../../../agent-docs/terminal-performance.md).
That table reports between-invocation noise from whole `confirm` runs, which
these arms have never been through. The doc says so instead of guessing.

## D3 -- Rotate the row deque for a whole-viewport scroll, and reuse the evicted row as the blank

DECIDED 2026-08-28: make the whole-viewport case a rotation of the row storage
for every whole-viewport scroll, not only the one that pushes to scrollback, and
recycle the row that leaves the viewport into the blank that enters it.
Implemented in `873431d0` and confirmed by `F6`; the plan is
[plans/impl/2026-08-28-1410-h1-alt-scroll-rotation.md](../../../plans/impl/2026-08-28-1410-h1-alt-scroll-rotation.md).

### What the code does today

`moveAndFillRows` (`lib/TerminalCore/Sources/TerminalCore/Terminal.swift:8557`)
already has a rotation branch, and it is gated on the wrong thing:

```swift
let rotatesWholeViewport = delta < 0 && pushesToScrollback && range == 0..<rowCount
```

`pushesToScrollback` is `retainsRowsScrolledOffTop`
(`Terminal.swift:8360`), which is false whenever the alternate screen is
active. So on the alt screen -- kitten's whole stimulus -- a line advance falls
into the `moveInPlace` shift at `Terminal.swift:8591-8599`, which per line
advance copies `rowCount - 1` `GridRow` values and calls
`makeBlankRow(columns:styleId:)` (`Terminal.swift:6337`) for the vacated row.
At the canonical 179x66 that is 65 row-value copies -- `GridRow` holds a
`cells: [GridCell]` array and a `spills: [[Unicode.Scalar]]` array, so each copy
is retain/release traffic plus the deque's uniqueness check -- and one fresh
179-element cell array allocated and one freed. `F1` attributes 80% of `ascii`
parse samples and 35% of `unicode` to `advanceToNextRow`, with leaf frames
`swift_retain`/`swift_release`, `swift_isUniquelyReferenced_nonNull_native`, and
`ContiguousArray._createNewBuffer` -> `swift_allocObject`, which is exactly this
line and this allocation.

The row storage is **already** `Deque<GridRow>` (`Terminal.swift:984`,
swift-collections), so no container change is needed: the primary-screen branch
at `Terminal.swift:8579-8584` rotates it today with `removeFirst(amount)` plus
`append`, and it allocates a fresh blank row per line because the rows it
evicted went to `appendToScrollback` (`Terminal.swift:8853`) and are not free to
reuse.

Two facts change how H1 should be read:

- The premise "the alt screen has no deque to rotate" was never true. What is
  missing is only the gate: the branch demands `pushesToScrollback`, which is a
  fact about *where the evicted row goes*, not about whether the move is a
  rotation.
- `range == 0..<rowCount` with `pushesToScrollback == false` is not
  alt-screen-only. A `DL`/`IL` issued with the cursor on row 0 and no scroll
  region produces exactly that range on the primary screen, and it must keep
  discarding rather than retaining. So the correct gate is the shape of the move
  (whole viewport), and where the evicted rows go stays a separate, unchanged
  decision.

### Ideal structure

The simplest structure in which per-line whole-screen row copying cannot happen:
**a whole-viewport scroll is a rotation of the row deque, in either direction,
whatever the disposal policy for the rows that leave.** The rows that leave the
viewport are disposed of exactly as they are today (admitted to history when the
scroll pushes to scrollback, discarded otherwise), and a discarded row is reset
in place and re-enters the deque as the blank -- so a whole-viewport scroll of
`n` lines costs `n` rotations plus `n` row resets and no row-value copies and no
row allocation at all.

This is structural rather than a fast path: with the rotation gated on the shape
of the move, there is no arrangement of alt screen, scroll region, or DL/IL that
can reach the `moveInPlace` shift with a whole-viewport range. The
`moveInPlace` shift survives only for a partial region, where it is the correct
primitive.

Reuse also removes the one remaining allocation on the *primary* whole-viewport
path, provided the row admitted to history is not still referenced by the store.
That is a property of `admit`, and the plan makes it a proof obligation rather
than an assumption: where the row is still referenced, the reset copies on write
and the path costs exactly what it costs today.

### Cheaper alternatives, beside it

- **Widen the existing gate only for the alt screen** (`|| isAlternateScreenActive`)
  and keep allocating the blank row. It removes the 65 row copies and leaves the
  per-line allocation, and it leaves a second condition that has to agree with
  `retainsRowsScrolledOffTop` forever. It is smaller and strictly weaker; no
  constraint of the ideal recommends it.
- **Make `GridRow` cheap to copy** (a reference-typed row box, so a move is one
  pointer). It would help the partial-region case too, but it changes the value
  semantics every snapshot consumer in the engine rests on, and it makes each
  row read an indirection. Rejected as the H1 fix; it is the shape the
  partial-region task would have to consider, and only if that task ever gets a
  measured trigger.

### Confirmation criterion

`H1` is confirmed when, on a re-sample of the `ascii` arm taken the way `F1` was
taken, `advanceToNextRow` is below 10% of `Terminal.feed` parse samples and the
`ascii` MB/s figure moves. The profile share alone is not the verdict: the
verdict is the ladder.

### Gates

- `just benchmark-quick workload=kitten-feed-ascii` decides it, at the frozen
  rule `D2` set: 2 pairs, +/-1.70%.
- It is measured on **all four** arms before it is called a win
  (`kitten-feed-unicode` +/-1.80%, `kitten-feed-unique-unicode` +/-1.60%,
  `kitten-feed-csi` +/-1.45%). A win on one arm that costs another is a
  trade-off to record.
- `scrollback-stream` must not regress: it is the primary-screen branch, which
  this change also touches. Read it against that workload's own caveat -- worst
  A/A estimate 3.48 points against a 1.85% threshold
  ([agent-docs/terminal-performance.md](../../../agent-docs/terminal-performance.md)),
  so a directional `slower` there needs `confirm` before it is believed, and an
  `equivalent` is the expected reading.
- `just test` plus the `TerminalCore` suite, because the whole claim is that no
  observable behavior changes.

### The partial-region case (Phase 3 task 2) stays a separate task

This structure does not address it. Rotating a sub-range of a deque is not O(1)
in element moves -- it is the same shift -- so the partial-region cost can only
be removed by making a row move cheap, which is the rejected alternative above
and a different decision with a different risk. It also has no gate here: none
of the four kitten arms sets a scroll region (`csi`'s seven bands are `SGR`,
`SM/RM`, `CUP`, `CUU`, `CNL`, `EL`, `HPA`, `REP` -- no `DECSTBM`;
`lib/TerminalCore/Sources/KittenFeedFixture/KittenFeedFixture.swift:144-152`),
so `kitten-feed-*` cannot decide it and it needs its own trigger and its own
workload before it is worth doing.

## D4 -- `H1` ships as committed, and the two `slower` cells stay open as the next task

DECIDED 2026-08-28: keep `873431d0`. `H1` is confirmed and Phase 3 task 1 is
closed. The `content-churn` and `retained-browse` `slower` verdicts are **not**
closed, and the next ledger task is the control run that would settle them --
before any further fix lands on the same cells.

The evidence is `F6`. On the arms `D3` set as the gate, the result is not
marginal: `kitten-feed-ascii` `faster` at -123.61% and `kitten-feed-unicode`
`faster` at -41.48% under `confirm`, `scrollback-stream` `faster` at -4.68%
where the gate only asked for no regression, the kitten `ascii` arm at 3.9x, and
a re-sample in which every leaf frame `F1` attributed the cost to -- the row-value
retain/release traffic, the uniqueness check, the blank-row allocation -- is
gone. Three independent readings, one mechanism. Reverting that over two cells
at +1.76% and +1.20% would trade a measured 4x for an unexplained 1%.

`unique_unicode` and `csi` are `inconclusive`, and `quick` called both `faster`
by margins inside half a point of their own thresholds. `F6` reads that as
threshold-edge noise on a 2-pair rule rather than a win, and this decision takes
the conservative half: `H1` moved the two arms that scroll per byte and left the
two that do not. Nothing here claims a gain on those two arms.

### What is open, and the cheap reading beside the ideal one

The cheap reading is that neither `slower` cell is reachable from the one
function the commit changed -- `content-churn`'s stimulus never scrolls
(`redraw_screen` homes the cursor and writes 66 rows with no trailing newline),
it decides on a draw metric whose plan time moved -0.22%, and
`retained-browse` plans over history that `admit` copies out of the row -- so
both are noise and the work is done. That reading is probably right, and it is
not evidence. `content-churn`'s rule made 0 of 8 false directional calls in the
control it was frozen against (`research/33/F28`), with a worst A/A estimate of
0.99 points against the +1.76% seen here, so "noise" is a claim about a rule
whose own control says it does not do that.

The ideal is the one measurement-discipline names: give the comparison a control
the change cannot reach, in the same session. Run `confirm` on the post-`H1`
tree against itself with only a marker differing, interleaved with a re-run of
the real pair, and read all four numbers together. If the control shows the same
+1.7% on `content-churn`, the cell moved for a reason that is not this commit,
and both verdicts are host state. If the control is flat and the real pair
repeats, there is a route from this change to the draw path that neither the
stimulus nor the metric predicts, and it needs a profile, not another run.

`retained-browse` needs one thing more: the physical arm slot comes from the
candidate tree's own hex parity and moves that cell by about 0.6 points against
a 1.05% threshold, while a re-run of the same tree pair reproduces to within
0.3. So re-running this pair measures the same slot and cannot separate the
confound; the control needs a candidate tree on the other parity.

Rejected alternative: run the control later, after `H3`. A second change to
`Terminal.swift` lands on the same two cells, and then no run can say which of
the two moved them. The control is cheap and it is only cheap now.

### Ledger

Phase 3 task 1 is DONE, cited to `F6` and this decision. One new task is added
ahead of the remaining fixes: the paired control run above. `H3` is next among
the fixes on `F6`'s re-ranked profile, and the per-line `resetAsBlank` fill that
`H1` left behind (17.9% of the `ascii` thread) enters the hypothesis list as
`H6`.
