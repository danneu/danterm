# Inspection, Search, and Recovery

## Problem

Pane reads, selection, search, state export, and crash recovery all turn terminal
cells into observable text. If they disagree about soft wraps, trailing cells,
or line endings, a resize can change IPC output or saved history even when the
logical terminal content did not change.

## Decision

The terminal core owns one deterministic logical-text projection used by inspection,
selection, search, and persistence. A soft wrap contributes no separator. A
hard line boundary between retained logical lines contributes `\n`. Empty
right-hand grid padding and trailing padding-only rows are omitted; spaces that
were written into selected or retained content are preserved. Serialization
does not add a final newline merely because a viewport or selection ended.

Under [Engine architecture and testability](03-engine-architecture.md), this
projection is deterministic policy. Inspection and persistence consumers
receive read-only results, and their IO adapters do not redefine text semantics.

Inspection has two explicit ranges:

- viewport text is the logical content intersecting the rows selected by the
  pane's local viewport under the scrolling contract in
  [Input and interaction](08-input-interaction.md)
- full-history text is the retained scrollback plus active rows of the active
  screen

`danterm pane read` without `--lines` returns viewport text. With `--lines N`,
it returns the last `N` newline-delimited logical lines of full-history text,
not the last `N` visual rows. `N == 0` returns an empty string; otherwise the
operation preserves whether the source projection ended in a newline.

Linear selection uses the same serialization: it joins soft-wrapped rows,
places `\n` at included hard boundaries, preserves selected spaces and empty
logical lines, and never splits a grapheme cluster or wide cell. Search is a
literal search over the same full-history projection. It is ASCII
case-insensitive and otherwise Unicode-exact initially, can span soft wraps but
not an unrequested hard newline, selects the newest match first, navigates
toward older matches with Next and newer matches with Previous, and stops at
either end rather than wrapping.

Export and enriched recovery checkpoints capture primary-screen full history;
alternate-screen content is transient and is not replayed into a new shell.
The existing DanTerm persistence projection remains the compatibility
contract and is the explicit exception to the projection's space preservation:
it trims leading and trailing whitespace from the full-history text as a whole,
omits the result when nothing remains, retains at most the last 4,000 logical
lines and 400,000 grapheme clusters, and stores non-empty replay text with
exactly one final newline. Recovery restores this plain text only; terminal
modes, presentation attributes, selection, search state, and alternate-screen
state are not reconstructed.

Enriched recovery freshness is event-driven. A terminal mutation that changes
the enriched recovery projection makes recovery dirty. Dirty recovery is
checkpointed through bounded coalescing: isolated changes are eventually
written, sustained changes cannot postpone a covering checkpoint indefinitely,
and a later mutation remains dirty until a checkpoint includes it. Once the
persisted checkpoint covers the latest mutation, no recurring checkpoint work
remains scheduled. Clean termination flushes dirty recovery.

## Invariants

- Reflow changes visual rows without changing logical-text serialization.
- Pane reads, selection, search, export, and recovery agree on hard and soft
  line boundaries.
- A text range never begins or ends inside a grapheme cluster or wide cell.
- Inspection and persistence do not expose terminal padding as user content.
- Alternate-screen activity cannot replace or enter saved primary history.
- Changed enriched recovery becomes durable within a bounded checkpoint window,
  while a clean terminal schedules no recurring checkpoint work.

## Proof obligations

- Current-backend characterization fixtures pin viewport and full-history
  extraction, soft wraps, written and padding spaces, empty rows, and final
  newline behavior before the runtime reader is replaced.
- `pane read --lines` counts logical lines across several widths and preserves
  the source projection's final-newline state.
- Selection and search fixtures cover hard boundaries, soft wraps, Spanish,
  Chinese wide text, emoji, spaces, empty lines, case behavior, navigation
  order, and reflow.
- Export and enriched-checkpoint fixtures prove the primary/alternate-screen
  boundary, persistence limits, whitespace-only omission, final newline, and
  plain-text recovery replay.
- Recovery scheduling traces cover isolated output, sustained output, a write
  completion racing later output, clean idle, and termination flush; every
  mutation remains dirty until a persisted checkpoint covers it, and clean
  state becomes quiescent.
- The Ghostty and Swift backends return identical IPC text for the
  characterization corpus while both backends exist.

## Non-goals

- Styled or HTML pane export.
- Persisting terminal modes, cell attributes, selection, search state, or the
  alternate screen.
- Regex, whole-word, or locale-sensitive search in the initial engine.

## Implementation discretion

- The logical-position and text-slice representation.
- How inspection avoids copying unchanged history, provided the observable
  projection and resource limits remain unchanged.
