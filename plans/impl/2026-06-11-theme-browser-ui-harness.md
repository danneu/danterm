# Promote ThemeBrowserView into the tests-ui harness

## Context

Third view promotion into the GhosttyKit-free UI harness, following
PaneWrapperView (commit 8da7613, the menu-builder-extraction precedent) and
TabTodoPopoverView (commit 265ee65, the fixture-factory + phase-shape
precedent; plan at plans/impl/2026-06-11-tab-todo-popover-ui-harness.md).

Target: `app/ThemeBrowserView.swift` (313 lines, Cocoa-only) -- NSTableView
theme list with live search filtering, selection-driven theme apply, and a
context menu built via `NSMenuDelegate.menuNeedsUpdate` carrying theme names
in `representedObject`. None of its behavior is covered by any test today.

Unlike TabTodoPopoverView, this is NOT a zero-production-change promotion.
Four things force small production edits, all confined to
`app/ThemeBrowserView.swift` (plus one safe-map line in the lifetime ADR):

1. **Empty catalog in the harness.** `init` reads
   `ThemeCatalog.shared.names` (ThemeBrowserView.swift:132), and
   `ThemeCatalog` resolves `Bundle.main.url(forResource: "ghostty/themes")`
   (ThemeCatalog.swift:20) -- nil in the test binary, so every test would run
   against zero rows. Fix: inject theme names via init, defaulting to the
   catalog. This follows the AGENTS.md inject-vs-ambient rule: names are
   ASSERTED by tests (inject); swatch colors at render time
   (ThemeBrowserView.swift:281) are only SHOWN (leave ambient -- empty
   catalog renders clear swatches, which is fine).
2. **`clickedRow` is unsettable.** `menuNeedsUpdate` reads
   `tableView.clickedRow`, which is -1 outside a real right-click. Fix:
   extract a builder method tests call directly, mirroring
   `PaneWrapperView.makePaneMenu`.
3. **Menu lifetime invariant violation.** The current menu item sets weak
   `target = self` with only a String in `representedObject` -- the exact
   shape the lifetime ADR rule 7
   (docs/design/2026-06-09-appkit-lifetime-safety.md:57) prohibits for menus
   owned by an ephemeral view: the browser can be toggled away mid-track
   (toggleThemeBrowser tears the view down; an async-dispatched IPC or menu
   command can land during menu tracking), deallocating the weak target and
   turning "Copy Name" into a silent no-op. Promoting the view as-is would
   cement the unsafe shape in tests. Fix: anchor the owner via a strong
   payload in `representedObject` (the `PaneWrapperView.wrapperItem`
   precedent, app/PaneWrapperView.swift:429-437), carrying the theme name +
   the view. One twist PaneWrapperView doesn't have: its menu is built fresh
   per open, so the anchor dies with the menu; ThemeBrowserView's menu is
   PERSISTENT (`tableView.menu`, set once in init), so the anchor creates a
   retain cycle (view -> tableView -> menu -> item -> payload -> view) that
   must be broken after tracking ends. Apple documents that `menuDidClose`
   must not mutate the menu, so the clear is deferred one main-queue turn.
   The retention test that pins this contract also forces a one-line
   pasteboard seam (`var pasteboard: NSPasteboard = .general`) so invoking
   the copy action in tests never touches the developer's clipboard.
4. **Private controls.** `tableView`/`searchField`/`resetButton`/`closeButton`
   are `private let`; the harness compiles everything as one module, so
   `internal` suffices for tests to drive real controls.

Per TDD, the production edits land only when a failing test forces them
(Phases 2a/3a and 2b/3b below). The harness is all-or-nothing (one swiftc
invocation; a compile error runs nothing), so "fails for the expected reason"
for seam-demanding tests means observing the specific expected compile
diagnostic, then satisfying it in the same working session -- never leaving
the harness compile-broken at a phase boundary.

## Files touched

- `test-ui.sh` -- six compile-list lines
- `tests-ui/SidebarViewTestShim.swift` -- shim `toggleThemeBrowser()` + header comment
- `tests-ui/PaneSplitViewTests.swift` -- one runner-registration line
- `tests-ui/ThemeBrowserViewTests.swift` -- NEW: suite, fixture, 1 smoke + 19 behavioral tests
- `app/ThemeBrowserView.swift` -- init seam, four visibility relaxations, menu-builder extraction, menu lifetime payload + `menuDidClose` cycle break, pasteboard seam. The only production file that changes.
- `docs/design/2026-06-09-appkit-lifetime-safety.md` -- add the persistent-menu anchored shape to the context-menus safe-map bullet.

