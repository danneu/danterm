# Replace quit-confirmation sheet with a non-modal NSPanel

## Context

The terminate confirmation in DanTerm is currently a window-modal `NSAlert`
sheet attached to the main window
(`app/AppRuntime.swift` `case .showTerminateConfirmation(...)`). When the
sheet is up, the main window is non-interactive: terminals can't be focused,
typed into, or scrolled.

A bug recently surfaced where libghostty fired `GHOSTTY_ACTION_QUIT` in a
tight loop, queueing thousands of confirmation sheets that couldn't be
dismissed. The previous commit
(`159062a fix(lifecycle): guard confirmation sheet re-entry`) coalesced
emission via `Model.pendingConfirmation`, so duplicate `.requestQuit` calls
no longer stack new sheets. That fixed the immediate stuck state.

This plan replaces the remaining sheet UI with a non-modal `NSPanel` so the
user can keep using their terminals while the prompt is open and dismiss
the prompt naturally if they decide not to quit. Close-tab confirmation
stays an `NSAlert` sheet for now (tab-scoped, not app-scoped).

## Approach

- New `QuitConfirmationPanel` (`NSPanel` subclass), modeled on
  `PreferencesPanel` (file: `app/PreferencesPanel.swift`).
- Floating-level, `[.titled, .closable, .utilityWindow]` style mask, with
  `hidesOnDeactivate = false` (overrides the utility-window default so the
  panel stays visible if the user clicks away to another app).
- Quit / Cancel buttons route through the existing
  `.confirmTerminate` / `.cancelTerminate` `Msg` cases. Red-X close routes
  to `.cancelTerminate` via `windowShouldClose`. ESC = Cancel,
  Return = Quit.
- Body copy preserves the old count-specific wording: "This will close
  {count} terminal session(s)." The prompt is non-modal, so the runtime
  also refreshes the label from the live model while quit confirmation is
  pending.
- `AppRuntime` lazily creates and retains the panel (same pattern as
  `preferencesPanel` at `app/AppRuntime.swift:29`). The retained panel is
  torn down in `tearDownCurrentSession()` (`app/AppRuntime.swift:984`)
  alongside `preferencesPanel`, `alertsPopover`, and `todoPopover`, so an
  Import / restore-session swap can't leave a stale panel that fires
  `.confirmTerminate` against a freshly-loaded model.
- No `Model`, `Update`, `Effect`, or `Msg` changes. Coalesce in
  `Model.pendingConfirmation` already gates re-entry; existing tests in
  `tests/UpdateLifecycleTests.swift` continue to apply unchanged.

## Files

### Add

- `app/QuitConfirmationPanel.swift` — new file. `NSPanel` subclass
  conforming to `NSWindowDelegate`. Holds a static body label
  configured from the current pane count and Quit / Cancel buttons in an
  `NSStackView`. Quit / Cancel handlers call `orderOut(nil)` and dispatch
  `runtime?.send(.confirmTerminate)` / `.cancelTerminate`. `windowShouldClose`
  sends `.cancelTerminate` and returns `true`.

### Edit

- `app/AppRuntime.swift`
  - Add private property next to `preferencesPanel` (line ~29):
    `private var quitConfirmationPanel: QuitConfirmationPanel?`
  - Replace `case .showTerminateConfirmation(let paneCount):` block
    (lines 367–390) with a panel show/center/order-front sequence. Lazily
    instantiate, position centered on the main window's frame (or
    `center()` if no window), configure the body copy from `paneCount`,
    then `makeKeyAndOrderFront(nil)`.
  - In `tearDownCurrentSession()` (line 984), after the existing
    `preferencesPanel?.close(); preferencesPanel = nil` lines, add
    `quitConfirmationPanel?.orderOut(nil); quitConfirmationPanel = nil`.
    `orderOut` hides the retained, reusable panel without posting
    `windowWillClose` / `windowDidClose` notifications — the panel stays
    intact for next use, and the model swap doesn't trigger any stray
    Cocoa lifecycle work. (`close()` would also not fire
    `windowShouldClose` — only `performClose(_:)` does — but `close()`
    posts close notifications and tears down some state; `orderOut` is
    the lightweight hide that matches our reuse pattern.)

### Untouched (verify, do not edit)

