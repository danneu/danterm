# Add `tab new` position flags that mirror the `TabInsertPosition` enum

## Context

The `danterm tab new` CLI currently has no way to control where a new tab
lands in its group -- it always uses the `update` handler default
(`.afterSelected`), even though the internal `TabInsertPosition` enum
already supports `.atGroupEnd` (used by the Cmd-Shift-T menu item only).

We want agents to be able to opt into "after a specific tab" or "at end of
group" from the CLI without changing the default behavior. We're also
establishing a convention: **CLI position flags map 1:1 to enum cases**,
both in name and shape. That means adding one CLI flag per case (now and
in the future), not a single `--position <value>` enum flag.

Concrete asks:

- Add a new enum case `TabInsertPosition.afterTab(TabId)`.
- Add three mutually-exclusive CLI flags to `tab new`:
  - `--after-selected` (bool) -> `.afterSelected`
  - `--at-group-end` (bool) -> `.atGroupEnd`
  - `--after-tab <tab-id>` (string) -> `.afterTab(TabId)`
- Default (no flag set) keeps current behavior: `.afterSelected`.

## Design

### Enum change (`app/Msg.swift:27-30`)

Add a third case carrying the tab id:

```swift
enum TabInsertPosition {
    case afterSelected
    case atGroupEnd
    case afterTab(TabId)
}
```

Update the doc comment above the enum to mention the new case. The
default on `Msg.createTab(... position: TabInsertPosition = .afterSelected ...)`
at `app/Msg.swift:44` stays as-is.

### Handler arm (`app/Update.swift:72-82`)

Extend the existing `switch position` block with an `.afterTab(let id)`
arm. Find that tab id in the resolved target group and insert at
`idx + 1`. If it isn't in the target group, fall back to append --
this matches the `.afterSelected` fallback shape and keeps `update`
tolerant of internal Swift callers that may pass a ref id from a
different group. (The IPC path validates ref-in-group up front, so the
fallback should never trigger from CLI input -- see "IPC handler"
below.)

```swift
case .afterTab(let refTabId):
    if let refIdx = model.groups[targetGroupIndex].tabs.firstIndex(where: { $0.id == refTabId }) {
        model.groups[targetGroupIndex].tabs.insert(tab, at: refIdx + 1)
    } else {
        model.groups[targetGroupIndex].tabs.append(tab)
    }
```

### CLI parser (`lib/DanTermProtocol/Sources/DanTermProtocol/TabNewArgs.swift`)

`ParsedTabNew` is a `public struct` with a `public init(...)` consumed
by several `ParsedTabNew(group:, launch:, background:)` test call
sites in `TabNewArgsTests.swift`. To avoid churn, the new field and
its supporting enum must both be `public`, and the init must add the
new parameter at the end with a default value:

```swift
public enum ParsedTabPosition: Equatable {
    case afterSelected
    case atGroupEnd
    case afterTab(String)  // raw tab-id string; UUID validated server-side
}

public struct ParsedTabNew: Equatable {
    public let group: String?
    public let launch: LaunchSpec?
    public let background: Bool
    public let position: ParsedTabPosition?

    public init(
        group: String?,
        launch: LaunchSpec?,
        background: Bool = false,
        position: ParsedTabPosition? = nil
    ) {
        self.group = group
        self.launch = launch
        self.background = background
        self.position = position
    }
}
```

Defaulting `position` to `nil` keeps the eight existing
`ParsedTabNew(group:, launch:, ...)` call sites compiling unchanged.
`TabNewParseError` gains a new `case conflictingPositionFlags` (no
payload -- the message is composed in `CLIParser.swift`).

In the `parseTabNewArgs` loop, recognise the three new flags and
track the chosen `ParsedTabPosition?` in a local `var`. Setting it a
second time throws `TabNewParseError.conflictingPositionFlags`.
`--after-tab` uses the existing `value(after:)` helper to read its
argument (same pattern as `--group`/`--cmd`), so an empty value still
surfaces as `TabNewParseError.missingValue("--after-tab")`. The final
`return ParsedTabNew(...)` passes the tracked position through.

### CLI parse-error mapping (`lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift:84-110`)

`parseTabNewCommand` currently hard-codes its own usage string (line 91)
that's independent of `cli/main.swift`. Update it:

- Hoist the usage string into one local constant inside
  `parseTabNewCommand` that already includes the new position flags:
  `"usage: danterm tab new [--group <group-id>] [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--after-selected | --at-group-end | --after-tab <tab-id>]"`.
- Use that constant in both the existing `.missingValue` arm and a new
  `.conflictingPositionFlags` arm that emits a concrete message:
  `"--after-selected, --at-group-end, and --after-tab are mutually exclusive\n\(usage)"`.
- Leave the `.unknownFlag` / `.unexpectedArgument` arms returning their
  current short messages.

### CLI -> IPC mapping (`lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift:99-109`)

Normalize on the wire to a single key plus an optional companion:

