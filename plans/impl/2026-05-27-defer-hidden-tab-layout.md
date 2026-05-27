# Pivot: defer hidden-tab container *layout* (not construction) to first reveal

## Context

A performance audit flagged that session restore eagerly builds **and lays out**
every tab's `SplitContainerView` -- selected one visible, the rest `isHidden`.
Verified true, and slightly worse than stated: `desiredContainerShapes`
(`app/Projections.swift:609-617`) is a *total* projection over every group's every
tab, and at restore the caches are reset (`app/AppRuntime.swift:1201`), so
`computeContainerOps` emits a `.rebuild` for **every** tab across **all** groups
(`app/Projections.swift:645`). Each rebuild runs
`layoutSubtreeIfNeeded()` + recursive `applyRatios()`
(`app/SplitContainerView.swift:42-43`). A restored session with N tabs => N explicit
split-tree layout+ratio passes on the main thread at launch, N-1 of them never seen. The
recursive `applyRatios` cost scales with a tab's split count -- it early-returns on a leaf
(`app/SplitContainerView.swift:47`) -- so the win concentrates on split-heavy sessions;
a single-pane tab defers only its one `layoutSubtreeIfNeeded`.

Eager *mounting* is intentional and worth keeping: it gives instant tab switching
(`.setVisible` just toggles `isHidden`) and lets the projection stay a total
function with no "mounted set" side-input -- which keeps background-tab shape drift
trivially correct (a core DanTerm design goal). The finding's proposed fix (lazy
*construction*) trades that invariant away.

**The pivot:** keep eager construction of the NSView tree, but defer DanTerm's own
expensive layout work -- the explicit `layoutSubtreeIfNeeded()` + recursive
`applyRatios()` pass that `rebuild()` runs -- for a container until the tab is first
revealed. Result: restore runs that pass for exactly 1 container (the selected one);
each other tab runs it once, on first switch-to; a never-revealed hidden tab never runs
it. The total projection, the cache semantics, the ops, and background-drift correctness
are all untouched.

Stated precisely (this is the scope of the win, not more): the pivot defers DanTerm's
*explicit* layout/ratio pass, not AppKit's own constraint solving. A mounted-but-hidden
container stays in the view tree, so AppKit may still assign it space and autoresize it --
the crux below in fact depends on that. What the pivot removes for hidden tabs is the
N-1 redundant `applyRatios()` passes at launch, plus -- because the `isApplyingRatio`
guard stays armed until reveal -- the per-resize `splitViewDidResizeSubviews`
ratio-recompute writes a not-yet-revealed tab would otherwise emit. It does not claim a
hidden mounted view escapes AppKit layout.

## Design

Route **all** layout through a single new trigger: the `.setVisible(_, true)` arm of
`reconcileContainers`. `rebuild()` becomes construction-only; a new `ensureLaidOut()`
does the layout work, guarded so it runs exactly once per container build.

Why this seam (vs. deciding layout at build time in `buildAndInsertContainer`):
`computeContainerOps` already emits `.setVisible(visible:)` for **every** tab every
pass (`app/Projections.swift:648-650`), with `visible == (tabId == selectedTabId)`.
So the selected tab -- at restore or on switch -- always receives a
`.setVisible(true)` in the same ops list, immediately after its `.rebuild`. Hanging
layout off that one op keeps a single layout trigger site and needs no new
parameters or projection.

### The crux: the `isApplyingRatio` guard must span the *entire* deferral window

`PaneSplitView.applyRatio()` needs a non-zero frame (`app/PaneSplitView.swift:22`),
and `splitViewDidResizeSubviews` (`app/PaneSplitView.swift:60-68`) recomputes and
emits `onRatioChanged` -- **overwriting the stored ratio** -- unless `isApplyingRatio`
is set. Today `rebuild()` does construction + layout atomically inside a
`setApplyingRatio(true)` / `defer false` bracket, so AppKit never gets an unguarded
layout pass in between.

With deferral there is a gap between construction and reveal. A hidden container's
subtree is still in the window's constraint graph, so an AppKit-initiated layout
pass during that gap could fire an **unguarded** `splitViewDidResizeSubviews` at a
non-zero size and corrupt the hidden tab's stored ratio. Therefore `rebuild()` must
set `isApplyingRatio(true)` and **leave it set**; `ensureLaidOut()` releases it only
after applying the real stored ratios. This is the single most important correctness
detail in the change.

