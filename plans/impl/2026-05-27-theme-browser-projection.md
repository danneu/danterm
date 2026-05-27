# Reconcile theme browser focused-pane state via a projection pass

> **Citations are by symbol name, not line number.** This repo is being actively
> refactored in parallel -- HEAD advanced several commits during planning and line
> numbers shifted by dozens of lines mid-session across app *and* test files (e.g.
> `ModelOperationsTests` moved ~40 lines). Every reference below names its symbol;
> grep for that symbol rather than trusting any line number.

## Context

The theme browser (`app/ThemeBrowserView.swift`) shows and sets the focused
pane's theme. Themes are per-pane (`.setPaneTheme(paneId, themeName)` writes
`model.pane.theme`), so two panes in one tab can carry different themes. The
panel's `currentThemeName` is the single source for three pieces of UI: the row
checkmark (in `viewFor`), the selected/scrolled row (`selectCurrentThemeRow`), and
the Reset-button visibility.

`currentThemeName` is written only inside `reloadFromRuntime()`, which
is called from exactly two places:

- `AppRuntime.toggleThemeBrowser()` open path -- a direct runtime method
  (menu/shortcut), not a `send()`/`reconcile()` cycle.
- `AppRuntime.applyMountTimeFocus()` -- runs inside `reconcile()` only when a
  container is built/rebuilt/newly-shown (i.e. tab activation).

A **same-tab focus change** (`.paneBecameFirstResponder` in `Update.swift`)
sets `focusedPaneId` and returns `[.scheduleCheckpoint]` with no container-shape
change. `reconcileContainers` emits no ops and returns `nil`, so
`applyMountTimeFocus(nil)` early-returns and the browser never reloads. Result:
after focusing a differently-themed sibling pane in the same tab, the checkmark,
selected row, and Reset button all describe the **previously** focused pane.

The same staleness exists on a second, latent path: the IPC handler
(`.ipcRequest` -> `handleIpcRequest` -> `Methods.themeSet` in `Update.swift`,
the `danterm theme set` CLI) dispatches `.setPaneTheme` with zero browser-view
involvement -- so with the browser open, an external `theme set` on the focused
pane silently desyncs the panel too.

Every other panel (sidebar, window chrome, MRU switcher, preferences) has already
been migrated off imperative view-reads-model reloads onto the reconcile-pass
pattern: a pure Equatable projection in `ModelOperations.swift`, a single-optional
cache field on `ReconcilerCaches`, and a `reconcileX()` pass run on every `send()`.
The theme browser is the lone holdout. This plan migrates it, which dissolves both
staleness paths at once and removes the last imperative `reloadFromRuntime` call
site.

## Scope guardrail (from the migration plan)

