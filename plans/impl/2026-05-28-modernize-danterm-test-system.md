# Plan: Modernize the DanTerm test system

## Context

DanTerm has 1065 pure model/update tests (16.7k LOC, 37 files) plus a small
protocol suite and a Cocoa UI suite. The big core suite is the project's main
safety net for the Elm-style `update(&model, msg) -> [Command]` logic, but it
runs on a hand-rolled harness that has accumulated real friction:

- **The main test safety net is too easy to skip.** `just test` runs the protocol
  XCTest target and the hand-rolled core harness locally, but the core suite still
  pays the cold compile cost and has no package-native discovery/filtering. CI
  gating is valuable, but it is a follow-up, not part of this migration pass.
- **~93% of every run is wasted compilation.** `./test.sh` takes 19.4s wall, but
  the compiled binary runs in 1.25s. The script compiles ~75 files from scratch
  into a `mktemp -d` that it deletes on exit (`trap rm -rf`) -- no incremental
  build, no cache, every run cold.
- **Two hand-maintained lists rot silently.** `test.sh` lists every app source
  file to compile; `TestHarness.swift`'s `main()` lists every entry function.
  Forget to register a new `func fooTests()` and its tests never run while the
  suite still reports green. (No orphans today, but the footgun is structural.)
- **Weak assertions.** `expectEqual` on a large nested `AppModel` prints
  `big != big` with no field-level diff. Manual `for`-loops stand in for
  parameterized tests and mask which case failed.
- **No parallelism, no name/tag filtering, no Xcode/xcresult integration.**

Toolchain is Swift 6.3.2 / Xcode 26.5, so Swift Testing is fully available. The
22 files the core suite exercises (the full pure compile closure `test.sh` lists)
import only `Foundation`/`DanTermProtocol`/`Darwin` -- the core is already Cocoa-
and GhosttyKit-free, which is what makes extraction into a testable module
feasible.

**Intended outcome:** the core suite runs locally via `swift test` in an isolated,
incrementally-built, parallel, auto-discovered Swift Testing package; failures show
readable diffs. The hand-rolled harness, both manual lists, and the
throwaway-compile loop are retired. GitHub Actions gating is documented as a
follow-up.

## Goals / non-goals

**Goals**
- Run the core suite via `swift test` with incremental builds, parallel
  execution, auto-discovery, and `--filter`.
- Keep `just test` as the local migration gate, ending at protocol + core SwiftPM
  suites plus the local core-purity lint.
- Readable failure diffs for value types (`swift-custom-dump`).
- Bring every migrated test into compliance with the per-test preamble
  convention (Intent / Why / Scenario) from `AGENTS.md` -- the legacy harness
  tests currently have none (0 of 37 test files) -- and keep every test's
  behavioral coverage 1:1 (assertions, not just names; see the per-wave gates).

