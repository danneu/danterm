# One title slot, one writer: declared titles, cwd as display

## Context

After an unclean exit, every recovered tab without a `customTitle` reads as its
cwd. In the production window that turns ~20 tabs into a wall of
`~/Code/danterm`, which is the one moment the title carries information: the
recovered scrollback and the `claude --resume` command are per-tab, and the tab
list is the only way to tell recovered work apart.

The checkpoint is not the problem. It already stores each pane's
terminal-reported title -- a live `last-light.json` carries
`"title": "✳ Observer free pane tape follow"` next to panes whose title is a
cwd -- and restore rehydrates it into the replacement session. The title is
then destroyed within a second.

Probe (raw OSC tape from a fresh fish pane in `just launch-slot`):

| what fish sends | when |
|---|---|
| `ESC ] 0 ; BEL` (empty) | every prompt |
| `ESC ] 0 ; sleep 3` | while a command runs |
| `ESC ] 7 ; file://.../Users/dan` | every prompt |

fish never declares an idle title. The full-path title on every idle pane is
DanTerm's own: an empty OSC 0/2 arms a sticky "title follows cwd" mode, after
which every OSC 7 re-titles the pane to its cwd. A restored pane launches as a
plain shell, so it arms that mode immediately and overwrites the recovered
title.

The root cause is one stored title slot with writers of two different kinds: a
program's claim, and a fallback DanTerm manufactures. Last-writer-wins destroys
the informative one. This also makes the restore rehydration a quiet violation
of D3 in
[docs/design/2026-08-10-session-owned-terminal-reported-facts.md](../../docs/design/2026-08-10-session-owned-terminal-reported-facts.md)
("a delayed report from a dead session cannot rename the replacement").

## Decision

Split the two writers apart.

- **D1.** The engine stops manufacturing titles. An empty OSC 0/2 clears the
  pane's declared title; it does not set it to the cwd, and it arms no mode
  that lets a later OSC 7 do so.
- **D2.** A pane's declared title becomes optional in the model -- present only
  when a program declared one. The cwd is resolved as a display fallback in one
  place instead of being stored as a title.
- **D3.** The checkpointed title stops seeding the replacement session and
  becomes a pane-level *recovered label*: shown while the replacement session
  has declared nothing, dropped for good the first time that pane's session
  declares a title.
- **D4.** Two related resolutions, shared by every consumer. A pane resolves to
  its declared title, then its recovered label, then its abbreviated cwd. A tab
  overlays its `customTitle` on the resolved title of its focused pane;
  `customTitle` is tab-owned and never names an individual pane.
- **D5.** IPC reports the declared title only -- `null` when a pane has none --
  and `integrations/danterm/SKILL.md` changes with it.

Critical files: `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` (the OSC
0/2 and OSC 7 dispatch), `lib/DanTermCore/Sources/DanTermCore/Model.swift`
(session/pane fields, `validateAndBuildDetailed`), `PaneLifecycleReducer.swift`,
`ModelOperations.swift` (`tabChrome` / `tabDisplayTitle`), `Persistence.swift`
(`toPaneSnapshot`), the `?? "Terminal"` sites in `IpcEntityEncoder.swift`,
`Projections.swift`, `PaneRosterProjection.swift`, `TabTodo.swift`,
`AlertPresentation.swift`, `Update.swift`, and `integrations/danterm/SKILL.md`.

## Invariants

- **I1.** An empty OSC 0/2 clears a pane's declared title. No OSC 7, before or
  after it, changes any title.
- **I2.** A pane with no declared title and no recovered label displays its
  abbreviated cwd -- the same string it shows today. A tab with no
  `customTitle` displays what its focused pane resolves to.
- **I3.** A restored pane displays the title its predecessor last declared,
  until its own session declares one; after that the recovered label never
  returns.
- **I4.** A checkpoint stores a pane's declared title, or its recovered label
  when it has no declared title, or nothing when it has neither -- so a tab's
  identity survives repeated crashes.
- **I5.** A replacement session inherits no declared title from the session it
  replaces, and a title reported by the predecessor's id changes nothing. The
  cwd, last command, and agent recovery state restore seeds are unaffected.
- **I6.** IPC reports a pane's declared title and `null` when there is none.

## Proof obligations

- **PO1** (I1): an empty OSC 0/2 followed by an OSC 7 leaves the pane with no
  declared title. Inverts the existing engine test "empty title follows cwd
  until another explicit title arrives".
- **PO2** (I2): the tab and pane chrome for a pane that has declared nothing
  reads as its abbreviated cwd.
