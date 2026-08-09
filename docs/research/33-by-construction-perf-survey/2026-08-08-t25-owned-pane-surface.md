# T25: the view owns the pane surface -- IOSurface swapchain, one render path

## Problem, outcome, evidence

The T9 mirror deleted glyph submission from the scrolled draw and replaced it
with something worse on the workload it exists for: on the paced stream
(`saturate-scrollback.sh --stream 500`), process CPU rose 44.1% to 64.1% of a
core against the last pre-mirror commit (research/33 `F24`). The mechanism is
structural, not a defect in the mirror: a layer-backed `draw(_:)` records a
display list that CoreAnimation renders asynchronously into a Metal-backed
store, so the mirror's per-frame image blit forces CA to capture the whole
frame on the CPU and upload it as a fresh GPU texture -- two full-frame copies
per drawn frame, uncacheable by construction, plus a measured main-thread
stall waiting on that queue. The `D7` addendum parked full surface ownership
with exactly this trigger ("if the blit shows up in the gates"); `F24` is that
observation.

The desired outcome: displaying a frame costs zero full-frame copies. The
render server reads the view's own pixels directly.

Load-bearing premises, all measured or already decided:

- The blit's cost is CA's frame capture plus texture upload, not colorspace
  conversion and not the mirror's own maintenance (`F24`: 1,923 of 2,626
  CG-queue samples in the copy; mirror upkeep 364 main-thread samples).
- The same display-list machinery is also why glyph drawing pays per-occurrence
  off-main-thread bounds recomputation, the largest single cost previously
  found in the app (`17/F6`). Owning the surface removes that path for every
  regime, not only scrolls.
- AppKit's backing store cannot be written or translated directly (`F22`); the
  only zero-copy display route is view-owned memory the render server can
  texture from, which is what a CALayer displays when its contents is an
  IOSurface.
- A row shift is integral in backing pixels by construction, and the owned
  store already realizes translate-plus-damaged-render byte-exactly behind
  `FrameBackingStoreTests`.
- H1/L8 stand: this is still the AppKit/CoreGraphics renderer. No Metal
  dependency, no GPU renderer.

## Decision

The frame store stops being a paced-regime mirror behind AppKit's store and
becomes the display surface itself. The view owns a small swapchain of
IOSurface-backed frame stores. A publish that acquires a buffer renders into
it (incrementally when accumulated damage permits, from scratch otherwise)
and the layer then displays that buffer directly; a publish that finds no
acquirable buffer neither renders nor blocks, and instead coalesces into the
pane's one pending presentation, which renders when a buffer frees. `draw(_:)`'s content path, the
AppKit backing store, the mirror validity bit, the pending-damage/dirty-rect
fallback machinery, and the draw-seam fold all delete: there is one render
path for every regime, and an AppKit-initiated redisplay can only reattach the
current buffer, never require re-rendering.

## Invariants

- I1 **Pixel equivalence.** Every displayed frame is byte-identical to a
  from-scratch render of the published plan, in every regime and across
  every buffer rotation, resize, scale change, and theme change.
- I2 **Zero-copy display.** Displaying a frame performs no full-frame pixel
  copy and no in-process texture upload. Both stack families `F24` attributed
  are absent from a steady-state stream profile: the CPU frame capture
  (`create_image_by_copying` -> `CGBlt_copyBytes`) and the GPU upload
  (`MetalContext::update_image` -> `copy_image_to_texture`).
