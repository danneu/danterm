# IPC API redesign: dotted methods, wrapped responses, launch spec

## Context

DanTerm's IPC surface has accumulated three kinds of historical inconsistency:

1. **Method naming** mixes dotted (`tab.title`, `pane.split`, `theme.set`, `todo.*`) and dashed (`new-tab`, `send-keys`, `read-pane`).
2. **Response shapes** are heterogeneous: `pane.split` returns `{paneId}`, `new-tab` returns `{tabId}`, mutations mostly return `{ok: true}`, `ls` returns a snapshot, `todo.list` returns a bare array, `todo.add` returns a bare object.
3. **No way to launch a program** in a newly-created pane via IPC. Today the only path is `new-tab` + `send-keys`, which races shell-prompt readiness and requires an extra `ls` round-trip to discover the pane id.

The user is the sole consumer, so backwards compatibility is not a constraint. This change unifies the surface on three rules -- dotted method names, wrap-entity response shape, optional `launch` spec on pane-creating methods -- and unblocks scripted layouts (`danterm tab new --cmd 'vim foo'`).

## Goals

1. **Method naming**: all IPC methods follow `<noun>.<verb>` dotted form on the wire. CLI mirrors the same noun-verb structure with spaces (`danterm tab new`, `danterm pane input`).
2. **Response shapes**: methods that act on a primary entity wrap it under the singular noun (`{tab: {...}}`, `{pane: {...}}`, `{todo: {...}}`). List/read methods return data under the plural noun or a descriptive key (`{todos: [...]}`, `{text}`). Pure acks return `{ok: true}`. Inside entity objects, self-id is `id`; references to other entities are `<type>Id` -- the convention already established in `TabSnapshot`/`PaneSnapshot`.
3. **Launch spec**: optional `launch: {cmd, cwd, title}` on `tab.new` and `pane.split`. CLI flags `--cmd`, `--cwd`, `--title`. Each field independently optional.

## Method-rename and response-shape table

| Old wire name | New wire name | New response |
|---|---|---|
| `new-tab` | `tab.new` | `{tab: TabSnapshot, panes: [{id}], group?: {id, name}}` -- panes carry only `id` (other fields are empty at reply time); `group` present only when a new group was created |
| `send-keys` | `pane.input` | `{ok: true}` (unchanged) |
| `read-pane` | `pane.read` | `{text: string}` (already this shape; rename only) |
| `tab.title` (overloaded getter+setter) | replaced by `tab.rename` (setter only; getter dropped) | `tab.rename` accepts `{title: string \| null}` and returns `{tab: {id, customTitle}}`. Null clears `customTitle` back to auto-derived. No dedicated single-tab getter -- callers use `ls` + jq if they need the full tab object |
| `pane.split` | `pane.split` | `{pane: {id}}` (wrapped) |
| `pane.focus` | `pane.focus` | `{tab: {id, focusedPaneId}}` |
| `theme.set` | `theme.set` | `{pane: {id, theme}}` |
| `todo.list` | `todo.list` | `{todos: [{id, text, isDone}, ...]}` |
| `todo.add` | `todo.add` | `{todo: {id, text, isDone}}` |
| `todo.edit` | `todo.edit` | `{todo: {id, text, isDone}}` (returns updated, was `{ok:true}`) |
| `todo.done`, `todo.open` | unchanged | `{todo: {id, text, isDone}}` (returns updated) |
| `todo.delete`, `todo.clearCompleted` | unchanged | `{ok: true}` (entity gone -- nothing to wrap) |
| `ls` | `ls` | `{groups, panes, selectedTabId}` (unchanged) |
| `hello` | `hello` | server-pushed handshake (unchanged) |

## Launch spec

`tab.new` and `pane.split` accept an optional `launch` object:

```json
{
  "launch": {
    "cmd": "vim foo.txt",
    "cwd": "/Users/dan/world",
    "title": "edit"
  }
}
```

