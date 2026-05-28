# Plan: Introduce `CoreEnvironment` to DanTermCore

## Context

The test-system migration landed (`plans/impl/2026-05-28-modernize-danterm-test-system.md`)
and the pure core now lives at `lib/DanTermCore/Sources/DanTermCore/`, gated in CI
via Swift Testing in a nested SwiftPM package. The migration exited with **one**
production-source touch -- R2's defaulted `recoveryDir: URL = recoveryDirectoryURL()`
parameter on the four session-lock helpers in `Persistence.swift` -- because its
non-goals were deliberately disciplined.

That leaves the core's last ambient-dependency leaks in place. `update()` is
advertised as pure and is the basis for every test, but a fresh grep shows:

- **21 nondeterministic identity sources.** `TypedId<Tag>.init()`
  (`Model.swift:14`) calls `UUID()` directly, and that no-arg init is invoked
  15 times inside `update()` and `ModelOperations` (`Update.swift:35,36,165,289,
  379,728,758,940,1067`; `ModelOperations.swift:143,270`; plus four snapshot-decode
  mints at `Model.swift:428,445,558,590`). Six further direct `UUID()` calls
  appear at `Update.swift:1210,1336,1699`, `ModelOperations.swift:738`, and
  `IpcConnection.swift:50`.
- **4 wall-clock reads.** `Date()` at `Update.swift:729,759,2475` (alert
  `createdAt` + notification throttle) and `Persistence.swift:281`
  (`SessionLock.startedAt`).
- **R2's defaulted `recoveryDir:` param** is scattered across four functions
  (`Persistence.swift:265,280,290,298`) rather than one seam.

The consequence: `update(&model, msg)` is not referentially transparent.
Identical input + identical Msg produces different output every run (different
UUIDs, different `createdAt`). This blocks two specific wins:

1. **Full-tree golden-master assertions** via `expectNoDifference` -- the diff
   utility the migration just adopted. Today tests must cherry-pick fields
   modulo IDs; with determinism they can diff the whole `AppModel`.
2. **Reusability** -- a state machine that mints random UUIDs internally cannot
   be driven reproducibly by a replay tool, a fuzzer, or any host outside the
   app.

**Intended outcome:** one injected `CoreEnv` value carries `newId`/`now`/
`recoveryDir`; `update()` and the session-lock helpers take it with `.live` as
the default; production behavior is unchanged; tests can inject a deterministic
env and assert on whole models. R2's per-function defaulted param is absorbed
into the same env.

## Goals / non-goals

**Goals**
- `update(&model, msg, env: .live)` produces bit-for-bit identical output given
  identical input + env. No `UUID()`/`Date()` calls survive on the
  `update()` path.
- R2 is retired: the four session-lock helpers take `env:` instead of
  `recoveryDir:`; `CheckpointTests` migrates to env-based injection.
- Add one golden-master test that drives a fixed `[Msg]` sequence under a
  deterministic env and asserts the full output `AppModel` with
  `expectNoDifference`. That test is the proof the seam holds; any future
  stray `UUID()`/`Date()` inside `update()` breaks it with a readable diff.
- Behavior-preserving with `.live` defaults at every entry point. Production
  callers (`AppRuntime.send`) need no changes.

**Non-goals**
- No env-threading through snapshot decode (`Model.swift:428,445,558,590`).
  Hand-authored init-file entries without ids getting fresh UUIDs is a
  user-facing affordance, not a state-machine input. Document the intent
  with a `// MARK:` comment and leave it.
- No env on `IpcConnection.init`'s default `UUID()` (`IpcConnection.swift:50`).
  Connection identity for a Cocoa-adjacent pipe; off the decision surface.
- No env on `ProcessInfo.processIdentifier` (`Persistence.swift:281`).
  Informational, not control-flow.
- No env on `FileManager.default.contents(atPath:)` in `DanTermConfig.swift:34`
  or `ThemeColorParser.swift:67`. Caller supplies the path; not nondeterminism.
- No test-body refactors. Existing tests mint IDs in fixture code via the no-arg
  `TypedId()` form and capture them locally; that pattern keeps working.

## Design

### `CoreEnv` -- one struct, three closures

New file `lib/DanTermCore/Sources/DanTermCore/CoreEnvironment.swift`:

```swift
// Injectable environment for the pure core's nondeterministic edges:
// fresh IDs (UUID), wall-clock (Date), and the on-disk recovery directory.
// Production callers take `.live`, which mirrors today's free-function
// defaults (UUID(), Date(), recoveryDirectoryURL()) and is the default
// argument on every public seam, so behavior is preserved by construction.
// Tests construct a deterministic env (sequenced IDs, frozen clock, per-test
// temp recovery dir) and pass it explicitly, enabling full-tree equality
// assertions via expectNoDifference.
import Foundation

struct CoreEnv {
    var newId: () -> UUID
    var now: () -> Date
    var recoveryDir: () -> URL

    static let live = CoreEnv(
        newId: { UUID() },
        now: { Date() },
        recoveryDir: { recoveryDirectoryURL() }
    )
}
```

