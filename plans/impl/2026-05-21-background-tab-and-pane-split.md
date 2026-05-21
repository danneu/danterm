# `tab new --background` + `pane split --background` (don't steal focus)

## Context

`danterm tab new` and `danterm pane split` both pull focus today:
- `tab new` switches the new tab to selected, defocusing whatever pane
  the user is in.
- `pane split` reassigns the target tab's `focusedPaneId` to the new
  pane (`app/Update.swift:220`) and rebuilds the content view.

That's right for a human typing the command from their own pane, but it
breaks the "agent-owned tab group" pattern: a long-running agent
(e.g. one assigned its own group) should be able to spin up tabs and
split panes in the background while the user works elsewhere, without
being yanked away.

Goal: opt-in `--background` flag on both commands.
- `tab new --background` creates the tab + its surface but leaves
  `model.selectedTabId` alone. Because the new tab is never the
  selected tab, `.rebuildContentView` is always skipped -- the visible
  content area belongs to the user's existing tab and must not be
  disturbed.
- `pane split --background` adds the split + new surface to the target
  tab's tree but leaves the tab's existing `focusedPaneId` alone.
  `.rebuildContentView` gating is conditional: emitted when the split
  targets the currently-selected tab (so the new pane actually
  renders), skipped when it targets a backgrounded tab (so the user's
  popovers and drags survive).
- Neither emits `.makeFirstResponder`, defocuses the user's current
  pane, or changes `model.selectedTabId`.
- Both still create the surface, schedule a checkpoint, reload the
  sidebar where relevant, and apply inherited themes.

Also update the DanTerm agent skill so agents default to `--background`
for autonomous work -- the user may be focused elsewhere.

Two adjacent issues for `tab.new` fall out of review and are folded in
so the agent-safe path is actually agent-safe:

- IPC `tab.new` currently inherits cwd from `currentCwd(in: model)`,
  which reads `model.selectedTabId` (`app/ModelOperations.swift:359`).
  An agent calling `tab.new` from its own pane would inherit the
  *user's* selected-tab cwd, not its own. `pane.split` already does the
  right thing (`app/Update.swift:205` -- `launch?.cwd ?? target pane
  cwd`); `tab.new` should match.
- IPC `background` parsing (for both methods) must reject malformed
  values rather than silently treating them as `false`, matching the
  strict `lines` parsing precedent at `app/Update.swift:1685`.

## Approach

### 1. CLI surface

**`tab new`**

`lib/DanTermProtocol/Sources/DanTermProtocol/TabNewArgs.swift`
- Add `background: Bool` to `ParsedTabNew` (default `false`).
- In `parseTabNewArgs`, add `case "--background"` -> set the flag,
  advance `i += 1` (zero-arg flag).

`lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift`
- In `parseTabNewCommand` (line 84): if `parsed.background`, set
  `params["background"] = .bool(true)`. Omit otherwise so the wire is
  unchanged for existing callers.
- Append `[--background]` to the usage string at line 91.

**`pane split`**

`lib/DanTermProtocol/Sources/DanTermProtocol/PaneSplitArgs.swift`
- Add `background: Bool` to `ParsedPaneSplit` (default `false`).
- In `parsePaneSplitArgs`, add `case "--background"` -> set the flag,
  advance `i += 1`.

`lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift`
- In `parsePaneSplitCommand` (line 151): if `parsed.background`, set
  `params["background"] = .bool(true)`. Omit otherwise.
- Append `[--background]` to the usage string at line 158.

**Help text** -- `cli/main.swift`
- Append `[--background]` to the `tab new` usage line at line 30 and
  the `pane split` usage line at line 37 (manual help text -- kept in
  sync by hand per the comment at line 19-21).

### 2. Msg + Update

`app/Msg.swift`
- Extend `.createTab` (line 44) with `background: Bool = false`:
  ```swift
  case createTab(inGroupId: GroupId?, position: TabInsertPosition = .afterSelected, launch: LaunchSpec? = nil, background: Bool = false)
  ```
- Extend `.splitPane` (line 47) with `background: Bool = false`:
  ```swift
  case splitPane(paneId: PaneId? = nil, direction: SplitNodeModel.Direction, launch: LaunchSpec? = nil, background: Bool = false)
  ```

