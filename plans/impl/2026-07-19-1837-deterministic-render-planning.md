# Milestone 4 slice 1: deterministic render planning

Milestone 4 of the Swift terminal-engine experiment is the interactive
viability slice ([14-roadmap.md](../../plan-terminal-engine/14-roadmap.md)
lines 117-130): one Swift-engine pane launching zsh, rendering, taking input,
and satisfying the experiment gate in
[02-migration-and-boundary.md](../../plan-terminal-engine/02-migration-and-boundary.md).
It lands in four slices: (1) pure render planning, (2) minimal AppKit
CoreText/CoreGraphics executor, (3) session adapter over
`app/TerminalBackend.swift` + the `AppDelegate` backend seam, (4) viability
harness and gate closure. This plan covers slice 1 only; each later slice gets
its own plan informed by what this one establishes.

## Problem

Milestones 2-3 produced a proven headless terminal -- `Terminal` snapshots via
`TerminalPTYHost.snapshot()` -- but nothing that decides what a frame should
look like. The core deliberately stores presentation semantically: indexed
colors are never palette-resolved, SGR 7 reverse is stored not applied, hidden
retains content. [09-renderer.md](../../plan-terminal-engine/09-renderer.md)
requires that "given a read-only terminal snapshot and explicit presentation
inputs, planning decides the required drawing work" deterministically, with
CoreText/CoreGraphics only executing it. Without a pure planning layer,
rendering policy would fuse into AppKit code where it cannot be proven
deterministically, violating the planning/execution split and the Milestone 4
requirement that "terminal-core behavior has deterministic proof at the lowest
practical layer."

Load-bearing evidence (verified):

- `plan-terminal-engine/09-renderer.md:15-18` planning/execution split;
  `:20-30` initial defaults (13 pt monospaced system font, one baked dark
  theme, 16/256/RGB color, steady block cursor); `:44-45` "Identical snapshots
  and explicit presentation inputs produce identical planned drawing work";
  `:49-51` deterministic planning fixtures cover colors, decorations,
  selection, cursor, damage, and wide-cell geometry.
- `plan-terminal-engine/13-power-performance.md:39-48` rendering demand
  coalescing and damage retention are scheduling-layer contracts above the
  planner; `plan-terminal-engine/14-roadmap.md:144-166` damage equivalence,
  selection, and scrollback presentation are Milestone 6.
- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`: the planner's read
  surface is exactly `geometry` (:211) and `cell(row:column:)` (:229) --
  viewport geometry plus viewport cells, nothing else. Scrollback depth and
  the live pen (`currentStyle`, :104) are outside it. `backgroundEraseStyle`
  (:106-111) copies only pen fg/bg into the erased cells themselves, so erased
  padding carries background color but never decorations, and the planner
  never needs to read the pen.
- `lib/TerminalCore/Sources/TerminalCore/TerminalGeometry.swift`: cell kinds
  padding/narrow/wideHead/wideTail/spacerHead (:4-10); `TerminalCursor`
  {row, column, isPendingWrap} (:34-50). No cursor visibility or shape state
  exists in the core.
- `lib/TerminalCore/Sources/TerminalCore/TerminalStyle.swift`: semantic colors
  `.default`/`.indexed`/`.rgb` (:4-8); "Bold is independent from indexed-color
  brightness" (:27); underline color outside the contract (:35); reverse
  stored, not applied (:38-39); hidden retains content (:41).
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalGridAssertions.swift:53-111`:
  wideTail and spacerHead mirror the head's style; spacerHead appears only in
  the last column of a soft-wrapped row.
- `lib/TerminalCore/Package.swift:11-30`: the `TerminalCoreRecording` pattern
  the new target mirrors (depends on TerminalCore, Swift 6 mode, macOS 26).
- `justfile:32` runs `swift test --package-path lib/TerminalCore` unfiltered,
  so a new test target needs no test-gate wiring; `justfile:36-39` shows the
  per-target lint-line pattern.
- `scripts/core-purity-lint.sh:60-64`: `--forbid-imports` rejects every import
  including `import TerminalCore`, so the existing import gate cannot apply
  verbatim to a target that must import TerminalCore.
- `lib/TerminalCore/Sources/TerminalCoreRecording/NeutralTerminalRecording.swift:213-252`:
  public init and `replay(inspect:)` let tests author recordings in Swift with
  `danTerm(test:)` provenance.
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalFixtureTests.swift:79-88`:
  the libvterm fixture corpus loads via `Bundle.module`, private to that
  target; `lib/TerminalPTY/Tests/TerminalPTYHostTests/TerminalPTYHostTests.swift:425`
  is precedent for `#filePath`-relative package-directory access.

## Decision

