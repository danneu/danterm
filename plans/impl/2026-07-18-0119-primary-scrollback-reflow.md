# Primary-screen scrollback and resize reflow (Milestone 2, slice 4)

Fourth implementation slice of [14-roadmap.md](../../plan-terminal-engine/14-roadmap.md)
Milestone 2, governed by
[05-unicode-grid-scrollback.md](../../plan-terminal-engine/05-unicode-grid-scrollback.md)
(one-stream primary reflow, hard/soft line identity, cursor attachment),
[06-inspection-recovery.md](../../plan-terminal-engine/06-inspection-recovery.md)
(logical-line vs visual-row projection), and the neutral-fixture mandate in
[docs/research/1-external-tests.md](../../docs/research/1-external-tests.md).
Sequenced after slice 3 because reflow moves the final indivisible cell unit,
which now exists. Phase A delivers retention, projection, and the replay seam;
phase B delivers resize itself. Alternate-screen resize and the 10 MiB
eviction contract stay deferred: inspection confirmed they are separable (no
alternate screen exists yet, and eviction lands later at the single
scroll-off seam this slice creates).

## Problem

The engine's grid holds only the viewport. Rows that scroll off the top are
discarded at the single scroll-off point, dimensions are fixed at
construction with no resize entry point, and screen text ignores soft-wrap
identity, so logical lines are not observable at all. Milestone 2's remaining
exit criteria -- hard/soft line identity, primary-screen resize reflow that
preserves logical content and cursor attachment, and structure-insensitive
replay that adopts external fixtures early enough to shape the public
contract -- have neither implementation nor test seam.

Load-bearing evidence (verified):

- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`: viewport-only row
  storage whose per-row soft-wrap flag is the sole line-continuation state;
  immutable dimensions; scroll-off discard isolated in one advance-to-next-row
  path (the seam scrollback capture and, later, eviction land on);
  cluster/wide atomicity already centralized in the cell-kind markers and the
  pair-clearing discipline; whole-value equality already backs the
  chunk-invariance harness.
- Ghostty reference: `.ghostty-src/src/terminal/PageList.zig`
  `resize`/`resizeCols`/`ReflowCursor.reflowRow` (~940/1006/1211) and
  `Screen.zig` `resize` (~1642) -- scrollback and active rows reflow as one
  row stream with per-row wrap flags; the cursor survives via a tracked pin
  plus rows-below-cursor accounting; trailing-blank trimming is gated on
  codepoint-0 emptiness (`page.zig` `Cell.isEmpty`), so written spaces are
  never trimmed; wide cells never split across the wrap boundary.
- All five upstream libvterm files fetched and classified case-by-case:
  `t/16state_resize.test`, `t/32state_flow.test`, `t/63screen_resize.test`,
  `t/69screen_pushline.test`, `t/69screen_reflow.test`
  (github.com/neovim/libvterm, branch nvim, MIT; archived repo, cloned at
  `references/libvterm`, whose checked-out commit the manifest pins). Note libvterm marks the continuation row while DanTerm's
  flag marks continues-into-next -- same boundary, mechanical translation.
- `fixtures/terminal-characterization/ghostty-inspection-recovery.json`
  carries narrow/wide/narrowAfterReflow captures from live Ghostty with no
  loader yet; its expectation vocabulary is a subset of the seam's
  (conversion left open).

## Decision

Implement primary-screen scrollback retention, the 06 full-history text
projection, a DanTerm-owned neutral byte-replay fixture seam, and
primary-screen resize -- height transfer plus width reflow with cursor
re-attachment -- as one slice, phase A before phase B.

- **Visual-row storage, logical lines derived.** Scrollback is an ordered
  collection of the same row shape the viewport uses (cells plus soft-wrap
  flag), conceptually above it. Scrollback rows (oldest to newest) followed
  by viewport rows (top to bottom) form one visual-row stream at the current
  width; a logical line is a maximal run whose every non-final row is
  soft-wrapped, and the scrollback/viewport boundary may fall inside one.
  Logical lines are reconstructed transiently during reflow and projection,
  never stored. All retained rows always have exactly the current column
  count -- reflow rewrites scrollback too (unlike libvterm, whose
  callback-owned scrollback keeps its old width). Phase A adds no new
  per-row state.
- **Minimal public surface growth.** Four additions, nothing else:
  `resize(columns:rows:)`; a scrollback row count; indexed scrollback row
  access exposing exact cells and soft-wrap identity (index 0 oldest); and a
  full-history text projection implementing 06 over the whole stream -- soft
  wraps join with no separator, each hard boundary contributes exactly one
  newline, right-hand padding and trailing padding-only rows are omitted,
  written spaces and empty logical lines are preserved, no final newline is
  synthesized. Existing viewport-only `screenText`/`geometry` are unchanged.
- **Resize call semantics.** Validity matches construction (at least 2
  columns, 1 row); an invalid or same-dimensions request is a bit-identical
  no-op -- nothing changes, in-flight parser state and any open cluster
  included. A combined width+height change behaves exactly as height change
  then width change (D1). Resize never touches in-flight stream state: a
  partial escape or UTF-8 sequence spanning a resize continues and its
  parameters clamp against the new dimensions at dispatch. An effective
  resize closes an open grapheme cluster; a mark fed afterward starts a
  fresh cluster (D3).
- **Written spaces are content; padding is not.** The binding reading of
  05's "including explicit blank cells": a written space is a narrow content
  cell and is never trimmed; never-written or erased padding is not logical
  content. Reflow trims only trailing padding on non-soft-wrapped rows --
  every cell of a soft-wrapped row is content -- and interior padding is
  always preserved. Blank rows at or above the last content-or-cursor row
  are retained as empty hard lines; trailing blank rows below it are
  re-derived by the viewport rule. Consistent with the reference's
  codepoint-0 emptiness gate, so no contract conflict exists.
- **Cursor attachment across a width change** is by anchor kind, captured at
  resize time:
  - Cell anchor (pending wrap clear, cursor over a cell reflow retains --
    written content, or padding preserved because it is interior or on a
    soft-wrapped row): the cursor lands on that cell's new position; a tail
    follows its pair; a last-column spacer follows the wide head it deferred.
  - Trailing-padding anchor (cursor over trimmable padding past the row's
    retained content): the distance past that content is preserved, clamped
    to the visual row where the content now ends -- trailing padding never
    manufactures extra soft-wrapped rows. On an all-padding row the cursor
    keeps its column, clamped to the new width.
  - Boundary anchor (pending wrap set): the anchor is the boundary after the
    row's final cell. If that boundary becomes interior to a visual row at
    the new width, the cursor lands on the following column with pending
    wrap cleared; if it again falls at a row end, the cursor sits at the
    last column with pending wrap set.
- **Viewport derivation after a width change.** Never-written blank rows are
  appended at the bottom of the stream only until the cursor's distance from
  the bottom row equals its pre-resize distance reduced by the net increase
  in soft-wrap continuation rows at or above the cursor within the viewport
  (floored at zero); the viewport is then the bottom rows of the stream and
  scrollback is everything above. This is Ghostty's cursor-preservation
  formula stated behaviorally (AR4). Emergent behavior it pins: post-clear
  width shrink does not slurp history under the cursor; a line wrapping down
  does not push its own head into scrollback; bottom-cursor width growth
  unwraps lines and pulls history back into freed rows; viewport overflow on
  shrink displaces top rows into scrollback.
- **Height transfer at the live bottom.** Height-only changes never alter
  any row's cells or wrap flag; they only move rows across the
  scrollback/viewport boundary and create never-written blanks. Shrink first
  trims trailing all-padding viewport rows strictly below the cursor row
  (the cursor row is never trimmed, even when blank), then pushes the
  remaining need from the top of the viewport into scrollback in order,
  flags intact. Growth pulls back the newest retained rows only when the
  cursor is on the bottom viewport row -- the binding definition of 05's
  "eligible" -- and appends never-written blanks for any remainder. Blank
  rows displaced off the top -- by LF scroll or by shrink -- are retained as
  empty hard lines like any other row (the adopted 63screen must-scroll case
  pushes four blank rows); the filler growth appends is exactly what
  shrink's trailing-trim later removes, so grow/shrink round-trips do not
  accrete blank lines into history. A cursor whose row is displaced by shrink
  clamps to the top viewport row preserving column and pending wrap (D2).
- **Unbounded scrollback within this slice** (AR1). A placeholder cap would
  create observable eviction semantics that the Milestone 6 10 MiB contract
  redefines; unbounded keeps every fixture a pure statement about reflow and
  makes conservation exact. The scroll-off push is the single reserved seam
  where the budget later lands.
- **Neutral byte-replay fixture seam.** Versioned JSON fixture files shipped
  as test-target resources with a Swift runner (Foundation enters the test
  target only; the library stays import-free). A fixture records provenance
  (source, URL, pinned commit, upstream case, license, recorded deviations),
  initial dimensions, and an ordered event list: feed (text or hex for
  malformed bytes), resize, and expect. Expect payloads assert only public
  inspection views -- viewport text, cell kinds, soft-wrap flags, cursor
  including pending wrap, scrollback count and rows, full-history text.
  Every fixture runs in three modes -- as-authored chunks, byte-at-a-time,
  and exhaustive feed-split points under a size threshold (sampled above
  it) -- with splits only inside feed segments; every mode must pass every
  expect at its position and final terminal values must compare equal across
  modes. A manifest records a disposition -- adopted, adapted, superseded,
  or out of scope -- for every case of the five libvterm files, with
  rationale and the pinned commit. The complete upstream copyright and
  permission notice ships alongside the fixture resources, and manifest
  entries reference it -- a bare license identifier does not satisfy MIT
  attribution.
- **libvterm dispositions** (headline adaptations; the manifest holds the
  full table):
  - 16state_resize: grow cases adopted (including the cursor-past-content
    case the padding anchor reproduces); shrink adapted because the upstream
    state layer does not reflow and DanTerm always does; "grow doesn't
    cancel phantom" adopted verbatim; the putglyph placement case superseded
    by slices 1-2.
  - 32state_flow: continuation-marking cases adopted via the flag-offset
    translation; the EL case adapted to CUP positioning because reverse
    index is unimplemented.
  - 63screen_resize: the primary width/height cases adopted with
    callback-order assertions translated to scrollback views; "taller
    attempts to pop scrollback" adapted (cursor not at bottom, so no pull)
    plus a native cursor-at-bottom variant that does pull; the altscreen
    case out of scope.
  - 69screen_pushline: collapsed into one adapted fixture pinning scrollback
    content and soft-wrap identity; callback-timing assertions are libvterm
    architecture, out of scope.
  - 69screen_reflow: wider/narrower reflow cases adopted; "Shell wrapped
    prompt behaviour" adopted at its early width steps and adapted at the
    final one, where one-stream reflow pulls the first prompt back from
    scrollback (libvterm cannot reflow callback-owned scrollback); "Cursor
    goes missing" adapted -- its sub-minimum geometries become the
    invalid-resize no-op pin, with the crash-regression intent covered by
    native 2-column cases.
- **Recorded deviations from Ghostty** (future differential traces carve
  these out by name): D1 combined resize is canonically height-then-width;
  Ghostty orders by column-change direction. D2 a shrink-displaced cursor
  clamps to the top row preserving column and pending wrap; Ghostty resets
  to top-left. D3 resize closes an open grapheme cluster; Ghostty's
  content-derived identity can rejoin across resize (extends slice 3 D3).
  D4 no semantic-prompt handling on resize until protocols land. D5 reflow
  is unconditional on width change; Ghostty gates it on DECAWM. D6 the
  2-column minimum stands and sub-minimum resize is a no-op; Ghostty
  supports 1-column grids by destroying wide cells.

## Invariants

- I1. Retention: a visual row that scrolls or is displaced off the top of
  the viewport is retained in scrollback with exact cell content -- kinds and scalars,
  written spaces included -- and its soft-wrap identity; nothing else enters
  scrollback; within this slice nothing leaves it; no row is in both regions.
- I2. One stream: scrollback rows (oldest to newest) followed by viewport
  rows (top to bottom) form one ordered visual-row sequence at the current
  width, partitioned into logical lines by the soft-wrap flags; the region
  boundary may fall inside a logical line.
- I3. Projection: full-history text implements the 06 projection over that
  sequence -- soft wraps join with no separator, hard boundaries contribute
  exactly one newline each, right-hand padding and trailing padding-only
  rows are omitted, written spaces and empty logical lines are preserved, no
  final newline is synthesized.
- I4. Conservation before budget enforcement: reflow itself leaves full-history
  text bit-identical -- same logical text, same hard-boundary positions. A width
  change may still evict the oldest rows when splitting lines increases fixed
  per-row overhead beyond the configured scrollback budget.
- I5. Reflow legality: after any resize, every retained row has the current
  column count logically; physical history storage may omit default trailing
  padding. A row is soft-wrapped iff its logical line continues
  on the next row; every non-final row of a logical line is exactly full at
  the current width (a trailing spacer head counts as full); wide pairs and
  grapheme clusters never split across rows; the slice 1-3 grid-validity
  invariants hold over viewport and scrollback alike.
- I6. Cursor attachment (width): a width change re-attaches the cursor by
  the anchor rules -- a retained cell (written or preserved padding) to its
  new position (tail to tail, spacer to the following head), trailing
  padding to its preserved distance past content clamped within the
  content-end row, boundary anchor to the following
  column with pending wrap cleared when interior or to the last column with
  pending wrap set when again at a row end.
- I7. Viewport derivation (width): after a width change the viewport is the
  bottom rows of the stream, extended by never-written blanks only per the
  distance-from-bottom rule; content never duplicates, leaves the viewport
  only into scrollback at the top, and enters only from scrollback at the
  top or as never-written blanks at the bottom.
- I8. Height transfer: a height-only change alters no row's cells or wrap
  flag; shrink trims trailing all-padding rows strictly below the cursor
  first, then displaces top rows into scrollback in order; growth pulls back
  the newest retained rows only with the cursor on the bottom row, then
  appends never-written blanks; the cursor follows its row when retained and
  clamps to the top row preserving column and pending wrap when displaced.
- I9. No-op safety: resize to identical or invalid dimensions leaves the
  terminal value bit-identical, in-flight escape/UTF-8 state and any open
  cluster included.
- I10. Stream independence: in-flight escape and UTF-8 sequences spanning a
  resize continue undisturbed and clamp against post-resize dimensions at
  dispatch; an effective resize closes an open cluster; chunk invariance
  holds for all split points within feed segments interleaved with resize
  events.
- I11. Determinism: identical event sequences produce equal terminal values;
  no IO; scrollback participates in value equality.

## Proof obligations

- PO1 (I1, I2, I3). Native scrollback-capture tests plus the adapted
  69screen_pushline and 32state_flow fixtures: soft/hard identity in
  scrollback, written-space retention, blank-row transfer.
- PO2 (I3). Projection matrix: interior vs trailing blank rows, interior
  padding, spacer-head rows, wide/emoji content, empty logical lines, no
  synthesized newline.
- PO3 (I4). Repeated-resize round-trip properties over Spanish, Chinese,
  emoji, and written-space corpora: width walks down to 2 columns and back,
  height walks, combined resizes; full-history text exact throughout.
- PO4 (I5). Grid-validity sweep over both regions after every resize path;
  wrap-flag re-derivation; spacer heads appearing and disappearing
  round-trip across odd/even widths.
- PO5 (I6). Cursor matrix: cell anchors on narrow, wide-head, wide-tail,
  and spacer cells; cell anchors on interior padding between written cells
  and on padding in a soft-wrapped row; trailing-padding anchor at
  preserved distance with clamp; boundary anchor on growth (adopted phantom
  fixture) and landing at a row end on shrink; cursor after written spaces;
  cursor on an empty line.
- PO6 (I7). The viewport-derivation quartet: post-clear shrink (no slurp),
  single-line wrap-down (no self-push), bottom-cursor growth (history pulls
  back; adapted shell-prompt fixture), overflow shrink (top rows enter
  scrollback).
- PO7 (I8). The 63screen height cases plus the adapted taller case, the
  native eligibility-gated pull, flag preservation across the region
  boundary, blank rows displaced by shrink retained as empty hard lines
  (the adopted must-scroll case), a grow/shrink round-trip accreting no
  blank lines into history, and the displaced-cursor clamp with a nonzero
  column.
- PO8 (I9). No-op equality, including with pending wrap set and scrollback
  populated; same-size and invalid resizes interposed mid-UTF-8, mid-CSI,
  and mid-cluster, with continued feeding matching the uninterrupted run.
- PO9 (I10). Runner split modes over every fixture; a resize interposed
  mid-CSI; the open-cluster reset pin (a mark fed after an effective
  resize does not join).
- PO10 (I11). Cross-mode final equality on every fixture; the existing fuzz
  harnesses extended with interleaved random valid and invalid resizes -- no
  crash, sentinel visible, validity sweep green.
- PO11 (seam). Every fixture carries provenance and asserts only public
  views; the manifest covers every case of all five libvterm files with a
  disposition, the pinned commit, and the shipped-license reference.

Slice exit gate: `just test` green with the seam runner and fixtures wired
in, plus a checked slice 4 entry in the roadmap linking the promoted plan.
Left open for later slices: eviction and truncation marking at the
scroll-off seam; ED 3 scrollback erasure; DECAWM-off resize semantics; alternate-screen resize and
saved-cursor reflow; scrolled-viewport anchors and their reflow behavior
(08); converting the Ghostty characterization capture into seam fixtures;
compact scrollback storage; damage and output-byte expectations in the seam
schema.

## Non-goals

- Alternate screen in any form (none exists; Milestone 6).
- The 10 MiB budget, eviction, and truncation marking (Milestone 6).
- ED 3 scrollback erasure: `CSI 3 J` stays a deliberate no-op over retained
  history this slice; this slice repins the existing ED 3 test's rationale
  to that deferral, since its no-scrollback premise stops being true.
- Selection, search, and viewport anchors (08's stable-anchor contract; the
  one-stream model is the enabling structure, not the delivery).
- Scroll regions/margins and their resize interaction (no margins exist).
- DECAWM and any reflow-off mode (D5).
- OSC 133 semantic prompts (D4).
- Damage tracking and Alacritty reference recordings.
- Scrollback storage compaction and performance work (05 discretion).

## Accepted risks

- AR1. Scrollback is unbounded until the budget slice; exposure is
  test-only (the engine is not app-wired) and fuzz inputs are bounded.
- AR2. Reflow is a full rebuild of the retained stream per width change,
  linear in retained cells; acceptable pre-integration and optimizable
  later without observable change.
- AR3. Value equality and the exhaustive-split runner now scale with
  scrollback size; fixture sizes stay modest and the split threshold guards
  runtimes.
- AR4. The viewport-derivation rule is a behavioral reading of Ghostty's
  cursor-preservation arithmetic, not a published spec; Milestone 4-6
  differential traces may force refinement, carved out by name.
- AR5. Fixture schema v1 will need extension (modes, damage, output bytes);
  the format version field exists for that.

## Rejected ideas

- RI1. Logical-line-primary storage: rewrites every row/column-addressed
  mutation path (print, erase widening, pair discipline, cursor addressing)
  to serve the rarest operation; both references store visual rows, and
  hard/soft identity is fully preserved either way.
- RI2. Text-level rewrap (reconstructing lines as strings): loses cell
  identity -- padding vs written spaces, cluster scalars, future styles --
  and breaks cell anchoring; reflow must move cells.
- RI3. Swift-native fixture structs instead of files: fails the research
  doc's neutral, provenance-bearing, externally-reusable requirement.
- RI4. A placeholder scrollback cap: throwaway observable eviction
  semantics the 10 MiB contract redefines (AR1 instead).
- RI5. libvterm's unconditional pop-on-growth: resurfaces cleared content
  under the prompt after clear; the eligibility gate matches Ghostty and
  Terminal.app.
- RI6. Introducing logical-line IDs or anchors now for 08: nothing in this
  slice needs them and the stream model admits them later.

## Implementation discretion

- The scrollback container shape and whether rows are shared or copied
  between regions during transfer.
- Reflow algorithm internals (single pass vs staged) provided the
  invariants hold.
- Fixture schema field naming, file organization, and the split-sampling
  threshold.
- Consolidating the four duplicated grid-validity/run helpers while
  extending them (do not fork a fifth copy).
- Test-file placement and naming.
- Commit slicing and ordering, provided phase A (retention, projection,
  replay seam) lands before the phase B resize work that consumes it (each
  commit green; tests travel with the behavior they prove).

## Commit progress

- [x] 1. Retain primary scrollback and add the full-history replay seam
- [x] 2. Implement primary-screen resize reflow
