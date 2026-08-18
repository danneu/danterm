# Pane grid override: D6 stage 2 on model-owned geometry

Builds D6 stage 2 (docs/research/35-ios-remote-client/decisions.md, "D6 --
geometry: claim is a gesture, not a lock") on top of the model-owned pane
geometry ADR (docs/design/2026-08-16-model-owned-pane-geometry.md).

## Problem

The Mac window runs a pane at ~179 columns; the phone can show ~60. A pane has
one authoritative size, so the shipped iOS client renders the whole Mac-sized
grid scaled by ~0.29 -- legible as proof, unusable as product. D6 decided the
model: no ownership, no locks; claiming is a one-shot gesture that sends the
client's size as an ordinary last-writer-wins resize through a new
`pane.resize` method, and every client renders native or remote-sized by a
derived predicate.

What D6 did not anticipate: the 2026-08-16 ADR has since made a pane's grid a
pure function of container bounds and split ratios. `paneLayout` projects every
pane rectangle from the model; `SwiftTerminalSessionView.synchronizePresentation`
derives the grid from its bounds; the model never stores a pane grid. There is
no place to say "this pane is 60 columns regardless of its rectangle." The real
content of stage 2 is that seam -- the rectangle a pane *occupies* versus the
grid it *runs at* -- not the IPC verb.

## Load-bearing premises

- The model already flows per-pane presentation state one-way to the session
  view (theme, font size via `reconcilePaneConfig`); a grid override rides the
  same channel. Verified against `Reconcile.swift` and `PaneModel`.
- Only a user divider gesture writes geometry model-ward (ADR D2). Container
  layout, tab reveal, zoom, and window resize produce no model message.
- Resizes already propagate to every replica through the recorder stream, and
  D5's sync fence orders a mid-sync resize correctly. No new wire record is
  needed for observers (F4, D5).
- The engine floor for a grid is columns >= 2, rows >= 1
  (`terminalGridDimensions`).
- There is no crisp remote-detach event (F5), so no release rule may depend on
  liveness. D6's rationale; decided, not re-litigated here.

## Decision

`PaneModel` gains an optional grid override in cells. Absent, the pane's grid
derives from its slot rectangle exactly as today. Present, the pane's grid is
exactly the override, independent of every rectangle input. `pane.resize` sets
it (columns + rows) or clears it (fit); a take-back gesture at the Mac clears
it. Both writers are ordinary `update()` messages; last writer wins; nothing
records who wrote.

This is the ideal under the design bar, and it is cheap precisely because the
ADR just built the rails: the model is already the single geometry owner, the
reconcile pipeline already carries per-pane state to the view, and the stream
already broadcasts resizes. The pane's *rectangle* stays a pure projection of
bounds and ratios; the *grid* gains one explicit model input. The core still
computes no rows or columns from points -- it stores a requested grid a client
supplied (the ADR's "chrome stays AppKit-owned" consequence is untouched).

**D6 holds, and the ADR improves its implementation.** "Claimed" remains a
derived per-client predicate; what the model stores is the pane's size policy,
not ownership -- no client identity, no tenure, no release protocol. And D6's
stage 3 (origin metadata on resize events) dissolves: its one job was to stop
the Mac's incidental layout-driven resizes from clobbering a claim, and under
the ADR layout is not a grid writer at all, so the clobber it would suppress
is structurally impossible. Reopen stage 3 only if a non-model grid writer is
ever reintroduced.

**Open question resolved: the override is durable until explicit take-back**,
deliberately diverging from D6's v1 ("any Mac layout event reasserts"). The
crude reassert is no longer free: it would require the view to write geometry
model-ward on layout events -- the exact feedback edge the ADR deleted -- and a
transient false frame during a structural change would silently drop a
deliberate claim. Durable is also the behavior the user actually wants.
Consequence: a minimal take-back affordance moves into stage 2 (D6 had
deferred it to stage 3), because a durable override needs a one-gesture exit
at the Mac.

Scope: the model override and its two writers; the `pane.resize` method and
`danterm pane resize` CLI verb with `integrations/danterm/SKILL.md` updated in
the same change; Mac remote-sized rendering with the take-back affordance; the
phone's claim button. When this ships, amend the D6 entry in decisions.md with
the stage-2-as-built record: durable take-back, and stage 3 dissolved with its
reopen condition.

## Invariants

- I1 -- A pane's grid derives from its slot rectangle unless the model holds an
  override; with an override, the grid is independent of every rectangle input
  (window resize, divider drag, zoom, tab reveal) and of font changes, which
  move pixel size only.
- I2 -- Only `update()` messages move the override: an IPC `pane.resize`, or
  the Mac take-back gesture. No AppKit layout, reveal, occlusion, or window
  event writes it.
- I3 -- No ownership state exists: no client identity, liveness, or lock is
  stored anywhere; concurrent claimers self-heal by last-writer-wins.
- I4 -- An override transition submits exactly one grid to the session: the
  override grid on set, the slot-derived grid on clear, with no intermediate
  value between states. While an override is present, rectangle changes submit
  no grid and reach no PTY.
- I5 -- An applied resize reaches the PTY once and reaches every replica
  through the existing recorder stream; no new stream record kind, no change
  to the D5 sync contract.
- I6 -- The Mac keys remote-sized presentation and the take-back affordance
  off override presence in the model, never off a grid comparison. While an
  override is present, the Mac renders it at native cell metrics, anchored
  top-left with blank surround, scaled down uniformly only when the slot
  cannot contain it;
  pointer input (selection, wheel targeting) maps through the same transform;
  a visible affordance on the pane clears the override in one gesture.
- I7 -- The override survives tree edits, zoom cycles, hidden tabs, and app
  restart (recovery persistence); a pane created by splitting an overridden
  pane starts without one. A pane restored with an override spawns its child
  at the override: no earlier grid -- the 80x24 launch default or a
  slot-derived size -- is ever observable to the child or on the tape. A
  persisted override outside I8's accepted range decodes as absent (the
  `fontSizeSteps` decode precedent), so a corrupt snapshot yields the stated
  slot-derived launch, never a silent default.
- I8 -- `pane.resize` is pane-targeted, callable by remote callers, audited,
  and non-terminating; its params are columns + rows or the fit form, never
  both. Accepted values lie within the engine floor (columns >= 2, rows >= 1)
  and a per-axis maximum of 1,024, documented in SKILL.md. The maximum bounds
  a maximal grid's cell storage in the tens of megabytes -- and, with I12's
  destination-bounded presentation storage, no single request can exhaust the
  memory of any app rendering the pane -- and it sits far below the PTY's 16-bit
  winsize ceiling, so every accepted grid is represented identically by the
  PTY, the engine, and every replica. Out-of-range values are invalid-params
  errors, never clamped; every other shape is an invalid-params error.
- I9 -- `pane.info` and `ls` report the override when present.
- I10 -- CLI: `danterm pane resize --pane <pane-id> <columns>x<rows>` and
  `danterm pane resize --pane <pane-id> --fit`, replying in the `pane info`
  shape (as `pane zoom` does); SKILL.md documents it in the same change.
- I11 -- The phone's claim gesture sends the replica surface's native grid as
  a `pane.resize`; typing and scrolling never send one (D6's typing-never-
  claims policy).
- I12 -- Every presentation that scales a grid to fit its destination -- the
  Mac's letterbox case and the phone's observe rendering alike -- draws
  directly into backing storage bounded by the destination view's pixel
  extent. No pixel allocation sized to the grid's native extent (frame store,
  swapchain buffer, or any other pixel buffer) ever occurs on either end.

