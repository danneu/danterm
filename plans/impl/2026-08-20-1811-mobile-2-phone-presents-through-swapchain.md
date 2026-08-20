# MOBILE-2 pivot: the phone presents through the swapchain, not around it

Source: MOBILE-2 in `docs/scratch/2026-08-18-construction-audit.md`
(`#mobile-2`), verified against the tree on 2026-08-20. The ordering X5
asked for is satisfied: FRAME-1 (`3bea76c5`), FRAME-3 (`2a68270f`,
`13db5f73`), DRAW-1 (`82e5acf1`), MOBILE-1 (`76aed4ab`) and MOBILE-4
(`3e99c1a1`) are all on `master`. MOBILE-5 waits on this.

## Problem

Every published frame on the phone replans every row and repaints every pixel
of the grid, whatever moved, once per display-link tick for as long as output
arrives.

`TerminalSurfaceView#displayTick`
(`ios/DanTermMobileApp/Sources/DanTermMobileApp/TerminalSurfaceView.swift`)
drains `(terminal, damage)` from `PaneReplica.drainPresentation()`, never reads
the damage, plans with the stateless free `planFrame(for:presentation:)`
(hardcoded `.plan(reusing: nil, damage: .full)` in
`lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift`),
and calls `TerminalFrameBackingStore.renderFull`. Buffer rotation is a parallel
implementation, `MobilePresentationPolicy`
(`ios/DanTermMobileKit/Sources/DanTermMobileKit/MobilePresentationPolicy.swift`),
whose entire damage model is one Bool.

The engine already computes the damage and the replica already returns it.
`TerminalFrameSwapchain`
(`lib/TerminalCore/Sources/TerminalRenderExecution/TerminalFrameSwapchain.swift`)
already owns the discipline the phone needs -- per-buffer stale-damage
composition, acquire-a-free-detached-buffer, `apply(plan:damage:)` with
`renderFull` as the fallback, a pending presentation with retry -- and
`PaneFramePlanner`
(`lib/TerminalCore/Sources/TerminalRenderPlanning/PaneFramePlanner.swift`)
already replans only damaged rows. Both are public, both already compile for
iOS (research/35 F2 ran the swapchain on device unchanged), and the phone
already links `TerminalRenderExecution` and `TerminalRenderPlanning`.

Load-bearing premises, checked:

- `TerminalFrameBackingStore.apply(plan:damage:)` takes the `TerminalDamage`
  value end to end (FRAME-3) and refuses `.full`, a mis-sized value, or a grid
  mismatch with the store untouched.
- Every `Terminal` the replica constructs (`PaneReplica.init(checkpoint:)`,
  `replace(with:)` on sync, `reset`) starts with full damage
  (`Terminal.swift` init: `TerminalDamage(rowCount:isFull:true)`), so the
  first drain of any new stream is `.full`.
- The swapchain's in-use premise on iOS: research/35 F2 observed `isInUse`
  false right after assignment and true once on screen -- the same shape the
  Mac assumes -- and the phone's present tick already trusts it the same way.
- The phone's two-tick render/publish split has no surviving reason. It was
  written (`f3acd14c`) to keep presentation headless-testable before the
  swapchain was reachable; the swapchain is headless-testable through its
  injected in-use predicate (`FrameSwapchainTests`), and the Mac attaches in
  the same call that renders (`SwiftTerminalSessionView#presentAttempt`).

## Decision

Delete the parallel implementation. The phone's presentation becomes a thin,
headless-testable presenter in `DanTermMobileKit` that owns one
`PaneFramePlanner` and one `TerminalFrameSwapchain` per fitted surface, and
`TerminalSurfaceView` drives it from the display link:

- On a tick with a drain pending: drain the replica, and if the drain carries
  damage, plan with it and `publish(plan:damage:)`; an empty drain publishes
  nothing (the Mac's `planIfNeeded` gate, `guard pendingDamage != .none`).
  The one exception is a presenter that has never presented: its first tick
  publishes `.full`, the phone's analogue of the Mac's `rerenderCurrentPlan`.
  On a tick with nothing to drain but a pending presentation:
  `retryPendingPresentation()`. Whatever store comes back is attached to the
  layer on that same tick.
- `MobilePresentationPolicy` and `PresentationPolicyTests` are deleted. The
  phone keeps no damage value of its own: the engine owns undrained damage and
  the swapchain owns per-buffer stale damage. The one phone-side bit is "a
  drain is pending", set where today's `noteDamage()` calls sit (`apply`,
  `scrollViewport`, `ensureSurfaces`, `reset`).
- The presenter is rebuilt wherever the stores are rebuilt today (grid or
  metrics change in `ensureSurfaces`, and `reset`). A rebuild within the same
  stream (grid or metrics change) keeps the attached store on the layer, as the
  Mac's `displayedStore` is kept. `reset` is a stream replacement, not a
  rebuild: it clears the layer's contents, as today, so no pane ever shows
  another pane's pixels.
- The presenter takes the in-use predicate as an input with the IOSurface
  default, so kit tests steer it exactly as `FrameSwapchainTests` does.

This is the audit's ideal with one pivot: its second paragraph ("change
`hasDamage: Bool` to an accumulated `TerminalDamage`") would make the phone a
third owner of damage beside the engine and the swapchain. Not taken (RI1).

## Invariants

- I1. Every frame the phone attaches is byte-identical to a from-scratch
  `renderFull` of the plan it was published with -- across buffer rotation,
  scroll streams (shift damage), a coalesced publish retried later, a
  mid-stream sync replacement, `reset`, and a grid or metrics change.
- I2. Damage is never discarded: a buffer that missed publishes renders the
  union of everything since it last presented, and a one-row change on a
  settled screen renders incrementally (the swapchain's `lastRenderedDamage`
  is not `.full`), with only damaged rows replanned.
- I3. A plan is reused only against the stream it was planned for. The
  presenter is the only drainer of the replica, and a fresh `Terminal` drains
  `.full` before anything else can drain it, so the first frame after any
  replica terminal replacement (checkpoint restore, sync, reset) and after any
  grid change is planned and rendered in full.
- I4. Idle costs nothing: a drain that yields no damage publishes nothing and
  attaches nothing (records that damage nothing -- focus, write, a no-op
  resize, a scroll clamped in place -- cause no presentation); a tick with
  nothing to drain and nothing pending pauses the display link; the link
  resumes on the next record, local scroll, surface rebuild, or reset.
- I5. A stream replacement shows no stale pixels: `reset` detaches whatever the
  layer holds, so a pane selected before its first synchronization draws nothing
  rather than the previous pane's last frame. A same-stream rebuild keeps the
  attached store until the rebuilt presenter's first frame replaces it.
- I5b. A freshly built presenter presents a full frame on its first tick even
  when the drain is empty -- a metrics-only rebuild (rotation, display scale,
  entering a window) damages no terminal row, and the layer must not keep
  showing the old store at the new bounds until the next record arrives.
- I6. Only the display-link tick publishes, retries, or attaches; records,
  local scrolls, layout, and reset only mark a drain pending. The attached
  surface is never the render target, no store renders while reported in
  use, and a publish with no free detached buffer coalesces into one pending
  presentation that a later tick presents with the newest plan. A pending
  presentation still completes after the replica leaves `.exact`, as today.
  Attach never runs inside a UIView animation context.
- I7. The shell's observable signals keep their meaning: `didPublishFrame`
  fires exactly when a newly rendered frame replaces the attached one (and
  so no longer fires for a damage-less record); `didLayout`, replica-state
  and replica-facts callbacks are untouched. A tick that finds no presenter
  yet (no extent fitted) drains nothing and leaves the drain pending for the
  layout pass to pick up.

## Proof obligations

Kit tests, headless on the macOS host (`swift test --package-path
ios/DanTermMobileKit`), driving a `PaneReplica` with tape records and the
presenter with an injected in-use predicate; byte equality is a lock-and-compare
of the presented store's IOSurface bytes against a scratch store's `renderFull`
of the same plan.

