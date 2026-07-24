# Wire Cmd-F search to the Swift engine's history search

## Problem and outcome

The app already ships a complete backend-agnostic find feature (Cmd-F menu ->
Elm `startSearch`/`searchNeedleChanged`/`searchNavigate`/`endSearch` flow,
`SearchOverlayView` with match counter, reconcile-mounted overlay, focus
handoff), and the Swift engine already implements literal history search over
the logical projection (`Terminal.beginSearch`/`searchNext`/`searchPrevious`/
`clearSearch`/`activeSearchMatchRange`, with reflow attachment and eviction
clamps). But the two are not connected: `SwiftTerminalSessionView`'s four
`TerminalBackend` search methods (`app/SwiftTerminalSessionView.swift:447-450`)
are empty stubs, so on the Swift-engine backend Cmd-F does nothing. There is
also no visual highlight for the match, no engine API for the overlay's
match counter, and no Cmd-G / Cmd-Shift-G accelerators.

Outcome: on the Swift-engine backend, Cmd-F opens the existing overlay, typing
searches history live, Enter/Shift-Enter and Cmd-G/Cmd-Shift-G walk matches,
the active match is visibly highlighted and scrolled into view, the counter
shows selected/total, and Escape closes and returns focus to the terminal.

Evidence for load-bearing premises:

- App flow: `app/AppDelegate.swift` Edit menu (Cmd-F "Find"), `lib/DanTermCore` Msg/
  Command/Update search cases, `app/SearchOverlayView.swift`,
  `app/Reconcile.swift` `desiredSearchOverlays`. All backend-neutral via
  `TerminalSessionEvent.searchStarted/.searchTotal/.searchSelected`
  (`lib/DanTermCore/Sources/DanTermCore/TerminalBackendBoundary.swift:15-17`).
- Engine search: `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`
  (~line 2130 on), tested in `TerminalSearchTests.swift`. `beginSearch`
  selects the newest match and already scrolls it into view.
- Threading: `Terminal` is owned by `actor TerminalPTYHost` (nonisolated
  enqueue -> `apply*` pattern, e.g. `clearSelection` -> `applyClearSelection`);
  `@MainActor TerminalPaneSessionController` fronts it; the app view emits
  events through its `callbackGate`.
- Rendering has exactly one highlight kind today (selection):
  `RenderFramePlanner.selectionRuns` -> `RenderFramePlan.selectionRuns` +
  `selectionBackground` -> filled in `TerminalRenderExecution`.

## Decision

Pure plumbing, same shape as the Cmd-A slice: no new core search machinery.

1. **Engine counter API.** Add a public search-status read on `Terminal`
   reporting the live match count and the selected match's index, derived on
   demand from the existing private match scan (no stored derived state).
   Index orientation: newest match is selected on `beginSearch` and reads as
   1/N; walking older increments — matching macOS Find feel. Existing
   begin/next/previous signatures are unchanged.

   The status type is a **total enum** — `.empty` (a non-empty needle that
   currently matches nothing) and `.matched(selected: Int, total: Int)` — so
   `selected >= total`, a negative total, and "matches exist but none selected"
   are unrepresentable rather than merely untested. An optional-`Int` pair would
   leave those states constructible at every call site and defend the invariant
   with review attention instead of the compiler. A `nil` status means no search
   at all. Boundary mapping for Decision 4: `nil` -> `(total: nil, selected: nil)`
   (the overlay's `--/--`), `.empty` -> `(0, nil)` (its `-/0` failed-search
   display, `SearchOverlayView.swift:152-156`), `.matched` -> `(total, selected)`.

   Totality requires one behavior change: when the active needle found nothing
   but the live scan now has matches — output arrived while a failed search was
   still open — `searchNext`/`searchPrevious` adopt the newest match instead of
   returning false. Without it the engine can sit in "matches exist, none
   selected": the overlay shows `-/1` and Cmd-G does nothing until the user
   types another character.
2. **Highlight the active match only**, as a proper second highlight channel
   through the render pipeline: a theme color for search matches (distinct
   from selection background) and match runs planned from
   `activeSearchMatchRange`, clipped to the viewport like selection runs, and
   drawn so the match reads over selection when they overlap. All-matches
   highlighting is out of scope (the engine tracks one match).