```swift
switch parsed.position {
case .none: break
case .afterSelected:
    params["position"] = .string("afterSelected")
case .atGroupEnd:
    params["position"] = .string("atGroupEnd")
case .afterTab(let id):
    params["position"] = .string("afterTab")
    params["afterTabId"] = .string(id)
}
```

One wire key keeps things normalized and mirrors the enum tag directly;
the companion `afterTabId` only appears for the `afterTab` variant.

### IPC handler (`app/Update.swift:1563-1598`)

Add a `parseTabInsertPosition(_ object:) throws -> TabInsertPosition?`
helper next to the other private parsers in `Update.swift` (~line 1856
where `parseTabId` lives). It receives the already-unwrapped
`[String: JSONValue]` object (matching the surrounding handler style)
and validates strictly, in this order, before mutation:

1. If both `position` and `afterTabId` are absent -> return `nil`
   (preserves current default of `.afterSelected`).
2. If `afterTabId` is present but `position` is absent or its string
   value is not `"afterTab"` ->
   `throw IpcParamsError("afterTabId is only valid when position == \"afterTab\"")`.
3. If `position` is present but not a string ->
   `throw IpcParamsError("position must be a string")`.
4. If the `position` string is not one of `"afterSelected"`,
   `"atGroupEnd"`, `"afterTab"` ->
   `throw IpcParamsError("position must be one of: afterSelected, atGroupEnd, afterTab")`.
5. For `"afterSelected"` / `"atGroupEnd"` -> return the matching case.
6. For `"afterTab"`: if `afterTabId` is missing ->
   `throw IpcParamsError("position=afterTab requires afterTabId")`;
   if present but not a string ->
   `throw IpcParamsError("afterTabId must be a string")`;
   if string but not a valid UUID (`parseTabId` returns nil) ->
   `throw IpcParamsError("afterTabId is not a valid tab id")`.
   Return `.afterTab(tabId)`.

This helper validates shape only -- it does not check that the ref tab
exists in the model. That happens in the position-aware target
resolution below, so that "ref not found" and "ref in wrong group"
errors share one code path.

#### Position-aware target group resolution

Replace the unconditional call to `resolveTabNewGroup` with a small
dispatch that depends on the parsed `TabInsertPosition?`:

- For `.afterTab(refId)`:
  - Look up the ref via `tabById(refId, in: model)`. If nil ->
    `throw IpcParamsError("position.afterTabId not found")`.
  - Resolve the ref's group via `groupForTab(refId, in: model)`.
  - If the caller passed an explicit `group` param, parse it and
    require it to equal the ref's group; otherwise
    `throw IpcParamsError("position.afterTabId is not in the requested group")`.
  - If no explicit `group`, use the ref's group as the target.
  - Pane context is ignored for `.afterTab` -- the ref id is a stronger
    signal than `$DANTERM_PANE`, and this lets `danterm tab new
    --after-tab <id>` succeed from outside a danterm pane.
- For `.afterSelected`, `.atGroupEnd`, and `nil`: keep the existing
  `resolveTabNewGroup(params:context:in:)` logic untouched (explicit
  `--group` first, then pane context, then `IpcParamsError("no group in context")`).

Thread the resulting `TabInsertPosition?` into the existing
`.createTab(...)` call -- only pass `position:` when non-nil so the
default stays in one place:

```swift
let position = try parseTabInsertPosition(object)
let groupId = try resolveTabNewTargetGroup(position: position, params: params, context: context, in: model)
// ... existing launch / background parsing ...
let createTabMsg: Msg = if let position {
    .createTab(inGroupId: groupId, position: position, launch: effectiveLaunch, background: background)
} else {
    .createTab(inGroupId: groupId, launch: effectiveLaunch, background: background)
}
let effects = update(&model, createTabMsg)
```

`resolveTabNewTargetGroup` is the new dispatch wrapper; it delegates to
the existing `resolveTabNewGroup` for the non-`.afterTab` cases. All
new error paths return `ipcInvalidParams` and must complete before any
state mutation in `update`.

### Help text (`cli/main.swift:30`)

Update the `tab new` usage line to include the new flags:

```
tab new [--group <group-id>] [--cmd <s>] [--cwd <p>] [--title <s>] [--background]
        [--after-selected | --at-group-end | --after-tab <tab-id>]
```

## Files touched

- `app/Msg.swift` -- add `.afterTab(TabId)` case + doc.
- `app/Update.swift` -- new handler arm, `parseTabInsertPosition`
  helper, position-aware `resolveTabNewTargetGroup` wrapper,
  `Methods.tabNew` wiring.
- `lib/DanTermProtocol/Sources/DanTermProtocol/TabNewArgs.swift` -- new
  flag parsing, `ParsedTabPosition`, new `.conflictingPositionFlags`
  error case.
- `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift` -- map
  `parsed.position` to `params["position"]` (+ `afterTabId`); hoist the
  `tab new` usage string and handle `.conflictingPositionFlags`.
