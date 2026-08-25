# A pane's viewport as cells over the CLI

## Problem

Nothing tells an agent what text sits at which column of a pane. `pane read`
joins soft-wrapped rows and carries no columns at all; `pane rows` carries
per-row structure -- width, content end, margin kind -- but no content. A
character index is not a column, because a wide glyph owns two, so counting
characters in `pane read` output gives the wrong column on any row holding CJK
or an emoji.

Every question of the form "did the program draw what I expected, and where"
is therefore unanswerable without a human looking at the screen: rendering and
reflow defects, alignment after a resize, and -- the case that raised this --
locating the text a pointer gesture should aim at.

AGENTS.md holds that DanTerm is fully controllable programmatically, and that a
missing capability is closed by a general, reusable command.

Outcome: an agent can ask what is on screen and where, and act on the answer.

`plans/wip/pane-pointer-cli.md` is the deferred dependent: it points at cells
this readout names, and waits for a concrete need.

## Decision

**D1. `danterm pane cells --pane <id>`** reports the pane's current viewport as
cells: the grid dimensions, and one record per viewport row carrying its
zero-based row index and the spans of that row.

Each span starts at a column and uses one of these column-width rules:

- A narrow span carries consecutive graphemes that each own one column. A
  printed space is one such grapheme. Interior padding is carried as synthetic
  space graphemes so text on either side keeps its visible distance.
- A wide span carries consecutive terminal-authored graphemes that each own two
  columns. Each glyph represents its `wideHead`; its following `wideTail` is
  implicit and is never a separate span or glyph.
- A spacer span carries no text and reserves each column occupied by a
  `spacerHead` at a wide-wrap boundary.

Leading and trailing padding are omitted. All other transitions between these
rules start a new span. A text span carries its graphemes as one unnormalized
string plus one zero-based UTF-8 byte offset per grapheme, including offset 0.
The offset is measured in the decoded span text, not its JSON escape spelling.
For offset entry *i*, the glyph starts at `column + i * cellWidth`; a spacer
span carries neither text nor offsets. The documented JSON shape preserves
these fields, the span kind, its start column, and its cell width.

**D2. Rows are viewport-relative and the reply gives the matching `pane rows`
origin.** Row indices count from the top of the current viewport. The reported
origin is the exact `index` that `pane rows` would assign to viewport row 0 for
the same terminal state. On the primary screen it is the current-retained row
index and rebases when older history is evicted. On the alternate screen it is
the retained primary row count, because `pane rows` prefixes those rows before
the alternate grid even though the alternate viewport itself starts at row 0.
Adding a viewport row to this origin therefore names the corresponding `pane
rows` record in either screen mode.

**D3. The readout is faithful to the grid, not to the text.** A glyph that
owns two columns is reported at the column it starts in, and the next span
begins after both. What the readout says occupies a column is what the renderer
draws there.

`integrations/danterm/SKILL.md` documents the complete JSON shape and is
updated in the same change. Its command-choice guidance distinguishes the
three pane projections: use `pane read` for logical text, `pane rows` for
whole-stream wrap and reflow structure, and `pane cells` for visible text at
viewport row and column coordinates.

## Invariants

- **I1.** Every column holding printed content is reported exactly once, at the
  column the renderer draws it in, wide glyphs included.
- **I2.** Row indices address the current viewport, and the reported `pane rows`
  origin converts between the two bases.
- **I3.** The readout changes nothing it reads.

## Proof obligations

- Reconstruct each occupied viewport column from the projection and compare it
  with the engine's renderer-facing viewport traversal using only the
  serialized span text, UTF-8 grapheme offsets, start column, and cell width.
  Cover narrow text, combining graphemes followed by more text, wide glyphs
  and their implicit tails, printed spaces, interior padding, soft wraps, and
  spacer cells (I1).
- The origin converts every viewport row to the matching `pane rows` record on
  a scrolled primary screen, after retained-history eviction has rebased the
  indices, and on an alternate screen with retained primary history (I2).
- Reading a pane twice with no output in between returns the same result, and
  leaves selection, scroll position, and terminal state untouched (I3).

## Non-goals

- Cells outside the current viewport. `pane read` and `pane rows` already serve
  whole-stream questions, and a readout of retained scrollback answers a
  question no on-screen check asks.
- Style, color, and link metadata. Locating a cell needs its text and its
  width; every field beyond that is a second contract to keep.
- Driving pointer gestures and reading selection state, which
  `plans/wip/pane-pointer-cli.md` holds. That plan depends on this one and is
  deferred until a concrete need appears.

## Rejected ideas

- **RI1. A column-aligned format on `pane read`.** No new verb, but it
  overloads a reader whose whole contract is joining soft-wrapped lines into
  logical ones, which is the opposite of a per-display-row cell view.
- **RI2. One record per cell.** Unambiguous and needs no span rule, but a
  normal screen becomes some two thousand objects, and the common case -- a row
  of ordinary text -- is the one it punishes most.
- **RI3. Breaking a span at every blank.** Smaller spans and no interior
  padding to reason about, but a row's text stops being greppable: a search for
  a phrase that contains a space matches nothing.

## Critical files

- `lib/DanTermProtocol` -- the request and the generated command synopsis.
- `lib/DanTermCore` -- request dispatch to the pane read.
- `app/`, `lib/TerminalPTY`, and `lib/TerminalCore` -- the viewport cell
  projection.
- `integrations/danterm/SKILL.md` -- the CLI contract and guidance for choosing
  among `pane read`, `pane rows`, and `pane cells`, updated in the same change.

## Commit progress

- [x] 1. feat(cli): report a pane's viewport as cells