3. **Host/controller plumbing** follows the existing `clearSelection` pattern:
   nonisolated enqueue on `TerminalPTYHost` for begin/navigate/clear, each
   `apply*` publishing a frame update after mutation (the mutation records match-row
   damage per I5, whether or not it scrolls, so the republished frame redraws
   the moved highlight), and reporting the new search
   status back via a `@Sendable` callback; `TerminalPaneSessionController`
   surfaces MainActor-hopping wrappers. The status callback is
   **unconditional**: reported after every begin/navigate/clear regardless of
   whether the terminal value changed — it sits above the pattern's
   `guard terminal != previousTerminal` early return, not below it. Otherwise
   the common failed search (typing up from an empty needle, so `search` is
   already nil and no-match `beginSearch` mutates nothing) reports nothing and
   the overlay never shows the `-/0` this decision promises.
4. **Backend stubs implemented** in `SwiftTerminalSessionView`:
   `startSearch()` must synchronously emit `.searchStarted` (that event is
   what creates `searchState` and mounts the overlay); needle changes and
   navigation drive the controller and emit `.searchTotal`/`.searchSelected`
   from the status callback; empty needle and `endSearch()` clear engine
   search state (which also removes the highlight).
5. **Cmd-G / Cmd-Shift-G**: "Find Next"/"Find Previous" menu items in
   `AppDelegate` dispatching a new paneless core msg that resolves the focused
   pane (like `.startSearch` does) and no-ops when that pane has no active
   search. No find-pasteboard behavior. This is the only Elm-core change.

## Invariants

- I1: With no active search (nil/empty needle, or after clear), the engine
  reports no search status and the renderer draws no match highlight. The
  alternate screen counts as "no active search" for both reads: while
  `inactivePrimaryScreen != nil`, the status read reports nil and
  `activeSearchMatchRange` yields no runs. Reason: match anchors are absolute
  stream rows over scrollback + alt grid, while `scrollProjection` under alt
  reports `topRow: 0, windowRows: rowCount` — so an unguarded scrollback match
  would paint over unrelated alt-screen content at the same numeric row. This
  is the guard `revealSearchMatchIfNeeded` already carries, made consistent.
- I2: Search status is consistent, and consistency is carried by the type
  rather than by discipline: `selected` is always in `0..<total` because the
  status enum cannot express otherwise; "matches exist with none selected"
  cannot arise, because navigation re-attaches to the newest match when a
  failed needle starts matching; and navigation at either end (no wrap) leaves
  status unchanged.
- I3: The active-match highlight always corresponds to
  `activeSearchMatchRange`, clipped to the viewport; an off-viewport match
  produces no runs.
- I4: Search highlight and selection highlight are independent: either, both,
  or neither can render, without corrupting the other.
- I5: Every search mutation (begin/navigate/clear) records the row damage
  needed to render the new match, including when the match changes *within* the
  existing viewport (no reveal scroll). Concretely: the search range joins the
  damage-action snapshot alongside selection/hover, so a mutation damages both
  the old and new match's visible rows. A frame published with `.none` damage
  after an in-viewport match change is a bug — the highlight would go stale.
- I6: Cmd-G/Cmd-Shift-G with no active search on the focused pane is a no-op
  (no commands emitted).
- I7: `startSearch()` on the Swift backend emits `.searchStarted` so the
  overlay mounts even before any engine round-trip.

## Proof obligations

- PO1 (I1, I2): engine tests in `TerminalSearchTests.swift` — status nil with
  no search and after clear; count/index across begin, next, previous, and
  no-wrap edges; a zero-match needle reports `.empty`; a needle matching only
  pre-`less` scrollback while the alternate screen is active reports nil status;
  and — the re-attach case — a needle that matched nothing, followed by output
  containing it, has the next `searchNext` adopt the newest match and report
  `.matched(selected: 0, total: 1)` instead of staying unselected. The
  `selected < total` half of I2 needs no test: the enum makes its negation
  unrepresentable.