**Non-goals**
- No change to app/runtime behavior or to what the tests assert. (The sole source
  touch is a behavior-preserving test seam: a defaulted recovery-path parameter on
  the session-lock helpers so `CheckpointTests` runs against a temp dir instead of
  the real recovery path; production callers keep today's default. See R2.)
- No GitHub Actions, branch-protection, or required-status-check changes in this
  pass; CI gating is a follow-up section.
- Not rewriting the protocol XCTest suite (already runs via `swift test`); its
  optional migration is a final, low-value phase.
- Not changing the Cocoa UI suite; it remains a local `just test-ui` harness (see R3).

## Target architecture

Mirror the proven in-repo `DanTermProtocol` dual-manifest pattern: the 22 pure
files move to `lib/DanTermCore/Sources/DanTermCore/`, and **two independent builds
compile the same files** -- the root app build (folding them into the app's own
module) and a nested standalone test package (compiling them as a separate,
GhosttyKit-free `DanTermCore` module). The app does **not** depend on a
`DanTermCore` library module; it includes the core dir in its own `sources`. That
single choice deletes the entire access-control cost -- see R1.

```
lib/DanTermCore/
  Package.swift                       # nested manifest: library + Swift Testing test target
  Sources/DanTermCore/                # the 22 pure files moved out of app/
  Tests/DanTermCoreTests/             # migrated Swift Testing suites + TestSupport.swift
```

**Files moved into `Sources/DanTermCore/`** -- the full pure compile closure
`test.sh` currently lists (22 files; `test.sh` compiling exactly these + the test
files and linking is what proves the set is closed and has no inbound references
to the ~30 Cocoa files): `Model.swift`, `ModelOperations.swift`,
`Projections.swift`, `TabTodo.swift`, `Persistence.swift`, `SidebarItemStore.swift`,
`Msg.swift`, `Command.swift`, `TerminalLaunchEnvironment.swift`, `Update.swift`,
`IpcConnection.swift`, `CLIPathInstaller.swift`, `DragDropInput.swift`,
`DropZone.swift`, `ScrollbarMath.swift`, `TickCoalescer.swift`,
`SurfaceGeometry.swift`, `ThemeColorParser.swift`, `DanTermConfig.swift`,
`TodoPopoverState.swift`, `TodoInputCommand.swift`, `TodoShortcutCatalog.swift`.
Intra-core dependencies that make the three additions mandatory: `Update.swift`
calls `toSnapshot` (`Persistence.swift:96`); `Projections.swift` uses `TabTodoRow`
/ `buildTabTodoRows` (`TabTodo.swift:14,136`).

**Why a nested package and not a root test target:** `swift test` builds the
entire package graph, so a core test target in the root `Package.swift` would
drag in the GhosttyKit-linked `DanTerm` executable and require the xcframework.
The nested package builds only `DanTermCore + DanTermCoreTests`. This is exactly
why `just test` already runs `swift test --package-path lib/DanTermProtocol`.

### Manifest wiring

Root `Package.swift` -- the `DanTerm` executable compiles the core files into its
**own module** by listing both source dirs, so core stays plain `internal` and the
app needs zero access annotations. `path: "."` makes the target root the repo, so
sibling Swift dirs and the nested package must be excluded. Always-present paths go
in a static exclude list; optional gitignored build artifacts are appended only when
they exist, because SwiftPM warns both ways: an unexcluded present artifact produces
unhandled-file warnings, while a static exclude for an absent artifact produces
`Invalid Exclude ... File not found`.

```swift
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

var danTermExcludes = [
    "app/Info.plist", "cli", "tests", "tests-ui",
    "lib/DanTermProtocol", "lib/GhosttyKit.xcframework",
    "lib/DanTermCore/Package.swift", "lib/DanTermCore/Tests",
    // EVERY other non-hidden top-level entry, not just Swift-bearing ones:
    // with path: "." SwiftPM scans the whole repo and warns on ANY unhandled
    // file (verified in a Phase-0 spike). Dirs: "build", "docs", "icon",
    // "scripts", "plans", "self-notes", "integrations", "delete-me". Plus loose
    // top-level files: "README.md", "justfile", the "*.sh" scripts, ...
]

if FileManager.default.fileExists(
    atPath: packageRoot.appendingPathComponent("lib/ghostty-themes").path
) {
    danTermExcludes.append("lib/ghostty-themes")
}

.executableTarget(
    name: "DanTerm",
    dependencies: ["GhosttyKit", "DanTermProtocol"],   // core comes in via sources, not as a dep
    path: ".",
    exclude: danTermExcludes,
    sources: ["app", "lib/DanTermCore/Sources/DanTermCore"],
    swiftSettings: [.swiftLanguageMode(.v5)],
    linkerSettings: [ /* unchanged */ ]
),
```

(`.build`/`.git`/`.ghostty-src`/etc. dot-dirs are ignored automatically, but every
*non-hidden* top-level entry that isn't compiled must be excluded -- not just
Swift-bearing dirs. With `path: "."` SwiftPM treats the repo root as the target dir
and emits "found N file(s) which are unhandled" for any non-source file it sees
(verified: a throwaway `path: "."` package warns on stray dirs *and* loose top-level
files). So the exclude list must cover all non-source top-level dirs (`build`,
`docs`, `icon`, `scripts`, `plans`, `self-notes`, `integrations`, `delete-me`, ...)
*and* loose top-level files (`README.md`, `justfile`, the `*.sh` build scripts, ...).
It is still coarse and stable -- top-level entries change rarely -- and
auto-discovery *within* the `sources` dirs is preserved, so it does not reintroduce
the per-file "rotting list" the migration removes. One non-top-level case to watch:
`lib/` is not wholesale-excluded (it holds the core sources), so gitignored build
artifacts under `lib/` -- especially `lib/ghostty-themes`, populated before some
`build-app.sh` release-style runs execute `swift build` -- are scanned too and must
be excluded when present. Do not statically exclude optional artifacts: a bare local
checkout lacks `lib/ghostty-themes`, and SwiftPM warns on excludes whose paths do
not exist. So the Phase-0 acceptance bar is warning-free in **both** states: bare
checkout (no invalid-exclude warning) and artifact-populated tree (no unhandled
theme-file warnings).

Nested `lib/DanTermCore/Package.swift` -- note DanTermProtocol comes in as a
`.package(path:)` dependency, **not** a target `path:` (SwiftPM forbids a target
source path from escaping the package root via `..`):

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DanTermCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "DanTermCore", targets: ["DanTermCore"])],
    dependencies: [
        .package(path: "../DanTermProtocol"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "DanTermCore",
            dependencies: [.product(name: "DanTermProtocol", package: "DanTermProtocol")],
            path: "Sources/DanTermCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DanTermCoreTests",
            dependencies: [
                "DanTermCore",
                .product(name: "CustomDump", package: "swift-custom-dump"),
            ],
            path: "Tests/DanTermCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

Tests use `@testable import DanTermCore` so they see `internal` symbols and need
no extra access annotations.

## Key risks and decisions

### R1 (resolved by design): keep core in the app's module -- no access-control work

The core files are unit-testable in isolation **without** the app importing a
separate `DanTermCore` module. The root `DanTerm` target compiles them into its own
module (see Manifest wiring), so across the app they stay plain `internal` --
exactly as today. The nested test package compiles the *same files* as a standalone
module and reaches them via `@testable import DanTermCore`. Net effect: **zero
`package`/`public` annotations, zero explicit initializers, zero `import
DanTermCore` edits, no access-keyword spike, and no `@unknown default` step** (no
cross-module switch exists in the app build; an exhaustive switch over a non-resilient
enum needs none anyway -- verified: a `package enum` switched exhaustively across a
two-target SwiftPM package builds with zero warnings).

This matters because the access-control cost a module split *would* impose is real,
not hypothetical -- which is exactly why sidestepping it pays. Access does **not**
propagate from a type to its members: marking `struct AppModel` `package` leaves
`var groups`/`selectedTabId`/`config` (`Model.swift:188-194`) `internal`, so a
separate-module app would fail to compile its reads of `model.groups` until every
*member* it touches (across `AppModel`, `TabModel`, `PaneModel`, the
`Projections.swift` structs, ...) were individually annotated, plus explicit
initializers on every struct the app constructs. (Confirmed on Swift 6.3.2: a
`package struct` with an unmarked member is "inaccessible due to 'internal'" across a
module boundary.) That is a large one-time change **and** a permanent tax -- every
future model field the app reads would need annotating. The same-module design pays
none of it.

**What we do NOT lose.** A module split's only *compiler-enforced* benefit is that
core compiles without the app module or GhosttyKit -- and the nested test package
delivers exactly that: neither the `DanTerm` executable nor `GhosttyKit` is a
dependency of `lib/DanTermCore`, so a core file that calls an app-only symbol or
gains `import GhosttyKit` fails to resolve under the nested `swift test`. What the
nested package does **not** catch is `import Cocoa`/`AppKit`/`SwiftUI`: those are
system frameworks any macOS SwiftPM target links by default, so they compile cleanly
in a standalone package. A *separate* `DanTermCore` module wouldn't catch them
either -- the compiler enforces Cocoa-freeness in no design. We therefore enforce it
with a cheap local lint: a forbidden-import grep over
`lib/DanTermCore/Sources/DanTermCore` (ban `import Cocoa`/`AppKit`/`SwiftUI`) wired
into `just test` at cutover. Net: purity is still enforced locally --
app/GhosttyKit independence by the test package, Cocoa-freeness by the lint -- so
the same-module design loses nothing the split would have given. CI can run the
same command later as a follow-up.

**Trade-off.** `path: "."` is unconventional and needs the `exclude:` list, and the
app build no longer has an internal core/Cocoa boundary -- both minor against
deleting R1. **Verified** (throwaway spike): `.executableTarget(path: ".",
sources: ["app","core"])` beside a sibling `cli` target builds with core as
same-module `internal` and no annotations, while `swift test --package-path` on the
nested package runs green.

**Fallback.** If the Phase-0 check shows `path: "."` cannot yield a launchable
production bundle in the real tree, fall back to the separate-module design: the app
`import DanTermCore`, and annotate the app-touched surface `package` (members
included) with explicit inits -- larger, but conventional.

### R2: parallel-by-default safety

Swift Testing runs in parallel. Findings from the suite audit:

- Vast majority are pure functions over a local `var model` -- inherently safe.
- `CLIPathInstallerTests` already isolates via `temporaryDirectory + UUID` -- safe.
- `CheckpointTests` writes/reads/deletes the real bundle-id recovery dir + session
  lockfile at a **fixed production path** (`writeSessionLockFile` -> `sessionLockURL()`
  -> `recoveryDirectoryURL()` with the production default, `Persistence.swift:276,265,230`)
  -- a **real collision risk**, and `.serialized` does not fix it: serialization only
  orders tests *within* the suite, it does not isolate the shared path from a running
  DanTerm.app, a second test process, or a future suite touching the same dir. Fix it
  by making the recovery path injectable and pointing the test at a temp dir (see Decision).
- Earlier `setenv`/`ProcessInfo` grep hits in `CheckpointTests` /
  `TerminalLaunchEnvironmentTests` were reads / name matches, not process-global
  mutation -- no serialization needed for env on that basis.

**Decision:** default parallel. For `CheckpointTests`, add an injectable recovery-path
parameter to the session-lock I/O helpers (`writeSessionLockFile` / `readSessionLockFile`
/ `deleteSessionLockFile`, plus any checkpoint writer a migrated test exercises),
defaulting to today's production `recoveryDirectoryURL()` so app behavior is unchanged,
and point the migrated test at a unique per-test temp dir
(`FileManager.default.temporaryDirectory` + UUID, removed after the test). The migrated
test must assert the seam is actually honored: check on disk that the concrete temp
`session.json` exists after write and is gone after delete (`FileManager.fileExists`),
not merely that `readSessionLockFile(...)` round-trips -- a round-trip alone still
passes if the parameter is ignored and the helper keeps writing the real recovery path,
which is exactly the regression this isolation must guard. That makes the suite hermetic
and parallel-safe on its own merits -- it no longer depends on `.serialized`. For any
*other* filesystem-touching suite that flakes, the same per-test-temp-dir fix is
preferred; `.serialized` stays an available fallback.

### R3: UI tests remain local

`tests-ui/` explicitly inits `NSApplication.shared` and exercises
`NSView.fittingSize`, `NSSplitView` layout, and `layoutSubtreeIfNeeded()` -- these
need a window-server/GUI session.

**Decision:** keep UI tests local as `just test-ui`. Optionally migrate them to
their own nested package (`lib/DanTermUI`) in a later consolidation pass.

### R4: migrate incrementally, not big-bang

The hand-rolled harness and `swift test` coexist during transition, but the
source move and the test move must each be handled so the old harness never
breaks. `TestHarness.main()` calls every `fooTests()`, and `test.sh` hard-codes
its source paths under `app/` -- so two things are required:

1. Phase 1 moves the 22 source files out of `app/` and **repoints the source lists
   in both `test.sh` and `test-ui.sh` at `lib/DanTermCore/Sources/DanTermCore/`**
   (otherwise the `git mv` breaks both harnesses instantly). `test.sh` lists the full
   pure closure; `test-ui.sh` hard-codes a moved subset (`Model`, `ModelOperations`,
   `Projections`, `TabTodo`, `Persistence`, `Msg`, `Command`, `DanTermConfig`,
   `SidebarItemStore`) alongside Cocoa files that stay in `app/`, so only the moved
   entries are repointed.
2. Each migrated test file is, in the same step, deleted from `tests/` *and*
   de-registered from `TestHarness.main()` -- otherwise `test.sh` fails to compile
   on the now-undefined `fooTests()`, or old and new copies both run.

The result: `test.sh` runs only not-yet-migrated files, `swift test --package-path
lib/DanTermCore` runs the migrated ones, exactly one copy of each test, never red
mid-migration. From the scaffold phase onward both run under local `just test` (the
core run is wired in the moment the package exists, not deferred to cutover);
`test.sh` is dropped only at cutover.

## Migration mechanics

Per file, convert `func fooTests()` into a Swift Testing suite. Largely a
scripted text transform, hand-verified:

- `func fooTests() { ... }`  ->  `@Suite struct FooTests { ... }` (grouping by
  suite lets us attach `.serialized`/tags per domain).
- `test("name") { BODY }`  ->  `@Test("name") func someName() throws { BODY }`.
  The display string moves into `@Test("...")`. **Author the three-section
  Intent / Why / Scenario preamble at the top of each function body** -- the
  legacy tests have none, so conversion must add it (AGENTS.md). Write it from
  the test's actual behavior / the code under test; do not fabricate an incident
  (AGENTS.md: "Do not invent an incident"). This per-test authoring -- not the
  mechanical rewrite -- is the dominant content cost of the migration.
- `try expect(cond, "msg")`  ->  `#expect(cond, "msg")` (drop `try`; `#expect`
  captures source location automatically -- delete the `file:`/`line:` args).
- `try expectEqual(a, b)`  ->  `#expect(a == b)`; for large model/tree values use
  `expectNoDifference(a, b)` for field-level diffs.
- Unwraps / preconditions that should stop the test  ->  `try #require(...)`.

**Shared helpers** move to `Tests/DanTermCoreTests/TestSupport.swift`:
- Keep as-is (fixtures): `makeModel`, `createTab`, `hasEffect`, `paneSnapshots`,
  `allPaneSnapshots`, `paneSnapshot`.
- Delete (replaced by the framework): `test`, `expect`, `expectEqual`,
  `TestFailure`, and the `failures`/`total` globals.

Local core-purity lint command (wired into `just test` at cutover; CI can reuse it
later):

```bash
# Allow leading whitespace + an optional import attribute (@preconcurrency,
# @_exported, @_spi(...), ...); the trailing non-identifier guard stops
# `import CocoaLumberjack`/`CocoaAsyncSocket` from false-positiving on `Cocoa`.
if grep -rnE '^[[:space:]]*(@[^[:space:]]+[[:space:]]+)?import[[:space:]]+(Cocoa|AppKit|SwiftUI)([^[:alnum:]_]|$)' lib/DanTermCore/Sources/DanTermCore; then
  echo "Cocoa/AppKit/SwiftUI import found in DanTermCore (core must stay UI-free)"
  exit 1
fi
```

While both harnesses coexist, local `just test` runs protocol + core +
`./test.sh`. At cutover it runs protocol + core + the purity lint above.

---

## TODO checklist

### Phase 0 -- De-risk (spike, throwaway)
- [ ] Spike on a temp branch: move 1-2 core files to
      `lib/DanTermCore/Sources/DanTermCore/`, rewire the root `DanTerm` target to
      `path: "."` + `sources: ["app", "lib/DanTermCore/Sources/DanTermCore"]` +
      the `exclude:` list, and confirm **`./build-app.sh` yields a launchable
      bundle**. This is the load-bearing check -- `path: "."` changes the
      production build.
- [ ] Enumerate the FULL `exclude:` set in **both checkout states**:
      1. Bare checkout / normal local dev, where `lib/ghostty-themes` is absent:
         there must be no `Invalid Exclude ... File not found` warning.
      2. Artifact-populated tree after the GhosttyKit/themes build, where
         `lib/ghostty-themes` and any other gitignored build artifacts are present:
         there must be no unhandled-file warning for those artifacts.
      Exclude every non-source top-level dir (`build`, `docs`, `icon`,
      `scripts`, `plans`, `self-notes`, `integrations`, `delete-me`, ...), every
      loose top-level non-source file (`README.md`, `justfile`, `*.sh`, ...), and
      append optional build-artifact excludes under `lib/` (`lib/ghostty-themes`)
      conditionally with `FileManager.fileExists`. Build until both states have
      **zero "found N file(s) which are unhandled" warnings**, no invalid excludes,
      no overlapping-target errors, and no stray `tests/`/`cli/` Swift in the app
      module. (A warning flood here means the exclude logic is incomplete, not that
      `path: "."` is wrong.)
- [ ] Stand up the nested `lib/DanTermCore/Package.swift` and confirm
      `swift test --package-path lib/DanTermCore` resolves `swift-custom-dump` and
      runs a trivial `@Test` green.
- [ ] If `build-app.sh` cannot produce a launchable bundle with `path: "."`, adopt
      the R1 fallback (separate module + access annotations). Record the decision.
- [ ] Discard the spike branch.

### Phase 1 -- Scaffold core + nested test package
- [ ] `git mv` the 22 pure files from `app/` to
      `lib/DanTermCore/Sources/DanTermCore/`.
- [ ] Rewire the root `DanTerm` target to `path: "."` + `sources: ["app",
      "lib/DanTermCore/Sources/DanTermCore"]` + the verified `exclude:` list (per
      Phase 0). No `import DanTermCore` and no access annotations -- core stays
      same-module `internal` (R1).
- [ ] Create `lib/DanTermCore/Package.swift` (manifest above): the DanTermCore
      library, the DanTermCoreTests Swift Testing target, the
      `.package(path: "../DanTermProtocol")` dep, and the swift-custom-dump dep.
- [ ] **Gate the core package locally immediately** -- the moment it exists, add
      `swift test --package-path lib/DanTermCore` to the `justfile` `test` target
      (alongside the existing protocol run + `./test.sh`).
      Do this before deleting any suite from `test.sh`: a suite moved into the core
      package but not yet run by `just test` would otherwise be gated nowhere from
      here until cutover, defeating Goal #2 for the whole migration window.
- [ ] **Repoint `test.sh`** so the old harness keeps compiling: replace its
      hard-coded `$SCRIPT_DIR/app/<file>.swift` list with
      `$SCRIPT_DIR/lib/DanTermCore/Sources/DanTermCore/*.swift`. The `git mv`
      breaks `test.sh` immediately without this. Confirm `./test.sh` is still green.
- [ ] **Repoint `test-ui.sh`** the same way: point only its moved-file entries
      (`Model`, `ModelOperations`, `Projections`, `TabTodo`, `Persistence`, `Msg`,
      `Command`, `DanTermConfig`, `SidebarItemStore`) at
      `lib/DanTermCore/Sources/DanTermCore/`, leaving the Cocoa files it also lists
      (`SidebarView`, `PaneSplitView`, `BadgeLabel`, `TodoInputView`) under `app/`.
      Confirm `just test-ui` still compiles and runs green locally.
- [ ] `./build-app.sh` and `just build` compile and launch unchanged.
- [ ] Capture the baseline parity inventory into a tracked `test-inventory.txt`:
      per source file, every old `test("...")` display name AND a per-idiom
      failure-site breakdown -- `expect(`, `expectEqual(`, and `throw TestFailure`
      counts (the three ways an old test can fail) -- plus their sum as the
      total-failure-site count, for the Phase 2 gate (so `expectNoDifference` and
      `#require` conversions are scored against the right baseline; see gate 2).
- [ ] Port shared fixtures into `Tests/DanTermCoreTests/TestSupport.swift`;
      migrate ONE small suite (e.g. `ScrollbarMathTests`) end-to-end as the
      template; confirm `swift test --package-path lib/DanTermCore` is green, then
      delete `tests/ScrollbarMathTests.swift` and remove its `scrollbarMathTests()`
      call from `TestHarness.main()` so the two harnesses don't double-run it.

### Phase 2 -- Migrate the suites in waves
Migrate one file at a time. For **each** file, atomically: (1) write the converted
Swift Testing suite into `Tests/DanTermCoreTests/`; (2) delete the old
`tests/<File>.swift` (the `tests/*.swift` glob then drops it from `test.sh`);
(3) remove that file's `fooTests()` call from `TestHarness.main()` -- otherwise
`test.sh` fails to compile on the now-undefined function. This keeps exactly one
live copy of each test. After each wave, run BOTH `swift test --package-path
lib/DanTermCore` and `./test.sh` green, then run **three structure-sensitive gates**
against the Phase-1 baseline (structural preservation of assertions is the
migration's contract, so these are deliberately structure-sensitive, unlike the bar
for product tests):
  1. **Name parity** -- symmetric *source* grep of old `test("...")` strings vs new
     `@Test("...")` strings (NOT `swift test list`, which emits function
     identifiers, not display strings); every old name maps to a migrated test.
  2. **Assertion parity** -- per file, the **total failure-site count** is
     preserved: old (`expect(` + `expectEqual(` + `throw TestFailure`) equals new
     (`#expect(` + `expectNoDifference(` + `#require(` + `Issue.record(`). Counting
     all idioms on each side is what makes the gate correct: the migration turns
     large-value `expectEqual` into `expectNoDifference` and `guard ... else { throw
     TestFailure }` into `try #require`, so a naive `expect+expectEqual` vs
     `#expect+#require` comparison would both miss `expectNoDifference` (reading a
     valid conversion as a dropped assertion) and double-charge `#require` against
     value assertions (the ~113 `throw TestFailure` sites were never
     `expect`/`expectEqual` calls). A single total across every failure idiom maps
     1:1 regardless of which idiom a site converts to, so no drop hides and no
     conversion false-fails; record the per-idiom breakdown alongside it for
     diagnostics. Two kinds of delta are allowed when logged with a reason -- so the
     gate stays a tripwire for *silent* change, not a straitjacket: an intentional
     `@Test(arguments:)` collapse (log the delta and assert the `arguments:` element
     count equals the old loop's iteration count), and an intentional strengthening
     that *adds* assertions (e.g. `CheckpointTests` gaining the on-disk temp-path
     checks from R2). Any unexplained inequality -- a drop, or an unlogged increase
     -- fails the wave.
  3. **Style** -- every migrated `@Test` carries the three-section preamble (grep
     for `Intent:` / `Why it exists:` / `Scenario:`).
Fail the wave on any gate. (Optional velocity valve, default off: gate 3 -- the
per-test preamble, the migration's dominant content cost -- may be decoupled from
gates 1-2 to land a wave mechanically correct (incremental + parallel + diffs)
with preambles backfilled before cutover, so Goal #4 still holds. The default keeps
all three coupled -- touch each test once, compliance guaranteed.)
Suggested waves (representative files):
- [ ] Wave A -- pure math/parsing: `ScrollbarMathTests`(done), `SurfaceGeometryTests`,
      `ThemeColorParserTests`, `TickCoalescerTests`, `DropZoneTests`,
      `DragDropInputTests`.
- [ ] Wave B -- model ops + snapshots: `ModelOperationsTests`, `SnapshotTests`,
      `TreeOwnsPanesTests`, `ExportTests` (apply `expectNoDifference` to big-tree
      assertions here).
- [ ] Wave C -- update domains: `UpdateTabTests`, `UpdatePaneTests`,
      `UpdateGroupTests`, `UpdateGhosttyTests`, `UpdateLifecycleTests`,
      `UpdateSearchTests`, `UpdateThemeTests`, `UpdateAlertTests`,
      `UpdatePreferencesTests`, `UpdateRemoteTests`, `UpdateMruTests`,
      `UpdateJumpTests`, `ReconcileTests`.
- [ ] Wave D -- IPC/CLI/config/todo: `UpdateIpcTests`, `IpcConnectionTests`,
      `CLIPathInstallerTests`, `DanTermConfigTests`, `TodoPopoverStateTests`,
      `TodoShortcutCatalogTests`, `UpdateTodoTests`, `UpdateTabTodoTests`,
      `TerminalLaunchEnvironmentTests`, `CustomTitleTests`, `SwitcherEventTests`,
      `PaneToolbarTests`, `SidebarItemStoreTests`, `CheckpointTests` (first add the
      injectable recovery-path seam to the session-lock helpers in `Persistence.swift`,
      keeping the production default, then point the migrated session-lock test at a
      per-test temp dir AND assert on disk that the temp `session.json` is created by
      write and removed by delete -- so a no-op parameter that still hit the real
      `~/Library/Application Support/<bundle-id>/Recovery/` path fails the test. See R2.
      This adds assertions over the old round-trip, so log it as an intentional
      strengthening in the gate-2 inventory).
- [ ] Convert remaining manual `for`-loop cases to `@Test(arguments:)` where it
      improves per-case reporting (e.g. scrollbar round-trip); log each such
      collapse as a documented exception in the parity check above.

### Phase 3 -- Cutover
- [ ] All suites migrated; the final parity check accounts for every baseline
      `test("...")` name (mapped or a documented parameterized collapse) -- not a
      bare test-count threshold, which a collapse can satisfy while dropping a body.
- [ ] Delete `tests/TestHarness.swift` and `test.sh` (per-file deletion in Phase 2
      should already have emptied `tests/`; remove any stragglers).
- [ ] Update `justfile`: drop `./test.sh` from `test` (the core
      `swift test --package-path lib/DanTermCore` run was wired in at Phase 1),
      leaving `test` -> protocol + core + the local core-purity lint.
- [ ] Land a self-test for the purity lint beside `scripts/tests/danterm-cli_test.sh`
      (e.g. `scripts/tests/core-purity-lint_test.sh`): positive fixtures that MUST
      trip it (`import Cocoa`, `@preconcurrency import AppKit`, leading-whitespace
      `  import SwiftUI`) and negative fixtures that must NOT (`import CocoaLumberjack`,
      `import Foundation`, a commented `// import AppKit`). The lint is R1's *only*
      guard against Cocoa creep, so a silent regex regression must itself be caught.
- [ ] Update docs: `AGENTS.md` (Tests + Architecture sections), and add a design
      note under `docs/design/` recording the decision -- core compiled same-module
      into the app (`path: "."`) while a nested package tests it in isolation on
      Swift Testing, and why that beats a separate `DanTermCore` module (R1).

### Phase 4 -- Follow-up: CI and optional consolidation
- [ ] Optional standalone CI quick win, independent of the migration: add a
      GitHub Actions check for today's local gate (`swift test --package-path
      lib/DanTermProtocol` + `./test.sh`). Skip this if the project wants zero
      CI/branch-protection churn until after cutover.
- [ ] After cutover, add or update a GitHub Actions `test` job (`macos-26`) that
      runs the same pure gate as local `just test`: `swift test --package-path
      lib/DanTermProtocol`, `swift test --package-path lib/DanTermCore`, and the
      core-purity lint.
- [ ] Mark the `test` job a **required status check** on the default branch
      (branch protection / ruleset -- a repo setting; a red job does not block
      merge without it).
- [ ] Verify end to end: open a PR with a deliberately broken test and confirm
      **merge is blocked** (not merely that the job goes red), then revert it.
- [ ] Migrate `lib/DanTermProtocol` XCTest -> Swift Testing for one idiom repo-wide
      if the project wants one test framework everywhere.
- [ ] Extract `tests-ui/` into a `lib/DanTermUI` nested package on Swift Testing.
      If CI coverage for UI tests becomes valuable, add it as a non-blocking CI job
      after confirming runner GUI-session behavior.

---

## Verification

- **Unit (core):** `swift test --package-path lib/DanTermCore` -- green, and a
  warm second run completes in ~1-2s (vs 19.4s today), confirming incremental
  build + parallelism. Verify `--filter` selects a single suite.
- **Coverage parity (names + assertions):** every old `test("...")` name from the
  baseline maps to a migrated test (source grep, not `swift test list`), AND each
  file's **total failure-site count** is preserved -- old (`expect` + `expectEqual`
  + `throw TestFailure`) equals new (`#expect` + `expectNoDifference` + `#require` +
  `Issue.record`), counting all idioms so `expectNoDifference` and `#require`
  conversions score correctly (Phase 2 gate 2). As in gate 2, equality is required
  except for two logged deltas -- `@Test(arguments:)` collapses (case counts checked)
  and intentional assertion strengthenings (e.g. `CheckpointTests`' on-disk temp-path
  checks) -- and any unexplained inequality fails. A raw test-count threshold is
  insufficient -- a collapse lowers the function count, and a preserved name can still
  drop an interior assertion.
- **Preamble compliance:** every migrated `@Test` carries an Intent / Why /
  Scenario preamble (grep gate in the per-wave check); none fabricated.
- **Diff quality:** temporarily break one model-equality assertion and confirm
  `expectNoDifference` prints a field-level diff.
- **Core purity:** the local core-purity lint over `lib/DanTermCore/Sources/DanTermCore`
  fails `just test` if a core file adds `import Cocoa`/`AppKit`/`SwiftUI` (the nested
  package alone can't catch system-framework imports -- see R1).
- **Protocol:** `swift test --package-path lib/DanTermProtocol` -- green.
- **App unaffected:** `just build` (and `just build-run`) compile and launch; the
  Elm runtime behaves identically (no behavioral code changed).
- **Parallel safety:** run `swift test --package-path lib/DanTermCore` 3x; no
  flakes from the filesystem-touching suites.

## Rollback / coexistence

Every phase is independently revertable. The two harnesses run side by side:
Phase 1 repoints `test.sh` and `test-ui.sh` at the moved core sources and wires
`swift test --package-path lib/DanTermCore` into local `just test`; each Phase 2
file is deleted from `tests/` and de-registered from `TestHarness.main()` as it is
migrated, so `test.sh` and `swift test` together always run exactly one local copy
of each test mid-migration. The hand-rolled harness is removed only in Phase 3
after the name-inventory parity check passes. CI gating waits for the Phase 4
follow-up.

## Sources

- Swift Testing (parameterized `@Test(arguments:)`, parallel-by-default,
  `.serialized`, XCTest coexistence): https://developer.apple.com/xcode/swift-testing/
- `swift test` builds the whole package graph (rationale for a nested package):
  https://forums.swift.org/t/swift-test-tries-to-build-all-targets-instead-of-just-those-needed-for-testing/82803
- Extract a library target to make executable logic testable:
  https://forums.swift.org/t/unit-testing-executable-targets-with-swift-package-manager/44860
- `swift-custom-dump` `expectNoDifference` (works with XCTest and Swift Testing):
  https://github.com/pointfreeco/swift-custom-dump
