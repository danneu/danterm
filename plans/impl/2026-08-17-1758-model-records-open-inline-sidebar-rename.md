# The model records an open inline sidebar rename

## Problem

The model is not a truthful record of whether a sidebar edit session is open,
so no state query can report one. An edit session begins two ways today, and
only one goes through the model:

- The group-creating messages set `sidebarRenameTarget` as a side effect, and
  the reconcile pass opens the editor when the projection's rename target
  changes.
- A double-click on a sidebar row calls into the sidebar view directly and
  begins editing without the model knowing a session exists.

A human-reported rename bug comes from the second path, so an agent
reproducing one is looking at exactly the case the model does not hold.

## Decision

**D1 -- one model-level message begins every inline rename.** A begin-rename
message sets `sidebarRenameTarget`; the double-click handler sends it instead
of calling the view, and the group-creating messages set the target through it.
The reconcile pass stays the only thing that opens an editor.

**D2 -- the state query reports the open session.** The listing the CLI already
uses for state gains the pending rename target. D1 is what makes this honest:
without it the query would report no session while a double-click editor is
open.

`integrations/danterm/SKILL.md` changes with the surface, per the standing rule.

## Invariants

- **I1.** An inline edit session begins only when `sidebarRenameTarget`
  changes. Menu and double-click are its writers; neither opens an editor by
  another route.
- **I2.** Beginning a rename while a session is live ends the live one and
  opens the new one, whichever writer asks.
- **I3.** The state query names the entity whose editor is open, and reports
  none once the session ends.
- **I4.** The pass reports whether an editor actually opened. A begin request
  the pass cannot honor -- the row is not mounted, or sits inside a collapsed
  group -- leaves no open session recorded, so the model never claims a session
  that does not exist.

## Proof obligations

- **PO1 (I1).** A double-click leaves the model reporting an open session on
  the clicked row -- the fact the model does not hold today.
- **PO2 (I1).** Ablating the reconcile pass's editor-opening step stops both
  writers from opening an editor.
- **PO3 (I2).** A second begin-rename against a different row, issued while the
  first editor is open, leaves exactly one session open and it is the second.
- **PO4 (I3).** Each rename-ending cause reachable without a CLI editor trigger
  ends with the state query reporting no open session.
- **PO5 (I4).** A begin request against a row the pass cannot open an editor on
  -- covering both an unmounted row and a row inside a collapsed group -- ends
  with the state query reporting no open session, and a later pass does not
  resurrect one.

## Non-goals

- **A CLI flag that opens the editor.** Deferred until an agent is actually
  blocked reproducing a live rename issue. The design is settled: `--edit` on
  the existing `group rename` / `tab rename` verbs, sending D1's message and
  nothing else. Building it then costs one flag, because D1 has already put the
  entry point in the model.
- Asserting the editor's on-screen appearance. The row's displayed title is
  model-backed once a session ends, so model-level assertions carry the intent.
- **Revealing a target the user cannot see.** Scrolling an offscreen row into
  view or expanding a collapsed group so its editor can open is a separate
  behavior change. Renaming such a row already does nothing today, and I4 makes
  that outcome honest rather than silently stale.

## Accepted risks

- **AR1.** The five rename-ending causes the reconcile work deferred to a live
  GUI check stay hand-run until the deferred flag exists. PO4 covers only the
  causes reachable without a CLI-opened editor. The judgment is that the
  incident history makes the flag likely but not certain to be needed, and a
  written-down design costs less than an unused surface.

## Rejected ideas

- **RI1.** Driving the editor through accessibility or UI scripting. It
  bypasses the model, which is the thing the remote-controllability rule exists
  to prevent.
- **RI2.** A command that runs a named rename scenario. It is not general: it
  would serve this check and no future one.
- **RI3.** Exposing the rename target without D1. The query would report no
  session while a double-click editor is open, which is worse than no query.
- **RI4.** Building the `--edit` flag now on the strict reading of the rule
  that a missing remote-control action must be added to the API. Rejected on
  the rule's intent -- no agent is blocked today, because the five ending
  causes are already hand-run -- and because D1 lands the entry point in the
  model, so building the flag when an agent is actually blocked costs one flag.

## Implementation discretion

- Whether the begin-rename message carries one target value or separate tab and
  group cases.

## Implementation notes

- The rename-end message now names the session it ends, and `update` retracts
  the pending target only when the names match. I2 forces this: when a second
  begin supersedes a live session, the pass commits the predecessor and reports
  its end after the sweep, so a blanket clear would retract the successor's
  target while the successor's editor is open. Sliced out as commit 1 because it
  is a self-contained no-op refactor that touches every rename-end site.

- The begin message carries one target value, and the menu, the double-click,
  and the two group-creating messages all send it. That retired the view's
  `beginRenamingTab` / `beginRenamingGroup` entry points, which had no
  production caller left; the UI suites now open an editor the way production
  does, through a shared `beginRenameThroughModel` test helper.
- The pass still opens an editor only when the projected target CHANGES. The
  weaker rule -- open whenever the view's session differs from the projected
  target -- would reopen the editor a selection change had just ended, because
  the model has not yet seen the end the same pass reported.
- I4 reports the end from the view's begin, so an unhonored request retracts
  itself. The UI proof runs the collapsed-group row and an unmounted row far
  below a short window; ablating the report fails it.

## Commit progress
- [x] 1. The sidebar rename end names the session it ends
- [x] 2. Every inline sidebar rename begins through the model
- [ ] 3. The state listing reports the open inline rename

## Follow Up

- `SidebarView.resetRecycledRenameState` (app/SidebarView.swift) clears a live
  session without reporting its end, so the model can keep a pending target
  after a cell reuse killed the editor. A later begin for that same target then
  changes nothing and no editor opens. The reset runs mid-traversal, so the fix
  is to feed its end into the pass's follow-ups.