- PO2 (I3, I4): planning tests in `TerminalRenderPlanningTests` — match runs
  for in-viewport and off-viewport active matches; selection and match runs
  coexisting; the alt-screen case of PO1 plans no match runs; and a plan
  clipped by row damage (`clipFramePlan`) keeps match runs on damaged rows and
  drops them on undamaged ones — the clipped plan is the app's only render
  path, so unfiltered/unforwarded match runs would pass every unclipped
  planning case while never appearing on screen.
- PO2b (Decision 2 precedence): a pixel-level `TerminalRenderExecutionTests`
  case proving an overlapping search highlight overrides the selection
  background while the glyph text stays visible — coexistence at the planning
  layer (PO2) does not fix draw order.
- PO3 (I5): engine tests in `TerminalSearchTests.swift` — begin, next, and
  previous that move the match *without* scrolling the viewport each drain
  non-empty row damage covering the old and new match rows; clear damages the
  departing match's rows; and a `beginSearch` whose needle transitions
  match -> no match (sets `search = nil`) damages the departing match's rows
  too — a clear in disguise. Plus `TerminalPTYHost` tests alongside the
  existing clearSelection/selectAll tests — begin/navigate/clear each publish
  an update and report status, *and* the mutations that leave the terminal
  value unchanged (a needle that never matched, a navigate at either end) still
  report status even though no frame republishes.
- PO4 (I6): `DanTermCore` update test for the new paneless navigate msg —
  guard behavior with and without active `searchState`.
- PO5 (I7 + end-to-end): manual verification in the running app on the Swift
  backend — Cmd-F, live typing, Enter/Shift-Enter, Cmd-G/Cmd-Shift-G,
  counter, highlight color vs selection, Escape restores terminal focus.

## Non-goals / accepted risks

- Non-goal: highlighting all matches in the viewport (follow-up; engine
  tracks a single match today).
- Non-goal: regex or case-sensitivity options; the engine's existing literal
  + ASCII-fold semantics are used as-is.
- Non-goal: renaming the `ghosttyStartSearch`/`ghosttySearchTotal`/
  `ghosttySearchSelected` msgs; reuse them as-is this slice.
- Accepted risk: the counter is a snapshot taken at each search mutation.
  Concurrent output that adds or evicts matches does not re-report status, so
  `n/N` can drift from the engine until the next mutation; the highlight is
  planned live from `activeSearchMatchRange` and stays correct regardless.
- Accepted risk: the engine-status -> `.searchTotal`/`.searchSelected` ->
  overlay seam is manually verified (PO5), not automated — the view layer is
  AppKit-bound and outside the `just test` gate. Index orientation is still
  pinned by Decision 1 + I2 plus the overlay's `selected + 1`.
- Accepted risk: match rescan per keystroke/navigation on large scrollback;
  the engine already rescans on navigation, and the app already debounces
  short needles. Optimize only if profiling demands it.
- Pre-existing crash caveat (`TerminalPaneSession.swift:244` `planIfNeeded`
  copy): not fixed here; new reads go through host enqueues, not extra
  terminal copies.

## Implementation discretion

