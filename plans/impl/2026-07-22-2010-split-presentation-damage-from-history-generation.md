# Split presentation damage out of the primary-history generation

## Context

Commit `977b2bb` derives `primaryHistoryGeneration` from the damage funnel:
all three `recordDamage*` helpers in
`lib/TerminalCore/Sources/TerminalCore/Terminal.swift` call
`notePrimaryHistoryDamage()`. Render damage is a strictly larger set than
history mutation, so cursor movement, selection drag, link hover, viewport
scrolling, and search navigation now advance the generation (verified:
PROBE-CURSOR / PROBE-SELECT).

The motivation is invariant honesty, not throughput. The runtime constructs
`RecoveryCheckpointPolicy` with a 600-second window
(`app/AppRuntime.swift:162-163`), so a redundant trigger costs at most one
extra enriched checkpoint per 10 minutes -- the same cadence the Ghostty
backend writes unconditionally. The cost of the conflation is that
"generation advanced" cannot be read as "history changed", so no consumer
can trust it and the dead consumer-side filter cannot be retired.

That old backstop, `enrichedRecoveryProjectionChanged`
(`lib/DanTermCore/Sources/DanTermCore/Persistence.swift:255`), is dead in
production -- referenced only by its own tests
(`ExportTests.swift:103-105`).

The fix is structural, not a filter: presentation damage reaches the funnel
through a small set of provably content-free sites -- the body of
`recordDamage(since:)` (`Terminal.swift:555-585`), which diffs
cursor/selection/hover UI state, and the viewport-state-only damage in
`scroll(toTopRow:)` / `scrollToBottom` / the three search-reveal sites.
Everything else in the funnel is content damage. The `recordDamage(since:)`
half was implemented locally and verified: PROBE-CURSOR and PROBE-SELECT go
quiet, PROBE-BROWSE (output while scrolled back) still bumps, 468 core
tests pass.

## Decision

Convert to damage-recording variants that do not advance the history
generation, in exactly two places and nowhere else:

1. The whole body of `recordDamage(since:)` -- its `recordFullDamage()`
   early returns and its cursor/selection/hover row-damage calls.
2. The viewport-only damage statements in `scroll(toTopRow:)` (1383),
   `scrollToBottom` (1392), and `beginSearch`/`searchNext`/`searchPrevious`
   (2045/2062/2079). Each is shaped
   `if viewportState != previous { recordFullDamage() }` after a mutation
   that touches only `viewportState`/`search`, never cell storage.

Every call site outside these two keeps bumping by default, so the failure
mode of a future mistake is a redundant recovery write, never a lost
emission.

Target 1 is safe for a different reason than target 2, and the two must
not be judged by the same rule. `recordDamage(since:)` is called after
arbitrary work -- including full stream feeds -- so its callers do mutate
cells. What makes it convertible is that its *body* records only the
deltas it detects by diffing the cursor/selection/hover snapshot; the
content those callers wrote reaches the funnel through its own paths.
PO-A is the obligation that pins exactly this: each of the four content
funnels bumps independently, so no emission depends on this function's
blanket bump.

Convertibility criterion for direct damage calls *outside*
`recordDamage(since:)` (i.e. target 2 and any future candidate) -- a site
may be converted only if both hold: (a) the mutation preceding it touches
`viewportState`/`search` alone and never cell storage, and (b) it is
guarded by `inactivePrimaryScreen == nil`. Any site failing either clause
keeps bumping, no judgment call.

`invalidateInspection(inViewportRows:)` (`Terminal.swift:~2495`) is the
site that fails clause (a) and must not be converted: it reads as
presentational, but its full-damage branch follows a cell write -- it is
the content funnel for `print`/erase/scroll while the user is scrolled
back. Converting it would silently drop history emissions (the
stale-recovery bug).

With the trigger now meaning "content actually mutated", delete
`enrichedRecoveryProjectionChanged` and its three `#expect` cases: it is
dead in production, and the imprecision it was shaped to absorb is no
longer the presentation conflation but the cheap over-approximation AR1
already accepts.

Record the surviving imprecision in the impl plan
(`plans/impl/2026-07-22-1736-terminal-core-feed-throughput-recovery.md`,
I5 clause): identical-content cell rewrites (shell prompt repaint on each
keystroke) still advance the generation, so "generation advanced" is not
"text differs" -- bounded by the checkpoint policy's
`scheduledDeadline == nil` guard.

