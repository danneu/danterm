# Master plan: pure core / portable support / platform runtime

## Context

DanTerm follows an Elm architecture: views dispatch `Msg`, the pure `update(&model, msg) -> [Command]`
decides, and `AppRuntime.perform` interprets commands as side effects. The intended invariant is
"core decides, runtime does": `DanTermCore` should be deterministic domain logic, fully unit-testable
without Cocoa, GhosttyKit, sockets, timers, or the filesystem.

That invariant is mostly real already -- but not enforced, and quietly violated. The decision logic is
pure and exhaustively tested (`UpdateIpcTests`, `UpdateTabTests`, ... ~600k of pure `update()` tests;
`Command` is a data enum of effect descriptions with no closures). The leak is a handful of
side-effecting _utilities_ filed in the core directory:

- `IpcConnection.swift` -- Unix-socket read/write (`Darwin.read/write`, `DispatchQueue`, `NSLock`,
  `setsockopt`). The pure `IpcLineFramer`/`IpcFrameEvent` in the same file is the only part tested.
- `Debouncer.swift` -- a `DispatchSourceTimer` wrapper (its own header admits it was parked in core
  "so it can be compiled in ... the unit test build").
- `CLIPathInstaller.swift` -- `Process` (osascript) + `FileManager` symlink install/uninstall.
- `Persistence.swift` tail -- recovery-path resolution (`FileManager.default.urls`) and session-lock
  read/write/delete (`Data(contentsOf:)`, `data.write(to:)`, `FileManager.removeItem`).
- Trivial file-load wrappers: `DanTermConfigParser.loadFromDisk()` and `ThemeColorParser.parse(themeFileAt:)`.
- `CoreEnv.live` binds `recoveryDir: { recoveryDirectoryURL() }`, transitively pulling FileManager into core.
- Environment reads inside _pure_ code: `abbreviateHome` (ModelOperations.swift:470), `expandTilde`
  (Model.swift:540), and `DanTermConfigParser.configFilePath()` (DanTermConfig.swift:25) all call
  `NSHomeDirectory()`. The consequential one is `abbreviateHome`, reached from the snapshot codec
  (`toPaneSnapshot`), with `toSnapshot` called from inside `update()` (Update.swift:701, 1475, 2209).
  Scope correction (verified -- see "Determinism seam"): the HOME read does **not** taint the `AppModel`
  that `update()` produces. HOME never enters the model; it appears only in the _snapshot payloads_
  `update()` hands back inside `Command`s / IPC results (`.exportState`, the `ls` reply, `tabSnapshotJSON`).
  `emitCloseTabConfirmation` writes only a bare `.closeTab` enum to the model -- the home-abbreviated title
  rides the `.showCloseTabConfirmation` _command_ (ModelOperations.swift:520-528; call sites Update.swift:120,
  1422). `PaneModel.cwd` holds the raw absolute path the shell reported on a `Msg`, not an
  `NSHomeDirectory()`-derived value. So `update()`'s _state evolution_ is already home-deterministic; only
  its _saved/sent_ outputs embed real HOME. `GoldenMasterTests` (which asserts on the model) is therefore
  already home-independent; the recorded `SnapshotTesting`/export fixtures that snapshot `toSnapshot` output
  are the parts that secretly depend on the author/CI HOME -- a latent cross-machine fragility in the
  save/send path, not a model-purity nit.

These slipped in because the only purity guard today is `scripts/core-purity-lint.sh`, which forbids
`import Cocoa/AppKit/SwiftUI` -- nothing stops `import Darwin`, `Process`, `FileManager`, `DispatchSource`,
or `NSHomeDirectory`. The nested test package (`lib/DanTermCore/Package.swift`) compiles the core without
GhosttyKit, so GhosttyKit creep _is_ caught, but Foundation/Darwin IO is invisible to both guards.

The existing plan (`polish-this-into-a-vectorized-stearns.md`) addresses a different axis -- it would
make `DanTermCore` a real importable SwiftPM target, delete the `app/DanTermCore` symlink, and add
`package` access annotations across the model. That is mechanically viable but does not protect the
purity invariant (Foundation IO compiles in any target), and it pays a permanent per-field annotation
tax that `docs/design/2026-05-28-core-module-via-symlink.md` deliberately rejected.

This plan reframes the work around the invariant the project actually cares about: make the domain core
genuinely pure, move portable side effects to a sibling `DanTermSupport` layer that stays fast-testable,
keep the proven symlink mechanism, and defer the real-target migration until a concrete second consumer
justifies it.

## Recommended direction (the pivot, stated plainly)

**Pivot away from the real-target / symlink-removal plan. Do purity-first instead, keeping the symlink.**

1. Split the mixed `DanTermCore` into:
   - `DanTermCore` -- pure, deterministic domain logic. No sockets, files, timers, processes, AppKit,
     or GhosttyKit. Same files compiled same-module into the app via the existing symlink; fast-tested
     via the existing nested package.
   - `DanTermSupport` (new) -- portable side effects (sockets, timers, installer, recovery store) that
     need no AppKit/GhosttyKit and benefit from fast unit tests. Same symlink + nested-package pattern.
   - `app/` runtime -- AppKit + GhosttyKit + everything platform-bound, plus trivial IO wrappers.
   - `DanTermProtocol` -- unchanged role (CLI parser + IPC envelope), gains the IPC line framer.
2. Keep the `app/DanTermCore` symlink; add a parallel `app/DanTermSupport` symlink. No `package`/`public`
   tax: the app reaches core and support same-module (`internal`); support depends on nothing in core.
3. Strengthen the purity lint to enforce the real invariant (no side-effecting APIs in the core dir),
   making purity a maintained property rather than an accident.
4. Defer the real importable-target migration indefinitely. Park the existing plan as superseded with a
   recorded trigger condition.

Why this is the simplest robust path:

- It protects the invariant the user named; the real-target boundary does not (it only adds access control).
- A second globbed source dir + nested package is the _minimal_ structure that yields both a provably
  pure core and fast tests for portable effects -- and it reuses a pattern the repo already documents
  and trusts, so it is not a new kind of complexity.
- It avoids the permanent annotation tax and the `--build-path .spm-build` rebuild bug that the symlink
  doc was written to dodge.
- Module-boundary churn is zero: moving symbols are consumed by `app/` files that compile them same-module,
  so no call site changes its import or visibility. (The determinism seam below has its own bounded,
  mechanical churn -- threading a non-defaulted `newId` into the restore builder, removing the no-arg
  `TypedId.init()`, and repointing the `configFilePath` callers -- but that is the inherent cost of the id
  seam and the config-path move, not of the split. The HOME seam is narrower still: it adds _no_ app-caller
  churn, because the home parameters default to the real ambient home.)

## Target / module layout and dependency direction

```
lib/DanTermProtocol/        real importable target (unchanged role)
  Sources/DanTermProtocol/  CLI parser, JSON-RPC envelope, JSONValue, + IpcLineFramer/IpcFrameEvent (moved in)
  Tests/                    XCTest; gains the framer tests

lib/DanTermCore/            PURE domain (symlinked into app; nested test package)
  Sources/DanTermCore/      Model, Msg, Command(data), Update, ModelOperations, Projections,
                            snapshot/restore/merge codec, parsers/validators, classifiers, CoreEnv{newId,now,homeDirectory}
  Tests/DanTermCoreTests/   Swift Testing; keeps all pure suites

lib/DanTermSupport/         NEW: portable side effects (symlinked into app; nested test package)
  Sources/DanTermSupport/   IpcConnection (socket IO), Debouncer (timer), CLIPathInstaller (Process/FS),
                            RecoveryStore (recovery paths + session-lock IO), SessionLock type
  Tests/DanTermSupportTests/ Debouncer/CLIPathInstaller/RecoveryStore suites (moved from core)

app/                        RUNTIME: AppKit + GhosttyKit
  *.swift                   AppRuntime (Command interpreter), Reconcile, AppDelegate, IpcServer (accept loop),
                            TerminalView/GhosttyApp, checkpoint scheduling/writing, notifications,
                            trivial IO wrappers (loadFromDisk, parse(themeFileAt:))
  DanTermCore     -> symlink ../lib/DanTermCore/Sources/DanTermCore       (existing)
  DanTermSupport  -> symlink ../lib/DanTermSupport/Sources/DanTermSupport (new)
```

Dependency direction (acyclic):

```
DanTermProtocol  (leaf; no deps)
      ^                         ^
      |                         |
DanTermCore (pure)        DanTermSupport (portable effects)   <- siblings; neither imports the other
      \                         /
       \                       /
        app  (compiles core + support same-module via symlinks; real `import DanTermProtocol`;
              links AppKit + GhosttyKit; interprets Commands)
```

Key property: `DanTermSupport` depends on `DanTermProtocol` (for `IpcConnection`) and Foundation/Darwin
only -- **not on `DanTermCore`**. That is what keeps the whole split annotation-free (see API policy).

The root `Package.swift` is **untouched**: the `DanTerm` target already globs `path: "app"` and compiles
`app/DanTermCore/*` via symlink without listing it as a dependency. The new `app/DanTermSupport` symlink
is picked up the same way. Support files `import DanTermProtocol`, which the app target already depends on.

## What moves, what stays (by concept)

Stays in `DanTermCore` (pure):