No core/lib edits. `ThemeColorParser.swift` joins the harness compile list
but is never modified, so core tests and `scripts/core-purity-lint.sh` are
untouched by construction.

## Phase 1 -- Harness enablement

Gate: `just test-ui` green (existing suites + a smoke test that uses only
existing API, so it compiles before any seam exists).

### 1a. Shim extension (`tests-ui/SidebarViewTestShim.swift`)

Add to the shim `AppRuntime`, recorder-style like `focusedPaneSurfaces`:

```swift
var themeBrowserToggles = 0

/// ThemeBrowserView close-button hook. Production toggles the panel
/// in/out of the content area; the harness only counts invocations.
func toggleThemeBrowser() { themeBrowserToggles += 1 }
```

A counter, not a marker array: the call carries no payload, and the close
test asserts "exactly one toggle, zero messages". Update the file-header
comment to mention ThemeBrowserView.

### 1b. Compile-list additions (`test-ui.sh`)

One core line after `DanTermConfig.swift` (line 35):

```
"$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/ThemeColorParser.swift" \
```

Four app lines after `app/SidebarView.swift` (line 50):

```
"$SCRIPT_DIR/app/ThemeColorFileLoader.swift" \
"$SCRIPT_DIR/app/ThemeCatalog.swift" \
"$SCRIPT_DIR/app/ThemeSwatchViews.swift" \
"$SCRIPT_DIR/app/ThemeBrowserView.swift" \
```

One test line next to the other test files (before `PaneSplitViewTests.swift`):

```
"$SCRIPT_DIR/tests-ui/ThemeBrowserViewTests.swift" \
```

Closure audit (verified): everything else ThemeBrowserView needs is already
compiled -- `selectedTab` (ModelOperations.swift), `.setPaneTheme`
(Msg.swift), `ThemeBrowserProjection` + `desiredThemeBrowser`
(Projections.swift), `model.pane(_:)`, shim `AppRuntime` (1a). The new chain
ThemeCatalog -> ThemeColorFileLoader -> ThemeColorParser is
Cocoa/Foundation-only; in the harness the catalog is empty, which is harmless
and pinned by the smoke test.

### 1c. Runner registration + smoke suite

New `tests-ui/ThemeBrowserViewTests.swift` with `func themeBrowserViewTests()`;
register it after `tabTodoPopoverViewTests()` in `UITestRunner.main`
(tests-ui/PaneSplitViewTests.swift:21). Smoke test, existing-API-only:

```swift
uiTest("constructs against an empty catalog and applies a projection without dispatch") {
    let runtime = AppRuntime()
    let view = ThemeBrowserView()          // harness catalog is empty: zero rows
    view.runtime = runtime
    view.reloadTable()
    view.apply(ThemeBrowserProjection(currentThemeName: nil))
    try uiExpect(runtime.sentMessages.isEmpty, "apply must not dispatch")
}
```

## Phase 2/3 -- Behavioral tests + forced production changes, interleaved

### Fixture factory (Phase 2a, in ThemeBrowserViewTests.swift)

```swift
private func makeThemeBrowserFixture(
    names: [String] = ["Dracula", "Gruvbox Dark", "Gruvbox Light", "Nord", "Solarized Dark"],
    currentTheme: String? = nil
) -> ThemeBrowserFixture   // (view, runtime, window, tabId, paneId, names)
```

