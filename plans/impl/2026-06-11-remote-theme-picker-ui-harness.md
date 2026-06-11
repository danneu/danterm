# Promote RemoteThemePickerSheet into the tests-ui harness

## Context

Fourth view promotion into the GhosttyKit-free UI harness, and the thin
increment the ThemeBrowserView promotion (cb82c5b, plan at
plans/impl/2026-06-11-theme-browser-ui-harness.md) explicitly set up: its
"RemoteThemePickerSheet later" section already audited this target and
concluded a later sheet promotion needs only its own compile-list line, its
own names seam (reusing the inject-names/ambient-colors split decided there),
and its own fixture modeled on `makeThemeBrowserFixture`.

Target: `app/RemoteThemePickerSheet.swift` (195 lines, Cocoa-only) -- the
preferences-panel sheet with a searchable NSTableView, double-click commit,
and an `onSelect` callback. None of its behavior is covered by any test
today. Presented from `app/PreferencesPanel.swift:321,336`
(`browseGhosttyTheme` / `browseRemoteTheme`), which set `currentThemeName`,
install `onSelect`, and present via `beginSheet`.

Dependency closure (verified): `Cocoa` + `ThemeCatalog` +
`ThemeBrowserCellView`/`ColorSwatchView` (app/ThemeSwatchViews.swift:34,86).
All already in the `test-ui.sh` compile list since cb82c5b; no GhosttyKit
anywhere in the closure. The sheet never touches `AppRuntime` -- it reports
via the plain `onSelect` closure -- so unlike every prior promotion, **no
shim changes** are needed.

Two production realities shape the plan, both already solved by precedent:

1. **Empty catalog in the harness.** `allNames`/`filteredNames` initialize
   from `ThemeCatalog.shared.names` in property initializers
   (RemoteThemePickerSheet.swift:18-19); the test binary has no app bundle,
   so every test would run against zero rows. Fix: the same names seam as
   `ThemeBrowserView.init(themeNames:)` (app/ThemeBrowserView.swift:52,
   162-165), adapted to NSViewController. Per the inject-vs-ambient rule:
   names are ASSERTED by tests (inject); swatch colors at render time
   (`ThemeCatalog.shared.colors[name]`, RemoteThemePickerSheet.swift:182)
   are only SHOWN (leave ambient -- empty catalog renders clear swatches).
2. **Sheet lifecycle needs no shim and no real sheet.** `dismiss()`
   (RemoteThemePickerSheet.swift:100-104) guards on
   `view.window?.sheetParent` and no-ops when the view sits in a plain
   fixture window, so `commitSelection()` still resolves the row and fires
   `onSelect`, and `cancel()` fires nothing. The windowless no-op IS the
   driving strategy; do not present a real sheet (runloop-dependent, flaky).
   One harness caveat: the fixture window is never ordered front, so AppKit
   will not fire `viewDidAppear` -- the fixture invokes it directly to run
   `selectCurrentThemeRow()` preselection, mirroring production appear.

No menus, observers, timers, or stored cross-lifetime targets are added, so
the lifetime ADR is untouched.

Out of scope (follow-up note only): the sheet hand-copies ThemeBrowserView's
cell construction/config (~40 lines, RemoteThemePickerSheet.swift:142-188).
Once both surfaces are pinned by tests, extracting a shared configure helper
into `ThemeSwatchViews.swift` becomes safe -- a separate change; nothing in
Phase 3 should force it.

## Files touched

- `test-ui.sh` -- two compile-list lines
- `tests-ui/PaneSplitViewTests.swift` -- one runner-registration line
- `tests-ui/RemoteThemePickerSheetTests.swift` -- NEW: suite, fixture,
  1 smoke + ~11 behavioral tests
- `app/RemoteThemePickerSheet.swift` -- names seam, three visibility
  relaxations, stored cancel button. The only production file that changes.

No shim edits, no core/lib edits, no ADR edits. `just test` scope is
untouched by construction.

## Phase 1 -- Harness enablement

Gate: `just test-ui` green (existing suites + a smoke test that uses only
existing API, so it compiles before any seam exists).

### 1a. Compile-list additions (`test-ui.sh`)

