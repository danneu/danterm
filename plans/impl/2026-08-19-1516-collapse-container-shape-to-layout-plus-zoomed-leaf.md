# Collapse ContainerShape to layout plus zoomedLeaf

Source: MODEL-3 in docs/scratch/2026-08-18-construction-audit.md (its
Starter kit lists every change site; this plan carries the contract).
Verified against the tree 2026-08-19.

## Problem

`ContainerShape` (lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift)
stores four fields of which two are derived: `tree` is `layout` with the
ratios dropped, and `isZoomed` is `zoomedLeaf != nil`. `isZoomed` has no
reader at all. The initializer takes `tree` and `layout` independently, so
a value whose structural fingerprint contradicts its own layout tree is
representable. `desiredContainerShapes` rebuilds both indirect-enum trees
for every tab on every reconcile sweep.

The sole field reader is `computeContainerOps`
(lib/DanTermCore/Sources/DanTermCore/Projections.swift); the runtime
(app/Reconcile.swift) holds the shape cache opaquely.

## Decision

Reduce `ContainerShape` to two stored fields: `layout: ContainerLayoutNode`
and `zoomedLeaf: PaneId?`. Delete `ContainerShapeNode`, its builder, the
fabricated-ratio default-layout helper, `isZoomed`, and the hand-written
initializer. `computeContainerOps` distinguishes a tree edit from a
ratio-only change with a ratio-skipping structural comparison over the two
layout trees, compared in place -- never by rebuilding a derived tree per
comparison, which would reintroduce the allocation this change removes.

This is a behavior-preserving refactor: for every old/new pair of shapes
produced by `containerShape(of:)`, the emitted op script is unchanged. The
old initializer also admitted shapes whose fingerprint contradicted their
layout; those have no counterpart after the collapse, so they are outside
the claim.

Decisive constraints:

- The structural comparison runs before full layout equality in the diff,
  because a structural change is also a layout inequality.
- Sound because `PaneTree.focusedPaneId` is non-optional and
  `PaneTree.zoomedPaneId` is nil iff unzoomed, so `zoomedLeaf` alone
  carries the zoom fact losslessly.

## Invariants

- I1. A shape whose structural fingerprint disagrees with its own layout,
  or that claims zoom without a zoomed leaf (or the reverse), is
  unrepresentable -- by construction of the two-field struct.
- I2. A ratio-only change emits `.setLayout` and never `.setTree`.
- I3. A split or a close (any structural tree change) emits `.setTree`.
- I4. A zoom toggle changes the shape.
- I5. A leaf pane payload edit (title/cwd/progress/todos/theme) leaves the
  shape equal.

## Proof obligations

- PO1 (I2): existing test "a ratio-only container change requests layout
  without a tree edit" (ReconcileTests) keeps passing.
- PO2 (I3): new characterization tests driving `computeContainerOps`
  directly, built from real `TabModel`s via `containerShape(of:)`. One case
  per structural discriminator the ratio-skipping comparison must honor:
  node kind (leaf vs split, and the inverse close), split id, direction,
  leaf pane id, and a change confined to a nested descendant. Each asserts
  `.setTree` and no `.setLayout`. The ratio-only case (PO1) is the inverse
  obligation, so together they pin the comparison from both sides. This
  matters because the collapse replaces derived `ContainerShapeNode`
  equality with a hand-written comparison: a comparison that silently drops
  one discriminator would classify a real tree edit as `.setLayout`,
  breaking I3, and `containerOpsEditVisibleTree` would then fail to cancel
  a pane drag whose split no longer exists. Written first and GREEN before
  the refactor (the current code already behaves correctly; this is the
  safety net, not a red test), then kept passing after.
- PO3 (I4): existing "ContainerShape: structural change / zoom toggle
  compare unequal" keeps passing -- the zoom clause now rides on
  `zoomedLeaf` alone.
- PO4 (I5): existing "leaf PaneModel metadata edit compares equal" keeps
  passing.
- PO5 (behavior preservation): the whole computeContainerOps model-apply
  suite and the op classifiers (`containerOpsStrandVisible`,
  `containerOpsEditVisibleTree`) keep passing once the file-private
  fixtures are rewritten to the two-field initializer.

## Non-goals

- No behavior change: no op starts or stops firing. RECON-1 (diffed
  container visibility) touches the same struct and diff and is sequenced
  after this change, in its own commit.
- No performance claim. Every benchmark-ladder workload runs one tab and
  one pane, so no calibrated number can price this; sell it as strictly
  less code and one tree build instead of two.
- Not restructuring `SplitNodeModel` leaves to bare `PaneId`s with a pane
  side table. That would make `paneTree.root` itself the shape, but it
  contradicts the tree-owns-panes invariant ("a pane exists iff a tree
  leaf owns it", pinned by TreeOwnsPanesTests) and needs its own decision.

## Rejected ideas

- RI1. A computed `var structure: ContainerShapeNode` derived from
  `layout` (the audit's original Ideal-fix wording): every read in the
  diff would rebuild an indirect-enum tree, heap-allocating a box per
  node -- the exact cost the mirror was paying. Retracted by the audit's
  own Sharper-ideal paragraph in favor of the in-place comparison.
- RI2. Storing `SplitNodeModel` plus `zoomedLeaf` and comparing it
  recursively (dropping `ContainerLayoutNode` too): it moves payload
  independence (I5) out of the value and into a hand-written `==` that must
  remember to skip pane payload, where today the payload simply is not in
  the value. It also makes the reconcile cache retain a full previous
  generation of every tab's pane payload. Disagreement between structure
  and layout is already unrepresentable under I1, so the pivot buys no
  invariant this plan lacks.
- RI3. Merging RECON-1 into this change: mixing a behavior change into a
  pure refactor destroys the characterization argument that guards it.

## Implementation discretion

- Name and placement of the ratio-skipping equality helper (the audit
  suggests beside `ContainerLayoutNode`), and the exact rewrite of the
  file-private ReconcileTests fixtures (`cShape`/`cSplitShape`) and the
  file header comment that names the old type layout.

## Verification

1. Write the PO2 test; run
   `swift test --package-path lib/DanTermCore --filter ReconcileTests`
   and confirm it is green against the unmodified code.
2. Make the change; same filter run stays green (PO1-PO5).
3. `just test` for the full gate.
