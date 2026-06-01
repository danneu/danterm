# Add `tab close` to the DanTerm CLI

## Context

The `danterm` CLI can create (`tab new`) and rename (`tab rename`) tabs, but it
cannot close one. Agents and scripts that open tabs for transient work (run a
build, launch a verifier, etc.) currently have no programmatic way to clean them
up. This adds `danterm tab close [--tab <tab-id>]`, closing the gap and matching
the existing tab command surface.

The change reuses the model's existing tab-close path end to end, so we add no
new close/cleanup logic -- only the CLI parser entry, the IPC method handler,
docs, and tests.

### Design decisions

- **Reuse `.closeTab`.** The existing `.closeTab` Msg (`Update.swift`) already
  handles fallback selection, per-pane alert/search/notification/todo-popover
  cleanup, empty-group pruning, and checkpoint scheduling via `closeTabBody`.
  The CLI routes through it rather than reimplementing removal.
- **Route through `.closeTab`, not `.requestCloseTab`.** `.requestCloseTab` pops
  a GUI confirmation sheet for multi-pane / uncompleted-todo tabs. A CLI request
  cannot drive a GUI dialog, and every other CLI mutation is dialog-free, so the
  CLI dispatches `.closeTab` directly (closes immediately, no prompt).
- **Refuse to close the last remaining tab** (user-confirmed). Closing the only
  tab is what quits the app, and that path is intentionally gated behind a quit
  confirmation. Routing the last tab through `.closeTab` would hit
  `wouldQuitFromClose` -> `emitTerminateConfirmation`, which sets
  `model.pendingConfirmation = .terminate`, returns no commands (the tab is *not*
  closed), and leaves a stuck pending-confirmation that blocks future
  close/quit dialogs. So the handler guards on `wouldQuitFromClose(model)`
  *before* mutating and returns an IPC error (`-32602`,
  "cannot close the last tab"). The app keeps running; every non-last tab closes
  normally.
- **Targeting mirrors `tab rename`:** optional `--tab <tab-id>`, falling back to
  the `$DANTERM_PANE` context tab. Reuses `resolveIpcTabId` verbatim.
- **Output mode `.none`** (like `tab rename`): prints nothing, exits 0 on
  success. The IPC reply still carries the closed tab id for the round-trip and
  for test assertions.
- **Single tab only** (mirrors rename). Batch close (`requestCloseTabs`) is a
  possible future extension, intentionally out of scope.

## Implementation

### 1. Method constant
`lib/DanTermProtocol/Sources/DanTermProtocol/Methods.swift` -- add next to
`tabRename`:

```swift
public static let tabClose = "tab.close"
```

### 2. CLI parser
`lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift`:

- In the `case "tab":` switch (~line 43), add `case "close":` and widen the
  fallback usage string to `danterm tab <new|rename|close>`:

  ```swift
  case "close":
      return try parseTabCloseCommand(Array(args.dropFirst(2)))
  ```

- Add `parseTabCloseCommand` beside `parseTabRenameCommand` (~line 126),
  mirroring its `--tab` handling:

  ```swift
  private func parseTabCloseCommand(_ args: [String]) throws -> CLICommand {
      let usage = "usage: danterm tab close [--tab <tab-id>]"
      var remaining = args
      var params: [String: JSONValue] = [:]
      if remaining.first == "--tab" {
          guard remaining.count >= 2 else { throw CLIParseError(usage) }
          params["tab"] = .string(remaining[1])
          remaining.removeFirst(2)
      }
      guard remaining.isEmpty else {
          if remaining[0].hasPrefix("--") { throw CLIParseError("unknown flag: \(remaining[0])") }
          throw CLIParseError("unexpected argument: \(remaining[0])")
      }
      return CLICommand(method: Methods.tabClose, params: params, outputMode: .none)
  }
  ```

### 3. IPC handler (model/update)
`lib/DanTermCore/Sources/DanTermCore/Update.swift` -- add `case Methods.tabClose:`
adjacent to `Methods.tabRename` (~line 1496):