**Note on the closure wrappers.** Each closure exists for a real reason --
this is not stylistic. `recoveryDirectoryURL(bundleId: String =
Bundle.main.bundleIdentifier ?? "com.danneu.danterm") -> URL`
(`Persistence.swift:230`) has type `(String) -> URL` as a function value
because Swift function references do not erase defaulted parameters --
writing `recoveryDir: recoveryDirectoryURL` is a type error. Wrapping in
`{ recoveryDirectoryURL() }` lets the default `bundleId` fire at the call
site. `UUID.init` and `Date.init` are also overloaded
(`UUID.init?(uuidString:)`, `Date.init(timeIntervalSince1970:)`, etc.), so
the same closure pattern is used for symmetry and to keep overload
resolution out of the type signature.

Threading is **explicit**, not `@TaskLocal`: dependencies appear in signatures,
matching the codebase's "visible data, pure deciders, no closures-in-commands"
philosophy and the shape R2 already established. The cost is ~25 mechanical
edits inside one module; the win is no hidden ambient state and no risk of
losing the env across a future Combine/dispatch boundary.

### Typed ID construction -- keep no-arg, mint explicitly from env

`Model.swift:12-16` today:

```swift
struct TypedId<Tag>: Hashable, RawRepresentable, Codable {
    let rawValue: UUID
    init() { self.rawValue = UUID() }
    init(rawValue: UUID) { self.rawValue = rawValue }
}
```

After:

```swift
struct TypedId<Tag>: Hashable, RawRepresentable, Codable {
    let rawValue: UUID
    init() { self.rawValue = UUID() }                  // unchanged
    init(rawValue: UUID) { self.rawValue = rawValue }  // unchanged
}
```

The no-arg form survives so test fixtures (`TestSupport.makeModel`,
`makeMruModel`) and snapshot-decode mints keep working unchanged. Inside
`update()` and helpers it calls, every env-backed mint uses the existing
raw-value initializer explicitly via the typealias -- e.g.
`PaneId(rawValue: env.newId())`, `TabId(rawValue: env.newId())`. This keeps
`CoreEnv` at call-site boundaries instead of making `TypedId` know about the
whole environment.

### `update()` -- defaulted env parameter

`Update.swift:6` today:

```swift
@discardableResult
func update(_ model: inout AppModel, _ msg: Msg) -> [Command] {
```

After:

```swift
@discardableResult
func update(_ model: inout AppModel, _ msg: Msg, env: CoreEnv = .live) -> [Command] {
```

`AppRuntime.send` picks up `.live` for free. 19 recursive `update(&model, ...)`
self-calls inside `Update.swift` (lines 106, 125, 131, 225, 774, 907, 943,
1075, 1395, 1401, 1487, 1502, 1554, 1592, 1728, 1753, 1777, 1791, **2332**)
forward `env: env`. **Forwarding is mandatory at every recursive site** -- a
missed forward silently uses `.live`. Three independent gates catch a missed
forward: (1) the Phase 5 golden-master snapshot diffs on any mint-bearing
path, (2) the grep gate at PR time (see Verification), and (3) the
compiler -- the private helpers that recurse (`handleIpcRequest`,
`navigateToPane`) take `env: CoreEnv` **required** (no `.live` default), so a
missed forward at any caller is a build error. `throttledNotification` takes a
concrete `Date` from its caller instead of the whole env.
Only the public surface -- top-level `update()` and the four session-lock
helpers in `Persistence.swift` -- carries `= .live` for behavior preservation
at production call sites.

### Session-lock helpers -- retire R2's `recoveryDir:` for `env:`

`Persistence.swift:265,280,290,298` today (post-R2):

```swift
func sessionLockURL(recoveryDir: URL = recoveryDirectoryURL()) -> URL
func writeSessionLockFile(recoveryDir: URL = recoveryDirectoryURL())
func readSessionLockFile(recoveryDir: URL = recoveryDirectoryURL()) -> SessionLock?
func deleteSessionLockFile(recoveryDir: URL = recoveryDirectoryURL())
```

After:

```swift
func sessionLockURL(env: CoreEnv = .live) -> URL
func writeSessionLockFile(env: CoreEnv = .live)
func readSessionLockFile(env: CoreEnv = .live) -> SessionLock?
func deleteSessionLockFile(env: CoreEnv = .live)
```