## Proof obligations

- PO1 (I1, I2, I3, I8) -- Core tests: dispatch sets and clears the override;
  the take-back message clears it; a second resize replaces the first; invalid
  params are refused with stable errors, including values at and beyond both
  ends of the accepted range.
- PO2 (I4) -- App-side tests extending the ADR's focused rectangle-to-grid
  suite: with an override present, a wrapper frame change submits no grid;
  setting submits exactly the override once; clearing submits exactly the
  slot-derived grid once; a font-metrics change under an active override
  leaves the grid and PTY unchanged while presentation metrics update.
- PO3 (I5) -- End-to-end against a live slot: `danterm pane resize` changes
  the pane's real grid, observable from the pane's own tape geometry, and a
  following replica converges on it.
- PO4 (I7) -- Core tests: persistence round-trip retains the override; a split
  does not propagate it; an out-of-range persisted override decodes as absent. A restore test proving the first observable PTY/tape
  geometry of a recovered overridden pane is the override, with no preceding
  80x24 or slot-derived resize.
- PO5 (I6, I12) -- A projection-level test that the affordance tracks override
  presence exactly, including an override equal to the slot-derived grid;
  hit-test mapping asserted where the mapping lives; presentation-
  geometry coverage for both rendering cases: a fitting grid renders at native
  cell metrics at top-left with blank surround, and an oversized grid scales
  down uniformly to fit with every pixel allocation bounded by the slot's
  pixel extent; a phone-side test that observe rendering of a grid larger
  than its view allocates no store beyond the view's pixel extent.