```swift
case Methods.tabClose:
    let tabId: TabId
    do {
        tabId = try resolveIpcTabId(params: params, context: context, in: model)
    } catch let error as IpcParamsError {
        return ipcInvalidParams(reqId, error.message)
    } catch {
        return ipcInvalidParams(reqId, "invalid tab")
    }
    // Refuse the last tab: routing it through .closeTab would set a terminate
    // confirmation, leave the tab open, and strand pendingConfirmation. The CLI
    // never quits the app as a side effect of closing a tab.
    if wouldQuitFromClose(model) {
        return ipcInvalidParams(reqId, "cannot close the last tab")
    }
    let commands = update(&model, .closeTab(id: tabId), env: env)
    return commands + [.ipcReply(reqId: reqId, result:
        .object(["tab": .object(["id": .string(tabId.rawValue.uuidString)])]))]
```

Reuses existing helpers: `resolveIpcTabId` (explicit `--tab` or context fallback,
already validates the tab exists), `wouldQuitFromClose` /`totalTabCount`
(`ModelOperations.swift`), `ipcInvalidParams`. The reply id is captured before
the mutation, so it is valid after the tab is removed. (Optionally factor the
reply object into a `tabCloseResult(_:)` helper mirroring `tabRenameResult`.)

### 4. CLI help text
`cli/main.swift` -- add a line to `usageText` (~line 33) after the `tab rename`
line:

```
  tab close [--tab <tab-id>]
```

### 5. Docs (`integrations/danterm/SKILL.md`) -- required when the CLI surface changes
- **YAML front-matter `description`** (line 4): add closing a tab to the trigger
  phrases (e.g. "rename or close this tab"). This `description` drives skill
  discovery; without it, the body would document `tab close` but a "close this
  tab" request would not reliably trigger the danterm skill.
- **CLI API list** (~line 21): add `danterm tab close [--tab <tab-id>]` after the
  `tab rename` line.
- **Targeting rule -> "For agent commands"** (~line 77): add a `tab close` bullet
  -- "always pass `--tab <tab-id>`."
- **"When to reach for this skill" table** (~line 118): add a row
  -- `"close this tab" / "close tab X"` -> `tab close --tab <tab-id>`.
- **Recipes** (after the rename recipe, ~line 133): add a "Close a tab"
  subsection, e.g. `danterm tab close --tab "$TAB_ID"`, noting that closing the
  only remaining tab is refused (to avoid quitting the app).
- **Do NOT add a row to the "CLI stdout shapes" table.** That table lists only
  commands that print to stdout; `tab close` is `.none` (like `tab rename`, which
  is also absent), and the table's preamble already covers "everything else
  prints nothing on success and exits 0."

## Tests (TDD: write failing first, confirm the failure reason, then implement)

### Parser -- `lib/DanTermProtocol/Tests/DanTermProtocolTests/CLIParserTests.swift` (XCTest)
- `testTabCloseParsesExplicitTab`: `parseCLI(["tab","close","--tab","T1"])` ->
  method `Methods.tabClose`, `params["tab"] == .string("T1")`, `outputMode == .none`.
- `testTabCloseWithoutTabHasNoTabParam`: `parseCLI(["tab","close"])` -> method
  `tabClose`, `params["tab"] == nil` (context fallback at runtime).
- Extend the existing error-cases table (~line 289) with:
  `(["tab","close","--tab"], "usage: danterm tab close [--tab <tab-id>]")`,
  `(["tab","close","bogus"], "unexpected argument: bogus")`,
  `(["tab","close","--nope"], "unknown flag: --nope")`.

### Core IPC -- `lib/DanTermCore/Tests/DanTermCoreTests/UpdateIpcTests.swift` (Swift Testing)
Use the existing helpers `sendIpc`, `requireIpcReply`, `requireIpcError`,
`makeModel`, `createTab`, `contextForSelectedPane`, `selectedTab`, `tabById`.
Each test gets the 3-section preamble (Intent / Why it exists / Scenario).