- Exact name of the paneless navigate msg, and the case/parameter spelling of
  the status enum (its totality is not discretionary — see Decision 1).

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` (+
  `TerminalSearchTests.swift`)
- `lib/TerminalCore/Sources/TerminalRenderPlanning/{RenderFramePlanner,TerminalRenderPlanning}.swift`,
  `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift`
- `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`,
  `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift`
- `app/SwiftTerminalSessionView.swift`, `app/AppDelegate.swift`,
  `lib/DanTermCore/Sources/DanTermCore/{Msg,Update}.swift`

## Follow-ups (out of scope, for the backlog)

- [ ] Rename the `ghosttyStartSearch`/`ghosttySearchTotal`/`ghosttySearchSelected`
  msgs to backend-neutral names (`searchStarted`/`searchTotal`/`searchSelected`);
  they are engine callbacks now, and the `TerminalSessionEvent` cases feeding
  them are already neutral. Pure Swift-internal rename across 4 files
  (`Msg`/`Update`/`TerminalBackendBoundary`, plus the reset-skip list at
  `Msg.swift:210`); no libghostty relationship — these names never cross the C
  boundary. Leave `ghosttyConfigReloaded`/`ghosttyPrefsRefreshed` alone (genuinely
  Ghostty-coupled). Best done as its own tiny commit, not bundled with the feature.
- [ ] Replace `SearchModel.total`/`selected` (two independently-nullable Ints,
  which allow the impossible "selected without total" state) with one optional
  field fed by one msg, mirroring the engine's total status enum — the app layer
  is currently the only place left where the impossible pair is representable.
- [ ] If a third highlight kind ever appears, generalize the run type
  (`RenderSelectionRun` is really a generic row band) instead of adding a
  fourth parallel array.

## Commit progress

- [x] 1. feat(engine): search-status read and search-mutation damage accounting (PO1, PO3 engine tests)
- [x] 1b. refactor(engine): make search status a total enum and re-attach navigation after a failed needle (PO1 re-attach case)
- [ ] 2. feat(renderer): second highlight channel for the active search match (PO2, PO2b)
- [ ] 3. feat(host): enqueue search begin/navigate/clear with status callback (PO3 host tests)
- [ ] 4. feat(app): implement backend search stubs and Cmd-G/Cmd-Shift-G accelerators (PO4, PO5)

## Implementation notes

- Commit 1: reporting `total = 0, selected = nil` for a failed search (Decision 1,
  PO1) required retaining the needle on a miss, so `SearchState.range` became
  optional and `beginSearch` now keeps a non-matching non-empty needle as an active
  search with no occurrence. This contradicts Decision 3's aside that a no-match
  `beginSearch` "mutates nothing" -- it now does mutate nil -> miss-state, which
  means the failed search *also* damages the departing match's rows and republishes
  a frame. Decision 3's unconditional status callback is still required and still
  correct (a repeated no-match keystroke mutates nothing on the second try).
  An empty needle remains "not a search" and drops the state entirely.
- Commit 1b exists because commit 1 shipped the status as a struct
  (`TerminalSearchStatus(total: Int, selected: Int?)`, its own file) before
  Decision 1 called for a total enum. The struct's public memberwise init makes
  `total: 0, selected: 5` and `total: -1` constructible, and `total > 0,
  selected == nil` is not merely constructible but *reachable*: `beginSearch`
  retains a non-matching needle as `SearchState(query:, range: nil)`, the status
  read rescans live, so output arriving under a failed search yields matches
  with no selection. 1b converts the type, adds the re-attach to
  `searchNext`/`searchPrevious`, and updates the commit-1 tests' expected values
  (`TerminalSearchStatus(total: 3, selected: 0)` -> `.matched(selected: 0, total: 3)`,
  `(total: 0, selected: nil)` -> `.empty`). Engine-only and self-contained — it
  must land before commit 3, which is the first consumer of the type. Keeping it
  a separate commit rather than amending commit 1 keeps the shipped damage-accounting
  work reviewable on its own.
- Commit 1: the four mutations now route damage through the existing
  `recordDamage(since:)` snapshot diff (with the search range added to
  `DamageActionSnapshot`) rather than each hand-rolling a `viewportState` compare.
  Side effect: a search mutation while scrolled back now records presentation-only
  full damage where it previously recorded none -- a redundant redraw, and the only
  correct answer since viewport-relative match rows are not computable while browsing.
- Commit 1b: the total enum forces an answer the plan left open -- what `searchStatus`
  reports when matches exist but the retained occurrence does not identify one (a failed
  needle that output later satisfied; the read is non-mutating, so it cannot re-attach
  itself). It reports `.matched(selected: 0, total:)`, i.e. the newest match, which is
  exactly the one the next `searchNext`/`searchPrevious` adopts, so the counter never
  disagrees with where navigation is about to land. For that brief window
  `activeSearchMatchRange` is still nil, so the counter reads 1/N with no highlight
  until the user navigates -- strictly better than the `-/1` dead end Decision 1 names.
- Commit 1b: the re-attach triggers on any occurrence the live scan does not contain,
  not only on a nil one -- same rationale, and a stale-but-non-nil range would otherwise
  wedge navigation the same way. Only the nil case is tested: the eviction/damage paths
  (`Terminal.swift` scrollback trim and row-damage invalidation) drop the whole search
  state, so a stale non-nil range is defensive rather than behaviorally reachable today.