Inside, `recoveryDir` becomes `env.recoveryDir()` and `Date()` at line 281
becomes `env.now()`. `recoveryDirectoryURL(bundleId:)` at line 230 stays --
it's the implementation of `CoreEnv.live.recoveryDir`, and
`CheckpointTests.recoveryDirectoryURLIsNamespacedByBundleId` keeps testing it
directly.

### `splitLeaf` / `insertAtLeaf` -- caller-supplied `SplitId`, not env

`splitLeaf` (`ModelOperations.swift:143`) and `insertAtLeaf`
(`ModelOperations.swift:270`, reached via `moveLeaf` at line 238) both mint
`SplitId()` internally. Both are on the `update()` path -- the former via
`.splitPane`, the latter via `.movePane`. They MUST become deterministic for
the central guarantee to hold (and for the Phase 5 `.splitPane` golden test
to be meaningful at all).

**Hoist the mint to the caller, do not thread env into ModelOperations.**
Change signatures to take `newSplitId: SplitId` (and forward `newSplitId`
through the recursive cases that re-build `.split(...)` with an existing
id -- those keep using `splitId` from the matched case, not the new
argument). Callers in `Update.swift` compute the id once before the call:

```swift
let newSplitId = SplitId(rawValue: env.newId())
let updated = splitLeaf(tab.rootNode, paneId: paneId, direction: direction,
                        newPane: newPane, newSplitId: newSplitId)
```

This keeps `ModelOperations` env-free -- it stays a layer of pure tree
functions parameterized by id, with no concept of an environment, which is
the right architectural shape. Existing direct tests of `splitLeaf` /
`moveLeaf` (search in `ModelOperationsTests`) update to pass an explicit
`SplitId()` argument; the change is mechanical.

### `PaneTokenStore.generate` -- one-off mirror, not env

`ModelOperations.swift:738` mints `UUID().uuidString` for pane tokens. It's
not on the `update()` path -- `AppRuntime` constructs the store. Treat it as
a small leaf with its own seam: add
`init(idGenerator: () -> UUID = UUID.init)` to the struct. `AppRuntime`
constructs the live one; any future test that exercises it can construct a
sequenced one. This avoids pulling env into a layer that today is id-agnostic.

### Helpers that mint, read the clock, or recurse into `update()`

Two `Update.swift` helpers need env threading. `throttledNotification` still
needs a signature change, but it receives the concrete timestamp chosen by its
caller instead of the whole env.

**Private helpers take `env: CoreEnv` REQUIRED -- no `.live` default.** This
turns the compiler into a third gate alongside grep + golden master: a
forgotten `env: env` at any caller is a build error, not a silent leak. The
public surface (top-level `update()` and the four `Persistence.swift`
session-lock helpers) keeps `= .live` to preserve production call sites
unchanged; recursive private helpers have no production-default obligation.

- `appendTodo` (signature already takes `id: UUID`) -- no helper-signature
  change. Its two callers at lines 1336, 1699 change from `id: UUID()` to
  `id: env.newId()`.
- `throttledNotification` (Update.swift:2471) reads `Date()` at line 2475.
  Change it to take **required** `now: Date` instead of `env: CoreEnv`.
  The two alert-producing callers compute `let now = env.now()` once, use
  that same value for `AlertModel.createdAt`, and pass it through for
  throttle bookkeeping.
- `handleIpcRequest` (Update.swift:1432, private) is called from `update()`'s
  `.ipcRequest` case and itself contains both a direct `UUID()` (line 1699,
  IPC todoAdd) and **eight recursive `update(...)` calls** (lines 1487, 1502,
  1554, 1592, 1728, 1753, 1777, 1791 -- IPC `tabRename`, `paneSplit`,
  `tabNew`, `themeSet`, todoEdit / todoDone / todoDelete /
  todoClearCompleted). Add **required** `env: CoreEnv` to its signature;
  forward `env` at the single call site inside `update()`'s `.ipcRequest`
  arm; replace the line-1699 `UUID()` with `env.newId()`; forward `env: env`
  at all eight recursive `update(...)` calls. Without this, deterministic
  replay through any IPC method is broken.
