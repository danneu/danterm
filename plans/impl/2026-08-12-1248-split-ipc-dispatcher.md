# Split the IPC dispatcher out of Update.swift

## Problem

`lib/DanTermCore/Sources/DanTermCore/Update.swift` (2,170 lines) holds two
subsystems behind the one-line header "Pure update function for DanTerm's
Elm-style state machine". Lines 1427-1852 (the `// MARK: - IPC Handlers`
region, ~420 lines) are the complete external IPC method dispatcher --
`handleIpcRequest`, `dispatchIpc`, and their private validation and
result-building helpers. That region is the whole API surface the planned
iOS thin client will consume and extend, but nothing in the file layout says
so: someone changing an IPC method has no reason to open Update.swift, and
someone reading the reducer scrolls past the JSON layer.

Evidence (verified 2026-08-12):

- Every symbol in the region is `private` and referenced only inside the
  region, with three cross-file calls: `handleIpcRequest` is called from the
  reducer's `.ipcRequest` arm (Update.swift:28), `appendTodo` from its
  `.addTodo` arm (Update.swift:1323), and the dispatcher calls
  `navigateToPane`, which also serves reducer-owned alert navigation.
- The reducer's `.ipcRequest` arm is already a one-line delegation to
  `handleIpcRequest`, so the split changes no control flow.
- Precedent for the boundary already exists: `IpcEntityEncoder.swift` and
  `PaneLifecycleIpcAdapter.swift` hold IPC translation outside Update.swift,
  and `ModelOperations.swift` is the established home for shared
  non-private model-mutation helpers (for example `removeAlertsForPane`).
- Origin: simplification-audit finding S50
  (docs/scratch/2026-08-11-simplification-audit.md).

## Decision

Move the entire `// MARK: - IPC Handlers` region of Update.swift into a new
file `lib/DanTermCore/Sources/DanTermCore/IpcDispatch.swift`, where
`handleIpcRequest` becomes the file's one internal entry point. Move
`appendTodo` to `ModelOperations.swift` as a shared (non-private) helper,
since both the reducer and the dispatcher call it. Keep `navigateToPane` in
Update.swift because its other callers are reducer handlers, and widen it to
internal for the dispatcher call. Update.swift keeps its one-line
`.ipcRequest` delegation.

Both files get real headers per the code-style rule:

- IpcDispatch.swift's header states that it holds the external IPC API
  surface, and restates the contract that changing this surface means
  updating `integrations/danterm/SKILL.md` in the same change.
- Update.swift's header states that the file holds the reducer and that the
  IPC dispatcher lives in IpcDispatch.swift.

No build-configuration change is needed: `app/DanTermCore` is a directory
symlink into `lib/DanTermCore/Sources/`, so the new file compiles into both
the package and the app automatically.

## Invariants

- I1: Pure refactor -- no observable behavior changes. For every IPC request,
  the dispatcher produces the same model mutations and the same ordered
  `Command` values before and after.
- I2: Visibility widens only where the cross-file calls require it:
  `handleIpcRequest` (called by the reducer's `.ipcRequest` arm in
  Update.swift), `appendTodo` (called by the reducer's `.addTodo` arm), and
  `navigateToPane` (called by the dispatcher) become internal. Every
  dispatcher helper stays `private`, now scoped to IpcDispatch.swift.
- I3: DanTermCore stays pure: the new file introduces no IO, AppKit, or
  engine dependency, and `scripts/core-purity-lint.sh` stays green.

## Proof obligations

- PO1 (I1): the existing suites -- `UpdateIpcTests`, `GoldenMasterTests`,
  and the rest of the DanTermCore tests -- pass with zero test-file edits.
  A refactor that forces a test edit is evidence it was not pure.
- PO2 (I2, I3): `just test` (which includes the purity lint and full build
  of both the package and the app target) passes.

## Non-goals

- S51 (phantom-typed `TodoId` and removal of the unreachable UUID guards in
  the todo dispatch cases) is a separate change; doing this move first gives
  it a clean target.
- No renames, signature changes, or behavior changes to any IPC method, and
  no changes to `DanTermProtocol`, `app/IpcServer`, or the CLI.

## Implementation discretion

- Exact placement of `appendTodo` within ModelOperations.swift and whether
  it gains a `///` comment beyond the code-style minimum.

## Verification

1. `swift test --package-path lib/DanTermCore` -- all tests pass with no
   test-file changes (PO1).
2. `just test` -- full gate including purity lint and app build (PO2).
