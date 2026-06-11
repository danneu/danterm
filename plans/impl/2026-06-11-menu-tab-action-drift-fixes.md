# Menubar/sidebar tab-menu drift fixes: enablement bug, ackTabAlerts retirement, Clear Custom Title parity

## Context

A drift audit of the duplicated tab/group action surfaces (menubar in
`app/AppDelegate.swift` vs sidebar context menus in `app/SidebarView.swift`),
motivated by the pane context-menu unification (8da7613), found one real bug
and two alignment gaps:

1. **Enablement bug**: `contextMenu(for group:)` sets
   `deleteItem.isEnabled = (groups.count > 1)` (SidebarView.swift:769), but the
   menu keeps the default `autoenablesItems = true` and SidebarView doesn't
   conform to `NSMenuItemValidation`, so AppKit's `update()` re-enables the item
   (target responds to the selector). With one group, "Delete Group" shows
   enabled and clicking it silently no-ops. The unified pane menu already
   guards against this (`app/PaneWrapperView.swift:427`).
2. **Duplicate Msg**: `.ackTabAlerts` (Msg.swift:112, Update.swift:937-943) is
   byte-for-byte `.clearAlertsForTabs(tabIds: [selectedTabId])`
   (Update.swift:445). Its only caller is the menubar "Clear Tab Alerts"
   (Cmd-.). No IPC/CLI/keybinding surface exists (verified across
   DanTermProtocol, integrations/, DanTermConfig).
3. **Parity gap**: "Clear Custom Title" exists only in the sidebar context
   menu; the menubar has Rename Tab but no way to clear a custom title.

**User decision**: all batch-capable menubar tab actions adopt one target
rule -- the sidebar multi-selection with fallback to the selected tab (the rule
`currentColorTargetTabIds()` already implements, AppDelegate.swift:505-511).
This is a deliberate behavior change for Cmd-. (now clears alerts across the
multi-selection).

## Staging discipline

The tracked tree is clean (the rename-recycle WIP landed as 461d842), but the
working tree carries many untracked plan/notes files (`plans/`, `research/`,
`self-notes/`, `TODO.md`, ...). Stage explicit paths only; never `git add -A`.

## Changes

### 1. Sidebar context-menu auto-enablement (the bug fix)

`app/SidebarView.swift`:
- Set `menu.autoenablesItems = false` in `contextMenu(for group:)` (~752) and
  `contextMenu(forTab:clickedRow:)` (~848), and on the `colorSubmenu` (~883)
  for drift-proofing (submenus are separate NSMenus; parent setting doesn't
  cover them).

**TDD**: new `tests-ui/SidebarContextMenuTests.swift` written and verified
failing BEFORE the fix:
- Harness: copy the pattern from `tests-ui/SidebarRenameRecycleTests.swift`
  (~line 173): build `SidebarView`, feed a model via
  `applySidebarOps(computeSidebarRowOps(...), model:, clearActiveRename:)`
  (sets the private `currentModel` the builders read).
- Test A: model with 1 group -> `sidebar.contextMenu(for: group)` ->
  `menu.update()` (triggers autovalidation; documented to work on detached
  menus) -> assert the "Delete Group" item is disabled. Fails pre-fix
  (autovalidation re-enables it), passes post-fix.
- Test B: 2 groups -> same flow -> assert "Delete Group" enabled.
- Menu-assertion helpers: copy `nonSeparatorItems`/`onlyItem` from
  `tests-ui/PaneWrapperViewTests.swift:231-239`.
- Register in `test-ui.sh` build list and the runner in
  `tests-ui/PaneSplitViewTests.swift`.
- Test A is a bug-fix test: give it the Intent / Why it exists / Scenario
  preamble, naming the drift-audit incident. New file gets the line-1 `//`
  file-header block per AGENTS.md.

### 2. Retire `.ackTabAlerts`