- I3 **Swapchain safety.** A buffer is written only after it is both detached
  from the layer and confirmed not in use by the render server. Detachment
  alone is not enough: the render server scans asynchronously and can still
  be reading the previous surface after the layer's contents point at the
  new one. Acquisition therefore requires `IOSurfaceIsInUse` to report the
  surface free -- which, for a surface we have detached and will not
  reattach, cannot become true again -- provided the detachment's transaction
  has committed before eligibility is checked, so the render server cannot
  still be about to acquire the surface for a queued presentation. Implicit
  contents animation is disabled so a presentation layer never adds a second
  reference. When no buffer is acquirable, the publish coalesces into
  accumulated damage rather than rendering or blocking, and the pane is left
  with a pending presentation: a pending presentation retries acquisition on
  the existing publish-pacing signal (`D8`'s one-per-refresh tick), without a
  display link and without depending on further terminal output, and stops as
  soon as the latest plan has rendered. So the last published plan always
  reaches the screen even if output stops immediately after it.
  A buffer acquired for rendering is first brought current by applying the
  damage accumulated since it was last displayed (shifts composing per `D7`'s
  rules), escalating to a full render whenever composition escalates or the
  buffer's content cannot be trusted. Content trust depends on every
  presentation input that decides pixels: a fresh buffer, or a change of
  geometry, backing scale, theme, or window color space, forces the full
  render.
- I4 **One render path.** Every regime -- paced shift, `.full` flood, first
  frame, resize, occlusion return -- renders through the owned store. No
  glyph run is submitted at a draw seam, and no state falls back to a
  region-wide redraw of undamaged content.
- I5 **Presentation unchanged.** The view area outside the grid shows the
  theme default background, and surface pixels display in the window's color
  space with output colors matching today's across display-profile changes.
- I6 **Power contract holds.** Event-driven display, no periodic work, no
  display link; an occluded pane renders nothing and a newly visible pane
  displays one complete current frame (register rows L1, L3, H4). A pane with
  a pending presentation is not quiescent -- its retries are bounded by that
  pending plan and stop when it renders -- so the no-periodic-work contract
  is about panes with nothing pending.

## Interface changes

- The benchmark draw bracket and its dirty-rect/fallback observation move
  from `draw(_:)` to the surface render site, so the three serialized-draw
  workloads' deciding metric changes meaning: it will now contain glyph
  rasterization that previously ran on CA's queue outside the bracket. Per
  `agent-docs/terminal-performance.md`, directional claims on those cells
  stop until their rules are recalibrated; the paired ladder still runs as
  the non-regression check with that caveat recorded.
- The UI harness's drawn-row and clip-rect pins move to the same seam,
  restated as which rows the store rendered per publish.

## Proof obligations

- PO1 (I1): the existing headless byte-equality gates hold on the
  IOSurface-backed store across the full `D7` scenario matrix, including
  IOSurface row-stride alignment; plus byte-equality across buffer rotation
  (a reacquired stale buffer brought current equals a from-scratch render).
- PO2 (I2): the deciding evidence is the profile, not a CPU number. Re-run
  `F24`'s paired stream measurement and show both attributed stack families
  absent from the same steady-state profile: the capture path
  (`create_image_by_copying` -> `CGBlt_copyBytes`) and the upload path
  (`MetalContext::update_image` -> `copy_image_to_texture`). Process CPU is
  recorded as a descriptive figure with the arms named, not as a pass
  threshold: `F24`'s 44.1% was uninterleaved and decides nothing, and no
  threshold is set here until a contemporaneous controlled rule is
  calibrated.
- PO3 (I3, I4): harness pins for the swapchain: a buffer is never the render
  target while attached or while reported in use; a publish that finds no
  acquirable buffer coalesces, and the coalesced plan renders in full on a
  later retry with no further publishes arriving; accumulated-damage
  application and its escalation to full render; full rebuild on each
  trust-breaking input -- resize, backing-scale change, theme change, and a
  window color-space change at unchanged scale and geometry; occlusion return
  and first frame display a complete frame without a draw-seam path. Two pins
  run against real AppKit, covering the premises the harness cannot model:
  repeated contents swaps produce no contents animation, so a released buffer
  has no live presentation-layer reference; and eligibility is only ever
  checked after the detaching transaction commits, with a surface reported
  free at that point staying free for the whole window in which the swapchain
  writes it. That second pin is a viability gate, not a tuning knob: it is
  the only thing standing between the swapchain and writing a surface the
  render server is still scanning. If it fails, this route stops and the plan
  returns for a retirement rule with a provable completion boundary --
  waiting a fixed number of generations does not bound a stalled render
  server, so depth and age are not a substitute.
- PO4 (I5): a pixel proof that the letterbox region shows theme background,
  that grid output colors are unchanged from today at the same window color
  space, and that a same-scale move to a display with a different profile
  produces correct colors rather than the previous buffer's.
- PO5 (I6): existing quiescence gates stay green (no recurring frames for
  unchanged content, hidden panes render nothing). `t4-publish-rate.sh`'s
  publishes-per-draw ratio is retired -- with the draw seam deleted it would
  read 1.0 by construction and detect nothing. It is replaced by independent
  counters for frame publications, owned-surface renders, and AppKit layer
  display callbacks, asserting at most one render per publish, zero renders
  caused by an AppKit-initiated redisplay, and -- for a burst that coalesces
  several publications into one render -- that the last publication does
  render and the pane then goes quiet with no pending presentation left.
- PO6: calibrated ladder run recorded with the bracket-change caveat, and
  `t5-scroll-amplification.py` shows scrolled-frame glyph submission bounded
  by the composed damage since the acquired buffer was last current, with
  the flood arm's region render intact. `F23`'s 1,086 glyphs per frame is
  not the ceiling: it measured one mirror current every frame, whereas a
  buffer reacquired from a depth-N swapchain is N generations stale and must
  redraw every row exposed since, so the bound scales with swapchain depth.

## Non-goals

- A Metal or GPU renderer, or any new render thread: rendering stays
  synchronous CoreGraphics on the main thread (H1, L8, B14).
- Changing the damage representation, the planner, or the shift contract --
  `D7`'s engine half is untouched.
- T14's derived glyph halo (queued behind this; it shrinks the damaged-row
  render, measured at 1/20th of the blit cost in `F24`).