- `navigateToPane` (Update.swift:2327, private helper marked "Helpers") is a
  second private helper that recurses: `var commands = update(&model,
  .selectTab(id: currentTab.id))` at Update.swift:2332. It has three
  callers: Update.swift:861 and 877 (alert-jump handlers) and Update.swift:1566
  (inside `handleIpcRequest`'s `Methods.paneFocus` arm). Add **required**
  `env: CoreEnv` to its signature; forward `env` at the recursive
  `update(...)` and at all three callers. Easy to miss because the line is
  `var commands = update(...)`, which the leading-`let`/`return` grep
  patterns skip -- which is exactly why the Verification grep below is
  written to catch *any* `update(&...)` regardless of prefix, and why the
  required-env discipline matters as a parallel gate.

A full audit of recursing helpers (`grep -nE 'update\(&' Update.swift` then
walking each line back to its enclosing `func`) yields exactly two:
`handleIpcRequest` and `navigateToPane`. Both take **required** `env:
CoreEnv`. The remaining recursive `update(...)` sites live in `update()`'s
own top-level switch arms.

## Phasing -- each phase independently shippable

### Phase 1 -- Introduce `CoreEnv`. Zero call-site changes.
- [ ] Add `CoreEnvironment.swift`.
- [ ] Keep `TypedId` limited to its no-arg and `rawValue:` initializers; do
      not add an env convenience initializer.
- [ ] Add `import Testing` to `TestSupport.swift`. The file imports only
      `Foundation` + `@testable import DanTermCore` today
      (`TestSupport.swift:13-15`), and the next bullet uses
      `Issue.record(...)`, which is defined by Swift Testing -- the helper
      will not compile without this import.
- [ ] Add a `makeTestEnv(recoveryDir:now:idSequence:)` helper to
      `TestSupport.swift` (returns a `CoreEnv` with a sequenced id pool).
      **Sequence exhaustion must fail loud, not fall back to `UUID()`.** If
      `newId()` is called beyond the pool, record a Swift Testing issue
      naming the seam and the index, then return a synthetic id (e.g.
      `UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!`):
      ```swift
      newId: {
          defer { idx += 1 }
          guard idx < ids.count else {
              Issue.record("makeTestEnv idSequence exhausted at index \(idx); add more ids")
              return UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
          }
          return ids[idx]
      }
      ```
      A silent `UUID()` fallback would turn under-provisioned tests
      nondeterministic instead of failing at the exact missing-id seam,
      defeating the purpose of the helper.
- [ ] CI green; no test edits. Production behavior unchanged.

### Phase 2 -- Retire R2. Session-lock helpers take `env:`.
- [ ] Change the four signatures in `Persistence.swift:265,280,290,298` from
      `recoveryDir:` to `env: CoreEnv = .live`.
- [ ] Replace `Date()` at line 281 with `env.now()`.
- [ ] Migrate `CheckpointTests.swift` call sites (3 around lines 346-358) from
      `recoveryDir: recoveryDir` to `env: testEnv`, where `testEnv` comes
      from `makeTestEnv(recoveryDir: makeTestRecoveryDir(), now: frozenNow)`
      with `frozenNow = Date(timeIntervalSince1970: 1_700_000_000)`. Keep
      the `FileManager.fileExists` on-disk assertions that prove the seam is
      honored (the original R2 contract). **Add** `#expect(lock.startedAt
      == frozenNow)` after the `readSessionLockFile(env: testEnv)` round-trip:
      this proves `writeSessionLockFile` honored `env.now()`, otherwise a
      no-op env wiring (where `startedAt` keeps using ambient `Date()`)
      still passes the recovery-dir assertions. Without this, the env-now
      conversion is unguarded.
- [ ] `AppRuntime`'s production callers (lifecycle code that writes/reads/
      deletes the session lock) need no change -- the `.live` default matches
      today's `recoveryDir: recoveryDirectoryURL()` default.

### Phase 3 -- Thread `env` into `update()` and every helper on its path.
- [ ] Add `env: CoreEnv = .live` to `update()` (`Update.swift:6`).
- [ ] Convert the 9 `XxxId()` mint sites directly inside `Update.swift`
      (`Update.swift:35,36,165,289,379,728,758,940,1067`) to
      `XxxId(rawValue: env.newId())`.
- [ ] **Hoist the two `SplitId()` mints in `ModelOperations`** -- the central
      F1 fix. Change `splitLeaf` (`ModelOperations.swift:143`) and
      `insertAtLeaf` (`ModelOperations.swift:270`) to take
      `newSplitId: SplitId`. Callers in `Update.swift` (`.splitPane` /
      `.movePane` arms) compute
      `let newSplitId = SplitId(rawValue: env.newId())` before the call.
      Update any direct `ModelOperationsTests` callers of
      `splitLeaf` / `moveLeaf` to pass an explicit `SplitId()` -- mechanical.
      **Required, not optional:** `splitLeaf` is on `update()`'s path via
      `.splitPane`, which the Phase 5 golden master exercises directly; if
      this is deferred the central guarantee is false and the golden test
      cannot pass.
- [ ] Convert the 3 direct `UUID()` calls at `Update.swift:1210,1336,1699` to
      `env.newId()`. The one at 1699 lives inside `handleIpcRequest`.
- [ ] Convert the 3 `Date()` calls at `Update.swift:729,759,2475` to
      `env.now()` / caller-supplied `now`. The two alert branches compute
      `let now = env.now()` once and use that same value for
      `AlertModel.createdAt` and `throttledNotification`. The old line 2475
      read inside `throttledNotification`; change that helper to take
      **required** `now: Date` instead of `env: CoreEnv`.
