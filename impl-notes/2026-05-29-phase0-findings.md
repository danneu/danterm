# Phase 0 findings — pure-core refactor (read-only recon)

- **Plan:** `plans/impl/2026-05-29-pure-core-portable-support.md`
- **Branch:** `refactor-pure-core`
- **Date:** 2026-05-29
- **Scope:** Pure reconnaissance — verify the plan's factual claims against live
  source before any code moves. No edits to source/tests/config were made during
  this phase. The plan itself was subsequently patched with the corrections below
  (line patches + structural fixes + a re-grep caveat).

> **Re-grep before you edit.** Every `file:line` below was captured on 2026-05-29.
> Line numbers drift as files change; symbol names do not. Before editing in a
> later phase, re-grep by symbol name and re-confirm the line.

Verdict up front: **Phase 1 can proceed as written.** Surprises found are
non-blocking; they only adjust Phases 4/5/6 (see §7).

---

## 1. `update()` env usage — plan's load-bearing premise CONFIRMED

`update()` is a single function: `update(_ model: inout AppModel, _ msg: Msg, env: CoreEnv = .live) -> [Command]` at `Update.swift:6` (default `.live`, as the plan assumes).

Every `env.` access in `Update.swift` is `env.newId()` or `env.now()` — **nothing else**:

- `env.newId()`: `Update.swift:36, 37, 166, 167, 266, 298, 388, 738, 769, 973, 1100, 1242, 1368, 1736`
- `env.now()`: `Update.swift:736, 767`

**`env.recoveryDir` is never read by `update()`.** Grep for `recoveryDir|homeDirectory` in both `Update.swift` and `ModelOperations.swift` returns **0** matches each. `recoveryDir` appears in core only at `CoreEnvironment.swift:10/15` (the field + `.live` binding) and `Persistence.swift:266` (the session-lock helper that moves to support). **Plan Risk #1 is resolved — dropping `recoveryDir` from `CoreEnv` cannot break `update()`.**

`homeDirectory` does **NOT** exist on `CoreEnv` today (0 matches). Current definition (`CoreEnvironment.swift:7-17`):

```swift
struct CoreEnv {
    var newId: () -> UUID
    var now: () -> Date
    var recoveryDir: () -> URL          // <- removed in Phase 4
    static let live = CoreEnv(
        newId: { UUID() },              // CoreEnvironment.swift:13  (UUID() allowlist seam)
        now: { Date() },                // CoreEnvironment.swift:14  (Date() allowlist seam)
        recoveryDir: { recoveryDirectoryURL() }
    )
}
```

## 2. Pure/impure boundary, per file

### `Persistence.swift` (split target — Phase 4)
| Symbol | Line | Class | Destination |
|---|---|---|---|
| `ValidatedAppRestore`, `AppInitFileLoadError` | 14, 20 | pure types | core |
| `loadValidatedInitFile(from:)` | 27 | pure (decode+validate) | core |
| `restoreCommandBehavior(from:)` | 55 | pure | core |
| `restoreInitialInput(for:behavior:)` | 74 | pure | core |
| `toInitFile(_ model:)` / `toInitFile(snapshot:)` | 86 / 92 | pure | core |
| `toSnapshot(_:)` | 96 | pure codec | core (gets `home` param) |
| `toPaneSnapshot(_:)` *(private)* | 129 | pure — **calls `abbreviateHome` @130** | core (gets `home` param) |
| `toSplitNodeSnapshot` *(private)* | 152 | pure | core |
| `graftScrollback(onto:…)` / `graftScrollbackIntoNode` | 175 / 198 | pure | core |
| `mergeCheckpoints(light:enriched:)` | 251 | pure | core |
| `truncateScrollback(_:…)` | 307 | pure | core |
| **`recoveryDirectoryURL(bundleId:)`** | 230 | **impure** (`FileManager` @233) | support |
| **`lightCheckpointURL()` / `enrichedCheckpointURL()`** | 238 / 242 | impure (call `recoveryDirectoryURL`) | support |
| **`sessionLockURL(env:)`** | 265 | impure — reads `env.recoveryDir()` @266 | support (drop `CoreEnv`) |
| **`writeSessionLockFile(env:)`** | 279 | **impure** — `ProcessInfo`@280, `FileManager`@286, `.write(to:)`@287 | support |
| **`readSessionLockFile(env:)`** | 291 | **impure** — `Data(contentsOf:)`@292 | support |
| **`deleteSessionLockFile(env:)`** | 299 | **impure** — `FileManager.removeItem`@300 | support |

