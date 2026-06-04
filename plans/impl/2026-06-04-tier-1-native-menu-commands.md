# Plan: Tier 1 native macOS menu commands (Hide / Minimize / Window menu)

## Context

DanTerm hand-builds its menu bar in `app/AppDelegate.swift` `buildMenu()`
(App, Edit, View, Tab, Pane). macOS's standard app/window commands -- Hide,
Hide Others, Show All, Minimize, Zoom, Bring All to Front -- are **not**
automatic; they come from standard menu items DanTerm never added. So today
cmd-H and cmd-M do nothing useful (they fall through to the terminal surface),
and there is no Window menu at all. Tier 1 adds these standard items so DanTerm
behaves like every other Mac app. It is purely additive.

## Scope

- **In:** the App-menu Hide/Show triad, plus a new Window menu (Minimize / Zoom
  / Bring All to Front + AppKit's auto window list) in `app/AppDelegate.swift`
  `buildMenu()` (~20 lines); plus a one-line `isExcludedFromWindowsMenu = true`
  at five auxiliary-window construction sites across three panel files so the
  auto window list shows only the main window (Change 3). No new state, no
  model/core/Command changes.
- **Out:** Enter Full Screen (Tier 2 -- needs a chrome-layout fix), Emoji &
  Symbols / Help / Services / restorable state (Tier 3). No change to cmd-W
  (stays Close Pane) or cmd-N (stays New Group) -- those are intentional
  terminal remaps, not omissions.

All six new actions are AppKit built-ins dispatched through the responder chain
(menu-item `target` stays `nil`), so there are **no new handler methods** in
`AppDelegate` -- only `NSMenuItem`s.

## Change 1 -- App menu: Hide / Hide Others / Show All

Insert after the "Install danterm Command in PATH" item
(`AppDelegate.swift:228`), ahead of the existing pre-Quit separator, yielding
the standard App-menu tail: `Install danterm / --- / Hide / Hide Others / Show
All / --- / Quit`.

| Item | Shortcut | Selector |
|---|---|---|
| *(separator -- new)* | | |
| Hide DanTerm | cmd-H | `#selector(NSApplication.hide(_:))` |
| Hide Others | cmd-opt-H | `#selector(NSApplication.hideOtherApplications(_:))` |
| Show All | -- | `#selector(NSApplication.unhideAllApplications(_:))` |

- "Hide Others" needs `keyEquivalentModifierMask = [.command, .option]` (set on
  the `NSMenuItem`, matching the existing pattern at `:223`/`:226`).
- "Show All" auto-disables (via AppKit) until something is hidden.
- Reuse the existing `appMenu` local already in scope.

## Change 2 -- new Window menu

Insert after the Pane menu is added (`AppDelegate.swift:382`) and before
`NSApp.mainMenu = mainMenu` (`:384`). Per Apple HIG, app-specific menus
(Tab/Pane) precede Window, so appending after Pane is correct; Window stays the
last menu until a Help menu lands (Tier 3).

| Item | Shortcut | Selector |
|---|---|---|
| Minimize | cmd-M | `#selector(NSWindow.performMiniaturize(_:))` |
| Zoom | -- | `#selector(NSWindow.performZoom(_:))` |
| *(separator)* | | |
| Bring All to Front | -- | `#selector(NSApplication.arrangeInFront(_:))` |

Then assign `NSApp.windowsMenu = windowMenu`.

- `NSApp.windowsMenu` makes AppKit auto-append the live window list (below a
  separator it inserts itself) and enables cmd-`` ` `` window cycling.
- **Auxiliary windows must be excluded explicitly (Change 3).**
  `isExcludedFromWindowsMenu` defaults to `false` -- including for `NSPanel` and
  `.utilityWindow` panels (confirmed by a local AppKit probe); AppKit does *not*
  omit panels automatically. `PreferencesPanel` and `QuitConfirmationPanel` are
  `.titled` panels that order front, so without the flag they would show up in
  the list. The main window (created in `AppDelegate`) keeps the default
  `false`, so it -- and only it -- stays listed.
- Minimize/Zoom act on the key window via the responder chain. Double-click-to-
  zoom already exists (`TitlebarDragView.swift:11` calls `window.zoom(nil)`);
  this adds the menu entry and the cmd-M path.

## Change 3 -- keep only the main window in the Window list

`NSApp.windowsMenu` auto-lists every titled, ordered-front top-level window
whose `isExcludedFromWindowsMenu` is `false` (the default -- panels included).
Set the flag at each auxiliary-window construction site so only the main
"DanTerm" window remains listed:

| Site | Window | Edit |
|---|---|---|
| `PreferencesPanel.swift:36` (`init`) | `PreferencesPanel` -- `.titled` `NSPanel` | `isExcludedFromWindowsMenu = true` |
| `QuitConfirmationPanel.swift:8` (`init`) | `QuitConfirmationPanel` -- `.titled` `NSPanel` | `isExcludedFromWindowsMenu = true` |
| `SwitcherPanel.swift:11` (`init`) | `SwitcherPanel` -- `.borderless` `NSPanel` | `isExcludedFromWindowsMenu = true` |
| `PreferencesPanel.swift:327` (`browseGhosttyTheme`) | theme-picker `sheetWindow` -- `.titled` `NSWindow` | `sheetWindow.isExcludedFromWindowsMenu = true` |
| `PreferencesPanel.swift:341` (`browseRemoteTheme`) | theme-picker `sheetWindow` -- `.titled` `NSWindow` | `sheetWindow.isExcludedFromWindowsMenu = true` |

- Set it in each panel's `init` so it covers every present and future
  presentation; set it on each locally-created `sheetWindow` before `beginSheet`
  (the picker itself is an `NSViewController`, so the host `NSWindow` is the
  thing that would be listed).
- `SwitcherPanel` is borderless and non-activating (`canBecomeKey`/`canBecomeMain`
  are `false`), so AppKit almost certainly never lists it; the flag is
  belt-and-suspenders and documents intent.
- The two `sheetWindow` blocks are identical; keep the one-liner inline at both
  sites -- no helper extraction (out of scope).

## Conflict / behavior notes

- **No key collisions.** cmd-H (Hide) is distinct from cmd-shift-H (Focus Left,
  Pane menu) -- different modifier mask. cmd-M and cmd-opt-H are otherwise
  unused in the current menu.
- **Intended PTY interception.** Once these are menu key-equivalents, AppKit
  consumes them in `performKeyEquivalent` before `TerminalView.keyDown`
  (`TerminalView.swift:399`) forwards to the shell -- so they stop reaching the
  PTY. That is the desired native behavior and matches every macOS terminal.
- **No quit-flow entanglement.** None of these route through the
  quit-confirmation path (`requestQuit` / `windowShouldClose`); they act
  directly on `NSApp` / the key window.

## Verification

**Primary -- manual, via `just build-run`:**

1. cmd-H hides DanTerm; clicking the Dock icon (or cmd-tab back) restores it.
   App menu shows Hide DanTerm / Hide Others / Show All in the standard spot.
2. cmd-M minimizes to the Dock; clicking the Dock thumbnail restores it. Window
   menu shows Minimize / Zoom / Bring All to Front.
3. Hide Others (cmd-opt-H) hides other apps; Show All reveals them and re-enables.
4. Window menu lists exactly one entry, "DanTerm", and stays that way while
   auxiliary windows are open: open Preferences (cmd-,), then a theme-picker
   sheet (a Browse button), then trigger the quit confirmation (cmd-Q), and
   confirm none of them appear in the Window list.
5. Regression sanity: cmd-shift-H still focuses the left pane; cmd-W still
   closes the pane; cmd-Q still hits the quit confirmation.

**Compile-time:** all six actions use `#selector(...)` against real AppKit
methods, so a mistyped selector fails the build. `just test` still passes
(no core/protocol/support code changed).

**Automated (deliberately deferred):** the `tests-ui/` harness builds views in
isolation and never constructs `AppDelegate`'s `private buildMenu()`. A
behavioral test (synthesize a cmd-M event, call `mainMenu.performKeyEquivalent`,
assert `window.isMiniaturized`) would require extracting `buildMenu()` into a
side-effect-free factory returning `NSMenu`. Per the test rubric, such a test
mostly exercises AppKit built-ins, so it is out of Tier 1 scope; manual
verification covers the wiring. (If we later want it, the extraction is the
clean enabler and can ride along with Tier 2.)

## Out of scope (later tiers, for reference)

- **Tier 2:** Enter Full Screen (cmd-ctrl-F via `NSWindow.toggleFullScreen(_:)`)
  + a `WindowChromeView` fullscreen-layout fix (`WindowChromeView.swift:201`
  reads the traffic-light frame, which is hidden in fullscreen) +
  `applicationShouldHandleReopen`.
- **Tier 3:** Emoji & Symbols (cmd-ctrl-space), Help menu, Services submenu,
  `applicationSupportsSecureRestorableState`.
