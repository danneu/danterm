# Reconcile tab selection and MRU as one state

## Problem

`AppModel.selectedTabId` must name a live tab, but repair after the
selected tab dies is hand-written per removal path, and the policies
disagree (audit finding S56, verified live 2026-08-18):

- `closeTabRemoval` picks the predecessor tab, then the successor
  (`lib/DanTermCore/Sources/DanTermCore/Update.swift:1906-1914,
  1940-1942`) -- pinned by tests (UpdateTabTests.swift:1266, 1285, 1306).
  This helper serves the whole close family: explicit tab close, batch
  close, and the last-pane-removal arm of `closePaneBody`
  (Update.swift:1655-1661), which `.sessionProcessExited` and
  `.sessionEnded` reach through `.closePane` (Update.swift:754-757).
  Nothing pins the session-exit route's selection outcome.
- `.sessionCreationFailed` jumps to the first tab in flattened order
  (Update.swift:785-786). No test pins the selection outcome.
- `deleteGroupBody`'s non-move arm repeats the first-tab rule as a third
  copy (Update.swift:1559-1562). No test pins it.
- deleteGroup with `moveTabs` and `.movePaneToTab` rely on their own
  local reasoning; nothing structural stops a future removal path from
  forgetting the repair entirely.

The user lands on different tabs depending on *how* their tab died, and
the invariant is unenforced.

## Evidence / load-bearing premises

- `update()` already has a deferred reconcile chokepoint built for
  exactly this problem class (Update.swift:12-23: `reconcileMru`,
  `reconcileTodoPopover`, `reconcilePendingConfirmation`,
  `reconcileSidebarRenameTarget`); its comment says every path that
  mutates tab membership or selectedTabId reaches it.
- The chokepoint covers all tab/group mutation paths. IPC dispatch runs
  inside `update()` (`IpcDispatch.swift#handleIpcRequest`, invoked from
  the `.ipcRequest` arm). The one whole-model write that bypasses
  `update()` is `AppRuntime.commitRestoreSession`
  (app/AppRuntime.swift:1844), and its input comes from
  `validateAndBuildDetailed` (Model.swift:918-933), which already
  guarantees at least one tab and a live selection.