- Recalibrating the benchmark rules inside this change; the plan only
  records that the old cells' meanings changed.

## Accepted risks

- **Memory.** Two to three grid-sized surfaces per pane (~28 MB each for a
  full-screen 2x pane) replace one mirror bitmap plus AppKit's own
  backing store. Net growth is at most one to two frame stores per visible
  pane, paid only by panes that have displayed.
- **Main-thread rasterization.** Glyph rendering moves from CA's async queue
  into the publish path. It is bounded by the publish deadline (`D8`: one
  publish per display refresh) and measured small (~0.5 ms per full 179x66
  frame), and it deletes the larger `17/F6` off-thread cost -- but
  main-thread occupancy during floods rises, and the ladder's recalibrated
  bracket is what will price it honestly.
- **Stale-buffer glyph work scales with depth.** A buffer reacquired from a
  depth-N swapchain redraws every row exposed over N generations, so paced
  scrolls submit more glyphs per rendered frame than T9's always-current
  mirror did. This is inherent to multi-buffering, which the swapchain is
  already committed to; T14's derived halo is the lever that shrinks it.

## Rejected ideas

- **Keep `draw(_:)` and hand CA an IOSurface-backed CGImage.** No public
  contract makes that zero-copy; CA may still capture, and the fix would
  rest on undocumented behavior exactly where `F22` taught us not to trust
  it.
- **Single owned surface without a swapchain.** Writing the displayed
  surface while the render server scans it tears; the `D7` addendum already
  named multi-buffering as the cost of ownership.
- **Regime-conditional ownership** (own the surface only in the paced
  regime, keep `draw(_:)` elsewhere). That preserves two display paths and
  the validity ledger between them -- the shape whose seams produced both
  `F23`'s latent halo defect and `F24`'s mispriced blit. One path is the
  structure in which the problem cannot recur.

## Commit progress

