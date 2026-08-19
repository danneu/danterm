# Keyboard-stable claim geometry and model-owned claim renewal

## Context

On the phone, the terminal view's bottom rides the keyboard (via the bottom
bar on `keyboardLayoutGuide`), so showing the keyboard shrinks the view. Two
symptoms follow:

- The whole rendered grid is fit-scaled down to the shrunken view
  (`MobileObserveSurface.fittedRenderScale`), so a pane claimed at the phone's
  own size becomes smaller and blurrier the moment the user starts typing --
  plus all three frame stores are reallocated and redrawn on every keyboard
  toggle.
- The grid a claim names is read from the view's momentary bounds, so two
  claims seconds apart can name different grids depending on keyboard state.

A third gap is independent of the keyboard: rotating the phone while it holds
the claim leaves the pane at the old orientation's grid until the user
manually re-claims.

Desired outcome, confirmed with the user:

1. A claim always names the keyboard-absent grid.
2. The keyboard never rescales content. The drawn grid keeps its metrics,
   stays bottom-anchored above the bar, and its top rows slide up out of the
   clip.
3. Rotation while this phone holds the claim automatically renews the claim at
   the new orientation's grid, decided by the model, not the view.

Load-bearing premise (verified in code): the fit-scaling the user dislikes
exists only because the fit box shrinks with the keyboard. Making the content
box keyboard-absent delivers outcome 2 with no change to `MobileContentBox`,
`MobileObserveSurface`, or the render pipeline. Bottom-anchoring and
clipping already exist in `TerminalSurfaceView` (`layer.position` from
`box.maxY`, `clipsToBounds = true`).

## Decision

**D1 -- the keyboard is a presentation offset, never a geometry input.**
`TerminalSurfaceView`'s bounds become keyboard-absent: its bottom sits at the
bar's rest position (safe-area bottom minus the bar height), which reproduces
today's keyboard-hidden layout exactly. The root view controller measures how
far the bar has risen above that rest position and hands the surface view one
scalar; the surface subtracts it from the drawn layer's bottom anchor. The
existing single content box -- the source for the claim grid, the fit scale,
and frame-store allocation -- is therefore keyboard-stable by construction.
Observed (Mac-sized) panes change behavior too: they fit-scale against the
stable box and slide/clip like claimed ones instead of rescaling per keyboard
toggle. This is intended.

The drawn layer's placement -- its bottom edge computed from the content box
and the obscured height, clamped at zero and quantized to whole backing
pixels -- is a pure `DanTermMobileKit` value with behavioral tests, in the
mold of `MobileContentBox` and `MobileObserveSurface`. The UIKit side only
measures the bar's rise and applies the computed placement. The placement
is the single source of the drawn rectangle for everything that must line
up with the cells: the drawn layer's position, the scroll chrome's frame,
and gesture-to-cell mapping all read the offset rectangle, so a viewport
or hit test placed while the keyboard is up lands on the rows actually
visible.

**D2 -- the model holds a standing claim.** A claim gesture that emits a
resize records the claimed grid as a standing claim. While one is held, a
surface report offering a different grid (rotation) emits a renewal resize at
the new grid -- the renewal's sole effect. A standing claim (and each
renewal) is *confirmed* by the success response to the phone's own resize
request, which the connection already delivers into the model with the
request id the model minted. The response is causal by construction, and it
is the only confirmation that exists in every case: a resize naming the grid
the pane already runs at is a server-side no-op (`Update.swift`,
`setPaneGridOverride` guard) that emits no tape transition, so no replica
observation could confirm it. Replica state never confirms a claim. An error
response ends the standing claim. The standing claim also ends on the
release gesture, on connection end, and on an external release, which is
detected from the tape stream (I6): records and responses arrive on one
ordered frame stream, and the server replies before it reconciles
(`AppRuntime.dispatchInFrame` performs commands, then `reconcile()`), so
a record received after the success response states post-claim truth.
Surface facts lawfully lag the response and never end a claim. The
standing claim is in-memory only, never persisted to a checkpoint.

**D3 -- typing.** `surfaceChanged` moves from the ordinary event enum to the
geometry event enum, so the type-level contract stays whole: resize effects
flow only from the geometry entry point, whose inputs are the two deliberate
gestures plus the surface report -- and the surface report resizes only while
a standing claim created by a gesture exists.

## Invariants

- I1: No keyboard state can reach a grid, a claim request, or a frame-store
  allocation. The claim grid is a function of device geometry (orientation,
  safe areas, bar height) only.
- I2: A keyboard show/hide changes only where the drawn rectangle sits and
  what the view clips -- the drawn layer, the scroll chrome, and
  gesture-to-cell mapping move together: same metrics, same pixel extent,
  no store reallocation.
