# Plan: Extract a shared confirmation-dialog helper in AppRuntime

## Context

`AppRuntime.perform(_:)` has three near-identical NSAlert confirm/cancel blocks:

- `showCloseTabConfirmation` -- `app/AppRuntime.swift:509-528`
- `showCloseTabsConfirmation` -- `app/AppRuntime.swift:530-550`
- `showClosePaneConfirmation` -- `app/AppRuntime.swift:704-720`

Each builds a two-button `NSAlert`, branches on `if let window` (sheet) vs.
`runModal()` (modal), and maps `response == .alertFirstButtonReturn` to a
"confirm" outcome. That `.alertFirstButtonReturn` check is copy-pasted **5
times** (`521, 526, 543, 548, 714`). Each copy is an independent chance to
desync the confirm/cancel mapping.

The desync risk is real, not cosmetic: per the codec doc comment at
`lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift:594-595`, the two
close-tab arms must dispatch a `Msg` on **both** confirm *and* cancel so the
pure core can clear its pending-confirmation state. Cancel maps to
`.cancelCloseTab(s)`, not a no-op.

**Why this is a pivot, not the finding's proposed fix.** The originating
finding proposed `runConfirmation(_:onConfirm:)` -- an *onConfirm-only*
callback. That signature silently drops the cancel branch the two close-tab
arms depend on, re-creating the exact desync it set out to remove. The correct
seam is a single `onResponse: (Bool) -> Void` completion (the Bool is
`isConfirm`) that fires for **both** outcomes. That unifies all three arms and
collapses the 5 mapping copies into 1.

Intended outcome: one private helper owns the sheet-vs-modal split and the
response->Bool mapping; the three call sites shrink to a description (titles +
copy + style) plus a `(Bool) -> Void` action.

## Approach

### 1. Add the private helper

`AppRuntime` is `@MainActor class AppRuntime` (`app/AppRuntime.swift:10-11`);
`send(_ msg: Msg)` is at `:231`; `weak var window: NSWindow?` is at `:35`.
Place the helper next to the existing private alert helper `showImportError`
(`app/AppRuntime.swift:1285-1290`).

```swift
/// Run a two-button confirm/cancel alert and report the user's choice as a
/// single Bool (true == confirm button). Centralizes the sheet-vs-modal split
/// and the `response == .alertFirstButtonReturn` mapping so the close-tab,
/// close-tabs, and close-pane arms can't desync those branches independently.
/// `onResponse` fires for BOTH outcomes: the close-tab/close-tabs callers rely
/// on the cancel call to dispatch the Msg that clears pending-confirmation
/// state (see closeTabConfirmationResponse in ModelOperations).
private func runConfirmation(
    messageText: String,
    informativeText: String,
    confirmTitle: String,
    onResponse: @escaping (Bool) -> Void
) {
    let alert = NSAlert()
    alert.messageText = messageText
    alert.informativeText = informativeText
    alert.addButton(withTitle: confirmTitle)
    alert.addButton(withTitle: "Cancel")
    alert.alertStyle = .warning  // every close-confirmation is destructive; also NSAlert's default
    if let window = window {
        alert.beginSheetModal(for: window) { response in
            onResponse(response == .alertFirstButtonReturn)
        }
    } else {
        onResponse(alert.runModal() == .alertFirstButtonReturn)
    }
}
```

Notes:
- Alert style is hardcoded to `.warning`, not parametrized. `NSAlert`'s
  documented default `alertStyle` is already `.warning`, so the two tab arms
  (which never set it -- `app/AppRuntime.swift:509`, `:530`) and the pane arm
  (which sets it explicitly -- `:711`) are *all* warning-style today.
  Hardcoding therefore changes nothing, and there is no style variation across
  the three call sites worth a parameter. Add a `style` parameter only if a
  future non-destructive confirmation actually needs a different style. (This
  corrects an earlier draft that defaulted the helper to `.informational`, which
  would have silently downgraded both tab dialogs.)
- The "Cancel" second button is constant across all three, so it's hardcoded.

### 2. Rewrite the three call sites

Each caller closure uses `[weak self]` -- it escapes via `beginSheetModal`, so
this matches the project's object-lifetime rule (see
`docs/design/2026-06-09-appkit-lifetime-safety.md`). The synchronous modal path
calls `onResponse` before the helper returns, so `[weak self]` is harmless
there. This preserves the original `[weak self]` semantics of the sheet paths.

`showCloseTabConfirmation`:
```swift
case .showCloseTabConfirmation(let tabId, let tabTitle, let paneCount, let isLastTab, let uncompletedTodoCount):
    runConfirmation(
        messageText: "Close tab \"\(tabTitle)\"?",
        informativeText: closeTabConfirmationCopy(paneCount: paneCount, uncompletedTodoCount: uncompletedTodoCount, isLastTab: isLastTab),
        confirmTitle: "Close Tab"
    ) { [weak self] isConfirm in
        self?.send(closeTabConfirmationResponse(isConfirm: isConfirm, tabId: tabId))
    }
```