`plans/impl/2026-05-26-tree-owns-panes-reconciler.md:336` deliberately keeps the
browser's **filter** (`searchField` / `filteredNames`) and **focus**
(`captureFocusTarget` / `restoreFocus`) view-local -- mirroring them into the model
would be "dead weight no reconcile pass reads." Only the model-derived **content**
(the focused pane's theme) becomes a projection. Filter and focus stay exactly
where they are.

The projection reads `pane.theme` (the user override), NOT
`effectiveTheme(for:)` (`ModelOperations.swift`, `remoteThemeOverride ?? theme`).
The browser shows/sets the user override; a remote session's transient theme must
not hijack the checkmark. The `setPaneTheme while remote...` test in
`UpdateRemoteTests.swift` already guards that these are independent channels.

## Approach

Template to mirror throughout: the single-optional direct-compare cache shape used
by panel passes in `Reconcile.swift`, plus a pure projection like
`desiredPreferencesPanel` (`ModelOperations.swift`). The reconcile pass becomes the
**single writer** of `currentThemeName`; the browser's action handlers become pure
`Msg` dispatchers. This is safe and lag-free because `AppRuntime` is `@MainActor`
and `send()` runs `reconcile()` synchronously for any non-coalescing message
(`coalescesReconcile` in `Msg.swift` returns true only for
`.surfaceTitle/.surfaceCwd/.surfaceProgress`). Both relevant entry messages fall in
the `default: false` branch: the browser's own `send(.setPaneTheme)` and the IPC
path's `.ipcRequest` wrapper. `.setPaneTheme` itself returns only
`.scheduleCheckpoint`; applying the chosen theme to Ghostty surfaces is already
reconciler-owned by `reconcilePaneConfig()`, so this plan only adds the separate
browser-UI projection. After either entry message returns, reconcile -- and thus
the repaint -- has already run.

### 0. Make `themeBrowserView` cross-file readable (blocking)

In `AppRuntime.swift` -- change `private var themeBrowserView` to internal, matching
the existing internal `preferencesPanel`/`switcherPanel` fields and their comment:

```swift
// internal (not private): the cross-file reconcileThemeBrowser extension reads it.
var themeBrowserView: ThemeBrowserView?
```

The `reconcileThemeBrowser()` pass lives in the `Reconcile.swift` extension and
cannot read a `private` member.

### 1. Projection + cache (`ModelOperations.swift`, `Reconcile.swift`)

Add next to `desiredPreferencesPanel`:

```swift
struct ThemeBrowserProjection: Equatable {
    var currentThemeName: String?
}

/// The focused pane's user-set theme for the selected tab. Reads `.theme`
/// (the override), never effectiveTheme, so a remote session's transient theme
/// does not move the checkmark. nil currentThemeName == no override (Reset state)
/// or no selected tab.
func desiredThemeBrowser(in model: AppModel) -> ThemeBrowserProjection {
    ThemeBrowserProjection(
        currentThemeName: selectedTab(in: model).flatMap { model.pane($0.focusedPaneId)?.theme }
    )
}
```

The projection is **non-optional**. The "browser closed" bit is view-local, so it
is carried by the reconcile gate (below), not folded into the projection return --
otherwise "closed" and "open, no tab" collapse into one nil and the cache compare
cannot tell them apart.

Add the cache field to `ReconcilerCaches` (`Reconcile.swift`, alongside the other
single-optional caches) with a doc comment: `nil == no browser open; non-nil == last
content applied`. It resets for free via `tearDownCurrentSession`'s
`caches = ReconcilerCaches()`.

```swift
var themeBrowser: ThemeBrowserProjection? = nil
```

### 2. Reconcile pass (`Reconcile.swift`)

Mirror the single-optional direct-compare cache shape used by panel passes (direct
`!=` compare against the single-optional cache, not `applyDiff`):

```swift
func reconcileThemeBrowser() {
    let new = themeBrowserView == nil ? nil : desiredThemeBrowser(in: model)
    guard caches.themeBrowser != new else { return }
    if let proj = new { themeBrowserView?.apply(proj) }
    caches.themeBrowser = new
}
```

Slot it in `reconcile()` right after `reconcilePreferencesPanel()`.

### 3. `ThemeBrowserView` content apply + pure dispatchers

**Add `apply(_:)`** -- content only, never touches `filteredNames`/`searchField`/
first responder:

```swift
/// Single entry point the reconciler uses to push focused-pane theme content.
/// Filter text and focus stay view-local (searchChanged / restoreFocus own those).
func apply(_ proj: ThemeBrowserProjection) {
    let old = currentThemeName
    currentThemeName = proj.currentThemeName          // set BEFORE selecting (loop safety, below)
    resetButton.isHidden = currentThemeName == nil
    // Partial reload of only the rows whose checkmark changes, so selection/scroll
    // are preserved (same nicety the old tableViewSelectionDidChange had).
    var rows = IndexSet()
    if let o = old, let i = filteredNames.firstIndex(of: o) { rows.insert(i) }
    if let n = currentThemeName, let i = filteredNames.firstIndex(of: n) { rows.insert(i) }
    if !rows.isEmpty { tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0)) }
    selectCurrentThemeRow()
}
```

Guard the scroll inside `selectCurrentThemeRow` (or in `apply`): skip
`scrollRowToVisible` when `tableView.selectedRow` already equals the target index,
so arrow-key navigation through the list does not re-scroll on every keystroke.

**Make `tableViewSelectionDidChange` a pure dispatcher** -- keep BOTH
guards, then dispatch and return:

```swift
func tableViewSelectionDidChange(_ notification: Notification) {
    let row = tableView.selectedRow
    guard row >= 0, row < filteredNames.count else { return }   // deselect (row == -1) must NOT become a Reset
    let name = filteredNames[row]
    guard name != currentThemeName else { return }              // breaks the programmatic-reselect feedback loop
    guard let runtime = runtime, let tab = selectedTab(in: runtime.model) else { return }
    runtime.send(.setPaneTheme(paneId: tab.focusedPaneId, themeName: name))
}
```

Delete the local `currentThemeName`/`resetButton`/partial-reload mutation that
followed the `send` -- the reconcile pass now owns all of it.

Feedback-loop safety: the reconcile-driven `apply()` sets `currentThemeName` and
then `selectCurrentThemeRow()` calls `selectRowIndexes`, which re-fires this
delegate. Because `currentThemeName` was set first, the `name != currentThemeName`
guard returns. On the deselect path (`deselectAll`, `row == -1`) the `row >= 0`
guard returns. No re-entrancy.

**Make `resetTheme` a pure dispatcher** -- dispatch `themeName: nil`
(optionally guard `currentThemeName != nil`) and return; delete the local mutation.

**Delete `reloadFromRuntime()`** entirely.

### 4. Wire-up (`AppRuntime.swift`)

**`toggleThemeBrowser` open path**: after `themeBrowserView = browser`,
do a one-time full table populate then seed via the pass. (A full `reloadData()` is
required on open -- `apply()` only partial-reloads the checkmark rows, so the other
rows need the initial load, exactly as the old `reloadFromRuntime` did.)
Expose a tiny `func reloadTable() { tableView.reloadData() }` on the browser:

```swift
themeBrowserView = browser
browser.reloadTable()
reconcileThemeBrowser()   // cache is nil -> applies focused pane's theme + selection
```

Calling `reconcileThemeBrowser()` directly here (outside a `send()`/`reconcile()`
cycle) is intentional and consistent with the scope guardrail's imperative
open/close: the pass has no cross-pass dependencies, so a single direct call is the
right shape -- inventing an open/close `Msg` purely to route the seed would add
surface area for no benefit.

**`toggleThemeBrowser` close path**: after `themeBrowserView = nil`, call
`reconcileThemeBrowser()` (gate returns nil, cache resets to nil so the next open
re-seeds). Keep the existing focus-restore-to-surface block unchanged.

**`applyMountTimeFocus`**: delete the `browser.reloadFromRuntime()` content reload.
KEEP `captureFocusTarget()` and `restoreFocus(target)` -- focus stays view-local and
owned here; content now
flows through `reconcileThemeBrowser`, which runs later in the same synchronous
`reconcile()`. `apply()` never calls `makeFirstResponder`, so it cannot fight the
restored focus.

## Files to modify

- `app/ModelOperations.swift` -- add `ThemeBrowserProjection` + `desiredThemeBrowser`.
- `app/Reconcile.swift` -- add `themeBrowser` cache field, `reconcileThemeBrowser()`,
  and the call in `reconcile()`.
- `app/ThemeBrowserView.swift` -- add `apply(_:)` + `reloadTable()`; convert
  `tableViewSelectionDidChange` and `resetTheme` to dispatchers; delete
  `reloadFromRuntime()`.
- `app/AppRuntime.swift` -- un-private `themeBrowserView`; rewire `toggleThemeBrowser`
  open/close; trim `applyMountTimeFocus`.
- `tests/ModelOperationsTests.swift` -- projection test (below).

## Test plan (TDD -- write first, watch it fail)

Pure projection test in `tests/ModelOperationsTests.swift`, inside
`modelOperationsTests()` next to the `desiredFocusBorders` tests, which
is the template. Tests drive the pure reducer `update(&model, ...)`, not
`runtime.send()`. `.paneBecameFirstResponder` requires the target to differ from
current focus (the `paneId != oldFocusedId` guard in `.paneBecameFirstResponder`)
or it no-ops.

```swift
test("desiredThemeBrowser: tracks the focused pane's theme across same-tab focus") {
    var model = makeModel(); createTab(&model)
    let paneA = selectedTab(in: model)!.focusedPaneId
    update(&model, .splitPane(paneId: paneA, direction: .horizontal))
    let focused = selectedTab(in: model)!.focusedPaneId
    let other = allPaneIds(selectedTab(in: model)!.rootNode).first { $0 != focused }!
    update(&model, .setPaneTheme(paneId: focused, themeName: "Dracula"))
    update(&model, .setPaneTheme(paneId: other, themeName: "Nord"))

    try expectEqual(desiredThemeBrowser(in: model).currentThemeName, "Dracula",
        "projection returns the focused pane's theme")

    update(&model, .paneBecameFirstResponder(paneId: other))
    try expectEqual(desiredThemeBrowser(in: model).currentThemeName, "Nord",
        "projection updates on same-tab focus change -- the bug this fixes")
}

test("desiredThemeBrowser: nil theme when no selected tab / no override") {
    var model = makeModel()                      // no tabs yet
    try expectEqual(desiredThemeBrowser(in: model).currentThemeName, nil)
}

// Discriminating guard: with a remote override present, effectiveTheme(for:)
// would return "Purplepeter", but the browser must report the user theme. The two
// tests above would still pass if the projection wrongly used effectiveTheme,
// because effectiveTheme falls back to pane.theme when no override is set -- this
// test is the one that actually fails on that mistake.
test("desiredThemeBrowser: reports the user theme, not the remote override") {
    var model = makeModel(); createTab(&model)
    let paneId = selectedTab(in: model)!.focusedPaneId
    update(&model, .setPaneTheme(paneId: paneId, themeName: "Dracula"))
    model.updatePane(paneId) { $0.remoteThemeOverride = "Purplepeter" }
    try expectEqual(desiredThemeBrowser(in: model).currentThemeName, "Dracula",
        "projection reads pane.theme, never effectiveTheme")
}
```

The first test fails today (no projection exists) and pins the focus-tracking bug;
the third fails if the projection is ever switched to `effectiveTheme`. Run with
`just test`.

## Verification

1. `just test` -- the new projection tests pass; existing `UpdateThemeTests` and
   `UpdateRemoteTests` still pass (behavior of `.theme` vs `remoteThemeOverride`
   unchanged).
2. `just build-run`, then manual QA:
   - Split a tab into two panes. Set pane A's theme to Dracula, pane B's to Nord via
     the browser. Open the browser (focus on A): Dracula is checked + selected.
     Click pane B's terminal: the browser now checks/selects Nord and the Reset
     button stays visible. Click back to A: returns to Dracula. (This is the bug.)
   - Reset on a pane with an override: checkmark clears, Reset hides; focus a sibling
     with an override and back -- state tracks correctly.
   - Type a filter, switch focus between panes, and confirm the filter text and the
     field's first-responder survive (filter/focus stay view-local).
   - Arrow-key through the theme list: live preview still applies per row with no lag
     or scroll jank.
   - With the browser open on the focused pane, run `danterm theme set <name>` from a
     shell in that pane (IPC path): the browser's checkmark/selection update without
     any browser interaction.
   - Tab-activation reload still works: switch to another tab whose focused pane has a
     different theme and confirm the browser reflects it on activation.