One app line after `app/ThemeBrowserView.swift` (line ~57):

```
"$SCRIPT_DIR/app/RemoteThemePickerSheet.swift" \
```

One test line next to the other test entries (before
`PaneSplitViewTests.swift`):

```
"$SCRIPT_DIR/tests-ui/RemoteThemePickerSheetTests.swift" \
```

Closure audit (verified): everything else the sheet needs is already in the
list (`ThemeCatalog.swift`, `ThemeColorFileLoader.swift`,
`ThemeColorParser.swift`, `ThemeSwatchViews.swift`).

### 1b. Runner registration + smoke suite

Add `remoteThemePickerSheetTests()` to `UITestRunner.main`
(tests-ui/PaneSplitViewTests.swift:10-23), after `themeBrowserViewTests()`.

New `tests-ui/RemoteThemePickerSheetTests.swift` with a `//` file header
(per AGENTS.md) naming the windowless-dismiss driving strategy, and one
smoke test using only existing API:

```swift
uiTest("constructs against an empty catalog with zero rows and no callback") {
    let sheet = RemoteThemePickerSheet()      // production init, bundle-less catalog
    var fired = false
    sheet.onSelect = { _ in fired = true }
    _ = sheet.view                            // triggers loadView
    try uiExpect(sheet.view.subviews.count > 0, "loadView should build the hierarchy")
    try uiExpect(!fired, "construction must not fire onSelect")
}
```

(Smoke deliberately avoids `tableView` -- still private in Phase 1.)

## Phase 2 -- Failing behavioral tests first

The harness is all-or-nothing (one swiftc invocation; a compile error runs
nothing), so for seam-demanding tests "fails for the expected reason" means
observing the specific expected compile diagnostic (`RemoteThemePickerSheet`
has no `init(themeNames:)`; `tableView`/`searchField`/`selectButton`/
`cancelButton` inaccessible), then satisfying it in the same working session
via Phase 3 -- never leaving the harness compile-broken at a phase boundary.

### Fixture factory (private to the new test file)

Model on `makeThemeBrowserFixture`
(tests-ui/ThemeBrowserViewTests.swift:281-316) and its `setSearch` /
`cellText` / `rowIndex` / settle helpers (:318-348), including the private
`trimmingCheckmark` extension:

```swift
private final class SelectRecorder { var names: [String] = [] }

private struct RemotePickerFixture {
    let sheet: RemoteThemePickerSheet
    let window: NSWindow
    let recorder: SelectRecorder
    let names: [String]
}

private func makeRemotePickerFixture(
    names: [String] = ["Dracula", "Gruvbox Dark", "Gruvbox Light", "Nord", "Solarized Dark"],
    currentTheme: String? = nil
) -> RemotePickerFixture {
    let sheet = RemoteThemePickerSheet(themeNames: names)   // seam from Phase 3
    sheet.currentThemeName = currentTheme
    let recorder = SelectRecorder()
    sheet.onSelect = { recorder.names.append($0) }

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = sheet.view          // triggers loadView; plain window => sheetParent nil
    sheet.viewDidAppear()                    // AppKit won't fire it (window never ordered front);
                                             // runs selectCurrentThemeRow() as production appear does
    window.layoutIfNeeded()
    return RemotePickerFixture(sheet: sheet, window: window, recorder: recorder, names: names)
}
```

Every test: `defer { fx.window.close() }`.

### Tests (each asserts the recorder, not just UI state)

Filtering (drive through the real delegate path:
`searchField.stringValue = q` then
`controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))`):

1. search filter narrows rows case-insensitively ("gru" -> 2 rows, cell
   texts "Gruvbox Dark"/"Gruvbox Light").
2. clearing the filter restores all rows.
3. no-match filter yields zero rows, disables Select, and a commit attempt
   fires nothing (the empty-results edge case: `commitSelection` guard at
   :90 rejects `selectedRow == -1`). Assert `!selectButton.isEnabled`, then
   drive the commit through the table double-action wiring --
   `_ = fx.sheet.tableView.target?.perform(fx.sheet.tableView.doubleAction!)`
   -- and assert the recorder stays empty. (Do NOT drive a disabled button's
   `performClick`: a disabled NSButton does not send its action, so that
   path never enters `commitSelection` and the guard could regress while
   the test stays green.)