- PO1 (I1): every presented store equals a from-scratch render across a
  scrolling record stream, a coalesced-then-retried publish, a sync
  replacement mid-stream, and a rebuild after a grid change. The scroll case
  must be output-driven while following (fed newlines): a local
  `scrollViewport` records `.full`, so only feed-driven scrolls exercise the
  shift path.
- PO2 (I2): a one-row change on a settled screen presents incrementally
  (`lastRenderedDamage` not `.full`, one damaged row) and still satisfies PO1.
  "Settled" means every swapchain buffer has presented once; before that each
  buffer's first render is necessarily full.
- PO3 (I3, I5): the first presentation after `reset(checkpoint:)`, after a sync
  replacement, and after a grid change is a full render; `reset` reports no
  attached store until that first frame, while a same-stream rebuild still
  reports the previously attached one.
- PO4 (I4, I5b): an idle presenter reports no tick needed and a forced tick
  presents nothing; a record that damages nothing presents nothing; a record,
  a local scroll, and a rebuild each make it report a tick needed; a rebuilt
  presenter presents a full frame on its first tick with an empty drain.
- PO5 (I6): with every detached store reported busy, a tick presents nothing
  and the presenter still reports a tick needed; when one frees, the retry
  presents the newest plan, never into the attached store. A second scenario
  coalesces a publish, then moves the replica out of `.exact` (a gap, so the
  next drain yields nothing), then frees a buffer: the tick must present the
  pending plan and only then report idle -- a failed drain never ends the tick
  while a presentation is pending. This is the replacement for
  `PresentationPolicyTests`, which go with the policy.
- PO6 (I7): a drain marked pending before any extent is fitted drains nothing
  and presents nothing; fitting the presenter then publishes the first frame in
  full, with no damage consumed in between. The `didPublishFrame` wiring in
  `MobileSessionController` is reached by reading; there is no shell test
  target (`MobileSessionController.swift` says so).
- PO7: `FrameSwapchainTests` and `FrameBackingStoreTests` in
  `lib/TerminalCore` stay green unchanged -- the engine side does not move.

## Non-goals / Accepted risks / Rejected ideas

- N1. MOBILE-5 (replica off the main actor). The presenter is the
  `(plan, damage)` consumer MOBILE-5 wants to hand the main actor, but moving
  the replica is its own item.
- N2. Any engine change: no new swapchain, store, damage, or planner API.
- N3. Theme on the phone stays `.dark`; cursor presentation stays what the
  terminal reports.
- N4. On-device measurement. The audit says no iOS instrument exists; PO2 is
  the in-repo evidence the work narrowed, and it is a correctness observation,
  not a number.
- N5. Editing the historical plan that introduced the policy
  (`plans/impl/2026-08-14-2129-step0-ios-client-app.md`, "surface ownership is
  decided by the kit's presentation policy"); plans are history. The audit's
  MOBILE-2 line is ticked on completion, and research/35 D2 ("a coalesced
  publish is retried on a later tick") stays true.
- AR1. The phone inherits the incremental path's bugs (translation stale
  strips, ink-reach ledger) that only the Mac exercises today. Accepted: the
  code is shared, pinned byte-identical on both sides (PO1, PO7), and a bug
  found on the phone is a bug on the Mac.
- AR2. iOS has no real-UIKit pin that "a detached surface reported free stays
  free" under the publish-attach-retry cadence (research/35 F2's stated
  uncertainty). Accepted: today's phone code already trusts `isInUse` per
  tick; this change adds no new reliance.
- RI1. The finding's own "accumulate a `TerminalDamage` in the policy": a
  third owner of damage that can drift from the two that already exist.
- RI2. The finding's cheaper fallback (keep the policy, pass the drained
  damage to `apply` per store): wrong for rotating buffers -- a store that
  missed publishes needs the union, which is what the swapchain's per-buffer
  stale damage is.
- RI3. Keep the two-tick render/publish split inside the swapchain model: the
  swapchain renders inside `publish`, the Mac attaches on the same call, and
  the split's only stated reason (headless testability) is met without it.

## Implementation discretion

