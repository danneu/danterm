# Pivot Width Reflow to Structural Blank Preservation

## Context

Commit `b6b47261` fixed the Codex composer width-resize defect with a fallback:
a recorded resize-series state (viewport top + cursor attachment) restated
across consecutive width changes and cleared by termination events. A survey of
the reference terminals showed the defect class is structural: every terminal
that trims trailing blanks at reflow time (ghostty, kitty, wezterm, foot, vte,
libvterm) has the bug or a one-resize-wide fence around it, while every
terminal that treats blank rows as data in one stream with a derived seam
(alacritty, tmux, iTerm2) is self-inverse with no state at all. This plan
replaces the shipped fallback with that structural fix.

## Problem

The fallback works, but it is memory bolted onto a lossy operation: a private
`WidthResizeSeries` value, two anchor-restatement helpers, a second reflow
destination map, nine termination hook sites, an eviction clamp, and per-action
feed-loop bookkeeping -- all to remember what the shrink destroyed. It also
only restores layout within one uninterrupted series: any output, navigation,
height change, or screen transition between two resizes re-exposes the defect.

## Decision

Make primary-screen width reflow information-preserving, so a width round trip
is self-inverse by construction and the engine holds no resize state across
calls.

- Trailing never-written blank rows are layout data. Width reflow preserves
  their count at every width. Wrap growth displaces rows from the top of the
  viewport into scrollback instead of consuming blanks below the cursor.
- Ordering contract (this inversion is the fix): after refolding live content,
  append the preserved trailing blanks first, then compute the viewport
  deficit. The deficit then equals exactly the rows freed by unwrapping --
  which is exactly what a prior shrink pushed out -- so widening pulls back
  precisely those rows through the existing history pull path.
- Bottom-follow is a degenerate case, not a mode: a cursor on the bottom row
  means zero trailing blanks, so widening still pulls eligible retained
  history into freed rows.
- Cursor visibility wins over blank preservation: when the reflowed cursor
  destination would land above the viewport start, reduce the preserved
  trailing blanks by exactly the shortfall (never touching content -- the
  overflow and deficit branches are mutually exclusive, so the removed tail
  rows are provably the appended blanks). This clamp is the one residual
  layout irreversibility.
- The cursor keeps the existing per-resize reflow anchor model unchanged,
  including the trailing-padding column clamp.
- Remove the series mechanism added by `b6b47261` entirely: no width-resize
  state and no series-specific control path, hook, or bookkeeping remains in
  `Terminal.swift`. Keep `evictScrollbackRowsForTesting` for the rewritten
  eviction test. Which symbols that removal touches is implementation
  discretion.
- No public API changes. Nothing outside `Terminal.swift` and tests observes
  the removed state (verified by grep; the field was private).

## Invariants

- I1. A width round trip over unchanged primary content restores the
  underlying primary layout -- full-history text, the history/live seam, the
  trailing blank rows, and the content-anchored cursor -- across any number of
  separate resize events and regardless of intervening alternate-screen
  activity. (Stronger than the fallback: there is no series to end.) Two
  qualifications, both defined elsewhere in this plan: blanks the
  cursor-visibility clamp removed (I2) are the one residual loss, and after
  explicit viewport navigation the displayed viewport follows the browsing
  anchor (I5) while the underlying layout still restores.
- I2. Width reflow preserves trailing never-written blanks: wrap growth
  displaces rows into scrollback instead of consuming them. The one exception
  is the cursor-visibility clamp: blanks removed to keep the cursor visible
  are lost, and on a later widen those rows fill from retained history like
  any other deficit.
- I3. A width change with the cursor on the bottom row keeps bottom-follow:
  widening pulls eligible retained history into freed rows.
- I4. Width reflow preserves full-history logical text and grid validity at
  every width.
- I5. Alternate-screen rectangle resize and the explicit browsing viewport
  contract are unchanged; the stashed primary refolds under this same rule
  while the alternate is active.
- I6. `resize` is a pure function of the terminal value and the requested
  size; invalid and same-size requests remain bit-identical no-ops.

## Accepted risks

- A cursor parked in never-written trailing padding whose column was clamped
  at a narrow width is not restored by the widen leg (user decision; matches
  alacritty, tmux, and iTerm2; any app output after resize repositions the
  cursor anyway).
- Background-erase-styled trailing blank rows re-materialize with default
  style across a width change. Pre-existing behavior; not changed here.
- Content below the cursor exceeding a full screen still top-clamps the cursor
  via the existing backstop. Pre-existing behavior; not changed here.

## Proof Obligations

- PO1 (I1, I4, I5). These existing tests must pass unchanged, and are the
  pivot's regression proof: `widthRoundTripPreservesCodexComposerViewport`,
  the behind-alternate round trip (rename it -- there is no series to not
  end), `widthGrowthPullsHistory`, `widthShrinkViewportBoundaries`,
  `trailingPaddingAnchorPreservesDistance`,
  `trailingBlankAnchorDefersWrapWhenContentFillsRow`,
  `resizePreservesBrowsingAnchor`, `shorteningWidthReflowRestoresBottomFollow`,
  and `resizeFuzzMaintainsGridValidity`.
