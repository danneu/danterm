# Selection gesture cost and point-local projection

Research started: 2026-07-30.

## Purpose

Owns one question: **does a local selection gesture cost enough to justify
making it point-local, and can the change hold behavioral equivalence while it
does?** A plan for the change already exists in reviewed, converged form (it is
reproduced below as the candidate direction), but every claim in it about cost
was derived from reading the call graph. This file exists to price the gesture
before the change is implemented, and to hold the decision either way. As of
2026-07-31 the pricing is complete -- probe (`F2`) and app-level check (`F3`)
both in -- and `D1` records **take**. What remains is Phases 3-5: pin the
behavior, implement, re-measure.

It owns an axis no earlier performance file does: **the cost of a pointer-driven
query**. Docs 9-18 all measure the output path -- parse, plan, draw, and the
memory under them. No workload in the paired benchmark harness generates a
pointer event, so no instrument this project owns has ever looked at what a
mouse drag costs.

The decision boundary it must preserve: the change is worth taking only if the
measured gesture cost is large enough to justify reproducing three whole-stream
dependencies inside a bounded projection (`F1`), each of which silently changes
observable selection behavior if it is recomputed locally instead.

## Investigation rules

- **The paired harness cannot decide this.** Its five workloads are
  `terminal-feed`, `scrollback-stream`, and the three draw workloads; none
  invokes a selection query, so `benchmark-quick` would report `equivalent`
  regardless of the change's size. That is the documented failure mode ("a
  workload that does not contain the cost you are trying to move will answer
  `equivalent` no matter how good the change is",
  [agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md)).
  Do not spend a paired run on this; do not add a calibrated workload for it
  (see Rejected).
- **Probe numbers are diagnostic, never benchmark results.** They carry no
  verdict, no threshold, and no `faster`/`slower` label. Report them as
  measured medians with the machine state that produced them.
- **The deciding quantity is the deep/shallow ratio, not the absolute
  nanosecond.** The change's entire claim is that gesture cost stops scaling
  with unrelated scrollback, so the ratio is what it targets, and unlike an
  absolute figure the ratio survives thermal and governor drift (`8/D2`).
  Record the absolute anyway: the ratio decides whether the mechanism is real,
  the absolute decides whether anyone would notice.
- **Granularity redefinition lands first.** *Satisfied as of 2026-07-31.*
  [plans/impl/2026-07-30-1646-ghostty-selection-granularity.md](../../plans/impl/2026-07-30-1646-ghostty-selection-granularity.md)
  replaced character-class word and whitespace-run cluster with one
  boundary-set cluster at double-click, moved line to triple-click, and cycles
  higher counts;
  [plans/impl/2026-07-31-1812-utf8-terminal-token-selection.md](../../plans/impl/2026-07-31-1812-utf8-terminal-token-selection.md)
  then settled that double-click unit as DanTerm's terminal-token contract.
  This file's "expansion" arm means that surviving granularity, which is
  `SelectionGranularity.terminalToken` in code. The mapping Phase 1 must
  measure is the three-way one at
  `TerminalInteractionPolicy.swift#pointerDownDecision`: character,
  terminalToken, line.
- **Release builds only.** A debug measurement of an allocation-bound loop is
  not evidence of anything.
- **The gate is pre-registered.** `D1`'s thresholds are written before Phase 1
  runs and are read as written afterward.
- **Implementation may begin only after `D1` records "take".** And when it
  does, the behavioral tests for `F1`'s three named risks are written first and
  verified to fail against a naive slice -- doc 17's lesson (`17/F13`): a green
  measurement is not evidence of correctness, and the naive implementation of a
  pitch is exactly where the correctness bug lives.

## Trigger and current evidence

Reading the selection path at `705244c` while reviewing the
point-local-selection-projection plan draft (never promoted; this file replaced
it and it was deleted from `plans/wip/`). Every local selection query --
character, expansion (double-click), line -- and every application of a
resulting range rebuilds a materialized copy of the entire retained stream, and
the expansion path additionally allocates one array per projected cell of
scrollback. This runs per pointer event during a drag.

That is a source-level observation, recorded in full as `F1`. It has since been
timed in a micro-benchmark (`F2`, 2026-07-31) but **not yet in the app**
(`F3`).

Context that sizes the upper bound: doc 15 established that a pane at 179x66
retains **~1,768 rows** of history at the 10 MB budget (`15/F17`), so the
whole-stream walk is bounded by roughly 300k cells at that geometry -- less in
practice, since a non-wrapped row projects only to its last content column.

## Current hypotheses

### H1 -- the double-click expansion gesture scales with retained scrollback, at a size a user can feel

The unit-building expansion path builds a `ProjectionUnit` per projected cell
of the whole stream, each owning a freshly allocated `[Unicode.Scalar]` (`F1`), and
`selectionUnit(...)` is called once per pointer-move during a drag
(`TerminalInteractionPolicy.swift:383`).

- Predicts: probe deep/shallow ratio far above 1, and a deep composite well
  above a millisecond -- a meaningful fraction of a 120 Hz frame's 8.3 ms.
- Competing explanation: allocation of many tiny same-sized arrays is exactly
  what a size-class allocator is fastest at, and the units array grows by
  doubling, so the constant may be small enough that even 200k units lands in
  the tens of microseconds.
- Distinguishing observation: `F2`'s deep-scrollback expansion composite.
- **Refined by `F2c`:** confirmed, but the per-move framing above understates
  exposure. A drag latches its granularity at the opening click, so ordinary
  click-drag highlighting is `.character`; meanwhile a bare double-click with
  no movement at all pays the same full unit build. The dominant symptom is a
  stall on click, not drag jank.