- [ ] **Thread env through `handleIpcRequest`** (Update.swift:1432, private).
      Add **required** `env: CoreEnv` to its signature (no `.live` default);
      forward `env: env` at the single call site inside `update()`'s
      `.ipcRequest` arm; forward `env: env` at all 8 recursive `update(...)`
      calls inside it (Update.swift:1487, 1502, 1554, 1592, 1728, 1753,
      1777, 1791). Line 1554 is `update(&model, createTabMsg)` -- the
      second argument is a local variable, not a `.x` literal, so don't
      rely on a `.` pattern to find it.
- [ ] **Thread env through `navigateToPane`** (Update.swift:**2327**,
      private). Add **required** `env: CoreEnv` to its signature (no
      `.live` default); forward `env: env` at the recursive `update(...)`
      call inside it (Update.swift:**2332**, `var commands = update(&model,
      .selectTab(...))`); forward `env: env` at all three callers:
      Update.swift:861, 877 (alert-jump handlers) and 1566 (inside
      `handleIpcRequest`'s `Methods.paneFocus` arm).
- [ ] Forward `env: env` at the 10 top-level recursive `update(...)` calls
      inside `update()`'s switch arms (Update.swift:106, 125, 131, 225, 774,
      907, 943, 1075, 1395, 1401). 19 recursive sites total: 10 top-level +
      8 in `handleIpcRequest` + 1 in `navigateToPane` (Update.swift:2332).
      Verify with the grep gate below; any new site must show in the same
      gate. Required-env on the two recursive private helpers means a missed
      forward at any caller is *also* a compile error -- the gates are
      independent.
- [ ] Run the grep gate after Phase 3 (see Verification): zero hits, or fix
      until zero.
- [ ] Existing tests pass unchanged (they mint via `TypedId()` no-arg and call
      `update(&model, .x)` without env -- both still work via the defaults).

### Phase 4 -- `PaneTokenStore` id-gen seam.
- [ ] Add `init(idGenerator: () -> UUID = UUID.init)` to `PaneTokenStore`
      (`ModelOperations.swift:738`). `AppRuntime` uses the default. Genuinely
      optional polish -- it's off the `update()` path. Defer if Phase 3 +
      Phase 5 are landing under time pressure.

### Phase 5 -- Golden-master payoff demonstration.
- [ ] Add `swift-snapshot-testing` to
      `lib/DanTermCore/Package.swift`'s `dependencies`, and add **both**
      its `SnapshotTesting` product (`assertSnapshot` itself) and its
      `SnapshotTestingCustomDump` product (the `.customDump` strategy) to
      the `DanTermCoreTests` target dependencies. The `.customDump`
      strategy renders via `swift-custom-dump` -- the same library the
      rest of the suite uses for `expectNoDifference` -- so snapshot
      diffs match the diff style elsewhere in the suite. Note: the older
      `.dump` strategy is deprecated upstream
      (`@available(macOS, deprecated: 9999, message: "Use '.customDump'
      from the 'SnapshotTestingCustomDump' module, instead.")`) and
      renders via Swift stdlib's `dump()`, not `customDump`; do not use
      it.
      ```swift
      // dependencies:
      .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
      // testTarget dependencies:
      .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
      .product(name: "SnapshotTestingCustomDump", package: "swift-snapshot-testing"),
      ```
- [ ] Add `lib/DanTermCore/Tests/DanTermCoreTests/GoldenMasterTests.swift`
      with one `@Test` that drives a fixed `[Msg]` sequence under a
      deterministic env and asserts the full output `AppModel` via
      `assertSnapshot(of: model, as: .customDump)`. See sketch below.
- [ ] Add a `makeModel(env:)` overload to `TestSupport.swift` that mints the
      seed `GroupId` via env.
- [ ] Commit the snapshot file `__Snapshots__/GoldenMasterTests/<test>.1.txt`
      that `swift-snapshot-testing` writes on first run. Reviewers diff
      this file in PRs; CI compares against it.

## Payoff demo

The golden master must exercise at least one recursive `update(...)` path
and one IPC handler path, otherwise a missed `env: env` forward inside
`handleIpcRequest` or in a recursing top-level arm survives the gate.
Five messages cover the full surface -- top-level mint, recursive
forward, IPC forward (split path), IPC forward (navigate path), clock:

