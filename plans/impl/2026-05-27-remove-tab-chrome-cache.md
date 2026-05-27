# Plan: Remove stored derived tab chrome from TabModel

## Context

`TabModel` (app/Model.swift:111-123) stores two fields, `title` and `subtitle`,
that are pure caches of the focused pane's abbreviated title and cwd. Because
they're stored, every code path that changes a tab's focused pane must call
`syncFocusedPaneChrome` to re-derive them; miss that call and the sidebar row,
window title, and MRU switcher go stale.

This bug class has already shipped and been patched reactively
(`c92b8c3 fix(sidebar): sync tab chrome when pane close auto-focuses sibling`),
and **three more unpatched stale paths exist today**:

- `movePane` swap / move-within-tab (Update.swift:284) -- on the *visible* tab.
- `movePaneToTab` source tab (Update.swift:325-326) -- focus shifts to `next` but chrome isn't re-derived.
- `movePaneToNewTab` source tab (Update.swift:400-402) -- same.

The two move-source cases never self-heal: the surviving pane already reported
its title/cwd long ago, so nothing re-emits it. (`splitPane` at Update.swift:183
is also unsynced but self-heals when the new shell reports a title.)

The serialization layer already treats this chrome as derived -- `TabSnapshot`
(Model.swift:301-308) stores only `customTitle`, and the decode comment says
chrome is "never stored in the snapshot" (Model.swift:463-464). Only the
in-memory model still caches it.

