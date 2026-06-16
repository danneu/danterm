# Unify IPC target resolution (pane / tab / group)

## Context

DanTerm's IPC command surface resolves "which pane/tab/group does this command
act on?" through a scatter of ad-hoc helpers in
`lib/DanTermCore/Sources/DanTermCore/Update.swift`. They diverge in three ways
that the recent "centralize/unify IPC" refactors (e.g. `cd6003a` centralize IPC
error boundary, `479f5c6` unify key wire-name mapping) have not yet reached:

- **Field name.** Every pane command reads `params["pane"]` except `pane.focus`,
  which alone reads `params["paneId"]`.
- **Error vocabulary.** The same "resolve an explicit pane id" step is hand-rolled
  three ways: `resolveExplicitPane` ("pane must be a string" / "pane not found"),
  `pane.read` ("pane required" for both missing *and* non-string / "pane not
  found"), and `pane.focus` (a single "invalid pane id" for everything).
- **Indirection.** `resolvePaneSplitTarget` and `resolveSendKeysPane` are pure
  pass-throughs to `resolveTargetPane` that exist only to carry comments, and
  `todo.list` has an unreachable `"no pane in context"` guard after the pane is
  already validated.

Most commands *already* converge on the vocabulary `<entity> must be a string` /
`<entity> not found` / `no <entity> in context` (via `resolveTargetPane`,
`resolveIpcTabId`, `resolveTabNewGroup`). The goal is to make that the *single*
path for all three entities.

**Outcome:** one generic resolver behind thin per-entity wrappers, a uniform
error vocabulary, a uniform wire field name per entity, and the per-command
"must the caller name an explicit target?" policy expressed as an intentional,
legible flag rather than scattered hand-rolled code.

**Scope decisions (settled with the user):**
- Behavior-**preserving** refactor. `pane.focus` and `pane.read` stay
  explicit-required (no context fallback), expressed via `requireExplicit: true`.
  No CLI-parser or SKILL.md behavior changes. The flag leaves a clean one-line
  seam if a self-default shorthand is ever wanted later.
- `pane.focus`'s **forward** wire field becomes `pane` (CLIParser emits `pane`)
  so the generic resolver needs no per-command field override. `paneId` is
  **retained as a deprecated input alias** rather than removed: the wire protocol
  is a semi-public contract, not a purely internal field. `DanTermProtocol`
  exposes public `JsonRpcRequest` / `JsonRpcResponse` / `Methods` ("JSON-RPC 2.0
  envelopes shared by the DanTerm app and CLI", `Envelope.swift:1`), and the
  codebase explicitly recognizes "direct IPC clients that bypass the CLI parser"
  (`KeyTokensTests.swift:142`). So a raw client still sending `params["paneId"]`
  must keep working. The `pane.focus` branch normalizes a legacy `paneId` to
  `pane` before calling the generic resolver, keeping the resolver clean; the
  alias is the one tolerated wart, contained to that branch and documented as
  deprecated. The user-facing `danterm pane focus <id>` CLI surface is unchanged.

## Design

### Generic core + three thin wrappers

Add near the existing resolvers (~`Update.swift:1883`), replacing
`resolveTargetPane` / `resolveExplicitPane`:

```swift
// Unifies explicit-vs-context target resolution for pane/tab/group IPC params.
// An explicit field is authoritative: malformed or unknown values fail rather
// than falling back to context. An absent field falls back to context when
// allowed, or errors as required. `entity` doubles as the wire field name and
// the error-message noun, so the vocabulary is identical across entities.
private func resolveTarget<ID>(
    entity: String,                 // "pane" | "tab" | "group"
    params: JSONValue,
    parse: (String) -> ID?,         // raw string -> typed id (no existence check)
    exists: (ID) -> Bool,           // typed id -> live in the model
    contextID: () -> ID?,           // validated context fallback, or nil
    requireExplicit: Bool           // true => no context fallback (focus, read)
) throws -> ID {
    if case .object(let object) = params, let raw = object[entity] {
        guard case .string(let str) = raw else {
            throw IpcParamsError("\(entity) must be a string")
        }
        guard let id = parse(str), exists(id) else {
            throw IpcParamsError("\(entity) not found")
        }
        return id
    }
    if requireExplicit { throw IpcParamsError("\(entity) required") }
    if let id = contextID() { return id }
    throw IpcParamsError("no \(entity) in context")
}
```

Wrappers (the only places naming the per-entity closures):

```swift
private func resolvePane(params:context:in:requireExplicit:Bool = false) throws -> PaneId
    // parse: parsePaneId, exists: { model.pane($0) != nil },
    // contextID: { resolveIpcPaneId(context, in: model) }

private func resolveTab(params:context:in:requireExplicit:Bool = false) throws -> TabId
    // parse: parseTabId, exists: { tabById($0, in: model) != nil },
    // contextID: { parsePaneId(context.paneId).flatMap { tabForPane($0, in: model)?.id } }

private func resolveGroup(params:context:in:requireExplicit:Bool = false) throws -> GroupId
    // parse: parseGroupId, exists: { id in model.groups.contains { $0.id == id } },
    // contextID: pane -> tabForPane -> groupForTab(tab.id)?.id
```

These reuse existing primitives: `model.pane`, `tabById`, `tabForPane`,
`groupForTab` (`ModelOperations.swift`), `resolveIpcPaneId`, and the
`parsePaneId`/`parseTabId`/`parseGroupId` helpers. Each `contextID` closure
replicates the *exact* fallback path the entity uses today, so malformed `_ctx`
(non-UUID) and orphan-context-pane (valid UUID, absent from all trees) still
error with `-32602` before any mutation.

### Call-site mapping (all in `dispatchIpc`)

| Method(s) | Wrapper call |
|---|---|
| pane.info, agent.attach, theme.set, pane.split, pane.input, todo.* (all 7) | `resolvePane(params:context:in:)` |
| pane.focus, pane.read | `resolvePane(params:context:in:, requireExplicit: true)` |
| tab.rename, tab.close | `resolveTab(params:context:in:)` |
| tab.new (group) | `resolveGroup(...)` via `resolveTabNewGroup` |

- **pane.focus**: replace the inline guard with a legacy-alias normalization --
  copy `params["paneId"]` into `pane` only when `pane` is absent (`pane` wins if
  both are present), preserving the value verbatim -- then call
  `resolvePane(..., requireExplicit: true)`, which reads `params["pane"]`. Pair
  with `CLIParser.swift:59` -> `["pane": .string(args[2])]` (the forward form). A
  non-string legacy `paneId` flows through and yields `"pane must be a string"`,
  which is acceptable for a deprecated alias.
- **pane.read**: replace only the two pane guards with one
  `resolvePane(..., requireExplicit: true)`; keep the `object` destructure and the
  entire `lines` validation block unchanged.
- **resolveTabNewTargetGroup** (the afterTab/group cross-check) stays as a
  composition *above* the generic resolver: its non-afterTab path calls
  `resolveGroup`; inside `.afterTab`, when `params["group"]` is present, validate
  it with `resolveGroup(...)` (the field-present branch is identical regardless of
  `requireExplicit`) and cross-check `== refGroup.id`.

### Cleanup folded in

- Delete the pure pass-throughs `resolvePaneSplitTarget`, `resolveSendKeysPane`,
  and the subsumed `resolveTargetPane`, `resolveExplicitPane`, `resolveIpcTabId`,
  `resolveExplicitGroup`.
- `todo.list`: drop the unreachable guard; `let todos = model.pane(paneId)?.todos ?? []`.

## Files

- `lib/DanTermCore/Sources/DanTermCore/Update.swift` — resolver core + wrappers,
  all call sites, deletions, dead-guard removal.
- `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift:59` — `paneId` -> `pane`.
- `lib/DanTermCore/Tests/DanTermCoreTests/UpdateIpcTests.swift` — test migrations (below).
- `lib/DanTermProtocol/Tests/DanTermProtocolTests/CLIParserTests.swift` — new
  `pane focus` param-shape test (none exists today).

## Test migrations

Verified scope (the bulk of the ~80 targeting tests assert only `error.code ==
-32602` and are untouched):

- **Wire-field flip `paneId` -> `pane`, no string change** (4 success-path tests):
  `paneFocusSelectsTabAndRequestsFirstResponder`,
  `paneFocusRepliesWithSameTabFocusedSync`,
  `paneFocusPreservesPopoverOnSameTabFocus`,
  `paneFocusClearsTargetPaneAlertsInFocusMode`.
- **Error-string change** (1 test): `paneReadNonStringPaneParamErrors` —
  non-string now yields `"pane must be a string"` (was `"pane required"`). Missing
  stays `"pane required"`; unknown stays `"pane not found"`.
- **New** (spec-first): `pane.focus` explicit-required error cases
  (`"pane required"` / `"pane must be a string"` / `"pane not found"`) — note
  `"invalid pane id"` is asserted by **zero** existing tests. Plus a CLIParser test
  asserting `parseCLI(["pane","focus","P1"]).params["pane"] == .string("P1")` and
  `params["paneId"] == nil`.
- **New** (back-compat, `UpdateIpcTests`): a `pane.focus` request carrying the
  legacy `params["paneId"]` (and no `pane`) still focuses the pane — guards the
  deprecated input alias for direct IPC clients. Also assert that `pane` wins when
  both `pane` and `paneId` are present.
- **New** (message contract, `UpdateIpcTests`): one table-driven test over `tab`
  and `group` pinning the uniform vocabulary on explicit targets — non-string ->
  `"<entity> must be a string"`, unknown UUID -> `"<entity> not found"`, and
  absent-with-empty-context -> `"no <entity> in context"`. Today the tab/group
  malformed-target tests assert only `-32602` (e.g. `UpdateIpcTests.swift:290`
  tab.rename, `:467` tab.close, `:869` tab.new group), leaving these strings
  unpinned; the test passes against the current code, so it locks the contract
  *before* the migration and then guards it against regression.
- **Unchanged / do not touch**: all `pane.input` / `theme.set` / `todo.*` /
  `tab.*` `-32602`-only assertions (behavior preserved); the
  `IpcRequestContext.paneId` `_ctx` references in `EnvelopeTests.swift` (a
  different field).

## Risks

- **Present-but-null explicit field** (`pane: null`): stays in the explicit branch
  (`object[entity]` is non-nil for `.null`) -> `"<entity> must be a string"`, no
  fallback. Identical to today.
- **`requireExplicit` default `false`**: a forgotten flag silently re-enables
  fallback for focus/read. Mitigated by passing `true` explicitly at both sites
  and by the migrated focus/read tests.
- **pane.read `lines` independence**: keep the `lines` block byte-for-byte; only
  pane resolution changes.
- **agent.attach** silently joins the `resolvePane` family — its existing context
  test must still pass (valid context pane, no explicit field -> fallback path).
- **Legacy `paneId` alias** (`pane.focus`): the normalization must copy into `pane`
  only when `pane` is absent (forward form wins) and preserve the JSON value
  verbatim, so the resolver's type/existence validation and its `pane`-worded
  errors still fire. Covered by the new back-compat test. This is the only wire
  field carrying a deprecated alias; tab/group have no legacy field to preserve.

## TDD sequence (strict failing-test-first)

1. **Protocol**: add failing CLIParser `pane focus` test -> edit `CLIParser.swift:59`. Green.
2. **pane.focus**: flip the 4 focus tests' wire field to `pane`, add the 3
   explicit-required error tests, and add the legacy-`paneId`-alias back-compat
   test (fail) -> add `resolveTarget` core + `resolvePane`, rewrite the
   `pane.focus` case with the alias normalization + `requireExplicit: true`. Green.
3. **pane.read**: flip `paneReadNonStringPaneParamErrors` to `"pane must be a
   string"` (fail) -> route `pane.read` through `resolvePane(..., requireExplicit:
   true)`, keep `lines`. Green.
4. **Remaining pane consumers** (info, agent.attach, theme.set, split, input,
   todo.*) -> `resolvePane`; delete `resolveTargetPane`, `resolveExplicitPane`,
   `resolvePaneSplitTarget`, `resolveSendKeysPane`. No test changes. Green.
5. **tab + group message contract**: first add the table-driven tab+group
   message-contract test (non-string / unknown / absent-with-empty-context -> the
   uniform strings); it passes against current code, locking the contract before
   any routing change.
6. **tab**: add `resolveTab`, route rename/close, delete `resolveIpcTabId`. Message
   test + tab suites stay green.
7. **group**: add `resolveGroup`, rewrite `resolveTabNewGroup` + the
   `resolveTabNewTargetGroup` cross-check, delete `resolveExplicitGroup`. Green.
8. **Dead guard**: simplify `todo.list`. Green.

## Verification

- `swift test --package-path lib/DanTermProtocol --filter DanTermProtocolTests`
- `swift test --package-path lib/DanTermCore --filter UpdateIpcTests` (then full
  core suite, incl. any GoldenMaster/Snapshot suites, to confirm no incidental
  wire drift).
- `just test` (local gate: protocol + core + support + purity lint + shell self-tests).
- Manual smoke (optional, after `just build-run`): from inside a DanTerm pane,
  confirm `danterm pane focus <id>`, `danterm pane read --pane <id>`,
  `danterm pane info` (context fallback), and a no-target `danterm pane focus`
  error message read as expected.