### Why no bounds guard, and not an AppKit `layout()` retry

`ensureLaidOut()` deliberately has no `bounds > 0` guard. `applyRatios` does need a
non-zero frame, but the container always has one when `ensureLaidOut()` runs:
`reconcileContainers` early-returns unless `contentArea != nil` (`app/Reconcile.swift:125`),
and `contentArea` is wired to the runtime *after* the window is created and sized, before
the first bootstrap/restore reconcile. The container is built at `contentArea.bounds` with
an autoresizing mask, so it is non-zero by the time any `setVisible(true)` fires. A
`bounds > 0` early-return was considered and rejected: reconcile is model-driven, not
resize-driven, so a zero-bounds early-return would have **no retry trigger** and could
strand a container unlaid-out (with the feedback guard left armed). Dropping it removes
that failure mode -- at the (invariant-prevented) zero-bounds case the behavior degrades
exactly as today's eager `rebuild()` already does (ratios default until a resize recomputes
them), so no new failure mode; the contract is just "call only with a valid frame," which
the reconcile guard plus launch ordering enforce.

Not chosen (the review's proposed fix): driving the deferred layout from an overridden
`SplitContainerView.layout()`. Hidden views still participate in Auto Layout -- the engine
assigns them space and they autoresize -- so `layout()` fires for hidden containers and
would *defeat* the deferral; and calling `layoutSubtreeIfNeeded()` / `applyRatios()` from
inside `layout()` risks reentrancy. The deterministic `setVisible(true)` trigger fires only
for the visible/selected tab and is both simpler and correct.

### Accepted side effect: hidden split tabs' surface sizing is deferred too

Restore stages a live ghostty surface for *every* tab, hidden included
(`commitRestoreSession` sets `surfaces = staged.surfaces`; the no-op
`reconcileSurfaceExistence` confirms staged surfaces match all pane ids). Surface size
flows from view layout: `TerminalView.setFrameSize` -> `syncSurfaceGeometry` ->
`ghostty_surface_set_size` (`app/TerminalView.swift:216-218,176-182`). So deferring a
container's explicit layout pass also defers its panes' surface sizing.

Concretely: today's eager `rebuild()` sizes every restored surface -- hidden included --
to its stored-ratio layout at launch. Under the pivot, a hidden **split** tab's panes are
sized only to whatever AppKit's automatic layout gives a mounted-hidden container (its
default ~50/50 divider, or possibly creation size if AppKit skips the hidden subtree)
until first reveal, when `ensureLaidOut` -> `applyRatios` -> `setFrameSize` corrects them
to the stored ratio. Single-pane tabs are unaffected (no divider; the lone pane fills the
container regardless of `applyRatios`). The post-reveal state is always correct, and
`syncSurfaceGeometry` skips degenerate `0x0` sizes (`app/TerminalView.swift:174`), so
there is no corruption -- this is a sizing-*timing* divergence, narrow to a size-sensitive
program (a TUI, or anything reading `COLUMNS`/winsize) in a *split background* pane before
it is first revealed. This is an inherent, accepted consequence of deferral (you cannot
defer the layout yet still size hidden panes eagerly); the plan characterizes and verifies
it (Testing steps 2 + 4) rather than treating surfaces as unaffected.

## Changes

### `app/SplitContainerView.swift` (primary)

Split `rebuild()` (currently lines 23-44) into construction + deferred layout, add a
one-shot flag:

- Add the required top-of-file `//` header (the file currently opens at `import Cocoa`
  with no header -- `app/SplitContainerView.swift:1`). Convey: renders one tab's split
  tree (`SplitNodeModel`) as nested `PaneSplitView`s hosting each pane's
  `PaneWrapperView`; construction is eager (`rebuild()`) but the explicit layout +
  split-ratio pass is deferred to first reveal (`ensureLaidOut()`) so a restored session
  runs that pass for only the visible tab; AppKit view layer only -- the model decides
  *which* tab is visible, this file realizes the tree and positions dividers.
- New `private var hasBeenLaidOut = false`.
- `rebuild()` -> construction only: remove subviews, `buildView`, activate the four
  pin constraints (lines 24-37 unchanged), then `setApplyingRatio(true, in: self)`
  and **leave it set** (do not clear), and `hasBeenLaidOut = false`. Drop the
  `defer`, the `layoutSubtreeIfNeeded()`, and the `applyRatios()` call from here.
  Update its comment to say it builds the tree and arms the resize-feedback guard for
  the deferral window; layout is applied by `ensureLaidOut()`.