Order matters (port coverage before deleting):
1. **Port the only non-duplicated scenario**: the existing `clearAlertsForTabs`
   tests (UpdateAlertTests.swift:1206-1380) all use single-pane tabs; only
   `testAckTabAlertsClearsAllPaneAlertsInTab` (line 1133) covers a multi-pane
   tab. Add a `clearAlertsForTabs` test for a split tab where every pane has
   unread alerts (keep `model.config.alertClearMode = .manual` from the ack
   test -- splitting refocuses panes and auto-clear would mask the assertion).
   Verify it passes, then delete the three ack tests (lines ~1131-1206).
2. Delete `case ackTabAlerts` (Msg.swift:112) and its handler
   (Update.swift:937-943). Only `update()` switches exhaustively over Msg;
   `coalescesReconcile` has a `default:` -- no other breakage.
3. `app/AppDelegate.swift`: rename handler `ackTabAlerts` -> `clearTabAlerts`
   (both the method ~628 and the `#selector` at the menu item ~376); body
   routes through `menubarTabActionMsg(.clearAlerts, ...)` (Change 3). Not in
   `MenuCommandPolicy.windowIndependentActions`, so no allowlist edit.

### 3. One menubar target rule (core router) + Tab > Clear Custom Title

The menubar batch wiring gets a pure, unit-tested router in core so the
target rule and Msg construction are asserted, not just glued (the planned
reducer tests alone would pass even if Cmd-. kept clearing only the selected
tab or Clear Custom Title were wired to the wrong target).

`lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift` (next to its
siblings `resolveContextTargets` / `resolveColorForBatch`, ~1133-1181):

```swift
/// Batch-capable menubar tab actions. One enum so every menubar entry
/// point shares the same target rule and Msg construction.
enum MenubarTabAction {
    case setColor(TabColor), clearColor, clearCustomTitles, clearAlerts
}

/// Menubar batch-target rule: act on the sidebar multi-selection,
/// falling back to the selected tab; nil when there is no target.
/// setColor threads resolveColorForBatch (toggle-off policy).
func menubarTabActionMsg(
    _ action: MenubarTabAction,
    sidebarSelection: [TabId],
    in model: AppModel
) -> Msg?
```

- targets = `sidebarSelection` if non-empty, else `[model.selectedTabId]`,
  else return nil.
- `.setColor(c)` -> `.setTabColors(targets, resolveColorForBatch(...))`;
  `.clearColor` -> `.setTabColors(targets, nil)`;
  `.clearCustomTitles` -> `.clearCustomTitles(targets)`;
  `.clearAlerts` -> `.clearAlertsForTabs(targets)`.

**TDD**: new core Swift Testing suite (e.g.
`lib/DanTermCore/Tests/DanTermCoreTests/MenubarTabActionTests.swift`, or
alongside the existing resolveColorForBatch tests if a suite already covers
that file) written failing-first, asserting per action: multi-selection
passthrough (correct Msg case + ids), empty-selection fallback to
`model.selectedTabId`, nil when no selection and no selected tab, and that
`.setColor` toggle-off matches `resolveColorForBatch` (all-targets-share ->
clears). Runs headless in the `just test` gate -- no UI-harness involvement.

`app/AppDelegate.swift`:
- `setTabColorFromMenu` (~485), `clearTabColor` (~495), the renamed
  `clearTabAlerts`, and the new `clearCustomTitle` handler all become thin:
  `if let msg = menubarTabActionMsg(<action>, sidebarSelection:
  sidebarView?.selectedTabIds() ?? [], in: runtime.model) { runtime.send(msg) }`.
  This dissolves `currentColorTargetTabIds()` (~505-511) -- the fallback rule
  moves into the router; delete the helper.
- New menu item "Clear Custom Title" in the Tab menu directly after "Rename
  Tab" (~283), no key equivalent, action `clearCustomTitle(_:)`. Always
  enabled (consistent with every other window-scoped menubar item;
  `validateMenuItem` gates only on window liveness; core handler is
  model-idempotent).
