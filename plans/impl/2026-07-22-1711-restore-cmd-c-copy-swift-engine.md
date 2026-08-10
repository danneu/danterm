# Restore Cmd-C copy under the Swift terminal engine

## Context

Cmd-C does not copy in DanTerm Dev when running the Swift terminal engine,
though right-click > Copy and Cmd-V both work. It works in DanTerm proper
(libghostty).

The cause is that Cmd-C was never a DanTerm feature -- it was Ghostty's. The
trace:

- `app/AppDelegate.swift:264` builds Edit > Copy with
  `action: #selector(NSText.copy(_:))`, `keyEquivalent: "c"`. AppKit enables a
  nil-targeted item only if some responder implements the action. **No responder
  implements `copy(_:)`**, so the item is disabled in both builds and its key
  equivalent is declined.
- The event therefore falls through to the focused view's `keyDown`.
- libghostty path: `TerminalView.keyDown` (`app/TerminalView.swift:448`)
  forwards every key, Command included, into `ghostty_surface_key`. Ghostty core
  matches its own default bind `super+c -> copy_to_clipboard`
  (`.ghostty-src/src/config/Config.zig:6450-6456`) and calls back out through
  `write_clipboard_cb` (`app/GhosttyApp.swift:245`), which writes to
  `NSPasteboard.general`.
- Swift engine path: `SwiftTerminalSessionView.keyDown`
  (`app/SwiftTerminalSessionView.swift:267`) opens with
  `guard event.modifierFlags.contains(.command) == false else { return }` and
  drops every Command-modified key. There is no in-app keybind layer behind it,
  so the shortcut evaporates.

Cmd-V survives only because `paste(_:)` already exists
(`app/SwiftTerminalSessionView.swift:419`) and enables its menu item. Copy has
the counterpart method `copySelection()` (line 408), but it is a plain method
the context menu calls directly via `PaneWrapperView.copySelectionAction`
(`app/PaneWrapperView.swift:477`) -- it is not on the responder chain.

Outcome: Cmd-C copies the selection, and Edit > Copy greys out with no
selection so the user can see nothing is selected.

## Approach

Own the shortcut where macOS expects it: the responder chain plus menu
validation. Do not reintroduce a Command-key branch in `keyDown` -- the Swift
engine correctly declines to own app shortcuts.

### 1. Responder-chain `copy(_:)`

In `app/SwiftTerminalSessionView.swift`, beside the existing `paste(_:)`, add a
responder-chain `@objc func copy(_ sender: Any?)` delegating to the existing
`copySelection()`. That alone enables the Edit > Copy item and makes Cmd-C work,
reusing the existing `copySelection()` ->
`controller.readSelectedTextSynchronizing()` -> `writeClipboard` path.

### 2. Disable Copy with no selection

Conform `SwiftTerminalSessionView` to `NSMenuItemValidation`, returning
`hasSelection` for `copy(_:)` and `true` for every other action.

Reuse `hasSelection` (`app/SwiftTerminalSessionView.swift:67`), which is
deliberately cache-only and does not fence pending selection work -- the correct
property for validation, which must be cheap and non-blocking. This mirrors the
existing precedent at `app/PaneWrapperView.swift:436-437`, where the context
menu's Copy is disabled rather than hidden on the same predicate.

Notes:

- Returning `true` for every other action keeps `paste(_:)` and unrelated
  nil-targeted items unaffected. `AppDelegate.validateMenuItem`
  (`app/AppDelegate.swift:767`, via `MenuCommandPolicy`) is untouched: it only
  validates items the delegate itself responds to.
- With no selection the item is disabled, so Cmd-C again falls to `keyDown` and
  is dropped. That is the intended no-op.

### 3. No change to the libghostty path

`TerminalView` is a distinct class that does not implement `copy(_:)`, so its
Edit > Copy stays disabled and Cmd-C keeps flowing to Ghostty's keybind.
Behavior there is unchanged.

## Non-goals / Accepted risks

- **AR1: Menu enablement and the copy action read selection state through
  different paths.** `validateMenuItem` reads cache-only `hasSelection` while
  `copySelection()` fences via `readSelectedTextSynchronizing()`, so in the
  window between a drag ending and consumption completing, Edit > Copy can be
  enabled while the copy no-ops (or the inverse). Accepted: delayed-but-eventual,
  identical to the already-shipped context menu
  (`app/PaneWrapperView.swift:436-437`), and the divergence is deliberate --
  pinned by the existing test `"explicit copy fences selection and hasSelection
  stays cache-only"` (`tests-ui/SwiftTerminalSessionViewTests.swift:182`).
  Making validation fence would make menu tracking block on the render owner.

## Out of scope (follow-up)

The same regression shape likely applies to other binds libghostty supplied for
free and `keyDown`'s Command guard now swallows: Cmd-Shift-C (copy as HTML),
Cmd-K, Cmd-Plus/Minus/0 font size, Cmd-Comma. Worth an audit against Ghostty's
default keybind table, but not part of this fix.

## Files

- `app/SwiftTerminalSessionView.swift` -- add `copy(_:)` and the
  `NSMenuItemValidation` conformance.
- `tests-ui/SwiftTerminalSessionViewTests.swift` -- new tests.

## Verification

Tests (TDD -- write failing first):

1. In `tests-ui/SwiftTerminalSessionViewTests.swift`, following the existing
   `uiTest("explicit copy fences selection...")` at line 182 (same
   `TerminalPaneSessionController` + `makeMountedPane` + injected
   `selectionPasteboard` fixture):
   - `copy(_:)` with a selection puts the finalized text on the injected
     pasteboard.
   - `validateMenuItem` returns `false` for a `copy(_:)` item with no selection
     and `true` once a selection exists.
   - `validateMenuItem` returns `true` for a `paste(_:)` item regardless of
     selection (guards against over-broad validation).
   - A Command-`c` `keyDown` dispatched to a mounted pane produces no controller
     input -- assert `controller.inputBytes` is unchanged, the same vehicle the
     existing key-encoding tests use (line 499). This pins the `keyDown` Command
     guard the whole approach rests on: the failure mode a wrong fix introduces
     is a stray byte reaching the shell.
2. `just test-ui` -- the suite needs a WindowServer, so run from a GUI session.
3. `just test` -- confirm the local gate is still green.

Manual end-to-end:

4. `just build-run`, open a pane on the Swift engine, drag-select some output.
   Check Edit > Copy is enabled, press Cmd-C, paste elsewhere to confirm.
5. Click to clear the selection: Edit > Copy is greyed out and Cmd-C does
   nothing (no stray character sent to the shell).
6. Confirm right-click > Copy and Cmd-V still behave as before.