- New `func ensureLaidOut()`:
  ```
  guard !hasBeenLaidOut else { return }
  layoutSubtreeIfNeeded()
  applyRatios(for: rootNode)
  setApplyingRatio(false, in: self)   // release the feedback guard; real ratios now applied
  hasBeenLaidOut = true
  ```
  `///` doc: lays out + applies stored ratios exactly once, on first reveal. The sole
  guard is `!hasBeenLaidOut` (idempotency): the per-pass `setVisible(true)` op calls this
  every reconcile, and after the first call the rest are no-ops. No bounds check -- see
  the frame invariant below.

`applyRatios` / `findPaneSplitView` / `setApplyingRatio` / `buildView` are unchanged
and reused as-is.

### `app/Reconcile.swift` (one line)

In `reconcileContainers`, the `.setVisible` arm (lines 167-172), after
`container.isHidden = !visible`:

```
if visible { container.ensureLaidOut() }   // lazy first-reveal layout; idempotent
```

Gate on `visible` only -- **not** `wasHidden` -- so the freshly-built selected tab at
restore (default `isHidden == false`, so `wasHidden == false`) still lays out. The
existing `activatedSelected` line is unchanged.

### `app/AppRuntime.swift` -- no change

`buildAndInsertContainer` (line 1295) still calls `container.rebuild()` at line 1325;
that now constructs only. Every `.rebuild` op is followed by a `.setVisible` for the
same tab in the same ops list, so construction is always paired with the layout
trigger. `rebuild()` has exactly one caller (verified), so nothing else relies on it
laying out.

### `tests-ui/` -- automated coverage (write first; TDD)

`tests-ui` compiles real AppKit (`-framework Cocoa`, boots `NSApplication.shared`) and
already exercises the `isApplyingRatio` guard at the `PaneSplitView` level
(`tests-ui/PaneSplitViewTests.swift:51-111`). The new lifecycle is testable there too:
`buildView` returns a plain `NSView()` for a leaf when `surfaceLookup` returns nil
(`app/SplitContainerView.swift:82-83`), so a container with `surfaceLookup: { _ in nil }`
and a *split* root builds a real `PaneSplitView` with plain-NSView leaves -- enough to
assert guard/ratio behavior without GhosttyKit.

- Shims (extend `tests-ui/SidebarViewTestShim.swift`, or add a `SplitContainerViewTestShim.swift`):
  minimal `class TerminalView: NSView {}` and `class PaneWrapperView: NSView` (with the
  `init(paneId:terminalView:isZoomed:hasSplits:runtime:)` signature) so
  `SplitContainerView.swift` compiles; neither is instantiated (surfaceLookup returns nil).
  Extend the shim `AppRuntime.send` to record `[Msg]` so a test can assert whether
  `.splitRatioChanged` fired.
- New `tests-ui/SplitContainerViewTests.swift` -> `splitContainerViewTests()`:
  1. **arm + release:** after `rebuild()` the nested `PaneSplitView.isApplyingRatio ==
     true`; after `ensureLaidOut()` it is `false` and the first subview width matches the
     stored ratio (e.g. ~0.7 * 800).
  2. **deferred suppresses feedback (the crux):** with the recording `AppRuntime`, after
     `rebuild()` force a layout pass (`layoutSubtreeIfNeeded()` and/or a frame change) and
     assert no `.splitRatioChanged` was sent and the model ratio is intact.
  3. **idempotent:** a second `ensureLaidOut()` changes nothing (stable ratio, no new
     `.splitRatioChanged`).