- [x] 1. Viability gate: PO3's two real-AppKit pins for IOSurface layer
       contents (no implicit contents animation; a detached surface reported
       free stays free). If the gate fails, the route stops here.
- [x] 2. IOSurface-backed frame store behind the byte-equality gates (PO1).
- [x] 3. Surface swapchain: acquisition, coalescing, pending presentation,
       trust-breaking inputs, with the headless PO3 pins.
- [x] 4. Own the pane surface: one render path, draw seam deleted, benchmark
       bracket / harness pins / PO5 counters moved with it (PO4, PO5).
- [x] 5. Record the re-measurement and tick the T25 ledger (PO2, PO6).

## Implementation notes

- Commit 1 (viability gate): freeing is presentation-driven, not
  detach-driven. A detached surface is not released by the detaching commit
  alone: with no further frames presented it stayed in use through 5 seconds
  of quiescence, and a cold pipeline once held it across 4 subsequent
  presentations (steady state: released after 1). The gate pin therefore
  keeps presenting frames while waiting for the surface to free, then
  asserts monotonic freedom from that point -- matching I3's premise, which
  requires free-implies-stays-free, not prompt freeing. Consequence for
  commit 3: the swapchain needs depth 3. With depth 2 a cold pipeline can
  wedge, because a retry that cannot acquire a buffer presents nothing and
  so never flushes the pipeline holding the only detached buffer. A
  standalone probe running the 3-deep swapchain at ~110 Hz for 25 s
  recorded zero acquisition skips.
