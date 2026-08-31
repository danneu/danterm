# Hold the split tree itself in ContainerShape; delete ContainerLayoutNode

Source finding: MODEL-3 in `docs/scratch/2026-08-26-improvement-audit.md`
(as rescored by its own Correction: structural cleanup, not a cost win).

## Problem

`ContainerShape` does not hold the split tree it describes; it holds a
hand-maintained mirror. `containerLayoutNode(_:)`
(`lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift:1065`) rebuilds a
parallel `ContainerLayoutNode` tree from `SplitNodeModel` on every reconcile
sweep, per tab, so the diff in `computeContainerOps`
(`Projections.swift:1285-1287`) can compare it against the cached one.

The mirror is the hazard: a layout-relevant field added to `SplitNodeModel`
but forgotten in `containerLayoutNode` silently stops producing relayouts.
The per-sweep allocation is real but unmeasured and small (sweeps are capped
at ~13/s); it is not the justification and no cost claim is made.

## Decision

`ContainerShape` holds the model's own tree -- `root: SplitNodeModel` --
instead of a copy. The diff gains a payload-skipping layout comparison
(ids, directions, ratios; never pane payload) beside the existing
ratio-skipping structure comparison, and `computeContainerOps` uses it
where it compares `oldShape.layout != shape.layout` today.
`ContainerLayoutNode`, `containerLayoutNode`, and `ContainerShape`'s
`Equatable` conformance are deleted outright.

The stored tree is encapsulated: `root` is private to the file that
defines the two comparisons, and both comparisons take `ContainerShape`
values. No caller outside that seam can reach the raw tree, so
payload-inclusive comparison (`a.root == b.root`, or a synthesized
shape `==`) is unavailable by construction, not by convention.

Dropping `Equatable` is part of the same contract: with `SplitNodeModel`
inside, a synthesized `==` would silently compare pane payload (titles,
cwds, todos), reversing the property the deleted type existed to
guarantee. No production code compares `ContainerShape` with `==`; four
test call sites do (`ReconcileTests.swift:712`, `:723`, `:1029-1030`,
`:1043-1064`), and all four are rewritten against the named comparisons
plus field assertions.

The structure comparison keeps comparing in place -- no derived tree,
per its own doc comment.

## Invariants

- I1: A pane-payload edit (title, cwd, progress, todos, theme) changes no
  container shape: the sweep emits no op for it.
- I2: Op classification is unchanged -- ratio-only change emits
  `.setLayout`; a tree edit (leaf added/removed, direction change, leaf or
  split id change) emits `.setTree`; zoom change emits `.setZoomedPane`;
  visibility is diffed like every other field.
- I3: No comparison of container shapes can include pane payload:
  `ContainerShape` is not `Equatable`, the stored tree is unreadable
  outside the comparison seam, and the only layout comparisons are the
  two named payload-skipping functions taking `ContainerShape` values.

## Proof obligations

Proofs land at the diff boundary (`computeContainerOps`), not only on
the comparison helpers -- a helper-level test stays green even if the
diff bypasses the helper.

- PO1 (I1): a payload-only edit (title, cwd, progress, todos, theme)
  produces an empty op script from `computeContainerOps`.
- PO2 (I2): a ratio-only edit emits `.setLayout`; each structural edit
  kind emits `.setTree`; a zoom-only toggle emits `.setZoomedPane`. The
  existing op-script and model-apply tests carry the rest.
- PO3 (I3): the four shape-equality test call sites
  (`ReconcileTests.swift:712`, `:723`, `:1029-1030`, `:1043-1064`) are
  rewritten against the named comparisons and field assertions; the
  build itself proves shape `==` no longer exists.
- TDD: land the `computeContainerOps`-level assertions (PO1, PO2's zoom
  case) first against the current code and watch any that fail do so
  for the expected reason before the type change lands.

## Non-goals

- No allocation benchmark and no cost claim; if anyone wants the number,
  `just benchmark-sample btop-scroll 20` is the probe, separately.
- No generation counter on `PaneTree` (the finding's cheaper fallback --
  another hand-maintained mirror).

## Accepted risks

- AR1: The reconciler's shape cache (`app/Reconcile.swift:40`) now retains
  full `PaneModel` payloads for one sweep after a pane is gone. Bounded and
  small -- scrollback is not in the model.
- AR2: The forgotten-field hazard moves rather than disappears: a new
  layout-relevant `SplitNodeModel` field forgotten in the payload-skipping
  comparison misses relayouts, the same failure class as today's builder.
  The win is one fewer type and one fewer recursive walk, not immunity.

## Implementation discretion

- How construction works with a private stored tree (an explicit
  non-private initializer is fine -- privacy guards reads, not
  construction) and whether the comparisons are free functions or
  methods.

## Files

- `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift` -- the type,
  the deleted mirror, the comparisons.
- `lib/DanTermCore/Sources/DanTermCore/Projections.swift` -- the one
  `!=` call site in `computeContainerOps`.
- `lib/DanTermCore/Tests/DanTermCoreTests/ReconcileTests.swift` -- the two
  shape-equality tests.
- `app/Reconcile.swift` compiles unchanged (it only stores and re-reads the
  shape dictionary).

## Verification

- `swift test --package-path lib/DanTermCore` and `just lint` in the loop.
- `just test` before the commit.

## Commit progress

- [x] 1. refactor(core): diff container shapes against their split trees
- [x] 2. docs(audit): mark MODEL-3 complete

## Implementation notes

- The stored tree is `fileprivate`, not `private`. Swift's `private` on a
  struct member reaches only the type and its extensions, so the two
  comparisons -- free functions in the same file -- could not read it. An
  explicit internal `init(root:zoomedLeaf:visible:)` replaces the
  memberwise initializer, which `fileprivate root` would otherwise have
  made file-local and unreachable from the tests.
- The new payload-skipping layout comparison is `sameContainerLayout`,
  beside the renamed-in-place `sameContainerStructure`. Both take
  `ContainerShape` values and delegate to a private walk over
  `SplitNodeModel`. The two walks are separate rather than one walk with a
  "count ratios" flag: each reads as a plain structural recursion.
- The tests need whole-shape sameness in two places, so `ReconcileTests`
  keeps a private `sameShape` helper built out of the two named
  comparisons plus `zoomedLeaf` and `visible`. It composes the public
  seam rather than reaching around it.