- I3: The drawn content's bottom edge lands exactly on the bar's top, at
  whole-backing-pixel alignment. (The bar is transparent; this is what keeps
  nothing showing through beneath it.)
- I4: The ordinary event entry point cannot produce a resize (existing
  invariant, preserved). A surface report produces a resize only while a
  standing claim exists, so this phone never renews a claim it did not make
  and no renewal loop between two clients is possible.
- I5: Renewals are self-quiescing: after a renewal, an identical surface
  report emits nothing. Semantics stay last-writer-wins, as
  `MobileSurfaceGrid` already declares.
- I6: A standing claim or renewal is confirmed only by the success response
  to the phone's own latest claim or renewal request; no replica state
  report or tape record confirms one -- including a pane another client
  already pinned at exactly this phone's grid. A renewal resets
  confirmation until its own response. An external release ends a
  confirmed claim only via the tape stream: a record stating the pane
  unpinned, decoded after the latest request's success response. The frame
  stream orders records against responses, so the model reads the record's
  pinnedness where it decodes the frame -- never at the surface's later
  acknowledgment, which can lag past the response. Surface facts never end
  a claim, and a record decoded before confirmation does not either. A
  momentary no-whole-cell report (`nativeGrid == nil`) does not end it. An
  error response ends it.
- Transient, accepted as behavior: between a rotation and its renewal echo,
  the held grid no longer fits natively and renders fit-scaled and
  bottom-anchored through the existing observed-pane path, then snaps back to
  native metrics when the echo lands. Not an error state.

## Proof obligations

Model-level, in `MobileSessionModelTests` (existing `Session` driver and
effect-extraction helpers; TDD order):

- PO1 (I4, D2): a claim followed by a surface report at a new grid emits
  exactly one effect, a resize at that grid; the same report without a prior
  claim -- including on an externally pinned pane whose grid moves -- emits
  no resize.
- PO2 (I5): repeating the facts after a renewal, and the renewal's own echo,
  emit no further resize.
- PO3 (D2, I6): the standing claim ends on release, on connection end, on an
  error response, and on an external release -- an unpinned-stating record
  decoded after the latest request's success response. It survives every
  surface report, whatever pinnedness it carries -- including reports
  showing the pane already pinned at exactly the claimed grid, which must
  not confirm it, and reports repeating the pre-claim unpinned state after
  confirmation -- and a momentary nil-grid report (renewal still fires on
  the next real grid change). Includes the already-pinned scenario:
  claiming a pane another client pinned at the same grid, unrelated
  replica reports do not confirm, the request's success response does, and
  an unpinned record afterwards still ends the claim. Includes the
  ordering scenario: the same unpinned record ends the claim decoded after
  the success response and does not decoded before it.
- PO4 (existing test hygiene): `geometryGesturesSendTheCurrentGrid` currently
  reports a changed grid on a pinned pane and discards the effects; after this
  change that path renews, so the test must assert the renewal rather than
  silently exercise it. No other existing kit test changes meaning
  (`ClaimControlTests`, `ClaimGestureTests`, `ObserveSurfaceTests`,
  `ContentBoxTests` untouched).

Kit-level, for the placement value (D1):

- PO5 (I1-I3): varying the obscured height against a fixed content box
  changes only where the drawn rectangle sits -- the grid, metrics, and
  pixel extent take no keyboard input, provable from the seam's API -- the
  content's bottom edge stays pixel-aligned at the visible bottom, and a
  negative measurement clamps to zero. The drawn frame and the
  gesture-to-cell mapping follow the same offset: a point over a visible
  row resolves to that row at any obscured height.

View-level, for the UIKit wiring only (simulator run via
`scripts/ios-app.sh simulator`):

- PO6 (D1 wiring): keyboard show/hide slides the content with the bar,
  bottom rows visible above it, top rows clipped, no rescale on either a
  claimed or an observed wide pane; a claim made while the keyboard is up
  names the same grid as one made with it hidden; the scroll chrome sits
  over the visible rows with the keyboard up, and a scroll gesture there
  moves the rows under the finger.
- PO7 (D2 end to end): rotation while claimed renews automatically (transient
  fit-scale, then native snap); rotation after Release or after a Mac
  take-back does not.

Server-level, for the ordering premise I6 leans on:

- PO8 (I6 premise): the server writes a pane-resize request's response
  before any tape record that resize emits on the same connection, so a
  record behind the response is post-claim truth.

## Non-goals

