# Index PaneSplitViews by id instead of re-searching the view tree

## Context

`app/SplitContainerView.swift` realizes a tab's `SplitNodeModel` as nested
`PaneSplitView`s. Twice, it needs to act on the `PaneSplitView` that corresponds
to a given model node -- once to apply each split's stored divider ratio after
layout, and once to flip the `isApplyingRatio` resize-feedback guard. Both times
it re-derives the view from the model by **recursively walking the live AppKit
view tree and type-casting** every subview:

- `applyRatios(for:)` (`SplitContainerView.swift:61-69`) recurses the model tree
  and, per split node, calls `findPaneSplitView(for:)` ->
  `findPaneSplitViewIn(view:id:)` (`:71-86`), a fresh depth-first search from the
  container root that `as? PaneSplitView`-casts each subview until `splitId`
  matches.
- `setApplyingRatio(_:in:)` (`:125-132`) is a second recursive subview walk doing
  the same `as? PaneSplitView` cast to set a flag on each one.

This is the wrong idiom for this codebase. Everywhere else, a view the runtime
needs to address later is held in an id-keyed map and looked up directly --
`surfaces[paneId]` and `tabContainers[tabId]` in `AppRuntime`. `buildView(.split)`
(`:100-121`) already *creates* each `PaneSplitView` with its `splitId` in hand,
then throws that pairing away so two separate recursive searches can reconstruct
it. The result is ~15 lines of error-prone tree-walking-plus-casting (the kind of
code that silently returns `nil` or the wrong node if the hierarchy ever shifts)
standing in for what should be a dictionary read.

This change keeps that id->view pairing at the moment of construction in a
`[SplitId: PaneSplitView]` index, then reads it where needed. It deletes both
`findPaneSplitView` helpers outright and flattens `setApplyingRatio` from a
recursive view walk to a loop over the index's values. Outcome: one fewer way to
find a view (the explicit map, matching the rest of the app), two recursive
helpers gone, and the construction site becomes the single source of truth for
"which `PaneSplitView` is which." (It is incidentally also less work at runtime --
the search was O(splits^2) -- but that cost was negligible at human-rate reveal
frequency and is not the reason to do this.)

This is a pure refactor: no behavior change, identical divider geometry, focus,
and feedback-guard timing.

## Prerequisites (verified)

- `SplitId` = `TypedId<SplitTag>`, which conforms to `Hashable`
  (`lib/DanTermCore/Sources/DanTermCore/Model.swift:12-14`), so it is a valid
  dictionary key.
- `findPaneSplitView`, `findPaneSplitViewIn`, and `setApplyingRatio` are all
  `private` and called only within `SplitContainerView.swift` -- no external
  callers to update.
- `buildView(.split)` (`SplitContainerView.swift:101`) is the only production
  construction site for `PaneSplitView`, so the index is exhaustive. (The only
  other `PaneSplitView(...)` calls are isolated unit-test fixtures in
  `tests-ui/PaneSplitViewTests.swift`.)

## Changes -- all in `app/SplitContainerView.swift`

### 1. Add the index property

Next to the other stored state (near `:15`, after `hasBeenLaidOut`):

```swift
/// SplitId -> the live PaneSplitView built for it, populated by buildView so the
/// post-layout ratio pass and the resize-feedback guard address each split view by
/// id instead of re-searching the view tree. Rebuilt from scratch every rebuild().
private var splitViews: [SplitId: PaneSplitView] = [:]
```

### 2. Clear it at the top of `rebuild()`

Right after the `removeFromSuperview()` loop, before `buildView` repopulates it
(`:33-37`):

```swift
for sub in subviews {
    sub.removeFromSuperview()
}
splitViews.removeAll(keepingCapacity: true)

let view = buildView(for: rootNode)
```

### 3. Populate it in `buildView(.split)`

One line right after the `PaneSplitView` is constructed (`:101`):

```swift
case .split(let id, let direction, let first, let second, let ratio):
    let splitView = PaneSplitView(splitId: id, ratio: ratio)
    splitViews[id] = splitView
    splitView.onRatioChanged = { [weak self] splitId, ratio in
        ...
```

### 4. `applyRatios`: bind `id`, look it up; delete both `findPaneSplitView*` helpers

```swift
private func applyRatios(for node: SplitNodeModel) {
    guard case .split(let id, _, let first, let second, _) = node else { return }
    if let paneSplit = splitViews[id] {
        paneSplit.applyRatio()
        paneSplit.layoutSubtreeIfNeeded()
    }
    applyRatios(for: first)
    applyRatios(for: second)
}
```

Then delete `findPaneSplitView(for:)` and `findPaneSplitViewIn(view:id:)`
(`:71-86`) entirely -- `applyRatios` was their only caller.

### 5. Flatten `setApplyingRatio` over the index

Update the two call sites (`:48`, `:57`) to drop the `in:` argument:

```swift
setApplyingRatio(true)   // in rebuild()
setApplyingRatio(false)  // in ensureLaidOut()
```

and replace the recursive walk (`:125-132`) with:

```swift
private func setApplyingRatio(_ value: Bool) {
    for splitView in splitViews.values {
        splitView.isApplyingRatio = value
    }
}
```

Equivalent because `splitViews` holds exactly the `PaneSplitView`s `buildView`
created (the same set the recursive walk visited) and is fully populated before
either call -- `setApplyingRatio(true)` runs after `buildView` in `rebuild()`, and
`setApplyingRatio(false)` runs in `ensureLaidOut()` while the map is still live
(it is only cleared at the start of the next `rebuild()`).

