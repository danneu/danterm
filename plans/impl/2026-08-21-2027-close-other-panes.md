# Close Other Panes

## Problem

The pane menu can close its target pane, but it cannot keep that pane and close
the other panes in the same tab. The command must not appear when the pane has
no siblings, and it must preserve the safety behavior of existing interactive
closes.

The terminal right-click menu, toolbar `...` menu, and drag-handle right-click
menu share one builder. They therefore form one behavioral surface for this
feature.

## Decision

Add `Close Others` directly below `Close Pane` in the shared pane menu when the
targeted pane has at least one sibling. The action keeps the pane whose menu was
opened and closes every other pane in that pane's current tab as one model
transition.

Use the existing close-confirmation system for the affected panes. Close one
idle sibling immediately. Ask for confirmation when the action affects two or
more panes, or when any affected pane has a running command or an unfinished
pane task. The confirmation uses singular or plural pane copy for the affected
count and names how many panes will close.

## Invariants

- `Close Others` is absent when the targeted pane is the only pane in its tab.
- The action resolves the targeted pane against the live model. A stale pane id
  does nothing, and a menu for a background tab never acts on the selected tab.
- A pending confirmation is retracted if the targeted pane leaves the model.
  Answering that stale confirmation closes nothing.
- The targeted pane and its full pane state survive. It becomes the tab's
  focused pane, the tab survives, and pane zoom is cleared.
- Every other pane in that tab closes atomically. No pane in another tab closes.
- Each closed pane gets the same teardown behavior as an individual pane close,
  including pending IPC rejection, alert removal, pane popover dismissal, and
  session and view removal through reconciliation.
- Confirmation impact includes only panes that will close. It excludes the
  retained pane and tab-level tasks because both survive.
- If the affected set or its running work grows while confirmation is open, the
  user sees a refreshed confirmation before anything closes.
- Canceling confirmation leaves every pane unchanged.

## Proof Obligations

- UI behavior proves all three shared menu entry points show `Close Others`
  immediately below `Close Pane` only when live tab membership contains a
  sibling, and route the action to the pane whose menu opened.
- Core behavior proves a single-pane request is a no-op and a nested multi-pane
  tab retains only the requested pane without changing another tab.
- Core behavior proves the retained pane is focused and unzoomed and every
  removed pane receives the ordinary close cleanup.
- Confirmation behavior proves the count and work thresholds, affected-only
  impact and count copy, and confirm and cancel outcomes.
- One interleaving proof removes the targeted pane while confirmation is open
  and proves the confirmation retracts and a late answer closes nothing.
- Separate interleaving proofs add a sibling and start new work in an affected
  pane while confirmation is open. Each proves the user is re-asked before any
  pane closes.
- The targeted core suite and UI harness pass, followed by the full `just test`
  gate.

## Non-goals

- Do not add the command to the top-level macOS Pane menu.
- Do not add or change CLI, IPC, persistence, or external compatibility
  surfaces.

## Accepted Risks

- A confirmation may remain visible after every affected sibling exits. A
  later answer closes nothing, so this presentation staleness has no deletion
  risk and does not justify another retraction rule.

## Implementation Discretion

- Internal message, tree-operation, and confirmation-state shapes are left to
  implementation as long as the atomicity and confirmation invariants hold.
- Exact confirmation wording and destructive button titles are left to
  implementation, subject to the affected-count requirement.