```swift
// Demonstrates the CoreEnv seam: under a deterministic env, a fixed [Msg]
// sequence produces a fully byte-equal AppModel. assertSnapshot with the
// .customDump strategy renders via swift-custom-dump (same as the suite's
// expectNoDifference assertions) and writes the snapshot to a committed
// __Snapshots__/ file on first run, then diffs on every subsequent run.
import Foundation
import Testing
import SnapshotTesting              // assertSnapshot
import SnapshotTestingCustomDump    // .customDump strategy (renders via swift-custom-dump)
import DanTermProtocol              // Methods, IpcRequestContext, JSONValue
@testable import DanTermCore

@Suite struct GoldenMasterTests {
    @Test("Deterministic env -> deterministic AppModel across top-level, recursive, IPC, and navigation paths")
    func deterministicAppModel() {
        // Intent: the pure core is a deterministic state machine when given a
        //   deterministic env. Same input -> same output, bit-for-bit, across
        //   top-level mints, recursive update() calls, handleIpcRequest, AND
        //   navigateToPane.
        // Why it exists: pins the CoreEnv seam's central guarantee. A missed
        //   `env: env` forward at ANY of the 19 recursive sites (8 of which
        //   live inside handleIpcRequest, 1 inside navigateToPane) would
        //   silently leak `.live`. The five arms below are picked to cover:
        //   (a) .splitPane (top-level mint + the hoisted ModelOperations
        //   SplitId), (b) .createGroup -> internal update(.createTab) at
        //   Update.swift:943, (c) .ipcRequest with Methods.paneSplit ->
        //   handleIpcRequest's recursive update(.splitPane) at
        //   Update.swift:1502, (d) .ipcRequest with Methods.paneFocus ->
        //   handleIpcRequest's call to navigateToPane at Update.swift:1566
        //   -> recursive update(.selectTab) at Update.swift:2332, (e)
        //   .surfaceBell for env.now() on alert createdAt. Spec-first;
        //   no incident.
        let ids = (0..<64).map { i in
            UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", i))")!
        }
        let env = makeTestEnv(
            now: Date(timeIntervalSince1970: 1_700_000_000),
            idSequence: ids
        )

        var model = makeModel(env: env)
        // (a) Top-level mint + ModelOperations SplitId via .splitPane.
        _ = update(&model, .createTab(inGroupId: nil), env: env)
        let firstPane = model.groups[0].tabs[0].focusedPaneId   // non-optional
        _ = update(&model, .splitPane(paneId: firstPane, direction: .horizontal), env: env)

        // (b) Recursive forward: .createGroup recurses into .createTab at
        //     Update.swift:943. .createGroup REQUIRES a name (Msg.swift:53).
        _ = update(&model, .createGroup(name: "Golden"), env: env)

        // (c) IPC recursive forward: .ipcRequest -> handleIpcRequest ->
        //     recursive update(.splitPane) at Update.swift:1502. Use the
        //     real protocol surface (Methods.paneSplit / "pane.split", and
        //     IpcRequestContext from DanTermProtocol). Crib the exact
        //     params shape from existing UpdateIpcTests `Methods.paneSplit`
        //     fixtures (search for `case Methods.paneSplit` callers in
        //     UpdateIpcTests.swift) -- the relevant params for paneSplit
        //     include `direction`, with `pane` resolved via the context.
        let secondGroupPane = model.groups[1].tabs[0].focusedPaneId
        let splitCtx = IpcRequestContext(paneId: secondGroupPane.rawValue.uuidString)
        let splitParams: JSONValue = .object([
            "direction": .string("vertical"),
        ])
        _ = update(&model, .ipcRequest(
            reqId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            method: Methods.paneSplit,
            params: splitParams,
            context: splitCtx
        ), env: env)

        // (d) IPC -> navigateToPane path: .ipcRequest with Methods.paneFocus
        //     routes handleIpcRequest -> navigateToPane (Update.swift:1566)
        //     -> recursive update(.selectTab) (Update.swift:2332). This arm
        //     proves the navigation chain is end-to-end env-threaded; the
        //     required-env discipline on navigateToPane is the compile-time
        //     gate, and this arm is the runtime integration witness.
        //     paneFocus params take a "paneId" string (Update.swift:1559).
        let focusParams: JSONValue = .object([
            "paneId": .string(firstPane.rawValue.uuidString),
        ])
        _ = update(&model, .ipcRequest(
            reqId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            method: Methods.paneFocus,
            params: focusParams,
            context: IpcRequestContext(paneId: nil)
        ), env: env)

        // (e) Clock-minting path: alert createdAt must equal env.now().
        _ = update(&model, .surfaceBell(paneId: firstPane), env: env)

        assertSnapshot(of: model, as: .customDump)
    }
}
```

The `import DanTermProtocol` brings in `Methods`, `IpcRequestContext`, and
`JSONValue` -- the existing `TestSupport.swift` and `UpdateIpcTests.swift`
already use this same surface, so no protocol-package wiring change. When
porting this sketch, the implementer should open
`lib/DanTermCore/Tests/DanTermCoreTests/UpdateIpcTests.swift` first and
crib the exact `paneSplit` / `paneFocus` params shapes from existing
fixtures (search for `Methods.paneSplit` / `Methods.paneFocus`); the
versions above are illustrative, not copy-paste-ready.