## What stays untouched (load-bearing)

The deferral structure is unchanged: ratios still apply post-layout in
`ensureLaidOut()` after `layoutSubtreeIfNeeded()` (`:53-59`), the pre-order
recursion in `applyRatios` is identical, and `isApplyingRatio` still suppresses
`onRatioChanged` during the programmatic pass. Only the *how-do-I-find-this-view*
mechanism changes. Do **not** try to apply ratios inline in `buildView`:
`applyRatio()` reads `bounds` and bails when `totalSize <= 0`
(`PaneSplitView.swift:21-22`), so at build time (zero frame) it would silently
no-op and leave dividers at the 50/50 default -- which is exactly why the pass is
deferred.

## Out of scope

- The broader batch-C container-teardown rework (granular container diff, wrapper
  reuse). This plan is only the id-keyed-lookup cleanup; the rest is deferred.
- The test-only `onlyPaneSplitView(in:)` helper in
  `tests-ui/SplitContainerViewTests.swift`, which also walks the view tree. It is
  test scaffolding for single-split trees, not production code; leave it as-is.

## Required new test: nested-split coverage

The refactor's whole correctness condition is that the `splitViews` index is
**exhaustive across nesting** -- every split node, not just the root, is captured
and addressed. But the existing `SplitContainerView` UI tests build only a
single-split tree: `makeSplitContainer` (`tests-ui/SplitContainerViewTests.swift:70-86`)
constructs one `.split` node, and `onlyPaneSplitView` (`:88-92`) asserts there is
exactly one `PaneSplitView`. So a bug where the index (or the flattened
`setApplyingRatio`) covered only the root would leave inner dividers at the 50/50
default and inner guards wrong -- and every current test would still pass. Close
that gap with one nested-tree test **before** doing the refactor (write it,
confirm it is green against today's tree-search code, then refactor and confirm it
stays green -- that ordering is what catches an incomplete index).

Add to `tests-ui/SplitContainerViewTests.swift`, reusing the existing
`paneSplitViews(in:)` recursive collector (`:94-103`, already present -- it returns
*all* split views, unlike `onlyPaneSplitView`):

- Build a two-level tree with two distinct `SplitId`s and two distinct ratios
  (outer `.split` whose `second` child is itself a `.split`). A small
  `makeNestedSplitContainer` fixture mirroring `makeSplitContainer` (800x600) is the
  natural shape. **Orient the inner split perpendicular to the outer** so its split
  axis spans the container's full un-split dimension -- e.g. outer `.horizontal`
  (splits the 800pt width), inner `.vertical` (splits the full 600pt height). Do
  NOT copy the outer's orientation: a same-orientation inner split lives inside the
  outer's narrow ~240pt second pane, where the usable band is only `[100, 140]`,
  and the assertion below would measure a clamped divider, not the stored ratio
  (see the constraint note).
- Pick two distinct ratios that land each split's divider clear of the 100pt min on
  **its own** axis -- e.g. outer 0.65 (position 0.65 * 800 = 520, within `[100, 700]`),
  inner 0.7 (position 0.7 * 600 = 420, within `[100, 500]`).
- After `rebuild()`: assert `paneSplitViews(in: container)` has count 2 and **every**
  one has `isApplyingRatio == true`.
- After `ensureLaidOut()`: assert **every** split view has `isApplyingRatio == false`,
  and each split view's divider matches **its own** stored ratio. Assert the
  fraction relative to that split view's own measured bounds
  (`firstChildExtent / ownTotalExtent` ~= the stored ratio), not a hardcoded
  absolute -- the inner split's available size depends on layout, so an absolute
  total would be brittle and structure-coupled. (The existing `firstSubviewRatio`
  helper already reads the correct axis per `isVertical`, but takes a hardcoded
  `expectedTotal`; for the inner node measure the fraction off its own `bounds`
  instead.)

**Constraint note (do not skip):** `PaneSplitView` clamps every divider to
`[100, totalSize - 100]` on its split axis (`constrainMinCoordinate` -> 100,
`constrainMaxCoordinate` -> `totalSize - 100`, `PaneSplitView.swift:29-36`), and
`setPosition` respects it. So each chosen `total * ratio` MUST satisfy
`100 <= position <= total - 100` on that split's own axis; otherwise the divider is
clamped and the assertion measures the clamp, not the ratio -- a misleading red (or,
if someone then loosens the tolerance to "fix" it, a silently weakened green on the
one test the plan's correctness argument rests on).

This is behavioral and structure-insensitive: it asserts observable geometry and
guard state, never the private `splitViews` map or the construction mechanism.

## Verification

- `just test-ui` -- the primary safety net. The new nested test above plus the
  existing `tests-ui/SplitContainerViewTests.swift` cases ("rebuild arms ratio
  guard and ensureLaidOut applies stored ratio", "deferred container suppresses
  split resize feedback", "ensureLaidOut is idempotent") and
  `tests-ui/PaneSplitViewTests.swift` (the `isApplyingRatio` guard tests) together
  cover both single- and nested-split ratio application and the feedback guard;
  all must pass unchanged. (Needs a GUI session; runs from this shell, fails
  headless.)
- `just test` -- full local gate (compile + core/protocol/support suites + lints);
  run before done to confirm the file still compiles and nothing in the pure
  layer regressed.
- `just build-run` -- manual smoke: open a tab, split horizontally and
  vertically (N >= 3 panes), drag dividers, switch away and back, zoom/unzoom.
  Confirm dividers land at their stored ratios on reveal, dragging still updates
  the model, and there is no visual glitch -- identical to current behavior.
