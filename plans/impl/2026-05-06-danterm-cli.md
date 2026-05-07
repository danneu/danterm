# DanTerm CLI (`danterm`)

## Context

DanTerm has no scripting surface today. There is no way for a user inside a
DanTerm pane to do what `tmux send-keys`, `wezterm cli set-tab-title`, or
`kitten @ ls` do — query the running app, rename the current tab from a build
script, spawn a split from a shell function, etc.

This plan ships a `danterm` CLI binary alongside the GUI. Running `danterm`
inside a DanTerm-hosted shell connects to the running app over a Unix domain
socket and dispatches commands/queries against the live `AppModel`. The CLI is
discovered via env vars set when the surface is spawned, and "Install
`danterm` in PATH" is a menu item that symlinks the bundled binary into
`/usr/local/bin`.

Architecture goal: every IPC request becomes a regular `Msg`. All command logic
stays in pure `update()` and is unit-testable without sockets, AppKit, or
GhosttyKit. The transport is a thin actor.

## Design choices

Decisions baked in (research and exploration are in prior turns of the chat
that produced this plan; not duplicated here).

| Concern | Choice |
|---|---|
| Transport | `AF_UNIX SOCK_STREAM` at `~/Library/Caches/<bundle-id>/control.sock` (dir 0700, sock 0600). Bundle ID differs between dev and prod, so they don't collide. |
| Wire format | JSON-RPC 2.0, newline-delimited. One compact JSON object per line; literal `\n` forbidden in payload. Server caps line length at 16 MiB. |
| Handshake | One-way. The server writes a single hello line on accept: `{"jsonrpc":"2.0","method":"hello","params":{"protocol":1,"app":"<version>"}}`. The client reads it and aborts with a clear message if `protocol` is unknown. The client never sends a hello back; the server never waits for one. |
| `params`/`result` representation | Codable `JSONValue` enum (`.null`/`.bool`/`.number`/`.string`/`.array`/`.object`). **Not** `Data` — Codable encodes `Data` as base64. Hand-written `init(from:)`/`encode(to:)` so envelopes round-trip through `JSONEncoder`/`JSONDecoder` faithfully. |
| Discovery env vars | `DANTERM=1`, `DANTERM_SOCK=<absolute path>`, `DANTERM_PANE=<UUID>`, `DANTERM_TAB=<UUID>` — separate vars, not joined string. |
| CLI binary | Separate SwiftPM executable product `DanTermCLI`, shipped at `DanTerm.app/Contents/MacOS/danterm`. The internal product name avoids a case-insensitive build artifact collision with the GUI `DanTerm` product. Apple TN2206 places nested helper tools in `Contents/MacOS` or `Contents/Helpers`, not `Contents/Resources` (signing/notarization correctness). **Not** argv[0] dispatch on the GUI binary (cold-start latency). |
| PATH install | "DanTerm › Install `danterm` Command in PATH" menu item creates `/usr/local/bin/danterm` → bundled binary symlink. AppleScript admin escalation on `EACCES`. Refuses install if bundle path contains `AppTranslocation/`. |
| Auth | Filesystem permissions only. Same-uid trust. No password/crypto. |
| Connect failure | CLI prints `danterm: DanTerm is not running` to stderr and exits 1. No auto-launch in v1. (Full per-verb stdout/stderr/exit table is below the command surface.) |
| App-side architecture | New `IpcServer` actor owns the socket. Each request → `Msg.ipcRequest(reqId, method, params, context)`. `update` translates to existing Msgs and emits `[Effect.ipcReply(reqId, payload)]`. AppRuntime keeps a `[UUID: ConnectionWriter]` map outside the model. |
| Threading | `AppRuntime` is `@MainActor`. The IpcServer accept/read loop runs off-main; every callback into `runtime.send(_:)` hops to `MainActor.run { ... }` first. Model mutation and AppKit/Ghostty effect performance never run off-main. |
| Request context | `Msg.ipcRequest` carries an `IpcRequestContext(paneId: String?, tabId: String?)` (raw UUID strings at the protocol boundary, parsed inside `update`). The CLI populates these from `$DANTERM_PANE` / `$DANTERM_TAB` and ships them in JSON-RPC `params` under a reserved `"_ctx"` key. IPC handlers in `update` never fall back to `selectedTab(in: model)`. **`paneId` is the source of truth** — when present it is parsed and `tabForPane(pid, in: model)?.id` resolves the current tab live. `tabId` is only consulted when no `paneId` exists, since panes can move between tabs after env vars were set. |
| Protocol code sharing | New `DanTermProtocol` library target in `Package.swift`, depended on by both the `DanTerm` GUI target and the `danterm` CLI target. Holds env-var names, socket-path resolver, `JSONValue`, JSON-RPC envelope types. |

### Rationale for the reply-handle pattern

`AppModel` is `Equatable` and pure. Connection writers (file descriptors,
output streams) cannot live in the model. Precedent: confirmation sheets store
`pendingConfirmation` *metadata* in the model and route the response back as a
new Msg — but the actual `NSAlert` reference lives outside the model in
AppRuntime. Mirror that:

- `Msg.ipcRequest(reqId: UUID, method: String, params: JSONValue, context: IpcRequestContext)` — pure, Equatable.
- `update` matches on `method`, dispatches to existing per-domain Msgs (e.g.
  `.renameTab`, `.splitPane`) using **explicit IDs from `context`** rather than
  the focused-tab fallbacks, and returns
  `[.ipcReply(reqId: reqId, result: ...)]` once the model mutation is applied.
- AppRuntime holds `private var ipcConnections: [UUID: IpcConnection] = [:]`,
  resolves `reqId` → connection writer, writes the JSON line, removes the entry.

Long-lived connections (subscriptions) keep their entry; one-shot requests
remove on first reply.

### Rationale for explicit request context

