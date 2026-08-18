# Return clamp state from terminalCell; let the swapchain own its construction inputs (S54 + S46)

## Context

Audit findings S54 and S46 in `docs/scratch/2026-08-11-simplification-audit.md`,
both verified live against the current tree (status column empty, all cited
structures present).

- **S54.** `terminalCell` (`lib/TerminalCore/Sources/TerminalCore/TerminalInteractionVocabulary.swift`)
  already computes whether a point fell inside the grid -- that is what its
  clamp does -- and throws the answer away. The view recovers it by
  re-deriving grid extents in `pointerIsOutsideGrid`
  (`app/SwiftTerminalSessionView.swift`) with different math, at six call
  sites, converting the same window point up to three times per pointer event.
- **S46.** `TerminalFrameSwapchain.init` consumes columns, rows, metrics, and
  colorSpace and stores none of them. The view mirrors them in
  `SurfaceInputs` / `swapchainInputs`, which must be assigned and cleared in
  lockstep with `swapchain` in three places; a drift would be silent (buffers
  built for the wrong geometry).
- Load-bearing premise: Swift `==` on `CGColorSpace` compares equivalent
  color spaces by value, so two separately constructed sRGB spaces are equal.
  Pinned by PO5 so a future OS change fails a test instead of shipping as
  rebuild-per-publish buffer thrash.

## Decision

**S54.** `TerminalViewportCell` gains `isInsideGrid: Bool`, default `true` in
the init, participating in synthesized `==`. `terminalCell` sets it from the
same point and geometry it already has, using the range predicate the view
used (`coordinate >= 0 && coordinate < columns * cellWidth`, and the same on
the row axis) rather than reading it back off the clamp -- the clamp derives
from a floored quotient, which can disagree with the range test by one ULP at
a boundary. The normalized cell keeps being derived by flooring and clamping.
Delete `pointerIsOutsideGrid`; each pointer path converts the window point once and
reads cell + insideness from one value. `publish()` re-derives via
`normalizedCell(at:)` against current geometry -- no persisted insideness bit,
because a stored bit goes stale exactly in the case the current code defends
(grid shrinks under a parked pointer).

**S46.** `TerminalFrameSwapchain` stores its four construction inputs
privately and exposes two queries: a full
`matches(columns:rows:metrics:colorSpace:)` for `surfaceSwapchain`, and a
metrics+colorSpace-only variant for `synchronizePresentation`, which
deliberately keeps the swapchain's own geometry (grid resizes republish
through `setGridDimensions`). The view deletes `SurfaceInputs` and
`swapchainInputs`; `discardSwapchain` drops only `swapchain` (theme stays a
discard, never a compared input). Color spaces compare as `CGColorSpace?`
with Swift `==`; nil is stored as-passed, not normalized to sRGB (that
substitution stays private to `TerminalFrameBackingStore`). The metrics
comparison stays the existing deep `TerminalRenderMetrics ==`.

The UI-test shim's fake `TerminalFrameSwapchain`
(`tests-ui/SwiftTerminalSessionViewTestShim.swift`) gains the same stored
inputs and both `matches` methods.

Two independent commits, S54 first (smaller); no ordering constraint.

## Invariants

- **I1.** Insideness is the range predicate on the raw point: within
  `[0, extent)` on both axes is inside; the exact right/bottom edge and
  negative coordinates are outside; unusable geometry yields no cell and is
  treated as outside everywhere the view asks. It is always read at the moment
  the view asks -- including the hover check in `publish`, which re-derives it
  against current geometry -- never from a value stored at an earlier event.
- **I2.** Pointer event ordering is preserved: an outside down sends the event
  then cancels link interaction; an outside up cancels (and clears
  `isPointerInside`) then sends; exactly one cancellation per outside event.
- **I3.** Policy-minted cells (`paneMenuCell`) and existing in-grid test
  literals are unchanged: the default `isInsideGrid: true` is the honest value
  for a cell not produced by clamping.
- **I4.** Swapchain reuse/replacement behavior is unchanged: reused iff all
  four construction inputs match; `synchronizePresentation` rerenders iff
  metrics or colorSpace moved at the live swapchain's own geometry; a theme
  change still discards unconditionally.
- **I5.** `matches` compares color spaces by value: independently constructed
  spaces for the same color space compare equal (no rebuild thrash);
  different spaces, and nil vs non-nil, mismatch.

## Proof obligations

- **PO1** (I1): unit coverage on `terminalCell`, exercising each axis alone so
  a column-only predicate cannot pass -- an in-grid point reports inside;
  outside-left, outside-right, and the exact right edge report outside with an
  in-range y; outside-above and the exact bottom edge report outside with an
  in-range x. The clamped-case whole-value literals in `pointNormalization`
  (`TerminalInteractionPolicyTests.swift`) gain explicit
  `isInsideGrid: false` and must fail until `terminalCell` computes the flag.