- **PO3** (I3): a restore whose checkpoint carries a title shows it; the empty
  clear the replacement shell sends at its first prompt leaves the label
  standing; a non-empty declaration replaces it, and a clear after that falls
  through to the cwd rather than back to the label.
- **PO4** (I4): a checkpoint written from a pane with a declared title and one
  written from a pane carrying only a recovered label both round-trip to the
  same recovered label -- serialization keeps the string, restore reclassifies
  it -- and a pane with neither stores none.
- **PO5** (I5): the replacement session starts with no declared title, and a
  title reported by the predecessor's id after restore changes nothing
  (extends the existing session-identity coverage to the title).
- **PO6** (I6): `ls` / `pane info` report `null` for a pane with no declared
  title and the declared string otherwise.
- **PO7** (premise): the pre-crash program title in the checkpoint is what the
  recovered tab shows -- end to end, not only in the model.

## Non-goals

- No visual mark distinguishing a recovered label from a live title.
- `pane split --title` stays as durable as it is today (a first declaration the
  shell may clear); making a pane-level custom title durable is separate work.
- The pane roster keeps its own resolution -- the running-command fallback and
  the non-abbreviated form it needs for targeting.

## Accepted risks

- **AR1.** A recovered label disappears the first time any command runs in that
  pane, because fish declares the running command as the title. Accepted: the
  short-lived label is the chosen behavior, and renaming the tab makes the name
  permanent.
- **AR2.** `danterm ls` stops reporting a cwd-shaped title for idle panes, so
  agent targeting by "exact pane title" must target the cwd for those panes.
  Accepted and documented in `SKILL.md`; no information is lost, since cwd is
  already its own field.

## Rejected ideas

- **RI1.** Promote the checkpointed title into `customTitle` on restore. Zero
  new state, but it fakes a rename the user never made, pins the tab forever,
  and re-conflates user intent with a terminal fact -- the conflation this plan
  removes.
- **RI2.** Keep the last declared title alive across a clear within a live
  session. fish clears at every prompt, so the pane would read `sleep 3`
  forever.

## Implementation discretion

- How "no declared title" is represented on the wire between the engine and the
  core (an optional payload versus the empty string the OSC itself uses).
- Whether the recovered label lives on the pane or on its session, as long as
  it survives the session swap that restore performs.

## Verification

- Targeted suites plus `just lint` in the loop; `just test` before the commit.
- End to end on a slot (never the production app): `just launch-slot`, declare
  a title in the pane (`printf '\e]0;probe title\a'`), confirm `danterm ls`
  reports it, then kill the app process to leave the session lock behind,
  relaunch the slot, and confirm the recovered tab still reads `probe title`
  while `pane info` reports a `null` title for an untouched idle pane.
  `just stop-slot <n>` afterwards.

## Commit progress

- [x] 1. Make a pane's declared title optional and resolve display in one place
      (D2, D3, D4, D5 minus the doc; PO2-PO6). The engine still manufactures a
      cwd title, so display and `ls` are unchanged in practice -- this commit
      builds the structure the fix needs and leaves the tree green.
- [ ] 2. Stop the engine manufacturing titles (D1, PO1, PO7, `SKILL.md`). This
      is the commit where the recovered label survives and idle panes report a
      `null` title.

## Implementation notes

- The recovered label lives on `SessionModel`, not `PaneModel` (the discretion
  the plan grants). Restore is the only thing that ever swaps a live pane's
  session -- `SessionModel(...)` is constructed in exactly three places, and one
  of them is restore -- so a session-owned label survives every swap that
  happens, and it sits beside `lastCommand` and `lastAgentSession`, the two
  recovery memos it behaves exactly like.
- A declared title is no longer run through `abbreviateHome`. It used to be,
  because the title *was* the cwd; now only the cwd fallback abbreviates, so a
  program that declares a home-prefixed string gets it back verbatim. Two
  `CustomTitleTests` fixtures pinned the old behavior and were rewritten to the
  new contract.
- `formatToolbarLabel` now takes an optional title and is fed `paneClaimedTitle`
  rather than the resolved one. Its old `title == cwd` special case existed only
  to stop the manufactured cwd-title from printing twice; the optional says the
  same thing directly, and the special case stays for a program that really does
  declare its own cwd.
- "A working-directory-only update does not reload the tab row" is no longer
  true, and could not be: an undeclared pane's row title *is* its cwd. The test
  was inverted -- a cwd update reloads the row while the pane has declared
  nothing, and stops reloading it once a program declares a title.