**Outcome:** make `title`/`subtitle` derive on read from the focused leaf pane
(which always lives in the tab's own `rootNode`). This deletes the cache, the
entire `syncFocusedPaneChrome` obligation, and all three latent stale bugs at
once -- they become structurally impossible.

## Approach

Convert `TabModel.title`/`subtitle` from stored fields to computed properties
backed by the focused leaf pane. `title` stays a read-only computed property
(the bare pane-derived title), `displayTitle` keeps layering `customTitle` on
top, and `subtitle` derives the cwd. Every reader -- `tab.title`,
`tab.subtitle`, `tab.displayTitle` -- keeps its name, so reads need no changes;
only the writers are deleted (writing a get-only property is a compile error,
which is how we find them all). At import, seed the live `PaneModel.cwd`
launch-aware so the derived subtitle matches today's restore behavior, which
lets `deriveTabChromeFromSnapshot` be deleted too.

Reuse existing module-internal helpers: `paneInNode(_:id:)`
(ModelOperations.swift:126), `abbreviateHome(_:)` (ModelOperations.swift:505),
`deriveTabChrome(from:)` (ModelOperations.swift:512), and `resolveLaunch(_:)`
(Model.swift:517).

### Why this is safe (verified)

- Restore surface creation reads cwd via `resolveLaunch` from the
  `paneSnapshots` map (AppRuntime.swift:1118-1139), **not** from `PaneModel.cwd`,
  so re-seeding `PaneModel.cwd` does not change any surface's working directory.
- `toSnapshot` writes a pane's `cwd` and `launch.cwd` from the *same* value
  (ModelOperations.swift ~1652-1673), so `resolveLaunch(ps).cwd ==
  expandTilde(ps.cwd)` for every real persisted snapshot -- the seeding change is
  a no-op there. It differs only for hand-authored init files where
  `cwd != launch.cwd`. Note `PaneModel.cwd` has live readers beyond the derived
  subtitle: new-tab/split cwd inheritance (`currentCwd`, ModelOperations.swift:491,
  and the IPC `effectiveLaunch` fallback in Update.swift ~1555), the copy-cwd
  context menu (PaneWrapperView.swift:344/380), and the CLI context JSON (`pane.cwd`
  in the IPC info payload). For all of them, `launch.cwd` winning on a hand-authored
  file is the intended, correct outcome: it matches the directory the surface was
  actually launched in (surface creation already resolves cwd via `resolveLaunch`),
  so seeding makes these readers consistent with the surface instead of diverging
  from it. The change is therefore not subtitle-local, but every non-subtitle effect
  is either a no-op (real snapshots) or a correctness improvement (hand-authored).
- Reconcile diffs `SidebarTabProjection` / `WindowChromeProjection`, which copy
  the derived strings into their own stored `Equatable` fields -- never a whole
  `TabModel`, so reconcile diffing is unaffected. Whole-group equality *is*
  exercised in tests (`testClearCustomTitlesAllStaleIsNoop`,
  CustomTitleTests.swift:520, asserts `model.groups == snapshot`, which
  transitively compares `TabModel` via synthesized `Equatable`), but that stays
  behaviorally valid: chrome derives only from the still-compared stored fields
  (`rootNode`, `focusedPaneId`, `customTitle`). Dropping the cached
  `title`/`subtitle` from `Equatable` can only collapse stale-but-structurally-
  identical tabs to equal (more correct), never make equal tabs unequal -- so
  the no-op assertion still holds.

## Changes

### 1. TabModel derives chrome on read -- app/Model.swift:111-123

Delete stored `var title: String = "Terminal"` (113) and `var subtitle: String?`
(114), then re-add `title` and `subtitle` as read-only computed properties and
switch `displayTitle` to derive-on-read -- all funneling through one derivation
point (`deriveTabChrome` on the focused leaf). Keeping `title` get-only
preserves every existing `tab.title` reader; the former writes to it become
compile errors that the step-2 deletions remove:

```swift
struct TabModel: Equatable {
    let id: TabId
    var customTitle: String?
    var focusedPaneId: PaneId
    var rootNode: SplitNodeModel
    var isZoomed: Bool = false
    var color: TabColor? = nil
    var todos: [TodoItem] = []

    // The focused leaf always lives in this tab's own tree, so chrome derives
    // from the model with no stored cache to keep in sync.
    var focusedPane: PaneModel? { paneInNode(rootNode, id: focusedPaneId) }
    private var derivedChrome: (title: String, subtitle: String?) {
        focusedPane.map { deriveTabChrome(from: $0) } ?? ("Terminal", nil)
    }
    var title: String { derivedChrome.title }          // bare pane-derived title (read-only)
    var displayTitle: String { customTitle ?? title }  // custom override layered on top
    var subtitle: String? { derivedChrome.subtitle }
}
```

### 2. Delete every cache writer -- app/Update.swift

> `app/Update.swift` line numbers below are approximate -- the file shifts under
> active perf work (e.g. `syncFocusedPaneChrome` moved from ~2448 to ~2400 during
> planning). Anchor on the `case`/function names, which are stable; the deletions
> are also self-verifying, since writing the now-get-only `title`/`subtitle`
> becomes a compile error.

- `syncFocusedPaneChrome` definition (~2400) and its three call sites. In
  `closePane`, delete **only** the standalone
  `if let next = nextFocus { syncFocusedPaneChrome(next, in: &model) }` block
  (~235-237); **keep** the separate `tab.focusedPaneId = next` assignment inside
  the `updateSelectedTab` closure above it -- that is focus-follows-close, not
  chrome. The other two sites (`paneBecameFirstResponder` ~496, focus helper
  ~2358) are single-line deletions.
- movePaneToTab: drop `let chrome = deriveTabChrome(...)` and the
  `tab.title`/`tab.subtitle` lines. Keep rootNode/focusedPaneId/isZoomed.
- movePaneToNewTab Path B: drop `let chrome = ...` and
  `newTab.title`/`newTab.subtitle`.
- surfaceTitle (~705) and surfaceCwd (~717): drop the `let abbrev = ...` +
  `updateTab { t.title/subtitle = abbrev }`. **Keep** `model.updatePane { $0.title/$0.cwd = ... }`
  and the `.scheduleCheckpoint` returns. With the tab write gone both guard
  branches return `[.scheduleCheckpoint]`, so collapse the now-dead
  focused-pane guard to a single unconditional `return [.scheduleCheckpoint]`.

### 3. Import path -- app/Model.swift

- In `validateAndBuild` (468-476): drop `title:`/`subtitle:` from the `TabModel(...)`
  init. Remove the now-unused `let focusedPs = ...` (465) and
  `let chrome = deriveTabChromeFromSnapshot(focusedPs)` (466).
- Pane cwd seeding (567): change `let expandedCwd = ps.cwd.map { expandTilde($0) }`
  to `let expandedCwd = resolveLaunch(ps).cwd` so the live pane cwd is
  launch-aware and the derived subtitle matches current restore output.
- Delete `deriveTabChromeFromSnapshot` (ModelOperations.swift:518-525). Keep
  `deriveTabChrome` and `abbreviateHome`.

## Tests (TDD)

Per project TDD practice, write the three new behavioral tests first and confirm
they fail against current `master` for the right reason (the derived/expected
title does not appear), then implement and confirm they pass.

### New -- structure-insensitive, catch the three latent stale paths

Add to tests/UpdatePaneTests.swift (or a movePane-focused file). Each asserts the
affected tab's `displayTitle` follows the newly focused pane after the op, with
no explicit sync call:

- `testMovePaneSwapUpdatesVisibleTabChrome` (Update.swift:284): tab with pane A
  ("alpha") split to B ("beta", focused); `movePane(source: A, target: B, intent: .swap)`
  lands focus on A; assert `displayTitle == "alpha"`.
- `testMovePaneToTabUpdatesSourceTabChrome` (Update.swift:325-326): source tab S
  has A (focused, "alpha") + B ("beta"); move A to another tab T; S now focuses B;
  assert `tabById(S).displayTitle == "beta"`. (S is a background tab, also proving
  derivation works for non-selected tabs -- the old sync only fixed the selected tab.)
  Set A's chrome before the move so the pre-fix stale value is "alpha", not the default.
- `testMovePaneToNewTabUpdatesSourceTabChrome` (Update.swift:400-402): same shape
  via `.movePaneToNewTab`; assert the source tab's `displayTitle == "beta"`.

### Rework

Because `title`/`subtitle` stay readable (now computed), every test that *reads*
them still compiles and passes. Only fixture *writes* and the one reference to
the deleted helper change:

- tests/CustomTitleTests.swift:12, 19 -- `tabs[0].title = "vim"` is now a write to
  a get-only property. Set the focused pane's title instead:
  `model.updatePane(...) { $0.title = "vim" }`.
- tests/TreeOwnsPanesTests.swift:367-369 -- only the `deriveTabChromeFromSnapshot`
  reference breaks (deleted in step 3). Replace `expected.title`/`expected.subtitle`
  with the literal assertions already present just below (`tab.title == "Editor"`,
  `tab.subtitle == "~/focused-launch"`, sibling cwd does not leak at 373-374). The
  launch.cwd precedence is preserved by the step-3 seeding change.
- tests/ModelOperationsTests.swift:1828, 1885, 1925, 1930 -- these write
  `tab.title`/`tab.subtitle` directly as fixtures. Reseed via the focused pane's
  `title`/`cwd` (use an absolute cwd under `$HOME`, e.g. `NSHomeDirectory()+"/src"`,
  so the computed subtitle abbreviates to `~/src`). The `windowTitle` suppression
  case at 1925-1930 (subtitle == displayTitle is omitted) is the one awkward spot:
  set the focused pane's cwd and `customTitle` to the same abbreviated string so
  the derived subtitle equals displayTitle. This is the most likely spot to need
  a small iteration.

### Keep unchanged (reads survive; now free derive-path coverage)

- tests/UpdateGhosttyTests.swift:178/193/205/236/252 -- read `tab.title`/`tab.subtitle`
  after surfaceTitle/surfaceCwd, including the unfocused-pane ("tab title should not
  change") and background-tab cases. Keep passing; now exercise the derive path.
- tests/UpdatePaneTests.swift:222/223 (close-refocus) and :990/991 (movePaneToNewTab
  derives title/subtitle from the pane) -- read the computed fields; keep passing.
- tests/CustomTitleTests.swift:537 `testClearCustomTitlesRevertsSelectedTabDisplayTitle`
  -- asserts `displayTitle == tab.title` after clearing the custom title; both compute
  off the same focused pane, so it passes unchanged.
- tests/CustomTitleTests.swift:520 `testClearCustomTitlesAllStaleIsNoop` -- the
  `model.groups == snapshot` no-op assertion still holds (see the equality note in
  "Why this is safe").
- tests/CustomTitleTests.swift:297 `testDeriveTabChromeMatchesRuntimeBehavior` --
  uses `deriveTabChrome` (kept) and reads the computed fields; already behavioral.
- tests/CustomTitleTests.swift:269 legacy-decode test -- old files with tab-level
  title/subtitle still decode and derive correctly; valuable guard.
- tests/UpdatePaneTests.swift:206 `testClosePaneSyncsTabChromeFromSurvivingPane` --
  the canonical c92b8c3 regression test; still passes via derivation.

## Verification

1. `just test` -- all pure unit tests pass, including the three new behavioral tests.
2. Confirm the three new tests fail on current `master` before the change (right reason).
3. `just build` -- app compiles (no stray references to the deleted symbols).
4. Manual smoke (optional): `just build-run`, then in the running app set distinct
   titles in two panes, drag-swap them, and drag a pane to another tab; verify the
   sidebar row, window title, and cmd-shift-o switcher all track the focused pane
   immediately, including on the unselected source tab.

## Implementation notes

- `tests/SidebarItemStoreTests.swift` also had a helper seeding `TabModel.title`
  through the old memberwise initializer; it now seeds the helper leaf's
  `PaneModel.title` instead.
