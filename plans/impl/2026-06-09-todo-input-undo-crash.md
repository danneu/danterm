# Fix: use-after-free crash on Cmd-Z after dismissing a todo input

## Context

DanTerm (prod v0.0.73) crashed today while the user was composing a todo at the
tab level: they dismissed the input instead of pressing Enter, then a keystroke
crashed the app. Crash report:
`~/Library/Logs/DiagnosticReports/DanTerm-2026-06-09-091754.ips`.

The signal is `EXC_BAD_ACCESS` / `SIGSEGV` ("possible pointer authentication
failure") on the main thread, and the backtrace is unambiguous:

```
objc_msgSend                          <- messaging a freed object (clobbered isa)
-[_NSUndoStack popAndInvoke]
-[NSUndoManager undoNestedGroup]
-[NSApplication sendAction:to:from:]
-[NSMenu performKeyEquivalent:]       <- Cmd-Z fired Edit > Undo (AppDelegate.swift:246)
```

### Root cause

The todo input is an `NSTextView` with `allowsUndo = true`
(`app/TodoInputView.swift:93`) hosted inside a **`.transient` `NSPopover`**
(`app/AppRuntime.swift:690-698`). It has no `undoManager(for:)` delegate hook, so
NSTextView registers its built-in typing-undo against the **window's shared
`UndoManager`**, targeting the text view. Dismissing the popover runs
`tabTodoPopover = nil` (`app/AppRuntime.swift:293-294`), which deallocates the
view controller and the text view -- but **nothing clears the undo stack** (there
are no `removeAllActions`/`registerUndo` calls anywhere in `app/`). A later Cmd-Z
pops the stale entry and messages the freed text view -> use-after-free.

The intended outcome: in-field undo while composing keeps working, but a todo
field's undo registrations can never outlive the field, so dismiss-then-Cmd-Z is
safe.

### Blast radius (verified)

`TodoInputView` is the **only** vulnerable site. It backs both the pane popover
(`TodoPopoverView.swift`) and the tab popover (`TabTodoPopoverView.swift`), so a
single fix in `TodoInputView` covers all four `addInput`/`editInput` instances.

Everything else is safe -- and the reason matters for future readers. The other
editable controls (`NSTextField`/`NSSearchField`: sidebar rename, Preferences,
search overlays, theme pickers) edit through the window's **field editor**, a
persistent window-owned `NSTextView`, not a standalone text view they own. Per
Apple's undo docs, a text field's undo applies only while it is first responder and
"prior operations cannot be undone" once the insertion point leaves the field, and
the field editor is never deallocated mid-edit -- so no undo action survives to
target a freed field. The todo input is the lone exception: a standalone `NSTextView`
with `allowsUndo = true` that registers against the window's `UndoManager` and is
itself deallocated on dismiss. No other `UndoManager` usage exists in `app/`.
(Ref: Apple, "Using Undo in AppKit-Based Applications".)

## The fix

Scope each todo text view's undo to a manager **owned by the text view**, so the
undo stack's lifetime is tied to the view (not the window). Implement it as a
small private `NSTextView` subclass inside `TodoInputView.swift` -- mirroring the
existing `FocusRingScrollView: NSScrollView` private subclass already in that file,
which is the house idiom for encapsulating view-specific AppKit behavior here.

### `app/TodoInputView.swift` (only production change)

1. Add a private subclass near `FocusRingScrollView` (top of file):

   ```swift
   /// NSTextView that owns its undo stack instead of inheriting the window's
   /// shared UndoManager. The todo inputs live in transient NSPopovers; with the
   /// default behavior, typing-undo registers against the window manager and
   /// outlives the text view when the popover is dismissed, so a later Cmd-Z
   /// (Edit > Undo) messages the freed text view -- a use-after-free crash. Scoping
   /// the manager to the text view ties the undo stack to the view's lifetime, and
   /// still serves Cmd-Z while editing (the field is first responder, so the
   /// responder chain resolves Undo to this manager).
   private final class ScopedUndoTextView: NSTextView {
       private let scopedUndoManager = UndoManager()
       override var undoManager: UndoManager? { scopedUndoManager }
   }
   ```

   (Inherits NSTextView's `init(frame:)` -- the stored property has a default and
   no designated initializer is added, so the "must use `NSTextView(frame:)` to get
   a text container" requirement at line 60-61 still holds.)

2. Change the construction at `app/TodoInputView.swift:61`:

   ```swift
   textView = ScopedUndoTextView(frame: .zero)   // was: NSTextView(frame: .zero)
   ```

   Keep `let textView: NSTextView` (line 28) and `textView.allowsUndo = true`
   (line 93) unchanged -- `allowsUndo` still enables typing-undo; it now registers
   into the scoped manager.

**No changes to the two view controllers, `AppRuntime`, the menu wiring, or the
test harness plumbing.** The fix is intrinsic to the reusable component, so any
future use of `TodoInputView` is protected automatically (the original bug was
exactly a per-call-site hook that was easy to omit).

### Alternatives rejected

- **`undoManager(for:)` delegate hook on each VC** -- the Apple-documented route,
  but it spreads the fix across both VCs (the same forgettable per-call-site wiring
  that caused the bug), can't be unit-tested without compiling the full VCs into the
  UI-test target, and isn't future-proof for new callers.
- **Clear undo on dismiss** (`removeAllActions` in a close/teardown hook) -- fragile:
  must cover every dismiss path (click-away, Escape, programmatic close, window
  close) and run while the view is still in its window. Lifetime-scoping is robust by
  construction.
- **Disable undo** (`allowsUndo = false`) -- loses in-field undo while composing
  multi-line todos.

## Test (regression)

Add one `uiTest` to the existing `todoInputViewTests()` in
`tests-ui/TodoInputViewTests.swift`. This file and `app/TodoInputView.swift` are
already compiled into the `test-ui` target (`test-ui.sh:35,43`) and the function is
already registered (`tests-ui/PaneSplitViewTests.swift:14`), so **no harness
plumbing changes are needed**. Mirror the existing `uiTest`/`uiExpect` style and the
`NSWindow` setup used in `SidebarSelectionCacheTests`.

```swift
uiTest("todo input scopes undo to its own manager and still undoes typing") {
    // Intent: a TodoInputView's typing-undo lives in a manager owned by the field
    //   (so it dies with the field), AND in-field undo while composing still works.
    // Why it exists: regression for the 2026-06-09 SIGSEGV -- typing-undo against
    //   the window's shared manager outlived the deallocated text view when the
    //   transient todo popover was dismissed, so a later Cmd-Z messaged a freed
    //   object. The fix must not regress normal undo-while-composing.
    let input = TodoInputView()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
        styleMask: [.titled], backing: .buffered, defer: false)
    defer { window.close() }
    window.contentView = input
    window.makeFirstResponder(input.textView)
    let tv = input.textView

    // Structural guard: the field's undo manager is NOT the window's shared one.
    try uiExpect(tv.undoManager != nil, "todo input should expose an undo manager")
    try uiExpect(tv.undoManager !== window.undoManager,
                 "todo input undo must be scoped to the field, not the window's shared manager")

    // Behavioral: typing registers undo in the field's manager only, and undo restores it.
    tv.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
    tv.breakUndoCoalescing()                                     // finalize the typing group
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) // close the per-event undo group
    try uiExpect(tv.string == "hello", "sanity: text was inserted")
    try uiExpect(tv.undoManager?.canUndo == true, "the field's manager recorded the edit")
    try uiExpect(window.undoManager?.canUndo == false, "the edit must not leak into the window's manager")
    tv.undoManager?.undo()
    try uiExpect(tv.string.isEmpty, "in-field undo restores the text (composing-undo still works)")
}
```

This pins both axes of the fix and is red before / green after on each:

- **Crash prevention (structural + leak):** before the fix the in-window text view
  resolves `undoManager` to `window.undoManager`, so `tv.undoManager !== window.undoManager`
  fails *and* the insert leaks into the window manager (`window.undoManager?.canUndo`
  becomes `true`). After the fix both hold.
- **Preserved behavior:** typing then `undo()` restores the field, proving
  composing-undo still works through the scoped manager.

Undo-grouping wrinkle: `NSUndoManager.groupsByEvent` is true by default, so the
typing group only closes at a run-loop boundary. The test uses
`breakUndoCoalescing()` plus a brief `RunLoop` spin to close it deterministically;
confirm the minimal incantation that makes `canUndo`/`undo()` fire by running
`just test-ui` during implementation, and drop whichever proves unnecessary.

## Verification

1. **Regression test:** `just test-ui` (needs a logged-in GUI session; runs fine
   from the mac shell). Expect the new `todo input scopes undo...` test to pass and
   the suite to report all-green.
2. **Manual end-to-end repro of the original crash:** `just build-run` to launch the
   dev app, then: open a tab todo popover -> type a few characters -> dismiss with
   Escape (do **not** press Enter) -> press Cmd-Z. Before the fix this crashes; after,
   it is a no-op. Repeat for the pane-level todo popover.
3. **Full local gate:** `just test` (protocol + core + support + lint) to confirm no
   regressions; the production change is confined to `TodoInputView.swift`.

The fix ships to users with the next release (release commands are user-gated; not
part of this change).

## Implementation notes

- `test-ui.sh` already needed `AgentSession.swift` in its manual source list before
  the new regression could compile, so the implementation includes that test-harness
  source-list fix even though the plan expected no harness plumbing changes.
- Direct `insertText` made the edit immediately undoable in the UI harness, so the
  regression test dropped both `breakUndoCoalescing()` and the run-loop spin from
  the plan sketch.
