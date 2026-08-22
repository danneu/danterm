# Derive grapheme continuation from the grid after terminal actions

Source: BUG-33 in `docs/scratch/2026-08-18-construction-audit.md`, verified
against `367def2b` on 2026-08-21. This plan pivots from the finding's
zero-width-only fallback.

## Problem, outcome, and evidence

DanTerm keeps streaming grapheme state while it prints adjacent scalars. Cursor
motion and several grid actions clear that state. If the next scalar needs the
cell before the cursor to decide its grapheme boundary, the printer does not
consult the grid. It drops a zero-width scalar and starts a positive-width
scalar as a new cluster even when the preceding cell proves that the scalar
belongs to it.

The smallest probe is `e ESC [ 2 G U+0301`: the cursor returns to the position
after `e`, but the accent disappears. The code still has this shape in
`lib/TerminalCore/Sources/TerminalCore/Terminal.swift`: motion clears the
streaming context, the join path declines without it, and the printer returns
on an unjoined zero-width scalar.

No existing test covers the adjacent-predecessor probe. The combining-mark half
of `TerminalGraphemeTests.cursorMovementResetsLookBehind` moves two columns past
its base, so the blank intervening cell makes it a no-predecessor case that
should keep passing. The regional-indicator half does pin behavior this work
must preserve under the clarified wide-cell rule. Commit `608d12de` introduced
both expectations with grapheme assembly.

The live terminal contract points the other way:

- `docs/design/2026-08-06-swift-terminal-engine.md` D1 makes an extended
  grapheme cluster the indivisible visible unit and advertises mode 2027 as
  permanently set.
- D2 says zero-width marks extend their cluster.
- D13 requires every grid mutation to preserve whole grapheme cells.
- D14 bounds retained cluster data at 256 UTF-8 bytes while keeping streaming
  segmentation state correct after a scalar is dropped at the bound.
- Kitty, Ghostty in mode 2027, and foot recover the preceding cluster from the
  cursor and grid. They use grapheme breaking rather than a special rule that
  blindly appends zero-width input.

The desired outcome is that terminal actions can discard stale streaming state
without inventing a text boundary. The next scalar uses the actual preceding
grid cell when one exists, and ordinary grapheme segmentation decides whether
it joins.

## Decision

Use two sources of grapheme look-behind with a clear authority order:

1. Continue to use live streaming state while it remains valid. It carries the
   exact segmentation history, including scalars dropped at the retention
   bound.
2. When that state is absent, reconstruct sufficient look-behind from the
   content immediately before the cursor. The grid determines the attachment
   target; replaying that cell's retained scalars determines its segmentation
   state.

Apply this decision to every printing route before the printer decides that a
zero-width scalar is invisible or that a positive-width scalar starts a new
cell. Optimized runs can proceed only after reaching the same answer for their
first scalar. This covers combining marks, variation selectors, emoji ZWJ
followers, regional indicators, Hangul, Indic conjuncts, and future classes
governed by the same pinned grapheme algorithm.

The grid predecessor follows terminal geometry. A pending wrap identifies the
current cell as the trailing edge of the last printed unit; a wide tail there
resolves to its wide head. Without a pending wrap, the cursor must follow the
candidate cluster: if the cursor cell is a wide tail, the cursor is inside that
cluster and no predecessor exists; otherwise the cell to the left is the
candidate, and a wide tail there resolves to its wide head. Column zero can
reach the last content cell of the preceding row only when that row logically
continues into the current row. Blank layout, stale wrap claims, and
non-content cells do not supply a predecessor.

A joined scalar may change its predecessor's cell width only when the
predecessor and cursor have the relationship that uninterrupted printing
establishes: they are in the same row and the cursor immediately follows the
predecessor, or the cursor holds that predecessor's pending-wrap trailing edge.
A cross-row predecessor can accept scalars that leave its width unchanged, but
it remains ineligible for a width change throughout that cluster's
continuation. The restriction is checked for every joined scalar, including
those processed through live state established by an earlier recovery.

REP is an explicit exception to recovery. Each requested repetition starts a
new cluster even if its first scalar could join the cell before the cursor.
Clearing streaming state for that boundary must not cause grid reconstruction.

A terminal action is not itself a grapheme boundary. An action that removes or
separates the predecessor naturally prevents attachment because the resolved
grid relationship no longer exists. An action that leaves the predecessor
immediately before the cursor does not prevent attachment merely because it
cleared cached state.

## Invariants

- **I1 - Grid-authoritative recovery:** When live look-behind is absent, the
  next scalar is compared with the grapheme cell the cursor follows, as the
  Decision's geometry defines it.
- **I2 - One segmentation rule:** Recovered and uninterrupted input, including
  the head of an optimized run, use the same pinned grapheme-break rules. Width
  alone never decides attachment.
- **I3 - Whole-cell geometry:** Attachment targets a narrow cell or a wide
  head that the cursor follows. Every joined width change requires the same-row
  cursor relationship of uninterrupted printing or its pending-wrap case,
  including after a width-neutral cross-row recovery; other attachment leaves
  wrap state, cursor state, damage, and text projection as valid as
  uninterrupted cluster assembly.
- **I4 - Logical row boundary:** Recovery crosses a row boundary exactly when
  the preceding row logically continues. It never crosses a hard boundary or
  a stale erased wrap claim.
- **I5 - Streaming fidelity:** Valid live state remains authoritative because
  it can contain segmentation history that the bounded grid intentionally no
  longer stores.