- Model + typed IDs, `Msg`, `Command` (already pure effect descriptions), `update`, `ModelOperations`,
  `Projections`, `ScrollbarMath`, `SurfaceGeometry`, `DropZone`, `DragDropInput`,
  `TerminalLaunchEnvironment`, all TODO/sidebar/switcher classifiers and state machines.
- Persistence _value_ layer: `toSnapshot`, `toInitFile`, `graftScrollback`, `mergeCheckpoints`,
  `loadValidatedInitFile`, `truncateScrollback`, `restoreCommandBehavior`, `restoreInitialInput`.
- Pure parsers/validators: `DanTermConfigParser.parse(content:)` + the config writer (string transforms);
  `ThemeColorParser.parse(themeContent:)`.
- `CoreEnv` becomes `{ newId, now, homeDirectory }` -- pure injected closures -- and **keeps its
  `static let live` in core**. `update()` retains its `env: CoreEnv = .live` default, so `.live` must
  resolve when the nested package compiles `update()`; it therefore stays in core (it cannot move to `app/`).
  `.live` binds `{ UUID() }`/`{ Date() }`/`{ NSHomeDirectory() }`; the lint allowlists that one
  seam-binding declaration (see lint section). The `recoveryDir` field is removed (persistence split; the
  session-lock helpers that consumed `env.recoveryDir()`/`env.now()` move to support and compute their dir
  and clock internally). See "Determinism seam (home, ids, time)" for how ids/time/home are threaded -- and
  why, unlike the wide earlier draft, `update()` keeps its default env and core source legitimately retains
  `.live`'s ambient bindings (plus the two leaf helpers' `NSHomeDirectory()` defaults), guarded by a small
  lint allowlist rather than banned outright.

Moves to `DanTermProtocol`:

- `IpcLineFramer` + `IpcFrameEvent` (newline-delimited JSON-RPC framing is a transport-protocol concern).
  This is what lets `IpcConnection` depend on protocol, not core.

Moves to `DanTermSupport` (portable side effects, fast-testable):

- `IpcConnection` class (per-connection socket read/write/close lifecycle).
- `Debouncer` (DispatchSourceTimer).
- `CLIPathInstaller` (already DI-factored; Process + FileManager).
- `RecoveryStore`: recovery-path helpers (`recoveryDirectoryURL`, `lightCheckpointURL`,
  `enrichedCheckpointURL`, `sessionLockURL`) + session-lock IO (`writeSessionLockFile`,
  `readSessionLockFile`, `deleteSessionLockFile`) + the `SessionLock` type (currently defined in `Model.swift:278`, not `Persistence.swift` -- extract it from
  there on the move; its only core consumers are the IO helpers and `CheckpointTests`, which also move). API: keep the production entry
  points zero-arg (`writeSessionLockFile()`, `readSessionLockFile() -> SessionLock?`,
  `deleteSessionLockFile()`), computing `recoveryDir` (FileManager), `now` (Date), and `pid` (ProcessInfo)
  internally -- all allowed in support. Add _defaulted_ test seams on those same functions
  (`recoveryDir: URL = <real>`, `now: Date = Date()`, `pid: Int32 = <real>`) that the relocated round-trip
  test passes explicitly (temp dir + frozen date + fixed pid). Zero-arg production signatures keep the app
  call sites (`AppDelegate`, `main.swift`) byte-for-byte unchanged. Critically, these helpers **currently
  take `env: CoreEnv = .live`** and read `env.recoveryDir()`/`env.now()` (Persistence.swift:265-301); the move
  must **drop the `CoreEnv` parameter** (computing dir/clock/pid internally), because a `CoreEnv` dependency
  would create exactly the `support -> core` edge the split forbids. The store then needs nothing from core.

Moves to `app/` (trivial IO wrappers / ambient bindings with no meaningful unit test to preserve; the pure
parser or seam they wrap is already tested in core):

- `DanTermConfigParser.loadFromDisk()` (5-line FileManager read around the pure parser) and the path helper
  `configFilePath()` (`NSHomeDirectory`-based). `configFilePath()` has **six** callers total: five direct
  app callers (PreferencesPanel.swift:347, AppRuntime.swift:553/569, AppDelegate.swift:500, GhosttyApp.swift:79
  `loadDanTermOverlay`) plus the internal call inside `loadFromDisk` (DanTermConfig.swift:33), which travels
  to `app/` with the loader. Move `configFilePath()` as an internal _app-level_ helper (e.g.
  `DanTermConfigPaths.configFilePath()`) visible to all five app callers, not a loader-private function.
  Repointing those five app call sites is the one bit of real config-path app churn here. (GhosttyApp.swift
  has its own separate `configFilePath()` for the Ghostty overlay path -- a different symbol, not moved; it is
  called at AppDelegate.swift:517, which must **not** be repointed.) `loadFromDisk()` itself also has two app
  callers that travel with it -- AppRuntime.swift:87 and 1036 -- byte-for-byte unchanged if it keeps the name
  `DanTermConfigParser.loadFromDisk()` via an app-side extension, otherwise repoint both.
- `ThemeColorParser.parse(themeFileAt:)` (file read around the pure content parser). One app caller,
  ThemeCatalog.swift:36 (same keep-the-name-or-repoint caveat as `loadFromDisk`).

`CoreEnv.live` does **not** move (the earlier draft moved it to `app/`): because `update()` keeps its
`= .live` default, `.live` stays in core as the designated ambient seam, lint-allowlisted. See "Determinism
seam (home, ids, time)".

Stays in `app/` (already there, platform/runtime-bound):

- `AppRuntime.perform` (Command interpreter), checkpoint scheduling/writing (`writeCheckpoint`,
  light/enriched timers), `IpcServer` (socket accept loop, coupled to `AppRuntime`), notifications,
  Ghostty surface creation, all AppKit.

IPC, after the split, is layered exactly as requested:

- Method semantics + param handling + result `JSONValue` construction: `update()` in core (already pure,
  covered by `UpdateIpcTests`). No move needed.
- Envelope + line framing: `DanTermProtocol`.
- Per-connection socket read/write lifecycle: `IpcConnection` in `DanTermSupport`.
- Accept loop + dispatch into the model: `IpcServer` in `app/`.

Persistence, after the split, is layered exactly as requested:

- Pure snapshot/validation/merge policy: `DanTermCore`.
- Path resolution + file read/write + session lock: `RecoveryStore` in `DanTermSupport`.
- Checkpoint _scheduling_ (debounce/timer) and the actual snapshot-to-disk write: `app/` (AppRuntime),
  which already owns it.

### Determinism seam (home, ids, time)

The core's nondeterminism comes from three ambient inputs -- home directory, fresh ids, wall-clock time.
Ids and time are made explicit and compiler-forced. Home is handled by a _narrow_ seam, because the
verified finding (above) changed its scope: `update()`'s model evolution is already home-clean, so the
wide "thread a non-defaulted `home` through ~8 APIs and demolish `TabModel`'s computed chrome" approach was
over-scoped -- most of its churn purified the render path, which is impure app-facing code never compared
across runs.

**The rule (inject vs. ambient).** This is the principle the seam encodes, and it generalizes to any
ambient input:

> Inject an explicit value when the result will be **SAVED** (to disk), **SENT** (over IPC), or
> **ASSERTED** (in a test) -- anything a second execution will compare against. Leave it **AMBIENT**
> (read the real `NSHomeDirectory()` via a default) when the result is only **SHOWN** live and discarded
> (sidebar/toolbar titles, alert text).