- Commit 1 due diligence (`F22`'s lesson, ahead of PO2): a 10 s `sample` of
  that probe showed zero occurrences of the `F24` stack families
  (`CGBlt_copyBytes`, `copy_image`, `create_image_by_copying`,
  `CABackingStoreGetFrontTexture`) and no `CA::CG::Queue` thread at all --
  the zero-copy premise holds at probe scale before the seam moves. PO2
  stays the deciding in-app proof.
- The animation pin disables implicit contents animation via the layer's
  `actions` dictionary (`["contents": NSNull()]`); commit 4 uses the same
  mechanism the pin proves.
- Commit 3: trust-breaking inputs are realized as whole-swapchain
  replacement -- the owner discards the swapchain on geometry, backing
  scale, theme, or window color-space change, and fresh buffers force full
  renders by construction (`isCurrent`). The swapchain therefore has no
  distrust API and never changes shape in place; the view-side replacement
  pins land with commit 4, where those inputs arrive. Acquisition prefers
  the least-stale free buffer so bring-current redraws the fewest exposed
  rows.
- Commit 4: the view shows the surface as its own layer's contents rather
  than through a dedicated sublayer, with `wantsUpdateLayer` true so AppKit
  allocates no backing store and never calls `draw(_:)`. `updateLayer()` --
  AppKit's redisplay entry point -- is the counted, do-nothing site I4
  demands. `layerContentsPlacement = .topLeft` is what keeps the grid
  unscaled at the top-left with the theme background in the letterbox
  strip; a probe measured the composed result before the code was written,
  because a wrong gravity, flip, or contents scale fails no other gate in
  this plan (every other gate stops at the store's memory). That probe is
  now PO4's pin, in `tests-ui/IOSurfaceLayerContentsTests.swift`, reading
  back through `CALayer.render(in:)` -- not the render server's path, but
  the same layer geometry rules, and it needs no screen-recording grant.
- Commit 4: trust-breaking inputs split two ways. Geometry, backing scale
  and window color space are compared as values (`SurfaceInputs`), so the
  swapchain is replaced wherever a presentation arrives; a theme change is
  an explicit discard, because no value the view holds distinguishes two
  themes that share a background. Scale and color space also re-render on
  their own, since neither produces a publish and buffers rendered under
  the old values cannot be brought current by damage.
- Commit 4: `TerminalFrameSwapchain` gained `lastRenderedDamage` rather
  than a richer return type, so the benchmark bracket can report the
  render's own damage topology without churning commit 3's pins.
  `usedDirtyRectFallback` is now structurally false and was kept rather
  than deleted: its consumers reach into the artifact schema and the
  Python validators, which is benchmark-rule territory this plan
  non-goals.
- Commit 4 live check (ahead of PO2's real measurement): a paced ~59 Hz
  stream in a slot recorded publishes and renders equal per second with
  zero layer displays and no acquisition skips, and an idle pane recorded
  nothing at all.
- Commit 5, PO2: the plan asked for `F24`'s paired measurement re-run, and it
  was run as three arms rather than two -- `F24`'s baseline and candidate
  rebuilt alongside the new one -- twice, A-B-C then C-B-A. Reproducing both
  of `F24`'s arms in the same session is what lets the new arm be read against
  its numbers, and the reversed second round retires the uncorrected-drift
  caveat `F24` filed against itself.
- Commit 5, PO6: the ladder could not run as the plan assumed. Every
  `incremental-mixed` block on the candidate arm produced 1 of 50 serialized
  draws and stalled, because draw acceptance compared the rendered rectangle
  against a frozen 6 rows and a render now brings a stale swapchain buffer
  current over composed damage. The plan non-goals recalibrating benchmark
  rules, so this was raised rather than absorbed; the user chose to fix
  acceptance in this commit. Acceptance moved onto the stimulus -- the engine
  damage the workload's producer emits -- which is where the sparse-span
  workloads already select, so the failure class is gone rather than retuned.
  The retired constant is not replaced by a bigger constant.
- Commit 5: gate coverage is read from each arm's own source tree, not
  inferred from a missing artifact key. Requiring the new evidence would make
  every comparison against a baseline older than the instrument impossible;
  excusing every absence would let a candidate whose publish path broke pass as
  an old arm. The tree cannot be faked by the failure being measured.
- Commit 5: the block artifact key is `acceptedDrawTopology`, not
  `damageTopology`, because the profiling activity artifact already publishes a
  different `damageTopology` object (per-draw histograms). The first attempt
  collided with it, and the source-tree probe silently matched the wrong one.

## Follow Up

- Re-screen the three serialized-draw rules against the moved bracket. All
  three now read `slower` by ~160% purely because the bracket swallowed the
  rasterization CoreAnimation used to replay outside it, so those cells carry
  no directional claim until their thresholds are recalibrated
  (`scripts/terminal-benchmark-calibration.py`; the caveat and the measured
  step are in `agent-docs/terminal-performance.md`).
- ~~Explain the +18.8% and +18.4% descriptive process CPU on `content-churn`
  and `style-churn`.~~ Done (`F26`): the baseline shaded the full grid on the
  GPU through CoreAnimation's display-list renderer, so its raster was in no
  CPU account at all; T25's software render (~6.2 s per 20 s, over half of it
  background fills) outweighs the ~5.2 s of encode, glyph-bounds, and commit
  machinery it deleted. Work changing account, not new frame work, and the
  sign flips with redrawn area -- which is why `incremental-mixed` and the
  paced stream fell on the same instrument.
- Retire `usedDirtyRectFallback`. It is structurally false since commit 4 --
  no rectangle AppKit chose can reach a render -- but its consumers reach
  into the benchmark artifact schema (`dirtyRectFallbackCount` in
  `TerminalBenchmarkDamageTopology`, `app/TerminalBenchmark.swift`, and
  `scripts/terminal_btop_artifacts.py`), which this plan non-goals. Delete it
  with the benchmark recalibration.
- `agent-docs/terminal-performance.md`'s "whole-process CPU per accepted
  draw" section still describes CoreAnimation's asynchronous display-list
  replay as a live blind spot the draw bracket cannot see. Owning the
  surface removes that replay, so the section's framing needs revisiting
  when the serialized-draw cells are recalibrated.
