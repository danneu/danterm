# Plan: Centralized IPC error boundary in `handleIpcRequest`

## Context

`handleIpcRequest` in `lib/DanTermCore/Sources/DanTermCore/Update.swift` (~lines
1493-1907) dispatches every CLI/IPC method through a big `switch method`. Most
cases repeat the same error-handling preamble:

```swift
let paneId: PaneId
do {
    paneId = try resolveTargetPane(params: params, context: context, in: model)
} catch let error as IpcParamsError {
    return ipcInvalidParams(reqId, error.message)
} catch {
    return ipcInvalidParams(reqId, "bespoke fallback")   // unreachable
}
```

Two problems, one root cause:

1. **Duplication.** This `do { try resolve } catch IpcParamsError { ... } catch { ... }`
   shape repeats ~15x across the switch.
2. **Dead branches.** Every resolver/parser (`resolveTargetPane`,
   `resolveExplicitPane`, `resolveIpcTabId`, `resolveTabNewGroup`,
   `resolveTabNewTargetGroup`, `resolveExplicitGroup`, `parseOptionalBool`,
   `parseTabInsertPosition`, `parseInputEvent`) throws **only** `IpcParamsError`.
   The trailing generic `catch {}` is therefore runtime-unreachable in every
   resolver-only site — but it cannot simply be deleted, because Swift's untyped
   `throws` requires the `do/catch` to be exhaustive. So the dead code is forced
   to exist per-site.

The fix is to hoist error handling to a **single error boundary**: resolvers and
parsers just `throw`, and one `do/catch` translates the thrown error to a
`Command` reply. This removes both the duplication and all the dead branches at
once (the exhaustiveness obligation is satisfied once, centrally), and is more
idiomatic than 15 local conversions.

Investigation confirmed this is safe and contained:
- `handleIpcRequest` is the **sole** IPC dispatcher; `IpcParamsError` and
  `ipcInvalidParams` are `private` to `Update.swift`. No sibling pattern to unify.
- Only three error types reach the cases: `IpcParamsError`, `LaunchSpecParseError`
  (`paneSplit`/`tabNew` only, from `parseLaunchSpec` in DanTermProtocol), and JSON
  encode/decode errors in the `ls` case. `KeyModsDecodeError` is caught and
  rethrown as `IpcParamsError` inside `parseInputEvent`, so it never escapes.
- **Invariant (verified across all 16 cases):** every case completes all throwing
  validation/resolution *before* any model mutation. No case mutates then throws.
  Combined with `inout` copy-in/copy-out (callee mutations are written back on any
  scope exit — return *or* throw), converting a pre-mutation
  `return ipcInvalidParams(...)` into a `throw` is observationally identical.
- No test asserts any unreachable bespoke fallback message.

## Approach

### 1. Split into a throwing dispatcher + thin wrapper

Keep `handleIpcRequest(...) -> [Command]` (its caller, the `.ipcRequest` case in
`update`, is non-throwing — leave it untouched). Move the entire `switch method`
body into a new `private func dispatchIpc(...) throws -> [Command]` with the same
parameters, and make `handleIpcRequest` a thin boundary.

