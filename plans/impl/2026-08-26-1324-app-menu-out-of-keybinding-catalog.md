# Take non-rebindable App-menu commands out of the keybinding catalog

## Context

`commandCatalog` (`lib/DanTermCore/Sources/DanTermCore/CommandCatalog.swift`) does
three jobs at once: it is the dispatch identity for a menu command, the source of
its menu key equivalent, and the list of things the Settings keybinding browser
lets the user rebind. Because the three are fused, anything that needs a menu
item automatically becomes a rebindable action.

Four App-menu commands do not belong in that list. `Settings...` must keep
`cmd+,` -- it is the macOS convention, not a preference. `Install danterm Command
in PATH`, `Import State...`, and `Export State...` are one-shot maintenance
actions with no chord at all. All four are noise in the keybinding picker.

The fix is to unfuse the three jobs: the catalog holds only commands the user may
rebind, and everything else is an ordinary AppKit menu item. Then the problem
cannot recur -- a command that is not a binding is not listed, searched,
overridden, or reset, because it is not a binding at all. `cmd+,` moves to
`keybindingReservations`, the existing home for fixed macOS chords no
configurable command may claim.

`app.open-config` (`cmd+option+,`) and `app.reload-config` (`cmd+shift+,`) stay
configurable and stay in the catalog, so the Application category does not empty
out.

## Why plain menu items, not a "hidden from the picker" flag

The alternative -- an `isUserConfigurable: Bool` on `CommandDescriptor` -- is a
smaller diff and keeps the `cmd+,` conflict entry for free. It is rejected
because it leaves these commands as bindings that are merely hidden: every
catalog consumer (`Projections.keybindingSettingsGroups`, `catalogBindings`,
`moveCandidateOwnership`, `confirmResetAll`, `knownKeybindingActionIDs`) then has
to remember the flag, and forgetting it in one place puts the row back.

The plain-item path needs no new machinery. `MenuCommandPolicy` already has a
selector branch (`isEnabled(action:windowIsLive:)`) whose
`WindowIndependentMenuActions` allowlist already names all four selectors. It is
currently dead for these commands, because catalog items use the shared
`performConfiguredCommand(_:)` selector and a `String` `representedObject`.
Moving them off the catalog makes that existing branch live again, which is what
it was written for.

## Contract

**Catalog membership.** `commandCatalog` and `ConfigurableCommand` lose
`app.import-state`, `app.export-state`, `app.settings`, and `app.install-cli`.
They keep `app.open-config` and `app.reload-config`. The existing
catalog-equals-enum assertion holds after the change, so the two stay 1:1.

**Fixed App-menu items.** Import State, Export State, Settings, and Install
danterm Command in PATH remain in the App menu, in their current order and with
their current titles. Each one:

- dispatches through its own existing `AppDelegate` selector
  (`importState(_:)`, `exportState(_:)`, `showPreferences(_:)`,
  `installDantermInPath(_:)`), not through `performConfiguredCommand(_:)`;
- carries no configurable-command identity, so
  `ConfigurableMenuBindingSurface` never rewrites it and
  `commandDescriptor(id:)` is never asked to resolve it;
- stays enabled with no live window, via the selector branch of
  `MenuCommandPolicy` -- the same answer `scope: .application` gave before.

Settings owns `cmd+,` as a fixed key equivalent. The other three carry no key
equivalent.

Reaching the constructed App menu from a test needs an internal seam in
`app/AppDelegate.swift`; `buildMenu()` is private and only runs inside
`applicationDidFinishLaunching`. The seam's shape is discretionary.

**Reservation.** `keybindingReservations` gains an entry for `cmd+,` titled
`Settings`. The title is user-visible: it lands verbatim in the diagnostic
`keybindings.<id>[0]: reserved by Settings`, from both `effectiveBindings` and
the live recorder sheet. Assigning `cmd+,` to any configurable command is
rejected with that diagnostic. The other three removals need no reservation --
none has a default chord, so there is nothing to protect.

**Dispatch.** The `switch command` in `AppDelegate.performConfiguredCommand`
loses the four cases. The four action methods themselves are unchanged.

**Browser projection.** The Settings keybinding browser's Application group
lists exactly `app.open-config` and `app.reload-config`. Searching for the
removed commands returns nothing.

## Files

- `lib/DanTermCore/Sources/DanTermCore/CommandCatalog.swift` -- enum cases,
  descriptors, reservation.
