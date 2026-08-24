# Extract state synchronization from Terminal

Source: PARSE-6 in
`docs/scratch/2026-08-18-construction-audit.md`, verified 2026-08-24 against
`61b3f5e9`. This is a pivot from the finding's two-part extraction.

## Problem and evidence

`Terminal.swift` is 8,765 lines. About 600 contiguous lines only read terminal
state and encode a synchronization byte stream. This serialization job now
owns history budgeting, primary and alternate screen reconstruction, control
state, modes, tab stops, styles, hyperlinks, semantic marks, character sets,
and grapheme continuation. Keeping it inside the mutable parser and grid owner
makes changes to either concern contend in the same type and file.

The finding's inspection half does not solve its stated construction problem.
Putting the inspection fields in one value would still let a content mutation
omit the required invalidation call. The concrete search/history hazard has
already been removed by the retained-history mutation door in `f3134418`.

PARSE-2 (`c5057591`), PARSE-3 (`038ba535`), INTERACT-1 (`f3134418`), and
FEED-3 (`8fbc376d`) have landed. No prerequisite remains.

## Decision

Move the complete state-synchronization encoder behind a read-only terminal
state boundary in its own source file. `Terminal` keeps its existing public
synchronization API and supplies one immutable view of the state needed to
encode it. The extracted subsystem owns history-budget selection, logical-line
alignment, row and control-state encoding, and byte writing.

The boundary must preserve the exhaustive ANSI and DEC mode catalogs: adding a
supported mode without deciding how synchronization represents it remains a
compile-time failure. It must not give the encoder write access to `Terminal`,
make Terminal's stored state writable outside its owner, copy the scrollback
arena, or materialize all retained history to encode a bounded suffix. The
encoder input carries the retained-history store's indexed read view, and the
encoder selects and materializes only the suffix the budget admits.

Only encode-direction helpers move. Synchronization decoding stays with the
parser and its mutating handlers on `Terminal`.

## Invariants

- I1. The public synchronization APIs and wire format do not change.
- I2. A source terminal and a terminal reconstructed from its synchronization
  have the same observable grid, retained history, cursor, modes, styles,
  links, semantic state, character-set state, and continuation behavior.
- I3. A history budget keeps its current byte bound, cuts only at a complete
  logical-line boundary, reports the same dropped-row count, and never reduces
  active-grid fidelity.
- I4. Synchronization is a read-only operation. It cannot mutate terminal,
  inspection, parser, grid, history, or pending-reply state.
- I5. Encoding work remains proportional to the retained suffix selected by
  the caller's budget plus the complete live screens; the extraction adds no
  full-history copy or second scrollback owner.

## Proof obligations

- PO1 (I1, I2, I4): the existing unbounded synchronization suite passes
  unchanged, including primary and alternate screens, every supported mode,
  saved cursor state, tab stops, styles, hyperlinks, semantic marks, character
  sets, grapheme continuation, and unfinished input recognition.
- PO2 (I1, I3): the existing bounded-history synchronization suite passes
  unchanged, including the byte bound, logical-line cut, exact grid replay,
  dropped-row report, and repair after replica divergence.
- PO3 (I1, I2): existing exact-byte assertions and the tab-stop, reset,
  viewport-rotation, selection, search, hyperlink, inspection-invalidation,
  and resize suites pass unchanged.
- PO4 (I5): a deterministic cost proof shows that a bounded synchronization's
  retained-row visits do not grow when retained depth grows while the budget
  and admitted suffix stay fixed; an unbounded synchronization is the
  non-vacuous control whose visits do grow.
- PO5: `just lint` and `just test` pass. No test may reach into the new private
  decomposition; proofs stay on the public synchronization behavior.

## Non-goals and rejected ideas

- NG1. No control-sequence, wire-format, package-dependency, or public API
  change.
- NG2. No inspection-state extraction or content-mutation refactor.
- RI1. A `TerminalInspection` property bag is rejected because it moves state
  without making missed invalidation impossible. A future construction-level
  fix would need a content-mutation boundary that owns mutation, damage, and
  invalidation together.
- RI2. A file split that leaves the encoder with unrestricted access to
  `Terminal` is rejected because it lets serialization dependencies regrow
  silently; the read-only input boundary is the construction-level value of
  this refactor.

## Implementation discretion

- The shape and naming of non-history fields in the immutable encoder input are
  left to the implementation, subject to I4.
- Existing behavioral tests may be regrouped, but new structure-sensitive
  comparison tests are unnecessary.