Build the planner as a new library target in the TerminalCore package (working
name `TerminalRenderPlanning`), depending on `TerminalCore` only, with a new
Swift Testing test target depending on the planner, `TerminalCore`, and
`TerminalCoreRecording`.

### Purity gate

The planner target imports exactly `TerminalCore` -- no Foundation, no Darwin
-- so the determinism claim is structural, like TerminalCore's own gate.
`scripts/core-purity-lint.sh` gains an import-allowlist mode (flag spelling
discretion) with matching self-test cases, and the justfile gains two lint
lines for the new target mirroring the TerminalCore pair (pure profile +
import allowlist).

### Planning function and plan form

Planning is one pure, total, non-mutating function of (snapshot, presentation
inputs) returning an `Equatable`, `Sendable` plan value. Presentation inputs
are the theme and cursor visibility -- nothing ambient. The plan is a complete
frame: a fresh executor given only the plan can draw the entire pane. The
planner is stateless, and its terminal read surface is exactly viewport
geometry plus viewport cells -- not scrollback, not the live pen.

Coordinate space is grid cells (row, column), never pixels or points: doc 09
assigns Retina geometry, font metrics, and line height to execution, and a
pixel-space plan would make the determinism invariant false across displays.
Colors in the plan are concrete RGB triples only; no semantic `TerminalColor`
crosses to the executor.

Run coalescing is contract, not discretion: every run array is in canonical
form -- row-major, ascending start column, non-overlapping, in-bounds, and
maximal (no two adjacent runs in a row share a mergeable key). Canonical form
is what makes plan equality meaningful.

### Plan layers

Layer semantics are contract; exact types and names are discretion.

- Frame geometry: columns/rows echoed from the snapshot plus the resolved
  default background color the executor clears the pane with.
- Background runs: emitted only where a cell's resolved background differs
  from the resolved theme default. Never-written padding therefore emits
  nothing while background-color-erased padding emits runs -- one rule, no
  padding special case.
- Text runs: maximal per-row runs over consecutive glyph-bearing cells
  (narrow or wideHead with scalars, not hidden) sharing resolved foreground
  and font-affecting attributes (bold, italic). Each run cell carries its
  exact scalars and its column width (1 or 2). Written spaces are glyph cells
  and are included. Underline and strikethrough do not split text runs.
- Decoration runs: maximal per-row runs for underline single/double/curly and
  strikethrough, colored with the resolved (post reverse/dim) foreground,
  computed over narrow, wideHead, and wideTail cells so the mirrored tail
  style extends decorations under the whole glyph.
- Cursor: one optional record -- see cursor planning.

### Color resolution pipeline (pinned order)

1. Palette resolution: `.default` maps to the theme defaults; `.indexed(0-15)`
   through the theme's 16-entry ANSI table; `.indexed(16-231)` and
   `.indexed(232-255)` by the standard xterm 6x6x6 cube and grayscale-ramp
   formulas (pinned -- applications rely on these values); `.rgb` passes
   through.
2. Bold never changes color; it selects the bold face only. This matches the
   core's bold/brightness separation and modern terminal defaults; bright
   colors arrive as `.indexed(8-15)` via SGR 90-97.
3. Reverse swaps the fully resolved foreground and background, so
   default-on-default reverse shows swapped theme defaults.
4. Hidden suppresses the cell's text and decoration runs while keeping its
   background; the plan never schedules invisible drawing work.
5. Dim applies a fixed deterministic transform to the resolved foreground
   (exact transform discretion, fixture-pinned once chosen).

### Wide-cell and padding presentation (pinned)

- wideHead: one text-run cell of width 2 at the head column.
- wideTail: no text of its own; contributes background and decorations from
  its mirrored style, so both coalesce across the pair.
- spacerHead and padding: background only -- no text, no decorations. The
  deferred wide glyph draws fully at its real position on the next row.
- Spans derive from cell kinds alone, never recomputed from scalar content,
  so doc 09's "font fallback changes glyph choice without changing grid
  geometry" holds at the planning layer.

### Cursor planning (pinned)

- Cursor visibility is a presentation input. Invisible: no cursor record and
  no cursor color override anywhere in the plan.
- Visible: a steady filled block at `geometry.cursor`. `isPendingWrap` does
  not move the drawn cursor -- it renders on the last-column cell where the
  cursor logically rests until the wrap commits.
- On a wideHead the cursor spans both columns; on a wideTail (reachable via
  CUP) it snaps to the head and spans both columns; otherwise it spans one.
- The spanned cells' resolved colors are overridden (background := theme
  cursor color, foreground := theme cursor-text color) before run coalescing,
  so background, text, and decoration runs all carry the cursor colors and the
  plan's layers already contain the correct final frame. Hidden cells stay
  textless under the cursor.
- No focus distinction this slice: the same filled block regardless of pane
  focus. Focus-dependent cursor treatment is a later slice.

