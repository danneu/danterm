# Trim whitespace from line selection

## Problem and desired outcome

Line selection currently includes written leading and trailing whitespace.
Triple-clicking `bar` in `"  foo bar       "` therefore selects the spaces
around the useful text.

The desired outcome is a content-focused line gesture: the same triple-click
selects `"foo bar"` while preserving the existing logical-line, soft-wrap, and
dragging behavior.

## Decision

- Line selection trims projected units from both outer edges of the selected
  logical line when their leading scalar has Unicode's whitespace property.
- Trimming applies to the whole soft-wrapped logical line, not separately to
  each visual row.
- A whitespace-only logical line produces an empty range at that logical line's
  start, matching an empty line.
- A multi-line line-granularity drag remains one contiguous selection. Only its
  outer edges are trimmed; whitespace between selected content remains.
- Land this behavior before Phase 1 of
  [selection gesture cost research](../../docs/research/21-selection-gesture-cost.md)
  so that investigation measures the final line-selection gesture.

No public API signature changes.

## Invariants

- **I1** -- Triple-clicking `"  foo bar       "` selects exactly `"foo bar"`;
  click counts three and six produce the same trimmed line unit.
- **I2** -- Trimming removes whole projected units whose leading scalar has
  Unicode's whitespace property.
- **I3** -- Leading and trailing whitespace is trimmed across a soft-wrapped
  logical line, while internal whitespace and hard line boundaries are
  preserved.
- **I4** -- Empty and whitespace-only logical lines both produce empty ranges
  anchored at the logical line's first row, column zero, whether or not that
  line projects any units.
- **I5** -- Line-granularity dragging trims the outer selection edges without
  dropping whitespace between the selected endpoints.
- **I6** -- Character selection, cluster expansion, link detection, selection
  serialization, clamping, and retained-history behavior remain unchanged.

## Proof obligations

- **PO1** (I1) -- Exercise the pointer path at click counts three and six and
  verify the resulting range and selected text exclude surrounding whitespace,
  including on a scrollback line after history eviction.
- **PO2** (I2) -- Cover non-breaking and ideographic spaces, a whitespace base
  with a combining mark, and wide-cell atomicity.
- **PO3** (I3) -- Select a soft-wrapped logical line with whitespace at its
  logical edges and internal whitespace across the wrap; also verify expansion
  still stops at a hard line ending.
- **PO4** (I4) -- Verify a written whitespace-only line and an empty row past
  the last written content both return empty ranges at their logical-line
  starts.
- **PO5** (I5) -- Drag line selection across hard lines and verify only the
  overall outer edges are trimmed.
- **PO6** (I6) -- Existing selection-unit, interaction-policy, hyperlink, and
  retained-content coverage remains green.

## Non-goals

- Configuring the whitespace definition.
- Producing discontiguous per-line trimming for a multi-line selection.
- Changing double-click cluster boundaries, ordinary character dragging, or
  selected-text serialization.

## Accepted risks

- **AR1** -- Non-breaking and ideographic spaces at a logical line's outer
  edges are removed. This deliberately diverges from Ghostty's ASCII-only
  `{NUL, space, tab}` line-trimming set in favor of Unicode whitespace.

## Implementation discretion

- How logical-line bounds and projected units are traversed, provided link
  detection keeps its current full-line behavior and the invariants above hold.

## Implementation notes

- Trimming landed as a new `Terminal.trimmedLogicalLineRange(at:)` rather than
  inside `logicalLineRange(at:)`. Detected-link resolution windows its scan on
  `logicalLineRange`'s row bounds, so trimming in place would have moved the rows
  it searches -- an indented wrapped line would silently lose its URL. The
  pointer policy's `.line` granularity is the only caller switched over;
  `logicalLineRange` keeps its untrimmed contract.
- `logicalLineRange` gained a private stream-taking overload so
  `trimmedLogicalLineRange` materializes `activeProjectionRows()` once instead of
  twice. Line-granularity dragging recomputes the unit on every pointer sample,
  so the duplicate projection build was worth removing before the gesture-cost
  research measures it.
