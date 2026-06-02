# Fix: sidebar fights manual scroll by re-revealing the selected tab

## Context

DanTerm's sidebar (an `NSOutlineView` listing tabs) refuses to let the user
scroll the selected tab off-screen: while a terminal is producing output the
sidebar "stutters", snapping the selected row back into view.

Root cause is a single line. `SidebarView.applySidebarOps(...)` ends with an
**unconditional** `scrollRowToVisible` of the selected tab
(`app/SidebarView.swift:264-269`), and that method runs on **every** reconcile
sweep (`reconcile()` -> `reconcileSidebar()` -> `applySidebarOps()`,
`app/Reconcile.swift:93,252,265`). Reconciles are event-driven, fired by
coalescing `surfaceTitle` / `surfaceCwd` / `surfaceProgress` messages
(`Msg.coalescesReconcile`, `lib/DanTermCore/.../Msg.swift:198`) at up to ~13Hz
(`reconcileCoalesceInterval = 0.075`, `app/AppRuntime.swift:75`). `scrollRowToVisible`
is a no-op while the row is visible, so an idle terminal never triggers it -- but
the moment the user scrolls the selected tab off-screen, the next sweep snaps it
back. That repeated snap-back is the stutter.

Two Explore agents confirmed (a) line 268 is the *only* scroll call reachable from
a reconcile -- `selectRowIndexes` in `applyRestoreSelection` does not auto-scroll,
and a cosmetic title update produces only an in-place `.reloadTab` cell edit -- and
(b) the UI-test harness can build an overflowing sidebar and assert scroll position.

**Intended outcome:** the user can scroll the sidebar freely; the focused tab is
revealed only when focus actually changes (tab switch / new tab / restore, including
shifting focus within a multi-selection), which is the one case that genuinely wants a
reveal.

## The fix (production)

`app/SidebarView.swift`, the scroll block at lines 264-269 inside `applySidebarOps`.
Gate the reveal on an **actual focus change** -- compare the model's `selectedTabId`
against the previously-applied focused tab. `applySidebarOps` already holds the prior
model in `currentModel` (the property set at line 243; `currentModel?.selectedTabId` is
the focus reference, same as `outlineViewSelectionDidChange` uses at line 555). Capture
its `selectedTabId` before line 243 overwrites it, then gate on the transition:

```swift
func applySidebarOps(_ ops: [SidebarRowOp], model: AppModel, clearActiveRename: Bool) {
    isReloading = true
    defer { isReloading = false }
    // Prior focused tab, read BEFORE currentModel is overwritten -- the scroll gate
    // below compares against it so we reveal only on a real focus change.
    let priorFocusedTabId = currentModel?.selectedTabId
    currentModel = model
    ...
    // Reveal the selected tab ONLY when focus actually moved to it. applySidebarOps runs
    // on every reconcile sweep, including cosmetic surfaceTitle/cwd/progress updates
    // coalesced at ~13Hz (AppRuntime.reconcileCoalesceInterval = 0.075); scrolling
    // unconditionally fought a user who scrolled the selected tab off-screen, snapping it
    // back each sweep. Gating on the focused-id transition reveals on any genuine tab
    // switch / new-tab / restore -- including shifting focus to an already-selected tab in
    // a multi-selection -- while leaving cosmetic sweeps (focus unchanged) alone.
    if let selectedTabId = model.selectedTabId,
       selectedTabId != priorFocusedTabId,
       let item = tabItemCache[selectedTabId] {
        let row = outlineView.row(forItem: item)
        if row >= 0 { outlineView.scrollRowToVisible(row) }
    }
}
```

The new `let priorFocusedTabId` capture plus the `selectedTabId != priorFocusedTabId`
condition are the entire behavior change. The existing `priorSelectedTabIds` snapshot
(line 251) is untouched -- it serves multi-selection *restore* (`resolveReloadSelection`)
and is a separate concern from the scroll gate.

**Why focused-id transition (not the alternatives):**
- *Prior selection-set membership* (`!priorSelectedTabIds.contains(...)`) would miss a
  focus shift onto an off-screen tab that was already part of a multi-selection -- it
  would fail to reveal it, contradicting the intended outcome. Focused-id transition
  reveals on any real focus change, with no such gap.
- *Gate on "ops non-empty"* is wrong: the selected tab's own title change emits a
  non-empty `.reloadTab` op with unchanged focus, so it would still stutter.
- *Delete the scroll* regresses reveal-on-switch (keyboard-switching to an off-screen
  tab would no longer reveal it).

Reusing `currentModel?.selectedTabId` needs zero new state (no `lastRevealedTabId`
property to keep in sync), and -- unlike selection-set membership -- carries no
multi-selection limitation.

## Regression tests

Add `func sidebarScrollRevealTests()` to `tests-ui/SidebarSelectionCacheTests.swift`
(reusing its in-file `private` helpers directly -- no duplication, no visibility
changes), and call it from `UITestRunner.main()` in
`tests-ui/PaneSplitViewTests.swift`. No `test-ui.sh` edit needed (the file is
already compiled). Update the file-header comment of `SidebarSelectionCacheTests.swift`
to mention scroll-reveal alongside selection restore. Both tests carry the bug-fix
preamble (Intent / Why it exists / Scenario naming the stutter incident).

