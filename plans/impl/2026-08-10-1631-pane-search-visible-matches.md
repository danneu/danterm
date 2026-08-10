# Pane search highlights every visible match

## Problem

Cmd-F in a pane highlights only the selected match. Every other occurrence on
screen is invisible, so the user cannot see what they are stepping through.

This is not a paint bug. The engine models search as one selected occurrence
plus a whole-history match list kept only for the counter, and the renderer is
handed a single range. There is no representation for "the other matches", so
there is nothing to draw.

Two costs fall out of the same split:

- The whole-history match list is dropped on **every cell write**, so a pane
  with output flowing rescans all of history -- up to the 16 MiB scrollback cap
  -- on each navigation keypress. This is the coupling
  `agent-docs/perf-granularity-mismatch.md` describes: the cache is the
  workaround, and no tuning of it removes the coupling.
- A selected match whose cells are overwritten is retired to "matches exist,
  none selected", and a reattach path exists purely to climb back out.

## Decision

Matching becomes one pure function of `(needle, row range)`, and a search
session holds one **ordered index of every occurrence** built from it. All
three consumers read that single sequence, so they cannot disagree:

- **Rendering** takes the viewport slice. The planner receives the *set* of
  visible matches; "selected" becomes a predicate over that set rather than a
  separate channel.
- **Navigation** takes the indexed predecessor or successor, wrapping at the
  ends. It never walks the distance between two sparse matches.
- **The counter** takes its total from the sequence length and its ordinal from
  the selected position within it.

The index survives output because retained history's middle is immutable: only
the head record and the tail record are writable. So the index splits into a
built prefix over closed history and a suffix rescanned each time it is read --
the open tail plus the live grid. Head eviction drops a prefix of the sequence,
tail truncation drops a suffix, and a needle change rebuilds. Nothing else
invalidates it. This is what replaces the whole-history cache that today is
dropped on every cell write.

Rescanning the suffix at read is what keeps this free of a maintenance hook on
every content mutation, and it is bounded work: the store force-splits the open
tail at a fixed fraction of the byte budget, so no amount of output makes the
suffix grow with scrollback depth.

Search state becomes a needle plus a **position**, not a needle plus a range.
The position resolves to the *nearest* match, ties to the later one. An
overwritten occurrence then resolves to its neighbour on the next read instead
of vanishing, which deletes the retire-and-reattach pair outright. Nearest
rather than at-or-after is load-bearing: at-or-after would let a `\r`-redrawn
progress line silently move the selection far down the stream.

Overlay damage stays in the terminal. A change to the needle or the selected
position damages the whole viewport, which is affordable because search
mutations are keystroke-paced, and it is the simplest structure in which "a
row's match set changed and nobody damaged it" cannot happen. Content damage
is widened by the needle's row span while a search is open, because a write to
one row can complete or destroy a match that starts on an undamaged row above
it.

A non-selected match is drawn as a quieter sibling of the selected one: a
fourth rung on the existing overlay fill ladder
(`lib/TerminalCore/Sources/TerminalRenderPlanning/RenderColorResolution.swift`),
brightness-separated from the cell background, the selection fill, and the
selected-match fill.

Match computation stays in `TerminalCore` and the planner consumes ranges.
Folding matching into the planner's row traversal is rejected under RI2.

### Net shape

Removed: the whole-history match cache and its invalidation on every cell
write, the reattach-to-newest path, the clearing of a selected occurrence on
overwrite, the single-range render input, the per-match-row damage branch and
its field in the per-action damage snapshot, and the split search anchors the
width-reflow path carries.

Added: the row-range scan primitive, the ordered match index over it, and two
overlay states with their ladder rung.

Search status also has to reach the pane. Today it is published only when the
user issues a search command, so a tailing pane keeps showing a stale count
while output arrives. Status joins the regular coalesced terminal update.

Critical files: `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`,
`LogicalLineStore.swift`,
`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`,
`lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift`,
`RenderColorResolution.swift`, `TerminalRenderPlanning.swift`.

## Invariants

- **I1.** Every match intersecting the viewport is highlighted, including one
  whose start lies above the top edge or whose tail runs past the bottom.
- **I2.** Whenever at least one match exists, exactly one highlighted match is
  the selected one, and it is visually distinct from the rest. A needle with no
  matches keeps the search open and reports the existing empty state.
- **I3.** Selection, selected match, and non-selected match stay pairwise
  distinguishable over every bundled theme and any cell background.
- **I4.** The windowed scan yields exactly the whole-stream scan restricted to
  that window -- same unit projection, same line boundaries, same seam
  handling.
- **I5.** Per-frame highlight cost is independent of scrollback depth, and
  planning a frame never projects the whole stream.
- **I6.** Opening or editing a needle may scan all of history. Navigating an
  unchanged needle may not cost time proportional to scrollback depth, whether
  or not output is arriving.
- **I7.** Overwriting or evicting the selected match leaves the search open,
  and selected on a surviving occurrence when one exists. The occurrence chosen
  is the nearest surviving one, resolving a tie toward the later. There is no
  state that only retyping the needle can leave.
- **I8.** The viewport moves only for navigation the user asked for. A
  selection that changes because content moved under it never scrolls the pane.
- **I9.** Every row whose highlight changed is damaged in the frame that
  changes it.
- **I10.** The counter the user sees reports the total and selected ordinal a
  full rescan would produce, across output, eviction, and resize. Reaching the
  engine is not enough: matching output updates the mounted overlay with no
  search command issued.
- **I11.** Search reads no state under the alternate screen, as today.

## Proof obligations

- **PO1.** I1 -- a viewport holding several matches plans a highlight for each,
  including matches crossing the top edge, the bottom edge, and a soft wrap.