The CLI runs in a specific pane and may not be in the focused tab — a build
script in a background tab calling `danterm tab title "✓ done"` must rename
*its* tab, not whatever tab the user happens to be looking at. The CLI reads
`$DANTERM_PANE` / `$DANTERM_TAB` and sends them in `params._ctx`; the server
parses them into `IpcRequestContext` before dispatching the Msg.

**Pane is the source of truth.** Panes can move between tabs after the env
vars were captured at surface creation. So when both `_ctx.paneId` and
`_ctx.tabId` are present, the resolver parses the pane id and asks
`tabForPane(_:in:)` for the *current* owning tab — `_ctx.tabId` is ignored
in that case. `_ctx.tabId` is only consulted when there is no pane id (e.g.
a future "tab-only" CLI verb invoked from outside any pane).

This forces a small refactor: the existing `selectedTab(in: model)` fallback
in `Update.swift:157` (`.splitPane`) and similar handlers stays valid for *UI*
callers, but IPC handlers must use the existing
`tabForPane(_ paneId: PaneId, in: AppModel) -> TabModel?` helper at
`ModelOperations.swift:341` (returns `TabModel`; we use `.id`) to locate the
current tab from the explicit pane id.

Validation: if the resolved pane/tab no longer exists, return JSON-RPC
error `-32602` ("invalid params") — never silently retarget.

## Initial command surface

Table-stakes ergonomic verbs only. A generic `action <name>` escape hatch
inspired by kitty's `kitten @ action` was tempting, but the repo has no
central keybinding/action registry to reuse, so designing it requires
inventing action names, arg schemas, and context rules from scratch.
Deferred to v2 — see "Out of scope".

```
# implicit subject from $DANTERM_PANE / $DANTERM_TAB
danterm tab title [<text>]             # get (no arg) or set current tab title
danterm tab rename <name>              # alias of `tab title <name>`
danterm pane focus <pane-id>           # explicit pane id, not implicit
danterm pane split -h | -v
danterm new-tab [--group <name>]
# --group targets the first matching group in model.groups order; if no
# group matches, it creates a new group with that name.
danterm send-keys <text>               # send literal text to current pane
danterm theme set <name>               # set theme override on current pane;
                                       #   --clear to unset
danterm todo list                      # current pane TODOs as compact JSON
danterm todo add <text>                # create TODO on current pane; prints item JSON
danterm todo edit <todo-id> <text>     # update TODO text
danterm todo done <todo-id>            # mark TODO done
danterm todo open <todo-id>            # mark TODO not done
danterm todo delete <todo-id>          # delete TODO
danterm todo clear-completed           # delete completed TODOs

# generic introspection
danterm ls                             # full model as compact JSON to stdout
danterm ls --json                      # alias
```

`danterm ls` returns the same shape as the existing `exportState` flow (see
`Effect.exportState` and the snapshot/restore code) so the format is already
specified and tested.

Subscriptions / streaming are out of scope for v1 but the protocol reserves
the JSON-RPC `notification` form (no `id`) for them.

### CLI stdout / stderr / exit contract

The CLI does **not** blindly print the JSON-RPC `result`. Each verb has its
own output shape so output is usable in shell pipelines without `jq`:

| Verb | stdout on success | stderr | exit |
|---|---|---|---|
| `ls` (and `ls --json`) | compact JSON of `result` (one line, no trailing newline beyond standard) | — | 0 |
| `tab title` (get) | plain text: `result.title` followed by a newline | — | 0 |
| `tab title <text>` (set) | nothing | — | 0 |
| `tab rename` | nothing | — | 0 |
| `todo list` | compact JSON array of current-pane TODOs: `[{ "id": "...", "text": "...", "isDone": false }]` | — | 0 |
| `todo add <text>` | compact JSON object for the created TODO, including generated `id` | — | 0 |
| `pane focus`, `pane split`, `new-tab`, `send-keys`, `theme set`, `todo edit`, `todo done`, `todo open`, `todo delete`, `todo clear-completed` | nothing | — | 0 |
| any verb, JSON-RPC `error` returned | nothing | `danterm: <error.message>` (one line) | 1 |
| connect failure | nothing | `danterm: DanTerm is not running` | 1 |

Mutating commands are silent on success (Unix convention), except
`todo add`: it prints the created item so scripts can capture the generated
ID without racing a follow-up list query. The `tab title` getter prints the
resolved string raw so `danterm tab title > t.txt` works without shell
quoting. `ls` and `todo list` are structured machine-readable JSON,
intended for `| jq`.

This contract is implemented in the CLI's per-verb dispatcher, not the
generic JSON-RPC plumbing. The integration test in the testing section
asserts each verb's stdout exactly.

## File layout

### New files

```
cli/
  main.swift                # @main, argv parsing, socket connect, dispatch
lib/DanTermProtocol/
  Sources/DanTermProtocol/
    SocketPath.swift        # bundleId -> socket path resolver
    EnvVars.swift           # constants: DANTERM, DANTERM_SOCK, DANTERM_PANE, DANTERM_TAB
    JSONValue.swift         # Codable enum for arbitrary JSON values
    Envelope.swift          # JsonRpcRequest/Response/Error Codable types
    IpcRequestContext.swift # paneId/tabId carrier, encoded under params._ctx
    Methods.swift           # method-name string constants ("tab.title", "ls", ...)
  Tests/DanTermProtocolTests/
    EnvelopeTests.swift     # round-trip object/array/notification/error/null params
    SocketPathTests.swift   # bundle-id -> path resolution
app/
  IpcServer.swift           # actor: listen, accept, parse; hops to MainActor before send
  IpcConnection.swift       # per-connection state: framed reader (16 MiB cap), writer
  CLIPathInstaller.swift    # /usr/local/bin/danterm symlink + admin escalation
tests/
  UpdateIpcTests.swift      # unit tests for new update() branches (with context)
  IpcConnectionTests.swift  # line framing: short read, oversized line rejection,
                            # split-frame reassembly
  CLIPathInstallerTests.swift  # uses temp-dir destination + fake bundle URL +
                               # injected privileged-runner; covers fresh install,
                               # stale symlink replace, AppTranslocation refusal,
                               # uninstall idempotency, isInstalled mismatch
```