### H2 -- character granularity, the common drag, is a different and much smaller cost

`characterRange` builds no units. It pays repeated `activeProjectionRows()`
materializations -- one per helper call, roughly six across a query plus its
`setSelection` application (`F1`) -- each an array copy of N `GridRow` structs
with a retain/release on each row's cell storage.

- Predicts: same shape (ratio far above 1), far smaller absolute -- likely
  microseconds, not milliseconds.
- Why it matters: if H1 is true and H2 is true, the change is worth taking but
  its user-visible win is confined to double-click drags. If H1 is *false*, the
  change has no case at all.
- Distinguishing observation: `F2` measures both granularities separately.

### H3 -- the real cost of the change is equivalence risk, not code volume

The bounded walk is small (`detectedLink` at `Terminal.swift:2377` already runs
the same row-slice idiom). What is not small is that `forEachProjectionUnit` is
**not a pure function of the rows handed to it**: it truncates at a
whole-stream last-content row, its caller's fallback scans the entire stream,
and the row sequence has an alternate-screen seam rule. Two of the three are
pinned by no existing test.

- Predicts: if implemented from the plan text without the three carried
  dependencies, at least one of `PO4`/`PO6`/`PO7` fails on the first run.
- Confirmed in part already: the three dependencies are established from source
  in `F1`; what is untested is whether a careful implementation preserves them.

## Candidate direction, pending evidence

Provisional. This is the converged contract from the
point-local-selection-projection plan draft, which this file replaces (that
draft is no longer on disk; this section is its surviving copy).
It graduates back to a plan file if and only if `D1` records "take"; if `D1`
records "drop", it stays here as the rejected shape with its reason.

**Decision.** Give selection private indexed access to the exact sequence
`activeProjectionRows()` currently builds: scrollback followed by live rows,
including the alternate-screen rule that clears the last scrollback row's
soft-wrap seam. This is deliberately distinct from viewport row access, which
indexes only displayed alternate-screen rows.

Expansion selection finds the clicked logical line by following adjacent
soft-wrap flags, then builds projection units only for that row slice. The
bounded projection retains the whole stream's last-content boundary rather than
recomputing it from the slice. Target lookup uses the already-normalized
absolute click anchor, and expansion keeps whatever boundary predicate the
engine defines at that time.

When the click has no projected unit, preserve the whole-stream nearest-unit
fallback with row-level checks: search backward for the nearest preceding row
that projects a unit -- content, or a soft-wrapped row within the carried
last-content boundary -- then forward when none precedes the click. Only the
selected fallback row's logical line is projected into units.

Character ranges, logical-line ranges, empty ranges, and `setSelection`
endpoint normalization use indexed rows as well. Full-stream projection remains
available to operations that inherently consume full history, including search,
Select All, and history export. No public API changes.

**Invariants.**

- **I1** -- Character, expansion, and line selection produce the same
  ranges and selected text as before this optimization.
- **I2** -- No pointer-down or selection-drag range query, nor application of
  its resulting range, materializes rows or units for the whole retained
  stream.
- **I3** -- Expansion unit construction is proportional to the clicked
  logical line, not unrelated scrollback. Blank regions and the global
  last-content boundary may cost one row-level check per searched row, but
  never unit construction or row-array materialization for those rows. An
  exceptionally long soft-wrapped logical line remains the unavoidable unit
  work worst case.
- **I4** -- Soft-wrapped selection crosses the boundary between scrollback and
  live-row storage, while a hard line ending remains a boundary.
- **I5** -- Wide-cell atomicity, projected whitespace selection, clicks past
  retained content, empty-line behavior, out-of-range clamping, and whole-unit
  dragging remain unchanged.
- **I6** -- Existing alternate-screen selection coordinates remain unchanged in
  this optimization.

**Proof obligations.**

- **PO1** (I1, I3) -- With large unrelated scrollback, character, expansion,
  and line queries near the live bottom and in browsed history return
  the expected ranges and selected text.
- **PO2** (I2) -- Inspection of the gesture and range-application paths confirms
  they use indexed rows or logical-line slices and do not call whole-stream row
  or unit materialization. No timing threshold or percentage is claimed.
- **PO3** (I4) -- Expansion selection spans a soft-wrapped logical line
  whose rows straddle scrollback and live storage, and stop at a hard-ended
  line.
- **PO4** (I1, I3, I5) -- Nearest-unit fallback matches the existing projection
  for a blank line between content lines, a blank row after all content, a
  blank row before all content, and a blank soft-wrapped row.
- **PO5** (I1) -- Applying each computed range through `setSelection` preserves
  its range and selected text.
- **PO6** (I1, I5) -- An expansion query on projected whitespace inside a
  soft-wrapped line matches the whole-stream last-content truncation rule.
- **PO7** (I6) -- Before refactoring, characterize character, expansion, and
  line ranges while alternate screen is active and retained primary scrollback
  exists; the indexed implementation must preserve those results.
- **PO8** (I5) -- Existing selection-unit and interaction-policy coverage
  remains green, supplemented where needed for wide cells, retained-content
  fallback, clamping, and dragging through the indexed path.

**Non-goals.** Optimizing selected-text serialization, search, Select All,
history export, or other projection consumers outside the gesture path.
Changing selection granularity, click-count mapping, PTY mouse behavior, or any
public interface.

**Accepted risk (AR1).** The no-whole-stream-materialization invariant has no
automated regression counter. Test-only instrumentation would couple behavioral
tests to internal traversal mechanics, so code inspection and implementation
review remain its guard.