Commit paths (the "exactly once" contract -- assert
`recorder.names == [expected]`, count and value in one check):

4. double-click commit fires onSelect exactly once with the right name:
   select a row via `selectRowIndexes`, assert the wiring
   (`tableView.doubleAction != nil`, `tableView.target === fx.sheet`), then
   drive through the real wiring:
   `_ = fx.sheet.tableView.target?.perform(fx.sheet.tableView.doubleAction!)`.
   (ObjC dispatch -- works without relaxing `commitSelection`'s `private`.)
5. explicit commit via `selectButton.performClick(nil)` fires onSelect
   exactly once with the right name.
6. commit after filtering targets the filtered index (filter "gru", select
   row 1, commit -> "Gruvbox Light").
7. commit with no selection fires nothing (fresh fixture, no
   `currentThemeName`; Select starts disabled per :52). Same driving rule
   as test 3: assert `!selectButton.isEnabled`, then enter
   `commitSelection` via the double-action wiring and assert the recorder
   stays empty.

Cancel/dismiss:

8. cancel fires nothing: `cancelButton.performClick(nil)` -> recorder empty.
   Windowless `dismiss()` no-op covers the dismiss half by construction.

Preselection (`currentThemeName`, run by the fixture's `viewDidAppear()`):

9. currentThemeName preselects its row, enables Select, and the cell shows
   "\u{2713} <name>" (reuse the `cellText` + `trimmingCheckmark` idiom).
10. filtering keeps the current theme's row selected; filtering it away
    deselects and disables Select (`selectCurrentThemeRow()` re-runs after
    every `searchChanged`, :114).
11. selecting a row enables Select; `tableViewSelectionDidChange` path via
    `selectRowIndexes` (:137-140).

## Phase 3 -- Only what the tests force (`app/RemoteThemePickerSheet.swift`)

1. **Names seam.** Replace the property-initializer catalog reads (:18-19)
   with stored properties set in a designated init, mirroring
   ThemeBrowserView's seam shape adapted to NSViewController:

   ```swift
   /// Test entry point: inject theme names so the harness can assert row
   /// behavior without depending on the app bundle catalog.
   init(themeNames: [String] = ThemeCatalog.shared.names) {
       allNames = themeNames
       filteredNames = themeNames
       super.init(nibName: nil, bundle: nil)
   }

   required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
   ```

   The default argument keeps both production call sites
   (`RemoteThemePickerSheet()`, app/PreferencesPanel.swift:321,336)
   compiling unchanged. Swatch colors stay ambient (:182).
2. **Control visibility.** Drop `private` on `searchField`, `tableView`,
   `selectButton` (:13-16) -- the harness compiles everything as one module,
   so `internal` suffices, same as ThemeBrowserView's relaxations.
3. **Stored cancel button.** Promote the `loadView`-local `cancelButton`
   (:46) to a stored `let cancelButton = NSButton(title: "Cancel",
   target: nil, action: nil)` wired in `loadView`, mirroring how
   `selectButton` is already declared (:16) -- so test 8 drives the real
   control instead of calling `cancel()` reflectively.

No method visibility changes: filtering drives `controlTextDidChange`
(public delegate method), double-click drives the target/doubleAction wiring,
commit/cancel drive buttons.

## Verification

1. After Phase 1: `just test-ui` (needs a GUI session; fine from an agent
   shell in a logged-in session) -- existing suites + smoke green.
2. After Phase 3: `just test-ui` -- full suite green, `N/N passed`, exit 0.
3. `just test` -- must stay green; nothing in its scope changes. Run once.
4. Negative check (established precedent): temporarily flip the expected
   theme name in test 4, confirm a red assertion naming the mismatch,
   restore.
5. `just build` once at the end -- proves the production target still
   compiles against the new designated init (PreferencesPanel call sites
   rely on the default argument; the build is the proof).

## Follow Up

- Extract the duplicated ThemeBrowserCellView construction/configuration shared by `app/ThemeBrowserView.swift` and `app/RemoteThemePickerSheet.swift` into `app/ThemeSwatchViews.swift` now that both surfaces have UI-harness coverage.
