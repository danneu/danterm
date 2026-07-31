# Selection gesture cost and point-local projection

Research started: 2026-07-30.

## Purpose

Owns one question: **does a local selection gesture cost enough to justify
making it point-local, and can the change hold behavioral equivalence while it
does?** A plan for the change already exists in reviewed, converged form (it is
reproduced below as the candidate direction), but every claim in it about cost
is derived from reading the call graph. Nothing has been measured. This file
exists to price the gesture before the change is implemented, and to hold the
decision either way.

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
- **Granularity redefinition lands first.**
  [plans/wip/ghostty-selection-granularity.md](../../plans/wip/ghostty-selection-granularity.md)
  replaces character-class word and whitespace-run cluster with one
  boundary-set cluster at double-click, moves line to triple-click, and cycles
  higher counts. This file's "expansion" arm means that surviving cluster
  granularity. Do not run Phase 1 against the old four-granularity mapping: it
  would price a granularity that is about to be deleted.
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

Reading the selection path at `705244c` while reviewing
`plans/wip/point-local-selection-projection.md`. Every local selection query --
character, expansion (double-click), line -- and every application of a
resulting range rebuilds a materialized copy of the entire retained stream, and
the expansion path additionally allocates one array per projected cell of
scrollback. This runs per pointer event during a drag.

That is a source-level observation, recorded in full as `F1`. **No timing has
been taken**, in a micro-benchmark or in the app. The size of the effect, and
therefore whether it matters, is exactly what Phase 1 is for.

Context that sizes the upper bound: doc 15 established that a pane at 179x66
retains **~1,768 rows** of history at the 10 MB budget (`15/F17`), so the
whole-stream walk is bounded by roughly 300k cells at that geometry -- less in
practice, since a non-wrapped row projects only to its last content column.

## Current hypotheses

### H1 -- the double-click expansion gesture scales with retained scrollback, at a size a user can feel

The unit-building expansion path builds a `ProjectionUnit` per projected cell
of the whole stream, each owning a freshly allocated `[Unicode.Scalar]` (`F1`), and
`selectionUnit(...)` is called once per pointer-move during a drag
(`TerminalInteractionPolicy.swift:384`).

- Predicts: probe deep/shallow ratio far above 1, and a deep composite well
  above a millisecond -- a meaningful fraction of a 120 Hz frame's 8.3 ms.
- Competing explanation: allocation of many tiny same-sized arrays is exactly
  what a size-class allocator is fastest at, and the units array grows by
  doubling, so the constant may be small enough that even 200k units lands in
  the tens of microseconds.
- Distinguishing observation: `F2`'s deep-scrollback expansion composite.

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

