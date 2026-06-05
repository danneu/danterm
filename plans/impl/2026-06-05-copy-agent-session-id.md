# Plan: "Copy Agent Session ID" in the pane context menu

## Context

Commit `75e7c8a` simplified the toolbar agent-session chip to show only a
sparkles glyph + a compact, lowercase agent **kind** label
(`AgentSession.toolbarLabel` -- e.g. `claude`, truncated past 6 chars); the full
session id now lives only in the chip's tooltip and the recovery text. That
removed the easy way to grab the id (e.g. to `claude -r <id>` /
`codex resume <id>` from another shell).

This adds a **"Copy Agent Session ID"** row to the pane right-click context menu,
shown only when the pane is currently in an agent session, with the same
`sparkles` glyph as the chip so the association is obvious. It mirrors the
existing "Copy cwd" action exactly -- read a string off the pane model, push it
to the pasteboard.

Scope note: the item is added to `makePaneMenu()` in `PaneWrapperView.swift`,
the **shared builder for both** menu entry points -- the right-click context
menu (`ToolbarDragHandleView.menu(for:)` via `paneMenuProvider`, wired at
`:228`) and the pane toolbar's `...` button (`showPaneMenu()` at `:456`). So the
row appears in both. This is the same menu that already contains "Copy cwd". The
separate menu-bar "Pane" menu in `AppDelegate.swift` is intentionally left
untouched.

## Changes

All edits are in `app/PaneWrapperView.swift`.

### 1. Add the conditional menu item in `makePaneMenu()` (around line 436-441)

Right after the existing `copyCwd` item is added (grouping it with the other
copy action, before the trailing `.separator()`), insert:

```swift
// Only shown when the pane reported an agent session (via the claude/codex hook). The
// toolbar chip now renders just a sparkles glyph + a compact kind label, so the full
// session id is no longer visible there -- this item is its copy affordance.
if runtime?.model.pane(paneId)?.agentSession != nil {
    let copySessionId = NSMenuItem(title: "Copy Agent Session ID", action: #selector(copyAgentSessionIdAction), keyEquivalent: "")
    copySessionId.target = self
    copySessionId.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Agent session")
    menu.addItem(copySessionId)
}
```

`makePaneMenu()` is already documented as building fresh each time so dynamic
state is current, so the `agentSession != nil` check reflects the live model.

### 2. Add the action method (next to `copyCwdAction`, around line 478-482)

```swift
@objc private func copyAgentSessionIdAction() {
    guard let sessionId = runtime?.model.pane(paneId)?.agentSession?.sessionId else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(sessionId, forType: .string)
}
```

## Reused patterns / no new state

- `runtime?.model.pane(paneId)?.agentSession` -- the pane model already holds the
  session (`lib/DanTermCore/Sources/DanTermCore/Model.swift:84`); no need to
  retain the `AgentSession` on the view.
- Action mirrors `copyCwdAction` (`PaneWrapperView.swift:478`) for the
  pasteboard write.
- `sparkles` SF Symbol matches `agentIcon` (`PaneWrapperView.swift:160`).

## Tests

No automated test is added. The change lives entirely in the AppKit `app/`
target (NSMenu construction + NSPasteboard write), which the DanTermCore /
DanTermProtocol / DanTermSupport suites do not cover; the sibling "Copy cwd"
action is likewise untested, and the logic here is trivial passthrough of an
already-tested model field (`AgentSession.sessionId`). The UI harness stubs
`PaneWrapperView` rather than compiling the production file, so a behavior test
would require widening harness scope -- disproportionate for a one-row,
structure-sensitive AppKit addition.

No CLI surface changes, so `integrations/danterm/SKILL.md` is unaffected.

## Verification (manual)

1. `just build-run` to compile and launch `DanTerm Dev.app`. **This is the
   real compile/type/selector check** -- it builds the `app/` target. (`just
   test` does **not** compile `app/`; see step 7.)
2. In a pane **not** in an agent session: right-click the toolbar drag area ->
   confirm there is **no** "Copy Agent Session ID" row (only Split/Copy cwd/
   Zoom/Close).
3. Start an agent session in a pane (run `claude` / `codex` so the session hook
   fires and the indigo sparkles chip appears in that pane's toolbar).
4. Right-click that pane's toolbar -> confirm a "Copy Agent Session ID" row
   appears with the sparkles icon, grouped with "Copy cwd".
5. Open the **same menu via the pane toolbar's `...` button** -> confirm the row
   also appears there (both entry points share `makePaneMenu()`).
6. Click the row, then paste elsewhere -> verify the pasted value equals the full
   session id shown in the chip's tooltip (`<kind> session <id>`), not the
   truncated chip label.
7. Optional broader regression gate: `just test`. Note it runs only the nested
   package suites + lints and does **not** compile the `app/` target, so it is
   not a substitute for step 1's compile check.
