# Todo Popover Shortcut Help

## Summary

Add discoverable keyboard help to both todo popovers without making the main todo UI noisy: a small keyboard-help button in the header, `Cmd+/` as a keyboard way to open it, and a subtle `Shift+Return for newline` hint under todo text-entry fields.

The shortcut content is shared, mode-sectioned, and scope-aware: pane popovers omit tab-only bucket movement, while tab popovers include `Shift+H` / `Shift+L`.

## Key Changes

- Add a pure shortcut catalog in a new `app/TodoShortcutCatalog.swift`:
  - `TodoShortcutScope`: `.pane`, `.tab`
  - `TodoShortcutItem`: `keys`, `action`
  - `TodoShortcutSection`: `title`, `items`
  - `todoShortcutSections(scope:) -> [TodoShortcutSection]`
- Catalog sections:
  - `List`: `J/K` or arrows, `Return`, `Space`, `Esc`, `Tab` / `Shift+Tab`, `Cmd+N`, `Cmd+Delete`, `Shift+J/K`
  - `List` for tab only: also `Shift+H/L` for previous/next todo section
  - `Compose`: `Return`, `Shift+Return`, `Esc`, `Tab` / `Shift+Tab`
  - `Edit`: `Return`, `Shift+Return`, `Esc`, `Tab` / `Shift+Tab`, `Cmd+N`
  - Do not list duplicate aliases like `Cmd+Return` when plain `Return` already performs the same action.
- Extend the pure list classifier in `app/TodoInputCommand.swift`:
  - Add `ListKey.slash`.
  - Add `ListAction.showShortcutHelp`.
  - `classifyListAction(key: .slash, modifiers: [.command]) -> .showShortcutHelp`
  - `classifyListAction(key: .slash, modifiers: [.command, .shift]) -> .showShortcutHelp`
  - Plain `.slash` (no modifier) returns `.unhandled`.
  - Map the `/` key in `listKey(from:)` and `tabListKey(from:)` to `ListKey.slash`. Apple's `NSEvent.charactersIgnoringModifiers` preserves Shift, so `Shift+/` on a US keyboard arrives as `?`. Both mappers must match `"/"` **and** `"?"` to produce `.slash` so `Cmd+Shift+/` reaches the classifier (the existing `.h`/`.l` mappers don't need this only because `.lowercased()` collapses `H` to `h` — `?` does not collapse to `/`).
- Add a shared AppKit shortcut-help view in `app/TodoShortcutHelpView.swift`:
  - Renders the catalog as compact labels in an `NSPopover`.
  - Uses a monospaced/small key label column and normal action text.
  - Renders key labels using the existing Unicode glyph convention already used in this file family (e.g. `⌘N`, `⇧⏎`, `⌘⌫`); see `TabTodoPopoverView.swift:151` where `"New (⌘N)"` is already shown.
  - Has no user-focusable content controls so opening it does not appear to steal focus from the editor/list. To handle Esc dismissal, the view installs a minimal "dismiss-only" responder (an `NSView` subclass with `acceptsFirstResponder = true` and a `cancelOperation(_:)` override that calls `popover.performClose(nil)`). The help popover's view controller calls `view.window?.makeFirstResponder(dismissResponder)` after `popoverDidShow`. This responder takes no visible focus ring and exposes no keyboard navigation — its sole job is to absorb `Esc` so the keystroke does not propagate up to the parent popover's table view (`handleCancelOperation` closes the parent) or to an edit-mode text view (whose classifier returns `.cancelEdit` / `.dismiss`).
- Update `TodoPopoverViewController` and `TabTodoPopoverViewController`:
  - Add an image-only help button using SF Symbol `keyboard`, with `?` title fallback if the symbol is unavailable.
  - Tooltip/accessibility label: `Keyboard shortcuts`.
  - Pin the help button at the trailing edge of the header as its own view, **not** inside the conditionally-detaching `headerActions` stack — so the help button anchor does not shift left/right when `Clear completed` (or `New`) shows/hides via `detachesHiddenViews = true` (`TabTodoPopoverView.swift:225`).
  - The pane popover currently has no actions stack; introduce one for `Clear completed` to its left of the pinned help button.
  - Help button toggles the shortcut popover, anchored to the button and preferred below it.
  - `Cmd+/` and `Cmd+Shift+/` toggle the shortcut popover from list, compose, and edit modes. List mode routes through the classifier; compose/edit mode's `performTodoKeyEquivalent` adds a branch that maps `ListKey.slash` (with `.command` or `.command + .shift`) to the help action so all three modes funnel through the same pure decision.
  - Close the shortcut popover when the parent todo popover disappears.

### Popover stacking (parent transient + child help)

The existing parent popovers use `behavior = .transient` (`AppRuntime.swift:685, 705`). A transient popover auto-dismisses on any click that lands outside its window. A child help popover opens in its own AppKit window, so a click inside the help popover would register as "outside" the parent and silently dismiss the entire todo popover.

To prevent that:

- When showing the help popover, capture the parent's current behavior (`.transient`) and swap it to `.applicationDefined` for the duration the help popover is visible.
- Open the help popover with `behavior = .applicationDefined`.
- In the parent popover's `popoverWillClose` delegate (`TodoPopoverDelegateAdapter` / `TabTodoPopoverDelegateAdapter` in `AppRuntime.swift:1459, 1473`), call `performClose(nil)` on any open help popover so both close together cleanly.
- When the help popover closes (its own `popoverDidClose`), restore the parent's behavior to `.transient` so subsequent outside clicks dismiss the parent as they do today.

This keeps the existing "click outside to dismiss" behavior of the parent popover for all states except "help popover is open."

#### Parent-close ordering