`app/Update.swift` `case .createTab` (lines 44-106)
- Read `background` from the case pattern. When `background == true`,
  gate four things:
  - Skip the defocus loop (lines 86-90) -- no old-pane focus change.
  - Skip `model.selectedTabId = tabId` (line 92).
  - Skip `selectionSyncEffects(for: model)` (line 103) -- no selection
    change to sync.
  - Skip `.rebuildContentView` (line 101). `rebuildContentView` in
    `app/AppRuntime.swift:1355` removes all content subviews, cancels
    pane drags, and dismisses any open todo popovers -- emitting it
    when nothing visible changed would interrupt the user mid-action.
- Keep `.createSurface`, `.reloadSidebar`, `.scheduleCheckpoint`.

`app/Update.swift` `case .splitPane` (lines 194-239)
- Read `background` from the case pattern. When `background == true`,
  always preserve focused-pane state inside the tab: in the
  `updateTab` block (lines 218-222), set `tab.rootNode = newRoot` and
  `tab.isZoomed = false` as today, but **do not** reassign
  `tab.focusedPaneId`.
- `.rebuildContentView` gating must be conditional on whether the
  target tab is the currently selected tab:
  - If `model.selectedTabId == tab.id` (background split on the
    currently-visible tab), **still emit `.rebuildContentView`**.
    Otherwise the new pane never renders: `rebuildContentView` at
    `app/AppRuntime.swift:1370` only draws the selected tab's
    `rootNode`, and `applySelectTab` at `app/Update.swift:2169`
    no-ops when reselecting the same tab, so the new pane would
    stay invisible until some unrelated rebuild.
  - If `model.selectedTabId != tab.id` (background split into a
    backgrounded tab), skip `.rebuildContentView` -- the user is
    looking at a different tab, and emitting it would dismiss
    their open todo popovers and cancel any pane drag in progress
    (see `AppRuntime.swift:1355-1358`).
- Keep `.createSurface`, `.scheduleCheckpoint`, and the conditional
  `.applyPaneTheme` (lines 236-238) regardless -- the new surface
  still needs to be created, persisted, and themed.
- `case .splitPane` already does not touch `model.selectedTabId` and
  does not emit `.makeFirstResponder` directly -- both are properties
  the background tests will negate-assert (defense-in-depth so a
  future refactor that introduces either silently breaks the
  contract).

Callers of `.createTab` / `.splitPane` that don't pass `background`
get existing behavior via the default value -- no other call sites
need to change (keyboard shortcuts, menu items, drag/drop).

### 3. IPC handler

Both methods need (a) strict `background` parsing and (b) for
`tab.new`, caller-pane cwd inheritance.

**Shared helper.** Add a small helper near the existing param helpers
(e.g. just above `resolveTargetPane` at line 1874) to keep both call
sites identical:
```swift
private func parseOptionalBool(_ value: JSONValue?, name: String) throws -> Bool {
    switch value {
    case .none, .some(.null): return false
    case .some(.bool(let b)): return b
    default: throw IpcParamsError("\(name) must be a boolean")
    }
}
```

**`Methods.tabNew` (lines 1564-1587):** the current handler has two
separate `do` blocks (one for `parseLaunchSpec` catching
`LaunchSpecParseError`, one for `resolveTabNewGroup` catching
`IpcParamsError`). To make `parseOptionalBool` reach an
`IpcParamsError` catch, declare `background` and `groupId` before the
group-resolution `do` and parse `background` inside that same `do`:

```swift
let background: Bool
let groupId: GroupId
do {
    background = try parseOptionalBool(object["background"], name: "background")
    groupId = try resolveTabNewGroup(params: params, context: context, in: model)
} catch let error as IpcParamsError {
    return ipcInvalidParams(reqId, error.message)
} catch {
    return ipcInvalidParams(reqId, "invalid params")
}
```

Then, in order after the `do` block:

a. **Caller-pane cwd inheritance.** Before dispatching `.createTab`,
   if `launch?.cwd == nil` and the request has a usable pane context,
   fill the spec's cwd from the caller's pane (mirroring
   `splitPane`'s line 205 fallback). The caller pane resolver
   `resolveIpcPaneId(context, in: model)` at line 1860 is the right
   primitive. `LaunchSpec` has only `init(cmd:cwd:title:)` (see
   `lib/DanTermProtocol/Sources/DanTermProtocol/LaunchSpec.swift`),
   so build the updated spec by re-constructing it explicitly:
   ```swift
   var effectiveLaunch = launch
   if effectiveLaunch?.cwd == nil,
      let callerPaneId = resolveIpcPaneId(context, in: model),
      let cwd = model.panes[callerPaneId]?.cwd {
       effectiveLaunch = LaunchSpec(
           cmd: effectiveLaunch?.cmd,
           cwd: cwd,
           title: effectiveLaunch?.title
       )
   }
   ```
   This change applies to foreground and background `tab.new` alike --
   the focused-tab leak is a latent bug; making the IPC always prefer
   caller-pane cwd is the right fix and is consistent with
   `pane.split`. Menu-bar / non-IPC tab creation still falls through
   to `currentCwd(in: model)` via the unchanged model path.

b. **Pass through:** `update(&model, .createTab(inGroupId: groupId,
   launch: effectiveLaunch, background: background))`.

`tabNewResult` (line 2024) needs no change.

**`Methods.paneSplit` (lines 1542-1562):** the current handler already
wraps everything in a single `do` block that catches `IpcParamsError`,
so `parseOptionalBool` can be called inline -- no structural change.

a. **Strict `background` parsing.** Inside the existing `do`, alongside
   `parseLaunchSpec` and `resolvePaneSplitTarget`:
   `let background = try parseOptionalBool(object["background"], name: "background")`.

b. **Pass through:** `update(&model, .splitPane(paneId: paneId,
   direction: direction, launch: launch, background: background))`.

`paneResult` is unchanged -- the caller still gets the new pane id.

### 4. Tests

Coverage along the full path so a regression at any layer is caught.
Five test files are touched.

**`lib/DanTermProtocol/Tests/DanTermProtocolTests/TabNewArgsTests.swift`**
- `testBackgroundFlagParses`: `parseTabNewArgs(["--background"])` ->
  `ParsedTabNew(group: nil, launch: nil, background: true)`.
- `testBackgroundCombinesWithOtherFlags`: `--group G1 --background
  --cmd date` parses with all four fields populated. Mirrors
  `testCombinationParses` at line 33.

**`lib/DanTermProtocol/Tests/DanTermProtocolTests/PaneSplitArgsTests.swift`**
- `testBackgroundFlagParses`: `parsePaneSplitArgs(["-h", "--background"])`
  -> `ParsedPaneSplit(pane: nil, direction: .horizontal,
  background: true)`.
- `testBackgroundCombinesWithOtherFlags`: `--pane P1 -h --background
  --cmd 'just test' --cwd /tmp --title tests` parses with all fields
  populated.

**`lib/DanTermProtocol/Tests/DanTermProtocolTests/CLIParserTests.swift`**
- `parseCLI(["tab", "new", "--background"])` -> `CLICommand` with
  `method == Methods.tabNew` and `params["background"] == .bool(true)`.
- `parseCLI(["pane", "split", "-h", "--background"])` -> `CLICommand`
  with `method == Methods.paneSplit` and `params["background"] ==
  .bool(true)`.
- For both: omitting `--background` leaves `params["background"]`
  unset so the wire is unchanged for existing callers.
- Update the existing
  `testMalformedExplicitTargetSyntaxThrowsUsageErrors` cases at
  lines 145 and 148 to match the new usage strings -- append
  `[--background]` to both:
  - `tab new --group` expected message becomes
    `usage: danterm tab new [--group <group-id>] [--cmd <s>] [--cwd <p>] [--title <s>] [--background]`.
  - `pane split --pane` expected message becomes
    `usage: danterm pane split [--pane <pane-id>] -h|-v [--cmd <s>] [--cwd <p>] [--title <s>] [--background]`.
  Keep these strings in sync with the `CLIParseError` messages emitted
  by `parseTabNewCommand` (line 91) and `parsePaneSplitCommand`
  (line 158) -- both are updated in the CLI changes above.

**`tests/TestHarness.swift`**
- Extend the `createTab` helper at line 87:
  ```swift
  func createTab(_ model: inout AppModel, inGroupId: GroupId? = nil, background: Bool = false) -> [Effect] {
      return update(&model, .createTab(inGroupId: inGroupId, background: background))
  }
  ```

**`tests/UpdateTabTests.swift`**
- `testCreateTabBackgroundDoesNotChangeSelection`, mirroring
  `testCreateTabAddsToDefaultGroup` (line 6) and
  `testSelectTabDefocusesOldPanes` (line 40):
  - Create tab A (foreground); record `aTabId`, `aPaneId`.
  - Call `createTab(&model, background: true)`; capture effects.
  - Assert `model.groups[0].tabs.count == 2`.
  - Assert `model.selectedTabId == aTabId` (unchanged).
  - Assert effects contain `.createSurface` for the new pane.
  - Assert effects contain `.reloadSidebar`.
  - Assert effects do NOT contain
    `.focusSurface(paneId: aPaneId, focused: false)`.
  - Assert effects do NOT contain `.rebuildContentView` (would dismiss
    user popovers / cancel drags -- see `AppRuntime.swift:1355`).
- `testCreateTabBackgroundIntoSpecificGroup`, mirroring
  `testCreateTabInSpecificGroup` (line 108): tab lands in the named
  group; selection still doesn't move.

**`tests/UpdatePaneTests.swift`** -- two background cases (selected
target tab vs non-selected target tab) plus a foreground pin.

- `testSplitPaneBackgroundOnSelectedTabRebuildsButPreservesFocus`:
  the user's own tab is the target.
  - Create one tab (becomes selected); record its
    `existingFocusedPaneId`.
  - Call `update(&model, .splitPane(paneId: existingFocusedPaneId,
    direction: .horizontal, background: true))`; capture effects.
  - Assert a new pane was added to the tab's tree (model.panes count
    went up; tree contains a new leaf).
  - Assert the tab's `focusedPaneId == existingFocusedPaneId`
    (unchanged).
  - Assert `model.selectedTabId` unchanged.
  - Assert effects contain `.createSurface`, `.scheduleCheckpoint`,
    and `.rebuildContentView` (required so the new pane actually
    renders -- the selected tab is the target).
  - Assert effects do NOT contain `.makeFirstResponder` for any pane.

