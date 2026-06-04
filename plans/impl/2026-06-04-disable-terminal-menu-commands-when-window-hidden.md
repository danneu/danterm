# Plan: Disable terminal menu commands when the main window isn't on-screen

## Context

Terminal-mutating menu commands -- Close Pane (cmd-W), Close Tab (cmd-shift-W),
splits, focus moves, New Tab, etc. -- currently fire even when DanTerm's only
window is **minimized**. Incident: the window was minimized, the user believed
the browser was focused, and pressed cmd-W repeatedly -- silently closing panes
in the hidden terminal. Root cause is a macOS subtlety: minimizing a window does
**not** deactivate the app. DanTerm stayed frontmost, its menu bar kept
receiving key-equivalents, and the browser was merely showing through the empty
space.

Native apps avoid this because window-scoped commands ride the responder chain
to the key window (`performClose:`, `performMiniaturize:`) and auto-disable when
there is no key window -- minimize any app's last window and File > Close grays
out, cmd-W beeps. DanTerm doesn't get this for free because its terminal
commands target always-enabled custom `@objc` selectors on `AppDelegate`, which
has no menu validation. (The Window-menu Minimize/Zoom items just added behave
correctly already -- they target the key window; only the custom terminal
commands leak. Edit-menu cut/copy/paste/undo target the first responder, so they
already gray out when minimized.)

Outcome: terminal commands gray out (and their shortcuts beep) whenever the main
window isn't on-screen, so they can't run invisibly. App/config commands
(Preferences, config files, import/export, install CLI, Quit) stay available.

## Approach

Validate menu items in the AppKit layer -- correct because minimization is
ambient view state, not model state, so it must not be threaded into the pure
core. Use **default-deny**: a small, stable allowlist of window-independent
commands stays enabled; everything else routed to `AppDelegate` requires a live
window. Default-deny is the key property -- any terminal command added later is
gated automatically and cannot reintroduce this incident by omission.

### New file: `app/MenuCommandPolicy.swift`

A standalone, Foundation-only policy unit (no AppKit views, no GhosttyKit) so it
compiles into the `tests-ui/` harness, which cannot compile `AppDelegate` (that
would drag in AppRuntime + GhosttyKit -- confirmed: `test-ui.sh` hand-picks leaf
files and omits it).

- `@objc protocol WindowIndependentMenuActions` declaring the **8** app-level
  action signatures, used only to mint their `Selector`s type-safely (no
  stringly-typed selectors). The 8, confirmed exhaustive against `buildMenu()`:
  `showPreferences`, `quitApp`, `importState`, `exportState`,
  `openDanTermConfig`, `openGhosttyConfig`, `reloadConfig`, `installDantermInPath`.
- `enum MenuCommandPolicy`:
  - `static let windowIndependentActions: Set<Selector>` built from
    `#selector(WindowIndependentMenuActions.showPreferences(_:))` etc.
  - `static func isEnabled(action: Selector?, windowIsLive: Bool) -> Bool` --
    `nil` action -> `true` (separators / submenu parents); allowlisted -> `true`;
    otherwise -> `windowIsLive`.

### `app/AppDelegate.swift`

- Add `extension AppDelegate: NSMenuItemValidation` with:
  ```swift
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
      MenuCommandPolicy.isEnabled(action: item.action,
                                  windowIsLive: window != nil && window.isVisible)
  }
  ```
- Declare `WindowIndependentMenuActions` conformance on the class (the 8 methods
  already exist and are `@objc`), so renaming any of them is a compile error
  until the policy is updated -- the allowlist can't silently drift.
- Relies on NSMenu's default `autoenablesItems == true` (DanTerm never disables
  it). Only items whose resolved target is `AppDelegate` reach `validateMenuItem`;
  items targeting the key window / NSApp / first responder validate through their
  own responders and are unaffected. Gating therefore spans every terminal-scoped
  `AppDelegate` command regardless of menu -- including Edit > Find
  (`findInTerminal`) and View > Theme Browser (`toggleThemeBrowser`).

## Decisions

- **Gate on `window.isVisible` (false while miniaturized), not `isKeyWindow`.**
  isVisible precisely fixes the reachable bad state (frontmost + minimized) with
  no risk of over-disabling. isKeyWindow would also disable terminal commands
  whenever a DanTerm panel/popover is focused over a *visible* window -- higher
  risk, negligible benefit (the result would be visible anyway).
- **New Tab / New Group are gated too** (terminal-scoped -> disabled when
  minimized). Uniform and safe; the fancier "deminiaturize-then-create"
  alternative adds special-casing and is deferred.
- **Scope = menu-driven commands.** The MRU switcher's local `NSEvent` monitor
  (cmd-shift-o/i) bypasses menu validation but is non-destructive (focus/
  selection only); the destructive paths (cmd-W / Close) are pure menu
  key-equivalents and are fully covered. Chrome-button paths can't fire while
  minimized -- the buttons aren't clickable on a hidden window.

## Files

- **New** `app/MenuCommandPolicy.swift` -- protocol + policy enum.
- `app/AppDelegate.swift` -- `NSMenuItemValidation` + `WindowIndependentMenuActions`
  conformance, ~6-line `validateMenuItem`.
- **New** `tests-ui/MenuCommandPolicyTests.swift` -- `menuCommandPolicyTests()` suite.
- `tests-ui/PaneSplitViewTests.swift` -- one line in `UITestRunner.main()` to call it.
- `test-ui.sh` -- add `app/MenuCommandPolicy.swift` and the new test file to the
  `swiftc` list.

## Verification

**Automated -- `menuCommandPolicyTests()` via `just test-ui`** (the policy
compiles standalone in the harness). Behavioral, structure-insensitive cases
using `uiTest`/`uiExpect`:
- terminal-scoped `Selector("closePane:")` -> disabled when `windowIsLive: false`,
  enabled when `true`.
- app-level `#selector(WindowIndependentMenuActions.showPreferences(_:))` ->
  enabled regardless of `windowIsLive`.
- an unlisted `Selector("brandNewCommand:")` -> disabled when not live (pins
  default-deny -- the property that prevents recurrence).
- `nil` action -> enabled.

**Manual -- `just build-run`:**
1. Minimize (cmd-M); DanTerm stays frontmost. In the Tab/Pane menus, Close Tab /
   Close Pane / splits / focus / New Tab are grayed; cmd-W and cmd-shift-W beep
   instead of closing. (The incident, fixed.)
2. While minimized, App menu still works: Preferences (cmd-,) opens; Quit works.
3. Restore the window: all terminal commands re-enable and behave normally.

**Compile-time:** the allowlist uses `#selector` against the protocol, and
`AppDelegate`'s conformance makes any rename of the 8 app-level methods a build
error -- the policy can't drift out of sync.

## Out of scope

- New-command "deminiaturize-then-create" behavior (kept gated for now).
- The MRU event-monitor path (non-destructive).
- Panel-focused gating via `isKeyWindow`.
