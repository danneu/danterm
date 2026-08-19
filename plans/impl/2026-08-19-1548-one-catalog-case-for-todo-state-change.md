# One catalog case for the todo state change

## Context

Audit finding IPC-3 (docs/scratch/2026-08-18-construction-audit.md, "IPC-3"),
verified against the current tree on 2026-08-19: all cited code is live and
unfixed. `IpcRequest.todoDone` and `.todoOpen` differ only by a boolean, and
they share one argument grammar with `.todoDelete`. Because they are separate
catalog cases with identical payloads, three places group them and then
re-switch to recover which one they had, each ending in a `preconditionFailure`
arm the compiler cannot prove unreachable:

- `lib/DanTermCore/Sources/DanTermCore/IpcDispatch.swift#dispatchIpc`
  (re-switch on `request` to derive `shouldBeDone`)
- `lib/DanTermProtocol/Sources/DanTermProtocol/IpcRequest.swift#decode`
  (grouped `.todoDone, .todoOpen, .todoDelete` arm with an inner
  `switch method`)
- `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift#parseTodoIdCommand`
  (takes an `IpcRequestMethod` selector and re-switches into a constructor)

A future case added to one of those groupings crashes the daemon or the CLI at
runtime instead of failing to build. IPC-1 and IPC-4 in the same audit are
written against the merged-case result, so this lands first.

## Decision

Make the variant a value in the payload instead of a tag branches must
translate back:

- Merge the two catalog cases into one
  `todoSetDone(owner: TodoOwner, todoId: TodoId, isDone: Bool)`.
  `todoDelete` stays its own case.
- Keep the two wire methods: `todo.done` decodes with `isDone: true`,
  `todo.open` with `false`, and the `method` projection derives the tag from
  `isDone`. `IpcRequestMethod` is unchanged.
- Ungroup `decode`'s three-way todo arm into separate case arms over a shared
  owner+id extraction, so no `default` over the full method enum survives.
- Change `parseTodoIdCommand` to take the request constructor
  `(TodoOwner, TodoId) -> IpcRequest` instead of a method enum.

Change sites beyond the three cited (compile breaks from the merged case's
third binding): `IpcRequest.params`, `IpcRequest.targetParameterKeys`,
`IpcRequest.method`, `IpcAuditDescriptor#auditTarget`, and the three
`parseTodo` call sites. Nothing outside `lib/DanTermProtocol` and
`lib/DanTermCore` constructs or matches these cases (verified by grep across
app, cli, ios). `Msg.setTodoDone` already carries the boolean, so `Msg` and
`update` are untouched. `integrations/danterm/SKILL.md` is unaffected: no
verb, flag, usage string, or output shape changes.

## Invariants

- I1. The external surface is byte-identical: wire methods, params objects,
  audit records, CLI usage strings, and replies. In particular `isDone` is
  never written into params -- the wire method carries it.
- I2. No todo request path retains a `default`/`preconditionFailure` arm:
  every switch over todo requests or methods is exhaustive by construction.
- I3. `todo.done` and `todo.open` stay two distinct wire methods; both are
  still produced by `IpcRequest.method`.

## Proof obligations

- PO1 (I1, I3): `IpcRequestTests.everyCLIRequestRoundTripsThroughCatalog`
  and `everyTargetingCatalogMethodRejectsAbsentTarget`, plus
  `CLIParserTests.todoStateMutationsParseExplicitPanes` / `...ParseTabs`,
  keep passing unchanged.
- PO2 (I1, dispatch semantics): the `UpdateIpcTests` todo family
  (`todoCommandFamilyUsesContextPane`, explicit-pane, tab-owner,
  malformed-pane, missing-target, unknown-id, and
  `everyTargetingMethodRejectsAbsentTarget`) keeps passing unchanged.
- PO3 (I2): `grep preconditionFailure` in IpcDispatch.swift, IpcRequest.swift,
  and CLIParser.swift shows the three todo arms gone (CLIParser's prefix-loop
  assert at its top is out of scope and remains).
- PO4 (I1, I3): a new test in `IpcAuditDescriptorTests` pins the todo state
  change's audit record, which nothing covers today. For a pane-owned request
  and a tab-owned one, in both states: `auditDescriptor.method` is `todo.done`
  when done and `todo.open` when open, and `target` equals exactly the owner
  field (`pane` or `tab`) plus `todoId`, each the lowercased UUID string.

Otherwise no new tests: this is a pure refactor, the deleted arms are
unreachable today, and no test may assert the enum's shape. Run PO1/PO2's
suites before touching code to establish the green baseline; PO4 is written
first against the current two cases and must stay green across the merge.

## Non-goals

- Collapsing `todo.done`/`todo.open` into one wire method (external CLI
  surface change).
- Touching `todoDelete` semantics, `Msg`, `update`, or the other
  `preconditionFailure` sites in these modules (CLIParser prefix loop,
  ModelOperations close-copy) -- different patterns, not this finding.

## Implementation discretion

- Whether `.todoSetDone` joins `.todoEdit`'s audit arm with a `_` binding or
  gets its own arm in `auditTarget`, and the exact shape of the shared
  owner+id extraction in `decode`.

## Verification

1. `swift test --package-path lib/DanTermProtocol`
2. `swift test --package-path lib/DanTermCore`
3. PO3 grep.
4. `bash ./dev-build.sh --no-install` to prove the app target (which compiles
   both modules same-module) still builds.