- `testSplitPaneBackgroundOnUnselectedTabSkipsRebuild`:
  the target tab is not the one the user is looking at.
  - Create two tabs in the same group. The second tab is selected by
    default. Switch back to the first so tab A is selected.
  - Record tab B's `focusedPaneId` (tab B is not selected).
  - Call `update(&model, .splitPane(paneId: tabB.focusedPaneId,
    direction: .horizontal, background: true))`; capture effects.
  - Assert tab B's tree got the new pane (tree contains a new leaf;
    model.panes count went up).
  - Assert tab B's `focusedPaneId` is unchanged.
  - Assert `model.selectedTabId == tabA.id` (unchanged).
  - Assert effects contain `.createSurface` and `.scheduleCheckpoint`.
  - Assert effects do NOT contain `.rebuildContentView` (would
    dismiss user popovers / cancel drags in tab A -- see
    `AppRuntime.swift:1355-1358`).
  - Assert effects do NOT contain `.makeFirstResponder`.

- `testSplitPaneBackgroundInheritsTheme`: when the target pane has a
  theme, the background split still emits `.applyPaneTheme(paneId:
  newPaneId)`. Asserts we didn't accidentally drop theme propagation.

- `testSplitPaneForegroundStillMovesFocus`: default-foreground
  regression that pins the existing contract -- tab's `focusedPaneId`
  becomes the new pane and `.rebuildContentView` is emitted -- so the
  background gating can't silently degrade it.

**`tests/UpdateIpcTests.swift`**
- `tab.new --background does not steal selection`: full IPC round-trip
  via `sendIpc` (mirrors line 437/501). Set up tab A as selected, send
  `tab.new` with `background: true`, assert `model.selectedTabId`
  unchanged and the reply contains the new tab id.
- `tab.new with malformed background fails before mutation`: send
  `background: "true"` (string), assert `ipcInvalidParams` reply and
  no new panes/tabs created (mirror the malformed-launch test at
  line 639).
- `tab.new inherits cwd from caller pane, not selected tab` (F1
  regression). Create two tabs in different groups with different
  pane cwds; select tab A, then send `tab.new` with `context.paneId
  = B's pane` and no `launch.cwd`. Assert the resulting
  `.createSurface` effect's cwd matches B's pane cwd, not A's. Run
  this with `background: true` and `background: false` -- both should
  pick the caller's cwd; this is intentionally a behavior change for
  foreground IPC callers too.
- `pane.split --background on selected tab preserves focused pane`:
  full IPC round-trip targeting a pane in the currently selected tab.
  Assert the target tab's `focusedPaneId` is unchanged,
  `model.selectedTabId` is unchanged, the reply returns the new pane
  id, and the effect set contains `.rebuildContentView` (the new
  pane needs to render in the visible tab).