Reused harness helpers (all in `tests-ui/SidebarSelectionCacheTests.swift`):
`makeSidebarSelectionHarness` (L77, 260x420 window), `applyInitialSidebarModel`
(L91), `applySidebarTransition` (L106), `materializeSidebarRows` (L121, synchronous
layout), `sidebarRow(for:in:)` (L148), `sidebarSelectionModel` (L183, build a
single 30-tab group), `sidebarSelectionTab` (L199). Tab rows are 40pt
(`SidebarView.swift:506`), so 30 tabs (1200pt) overflow the 420pt window. A single
group renders tabs as root rows (no group header), so row index == tab index.

**Test A -- "cosmetic reconcile preserves the user's scroll position" (red-first;
fails today, passes after the fix):**
1. Build a single group of 30 tabs, `selectedTabId = tabIds[0]`; `applyInitialSidebarModel`.
2. `outline.scrollRowToVisible(29)` then `materializeSidebarRows` to push row 0 off-screen.
3. Sanity-assert row 0 is off-screen: `!outline.visibleRect.intersects(outline.rect(ofRow: 0))`.
   Capture `before = outline.visibleRect.origin.y`.
4. *Empty-ops variant:* `applySidebarTransition` with the **same** model (focus
   unchanged) -> assert `abs(outline.visibleRect.origin.y - before) < 0.5` and row 0
   still off-screen.
5. *Cosmetic-reloadTab variant:* `applySidebarTransition` with a model where one
   **off-screen, non-selected** tab has `customTitle` set (forces a `.reloadTab` op),
   focus still `tabIds[0]` -> same scroll-unchanged assertion. This variant is
   what proves the gate is on *focus change*, not op-count.

   (Build the title-changed model inline: `var tabs = tabIds.map(sidebarSelectionTab);
   tabs[15].customTitle = "changed"`, then wrap in `GroupModel`/`AppModel` -- `TabModel.customTitle`
   is a `var`.)

**Test B -- "focus change reveals an off-screen tab, including within a
multi-selection" (guards against over-correcting and pins focused-id gating). In
single-group mode row index == tab index, so the last tab is row 29:**

*B1 -- simple switch.* Build the 30-tab group, `selectedTabId = tabIds[0]`;
`applyInitialSidebarModel` (scrolled to top). Sanity-assert row 29 is off-screen.
`applySidebarTransition` with `selectedTabId = tabIds[29]`; `materializeSidebarRows`.
Assert row 29 is revealed: `outline.rect(ofRow: 29).intersects(outline.visibleRect)`.

*B2 -- focus shift onto an already-selected off-screen tab (the case selection-set
membership would have missed).* From the top-scrolled initial state (`selectedTabId =
tabIds[0]`), extend the live AppKit selection to also include the off-screen last row:
`outline.selectRowIndexes(IndexSet(integer: 29), byExtendingSelection: true)`. This does
not scroll (`selectRowIndexes` never auto-scrolls) -- sanity-assert row 29 is still
off-screen and that `selectedTabIds()` now contains both `tabIds[0]` and `tabIds[29]`.
Then `applySidebarTransition` with `selectedTabId = tabIds[29]` (focus moves onto the
already-selected tab; `currentModel?.selectedTabId` is still `tabIds[0]`, so the gate
sees a real transition); `materializeSidebarRows`. Assert row 29 is revealed. This passes
only with focused-id gating -- selection-set membership gating would leave it off-screen,
which is exactly the bug this test pins.

Both tests assert on scroll position / row visibility (behavioral and
structure-insensitive -- no assertions on internal calls). Test A also implicitly
guards the "`selectRowIndexes` doesn't itself scroll" assumption: if it did, the
unchanged-selection reconcile would still jump and Test A would fail.

## Files to modify

- `app/SidebarView.swift` -- capture `priorFocusedTabId` and gate the scroll at lines
  264-269 (the only production change).
- `tests-ui/SidebarSelectionCacheTests.swift` -- add `sidebarScrollRevealTests()`
  (Test A's two assertions + Test B's two scenarios); refresh the file-header comment to
  cover scroll-reveal alongside selection restore.
- `tests-ui/PaneSplitViewTests.swift` -- add `sidebarScrollRevealTests()` to
  `UITestRunner.main()`, **and** add the missing line-1 `//` file header (the file
  currently opens on `import Cocoa`; `AGENTS.md` requires a top-of-file `//` header on
  every touched `.swift` file). A one-line header describing it as the UI-test runner
  entry point plus shared harness (`uiTest` / `uiExpect` / `UITestFailure`) suffices.

## Verification

- `just test-ui` -- runs the harness (needs a logged-in GUI session, which the user
  has). Confirm both new tests pass and the existing sidebar/split/todo UI tests
  still pass. Confirm Test A genuinely fails *before* the production gate is added
  (TDD red-first), then passes after.
- `just test` -- the local gate (protocol + core + support + lints). This change is
  app-only and shouldn't touch it, but run for the green check. (Note: `just test-ui`
  is intentionally not part of `just test` -- it needs a WindowServer.)
- Manual: open DanTerm with enough tabs to overflow the sidebar, start a
  title-churning loop in any tab
  (`while true; do printf '\e]0;t %s\a' "$RANDOM"; sleep 0.1; done`), select the top
  tab, and scroll the sidebar -- it should stay put instead of stuttering. Then
  keyboard-switch to an off-screen tab and confirm it still scrolls into view.
