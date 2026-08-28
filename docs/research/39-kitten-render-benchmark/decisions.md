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

**Settled 2026-08-28 by `F7`.** The control ran as prescribed, interleaved with
a re-run of the real pair on `F6`'s slot and phase. The change-free control
called a direction on both disputed cells (`content-churn` `faster` -1.54%,
`retained-browse` `slower` +1.66%, each past its own threshold) while the real
pair read both `equivalent` (-0.31% and +0.12%) and reproduced `H1`'s wins. So
neither `slower` verdict is attributable to `873431d0`, no profile is needed,
and the ledger task closes. The `retained-browse` control ran on arm `b`, so its
+1.66% still mixes the arm-slot confound with invocation noise; that confound is
bounded, not priced.

## D5 -- Read projection and cluster context from their inputs, not through a getter on `inout self`; pin the feed path free of whole-`Terminal` copies

DECIDED 2026-08-28: remove both hot whole-`Terminal` copies on the feed path by computing the scroll projection from its five inputs through one function that the public getter and the damage snapshot both call, and by resolving the cluster predecessor on the screen sub-value; add a tooling gate that fails when a `MemoryLayout<Terminal>.size`-byte `memcpy` reappears in any feed-path function of the release object; and record, but do not build, the storage-box structure that would make the mechanism impossible. Plan: [plans/impl/2026-08-28-1714-h3-terminal-self-copy.md](../../../plans/impl/2026-08-28-1714-h3-terminal-self-copy.md).

### The mechanism, precisely

`F2` placed the copy: `apply` (`Terminal.swift:1879-1912`) ends every action with
`let after = damageActionSnapshot`, the snapshot (`:1531-1554`) opens with
`let projection = scrollProjection`, and `scrollProjection` (`:2785`) is a
`public` computed property the compiler declined to inline. Inside a `mutating`
method `self` is an `inout` access, and to call the opaque getter the compiler
materializes `self` into a stack temporary: `mov w2, #0x5e9; bl _memcpy` at
`apply+392`, 1513 bytes, once per parser action. `@inlinable` is not the knob --
caller and callee are in one module -- and the snapshot itself (about 120 bytes
of POD) is not the cost.

A probe on 2026-08-28 (not a finding; its numbers are recorded here) widened
that reading from one site to a family. The release `Terminal.swift.o` holds
**58** `#0x5e9 memcpy` sites, every one the same shape: a mutating method
calling a non-inlined non-mutating member of `Terminal` on `inout self`. On the
feed path, unconditional per action or per print:

- `apply+392` -> `scrollProjection`, once per action (`H3` as written).
- `feedBuffer` (`:1869`) -> the same getter, once per feed.
- `recoverClusterContextFromGridIfNeeded+60` (`:7870`) ->
  `gridClusterPredecessor()` (`:7897`), once per `printBulkNarrow` (`:7720`) and
  once per `print` (`:7832`). **Not covered by `H3`'s text**, same mechanism.

Guarded or cold on the feed path (selection or hovered-link change, width
change, a mode query, a reset): fifteen more. Off the feed path entirely
(`init`, `resize`, `setSelection`, search, the `Equatable` witness): the rest.

The probe's `sample` attribution of `_platform_memmove` on `F6`'s profile:
`ascii` 794 samples, of which `apply+396` 493 (62.1%) and
`recoverClusterContextFromGridIfNeeded+68` 242 (30.5%); `unicode` 1082, of
which `apply+396` 997 (92.1%). Nothing under `printBulkNarrow`, `printWide`, or
a row cell write. So 94% of the `memmove` line item on both arms is this
family, and of `ascii`'s 13.9% thread share `apply` holds about 8.6 points and
the cluster site about 4.2.

Two experiments confirmed the trigger, which `F2` had left at medium
confidence. `@inline(__always)` on `scrollProjection` alone removed the
`memcpy` and the getter relocation from `apply`. Computing `topRow` and
`isFollowing` from the inputs directly removed the copy from all three snapshot
sites with 1557 tests green. Measured at `just benchmark-quick baseline=HEAD`
under the `D2` rules: the direct computation alone read `kitten-feed-unicode`
`faster` at -18.11% and `kitten-feed-ascii` `faster` at -8.81%; with
`@inline(__always)` also on `gridClusterPredecessor`, `kitten-feed-ascii` read
`faster` at -17.11% (`unicode` not re-run for that variant). Two pairs each,
one invocation: a screen, not a verdict, which is why the plan's gate is the
full ladder.

### The ideal structure

The simplest structure in which a mutating `Terminal` method cannot pay a
whole-value copy to read its own state is **a `Terminal` that is one pointer
wide**: the stored state lives in a single class-backed storage box, `Terminal`
holds the reference and keeps value semantics by copy-on-write -- every
mutating entry checks uniqueness and clones the box when shared, the way
`Array` and `Deque` do. A defensive copy of `self` is then a pointer copy and a
retain, and no future read-only helper can reintroduce the cost, because there
is no 1513-byte value left to copy.

What is wrong with it, concretely, for this type:

- `Terminal: Sendable` is compiler-checked today, and the PTY host publishes
  fence-copied `Terminal` values across threads on that guarantee
  (`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift:281-290`,
  engine design `B4`). A mutable class box turns that into `@unchecked Sendable`
  plus a hand-kept invariant: every one of the 26 `public mutating func`
  entries (207 `mutating func` in the file) must establish uniqueness before
  touching storage, and one miss is shared mutation visible on the render
  thread. No compiler check replaces the one lost.
