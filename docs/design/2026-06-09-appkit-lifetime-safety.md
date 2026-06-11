# AppKit / Ghostty Lifetime Safety: No Cross-Lifetime Use-After-Free

`Status`: Accepted
`Date`: 2026-06-09

## Context

On 2026-06-09, DanTerm v0.0.73 crashed with `EXC_BAD_ACCESS` /
`SIGSEGV` after a transient todo popover closed. Its standalone `NSTextView`
had `allowsUndo = true`, so AppKit registered typing undo into the window's
shared `UndoManager`. After the popover dismissed and deallocated the text
view, Cmd-Z (`Edit > Undo`) messaged the freed text view.

The fix is `ScopedUndoTextView` in `app/TodoInputView.swift`: the standalone
todo input overrides `undoManager` so typing undo is scoped to the view and
dies with it. `tests-ui/TodoInputViewTests.swift` locks down that the todo
input's undo manager is not the window's shared manager.

A follow-up lifetime audit checked the rest of the app for the same bug shape:
a longer-lived owner messaging or calling back a shorter-lived AppKit object,
controller, or Ghostty/C bridge after teardown. The audit covered undo,
NotificationCenter observers, NSEvent monitors, timers and async hops,
popovers, sheets, controller delegates, AppKit target/delegate references, and
the Ghostty `userdata` boundary. It found no second crashable site. This ADR
records both the rule and the safe map so future changes do not re-audit from
scratch or reintroduce the class.

## Decision

Preserve these lifetime invariants when adding or changing AppKit, Ghostty, or
stored-callback code:

1. A standalone `NSTextView` with `allowsUndo = true` must own its
   `UndoManager` by overriding `undoManager` (for example
   `ScopedUndoTextView`). Do not rely on a per-call-site `undoManager(for:)`
   delegate hook. `NSTextField` and `NSSearchField` are exempt because they use
   the window field editor: undo applies only while the edit session owns first
   responder focus and does not outlive the field edit.
2. Every NotificationCenter observer must have an owner-lifetime teardown path:
   block observers store the token and remove it in `deinit`; selector observers
   use `self` and remove it in `deinit`; re-registration first removes the old
   observer.
3. Every `NSEvent` monitor stores the token, removes it in `deinit`, and uses a
   `[weak self]` handler.
4. New popover and sheet view controllers use `weak runtime` or another weak
   owner reference. Their delegate clears the owner's retained handle on close,
   and nested popovers close child-before-parent.