## Invariants

- I-A: The history generation advances for every primary-history text
  change, including output that arrives while the viewport is scrolled
  back and resize behind an active alternate screen. Over-approximation
  remains allowed.
- I-B: Presentation-only events -- cursor movement, selection changes,
  link hover, viewport scrolling, and search navigation -- never advance
  the history generation.

## Proof obligations

- PO-A (I-A): the existing `primaryHistoryGenerationCoversFixtureFrames`
  implication test passes unchanged, plus one pinned scrolled-back test
  (the PROBE-BROWSE scenario) asserting the generation advances for each
  of the four structurally distinct content funnels that line 558's
  blanket bump currently covers: `print` and erase (via
  `invalidateInspection(inViewportRows:)`), wrap-claim rewrite (via
  `invalidateInspection(inScrollbackRow:)`), linefeed-driven scrollback
  append (the direct `recordDamage(rows:)` at ~4579, which passes
  `invalidatesInspection: false`), and `enforceScrollbackBudget`
  eviction. Four assertions, one test.
- PO-B (I-B): a converse test pins that pure cursor/selection/hover
  events and pure scroll/search-navigation events leave the generation
  unchanged; its preamble notes that identical-content rewrites still
  advance it (the accepted risk below).
- Full gate: `just test` passes; the deleted `ExportTests` cases are
  gone, not skipped.

## Accepted risks

- AR1: Identical-content cell rewrites (prompt repaint while typing)
  still bump the generation and can open a checkpoint window. Consistent
  with "cell write = content mutation" semantics, and cheap: the policy's
  open-window no-op guard plus its 600s window cap the cost at one extra
  enriched checkpoint per 10 minutes.

## Non-goals

- No consumer-side text filter (retained-candidate
  `enrichedRecoveryProjectionChanged` at `TerminalPaneSessionController`)
  -- rejected as machinery compensating for a source-level conflation.
- No change to consumer-work signaling (`pendingConsumerWork`) or the
  checkpoint policy.

## Files

- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` -- the
  `recordDamage(since:)` and viewport/search-site conversions.
- `lib/DanTermCore/Sources/DanTermCore/Persistence.swift`,
  `lib/DanTermCore/Tests/DanTermCoreTests/ExportTests.swift` -- delete
  the dead filter and its tests.
- `lib/TerminalCore` test suite -- PO-A addition, PO-B converse test.
- `plans/impl/2026-07-22-1736-terminal-core-feed-throughput-recovery.md`
  -- I5 note on the surviving imprecision.

## Implementation discretion

- The shape of the non-bumping variants (parallel helpers vs. a flag
  parameter) -- constrained only by "outside the two converted sites,
  bumping stays the default".

## Verification

`just test` (protocol + core + support + purity lint). Optionally rerun
the probes: cursor-move and selection sequences leave the generation
unchanged; feed-while-scrolled-back advances it.

## Implementation notes

- Implementation discretion resolved toward parallel helpers, not a flag
  parameter: `recordPresentationFullDamage()` /
  `recordPresentationDamage(row:)` / `recordPresentationDamage(rows:)` record
  render damage only, and the three original `recordDamage*` names now wrap
  them plus `notePrimaryHistoryDamage()`. A defaulted flag parameter would have
  made the non-bumping path reachable by omission at a call site; distinct
  names keep bumping the default and make the exception grep-able. The
  convertibility criterion lives as a comment above the three helpers.
- PO-A's four funnels are not all independently reachable. Funnels 1 (cell
  write via `invalidateInspection(inViewportRows:)`) and 3 (linefeed scrollback
  append) are exercised alone. Funnel 2 (scrollback wrap-claim rewrite) and
  funnel 4 (budget eviction) cannot be: a scrollback row is only wrap-claimed
  while its continuation is live in the viewport, and eviction only runs off a
  scrollback append, so both necessarily co-fire with a viewport-row funnel
  through the public feed API. Those two cases assert the scrolled-back
  scenario plus its `primaryHistoryText` consequence instead, and the test
  states the limitation rather than implying isolation.
- The deleted `enrichedRecoveryProjectionChanged` was the only caller-free
  wrapper; `truncateScrollback` underneath it stays live in
  `app/AppRuntime.swift:945` and `:1308`, so only the wrapper and its three
  `#expect` cases were removed.