- `cli/main.swift` -- top-level usage string for `tab new`.
- Tests below.

## Tests (TDD)

Write failing tests first, then implement.

1. **Update handler** (`tests/UpdateTabTests.swift`, mirror existing
   afterSelected/atGroupEnd coverage):
   - `.afterTab(ref)` with `ref` in the target group inserts immediately
     after `ref`.
   - `.afterTab(ref)` with `ref` in a different group appends to the
     target group (fallback).
   - `.afterTab(ref)` with an unknown `ref` id appends to the target
     group.

2. **CLI parser** (`lib/DanTermProtocol/Tests/DanTermProtocolTests/CLIParserTests.swift`):
   - `--after-selected` -> `params["position"] == .string("afterSelected")`.
   - `--at-group-end` -> `params["position"] == .string("atGroupEnd")`.
   - `--after-tab <uuid>` -> `params["position"] == .string("afterTab")`
     and `params["afterTabId"] == .string(<uuid>)`.
   - No position flag -> neither `position` nor `afterTabId` is in
     `params`.
   - Two position flags (e.g. `--after-selected --at-group-end`) ->
     `parseCLI` throws `CLIParseError` whose message contains
     "mutually exclusive" and the full updated `tab new` usage line
     (asserts the new usage text is wired through).
   - `--after-tab` without an argument -> `parseCLI` throws
     `CLIParseError` whose message starts with `usage: danterm tab new`
     and contains `--after-tab` (asserts `.missingValue` arm uses the
     hoisted usage constant, not the stale one).

3. **IPC handler** (`tests/UpdateIpcTests.swift`):
   - Valid `position: "afterTab"` + `afterTabId` (no `group`) lands the
     new tab after the referenced tab, in the ref's group, even when
     the request has no pane context. Assertions (scoped, not
     full-model -- a successful `createTab` legitimately adds a pane
     and updates selection):
     - The target group's `tabs.map(\.id)` equals the previous list
       with the new tab id inserted at `refIdx + 1`.
     - Every other group's `tabs.map(\.id)` is byte-identical to its
       pre-call value.
     - One new entry was added to `model.panes` and it belongs to the
       new tab's root leaf.
     - `model.selectedTabId` is the new tab id (the request was not
       `background`).
   - Valid `position: "afterTab"` + `afterTabId` + matching `group`
     succeeds; tab lands after the ref (same scoped assertions).
   - `position: "afterTab"` + `afterTabId` + `group` pointing at a
     *different* group -> `ipcInvalidParams`, no mutation
     (groups + selection unchanged).
   - `position: "afterTab"` + `afterTabId` referring to a deleted /
     unknown tab id -> `ipcInvalidParams`, no mutation.
   - `position: "afterTab"` without `afterTabId` -> `ipcInvalidParams`,
     no mutation.
   - `position: "afterTab"` with non-string `afterTabId` (e.g. number)
     -> `ipcInvalidParams`, no mutation.
   - `position: "afterTab"` with non-UUID string `afterTabId` ->
     `ipcInvalidParams`, no mutation.
   - Lone `afterTabId` (no `position` key) -> `ipcInvalidParams`, no
     mutation.
   - `position` set to a non-string JSON value (e.g. number) ->
     `ipcInvalidParams`, no mutation.
   - Unknown `position` string (e.g. `"middle"`) -> `ipcInvalidParams`,
     no mutation.
   - `afterTabId` with `position == "afterSelected"` ->
     `ipcInvalidParams`, no mutation.

   For every error case above, assert the reply is `ipcInvalidParams`
   *and* a model-equality check before/after the call -- this catches
   any future drift where validation moves below a mutation.

4. **Smoke test** (`scripts/tests/danterm-cli_test.sh`):
   - Add one line that creates a tab with `--at-group-end` and asserts
     the JSON reply still has `.tab.id` (parity with the existing
     `--group` smoke test). Skip the `--after-tab` case here -- the
     IPC + parser tests cover the variant, and the smoke test only
     needs to prove the new flag path round-trips.

## Verification

- `just test` -- all new and existing unit tests pass.
- `just build` -- Swift compiles cleanly (the enum gains a case, so the
  exhaustive `switch position` would have failed if not updated).
- `bash scripts/tests/danterm-cli_test.sh` -- smoke test passes.
- Manual sanity in a `just build-run` session:
  - `danterm tab new` -- lands after selected (unchanged).
  - `danterm tab new --at-group-end` -- lands at end of current group.
  - `danterm tab new --after-tab <id-in-another-group>` -- lands in
    that other group, right after the ref tab (proves the
    position-aware group resolution).
  - `danterm tab new --group <gid> --after-tab <id-in-different-group>`
    -- fails with `position.afterTabId is not in the requested group`.
  - Run `danterm tab new --after-tab <id>` from a shell *outside* any
    danterm pane (no `$DANTERM_PANE`) -- succeeds, lands after the ref.
  - `danterm tab new --at-group-end --after-selected` -- fails with the
    conflicting-flags error and prints the new usage line.
