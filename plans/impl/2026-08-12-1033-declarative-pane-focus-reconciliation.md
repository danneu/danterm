# Declarative Pane Focus Reconciliation

## Problem

Incremental pane-tree patches preserve wrapper identity but temporarily detach
views. AppKit clears first responder when the focused view leaves its hierarchy
and does not restore it when the same view returns. Split, close, move, swap,
zoom, and unzoom can therefore leave the window itself as first responder, so
keystrokes reach no pane until the user moves focus away and back.

The model already records the desired pane in the selected tab's
`focusedPaneId`, but active search state does not record whether the terminal or
its search field most recently claimed focus. The current imperative responder
commands duplicate only some of that policy, which is why operations that emit
no such command can strand focus.

## Decision

Make pane focus a declarative reconciliation pass. Active search state records
which in-pane control owns focus: search activation starts with the field, and
first-responder transitions to either the terminal or field update that owner.
A pure projection derives the desired target from the selected tab's focused
pane and its in-pane owner. After container and pane-chrome reconciliation, a
thin AppKit applier makes that live target first responder when pane focus is
unclaimed or points at a different pane target.

The applier preserves a deliberate non-pane claimant in the main window, such
as a sidebar editor or theme browser control. Because an AppKit field editor is
the window's responder rather than its control, claimant detection resolves a
field editor back to the control or delegate that owns its editing session. The
window itself is not a claimant, so a responder stranded by reparenting is
repaired without classifying which tree operation occurred.

Reducers remain the authority for pane-focus policy. Any reducer that chooses
a pane records `focusedPaneId` and focus-mode alert effects before
reconciliation; responder callbacks continue to record focus initiated by
AppKit interaction. The reconciler reads that decision and does not infer
foreground split, close succession, move intent, or zoom behavior from a tree
diff.

Remove the internal pane and search-field first-responder commands, the command
phase split that exists only to defer them, and mount-time focus. Session focus
signaling that is not view synchronization remains separate. Update the
model-driven reconciliation design contract to record the new focus ownership
and its ordering after pane chrome.

Add a read-only `danterm focus` query, backed by `focus.info`, so the running
app exposes its actual key focus owner as one of these JSON results:
`{"focus":{"type":"terminal","paneId":"..."}}`,
`{"focus":{"type":"searchField","paneId":"..."}}`,
`{"focus":{"type":"nonPane"}}`, or `{"focus":{"type":"none"}}`.
Keep search focus ownership ephemeral and excluded from persistence. Other CLI
and IPC behavior does not change. A foreground split in a background tab
updates that tab's focused pane for its next selection but does not steal focus
from the selected tab. Update `integrations/danterm/SKILL.md` with the query in
the same change.

## Invariants

- **I1.** Model focus, focus chrome, the model-declared in-pane owner, AppKit
  focus, and the control receiving the next key converge before the initiating
  event completes.
- **I2.** The desired responder is the selected tab's focused pane, using its
  search field while active search state declares field ownership and its
  terminal otherwise.
- **I3.** Tree reconciliation neither needs to identify the operation that
  produced a patch nor duplicates its pane-selection policy.
- **I4.** Background-tab changes and deliberate non-pane focus claimants do not
  lose first responder to pane reconciliation.
- **I5.** Responder safety preserves incremental reconciliation: it does not
  require a full container rebuild, delayed retry, or synthetic key forwarding.

## Proof Obligations

- **PO1.** Pure projection tests prove the desired target after foreground and
  background split, focused-pane close, move or swap, zoom or unzoom, tab
  selection, search start or end, and focus transitions between an active
  search field and its terminal. (I1-I3)
- **PO2.** Pure update tests prove every pane-focus intent is recorded eagerly,
  while background-tab operations leave the selected tab's desired target
  unchanged. When directional navigation begins recording focus eagerly, it
  also takes over the focus-mode alert clearing previously performed by the
  responder callback. (I1, I3, I4)
- **PO3.** AppKit coverage proves that reparenting a focused pane or active pane
  search control can strand first responder, and proves claimant detection for
  terminal content, field-editor-backed controls, the window, and deliberate
  non-pane controls. (I2, I4)
- **PO4.** In an isolated source-tree app, drive foreground split, background
  split, zoom, and unzoom through the CLI and assert through `danterm focus`
  that the running reconciler leaves the intended terminal or search field in
  control. Confirm the new foreground pane accepts its first typed keystroke
  without a focus round trip. (I1, I2, I4)
- **PO5.** The targeted core tests, full local gate, and one captured UI-harness
  run pass. Protocol and CLI tests pin the focus-query grammar and JSON shape.
  The regression coverage names the 2026-08-12 split incident. (I1-I5)

## Rejected Ideas

- **RI1.** Capture and restore the pre-patch responder while classifying each
  tree edit. This duplicates reducer policy in the view layer and makes the
  central behavior depend on stateful AppKit logic the repository cannot test
  through its real runtime.
- **RI2.** Add responder commands to the tree operations that currently omit
  them. This preserves two authorities and lets the next forgotten emission
  recreate the bug.
- **RI3.** Rebuild the whole container to recover mount-time focus. This undoes
  incremental reconciliation and restores pane-count-dependent work.
- **RI4.** Forward keys or restore focus on a later run-loop turn. Both permit
  observable lost input and mask the broken responder contract.
- **RI5.** Put every non-pane focus claimant in the model. Sidebar rename is
  deliberately view-local and separate-window panels do not contend for the
  main window's responder, so claimant detection is the smaller mechanism.

## Implementation Discretion

- The exact internal representation of the pure desired target and the helper
  boundaries in its thin AppKit applier.

## Commit progress

- [x] 1. fix(focus): reconcile pane responders from model state
- [ ] 2. feat(cli): expose the live pane focus owner
