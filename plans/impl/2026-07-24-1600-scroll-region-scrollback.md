# Scroll-region scrollback: retain rows scrolled off a top-anchored region

## Problem

With codex running in a DanTerm pane on the Swift engine, mouse-wheel scroll
does nothing, while Ghostty scrolls the same session fine. Root cause: codex's
ratatui inline viewport pins its composer with a top-anchored DECSTBM scroll
region (`CSI 1;N r`) and scrolls transcript lines out the top via LF / `CSI S`,
expecting them to land in scrollback. Our engine only pushes to scrollback when
no scroll region is set at all (`pushesToScrollback: scrollRegion == nil` in
`advanceToNextRow` and `scrollUp`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`),
so every transcript line is discarded, history stays empty, and the (correctly
routed) local-viewport wheel has nothing to scroll into.

Ghostty/xterm/kitty semantics: rows scrolled off the top are retained whenever
the region is anchored at row 0 and full width, even with a bottom margin set
(`.ghostty-src/src/terminal/Terminal.zig:1466` and `:1677`). Our condition is
the deviation; converging on it fixes wheel scroll, selection/copy of scrolled
text, search, and export of codex-style sessions in one place.

## Decision

Adopt the Ghostty/xterm rule in the two upward-scroll paths (`advanceToNextRow`
and `scrollUp`): push to scrollback when the active scroll region starts at
row 0 and the primary screen is active, instead of requiring no region. DanTerm
implements no left/right margins (DECSLRM), so full width is trivially true.
No change to `scrollDown`, `insertLines`, `deleteLines`, or `reverseIndex` --
mid-screen shuffles still discard.

## Invariants

- I1: On the primary screen, a row scrolled off the top of a scroll region
  anchored at row 0 enters scrollback -- for both the linefeed-at-bottom-margin
  path (including soft wrap) and `CSI S`, with a partial-height region
  (bottom margin above the last row) as well as the full screen.
- I2: Rows below the bottom margin are untouched by such a scroll, and the
  retained stream (scrollback + viewport) stays in terminal-stream order.
- I3: A region NOT anchored at row 0 never pushes to scrollback, for LF and
  `CSI S` alike.
- I4: The alternate screen never pushes to scrollback, region or not.
- I5: Downward/mid-screen operations (`CSI T`, IL, DL, RI) never push to
  scrollback, even inside a top-anchored region.
- I6: Region-pushed rows participate in normal scrollback accounting: byte
  costs accrue and budget eviction applies exactly as for regionless pushes.
- I7: `CSI S` with an amount exceeding the region height pushes at most the
  region's rows (no over-push, no crash).
- I8: End to end, a codex-shaped byte stream (DECSTBM `1;N`, transcript lines
  scrolled out via LF at the bottom margin) yields usable history --
  `scrollbackRowCount > 0` after the stream -- and `decideTerminalWheel` on the
  primary screen routes `.localViewport` with a nonzero `localRowDelta`. The
  `scrollbackRowCount > 0` clause is the load-bearing proof (it is what the fix
  makes true); the wheel decision is a shared-behavior premise that already
  holds, included so the end-to-end path is exercised. `decideTerminalWheel`
  does not itself inspect the history range, so it cannot stand in for the
  history-growth assertion.

## Proof obligations

One behavioral test per invariant I1-I8 (a single test may discharge several;
I2 is the design-nuance case and gets its own scenario: region `0..<N` with
distinct content parked below the margin, asserting both the pushed row's text
in scrollback and the unchanged below-margin rows). Tests are TDD-first and
follow the repo's Swift Testing preamble convention. Require pre-fix failure
only for the newly-introduced region-push behavior: I1, I2, I7, and the
`scrollbackRowCount > 0` clause of I8. I6 (shared scrollback accounting/eviction)
and the wheel-routing clause of I8 are load-bearing premises that already hold;
they are proven alongside the newly failing region behavior, not asserted to be
red. Do not combine unrelated assertions merely to force a whole test red.

## Non-goals

- No DECSLRM (left/right margin) support; the full-width condition is implicit.
- No input-side workaround in the wheel path; routing and encoding are correct.
- No change to alternate-screen scroll semantics or the wheel arrow-key route.

## Implementation discretion

- Test placement (new suite file vs. extending an existing scroll/scrollback
  suite) and whether the I8 fixture uses the neutral fixture harness or a
  direct `feed` + `decideTerminalWheel` test.

## Verification

- `swift test --package-path lib/TerminalCore` (new tests red before the fix,
  green after), then `just test`.
- Manual: `just build-run`, open codex in a pane, confirm mouse-wheel scrolls
  the transcript; confirm `claude` / `tree` scrolling still works and a
  full-screen TUI (e.g. `vim`) still does not scroll locally.

## Implementation notes

- The condition landed as a named `retainsRowsScrolledOffTop` property
  (`activeScrollRegion.lowerBound == 0 && inactivePrimaryScreen == nil`) rather
  than inline at both call sites, so the xterm/libvterm citation and the
  "upward paths only" scope live in one place.
- The rule matches libvterm's own `premove` gate exactly
  (`references/libvterm/src/screen.c:225` -- `start_row == 0`, full width,
  primary buffer), so two neutral fixtures stopped being deviations:
  `libvterm/scroll-region-linefeed.json` lost its recorded deviation entirely,
  and the manifest-level deviation was narrowed to offset regions and line
  edits (libvterm's `premove` does push for DL at row 0; DanTerm still does
  not, per the plan's Decision).
- `libvterm/erase-scrollback.json` needed its trailing expectation updated too:
  its final LF sits at the bottom margin of a `CSI 1;2 r` region, so it now
  retains a row.
- `TerminalScrollRegionTests.verticalScrollSeversWrapSeams` used `CSI S` in a
  `CSI 1;2 r` region as its only proof that a scrollback row's wrap claim is
  severed when its continuation is destroyed. That scroll now retains instead
  of destroying, so the case switched to `DL` at the top margin -- the
  remaining path that orphans a scrollback wrap claim -- keeping
  `severScrollbackWrapClaim` covered with the same assertions.
