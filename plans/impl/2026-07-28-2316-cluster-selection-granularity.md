# Cluster selection granularity (triple-click selects a whitespace-delimited token)

## Problem

There is no selection granularity between "word" and "whole logical line", so
the single most common terminal copy target -- a path, URL, hash, or flag --
cannot be selected in one gesture.

Evidence, both in `lib/TerminalCore/Sources/TerminalCore/`:

- `Terminal.wordClass(of:)` (`Terminal.swift:2477`) buckets cells into three
  classes: whitespace, alphanumeric/`_`/non-ASCII, and everything else. Word
  expansion requires the class to match, so `/`, `-`, and `.` all terminate a
  word. Double-clicking `docs/research/13-live-app-compositing-...md` yields
  `compositing`.
- `Terminal.logicalLineRange(at:)` (`Terminal.swift:1806`) starts the range at
  `column: 0` unconditionally. Triple-clicking that same path yields the whole
  row, including Claude Code's leading `⏺ ` output glyph.

Load-bearing premises:

- Projection units are already contiguous across soft-wrapped rows.
  `forEachProjectionUnit` (`Terminal.swift:2333`) emits its synthetic
  hard-boundary unit only when `row.isSoftWrapped == false`, so a scan over the
  unit array walks from the end of a wrapped row into the next row with nothing
  in between. Wrapped-path continuation therefore needs no new row-walking
  logic.
- Trailing blank cells past a hard line's last real character are absent from
  the text projection (`projectedCellEnd` -> `retainedContentEnd`,
  `Terminal.swift:2381`), and a click there resolves to the nearest preceding
  projected unit (`nearestTextUnitIndex`, `Terminal.swift:2453`). This is
  existing behavior that word granularity already exhibits.

## Desired outcome

Triple-click on the path above selects exactly
`docs/research/13-live-app-compositing-and-draw-hotspots.md` -- no glyph, no
leading space. The whole line remains selectable at one additional click.

## Decision

Insert a `cluster` granularity between `word` and `line`, so click count maps
1 = character, 2 = word, 3 = cluster, 4+ = line.

Cluster is a **purely whitespace-delimited run** over the same text projection
word selection already walks. This deliberately makes it mechanical rather
than semantic: no path/URL recognition, no trailing punctuation heuristics.

The change is confined to `lib/TerminalCore` -- the range query on `Terminal`
and the pointer policy that maps click count to granularity. No other
production file changes: `clickCount` already flows unclamped from `NSEvent`
through the session view and reaches the policy untouched, and nothing
downstream reads it.

## Invariants

- **I1** -- Cluster selection is the maximal run of adjacent non-whitespace
  cells, among those the text projection retains, containing the clicked cell.
- **I2** -- A cluster spans soft-wrapped rows and never crosses a hard line
  ending, so a wrapped path selects whole and a cluster never absorbs text
  from the following command.
- **I3** -- Clicking projected whitespace -- the gaps between tokens -- selects
  the whitespace run. Past a hard line's retained content no whitespace is
  projected, and clicking there selects the nearest preceding cluster, matching
  what word granularity already does in that region.
- **I4** -- Line selection is behaviorally unchanged, including its
  unconditional start at column 0; it is simply reached at 4 clicks instead of
  3, and every count above 4 still means line.
- **I5** -- Dragging after a cluster-granularity press extends the selection
  by whole clusters.
- **I6** -- Click count does not affect bytes reported to the PTY, so a
  four-click gesture is indistinguishable from four single clicks to an
  application that has captured the mouse.

## Proof obligations

- **PO1** (I1) -- A cluster query against a line carrying a leading glyph, a
  space, and a punctuated path returns the path alone. Assert on selected
  text, since that is the user-visible claim.
- **PO2** (I2) -- A cluster spanning a soft wrap selects whole; a cluster at
  the end of a hard-terminated line stops there rather than joining the next
  line's first token.
- **PO3** (I3) -- Both regions: a query on whitespace embedded between two
  tokens returns the whitespace run, and a query past a hard line's last real
  character returns that line's final cluster.
- **PO4** (I4) -- The click-count map: 3 selects a cluster, 4 and some higher
  count both select the line. The existing `selectionGranularity` policy test
  encodes the old 3-means-line mapping in two places and must be updated
  rather than deleted.
- **PO5** (I5) -- A cluster-granularity press followed by a move produces the
  union of the two clusters.
- **PO6** (I6) -- Under captured mouse, a press with click count 4 and a press
  with click count 1 produce identical, non-empty reported bytes and no
  selection change. The existing captured-mouse recording test does not
  discharge this: replay discards reported bytes and compares only terminal
  state, so it cannot detect a fourth click whose report is altered or
  suppressed.

## Non-goals

- Smart/semantic selection (recognizing paths, URLs, or quoted strings and
  selecting the matched token). The existing URL scanner in `detectedLink` is
  anchored on an `http(s)://` prefix and uses a URL-specific character class
  that excludes quotes and brackets; it is not a whitespace-run helper and is
  not being generalized here.
- Trimming trailing punctuation from a cluster. `file.md` ends in meaningful
  punctuation as often as a sentence-final URL does not.
- Any change to where line selection starts. Including the leading glyph
  matches Ghostty (`.ghostty-src/src/terminal/Screen.zig:2515`) and every other
  terminal.
- A user-facing preference for the ordering. `TerminalCore` is deliberately
  config-free and `DanTermConfig` is internal to the sibling `DanTermCore`
  module, so a knob costs the full `alert-clear-mode` treatment. Adding one
  later is purely additive.

## Accepted risks

- **AR1** -- Line selection now costs a fourth click, which some users cannot
  reliably produce within macOS's double-click interval, and which breaks
  near-universal triple-click-selects-line muscle memory. Accepted because
  cluster is the more frequent target in agent-driven output, line remains
  reachable, and the failure mode is benign: you get a token, you click again,
  you get the line.

## Implementation discretion

- Whether the cluster scan covers the full stream, as word selection already
  does, or is windowed to bounded rows for cost.

## Verification

- `swift test --package-path lib/TerminalCore` for the new and re-pinned
  suites.
- `just test` for the full local gate.
- `just build-run`, then in a pane: print a line with a leading non-ASCII
  glyph followed by a space and a punctuated path (the case in the problem
  statement), and confirm 2/3/4 clicks yield word, path, and whole line
  respectively. Repeat with a path long enough to soft-wrap.