- `app/Model.swift` — `PendingConfirmation` enum stays as-is.
- `app/Update.swift` — `.confirmTerminate` / `.cancelTerminate` /
  `.requestQuit` cases stay as-is. They already clear
  `pendingConfirmation`.
- `app/Effect.swift` — `.showTerminateConfirmation(paneCount: Int)`
  signature unchanged.
- `app/AppDelegate.swift` — `windowShouldClose`,
  `applicationShouldTerminate`, and the `quitConfirmed` flag stay as-is.
  The new panel does not change the terminate-cancel / NSApp.terminate
  handshake.
- `app/GhosttyApp.swift:265` — `GHOSTTY_ACTION_QUIT` still calls
  `runtime?.send(.requestQuit)`.

## Behaviors locked down

- **Mash Cmd+Q**: only one panel ever exists.
  `pendingConfirmation = .terminate` after the first emit; subsequent
  `.requestQuit` returns `[]` from `emitTerminateConfirmation` in
  `app/ModelOperations.swift`.
- **Cmd+Q while panel up**: no-op at the model layer; the existing panel
  remains visible (it's at `.floating` level so it's already on top).
- **Click into a terminal pane while panel up**: pane gets focus, typing
  works. Panel stays visible above.
- **Red-X on panel**: routes to `.cancelTerminate`; clears
  `pendingConfirmation`.
- **Red-X on main window with multi-pane / multi-tab**:
  `AppDelegate.windowShouldClose` returns `false` and sends
  `.requestQuit`, same as today — now shows the panel instead of the
  sheet.
- **NSApp.terminate(...) from another path**: `applicationShouldTerminate`
  returns `.terminateCancel` and sends `.requestQuit`. Same flow.
- **Confirm**: panel hides itself (`orderOut`), then `.confirmTerminate`
  → `.terminate` → `quitConfirmed = true` → `NSApp.terminate(nil)` →
  `applicationShouldTerminate` returns `.terminateNow`. Unchanged.
- **Import / session restore while panel is up**:
  `commitRestoreSession` calls `tearDownCurrentSession`, which now also
  hides and nils the panel. The user's next click can't fire
  `.confirmTerminate` against the freshly-loaded model. The new model
  starts with `pendingConfirmation = nil`, so a subsequent Cmd+Q creates
  a fresh panel cleanly.
- **Pane count changes while panel is up**: runtime refreshes the panel body
  from `model.panes.count` while quit confirmation remains pending.

## Verification

1. **Build**: `just build` — release- and debug-equivalent compile must
   pass.
2. **Unit tests**: `just test`. Existing `UpdateLifecycleTests` and
   `UpdateTabTests` (added in commit 159062a) cover the model behavior;
   they should still pass with no changes.
3. **Manual smoke** (`just build-run`):
   - Open with at least 2 panes. Cmd+Q. Confirm a panel appears, *not* a
     sheet, and that the main window's titlebar isn't dimmed.
   - With the panel up, click a terminal pane and type — input should go
     to the pane.
   - Press ESC → panel closes, app keeps running.
   - Cmd+Q again, click Quit → app quits cleanly.
   - Reopen, Cmd+Q, click red-X on panel → app keeps running.
   - Reopen, mash Cmd+Q ~30 times → exactly one panel visible.
   - Reopen, click main-window red-X with multiple panes → panel appears
     (not sheet).
4. **Single-pane sanity**: with only one pane, Cmd+Q should still confirm
   (current behavior — no change).
5. **Close-tab confirmation untouched**: with two tabs, each multi-pane,
   right-click → Close Tab on a non-last tab should still produce an
   `NSAlert` sheet (this plan deliberately doesn't migrate that path).
6. **Import flow**: with the quit panel open, trigger File → Import (or
   the equivalent restore-session path that calls `commitRestoreSession`).
   The panel must disappear before the new session loads. After import,
   the previously-shown panel's Quit button must not be reachable; a
   fresh Cmd+Q must work normally.

## Out of scope

- Migrating `case .showCloseTabConfirmation(...)` to a panel. Tab-scoped
  confirmation is fine as a sheet; revisit if a similar fire-hose bug
  appears there.
- Adding a `confirm-on-quit = true|false` config. Already noted in the
  prior plan as deferred.
- Persisting panel position across launches. macOS will not auto-save
  utility-window frames; not worth wiring up frameAutosave for a
  rarely-shown panel.
