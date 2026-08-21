# REDUCE-2: `.startSearch` opens the pane's search state directly

Source: `docs/scratch/2026-08-18-construction-audit.md` REDUCE-2 (as corrected
there). Dependency MODEL-5 landed in `03203c2d`; live search state is
`PaneModel.live.search`.

## 1. Problem

Cmd-F is a decision the reducer already makes, but the reducer does not record
it. Today `.startSearch` returns `.sendStartSearch(paneId:)`; the runtime calls
`SwiftTerminalSessionView.startSearch()`, whose whole body emits
`TerminalSessionEvent.searchStarted("")`; that becomes `Msg.searchStarted
(paneId:needle:)`, whose arm finally writes `pane.live.search` and
`focusOwner = .field`. The trip gains no information, the `needle` argument is
always `""` (the `if !needle.isEmpty` branch is dead outside tests), and between
the two steps the model says search is closed while the view is opening it. If
the pane's session is not mounted yet, the command is dropped and Cmd-F does
nothing.

Evidence: `Update.swift` `case .startSearch` / `case .searchStarted`;
`AppRuntime.perform` `.sendStartSearch`; `SwiftTerminalSessionView.startSearch`;
`TerminalBackendBoundary.terminalMessages`. `SwiftTerminalSessionView` is the
only emitter of `.searchStarted` in app/, lib/, ios/, tests-ui/, app-tests/.

Load-bearing premises (verified in the current tree):

- P1. The overlay mounts from model state: `reconcilePaneChrome` diffs
  `desiredSearchOverlays(in:)` (`app/Reconcile.swift`).
- P2. The caret moves from model state: `reconcilePaneFocus` applies
  `desiredPaneFocus(in:)`, which names `.searchField` when the focused pane's
  `live.search?.focusOwner == .field`, and it runs after `reconcilePaneChrome`
  in the same sweep (`app/Reconcile.swift`, `app/PaneFocusReconciliation.swift`).
- P3. Cmd-F while search is already open keeps the typed needle and only
  reclaims field ownership. This follows from the arm's `if !needle.isEmpty`
  guard against the production payload `""`; no existing test drives that
  re-entry path (`searchStartedWhileActiveUpdatesNeedleAndOwner` sends a
  non-empty needle and pins the dead replacement branch instead), so PO2 is new
  coverage of a behavior only the guard holds up today.

Desired outcome: the reducer writes the open-search state itself and the whole
round trip is deleted, so no model state can say "closed" after the reducer
decided "open".

## 2. Decision

`.startSearch` writes the selected tab's focused pane directly -- create
`live.search` only when it is nil, then set `focusOwner = .field` -- and returns
no command. Delete the round trip end to end: `Command.sendStartSearch` and its
`perform` arm, `Msg.searchStarted` and its arm, `TerminalSessionEvent.
searchStarted` with its `terminalMessages` case and its characterization
description, the `TerminalSession.startSearch()` requirement, and
`SwiftTerminalSessionView.startSearch()` together with every test-double
conformer's stub.

Why this and not the cheaper fallback (keep the command, drop `needle`): the
fallback keeps the window where the model disagrees with the reducer's own
decision and keeps a protocol method whose only job is to echo. Nothing the
engine does is lost; the search-needle, navigate, and end-search commands are
untouched.

Scope: reducer, command/message vocabulary, the session protocol, and the tests
that drive `.searchStarted` directly. No change to overlay views, focus sweep,
or engine search.

## 3. Invariants

- I1. After `.startSearch` with a selected tab, the focused pane's live search
  exists with `focusOwner == .field` and no command is emitted; the overlay and
  caret follow from P1/P2 without a further message.
- I2. `.startSearch` on a pane whose search is already open keeps its needle
  and status and sets `focusOwner = .field` (preserves P3).
- I3. `.startSearch` with no selected tab changes nothing and emits nothing.
- I4. No message or event can open search on a pane the reducer did not choose:
  "search opened by a backend report" is not expressible (the message is gone),
  which supersedes MODEL-5's orphan-pane narrowing test.
- I5. Search-needle, navigate, end-search, total/selection reports, and their
  reconcile behavior are unchanged.