No straddlers — the cut between pure codec (top) and impure recovery/lock IO (`:230` onward) is clean.

### `DanTermConfig.swift` (split target — Phase 6)
| Symbol | Line | Class | Destination |
|---|---|---|---|
| `AlertClearMode`, `DanTermConfig` | 7, 12 | pure types | core |
| **`DanTermConfigParser.configFilePath()`** | 25 | **impure** (`NSHomeDirectory()` @26) | app |
| **`DanTermConfigParser.loadFromDisk()`** | 32 | **impure** (`FileManager` @34; calls `configFilePath()` @33) | app |
| `DanTermConfigParser.parse(content:)` | 43 | pure | core |
| `DanTermConfigWriter.setKey/removeKey` | 72 / 100 | pure | core |

**Straddler:** `DanTermConfigParser` is one `enum` whose members split across the core/app boundary (`parse(content:)` stays; `configFilePath`/`loadFromDisk` leave). Phase 6 must split the enum (e.g. app-side `extension DanTermConfigParser` or a new `DanTermConfigPaths`).

### `ThemeColorParser.swift` (split target — Phase 6)
| Symbol | Line | Class | Destination |
|---|---|---|---|
| `ThemeColorHex` | 8 | pure type | core |
| `ThemeColorParser.parse(themeContent:)` | 27 | pure | core |
| **`ThemeColorParser.parse(themeFileAt:)`** | 66 | **impure** (`FileManager` @67) | app |
| `parsePaletteEntry` / `validateHex` *(private)* | 73 / 87 | pure | core |

**Straddler:** same shape — one `enum ThemeColorParser` with `parse(themeFileAt:)` leaving and `parse(themeContent:)` staying.

## 3. `abbreviateHome` / `expandTilde` full call-site inventory