- `cmd`: single shell string. libghostty runs it through `/bin/sh -c` via `ghostty_surface_config.command` (see `.ghostty-src/include/ghostty.h:447`). This is the **direct-launch** path -- distinct from today's restore-prefill path which writes to `config.initial_input`.
- `cwd`: initial working directory (`config.working_directory`).
- `title`: initial pane title; will be overridden later by OSC sequences if shell integration is active.
- `config.wait_after_command` is set to `true` for IPC launches so the pane stays alive after the command exits (matches tmux `split-window <cmd>` UX). Hardcoded; not user-tunable.

CLI flags on `danterm tab new` and `danterm pane split`: `--cmd <string>`, `--cwd <path>`, `--title <string>`.

### Server-side validation contract

`parseLaunchSpec(JSONValue) throws -> LaunchSpec?` lives in `DanTermProtocol` and is called by both `tab.new` and `pane.split` handlers before any state mutation. It throws a *public* `LaunchSpecParseError` (`DanTermProtocol`-owned, not the private `IpcParamsError` in `app/Update.swift:1771`) which the app layer maps to JSON-RPC `-32602`:

```swift
public enum LaunchSpecParseError: Error {
    case notObject
    case fieldNotString(field: String)   // "cmd" / "cwd" / "title"
}
```

Semantics:
- `launch` key absent -> returns `nil` (no launch; default shell).
- `launch` present but not an object -> `.notObject`.
- `launch.cmd`/`launch.cwd`/`launch.title` present but not strings (or null/absent for missing) -> `.fieldNotString`.
- Empty-string `cmd` -> treated as absent (no launch).
- Validation runs before any model mutation -- a malformed `launch` never creates a pane.

### Pane title vs tab chrome

`PaneModel.title` and `TabModel.title`/`customTitle` are independent (`app/Model.swift:77` vs `:109`). Tab chrome shows `tab.displayTitle = customTitle ?? title` (`app/Model.swift:118`), not pane title. So setting only the pane title leaves tab chrome unaffected.

`launch.title` semantics:
- **`tab.new`**: sets `PaneModel.title` AND `TabModel.customTitle` -- the new tab is fully owned by this launch, so tab chrome should reflect the requested label.
- **`pane.split`**: sets only `PaneModel.title` -- the tab is shared by sibling panes, so we don't hijack tab chrome.

OSC sequences from shell integration still overwrite `PaneModel.title` later as normal; `customTitle` on the tab is sticky until cleared via `tab.rename --clear`.

### pane.focus must update focusedPaneId synchronously

Current `navigateToPane` (`app/Update.swift:2036`) emits `.makeFirstResponder(paneId:)` as an effect; `TabModel.focusedPaneId` is updated later via the AppKit callback. If the `pane.focus` IPC handler builds its `{tab: {id, focusedPaneId}}` reply from the model immediately after, it would report the *old* focused pane.

Fix: update the target tab's `focusedPaneId` synchronously inside `navigateToPane` (e.g. `updateTab(currentTab.id, in: &model) { $0.focusedPaneId = paneId }`) before returning effects. This benefits all callers (alert navigation, IPC focus) -- the model intent is immediate, the AppKit effect remains async. The reply for `pane.focus` is then guaranteed accurate.

## CLI surface

| Old | New |
|---|---|
| `danterm new-tab [--group <name>]` | `danterm tab new [--group <name>] [--cmd <s>] [--cwd <p>] [--title <s>]` |
| `danterm send-keys [--pane <id>] [--literal] -- <tokens>` | `danterm pane input [--pane <id>] [--literal] -- <tokens>` |
| `danterm read-pane --pane <id> [--lines <n>]` | `danterm pane read --pane <id> [--lines <n>]` |
| `danterm tab title [text]` (getter+setter overload) | `danterm tab rename <name>\|--clear` (getter dropped; use `danterm ls` if you need to inspect a tab) |
| `danterm pane split [--pane <id>] -h\|-v` | `danterm pane split [--pane <id>] -h\|-v [--cmd <s>] [--cwd <p>] [--title <s>]` |
| `danterm ls`, `pane focus`, `theme set`, `todo *`, `help` | unchanged |