Apple's `NSPopover.performClose(_:)` is documented as best-effort — it can be refused when the popover has a nested popover or a child window attached. The four runtime close paths today call `performClose(nil)` directly: `showTodoPopover` re-entry (`AppRuntime.swift:674`), `dismissTodoPopover` (`AppRuntime.swift:691`), `showTodoPopoverForTab` re-entry (`AppRuntime.swift:696`), and `dismissTodoPopoverForTab` (`AppRuntime.swift:711`). If the help popover is open and `performClose` is refused, the parent's `popoverWillClose` never fires and our cascading-close path never runs.

To make close ordering deterministic:

- Introduce a `dismissTodoPopoverPair(...)` helper on `AppRuntime` (one per pane/tab popover, or a single helper parameterized by which parent reference to clear). It first calls `performClose(nil)` on any tracked help popover and clears its reference, then calls `performClose(nil)` on the parent. Help closes first so the parent has no child window when its own close is attempted.
- Replace the four bare parent `performClose(nil)` call sites above with calls to the helper.
- The cascading close from parent `popoverWillClose` (described above) remains as a defense-in-depth path: if the help popover was somehow opened or surfaced outside the helper's knowledge, the parent's delegate still closes it on the way out.

### Focus restoration after help closes

Presenting the help popover moves key-window focus to the help popover's window, where the dismiss-only responder described above takes first responder. On close, we must explicitly restore focus to the parent or the user lands back in an indeterminate responder (table view rather than the compose field they were typing in).

- Before showing the help popover, capture `view.window?.firstResponder` in the parent popover.
- In the help popover's `popoverDidClose` delegate, call `parent.view.window?.makeFirstResponder(savedResponder)` to put the caret back where the user invoked Cmd+/.
- This restoration runs regardless of whether the help popover was closed via Esc (dismiss responder), `popoverWillClose` cascade from the parent, or programmatic `performClose`.

### Hint labels

- Under compose input in list mode: `Shift+Return for newline`
- Under edit input before Save/Cancel: `Shift+Return for newline`
- Use small secondary text and keep labels noninteractive.

## Test Plan

- Add unit tests for `todoShortcutSections(scope:)`:
  - Pane catalog: List section contains `Cmd+N`, `Cmd+Delete`, `Shift+J/K`; Compose section contains `Shift+Return`; Edit section contains `Shift+Return` and `Cmd+N`.
  - Pane catalog does not contain `Shift+H` or `Shift+L` anywhere.
  - Tab catalog: same as pane plus `Shift+H` and `Shift+L` in the List section; Compose section contains `Shift+Return`; Edit section contains `Shift+Return` and `Cmd+N`.
  - Catalog rendering uses the Unicode glyph convention (`⌘`, `⇧`, `⏎`, `⌫`) consistent with existing UI labels.
- Extend `UpdateTodoTests.swift` classifier tests:
  - `classifyListAction(key: .slash, modifiers: [.command]) == .showShortcutHelp`
  - `classifyListAction(key: .slash, modifiers: [.command, .shift]) == .showShortcutHelp`
  - `classifyListAction(key: .slash, modifiers: KeyModifiers()) == .unhandled`
  - `classifyListAction(key: .slash, modifiers: [.shift]) == .unhandled`
  - Existing `Cmd+Shift+H/L` behavior remains `.unhandled` by the pure classifier.
- Register new tests in `tests/TestHarness.swift`.
- Add `app/TodoShortcutCatalog.swift` to `test.sh`.
- Run:
  - `just test`
  - `just build`

## Manual Verification

- Open pane todo popover:
  - Help button appears pinned at the trailing edge of the header. Toggling `Clear completed` visibility does not shift the help button.
  - Click help and press `Cmd+/` from list, compose, and edit mode. Also verify `Cmd+Shift+/` opens the same help popover from all three modes (confirms the `?` mapping in `listKey(from:)` / `tabListKey(from:)`).
  - Clicks inside the help popover do not dismiss the parent todo popover.
  - Pressing Esc inside the help popover closes only the help popover (not the parent), and caret focus returns to the compose/edit field if that was the active responder when help was opened. From list mode, Esc closes the help popover and the table view regains first responder (a subsequent Esc still closes the parent via the existing list-mode `handleCancelOperation`).
  - Closing the parent todo popover also closes the help popover.
  - Help omits `Shift+H/L`.
  - `Shift+Return for newline` hint is visible under compose/edit fields.
- Open tab todo popover:
  - Help button stays pinned at the trailing edge whether `Clear completed` is hidden or visible.
  - Help includes `Shift+H/L`.
  - `Cmd+/` works from list, compose, and edit mode with the same focus-restoration behavior.
- Verify existing shortcuts still work: `Return`, `Shift+Return`, `Esc`, `Tab`, `Shift+Tab`, `Shift+J/K`, `Shift+H/L` in tab popover, `Cmd+N`, and `Cmd+Delete`.
- Verify the parent popover still auto-dismisses on outside click when the help popover is closed (i.e. behavior restoration works).
- With the help popover open, dismiss the parent via every available path (clicking the toolbar todo button again, switching tabs, closing the window). Each should tear down both popovers in order (help first, then parent) without leaving a stray help popover floating.

## Assumptions

- Use Unicode key glyphs (`⌘`, `⇧`, `⏎`, `⌫`) for shortcut display in this UI to match the existing label convention in `TabTodoPopoverView.swift:151` (`"New (⌘N)"`). The global ASCII-preferred rule has an explicit "surrounding file already uses Unicode" exception that applies here. Comments/identifiers in Swift source remain ASCII (`Cmd`, `Return`, `Shift`).
- Keep shortcut help as an in-popover aid, not menu bar documentation.
- Do not add persistent footer shortcut text beyond the one newline hint.