**Why `assertSnapshot(of: model, as: .customDump)` rather than a
hand-authored `expectNoDifference(model, expected)` literal.** A frozen
`AppModel` literal for the 5-Msg sequence is hundreds of lines of nested
Swift expressions (groups -> tabs -> recursive `SplitNodeModel` trees
-> panes with cwd/theme/todos -> alerts -> `lastNotificationTime:
[PaneId: [AlertKind: Date]]` -> mru order), and `customDump`'s output is
*not* Swift-paste-compatible (UUIDs render bare, Dates render as
timestamps). The pragmatic outcomes of that approach are: implementers
weaken the test to assert just a slice of `AppModel`, or they stall.
`assertSnapshot` writes the snapshot to a committed
`__Snapshots__/GoldenMasterTests/<test>.1.txt` file on first run, then
on every subsequent run diffs the live model's dump against that file
and fails with a unified diff if they disagree -- which is exactly the
contract `expectNoDifference` provides, minus the literal-authoring tax.
The `.customDump` strategy (from `SnapshotTestingCustomDump`, the
companion library in the same `swift-snapshot-testing` package) renders
via `swift-custom-dump`, so the snapshot diffs match the diff style the
rest of the suite already uses for `expectNoDifference`. The older
`.dump` strategy is deprecated upstream and uses Swift stdlib's `dump()`
instead -- distinct format, not what we want. The new dep is one
package (`swift-snapshot-testing`) in the same Point-Free family as the
existing `swift-custom-dump`, accepted cost.

**Updating the snapshot when the AppModel surface changes intentionally**
(e.g. a new field is added): delete the snapshot file and re-run, or
wrap the relevant call in `withSnapshotTesting(record: .all) { ... }`
for one run. The diff in the snapshot file then surfaces in code
review just like any other reviewable artifact -- which is the headline
benefit over a giant inline literal.

The `(a)/(b)/(c)/(d)/(e)` arms above are the specific behavioral guards
this golden master demands; if any is dropped, the seam loses its
end-to-end integration witness.

## Risks

### R1: Missed `env: env` forwarding on a recursive `update(...)` call
**Impact:** the inner call silently uses `.live`, so a test that injects a
deterministic env still sees random UUIDs/Date inside any branch that recurses.
The Phase 5 golden master catches this as a diff once that path is exercised,
but earlier waves could land with silent leaks.
**Fix:** three independent gates close the gap. (1) The grep gate at PR time --
`grep -nE 'update\(&[a-zA-Z_]+, ' Update.swift | grep -v 'env: env' | grep -v '^6:'`
must return zero hits. The pattern matches any `update(&identifier, ...)`
call regardless of prefix (`let`/`var`/`return`/`_ =`/none) or
second-argument shape (`.foo(...)` or a bare local like `createTabMsg` at
Update.swift:1554); the `^6:` filter excludes the function definition.
Re-run after each Phase 3 commit. (2) The compiler -- the two private
helpers that recurse (`handleIpcRequest`, `navigateToPane`) take
**required** `env: CoreEnv`, so a missed forward at any caller is a build
error. (3) The Phase 5 snapshot diff, which catches mint-bearing paths at
runtime.

### R2: Snapshot decode keeps `UUID()` -- callers may expect determinism
**Impact:** a user (or a future replay tool) decoding an init file expects
deterministic IDs; today they get random ones for id-less entries.
**Fix:** add a `// MARK: snapshot decode intentionally mints non-deterministic
ids` comment block above the four sites at `Model.swift:428,445,558,590` that
records the intent: hand-authoring an init file without ids is the user
affordance; deterministic replay should drive replay through `update()` from a
fully-id'd snapshot, not by re-decoding.

### R3: `throttledNotification` tests may have implicit `Date()` dependence
**Impact:** any existing test in `UpdateAlertTests` that asserts throttle
behavior (`surfaceBell` / `desktopNotification` paths) may rely on real
wall-clock progression. After env injection, those tests get an `env.now()`
that doesn't advance unless they explicitly bump it.
**Fix:** during Phase 3, audit `UpdateAlertTests` for throttle-related
assertions; if any exist, migrate them to use a `var now = Date(...)` closure
in `makeTestEnv` so they can advance the clock explicitly. This is a strict
improvement -- the throttle becomes properly testable across the >=1s boundary.