- `app/AppDelegate.swift` -- App-menu construction, the dispatch switch, and the
  test seam.
- `app/PreferencesPanel.swift` -- `KeybindingRecorderButton.actionID` defaults to
  the literal `"app.settings"` as a non-optional placeholder, overwritten before
  use. Repoint it at some catalog id so it is not a dangling reference.
- `README.md` -- the reserved-chord prose gains Settings / `cmd+,`; the
  configurable-id list's Application line becomes `app.open-config`,
  `app.reload-config`. The `| Preferences | Cmd+, |` shortcut table row stays
  correct as written.

No `docs/design/`, `agent-docs/`, or `integrations/danterm/SKILL.md` changes:
keybindings have no CLI, IPC, or skill surface.

## Tests

TDD order -- write each failing first, confirm the failure reason, then change
the code.

New:

- **App menu behavior** (`tests-ui`): the four fixed items are present, each
  carries its own selector and no configurable-command identity, and Settings
  carries `cmd+,`. This is the only coverage of the menu-construction change.
- **Reservation conflict** (`CommandCatalogTests`): assigning `cmd+,` to a
  configurable command is rejected with `reserved by Settings`. The suite
  already has a native-reservation case to model.
- **Browser projection** (`KeybindingPreferencesTests`): the Application group
  lists only the two config commands.

Edited:

- `CommandCatalogTests` -- drop the four ids from the expected id set. The
  catalog-equals-enum assertion stays.
- `tests-ui/MenuCommandPolicyTests` -- the catalog-scope case passes
  `commandID: "app.settings"`, which now hits `commandDescriptor`'s
  `preconditionFailure`. Retarget it at `app.open-config`. The existing
  "window-independent app action ignores window liveness" case already covers
  the `showPreferences(_:)` selector route and needs no change.

Untouched and expected to stay green: `PreferencesPanelTests`,
`KeybindingConfigTests`, `DanTermConfigStoreTests`.

## Verification

1. `swift test --package-path lib/DanTermCore` and `just lint` in the edit loop.
2. `just test` before the commit; `just test-ui` for the AppKit cases, which are
   outside the gate because they need a WindowServer.
3. `just launch-slot`, then by hand:
   - App menu shows all six items, `Settings...` still reads `cmd+,`, and
     `cmd+,` opens Settings.
   - Settings > Keybindings: the Application group lists only Open DanTerm
     Config and Reload Config; searching "settings" and "install" returns
     nothing.
   - Record `cmd+,` onto Split Right: the sheet rejects it with
     `reserved by Settings`.
   - `just stop-slot <n>`.
4. Config check: `~/.config/danterm/config.json` currently overrides only
   `tab.color-green`, so no stale `app.*` entry and no chord collides with the
   new reservation. Nothing to migrate.

## Implementation discretion

- The shape of the App-menu test seam.
- The exact construction calls for the four fixed menu items.
- Which catalog id replaces the `KeybindingRecorderButton` placeholder.
- Placement of new test cases within their existing suites.

## Non-goals and accepted risks

- **AR1: a stale `app.*` keybinding entry in a user config is preserved and
  silently inert.** `DanTermConfigDocument` ignores unknown ids by design and
  keeps them in the file; this already has protocol-level coverage. No migration
  step is added -- the one live config has no such entry.
- **N1: `CommandDescriptor.isAvailableDuringTextEditing` is dead.** It has no
  runtime consumer; the only non-declaration reference is a pass-through copy
  when `ConfigurableMenuBindingSurface` rebuilds a hidden twin. Deleting it is
  worthwhile but is a separate change.

## Implementation notes

- The App-menu test seam is `AppDelegate.makeAppMenu() -> NSMenu`, a static
  method that `buildMenu()` calls for the App submenu. It keeps `buildMenu()`
  private and lets the UI test read the menu with no app launch and no side
  effect on `NSApp.mainMenu`.
- `KeybindingRecorderButton.actionID` now defaults to `"app.open-config"`.
- The four fixed items use `#selector(AppDelegate.<method>(_:))` and go through
  the responder chain with a nil target, the same route the catalog items used.
- Manual verification (plan step 3, `just launch-slot` plus by-hand menu,
  browser, and recorder checks) was not run. The new UI test covers the menu
  construction, and the two new core tests cover the reservation diagnostic and
  the browser projection.
