# Diff container visibility as a field of ContainerShape

Audit item RECON-1 in `docs/scratch/2026-08-18-construction-audit.md`, with
RUNTIME-5 absorbed. Follows MODEL-3 (`63e0c675`), which reduced
`ContainerShape` to `layout` plus `zoomedLeaf`.

## Problem

`computeContainerOps` (lib/DanTermCore/Sources/DanTermCore/Projections.swift)
diffs every field of `ContainerShape` against the reconcile cache except
visibility: it ends with an unconditional loop that emits `.setVisible` for
every tab on every sweep, fed by a separate `selectedTabId` argument. The
executor arm in `app/Reconcile.swift#reconcileContainers` answers each one
with `isHidden = !visible; ensureLaidOut()`, and `ensureLaidOut` is a bare
`applyModelLayout()`: a full `paneLayout` solve, a pane-id set, and a walk
over every leaf and divider. So every reconcile sweep -- coalesced cosmetic
sweeps and every inline Msg sweep alike -- runs one layout solve per mounted
tab, hidden tabs included, whatever the sweep was about.

The same function also reads its own output back out of AppKit:
`previouslyVisibleTabId` is the first container whose `isHidden` is false. The
reconciler already holds this fact in `caches.containerShape` once visibility
is a diffed field, so the AppKit scan is a second reader of a fact the cache
owns -- the same two-writers shape RUNTIME-5 named.

Evidence: the audit's RECON-1 and RUNTIME-5 sections, both vetted against the
tree; the cited code is unchanged on `f079a56a`.

## Decision

D1. Visibility is a diffed field of `ContainerShape`. `desiredContainerShapes`
sets it from the model's selected tab; `computeContainerOps` takes only `old`
and `new` and emits `.setVisible` the way it emits every other op: when the
field differs from the cached shape, and for a tab the cache has never seen.
An op that fires with nothing changed becomes unrepresentable.

D2. The reconciler's "what did the last pass show" comes from its own cache,
never from AppKit. `containerOpsStrandVisible` and `containerOpsEditVisibleTree`
take the cached shape map and derive the previously visible tab from it
themselves; neither the predicates nor `reconcileContainers` accepts a
caller-supplied tab id, so scanning `isHidden` for that answer is not
expressible.

D3. `.setVisible` always writes `isHidden`, but calls `ensureLaidOut()` only
when `visible` is true. The hide half of a selection change therefore costs no
layout solve. The reveal half keeps forcing one: whether AppKit runs `layout()`
on a hidden container whose frame autoresized is not pinned by any test here,
so deleting that relayout is a separate, test-gated change.

Hidden tabs keep model-derived geometry on every real change: tree, ratio,
and zoom ops already apply the layout themselves, and the `layout()` override
covers bounds. This preserves D1 of
`docs/design/2026-08-16-model-owned-pane-geometry.md` ("hidden and visible
tabs use the same layout path").

## Invariants

- I1. A sweep that changes no container shape and no selection emits no
  container ops.
- I2. A selection change at identical shapes emits exactly one hide and one
  show, and nothing else.
- I3. A tab the cache has never seen receives a build and then its
  visibility, so a new background tab ends the sweep hidden and a new selected
  tab ends it visible.
- I4. Applying the op script to the cached visibility state always reproduces
  "selected visible, all others hidden", including when the starting state
  has a freshly built, unhidden container.
- I5. Whether an op script strands or edits the visible tab is decided from
  the cached shapes alone.
- I6. A structural or zoom change applied to a hidden container lands every
  pane wrapper at the model-derived frame without any extra relayout call.
- I7. A selection change lays out only the revealed container. Hiding a
  container touches no pane geometry.

## Proof obligations

- PO1 (I1, I2, I3): core tests on `computeContainerOps` asserting the op
  script itself, not only its applied result. The existing "no-op when the
  selected tab is unchanged" test passes today only because the model-apply
  harness tolerates the extra ops; it is the red test.
- PO2 (I4): the model-apply harness in
  `lib/DanTermCore/Tests/DanTermCoreTests/ReconcileTests.swift` models
  `.build` as *unhidden*, matching `buildAndInsertContainer`, so a script that
  skips visibility after a build fails instead of being blessed.
- PO3 (I5): core tests call the strand/edit predicates with the cached shape
  map as their only source of prior visibility. The signature carries the
  obligation -- there is no tab-id parameter a caller could fill from AppKit --
  so the tests only need to pin the decisions the derived value produces.
- PO4 (I6): UI harness (`tests-ui/SplitContainerViewTests.swift`): a hidden
  container receives a split and a zoom and its wrappers match `paneLayout`
  with no `ensureLaidOut` call.
- PO5 (I7): a UI-harness test switches selection between two mounted tabs and
  asserts the panes of the tab being hidden receive no new grid, while the
  revealed tab's panes match `paneLayout`.

## Non-goals / Accepted risks / Rejected ideas

- NG1. Deleting `ensureLaidOut` and the transition relayout (D3).
- NG2. LOOKUP-4 (`containsPane`, the `paneLayout` set hoist). It shrinks after
  this change and is tracked separately.
- NG3. Any measured speedup claim. No benchmark on the ladder scales tab
  count; the deliverable is work proportional to change instead of to state.
- AR1. The reveal-path `ensureLaidOut()` (D3) stays unpinned by any test.
  A test that reveals a container and checks its frames cannot discriminate,
  because I6 requires those frames to hold without the extra call, so the call
  could be deleted by accident and only manual use would show it. Deleting it
  deliberately is NG1.
- RI1. Guarding the executor arm (`if container.isHidden != !visible`) and
  keeping the unconditional emission. Same saving, but visibility stays a side
  input outside the diffed representation, which is the shape that produced
  this and RUNTIME-5.
- RI2. A separate `visibleTabId` field in `ReconcilerCaches` (RUNTIME-5's
  original proposal). Redundant once the shape carries visibility, and it
  reintroduces two writers for one fact.

## Implementation discretion

- Whether `containerShape(of:)` gains a selection parameter or
  `desiredContainerShapes` fills the field.

## Verification

- `swift test --package-path lib/DanTermCore --filter ReconcileTests`
- `just test-ui > .build/ui.log 2>&1`, then grep the log.
- `just test` before commit.
- Manual: `just launch-slot`, open three tabs, split one in the background,
  switch to it; panes land at model frames; drag a pane, switch tabs, the drag
  overlay is gone. `just stop-slot <n>`.

## Implementation notes

- Took the `containerShape(of:visible:)` half of the discretion clause:
  `desiredContainerShapes` passes `tab.id == model.selectedTabId`, so a
  `ContainerShape` cannot be built without an answer for visibility.
- PO5 is a `SplitContainerView`-level test, not a reconciler-level one.
  `app/Reconcile.swift` is not on the UI harness compile list (`test-ui.sh`
  builds against a shim `AppRuntime`), so no UI test can call
  `reconcileContainers`. The test applies the same hide/reveal pair the
  executor emits and pins the AppKit half of I7: hiding lays nothing out, and
  revealing repairs geometry the hidden container missed. It discriminates --
  adding `ensureLaidOut()` to the hide half fails it -- but it cannot catch a
  future edit that reintroduces the call inside `reconcileContainers`.
- The `.build(tabId: visible)` arm of `containerOpsStrandVisible` is now
  unreachable in production: a `.build` fires only for a tab absent from the
  cache, and the cache is the sole source of "what was visible". The arm and
  its test case stay, since the classifier is a statement about op scripts.
