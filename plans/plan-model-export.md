# Export State Feature

## Context

DanTerm has an `--init <path>` system that restores app state from a JSON file
(groups, tabs, split panes, cwds, commands). The **deserialization** path works:
`main.swift` parses `--init`, decodes `AppInitFile`, calls
`bootstrapFromSnapshot()`. But there's no **serialization** path — no way to
export the current `AppModel` as JSON.

This feature adds:
1. **"Export State..." menu item** — dumps the live model as JSON, round-trippable through `--init`
2. **Command tracking via shell integration** — so exports capture what command each pane was running

### Why command tracking matters

Without it, an exported snapshot can only restore the pane layout and cwds —
every pane opens a bare shell. The user loses context about what they were
doing (running `vim`, `ssh`, `claude`, etc.).

### Approaches considered and rejected

**Title heuristic** — Ghostty's shell integration sets the terminal title to
the command on `preexec` and to the cwd on `precmd`. We could infer `lastCommand`
by comparing title vs cwd. **Rejected because**: Programs like Claude Code, vim,
ssh, and tmux dynamically change the title to their own content ("Conversation
about car tires"), overwriting the original command. The captured "command" would
be the program's dynamic title, not the user's original command.

**Process tree inspection** — Walk child processes via `sysctl(KERN_PROC)` at
export time. **Rejected because**: (a) ghostty's C API doesn't expose the child
PID (`ghostty_surface_child_pid` doesn't exist — PID is tracked internally in
`Command.zig:80` but never exported), (b) only works at export time, not for
crash recovery, (c) would need to find PID indirectly via TTY which ghostty also
doesn't expose.

**Fork ghostty for OSC 133 callbacks** — Add `GHOSTTY_ACTION_COMMAND_START`
etc. to the embedded runtime. **Rejected because**: (a) OSC 133 marks boundaries
but doesn't carry the command text — you'd still need title or process inspection
for the actual command, (b) maintaining a fork is high cost for this feature alone.

**File-based IPC** — Set `DANTERM_PANE_ID` env var per surface, shell writes
command to `/tmp/danterm-cmd-$PANE_ID` on preexec. DanTerm reads files on export.
**Considered viable** but superseded by the title-channel approach below which
requires zero new IPC.

### Chosen approach: title-channel event protocol with per-pane nonce

The shell's preexec/precmd hooks send structured `__DANTERM_EVT__` messages via
OSC 0 (set title), which DanTerm already receives through the existing
`surfaceTitle` callback. The shell also sends the normal human-readable title
immediately after, so the event is invisible to the user.

**Protocol** (each event MUST be followed by a normal title to prevent stale display):
- `__DANTERM_EVT__:<token>:CMD_START:<base64-encoded command>` then normal title (command text) — on preexec
- `__DANTERM_EVT__:<token>:CMD_END` then normal title (cwd or empty) — on precmd
- `<token>` is a per-pane random nonce set by DanTerm via `DANTERM_TOKEN` env var

**Trust boundary**: DanTerm generates a random token per pane, passes it via
`DANTERM_TOKEN` env var on surface creation. The shell copies it to a local
(non-exported) var and unsets the env var, so child processes can't read it.
DanTerm validates the token before accepting events — rejects wrong/missing tokens.

**Why this works**:
- Piggybacks on existing `GHOSTTY_ACTION_SET_TITLE` → `surfaceTitle` callback
- No new IPC channels (no files, sockets, named pipes)
- Per-pane nonce prevents spoofing by child processes
- Base64 handles commands with special characters
- The real title follows immediately, so the event string never visibly appears
- Command is captured at the exact preexec moment, immune to programs changing the title later
- Shell-side is opt-in (~10 lines of zsh/fish config)
- Works for crash recovery (model always has latest `lastCommand`)

**Shell-side config** (user provides in their dotfiles, not shipped by DanTerm).
Uses hook arrays (`preexec_functions`/`precmd_functions` in zsh, `--on-event` in
fish) to avoid clobbering existing hooks:

```zsh
# zsh — add to initExtra or shells.nix
if [[ -n "$DANTERM_TOKEN" ]]; then
  typeset -g _danterm_tok="$DANTERM_TOKEN"
  unset DANTERM_TOKEN
  _danterm_b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
  _danterm_preexec() {
    printf '\e]0;__DANTERM_EVT__:%s:CMD_START:%s\a' "$_danterm_tok" "$(_danterm_b64 "$1")"
    printf '\e]0;%s\a' "$1"
  }
  _danterm_precmd() {
    printf '\e]0;__DANTERM_EVT__:%s:CMD_END\a' "$_danterm_tok"
    printf '\e]0;%s\a' "${(%):-%(4~|…/%3~|%~)}"  # restore cwd as visible title
  }
  preexec_functions+=(_danterm_preexec)
  precmd_functions+=(_danterm_precmd)
fi
```

```fish
# fish — add to interactiveShellInit
if set -q DANTERM_TOKEN
  set -g _danterm_tok $DANTERM_TOKEN
  set -e DANTERM_TOKEN
  function __danterm_preexec --on-event fish_preexec
    set -l b64 (printf '%s' $argv[1] | base64 | string replace -a '\n' '')
    printf '\e]0;__DANTERM_EVT__:%s:CMD_START:%s\a' $_danterm_tok $b64
    printf '\e]0;%s\a' $argv[1]
  end
  function __danterm_postcmd --on-event fish_prompt
    printf '\e]0;__DANTERM_EVT__:%s:CMD_END\a' $_danterm_tok
    printf '\e]0;%s\a' (prompt_pwd)  # restore cwd as visible title
  end
end
```

## Plan

### 1. Add `lastCommand` to PaneModel

**`app/Model.swift:23-29`** — Add field after `lastBellNotification`:

```swift
struct PaneModel: Equatable {
    let id: PaneId
    var title: String = "Terminal"
    var cwd: String?
    var hasBell: Bool = false
    var lastBellNotification: Date?
    var lastCommand: String?        // ← NEW: set via __DANTERM_EVT__ title protocol
}
```

**Note**: `dantermToken` is intentionally NOT in AppModel. Nonce state lives in
AppRuntime (see step 2) to keep the model pure — only `update()` mutates model,
and the runtime validates events before emitting semantic Msgs.

### 2. Token management and event parsing in AppRuntime

**`app/AppRuntime.swift`** — Add a `paneTokens: [PaneId: String]` dictionary
alongside the existing `surfaces` dict. This is runtime-only state, not model.

On surface creation (`perform(.createSurface(...))` and `bootstrapFromSnapshot()`):
- Generate token: `UUID().uuidString`
- Store: `paneTokens[paneId] = token`
- Pass as env var to TerminalView: `envVars: [("DANTERM_TOKEN", token)]`

On surface destroy: `paneTokens.removeValue(forKey: paneId)`

**Pure event parser** — Add to `app/ModelOperations.swift` (testable without runtime):

```swift
/// Result of parsing a __DANTERM_EVT__ title string.
enum DantermEvent: Equatable {
    case commandStarted(command: String)
    case commandEnded
}

/// Parse a __DANTERM_EVT__ title. Returns nil if malformed, wrong token, or bad base64.
func parseDantermEvent(_ raw: String, expectedToken: String) -> DantermEvent? {
    let prefix = "__DANTERM_EVT__:"
    guard raw.hasPrefix(prefix) else { return nil }
    let payload = String(raw.dropFirst(prefix.count))

    // Extract token (first segment before ':')
    let parts = payload.split(separator: ":", maxSplits: 1)
    guard parts.count == 2, String(parts[0]) == expectedToken else { return nil }
    let event = String(parts[1])

    if event.hasPrefix("CMD_START:") {
        let b64 = String(event.dropFirst("CMD_START:".count))
        guard let data = Data(base64Encoded: b64),
              let cmd = String(data: data, encoding: .utf8),
              !cmd.isEmpty else { return nil }
        return .commandStarted(command: cmd)
    } else if event == "CMD_END" {
        return .commandEnded
    }
    return nil
}
```

**Runtime interception**: In `AppRuntime.send(_ msg:)`, intercept `surfaceTitle`
before passing to `update()`. If the title starts with `__DANTERM_EVT__:`,
validate via the pure parser and translate to a semantic Msg:

```swift
func send(_ msg: Msg) {
    let translatedMsg: Msg
    switch msg {
    case .surfaceTitle(let paneId, let title) where title.hasPrefix("__DANTERM_EVT__:"):
        guard let token = paneTokens[paneId],
              let event = parseDantermEvent(title, expectedToken: token) else { return }
        switch event {
        case .commandStarted(let command):
            translatedMsg = .commandStarted(paneId: paneId, command: command)
        case .commandEnded:
            return // drop — lastCommand persists (see design note)
        }
    default:
        translatedMsg = msg
    }
    // ... existing: update(&model, translatedMsg), perform effects ...
}
```

The runtime does minimal work: token lookup + calling the pure parser. All
parsing logic is in the testable `parseDantermEvent` function.

**Design note**: `CMD_END` is dropped at the runtime layer (no Msg emitted).
`lastCommand` persists across command completion — its meaning is "last command
this pane ran," which is what we want for export and crash recovery. A future
`isRunning: Bool` could be added via a `Msg.commandEnded` when spinner UI is needed.

### 3. Add `commandStarted` Msg

**`app/Msg.swift`** — Add:
```swift
case commandStarted(paneId: PaneId, command: String)
```

**`app/Update.swift`** — Add handler (pure model mutation):
```swift
case .commandStarted(let paneId, let command):
    model.panes[paneId]?.lastCommand = command
    return []
```

This keeps all model mutation in `update()` where it's testable.

### 4. Add env vars support to TerminalView

**`app/TerminalView.swift:23`** — Add `envVars: [(String, String)] = []`
parameter to init. Before calling `ghostty_surface_new`, set up the env vars
array on the config:

```swift
// Build env vars array for ghostty
var envVarStructs = envVars.map { (key, value) in
    ghostty_env_var_s(key: strdup(key), value: strdup(value))
}
envVarStructs.withUnsafeMutableBufferPointer { buf in
    config.env_vars = buf.baseAddress
    config.env_var_count = buf.count
    createSurface()
}
// Free strdup'd strings after surface creation
for ev in envVarStructs { free(UnsafeMutablePointer(mutating: ev.key)); free(UnsafeMutablePointer(mutating: ev.value)) }
```

Token generation: `UUID().uuidString` (simple, unique enough).

### 4. Add Msg and Effect for export (Elm architecture)

Export goes through the Elm flow to stay consistent with the architecture.

**`app/Msg.swift`** — Add:
```swift
case exportState
```

**`app/Effect.swift`** — Add:
```swift
case exportState(AppInitFile)
```

**`app/Update.swift`** — Add handler:
```swift
case .exportState:
    let initFile = toInitFile(model)
    return [.exportState(initFile)]
```

**`app/AppRuntime.swift`** — Add effect handler in `perform()`:
```swift
case .exportState(let initFile):
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    let data: Data
    do {
        data = try encoder.encode(initFile)
    } catch {
        let alert = NSAlert()
        alert.messageText = "Export Failed"
        alert.informativeText = "Failed to encode state: \(error.localizedDescription)"
        alert.runModal()
        return
    }

    let panel = NSSavePanel()
    panel.nameFieldStringValue = "danterm-state.json"
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true

    guard let window = window else { return }
    panel.beginSheetModal(for: window) { response in
        guard response == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Save Failed"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
```

### 5. Add `toSnapshot()` and `toInitFile()` pure functions

**`app/ModelOperations.swift`** — New section at the bottom.

`toSnapshot(_ model: AppModel) -> AppModelSnapshot`:
- Walks `model.groups` → `GroupSnapshot` with id, name, isCollapsed, tabs
- Each tab → `TabSnapshot` with id, title, subtitle, focusedPaneId, rootNode
- Each split node → `toSplitNodeSnapshot()` recursive helper
- Collects panes in tree traversal order → `PaneSnapshot` with id, title, cwd
  (abbreviated via `abbreviateHome`), launch (cwd + lastCommand)
- `launch` is omitted when both `lastCommand` and `cwd` are nil
- All UUIDs preserved as strings

`toInitFile(_ model: AppModel) -> AppInitFile`:
- Wraps in `AppInitFile(version: 1, model: toSnapshot(model))`

Reuses existing: `allPaneIds()` (`ModelOperations.swift`), `abbreviateHome()` (`ModelOperations.swift`).

### 6. Add "Export State..." menu item

**`app/AppDelegate.swift`**:

- Add `import UniformTypeIdentifiers` (framework already linked in `dev-build.sh:58`)
- In `buildMenu()` (~line 127): add "Export State..." item before the separator + "Close Pane"
  - Shortcut: Cmd+Shift+E
- Menu action dispatches through Elm: `runtime.send(.exportState)`

### 7. Tests

**`tests/ExportTests.swift`** (new file):

**Round-trip tests**:
- `toSnapshot` → `validateAndBuild` produces valid model
- Group/tab/pane UUIDs preserved through round-trip
- `selectedTabId` preserved
- Split tree structure (directions, ratios) preserved
- Multiple groups preserved with names and collapsed state

**Launch field tests**:
- `lastCommand` maps to `launch.command` in snapshot
- `launch` omitted when no command and no cwd
- cwd abbreviated with `~` in export

**parseDantermEvent tests** (pure parser, no runtime needed):
- Valid CMD_START with correct token → `.commandStarted(command: "vim")`
- Valid CMD_END with correct token → `.commandEnded`
- Wrong token → nil (rejected)
- Missing token segment → nil
- Malformed base64 → nil
- Empty command after decode → nil
- No `__DANTERM_EVT__:` prefix → nil
- Unknown event type (not CMD_START or CMD_END) → nil

**commandStarted Msg tests** (pure model tests):
- `.commandStarted(paneId, "vim")` sets `pane.lastCommand` to `"vim"`
- `.commandStarted` with a second command overwrites the first
- `.commandStarted` does not affect `pane.title`
- Normal `.surfaceTitle` does not affect `lastCommand`

**exportState Msg/Effect tests**:
- `.exportState` msg returns `[.exportState(initFile)]` effect with valid snapshot

**JSON round-trip**:
- encode → decode → `validateAndBuild` succeeds

**`tests/TestHarness.swift`** — Add `exportTests()` call in `main()`.

`test.sh` already globs `tests/*.swift` — no changes needed.

## Files changed

| File | Change |
|---|---|
| `app/Model.swift` | Add `lastCommand: String?` to `PaneModel` |
| `app/Msg.swift` | Add `case commandStarted(paneId:command:)`, `case exportState` |
| `app/Effect.swift` | Add `case exportState(AppInitFile)` |
| `app/Update.swift` | Handle `.commandStarted` (sets lastCommand), handle `.exportState` (returns snapshot effect) |
| `app/ModelOperations.swift` | Add `toSnapshot()`, `toSplitNodeSnapshot()`, `toInitFile()` |
| `app/TerminalView.swift` | Add `envVars` parameter to init, wire to `ghostty_surface_config_s` |
| `app/AppRuntime.swift` | Add `paneTokens` dict, intercept `__DANTERM_EVT__` in `send()`, translate to `.commandStarted`, generate tokens on surface creation, handle `.exportState` effect with error alerts |
| `app/AppDelegate.swift` | Add `import UniformTypeIdentifiers`, menu item dispatching `.exportState` |
| `tests/ExportTests.swift` | New file: round-trip, launch, commandStarted msg, JSON tests |
| `tests/TestHarness.swift` | Register `exportTests()` |

## Verification

1. `just test` — all existing + new tests pass
2. `just build-run` — app launches, Shell menu shows "Export State..."
3. Click "Export State..." → save panel → save to `/tmp/test.json`
4. Inspect JSON: version, groups, tabs, panes with IDs, cwds, split ratios
5. Quit and relaunch: `open "DanTerm Dev.app" --args --init /tmp/test.json` → same layout
6. Add shell hooks to zsh config, restart shell in a pane
7. Verify `DANTERM_TOKEN` is set initially, then unset after shell init
8. Run `vim`, export → `launch.command` is `"vim"` in JSON
9. Exit vim (back at prompt), export → `launch.command` still `"vim"` (persists)
10. Run a different command, export → `launch.command` updated to new command