### Baked dark theme

One theme value in the planner target: 16 ANSI RGB entries, default
foreground, default background, cursor color, cursor-text color. Structure is
contract; the exact RGB values are discretion but become fixture-pinned once
chosen so they cannot drift silently. Indices 16-255 are formula-derived, not
stored.

### Damage and scrollback stance

The planner holds no previous plan, no dirty regions, no diffing. Deciding
when to plan is later scheduling work, where unchanged snapshots are gated by
`Terminal`'s `Equatable` conformance and damage retention follows doc 13.
Damage-equivalence proof is Milestone 6. Plans depend only on viewport state
and presentation inputs; neither scrollback content nor the live pen can
change a plan.

### Test strategy

All planner tests drive terminals through the public surface --
`Terminal(columns:rows:)`, `feed`, `resize` -- directly or via Swift-authored
`NeutralTerminalRecording` values, so plan facts are asserted against states
the real engine can reach. The corpus determinism sweep replays every JSON
fixture in `Tests/TerminalCoreTests/Fixtures/libvterm/` by locating the
package directory from `#filePath` (repo precedent) -- no resource
duplication, `TerminalCoreTests` untouched. Of doc 09's fixture categories
this slice covers colors, decorations, cursor, and wide-cell geometry;
selection and damage defer to the milestones that own them. A later visual
bug becomes assignable to planner or executor by replaying the snapshot
through the planner alone.

## Invariants

- I1: Planning is a pure, total, deterministic function of (snapshot,
  presentation inputs): identical inputs produce `==` plans, planning never
  traps on any publicly reachable `Terminal`, and the planner target imports
  exactly TerminalCore (lint-enforced) with no IO or ambient reads.
- I2: Planning reads the snapshot only through public inspection views and
  leaves it unchanged; no planned quantity depends on pixels, fonts, or
  display scale.
- I3: Plans are in canonical form (row-major, ascending, non-overlapping,
  in-bounds, maximal), and every viewport cell's resolved background is
  represented exactly once (by the default clear or one background run).
- I4: Color resolution follows the pinned pipeline (palette -> reverse ->
  hidden -> dim); bold never changes color; indices 16-255 follow the
  standard formulas; only concrete RGB values appear in plans.
- I5: Wide-cell presentation preserves core geometry: wideHead spans two
  columns in one run cell, wideTail contributes no text, spacerHead and
  padding contribute background only, and spans derive from cell kinds alone.
- I6: Every glyph-bearing cell appears in exactly one text run unless hidden;
  hidden cells emit background only.
- I7: A visible cursor yields exactly one cursor record with the pinned
  span/snap/pending-wrap behavior and pre-coalescing color override; an
  invisible cursor yields no cursor record and no cursor-colored cell.
- I8: Plans are complete frames from viewport state only: the planner holds
  no cross-frame state, and no state outside viewport geometry and viewport
  cells -- scrollback content or the live pen included -- can change a plan.
- I9: The baked theme's structure is fixed and its chosen values cannot drift
  without a fixture change.

## Proof obligations

- PO1 (I1, I2, I3): Corpus sweep -- every libvterm fixture replays once
  through the planner; at each checkpoint planning is total, canonical-form
  checks pass, planning the same snapshot twice yields `==` plans, and the
  snapshot equals its pre-planning copy. The sweep asserts the fixture
  directory exists (fails loudly, never skips). Chunk invariance of `Terminal`
  itself is already discharged by the existing fixture suite, so the sweep
  does not re-replay chunkings.
- PO2 (I4): Palette resolution -- theme defaults, the 16-entry table, the
  cube and grayscale formulas, `.rgb` passthrough, and bold+indexed keeping
  the exact palette value.
- PO3 (I4): Reverse swaps fully resolved colors, including
  default-on-default, and reversed cells produce background runs where the
  swapped background differs from the default clear.
- PO4 (I4, I6): Hidden cells emit their (post-reverse) background and no text
  or decoration runs.
- PO5 (I4): Dim produces a deterministic foreground distinct from undimmed,
  composing with bold and reverse, pinned by fixture.
- PO6 (I5): Wide cells -- one width-2 run cell at the head with a silent
  tail; decorations span the pair; a deferred wide glyph plans background
  only at the spacerHead and the full glyph on the next row.
- PO7 (I3): Background trimming and maximality -- never-written padding emits
  no runs; an erased region emits one run per row; no plan contains adjacent
  mergeable runs.
- PO8 (I4, I6): Run content and splitting -- a text-run cell carries its
  source cell's complete payload: the exact scalar sequence in order
  (multi-scalar clusters such as a base plus combining mark keep every
  scalar), the column width, and bold and italic as distinct attributes,
  proven for reachable narrow and wide cells. Underline single, double, and
  curly and strikethrough each survive as their own decoration kind (never
  collapsed, never dropped) carrying the resolved post-reverse/dim
  foreground; foreground or font-affecting changes split text runs; underline
  changes split decoration runs but not text runs; written spaces appear in
  text runs.