- **PO2.** I2 -- the selected match plans a different overlay state from its
  neighbours, and navigation moves that distinction without changing the set.
- **PO3.** I3 -- extend the existing overlay contrast property tests to the new
  state and its combination with selection.
- **PO4.** I4 -- property test: windowed matches equal whole-stream matches
  restricted to the window, over a corpus including blank trailing rows, soft
  wraps, the history/live seam, and an unterminated soft-wrapped line straddling
  the index's prefix/suffix boundary.
- **PO5.** I5 -- the whole-projection counter does not advance while frames are
  planned with a search open. Existing tests already assert on that counter, so
  a per-frame whole-stream projection would surface there.
- **PO6.** I6 -- navigation cost over a fixed sparse match set does not grow
  with scrollback depth. A single-depth latency probe cannot show this, so the
  proof compares at least two depths, quiet and streaming.
- **PO7.** I7 -- output that overwrites the selected match, and eviction that
  drops it, both leave the search navigable with a highlight. With surviving
  matches on both sides of the overwritten position, the selected occurrence is
  the nearer one, and the later one when the two are equidistant. Replaces the
  existing assertions that these clear the selected match.
- **PO8.** I8 -- an overwrite that re-resolves the selection, including the
  both-sides cases of PO7, leaves the viewport top unchanged.
- **PO9.** I9 -- a frame whose only change is a search mutation repaints the
  pixels of every row holding a match; a write that completes a match starting
  on the row above repaints that row too.
- **PO10.** I10 -- the index's complete ordered range sequence and its resolved
  selection both equal what a full rescan produces, after output, after head
  eviction, after the open tail closes and reopens, after tail truncation,
  after a live overwrite, and after resize, including matches that straddle
  each of those boundaries. Comparing only the total is not enough: one action
  can destroy a match on one row and create one on another, leaving the count
  right and every highlight wrong. Separately,
  a behavioral test at the host/session seam: matching output arrives, the
  mounted overlay's count updates, no search command is issued.
- **PO11.** I11 -- alt screen plans no highlights and reports no status.

## Non-goals

- No CLI or IPC surface for search; it stays menu- and overlay-driven.
- No change to needle syntax: literal, canonical-caseless, no regex.
- No scrollbar or minimap match markers.
- Selection and link-hover damage are not restructured. They are single-range
  and correct today.

## Accepted risks

- **AR1.** The match index is the one new stateful mechanism, and its
  correctness rests on the retained store's immutable middle: the head record
  and the tail record are the only writable bytes, so every mutation the store
  admits maps to dropping a prefix, dropping a suffix, or rescanning the tail.
  Every consumer reads the index, so a wrong index means wrong highlights and
  wrong navigation, not merely a stale count -- which is why PO10's oracle is
  the whole sequence. A needle change rebuilds from scratch, so no error
  outlives the current needle.
- **AR3.** Reading the index rescans the mutable suffix rather than maintaining
  it at each content mutation. The forced split bounds that suffix
  independently of scrollback depth, so I5 and I6 hold; a single logical line
  near the cap still costs a bounded rescan per frame. Maintenance hooks are
  the fallback if measurement shows it matters, not the opening design.
- **AR2.** The scroll-shift row-translation path is refused whenever a search
  is open, rather than only when a match is selected. Costs a full replan while
  scrolling with the find bar up; a transient state.

## Rejected ideas

- **RI1.** Moving overlay damage into the frame planner, letting it replan rows
  whose overlay inputs changed. The damage set is not a planning hint -- it
  drives the pixel erase in `TerminalFrameBackingStore`, and the pane session
  skips planning entirely when damage is empty. A planner-only replan is
  clipped back out and never drawn, and the reuse tests compare plan to plan so
  none of them would catch it.
- **RI2.** Folding the match scan into the planner's existing row traversal.
  That traversal exposes no soft-wrap flag, visits synthesized padding columns,
  and skips reused rows -- so a match spanning a reused row would be lost. It
  would also move grapheme-break and caseless-folding semantics out of
  `TerminalCore`.
- **RI3.** Dropping the selected ordinal from the counter. Cheaper, but "3 of
  17" is the counter's job, and the index gives the ordinal as a position in a
  sequence the plan already keeps.
- **RI4.** A per-history-row match count table or Fenwick tree. The index
  answers both the total and the ordinal directly; a summing structure over it
  buys nothing.
- **RI5.** Directional scanning for navigation, with the total kept as
  separately maintained integers. Rejected on I6: with matches sparse in deep
  scrollback, stepping past the last one scans to the end of the stream before
  wrapping, at a cost that grows with scrollback depth. It also gives
  highlights, navigation, and the counter three derived representations of the
  same fact.

## Implementation discretion

- How the index represents positions and where the prefix/suffix boundary is
  drawn, given I6 and I10.
- How far the scan reaches past each viewport edge, given I1 and I5.

## Commit progress

- [x] 1. Replace search rescans with a position-based ordered match index
- [x] 2. Render every visible match with distinct selected and unselected overlays
- [ ] 3. Publish live search status with regular coalesced terminal updates

## Implementation notes

- The immutable prefix ends before the store's open tail record. A forced split
  becomes prefix data once its record closes; the open record and live grid remain
  the suffix. Closed-prefix matches ending in trailing blank rows remain dormant
  candidates until later content makes those hard boundaries part of the text
  projection.
- A row-window scan reads up to `max(1, needle grapheme count - 1)` context rows
  on each side, because a one-unit hard boundary starts on the preceding row.
  Selection distance uses row-major cell coordinates and resolves equal
  distances toward the later match.
- A non-selected match keeps the same quiet fill when local selection overlaps
  it. Selection still changes the glyph source, while the stable fill preserves
  selected-versus-unselected match identity and keeps the brightness ladder
  total over every cell background.
