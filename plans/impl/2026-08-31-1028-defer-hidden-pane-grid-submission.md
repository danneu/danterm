# Gate grid submission on pane visibility (CHROME-3)

## 1. Problem

Every tab's container is mounted eagerly and autoresizes with the content area,
so a window drag re-frames the panes of every tab. A hidden pane's
`setFrameSize` reaches `synchronizePresentation`
(`app/SwiftTerminalSessionView.swift:1607`), which submits a new grid through
`controller.setGridDimensions` on every cell-boundary crossing. Each submission
costs a `TIOCSWINSZ` to the child plus a full grid-and-scrollback reflow inside
`TerminalPTYHost.applyResize` -- per hidden pane, per crossing, for the whole
drag. The cost of a resize scales with how many tabs exist, not with what the
user is looking at, and nothing observes the intermediate sizes.

The visibility authority already reaches the view: `syncPaneVisibility`
(`app/AppPresentationLifecycle.swift:68`) pushes
`effectivePaneVisibility(in:windowVisible:)` -- selected tab, window occlusion,
zoom -- to every session via `setVisible(_:)`. The view forwards it to the
controller and stores nothing; `setGridDimensions` ignores it.

Source finding: CHROME-3 in `docs/scratch/2026-08-26-improvement-audit.md`
(impact 3, confidence 5). Its two prerequisites landed: INPUT-3 (the folded
`PanePresentation`, e7de7081) and CHROME-2 (`present(tree:zoomedPaneId:)`,
fe3a1d99).

## 2. Decision

Gate automatic, rectangle-derived grid submission in the view on the
model-pushed visibility. A hidden pane keeps deriving and recording its
presentation but submits nothing for frame, font, or scale changes; the
hidden-to-visible transition submits once, carrying the final geometry, when
it differs from the last submission. Explicit grid-override changes --
`pane resize` setting a grid and `--fit` clearing one -- submit immediately,
even while hidden: the CLI contract is that `pane resize` decides the grid a
pane runs at, whatever rectangle it occupies (`integrations/danterm/SKILL.md`,
"Run a pane at an exact grid"), and a remote client may be consuming that pane
while the Mac tab is never revealed.

The gate lives in `SwiftTerminalSessionView`, not in
`TerminalPaneSession.setGridDimensions`, so the session's contract ("submits
every valid geometry report, preserving order") stays true and geometry
deferral sits where geometry is derived.

The rectangle-derived half is a deliberate behavior change, not only an
optimization: a program in a background tab learns the new window size when
its tab is revealed, not while the user drags. That is tmux's behavior. The
change was put to the user in the verify-issue pass and accepted.