`DanTermProtocol` is a library target (not a folder import) so both
executables get the same source via SwiftPM's normal mechanism. Pattern is
standard SwiftPM and lets the CLI stay zero-dep on Cocoa.

### Files edited

```
Package.swift                # add DanTermProtocol library + tests target +
                             #   danterm executable; main app depends on protocol
app/Msg.swift                # + .ipcRequest(reqId, method, params, context);
                             #   + .setTodoDone(paneId, todoId, isDone)
app/Effect.swift             # + .ipcReply(reqId, result), .ipcError(reqId, code, message),
                             #   .refreshPaneToolbar(paneId)
app/Update.swift             # + // MARK: - IPC section dispatching .ipcRequest
app/AppRuntime.swift         # mark @MainActor; + ipcConnections map;
                             #   perform .ipcReply/.ipcError;
                             #   start IpcServer in init; inject DANTERM_* env vars
                             #   in perform(.createSurface)
app/AppDelegate.swift        # + "Install `danterm` Command in PATH" menu item
tests/TestHarness.swift      # + ipcUpdateTests(), ipcConnectionTests(),
                             #   cliPathInstallerTests() in TestRunner.main()
dev-build.sh                 # + cp .build/.../danterm to Contents/MacOS/
build-app.sh                 # + cp .build/.../danterm to Contents/MacOS/
test.sh                      # + compile DanTermProtocol module first; link into
                             #   the pure-app test compilation
```

### Files untouched

- `Model.swift`, `ModelOperations.swift` — model stays pure.
- `TerminalView.swift` — already accepts `envVars: [(String, String)]`
  (line 86–101); we just pass more from the call site.
- All existing `Update*Tests.swift` and other tests.

## Implementation outline

In dependency order. Each step is a small commit.

### Step 1 — Protocol library target

1. Add `DanTermProtocol` library target plus its test target to
   `Package.swift`. Add `test.sh` wiring (see Step 8) up front so this
   step's tests can run.
2. Implement `SocketPath.swift`:
   ```swift
   public func controlSocketPath(bundleId: String = Bundle.main.bundleIdentifier ?? "com.danneu.danterm") -> URL {
       FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
           .appendingPathComponent(bundleId, isDirectory: true)
           .appendingPathComponent("control.sock")
   }
   ```
3. Implement `EnvVars.swift` with the four constants.
4. Implement `JSONValue.swift`:
   ```swift
   public enum JSONValue: Equatable {
       case null
       case bool(Bool)
       case number(Double)
       case string(String)
       case array([JSONValue])
       case object([String: JSONValue])
   }
   extension JSONValue: Codable {
       public init(from decoder: Decoder) throws { /* try each container */ }
       public func encode(to encoder: Encoder) throws { /* dispatch on case */ }
   }
   ```
   Hand-written `Codable` so `JSONEncoder`/`JSONDecoder` round-trip arbitrary
   JSON shapes without base64 encoding (the `Data` trap). Add
   `subscript(_: String) -> JSONValue?` and `.asString`/`.asObject` accessors
   for ergonomic handler code.
5. Implement `IpcRequestContext.swift` — raw UUID strings on the wire,
   parsed inside `update()`:
   ```swift
   public struct IpcRequestContext: Codable, Equatable {
       public let paneId: String?  // raw UUID string
       public let tabId: String?   // raw UUID string
       public static let paramsKey = "_ctx"
   }
   ```
6. Implement `Envelope.swift` with `JsonRpcRequest`, `JsonRpcResponse`,
   `JsonRpcError` whose `params`/`result`/`data` fields are `JSONValue?`
   (not `Data`).
7. Implement `Methods.swift` with string constants.
8. Add `EnvelopeTests.swift`: every shape round-trips through
   `JSONEncoder` and `JSONDecoder` and matches a hand-written JSON string —
   object params, array params, null, notification (no `id`),
   error response, request with `_ctx`. **Run `just test`; verify pass.**

### Step 2 — `danterm` CLI executable

1. Add `danterm` executable target to `Package.swift`, depending on
   `DanTermProtocol`. Foundation-only (no Cocoa, no GhosttyKit).