- The one-time clone that copy-on-write defers lands on the owner queue on the
  first action after every fence, which is the same thread the copy is being
  removed from; it is one 1513-byte copy plus about twenty retains per read
  turn instead of per action, a large net win, but not zero.
- It is a rewrite of every stored-property access in a 9,000-line file with no
  behavior change, to defeat a mechanism that is unconditional at two sites.

The trade is a structural guarantee against two sites and a guard. This
decision takes the guard. The box stays on the table: if the guard trips
repeatedly, or a third unconditional site appears, the box is the fix and this
section is its brief.

### The narrower structures, and what is chosen

- **Projection from its inputs.** `scrollProjection` reads five cheap things
  (`isAlternateScreenActive`, `rowCount`, `historyRowCount`, `viewportState`,
  `evictedRowCount`). One function that takes those inputs and returns the
  projection, called by the public getter and by the damage snapshot alike,
  makes the copy impossible at the snapshot sites without an annotation and
  without the duplicated arithmetic the probe's variant B carried -- there is
  one place the projection is derived. Chosen. A stored POD sub-struct owning
  the inputs was the probe's shape (b); `historyRowCount` lives in the history
  store and `isAlternateScreenActive` in the screen-ownership enum, so it would
  have to be passed in anyway, and the function is the sub-struct with nothing
  stored. Whether the function lives on `TerminalScrollProjection` or is a
  static on `Terminal` is the implementer's.
- **Cluster predecessor on the screen.** `gridClusterPredecessor` reads only
  `screen.cursor`, `screen.rows`, and `screen.isPendingWrap`, all members of
  `ScreenState`. Resolving it there, or inline, means the value it is called on
  is the screen, not the terminal. Chosen. The implementer decides between a
  `ScreenState` method and an inline read on `Terminal`; the gate below decides
  whether the choice worked.
- **The cheap fix beside them: `@inline(__always)` on both members.** One line
  each, measured -17%/-18%. It is a trade-off: it leaves the two calls on
  `inout self` and asks the optimizer to make them free, which is a statement
  about the compiler that
  [docs/design/2026-07-29-cross-module-value-dispatch.md](../../design/2026-07-29-cross-module-value-dispatch.md)
  says has no automated cover and gets tidied away. The chosen shapes need no
  annotation, and where the implementer finds one still needed, the gate is what
  makes it safe to carry.
- **The guard (c).** A tooling gate that builds the release `TerminalCore`
  object, reads `MemoryLayout<Terminal>.size` from the built product rather
  than hard-coding 1513, and fails when a `memcpy` of that length appears in
  any function on the feed path. It is a guard, not a structure: it cannot
  prevent site 59, only report it, and it fits in `just test-tooling`, beside
  the other build-product contracts, not in `just test` (it needs a release
  build). It is the automated cover the cross-module note said inlining could
  not have, and the reason it can exist here is that the assertion is about a
  copy of a named size in a named object, not about whether a call inlined.
  Chosen. The 55 cold and guarded sites stay outside its scope and outside
  `H3`; they are a fact about the type, recorded above, with the box as their
  answer if any of them ever profiles.

### Scope of `H3`

`H3` covers both unconditional sites. They are one mechanism, they share one
gate, and the probe put the cluster site at 30% of `ascii`'s `memmove` and
about 8 points of the arm; leaving it for a separate task would mean a second
change to `Terminal.swift` on the same four cells, which `D4` already refused
once. The README's `H3` text is corrected to say so.

### Confirmation criteria

`H3` is confirmed when all three hold:

1. The guard passes on the change: no `sizeof(Terminal)`-byte `memcpy` in
   `apply`, `feedBuffer`, `recoverClusterContextFromGridIfNeeded`, the print
   family, or `execute` in the release object.
2. That reading is taken by copy size in the object, not by an absence of
   frames in a profile. A `sample` stack carries no copy length, and small
   copies legitimately stay under both sites, so "no `_platform_memmove` sample
   under `apply` or `recoverClusterContextFromGridIfNeeded`" is neither
   necessary nor achievable; criterion 1 is what decides, and the sites that
   remain in the object are named as guarded or cold (`F8`). A share is no
   substitute either, because the fix shrinks the denominator it would be read
   against (`F6`).
3. The kitten `ascii` and `unicode` MB/s figures move, recorded with window
   state and geometry.

### Gates

- `just benchmark-quick baseline=<pre-change>` on each of the four arms at the
  `D2` rules: `kitten-feed-ascii` +/-1.70%, `kitten-feed-unicode` +/-1.80%,
  `kitten-feed-unique-unicode` +/-1.60%, `kitten-feed-csi` +/-1.45%. The cost is
  per action, so every arm should read `faster`; an arm that does not is
  recorded, not hidden.
- `just benchmark-confirm baseline=<pre-change>` before the performance claim
  is recorded anywhere durable. `terminal-feed` and `scrollback-stream` share the
  feed path and are expected to move; `content-churn` and `retained-browse` are
  read against `F7`'s control, which shows what a change-free run does to them.
- `just test`, the `TerminalCore` suite, and `just test-tooling` for the new
  gate.
