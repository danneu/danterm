# Point-local selection projection

## Context and evidence

Every local selection query -- character, terminal-token, line -- and every
application of a resulting range rebuilds a materialized copy of the entire
retained stream, and the terminal-token path additionally allocates one
`[Unicode.Scalar]` per projected cell of that stream. This runs per pointer
event. A click that touches roughly ten units builds hundreds of thousands.

Evidence, from [docs/research/21-selection-gesture-cost.md](../../docs/research/21-selection-gesture-cost.md):

- `F1` -- the source-level observation, including the three whole-stream
  dependencies below.
- `F2`/`F2b`/`F2c` -- probe timings. Cost scales with retained rows, and is paid
  in full by the pointer-down decision, so a bare double-click pays it with no
  drag at all.
- `F3` -- app confirmation on an optimized build: a double-click burst put 450
  samples on the terminal PTY-host queue against 1 idle, 37 of them in selection
  frames.
- `D1` -- recorded **take**.

**Why now.** The cost is linear in retained rows. Today's 10 MB scrollback
budget caps a 179x66 pane at ~1,768 rows (`15/F17`), which bounds the waste;
raising that budget raises the per-click cost proportionally. The goal is
therefore asymptotic -- gesture cost independent of retained history -- not a
constant-factor win.

**Load-bearing premises.**

1. The unit walk depends on three facts about the whole stream, not just the
   clicked row: last-content truncation, the nearest-unit fallback's search
   extent, and an alternate-screen soft-wrap seam (`F1`). `F6` falsified a
   naive per-line slice against five of six pinned points, and every wrong
   answer was plausible rather than obviously broken.
2. Truncation semantics already differ by caller: terminal-token expansion
   truncates at the whole stream's last content row, while trimmed-line and
   link detection truncate within their own row slice. Unifying them would be
   a silent behavior change.

## Decision

Give selection indexed access to the projected row sequence -- scrollback
followed by live rows, carrying the alternate-screen seam rule -- instead of a
materialized copy, and expand from the clicked point outward.

Resolve the carried whole-stream facts by bounded search from the stream edges
rather than by a cached or precomputed unit index. `Terminal` is a value type
and its range queries are non-mutating reads; a cache would force `mutating`
onto that surface and add an invalidation obligation to every grid write,
erase, scroll, reflow, and screen switch.

**Behavioral scope.** Character, terminal-token, and line ranges; the
empty-range and endpoint-normalization paths that apply them; and link
resolution, which already windows to a row radius. Whole-stream projection
remains for consumers that inherently read all history: search, Select All,
history export, width reflow, and selected-text serialization. No public API
changes.