`showCloseTabsConfirmation`:
```swift
case .showCloseTabsConfirmation(let tabIds, let tabCount, let totalPaneCount, let totalUncompletedTodos, let isQuit):
    runConfirmation(
        messageText: isQuit ? "Close \(tabCount) tabs and quit DanTerm?" : "Close \(tabCount) tabs?",
        informativeText: closeTabsConfirmationCopy(tabCount: tabCount, totalPaneCount: totalPaneCount, totalUncompletedTodos: totalUncompletedTodos, isQuit: isQuit),
        confirmTitle: "Close \(tabCount) Tabs"
    ) { [weak self] isConfirm in
        self?.send(closeTabsConfirmationResponse(isConfirm: isConfirm, ids: tabIds))
    }
```

`showClosePaneConfirmation`:
```swift
case .showClosePaneConfirmation(let paneId, let uncompletedCount):
    let tasks = uncompletedCount == 1 ? "1 uncompleted task" : "\(uncompletedCount) uncompleted tasks"
    runConfirmation(
        messageText: "Close pane?",
        informativeText: "This pane has \(tasks).",
        confirmTitle: "Close Pane"
    ) { [weak self] isConfirm in
        guard isConfirm, let surface = self?.surfaces[paneId]?.surface else { return }
        ghostty_surface_request_close(surface)
    }
```

### Intentional behavior change (window == nil + pane)

Today `showClosePaneConfirmation` has **no modal fallback** -- when `window`
is nil it silently does nothing and the pane never closes
(`app/AppRuntime.swift:712-720`, no `else`). Routing it through the shared
helper gives it the same `runModal()` fallback as the tab arms. This is
strictly more correct and removes an asymmetry; the edge is effectively
unreachable (a live pane implies a window). Adopting the fallback is the
recommendation. If strict preservation is preferred instead, the alternative is
a `fallbackToModal: Bool = true` parameter the pane site sets to `false` -- not
recommended, since it re-introduces the asymmetry the refactor is removing.

## Files

- `app/AppRuntime.swift` -- add `runConfirmation` near `showImportError`
  (~`:1285`); rewrite the three `case` arms.
- `lib/DanTermCore/Tests/DanTermCoreTests/UpdateLifecycleTests.swift` -- add the
  two batch-codec tests described in Tests below.

Reused as-is (not modified):
- `closeTabConfirmationCopy` (`app/AppRuntime.swift:1465`),
  `closeTabsConfirmationCopy` (`lib/.../ModelOperations.swift:608`)
- `closeTabConfirmationResponse` / `closeTabsConfirmationResponse`
  (`lib/.../ModelOperations.swift:596`, `:602`)

## Tests

No test for the three `perform(_:)` arms themselves -- they live in the
AppKit-bound interpreter with no unit-test seam (the `just test-ui` harness
covers split geometry, sidebar badges, and todo-input sizing, not these
dialogs), and a test asserting "the helper got the right titles" would be
structure-sensitive, which the project's bar rejects.

The behavioral contract that actually matters -- cancel still produces
`.cancelCloseTab(s)` and confirm still produces `.confirmCloseTab(s)` -- is the
pure codec mapping in `ModelOperations.swift:596-604`. Coverage there is
currently uneven:

- `closeTabConfirmationResponse` (single tab) is already pinned by
  `UpdateLifecycleTests` (`:519-552`, confirm + cancel).
- `closeTabsConfirmationResponse` (batch) is **unpinned** -- it appears only in
  source and runtime, never in a test. This is a pre-existing gap that the
  refactor's safety-net argument leans on, so close it.

Add two spec-first tests to `UpdateLifecycleTests.swift`, mirroring the existing
single-tab pair's idiom (`@Test` title, `if case` destructure, `Issue.record`
on the else branch -- see `:519-552`):

- `closeTabsConfirmationResponse(isConfirm: true, ids:)` returns
  `.confirmCloseTabs(ids:)` carrying the same id array.
- `closeTabsConfirmationResponse(isConfirm: false, ids:)` returns
  `.cancelCloseTabs`.

This refactor does not touch the codecs, so once both are pinned the coverage
stays green and guards the confirm/cancel desync risk at its source.

## Verification

1. `just build` -- must compile (closure capture / `NSAlert.Style` types).
2. `just test` -- core + protocol + support + purity lint stay green, including
   the two new `closeTabsConfirmationResponse` codec tests.
3. Manual smoke in `just build-run`:
   - Close a tab with multiple panes and/or unfinished todos -> sheet appears
     with correct copy; **Cancel** leaves the tab open; **Close Tab** closes it.
   - Close-all / Quit with multiple tabs -> "Close N tabs..." sheet; Cancel and
     confirm both behave; confirm-on-quit terminates.
   - Close a pane that has uncompleted todos -> `.warning` sheet; Cancel keeps
     the pane; Close Pane closes it.