## Implementation

### Reuse (already in place)

- libghostty surface config supports `command`, `working_directory`, `initial_input`, `wait_after_command` natively (`.ghostty-src/include/ghostty.h:440-453`). We currently use only `working_directory` and `initial_input`.
- `.renameTab(id: TabId, name: String?)` already accepts an optional name -- nil clears `customTitle` (`app/Msg.swift:67`). No model-layer change needed for `tab.rename` clear semantics.
- `PaneLaunchSnapshot` exists at `app/Model.swift:299` with `command`/`cwd` fields; `resolveLaunch` helper for session-restore at `app/Model.swift:491-502` -- already the pattern to follow for resolving inputs.

### Runtime gap to close (the key correction)

The existing `Effect.createSurface(paneId:, cwd:, command:)` does NOT do a real libghostty launch. `TerminalView.swift:84` threads `command` through `restoreInitialInput()` into `config.initial_input` -- i.e. it types the command at the shell prompt. For `.execute` restore behavior it appends `\n`; for `.prefill` it doesn't. Either way, libghostty's `config.command` is never set, so the spawned process is always the user's interactive shell. That means today's `command:` parameter has the same race the launch spec is meant to remove.

To get true launch semantics we need a new path:

- Extend `Effect.createSurface` to take a separate `launchCommand: String?` parameter (in addition to the existing `command:` restore-prefill parameter). At most one is non-nil.
- Extend `TerminalView.init` to accept `launchCommand: String?` and `waitAfterCommand: Bool = true`. When set, wire to `config.command` and `config.wait_after_command` instead of `config.initial_input`. The `withCString` nesting in `TerminalView.swift:104-124` needs another layer for `command` ptr.
- The restore path (`bootstrapFromSnapshot` and other AppRuntime call sites) keeps using `command:` -- no behavior change there. Only IPC-driven `tab.new`/`pane.split` with `launch.cmd` use the new path.

### Critical files to modify

**Protocol** (`lib/DanTermProtocol/Sources/DanTermProtocol/`):
- `Methods.swift` -- rename constants: `newTab` -> `tabNew` (wire `"tab.new"`), `sendKeys` -> `paneInput` (wire `"pane.input"`), `readPane` -> `paneRead` (wire `"pane.read"`). Remove `tabTitle`; add `tabRename` (wire `"tab.rename"`).
- Add `TabNewArgs.swift` with `parseTabNewArgs` mirroring the existing `PaneSplitArgs.swift` shape (returns `ParsedTabNew { group, launch }`).
- Extend `PaneSplitArgs.swift` to also parse `--cmd`/`--cwd`/`--title` flags into `ParsedPaneSplit.launch`.
- Add a shared `LaunchSpec` struct + `parseLaunchSpec(JSONValue)` strict validator (per "Server-side validation contract" above). Used by both `tab.new` and `pane.split` server handlers.

**Server** (`app/`):
- `Update.swift` -- the IPC dispatch block (`case Methods.X` at ~line 1475 onwards). For each case: update method constant reference, reshape response per the table. Specifically:
  - Delete `tabIdResult` and `paneIdResult` helpers (lines 1891, 1896). Replace with `tabSnapshotResult`, `paneSnapshotResult`, `todoResult`, `todoListResult`, `okResult`. Each helper accepts the model entity and returns the wrapped `JSONValue`.
  - `tab.new` handler (~line 1521): call `parseLaunchSpec` first (returns `-32602` on malformed launch before any mutation); pass `LaunchSpec` into the new `.createTab` Msg fields; build `{tab, panes, group?}` reply.
  - Replace the `tab.title` case (~line 1485) with a `tab.rename` case. Accepts `{title: string | null}`; for null, call `.renameTab(id:, name: nil)`. Reply: `{tab: {id, customTitle}}`.
  - `pane.split` handler (~line 1502): call `parseLaunchSpec` first; pass into `.splitPane`; reply with `{pane: {id}}`.
  - `pane.focus`, `theme.set`, all `todo.*`: rewrap responses per table.
