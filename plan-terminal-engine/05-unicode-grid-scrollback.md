# Unicode, Grid, and Scrollback

## Problem

Spanish composition, Chinese text, emoji, wide cells, selection, and resize
reflow must agree on one definition of terminal text. A scalar-per-cell or
rendered-width model cannot preserve those behaviors reliably.

## Decision

The terminal text model treats extended grapheme clusters as the indivisible
user-visible unit. Terminal width is protocol state, not a measurement of the
chosen glyph.

- Zero-width marks extend the appropriate cluster.
- Narrow clusters occupy one cell.
- East Asian Wide and Fullwidth clusters occupy two cells.
- East Asian Ambiguous clusters occupy one cell by default.
- Basic emoji and common supported emoji sequences occupy a stable terminal
  width and render through macOS font fallback.
- Private Use Area glyphs, including Nerd Font glyphs, are ordinary font glyphs;
  no separate Nerd Font protocol is required.

Unicode behavior is based on a pinned Unicode data version so width and
segmentation do not drift silently between releases.

Scrollback has a fixed 10 MiB per-pane storage budget. It preserves the
difference between hard line endings and soft wraps so content reflows when a
pane changes width. The active viewport is outside the scrollback budget.

Primary-screen resize reflows retained history and active primary rows as one
ordered sequence of logical lines. A width change keeps the cursor attached to
the same logical cell boundary, including explicit blank cells, then chooses
visual rows at the new width. At the live bottom, a height shrink moves rows
displaced above the viewport into scrollback, while growth pulls the newest
eligible primary rows back from scrollback before adding blank rows. Resize does
not duplicate or discard logical content except through ordinary 10 MiB
eviction. A viewport browsing older content follows the stable-anchor contract
in [Input and interaction](08-input-interaction.md).

Alternate-screen resize does not reflow and never contributes rows to primary
history. Cells inside the resized rectangle retain their coordinates; shrink
discards cells outside it and clears a grapheme or wide cell as a whole when the
new edge would split it, while growth adds blank cells and rows. Active and
saved cursors clamp within the new grid without landing on a wide-cell tail, and
horizontal and vertical margins reset to the full resized grid. The inactive
primary screen independently follows the primary resize contract above.

## Invariants

- Canonically equivalent Spanish text occupies equivalent terminal geometry.
- A Chinese wide character or emoji cannot leave an orphaned half-cell after
  overwrite, erase, selection, scroll, or resize.
- Reflow changes visual wrapping without changing logical text or hard line
  boundaries.
- Primary-screen resize preserves the cursor's logical cell boundary and the
  combined logical content of retained history and active rows.
- Alternate-screen resize preserves valid cells, cursors, and margins without
  reflowing or transferring alternate content into primary history.
- Selection and search positions remain attached to logical content across
  reflow and obey the projection in
  [Inspection, search, and recovery](06-inspection-recovery.md).
- Scrollback eviction removes oldest content at valid grapheme boundaries and
  never produces invalid UTF-8 or partial presentation metadata.
- A single logical line larger than the budget may lose its oldest prefix, but
  retained content remains valid and is marked as truncated.

## Proof obligations

- Precomposed and decomposed Spanish examples render, select, erase, and search
  correctly.
- Chinese wide characters and U+1F618 render with stable geometry and survive
  all grid mutations without corruption.
- Every supported emoji sequence is one selection and editing unit even when
  glyph fallback is required.
- Repeated width changes round-trip logical text, hard breaks, selection, and
  search anchors.
- Primary-screen width and height shrink/growth fixtures cover cursor
  attachment, transfer between active rows and scrollback, live-bottom and
  locally scrolled viewports, and absence of duplicated or lost content.
- Alternate-screen width and height shrink/growth fixtures cover coordinate
  preservation, whole-grapheme and whole-wide-cell clipping, blank growth,
  active and saved cursor validity, full-grid margins, and primary-history
  isolation.
- Crossing the 10 MiB budget evicts the oldest valid content and keeps retained
  scrollback searchable and renderable.
- Malformed UTF-8 produces defined replacement behavior and does not desynchronize
  the escape parser.

## Non-goals

- Bidirectional or RTL layout.
- Perfect presentation of every emoji sequence supported by future macOS
  releases.
- Ligatures.
- Configurable ambiguous-width or scrollback policies in the initial engine.

## Implementation discretion

- The compact storage representation and eviction data structure.
- The generated Unicode table format and update tooling.