Ordering facts the design leans on: pane creation and its first layout run
before the sweep's visibility pass (`app/Reconcile.swift:83-123`), so the view
must treat itself as visible until the first `setVisible` push. On reveal with
a grid owed, the sequence is: submit the grid, fence the controller's state
(`synchronizeState()`), then forward `setVisible(true)`. Call order alone is
not enough -- `setGridDimensions` queues the resize asynchronously
(`TerminalPTYHost.resize`) while `setVisible(true)` synchronously plans a
frame from the cached terminal, so without the fence a reveal can publish one
old-grid frame -- the stale reveal this design exists to prevent. The fence
already exists for exactly this ("fences host work and applies the newest
state", `TerminalPaneSession.synchronizeState`).

## 3. Invariants

- I1: A pane whose model-pushed visibility is hidden submits no grid for
  rectangle-derived changes -- frame, font, or scale -- while hidden.
- I2: The hidden-to-visible transition submits at most one grid: exactly one
  when the current geometry differs from the last submission (the final
  geometry, never an intermediate), none when it does not; an owed submission
  is submitted and fenced (`synchronizeState()`) before `setVisible(true)` is
  forwarded, so the first revealed frame is at the new grid.
- I3: A visible pane's submission behavior is unchanged, including the
  2026-08-16 incident guarantee: a nested split submits one true grid per
  affected pane, none for the untouched sibling, and no container-wide
  placeholder is ever observed.
- I4: A newly mounted pane submits its first view-derived grid before the
  first visibility push can gate submissions.
- I5: An explicit override change submits immediately regardless of
  visibility: setting a grid submits it pinned, and clearing with `--fit`
  submits the rectangle-implied grid unpinned -- including a change where
  only pinnedness differs.

## 4. Proof obligations

All live in `tests-ui` (WindowServer; `synchronizePresentation` needs a
window). `FakeTerminalPaneSessionController`
(`tests-ui/UITestTerminalSession.swift:34`) must start recording `setVisible`
and the `pinned` flag so ordering and pinnedness are assertable.

- PO1 (I1): a hidden pane resized across at least one cell boundary submits
  nothing.
- PO2 (I2): reveal after such a resize submits exactly one grid matching the
  final bounds, in the sequence submit, fence, `setVisible(true)`; reveal
  with unchanged geometry submits nothing. Additionally, controller-level
  coverage (existing in the TerminalPTY suite or added there) proves the
  fence applies a queued resize before the first revealed frame. This pins
  the regression class the pane-geometry ADR exists to prevent -- a revealed
  tab drawing at its old grid.
- PO3 (I3): the visible arm of "Claude Code 2026-08-16 nested split submits
  only true model slots" (`tests-ui/SplitContainerViewTests.swift:206`) keeps
  its assertions. Its hidden arm is rewritten to the new guarantee: zero
  submissions while hidden, and the one grid at reveal is the true model-slot
  grid, never a container-wide placeholder -- the incident's promise moves to
  the reveal, it does not weaken.
- PO4 (I4): a pane mounted and framed before any visibility push submits its
  initial grid once.
- PO5 (I5): setting an override while hidden submits it immediately, pinned;
  clearing with `--fit` while hidden submits the rectangle-implied grid
  immediately, unpinned; a change where only pinnedness differs still submits.

## 5. Non-goals / Accepted risks

- Non-goal: debouncing or throttling submissions for visible panes; the ADR's
  "stream of true sizes during live window resize" stays as is.
- Non-goal: unifying the three independent derivations of pane visibility
  (`effectivePaneVisibility`, `desiredContainerShapes`, `paneLayout`) -- noted
  as a possible future cleanup, not this change.
- AR1: a background program that queries its size between the resize and the
  reveal reads the stale size until its tab is selected. Accepted; matches
  tmux.
- AR2: geometry-stream events that derive from grid submissions are delayed
  for a hidden pane's rectangle-derived changes until reveal. Consistent with
  the behavior choice; explicit override changes are exempt from the gate
  (I5), so the `pane resize` contract is unaffected.
- AR3: while a window is fully occluded, its panes defer submissions too
  (occlusion feeds `effectivePaneVisibility`). Accepted as consistent; the
  reveal path covers de-occlusion because it re-runs the same transition.

## 6. Implementation discretion

- How the view tracks "a submission is owed" while hidden (a last-submitted
  record vs a dirty flag) and where the reveal re-sync hooks into
  `setVisible`.
- Whether to add a `session.gridSubmitted` characterization event beside the
  existing `recordTerminalCharacterizationVisibilityChange`
  (`app/AppRuntime.swift:47`) as an ordering fence; useful, not required by
  the contract.

## Critical files

- `app/SwiftTerminalSessionView.swift` -- the gate, the stored visibility, the
  reveal re-sync.
- `tests-ui/SplitContainerViewTests.swift` -- incident-test rewrite plus the
  new reveal tests.
- `tests-ui/UITestTerminalSession.swift` -- recorder additions.
- `tests-ui/SwiftTerminalSessionViewTests.swift` -- view-level visibility
  tests if they fit better there than beside the container tests.

## Verification

1. TDD: write PO1-PO5 first against the current tree; PO1 and PO2 must fail
   (hidden panes submit today, so nothing is owed at reveal), PO3, PO4, and
   PO5 must pass.
2. `just test-ui` for the suite, `just lint` in the loop, `just test` before
   commit.
3. Optional one-off measurement (not a gate test): with the characterization
   log, open twelve two-pane tabs, drag the window edge ~300pt, and confirm
   hidden-pane submissions drop from ~(crossings x hidden panes) to one per
   pane at reveal, with the selected tab's counts unchanged.

## Commit progress

- [x] 1. perf(terminal): defer hidden-pane grid submission until reveal
- [ ] 2. docs(audit): mark CHROME-3 complete