Rationale: determinism only earns its keep where two executions are compared -- a restore round-trip, a
test re-run, a CLI client parsing a response. A title painted into one `NSAlert` is never compared, so
reading the real `NSHomeDirectory()` there is both cheaper and more correct. The structural payoff is
**enforceability**, not just the test fixtures: confining `NSHomeDirectory()` to the three allowlisted seams
is what lets the lint ban ambient HOME everywhere else in core and close the last hole in the determinism
boundary (the fixtures' machine-independence is the bonus). This rule is recorded in the new ADR, AGENTS.md,
doc comments, and the lint failure message (see "Documentation updates").

**Home (narrow seam).**

- Add `homeDirectory: () -> String` to `CoreEnv` alongside `newId`/`now`; `.live` binds `{ NSHomeDirectory() }`.
  `.live` stays in core (see Env wiring), so this binding is one of the lint-allowlisted ambient sites.
- The leaf helpers gain a **defaulted** home param reading the real ambient home:
  `abbreviateHome(_:home: String = NSHomeDirectory())` and `expandTilde(_:home: String = NSHomeDirectory())`.
  The default carries every render/display caller for free -- **no projection-layer churn**, and `TabModel`'s
  computed `title`/`displayTitle`/`subtitle` (Model.swift:123-128), `deriveTabChrome` (ModelOperations.swift:477),
  and `formatToolbarLabel` (ModelOperations.swift:642) survive unchanged, reading ambient home. These two
  helpers' default expressions are the home `NSHomeDirectory()` allowlist entries (plus `.live`). Optional and
  orthogonal, but cheap since the same two lines are being edited anyway: make `abbreviateHome`'s prefix test
  boundary-aware -- `path == home || path.hasPrefix(home + "/")` instead of the bare `path.hasPrefix(home)`
  (ModelOperations.swift:472) -- so `/Users/dan` stops mis-rendering `/Users/danielle/foo` as `~ielle/foo`.
  Honest severity: a SHOWN-path display glitch only (the abbreviate/expand pair are inverses on a fixed home,
  so the round-trip self-corrects); fold it in here or split a trivial follow-up commit. Either way the
  **abbreviate-boundary** test (test plan, item 3) travels with the fix.
- Thread an explicit home **only** through the save/send/restore paths -- the values a second run compares:
  - Snapshot/checkpoint (SAVED) + IPC (SENT): `toSnapshot`, `toInitFile(_ model:)`, and the snapshot-embedding
    IPC builders. The three update()-internal `toSnapshot` sites (Update.swift:701 `.exportState`, 1475 `ls`
    reply, and the `toSnapshot` inside `tabSnapshotJSON` -- the literal call is at 2209, reached via the `tabSnapshotJSON` call at 2116 whose def is at 2208) pass `env.homeDirectory()`; `tabSnapshotJSON` gains a `home`
    param threaded from its IPC handler's in-scope `env`. (No other Update.swift code abbreviates home --
    verified: all home-embedding in `update()` output flows through `toSnapshot` -> `toPaneSnapshot` ->
    `abbreviateHome`; `paneInfoResult` embeds the raw shell cwd, which is input data, not synthesized.)
  - Restore (the **ASSERTED** axis): `loadValidatedInitFile`, `validateAndBuildDetailed`, and `resolveLaunch`
    thread home down to `expandTilde`. In production restore _defaults to ambient_ -- it expands a saved
    `~/foo` to the user's **current** home, which is the whole point of storing `~/` (it does not "reproduce"
    a saved home). The injectable `home` exists so a test can assert machine-independent expansion against a
    fixed home, not for production reproduction.
  - To keep the `NSHomeDirectory()` allowlist to just the leaf helpers + `.live`, these save/send/restore
    functions take `home: String? = nil` -- **not** a `= NSHomeDirectory()` default, which would spell the
    banned token in each signature. Resolve ambient **once at function entry** and pass a non-optional value
    down: `let h = home ?? CoreEnv.live.homeDirectory()`, then `abbreviateHome(x, home: h)` /
    `expandTilde(x, home: h)`. `CoreEnv.live.homeDirectory()` spells none of the banned tokens and routes
    through the already-allowlisted `.live`, so it stays lint-clean while avoiding a per-leaf `.map/??` dance
    (cleaner than resolving at each leaf call -- `toPaneSnapshot` abbreviates both cwd and title). So
    `NSHomeDirectory()` is literally written in exactly three core places: `abbreviateHome`, `expandTilde`,
    and `.live`.
  - Because the default is the _real_ ambient home (not a fake), a missed call site stays correct in
    production -- it reads the user's real HOME. This is why the wide plan's "fake-home default" hazard
    dissolves and these params can safely default instead of being compiler-forced. The app's direct
    checkpoint/restore call sites (checkpoint: AppRuntime.swift:899/923; restore: main.swift:53/93-98,
    AppRuntime.swift:965/1088/1126) stay **unchanged** for home -- they omit it and get ambient. (The
    restore sites still change for the _id_ seam below, which threads a non-defaulted `newId`.) Determinism
    is pinned only where it is compared: update()-internal builders pass `env.homeDirectory()`; tests pass a
    fixed home.
- `TabModel`'s computed chrome is **not** removed (the wide plan demolished it). It keeps deriving from
  `deriveTabChrome` -> `abbreviateHome` with the ambient default; tab chrome is SHOWN-only, never saved/sent.
  The close-tab confirmation title (Update.swift:120, 1422 -> `.showCloseTabConfirmation`) is also SHOWN
  (alert text), so it correctly stays ambient even though it rides a `Command`.