- PO2 (I1, I2). Rewrite the two pinned shrink tests `widthShrinkDoesNotSelfPush`
  and `widthShrinkCountsAllContinuationsAboveCursor` to the new contract:
  assert displacement into scrollback with trailing blanks preserved, and add
  a widen-back leg asserting exact restoration (screen text, cursor including
  pending-wrap, scrollback count) -- the self-inverse property is the point.
  Rename to describe the new contract; their preambles name this pivot.
- PO3 (I1, I2). Add coverage the fallback could not have, as two separate
  assertions: (a) a round trip split across separate resize events with
  intervening viewport navigation restores the underlying live layout (screen
  text, seam, trailing blanks) while the displayed viewport keeps the browsing
  anchor; (b) a round trip whose narrow leg clamps blanks for cursor
  visibility, with retained history present, pins the residual loss -- the
  widen leg pulls history into exactly the clamped rows and restores the
  remaining blanks.
- PO4 (I2). The blank-reduction clamp is pinned by the `padding` and
  `writtenSpace` sub-cases of `cellAnchorsFollowReflowedCells`, which now pass
  only through it; update the three sub-cases (`narrow`, `tail`, `head`) and
  the narrow half of `boundaryAnchorFollowsReflowBoundary` whose expectations
  shift to the displacement behavior, and reframe the cluster half of
  `spacerRoundTripAcrossWidths` (its spacer assertion moves to a scrollback
  row or a bottom-row cursor fixture).
- PO5. Curate the series tests: delete the now-vacuous termination tests
  (output, cursor motion, height change, reset, screen transition -- both
  arms are identical without a series); keep the viewport-navigation test
  renamed as a browsing-anchor-across-widen proof; rewrite the eviction test
  as plain robustness (widen after full eviction pads blanks, resurrects
  nothing, preserves validity); delete or weaken
  `multiStepWidthSeriesRestoresTrailingPaddingCursor` to layout-and-history
  restoration per the accepted risk.
- PO6 (I4). Update the adapted suites where a shrink with trailing blanks now
  displaces: one leg of `cursorAnchorSurvivesNarrowAndRewidenWalk`
  (`TerminalWezTermAdaptedTests`, plus its Divergence note -- wezterm itself
  consumes blanks) and two kitty narrow tests
  (`narrowSplitsOnlyTheOverflowingRow`,
  `narrowCarriesTrailingSpacesOfAContinuedRow`). Audit
  `TerminalAlacrittyAdaptedTests`, `TerminalViewportTests`,
  `TerminalDamageTests`, and `TerminalResizeProbeSupportTests` for
  shrink-with-blanks fixtures.
- PO7 (I6). The existing bit-identical no-op test now also proves the state
  removal, since the field is gone from the value.
- PO8. Run `swift test --package-path lib/TerminalCore --filter
  TerminalResizeTests`, then the adapted suites, then the full local gate
  (`just test`).

## Rejected ideas

- The resize-series memory (commit `b6b47261`). Restores layout only within
  one uninterrupted series and carries nine termination hooks plus an eviction
  clamp; superseded by making the operation lossless. The implementation and
  its plan (`plans/impl/2026-08-13-1817-preserve-viewport-across-width-resize.md`)
  remain in history.
- A width-independent true cursor column (clamped only as a per-width
  projection) to preserve the trailing-padding cursor across round trips.
  Structurally clean and self-invalidating, with vte/xterm prior art, but it
  permanently widens the cursor invariant to two divergeable columns to
  preserve a behavior that is nearly unobservable. User rejected it; recorded
  as the accepted risk above.

## Non-goals

- Height-resize behavior (trailing-blank trimming on shrink, bottom-gated
  pull on growth) is unchanged.
- Alternate-screen rectangle resize is unchanged.

## Documentation

- Rewrite the D7 row in `docs/design/2026-08-06-swift-terminal-engine.md`:
  replace the series contract with the structural one -- trailing
  never-written blank rows are layout data preserved at every width, the seam
  is derived, width round trips are self-inverse, and cursor visibility bounds
  blank preservation. Note the prior art (alacritty, tmux, iTerm2).
- Record the nine-terminal resize survey in
  `docs/scratch/2026-08-13-resize-reflow-survey.md` so the comparative
  evidence behind this pivot is not lost with the conversation.

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` -- remove the series
  mechanism; replace the viewport arithmetic in `resizeWidth` with the
  blank-preservation rule, reusing the existing deficit-pull and
  anchor-restatement paths.
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalResizeTests.swift` -- the
  rewrites and curation above.
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalWezTermAdaptedTests.swift`,
  `TerminalKittyAdaptedTests.swift` -- shifted expectations.
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalCellStyleTests.swift`,
  `TerminalLogicalLineFoldTests.swift`, and
  `Fixtures/libvterm/reflow-narrow-wide.json` -- displaced-row expectations
  found by the full adapted-fixture audit.
- `docs/design/2026-08-06-swift-terminal-engine.md` -- D7.