- PO9 (I7): Cursor planning matches every pinned behavior -- narrow span,
  wideHead span, wideTail snap, pending wrap, and hidden cells under the
  cursor; the spanned cells' background, text, and decoration runs carry the
  theme cursor and cursor-text colors; and, on a snapshot whose cursor sits
  on a styled cell, invisible planning emits no cursor record and leaves that
  cell's background, text, and decoration colors at their ordinary resolved
  values.
- PO10 (I8): Terminals with identical viewport geometry and cells produce
  `==` plans when they differ in scrollback depth and when they differ only
  in the live pen (an SGR change with nothing printed after it).
- PO11 (I1): The new lint lines pass and the lint self-test covers the
  import-allowlist mode in both directions.
- PO12 (I9): A golden theme test pins the chosen ANSI, default, and cursor
  RGB values.

## Non-goals

- The AppKit/CoreText executor, glyph choice, font metrics, Retina scaling,
  and pixel snapshots (slice 2).
- The session adapter, `TerminalBackend`/`TerminalSession` conformance, and
  the `AppDelegate.swift` backend seam (slice 3); the viability harness,
  recordings, and sleep/wake proofs (slice 4).
- Damage or dirty-region planning, partial-frame plans, and plan diffing
  (Milestone 6 owns damage equivalence).
- Selection, search highlights, and hyperlink presentation (Milestone 6).
- Scrollback presentation and scroll-offset input (Milestone 6).
- Cursor blinking, application-requested cursor shapes, DECTCEM, and
  focus-dependent cursor rendering -- no core state exists for the first
  three, and focus treatment was explicitly deferred.
- Configurable themes, fonts, or any settings surface (doc 11 baked
  defaults).

## Accepted risks

- AR1: Planning walks `cell(row:column:)` per frame, allocating one
  `TerminalCell` per cell. Acceptable for the correctness-first slice; a
  bulk-row read on `Terminal` is later discretion if profiling demands it.
- AR2: Full-frame plans and text runs for written spaces do more executor
  work than a trimmed or diffed plan; correctness and plan simplicity win
  this slice.
- AR3: The corpus sweep reaches fixtures via a `#filePath`-relative path
  rather than bundled resources; PO1's existence assertion makes a moved
  directory fail loudly.
- AR4: No-bold-brightening and the hidden/dim renderings are visible product
  choices made without daily-use feedback; each is a single pinned decision
  reversible behind the same contract shape.

## Rejected ideas

- RI1: Pixel- or point-space plans -- breaks cross-display determinism and
  drags CoreText metrics into the pure layer.
- RI2: Planning inside the TerminalCore target -- the core deliberately
  stores semantic colors; fusing presentation would break its import-free
  gate and its recorded libvterm deviation.
- RI3: A separate SwiftPM package -- the same-package target matches the
  TerminalCoreRecording precedent; a package boundary buys nothing until an
  executor exists.
- RI4: Damage diffing in the planner now -- stateful planner, duplicates
  Milestone 6 work, contradicts doc 13's damage-retention model.
- RI5: Semantic colors in the plan with executor-side palette lookup --
  splits color policy across the boundary and makes identical-plan =
  identical-drawing false under theme changes.
- RI6: Cursor as an executor-side overlay that re-renders cell text -- the
  plan would no longer fully determine drawing.
- RI7: Bold brightens ANSI 0-7 -- contradicts the core's bold/brightness
  separation and modern terminal defaults; SGR 90-97 already provides bright
  colors.
- RI8: Moving `Fixtures/` into a shared resource target -- churns Milestone
  2's fixture loading and manifest test for a read-only need `#filePath`
  already serves.
- RI9: Coalescing as implementation discretion -- without canonical form,
  plan equality (the doc 09 determinism invariant) is unfalsifiable.

## Implementation discretion

- All type, member, and file names (working names above); run storage layout;
  the coalescing algorithm.
- The exact dim transform and the theme's exact RGB values (both
  fixture-pinned once chosen).
- The lint flag spelling and self-test mechanics, provided the planner
  target's import set is mechanically limited to TerminalCore.
- Commit slicing, provided every commit is green and failing-test-first
  (repo TDD rule).

## Verification

`just test` is the acceptance gate: it runs the TerminalCore package tests
unfiltered, the new target's lint lines, and the lint self-test.

## Commit progress

- [x] 1. Enforce the render planner purity boundary
- [ ] 2. Add deterministic render values and color resolution
- [ ] 3. Plan complete viewport frames with corpus-backed proofs
