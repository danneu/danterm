# Make Pane Removal Valid by Construction

Source: MODEL-7 in `docs/scratch/2026-08-18-construction-audit.md`,
verified against the current tree on 2026-08-21.

## Problem and desired outcome

`PaneTree.remove` reports an empty result while leaving its mutating receiver
unchanged. The receiver therefore still contains the pane that the result says
was removed. All current callers check the result before writing the tree back,
so this is not a live defect, but the API permits a future caller to duplicate
a pane across tabs.

Removal should return an exhaustive outcome. A surviving tree should exist only
in the outcome that has one, and the input tree should remain unchanged. The
lower leaf-removal operation should express the same invariant instead of using
a tuple whose optional values admit contradictory combinations.

## Decision

- Make pane removal non-mutating and give it distinct not-found, emptied, and
  surviving-tree outcomes. Each successful outcome carries the removed pane.
- Do not return a separate focus-moved flag. The returned tree is the authority
  for focus, and no production caller needs the redundant fact.
- Give the leaf-removal operation exhaustive outcomes too. A surviving node
  carries a non-optional successor focus.
- Let removal outcomes drive cross-tab moves, new-tab extraction, and pane
  closing. In particular, new-tab extraction should no longer classify a
  single-pane source separately before removing from it.
- Preserve the existing behavior that moving the sole pane of a tab moves the
  tab entity, including its metadata, rather than replacing it with a new tab.
- Asking to extract the sole pane of the only tab remains a no-op and emits no
  commands.

## Invariants

- I1. An empty removal result cannot expose a tree for callers to install.
- I2. The original tree stays valid and unchanged for every outcome.
- I3. A surviving tree contains every original pane except the removed pane,
  preserves every surviving payload, has a valid focus, and is not zoomed.
- I4. Removing an unfocused pane preserves focus. Removing the focused pane
  uses the existing sibling-successor rule.
- I5. A moved pane keeps its full payload, and an unknown pane id changes
  nothing.
- I6. Existing tab identity and metadata behavior is unchanged when moving a
  sole pane into a new-tab position.

## Proof obligations

- PO1. Direct pane-tree coverage proves all three outcomes, input non-mutation,
  removed-payload preservation, focus behavior, and zoom clearing.
- PO2. Leaf-removal coverage proves empty and surviving shapes, successor focus,
  payload preservation, and the not-found result without optional tuple states.
- PO3. Reducer coverage proves that a cross-tab move removes an empty source tab
  without losing or duplicating panes, while a split source survives with the
  correct pane focused.
- PO4. Reducer coverage proves both new-tab move paths preserve their current
  tab-identity, pane-payload, focus, zoom, and selection behavior, and that the
  sole-pane, sole-tab request remains a no-op with no commands.
- PO5. Reducer coverage proves that closing the final pane removes its tab and
  closing a pane from a split installs the valid surviving tree.
- PO6. The focused core suites and lint pass during development, and `just test`
  passes before commit.

## Non-goals and rejected ideas

- Non-goal: change persistence, IPC, CLI, or any external compatibility
  surface. This is an internal `DanTermCore` refactor.
- Rejected idea: retain the mutating API as a compatibility wrapper. It would
  keep the contradictory receiver state available.
- Rejected idea: use a generic removal abstraction for both tree layers. Their
  surviving outcomes carry different facts, so the abstraction adds indirection
  without strengthening the invariant.

## Implementation discretion

- Exact internal type, case, and method names.

No prerequisite work is required. The active worktrees inspected on 2026-08-21
do not overlap the affected pane-removal code.