**Ids.** `update()` already mints every id through `env.newId()` (e.g. `PaneId(rawValue: env.newId())`), but
the restore builder `validateAndBuildDetailed` mints bare `GroupId()`/`TabId()`/`PaneId()`/`SplitId()` for
id-less snapshots (Model.swift:434, 451, 564, 596) -- nondeterministic. Like the restore home seam, this is
the **ASSERTED** axis: production mints fresh ids (the app's live generator), but a test must pin them to a
known sequence (and removing the no-arg init, below, closes the leak in the bargain). Add a **non-defaulted**
`newId: () -> UUID` parameter to
`validateAndBuildDetailed`/`loadValidatedInitFile` and build ids as `GroupId(rawValue: newId())`. The app
passes the live generator; tests pass a deterministic sequence. Then remove the no-arg `TypedId.init()`
(Model.swift:14, `self.rawValue = UUID()`): with restore fixed it has no remaining _core_ caller, and
removing it turns off-seam id minting into a compile error.

Consistency check (the finding asked us to confirm the actual site count and apply the same judgment as
home -- lint allowlist vs. wide removal). Verified counts of bare no-arg `XxxId()` mints:

- **Core source: 4** -- exactly the restore sites above; all become `rawValue: newId()`. (Genuine leaks.)
- **App: 1** -- `GroupId()` at AppRuntime.swift:84 (initial group), rewritten to `GroupId(rawValue: <app newId>)`.
- **Core tests: 536** (GroupId 52, TabId 155, PaneId 188, SplitId 53, AlertId 88), **`tests-ui` harness: 19**
  (PaneSplitViewTests 2/SidebarSelectionCacheTests 12/SplitContainerViewTests 5) -- impure fixtures;
  nondeterministic ids are fine there. (`AlertId` is a 5th `TypedId` tag, Model.swift:22, beyond the four
  named above; the generic shim below covers it too.)

Decision: **keep the removal** (do not mirror the home allowlist). The home allowlist exists only because
the two leaf helpers _legitimately_ need `NSHomeDirectory()` in core; by contrast, once restore is fixed,
**no core code legitimately needs a no-arg id mint**, so removal is strictly cleaner and compiler-enforced
with no offsetting cost. The 555 test sites (536 core + 19 tests-ui) are absorbed by re-adding a test-only
`extension TypedId { init() { self.init(rawValue: UUID()) } }` in _both_ test compilation units
(`DanTermCoreTests` and the `tests-ui` harness -- they share no module), so no fixture call site changes.
And the planned bare-`UUID()` core ban already catches the only other fresh-id path (`XxxId(rawValue: UUID())`),
so no separate `XxxId()` lint pattern is needed -- the id seam rides on the `UUID()` ban plus the removed init.

**Time.** `update()` uses `env.now()`; no bare `Date()` in core except `.live`'s binding (allowlisted).

**Env wiring.** `CoreEnv` is the struct plus its `static let live`, both in core. `update()` **keeps** its
`env: CoreEnv = .live` default (the earlier draft removed it). Consequences, all simplifications versus the
wide draft:

- `.live` stays in core (the nested package compiles `update()` and must resolve `.live`); its
  `{ UUID() }`/`{ Date() }`/`{ NSHomeDirectory() }` bindings are lint-allowlisted as the designated ambient
  seam. With `.live` carrying ambient `homeDirectory`, the existing ~600k `update()` corpus keeps compiling
  and passing **unchanged** -- no corpus-wide `TestSupport` 2-arg `update(_:_:)` wrapper is introduced.
- `AppRuntime.send` keeps calling `update(&model, translatedMsg)` (AppRuntime.swift:296) on the `.live`
  default -- **no app change** at the send path.
- `TestSupport.makeTestEnv` drops its `recoveryDir` param (removed from `CoreEnv`) and adds a `homeDirectory`
  closure returning a fixed test home. `GoldenMasterTests` asserts on the _model_ (home-clean), so its
  recorded snapshot is unchanged by the added home; the fixed home matters only for suites that assert on
  snapshot/IPC payloads. If a narrow home-only test helper is ever added, its default env must still mint
  fresh `UUID`s and real time, overriding only `homeDirectory`.

## Public / package API policy

The headline benefit: **no new `public` or `package` annotations anywhere.** This is what distinguishes
the plan from the parked real-target plan.

- app -> core, app -> support: same module via symlinks. Everything stays `internal`. No annotations.
- core <-> support: **no edge exists.** Support depends only on `DanTermProtocol` + Foundation/Darwin.
  This is deliberate -- it is why moving the framer to protocol and `SessionLock` to support matters.
- core/support -> protocol: `DanTermProtocol` is the one real importable target; its app-facing symbols
  are already `public`. The moved framer types become `public` there, but **member access must be promoted
  explicitly** -- a `public` type does not export its members, and `IpcLineFramer`'s stored properties are
  `private` today so its synthesized init is not usable cross-module. Pin the exact surface:
  `public enum IpcFrameEvent` (its `.line(Data)` / `.oversized` cases are public via the public enum),
  `public struct IpcLineFramer`, `public init()`, `public static let maxLineBytes`, and
  `public mutating func append(_ data: Data) -> [IpcFrameEvent]`; the `private` buffer/oversized state stays
  private. That is the entire annotation delta: two small types, in the module that is already public by design.

If a future change ever makes support genuinely need a core type, prefer moving that type to protocol (if
it is protocol-shaped) or duplicating a tiny value over introducing a core->support-facing `public`
surface. Keeping the sibling modules dependency-free is the invariant that keeps this annotation-free.

**Open consideration -- `DanTermSupport` as a real `import` target.** The symlink/`internal` choice is the
right default for _core_ (the model's per-field `package`/`public` annotation tax is precisely what the
symlink doc rejected). Support is a weaker case for the symlink: its API surface is a handful of entry
points (`IpcConnection`, `Debouncer`, `CLIPathInstaller`, `RecoveryStore`/`SessionLock`), not a wide
value-type model, so making it a real target would cost a few `public`s, not a per-field tax -- and a real
target is exactly what would let the `danterm` CLI `import` `CLIPathInstaller`/`RecoveryStore` directly if it
grows beyond IPC. This plan still scaffolds support as a symlinked sibling (mirrors core, zero new
annotations, smallest diff now), but flag the real-target option as the _cheaper_ pivot than promoting core:
the trigger for promoting support is lower, since it does not carry the model's annotation tax. Decide it
the day a non-app consumer needs these helpers, not now.

## Build / test plumbing

`just test` -- add one line; keep everything else:

```
swift test --package-path lib/DanTermProtocol --filter DanTermProtocolTests
swift test --package-path lib/DanTermCore
swift test --package-path lib/DanTermSupport          # NEW
./scripts/core-purity-lint.sh                          # extended (see below)
./scripts/tests/core-purity-lint_test.sh               # extended fixtures
./scripts/tests/load-ghostty-version_test.sh
./scripts/tests/build-lib-stale-guard_test.sh
./scripts/tests/build-lib-contract_test.sh
```

Nested test packages:

- `lib/DanTermCore/Package.swift` -- unchanged manifest. Sources are globbed from `Sources/DanTermCore`,
  so files leaving that dir drop out automatically; tests are globbed from `Tests/DanTermCoreTests`, so
  moved test files drop out automatically. No manifest edit. Update the header comment that currently
  says "Cocoa-freeness is enforced separately by a local lint" to "purity (no IO) is enforced by a local
  lint" and note the new sibling.
- `lib/DanTermSupport/Package.swift` -- new, mirrors core: `library(name: "DanTermSupport")` depending on
  `.package(path: "../DanTermProtocol")`, a `DanTermSupportTests` target (Swift Testing; add CustomDump
  only if a moved test uses it), `platforms: [.macOS(.v26)]`, `swiftLanguageMode(.v5)`.

`test-ui.sh` -- **file-list path edits only, no rewrite.** It hand-compiles files by absolute path into a
Cocoa harness and does not use the symlink mechanism, so keeping the symlink means it keeps working. Edits:

- If `Persistence.swift` / `DanTermConfig.swift` are split or renamed, point the listed paths at the
  surviving pure core files.
- If any compiled UI view references a symbol that moved to support (audit `SidebarView`, `SplitContainerView`,
  `BadgeLabel`, `PaneSplitView`, `TodoInputView` -- none are expected to use Debouncer/IpcConnection/installer),
  add that one `lib/DanTermSupport/Sources/DanTermSupport/<file>.swift` to the compile list.
- Add a harness-local `extension TypedId { init() { self.init(rawValue: UUID()) } }` shim (a new
  `tests-ui/` file in the compile list), since the UI fixtures use no-arg `SplitId()`/`GroupId()`/`TabId()`/
  `PaneId()` and the core no-arg init is being removed. The harness is impure test code, so nondeterministic
  fixture ids are fine; this avoids rewriting every UI-fixture call site.

The purity lint (`scripts/core-purity-lint.sh`) -- extend to two profiles:

- `pure` profile (run against `lib/DanTermCore/Sources/DanTermCore`): keep the existing
  Cocoa/AppKit/SwiftUI import rule, and add a denylist pass that fails on side-effecting / nondeterministic
  tokens and imports. Two tiers:
  - **Hard bans, no allowlist** (these utilities leave core entirely -- the nested-package structural proof
    backs the ban): `import Darwin`, `import Network`, `FileManager`, `Process(`, `DispatchSource`,
    `DispatchQueue(`, `\.asyncAfter`, `Timer(`, `URLSession`, `NSWorkspace`, `setsockopt`, `Data\(contentsOf:`,
    `\.write\(to:`, `ProcessInfo`.
  - **Banned-with-allowlist** (the values stay in core but only at designated ambient seams): `NSHomeDirectory`
    and the **zero-arg** mints `UUID\(\)` / `Date\(\)` (match empty parens only -- NOT `UUID(uuidString:)` or
    `Date(timeIntervalSince1970:)`, which are pure deterministic construction used ~13 times in core:
    Update.swift, Model.swift, Persistence.swift). These three tokens are allowed **only** at the named
    ambient-seam sites: the `homeDirectory`/`newId`/`now` bindings in `CoreEnv.live` (CoreEnvironment.swift),
    and the `home: String = NSHomeDirectory()` defaults of `abbreviateHome` and `expandTilde`. Anywhere else
    in core they are a fresh nondeterminism leak.
  - Implement the allowlist with a per-line opt-out marker comment (e.g. a trailing
    `// core-purity: ambient-seam`) rather than file/line-number exemptions, so it travels with the code and
    survives edits. The marker is also the teaching pointer: it names the rule at the exact spot the
    exception is taken.

  Why these three need an allowlist (and the wide draft did not): the wide draft removed `update()`'s
  `= .live` default and moved `CoreEnv.live` out of core, so it could ban the tokens outright. The narrow
  design **keeps** that default, so `.live` (with `{ UUID() }`/`{ Date() }`/`{ NSHomeDirectory() }`) and the
  two leaf helpers' ambient defaults legitimately live in core -- hence the allowlist. The restore id
  generator is threaded (`newId`), so it mints nothing bare; the no-arg `TypedId.init()` is removed; so
  outside the allowlisted sites, ids/time/home enter core solely through the injected
  `newId`/`now`/`homeDirectory` seams.

- **Make the failure message the teaching surface.** When the denylist trips on a new `NSHomeDirectory`
  (or bare `UUID()`/`Date()`) in core, the message must point the developer/agent at the reproducibility
  rule -- inject when SAVED/SENT/ASSERTED, leave ambient when SHOWN -- and name the new ADR subsection. This
  is the enforcement point an agent actually hits, so it is where the rule must be restated, not just in docs.
- **Strip comments and string literals before the denylist pass.** A raw grep would false-positive on pure
  comments -- e.g. ModelOperations.swift:776 ("...the DispatchSourceTimer glue") stays in core and must not
  trip `DispatchSource`. Implement the pass to drop `//` line comments (and ideally `/* */` blocks and
  string-literal bodies) before tokenizing. The existing import rule is already line-anchored, so it is
  unaffected; the new token denylist is what needs the stripping.
- `portable` profile (run against `lib/DanTermSupport/Sources/DanTermSupport`): the Cocoa/AppKit/SwiftUI
  rule plus a `GhosttyKit` import rule. (GhosttyKit-freeness is also structurally guaranteed -- the
  support nested package has no GhosttyKit dependency -- so this is a fast-feedback echo of that.)
- Extend `scripts/tests/core-purity-lint_test.sh` with: positive fixtures (`import Darwin`, a `FileManager`
  line, a real `DispatchSource.makeTimerSource(...)`, an **un-marked** `NSHomeDirectory()` call, a bare
  `UUID()` and a bare `Date()` must trip the pure profile); allowlist fixtures (an `NSHomeDirectory()` /
  bare `UUID()` / bare `Date()` line carrying the `// core-purity: ambient-seam` marker must **PASS** the
  pure profile, and the marker must not blanket-exempt a _hard-ban_ token like `FileManager` on the same
  line -- the marker only relaxes the three allowlisted tokens); negative fixtures (`UUID(uuidString: ...)`
  and `Date(timeIntervalSince1970: ...)` as real code must PASS; a comment mentioning
  `DispatchSourceTimer`/`FileManager`/`UUID` must pass; a `ProcessInfo`-in-a-comment must not false-positive;
  and the same impure lines must pass the portable profile). Token-boundary the patterns so `ProcessInfo`
  and `Process(` are distinguishable, and `UUID()`/`Date()` match empty parens only.

The regex denylist is a heuristic regression guard, not the proof of purity. The proof is structural:
after migration the core dir contains no IO, and its nested package compiles green with no GhosttyKit and
no support dependency. The lint exists to keep it that way.

## Test plan

Boundary-proof tests (prove the pure/runtime split holds and cannot silently erode):

1. Extended purity lint + its self-test (above) -- the regression guard against IO re-entering core.
2. Structural proof via the build graph: `swift test --package-path lib/DanTermCore` must stay green with
   no GhosttyKit and no `DanTermSupport` dependency in the manifest -- any core file reaching for a moved
   symbol fails to resolve. `swift test --package-path lib/DanTermSupport` proves support compiles and
   tests without AppKit/GhosttyKit and without depending on core.
3. Determinism seam, proven -- scoped to where determinism is actually compared (SAVE/SEND/ASSERT), per
   the rule in "Determinism seam".
   - `GoldenMasterTests` needs **no home injection**. It asserts on the `AppModel` (`assertSnapshot(of: model)`,
     discarding every `update()` command return), and the model is home-clean (verified). Injecting a fixed
     home would not change its recorded snapshot. Confirm this scope holds; widen it to inject home _only_ if
     it is ever changed to also assert on command/IPC payloads. It keeps pinning the `newId`/`now` seams.
   - `TestSupport.makeTestEnv` drops `recoveryDir` (removed from `CoreEnv`) and adds a `homeDirectory` closure
     returning a fixed test home; this leaves GoldenMaster's snapshot unchanged but lets payload-asserting
     suites pin home. (The seam is a per-call `env`/`home` parameter, deliberately **not** a process-global
     `setenv("HOME", ...)` shortcut: Swift Testing runs suites in parallel in-process, so a global HOME would
     race nondeterministically across concurrent tests; the explicit parameter is race-free and, unlike
     `setenv`, lint-enforceable.)
   - Re-record **only** the `SnapshotTesting`/export fixtures whose tests assert on `toSnapshot` output (the
     save/send path) -- and only after those tests inject a fixed home -- so they stop depending on the
     author/CI HOME. Do **not** touch chrome fixtures; chrome stays ambient.
   - Targeted behavioral tests for the save/send/restore seams (all pass `home`/`newId` explicitly):
     (a) **restore-expand**: `loadValidatedInitFile`/`resolveLaunch` expand a saved `~/foo` to
     `<fixedHome>/foo` under a non-real fixed home, asserting machine independence;
     (b) **snapshot-abbreviate**: `toSnapshot` abbreviates a `<fixedHome>/foo` cwd back to `~/foo` under the
     fixed home, never the process HOME;
     (c) **id-less-restore**: a deterministic `newId` sequence into `loadValidatedInitFile` yields minted ids
     matching the sequence (reproducible restore).
   - **model-stays-home-clean** (pins the load-bearing premise that justifies the _whole_ narrow seam): bind
     the env's `homeDirectory` to the **real** ambient home and place the input cwd/title **under** it --
     `let h = NSHomeDirectory()`, env `homeDirectory = { h }`, drive `update()` with
     `.surfaceCwd(pane, h + "/sentinel")` and `.surfaceTitle(pane, h + "/sentinel")`, then assert the resulting
     `model` stores the **raw** paths (`model.pane(pane)?.cwd == h + "/sentinel"`, title likewise) -- never
     `~/sentinel`. Aligning env-home == leaf-default-home == the cwd's parent is deliberate: it makes _any_
     abbreviation-into-the-model collapse the stored path to `~/sentinel`, so the test catches **both** leak
     vectors -- a handler abbreviating via the injected `env.homeDirectory()` **and** one abbreviating via the
     leaf default `abbreviateHome(cwd)` (which reads ambient `NSHomeDirectory()`). A _fake_ non-real home with
     the cwd under it (the earlier draft, `"/fake/home"` + `"/fake/home/foo"`) catches only the injected
     vector: against a fake cwd not under the _real_ ambient home, a bare `abbreviateHome(cwd)` returns the
     path unchanged, the assertion passes, and the leak slips through -- and the lint can't catch it either,
     since the call site spells no `NSHomeDirectory` token (the ambient read hides in the leaf's allowlisted
     default). The assertion stays machine-independent **in form** -- it compares against whatever `h` is at
     runtime. Note the deliberate asymmetry with (a)/(b): those need a fake home that **differs** from ambient,
     because their job is to prove the _injected_ home (not ambient) is the one used, and a fake home unequal
     to ambient is exactly what exposes a "read ambient instead of injected" bug there. `model-stays-home-clean`
     has the opposite requirement -- all three homes aligned to ambient -- so it needs the opposite home; do
     **not** "simplify" it back to a fake home or it silently reopens the leaf-default hole. Behavioral
     and structure-insensitive: a pure refactor that keeps "model stores raw input" passes; only abbreviating
     _into the model_ breaks it. This is the guard (a)/(b)/(c) and `GoldenMasterTests` do **not** provide --
     (b) asserts the _snapshot_ abbreviates (the opposite direction), and a model-leak would record a
     stable-but-wrong value under the fixed home, so GoldenMaster would pass on the recording machine and fail
     only cross-machine (i.e. flakily). Feasible today: `.surfaceCwd` writes `$0.cwd = cwd` raw
     (Update.swift:711-712) and `.surfaceTitle` writes `$0.title = title` raw (705-706).
   - **abbreviate-boundary** (contingent -- travels with the boundary-aware `abbreviateHome` fix, not this
     plan per se): if that fix is folded in here, pin it here; if it is split to its own follow-up commit, this
     test goes with that commit. One line, no model, structure-insensitive -- assert the boundary case is left
     untouched, `abbreviateHome("/Users/danielle/foo", home: "/Users/dan") == "/Users/danielle/foo"` (the bare
     `hasPrefix(home)` bug mis-renders it `~ielle/foo`), alongside the positive
     `abbreviateHome("/Users/dan/foo", home: "/Users/dan") == "~/foo"`. Guards a later "simplification" back to
     `hasPrefix(home)` from silently reintroducing the glitch.
   - **Dropped:** the chrome/`displayTitle` machine-independence test from the wide draft -- chrome is
     render-only (SHOWN) and stays ambient, so there is nothing machine-dependent to pin. If coverage of the
     abbreviation logic itself is wanted, add a cheap direct unit test of `abbreviateHome(_:home:)` with an
     explicit home instead (it needs no model or `update()`).

Behavior-preservation tests (prove the move changes structure, not behavior):

4. Relocate, do not rewrite, the moved suites -- byte-for-byte where possible, adjusting only the
   `@testable import` target:
   - `IpcConnectionTests` (framer only) -> `DanTermProtocolTests` (XCTest or Swift Testing per that
     package's convention).
   - `DebouncerTests`, `CLIPathInstallerTests` -> `DanTermSupportTests`.
   - `CheckpointTests` splits: emission / `toSnapshot` fidelity / `mergeCheckpoints` rules stay in
     `DanTermCoreTests` (the `toSnapshot` tests inject the fixed home from item 3); the recovery-path-helper
     tests and the session-lock write/read/delete round-trip (the `testEnv`-pointed-at-temp-dir test) move
     to `DanTermSupportTests` as `RecoveryStoreTests`, reworked to pass the explicit `recoveryDir`/`now`/`pid`
     test seams instead of `CoreEnv`.
   - `DanTermConfigTests` / `ThemeColorParserTests`: parse-content tests stay in core; any file-load test
     moves to wherever the loader lands (app harness or dropped if it only exercised FileManager).
5. The full pure `update()` corpus (`UpdateIpcTests`, `UpdateTabTests`, `UpdatePaneTests`,
   `UpdateTabTodoTests`, `UpdateSearchTests`, `SnapshotTests`, `ExportTests`, `ReconcileTests`,
   `ModelOperationsTests`, ...) stays in `DanTermCoreTests` untouched and must remain green at every phase.
   This is the regression net that proves tab/pane/sidebar/todo/search/IPC behavior is unchanged.
6. `just test-ui` (AppKit harness) green after the `test-ui.sh` path edits.
7. `just build-run` launches; manual smoke: open/split/close panes, rename a tab, run an IPC command via
   the `danterm` CLI, trigger a checkpoint, quit cleanly (session lock deleted) -- all unchanged.

New tests are warranted only where the move newly enables them cheaply (optional, not required for the
migration): a socketpair-based `IpcConnection` lifecycle test in `DanTermSupportTests`, since the socket
class is currently untested and now lives in a display-free, GhosttyKit-free package.

## Documentation updates

- `docs/design/2026-05-28-core-module-via-symlink.md` -- **do not mark Superseded.** Its decision (use the
  symlink, reject the real-target annotation tax) is reaffirmed by this plan. Add a short "Extended by"
  note pointing at the new ADR, which adds the purity layer and the sibling `DanTermSupport` module using
  the same mechanism. Keep `Status: Accepted`.
- New ADR `docs/design/2026-05-28-pure-core-support-split.md` (ADR format: Status/Date/Context/Decision/
  Consequences/References): records the three-layer core/support/runtime split, the "core depends on
  nothing impure; support depends on nothing in core" invariant, purity enforced by lint + nested package,
  the framer move to protocol, and the deferred real-target migration with its trigger condition. **Include
  a named subsection "When to inject an ambient input: save/send/assert vs. show"** stating the
  reproducibility rule (inject when SAVED/SENT/ASSERTED; leave ambient when SHOWN), with the home seam as the
  worked example and a note that the same rule is why ids/time are injected but render text is not. This
  subsection is the canonical statement the lint failure message and AGENTS.md point back to. Also record the
  **typed-path decision** so it is not re-litigated: path fields stay `String`; adopt a typed path only when
  path _algebra_ arrives (file picker, project-root detection, path completion, directory-identity comparison),
  and at that point prefer absolute-vs-display _representation_ types over a bare `FilePath` -- representation
  confusion, not component matching, is the bug class that actually bites here.
- `docs/design/index.md` -- add the new ADR to the list.
- `AGENTS.md` (danterm) -- update the architecture section: the `lib/` tree gains `DanTermSupport/`; the
  data-flow note gains the IPC/persistence layering; the "Boundaries / Don't edit" note gains the second
  symlink. Add a one-paragraph note near the Architecture / data-flow section stating the inject-vs-ambient
  rule in a sentence and pointing at the new ADR's "When to inject an ambient input" subsection, so an agent
  threading a new home/id/time value learns the rule without rediscovering it. Also sync the **Build**
  section: `just test`'s prose enumeration ("protocol XCTest + core Swift Testing + core-purity lint + five
  shell self-tests") gains the new `DanTermSupport` package suite and the pure+portable lint profiles. Keep
  the existing typed-ID and Elm-architecture sections.
- Doc comments encoding the rule at the seam: a short `///` on `CoreEnv.homeDirectory` and on
  `abbreviateHome`/`expandTilde` stating the inject-vs-ambient rule and why the defaulted-ambient param
  exists (cross-referencing the ADR subsection). This puts the rule at the exact spot an implementer reads
  when deciding whether to pass `home`.
- If the `danterm` CLI surface is unaffected (it is -- IPC method semantics do not change), no
  `integrations/danterm/SKILL.md` edit. Note this explicitly in the implementing commit.

## Risks and mitigations

- **`update()` secretly consumes `env.recoveryDir`.** If true, dropping it from `CoreEnv` breaks core.
  Mitigation: Phase 0 greps `Update.swift`/`ModelOperations.swift` for `recoveryDir`; evidence says only
  the session-lock helpers use it, but verify before editing. Fallback: keep a `recoveryDir` seam on
  `CoreEnv` that returns an _injected_ URL (no FileManager body in core) supplied by the app at startup.
- **A UI view compiled by `test-ui.sh` uses a moved symbol.** Mitigation: the Phase-0 grep of `app/`
  already enumerates usages (Debouncer/IpcConnection live in AppRuntime/IpcServer, not in the listed
  views), so this is unlikely; if it surfaces at Phase 6, add the one support file to the compile list.
- **Lint regex false positives/negatives** -- pure comments mentioning `DispatchSourceTimer`/`FileManager`
  (ModelOperations.swift:776), `ProcessInfo` vs `Process(`, the ~13 legitimate `UUID(uuidString:)` parses vs
  bare `UUID()`, Dispatch usable without `import Dispatch`. Mitigation: strip comments/strings before the
  denylist pass, match `UUID()`/`Date()` empty-parens only, token-boundary the patterns, lean on the
  structural proof (nested package) as the real guarantee, and pin every edge case in the self-test.
- **`RecoveryStore` signature change vs the "no app edits" claim.** App call sites are zero-arg today
  (`writeSessionLockFile()`, `readSessionLockFile()`, `deleteSessionLockFile()` in `AppDelegate`/`main.swift`).
  Mitigation: keep the production entry points zero-arg (real `recoveryDir`/`now`/`pid` computed inside
  support) and add _defaulted_ params only for the test seam -- so the app sites stay byte-for-byte
  unchanged while the relocated round-trip test injects a temp dir + frozen date + fixed pid.
- **The HOME seam relies on the _real_ ambient default being correct (not a fake).** The narrow seam
  defaults `home` to the real `NSHomeDirectory()` (leaf helpers + `.live`), so a save/send/restore caller
  that omits `home` reads the user's real HOME -- correct in production. This is the inverse of the wide
  draft's hazard (a _fake_-home default that would restore into `/Users/danterm/foo`): there is no fake home
  anywhere, so omission is safe, not wrong. The residual risk is narrow -- a test or an update()-internal
  builder that _should_ inject a home forgets to, silently falls back to ambient, and so passes locally but
  is non-reproducible across machines. Mitigation: the restore-expand and snapshot-abbreviate behavioral
  tests inject a non-real fixed home and assert machine independence, failing loudly if a save/send path
  reads ambient instead of the injected home; the build-run check confirms cwd/title still render as `~/...`.
- **Home threading is internal, not spread across app callers.** Only the leaf helpers
  (`abbreviateHome`/`expandTilde`, defaulted) and the save/send/restore functions
  (`toSnapshot`/`toInitFile(_ model:)`/`loadValidatedInitFile`/`validateAndBuildDetailed`/`resolveLaunch`,
  `home: String? = nil`) gain a parameter; render APIs (`deriveTabChrome`/`formatToolbarLabel`, `TabModel`
  chrome) are untouched. The only explicit passes are the three update()-internal `toSnapshot` sites
  (`env.homeDirectory()`) and the behavioral tests (fixed home); app checkpoint/restore sites omit `home`.
  Mitigation: the surface is small and internal, and the behavioral tests catch a save/send path that
  wrongly reads ambient. (The wide draft's "demolish `TabModel`'s computed chrome + edit ~13 projection
  callers" is **dropped entirely** -- chrome is SHOWN-only and stays ambient.)
- **Removing the no-arg `TypedId.init()` reaches three compilation units.** (The wide draft also removed
  `update()`'s `= .live` default; the narrow design keeps it, so that half of this risk is gone -- no
  `TestSupport` 2-arg `update` wrapper, no `AppRuntime.send` change.) The `TypedId.init()` removal is the
  remaining load-bearing edit: it turns off-seam id minting into a compile error. It touches core (4 restore
  sites -> `rawValue: newId()`), app (rewrite `GroupId()` at AppRuntime.swift:84 to `rawValue: <app newId>`),
  and _both_ test units -- re-add a no-arg `extension TypedId` in `DanTermCoreTests` and in the `tests-ui`
  harness (they share no module, one extension each), keeping all 536 + 19 fixture sites compiling unchanged.
- **Restore id seam.** `validateAndBuildDetailed`/`loadValidatedInitFile` gain a non-defaulted `newId` (4
  bare `XxxId()` sites: Model.swift:434/451/564/596). Mitigation: bounded and compiler-forced; the id-less
  restore test pins reproducibility.
- **CI parity.** Adding `swift test --package-path lib/DanTermSupport` to `just test` means CI runs it; the
  new package has only sibling-path + Foundation deps, so no new external fetch beyond what core already
  pulls. Verify the CI `just test` step picks it up.
- **`.live` and the leaf helpers' ambient defaults stay in core (allowlisted), by design.** Because
  `update()` keeps its `= .live` default, `.live`'s `{ UUID() }`/`{ Date() }`/`{ NSHomeDirectory() }` and the
  `home: String = NSHomeDirectory()` defaults of `abbreviateHome`/`expandTilde` remain in core source -- they
  would trip the bare-`UUID()`/`Date()`/`NSHomeDirectory` bans, so the lint must allowlist exactly those
  sites. Risk if mishandled: a blanket ban fails CI on legitimate seams, or an over-broad allowlist lets a
  real leak through. Mitigation: the allowlist is a narrow per-line marker comment (not a file-wide
  exemption), and the self-test pins both directions (marked seam passes; unmarked `NSHomeDirectory` / bare
  mint fails). Everywhere else, ids/time/home enter core only through the injected `newId`/`now`/`homeDirectory`
  seams -- deliberate determinism on the save/send/assert paths. (This corrects the wide draft's premise that
  `CoreEnv.live` would move out of core; keeping `update()`'s default forces it to stay.)

## Migration sequence (each phase keeps `just test` green)

- **Phase 0 -- verify (no moves). DONE 2026-05-29 -- findings in
  `impl-notes/2026-05-29-phase0-findings.md`.** Confirmed `update()` consumes only `newId`/`now` (never
  `recoveryDir`); enumerated the pure/impure boundary in `Persistence.swift`, `DanTermConfig.swift`,
  `ThemeColorParser.swift`, and every `abbreviateHome`/`expandTilde` call site; re-grepped `app/` and
  `lib/DanTermCore/Tests` for every moving symbol. Line/count drifts it found are patched into this plan
  (App `GroupId()` 88->84; `configFilePath` AppRuntime 558/574->553/569; core-test mints ~410->536; literal
  `toSnapshot` in `tabSnapshotJSON` at 2209; `SessionLock` in `Model.swift:278`; `loadFromDisk` has 2 app
  callers + `parse(themeFileAt:)` 1). **Re-grep caveat:** every `file:line` ref in this plan was captured on a
  snapshot and drifts as files change -- re-grep by symbol name and re-confirm the line before editing in any
  later phase. No surprise blocks Phase 1.
- **Phase 1 -- scaffold support.** Add `lib/DanTermSupport/Package.swift` plus a minimal placeholder source
  (`Sources/DanTermSupport/DanTermSupport.swift`, e.g. an internal no-op decl) and a placeholder test
  (`Tests/DanTermSupportTests/PlaceholderTests.swift`, one trivial passing test) -- an empty target fails
  `swift build`/`swift test`, which would break the green invariant. Add the `app/DanTermSupport` symlink
  and the `swift test --package-path lib/DanTermSupport` line to `just test`. Builds green.
- **Phase 2 -- framer to protocol.** Move `IpcLineFramer`/`IpcFrameEvent` to `DanTermProtocol` with the
  explicit public surface pinned in the API policy (`public init()`, `public mutating func append`,
  `public static let maxLineBytes`, `public enum IpcFrameEvent`). Move `IpcConnectionTests` to
  `DanTermProtocolTests`. Green.
- **Phase 3 -- move the no-core-dep utilities.** Move `Debouncer`, `CLIPathInstaller`, and the
  `IpcConnection` class (now depending on protocol) to support; move `DebouncerTests` and
  `CLIPathInstallerTests` to `DanTermSupportTests` (delete the Phase-1 placeholder test once real tests
  land). App compiles unchanged (same-module via symlink). Green.
- **Phase 4 -- split persistence.** Keep the pure codec/merge/validation in core (rename to
  `SnapshotCodec.swift` if it clarifies). Move recovery-path helpers + session-lock IO + `SessionLock` (currently in `Model.swift:278`, not `Persistence.swift`) to
  `RecoveryStore.swift` in support, with zero-arg production entry points + defaulted test seams (no
  `CoreEnv`). Drop `recoveryDir` from `CoreEnv`. Split `CheckpointTests`: pure parts stay; path/lock parts
  become `RecoveryStoreTests`. App call sites keep identical (zero-arg) names, so no edits. Green.
- **Phase 5 -- determinism seam (home, ids, time).** Re-derived against the narrow design: the wide draft's
  projection/chrome churn is gone, so the **id seam is the main remaining work**. The home and id sub-steps
  are independently committable.
  - _HOME (narrow; no app-caller churn)._ Add `homeDirectory: () -> String` to `CoreEnv`; bind it in `.live`
    (`{ NSHomeDirectory() }`, staying in core). Give `abbreviateHome`/`expandTilde` a **defaulted**
    `home: String = NSHomeDirectory()`. Give the save/send/restore functions (`toSnapshot`,
    `toInitFile(_ model:)`, `loadValidatedInitFile`, `validateAndBuildDetailed`, `resolveLaunch`, plus the
    private `toPaneSnapshot`/`parseSplitNode`) a `home: String? = nil` threaded to the leaf (nil = ambient).
    Pass `env.homeDirectory()` at the three update()-internal `toSnapshot` sites (Update.swift:701, 1475, and
    `tabSnapshotJSON`, which gains a `home` param). Render APIs and `TabModel` chrome stay ambient (untouched);
    no app checkpoint/restore call site changes for home.
  - _IDS + TIME (compiler-forced; three compilation units)._ Thread a non-defaulted `newId: () -> UUID` into
    `validateAndBuildDetailed`/`loadValidatedInitFile` (the 4 bare `XxxId()` restore sites: Model.swift
    434/451/564/596 -> `rawValue: newId()`). Remove the no-arg `TypedId.init()`; rewrite the app's `GroupId()`
    (AppRuntime.swift:84) to `rawValue: <app newId>`; re-add a no-arg `extension TypedId` in both
    `DanTermCoreTests` and the `tests-ui` harness. Time already routes through `env.now()`.
  - _Env wiring (simplifications vs. the wide draft)._ `update()` **keeps** its `= .live` default; `.live`
    stays in core; `AppRuntime.send` is unchanged; **no** `TestSupport` 2-arg `update` wrapper. Update
    `TestSupport.makeTestEnv` to drop `recoveryDir` and add a fixed `homeDirectory`.
  - _Tests._ Add the restore-expand, snapshot-abbreviate, and id-sequence behavioral tests (explicit fixed
    home/`newId`). Re-record only the snapshot/export fixtures whose tests now inject a fixed home. Confirm
    `GoldenMasterTests` is unchanged (it asserts on the home-clean model). The `NSHomeDirectory`/`UUID()`/`Date()`
    lint allowlist lands with the rest of the lint work in Phase 6 (the pure profile can't pass until
    `configFilePath` leaves core there); until then the new token bans are not yet active. Green.
- **Phase 6 -- move trivial wrappers + enforce.** Move `loadFromDisk()` (with its internal `configFilePath()`
  call, DanTermConfig.swift:33), `parse(themeFileAt:)`, and the config path helper into `app/`.
  `configFilePath()` becomes an app-level helper (e.g. `DanTermConfigPaths`); repoint its five direct app
  callers (PreferencesPanel.swift:347, AppRuntime.swift:553/569, AppDelegate.swift:500, GhosttyApp.swift:79
  `loadDanTermOverlay`). Also repoint (or keep-by-name) `loadFromDisk()`'s two app callers
  (AppRuntime.swift:87, 1036) and `parse(themeFileAt:)`'s one (ThemeCatalog.swift:36). With `configFilePath()`
  gone, core's only remaining `NSHomeDirectory()` is the
  allowlisted `.live` + leaf-helper defaults. Extend `core-purity-lint.sh` (pure + portable profiles,
  comment/string stripping, the hard-ban IO tokens, and the **banned-with-allowlist**
  `NSHomeDirectory`/`UUID()`/`Date()` tokens via the per-line marker + teaching failure message) and
  `core-purity-lint_test.sh` (positive, allowlist, and negative fixtures); the pure profile now passes.
  Update the `test-ui.sh` file list. Run `just test` and `just test-ui`. Green.
- **Phase 7 -- docs.** Amend the symlink ADR ("Extended by ..."), write the new ADR, update
  `docs/design/index.md` and `AGENTS.md`, and prepend the superseded note to the parked plan.

Each phase is independently committable and leaves the tree green, so the migration can pause/resume.

## Relationship to the existing plan and the deferred real target

`polish-this-into-a-vectorized-stearns.md` is parked, not deleted. Its mechanism (real `DanTermCore`
target + `package` annotations + symlink removal) is the right move only when a **real second consumer must
`import` the domain model** -- e.g. the `danterm` CLI grows model logic beyond IPC, or a separate
menu-bar app or XPC/privileged helper needs `AppModel`/`update`. Today there is no such consumer: the CLI
speaks IPC through `DanTermProtocol`, which is already a real importable target.

If that trigger ever fires, this purity-first split makes the migration strictly cheaper and safer: the
core will be smaller (no IO utilities to drag across the boundary), and the annotations would then buy a
real compiler-enforced boundary for a real client. Revisit the parked plan at that point; until then,
keep the symlink and the zero-tax `internal` surface.

## Verification (end-to-end)

1. `just test` -- all four package suites + extended lint + lint self-test + shell self-tests green.
2. `swift test --package-path lib/DanTermCore` in isolation -- proves the pure core builds and tests with
   no GhosttyKit, no support, no IO.
3. `swift test --package-path lib/DanTermSupport` -- proves portable effects test without AppKit/GhosttyKit.
4. `./scripts/core-purity-lint.sh` (pure profile) exits 0 on core and would exit 1 if an `import Darwin` /
   `FileManager` / `DispatchSource` line were reintroduced, or if an **un-marked** `NSHomeDirectory()` / bare
   `UUID()` / bare `Date()` were added outside the allowlisted seam sites (confirm via the self-test fixtures).
5. Determinism/portability: the added save/send tests pass under a non-real fixed home -- restore expands
   `~/foo` and `toSnapshot` abbreviates back to `~/foo` against the injected home, and the re-recorded
   snapshot/export fixtures no longer depend on the machine's real HOME. `GoldenMasterTests` is home-clean by
   construction (asserts on the model); confirm it still passes with no home injection.
6. `just test-ui` green after path edits.
7. `just build-run` -- launch DanTerm Dev; smoke test split/close panes, tab rename, an IPC command via the
   `danterm` CLI, a checkpoint write, a clean quit (session lock removed), and that cwd/title render as
   `~/...` (the ambient home flows correctly through the render path and the `.live` default). Behavior
   identical to today.

## Implementaion notes:

Phase 1: done 2026-05-29. Scaffolded the empty `DanTermSupport` sibling exactly as
specified -- nested `Package.swift` (kept the `../DanTermProtocol` path dep + product
dep per the manifest spec / hand-off recommendation, so Phase 3's `IpcConnection` needs
no manifest churn), placeholder source (`DanTermSupport.swift`,
`enum DanTermSupportModulePlaceholder {}`), placeholder Swift Testing suite
(`PlaceholderTests`), the tracked relative symlink
`app/DanTermSupport -> ../lib/DanTermSupport/Sources/DanTermSupport`, and the
`swift test --package-path lib/DanTermSupport` line in `just test` (after core, before
the lint). No code moved; root `Package.swift` and `lib/DanTermCore/Package.swift` both
untouched.

- **Divergence (one, necessary): `.gitignore`.** It ignores all of `lib/` via `lib/*`
  and un-ignores only the tracked sibling packages by name (`!lib/DanTermProtocol/`,
  `!lib/DanTermCore/`), so the new `lib/DanTermSupport/` tree was ignored and could not
  be staged. Added `!lib/DanTermSupport/` (and updated the adjacent comment), mirroring
  the existing pattern; committed alongside the scaffold. Outside the hand-off's literal
  file list but required for the scaffolding to be trackable -- and it pre-clears the
  same footgun for Phases 2-4 when real source/test files land under the tree.
- **Deferred per hand-off:** the `lib/DanTermCore/Package.swift` header retitle ("purity
  (no IO) is enforced by a local lint") is NOT done -- the lint only bans Cocoa until
  Phase 6, so that claim isn't true yet. Defer to Phase 6/7.
- **Placeholder fates (reminder):** delete `DanTermSupport.swift` when the first real
  support source lands (Phase 3); delete `PlaceholderTests.swift` when the first real
  suite lands (Phase 3).
- **Verification (all green):** `swift test --package-path lib/DanTermSupport` builds +
  passes in isolation (resolves only the local `../DanTermProtocol` path dep, no
  GhosttyKit/AppKit, no `DanTermCore` dep -- the sibling-independence proof). `just test`
  green end to end (core 1069 tests / 39 suites; the new support line; purity lint + all
  five shell self-tests). `just build` green -- the app target compiled
  `DanTermSupport.swift` through the symlink (`[3/9] Compiling DanTerm DanTermSupport.swift`),
  proving the placeholder globs cleanly into `DanTerm` same-module. Symlink verified
  relative and pointing at `Sources/DanTermSupport` (no `Package.swift` exposed to the
  app glob).

Phase 2: done 2026-05-29. Moved the two pure IPC line-framing types
(`IpcLineFramer`, `IpcFrameEvent`) out of `DanTermCore`'s `IpcConnection.swift` into a
new `DanTermProtocol` source (`Sources/DanTermProtocol/IpcLineFramer.swift`), promoted to
the public surface pinned in the API policy. The `IpcConnection` socket class **stays in
core** (it moves to support in Phase 3) and now resolves the framer through the
`import DanTermProtocol` it already had -- no new import. Relocated the framer-only test
suite to `DanTermProtocolTests`. No app, manifest, or `.gitignore` changes (protocol globs
its sources/tests by directory; core already depends on protocol).

- **Public-surface delta (the only `public` the whole split adds):** `public enum
  IpcFrameEvent` (its `.line(Data)`/`.oversized` cases are public via the enum, and the
  `Data`-payload enum still synthesizes `Equatable` -- needed by the `events.contains(.oversized)`
  assertion), `public struct IpcLineFramer`, `public static let maxLineBytes`,
  `public mutating func append(_:)`, and an **explicit `public init() {}`**. The explicit
  init is load-bearing: with `buffer`/`isOversized` `private`, the synthesized default init
  is `private`, so `IpcLineFramer()` would not construct cross-module (both the tests and
  `IpcConnection` build it with no args). The two stored properties stay `private`.
- **Test framework decision -- converted to XCTest (the one judgment call).** Took the
  hand-off's recommended option over byte-for-byte relocation, for two reasons: (1)
  `DanTermProtocolTests` is 100% XCTest, so XCTest is "per that package's convention"; (2)
  the silent-skip hazard -- `just test` runs the suite as
  `swift test --package-path lib/DanTermProtocol --filter DanTermProtocolTests`, and a
  Swift Testing suite's IDs may not carry the `DanTermProtocolTests` prefix the filter keys
  on, so it could pass in isolation yet be silently skipped under the gate. Confirmed the 4
  tests actually execute under that exact filter (see verification). Mechanical, behavior-
  preserving mapping: `@Suite struct` -> `final class: XCTestCase`; `@Test("...") func foo`
  -> `func testFoo` (display strings dropped); `#expect(a == b)` -> `XCTAssertEqual`;
  `#expect(cond, msg)` -> `XCTAssertTrue`; `Issue.record` -> `XCTFail`; imports become
  `Foundation`/`XCTest`/`@testable import DanTermProtocol`. The `// Intent / Why it exists
  / Scenario` preambles and the private `ipcLine(_:)` helper are kept verbatim.
- **Renamed the moved test `IpcConnectionTests.swift` -> `IpcLineFramerTests.swift`** (via
  `git mv`): the suite tests the framer, not the connection, and the new name matches
  protocol's `<Type>Tests.swift` convention. Rewrote its top-of-file header (the old one
  described a "Swift Testing migration" that no longer holds).
- **Tightened the core `IpcConnection.swift` line-1 header** -- framing has left the file,
  so it now reads "Unix-socket connection lifecycle and JSON-RPC response writing ...; line
  framing lives in DanTermProtocol (IpcLineFramer)".
- **Zero app churn, confirmed.** Re-grepped `app` + `lib` (excluding `.build`): the framer
  types had exactly two referencers -- the core source and the moved test. `app/IpcServer.swift`
  uses the `IpcConnection` class, never the framer types. So `app/` needed no edits.
- **CLI/docs:** IPC method semantics are unchanged (only where the framer type lives moved),
  so per AGENTS.md's CLI-doc rule **no `integrations/danterm/SKILL.md` edit** -- stated in the
  commit body. No `AGENTS.md`/ADR edits either (architecture-doc updates are batched into
  Phase 7).
- **Verification (all green):**
  - Protocol: 121 XCTest tests, 0 failures. The 4 framer tests
    (`testOneFullLineEmitsOneFrame`, `testTwoFullLinesInOneReadEmitTwoFrames`,
    `testSplitFrameReassemblesAfterSecondChunk`, `testOversizedLineEmitsRejectionEvent`)
    confirmed executed by name under the exact `--filter DanTermProtocolTests` gate. The
    Swift Testing runner reported "0 tests in 0 suites" for the package -- i.e. there are no
    Swift Testing tests here, so the silent-skip hazard is moot, exactly as the XCTest choice
    intends.
  - Core: **1065 tests / 38 suites** -- down exactly the 4-test framer suite from the
    pre-Phase-2 1069/39. This green run is the structural proof core has no dangling framer
    reference (its only referencer, `IpcConnection.swift`, now resolves the type via
    `import DanTermProtocol`).
  - Support: 1 test / 1 suite, untouched and green.
  - `just test`: green end to end (the three package suites + purity lint + all five shell
    self-tests). The purity lint passes with `IpcConnection`'s `import Darwin`/sockets still
    in core -- expected, since the IO-token bans don't land until Phase 6.
  - `just build`: green. The app target compiled the core `IpcConnection.swift` through the
    symlink against the framer's new home (`[20/36] Compiling DanTerm IpcConnection.swift`)
    and linked cleanly. (A transient SourceKit "Cannot find 'IpcLineFramer' in scope"
    warning surfaced immediately after the edit -- the prebuilt `DanTermProtocol.swiftmodule`
    predated the new public type; the real compile resolves it, as the green core package and
    app build both confirm.)

Phase 3: done 2026-05-29. Moved the three portable side-effecting utilities
(`Debouncer` timer, `CLIPathInstaller` Process/FileManager, and the post-Phase-2
`IpcConnection` socket class) out of `DanTermCore` into `DanTermSupport`, and
relocated their two Swift Testing suites (`DebouncerTests`, `CLIPathInstallerTests`)
into `DanTermSupportTests`. Every move was a byte-for-byte `git mv` except the two
test files, whose only edit was the `@testable import DanTermCore` ->
`@testable import DanTermSupport` target line (R099 in the diff; the three sources
are R100). Deleted both Phase-1 placeholders (`DanTermSupport.swift`,
`PlaceholderTests.swift`) in the same move commit -- an empty target fails
`swift build`, and the placeholder test references the now-gone enum, so neither
could outlive the first real source/suite.

- **Zero public annotations added (the key contrast with Phase 2).** The moved
  types stay `internal`: the app reaches them same-module through the
  `app/DanTermSupport` symlink, and `DanTermSupportTests` reaches them via
  `@testable import DanTermSupport`, so no symbol crosses a real module boundary.
  Confirmed `grep -c public` == 0 on all three moved sources; no access level
  changed. (Phase 2 had to make the framer `public` precisely because it moved
  into the real `DanTermProtocol` import target; Phase 3 crosses no such boundary,
  so it adds nothing -- this is the annotation-free payoff the split was designed
  for.)
- **No framework conversion needed.** Both suites are already Swift Testing
  (`@Suite`/`@Test`/`#expect`), matching `DanTermSupport`'s convention (the deleted
  placeholder suite was Swift Testing too), so unlike Phase 2's XCTest conversion
  the only change was the `@testable import` line -- headers, preambles, bodies,
  and the private `InstallerFixture`/`makeInstallerFixture` helper traveled
  byte-for-byte. The headers' "Swift Testing migration of the legacy harness" note
  is a historical fact about a prior migration and stays true; left untouched.
- **No silent-skip hazard (Phase 2's concern does not apply here).** `just test`
  runs the support suite as `swift test --package-path lib/DanTermSupport` with
  **no `--filter`**, so the moved Swift Testing suites run naturally. Confirmed by
  eye that both `DebouncerTests` (4) and `CLIPathInstallerTests` (7) executed.
- **Zero app / manifest / `.gitignore` / `test-ui` churn, confirmed.** The three
  symbols are referenced by `app/AppRuntime.swift`, `app/IpcServer.swift`, and
  `app/AppDelegate.swift`, all same-module -- moving the files from the
  `app/DanTermCore` symlinked dir to the `app/DanTermSupport` symlinked dir keeps
  them in the same `DanTerm` module, so those references resolved unchanged with no
  edits. Both nested manifests glob by directory (files leaving/entering are picked
  up automatically); the support target already depended on the `DanTermProtocol`
  product (so `IpcConnection`'s `import DanTermProtocol` resolves); `.gitignore`
  already un-ignores the support tree (Phase 1). No script and no `test-ui.sh`
  references any of the three, so `just test-ui` is unaffected and needed no path
  edits.
- **CLI/docs:** IPC method semantics are unchanged (only where the socket class
  lives moved), so per AGENTS.md's CLI-doc rule **no `integrations/danterm/SKILL.md`
  edit** -- stated in the commit body. No `AGENTS.md`/ADR edits (architecture-doc
  updates are batched into Phase 7). No lint changes: the portable profile + the
  IO-token bans land in Phase 6, and core losing `import Darwin` (with
  `IpcConnection` gone) keeps the current Cocoa-only pure-profile lint green.
- **Verification (all green):**
  - Support: **11 tests / 2 suites** (was 1/1) -- the placeholder's 1/1 removed,
    +4 `DebouncerTests`, +7 `CLIPathInstallerTests`. Green in isolation with the
    support manifest depending on **no** core -- the structural proof that none of
    the moved files secretly referenced a core type.
  - Core: **1054 tests / 36 suites** (was 1065/38) -- down exactly the 11-test,
    2-suite utilities. A green core run at 1054/36 is the structural proof core has
    nothing dangling after the utilities leave.
  - Protocol: **121 tests** (incl. the 4 framer tests), unchanged.
  - `just test`: green end to end (the three package suites + purity lint + all
    five shell self-tests).
  - `just build`: green. The app target compiled the three files through the
    `app/DanTermSupport` symlink (`[35/63] CLIPathInstaller.swift`,
    `[36/63] Debouncer.swift`, `[37/63] IpcConnection.swift`) and linked cleanly,
    proving the same-module move keeps the app's references intact with no source
    edits.