- `pane.split --background on unselected tab does not rebuild`: full
  IPC round-trip targeting a pane in a tab that is NOT
  `model.selectedTabId`. Assert the target tab's `focusedPaneId` is
  unchanged, `model.selectedTabId` is unchanged, the reply returns
  the new pane id, and the effect set does NOT contain
  `.rebuildContentView`.
- `pane.split with malformed background fails before mutation`: send
  `background: "true"`, assert `ipcInvalidParams` and no new pane.

### 5. SKILL.md updates

`integrations/danterm/SKILL.md`

- Recipes -- "Open a new tab and optionally run a command in it"
  (lines 90-94): add a `--background` example and a one-line note that
  `--background` keeps the user's current tab focused:
  ```
  danterm tab new --group "$GROUP_ID" --background --cmd 'just test' --title tests
  ```

- Recipes -- "Split a pane and run a command in the new one"
  (lines 100-114): add a `--background` example for splits:
  ```
  danterm pane split --pane "$PANE_ID" -h --background --cmd 'just test' --title tests
  ```
  with a one-line note that `--background` leaves the caller's pane
  focused inside its tab.

- Rules for agents section (lines 201-213): add a bullet:
  > Prefer `--background` on `tab new` and `pane split` for autonomous
  > work the user did not just ask for. The user may be focused on
  > another tab or pane; stealing focus is disruptive. Omit
  > `--background` only when the user explicitly asked you to switch
  > to the new tab/pane.

- Targeting rule section (lines 31-39): update the `tab new` and
  `pane split` bullets to recommend `--background` as the default
  agent posture:
  > - `tab new`: always pass `--group <group-id>`; prefer
  >   `--background` unless the user asked to switch to the new tab.
  > - `pane split`: always pass `--pane <pane-id>`; prefer
  >   `--background` unless the user asked to focus the new pane.

## Verification

1. `just test` -- new tests pass; existing tab/pane tests still pass
   (default `background: false` preserves behavior).
2. `just build-run`, then from a pane inside DanTerm:
   ```
   GROUP_ID=$(danterm pane info --pane "$DANTERM_PANE" | jq -r '.group.id')
   PANE_ID=$(danterm pane info --pane "$DANTERM_PANE" | jq -r '.pane.id')

   # Background tab.
   danterm tab new --group "$GROUP_ID" --background --cmd 'sleep 30' --title bg
   # -> new tab in sidebar; caller's tab still selected and focused.

   # Background split on the caller's tab (selected).
   danterm pane split --pane "$PANE_ID" -h --background --cmd 'sleep 30' --title bg-split
   # -> new pane appears immediately in the caller's tab tree; caller's
   #    pane stays focused (keyboard still types into it).

   # Background split on a non-selected tab.
   # Open a second tab, capture its pane id, then switch back to the
   # caller's tab; split the second tab's pane in the background.
   OTHER_TAB=$(danterm tab new --group "$GROUP_ID" | jq -r '.tab.id')
   OTHER_PANE=$(danterm tab new --group "$GROUP_ID" | jq -r '.panes[0].id')
   # (re-select the caller's tab via the sidebar, then:)
   danterm pane split --pane "$OTHER_PANE" -h --background --cmd 'sleep 30'
   # -> No visible change to the caller's tab (no popover dismissal,
   #    no chrome flicker); switching to the other tab reveals the
   #    new pane.
   ```
3. Cross-check existing defaults still steal focus:
   ```
   danterm tab new --group "$GROUP_ID" --cmd 'sleep 30'
   danterm pane split --pane "$PANE_ID" -h --cmd 'sleep 30'
   ```
4. Manual cwd-inheritance check: from a pane whose shell is `cd`-ed
   into `/tmp`, while a *different* tab is selected, run
   `danterm tab new --group "$GROUP_ID" --background --cmd pwd`; the
   new tab's pane should report `/tmp`, not the selected tab's cwd.
5. Manual malformed-input check: send a raw IPC `tab.new` and
   `pane.split` with `{"background": "true"}` (string) via the socket;
   confirm both reply with `ipcInvalidParams` and no entity is
   created.
6. `danterm help` shows `[--background]` in both the `tab new` and
   `pane split` usage lines.