The bounded walk is small (`detectedLink` at `Terminal.swift:2268` already runs
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

Provisional. This is the converged contract from
`plans/wip/point-local-selection-projection.md`, which this file replaces.
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

- [ ] Build the scratch probe per `D2` and record its design and medians in
      `F2`: deep (10 MB, at budget) and shallow (~50 rows) arms sharing one
      local suffix and identical gesture coordinates, one arm per surviving
      granularity (character, expansion, line), each timing one `.move`
      decision through `decideTerminalPointer` plus application of its returned
      `selectionMutation`. Record both the ratio and the absolute median per
      granularity.
- [ ] Confirm the cost exists in the real app, not just the probe, as a
      **differential** capture: optimized build, deep scrollback, two
      equal-duration `sample` runs -- one while holding a sustained
      double-click drag, one idle control with no pointer activity. Record in
      `F3` whether the `projectionUnits` / `activeProjectionRows` subtree
      appears materially only in the drag capture, and the delivered move count
      if it can be observed. `F3` passes on that presence/absence contrast
      alone; do not claim numerical agreement with `F2`'s per-move figure
      unless the sampled share can be normalized by an observed move count,
      since sampled process share depends on drag event rate and unrelated
      process CPU. A probe that disagrees with the app is measuring the wrong
      thing -- this step exists because `17/F17` cost doc 17 its headline for
      exactly that reason.

### Phase 2 -- decide

- [ ] Read `F2` and `F3` against `D1`'s pre-registered gate and record take or
      drop in `D1`. On drop, close the file: the candidate direction stays here
      with its measured reason, and nothing is implemented.

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

**Observation, the cost.** `activeProjectionRows()`
(`Terminal.swift:2684`) copies `scrollback ++ live` into a fresh `[GridRow]`.
`projectionUnits()` (`:2693`) then walks it via `forEachProjectionUnit`
(`:2708`), emitting one `ProjectionUnit` per projected cell; each unit owns a
freshly allocated `[Unicode.Scalar]` (`:2724`-`:2731`, and the struct at
`:348`). So the expansion path is one heap allocation per projected cell of
the entire retained stream, plus the growth of a units array of ~48-byte
elements.

On the pointer path, one drag-move calls `selectionUnit(...)` for the moved-to
position (`TerminalInteractionPolicy.swift:384`) and then applies
`.set(union(anchor, current))`, which reaches `setSelection`
(`Terminal.swift:2087`) -> `normalizedSelectionBoundary` x2 (`:2802`) ->
`normalizedCellPosition` (`:2785`) / `anchor(after:)` (`:2886`). Each of those
helpers calls `activeProjectionRows()` independently, so a single move costs
roughly six full row-array materializations *in addition to* the unit build.

Scale bound: ~1,768 retained rows at 179x66 at the 10 MB budget (`15/F17`),
hence O(300k) cells as an upper bound at that geometry; the real count is lower
because `projectedCellEnd` stops at a non-wrapped row's last content column
(`:2753`).

**Observation, the three whole-stream dependencies.** These are why a naive
slice is not equivalent:

1. **Global last-content truncation.** `forEachProjectionUnit` computes
   `stream.lastIndex(where: rowContainsContent)` over whatever stream it is
   given and emits nothing past it, including suppressing the trailing
   hard-boundary unit on that row. Recomputed on a slice it means something
   different.
2. **Whole-stream nearest-unit fallback.** `nearestTextUnitIndex` (`:2828`)
   resolves a click no unit contains by taking the last text unit with
   `start <= target` across the *entire* unit array, falling back to the first
   unit when none precedes. Clicking a blank line between two commands
   therefore selects the previous line's last word today. A per-line slice
   returns an empty range instead. Note the predicate is "projects a unit", not
   "contains content": a soft-wrapped row of `.padding` cells projects a run of
   spaces (`projectedCellEnd` returns full width for it) while
   `rowContainsContent` (`:5544`) is false, and `eraseLine(mode: 1)` blanks
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

- Status: **pending.** Phase 1.

### F3 -- does the app agree with the probe

- Status: **pending.** Phase 1.

### F4 -- post-change measurement

- Status: **pending.** Phase 5, only on "take".

## Decision log

### D1 -- is the point-local change worth its equivalence risk

- Status: **pending `F2`/`F3`.** Gate pre-registered below on 2026-07-30,
  before any measurement.
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
  `decideTerminalPointer` (`TerminalInteractionPolicy.swift:251`) and
  `TerminalPointerDecision.selectionMutation` are both `public`, so no
  `@testable` and no `Package.swift` change is needed -- the ad-hoc compile
  pattern at `scripts/terminal-viability.sh:273` (compile a standalone `.swift`
  against the built `TerminalCore` objects) already exists for exactly this
  shape.

**Probe requirements**, so `F2` and `F4` are comparable:

- **Drive all four granularity arms through `decideTerminalPointer`, never
  through individual range functions.** `characterRange` (`Terminal.swift:2244`)
  is internal, and calling public `setSelection(from:to:)` directly would skip
  the character query the pointer path actually performs -- so a direct-call
  probe would measure a materially different path for the most common drag
  granularity. Per arm: establish the click-count-specific drag with a `.down`
  decision *outside* the timed region, time one `.move` decision, and apply the
  returned `selectionMutation` inside the timed region exactly as
  `TerminalPTYHost.applyPointer` does (`TerminalPTYHost.swift:836`).
- Feed generated word-bearing lines until eviction begins, so the deep arm sits
  at the real `productionScrollbackBudgetBytes` ceiling (`Terminal.swift:543`),
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
  (`TerminalPaneSession.swift:338`) calls it for Copy menu validation
  (`SwiftTerminalSessionView.swift:522`, `PaneWrapperView.swift:437`). So menu
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

Investigation in progress. Nothing measured, nothing implemented.