- `tabCloseRemovesExplicitTab`: with >1 tab, close one by explicit `tab` param;
  assert reply `["tab"]?["id"]` == closed id, `tabById(id) == nil`, total tab
  count decremented by 1.
- `tabCloseDerivesTabFromPaneContext`: no explicit `tab`, pane context set
  (mirror `tabRenameDerivesLiveTabFromPaneContext`); assert the context's tab is
  removed.
- `tabCloseSelectsFallbackWhenClosingSelected`: closing the selected tab moves
  `model.selectedTabId` to a sibling -- pins the reuse of `closeTabBody`'s
  fallback-selection.
- `tabCloseBypassesConfirmationForMultiPaneTab` (pins the "route through
  `.closeTab`, not `.requestCloseTab`" decision -- the one contract that single-
  pane tests can't catch): build a *non-last* tab with >1 pane (split its pane
  via a `.splitPane` update or a `Methods.paneSplit` IPC), then `Methods.tabClose`
  it. Assert the tab is removed (`tabById == nil`), `model.pendingConfirmation
  == nil`, and no `.showCloseTabConfirmation` command is emitted -- i.e. the CLI
  closes immediately instead of stranding a GUI confirmation. (The same contract
  could be pinned for an uncompleted-todo single-pane tab via the todo-rollup
  branch; one multi-pane test is the minimum.)
- `tabCloseRefusesLastTab` (regression-style; name the stuck-confirmation risk in
  the preamble): single-tab model; assert `requireIpcError` code `-32602`, the
  tab is still present, and `model.pendingConfirmation == nil` (proves we guard
  before the `.closeTab` path and never strand a terminate confirmation).
- `tabCloseMalformedOrUnknownExplicitTab`: bogus / unknown-uuid / non-string
  `tab` value -> `-32602`, no mutation (mirror the rename no-fallback test).
- `tabCloseWithoutTabAndWithoutContextFails`: neither explicit `tab` nor context
  -> `-32602`, no mutation (mirror the rename no-target test).

### Integration smoke -- `scripts/tests/danterm-cli_test.sh`
Two additions:

- **Help-line coverage** (~line 42): add `grep -qF 'tab close [--tab <tab-id>]'`
  to both the bare-usage (stderr) and explicit-help (stdout) assertion blocks,
  alongside the existing per-command checks. Without this, the impl could wire
  the parser/IPC but forget the `danterm help` line and the smoke test would
  still pass.
- **Behavioral check** (live-app section, after the existing `tab new` /
  `tab rename` checks): create a throwaway tab, `tab close --tab <id>`, then
  assert via `ls` + `jq` that the tab id no longer appears:

```bash
close_id="$("$CLI_PATH" tab new --group "$group_id" --title close-test | jq -r '.tab.id')"
"$CLI_PATH" tab close --tab "$close_id"
"$CLI_PATH" ls | jq -e --arg t "$close_id" '[.groups[].tabs[] | select(.id == $t)] | length == 0' >/dev/null
```

## Verification

1. **Unit/gate:** `just test` (runs protocol XCTest + core Swift Testing +
   DanTermSupport + core-purity lint + shell self-tests). Targeted while
   iterating:
   - `swift test --package-path lib/DanTermProtocol --filter DanTermProtocolTests`
   - `swift test --package-path lib/DanTermCore --filter UpdateIpcTests`
2. **End-to-end in the running app:** `just build-run`, then from any shell:
   - `danterm ls` to grab a tab id; `danterm tab close --tab <id>` -> the tab
     disappears from `ls` and the UI; closing the *selected* tab moves selection
     to a sibling.
   - Closing a multi-pane tab via CLI closes it with no GUI prompt.
   - `danterm tab close --tab <last-remaining-id>` prints
     `danterm: cannot close the last tab` to stderr, exits non-zero, app stays up.
   - `danterm tab close` with no `--tab` from inside a DanTerm pane closes that
     pane's tab (context fallback).
3. **Smoke script:** `bash scripts/tests/danterm-cli_test.sh` (needs the dev app).