5. Ghostty/C `userdata` must either be app-lifetime or stay retained until
   after the matching `free`. Surface `userdata` uses a retained
   `SurfaceBridge` for the surface's life, with a weak back-reference to the
   view. Never assume a deferred-free closure's `nsview` is alive; it is safe
   only while the free path does not message the view. Re-check that upstream
   condition during Ghostty upgrades, per
   [`../upgrading-ghostty.md#steps`](../upgrading-ghostty.md#steps).
6. Prefer `[weak self]` for stored escaping closures, timers, monitors, and
   async hops. Avoid `unowned`; the codebase currently has none.
7. `NSMenuItem.target` is weak -- an AppKit target that can outlive its referent
   must not be the only object keeping menu actions alive. A menu
   owned by a reconcile-ephemeral view (for example `PaneWrapperView`) must
   anchor that owner for the menu's lifetime by setting `representedObject` to
   it on every owner-targeted item; otherwise a reconcile mid-track can
   deallocate the target and turn actions into silent no-ops. Menu actions
   identify subjects with stable model ids rather than row indices and resolve
   those ids against the live model at fire time. Stale ids must either fail
   closed or use an intentional fallback documented at the handler/core
   boundary.

## Consequences

The current high-risk sites are safe for these specific reasons:

- Deferred `ghostty_surface_free` with
  `nsview = Unmanaged.passUnretained(self).toOpaque()`
  (`app/TerminalView.swift:74,152-169`) is safe because `closeSurface()` defers
  only the surface free, and Ghostty's current Metal renderer teardown stores no
  view field and releases only its GPU objects
  (`.ghostty-src/src/renderer/Metal.zig:158-161`). No free path messages the
  possibly-deallocated `nsview`. This is upstream-dependent and must be
  re-checked on Ghostty upgrades.
- `SurfaceBridge` `passRetained` surface userdata
  (`app/TerminalView.swift:6-8,68-70,159-164`) is held for the surface's life
  and released only after `ghostty_surface_free`; `bridge.view` is weak, so
  callbacks after view teardown see `nil`.
- `GhosttyApp` `passUnretained` app userdata
  (`app/GhosttyApp.swift:150,152-161,203-209`) is tied to the app-lifetime
  Ghostty owner. Callback hops either run through that owner or capture resolved
  values before dispatching.
- Field-editor undo in sidebar rename, preferences fields, and search
  (`app/SidebarView.swift:1367-1434`, `app/PreferencesPanel.swift:94-118`,
  `app/SearchOverlayView.swift:86`) uses `NSTextField` / `NSSearchField` edit
  sessions rather than a standalone undo-enabled `NSTextView`.
- Context menus are safe in two shapes. `SidebarView` menus target the
  long-lived sidebar and carry model ids or id boxes in `representedObject`;
  tab actions re-resolve/filter live ids through `currentModel` and core update
  paths (`app/SidebarView.swift:787-807,847-995,1040-1078`). Group "New Tab" is
  not a fail-closed stale-id example: a stale group id follows `createTab`'s
  existing fallback to the selected tab's group
  (`lib/DanTermCore/Sources/DanTermCore/Update.swift:51-60`,
  `lib/DanTermCore/Tests/DanTermCoreTests/UpdateTabTests.swift:274-304`).
  `PaneWrapperView.makePaneMenu` targets the reconcile-ephemeral wrapper and
  anchors it via `representedObject = self` on each wrapper-targeted item
  (`app/PaneWrapperView.swift:425-485`); its clipboard items target the
  reconcile-stable `TerminalView` and need no anchor.
- Menu `undo:` / `redo:` (`app/AppDelegate.swift:246-249`) dispatches through
  the responder chain. DanTerm has no window-level `registerUndo` site.
- `WindowChromeView` selector observers
  (`app/WindowChromeView.swift:172-187`) and `ScrollableTerminalView` block
  observers (`app/ScrollableTerminalView.swift:74-122`) remove their
  NotificationCenter registrations in `deinit`.
- `AppRuntime`'s switcher monitor (`app/AppRuntime.swift:103-115`) stores its
  token, uses `[weak self]`, and removes the monitor in `deinit`.
- Popover delegate adapters in `app/AppRuntime.swift` use weak runtime
  references (`app/AppRuntime.swift:1412-1464`), clear or reconcile the retained
  popover handle on close, and close shortcut-help child popovers before parent
  TODO popovers close. The shortcut help controller keeps weak parent references
  (`app/TodoShortcutHelpView.swift:146-200`).
- Debouncers, `DispatchSourceTimer` handlers, and the IPC actor
  (`app/AppRuntime.swift:842-899`,
  `lib/DanTermSupport/Sources/DanTermSupport/Debouncer.swift:50-74`,
  `app/IpcServer.swift:35-69`) use `[weak self]` or explicit close/cancel paths
  so an owner teardown does not leave a strong callback cycle that can message a
  freed owner.
- Known asymmetry: `AppRuntime.deinit` cancels the local event monitor but not
  its two `DispatchSourceTimer`s (`app/AppRuntime.swift:103-106,856-899`). That
  is benign while `AppRuntime` remains the app-lifetime singleton because
  handlers use `[weak self]`, and the enriched checkpoint timer is cancelled on
  `.terminate` (`app/AppRuntime.swift:581-584`). If `AppRuntime` ever becomes
  per-window, add `deinit` timer cancellation.

No enforcement lint is added for this docs-only hardening pass. If this bug
class recurs, consider a focused app-lifetime lint for new standalone
undo-enabled text views, observer tokens, event monitors, and stored escaping
closures.

## References

- `app/TodoInputView.swift:8-13,67-101` -- `ScopedUndoTextView`, the scoped undo
  fix for the transient todo input.
- `tests-ui/TodoInputViewTests.swift:45-72` -- UI regression coverage for
  keeping todo input undo out of the window undo manager.
- `docs/upgrading-ghostty.md` -- Ghostty upgrade step that re-checks the
  deferred-free `nsview` assumption.
- `app/PaneWrapperView.swift:425-485` -- `makePaneMenu` / `wrapperItem`, the
  `representedObject` anchor for menus owned by a reconcile-ephemeral view.
- [Apple: Using Undo in AppKit-Based Applications](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/AppKitUndo.html)
  -- AppKit's undo-manager lookup, `NSTextView` undo behavior, and text-field
  edit-session undo behavior.