- `Msg.swift` -- extend `case createTab(inGroupId:, position:)` (line 44) with optional `launch: LaunchSpec?`. Same for `case splitPane(paneId:, direction:)` (line 47). Extend `case createGroup(name:)` (line 976 handler) with optional `launch: LaunchSpec?` so `tab.new --group <new> --cmd ...` carries launch through to the auto-created first tab.
- `Update.swift` handlers:
  - `.createTab` (~line 44): if `launch != nil`, pass `launch.cmd` as the new `launchCommand:` argument to `.createSurface` (NOT the existing `command:` restore-prefill parameter), and pass `launch.cwd`. Set both `PaneModel.title` AND the new `TabModel.customTitle` from `launch.title` (see "Pane title vs tab chrome" above).
  - `.splitPane` (~line 182): same pattern except `launch.title` sets only `PaneModel.title`; do not modify the surrounding tab's `customTitle`.
  - `.createGroup` (line 976): change `update(&model, .createTab(inGroupId: groupId))` to forward `launch` -- `.createTab(inGroupId: groupId, launch: launch)`.
  - `navigateToPane` (line 2036): update the target tab's `focusedPaneId` synchronously before returning effects. This unblocks `pane.focus` from returning a stale id (see "pane.focus must update focusedPaneId synchronously" above).
- `Effect.swift` (line 6): extend `case createSurface` to `(paneId:, cwd:, command:, launchCommand:, waitAfterCommand:)`. Existing call sites pass `launchCommand: nil` (preserves current restore behavior).
- `AppRuntime.swift` `.createSurface` handler: wire the new params through to `TerminalView.init`.
- `TerminalView.swift` (lines 45-124): add `launchCommand: String?` and `waitAfterCommand: Bool = true` init params. When `launchCommand != nil`, set `config.command` + `config.wait_after_command` (extra `withCString` nesting at lines 104-124). The existing `restoreInitialInput` / `config.initial_input` path is unaffected.

**CLI** (`cli/main.swift`):
- Extract `parseCommand` and the `outputMode`-resolution logic into a public, testable function in a new file (e.g. `cli/CLIParser.swift`) or into `DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift` so tests in `DanTermProtocolTests` can import it. Signature: `parseCLI(_ args: [String]) throws -> CLICommand` where `CLICommand` exposes method/params/outputMode.
- Restructure dispatch:
  - `tab new`, `tab rename <name>|--clear` (no `tab title`, no `tab get`).
  - `pane focus`, `pane split`, `pane input` (was `send-keys` top-level), `pane read` (was `read-pane` top-level).
  - Remove top-level `new-tab`, `send-keys`, `read-pane` cases.
- `usageText` (line 35) -- regenerate to match new structure.

### Test work

Update existing:
- `tests/UpdateIpcTests.swift` -- substitute renamed method strings throughout; update response-shape assertions per the table. Affected groups: `new-tab` (2), `pane.split` (8), `tab.title` (2), `send-keys` (23), `read-pane` (9), `pane.focus` (1), `theme.set` (1), `todo.*` (8).
- `lib/DanTermProtocol/Tests/DanTermProtocolTests/PaneSplitArgsTests.swift` -- extend with `--cmd`/`--cwd`/`--title` cases.

Add new (parser layer):
- `lib/DanTermProtocol/Tests/DanTermProtocolTests/TabNewArgsTests.swift` -- parser tests for `parseTabNewArgs`: `--group`, `--cmd`, `--cwd`, `--title` individually, combinations, missing-value errors.
- `lib/DanTermProtocol/Tests/DanTermProtocolTests/LaunchSpecTests.swift` -- `parseLaunchSpec` strict-validation tests: absent -> nil, non-object -> error, non-string cmd/cwd/title -> error, empty cmd -> treated as absent, all-string valid case.
- `lib/DanTermProtocol/Tests/DanTermProtocolTests/CLIParserTests.swift` (new file, requires CLI parser extraction) -- behavioral coverage of the full CLI surface:
  - Each new subcommand resolves to the correct method string, params object, and outputMode (`tab new`, `tab rename <name>`, `tab rename --clear`, `pane input`, `pane read`, `pane split` with launch flags).
  - Removed legacy commands (`new-tab`, `send-keys`, `read-pane`) raise "unknown command".
  - `tab rename --clear` produces `params.title == null` (not omitted, not empty string).
  - `tab new --cmd foo --cwd /x --title t` produces a properly shaped `launch` params object.

