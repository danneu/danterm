# Incremental Container Reconciliation

## Context

Opening or closing a pane gets slower the more panes the tab holds. Measured on
an isolated slot with a release build, splitting repeatedly in one tab:

| panes | 2 | 5 | 8 | 11 | 14 | 18 | 22 | 25 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| split (ms) | 27 | 45 | 76 | 88 | 115 | 182 | 279 | 323 |

The cause is that any change to a tab's `ContainerShape` -- which every pane add
or remove is -- makes `reconcileContainers` throw the tab's entire AppKit view
tree away and build a new one. A `sample` of the main thread during the tail
attributes 775 of 779 busy samples to that one pass: ~387 to the layout and
ratio pass on the new tree, ~266 to constructing every wrapper and split view,
~122 to tearing the old tree down. Closing a pane takes the identical path.

Two premises this rests on:

- The pure layer is not implicated. `desiredContainerShapes` costs tens of
  microseconds even at 60 tabs / 480 panes
  (`docs/research/33-by-construction-perf-survey`); the tens of milliseconds are
  entirely the AppKit rebuild.
- The cost is per *visible* pane. With the window occluded the same splits run
  flat, because the rebuilt panes never render.

This is `agent-docs/perf-granularity-mismatch.md` inverted: the work runs at the
granularity of the whole tab while the variation is one node. The existing
compensating apparatus is the structure apologizing -- chrome caches invalidated
for every pane in the tab, popovers dismissed because their anchor is about to
be destroyed, every session defocused before the rebuild, ratios reapplied
across the whole tree.

The reconciliation ADR already names the target state: "make displayed view
state a consequence of the model without rebuilding all AppKit objects", and
"this is not a license to rebuild all AppKit hosts after every message". The
sidebar pass already works this way; the container pass is the outlier.

## Decision

Make container reconciliation incremental, in one change with two coupled
halves.

**A pane's wrapper host lives as long as its terminal session, and the runtime
owns it.** Today the wrapper owns the session and the session points back at the
wrapper weakly, so a wrapper detached from the tree has no owner at all. The
strong reference moves up: a per-pane host owned by the runtime and keyed by
`PaneId` owns both the session and the wrapper, and a container tree only ever
reparents that wrapper. The host is released when the pane's session is torn
down, and never by a tree edit. The two facts a wrapper freezes at construction
today -- whether the pane is zoomed and whether its tab has splits -- move into
the per-pane toolbar projection that `reconcilePaneChrome` already diffs and
pushes, so the same wrapper's affordances track the model.