## 4. Proof obligations

- PO1 (I1): reducer test -- `.startSearch` on a fresh tab yields field-owned
  empty search on the focused pane, empty command list, and
  `desiredPaneFocus == .searchField(pane)` / `desiredSearchOverlays[pane]`
  present.
- PO2 (I2): reducer test -- open search, set a needle, hand focus back to the
  terminal, send `.startSearch` again; needle intact, owner `.field`, no
  command.
- PO3 (I3): reducer test -- `.startSearch` on an empty model is a no-op.
- PO4 (I4): the build proves it: `Msg.searchStarted`, `TerminalSessionEvent.
  searchStarted`, and `Command.sendStartSearch` no longer compile.
  `UpdateSearchTests.searchStartedForMissingPaneCreatesNoOverlay` and
  `searchStartedWithNeedleSetsNeedle` are deleted with a note that the state
  they guarded is unrepresentable.
- PO5 (I5): existing suites stay green after their setup calls move off
  `.searchStarted(paneId:needle:)`. `.startSearch` is the replacement only where
  the setup means "the user activated search on the focused pane". A setup whose
  point is that search is already open on a pane that is *not* focused --
  `UpdateSearchTests.searchFieldFocusReportAdoptsItsPane` opens search on pane B
  while pane A holds focus -- must keep that shape, so it establishes the
  fixture through pane state rather than through an activation message.
  Suites: `UpdateSearchTests`, `ReconcileTests`, `ProjectionsTests`, `CheckpointCaptureTests`,
  `TerminalBackendBoundaryTests`, `app-tests/AppRuntimeSessionCommandTests`,
  `tests-ui/SwiftTerminalSessionViewTests` (drops the `.searchStarted("")`
  expectation), `tests-ui/SplitContainerViewTests` (overlay + field focus,
  unchanged).
- PO6 (P1, P2 end to end): `just test-ui` green, plus one live slot check that
  Cmd-F mounts the overlay with the caret in the field, a second Cmd-F keeps the
  needle, and Esc/close still tears it down.

## 5. Non-goals / Accepted risks / Rejected ideas

- Non-goal: changing what happens when a non-pane control (sidebar rename, todo
  popover) holds first responder during Cmd-F; the focus sweep's `.nonPane`
  rule is untouched and behaves as today.
- Non-goal: REDUCE-5 (alert raising) -- same file, different arms; no coupling.
- RI1. Keep `sendStartSearch` and only drop `needle` -- rejected; see Decision.
- AR1. Cmd-F on a pane whose session has not mounted now opens the overlay
  (today it is silently dropped). Accepted as the correct behavior.

## 6. Implementation discretion

- How tests that previously started search with a non-empty needle now set it
  (`.searchNeedleChanged` vs writing `live.search?.needle`).
- Whether the three `.startSearch` reducer tests replace the existing
  `searchStarted*` tests in place or get fresh names.

## Merge notes

No overlap with in-flight work: `worktree-pane-focus-pane-id` touches CLI /
protocol only; the locked agent worktree edits `app/AppRuntime.swift` around
line 1389 (launch recovery), far from the two arms this plan deletes.

## Implementation notes

- Discretion point 1: tests that needed a needle now set it with
  `.searchNeedleChanged` after `.startSearch`, rather than writing
  `live.search?.needle`, so the setup stays behavioral.
- Discretion point 2: the three `.startSearch` reducer tests got fresh names
  (`startSearchOpensFieldOwnedSearchOnFocusedPane`,
  `startSearchOnOpenSearchKeepsNeedleAndReclaimsField`,
  `startSearchWithNoSelectedTabChangesNothing`); the four `searchStarted*`
  tests were deleted, and the suite header now says why the deleted states are
  unrepresentable.
- `UpdateSearchTests.searchFieldFocusReportAdoptsItsPane` keeps its fixture
  shape per PO5, so it writes `live.search` on the unfocused pane B directly --
  no activation message can open search on a pane that does not hold focus.
- PO6 live check on slot 1: Cmd-F mounted the overlay and `danterm focus`
  reported `searchField`; typing `hello` and pressing Cmd-F again left the
  needle in place; Escape tore the overlay down.