- The presenter's exact API, provided I4-I7 hold and no damage value is stored
  outside the engine and the swapchain. The "drain pending" bit and the
  not-yet-fitted state live in the kit, so PO6 can drive both headlessly; the
  view only reports records, scrolls, layout, and reset into it.
- Whether the planner is rebuilt on a metrics-only change (it need not be:
  plan rows are metrics-independent and the planner refuses on a grid
  mismatch) or only the swapchain is.

## Critical files

- `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobilePresentationPolicy.swift`
  -- deleted; replaced by the presenter file in the same directory.
- `ios/DanTermMobileKit/Tests/DanTermMobileKitTests/PresentationPolicyTests.swift`
  -- deleted; replaced by the presenter tests (PO1-PO5).
- `ios/DanTermMobileApp/Sources/DanTermMobileApp/TerminalSurfaceView.swift`
  -- `displayTick`, `ensureSurfaces`, `reset`, the `stores`/`policy` fields.
- `ios/DanTermMobileKit/Package.swift` -- the kit target gains
  `TerminalRenderPlanning`; the test target gains `TerminalRenderPlanning` and
  `TerminalRenderExecution`; declared per
  `docs/design/2026-08-17-package-owns-its-targets.md`. Both already
  cross-compile for iOS, which the portability gate checks for the kit's test
  target too.
- Reuse, not rewrite: `TerminalFrameSwapchain`, `PaneFramePlanner`,
  `TerminalFrameBackingStore.apply`, `PaneReplica.drainPresentation`. Byte
  comparison in kit tests is a lock-and-compare of two stores' IOSurface
  bytes; `BitmapTestSupport` is private to the engine's test target and is
  not shared.

## Verification

1. `swift test --package-path ios/DanTermMobileKit` (PO1-PO5).
2. `swift test --package-path lib/TerminalCore --filter 'FrameSwapchain|FrameBackingStore'` (PO7).
3. `./scripts/ios-portability-gate.sh --package ios/DanTermMobileApp` and
   `--package ios/DanTermMobileKit` -- the iOS compile of the presenter.
4. `just test` for the gate.
5. Live check on the phone or simulator: observe a TUI touching a few rows of a
   settled screen and a full-screen flood; both must look right and the flood
   must not regress visibly (the swapchain's coverage barrier handles it).
   Rotate the device and bring the keyboard up and down on a quiet pane: the
   grid must redraw at the new scale without waiting for output (I5).
6. Tick MOBILE-2 in `docs/scratch/2026-08-18-construction-audit.md` with the
   commit hash.

## Implementation notes

- The presenter is one object that lives as long as the view and is refitted in
  place, rather than one rebuilt beside the stores. The plan said "the presenter
  is rebuilt wherever the stores are rebuilt today"; keeping one object is what
  lets the pending-drain bit and the not-yet-fitted state outlive a rebuild,
  which PO6 requires of them.
- A fit rebuilds both the planner and the swapchain, including on a
  metrics-only change (the plan left that to discretion). The fresh buffers hold
  no pixels, so that first frame is full whatever the planner retained, and one
  rule is simpler than two.
- `DanTermMobileApp` dropped its direct `TerminalRenderPlanning` and
  `TerminalRenderExecution` dependencies. The view no longer names a plan, a
  frame store, or render metrics, so the engine's render surface now reaches the
  phone only through the kit.
- `MobileFramePresenter.presentation(for:)` is public so the presenter and the
  byte-equality tests plan under one statement of the phone's presentation
  inputs, instead of two that could drift.

## Follow Up

- Tick MOBILE-2 in `docs/scratch/2026-08-18-construction-audit.md` with this
  commit's hash (verification step 6). It cannot go in the commit it names.
- Run verification step 5 on the phone or the simulator: a TUI touching a few
  rows of a settled screen, a full-screen flood, a rotation, and the keyboard up
  and down on a quiet pane. Nothing here is reachable headlessly.
- MOBILE-5 (the replica off the main actor) is unblocked. `MobileFramePresenter`
  is the `(plan, damage)` consumer that item wants to leave on the main actor.