- **I6 - Retention bound:** Recovery never lets a live cell, REP memory, or
  synchronization payload retain more than 256 UTF-8 bytes. Dropped joining
  scalars still advance live segmentation state.
- **I7 - Print ordering:** Attachment is decided before positive-width pending
  wrap handling. A joining scalar extends its predecessor instead of wrapping
  and starting a new cell.
- **I8 - Terminal side state:** A joined scalar has the same observable style,
  hyperlink, single-shift, inspection invalidation, and REP memory whether
  attachment used live or recovered look-behind. REP starts every repetition
  as a new cluster.
- **I9 - No invented base:** If the grid exposes no valid predecessor, an
  unjoined zero-width scalar remains invisible and a positive-width scalar
  prints normally. A cursor inside a wide pair exposes no valid predecessor. A
  cross-row cluster is invalid for any later joined scalar that would change
  its width, even after a width-neutral scalar established live state.

## Proof obligations

- **PO1 - Reported defect:** Through byte ingestion, cursor positioning between
  a base and a combining mark preserves the mark in the base cell without
  moving the cursor unexpectedly.
- **PO2 - Full grapheme scope:** Positive-width joins after a terminal action
  obey the same emoji, regional-indicator, Hangul, and Indic boundaries as an
  uninterrupted scalar stream. Moving the cursor onto a regional indicator's
  wide tail exposes no predecessor: the next two indicators form their own
  wide cluster at the cursor and replace the intersected old pair atomically.
- **PO3 - Geometry:** Recovery from after a wide cell reaches its wide head,
  while recovery from inside a wide pair declines. A recovered selector or
  other width contributor changes a same-row predecessor under the existing
  cursor and wrap rules. A cross-row recovered selector that would upgrade or
  downgrade its predecessor leaves the grid and cursor unchanged, both when it
  arrives first and when a width-neutral combining mark established live state
  earlier in the same continuation.
- **PO4 - Row seams:** Recovery attaches across a genuine soft wrap and declines
  across a hard line ending, blank padding, and a stale erased wrap claim.
- **PO5 - Actions versus content:** Motion and non-destructive actions preserve
  attachment when the same predecessor remains adjacent. Erase, overwrite,
  scroll, and resize prevent attachment when they remove or separate that
  predecessor.
- **PO6 - Bounded state:** A recovered cluster at the 256-byte bound stays
  bounded, advances segmentation correctly, and remains equivalent after state
  synchronization.
- **PO7 - Side effects:** Recovered attachment updates projection consumers,
  damage, width, REP memory, style, hyperlink identity, and character-set shift
  state exactly as uninterrupted attachment does. Repeating one regional
  indicator produces two separate wide cells rather than joining the repeated
  scalar to its predecessor.
- **PO8 - No predecessor:** Leading marks and marks addressed after empty layout
  remain invisible, while the next ordinary scalar prints and recovers normally.
- **PO9 - Existing contract:** Chunk boundaries remain irrelevant, no-op events
  preserve exact live state, and the last-column behavior from `51609b1e`
  remains unchanged for joining and non-joining scalars. An ASCII run after a
  recovered Prepend predecessor produces the same joined grid regardless of
  run length or input chunking.

Write the failing behavioral tests first and confirm that they fail because
the printer does not recover grid look-behind. Run the focused TerminalCore
suite and lint during the loop, then the full local gate before commit.

## Dependencies and integration

This work is confined to TerminalCore. It needs no AppKit, PTY, CLI, parser,
package dependency, public API, migration, or synchronization-format change.
The existing Unicode tables and grapheme breaker remain authoritative.

The main conflict surface is the scalar and optimized-run print code in
`Terminal.swift` and the grapheme and ASCII-run tests. BUG-30 may overlap the
soft-wrap evidence used at row boundaries. Preserve its distinction between a
live continuation and a stale erased wrap claim. BUG-31 and BUG-32 have
separate reset and saved-cursor contracts; do not fold them into this work.

The mode-independent last-column change in `51609b1e` has already landed. Its
ordering constraint is binding: a joining scalar is resolved before deferred
wrap, while a non-joining positive-width scalar follows the existing wrap path.

## Rejected ideas

- **RI1 - Append only zero-width scalars:** This fixes the audit probe but
  violates unconditional grapheme clustering for positive-width joiners and
  duplicates part of the existing attachment path.
- **RI2 - Append every zero-width scalar blindly:** Width does not determine a
  grapheme boundary. This would attach non-joining input and bypass width,
  retention, invalidation, and REP behavior.
- **RI3 - Reconstruct from the grid for every scalar:** The live state is the
  exact and cheaper source during an uninterrupted stream. The bounded grid
  cannot reconstruct segmentation history for scalars deliberately dropped
  after the retention limit.
- **RI4 - Keep terminal actions as forced grapheme boundaries:** This preserves
  the current tests but contradicts the permanent mode-2027 claim, the grid
  model used by the compatible references, and D1-D2.

## Non-goals and accepted risks

- Changing Unicode data, grapheme-break rules, width policy, or the 256-byte
  bound is out of scope.
- Matching xterm's fallback to the cell under the cursor is out of scope;
  DanTerm follows the preceding-cell model used by its closer grid references.
- **AR1 - Bounded reconstruction:** After live state is cleared, recovery can
  replay only scalars retained in the cell. This is the unavoidable consequence
  of D14 without adding per-cell segmentation metadata; the recovered cell is
  still bounded and valid, and uninterrupted streams retain exact state.

## Implementation discretion

- The internal representation and factoring of predecessor resolution and
  reconstructed look-behind are implementation choices.
- Behavioral proof obligations decide test grouping and file placement.