Mirrors `makeTabTodoFixture`: one `PaneModel` (`pane.theme = currentTheme`),
`.leaf` root, one `TabModel` (focusedPaneId = the pane), one `GroupModel`,
`selectedTabId` set -- so `selectedTab(in:)` and `tab.focusedPaneId` resolve.
Then shim `AppRuntime(model:)`, `ThemeBrowserView(themeNames: names)` (the
seam), `view.runtime = runtime`, host in an NSWindow replicating the
production attach (pin top/bottom/trailing per AppRuntime.swift:1080-1086;
width comes from the view's own 250 constraint), `view.reloadTable()`,
`view.apply(desiredThemeBrowser(in: runtime.model))`, `window.layoutIfNeeded()`.
Tests `defer { fx.window.close() }`.

Helpers: `setSearch(_:in:)` drives the real delegate path -- no new API
needed because `controlTextDidChange` is internal and ignores its payload:

```swift
fx.view.searchField.stringValue = "gru"
fx.view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fx.view.searchField))
```

plus `cellText(row:in:)` via `tableView.view(atColumn:0, row:, makeIfNecessary:true)
as? ThemeBrowserCellView`, and `rowIndex(of:)`.

Selection mechanics (verified against prior art): `selectRowIndexes` posts
the selection-change notification synchronously, no runloop pump needed --
same pattern as tests-ui/SidebarSelectionCacheTests.swift:26. Test 4 asserts
`sentMessages.count == 1`, so if that assumption ever broke the suite fails
loudly rather than passing vacuously.

**Pasteboard policy:** no test touches `NSPasteboard.general`, ever (a
save/restore would not be enough: `clearContents()` wipes ALL items and
types, so restoring only the string would erase a non-string clipboard
value). Menu-shape tests assert the item payload and never invoke
`copyThemeName`. The retention test (18) does invoke it -- "actions still
fire after teardown" is the lifetime contract under test and the pasteboard
write is its only observable effect -- but through a one-line production
seam: `var pasteboard: NSPasteboard = .general` on ThemeBrowserView, which
test 18 redirects to `NSPasteboard.withUniqueName()` (released via
`releaseGlobally()` in a `defer`). Inject-vs-ambient applied to AppKit: the
write is ASSERTED by the test (inject the pasteboard); production keeps the
ambient `.general` default. The selector stays private either way -- tests
reach it only via `item.target?.perform(item.action, with: item)`.

### Phase 2a tests (need the init seam + control visibility)

Expected compile failures before 3a (observe and record both):
`extra argument 'themeNames' in call` at the fixture, and
`'tableView' is inaccessible due to 'private' protection level` (likewise
the other three controls) at the helpers.

1. **search filter narrows rows case-insensitively** -- `setSearch("gru")`;
   `numberOfRows == 2`, cell texts are the two Gruvbox names.
2. **clearing the filter restores all rows** -- `setSearch("gru")` then
   `setSearch("")`; `numberOfRows == names.count`.
3. **no-match filter yields zero rows** -- `setSearch("zzz")`; 0 rows.
4. **selection sends setPaneTheme for the focused pane** -- select the
   "Nord" row; exactly one message, `.setPaneTheme(paneId: fx.paneId,
   themeName: "Nord")`.
5. **selection after filtering targets the filtered index** --
   `setSearch("gru")`, select row 1; message carries "Gruvbox Light".
   Pins `filteredNames` indexing, the real bug surface.
6. **re-selecting the current theme sends nothing** -- fixture
   `currentTheme: "Nord"`; select the Nord row again; `sentMessages.isEmpty`.
7. **apply moves selection and checkmark without dispatching** -- apply
   `ThemeBrowserProjection(currentThemeName: "Nord")`; selectedRow is Nord's
   index, cell text `"\u{2713} Nord"`, `resetButton.isHidden == false`,
   `sentMessages.isEmpty`. Pins apply's currentThemeName-before-select
   ordering (ThemeBrowserView.swift:151 before :161), which suppresses the
   synchronous delegate echo -- the easiest thing for a refactor to break
   silently.
8. **apply nil clears checkmark, reset visibility, and selection** -- apply
   "Nord" then nil; `resetButton.isHidden`, `selectedRow == -1`, no
   checkmark prefix, no messages.
9. **filtering keeps the current theme's row selected without dispatch** --
   `currentTheme: "Gruvbox Dark"`, `setSearch("gru")`; `selectedRow == 0`,
   no messages.
10. **filtering away the current theme deselects** -- `currentTheme: "Nord"`,
    `setSearch("gru")`; `selectedRow == -1`, no messages.
11. **reset button sends setPaneTheme nil** -- `currentTheme: "Nord"`;
    `resetButton.performClick(nil)`; one message
    `.setPaneTheme(paneId: fx.paneId, themeName: nil)`.
12. **close button calls toggleThemeBrowser** -- `closeButton.performClick(nil)`;
    `themeBrowserToggles == 1`, `sentMessages.isEmpty`.

### Phase 3a production change (`app/ThemeBrowserView.swift` only)

Forced by tests 1-12 (all need injected rows; visibility per test list):

```swift
/// Designated init with the theme-name seam: tests ASSERT on names (inject);
/// swatch colors are only SHOWN (ambient ThemeCatalog.shared at render time).
init(frame frameRect: NSRect = .zero, themeNames: [String]) { ... }

/// Production entry point: names from the bundled catalog.
override convenience init(frame frameRect: NSRect) {
    self.init(frame: frameRect, themeNames: ThemeCatalog.shared.names)
}
```

The convenience override (rather than a single init with a catalog default)
preserves the ObjC `initWithFrame:` override and keeps `ThemeBrowserView()`
at AppRuntime.swift:1078 provably unchanged. In the designated init body,
`allNames = themeNames` replaces the line-132 catalog read.

Drop `private` on exactly four controls: `tableView`, `searchField`,
`resetButton`, `closeButton`. `backgroundView`/`headerLabel`/`scrollView`
stay private (no test touches them); all `@objc private` action methods and
`selectCurrentThemeRow` stay private -- tests reach them through real entry
points (`performClick`, the delegate method).

Run `just test-ui` -> all green.

### Phase 2b tests (need the menu builder + lifetime payload)

Expected compile failures before 3b:
`value of type 'ThemeBrowserView' has no member 'buildThemeContextMenu'`,
`cannot find 'ThemeBrowserView.MenuPayload' in scope` (tests 13/16/18 name
the payload type), and `value of type 'ThemeBrowserView' has no member
'pasteboard'` (test 18 redirects the seam).

13. **context-menu builder yields Copy Name carrying the row's theme and a
    strong anchor** -- fresh `NSMenu()`;
    `buildThemeContextMenu(into: menu, forRow: 1)`; one item, title
    "Copy Name", `target === view`, `action != nil`, and
    `representedObject as? ThemeBrowserView.MenuPayload` has
    `themeName == names[1]` and `anchor === view`. Do not send the action.
14. **builder clears stale items and yields empty for row -1** -- pre-add a
    dummy item; `forRow: -1`; `menu.items.isEmpty`. Pins the unconditional
    `removeAllItems` + miss-click path.
15. **builder yields empty for out-of-bounds row** -- `forRow: names.count`;
    empty.
16. **builder reads the active filter** -- `setSearch("gru")`; `forRow: 0`;
    payload `themeName == "Gruvbox Dark"`.
17. **menuNeedsUpdate with no click builds an empty menu** -- call
    `view.menuNeedsUpdate(menu)` on a pre-populated menu (clickedRow is -1
    absent a real right-click); assert empty. Pins the delegate->builder
    delegation itself.
18. **menu keeps the browser alive and Copy Name still fires after
    teardown** -- mirrors
    tests-ui/PaneWrapperViewTests.swift:147. Construct the fixture view
    inside an `autoreleasepool` (AppKit init paths autorelease view
    references; without draining, the view survives anyway and a pre-fix run
    passes vacuously), hold only `weak var observer: ThemeBrowserView?` and
    an externally-owned `NSMenu` populated via
    `buildThemeContextMenu(into:forRow:)`, release the fixture's strong
    references, drain the pool. Inside the pool, while the view is still
    strongly held, redirect the seam to a scratch pasteboard:
    `view.pasteboard = NSPasteboard.withUniqueName()`, with
    `releaseGlobally()` in a `defer`. After the pool drains, assert
    `observer != nil` (the payload anchors the view), then
    `item.target?.perform(item.action, with: item)` and assert the scratch
    pasteboard now holds the expected theme name (the action dispatched and
    did its job after the owner was released, without ever touching
    `.general`).
19. **menuDidClose breaks the anchor cycle so the browser can deallocate** --
    populate the persistent menu via the builder (payload now anchors the
    view), call `view.menuDidClose(menu)`, then drain the deferred clear with
    one short runloop spin (`RunLoop.main.run(until:)` -- the harness
    convention avoids pumping, but the cycle-break is deliberately deferred
    one main-queue turn because AppKit forbids mutating the menu inside
    `menuDidClose`, so this test must drain that turn; say so in the test
    preamble). Assert `menu.items.isEmpty`, then release the view's strong
    references and assert a `weak` observer goes nil -- no leak from
    view -> tableView -> menu -> payload -> view.

### Phase 3b production change

Forced by tests 13-19. Extract the builder, mirroring `makePaneMenu`
(PaneWrapperView.swift:425) but keeping the `into:` form because
`menuNeedsUpdate` must mutate the table-owned menu in place -- and bring the
item into compliance with lifetime ADR rule 7
(docs/design/2026-06-09-appkit-lifetime-safety.md:57):

```swift
/// Pasteboard seam for Copy Name. Inject-vs-ambient applied to AppKit: the
/// retention test ASSERTS the write (inject a scratch pasteboard so the
/// harness never touches the developer's clipboard); production keeps the
/// ambient general pasteboard.
var pasteboard: NSPasteboard = .general

/// Strong context-menu payload: the theme name the action consumes plus an
/// anchor to this view. NSMenuItem.target is weak and the browser can be
/// toggled away mid-track (lifetime ADR rule 7); the anchor keeps the
/// target alive for the menu's lifetime, like PaneWrapperView.wrapperItem.
final class MenuPayload {
    let themeName: String
    let anchor: ThemeBrowserView
    init(themeName: String, anchor: ThemeBrowserView) { ... }
}

/// Rebuild the right-click menu for `row` (NSTableView.clickedRow semantics:
/// -1 when the click missed every row). Split from menuNeedsUpdate so the
/// harness can drive row values a programmatic test cannot click.
func buildThemeContextMenu(into menu: NSMenu, forRow row: Int) {
    menu.removeAllItems()
    guard row >= 0, row < filteredNames.count else { return }
    let item = NSMenuItem(title: "Copy Name", action: #selector(copyThemeName(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = MenuPayload(themeName: filteredNames[row], anchor: self)
    menu.addItem(item)
}

/// NSMenuDelegate: build the context menu for the right-clicked row.
func menuNeedsUpdate(_ menu: NSMenu) {
    buildThemeContextMenu(into: menu, forRow: tableView.clickedRow)
}

/// NSMenuDelegate: break the anchor cycle once tracking ends. Unlike
/// PaneWrapperView's per-open menus, this menu is persistent (tableView.menu),
/// so anchored items would otherwise retain self forever
/// (view -> tableView -> menu -> payload -> view). Deferred one main-queue
/// turn: AppKit forbids mutating the menu inside menuDidClose, and the
/// clicked item's action dispatches after this returns.
func menuDidClose(_ menu: NSMenu) {
    DispatchQueue.main.async { menu.removeAllItems() }
}
```

`copyThemeName` changes its guard to read
`(sender.representedObject as? MenuPayload)?.themeName` -- the payload
carries the stable subject (the theme name, not a row index), satisfying the
ADR's resolve-at-fire-time clause trivially since the name is itself the
copied datum; a missing payload fails closed (guard returns). Its two
`NSPasteboard.general` references become `pasteboard` (the seam above,
forced by test 18).

Behavior at the menu surface is otherwise preserved exactly
(removeAllItems on every open; empty menu for -1/out-of-bounds), per
current lines 298-306.

Also update the lifetime ADR's safe-map bullet on context menus
(docs/design/2026-06-09-appkit-lifetime-safety.md:92-103) to record the
third shape this introduces: a PERSISTENT table menu with anchored items
plus a deferred `menuDidClose` clear that breaks the cycle.

Run `just test-ui` -> all green.

Out of scope: `captureFocusTarget`/`restoreFocus` (first-responder behavior
is environment-sensitive; same rationale the TabTodo plan used to skip
focus tests).

## RemoteThemePickerSheet later (note only -- not planned here)

`app/RemoteThemePickerSheet.swift` shares exactly the surface this phase
moves into the harness: `ThemeBrowserCellView` + `ColorSwatchView`
(ThemeSwatchViews.swift, whose header already names both consumers) and
`ThemeCatalog.shared` names/colors (RemoteThemePickerSheet.swift:18-19,
144-151, 182). A later sheet promotion needs only its own compile-list line,
its own names seam (reuse the inject-names/ambient-colors split decided
here), and its own fixture modeled on `makeThemeBrowserFixture`.

## Verification

1. After Phase 1: `just test-ui` (needs a GUI session; fine from an agent
   shell in a logged-in session) -- existing suites + smoke green.
2. After 3a and again after 3b: `just test-ui` -- full suite green,
   `N/N passed`, exit 0.
3. `just test` -- must stay green; nothing in its scope changes. Run once.
4. Negative check (TabTodo-plan precedent): temporarily flip the expected
   theme name in test 4, confirm a red assertion naming the mismatched
   message, restore.
5. `just build` once at the end -- proves the production target still
   compiles with the init/builder change (the convenience override keeps
   `ThemeBrowserView()` valid; the build is the proof).

## Implementation notes

- The pasteboard seam landed as a small `ThemeNamePasteboard` protocol instead
  of a concrete `NSPasteboard` property. Production still uses
  `NSPasteboard.general`, but the lifetime test injects a recorder because
  writing to a real named pasteboard after synthetic owner teardown was unstable
  in the UI harness and not part of the behavior under test.
- `menuDidClose` uses `RunLoop.main.perform` instead of `DispatchQueue.main.async`
  so the UI harness can deterministically drain the deferred clear. It also nils
  each item target and payload before `removeAllItems()` because AppKit can keep
  removed item objects alive briefly; the payload-release test pins that the
  anchor cycle is broken even if those item objects linger.