2. `cli/main.swift`:
   - Manual argv parsing (no `swift-argument-parser` dep).
   - Read `DANTERM_SOCK`, fall back to `controlSocketPath()`.
   - Connect to `AF_UNIX` via raw POSIX `socket()`/`connect()` and an
     `FileHandle(fileDescriptor:closeOnDealloc:true)` (same approach as
     cmux's `CLI/cmux.swift`).
   - Read the `hello` line; reject if `protocol != 1`.
   - Build a request: `params` is a `JSONValue.object` carrying both the
     command's args and `"_ctx"` populated from `$DANTERM_PANE` /
     `$DANTERM_TAB`.
   - Send the request; await matching `id` in response; route to a
     per-verb formatter (see "CLI stdout / stderr / exit contract"
     above) — *not* a generic "print result as JSON" function. The
     formatter table looks like:
     ```swift
     switch verb {
     case "ls":          print(compactJson(result))
     case "tab.title":   if isGet { print(result["title"]?.asString ?? "") }
     case "todo.list":   print(compactJson(result))
     case "todo.add":    print(compactJson(result))
     default:            break  // other mutating verbs print nothing on success
     }
     ```
   - On JSON-RPC `error`: print `danterm: <error.message>` to stderr,
     exit 1.
   - On connect failure: print `danterm: DanTerm is not running` to
     stderr, exit 1.
3. Build and verify: `just build` produces two binaries.

### Step 3 — App-side server, no commands yet

1. Mark `AppRuntime` as `@MainActor`. Audit existing `send(_:)` callers
   (UI delegates, Ghostty callbacks, debounce timers — all already on
   the main queue per AppRuntime.swift exploration); add `MainActor.assumeIsolated`
   only where the compiler complains and the call site is provably main.
2. Add `Msg.ipcRequest(reqId: UUID, method: String, params: JSONValue, context: IpcRequestContext)`.
3. Add `Effect.ipcReply(reqId: UUID, result: JSONValue)` and
   `Effect.ipcError(reqId: UUID, code: Int, message: String)`.
4. Add `IpcConnection.swift` — owns one accepted socket fd. Read loop on a
   background queue; framed reader buffers up to 16 MiB per line and rejects
   anything longer with a JSON-RPC error response and connection close.
   Write queue serialized via a per-connection serial DispatchQueue.
5. Add `IpcServer.swift` — actor, owns the listen fd. On accept, mints a
   new `IpcConnection`, writes the one-way `hello` line, registers it.
   On each complete request line, parses to `JsonRpcRequest`, extracts
   `_ctx` into `IpcRequestContext`, then **hops to MainActor** before calling
   `runtime.send(.ipcRequest(reqId: ..., method: ..., params: ..., context: ...))`.
   The server never reads or expects a client hello; the client is
   responsible for verifying `protocol` against the server hello before
   sending its first request.
6. AppRuntime (now `@MainActor`):
   - Add `private var ipcConnections: [UUID: IpcConnection] = [:]` keyed
     by request id (each connection registers itself per pending request).
   - In `init`, start `IpcServer` with the resolved socket path; ensure
     parent dir exists with mode `0700`, socket created with mode `0600`.
     On `applicationWillTerminate`, unlink the socket.
   - In `perform(_:)`, handle `.ipcReply`/`.ipcError` by looking up the
     connection writer and writing the JSON-RPC response line.
7. In `Update.swift`, add a `// MARK: - IPC` section with a single
   `case .ipcRequest(let reqId, let method, let params, let context):` arm.
   For now it returns
   `[.ipcError(reqId: reqId, code: -32601, message: "method not found")]`
   for everything — confirms the round trip works end-to-end.
8. Smoke test: run `just build-run`, then in any DanTerm pane:
   ```
   echo '{"jsonrpc":"2.0","id":1,"method":"foo"}' | nc -U $DANTERM_SOCK
   ```
   should print the hello line then a method-not-found error.

### Step 4 — Inject env vars on surface creation

1. In `AppRuntime.perform(_:)` at the `case .createSurface(...)` branch
   (currently around `AppRuntime.swift:246-254`):
   - Look up the tab using the existing helper at
     `ModelOperations.swift:341`:
     ```swift
     let tabId = tabForPane(paneId, in: model)?.id
     ```
     (`tabForPane` returns `TabModel?`; we want `.id`.)
   - Read the socket path from the AppRuntime-owned IPC server. AppRuntime
     stores the running server on a property (`private let ipcServer: IpcServer`)
     and exposes `var ipcSocketPath: URL { ipcServer.socketPath }` so the
     env injection is a property access, not a singleton lookup.
   - Build env-var array:
     ```swift
     var envVars: [(String, String)] = [
         (EnvVars.flag, "1"),
         (EnvVars.sock, ipcSocketPath.path),
         (EnvVars.pane, paneId.rawValue.uuidString),
     ]
     if let tabId = tabId {
         envVars.append((EnvVars.tab, tabId.rawValue.uuidString))
     }
     ```
   - Pass through `makeTerminalView(...)` into existing
     `TerminalView.init(envVars:)` (already supported, see
     `TerminalView.swift:45-124`).
2. Smoke test: open a pane, `echo $DANTERM_PANE` returns a UUID;
   `echo $DANTERM_SOCK` returns an absolute path to an existing socket.

### Step 5 — Real verbs

For each verb, follow the same pattern in `Update.swift` IPC section.
The pseudocode below uses the actual repo APIs:

- `Msg.renameTab(id: TabId, name: String?)` — `name`, not `title` (Msg.swift:56).
- `tabById(_ tabId: TabId, in model: AppModel) -> TabModel?` (ModelOperations.swift:331).
- `tabForPane(_ paneId: PaneId, in model: AppModel) -> TabModel?` (ModelOperations.swift:341).
- `toSnapshot(_ model: AppModel) -> AppModelSnapshot` (ModelOperations.swift:585).
- `params: JSONValue` — `Data` is not used anywhere on the wire.

```swift
// Local parse helpers — TypedId only has init(rawValue: UUID) per
// Model.swift:12, so we go via UUID(uuidString:) first.
func parsePaneId(_ s: String?) -> PaneId? {
    guard let s, let uuid = UUID(uuidString: s) else { return nil }
    return PaneId(rawValue: uuid)
}
func parseTabId(_ s: String?) -> TabId? {
    guard let s, let uuid = UUID(uuidString: s) else { return nil }
    return TabId(rawValue: uuid)
}
func parseTodoId(_ s: String?) -> UUID? {
    guard let s else { return nil }
    return UUID(uuidString: s)
}

func resolvePaneId(_ context: IpcRequestContext, in model: AppModel) -> PaneId? {
    guard let pid = parsePaneId(context.paneId), model.panes[pid] != nil else {
        return nil
    }
    return pid
}

// Pane is the source of truth. `tabId` from context is only used when
// no paneId is present, since panes can move between tabs.
func resolveTabId(_ context: IpcRequestContext, in model: AppModel) -> TabId? {
    if let pid = parsePaneId(context.paneId) {
        return tabForPane(pid, in: model)?.id  // live lookup
    }
    if let tid = parseTabId(context.tabId), tabById(tid, in: model) != nil {
        return tid
    }
    return nil
}

case .ipcRequest(let reqId, let method, let params, let context):
    switch method {
    case Methods.tabTitle:
        guard let tabId = resolveTabId(context, in: model) else {
            return [.ipcError(reqId: reqId, code: -32602,
                              message: "no tab in context")]
        }
        if case .object(let obj) = params, case .string(let name)? = obj["title"] {
            // Set: writes to TabModel.customTitle via .renameTab.
            let sub = update(&model, .renameTab(id: tabId, name: name))
            return sub + [.ipcReply(reqId: reqId, result: .object(["ok": .bool(true)]))]
        } else {
            // Get: read TabModel.displayTitle (Model.swift:117), which
            // returns customTitle ?? title — so a getter run right after
            // a setter sees the value the user just set.
            let current = tabById(tabId, in: model)?.displayTitle ?? ""
            return [.ipcReply(reqId: reqId,
                              result: .object(["title": .string(current)]))]
        }

    case Methods.ls:
        let snapshot = toSnapshot(model)
        let data = try JSONEncoder().encode(snapshot)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return [.ipcReply(reqId: reqId, result: value)]

    default:
        return [.ipcError(reqId: reqId, code: -32601,
                          message: "method not found")]
    }
```

The `ls` snapshot is bridged through `Data` purely as the `Encodable ->
JSONValue` conversion path; nothing of `Data` survives onto the wire (the
final envelope encodes `JSONValue` directly).

TODO verbs are scoped to the current pane via `_ctx.paneId`; they never use
the selected tab or focused pane as a fallback. Add method constants for
`todo.list`, `todo.add`, `todo.edit`, `todo.done`, `todo.open`,
`todo.delete`, and `todo.clearCompleted`.

Implementation details for TODO handlers:

- `todo.list` reads `model.panes[paneId]?.todos` and returns
  `.array` of `.object(["id": .string(uuidString), "text": .string(text),
  "isDone": .bool(isDone)])`.
- `todo.add` must return the generated item ID. Extract the existing
  `.addTodo` branch's trim-and-append logic into a small pure helper that
  accepts an explicit `UUID`, then use that helper from both `.addTodo` and
  the IPC handler. Empty or whitespace-only text returns `-32602` for IPC.
- `todo.edit` wraps the existing `Msg.editTodoText`; empty text, malformed
  IDs, deleted panes, and unknown todo IDs return `-32602`.
- `todo.done` / `todo.open` should be deterministic, not toggles. Add
  `Msg.setTodoDone(paneId:todoId:isDone:)`, and have `toggleTodoDone`
  share the same pure helper internally, so scripts can safely mark a TODO
  done/open without knowing its current state.
- `todo.delete` wraps `Msg.deleteTodo`; unknown todo IDs return `-32602`
  rather than silently succeeding.
- `todo.clearCompleted` wraps `Msg.clearCompletedTodos`; clearing zero
  completed items is a successful no-op.
- IPC todo mutations must also refresh the pane toolbar counts. Add
  `Effect.refreshPaneToolbar(paneId:)`, perform it in `AppRuntime` by
  calling `refreshPaneToolbar(for:)`, and return it from todo IPC handlers
  alongside `.scheduleCheckpoint` / `.ipcReply`. This matters because
  `AppRuntime.send(_:)` currently refreshes TODO counts by inspecting the
  top-level `Msg`; nested `update(&model, .addTodo(...))` calls inside
  `.ipcRequest` would otherwise mutate the model without updating the
  toolbar.

Implementation order within Step 5:
1. `ls` (read-only, exercises serialization).
2. `tab title` get + set (exercises Msg dispatch from IPC, including the
   `renameTab(id:name:)` signature and the `displayTitle` getter).
3. `pane split`, `new-tab`, `pane focus`, `theme set`.
4. `todo list/add/edit/done/open/delete/clear-completed` (current-pane CRUD,
   plus toolbar refresh effect).
5. `send-keys` — needs a `ghostty_surface_text` write effect; check if
   one exists in `Effect.swift` or add it.

A generic `action <name>` escape hatch is deferred to v2 (see "Out of
scope") because it requires a central keybinding/action registry that
does not exist in the repo today.

### Step 6 — PATH installer menu item

1. Port `CLIPathInstaller.swift` from cmux's `CmuxCLIPathInstaller.swift`
   (at `.refs/cmux/Sources/App/CmuxCLIPathInstaller.swift`). Keep cmux's
   instance-style design so every system-touching dependency is injectable
   for tests:

   ```swift
   final class CLIPathInstaller {
       struct Dependencies {
           var destinationURL: URL                  // default: /usr/local/bin/danterm
           var sourceURL: () -> URL                 // default: Contents/MacOS/danterm
           var bundleURL: () -> URL                 // default: Bundle.main.bundleURL
           var fileManager: FileManager             // default: .default
           var privilegedRunner: (String) throws -> Void  // default: osascript admin
       }
       let deps: Dependencies
       init(_ deps: Dependencies = .default) { self.deps = deps }

       static let `default` = CLIPathInstaller()

       func install() throws -> InstallOutcome { ... }
       func uninstall() throws -> UninstallOutcome { ... }
       func isInstalled() -> Bool { ... }
   }
   ```

   - Source URL default:
     `Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("danterm")`
     — i.e. `Contents/MacOS/danterm`, sibling of the GUI binary.
   - Destination URL default: `URL(fileURLWithPath: "/usr/local/bin/danterm")`.
   - Tests construct an instance with a temp-dir destination, a fake
     bundle URL (e.g. one containing `/AppTranslocation/`), a fake source
     URL, and a stub `privilegedRunner` closure. None of the tests touch
     real `/usr/local/bin/` or invoke `osascript`.

2. Add the App Translocation guard inside `install()`:
   ```swift
   guard !deps.bundleURL().path.contains("/AppTranslocation/") else {
       throw InstallerError.appTranslocated
   }
   ```

3. Add menu item to `AppDelegate.buildMenu()` in the app menu near
   "Reload Config":
   ```swift
   appMenu.addItem(withTitle: "Install danterm Command in PATH",
                   action: #selector(installDantermInPath(_:)),
                   keyEquivalent: "")
   ```

4. Action handler calls `CLIPathInstaller.default.install()` and surfaces
   success or failure via `NSAlert`.

5. Add `CLIPathInstallerTests.swift` using the dependency struct: cover
   fresh install, replacing a stale symlink, refusing under
   AppTranslocation, idempotent uninstall, and `isInstalled()` mismatch
   detection. The privileged-runner stub records calls so we can assert
   it was (or wasn't) invoked.

### Step 7 — Build script wiring

1. `dev-build.sh`: after the existing copy of `DanTerm` into
   `Contents/MacOS/`, add:
   ```sh
   cp "$BIN_PATH/DanTermCLI" "$APP_PATH/Contents/MacOS/danterm"
   chmod +x "$APP_PATH/Contents/MacOS/danterm"
   ```
2. Same in `build-app.sh`.
3. CI signing: TN2206 says nested helpers must be signed *before* the
   outer bundle. In `release-stable.yml`'s `codesign` step, sign
   `Contents/MacOS/danterm` first (with the same Developer ID and
   hardened runtime), then sign the outer `.app`. Verify with
   `codesign --verify --deep --strict --verbose=2` and check
   `spctl -a -vvv` accepts the bundle. Update `docs/ci.md` accordingly.

### Step 8 — `test.sh` / `just test` wiring

`test.sh` is a manual `xcrun swiftc` invocation with an explicit source
list (see the current contents of `test.sh:5-19`). Once `Msg.swift` and
`Update.swift` import `DanTermProtocol`, the link fails; new app-side
test subjects (`IpcConnection.swift`, `CLIPathInstaller.swift`) also need
to be added to the source list. New test functions need to be wired into
`tests/TestHarness.swift`'s `TestRunner.main()` (each test suite is
called by name; the harness does no auto-discovery).

Updates:

1. Compile the protocol module directly into a temp test-build dir
   (SwiftPM's `swift build` does not produce a `.a` for library targets,
   so we cannot link with `-lDanTermProtocol` against `.build/`):
   ```sh
   PROTO_BUILD="$(mktemp -d)"
   xcrun swiftc \
       -emit-module -emit-library -static \
       -module-name DanTermProtocol \
       -emit-module-path "$PROTO_BUILD/DanTermProtocol.swiftmodule" \
       -o "$PROTO_BUILD/libDanTermProtocol.a" \
       "$SCRIPT_DIR"/lib/DanTermProtocol/Sources/DanTermProtocol/*.swift
   ```
2. Add `-I "$PROTO_BUILD" -L "$PROTO_BUILD" -lDanTermProtocol` to the
   existing `swiftc` invocation that compiles the app + tests.
3. Add the new Foundation-only app sources to the explicit list in
   `test.sh`:
   ```sh
   "$SCRIPT_DIR/app/IpcConnection.swift" \
   "$SCRIPT_DIR/app/CLIPathInstaller.swift" \
   ```
   `IpcServer.swift` is *not* added here if it imports anything outside
   Foundation; the framing-only logic should live in `IpcConnection.swift`
   so it can be tested without sockets.
4. Edit `tests/TestHarness.swift`'s `TestRunner.main()` to add:
   ```swift
   ipcUpdateTests()
   ipcConnectionTests()
   cliPathInstallerTests()
   ```
   Without these calls the new test functions never run (the harness has
   no auto-discovery).
5. For the protocol library's own tests, run separately:
   ```sh
   swift test --filter DanTermProtocolTests
   ```
   Wire this into `justfile`'s `test` recipe so `just test` runs both.
6. Verify `just test` runs both the new and existing test suites and they
   all pass.

## Testing

Following the project's TDD norm (`AGENTS.md`: "write the failing test first").
Tests are bucketed by what they validate; each bullet is a single test.

### Pure update() tests — no sockets

`tests/UpdateIpcTests.swift`. Each shipped v1 verb gets a happy-path test
plus at least one stale-context error test. Reply payloads round-trip
through `JSONEncoder`/`JSONDecoder` as `JSONValue` (structurally equal).

Generic dispatch:

- `ipcRequest unknown method returns -32601 error`
- `ipcRequest with malformed _ctx (non-UUID strings) returns -32602`

`ls`:

- `ipcRequest "ls" returns ipcReply with the full snapshot`

`tab.title` (set + get):

- `tab.title with title and ctx.paneId renames that pane's current tab
  (writes to TabModel.customTitle)`
- `tab.title without title returns the current displayTitle`
- **Set-then-get regression**: after `tab.title {"title":"hello"}`, the
  next `tab.title` (no args) returns `"hello"` — verifies the getter
  reads `displayTitle`, not the auto-derived `title`
- **Stale-tab regression: pane has been moved to a different tab; `_ctx`
  carries the original `tabId` and the moved pane's `paneId`. The handler
  must rename the pane's *current* tab and ignore the stale `tabId`.**
- `tab.title with deleted pane id returns -32602`

`pane.split`:

- `pane.split with explicit ctx.paneId splits *that* pane, even when a
  different tab is focused` — guards the `selectedTab(in:)` regression
- `pane.split with deleted pane id returns -32602`

`new-tab`:

- `new-tab returns ipcReply containing the new tab id and emits
  rebuildContentView / reloadSidebar effects`
- `new-tab --group <name> places the tab in the first matching group in
  model.groups order`
- `new-tab --group <name> creates a group when there are no matches`

`pane.focus` — takes the **target pane id from `params.paneId`** (the CLI
arg), not from context. The handler decodes the explicit id, validates
it exists in `model.panes`, and calls `navigateToPane(targetPaneId, in:
&model)` (helper at `Update.swift:1368`, which selects the target tab if
needed and emits `.makeFirstResponder(paneId:)`).

The model's `focusedPaneId` does NOT change in this Msg's update step;
AppKit later fires `.paneBecameFirstResponder(paneId:)`, which is what
actually mutates `focusedPaneId` (see `Update.swift:493-501` and the
comment at `Update.swift:489`).

- `pane.focus with explicit params.paneId emits .makeFirstResponder
  targeting that pane and does not mutate focusedPaneId yet`
- `pane.focus targeting a pane in another tab also selects that tab`
- `pane.focus with a missing/unknown params.paneId returns -32602`
- `pane.focus with malformed (non-UUID) params.paneId returns -32602`
- (focusedPaneId mutation on `.paneBecameFirstResponder` is already
  covered by existing `UpdatePaneTests` — no new test needed)

`theme.set` — wraps the existing `Msg.setPaneTheme(paneId: PaneId,
themeName: String?)` (Msg.swift:55). Theme is per pane, stored at
`model.panes[paneId]?.theme`. Existing `setPaneTheme` does not validate
the theme name (unknown names are preserved as-is), so the IPC handler
inherits that behavior — only context errors map to JSON-RPC errors.

- `theme.set updates model.panes[paneId]?.theme to the given name and
  emits .applyPaneTheme`
- `theme.set with themeName: nil clears the pane override`
- `theme.set with no ctx.paneId returns -32602`
- `theme.set with deleted pane id returns -32602`

`todo.*` — all verbs target the current pane from `ctx.paneId`; they do
not fall back to the selected tab or focused pane. TODO result objects use
the persisted `TodoItem` shape with string UUIDs:
`{"id":"...","text":"...","isDone":false}`.

- `todo.list with ctx.paneId returns only that pane's TODOs as JSONValue`
- `todo.list with deleted pane id returns -32602`
- `todo.add trims text, appends an undone TODO to ctx.paneId, returns the
  created item JSON including id, emits .scheduleCheckpoint, and emits
  .refreshPaneToolbar`
- `todo.add with empty or whitespace-only text returns -32602`
- `todo.edit updates the matching TODO text, emits .scheduleCheckpoint,
  and emits .refreshPaneToolbar`
- `todo.edit with malformed/unknown todo id returns -32602`
- `todo.done marks the matching TODO done idempotently`
- `todo.open marks the matching TODO not done idempotently`
- `todo.done/open with malformed or unknown todo id returns -32602`
- `todo.delete removes the matching TODO and emits .refreshPaneToolbar`
- `todo.delete with unknown todo id returns -32602`
- `todo.clear-completed removes only done items and succeeds when none are
  completed`
- `todo command with no ctx.paneId returns -32602`

`send-keys`:

- `send-keys with text emits the surface-write effect (whatever Effect
  case is added in Step 5.5) targeting ctx.paneId`
- `send-keys with no ctx.paneId returns -32602`

Test idiom matches the existing `Update*Tests.swift` files.

### Protocol-library tests

`lib/DanTermProtocol/Tests/DanTermProtocolTests/EnvelopeTests.swift`:

- Object params round-trip — `{"a":1,"b":[2,3]}` decoded as `JSONValue.object`,
  re-encoded as the same byte string after key-sort.
- Notification request (no `id`) round-trips.
- Error response with arbitrary `data` field round-trips.
- Request with `params._ctx` decodes into `IpcRequestContext` correctly.
- A `Data`-typed regression test: assert `JSONValue` does NOT
  produce base64 when the inner shape is `{"x":1}`.

`SocketPathTests.swift`:

- `controlSocketPath(bundleId:)` produces the expected absolute path under
  `Caches/<bundle-id>/control.sock`.
- Two distinct bundle IDs produce distinct paths.

### IpcConnection / framing tests

`tests/IpcConnectionTests.swift` (Foundation-only, no sockets):

- One full line → one parsed request.
- Two full lines in one read → two parsed requests in order.
- Split frame: bytes `{"jsonrpc":` then `"2.0",...}\n` → one parsed
  request when the second chunk arrives.
- Line longer than 16 MiB → connection emits a JSON-RPC error and the
  reader raises a close-the-fd signal (no buffer growth past cap).

These run against an in-memory pipe pair, not a real socket.

### CLI / hello-handshake test

Owned by the protocol library or a small CLI test helper:

- CLI rejects a server hello with `protocol: 999` (writes an error to
  stderr and exits non-zero). Verifies the client side of the one-way
  handshake. There is no corresponding server-side "bad client hello"
  test because the server never expects a client hello.

### Installer tests

`tests/CLIPathInstallerTests.swift`:

- `install` into a writable temp target succeeds; symlink target equals
  the source path.
- `install` over a stale symlink replaces it.
- `install` from an `AppTranslocation`-shaped bundle URL refuses with
  `InstallerError.appTranslocated`.
- `install` failing with `EACCES` calls the injected privileged-runner
  closure and reports success when it returns.
- `uninstall` is idempotent.
- `isInstalled()` returns false when the target points elsewhere.

The `privilegedRunner` injection is what makes this testable without
actually invoking `osascript` admin elevation in CI.

### Integration test — shell-script smoke test

Add a new `scripts/tests/danterm-cli_test.sh` (the `scripts/tests/`
directory does not yet exist in this repo; create it as part of this
step):

1. Build dev app.
2. Launch dev app with `open -W` (or in a controlled background mode).
3. Inside a child shell with `DANTERM_SOCK` set:
   - `danterm ls | jq .tabs` returns at least one tab.
   - `danterm tab title test123 && [ "$(danterm tab title)" = "test123" ]`
     verifies set-then-get round-trip on the displayTitle path.
   - `todo_id="$(danterm todo add 'ship cli' | jq -r .id)"` returns a UUID,
     `danterm todo list | jq -e --arg id "$todo_id" '.[] | select(.id == $id)'`
     finds it, `danterm todo edit "$todo_id" 'ship cli v2'` updates text,
     `danterm todo done "$todo_id"` marks it done, and
     `danterm todo delete "$todo_id"` removes it.
   - `echo '{"jsonrpc":"2.0","id":1,"method":"unknown"}' | nc -U $DANTERM_SOCK`
     returns the hello line, then a `-32601` error response.
   - With the app quit: `danterm ls` exits 1 with stderr
     `danterm: DanTerm is not running`.

Wire the script into `justfile` as a new `test-cli` recipe (separate
from `just test`, which is pure-unit only). CI does not need to run
this — it requires a launched GUI.

### Manual verification checklist

- `just build-run`, open a pane, run `env | grep DANTERM` — four vars set.
- `danterm ls` from inside a pane prints valid JSON.
- `danterm tab title hello` updates the visible tab title immediately.
- `danterm tab title` (no arg) prints `hello`.
- `danterm pane split -v` opens a vertical split.
- `danterm todo add "follow up"` prints a JSON object with an id;
  `danterm todo list` includes it; `danterm todo done <id>` updates the
  toolbar count; `danterm todo delete <id>` removes it.
- Quit the app, run `danterm ls` from a leftover pane — exits 1 with
  stderr `danterm: DanTerm is not running`.
- Open the menu, click "Install `danterm` Command in PATH", enter admin
  password, run `which danterm` from a fresh non-DanTerm shell — points
  to `/usr/local/bin/danterm`.
- Re-launch dev build at the same time as prod build — both sockets
  exist (different bundle ids), `DANTERM_SOCK` in each instance points
  to the right one.
- Move the .app to a translocated path and try to install — gets a
  clear "move to /Applications first" alert.

## Risks and pitfalls (acknowledged in code comments where they apply)

- **Argv quoting**: `send-keys` text is passed as a `String` over the
  wire — never as a shell-escaped string concatenation (wezterm #5474).
- **No tty/escape-sequence channel**: do not accept commands via OSC even
  when convenient; it's the kitty #2084 trap.
- **Bound the reader**: 16 MiB max line, hard-fail otherwise (wezterm #7527).
- **Unset env over SSH**: shell integration must `unset DANTERM_PANE
  DANTERM_TAB DANTERM_SOCK` before any wrapper that hands off to ssh /
  docker / nested terminals — leaks point at the wrong pane (wezterm
  #5378). This belongs in a follow-up plan that ships shell integration
  scripts; out of scope for v1.
- **App Translocation**: refused at install time; logged at startup if
  detected.

## Out of scope (v2+)

- **Generic `action <name>` escape hatch.** Inspired by kitty's
  `kitten @ action`, but the repo has no central keybinding/action
  registry today. Designing one is its own design problem (action
  vocabulary, arg schemas, context rules, error semantics) and would
  bloat this plan. v1 ships explicit verbs only; the generic dispatch
  is reconsidered once the explicit-verb surface stabilizes and a
  registry refactor is on the table.
- Subscriptions / event streams (`bell.subscribe`, `pane.exit`,
  `tab.title.changed`). Reserved by the JSON-RPC `notification` form.
- Shell integration scripts (zsh/bash/fish wrappers that auto-unset env
  on SSH, set prompt indicators, etc.).
- Homebrew formula for the CLI.
- SSH-forwarded socket / cross-host control. Not needed; would require
  password auth (kitty `remote_control_password` model).
- `--launch` flag that auto-spawns the GUI on connect failure.

## Critical files reference

For execution:

- `/Users/dan/world/my-apps/danterm/Package.swift` — add `DanTermProtocol`
  library + test target + `danterm` executable target.
- `/Users/dan/world/my-apps/danterm/test.sh` — wire `DanTermProtocol`
  module into the manual swiftc invocation; call `swift test
  --filter DanTermProtocolTests` for the library tests.
- `/Users/dan/world/my-apps/danterm/app/Msg.swift:1-150` — add
  `.ipcRequest(reqId, method, params, context)` and deterministic
  `.setTodoDone(paneId, todoId, isDone)` for CLI TODO updates.
- `/Users/dan/world/my-apps/danterm/app/Effect.swift` — add
  `.ipcReply`/`.ipcError` and `.refreshPaneToolbar(paneId:)`.
- `/Users/dan/world/my-apps/danterm/app/Update.swift` — add IPC `// MARK:`
  section; handlers must use explicit `context` IDs, not
  `selectedTab(in:)`.
- `/Users/dan/world/my-apps/danterm/app/AppRuntime.swift:17` (model field),
  `:199` (`send(_:)`), `:244` (`perform(_:)`), `:246-254` (`createSurface` —
  env injection point). Mark class `@MainActor`.
- `/Users/dan/world/my-apps/danterm/app/ModelOperations.swift:331,341,585` —
  reuse existing `tabById(_:in:)`, `tabForPane(_:in:)`, and `toSnapshot(_:)`;
  no edits required here.
- `/Users/dan/world/my-apps/danterm/tests/TestHarness.swift:4-36` — add
  calls to the new test-suite functions in `TestRunner.main()`.
- `/Users/dan/world/my-apps/danterm/app/TerminalView.swift:45-124` — already
  accepts `envVars`, no change needed.
- `/Users/dan/world/my-apps/danterm/app/AppDelegate.swift:203-374`
  (`buildMenu`), insert near line 221.
- `/Users/dan/world/my-apps/danterm/.refs/cmux/Sources/App/CmuxCLIPathInstaller.swift`
  — port to `CLIPathInstaller.swift`. Source path resolves to
  `Contents/MacOS/danterm`, not `Contents/Resources/danterm`.
- `/Users/dan/world/my-apps/danterm/.refs/cmux/CLI/cmux.swift` — reference for
  raw POSIX socket connect pattern.
- `/Users/dan/world/my-apps/danterm/dev-build.sh`,
  `/Users/dan/world/my-apps/danterm/build-app.sh` — copy CLI to
  `Contents/MacOS/`.
- `.github/workflows/release-stable.yml` — sign nested `Contents/MacOS/danterm`
  before signing the outer bundle (TN2206).