**Follow-up, out of scope.** Define and test the intended alternate-screen
selection stream, then reconcile the current mismatch between viewport row
coordinates and the active text projection when retained primary scrollback
exists. `I6` deliberately preserves today's behavior rather than fixing it.

## Task ledger

### Phase 1 -- price the gesture, before any implementation

- [x] **Done 2026-07-31** (`F2`, plus the `F2b` scaling arm; `text_equal` held
      in every arm). Build the scratch probe per `D2` and record its design and
      medians in `F2`: deep (10 MB, at budget) and shallow (~50 rows) arms
      sharing one local suffix and identical gesture coordinates, one arm per
      surviving granularity (character, expansion, line), each timing one
      `.move` decision through `decideTerminalPointer` plus application of its
      returned `selectionMutation`. Record both the ratio and the absolute
      median per granularity. *Extended beyond `D2`'s ask with saturated
      100 MB and 50,000-row arms (`F2b`) to characterize the scaling curve;
      those arms' absolutes are not user-facing figures.*
- [ ] Confirm the cost exists in the real app, not just the probe, as a
      **differential** capture: optimized build, deep scrollback, two
      equal-duration `sample` runs -- one across a burst of repeated bare
      double-clicks on a word, one idle control with no pointer activity.
      Record in `F3` whether the `projectionUnits` / `activeProjectionRows`
      subtree appears materially only in the click capture, and the delivered
      click count if it can be observed. `F3` passes on that presence/absence
      contrast alone; do not claim numerical agreement with `F2`'s per-event
      figure unless the sampled share can be normalized by an observed event
      count, since sampled process share depends on event rate and unrelated
      process CPU. A probe that disagrees with the app is measuring the wrong
      thing -- this step exists because `17/F17` cost doc 17 its headline for
      exactly that reason.

      *Method revised 2026-07-31 (was: hold a sustained double-click drag).
      `F2c` showed the expansion cost is paid in full by the `.down` decision,
      so a bare double-click reproduces it without a drag. The revision only
      changes how the gesture is driven; the presence/absence contrast, the
      normalization caveat, and `D1`'s thresholds are untouched. It is a
      strictly better instrument for this claim: one discrete event per click
      instead of an AppKit-coalesced move stream at an unmeasured rate, which
      is the caveat this step already carried and could not resolve.*

### Phase 2 -- decide

- [x] **Done 2026-07-31.** Read `F2` and `F3` against `D1`'s pre-registered
      gate and recorded **take** (step 2, ~13.6 ms against a ~2 ms threshold).
      `D1` carries two qualifications -- `F2c`'s who-pays correction and the
      shipped-budget urgency -- plus a note to split Phase 4 so the bounded unit
      build lands first.

### Phase 3 -- pin behavior before changing it (only on "take")

- [ ] Land `PO7`'s alternate-screen characterization against unmodified code;
      it must be green before any refactor. No such coverage exists today.
- [ ] Write `PO4` and `PO6` first and verify each fails against a naive
      per-line slice that recomputes the last-content boundary and searches
      only the clicked row. A test that passes against the naive version is not
      guarding `F1`'s dependencies.

### Phase 4 -- implement the selected direction

- [ ] Implement the candidate direction; `PO1`-`PO8` green.

### Phase 5 -- close with a final measurement

- [ ] Re-run the byte-identical probe from `F2` and record the result in `F4`.
      Expected: deep/shallow ratio collapses toward 1 for the expansion arm.
      Record the outcome even if the win is smaller than `F2` predicted --
      especially then.

## Findings log

### F1 -- every local selection query rebuilds the whole retained stream, and the unit walk depends on three whole-stream facts

- Status: established from source. **Not measured.**
- Date and investigator: 2026-07-30, during review of
  `plans/wip/point-local-selection-projection.md`.
- Commit and worktree state: `705244c`, clean except unrelated untracked docs.
- Method: read `Terminal.swift` and `TerminalInteractionPolicy.swift`; no
  execution.

**Observation, the cost.** Line cites in this finding were taken at `705244c`
and re-resolved at `e97345e` on 2026-07-31; the shape is unchanged, only the
numbers drifted (~110 lines) and the double-click entry point was renamed to
`terminalTokenRange` by the granularity work.

`activeProjectionRows()`
(`Terminal.swift:2793`) copies `scrollback ++ live` into a fresh `[GridRow]`.
`projectionUnits()` (`:2819`) then walks it via `forEachProjectionUnit`
(`:2834`), emitting one `ProjectionUnit` per projected cell; each unit owns a
freshly allocated `[Unicode.Scalar]` (`:2853`-`:2860`, and the struct at
`:380`). So the expansion path is one heap allocation per projected cell of
the entire retained stream, plus the growth of a units array of ~48-byte
elements. `terminalTokenRange` (`:2233`) is its only gesture caller.

On the pointer path, one drag-move calls `selectionUnit(...)` for the moved-to
position (`TerminalInteractionPolicy.swift:383`) and then applies
`.set(union(anchor, current))`, which reaches `setSelection`
(`Terminal.swift:2201`) -> `normalizedSelectionBoundary` x2 (`:2911`) ->
`normalizedCellPosition` (`:2894`) / `anchor(after:)` (`:2996`). Each of those
helpers calls `activeProjectionRows()` independently, so a single move costs
roughly six full row-array materializations *in addition to* the unit build.

Scale bound: ~1,768 retained rows at 179x66 at the 10 MB budget (`15/F17`),
hence O(300k) cells as an upper bound at that geometry; the real count is lower
because `projectedCellEnd` stops at a non-wrapped row's last content column
(`:2880`).

**Observation, the three whole-stream dependencies.** These are why a naive
slice is not equivalent:

1. **Global last-content truncation.** `forEachProjectionUnit` computes
   `stream.lastIndex(where: rowContainsContent)` over whatever stream it is
   given and emits nothing past it, including suppressing the trailing
   hard-boundary unit on that row. Recomputed on a slice it means something
   different.
2. **Whole-stream nearest-unit fallback.** `nearestTextUnitIndex` (`:2937`)
   resolves a click no unit contains by taking the last text unit with
   `start <= target` across the *entire* unit array, falling back to the first
   unit when none precedes. Clicking a blank line between two commands
   therefore selects the previous line's last word today. A per-line slice
   returns an empty range instead. Note the predicate is "projects a unit", not
   "contains content": a soft-wrapped row of `.padding` cells projects a run of
   spaces (`projectedCellEnd` returns full width for it) while
   `rowContainsContent` (`:5717`) is false, and `eraseLine(mode: 1)` blanks
   cells without clearing `isSoftWrapped`, so that row is reachable.
3. **Alternate-screen seam.** `activeProjectionRows()` forces the last
   scrollback row's `isSoftWrapped` to false under alt screen. The
   already-present indexed accessor `viewportStreamRow(at:)` has *different*
   alt-screen semantics -- it indexes live rows directly and ignores scrollback
   -- so reusing it shifts every alt-screen selection coordinate by
   `scrollbackRows.count`.

**Inference.** The gesture path is O(retained stream) in both allocations and
row copies, per pointer event. Whether that is a user-visible cost is not
determined by this finding.

**Competing interpretations.** Allocation of uniform small arrays is the
allocator's best case, and the row-array copy is N retain/release pairs rather
than a deep copy of cell storage, so the constants could be small enough that
even the upper-bound cell count lands well under a frame budget. `F2` decides
this.

**Uncertainty.** Cell count per row in real output is unmeasured; the 300k
figure is a ceiling, not an estimate. Pointer-event rate during a drag is
assumed to be display rate and unverified.

**Next action.** `F2` -- build the probe and price it.

### F2 -- probe: what a drag move actually costs

- Status: **measured** 2026-07-31. Diagnostic numbers, not benchmark results:
  no verdict, no threshold, no `faster`/`slower` label.
- Commit and worktree state: `e97345e`, clean except unrelated untracked docs
  and this file.
- Machine state: Apple M1 Pro, macOS 26.5.2, Swift 6.3.3, AC power, no other
  deliberate load.
- Method: scratch probe per `D2`, built in the scratchpad and not committed.
  `swift build -c release --package-path lib/TerminalCore`, then a standalone
  `.swift` compiled with `xcrun swiftc -O -I <bin>/Modules` against the
  `TerminalCore.build/*.o` objects -- the `scripts/terminal-viability.sh:273`
  pattern. Every arm drives `decideTerminalPointer`, never an individual range
  function.

**Probe design, as built.** Geometry 179x66 with the production 10 MB budget,
matching `15/F17`. Both arms feed one shared 80-line local suffix of
word-bearing text; the deep arm prepends generated history in 500-line chunks
until `scrollProjection.totalRows` stops growing for three consecutive chunks
(the observable eviction signal), plus three more chunks to sit at the ceiling.
Gesture per granularity: `.down(.left, column: 20, row: 40, clickCount: k)`
outside the timed region, then a timed `.move(column: 62, row: 42)` decision
plus application of its `selectionMutation` exactly as
`TerminalPTYHost.applyPointer` does. `selectedText` is never called inside the
timed region; elision is defeated by checksumming the returned range endpoints,
and text equivalence is verified once per granularity outside the loop. Median
of 300 iterations after 30 warmup.

**Deviation from `D2`'s stated shallow arm.** `D2` asks for a ~50-row shallow
arm, which 179x66 cannot express: the live grid alone is 66 rows, so the
minimum stream is 66. The shallow arm is the 80-line suffix by itself
(`totalRows` 81). Both arms therefore end with an identical scrolled viewport
and a byte-identical clicked logical line, which is the property the ratio
actually depends on.

**Arm sizes.** Deep `totalRows` = **1,768**, from 5,000 fed history lines --
an exact match for `15/F17`'s independently measured retained-row count at this
geometry, which is a useful cross-check that the deep arm really sits at
budget. Shallow `totalRows` = 81.

**Medians**, microseconds per drag-move, three runs:

| granularity | shallow | deep | ratio |
| --- | --- | --- | --- |
| `character` | 5.08 / 5.25 / 5.25 | 92.3 / 96.1 / 101.3 | 18.2 / 18.3 / 19.3 |
| `terminalToken` | 505.4 / 523.5 / 524.7 | **14,381.9** / 24,584.0 / 14,272.7 | 28.5 / 47.0 / 27.2 |
| `line` | 18.0 / 18.1 / 18.2 | 101.8 / 96.8 / 100.0 | 5.6 / 5.4 / 5.5 |

`text_equal` was `yes` for every granularity in every run: the deep and shallow
arms select byte-identical text, so the ratio measures history depth alone.

**Observation.** The double-click (`terminalToken`) deep composite is
**~14.4 ms per drag-move** -- roughly 1.7x a 120 Hz frame's entire 8.3 ms
budget, on a path that then still has to plan and draw. `H1` is confirmed, and
by a wider margin than it predicted; its competing explanation (the allocator
absorbs the tiny-array traffic) is refuted. At ~14.4 ms for ~1,768 rows the
per-unit cost is ~48 ns, which is a heap allocation plus array growth per
projected cell, exactly as `F1` described.