`dispatchIpc` is a new top-level function, so per the repo rule ("doc comments on
declarations" in `AGENTS.md`) it gets a `///` comment stating *why it exists* —
roughly: it carries the per-method IPC dispatch and is free to `throw`
`IpcParamsError`/`LaunchSpecParseError`, so its caller `handleIpcRequest` can be
the single non-throwing error boundary that translates those throws into
`Command` replies. (The existing `handleIpcRequest` has no `///` today; adding a
one-line `///` describing its new error-boundary role is a nicety, not required.)

```swift
private func handleIpcRequest(
    _ model: inout AppModel, reqId: UUID, method: String,
    params: JSONValue, context: IpcRequestContext, env: CoreEnv
) -> [Command] {
    do {
        return try dispatchIpc(&model, reqId: reqId, method: method,
                               params: params, context: context, env: env)
    } catch let error as IpcParamsError {
        return ipcInvalidParams(reqId, error.message)
    } catch let error as LaunchSpecParseError {
        return ipcInvalidParams(reqId, launchSpecErrorMessage(error))
    } catch {
        return [.ipcError(reqId: reqId, code: -32603, message: "internal error")]
    }
}
```

Notes:
- `Command.ipcError` is labeled — `.ipcError(reqId:code:message:)` (`Command.swift:47`).
- The two specific `catch` arms must precede the generic one.
- The generic `catch` reproduces the `ls` case's current `-32603` "internal error"
  behavior; it is reachable only via JSON encode/decode failure.

### 2. Transform each case (mechanical)

Inside `dispatchIpc`:
- **Collapse** each `do { x = try resolve(...) } catch ... catch ...` to a single
  `let x = try resolve(...)`. Fold any `let x: T` declaration that sat above the
  `do` into the inline binding.
- **Convert** each *reachable* structural guard
  `guard ... else { return ipcInvalidParams(reqId, "msg") }` to
  `guard ... else { throw IpcParamsError("msg") }`.
- **`ls`**: drop its local `do/catch`; the body becomes plain `try` (JSON errors
  route to the central `-32603`). Keep its `let snapshot/data/value` and the
  `.ipcReply` return.
- **`paneSplit` / `tabNew`**: drop the `catch LaunchSpecParseError` /
  `catch IpcParamsError` / generic arms entirely; `try parseLaunchSpec(...)`,
  `try parseOptionalBool(...)`, `try parseTabInsertPosition(...)`,
  `try resolveTabNewTargetGroup(...)` all propagate to the wrapper.
- **`default`**: unchanged — stays a plain
  `return [.ipcError(reqId: reqId, code: -32601, message: "method not found")]`.
  Normal returns bypass the `catch` arms, so unknown methods still yield `-32601`,
  never `-32603`.

### 3. Strings deleted vs. preserved

Only these strings vanish from the program entirely — each lives in an unreachable
generic catch and is asserted by **no** test:
`"invalid pane info params"`, `"invalid tab"` (tabRename + tabClose),
`"invalid launch"`, `"invalid group"`, `"invalid todo params"`.

Do **not** delete the reachable duplicates: `agentAttach` `"invalid agent session"`,
`themeSet` `"invalid theme params"`, `paneSplit` `"invalid pane split params"`,
`paneRead` `"invalid params"`, `todoAdd` `"invalid todo text"`,
`todoEdit`/`todoDone`/`todoOpen`/`todoDelete` `"invalid todo"`, and
`todoClearCompleted` `"no pane in context"` each also appear in a reachable
structural guard or are thrown by `resolveTargetPane`. Delete only the
generic-catch copy; the reachable copy survives (as a `throw`).

Reachable messages pinned by existing tests that must survive verbatim:
`"cannot close the last tab"`, `"pane must be a string"`, `"pane not found"`,
`"pane required"`, `"lines must be a positive integer"`, `"no pane in context"`,
`"mods must be an array"`, `"unknown key Bogus"`, `"unknown mod bogus"`.

## Out of scope (considered, deferred)

- **Typed throws (`throws(IpcParamsError)`) on the resolvers.** Would give a
  compile-time guarantee that resolvers can't throw anything else, but cascades
  into DanTermProtocol (`KeyMods.decode`, `parseLaunchSpec` would need typed
  throws too) for marginal benefit. The centralized boundary already eliminates
  the dead branches without it. A resolver that ever threw a non-`IpcParamsError`
  would surface as `-32603` "internal error" rather than silently as `-32602`,
  which is arguably more correct — and currently impossible anyway.
- **Named constants for `-32601`/`-32602`/`-32603`.** Centralization already
  reduces each code to a single literal site (`ipcInvalidParams` for `-32602`,
  the wrapper for `-32603`, `default` for `-32601`), so constants add little.
  `AppRuntime.swift` also uses `-32603`; unifying across modules is a separate
  concern.

## Files

- `lib/DanTermCore/Sources/DanTermCore/Update.swift` — the refactor (split +
  per-case transform).
- `lib/DanTermCore/Sources/DanTermCore/Command.swift` — reference only
  (`Command.ipcError` label shape).
- `lib/DanTermProtocol/Sources/DanTermProtocol/LaunchSpec.swift` — reference only
  (`LaunchSpecParseError`, `launchSpecErrorMessage`).
- `lib/DanTermCore/Tests/DanTermCoreTests/UpdateIpcTests.swift` — existing
  coverage; the regression gate (see below).

## Verification

This is a behavior-preserving refactor; the existing IPC test suite is the gate.

1. `swift build --package-path lib/DanTermCore` — catches the `.ipcError` label
   and any `let`-scoping slips from collapsing `do` blocks.
2. `swift test --package-path lib/DanTermCore --filter UpdateIpcTests` — pins the
   reachable `-32602` and `-32601` codes, the "fail before mutation" ordering for
   ~18 cases, and the load-bearing reachable messages. Green confirms behavior
   preserved for every path the suite exercises.
3. `just test` — full local gate (core + protocol + support + purity lint + shell
   self-tests) before commit.

**`-32603` is not behavior-covered, and we accept that.** `UpdateIpcTests` only
exercises the *successful* `ls` path; it has no `-32603` assertion (confirmed by
grep — the only `-32603` in DanTermCore is the `ls` internal-error literal itself,
`Update.swift:1509`). The refactor moves that serialization-failure `catch` into
the central generic boundary, preserving the same `-32603` "internal error"
behavior, but no test pins it. We deliberately do not add one: the path triggers
only on `JSONEncoder`/`JSONDecoder` failure over a valid snapshot, which has no
structure-insensitive trigger — forcing it would require a fault-injection seam
that contradicts the behavior-preserving goal. The `-32603` path is reviewed by
reading, not by test.

Optional test add (low value, only if desired): a garbage-params variant of the
existing unknown-method test asserting `-32601`, proving garbage methods never
route through the throwing path to `-32603`. Do **not** add tests asserting any
deleted unreachable string — that would couple tests to dead code.
