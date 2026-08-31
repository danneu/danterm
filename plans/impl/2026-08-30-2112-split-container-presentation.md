# One presentation entry point for SplitContainerView (CHROME-2)

## Problem

`SplitContainerView` takes its tree in `init` but not its zoom, so a
container is constructed in a state its tab may contradict and the builder
must remember a repair call (`AppRuntime.buildAndInsertContainer` does
`container.rebuild()` then `container.setZoomedPane(...)`). That leaves four
public spellings of one operation -- `rebuild()`, `ensureLaidOut()`,
`setRootNode(_:)`, `setZoomedPane(_:)`, the first two byte-identical -- and
the `.setTree` / `.setLayout` / `.setZoomedPane` arms of
`reconcileContainers` in `app/Reconcile.swift` spell the same call three
ways.

Source: audit finding CHROME-2 in
`docs/scratch/2026-08-26-improvement-audit.md` (vetted; every quote verified
against the current tree). This is a vocabulary fix, not a behavior fix.

## Decision

Give the container one presentation entry point that takes the tree and the
zoom together, and make construction take both:

- `init` gains the zoomed pane id, so a container with a tree but no zoom
  stops being representable and no caller can forget the follow-up.
- One `present(tree:zoomedPaneId:)` replaces all four public methods; the
  reveal arm passes the tab's current tree and zoom rather than trusting the
  container's stored copy.

The `ContainerOp` cases in `lib/DanTermCore/Sources/DanTermCore/Projections.swift`
stay distinct -- `containerOpsEditVisibleTree` needs `.setTree` and
`.setZoomedPane` (and not `.setLayout`) to decide a pane-drag cancel -- only
their executors in `reconcileContainers` unify.

Files: `app/SplitContainerView.swift`, `app/AppRuntime.swift`
(`buildAndInsertContainer`), `app/Reconcile.swift` (`reconcileContainers`),
`tests-ui/SplitContainerViewTests.swift` (~56 call sites rewritten to the
new API), `app-tests/AppRuntimeAutosplitTests.swift` (constructs two
containers directly and calls `setZoomedPane`; its containers pass the zoom
at initialization -- it also backs I5 by observing arranged layout
independent of zoom).

## Invariants

- I1: A `SplitContainerView` cannot exist with a tree but without its tab's
  zoom; a freshly built container's layout already reflects the zoom with no
  second call.
- I2: `present(tree:zoomedPaneId:)` is the only public way to change what
  the container presents.
- I3: Observable behavior is unchanged: pane frames, hidden/visible state,
  grid submissions, and ratio messages are identical to today for every
  existing scenario (zoom, reveal, tree edit, ratio drag, the 2026-08-16
  incident guarantees).
- I4: Presenting an unchanged tree and zoom writes no pane frame and emits
  no ratio feedback (idempotence, already pinned by an existing test).
- I5: The container still answers `currentPaneLayout()` /
  `currentArrangedPaneLayout()` from its stored tree -- the drag coordinator
  reads these outside any reconcile pass.

## Proof obligations

- PO1 (I1): new `tests-ui/SplitContainerViewTests.swift` test -- construct a
  container for a two-pane tab zoomed on pane A and assert, without any call
  after construction, that pane A's frame is the container bounds and pane B
  is hidden. Runs under `just test-ui` (needs a WindowServer; not in the
  gate).
- PO2 (I3): the existing suite in that file, rewritten to the single entry
  point, passes with its assertions unchanged -- in particular the
  2026-08-16 incident test ("nested split submits only true model slots")
  keeps asserting exactly one true grid per affected pane and none for the
  untouched sibling, in both its hidden and visible arms.
- PO3 (I4): the existing "reapplying layout writes no pane frame and emits
  no ratio" test, rewritten to `present`, passes.

## Verification

`just test-ui` (PO1-PO3 live there), then `just test` before commit.

## Non-goals

- CHROME-3's visibility gate on `setGridDimensions` (hidden panes still
  submit grids during a resize). It changes behavior for background
  programs, is blocked on the user's decision, on the INPUT-3
  `PanePresentation` fold, and on the measurement its Verification block
  prescribes.
- Any change to `ContainerOp` or `computeContainerOps` (MODEL-3 territory).
- Any change to when layout passes run (`layout()` override,
  `autoresizingMask`, eager mounting).

## Delivery note

After the commit lands, tick CHROME-2's box in `## Plan of work` of
`docs/scratch/2026-08-26-improvement-audit.md` and append the commit hash.

## Implementation discretion

- Whether `init` lays out directly or defers to the first AppKit layout
  pass, provided PO1 holds.

## Commit progress

- [x] 1. refactor: unify split container presentation
- [ ] 2. docs: record CHROME-2 completion