- Conventions (AGENTS.md): the new `SplitContainerViewTests.swift` (and any new shim
  file) open with the required top-of-file `//` header, and each new `uiTest` body opens
  with the three-section preamble -- `Intent`, `Why it exists`, `Scenario`. These are
  spec-first tests, so `Scenario` states the behavior under test; do not invent an
  incident. (AGENTS.md names the `tests/` and `lib/` idioms explicitly, and the existing
  `tests-ui` files predate the convention -- apply it to the new code, don't retrofit.)
- Wiring: add `app/SplitContainerView.swift` + `tests-ui/SplitContainerViewTests.swift`
  (+ any new shim file) to the `swiftc` compile list in `test-ui.sh`, and call
  `splitContainerViewTests()` from `UITestRunner.main`
  (`tests-ui/PaneSplitViewTests.swift:5-16`).
- TDD: write these before the `SplitContainerView` change. They fail first (no
  `ensureLaidOut`; the current eager `rebuild()` releases the guard immediately), then go
  green via `just test-ui` after the change.

## What deliberately does NOT change

- `desiredContainerShapes` stays a total projection (no mounted-set side-input).
- `computeContainerOps` / `ContainerOp` / the ops ordering -- unchanged. The existing
  `checkContainerOps` model-apply test (`tests/ReconcileTests.swift:564-590`) stays
  green.
- Cache semantics (`caches.containerShape`), chrome invalidation, popover-stranding,
  mount-time focus -- all unchanged.
- Background-tab shape drift: a hidden tab whose shape changes still gets a `.rebuild`
  (reconstruct + re-arm guard, `hasBeenLaidOut=false`) and stays layout-deferred until
  revealed. Correct by construction.

## Testing & Verification

**1. Automated (`just test-ui`) -- primary correctness coverage.** The three
`SplitContainerViewTests` above pin the new lifecycle invariants: the guard is armed
across the deferral window, `ensureLaidOut` applies ratios and releases the guard exactly
once, and a deferred container does not corrupt its ratio when AppKit lays it out. (An
earlier draft of this plan claimed there was no automated seam -- that was wrong, based on
a bad read of the test setup; `tests-ui` already links Cocoa and tests `PaneSplitView`.)

**2. Instrument: explicit-pass count + hidden-tab surface sizing.** Temporarily `NSLog`
(a) a counter inside `ensureLaidOut()` past the guard, and (b) each `TerminalView.setFrameSize`
with its pane id + size. Build a many-tab restored session (open ~15-20 tabs, *some split*,
via the `danterm` CLI; quit; relaunch) and read the launch logs:
- Explicit-pass count: before, N (one per tab); after, 1 (selected only), then +1 on each
  first switch-to. This proves DanTerm's explicit layout+ratio passes were deferred N->1
  and that `ensureLaidOut` is idempotent (the count does not balloon). It does **not**
  measure total main-thread layout time -- AppKit still lays out mounted-hidden containers
  (see the crux + side-effect sections) -- so it is a mechanism proof, not a timing one.
- Surface sizing: note whether, and at what size, each *hidden split* tab's `setFrameSize`
  fires at launch vs. on reveal. This records the background-sizing divergence (side-effect
  section) instead of assuming it. Remove the instrument before committing.

**3. Launch wall-clock, before/after (required).** The pass count proves work was
*deferred*, not that launch got *faster* (deferral could merely shift cost onto AppKit's
automatic layout). So measure cold-restore wall-clock for a **split-heavy** ~20-tab session
before vs. after the change -- this is the actual evidence the deferral reduces launch cost.
Record the numbers in the commit message.

**4. Manual QA (`just build-run`) -- integration behaviors the unit tests can't reach:**
- Restore a multi-tab/multi-group session -> selected tab renders immediately, no blank pane.
- Switch through several previously-hidden tabs -> each renders with correct splits.
- Ratio-across-real-resize: set tab A to a non-50/50 ratio, switch to B, resize the window,
  switch back to A -> A's divider holds its ratio. (Automated test 2 covers the
  programmatic layout pass; this exercises a true window resize.)
- **Split background tab sizing:** restore a session with a *split* background tab running a
  size-sensitive program (e.g. `htop` in one pane); switch to it and confirm it ends
  correctly sized/reflowed after reveal (exercises the surface-sizing side effect).
- Zoom a pane, switch away and back -> still zoomed and correct.
- Via `danterm` CLI, split a pane in a **background** tab; switch to it -> renders the new
  split correctly (deferred build + lazy layout path).

## Risks / non-goals

- Risk: missed reveal path. Mitigated -- the `.setVisible` arm is the only place a tab
  container's `isHidden` is cleared (verified across the codebase).
- Risk: hidden-tab ratio corruption. Mitigated by the span-the-deferral-window guard
  (the crux above) and verified by automated test 2 (deferred-suppresses-feedback).
- Non-goal: surface/PTY *creation* cost (unchanged). Creation only -- surface *sizing* for
  hidden split tabs IS deferred (see the accepted-side-effect section).
- Non-goal: any change to the eager-mount projection model.
