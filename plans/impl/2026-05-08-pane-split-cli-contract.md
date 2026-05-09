# DanTerm CLI: deterministic pane split replies

## Context

DanTerm already exposes a JSON-RPC control socket and a `danterm` CLI that
inherits pane context through `DANTERM_PANE`. The existing `danterm pane split`
command accepted only `-h|-v`, always targeted the caller's context pane, and
returned no stdout because the IPC response was only `{"ok": true}`.

That forced automation to discover the newly-created pane by diffing
`danterm ls` before and after a split, which races user activity and
concurrent splits. The CLI contract should instead return the new pane id
directly and allow callers to split a specific sibling pane.

## Scope

Implement only the CLI/IPC hardening needed for deterministic pane split
automation:

- `danterm pane split [--pane <id>] -h|-v`
- `--pane` overrides `$DANTERM_PANE` for this command.
- Successful splits print JSON with the new pane id:

  ```json
  {"paneId":"<uuid>"}
  ```

- A no-op split target returns a deterministic shape:

  ```json
  {"paneId":null}
  ```

- Malformed or unknown explicit pane ids fail instead of falling back to the
  caller's context pane.

Out of scope: any DanTerm agent skill file, Home Manager skill installation,
downstream flake updates, MCP work, or manual agent orchestration smoke tests.

## Implementation

Add `lib/DanTermProtocol/Sources/DanTermProtocol/PaneSplitArgs.swift` next to
the existing `send-keys` and `read-pane` parsers. The parser should expose:

```swift
public enum PaneSplitDirection { case horizontal, vertical }

public struct ParsedPaneSplit: Equatable {
    public let pane: String?
    public let direction: PaneSplitDirection
}

public enum PaneSplitParseError: Error, Equatable {
    case missingDirection
    case missingPaneArg
    case unknownFlag(String)
    case unexpectedArgument(String)
}

public func parsePaneSplitArgs(_ args: [String]) throws -> ParsedPaneSplit
```

Update `cli/main.swift` so the `pane split` arm calls the shared parser,
includes a `"pane"` JSON param when `--pane` is present, and uses `.json`
output mode instead of `.none`.

Update `app/Update.swift` so `Methods.paneSplit` resolves its target with a
dedicated resolver:

- If params include `pane`, the value must be a string UUID for an existing
  pane.
- If params omit `pane`, fall back to the IPC request context.
- Do not fall back to context when an explicit pane is malformed or unknown.

The handler should snapshot `model.panes.keys` before calling
`.splitPane(paneId:direction:)`, find the newly-created pane afterward, and
return that id through a `paneIdResult` helper.

## Tests

Add parser tests in
`lib/DanTermProtocol/Tests/DanTermProtocolTests/PaneSplitArgsTests.swift`:

- `-h`
- `-v`
- `--pane <id> -h`
- missing pane argument
- missing direction
- unknown flag
- trailing positional argument

Extend `tests/UpdateIpcTests.swift` around the existing `pane.split` coverage:

- Context-only split returns a `paneId` matching the newly-added pane.
- Explicit sibling pane split targets the sibling, not the caller context.
- Malformed explicit pane id returns invalid params and leaves the model
  unchanged.
- Non-string explicit pane id returns invalid params and leaves the model
  unchanged.
- Unknown explicit pane id returns invalid params and leaves the model
  unchanged.
- No-op split target returns `{"paneId":null}` and leaves the model unchanged.

## Verification

Run:

```bash
just test
swift build --product DanTermCLI
```