`H2` is confirmed as stated: `character` shows the same shape (ratio ~18) at a
far smaller absolute (~95 us deep). Note it lands just *below* `D1` step 4's
0.1 ms character threshold, which is moot because step 2 fires first.

**Unanticipated result: `line` granularity is already mostly point-local.** Its
ratio is ~5.5, a third of `character`'s, and its deep absolute (~100 us) is
indistinguishable from `character`'s despite doing strictly more work. The
reason is in the code, not the measurement: `trimmedLogicalLineRange`
(`Terminal.swift:2292`) already builds units only for the clicked logical
line's row slice (`:2299`-`:2302`). Its residual cost is the
`activeProjectionRows()` materializations alone -- which is precisely the
"reduced version" `D1` step 4 describes, already implemented for one
granularity. That is direct evidence the bounded-unit-build half of the
candidate direction is where the 14.4 ms lives, and that the indexed-row half
is worth roughly the 5x that `line` still pays.

**Run-to-run spread.** The 24.6 ms `terminalToken` deep median in run 2 is a
~1.7x outlier against two tightly agreeing runs at ~14.3 ms; treat ~14.4 ms as
the figure and the outlier as allocator/memory-pressure noise. It does not move
any gate step -- every observed value is far above step 2's ~2 ms.

**Uncertainty.** Absolute figures are M1 Pro-specific. Pointer-event rate
during a real drag is still assumed, not measured (`F3`'s job). The probe
measures core-local cost only.

#### F2b -- how the cost scales with retained rows

Two further arms were added to separate "how big is it today" from "what shape
is the curve": a saturated **100 MB** budget (10x production) and a
**50,000-row** arm built against an unbounded budget. Neither is a
configuration DanTerm ships; both exist to characterize scaling, and their
absolutes are not user-facing figures.

Reaching a non-production budget needs `Terminal.init(columns:rows:scrollbackBudgetBytes:)`,
which is internal, so this build used `@testable import TerminalCore` against a
`-Xswiftc -enable-testing` release build. **That did not distort the
measurement**: the 10 MB arm under `-enable-testing` reproduces the plain
release figures within run-to-run spread (character 90-97 us vs 92-101 us,
`terminalToken` 13.58-13.91 ms vs 14.27-14.38 ms, line 89-99 us vs 96-102 us).
Only the internal initializer is reached that way; every timed call is public
API.

**Row cost, measured via `Terminal.memoryCensus`.** `cellStrideBytes` is 32 and
every arm reports **5,728 bytes per row** = 179 columns x 32, because rows are
stored full-width regardless of content. That is why a 100 MB budget buys only
~17k rows: the ceiling is the cell representation (docs 12 and 16), not
anything in the selection path. The row-count arms below are therefore the
honest axis for this file -- retained *rows* are what the projection walks, and
bytes-per-row is someone else's subject.

Medians in microseconds, 10 warmup; iteration counts fall with arm cost
(300/300/30/15):

| granularity | shallow, 81 rows | 1,768 rows (10 MB) | 17,088 rows (100 MB) | 50,081 rows (274 MB) |
| --- | --- | --- | --- | --- |
| `character` | 5.2 | 89.6 | 2,218 | **6,803** |
| `terminalToken` | 495 | 13,580 | 135,808 | **399,739** |
| `line` | 17.5 | 89.5 | 1,898 | **6,493** |

`text_equal` remained `yes` for every arm and granularity: all four streams
select byte-identical text, so the comparison is still history depth alone.

**Observation 1 -- the unit build is exactly linear in retained rows, across
28x of range.** `terminalToken` goes 1,768 -> 17,088 rows (9.67x) for 10.0x the
time, then 17,088 -> 50,081 (2.93x) for 2.94x the time. No threshold, no
amortization: O(retained cells) per pointer move, exactly as `F1` described. At
50k rows a double-click drag costs **~400 ms per move** -- roughly 48 frames at
120 Hz, for a single event in a gesture that delivers events continuously.

**Observation 2 -- the row-materialization paths have a knee between 1,768 and
17,088 rows, then go linear again.** `character` grows 9.67x in rows but ~25x
in time over the first step (90 us -> 2.22 ms), then only 3.07x over the second
(2.22 -> 6.80 ms) for 2.93x the rows. `line` behaves the same way (~21x, then
3.42x). Both are pure `activeProjectionRows()` cost -- `characterRange` builds
no units, and `trimmedLogicalLineRange` already bounds its unit build to the
clicked line -- so the excess is in the row-array copy itself, and it is a
one-time step rather than a compounding exponent.

- Leading explanation, **not established**: `[GridRow]` materialization crosses
  libmalloc's ~128 KB large-allocation cutoff somewhere in that interval, so
  each of the ~6 copies per move becomes an `mmap`/`munmap` pair with fresh
  page faults instead of a free-list hit. A knee that appears once and then
  leaves the slope linear is the signature of an allocator path change, not of
  a super-linear algorithm.
- Distinguishing observation, if anyone wants it: `malloc` stack logging or a
  `vm_fault` count across the interval, or intermediate row counts to locate
  the knee precisely. Not needed for `D1`.
- Either way it strengthens the case, and it is specifically evidence for the
  *indexed-row* half of the candidate direction -- the half `line` granularity
  has not yet been given.

**What this does and does not change.** It does not change `D1`, which reads
against the production 10 MB budget and already fires step 2. What it adds is a
bound on the future: **the current design has no headroom in retained rows.**
At 17k rows a double-click drag costs ~136 ms per event and even a plain
`character` drag -- the common gesture -- passes 2 ms; at 50k rows those are
~400 ms and ~6.8 ms. Any future work that retains more history is gated behind
this optimization, and that includes work on the cell representation, since
making rows cheaper in bytes is precisely what would let the same budget retain
the row counts measured here.

#### F2c -- which gesture actually pays the expansion cost

`F2` and `F2b` both price a `.move`, because `D1`'s gate is written "per drag
move". Reading the drag branch (`TerminalInteractionPolicy.swift:381`-`:398`)
sharpens what that means, in two directions.

**A drag extends at the granularity latched by its opening click, not by
character.** `state.selectionDrag.granularity` is set once in
`pointerDownDecision` from the click count and reused for every subsequent
`.move`. So an ordinary click-and-drag highlight is `.character` for its whole
length, and the `terminalToken` figures apply only to a double-click-and-hold
drag, which extends token by token. That makes the ordinary highlight drag the
`character` row: ~90 us at the production budget, 2.2 ms at 17k rows, 6.8 ms at
50k -- real scaling, modest absolutes today.

**But the expansion cost is not primarily a drag cost at all: it is paid in
full by a bare double-click.** `pointerDownDecision` runs the same
`selectionUnit` query at the click's granularity, so selecting a word with a
double-click and *no pointer movement whatsoever* pays one complete
whole-stream unit build. Measured directly by timing the `.down` decision plus
its applied mutation, medians in microseconds:

| granularity | 81 rows | 1,768 rows | 17,088 rows | 50,081 rows |
| --- | --- | --- | --- | --- |
| `character` | 1.5 | 26.5 | 626 | 1,889 |
| `terminalToken` | 493 | **13,542** | **134,688** | **397,850** |
| `line` | 17.0 | 89.7 | 1,901 | 5,779 |

The `terminalToken` click is within noise of the `terminalToken` move
(13.5 vs 13.6 ms at production; 398 vs 400 ms at 50k rows), which is expected:
both run `terminalTokenRange` over the whole stream and then apply a range
through `setSelection`. The `character` click is *cheaper* than a character
move (26.5 vs 89.6 us) because a character `.down` returns `.clear` rather than
`.set`, skipping `setSelection`'s two `normalizedSelectionBoundary` calls.

**Why this matters for how the finding is stated.** `H1` frames the subject as
a gesture whose cost recurs "once per pointer-move during a drag", and `D1`'s
gate reads a per-move composite. That framing is not wrong, but it understates
exposure: double-click-to-select-a-word is a far more common gesture than
double-click-and-drag, and it pays the same ~13.9 ms at the shipped budget for
a single click. The user-visible symptom is therefore a stall on *click*, not
only jank during a drag.

It does not change `D1`. The deciding number is the same number; step 2 fires
on it either way. What changes is the description of who feels it, which the
resulting plan should carry so it does not justify itself solely on drag
smoothness.

**Next action.** `F3` -- confirm the cost appears in the real app.

### F3 -- does the app agree with the probe

- Status: **measured 2026-07-31. The app agrees.** Phase 1.

Differential `sample` capture against a live optimized `DanTerm Dev` (0.0.84,
`com.danneu.danterm-dev`, macOS 26.5.2, Apple M1 Pro), sampling every 1 ms for
10 s per capture, one pane saturated past the 10 MiB budget. Method per the
revised Phase 1 step: a burst of repeated bare double-clicks versus an idle
control, driven by hand.

**Instrument validity, checked before the capture.** Optimization does not
erase the frames this step looks for: in the shipped binary `activeProjectionRows`
survives as an out-of-line function and `terminalTokenRange(at:)` as an exported
symbol, and `forEachProjectionUnit` survives as three closure-propagated
specializations. `projectionUnits` survives *only* inside those specialization
names -- it is inlined into its callers -- so a grep for `projectionUnits` alone
would have under-reported. The capture matched all four names. This check exists
because a false negative here would look exactly like a passing control.

**Result -- presence/absence.** Selection-path frames appear in the click
capture and not in the control:

| capture | pty-host queue samples | selection-path frames |
|---|---|---|
| control (idle) | 1 | **0** |
| click (double-click burst) | 450 | **37** |

The click capture's call chain is the one `F1` predicted, on
`com.danneu.danterm.terminal-pty-host`:

```
450  DispatchQueue_288: com.danneu.danterm.terminal-pty-host (serial)
 359  closure #1 in closure #1 in TerminalPTYHost.sendPointer(_:onPaneMenu:onOpenLink:)
  311  TerminalPTYHost.applyPointer(_:onPaneMenu:onOpenLink:)
   297  decideTerminalPointer(_:terminal:state:)
    174  Terminal.terminalTokenRange(at:)
     45   specialized Terminal.forEachProjectionUnit(from:absoluteBase:_:)
     ...  Terminal.activeProjectionRows()
```

So `decideTerminalPointer` accounts for 297 of the queue's 450 samples, and
`terminalTokenRange` -- one call per click, doing nothing but building units --
is its single largest child at 174. The control's lone pty-host sample sits in
`applyPointer` with no projection frame beneath it, which is the expected shape
for an idle queue that saw one stray pointer event.

**What this does and does not establish.** It passes on the presence/absence
contrast, which is all the pre-registered step asked of it. It is *not* a
numerical corroboration of `F2`: `sample` gives no click count, so the sampled
share cannot be normalized per event, exactly as the step warned. For scale
only, and explicitly not as a claim: 450 ms of queue CPU across 10 s of manual
clicking is the same order as ~20 double-clicks at `F2`'s 13.5 ms, but the click
count was not observed and the arithmetic is not evidence.

The value of this step is that the probe is not measuring a path the app does
not take. It takes it, through the call chain `F1` named, at the granularity
`F2c` identified, on a bare click with no drag.

**Subjective read.** Not recorded -- the operator did not report whether the
clicks felt like they hitched. `F2b`'s note stands: at the shipped budget this
is roughly one dropped frame per click, plausibly noticeable only when looked
for. That remains the closest thing this doc has to a user-facing measurement,
and it is still missing.

### F4 -- post-change measurement

- Status: **pending.** Phase 5, only on "take".

## Decision log

### D1 -- is the point-local change worth its equivalence risk

- Status: **TAKE, recorded 2026-07-31.** Gate pre-registered below on
  2026-07-30, before any measurement. Read in order, the gate stops at
  **step 2**: the `terminalToken` deep composite is ~13.6 ms, ~7x the ~2 ms
  threshold. Verdict: **take the candidate direction as written.** `F3`'s
  app-level capture is in and corroborates the path (`decideTerminalPointer` at
  297 of 450 pty-host samples during a click burst, zero in the idle control),
  so the `17/F17` failure mode -- a probe the app does not corroborate -- does
  not apply here.

  **Two qualifications carried into the plan, neither of which changes the
  verdict:**

  1. *`F2c` changes who pays, not how much.* The gate is written per drag move,
     but the cost is paid in full by a bare double-click. The plan must justify
     itself on a stall at click time, not on drag smoothness -- ordinary
     click-drag highlighting is `.character` and is already cheap.
  2. *The urgency is smaller than the headline.* At the shipped 10 MiB budget
     this is ~13.6 ms, roughly one dropped frame per double-click. The 135 ms
     and 400 ms figures in `F2b` require row counts DanTerm cannot currently
     retain (5,728 bytes/row caps 10 MiB at ~1.7k rows), so they are a headroom
     argument for after the cell-representation work, not a today argument. The
     gate fired on the shipped-budget number alone; the deep arms are not load
     bearing for this decision and the plan should not lean on them.

  **Sequencing note, not a gate change.** `F2b`/`F2c` separate the candidate
  direction's two halves cleanly, and they are independently shippable: the
  bounded unit build captures the entire user-visible win (the 13.6 ms click),
  while the indexed-row half addresses the ~90 us `.character` path that nothing
  can feel at any budget DanTerm reaches today. Landing the bounded unit build
  first gets the value at a fraction of `H3`'s equivalence risk -- it needs only
  the last-content-truncation and nearest-unit-fallback dependencies, and
  `trimmedLogicalLineRange` already ships that exact pattern for `.line`
  granularity as a working precedent. Phase 4 should be split accordingly.
- Evidence to be used: `F2` (probe medians and deep/shallow ratios per
  granularity), `F3` (app-level confirmation), `F1` (the equivalence cost being
  bought).
- Candidate solutions: take the candidate direction as written; take a reduced
  version (indexed rows only, no bounded unit build) if `H2` holds and `H1`
  does not; drop.

**Pre-registered gate**, read against the deep-scrollback composite per drag
move. Frame of reference: a 120 Hz drag leaves ~8.3 ms per event for
everything, planning and drawing included.

Read the steps in order and stop at the first that fires; every measurement
reaches exactly one verdict.

Definitions. *Deep composite* is the deep-arm median for a granularity. *Scales*
means that granularity's deep/shallow ratio is at or above 2.

1. **Neither expansion nor character scales** (both ratios below 2) ->
   **Drop**, and record in `F1` that its source-level scaling observation is
   *immaterial or obscured in this workload* -- not false. The dependency the
   source shows is real; the measurement says it does not dominate at the
   retained-stream sizes this project actually reaches, so `F1`'s three
   dependencies are not worth reproducing.
2. **Expansion deep composite at or above ~2 ms** -> **Take** the candidate
   direction as written. At a 120 Hz drag's ~8.3 ms per event this is a
   substantial share of the frame budget on a path that also has to plan and
   draw. (It is a large fraction, not proof of a dropped frame on its own.)
3. **Expansion deep composite ~0.5-2 ms** -> **Take**, and weight the
   `.character` figure in the resulting plan: character is the granularity most
   drags use, so if it is trivial the user-visible win is confined to
   double-click drags. Say so in the plan.
4. **Expansion deep composite below ~0.5 ms, character deep composite at or
   above ~0.1 ms and character scales** -> **Take the reduced version**: indexed
   row access only, no bounded unit build. This buys the character path without
   reproducing the last-content-truncation and nearest-unit-fallback
   dependencies that only the unit build needs.
5. **Otherwise** (expansion below ~0.5 ms and character below ~0.1 ms or not
   scaling) -> **Drop.** The mechanism is real but nobody can feel it.

- Tradeoffs and correctness risks: the change buys latency and pays in three
  reproduced whole-stream dependencies (`F1`), two of which are pinned by no
  current test. `AR1` records that `I2` itself has no automated guard.
- Falsifier: deep/shallow ratios below 2 in every granularity (step 1), or deep
  absolutes under the step-5 thresholds.

### D2 -- how to measure a path no calibrated workload contains

- Status: **decided** 2026-07-30.
- Evidence used: the workload table in
  [agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md)
  -- none of the five workloads generates a pointer event.
- Candidate solutions: (a) add a calibrated selection workload to the paired
  harness; (b) drive a real drag through the GUI via Accessibility and time it;
  (c) a scratch release-mode micro-benchmark against the public selection API.
- Selected direction: **(c)**, driven through the public pointer entry point,
  with a `sample` capture of a live drag as the reality check (`F3`).
- Rationale: (a) costs calibration, the frozen-pair machinery, and the GUI
  contract proof for a one-off decision, and would leave a permanent workload
  behind for a path that is not otherwise contended. (b) measures the right
  thing but adds Accessibility scripting and window state to a question that is
  entirely core-local. (c) reaches the pointer path exactly, because
  `decideTerminalPointer` (`TerminalInteractionPolicy.swift:250`) and
  `TerminalPointerDecision.selectionMutation` are both `public`, so no
  `@testable` and no `Package.swift` change is needed -- the ad-hoc compile
  pattern at `scripts/terminal-viability.sh:273` (compile a standalone `.swift`
  against the built `TerminalCore` objects) already exists for exactly this
  shape.

**Probe requirements**, so `F2` and `F4` are comparable:

- **Drive all three granularity arms through `decideTerminalPointer`, never
  through individual range functions.** `characterRange` (`Terminal.swift:2308`)
  is internal, and calling public `setSelection(from:to:)` directly would skip
  the character query the pointer path actually performs -- so a direct-call
  probe would measure a materially different path for the most common drag
  granularity. Per arm: establish the click-count-specific drag with a `.down`
  decision *outside* the timed region, time one `.move` decision, and apply the
  returned `selectionMutation` inside the timed region exactly as
  `TerminalPTYHost.applyPointer` does (`TerminalPTYHost.swift:916`).
- Feed generated word-bearing lines until eviction begins, so the deep arm sits
  at the real `productionScrollbackBudgetBytes` ceiling (`Terminal.swift:584`),
  not at an arbitrary row count.
- **Deep and shallow arms differ only in history depth.** Build both from one
  shared local suffix, appending only a generated history prefix to the deep
  arm, and use identical gesture coordinates (down position, move position,
  click count). The clicked logical line, the rows around it, and the resulting
  selected text must be byte-identical between arms, so the ratio measures
  scrollback depth and nothing else.
- One arm per granularity; the shallow arm (~50 rows total) supplies the ratio.
- Median over a few hundred iterations after a warmup; AC power, no other load.
- **Do not call `selectedText` inside the timed region.** It deliberately walks
  the whole stream and would measure an out-of-scope cost. Defeat `-O` elision
  by checksumming the returned `selectionMutation`'s range endpoints inside the
  loop; verify selected-text equivalence between arms once, outside it.
- Lives in the scratchpad and is never committed (see Rejected).

## Rejected

### Add a calibrated selection workload to the paired benchmark

Would make the change decidable by frozen rule, which is this project's usual
bar. Rejected on proportion: it requires calibration, the position-balanced
schedule, a frozen threshold, and the GUI contract proof, and would leave a
permanent sixth workload behind for a path with no ongoing contention. Reopen
if selection cost turns out to be a recurring subject rather than a one-off
decision.

### Commit the probe as a regression guard for I2

Rejected as `AR1`: test-only traversal instrumentation couples a behavioral
suite to internal mechanics, and the thing it would guard (`I2`) is a structural
property that code inspection and implementation review already cover. The
consequence is accepted explicitly -- a future edit reintroducing
`activeProjectionRows()` into a selection helper will not be caught by any test.
Reopen if that actually happens.

## Open questions and caveats

- **The copy path is untouched and is a plausible second subject.**
  `selectedText` projects the full stream, and `hasSelection`
  (`TerminalPaneSession.swift:598`) calls it for Copy menu validation
  (`SwiftTerminalSessionView.swift:562`, `PaneWrapperView.swift:437`). So menu
  validation over a deep scrollback pays the full walk. Out of scope here by
  the candidate direction's non-goals; worth its own trigger if `F3` shows it.
- **Pointer-event rate during a drag is assumed, not measured.** The gate reads
  against a 120 Hz budget; if AppKit coalesces drag events more aggressively
  than that, the per-move cost matters proportionally less.
- **`F1`'s 300k-cell ceiling is a ceiling.** Real rows project only to their
  last content column, so the practical unit count is unknown until `F2`.
- **The probe measures core-local cost only.** It cannot see actor hops,
  snapshot delivery, or anything else between the pointer event and the draw.
  `F3` is the only check on that, and it is qualitative.

## Outcome

**Phases 1 and 2 are closed. `D1` records TAKE.** Phases 3-5 remain; nothing is
implemented yet.

Phase 1 measured the gesture (`F2`): the double-click expansion costs ~13.6 ms
at the 10 MiB scrollback ceiling against ~0.5 ms shallow, and `character` and
`line` scale too at far smaller absolutes. `F2c` establishes that this is paid
in full by a bare double-click, not only by dragging -- ordinary click-drag
highlighting runs at the cheaper `character` granularity -- so the symptom is a
stall on click. `F3` confirms the app takes exactly the path `F1` named:
`decideTerminalPointer` holds 297 of 450 pty-host samples during a click burst
and zero appear in the idle control. `F2b` adds that the expansion path is
exactly linear in retained rows across 28x of range (~136 ms at 17k rows,
~400 ms at 50k), while the row-copy paths take a one-time allocator knee in
between.

Two things to carry forward, both recorded in `D1`. The deep-arm figures are a
headroom argument, not a today argument -- 5,728 bytes/row caps the shipped
10 MiB budget at ~1.7k rows, so nobody reaches 17k rows until the
cell-representation work lands; the gate fired on the shipped-budget number
alone. And Phase 4 should be split, bounded unit build first: it captures the
whole user-visible win at a fraction of `H3`'s equivalence risk, with
`trimmedLogicalLineRange` already shipping the pattern for `.line`.

The one thing Phase 1 did not produce is a subjective read on whether a
double-click *feels* like it hitches at the shipped budget. That is still the
closest thing to a user-facing measurement here, and it is still missing.