- `mruOrder` is maintained at the same chokepoint with the canonical
  invariant `mruOrder[0] == selectedTabId` when not cycling
  (ModelOperations.swift#reconcileMru, #mruOrderIsCanonical). The
  surviving prefix of `mruOrder` identifies the most recently used live
  tabs, while live tabs missing from MRU history use flattened tab order
  as their fallback.
- Existing repairs change `selectedTabId` without emitting
  `.focusSession`; focus follows via the `desiredPaneFocus` projection.
  The defer cannot deliver commands, so the repair keeps that property.

## Decision

Replace the standalone MRU reconcile with one tab-state reconcile pass
in the `update()` defer. It derives one ordered live-tab snapshot,
repairs `selectedTabId` from the surviving MRU order when necessary,
and canonicalizes `mruOrder` from the same snapshot. Selection validity
and MRU order therefore have one owner and cannot be reconciled
independently. Delete the two ad-hoc first-tab repair blocks. The close
family -- everything routed through
`closeTabRemoval`, which is explicit tab close, batch close, and the
last-pane removal that a pane close or a session exit triggers -- keeps
its predecessor-then-successor selection as a deliberate move
(user-confirmed policy), same category as `.movePaneToTab`'s jump to the
target tab. The reconcile pass owns every other removal.

Behavioral scope (the deliberate changes):

- After a session-creation failure or a group deletion removes the
  selected tab, selection lands on the most recently used surviving tab
  instead of the first tab in flattened order.
- A tab created into a model with no tabs becomes selected even when
  created `background: true` (reachable only via IPC in the launch
  window before the first tab exists; previously left selection nil).
- When the last tab is removed, `selectedTabId` becomes nil instead of
  dangling on the dead id (the app terminates in that state anyway).

Critical files: `lib/DanTermCore/Sources/DanTermCore/Update.swift`
(defer, two deleted blocks), `ModelOperations.swift` (the unified
tab-state reconcile and its live-tab snapshot), tests in
`lib/DanTermCore/Tests/DanTermCoreTests/` (UpdateMruTests,
UpdateGroupTests, UpdateSessionEventTests, ModelOperationsTests) using
the existing TestSupport helpers (`makeModel`, `createTab`,
`sessionId(for:in:)`, `.deleteGroup(id:moveTabs:)` direct route).

## Invariants

- I1: After every `update()`, `selectedTabId` names a live tab, and is
  nil iff no tabs exist.
- I2: When the selected tab is removed by a path that makes no
  deliberate selection move of its own -- session creation failure and
  group deletion -- selection lands on the most recently used surviving
  tab (first tab in flattened order only when no MRU history covers the
  survivors).
- I3: The close family keeps predecessor-then-successor selection:
  explicit tab close, batch close, and the last-pane removal reached
  from a pane close or a session exit. They share `closeTabRemoval`, and
  they share the policy, so no user-visible selection depends on which
  of them fired.
- I4: Selection repair and MRU canonicalization are one reconciliation
  result. At the end of every `update()`, `mruOrder[0] == selectedTabId`
  when not cycling, including the tick that repaired selection.
- I5: A background-created tab never steals a live selection (existing
  behavior, unchanged; the nil-selection case in scope above is not a
  steal -- there was no selection).

## Proof obligations

TDD per repo rules. PO1-PO5 drive the change: write each first and watch
it fail for the expected reason. PO6 and PO7 are characterization --
they pin behavior this plan does not change, so they are written first
and must pass before the code changes as well as after.

- PO1 (I1, I2): `.sessionCreationFailed` on the selected tab selects
  the MRU-previous live tab, in a model arranged so the MRU answer and
  the first-tab answer differ (the existing
  UpdateSessionEventTests.swift:210-243 scenario cannot tell the two
  policies apart).
- PO2 (I2): `.deleteGroup(moveTabs: false)` containing the selected tab
  selects the MRU-previous live tab, likewise arranged so the policies
  differ.
- PO3 (I1): a background tab created into a tab-less model becomes
  selected.
- PO4 (I4): after a repair through `update()`, `mruOrder[0] ==
  selectedTabId` and both name the MRU-previous surviving tab.
- PO5 (I1, I2, I4): unified reconcile directly, with no removal path
  involved -- a dead selection and several live survivors, arranged so
  the MRU-first survivor and the flattened-first tab differ, selects the
  MRU-first survivor and makes it `mruOrder[0]`; a live selection stays
  untouched; a dead selection with no survivors goes nil; and a second
  reconciliation changes nothing in any of these cases.
- PO6 (I3, I5): the pinned predecessor/successor close tests and the
  background-does-not-steal tests pass unchanged.
- PO7 (I3): `.sessionProcessExited` for the only session of the selected
  tab selects the predecessor tab, in a model arranged so the MRU answer
  and the predecessor answer differ. This pins the close family's shared
  policy on the one route that currently has no test, so a later reader
  sees it as decided rather than forgotten.

## Non-goals

- The restore default (`validateAndBuildDetailed` first-tab fallback,
  Model.swift:924-929) stays as is: no removal happened, no MRU history
  exists, and SnapshotTests pin it.
- No `.focusSession` emission from the repair; focus continues to
  follow the reconcile projection.
- No change to the deliberate selection moves in `.movePaneToTab`,
  `.movePaneToNewTab`, or deleteGroup-with-moveTabs.

## Rejected ideas

- RI1: `private(set) var selectedTabId` plus removal primitives (the
  audit's proposal). A second enforcement architecture beside the
  existing reconcile chokepoint; the chokepoint already covers every
  mutation path (see Evidence), so primitives add API without adding
  coverage.
- RI2: MRU policy for the close family too. Rejected by the user for
  explicit close, and the last-pane and session-exit routes share that
  helper and that policy; splitting them would make the landing spot
  depend on whether the user pressed Cmd-W or typed `exit`.
- RI3: First-tab backstop. An arbitrary landing spot when the MRU
  answer is available at the same chokepoint for free.
- RI4: Separate selected-tab and MRU reconcile passes. Both derive the
  same live-tab facts and maintain a coupled invariant; separate passes
  duplicate work and permit one side to change without the other.

## Accepted risks

- AR1: The background-create-into-empty-model selection change (scope
  above) alters an unpinned IPC-reachable behavior; selecting the only
  tab is judged strictly better than a nil selection with a live tab.

## Implementation discretion

- D1: The unified reconcile's exact name and internal helper factoring.
  One pass must own both selection repair and MRU canonicalization, but
  its private structure is not contractual.

## Verification

1. All of PO1-PO7 written first: PO1-PO5 failing for the expected
   reason, PO6 and PO7 passing already.
2. `swift test --package-path lib/DanTermCore` green.
3. `just test` green (full gate, includes core-purity lint).