- Ending the standing claim when another client re-claims while the pane
  stays pinned. No renewal loop is possible (renewals fire only on this
  phone's grid changes), so the residual behavior -- this phone re-imposes
  its grid on its next rotation -- is the declared last-writer-wins
  semantics. If wanted later: end the claim on a record pinned at a grid
  other than the claimed one, decoded after the latest request's response.
- Persisting the standing claim across launches or reconnects. After a
  reconnect the user re-claims deliberately; no surprise resizes on resume.

## Accepted risks

- iPad floating/undocked keyboards can put the bar in odd positions; the
  obscured-height measurement clamps at zero and otherwise follows the bar,
  which is no worse than today's shrink-to-bar behavior.
- While the keyboard is up, the top rows of a full-screen TUI are off-screen
  by design; dismissing the keyboard restores the full grid.

## Rejected ideas

- Correcting for the keyboard inside `contentBox`, or keeping a second
  keyboard-absent box beside the shrinking one: two readings of the same
  region is exactly the drift `MobileContentBox` exists to prevent.
- Feeding keyboard height to the model: pixels do not belong in the model.
- The view re-dispatching `claimRequested` on rotation while pinned: `pinned`
  cannot distinguish this phone's claim from another client's, so the view
  would renew claims it never made. The standing claim is the memory that
  fixes that, and the model is the only place it can live.
- Dropping the confirmed/pre-echo distinction (I6): two fewer states, but the
  phone would then re-pin a pane the Mac's user deliberately took back, on
  every rotation. The wart is worth the extra state.
- Detecting external release from surface facts, gated on a prior pinned
  observation: the facts are layout-coalesced (a pin+unpin pair applied in
  one runloop turn merges into one net report that never satisfies the
  gate) and lawfully lag the response; the tape stream already orders
  pinnedness against responses and needs no gate.

## Implementation discretion

- Where and how the root controller measures the bar's rise, and the exact
  shape of the placement value, so long as I3 and PO5 hold.
- The standing claim's internal representation in `MobileSessionModel`,
  including how the pending request id, the response, and record
  pinnedness are matched at the decode point.

## Critical files

- `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionModel.swift`
- `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionEvent.swift`
- `ios/DanTermMobileKit/Tests/DanTermMobileKitTests/MobileSessionModelTests.swift`
- `ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileRootViewController.swift`
- `ios/DanTermMobileApp/Sources/DanTermMobileApp/TerminalSurfaceView.swift`
- `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileObserveSurface.swift`
  and `ios/DanTermMobileApp/Sources/DanTermMobileApp/TerminalScrollChromeView.swift`
  (the drawn-rectangle consumers D1 offsets)
- A new placement value and its tests in `DanTermMobileKit` (name at the
  implementer's discretion).
- Header-comment updates where the claim contract is stated:
  `MobileSessionEffect.swift`, `MobileSurfaceGrid.swift`,
  `MobileSessionController.swift`.

## Verification

- Kit tests: `swift test --package-path ios/DanTermMobileKit` (also runs in
  the gate via `scripts/run-test-suite.sh`), then the full `just test`.
- App: `scripts/ios-app.sh simulator`, walking PO6 and PO7 against a live Mac
  DanTerm instance.

D1 lands first, or with D2/D3 in one commit -- never D2 alone: without the
keyboard-stable box, a keyboard toggle still changes `nativeGrid`, and the
standing claim would renew at the keyboard-shrunken grid on every show and
hide, letting keyboard state reach a claim request (I1). TDD order governs
test-before-code within each change, not the order between them.

## Implementation notes

- The placement value is `MobileSurfacePlacement`: the content box plus the
  obscured height quantized to backing pixels. `MobileObserveSurface`'s
  `drawnFrame(in:)` and `cell(at:in:)` now take the placement instead of the
  bare box, and the box-taking forms are gone, so no consumer can read the
  drawn rectangle without the offset. Two `ContentBoxTests` call sites now
  pass a rest placement (obscured height 0); their meaning is unchanged.
- The root controller measures the rise in `viewDidLayoutSubviews` as
  `terminalView.frame.maxY - bottomBar.frame.minY` and passes it raw; the
  clamp and the quantization live in the kit value, where PO5 tests them.
- PO6 verification here: kit tests (PO5) plus a simulator launch smoke --
  the app boots and the bar sits at its rest position with the terminal
  bounds above it. The interactive half of PO6 (keyboard slide/clip, claim
  parity with the keyboard up, scroll-chrome alignment during a gesture)
  needs a live Mac DanTerm instance and touch input, so it remains for the
  user's walk with `scripts/ios-app.sh simulator`.

## Commit progress
- [x] 1. D1: keyboard-stable content box and the placement offset (I1-I3, PO5-PO6)
- [ ] 2. D2/D3: model-owned standing claim and rotation renewal (I4-I6, PO1-PO4, PO7-PO8)