### R4: `path: "."` symlink wiring stays intact
**Impact:** `app/DanTermCore` is a symlink to `lib/DanTermCore/Sources/DanTermCore`.
Adding `CoreEnvironment.swift` under `Sources/DanTermCore/` must be picked up
by both the app build (via the symlink) and the nested test package.
**Fix:** none required -- the migration's `sources: ["app",
"lib/DanTermCore/Sources/DanTermCore"]` wiring auto-includes the new file.
Phase 1's CI green is the proof.

## Verification

- **Determinism (top-level + recursive + IPC + navigation):** the Phase 5
  golden-master test passes. It exercises five arms by design:
  (a) `.splitPane` (top-level `PaneId(rawValue: env.newId())` + the hoisted
  `splitLeaf`/`insertAtLeaf` `SplitId` mint),
  (b) `.createGroup` -> recursive `update(.createTab)` (Update.swift:943),
  (c) `.ipcRequest` with `Methods.paneSplit` -> `handleIpcRequest` ->
  recursive `update(.splitPane)` (Update.swift:1502),
  (d) `.ipcRequest` with `Methods.paneFocus` -> `handleIpcRequest` ->
  `navigateToPane` (Update.swift:1566) -> recursive `update(.selectTab)`
  (Update.swift:2332),
  (e) `.surfaceBell` (`env.now()` for alert `createdAt`).
  Intentionally dropping `env: env` at any of those forwarding sites fails
  the test with a readable snapshot diff. Arm (d) integration-tests the
  `navigateToPane` chain end-to-end; the required-env discipline on the
  private helper is the parallel compile-time gate.
- **R2 retired:** `grep -nE 'recoveryDir: URL = recoveryDirectoryURL' lib/`
  returns zero hits after Phase 2. `CheckpointTests` still proves the
  recovery-dir seam via `FileManager.fileExists` on the temp `session.json`
  before/after write/delete, **and** asserts `lock.startedAt == frozenNow`
  to prove `env.now()` was honored (F4).
- **No `env: env` misses:** the Phase 3 grep gate
  (`grep -nE 'update\(&[a-zA-Z_]+, ' lib/DanTermCore/Sources/DanTermCore/Update.swift | grep -v 'env: env' | grep -v '^6:'`)
  returns zero hits. The pattern matches *any* `update(&identifier, ...)`
  call regardless of prefix (`let`, `var`, `return`, `_ =`, none) or
  second-argument shape (`.foo(...)` literal, bare local like
  `createTabMsg` at Update.swift:1554). The `^6:` filter excludes the
  function definition line itself.
- **No `Date()`/`UUID()` on the `update()` path:**
  `grep -nE 'Date\(\)|UUID\(\)' lib/DanTermCore/Sources/DanTermCore/Update.swift`
  returns zero hits after Phase 3. Same for the two hoisted sites in
  `ModelOperations.swift:143,270` (after Phase 3 they take `newSplitId:`).
  Sites in `Model.swift` for snapshot decode and in `Persistence.swift` for
  `Bundle.main` / `ProcessInfo` are not on this path.
- **Production behavior unchanged:** `just build` + `just build-run` produce
  the same app; `AppRuntime.send` was never changed; default `.live` env makes
  every signature change a no-op at the call site.
- **Tests green throughout:** `swift test --package-path lib/DanTermCore` after
  each phase. Test files in `lib/DanTermCore/Tests/DanTermCoreTests/` need no
  edits (Phase 1, 3, 4); `CheckpointTests` is the only file the plan modifies
  (Phase 2).
- **CI gate:** the existing `test` job runs the core suite on `macos-26` after
  every phase. No new CI wiring needed.

## Rollback / coexistence

Every phase is independently revertable. Phases 1-4 add a mix of optional
(public-surface, `.live` defaults) and required (private-helper) `env:`
parameters; reverting any one means deleting the parameter and -- for the
private helpers -- updating their handful of internal callers. Phase 5
adds a new test file, the `swift-snapshot-testing` dep, and a committed
`__Snapshots__/` directory; reverting means removing all three. R2's
old `recoveryDir:` shape is the only deletion; if Phase 2 needs to roll
back, restore the four signatures and `CheckpointTests` keeps working with
the restored param.

## Sources

- This conversation's exploration of the impurity surface: 21 nondeterministic
  identity sources, 4 `Date()` calls, and R2's scattered `recoveryDir:` shape.
- The implemented test-migration plan
  (`plans/impl/2026-05-28-modernize-danterm-test-system.md`) for R2's existing
  shape, the symlink wiring, the `swift-custom-dump` dep, and the test-preamble
  convention used in the golden-master sketch.

## Implementation notes

- The golden-master sequence calls `.appResignedActive` before `.surfaceBell` so
  the bell creates an alert even after `pane.focus` focuses the target pane;
  otherwise active-app focused-pane suppression bypasses the clock path.
- `lib/DanTermCore/Package.swift` excludes `Tests/DanTermCoreTests/__Snapshots__`
  from the test target so SwiftPM does not warn about the committed snapshot text
  file as an unhandled source/resource.