- **PO2** (I2): ordering is proved by the outcome the ordering exists to
  produce, not by counting events and cancellations separately. With an armed
  Cmd-link, an outside `.up` must open nothing (cancellation ran first), and an
  outside `.down` followed by an in-grid Cmd-up must open nothing (the down was
  delivered before the cancellation, so it cannot survive as an arm). The
  existing tests-ui up-outside pin stays green; add the down-outside sibling --
  a characterization test verified green before the refactor and held green
  through it.
- **PO3** (I3): existing whole-value `==` literals in
  `TerminalInteractionPolicyTests` and the tests-ui `menuCells` comparison
  pass unmodified.
- **PO4** (I4): new `FrameSwapchainTests` -- same four inputs match; each
  input varied alone mismatches; a geometry mismatch fails the full `matches`
  while the metrics variant still passes. Existing tests-ui
  `creationCountForTesting` pins stay green as the replacement-behavior net.
- **PO5** (I5): a swapchain built with named sRGB matches a separately
  constructed sRGB (via its ICC data); sRGB vs displayP3 mismatches; nil vs
  nil matches; nil vs sRGB mismatches. The test preamble names the risk it
  guards: `CGColorSpace` value equality going away.
- **PO6** (I1, publish-time re-derivation): a tests-ui test parks the pointer
  inside the grid over a hovered link, shrinks the grid so that stored location
  now falls outside, and publishes a frame without another pointer event; the
  hovered-link chrome must not be shown. Fails against any implementation that
  reuses an event-time insideness value.

## Non-goals / accepted risks / rejected ideas

- **Non-goal:** making the metrics comparison cheaper.
- **RI1:** the audit's identity-token idea for `TerminalRenderMetrics` --
  changes publish-path comparison semantics for unmeasured performance; out
  of scope unless a benchmark motivates it.
- **AR1:** the colorSpace comparison moves from `NSColorSpace` to
  `CGColorSpace` equality -- the domain that actually decides the pixels; two
  distinct `NSColorSpace` objects over one CG space no longer force a
  pointless rebuild.
- **AR2:** a NaN stored pointer location now yields no hover instead of
  hover; unreachable from a real `NSEvent`, and the new behavior is the sane
  one.

## Implementation discretion

- The shared move-delivery helper shape for `forwardPointerMove` /
  `flagsChanged` (each path normalizes once; `flagsChanged` still leaves
  `isPointerInside` alone, as today).
- Doc and comment updates: the `TerminalViewportCell` doc gains the flag's
  provenance framing, the swapchain file header states that it remembers its
  inputs, and the two stale `SurfaceInputs` comment mentions in the view move
  onto the `matches` call sites.

## Verification

- `swift test --package-path lib/TerminalCore` -- PO1, PO4, PO5.
- `just test-ui > .build/ui.log 2>&1` -- PO2, PO3, and the creation-count
  pins in PO4.
- `just test` as the final gate.

Critical files: `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionVocabulary.swift`,
`app/SwiftTerminalSessionView.swift`,
`lib/TerminalCore/Sources/TerminalRenderExecution/TerminalFrameSwapchain.swift`,
`tests-ui/SwiftTerminalSessionViewTestShim.swift`,
`lib/TerminalCore/Tests/TerminalRenderExecutionTests/FrameSwapchainTests.swift`,
`lib/TerminalCore/Tests/TerminalCoreTests/TerminalInteractionPolicyTests.swift`,
`tests-ui/SwiftTerminalSessionViewTests.swift`.

## Commit progress
- [x] 1. S54 -- return clamp state from `terminalCell` and delete `pointerIsOutsideGrid`
- [x] 2. S46 -- let `TerminalFrameSwapchain` own its construction inputs

## Implementation notes

- The tests-ui harness did not compile at the start of this work: its fake
  controller still declared `setGridDimensions(_:)` while the view has called
  `setGridDimensions(_:pinned:)` since commit 4c4fdabe. PO2, PO3, and PO6 all
  run there, so the shim signature was repaired as part of this commit. It is
  a one-line catch-up, and the fake ignores `pinned` because no test reads it.
- PO6 claims a 2x1 grid rather than a 1x1 one: `PaneGridOverride` refuses
  fewer than two columns, and its failable init makes a refused override a
  silent no-op at the `setGridOverride` call site. The test unwraps the
  override explicitly so a future range change fails loudly instead of
  claiming nothing.
- The view reads the window color space through one `surfaceColorSpace`
  accessor rather than converting `NSColorSpace` at each of the two call
  sites, so construction and both comparisons cannot drift on how they
  derive it.
- The PO2 ordering test was checked against a mutant -- the cancellation moved
  ahead of the press in `forwardPointerDown` -- and it fails there, so it
  really pins the order rather than only the outcome.

## Follow Up

- `just test-ui` is excluded from the `just test` gate, so it rotted unnoticed
  until this commit (the `setGridDimensions` signature drift above). Either add
  a compile-only step for `tests-ui/` to `scripts/run-test-suite.sh`, or decide
  deliberately that the harness is checked by hand.