**Critical files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` owns
the projection and every range API. `TerminalInteractionPolicy.swift` dispatches
granularity and is not modified. Coverage lives in
`lib/TerminalCore/Tests/TerminalCoreTests/` -- `TerminalSelectionUnitTests.swift`,
`TerminalSelectionTests.swift`, `TerminalInteractionPolicyTests.swift`,
`TerminalHyperlinkTests.swift`.

## Invariants

- **I1** -- Character, terminal-token, and line selection produce the same
  ranges and selected text as before this optimization.
- **I2** -- No pointer-down or selection-drag range query, nor application of
  its resulting range, materializes rows or units for the whole retained stream.
- **I3** -- Unit construction is proportional to the clicked logical line, not
  to unrelated scrollback. Blank regions and the global last-content boundary
  may cost one row-level check per searched row, never unit construction or row
  materialization for those rows. A long soft-wrapped logical line remains the
  unavoidable worst case.
- **I4** -- Soft-wrapped selection crosses the boundary between scrollback and
  live-row storage; a hard line ending remains a boundary.
- **I5** -- Wide-cell atomicity, projected whitespace selection, clicks past
  retained content, empty-line behavior, out-of-range clamping, and whole-unit
  dragging are unchanged.
- **I6** -- Alternate-screen selection coordinates are unchanged, including
  today's mismatch between viewport rows and the active text projection.

## Proof obligations

- **PO1** (I1, I3) -- With large unrelated scrollback, character, terminal-token
  and line queries near the live bottom and in browsed history return the
  expected ranges and selected text.
- **PO2** (I2) -- Inspection confirms the gesture and range-application paths
  read indexed rows or logical-line slices and call no whole-stream
  materialization. No timing threshold is claimed. See `AR1`.
- **PO3** (I4) -- Terminal-token selection spans a soft-wrapped logical line
  whose rows straddle scrollback and live storage, and stops at a hard-ended
  line.
- **PO4** (I1, I3, I5) -- *Discharged.* Nearest-unit fallback matches the
  existing projection for a blank line between content lines, a blank row after
  all content, a blank row before all content, and a blank soft-wrapped row.
- **PO5** (I1) -- Applying each computed range through `setSelection` preserves
  its range and selected text.
- **PO6** (I1, I5) -- *Discharged.* A terminal-token query on projected
  whitespace inside a soft-wrapped line matches the whole-stream last-content
  truncation rule, and the same point's line query matches the slice-local rule
  (premise 2).
- **PO7** (I6) -- *Discharged.* Character, terminal-token and line ranges while
  the alternate screen is active over retained primary scrollback are
  characterized; the indexed implementation reproduces them.
- **PO8** (I1, I5) -- Existing selection-unit, interaction-policy and hyperlink
  coverage stays green, supplemented for wide cells, retained-content fallback,
  clamping, and dragging through the indexed path; and Select All's selected
  text still equals full history text.

## Non-goals, accepted risks, rejected ideas

**Non-goals.** Optimizing search, Select All, history export, or width reflow.
Changing selection granularity, click-count mapping, PTY mouse behavior, or any
public interface. Fixing `I6`'s alternate-screen coordinate mismatch (`F5`) --
entangling that with a performance change would make each one's effect
unattributable.

Optimizing selected-text serialization, which is unmeasured and carries a
global dependency this direction cannot satisfy: whether a blank hard-ended row
contributes a newline depends on whether content exists later in the whole
stream, at unbounded distance, so a range-local serializer cannot reproduce
today's text. Making it point-local means either an unbounded trailing scan or
a semantic change, and it needs its own evidence either way.

**AR1** -- The no-whole-stream-materialization invariant has no automated
regression counter. Test-only instrumentation would couple behavioral tests to
internal traversal mechanics, so code inspection and implementation review
remain its guard.

**RI1** -- A cached or incrementally maintained unit/boundary index, rejected
above: it converts a read-only value-type surface into a mutating one and
spreads an invalidation obligation across every grid mutation, to accelerate a
query that occurs at human click rate.

**RI2** -- A calibrated selection workload in the paired benchmark harness,
rejected in doc 21: none of the five workloads invokes a selection query, so a
paired run reports `equivalent` regardless of this change's size.

## Implementation discretion

- How the whole-stream walk and the point-local walk are kept in agreement --
  a shared per-row emission definition, or independent implementations proven
  equivalent by `PO1`/`PO4`/`PO6`.
- Whether unit classification reads cell scalars in place or materializes them.

## Commit progress

- [x] 1. perf(terminal): expand a terminal token from the clicked point outward
- [x] 2. refactor(terminal): index the projected row stream instead of copying it
- [x] 3. docs(research): record `F4` and close doc 21

Each slice lands green, with its tests. Slice 1 carries the measured win and is
where `PO1`, `PO3` and `PO5` are written; slice 2 is behavior-preserving by
construction, carries no new tests beyond existing suites staying green, and is
what completes `I2`.

## Verification

- `swift test --package-path lib/TerminalCore` -- the selection, interaction
  policy, hyperlink and search suites. Whole-package green is the gate for each
  slice, since search, Select All and reflow share the projection being changed.
- `just test` before the final slice.
- `PO2` by inspection, per `AR1`.
- Phase 5 of doc 21: re-run the byte-identical `F2` probe from the scratchpad on
  a release build and record the deep/shallow ratio and absolute as `F4`. The
  ratio is the deciding quantity -- the claim is that gesture cost stops scaling
  with unrelated scrollback. The probe is never committed.
- Manual: in a pane with deep scrollback, double-click a word and confirm the
  selection is unchanged and the click no longer stalls; copy it and confirm the
  clipboard content is unchanged.

## Implementation notes

- Slice 1 took the shared per-row emission definition offered by
  "Implementation discretion", not independent implementations: the whole-stream
  walk and the point-local walk both emit through one `forEachRowTextUnit`, so
  they cannot drift on wide cells, padding, or trailing-cell truncation. The
  hard boundary stays with each caller, because it is a fact *between* rows and
  has no row-local representation.
- `nearestTextUnit` collapses the old two-pass "containing, else last preceding"
  search into one backward walk: units are ordered and non-overlapping, so the
  last unit with `start <= target` is the containing unit whenever one exists.
- Slice 1's tests are characterization tests -- they pass before and after,
  because `I1` requires the change to be equivalence-preserving. They were
  written and run green against the old implementation first, so they pin the
  baseline rather than fail first. `F6` already established that the
  whole-stream dependencies are guarded by `PO4`/`PO6`, which fail against a
  naive slice.
- `terminalTokenRange` still calls `activeProjectionRows()` (and reaches it again
  through `normalizedBoundaryPosition`), so the row-array copy survives slice 1
  and `I2` is not yet met; removing it is slice 2's whole job. What slice 1
  removes is the unit array and its per-cell `[Unicode.Scalar]` allocation for
  the whole retained stream.
- Slice 2 gives the indexed access as a `ProjectionRows` value conforming to
  `RandomAccessCollection` over `(scrollbackRows, rows)`, rather than as
  `projectionRow(at:)`-style accessors. Every existing point-local reader already
  spoke `stream[i]` / `stream.count` / `stream.lastIndex(where:)` /
  `Array(stream[a...b])`, so the collection shape turned each call site into a
  one-line type change and left the walks themselves untouched -- which is what
  makes the slice behavior-preserving by construction.
- The alternate-screen seam rule moved into that view's subscript and
  `activeProjectionRows()` became `Array(activeProjection())`, so the materialized
  and indexed projections cannot disagree about the seam. The whole-stream
  consumers (search, Select All, reflow, selected-text serialization) therefore pay
  a per-row subscript branch where they previously got a bulk copy; they are
  already linear in retained rows with much heavier per-row work, and this keeps
  the rule stated once.
- `normalizedBoundaryPosition` and `normalizedSelectionBoundary` only ever needed
  the projection's extent, so they read a `projectionRowCount` property and build
  no view at all.
- Slice 3's `F4` re-ran the original `F2` probe unmodified -- it survived in the
  earlier session's scratchpad, so "byte-identical" is literal (`sha256`
  compared), not reconstructed. Only the build script's scratchpad path changed.
  Three `.move` runs plus one `.down` run; the probe is still uncommitted per the
  doc's `AR1`.
- `F4` records no post-change `sample` capture. `F3`'s instrument answers a
  presence/absence question, and after the change its frames are expected absent
  for two independent reasons (the work is gone, and what is left is under the
  sampler's resolution), so it could not discriminate between success and a
  broken capture.
- The plan's manual check (double-click in a deep-scrollback pane, confirm the
  selection and the clipboard are unchanged) is **not done** -- it needs a human
  at a GUI. Doc 21 closes noting that the subjective read was never taken, before
  or after.

## Follow Up

- Manual verification is still owed and cannot be done headlessly: in a pane
  with deep scrollback, double-click a word, confirm the selection is unchanged
  and the click no longer stalls, then copy it and confirm the clipboard content
  is unchanged. This is also the subjective read doc 21 closes without ever
  having taken.
- `selectedText` still walks the whole projection, and `hasSelection`
  (`TerminalPaneSession.swift#hasSelection`) calls it for Copy menu validation,
  so menu validation over deep scrollback still pays a full projection. Unmeasured;
  doc 21's reopening condition 1 says to price it before designing anything,
  because a range-local serializer provably cannot reproduce today's text.
- The alternate-screen click-coordinate mismatch (`21/F5`) is still live: a
  double-click on a full-screen program's visible text selects primary scrollback
  that is not on screen. Pinned as current behavior by
  `alternateScreenClickCoordinateMismatchCharacterization` in
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalSelectionUnitTests.swift`,
  which the eventual fix has to delete deliberately.