- PO6 (I8) -- The method catalog's exhaustive switches force classification at
  compile time; audit coverage follows the existing per-method pattern.
- PO7 (I9, I10) -- Encoder test for the reported override; CLI parser tests
  for both forms.
- PO8 (I11) -- A kit-level test that the claim gesture produces a `pane.resize`
  carrying the surface's native grid.

## Non-goals

- Stage-4 client polish: hybrid reflow, auto-take-back, typing-claims, a
  phone-side release/fit control.
- Origin metadata on resize events (stage 3) -- dissolved above; reopen only
  if a non-model grid writer is reintroduced.
- Any change to phone observe-mode presentation: T25's scaled rendering stays
  the unclaimed look. Its backing storage moves under I12's destination bound;
  nothing else about it changes.
- Input arbitration or multi-human tenure (D6's reopen conditions, unchanged).

## Accepted risks

- AR1 -- An absent phone leaves a small pane behind; recovery is one gesture
  at the Mac. This is D6's "detach dissolves" premise, now behind an explicit
  gesture instead of a free layout reassert.
- AR2 -- Durable take-back diverges from D6's recorded v1. Deliberate; the
  decision-log amendment in Scope records it.
- AR3 -- Any admitted remote caller can shrink a pane mid-use; last-writer-
  wins by design, and the user reclaims in one gesture.
- AR4 -- An override larger than the slot renders scaled down at the Mac,
  mirroring the phone's unclaimed view; acceptable, one user controls both
  ends.

## Rejected ideas

- RI1 -- `pane.resize` as a session-level command bypassing the model, with
  Mac layout reasserting (D6's literal v1). Reintroduces a second geometry
  writer racing the container pass -- the two-writer false-frame class the ADR
  exists to close -- and occlusion-driven layout would end a claim within
  milliseconds.
- RI2 -- The core computing rows and columns from rectangles. Moves font
  metrics into the pure core against the ADR's explicit consequence.
- RI3 -- Stored ownership, or origin metadata now. D6 decided against
  ownership; origin metadata's job is void under I2.
- RI4 -- Folding the override into zoom. Zoom is rectangle policy, the
  override is grid policy; I1 keeps them orthogonal and composable.

## Implementation discretion

- Exact wire and CLI spellings beyond the stated forms, reply payload detail,
  and the reported override's field naming.
- The take-back affordance's concrete form (toolbar chip, surround click, or
  similar), provided I6's one-gesture rule holds.
- How the letterbox transform and the destination-bounded scaled draws are
  realized, within I12's no-grid-native-allocation rule.

## Commit progress

- [x] 1. feat(core): store the pane grid override with set, clear, and
  take-back messages
- [x] 2. feat(ipc): add `pane.resize` and the `danterm pane resize` CLI verb,
  reported by `pane.info` and `ls`
- [x] 3. feat(app): drive the pane grid from the override, including
  restored-pane launch
- [x] 4. feat(render): Mac remote-sized rendering with the take-back
  affordance
- [x] 5. feat(ios): claim button sends the surface's native grid
- [ ] 6. feat(ios): destination-bounded observe rendering; amend the D6
  decision record

## Implementation notes

- Commit 1 writes the override with two messages, not three:
  `setPaneGridOverride(paneId:grid:)` and
  `clearPaneGridOverride(paneId:)`. The take-back gesture is a clear with
  no pane id, which the reducer resolves to the selected tab's focused
  pane -- the `resetPaneFontSize` precedent. A separate take-back message
  would carry identical semantics and give the model a second way to say
  the same thing, which I2 does not require.
- Commit 2 splits the two validations by which layer owns the fact.
  `DanTermProtocol` reads only the shape -- `{columns, rows}` or
  `{fit: true}`, never both -- because it cannot see `PaneGridOverride`.
  The accepted range is checked once, in core dispatch, by the failable
  init, so the range has exactly one definition.
- Commit 2 reports the override from `IpcEntityEncoder.paneFields`, the
  field set `pane.info` and `ls` share, rather than from the `ls`-only
  block that carries `theme` and `fontSizeSteps`. That is what makes I9's
  "both report it" true by construction instead of by two edits.
- Only in-range grids are representable: `PaneGridOverride` has a failable
  init bounded by `paneGridOverrideColumnRange` (2...1024) and
  `paneGridOverrideRowRange` (1...1024). That makes I8's "never clamped"
  and I7's "out-of-range persists as absent" the same one rule, and leaves
  the IPC layer in commit 2 with nothing to validate beyond mapping a nil
  construction to invalid-params.
- Commit 3 rides the override to the view on the existing per-pane config
  channel: `PaneConfigKey` gains it and `reconcilePaneConfig` pushes it,
  so a set and a clear are both just a changed key that the same diff
  applies. No new command and no new reconcile pass.
- The view keeps I4 by construction rather than by a suppression rule.
  `synchronizePresentation` reads `override ?? boundsDerivedGrid`, so
  while a claim is present the bounds conversion is never evaluated, the
  computed grid never changes, and the existing "only submit when the
  grid changed" test already stops every rectangle input at the view.
- Restored-pane launch takes the override as *spawn* geometry, not as a
  grid submitted after launch: `TerminalPaneLaunchRequest` gained an
  optional `initialDimensions`, and `SwiftTerminalSessionView` takes the
  override at construction so its first presentation pass submits the
  claim rather than the slot-derived grid. Submitting after launch would
  have left the 80x24 default observable to the child, which I7 forbids.
- PO3 was confirmed live against a dev slot: a claim moved the child's
  real `stty size` to 60x20, survived a split that halved the pane's
  rectangle, and `--fit` returned it to the rectangle's grid. The restart
  half could not be driven through `just launch-slot`, which always
  passes `--fresh`; it is covered by the app tests plus a check that the
  written recovery checkpoint carries the override.
- Commit 4 realizes I12's destination bound by rendering at a reduced
  display scale rather than by transforming a native-sized surface. The
  frame store's pixel extent is `cellPixels * count`, so lowering the
  scale the cell box is quantized at lowers the allocation in the same
  proportion, and the pane then presents those pixels at its own backing
  scale. A layer transform would have left the allocation at the claimed
  grid's native extent, which I12 forbids.
- The fit scale comes from the whole pixels each cell may occupy --
  `floor(pixelBudget / count) / nativeCellPoints` -- not from the point
  extent. A cell box is ceiled to whole backing pixels, so a scale derived
  from points can overshoot by up to a pixel per cell, which is a visible
  fraction of a 179-column grid. Dividing the budget first makes the
  ceiled box fit by construction, with no iteration.
- One formula covers both rendering cases: a grid the slot contains
  resolves to the pane's own backing scale, because floor(budget/count) is
  then at least the native cell's pixel count. So there is no
  fits/does-not-fit branch, and an unclaimed pane -- whose grid is derived
  from its own rectangle and therefore always fits -- renders exactly as
  before.
- The view now separates the cell box it renders from the cell box it
  shows. `displayedCellSize` is the rendered box carried back to the pane's
  scale, and every pointer mapping, the context-menu anchor, and the
  scrollbar's cell height read it. I6's "pointer input maps through the
  same transform" is that one value being the only cell box the view's own
  coordinates ever meet.
- A commit-3 test had to move: it proved a font change under a claim moves
  cell metrics, using a pane too small to contain the claim. Under this
  commit such a pane draws the claim down to fit, so the font no longer
  decides the drawn cell size there. The fixture is now a pane that
  contains the claim, which is the case the assertion was always about.
- Commit 5 puts the claim's whole computation in one kit value,
  `MobileSurfaceGrid`, built from backing pixels rather than points: the
  cell box is quantized to whole pixels, so a point-derived count can name
  a column the surface cannot draw. The shell's only job is to read its own
  extent and send what the value returns.
- The claim carries no clamp to the accepted range. That range lives in
  `DanTermCore`, which the phone cannot see, and duplicating it would give
  it a second definition; a grid the Mac refuses comes back as an ordinary
  request refusal the status line already reports. The kit refuses only the
  one case it can decide for itself -- a surface with no room for a whole
  cell has no honest claim to make.
- The claim uses the terminal view's extent at the moment of the tap, so a
  claim made with the keyboard up asks for the shorter grid. Re-claiming is
  one tap, and an automatic re-claim on every layout change is exactly the
  reassert the plan rejected.