- Move "Clear Tab Alerts" (Cmd-., currently Pane menu ~376) to the Tab menu
  after the Color submenu: under the multi-selection rule it's a tab-batch
  action like Color, and leaving it next to "Clear Pane Alerts" would be
  misleading. "Clear Pane Alerts" (Cmd-Shift-.) stays in the Pane menu.

`app/SidebarView.swift`:
- Update the stale doc on `selectedTabIds()` (~782: "Used by AppDelegate's
  tab-color shortcuts") to say it feeds the menubar batch router
  (`menubarTabActionMsg`).

Reducer behavior is already covered (`.clearCustomTitles`:
CustomTitleTests.swift:602-688; `.clearAlertsForTabs`:
UpdateAlertTests.swift:1206-1380). No CLI surface change, so
`integrations/danterm/SKILL.md` is untouched.

## Files touched

- `app/SidebarView.swift` -- autoenablesItems x3, doc comment
- `app/AppDelegate.swift` -- handlers routed through menubarTabActionMsg
  (deletes currentColorTargetTabIds), new Clear Custom Title item + handler,
  clearTabAlerts rename + retarget, menu item move
- `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift` -- NEW
  MenubarTabAction + menubarTabActionMsg router
- `lib/DanTermCore/Sources/DanTermCore/Msg.swift` -- delete ackTabAlerts case
- `lib/DanTermCore/Sources/DanTermCore/Update.swift` -- delete handler
- `lib/DanTermCore/Tests/DanTermCoreTests/MenubarTabActionTests.swift` -- NEW
  router suite
- `lib/DanTermCore/Tests/DanTermCoreTests/UpdateAlertTests.swift` -- port
  multi-pane test, delete 3 ack tests
- `tests-ui/SidebarContextMenuTests.swift` -- NEW
- `test-ui.sh`, `tests-ui/PaneSplitViewTests.swift` -- register new test file

## Verification

1. TDD checkpoints during implementation:
   - SidebarContextMenuTests Test A fails (Delete Group wrongly enabled)
     before the `autoenablesItems` fix; passes after.
   - MenubarTabActionTests written failing-first (router doesn't exist yet),
     pass once `menubarTabActionMsg` lands, BEFORE rewiring AppDelegate.
   - Ported multi-pane `clearAlertsForTabs` test passes BEFORE deleting the
     ack tests.
2. `just test` -- core suite (including UpdateAlertTests, CustomTitleTests),
   protocol tests, purity lint, shell self-tests.
3. `just test-ui` -- full UI harness including the new SidebarContextMenuTests
   (needs a GUI session; works from an agent shell).
4. Manual smoke (optional): `just build-run`; right-click a group with only
   one group present -> Delete Group greyed out; select 2 tabs in the sidebar
   -> Tab > Clear Custom Title clears both; Cmd-. clears alerts on both.

## Commit message

```
fix(menu): repair sidebar enablement and align menubar tab actions

Drift-audit follow-up to the pane context-menu unification (8da7613):

- Sidebar context menus now set autoenablesItems = false so the manual
  Delete Group enablement (single-group guard) sticks; AppKit
  autovalidation was re-enabling it, leaving a silently no-op item.
- Retire .ackTabAlerts: it duplicated .clearAlertsForTabs for the
  selected tab. The menubar item now sends .clearAlertsForTabs and
  moves to the Tab menu, since it acts on tabs, not panes.
- Add Tab > Clear Custom Title (parity with the sidebar context menu).
- One menubar batch-target rule: sidebar multi-selection with
  selected-tab fallback, now a pure unit-tested core router
  (menubarTabActionMsg) shared by the Color, Clear Custom Title, and
  Clear Tab Alerts handlers. Behavior change: Cmd-. now clears alerts
  across the multi-selection, matching the Color submenu.
```