**The container pass patches the live split tree instead of rebuilding it.**
The shape projection is already a tree keyed by ids the model preserves across
edits (`splitLeaf`, `removeLeaf`, `swapLeaves` all keep surviving splits' ids),
so a keyed structural diff of old shape against new shape yields node-level ops
that the executor applies to the live hierarchy. A whole-tab build remains the
op for a tab that is new or restored.

Consequences that are part of the decision, not side effects: `chromeInvalidation`
is deleted, since no edit destroys a wrapper; the defocus-every-session loop in
the container builder goes with it; zoom becomes a presentation of the live tree
rather than a collapsed rebuild of it. Popover-stranding dismissal is narrowed by
scope rather than deleted. A tab-scoped TODO popover keeps today's behavior in
full, including dismissal on a shape change to its tab. A pane-scoped popover
stops being dismissed by a structural edit that keeps its pane alive, because
its anchor now survives; both halves of the rule narrow together, the pure clear
in `update()` and the AppKit dismissal in the container pass. Removal of the
anchor's tab, and loss of that tab's visibility, still dismiss either scope.

`docs/design/2026-05-27-model-driven-view-reconciliation.md` is amended in the
same change: its ordering rationale ("container reconciliation runs before pane
chrome because container rebuilds recreate pane wrapper hosts") and its non-goal
sentence about not diffing a UI tree both describe the structure being replaced,
and its accepted duplication of the TODO-popover condition now covers visibility
loss and tab removal for either scope, plus a shape change for a tab-scoped
popover.

Critical files: `app/Reconcile.swift`, `app/SplitContainerView.swift`,
`app/PaneSplitView.swift`, `app/PaneWrapperView.swift`, `app/AppRuntime.swift`
(container build/remove, wrapper lookup, mount-time focus),
`lib/DanTermCore/Sources/DanTermCore/Projections.swift` and
`ModelOperations.swift`, plus their tests in
`lib/DanTermCore/Tests/DanTermCoreTests/ReconcileTests.swift` and
`tests-ui/SplitContainerViewTests.swift`.

## Invariants

- **I1.** A pane's wrapper host is owned by the runtime and exists exactly as
  long as its terminal session: no tree edit destroys or replaces one, and
  tearing the session down releases both.
- **I2.** A tree edit mutates the live container in place. The views it
  constructs or destroys are bounded by the edit, not by the tab's pane count.
- **I3.** A pane's toolbar state, active search overlay, and pane-scoped TODO
  popover survive any structural edit that keeps the pane alive while its tab
  stays visible -- including edits that move it within its tab, and a zoom
  toggle. Losing that visibility, or removing the tab, still dismisses the
  popover.
- **I4.** A patch, and the layout it provokes, never writes a split ratio the
  user did not move.
- **I5.** A zoomed tab presents only the focused pane. Which panes render is
  what the pure visibility projection says, unchanged.
- **I6.** An in-flight pane drag is cancelled by any edit to the visible tab's
  tree.
- **I7.** Diff logic stays pure and AppKit-free; the executor stays a thin
  applier that never writes `AppModel`.
- **I8.** Restore still produces a clean full build from a reset cache, never a
  patch against stale state.
- **I9.** Apart from latency and the chrome survival in I3, split, close, move,
  zoom, and tab switch behave as they do today.

## Proof obligations

- **PO1.** For every structural mutation the model can produce -- replace leaf
  with split, collapse a split into its surviving sibling, wrap a tab root,
  swap two leaves, tab appear and disappear, zoom toggle, whole-tree
  replacement -- applying the computed ops to a model of the mounted tree
  reaches the desired shape. Structure-insensitive, in the model-apply style the
  existing container and sidebar op suites already use; not an exact-sequence
  assert. (I2, I7, I8)
- **PO2.** A change that preserves the shape -- a split ratio, a leaf payload
  edit -- still produces no host mutation. (I7; the existing "split ratio is
  excluded" test is the anchor and must keep passing.)
- **PO3.** Wrapper identity survives a split of the pane itself, a close of a
  sibling, a move within the tab, a move to another tab, and a zoom toggle;
  tearing the pane's session down releases the host. This inverts the current
  UI-harness assertion that a rebuild replaces the wrapper. (I1)
- **PO3a.** The surviving wrapper's zoom affordances follow the model: its
  unzoom control and its pane-menu zoom state are correct across a first split,
  a zoom, an unzoom, and the close of a last sibling. (I9)
- **PO4.** An active search overlay and an open pane-scoped TODO popover survive
  a sibling pane being opened and closed; a tab-scoped popover is still
  dismissed by the same edit; and switching away from the popover's tab, or
  removing that tab, still dismisses either scope. (I3, I9)
- **PO5.** A patch and its layout emit no split-ratio message, and stored ratios
  are unchanged afterwards. (I4)
- **PO6.** In a zoomed tab exactly the focused pane reports visible to its
  renderer, and unzooming restores the others. (I5)
- **PO7.** A tree edit to the visible tab cancels an in-flight drag. (I6)
- **PO8.** A restore builds every tab's container from the reset cache. (I8)
- **PO9.** Split and close latency no longer grows with the tab's pane count.
  Baseline and changed builds run as two isolated slots in one contemporaneous
  session, with matched pane counts alternated between them and each point
  repeated; each build also carries the control the change cannot reach -- the
  same operation with the window occluded, which is flat today and must stay
  flat. Report trial counts and the distribution at each point, not a
  pass/fail. (I2)

## Non-goals

- The whole-model scan the projection layer performs on every message. That is a
  separate, already-documented mismatch, and the ADR forbids precomputing
  further reconcile inputs speculatively.
- A generic component reconciler. The diff is keyed on ids the model already
  carries and covers the mutations enumerated in PO1; nothing else.
- Any change to pane, split, or zoom semantics, or to the `danterm` CLI surface.

## Accepted risks

- **AR1.** A pane drag snapshots its target pane ids when the drag starts. With
  wrappers reused rather than destroyed, a stale target would now resolve to a
  live wrapper at a new position instead of resolving to nothing. I6 is what
  keeps this unreachable, so it is load-bearing rather than incidental.
- **AR2.** A zoomed tab keeps its non-focused wrappers in the view hierarchy
  where the rebuild previously unmounted them. Renderer visibility is decided by
  the pure projection and so is unchanged; the residue is view-hierarchy
  membership and its memory, which for an eagerly-mounted app is what every
  background tab already costs.

## Rejected ideas

- **RI1.** Keep the whole-tab rebuild and shrink its constant -- cheaper
  wrappers, or dropping Auto Layout inside the container. It leaves the cost
  linear in pane count, and the profile splits roughly evenly across teardown,
  construction, and layout, so no single constant carries the fix.
- **RI2.** Coalesce or throttle structural reconciles. That is a cache in front
  of a granularity mismatch, and the ADR requires proving popover, session, and
  post-reconcile-command alignment before any structural message may coalesce.
- **RI3.** Keep wrappers owned by the tree and merely reuse them by key. The
  pane being split still loses its wrapper, so chrome invalidation and popover
  stranding both survive and I3 cannot be stated.

## Implementation discretion

- The op vocabulary and addressing scheme for the node-level diff.
- How a persistent wrapper represents the unzoom affordance, which is
  construction-time today.

## Verification

- `just test` for the pure obligations (PO1, PO2, PO8, and the model half of
  PO6) and `just test-ui > /tmp/ui.log 2>&1` for everything that needs a real
  view tree (PO3, PO3a, PO4, PO5, PO6, PO7); both must be green. The CLI reaches
  panes, splits, and zoom but not a search overlay, the TODO popover, or an
  AppKit drag, so those obligations belong in the UI harness with runtime and
  session doubles, not in a scripted session.
- PO9: with each app frontmost on its own slot, drive splits and closes from the
  CLI (`pane split`, `pane close --pane <id>`) as pane count grows. Confirm the
  changed curve is flat where the baseline reached ~320ms at 25 panes, and
  re-profile with `sample` to confirm `reconcileContainers` no longer dominates.

## Implementation notes

- The pure patch carries the desired root and split map together with the changed
  and removed split ids. The executor detaches every changed relationship before
  attaching any of them, so cross-tab pane moves are correct in either tab-op
  order while unchanged nodes keep their AppKit identity.
- Five alternating visible trials per arm used balanced split targets at 2, 5,
  8, 11, 14, 18, 22, and 25 panes. At 25 panes, median CLI reply latency moved
  from 124.73 ms to 11.29 ms for split and from 132.57 ms to 8.60 ms for close;
  the candidate stayed near 9-11 ms from 5 through 25 panes. Three hidden-window
  control trials did not reproduce the plan's claim that the baseline was flat:
  its 25-pane medians remained 181.10 ms for split and 189.71 ms for close. The
  visible result is therefore descriptive evidence for the intended flat curve,
  not a comparison backed by the planned unaffected control. An eight-second
  candidate sample under repeated split/close load contained keyed patch and
  affected-layout work rather than repeated full-tab construction; because the
  stimulus exclusively exercised container reconciliation, that pass remained
  the main-thread work rather than literally disappearing from the profile.

## Follow Up

- Add a structural-mutation timing instrument that observes the final completed
  draw, then repeat the visible/occluded comparison; CLI reply latency did not
  reproduce the plan's flat baseline control.