**`abbreviateHome`** — def `ModelOperations.swift:470`; boundary bug `guard path.hasPrefix(home)` at `ModelOperations.swift:472` (plan's cited line ✓). Four call sites:

| Site | Enclosing fn | Reached from | Class | Action |
|---|---|---|---|---|
| `Persistence.swift:130` | `toPaneSnapshot` | `toSnapshot` (`.exportState`, `ls`, `tabSnapshotJSON`) | **SAVED/SENT** | thread `home` (Phase 5) |
| `ModelOperations.swift:478` | `deriveTabChrome` (title) | `TabModel.title` computed `Model.swift:124` | **SHOWN** | ambient (untouched) |
| `ModelOperations.swift:479` | `deriveTabChrome` (subtitle) | `TabModel.subtitle` `Model.swift:128` | **SHOWN** | ambient (untouched) |
| `ModelOperations.swift:644` | `formatToolbarLabel` | `app/PaneWrapperView.swift:254` (toolbar label) | **SHOWN** | ambient (untouched) |

**`expandTilde`** — def `Model.swift:540` (body reads `NSHomeDirectory()` @542). Two call sites, both in `resolveLaunch`:

| Site | Enclosing fn | Reached from | Class | Action |
|---|---|---|---|---|
| `Model.swift:530` | `resolveLaunch` (`launch.cwd`) | restore chain ↓ | **ASSERTED** (restore) | thread `home` (Phase 5) |
| `Model.swift:532` | `resolveLaunch` (`pane.cwd`) | restore chain ↓ | **ASSERTED** (restore) | thread `home` (Phase 5) |

**Restore threading chain (verified):** `loadValidatedInitFile` (`Persistence.swift:27`) → `validateAndBuildDetailed` (`Model.swift:400`, calls `resolveLaunch` @`Model.swift:577`) → `resolveLaunch` (`Model.swift:527`) → `expandTilde`. `resolveLaunch` has a second, app-side caller `app/AppRuntime.swift:1126` (omits `home` → ambient). The plan's "thread home through `loadValidatedInitFile`/`validateAndBuildDetailed`/`resolveLaunch`" is accurate, with the nuance that `expandTilde`'s **only** callers are inside `resolveLaunch`.

**`toSnapshot` call sites in `update()` (the SAVED/SENT path to `abbreviateHome`):** `Update.swift:701` (`.exportState`), `Update.swift:1475` (`ls` reply), `Update.swift:2209` (inside `tabSnapshotJSON`). Nuance: the literal `toSnapshot(model)` inside `tabSnapshotJSON` is at **2209**; `Update.swift:2116` is the `tabSnapshotJSON` **call** (where `env.homeDirectory()` is passed) and `Update.swift:2208` is its **definition**.

**No site the plan missed.** Confirmed the indirect home path the plan describes: the close-tab confirmation passes `tab.displayTitle` (`Update.swift:120, 1422`) into `.showCloseTabConfirmation`; `displayTitle` = `customTitle ?? title` (`Model.swift:127`), and `title` reaches `abbreviateHome` via `deriveTabChrome`. This is **SHOWN** (alert text) and correctly stays ambient — `emitCloseTabConfirmation` (`ModelOperations.swift:516`) itself does **not** call `abbreviateHome`; it just forwards the caller's string (`ModelOperations.swift:524`).

## 4. Moving-symbol call-site inventory

Searched `app/*.swift`, `lib/DanTermCore/Sources/`, `lib/DanTermCore/Tests/`, `tests-ui/`. **No moving symbol appears in any `tests-ui/` file or in any AppKit view** — confirms the plan's Risk #2 mitigation (Debouncer/IpcConnection/etc. live only in `AppRuntime`/`IpcServer`/`AppDelegate`).

### → `DanTermProtocol`
- **`IpcFrameEvent`** (def `IpcConnection.swift:6`), **`IpcLineFramer`** (def `IpcConnection.swift:11`): only non-test consumer is `IpcConnection` itself (`IpcConnection.swift:62`). Tests: `IpcConnectionTests.swift:19,35,48,62,66,67`. **Zero `app/` callers** — so the framer→protocol move lets `IpcConnection` depend on protocol exactly as planned.

### → `DanTermSupport`
- **`Debouncer`** (def `Debouncer.swift:18`): app — `AppRuntime.swift:63, 69, 583, 634, 637-639, 654-655, 823-824, 844, 851(comment), 874`. Tests — `DebouncerTests.swift`. No other consumer.
- **`CLIPathInstaller`** (def `CLIPathInstaller.swift:4`): app — `AppDelegate.swift:536`. Tests — `CLIPathInstallerTests.swift` (many).
- **`IpcConnection`** class (def `IpcConnection.swift:41`): app — `AppRuntime.swift:70, 352`; `IpcServer.swift:13, 60, 73, 77, 87`.
- **Recovery-path helpers:** `recoveryDirectoryURL` (def `Persistence.swift:230`) — app `AppRuntime.swift:930`, internal `CoreEnvironment.swift:15`, tests `CheckpointTests.swift:363-364`. `lightCheckpointURL` (def `:238`) — app `AppRuntime.swift:900`, `main.swift:89`, test `:377`. `enrichedCheckpointURL` (def `:242`) — app `AppRuntime.swift:924`, `main.swift:90`, test `:386`. `sessionLockURL` (def `:265`) — internal only + test `:395`.
- **Session-lock IO:** `writeSessionLockFile` (def `:279`) — app `AppDelegate.swift:129`. `readSessionLockFile` (def `:291`) — app `main.swift:83`. `deleteSessionLockFile` (def `:299`) — app `AppDelegate.swift:720`. All three app calls are **zero-arg**, confirming the plan's "byte-for-byte unchanged" claim.
- **`SessionLock` type** — ⚠ **defined at `Model.swift:278`, NOT in `Persistence.swift`.** Consumers: `Persistence.swift:280,295` (the IO helpers, which move) + `CheckpointTests`. Nothing else in core references it, so the move out of `Model.swift` is clean — but the plan implies it lives near the persistence code (see §7).
- **`recoveryDir`** (CoreEnv field): `CoreEnvironment.swift:10`, `Persistence.swift:266` only.

### → `app/`
- **`configFilePath`** (the moving one, `DanTermConfigParser.configFilePath()`): see §5 table.
- **`loadFromDisk`** (def `DanTermConfig.swift:32`): app — `AppRuntime.swift:87, 1036` (2 callers, **not enumerated in the original plan**; see §7).
- **`parse(themeFileAt:)`** (def `ThemeColorParser.swift:66`): app — `ThemeCatalog.swift:36` (1 caller).

## 5. Line/count claim re-confirmation (drift corrected)

| Plan claim | Plan value | **Actual** | Verdict |
|---|---|---|---|
| Core bare id mints | 4 @ `Model.swift:434/451/564/596` | **4 @ `Model.swift:434/451/564/596`** (`GroupId`/`TabId`/`PaneId`/`SplitId`) | ✓ exact |
| App bare id mint | 1 @ `AppRuntime.swift:88` | **1 @ `AppRuntime.swift:84`** | ⚠ **line 88→84** |
| Core-test bare mints | ~410 | **536** (GroupId 52, TabId 155, PaneId 188, SplitId 53, AlertId 88) | ⚠ **undercount** (see note) |
| tests-ui bare mints | 19 | **19** (PaneSplitViewTests 2, SidebarSelectionCacheTests 12, SplitContainerViewTests 5) | ✓ exact |
| `configFilePath` callers | 5: Pref 347, AppRuntime 558/574, AppDelegate 500, GhosttyApp 79 | **5: Pref `347`, AppRuntime `553`/`569`, AppDelegate `500`, GhosttyApp `79`** (+ internal `DanTermConfig.swift:33`) | ⚠ **AppRuntime 558→553, 574→569** |
| `.surfaceCwd` raw write | `Update.swift:711-712` | case @711, `$0.cwd = cwd` @**712** | ✓ |
| `.surfaceTitle` raw write | `Update.swift:705-706` | case @705, `$0.title = title` @**706** | ✓ |
| session-lock helpers `env: CoreEnv = .live` | `Persistence.swift:265-301` | `sessionLockURL` @265, write @279, read @291, delete @299 — all defaulted `env` | ✓ |
| `TypedId.init()` no-arg | `Model.swift:14` | `init() { self.rawValue = UUID() }` @**14** | ✓ |
| `abbreviateHome` def | `ModelOperations.swift:470` | @**470** | ✓ |
| `expandTilde` def | `Model.swift:540` | @**540** | ✓ |

**Notes on the drifts:**

- **`AppRuntime.swift` line drift (88→84, 558→553, 574→569).** AppRuntime line refs run ~4-5 lines high in the plan; the file is slightly shorter now. `AppRuntime.swift:84` is `groups: [GroupModel(id: GroupId(), name: "General")]` (the initial group — exactly the symbol the plan means). Rewrite target for Phase 5 is line **84**.
- **Core-test count 410→536.** The word-boundary count (`[[:<:]]…\(\)`, excludes the `scrollbackByPaneId()` substring) is **536**, or **448** excluding `AlertId`. This is benign: the re-added test-only `extension TypedId { init() }` shim is generic over `Tag`, so it covers all 5 id kinds (`AlertId` included — note `AlertId` is a 5th `TypedId` tag at `Model.swift:22`, beyond the 4 the plan names) at any count. The mechanism is count-independent; only the stated number is stale.
- **`toSnapshot` "2116/2208" nuance.** The literal `toSnapshot(model)` calls in `update()` are at `Update.swift:701, 1475, 2209`. `Update.swift:2116` is the **call site** of `tabSnapshotJSON` (inside an IPC handler with `env` in scope) and `Update.swift:2208` is `tabSnapshotJSON`'s **definition** (the `toSnapshot` it wraps is the next line, 2209). The plan's intent is right — `tabSnapshotJSON` gains a `home` param passed `env.homeDirectory()` at the 2116 call — just note the literal `toSnapshot(` is at **2209**.

## 6. Lint baseline (`scripts/core-purity-lint.sh`)

Current state (21 lines total):

- **One rule:** a single `grep -rnE` (line 17) failing on `import Cocoa|AppKit|SwiftUI`, tolerant of leading whitespace + optional `@attr`, with a trailing non-identifier guard so `CocoaLumberjack`/`CocoaAsyncSocket` don't false-positive.
- **No token denylist** — `import Darwin`, `FileManager`, `Process`, `DispatchSource`, `NSHomeDirectory`, bare `UUID()`/`Date()`, etc. are all currently **unguarded**.
- **No allowlist / per-line markers**, **no comment/string stripping**, **no separate profiles.** Single target, defaulting to `lib/DanTermCore/Sources/DanTermCore`, overridable via `$1` (`TARGET="${1:-$DEFAULT_TARGET}"`).

Phase 6 adds: pure+portable profiles, the hard-ban IO token pass, the `NSHomeDirectory`/`UUID()`/`Date()` banned-with-allowlist tier, comment/string stripping, and the teaching failure message. **Full impure-token map for that work (every hard-ban token currently in core):**

- `import Darwin` → `IpcConnection.swift:4` *(→support)*
- `FileManager` → `DanTermConfig.swift:34` *(→app)*, `Persistence.swift:233/286/300` *(→support)*, `CLIPathInstaller.swift:21` *(→support)*, `ThemeColorParser.swift:67` *(→app)*, + comments `Persistence.swift:1,6`
- `Process(` → `CLIPathInstaller.swift:38` *(→support)*
- `ProcessInfo` → `Persistence.swift:280` *(→support)*
- `DispatchSource` → `Debouncer.swift:20,41` *(→support)*; **comment-only** `ModelOperations.swift:776` *(STAYS — the canonical comment-stripping false-positive the plan names ✓)*
- `DispatchQueue(` → `IpcConnection.swift:53` *(→support)*
- `setsockopt` → `IpcConnection.swift:186` *(→support)*
- `Data(contentsOf:` → `Persistence.swift:292` *(→support)* + comment `:6`
- `.write(to:` → `Persistence.swift:287` *(→support)*
- `NSHomeDirectory` → `Model.swift:542` (`expandTilde`, STAYS→allowlist), `ModelOperations.swift:471` (`abbreviateHome`, STAYS→allowlist), `DanTermConfig.swift:26` (`configFilePath`, →app)
- bare `UUID()` → `IpcConnection.swift:50` *(→support)*, `Model.swift:14` *(removed Phase 5)*, `CoreEnvironment.swift:13` (`.live`, STAYS→allowlist)
- bare `Date()` → `CoreEnvironment.swift:14` (`.live`, STAYS→allowlist)
- `UUID(uuidString:)` deterministic form = **13** (must NOT trip; matches plan's "~13"); `Date(timeIntervalSince1970:)` = **0**; `import Network`/`Timer(`/`URLSession`/`NSWorkspace`/`.asyncAfter` = **0** (forward-looking bans).
- `import GhosttyKit` in core = **0** (structural GhosttyKit-freeness already holds).

**Conclusion:** after the planned moves, every hard-ban token in *staying* core code is gone except the `ModelOperations.swift:776` comment (handled by comment-stripping) and the allowlisted ambient seams (`abbreviateHome`/`expandTilde` defaults + `.live`). The plan's structural-purity claim checks out.

## 7. Surprises & verdict

**Surprises (none blocking; all are notes for later phases):**

1. **`SessionLock` lives in `Model.swift:278`, not `Persistence.swift`.** The plan files it under the persistence/recovery move (Phase 4) without saying where it currently is. Phase 4 must extract it from `Model.swift`. Clean to move — its only consumers (the IO helpers + `CheckpointTests`) all move too; nothing else in core references it. *(Folded into Phase 4 + the RecoveryStore bullet.)*
2. **`loadFromDisk` has 2 app callers the plan doesn't enumerate** (`AppRuntime.swift:87, 1036`), and `parse(themeFileAt:)` has 1 (`ThemeCatalog.swift:36`). The plan enumerates only `configFilePath`'s 5 callers. If Phase 6 keeps the names `DanTermConfigParser.loadFromDisk()` / `ThemeColorParser.parse(themeFileAt:)` via app-side extensions, these callers don't change; if the symbols are renamed/rehomed, these 3 sites also need repointing. *(Folded into Phase 6 + the "Moves to app/" bullet.)*
3. **AppRuntime line drift** (§5): rewrite the initial-group `GroupId()` at **`AppRuntime.swift:84`** (plan said 88); repoint `configFilePath` at **`AppRuntime.swift:553`/`569`** (plan said 558/574). *(Line patches applied.)*
4. **Core-test mint count is 536, not ~410** (§5) — benign; the generic shim is count-independent. `AlertId` is a 5th `TypedId` tag (`Model.swift:22`) the plan's id-seam discussion omits, but the shim covers it. *(Count patched; AlertId noted.)*
5. **`AppDelegate.swift` has both `configFilePath` symbols** — line 500 calls the moving `DanTermConfigParser.configFilePath()`; line 517 calls the separate, non-moving `GhosttyApp.configFilePath()` (def `GhosttyApp.swift:85`, returns `String?`). The plan correctly distinguishes them; just don't repoint line 517.

**None of these contradict the plan's design** — the determinism premise (model stays home-clean; `update()` reads only `newId`/`now`), the dependency direction, the zero-app-churn-for-home claim, and the structural-purity argument all hold against live source.

**Verdict:** **Phase 1 can proceed as written.** Phase 1 (scaffold `DanTermSupport` + symlink + `just test` line) is unaffected by any drift above. Carry these into the later phases they touch: Phase 4 — `SessionLock` is in `Model.swift:278`; Phase 5 — rewrite `GroupId()` at `AppRuntime.swift:84` and pass `home` at the `tabSnapshotJSON` call `Update.swift:2116` (literal `toSnapshot` @2209); Phase 6 — repoint `configFilePath` at `AppRuntime.swift:553/569` and also handle the 2 `loadFromDisk` + 1 `themeFileAt` app callers.