Add new (handler layer in `tests/UpdateIpcTests.swift`):
- `tab.new` with `launch.cmd`/`cwd`/`title` produces a `.createSurface` effect with non-nil `launchCommand:` (NOT the existing `command:` parameter), correct `cwd`, AND sets `tab.customTitle == launch.title` (so `tab.displayTitle` reflects the requested label, not the default `"Terminal"`).
- `tab.new --group <new-name>` with `launch.cmd` populates the auto-created tab inside the new group with the launch fields (regression for the `.createGroup` propagation).
- `pane.split` with `launch.title` sets `PaneModel.title` only -- the surrounding tab's `customTitle` is unchanged.
- Malformed launch params (non-object, non-string fields) return `-32602` and produce no mutation effects (no `.createSurface`, no model change).
- `tab.rename` with `{title: null}` clears `customTitle`; with a string sets it.
- `pane.focus` reply shape: `{tab: {id, focusedPaneId}}`. Add a same-tab multi-pane test: starting with pane A focused, calling `pane.focus` on pane B in the same tab returns `focusedPaneId == B.id` (regression for the stale-focusedPaneId finding).
- `theme.set` reply shape: `{pane: {id, theme}}`.
- `todo.add`/`edit`/`done`/`open` reply shape: `{todo: {...}}`; `todo.list` shape: `{todos: [...]}`.

### Verification

1. `just test` -- the pure-Swift unit suite passes (no Cocoa/GhosttyKit needed).
2. `just build` -- compiles.
3. `just build-run` -- launches the dev app.
4. Manual exercises against the running dev app:
   - `danterm tab new` -- new tab, default shell, prints JSON with `{tab, panes, ...}`.
   - `danterm tab new --cmd 'date > /tmp/danterm-launch && cat /tmp/danterm-launch'` -- verify `/tmp/danterm-launch` contains the timestamp AND the pane stays open (proves `wait_after_command=true` and `config.command` -- not `initial_input` -- is being used).
   - `danterm tab new --cmd 'pwd' --cwd /tmp --title custom` -- verify the **tab bar** shows "custom" (not "Terminal" or a shell-derived label), proving `customTitle` is set. Then verify the pane's cwd via `pwd` output.
   - `danterm tab new --group brand-new --cmd 'echo group-launch'` -- new group's auto-created first tab actually runs the command (regression for the `.createGroup` propagation finding).
   - From an existing pane: `danterm pane split -h --cmd 'cargo --version'` -- new pane runs the command.
   - `danterm tab rename foo` then `danterm tab rename --clear` -- title returns to auto-derived (default).
   - `danterm pane input -- hello Enter` -- still sends keys.
   - `danterm pane read --pane <id>` -- still reads.
   - `danterm ls`, `danterm theme set <name>`, `danterm todo add/list/done` -- unaffected by the rename, but new wrapped shapes visible in JSON output.
5. Inspect `danterm tab new --cmd 'sleep 30' | jq` and confirm:
   - `.tab.id` is a UUID
   - `.tab.focusedPaneId` matches `.panes[0].id`
   - `.tab.rootNode.paneId` matches `.panes[0].id`
   - `.panes[0]` has only the `id` key
6. Malformed-launch error check: pipe a hand-built malformed request via `nc -U <socket>` (e.g. `launch: "not-an-object"` or `launch: {cmd: 42}`) and confirm a `-32602` error response and that no new pane appeared in a follow-up `danterm ls`.
